//! Finds every file the application reaches from its entry point, and which
//! of them can run as HMR modules.
//!
//! The walk starts at the root source file of the executable's root module.
//! It follows `@import` and `@embedFile` of files, and `@import` of named
//! modules that belong to the application. Named modules of dependencies are
//! not entered.
//!
//! A module runs in a guest build that has only `std`, `builtin`,
//! `knots-ui` and the portable part of `knots`. A file is portable if it
//! uses nothing else, and everything it imports is portable. A portable file
//! that declares `pub fn main(frame)` is a module, unless it is the root of a
//! named module. Its id is `@typeName` of the file: the path below the
//! directory of its module's root, without `.zig`, with dots for separators.

const std = @import("std");

const source_bytes_max = 32 * 1024 * 1024;
const files_max = 4096;

/// A named module of the application. Packages are numbered by their index
/// in the slice given to `resolve`. Package 0 is the executable's root module.
pub const Package = struct {
    root: []const u8,
    imports: []const Import = &.{},
};

pub const Import = struct {
    name: []const u8,
    package: ?u32 = null,
};

pub const Module = struct {
    id: []const u8,
    path: []const u8,
    files: []const []const u8 = &.{},

    pub fn reaches(self: *const Module, path: []const u8) bool {
        return contains(self.files, path);
    }
};

pub const Rejection = struct { id: []const u8, reason: []const u8 };

/// Paths are sorted. `files` includes files that do not exist yet, so that
/// creating them is seen. `modules` is sorted by id.
pub const Result = struct {
    files: []const []const u8 = &.{},
    module_files: []const []const u8 = &.{},
    modules: []const Module = &.{},
    rejections: []const Rejection = &.{},

    pub fn module(self: *const Result, path: []const u8) ?Module {
        for (self.modules) |entry| {
            if (std.mem.eql(u8, entry.path, path))
                return entry;
        }
        return null;
    }

    pub fn sameShape(self: *const Result, other: *const Result) bool {
        if (!samePaths(self.files, other.files) or self.modules.len != other.modules.len)
            return false;

        for (self.modules, other.modules) |left, right| {
            if (!std.mem.eql(u8, left.id, right.id) or !std.mem.eql(u8, left.path, right.path))
                return false;

            if (!samePaths(left.files, right.files))
                return false;
        }
        return true;
    }
};

/// What one source file imports and declares. It does not depend on the
/// other files, so it stays valid until the file changes.
const Summary = struct {
    arena: std.heap.ArenaAllocator,
    files: []const []const u8,
    names: []const []const u8,
    embeds: []const []const u8,
    reason: ?[]const u8,
    declares_main: bool,
};

/// Summaries by path. The server keeps one between changes, so a change
/// parses only the files that changed.
pub const Cache = struct {
    gpa: std.mem.Allocator,
    summaries: std.StringHashMapUnmanaged(*Summary) = .empty,

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Cache) void {
        var iterator = self.summaries.iterator();
        while (iterator.next()) |entry|
            self.destroy(entry.key_ptr.*, entry.value_ptr.*);

        self.summaries.deinit(self.gpa);
    }

    pub fn invalidate(self: *Cache, path: []const u8) void {
        const entry = self.summaries.fetchRemove(path) orelse return;
        self.destroy(entry.key, entry.value);
    }

    fn destroy(self: *Cache, path: []const u8, summary: *Summary) void {
        summary.arena.deinit();
        self.gpa.destroy(summary);
        self.gpa.free(path);
    }

    fn get(self: *Cache, io: std.Io, path: []const u8, knots_decls: []const []const u8) !?*const Summary {
        if (self.summaries.get(path)) |summary|
            return summary;

        const summary = try self.gpa.create(Summary);
        errdefer self.gpa.destroy(summary);

        summary.arena = .init(self.gpa);
        errdefer summary.arena.deinit();

        const allocator = summary.arena.allocator();
        const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .limited(source_bytes_max), .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                summary.arena.deinit();
                self.gpa.destroy(summary);
                return null;
            },
            else => return err,
        };

        try summarize(allocator, source, knots_decls, summary);
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);

        try self.summaries.put(self.gpa, key, summary);
        return summary;
    }
};

