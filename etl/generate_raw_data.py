import pandas as pd
import numpy as np
import json
import random
import os
from faker import Faker
from datetime import datetime, timedelta, date

fake = Faker()
random.seed(42)
np.random.seed(42)

# ============================================================
# CONFIG
# ============================================================
NUM_PATIENTS       = 5000
NUM_ADMISSIONS     = 10000
NUM_LAB_RESULTS    = 25000
OUTPUT_DIR         = "data/raw"
os.makedirs(OUTPUT_DIR, exist_ok=True)

# ============================================================
# REFERENCE DATA
# ============================================================
VALID_ICD10 = [
    ("I21.0",  "Acute anterior ST elevation MI"),
    ("I50.9",  "Heart failure, unspecified"),
    ("J18.9",  "Pneumonia, unspecified"),
    ("N18.3",  "Chronic kidney disease, stage 3"),
    ("E11.9",  "Type 2 diabetes without complications"),
    ("I10",    "Essential hypertension"),
    ("J44.1",  "COPD with acute exacerbation"),
    ("K92.1",  "Melena"),
    ("A41.9",  "Sepsis, unspecified"),
    ("I63.9",  "Cerebral infarction, unspecified"),
    ("F32.1",  "Major depressive disorder, single episode"),
    ("M54.5",  "Low back pain"),
    ("K35.80", "Acute appendicitis without abscess"),
    ("S72.001","Fracture of femoral neck"),
    ("C34.10", "Malignant neoplasm of upper lobe bronchus"),
]
INVALID_ICD10 = ["ZZZ999", "INVALID", "XX-00", "1234567", "N/A", "", "UNKNOWN"]

DEPARTMENTS = [
    "ICU", "Emergency", "General", "Surgical",
    "Cardiology", "Neurology", "Oncology", "Pediatrics", "Orthopedics"
]

ADMISSION_TYPES        = ["Emergency", "Elective", "Urgent", "Newborn"]
DISCHARGE_DISPOSITIONS = ["Home", "Transfer", "AMA", "Expired", "Rehab", "SNF"]
BLOOD_TYPES            = ["A+","A-","B+","B-","AB+","AB-","O+","O-"]
INSURANCE_PROVIDERS    = [
    "BlueCross BlueShield", "Aetna", "UnitedHealth",
    "Cigna", "Humana", "Medicare", "Medicaid", "Self-Pay"
]

LAB_TESTS = [
    ("Hemoglobin",        "g/dL",  11.0,  17.5,  7.0,   20.0),
    ("White Blood Count", "K/uL",  4.5,   11.0,  1.0,   30.0),
    ("Platelets",         "K/uL",  150.0, 400.0, 50.0,  800.0),
    ("Sodium",            "mEq/L", 136.0, 145.0, 120.0, 160.0),
    ("Potassium",         "mEq/L", 3.5,   5.0,   2.5,   7.0),
    ("Creatinine",        "mg/dL", 0.6,   1.2,   0.3,   10.0),
    ("Glucose",           "mg/dL", 70.0,  100.0, 40.0,  500.0),
    ("ALT",               "U/L",   7.0,   56.0,  3.0,   300.0),
    ("Troponin",          "ng/mL", 0.0,   0.04,  0.0,   5.0),
    ("BNP",               "pg/mL", 0.0,   100.0, 0.0,   2000.0),
]

# ============================================================
# DATE FORMAT HELPERS  (intentionally inconsistent)
# ============================================================
DATE_FORMATS = [
    "%Y-%m-%d",    # 2023-04-15   (ISO — clean)
    "%m/%d/%Y",    # 04/15/2023
    "%d-%m-%Y",    # 15-04-2023
    "%d/%m/%Y",    # 15/04/2023
    "%Y/%m/%d",    # 2023/04/15
    "%b %d, %Y",   # Apr 15, 2023
    "%d %B %Y",    # 15 April 2023
]

