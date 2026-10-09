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

From a Cloudberry coordinator, query statistics across the cluster:

```sql
-- Per-table heap and append-optimized vacuum statistics, with gp_segment_id
SELECT * FROM ext_vacuum_statistics.gp_stats_vacuum_tables;

-- Per-index vacuum statistics
SELECT * FROM ext_vacuum_statistics.gp_stats_vacuum_indexes;

-- Per-database aggregate vacuum statistics
SELECT * FROM ext_vacuum_statistics.gp_stats_vacuum_database;
```

The corresponding `pg_stats_vacuum_*` views read only the connected instance.
Use them for a standalone server or a utility connection to a single segment.
Use the `gp_stats_vacuum_*_summary` views for cluster totals.

Example projection of table statistics:

```
 relname   | total_blks_read | total_blks_hit | wal_records | tuples_deleted | pages_removed
-----------+-----------------+----------------+-------------+----------------+---------------
 mytable   |             120 |            340 |          15 |            500 |            10
```

Reset statistics across the cluster from the coordinator:

```sql
SELECT ext_vacuum_statistics.gp_vacuum_statistics_reset();
```

Use the `gp_` wrappers from a normal coordinator connection to reset statistics
on the coordinator and all primary segments.

**Local functions reset only the current node.** Calling
`ext_vacuum_statistics.vacuum_statistics_reset()` on the coordinator (QD)
resets only the coordinator's counters; segment counters remain unchanged.
The same applies to `extvac_reset_entry()` and `extvac_reset_db_entry()`.
Use the local functions for a utility connection to an individual segment.

All functions below belong to the `ext_vacuum_statistics` schema:

| Reset scope | Cluster wrapper (call on the coordinator) | Local function (current node only) |
|-------------|------------------------------------------|-----------------------------------|
| One table or index | `gp_extvac_reset_entry(dboid, relid)` | `extvac_reset_entry(dboid, relid)` |
| One database and all its relations | `gp_extvac_reset_db_entry(dboid)` | `extvac_reset_db_entry(dboid)` |
| All databases | `gp_vacuum_statistics_reset()` | `vacuum_statistics_reset()` |

For example, reset only the current database across the cluster:

```sql
SELECT ext_vacuum_statistics.gp_extvac_reset_db_entry(oid)
FROM pg_database WHERE datname = current_database();
```

## Configuration (GUCs)

| GUC | Default | Description |
|-----|---------|-------------|
| `vacuum_statistics.enabled` | on | Enable extended vacuum statistics collection |

## Memory usage

Each tracked object (table or index) uses a fixed-size shared memory entry; the exact size depends on the platform.

Per-database aggregates add one entry per tracked database. Entry size includes
the AO phase counters and pgstat bookkeeping; memory estimates must use the
structures of the actual build rather than a fixed byte count from an earlier
version.

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

## Native work counters

Heap, index and AO work is also collected by the built-in statistics system
without this module. Use `pg_stat_vacuum_tables`, `pg_stat_vacuum_indexes`
and `pg_stat_vacuum` (and their `gp_stat_*` counterparts) for native counters.
They obey `track_counts` and ordinary `pg_stat_reset*` functions. The extension
retains its existing counters for compatibility and adds resource measurements
such as buffers and WAL. Its counters obey `vacuum_statistics.enabled` and
its own reset functions. Extension-specific resets do not clear native counters;
`pg_stat_reset()` also clears the extension's entries for the current database.

## Heap page counters

`pages_frozen` accumulates pages on which vacuum froze at least one tuple.
`pages_all_visible` accumulates pages whose visibility-map all-visible bit
vacuum changed from unset to set, including empty pages. These count work
across vacuums, not the current number of frozen or all-visible pages. A
page can be counted again after later changes require new work; rescanning
an unchanged page or adding only its all-frozen bit does not add to
`pages_all_visible`. Both counters survive clean restarts and are cleared
by statistics resets.

