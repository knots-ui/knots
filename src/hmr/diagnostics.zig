const std = @import("std");

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
    \\+- install playground-dev to hmr/staging/app.wasm
    \\   +- compile exe playground-dev debug wasm32-freestanding 1 errors
    \\/app/src/demos/buttons.zig:12:22: error: expected type 'isize', found '*const [4:0]u8'
    \\var counter: isize = "zero";
    \\                     ^~~~~~
    \\referenced by:
    \\    main: /app/src/demos/buttons.zig:33:72
    \\    webMain: /app/src/main.zig:20:46
    \\error: 1 compilation errors
    \\failed command: /zig build-exe -fno-entry -fstrip -Odebug -target wasm32-freestanding --dep knots
    \\
    \\Build Summary: 29/32 steps succeeded (1 failed)
    \\dev transitive failure
    \\+- install playground-dev to hmr/staging/app.wasm transitive failure
    \\   +- compile exe playground-dev debug wasm32-freestanding 1 errors
    \\
;

test "diagnostics drop build runner noise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(
        \\/app/src/demos/buttons.zig:12:22: error: expected type 'isize', found '*const [4:0]u8'
        \\var counter: isize = "zero";
        \\                     ^~~~~~
        \\referenced by:
        \\    main: /app/src/demos/buttons.zig:33:72
        \\    webMain: /app/src/main.zig:20:46
    , try summary(arena.allocator(), sample));
}

test "output without located diagnostics is kept, minus command lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(
        "error: no step named 'dev'",
        try summary(arena.allocator(), "error: no step named 'dev'\nfailed command: zig build\n"),
    );
}
