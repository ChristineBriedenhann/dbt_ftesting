{% macro string_value_pattern_detection(column_name) %}
    CASE
        -- Email format
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$')
            THEN 'xyz@abc.mnm'
        -- Datetime with fractional seconds and AM/PM (e.g. 2026-01-15 02:30:00.123 PM)
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^[0-9]{4}\\-[0-9]{2}\\-[0-9]{2}[T ][0-9]{1,2}:[0-9]{2}:[0-9]{2}\\.[0-9]+\\s*(AM|PM|am|pm)$')
            THEN 'YYYY-MM-DD HH12:MI:SS.FF AM'
        -- Datetime with AM/PM (e.g. 2026-01-15 02:30:00 PM)
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^[0-9]{4}\\-[0-9]{2}\\-[0-9]{2}[T ][0-9]{1,2}:[0-9]{2}:[0-9]{2}\\s*(AM|PM|am|pm)$')
            THEN 'YYYY-MM-DD HH12:MI:SS AM'
        -- Datetime with fractional seconds and timezone (e.g. 2026-01-15 10:30:00.123456+13:00)
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^[0-9]{4}\\-[0-9]{2}\\-[0-9]{2}[T ][0-9]{1,2}:[0-9]{2}:[0-9]{2}\\.[0-9]+\\s*([+-][0-9]{2}:?[0-9]{2}|Z)$')
            THEN 'YYYY-MM-DD HH24:MI:SS.FF TZH:TZM'
        -- Datetime with timezone offset (e.g. 2026-01-15 10:30:00+13:00, 2026-01-15T10:30:00Z)
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^[0-9]{4}\\-[0-9]{2}\\-[0-9]{2}[T ][0-9]{1,2}:[0-9]{2}:[0-9]{2}\\s*([+-][0-9]{2}:?[0-9]{2}|Z)$')
            THEN 'YYYY-MM-DD HH24:MI:SS TZH:TZM'
        -- Datetime with fractional seconds (e.g. 2026-01-15 10:30:00.123456)
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^[0-9]{4}\\-[0-9]{2}\\-[0-9]{2}[T ][0-9]{1,2}:[0-9]{2}:[0-9]{2}\\.[0-9]+$')
            THEN 'YYYY-MM-DD HH24:MI:SS.FF'
        -- Datetime without fractional seconds (e.g. 2026-01-15 10:30:00)
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^[0-9]{4}\\-[0-9]{2}\\-[0-9]{2}[T ][0-9]{1,2}:[0-9]{2}:[0-9]{2}$')
            THEN 'YYYY-MM-DD HH24:MI:SS'
        -- Date format (YYYY-MM-DD)
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^[0-9]{4}\\-[0-9]{2}\\-[0-9]{2}$')
            THEN 'YYYY-MM-DD'
        -- Phone number (digits with spaces, dashes, parens, plus sign)
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^[\\(\\+]?[0-9][0-9\\s\\-\\(\\)]{5,}$')
            THEN REGEXP_REPLACE({{column_name}}::varchar, '[0-9]', 'N')
        -- Money (starts with $ or -$)
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^\\-?\\$[0-9,]+(\\.[0-9]+)?$')
            THEN REGEXP_REPLACE({{column_name}}::varchar, '[0-9]', 'N')
        -- Decimal number
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^\\-?[0-9,]+\\.[0-9]+$')
            THEN REGEXP_REPLACE({{column_name}}::varchar, '[0-9]', 'N')
        -- Whole number
        WHEN REGEXP_LIKE({{column_name}}::varchar, '^\\-?[0-9,]+$')
            THEN REGEXP_REPLACE({{column_name}}::varchar, '[0-9]', 'N')
        -- Single character
        WHEN LENGTH({{column_name}}::varchar) = 1
            THEN {{column_name}}::varchar
        -- Long string (>150 chars): truncated generic pattern
        WHEN LENGTH({{column_name}}::varchar) > 150
            THEN LEFT(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE({{column_name}}::varchar, '[A-Z]', 'A'), '[a-z]', 'a'), '[0-9]', 'n'), 50)
        -- Generic pattern: replace digits with 'n', uppercase with 'A', lowercase with 'a', keep separators
        ELSE REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE({{column_name}}::varchar, '[A-Z]', 'A'), '[a-z]', 'a'), '[0-9]', 'n')
    END
{% endmacro %}
