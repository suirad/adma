const std = @import("std");
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const Mutex = std.mutex.Mutex;
const page_alloc = std.heap.page_allocator;

const AdmaAllocator = @import("adma").AdmaAllocator;

const debug_print = false;
const print = if (debug_print) std.debug.print else fakeprint;

fn fakeprint(_: []const u8, __: anytype) void {}

threadlocal var adma_alloc: ?*AdmaAllocator = null;

var lib_init = false;
var allocations: ArrayList([]u8) = undefined;
var mutex = Mutex{};

export fn malloc(size: usize) ?[*]u8 {
    const adma = adma_alloc orelse blk: {
        adma_alloc = AdmaAllocator.init();
        assert(adma_alloc != null);
        allocations = ArrayList([]u8).init(&adma_alloc.?.allocator);
        std.debug.print("Initialized Adma Allocator\n", .{});
        break :blk adma_alloc.?;
    };

    var lock = mutex.acquire();
    defer lock.release();

    var data = adma.allocator.alloc(u8, size) catch @panic("Failed to allocate");
    //var data = page_alloc.alloc(u8, size) catch @panic("Failed to allocate");

    allocations.append(data) catch @panic("Failed to track allocation");

    print("Malloced {} ask size: {} | given size: {}\n", .{ data.ptr, size, data.len });
    return data.ptr;
}

export fn free(raw_ptr: ?[*]u8) void {
    const ptr = raw_ptr orelse return;

    const adma = adma_alloc orelse @panic("Attempt to free without initing adma");

    print("Freeing pointer: {}\n", .{ptr});

    var lock = mutex.acquire();
    defer lock.release();

    for (allocations.items) |item, i| {
        if (ptr == item.ptr) {
            print("Found and freeing: {}\n", .{ptr});
            adma.allocator.free(item);
            //page_alloc.free(item);
            _ = allocations.swapRemove(i);
            return;
        }
    }

    @panic("Attempt to free unknown pointer");
}

export fn calloc(num: usize, size: usize) ?[*]u8 {
    const tsize = num * size;
    if (tsize == 0) return null;

    const may_ptr = malloc(tsize);

    print("Calloced {} bytes: {}\n", .{ tsize, may_ptr });
    if (may_ptr) |ptr| {
        @memset(ptr, 0, tsize);
    }
    return may_ptr;
}

export fn realloc(rptr: ?[*]u8, size: usize) ?[*]u8 {
    const ptr = rptr orelse return null;
    const adma = adma_alloc orelse return null;

    var lock = mutex.acquire();
    defer lock.release();

    for (allocations.items) |item, i| {
        if (ptr == item.ptr) {
            print("Reallocing ptr: {} | oldsize: {} | newsize: {}\n", .{ ptr, item.len, size });
            const newdata = adma.allocator.realloc(item, size) catch
            //const newdata = page_alloc.realloc(item, size) catch
                @panic("Failed to realloc");
            allocations.items[i] = newdata;
            assert(newdata.len == size);
            return newdata.ptr;
        }
    }
    @panic("Failed to realloc");
}

export fn memalign(alignment: usize, size: usize) ?[*]u8 {
    std.debug.print("Memalign called.\n", .{});
    return null;
}

export fn exit(code: u8) void {
    std.debug.print("\nGoodbye from exit!\n", .{});
    cleanup();
    std.os.exit(code);
}

export fn abort() void {
    std.debug.print("\nGoodbye from abort!\n", .{});
    cleanup();
    std.os.abort();
}

fn cleanup() void {
    const adma = adma_alloc orelse return;

    for (allocations.items) |item| {
        adma.allocator.free(item);
    }

    print("Cleaned up allocations\n", .{});

    allocations.deinit();
    print("Deinit allocations\n", .{});

    adma.deinit();
    std.debug.print("Deinit adma\n", .{});
}
