# gp_dist_random loses segment execution for a UNION ALL view

This is a planner bug, independent of `ext_vacuum_statistics`. The reproduction
uses only built-in objects and does not require the extension or its views.
The planner change from commit `a94debaa12e` is excluded from the vacuum statistics
change; this report preserves the reproduction for a separate fix.

## Reproduction

Connect to a Cloudberry coordinator with multiple primary segments. Use the
PostgreSQL planner (`optimizer = off`); ORCA behavior is not established here.

```sql
SET optimizer = off;

CREATE TEMP VIEW gdr_union AS
  SELECT gp_execution_segment() AS seg, 1 AS branch FROM gp_id
  UNION ALL
  SELECT gp_execution_segment(), 2 FROM gp_id;

SELECT branch,
       bool_and(seg >= 0) AS on_segments,
       count(*) = (SELECT count(*) FROM gp_segment_configuration
                    WHERE role = 'p' AND content >= 0) AS once_per_segment
  FROM gp_dist_random('gdr_union')
 GROUP BY branch
 ORDER BY branch;
```

Expected: both columns are `t` for each branch. Each branch should execute once
on each primary segment, with no coordinator row.

Observed on the three-segment test cluster before the planner change:

```text
 branch | on_segments | once_per_segment
--------+-------------+------------------
      1 | f           | f
      2 | f           | f
```

## Controls and cleanup

```sql
-- Ordinary access should execute both branches on the coordinator: t, t.
SELECT count(*) = 2 AS two_rows, bool_and(seg = -1) AS on_coordinator
  FROM gdr_union;

-- This nested, filtered form already passed before the proposed fix: t, t.
CREATE TEMP VIEW gdr_union_filtered AS
  SELECT * FROM gdr_union WHERE branch = 2;
SELECT bool_and(seg >= 0) AS on_segments,
       count(*) = (SELECT count(*) FROM gp_segment_configuration
                    WHERE role = 'p' AND content >= 0) AS once_per_segment
  FROM gp_dist_random('gdr_union_filtered');

-- An impossible filter should return zero rows.
SELECT count(*) FROM gp_dist_random('gdr_union') WHERE branch = 3;

DROP VIEW gdr_union_filtered;
DROP VIEW gdr_union;
RESET optimizer;
```

## Cause and proposed direction

In `src/backend/optimizer/prep/prepjointree.c`, ordinary subquery pull-up honors
`RangeTblEntry.forceDistRandom`, but the `is_simple_union_all()` branch in
`pull_up_subqueries_recurse()` does not. Pulling up the UNION ALL loses the
requirement to execute on segments.

Adding `!rte->forceDistRandom` before `is_simple_union_all()` made the direct
reproduction return `t, t` for both branches in an earlier test run. The ordinary,
nested, and empty-result controls also passed. This is evidence for a separate
planner fix, not a change needed in the creation of vacuum statistics views.

The SQL examples and observations above are retained here instead of adding
planner code or planner regression tests to the vacuum statistics change.
