/*-------------------------------------------------------------------------
 *
 * ext_vacuum_statistics--1.0.sql
 *    Extended vacuum statistics via hook and custom storage
 *
 * This extension collects extended vacuum statistics via set_report_vacuum_hook
 * and stores them in shared memory.
 *
 *-------------------------------------------------------------------------
 */

\echo Use "CREATE EXTENSION ext_vacuum_statistics" to load this file. \quit

CREATE SCHEMA IF NOT EXISTS ext_vacuum_statistics;

COMMENT ON SCHEMA ext_vacuum_statistics IS
  'Extended vacuum statistics (heap, index, database)';

-- Reset functions
CREATE OR REPLACE FUNCTION ext_vacuum_statistics.extvac_reset_entry(
    dboid oid,
    relid oid
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'extvac_reset_entry'
LANGUAGE C STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION ext_vacuum_statistics.extvac_reset_db_entry(dboid oid)
RETURNS bigint
AS 'MODULE_PATHNAME', 'extvac_reset_db_entry'
LANGUAGE C STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION ext_vacuum_statistics.vacuum_statistics_reset()
RETURNS bigint
AS 'MODULE_PATHNAME', 'vacuum_statistics_reset'
LANGUAGE C STRICT PARALLEL SAFE;

-- Internal C function to fetch table vacuum stats
CREATE OR REPLACE FUNCTION ext_vacuum_statistics.pg_stats_get_vacuum_tables(
    IN  dboid oid,
    IN  reloid oid,
    OUT relid oid,
    OUT total_blks_read bigint,
    OUT total_blks_hit bigint,
    OUT total_blks_dirtied bigint,
    OUT total_blks_written bigint,
    OUT wal_records bigint,
    OUT wal_fpi bigint,
    OUT wal_bytes numeric,
    OUT blk_read_time double precision,
    OUT blk_write_time double precision,
    OUT rel_blks_read bigint,
    OUT rel_blks_hit bigint,
    OUT tuples_deleted bigint,
    OUT pages_scanned bigint,
    OUT pages_removed bigint,
    OUT tuples_frozen bigint,
    OUT recently_dead_tuples bigint,
    OUT missed_dead_pages bigint,
    OUT missed_dead_tuples bigint
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stats_get_vacuum_tables'
LANGUAGE C STRICT STABLE;

-- Internal C function to fetch index vacuum stats
CREATE OR REPLACE FUNCTION ext_vacuum_statistics.pg_stats_get_vacuum_indexes(
    IN  dboid oid,
    IN  reloid oid,
    OUT relid oid,
    OUT total_blks_read bigint,
    OUT total_blks_hit bigint,
    OUT total_blks_dirtied bigint,
    OUT total_blks_written bigint,
    OUT wal_records bigint,
    OUT wal_fpi bigint,
    OUT wal_bytes numeric,
    OUT blk_read_time double precision,
    OUT blk_write_time double precision,
    OUT rel_blks_read bigint,
    OUT rel_blks_hit bigint,
    OUT tuples_deleted bigint,
    OUT pages_deleted bigint
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stats_get_vacuum_indexes'
LANGUAGE C STRICT STABLE;

-- Internal C function to fetch database vacuum stats
CREATE OR REPLACE FUNCTION ext_vacuum_statistics.pg_stats_get_vacuum_database(
    IN  dboid oid,
    OUT dbid oid,
    OUT total_blks_read bigint,
    OUT total_blks_hit bigint,
    OUT total_blks_dirtied bigint,
    OUT total_blks_written bigint,
    OUT wal_records bigint,
    OUT wal_fpi bigint,
    OUT wal_bytes numeric,
    OUT blk_read_time double precision,
    OUT blk_write_time double precision
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stats_get_vacuum_database'
LANGUAGE C STRICT STABLE;

-- View: vacuum statistics per table (heap)
CREATE VIEW ext_vacuum_statistics.pg_stats_vacuum_tables AS
SELECT
  rel.oid AS relid,
  ns.nspname AS schema,
  rel.relname AS relname,
  db.datname AS dbname,
  stats.total_blks_read,
  stats.total_blks_hit,
  stats.total_blks_dirtied,
  stats.total_blks_written,
  stats.wal_records,
  stats.wal_fpi,
  stats.wal_bytes,
  stats.blk_read_time,
  stats.blk_write_time,
  stats.rel_blks_read,
  stats.rel_blks_hit,
  stats.tuples_deleted,
  stats.pages_scanned,
  stats.pages_removed,
  stats.tuples_frozen,
  stats.recently_dead_tuples,
  stats.missed_dead_pages,
  stats.missed_dead_tuples
FROM pg_database db,
     pg_class rel,
     pg_namespace ns,
     LATERAL ext_vacuum_statistics.pg_stats_get_vacuum_tables(db.oid, rel.oid) stats
WHERE db.datname = current_database()
  AND rel.relkind = 'r'
  AND rel.relnamespace = ns.oid
  AND rel.oid = stats.relid;

COMMENT ON VIEW ext_vacuum_statistics.pg_stats_vacuum_tables IS
  'Extended vacuum statistics per table (heap)';

-- View: vacuum statistics per index
CREATE VIEW ext_vacuum_statistics.pg_stats_vacuum_indexes AS
SELECT
  rel.oid AS indexrelid,
  ns.nspname AS schema,
  rel.relname AS indexrelname,
  db.datname AS dbname,
  stats.total_blks_read,
  stats.total_blks_hit,
  stats.total_blks_dirtied,
  stats.total_blks_written,
  stats.wal_records,
  stats.wal_fpi,
  stats.wal_bytes,
  stats.blk_read_time,
  stats.blk_write_time,
  stats.rel_blks_read,
  stats.rel_blks_hit,
  stats.tuples_deleted,
  stats.pages_deleted
FROM pg_database db,
     pg_class rel,
     pg_namespace ns,
     LATERAL ext_vacuum_statistics.pg_stats_get_vacuum_indexes(db.oid, rel.oid) stats
WHERE db.datname = current_database()
  AND rel.relkind = 'i'
  AND rel.relnamespace = ns.oid
  AND rel.oid = stats.relid;

COMMENT ON VIEW ext_vacuum_statistics.pg_stats_vacuum_indexes IS
  'Extended vacuum statistics per index';

-- View: vacuum statistics per database (aggregate)
CREATE VIEW ext_vacuum_statistics.pg_stats_vacuum_database AS
SELECT
  db.oid AS dboid,
  db.datname AS dbname,
  stats.total_blks_read AS db_blks_read,
  stats.total_blks_hit AS db_blks_hit,
  stats.total_blks_dirtied AS db_blks_dirtied,
  stats.total_blks_written AS db_blks_written,
  stats.wal_records AS db_wal_records,
  stats.wal_fpi AS db_wal_fpi,
  stats.wal_bytes AS db_wal_bytes,
  stats.blk_read_time AS db_blk_read_time,
  stats.blk_write_time AS db_blk_write_time
FROM pg_database db
LEFT JOIN LATERAL ext_vacuum_statistics.pg_stats_get_vacuum_database(db.oid) stats ON db.oid = stats.dbid;

COMMENT ON VIEW ext_vacuum_statistics.pg_stats_vacuum_database IS
  'Extended vacuum statistics per database (aggregate)';

--
-- Cloudberry: cluster-wide views.
--
-- Every instance of the cluster keeps the statistics of the vacuums it runs
-- itself, and the pg_stats_vacuum_* views above only show those of the
-- instance they are queried on.  The gp_stats_vacuum_* views show the rows
-- of all instances, with the gp_segment_id of each (-1 for the
-- coordinator), like the gp_stat_* views of the core.
--
CREATE VIEW ext_vacuum_statistics.gp_stats_vacuum_tables AS
SELECT gp_execution_segment() AS gp_segment_id, *
  FROM gp_dist_random('ext_vacuum_statistics.pg_stats_vacuum_tables')
UNION ALL
SELECT -1 AS gp_segment_id, *
  FROM ext_vacuum_statistics.pg_stats_vacuum_tables;

COMMENT ON VIEW ext_vacuum_statistics.gp_stats_vacuum_tables IS
  'Extended vacuum statistics per table, on every instance of the cluster';

CREATE VIEW ext_vacuum_statistics.gp_stats_vacuum_indexes AS
SELECT gp_execution_segment() AS gp_segment_id, *
  FROM gp_dist_random('ext_vacuum_statistics.pg_stats_vacuum_indexes')
UNION ALL
SELECT -1 AS gp_segment_id, *
  FROM ext_vacuum_statistics.pg_stats_vacuum_indexes;

COMMENT ON VIEW ext_vacuum_statistics.gp_stats_vacuum_indexes IS
  'Extended vacuum statistics per index, on every instance of the cluster';

CREATE VIEW ext_vacuum_statistics.gp_stats_vacuum_database AS
SELECT gp_execution_segment() AS gp_segment_id, *
  FROM gp_dist_random('ext_vacuum_statistics.pg_stats_vacuum_database')
UNION ALL
SELECT -1 AS gp_segment_id, *
  FROM ext_vacuum_statistics.pg_stats_vacuum_database;

COMMENT ON VIEW ext_vacuum_statistics.gp_stats_vacuum_database IS
  'Extended vacuum statistics per database, on every instance of the cluster';

--
-- The *_summary views add the numbers up over the cluster, the way the
-- gp_stat_*_summary views of the core do: user relations are summed over
-- the segments (a replicated table is stored and vacuumed in full on every
-- segment, so its sums are divided by the number of segments), and the
-- system catalogs, which every instance keeps its own copy of, are shown as
-- the coordinator counts them.
--
CREATE VIEW ext_vacuum_statistics.gp_stats_vacuum_tables_summary AS
SELECT
  s.relid,
  s.schema,
  s.relname,
  s.dbname,
  CASE WHEN d.policytype = 'r' THEN (sum(s.total_blks_read) / d.numsegments)::bigint ELSE sum(s.total_blks_read)::bigint END AS total_blks_read,
  CASE WHEN d.policytype = 'r' THEN (sum(s.total_blks_hit) / d.numsegments)::bigint ELSE sum(s.total_blks_hit)::bigint END AS total_blks_hit,
  CASE WHEN d.policytype = 'r' THEN (sum(s.total_blks_dirtied) / d.numsegments)::bigint ELSE sum(s.total_blks_dirtied)::bigint END AS total_blks_dirtied,
  CASE WHEN d.policytype = 'r' THEN (sum(s.total_blks_written) / d.numsegments)::bigint ELSE sum(s.total_blks_written)::bigint END AS total_blks_written,
  CASE WHEN d.policytype = 'r' THEN (sum(s.wal_records) / d.numsegments)::bigint ELSE sum(s.wal_records)::bigint END AS wal_records,
  CASE WHEN d.policytype = 'r' THEN (sum(s.wal_fpi) / d.numsegments)::bigint ELSE sum(s.wal_fpi)::bigint END AS wal_fpi,
  CASE WHEN d.policytype = 'r' THEN (sum(s.wal_bytes) / d.numsegments) ELSE sum(s.wal_bytes) END AS wal_bytes,
  CASE WHEN d.policytype = 'r' THEN (sum(s.blk_read_time) / d.numsegments) ELSE sum(s.blk_read_time) END AS blk_read_time,
  CASE WHEN d.policytype = 'r' THEN (sum(s.blk_write_time) / d.numsegments) ELSE sum(s.blk_write_time) END AS blk_write_time,
  CASE WHEN d.policytype = 'r' THEN (sum(s.rel_blks_read) / d.numsegments)::bigint ELSE sum(s.rel_blks_read)::bigint END AS rel_blks_read,
  CASE WHEN d.policytype = 'r' THEN (sum(s.rel_blks_hit) / d.numsegments)::bigint ELSE sum(s.rel_blks_hit)::bigint END AS rel_blks_hit,
  CASE WHEN d.policytype = 'r' THEN (sum(s.tuples_deleted) / d.numsegments)::bigint ELSE sum(s.tuples_deleted)::bigint END AS tuples_deleted,
  CASE WHEN d.policytype = 'r' THEN (sum(s.pages_scanned) / d.numsegments)::bigint ELSE sum(s.pages_scanned)::bigint END AS pages_scanned,
  CASE WHEN d.policytype = 'r' THEN (sum(s.pages_removed) / d.numsegments)::bigint ELSE sum(s.pages_removed)::bigint END AS pages_removed,
  CASE WHEN d.policytype = 'r' THEN (sum(s.tuples_frozen) / d.numsegments)::bigint ELSE sum(s.tuples_frozen)::bigint END AS tuples_frozen,
  CASE WHEN d.policytype = 'r' THEN (sum(s.recently_dead_tuples) / d.numsegments)::bigint ELSE sum(s.recently_dead_tuples)::bigint END AS recently_dead_tuples,
  CASE WHEN d.policytype = 'r' THEN (sum(s.missed_dead_pages) / d.numsegments)::bigint ELSE sum(s.missed_dead_pages)::bigint END AS missed_dead_pages,
  CASE WHEN d.policytype = 'r' THEN (sum(s.missed_dead_tuples) / d.numsegments)::bigint ELSE sum(s.missed_dead_tuples)::bigint END AS missed_dead_tuples
FROM gp_dist_random('ext_vacuum_statistics.pg_stats_vacuum_tables') s
LEFT JOIN gp_distribution_policy d ON d.localoid = s.relid
WHERE s.relid >= 16384
GROUP BY s.relid, s.schema, s.relname, s.dbname, d.policytype, d.numsegments
UNION ALL
SELECT
  relid,
  schema,
  relname,
  dbname,
  total_blks_read,
  total_blks_hit,
  total_blks_dirtied,
  total_blks_written,
  wal_records,
  wal_fpi,
  wal_bytes,
  blk_read_time,
  blk_write_time,
  rel_blks_read,
  rel_blks_hit,
  tuples_deleted,
  pages_scanned,
  pages_removed,
  tuples_frozen,
  recently_dead_tuples,
  missed_dead_pages,
  missed_dead_tuples
FROM ext_vacuum_statistics.pg_stats_vacuum_tables
WHERE relid < 16384;

COMMENT ON VIEW ext_vacuum_statistics.gp_stats_vacuum_tables_summary IS
  'Extended vacuum statistics per table, summed over the cluster';

CREATE VIEW ext_vacuum_statistics.gp_stats_vacuum_indexes_summary AS
SELECT
  s.indexrelid,
  s.schema,
  s.indexrelname,
  s.dbname,
  CASE WHEN d.policytype = 'r' THEN (sum(s.total_blks_read) / d.numsegments)::bigint ELSE sum(s.total_blks_read)::bigint END AS total_blks_read,
  CASE WHEN d.policytype = 'r' THEN (sum(s.total_blks_hit) / d.numsegments)::bigint ELSE sum(s.total_blks_hit)::bigint END AS total_blks_hit,
  CASE WHEN d.policytype = 'r' THEN (sum(s.total_blks_dirtied) / d.numsegments)::bigint ELSE sum(s.total_blks_dirtied)::bigint END AS total_blks_dirtied,
  CASE WHEN d.policytype = 'r' THEN (sum(s.total_blks_written) / d.numsegments)::bigint ELSE sum(s.total_blks_written)::bigint END AS total_blks_written,
  CASE WHEN d.policytype = 'r' THEN (sum(s.wal_records) / d.numsegments)::bigint ELSE sum(s.wal_records)::bigint END AS wal_records,
  CASE WHEN d.policytype = 'r' THEN (sum(s.wal_fpi) / d.numsegments)::bigint ELSE sum(s.wal_fpi)::bigint END AS wal_fpi,
  CASE WHEN d.policytype = 'r' THEN (sum(s.wal_bytes) / d.numsegments) ELSE sum(s.wal_bytes) END AS wal_bytes,
  CASE WHEN d.policytype = 'r' THEN (sum(s.blk_read_time) / d.numsegments) ELSE sum(s.blk_read_time) END AS blk_read_time,
  CASE WHEN d.policytype = 'r' THEN (sum(s.blk_write_time) / d.numsegments) ELSE sum(s.blk_write_time) END AS blk_write_time,
  CASE WHEN d.policytype = 'r' THEN (sum(s.rel_blks_read) / d.numsegments)::bigint ELSE sum(s.rel_blks_read)::bigint END AS rel_blks_read,
  CASE WHEN d.policytype = 'r' THEN (sum(s.rel_blks_hit) / d.numsegments)::bigint ELSE sum(s.rel_blks_hit)::bigint END AS rel_blks_hit,
  CASE WHEN d.policytype = 'r' THEN (sum(s.tuples_deleted) / d.numsegments)::bigint ELSE sum(s.tuples_deleted)::bigint END AS tuples_deleted,
  CASE WHEN d.policytype = 'r' THEN (sum(s.pages_deleted) / d.numsegments)::bigint ELSE sum(s.pages_deleted)::bigint END AS pages_deleted
FROM gp_dist_random('ext_vacuum_statistics.pg_stats_vacuum_indexes') s
JOIN pg_index i ON i.indexrelid = s.indexrelid
LEFT JOIN gp_distribution_policy d ON d.localoid = i.indrelid
WHERE s.indexrelid >= 16384
GROUP BY s.indexrelid, s.schema, s.indexrelname, s.dbname, d.policytype, d.numsegments
UNION ALL
SELECT
  indexrelid,
  schema,
  indexrelname,
  dbname,
  total_blks_read,
  total_blks_hit,
  total_blks_dirtied,
  total_blks_written,
  wal_records,
  wal_fpi,
  wal_bytes,
  blk_read_time,
  blk_write_time,
  rel_blks_read,
  rel_blks_hit,
  tuples_deleted,
  pages_deleted
FROM ext_vacuum_statistics.pg_stats_vacuum_indexes
WHERE indexrelid < 16384;

COMMENT ON VIEW ext_vacuum_statistics.gp_stats_vacuum_indexes_summary IS
  'Extended vacuum statistics per index, summed over the cluster';

-- The database aggregates are summed over all instances, the coordinator
-- included: they are the vacuum work done in the database cluster-wide.
CREATE VIEW ext_vacuum_statistics.gp_stats_vacuum_database_summary AS
SELECT
  dboid,
  dbname,
  sum(db_blks_read)::bigint AS db_blks_read,
  sum(db_blks_hit)::bigint AS db_blks_hit,
  sum(db_blks_dirtied)::bigint AS db_blks_dirtied,
  sum(db_blks_written)::bigint AS db_blks_written,
  sum(db_wal_records)::bigint AS db_wal_records,
  sum(db_wal_fpi)::bigint AS db_wal_fpi,
  sum(db_wal_bytes) AS db_wal_bytes,
  sum(db_blk_read_time) AS db_blk_read_time,
  sum(db_blk_write_time) AS db_blk_write_time
FROM ext_vacuum_statistics.gp_stats_vacuum_database
GROUP BY dboid, dbname;

COMMENT ON VIEW ext_vacuum_statistics.gp_stats_vacuum_database_summary IS
  'Extended vacuum statistics per database, summed over the cluster';

--
-- Cloudberry: resetting on the whole cluster.  The reset functions above act
-- on the instance they are called on; these run them on the coordinator and
-- on every segment.
--
CREATE FUNCTION ext_vacuum_statistics.gp_vacuum_statistics_reset()
RETURNS void
AS $$
  SELECT ext_vacuum_statistics.vacuum_statistics_reset() FROM gp_dist_random('gp_id');
  SELECT ext_vacuum_statistics.vacuum_statistics_reset();
$$ LANGUAGE sql VOLATILE;

CREATE FUNCTION ext_vacuum_statistics.gp_extvac_reset_entry(dboid oid, relid oid)
RETURNS void
AS $$
  SELECT ext_vacuum_statistics.extvac_reset_entry(dboid, relid) FROM gp_dist_random('gp_id');
  SELECT ext_vacuum_statistics.extvac_reset_entry(dboid, relid);
$$ LANGUAGE sql STRICT VOLATILE;

CREATE FUNCTION ext_vacuum_statistics.gp_extvac_reset_db_entry(dboid oid)
RETURNS void
AS $$
  SELECT ext_vacuum_statistics.extvac_reset_db_entry(dboid) FROM gp_dist_random('gp_id');
  SELECT ext_vacuum_statistics.extvac_reset_db_entry(dboid);
$$ LANGUAGE sql STRICT VOLATILE;
