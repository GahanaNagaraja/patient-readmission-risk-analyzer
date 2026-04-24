-- Query 1: Overall readmission rate
-- Business question: What % of patients were readmitted?
-- Technique: Aggregation, ROUND, casting

SELECT
    COUNT(*)                                          AS total_admissions,
    SUM(readmission_flag::INT)                        AS total_readmissions,
    ROUND(
        SUM(readmission_flag::INT)::NUMERIC
        / COUNT(*) * 100, 2
    )                                                 AS readmission_rate_pct
FROM production.admissions;

-- Query 2: Readmission rate by department
-- Business question: Which departments have the highest readmission rates?
-- Technique: JOIN, GROUP BY, ORDER BY, ROUND

SELECT
    d.department_name,
    COUNT(a.admission_id)                             AS total_admissions,
    SUM(a.readmission_flag::INT)                      AS total_readmissions,
    ROUND(
        SUM(a.readmission_flag::INT)::NUMERIC
        / COUNT(a.admission_id) * 100, 2
    )                                                 AS readmission_rate_pct
FROM production.admissions a
JOIN production.departments d
    ON a.department_id = d.department_id
GROUP BY d.department_name
ORDER BY readmission_rate_pct DESC;

-- Query 3: Readmission rate by age group
-- Business question: Are older patients readmitted more frequently?
-- Technique: CASE WHEN for bucketing, DATE_PART, JOIN

SELECT
    CASE
        WHEN DATE_PART('year', AGE(p.date_of_birth)) < 18  THEN 'Under 18'
        WHEN DATE_PART('year', AGE(p.date_of_birth)) < 35  THEN '18-34'
        WHEN DATE_PART('year', AGE(p.date_of_birth)) < 50  THEN '35-49'
        WHEN DATE_PART('year', AGE(p.date_of_birth)) < 65  THEN '50-64'
        ELSE '65+'
    END                                               AS age_group,
    COUNT(a.admission_id)                             AS total_admissions,
    SUM(a.readmission_flag::INT)                      AS readmissions,
    ROUND(
        SUM(a.readmission_flag::INT)::NUMERIC
        / COUNT(a.admission_id) * 100, 2
    )                                                 AS readmission_rate_pct
FROM production.admissions a
JOIN production.patients p
    ON a.patient_id = p.patient_id
GROUP BY age_group
ORDER BY readmission_rate_pct DESC;

-- Query 4: Top 10 diagnosis codes driving readmissions
-- Business question: Which diagnoses are most associated with readmissions?
-- Technique: JOIN, GROUP BY, HAVING, ORDER BY

SELECT
    a.primary_diagnosis_code,
    COUNT(*)                                          AS total_admissions,
    SUM(a.readmission_flag::INT)                      AS readmissions,
    ROUND(
        SUM(a.readmission_flag::INT)::NUMERIC
        / COUNT(*) * 100, 2
    )                                                 AS readmission_rate_pct
FROM production.admissions a
GROUP BY a.primary_diagnosis_code
HAVING COUNT(*) > 10
ORDER BY readmission_rate_pct DESC
LIMIT 10;

-- Query 5: 30-day readmission flagging 
-- Business question: Which patients were readmitted within 30 days?
-- Technique: CTE, self-join, date arithmetic, DATEDIFF equivalent

WITH admission_pairs AS (
    SELECT
        a1.patient_id,
        a1.admission_id                               AS first_admission_id,
        a1.admission_date                             AS first_admission_date,
        a1.discharge_date                             AS discharge_date,
        a2.admission_id                               AS readmission_id,
        a2.admission_date                             AS readmission_date,
        (a2.admission_date - a1.discharge_date)       AS days_between
    FROM production.admissions a1
    JOIN production.admissions a2
        ON  a1.patient_id    = a2.patient_id
        AND a2.admission_date > a1.admission_date
        AND a1.discharge_date IS NOT NULL
)
SELECT
    p.patient_id,
    p.first_name || ' ' || p.last_name               AS patient_name,
    ap.first_admission_date,
    ap.discharge_date,
    ap.readmission_date,
    ap.days_between
