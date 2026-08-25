-----JSON flatten-------
{% set model_source = ref('int_ds_iris_patient_000') %}

{{
    int_datastore_json_parse_template(model_source)
}}