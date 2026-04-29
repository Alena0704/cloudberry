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
| `vacuum_statistics.enabled` | `on` | Enable extended vacuum statistics collection |
| `vacuum_statistics.object_types` | `all` | Which object kinds to collect stats for: `all`, `databases`, `relations` |
| `vacuum_statistics.track_relations` | `all` | When `object_types` includes relations, restrict by relation kind: `all`, `system`, `user` |
| `vacuum_statistics.track_databases_from_list` | `off` | If `on`, track only databases registered via `add_track_database()` |
| `vacuum_statistics.track_relations_from_list` | `off` | If `on`, track only relations registered via `add_track_relation()` |
| `vacuum_statistics.collect` | `all` | Comma- or whitespace-separated list of stat categories to accumulate: `buffers`, `wal`, `general`, `timing`, or `all` |

All GUCs are `PGC_SUSET` — settable per-session by superusers and via `ALTER SYSTEM` / `postgresql.conf`. Changing them does not require a restart.

## Filtering: which objects get tracked

Three independent filters are applied in this order; an object is tracked only if it passes all of them.

### 1. Object kind — `vacuum_statistics.object_types`

Selects what categories of objects to track.

| Value | Per-table stats | Per-index stats | Per-database aggregate |
|-------|:---:|:---:|:---:|
| `all` (default) | ✓ | ✓ | ✓ |
| `relations` | ✓ | ✓ | — |
| `databases` | — | — | ✓ |

`relations` covers **both heap tables and indexes** — per-table stats land in `pg_stats_vacuum_tables`, per-index stats in `pg_stats_vacuum_indexes`. The two cannot be filtered independently.

### 2. Relation kind — `vacuum_statistics.track_relations`

When relations are tracked (i.e., `object_types ∈ {all, relations}`), narrow the set further by catalog vs. user-defined.

| Value | System catalogs (per `IsCatalogRelationOid`) | User-defined tables/indexes |
|-------|:---:|:---:|
| `all` (default) | ✓ | ✓ |
| `system` | ✓ | — |
| `user` | — | ✓ |

"System" here is whatever `IsCatalogRelationOid()` returns — built-in catalogs plus those in the `pg_catalog` / `information_schema` namespaces. Bootstrap-OID extensions (large catalog OIDs) still count as system; user objects in user schemas count as user.

If `object_types = 'databases'`, this GUC has no effect.

### 3. Explicit allowlists — `track_*_from_list`

When you need finer control than "system vs user", pin the filter to specific OIDs registered via `add_track_database()` / `add_track_relation()`. Lists are persisted to `pg_stat/ext_vacuum_statistics_track.oid` and survive restart; `OAT_DROP` cleans them up automatically when an object is dropped.

| GUC | Effect when `on` |
|-----|------------------|
| `vacuum_statistics.track_databases_from_list` | Only databases whose OID appears in the list (added via `add_track_database()`) are aggregated. |
| `vacuum_statistics.track_relations_from_list` | Only `(dboid, reloid)` pairs in the list are tracked. `dboid = 0` matches the relation in any database. |

When a list-based GUC is `off` (default) the corresponding category is governed only by `object_types` + `track_relations`.

### Quick selectors

| Goal | Settings |
|------|----------|
| Track everything (default) | `object_types=all` |
| Per-database aggregates only — minimum overhead | `object_types=databases` |
| User tables and their indexes only | `object_types=relations`, `track_relations=user` |
| System catalogs only | `object_types=relations`, `track_relations=system` |
| Specific tables in specific databases | `add_track_relation(...)` + `track_relations_from_list=on` |
| Pause collection without unloading | `enabled=off` |

### Stat categories — `vacuum_statistics.collect`

Orthogonal to the object filters: pick which counters get accumulated even for tracked objects. Useful when you want to keep the entry count low and only need a slice of the metrics.

| Token | Counters accumulated |
|-------|----------------------|
| `buffers` | `total_blks_read/hit/dirtied/written`, `blks_fetched`, `blks_hit`, `blk_read_time`, `blk_write_time` |
| `wal` | `wal_records`, `wal_fpi`, `wal_bytes` |
| `general` | `tuples_deleted`, `pages_*`, `vm_new_*`, `wraparound_failsafe_count`, `interrupts_count`, `tuples_frozen`, `recently_dead_tuples`, `missed_dead_*`, `index_vacuum_count`, `pages_deleted` |
| `timing` | `delay_time`, `total_time` |
| `all` (default) | every category above |

