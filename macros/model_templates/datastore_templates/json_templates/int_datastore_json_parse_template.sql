/*
  Macro: int_datastore_json_parse_template

  Description:
    This macro serves as a template for generating intermediate datastore models
    that automatically detect VARIANT columns, determine their JSON structure
    (object vs array), recursively discover all keys at any nesting depth,
    and generate flattening SQL.

    New JSON properties are automatically detected on each dbt run since key
    discovery happens at compile time via full-scan OBJECT_KEYS queries.

  Arguments:
    source_model (string): A dot-separated string in the format "source_name.table_name"
                           representing the source model to be processed.

  Behavior:
    - Parses the source_model to extract source name and table name.
    - Queries information_schema.columns to detect VARIANT columns.
    - For each VARIANT column, determines if the JSON is an object or array.
    - For object types: recursively discovers all keys and extracts them as columns.
    - For array types: uses LATERAL FLATTEN to produce one row per element,
      then extracts object keys from within each array element.
    - Non-variant columns are selected as-is.
    - Applies the standard filter_data pattern with datastore_process_date filtering.

  Dependencies:
    - dbt_utils.get_filtered_columns_in_relation
    - convert_utc_to_ltz (project macro)

  Usage Example:
    {{ int_datastore_json_parse_template("my_source.my_table") }}
*/
{% macro int_datastore_json_parse_template(model_name, auto_data_type_cast=true) %}
{%- set model_database = model_name.database %}
{%- set model_schema = model_name.schema %}
{%- set model_table_name = model_name.identifier %}

