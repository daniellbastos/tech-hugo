---
title: "A Study Log: SQLite Internals"
date: 2026-08-08
draft: true
description: "This is a raw dump of my SQLite internals study log: source-code-first, Socratic Q&A, every claim traced to a specific file and line, with PostgreSQL used as a comparative reference throughout. Posting it as-is, unedited."
tags: ["database", "sqlite", "internals", "wal", "study-log"]
---

## How This Works

- **Method:** Socratic. Small questions, one concept at a time, grounded strictly in the official SQLite source code (not general knowledge/guessing).
- Every claim should be traceable to a real file/line in the source tree below.
- **Diagrams:** plain text / ASCII only.
- Each session: append new Q&A to this file, don't rewrite history.
- **To resume in a new conversation:** upload this file and say *"continue the SQLite study log, same method as described in the file."*

## References

- **Canonical source** (Fossil, authoritative): https://sqlite.org/src
- **Official read-only Git mirror** (easier to browse): https://github.com/sqlite/sqlite
- **Local clone used in this study:** `/home/claude/sqlite`
  cloned via:
  ```
  git clone --depth 1 https://github.com/sqlite/sqlite.git
  ```
  Check-in used (`manifest.uuid`): `8b3da5d6cea2e3b31784f5e8f05c4801a3d881039aa26ecadf3a50b4454a3de6`

**Key source files we'll likely walk through:**

| File | Size | Role |
|---|---|---|
| `src/btree.c` | 11,633 lines | B-tree storage engine |
| `src/pager.c` | 7,888 lines | Page cache / rollback journal / recovery |
| `src/wal.c` | 4,645 lines | Write-ahead log mode |
| `src/vdbe.c` | 9,487 lines | Virtual machine that executes bytecode |
| `src/vdbeaux.c` | 5,812 lines | VDBE support routines |
| `src/where.c` | 7,894 lines | Query planner / WHERE clause optimization |
| `src/select.c` | 9,028 lines | SELECT statement compilation |
| `src/os_unix.c` | 8,582 lines | OS/VFS layer (POSIX); file locking lives here |
| `src/os.h` | — | Lock state constants (`NO_LOCK`..`EXCLUSIVE_LOCK`) + semantics |
| `src/main.c` | — | Top-level programmer interface (`sqlite3_open`, etc.) |

> **Note:** This sandbox environment resets between conversations. The git clone at `/home/claude/sqlite` will **not** persist to a new session. Re-clone with the command above at the start of a new conversation before continuing the code walkthrough.

**Context:** Daniel is a software engineer (Python/Django/Postgres/Celery/K8s background) doing a deep-dive into SQLite internals as part of a broader Linux/Unix + database internals self-study track. Comparisons to PostgreSQL internals are useful and welcome throughout.

---

## Q&A Log

### Q1: How does the SQLite lib handle multiple readers?

SQLite has two different concurrency models depending on journal mode.

#### 1) Rollback-journal mode — coarse-grained whole-file locks

Source: `src/os.h:98-102`

```
NO_LOCK(0) -> SHARED_LOCK(1) -> RESERVED_LOCK(2) -> PENDING_LOCK(3) -> EXCLUSIVE_LOCK(4)
```

- **SHARED** — any number of processes may hold this at once (readers coexist)
- **RESERVED** — only one process may hold it (declares write intent); other processes may still take/hold SHARED locks (existing readers unaffected)
- **PENDING** — blocks any *new* shared locks from starting; existing readers are allowed to finish
- **EXCLUSIVE** — nobody else allowed; needed to actually flush the journal and commit

Writer lock escalation path: `SHARED → RESERVED → PENDING → EXCLUSIVE`. It escalates gradually so it doesn't evict readers immediately — it just closes the door to *new* readers (PENDING) and waits for existing readers to drain before going EXCLUSIVE.

```
Reader1 --SHARED---------------------------> (reads happily)
Reader2 --SHARED----->(done)
Writer  --SHARED-RESERVED-PENDING--wait for readers--EXCLUSIVE-->commit-->SHARED
                                    (no NEW readers admitted here)
```

Multiple readers: trivially fine (SHARED is non-exclusive). Limitation: a writer's commit window still can't overlap with readers — coarse, whole-file locking.

#### 2) WAL mode (default since 3.7) — MVCC-like snapshotting, readers never block

Source: `src/wal.c` header comment (~line 99–115):

> "To start a read transaction, the reader records the index of the last valid frame in the WAL... the reader uses this recorded mxFrame value for all subsequent read operations... This technique allows multiple concurrent readers to view different versions of the database content simultaneously."

**Mechanics:** writes are appended as "frames" to a separate `-wal` file instead of touching the main `.db` file. A reader, at transaction start, just records "WAL valid through frame N" (its `mxFrame`). Every page read is serviced from the WAL (≤N) if present there, else falls back to the base `.db` file. Conceptually like a Postgres MVCC snapshot, but:

- page-granular, not tuple-granular
- log-based (frames in a WAL file), not heap-based (tuple versions)

```
main.db  (base pages)
   ^
   | fallback if page not yet touched in WAL
   |
 WAL file: [frame1][frame2][frame3]...[frame N]...[frame N+k]
                                    ^              ^
                              Reader A's        Writer keeps
                              mxFrame=N          appending here
                              (frozen snapshot)
```

**Result:** readers never block writers, writer never blocks readers. Exception: still only **one writer at a time** (no MVCC for writes, unlike Postgres).

**Open question posed back (for next session):** Given deep Postgres MVCC knowledge — where does the `-wal` file's *role* differ most from Postgres's WAL? (Hint: think about what Postgres's WAL is *for* vs. what SQLite's WAL actually *stores*.)

*(This open question is still pending — not yet answered as of Q2 below.)*

---

### Q2: How does the OS-level process handle multiple readers and the writer? How does "the main process" handle it?

**Key insight up front: there is no main process.** SQLite is a linked library, not a server. Every process that opens the same `.db` file is a peer. Coordination happens entirely through the **kernel's own advisory-lock table**, not through any SQLite-side arbiter.

#### The mechanism: byte-range locks on fake offsets

POSIX doesn't give a "lock state" API — only byte-range locks on a file (`fcntl(fd, F_SETLK, struct flock*)`). SQLite reserves specific byte offsets in the `.db` file (never used for real page data) purely as lock semaphores.

Source: `src/os.h:160-166`

```c
#define PENDING_BYTE      0x40000000        /* byte 1,073,741,824 (1GiB) */
#define RESERVED_BYTE     (PENDING_BYTE+1)
#define SHARED_FIRST       (PENDING_BYTE+2)
#define SHARED_SIZE        510
```

```
File byte offset:
        0 ......................... 0x40000000  0x40000001  0x40000002 .. +510
        |   actual page data          |PENDING|  |RESERVED|  |---- SHARED range ----|
        |   (pages, up to ~1GB)        (1 byte)    (1 byte)      (510 bytes)
```

Why 1 GiB: chosen high on purpose so normal-size databases never collide with a real page there, avoiding wasted allocation. Comment in `os.h` warns that changing `PENDING_BYTE` creates a subtly incompatible file format; `PENDING_BYTE_PAGE` in `src/btreeInt.h` computes which page number this offset would correspond to, for the rare >1GB case where SQLite must treat that page specially.

#### What each lock state does at the syscall level (`unixLock`, `src/os_unix.c` ~line 1960)

