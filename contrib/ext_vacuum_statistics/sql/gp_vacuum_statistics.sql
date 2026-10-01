--
-- Cluster-wide vacuum statistics: aggregation and collection control.
-- The final two cases cover core summary views and synchronization of
-- track_cost_delay_timing.
--
-- This test runs against a Cloudberry cluster that has ext_vacuum_statistics
-- in shared_preload_libraries of every instance ("make installcheck-cluster").
--
CREATE EXTENSION IF NOT EXISTS ext_vacuum_statistics;
SELECT oid AS dboid FROM pg_database WHERE datname = current_database() \gset

-- Prepare dead tuples: 10000 in a distributed table and 300 copies on
-- each segment in a replicated table.  VACUUM also cleans the index.
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

-- Collection: expect an entry on every primary segment and the coordinator.
-- role = 'p' includes the coordinator and excludes mirrors.
SELECT count(*) = (SELECT count(*) FROM gp_segment_configuration
                    WHERE role = 'p') AS one_row_per_instance
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables
 WHERE relname = 'gpvs_dist';

-- Expect 10000 removed tuples across the segments and 0 on the coordinator.
SELECT gp_segment_id = -1 AS coordinator, sum(tuples_deleted) AS tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables
 WHERE relname = 'gpvs_dist'
 GROUP BY 1 ORDER BY 1;

-- Aggregation: expect 10000 for the distributed table and 300 for the
-- replicated table.  Replicated counts must be averaged across segments.
SELECT relname, tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables_summary
 WHERE relname LIKE 'gpvs%'
 ORDER BY relname;

-- The index summary must also report 10000 removed tuples.
SELECT indexrelname, tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_indexes_summary
 WHERE indexrelname = 'gpvs_dist_idx';

-- WAL volume varies, so compare the summary with the segment counters.
SELECT s.wal_records = (SELECT sum(wal_records)
                          FROM ext_vacuum_statistics.gp_stats_vacuum_tables
                         WHERE relname = 'gpvs_dist' AND gp_segment_id >= 0)
         AS summary_matches_segments
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables_summary s
 WHERE s.relname = 'gpvs_dist';

-- Database WAL includes these tables plus indexes and other relations;
-- it must be positive and at least as large as the table WAL total.
SELECT db_wal_records > 0 AS database_has_wal,
       db_wal_records >= (SELECT sum(wal_records)
                            FROM ext_vacuum_statistics.gp_stats_vacuum_tables
                           WHERE relname LIKE 'gpvs%') AS database_covers_tables
  FROM ext_vacuum_statistics.gp_stats_vacuum_database_summary
 WHERE dbname = current_database();

-- Core table summaries must also record a positive vacuum duration.
SELECT relname, total_vacuum_time > 0 AS vacuum_timed
  FROM gp_stat_all_tables_summary
 WHERE relname LIKE 'gpvs%'
 ORDER BY relname;

-- Collection control: disable collection on the coordinator, then vacuum
-- another 1000 dead tuples.  The segment counters must stay at 10000.
INSERT INTO gpvs_dist SELECT g, 'y' FROM generate_series(1, 1000) g;
DELETE FROM gpvs_dist;
SET vacuum_statistics.enabled = off;
VACUUM gpvs_dist;
RESET vacuum_statistics.enabled;
SELECT sum(tuples_deleted) AS tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables
 WHERE relname = 'gpvs_dist';

-- Core database timing is published asynchronously.  Allow pending stats
-- to be flushed before checking that the vacuum duration is positive.
SELECT pg_sleep(2);
SELECT total_vacuum_time > 0 AS database_vacuum_timed
  FROM gp_stat_vacuum_summary
 WHERE datname = current_database();

DROP TABLE gpvs_repl;
DROP TABLE gpvs_dist;

-- Core GUC regression: reconnect with timing enabled at session startup.
-- New segment processes must inherit it; SET inside a transaction must
-- disable it there, and ROLLBACK must restore it.  All three checks expect t.
\connect -reuse-previous=on "options='-c track_cost_delay_timing=on'"
SELECT bool_and(setting = 'on') AS delay_timing_synced
  FROM gp_dist_random('pg_settings') WHERE name = 'track_cost_delay_timing';
BEGIN;
SET track_cost_delay_timing = off;
SELECT bool_and(setting = 'off') AS delay_timing_disabled
  FROM gp_dist_random('pg_settings') WHERE name = 'track_cost_delay_timing';
ROLLBACK;
SELECT bool_and(setting = 'on') AS delay_timing_restored
  FROM gp_dist_random('pg_settings') WHERE name = 'track_cost_delay_timing';
RESET track_cost_delay_timing;

-- Core index-summary regression: two indexes on the same table must give
-- exactly two summary rows.  Joining by table OID alone used to multiply
-- rows and mix index timings; compare each index with its own segment sum.
CREATE TABLE core_summary_test (a int, b int) DISTRIBUTED BY (a);
CREATE INDEX core_summary_a ON core_summary_test(a);
CREATE INDEX core_summary_b ON core_summary_test(b);
INSERT INTO core_summary_test SELECT g, g FROM generate_series(1, 10000) g;
DELETE FROM core_summary_test WHERE a % 2 = 0;
VACUUM core_summary_test;
SELECT count(*) AS summary_indexes,
       count(DISTINCT indexrelid) AS distinct_indexes
  FROM gp_stat_all_indexes_summary WHERE relname = 'core_summary_test';
SELECT bool_and(s.total_vacuum_time = d.total_vacuum_time) AS index_totals_match
  FROM gp_stat_all_indexes_summary s
  JOIN (SELECT indexrelid, sum(total_vacuum_time) AS total_vacuum_time
          FROM gp_dist_random('pg_stat_all_indexes')
         WHERE relname = 'core_summary_test' GROUP BY indexrelid) d
    USING (indexrelid)
 WHERE s.relname = 'core_summary_test';
DROP TABLE core_summary_test;