/// Walks the application from the root of `packages[0]`. `knots_decls` are
/// the public declarations of the portable `knots` module. The result is
/// allocated with `allocator`.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: *Cache,
    packages: []const Package,
    knots_decls: []const []const u8,
) !Result {
    var walk: Walk = .{ .allocator = allocator, .packages = packages };
    _ = try walk.add(packages[0].root, 0);

    var index: u32 = 0;
    while (index < walk.nodes.items.len) : (index += 1) {
        const path = walk.nodes.items[index].path;
        if (!std.mem.endsWith(u8, path, ".zig"))
            continue;

        const summary = try cache.get(io, path, knots_decls) orelse continue;
        walk.nodes.items[index].summary = summary;
        try walk.follow(index, summary);
    }

    walk.propagate();
    return walk.result(io);
}

const Node = struct {
    path: []const u8,
    package: u32,
    summary: ?*const Summary = null,
    edges: std.ArrayList(u32) = .empty,
    reason: ?[]const u8 = null,
    cause: ?u32 = null,
};

const Walk = struct {
    allocator: std.mem.Allocator,
    packages: []const Package,
    nodes: std.ArrayList(Node) = .empty,
    indices: std.StringHashMapUnmanaged(u32) = .empty,

    fn add(self: *Walk, path: []const u8, package: u32) !u32 {
        const entry = try self.indices.getOrPut(self.allocator, path);
        if (entry.found_existing)
            return entry.value_ptr.*;

        if (self.nodes.items.len == files_max)
            return error.TooManySourceFiles;

        entry.value_ptr.* = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .path = path, .package = package });
        return entry.value_ptr.*;
    }

    fn follow(self: *Walk, index: u32, summary: *const Summary) !void {
        const package = self.nodes.items[index].package;
        self.nodes.items[index].reason = summary.reason;
        for (summary.files) |relative|
            try self.followPath(index, relative);

        for (summary.names) |name|
            try self.followName(index, name);

        for (summary.embeds) |embed| {
            // Like the compiler, prefer a named module over a file.
            if (self.findImport(package, embed) == null) {
                try self.followPath(index, embed);
                continue;
            }

            if (self.nodes.items[index].reason == null)
                self.nodes.items[index].reason = try std.fmt.allocPrint(self.allocator, "embeds `{s}`", .{embed});

            try self.followName(index, embed);
        }
    }

    fn followPath(self: *Walk, index: u32, relative: []const u8) !void {
        const directory = std.fs.path.dirname(self.nodes.items[index].path).?;
        const path = try std.fs.path.resolveAlloc(self.allocator, &.{ directory, relative });
        const target = try self.add(path, self.nodes.items[index].package);
        try self.nodes.items[index].edges.append(self.allocator, target);
    }

    fn followName(self: *Walk, index: u32, name: []const u8) !void {
        const import = self.findImport(self.nodes.items[index].package, name) orelse return;
        const package = import.package orelse return;
        const target = try self.add(self.packages[package].root, package);
        try self.nodes.items[index].edges.append(self.allocator, target);
    }

    fn findImport(self: *const Walk, package: u32, name: []const u8) ?Import {
        for (self.packages[package].imports) |import| {
            if (std.mem.eql(u8, import.name, name))
                return import;
        }
        return null;
    }

    fn propagate(self: *Walk) void {
        var changed = true;
        while (changed) {
            changed = false;
            for (self.nodes.items) |*node| {
                if (node.reason != null)
                    continue;

                for (node.edges.items) |edge| {
                    if (self.nodes.items[edge].reason == null)
                        continue;

                    node.reason = "imports";
                    node.cause = edge;
                    changed = true;
                    break;
                }
            }
        }
    }

    fn result(self: *Walk, io: std.Io) !Result {
        var files: std.ArrayList([]const u8) = .empty;
        var modules: std.ArrayList(Module) = .empty;
        var rejections: std.ArrayList(Rejection) = .empty;
        for (self.nodes.items) |node| {
            try files.append(self.allocator, node.path);
            const summary = node.summary orelse continue;
            if (!summary.declares_main or self.isPackageRoot(node.path))
                continue;

            const id = try self.moduleId(node);
            if (node.reason == null) {
                try modules.append(self.allocator, .{ .id = id, .path = node.path });
            } else {
                try rejections.append(self.allocator, .{ .id = id, .reason = try self.explain(node) });
            }
        }

        const module_files = try self.moduleFiles(io, modules.items);
        sortPaths(files.items);
        sortPaths(module_files);
        std.mem.sort(Module, modules.items, {}, struct {
            fn lessThan(_: void, left: Module, right: Module) bool {
                return std.mem.lessThan(u8, left.id, right.id);
            }
        }.lessThan);

        for (1..modules.items.len) |index| {
            if (std.mem.eql(u8, modules.items[index].id, modules.items[index - 1].id))
                return error.DuplicateModuleId;
        }

        return .{ .files = files.items, .module_files = module_files, .modules = modules.items, .rejections = rejections.items };
    }

    fn moduleFiles(self: *Walk, io: std.Io, modules: []Module) ![][]const u8 {
        var all = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.nodes.items.len);
        var exists = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.nodes.items.len);
        for (self.nodes.items, 0..) |node, index| {
            if (nodeExists(io, node))
                exists.set(index);
        }

        var seen = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.nodes.items.len);
        var pending: std.ArrayList(u32) = .empty;
        for (modules) |*entry| {
            seen.unsetAll();
            const root = self.indices.get(entry.path).?;
            try pending.append(self.allocator, root);
            var files: std.ArrayList([]const u8) = .empty;
            while (pending.pop()) |index| {
                if (seen.isSet(index))
                    continue;

                seen.set(index);
                try pending.appendSlice(self.allocator, self.nodes.items[index].edges.items);
                if (!exists.isSet(index))
                    continue;

                all.set(index);
                if (index != root)
                    try files.append(self.allocator, self.nodes.items[index].path);
            }

            sortPaths(files.items);
            try files.insert(self.allocator, 0, entry.path);
            entry.files = files.items;
        }

        var result_files: std.ArrayList([]const u8) = .empty;
        var iterator = all.iterator(.{});
        while (iterator.next()) |index|
            try result_files.append(self.allocator, self.nodes.items[index].path);

        return result_files.items;
    }

    fn isPackageRoot(self: *const Walk, path: []const u8) bool {
        for (self.packages) |package| {
            if (std.mem.eql(u8, package.root, path))
                return true;
        }
        return false;
    }

    fn moduleId(self: *Walk, node: Node) ![]const u8 {
        const base = std.fs.path.dirname(self.packages[node.package].root).?;
        const relative = try std.fs.path.relativeAlloc(self.allocator, base, null, base, node.path);
        const id = relative[0 .. relative.len - ".zig".len];
        for (id) |*byte| {
            if (std.fs.path.isSep(byte.*))
                byte.* = '.';
        }
        return id;
    }

    fn explain(self: *Walk, node: Node) ![]const u8 {
        var text: std.ArrayList(u8) = .empty;
        var current = node;
        while (current.cause) |cause| {
            const next = self.nodes.items[cause];
            const base = std.fs.path.dirname(current.path).?;
            const relative = try std.fs.path.relativeAlloc(self.allocator, base, null, base, next.path);
            if (text.items.len == 0) {
                try text.print(self.allocator, "imports {s}", .{relative});
            } else {
                try text.print(self.allocator, ", which imports {s}", .{relative});
            }
            current = next;
        }

        if (text.items.len > 0)
            try text.appendSlice(self.allocator, ", which ");

        try text.appendSlice(self.allocator, current.reason.?);
        return text.items;
    }
};

