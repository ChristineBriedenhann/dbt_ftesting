{% macro generate_hash_key(columns) %}
md5(
    {%- for col in columns %}
    nvl({{col}}::varchar, 'NULL') {%- if not loop.last -%}|| '-' ||{%- endif -%}
    {%- endfor %}
)
{% endmacro %}