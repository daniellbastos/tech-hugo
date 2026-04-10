---
title: "Access Path Selection in a Relational Database Management System - Notes Through Chapter 3"
date: 2026-04-10
draft: false
description: "This post is a study dump. I've been reading 'Access Path Selection in a Relational Database Management System' (Selinger et al., 1979) and stopped at chapter 3 to consolidate what I learned."
tags: ["database", "system r", "storage", "relational database", "management system", "postgresql"]
---


> This post is a study dump. I've been reading [Access Path Selection in a Relational Database Management System (Selinger et al., 1979)](https://courses.cs.duke.edu/compsci516/cps216/spring03/papers/selinger-etal-1979.pdf) and stopped at chapter 3 to consolidate what I learned. I used available internet resource and tools to go deeper on the examples and make the concepts more concrete.

## What the paper covers

The paper describes how System R, an experimental relational database built at IBM in the 1970s, chooses access paths to execute SQL queries. You write SQL declaratively, without specifying how data is accessed or in what order joins happen. The optimizer decides both, minimizing total access cost.

It covers single-relation access paths and their cost formulas, join methods (nested loops and merging scans), join order selection, and nested queries. The conclusion reports that the optimizer selects the true optimal path in a large majority of cases, even when cost estimates are not accurate in absolute terms.

I've read through chapter 3, which covers the processing pipeline for SQL statements and the physical storage model underneath the optimizer.

## How data is physically stored

The RSS (Research Storage System) organizes data in 4KB pages. Pages are grouped into segments. A segment can contain multiple tables, and tuples from different tables can live on the same page. Each tuple carries a tag identifying which table it belongs to.

### Base table

```
EMP
+----+--------+-----+--------+
| ID | NAME   | DNO | SALARY |
+----+--------+-----+--------+
|  1 | Smith  |  50 |   8500 |
|  2 | Jones  |  50 |  15000 |
|  3 | Doe    |  51 |   9500 |
|  4 | Clark  |  51 |  12000 |
|  5 | Taylor |  52 |  20000 |
|  6 | Brown  |  52 |   6000 |
+----+--------+-----+--------+
```

### Physical storage (insertion order)

```
SEGMENT
+----------------------+----------------------+
|       PAGE 1         |       PAGE 2         |
| [EMP tid=1] Smith    | [EMP tid=4] Clark    |
|   DNO=50  SAL=8500   |   DNO=51  SAL=12000  |
| [EMP tid=2] Jones    | [EMP tid=5] Taylor   |
|   DNO=50  SAL=15000  |   DNO=52  SAL=20000  |
| [EMP tid=3] Doe      | [EMP tid=6] Brown    |
|   DNO=51  SAL=9500   |   DNO=52  SAL=6000   |
+----------------------+----------------------+
```

## Scan types

Access happens through scans. Two types:

- **Segment scan**: reads all non-empty pages in the segment. Each page is touched exactly once.
- **Index scan**: traverses a separate B-tree whose leaves contain `(key, tid)` pairs. Leaves are linked, allowing range scans without returning to upper tree levels.

### Segment scan

```
SELECT * FROM EMP WHERE SALARY > 10000

PAGE 1 --> Smith(8500)   DISCARD
       --> Jones(15000)  RETURN
       --> Doe(9500)     DISCARD

PAGE 2 --> Clark(12000)  RETURN
       --> Taylor(20000) RETURN
       --> Brown(6000)   DISCARD

2 page fetches. Every page read exactly once.
```

### B-tree structure (index scan)

```
INDEX (SALARY)

     [leaf 1]                [leaf 2]
+------------------+    +------------------+
| 6000  -> tid=6   |    | 12000 -> tid=4   |
| 8500  -> tid=1   |    | 15000 -> tid=2   |
| 9500  -> tid=3   |    | 20000 -> tid=5   |
+------------------+    +------------------+
        |                        |
        +-----> linked <---------+
```

The index itself does not return data. It returns tids. For each tid, the RSS fetches the tuple from the data page. The scan only visits entries that satisfy the predicate, unlike the segment scan, it never touches tuples that fall outside the index range.

