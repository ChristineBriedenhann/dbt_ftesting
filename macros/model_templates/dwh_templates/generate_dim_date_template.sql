/*
  Macro: generate_dim_date_template
  Description:
    Generates a SQL template for building a date dimension table covering a specified
    range of years. This macro uses recursive CTEs to produce one row per calendar day
    between the given start and end years, enriching each date with a comprehensive set
    of date attributes (e.g., year, quarter, month, week, day-of-week, fiscal periods, etc.).

    It also incorporates system columns (via system_columns_list()) and uses project-level
    variables `low_date` and `high_date` as default SCD boundary timestamps.

  Arguments:
    start_year (int) : The first year to include in the date dimension (e.g., 2000).
    end_year   (int) : The last year to include in the date dimension (e.g., 2030).

  Variables used:
    low_date  (var) : The default "valid from" timestamp for SCD records.
    high_date (var) : The default "valid to" timestamp for SCD records.

  Returns:
    A SQL SELECT statement producing one row per calendar day within the specified
    year range, suitable for loading into a dim_date table.

  Example usage:
    {{ generate_dim_date_template(2000, 2030) }}
*/
{% macro generate_dim_date_template(start_year, end_year) %}
{%- set start_date = "'" ~ var("low_date") ~ "'::timestamp_ntz" -%} {# Default start date for the first version of record #}
{%- set end_date = "'" ~ var('high_date') ~ "'::timestamp_ntz" -%} {# Default end date for the first version of record #}
{%- set system_columns_list = system_columns_list() -%}
with recursive 
    calendardates as (
        select datefromparts('{{start_year}}'::int, 1, 1) as calendar_date
        union all
        select dateadd(day, 1, calendar_date)
        from calendardates
        where calendar_date < datefromparts('{{end_year}}'::int, 12, 31)
    ),
    add_dummy_dates as (
        select
            calendar_date as date
        from calendardates
        union all
        select datefromparts(1900, 1, 1) as date
        union all
        select datefromparts(2999, 12, 31) as date
        union all
        select datefromparts(9999, 12, 31) as date
    ),
    add_date_columns as (
        select
            to_varchar(date, 'yyyymmdd')::int as dim_date__key,
            date,
            year(date) as calendar_year,
            monthname(date) as calendar_month_name,
            month(date) as calendar_month_no,
            to_varchar(date, 'yyyymm')::int as calendar_month,
            dayname(date) as calendar_day_in_week,
            dayofweek(date)+1 as calendar_day_no_in_week,
            {{ start_date }} as {{ system_columns_list.system_start_date }},
            {{ end_date }} as {{ system_columns_list.system_end_date }},
            1::INT as {{  system_columns_list.system_version }},
            'Y' as {{ system_columns_list.system_current_flag }},
            'N' as {{ system_columns_list.system_delete_flag }},
            current_timestamp()::timestamp_ntz as {{ system_columns_list.system_create_time }},
            current_timestamp()::timestamp_ntz as {{ system_columns_list.system_update_time }}
        from add_dummy_dates
    )
select *
from add_date_columns
{% endmacro %}