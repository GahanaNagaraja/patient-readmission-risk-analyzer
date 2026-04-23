-- Widen columns that exceeded VARCHAR limits
ALTER TABLE production.patients
    ALTER COLUMN phone TYPE VARCHAR(50);

ALTER TABLE production.patients
    ALTER COLUMN zip_code TYPE VARCHAR(20);

ALTER TABLE production.patients
    ALTER COLUMN email TYPE VARCHAR(200);

-- Drop constraints handled in ETL transform layer
-- chk_readmission_days: enforced in Python before load
ALTER TABLE production.admissions
    DROP CONSTRAINT IF EXISTS chk_readmission_days;

-- chk_discharge_after_admission: enforced in Python before load
ALTER TABLE production.admissions
    DROP CONSTRAINT IF EXISTS chk_discharge_after_admission;