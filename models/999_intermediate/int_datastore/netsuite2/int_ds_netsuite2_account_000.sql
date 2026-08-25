{%- set source_model = source('netsuite2','account') -%}
{{ fivetran_int_datastore_000_template(source_model) }}