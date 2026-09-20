const std = @import("std");

/// `.git` files whose changes signal a git-state change (commit, checkout,
/// branch switch, staging) even when no working-tree file is touched.
pub const git_signal_files = [_][]const u8{
    ".git/HEAD",
    ".git/index",
    ".git/packed-refs",
    ".git/ORIG_HEAD",
    ".git/MERGE_HEAD",
};

pub fn cheapSignals(io: std.Io, workdir: []const u8) ?u64 {
    var hasher = std.hash.Wyhash.init(0);
    addRoot(&hasher, io, workdir) orelse return null;
    addGitSignalFiles(&hasher, io, workdir);
    return hasher.final();
}

fn addRoot(hasher: *std.hash.Wyhash, io: std.Io, workdir: []const u8) ?void {
    const stat = std.Io.Dir.cwd().statFile(io, workdir, .{}) catch return null;
    foldEntry(hasher, ".", stat);
}

fn addGitSignalFiles(hasher: *std.hash.Wyhash, io: std.Io, workdir: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    for (git_signal_files) |rel| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ workdir, rel }) catch continue;
        const stat = cwd.statFile(io, full, .{}) catch continue;
        foldEntry(hasher, rel, stat);
    }
}

fn foldEntry(hasher: *std.hash.Wyhash, path: []const u8, stat: std.Io.File.Stat) void {
    hasher.update(path);
    const mtime: i96 = stat.mtime.nanoseconds;
    hasher.update(std.mem.asBytes(&mtime));
    hasher.update(std.mem.asBytes(&stat.size));
}
