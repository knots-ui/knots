const std = @import("std");

const Configuration = struct {
    copies: []const struct { source: []const u8, target: []const u8 },
    generated: []const struct { target: []const u8, contents: []const u8 },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);
    if (arguments.len != 3)
        return error.ExpectedConfigurationAndDirectory;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, arguments[1], allocator, .limited(32 * 1024 * 1024));
    const config = try std.json.parseFromSlice(Configuration, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false });

    if (config.value.copies.len > 4096)
        return error.TooManyInputs;
    if (config.value.generated.len > 4097)
        return error.TooManyEntries;

    var retained: std.StringHashMap(void) = .init(allocator);
    for (config.value.copies) |copy| {
        const target = try std.fs.path.join(allocator, &.{ arguments[2], copy.target });
        const contents = try std.Io.Dir.cwd().readFileAlloc(init.io, copy.source, allocator, .limited(32 * 1024 * 1024));
        try writeChanged(allocator, init.io, target, contents);
        try retained.put(try normalized(allocator, copy.target), {});
    }

    for (config.value.generated) |generated| {
        const target = try std.fs.path.join(allocator, &.{ arguments[2], generated.target });
        try writeChanged(allocator, init.io, target, generated.contents);
        try retained.put(try normalized(allocator, generated.target), {});
    }

    var directory = try std.Io.Dir.cwd().openDir(init.io, arguments[2], .{ .iterate = true });
    defer directory.close(init.io);

    var walker = try directory.walk(allocator);
    defer walker.deinit();
    var visited: usize = 0;
    while (try walker.next(init.io)) |entry| {
        visited += 1;
        if (visited > 32768) return error.TooManySnapshotEntries;
        if (entry.kind != .file) continue;
        if (retained.contains(try normalized(allocator, entry.path))) continue;
        try directory.deleteFile(init.io, entry.path);
    }
    std.debug.assert(retained.count() <= 8193);
    std.debug.assert(arguments[2].len > 0);
}

fn normalized(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const result = try allocator.dupe(u8, path);
    std.mem.replaceScalar(u8, result, '\\', '/');
    return result;
}

fn writeChanged(allocator: std.mem.Allocator, io: std.Io, path: []const u8, contents: []const u8) !void {
    const previous = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (previous) |value| {
        defer allocator.free(value);
        if (std.mem.eql(u8, value, contents)) return;
    }
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents, .flags = .{} });
}
