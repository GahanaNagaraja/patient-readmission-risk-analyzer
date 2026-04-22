-- ------------------------------------------------------------
-- 1. departments (lookup table — no dependencies)
-- ------------------------------------------------------------
CREATE TABLE production.departments (
    department_id     SERIAL PRIMARY KEY,
    department_name   VARCHAR(100) NOT NULL UNIQUE,
    department_type   VARCHAR(50)  NOT NULL
                      CHECK (department_type IN (
                          'ICU', 'Emergency', 'General',
                          'Surgical', 'Cardiology', 'Neurology',
                          'Oncology', 'Pediatrics', 'Orthopedics'
                      )),
    floor_number      SMALLINT     NOT NULL CHECK (floor_number > 0),
    total_beds        SMALLINT     NOT NULL CHECK (total_beds > 0),
    created_at        TIMESTAMP    NOT NULL DEFAULT NOW()
);

-- ------------------------------------------------------------
-- 2. doctors (depends on departments)
-- ------------------------------------------------------------
CREATE TABLE production.doctors (
    doctor_id         SERIAL PRIMARY KEY,
    first_name        VARCHAR(50)  NOT NULL,
    last_name         VARCHAR(50)  NOT NULL,
    specialization    VARCHAR(100) NOT NULL,
    department_id     INT          NOT NULL
                      REFERENCES production.departments(department_id)
                      ON DELETE RESTRICT,
    years_experience  SMALLINT     NOT NULL CHECK (years_experience >= 0),
    email             VARCHAR(150) NOT NULL UNIQUE,
    phone             VARCHAR(20),
    is_active         BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMP    NOT NULL DEFAULT NOW()
);

-- ------------------------------------------------------------
-- 3. patients (core table)
-- ------------------------------------------------------------
CREATE TABLE production.patients (
    patient_id        SERIAL PRIMARY KEY,
    first_name        VARCHAR(50)  NOT NULL,
    last_name         VARCHAR(50)  NOT NULL,
    date_of_birth     DATE         NOT NULL,
    gender            CHAR(1)      NOT NULL CHECK (gender IN ('M', 'F', 'O')),
    blood_type        VARCHAR(5)   CHECK (blood_type IN (
                          'A+','A-','B+','B-','AB+','AB-','O+','O-'
                      )),
    phone             VARCHAR(20),
    email             VARCHAR(150),
    address           TEXT,
    city              VARCHAR(100),
    state             VARCHAR(50),
    zip_code          VARCHAR(10),
    insurance_provider VARCHAR(100),
    insurance_id      VARCHAR(50),
    created_at        TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMP    NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_dob CHECK (date_of_birth <= CURRENT_DATE),
    CONSTRAINT chk_dob_reasonable CHECK (
        date_of_birth >= '1900-01-01'
    )
);

-- ------------------------------------------------------------
-- 4. admissions (links patients, doctors, departments)
-- ------------------------------------------------------------
CREATE TABLE production.admissions (
    admission_id          SERIAL PRIMARY KEY,
    patient_id            INT          NOT NULL
                          REFERENCES production.patients(patient_id)
                          ON DELETE RESTRICT,
    doctor_id             INT          NOT NULL
                          REFERENCES production.doctors(doctor_id)
                          ON DELETE RESTRICT,
    department_id         INT          NOT NULL
                          REFERENCES production.departments(department_id)
                          ON DELETE RESTRICT,
    admission_date        DATE         NOT NULL,
    discharge_date        DATE,
    admission_type        VARCHAR(20)  NOT NULL
                          CHECK (admission_type IN (
                              'Emergency', 'Elective', 'Urgent', 'Newborn'
                          )),
    discharge_disposition VARCHAR(50)
                          CHECK (discharge_disposition IN (
                              'Home', 'Transfer', 'AMA',
                              'Expired', 'Rehab', 'SNF'
                          )),
    primary_diagnosis_code VARCHAR(10) NOT NULL,
    readmission_flag      BOOLEAN      NOT NULL DEFAULT FALSE,
    days_to_readmission   SMALLINT     CHECK (days_to_readmission >= 0),
    length_of_stay        SMALLINT
                          GENERATED ALWAYS AS (
                              CASE
                                  WHEN discharge_date IS NOT NULL
                                  THEN (discharge_date - admission_date)::SMALLINT
                                  ELSE NULL
                              END
                          ) STORED,
    created_at            TIMESTAMP    NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_discharge_after_admission CHECK (
        discharge_date IS NULL OR discharge_date >= admission_date
    ),
    CONSTRAINT chk_readmission_days CHECK (
        (readmission_flag = FALSE AND days_to_readmission IS NULL)
        OR (readmission_flag = TRUE AND days_to_readmission IS NOT NULL)
    )
);

