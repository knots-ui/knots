//! Reduces `zig build` output to the compiler diagnostics, with paths to the
//! user's own files.

const std = @import("std");

/// The build compiles private copies of the sources (see snapshot.zig).
/// Changes each path `…<copies>file.zig` to `<sources>/file.zig`.
pub fn sourcePaths(allocator: std.mem.Allocator, output: []const u8, copies: []const u8, sources: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var rest = output;
    while (std.mem.indexOf(u8, rest, copies)) |index| {
        const start = if (std.mem.lastIndexOfAny(u8, rest[0..index], " \t\n'\"(")) |separator| separator + 1 else 0;
        try result.appendSlice(allocator, rest[0..start]);
        try result.appendSlice(allocator, sources);
        try result.append(allocator, '/');
        rest = rest[index + copies.len ..];
    }

    try result.appendSlice(allocator, rest);
    return result.items;
}

/// Keeps diagnostics with a location (`file:line:column: error: …`) and their
/// excerpts, notes and reference traces. Removes the build runner's step
/// trees, commands and summaries. If no diagnostic has a location (for
/// example, a broken build script), keeps all output except commands.
pub fn summary(allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
    var located: std.ArrayList(u8) = .empty;
    var other: std.ArrayList(u8) = .empty;
    var in_diagnostic = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "failed command:") or std.mem.startsWith(u8, line, "info(verbose):"))
            continue;

        if (isLocated(line)) {
            in_diagnostic = true;
        } else if (in_diagnostic and runnerLine(line)) {
            in_diagnostic = false;
        }

        const target = if (in_diagnostic) &located else &other;
        try target.appendSlice(allocator, line);
        try target.append(allocator, '\n');
    }

    const result = if (located.items.len > 0) located.items else other.items;
    return std.mem.trim(u8, result, "\n");
}

pub fn hasLocated(output: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (isLocated(line))
            return true;
    }
    return false;
}

fn isLocated(line: []const u8) bool {
    const marker = for ([_][]const u8{ ": error: ", ": note: " }) |marker| {
        if (std.mem.indexOf(u8, line, marker)) |index| break line[0..index];
    } else return false;

    var parts = std.mem.splitBackwardsScalar(u8, marker, ':');
    for (0..2) |_| {
        const number = parts.next() orelse return false;
        _ = std.fmt.parseInt(u32, number, 10) catch return false;
    }

    return parts.rest().len > 0;
}

fn runnerLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    return std.mem.startsWith(u8, line, "error: ") or
        std.mem.startsWith(u8, line, "Build Summary") or
        std.mem.startsWith(u8, trimmed, "+- ") or
        std.mem.endsWith(u8, line, "transitive failure");
}

const sample =
    \\dev
    \\+- install generated to hmr/staging/demos/buttons.wasm
    \\   +- compile exe buttons debug wasm32-freestanding 1 errors
    \\.zig-cache/knots-modules/c246e860e4203483/tree/demos/buttons.zig:12:22: error: expected type 'isize', found '*const [4:0]u8'
    \\var counter: isize = "zero";
    \\                     ^~~~~~
    \\referenced by:
    \\    main: .zig-cache/knots-modules/c246e860e4203483/tree/demos/buttons.zig:33:72
    \\    knots_hmr_init: /knots/src/hmr/guest.zig:38:46
    \\error: 1 compilation errors
    \\failed command: /zig build-exe -fno-entry -fstrip -Odebug -target wasm32-freestanding --dep hmr
    \\
    \\Build Summary: 29/32 steps succeeded (1 failed)
    \\dev transitive failure
    \\+- install generated to hmr/staging/demos/buttons.wasm transitive failure
    \\   +- compile exe buttons debug wasm32-freestanding 1 errors
    \\
;

test "diagnostics point at the sources and drop build runner noise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const rewritten = try sourcePaths(allocator, sample, "knots-modules/c246e860e4203483/tree/", "/app/src");
    try std.testing.expectEqualStrings(
        \\/app/src/demos/buttons.zig:12:22: error: expected type 'isize', found '*const [4:0]u8'
        \\var counter: isize = "zero";
        \\                     ^~~~~~
        \\referenced by:
        \\    main: /app/src/demos/buttons.zig:33:72
        \\    knots_hmr_init: /knots/src/hmr/guest.zig:38:46
    , try summary(allocator, rewritten));
}

test "output without located diagnostics is kept, minus command lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(
        "error: no step named 'dev'",
        try summary(arena.allocator(), "error: no step named 'dev'\nfailed command: zig build\n"),
    );
}
