-- Reproducer for the routine-grant Observe bug reported on v0.16.0-beta.0
-- (https://github.com/crossplane-contrib/provider-sql/issues/240#issuecomment-4629228895)
--
-- selectRoutineGrantQuery cross-joins unnest(p.proargtypes) (one row per
-- ARGUMENT) with aclexplode(p.proacl) (one row per PRIVILEGE), then compares
--
--   array_agg(acl.privilege_type) = ARRAY['EXECUTE']
--
-- The cartesian product means array_agg yields one EXECUTE per argument. For a
-- 9-argument function that is {EXECUTE x9}, which never equals {EXECUTE}.
-- Observe therefore returns ResourceExists=false forever while the GRANT has in
-- fact been applied.
--
-- Verified against PostgreSQL 18.4: 0 and 1 argument pass; 2+ arguments fail.
-- The 1-arg control below is what every existing unit test uses, which is why
-- the bug survived to merge.

CREATE ROLE "routine-grant-role" LOGIN PASSWORD 'test';
CREATE DATABASE "routine-grant-db" OWNER postgres;

\c "routine-grant-db"

CREATE SCHEMA aws_s3;

-- The reported shape: 9 text arguments.
CREATE FUNCTION aws_s3.table_import_from_s3(
    text, text, text, text, text, text, text, text, text
) RETURNS int LANGUAGE sql AS 'SELECT 1';

-- Control: identical in every way except it takes a single argument.
-- This one is observed correctly today.
CREATE FUNCTION aws_s3.one_arg(text) RETURNS int LANGUAGE sql AS 'SELECT 1';

GRANT USAGE ON SCHEMA aws_s3 TO "routine-grant-role";