{# --- Step 1: Get all columns and detect VARIANT columns --- #}
{%- set get_columns_sql %}
    select
        column_name,
        data_type
    from {{ model_database }}.information_schema.columns
    where upper(table_schema) = upper('{{ model_schema }}')
      and upper(table_name) = upper('{{ model_table_name }}')
    order by ordinal_position
{% endset -%}

{%- set columns_result = run_query(get_columns_sql) -%}

{%- set variant_columns = [] -%}
{%- set non_variant_columns = [] -%}
{%- for col in columns_result -%}
    {%- if col['DATA_TYPE'] == 'VARIANT' -%}
        {%- do variant_columns.append(col['COLUMN_NAME']|lower) -%}
    {%- else -%}
        {%- do non_variant_columns.append(col['COLUMN_NAME']|lower) -%}
    {%- endif -%}
{%- endfor -%}

{# --- If no VARIANT columns, fall back to standard select --- #}
{%- if variant_columns|length == 0 -%}
    {{ _json_parse_no_variant_sql(model_src, non_variant_columns) }}
{%- else -%}

{# --- Step 2: Determine JSON type for each VARIANT column (object vs array) --- #}
{%- set variant_types = {} -%}
{%- for vcol in variant_columns -%}
    {%- set type_detect_sql %}
        select
            case
                when count_if(typeof({{ vcol }}) = 'ARRAY') > count_if(typeof({{ vcol }}) = 'OBJECT')
                    then 'ARRAY'
                else 'OBJECT'
            end as json_type
        from {{ model_name }}
        where {{ vcol }} is not null
    {% endset -%}
    {%- set type_result = run_query(type_detect_sql) -%}
    {%- if type_result|length > 0 -%}
        {%- do variant_types.update({vcol: type_result[0]['JSON_TYPE']}) -%}
    {%- else -%}
        {%- do variant_types.update({vcol: 'OBJECT'}) -%}
    {%- endif -%}
{%- endfor -%}

{# --- Step 3: Discover keys recursively for each VARIANT column --- #}
{%- set variant_keys = {} -%}
{%- for vcol in variant_columns -%}
    {%- if variant_types[vcol] == 'OBJECT' -%}
        {# Recursive flatten to get all paths and value types for object type #}
        {%- set keys_sql %}
            select
                f.path as key_path,
                typeof(f.value) as value_type
            from {{ model_name }},
            lateral flatten(input => {{ vcol }}, recursive => true, mode => 'OBJECT') f
            where typeof(f.value) not in ('OBJECT', 'NULL_VALUE')
            qualify row_number() over (partition by f.path order by f.path) = 1
            order by f.path
        {% endset -%}
    {%- else -%}
        {# For array type: flatten array first, then recursively get keys from elements #}
        {%- set keys_sql %}
            select
                f2.path as key_path,
                typeof(f2.value) as value_type
            from {{ model_name }},
            lateral flatten(input => {{ vcol }}) f1,
            lateral flatten(input => f1.value, recursive => true, mode => 'OBJECT') f2
            where typeof(f2.value) not in ('OBJECT', 'NULL_VALUE')
            qualify row_number() over (partition by f2.path order by f2.path) = 1
            order by f2.path
        {% endset -%}
    {%- endif -%}
    {%- set keys_result = run_query(keys_sql) -%}
    {%- set col_keys = [] -%}
    {%- for row in keys_result -%}
        {%- do col_keys.append({'path': row['KEY_PATH'], 'type': row['VALUE_TYPE']}) -%}
    {%- endfor -%}
    {%- do variant_keys.update({vcol: col_keys}) -%}
{%- endfor -%}

{# --- Step 4: Separate into object columns and array columns --- #}
{%- set object_variant_columns = [] -%}
{%- set array_variant_columns = [] -%}
{%- for vcol in variant_columns -%}
    {%- if variant_types[vcol] == 'OBJECT' -%}
        {%- do object_variant_columns.append(vcol) -%}
    {%- else -%}
        {%- do array_variant_columns.append(vcol) -%}
    {%- endif -%}
{%- endfor -%}

{# --- Step 5: Generate SQL --- #}
with
    src_data as (
        select
            {# Non-variant columns #}
            {%- for col in non_variant_columns %}
            src.{{ col }},
            {%- endfor %}
            {# Object variant columns - extract each key path with proper type cast #}
            {%- for vcol in object_variant_columns %}
            {%- set keys = variant_keys[vcol] %}
            {%- for key_info in keys %}
            {%- set col_alias = _json_path_to_column_name(vcol, key_info['path']) %}
            src.{{ vcol }}:{{ _json_path_to_accessor(key_info['path']) }}::{{ _json_typeof_to_snowflake_type(key_info['type']) }} as {{ col_alias }},
            {%- endfor %}
            {%- endfor %}
            {# Array variant columns kept as-is for flattening in next CTE #}
            {%- for vcol in array_variant_columns %}
            src.{{ vcol }},
            {%- endfor %}
        from {{ model_name }} src
    )
    {# --- Generate LATERAL FLATTEN CTEs for each array variant column --- #}
    {%- set prev_cte = 'src_data' -%}
    {%- for vcol in array_variant_columns %}
    {%- set flatten_cte_name = 'flatten_' ~ vcol %}
    , {{ flatten_cte_name }} as (
        select
            {{ prev_cte }}.* exclude ({{ vcol }})
            {%- set keys = variant_keys[vcol] %}
            {%- for key_info in keys %},
            f_{{ vcol }}.value:{{ _json_path_to_accessor(key_info['path']) }}::{{ _json_typeof_to_snowflake_type(key_info['type']) }} as {{ _json_path_to_column_name(vcol, key_info['path']) }}
            {%- endfor %}
        from {{ prev_cte }},
        lateral flatten(input => {{ prev_cte }}.{{ vcol }}, outer => true) f_{{ vcol }}
    )
    {%- set prev_cte = flatten_cte_name -%}
    {%- endfor %}
    , final as (
        select
            src.*
        from {{ prev_cte }} src
    )
select *
from final
{%- endif -%}
{% endmacro %}


{# --- Helper: Convert a JSON path like "address.city" to a column name like "variant_col_address_city" --- #}
{% macro _json_path_to_column_name(variant_col, key_path) %}
    {%- set clean_path = key_path | replace('.', '_') | replace('[', '_') | replace(']', '') | replace(' ', '_') | replace('-', '_') | lower -%}
    {{- variant_col ~ '_' ~ clean_path -}}
{% endmacro %}


{# --- Helper: Convert a JSON path like "address.city" to accessor notation "address.city" (for use after colon) --- #}
{% macro _json_path_to_accessor(key_path) %}
    {#- Split path on dots, wrap each segment in bracket notation if it contains special chars -#}
    {%- set parts = key_path.split('.') -%}
    {%- set accessor_parts = [] -%}
    {%- for part in parts -%}
        {%- if part != part | replace(' ', '') | replace('-', '') -%}
            {%- do accessor_parts.append('["' ~ part ~ '"]') -%}
        {%- else -%}
            {%- do accessor_parts.append(part) -%}
        {%- endif -%}
    {%- endfor -%}
    {{- accessor_parts | join('.') -}}
{% endmacro %}


{# --- Helper: Map JSON typeof() values to Snowflake SQL data types --- #}
{% macro _json_typeof_to_snowflake_type(value_type) %}
    {%- if value_type == 'INTEGER' -%}
        number
    {%- elif value_type == 'DECIMAL' -%}
        number(38, 10)
    {%- elif value_type == 'DOUBLE' -%}
        double
    {%- elif value_type == 'BOOLEAN' -%}
        boolean
    {%- elif value_type == 'ARRAY' -%}
        array
    {%- elif value_type == 'OBJECT' -%}
        object
    {%- else -%}
        varchar
    {%- endif -%}
{% endmacro %}


{# --- Fallback: No variant columns present, standard select with filter --- #}
{% macro _json_parse_no_variant_sql(model_src, non_variant_columns) %}
with
    src_data as (
        select
            {{
                prefix_fields("src", non_variant_columns)|lower
            }}
        from {{ model_src }} src
    )
select *
from src_data
{% endmacro %}
