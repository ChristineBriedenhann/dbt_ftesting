{% macro system_columns_list() %}
    {% set system_columns_list = {
        'system_start_date': 'dbt_start_date',
        'system_end_date': 'dbt_end_date',
        'system_current_flag': 'dbt_current_flag',
        'system_create_time': 'dbt_create_time',
        'system_update_time': 'dbt_update_time',
        'system_delete_flag': 'dbt_delete_flag',
        'system_version': 'dbt_version',
        'system_business_key': 'dbt_business_key',
        'system_check_columns': 'scd_check_columns',
        'system_sf_load_date': '_sf_load_at'
    } %}
    {{ return (system_columns_list) }}
{% endmacro %}