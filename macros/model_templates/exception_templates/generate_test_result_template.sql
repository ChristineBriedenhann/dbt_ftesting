/*

  Generates a SQL query template that retrieves dbt test results for a specific model
  from the elementary_test_results table.

  Arguments:
    model_name (object): A relation object representing the target model, with the
                         following attributes:
      - database (str): The database where the model resides.
      - schema (str): The schema where the model resides.
      - identifier (str): The table/view name of the model.

  Returns:
    A SQL query (as a string) that selects all test results associated with
    the specified model from the elementary_test_results table.

  Dependencies:
    - ref('elementary_test_results'): The elementary package's test results table,
      which must exist and be accessible in the project.
*/
{% macro generate_test_result_template(model_name) %}
--depends_on: ref('elementary_test_results')

{% set database_name = model_name.database|trim|lower %}
{% set schema_name = model_name.schema|trim|lower %}
{% set model_table_name = model_name.identifier|trim|lower %}

{% set get_result_tables_list_sql %}
    with
        elementary_dbt_test_results as (
            select *
            from {{ref('elementary_test_results')}}
            where 1=1
                and upper(database_name) = upper('{{database_name}}')
                and upper(schema_name) = upper('{{schema_name}}')
                and upper(table_name) = upper('{{model_table_name}}')
        ),
        group_invocation as (
            select database_name, schema_name, table_name, invocation_id,
                max(detected_at) as last_run_timestamp
            from elementary_dbt_test_results
            group by all
        ),
        group_invocation_index as(
            select * 
                , row_number() over (partition by database_name, schema_name, table_name order by last_run_timestamp desc) as group_index
            from group_invocation
        ),
        final_data as (
            select t.*
            from elementary_dbt_test_results as t
            join group_invocation_index as i
                on t.invocation_id = i.invocation_id
                and t.database_name = i.database_name
                and t.schema_name = i.schema_name
                and t.table_name = i.table_name
            where i.group_index = 1
        )
    select *
    from final_data;
{% endset %}
{% set tbl_list_result = run_query(get_result_tables_list_sql) %}
{% set test_schema = generate_schema_name('dbt_test__audit') %}

{% set sql_template = [] %}
{% do sql_template.append("with") %}
{% do sql_template.append("src_data as (") %}
{% do sql_template.append("select * from " ~ ref('elementary_test_results')) %}
{% do sql_template.append("),") %}
{% do sql_template.append("test_data as (") %}
{% for rs in tbl_list_result %}
    {% set tb_sql = "select *, '" ~ rs["INVOCATION_ID"] ~ "' as invocation_id from " ~ database_name ~ "." ~ (test_schema|trim|lower) ~ "." ~ rs["TEST_ALIAS"] %}
    {% do sql_template.append(tb_sql) %}
    {% if not loop.last %}
        {% do sql_template.append("union all") %}
    {% endif %}
{% endfor %}
{% do sql_template.append("),") %}
{% do sql_template.append("final_data as (") %}
{% do sql_template.append("select") %}
{% do sql_template.append("src.*, " ~ convert_utc_to_ltz('tt.detected_at') ~ " as detected_at_ltz") %}
{% do sql_template.append("from test_data src") %}
{% do sql_template.append("inner join src_data tt") %}
{% do sql_template.append("on src.invocation_id = tt.invocation_id") %}
{% do sql_template.append(")") %}
{% do sql_template.append("select * from final_data") %}

{{ return(sql_template|join("\n"))}}

{% endmacro %}