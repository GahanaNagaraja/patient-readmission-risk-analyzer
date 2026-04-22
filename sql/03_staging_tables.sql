CREATE TABLE staging.stg_patients (
    raw_id              SERIAL PRIMARY KEY,
    patient_id          VARCHAR(50),
    first_name          VARCHAR(100),
    last_name           VARCHAR(100),
    date_of_birth       VARCHAR(50),  -- raw string, mixed formats
    gender              VARCHAR(20),
    blood_type          VARCHAR(20),
    phone               VARCHAR(50),
    email               VARCHAR(200),
    address             TEXT,
    city                VARCHAR(100),
    state               VARCHAR(100),
    zip_code            VARCHAR(20),
    insurance_provider  VARCHAR(200),
    insurance_id        VARCHAR(100),
    load_timestamp      TIMESTAMP    DEFAULT NOW(),
    is_processed        BOOLEAN      DEFAULT FALSE,
    rejection_reason    TEXT
);

CREATE TABLE staging.stg_admissions (
    raw_id                  SERIAL PRIMARY KEY,
    admission_id            VARCHAR(50),
    patient_id              VARCHAR(50),
    doctor_id               VARCHAR(50),
    department              VARCHAR(100),
    admission_date          VARCHAR(50),  -- raw string, mixed formats
    discharge_date          VARCHAR(50),
    admission_type          VARCHAR(50),
    discharge_disposition   VARCHAR(100),
    primary_diagnosis_code  VARCHAR(50),
    load_timestamp          TIMESTAMP    DEFAULT NOW(),
    is_processed            BOOLEAN      DEFAULT FALSE,
    rejection_reason        TEXT
);

CREATE TABLE staging.stg_lab_results (
    raw_id           SERIAL PRIMARY KEY,
    admission_id     VARCHAR(50),
    test_name        VARCHAR(200),
    test_date        VARCHAR(50),
    result_value     VARCHAR(50),  -- raw string, may be non-numeric
    result_unit      VARCHAR(50),
    reference_range  VARCHAR(100), -- e.g. "3.5 - 5.0", needs parsing
    load_timestamp   TIMESTAMP    DEFAULT NOW(),
    is_processed     BOOLEAN      DEFAULT FALSE,
    rejection_reason TEXT
);