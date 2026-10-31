const std = @import("std");

const Io = std.Io;

const codepoint_count: usize = 0x110000;
const unicode_version = "18.0.0";

const general_categories = [_][]const u8{
    "Cc", "Cf", "Cn", "Co", "Cs", "Ll", "Lm", "Lo", "Lt", "Lu",
    "Mc", "Me", "Mn", "Nd", "Nl", "No", "Pc", "Pd", "Pe", "Pf",
    "Pi", "Po", "Ps", "Sc", "Sk", "Sm", "So", "Zl", "Zp", "Zs",
};

const grapheme_breaks = [_][]const u8{
    "Other",   "CR",          "LF", "Control", "Extend", "ZWJ", "Regional_Indicator",
    "Prepend", "SpacingMark", "L",  "V",       "T",      "LV",  "LVT",
};

const conjunct_breaks = [_][]const u8{ "None", "Linker", "Consonant", "Extend" };

const Props = struct {
    general_category: u5 = 2,
    combining_class: u8 = 0,
    script: u8 = 0,
    grapheme_break: u4 = 0,
    extended_pictographic: bool = false,
    default_ignorable: bool = false,
    conjunct_break: u2 = 0,

    fn pack(props: Props) u32 {
        return @as(u32, props.general_category) |
            @as(u32, props.combining_class) << 5 |
            @as(u32, props.script) << 13 |
            @as(u32, props.grapheme_break) << 21 |
            @as(u32, @intFromBool(props.extended_pictographic)) << 25 |
            @as(u32, @intFromBool(props.default_ignorable)) << 26 |
            @as(u32, props.conjunct_break) << 27;
    }
};

const Decomposition = struct { codepoint: u32, first: u32, second: u32 };
const Composition = struct { first: u32, second: u32, composed: u32 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const ucd_path = args.next() orelse return error.MissingUcdPath;
    const out_path = args.next() orelse return error.MissingOutputPath;
    var ucd = try Io.Dir.cwd().openDir(io, ucd_path, .{});
    defer ucd.close(io);

    const props = try arena.alloc(Props, codepoint_count);
    @memset(props, .{});

    const scripts = try parseScriptAliases(arena, try readFile(io, arena, ucd, "PropertyValueAliases.txt"));
    const unknown_script = indexOfName(scripts.long, "Unknown") orelse return error.MissingUnknownScript;
    for (props) |*entry| entry.script = @intCast(unknown_script);

    const unicode_data = try readFile(io, arena, ucd, "UnicodeData.txt");
    const decompositions = try parseUnicodeData(arena, unicode_data, props);
    const exclusions = try parseBinaryProperty(arena, try readFile(io, arena, ucd, "DerivedNormalizationProps.txt"), "Full_Composition_Exclusion");
    const compositions = try buildCompositions(arena, decompositions, exclusions);

    var script_lines = Fields.init(try readFile(io, arena, ucd, "Scripts.txt"));
    while (script_lines.next()) |fields| {
        const script = indexOfName(scripts.long, fields.value) orelse return error.UnknownScript;
        for (fields.first..fields.last + 1) |codepoint| props[codepoint].script = @intCast(script);
    }

    var grapheme_lines = Fields.init(try readFile(io, arena, ucd, "auxiliary/GraphemeBreakProperty.txt"));
    while (grapheme_lines.next()) |fields| {
        const value = indexOfName(&grapheme_breaks, fields.value) orelse return error.UnknownGraphemeBreak;
        for (fields.first..fields.last + 1) |codepoint| props[codepoint].grapheme_break = @intCast(value);
    }

    var emoji_lines = Fields.init(try readFile(io, arena, ucd, "emoji/emoji-data.txt"));
    while (emoji_lines.next()) |fields| {
        if (!std.mem.eql(u8, fields.value, "Extended_Pictographic")) continue;
        for (fields.first..fields.last + 1) |codepoint| props[codepoint].extended_pictographic = true;
    }

    var core_lines = Fields.init(try readFile(io, arena, ucd, "DerivedCoreProperties.txt"));
    while (core_lines.next()) |fields| {
        if (std.mem.eql(u8, fields.value, "Default_Ignorable_Code_Point")) {
            for (fields.first..fields.last + 1) |codepoint| props[codepoint].default_ignorable = true;
            continue;
        }
        if (std.mem.startsWith(u8, fields.value, "InCB")) {
            const value_start = std.mem.findScalar(u8, fields.value, ';') orelse return error.InvalidInCB;
            const name = std.mem.trim(u8, fields.value[value_start + 1 ..], " ");
            const value = indexOfName(&conjunct_breaks, name) orelse return error.UnknownInCB;
            for (fields.first..fields.last + 1) |codepoint| props[codepoint].conjunct_break = @intCast(value);
        }
    }

    var mirrors: std.ArrayList([2]u32) = .empty;
    var mirror_lines = Fields.init(try readFile(io, arena, ucd, "BidiMirroring.txt"));
    while (mirror_lines.next()) |fields| {
        const mirror = try std.fmt.parseInt(u32, fields.value, 16);
        try mirrors.append(arena, .{ fields.first, mirror });
    }

    std.mem.sort([2]u32, mirrors.items, {}, struct {
        fn lessThan(_: void, a: [2]u32, b: [2]u32) bool {
            return a[0] < b[0];
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    try writeHeader(arena, &out, scripts.short);
    try writeTrie(arena, &out, props);
    try writeDecompositions(arena, &out, decompositions);
    try writeCompositions(arena, &out, compositions);
    try writeMirrors(arena, &out, mirrors.items);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.items });
}

fn readFile(io: Io, arena: std.mem.Allocator, dir: Io.Dir, path: []const u8) ![]const u8 {
    return dir.readFileAlloc(io, path, arena, .unlimited);
}

fn indexOfName(names: []const []const u8, wanted: []const u8) ?usize {
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, name, wanted)) return index;
    }
    return null;
}

