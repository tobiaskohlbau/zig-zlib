const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("zlib.h");
    @cInclude("stddef.h");
});

const alignment = @alignOf(c.max_align_t);
const Allocator = std.mem.Allocator;

pub const Error = error{
    StreamEnd,
    NeedDict,
    Errno,
    StreamError,
    DataError,
    MemError,
    BufError,
    VersionError,
    OutOfMemory,
    Unknown,
};

pub fn errorFromInt(val: c_int) Error {
    return switch (val) {
        c.Z_STREAM_END => error.StreamEnd,
        c.Z_NEED_DICT => error.NeedDict,
        c.Z_ERRNO => error.Errno,
        c.Z_STREAM_ERROR => error.StreamError,
        c.Z_DATA_ERROR => error.DataError,
        c.Z_MEM_ERROR => error.MemError,
        c.Z_BUF_ERROR => error.BufError,
        c.Z_VERSION_ERROR => error.VersionError,
        else => error.Unknown,
    };
}

// method is copied from pfg's https://gist.github.com/pfgithub/65c13d7dc889a4b2ba25131994be0d20
// we have a header for each allocation that records the length, which we need
// for the allocator. Assuming that there aren't many small allocations this is
// acceptable overhead.
const magic_value = 0x1234;
const ZallocHeader = struct {
    magic: usize,
    size: usize,

    const size_of_aligned = (std.math.divCeil(usize, @sizeOf(ZallocHeader), alignment) catch unreachable) * alignment;
};

comptime {
    if (@alignOf(ZallocHeader) > alignment) {
        @compileError("header has incorrect alignment");
    }
}

fn zalloc(private: ?*anyopaque, items: c_uint, size: c_uint) callconv(.C) ?*anyopaque {
    if (private == null)
        return null;

    const allocator = @as(*Allocator, @ptrCast(@alignCast(private.?)));
    var buf = allocator.alloc(u8, ZallocHeader.size_of_aligned + (items * size)) catch return null;
    const header = @as(*ZallocHeader, @ptrCast(@alignCast(buf.ptr)));
    header.* = .{
        .magic = magic_value,
        .size = items * size,
    };

    return buf[ZallocHeader.size_of_aligned..].ptr;
}

fn zfree(private: ?*anyopaque, addr: ?*anyopaque) callconv(.C) void {
    if (private == null)
        return;

    const allocator = @as(*Allocator, @ptrCast(@alignCast(private.?)));
    const header = @as(*ZallocHeader, @ptrFromInt(@intFromPtr(addr.?) - ZallocHeader.size_of_aligned));
    if (builtin.mode != .ReleaseFast) {
        if (header.magic != magic_value)
            @panic("magic value is incorrect");
    }

    var buf: []align(alignment) u8 = undefined;
    buf.ptr = @as([*]align(alignment) u8, @ptrCast(@alignCast(header)));
    buf.len = ZallocHeader.size_of_aligned + header.size;
    allocator.free(buf);
}

