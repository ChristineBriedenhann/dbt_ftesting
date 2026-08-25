{% macro rename_table(from_name, to_name) %}
    {# 
        This macro is to rename a table in the database. 
        It takes two parameters: from_name (the current name of the table) and to_name (the new name for the table).
        The input parameters have to be provided in format <database_name>.<schema_name>.<table_name>.
        It checks if the table exists before attempting to rename it, and logs the operation.
    #}
    {% set var_project_name = generate_project_name()|trim|upper %}
    {% if execute %}
        {% if from_name is not none and to_name is not none %}
            {{ log(var_project_name ~ ': call macro rename_table for table ' ~ from_name ~ ' to ' ~ to_name, info=True) }}
            {% set from_name_arr = from_name.split(".") %}
            {% set to_name_arr = to_name.split(".") %}
            {% if from_name_arr | length != 3 or to_name_arr | length != 3 %}
                {{ exceptions.raise_compiler_error(var_project_name ~ ': from_name and to_name must be in format <database_name>.<schema_name>.<table_name>') }}
            {% endif %}

            {% set from_tb_relation = check_table_exist(full_table_name=from_name) %}
            {% set to_tb_relation = check_table_exist(full_table_name=to_name) %}
            {% if from_tb_relation is not none %}
                {% if to_tb_relation is none %}
                    {% set sql = "alter table " ~ from_tb_relation ~ " rename to " ~ to_tb_relation ~ ";" %}
                    {% do run_query(sql) %}
                    {{ log(var_project_name ~ ': rename table ' ~ from_tb_relation ~ ' to ' ~ to_tb_relation ~ ' successful ✅', info=True) }}

                    {% set var_model_name = from_tb_relation %}
                    {% set var_additional_details = 'rename table name ' ~ from_tb_relation|trim|upper ~ ' to ' ~ to_tb_relation|trim|upper ~ ' on target environment [' ~ target.name|trim|upper ~ ']' %}
                    {% set var_started_at = get_current_timestamp() %}
                    {% do add_operational_log(model_name=var_model_name, additional_details=var_additional_details, started_at=var_started_at) %}
                {% else %}
                    {{ log(var_project_name ~ ': table ' ~ to_name ~ ' already exists ⁉️', info=Warning) }}
                {% endif %}
            {% else %}
                {{ log(var_project_name ~ ': table ' ~ from_name ~ ' does not exist ⁉️', info=Warning) }}
            {% endif %}
        {% else %}
            {{ exceptions.raise_compiler_error(var_project_name ~ ': from_name and to_name are required parameters for rename_table macro') }}
        {% endif %}
    {% endif %}
{% endmacro %}