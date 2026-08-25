# Macros Reference

Summary and usage guide for every macro in the `macros/` folder of this dbt project.

## Table of Contents

- [macros/utils](#macrosutils)
  - [truncate_table](#truncate_table)
  - [string_value_pattern_detection](#string_value_pattern_detection)
  - [rename_table](#rename_table)
  - [propagate_column_tags](#propagate_column_tags)
  - [prefix_fields](#prefix_fields)
  - [get_project_version](#get_project_version)
  - [get_current_timestamp_for_logging](#get_current_timestamp_for_logging)
  - [generate_schema_name](#generate_schema_name)
  - [generate_project_name](#generate_project_name)
  - [generate_hash_key](#generate_hash_key)
  - [drop_view](#drop_view)
  - [convert_utc_to_ltz](#convert_utc_to_ltz)
  - [convert_ts_timezone](#convert_ts_timezone)
  - [check_table_exist](#check_table_exist)
- [macros/operations](#macrosoperations)
  - [update_parameter](#update_parameter)
  - [get_parameter_value](#get_parameter_value)
- [macros/operations/data_profilers](#macrosoperationsdata_profilers)
  - [data_profiler_schema](#data_profiler_schema)
  - [data_profiler_model](#data_profiler_model)
- [macros/operations/environment_setup](#macrosoperationsenvironment_setup)
  - [ops_environment_setup](#ops_environment_setup)
  - [get_ops_table_ddl](#get_ops_table_ddl)
  - [create_ops_table](#create_ops_table)
- [macros/model_templates](#macrosmodel_templates)
  - [system_columns_list](#system_columns_list)
  - [generate_model_yml](#generate_model_yml)
  - [generate_test_result_template](#generate_test_result_template)
  - [generate_scd2_dimension_template](#generate_scd2_dimension_template)
  - [generate_dim_key](#generate_dim_key)
  - [generate_dim_date_template](#generate_dim_date_template)
- [macros/model_templates/datastore_templates](#macrosmodel_templatesdatastore_templates)
  - [generate_datastore_key](#generate_datastore_key)
  - [int_datastore_json_parse_template](#int_datastore_json_parse_template)
  - [general_int_datastore_000_template](#general_int_datastore_000_template)
  - [general_datastore_template](#general_datastore_template)
  - [fivetran_int_datastore_000_template](#fivetran_int_datastore_000_template)
  - [fivetran_datastore_template](#fivetran_datastore_template)
- [macros/custom_tests](#macroscustom_tests)
  - [uniqueness_test_return_all_columns](#uniqueness_test_return_all_columns)
  - [scd2_startdate_version_gaps](#scd2_startdate_version_gaps)
  - [scd2_startdate_gt_enddate](#scd2_startdate_gt_enddate)

---

## macros/utils

### `truncate_table`
**Path:** `macros/utils/truncate_table.sql`

Truncates all data in a table. Validates the table exists (via `check_table_exist`), executes a `TRUNCATE TABLE` statement, logs success/failure, and records an operational log entry via `add_operational_log`. Raises a compiler error if `full_table_name` is not provided.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `full_table_name` | Yes | — | Fully qualified name `<database>.<schema>.<table>` |

```sql
{{ truncate_table(full_table_name='ANALYTICS.STAGING.STG_CUSTOMER') }}
```

### `string_value_pattern_detection`
**Path:** `macros/utils/string_value_pattern_detection.sql`

Returns a SQL `CASE` expression that classifies a column's string value into a generic pattern (email, various datetime formats, date, phone number, money, decimal, whole number, single character, long string, or a generic letter/digit mask). Used by the data profiler to derive a representative `value_pattern` per column.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `column_name` | Yes | — | Column expression/name to analyze |

```sql
select mode({{ string_value_pattern_detection('email_address') }}) as value_pattern
from my_table
```

### `rename_table`
**Path:** `macros/utils/rename_table.sql`

Renames a table in the database. Validates both `from_name` and `to_name` are in `<database>.<schema>.<table>` format, checks existence of source/target via `check_table_exist`, runs `ALTER TABLE ... RENAME TO ...` if source exists and target does not, logs the action, and records an operational log entry.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `from_name` | Yes | — | Current fully qualified table name |
| `to_name` | Yes | — | New fully qualified table name |

```sql
{{ rename_table(from_name='ANALYTICS.STAGING.OLD_TABLE', to_name='ANALYTICS.STAGING.NEW_TABLE') }}
```

### `propagate_column_tags`
**Path:** `macros/utils/propagate_column_tags.sql`

Propagates Snowflake object tags and dbt `meta.snowflake_tags` from upstream source columns to the current model's matching columns, tracing lineage back through the dbt graph. Supports direct name matching and custom mapping via `meta.tag_column_mapping`. Intended for use as a post-hook (uses `this`/`model`), or via the companion `propagate_tags_for_model` run-operation wrapper for manual invocation. Also defines internal helpers `_find_source_nodes`, `_trace_lineage`, `_get_snowflake_column_tags`, `_get_dbt_meta_tags`.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `column_mapping` | No | `none` | Dict mapping source column name → target column name; if `none`, resolved from model's `meta.tag_column_mapping` config |

```sql
{{
    config(
        post_hook="{{ propagate_column_tags() }}"
    )
}}
select * from {{ source('iris', 'patient') }}
```

```sql
-- run-operation (companion macro in same file)
dbt run-operation propagate_tags_for_model --args '{"model_name": "ds_iris_patient"}'
```

### `prefix_fields`
**Path:** `macros/utils/prefix_fields.sql`

Prefixes each field name in a list with a given table alias (e.g. `src.col1`), and joins them into a comma+newline separated string for use in `SELECT` clauses.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `alias` | Yes | — | Table alias to prefix each field with |
| `fields` | Yes | — | List of field names |

```sql
select
    {{ prefix_fields('src', ['customer_id', 'customer_name']) }}
from {{ ref('stg_customer') }} src
```

### `get_project_version`
**Path:** `macros/utils/get_project_version.sql`

Returns the dbt project version by reading it from Elementary's `get_runtime_config()`.

**Parameters:** none

```sql
{% set proj_version = get_project_version() %}
{{ log('Project version: ' ~ proj_version, info=True) }}
```

### `get_current_timestamp_for_logging`
**Path:** `macros/utils/get_current_timestamp_for_logging.sql`

Returns the current timestamp formatted as `'YYYY-MM-DD HH:MM:SS.ffffff'` in a given timezone (default `Pacific/Auckland`). Useful for generating human-readable log timestamps / run IDs.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `timezone` | No | `'Pacific/Auckland'` | IANA timezone name |

```sql
{% set ts = get_current_timestamp_for_logging() %}
{{ log('Run started at: ' ~ ts, info=True) }}
```

### `generate_schema_name`
**Path:** `macros/utils/generate_schema_name.sql`

Overrides dbt's default schema-name generation. If no custom schema is provided, uses `target.schema`. Otherwise, on the `sandbox` target it prefixes the custom schema with the current user (from the `DBT_CURRENT_USER` env var) to avoid collisions between developers; on other targets it uses the custom schema name as-is.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `custom_schema_name` | Yes | — | Custom schema from `dbt_project.yml`/model config (can be `none`) |
| `node` | Yes | — | The dbt node being compiled |

```sql
{{ generate_schema_name('operations', model) }}
```

### `generate_project_name`
**Path:** `macros/utils/generate_project_name.sql`

Returns the dbt project name (from the `project_name` global variable set at project compile time).

**Parameters:** none

```sql
{% set proj = generate_project_name() %}
```

### `generate_hash_key`
**Path:** `macros/utils/generate_hash_key.sql`

Generates an `MD5` hash key by concatenating a list of columns, each `NVL`'d to `'NULL'` and cast to `varchar`, separated by `'-'`. Used throughout the project to build business/surrogate hash keys.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `columns` | Yes | — | List of column names to hash |

```sql
select {{ generate_hash_key(['customer_id', 'source_system']) }} as customer_hash_key
from {{ ref('stg_customer') }}
```

### `drop_view`
**Path:** `macros/utils/drop_view.sql`

Drops a view if it exists. Resolves the view via `check_table_exist`; if found, wraps the `DROP VIEW` in a Snowflake scripting `BEGIN...EXCEPTION` block to capture errors and logs success or failure. Logs a warning if the view does not exist, and raises a compiler error if `view_name` is not provided.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `view_name` | Yes | — | Name of the view to drop |

```sql
{{ drop_view(view_name='ANALYTICS.STAGING.OLD_VIEW') }}
```

### `convert_utc_to_ltz`
**Path:** `macros/utils/convert_utc_to_ltz.sql`

Converts a UTC timestamp column to the project's local timezone (as configured by the `project_timezone` dbt variable), returning a `TIMESTAMP_NTZ`.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `column_name` | Yes | — | Column containing the UTC timestamp |

```sql
select {{ convert_utc_to_ltz('_fivetran_synced') }} as _fivetran_synced_ltz
from {{ source('fivetran', 'raw_table') }}
```

### `convert_ts_timezone`
**Path:** `macros/utils/convert_ts_timezone.sql`

Converts a timestamp column from a specified source timezone to a specified target timezone, casting to `TIMESTAMP_NTZ` before and after conversion.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `column_name` | Yes | — | Timestamp column to convert |
| `source_timezone` | Yes | — | Timezone of the input timestamp (e.g. `'UTC'`) |
| `target_timezone` | Yes | — | Desired output timezone (e.g. `'Pacific/Auckland'`) |

```sql
select {{ convert_ts_timezone(column_name='created_at', source_timezone='UTC', target_timezone='Pacific/Auckland') }} as created_at_ltz
from {{ ref('stg_orders') }}
```

### `check_table_exist`
**Path:** `macros/utils/check_table_exist.sql`

Checks whether a table exists using `adapter.get_relation`. Returns the relation object if it exists, or `none` if it does not.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `full_table_name` | Yes | — | Fully qualified name `<database>.<schema>.<table>` |

```sql
{% set rel = check_table_exist(full_table_name='ANALYTICS.STAGING.STG_CUSTOMER') %}
{% if rel is not none %}
    {{ log('Table exists: ' ~ rel, info=True) }}
{% endif %}
```

---

## macros/operations

### `update_parameter`
**Path:** `macros/operations/update_parameter.sql`

Creates or updates a key/value parameter in the `operations.parameters` table. Validates `parameter_data_type` (must be `date`, `boolean`, `number`, or `string`) when provided, validates that `parameter_value` is convertible to that data type, then performs a `MERGE` (update existing row, or insert if a data type was supplied for a new parameter). Logs before/after values.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `parameter_name` | Yes | — | Name of the parameter |
| `parameter_value` | Yes | — | Value to set |
| `parameter_data_type` | No | `none` | One of `date`, `boolean`, `number`, `string`; required when creating a new parameter |

```sql
{{ update_parameter(parameter_name='dwh_process_date', parameter_data_type='date', parameter_value='2026-07-01') }}
```

### `get_parameter_value`
**Path:** `macros/operations/get_parameter_value.sql`

Looks up and returns the current value of a named parameter from the `operations.parameters` table (latest by `updated_at`). Raises a compiler error if the parameter is not found or if `parameter_name` is missing.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `parameter_name` | Yes | — | Name of the parameter to look up |

```sql
{% set process_date = get_parameter_value(parameter_name='dwh_process_date') %}
```

---

## macros/operations/data_profilers

### `data_profiler_schema`
**Path:** `macros/operations/data_profilers/data_profiler_schema.sql`

Profiles all tables/views within a given schema by listing them via `information_schema.tables` and calling `data_profiler_model` for each. Logs progress per table.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `schema_name` | Yes | — | Format `database.schema` |
| `sampling_to_profile` | No | `20000` | Number of records to sample per table |

```sql
dbt run-operation data_profiler_schema --args '{"schema_name": "ANALYTICS.STAGING", "sampling_to_profile": 20000}'
```

### `data_profiler_model`
**Path:** `macros/operations/data_profilers/data_profiler_model.sql`

Profiles a single model/table: validates it exists, creates a sampled temp table, gathers column metadata from `information_schema.columns`, generates a `run_id`, inserts a table-level profile row (row count, size, timestamps, etc.) into `profile_table_level`, and inserts a column-level profile row per column into `profile_column_level` (null/distinct counts and percentages, min/max, length stats, variant JSON/XML structure detection for `VARIANT` columns, and value pattern via `string_value_pattern_detection`). Drops the temp table when done.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `model_name` | Yes | — | Fully qualified table/model name to profile |
| `sampling_to_profile` | Yes | — | Sample size limit (`none`, `"full"`, or a number) |
| `conditions` | Yes | — | Optional WHERE clause filter (can be `none`) |

```sql
dbt run-operation data_profiler_model --args '{"model_name": "ANALYTICS.STAGING.STG_CUSTOMER", "sampling_to_profile": 5000, "conditions": null}'
```

---

## macros/operations/environment_setup

### `ops_environment_setup`
**Path:** `macros/operations/environment_setup/ops_environment_setup.sql`

Bootstraps the operations environment: optionally drops the existing `OPERATIONS` schema (or `<user>_OPERATIONS` on sandbox), then creates the `parameters`, `profile_table_level`, and `profile_column_level` ops tables via `create_ops_table`, and seeds default parameters (`datastore_process_date`, `dwh_process_date`, `datastore_full_refresh`, `dwh_full_refresh`).

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `rebuild` | No | `false` | If `true`, drops and recreates the operations schema |

```sql
dbt run-operation ops_environment_setup --args '{"rebuild": false}'
```

### `get_ops_table_ddl`
**Path:** `macros/operations/environment_setup/get_ops_table_ddl.sql`

Returns the column DDL (with types, defaults, and comments) for a named operations table. Supports `operational_logs`, `parameters`, `profile_table_level`, and `profile_column_level`. Used by `create_ops_table` to build `CREATE TABLE` statements.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `table_name` | Yes | — | One of `operational_logs`, `parameters`, `profile_table_level`, `profile_column_level` |

```sql
create or replace table {{ target.database }}.operations.parameters
{{ get_ops_table_ddl('parameters') }}
```

### `create_ops_table`
**Path:** `macros/operations/environment_setup/create_ops_table.sql`

Creates (or alters) an operations table at the given database/schema/table location, creating the schema if needed. If the table doesn't exist, creates it via `CREATE OR REPLACE` (if `force_replace`) or `CREATE OR ALTER`; if it already exists, always runs `CREATE OR ALTER` to sync schema changes. Uses `get_ops_table_ddl` for the column definitions.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `database_name` | Yes | — | Target database |
| `schema_name` | Yes | — | Target schema |
| `table_name` | Yes | — | Target table |
| `force_replace` | No | `false` | If `true`, use `CREATE OR REPLACE` when the table doesn't exist |

```sql
{{ create_ops_table(database_name=target.database, schema_name='OPERATIONS', table_name='parameters', force_replace=false) }}
```

---

## macros/model_templates

### `system_columns_list`
**Path:** `macros/model_templates/system_columns_list.sql`

Returns a dictionary mapping logical system-column keys to their physical column names used across the project's SCD2 templates (e.g. `dbt_start_date`, `dbt_end_date`, `dbt_current_flag`, `dbt_create_time`, `dbt_update_time`, `dbt_delete_flag`, `dbt_version`, `dbt_business_key`, `scd_check_columns`, `_sf_load_at`).

**Parameters:** none

```sql
{% set sys_cols = system_columns_list() %}
select {{ sys_cols.system_start_date }}, {{ sys_cols.system_end_date }} from {{ this }}
```

### `generate_model_yml`
**Path:** `macros/model_templates/schema_yaml_templates/generate_model_yml.sql`

Generates a YAML schema block (`version: 2` with `sources:`/`models:`, table + column descriptions and data types) by introspecting `information_schema` for a given source table or ref model. Optionally uses Snowflake Cortex `COMPLETE` to auto-generate table/column descriptions when no comment exists. Outputs the YAML via `log`.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `model_name` | Yes | — | `"source_name.table_name"` for sources, or model name for refs |
| `model_type` | No | `"source"` | `"source"` or `"ref"` |
| `use_ai` | No | `false` | Enable Cortex AI description generation |
| `ai_model` | No | `"mistral-large2"` | Cortex LLM model name |

```sql
dbt run-operation generate_model_yml --args '{"model_name": "iris.allergy", "model_type": "source", "use_ai": true, "ai_model": "llama3.1-70b"}'
```

### `generate_test_result_template`
**Path:** `macros/model_templates/exception_templates/generate_test_result_template.sql`

Builds a SQL template string that unions all dbt/Elementary custom test result tables for a given model (looked up from `elementary_test_results`, deduplicated to the latest invocation), joining back to `elementary_test_results` to attach a local-timezone `detected_at_ltz` column. Returns the SQL as a string (intended to be used as a model's compiled SQL, e.g. for an exception/audit model).

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `model_name` | Yes | — | A relation object with `.database`, `.schema`, `.identifier` (e.g. `this` or `ref(...)`) |

```sql
{{ generate_test_result_template(this) }}
```

### `generate_scd2_dimension_template`
**Path:** `macros/model_templates/dwh_templates/generate_scd2_dimension_template.sql`

Generates full SCD Type 2 dimension-load SQL comparing a staging/ref table against the existing dimension table, using `dbt_utils.generate_surrogate_key` for business-key/change-detection hashing. Handles initial load (no existing table or non-incremental run) vs. incremental load (detect new records, expire changed records, insert new versions, optionally track soft-deletes when `track_delete='Y'`). Also defines internal helpers `_dim_generate_incremental_load_sql` and `_dim_generate_initial_load_sql`.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `this` | Yes | — | The current model relation |
| `ref_table` | Yes | — | Source/staging relation |
| `exception_table` | Yes | — | Table of records to exclude from processing (can be `none`) |
| `unique_key` | Yes | — | Surrogate key column name |
| `business_key` | Yes | — | List of natural key column(s) |
| `dss_track_date` | Yes | — | Effective date (`yyyy-mm-dd`) for opening/closing versions |
| `dim_key_type` | No | `"identity"` | `"identity"` or `"hash"` |
| `track_delete` | No | `"Y"` | `"Y"`/`"N"` to enable soft-delete tracking |

```sql
{{
    config(
        materialized='incremental',
        unique_key='customer_key',
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}
{{ generate_scd2_dimension_template(
    this            = this,
    ref_table       = ref('stg_customer'),
    exception_table = ref('dim_customer_exceptions'),
    unique_key      = 'customer_key',
    business_key    = ['customer_id', 'source_system'],
    dss_track_date  = '2026-07-01',
    dim_key_type    = 'identity',
    track_delete    = 'Y'
) }}
```

### `generate_dim_key`
**Path:** `macros/model_templates/dwh_templates/generate_dim_key.sql`

Produces a SQL column expression to generate a dimension surrogate key, either via `generate_hash_key` (`dim_key_type="hash"`) or a sequential `row_number()` (`dim_key_type="identity"`). In incremental mode with `identity`, adds the running row number to `max_dim_key` (from a `max_dim_key_data` CTE expected to exist in the calling SQL).

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `unique_key_cols_src` | Yes | — | Source column(s) for hash generation |
| `unique_key_name` | Yes | — | Alias for the generated key column |
| `dim_key_type` | Yes | — | `"hash"` or `"identity"` |
| `_is_incremental` | No | `true` | Whether the model is running incrementally |

```sql
select
    {{ generate_dim_key(unique_key_cols_src=['customer_id'], unique_key_name='customer_key', dim_key_type='hash', _is_incremental=false) }}
    *
from source_records
```

### `generate_dim_date_template`
**Path:** `macros/model_templates/dwh_templates/generate_dim_date_template.sql`

Generates a SQL SELECT that builds a date-dimension table using a recursive CTE, producing one row per calendar day between `start_year` and `end_year`, plus dummy boundary dates (1900-01-01, 2999-12-31, 9999-12-31). Adds calendar attributes (year, month name/number, month key, day name/number-in-week) and standard system SCD columns via `system_columns_list()`, using `low_date`/`high_date` project vars.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `start_year` | Yes | — | First year of the date range |
| `end_year` | Yes | — | Last year of the date range |

```sql
{{ generate_dim_date_template(2000, 2030) }}
```

---

## macros/model_templates/datastore_templates

### `generate_datastore_key`
**Path:** `macros/model_templates/datastore_templates/generate_datastore_key.sql`

Same pattern as `generate_dim_key`, but for datastore tables: generates a hash key or a sequential `row_number()`-based identity key, adding to `max_ds_key` (from a `max_ds_key_data` CTE) when incremental.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `unique_key_cols_src` | Yes | — | Source column(s) for hash generation |
| `unique_key_name` | Yes | — | Alias for the generated key column |
| `datastore_key_type` | Yes | — | `"hash"` or `"identity"` |
| `_is_incremental` | No | `true` | Whether the model is running incrementally |

```sql
select
    {{ generate_datastore_key(unique_key_cols_src=['order_id'], unique_key_name='order_key', datastore_key_type='identity', _is_incremental=true) }}
    *
from union_new_records_data
```

### `int_datastore_json_parse_template`
**Path:** `macros/model_templates/datastore_templates/json_templates/int_datastore_json_parse_template.sql`

Builds an intermediate-model template that auto-detects `VARIANT` columns in a source model, determines each one's JSON structure (object vs. array), recursively discovers all keys/paths at compile time (via `LATERAL FLATTEN`), and generates flattening SQL that extracts each key into its own typed column. Array-type variant columns are flattened via `LATERAL FLATTEN(... outer => true)`. Falls back to a plain select (via helper `_json_parse_no_variant_sql`) if no VARIANT columns exist. Also defines helpers `_json_path_to_column_name`, `_json_path_to_accessor`, `_json_typeof_to_snowflake_type`.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `model_name` | Yes | — | The source relation to parse (object with `.database/.schema/.identifier`) |
| `auto_data_type_cast` | No | `true` | Declared but not currently referenced in the macro logic |

```sql
{{ int_datastore_json_parse_template(source('iris', 'allergy')) }}
```

### `general_int_datastore_000_template`
**Path:** `macros/model_templates/datastore_templates/general_templates/general_int_datastore_000_template.sql`

Standard intermediate ("_000") datastore layer template: selects all columns from the source model, converts a date column to the project timezone via `convert_ts_timezone` (aliased to `_sf_load_at`), filters rows against `datastore_process_date` (full range for full-refresh, exact-date match for incremental, both controlled by the `datastore_full_refresh` var), and optionally deduplicates on `key_columns_to_dedup` (keeping the latest by load date).

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `source_model` | Yes | — | Source relation |
| `date_column_filter` | Yes | — | Name of the date column to convert/filter on |
| `date_column_in_timezone` | Yes | — | Timezone of the source date column |
| `key_columns_to_dedup` | No | `none` | List of columns to dedupe on |

```sql
{{ general_int_datastore_000_template(
    source_model=source('iris', 'allergy'),
    date_column_filter='updated_at',
    date_column_in_timezone='UTC',
    key_columns_to_dedup=['allergy_id']
) }}
```

### `general_datastore_template`
**Path:** `macros/model_templates/datastore_templates/general_templates/general_datastore_template.sql`

Generates a general-purpose SCD Type 2 datastore load (non-Fivetran-specific), comparing source vs. active target records using hash-based change detection (`generate_hash_key`), tracking `_sf_load_at` as the change-tracking date. Handles initial load and incremental load (new records, deactivate changed records, insert new versions), and generates the surrogate key via `generate_datastore_key`. Supports excluding columns from output via `exclude_columns`. Also defines internal helpers `_general_generate_incremental_load_sql` and `_general_generate_initial_load_sql`.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `this` | Yes | — | Current model relation |
| `ref_table` | Yes | — | Source/staging relation |
| `unique_key` | Yes | — | Surrogate key column |
| `business_key` | Yes | — | Natural key column(s) |
| `exclude_columns` | No | `none` | Columns to exclude from change comparison/output |
| `datastore_key_type` | No | `"identity"` | `"identity"` or `"hash"` |

```sql
{{
    config(
        materialized='incremental',
        unique_key='order_key',
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}
{{ general_datastore_template(
    this=this,
    ref_table=ref('int_orders_000'),
    unique_key='order_key',
    business_key=['order_id'],
    exclude_columns=['load_timestamp'],
    datastore_key_type='identity'
) }}
```

### `fivetran_int_datastore_000_template`
**Path:** `macros/model_templates/datastore_templates/fivetran_templates/fivetran_int_datastore_000_template.sql`

Intermediate ("_000") datastore layer template specifically for Fivetran-ingested sources. Converts `_fivetran_synced` (and, if present, `_fivetran_start`/`_fivetran_end`) to local timezone via `convert_utc_to_ltz`, and filters rows against `datastore_process_date` per the `datastore_full_refresh` variable. Branches its logic based on whether `_fivetran_start` exists in the source (i.e. Fivetran history-mode tables).

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `source_model` | Yes | — | The Fivetran source relation |

```sql
{{ fivetran_int_datastore_000_template(source('fivetran_crm', 'contact')) }}
```

### `fivetran_datastore_template`
**Path:** `macros/model_templates/datastore_templates/fivetran_templates/fivetran_datastore_template.sql`

Generates an SCD Type 2 datastore load specifically for Fivetran data, using `_fivetran_synced_ltz` as the change-tracking date (or, for Fivetran history-mode tables containing `_fivetran_start`, reconstructing versioned start/end dates directly from `_fivetran_start_ltz`/`_fivetran_end_ltz`/`_fivetran_active`). Supports soft-deletes via `_fivetran_deleted` when present, handles initial vs incremental load, and supports multiple loads per day. Defines internal helpers `_fivetran_generate_incremental_load_sql` and `_fivetran_generate_initial_load_sql`.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `this` | Yes | — | Current model relation |
| `ref_table` | Yes | — | Source/staging relation |
| `unique_key` | Yes | — | Surrogate key column |
| `business_key` | Yes | — | Natural key column(s) |
| `exclude_columns` | No | `none` | Columns to exclude from change comparison/output |
| `datastore_key_type` | No | `"identity"` | `"identity"` or `"hash"` |

```sql
{{
    config(
        materialized='incremental',
        unique_key='record_key',
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}
{{ fivetran_datastore_template(
    this,
    ref('int_fivetran_crm_contact_000'),
    unique_key='record_key',
    business_key='customer_id',
    exclude_columns=['_fivetran_synced', 'load_timestamp'],
    datastore_key_type='identity'
) }}
```

---

## macros/custom_tests

### `uniqueness_test_return_all_columns`
**Path:** `macros/custom_tests/uniqueness_test_return_all_columns.sql`

dbt generic test. Checks uniqueness of a combination of columns and, unlike the built-in `dbt_utils.unique_combination_of_columns`, returns the *full row* for every duplicate record (grouped by a hash of the combination), making duplicates easier to debug.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `model` | Yes (implicit) | — | The model under test |
| `combination_of_columns` | Yes | — | List of columns that should be unique together |

```yaml
models:
  - name: dim_customer
    tests:
      - uniqueness_test_return_all_columns:
          combination_of_columns:
            - customer_id
            - source_system
```

### `scd2_startdate_version_gaps`
**Path:** `macros/custom_tests/scd2_startdate_version_gaps.sql`

dbt generic test for SCD2 tables. For each business key (hashed via `generate_hash_key`), computes the gap in milliseconds between a record's `dbt_end_date` and the next version's `dbt_start_date` (using `LEAD` ordered by `dbt_start_date`, defaulting to the `high_date` var for the last version). Flags and returns full rows where the gap exceeds 3ms, indicating a broken/missing version chain.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `model` | Yes (implicit) | — | The model under test |
| `business_key_columns` | Yes | — | List of business key columns |
| `start_date_column` | Yes | — | Name of the SCD start-date column |
| `end_date_column` | Yes | — | Name of the SCD end-date column |

```yaml
models:
  - name: dim_customer
    tests:
      - scd2_startdate_version_gaps:
          business_key_columns:
            - customer_id
          start_date_column: dbt_start_date
          end_date_column: dbt_end_date
```

### `scd2_startdate_gt_enddate`
**Path:** `macros/custom_tests/scd2_startdate_gt_enddate.sql`

dbt generic test for SCD2 tables. Flags and returns full rows where `start_date_column >= end_date_column`, i.e. invalid/inverted effective date ranges, grouped/matched by a business-key hash.

**Parameters:**
| Name | Required | Default | Description |
|---|---|---|---|
| `model` | Yes (implicit) | — | The model under test |
| `business_key_columns` | Yes | — | List of business key columns |
| `start_date_column` | Yes | — | Name of the SCD start-date column |
| `end_date_column` | Yes | — | Name of the SCD end-date column |

```yaml
models:
  - name: dim_customer
    tests:
      - scd2_startdate_gt_enddate:
          business_key_columns:
            - customer_id
          start_date_column: dbt_start_date
          end_date_column: dbt_end_date
```
