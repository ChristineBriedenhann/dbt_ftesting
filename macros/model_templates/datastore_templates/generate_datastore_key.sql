/*
  Generates a datastore key column expression based on the specified key type.

  This macro is used to produce a unique key column for a model, with different
  behavior depending on whether the model is running in incremental mode or not.

  Args:
    unique_key_cols_src (list|string): The source column(s) used to generate the unique key.
                                       Used as input for hash key generation.
    unique_key_name (string):          The alias name to assign to the generated key column.
    datastore_key_type (string):       The type of key to generate. Supported values:
                                         - "hash"     : Generates a hash-based key from the source columns.
                                         - "identity" : Generates a sequential integer key using row_number().
                                       Defaults to "hash" for any unrecognized value.
    _is_incremental (bool):            Controls whether incremental logic is applied.
                                         - false : Always generate a new key using the specified key type.
                                         - true  : (default) Use incremental logic to preserve existing keys.

  Returns:
    A SQL column expression string assigning the generated key to `unique_key_name`.
*/
{% macro generate_datastore_key(unique_key_cols_src, unique_key_name, datastore_key_type, _is_incremental=true) %}
{% if _is_incremental == false %}
    {% if datastore_key_type == "hash" -%}    
    {{ generate_hash_key(unique_key_cols_src) }} as {{ unique_key_name }},
    {% elif datastore_key_type == "identity" -%}
    row_number() over (order by seq4()) as {{ unique_key_name }},
    {% else -%}
    {{ generate_hash_key(unique_key_cols_src) }} as {{ unique_key_name }},
    {% endif -%}
{% else %}
    {% if datastore_key_type == "hash" -%}    
    {{ generate_hash_key(unique_key_cols_src) }} as {{ unique_key_name }},
    {% elif datastore_key_type == "identity" -%}
    (row_number() over (order by seq4()))+(select max_ds_key from max_ds_key_data) as {{ unique_key_name }},
    {% else -%}
    {{ generate_hash_key(unique_key_cols_src) }} as {{ unique_key_name }},
    {% endif -%}
{% endif %}
{% endmacro %}