---
title: "First Steps into Frames in Python"
date: 2026-10-09
draft: false
series: ["Python internals"]
tags: ["python", "cpython", "python internals", "frames", "reference counting"]
---

Following the previous post about [memory management in Python](https://tech.daniellbastos.com.br/posts/python-memory-management/) and continuing the exploration of Python internals, this post walks through frames in Python.

A frame is the state of one execution of Python code. It can be an entire script file, a function, a class body.
Each frame contains its code, its local variables, references to the global and built-in namespaces, and a link to the caller.
Local variables only reference objects, and objects live as long as something references them.


The frame's information can be verified directly with Python code.

> For all examples, I used Python 3.13.

```python
# ex1.py
import sys
a = 10
b = "ignore me"

def foo(x):
    d = x + 32
    print(">>> foo::frame: ", sys._getframe())
    print(">>> foo::frame.f_back: ", sys._getframe().f_back)
    print(">>> foo::frame.f_locals: ", dict(sys._getframe().f_locals))
    print(">>> foo::frame.f_globals: ", dict(sys._getframe().f_globals))
    print(b)
    return d

print(">>> global::frame: ", sys._getframe())
print(">>> global::frame.f_locals: ", dict(sys._getframe().f_locals))
print(">>> global::frame.f_globals: ", dict(sys._getframe().f_globals))
print(foo(a))
```

```
root@8048b4526f56:/app# python ex1.py
>>> global::frame:  <frame at 0xffff8a03d080, file '/app/ex1.py', line 15, code <module>>
>>> global::frame.f_locals:  {'__name__': '__main__', '__doc__': None, '__package__': None, '__loader__': <_frozen_importlib_external.SourceFileLoader object at 0xffff8a1fe2c0>, '__spec__': None, '__annotations__': {}, '__builtins__': <module 'builtins' (built-in)>, '__file__': '/app/ex1.py', '__cached__': None, 'sys': <module 'sys' (built-in)>, 'a': 10, 'b': 'ignore me', 'foo': <function foo at 0xffff8a0a7ce0>}
>>> global::frame.f_globals:  {'__name__': '__main__', '__doc__': None, '__package__': None, '__loader__': <_frozen_importlib_external.SourceFileLoader object at 0xffff8a1fe2c0>, '__spec__': None, '__annotations__': {}, '__builtins__': <module 'builtins' (built-in)>, '__file__': '/app/ex1.py', '__cached__': None, 'sys': <module 'sys' (built-in)>, 'a': 10, 'b': 'ignore me', 'foo': <function foo at 0xffff8a0a7ce0>}
>>> foo::frame:  <frame at 0xffff8a0958c0, file '/app/ex1.py', line 8, code foo>
>>> foo::frame.f_back:  <frame at 0xffff8a03d080, file '/app/ex1.py', line 18, code <module>>
>>> foo::frame.f_locals:  {'x': 10, 'd': 42}
>>> foo::frame.f_globals:  {'__name__': '__main__', '__doc__': None, '__package__': None, '__loader__': <_frozen_importlib_external.SourceFileLoader object at 0xffff8a1fe2c0>, '__spec__': None, '__annotations__': {}, '__builtins__': <module 'builtins' (built-in)>, '__file__': '/app/ex1.py', '__cached__': None, 'sys': <module 'sys' (built-in)>, 'a': 10, 'b': 'ignore me', 'foo': <function foo at 0xffff8a0a7ce0>}
ignore me
42
```

The `f_back` of `foo` has the same address as the module frame, `0xffff8a03d080`. Inside `foo`, `f_locals` has only `x` and `d`. The `b` that `foo` prints comes from `f_globals`.
Nothing is new here, but it explains a bit how these things work behind the scenes.

To make it a little bit more fun, and to connect with memory management theme, I created a small class that allocates a known amount of memory to be used in the next examples to illustrate how long objects live.

```python
import os

MB = 1024 * 1024


class DummyObj:
    def __init__(self, mb=1) -> None:
        self.data = os.urandom(mb * MB)

    def __str__(self) -> str:
        return f"DummyObj {id(self)}"

    def __repr__(self) -> str:
        return str(self)
```

Look at this code and answer the question: What was the peak memory used during `foo`? 
```python
def foo():
    for _ in range(3):
        obj = DummyObj(10)  # 10MB
        # do something

foo()
```

You're right if you said 20MB.  
If you want to check your answer before reading further, run this locally:
```python
import tracemalloc

tracemalloc.start()
foo()
current, peak = tracemalloc.get_traced_memory()
print(f"current={current / MB:.1f} MB, peak={peak / MB:.1f} MB")
tracemalloc.stop()
```

We are reassigning the same variable, so why did we use 20 MB instead of 10 MB?  
This happens because Python evaluates the right side first. The new `DummyObj` must **exist before** `obj` can point to it.
For a moment, **both objects are alive at the same time**.

I implemented a small utils/helper code to measure the current memory usage, the peak, and the local variables of the frame at each point.  
```python
# utils.py
import sys, os, tracemalloc

MB = 1024 * 1024


class DummyObj:
    def __init__(self, mb=1) -> None:
        self.data = os.urandom(mb * MB)

    def __str__(self) -> str:
        return f"DummyObj {id(self)}"

    def __repr__(self) -> str:
        return str(self)


class TraceExec:
    def __init__(self, prefix) -> None:
        self.samples = []
        self.index = 0
        self.prefix = prefix
        self.tracemalloc = tracemalloc

    def __enter__(self) -> "TraceExec":
        self.tracemalloc.start()
        return self

    def __exit__(self, *exec) -> None:
        self.tracemalloc.stop()

    def _format_label(self, label) -> str:
        return f"{self.index}.{self.prefix}::{label}"

    def _print_in_mb(self, value) -> str:
        return f"{value/MB:.0f}MB"

    def mark(self, label) -> None:
        curr, peak = tracemalloc.get_traced_memory()
        self.samples.append(
            (
                self._format_label(label),
                str(sys._getframe(1).f_locals),
                curr,
                peak,
            )
        )
        self.index += 1

    def report(self) -> None:
        self.tracemalloc.stop()
        for label, curr_frame, curr, peak in self.samples:
            print(f"{label}: curr={self._print_in_mb(curr)}, peak={self._print_in_mb(peak)}, curr_frame: {curr_frame}")


def exec_function(label, func) -> None:
    with TraceExec(label) as traceexec:
        func(traceexec)

    traceexec.report()
```

Now I updated the previous code to mark the points we want to measure inside `foo`.
```python
# foo.py
from utils import DummyObj, TraceExec, exec_function


def foo(_te: TraceExec) -> None:
    _te.mark("start")
    for _ in range(3):
        _te.mark("forloop::start")
        obj = DummyObj(10)
        _te.mark("forloop::after instance obj")
        # do something
        _te.mark("forloop::end")

    _te.mark("end")


if __name__ == "__main__":
    exec_function("foo", foo)
```

Running it again:
```
root@8048b4526f56:/app# python src/foo.py
0.foo::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9884f4d0>}
1.foo::forloop::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9884f4d0>, '_': 0}
2.foo::forloop::after instance obj: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9884f4d0>, '_': 0, 'obj': DummyObj 281473240592608}
3.foo::forloop::end: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9884f4d0>, '_': 0, 'obj': DummyObj 281473240592608}
4.foo::forloop::start: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9884f4d0>, '_': 1, 'obj': DummyObj 281473240592608}
5.foo::forloop::after instance obj: curr=10MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9884f4d0>, '_': 1, 'obj': DummyObj 281473239536080}
6.foo::forloop::end: curr=10MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9884f4d0>, '_': 1, 'obj': DummyObj 281473239536080}
7.foo::forloop::start: curr=10MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9884f4d0>, '_': 2, 'obj': DummyObj 281473239536080}
8.foo::forloop::after instance obj: curr=10MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9884f4d0>, '_': 2, 'obj': DummyObj 281473239537040}
9.foo::forloop::end: curr=10MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9884f4d0>, '_': 2, 'obj': DummyObj 281473239537040}
10.foo::end: curr=10MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9884f4d0>, '_': 2, 'obj': DummyObj 281473239537040}
```

Look at lines `4.foo::forloop::start` and `5.foo::forloop::after instance obj`.
The loop starts with the previous object alive (`DummyObj 281473240592608`), and the new object is created while `obj` still points to the old one.
The old object dies when `obj` is reassigned, because this removes its last reference (its reference count hits zero).

To avoid doubling memory in this case, we can remove the reference before the next iteration.
```python
# foo_del.py
from utils import DummyObj, exec_function, TraceExec


def foo_del(_te: TraceExec) -> None:
    _te.mark("start")
    for _ in range(3):
        _te.mark("forloop::start")
        obj = DummyObj(10)
        _te.mark("forloop::after instance obj")
        # do something with obj
        del obj
        _te.mark("forloop::end")

    _te.mark("end")


if __name__ == "__main__":
    exec_function("foo_del", foo_del)
```

```
root@8048b4526f56:/app# python src/foo_del.py
0.foo_del::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff85e1f4d0>}
1.foo_del::forloop::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff85e1f4d0>, '_': 0}
2.foo_del::forloop::after instance obj: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff85e1f4d0>, '_': 0, 'obj': DummyObj 281472927920352}
3.foo_del::forloop::end: curr=0MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff85e1f4d0>, '_': 0}
4.foo_del::forloop::start: curr=0MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff85e1f4d0>, '_': 1}
5.foo_del::forloop::after instance obj: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff85e1f4d0>, '_': 1, 'obj': DummyObj 281472926863824}
6.foo_del::forloop::end: curr=0MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff85e1f4d0>, '_': 1}
7.foo_del::forloop::start: curr=0MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff85e1f4d0>, '_': 2}
8.foo_del::forloop::after instance obj: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff85e1f4d0>, '_': 2, 'obj': DummyObj 281472926863824}  # new object, same address as the freed one
9.foo_del::forloop::end: curr=0MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff85e1f4d0>, '_': 2}
10.foo_del::end: curr=0MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff85e1f4d0>, '_': 2}
```

Nice, right?  

I know, calling `del` on every object is not common.
But you get the idea: if we load a huge object, we hold it in memory for as long as the frame references it.

```python
# loop.py
from utils import DummyObj, TraceExec, exec_function


def process(_te: TraceExec, obj: DummyObj):
    _te.mark("process")

def get_objects_list(_te: TraceExec) -> list[DummyObj]:
    _te.mark("get_objects_list::start")
    objects = []
    _te.mark("get_objects_list::before_loop")
    for _ in range(4):
        objects.append(DummyObj(10))
    _te.mark("get_objects_list::end")
    return objects

def accumulate(_te: TraceExec) -> None:
    _te.mark("start")
    objects_list = get_objects_list(_te)
    _te.mark("before_loop")
    for page in objects_list:
        _te.mark("loop::before_process")
        process(_te, page)
    _te.mark("end")


if __name__ == "__main__":
    exec_function("accumulate", accumulate)
```

```
root@8048b4526f56:/app# python src/loop.py
0.accumulate::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>}
1.accumulate::get_objects_list::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>}
2.accumulate::get_objects_list::before_loop: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'objects': []}
3.accumulate::get_objects_list::end: curr=40MB, peak=40MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'objects': [DummyObj 281473720250592, DummyObj 281473719194384, DummyObj 281473719195344, DummyObj 281473720707248], '_': 3}
4.accumulate::before_loop: curr=40MB, peak=40MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'objects_list': [DummyObj 281473720250592, DummyObj 281473719194384, DummyObj 281473719195344, DummyObj 281473720707248]}
5.accumulate::loop::before_process: curr=40MB, peak=40MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'objects_list': [DummyObj 281473720250592, DummyObj 281473719194384, DummyObj 281473719195344, DummyObj 281473720707248], 'page': DummyObj 281473720250592}
6.accumulate::process: curr=40MB, peak=40MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'obj': DummyObj 281473720250592}
7.accumulate::loop::before_process: curr=40MB, peak=40MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'objects_list': [DummyObj 281473720250592, DummyObj 281473719194384, DummyObj 281473719195344, DummyObj 281473720707248], 'page': DummyObj 281473719194384}
8.accumulate::process: curr=40MB, peak=40MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'obj': DummyObj 281473719194384}
9.accumulate::loop::before_process: curr=40MB, peak=40MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'objects_list': [DummyObj 281473720250592, DummyObj 281473719194384, DummyObj 281473719195344, DummyObj 281473720707248], 'page': DummyObj 281473719195344}
10.accumulate::process: curr=40MB, peak=40MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'obj': DummyObj 281473719195344}
11.accumulate::loop::before_process: curr=40MB, peak=40MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'objects_list': [DummyObj 281473720250592, DummyObj 281473719194384, DummyObj 281473719195344, DummyObj 281473720707248], 'page': DummyObj 281473720707248}
12.accumulate::process: curr=40MB, peak=40MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'obj': DummyObj 281473720707248}
13.accumulate::end: curr=40MB, peak=40MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffb51bf4d0>, 'objects_list': [DummyObj 281473720250592, DummyObj 281473719194384, DummyObj 281473719195344, DummyObj 281473720707248], 'page': DummyObj 281473720707248}
```

In this example, the current memory stays at 40MB until the end, because `objects_list` in the `accumulate` frame still references the list, and the list references all four objects.


On the other hand, with a generator and `del`, only one object is alive at a time.
```python
# stream.py
from collections.abc import Iterator

from utils import DummyObj, TraceExec, exec_function


def process(_te: TraceExec, obj: DummyObj):
    _te.mark("process")

def get_objects_stream(_te: TraceExec) -> Iterator[DummyObj]:
    _te.mark("get_objects_stream::start")
    for _ in range(4):
        yield DummyObj(10)
    _te.mark("get_objects_stream::end")

def stream(_te: TraceExec) -> None:
    _te.mark("start")
    objects_stream = get_objects_stream(_te)
    _te.mark("before_loop")
    for page in objects_stream:
        _te.mark("loop::before_process")
        process(_te, page)
        del page
    _te.mark("end")


if __name__ == "__main__":
    exec_function("stream", stream)
```

```
root@8048b4526f56:/app# python src/stream.py
0.stream::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>}
1.stream::before_loop: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>, 'objects_stream': <generator object get_objects_stream at 0xffffabcdd080>}
2.stream::get_objects_stream::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>}
3.stream::loop::before_process: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>, 'objects_stream': <generator object get_objects_stream at 0xffffabcdd080>, 'page': DummyObj 281473565521440}
4.stream::process: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>, 'obj': DummyObj 281473565521440}
5.stream::loop::before_process: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>, 'objects_stream': <generator object get_objects_stream at 0xffffabcdd080>, 'page': DummyObj 281473564468368}
6.stream::process: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>, 'obj': DummyObj 281473564468368}
7.stream::loop::before_process: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>, 'objects_stream': <generator object get_objects_stream at 0xffffabcdd080>, 'page': DummyObj 281473564468368}  # new object, same address as the freed one
8.stream::process: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>, 'obj': DummyObj 281473564468368}
9.stream::loop::before_process: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>, 'objects_stream': <generator object get_objects_stream at 0xffffabcdd080>, 'page': DummyObj 281473565981920}
10.stream::process: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>, 'obj': DummyObj 281473565981920}
11.stream::get_objects_stream::end: curr=0MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>, '_': 3}
12.stream::end: curr=0MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffffabe2ee40>, 'objects_stream': <generator object get_objects_stream at 0xffffabcdd080>}
```


These simple examples help us understand how frames work in Python and how they can help our applications use less memory, if we pay attention to them.  
We don't control when Python gives memory back to the OS, but **we can try to control how many objects are alive at the same time**.