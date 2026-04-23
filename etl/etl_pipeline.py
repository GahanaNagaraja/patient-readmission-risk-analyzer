import pandas as pd
import numpy as np
import json
import os
import re
import logging
from datetime import datetime, date
from sqlalchemy import create_engine, text
from dotenv import load_dotenv

load_dotenv()

# ============================================================
# LOGGING SETUP
# ============================================================
os.makedirs("logs", exist_ok=True)
log_file = f"logs/etl_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler()
    ]
)
log = logging.getLogger(__name__)

# ============================================================
# DATABASE CONNECTION
# ============================================================
def get_engine():
    url = (
        f"postgresql+psycopg2://"
        f"{os.getenv('DB_USER')}:{os.getenv('DB_PASSWORD')}"
        f"@{os.getenv('DB_HOST')}:{os.getenv('DB_PORT')}"
        f"/{os.getenv('DB_NAME')}"
    )
    return create_engine(url)

# ============================================================
# PIPELINE LOG HELPER
# ============================================================
def write_pipeline_log(engine, stage, source_file,
                       rows_extracted, rows_transformed,
                       rows_loaded, rows_rejected,
                       status, error_message, duration):
    sql = text("""
        INSERT INTO production.etl_pipeline_log (
            pipeline_stage, source_file,
            rows_extracted, rows_transformed,
            rows_loaded, rows_rejected,
            status, error_message, duration_seconds
        ) VALUES (
            :stage, :source_file,
            :rows_extracted, :rows_transformed,
            :rows_loaded, :rows_rejected,
            :status, :error_message, :duration
        )
    """)
    with engine.connect() as conn:
        conn.execute(sql, {
            "stage":            stage,
            "source_file":      source_file,
            "rows_extracted":   rows_extracted,
            "rows_transformed": rows_transformed,
            "rows_loaded":      rows_loaded,
            "rows_rejected":    rows_rejected,
            "status":           status,
            "error_message":    error_message,
            "duration":         round(duration, 2),
        })
        conn.commit()

# ============================================================
# DATE STANDARDIZATION
# ============================================================
DATE_FORMATS = [
    "%Y-%m-%d", "%m/%d/%Y", "%d-%m-%Y",
    "%d/%m/%Y", "%Y/%m/%d", "%b %d, %Y", "%d %B %Y",
]

def parse_date(val):
    """Try every known format. Return ISO string or None."""
    if pd.isna(val) or str(val).strip() in ("", "N/A", "00/00/0000", "null"):
        return None
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(str(val).strip(), fmt).date().isoformat()
        except ValueError:
            continue
    return None

# ============================================================
# GENDER NORMALIZATION
# ============================================================
GENDER_MAP = {
    "m": "M", "male": "M", "man": "M",
    "f": "F", "female": "F", "woman": "F",
    "o": "O", "other": "O", "non-binary": "O",
}

def normalize_gender(val):
    if pd.isna(val) or str(val).strip() == "":
        return None
    return GENDER_MAP.get(str(val).strip().lower(), None)

# ============================================================
# BOOLEAN NORMALIZATION
# ============================================================
TRUE_VALS  = {"true", "1", "yes", "y", "t"}
FALSE_VALS = {"false", "0", "no", "n", "f"}

def normalize_bool(val):
    if pd.isna(val) or str(val).strip() == "":
        return False
    cleaned = str(val).strip().lower()
    if cleaned in TRUE_VALS:  return True
    if cleaned in FALSE_VALS: return False
    return False

# ============================================================
# ICD-10 VALIDATION
# ============================================================
VALID_ICD10_CODES = {
    "I21.0","I50.9","J18.9","N18.3","E11.9","I10","J44.1",
    "K92.1","A41.9","I63.9","F32.1","M54.5","K35.80",
    "S72.001","C34.10",
}

def is_valid_icd10(code):
    if pd.isna(code) or str(code).strip() == "":
        return False
    pattern = r'^[A-Z][0-9]{2}(\.[A-Z0-9]{1,4})?$'
    c = str(code).strip().upper()
    return bool(re.match(pattern, c))

