//! One HMR module in the browser. The JavaScript host loads and runs the
//! module (see `BrowserHmr` in web/host.js). This side holds a handle to it.

const std = @import("std");
const hmr = @import("hmr");

const Browser = @This();

handle: u32,

/// The JavaScript host must already have loaded this build of the module.
pub fn init(id: []const u8, hash: []const u8) !Browser {
    const handle = imports.open(id.ptr, id.len, hash.ptr, hash.len);
    if (handle == 0)
        return error.ModuleUnavailable;

    errdefer imports.close(handle);
    if (imports.fingerprint(handle) != hmr.fingerprint)
        return error.HostOutdated;

    return .{ .handle = handle };
}

pub fn deinit(self: *Browser) void {
    imports.close(self.handle);
    self.* = undefined;
}

pub fn frame(self: *Browser, allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    if (imports.frame(self.handle, request.ptr, request.len) == 0)
        return error.GuestCallFailed;

    return self.output(allocator);
}

pub fn snapshotState(self: *Browser, allocator: std.mem.Allocator) ![]u8 {
    if (imports.snapshot(self.handle) == 0)
        return error.GuestCallFailed;

    return self.output(allocator);
}

pub fn restoreState(self: *Browser, allocator: std.mem.Allocator, snapshot: []const u8) ![]u8 {
    if (imports.restore(self.handle, snapshot.ptr, snapshot.len) == 0)
        return error.GuestCallFailed;

    return self.output(allocator);
}

pub fn source(self: *Browser, allocator: std.mem.Allocator) ![]u8 {
    return copy(allocator, imports.sourceLength(self.handle), self.handle, imports.sourceCopy);
}

fn output(self: *Browser, allocator: std.mem.Allocator) ![]u8 {
    return copy(allocator, imports.outputLength(self.handle), self.handle, imports.outputCopy);
}

pub fn revision() u32 {
    return imports.revision();
}

pub fn manifest(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try allocator.alloc(u8, imports.manifestLength());
    if (imports.manifestCopy(bytes.ptr, bytes.len) != bytes.len)
        return error.InvalidGuestRange;

    return bytes;
}

fn copy(allocator: std.mem.Allocator, length: usize, handle: u32, copyFn: *const fn (u32, [*]u8, usize) callconv(.c) usize) ![]u8 {
    const bytes = try allocator.alloc(u8, length);
    if (copyFn(handle, bytes.ptr, bytes.len) != bytes.len)
        return error.InvalidGuestRange;

    return bytes;
}

const imports = struct {
    extern "knots_hmr" fn revision() u32;
    extern "knots_hmr" fn manifestLength() usize;
    extern "knots_hmr" fn manifestCopy(output: [*]u8, capacity: usize) usize;
    extern "knots_hmr" fn open(id: [*]const u8, id_length: usize, hash: [*]const u8, hash_length: usize) u32;
    extern "knots_hmr" fn close(handle: u32) void;
    extern "knots_hmr" fn fingerprint(handle: u32) u32;
    extern "knots_hmr" fn sourceLength(handle: u32) usize;
    extern "knots_hmr" fn sourceCopy(handle: u32, output: [*]u8, capacity: usize) usize;
    extern "knots_hmr" fn frame(handle: u32, request: [*]const u8, request_length: usize) u32;
    extern "knots_hmr" fn snapshot(handle: u32) u32;
    extern "knots_hmr" fn restore(handle: u32, snapshot: [*]const u8, snapshot_length: usize) u32;
    extern "knots_hmr" fn outputLength(handle: u32) usize;
    extern "knots_hmr" fn outputCopy(handle: u32, output: [*]u8, capacity: usize) usize;
};
