--
-- The cluster-wide views and functions of ext_vacuum_statistics.
--
-- This test runs against a Cloudberry cluster that has ext_vacuum_statistics
-- in shared_preload_libraries of every instance ("make installcheck-cluster").
--
CREATE EXTENSION IF NOT EXISTS ext_vacuum_statistics;
SELECT ext_vacuum_statistics.gp_vacuum_statistics_reset();

SELECT oid AS dboid FROM pg_database WHERE datname = current_database() \gset

CREATE TABLE gpvs_dist (id int, v text) WITH (autovacuum_enabled = off)
  DISTRIBUTED BY (id);
CREATE INDEX gpvs_dist_idx ON gpvs_dist (id);
INSERT INTO gpvs_dist SELECT g, 'x' FROM generate_series(1, 10000) g;
CREATE TABLE gpvs_repl (id int) WITH (autovacuum_enabled = off)
  DISTRIBUTED REPLICATED;
INSERT INTO gpvs_repl SELECT generate_series(1, 300);
DELETE FROM gpvs_dist;
DELETE FROM gpvs_repl;
VACUUM gpvs_dist, gpvs_repl;

-- One row per instance: every segment and the coordinator vacuum the table.
SELECT count(*) = (SELECT count(*) FROM gp_segment_configuration
                    WHERE role = 'p') AS one_row_per_instance
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables
 WHERE relname = 'gpvs_dist';

-- The rows were deleted on the segments; the coordinator holds none.
SELECT gp_segment_id = -1 AS coordinator, sum(tuples_deleted) AS tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables
 WHERE relname = 'gpvs_dist'
 GROUP BY 1 ORDER BY 1;

-- The summary adds the segments up; a replicated table is stored on every
-- segment, so its sums are divided by their number.
SELECT relname, tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables_summary
 WHERE relname LIKE 'gpvs%'
 ORDER BY relname;

SELECT indexrelname, tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_indexes_summary
 WHERE indexrelname = 'gpvs_dist_idx';

SELECT s.wal_records = (SELECT sum(wal_records)
                          FROM ext_vacuum_statistics.gp_stats_vacuum_tables
                         WHERE relname = 'gpvs_dist' AND gp_segment_id >= 0)
         AS summary_matches_segments
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables_summary s
 WHERE s.relname = 'gpvs_dist';

SELECT db_wal_records > 0 AS database_has_wal,
       db_wal_records >= (SELECT sum(wal_records)
                            FROM ext_vacuum_statistics.gp_stats_vacuum_tables
                           WHERE relname LIKE 'gpvs%') AS database_covers_tables
  FROM ext_vacuum_statistics.gp_stats_vacuum_database_summary
 WHERE dbname = current_database();

-- The same numbers in the core summary views.
SELECT relname, total_vacuum_time > 0 AS vacuum_timed
  FROM gp_stat_all_tables_summary
 WHERE relname LIKE 'gpvs%'
 ORDER BY relname;

-- vacuum_statistics.enabled set on the coordinator reaches the segments.
INSERT INTO gpvs_dist SELECT g, 'y' FROM generate_series(1, 1000) g;
DELETE FROM gpvs_dist;
SET vacuum_statistics.enabled = off;
VACUUM gpvs_dist;
RESET vacuum_statistics.enabled;
SELECT sum(tuples_deleted) AS tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables
 WHERE relname = 'gpvs_dist';

-- Resetting one relation resets it on every instance.
SELECT ext_vacuum_statistics.gp_extvac_reset_entry(:dboid, 'gpvs_dist'::regclass);
SELECT coalesce(sum(tuples_deleted), 0) AS tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables
 WHERE relname = 'gpvs_dist';
SELECT relname, tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables_summary
 WHERE relname LIKE 'gpvs%'
 ORDER BY relname;

-- The entries of a dropped table go away on every instance, when the drop
-- commits (on the segments through COMMIT PREPARED), and a rolled back drop
-- keeps them.  The entry is looked up by OID, since the views need the
-- relation in pg_class.
SELECT 'gpvs_repl'::regclass::oid AS repl_oid \gset
CREATE VIEW gpvs_repl_entry AS
  SELECT s.relid
    FROM gp_id,
         LATERAL ext_vacuum_statistics.pg_stats_get_vacuum_tables(:dboid, :repl_oid) s;
SELECT count(*) AS segment_entries FROM gp_dist_random('gpvs_repl_entry');
SELECT count(*) AS coordinator_entries FROM gpvs_repl_entry;
BEGIN;
DROP TABLE gpvs_repl;
ROLLBACK;
SELECT count(*) AS segment_entries FROM gp_dist_random('gpvs_repl_entry');
DROP TABLE gpvs_repl;
SELECT count(*) AS segment_entries FROM gp_dist_random('gpvs_repl_entry');
SELECT count(*) AS coordinator_entries FROM gpvs_repl_entry;

-- The database-level times of the core reach the shared statistics when a
-- segment flushes its pending statistics, which an idle backend does within
-- a second (PGSTAT_MIN_INTERVAL); wait for that before reading them.
SELECT pg_sleep(2);
SELECT total_vacuum_time > 0 AS database_vacuum_timed
  FROM gp_stat_database_summary
 WHERE datname = current_database();

-- Resetting everything on the whole cluster.
SELECT ext_vacuum_statistics.gp_vacuum_statistics_reset();
SELECT count(*) AS entries
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables
 WHERE relname LIKE 'gpvs%';

DROP VIEW gpvs_repl_entry;
DROP TABLE gpvs_dist;