Multiple tokens may be combined: `vacuum_statistics.collect = 'wal, general'`. Categories not listed are simply not added into the report — entries already in shared memory keep their previous values.

## Memory usage

Each tracked object (table, index, or database) uses approximately **232 bytes** of shared memory on Linux x86_64 (e.g. Ubuntu): common stats (buffers, WAL, timing) ~144 bytes; type + union ~88 bytes (union holds table-specific or index-specific fields, allocated size is the same for both).

The exact size depends on the platform. Call `ext_vacuum_statistics.shared_memory_size()` to get the total shared memory used by the extension. The GUCs provided by the extension allow controlling the amount of memory used: `vacuum_statistics.object_types` to track only databases or relations, `vacuum_statistics.track_relations` to restrict to user or system tables/indexes, and `track_*_from_list` to track only selected databases and relations.

Example: a database with 1000 tables and 2000 indexes, all tracked, uses about **700 KB** on Ubuntu (3001 entries × 232 bytes). Per-database entries add one entry per tracked database.

## Advanced tuning

### Track only database-level stats

```sql
SET vacuum_statistics.object_types = 'databases';
```

Statistics are accumulated per database; per-relation views remain empty.

### Track only user or system tables

```sql
SET vacuum_statistics.object_types = 'relations';
SET vacuum_statistics.track_relations = 'user';   -- skip system catalogs
-- or
SET vacuum_statistics.track_relations = 'system'; -- only system catalogs
```

### Filter by database or relation OIDs

Add OIDs via functions (persisted to `pg_stat/ext_vacuum_statistics_track.oid`) and enable filtering:

```sql
-- Add databases and relations to track
SELECT ext_vacuum_statistics.add_track_database(16384);
SELECT ext_vacuum_statistics.add_track_relation(16384, 16385);  -- dboid, reloid
SELECT ext_vacuum_statistics.add_track_relation(0, 16386);      -- rel 16386 in any db

-- Enable list-based filtering (off = track all)
SET vacuum_statistics.track_databases_from_list = on;
SET vacuum_statistics.track_relations_from_list = on;
```

Remove OIDs when no longer needed:

```sql
SELECT ext_vacuum_statistics.remove_track_database(16384);
SELECT ext_vacuum_statistics.remove_track_relation(16384, 16385);
```

Inspect the current tracking configuration:

```sql
SELECT * FROM ext_vacuum_statistics.track_list();
```

Returns `track_kind`, `dboid`, `reloid`. When `dboid` or `reloid` is NULL, statistics are collected for all.

## Recipes

**Reduce overhead by tracking only databases:**

```sql
SET vacuum_statistics.object_types = 'databases';
```

**Track only a specific table in a specific database:**

```sql
SELECT ext_vacuum_statistics.add_track_database(
    (SELECT oid FROM pg_database WHERE datname = current_database())
);
SELECT ext_vacuum_statistics.add_track_relation(
    (SELECT oid FROM pg_database WHERE datname = current_database()),
    'mytable'::regclass
);
SET vacuum_statistics.track_databases_from_list = on;
SET vacuum_statistics.track_relations_from_list = on;
```

**Disable statistics collection temporarily:**

```sql
SET vacuum_statistics.enabled = off;
```

## Views

| View | Description |
|------|-------------|
| `ext_vacuum_statistics.pg_stats_vacuum_tables` | Per-table heap vacuum stats (pages scanned, tuples deleted, WAL, timing, etc.) |
| `ext_vacuum_statistics.pg_stats_vacuum_indexes` | Per-index vacuum stats |
| `ext_vacuum_statistics.pg_stats_vacuum_database` | Per-database aggregate vacuum stats |

## Limitations

- Must be loaded via `shared_preload_libraries`; it cannot be loaded on demand.
- Tracking configuration (`add_track_*`, `remove_track_*`) is stored in a file and shared across all databases in the cluster.
