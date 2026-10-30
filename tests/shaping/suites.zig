//! The case suites: hand-written files in `tests/shaping/cases`, plus suites generated from the
//! fonts and this repository's sources on every run.

const std = @import("std");
const text = @import("text");
const manifest = @import("manifest.zig");

const Io = std.Io;

pub const Suite = struct {
    name: []const u8,
    cases: []const manifest.Case,
};

pub fn load(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root: Io.Dir, fonts: []const manifest.FontEntry) ![]const Suite {
    var suites: std.ArrayList(Suite) = .empty;
    var dir = try root.openDir(io, manifest.cases_dir, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        try suites.append(arena, .{
            .name = try arena.dupe(u8, entry.name[0 .. entry.name.len - 4]),
            .cases = try manifest.parseCases(arena, try dir.readFileAlloc(io, entry.name, arena, .unlimited)),
        });
    }
    std.mem.sort(Suite, suites.items, {}, struct {
        fn lessThan(_: void, a: Suite, b: Suite) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    try suites.append(arena, .{ .name = "code-ligatures", .cases = try codeLigatures(io, gpa, arena, root, fonts) });
    try suites.append(arena, .{ .name = "real-code", .cases = try realCode(io, arena, root) });
    return suites.items;
}

const coding_fonts = [_][]const u8{ "fira-code", "jetbrains-mono", "cascadia-code", "iosevka", "monaspace-neon" };
const operators = "!#$%&*+-./:;<=>?@\\^|~_";
const operator_sequences = [_][]const u8{
    "===",       "!==", "<=>", "->>", "<<-", ">>=", "<<=", "...",    "///",    "|||",      "&&&",              "::=",            "=>>",            "<<<", ">>>", "-->",  "<--", "<->",
    "<==",       "==>", "|=>", "<=|", "|->", "<-|", "~~>", "<~~",    "=/=",    "!!.",      "?.",               "?:",             "??",             "::",  ":::", "..<",  "..=", "#{",
    "#[",        "#(",  "#?",  "#_",  "#_(", "%%",  "**",  "***",    "/*",     "*/",       "/**",              "//",             "</",             "</>", "/>",  "<!--", "www", "0xFF",
    "1920x1080", "fi",  "fl",  "ffi", "ffl", "Th",  "->",  "=>",     "!=",     "==",       "<=",               ">=",             "&&",             "||",  "++",  "--",   ":=",  "|>",
    "<|",        ".=",  "+=",  "-=",  "*=",  "/=",  "^=",  "a != b", "x => y", "foo->bar", "a == b && c != d", "if (a <= b) {}", "return x ?? y;",
};

/// Operator pairs, common sequences and every GSUB ligature reachable from the cmap.
fn codeLigatures(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root: Io.Dir, fonts: []const manifest.FontEntry) ![]const manifest.Case {
    var cases: std.ArrayList(manifest.Case) = .empty;
    for (coding_fonts) |name| {
        for (operators) |a| {
            for (operators) |b| try appendCase(arena, &cases, name, &.{ a, b });
        }
        for (operator_sequences) |sequence| try appendCase(arena, &cases, name, sequence);
        const entry = manifest.findFont(fonts, name) orelse return error.UnknownFont;
        const data = try root.readFileAlloc(io, try entry.fontPath(arena), arena, .unlimited);
        var program = try text.FontProgram.init(gpa, data, 0);
        defer program.deinit();
        try appendLigatureSequences(arena, &cases, name, &program);
    }
    return cases.items;
}

/// Lines sampled from this repository's sources.
fn realCode(io: Io, arena: std.mem.Allocator, root: Io.Dir) ![]const manifest.Case {
    var cases: std.ArrayList(manifest.Case) = .empty;
    const lines = try sourceLines(io, arena, root);
    for (coding_fonts, 0..) |name, font_index| {
        const wanted: usize = switch (font_index) {
            0 => 500,
            else => 120,
        };
        const stride = @max(1, lines.len / wanted);
        var index: usize = font_index;
        var count: usize = 0;
        while (index < lines.len and count < wanted) : (index += stride) {
            try appendCase(arena, &cases, name, lines[index]);
            count += 1;
        }
    }
    return cases.items;
}

/// Cases are numbered from 1 in generation order, which `SHAPING_CASE` and `xfail.txt` refer to.
fn appendCase(arena: std.mem.Allocator, cases: *std.ArrayList(manifest.Case), font: []const u8, value: []const u8) !void {
    try cases.append(arena, .{
        .line = @intCast(cases.items.len + 1),
        .font = font,
        .script = "latn",
        .features = "",
        .text = try arena.dupe(u8, value),
    });
}

fn appendLigatureSequences(arena: std.mem.Allocator, cases: *std.ArrayList(manifest.Case), font: []const u8, program: *const text.FontProgram) !void {
    var reverse: std.AutoHashMapUnmanaged(u32, u21) = .empty;
    var codepoint: u21 = 0x7E;
    while (codepoint >= 0x20) : (codepoint -= 1) {
        const glyph = program.cmap.glyph(codepoint);
        if (glyph != 0) try reverse.put(arena, glyph, codepoint);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var count: usize = 0;
    for (program.gsub.lookups) |lookup| {
        for (lookup.subtables) |subtable| {
            if (subtable.kind != .ligature_subst) continue;
            const visitor: LigatureVisitor = .{ .arena = arena, .cases = cases, .font = font, .reverse = &reverse, .seen = &seen, .count = &count, .subtable = subtable };
            text.coverage.forEach(subtable.coverage, &visitor, LigatureVisitor.visit);
        }
    }
}

const LigatureVisitor = struct {
    arena: std.mem.Allocator,
    cases: *std.ArrayList(manifest.Case),
    font: []const u8,
    reverse: *std.AutoHashMapUnmanaged(u32, u21),
    seen: *std.StringHashMapUnmanaged(void),
    count: *usize,
    subtable: text.Layout.Subtable,

    fn visit(self: *const LigatureVisitor, first: u32) void {
        self.visitFallible(first) catch {};
    }

    fn visitFallible(self: *const LigatureVisitor, first: u32) !void {
        if (self.count.* >= 300) return;
        const reader = self.subtable.reader;
        const index = text.coverage.index(self.subtable.coverage, first);
        const set_count = try reader.u16At(4);
        if (index >= set_count) return;
        const set = try reader.sub(try reader.u16At(6 + @as(usize, index) * 2));
        for (0..try set.u16At(0)) |ligature_index| {
            const ligature = try set.sub(try set.u16At(2 + ligature_index * 2));
            const components = try ligature.u16At(2);
            var value: std.ArrayList(u8) = .empty;
            var ok = true;
            for (0..components) |component| {
                const glyph: u32 = switch (component) {
                    0 => first,
                    else => try ligature.u16At(4 + (component - 1) * 2),
                };
                const character = self.reverse.get(glyph) orelse {
                    ok = false;
                    break;
                };
                var encoded: [4]u8 = undefined;
                try value.appendSlice(self.arena, encoded[0..try std.unicode.utf8Encode(character, &encoded)]);
            }
            if (!ok or value.items.len < 2) continue;
            const entry = try self.seen.getOrPut(self.arena, value.items);
            if (entry.found_existing) continue;
            try appendCase(self.arena, self.cases, self.font, value.items);
            self.count.* += 1;
        }
    }
};

fn sourceLines(io: Io, arena: std.mem.Allocator, root: Io.Dir) ![]const []const u8 {
    var dir = try root.openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.path, "tables.zig")) continue;
        try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    var lines: std.ArrayList([]const u8) = .empty;
    for (paths.items) |path| {
        const source = try dir.readFileAlloc(io, path, arena, .unlimited);
        var iterator = std.mem.splitScalar(u8, source, '\n');
        while (iterator.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \t\r");
            if (line.len < 8 or line.len > 120) continue;
            try lines.append(arena, line);
        }
    }
    return lines.items;
}
