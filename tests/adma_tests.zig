const std = @import("std");
const mem = std.mem;
const page_size = std.mem.page_size;
const warn = std.debug.warn;
const testing = std.testing;

const adma = @import("adma");

test "Use adma" {
    var a = adma.AdmaAllocator.init();
    defer a.deinit();

    var aa = &a.allocator;
    var tmp: [50][]u8 = undefined;

    for (tmp) |_, i| {
        tmp[i] = try aa.alloc(u8, 2000);
    }

    for (tmp) |_, i| {
        aa.free(tmp[i]);
    }
}

test "Resize too large external buffer into adma chunk" {
    var a = adma.AdmaAllocator.init();
    defer a.deinit();
    var aa = &a.allocator;

    var buf = try aa.alloc(u8, 10000); // dont free
    var buf2 = try aa.realloc(buf, 1000);
    testing.expect(buf2.len == adma.AdmaAllocator.largest_alloc + 1);
    aa.free(buf2);
}

test "Resize adma chunk to another adma chunk" {
    var a = adma.AdmaAllocator.init();
    defer a.deinit();
    var aa = &a.allocator;

    var buf = try aa.alloc(u8, 1000); // dont free
    buf = try aa.realloc(buf, 2048);
    testing.expect(buf.len == adma.AdmaAllocator.largest_alloc);
    aa.free(buf);
}

test "Allocate chunk then resize into external buffer" {
    var a = adma.AdmaAllocator.init();
    defer a.deinit();
    var aa = &a.allocator;

    var buf = try aa.alloc(u8, 1000); // dont free
    var buf2 = try aa.alloc(u8, 1000);
    defer aa.free(buf2);

    std.mem.set(u8, buf, 1);
    std.mem.set(u8, buf2, 1);

    var buf3 = try aa.realloc(buf, 10000);
    defer aa.free(buf3);

    testing.expectEqualSlices(u8, buf3[0..1000], buf2);
}

test "Wrapping adma with an arena allocator" {
    var a = adma.AdmaAllocator.init();
    defer a.deinit();

    var arena = std.heap.ArenaAllocator.init(&a.allocator);
    defer arena.deinit();

    var arenaal = &arena.allocator;
    var buf = try arenaal.alloc(u8, 50);
    defer arenaal.free(buf);
}

test "arraylist" {
    var a = adma.AdmaAllocator.init();
    defer a.deinit();
    var aa = &a.allocator;

    var list = std.ArrayList(usize).init(aa);
    defer list.deinit();
    try list.ensureCapacity(5000);
    var x: usize = 0;
    while (x != 10000) : (x += 1) {
        _ = try list.append(x);
    }
}

fn threadFree(buf: []u8) !void {
    var a = adma.AdmaAllocator.init();
    defer a.deinit();
    var aa = &a.allocator;

    aa.free(buf);
}

test "free remote chunk" {
    if (std.builtin.single_threaded == true) return;

    var a = adma.AdmaAllocator.init();
    defer a.deinit();
    var aa = &a.allocator;

    var buf = try aa.alloc(u8, 1000);
    var buf2 = try aa.alloc(u8, 1000);

    var thd = try std.Thread.spawn(buf, threadFree);
    thd.wait();

    var buf3 = try aa.alloc(u8, 1000);
    aa.free(buf2); // should also free buf1
    aa.free(buf3);
}

test "small allocations - free in same order" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    var list = std.ArrayList(*u64).init(std.testing.allocator);
    defer list.deinit();

    var i: usize = 0;
    while (i < 513) : (i += 1) {
        const ptr = try allocator.create(u64);
        try list.append(ptr);
    }

    for (list.items) |ptr| {
        allocator.destroy(ptr);
    }
}

test "small allocations - free in reverse order" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    var list = std.ArrayList(*u64).init(std.testing.allocator);
    defer list.deinit();

    var i: usize = 0;
    while (i < 513) : (i += 1) {
        const ptr = try allocator.create(u64);
        try list.append(ptr);
    }

    while (list.popOrNull()) |ptr| {
        allocator.destroy(ptr);
    }
}

test "large allocations" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    const ptr1 = try allocator.alloc(u64, 42768);
    const ptr2 = try allocator.alloc(u64, 52768);
    allocator.free(ptr1);
    const ptr3 = try allocator.alloc(u64, 62768);
    allocator.free(ptr3);
    allocator.free(ptr2);
}

test "realloc" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    var slice = try allocator.alignedAlloc(u8, @alignOf(u32), 1);
    defer allocator.free(slice);
    slice[0] = 0x12;

    // This reallocation should keep its pointer address.
    const old_slice = slice;
    slice = try allocator.realloc(slice, 2);
    std.testing.expect(old_slice.ptr == slice.ptr);
    std.testing.expect(slice[0] == 0x12);
    slice[1] = 0x34;

    // This requires upgrading to a larger size class
    slice = try allocator.realloc(slice, 17);
    std.testing.expect(slice[0] == 0x12);
    std.testing.expect(slice[1] == 0x34);
}

test "shrink" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    var slice = try allocator.alloc(u8, 20);
    defer allocator.free(slice);

    mem.set(u8, slice, 0x11);

    slice = allocator.shrink(slice, 17);

    for (slice) |b| {
        std.testing.expect(b == 0x11);
    }

    slice = allocator.shrink(slice, 16);

    for (slice) |b| {
        std.testing.expect(b == 0x11);
    }
}

test "large object - grow" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    var slice1 = try allocator.alloc(u8, page_size * 2 - 20);
    defer allocator.free(slice1);

    const old = slice1;
    slice1 = try allocator.realloc(slice1, page_size * 2 - 10);
    std.testing.expect(slice1.ptr == old.ptr);

    slice1 = try allocator.realloc(slice1, page_size * 2);
    std.testing.expect(slice1.ptr == old.ptr);

    slice1 = try allocator.realloc(slice1, page_size * 2 + 1);
}