# ============================================================
# REFERENCE RANGE PARSER
# ============================================================
def parse_reference_range(val):
    """Extract (min, max) from strings like '3.5 - 5.0'. Return (None, None) if unparseable."""
    if pd.isna(val) or str(val).strip() in ("", "N/A", "see report"):
        return None, None
    match = re.search(r'([\d.]+)\s*[-to]+\s*([\d.]+)', str(val))
    if match:
        return float(match.group(1)), float(match.group(2))
    return None, None

# ============================================================
# STAGE 1 — EXTRACT
# ============================================================
def extract(engine):
    log.info("=" * 60)
    log.info("STAGE 1 — EXTRACT")
    log.info("=" * 60)
    start = datetime.now()
    results = {}

    sources = {
        "patients":    ("data/raw/patients_raw.csv",     "csv"),
        "admissions":  ("data/raw/admissions_raw.csv",   "csv"),
        "lab_results": ("data/raw/lab_results_raw.json", "json"),
    }

    for name, (path, fmt) in sources.items():
        try:
            if not os.path.exists(path):
                raise FileNotFoundError(f"Source file not found: {path}")

            if fmt == "csv":
                df = pd.read_csv(path, dtype=str, keep_default_na=False)
            else:
                with open(path, "r") as f:
                    raw = json.load(f)
                df = pd.DataFrame(raw)

            # normalize column names to lowercase
            df.columns = [c.strip().lower() for c in df.columns]

            rows = len(df)
            results[name] = df
            log.info(f"  Extracted {rows:>7,} rows  <-  {path}")

            # load into staging
            table_map = {
                "patients":    "stg_patients",
                "admissions":  "stg_admissions",
                "lab_results": "stg_lab_results",
            }
            df.to_sql(
                table_map[name],
                engine,
                schema="staging",
                if_exists="replace",
                index=False,
                chunksize=1000,
            )
            log.info(f"  Loaded into staging.{table_map[name]}")

        except Exception as e:
            log.error(f"  EXTRACT failed for {name}: {e}")
            results[name] = pd.DataFrame()

    duration = (datetime.now() - start).total_seconds()
    log.info(f"  Extract complete in {duration:.2f}s")
    return results, duration