`dead_pages` accumulates heap pages containing tuples that are dead but
not yet removable (for example, because an old snapshot still needs them).
It differs from `missed_dead_pages`, which counts pages with removable tuples
that vacuum could not remove. For indexes, `dead_pages` accumulates deleted
pages not yet reusable, sampled once after cleanup. Repeated observations
are counted again; this is not a snapshot of the current relation.

`freeze_age_vacuum_count` counts heap vacuums made aggressive by the XID or
MultiXact freeze table age, including `VACUUM FREEZE`. Forcing a scan with
`DISABLE_PAGE_SKIPPING` alone does not increment it, and entering failsafe
mode is counted separately. Both new counters survive clean restarts and
are cleared by statistics resets.

## Append-optimized tables

AO row and AOCS tables and their indexes are reported too.  For the table,
`tuples_deleted` is the number of dead tuples the compaction discarded and
`pages_removed` the space released by truncating and dropping segment files,
in heap-equivalent pages. `pages_scanned` counts the data scanned during
compaction in those units, rounded up per compacted segment (source EOF for
AO row, scan bytes read for AOCS). `compacted_segments` and `tuples_moved`
accumulate actual compactions and live rows moved; skipped candidates add
nothing. `total_file_segs` is the segment metadata entry count after the
latest vacuum, including empty and awaiting-drop entries. It is replaced on
each vacuum, not accumulated; AOCS counts segment numbers, not individual
column files. A statistics reset clears these values, and the next vacuum
refreshes the segment count even without compaction. All three AO-specific
fields stay zero for heap tables.

`awaiting_drop_segments` is the number of segment metadata entries still in
`AWAITING_DROP` at the end of the last completed vacuum. An older snapshot
can delay their recycling even after compaction has finished. This value is
replaced, not accumulated; AOCS counts segment numbers, not column files.
It is zero for heap tables and after reset.

The `ao_pre_cleanup_*`, `ao_compaction_*` and `ao_post_cleanup_*` columns
break down cumulative resource usage by phase. Each prefix has `blks_read`,
`blks_hit`, `blks_dirtied`, `blks_written`, `wal_records`, `wal_fpi`,
`wal_bytes`, `blk_read_time` and `blk_write_time`. Buffer counts include
shared and local buffers, as in `total_blks_*`; I/O times are milliseconds
and require `track_io_timing`. Index resource usage is excluded from its
phase and remains in the index statistics. The three phase counters sum to
the corresponding table total (apart from floating-point rounding of times).
Heap tables have zero phase counters. Cluster summaries use the same
sum/replicated-average rules as the other table fields. In replicated
summaries, independently rounded integer fields can differ by rounding.

All new fields obey collection control and resets and survive clean
restarts. Failed vacuums do not publish a table report; replacement workers
report only phases they executed. This development-series payload change
bumps the statistics-file format: installing the new build discards saved
statistics from the previous format. Rebuild the server and extension
together and recreate the extension's SQL objects when updating a test
installation from the earlier 1.0 definition.

`recently_dead_tuples` accumulates the hidden rows remaining in the AO
visibility map after post-cleanup. This includes rows left because
compaction is disabled or below its threshold. Each completed vacuum adds
its remaining count, so two vacuums that both leave 100 hidden rows add
200; it is not a snapshot or a count of distinct rows. Once compaction
removes those rows, later vacuums add zero. Statistics resets clear the
counter, and clean restarts preserve it.

The heap-only counters (`pages_frozen`, `pages_all_visible`,
`tuples_frozen`, `missed_dead_*`, `dead_pages`, `freeze_age_vacuum_count`) stay zero for AO. The
resource usage covers all phases of the vacuum, which is reported at the end
of the last one.  The compaction moves live tuples to another segment file,
so an index's `tuples_deleted` counts the entries of the moved live tuples
too.

AO vacuum time and cost delay are summed over the active phases executed
by the reporting worker. Gaps between phases are excluded. If a worker is
replaced between phases, only the replacement worker's phases are reported.
Removed tuple and byte counters use 64 bits; conversion of released bytes
to heap-equivalent pages preserves the 64-bit range.