pub const gzip = struct {
    pub fn compressor(allocator: Allocator, writer: anytype) Error!Compressor(@TypeOf(writer)) {
        return Compressor(@TypeOf(writer)).init(allocator, writer);
    }

    pub fn Compressor(comptime WriterType: type) type {
        return struct {
            allocator: Allocator,
            stream: *c.z_stream,
            inner: WriterType,

            const Self = @This();
            const WriterError = Error || WriterType.Error;
            const Writer = std.io.Writer(*Self, WriterError, write);

            pub fn init(allocator: Allocator, inner_writer: WriterType) !Self {
                var ret = Self{
                    .allocator = allocator,
                    .stream = undefined,
                    .inner = inner_writer,
                };

                ret.stream = try allocator.create(c.z_stream);
                errdefer allocator.destroy(ret.stream);

                // if the user provides an allocator zlib uses an opaque pointer for
                // custom malloc an free callbacks, this requires pinning, so we use
                // the allocator to allocate the Allocator struct on the heap
                const pinned = try allocator.create(Allocator);
                errdefer allocator.destroy(pinned);

                pinned.* = allocator;
                ret.stream.@"opaque" = pinned;
                ret.stream.zalloc = zalloc;
                ret.stream.zfree = zfree;

                const rc = c.deflateInit2(ret.stream, c.Z_DEFAULT_COMPRESSION, c.Z_DEFLATED, c.MAX_WBITS + 16, 8, c.Z_DEFAULT_STRATEGY);
                return if (rc == c.Z_OK) ret else errorFromInt(rc);
            }

            pub fn deinit(self: *Self) void {
                const pinned = @as(*Allocator, @ptrCast(@alignCast(self.stream.@"opaque".?)));
                _ = c.deflateEnd(self.stream);
                self.allocator.destroy(pinned);
                self.allocator.destroy(self.stream);
            }

            pub fn flush(self: *Self) !void {
                var tmp: [4096]u8 = undefined;
                while (true) {
                    self.stream.next_out = &tmp;
                    self.stream.avail_out = tmp.len;
                    const rc = c.deflate(self.stream, c.Z_FINISH);
                    if (rc != c.Z_STREAM_END)
                        return errorFromInt(rc);

                    if (self.stream.avail_out != 0) {
                        const n = tmp.len - self.stream.avail_out;
                        try self.inner.writeAll(tmp[0..n]);
                        break;
                    } else try self.inner.writeAll(&tmp);
                }
            }

            pub fn write(self: *Self, buf: []const u8) WriterError!usize {
                var tmp: [4096]u8 = undefined;

                self.stream.next_in = @as([*]u8, @ptrFromInt(@intFromPtr(buf.ptr)));
                self.stream.avail_in = @intCast(buf.len);

                while (true) {
                    self.stream.next_out = &tmp;
                    self.stream.avail_out = tmp.len;
                    const rc = c.deflate(self.stream, c.Z_PARTIAL_FLUSH);
                    if (rc != c.Z_OK)
                        return errorFromInt(rc);

                    if (self.stream.avail_out != 0) {
                        const n = tmp.len - self.stream.avail_out;
                        try self.inner.writeAll(tmp[0..n]);
                        break;
                    } else try self.inner.writeAll(&tmp);
                }

                return buf.len - self.stream.avail_in;
            }

            pub fn writer(self: *Self) Writer {
                return .{ .context = self };
            }
        };
    }
};

test "compress gzip with zig interface" {
    const allocator = std.testing.allocator;
    const FifoType = std.fifo.LinearFifo(u8, .Dynamic);
    var fifo = FifoType.init(allocator);
    defer fifo.deinit();

    const input = @embedFile("rfc1951.txt");
    var compressor = try gzip.compressor(allocator, fifo.writer());
    defer compressor.deinit();

    const writer = compressor.writer();
    try writer.writeAll(input);
    try compressor.flush();

    const actual: []u8 = try allocator.alloc(u8, std.math.maxInt(usize));
    var buffer = std.io.fixedBufferStream(actual);
    defer allocator.free(actual);

    try std.compress.gzip.decompress(fifo.reader(), buffer.writer());

    try std.testing.expectEqualStrings(input, actual);
}

test "compress gzip with C interface" {
    var input = [_]u8{ 'b', 'l', 'a', 'r', 'g' };
    var output_buf: [4096]u8 = undefined;

    var zs: c.z_stream = undefined;
    zs.zalloc = null;
    zs.zfree = null;
    zs.@"opaque" = null;
    zs.avail_in = input.len;
    zs.next_in = &input;
    zs.avail_out = output_buf.len;
    zs.next_out = &output_buf;

    _ = c.deflateInit2(&zs, c.Z_DEFAULT_COMPRESSION, c.Z_DEFLATED, 15 | 16, 8, c.Z_DEFAULT_STRATEGY);
    _ = c.deflate(&zs, c.Z_FINISH);
    _ = c.deflateEnd(&zs);
}
