{% macro prefix_fields(alias, fields) %}
    {# 
        This macro is to prefix the fields with the given alias. 
        It takes two parameters: alias (the prefix to be added) and fields (the list of fields to be prefixed).
        The input parameters have to be provided in format <alias> and <fields> as a list.
    #}
    {% set prefixed_fields = [] %}
    {% for field in fields %}
        {% set prefixed_field = alias ~ '.' ~ field %}
        {% do prefixed_fields.append(prefixed_field) %}
    {% endfor %}
    {{ return(prefixed_fields|join(',\n')) }}
{% endmacro %}