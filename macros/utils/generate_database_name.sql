{% macro generate_database_name(custom_database_name, node) %}
    {% set default_database = target.database %}
    {% if custom_database_name %}
        {%- if target.name == "sandbox" -%}
            {{- return((env_var('DBT_SANDBOX_NAME') ~ '_' ~ custom_database_name) | trim) -}}
        {%- else -%}
            {{- return(custom_database_name | trim) -}}
        {%- endif -%}
    {% else %}
        {{ return(default_database) }}
    {% endif %}
{% endmacro %}