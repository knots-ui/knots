const std = @import("std");

/// Reverses `std.zig.SubprocessCommand.format`, dropping `cd` and env.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !?[]const []const u8 {
    var rest = text;
    if (std.mem.startsWith(u8, rest, "cd ")) {
        const end = std.mem.indexOf(u8, rest, " && ") orelse return null;
        rest = rest[end + " && ".len ..];
    }

    var argv: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < rest.len) {
        if (rest[index] == ' ') {
            index += 1;
            continue;
        }

        const start = index;
        var word: std.ArrayList(u8) = .empty;
        while (index < rest.len and rest[index] != ' ') {
            if (rest[index] == '"') {
                index = try parseQuoted(allocator, rest, index + 1, &word);
                continue;
            }

            try word.append(allocator, rest[index]);
            index += 1;
        }

        // A first argument that contains `=` is always quoted.
        if (argv.items.len == 0 and isAssignment(rest[start..index]))
            continue;

        try argv.append(allocator, word.items);
    }

    if (argv.items.len == 0)
        return null;

    return argv.items;
}

fn parseQuoted(allocator: std.mem.Allocator, rest: []const u8, start: usize, word: *std.ArrayList(u8)) !usize {
    var index = start;
    while (true) {
        if (index >= rest.len)
            return error.UnterminatedQuote;

        const byte = rest[index];
        index += 1;
        if (byte == '"')
            return index;

        if (byte != '\\') {
            try word.append(allocator, byte);
            continue;
        }

        if (index >= rest.len)
            return error.UnterminatedQuote;

        const escaped = rest[index];
        index += 1;
        switch (escaped) {
            'a' => try word.append(allocator, 0x07),
            'b' => try word.append(allocator, 0x08),
            't' => try word.append(allocator, '\t'),
            'n' => try word.append(allocator, '\n'),
            'v' => try word.append(allocator, 0x0b),
            'f' => try word.append(allocator, 0x0c),
            'r' => try word.append(allocator, '\r'),
            'E' => try word.append(allocator, 0x1b),
            '0'...'7' => {
                if (index + 2 > rest.len)
                    return error.InvalidEscape;

                const value = std.fmt.parseInt(u8, rest[index - 1 .. index + 2], 8) catch return error.InvalidEscape;
                try word.append(allocator, value);
                index += 2;
            },
            else => try word.append(allocator, escaped),
        }
    }
}

fn isAssignment(word: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (equals == 0)
        return false;

    for (word[0..equals]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_')
            return false;
    }
    return true;
}

test "commands from zig build --verbose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const arguments = [_][]const u8{ "/zig dir/zig", "build-exe", "-Mapp=C:\\Users\\A B\\app.zig", "tab\tquote\"", "plain", "\x01" };
    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("ZIG_FLAG", "a b");

    const printed = try std.fmt.allocPrint(allocator, "{f}", .{std.zig.SubprocessCommand{
        .argv = &arguments,
        .cwd = "/some dir",
        .child_env = &environment,
    }});
    const parsed = (try parse(allocator, printed)).?;

    try std.testing.expectEqual(arguments.len, parsed.len);
    for (arguments, parsed) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);
}
