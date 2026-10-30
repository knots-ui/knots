const std = @import("std");
const text = @import("text");
const manifest = @import("manifest.zig");
const font_digest = @import("digest.zig");
const harfbuzz = @import("harfbuzz.zig");
const suites = @import("suites.zig");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const root_path = args.next() orelse ".";
    var root = try Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);

    root.access(io, manifest.cache_dir, .{}) catch {
        std.debug.print("shaping: {s} is missing, run `zig build fetch` in tests/shaping first\n", .{manifest.cache_dir});
        return error.MissingTestData;
    };

    const fonts_text = try root.readFileAlloc(io, manifest.fonts_path, arena, .unlimited);
    const fonts = try manifest.parseFonts(arena, fonts_text);
    const digests = root.readFileAlloc(io, font_digest.path, arena, .unlimited) catch "";
    var failures: usize = 0;
    for (fonts) |font| {
        if (font.isDirectory()) continue;
        failures += try checkFont(io, init.gpa, arena, root, font, digests);
    }
    const loaded = try suites.load(io, init.gpa, arena, root, fonts);
    var oracle = harfbuzz.Oracle.init();
    defer oracle.deinit();
    std.debug.print("oracle: HarfBuzz {s}\n", .{harfbuzz.version()});
    var cache: FontCache = .{ .gpa = init.gpa, .arena = arena, .io = io, .root = root, .fonts = fonts };
    defer cache.deinit();
    failures += try checkPlans(&cache, &oracle, fonts);
    failures += try checkSuites(&cache, &oracle, loaded, init.environ_map);
    failures += try checkProperties(&cache, io, arena, root, fonts, loaded);
    failures += try checkGraphemeBreakTest(io, arena, root);
    failures += try checkNormalizationTest(io, arena, root);
    if (failures > 0) {
        std.debug.print("shaping: {d} failures\n", .{failures});
        return error.ShapingMismatch;
    }
    std.debug.print("shaping: ok\n", .{});
}

fn checkFont(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root: Io.Dir, font: manifest.FontEntry, digests: []const u8) !usize {
    const path = try font.fontPath(arena);
    const data = try root.readFileAlloc(io, path, arena, .unlimited);
    var program = text.FontProgram.init(gpa, data, 0) catch |err| {
        std.debug.print("{s}: FontProgram failed: {t}\n", .{ font.name, err });
        return 1;
    };
    defer program.deinit();

    const actual = try font_digest.compute(gpa, &program);
    std.debug.print("{s}: {d} glyphs, FontProgram {d} KiB\n", .{ font.name, program.glyph_count, program.memoryBytes() / 1024 });
    const expected = font_digest.find(digests, font.name) orelse {
        std.debug.print("{s}: no digest in {s}, run `zig build digests` in tests/shaping\n", .{ font.name, font_digest.path });
        return 1;
    };
    var failures: usize = 0;
    inline for (comptime std.meta.fieldNames(font_digest.Digest)) |name| {
        if (@field(expected, name) != @field(actual, name)) {
            std.debug.print("{s}: {s} changed from {x} to {x}\n", .{ font.name, name, @field(expected, name), @field(actual, name) });
            failures += 1;
        }
    }
    return failures;
}

const unicode = text.unicode;

fn checkGraphemeBreakTest(io: Io, arena: std.mem.Allocator, root: Io.Dir) !usize {
    const source = try root.readFileAlloc(io, manifest.cache_dir ++ "/ucd/auxiliary/GraphemeBreakTest.txt", arena, .unlimited);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var failures: usize = 0;
    var total: usize = 0;
    var line_number: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        const comment = std.mem.findScalar(u8, raw, '#') orelse raw.len;
        const line = std.mem.trim(u8, raw[0..comment], " \t\r");
        if (line.len == 0) continue;
        var bytes: std.ArrayList(u8) = .empty;
        var expected: std.ArrayList(usize) = .empty;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "\u{00F7}")) {
                if (bytes.items.len > 0) try expected.append(arena, bytes.items.len);
                continue;
            }
            if (std.mem.eql(u8, token, "\u{00D7}")) continue;
            const codepoint = try std.fmt.parseInt(u21, token, 16);
            var buffer: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(codepoint, &buffer);
            try bytes.appendSlice(arena, buffer[0..len]);
        }
        var actual: std.ArrayList(usize) = .empty;
        var iterator = unicode.grapheme.Iterator.init(bytes.items);
        while (iterator.next()) |end| try actual.append(arena, end);
        total += 1;
        if (std.mem.eql(usize, expected.items, actual.items)) continue;
        if (failures < 5) std.debug.print("GraphemeBreakTest:{d}: {s} expected {any} got {any}\n", .{ line_number, line, expected.items, actual.items });
        failures += 1;
    }
    std.debug.print("GraphemeBreakTest: {d}/{d} passed\n", .{ total - failures, total });
    return failures;
}

