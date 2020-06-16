const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;
const page_size = mem.page_size;
const assert = std.debug.assert;

/// Global structure to hold allocations that leave their origining thread
/// Not directly accessible
var global_collector: LostAndFound = .{};

/// Every thread has its own allocator instance, that needs to be initialized individually
/// Subsequent calls to init return a pointer to the same instance
threadlocal var localAdma: AdmaAllocator = undefined;

///
const LostAndFound = struct {
    init: bool = false,
    allocator: *Allocator = undefined,
    collector64: Collector = .{ .list = undefined },
    collector128: Collector = .{ .list = undefined },
    collector256: Collector = .{ .list = undefined },
    collector512: Collector = .{ .list = undefined },
    collector1024: Collector = .{ .list = undefined },
    collector2048: Collector = .{ .list = undefined },
    thread_count: usize = 1,

    const Self = @This();

    const Collector = struct {
        list: ArrayList([]u8),
        lock: u8 = 1,
    };

    pub fn init(allocator: *Allocator) !void {
        if (global_collector.init == true) {
            _ = @atomicRmw(usize, &global_collector.thread_count, .Add, 1, .SeqCst);
            return;
        }
        global_collector.init = true;
        global_collector.allocator = allocator;
        global_collector.collector64.list = ArrayList([]u8).init(allocator);
        global_collector.collector128.list = ArrayList([]u8).init(allocator);
        global_collector.collector256.list = ArrayList([]u8).init(allocator);
        global_collector.collector512.list = ArrayList([]u8).init(allocator);
        global_collector.collector1024.list = ArrayList([]u8).init(allocator);
        global_collector.collector2048.list = ArrayList([]u8).init(allocator);
        global_collector.thread_count = 1;
    }

    pub fn deinit(self: *Self) void {
        const count = @atomicRmw(usize, &self.thread_count, .Sub, 1, .SeqCst);
        if (count > 1) return;

        // check for leaks and deinit all lists
        assert(self.collector64.list.items.len == 0); // chunk was not collected by a thread
        self.collector64.list.deinit();
        assert(self.collector128.list.items.len == 0); // chunk was not collected by a thread
        self.collector128.list.deinit();
        assert(self.collector256.list.items.len == 0); // chunk was not collected by a thread
        self.collector256.list.deinit();
        assert(self.collector512.list.items.len == 0); // chunk was not collected by a thread
        self.collector512.list.deinit();
        assert(self.collector1024.list.items.len == 0); // chunk was not collected by a thread
        self.collector1024.list.deinit();
        assert(self.collector2048.list.items.len == 0); // chunk was not collected by a thread
        self.collector2048.list.deinit();
        self.init = false;
    }

    pub fn lock(self: *Self, list_size: u16) void {
        const this = self.pickLock(list_size);
        while (true) {
            if (@atomicRmw(u8, this, .Xchg, 0, .AcqRel) == 1) {
                break;
            }
        }
    }

    pub fn tryLock(self: *Self, list_size: u16) ?*ArrayList([]u8) {
        const this = self.pickLock(list_size);
        const is_locked = @atomicRmw(u8, this, .Xchg, 0, .AcqRel) == 1;

        if (is_locked == false) {
            return null;
        }

        const list = self.pickList(list_size);
        if (is_locked and list.items.len == 0) {
            @atomicStore(u8, this, 1, .Release);
            return null;
        }

        return list;
    }

    pub fn unlock(self: *Self, list_size: u16) void {
        const this = self.pickLock(list_size);
        @atomicStore(u8, this, 1, .Release);
    }

    pub fn pickList(self: *Self, list_size: u16) *ArrayList([]u8) {
        switch (list_size) {
            64 => return &self.collector64.list,
            128 => return &self.collector128.list,
            256 => return &self.collector256.list,
            512 => return &self.collector512.list,
            1024 => return &self.collector1024.list,
            2048 => return &self.collector2048.list,
            else => @panic("Invalid list size"),
        }
    }

    fn pickLock(self: *Self, list_size: u16) *u8 {
        switch (list_size) {
            64 => return &self.collector64.lock,
            128 => return &self.collector128.lock,
            256 => return &self.collector256.lock,
            512 => return &self.collector512.lock,
            1024 => return &self.collector1024.lock,
            2048 => return &self.collector2048.lock,
            else => @panic("Invalid lock size"),
        }
    }
};

