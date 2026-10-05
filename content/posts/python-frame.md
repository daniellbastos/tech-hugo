---
title: "First Steps into Frame in Python"
date: 2026-10-06
draft: true
tags: ["python", "cpython", "python internals", "frame", "reference counting"]
---

Following the previous post about the memory management in Python, now we need to understand how the frame works in Python.

A frame is a state of one python code execution, it should be a entire script file or a function or other nested code. Each frame contains the code, local objects, reference to the globals and built-in namespaces, and a link to the caller. The objects they reference live as long as something references them.

Each information about the frame can be verified directly in Python code
```python
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

Running the script
```bash
root@d98981498b7b:/app# python ex1.py
>>> global::frame:  <frame at 0xffffa5954880, file '/app/ex1.py', line 14, code <module>>
>>> global::frame.f_locals:  {'__name__': '__main__', '__doc__': None, '__package__': None, '__loader__': <_frozen_importlib_external.SourceFileLoader object at 0xffffa57aee40>, '__spec__': None, '__annotations__': {}, '__builtins__': <module 'builtins' (built-in)>, '__file__': '/app/ex1.py', '__cached__': None, 'sys': <module 'sys' (built-in)>, 'a': 10, 'b': 'ignore me', 'foo': <function foo at 0xffffa57e5620>}
>>> global::frame.f_globals:  {'__name__': '__main__', '__doc__': None, '__package__': None, '__loader__': <_frozen_importlib_external.SourceFileLoader object at 0xffffa57aee40>, '__spec__': None, '__annotations__': {}, '__builtins__': <module 'builtins' (built-in)>, '__file__': '/app/ex1.py', '__cached__': None, 'sys': <module 'sys' (built-in)>, 'a': 10, 'b': 'ignore me', 'foo': <function foo at 0xffffa57e5620>}
>>> foo::frame:  <frame at 0xffffa59fd080, file '/app/ex1.py', line 7, code foo>
>>> foo::frame.f_back:  <frame at 0xffffa5954880, file '/app/ex1.py', line 17, code <module>>
>>> foo::frame.f_locals:  {'x': 10, 'd': 42}
>>> foo::frame.f_globals:  {'__name__': '__main__', '__doc__': None, '__package__': None, '__loader__': <_frozen_importlib_external.SourceFileLoader object at 0xffffa57aee40>, '__spec__': None, '__annotations__': {}, '__builtins__': <module 'builtins' (built-in)>, '__file__': '/app/ex1.py', '__cached__': None, 'sys': <module 'sys' (built-in)>, 'a': 10, 'b': 'ignore me', 'foo': <function foo at 0xffffa57e5620>}
ignore me
42
```

We noticed the `frame` global don't know which variables exists in the `foo` frame, but the `foo` frame know who is the caller and can access the globals vars too.

I guess it's intersting to make it clear and connect to the reference counting knowledge we've mentioned in the other post.
And now we're able to explore a bit when the variables are freed, and how this impact the memory usage.
To make it a little bit more fun, I creaed a simple code to help us to see the memory impact during the code execution.
For the next examples, we'll use this dummy class to simulate any kind of complex object.

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

As first example, look this code and answer the question.
```python
def foo():
    for _ in range(3):
        obj = DummyObj(10)  # 10Mb
        # do something

foo()
```

How much was the peak of memory used at the end of `foo`?
A) 10Mb
B) 20Mb
C) 30Mb
D) Nothing else

You're right if you choose B.
You should be woried about it because we're overriding the same variable, so why we used 20Mb instead of 10Mb?
This happen because **before** override the `obj` points, we needed to create the new instance of `DummyObj` first, so, for a moment you have both objects live at the same time.

You don't need to thuth me, I've implemented a small helper to be able to measure how much memory we're using, what is the peak, and the variables from that frame.

The helper code
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

Now, updating the previous code to mark the points what we want to measure into `foo`.
```python
from utils import DummyObj, exec_function, TraceExec


def foo(_te: TraceExec) -> None:
    _te.mark("start")
    for _ in range(3):
        _te.mark("forloop::start")
        obj = DummyObj(10)
        # do something
        _te.mark("forloop::end")

    _te.mark("end")


if __name__ == "__main__":
    exec_function("foo", foo)
```

Run again to can confirm the memory usage
```bash
root@d98981498b7b:/app/src# python foo.py
0.foo::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff902efb30>}
1.foo::forloop::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff902efb30>, '_': 0}
2.foo::forloop::after instance obj: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff902efb30>, '_': 0, 'obj': DummyObj 281473100741472}
3.foo::forloop::end: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff902efb30>, '_': 0, 'obj': DummyObj 281473100741472}
4.foo::forloop::start: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff902efb30>, '_': 1, 'obj': DummyObj 281473100741472}
5.foo::forloop::after instance obj: curr=20MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff902efb30>, '_': 1, 'obj': DummyObj 281473100742192}
6.foo::forloop::end: curr=10MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff902efb30>, '_': 1, 'obj': DummyObj 281473100742192}
7.foo::forloop::start: curr=10MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff902efb30>, '_': 2, 'obj': DummyObj 281473100742192}
8.foo::forloop::after instance obj: curr=20MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff902efb30>, '_': 2, 'obj': DummyObj 281473100741472}
9.foo::forloop::end: curr=10MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff902efb30>, '_': 2, 'obj': DummyObj 281473100741472}
10.foo::end: curr=10MB, peak=20MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff902efb30>, '_': 2, 'obj': DummyObj 281473100741472}
```

Look at the lines `4.foo::forloop::start` and `5.foo::forloop::after instance obj:...`, we started the loop with the previous object alive (`DummyObj 281473662712384`), the previous object only will died when the current loop/frame ends.

This is a simple example to confirm when the Python freed the objects with no referencing. An alternative to avoid doubling memory usage in this case, is forcing the death of the object before go to next iteration.
```python
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
The output can confirm it 
```bash
root@d98981498b7b:/app/src# python foo_del.py
0.foo_del::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9d65fb90>}
1.foo_del::forloop::start: curr=0MB, peak=0MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9d65fb90>, '_': 0}
2.foo_del::forloop::after instance obj: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9d65fb90>, '_': 0, 'obj': DummyObj 281473322520160}
3.foo_del::forloop::end: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9d65fb90>, '_': 0}
4.foo_del::forloop::start: curr=0MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9d65fb90>, '_': 1}
5.foo_del::forloop::after instance obj: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9d65fb90>, '_': 1, 'obj': DummyObj 281473322520160}
6.foo_del::forloop::end: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9d65fb90>, '_': 1}
7.foo_del::forloop::start: curr=0MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9d65fb90>, '_': 2}
8.foo_del::forloop::after instance obj: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9d65fb90>, '_': 2, 'obj': DummyObj 281473322520160}
9.foo_del::forloop::end: curr=10MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9d65fb90>, '_': 2}
10.foo_del::end: curr=0MB, peak=10MB, curr_frame: {'_te': <utils.TraceExec object at 0xffff9d65fb90>, '_': 2}
```

Very nice, no?

I hope this simple example should be enough to help you to understand how the knowledge about memory management should be impact your code if you don't be attention while you write your code.
