# A.D.M.A - Acronyms Dont Mean Anything

Adma is a general purpose allocator for zig with the following features:

- [x] [Slab Allocation strategy](https://en.wikipedia.org/wiki/Slab_allocation)
- [x] Optimized for rapid small memory allocation/releasing
- [x] Reuse of OS provided allocations
- [x] Non-Blocking allocation & free within a thread
- [x] Multithreaded Capable
- [x] Automatic feature reduction for single threaded use
- [x] Safe freeing of memory sent to a different thread

## Getting started

In Zig:

```zig
const adma = @Import("adma");

pub fn example() !void {
    // .initWith using a c allocator
    //const adma_ref = try adma.AdmaAllocator.initWith(std.heap.c_allocator, 0);

    // .init defaults to using std.heap.page_allocator underneath for ease of use
    const adma_ref = adma.AdmaAllocator.init();
    defer adma_ref.deinit();

    const allocator = &adma_ref.allocator;

    var buf = try allocator.alloc(u8, 100);
    defer allocator.free(buf);
}

```

## Usage Notes

- If using adma in a multithreaded context, ensure you `AdmaAllocator.init/deinit`
 in every thread; not pass the allocator pointer to the additional thread
- If using for zig prior to the big allocation interface change, see the branch
called `pre-allocator-revamp`

