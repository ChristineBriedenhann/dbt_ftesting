----Data type cast----
{% set model_source = ref('int_ds_iris_patient_010') -%}
{%- set ref_column_list = dbt_utils.get_filtered_columns_in_relation(model_source) -%}
with
    src_data as (
        select
            {{ prefix_fields("src", ref_column_list)|lower }}
        from {{model_source}} src
    ),
    cast_data_type as (
        select
            *,
            try_to_number(insurance_info_copay) as insurance_info_copay_cast
        from src_data
    )
select *
    exclude (insurance_info_copay)
    rename insurance_info_copay_cast as insurance_info_copay
from cast_data_type