/*
  Macro: generate_scd2_dimension_template
  
  Description:
    Generates a Slowly Changing Dimension Type 2 (SCD2) SQL template for a given
    dimension table. This macro handles the full lifecycle of SCD2 records, including:
      - Inserting new records as they are first encountered
      - Expiring (closing out) existing records when attributes change
      - Inserting updated records as new versions with a new effective date range
      - Optionally tracking soft-deletes for records that disappear from the source

  Parameters:
    this             (required) - Reference to the current dbt model (use `this`)
    ref_table        (required) - The source/staging table to compare against the dimension
    exception_table  (required) - Table containing records to exclude from processing
    unique_key       (required) - Surrogate/primary key column name of the dimension table
    business_key     (required) - List of natural/business key column(s) that uniquely
                                  identify a business entity (used for record matching)
    dss_track_date   (required) - The effective date (yyyy-mm-dd) used to open/close
                                  record versions (e.g. the batch processing date)
    dim_key_type     (optional) - Strategy for generating the surrogate key.
                                  Accepted values: "identity" (default) or "hash"
    track_delete     (optional) - Flag ("Y"/"N") indicating whether to mark records
                                  as deleted when they no longer appear in the source.
                                  Defaults to "Y".
                                  To allow track_delete work correctly, it's required to supply
                                  full set of records in ref_table, not only new changed records.
                                  E.g. 
                                        select * from ds_account 
                                        where 1=1
                                            and <dwh_process_date>::timestamp_ntz between dbt_start_date and dbt_end_date
                                            and dbt_delete_flag <> "Y"

  Record Date Ranges:
    - New/updated records receive a start date of `dss_track_date` and an end date
      of the configured `high_date` variable (representing "currently active")
    - Expired records are closed with an end date of `dss_track_date - 3ms`
    - The `low_date` variable is used as the start date for the very first version
      of each record

  Usage Example:
    {{
        config(
            materialized='incremental',
            unique_key=unique_key,
            incremental_strategy='merge',
            on_schema_change='append_new_columns'
        )
    }}
    {{ generate_scd2_dimension_template(
        this            = this,
        ref_table       = ref('stg_customer'),
        exception_table = ref('dim_customer_exceptions'),
        unique_key      = 'customer_key',
        business_key    = ['customer_id', 'source_system'],
        dss_track_date  = '2024-01-15',
        dim_key_type    = 'identity',
        track_delete    = 'Y'
    ) }}
*/
{% macro generate_scd2_dimension_template(this, ref_table, exception_table, unique_key, business_key, dss_track_date, dim_key_type="identity", track_delete="Y") %}
    {%- set start_date = "'" ~ var("low_date") ~ "'::timestamp_ntz" -%} {# Default start date for the first version of record #}
    {%- set end_date = "'" ~ var('high_date') ~ "'::timestamp_ntz" -%} {# Default end date for the first version of record #}
    {%- set existing_record_end_date = "dateadd(ms, -3, to_date('" ~ dss_track_date ~ "','yyyy-mm-dd')::timestamp_ntz)" -%}   {# Default end date for the current version of record #}
    {%- set existing_record_start_date = "(to_date('" ~ dss_track_date ~ "','yyyy-mm-dd')::timestamp_ntz)" -%}

    {%- set unique_key_cols_src = [] -%}
    {%- for col in business_key -%}
        {%- do unique_key_cols_src.append("src." ~ col|trim|lower) -%}
    {%- endfor -%}
    {%- do unique_key_cols_src.append("'" ~ dss_track_date ~ "'") -%}

    {%- set unique_key_cols_atr = [] -%}
    {%- for col in business_key -%}
        {%- do unique_key_cols_atr.append("atr." ~ col|trim|lower) -%}
    {%- endfor -%}
    {%- do unique_key_cols_atr.append("'" ~ dss_track_date ~ "'") -%}

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
        {{ _dim_generate_initial_load_sql(
            ref_table=ref_table, 
            exception_table=exception_table, 
            unique_key=unique_key, 
            business_key=business_key, 
            unique_key_cols_src=unique_key_cols_src, 
            ref_column_list_after_exclude=ref_column_list_after_exclude, 
            system_columns_list=system_columns_list, 
            start_date=start_date, 
            end_date=end_date, 
            dim_key_type=dim_key_type,
            _is_incremental=false
        ) }}
    {%- else -%} {# table exists and need to compare source to target data based on check_columns #}
        {{ _dim_generate_incremental_load_sql(
            this=this,
            ref_table=ref_table,
            exception_table=exception_table,
            unique_key=unique_key,
            business_key=business_key,
            unique_key_cols_src=unique_key_cols_src,
            unique_key_cols_atr=unique_key_cols_atr,
            ref_column_list_after_exclude=ref_column_list_after_exclude,
            system_columns_list=system_columns_list,
            system_columns_arr=system_columns_arr,
            start_date=start_date,
            end_date=end_date,
            existing_record_end_date=existing_record_end_date,
            existing_record_start_date=existing_record_start_date,
            track_delete=track_delete, 
            dim_key_type=dim_key_type,
            _is_incremental=true
        ) }}

    {%- endif -%}

{% endmacro %}

{% macro _dim_generate_incremental_load_sql(this, ref_table, exception_table, unique_key, business_key, unique_key_cols_src, unique_key_cols_atr, ref_column_list_after_exclude, system_columns_list, system_columns_arr, start_date, end_date, existing_record_end_date, existing_record_start_date, track_delete, dim_key_type, _is_incremental) %}
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
                    {{ dbt_utils.generate_surrogate_key(business_key) }} as {{ system_columns_list.system_business_key }},
                    {{ dbt_utils.generate_surrogate_key(fields_to_track) }} as {{ system_columns_list.system_check_columns }}
                from {{ref_table}}
            ),
            active_target_records as (
                /* Select active records from target table */
                select 
                    *,
                    {{ dbt_utils.generate_surrogate_key(business_key) }} as {{ system_columns_list.system_business_key }},
                    {{ dbt_utils.generate_surrogate_key(fields_to_track) }} as {{ system_columns_list.system_check_columns }}
                from {{this}}
                where {{ system_columns_list.system_current_flag }} = 'Y'
            ),
            {% if (exception_table != none) -%}
            exception_records as (
                select distinct
                    {% for col in business_key -%}
                    {{col}},
                    {% endfor -%}
                    {{ dbt_utils.generate_surrogate_key(business_key) }} as {{ system_columns_list.system_business_key }}
                from {{exception_table}}
            ),
            {% endif -%}
            {% if dim_key_type == "identity" %}
            max_dim_key_data as (
                select max({{ unique_key }}) as max_dim_key
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
                    'N' as {{  system_columns_list.system_delete_flag }},
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
                    'N' as {{ system_columns_list.system_delete_flag }},
                    atr.{{ system_columns_list.system_create_time }} as {{ system_columns_list.system_create_time }},
                    current_timestamp()::timestamp_ntz as {{ system_columns_list.system_update_time }},
                    'DE-ACTIVATED VERSION RECORD' as merge_category
                from active_target_records atr
                join source_records src
                    on src.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
                where atr.{{ system_columns_list.system_check_columns }} <> src.{{ system_columns_list.system_check_columns }}
                    and atr.{{ unique_key}} <> ({{ dbt_utils.generate_surrogate_key(unique_key_cols_src) }})
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
                    'N' as {{  system_columns_list.system_delete_flag }},
                    current_timestamp()::timestamp_ntz as {{  system_columns_list.system_create_time }},
                    current_timestamp()::timestamp_ntz as {{  system_columns_list.system_update_time }},
                    'NEW VERSION RECORD' as merge_category
                from source_records src
                join active_target_records atr
                    on src.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
                where atr.{{ system_columns_list.system_check_columns }} <> src.{{ system_columns_list.system_check_columns }}
            ),
            {% if track_delete == "Y" %}
            to_deactivate_deleted_records as (
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
                    'N' as {{ system_columns_list.system_delete_flag }},
                    atr.{{ system_columns_list.system_create_time }} as {{ system_columns_list.system_create_time }},
                    current_timestamp()::timestamp_ntz as {{ system_columns_list.system_update_time }},
                    'DE-ACTIVATE DELETED VERSION RECORD' as merge_category
                from active_target_records atr
                left join source_records src
                    on src.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
                {% if (exception_table != none) -%}
                left join exception_records ex
                    on ex.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
                {% endif -%}
                where 1=1
                    and src.{{ system_columns_list.system_business_key }} is null
                    {% if (exception_table != none) -%}
                    and ex.{{ system_columns_list.system_business_key }} is null
                    {% endif -%}
            ),
            deleted_records as (
                /* New version for deleted records */
                select
                    {{  prefix_fields('atr', fields_to_track) }},
                    {%- if (fields_not_in_ref|length > 1) %}
                    {{  prefix_fields('atr', fields_not_in_ref) }},
                    {% endif %}
                    {%- if (fields_not_in_target|length > 1) %}
                        {%- for col in fields_not_in_target %}
                    null as {{col}},
                        {%- endfor %}
                    {% endif -%}
                    {{ existing_record_start_date }} as {{ system_columns_list.system_start_date }},
                    {{ end_date }} as {{ system_columns_list.system_end_date }},
                    coalesce(atr.{{ system_columns_list.system_version }}, 0) + 1 as {{  system_columns_list.system_version }},
                    'Y' as {{  system_columns_list.system_current_flag }},
                    'Y' as {{  system_columns_list.system_delete_flag }},
                    current_timestamp()::timestamp_ntz as {{  system_columns_list.system_create_time }},
                    current_timestamp()::timestamp_ntz as {{  system_columns_list.system_update_time }},
                    'DELETED VERSION RECORD' as merge_category
                from active_target_records atr
                left join source_records src
                    on src.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
                {% if (exception_table != none) -%}
                left join exception_records ex
                    on ex.{{ system_columns_list.system_business_key }} = atr.{{ system_columns_list.system_business_key }}
                {% endif -%}
                where 1=1
                    and src.{{ system_columns_list.system_business_key }} is null
                    {% if (exception_table != none) -%}
                    and ex.{{ system_columns_list.system_business_key }} is null
                    {% endif -%}
            ),
            {% endif -%}
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
                {% if track_delete == "Y" %}
                union all
                select
                    {{  prefix_fields('del', full_columns_set) }}
                    , merge_category
                from deleted_records del
                {% endif -%}
            ),
            generate_key_new_records as (
                select 
                    {{ generate_dim_key(
                            unique_key_cols_src=unique_key_cols_src, 
                            unique_key_name=unique_key, 
                            dim_key_type=dim_key_type,
                            _is_incremental=true
                    ) }}
                    und.*
                from union_new_records_data und
            ),
            final as (
                select *
                from generate_key_new_records
                union all
                select 
                    der.{{unique_key}},
                    {{  prefix_fields('der', full_columns_set) }}
                    , merge_category 
                from to_deactivate_existing_records der               
                {% if track_delete == "Y" %}
                union all
                select
                    ddr.{{unique_key}},
                    {{  prefix_fields('ddr', full_columns_set) }}
                    , merge_category
                from to_deactivate_deleted_records ddr
                {% endif -%}
            )
        select *
        from final
{% endmacro %}

{% macro _dim_generate_initial_load_sql(ref_table, exception_table, unique_key, business_key, unique_key_cols_src, ref_column_list_after_exclude, system_columns_list, start_date, end_date, dim_key_type, _is_incremental) %}
        with
            source_records as (
                select *
                from {{ref_table}}
            )
            {% if (exception_table != none) -%}
            , exception_records as (
                select distinct
                    {% for col in business_key -%}
                        {{col}}{% if not loop.last %},{% endif %}
                    {% endfor -%}
                from {{exception_table}}
            )
            {% endif -%}
        select
            {{ generate_dim_key(
                    unique_key_cols_src=unique_key_cols_src, 
                    unique_key_name=unique_key, 
                    dim_key_type=dim_key_type,
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
        from source_records src
        where 1=1
            {% if (exception_table != none) -%}
            and not exists (
                select 1
                from exception_records ex
                where 1=1
                    {% for col in business_key -%}
                    and ex.{{col}} = src.{{col}}
                    {% endfor %}
            )
            {% endif -%}
{% endmacro %}