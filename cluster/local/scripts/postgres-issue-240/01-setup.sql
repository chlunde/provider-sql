-- Reproducer for https://github.com/crossplane-contrib/provider-sql/issues/240
--
-- Pre-create a role and a database owned by that role. The role then implicitly
-- holds CONNECT/CREATE/TEMPORARY on the database (DB owner). The Grant resource
-- applied in 02-grant.yaml only asks for CONNECT — the Observe query expects
-- the actual privilege array to be EQUAL to the requested one, so EXISTS
-- returns false and the resource is stuck in "Creating".

CREATE ROLE "my-service_user"
    PASSWORD 'mKMTrwhl79'
    INHERIT NOCREATEDB NOCREATEROLE LOGIN;
GRANT "my-service_user" TO "postgres";
ALTER ROLE "my-service_user" CONNECTION LIMIT -1;

CREATE DATABASE "my-service"
    OWNER "my-service_user"
    ALLOW_CONNECTIONS true
    CONNECTION LIMIT -1;
