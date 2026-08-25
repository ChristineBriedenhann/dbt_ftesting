# qrious-dbt-development-packages

## Table of Contents

- [Naming Conventions](#naming-conventions)
- [How to Build Datastore Models](#how-to-build-datastore-models)
- [How to Build Dimension Models](#how-to-build-dimension-models)
- [How to Build Exception Models](#how-to-build-exception-models)
- [SCD2 Data Quality Tests](#scd2-data-quality-tests)
- [How to set up operations schema and tables](#how-to-set-up-operations-schema-and-tables)
- [How to run dbt deps](#how-to-run-dbt-deps)
- [How to update parameter](#how-to-update-parameter)
- [Column Tag Propagation](#column-tag-propagation)

## Naming Conventions

### Folder Structure

The `models/` directory uses numeric prefixes to define layer ordering:

| Folder | Layer | Purpose |
|--------|-------|---------|
| `000_sources/` | Sources | Source definitions (`_sources.yml`) |
| `010_datastore/` | Datastore | Persisted source data (SCD2) |
| `020_dwh/` | Data Warehouse | Dimensions and facts |
| `040_mart/` | Mart | Business-facing aggregates |
| `990_operations/` | Operations | Exception reports, monitoring |
| `999_intermediate/` | Intermediate | Staging transformations between layers |

Within each layer, models are grouped by **data source** (e.g. `netsuite2/`, `iris/`). For the DWH layer, models are grouped by **type** (e.g. `dims/`, `facts/`). For the Mart layer, models are grouped by **department** (e.g. `finance/`, `marketing/`, `sales/`).

Schema YAML files live in a `_schemas/` subfolder within each source group:

```
models/010_datastore/netsuite2/
├── _schemas/
│   ├── _ds_netsuite2_account.yml
│   └── _ds_netsuite2_currency.yml
├── ds_netsuite2_account.sql
└── ds_netsuite2_currency.sql
```

```
models/040_mart/
├── finance/
│   ├── _schemas/
│   │   └── _revenue_summary.yml
│   └── revenue_summary.sql
└── marketing/
    ├── _schemas/
    │   └── _campaign_performance.yml
    └── campaign_performance.sql
```

### Model Naming

| Layer | Prefix | Pattern | Example |
|-------|--------|---------|---------|
| Datastore | `ds_` | `ds_<source>_<entity>` | `ds_netsuite2_account` |
| DWH Dimension | `dim_` | `dim_<entity>` | `dim_currency` |
| DWH Fact | `fact_` | `fact_<entity>` | `fact_transactions` |
| Mart | _(none)_ | `<entity>` | `revenue_summary` |
| Intermediate (datastore) | `int_ds_` | `int_ds_<source>_<entity>_<step>` | `int_ds_netsuite2_account_000` |
| Intermediate (dwh) | `int_` | `int_<dim\|fact>_<entity>_<step>` | `int_dim_currency_000` |
| Operations | `ops_` | `ops_exceptions_<model_name>` | `ops_exceptions_ds_netsuite2_account` |

Intermediate models use a 3-digit step suffix (`_000`, `_010`, `_020`) to indicate transformation sequence within a pipeline.

### Schema YAML Filenames

- Source definitions: `_sources.yml` (one per source folder in `000_sources/`)
- Model schemas: `_<model_name>.yml` (underscore-prefixed, one file per model, placed in the `_schemas/` subfolder)

Examples:
- `_ds_netsuite2_account.yml`
- `_int_ds_iris_patient_000.yml`

### Macros Folder Structure

```
macros/
├── custom_tests/          -- Custom data test macros
├── model_templates/       -- Code generation templates
│   ├── datastore_templates/
│   ├── dwh_templates/
│   ├── exception_templates/
│   └── schema_yaml_templates/
├── operations/            -- Environment setup and profilers
└── utils/                 -- Shared utilities (hash keys, schema names, etc.)
```

### General Rules

- All names use **lowercase** with **underscores** as separators
- Numeric folder prefixes control execution/display ordering
- Underscore-prefixed files/folders (`_schemas/`, `_sources.yml`) denote metadata/configuration rather than materialised models
- Column names and data types in schema YAMLs are lowercase

## How to Build Datastore Models

Datastore models persist source data as versioned (SCD2) tables. The pipeline flows through three layers: **source** → **int_datastore** → **datastore**.

### Data Flow

```
000_sources/ (YAML definition)
    ↓
999_intermediate/int_datastore/<source>/ (extract, flatten, cast)
    ↓
010_datastore/<source>/ (incremental SCD2 merge)
```

### Step 1: Define the Source

Create a `_sources.yml` file in `models/000_sources/<source>/` declaring the source database, schema, table, and columns.

### Step 2: Create Intermediate Models

Intermediate models live in `models/999_intermediate/int_datastore/<source>/` and use numbered step suffixes (`_000`, `_010`, `_020`) to indicate transformation sequence.

**Step _000 — Extract and deduplicate from source**

For Fivetran-managed sources:

```sql
{%- set source_model = source('<source>','<table>') -%}
{{ fivetran_int_datastore_000_template(source_model) }}
```

For general sources:

```sql
{% set source_model = source('<source>','<table>') -%}
{%- set date_column_filter="<date_column>" -%}
{%- set key_columns_to_dedup=["<business_key>"] -%}
{{ general_int_datastore_000_template(source_model, date_column_filter, key_columns_to_dedup) }}
```

**Step _010 — Flatten JSON (if needed)**

```sql
{% set model_source = ref('int_ds_<source>_<table>_000') %}
{{ int_datastore_json_parse_template(model_source) }}
```

**Step _020 — Cast data types / custom transforms (if needed)**

```sql
{% set model_source = ref('int_ds_<source>_<table>_010') -%}
-- Custom SQL for casting or renaming columns
```

### Step 3: Create the Datastore Model

The final datastore model lives in `models/010_datastore/<source>/` and performs an incremental SCD2 merge from the last intermediate step.

**For Fivetran sources** (`ds_<source>_<table>.sql`):

```sql
{% set source_table = ref('int_ds_<source>_<table>_000') %}
{% set business_key = ['<BUSINESS_KEY>'] %}
{% set exclude_columns = [] %}
{% set unique_key = (this.name|trim|lower) ~ "__key" %}
{% set datastore_key_type = "identity" %}

{{
    config(
        materialized='incremental',
        unique_key=unique_key,
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

{{ fivetran_datastore_template(
        this=this,
        ref_table=source_table,
        unique_key=unique_key,
        business_key=business_key,
        exclude_columns=exclude_columns,
        datastore_key_type=datastore_key_type
)}}
```

**For general sources** (`ds_<source>_<table>.sql`):

```sql
{% set source_table = ref('int_ds_<source>_<table>_020') %}
{% set business_key = ['<BUSINESS_KEY>'] %}
{% set exclude_columns = [] %}
{% set unique_key = (this.name|trim|lower) ~ "__key" %}
{% set datastore_key_type = "identity" %}

{{
    config(
        materialized='incremental',
        unique_key=unique_key,
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

{{ general_datastore_template(
        this=this,
        ref_table=source_table,
        unique_key=unique_key,
        business_key=business_key,
        exclude_columns=exclude_columns,
        datastore_key_type=datastore_key_type
)}}
```

#### Parameter Reference

| Parameter | Type | Description |
|-----------|------|-------------|
| `source_table` | relation | Reference to the last intermediate model (e.g. `ref('int_ds_netsuite2_account_000')` for Fivetran or `ref('int_ds_iris_patient_020')` for general sources) |
| `business_key` | list | Column(s) representing the natural/business key used to match records across source and target (e.g. `['ID']`, `['PATIENT_ID']`) |
| `exclude_columns` | list | Columns to exclude from change detection comparison. Use this for columns that change frequently but are not meaningful (e.g. audit timestamps). Defaults to `[]` |
| `unique_key` | string | Surrogate key column that uniquely identifies each versioned record in the target table. Convention: `<model_name>__key` (auto-derived from `this.name`) |
| `datastore_key_type` | string | Key generation strategy: `"identity"` (auto-increment integer, default) or `"hash"` (deterministic hash-based key) |

#### Config Reference

| Config | Value | Description |
|--------|-------|-------------|
| `materialized` | `'incremental'` | Model is incrementally loaded (not rebuilt from scratch each run) |
| `unique_key` | `<model>__key` | Column used by the merge strategy to identify existing rows |
| `incremental_strategy` | `'merge'` | Uses SQL `MERGE` to upsert new/changed records and close expired versions |
| `on_schema_change` | `'append_new_columns'` | Automatically adds new source columns to the target table without failing the build |

### Step 4: Create the Schema YAML

Create a schema YAML file at `models/010_datastore/<source>/_schemas/_ds_<source>_<table>.yml` and corresponding intermediate schema YAMLs in `models/999_intermediate/int_datastore/<source>/_schemas/`.

**Note:** For `ref` models, you must run `dbt build` (or `dbt run`) first to create the table in Snowflake before executing the `generate_model_yml` macro — it queries `INFORMATION_SCHEMA.COLUMNS` on the materialised table.

Use the `generate_model_yml` macro to generate the YAML content from the existing table, then paste the output into the `.yml` file:

```sql
-- For a source table:
EXECUTE DBT PROJECT FROM WORKSPACE USER$.PUBLIC."coco_kn_dbt_new_framework_test_-74c54"
  ARGS='run-operation --target sandbox generate_model_yml --args {"model_name": "<source>.<table>", "model_type": "source"}'
  DBT_VERSION='1.10.15'

-- For a ref model (e.g. an intermediate or datastore model):
EXECUTE DBT PROJECT FROM WORKSPACE USER$.PUBLIC."coco_kn_dbt_new_framework_test_-74c54"
  ARGS='run-operation --target sandbox generate_model_yml --args {"model_name": "ds_<source>_<table>", "model_type": "ref"}'
  DBT_VERSION='1.10.15'
```

Optionally add `"use_ai": true` to auto-generate column descriptions using Cortex AI.

**Enforce contract** on datastore models by adding a `config.contract.enforced: true` block to the schema YAML. This ensures dbt validates that the materialised table matches the column names and data types declared in the YAML at build time:

```yaml
models:
  - name: ds_<source>_<table>
    description: |
      ...
    config:
      contract:
        enforced: true
    columns:
      - name: <column>
        data_type: <type>
```

When contract enforcement is enabled, every column in the model must be declared in the YAML with a matching `data_type`. If the materialised output has columns not listed, or types that differ, the dbt build will fail. Intermediate models do **not** require contract enforcement.

## How to Build Dimension Models

Dimension (and fact) models transform datastore tables into star-schema DWH tables. The pipeline flows through three layers: **datastore** → **int_dwh** → **dwh**.

### Data Flow

```
010_datastore/<source>/ (versioned SCD2 tables)
    ↓
999_intermediate/int_dwh/ (point-in-time filter, dedup, business logic)
    ↓
020_dwh/dims/ or 020_dwh/facts/ (final SCD2 dimension or fact)
```

### Step 1: Create Intermediate DWH Models

Intermediate DWH models live in `models/999_intermediate/int_dwh/` and read from datastore tables with point-in-time filtering and deduplication.

```sql
-- int_dim_<entity>_000.sql
select
    ...
from {{ ref('ds_<source>_<table>') }} src
where '{{dwh_process_date}}'::timestamp_ntz between system_start_date and system_end_date
qualify row_number() over (partition by <business_key> order by system_version desc) = 1
```

This step filters to the active version at the processing date and excludes deleted records (`system_delete_flag = 'N'`).

### Step 2: Create the DWH Model

The final dimension or fact model lives in `models/020_dwh/dims/` (or `models/020_dwh/facts/`) and applies the SCD2 dimension template.

```sql
-- dim_<entity>.sql
{%- set ref_model = ref('int_dim_<entity>_000') -%}
{%- set exception_table = none -%}
{%- set business_key = ["<BUSINESS_KEY>"] -%}
{%- set unique_key = (this.name|trim|lower) ~ "__key" -%}
{%- set dim_key_type = "identity" -%}
{%- set process_date = var('dwh_process_date') -%}
{%- set track_delete = 'Y' -%}

{{
    config(
        materialized='incremental',
        unique_key=unique_key,
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

{{ generate_scd2_dimension_template(
    this            = this,
    ref_table       = ref_model,
    exception_table = exception_table,
    unique_key      = unique_key,
    business_key    = business_key,
    dss_track_date  = process_date,
    dim_key_type    = dim_key_type,
    track_delete    = track_delete
) }}
```

#### Parameter Reference

| Parameter | Type | Description |
|-----------|------|-------------|
| `ref_model` | relation | Reference to the intermediate DWH model (e.g. `ref('int_dim_currency_000')`) |
| `exception_table` | relation or `none` | Table containing records to exclude from processing. Set to `none` if not used |
| `business_key` | list | Natural/business key column(s) that uniquely identify a business entity across versions (e.g. `["ID"]`) |
| `unique_key` | string | Surrogate key column for the dimension table. Convention: `<model_name>__key` (auto-derived from `this.name`) |
| `dim_key_type` | string | Key generation strategy: `"identity"` (auto-increment integer, default) or `"hash"` (deterministic hash-based key) |
| `process_date` | string | The effective date (`yyyy-mm-dd`) used to open/close record versions. Sourced from `var('dwh_process_date')` |
| `track_delete` | string | `'Y'` (default) or `'N'`. When `'Y'`, records that disappear from the source are marked as deleted. Requires the intermediate model to supply the full set of active records (not just changed records) |

#### Config Reference

| Config | Value | Description |
|--------|-------|-------------|
| `materialized` | `'incremental'` | Model is incrementally loaded (not rebuilt from scratch each run) |
| `unique_key` | `<model>__key` | Column used by the merge strategy to identify existing rows |
| `incremental_strategy` | `'merge'` | Uses SQL `MERGE` to upsert new/changed records and close expired versions |
| `on_schema_change` | `'append_new_columns'` | Automatically adds new source columns to the target table without failing the build |

This produces an incremental SCD2 merge model tracking historical changes to the dimension.

### Step 3: Create the Schema YAML

Create a schema YAML file at `models/020_dwh/dims/_schemas/_dim_<entity>.yml` (or `facts/_schemas/_fact_<entity>.yml`).

**Note:** You must run `dbt build` (or `dbt run`) first to create the table in Snowflake before executing the `generate_model_yml` macro — it queries `INFORMATION_SCHEMA.COLUMNS` on the materialised table.

Use the `generate_model_yml` macro to generate the YAML content from the existing table, then paste the output into the `.yml` file:

```sql
EXECUTE DBT PROJECT FROM WORKSPACE USER$.PUBLIC."coco_kn_dbt_new_framework_test_-74c54"
  ARGS='run-operation --target sandbox generate_model_yml --args {"model_name": "dim_<entity>", "model_type": "ref"}'
  DBT_VERSION='1.10.15'
```

Optionally add `"use_ai": true` to auto-generate column descriptions using Cortex AI.

**Enforce contract** on DWH models by adding `config.contract.enforced: true`:

```yaml
models:
  - name: dim_<entity>
    description: |
      ...
    config:
      contract:
        enforced: true
    columns:
      - name: <column>
        data_type: <type>
```

Contract enforcement ensures the materialised table matches the declared column names and data types exactly. All columns must be listed with their `data_type` — any mismatch or missing column will cause the dbt build to fail.

## How to Build Exception Models

Exception models consolidate data quality test failures for a given model into a single queryable table. They live in `models/990_operations/` and use the `generate_test_result_template` macro.

### Data Flow

```
010_datastore/ or 020_dwh/ (model under test)
    ↓
dbt test (stores failures in dbt_test__audit schema)
    ↓
990_operations/ (exception model queries audit tables)
```

### Step 1: Create the Exception Model

Create a SQL file in `models/990_operations/` named `ops_exceptions_<model_name>.sql`.

Example (`ops_exceptions_ds_netsuite2_account.sql`):

```sql
{% set model_name = ref('ds_netsuite2_account') %}
{{generate_test_result_template(model_name)}}
```

#### Parameter Reference

| Parameter | Type | Description |
|-----------|------|-------------|
| `model_name` | relation | A `ref()` to the model whose test failures you want to retrieve (e.g. `ref('ds_netsuite2_account')`, `ref('dim_currency')`) |

### Step 2: Run the Exception Model

Exception models must be run **after** dbt tests have executed (since they query test result audit tables):

```sql
-- Run tests first:
EXECUTE DBT PROJECT FROM WORKSPACE USER$.PUBLIC."coco_kn_dbt_new_framework_test_-74c54"
  ARGS='test --target sandbox --select ds_netsuite2_account'
  DBT_VERSION='1.10.15'

-- Then run the exception model:
EXECUTE DBT PROJECT FROM WORKSPACE USER$.PUBLIC."coco_kn_dbt_new_framework_test_-74c54"
  ARGS='run --target sandbox --select ops_exceptions_ds_netsuite2_account'
  DBT_VERSION='1.10.15'
```

### How It Works

The `generate_test_result_template` macro:
1. Queries `elementary_test_results` to find all test executions for the target model
2. Identifies the most recent invocation (by `detected_at` timestamp)
3. Unions the raw audit tables (`dbt_test__audit` schema) for each failed test from that invocation
4. Returns all exception rows with their test metadata, ready for investigation

### Prerequisites

- The [Elementary](https://docs.elementary-data.com/) dbt package must be installed and configured (provides the `elementary_test_results` model)
- Tests must be configured to store failures (dbt's `store_failures: true` or Elementary equivalent)
- The `dbt_test__audit` schema must be accessible to the executing role

## SCD2 Data Quality Tests

This framework provides a standard set of data tests to ensure SCD2 (Slowly Changing Dimension Type 2) tables in the `010_datastore` and `020_dwh` layers maintain data integrity. All custom test macros live in `macros/custom_tests/` and return the full offending rows (not just a count), making it easy to diagnose issues.

### Recommended Tests for Every SCD2 Table

Define the following tests in the model's schema YAML file under `data_tests`:

#### 1. Uniqueness on surrogate key

Ensures the datastore/dwh surrogate key column is unique across all rows.

```yaml
data_tests:
  - uniqueness_test_return_all_columns:
      name: <model>__uniqueness__datastore_key_columns
      combination_of_columns:
        - <model>__key
      config:
        severity: "{{var('data_test_severity')}}"
```

#### 2. Uniqueness on business key for current records

Ensures there is only one current (`dbt_current_flag = 'Y'`) record per business key.

```yaml
  - uniqueness_test_return_all_columns:
      name: <model>__uniqueness__primary_key_current_flag
      combination_of_columns:
        - <business_key_column>
      config:
        severity: "{{var('data_test_severity')}}"
        where: "dbt_current_flag = 'Y'"
```

#### 3. Uniqueness on business key + start date

Ensures no duplicate versions share the same business key and start date.

```yaml
  - uniqueness_test_return_all_columns:
      name: <model>__uniqueness__primary_key_start_date
      combination_of_columns:
        - <business_key_column>
        - dbt_start_date
      config:
        severity: "{{var('data_test_severity')}}"
```

#### 4. Uniqueness on business key + version number

Ensures no duplicate version numbers exist for the same business key.

```yaml
  - uniqueness_test_return_all_columns:
      name: <model>__uniqueness__primary_key_version
      combination_of_columns:
        - <business_key_column>
        - dbt_version
      config:
        severity: "{{var('data_test_severity')}}"
```

#### 5. SCD2 start date must be less than end date

Validates that `dbt_start_date < dbt_end_date` for every row (no inverted date ranges).

```yaml
  - scd2_startdate_gt_enddate:
      name: <model>__scd2__startdate_greaterthan_enddate
      business_key_columns:
        - <business_key_column>
      start_date_column: dbt_start_date
      end_date_column: dbt_end_date
      config:
        severity: "{{var('data_test_severity')}}"
```

#### 6. SCD2 no gaps between versions

Validates that `dbt_end_date` of one version aligns with `dbt_start_date` of the next version (no gaps > 3 milliseconds).

```yaml
  - scd2_startdate_version_gaps:
      name: <model>__scd2__startdate_has_gaps_to_next_version
      business_key_columns:
        - <business_key_column>
      start_date_column: dbt_start_date
      end_date_column: dbt_end_date
      config:
        severity: "{{var('data_test_severity')}}"
```

### Test Severity

All tests reference `var('data_test_severity')` which defaults to `error` (defined in `dbt_project.yml`). This means a failing test will cause the dbt run to fail. Change the variable to `warn` if you want tests to report warnings without blocking the pipeline.

When severity is set to `warn`, the pipeline will continue to run even when tests fail. In this case, you **must** build an exception model (see [How to Build Exception Models](#how-to-build-exception-models)) and incorporate it into the downstream dimension model's configuration. The exception table is passed as the `exception_table` parameter in `generate_scd2_dimension_template`, which excludes the failed records from being loaded into the dimension:

```sql
-- dim_<entity>.sql
{%- set exception_table = ref('ops_exceptions_ds_<source>_<table>') -%}

{{ generate_scd2_dimension_template(
    ...
    exception_table = exception_table,
    ...
) }}
```

This ensures data quality issues are surfaced for investigation without blocking the pipeline, while still preventing bad records from propagating into the DWH layer.

## How to set up operations schema and tables

```
EXECUTE DBT PROJECT FROM WORKSPACE USER$.PUBLIC."coco_kn_dbt_new_framework_test_-74c54" ARGS='run-operation --target sandbox ops_environment_setup' DBT_VERSION='1.10.15'
```

## How to run dbt deps

```
EXECUTE DBT PROJECT FROM WORKSPACE USER$.PUBLIC."coco_kn_dbt_new_framework_test_-74c54" ARGS='deps --target sandbox' DBT_VERSION='1.10.15' EXTERNAL_ACCESS_INTEGRATIONS=(ALLOW_ALL_INTEGRATION)
```

## How to update parameter
```
EXECUTE DBT PROJECT FROM WORKSPACE USER$.PUBLIC."coco_kn_dbt_new_framework_test_-74c54" ARGS='run-operation --target sandbox update_parameter --args ' DBT_VERSION='1.10.15'
```

## Column Tag Propagation

Automatically propagates Snowflake object tags and dbt meta-defined tags from source columns to downstream model columns. The macro traces lineage back through the dbt graph to find the original source table(s), discovers any tags on those source columns, and applies them to matching columns on the target model.

### Supported Tag Types

- **Snowflake object tags**: Tags applied via `ALTER TABLE ... ALTER COLUMN ... SET TAG` (e.g. PII classification, sensitivity tags)
- **dbt meta tags**: Tags defined in source YAML under `meta.snowflake_tags` on columns

### How It Works

1. Recursively walks `depends_on.nodes` from the current model back to the original `source.*` nodes
2. Queries `INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS()` on each source for Snowflake object tags
3. Reads `meta.snowflake_tags` from source column definitions in the dbt graph
4. Matches source columns to target columns by name, or via a configurable column mapping
5. Applies discovered tags to target columns using `ALTER TABLE ... ALTER COLUMN ... SET TAG`

### Invocation

**Automatic (post-hook)** - enabled by default on `010_datastore`, `020_dwh`, and `040_mart` layers:

Tags are propagated automatically after each model materializes. No action required.

**Manual (run-operation)**:

```sql
EXECUTE DBT PROJECT FROM WORKSPACE USER$.PUBLIC."coco_kn_dbt_new_framework_test_-74c54"
  ARGS='run-operation --target sandbox propagate_tags_for_model --args {"model_name": "ds_iris_patient"}'
  DBT_VERSION='1.10.15'
```

With a column mapping override:

```sql
EXECUTE DBT PROJECT FROM WORKSPACE USER$.PUBLIC."coco_kn_dbt_new_framework_test_-74c54"
  ARGS='run-operation --target sandbox propagate_tags_for_model --args {"model_name": "ds_iris_patient", "column_mapping": {"first_name": "patient_first_name"}}'
  DBT_VERSION='1.10.15'
```

### Defining Tags in Source YAML (dbt Meta Tags)

Add `meta.snowflake_tags` to source columns to declare tags that should be propagated without requiring them to be pre-applied in Snowflake:

```yaml
sources:
  - name: iris
    tables:
      - name: patient
        columns:
          - name: ssn_last4
            meta:
              snowflake_tags:
                my_db.my_schema.pii_type: "SSN"
                my_db.my_schema.sensitivity: "HIGH"
```

### Column Mapping for Renamed Columns

When downstream columns have been renamed from their source, define a mapping in the model's meta config:

```yaml
models:
  - name: ds_iris_patient
    meta:
      tag_column_mapping:
        first_name: patient_first_name
        last_name: patient_last_name
```

Or inline in the model SQL:

```sql
{{ config(meta={'tag_column_mapping': {'first_name': 'patient_first_name'}}) }}
```

### Prerequisites

- The executing role must have `USAGE` privilege on any tag objects being applied
- The executing role must have `ALTER` privilege on target tables
- Source tables must exist and be accessible for tag reference queries