**SHARED_LOCK (reader):**
```c
lock.l_type  = F_RDLCK;
lock.l_start = PENDING_BYTE;   // 1) briefly grab PENDING as a read-lock
fcntl(fd, F_SETLK, &lock);     //    (guards against racing a writer's PENDING grab)
...
lock.l_start = SHARED_FIRST;   // 2) real read-lock over the 510-byte SHARED range
lock.l_len   = SHARED_SIZE;
fcntl(fd, F_SETLK, &lock);
...
lock.l_type  = F_UNLCK;        // 3) release the temporary PENDING lock
lock.l_start = PENDING_BYTE;
fcntl(fd, F_SETLK, &lock);
```
Multiple processes can hold `F_RDLCK` on the same bytes simultaneously — that's a core POSIX guarantee, and it's the entire answer for "how do readers coexist" at the OS level: the kernel's advisory lock table just permits N shared read-locks on the same byte range.

**RESERVED_LOCK (writer declaring intent):**
```c
lock.l_type  = F_WRLCK;
lock.l_start = RESERVED_BYTE;   // just 1 byte, exclusive write-lock
lock.l_len   = 1;
fcntl(fd, F_SETLK, &lock);
```
Only one `F_WRLCK` can exist on a given byte at a time — "only one writer" is enforced purely by kernel semantics, no cross-process bookkeeping needed.

**EXCLUSIVE_LOCK (about to commit):**
```c
lock.l_type  = F_WRLCK;
lock.l_start = SHARED_FIRST;    // write-lock the WHOLE 510-byte shared range
lock.l_len   = SHARED_SIZE;
fcntl(fd, F_SETLK, &lock);      // fails (SQLITE_BUSY) if any reader still holds F_RDLCK there
```
Elegant part: EXCLUSIVE is a write-lock over the *exact same byte range* readers use for their `F_RDLCK`. The kernel itself refuses to grant it while any reader is present — SQLite doesn't poll or track reader counts across processes; it just asks the kernel and gets `SQLITE_BUSY` back if it can't have it.

#### The same-process gotcha: `unixInodeInfo`

POSIX advisory locks (`fcntl`) are associated with the **process**, not the file descriptor. If two threads in the *same* process each `open()` the db file separately, closing *either* fd silently drops the lock for *both* — a well-known POSIX wart Postgres never has to deal with (single multiplexed server, not N independent client processes).

To work around this, `src/os_unix.c` keeps its own in-process bookkeeping struct, `unixInodeInfo` (keyed by device+inode), layered on top of the kernel locks. It tracks how many of SQLite's own connections *in this process* currently hold a SHARED lock (`pInode->nShared`), so the kernel lock is only actually requested/released at the boundaries where the process's aggregate need changes — not once per connection.

```
                  KERNEL LOCK TABLE (per inode)
                  ┌─────────────────────────────┐
                  │ byte 0x40000000: PENDING     │◄── fcntl() from any process
                  │ byte 0x40000001: RESERVED    │
                  │ bytes 0x40000002-...: SHARED │
                  └─────────────────────────────┘
                        ▲              ▲
                 fcntl()│              │fcntl()
                        │              │
        ┌───────────────┴───┐   ┌──────┴─────────────┐
        │ Process A           │   │ Process B           │
        │ unixInodeInfo        │   │ unixInodeInfo        │
        │  nShared=2 (2 conns) │   │  nShared=1           │
        │ conn1 conn2          │   │ conn1                │
        └──────────────────────┘   └──────────────────────┘
```

**Bottom line:** no daemon, no shared memory, no IPC beyond what `fcntl()` already provides. Coordination is entirely the kernel's advisory-lock table on the shared file, using byte offsets as a hand-rolled semaphore protocol.

**Caveat flagged:** this mechanism is notoriously unreliable over NFS (especially pre-NFSv4 / `lockd` issues) — SQLite's own docs warn against network filesystems for exactly this reason.

**Still pending:** the WAL-mode OS mechanics (adds a `-shm` file, switches from `fcntl` byte-ranges to a different scheme) and the original open question about Postgres-vs-SQLite WAL *role* differences.

---

### Q3: How does `fcntl` and related OS things work, and why does it match SQLite's philosophy so well? (asked from a non-C/non-Unix background)

#### The kernel boundary

User-space code never touches hardware or other processes directly — everything crosses through the kernel via **syscalls**, a fixed menu of operations (`open`, `read`, `write`, `close`, `fcntl`, ...).

```
 Process A (SQLite)          Process B (SQLite)
 ┌─────────────┐             ┌─────────────┐
 │ user space   │             │ user space   │
 │  C library    │             │  C library    │
 └──────┬───────┘             └──────┬───────┘
        │ syscall (fcntl, open...)   │ syscall
════════▼═════════════ kernel boundary ═════════▼════════
 ┌───────────────────────────────────────────────────┐
 │                    KERNEL                          │
 │  - owns the filesystem                              │
 │  - owns the one lock table per inode                │
 └───────────────────────────────────────────────────┘
```

Two unrelated processes share no memory, no network connection — only the fact that both talk to the same kernel about the same file. That's the whole trick: the kernel is a rendezvous point that already exists for free on every Unix system.

#### File descriptor vs. inode

- **inode** — the kernel's internal identity for the real file on disk (data, permissions, size). One per file regardless of how many processes have it open.
- **file descriptor (fd)** — a small integer, private to *your process*, pointing at an "open file description" in the kernel, which points at the inode.

```
Process A: fd 3 ──┐
Process B: fd 7 ──┼──► open file description(s) ──► inode 88213 (the .db file on disk)
Process A: fd 5 ──┘        (kernel-owned)
```

POSIX record locks (what SQLite uses) are associated with the **(process, inode)** pair, not the fd — that's the earlier "gotcha": closing *any* fd to that inode in a process drops *all* of that process's locks on it. Real wart, but also why it works as a cross-process signal: the kernel tracks "which processes claim what on this inode," independent of fd count.

#### What `fcntl()` actually is

`fcntl` = "file control" — a general-purpose, multiplexed syscall. One entry point, many unrelated jobs selected by a command argument (set fd non-blocking, duplicate it, etc.). SQLite uses the command `F_SETLK`: set an advisory record lock.

```c
struct flock lock;
lock.l_type   = F_RDLCK;      // or F_WRLCK, or F_UNLCK
lock.l_whence = SEEK_SET;     // offset is from start of file
lock.l_start  = SHARED_FIRST; // byte offset to lock
lock.l_len    = SHARED_SIZE;  // how many bytes

fcntl(fd, F_SETLK, &lock);    // ask the kernel; non-blocking, errors if it can't grant it
```

Four fields describe which byte range + what kind of lock. The kernel keeps a table, per inode, of who holds what over which ranges, enforcing: many readers (`F_RDLCK`) can overlap; a writer (`F_WRLCK`) can't overlap with anything else on that range. Same intuition as Postgres row-locks — applied to arbitrary byte ranges of a file instead of tuples.

#### The crucial word: "advisory"

**Advisory locks are not enforced against processes that ignore them.** The kernel doesn't prevent writes to the file — a process that just calls `write()` without ever calling `fcntl(F_SETLK)` first will succeed regardless. It's a cooperative protocol (like a talking-stick convention), not a mandatory OS-enforced lock on a door.

This is why it only works because **every SQLite connection, in every process, runs the same `os_unix.c` code and obeys the same protocol.** A non-SQLite program writing directly to the file, ignoring locks, breaks everything. The contract: "everyone touching this file agrees to ask the kernel first." SQLite is only safe against other SQLite processes.

#### Why this fits SQLite's philosophy

SQLite's own tagline: "self-contained, serverless, zero-configuration." What that demands:

- **No daemon, no install step, no port to bind.** If concurrency needed a lock-manager *process*, you'd need something to launch/supervise it and a way for clients to find it — exactly the operational weight SQLite exists to avoid (contrast with Postgres's postmaster + shared buffers + WAL writer vs. `import sqlite3`).
- **Every OS already ships a working, crash-safe, cross-process arbiter: the kernel's lock table.** No need to invent shared memory segments or a coordination protocol — `fcntl()` already is one, for free, on every POSIX system.
- **Composes with "the database is just one file."** Locking as byte ranges *within that same file* means the whole system needs nothing but a filesystem. (A dot-file locking fallback exists in `os_unix.c` for filesystems where `fcntl` doesn't work reliably.)
- **Portability without new abstractions.** The VFS layer (`sqlite3_io_methods`) swaps in whatever native advisory-locking primitive the OS offers — `fcntl` on POSIX, `LockFile`/`LockFileEx` on Windows. SQLite rides the host OS's existing coordination primitive rather than building its own.

Confirmed in source: `src/os_unix.c` header comment (top of file) states it plainly — the file contains *several* interchangeable locking backends (Posix Advisory Locks by default, plus `flock()`, dot-files, proprietary schemes) behind a pluggable VFS, reinforcing that "use whatever primitive the OS gives you" is a first-class design axis, not an implementation accident.

**General systems principle worth keeping:** when the OS already solved your coordination problem, use its primitive instead of reinventing it as an application-level service. Postgres *needs* its own lock manager because it arbitrates access to shared memory/buffers inside one long-lived server process — a resource the OS knows nothing about. SQLite has no such internal shared state across processes to protect; the only shared resource is the file itself, and the file already comes with a kernel-native way to arbitrate it.

**Still pending:** the WAL-mode OS mechanics (adds a `-shm` file, switches from `fcntl` byte-ranges to a different scheme) and the original open question about Postgres-vs-SQLite WAL *role* differences.

---

### Q4: Comprehension check — "Readers see data up to their own pointer position (reader A sees 0-9, reader B sees 0-11, someone wrote more numbers in between). Writers ask the kernel to stop accepting new readers until done, then unlock, and new readers see the new data." Is that right?

**Partly — it conflates two different mechanisms covered so far.**

**Correction:** the `fcntl` byte-range locks (Q2/Q3) do **not** work this way. Those lock bytes (`PENDING_BYTE`, `RESERVED_BYTE`, `SHARED_FIRST..+510`) are **fixed offsets that never move** — pure boolean semaphores ("is byte X locked, yes/no"), not a marker of how much data exists. In rollback-journal mode, every reader holding `SHARED_LOCK` locks the exact same fixed byte range and sees the exact same, single version of the database. There is no partial visibility between readers — it's all-or-nothing, and the writer only swaps in new data *after* every existing reader has fully finished and released, not concurrently with them.

```
ROLLBACK-JOURNAL MODE: single version, boolean gate

  Reader A ──SHARED(fixed bytes 0x40000002..+510)──► sees version V
  Reader B ──SHARED(same fixed bytes)───────────────► sees version V  (identical to A)

  Writer wants to commit V+1:
    RESERVED → PENDING (blocks NEW readers from joining; A/B already in are unaffected)
    → wait for A and B to fully finish and release SHARED
    → EXCLUSIVE → write new data → commit → release

  Reader C (arrives after commit) ──SHARED──► sees version V+1
```

**What the question actually describes correctly is WAL mode** (from Q1, not yet detailed at the OS/mechanics level): each reader freezes its own high-water mark (`mxFrame`) in a growing log at transaction start, and the log keeps growing underneath without disturbing readers already in flight — genuinely different readers can see genuinely different amounts of data at the same instant.

```
WAL MODE: growing log, each reader freezes its own high-water mark

  WAL file:  [frame1][frame2][frame3][frame4][frame5]...
                                  ▲                  ▲
                          Reader A's mxFrame=3   Writer keeps
                          (frozen at frame 3,    appending new
                           ignores 4,5,...)      frames here

  Reader B arrives later, records mxFrame=5 → sees frames up through 5
  Reader A, still mid-transaction, keeps using mxFrame=3 → doesn't see 4 or 5
```

**Takeaway to hold onto:** fixed-offset semaphore bytes (rollback-journal locking) ≠ growing-log snapshot pointer (WAL `mxFrame`). Same overarching goal (readers not corrupted by concurrent writers), completely different mechanism.

**Still pending:** the WAL-mode OS mechanics (the `-shm` file and its locking scheme, since `mxFrame` isn't a simple fcntl byte) and the original open question about Postgres-vs-SQLite WAL *role* differences.

---

### Q5: Explain how WAL works (full mechanics)

WAL mode has three cooperating structures, not just "a log file":

```
mydb.db          — the base table (only touched by checkpoint, not by writers)
mydb.db-wal      — append-only log of changed pages ("frames")
mydb.db-shm      — shared memory: index into the WAL + reader bookkeeping + locks
```

#### The WAL file: what a "frame" is

Source: `src/wal.c` header comment. Every write transaction appends **frames** — one per changed page, header + raw page bytes:

```
WAL file:
┌────────────┐┌─────────┐┌────────────┐┌─────────┐┌────────────┐┌─────────┐
│ WAL header ││ frame 1 ││ frame 2    ││ frame 3 ││ frame 4    ││ frame 5 │...
│ (32 bytes) ││ hdr+page││ hdr+page   ││ hdr+page││ hdr+page   ││ hdr+page│
└────────────┘└─────────┘└────────────┘└─────────┘└────────────┘└─────────┘
```

Each frame header stores: page number, salt values (detect stale/torn frames after crash), and a running checksum chained from the WAL header through every prior frame. A transaction commits by writing a frame flagged as the commit frame (also stores new DB size in pages). Crash recovery replays frames forward, verifying the checksum chain, and stops at the last complete/committed transaction — anything after a broken checksum is torn-write garbage and gets discarded.

Key property: **the WAL only appends, never overwrites in place.** That's exactly why readers mid-transaction are never disturbed — nothing they've already located gets mutated under them.

#### Why an index is needed: the naive-scan problem

Scanning a WAL with 50,000 frames linearly for "the last frame for page 42" is slow. SQLite builds the **wal-index** — a hash table in the `-shm` file mapping page-number → most recent frame offset. It's pure derived data (rebuildable by replaying the WAL), so it doesn't need to be crash-safe or cross-platform: native-endian, mmap'd, thrown away and rebuilt after a crash. (Source comment: "the wal-index is transient... it can use an architecture-specific format.")

#### `mxFrame`: the field that makes snapshotting possible

`WalIndexHdr` struct, `src/wal.c:321`:

```c
struct WalIndexHdr {
  ...
  u32 mxFrame;      /* Index of last valid frame in the WAL */
  u32 nPage;        /* Size of database in pages, as of mxFrame */
  ...
};
```

A reader starting a transaction copies (`memcpy`s) this whole header into its own private memory — freezing `mxFrame`. Every subsequent page lookup in that transaction is answered "as of `mxFrame`," ignoring frames appended afterward. **The entire snapshot mechanism is just a copied integer, not a lock.**

```
 -shm file header (shared, mutable)          Reader A's private copy
 ┌─────────────────────┐                     ┌─────────────────┐
 │ mxFrame = 5  ───────┼──── copied at ─────►│ mxFrame = 3      │ (frozen)
 │ (writer bumps this   │     tx start        └─────────────────┘
 │  as it commits more) │
 └─────────────────────┘
     Writer later commits frames 4, 5 → header's mxFrame becomes 5
     Reader A still queries "<=3" forever, for this transaction
```

#### `nBackfill`: how checkpointing stays safe

`WalCkptInfo` struct, `src/wal.c:394`:

```c
struct WalCkptInfo {
  u32 nBackfill;              /* Number of WAL frames already copied into DB */
  u32 aReadMark[WAL_NREADER]; /* Reader marks */
  u8  aLock[SQLITE_SHM_NLOCK];
  u32 nBackfillAttempted;
  ...
};
```

Source comment: "nBackfill is the number of frames in the WAL that have been written back into the database... nBackfill can only be increased by a thread holding WAL_CKPT_LOCK." A checkpoint copies WAL frames `nBackfill+1..mxFrame` into the base `.db` file, then advances `nBackfill`. Safety invariant: checkpoint can never backfill past the smallest `mxFrame` any active reader is still using, or it would overwrite (in the base file) a page version some reader hasn't finished reading from the WAL yet. `aReadMark[]` is the array of slots where active readers publish "I'm pinned at frame N," giving the checkpointer its floor.

```
                nBackfill=2           mxFrame=5
                     |                    |
WAL frames:    [1][2]|[3][4][5]           |
                     v                    v
              already copied      not yet checkpointed
              into mydb.db        (checkpoint must wait for
                                    readers below frame 5
                                    before going further)

aReadMark[]:  Reader A pinned @3   Reader B pinned @5
              (checkpoint can't backfill past frame 3 while A is active)
```

#### Locking: named slots instead of PENDING/RESERVED bytes

`src/wal.c:290-296`:

```c
#define WAL_WRITE_LOCK         0        // only one writer, ever
#define WAL_CKPT_LOCK          1        // only one checkpointer at a time
#define WAL_RECOVER_LOCK       2        // only one connection recovers after a crash
#define WAL_READ_LOCK(I)       (3+(I))  // up to WAL_NREADER (default 5) reader slots
```

A reader doesn't take one shared lock over the whole file anymore — it claims **one specific reader slot**, publishes its `mxFrame` into `aReadMark[slot]`, and holds a lock only on that slot. This is how multiple readers at genuinely different `mxFrame` values coexist without contending with each other: distinct slots, not one shared byte range.

#### The full cycle

```
1. WRITER commits:
   append frames to .db-wal -> write commit frame -> bump mxFrame in shm header

2. READER starts:
   copy shm header (freezes mxFrame) -> claim a WAL_READ_LOCK(i) slot ->
   publish own mxFrame into aReadMark[i] -> query pages via wal-index hash,
   falling back to base .db file for pages not yet in WAL <= mxFrame

3. CHECKPOINTER (periodic, or on close, or PRAGMA wal_checkpoint):
   take WAL_CKPT_LOCK -> find min(aReadMark[]) across active readers ->
   copy WAL frames nBackfill+1..min(that floor, mxFrame) into mydb.db ->
   fsync the .db file -> advance nBackfill
```

This is what makes "readers never block writers, writer never blocks readers" true: the writer only ever contends with other writers (`WAL_WRITE_LOCK`, still just one at a time — no MVCC on the write side), and readers only ever contend with the checkpointer trying to reclaim frames they still need, never with the writer directly.

**Still pending:** the original open question — where SQLite's WAL *role* diverges most from Postgres's WAL (now answerable: SQLite's WAL is a versioned page store readers query directly, not just a crash-recovery replay log).

---

### Q6: Comprehension check — comparing Postgres WAL vs SQLite WAL

User's attempt: "Postgres always appends data in WAL, and 'moves' the data to database at checkpoint. Postgres only appends data and marks old tuple dead, WAL is where data lives until stored. Also used for recovery (know which page/what's missing). SQLite's WAL is a mechanism to control readers/writers so checkpoint knows what can be stored because no one is looking at it."

**Correction — Postgres side conflates two separate mechanisms:**

1. **MVCC / dead tuples** happens entirely in the **heap** (table file, via shared_buffers): `UPDATE` writes a new tuple version into the heap and marks the old one dead (`xmax`). `VACUUM` reclaims dead tuples later. **WAL has nothing to do with where tuple versions physically live** — that's the heap's job.

2. **WAL / durability** is separate. The write-ahead logging rule: before a modified buffer-pool page can be flushed to its table file, the WAL record describing that change must already be durably on disk (not the reverse). WAL is a **redo log of operations**, not a holding pen for data. Checkpoint doesn't "move data from WAL into the database" — it flushes all currently-dirty shared_buffers pages to their real table files and records the LSN this happened at, so recovery only needs to replay WAL from that point forward. Older WAL segments become archivable/recyclable afterward — not because data "moved" out of WAL, but because the table file was already updated independently.

```
POSTGRES

  client write --> WAL record (fsync'd first, durability proof)
                    |
                    +--> heap page modified in shared_buffers (the LIVE data)
                              |
                    checkpoint: flush dirty shared_buffers pages --> table file on disk
                    (WAL segments before this point can now be discarded/archived)

  READS always go to: shared_buffers / table file.  Readers NEVER read WAL.
  WAL is purely: "what to redo if we crash before the flush above happened."
```

**SQLite side — this part of the original guess was correct, sharpened:** the WAL genuinely IS where current data lives until checkpointed. Not a redo log describing changes made elsewhere — the frames ARE the authoritative content of those pages.

```
SQLITE

  client write --> frame appended to WAL (this IS the current page content now)

  READS: reader checks WAL first (via wal-index) for the page, falls back
         to base .db file only if the WAL has no copy for that page yet.
         Readers DO read the WAL directly, every query, every time.

  checkpoint: copy WAL frames into base .db file, ONLY once no active
              reader still needs them (nBackfill vs aReadMark[] from Q5)
```

**The actual role difference, stated precisely:**

| | Postgres WAL | SQLite WAL |
|---|---|---|
| What it contains | Redo *operations* (physical/logical change records) | Full *page images* (frames) |
| Do readers ever read it? | Never — reads always go to heap/buffer pool | Yes — every read checks the WAL first |
| What "checkpoint" means | Guarantee dirty buffer-pool pages are durably flushed to table files; shrink/recycle WAL | Physically copy page frames from WAL into the base `.db` file |
| Where does MVCC/versioning live? | In the heap itself (old/new tuple versions, `xmin`/`xmax`) | In the WAL itself (old/new page frames, `mxFrame`) |

**Core takeaway:** Postgres's WAL and Postgres's MVCC are two unrelated subsystems that happen to share the word "version." SQLite collapsed both jobs — durability logging *and* multi-version snapshotting — into the *same* file. A genuinely different design decision, not just a smaller version of Postgres's WAL.

**Open question from Q1 is now resolved.** No further pending items from this thread; next topic open.

---

### Q7: How is data actually stored in SQLite? How is it structured to be searchable?

Source: `src/btreeInt.h` top-of-file design comment (references Knuth Vol.3), `src/vdbeaux.c:3868` (record/serial-type format), `src/vdbe.c` `OP_MakeRecord`.

#### Layer 1: the file is just pages

The `.db` file is sliced into fixed-size pages, numbered from 1. Page 1 carries a 100-byte file header (magic string `"SQLite format 3\0"`, page size, counts, etc.), then every page — including page 1 after that header — is a B-tree page, freelist page, overflow page, or pointer-map page.

#### Layer 2: a B-tree page's internal layout

```
Page layout:
+----------------+
| file header     |  100 bytes -- page 1 ONLY
+----------------+
| page header     |  8 bytes (leaf) / 12 bytes (interior)
+----------------+
| cell pointer    |  2 bytes per cell, SORTED, grows downward
| array           |
+----------------+
| (free space)    |
+----------------+
| cell content    |  grows upward, arbitrary order
| area            |
+----------------+
```

Cells stored back-to-front from the end of the page; the sorted pointer array up front (2 bytes/cell) enables binary search within a page without moving cell bytes around.

#### Layer 3: what a "cell" contains

```c
SIZE    DESCRIPTION
  4     Page number of left child   (interior nodes only)
 var    Bytes of data               (omitted if index-only page)
 var    Bytes of key, OR the key itself if intkey
  *     Payload
  4     First overflow page          (only if payload > fits on page)
```

`var` fields are **varints** — 1-9 bytes, 7 usable bits/byte, MSB-first (same idea Protobuf later reused). A rowid of 100 costs 1 byte, not a fixed 8.

#### The two kinds of B-trees — the key to searchability

Single flag distinguishes them: `intKey` (`src/btreeInt.h:275`, "True if table b-trees. False for index b-trees").

- **Table B-tree** — keyed by **rowid** (64-bit int), an `intkey` tree. Leaves hold `rowid -> full row payload`. `WHERE rowid = 12345` is O(log n) direct descent; `WHERE some_col = X` unindexed requires full leaf scan.
- **Index B-tree** — keyed by the **indexed column value(s)** with rowid appended as the last key field pointing back to the row. No separate "data" — payload IS the key (the `zerodata` page-header flag).

```
TABLE B-TREE (rowid -> row)          INDEX B-TREE (column value -> rowid)

        [50]                                [ "m" ]
       /    \                              /       \
  [10,25]  [75,90]                  ["a".."l"]  ["n".."z"]
  rowid    rowid                    (val, rowid) (val, rowid)
  keys ->  keys ->                   pairs, sorted
  full     full                      by val
  row      row
  data     data
```

Every table has exactly one table B-tree (its rowid tree —`WITHOUT ROWID` tables opt out, storing the PK directly instead). Every `CREATE INDEX` adds a separate B-tree sorted by different keys, pointing back into the first.

#### Layer 4: the record format inside a payload

A row's payload is a **record**: header of serial-types, then raw values concatenated (`src/vdbeaux.c:3868`):

```
record = [header-length varint][serial_type_1 varint][serial_type_2 varint]...[data_1][data_2]...
```

```c
serial type    bytes    meaning
   0             0      NULL
   1             1      signed int (1 byte)
   2             2      signed int (2 bytes)
   ...
   6             8      signed int (8 bytes)
   7             8      IEEE float
   8             0      integer constant 0   (stored as ZERO data bytes)
   9             0      integer constant 1
  N>=12 even  (N-12)/2  BLOB
  N>=13 odd   (N-13)/2  TEXT
```

This is SQLite's dynamic typing made concrete at the storage layer: no fixed-width column slots like Postgres's tuple layout — every value carries its own type tag inline, chosen at write time (`OP_MakeRecord` in `vdbe.c`). A column declared `INTEGER` holding `0` costs zero bytes of actual data, just the serial-type tag `8`.

#### Putting it together: how a search happens

```
SELECT * FROM users WHERE id = 42;
   -> table b-tree descent on rowid=42, O(log n) page reads, exact leaf found

SELECT * FROM users WHERE email = 'x@y.com';   (email is indexed)
   -> index b-tree descent on email value, O(log n), leaf gives you the rowid
   -> then a SECOND lookup: table b-tree descent on that rowid, O(log n)
   -> this "two-tree hop" is exactly what Selinger-style cost formulas
      (System R paper) are pricing when distinguishing clustered vs
      non-clustered index cost -- same fundamental tradeoff applies here
```

**Connection to System R paper (project context):** SQLite's non-`intkey` index is structurally a **non-clustered index** — matching a boolean factor gets cheap key comparisons, but each hit still costs a second B-tree traversal to fetch the row, unless the query is index-only (covered).

**Next options offered:** how `where.c` picks between table-scan and index-scan (SQLite's own cost-based planner, comparable to Selinger's optimizer), or overflow pages / freelist reclamation mechanics.

---

### Q8: How does SQLite move/checkpoint data from WAL to the db file while avoiding corruption?

Source: `src/wal.c` comment above `walCheckpoint()` (~line 2166) and the function body (~2166-2345).

Two separate hazards, two different defenses:

1. **Corruption from overwriting a page a live reader still needs** -> solved with `mxSafeFrame` (reader-floor math)
2. **Corruption from a crash mid-checkpoint** -> solved with strict two-fsync ordering

#### Hazard 1: don't clobber what readers are still using

```c
mxSafeFrame = pWal->hdr.mxFrame;          // start optimistic: everything is safe
for i in 1..WAL_NREADER:
    y = aReadMark[i]
    if mxSafeFrame > y:
        mxSafeFrame = y        // shrink the ceiling to the slowest active reader
```

Checkpointer walks every reader slot, clamps its target down to the minimum `mxFrame` any reader currently has pinned (ties back to `nBackfill`/`aReadMark[]` from Q5). If Reader A is frozen at frame 3 and Reader B at frame 5, `mxSafeFrame` becomes 3 — checkpoint copies up to frame 3 into the db file and stops, leaving 4/5 in the WAL until A finishes. Correctness comes from never letting `mxSafeFrame` exceed the slowest reader, not from blocking anyone.

#### Hazard 2: don't corrupt the file on crash/power-loss mid-checkpoint

Direct quote from source comment: "Fsync is called on the WAL before writing content out of the WAL and into the database... Fsync is also called on the database file if (and only if) the entire WAL content is copied into the database file."

```
STEP 1: fsync(WAL file)
        -- guarantees every frame about to be copied is durably on disk
           in the WAL, in case of crash mid-copy (redo checkpoint on restart).

STEP 2: for each page in mxSafeFrame range:
           read szPage bytes from WAL frame  ->  write to .db file at (page-1)*szPage
        (plain writes, NOT yet synced)

STEP 3: IF fully backfilled (mxSafeFrame == WAL's true mxFrame):
           truncate db file to correct size
           fsync(db file)          <- ONLY fires when WAL is now fully redundant
```

Crash-scenario walkthrough (why the ordering is non-negotiable):

```
Crash between STEP 1 and STEP 2:
  WAL durably fsync'd, .db file untouched. Restart: WAL replay redoes
  the checkpoint. Nothing lost.

Crash mid-STEP 2 (some pages written to .db, some not):
  .db file "torn" but WAL still fully intact (never reset since STEP 1's
  fsync). Restart: WAL replay recovers using the frames again; torn .db
  writes are irrelevant until step 3 completes.

Crash between STEP 2 and STEP 3's fsync:
  .db file has new bytes but not necessarily durable yet (write() != fsync()).
  WAL still intact and authoritative. Recovery still works from WAL.

Only AFTER db-file fsync in STEP 3 succeeds is nBackfill actually advanced
(AtomicStore) — only then does the WAL become safely discardable/overwritable.
```

**Invariant in one sentence:** the WAL is never treated as "safe to lose" until the corresponding bytes are provably durable in the `.db` file — that final `fsync` on the db file is the sole gate that flips authority from "WAL is truth" to "`.db` file is truth" for that page range. Corruption is prevented not by hoping writes land in order, but because the WAL is deliberately kept valid and untouched until its content is *proven* redundant.

#### Checkpoint modes: PASSIVE / FULL / RESTART / TRUNCATE

Same core loop, four policies (`src/wal.c` ~2348, referencing doc requirement R-59782-36818):

- **PASSIVE** — best-effort, never blocks, never invokes a busy-handler (`assert(eMode!=PASSIVE || xBusy==0)`). If a reader is in the way, checkpoints less and returns.
- **FULL** — actually waits (via `xBusy` callback) for readers to clear, to fully drain the WAL.
- **RESTART** — like FULL, plus resets the WAL back to frame 0 (`walRestartHdr`) so the next writer starts appending from the beginning instead of growing the file forever.
- **TRUNCATE** — like RESTART, plus physically truncates the `-wal` file to zero bytes on disk (reclaims space, not just resets the logical pointer).

This mode gradient answers "why doesn't the WAL grow forever": SQLite auto-checkpoints in PASSIVE mode by default after a page threshold; FULL/RESTART/TRUNCATE come via explicit `PRAGMA wal_checkpoint(...)` when a stronger blocking guarantee is wanted (e.g. before backing up/deploying the file).

**Next options offered:** `where.c` query planner (ties directly to the Selinger/System R paper), or overflow pages / freelist reclamation mechanics.

---

### Q9: Why does fsync work so well? How does it work behind the scenes?

Source: `src/os_unix.c` comment block ~3752-3775 and `full_fsync()` implementation (~3775-3845).

#### What `write()` actually does — and doesn't do

`write()` does not touch the disk. It copies bytes into the **page cache** — kernel-managed RAM holding "dirty" pages waiting to be flushed. The process returns immediately. A power loss right after `write()` returns loses everything still in that RAM cache — this is why a naive "just write the file" approach isn't durable.

```
Your process --write()--> [ page cache in RAM ]  ...eventually...  --> disk platter/flash
                              (dirty pages,                (kernel decides when,
                               kernel-owned)                 e.g. every 30s by
                                                              default on Linux)
```

`fsync(fd)` forces every dirty page belonging to this file out to stable storage immediately, and doesn't return until it's actually there.

#### Layer by layer — why this is harder than it sounds

```
Process
   | write()          -- lands in page cache (RAM), fast, not durable
   v
Page cache (kernel, RAM)
   | fsync()           -- kernel issues I/O requests to flush dirty pages
   v
Block layer / filesystem (ext4, APFS, etc.)
   |                   -- may itself buffer, may reorder, may batch
   v
Disk controller
   |                   -- often has ITS OWN volatile write cache (RAM on the drive)
   v
Platter / NAND flash    -- the only place actually safe from power loss
```

Three caches sit between `write()` and physical durability: OS page cache, filesystem internal buffering, and the disk drive's own onboard write cache (volatile RAM on the controller itself). `fsync()` is only as good as its ability to punch through all three layers.

#### Why SQLite's own source says fsync "does not work as advertised"

SQLite handles three platform cases differently (`os_unix.c`):

- **macOS** — plain `fsync()` historically does NOT flush the disk's onboard write cache; it only pushes data out of the OS page cache to the disk controller and stops. SQLite calls `fcntl(fd, F_FULLFSYNC, 0)` instead (`os_unix.c:3817`) — a macOS-only fcntl command that forces the physical drive to actually flush its write cache to the platter. Falls back to plain `fsync()` only if `F_FULLFSYNC` fails.
- **Linux** — SQLite prefers `fdatasync()` over `fsync()`. Per the comment: `fdatasync` skips flushing inode metadata (mtime, etc.) not relevant to correctness, syncing only file content (and size, if changed) — cheaper, same durability guarantee SQLite actually needs.
- **Testing** — `SQLITE_NO_SYNC` disables all of this for fast test runs, with an explicit warning: never deploy with it enabled, since "an OS crash or power failure will likely corrupt the database file." This confirms `fsync` isn't a safety-margin optimization — it's the actual boundary between durable and corrupted during power loss.

#### Why fsync "works" when it works

The real guarantee (when the platform honors it correctly): `fsync()` is a **barrier**, not just a flush. When the syscall returns, every byte written to that fd *before* the call is provably on stable storage — survives kernel panic, OS crash, power pull. It does NOT guarantee ordering of *future* writes relative to it. This is exactly why the Q8 checkpoint code fsyncs the WAL before fsyncing the db file: each `fsync()` call is a "everything up to here, provably durable" checkpoint in time, and sequencing two of them constructs a safe crash-recovery narrative.

#### Known caveat worth remembering ("fsyncgate")

2018: Postgres contributors (Craig Ringer et al.) discovered that on Linux, if `fsync()` fails (e.g. kernel couldn't write a dirty page due to a disk error), the kernel marked the error "reported" and cleared the dirty bit anyway — meaning a *second* `fsync()` call would report success even though the data was never actually written. Consequence: you cannot safely retry an `fsync()` failure and trust a later success. Affects how every database (Postgres, and SQLite by extension) must handle fsync error paths. A good example of an OS primitive matching a system's philosophy well — until the primitive itself has a rough edge.

**Next options offered (carried over):** `where.c` query planner (ties to the Selinger/System R paper), overflow pages/freelist mechanics, or revisit the storage/searchability topic flagged as still unclear.

---

### Q10: Plain-text diagram — how is data stored to be findable, and what happens when data needs more than one page? (Selinger-paper style worked example)

Source: `src/btreeInt.h` (page/cell/overflow format), `src/btree.c:1180` (`btreeParseCellAdjustSizeForOverflow`, local-vs-overflow split).

#### Worked example — a `users` table

```sql
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, bio TEXT);
```

Rows keyed by `id` (rowid). Rowids 1-9 inserted; too much cell data for one leaf page on a typical 4096-byte page, so the table b-tree grows an interior page on top.

#### Level 1: table too big for one page -> interior + leaf pages

```
                        PAGE 2 (interior, "root")
                 +-------------------------------------+
                 | Ptr(0) | Key=4 | Ptr(1) | Key=7 | Ptr(2) |
                 +----+-------------+--------------+----+
                      |             |              |
           rowid<=4   |  4<rowid<=7 |   rowid>7    |
                      v             v              v
                 PAGE 3          PAGE 5          PAGE 8
                (leaf)          (leaf)          (leaf)
             +-----------+  +-----------+  +-----------+
             | rowid=1   |  | rowid=5   |  | rowid=8   |
             | rowid=2   |  | rowid=6   |  | rowid=9   |
             | rowid=3   |  | rowid=7   |  +-----------+
             | rowid=4   |  +-----------+
             +-----------+
```

Same B-tree intuition the Selinger paper uses for secondary indexes (section 3), applied here to the TABLE itself: search for `rowid=6` reads page 2 (compare 6 vs 4, vs 7 -> descend Ptr(1)), then page 5 (scan within page, find rowid=6). Two page reads total — O(log n) page fetches, same cost shape Table 2's formulas price (`NINDX(I) + TCARD` etc.), just for the table's own primary structure rather than a secondary index.

Interior page cells hold NO row data — just `Key | ChildPtr` pairs (the 4-byte left-child pointer is only omitted on leaves, per the cell format). Only leaf pages hold actual row payloads.

#### Level 2: one row too big for one page -> overflow chain

Different problem: not "too many rows" but "one single cell doesn't fit." Say rowid 6's `bio` is a 10,000-byte essay. `src/btree.c:1180` computes how many bytes stay LOCAL (on the leaf page, inside the cell) vs spill to OVERFLOW pages, via `minLocal`/`maxLocal` thresholds (ensuring a page can always hold at least ~4 cells). Source comment: "changing the way overflow payload is distributed in any way will result in an incompatible file format" — hard-baked format constant, not a runtime tunable.

```
PAGE 5 (leaf) -- the cell for rowid=6 only stores a PREFIX locally,
then a 4-byte pointer to where the REST of the payload lives:

+-----------------------------------------------------------+
| page header | cell ptr array | ... | cell(rowid=5) |       |
|                                     | cell(rowid=6):       |
|                                     |  keysize=10024       |
|                                     |  [first ~2800 bytes  |
|                                     |   of bio, LOCAL]     |
|                                     |  overflow-ptr -> PG 40|
|                                     | cell(rowid=7) |       |
+-----------------------------------------------------------+
                                              |
                                              v
                          PAGE 40 (overflow, full)
                    +------------------------------+
                    | next-overflow-ptr -> PG 41    |
                    | [next ~4092 bytes of bio]     |
                    +------------------------------+
                                              |
                                              v
                          PAGE 41 (overflow, LAST -- partial)
                    +------------------------------+
                    | next-overflow-ptr = 0 (none)  |
                    | [remaining ~3100 bytes of bio]|
                    +------------------------------+
```

Per the file-format comment: each overflow page except the last is completely full (`pagesize - 4` bytes of data, 4 bytes reserved for the next pointer); only the last page in the chain can be partial. Plain singly-linked list of pages — no B-tree structure among overflow pages, because you never need to search inside one cell's payload, only reconstruct it byte-for-byte once the cell is already located.

#### Reading rowid=6 end to end — combining both mechanisms

```
1. Root (page 2):     6 vs 4 -> 6 vs 7 -> descend Ptr(1)          [1 page read]
2. Leaf (page 5):     scan cells, find rowid=6                    [1 page read]
3. Cell says:         "here's 2800 local bytes, rest is on PG 40"
4. Overflow (page 40): read full page, follow ptr -> PG 41        [1 page read]
5. Overflow (page 41): read remaining bytes, ptr=0 -> done         [1 page read]

Total: 4 page reads to fully materialize one row with a big TEXT column.
Only 2 of those 4 were "search" cost (steps 1-2); the other 2 are pure
payload-reconstruction cost, paid only because THIS row happens to be huge.
```

**Core takeaway:** B-tree search cost (steps 1-2) and payload size cost (steps 3-4) are two independent axes. A million small rows vs ten thousand rows with huge TEXT/BLOB columns can have wildly different total I/O for "the same" query, even with identical tree depth — exactly the kind of thing the Selinger cost formulas (`TCARD`, `NCARD`, page-fetch counts) were built to make explicit rather than leave to intuition.

**Next up (per user request):** WHERE-clause / search strategy — how `where.c` picks table-scan vs index-scan, comparable to Selinger's cost-based optimizer.

---

### Q11: What are the strategies for backing up a SQLite database? What mechanism avoids crashing the backup or the application while backup is running?

Source: `src/backup.c` (Online Backup API implementation), pager hook call sites in `src/pager.c`.

#### Two families of strategy

- **A) Cold copy** — `cp mydb.db mydb-backup.db` while nothing has the file open. Trivially safe, trivially useless for a live application.
- **B) Hot copy** — application running/writing while backup happens. This is what the Online Backup API (`sqlite3_backup_init/step/finish`) and `VACUUM INTO` are purpose-built for.

#### Mechanism 1: incremental, page-by-page copy — bounded blocking

```c
sqlite3_backup *p = sqlite3_backup_init(destDb, "main", srcDb, "main");
while ( sqlite3_backup_step(p, N) == SQLITE_OK ) { /* copy N pages, repeat */ }
sqlite3_backup_finish(p);
```

`sqlite3_backup_step()` (`src/backup.c:325`) doesn't lock the whole source for the entire backup — it opens a normal READ transaction, copies N pages via `backupOnePage`, returns. Called in a loop. From the source database's point of view, an in-progress backup is indistinguishable from an ordinary long-running reader (same SHARED-lock mechanism from Q2/Q3) — never escalates to RESERVED/EXCLUSIVE. The application can keep writing while backup proceeds, because readers and one writer already coexist by design.

#### Mechanism 2: source changes mid-copy — the restart hook

Copying page-by-page over time means a writer could mutate page 3 after it's already been copied into the backup. Naive copying would leave a stale/inconsistent backup. SQLite's pager layer solves this with a callback hook (confirmed call sites: `src/pager.c:1823, 2485, 3193, ...`):

- **`sqlite3BackupUpdate(page, data)`** — fires whenever a page the source pager is writing gets modified. If that page (`iPage < p->iNext`) was already copied into the destination, immediately re-copies the fresh version into the backup. Cheap, surgical — one page, not a restart.
- **`sqlite3BackupRestart()`** — fires when the pager detects something that can't be patched incrementally: a completely different connection modified the database out from under the backup (e.g. WAL reset/checkpointed by another process). Source comment (`src/backup.c:718-725`): "there is no way of knowing which of the pages that have been copied into the destination database are still valid and which are not, so the entire process needs to be restarted." Sets `p->iNext = 1` — backup transparently restarts from page 1 on the next `backup_step()` call.

```
Timeline of a hot backup, with a concurrent writer:

backup_step()  copies pages 1..50 -------------------->
                                    app UPDATEs page 12 (same connection graph)
                                      -> sqlite3BackupUpdate(12, newdata)
                                      -> backup's copy of page 12 patched in place, no restart
backup_step()  copies pages 51..100 --------------------->
                                    a SEPARATE process WAL-checkpoints, resetting things
                                      -> sqlite3BackupRestart()
                                      -> p->iNext = 1  (backup starts over)
backup_step()  copies pages 1..100 again, cleanly ----->  SQLITE_DONE
```

#### Mechanism 3: bounded, cooperative backoff — SQLITE_BUSY, never a hard failure

Top of `backup_step()`: `if (p->pSrc->pBt->inTransaction==TRANS_WRITE) rc = SQLITE_BUSY;` — if the source is mid-write-transaction exactly when `backup_step()` is called, it returns `SQLITE_BUSY` for that call only, not an error. Caller (or a registered busy-handler) sleeps briefly and retries. Same cooperative, non-crashing philosophy as the rest of SQLite's locking model — nothing gets killed/aborted, an operation just waits and asks again.

#### Mechanism 4: `VACUUM INTO` — same engine, different entry point

`VACUUM INTO 'backup.db'` uses this exact backup machinery under the hood (the `#ifndef SQLITE_OMIT_VACUUM` section lives in the same `backup.c` file). Also compacts free pages while copying — useful for a smaller, defragmented backup rather than a byte-identical page copy.

#### What to actively avoid: naive file copy of a WAL-mode database

`cp`-ing just `mydb.db` directly while the app is running, in WAL mode, yields a corrupt/inconsistent snapshot — recently committed data lives in the separate `-wal` file, not yet backfilled (Q5/Q8). Raw filesystem copy of only `mydb.db` (ignoring `-wal`/`-shm`) captures a torn, outdated view. The Online Backup API avoids this entirely because it reads through the normal pager/WAL-aware path (`sqlite3PagerGet`) — the same code path a live query uses — so it always sees a logically consistent snapshot, never raw bytes off disk.

**Next up (carried over):** `where.c` query planner (ties to the Selinger/System R paper).

---

### Q12: How does SQLite handle UPDATE and DELETE? Does it have dead-tuple-like behavior?

Source: `src/btree.c` — `sqlite3BtreeDelete` (:9873), `freeSpace` (:1945), `freePage2` (:6868), `sqlite3BtreeInsert` (:9441); `src/vdbe.c` `OP_Insert`/`OP_Delete` opcodes.

#### Short answer: no, nothing like Postgres's dead tuples

Real architectural difference, not a minor detail. Postgres keeps old row versions physically in the heap (marked dead via `xmax`) because MVCC needs them for snapshot isolation — other transactions might still need the "before" version. SQLite has no MVCC on the write side at all (only one writer, ever — Q1/Q2). Nothing needs an old version to survive a write, so there's no analog to VACUUM cleaning up dead tuples, because nothing SQLite does creates that kind of debris.

#### What UPDATE/DELETE actually do: cell surgery on a page

Both compile to VDBE opcodes operating directly on the B-tree — `OP_Delete` and `OP_Insert`. An UPDATE is, at the storage layer, essentially delete-old-cell + insert-new-cell (with an in-place fast path — see below). No separate "old version" kept anywhere.

**DELETE** (`sqlite3BtreeDelete`, `src/btree.c:9873`):

```
1. Find the cell at the cursor's position
2. Remove its slot from the sorted cell-pointer array
3. Return its bytes to a FREEBLOCK chain within the SAME page
4. If the page is now under-full -> REBALANCE the B-tree (borrow from
   sibling, or merge pages, possibly freeing a whole page)
```

The freeblock mechanism is the closest thing to a "dead tuple" — but page-local, ephemeral, instantly reusable, not a queryable ghost row:

```
BEFORE delete (leaf page):                AFTER DELETE rowid=6:

+---------------------------+           +---------------------------+
| cell ptr: [C1,C2,C3,C4,C5] |           | cell ptr: [C1,C2,C4,C5]    |
|                             |           |                             |
| ... C1 C2 C3 C4 C5 ...     |           | ... C1 C2 [FREEBLOCK] C4 C5|
+---------------------------+           +---------------------------+
                                              ^
                              bytes where C3 (rowid=6) lived are now
                              on a freeblock linked-list, reusable by
                              the VERY NEXT insert on this page
```

Source comment on `freeSpace()`: "Adjacent freeblocks are coalesced." Multiple deletes on a page merge freed space automatically — no fragmentation debris pile-up, no separate page-level cleanup pass needed.

**UPDATE**: same machinery, with an important fast path. If the new row is the same size or smaller and its key doesn't change sort position, `sqlite3BtreeInsert` can often overwrite the existing cell IN PLACE — no delete, no freeblock churn — just new bytes over old bytes on the same page (still going through the pager's copy-on-write-to-journal/WAL path from Q8, so still crash-safe). If the new row is bigger, the old cell can't fit, so it becomes genuine delete-old + insert-new, potentially triggering the overflow-page machinery from Q10 if now big enough to spill.