fn nodeExists(io: std.Io, node: Node) bool {
    if (std.mem.endsWith(u8, node.path, ".zig"))
        return node.summary != null;

    std.Io.Dir.cwd().access(io, node.path, .{}) catch return false;
    return true;
}

fn contains(paths: []const []const u8, path: []const u8) bool {
    for (paths) |entry| {
        if (std.mem.eql(u8, entry, path))
            return true;
    }
    return false;
}

fn samePaths(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len)
        return false;

    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a, b))
            return false;
    }
    return true;
}

fn sortPaths(paths: [][]const u8) void {
    std.mem.sort([]const u8, paths, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
}

/// Reads imports from the tokens, which exist even where the parser fails.
/// `main` comes from the syntax tree when it parses.
fn summarize(allocator: std.mem.Allocator, source: [:0]const u8, knots_decls: []const []const u8, summary: *Summary) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .{});
    var files: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var embeds: std.ArrayList([]const u8) = .empty;
    var knots_names: std.ArrayList([]const u8) = .empty;
    var reason: ?[]const u8 = null;

    const count: std.zig.Ast.TokenIndex = @intCast(tree.tokens.len);
    var index: std.zig.Ast.TokenIndex = 0;
    while (index < count) : (index += 1) {
        const argument = try builtinArgument(allocator, &tree, index) orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(index), "@embedFile")) {
            try embeds.append(allocator, argument);
            continue;
        }

        if (std.mem.endsWith(u8, argument, ".zig") or std.mem.endsWith(u8, argument, ".zon")) {
            try files.append(allocator, argument);
            continue;
        }

        try names.append(allocator, argument);
        if (std.mem.eql(u8, argument, "knots")) {
            if (index >= 2 and tree.tokenTag(index - 1) == .equal and tree.tokenTag(index - 2) == .identifier)
                try knots_names.append(allocator, tree.tokenSlice(index - 2));

            if (reason == null)
                reason = try knotsAccess(allocator, &tree, index + 4, knots_decls);
        } else if (reason == null and !portableName(argument)) {
            reason = try std.fmt.allocPrint(allocator, "imports `{s}`", .{argument});
        }
    }

    if (reason == null)
        reason = try knotsAliasAccess(allocator, &tree, knots_names.items, knots_decls);

    summary.* = .{
        .arena = summary.arena,
        .files = files.items,
        .names = names.items,
        .embeds = embeds.items,
        .reason = reason,
        .declares_main = declaresMain(&tree),
    };
}

