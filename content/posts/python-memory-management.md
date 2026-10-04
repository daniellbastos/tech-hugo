---
title: "First Steps into Memory Management in Python"
date: 2026-10-04
draft: false
tags: ["python", "cpython", "python internals", "memory management", "garbage collector", "reference counting"]
---

For a long time, memory management in Python wasn't something I worried about while implementing things. It still isn't causing me any problems at work, but I became very interested in understanding it.

The starting point was the talk [Strong ref, weakref and garbage collector walk into a bar](https://www.youtube.com/watch?v=wIC4S9awFa8&t=11942s). Reference counting, gen0, gen1 and gen2: all of it made a lot of sense once I got it, but I felt like I was putting on my pants before my underpants. So I took a step back and before learning how Python frees memory, I needed to understand how it allocates it.

I went down a rabbit hole that I thought would never end. I'm still in it. But I managed to put my head out to take a breath and write something, to make things clear to myself before going deeper.

> ### Disclaimer:
> I'll talk about my studies on this topic, using CPython 3.12. I may not be 100% accurate because this is a brain dump on paper.

In Python, we have two ways to allocate memory, it's based on the object's size, `pymalloc` for small objects (≤512 bytes) and `malloc` (`PyMem_RawMalloc`) for the big ones.

Starting with small objects (`pymalloc`): when the process needs space for a new object and has none available, `pymalloc` asks the OS for a big chunk of memory called an arena. Each arena is divided into 64 pools, and each pool is divided into blocks of the same size.

> If you want to understand more about what is the Arena, Pools and Block, check this [blog post](https://realpython.com/python-memory-management/#cpythons-memory-management).

The object is stored in a free block, inside a pool. The memory only becomes real from the OS's point of view when its page is written for the first time. `pymalloc` only asks the OS for a new arena when none of the existing ones has room for an object of that size.

An arena is only given back to the OS when all of its pools are empty. So when a single block is freed, nothing changes for the OS: pymalloc keeps the space and reuses it for the next object of the same size.

This is fast, because most allocations just take a free block from a pool that already exists, without asking the OS for anything. The trade-off is that a Python process rarely shrinks. A single live object is enough to keep its whole arena from going back to the OS.

Bigger objects (>512 bytes) use `malloc`, the memory allocator that comes with the system's C library. Here there are no arenas or pools, Python asks for a number of bytes and malloc handles the rest. When the object is freed, malloc usually keeps the memory for reuse too. Only very large blocks go straight back to the OS.

This simple overview about the memory allocation is enough to get a point: **once memory is allocated, freeing it doesn't always reduce the memory the OS sees.**

Like allocation, deallocation also has two ways to free memory: reference counting and the garbage collector.

**Reference counting** is the simplest one to understand. Everything in Python is an object: int, strings, lists, functions, etc.

A variable is just a name that points to an object. So when you write `x = [1, 2, 3]`, behind the scenes you're saying "the name x now refers to this list object", and the list starts with a reference count of 1, held by `x`. When the name stops pointing to it (you assign something else to `x`, use `del x`, or the function where `x` lives returns), the count goes down by one. When it reaches zero, the object is destroyed immediately and its block goes back to available blocks in the pool.

```python
def foo():
    x = [1, 2, 3]   # list refcount = 1 (x)
    y = x           # list refcount = 2 (x and y)
    y = "foo"       # list refcount = 1 (x)
    return y        # function ends, x is gone: refcount = 0, list freed

foo()
```

The **garbage collector** solves a problem that reference counting can't: circular references. When two objects point to each other, their counts never reach zero. 
From time to time, the garbage collector looks at the container objects (lists, dicts, class instances) and finds the ones that can no longer be reached from the rest of the program. Those are freed in that same run. New objects start in gen0, which is checked often, because most objects die young. Objects that survive a collection move to an older generation, which is checked less often.

```python
def foo():
    x = [1, 2, 3]   # list A refcount = 1 (x)
    y = [x]         # list B refcount = 1 (y), list A = 2 (x, B)
    x.append(y)     # list B = 2 (y, A): now A -> B -> A, a cycle

foo()               # x and y are gone: A = 1, B = 1
                    # the next gen0 collection finds A and B unreachable and frees both
```


That's not as deep as I went, but it's enough to get some insights: you don't have full control over freed memory, because the allocator decides what goes back to the OS, but you can control how long a reference lives. A local variable that points to a big object keeps it alive until the function returns. If the function still has work to do after using it, you can `del` it, or pass it directly to the next call, like `summarize(load_file())`. Then it's freed as soon as that call returns.

I've had fun and learned a lot while studying Python Internals. Many of those things are hard to put into words, because when you open the door to understand memory management, there you face another door about how the OS handles the memory allocation, or how Python made free-threading possible, or how the interpreter executes your code, and so on.
It's an enjoyable adventure, and I feel bad I didn't start it sooner.
