{% macro generate_project_name() %}
    {# This macro generates the project name based on the dbt_project.yml definition. #}
    {# It retrieves the project name from the project metadata. #}
    {%- set project_name = project_name -%}
    {{ return(project_name) }}
{% endmacro %}