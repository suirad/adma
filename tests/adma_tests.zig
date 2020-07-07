const std = @import("std");
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