#### Whole-page reclamation: the freelist

If a whole page becomes empty (last row deleted, or a rebalance shrinks the tree), it doesn't sit wasted — `freePage2()` (`src/btree.c:6868`) links it into the database's **freelist**, a chain of trunk pages each pointing to a batch of fully-empty leaf pages (matches the format doc from Q7: "Freelist pages come in two subtypes: trunk pages and leaf pages"). The next time SQLite needs a fresh page — new leaf, new overflow page — `allocateBtreePage` checks the freelist first before extending the file. Freed pages get reincarnated for unrelated data. Closest real analog to "reclaiming dead space" — automatic, continuous, no manual `VACUUM` required.

#### Where `VACUUM` fits in

Given automatic freelist reclamation, `VACUUM` solves two things freelist reuse doesn't:

1. **File size never shrinks on its own** — freed pages stay in the freelist inside a file that stays the same size on disk.
2. **Fragmentation across the file** — rows for the same table can scatter non-contiguously after enough churn, hurting sequential-scan locality.

`VACUUM` (ties back to Q11 — literally reuses the Online Backup engine internally) rebuilds the entire database into a fresh, contiguous file and swaps it in — genuinely shrinking the file and defragmenting layout. Manual, occasional counterpart to the automatic-but-passive freelist mechanism.

