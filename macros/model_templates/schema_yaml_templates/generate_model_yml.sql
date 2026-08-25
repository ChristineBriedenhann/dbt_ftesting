/*
    Generates a YAML schema definition by querying the columns of a dbt source or ref model.
    Optionally uses Snowflake Cortex AI to generate descriptions when comments are missing.

    Usage:
        dbt run-operation generate_model_yml --args '{"model_name": "iris.allergy", "model_type": "source"}'
        dbt run-operation generate_model_yml --args '{"model_name": "iris.allergy", "model_type": "source", "use_ai": true}'
        dbt run-operation generate_model_yml --args '{"model_name": "iris.allergy", "model_type": "source", "use_ai": true, "ai_model": "llama3.1-70b"}'
        dbt run-operation generate_model_yml --args '{"model_name": "stg_iris__allergy", "model_type": "ref", "use_ai": true}'

    Args:
        model_name: For source: "source_name.table_name" (e.g., "iris.allergy").
                    For ref: the dbt model name (e.g., "stg_iris__allergy").
        model_type: "source" or "ref". Defaults to "source".
        use_ai:     If true, uses SNOWFLAKE.CORTEX.COMPLETE to generate descriptions
                    for table and columns when no comment exists. Defaults to false.
        ai_model:   The Cortex LLM model to use for AI generation. Defaults to "claude-haiku-4-5".
*/
{% macro generate_model_yml(model_name, model_type="source", use_ai=false, ai_model="mistral-large2") %}

