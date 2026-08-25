/*
    This macro overrides dbt's default schema name generation behavior.
    Instead of prefixing the custom schema with the target schema name,
    it uses the custom schema name directly (or the default target schema if none is provided).

    In sandbox environments, it prefixes the schema with the current user's name
    (from DBT_CURRENT_USER env var) to avoid schema collisions between developers.

    Args:
        custom_schema_name (str|None): The custom schema specified in dbt_project.yml or model config.
        node (node): The dbt node object (model, seed, snapshot, etc.) being compiled.

    Returns:
        str: The resolved schema name:
            - sandbox target:     <DBT_CURRENT_USER>_<custom_schema_name>
            - other targets:      <custom_schema_name>  (if set)
            - no custom schema:   <target.schema>       (default fallback)
*/
{% macro generate_schema_name(custom_schema_name, node) -%}
    
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{- default_schema -}}
    {%- else -%}
        {%- if target.name == "sandbox" -%}
            {{- (env_var('DBT_CURRENT_USER') ~ '_' ~ custom_schema_name) | trim -}}
        {%- else -%}
            {{- custom_schema_name | trim -}}
        {%- endif -%}
    {%- endif -%}
{%- endmacro %}
