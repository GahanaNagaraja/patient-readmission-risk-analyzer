-- Full patient admission summary
CREATE OR REPLACE VIEW production.vw_admission_summary AS
SELECT
    a.admission_id,
    p.patient_id,
    p.first_name || ' ' || p.last_name      AS patient_name,
    DATE_PART('year', AGE(p.date_of_birth)) AS age,
    p.gender,
    p.insurance_provider,
    d.department_name,
    doc.first_name || ' ' || doc.last_name  AS doctor_name,
    a.admission_date,
    a.discharge_date,
    a.length_of_stay,
    a.admission_type,
    a.primary_diagnosis_code,
    a.readmission_flag,
    a.days_to_readmission,
    a.discharge_disposition
FROM production.admissions a
JOIN production.patients    p   ON a.patient_id    = p.patient_id
JOIN production.departments d   ON a.department_id = d.department_id
JOIN production.doctors     doc ON a.doctor_id     = doc.doctor_id;


-- High risk patients (readmitted within 30 days)
CREATE OR REPLACE VIEW production.vw_high_risk_patients AS
SELECT
    p.patient_id,
    p.first_name || ' ' || p.last_name      AS patient_name,
    DATE_PART('year', AGE(p.date_of_birth)) AS age,
    p.gender,
    p.insurance_provider,
    COUNT(a.admission_id)                   AS total_admissions,
    SUM(a.readmission_flag::INT)            AS total_readmissions,
    ROUND(
        SUM(a.readmission_flag::INT)::NUMERIC
        / COUNT(a.admission_id) * 100, 2
    )                                       AS readmission_rate_pct,
    MAX(a.admission_date)                   AS last_admission_date,
    AVG(a.length_of_stay)                   AS avg_length_of_stay
FROM production.patients p
JOIN production.admissions a ON p.patient_id = a.patient_id
GROUP BY
    p.patient_id, p.first_name, p.last_name,
    p.date_of_birth, p.gender, p.insurance_provider
HAVING SUM(a.readmission_flag::INT) > 0;


-- ETL pipeline health summary
CREATE OR REPLACE VIEW production.vw_etl_health AS
SELECT
    DATE(run_timestamp)         AS run_date,
    COUNT(*)                    AS total_runs,
    SUM(rows_extracted)         AS total_rows_extracted,
    SUM(rows_loaded)            AS total_rows_loaded,
    SUM(rows_rejected)          AS total_rows_rejected,
    ROUND(AVG(rejection_rate), 2) AS avg_rejection_rate_pct,
    ROUND(AVG(duration_seconds), 2) AS avg_duration_seconds,
    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) AS successful_runs,
    SUM(CASE WHEN status = 'FAILED'  THEN 1 ELSE 0 END) AS failed_runs
FROM production.etl_pipeline_log
GROUP BY DATE(run_timestamp)
ORDER BY run_date DESC;