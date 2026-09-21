--
-- The extended vacuum statistics of append-optimized tables (AO row and
-- AOCS) and of their indexes.
--
-- This test runs against a Cloudberry cluster that has ext_vacuum_statistics
-- in shared_preload_libraries of every instance ("make installcheck-cluster").
--
CREATE EXTENSION IF NOT EXISTS ext_vacuum_statistics;
SELECT ext_vacuum_statistics.gp_vacuum_statistics_reset();

CREATE TABLE gpvs_ao_row (id int, v text) WITH (appendonly = true)
  DISTRIBUTED BY (id);
CREATE TABLE gpvs_ao_col (id int, v text)
  WITH (appendonly = true, orientation = column) DISTRIBUTED BY (id);
CREATE INDEX gpvs_ao_row_idx ON gpvs_ao_row (id);
CREATE INDEX gpvs_ao_col_idx ON gpvs_ao_col (id);
INSERT INTO gpvs_ao_row SELECT g, repeat('x', 100) FROM generate_series(1, 3000) g;
INSERT INTO gpvs_ao_col SELECT g, repeat('x', 100) FROM generate_series(1, 3000) g;
DELETE FROM gpvs_ao_row WHERE id % 2 = 0;
DELETE FROM gpvs_ao_col WHERE id % 2 = 0;
VACUUM gpvs_ao_row, gpvs_ao_col;

-- The compaction discarded the deleted rows on the segments, and truncating
-- the compacted segment files released space; the per-tuple heap counters
-- have no append-optimized counterpart and stay zero.
SELECT relname, tuples_deleted, pages_removed > 0 AS pages_removed,
       wal_records > 0 AS has_wal, pages_scanned, tuples_frozen,
       recently_dead_tuples, missed_dead_tuples, missed_dead_pages
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables_summary
 WHERE relname LIKE 'gpvs_ao_%'
 ORDER BY relname;

-- One row per instance; the coordinator holds no rows.
SELECT relname, gp_segment_id = -1 AS coordinator,
       sum(tuples_deleted) AS tuples_deleted, count(*) AS instances
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables
 WHERE relname LIKE 'gpvs_ao_%'
 GROUP BY 1, 2 ORDER BY 1, 2;

-- The compaction moves the live rows to another segment file, so the index
-- pass removes the entries of all rows of the compacted file, the moved live
-- ones included: 3000, not 1500.
SELECT indexrelname, tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_indexes_summary
 WHERE indexrelname LIKE 'gpvs_ao_%'
 ORDER BY indexrelname;

-- The database aggregate covers the tables and the indexes.
SELECT db_wal_records >=
         (SELECT sum(wal_records) FROM ext_vacuum_statistics.gp_stats_vacuum_tables
           WHERE relname LIKE 'gpvs_ao_%') +
         (SELECT sum(wal_records) FROM ext_vacuum_statistics.gp_stats_vacuum_indexes
           WHERE indexrelname LIKE 'gpvs_ao_%') AS database_covers_relations
  FROM ext_vacuum_statistics.gp_stats_vacuum_database_summary
 WHERE dbname = current_database();

-- A second vacuum, with nothing left to compact, adds no deleted tuples.
VACUUM gpvs_ao_row;
SELECT relname, tuples_deleted
  FROM ext_vacuum_statistics.gp_stats_vacuum_tables_summary
 WHERE relname = 'gpvs_ao_row';

-- The entries go away with the tables, on every instance.
SELECT 'gpvs_ao_row'::regclass::oid AS row_oid \gset
SELECT oid AS dboid FROM pg_database WHERE datname = current_database() \gset
CREATE VIEW gpvs_ao_entry AS
  SELECT s.relid
    FROM gp_id,
         LATERAL ext_vacuum_statistics.pg_stats_get_vacuum_tables(:dboid, :row_oid) s;
SELECT count(*) AS segment_entries FROM gp_dist_random('gpvs_ao_entry');
DROP TABLE gpvs_ao_row, gpvs_ao_col;
SELECT count(*) AS segment_entries FROM gp_dist_random('gpvs_ao_entry');
DROP VIEW gpvs_ao_entry;