{# Resolve the relation based on model_type #}
{% if model_type == "source" %}
    {% set parts = model_name.split(".") %}
    {% if parts | length != 2 %}
        {{ log("ERROR: For model_type='source', model_name must be 'source_name.table_name' (e.g., 'iris.allergy')", info=true) }}
        {{ return("") }}
    {% endif %}
    {% set src_name = parts[0] %}
    {% set tbl_name = parts[1] %}
    {% set relation = source(src_name, tbl_name) %}
{% elif model_type == "ref" %}
    {% set relation = ref(model_name) %}
{% else %}
    {{ log("ERROR: model_type must be 'source' or 'ref'. Got: " ~ model_type, info=true) }}
    {{ return("") }}
{% endif %}

{# Query table comment #}
{% set table_comment_query %}
    select comment
    from {{ relation.database }}.information_schema.tables
    where table_schema = '{{ relation.schema | upper }}'
      and table_name = '{{ relation.identifier | upper }}'
{% endset %}
{% set table_comment_result = run_query(table_comment_query) %}
{% set table_description = table_comment_result.columns[0].values()[0] if table_comment_result | length > 0 else '' %}

{# If no table comment and AI is enabled, generate one #}
{% if not table_description and use_ai %}
    {% set ai_table_query %}
        select snowflake.cortex.complete(
            '{{ ai_model }}',
            'Generate a concise one-sentence description for a database table named "{{ relation.identifier }}". '
            --|| 'The table is in schema "{{ relation.schema }}" and database "{{ relation.database }}". '
            --|| 'No need to add a line #{{relation.identifier}} table description before description.'
            || 'Base on data transformation on the model (DML & SQL) to provide a purpose of the model'
            || 'Only return the description text, no quotes or extra formatting.'
        ) as description
    {% endset %}
    {% set ai_table_result = run_query(ai_table_query) %}
    {% set table_description = ai_table_result.columns[0].values()[0] | trim if ai_table_result | length > 0 else '' %}
{% endif %}

{# Query columns from the resolved relation #}
{% set query %}
    select
        column_name,
        data_type,
        numeric_precision,
        numeric_scale,
        character_maximum_length,
        datetime_precision,
        comment
    from {{ relation.database }}.information_schema.columns
    where table_schema = '{{ relation.schema | upper }}'
      and table_name = '{{ relation.identifier | upper }}'
    order by ordinal_position
{% endset %}

{% set results = run_query(query) %}

{% if results | length == 0 %}
    {{ log("No columns found for " ~ relation, info=true) }}
{% else %}

    {# If AI enabled, generate descriptions for columns missing comments in a single call #}
    {% set col_descriptions = {} %}
    {% if use_ai %}
        {% set cols_without_comment = [] %}
        {% for row in results %}
            {% if not row['COMMENT'] %}
                {% do cols_without_comment.append(row['COLUMN_NAME']) %}
            {% endif %}
        {% endfor %}

        {% if cols_without_comment | length > 0 %}
            {% set col_list_str = cols_without_comment | join(", ") %}
            {% set ai_col_query %}
                select snowflake.cortex.complete(
                    '{{ ai_model }}',
                    'For the database table "{{ relation.identifier }}" in schema "{{ relation.schema }}", '
                    || 'generate a concise one-sentence description (less than 300 words) for each of these columns: {{ col_list_str }}. '
                    || 'Return the result as one-line per column in the format: COLUMN_NAME: description. '
                    || 'No numbering, no quotes, no extra formatting.'
                ) as descriptions
            {% endset %}
            {% set ai_col_result = run_query(ai_col_query) %}
            {% set ai_text = ai_col_result.columns[0].values()[0] if ai_col_result | length > 0 else '' %}

            {# Parse the AI response into a dictionary #}
            {% for line in ai_text.split("\n") %}
                {% if ":" in line %}
                    {% set parts = line.split(":", 1) %}
                    {% set col_key = parts[0] | trim | upper %}
                    {% set col_val = parts[1] | trim %}
                    {% do col_descriptions.update({col_key: col_val}) %}
                {% endif %}
            {% endfor %}
        {% endif %}
    {% endif %}

    {% set yaml_lines = [] %}
    {% do yaml_lines.append("version: 2") %}
    {% do yaml_lines.append("") %}

    {% set tbl_desc = table_description if table_description else '' %}

    {% if model_type == "source" %}
        {% do yaml_lines.append("sources:") %}
        {% do yaml_lines.append("  - name: " ~ src_name) %}
        {% do yaml_lines.append("    tables:") %}
        {% do yaml_lines.append("      - name: " ~ tbl_name) %}
        {% do yaml_lines.append("        description: |") %}
        {% do yaml_lines.append("          " ~ tbl_desc) %}
        {% do yaml_lines.append("        columns:") %}
        {% set col_indent = "          " %}
    {% else %}
        {% do yaml_lines.append("models:") %}
        {% do yaml_lines.append("  - name: " ~ model_name) %}
        {% do yaml_lines.append("    description: |") %}
        {% do yaml_lines.append("      " ~ tbl_desc) %}
        {% do yaml_lines.append("    columns:") %}
        {% set col_indent = "      " %}
    {% endif %}

    {% for row in results %}
        {% set col_name = row['COLUMN_NAME'] | lower %}
        {% set raw_type = row['DATA_TYPE'] %}
        {% set precision = row['NUMERIC_PRECISION'] %}
        {% set scale = row['NUMERIC_SCALE'] %}

        {% set char_length = row['CHARACTER_MAXIMUM_LENGTH'] %}
        {% set dt_precision = row['DATETIME_PRECISION'] %}

        {# Format data type with precision/scale/length where applicable #}
        {% if raw_type == 'NUMBER' and precision is not none %}
            {% set data_type = "NUMBER(" ~ precision ~ "," ~ scale ~ ")" %}
        {% elif raw_type == 'TEXT' %}
            {% if char_length is not none and char_length != 16777216 %}
                {% set data_type = "VARCHAR(" ~ char_length ~ ")" %}
            {% else %}
                {% set data_type = "VARCHAR" %}
            {% endif %}
        {% elif raw_type in ['TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ'] %}
            {% if dt_precision is not none and dt_precision != 9 %}
                {% set data_type = raw_type ~ "(" ~ dt_precision ~ ")" %}
            {% else %}
                {% set data_type = raw_type %}
            {% endif %}
        {% elif raw_type == 'TIME' %}
            {% if dt_precision is not none and dt_precision != 9 %}
                {% set data_type = "TIME(" ~ dt_precision ~ ")" %}
            {% else %}
                {% set data_type = "TIME" %}
            {% endif %}
        {% else %}
            {% set data_type = raw_type %}
        {% endif %}

        {# Use comment if available, otherwise use AI-generated description #}
        {% set col_comment = row['COMMENT'] if row['COMMENT'] else col_descriptions.get(col_name | upper, '') %}

        {% do yaml_lines.append(col_indent ~ "- name: " ~ col_name) %}
        {% do yaml_lines.append(col_indent ~ "  description: |") %}
        {% do yaml_lines.append(col_indent ~ "    " ~ col_comment) %}
        {% do yaml_lines.append(col_indent ~ "  data_type: " ~ data_type | lower) %}
        {% do yaml_lines.append(col_indent ~ "") %} {# Create a blank line between column #}
    {% endfor %}

    {% set output = yaml_lines | join("\n") %}
    {{ log(output, info=true) }}
{% endif %}

{% endmacro %}
