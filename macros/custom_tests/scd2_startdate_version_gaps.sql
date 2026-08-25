{% test scd2_startdate_version_gaps(model, business_key_columns, start_date_column, end_date_column) %}
    with
        src_data as (
            select *
                , {{ generate_hash_key(business_key_columns) }} as hash_col
            from {{ model }}
        ),
        order_index as (
            select 
                src.*
                , coalesce(lead(dbt_start_date) over (partition by hash_col order by dbt_start_date),'{{var("high_date")}}'::timestamp_ntz) as next_dbt_start_date
                , datediff('ms', dbt_end_date, next_dbt_start_date) as gaps_in_ms
            from src_data src
        ),
        validation_error as (
            select distinct
                hash_col
            from order_index
            where gaps_in_ms > 3 --gap time greater than 3 miliseconds
        ),
        final_data as (
            select src.*
            from src_data src
            inner join validation_error ve
                on src.hash_col = ve.hash_col
        )
    select * exclude (hash_col)
    from final_data
{% endtest %}