pub const AdmaAllocator = struct {
    init: bool = false,
    /// Exposed allocator
    allocator: Allocator,
    /// Wrapped allocator; should be a global allocator like page_allocator or c_allocator
    wrapped_allocator: *Allocator,

    bucket64: Bucket,
    bucket128: Bucket,
    bucket256: Bucket,
    bucket512: Bucket,
    bucket1024: Bucket,
    bucket2048: Bucket,

    slab_pool: ArrayList(*Slab),

    const Self = @This();
    const largest_alloc = 2048;

    /// Initialize with defaults
    pub fn init() !*Self {
        return try AdmaAllocator.initWith(std.heap.page_allocator, 0);
    }

    /// Initialize this allocator, passing in an allocator to wrap.
    pub fn initWith(allocator: *Allocator, initial_slabs: usize) !*Self {
        try LostAndFound.init(allocator);

        var self = &localAdma;
        localAdma = Self{
            .allocator = Allocator{
                .shrinkFn = shrink,
                .reallocFn = realloc,
            },
            .wrapped_allocator = allocator,
            .bucket64 = try Bucket.init(64, self),
            .bucket128 = try Bucket.init(128, self),
            .bucket256 = try Bucket.init(256, self),
            .bucket512 = try Bucket.init(512, self),
            .bucket1024 = try Bucket.init(1024, self),
            .bucket2048 = try Bucket.init(2048, self),
            .slab_pool = try ArrayList(*Slab).initCapacity(allocator, 20),
        };

        // seed slab pool with initial slabs
        try self.seedSlabs(initial_slabs);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.bucket64.deinit();
        self.bucket128.deinit();
        self.bucket256.deinit();
        self.bucket512.deinit();
        self.bucket1024.deinit();
        self.bucket2048.deinit();
        global_collector.deinit();

        for (self.slab_pool.items) |slab| {
            self.wrapped_allocator.destroy(slab);
        }
    }

    pub fn seedSlabs(self: *Self, size: usize) !void {
        if (size == 0) return;

        // goofy range
        for (@as([*]void, undefined)[0..size]) |_, i| {
            var slab = try self.wrapped_allocator.create(Slab);
            try self.slab_pool.append(slab);
        }
    }

    pub fn fetchSlab(self: *Self) !*Slab {
        var maybe_slab = self.slab_pool.popOrNull();
        if (maybe_slab) |slab| {
            return slab;
        }

        try self.seedSlabs(1);
        return self.slab_pool.pop();
    }

    pub fn releaseSlab(self: *Self, slab: *Slab) !void {
        if (self.slab_pool.items.len < 20) {
            try self.slab_pool.append(slab);
            return;
        }
        self.wrapped_allocator.destroy(slab);
    }

    fn realloc(this: *Allocator, oldmem: []u8, old_align: u29, new_size: usize, new_align: u29) ![]u8 {
        var self = @fieldParentPtr(Self, "allocator", this);

        if (oldmem.len == 0 and new_size == 0) {
            //why would you do this
            return "";
        } else if (oldmem.len == 0 and new_size > largest_alloc) {
            return try self.wrappedRealloc(oldmem, old_align, new_size, new_align);
        } else if (oldmem.len > largest_alloc and (new_size > largest_alloc or new_size == 0)) {
            return try self.wrappedRealloc(oldmem, old_align, new_size, new_align);
        } else if (oldmem.len > largest_alloc and new_size <= largest_alloc) {
            var chunk = try self.allocator.alloc(u8, new_size);
            mem.copy(u8, chunk, oldmem[0 .. chunk.len - 1]);
            self.wrapped_allocator.free(oldmem);
            return chunk;
        } else if (oldmem.len <= largest_alloc and new_size > largest_alloc) {
            var newbuf = try self.wrapped_allocator.alloc(u8, new_size);
            mem.copy(u8, newbuf, oldmem);
            self.allocator.free(oldmem);
            return newbuf;
        }

        assert(new_size <= largest_alloc);
        return try self.internalRealloc(oldmem, old_align, new_size, new_align);
    }

    fn shrink(this: *Allocator, oldmem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
        var self = @fieldParentPtr(AdmaAllocator, "allocator", this);
        if (oldmem.len > largest_alloc and new_size == 0) {
            self.wrapped_allocator.free(oldmem);
            return "";
        } else if (oldmem.len > largest_alloc and new_size < largest_alloc) {
            var chunk = self.allocator.alloc(u8, new_size) catch @panic("Failed to resize external buffer");
            mem.copy(u8, chunk, oldmem[0 .. chunk.len - 1]);
            self.wrapped_allocator.free(oldmem);
            return chunk;
        }
        return self.internalShrink(oldmem, old_align, new_size, new_align);
    }

    inline fn wrappedRealloc(self: *Self, oldmem: []u8, old_align: u29, new_size: usize, new_align: u29) ![]u8 {
        return try self.wrapped_allocator.reallocFn(self.wrapped_allocator, oldmem, old_align, new_size, new_align);
    }

    inline fn wrappedShrink(self: *Self, oldmem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
        return self.wrapped_allocator.shrinkFn(self.wrapped_allocator, oldmem, old_align, new_align, new_align);
    }

    fn pickBucket(self: *Self, size: u16) ?*Bucket {
        return switch (size) {
            1...64 => &self.bucket64,
            65...128 => &self.bucket128,
            129...256 => &self.bucket256,
            257...512 => &self.bucket512,
            513...1024 => &self.bucket1024,
            1025...2048 => &self.bucket2048,
            else => null,
        };
    }

    fn internalRealloc(self: *Self, oldmem: []u8, old_align: u29, new_size: usize, new_align: u29) ![]u8 {
        var old_bucket = self.pickBucket(@intCast(u16, oldmem.len));
        var new_bucket = self.pickBucket(@intCast(u16, new_size));

        if (oldmem.len == 0) {
            var newchunk = try new_bucket.?.newChunk();
            return newchunk[0..new_size];
        } else if (new_size == 0) {
            _ = old_bucket.?.freeChunk(oldmem, false);
            return "";
        }

        var newchunk = try new_bucket.?.newChunk();
        mem.copy(u8, newchunk, oldmem);
        _ = old_bucket.?.freeChunk(oldmem, false);

        return newchunk[0..new_size];
    }

    fn internalShrink(self: *Self, oldmem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
        var old_bucket = self.pickBucket(@intCast(u16, oldmem.len));
        var new_bucket = self.pickBucket(@intCast(u16, new_size));

        if (new_size == 0) {
            _ = old_bucket.?.freeChunk(oldmem, false);
            return "";
        }

        var newchunk = new_bucket.?.newChunk() catch @panic("Failed to safely shrink");
        mem.copy(u8, newchunk, oldmem[0 .. newchunk.len - 1]);
        _ = old_bucket.?.freeChunk(oldmem, false);

        return newchunk[0..new_size];
    }
};

