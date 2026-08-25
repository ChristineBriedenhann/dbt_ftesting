{% macro drop_view(view_name) %}
    {% set var_project_name = generate_project_name() | trim | upper %}

    {% set arr_view_name = view_name.split('.') %}
    {% set db_name = arr_view_name[0] | lower %}
    {% set schema_name = arr_view_name[1] | lower %}
    {% set vw_name = arr_view_name[2] | lower %}

    {% if execute %}
        {% if view_name %}
            {{log(var_project_name ~ ': calling macro drop_view')}}

            {% set verify_view_sql %}
                select *
                from {{db_name}}.information_schema.tables
                where 1=1
                    and lower(table_catalog) = lower('{{db_name}}')
                    and lower(table_schema) = lower('{{schema_name}}')
                    and lower(table_name) = lower('{{vw_name}}')
                    and lower(table_type) = 'view'
            {% endset %}
            
            {% set vw_relation = run_query(verify_view_sql) %}
            {% if vw_relation|length > 0 %}
                {% set drop_view_sql %}
                    BEGIN
                        DROP VIEW IF EXISTS {{ vw_relation }};
                    EXCEPTION
                        WHEN OTHER THEN
                            LET err_msg := SQLERRM;
                            RETURN err_msg;
                    END;
                {% endset %}

                {% set result = run_query(drop_view_sql) %}

                {% set var_started_at = get_current_timestamp_for_logging() %}
                {% if result and result.columns[0] %}
                    {{ log(var_project_name ~ ': drop_view failed - ' ~ result.rows[0][0], info=True) }}
                {% else %}
                    {{ log(var_project_name ~ ': drop_view completed - ' ~ vw_relation, info=True) }}
                {% endif %}

            {% else %}
                {{ log(var_project_name ~ ': view ' ~ view_name ~ ' does not exist ⁉️', info=True) }}
            {% endif %}
        {% else %}
            {{ exceptions.raise_compiler_error(var_project_name ~ ': view_name is a required parameter for drop_view macro') }}
        {% endif %}
    {% endif %}
{% endmacro %}