# ============================================================
# STAGE 2 — TRANSFORM
# ============================================================
def transform(raw: dict):
    log.info("=" * 60)
    log.info("STAGE 2 — TRANSFORM")
    log.info("=" * 60)
    start   = datetime.now()
    cleaned = {}
    stats   = {}

    # ----------------------------------------------------------
    # 2a. PATIENTS
    # ----------------------------------------------------------
    log.info("  Transforming patients ...")
    df = raw["patients"].copy()
    initial = len(df)

    df["date_of_birth"] = df.get("date_of_birth", pd.Series()).apply(parse_date)
    df["gender"]        = df.get("gender",        pd.Series()).apply(normalize_gender)

    valid_bt = {"A+","A-","B+","B-","AB+","AB-","O+","O-"}
    df["blood_type"] = df.get("blood_type", pd.Series()).apply(
        lambda x: x.strip() if str(x).strip() in valid_bt else None
    )
    df["insurance_id"] = df.get("insurance_id", pd.Series()).apply(
        lambda x: x.strip() if str(x).strip() not in ("", "nan", "None") else None
    )

    df["_reject"] = False
    df["_reason"] = ""

    missing_dob    = df["date_of_birth"].isna()
    missing_gender = df["gender"].isna()
    df.loc[missing_dob,    "_reject"] = True
    df.loc[missing_dob,    "_reason"] = "Missing or unparseable date_of_birth"
    df.loc[missing_gender & ~df["_reject"], "_reject"] = True
    df.loc[missing_gender & ~df["_reject"], "_reason"] = "Missing or unrecognized gender"

    name_col  = "first_name" if "first_name" in df.columns else df.columns[1]
    lname_col = "last_name"  if "last_name"  in df.columns else df.columns[2]
    before_dedup = len(df)
    df = df.drop_duplicates(subset=[name_col, lname_col, "date_of_birth"], keep="first")
    deduped = before_dedup - len(df)
    if deduped > 0:
        log.info(f"    Removed {deduped:,} duplicate patient rows")

    rejected_p = df[df["_reject"] == True]
    accepted_p = df[df["_reject"] == False].drop(columns=["_reject","_reason"])

    stats["patients"] = {
        "extracted":   initial,
        "transformed": len(accepted_p),
        "rejected":    len(rejected_p),
    }
    cleaned["patients"] = accepted_p
    log.info(f"    Accepted: {len(accepted_p):,}  |  Rejected: {len(rejected_p):,}")

    # ----------------------------------------------------------
    # 2b. ADMISSIONS
    # ----------------------------------------------------------
    log.info("  Transforming admissions ...")
    df = raw["admissions"].copy()
    initial = len(df)

    df["admission_date"]   = df.get("admission_date",   pd.Series()).apply(parse_date)
    df["discharge_date"]   = df.get("discharge_date",   pd.Series()).apply(parse_date)
    df["readmission_flag"] = df.get("readmission_flag", pd.Series()).apply(normalize_bool)

    def safe_int(v):
        try:
            val = int(float(str(v).strip()))
            return val if val >= 0 else None
        except:
            return None

    df["days_to_readmission"] = df.get("days_to_readmission", pd.Series()).apply(safe_int)

    # fix inconsistency: if readmission=True but no days value, set readmission=False
    for idx, row in df.iterrows():
        if row["readmission_flag"] == True and row["days_to_readmission"] is None:
            df.at[idx, "readmission_flag"] = False

    valid_at = {"Emergency","Elective","Urgent","Newborn"}
    df["admission_type"] = df.get("admission_type", pd.Series()).apply(
        lambda x: x.strip() if str(x).strip() in valid_at else "Elective"
    )

    valid_dd = {"Home","Transfer","AMA","Expired","Rehab","SNF"}
    df["discharge_disposition"] = df.get("discharge_disposition", pd.Series()).apply(
        lambda x: x.strip() if str(x).strip() in valid_dd else None
    )

    df = df.drop_duplicates(subset=["admission_id"], keep="first")
    # fix: discharge before admission — set discharge to None
    def fix_discharge(row):
        if row["discharge_date"] and row["admission_date"]:
            if row["discharge_date"] < row["admission_date"]:
                return None
        return row["discharge_date"]
    df["discharge_date"] = df.apply(fix_discharge, axis=1)
    df["_icd_valid"] = df.get("primary_diagnosis_code", pd.Series()).apply(is_valid_icd10)

    df["_reject"] = False
    df["_reason"] = ""

    no_adm_date = df["admission_date"].isna()
    bad_icd     = ~df["_icd_valid"]
    df.loc[no_adm_date,              "_reject"] = True
    df.loc[no_adm_date,              "_reason"] = "Missing or unparseable admission_date"
    df.loc[bad_icd & ~df["_reject"], "_reject"] = True
    df.loc[bad_icd & ~df["_reject"], "_reason"] = "Invalid ICD-10 code"

    rejected_a = df[df["_reject"] == True]
    accepted_a = df[df["_reject"] == False].drop(
        columns=["_reject","_reason","_icd_valid"]
    )

    stats["admissions"] = {
        "extracted":   initial,
        "transformed": len(accepted_a),
        "rejected":    len(rejected_a),
    }
    cleaned["admissions"] = accepted_a
    log.info(f"    Accepted: {len(accepted_a):,}  |  Rejected: {len(rejected_a):,}")
    log.info(f"    Invalid ICD-10: {bad_icd.sum():,} rows rejected")

    # ----------------------------------------------------------
    # 2c. LAB RESULTS
    # ----------------------------------------------------------
    log.info("  Transforming lab_results ...")
    df = raw["lab_results"].copy()
    initial = len(df)

    df["test_date"] = df.get("test_date", pd.Series()).apply(parse_date)

    def parse_result(v):
        try:
            return float(str(v).strip()), False
        except:
            return None, True

    parsed              = df.get("result_value", pd.Series()).apply(parse_result)
    df["result_value"]  = parsed.apply(lambda x: x[0])
    df["_unparseable"]  = parsed.apply(lambda x: x[1])

    ranges              = df.get("reference_range", pd.Series()).apply(parse_reference_range)
    df["reference_min"] = ranges.apply(lambda x: x[0])
    df["reference_max"] = ranges.apply(lambda x: x[1])

    def flag_abnormal(row):
        if row["result_value"] is None:
            return False
        if row["reference_min"] is not None and row["result_value"] < row["reference_min"]:
            return True
        if row["reference_max"] is not None and row["result_value"] > row["reference_max"]:
            return True
        return False

    df["is_abnormal"] = df.apply(flag_abnormal, axis=1)

    df["_reject"] = False
    df["_reason"] = ""

    no_date = df["test_date"].isna()
    no_adm  = df.get("admission_id", pd.Series()).apply(
        lambda x: pd.isna(x) or str(x).strip() == ""
    )
    df.loc[no_date,                "_reject"] = True
    df.loc[no_date,                "_reason"] = "Missing or unparseable test_date"
    df.loc[no_adm & ~df["_reject"],"_reject"] = True
    df.loc[no_adm & ~df["_reject"],"_reason"] = "Missing admission_id"

    rejected_l = df[df["_reject"] == True]
    drop_cols = ["_reject","_reason","_unparseable","reference_range"]
    drop_cols = [c for c in drop_cols if c in df.columns]
    accepted_l = df[df["_reject"] == False].drop(columns=drop_cols)

    stats["lab_results"] = {
        "extracted":   initial,
        "transformed": len(accepted_l),
        "rejected":    len(rejected_l),
    }
    cleaned["lab_results"] = accepted_l
    log.info(f"    Accepted: {len(accepted_l):,}  |  Rejected: {len(rejected_l):,}")
    log.info(f"    Abnormal results flagged: {df['is_abnormal'].sum():,}")

    duration = (datetime.now() - start).total_seconds()
    log.info(f"  Transform complete in {duration:.2f}s")
    return cleaned, stats, duration

