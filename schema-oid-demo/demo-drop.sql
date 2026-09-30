\set ON_ERROR_STOP on
-- Run as superuser in a test database. All database changes are rolled back.
BEGIN;
CREATE ROLE schema_demo_attacker;
SELECT format('GRANT CREATE ON DATABASE %I TO schema_demo_attacker', current_database()) \gexec

CREATE EXTENSION empty_schema_demo;
SELECT oid AS original_oid FROM pg_namespace
WHERE nspname = 'demo_ext_schema' \gset

\echo Original schema: name check and extension membership check both pass
SELECT n.oid, n.nspname,
       n.nspname = 'demo_ext_schema' AS name_check,
       EXISTS (
           SELECT 1 FROM pg_depend d JOIN pg_extension e ON e.oid = d.refobjid
           WHERE d.classid = 'pg_namespace'::regclass AND d.objid = n.oid
             AND d.objsubid = 0 AND d.refclassid = 'pg_extension'::regclass
             AND d.deptype = 'e' AND e.extname = 'empty_schema_demo'
       ) AS extension_member
FROM pg_namespace n WHERE n.nspname = 'demo_ext_schema';

-- A legitimate administrator removes the extension, freeing the name.
-- The attacker does NOT need permission to drop the original extension.
DROP EXTENSION empty_schema_demo;
SET ROLE schema_demo_attacker;
CREATE SCHEMA demo_ext_schema;
CREATE TABLE demo_ext_schema.user_data (payload text);
INSERT INTO demo_ext_schema.user_data VALUES ('This table belongs to an ordinary user');
RESET ROLE;

\echo Fake schema: name check passes, original OID and membership checks fail
SELECT n.oid, n.nspname, pg_get_userbyid(n.nspowner) AS owner,
       n.nspname = 'demo_ext_schema' AS name_check,
       n.oid = :original_oid::oid AS original_oid_check,
       EXISTS (
           SELECT 1 FROM pg_depend d JOIN pg_extension e ON e.oid = d.refobjid
           WHERE d.classid = 'pg_namespace'::regclass AND d.objid = n.oid
             AND d.objsubid = 0 AND d.refclassid = 'pg_extension'::regclass
             AND d.deptype = 'e' AND e.extname = 'empty_schema_demo'
       ) AS extension_member
FROM pg_namespace n WHERE n.nspname = 'demo_ext_schema';

-- Model privileged application/maintenance code that trusts the schema name.
-- These commands run as the original superuser after RESET ROLE.
\echo Name-only guard incorrectly accepts the user-owned schema
SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'demo_ext_schema') AS name_guard \gset
\if :name_guard
\echo SELECT reads the user-owned table
SELECT * FROM demo_ext_schema.user_data;
\echo DROP removes the user-owned table
DROP TABLE demo_ext_schema.user_data;
SELECT to_regclass('demo_ext_schema.user_data') IS NULL AS user_table_was_dropped;
\endif
ROLLBACK;
