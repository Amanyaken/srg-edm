-- SRG Task B4: core ETL transformations (MySQL 8.0+)
-- STATUS: DESIGNED against the columns the brief describes. NOT run on the real
-- SRG files (not yet received) and not run on any database. Expect to adjust
-- column names after you see the real CSV headers. Run and fix before submitting.
-- Phone convention here follows the course notes: 256XXXXXXXXX (no plus sign).
-- If you keep this, also change "+256..." / "E.164" wording in the Word document.

CREATE DATABASE IF NOT EXISTS srg_dw CHARACTER SET utf8mb4;
USE srg_dw;

-- ---------------------------------------------------------------
-- 0. Helper: proper-case names (MySQL has no INITCAP)
-- ---------------------------------------------------------------
DROP FUNCTION IF EXISTS initcap;
DELIMITER //
CREATE FUNCTION initcap(s VARCHAR(200)) RETURNS VARCHAR(200) DETERMINISTIC
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE out_s VARCHAR(200) DEFAULT '';
  DECLARE ch CHAR(1);
  DECLARE prev CHAR(1) DEFAULT ' ';
  SET s = LOWER(TRIM(s));
  WHILE i <= CHAR_LENGTH(s) DO
    SET ch = SUBSTRING(s, i, 1);
    IF prev = ' ' THEN SET out_s = CONCAT(out_s, UPPER(ch));
    ELSE SET out_s = CONCAT(out_s, ch);
    END IF;
    SET prev = ch;
    SET i = i + 1;
  END WHILE;
  RETURN out_s;
END //
DELIMITER ;