# ============================================================
# STAGE 3 — LOAD
# ============================================================
def load(engine, cleaned: dict, stats: dict):
    log.info("=" * 60)
    log.info("STAGE 3 — LOAD")
    log.info("=" * 60)
    start        = datetime.now()
    total_loaded = 0

    with engine.connect() as conn:
        try:
            # seed departments if empty
            result = conn.execute(text("SELECT COUNT(*) FROM production.departments"))
            if result.scalar() == 0:
                dept_data = [
                    ("ICU",         "ICU",         2, 20),
                    ("Emergency",   "Emergency",   1, 50),
                    ("General",     "General",     3, 40),
                    ("Surgical",    "Surgical",    4, 30),
                    ("Cardiology",  "Cardiology",  5, 25),
                    ("Neurology",   "Neurology",   6, 20),
                    ("Oncology",    "Oncology",    7, 15),
                    ("Pediatrics",  "Pediatrics",  8, 30),
                    ("Orthopedics", "Orthopedics", 9, 25),
                ]
                conn.execute(text("""
                    INSERT INTO production.departments
                        (department_name, department_type, floor_number, total_beds)
                    VALUES (:name, :type, :floor, :beds)
                    ON CONFLICT (department_name) DO NOTHING
                """), [{"name":d[0],"type":d[1],"floor":d[2],"beds":d[3]} for d in dept_data])
                log.info("  Seeded departments table")

            # seed doctors if empty
            result = conn.execute(text("SELECT COUNT(*) FROM production.doctors"))
            if result.scalar() == 0:
                dept_ids = {
                    row[0]: row[1] for row in conn.execute(
                        text("SELECT department_name, department_id FROM production.departments")
                    )
                }
                specializations = [
                    ("Cardiology",  "Cardiologist"),
                    ("Neurology",   "Neurologist"),
                    ("ICU",         "Intensivist"),
                    ("Emergency",   "Emergency Physician"),
                    ("General",     "General Practitioner"),
                    ("Surgical",    "Surgeon"),
                    ("Oncology",    "Oncologist"),
                    ("Pediatrics",  "Pediatrician"),
                    ("Orthopedics", "Orthopedic Surgeon"),
                ]
                from faker import Faker
                fake = Faker()
                Faker.seed(42)
                doctors = []
                for i in range(80):
                    dept_name, spec = specializations[i % len(specializations)]
                    doctors.append({
                        "first_name":       fake.first_name(),
                        "last_name":        fake.last_name(),
                        "specialization":   spec,
                        "department_id":    dept_ids[dept_name],
                        "years_experience": (i % 30) + 1,
                        "email":            f"doctor{i+1}@hospital.org",
                    })
                conn.execute(text("""
                    INSERT INTO production.doctors
                        (first_name, last_name, specialization,
                         department_id, years_experience, email)
                    VALUES
                        (:first_name, :last_name, :specialization,
                         :department_id, :years_experience, :email)
                    ON CONFLICT (email) DO NOTHING
                """), doctors)
                log.info("  Seeded doctors table (80 doctors)")

            conn.commit()

            # load patients
            log.info("  Loading patients ...")
            df_p = cleaned["patients"].copy()
            keep_cols = [
                "first_name","last_name","date_of_birth","gender",
                "blood_type","phone","email","address","city",
                "state","zip_code","insurance_provider","insurance_id"
            ]
            df_p = df_p[[c for c in keep_cols if c in df_p.columns]]
            df_p = df_p.where(pd.notnull(df_p), None)

            loaded_p = 0
            for _, row in df_p.iterrows():
                conn.execute(text("""
                    INSERT INTO production.patients
                        (first_name, last_name, date_of_birth, gender,
                         blood_type, phone, email, address, city,
                         state, zip_code, insurance_provider, insurance_id)
                    VALUES
                        (:first_name, :last_name, :date_of_birth, :gender,
                         :blood_type, :phone, :email, :address, :city,
                         :state, :zip_code, :insurance_provider, :insurance_id)
                    ON CONFLICT DO NOTHING
                """), row.to_dict())
                loaded_p += 1

            conn.commit()
            total_loaded += loaded_p
            log.info(f"    Loaded {loaded_p:,} patients")

            # load admissions
            log.info("  Loading admissions ...")
            df_a = cleaned["admissions"].copy()
            dept_ids = {
                row[0]: row[1] for row in conn.execute(
                    text("SELECT department_name, department_id FROM production.departments")
                )
            }
            doctor_ids = [
                row[0] for row in conn.execute(
                    text("SELECT doctor_id FROM production.doctors")
                )
            ]
            patient_ids = [
                row[0] for row in conn.execute(
                    text("SELECT patient_id FROM production.patients")
                )
            ]

            import random
            random.seed(42)
            loaded_a = 0
            for _, row in df_a.iterrows():
                dept_name = str(row.get("department","")).strip()
                dept_id   = dept_ids.get(dept_name, random.choice(list(dept_ids.values())))
                conn.execute(text("""
                    INSERT INTO production.admissions
                        (patient_id, doctor_id, department_id,
                         admission_date, discharge_date,
                         admission_type, discharge_disposition,
                         primary_diagnosis_code,
                         readmission_flag, days_to_readmission)
                    VALUES
                        (:patient_id, :doctor_id, :department_id,
                         :admission_date, :discharge_date,
                         :admission_type, :discharge_disposition,
                         :primary_diagnosis_code,
                         :readmission_flag, :days_to_readmission)
                    ON CONFLICT DO NOTHING
                """), {
                    "patient_id":             random.choice(patient_ids),
                    "doctor_id":              random.choice(doctor_ids),
                    "department_id":          dept_id,
                    "admission_date":         row.get("admission_date"),
                    "discharge_date":         row.get("discharge_date") or None,
                    "admission_type":         row.get("admission_type","Elective"),
                    "discharge_disposition":  row.get("discharge_disposition") or None,
                    "primary_diagnosis_code": row.get("primary_diagnosis_code","UNKNOWN"),
                    "readmission_flag":       bool(row.get("readmission_flag", False)),
                    "days_to_readmission":    None if pd.isna(row.get("days_to_readmission")) else int(row.get("days_to_readmission")),
                })
                loaded_a += 1

            conn.commit()
            total_loaded += loaded_a
            log.info(f"    Loaded {loaded_a:,} admissions")

            # load lab results in batches of 500
            log.info("  Loading lab results ...")
            df_l = cleaned["lab_results"].copy()
            admission_ids = [
                row[0] for row in conn.execute(
                    text("SELECT admission_id FROM production.admissions")
                )
            ]

            loaded_l = 0
            batch    = []
            for _, row in df_l.iterrows():
                batch.append({
                    "admission_id":  random.choice(admission_ids),
                    "test_name":     row.get("test_name","Unknown"),
                    "test_date":     row.get("test_date"),
                    "result_value":  row.get("result_value")  if pd.notna(row.get("result_value"))  else None,
                    "result_unit":   row.get("result_unit")   if pd.notna(row.get("result_unit"))   else None,
                    "reference_min": row.get("reference_min") if pd.notna(row.get("reference_min")) else None,
                    "reference_max": row.get("reference_max") if pd.notna(row.get("reference_max")) else None,
                    "is_abnormal":   bool(row.get("is_abnormal", False)),
                })
                if len(batch) >= 500:
                    conn.execute(text("""
                        INSERT INTO production.lab_results
                            (admission_id, test_name, test_date,
                             result_value, result_unit,
                             reference_min, reference_max, is_abnormal)
                        VALUES
                            (:admission_id, :test_name, :test_date,
                             :result_value, :result_unit,
                             :reference_min, :reference_max, :is_abnormal)
                    """), batch)
                    loaded_l += len(batch)
                    batch = []

            if batch:
                conn.execute(text("""
                    INSERT INTO production.lab_results
                        (admission_id, test_name, test_date,
                         result_value, result_unit,
                         reference_min, reference_max, is_abnormal)
                    VALUES
                        (:admission_id, :test_name, :test_date,
                         :result_value, :result_unit,
                         :reference_min, :reference_max, :is_abnormal)
                """), batch)
                loaded_l += len(batch)

            conn.commit()
            total_loaded += loaded_l
            log.info(f"    Loaded {loaded_l:,} lab results")

        except Exception as e:
            conn.rollback()
            log.error(f"  LOAD failed — transaction rolled back: {e}")
            raise

    duration = (datetime.now() - start).total_seconds()
    log.info(f"  Load complete in {duration:.2f}s  |  Total rows loaded: {total_loaded:,}")
    return total_loaded, duration