fn checkNormalizationTest(io: Io, arena: std.mem.Allocator, root: Io.Dir) !usize {
    const source = try root.readFileAlloc(io, manifest.cache_dir ++ "/ucd/NormalizationTest.txt", arena, .unlimited);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var failures: usize = 0;
    var total: usize = 0;
    var line_number: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        if (raw.len == 0 or raw[0] == '#' or raw[0] == '@') continue;
        var columns: [5][]u32 = undefined;
        var fields = std.mem.splitScalar(u8, raw, ';');
        for (&columns) |*column| column.* = try parseCodepoints(arena, fields.next() orelse return error.InvalidNormalizationTest);
        const nfc = columns[1];
        const nfd = columns[2];
        total += 1;
        var ok = true;
        for (columns[0..3]) |column| {
            if (!std.mem.eql(u32, try normalizeD(arena, column), nfd)) ok = false;
            if (!std.mem.eql(u32, try normalizeC(arena, column), nfc)) ok = false;
        }
        for (columns[3..5]) |column| {
            if (!std.mem.eql(u32, try normalizeD(arena, column), columns[4])) ok = false;
            if (!std.mem.eql(u32, try normalizeC(arena, column), columns[3])) ok = false;
        }
        if (ok) continue;
        if (failures < 5) std.debug.print("NormalizationTest:{d}: {s}\n", .{ line_number, raw });
        failures += 1;
    }
    std.debug.print("NormalizationTest: {d}/{d} passed (canonical forms)\n", .{ total - failures, total });
    return failures;
}

fn parseCodepoints(arena: std.mem.Allocator, field: []const u8) ![]u32 {
    var codepoints: std.ArrayList(u32) = .empty;
    var tokens = std.mem.tokenizeScalar(u8, field, ' ');
    while (tokens.next()) |token| try codepoints.append(arena, try std.fmt.parseInt(u32, token, 16));
    return codepoints.items;
}

fn decomposeFully(arena: std.mem.Allocator, out: *std.ArrayList(u32), codepoint: u32) !void {
    const pair = unicode.decompose(codepoint) orelse return out.append(arena, codepoint);
    try decomposeFully(arena, out, pair.first);
    if (pair.second != 0) try decomposeFully(arena, out, pair.second);
}

fn normalizeD(arena: std.mem.Allocator, input: []const u32) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    for (input) |codepoint| try decomposeFully(arena, &out, codepoint);
    const items = out.items;
    var index: usize = 0;
    while (index < items.len) {
        if (unicode.combiningClass(items[index]) == 0) {
            index += 1;
            continue;
        }
        var end = index;
        while (end < items.len and unicode.combiningClass(items[end]) != 0) end += 1;
        std.sort.insertion(u32, items[index..end], {}, struct {
            fn lessThan(_: void, a: u32, b: u32) bool {
                return unicode.combiningClass(a) < unicode.combiningClass(b);
            }
        }.lessThan);
        index = end;
    }
    return items;
}

fn normalizeC(arena: std.mem.Allocator, input: []const u32) ![]u32 {
    const items = try normalizeD(arena, input);
    var out: std.ArrayList(u32) = .empty;
    var starter: ?usize = null;
    var last_class: i16 = -1;
    for (items) |codepoint| {
        const class = unicode.combiningClass(codepoint);
        if (starter) |starter_index| {
            const blocked = last_class != -1 and last_class >= class;
            if (!blocked) {
                if (unicode.compose(out.items[starter_index], codepoint)) |composed| {
                    out.items[starter_index] = composed;
                    continue;
                }
            }
        }
        if (class == 0) {
            starter = out.items.len;
            last_class = -1;
        } else {
            last_class = class;
        }
        try out.append(arena, codepoint);
    }
    return out.items;
}

const FontCache = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    fonts: []const manifest.FontEntry,
    data: std.StringHashMapUnmanaged([]const u8) = .empty,
    programs: std.StringHashMapUnmanaged(*text.FontProgram) = .empty,
    plans: std.StringHashMapUnmanaged(*text.shape.Plan) = .empty,
    harfbuzz_fonts: std.StringHashMapUnmanaged(*harfbuzz.Font) = .empty,

    fn plan(self: *FontCache, case: manifest.Case, config: manifest.Config) !*text.shape.Plan {
        const key = try std.fmt.allocPrint(self.arena, "{s}|{s}|{s}|{t}", .{ case.font, case.script, case.features, config });
        if (self.plans.get(key)) |existing| return existing;
        const program = try self.get(case.font);
        var feature_list: std.ArrayList(text.shape.Plan.Feature) = .empty;
        try feature_list.appendSlice(self.arena, try text.shape.features.parse(self.arena, config.features()));
        try feature_list.appendSlice(self.arena, try text.shape.features.parse(self.arena, case.features));
        var lower: [4]u8 = undefined;
        if (case.script.len != 4) return error.InvalidScript;
        _ = std.ascii.lowerString(&lower, case.script);
        const script = std.meta.stringToEnum(text.unicode.Script, &lower) orelse return error.InvalidScript;
        const result = try self.arena.create(text.shape.Plan);
        result.* = try text.shape.Plan.init(self.gpa, program, .{ .script = script, .features = feature_list.items });
        try self.plans.put(self.arena, key, result);
        return result;
    }

    fn get(self: *FontCache, name: []const u8) !*text.FontProgram {
        if (self.programs.get(name)) |program| return program;
        const program = try self.arena.create(text.FontProgram);
        program.* = try text.FontProgram.init(self.gpa, try self.file(name), 0);
        try self.programs.put(self.arena, name, program);
        return program;
    }

    fn harfbuzzFont(self: *FontCache, name: []const u8) !*harfbuzz.Font {
        if (self.harfbuzz_fonts.get(name)) |font| return font;
        const font = harfbuzz.createFont(try self.file(name));
        try self.harfbuzz_fonts.put(self.arena, name, font);
        return font;
    }

    fn file(self: *FontCache, name: []const u8) ![]const u8 {
        if (self.data.get(name)) |data| return data;
        const entry = manifest.findFont(self.fonts, name) orelse return error.UnknownFont;
        const data = try self.root.readFileAlloc(self.io, try entry.fontPath(self.arena), self.arena, .unlimited);
        try self.data.put(self.arena, name, data);
        return data;
    }

    fn deinit(self: *FontCache) void {
        var fonts = self.harfbuzz_fonts.valueIterator();
        while (fonts.next()) |font| harfbuzz.destroyFont(font.*);
        var plans = self.plans.valueIterator();
        while (plans.next()) |value| value.*.deinit();
        var iterator = self.programs.valueIterator();
        while (iterator.next()) |program| program.*.deinit();
    }
};