AO auxiliary relations (`aoseg`, `visimap`, `blkdir`) are shown as separate
heap-statistics rows under their own OIDs and names. Their indexes are shown
in the index views. The parent AO row describes its phases; the later heap
vacuum of auxiliary relations is not added to it. To associate an auxiliary
row with its parent, join its `relid` to `pg_appendonly.segrelid`,
`visimaprelid` or `blkdirrelid`. Cluster summaries use the parent table's
replication divisor for auxiliary relations and their indexes too.

## Cloudberry

Each instance (the coordinator and every segment) keeps the statistics of the
vacuums it runs itself. The local `pg_stats_vacuum_*` views show only that
instance; use `gp_stats_vacuum_*` to read the coordinator and primary segments.

Install the matching extension library, control and SQL files in the Cloudberry
installation on every host, including mirror and standby coordinator hosts.
`gpconfig` changes configuration files; it does not distribute extension files.
Load the module on every instance so it is also available after promotion.

Inspect both the active setting and the configuration files first:

```sh
gpconfig -s shared_preload_libraries
gpconfig -s shared_preload_libraries --file
```

When the existing list is empty, configure it with:

```sh
gpconfig -c shared_preload_libraries -v 'ext_vacuum_statistics'
```

Otherwise pass the complete existing list with `ext_vacuum_statistics` appended.
Preserve any intentional differences between coordinator, primary and mirror
settings; do not replace their other preloaded libraries. With `-v` and no
role restriction, `gpconfig` updates the coordinator, standby, primaries and
mirrors. Resolve any reported unreachable hosts before relying on their setup.
Check the resulting files, then restart the cluster to load the library:

```sh
gpconfig -s shared_preload_libraries --file
gpstop -ar
gpconfig -s shared_preload_libraries --file-compare
```

A configuration reload (`gpstop -u`) alone cannot load a new preload library.
Check that mirror and standby instances also restarted successfully. After the
restart, run the following on the coordinator in each database where the views
are needed; `CREATE EXTENSION` is dispatched to the segments:

```sql
CREATE EXTENSION IF NOT EXISTS ext_vacuum_statistics;
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

The reset functions without the `gp_` prefix act only on the connected instance;
`gp_vacuum_statistics_reset()`, `gp_extvac_reset_entry(dboid, relid)` and
`gp_extvac_reset_db_entry(dboid)` dispatch the resets from the coordinator to
all primary segments and also reset the coordinator. A `SET` of
`vacuum_statistics.enabled` on the coordinator is passed on to the segments.

The counters are local pgstat state and are not replicated through WAL.
Preloading on a mirror enables collection after promotion; it does not copy
its primary's accumulated counters. A promoted instance reports its own local
statistics, so it cannot continue the former primary's counter history. This
also applies when the standby coordinator is promoted. A compatible clean
restart can preserve an instance's own counters; crash recovery resets them.

Treat promotion as a new measurement interval for the affected instance, even
if its `gp_segment_id` is unchanged. Other instances keep their own counters,
but cluster summaries can decrease when a primary is replaced. Monitoring
should retain previous samples externally and begin a new baseline after
failover, without interpreting the change as negative vacuum work.

The test of the cluster-wide views runs against such a cluster:

```
make -C contrib/ext_vacuum_statistics installcheck-cluster
make -C contrib/ext_vacuum_statistics installcheck-cluster-isolation2
```

The isolation2 target additionally requires a fault-injector build and the
`gp_inject_fault` extension installed on every instance. It checks retained
AO auxiliary entries during distributed DROP, including a suspension at
COMMIT PREPARED, and their removal after commit.

Reset functions return `void` and require superuser privileges by default.
An administrator can delegate access with `GRANT EXECUTE`; cluster wrappers
also require permission to execute the corresponding local reset function.
A relation reset clears only that relation's counters, leaving its indexes and
the database aggregate unchanged. A database reset clears its aggregate and
all its relation entries. The global reset affects all databases on the current
instance; the `gp_` wrappers apply these operations on the coordinator and all
primary segments.
Existing rows remain visible with zero counters until another vacuum updates
them. `pg_stat_reset()` also resets the extension's entries for the current
database. Resetting does not remove the type of a table, index, or database entry.
