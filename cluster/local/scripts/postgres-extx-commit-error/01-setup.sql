-- Make COMMIT fail after a successful GRANT.
-- GRANT -> ddl_command_end event trigger -> INSERT audit row
--       -> deferred constraint trigger fires at COMMIT -> RAISE
DROP DATABASE IF EXISTS extx_db;
DROP ROLE IF EXISTS extx_role;
CREATE ROLE extx_role;
CREATE DATABASE extx_db;
\c extx_db
CREATE SCHEMA extx_schema;
CREATE TABLE ddl_audit(id serial PRIMARY KEY, tag text NOT NULL);

CREATE FUNCTION audit_ddl() RETURNS event_trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ddl_audit(tag) VALUES (tg_tag);
END $$;
CREATE EVENT TRIGGER audit_ddl ON ddl_command_end
  WHEN TAG IN ('GRANT') EXECUTE FUNCTION audit_ddl();

CREATE FUNCTION reject_at_commit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'extx: COMMIT rejected (deferred trigger after %)', NEW.tag;
END $$;
CREATE CONSTRAINT TRIGGER reject_at_commit AFTER INSERT ON ddl_audit
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_at_commit();
