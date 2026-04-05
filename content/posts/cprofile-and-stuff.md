---
title: What the CPython profiler doesn't show you
date: 2026-04-05
draft: false
tags: [“python”, “CPython”, “cProfile”, “pstats”]
description: "Reading about a new profiling tool pulled a thread that didn't stop at the tool itself. This is an investigation into what .pstats files actually contain, how cProfile produces them, and the gap between what the profiler measures and what's really happening.“
---


I've see recently the post from Adam Joshnson about your new released library called [profiling-explorer](https://adamj.eu/tech/2026/04/03/python-introducing-profiling-explorer/). That is as a browser-based interface for `.pstats` files, the binary format that `cProfile` write to disk. Fancy and friendly UI, kind of tool that makes a familiar workflow suddenly feel less like archaeology.  
Looking at it triggered a question that had nothing to do with the tool itself. What's actually in there the `.pstats` files? How it gets produced. What it means when `cumtime` on a function is 20 times larger than `tottime`.
The tool was like a rock falls in the river that trigger wave of investigation begins.

A `.pstats` file is a marshal-serialized dict, the same binary format `CPython` uses internally for `.pyc` files. Each key is a (filename, lineno, funcname) tuple. Each value is (cc, nc, tt, ct, callers): primitive call count, total call count, total time, cumulative time, and a dict mapping every caller to its own per-caller timing breakdown. Every function recorded in the profile already knows who called it and how much time each caller contributed.

`cProfile` produces this by hooking into `CPython` through `PyEval_SetProfile()` and the interpreter checks it on every `CALL` and `RETURN` event. But the trace of the execution time it's not linear as we wonder at the first time. It does not stop when the GIL is released. That's the part that matters most, and it's not visible in any profiler output.

## What runs below the surface
Every line of Python compiles to bytecodes, and those bytecodes are dispatched through a switch statement in `_PyEval_EvalFrameDefault()`. Understanding what the interpreter is doing at the C level is what makes profiling output interpretable rather than just legible.

An unrelated thing, but interesting, is know how the memory is handle. Memory management runs when it hits zero `tp_dealloc` fires immediately, no garbage collector needed, no collection  cycle, no deferred cleanup. This is why with `open(...)` closes files deterministically in `CPython`. The file object is destroyed the instant the last reference drops.

Backing to profilling stuff. The GIL sits across all of this, so one thread executes Python bytecodes at a time. C extensions that do I/O release it explicitly. During that window, Python threads can run, but `clock_gettime` keeps incrementing for the thread that released the lock.  
That's where `cumtime` accumulates without a corresponding increase in `tottime` and it's the gap that the profiler cannot explain, only show.

By the way, Tachyon, the sampling profiler landing in Python 3.15 has a differenct approach from `cProfile` beceuse its reads directly from a running process's memory via `process_vm_readv` without need the hooks os somethingelse.

## Measuring the hard things to see in the profiler
The tools exist. They just address different layers. `dis.dis()` shows the bytecode structure — how many opcodes the loop body dispatches, whether a name loads from the local array or the global dict:
```
import dis

THRESHOLD = 100

def with_global(data):
    return [x for x in data if x > THRESHOLD]   # LOAD_GLOBAL each iteration

def with_local(data, _t=THRESHOLD):
    return [x for x in data if x > _t]           # LOAD_DEREF one dereference

dis.dis(with_global)
# inside comprehension: LOAD_GLOBAL  1 (THRESHOLD)

dis.dis(with_local)
# inside comprehension: LOAD_DEREF   0 (_t)
```
The difference is 1.3–1.5x on a tight loop, purely from removing the dict lookup. Not a dramatic number, but it's real and it's free.  


`__slots__` is in the same category, an allocation decision made at class definition time that `cProfile` never surfaces. Without it, every instance carries a `PyDictObject` 232 bytes of pre-allocated hash table regardless of how many attributes are stored. With `__slots__`, `CPython` generates `PyMemberDef` entries, fixed C-level offsets into the struct, no dict at all. Attribute access becomes a single pointer dereference:
```
import sys

class WithDict:
    def __init__(self, x, y, z):
        self.x = x; self.y = y; self.z = z

class WithSlots:
    __slots__ = ('x', 'y', 'z')
    def __init__(self, x, y, z):
        self.x = x; self.y = y; self.z = z

d = WithDict(1, 2, 3)
s = WithSlots(1, 2, 3)

print(sys.getsizeof(d) + sys.getsizeof(d.__dict__))  # ~280 bytes
print(sys.getsizeof(s))  # ~56 bytes
```

## Conclusion 

Reading about profiling-explorer was the entry point. A browser UI for .pstats files . But looking at what the tool was reading pulled the thread. What's in the file. How cProfile produces it. What those data are actually measures and, more importantly, what it doesn't.  
That last part is where the investigation settled for a while. Seemed hard is get the measurement right to a slow sub-function. Sometimes it's the GIL released for a database round trip, the OS scheduler preempting the thread mid-execution, an allocator churn that never shows up as time at all. The profiler shows the frame was on the stack. It doesn't show what the stack was waiting for.  
And other things were appearing by that, PyEval_SetProfile(), PyFrameObject, memory management and bytecode dispatch that was not the plan when the tab opened. It rarely is. The tool was good. The question it triggered was better.
