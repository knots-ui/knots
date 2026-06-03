const std = @import("std");
const math = @import("math");

pub const MAX_DEPTH = 32;

pub const State = struct {
    scissor: ?math.Rect = null,
    node: u32 = 0,

    pub fn eql(a: State, b: State) bool {
        return a.node == b.node and a.scissorEql(b);
    }

    pub fn scissorEql(a: State, b: State) bool {
        const some_a = a.scissor orelse return b.scissor == null;
        const some_b = b.scissor orelse return false;
        return some_a.eql(some_b);
    }
};

pub const Shape = struct {
    corner_radius: [4]f32 = .{ 0, 0, 0, 0 },
    border_width: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const Node = extern struct {
    rect: [4]f32,
    radii: [4]f32,
    parent: u32,
    _pad: [3]u32,

    pub const empty: Node = .{
        .rect = .{ 0, 0, 0, 0 },
        .radii = .{ 0, 0, 0, 0 },
        .parent = 0,
        ._pad = .{ 0, 0, 0 },
    };
};

pub fn depth(nodes: []const Node, node: u32) usize {
    var n = node;
    var d: usize = 0;
    while (n != 0 and d < MAX_DEPTH) : (d += 1) {
        if (n >= nodes.len) return MAX_DEPTH;
        n = nodes[n].parent;
    }
    return d;
}

pub fn contains(state: State, nodes: []const Node, point: math.Vec2) bool {
    if (state.scissor) |scissor| if (!scissor.contains(point)) return false;

    var n = state.node;
    var d: usize = 0;
    while (n != 0 and d < MAX_DEPTH) : (d += 1) {
        if (n >= nodes.len) return false;
        const node = nodes[n];
        if (!containsRounded(node, point)) return false;
        n = node.parent;
    }
    return n == 0;
}

fn containsRounded(node: Node, point: math.Vec2) bool {
    const rect = math.Rect.init(node.rect[0], node.rect[1], node.rect[2], node.rect[3]);
    if (rect.isEmpty()) return false;

    const half_size: math.Vec2 = .{ rect.w() * 0.5, rect.h() * 0.5 };
    const center: math.Vec2 = .{ rect.x() + half_size[0], rect.y() + half_size[1] };
    const p = point - center;
    return sdRoundedBox(p, half_size, normalizeRadii(node.radii, rect.size())) <= 0;
}

fn normalizeRadii(radii: [4]f32, size: math.Vec2) [4]f32 {
    var r = [4]f32{ @max(0, radii[0]), @max(0, radii[1]), @max(0, radii[2]), @max(0, radii[3]) };
    var scale: f32 = 1.0;
    if (r[0] + r[1] > size[0] and r[0] + r[1] > 0) scale = @min(scale, size[0] / (r[0] + r[1]));
    if (r[1] + r[2] > size[1] and r[1] + r[2] > 0) scale = @min(scale, size[1] / (r[1] + r[2]));
    if (r[2] + r[3] > size[0] and r[2] + r[3] > 0) scale = @min(scale, size[0] / (r[2] + r[3]));
    if (r[3] + r[0] > size[1] and r[3] + r[0] > 0) scale = @min(scale, size[1] / (r[3] + r[0]));
    r[0] *= scale;
    r[1] *= scale;
    r[2] *= scale;
    r[3] *= scale;
    return r;
}

fn cornerRadius(p: math.Vec2, radii: [4]f32) f32 {
    if (p[1] < 0) {
        return if (p[0] < 0) radii[0] else radii[1];
    }
    return if (p[0] >= 0) radii[2] else radii[3];
}

fn sdRoundedBox(p: math.Vec2, half_size: math.Vec2, radii: [4]f32) f32 {
    const radius = cornerRadius(p, radii);
    const q: math.Vec2 = .{
        @abs(p[0]) - half_size[0] + radius,
        @abs(p[1]) - half_size[1] + radius,
    };
    const outside: math.Vec2 = .{ @max(q[0], 0), @max(q[1], 0) };
    const outside_len = @sqrt(outside[0] * outside[0] + outside[1] * outside[1]);
    return outside_len + @min(@max(q[0], q[1]), 0) - radius;
}
