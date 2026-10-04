# SRG EDM Capstone: Technical Artifacts

Individual capstone, Project Savanna (Savanna Retail Group).

## Files
- etl_core_transformations.sql: core ETL transformations (MySQL 8). Phone, name, gender, date and district cleaning; SCD Type 2 product dimension; idempotent fact load.
- rbac_demo.sql: role-based access control (GRANT/REVOKE), masked customer view, and access tests.
- SRG_ER_and_StarSchema.drawio: logical ER model and star schema.
- SRG_Conceptual_ER.drawio: conceptual ER model.
- SRG_ETL_Workflow.drawio: ETL workflow diagram.

## Status
- Scripts were designed against the columns described in the brief. They have been tested only on invented sample rows, not on the real SRG files.
- B2 cleansing scripts are pending until the SRG data files are available.
