//! Text benchmarks: cold shaping against HarfBuzz, the fast path, a warm frame, paging,
//! keystrokes and laying out a long document. Run with -Doptimize=ReleaseFast.

const std = @import("std");
const text = @import("text");
const manifest = @import("manifest.zig");
const harfbuzz = @import("harfbuzz.zig");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const root_path = args.next() orelse ".";
    var root = try Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);
    root.access(io, manifest.cache_dir, .{}) catch {
        std.debug.print("bench: {s} is missing, run `zig build fetch` in tests/shaping first\n", .{manifest.cache_dir});
        return;
    };
    const fonts = try manifest.parseFonts(arena, try root.readFileAlloc(io, manifest.fonts_path, arena, .unlimited));
    const lines = try sourceLines(io, arena, root);
    var bytes: usize = 0;
    for (lines) |line| bytes += line.len;
    std.debug.print("corpus: {d} lines, {d} bytes of .zig sources\n", .{ lines.len, bytes });

    for ([_][]const u8{ "fira-code", "jetbrains-mono", "cascadia-code", "noto-sans" }) |name| {
        try benchCold(io, gpa, arena, root, fonts, name, lines);
    }
    try benchFastPath(io, gpa, arena, root, fonts, lines);
    try benchFrames(io, gpa, arena, root, fonts, lines);
    try benchDocument(io, gpa, arena, root, fonts, lines);
}

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn ms(nanoseconds: i96) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / 1e6;
}

fn loadFont(io: Io, arena: std.mem.Allocator, root: Io.Dir, fonts: []const manifest.FontEntry, name: []const u8) ![]const u8 {
    const entry = manifest.findFont(fonts, name) orelse return error.UnknownFont;
    return root.readFileAlloc(io, try entry.fontPath(arena), arena, .unlimited);
}

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
        while (iterator.next()) |line| {
            if (line.len == 0) continue;
            try lines.append(arena, line);
        }
    }
    return lines.items;
}

/// Every line shaped once per pass, best of five, against HarfBuzz shaping the same lines in process.
fn benchCold(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root: Io.Dir, fonts: []const manifest.FontEntry, name: []const u8, lines: []const []const u8) !void {
    const data = try loadFont(io, arena, root, fonts, name);
    var program = try text.FontProgram.init(gpa, data, 0);
    defer program.deinit();
    var plan = try text.shape.Plan.init(gpa, &program, .{});
    defer plan.deinit();
    var buffer = text.shape.Buffer.init(gpa);
    defer buffer.deinit();
    var out: std.ArrayList(text.shape.ShapedGlyph) = .empty;
    defer out.deinit(gpa);
    var best: i96 = std.math.maxInt(i96);
    for (0..5) |_| {
        const start = now(io);
        for (lines) |line| {
            out.clearRetainingCapacity();
            try text.shape.shaper.shapeFull(&buffer, &program, &plan, line, gpa, &out);
        }
        best = @min(best, now(io) - start);
    }

    const font = harfbuzz.createFont(data);
    defer harfbuzz.destroyFont(font);
    var oracle = harfbuzz.Oracle.init();
    defer oracle.deinit();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var hb_best: i96 = std.math.maxInt(i96);
    for (0..5) |_| {
        const start = now(io);
        for (lines) |line| {
            _ = scratch.reset(.retain_capacity);
            _ = try oracle.shape(scratch.allocator(), font, "latn", "", line);
        }
        hb_best = @min(hb_best, now(io) - start);
    }
    std.debug.print("cold shaping {s}: {d:.1} ms, HarfBuzz {d:.1} ms, {d:.2}x faster\n", .{ name, ms(best), ms(hb_best), @as(f64, @floatFromInt(hb_best)) / @as(f64, @floatFromInt(best)) });
}

fn benchFastPath(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root: Io.Dir, fonts: []const manifest.FontEntry, lines: []const []const u8) !void {
    const data = try loadFont(io, arena, root, fonts, "noto-sans-mono");
    var program = try text.FontProgram.init(gpa, data, 0);
    defer program.deinit();
    var plan = try text.shape.Plan.init(gpa, &program, .{});
    defer plan.deinit();
    var buffer = text.shape.Buffer.init(gpa);
    defer buffer.deinit();
    var out: std.ArrayList(text.shape.ShapedGlyph) = .empty;
    defer out.deinit(gpa);
    var corpus: std.ArrayList([]const u8) = .empty;
    var total: usize = 0;
    while (total < 1 << 20) {
        const before = total;
        for (lines) |line| {
            if (total >= 1 << 20) break;
            if (!text.shape.shaper.isFastPath(&plan, line)) continue;
            try corpus.append(arena, line);
            total += line.len;
        }
        if (total == before) break;
    }
    if (total == 0) return;
    var best: i96 = std.math.maxInt(i96);
    for (0..5) |_| {
        const start = now(io);
        for (corpus.items) |line| {
            out.clearRetainingCapacity();
            try text.shape.shape(&buffer, &program, &plan, line, gpa, &out);
        }
        best = @min(best, now(io) - start);
    }
    std.debug.print("fast path: {d:.2} ns/byte over {d} KiB\n", .{ @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(total)), total / 1024 });
}

const Instance = [8]f32;

