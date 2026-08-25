/*
    Data profiler macro that analyzes and profiles a dbt model's data quality and statistics.
    Validates the model exists before profiling, supports sampling and conditional filtering.

    Arguments:
    - model_name: The name of the dbt model/relation to profile
    - sampling_to_profile: A sampling expression or limit to reduce the data volume analyzed
    - conditions: Optional WHERE clause conditions to filter the data before profiling
*/

{% macro data_profiler_model(model_name, sampling_to_profile, conditions) %}

{% set relation = check_table_exist(model_name) %}

{% if relation is none %}
    {{ exceptions.raise_compiler_error("Object name is not found ❌") }}
{% endif %}

{% set model_database = relation.database %}
{% set model_schema = relation.schema %}
{% set model_table_name = relation.identifier %}

{% if sampling_to_profile is not none and sampling_to_profile != "full" %}
    {% if sampling_to_profile is not number %}
        {{ exceptions.raise_compiler_error("sampling_to_profile must be a number ❌") }}
    {% endif %}
{% endif %}

{% set profile_schema = (target.database)|trim|lower ~ "." ~ (generate_schema_name("operations")|trim|lower) %}

{% set full_temp_table_name = profile_schema ~ "." ~ (model_schema) ~ "__" ~ (model_table_name) ~ "_tmp" %}

{% set create_temp_data_sql %}
    create or replace transient table {{full_temp_table_name}}
    as
    select 
        {% if sampling_to_profile is not none and sampling_to_profile is number %}top {{sampling_to_profile}}{% endif %}
        *
    from {{relation}}
    where 1=1
        {% if conditions is not none %}and {{conditions}}{% endif %}
{% endset %}
{% do run_query(create_temp_data_sql) %}
{{ log("Create temp table " ~ full_temp_table_name|upper ~ " successful ✅") }}

{% set full_profile_table_level_name = check_table_exist(profile_schema ~ "." ~ "profile_table_level") %}
{{ log("Table profile " ~ full_profile_table_level_name|upper ~ " existed ✅") }}
{% set full_profile_column_level_name = check_table_exist(profile_schema ~ "." ~ "profile_column_level") %}
{{ log("Column profile " ~ full_profile_column_level_name|upper ~ " existed ✅") }}