test "realloc small object to large object" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    var slice = try allocator.alloc(u8, 70);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[60] = 0x34;

    // This requires upgrading to a large object
    const large_object_size = page_size * 2 + 50;
    slice = try allocator.realloc(slice, large_object_size);
    std.testing.expect(slice[0] == 0x12);
    std.testing.expect(slice[60] == 0x34);
}

test "shrink large object to large object" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    var slice = try allocator.alloc(u8, page_size * 2 + 50);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[60] = 0x34;

    slice = try allocator.resize(slice, page_size * 2 + 1);
    std.testing.expect(slice[0] == 0x12);
    std.testing.expect(slice[60] == 0x34);

    slice = allocator.shrink(slice, page_size * 2 + 1);
    std.testing.expect(slice[0] == 0x12);
    std.testing.expect(slice[60] == 0x34);

    slice = try allocator.realloc(slice, page_size * 2);
    std.testing.expect(slice[0] == 0x12);
    std.testing.expect(slice[60] == 0x34);
}

test "shrink large object to large object with larger alignment" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    var debug_buffer: [1000]u8 = undefined;
    const debug_allocator = &std.heap.FixedBufferAllocator.init(&debug_buffer).allocator;

    const alloc_size = page_size * 2 + 50;
    var slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    defer allocator.free(slice);

    const big_alignment: usize = switch (std.Target.current.os.tag) {
        .windows => page_size * 32, // Windows aligns to 64K.
        else => page_size * 2,
    };
    // This loop allocates until we find a page that is not aligned to the big
    // alignment. Then we shrink the allocation after the loop, but increase the
    // alignment to the higher one, that we know will force it to realloc.
    var stuff_to_free = std.ArrayList([]align(16) u8).init(debug_allocator);
    while (mem.isAligned(@ptrToInt(slice.ptr), big_alignment)) {
        try stuff_to_free.append(slice);
        slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    }
    while (stuff_to_free.popOrNull()) |item| {
        allocator.free(item);
    }
    slice[0] = 0x12;
    slice[60] = 0x34;

    slice = try allocator.reallocAdvanced(slice, big_alignment, alloc_size / 2, .exact);
    std.testing.expect(slice[0] == 0x12);
    std.testing.expect(slice[60] == 0x34);
}

test "realloc large object to small object" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    var slice = try allocator.alloc(u8, page_size * 2 + 50);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[16] = 0x34;

    slice = try allocator.realloc(slice, 19);
    std.testing.expect(slice[0] == 0x12);
    std.testing.expect(slice[16] == 0x34);
}

test "non-page-allocator backing allocator" {
    var adm = try adma.AdmaAllocator.initWith(std.testing.allocator, 0);
    defer adm.deinit();
    const allocator = &adm.allocator;

    const ptr = try allocator.create(i32);
    defer allocator.destroy(ptr);
}

test "realloc large object to larger alignment" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    var debug_buffer: [1000]u8 = undefined;
    const debug_allocator = &std.heap.FixedBufferAllocator.init(&debug_buffer).allocator;

    var slice = try allocator.alignedAlloc(u8, 16, page_size * 2 + 50);
    defer allocator.free(slice);

    const big_alignment: usize = switch (std.Target.current.os.tag) {
        .windows => page_size * 32, // Windows aligns to 64K.
        else => page_size * 2,
    };
    // This loop allocates until we find a page that is not aligned to the big alignment.
    var stuff_to_free = std.ArrayList([]align(16) u8).init(debug_allocator);
    while (mem.isAligned(@ptrToInt(slice.ptr), big_alignment)) {
        try stuff_to_free.append(slice);
        slice = try allocator.alignedAlloc(u8, 16, page_size * 2 + 50);
    }
    while (stuff_to_free.popOrNull()) |item| {
        allocator.free(item);
    }
    slice[0] = 0x12;
    slice[16] = 0x34;

    slice = try allocator.reallocAdvanced(slice, 32, page_size * 2 + 100, .exact);
    std.testing.expect(slice[0] == 0x12);
    std.testing.expect(slice[16] == 0x34);

    slice = try allocator.reallocAdvanced(slice, 32, page_size * 2 + 25, .exact);
    std.testing.expect(slice[0] == 0x12);
    std.testing.expect(slice[16] == 0x34);

    slice = try allocator.reallocAdvanced(slice, big_alignment, page_size * 2 + 100, .exact);
    std.testing.expect(slice[0] == 0x12);
    std.testing.expect(slice[16] == 0x34);
}

test "large object shrinks to small but allocation fails during shrink" {
    var failing_allocator = std.testing.FailingAllocator.init(std.heap.page_allocator, 3);
    var adm = try adma.AdmaAllocator.initWith(&failing_allocator.allocator, 0);
    defer adm.deinit();
    const allocator = &adm.allocator;

    var slice = try allocator.alloc(u8, page_size * 2 + 50);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[3] = 0x34;

    // Next allocation will fail in the backing allocator of the GeneralPurposeAllocator

    slice = allocator.shrink(slice, 4);
    std.testing.expect(slice[0] == 0x12);
    std.testing.expect(slice[3] == 0x34);
}

test "objects of size 1024 and 2048" {
    var adm = adma.AdmaAllocator.init();
    defer adm.deinit();
    const allocator = &adm.allocator;

    const slice = try allocator.alloc(u8, 1025);
    const slice2 = try allocator.alloc(u8, 3000);

    allocator.free(slice);
    allocator.free(slice2);
}
