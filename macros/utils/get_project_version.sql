{% macro get_project_version() %}
    {%- set conf = elementary.get_runtime_config() -%}
    {{ return(conf.version) }}
{% endmacro %}