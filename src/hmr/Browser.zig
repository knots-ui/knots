//! Browser-side execution of an isolated HMR guest.
const std = @import("std");
const hmr = @import("hmr");

const Self = @This();

handle: u32,

pub fn init(id: []const u8, hash: []const u8) !Self {
    const handle = imports.open(id.ptr, id.len, hash.ptr, hash.len);
    if (handle == 0) return error.ModuleUnavailable;
    return .{ .handle = handle };
}

pub fn deinit(self: *Self) void {
    imports.close(self.handle);
    self.* = undefined;
}

pub fn frame(self: *Self, allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    if (request.len > hmr.Protocol.bytes_max) return error.LimitExceeded;
    if (imports.frame(self.handle, request.ptr, request.len) == 0) return error.GuestFrameFailed;
    const length = imports.outputLength(self.handle);
    if (length > hmr.Protocol.bytes_max) return error.LimitExceeded;
    const output = try allocator.alloc(u8, length);
    errdefer allocator.free(output);
    if (imports.outputCopy(self.handle, output.ptr, output.len) != output.len)
        return error.InvalidGuestRange;
    return output;
}

pub fn staticString(self: *Self, allocator: std.mem.Allocator, comptime name: []const u8) ![]u8 {
    comptime std.debug.assert(std.mem.eql(u8, name, "source"));
    const length = imports.sourceLength(self.handle);
    if (length > hmr.Protocol.bytes_max) return error.LimitExceeded;
    const output = try allocator.alloc(u8, length);
    errdefer allocator.free(output);
    if (imports.sourceCopy(self.handle, output.ptr, output.len) != output.len)
        return error.InvalidGuestRange;
    return output;
}

pub fn revision() u32 {
    return imports.revision();
}

pub fn manifest(allocator: std.mem.Allocator) ![]u8 {
    return copyDocument(allocator, imports.manifestLength, imports.manifestCopy);
}

pub fn status(allocator: std.mem.Allocator) ![]u8 {
    return copyDocument(allocator, imports.statusLength, imports.statusCopy);
}

fn copyDocument(
    allocator: std.mem.Allocator,
    lengthFn: *const fn () callconv(.c) usize,
    copyFn: *const fn ([*]u8, usize) callconv(.c) usize,
) ![]u8 {
    const length = lengthFn();
    if (length > hmr.Protocol.bytes_max) return error.LimitExceeded;
    const output = try allocator.alloc(u8, length);
    errdefer allocator.free(output);
    if (copyFn(output.ptr, output.len) != output.len) return error.InvalidDocumentRange;
    return output;
}

const imports = struct {
    extern "knots_hmr" fn revision() u32;
    extern "knots_hmr" fn manifestLength() usize;
    extern "knots_hmr" fn manifestCopy(output: [*]u8, capacity: usize) usize;
    extern "knots_hmr" fn statusLength() usize;
    extern "knots_hmr" fn statusCopy(output: [*]u8, capacity: usize) usize;
    extern "knots_hmr" fn open(id: [*]const u8, id_length: usize, hash: [*]const u8, hash_length: usize) u32;
    extern "knots_hmr" fn close(handle: u32) void;
    extern "knots_hmr" fn sourceLength(handle: u32) usize;
    extern "knots_hmr" fn sourceCopy(handle: u32, output: [*]u8, capacity: usize) usize;
    extern "knots_hmr" fn frame(handle: u32, request: [*]const u8, request_length: usize) u32;
    extern "knots_hmr" fn outputLength(handle: u32) usize;
    extern "knots_hmr" fn outputCopy(handle: u32, output: [*]u8, capacity: usize) usize;
};
