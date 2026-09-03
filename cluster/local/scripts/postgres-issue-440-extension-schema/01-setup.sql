-- Issue #440: Extension.spec.forProvider.schema was never used.
-- Runs on both e2e passes, hence the DROPs. Needs a postgis-capable image
-- (POSTGRES_IMAGE=imresamu/postgis:18-3.6).
DROP DATABASE IF EXISTS issue440_db;
CREATE DATABASE issue440_db;
\c issue440_db
-- Target for the non-relocatable case (postgis).
CREATE SCHEMA gis;
-- Adversarial identifier for the relocatable case (hstore).
CREATE SCHEMA "Mixed Case";