FROM admission_pairs ap
JOIN production.patients p
    ON ap.patient_id = p.patient_id
WHERE ap.days_between <= 30
  AND ap.days_between >= 0
ORDER BY ap.days_between ASC;

-- Query 6: Average length of stay by department and admission type
-- Business question: How long do patients stay across departments?
-- Technique: Multi-column GROUP BY, AVG, ROUND, JOIN

SELECT
    d.department_name,
    a.admission_type,
    COUNT(*)                                          AS total_admissions,
    ROUND(AVG(a.length_of_stay), 1)                  AS avg_length_of_stay,
    MIN(a.length_of_stay)                             AS min_stay,
    MAX(a.length_of_stay)                             AS max_stay
FROM production.admissions a
JOIN production.departments d
    ON a.department_id = d.department_id
WHERE a.length_of_stay IS NOT NULL
GROUP BY d.department_name, a.admission_type
ORDER BY d.department_name, avg_length_of_stay DESC;

-- Query 7: Patients with multiple admissions
-- Business question: Which patients are being admitted repeatedly?
-- Technique: CTE, HAVING, subquery, JOIN

WITH frequent_patients AS (
    SELECT
        patient_id,
        COUNT(*)                                      AS admission_count,
        SUM(readmission_flag::INT)                    AS total_readmissions,
        MIN(admission_date)                           AS first_admission,
        MAX(admission_date)                           AS last_admission
    FROM production.admissions
    GROUP BY patient_id
    HAVING COUNT(*) >= 3
)
SELECT
    p.patient_id,
    p.first_name || ' ' || p.last_name               AS patient_name,
    DATE_PART('year', AGE(p.date_of_birth))::INT      AS age,
    p.insurance_provider,
    fp.admission_count,
    fp.total_readmissions,
    fp.first_admission,
    fp.last_admission,
    (fp.last_admission - fp.first_admission)          AS days_as_patient
FROM frequent_patients fp
JOIN production.patients p
    ON fp.patient_id = p.patient_id
ORDER BY fp.admission_count DESC
LIMIT 20;

-- Query 8: Doctor performance by readmission rate
-- Business question: Are some doctors associated with higher readmission rates?
-- Technique: CTE, JOIN, HAVING, ORDER BY

WITH doctor_stats AS (
    SELECT
        a.doctor_id,
        COUNT(*)                                      AS total_admissions,
        SUM(a.readmission_flag::INT)                  AS readmissions,
        ROUND(AVG(a.length_of_stay), 1)               AS avg_los
    FROM production.admissions a
    GROUP BY a.doctor_id
    HAVING COUNT(*) >= 20
)
SELECT
    doc.first_name || ' ' || doc.last_name            AS doctor_name,
    doc.specialization,
    d.department_name,
    ds.total_admissions,
    ds.readmissions,
    ROUND(
        ds.readmissions::NUMERIC
        / ds.total_admissions * 100, 2
    )                                                 AS readmission_rate_pct,
    ds.avg_los
FROM doctor_stats ds
JOIN production.doctors     doc ON ds.doctor_id     = doc.doctor_id
JOIN production.departments d   ON doc.department_id = d.department_id
ORDER BY readmission_rate_pct DESC;

-- Query 9: Ranking doctors by readmission rate within department
-- Business question: Who are the top/bottom performers in each department?
-- Technique: WINDOW function, RANK(), PARTITION BY

WITH doctor_rates AS (
    SELECT
        a.doctor_id,
        a.department_id,
        COUNT(*)                                      AS total_admissions,
        ROUND(
            SUM(a.readmission_flag::INT)::NUMERIC
            / COUNT(*) * 100, 2
        )                                             AS readmission_rate_pct
    FROM production.admissions a
    GROUP BY a.doctor_id, a.department_id
    HAVING COUNT(*) >= 10
)
SELECT
    doc.first_name || ' ' || doc.last_name            AS doctor_name,
    doc.specialization,
    d.department_name,
    dr.total_admissions,
    dr.readmission_rate_pct,
    RANK() OVER (
        PARTITION BY dr.department_id
        ORDER BY dr.readmission_rate_pct DESC
    )                                                 AS rank_in_department
