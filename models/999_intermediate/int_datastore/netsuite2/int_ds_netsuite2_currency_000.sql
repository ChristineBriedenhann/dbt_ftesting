{%- set source_model = source('netsuite2','currency') -%}
{{ fivetran_int_datastore_000_template(source_model) }}