const std = @import("std");

pub const cache_dir = ".cache/shaping";
pub const fonts_path = "tests/shaping/fonts.txt";
pub const cases_dir = "tests/shaping/cases";
pub const xfail_path = "tests/shaping/xfail.txt";

pub const plan_scripts = [_][]const u8{ "latn", "grek", "cyrl", "hani", "zyyy" };

pub const Config = enum {
    none,
    @"gsub-only",
    default,

    pub fn features(config: Config) []const u8 {
        return switch (config) {
            .none => "-abvm,-blwm,-ccmp,-locl,-mark,-mkmk,-rlig,-calt,-clig,-curs,-dist,-kern,-liga,-rclt,-rvrn,-ltra,-ltrm",
            .@"gsub-only" => "-kern,-mark,-mkmk,-curs,-dist,-abvm,-blwm",
            .default => "",
        };
    }
};

pub const FontEntry = struct {
    name: []const u8,
    url: []const u8,
    sha256: []const u8,
    license: []const u8,

    pub fn archivePath(entry: FontEntry) ?[]const u8 {
        const hash = std.mem.findScalar(u8, entry.url, '#') orelse return null;
        return entry.url[hash + 1 ..];
    }

    pub fn downloadUrl(entry: FontEntry) []const u8 {
        const hash = std.mem.findScalar(u8, entry.url, '#') orelse return entry.url;
        return entry.url[0..hash];
    }

    pub fn localPath(entry: FontEntry) ?[]const u8 {
        if (!std.mem.startsWith(u8, entry.url, "file:")) return null;
        return entry.url["file:".len..];
    }

    pub fn isDirectory(entry: FontEntry) bool {
        const path = entry.archivePath() orelse return false;
        return std.mem.endsWith(u8, path, "/");
    }

    pub fn fontPath(entry: FontEntry, arena: std.mem.Allocator) ![]const u8 {
        if (entry.localPath()) |path| return path;
        const source = entry.archivePath() orelse entry.downloadUrl();
        const extension = std.fs.path.extension(source);
        return std.fmt.allocPrint(arena, "{s}/fonts/{s}{s}", .{ cache_dir, entry.name, extension });
    }
};

pub fn parseFonts(arena: std.mem.Allocator, text: []const u8) ![]FontEntry {
    var entries: std.ArrayList(FontEntry) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, trimmed, '|');
        var values: [4][]const u8 = undefined;
        for (&values) |*value| {
            value.* = std.mem.trim(u8, fields.next() orelse return error.InvalidFontsFile, " \t");
        }
        try entries.append(arena, .{ .name = values[0], .url = values[1], .sha256 = values[2], .license = values[3] });
    }
    return entries.items;
}

pub fn findFont(entries: []const FontEntry, name: []const u8) ?FontEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub const Case = struct {
    line: u32,
    font: []const u8,
    script: []const u8,
    features: []const u8,
    text: []const u8,
};

pub fn parseCases(arena: std.mem.Allocator, source: []const u8) ![]Case {
    var cases: std.ArrayList(Case) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: u32 = 0;
    while (lines.next()) |line| {
        line_number += 1;
        if (line.len == 0 or line[0] == '#') continue;
        var rest = line;
        var values: [3][]const u8 = undefined;
        for (&values) |*value| {
            const bar = std.mem.findScalar(u8, rest, '|') orelse return error.InvalidCaseLine;
            value.* = std.mem.trim(u8, rest[0..bar], " \t");
            rest = rest[bar + 1 ..];
        }
        if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        try cases.append(arena, .{
            .line = line_number,
            .font = values[0],
            .script = values[1],
            .features = values[2],
            .text = try unescape(arena, rest),
        });
    }
    return cases.items;
}

pub fn unescape(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\' or index + 1 >= text.len) {
            try out.append(arena, text[index]);
            index += 1;
            continue;
        }
        switch (text[index + 1]) {
            '\\' => {
                try out.append(arena, '\\');
                index += 2;
            },
            'u' => {
                const open = index + 2;
                if (open >= text.len or text[open] != '{') return error.InvalidEscape;
                const close = std.mem.findScalarPos(u8, text, open, '}') orelse return error.InvalidEscape;
                const codepoint = try std.fmt.parseInt(u21, text[open + 1 .. close], 16);
                var buffer: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(codepoint, &buffer);
                try out.appendSlice(arena, buffer[0..len]);
                index = close + 1;
            },
            else => return error.InvalidEscape,
        }
    }
    return out.items;
}

/// One glyph as HarfBuzz shapes it: id, cluster byte, offset, advance and glyph flags.
pub const Glyph = struct {
    g: u32,
    cl: u32,
    dx: i32 = 0,
    dy: i32 = 0,
    ax: i32 = 0,
    ay: i32 = 0,
    fl: u32 = 0,
};

pub const Xfail = struct {
    suite: []const u8,
    line: ?u32,
    config: ?Config,
    reason: []const u8,

    pub fn matches(xfail: Xfail, suite: []const u8, line: u32, config: Config) bool {
        if (!std.mem.eql(u8, xfail.suite, suite)) return false;
        if (xfail.line) |wanted| {
            if (wanted != line) return false;
        }
        if (xfail.config) |wanted| {
            if (wanted != config) return false;
        }
        return true;
    }
};

pub fn parseXfail(arena: std.mem.Allocator, source: []const u8) ![]Xfail {
    var entries: std.ArrayList(Xfail) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, trimmed, '|');
        const target = std.mem.trim(u8, fields.next() orelse return error.InvalidXfail, " ");
        const reason = std.mem.trim(u8, fields.next() orelse return error.InvalidXfail, " ");
        var parts = std.mem.splitScalar(u8, target, ':');
        const suite = parts.next() orelse return error.InvalidXfail;
        const line_part = parts.next() orelse return error.InvalidXfail;
        const config_part = parts.next();
        try entries.append(arena, .{
            .suite = suite,
            .line = try parseXfailLine(line_part),
            .config = try parseXfailConfig(config_part),
            .reason = reason,
        });
    }
    return entries.items;
}

fn parseXfailLine(text: []const u8) !?u32 {
    if (std.mem.eql(u8, text, "*")) return null;
    return try std.fmt.parseInt(u32, text, 10);
}

fn parseXfailConfig(text: ?[]const u8) !?Config {
    const name = text orelse return null;
    return std.meta.stringToEnum(Config, name) orelse error.InvalidXfail;
}

test "case escapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = try parseCases(arena, "default | latn | +liga | a\\\\b\\u{007C}c\\u{200D}\\u{1F600}\\u{0009}");
    try std.testing.expectEqualStrings("a\\b|c\u{200D}\u{1F600}\t", cases[0].text);
    try std.testing.expectEqualStrings("+liga", cases[0].features);
}