FROM doctor_rates dr
JOIN production.doctors     doc ON dr.doctor_id     = doc.doctor_id
JOIN production.departments d   ON dr.department_id = d.department_id
ORDER BY d.department_name, rank_in_department;

-- Query 10: Running total of admissions per month
-- Business question: How is admission volume trending over time?
-- Technique: DATE_TRUNC, window function, SUM() OVER, ORDER BY

WITH monthly_admissions AS (
    SELECT
        DATE_TRUNC('month', admission_date)::DATE     AS admission_month,
        COUNT(*)                                      AS monthly_count,
        SUM(readmission_flag::INT)                    AS monthly_readmissions
    FROM production.admissions
    GROUP BY DATE_TRUNC('month', admission_date)
)
SELECT
    admission_month,
    monthly_count,
    monthly_readmissions,
    ROUND(
        monthly_readmissions::NUMERIC
        / monthly_count * 100, 2
    )                                                 AS monthly_readmission_rate,
    SUM(monthly_count) OVER (
        ORDER BY admission_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                 AS running_total_admissions
FROM monthly_admissions
ORDER BY admission_month;

-- Query 11: Days between admissions per patient using LAG
-- Business question: How quickly are patients returning to hospital?
-- Technique: LAG() window function, PARTITION BY, date arithmetic

SELECT
    p.patient_id,
    p.first_name || ' ' || p.last_name               AS patient_name,
    a.admission_date,
    a.discharge_date,
    a.primary_diagnosis_code,
    LAG(a.discharge_date) OVER (
        PARTITION BY a.patient_id
        ORDER BY a.admission_date
    )                                                 AS prev_discharge_date,
    (a.admission_date - LAG(a.discharge_date) OVER (
        PARTITION BY a.patient_id
        ORDER BY a.admission_date
    ))                                                AS days_since_last_discharge
FROM production.admissions a
JOIN production.patients p
    ON a.patient_id = p.patient_id
ORDER BY p.patient_id, a.admission_date;

-- Query 12: Patient risk scoring with NTILE quartiles
-- Business question: How do we segment patients into risk tiers?
-- Technique: CTE, NTILE(), CASE WHEN, multiple aggregations

WITH patient_scores AS (
    SELECT
        patient_id,
        COUNT(*)                                      AS total_admissions,
        SUM(readmission_flag::INT)                    AS total_readmissions,
        ROUND(AVG(length_of_stay), 1)                 AS avg_los,
        MAX(admission_date)                           AS last_admission
    FROM production.admissions
    GROUP BY patient_id
),
scored AS (
    SELECT
        ps.*,
        -- weighted risk score
        (ps.total_admissions * 1.0
         + ps.total_readmissions * 3.0
         + ps.avg_los * 0.5)                          AS raw_risk_score
    FROM patient_scores ps
)
SELECT
    p.patient_id,
    p.first_name || ' ' || p.last_name               AS patient_name,
    DATE_PART('year', AGE(p.date_of_birth))::INT      AS age,
    s.total_admissions,
    s.total_readmissions,
    s.avg_los,
    ROUND(s.raw_risk_score::NUMERIC, 2)               AS risk_score,
    CASE NTILE(4) OVER (ORDER BY s.raw_risk_score DESC)
        WHEN 1 THEN 'High Risk'
        WHEN 2 THEN 'Medium-High Risk'
        WHEN 3 THEN 'Medium-Low Risk'
        WHEN 4 THEN 'Low Risk'
    END                                               AS risk_tier,
    s.last_admission
FROM scored s
JOIN production.patients p
    ON s.patient_id = p.patient_id
ORDER BY s.raw_risk_score DESC;

-- Query 13: Monthly cohort readmission analysis
-- Business question: Do patients admitted in certain months get readmitted more?
-- Technique: DATE_TRUNC, cohort analysis pattern, CTE

WITH cohorts AS (
    SELECT
        patient_id,
        DATE_TRUNC('month', MIN(admission_date))::DATE AS cohort_month
    FROM production.admissions
    GROUP BY patient_id
),
cohort_activity AS (
    SELECT
        c.cohort_month,
        COUNT(DISTINCT c.patient_id)                  AS cohort_size,
        SUM(a.readmission_flag::INT)                  AS total_readmissions,
        ROUND(AVG(a.length_of_stay), 1)               AS avg_los
    FROM cohorts c
    JOIN production.admissions a
        ON c.patient_id = a.patient_id
    GROUP BY c.cohort_month
)
SELECT
    cohort_month,
    cohort_size,
    total_readmissions,
    avg_los,
    ROUND(
        total_readmissions::NUMERIC
        / cohort_size * 100, 2
    )                                                 AS readmission_rate_pct
FROM cohort_activity
ORDER BY cohort_month;

-- Query 14: Insurance provider analysis
-- Business question: Does insurance type affect readmission rates?
-- Technique: JOIN, GROUP BY, ROUND, ORDER BY

SELECT
    p.insurance_provider,
    COUNT(DISTINCT p.patient_id)                      AS total_patients,
    COUNT(a.admission_id)                             AS total_admissions,
    SUM(a.readmission_flag::INT)                      AS readmissions,
    ROUND(
        SUM(a.readmission_flag::INT)::NUMERIC
        / COUNT(a.admission_id) * 100, 2
    )                                                 AS readmission_rate_pct,
    ROUND(AVG(a.length_of_stay), 1)                   AS avg_length_of_stay
FROM production.patients p
JOIN production.admissions a
    ON p.patient_id = a.patient_id
WHERE p.insurance_provider IS NOT NULL
GROUP BY p.insurance_provider
ORDER BY readmission_rate_pct DESC;

-- Query 15: Abnormal lab results correlation with readmission
-- Business question: Do patients with abnormal labs get readmitted more?
-- Technique: CTE, JOIN, GROUP BY, ROUND

WITH admission_labs AS (
    SELECT
        l.admission_id,
        COUNT(*)                                      AS total_tests,
        SUM(l.is_abnormal::INT)                       AS abnormal_count,
        ROUND(
            SUM(l.is_abnormal::INT)::NUMERIC
            / COUNT(*) * 100, 2
        )                                             AS abnormal_rate_pct
    FROM production.lab_results l
    GROUP BY l.admission_id
)
SELECT
    CASE
        WHEN al.abnormal_rate_pct = 0        THEN 'No Abnormal Labs'
        WHEN al.abnormal_rate_pct < 25       THEN 'Low Abnormal (<25%)'
        WHEN al.abnormal_rate_pct < 50       THEN 'Medium Abnormal (25-50%)'
        ELSE                                      'High Abnormal (>50%)'
    END                                               AS abnormal_lab_tier,
    COUNT(*)                                          AS admissions,
    SUM(a.readmission_flag::INT)                      AS readmissions,
    ROUND(
        SUM(a.readmission_flag::INT)::NUMERIC
        / COUNT(*) * 100, 2
    )                                                 AS readmission_rate_pct
FROM admission_labs al
JOIN production.admissions a
    ON al.admission_id = a.admission_id
GROUP BY abnormal_lab_tier
ORDER BY readmission_rate_pct DESC;

-- Query 16: Most common abnormal lab tests
-- Business question: Which lab tests are flagging abnormal most often?
-- Technique: GROUP BY, ROUND, ORDER BY, LIMIT

SELECT
    test_name,
    COUNT(*)                                          AS total_tests,
    SUM(is_abnormal::INT)                             AS abnormal_count,
    ROUND(
        SUM(is_abnormal::INT)::NUMERIC
        / COUNT(*) * 100, 2
    )                                                 AS abnormal_rate_pct,
    ROUND(AVG(result_value)::NUMERIC, 3)              AS avg_result_value
FROM production.lab_results
WHERE result_value IS NOT NULL
GROUP BY test_name
ORDER BY abnormal_rate_pct DESC;

-- Query 17: ETL pipeline run history
-- Business question: How healthy is our data pipeline?
-- Technique: SELECT, ORDER BY, computed columns

SELECT
    log_id,
    run_timestamp,
    rows_extracted,
    rows_loaded,
    rows_rejected,
    rejection_rate                                    AS rejection_rate_pct,
    duration_seconds,
    status,
    COALESCE(error_message, 'None')                   AS error_message
FROM production.etl_pipeline_log
ORDER BY run_timestamp DESC;

-- Query 18: Data quality score over time
-- Business question: Is our data quality improving across pipeline runs?
-- Technique: Window function, LAG, computed quality score

SELECT
    run_timestamp,
    rows_extracted,
    rows_loaded,
    rows_rejected,
    rejection_rate                                    AS rejection_rate_pct,
    100 - rejection_rate                              AS quality_score_pct,
    LAG(rejection_rate) OVER (
        ORDER BY run_timestamp
    )                                                 AS prev_rejection_rate,
    rejection_rate - LAG(rejection_rate) OVER (
        ORDER BY run_timestamp
    )                                                 AS rejection_rate_change
FROM production.etl_pipeline_log
WHERE status = 'SUCCESS'
ORDER BY run_timestamp;

-- Query 19: Stored procedure to refresh risk scores
-- Technique: Stored procedure, CREATE OR REPLACE, transaction

CREATE OR REPLACE PROCEDURE production.refresh_risk_scores()
LANGUAGE plpgsql
AS $$
BEGIN
    -- log procedure start
    RAISE NOTICE 'Refreshing risk scores at %', NOW();

    UPDATE production.admissions a1
    SET readmission_flag = TRUE
    WHERE EXISTS (
        SELECT 1
        FROM production.admissions a2
        WHERE a2.patient_id    = a1.patient_id
          AND a2.admission_id  != a1.admission_id
          AND a2.admission_date > a1.admission_date
          AND a2.admission_date <= a1.admission_date + INTERVAL '30 days'
    );

    RAISE NOTICE 'Risk scores refreshed successfully';
END;
$$;

CALL production.refresh_risk_scores();

-- Query 20: Final executive summary query
-- Business question: Give me the full picture in one query
-- Technique: Multiple CTEs chained together

WITH summary_stats AS (
    SELECT
        COUNT(DISTINCT patient_id)                    AS total_patients,
        COUNT(*)                                      AS total_admissions,
        SUM(readmission_flag::INT)                    AS total_readmissions,
        ROUND(AVG(length_of_stay), 1)                 AS avg_length_of_stay
    FROM production.admissions
),
risk_distribution AS (
    SELECT
        CASE NTILE(4) OVER (ORDER BY COUNT(*) DESC)
            WHEN 1 THEN 'High Risk'
            WHEN 2 THEN 'Medium-High'
            WHEN 3 THEN 'Medium-Low'
            WHEN 4 THEN 'Low Risk'
        END                                           AS risk_tier,
        COUNT(DISTINCT patient_id)                    AS patient_count
    FROM production.admissions
    GROUP BY patient_id
),
top_diagnosis AS (
    SELECT primary_diagnosis_code, COUNT(*) AS cnt
    FROM production.admissions
    WHERE readmission_flag = TRUE
    GROUP BY primary_diagnosis_code
    ORDER BY cnt DESC
    LIMIT 1
)
SELECT
    ss.total_patients,
    ss.total_admissions,
    ss.total_readmissions,
    ROUND(
        ss.total_readmissions::NUMERIC
        / ss.total_admissions * 100, 2
    )                                                 AS overall_readmission_rate_pct,
    ss.avg_length_of_stay,
    td.primary_diagnosis_code                         AS top_readmission_diagnosis
FROM summary_stats ss
CROSS JOIN top_diagnosis td;