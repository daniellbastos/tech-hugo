---
title: “What fork() Actually Copies (And What It Doesn’t)”
date: 2026-03-28
draft: false
tags: [“python”, “celery”, “linux”, “django”, “postgresql”, “os”, “debugging”]
description: “A configuration flag changed. A boolean. The side effect opened a database connection pool before fork() and took down every Celery worker in production. This is an account of the investigation, the OS internals behind it, and a proposed solution still waiting for staging validation.”
---

Shallow changes can have consequences at the bottom of the ocean. This post is an account of something that happened to me recently, and the story is still open. The services are stable, the revert held, and a pull request is sitting there waiting for the team to review. The proposed solution makes sense on paper. Whether it fully solves the problem in practice is something we’ll only know after thorough testing in staging next week.

Writing this now, before it ships, feels right. It captures the uncertainty that is part of the work.

The investigation pushed me to dive deep into operating system concepts I thought I already understood. And it started with an error I had never seen behave quite like this.

Every Celery worker in production started timing out on database access. Not one or two. All of them, simultaneously, on every task.

`PoolTimeout: couldn't get a connection after 20.00 sec`

I had seen database errors before. Connection resets, query timeouts, pool exhaustion under load. This was different. The workers weren’t failing to reach the database. They were failing before they even tried.

-----

## The change that broke everything

A few days earlier, a small configuration flag had changed. A boolean, really. We needed Django signal listeners to register inside Celery workers, and the existing setup skipped that registration unless a specific flag was set to `true`.

We set it to `true`.

It worked. The signals fired. The feature shipped.

The QA was quick. The change felt contained: flip a flag, verify the signals are registering in Celery, done. And the signals were registering. That part was correct. Nobody was looking for a second-order effect buried in `AppConfig.ready()`.

Then, silently, something else started running. A few `AppConfig.ready()` methods that were now active made ORM queries at startup, creating periodic task schedules, checking crontab entries. Routine stuff. Nothing that looked dangerous.

But those queries opened the database connection pool. In the master process. Before `fork()`.

Celery’s default concurrency model is prefork. It doesn’t use threads or async workers. It uses `fork()`, the POSIX system call, to create a pool of worker processes. That detail is easy to forget when you’re looking at application code. It matters enormously when you’re opening database connections at startup.

That was the problem.

-----

## What fork() actually does at the OS level

Most engineers know the surface: `fork()` creates a child process that is a copy of the parent. But the word “copy” hides a precise distinction the kernel makes between two very different kinds of resources.

**Memory is copied, lazily, via copy-on-write.**

When `fork()` runs, the kernel doesn’t duplicate RAM immediately. Instead, it marks both the parent’s and child’s page tables as read-only, pointing at the same physical pages. The actual copy only happens when either process writes to a page: the kernel catches the page fault, allocates a new physical page, copies the content, and updates the page table. Until then, both processes share physical memory without knowing it.

This is efficient. It’s also why Python objects, including the connection pool’s internal state, appear intact in the child. The child gets its own copy of `pool._pool`, `pool._lock`, `pool._sched`. The bytes are right. The structure is right.

But some of those bytes point to kernel resources. And kernel resources are not copied.

**File descriptors are shared.**

A TCP socket is not a Python object. It’s a kernel object, a `struct file` with a reference count, backed by a `struct sock` with send and receive buffers, TCP state, sequence numbers. When `fork()` runs, the kernel calls `dup_fd()` on the parent’s file descriptor table: each open fd gets duplicated into the child, and the reference count on the underlying `struct file` is incremented.

Both processes now hold `fd=12`. Both point at the same kernel socket object. One TCP stream, two readers and two writers, with no coordination between them.

```
Parent  fd=12 ──────┐
                    ├──► TCP socket (kernel) ──► PostgreSQL
Child   fd=12 ──────┘
```

PostgreSQL’s wire protocol is stateful. It expects sequential request-response pairs on a single stream. Two processes interleaving bytes on the same connection don’t produce two independent conversations. They produce garbage.

-----

## Three things break, in three different ways

The connection pool, psycopg3’s `ConnectionPool`, holds three kinds of resources. Each breaks differently after `fork()`.

