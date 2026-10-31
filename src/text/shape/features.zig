const std = @import("std");
const Plan = @import("Plan.zig");

/// Parses HarfBuzz's feature syntax: `liga`, `-liga`, `+liga`, `aalt=2`, `kern[3:5]`, comma separated.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ![]Plan.Feature {
    var features: std.ArrayList(Plan.Feature) = .empty;
    var items = std.mem.tokenizeScalar(u8, text, ',');
    while (items.next()) |raw| {
        const item = std.mem.trim(u8, raw, " ");
        if (item.len == 0) continue;
        try features.append(arena, try parseOne(item));
    }
    return features.items;
}

fn parseOne(item: []const u8) !Plan.Feature {
    var rest = item;
    var value: u32 = 1;
    switch (rest[0]) {
        '-' => {
            value = 0;
            rest = rest[1..];
        },
        '+' => rest = rest[1..],
        else => {},
    }
    var feature: Plan.Feature = .{ .tag = 0, .value = value };
    if (std.mem.findScalar(u8, rest, '=')) |equals| {
        feature.value = try parseValue(rest[equals + 1 ..]);
        rest = rest[0..equals];
    }
    if (std.mem.findScalar(u8, rest, '[')) |open| {
        const close = std.mem.findScalarPos(u8, rest, open, ']') orelse return error.InvalidFeature;
        try parseRange(rest[open + 1 .. close], &feature);
        rest = rest[0..open];
    }
    if (rest.len == 0 or rest.len > 4) return error.InvalidFeature;
    var name: [4]u8 = @splat(' ');
    @memcpy(name[0..rest.len], rest);
    feature.tag = std.mem.readInt(u32, &name, .big);
    return feature;
}

fn parseValue(text: []const u8) !u32 {
    if (std.mem.eql(u8, text, "on")) return 1;
    if (std.mem.eql(u8, text, "off")) return 0;
    return std.fmt.parseInt(u32, text, 10);
}

fn parseRange(text: []const u8, feature: *Plan.Feature) !void {
    const colon = std.mem.findScalar(u8, text, ':') orelse {
        if (text.len == 0) return;
        feature.start = try std.fmt.parseInt(u32, text, 10);
        feature.end = feature.start + 1;
        return;
    };
    if (colon > 0) feature.start = try std.fmt.parseInt(u32, text[0..colon], 10);
    if (colon + 1 < text.len) feature.end = try std.fmt.parseInt(u32, text[colon + 1 ..], 10);
}

test "parses HarfBuzz feature strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const features = try parse(arena_state.allocator(), "-liga,+kern,aalt=2,calt[3:5],ss01=off");
    try std.testing.expectEqual(@as(usize, 5), features.len);
    try std.testing.expectEqual(@as(u32, 0), features[0].value);
    try std.testing.expectEqual(Plan.tag("aalt"), features[2].tag);
    try std.testing.expectEqual(@as(u32, 2), features[2].value);
    try std.testing.expectEqual(@as(u32, 3), features[3].start);
    try std.testing.expectEqual(@as(u32, 5), features[3].end);
    try std.testing.expect(features[1].isGlobal());
}
