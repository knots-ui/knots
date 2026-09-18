const std = @import("std");
const Protocol = @import("Protocol.zig");

pub const File = struct { id: []const u8, path: []const u8 };
pub const files_max = 4096;

pub fn scan(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8) ![]File {
    std.debug.assert(files_max > Protocol.modules_max);

    const paths = try pathsInRoots(allocator, io, roots);
    var files: std.ArrayList(File) = .empty;
    for (paths) |path| {
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        for (roots) |root| {
            const relative = try std.fs.path.relativeAlloc(allocator, root, null, root, path);
            defer allocator.free(relative);

            if (std.mem.eql(u8, relative, "..")) continue;
            if (std.mem.startsWith(u8, relative, "../")) continue;
            if (std.mem.startsWith(u8, relative, "..\\")) continue;

            const id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.fs.path.basename(root), relative[0 .. relative.len - 4] });
            std.mem.replaceScalar(u8, id, '\\', '/');
            if (!Protocol.validId(id)) return error.InvalidModuleId;
            for (files.items) |previous| {
                if (std.mem.eql(u8, previous.id, id)) return error.DuplicateModuleId;
            }
            try files.append(allocator, .{ .id = id, .path = path });
            break;
        }
    }

    std.mem.sort(File, files.items, {}, lessThan);

    return files.toOwnedSlice(allocator);
}

fn lessThan(_: void, left: File, right: File) bool {
    return std.mem.lessThan(u8, left.id, right.id);
}

pub fn pathsInRoots(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    var visited: usize = 0;
    for (roots) |root| {
        var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer directory.close(io);
        var walker = try directory.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |item| {
            visited += 1;
            if (visited > files_max * 4) return error.SourceTreeTooLarge;
            if (item.kind != .file) continue;
            const path = try std.fs.path.join(allocator, &.{ root, item.path });
            if (seen.contains(path)) {
                allocator.free(path);
                continue;
            }
            if (paths.items.len == files_max) return error.TooManySourceFiles;
            try seen.put(path, {});
            try paths.append(allocator, path);
        }
    }
    std.mem.sort([]const u8, paths.items, {}, lessPath);
    return paths.toOwnedSlice(allocator);
}

fn lessPath(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

pub fn fingerprint(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8) ![32]u8 {
    const paths = try pathsInRoots(allocator, io, roots);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (paths) |path| {
        hash.update(path);
        hash.update(&.{0});
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024));
        defer allocator.free(bytes);
        hash.update(bytes);
        hash.update(&.{0});
    }
    return hash.finalResult();
}
