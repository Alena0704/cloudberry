# ext_vacuum_statistics

Extended vacuum statistics extension for PostgreSQL. It collects and exposes detailed per-table, per-index, and per-database vacuum statistics (buffer I/O, WAL, general, timing) via convenient views in the `ext_vacuum_statistics` schema.

## Installation

```
./configure tmp_install="$(pwd)/my/inst"
make clean && make && make install
cd contrib/ext_vacuum_statistics
make && make install
```

It is essential that the extension is listed in `shared_preload_libraries` because it registers a vacuum hook at server startup.

In your `postgresql.conf`:

```
shared_preload_libraries = 'ext_vacuum_statistics'
```

Restart PostgreSQL.

In your database:

```sql
CREATE EXTENSION ext_vacuum_statistics;
```

## Usage

Query vacuum statistics via the provided views:

```sql
-- Per-table heap vacuum statistics
SELECT * FROM ext_vacuum_statistics.pg_stats_vacuum_tables;

-- Per-index vacuum statistics
SELECT * FROM ext_vacuum_statistics.pg_stats_vacuum_indexes;

-- Per-database aggregate vacuum statistics
SELECT * FROM ext_vacuum_statistics.pg_stats_vacuum_database;
```

Example output:

```
 relname   | total_blks_read | total_blks_hit | wal_records | tuples_deleted | pages_removed
-----------+-----------------+----------------+-------------+----------------+---------------
 mytable   |             120 |            340 |          15 |            500 |            10
```

Reset statistics when needed:

```sql
SELECT ext_vacuum_statistics.vacuum_statistics_reset();
```

## Configuration (GUCs)

| GUC | Default | Description |
|-----|---------|-------------|
| `vacuum_statistics.enabled` | on | Enable extended vacuum statistics collection |

## Memory usage

Each tracked object (table or index) uses a fixed-size shared memory entry; the exact size depends on the platform.

Example: a database with 1000 tables and 2000 indexes, all tracked, uses about **700 KB** on Ubuntu (3001 entries × 232 bytes). Per-database entries add one entry per tracked database.

The entry of a table or an index is dropped when the relation is dropped (at
commit, so a rolled back `DROP` keeps it), and a new relation that gets the OID
of an old one starts from zero.  The module does that with an
`object_access_hook`.

## Recipes

**Disable statistics collection temporarily:**

```sql
SET vacuum_statistics.enabled = off;
```

## Views

| View | Description |
|------|-------------|
| `ext_vacuum_statistics.pg_stats_vacuum_tables` | Per-table heap vacuum stats (pages scanned, tuples deleted, dead tuples, etc.) |
| `ext_vacuum_statistics.pg_stats_vacuum_indexes` | Per-index vacuum stats |
| `ext_vacuum_statistics.pg_stats_vacuum_database` | Per-database aggregate vacuum stats |

## Limitations

- Must be loaded via `shared_preload_libraries`; it cannot be loaded on demand.
- Starting a server without the module, even once, makes it treat the whole
  statistics file as corrupted and reset all cumulative statistics, the
  built-in ones included.  Use `vacuum_statistics.enabled = off` rather than
  removing the module.

## Append-optimized tables

AO row and AOCS tables and their indexes are reported too.  For the table,
`tuples_deleted` is the number of dead tuples the compaction discarded and
`pages_removed` the space released by truncating and dropping segment files,
in heap-equivalent pages; the heap-only counters (`pages_scanned`,
`tuples_frozen`, `recently_dead_tuples`, `missed_dead_*`) stay zero.  The
resource usage covers all phases of the vacuum, which is reported at the end
of the last one.  The compaction moves live tuples to another segment file,
so an index's `tuples_deleted` counts the entries of the moved live tuples
too.

## Cloudberry

Each instance (the coordinator and every segment) keeps the statistics of the
vacuums it runs itself; the views show the statistics of the instance they are
queried on.  Load the module on all instances, mirrors and the standby
coordinator included, and restart the cluster:

```
gpconfig -c shared_preload_libraries -v '<existing libraries>,ext_vacuum_statistics'
gpstop -ar
```

Cluster-wide views, like the `gp_stat_*` views of the core:

| View | Description |
|------|-------------|
| `ext_vacuum_statistics.gp_stats_vacuum_tables` | `pg_stats_vacuum_tables` of every instance, with `gp_segment_id` (-1 for the coordinator) |
| `ext_vacuum_statistics.gp_stats_vacuum_indexes` | the same for indexes |
| `ext_vacuum_statistics.gp_stats_vacuum_database` | the same for databases |
| `ext_vacuum_statistics.gp_stats_vacuum_tables_summary` | one row per table: summed over the segments (divided by their number for replicated tables); catalogs as on the coordinator |
| `ext_vacuum_statistics.gp_stats_vacuum_indexes_summary` | the same for indexes |
| `ext_vacuum_statistics.gp_stats_vacuum_database_summary` | one row per database, summed over all instances |

The reset functions act on the instance they are called on;
`gp_vacuum_statistics_reset()`, `gp_extvac_reset_entry(dboid, relid)` and
`gp_extvac_reset_db_entry(dboid)` run them on the whole cluster.  A `SET` of
`vacuum_statistics.enabled` on the coordinator is passed on to the segments.

The statistics are not replicated: after a failover the promoted mirror starts
with empty statistics, as with the built-in cumulative statistics.

The test of the cluster-wide views runs against such a cluster:

```
make -C contrib/ext_vacuum_statistics installcheck-cluster
```
