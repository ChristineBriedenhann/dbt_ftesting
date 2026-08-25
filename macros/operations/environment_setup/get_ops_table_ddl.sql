/*
    This macro returns the DDL definition for a given table name within the Operations schema.
    It accepts a `table_name` parameter and outputs the corresponding column definitions,
    data types, defaults, and comments to be used when creating or replacing operational tables.
*/

{% macro get_ops_table_ddl(table_name) %}

    {% if table_name == "operational_logs" %}
        {% set sql_ddl %}
            (
                log_id varchar default uuid_string() comment 'Unique ID for the log entry',
                invocation_id varchar comment 'Unique ID for dbt command',
                project_id varchar comment 'The dbt project ID',
                project_name varchar comment 'dbt project name',
                job_id varchar comment 'dbt job ID',
                run_id varchar comment 'Run ID for this job ID',
                run_reason varchar comment 'The specific trigger for this run, e.g. scheduled or manual kicked off by <whom>'
            )
            comment = 'Operation log table, store all job activities';
        {% endset %}
    {% elif table_name == "parameters" %}
        {% set sql_ddl %}
            (
                parameter_name varchar(300) comment 'Parameter name',
                parameter_data_type varchar(300) comment 'Data type for parameter',
                parameter_value varchar comment 'Parameter value',
                created_at timestamp_ntz comment 'System created at',
                updated_at timestamp_ntz comment 'System updated at'
            )
            comment = 'Parameter table for dbt project';
        {% endset %}
    {% elif table_name == "profile_table_level" %}
        {% set sql_ddl %}
            (
                database_name varchar(500) comment 'Database name',
                schema_name varchar(500) comment 'Schema name',
                table_name varchar(500) comment 'Table name',
                table_description varchar comment 'Table description',
                table_type varchar(500) comment 'Table type',
                row_count number comment 'Table row count',
                column_count number comment 'Table column count',
                retention_time number comment 'Retention duration',
                size_bytes number comment 'Table size',
                is_transient varchar(500) comment 'Is Transient table',
                is_temporary varchar(500) comment 'Is Temporary table',
                is_iceberg varchar(500) comment 'Is Iceberg table',
                is_dynamic varchar(500) comment 'Is Dynamic table',
                is_immutable varchar(500) comment 'Is Iummutable table',
                is_hybrid varchar(500) comment 'Is Hybrid table',
                is_interactive varchar(500) comment 'Is Interactive table',
                created_at timestamp_ntz comment 'Object created at',
                last_altered_at timestamp_ntz comment 'Last alter at',
                last_ddl_at timestamp_ntz comment 'Last DDL at',
                profile_sampling number comment 'Number of records to be profiled',
                profile_conditions varchar comment 'Profile conditions',
                profile_run_id varchar(500) comment 'Profile run ID',
                profiled_at timestamp_ntz comment 'Profile run at'
            )
            comment = 'Table profile';
        {% endset %}
    {% elif table_name == "profile_column_level" %}
        {% set sql_ddl %}
            (
                database_name varchar(500) comment 'Database name',
                schema_name varchar(500) comment 'Schema name',
                table_name varchar(500) comment 'Table name',
                column_name varchar(500) comment 'Column name',
                column_description varchar comment 'Column description',
                ordinal_position number comment 'Column position',
                data_type varchar(500) comment 'Column data type',
                is_nullable varchar(500) comment 'Allow Nullable',
                variant_type varchar(500) comment 'Variant data type, e.g. JSON or XML',
                variant_structure varchar comment 'Describe structure of variant columns',
                value_pattern varchar comment 'Value pattern',
                total_count number comment 'Value count',
                null_count number comment 'Null count',
                null_percentage float comment '% of null',
                not_null_count number comment 'Not-null count',
                distinct_count number comment 'Distinct value count',
                distinct_percentage float comment '% of distinct values',
                duplicate_count number comment 'Count duplicated values',
                min_value varchar comment 'Min value',
                max_value varchar comment 'Max value',
                min_length number comment 'Min length',
                max_length number comment 'Max length',
                avg_length float comment 'Average length',
                profile_run_id varchar(500) comment 'Profile run ID',
                profiled_at timestamp_ntz comment 'Profile run at'
            )
            comment = 'Column profile';
        {% endset %}
    {% endif %}

    {{ return(sql_ddl) }}
{% endmacro %}