const SuiteTotals = struct {
    passed: usize = 0,
    failed: usize = 0,
    xfailed: usize = 0,
    xpassed: usize = 0,
};

fn isSelected(environ: *const std.process.Environ.Map, suite: []const u8, line: u32) bool {
    const selection = environ.get("SHAPING_CASE") orelse return false;
    const colon = std.mem.findScalar(u8, selection, ':') orelse return false;
    if (!std.mem.eql(u8, selection[0..colon], suite)) return false;
    const wanted = std.fmt.parseInt(u32, selection[colon + 1 ..], 10) catch return false;
    return wanted == line;
}

fn checkSuites(cache: *FontCache, oracle: *harfbuzz.Oracle, loaded: []const suites.Suite, environ: *const std.process.Environ.Map) !usize {
    const xfail_source = cache.root.readFileAlloc(cache.io, manifest.xfail_path, cache.arena, .unlimited) catch "";
    const xfails = try manifest.parseXfail(cache.arena, xfail_source);
    var buffer = text.shape.Buffer.init(cache.gpa);
    defer buffer.deinit();
    var expected_arena = std.heap.ArenaAllocator.init(cache.gpa);
    defer expected_arena.deinit();

    var failures: usize = 0;
    for (loaded) |suite| {
        var totals: SuiteTotals = .{};
        var failing: std.ArrayList(u8) = .empty;
        for (std.enums.values(manifest.Config)) |config| {
            for (suite.cases) |case| {
                _ = expected_arena.reset(.retain_capacity);
                const expected = try expectedGlyphs(cache, oracle, expected_arena.allocator(), case, config);
                const xfail = findXfail(xfails, suite.name, case.line, config);
                const report = (xfail == null and totals.failed < 3) or isSelected(environ, suite.name, case.line);
                const ok = try checkCase(&buffer, cache, suite.name, case, config, expected, report);
                countResult(&totals, ok, xfail);
                if (!ok and xfail == null) try failing.print(cache.arena, " {d}:{t}", .{ case.line, config });
                if (!ok and xfail == null) failures += 1;
                if (ok and xfail != null and xfail.?.line != null and xfail.?.config != null) failures += 1;
            }
        }
        if (failing.items.len > 0) std.debug.print("{s} failing:{s}\n", .{ suite.name, failing.items });
        std.debug.print("{s}: {d} passed, {d} failed, {d} expected failures, {d} unexpected passes\n", .{ suite.name, totals.passed, totals.failed, totals.xfailed, totals.xpassed });
    }
    return failures;
}

/// HarfBuzz's output for `case`. A font chain is itemized by knots and each run shaped alone.
fn expectedGlyphs(cache: *FontCache, oracle: *harfbuzz.Oracle, arena: std.mem.Allocator, case: manifest.Case, config: manifest.Config) ![]const manifest.Glyph {
    const features = try joinFeatures(arena, config.features(), case.features);
    if (std.mem.findScalar(u8, case.font, '+') == null) {
        return oracle.shape(arena, try cache.harfbuzzFont(case.font), case.script, features, case.text);
    }
    var programs: std.ArrayList(*const text.FontProgram) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, case.font, '+');
    while (parts.next()) |name| {
        try programs.append(arena, try cache.get(name));
        try names.append(arena, name);
    }
    var runs: std.ArrayList(text.itemize.Run) = .empty;
    try text.itemize.itemize(arena, case.text, programs.items, &runs);
    var glyphs: std.ArrayList(manifest.Glyph) = .empty;
    for (runs.items) |item| {
        const font = try cache.harfbuzzFont(names.items[item.face]);
        const shaped = try oracle.shape(arena, font, @tagName(item.script), features, case.text[item.start..item.end]);
        for (shaped) |*glyph| glyph.cl += item.start;
        try glyphs.appendSlice(arena, shaped);
    }
    return glyphs.items;
}

fn joinFeatures(arena: std.mem.Allocator, config: []const u8, case: []const u8) ![]const u8 {
    if (config.len == 0) return case;
    if (case.len == 0) return config;
    return std.fmt.allocPrint(arena, "{s},{s}", .{ config, case });
}

fn countResult(totals: *SuiteTotals, ok: bool, xfail: ?manifest.Xfail) void {
    if (xfail == null) {
        if (ok) totals.passed += 1 else totals.failed += 1;
        return;
    }
    if (ok) totals.xpassed += 1 else totals.xfailed += 1;
}

fn findXfail(xfails: []const manifest.Xfail, suite: []const u8, line: u32, config: manifest.Config) ?manifest.Xfail {
    for (xfails) |xfail| {
        if (xfail.matches(suite, line, config)) return xfail;
    }
    return null;
}

