const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;
const page_size = mem.page_size;
const assert = std.debug.assert;

threadlocal var localAdma: AdmaAllocator = undefined;

pub const AdmaAllocator = struct {
    /// Exposed allocator
    allocator: Allocator,
    /// Wrapped allocator
    wrapped_allocator: *Allocator,

    bucket64: Bucket,
    bucket128: Bucket,
    bucket256: Bucket,
    bucket512: Bucket,
    bucket1024: Bucket,
    bucket2048: Bucket,

    page_pool: ArrayList(*Page),

    const Self = @This();
    const largest_alloc = 2048;

    /// Initialize with defaults
    pub fn init() !*Self {
        return try AdmaAllocator.initWith(std.heap.page_allocator, 5);
    }

    /// Initialize this allocator, passing in an allocator to wrap.
    pub fn initWith(allocator: *Allocator, initial_pages: usize) !*Self {
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
            .page_pool = try ArrayList(*Page).initCapacity(allocator, 20),
        };

        // seed page pool with initial pages
        try self.seedPages(initial_pages);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.bucket64.deinit();
        self.bucket128.deinit();
        self.bucket256.deinit();
        self.bucket512.deinit();
        self.bucket1024.deinit();
        self.bucket2048.deinit();

        for (self.page_pool.items) |page| {
            self.wrapped_allocator.destroy(page);
        }
    }

    pub fn seedPages(self: *Self, size: usize) !void {
        // goofy range
        for (@as([*]void, undefined)[0..size]) |_, i| {
            var page = try self.wrapped_allocator.create(Page);
            try self.page_pool.append(page);
        }
    }

    pub fn fetchPage(self: *Self) !*Page {
        var maybe_page = self.page_pool.popOrNull();
        if (maybe_page) |page| {
            return page;
        }

        try self.seedPages(1);
        return self.page_pool.pop();
    }

    pub fn releasePage(self: *Self, page: *Page) !void {
        if (self.page_pool.items.len < 20) {
            try self.page_pool.append(page);
            return;
        }
        self.wrapped_allocator.destroy(page);
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
            if (new_bucket) |bucket| {
                var newchunk = try bucket.newChunk();
                return newchunk[0..new_size];
            } else {
                unreachable;
            }
        } else if (new_size == 0) {
            if (old_bucket) |bucket| {
                bucket.freeChunk(oldmem);
                return "";
            } else {
                unreachable;
            }
        }

        var newchunk = try new_bucket.?.newChunk();
        mem.copy(u8, newchunk, oldmem);
        old_bucket.?.freeChunk(oldmem);

        return newchunk[0..new_size];
    }

    fn internalShrink(self: *Self, oldmem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
        var old_bucket = self.pickBucket(@intCast(u16, oldmem.len));

        if (new_size == 0) {
            if (old_bucket) |bucket| {
                bucket.freeChunk(oldmem);
                return "";
            } else {
                unreachable;
            }
        }

        return oldmem[0..new_size];
    }
};

const Bucket = struct {
    chunk_offset: u16,
    parent: *AdmaAllocator,
    pages: ArrayList(*Page),

    const Self = @This();

    pub fn init(offset: comptime u16, adma: *AdmaAllocator) !Self {
        if (page_size % offset != 0)
            @panic("Offset needs to be 2's complement and smaller than page_size(4096)");

        var pages = try ArrayList(*Page).initCapacity(adma.wrapped_allocator, 10);
        return Self{
            .chunk_offset = offset,
            .parent = adma,
            .pages = pages,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.pages.items) |page| {
            self.parent.wrapped_allocator.destroy(page);
        }
        self.pages.deinit();
    }

    pub fn addPage(self: *Self) !*Page {
        var page = try self.parent.fetchPage();
        try self.pages.append(page);
        return page.init(self.chunk_offset);
    }

    pub fn newChunk(self: *Self) ![]u8 {
        self.collectRemoteChunks();
        for (self.pages.items) |page| {
            var maybe_chunk = page.nextChunk();

            if (maybe_chunk) |chunk| {
                return chunk;
            }
        }

        var page = try self.addPage();
        var chunk = page.nextChunk() orelse unreachable;
        return chunk;
    }

    pub fn freeChunk(self: *Self, data: []u8) void {
        self.collectRemoteChunks();
        for (self.pages.items) |page, i| {
            if (page.freeChunk(data)) {
                if (page.state == .Empty) {
                    _ = self.pages.swapRemove(i);
                    self.parent.releasePage(page) catch @panic("Failed to release page to page_pool");
                }
                return;
            }
        }

        @panic("Free'd data that no page owns");
    }

    pub fn freeRemoteChunk(self: *Self, data: []u8) void {
        // spinlock remote chunks
        // defer unlock
        // append to list
    }

    fn collectRemoteChunks(self: *Self) void {
        // try lock remote chunks
        // if failed then return
        // defer unlock
        // iterate remote chunks and free
    }
};

const PageState = enum(u8) {
    Empty = 0,
    Partial,
    Full,
};

const Page = struct {
    state: PageState,
    chunk_size: u16,
    next_chunk: u16,
    chunks_left: u16,
    page_start: usize,
    page_end: usize,
    meta: [128]u8,
    data: [page_size * 2]u8,

    pub fn init(self: *Page, chunk_size: u16) *Page {
        self.state = .Empty;
        self.chunk_size = chunk_size;
        self.next_chunk = 0;
        self.chunks_left = self.max_chunks();
        self.page_start = @ptrToInt(&self.data[0]);
        self.page_end = @ptrToInt(&self.data[self.data.len - 1]);
        mem.set(u8, &self.meta, 0);
        return self;
    }

    fn max_chunks(self: *const Page) u16 {
        return @intCast(u16, self.data.len / self.chunk_size);
    }

    /// Next chunk or null
    pub fn nextChunk(self: *Page) ?[]u8 {
        if (self.state == .Full) return null;

        var indx = self.next_chunk;
        const max = self.max_chunks();

        while (true) : (indx = if (indx + 1 == max) 0 else indx + 1) {
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
    pub fn freeChunk(self: *Page, data: []u8) bool {
        // if data not in this page range, then false
        //NOTE: replace with bitmask
        const data_start = @ptrToInt(data.ptr);
        if ((self.page_start <= data_start and self.page_end > data_start) == false) {
            return false;
        }

        const meta_index = (data_start - self.page_start) / self.chunk_size;

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