-- ---------------------------------------------------------------
-- 1. Staging tables (assumed columns; adjust to the real CSV headers)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_customers_raw (
  src_system VARCHAR(20), src_id VARCHAR(30),
  name_raw VARCHAR(150), phone_raw VARCHAR(40), gender_raw VARCHAR(20),
  dob_raw VARCHAR(25), district_raw VARCHAR(60), email_raw VARCHAR(120),
  updated_at DATE,
  load_ts DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS stg_products_raw (
  product_code VARCHAR(30), product_name VARCHAR(150),
  category_raw VARCHAR(60), unit_raw VARCHAR(20)
);
CREATE TABLE IF NOT EXISTS stg_sales_raw (   -- the 3 formats unioned into one shape
  src_format VARCHAR(12), sale_id VARCHAR(40), sale_date_raw VARCHAR(25),
  store_code VARCHAR(15), customer_phone_raw VARCHAR(40),
  product_code VARCHAR(30), qty INT, amount_raw VARCHAR(30)
);
CREATE TABLE IF NOT EXISTS ref_district (district_name VARCHAR(60) PRIMARY KEY);
CREATE TABLE IF NOT EXISTS etl_reject_log (
  log_id INT AUTO_INCREMENT PRIMARY KEY, entity VARCHAR(20),
  src_system VARCHAR(20), src_id VARCHAR(30), reason VARCHAR(60),
  logged_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------
-- 2. TRANSFORM customers: phone, name, gender, date of birth, district
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS stg_customers_clean;
CREATE TABLE stg_customers_clean AS
SELECT
  r.src_system, r.src_id,
  initcap(r.name_raw) AS full_name,
  CASE
    WHEN d.digits REGEXP '^256[0-9]{9}$' THEN d.digits                      -- already 256...
    WHEN d.digits REGEXP '^0[0-9]{9}$'   THEN CONCAT('256', SUBSTRING(d.digits, 2))  -- 07xx...
    WHEN d.digits REGEXP '^[0-9]{9}$'    THEN CONCAT('256', d.digits)       -- 7xx...
    ELSE NULL                                                               -- reviewed, not guessed
  END AS phone_norm,
  CASE UPPER(TRIM(r.gender_raw))
    WHEN 'M' THEN 'M' WHEN 'MALE' THEN 'M'
    WHEN 'F' THEN 'F' WHEN 'FEMALE' THEN 'F'
    ELSE 'U' END AS gender,
  COALESCE(STR_TO_DATE(r.dob_raw, '%Y-%m-%d'),
           STR_TO_DATE(r.dob_raw, '%d/%m/%Y'),    -- assumption: day first
           STR_TO_DATE(r.dob_raw, '%d-%m-%Y')) AS dob,
  initcap(r.district_raw) AS district,
  LOWER(TRIM(r.email_raw)) AS email,
  r.updated_at
FROM stg_customers_raw r
JOIN (SELECT src_system, src_id, REGEXP_REPLACE(phone_raw, '[^0-9]', '') AS digits
      FROM stg_customers_raw) d
  ON d.src_system = r.src_system AND d.src_id = r.src_id;

-- Rejects go to a log and a steward queue; they are never silently dropped
INSERT INTO etl_reject_log (entity, src_system, src_id, reason)
SELECT 'CUSTOMER', c.src_system, c.src_id, 'PHONE_INVALID'
FROM stg_customers_clean c WHERE c.phone_norm IS NULL;
INSERT INTO etl_reject_log (entity, src_system, src_id, reason)
SELECT 'CUSTOMER', c.src_system, c.src_id, 'DISTRICT_NOT_IN_MASTER'
FROM stg_customers_clean c
LEFT JOIN ref_district rd ON rd.district_name = c.district
WHERE c.district IS NOT NULL AND rd.district_name IS NULL;

-- ---------------------------------------------------------------
-- 3. DIMENSIONS (always before the fact table)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_customer (
  customer_key INT AUTO_INCREMENT PRIMARY KEY,
  phone VARCHAR(12) UNIQUE, full_name VARCHAR(150), gender CHAR(1),
  dob DATE, district VARCHAR(60), email VARCHAR(120)
);
INSERT IGNORE INTO dim_customer (customer_key, phone, full_name, gender)
VALUES (-1, NULL, 'Unknown', 'U');   -- default row so unmatched keys stay visible

-- Simplified deterministic step: one row per phone, latest update wins.
-- The probabilistic score and steward review from B3 are NOT implemented here.
INSERT INTO dim_customer (phone, full_name, gender, dob, district, email)
SELECT phone_norm, full_name, gender, dob, district, email
FROM (SELECT c.*,
             ROW_NUMBER() OVER (PARTITION BY phone_norm ORDER BY updated_at DESC) AS rn
      FROM stg_customers_clean c WHERE phone_norm IS NOT NULL) x
WHERE rn = 1
ON DUPLICATE KEY UPDATE full_name = VALUES(full_name), district = VALUES(district),
                        email = VALUES(email);

-- dim_product: Slowly Changing Dimension Type 2 (history kept as new rows)
CREATE TABLE IF NOT EXISTS dim_product (
  product_key INT AUTO_INCREMENT PRIMARY KEY,
  product_code VARCHAR(30), product_name VARCHAR(150), category VARCHAR(60),
  unit VARCHAR(10), valid_from DATE, valid_to DATE, is_current TINYINT(1),
  KEY idx_prod (product_code, is_current)
);
INSERT IGNORE INTO dim_product (product_key, product_code, product_name, valid_from, valid_to, is_current)
VALUES (-1, 'UNKNOWN', 'Unknown', '1900-01-01', '9999-12-31', 1);

DROP TABLE IF EXISTS stg_products_clean;
CREATE TABLE stg_products_clean AS
SELECT UPPER(TRIM(product_code)) AS product_code,
       initcap(product_name) AS product_name,
       initcap(category_raw) AS category,
       CASE UPPER(TRIM(unit_raw))
         WHEN 'KG' THEN 'kg' WHEN 'KGS' THEN 'kg' WHEN 'KILOGRAMS' THEN 'kg'
         ELSE LOWER(TRIM(unit_raw)) END AS unit
FROM stg_products_raw;

-- Step A: close the current row when something changed
UPDATE dim_product d
JOIN stg_products_clean s ON s.product_code = d.product_code AND d.is_current = 1
SET d.valid_to = CURDATE() - INTERVAL 1 DAY, d.is_current = 0
WHERE d.product_name <> s.product_name OR d.category <> s.category OR d.unit <> s.unit;
-- Step B: insert a new current row for new or changed products
INSERT INTO dim_product (product_code, product_name, category, unit, valid_from, valid_to, is_current)
SELECT s.product_code, s.product_name, s.category, s.unit, CURDATE(), '9999-12-31', 1
FROM stg_products_clean s
LEFT JOIN dim_product d ON d.product_code = s.product_code AND d.is_current = 1
WHERE d.product_key IS NULL;
-- dim_store follows the same two-step SCD2 pattern (store_code, name, district).

CREATE TABLE IF NOT EXISTS dim_date (
  date_key INT PRIMARY KEY, full_date DATE, month TINYINT, quarter TINYINT, year SMALLINT
);
INSERT IGNORE INTO dim_date
WITH RECURSIVE d AS (
  SELECT DATE('2026-01-01') AS dt
  UNION ALL SELECT dt + INTERVAL 1 DAY FROM d WHERE dt < '2027-12-31')
SELECT CAST(DATE_FORMAT(dt, '%Y%m%d') AS UNSIGNED), dt, MONTH(dt), QUARTER(dt), YEAR(dt) FROM d;

-- ---------------------------------------------------------------
-- 4. FACT load (idempotent: re-running the same batch adds nothing)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_sales (
  sale_sk BIGINT AUTO_INCREMENT PRIMARY KEY,
  src_format VARCHAR(12), sale_id VARCHAR(40),
  date_key INT, customer_key INT, product_key INT,
  quantity INT, amount_ugx DECIMAL(12,2), is_return TINYINT(1),
  UNIQUE KEY uq_sale (src_format, sale_id)
);

INSERT IGNORE INTO fact_sales
  (src_format, sale_id, date_key, customer_key, product_key, quantity, amount_ugx, is_return)
SELECT s.src_format, s.sale_id,
       CAST(DATE_FORMAT(sd.sale_date, '%Y%m%d') AS UNSIGNED),
       COALESCE(c.customer_key, -1),            -- unmatched -> Unknown row, never dropped
       COALESCE(p.product_key, -1),
       s.qty,
       CAST(REGEXP_REPLACE(s.amount_raw, '[^0-9.-]', '') AS DECIMAL(12,2)),
       (s.qty < 0)                              -- returns kept and flagged
FROM stg_sales_raw s
JOIN (SELECT src_format, sale_id,
             COALESCE(STR_TO_DATE(sale_date_raw, '%Y-%m-%d'),
                      STR_TO_DATE(sale_date_raw, '%d/%m/%Y')) AS sale_date
      FROM stg_sales_raw) sd ON sd.src_format = s.src_format AND sd.sale_id = s.sale_id
LEFT JOIN dim_customer c
  ON c.phone = CASE
       WHEN REGEXP_REPLACE(s.customer_phone_raw, '[^0-9]', '') REGEXP '^256[0-9]{9}$'
         THEN REGEXP_REPLACE(s.customer_phone_raw, '[^0-9]', '')
       WHEN REGEXP_REPLACE(s.customer_phone_raw, '[^0-9]', '') REGEXP '^0[0-9]{9}$'
         THEN CONCAT('256', SUBSTRING(REGEXP_REPLACE(s.customer_phone_raw, '[^0-9]', ''), 2))
       ELSE NULL END
LEFT JOIN dim_product p
  ON p.product_code = UPPER(TRIM(s.product_code))
 AND sd.sale_date BETWEEN p.valid_from AND p.valid_to;   -- point-in-time version

-- Quality metric: how many facts landed on the Unknown rows (should trend to 0)
SELECT SUM(customer_key = -1) AS unknown_customers,
       SUM(product_key  = -1) AS unknown_products,
       COUNT(*)               AS total_rows
FROM fact_sales;