#### The contrast, in one line

**Postgres**: deletes/updates leave old tuple versions visible in the heap until VACUUM/autovacuum explicitly reclaims them — a deliberate MVCC tradeoff, since old versions might still be needed by another in-flight transaction. **SQLite**: deletes/updates reclaim page-local space immediately and automatically via freeblocks and the freelist, because there's no concurrent writer needing the old version to exist — `VACUUM` here is purely file-size/fragmentation housekeeping, not correctness-driven garbage collection.

**Next up (carried over):** `where.c` query planner (ties to the Selinger/System R paper).

---

### Q13: Confirm — do UPDATE/DELETE wait for readers to finish before applying the change? (short answer)

**Depends on the mode:**

- **Rollback-journal mode:** the row mutation happens immediately in the page cache (no waiting), but the writer can't reach EXCLUSIVE to actually commit/finalize until all existing readers release SHARED (RESERVED->PENDING->EXCLUSIVE escalation, Q2). So committing waits for readers; staging the change doesn't.
- **WAL mode:** no waiting at all. Writer just appends frames to the WAL (`WAL_WRITE_LOCK` only contends with other writers, never readers) — readers keep reading their frozen `mxFrame` snapshot, writer keeps appending, zero blocking either direction (Q5).

**Next topic starting now:** `where.c` query planner walkthrough (table-scan vs index-scan selection), ties directly to the Selinger/System R paper.

