-- Runs as root on both the namespaced and the cluster pass.
DROP DATABASE IF EXISTS colgrant;
DROP USER IF EXISTS 'colgrant'@'%';
CREATE DATABASE colgrant;
-- Ordinal order is deliberately not alphabetical: MariaDB lists columns in
-- SHOW GRANTS in hash order, which is neither.
CREATE TABLE colgrant.t (c INT, b INT, a INT);
CREATE TABLE colgrant.t2 (c INT, b INT, a INT);
CREATE USER 'colgrant'@'%' IDENTIFIED BY 'colgrant';
-- The gate counts GRANT/REVOKE statements the provider issues.
SET GLOBAL log_output = 'TABLE';
SET GLOBAL general_log = 1;
TRUNCATE TABLE mysql.general_log;