**TCP sockets** are shared at the kernel level, as described. Any attempt to use them from two processes simultaneously corrupts the protocol stream. In practice, the children never reached this point.

**`threading.Lock`** is built on `pthread_mutex_t`, which internally relies on futex, a Linux kernel mechanism that uses the *physical memory address* of an integer as the key for its wait queue. After `fork()`, copy-on-write can remap the child’s page to a new physical address when a write occurs. The child’s futex key drifts from the parent’s. A `futex_wake` from one process wakes nobody in the other. POSIX is explicit about this: the behavior of a mutex after `fork()` is undefined unless it was created with the process-shared attribute. Python’s `Lock` doesn’t use that attribute.

**Background threads** simply don’t exist in the child. `fork()` only duplicates the calling thread. The pool’s internal scheduler, responsible for maintaining minimum connections, running health checks, notifying waiters, is copied as a Python object but has no corresponding OS thread. Its TID doesn’t exist. Any code path that depends on it waiting or signaling will block forever.

The children inherited a pool that looked complete but was inert. They called `pool.getconn()`, tried to acquire the broken lock, waited 20 seconds for a notify that would never come, and timed out.

-----

## Why it worked before

Before the flag changed, `AppConfig.ready()` skipped the periodic task registration. The ORM was never called at startup. No queries meant no pool. No pool meant nothing to inherit.

Each child started with a clean state. On first database access, it lazily created its own pool: its own sockets, its own lock, its own background thread. Fully independent.

```
Before:   fork() → clean child → first query → fresh pool (correct)
After:    pool opens → fork() → broken child → PoolTimeout
```

-----

## How the incident was handled

When the workers started failing, the team jumped on a call with SRE to check the connection pool. The pool metrics looked clean. No exhaustion, no errors at the database level. That was the first confusing signal: everything looked fine on the infrastructure side, but nothing was working on the application side.

With no obvious root cause visible from the outside, the decision was to revert the last release. It worked. Workers recovered. The immediate fire was out.

That’s when I started digging. The revert gave us stability, but not understanding. And shipping the same change again without knowing what had actually happened wasn’t an option.

I spent the rest of the day tracing the chain: the flag, `AppConfig.ready()`, the ORM queries, the pool, and finally `fork()`. By end of day the pull request was ready.

-----

## The proposed solution

Two Celery signal hooks.

`worker_before_create_process` fires in the parent, after `ready()`, before each `fork()`. It closes all database connections across every alias and destroys the connection pools. By the time `fork()` runs, there are no open TCP sockets, no locks, no background threads to inherit.

`worker_process_init` fires in each child after `fork()` as a second layer. Defense-in-depth, in case anything was missed.

After both hooks run, each child is empty. The first ORM query creates a fresh pool that belongs entirely to that process.

```
ready() runs → pool opens → worker_before_create_process → pool destroyed
             → fork() → worker_process_init → first query → fresh pool
```

The principle is clear: never hold open connections before `fork()`, or explicitly close and destroy them before the fork happens. The same applies to any connection pool built on TCP: psycopg3, SQLAlchemy, redis-py. The technology doesn’t matter. The kernel’s behavior does.

The pull request is open. The team will review it, test it exhaustively in staging, and verify it actually resolves the problem before anything goes to production. The revert is holding. There is no urgency to ship something that hasn’t been properly validated.

-----

I’ve thought about what made this hard to see. The code change that triggered it was correct. The signals needed to register. The flag made sense. The ORM queries in `ready()` were harmless in isolation.

The QA caught what it was designed to catch. It just wasn’t designed to catch this. A developer verified the signals were registering. They were. The test was complete, and it was wrong. That’s not a failure of attention. It’s a gap in what we knew to look for.

The invisible part was the interaction between Django’s startup sequence and Celery’s process model. Two systems, each well-understood on its own, doing something unexpected at the boundary.

The real learning here isn’t the fix. It’s understanding why the pool broke at all. What `fork()` actually copies. What it shares. Why a lock that looks intact can deadlock a child process. Why a thread that exists as a Python object can be completely absent from the OS. Those are the things worth carrying forward, regardless of how the pull request ends up.

The diagrams below show the full picture: the state of the pool and the workers before and after the bug was introduced, and what the proposed solution restores.

-----

## Diagrams: the state before and after

