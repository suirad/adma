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

/// This struct is used to track allocations that are free'd in different threads than the ones that created them
/// This allows the solo thread based AdmaAllocator's to be used safely in a multithreaded context
const LostAndFound = if (std.builtin.single_threaded == false)
    struct {
        init: bool = false,
        allocator: *Allocator = undefined,
        collector64: Collector = .{},
        collector128: Collector = .{},
        collector256: Collector = .{},
        collector512: Collector = .{},
        collector1024: Collector = .{},
        collector2048: Collector = .{},
        thread_count: usize = 1,

        const Self = @This();

        const Collector = struct {
            list: ArrayList([]u8) = undefined,
            lock: u8 = 1,
        };

        pub fn init(allocator: *Allocator) void {
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
    }
else
// Empty global for single threaded mode
    struct {
        const Self = @This();
        pub inline fn init(a: *Allocator) void {}
        pub inline fn deinit(s: *Self) void {}
        pub inline fn lock(s: *Self, si: u16) void {}
        pub inline fn tryLock(s: *Self, si: u16) ?*ArrayList([]u8) {
            return null;
        }
        pub inline fn unlock(s: *Self, si: u16) void {}
        pub inline fn pickList(s: *Self, si: u16) void {}
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

    /// This is used for checking if this allocator is servicing an allocation or the wrapped allocator
    pub const largest_alloc = 2048;

    /// Initialize with defaults
    pub fn init() *Self {
        return AdmaAllocator.initWith(std.heap.page_allocator, 0) catch unreachable;
    }

    /// Initialize this allocator, passing in an allocator to wrap.
    pub fn initWith(allocator: *Allocator, initial_slabs: usize) !*Self {
        LostAndFound.init(allocator);

        var self = &localAdma;
        if (self.init == true) return self;

        localAdma = Self{
            .allocator = Allocator{
                .allocFn = adma_alloc,
                .resizeFn = adma_resize,
            },
            .wrapped_allocator = allocator,
            .bucket64 = Bucket.init(64, self),
            .bucket128 = Bucket.init(128, self),
            .bucket256 = Bucket.init(256, self),
            .bucket512 = Bucket.init(512, self),
            .bucket1024 = Bucket.init(1024, self),
            .bucket2048 = Bucket.init(2048, self),
            .slab_pool = ArrayList(*Slab).init(allocator),
        };

        // seed slab pool with initial slabs
        try self.seedSlabs(initial_slabs);

        self.init = true;
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
        self.slab_pool.deinit();
        self.init = false;
    }

    /// Adds `size` number of slabs to this threads slab pool
    pub fn seedSlabs(self: *Self, size: usize) !void {
        if (size == 0) return;

        // goofy range
        for (@as([*]void, undefined)[0..size]) |_, i| {
            var slab = try self.wrapped_allocator.create(Slab);
            try self.slab_pool.append(slab);
        }
    }

    /// Take a slab from the slab pool; allocates one if needed
    pub fn fetchSlab(self: *Self) !*Slab {
        var maybe_slab = self.slab_pool.popOrNull();
        if (maybe_slab) |slab| {
            return slab;
        }

        try self.seedSlabs(1);
        return self.slab_pool.pop();
    }

    /// Give a slab back to the slab pool; if pool is full, free the slab
    pub fn releaseSlab(self: *Self, slab: *Slab) !void {
        if (self.slab_pool.items.len < 20) {
            try self.slab_pool.append(slab);
            return;
        }
        self.wrapped_allocator.destroy(slab);
    }

    /// Allocator entrypoint
    fn adma_alloc(this: *Allocator, len: usize, ptr_align: u29, len_align: u29) ![]u8 {
        var self = @fieldParentPtr(Self, "allocator", this);

        if (len == 0) {
            return "";
        } else if (len > largest_alloc) {
            return try self.wrapped_allocator.alloc(u8, len);
        }

        assert(len <= largest_alloc);
        return try self.internal_alloc(len);
    }

    fn adma_resize(this: *Allocator, oldmem: []u8, new_size: usize, len_align: u29) !usize {
        var self = @fieldParentPtr(Self, "allocator", this);

        if (std.builtin.mode == .Debug or std.builtin.mode == .ReleaseSafe)
            if (self != &localAdma)
                @panic("AdmaAllocator pointer passed to another thread; to do this safely, in the new thread init an AdmaAllocator");

        if (oldmem.len == 0 and new_size == 0) {
            //why would you do this
            return 0;
        }

        // handle external sizes
        if (oldmem.len > largest_alloc) {
            if (new_size > largest_alloc or new_size == 0) {
                return try self.wrapped_allocator.callResizeFn(oldmem, new_size, len_align);
            }
            return largest_alloc + 1;
        } else if (oldmem.len == 0 and new_size > largest_alloc) {
            return try self.wrapped_allocator.callResizeFn(oldmem, new_size, len_align);
        }

        if (new_size > largest_alloc)
            return error.OutOfMemory;

        assert(new_size <= largest_alloc);

        return try self.internal_resize(oldmem, new_size);
    }

    /// Select a bucked based on the size given
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

    fn internal_alloc(self: *Self, len: usize) ![]u8 {
        const bucket = self.pickBucket(@intCast(u16, len));

        assert(bucket != null);

        const newchunk = try bucket.?.newChunk();
        return newchunk[0..len];
    }

    fn internal_resize(self: *Self, oldmem: []u8, new_size: usize) !usize {
        const old_bucket = self.pickBucket(@intCast(u16, oldmem.len));
        const new_bucket = self.pickBucket(@intCast(u16, new_size));

        if (oldmem.len == 0) {
            return 0;
        } else if (new_size == 0) {
            _ = old_bucket.?.freeChunk(oldmem, false);
            return 0;
        }

        if (old_bucket == new_bucket)
            return new_size;

        return error.OutOfMemory;
    }
};

/// This structure holds all slabs of a given size and uses them to provide allocations
const Bucket = struct {
    chunk_size: u16,
    parent: *AdmaAllocator,
    slabs: ArrayList(*Slab),

    const Self = @This();

    pub fn init(comptime offset: u16, adma: *AdmaAllocator) Self {
        comptime if (page_size % offset != 0)
            @panic("Offset needs to be 2's complement and smaller than page_size(4096)");

        var slabs = ArrayList(*Slab).init(adma.wrapped_allocator);
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

    /// Fetches a slab from the slab pool and adds it to the internal tracker
    pub fn addSlab(self: *Self) !*Slab {
        var slab = try self.parent.fetchSlab();
        try self.slabs.append(slab);
        return slab.init(self.chunk_size);
    }

    /// Iterates slabs to find an available chunk; if no slabs have space, request a new one from slab pool
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

    /// Iterates tracked slabs and attempts to free the chunk
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

    /// Adds the chunk to the global free list for this chunk_size
    fn freeRemoteChunk(self: *Self, data: []u8) void {
        if (std.builtin.single_threaded)
            @panic("Free'd invalid chunk. Ensure this data is allocated with Adma");

        global_collector.lock(self.chunk_size);
        defer global_collector.unlock(self.chunk_size);

        var list = global_collector.pickList(self.chunk_size);
        list.append(data) catch @panic("Failed to add global chunk");
    }

    /// Casually locks the global freelist for this size; then attempts to free them
    fn tryCollectRemoteChunks(self: *Self) void {
        var list = global_collector.tryLock(self.chunk_size) orelse return;
        defer global_collector.unlock(self.chunk_size);

        if (list.items.len == 0) return;

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

    /// Actively waits to lock the global freelist for this size and attempts to free the chunks
    fn collectRemoteChunks(self: *Self) void {
        if (std.builtin.single_threaded) return;

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

/// Slab slices a doublepage by a specific size and services allocations from it
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

    /// Attempts to service a chunk request
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

    /// Attempts to free a chunk by checking if the data ptr falls within the memory space of this Slabs .data
    pub fn freeChunk(self: *Slab, data: []u8) bool {
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

    /// Calculate the max number of chunks for this slabs chunk_size
    fn max_chunks(self: *const Slab) u16 {
        return @intCast(u16, self.data.len / self.chunk_size);
    }
};
