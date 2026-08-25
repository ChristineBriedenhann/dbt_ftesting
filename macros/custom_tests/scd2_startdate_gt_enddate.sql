{% test scd2_startdate_gt_enddate(model, business_key_columns, start_date_column, end_date_column) %}
    with
        src_data as (
            select *
                , {{ generate_hash_key(business_key_columns) }} as hash_col
            from {{ model }}
        ),
        validation_error as (
            select 
                hash_col,
                {{ start_date_column }},
                {{ end_date_column }}
            from src_data
            where {{ start_date_column }} >= {{ end_date_column }}
        ),
        final_data as (
            select src.*
            from src_data src
            inner join validation_error ve
                on src.hash_col = ve.hash_col
                and src.{{ start_date_column }} = ve.{{ start_date_column }}
                and src.{{ end_date_column }} = ve.{{ end_date_column }}
        )
    select * exclude (hash_col)
    from final_data
{% endtest %}