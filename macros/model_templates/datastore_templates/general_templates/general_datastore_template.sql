/*
    Macro: general_datastore_template

    Description:
        Generates a standardized slowly changing dimension (SCD Type 2) datastore table
        by comparing source records against existing target records. It tracks the full
        history of changes for each entity by managing effective start and end dates,
        inserting new records, and closing out outdated versions.

    Arguments:
        this              (relation)  - Reference to the current dbt model (target table).
        ref_table         (relation)  - Reference to the source/staging table to load from.
        unique_key        (string)    - Column(s) uniquely identifying each versioned record
                                        in the target table (e.g. surrogate/hash key).
        business_key      (string)    - Column(s) representing the natural/business key used
                                        to match records across source and target.
        exclude_columns   (list)      - Optional. List of columns to exclude from change
                                        detection comparison. Defaults to none.
        datastore_key_type (string)   - Optional. Defines the key generation strategy for the
                                        datastore. Accepted values: "identity" (default) or
                                        "hash".

    Variables Required:
        low_date   - The default start date applied to the first version of a record.
        high_date  - The default end date (far-future date) applied to the current/active
                     version of a record.

    Notes:
        - Relies on the `system_columns_list()` macro to retrieve standard system column names.
        - The end date of an expiring record is set to 3 milliseconds before the new
          record's load date to avoid overlapping date ranges.

*/
{% macro general_datastore_template(this, ref_table, unique_key, business_key, exclude_columns=none, datastore_key_type="identity") %}
    {%- set start_date = "'" ~ var("low_date") ~ "'::timestamp_ntz" -%} {# Default start date for the first version of record #}
    {%- set end_date = "'" ~ var('high_date') ~ "'::timestamp_ntz" -%} {# Default end date for the first version of record #}
    
    {%- set system_columns_list = system_columns_list() -%}
    {%- set dss_track_date_col = system_columns_list.system_sf_load_date %}
    
    {%- set existing_record_end_date = "dateadd(ms, -3, src." ~ dss_track_date_col ~ ")" -%}   {# Default end date for the current version of record #}
    {%- set existing_record_start_date = "src." ~ dss_track_date_col -%}

    {%- set unique_key_cols_src = [] -%}
    {%- for col in business_key -%}
        {%- do unique_key_cols_src.append("src." ~ col|trim|lower) -%}
    {%- endfor -%}

    {%- set unique_key_cols_atr = [] -%}
    {%- for col in business_key -%}
        {%- do unique_key_cols_atr.append("atr." ~ col|trim|lower) -%}
    {%- endfor -%}

    {%- set system_columns_arr = [] -%}
    {% for col in system_columns_list.values()|list %}
        {% if col != dss_track_date_col  %}
            {% do system_columns_arr.append(col|trim|lower) %}
        {% endif %}
    {% endfor %}

    {#- set system_columns_arr = system_columns_list.values()|list -#}
    {%- do system_columns_arr.append(unique_key|trim|lower) -%}

    {# get column list from ref_table #}
    {%- set ref_column_list = dbt_utils.get_filtered_columns_in_relation(ref_table) -%}
    {%- set ref_column_list_after_exclude = [] -%}
    {%- for col in ref_column_list -%}
        {%- if ((col|trim|lower) not in system_columns_arr) -%}
            {%- do ref_column_list_after_exclude.append((col|trim|lower)) -%}
        {%- endif -%}
    {%- endfor -%}

    {%- set relation = load_relation(this) -%}
    {%- if (not relation or not is_incremental()) -%} {# SCD table does not exist or is not incremental ==> Insert new records, no need to detect for changes. #}
        {{ _general_generate_initial_load_sql(
            ref_table=ref_table, 
            ref_column_list=ref_column_list, 
            ref_column_list_after_exclude=ref_column_list_after_exclude, 
            unique_key_cols_src=unique_key_cols_src, 
            unique_key=unique_key, 
            datastore_key_type=datastore_key_type, 
            system_columns_list=system_columns_list, 
            start_date=start_date, 
            end_date=end_date, 
            business_key=business_key,
            exclude_columns=exclude_columns
        ) }}
    {%- else -%} {# table exists and need to compare source to target data based on check_columns #}
        {{ _general_generate_incremental_load_sql(
            this=this, 
            ref_table=ref_table, 
            ref_column_list=ref_column_list, 
            ref_column_list_after_exclude=ref_column_list_after_exclude, 
            unique_key_cols_src=unique_key_cols_src, 
            unique_key=unique_key, 
            datastore_key_type=datastore_key_type, 
            system_columns_list=system_columns_list, 
            system_columns_arr=system_columns_arr, 
            start_date=start_date, 
            end_date=end_date, 
            business_key=business_key, 
            dss_track_date_col=dss_track_date_col, 
            existing_record_end_date=existing_record_end_date, 
            existing_record_start_date=existing_record_start_date, 
            exclude_columns=exclude_columns
        ) }}
    {%- endif -%}

{% endmacro %}

{% macro _general_generate_incremental_load_sql(this, ref_table, ref_column_list, ref_column_list_after_exclude, unique_key_cols_src, unique_key, datastore_key_type, system_columns_list, system_columns_arr, start_date, end_date, business_key, dss_track_date_col, existing_record_end_date, existing_record_start_date, exclude_columns) %}
    {# Get the list columns from target table #}
    {%- set tgt_column_list = dbt_utils.get_filtered_columns_in_relation(this) -%}
    {%- set fields_to_select_target = [] -%}
    {%- for col in tgt_column_list -%}
        {%- if ((col|trim|lower) not in system_columns_arr) -%}
            {%- do fields_to_select_target.append((col|trim|lower)) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- set fields_to_track = [] -%}
    {%- set fields_not_in_target = [] -%}
    {%- set fields_not_in_ref = [] -%}

    {# If columns are same between source (ref) and target (scd) ==> add to track columns list. Otherwise, add to not_in_target columns list #}
    {%- for col in ref_column_list_after_exclude -%}
        {%- if (col in fields_to_select_target and col not in system_columns_arr) -%}
            {%- do fields_to_track.append(col) -%}
        {%- else -%}
            {%- do fields_not_in_target.append(col) -%}
        {%- endif -%}
    {%- endfor -%}
    {# Add any columns in target (scd) but no longer in source (ref) #}
    {%- for col in fields_to_select_target -%}
        {%- if (col not in ref_column_list_after_exclude) -%}
            {%- do fields_not_in_ref.append(col) -%}
        {%- endif -%}
    {%- endfor -%}

    {# Build full columns list #}
    {%- set full_columns_set = [] -%}
    {%- for col in fields_to_track -%}
        {%- do full_columns_set.append(col) -%}
    {%- endfor -%}
    {%- for col in fields_not_in_target -%}
        {%- if (col not in full_columns_set) -%}
            {%- do full_columns_set.append(col) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- for col in fields_not_in_ref -%}
        {%- if (col not in full_columns_set) -%}
            {%- do full_columns_set.append(col) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- do full_columns_set.append(system_columns_list.system_start_date) -%}
    {%- do full_columns_set.append(system_columns_list.system_end_date) -%}
    {%- do full_columns_set.append(system_columns_list.system_version) -%}
    {%- do full_columns_set.append(system_columns_list.system_current_flag) -%}
    {%- do full_columns_set.append(system_columns_list.system_delete_flag) -%}
    {%- do full_columns_set.append(system_columns_list.system_create_time) -%}
    {%- do full_columns_set.append(system_columns_list.system_update_time) -%}

    {# Build SQL to detect changes #}
    with
        source_records as (
            /* Select data from ref table */
            select 
                *,
                {{ generate_hash_key(business_key) }} as {{ system_columns_list.system_business_key }},
                {{ generate_hash_key(fields_to_track) }} as {{ system_columns_list.system_check_columns }}
            from {{ref_table}}
        ),
        active_target_records as (
            /* Select active records from target table */
            select 
                *,
                {{ generate_hash_key(business_key) }} as {{ system_columns_list.system_business_key }},
                {{ generate_hash_key(fields_to_track) }} as {{ system_columns_list.system_check_columns }}
            from {{this}}
            where {{ system_columns_list.system_current_flag }} = 'Y'
        ),
        {% if datastore_key_type == "identity" %}
        max_ds_key_data as (
            select max({{ unique_key }}) as max_ds_key
            from {{this}}
        ),
        {% endif -%}
        new_records as (
            /* Identify new records [in ref_table, not in target_table] */
            select
                {{  prefix_fields('src', fields_to_track) }},
                {%- if (fields_not_in_ref|length > 1) %}
                {{ prefix_fields('src', fields_not_in_ref) }},
                {% endif %}
                {%- if (fields_not_in_target|length > 1) %}
                    {%- for col in fields_not_in_target %}
                null as {{col}},
                    {%- endfor %}
                {% endif %}
                {{ start_date }} as {{ system_columns_list.system_start_date }},
                {{ end_date }} as {{ system_columns_list.system_end_date }},
                coalesce(atr.{{ system_columns_list.system_version }}, 0) + 1 as {{  system_columns_list.system_version }},
                'Y' as {{  system_columns_list.system_current_flag }},
                'N' as {{ system_columns_list.system_delete_flag }},
                current_timestamp()::timestamp_ntz as {{  system_columns_list.system_create_time }},
                current_timestamp()::timestamp_ntz as {{  system_columns_list.system_update_time }},
                'INITIAL VERSION RECORD' as merge_category
            from source_records src
            left join active_target_records atr
                on src.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
            where atr.{{ system_columns_list.system_business_key }} is null
        ),
        to_deactivate_existing_records as (
            /* De-activate existing records before adding new version */
            select
                atr.{{ unique_key }},
                {{  prefix_fields('atr', fields_to_track) }},
                {%- if (fields_not_in_ref|length > 1) %}
                {{  prefix_fields('atr', fields_not_in_ref) }},
                {% endif %}
                {%- if (fields_not_in_target|length > 1) %}
                    {%- for col in fields_not_in_target %}
                null as {{col}},
                    {%- endfor %}
                {% endif %}
                atr.{{ system_columns_list.system_start_date }} as {{ system_columns_list.system_start_date }},
                {{ existing_record_end_date }} as {{ system_columns_list.system_end_date }},
                atr.{{ system_columns_list.system_version }},
                'N' as {{ system_columns_list.system_current_flag }},
                atr.{{ system_columns_list.system_delete_flag }} as {{ system_columns_list.system_delete_flag }},
                atr.{{ system_columns_list.system_create_time }} as {{ system_columns_list.system_create_time }},
                current_timestamp()::timestamp_ntz as {{ system_columns_list.system_update_time }},
                'DE-ACTIVATED VERSION RECORD' as merge_category
            from active_target_records atr
            join source_records src
                on src.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
            where atr.{{ system_columns_list.system_check_columns }} <> src.{{ system_columns_list.system_check_columns }}
                and atr.{{ dss_track_date_col }} < src.{{ dss_track_date_col }}
        ),
        new_version_of_existing_records as (
            /* Add new version for changed records */
            select
                {{  prefix_fields('src', fields_to_track) }},
                {%- if (fields_not_in_ref|length > 1) %}
                {{  prefix_fields('atr', fields_not_in_ref) }},
                {% endif %}
                {%- if (fields_not_in_target|length > 1) %}
                {{  prefix_fields('src', fields_not_in_target) }},
                {% endif %}
                {{ existing_record_start_date }} as {{ system_columns_list.system_start_date }},
                {{ end_date }} as {{ system_columns_list.system_end_date }},
                coalesce(atr.{{ system_columns_list.system_version }}, 0) + 1 as {{  system_columns_list.system_version }},
                'Y' as {{  system_columns_list.system_current_flag }},
                'N' as {{ system_columns_list.system_delete_flag }},
                current_timestamp()::timestamp_ntz as {{  system_columns_list.system_create_time }},
                current_timestamp()::timestamp_ntz as {{  system_columns_list.system_update_time }},
                'NEW VERSION RECORD' as merge_category
            from source_records src
            join active_target_records atr
                on src.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
            where atr.{{ system_columns_list.system_check_columns }} <> src.{{ system_columns_list.system_check_columns }}
                and atr.{{ dss_track_date_col }} < src.{{ dss_track_date_col }}
        ),
        union_new_records_data as (
            select 
                {{  prefix_fields('nr', full_columns_set) }}
                , merge_category
            from new_records nr
            union all
            select
                {{  prefix_fields('ner', full_columns_set) }}
                , merge_category
            from new_version_of_existing_records ner
        ),
        generate_key_new_records as (
            select 
                {{ generate_datastore_key(
                        unique_key_cols_src=unique_key_cols_src, 
                        unique_key_name=unique_key, 
                        datastore_key_type=datastore_key_type,
                        _is_incremental=true
                ) }}
                und.*
            from union_new_records_data und
        ),
        final as (
            select 
                ud.*
            from generate_key_new_records ud
            union all
            select 
                der.{{unique_key}},
                {{  prefix_fields('der', full_columns_set) }}
                , merge_category
            from to_deactivate_existing_records der
        )
    select * 
        exclude (merge_category {% if exclude_columns != none and exclude_columns|length > 0 %}, {{exclude_columns|join(", ")}}{% endif %})
    from final
 
{% endmacro %}

{% macro _general_generate_initial_load_sql(ref_table, ref_column_list, ref_column_list_after_exclude, unique_key_cols_src, unique_key, datastore_key_type, system_columns_list, start_date, end_date, business_key, exclude_columns) %}
        with
            source_records as (
                select *
                from {{ref_table}}
            )
        select
            {{ generate_datastore_key(
                    unique_key_cols_src=unique_key_cols_src, 
                    unique_key_name=unique_key, 
                    datastore_key_type=datastore_key_type,
                    _is_incremental=false
            ) }}
            {% for col in ref_column_list_after_exclude -%}
            {{col}},
            {% endfor -%}
            {{ start_date }} as {{ system_columns_list.system_start_date }},
            {{ end_date }} as {{ system_columns_list.system_end_date }},
            1::INT as {{  system_columns_list.system_version }},
            'Y' as {{ system_columns_list.system_current_flag }},
            'N' as {{ system_columns_list.system_delete_flag }},
            current_timestamp()::timestamp_ntz as {{ system_columns_list.system_create_time }},
            current_timestamp()::timestamp_ntz as {{ system_columns_list.system_update_time }}
            {% if exclude_columns != none and exclude_columns|length > 0 %}exclude ({{exclude_columns|join(", ")}}){% endif %}
        from source_records src
        where 1=1

{% endmacro %}
