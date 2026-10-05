//! `knots-module-snapshot`: copies the application's sources into a private
//! tree, adding to each module file the list of its variables (see
//! transfer.zig), and removes stale files from the tree.

const std = @import("std");
const transfer = @import("transfer.zig");

const file_bytes_max = 32 * 1024 * 1024;
const entries_max = 4097;
const directory_entries_max = 32768;

pub const Copy = struct {
    source: []const u8,
    target: []const u8,
    original: ?[]const u8 = null,
    name: []const u8 = "",
};

pub const Configuration = struct {
    copies: []const Copy,
    generated: []const struct { target: []const u8, contents: []const u8 },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);
    if (arguments.len != 3)
        return error.ExpectedConfigurationAndDirectory;

    const config_path = arguments[1];
    const output_path = arguments[2];

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(file_bytes_max));
    const config = try std.json.parseFromSlice(Configuration, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });

    if (config.value.copies.len > entries_max)
        return error.TooManyInputs;

    if (config.value.generated.len > entries_max)
        return error.TooManyEntries;

    var retained: std.StringHashMap(void) = .init(allocator);
    for (config.value.copies) |copy| {
        try writeCopy(allocator, io, output_path, copy);
        if (copy.original) |original|
            try retained.put(try normalized(allocator, original), {});

        try retained.put(try normalized(allocator, copy.target), {});
    }

    for (config.value.generated) |generated| {
        const target = try std.fs.path.join(allocator, &.{ output_path, generated.target });
        try writeChanged(allocator, io, target, generated.contents);
        try retained.put(try normalized(allocator, generated.target), {});
    }

    var directory = try std.Io.Dir.cwd().openDir(io, output_path, .{ .iterate = true });
    defer directory.close(io);

    var walker = try directory.walk(allocator);
    defer walker.deinit();

    var visited: usize = 0;
    while (try walker.next(io)) |entry| {
        visited += 1;
        if (visited > directory_entries_max)
            return error.TooManySnapshotEntries;

        if (entry.kind != .file)
            continue;

        if (retained.contains(try normalized(allocator, entry.path)))
            continue;

        try directory.deleteFile(io, entry.path);
    }
}

pub fn writeCopy(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, copy: Copy) !void {
    const target = try std.fs.path.join(allocator, &.{ directory, copy.target });
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, copy.source, allocator, .limited(file_bytes_max));
    if (copy.original) |original| {
        try writeChanged(allocator, io, target, try withVariables(allocator, contents, copy.name));
        try writeChanged(allocator, io, try std.fs.path.join(allocator, &.{ directory, original }), contents);
    } else {
        try writeChanged(allocator, io, target, contents);
    }
}

pub fn entryName(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "entry-{x}.zig", .{std.hash.Wyhash.hash(0, id)});
}

pub fn entryContents(allocator: std.mem.Allocator, copies: []const []const u8, original: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    for (copies, 0..) |copy, index|
        try output.writer.print("const f{d} = @import(\"{f}\");\n", .{ index, std.zig.fmtString(copy) });

    try output.writer.print("pub const source = f0;\npub const text = @embedFile(\"{f}\");\n", .{std.zig.fmtString(original)});
    try output.writer.writeAll("pub const vars = .{}");
    for (0..copies.len) |index|
        try output.writer.print(" ++ variables(f{d})", .{index});

    try output.writer.print(
        \\;
        \\
        \\// A file with syntax errors has no list. The compiler reports the error.
        \\fn Variables(comptime file: type) type {{
        \\    if (!@hasDecl(file, "{0s}")) return @TypeOf(.{{}});
        \\    return @TypeOf(file.@"{0s}");
        \\}}
        \\
        \\fn variables(comptime file: type) Variables(file) {{
        \\    if (!@hasDecl(file, "{0s}")) return .{{}};
        \\    return file.@"{0s}";
        \\}}
        \\
    , .{transfer.declaration_name});

    return output.written();
}

fn withVariables(allocator: std.mem.Allocator, contents: []const u8, name: []const u8) ![]const u8 {
    const source = try allocator.dupeSentinel(u8, contents, 0);
    var tree = try std.zig.Ast.parse(allocator, source, .{});
    defer tree.deinit(allocator);

    // The compiler reports the user's own error.
    if (tree.errors.len > 0)
        return contents;

    var output: std.Io.Writer.Allocating = .init(allocator);
    try output.writer.writeAll(contents);
    if (contents.len > 0 and contents[contents.len - 1] != '\n')
        try output.writer.writeByte('\n');

    try output.writer.print("pub const @\"{s}\" = .{{\n", .{transfer.declaration_name});

    var prefix: std.ArrayList(u8) = .empty;
    try prefix.print(allocator, "{s}:", .{name});
    try listVariables(&tree, tree.rootDecls(), &prefix, allocator, &output.writer, 0, prefix.items.len);
    try output.writer.writeAll("};\n");

    return output.written();
}

fn listVariables(
    tree: *const std.zig.Ast,
    declarations: []const std.zig.Ast.Node.Index,
    prefix: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    depth: u32,
    file_prefix: usize,
) !void {
    for (declarations) |node| {
        const declaration = tree.fullVarDecl(node) orelse continue;

        if (declaration.comptime_token != null)
            continue;

        if (declaration.threadlocal_token != null)
            continue;

        if (declaration.extern_export_token) |token| {
            if (tree.tokenTag(token) == .keyword_extern)
                continue;
        }

        const identifier = tree.tokenSlice(declaration.ast.mut_token + 1);
        const name = unquoted(identifier);
        const initializer = declaration.ast.init_node.unwrap() orelse continue;
        if (tree.tokenTag(declaration.ast.mut_token) == .keyword_var) {
            try writer.print("    .{{ .name = \"{f}{f}\", .pointer = &{s}{s}, .initial = 0x{x} }},\n", .{
                std.zig.fmtString(prefix.items),
                std.zig.fmtString(name),
                prefix.items[file_prefix..],
                identifier,
                std.hash.Wyhash.hash(0, tree.getNodeSource(initializer)),
            });
            continue;
        }

        if (depth == 4)
            continue;

        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, initializer) orelse continue;
        const mark = prefix.items.len;
        try prefix.print(allocator, "{s}.", .{identifier});
        try listVariables(tree, container.ast.members, prefix, allocator, writer, depth + 1, file_prefix);
        prefix.shrinkRetainingCapacity(mark);
    }
}

fn unquoted(identifier: []const u8) []const u8 {
    if (std.mem.startsWith(u8, identifier, "@\""))
        return identifier[2 .. identifier.len - 1];

    return identifier;
}

fn normalized(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const result = try allocator.dupe(u8, path);
    std.mem.replaceScalar(u8, result, '\\', '/');
    return result;
}

fn writeChanged(allocator: std.mem.Allocator, io: std.Io, path: []const u8, contents: []const u8) !void {
    const previous = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(file_bytes_max)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    if (previous) |value| {
        defer allocator.free(value);
        if (std.mem.eql(u8, value, contents))
            return;
    }

    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents, .flags = .{} });
}
