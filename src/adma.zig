const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;
const page_size = 4096;

threadlocal var localAdma: AdmaAllocator = undefined;

pub const AdmaAllocator = struct {
    /// Exposed allocator
    allocator: Allocator,
    /// Wrapped allocator
    wrapped_allocator: *Allocator,

    bucket32: Bucket, // cap 128
    bucket64: Bucket, // cap 64
    bucket128: Bucket, // cap 32
    bucket256: Bucket, // cap 16
    bucket512: Bucket, // cap 8

    const Self = @This();

    /// Initialize this allocator, passing in an allocator to wrap.
    pub fn init(allocator: *Allocator) !*Self {
        localAdma = Self{
            .allocator = Allocator{
                .shrinkFn = shrink,
                .reallocFn = realloc,
            },
            .wrapped_allocator = allocator,
            .bucket32 = try Bucket.init(32, allocator),
            .bucket64 = try Bucket.init(64, allocator),
            .bucket128 = try Bucket.init(128, allocator),
            .bucket256 = try Bucket.init(256, allocator),
            .bucket512 = try Bucket.init(512, allocator),
        };
        return &localAdma;
    }

    pub fn deinit(self: *Self) void {
        self.bucket32.deinit();
        self.bucket64.deinit();
        self.bucket128.deinit();
        self.bucket256.deinit();
        self.bucket512.deinit();
    }

    fn realloc(this: *Allocator, oldmem: []u8, old_align: u29, new_size: usize, new_align: u29) ![]u8 {
        var self = @fieldParentPtr(Self, "allocator", this);
        if (new_size > 512) {
            return try self.wrappedRealloc(oldmem, old_align, new_size, new_align);
        }
        return try self.internalRealloc(oldmem, old_align, new_size, new_align);
    }

    fn shrink(this: *Allocator, oldmem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
        var self = @fieldParentPtr(AdmaAllocator, "allocator", this);
        if (oldmem.len > 512) {
            return self.wrappedShrink(oldmem, old_align, new_size, new_align);
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
            1...31 => &self.bucket32,
            32...63 => &self.bucket64,
            64...127 => &self.bucket128,
            128...255 => &self.bucket256,
            256...511 => &self.bucket512,
            else => null,
        };
    }

    fn internalRealloc(self: *Self, oldmem: []u8, old_align: u29, new_size: usize, new_align: u29) ![]u8 {
        // get old bucket and new bucket
        var old_bucket = self.pickBucket(@intCast(u16, oldmem.len));
        var new_bucket = self.pickBucket(@intCast(u16, new_size));

        if (oldmem.len == 0) {
            if (new_bucket) |bucket| {
                var newchunk = try bucket.newChunk();
                return newchunk[0..new_size];
            } else {
                unreachable;
            }
        }

        if (new_size == 0) {
            if (old_bucket) |bucket| {
                bucket.freeChunk(oldmem);
                return "";
            } else {
                unreachable;
            }
        }

        if (new_size < oldmem.len) {
            return oldmem[0..new_size];
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
    backup_alloc: *Allocator,
    pages: ArrayList(*Page),

    const Self = @This();

    pub fn init(offset: comptime u16, allocator: *Allocator) !Self {
        if (page_size % offset != 0)
            @panic("Offset needs to be 2's complement and smaller than page_size(4096)");

        var pages = try ArrayList(*Page).initCapacity(allocator, 10);
        return Self{
            .chunk_offset = offset,
            .backup_alloc = allocator,
            .pages = pages,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.pages.items) |page| {
            self.backup_alloc.destroy(page);
        }
        self.pages.deinit();
    }

    pub fn addPage(self: *Self) !*Page {
        var page = try self.backup_alloc.create(Page);
        try self.pages.append(page);
        return page.init(self.chunk_offset);
    }

    pub fn newChunk(self: *Self) ![]u8 {
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
        for (self.pages.items) |page, i| {
            if (page.freeChunk(data)) {
                // if Empty, pop page from list and free it
                if (page.state == .Empty) {
                    _ = self.pages.swapRemove(i);
                    self.backup_alloc.destroy(page);
                }
                return;
            }
        }
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
    next_chunk: u8,
    chunks_left: u8,
    data: [page_size]u8,

    pub fn init(self: *Page, chunk_size: u16) *Page {
        self.state = .Empty;
        self.chunk_size = chunk_size;
        self.next_chunk = 0;
        self.chunks_left = self.max_chunks();
        mem.set(u8, self.data[0..self.data.len], 0);
        return self;
    }

    fn max_chunks(self: *Page) u8 {
        return @intCast(u8, page_size / self.chunk_size);
    }

    /// Next chunk or null
    pub fn nextChunk(self: *Page) ?[]u8 {
        if (self.state == .Full) return null;

        // use chunk_size to cast a 2d slice to iterate
        var indx = self.next_chunk;
        const max = self.max_chunks();

        while (true) : (indx = if (indx + 1 == max) 0 else indx + 1) {
            std.debug.warn("size: {}, indx: {}", .{ self.chunk_size, indx });
            const start = self.chunk_size * indx;
            var chunk = self.data[start .. start + self.chunk_size - 1];
            if (chunk[0] == 0) {
                chunk[0] = 1; // mark first byte that this chunk is in use

                self.next_chunk = if (indx + 1 == max) 0 else indx + 1;
                self.chunks_left -= 1;

                if (self.state == .Empty) {
                    self.state = .Partial;
                } else if (self.state == .Partial and self.chunks_left == 0) {
                    self.state = .Full;
                }

                return chunk[1 .. chunk.len - 1];
            }
        }
    }

    /// free a chunk, returns if it was successful or not
    pub fn freeChunk(self: *Page, data: []u8) bool {
        // if data not in this page range, then false
        //TODO: replace with bitmask
        if ((@ptrToInt(&self.data[0]) <= @ptrToInt(data.ptr) and @ptrToInt(&self.data[self.data.len - 1]) > @ptrToInt(data.ptr)) == false) {
            return false;
        }

        var chunk = (data.ptr - 1)[0 .. self.chunk_size - 1];

        chunk[0] = 0;

        self.chunks_left += 1;
        if (self.state == .Full) {
            self.state = .Partial;
        } else if (self.state == .Partial and self.chunks_left == self.max_chunks()) {
            self.state = .Empty;
        }

        return true;
    }
};