```
SELECT * FROM EMP WHERE SALARY > 10000

INDEX: navigate B-tree to SALARY > 10000, traverse leaves:

  leaf 2: 12000 -> tid=4 --> fetch tuple from data page --> RETURN
          15000 -> tid=2 --> fetch tuple from data page --> RETURN
          20000 -> tid=5 --> fetch tuple from data page --> RETURN

  leaf 1: not visited (all values <= 10000)

3 tuples returned. Only tuples matching the predicate were fetched.
```

## Clustered vs Non-clustered index

The difference is physical: in a clustered index, data page tuples are ordered by the same key as the index. In a non-clustered index, they are not. This determines whether the RSS reads data pages sequentially or jumps between random pages.

### Non-clustered: the random access problem

```
SELECT * FROM EMP WHERE SALARY > 10000

INDEX ordered by SALARY    DATA PAGES (physical order)
-----------------------    ---------------------------
12000 -> tid=4 -> PAGE 2   PAGE 1: Smith(8500), Jones(15000)
15000 -> tid=2 -> PAGE 1   PAGE 2: Clark(12000), Taylor(20000)
20000 -> tid=5 -> PAGE 2

tid=4 -> PAGE 2  (fetch)
tid=2 -> PAGE 1  (fetch) <-- jumped back
tid=5 -> PAGE 2  (fetch) <-- jumped back again

3 tuples returned, 3 page fetches alternating between pages.
```

### Clustered: sequential access

```
SEGMENT (data physically ordered by SALARY)
+----------------------+----------------------+
|       PAGE 1         |       PAGE 2         |
| [tid=6] Brown  6000  | [tid=4] Clark  12000 |
| [tid=1] Smith  8500  | [tid=2] Jones  15000 |
| [tid=3] Doe    9500  | [tid=5] Taylor 20000 |
+----------------------+----------------------+

SELECT * FROM EMP WHERE SALARY > 10000

INDEX: navigates to SALARY > 10000
  12000 -> tid=4 -> PAGE 2  (fetch)
  15000 -> tid=2 -> PAGE 2  (already in buffer)
  20000 -> tid=5 -> PAGE 2  (already in buffer)

3 tuples returned, 1 page fetch.
```

## The real cost: page fetch

A disk page fetch is orders of magnitude slower than reading from the buffer. That gap is what the optimizer is actually managing.

A non-clustered index with low selectivity generates random page fetches. Each tid points somewhere different. The disk arm moves. With high selectivity that's fine - few tids, few pages. With low selectivity, the segment scan wins: it reads pages in order, and sequential reads on magnetic disk are a different beast entirely.

## Tuple size and tuples per page

### Schema impact on page count

```
SIMPLE VERSION
+--------+---------+
| FIELD  |  SIZE   |
+--------+---------+
| ID     | 4 bytes |
| NAME   | 20 bytes|
| DNO    | 4 bytes |
| SALARY | 4 bytes |
+--------+---------+
| TOTAL  | 32 bytes|
+--------+---------+
tuples per page:    ~121
pages (1M rows):    ~8,300

HEAVY VERSION
+---------+-----------+
| FIELD   |   SIZE    |
+---------+-----------+
| ID      |   4 bytes |
| NAME    | 100 bytes |
| NOTES   | 500 bytes |
| PICTURE | 2000 bytes|
+---------+-----------+
| TOTAL   | 2604 bytes|
+---------+-----------+
tuples per page:    ~1
pages (1M rows):    ~1,000,000
```

The same query on tables with different schemas requires 120x more page fetches with no difference in the data returned.

## VARCHAR: real variation by content

VARCHAR stores only the actual content plus a 1-4 byte header.

```
FIELD: NOTES varchar(500)

SHORT CONTENT             FULL CONTENT
"" -> 1 byte              "long text..." -> 402 bytes

SHORT TUPLE               FULL TUPLE
ID    =   4 bytes         ID    =   4 bytes
NAME  =   3 bytes         NAME  =  20 bytes
NOTES =   1 byte          NOTES = 402 bytes
--------------            ---------------
TOTAL =   8 bytes         TOTAL = 426 bytes

tuples/page: ~487          tuples/page: ~9
```

Same table, same schema, but the real behavior depends on what was inserted. The optimizer works with catalog averages — it does not know the actual size of each row.