fn shapeChain(buffer: *text.shape.Buffer, gpa: std.mem.Allocator, cache: *FontCache, case: manifest.Case, config: manifest.Config, glyphs: *std.ArrayList(text.shape.ShapedGlyph)) !void {
    var programs: std.ArrayList(*const text.FontProgram) = .empty;
    defer programs.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var parts = std.mem.splitScalar(u8, case.font, '+');
    while (parts.next()) |name| {
        try programs.append(gpa, try cache.get(name));
        try names.append(gpa, name);
    }
    var runs: std.ArrayList(text.itemize.Run) = .empty;
    defer runs.deinit(gpa);
    try text.itemize.itemize(gpa, case.text, programs.items, &runs);
    for (runs.items) |item| {
        var single = case;
        single.font = names.items[item.face];
        single.script = @tagName(item.script);
        const start = glyphs.items.len;
        try text.shape.shape(buffer, programs.items[item.face], try cache.plan(single, config), case.text[item.start..item.end], gpa, glyphs);
        for (glyphs.items[start..]) |*glyph| glyph.cluster += item.start;
    }
}

fn checkCase(buffer: *text.shape.Buffer, cache: *FontCache, suite: []const u8, case: manifest.Case, config: manifest.Config, expected: []const manifest.Glyph, report: bool) !bool {
    const gpa = cache.gpa;
    var glyphs: std.ArrayList(text.shape.ShapedGlyph) = .empty;
    defer glyphs.deinit(gpa);
    if (std.mem.findScalar(u8, case.font, '+') != null) {
        try shapeChain(buffer, gpa, cache, case, config, &glyphs);
    } else {
        try text.shape.shape(buffer, try cache.get(case.font), try cache.plan(case, config), case.text, gpa, &glyphs);
    }
    const mismatch = firstMismatch(expected, glyphs.items) orelse return true;
    if (report) printMismatch(suite, case, config, expected, glyphs.items, mismatch);
    return false;
}

fn firstMismatch(expected: []const manifest.Glyph, actual: []const text.shape.ShapedGlyph) ?usize {
    for (expected, 0..) |glyph, index| {
        if (index >= actual.len) return index;
        const got = actual[index];
        if (glyph.g != got.glyph or glyph.cl != got.cluster or glyph.ax != got.x_advance or
            glyph.dx != got.x_offset or glyph.dy != got.y_offset or glyph.ay != 0 or glyph.fl != got.flags) return index;
    }
    if (actual.len != expected.len) return expected.len;
    return null;
}

fn printMismatch(suite: []const u8, case: manifest.Case, config: manifest.Config, expected: []const manifest.Glyph, actual: []const text.shape.ShapedGlyph, index: usize) void {
    std.debug.print("{s}:{d} [{t}] {s} {s} {s} \"{s}\": first mismatch at glyph {d}\n", .{ suite, case.line, config, case.font, case.script, case.features, case.text, index });
    const first = index -| 2;
    const last = @min(index + 3, @max(expected.len, actual.len));
    for (first..last) |i| {
        const marker: []const u8 = if (i == index) ">" else " ";
        std.debug.print("  {s}{d:>4} expected ", .{ marker, i });
        printExpected(expected, i);
        std.debug.print("  got ", .{});
        printActual(actual, i);
        std.debug.print("\n", .{});
    }
}

fn printExpected(glyphs: []const manifest.Glyph, i: usize) void {
    if (i >= glyphs.len) return std.debug.print("{s:<44}", .{"-"});
    const g = glyphs[i];
    std.debug.print("g={d:<5} cl={d:<3} ax={d:<5} dx={d:<4} dy={d:<4} fl={d}  ", .{ g.g, g.cl, g.ax, g.dx, g.dy, g.fl });
}

fn printActual(glyphs: []const text.shape.ShapedGlyph, i: usize) void {
    if (i >= glyphs.len) return std.debug.print("-", .{});
    const g = glyphs[i];
    std.debug.print("g={d:<5} cl={d:<3} ax={d:<5} dx={d:<4} dy={d:<4} fl={d}", .{ g.glyph, g.cluster, g.x_advance, g.x_offset, g.y_offset, g.flags });
}

fn checkPlans(cache: *FontCache, oracle: *harfbuzz.Oracle, fonts: []const manifest.FontEntry) !usize {
    var failures: usize = 0;
    var checked: usize = 0;
    for (fonts) |font| {
        if (font.isDirectory()) continue;
        const program = try cache.get(font.name);
        for (manifest.plan_scripts) |script| {
            for (std.enums.values(manifest.Config)) |config| {
                const case: manifest.Case = .{ .line = 0, .font = font.name, .script = script, .features = "", .text = "" };
                const plan = try cache.plan(case, config);
                const expected = try oracle.lookups(cache.arena, try cache.harfbuzzFont(font.name), script, config.features());
                checked += 1;
                for ([_][]const u16{ expected.gsub, expected.gpos }, 0..) |lookups, table| {
                    if (sameLookups(lookups, plan.lookups[table])) continue;
                    failures += 1;
                    std.debug.print("plans: {s} {s} {t} table {d}: expected {any}\n  got ", .{ font.name, script, config, table, lookups });
                    for (plan.lookups[table]) |lookup| std.debug.print("{d},", .{lookup.index});
                    std.debug.print("\n", .{});
                }
                const expected_space = bruteSpaceParticipates(program, expected, plan.apply_kern);
                if (expected_space != plan.space_participates) {
                    failures += 1;
                    std.debug.print("plans: {s} {s} {t}: space_participates expected {} got {}\n", .{ font.name, script, config, expected_space, plan.space_participates });
                }
            }
        }
        failures += try checkPartition(cache.gpa, font.name, program);
    }
    std.debug.print("plans: {d} plans checked, {d} failures\n", .{ checked, failures });
    return failures;
}

