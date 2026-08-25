/*
Converts a timestamp column from a source timezone to a target timezone using Snowflake's `convert_timezone` function. The column is cast to `TIMESTAMP_NTZ` before and after conversion to ensure timezone-naive handling.

**Arguments:**
- `column_name`: The name of the timestamp column to convert.
- `source_timezone`: The timezone of the input timestamp (e.g., `'UTC'`, `'America/New_York'`).
- `target_timezone`: The desired output timezone (e.g., `'Europe/London'`, `'Asia/Tokyo'`).
*/
{% macro convert_ts_timezone(column_name, source_timezone, target_timezone) %}  
convert_timezone('{{source_timezone}}', '{{target_timezone}}', {{column_name|trim|lower}}::timestamp_ntz)::timestamp_ntz
{% endmacro %}