/*
    This test checks the uniqueness of a combination of columns in a model.
    It returns all columns for rows where the combination of columns is not unique,
    making it easier to identify and debug duplicate records.

    Arguments:
    model                : The model to test
    combination_of_columns: A list of columns that should be unique in combination

    Usage example:
    tests:
        - uniqueness_test_return_all_columns:
            combination_of_columns:
            - column_1
            - column_2
*/
{% test uniqueness_test_return_all_columns(model, combination_of_columns) %}
    with
        src_data as (
            select *
                , {{ generate_hash_key(combination_of_columns) }} as hash_col
            from {{ model }}
        ),
        validation_error as (
            select 
                hash_col
            from src_data
            group by all
            having count(1) > 1
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