const Fields = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    const Entry = struct { first: u32, last: u32, value: []const u8 };

    fn init(source: []const u8) Fields {
        return .{ .lines = std.mem.splitScalar(u8, source, '\n') };
    }

    fn next(self: *Fields) ?Entry {
        while (self.lines.next()) |raw| {
            const comment = std.mem.findScalar(u8, raw, '#') orelse raw.len;
            const line = std.mem.trim(u8, raw[0..comment], " \t\r");
            if (line.len == 0) continue;
            const separator = std.mem.findScalar(u8, line, ';') orelse continue;
            const range = std.mem.trim(u8, line[0..separator], " ");
            const value = std.mem.trim(u8, line[separator + 1 ..], " ");
            const dots = std.mem.find(u8, range, "..");
            const first_text = range[0 .. dots orelse range.len];
            const first = std.fmt.parseInt(u32, first_text, 16) catch continue;
            const last = lastOfRange(range, dots) catch continue;
            return .{ .first = first, .last = last, .value = value };
        }
        return null;
    }

    fn lastOfRange(range: []const u8, dots: ?usize) !u32 {
        const index = dots orelse return std.fmt.parseInt(u32, range, 16);
        return std.fmt.parseInt(u32, range[index + 2 ..], 16);
    }
};

const ScriptAliases = struct {
    short: []const []const u8,
    long: []const []const u8,
};

fn parseScriptAliases(arena: std.mem.Allocator, source: []const u8) !ScriptAliases {
    var short: std.ArrayList([]const u8) = .empty;
    var long: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const comment = std.mem.findScalar(u8, raw, '#') orelse raw.len;
        var fields = std.mem.splitScalar(u8, raw[0..comment], ';');
        const property = std.mem.trim(u8, fields.next() orelse continue, " \t\r");
        if (!std.mem.eql(u8, property, "sc")) continue;
        try short.append(arena, std.mem.trim(u8, fields.next() orelse return error.InvalidAlias, " \t\r"));
        try long.append(arena, std.mem.trim(u8, fields.next() orelse return error.InvalidAlias, " \t\r"));
    }
    if (short.items.len > 256) return error.TooManyScripts;
    return .{ .short = short.items, .long = long.items };
}