const Bucket = struct {
    chunk_size: u16,
    parent: *AdmaAllocator,
    slabs: ArrayList(*Slab),

    const Self = @This();

    pub fn init(comptime offset: u16, adma: *AdmaAllocator) !Self {
        comptime if (page_size % offset != 0)
            @panic("Offset needs to be 2's complement and smaller than page_size(4096)");

        var slabs = try ArrayList(*Slab).initCapacity(adma.wrapped_allocator, 10);
        return Self{
            .chunk_size = offset,
            .parent = adma,
            .slabs = slabs,
        };
    }

    pub fn deinit(self: *Self) void {
        self.collectRemoteChunks();

        for (self.slabs.items) |slab| {
            self.parent.wrapped_allocator.destroy(slab);
        }
        self.slabs.deinit();
    }

    pub fn addSlab(self: *Self) !*Slab {
        var slab = try self.parent.fetchSlab();
        try self.slabs.append(slab);
        return slab.init(self.chunk_size);
    }

    pub fn newChunk(self: *Self) ![]u8 {
        for (self.slabs.items) |slab| {
            var maybe_chunk = slab.nextChunk();

            if (maybe_chunk) |chunk| {
                return chunk;
            }
        }

        var slab = try self.addSlab();
        var chunk = slab.nextChunk() orelse unreachable;
        return chunk;
    }

    pub fn freeChunk(self: *Self, data: []u8, remote: bool) bool {
        if (remote == false) {
            self.tryCollectRemoteChunks();
        }

        for (self.slabs.items) |slab, i| {
            if (slab.freeChunk(data)) {
                if (slab.state == .Empty) {
                    _ = self.slabs.swapRemove(i);
                    self.parent.releaseSlab(slab) catch @panic("Failed to release slab to slab_pool");
                }
                return true;
            }
        }

        if (remote == false) {
            self.freeRemoteChunk(data);
        }
        return false;
    }

    fn freeRemoteChunk(self: *Self, data: []u8) void {
        global_collector.lock(self.chunk_size);
        defer global_collector.unlock(self.chunk_size);

        var list = global_collector.pickList(self.chunk_size);
        list.append(data) catch @panic("Failed to add global chunk");
    }

    fn tryCollectRemoteChunks(self: *Self) void {
        var list = global_collector.tryLock(self.chunk_size) orelse return;
        defer global_collector.unlock(self.chunk_size);

        // if freeChunk successful then restart list iteration
        outer: while (true) {
            for (list.items) |chunk, i| {
                if (self.freeChunk(chunk, true) == true) {
                    _ = list.swapRemove(i);
                    continue :outer;
                }
            }
            break;
        }
    }
    fn collectRemoteChunks(self: *Self) void {
        global_collector.lock(self.chunk_size);
        defer global_collector.unlock(self.chunk_size);

        var list = global_collector.pickList(self.chunk_size);
        outer: while (true) {
            for (list.items) |chunk, i| {
                if (self.freeChunk(chunk, true) == true) {
                    _ = list.swapRemove(i);
                    continue :outer;
                }
            }
            break;
        }
    }
};

