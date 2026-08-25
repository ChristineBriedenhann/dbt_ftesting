{% set source_table = ref('int_ds_netsuite2_currency_000') %}
{% set business_key = ['ID'] %}
{% set exclude_columns = [] %}
{% set unique_key = (this.name|trim|lower) ~ "__key" %}
{% set datastore_key_type = "identity" %}

{{
    config(
        materialized='incremental',
        unique_key=unique_key,
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

{{ fivetran_datastore_template(
        this=this, 
        ref_table=source_table, 
        unique_key=unique_key, 
        business_key=business_key, 
        exclude_columns=exclude_columns,
        datastore_key_type=datastore_key_type
)}}