def messy_date(d):
    """Return a date as a randomly formatted string, or occasionally null/garbage."""
    r = random.random()
    if r < 0.04:   return ""             # 4%  missing
    if r < 0.06:   return "N/A"          # 2%  literal N/A
    if r < 0.065:  return "00/00/0000"   # 0.5% garbage
    fmt = random.choice(DATE_FORMATS)
    return d.strftime(fmt)

def random_date(start, end):
    delta = (end - start).days
    return start + timedelta(days=random.randint(0, max(delta, 0)))

# ============================================================
# 1. GENERATE PATIENTS  →  patients_raw.csv
# ============================================================
print("Generating patients_raw.csv ...")

patients  = []
used_ids  = set()

for i in range(NUM_PATIENTS):
    pid = f"P{random.randint(10000, 99999)}"
    while pid in used_ids:
        pid = f"P{random.randint(10000, 99999)}"
    used_ids.add(pid)

    dob = random_date(date(1930, 1, 1), date(2005, 12, 31))

    row = {
        "patient_id":          pid,
        "first_name":          fake.first_name(),
        "last_name":           fake.last_name(),
        "date_of_birth":       messy_date(dob),
        "gender":              random.choice(
                                   ["M","F","O","Male","Female","m","f","","Unknown"]
                               ),
        "blood_type":          random.choice(BLOOD_TYPES + [None, "", "Unknown"]),
        "phone":               fake.phone_number() if random.random() > 0.08 else None,
        "email":               fake.email()        if random.random() > 0.12 else None,
        "address":             fake.street_address(),
        "city":                fake.city(),
        "state":               fake.state_abbr(),
        "zip_code":            fake.zipcode(),
        "insurance_provider":  random.choice(INSURANCE_PROVIDERS + [None]),
        "insurance_id":        f"INS{random.randint(100000,999999)}"
                               if random.random() > 0.1 else None,
    }

    # inject ~3% full duplicates
    patients.append(row)
    if random.random() < 0.03:
        dup = row.copy()
        dup["first_name"] = dup["first_name"].upper()   # slight variation
        patients.append(dup)

df_patients = pd.DataFrame(patients)

# randomly uppercase some column names (simulates different source systems)
df_patients.columns = [
    c.upper() if random.random() < 0.15 else c
    for c in df_patients.columns
]

df_patients.to_csv(f"{OUTPUT_DIR}/patients_raw.csv", index=False)
print(f"  -> {len(df_patients):,} rows written")

# ============================================================
# 2. GENERATE ADMISSIONS  →  admissions_raw.csv
# ============================================================
print("Generating admissions_raw.csv ...")

patient_ids  = list(used_ids)
doctor_ids   = [f"D{random.randint(100, 999)}" for _ in range(80)]

admissions    = []
used_adm_ids  = set()

# track last admission per patient for readmission logic
last_admission = {}