const SlabState = enum(u8) {
    Empty = 0,
    Partial,
    Full,
};

const Slab = struct {
    state: SlabState,
    chunk_size: u16,
    next_chunk: u16,
    chunks_left: u16,
    slab_start: usize,
    slab_end: usize,
    meta: [128]u8,
    data: [page_size * 2]u8,

    pub fn init(self: *Slab, chunk_size: u16) *Slab {
        self.state = .Empty;
        self.chunk_size = chunk_size;
        self.next_chunk = 0;
        self.chunks_left = self.max_chunks();
        self.slab_start = @ptrToInt(&self.data[0]);
        self.slab_end = @ptrToInt(&self.data[self.data.len - 1]);
        mem.set(u8, &self.meta, 0);
        return self;
    }

    fn max_chunks(self: *const Slab) u16 {
        return @intCast(u16, self.data.len / self.chunk_size);
    }

    /// Next chunk or null
    pub fn nextChunk(self: *Slab) ?[]u8 {
        if (self.state == .Full) return null;

        var indx = self.next_chunk;
        const max = self.max_chunks();

        while (true) : (indx = if (indx >= max or indx + 1 >= max) 0 else indx + 1) {
            if (self.meta[indx] == 1) {
                continue;
            }

            const start = self.chunk_size * indx;
            const end = start + self.chunk_size;

            assert(indx < max);
            assert(start < self.data.len);
            assert(end <= self.data.len);

            var chunk = self.data[start..end];

            self.meta[indx] = 1;

            self.next_chunk = indx;
            self.chunks_left -= 1;

            if (self.state == .Empty) {
                self.state = .Partial;
            } else if (self.state == .Partial and self.chunks_left == 0) {
                self.state = .Full;
            }

            mem.set(u8, chunk, 0);
            return chunk;
        }
    }

    /// free a chunk, returns if it was successful or not
    pub fn freeChunk(self: *Slab, data: []u8) bool {
        // if data not in this slab range, then false
        //NOTE: replace with bitmask
        const data_start = @ptrToInt(data.ptr);
        if ((self.slab_start <= data_start and self.slab_end > data_start) == false) {
            return false;
        }

        const meta_index = (data_start - self.slab_start) / self.chunk_size;

        self.meta[meta_index] = 0;
        self.chunks_left += 1;

        if (self.state == .Full) {
            self.state = .Partial;
        } else if (self.state == .Partial and self.chunks_left == self.max_chunks()) {
            self.state = .Empty;
        }

        return true;
    }
};