### Before the flag change: clean fork, each child builds its own pool

```
MASTER PROCESS
==============

  AppConfig.ready()
    - signal listeners: SKIPPED
    - ORM queries:      SKIPPED
    - pool state:       never opened

  +----------------------------------+
  |  pool._pool  = []  (empty)       |
  |  pool._lock  = None              |
  |  pool._sched = None              |
  |  open TCP fds: none              |
  +----------------------------------+
              |
           fork() x4
              |
    +---------+---------+---------+
    |         |         |         |
    v         v         v         v
 Worker-1  Worker-2  Worker-3  Worker-4
 (clean)   (clean)   (clean)   (clean)
    |         |         |         |
    v         v         v         v
 1st ORM   1st ORM   1st ORM   1st ORM
 query     query     query     query
    |         |         |         |
    v         v         v         v
 owns its  owns its  owns its  owns its
 own pool  own pool  own pool  own pool
 own fds   own fds   own fds   own fds
 own lock  own lock  own lock  own lock
 own thread own thread own thread own thread

 Each worker is fully independent. No sharing. Works correctly.
```

-----

### After the flag change: pool opens in master, fork() distributes corruption

```
MASTER PROCESS
==============

  AppConfig.ready()
    - signal listeners: REGISTERED
    - ORM queries:      RUN  <-- pool forced open here
    - pool state:       open, 4 connections

  +------------------------------------------+
  |  pool._pool  = [conn-A, conn-B,           |
  |                 conn-C, conn-D]            |
  |  pool._lock  = Lock()  (initialized)      |
  |  pool._sched = Thread  (alive, TID=1002)  |
  |  fd=12, fd=13, fd=14, fd=15 open          |
  +------------------------------------------+
              |
           fork() x4   <-- copies memory, shares kernel fds
              |
    +---------+---------+---------+---------+
    |         |         |         |         |
    v         v         v         v         v
  Master   Worker-1  Worker-2  Worker-3  Worker-4

  All 4 workers inherit:

  pool._pool  = [conn-A, conn-B, conn-C, conn-D]  (CoW copy)
  pool._lock  = Lock() -- bytes copied, futex key broken
  pool._sched = Thread -- object exists, OS thread does not
  fd=12..15   = pointing at SAME kernel TCP sockets

              |
              |  task arrives, worker calls pool.getconn()
              v

  Worker-1: acquire pool._lock
    --> lock state undefined (futex broken after CoW)
    --> OR: lock acquired, waits for _sched.notify()
    --> _sched thread doesn't exist in this process
    --> nobody calls _cond.notify()
    --> wait 20 seconds
    --> PoolTimeout

  Same result in Worker-2, Worker-3, Worker-4.
  All workers fail. No tasks execute.


  Meanwhile, if any worker DID reach a connection:

  Worker-1  fd=12 ──┐
                    ├──► SAME TCP socket ──► PostgreSQL
  Worker-2  fd=12 ──┘

  Both writing on the same stream.
  PostgreSQL receives interleaved bytes from two workers.
  Wire protocol corrupted.
```

-----

### After the proposed solution: pool destroyed before fork(), each child starts clean

```
MASTER PROCESS
==============

  AppConfig.ready()
    - signal listeners: REGISTERED  (intended behavior preserved)
    - ORM queries:      RUN          (pool opens here)
    - pool state:       open

          |
          v

  worker_before_create_process()   <-- fires before each fork()
    - close all DB connections
    - destroy pool (close_pool())
    - join pool._sched thread

  +----------------------------------+
  |  pool._pool  = []  (destroyed)   |
  |  pool._lock  = None              |
  |  pool._sched = None              |
  |  open TCP fds: none              |
  +----------------------------------+
              |
           fork() x4   <-- nothing harmful to inherit
              |
    +---------+---------+---------+---------+
    |         |         |         |         |
    v         v         v         v         v
  Master   Worker-1  Worker-2  Worker-3  Worker-4

  Each worker runs worker_process_init()   <-- defense-in-depth
    - closes any remaining inherited state

              |
              v

  Each worker: 1st ORM query --> creates its own fresh pool
               own TCP fds, own lock, own background thread
               fully isolated

  Signal listeners still registered. Feature still works.
  Workers fully independent. No PoolTimeout.
```