fn parseUnicodeData(arena: std.mem.Allocator, source: []const u8, props: []Props) ![]Decomposition {
    var decompositions: std.ArrayList(Decomposition) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var range_start: ?u32 = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields: [15][]const u8 = undefined;
        var iterator = std.mem.splitScalar(u8, line, ';');
        for (&fields) |*field| field.* = iterator.next() orelse return error.InvalidUnicodeData;
        const codepoint = try std.fmt.parseInt(u32, fields[0], 16);
        const category: u5 = @intCast(indexOfName(&general_categories, fields[2]) orelse return error.UnknownCategory);
        const combining_class = try std.fmt.parseInt(u8, fields[3], 10);
        if (std.mem.endsWith(u8, fields[1], ", First>")) {
            range_start = codepoint;
            continue;
        }
        const first = range_start orelse codepoint;
        range_start = null;
        for (first..codepoint + 1) |index| {
            props[index].general_category = category;
            props[index].combining_class = combining_class;
        }
        const mapping = fields[5];
        if (mapping.len == 0 or mapping[0] == '<') continue;
        var parts = std.mem.tokenizeScalar(u8, mapping, ' ');
        const a = try std.fmt.parseInt(u32, parts.next().?, 16);
        const b = try parseOptionalHex(parts.next());
        if (parts.next() != null) return error.LongCanonicalDecomposition;
        try decompositions.append(arena, .{ .codepoint = codepoint, .first = a, .second = b });
    }
    return decompositions.items;
}

fn parseOptionalHex(text: ?[]const u8) !u32 {
    const value = text orelse return 0;
    return std.fmt.parseInt(u32, value, 16);
}

fn parseBinaryProperty(arena: std.mem.Allocator, source: []const u8, name: []const u8) !std.AutoHashMapUnmanaged(u32, void) {
    var set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var lines = Fields.init(source);
    while (lines.next()) |fields| {
        if (!std.mem.eql(u8, fields.value, name)) continue;
        for (fields.first..fields.last + 1) |codepoint| try set.put(arena, @intCast(codepoint), {});
    }
    return set;
}

fn buildCompositions(arena: std.mem.Allocator, decompositions: []const Decomposition, exclusions: std.AutoHashMapUnmanaged(u32, void)) ![]Composition {
    var compositions: std.ArrayList(Composition) = .empty;
    for (decompositions) |entry| {
        if (entry.second == 0 or exclusions.contains(entry.codepoint)) continue;
        try compositions.append(arena, .{ .first = entry.first, .second = entry.second, .composed = entry.codepoint });
    }
    std.mem.sort(Composition, compositions.items, {}, struct {
        fn lessThan(_: void, a: Composition, b: Composition) bool {
            if (a.first != b.first) return a.first < b.first;
            return a.second < b.second;
        }
    }.lessThan);
    return compositions.items;
}