/// What painting a laid-out line costs: one instance per glyph with its store slot and bounds.
fn emit(system: *text.TextSystem, layout: *const text.TextLayout, row: usize, instances: *std.ArrayList(Instance)) !void {
    const has_slots = comptime @hasDecl(text.TextSystem, "resolveSlots");
    const slots = if (has_slots) try system.resolveSlots(layout) else &[_]u32{};
    for (layout.runs) |run| {
        for (run.glyph_start..run.glyph_end) |index| {
            var slot: u32 = undefined;
            var bounds: [4]f32 = undefined;
            if (has_slots) {
                slot = slots[index];
                if (slot == 0 or slot == text.TextLayout.layered_slot) continue;
                system.glyph_store.touch(slot);
                bounds = system.glyph_store.table.items[slot].bounds;
            } else {
                const record = try system.glyphRecord(run.face, layout.glyphs.ids[index]);
                if (record.isEmpty()) continue;
                slot = record.slot;
                bounds = .{ record.bounds_em_min[0], record.bounds_em_min[1], record.bounds_em_max[0], record.bounds_em_max[1] };
            }
            try instances.append(system.gpa, .{ @floatCast(layout.glyphs.x[index]), @as(f32, @floatFromInt(row)) * layout.line_height, 14, @bitCast(slot), bounds[0], bounds[1], bounds[2], bounds[3] });
        }
    }
}

fn benchFrames(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root: Io.Dir, fonts: []const manifest.FontEntry, lines: []const []const u8) !void {
    const data = try loadFont(io, arena, root, fonts, "fira-code");
    var system = try text.TextSystem.init(gpa, &.{.{ .name = "fira-code", .data = data }});
    defer system.deinit();
    var visible: [80][]const u8 = undefined;
    var picked: usize = 0;
    for (lines) |line| {
        if (picked == visible.len) break;
        if (line.len < 60) continue;
        visible[picked] = line[0..@min(line.len, 120)];
        picked += 1;
    }
    var instances: std.ArrayList(Instance) = .empty;
    defer instances.deinit(gpa);
    var best: i96 = std.math.maxInt(i96);
    for (0..50) |_| {
        const start = now(io);
        instances.clearRetainingCapacity();
        for (visible, 0..) |line, row| try emit(&system, try system.layout(.{ .text = line, .size = 14 }), row, &instances);
        best = @min(best, now(io) - start);
        system.endFrame();
    }
    std.debug.print("warm frame: {d:.3} ms for 80 lines of 120 columns, {d} glyphs\n", .{ ms(best), instances.items.len });

    var page_times: [9]i96 = undefined;
    var index: usize = lines.len / 4;
    for (&page_times) |*page_time| {
        var next_lines: [80][]const u8 = undefined;
        var count: usize = 0;
        while (count < next_lines.len and index < lines.len) : (index += 1) {
            if (lines[index].len < 40) continue;
            next_lines[count] = lines[index];
            count += 1;
        }
        for (next_lines[0..count]) |line| {
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            while (words.next()) |word| _ = try system.layout(.{ .text = word, .size = 14 });
        }
        system.endFrame();
        const page_start = now(io);
        for (next_lines[0..count]) |line| _ = try system.layout(.{ .text = line, .size = 14 });
        page_time.* = now(io) - page_start;
        system.endFrame();
    }
    std.mem.sort(i96, &page_times, {}, std.sort.asc(i96));
    std.debug.print("page down: {d:.3} ms median for 80 new lines\n", .{ms(page_times[4])});

    var line: std.ArrayList(u8) = .empty;
    while (line.items.len < 500) try line.appendSlice(arena, "const value = compute(input, 42) + other; ");
    line.shrinkRetainingCapacity(500);
    _ = try system.layout(.{ .text = line.items, .size = 14 });
    var keystroke_best: i96 = std.math.maxInt(i96);
    for (0..20) |round| {
        line.items[250] = @intCast('a' + round);
        const start = now(io);
        _ = try system.layout(.{ .text = line.items, .size = 14 });
        keystroke_best = @min(keystroke_best, now(io) - start);
    }
    std.debug.print("keystroke: {d:.1} us in a 500-byte line\n", .{@as(f64, @floatFromInt(keystroke_best)) / 1e3});
}

/// A 2,000-line document edited one keystroke at a time, and the whole corpus laid out cold.
fn benchDocument(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root: Io.Dir, fonts: []const manifest.FontEntry, lines: []const []const u8) !void {
    const data = try loadFont(io, arena, root, fonts, "fira-code");
    var document: std.ArrayList(u8) = .empty;
    for (lines[0..@min(lines.len, 2000)]) |line| {
        try document.appendSlice(arena, line);
        try document.append(arena, '\n');
    }
    {
        var system = try text.TextSystem.init(gpa, &.{.{ .name = "fira-code", .data = data }});
        defer system.deinit();
        // Before keyed layouts compared content, a key without a revision bump returned the stale layout.
        const key: ?u64 = if (@hasDecl(text.TextSystem, "resolveSlots")) 1 else null;
        _ = try system.layout(.{ .text = document.items, .size = 14, .key = key });
        const middle = document.items.len / 2;
        var best: i96 = std.math.maxInt(i96);
        for (0..20) |round| {
            document.items[middle] = @intCast('a' + round);
            const start = now(io);
            _ = try system.layout(.{ .text = document.items, .size = 14, .key = key });
            best = @min(best, now(io) - start);
            system.endFrame();
        }
        std.debug.print("document keystroke: {d:.3} ms in {d} lines, {d} KiB\n", .{ ms(best), @min(lines.len, 2000), document.items.len / 1024 });
    }
    var corpus: std.ArrayList(u8) = .empty;
    for (lines) |line| {
        try corpus.appendSlice(arena, line);
        try corpus.append(arena, '\n');
    }
    var best: i96 = std.math.maxInt(i96);
    for (0..3) |_| {
        var system = try text.TextSystem.init(gpa, &.{.{ .name = "fira-code", .data = data }});
        defer system.deinit();
        const start = now(io);
        _ = try system.layout(.{ .text = corpus.items, .size = 14 });
        best = @min(best, now(io) - start);
    }
    std.debug.print("cold document layout: {d:.1} ms for {d} KiB\n", .{ ms(best), corpus.items.len / 1024 });
}