fn sameLookups(expected: []const u16, actual: []const text.shape.Plan.LookupMap) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |index, lookup| {
        if (index != lookup.index) return false;
    }
    return true;
}

fn checkPartition(gpa: std.mem.Allocator, name: []const u8, program: *const text.FontProgram) !usize {
    const partition = &program.partition;
    const domain = partition.class_of.len;
    const signatures = try gpa.alloc(u64, domain + 1);
    defer gpa.free(signatures);
    for (signatures, 0..) |*signature, glyph| {
        var hasher = std.hash.Wyhash.init(0);
        for (partition.predicates) |predicate| {
            const value: u32 = switch (predicate.source) {
                .coverage => |table| @intFromBool(text.coverage.contains(table, @intCast(glyph))),
                .class_def => |table| text.class_def.value(table, @intCast(glyph)),
                .glyph => |named| @intFromBool(named == glyph),
            };
            hasher.update(std.mem.asBytes(&value));
        }
        signature.* = hasher.final();
    }
    var class_signature: std.AutoHashMapUnmanaged(u16, u64) = .empty;
    defer class_signature.deinit(gpa);
    var signature_class: std.AutoHashMapUnmanaged(u64, u16) = .empty;
    defer signature_class.deinit(gpa);
    for (signatures, 0..) |signature, glyph| {
        const class = partition.classOf(@intCast(glyph));
        const by_class = try class_signature.getOrPut(gpa, class);
        const by_signature = try signature_class.getOrPut(gpa, signature);
        if (!by_class.found_existing) by_class.value_ptr.* = signature;
        if (!by_signature.found_existing) by_signature.value_ptr.* = class;
        if (by_class.value_ptr.* == signature and by_signature.value_ptr.* == class) continue;
        std.debug.print("partition: {s}: glyph {d} breaks the partition (class {d})\n", .{ name, glyph, class });
        return 1;
    }
    for (partition.predicates, 0..) |predicate, id| {
        for (0..domain) |glyph| {
            const class = partition.class_of[glyph];
            const ok = switch (predicate.source) {
                .coverage => |table| text.coverage.contains(table, @intCast(glyph)) == partition.contains(@intCast(id), class),
                .class_def => |table| text.class_def.value(table, @intCast(glyph)) == partition.value(@intCast(id), class),
                .glyph => |named| (named == glyph) == partition.contains(@intCast(id), class),
            };
            if (ok) continue;
            std.debug.print("partition: {s}: predicate {d} disagrees at glyph {d}\n", .{ name, id, glyph });
            return 1;
        }
    }
    std.debug.print("partition: {s}: {d} classes for {d} glyphs, {d} predicates, {d} KiB\n", .{ name, partition.class_count, domain, partition.predicates.len, partition.memoryBytes() / 1024 });
    return 0;
}

const RawReader = text.Reader;

fn rawLayout(program: *const text.FontProgram, table: usize) ?RawReader {
    return switch (table) {
        0 => program.directory.table("GSUB"),
        else => program.directory.table("GPOS"),
    };
}

fn bruteSpaceParticipates(program: *const text.FontProgram, lookups: harfbuzz.Oracle.Lookups, apply_kern: bool) bool {
    const space = program.space_glyph;
    if (apply_kern) {
        for (program.kern.subtables) |subtable| {
            for (0..program.glyph_count) |other| {
                if (text.Kern.value(subtable, space, @intCast(other)) != 0) return true;
                if (text.Kern.value(subtable, @intCast(other), space) != 0) return true;
            }
        }
    }
    for ([_][]const u16{ lookups.gsub, lookups.gpos }, 0..) |indices, table| {
        const layout_table = rawLayout(program, table) orelse continue;
        var visited: std.StaticBitSet(1 << 16) = .empty;
        for (indices) |index| {
            if (bruteLookup(program, layout_table, table, index, space, &visited, 0)) return true;
        }
    }
    return false;
}

fn rawLookup(layout_table: RawReader, index: u16) ?RawReader {
    const list = layout_table.sub(layout_table.u16At(8) catch return null) catch return null;
    return list.sub(list.u16At(2 + @as(usize, index) * 2) catch return null) catch null;
}

fn bruteLookup(program: *const text.FontProgram, layout_table: RawReader, table: usize, index: u16, space: u32, visited: *std.StaticBitSet(1 << 16), depth: u32) bool {
    if (depth > 64 or visited.isSet(index)) return false;
    visited.set(index);
    const lookup = rawLookup(layout_table, index) orelse return false;
    const declared_type = lookup.u16At(0) catch return false;
    const count = lookup.u16At(4) catch return false;
    const extension: u16 = switch (table) {
        0 => 7,
        else => 9,
    };
    for (0..count) |subtable_index| {
        var subtable = lookup.sub(lookup.u16At(6 + subtable_index * 2) catch continue) catch continue;
        var lookup_type = declared_type;
        if (lookup_type == extension) {
            lookup_type = subtable.u16At(2) catch continue;
            subtable = subtable.sub(subtable.u32At(4) catch continue) catch continue;
        }
        const kind = rawKind(table, lookup_type);
        const compiled: text.Layout.Subtable = .{
            .reader = subtable,
            .kind = kind,
            .format = subtable.u16At(0) catch continue,
            .coverage = subtable,
            .coverage_id = 0,
        };
        if (bruteSubtable(program, compiled, space)) return true;
        var nested = text.participation.NestedLookups.init(withCounts(compiled));
        while (nested.next()) |inner| {
            if (bruteLookup(program, layout_table, table, inner, space, visited, depth + 1)) return true;
        }
    }
    return false;
}

