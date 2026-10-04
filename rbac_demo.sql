-- SRG RBAC demo (Task C2). Works on MySQL 8.0+ and MariaDB 10.4+. Demo data is invented.
-- Run PART 1 and PART 2 as root. Run PART 3 logged in as test_analyst.

-- PART 1: demo schema and fake rows
CREATE DATABASE IF NOT EXISTS srg_demo;
USE srg_demo;

CREATE TABLE IF NOT EXISTS customer (
  customer_id INT PRIMARY KEY AUTO_INCREMENT,
  full_name   VARCHAR(100),
  phone       VARCHAR(20),
  district    VARCHAR(50)
);
CREATE TABLE IF NOT EXISTS sales (
  sale_id     INT PRIMARY KEY AUTO_INCREMENT,
  customer_id INT,
  amount_ugx  DECIMAL(12,2)
);
CREATE TABLE IF NOT EXISTS hr_staff (
  staff_id INT PRIMARY KEY AUTO_INCREMENT,
  name     VARCHAR(100),
  salary   DECIMAL(12,2)
);

INSERT INTO customer (full_name, phone, district) VALUES
  ('Grace Demo', '+256772000001', 'Jinja'),
  ('John Demo',  '+256701000002', 'Gulu');
INSERT INTO sales (customer_id, amount_ugx) VALUES (1, 8000), (2, 15000);
INSERT INTO hr_staff (name, salary) VALUES ('Staff Demo', 1000000);

-- Masked view for analysts (name and phone partly hidden)
CREATE OR REPLACE VIEW customer_masked AS
SELECT customer_id,
       CONCAT(LEFT(full_name, 1), '***')  AS full_name,
       CONCAT(LEFT(phone, 8), 'xxxxx')    AS phone,
       district
FROM customer;

-- PART 2: roles, grants, test user
CREATE ROLE IF NOT EXISTS cashier, store_manager, hq_steward, analyst, hr_officer;

GRANT INSERT ON srg_demo.customer        TO cashier;
GRANT INSERT ON srg_demo.sales           TO cashier;
GRANT SELECT ON srg_demo.customer_masked TO cashier;

GRANT SELECT ON srg_demo.customer_masked TO store_manager;
GRANT SELECT ON srg_demo.sales           TO store_manager;

GRANT SELECT, UPDATE ON srg_demo.customer TO hq_steward;
GRANT SELECT         ON srg_demo.sales    TO hq_steward;

GRANT SELECT ON srg_demo.customer_masked TO analyst;
GRANT SELECT ON srg_demo.sales           TO analyst;

GRANT SELECT, UPDATE ON srg_demo.hr_staff TO hr_officer;

-- Example of REVOKE: remove a permission that was given by mistake
GRANT DELETE ON srg_demo.sales TO analyst;
REVOKE DELETE ON srg_demo.sales FROM analyst;

CREATE USER IF NOT EXISTS 'test_analyst'@'localhost' IDENTIFIED BY 'Test#12345';
GRANT analyst TO 'test_analyst'@'localhost';
-- MySQL 8 syntax (use this one if your course uses MySQL 8):
SET DEFAULT ROLE analyst TO 'test_analyst'@'localhost';
-- MariaDB syntax instead: SET DEFAULT ROLE analyst FOR 'test_analyst'@'localhost';

-- PART 3: tests, run while logged in as test_analyst
-- 3a. SHOULD WORK: masked customers
--   SELECT * FROM srg_demo.customer_masked;
-- 3b. SHOULD FAIL (ERROR 1142, SELECT command denied): real customer data
--   SELECT * FROM srg_demo.customer;
-- 3c. SHOULD FAIL: HR salaries
--   SELECT * FROM srg_demo.hr_staff;
-- 3d. SHOULD FAIL: deleting sales (revoked above)
--   DELETE FROM srg_demo.sales WHERE sale_id = 1;
-- Take screenshots of 3a to 3d. The failed ones are your "failed-access" evidence.

-- Limitation: MariaDB has no row-level security. "Own store only" access
-- needs per-store views or application logic. State this in the portfolio.