fn knotsAliasAccess(allocator: std.mem.Allocator, tree: *const std.zig.Ast, aliases: []const []const u8, knots_decls: []const []const u8) !?[]const u8 {
    const count: std.zig.Ast.TokenIndex = @intCast(tree.tokens.len);
    var index: std.zig.Ast.TokenIndex = 1;
    while (index < count) : (index += 1) {
        if (tree.tokenTag(index) != .identifier or tree.tokenTag(index - 1) == .period)
            continue;

        if (!contains(aliases, tree.tokenSlice(index)))
            continue;

        if (try knotsAccess(allocator, tree, index + 1, knots_decls)) |reason|
            return reason;
    }
    return null;
}

fn builtinArgument(allocator: std.mem.Allocator, tree: *const std.zig.Ast, index: std.zig.Ast.TokenIndex) !?[]const u8 {
    if (tree.tokenTag(index) != .builtin)
        return null;

    const builtin = tree.tokenSlice(index);
    if (!std.mem.eql(u8, builtin, "@import") and !std.mem.eql(u8, builtin, "@embedFile"))
        return null;

    if (index + 3 >= tree.tokens.len)
        return null;

    if (tree.tokenTag(index + 1) != .l_paren or tree.tokenTag(index + 2) != .string_literal)
        return null;

    return std.zig.string_literal.parseAlloc(allocator, tree.tokenSlice(index + 2)) catch null;
}

fn knotsAccess(allocator: std.mem.Allocator, tree: *const std.zig.Ast, index: std.zig.Ast.TokenIndex, knots_decls: []const []const u8) !?[]const u8 {
    if (index + 1 >= tree.tokens.len)
        return null;

    if (tree.tokenTag(index) != .period or tree.tokenTag(index + 1) != .identifier)
        return null;

    const name = tree.tokenSlice(index + 1);
    if (contains(knots_decls, name))
        return null;

    return try std.fmt.allocPrint(allocator, "uses `knots.{s}`", .{name});
}

fn portableName(name: []const u8) bool {
    return contains(&.{ "std", "builtin", "knots-ui" }, name);
}

fn declaresMain(tree: *const std.zig.Ast) bool {
    for (tree.rootDecls()) |node| {
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buffer, node)) |function| {
            const name = function.name_token orelse continue;
            if (function.visib_token == null or !std.mem.eql(u8, tree.tokenSlice(name), "main"))
                continue;

            var parameters = function.iterate(tree);
            var count: usize = 0;
            while (parameters.next()) |_|
                count += 1;

            if (count == 1)
                return true;
        } else if (tree.fullVarDecl(node)) |declaration| {
            const name = declaration.ast.mut_token + 1;
            if (declaration.visib_token != null and std.mem.eql(u8, tree.tokenSlice(name), "main"))
                return true;
        }
    }

    // Keep a module whose `main` the parser lost, so the compiler reports
    // the user's error.
    return tree.errors.len > 0 and tokensDeclareMain(tree);
}