fn withCounts(subtable: text.Layout.Subtable) text.Layout.Subtable {
    var result = subtable;
    if (result.kind != .chain_context or result.format != 3) return result;
    const reader = result.reader;
    result.backtrack_count = reader.u16At(2) catch 0;
    const input_position = 4 + @as(usize, result.backtrack_count) * 2;
    result.input_count = reader.u16At(input_position) catch 0;
    result.lookahead_count = reader.u16At(input_position + 2 + @as(usize, result.input_count) * 2) catch 0;
    return result;
}

fn rawKind(table: usize, lookup_type: u16) text.Layout.Kind {
    const gsub = [_]text.Layout.Kind{ .none, .single_subst, .multiple_subst, .alternate_subst, .ligature_subst, .context, .chain_context, .none, .reverse_chain_subst };
    const gpos = [_]text.Layout.Kind{ .none, .single_pos, .pair_pos, .cursive_pos, .mark_base_pos, .mark_ligature_pos, .mark_mark_pos, .context, .chain_context };
    if (lookup_type >= 9) return .none;
    return switch (table) {
        0 => gsub[lookup_type],
        else => gpos[lookup_type],
    };
}

fn coveredAt(reader: RawReader, position: usize, glyph: u32) bool {
    const offset = reader.u16At(position) catch return false;
    if (offset == 0) return false;
    const table = reader.sub(offset) catch return false;
    if (!text.coverage.validate(table)) return false;
    return text.coverage.contains(table, glyph);
}

fn classAt(reader: RawReader, position: usize, glyph: u32) u16 {
    const offset = reader.u16At(position) catch return 0;
    if (offset == 0) return 0;
    return text.class_def.value(reader.sub(offset) catch return 0, glyph);
}

fn bruteSubtable(program: *const text.FontProgram, subtable: text.Layout.Subtable, space: u32) bool {
    if (program.directory.table("GSUB") == null and program.directory.table("GPOS") == null) return false;
    const reader = subtable.reader;
    const format = subtable.format;
    switch (subtable.kind) {
        .none => return false,
        .single_subst, .multiple_subst, .alternate_subst, .single_pos, .cursive_pos => return coveredAt(reader, 2, space),
        .ligature_subst => {
            if (coveredAt(reader, 2, space)) return true;
            const sets = reader.u16At(4) catch return false;
            for (0..sets) |set_index| {
                const set = reader.sub(reader.u16At(6 + set_index * 2) catch continue) catch continue;
                for (0..(set.u16At(0) catch 0)) |ligature_index| {
                    const ligature = set.sub(set.u16At(2 + ligature_index * 2) catch continue) catch continue;
                    const components = ligature.u16At(2) catch continue;
                    var component: usize = 1;
                    while (component < components) : (component += 1) {
                        if ((ligature.u16At(4 + (component - 1) * 2) catch 0) == space) return true;
                    }
                }
            }
            return false;
        },
        .reverse_chain_subst => {
            if (coveredAt(reader, 2, space)) return true;
            const backtrack = reader.u16At(4) catch return false;
            for (0..backtrack) |i| if (coveredAt(reader, 6 + i * 2, space)) return true;
            const lookahead_position = 6 + @as(usize, backtrack) * 2;
            const lookahead = reader.u16At(lookahead_position) catch return false;
            for (0..lookahead) |i| if (coveredAt(reader, lookahead_position + 2 + i * 2, space)) return true;
            return false;
        },
        .mark_base_pos, .mark_ligature_pos, .mark_mark_pos => return coveredAt(reader, 2, space) or coveredAt(reader, 4, space),
        .pair_pos => {
            if (coveredAt(reader, 2, space)) return true;
            const size1 = text.Layout.valueRecordSize(reader.u16At(4) catch 0);
            const size2 = text.Layout.valueRecordSize(reader.u16At(6) catch 0);
            if (format == 1) {
                const sets = reader.u16At(8) catch return false;
                for (0..sets) |set_index| {
                    const set = reader.sub(reader.u16At(10 + set_index * 2) catch continue) catch continue;
                    for (0..(set.u16At(0) catch 0)) |pair| {
                        if ((set.u16At(2 + pair * (2 + size1 + size2)) catch 0) == space) return true;
                    }
                }
                return false;
            }
            const class2 = classAt(reader, 10, space);
            const class1_count = reader.u16At(12) catch return false;
            const class2_count = reader.u16At(14) catch return false;
            if (class2 >= class2_count) return false;
            for (0..class1_count) |class1| {
                const record = 16 + (class1 * class2_count + class2) * (size1 + size2);
                for (0..(size1 + size2) / 2) |word| {
                    if ((reader.u16At(record + word * 2) catch 0) != 0) return true;
                }
            }
            return false;
        },
        .context, .chain_context => return bruteContext(subtable, space),
    }
}

