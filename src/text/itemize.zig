//! Splits a paragraph into runs of one face and one script.

const std = @import("std");
const unicode = @import("unicode/root.zig");
const FontProgram = @import("font/FontProgram.zig");

pub const chain_length_max = 16;

pub const Run = struct {
    start: u32,
    end: u32,
    face: u8,
    script: unicode.Script,
};

const Cluster = struct {
    start: u32,
    end: u32,
    script: unicode.Script,
};

/// HarfBuzz's cluster continuation: marks, emoji modifiers, ZWJ sequences, RI pairs and tags.
pub const ClusterIterator = struct {
    text: []const u8,
    index: usize = 0,
    previous_ri_continued: bool = false,
    previous_was_ri: bool = false,

    pub fn init(text: []const u8) ClusterIterator {
        return .{ .text = text };
    }

    fn continues(self: *ClusterIterator, codepoint: u32, joined: bool) bool {
        const was_ri = self.previous_was_ri;
        const ri_continued = self.previous_ri_continued;
        self.previous_was_ri = unicode.isRegionalIndicator(codepoint);
        self.previous_ri_continued = false;
        if (joined) return true;
        if (codepoint < 0x80) return false;
        const category = unicode.generalCategory(codepoint);
        if (category.isMark()) return true;
        switch (category) {
            .lowercase_letter, .uppercase_letter, .titlecase_letter, .other_letter, .space_separator => return false,
            else => {},
        }
        if (category == .modifier_symbol and codepoint >= 0x1F3FB and codepoint <= 0x1F3FF) return true;
        if (unicode.isRegionalIndicator(codepoint)) {
            const continued = was_ri and !ri_continued;
            self.previous_ri_continued = continued;
            return continued;
        }
        if (codepoint == 0x200D) return true;
        return (codepoint >= 0xFF9E and codepoint <= 0xFF9F) or (codepoint >= 0xE0020 and codepoint <= 0xE007F);
    }

    /// End of the next cluster.
    pub fn next(self: *ClusterIterator) ?usize {
        if (self.index >= self.text.len) return null;
        var joined = false;
        var first = true;
        while (self.index < self.text.len) {
            const decoded = unicode.decodeUtf8(self.text, self.index);
            const saved = self.*;
            const continued = self.continues(decoded.codepoint, joined);
            if (!first and !continued) {
                self.* = saved;
                break;
            }
            first = false;
            joined = decoded.codepoint == 0x200D and self.peekExtendedPictographic(self.index + decoded.len);
            self.index += decoded.len;
        }
        return self.index;
    }

    fn peekExtendedPictographic(self: *const ClusterIterator, index: usize) bool {
        if (index >= self.text.len) return false;
        return unicode.props(unicode.decodeUtf8(self.text, index).codepoint).extended_pictographic;
    }
};

fn isWeak(script: unicode.Script) bool {
    return script == .zyyy or script == .zinh or script == .zzzz;
}

fn clusterScript(text: []const u8, start: usize, end: usize) unicode.Script {
    var index = start;
    while (index < end) {
        const decoded = unicode.decodeUtf8(text, index);
        const script = unicode.script(decoded.codepoint);
        if (!isWeak(script)) return script;
        index += decoded.len;
    }
    return .zyyy;
}

fn covers(program: *const FontProgram, codepoint: u32) bool {
    if (program.cmap.has(codepoint)) return true;
    if (unicode.isDefaultIgnorable(codepoint)) return true;
    const pair = unicode.decompose(codepoint) orelse return false;
    if (!covers(program, pair.first)) return false;
    return pair.second == 0 or covers(program, pair.second);
}

fn coversCluster(program: *const FontProgram, text: []const u8) bool {
    var index: usize = 0;
    while (index < text.len) {
        const decoded = unicode.decodeUtf8(text, index);
        if (!covers(program, decoded.codepoint)) return false;
        index += decoded.len;
    }
    return true;
}