/// Looks for `pub fn main`, `pub const main` or `pub var main` in the tokens.
/// Comments and strings are not tokens, so they cannot match.
fn tokensDeclareMain(tree: *const std.zig.Ast) bool {
    const count: std.zig.Ast.TokenIndex = @intCast(tree.tokens.len);
    var index: std.zig.Ast.TokenIndex = 0;
    while (index < count) : (index += 1) {
        if (tree.tokenTag(index) != .keyword_pub)
            continue;

        var next = index + 1;
        while (next < count) : (next += 1) {
            switch (tree.tokenTag(next)) {
                .keyword_inline, .keyword_noinline, .keyword_export => continue,
                else => break,
            }
        }

        if (next + 1 >= count)
            return false;

        switch (tree.tokenTag(next)) {
            .keyword_fn, .keyword_const, .keyword_var => {},
            else => continue,
        }

        const name = next + 1;
        if (tree.tokenTag(name) == .identifier and std.mem.eql(u8, tree.tokenSlice(name), "main"))
            return true;
    }
    return false;
}

pub fn publicDecls(allocator: std.mem.Allocator, source: [:0]const u8) ![]const []const u8 {
    var tree = try std.zig.Ast.parse(allocator, source, .{});
    defer tree.deinit(allocator);

    var result: std.ArrayList([]const u8) = .empty;
    for (tree.rootDecls()) |node| {
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        if (tree.fullVarDecl(node)) |declaration| {
            if (declaration.visib_token == null)
                continue;

            try result.append(allocator, try allocator.dupe(u8, tree.tokenSlice(declaration.ast.mut_token + 1)));
        } else if (tree.fullFnProto(&buffer, node)) |function| {
            if (function.visib_token == null)
                continue;

            const name = function.name_token orelse continue;
            try result.append(allocator, try allocator.dupe(u8, tree.tokenSlice(name)));
        }
    }
    return result.items;
}

fn testDeclaresMain(source: [:0]const u8) !bool {
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .{});
    defer tree.deinit(std.testing.allocator);
    return declaresMain(&tree);
}

test "only a public main with one parameter makes a module" {
    try std.testing.expect(try testDeclaresMain("pub fn main(frame: *Frame) !void {}"));
    try std.testing.expect(try testDeclaresMain("pub const main = other.main;"));
    try std.testing.expect(!try testDeclaresMain("fn main(frame: *Frame) void {}"));
    try std.testing.expect(!try testDeclaresMain("pub fn main() void {}"));
    try std.testing.expect(!try testDeclaresMain("pub fn helper(frame: *Frame) void {}"));
}

test "modules with syntax errors stay modules" {
    try std.testing.expect(try testDeclaresMain("pub fn main(frame: *Frame) !void { x = ; }"));
    try std.testing.expect(try testDeclaresMain("const a = ;\npub fn main(frame: *Frame) !void {}"));
    try std.testing.expect(try testDeclaresMain("pub fn main(frame: *Frame) !void { if (x) { }"));
    try std.testing.expect(try testDeclaresMain("pub fn main (frame: *Frame) !void { try frame.e(.{ .x = 1 ) }"));
    try std.testing.expect(try testDeclaresMain("pub inline fn main( {"));
}

test "helpers with syntax errors stay helpers" {
    try std.testing.expect(!try testDeclaresMain("pub fn helper() void { a = ; }\nfn main() void {}"));
    try std.testing.expect(!try testDeclaresMain("// pub fn main(\nconst a = ;"));
    try std.testing.expect(!try testDeclaresMain("const text = \"pub fn main(\";\nconst a = ;"));
    try std.testing.expect(!try testDeclaresMain("fn main( {"));
}

const TestTree = struct {
    directory: std.testing.TmpDir,
    path: []const u8,
    allocator: std.mem.Allocator,

    fn write(self: *TestTree, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |parent|
            try self.directory.dir.createDirPath(std.testing.io, parent);

        try self.directory.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data, .flags = .{} });
    }

    fn absolute(self: *TestTree, sub_path: []const u8) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.path, sub_path });
    }
};

