/*
    This macro creates or updates a parameter in the parameters table within the operations schema.

    Args:
        parameter_name      (string): The name/key of the parameter to create or update.
        parameter_data_type (string): The data type of the parameter value. Must be one of: 'date', 'boolean', 'number', 'string'.
        parameter_value     (string): The value to assign to the parameter.
    
    Usage:
        {{ update_parameter('my_param', 'string', 'my_value') }}
        {{ update_parameter('start_date', 'date', '2024-01-01') }}
        {{ update_parameter('is_active', 'boolean', 'true') }}
        {{ update_parameter('max_retries', 'number', '5') }}
*/
{% macro update_parameter(parameter_name, parameter_value, parameter_data_type=none) %}

    {% if parameter_name and parameter_value %}
        {% set database_name = target.database %}
        {% set schema_name = generate_schema_name('operations') %} {#  #}
        {% set table_name = 'parameters' %}
        {% set full_parms_table_name = database_name ~ '.' ~ schema_name ~ '.' ~ table_name %}

        {% set parm_info_sql %}
            select object_construct(
                'parameter_name', parameter_name,
                'parameter_data_type', parameter_data_type,
                'parameter_value', parameter_value
            ) as obj_val
            from {{ full_parms_table_name }}
            where upper(parameter_name) = '{{ parameter_name|trim|upper }}';
        {% endset %}
        {% set parm_info_before_change = run_query(parm_info_sql) %}

        {% if parm_info_before_change == none and parameter_data_type == none %}
            {{ exceptions.raise_compiler_error('Error create new parameter ==> data type must be provided to create a new parameter and must be one of these values [date, boolean, number, string]  ❌') }}
        {% endif %}

        {% if parameter_data_type is not none %}
            {% if parameter_data_type|lower not in ('date','boolean','number','string') %}
                {{ exceptions.raise_compiler_error('Error create/update parameter ==> data type must be one of these values [date, boolean, number, string]  ❌') }}
            {% endif %}

            {% set _tbl_check_sql %}
                SELECT COUNT(*) AS cnt FROM {{ database_name }}.information_schema.tables
                WHERE table_schema = '{{ schema_name | upper }}' AND table_name = '{{ table_name | upper }}'
            {% endset %}
            {% set _tbl_check_result = run_query(_tbl_check_sql) %}
            {% if _tbl_check_result.columns[0][0] == 0 %}
                {{ exceptions.raise_compiler_error('Error create/update parameter ==> Parameters table does not exist yet ==> Please create it first  ❌') }}
            {% endif %}            

            {% set check_data_type_is_valid_sql %}
                select 
                    lower('{{parameter_data_type}}') as parameter_data_type,
                    case when parameter_data_type = 'date' then try_to_date('{{parameter_value}}', 'YYYY-MM-DD') else null end as date_value,
                    case when parameter_data_type = 'boolean' then try_to_boolean('{{parameter_value}}') else null end as boolean_value,
                    case when parameter_data_type = 'string' then '{{parameter_value}}' else null end as string_value,
                    case when parameter_data_type = 'number' then try_to_number('{{parameter_value}}') else null end as number_value,
                    case
                        when parameter_data_type = 'date' and date_value is not null then true
                        when parameter_data_type = 'boolean' and boolean_value is not null then true
                        when parameter_data_type = 'string' and string_value is not null then true
                        when parameter_data_type = 'number' and number_value is not null then true
                        else false
                    end as data_type_ok
            {% endset %}
            {% set rs_data_type_check = run_query(check_data_type_is_valid_sql) %}
            {% set data_type_check = rs_data_type_check.columns[5][0] %}

            {% if data_type_check == false %}
                {{ exceptions.raise_compiler_error('Invalid parameter data type or parameter value ==> Please check ❌') }}
            {% endif %}
        {% endif %}

        {% set parm_merge_sql %}
            merge into {{full_parms_table_name}} t
            using (
                select
                    '{{ parameter_name|trim|upper }}' as parameter_name,
                    {% if parameter_data_type is not none %}
                    '{{ parameter_data_type|trim|upper }}' as parameter_data_type,
                    {% endif %}
                    '{{ parameter_value }}' as parameter_value
            ) u
            on (t.parameter_name = u.parameter_name)
            when matched then update
                set
                    {% if parameter_data_type is not none %}    
                    t.parameter_data_type = u.parameter_data_type,
                    {% endif %}
                    t.parameter_value = u.parameter_value,
                    t.updated_at = current_timestamp()::timestamp_ntz
            {% if parameter_data_type is not none %}    
                when not matched then insert
                (parameter_name, parameter_data_type, parameter_value, created_at, updated_at)
                values
                (u.parameter_name, u.parameter_data_type, u.parameter_value, current_timestamp()::timestamp_ntz, current_timestamp()::timestamp_ntz)
            {% endif %}
            ;
        {% endset %}
        {% set rs = run_query(parm_merge_sql) %}

        {% set parm_info_after_change = run_query(parm_info_sql) %}
        
        {% if parm_info_before_change == none %}
            {{ log('Create new parameter successful - ' ~ parm_info_after_change.columns[0][0] ~ '✅') }}
        {% else %}
            {{ log('Update parameter successful - ✅') }}
            {{ log('==> Before change: ' ~ parm_info_before_change.columns[0][0]) }}
            {{ log('==> After change: ' ~ parm_info_after_change.columns[0][0]) }}
        {% endif %}
    {% else %}
        {{ exceptions.raise_compiler_error('Macro update_parameter because of missing parameters ==> Please check ❌') }}
    {% endif %}
{% endmacro %}