-- Tests for the pg_aux_catalog extension: creation of the fixed-OID
-- mdb_admin role and the privileges its membership confers.

CREATE EXTENSION pg_aux_catalog;

-- ---------------------------------------------------------------------
-- pg_create_mdb_admin_role() creates the mdb_admin role with its fixed OID.
-- ---------------------------------------------------------------------
SELECT pg_create_mdb_admin_role() AS mdb_admin_oid;

-- The role exists with the fixed OID and is a non-login, non-superuser,
-- connection-limited role.
SELECT oid = 8067 AS has_fixed_oid, rolcanlogin, rolsuper,
       rolcreaterole, rolcreatedb, rolconnlimit
  FROM pg_authid WHERE rolname = 'mdb_admin';

-- Creating it a second time is rejected.
SELECT pg_create_mdb_admin_role();

-- ---------------------------------------------------------------------
-- Resource-group permission gate: a role that is not a member of mdb_admin
-- is rejected on every entry point.  These checks run before the "resource
-- group is enabled" check, so they are deterministic regardless of the
-- resource manager in use.  Full dispatched / multi-session coverage lives
-- in src/test/isolation2 (resgroup/resgroup_mdb_admin).
-- ---------------------------------------------------------------------
CREATE ROLE regress_rg_noadmin;
SET ROLE regress_rg_noadmin;
CREATE RESOURCE GROUP regress_rg_x WITH (concurrency=1, cpu_max_percent=5);
ALTER RESOURCE GROUP regress_rg_x SET cpu_max_percent 6;
DROP RESOURCE GROUP regress_rg_x;
RESET ROLE;
DROP ROLE regress_rg_noadmin;

-- ---------------------------------------------------------------------
-- mdb_admin members may transfer object ownership between ordinary roles,
-- but not to superusers or to dangerous system roles.
-- ---------------------------------------------------------------------
CREATE ROLE regress_mdb_admin_user1;
CREATE ROLE regress_mdb_admin_user2;
CREATE ROLE regress_mdb_admin_user3;
CREATE ROLE regress_superuser WITH SUPERUSER;

GRANT mdb_admin TO regress_mdb_admin_user1;
SELECT current_database() AS datname \gset
GRANT CREATE ON DATABASE :"datname" TO regress_mdb_admin_user2;
GRANT CREATE ON DATABASE :"datname" TO regress_mdb_admin_user3;

SET ROLE regress_mdb_admin_user2;
CREATE FUNCTION regress_mdb_admin_add(integer, integer) RETURNS integer
    AS 'SELECT $1 + $2;'
    LANGUAGE SQL
    IMMUTABLE
    RETURNS NULL ON NULL INPUT;
CREATE SCHEMA regress_mdb_admin_schema;
GRANT CREATE ON SCHEMA regress_mdb_admin_schema TO regress_mdb_admin_user3;
CREATE TABLE regress_mdb_admin_schema.regress_mdb_admin_table();
CREATE TABLE regress_mdb_admin_table();
CREATE VIEW regress_mdb_admin_view as SELECT 1;
SET ROLE regress_mdb_admin_user1;

-- mdb_admin transfers ownership to another ordinary role: allowed
ALTER FUNCTION regress_mdb_admin_add (integer, integer) OWNER TO regress_mdb_admin_user3;
ALTER VIEW regress_mdb_admin_view OWNER TO regress_mdb_admin_user3;
ALTER TABLE regress_mdb_admin_schema.regress_mdb_admin_table OWNER TO regress_mdb_admin_user3;
ALTER TABLE regress_mdb_admin_table OWNER TO regress_mdb_admin_user3;
ALTER SCHEMA regress_mdb_admin_schema OWNER TO regress_mdb_admin_user3;

-- mdb_admin fails to transfer ownership to superusers and particular system roles
ALTER FUNCTION regress_mdb_admin_add (integer, integer) OWNER TO regress_superuser;
ALTER VIEW regress_mdb_admin_view OWNER TO regress_superuser;
ALTER TABLE regress_mdb_admin_schema.regress_mdb_admin_table OWNER TO regress_superuser;
ALTER TABLE regress_mdb_admin_table OWNER TO regress_superuser;
ALTER SCHEMA regress_mdb_admin_schema OWNER TO regress_superuser;

ALTER FUNCTION regress_mdb_admin_add (integer, integer) OWNER TO pg_execute_server_program;
ALTER VIEW regress_mdb_admin_view OWNER TO pg_execute_server_program;
ALTER TABLE regress_mdb_admin_schema.regress_mdb_admin_table OWNER TO pg_execute_server_program;
ALTER TABLE regress_mdb_admin_table OWNER TO pg_execute_server_program;
ALTER SCHEMA regress_mdb_admin_schema OWNER TO pg_execute_server_program;

ALTER FUNCTION regress_mdb_admin_add (integer, integer) OWNER TO pg_write_server_files;
ALTER VIEW regress_mdb_admin_view OWNER TO pg_write_server_files;
ALTER TABLE regress_mdb_admin_schema.regress_mdb_admin_table OWNER TO pg_write_server_files;
ALTER TABLE regress_mdb_admin_table OWNER TO pg_write_server_files;
ALTER SCHEMA regress_mdb_admin_schema OWNER TO pg_write_server_files;

ALTER FUNCTION regress_mdb_admin_add (integer, integer) OWNER TO pg_read_server_files;
ALTER VIEW regress_mdb_admin_view OWNER TO pg_read_server_files;
ALTER TABLE regress_mdb_admin_schema.regress_mdb_admin_table OWNER TO pg_read_server_files;
ALTER TABLE regress_mdb_admin_table OWNER TO pg_read_server_files;
ALTER SCHEMA regress_mdb_admin_schema OWNER TO pg_read_server_files;

ALTER FUNCTION regress_mdb_admin_add (integer, integer) OWNER TO pg_write_all_data;
ALTER VIEW regress_mdb_admin_view OWNER TO pg_write_all_data;
ALTER TABLE regress_mdb_admin_schema.regress_mdb_admin_table OWNER TO pg_write_all_data;
ALTER TABLE regress_mdb_admin_table OWNER TO pg_write_all_data;
ALTER SCHEMA regress_mdb_admin_schema OWNER TO pg_write_all_data;

ALTER FUNCTION regress_mdb_admin_add (integer, integer) OWNER TO pg_read_all_data;
ALTER VIEW regress_mdb_admin_view OWNER TO pg_read_all_data;
ALTER TABLE regress_mdb_admin_schema.regress_mdb_admin_table OWNER TO pg_read_all_data;
ALTER TABLE regress_mdb_admin_table OWNER TO pg_read_all_data;
ALTER SCHEMA regress_mdb_admin_schema OWNER TO pg_read_all_data;

-- ---------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------
RESET SESSION AUTHORIZATION;
REVOKE CREATE ON DATABASE :"datname" FROM regress_mdb_admin_user2;
REVOKE CREATE ON DATABASE :"datname" FROM regress_mdb_admin_user3;

DROP VIEW regress_mdb_admin_view;
DROP FUNCTION regress_mdb_admin_add;
DROP TABLE regress_mdb_admin_schema.regress_mdb_admin_table;
DROP TABLE regress_mdb_admin_table;
DROP SCHEMA regress_mdb_admin_schema;
DROP ROLE regress_mdb_admin_user1;
DROP ROLE regress_mdb_admin_user2;
DROP ROLE regress_mdb_admin_user3;
DROP ROLE regress_superuser;
DROP ROLE mdb_admin;
DROP EXTENSION pg_aux_catalog;
