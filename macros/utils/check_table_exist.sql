/*
        This macro is to check if a table exists in the database.
        It takes a single argument, full_table_name, which is the fully qualified name of the table in the format "database.schema.table".
        Returns a relation object if the table exists, or None if it does not exist.
*/
{% macro check_table_exist(full_table_name) %}

    {%- set relation = adapter.get_relation(
        database=full_table_name.split('.')[0],
        schema=full_table_name.split('.')[1],
        identifier=full_table_name.split('.')[2]
    ) -%}
    
    {{return (relation)}}
{% endmacro %}
