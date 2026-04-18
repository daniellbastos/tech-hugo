---

title: "Access Path Selection in a Relational Database Management System - Chapter 4: Cost Formulas"
date: 2026-04-18
draft: false
description: "This post continues the study of 'Access Path Selection in a Relational Database Management System' (Selinger et al., 1979), now covering chapter 4 and the cost formulas the optimizer uses to compare access paths for a single relation."
tags: ["database", "system r", "query optimizer", "cost formulas", "relational database", "postgresql"]
---

> This post continues the study of [Access Path Selection in a Relational Database Management System (Selinger et al., 1979)](https://courses.cs.duke.edu/compsci516/cps216/spring03/papers/selinger-etal-1979.pdf), now covering chapter 4. I used available internet resources and tools to go deeper on the examples and make the concepts more concrete.

## What chapter 4 covers

Chapter 4 describes how the optimizer estimates the cost of each access path available for a single relation and picks the cheapest one. It introduces the catalog statistics the optimizer depends on, the selectivity factors applied to different predicate types, and the cost formulas for each possible situation: unique index with equality, clustered and non-clustered indexes with and without matching predicates, and the segment scan fallback.

The chapter ends with interesting orders, which is how the optimizer accounts for sort costs when the query has ORDER BY or GROUP BY.

I previously covered [chapter 3](/posts/access-path-selection-relational-database-management-system/), which describes the physical storage model (RSS) that these cost formulas operate on.

## The base table used in all examples

```
EMP
+----+--------+-----+--------+
| ID | NAME   | DNO | SALARY |
+----+--------+-----+--------+
| 1000 tuples total           |
| 10 tuples per page          |
| 100 data pages              |
+----+-----------------------------+

INDEX on SALARY:
  ICARD = 800  (distinct values)
  NINDX = 5    (index pages)
  SALARY between 5000 and 25000

INDEX on DNO:
  ICARD = 10   (distinct values)
  NINDX = 2    (index pages)
```

## Catalog statistics

Every variable in the cost formulas comes from the System R catalog. These statistics are not computed at runtime, they are updated periodically via `UPDATE STATISTICS`.

### NCARD

Total number of tuples in the relation.

```
NCARD(EMP) = 1000

F * NCARD = expected number of matching tuples
```

### TCARD

Number of data pages in the segment that hold tuples of this relation. Different from NCARD because a segment can hold multiple relations on the same pages.

```
Segment with EMP and DEPT mixed:

+------------------+
| PAGE 1           |
| [EMP] Smith      |
| [EMP] Jones      |
| [DEPT] MFG       |  <-- another relation
| [EMP] Doe        |
+------------------+
| PAGE 2           |
| [DEPT] Billing   |
| [EMP] Clark      |
+------------------+

TCARD(EMP) = 2  (pages that contain at least one EMP tuple)
```

When EMP is the only relation in the segment, TCARD equals the total number of data pages.

### P(T)

Fraction of segment pages that hold tuples of relation T.

```
P(T) = TCARD(T) / (number of non-empty pages in the segment)

If segment has 200 pages and EMP occupies 100:
  P(EMP) = 100/200 = 0.5

TCARD/P = actual pages the segment scan must read
```

When EMP owns the segment, P = 1 and TCARD/P = TCARD.

### NINDX

Number of pages in the index, including internal nodes and leaf pages.

```
INDEX (SALARY)
                  [root]           <- 1 internal page
                 /      \
           [internal]  [internal]  <- 2 internal pages
           /    \       /    \
        [leaf][leaf] [leaf][leaf]  <- 4 leaf pages

NINDX(SALARY) = 7
```

### ICARD

Number of distinct key values in the index.

```
ICARD(SALARY) = 800  (800 distinct salaries among 1000 employees)
ICARD(DNO)    = 10   (10 distinct departments)
```

Used in the selectivity factor for equality predicates:

```
F(column = value) = 1 / ICARD
```

### RSI_CALLS

Number of tuples returned across the RSS interface to the caller.

```
RSI_CALLS = F * NCARD

WHERE SALARY > 20000 --> F = 0.25 --> RSI_CALLS = 250
```

RSI_CALLS represents CPU cost. Each tuple returned must be processed by the layer above the RSS, so it enters the cost formula multiplied by W.

```
COST = PAGE_FETCHES + W * RSI_CALLS

W high = CPU-bound system, RSI_CALLS weighs more
W low  = I/O-bound system, PAGE_FETCHES weighs more
```

## The cost formula

```
COST = PAGE_FETCHES + W * RSI_CALLS
```

The optimizer computes this for every available access path, each index on the relation plus the segment scan, and picks the lowest cost.

## Selectivity factor (F)

F is the estimated fraction of tuples that will satisfy a predicate, between 0 and 1. Lower F means fewer tuples and a higher chance that an index wins over a segment scan.

### Equality

```
WHERE SALARY = 12000

With index:    F = 1 / ICARD = 1/800 = 0.00125
Without index: F = 1/10  (default assumption)
```

### Range

```
WHERE SALARY > 10000

F = (high key - value) / (high key - low key)
  = (25000 - 10000) / (25000 - 5000)
  = 15000 / 20000
  = 0.75

Without arithmetic column or unknown value: F = 1/3
```

### BETWEEN

```
WHERE SALARY BETWEEN 10000 AND 15000

F = (value2 - value1) / (high key - low key)
  = (15000 - 10000) / (25000 - 5000)
  = 5000 / 20000
  = 0.25

Without arithmetic column or unknown values: F = 1/4
```

### IN (list)

```
WHERE SALARY IN (8500, 12000, 20000)

F = number of items * F(equality)
  = 3 * (1/800)
  = 0.00375

Capped at 0.5 (the paper's upper bound for IN)
```

### AND

```
WHERE SALARY > 15000 AND DNO = 50

F = F(SALARY > 15000) * F(DNO = 50)
  = 0.5 * 0.1
  = 0.05
```

The paper assumes column independence.

### OR

```
WHERE SALARY > 20000 OR DNO = 50

F = F1 + F2 - F1 * F2
  = 0.25 + 0.1 - 0.025
  = 0.325
```

### NOT

```
F(NOT pred) = 1 - F(pred)
```

## Cost formulas by situation

Table 2 of the paper lists cost formulas for each situation. Using W = 1 throughout the examples.

### Unique index matching an equal predicate

```
COST = 1 + 1 + W = 1 + 1 + 1 = 3

One page fetch for the index leaf,
one for the data page, one RSI call.
```

### Clustered index matching one or more boolean factors

```
COST = F(preds) * (NINDX + TCARD) + W * RSI_CALLS

WHERE SALARY BETWEEN 10000 AND 15000, F = 0.25:
  = 0.25 * (5 + 100) + 250 * 0.25 * 1
  = 26.25 + 62.5
  = 88.75
```

With a clustered index, data pages are in index order and each page is read at most once.

### Non-clustered index matching one or more boolean factors

```
COST = F(preds) * (NINDX + NCARD) + W * RSI_CALLS

WHERE SALARY > 10000, F = 0.75:
  = 0.75 * (5 + 1000) + 750
  = 753.75 + 750
  = 1503.75
```

NCARD appears here instead of TCARD. With a non-clustered index, each matching tid may be on a different page, so the worst case is one page fetch per tuple.

### Clustered index not matching any boolean factors

```
COST = (NINDX + TCARD) + W * RSI_CALLS

Full index scan + all data pages.
F = 1 (no predicate to reduce it).
```

### Non-clustered index not matching any boolean factors

```
COST = (NINDX + NCARD) + W * RSI_CALLS

Full index scan + potentially one page fetch per tuple.
Usually worse than segment scan.
```

### Segment scan

```
COST = TCARD/P + W * RSI_CALLS

WHERE SALARY > 10000, F = 0.75:
  RSI_CALLS = 750
  COST = 100/1 + 750 = 850
```

## When segment scan beats index scan

The crossover point depends on F. As F grows, non-clustered index cost grows faster than segment scan cost, because NCARD is much larger than TCARD.

```
Full comparison for WHERE SALARY > X, W = 1:

F      RSI   Segment  Non-clustered  Winner
0.001    1    101        6.0          Index
0.01    10    110       20.5          Index
0.05    50    150       100.3         Index
0.10   100    200       200.5         Tie
0.20   200    300       401           Segment
0.50   500    600      1002.5         Segment
0.75   750    850      1503.75        Segment
```

The crossover for this table is around F = 0.10.

With a clustered index the crossover is much higher, because TCARD replaces NCARD in the formula:

```
Clustered index, F = 0.75:
  COST = 0.75 * (5 + 100) + 750
       = 78.75 + 750
       = 828.75

Segment scan:  850
```

Almost equal at F = 0.75. A clustered index stays competitive much longer than a non-clustered one.

## Cost by operator

Concrete examples for each operator with W = 1.

### Equality

```
WHERE SALARY = 12000
  F = 0.00125, RSI_CALLS = 1.25

Non-clustered: 0.00125 * 1005 + 1.25 = 2.5
Segment scan:  100 + 1.25 = 101.25
```

Index wins by 40x.

### Range

```
WHERE SALARY > 24000  (narrow range)
  F = 0.05, RSI_CALLS = 50

Non-clustered: 0.05 * 1005 + 50 = 100.25
Segment scan:  100 + 50 = 150
```

Index wins.

```
WHERE SALARY > 10000  (wide range)
  F = 0.75, RSI_CALLS = 750

Non-clustered: 1503.75
Segment scan:  850
```

Segment scan wins.

### BETWEEN

```
Narrow range:
WHERE SALARY BETWEEN 19000 AND 21000
  F = 0.10   near crossover, near tie

Wide range:
WHERE SALARY BETWEEN 5000 AND 24000
  F = 0.95   segment scan wins easily
```

### IN (list)

```
Short list (3 values):
  F = 3 * (1/800) = 0.00375   index wins easily

Long list (400 values):
  F = 400/800 = 0.5 (capped)  segment scan wins
```

### AND

```
WHERE SALARY > 15000 AND DNO = 50
  F = 0.5 * 0.1 = 0.05   index on DNO wins
```

### OR

```
WHERE SALARY > 20000 OR DNO = 50
  F = 0.25 + 0.1 - 0.025 = 0.325   segment scan wins
```

## Interesting orders

The optimizer does not always pick the cheapest access path in isolation. When a query has an ORDER BY or GROUP BY, some access paths produce tuples already in the required order, eliminating a sort that would otherwise be needed. The paper calls these **interesting orders**.

An ordering is interesting only if it matches a column in the query’s ORDER BY or GROUP BY. An access path that happens to produce tuples in some other order gets no credit for it.

```
SELECT * FROM EMP WHERE DNO = 50 ORDER BY SALARY
  SALARY is an interesting order.

SELECT * FROM EMP WHERE DNO = 50
  No ORDER BY, no interesting order.
  An index on SALARY still produces ordered tuples,
  but the optimizer ignores that. Cost only.
```

### How the optimizer decides

Instead of picking only the cheapest access path, the optimizer keeps two candidates:

```
1. Cheapest unordered path
2. Cheapest path that produces each interesting order
```

Then compares:

```
Cost(ordered path)
  vs
Cost(unordered path) + Cost(sort QCARD tuples)

If ordered < unordered + sort, use the ordered path.
If ordered > unordered + sort, use the unordered path and sort afterwards.
```

### How sort cost is calculated

```
C-sort = cost of reading data via access path
       + cost of sorting (possibly multiple passes)
       + cost of writing result to temporary list

QCARD = NCARD * product of all F values in the query
      = number of tuples the sort must process
```

Sort cost grows with QCARD. Small QCARD fits in memory and the sort is cheap. Large QCARD requires multiple passes to disk and the sort dominates the total cost.

```
F = 0.01 --> QCARD = 10  --> sort trivial
F = 0.75 --> QCARD = 750 --> sort significant
```

The larger the F, the more valuable an access path that eliminates the sort entirely.

### Example: ORDER BY on a different column than WHERE

```
SELECT * FROM EMP WHERE DNO = 50 ORDER BY SALARY
F(DNO) = 0.1, QCARD = 100, W = 1

Access paths:
  A. Segment scan              COST = 200   order: none
  B. Index on DNO              COST = 200.2 order: none
  C. Index on SALARY           COST = 200.5 order: SALARY  <-- interesting
  D. Clustered index SALARY    COST = 110.5 order: SALARY  <-- interesting
```

```
Options with sort:
  A + sort:  200   + C-sort(100)
  B + sort:  200.2 + C-sort(100)

Options without sort:
  C:         200.5
  D:         110.5
```

Option D wins outright, cheapest access path and no sort. If C-sort(100) > 0.5, option C also beats A and B.

### Example: ORDER BY on the same column as WHERE

When the predicate and the ORDER BY share the same indexed column, the index satisfies both at once. F reduces the range of the index scan and the sort disappears.

```
SELECT * FROM EMP WHERE SALARY > 15000 ORDER BY SALARY
F = 0.5, QCARD = 500, W = 1

Non-clustered index on SALARY:
  COST = 0.5 * (5 + 1000) + 500 = 1002.5
  Sort: none

Clustered index on SALARY:
  COST = 0.5 * (5 + 100) + 500 = 552.5
  Sort: none

Segment scan:
  COST = 100 + 500 = 600
  Sort: C-sort(500) still needed
```

Clustered index wins unless C-sort(500) < 47.5, which is unlikely. Non-clustered index wins only if C-sort(500) > 402.5.

## The optimizer’s decision process

```
For each available access path:
  1. Compute F for each predicate
  2. Compute RSI_CALLS = F * NCARD
  3. Apply the appropriate cost formula
  4. Record cost and tuple ordering produced

Keep:
  - Cheapest unordered path
  - Cheapest path for each interesting order

Compare:
  ordered path cost
    vs
  unordered path cost + C-sort(QCARD)

Choose whichever is lower.
```

The cost number itself never appears at runtime. By execution time, the plan is fixed. The RSS follows the chosen path without re-evaluating costs.

## Covering indexes (not in the paper)

The Selinger paper describes indexes that store `(key, tid)` pairs in leaf pages. To retrieve a tuple, the RSS always goes to the data page after finding the tid in the index. This is the model assumed by all cost formulas in chapter 4.

PostgreSQL introduced a refinement not covered in the paper: the covering index, also called an index-only scan. The index leaf pages store additional column values as payload alongside the key and tid. When all columns needed by a query are present in the index, the data page is never fetched.

```
Standard index on SALARY (key + tid only):

  leaf: [12000 -> tid=4] --> fetch data page --> return Clark, DNO=51
        [15000 -> tid=2] --> fetch data page --> return Jones, DNO=50
        [20000 -> tid=5] --> fetch data page --> return Taylor, DNO=52

  Cost: NINDX pages + N data page fetches


Covering index on SALARY INCLUDE (NAME, DNO):

  leaf: [12000 | NAME=Clark  | DNO=51 | tid=4] --> return directly
        [15000 | NAME=Jones  | DNO=50 | tid=2] --> return directly
        [20000 | NAME=Taylor | DNO=52 | tid=5] --> return directly

  Cost: NINDX pages only. Data pages never touched.
```

In the paper’s model, the term `F * NCARD` in the non-clustered index formula represents page fetches on data pages, one per matching tuple in the worst case. A covering index eliminates that term:

```
Standard non-clustered index:
  COST = F * (NINDX + NCARD) + W * RSI_CALLS

Covering index (index-only scan):
  COST = F * NINDX + W * RSI_CALLS
```

In PostgreSQL:

```sql
-- Standard index: fetches data page for NAME and DNO
CREATE INDEX ON emp (salary);

-- Covering index: NAME and DNO stored as payload in leaf pages
-- Data page never fetched if query only needs salary, name, dno
CREATE INDEX ON emp (salary) INCLUDE (name, dno);

-- Query satisfied entirely from index:
SELECT name, dno FROM emp WHERE salary > 15000;
```

The columns in `INCLUDE` are stored only in the leaf pages of the B-tree. They are not part of the search key and do not affect the sort order of the index. Only B-tree, GiST and SP-GiST indexes support the `INCLUDE` clause.

Trade-offs:

```
GAINS:
  Data pages never fetched for covered queries.
  F * NCARD term disappears from cost.
  Largest benefit when F is high and data pages are large.

COSTS:
  Index is larger, leaf pages carry more data.
  Every INSERT and UPDATE on covered columns must update the index.
  No benefit if the query needs a column not in the index,
  the data page must still be fetched, paying full cost.
```

## Notes

- [Index-Only Scans and Covering Indexes](https://www.postgresql.org/docs/current/indexes-index-only-scans.html) — PostgreSQL’s official documentation on covering indexes with the `INCLUDE` clause, how the visibility map allows the planner to skip heap fetches, and the trade-offs between plain indexes and covering indexes. Primary reference for the Covering indexes section above.
