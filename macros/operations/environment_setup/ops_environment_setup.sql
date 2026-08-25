{% macro ops_environment_setup(rebuild=false) %}
    {% set database_name = target.database | trim | upper %}

    {% set operation_schema = generate_schema_name('operations') %}

    {{ log("ops_environment_setup: starting (rebuild=" ~ rebuild ~ ", database=" ~ database_name ~ ", schema=" ~ operation_schema ~ ")", info=True) }}

    {% if rebuild %}
        {% set drop_ops_schema_sql %}
            drop schema if exists {{database_name ~ '.' ~ operation_schema}};
        {% endset %}
        {% do run_query(drop_ops_schema_sql) %}
        {{ log("ops_environment_setup: drop schema succeeded", info=True) }}
    {% endif %}
    
    {{ create_ops_table(database_name=database_name, schema_name=operation_schema, table_name='parameters') }}
    {{ log("ops_environment_setup: create table parameters successfully", info=True) }}

    {{ create_ops_table(database_name=database_name, schema_name=operation_schema, table_name='profile_table_level') }}
    {{ log("ops_environment_setup: create table profile_table_level successfully", info=True) }}
    {{ create_ops_table(database_name=database_name, schema_name=operation_schema, table_name='profile_column_level') }}
    {{ log("ops_environment_setup: create table profile_column_level successfully", info=True) }}

    {# Verify parameters table exists using direct SQL (adapter cache may be stale for newly created tables) #}
    {% set verify_sql %}
        SELECT COUNT(*) AS cnt FROM {{ database_name }}.information_schema.tables
        WHERE table_schema = '{{ operation_schema | upper }}' AND table_name = 'PARAMETERS'
    {% endset %}
    {% set verify_result = run_query(verify_sql) %}
    {{ log("check parameters table exists ==> " ~ (verify_result.columns[0][0] > 0)) }}
    
    {{ update_parameter(parameter_name='datastore_process_date', parameter_data_type='date', parameter_value='2026-07-01') }}
    {{ log("ops_environment_setup: create parameter \"datastore_process_date\" successfully", info=True) }}
    {{ update_parameter(parameter_name='dwh_process_date', parameter_data_type='date', parameter_value='2026-07-01') }}
    {{ log("ops_environment_setup: create parameter \"dwh_process_date\" successfully", info=True) }}
    {{ update_parameter(parameter_name='datastore_full_refresh', parameter_data_type='string', parameter_value='YES') }}
    {{ log("ops_environment_setup: create parameter \"datastore_full_refresh\" successfully", info=True) }}
    {{ update_parameter(parameter_name='dwh_full_refresh', parameter_data_type='string', parameter_value='YES') }}
    {{ log("ops_environment_setup: create parameter \"dwh_full_refresh\" successfully", info=True) }}
{% endmacro %}
