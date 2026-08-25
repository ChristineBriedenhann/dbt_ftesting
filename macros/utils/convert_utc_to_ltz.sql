/*
        Converts a UTC timestamp column to the project's local timezone.
    
    Args:
        column_name: The name of the column containing a UTC timestamp to convert.
    
    Returns:
        A TIMESTAMP_NTZ value converted from UTC to the timezone specified
        by the 'project_timezone' dbt variable.
*/
{% macro convert_utc_to_ltz(column_name) %}  
convert_timezone('UTC', '{{var("project_timezone")}}', {{column_name|trim|lower}}::timestamp_ntz)::timestamp_ntz
{% endmacro %}