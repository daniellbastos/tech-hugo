---
title: tottime = 0 doesn’t mean fast
date: 2026-04-05
draft: false
tags: ["python", "CPython", "cProfile", "pstats", "performance", "internals", "memory"]
description: "A new profiling tool pulled a thread. What's actually in a .pstats file, how cProfile produces it, and why tottime = 0 doesn't mean fast."
---

Adam Johnson released a new library recently called [profiling-explorer](https://adamj.eu/tech/2026/04/03/python-introducing-profiling-explorer/). A browser-based interface for `.pstats` files, the binary output that `cProfile` writes to disk when you profile Python code. Fancy and friendly UI, kind of tool that makes a familiar workflow suddenly feel less like archaeology.

Looking at it triggered a question that had nothing to do with the tool itself. What's actually in there the `.pstats` files? How it gets produced. What it means when `cumtime` on a function is 20 times larger than `tottime`.
The tool was the rock. The investigation was the wave.

A `.pstats` file is a marshal-serialized dict, the same binary format `CPython` uses internally for `.pyc` files. Each key is a (filename, lineno, funcname) tuple. Each value is (cc, nc, tt, ct, callers): primitive call count, total call count, total time, cumulative time, and a dict mapping every caller to its own per-caller timing breakdown[0]. Every function recorded in the profile already knows who called it and how much time each caller contributed.

`cProfile` produces this by hooking into `CPython` through `PyEval_SetProfile()` and the interpreter checks it on every `CALL` and `RETURN` event. But the trace of the execution time it's not linear as we wonder at the first time. It does not stop when the GIL is released. That's the part that matters most, and it's not visible in any profiler output.

The two numbers mean different things and looking at one without the other is how investigations go in the wrong direction.

`tottime` is time spent inside the function itself, excluding sub-calls. `cumtime` is total elapsed wall-clock time from when the function was entered to when it returned including everything it called.

Three functions show the three distinct cases:

```python
import cProfile, pstats, io, time

def compute():
    # pure CPU — GIL held the entire execution
    return sum(i * i for i in range(300_000))

def wait_for_db():
    # simulates psycopg2: releases GIL during I/O wait
    time.sleep(0.05)
    return {'rows': 100}

def orchestrate():
    # coordinator: does nothing itself, only calls others
    a = compute()
    b = wait_for_db()
    return a, b

pr = cProfile.Profile()
pr.enable()
orchestrate()
pr.disable()

stream = io.StringIO()
ps = pstats.Stats(pr, stream=stream)
ps.sort_stats('cumtime').print_stats(8)
print(stream.getvalue())
```

Output:

```
         300007 function calls in 0.102 seconds

   Ordered by: cumulative time

   ncalls  tottime  percall  cumtime  percall filename:lineno(function)
        1    0.000    0.000    0.102    0.102 /app/test.py:12(orchestrate)
        1    0.000    0.000    0.055    0.055 /app/test.py:7(wait_for_db)
        1    0.055    0.055    0.055    0.055 {built-in method time.sleep}
        1    0.000    0.000    0.047    0.047 /app/test.py:3(compute)
        1    0.024    0.024    0.047    0.047 {built-in method builtins.sum}
   300001    0.022    0.000    0.022    0.000 /app/test.py:5(<genexpr>)
        1    0.000    0.000    0.000    0.000 {method 'disable' of '_lsprof.Profiler' objects}

```

`orchestrate` has `tottime = 0` and `cumtime = 102ms`. It spent no time doing anything itself, it just called other things. When you see this pattern, the function is not the problem. Something below it is.

`compute` has `tottime ~ cumtime`. The CPU holding the GIL the entire time, no I/O, no sub-calls that release control. It's means the function is doing real work and that work is measurable. This is the pattern you want to find when optimizing CPU-bound code.

`wait_for_db` has `tottime = 0` and `cumtime = 55ms`. That gap is `time.sleep()` (the same mechanism `psycopg2.execute()`, any socket read, any network call) releases the GIL. The profiler records the full time as `cumtime` on `wait_for_db`, with nothing in `tottime` because no Python bytecodes executed during that window. This one is the easiest to misread. `tottime = 0` looks like a profiler bug until you remember what happens to the GIL during a sleep.

A function with `tottime = 0` and `cumtime = 55ms` is not slow, **it is waiting**.

Reading about `profiling-explorer` was the entry point. A browser UI for `.pstats` files — nothing more than that at first glance. But looking at what the tool was reading pulled the thread. What's in the file. How `cProfile` produces it. What those numbers are actually measuring and, more importantly, what they don't.

Going deeper was not the plan when the tab opened. It rarely is. The tool is good. The question it triggered was better.

---
[0]
- cc / nc: primitive call count vs total calls (differ only with recursion)
- tt / tottime: time inside the function, GIL held, no sub-calls
- ct / cumtime: wall-clock from entry to return, everything included
- percall: appears twice — tt/ncalls and ct/ncalls
- callers: dict mapping each caller to its own timing breakdown