for i in range(NUM_ADMISSIONS):
    adm_id = f"A{random.randint(100000, 999999)}"
    while adm_id in used_adm_ids:
        adm_id = f"A{random.randint(100000, 999999)}"
    used_adm_ids.add(adm_id)

    pid           = random.choice(patient_ids)
    adm_date      = random_date(date(2021, 1, 1), date(2024, 6, 30))
    has_discharge = random.random() > 0.05          # 5% still admitted
    los           = random.randint(1, 30)
    disc_date     = adm_date + timedelta(days=los) if has_discharge else None

    # readmission logic — 18% chance if patient seen within 30 days before
    readmitted      = False
    days_to_readmit = None
    if pid in last_admission:
        gap = (adm_date - last_admission[pid]).days
        if 0 < gap <= 30 and random.random() < 0.18:
            readmitted      = True
            days_to_readmit = gap

    last_admission[pid] = adm_date

    # ICD-10: 8% invalid codes
    if random.random() < 0.08:
        icd = random.choice(INVALID_ICD10)
    else:
        icd = random.choice(VALID_ICD10)[0]

    row = {
        "admission_id":           adm_id,
        "patient_id":             pid,
        "doctor_id":              random.choice(doctor_ids),
        "department":             random.choice(DEPARTMENTS + [None, "UNKNOWN"]),
        "admission_date":         messy_date(adm_date),
        "discharge_date":         messy_date(disc_date) if disc_date else "",
        "admission_type":         random.choice(
                                      ADMISSION_TYPES + [None, "Walk-in", "Referral"]
                                  ),
        "discharge_disposition":  random.choice(DISCHARGE_DISPOSITIONS + [None, ""]),
        "primary_diagnosis_code": icd,
        "readmission_flag":       (
                                      random.choice(["True","1","YES","true"])
                                      if readmitted
                                      else random.choice(["True","False","1","0","YES","NO","true","false"])
                                  ),
        "days_to_readmission":    days_to_readmit if readmitted else "",
    }
    admissions.append(row)

    # 2% duplicate admissions
    if random.random() < 0.02:
        admissions.append(row.copy())

df_admissions = pd.DataFrame(admissions)
df_admissions.to_csv(f"{OUTPUT_DIR}/admissions_raw.csv", index=False)
print(f"  -> {len(df_admissions):,} rows written")

# ============================================================
# 3. GENERATE LAB RESULTS  →  lab_results_raw.json
# ============================================================
print("Generating lab_results_raw.json ...")

adm_ids     = list(used_adm_ids)
lab_records = []

for i in range(NUM_LAB_RESULTS):
    test                              = random.choice(LAB_TESTS)
    name, unit, ref_min, ref_max, val_min, val_max = test

    test_date = random_date(date(2021, 1, 1), date(2024, 6, 30))
    true_val  = round(random.uniform(val_min, val_max), 3)

    # inject result value issues (~10%)
    r = random.random()
    if   r < 0.03: result_value = "N/A"
    elif r < 0.05: result_value = ">999"       # out-of-range string
    elif r < 0.07: result_value = "PENDING"
    elif r < 0.08: result_value = ""
    else:          result_value = str(true_val)

    # inject reference range issues (~8%)
    r2 = random.random()
    if   r2 < 0.03: ref_range = "N/A"
    elif r2 < 0.05: ref_range = "see report"
    elif r2 < 0.08: ref_range = ""
    else:           ref_range = f"{ref_min} - {ref_max}"

    record = {
        "admission_id":    random.choice(adm_ids),
        "test_name":       name,
        "test_date":       messy_date(test_date),
        "result_value":    result_value,
        "result_unit":     unit if random.random() > 0.05 else None,
        "reference_range": ref_range,
    }
    lab_records.append(record)

with open(f"{OUTPUT_DIR}/lab_results_raw.json", "w") as f:
    json.dump(lab_records, f, indent=2)

print(f"  -> {len(lab_records):,} records written")

# ============================================================
# 4. SUMMARY REPORT
# ============================================================
print("\n" + "="*55)
print("  RAW DATA GENERATION COMPLETE")
print("="*55)
print(f"  patients_raw.csv       {len(df_patients):>7,} rows")
print(f"  admissions_raw.csv     {len(df_admissions):>7,} rows")
print(f"  lab_results_raw.json   {len(lab_records):>7,} records")
print()
print("  Data quality issues injected:")
print(f"  - Mixed date formats   : {len(DATE_FORMATS)} different formats")
print(f"  - Patient duplicates   : ~3% of rows")
print(f"  - Invalid ICD-10 codes : ~8% of admissions")
print(f"  - Missing discharge    : ~5% of admissions")
print(f"  - Null/empty values    : scattered across all files")
print(f"  - Inconsistent booleans: True/False/1/0/YES/NO")
print(f"  - Unparseable lab vals : ~10% of results")
print("="*55)
print("  Files saved to: data/raw/")
print("="*55)
