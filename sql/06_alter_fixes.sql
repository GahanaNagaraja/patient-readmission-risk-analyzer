SELECT
    CASE
        WHEN DATE_PART('year', AGE(p.date_of_birth)) >= 65 THEN '65+'
        ELSE 'Under 65'
    END AS age_group,
    ROUND(
        SUM(a.readmission_flag::INT)::NUMERIC
        / COUNT(*) * 100, 2
    ) AS readmission_rate_pct
FROM production.admissions a
JOIN production.patients p ON a.patient_id = p.patient_id
GROUP BY age_group;