fn expectIds(expected: []const []const u8, modules: []const Module) !void {
    try std.testing.expectEqual(expected.len, modules.len);
    for (expected, modules) |id, module_|
        try std.testing.expectEqualStrings(id, module_.id);
}

fn expectFile(result: *const Result, path: []const u8, reachable: bool) !void {
    try std.testing.expectEqual(reachable, contains(result.files, path));
}

test "the walk finds reachable modules and explains the others" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var tree: TestTree = .{ .directory = std.testing.tmpDir(.{}), .path = undefined, .allocator = allocator };
    defer tree.directory.cleanup();

    tree.path = try tree.directory.dir.realPathFileAlloc(std.testing.io, ".", allocator);

    try tree.write("main.zig",
        \\const app = @import("app");
        \\const ghost = @import("ghost.zig");
        \\pub fn main(init: std.process.Init) !void {}
    );
    try tree.write("app/root.zig",
        \\const demos = .{ @import("demos/counter.zig"), @import("demos/native.zig"), @import("demos/broken.zig") };
        \\const shader = @embedFile("shader");
    );
    try tree.write("app/demos/counter.zig",
        \\const knots = @import("knots");
        \\const ui = @import("knots-ui");
        \\const shared = @import("../shared.zig");
        \\pub fn main(frame: *knots.Frame) !void {}
    );
    try tree.write("app/shared.zig",
        \\const counter = @import("demos/counter.zig");
        \\pub const text = @embedFile("data.txt");
    );
    try tree.write("app/data.txt", "data");
    try tree.write("app/demos/native.zig",
        \\const knots = @import("knots");
        \\const helper = @import("../helper.zig");
        \\pub fn main(frame: *knots.Frame) !void {}
    );
    try tree.write("app/helper.zig",
        \\const knots = @import("knots");
        \\pub fn open(app: *knots.App) void {}
    );
    try tree.write("app/demos/broken.zig", "pub fn main(frame: *Frame) !void { if (x) { }");
    try tree.write("app/demos/unused.zig", "pub fn main(frame: *Frame) !void {}");

    const packages = [_]Package{
        .{ .root = try tree.absolute("main.zig"), .imports = &.{ .{ .name = "app", .package = 1 }, .{ .name = "knots" } } },
        .{ .root = try tree.absolute("app/root.zig"), .imports = &.{ .{ .name = "knots" }, .{ .name = "knots-ui" }, .{ .name = "shader" } } },
    };
    const knots_decls = [_][]const u8{ "Frame", "component" };
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();

    const result = try resolve(allocator, std.testing.io, &cache, &packages, &knots_decls);
    try expectIds(&.{ "demos.broken", "demos.counter" }, result.modules);
    try std.testing.expectEqual(@as(usize, 1), result.rejections.len);
    try std.testing.expectEqualStrings("demos.native", result.rejections[0].id);
    try std.testing.expectEqualStrings("imports ../helper.zig, which uses `knots.App`", result.rejections[0].reason);
    try expectFile(&result, try tree.absolute("app/data.txt"), true);
    try expectFile(&result, try tree.absolute("ghost.zig"), true);
    try expectFile(&result, try tree.absolute("app/demos/unused.zig"), false);
    try expectFile(&result, try tree.absolute("app/shader"), false);

    try std.testing.expectEqual(@as(usize, 4), result.module_files.len);

    const counter = result.module(try tree.absolute("app/demos/counter.zig")).?;
    try std.testing.expectEqual(@as(usize, 3), counter.files.len);
    try std.testing.expectEqualStrings(counter.path, counter.files[0]);
    try std.testing.expect(counter.reaches(try tree.absolute("app/data.txt")));
    try std.testing.expect(!result.module(try tree.absolute("app/demos/broken.zig")).?.reaches(try tree.absolute("app/data.txt")));

    try tree.write("app/demos/counter.zig",
        \\const helper = @import("../helper.zig");
        \\pub fn main(frame: *Frame) !void {}
    );
    const cached = try resolve(allocator, std.testing.io, &cache, &packages, &knots_decls);
    try std.testing.expect(cached.sameShape(&result));

    cache.invalidate(try tree.absolute("app/demos/counter.zig"));
    const changed = try resolve(allocator, std.testing.io, &cache, &packages, &knots_decls);
    try expectIds(&.{"demos.broken"}, changed.modules);
    try std.testing.expect(!changed.sameShape(&result));
}