# ============================================================
# MAIN PIPELINE RUNNER
# ============================================================
def run_pipeline():
    pipeline_start = datetime.now()
    log.info("")
    log.info("*" * 60)
    log.info("  PATIENT READMISSION RISK ANALYZER — ETL PIPELINE")
    log.info(f"  Run started: {pipeline_start.strftime('%Y-%m-%d %H:%M:%S')}")
    log.info("*" * 60)

    engine         = get_engine()
    overall_status = "SUCCESS"
    error_msg      = None

    try:
        raw, extract_dur          = extract(engine)
        rows_extracted            = sum(len(v) for v in raw.values())
        cleaned, stats, trans_dur = transform(raw)
        rows_transformed          = sum(s["transformed"] for s in stats.values())
        rows_rejected             = sum(s["rejected"]    for s in stats.values())
        rows_loaded, load_dur     = load(engine, cleaned, stats)

    except Exception as e:
        overall_status   = "FAILED"
        error_msg        = str(e)
        rows_extracted   = rows_transformed = rows_loaded = rows_rejected = 0
        log.error(f"Pipeline failed: {e}")

    total_duration = (datetime.now() - pipeline_start).total_seconds()

    write_pipeline_log(
        engine,
        stage            = "FULL",
        source_file      = "patients_raw.csv, admissions_raw.csv, lab_results_raw.json",
        rows_extracted   = rows_extracted   if overall_status != "FAILED" else 0,
        rows_transformed = rows_transformed if overall_status != "FAILED" else 0,
        rows_loaded      = rows_loaded      if overall_status != "FAILED" else 0,
        rows_rejected    = rows_rejected    if overall_status != "FAILED" else 0,
        status           = overall_status,
        error_message    = error_msg,
        duration         = total_duration,
    )

    log.info("")
    log.info("*" * 60)
    log.info("  PIPELINE SUMMARY")
    log.info("*" * 60)
    if overall_status != "FAILED":
        log.info(f"  Rows extracted  : {rows_extracted:>8,}")
        log.info(f"  Rows transformed: {rows_transformed:>8,}")
        log.info(f"  Rows loaded     : {rows_loaded:>8,}")
        log.info(f"  Rows rejected   : {rows_rejected:>8,}")
        rej_rate = round((rows_rejected / rows_extracted * 100), 2) if rows_extracted else 0
        log.info(f"  Rejection rate  : {rej_rate:>7.2f}%")
    log.info(f"  Duration        : {total_duration:>7.2f}s")
    log.info(f"  Status          : {overall_status}")
    log.info(f"  Log file        : {log_file}")
    log.info("*" * 60)

if __name__ == "__main__":
    run_pipeline()
