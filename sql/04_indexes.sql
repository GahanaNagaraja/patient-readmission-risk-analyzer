-- patients
CREATE INDEX idx_patients_dob
    ON production.patients(date_of_birth);

CREATE INDEX idx_patients_name
    ON production.patients(last_name, first_name);

-- admissions (most queried table)
CREATE INDEX idx_admissions_patient
    ON production.admissions(patient_id);

CREATE INDEX idx_admissions_doctor
    ON production.admissions(doctor_id);

CREATE INDEX idx_admissions_department
    ON production.admissions(department_id);

CREATE INDEX idx_admissions_date
    ON production.admissions(admission_date);

CREATE INDEX idx_admissions_readmission
    ON production.admissions(readmission_flag)
    WHERE readmission_flag = TRUE;

-- diagnoses
CREATE INDEX idx_diagnoses_admission
    ON production.diagnoses(admission_id);

CREATE INDEX idx_diagnoses_icd10
    ON production.diagnoses(icd10_code);

-- lab results
CREATE INDEX idx_lab_admission
    ON production.lab_results(admission_id);

CREATE INDEX idx_lab_abnormal
    ON production.lab_results(is_abnormal)
    WHERE is_abnormal = TRUE;

-- staging
CREATE INDEX idx_stg_patients_processed
    ON staging.stg_patients(is_processed);

CREATE INDEX idx_stg_admissions_processed
    ON staging.stg_admissions(is_processed);