---

### Q14: Start the `where.c` walkthrough from the basics (LogEst — why logarithmic cost estimates?)

Source: `src/where.c` top-of-file comment ("this module... you might also think of this module as the 'query optimizer'"); `src/sqliteInt.h:875-906` (`LogEst` comment + typedef).

#### Step 1: what problem the planner solves

Same problem as Selinger's System R optimizer (paper Section 4): given a query, several possible ways to fetch rows (table scan? which index? join order?) — pick the cheapest. `where.c` literally calls itself the query optimizer in its own top comment.

#### Step 2: what "cost" gets compared

Selinger's formula: `COST = PAGE_FETCHES + W*(RSI_CALLS)` — plain linear number, plans compared by subtraction.

SQLite represents the same kind of number as a **`LogEst`** — a 16-bit integer (`src/sqliteInt.h:906`). Comment states the rule: "Estimated quantities used for query planning are stored as 16-bit logarithms. For quantity X, the value stored is `10*log2(X)`."

Worked examples from the source comment:

```
Real quantity X        LogEst stored
       1        ->            0
       2        ->           10
       4        ->           20
      10        ->           33
    1000        ->           99
 1000000        ->          199
```

#### Step 3: why logarithmic — what it buys

Cost estimates in a query planner are never exact — built by multiplying a chain of approximate numbers (row counts, selectivity factors...). Selinger's own Table 1 acknowledges selectivity factors like "1/10" or "1/3" are guesses, not measurements. Multiplying a long chain of such approximate numbers (e.g. a 5-way join: cardinality x selectivity x selectivity x selectivity...) has two problems in plain linear arithmetic:

