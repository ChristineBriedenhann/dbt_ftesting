/*
    ## fivetran_datastore_template
    
    A macro that generates a slowly changing dimension (SCD Type 2) datastore table 
    for Fivetran-ingested data. It tracks historical changes to records by maintaining 
    versioned rows with effective date ranges.

    ### Parameters
    - `this`              : Reference to the current model (dbt `this` object)
    - `ref_table`         : Reference to the source/staging table containing incoming data
    - `unique_key`        : The surrogate or technical key that uniquely identifies a record version
    - `business_key`      : The natural/business key used to identify a logical entity across versions
    - `exclude_columns`   : (optional) List of columns to exclude from change detection. Defaults to `none`
    - `datastore_key_type`: (optional) Strategy for generating the unique key. Defaults to `"identity"`

    ### Behavior
    - Uses `_fivetran_synced_ltz` (local timezone-converted version of `_fivetran_synced`) 
      as the change tracking date column, set at the upstream `*_000` transformation step.
    - Opens new record versions using `var("low_date")` as the default start date.
    - Closes superseded record versions using `var("high_date")` as the default end date.
    - If table created with Fivetran history mode, it simply adds system columns and versioning, no CDC.
    - It also supports to execute multiple times for same datastore_process_date. It means the table can 
      have multiple-versions in a day if Fivetran executes multiple-times in a day.

    ### Required dbt Variables
    - `low_date`  : The earliest/default effective start timestamp (e.g. `'1900-01-01'`)
    - `high_date` : The far-future/default effective end timestamp (e.g. `'9999-12-31'`)

    ### Example Usage
    ```sql
    {{ fivetran_datastore_template(
        this,
        ref('my_source_table'),
        unique_key='record_key',
        business_key='customer_id',
        exclude_columns=['_fivetran_synced', 'load_timestamp'],
        datastore_key_type='identity'
    ) }}
    ```
*/
{% macro fivetran_datastore_template(this, ref_table, unique_key, business_key, exclude_columns=none, datastore_key_type="identity") %}
    {%- set start_date = "'" ~ var("low_date") ~ "'::timestamp_ntz" -%} {# Default start date for the first version of record #}
    {%- set end_date = "'" ~ var('high_date') ~ "'::timestamp_ntz" -%} {# Default end date for the first version of record #}
    
    {# 
        For Fivetran ingestion solution, "_fivetran_synced" is key column to detect time of changes. 
        It is in UTC format hence use "_fivetran_synced_ltz" which was transformed to project timezone at step *_000 
    #}
    {%- set dss_track_date_col = "_fivetran_synced_ltz" %}
    
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

    {%- set system_columns_list = system_columns_list() -%}
    {%- set system_columns_arr = system_columns_list.values()|list -%}
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
        {{ _fivetran_generate_initial_load_sql(
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
        {{ _fivetran_generate_incremental_load_sql(
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

{% macro _fivetran_generate_incremental_load_sql(this, ref_table, ref_column_list, ref_column_list_after_exclude, unique_key_cols_src, unique_key, datastore_key_type, system_columns_list, system_columns_arr, start_date, end_date, business_key, dss_track_date_col, existing_record_end_date, existing_record_start_date, exclude_columns) %}
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
    {% if "_fivetran_start" not in fields_to_track -%}
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
                {% if "_fivetran_deleted" in ref_column_list %}
                src._fivetran_deleted as {{ system_columns_list.system_delete_flag }},
                {% else %}
                'N' as {{ system_columns_list.system_delete_flag }},
                {% endif %}
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
                {% if "_fivetran_deleted" in fields_to_track %}
                case when src._fivetran_deleted = true then 'Y' else 'N' end as {{ system_columns_list.system_delete_flag }},
                {% else %}
                'N' as {{ system_columns_list.system_delete_flag }},
                {% endif %}
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
        exclude (merge_category {% if exclude_columns and exclude_columns|length > 0 %}, {{exclude_columns|join(", ")}}{% endif %})
    from final
    {% else %}
    with
        source_records as (
            /* Select data from ref table */
            select 
                *,
                {{ generate_hash_key(business_key) }} as {{ system_columns_list.system_business_key }},
                {{ generate_hash_key(fields_to_track) }} as {{ system_columns_list.system_check_columns }}
            from {{ref_table}}
        ),
        reorder_start_end as (
            /* Re-order by _fivetran_start to create version_index */
            select 
                sr.*,
                case
                    when lead(sr._fivetran_start_ltz) 
                            over (partition by {{ system_columns_list.system_business_key }} order by sr._fivetran_start_ltz) < coalesce(sr._fivetran_end_ltz, {{ end_date }})
                        then dateadd('ms', -3, lead(sr._fivetran_start_ltz) 
                            over (partition by {{ system_columns_list.system_business_key }} order by sr._fivetran_start_ltz))
                else coalesce(sr._fivetran_end_ltz, {{ end_date }})
                end as _fivetran_end_ltz_transformed,
                case
                    when lead(sr._fivetran_start_ltz) 
                            over (partition by {{ system_columns_list.system_business_key }} order by sr._fivetran_start_ltz) < coalesce(sr._fivetran_end_ltz, {{ end_date }})
                        then false
                else _fivetran_active
                end as _fivetran_active_transformed,
                row_number() over (partition by {{ system_columns_list.system_business_key }} order by sr._fivetran_start_ltz) as version_index
            from source_records sr
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
                {%- if (fields_not_ref|length > 1) %}
                {{ prefix_fields('src', fields_not_in_ref) }},
                {% endif %}
                {%- if (fields_not_in_target|length > 1) %}
                    {%- for col in fields_not_in_target %}
                null as {{col}},
                    {%- endfor %}
                {% endif %}
                case when src.version_index = 1 then {{ start_date }} else src._fivetran_start_ltz end as {{ system_columns_list.system_start_date }},
                case when src._fivetran_active_transformed = true then {{ end_date }} else src._fivetran_end_ltz_transformed end as {{ system_columns_list.system_end_date }},
                src.version_index as {{  system_columns_list.system_version }},
                case when src._fivetran_active_transformed = true then 'Y' else 'N' end as {{ system_columns_list.system_current_flag }},
                {% if "_fivetran_deleted" in ref_column_list %}
                src._fivetran_deleted as {{ system_columns_list.system_delete_flag }},
                {% else %}
                'N' as {{ system_columns_list.system_delete_flag }},
                {% endif %}
                current_timestamp()::timestamp_ntz as {{  system_columns_list.system_create_time }},
                current_timestamp()::timestamp_ntz as {{  system_columns_list.system_update_time }},
                'INITIAL VERSION RECORD' as merge_category
            from reorder_start_end src
            left join active_target_records atr
                on src.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
            where atr.{{ system_columns_list.system_business_key }} is null
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
                src._fivetran_start_ltz as {{ system_columns_list.system_start_date }},
                case when src._fivetran_active_transformed = true then {{ end_date }} else src._fivetran_end_ltz_transformed end as {{ system_columns_list.system_end_date }},
                row_number() over (partition by src.{{ system_columns_list.system_business_key }} order by src._fivetran_start_ltz ) + atr.{{  system_columns_list.system_version }} as {{  system_columns_list.system_version }},
                case when src._fivetran_active_transformed = true then 'Y' else 'N' end as {{ system_columns_list.system_current_flag }},
                {% if "_fivetran_deleted" in fields_to_track %}
                case when src._fivetran_deleted = true then 'Y' else 'N' end as {{ system_columns_list.system_delete_flag }},
                {% else %}
                'N' as {{ system_columns_list.system_delete_flag }},
                {% endif %}
                current_timestamp()::timestamp_ntz as {{  system_columns_list.system_create_time }},
                current_timestamp()::timestamp_ntz as {{  system_columns_list.system_update_time }},
                'NEW VERSION RECORD' as merge_category
            from reorder_start_end src
            join active_target_records atr
                on src.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
            where atr.{{ system_columns_list.system_check_columns }} <> src.{{ system_columns_list.system_check_columns }}
                and atr._fivetran_start_ltz < src._fivetran_start_ltz
        ),
        to_deactivate_existing_records as (
            /* De-activate existing records before adding new version */
            select
                atr.{{ unique_key }},
                {{  prefix_fields('src', fields_to_track) }},
                {%- if (fields_not_in_ref|length > 1) %}
                {{  prefix_fields('atr', fields_not_in_ref) }},
                {% endif %}
                {%- if (fields_not_in_target|length > 1) %}
                    {%- for col in fields_not_in_target %}
                null as {{col}},
                    {%- endfor %}
                {% endif %}
                atr.{{ system_columns_list.system_start_date }} as {{ system_columns_list.system_start_date }},
                src._fivetran_end_ltz_transformed as {{ system_columns_list.system_end_date }},
                atr.{{ system_columns_list.system_version }},
                'N' as {{ system_columns_list.system_current_flag }},
                atr.{{ system_columns_list.system_delete_flag }} as {{ system_columns_list.system_delete_flag }},
                atr.{{ system_columns_list.system_create_time }} as {{ system_columns_list.system_create_time }},
                current_timestamp()::timestamp_ntz as {{ system_columns_list.system_update_time }},
                'DE-ACTIVATED VERSION RECORD' as merge_category
            from active_target_records atr
            join reorder_start_end src
                on src.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
            where atr.{{ system_columns_list.system_check_columns }} <> src.{{ system_columns_list.system_check_columns }}
                and atr._fivetran_start_ltz = src._fivetran_start_ltz
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
        exclude (merge_category {% if exclude_columns and exclude_columns|length > 0 %}, {{exclude_columns|join(", ")}}{% endif %})
    from final
    {% endif %}
{% endmacro %}

{% macro _fivetran_generate_initial_load_sql(ref_table, ref_column_list, ref_column_list_after_exclude, unique_key_cols_src, unique_key, datastore_key_type, system_columns_list, start_date, end_date, business_key, exclude_columns) %}
{% if "_fivetran_start" not in ref_column_list_after_exclude -%}
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
            {% if "_fivetran_deleted" in ref_column_list %}
            src._fivetran_deleted as {{ system_columns_list.system_delete_flag }},
            {% else %}
            'N' as {{ system_columns_list.system_delete_flag }},
            {% endif %}
            current_timestamp()::timestamp_ntz as {{ system_columns_list.system_create_time }},
            current_timestamp()::timestamp_ntz as {{ system_columns_list.system_update_time }}
            {% if exclude_columns and exclude_columns|length > 0 %}exclude ({{exclude_columns|join(", ")}}){% endif %}
        from source_records src
        where 1=1
{% else %}
        with
            source_records as (
                select *
                    , {{ generate_hash_key(business_key) }} as {{ system_columns_list.system_business_key }}
                from {{ref_table}}
            ),
            reorder_start_end as (
                select 
                    sr.*,
                    case
                        when lead(sr._fivetran_start_ltz) 
                                over (partition by {{ system_columns_list.system_business_key }} order by sr._fivetran_start_ltz) < coalesce(sr._fivetran_end_ltz, {{ end_date }})
                            then dateadd('ms', -3, lead(sr._fivetran_start_ltz) 
                                over (partition by {{ system_columns_list.system_business_key }} order by sr._fivetran_start_ltz))
                    else coalesce(sr._fivetran_end_ltz, {{ end_date }})
                    end as _fivetran_end_ltz_transformed,
                    case
                        when lead(sr._fivetran_start_ltz) 
                                over (partition by {{ system_columns_list.system_business_key }} order by sr._fivetran_start_ltz) < coalesce(sr._fivetran_end_ltz, {{ end_date }})
                            then false
                    else _fivetran_active
                    end as _fivetran_active_transformed,
                    row_number() over (partition by {{ system_columns_list.system_business_key }} order by sr._fivetran_start_ltz) as version_index
                from source_records sr
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
            case when version_index = 1 then {{ start_date }} else src._fivetran_start_ltz end as {{ system_columns_list.system_start_date }},
            case when src._fivetran_active_transformed = true then {{ end_date }} else src._fivetran_end_ltz_transformed end as {{ system_columns_list.system_end_date }},
            version_index as {{  system_columns_list.system_version }},
            case when src._fivetran_active_transformed = true then 'Y' else 'N' end as {{ system_columns_list.system_current_flag }},
            {% if "_fivetran_deleted" in ref_column_list %}
            src._fivetran_deleted as {{ system_columns_list.system_delete_flag }},
            {% else %}
            'N' as {{ system_columns_list.system_delete_flag }},
            {% endif %}
            current_timestamp()::timestamp_ntz as {{ system_columns_list.system_create_time }},
            current_timestamp()::timestamp_ntz as {{ system_columns_list.system_update_time }}
            {% if exclude_columns and exclude_columns|length > 0 %}exclude ({{exclude_columns|join(", ")}}){% endif %}
        from reorder_start_end src
        where 1=1
{% endif %}
{% endmacro %}
