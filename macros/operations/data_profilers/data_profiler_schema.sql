/*
    Data profiler macro that profiles all tables within a given schema.
    Iterates over each table in the schema and calls data_profiler_model for each.

    Arguments:
    - schema_name: The fully qualified schema name (e.g., 'database.schema') to profile
    - sampling_to_profile: Number of records to sample per table (default: 20000)
*/

{% macro data_profiler_schema(schema_name, sampling_to_profile=20000) %}

{% set schema_parts = schema_name.split('.') %}

{% if schema_parts | length != 2 %}
    {{ exceptions.raise_compiler_error("schema_name must be in format 'database.schema' ❌") }}
{% endif %}

{% set db_name = schema_parts[0] | trim %}
{% set sch_name = schema_parts[1] | trim %}

{% set get_tables_sql %}
    select table_name
    from {{ db_name }}.information_schema.tables
    where upper(table_schema) = upper('{{ sch_name }}')
      and table_type in ('BASE TABLE', 'VIEW')
    order by table_name;
{% endset %}

{% set tables_result = run_query(get_tables_sql) %}

{% if tables_result | length == 0 %}
    {{ log("No tables found in schema: " ~ schema_name ~ " ❌", info=True) }}
{% else %}
    {{ log("Found " ~ tables_result | length ~ " table(s) in schema: " ~ schema_name ~ " ✅", info=True) }}

    {% for table in tables_result %}
        {% set table_name = table['TABLE_NAME'] %}
        {% set full_table_name = db_name ~ "." ~ sch_name ~ "." ~ table_name %}

        {{ log("Profiling (" ~ loop.index ~ "/" ~ tables_result | length ~ "): " ~ full_table_name, info=True) }}

        {{ data_profiler_model(full_table_name, sampling_to_profile, none) }}
    {% endfor %}

    {{ log("Schema profiling complete for: " ~ schema_name ~ " ✅", info=True) }}
{% endif %}

{% endmacro %}