fn chooseFace(chain: []const *const FontProgram, text: []const u8, weak: bool, previous: ?u8) u8 {
    if (weak) {
        if (previous) |face| {
            if (coversCluster(chain[face], text)) return face;
        }
    }
    for (chain, 0..) |program, index| {
        if (coversCluster(program, text)) return @intCast(index);
    }
    const first = unicode.decodeUtf8(text, 0).codepoint;
    for (chain, 0..) |program, index| {
        if (covers(program, first)) return @intCast(index);
    }
    return 0;
}

pub const Scratch = struct {
    clusters: std.ArrayList(Cluster) = .empty,

    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        self.clusters.deinit(gpa);
    }
};

pub fn itemize(gpa: std.mem.Allocator, text: []const u8, chain: []const *const FontProgram, out: *std.ArrayList(Run)) !void {
    var scratch: Scratch = .{};
    defer scratch.deinit(gpa);
    return itemizeWith(gpa, &scratch, text, chain, out);
}

pub fn itemizeWith(gpa: std.mem.Allocator, scratch: *Scratch, text: []const u8, chain: []const *const FontProgram, out: *std.ArrayList(Run)) !void {
    std.debug.assert(chain.len > 0 and chain.len <= chain_length_max);
    const clusters = &scratch.clusters;
    clusters.clearRetainingCapacity();
    var iterator = ClusterIterator.init(text);
    var start: usize = 0;
    while (iterator.next()) |end| {
        try clusters.append(gpa, .{ .start = @intCast(start), .end = @intCast(end), .script = clusterScript(text, start, end) });
        start = end;
    }
    resolveScripts(clusters.items);

    var previous: ?u8 = null;
    for (clusters.items) |cluster| {
        const slice = text[cluster.start..cluster.end];
        const weak = isWeak(unicode.script(unicode.decodeUtf8(slice, 0).codepoint));
        const face = chooseFace(chain, slice, weak, previous);
        previous = face;
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (last.face == face and last.script == cluster.script and last.end == cluster.start) {
                last.end = cluster.end;
                continue;
            }
        }
        try out.append(gpa, .{ .start = cluster.start, .end = cluster.end, .face = face, .script = cluster.script });
    }
}

/// Weak clusters take the script before them, or after them at the start, or Latin.
fn resolveScripts(clusters: []Cluster) void {
    var last_strong: ?unicode.Script = null;
    for (clusters) |*cluster| {
        if (isWeak(cluster.script)) {
            if (last_strong) |script| cluster.script = script;
            continue;
        }
        last_strong = cluster.script;
    }
    var next_strong: ?unicode.Script = null;
    var index = clusters.len;
    while (index > 0) {
        index -= 1;
        const cluster = &clusters[index];
        if (!isWeak(cluster.script)) {
            next_strong = cluster.script;
            continue;
        }
        cluster.script = next_strong orelse .latn;
    }
}

test "clusters keep marks, emoji sequences and flag pairs together" {
    var iterator = ClusterIterator.init("e\u{0301}\u{1F468}\u{200D}\u{1F469}\u{1F1FA}\u{1F1F8}\u{1F1EB}a");
    try std.testing.expectEqual(@as(?usize, 3), iterator.next());
    try std.testing.expectEqual(@as(?usize, 14), iterator.next());
    try std.testing.expectEqual(@as(?usize, 22), iterator.next());
    try std.testing.expectEqual(@as(?usize, 26), iterator.next());
    try std.testing.expectEqual(@as(?usize, 27), iterator.next());
    try std.testing.expectEqual(@as(?usize, null), iterator.next());
}

test "weak scripts resolve from their neighbors" {
    var clusters = [_]Cluster{
        .{ .start = 0, .end = 1, .script = .zyyy },
        .{ .start = 1, .end = 2, .script = .grek },
        .{ .start = 2, .end = 3, .script = .zyyy },
        .{ .start = 3, .end = 4, .script = .latn },
    };
    resolveScripts(&clusters);
    try std.testing.expectEqual(unicode.Script.grek, clusters[0].script);
    try std.testing.expectEqual(unicode.Script.grek, clusters[2].script);
    var weak = [_]Cluster{.{ .start = 0, .end = 1, .script = .zyyy }};
    resolveScripts(&weak);
    try std.testing.expectEqual(unicode.Script.latn, weak[0].script);
}