1. Numbers can overflow or lose precision fast across many orders of magnitude within one plan.
2. Multiplication is the natural combining operation (Selinger's own AND-predicate rule: `F = F(pred1) * F(pred2)`).

Logarithms turn multiplication into addition: `log(A x B) = log(A) + log(B)`. So instead of floating-point multiplication chains across huge dynamic ranges while walking a tree of thousands of join-order/access-path combinations (recall the System R paper's "at most 2^n x interesting orders" solution count), SQLite's planner just adds small 16-bit integers to combine cost estimates. Cheaper computation, no overflow risk, compact storage — and since these are estimates anyway, the "grainy" precision loss the comment mentions (16 and 17 both map to LogEst 40) doesn't matter.

```
Selinger-style (linear):                 SQLite-style (LogEst):

cost = NCARD(t1) * F(pred1) * F(pred2)   cost = LogEst(NCARD(t1))
       ...multiply floats, risk of              + LogEst(F(pred1))
       overflow/precision loss across            + LogEst(F(pred2))
       many orders of magnitude...              ...cheap integer addition,
                                                  compact 16-bit storage,
                                                  no overflow risk
```

**Core takeaway:** same conceptual job as Selinger's cost formula (estimate relative expense, pick the cheapest plan), different number representation — chosen because SQLite's planner multiplies many approximate quantities together and wants cheap, overflow-safe, compact arithmetic for it.

**Next options offered:** the `WhereTerm`/`WhereLoop` structures (direct analog to Selinger's "boolean factor" and the access-path tree from Section 4), or a concrete worked example of `LogEst` numbers combined for a real single-table query.
