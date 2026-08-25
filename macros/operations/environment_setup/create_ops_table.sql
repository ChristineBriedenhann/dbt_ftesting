/*
    This macro creates an operational (ops) table in the specified location.

    Parameters:
        database_name (str)  : The target database where the table will be created.
        schema_name   (str)  : The target schema within the database.
        table_name    (str)  : The name of the table to be created.
        force_replace (bool) : If true, the existing table will be dropped and
                            recreated. Defaults to false.
    
    Behavior:
        - Logs the macro invocation using the current project name.
        - Constructs the fully qualified table name as database.schema.table.
        - Checks whether the table already exists before attempting creation.
        - If force_replace is enabled, replaces the table regardless of existence.
        - Only executes during the dbt run phase (guarded by the execute flag).
*/
{% macro create_ops_table(database_name, schema_name, table_name, force_replace=false) %}

    {% set var_project_name = generate_project_name() %}

    {%- if execute -%}
        {% if database_name and schema_name and table_name %}
            {{ log(var_project_name ~ ': calling macro create_ops_table') }}
            {% set full_table_name = database_name ~ '.' ~ schema_name ~ '.' ~ table_name %}
            
            {% if check_table_exist(full_table_name) == none %}
                {% if force_replace %}
                    {% set table_sql %}
                        create schema if not exists {{ database_name ~ '.' ~ schema_name}};
                        create or replace table {{ full_table_name }}
                        {{ get_ops_table_ddl(table_name) }}
                    {% endset %}
                    {{ log('Table DDL - ' ~ table_sql) }}
                    {% do run_query(table_sql) %}
                {% else %}
                    {% set table_sql %}
                        create schema if not exists {{ database_name ~ '.' ~ schema_name}};
                        create or alter table {{ full_table_name }}
                        {{ get_ops_table_ddl(table_name) }}
                    {% endset %}
                    {{ log('Table DDL - ' ~ table_sql) }}
                    {% do run_query(table_sql) %}
                {% endif %}
            {% else %}
                {% set table_sql %}
                    create schema if not exists {{ database_name ~ '.' ~ schema_name}};
                    create or alter table {{ full_table_name }}
                    {{ get_ops_table_ddl(table_name) }}
                {% endset %}
                {{ log('Table DDL - ' ~ table_sql) }}
                {% do run_query(table_sql) %}
            {% endif %}
        {% else %}
            {{ exceptions.raise_compiler_error(' Macro create_ops_table failed because of missing parameters') }}
        {% endif %}
    {% endif %}
{% endmacro %}