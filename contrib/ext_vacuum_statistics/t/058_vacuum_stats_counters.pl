# Copyright (c) 2026, PostgreSQL Global Development Group

# Check relation coverage and that successive index vacuums only count newly
# deleted pages, not pages that were already deleted by an earlier vacuum.
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('vacstat_counters');
$node->init;
$node->append_conf('postgresql.conf', q{
shared_preload_libraries = 'ext_vacuum_statistics'
autovacuum = off
});
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION ext_vacuum_statistics');

my $nrows = 10000 *
  ($node->safe_psql('postgres', 'SHOW block_size') / 8192);
$node->safe_psql('postgres', qq{
CREATE TABLE page_counts (id int PRIMARY KEY);
INSERT INTO page_counts SELECT generate_series(1, $nrows);
DELETE FROM page_counts WHERE id <= $nrows / 2;
});
$node->safe_psql('postgres', 'VACUUM (INDEX_CLEANUP ON) page_counts');
my $pages_sql = q{
SELECT pages_deleted FROM ext_vacuum_statistics.pg_stats_vacuum_indexes
 WHERE indexrelname = 'page_counts_pkey'};
my $pages = $node->safe_psql('postgres', $pages_sql);
cmp_ok($pages, '>', 0, 'first vacuum deleted index pages');

# Delete one tuple from a populated leaf to force another bulkdelete scan
# without emptying another leaf. Old deleted pages are still in the index.
$node->safe_psql('postgres', "DELETE FROM page_counts WHERE id = $nrows - 1");
$node->safe_psql('postgres', 'VACUUM (INDEX_CLEANUP ON) page_counts');
is($node->safe_psql('postgres', $pages_sql), $pages,
   'second index scan does not count previously deleted pages again');

$node->safe_psql('postgres', q{
CREATE MATERIALIZED VIEW vacuum_mv AS SELECT 1 AS id;
CREATE TABLE vacuum_toast (v text);
ALTER TABLE vacuum_toast ALTER COLUMN v SET STORAGE EXTERNAL;
INSERT INTO vacuum_toast VALUES (repeat('x', 100000));
});
$node->safe_psql('postgres', 'VACUUM vacuum_mv, vacuum_toast');
is($node->safe_psql('postgres', q{
SELECT count(*) FROM ext_vacuum_statistics.pg_stats_vacuum_tables
 WHERE relid = 'vacuum_mv'::regclass}), '1',
   'table statistics view includes materialized views');
is($node->safe_psql('postgres', q{
SELECT count(*) FROM ext_vacuum_statistics.pg_stats_vacuum_tables
 WHERE relid = (SELECT reltoastrelid FROM pg_class
                 WHERE oid = 'vacuum_toast'::regclass)}), '1',
   'table statistics view includes TOAST relations');

# AO data is read outside the buffer manager. Index buffer accesses must not
# be subtracted from the table's own relation-local counters.
for my $orientation ('row', 'column')
{
    my $table = "vacuum_ao_$orientation";
    $node->safe_psql('postgres', qq{
CREATE TABLE $table (id int) WITH (appendonly = true, orientation = $orientation);
CREATE INDEX ${table}_idx ON $table (id);
INSERT INTO $table SELECT generate_series(1, $nrows);
DELETE FROM $table WHERE id % 2 = 0;
});
    $node->safe_psql('postgres', "VACUUM $table");
    is($node->safe_psql('postgres', qq{
SELECT rel_blks_read >= 0 AND rel_blks_hit >= 0
  FROM ext_vacuum_statistics.pg_stats_vacuum_tables
 WHERE relname = '$table'}), 't',
       "$orientation AO table has nonnegative relation-local block counts");
    is($node->safe_psql('postgres', qq{
SELECT rel_blks_hit > 0
  FROM ext_vacuum_statistics.pg_stats_vacuum_indexes
 WHERE indexrelname = '${table}_idx'}), 't',
       "$orientation AO vacuum accessed index buffers");
}

$node->stop;
done_testing();
