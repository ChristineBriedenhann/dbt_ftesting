/*
    Macro: propagate_column_tags

    Description:
        Propagates Snowflake object tags and dbt meta tags from source columns
        to downstream model columns. Traces lineage back through the dbt graph
        to find the original source table(s), queries any tags applied to those
        source columns, and applies them to matching columns on the target model.

    Supports:
        - Snowflake object tags (applied via ALTER TABLE SET TAG)
        - dbt meta tags (defined as meta.snowflake_tags on columns in YAML)
        - Column name matching (same name in source and target)
        - Custom column mapping for renamed columns (via meta.tag_column_mapping)

    Invocation Modes:

        1. Post-hook (automatic after model materializes):
            # dbt_project.yml
            models:
              my_project:
                010_datastore:
                  +post-hook:
                    - "{{ propagate_column_tags() }}"

        2. Run-operation (manual):
            dbt run-operation propagate_tags_for_model --args '{"model_name": "ds_iris_patient"}'

    Column Mapping Config:
        Define in model meta to map renamed columns:

        # In model YAML schema
        models:
          - name: ds_iris_patient
            meta:
              tag_column_mapping:
                first_name: patient_first_name
                last_name: patient_last_name

        # Or in model SQL config
        {{ config(meta={'tag_column_mapping': {'first_name': 'patient_first_name'}}) }}

    dbt Meta Tag Config:
        Define Snowflake tags in source YAML to apply via dbt:

        sources:
          - name: iris
            tables:
              - name: patient
                columns:
                  - name: ssn_last4
                    meta:
                      snowflake_tags:
                        pii_type: "SSN"
                        sensitivity: "HIGH"

    Notes:
        - Tags are applied using ALTER TABLE ... ALTER COLUMN ... SET TAG
        - If a tag already exists on the target column, it will be overwritten
        - Columns that don't exist on the target are silently skipped
        - Requires appropriate privileges: TAG usage and ALTER TABLE on target
*/