## Columns outside the SELECT still affect the query

The entire tuple lives on the page. A page fetch brings the whole page into the buffer, regardless of how many columns were requested. The RSS locates the full tuple and projects only the requested fields afterward.

```
SELECT id, salary FROM emp WHERE dno = 50

TUPLE ON DISK (428 bytes)
+----+--------------------+--------+----------+
| ID |        NAME        | SALARY |  NOTES   |
| 4B |        20B         |   4B   |  400B    |
+----+--------------------+--------+----------+

DISK -> buffer (4KB) -> tuple (428B) -> projection (8B) -> you
                               ^
                    NAME and NOTES enter the buffer
                    and are discarded.
                    The transport cost has already been paid.
```

## Indexes: write maintenance cost

Each index is a separate structure kept consistent on every write.

```
WRITE without index:
  INSERT -> writes to a data page
  1 write operation

WRITE with 3 indexes:
  INSERT -> writes to a data page
          -> updates B-tree of index 1
          -> updates B-tree of index 2
          -> updates B-tree of index 3
  4 write operations
```

UPDATE in PostgreSQL creates a new tuple version via MVCC (Multiversion Concurrency Control), marks the old one as a dead tuple, and updates indexes on modified columns.

## Dead tuples and VACUUM

```
PAGE after many UPDATEs on SALARY without VACUUM

+----------------------------------+
| [alive] id=1 salary=12000        |
| [DEAD]  id=1 salary=8500         |
| [DEAD]  id=1 salary=10000        |
| [alive] id=2 salary=9500         |
| [DEAD]  id=2 salary=8000         |
+----------------------------------+

Page with capacity for 6 tuples.
3 alive, 3 dead.
Each page fetch uses only half the buffer.
```

Dead tuples accumulated without VACUUM waste space on pages. The buffer loads pages full of garbage, reducing how many live tuples reach the buffer per page fetch.

## Index on a boolean column

Boolean has two possible values. With uniform distribution, `WHERE active = true` returns ~50% of rows.

```
Non-clustered index on boolean:
  500k tids scattered randomly
  -> ~500k random page fetches

Segment scan:
  reads all pages sequentially
  -> ~8k sequential page fetches
```

The optimizer will prefer the segment scan. The index exists but is never used, and the write maintenance cost is still paid on every INSERT and UPDATE.

The exception is asymmetric distribution where you always query the rare value, or a partial index:

```sql
-- Index that only indexes deleted rows
-- Small, selective, useful
CREATE INDEX ON emp (id) WHERE deleted = true;
```

## Strategies that actually move the needle

The thing with the most leverage and the least cost is tuple size.
Separating wide columns rarely accessed into a separate table reduces
page fetches across all queries on the main table. No new index needed.
The only cost is discipline at schema design time.

Covering indexes go further: an index that includes all columns a query
needs eliminates access to data pages entirely. The RSS satisfies the
query using only index pages. The trade-off is real, the index is
larger, writes get slower.

VACUUM matters more than most people assume. Dead tuples accumulate
silently. Without regular vacuuming, pages fill with garbage the buffer
still has to load. The buffer pool shrinks in practice without shrinking
in size.

Partitioning divides the table physically. Queries with a predicate on
the partition column eliminate entire partitions before scanning. The
gains can be large. So can the operational cost: migrations get harder,
maintenance gets more complex.

Things that don't move the needle in PostgreSQL: column order, CHAR vs
VARCHAR, indexes on low-selectivity columns.

Before creating an index: how many pages will this index eliminate, and does that gain cover the write maintenance cost?

## Notes

- [Database Page Layout](https://www.postgresql.org/docs/current/storage-page-layout.html) — PostgreSQL's official documentation on how pages are structured internally: the 24-byte header, the slot directory with `(offset, length)` pairs for each tuple, and how tuples grow backwards from the end of the page. This is the direct reference for everything described in the physical storage section above.

- [Introduction to PostgreSQL physical storage](https://rachbelaid.com/introduction-to-postgres-physical-storage/) — A practical walkthrough of the heap file structure, CTID, the slot array, and TOAST, with diagrams that make the page layout concrete. Complements the official documentation with examples you can run.
