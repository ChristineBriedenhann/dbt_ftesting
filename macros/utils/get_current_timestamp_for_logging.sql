/*
    Returns the current timestamp formatted as 'YYYY-MM-DD HH:MM:SS.ffffff' in the specified timezone.
    Defaults to 'Pacific/Auckland' (New Zealand Time).
    Useful for generating human-readable timestamps for logging purposes.
*/
{% macro get_current_timestamp_for_logging(timezone='Pacific/Auckland') %}
    {% set nzt_timezone = modules.pytz.timezone(timezone) %}
    {{ return(modules.datetime.datetime.now(nzt_timezone).strftime('%Y-%m-%d %H:%M:%S.%f')) }}
{% endmacro %}