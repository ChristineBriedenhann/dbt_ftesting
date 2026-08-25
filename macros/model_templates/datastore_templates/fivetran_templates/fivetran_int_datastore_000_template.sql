/*
This macro generates a standardized intermediate datastore transformation for Fivetran-sourced models.
It checks whether the source model already contains the `_fivetran_start` column (used for incremental/SCD logic),
and conditionally applies the appropriate transformation logic based on its presence.

Parameters:
  - source_model: The source relation to build the intermediate model from.
*/
{% macro fivetran_int_datastore_000_template(source_model) %}

{%- set ref_column_list = (dbt_utils.get_filtered_columns_in_relation(source_model))|lower|list -%}

{%- if "_fivetran_start" not in ref_column_list %}
with
    src_data as (
        select
            {{
                prefix_fields("src", ref_column_list)|lower
            }}
            , {{ convert_utc_to_ltz('_fivetran_synced') -}} as _fivetran_synced_ltz
        from {{ source_model }} src
    ),
    filter_data as (
        select
            src.*
        from src_data src
        {%- if var('datastore_full_refresh')|trim|lower == "yes" %}
        where 1=1
            and _fivetran_synced_ltz::date <= '{{var('datastore_process_date')}}'::date --get all records <= datastore_process_date for full-refresh
        {%- else %}
        where 1=1
            and _fivetran_synced_ltz::date = '{{var('datastore_process_date')}}'::date --only get new records for incremental load
        {%- endif %}
    )
select *
from filter_data
{%- else %}
with
    src_data as (
        select
            {{
                prefix_fields("src", ref_column_list)|lower
            }}
            , {{ convert_utc_to_ltz('_fivetran_synced') -}} as _fivetran_synced_ltz
            , {{ convert_utc_to_ltz('_fivetran_start') -}} as _fivetran_start_ltz
            , {{ convert_utc_to_ltz('_fivetran_end') -}} as _fivetran_end_ltz
        from {{ source_model }} src
    ),
    filter_data as (
        select
            src.*
        from src_data src
        {%- if var('datastore_full_refresh')|trim|lower == "yes" %}
        where 1=1
            and _fivetran_synced_ltz::date <= '{{var('datastore_process_date')}}'::date --get all records <= datastore_process_date for full-refresh
        {%- else %}
        where 1=1
            and _fivetran_synced_ltz::date = '{{var('datastore_process_date')}}'::date --only get new records for incremental load
        {%- endif %}
    )
select *
from filter_data
{%- endif %}
{% endmacro %}