{% macro get_parameter_value(parameter_name) %}
    {#
        Retrieves the value of a named parameter from the centralized parameters table.

        This macro queries the `operations.parameters` table in the target database
        to look up a configuration value by its parameter name. Useful for storing
        and accessing shared configuration values across dbt models without hardcoding them.

        Args:
            parameter_name (str): The name of the parameter to look up.

        Returns:
            The value associated with the given parameter name, or none if not found.
    #}

    {% if execute %}\
        {% if parameter_name %}
            {% set database_name = target.database %}
            {% set schema_name = generate_schema_name('operations') %}
            {% set table_name = 'parameters' %}
            {% set full_parms_table_name = database_name ~ '.' ~ schema_name ~ '.' ~ table_name %}

            {% set get_parm_sql %}
                select parameter_value
                from {{full_parms_table_name}}
                where parameter_name = upper('{{parameter_name}}')
                qualify row_number() over (partition by parameter_name order by updated_at desc) = 1;
            {% endset %}
            {% set result = run_query(get_parm_sql) %}
            {% set parm_val = result[0][0] %}

            {% if parm_val == none %}
                {{ exceptions.raise_compiler_error('Could not find value for parameter name: ' ~ parameter_name ~ '❌') }}
            {% else %}
                {{ return(parm_val) }}
            {% endif %}
        {% else %}
            {{ exceptions.raise_compiler_error('macro get_parameter_value failed because of missing parameter') }}
        {% endif %}
    {% endif %}
{% endmacro %}