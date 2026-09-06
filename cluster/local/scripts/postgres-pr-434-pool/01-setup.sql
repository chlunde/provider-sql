-- PR #434 connection pool probes. Runs on both passes as superuser on the
-- root DB, so start by removing leftovers. Pooled provider sessions may still
-- sit inside the database from the previous pass; terminate them first or
-- DROP DATABASE fails with 55006.
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE datname = 'pr434-db' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "pr434-db";
DROP ROLE IF EXISTS pr434_role;
DROP ROLE IF EXISTS pr434_grantee;
-- pr434_role owns the schema; pr434_grantee receives the USAGE grant. The
-- owner holds USAGE+CREATE implicitly, so a Grant of USAGE to the owner can
-- never observe as equal (same class as issue #240).
CREATE ROLE pr434_role LOGIN;
CREATE ROLE pr434_grantee LOGIN;
