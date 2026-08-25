/*
    Macro: general_int_datastore_000_template

    Description:
        Template macro for building an intermediate datastore layer.
        Selects all columns from the source model, applies an optional date
        column filter, and deduplicates records based on the specified key
        columns.

    Parameters:
        source_model        (required) - The source relation/model to pull data from.
        date_column_filter  (required) - The date column used to filter or partition the data.
        key_columns_to_dedup (optional, default: none) - A list of columns used
                             to identify duplicate records. If none, no
                             deduplication is applied.

    Usage:
        {{ general_int_datastore_000_template(
            source_model=ref('my_source_model'),
            date_column_filter='created_at',
            key_columns_to_dedup=['id', 'created_at']
        ) }}
*/

{% macro general_int_datastore_000_template(source_model, date_column_filter, date_column_in_timezone, key_columns_to_dedup=none) %}

{%- set ref_column_list = dbt_utils.get_filtered_columns_in_relation(source_model) -%}
{%- set system_columns_list = system_columns_list() -%}

with
    src_data as (
        select
            {{
                prefix_fields("src", ref_column_list)|lower
            }}
            , {{ convert_ts_timezone(
                column_name=date_column_filter, 
                source_timezone=date_column_in_timezone, 
                target_timezone=var("project_timezone")
            ) -}} as {{system_columns_list.system_sf_load_date}}
        from {{ source_model }} src
    ),
    filter_data as (
        select
            src.*
        from src_data src
        {%- if var('datastore_full_refresh')|trim|lower == "yes" %}
        where 1=1
            and src.{{system_columns_list.system_sf_load_date}}::date <= '{{var('datastore_process_date')}}'::date --get all records <= datastore_process_date for full-refresh
        {%- else %}
        where 1=1
            and src.{{system_columns_list.system_sf_load_date}}::date = '{{var('datastore_process_date')}}'::date --only get new records for incremental load
        {%- endif %}
    )
    {% if key_columns_to_dedup is not none %},
    dedup_data as (
        select *
        from filter_data
        qualify row_number() over (partition by {{key_columns_to_dedup|join(",")}} order by {{system_columns_list.system_sf_load_date}} desc) = 1
    )
select *
from dedup_data
    {% else %}
select *
from filter_data
    {% endif %}

{% endmacro %}