fn bruteContext(subtable: text.Layout.Subtable, space: u32) bool {
    const reader = subtable.reader;
    const chained = subtable.kind == .chain_context;
    switch (subtable.format) {
        1 => {
            if (coveredAt(reader, 2, space)) return true;
            var rules = text.participation.Rules.init(subtable);
            while (rules.next()) |rule| {
                for (rule.sequences) |sequence| {
                    for (0..sequence.count) |i| if ((sequence.reader.u16At(sequence.position + i * 2) catch 0) == space) return true;
                }
            }
            return false;
        },
        2 => {
            if (coveredAt(reader, 2, space)) return true;
            const values: [3]u16 = switch (chained) {
                true => .{ classAt(reader, 4, space), classAt(reader, 6, space), classAt(reader, 8, space) },
                false => .{ 0, classAt(reader, 4, space), 0 },
            };
            var rules = text.participation.Rules.init(subtable);
            while (rules.next()) |rule| {
                if (rule.first_class == values[1]) return true;
                for (rule.sequences, 0..) |sequence, role| {
                    if (!chained and role != 1) continue;
                    for (0..sequence.count) |i| if ((sequence.reader.u16At(sequence.position + i * 2) catch 0) == values[role]) return true;
                }
            }
            return false;
        },
        3 => {
            if (!chained) {
                const count = reader.u16At(2) catch return false;
                for (0..count) |i| if (coveredAt(reader, 6 + i * 2, space)) return true;
                return false;
            }
            var position: usize = 2;
            for (0..3) |_| {
                const count = reader.u16At(position) catch return false;
                for (0..count) |i| if (coveredAt(reader, position + 2 + i * 2, space)) return true;
                position += 2 + @as(usize, count) * 2;
            }
            return false;
        },
        else => return false,
    }
}

const PropertyTotals = struct {
    fast_path: usize = 0,
    words: usize = 0,
    sizes: usize = 0,
    carets: usize = 0,
    edits: usize = 0,
    failures: usize = 0,

    fn fail(self: *PropertyTotals, comptime format: []const u8, args: anytype) void {
        if (self.failures < 8) std.debug.print("properties: " ++ format ++ "\n", args);
        self.failures += 1;
    }
};

fn checkProperties(cache: *FontCache, io: Io, arena: std.mem.Allocator, root: Io.Dir, fonts: []const manifest.FontEntry, loaded: []const suites.Suite) !usize {
    const gpa = cache.gpa;
    var buffer = text.shape.Buffer.init(gpa);
    defer buffer.deinit();
    var totals: PropertyTotals = .{};
    for (loaded) |suite| {
        for (suite.cases) |case| {
            if (std.mem.findScalar(u8, case.font, '+') != null) continue;
            const program = try cache.get(case.font);
            const plan = try cache.plan(case, .default);
            try checkFastPath(&buffer, gpa, program, plan, case, &totals);
            try checkWords(&buffer, gpa, program, plan, case, &totals);
        }
    }
    try checkLayouts(gpa, io, arena, root, fonts, loaded, &totals);
    try checkIncremental(gpa, io, arena, root, fonts, loaded, &totals);
    std.debug.print("properties: fast path {d}, words {d}, sizes {d}, carets {d}, edits {d} checked, {d} failures\n", .{ totals.fast_path, totals.words, totals.sizes, totals.carets, totals.edits, totals.failures });
    return totals.failures;
}

fn sameGlyphs(a: []const text.shape.ShapedGlyph, b: []const text.shape.ShapedGlyph, compare_flags: bool) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.glyph != y.glyph or x.cluster != y.cluster or x.x_advance != y.x_advance or x.x_offset != y.x_offset or x.y_offset != y.y_offset) return false;
        if (compare_flags and x.flags != y.flags) return false;
    }
    return true;
}

fn checkFastPath(buffer: *text.shape.Buffer, gpa: std.mem.Allocator, program: *const text.FontProgram, plan: *const text.shape.Plan, case: manifest.Case, totals: *PropertyTotals) !void {
    if (!text.shape.shaper.isFastPath(plan, case.text)) return;
    var fast: std.ArrayList(text.shape.ShapedGlyph) = .empty;
    defer fast.deinit(gpa);
    var full: std.ArrayList(text.shape.ShapedGlyph) = .empty;
    defer full.deinit(gpa);
    try text.shape.shape(buffer, program, plan, case.text, gpa, &fast);
    try text.shape.shaper.shapeFull(buffer, program, plan, case.text, gpa, &full);
    totals.fast_path += 1;
    if (!sameGlyphs(fast.items, full.items, true)) totals.fail("fast path differs for {s} \"{s}\"", .{ case.font, case.text });
}

fn checkWords(buffer: *text.shape.Buffer, gpa: std.mem.Allocator, program: *const text.FontProgram, plan: *const text.shape.Plan, case: manifest.Case, totals: *PropertyTotals) !void {
    if (plan.space_participates or std.mem.findScalar(u8, case.text, ' ') == null) return;
    var whole: std.ArrayList(text.shape.ShapedGlyph) = .empty;
    defer whole.deinit(gpa);
    var words: std.ArrayList(text.shape.ShapedGlyph) = .empty;
    defer words.deinit(gpa);
    try text.shape.shape(buffer, program, plan, case.text, gpa, &whole);
    var start: usize = 0;
    while (start < case.text.len) {
        var end = start + 1;
        const is_space = case.text[start] == ' ';
        while (end < case.text.len and (case.text[end] == ' ') == is_space) end += 1;
        const base = words.items.len;
        try text.shape.shape(buffer, program, plan, case.text[start..end], gpa, &words);
        for (words.items[base..]) |*glyph| glyph.cluster += @intCast(start);
        start = end;
    }
    totals.words += 1;
    if (!sameGlyphs(whole.items, words.items, false)) totals.fail("word shaping differs for {s} \"{s}\"", .{ case.font, case.text });
}

fn findSuite(loaded: []const suites.Suite, name: []const u8) []const manifest.Case {
    for (loaded) |suite| {
        if (std.mem.eql(u8, suite.name, name)) return suite.cases;
    }
    return &.{};
}

