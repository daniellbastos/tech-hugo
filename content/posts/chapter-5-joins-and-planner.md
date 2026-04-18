---

title: "Access Path Selection in a Relational Database Management System - Chapter 5: Joins and the Planner"
date: 2026-04-18
draft: false
description: "This post continues the study of ‘Access Path Selection in a Relational Database Management System’ (Selinger et al., 1979), now covering chapter 5 and how the optimizer handles joins. PostgreSQL uses hash join most often, which the 1979 paper doesn’t describe."
tags: ["database", "system r", "joins", "query planner", "explain analyze", "postgresql"]
---


> This post continues the study of [Access Path Selection in a Relational Database Management System (Selinger et al., 1979)](https://courses.cs.duke.edu/compsci516/cps216/spring03/papers/selinger-etal-1979.pdf), now covering chapter 5. I used available internet resources and tools to go deeper on the examples and make the concepts more concrete.

## What chapter 5 covers

Chapter 5 covers joins. The paper describes two methods, nested loops and merging scans, and how the optimizer picks between them. It also describes join order selection: given N tables, which one to read first, which second, which last.

PostgreSQL today has a third method the paper doesn’t cover: hash join. In practice, hash join is what most real-world joins use. The two methods in the paper are still there, they just show up less often.

I previously covered [chapter 3](/posts/access-path-selection-relational-database-management-system/) and [chapter 4](/posts/chapter-4-cost-formulas/). This post assumes familiarity with page fetches, selectivity factor F, and interesting orders from those.

## Nested loops

When a query involves two tables, the optimizer designates one as the **outer relation** and one as the **inner**. The outer is read first. For each tuple retrieved from the outer, the optimizer looks for matching tuples in the inner.

The inner relation is scanned once per tuple from the outer. If the inner has an index on the join column, each lookup is fast. Without an index, the inner relation is read in full for every outer tuple.

```
Outer = DEPT (3 departments), Inner = EMP (1000 employees)

With index on EMP.DNO:    3 lookups       ~6 page fetches
Without index on EMP.DNO: 3 full scans  ~300 page fetches
```

## Merging scans

The second method requires both relations to be in order by the join column. Both are traversed in parallel, values advance together, tuples combine when they match.

```
EMP and DEPT both sorted by DNO:

  DNO=50 in EMP: Smith, Jones
  DNO=50 in DEPT: MFG
  --> Smith+MFG, Jones+MFG

  DNO=51 in EMP: Doe, Clark
  DNO=51 in DEPT: Billing
  --> Doe+Billing, Clark+Billing
```

Each relation is traversed once. If neither has an index on the join column, both need to be sorted first. That sort is paid once, then the merge is one sequential pass through each.

## Join order

Given N tables, the optimizer evaluates permutations to find the one that minimizes total cost. The paper notes that the best plan for K+1 tables can always be derived from the best plans for subsets of K. Search becomes manageable rather than factorial.

With three tables, the order matters. Filtering the most selective relation first can mean the difference between carrying 50 tuples or 1000 into the most expensive join step. The optimizer picks that order based on the cost formulas from chapter 4 applied to each intermediate result.

## Hash join (not in the paper)

Hash join works in two phases: read the smaller relation and build a hash table in memory keyed by the join column, then scan the larger relation and probe the hash table for matches.

If the smaller relation fits in memory, each relation is read exactly once. No index required. No sort required.

Nested loops without an index on the inner is expensive, every outer tuple triggers a full scan of the inner. Merging scans requires the inputs to be sorted, which either costs a sort or a pre-existing index. Hash join works when the input is large and there’s no index on the join column.

Nested loop still appears when the inner has a good index and the outer result is small. Merge join appears for sorted inputs or range-based joins. Hash join shows up everywhere else.

## Reading EXPLAIN

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT name, dname
FROM emp
JOIN dept ON emp.dno = dept.dno
WHERE salary > 10000;
```

```
Hash Join  (cost=5.0..320.0 rows=750 width=40)
           (actual time=0.8..18.3 rows=748 loops=1)
  Buffers: shared hit=45 read=60
  ->  Seq Scan on emp  (cost=0.0..250.0 rows=750 width=32)
                       (actual time=0.1..12.1 rows=748 loops=1)
        Filter: (salary > 10000)
        Rows Removed by Filter: 252
  ->  Hash
        ->  Seq Scan on dept ...
```

`cost=5.0..320.0` is the optimizer’s estimate before execution. `rows=750` is F * NCARD, the estimated result of applying the selectivity factor from chapter 4. `actual rows=748` is what came back.

`Buffers: shared hit=45 read=60` is the page fetch breakdown: 45 pages from the buffer pool, 60 from disk. That’s the real cost the optimizer was trying to minimize.

The number to watch is `rows=750` estimated versus `rows=748` actual. When those diverge, estimated 100 versus actual 100,000, the optimizer chose a plan based on wrong information. The estimate feeds every downstream choice, so they’re wrong too.

## When row estimates go wrong

The most common case is stale statistics. A table receives a large data load, `ANALYZE` hasn’t run since, the planner still thinks the table has 100 rows. With 5 million rows, a plan that chose nested loops because 100 outer tuples looked cheap turns into 5 million scans of the inner.

```sql
SELECT relname, n_live_tup, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;
```

`last_autoanalyze` far in the past on a large table confirms it. `ANALYZE table_name` fixes it immediately.

Correlated columns are a different problem. The optimizer assumes predicates on different columns are independent, so F(A AND B) = F(A) * F(B). When the columns are correlated, like `country = 'Brazil' AND city = 'Rio Grande do Sul'`, the real F is higher than the product. The optimizer underestimates the result and may pick a plan too aggressive for the actual data.

```sql
CREATE STATISTICS orders_country_city ON country, city FROM orders;
ANALYZE orders;
```

PostgreSQL 10+ learns the dependency if you tell it where to look.

A different kind of failure happens above 8 joined tables. PostgreSQL evaluates join order exhaustively up to 8 tables; above that it switches to a genetic algorithm. The algorithm works but doesn’t guarantee the optimal order. Queries joining 12 or 15 tables sometimes end up with the most selective filters applied last. Breaking those queries into CTEs with `MATERIALIZED` forces evaluation order across that boundary.

## When the hash doesn’t fit

`Hash Batches: 1` in EXPLAIN means the hash table fit in memory. `Hash Batches: 4` means it spilled to disk four times. `work_mem` controls how much memory is available for hash tables and sorts per operation. The default is 4MB.

```sql
SET work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS) <query>;
```

Raising it per session for heavy queries is safer than changing it globally. A high `work_mem` multiplied by many concurrent queries is a good way to exhaust memory on the host.

## Notes

- [Planner/Optimizer — PostgreSQL Documentation](https://www.postgresql.org/docs/current/planner-optimizer.html) — Official documentation on how the planner selects query plans, including the genetic query optimizer used above 8 relations. Primary reference for join order selection in PostgreSQL.
- [Extended Statistics — PostgreSQL Documentation](https://www.postgresql.org/docs/current/planner-stats.html#PLANNER-STATS-EXTENDED) — Official documentation on `CREATE STATISTICS` for multi-column dependencies. Primary reference for the correlated columns discussion.
