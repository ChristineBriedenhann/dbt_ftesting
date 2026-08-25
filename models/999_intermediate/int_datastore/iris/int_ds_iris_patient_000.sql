------Date filter----
{% set source_model = source('iris','patient') -%}
{%- set date_column_filter="_loaded_at" -%}
{%- set key_columns_to_dedup=["patient_id"] -%}
{%- set date_column_in_timezone="UTC" -%}

{{ general_int_datastore_000_template(
    source_model=source_model, 
    date_column_filter=date_column_filter,
    date_column_in_timezone=date_column_in_timezone,
    key_columns_to_dedup=key_columns_to_dedup
) }}