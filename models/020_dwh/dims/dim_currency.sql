{%- set ref_model = ref('int_dim_currency_000') -%}
{%- set exception_table = none -%}
{%- set business_key = ["ID"] -%}
{%- set unique_key = (this.name|trim|lower) ~ "__key" -%}
{%- set dim_key_type = "identity" -%}
{%- set process_date = var('dwh_process_date') -%}
{%- set track_delete    = 'Y' -%}

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
    ref_table       = ref_model,
    exception_table = exception_table,
    unique_key      = unique_key,
    business_key    = business_key,
    dss_track_date  = process_date,
    dim_key_type    = dim_key_type,
    track_delete    = track_delete
) }}