-- ------------------------------------------------------------
-- 5. diagnoses (multiple diagnoses per admission)
-- ------------------------------------------------------------
CREATE TABLE production.diagnoses (
    diagnosis_id      SERIAL PRIMARY KEY,
    admission_id      INT          NOT NULL
                      REFERENCES production.admissions(admission_id)
                      ON DELETE CASCADE,
    icd10_code        VARCHAR(10)  NOT NULL,
    icd10_description VARCHAR(255) NOT NULL,
    diagnosis_type    VARCHAR(20)  NOT NULL
                      CHECK (diagnosis_type IN (
                          'Primary', 'Secondary', 'Comorbidity'
                      )),
    diagnosis_date    DATE         NOT NULL,
    severity          VARCHAR(10)
                      CHECK (severity IN (
                          'Mild', 'Moderate', 'Severe', 'Critical'
                      )),
    created_at        TIMESTAMP    NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_admission_icd10
        UNIQUE (admission_id, icd10_code)
);

-- ------------------------------------------------------------
-- 6. medications (medications per admission)
-- ------------------------------------------------------------
CREATE TABLE production.medications (
    medication_id     SERIAL PRIMARY KEY,
    admission_id      INT          NOT NULL
                      REFERENCES production.admissions(admission_id)
                      ON DELETE CASCADE,
    medication_name   VARCHAR(150) NOT NULL,
    dosage            VARCHAR(50)  NOT NULL,
    frequency         VARCHAR(50)  NOT NULL,
    start_date        DATE         NOT NULL,
    end_date          DATE,
    prescribed_by     INT
                      REFERENCES production.doctors(doctor_id)
                      ON DELETE SET NULL,
    created_at        TIMESTAMP    NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_med_end_after_start CHECK (
        end_date IS NULL OR end_date >= start_date
    )
);

-- ------------------------------------------------------------
-- 7. lab_results (lab tests per admission)
-- ------------------------------------------------------------
CREATE TABLE production.lab_results (
    lab_result_id     SERIAL PRIMARY KEY,
    admission_id      INT          NOT NULL
                      REFERENCES production.admissions(admission_id)
                      ON DELETE CASCADE,
    test_name         VARCHAR(100) NOT NULL,
    test_date         DATE         NOT NULL,
    result_value      NUMERIC(10,3),
    result_unit       VARCHAR(30),
    reference_min     NUMERIC(10,3),
    reference_max     NUMERIC(10,3),
    is_abnormal       BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at        TIMESTAMP    NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_reference_range CHECK (
        reference_min IS NULL
        OR reference_max IS NULL
        OR reference_min <= reference_max
    )
);

-- ------------------------------------------------------------
-- 8. etl_pipeline_log (audit trail for every ETL run)
-- ------------------------------------------------------------
CREATE TABLE production.etl_pipeline_log (
    log_id              SERIAL PRIMARY KEY,
    run_timestamp       TIMESTAMP    NOT NULL DEFAULT NOW(),
    pipeline_stage      VARCHAR(20)  NOT NULL
                        CHECK (pipeline_stage IN (
                            'EXTRACT', 'TRANSFORM', 'LOAD', 'FULL'
                        )),
    source_file         VARCHAR(255),
    rows_extracted      INT          DEFAULT 0,
    rows_transformed    INT          DEFAULT 0,
    rows_loaded         INT          DEFAULT 0,
    rows_rejected       INT          DEFAULT 0,
    rejection_rate      NUMERIC(5,2)
                        GENERATED ALWAYS AS (
                            CASE
                                WHEN rows_extracted > 0
                                THEN ROUND(
                                    (rows_rejected::NUMERIC / rows_extracted) * 100,
                                    2
                                )
                                ELSE 0
                            END
                        ) STORED,
    status              VARCHAR(10)  NOT NULL
                        CHECK (status IN ('SUCCESS', 'FAILED', 'PARTIAL')),
    error_message       TEXT,
    duration_seconds    NUMERIC(8,2),
    created_at          TIMESTAMP    NOT NULL DEFAULT NOW()
);