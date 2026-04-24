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