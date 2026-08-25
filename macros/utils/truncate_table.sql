{% macro truncate_table(full_table_name) %}
    {# 
        This macro is to truncate data in a table.
        Input parameter full_table_name has to be provided in format <database_name>.<schema_name>.<table_name>.
        Returns a log message indicating whether the truncation was successful or if the table does not exist.
    #}
    {% set var_project_name = generate_project_name()|trim|upper %}
    {% if execute %}
        {% if full_table_name is not none %}
            {{ log(var_project_name ~ ': call macro truncate_table for table ' ~ full_table_name, info=True) }}
            {% set table_name_arr = full_table_name.split('.') %}
            {% set database_name = table_name_arr[0]|trim %}
            {% set schema_name = table_name_arr[1]|trim %}
            {% set table_name = table_name_arr[2]|trim %}

            {% set tb_relation = check_table_exist(full_table_name=full_table_name) %}
            {% if tb_relation is not none %}
                {% set sql = "truncate table " ~ tb_relation ~ ";" %}
                {% do run_query(sql) %}
                {{ log(var_project_name ~ ': truncate table ' ~ tb_relation ~ ' successful ✅', info=True) }}

                {% set var_model_name = tb_relation %}
                {% set var_additional_details = 'truncate table name ' ~ tb_relation|trim|upper ~ ' on target environment [' ~ target.name|trim|upper ~ ']' %}
                {% set var_started_at = get_current_timestamp() %}
                {% do add_operational_log(model_name=var_model_name, additional_details=var_additional_details, started_at=var_started_at) %}

            {% else %}
                {{ log(var_project_name ~ ': table ' ~ tb_relation ~ ' does not exist ⁉️', info=Warning) }}
            {% endif %}
        {% else %}
            {{ exceptions.raise_compiler_error(var_project_name ~ ': full_table_name is a required parameter for truncate_table macro') }}
        {% endif %}
    {% endif %}
{% endmacro %}