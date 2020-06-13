const std = @import("std");
const warn = std.debug.warn;
const testing = std.testing;

const adma = @import("adma.zig");

test "Use local adma" {
    // testing.expectEqual(1, 1);
    var a = try adma.AdmaAllocator.init(std.heap.page_allocator);
    defer a.deinit();

    var aa = &a.allocator;
    warn("Trying alloc\n", .{});
    var string = try aa.alloc(u8, 50);
    aa.free(string);
}
