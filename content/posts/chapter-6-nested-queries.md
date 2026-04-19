---

title: "Access Path Selection in a Relational Database Management System - Chapters 6 and 7: Nested Queries"
date: 2026-04-19
draft: false
description: "This post closes the study of Selinger et al. (1979), covering nested queries. Whether a subquery references columns from the outer query determines if it runs once or thousands of times."
tags: ["database", "system r", "nested queries", "subquery", "explain analyze", "postgresql"]
---

> This post closes the study of [Access Path Selection in a Relational Database Management System (Selinger et al., 1979)](https://courses.cs.duke.edu/compsci516/cps216/spring03/papers/selinger-etal-1979.pdf), covering chapters 6 and 7. I used available internet resources and tools to go deeper on the examples and make the concepts more concrete.

## What chapters 6 and 7 cover

Chapter 6 describes how the optimizer handles nested queries, which are queries that contain a subquery as a predicate operand. The chapter’s central distinction is whether the subquery references a column from the outer query. That single property determines how many times the subquery runs.

Chapter 7 is the paper’s conclusion. It reports that the optimizer selects the true optimal path in a large majority of cases, even when cost estimates are not accurate in absolute terms.

I previously covered [chapter 3](/posts/access-path-selection-relational-database-management-system/), [chapter 4](/posts/chapter-4-cost-formulas/), and [chapter 5](/posts/chapter-5-joins-and-planner/). This post assumes familiarity with access paths, selectivity factor F, and join methods from those.

## Non-correlated subquery: evaluated once

The paper’s first example:

```sql
SELECT name
FROM employee
WHERE salary = (SELECT AVG(salary) FROM employee)
```

The subquery `SELECT AVG(salary) FROM employee` does not reference any column from the outer query. Its result is the same regardless of which row the outer query is currently evaluating. The optimizer evaluates it first, gets a single number, and substitutes it into the outer query before anything else runs:

```
1. Evaluate subquery --> AVG = 15000
2. Rewrite: WHERE salary = 15000
3. Run the outer query with that fixed value
```


```sql
SELECT name
FROM employee
WHERE department_number IN (
    SELECT department_number
    FROM department
    WHERE location = 'Denver'
)
```

The subquery does not reference `employee`. The optimizer evaluates it first, produces a list of values, and the outer query runs against that list. The paper describes this result as a temporary list — an internal structure accessed sequentially, more efficient than a full relation.

## Correlation subquery: evaluated N times

The paper’s third example:

```sql
SELECT name
FROM employee x
WHERE salary > (
    SELECT salary
    FROM employee
    WHERE employee_number = x.manager
)
```

`x.manager` references the current candidate row from the outer query. The subquery result changes for each row being evaluated. The optimizer cannot compute it once and substitute — it must re-run the subquery for each candidate tuple.

```
Candidate row 1: x.manager = 201
  -> subquery WHERE employee_number = 201
  -> returns salary = 12000
  -> test: x.salary > 12000?

Candidate row 2: x.manager = 201  (same manager)
  -> subquery WHERE employee_number = 201  (runs again)
  -> returns salary = 12000
  -> test: x.salary > 12000?

Candidate row 3: x.manager = 305
  -> subquery WHERE employee_number = 305
  -> returns salary = 18000
  -> test: x.salary > 18000?
```

With 1000 rows in `employee`, the subquery runs up to 1000 times. The paper calls this a **correlation subquery**.

## Reducing re-evaluations with ordering

The paper describes an optimization: if the outer query produces rows ordered by the referenced column, the subquery result can be reused across consecutive rows with the same value.

```
employee rows ordered by manager:

  manager=201: Smith   -> evaluate subquery(201) -> salary=12000
  manager=201: Jones   -> same value, reuse result
  manager=201: Doe     -> same value, reuse result
  manager=305: Clark   -> new value, evaluate subquery(305) -> salary=18000
  manager=305: Taylor  -> same value, reuse result
```

```
Without ordering: N evaluations (one per candidate row)
With ordering:    D evaluations (D = distinct manager values)
```

The optimizer detects whether this is worth doing by comparing NCARD and ICARD. If `NCARD > ICARD`, the referenced column has repeated values, and sorting to exploit them may reduce cost enough to justify the sort.

## Multi-level nesting

The paper also covers subqueries that are themselves nested:

```sql
-- level 1
SELECT name
FROM employee x
WHERE salary > (
    -- level 2
    SELECT salary
    FROM employee
    WHERE employee_number = (
        -- level 3
        SELECT manager
        FROM employee
        WHERE employee_number = x.manager
    )
)
```

The level-3 subquery references `x.manager`, a value from level 1. The level-2 subquery does not reference level 1 directly, but depends on the level-3 result.

```
For each candidate row at level 1:
  x.manager changes
  -> level 3 re-evaluated (depends on x.manager)
  -> level 2 re-evaluated (depends on level-3 result)
```

The paper states that a subquery is re-evaluated for each new candidate tuple of the level it references, not of every intermediate level. If the same `x.manager` value appears in multiple consecutive level-1 rows, the level-3 result can be reused across them, and level 2 along with it.

## Reading EXPLAIN: InitPlan vs SubPlan (not in the paper)

PostgreSQL surfaces the paper’s distinction between non-correlated and correlated subqueries directly in EXPLAIN output, as two different node types.

**Non-correlated subquery — InitPlan:**

```
InitPlan 1 (returns $0)
  ->  Aggregate  (cost=25.0..25.0 rows=1 width=8)
                 (actual time=1.1..1.1 rows=1 loops=1)
        ->  Seq Scan on employee

Seq Scan on employee  (cost=25.0..75.0 rows=5 width=32)
                      (actual time=1.2..3.4 rows=5 loops=1)
  Filter: (salary = $0)
```

The InitPlan node appears before the main scan. Its result becomes parameter `$0`. `loops=1` on the Aggregate confirms it ran once.

**Correlation subquery — SubPlan:**

```
Seq Scan on employee x  (cost=0.0..2500.0 rows=333 width=32)
                        (actual time=0.1..45.2 rows=310 loops=1)
  Filter: (salary > (SubPlan 1))
  Rows Removed by Filter: 690
  SubPlan 1
    ->  Index Scan on employee  (cost=0.4..2.4 rows=1 width=8)
                                (actual time=0.04..0.04 rows=1 loops=1000)
          Index Cond: (employee_number = x.manager)
```

The SubPlan node appears inside the scan. `loops=1000` means the subquery ran 1000 times.

One thing to watch: `actual time` in EXPLAIN is the average per execution, not the total. The real time spent in this SubPlan is `0.04ms * 1000 = 40ms`, not 0.04ms. The PostgreSQL documentation states this explicitly — multiply `actual time` by `loops` to get the total time spent in any node that executes more than once.

**IN subquery rewritten as Hash Join:**

When the optimizer can determine semantic equivalence, it rewrites non-correlated IN subqueries as joins entirely. The SubPlan disappears:

```
Hash Join  (cost=5.0..120.0 rows=100 width=32)
           (actual time=0.5..8.2 rows=98 loops=1)
  Hash Cond: (employee.department_number = department.department_number)
  ->  Seq Scan on employee  (actual time=0.1..4.1 rows=1000 loops=1)
  ->  Hash
        ->  Seq Scan on department  (actual time=0.1..0.2 rows=38 loops=1)
              Filter: (location = 'Denver')
```

`loops=1` on every node. Each relation read once.

SubPlan with `loops=1` in EXPLAIN is fine. SubPlan with `loops` proportional to the outer table size is the signal worth investigating — whether a rewrite as join is possible.

## What the paper concludes

The paper’s conclusion is short. The optimizer selects the true optimal path in a large majority of cases. In many cases, the ordering among estimated costs for all candidate paths matches the ordering among actual measured costs exactly — even when the absolute numbers are off.

The cost of the optimization itself is modest: for a two-way join, path selection costs approximately the equivalent of 5 to 20 database retrievals. In a compiled environment like System R, where a plan is compiled once and executed many times, that cost is amortized across all runs.

The three contributions the paper identifies as distinct from prior work: the expanded use of statistics (index cardinality, specifically), the inclusion of CPU utilization in cost formulas alongside I/O, and the method for determining join order using interesting orders and equivalence classes to avoid storing redundant solutions.

## Notes

- [14.1. Using EXPLAIN — PostgreSQL Documentation](https://www.postgresql.org/docs/current/using-explain.html) — Official reference for InitPlan and SubPlan node types, the semantics of `loops` in EXPLAIN ANALYZE (average per execution, not total), and how subplans appear in query plans.
- [SubPlan — pgMustard](https://www.pgmustard.com/docs/explain/subplan) — Documents the InitPlan vs SubPlan distinction in PostgreSQL’s EXPLAIN output, including when each node type appears.