{# Get column metadata from information_schema #}
{% set get_columns_sql %}
    select
        column_name,
        ordinal_position,
        data_type,
        case 
            when lower(data_type) = 'number' 
                then 'NUMBER(' || numeric_precision::varchar || ',' || numeric_scale::varchar || ')'
            when lower(data_type) = 'text'
                then (case 
                        when character_maximum_length is not null
                            then 'VARCHAR(' || character_maximum_length::varchar || ')'
                        else 'VARCHAR'
                    end)
            when lower(data_type) like 'timestamp%' or lower(data_type) like 'time%'
                then (case 
                        when datetime_precision is not null
                            then data_type || '(' || datetime_precision::varchar || ')'
                        else data_type
                    end)
            else data_type
        end as data_type_transformed,
        is_nullable,
        comment
    from {{ relation.database }}.information_schema.columns
    where upper(table_schema) = upper('{{ model_schema }}')
      and upper(table_name) = upper('{{ model_table_name }}')
    order by ordinal_position;
{% endset %}

{# Generate a unique run ID #}
{% set run_id = get_current_timestamp_for_logging() ~ '-' ~ model_database|upper ~ '.' ~ model_schema|upper ~ '.' ~ model_table_name|upper %}
{{ log("Run ID: " ~ run_id) }}

{# Get column info #}
{% set columns_result = run_query(get_columns_sql) %}
{% set column_count = columns_result | length %}
{{ log("Column count: " ~ column_count) }}

{# Insert table-level profile #}
{% set table_profile_sql %}
    insert into {{ full_profile_table_level_name }} (
        database_name,
        schema_name,
        table_name,
        table_description,
        table_type,
        row_count,
        column_count,
        retention_time,
        size_bytes,
        is_transient,
        is_temporary,
        is_iceberg,
        is_dynamic,
        is_immutable,
        is_hybrid,
        is_interactive,
        created_at,
        last_altered_at,
        last_ddl_at,
        profile_sampling,
        profile_conditions,
        profile_run_id,
        profiled_at
    )
    select
        table_catalog as database_name,
        table_schema as schema_name,
        table_name,
        comment as table_description,
        table_type,
        row_count,
        {{ column_count }} as column_count,
        retention_time,
        bytes as size_bytes,
        is_transient,
        is_temporary,
        is_iceberg,
        is_dynamic,
        is_immutable,
        is_hybrid,
        is_interactive,
        created as created_at,
        last_altered as last_altered_at,
        last_ddl as last_ddl_at,
        {% if sampling_to_profile is number %}{{sampling_to_profile}}{% else %}null{% endif %} as profile_sampling,
        {% if conditions is not none %}'{{ conditions | replace("'", "''") }}'{% else %}null{% endif %} as profile_conditions,
        '{{ run_id }}'  as profile_run_id,
        current_timestamp()::timestamp_ntz as profiled_at
    from {{ relation.database }}.information_schema.tables
    where upper(table_schema) = upper('{{ model_schema }}')
      and upper(table_name) = upper('{{ model_table_name }}');
{% endset %}
{{ log("SQL for table profile \n" ~ table_profile_sql) }}

{% do run_query(table_profile_sql) %}

{# Insert column-level profile for each column #}
{% for col in columns_result %}
    {% set col_name = col.COLUMN_NAME %}
    {% set col_position = col.ORDINAL_POSITION %}
    {% set col_type = col.DATA_TYPE %}
    {% set col_type_trans = col.DATA_TYPE_TRANSFORMED %}
    {% set col_nullable = col.IS_NULLABLE %}
    {% set col_desc = col.COMMENT %}

    {% set column_profile_sql %}
        insert into {{full_profile_column_level_name}} (
            database_name,
            schema_name,
            table_name,
            column_name,
            column_description,
            ordinal_position,
            data_type,
            is_nullable,
            variant_type,
            variant_structure,
            value_pattern,
            total_count,
            null_count,
            null_percentage,
            not_null_count,
            distinct_count,
            distinct_percentage,
            duplicate_count,
            min_value,
            max_value,
            min_length,
            max_length,
            avg_length,
            profile_run_id,
            profiled_at
        )
    {% if col_type in ('VARIANT') %}
        with
            src_data as (
                select * 
                from {{ full_temp_table_name }}
            ),
            flattened AS (
                select distinct f.path as key_path, typeof(f.value) as value_type
                from src_data,
                    lateral flatten(input => {{col_name}}, recursive => true) f
                where typeof(f.value) not in ('OBJECT', 'ARRAY')
            ),
            normalized AS (
                -- Strip array indices to get base property name
                -- e.g. "[1].mobiles[2]" => "mobiles", "[0].email" => "email"
                select
                    regexp_replace(key_path, '\\[\\d+\\]\\.?', '') as base_key,
                    -- Is the leaf itself inside an array? (path ends with property_name[n])
                    case when regexp_like(key_path, '.*[a-zA-Z_]\\[\\d+\\]$')
                        then true else false end as is_array_element,
                    value_type
                FROM flattened
            ),
            agg as (
                select
                    base_key,
                    max(is_array_element) AS is_array,
                    listagg(distinct value_type, '", "') within group (order by value_type) as types_str
                from normalized
                where value_type <> 'NULL_VALUE'
                group by base_key
            ),
            final as (
                SELECT
                    '{' || LISTAGG(
                        '"' || base_key || '": ' ||
                        CASE WHEN is_array THEN '["' || types_str || '"]'
                            ELSE '"' || types_str || '"'
                        END,
                        ', '
                    ) WITHIN GROUP (ORDER BY base_key) || '}' AS json_type_map
                FROM agg
            ) 
    {% endif %}
        select
            '{{ model_database }}'                  as database_name,
            '{{ model_schema }}'                    as schema_name,
            '{{ model_table_name }}'                as table_name,
            '{{ col_name }}'                        as column_name,
            {% if col_desc is not none %}'{{ col_desc }}'{% else %}null{% endif %}  as column_description,
            {{ col_position }}                      as ordinal_position,
            '{{ col_type_trans }}'            as data_type,
            '{{ col_nullable }}'                    as is_nullable,
            {% if col_type in ('VARIANT') %}
            case 
                when sum(case when check_json({{col_name}}::varchar) is null then 1 else 0 end) > 0
                    and sum(case when check_xml({{col_name}}::varchar) is null then 1 else 0 end) = 0 then 'JSON'
                when sum(case when check_json({{col_name}}::varchar) is null then 1 else 0 end) = 0
                    and sum(case when check_xml({{col_name}}::varchar) is null then 1 else 0 end) > 0 then 'XML'
                when sum(case when check_json({{col_name}}::varchar) is null then 1 else 0 end) > 0
                    and sum(case when check_xml({{col_name}}::varchar) is null then 1 else 0 end) > 0 then 'JSON & XML'
            else 'OTHER'
            end                                     as variant_type,
            {% else %}
            null                                    as variant_type,
            {% endif %}
            {% if col_type in ('VARIANT') %}
            (select json_type_map from final) as variant_structure,
            null as value_pattern,
            {% else %}
            null as variant_structure,
            mode({{ string_value_pattern_detection(col_name) }}) as value_pattern,
            {% endif %}
            count(*)                                as total_count,
            sum(case when {{ col_name }} is null then 1 else 0 end) as null_count,
            round(sum(case when {{ col_name }} is null then 1 else 0 end) * 100.0 / nullif(count(*), 0), 2) as null_percentage,
            sum(case when {{ col_name }} is not null then 1 else 0 end) as not_null_count,
            count(distinct {{ col_name }})        as distinct_count,
            round(count(distinct {{ col_name }}) * 100.0 / nullif(count(*), 0), 2) as distinct_percentage,
            count(*) - count(distinct {{ col_name }}) as duplicate_count,
            {% if col_type in ('NUMBER', 'FLOAT', 'INT', 'INTEGER', 'BIGINT', 'SMALLINT', 'DECIMAL', 'NUMERIC', 'DOUBLE', 'REAL') %}
                cast(min({{ col_name }}) as varchar) as min_value,
                cast(max({{ col_name }}) as varchar) as max_value,
                null as min_length,
                null as max_length,
                null as avg_length,
            {% elif col_type in ('DATE', 'TIMESTAMP', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ') %}
                cast(min({{ col_name }}) as varchar) as min_value,
                cast(max({{ col_name }}) as varchar) as max_value,
                null as min_length,
                null as max_length,
                null as avg_length,
            {% else %}
                cast(min({{ col_name }}) as varchar) as min_value,
                cast(max({{ col_name }}) as varchar) as max_value,
                min(length({{ col_name }})) as min_length,
                max(length({{ col_name }})) as max_length,
                round(avg(length({{ col_name }})), 2) as avg_length,
            {% endif %}
            '{{ run_id }}'                          as profile_run_id,
            current_timestamp()::timestamp_ntz      as profiled_at
        FROM {{ full_temp_table_name }};
    {% endset %}
    {{ log("SQL for column profile \n" ~ column_profile_sql) }}

    {% do run_query(column_profile_sql) %}
{% endfor %}

{% set drop_temp_data_sql %}
    drop table if exists {{full_temp_table_name}};
{% endset %}
{% do run_query(drop_temp_data_sql) %}

{{ log("Data profiling complete for model: " ~ model_name ~ " | Run ID: " ~ run_id, info=True) }}

{% endmacro %}
