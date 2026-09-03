-- E2E coverage for https://github.com/crossplane-contrib/provider-sql/pull/436
-- (allow schema-qualified type names in Grant.spec.forProvider.routines[].args).
--
-- Mirrors the shape that motivated the PR: AWS RDS's aws_s3 extension exposes
-- table_import_from_s3 overloads whose signatures include composite types
-- living in the aws_commons schema. Before #436 the CRD pattern rejected the
-- dot in "aws_commons._s3_uri_1", so such a Grant could not be expressed.
--
-- Everything is created from scratch; the guards make the script safe to run
-- twice (the harness runs the cluster and namespaced passes back to back).

DROP DATABASE IF EXISTS pr436_db;
DROP ROLE IF EXISTS pr436_role;

CREATE ROLE pr436_role LOGIN PASSWORD 'pr436';
CREATE DATABASE pr436_db OWNER postgres;

\c pr436_db

-- Composite types in a schema that is NOT on the provider's search_path, so
-- pg_catalog.format_type() renders them schema-qualified on the Observe side.
-- The leading underscore matches the real extension and is deliberately
-- adversarial: "_name" is also PostgreSQL's array-type naming convention.
CREATE SCHEMA aws_commons;
CREATE TYPE aws_commons._s3_uri_1 AS (bucket text, file_path text, region text);
CREATE TYPE aws_commons._aws_credentials_1 AS (access_key text, secret_key text, session_token text);

CREATE SCHEMA aws_s3;

-- The overload under test: 3 text args + 2 schema-qualified composite args.
CREATE FUNCTION aws_s3.table_import_from_s3(
    text, text, text, aws_commons._s3_uri_1, aws_commons._aws_credentials_1
) RETURNS text LANGUAGE sql AS 'SELECT ''composite''';

-- A sibling overload with the same name and a signature that shares a prefix.
-- Granting on one must not grant on, observe, or revoke the other.
CREATE FUNCTION aws_s3.table_import_from_s3(
    text, text, text, text, text, text, text, text, text
) RETURNS text LANGUAGE sql AS 'SELECT ''nine-text''';

-- Mixed case in the CR against a lower-case type: the reconciler lower-cases
-- args before splicing them into SQL and before comparing with format_type().
CREATE TYPE aws_commons.mixed_case_probe AS (key text);
CREATE FUNCTION aws_s3.mixed_case(aws_commons.mixed_case_probe) RETURNS int LANGUAGE sql AS 'SELECT 1';

-- Known limitation probes (informational unless PR436_STRICT=true).
--
-- format_type() omits the schema for types that ARE visible on search_path
-- (public.*) and for built-ins (pg_catalog.*), and double-quotes any type
-- name outside [a-z0-9_] (a "$" for instance). A user who writes such a
-- spelling gets a GRANT that succeeds and an Observe that never matches, so
-- the resource can never become Ready. The "$" case predates #436: the old
-- pattern admitted "$" too.
CREATE TYPE public.pr436_pair AS (a int, b int);
CREATE FUNCTION public.pr436_public_type(public.pr436_pair) RETURNS int LANGUAGE sql AS 'SELECT 1';
CREATE FUNCTION public.pr436_pgcatalog_type(text) RETURNS int LANGUAGE sql AS 'SELECT 1';
CREATE TYPE aws_commons.cred$v2 AS (key text);
CREATE FUNCTION aws_s3.dollar_type(aws_commons.cred$v2) RETURNS int LANGUAGE sql AS 'SELECT 1';

-- Functions are EXECUTE-able by PUBLIC by default, which would make
-- has_function_privilege() true for every role and blind the ground-truth
-- checks in 99-check.sh. Strip that so only the provider's own GRANT counts.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA aws_s3, public FROM PUBLIC;

GRANT USAGE ON SCHEMA aws_s3, aws_commons TO pr436_role;
