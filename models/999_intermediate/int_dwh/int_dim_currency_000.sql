{%- set dwh_process_date = var('dwh_process_date') -%}
{%- set system_columns_list = system_columns_list() -%}
with
    src_data as (
        select
            {{
                dbt_utils.star(
                    from=ref('ds_netsuite2_currency'),
                    quote_identifiers=false,
                    relation_alias='src'
                )|lower
            }}
        from {{ ref('ds_netsuite2_currency') }} src
        where 1=1
            and '{{dwh_process_date}}'::timestamp_ntz between {{system_columns_list.system_start_date}}
                and {{system_columns_list.system_end_date}}
        qualify row_number() over (partition by id order by {{system_columns_list.system_version}} desc) = 1
    ),
    filter_deleted_records as (
        select *
        from src_data
        where 1=1
            and {{system_columns_list.system_delete_flag}} = 'N'
    )
select *
from filter_deleted_records