fn writeHeader(arena: std.mem.Allocator, out: *std.ArrayList(u8), scripts: []const []const u8) !void {
    try out.print(arena,
        \\// Generated by tests/shaping/gen_unicode.zig from the Unicode {s} UCD. Do not edit.
        \\
        \\pub const unicode_version = "{s}";
        \\
        \\pub const Script = enum(u8) {{
        \\
    , .{ unicode_version, unicode_version });
    for (scripts) |script| {
        var lower: [4]u8 = undefined;
        _ = std.ascii.lowerString(&lower, script);
        try out.print(arena, "    {s},\n", .{lower});
    }
    try out.appendSlice(arena, "};\n\n");
}

const Trie = struct {
    shift: u5,
    stage1: []u16,
    stage2: []u16,
    values: []u32,

    fn bytes(trie: Trie) usize {
        return trie.stage1.len * 2 + trie.stage2.len * 2 + trie.values.len * 4;
    }
};

fn buildTrie(arena: std.mem.Allocator, packed_props: []const u32, shift: u5) !Trie {
    var value_index: std.AutoArrayHashMapUnmanaged(u32, u16) = .empty;
    const block_len = @as(usize, 1) << shift;
    var blocks: std.StringArrayHashMapUnmanaged(u16) = .empty;
    var stage2: std.ArrayList(u16) = .empty;
    const stage1 = try arena.alloc(u16, codepoint_count >> shift);
    const block = try arena.alloc(u16, block_len);
    for (stage1, 0..) |*slot, block_number| {
        for (block, 0..) |*entry, offset| {
            const value = packed_props[block_number * block_len + offset];
            const result = try value_index.getOrPut(arena, value);
            if (!result.found_existing) result.value_ptr.* = @intCast(value_index.count() - 1);
            entry.* = result.value_ptr.*;
        }
        const key = try arena.dupe(u8, std.mem.sliceAsBytes(block));
        const result = try blocks.getOrPut(arena, key);
        if (!result.found_existing) {
            result.value_ptr.* = @intCast(stage2.items.len / block_len);
            try stage2.appendSlice(arena, block);
        }
        slot.* = result.value_ptr.*;
    }
    return .{ .shift = shift, .stage1 = stage1, .stage2 = stage2.items, .values = value_index.keys() };
}

fn writeTrie(arena: std.mem.Allocator, out: *std.ArrayList(u8), props: []const Props) !void {
    const packed_props = try arena.alloc(u32, props.len);
    for (packed_props, props) |*slot, entry| slot.* = entry.pack();
    var best: ?Trie = null;
    for ([_]u5{ 5, 6, 7, 8 }) |shift| {
        const trie = try buildTrie(arena, packed_props, shift);
        if (best == null or trie.bytes() < best.?.bytes()) best = trie;
    }
    const trie = best.?;
    try out.print(arena, "// {d} bytes\npub const block_shift = {d};\n\n", .{ trie.bytes(), trie.shift });
    try writeArray(arena, out, "stage1", "u16", trie.stage1);
    try writeArray(arena, out, "stage2", "u16", trie.stage2);
    try writeArray(arena, out, "values", "u32", trie.values);
}

fn writeArray(arena: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, comptime_type: []const u8, items: anytype) !void {
    try out.print(arena, "pub const {s} = [_]{s}{{", .{ name, comptime_type });
    for (items, 0..) |item, index| {
        if (index % 16 == 0) try out.appendSlice(arena, "\n   ");
        try out.print(arena, " {d},", .{item});
    }
    try out.appendSlice(arena, "\n};\n\n");
}

fn writeDecompositions(arena: std.mem.Allocator, out: *std.ArrayList(u8), decompositions: []const Decomposition) !void {
    try out.appendSlice(arena, "pub const Decomposition = struct { codepoint: u32, first: u32, second: u32 };\n\npub const decompositions = [_]Decomposition{\n");
    for (decompositions) |entry| {
        try out.print(arena, "    .{{ .codepoint = 0x{X}, .first = 0x{X}, .second = 0x{X} }},\n", .{ entry.codepoint, entry.first, entry.second });
    }
    try out.appendSlice(arena, "};\n\n");
}

fn writeCompositions(arena: std.mem.Allocator, out: *std.ArrayList(u8), compositions: []const Composition) !void {
    try out.appendSlice(arena, "pub const Composition = struct { first: u32, second: u32, composed: u32 };\n\npub const compositions = [_]Composition{\n");
    for (compositions) |entry| {
        try out.print(arena, "    .{{ .first = 0x{X}, .second = 0x{X}, .composed = 0x{X} }},\n", .{ entry.first, entry.second, entry.composed });
    }
    try out.appendSlice(arena, "};\n\n");
}

fn writeMirrors(arena: std.mem.Allocator, out: *std.ArrayList(u8), mirrors: []const [2]u32) !void {
    try out.appendSlice(arena, "pub const mirrors = [_][2]u32{\n");
    for (mirrors) |entry| try out.print(arena, "    .{{ 0x{X}, 0x{X} }},\n", .{ entry[0], entry[1] });
    try out.appendSlice(arena, "};\n");
}