fn checkLayouts(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, root: Io.Dir, fonts: []const manifest.FontEntry, loaded: []const suites.Suite, totals: *PropertyTotals) !void {
    var sources: std.ArrayList(text.TextSystem.FontSource) = .empty;
    for (fonts) |font| {
        if (font.isDirectory()) continue;
        try sources.append(arena, .{ .name = font.name, .data = try root.readFileAlloc(io, try font.fontPath(arena), arena, .unlimited) });
    }
    var system = try text.TextSystem.init(gpa, sources.items);
    defer system.deinit();
    for ([_][]const manifest.Case{ findSuite(loaded, "marks"), findSuite(loaded, "fallback") }) |list| {
        for (list) |case| {
            var font: []const u8 = case.font;
            if (std.mem.findScalar(u8, case.font, '+') != null) font = "default";
            const small = try system.layout(.{ .text = case.text, .font = font, .size = 12 });
            const large = try system.layout(.{ .text = case.text, .font = font, .size = 37 });
            totals.sizes += 1;
            if (!std.mem.eql(u32, small.glyphs.ids, large.glyphs.ids) or !std.mem.eql(u32, small.glyphs.cluster, large.glyphs.cluster)) {
                totals.fail("glyphs depend on size for {s} \"{s}\"", .{ case.font, case.text });
                continue;
            }
            for (small.glyphs.x, large.glyphs.x) |a, b| {
                if (@abs(a * 37.0 / 12.0 - b) > 1e-3) {
                    totals.fail("positions do not scale for {s} \"{s}\"", .{ case.font, case.text });
                    break;
                }
            }
            try checkCarets(large, case, totals);
        }
        system.endFrame();
    }
}

fn checkCarets(value: *const text.TextLayout, case: manifest.Case, totals: *PropertyTotals) !void {
    var iterator = text.unicode.grapheme.Iterator.init(case.text);
    var boundary: u32 = 0;
    while (true) {
        const point = value.pointForByte(boundary);
        const back = value.byteForPoint(.{ .x = point.x + 0.001, .y = point.y + 0.5 });
        totals.carets += 1;
        if (back != boundary) {
            const back_point = value.pointForByte(back);
            if (@abs(back_point.x - point.x) > 1e-3 or back_point.y != point.y) totals.fail("caret at byte {d} came back as {d} for {s} \"{s}\"", .{ boundary, back, case.font, case.text });
        }
        boundary = @intCast(iterator.next() orelse break);
    }
}

fn checkIncremental(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, root: Io.Dir, fonts: []const manifest.FontEntry, loaded: []const suites.Suite, totals: *PropertyTotals) !void {
    var lines: std.ArrayList(u8) = .empty;
    for (findSuite(loaded, "real-code")) |case| {
        if (!std.mem.eql(u8, case.font, "fira-code")) continue;
        try lines.appendSlice(arena, case.text);
        try lines.append(arena, ' ');
    }
    const long_text = lines.items[0..@min(lines.items.len, 600)];
    const entry = manifest.findFont(fonts, "fira-code") orelse return;
    const data = try root.readFileAlloc(io, try entry.fontPath(arena), arena, .unlimited);
    var system = try text.TextSystem.init(gpa, &.{.{ .name = "fira-code", .data = data }});
    defer system.deinit();
    var reference = try text.TextSystem.init(gpa, &.{.{ .name = "fira-code", .data = data }});
    defer reference.deinit();
    var edited: std.ArrayList(u8) = .empty;
    try edited.appendSlice(arena, long_text);
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const alphabet = "abc=!<>-+ ()";
    _ = try system.layout(.{ .text = edited.items, .size = 14 });
    for (0..300) |round| {
        const at = random.uintLessThan(usize, edited.items.len);
        const character = alphabet[random.uintLessThan(usize, alphabet.len)];
        switch (round % 3) {
            0 => edited.items[at] = character,
            1 => try edited.insert(arena, at, character),
            else => _ = edited.orderedRemove(at),
        }
        const incremental = try system.layout(.{ .text = edited.items, .size = 14 });
        const full = try reference.layout(.{ .text = edited.items, .size = 14 });
        totals.edits += 1;
        if (!std.mem.eql(u32, incremental.glyphs.ids, full.glyphs.ids) or !std.mem.eql(u32, incremental.glyphs.cluster, full.glyphs.cluster) or !std.mem.eql(f32, incremental.glyphs.advance, full.glyphs.advance)) {
            if (totals.failures == 0) {
                std.debug.print("lens {d} {d}\n", .{ incremental.glyphs.ids.len, full.glyphs.ids.len });
                for (0..@min(incremental.glyphs.ids.len, full.glyphs.ids.len)) |i| {
                    if (incremental.glyphs.ids[i] != full.glyphs.ids[i] or incremental.glyphs.cluster[i] != full.glyphs.cluster[i] or incremental.glyphs.advance[i] != full.glyphs.advance[i]) {
                        std.debug.print("at {d}: {d}/{d}/{d} vs {d}/{d}/{d}\n", .{ i, incremental.glyphs.ids[i], incremental.glyphs.cluster[i], incremental.glyphs.advance[i], full.glyphs.ids[i], full.glyphs.cluster[i], full.glyphs.advance[i] });
                        break;
                    }
                }
            }
            totals.fail("incremental reshaping differs after editing byte {d}", .{at});
        }
        system.endFrame();
        reference.endFrame();
        reference.previous.plan = null;
    }
}
