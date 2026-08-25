{% set start_year = 2000 %}
{% set end_year = 2040 %}
{% set unique_key = (this.name|trim|lower) ~ "__key" %}

{{
    config(
        materialized='incremental',
        unique_key=unique_key,
        incremental_strategy='delete+insert',
        on_schema_change='append_new_columns',
        tags=["dim_date"]
    )
}}

{{ generate_dim_date_template(
        start_year=start_year,
        end_year=end_year
)}}