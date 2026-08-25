/*
  Generates a dimension surrogate key column expression based on the specified key type.

  This macro is used to produce a surrogate key for dimension tables. It supports
  both hash-based and identity (sequential) key generation strategies, and handles
  logic differently depending on whether the model is being built incrementally or
  from scratch.

  Arguments:
    unique_key_cols_src  (list|string) : The source column(s) used to generate the surrogate key.
                                         Passed to `generate_hash_key` when dim_key_type is "hash".
    unique_key_name      (string)      : The alias name for the generated surrogate key column.
    dim_key_type         (string)      : The type of key to generate. Supported values:
                                           - "hash"     : Generates an MD5/SHA hash from source columns.
                                           - "identity" : Generates a sequential integer using row_number().
                                         Defaults to "hash" if an unrecognized value is provided.
    _is_incremental      (boolean)     : Controls whether incremental logic is applied.
                                           - false : Full refresh mode; generates the key from scratch.
                                           - true  : Incremental mode; uses existing key values where
                                                     possible (default: true).

  Returns:
    A SQL column expression (with alias) for the surrogate key.

  Example usage:
    {{ generate_dim_key(['customer_id', 'source_system'], 'customer_key', 'hash') }}
    {{ generate_dim_key(['order_id'], 'order_key', 'identity', _is_incremental=false) }}
*/
{% macro generate_dim_key(unique_key_cols_src, unique_key_name, dim_key_type, _is_incremental=true) %}
{% if _is_incremental == false %}
    {% if dim_key_type == "hash" -%}    
    {{ generate_hash_key(unique_key_cols_src) }} as {{ unique_key_name }},
    {% elif dim_key_type == "identity" -%}
    row_number() over (order by seq4()) as {{ unique_key_name }},
    {% else -%}
    {{ generate_hash_key(unique_key_cols_src) }} as {{ unique_key_name }},
    {% endif -%}
{% else %}
    {% if dim_key_type == "hash" -%}    
    {{ generate_hash_key(unique_key_cols_src) }} as {{ unique_key_name }},
    {% elif dim_key_type == "identity" -%}
    (row_number() over (order by seq4()))+(select max_dim_key from max_dim_key_data) as {{ unique_key_name }},
    {% else -%}
    {{ generate_hash_key(unique_key_cols_src) }} as {{ unique_key_name }},
    {% endif -%}
{% endif %}
{% endmacro %}