{% macro propagate_column_tags(column_mapping=none) %}
    {#
        Main macro - called as a post-hook or directly.
        When used as a post-hook, `this` is available and refers to the current model.
    #}
    {%- if execute -%}
        {%- set target_relation = this -%}
        {%- set target_db = target_relation.database -%}
        {%- set target_schema = target_relation.schema -%}
        {%- set target_table = target_relation.identifier -%}

        {# Resolve column mapping from model config meta if not passed directly #}
        {%- set model_meta = config.get('meta', {}) -%}
        {%- if column_mapping is none -%}
            {%- set column_mapping = model_meta.get('tag_column_mapping', {}) -%}
        {%- endif -%}

        {# Get target columns for matching #}
        {%- set target_columns_query %}
            select column_name
            from {{ target_db }}.information_schema.columns
            where table_schema = '{{ target_schema | upper }}'
              and table_name = '{{ target_table | upper }}'
        {% endset -%}
        {%- set target_cols_result = run_query(target_columns_query) -%}
        {%- set target_columns = [] -%}
        {%- for row in target_cols_result -%}
            {%- do target_columns.append(row['COLUMN_NAME'] | lower) -%}
        {%- endfor -%}

        {# Find source nodes by tracing lineage through the graph #}
        {%- set source_nodes = _find_source_nodes(model) -%}

        {# Collect tags from Snowflake object tags on sources #}
        {%- set tags_to_apply = [] -%}
        {%- for src_node in source_nodes -%}
            {%- set src_relation = api.Relation.create(
                database=src_node.get('database'),
                schema=src_node.get('schema'),
                identifier=src_node.get('identifier')
            ) -%}
            {%- set sf_tags = _get_snowflake_column_tags(src_relation) -%}
            {%- for tag_info in sf_tags -%}
                {%- do tags_to_apply.append(tag_info) -%}
            {%- endfor -%}

            {# Collect tags from dbt meta (snowflake_tags on columns) #}
            {%- set meta_tags = _get_dbt_meta_tags(src_node) -%}
            {%- for tag_info in meta_tags -%}
                {%- do tags_to_apply.append(tag_info) -%}
            {%- endfor -%}
        {%- endfor -%}

        {# Apply tags to matching target columns #}
        {%- for tag_info in tags_to_apply -%}
            {%- set source_col = tag_info['column_name'] | lower -%}
            {%- set tag_name = tag_info['tag_name'] -%}
            {%- set tag_value = tag_info['tag_value'] -%}
            {%- set tag_ref = tag_info['tag_reference'] -%}

            {# Determine the target column name via direct match or mapping #}
            {%- set target_col = none -%}
            {%- if source_col in target_columns -%}
                {%- set target_col = source_col -%}
            {%- elif source_col in column_mapping -%}
                {%- set mapped_col = column_mapping[source_col] | lower -%}
                {%- if mapped_col in target_columns -%}
                    {%- set target_col = mapped_col -%}
                {%- endif -%}
            {%- endif -%}

            {%- if target_col is not none -%}
                {%- set alter_sql %}
                    ALTER TABLE {{ target_db }}.{{ target_schema }}.{{ target_table }}
                        ALTER COLUMN {{ target_col | upper }}
                        SET TAG {{ tag_ref }} = '{{ tag_value | replace("'", "''") }}'
                {% endset -%}
                {%- do run_query(alter_sql) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}
{% endmacro %}


{% macro _find_source_nodes(current_model) %}
    {#
        Recursively traces lineage from the current model back to source nodes.
        Returns a list of dicts with database, schema, identifier, and graph_node.
    #}
    {%- set sources_found = [] -%}
    {%- set visited = [] -%}
    {%- do _trace_lineage(current_model, sources_found, visited) -%}
    {{ return(sources_found) }}
{% endmacro %}


{% macro _trace_lineage(node, sources_found, visited) %}
    {%- set node_id = node.unique_id if node.unique_id is defined else node -%}
    {%- if node_id in visited -%}
        {{ return("") }}
    {%- endif -%}
    {%- do visited.append(node_id) -%}

    {%- set depends_on_nodes = node.depends_on.nodes if node.depends_on is defined and node.depends_on.nodes is defined else [] -%}

    {%- for dep_id in depends_on_nodes -%}
        {%- if dep_id.startswith('source.') -%}
            {# Found a source node - extract its details from the graph #}
            {%- if dep_id in graph.sources -%}
                {%- set src_node = graph.sources[dep_id] -%}
                {%- do sources_found.append({
                    'database': src_node.database,
                    'schema': src_node.schema,
                    'identifier': src_node.identifier,
                    'graph_node': src_node
                }) -%}
            {%- endif -%}
        {%- elif dep_id.startswith('model.') -%}
            {# Intermediate model - recurse deeper #}
            {%- if dep_id in graph.nodes -%}
                {%- set dep_node = graph.nodes[dep_id] -%}
                {%- do _trace_lineage(dep_node, sources_found, visited) -%}
            {%- endif -%}
        {%- endif -%}
    {%- endfor -%}
{% endmacro %}


{% macro _get_snowflake_column_tags(relation) %}
    {#
        Queries Snowflake TAG_REFERENCES_ALL_COLUMNS to find all tags
        applied to columns on the given relation.
        Returns a list of dicts: {column_name, tag_name, tag_value, tag_reference}
    #}
    {%- set tags = [] -%}
    {%- set tag_query %}
        select
            column_name,
            tag_name,
            tag_value,
            tag_database,
            tag_schema
        from table({{ relation.database }}.information_schema.tag_references_all_columns(
            '{{ relation.database }}.{{ relation.schema }}.{{ relation.identifier }}', 'TABLE'
        ))
        where column_name is not null
    {% endset -%}

    {%- set tag_results = run_query(tag_query) -%}
    {%- for row in tag_results -%}
        {%- do tags.append({
            'column_name': row['COLUMN_NAME'],
            'tag_name': row['TAG_NAME'],
            'tag_value': row['TAG_VALUE'],
            'tag_reference': row['TAG_DATABASE'] ~ '.' ~ row['TAG_SCHEMA'] ~ '.' ~ row['TAG_NAME']
        }) -%}
    {%- endfor -%}

    {{ return(tags) }}
{% endmacro %}


{% macro _get_dbt_meta_tags(source_info) %}
    {#
        Reads column-level meta.snowflake_tags from the dbt graph node.
        Returns a list of dicts: {column_name, tag_name, tag_value, tag_reference}

        Expected YAML format on source columns:
            meta:
              snowflake_tags:
                tag_database.tag_schema.tag_name: "tag_value"
    #}
    {%- set tags = [] -%}
    {%- set graph_node = source_info.get('graph_node') -%}

    {%- if graph_node and graph_node.columns is defined -%}
        {%- for col_name, col_info in graph_node.columns.items() -%}
            {%- if col_info.meta is defined and col_info.meta.snowflake_tags is defined -%}
                {%- for tag_ref, tag_value in col_info.meta.snowflake_tags.items() -%}
                    {%- do tags.append({
                        'column_name': col_name,
                        'tag_name': tag_ref.split('.')[-1] if '.' in tag_ref else tag_ref,
                        'tag_value': tag_value,
                        'tag_reference': tag_ref
                    }) -%}
                {%- endfor -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}

    {{ return(tags) }}
{% endmacro %}


{% macro propagate_tags_for_model(model_name, column_mapping=none) %}
    {#
        Run-operation wrapper for manual invocation.

        Usage:
            dbt run-operation propagate_tags_for_model --args '{"model_name": "ds_iris_patient"}'
            dbt run-operation propagate_tags_for_model --args '{"model_name": "ds_iris_patient", "column_mapping": {"first_name": "patient_first_name"}}'
    #}
    {%- if execute -%}
        {# Resolve the model from the graph #}
        {%- set target_node = none -%}
        {%- for node_id, node in graph.nodes.items() -%}
            {%- if node.name == model_name and node.resource_type == 'model' -%}
                {%- set target_node = node -%}
            {%- endif -%}
        {%- endfor -%}

        {%- if target_node is none -%}
            {{ log("ERROR: Model '" ~ model_name ~ "' not found in the dbt graph.", info=true) }}
            {{ return("") }}
        {%- endif -%}

        {%- set target_db = target_node.database -%}
        {%- set target_schema = target_node.schema -%}
        {%- set target_table = target_node.identifier -%}

        {# Resolve column mapping from model config meta if not passed directly #}
        {%- if column_mapping is none -%}
            {%- set column_mapping = target_node.config.meta.get('tag_column_mapping', {}) if target_node.config.meta is defined else {} -%}
        {%- endif -%}

        {# Get target columns for matching #}
        {%- set target_columns_query %}
            select column_name
            from {{ target_db }}.information_schema.columns
            where table_schema = '{{ target_schema | upper }}'
              and table_name = '{{ target_table | upper }}'
        {% endset -%}
        {%- set target_cols_result = run_query(target_columns_query) -%}
        {%- set target_columns = [] -%}
        {%- for row in target_cols_result -%}
            {%- do target_columns.append(row['COLUMN_NAME'] | lower) -%}
        {%- endfor -%}

        {%- if target_columns | length == 0 -%}
            {{ log("WARNING: No columns found for " ~ target_db ~ "." ~ target_schema ~ "." ~ target_table ~ ". Has the model been materialized?", info=true) }}
            {{ return("") }}
        {%- endif -%}

        {# Find source nodes by tracing lineage #}
        {%- set source_nodes = _find_source_nodes(target_node) -%}

        {%- if source_nodes | length == 0 -%}
            {{ log("WARNING: No source nodes found in lineage for model '" ~ model_name ~ "'.", info=true) }}
            {{ return("") }}
        {%- endif -%}

        {{ log("Found " ~ source_nodes | length ~ " source(s) in lineage for '" ~ model_name ~ "'.", info=true) }}

        {# Collect all tags #}
        {%- set tags_to_apply = [] -%}
        {%- for src_node in source_nodes -%}
            {%- set src_relation = api.Relation.create(
                database=src_node.get('database'),
                schema=src_node.get('schema'),
                identifier=src_node.get('identifier')
            ) -%}

            {{ log("  Checking tags on source: " ~ src_relation, info=true) }}

            {%- set sf_tags = _get_snowflake_column_tags(src_relation) -%}
            {%- for tag_info in sf_tags -%}
                {%- do tags_to_apply.append(tag_info) -%}
            {%- endfor -%}

            {%- set meta_tags = _get_dbt_meta_tags(src_node) -%}
            {%- for tag_info in meta_tags -%}
                {%- do tags_to_apply.append(tag_info) -%}
            {%- endfor -%}
        {%- endfor -%}

        {%- if tags_to_apply | length == 0 -%}
            {{ log("No tags found on source columns. Nothing to propagate.", info=true) }}
            {{ return("") }}
        {%- endif -%}

        {{ log("Found " ~ tags_to_apply | length ~ " tag(s) to evaluate for propagation.", info=true) }}

        {# Apply tags to matching target columns #}
        {%- set applied_count = [0] -%}
        {%- set skipped_count = [0] -%}
        {%- for tag_info in tags_to_apply -%}
            {%- set source_col = tag_info['column_name'] | lower -%}
            {%- set tag_name = tag_info['tag_name'] -%}
            {%- set tag_value = tag_info['tag_value'] -%}
            {%- set tag_ref = tag_info['tag_reference'] -%}

            {%- set target_col = none -%}
            {%- if source_col in target_columns -%}
                {%- set target_col = source_col -%}
            {%- elif source_col in column_mapping -%}
                {%- set mapped_col = column_mapping[source_col] | lower -%}
                {%- if mapped_col in target_columns -%}
                    {%- set target_col = mapped_col -%}
                {%- endif -%}
            {%- endif -%}

            {%- if target_col is not none -%}
                {%- set alter_sql %}
                    ALTER TABLE {{ target_db }}.{{ target_schema }}.{{ target_table }}
                        ALTER COLUMN {{ target_col | upper }}
                        SET TAG {{ tag_ref }} = '{{ tag_value | replace("'", "''") }}'
                {% endset -%}
                {%- do run_query(alter_sql) -%}
                {{ log("  Applied tag " ~ tag_ref ~ " = '" ~ tag_value ~ "' to column " ~ target_col | upper, info=true) }}
                {%- do applied_count.append(applied_count.pop() + 1) if false else "" -%}
            {%- else -%}
                {{ log("  Skipped tag " ~ tag_ref ~ " on source column '" ~ source_col ~ "' (no matching target column).", info=true) }}
            {%- endif -%}
        {%- endfor -%}

        {{ log("Tag propagation complete for model '" ~ model_name ~ "'.", info=true) }}
    {%- endif -%}
{% endmacro %}
