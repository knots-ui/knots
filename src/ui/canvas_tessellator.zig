const std = @import("std");
const gpu = @import("gpu");
const render = @import("render");
const DrawList = render.DrawList;
const Clip = render.Clip;

const Decoration = @import("decoration.zig").Decoration;
const Radius = @import("Radius.zig");
const BorderWidth = @import("BorderWidth.zig");

const zero2 = [2]f32{ 0, 0 };
const zero4 = [4]f32{ 0, 0, 0, 0 };
const flat_hs = [2]f32{ 1e4, 1e4 };

pub fn tessellate(allocator: std.mem.Allocator, draw_list: *DrawList, cmds: []const Decoration.DrawCmd, origin: [2]f32, clip: Clip.State) !void {
    const ox = origin[0];
    const oy = origin[1];

    for (cmds) |cmd| {
        switch (cmd) {
            .fill_rect => |fr| {
                const inst = gpu.Instance{
                    .pos = .{ ox + fr.x, oy + fr.y },
                    .size = .{ fr.w, fr.h },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 0, 0 },
                    .color = fr.color,
                    .border_color = zero4,
                    .corner_radius = fr.corner_radius.value,
                    .border_width = BorderWidth.zero.value,
                    .prim_type = 0.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{inst}, null, clip);
            },
            .fill_rect_gradient => |fr| {
                const hw = fr.w / 2.0;
                const hh = fr.h / 2.0;
                const fcx = ox + fr.x + hw;
                const fcy = oy + fr.y + hh;
                const prim_type: f32 = if (fr.corner_radius.isZero()) 3.0 else 0.0;
                const vertices = [4]gpu.Vertex{
                    vertex(fcx - hw, fcy - hh, .{ -hw, -hh }, fr.colors[0], fr.corner_radius, .{ hw, hh }, prim_type),
                    vertex(fcx + hw, fcy - hh, .{ hw, -hh }, fr.colors[1], fr.corner_radius, .{ hw, hh }, prim_type),
                    vertex(fcx + hw, fcy + hh, .{ hw, hh }, fr.colors[2], fr.corner_radius, .{ hw, hh }, prim_type),
                    vertex(fcx - hw, fcy + hh, .{ -hw, hh }, fr.colors[3], fr.corner_radius, .{ hw, hh }, prim_type),
                };
                try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
            },
            .stroke_rect => |sr| {
                const inst = gpu.Instance{
                    .pos = .{ ox + sr.x, oy + sr.y },
                    .size = .{ sr.w, sr.h },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 0, 0 },
                    .color = zero4,
                    .border_color = sr.color,
                    .corner_radius = sr.corner_radius.value,
                    .border_width = (sr.edge_widths orelse BorderWidth.all(sr.thickness)).value,
                    .prim_type = 0.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{inst}, null, clip);
            },
            .fill_circle => |fc| {
                const cr = fc.radius;
                const inst = gpu.Instance{
                    .pos = .{ ox + fc.cx - cr, oy + fc.cy - cr },
                    .size = .{ cr * 2, cr * 2 },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 0, 0 },
                    .color = fc.color,
                    .border_color = zero4,
                    .corner_radius = Radius.all(cr).value,
                    .border_width = BorderWidth.zero.value,
                    .prim_type = 0.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{inst}, null, clip);
            },
            .stroke_circle => |sc| {
                const cr = sc.radius;
                const inst = gpu.Instance{
                    .pos = .{ ox + sc.cx - cr, oy + sc.cy - cr },
                    .size = .{ cr * 2, cr * 2 },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 0, 0 },
                    .color = zero4,
                    .border_color = sc.color,
                    .corner_radius = Radius.all(cr).value,
                    .border_width = BorderWidth.all(sc.thickness).value,
                    .prim_type = 0.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{inst}, null, clip);
            },
            .line => |l| {
                const dx = l.to[0] - l.from[0];
                const dy = l.to[1] - l.from[1];
                const len = @sqrt(dx * dx + dy * dy);
                if (len < 1e-6) continue;
                const nx = -dy / len * l.thickness * 0.5;
                const ny = dx / len * l.thickness * 0.5;
                const x0 = ox + l.from[0];
                const y0 = oy + l.from[1];
                const x1 = ox + l.to[0];
                const y1 = oy + l.to[1];
                const vertices = [4]gpu.Vertex{
                    vertex(x0 + nx, y0 + ny, zero2, l.color, .zero, flat_hs, 0.0),
                    vertex(x1 + nx, y1 + ny, zero2, l.color, .zero, flat_hs, 0.0),
                    vertex(x1 - nx, y1 - ny, zero2, l.color, .zero, flat_hs, 0.0),
                    vertex(x0 - nx, y0 - ny, zero2, l.color, .zero, flat_hs, 0.0),
                };
                try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
            },
            .fill_triangle => |t| {
                const vertices = [3]gpu.Vertex{
                    vertex(ox + t.points[0][0], oy + t.points[0][1], zero2, t.color, .zero, flat_hs, 0.0),
                    vertex(ox + t.points[1][0], oy + t.points[1][1], zero2, t.color, .zero, flat_hs, 0.0),
                    vertex(ox + t.points[2][0], oy + t.points[2][1], zero2, t.color, .zero, flat_hs, 0.0),
                };
                try draw_list.push(&vertices, &.{ 0, 1, 2 }, null, clip);
            },
            .fill_convex_polygon => |p| {
                if (p.points.len < 3) continue;
                const verts = try allocator.alloc(gpu.Vertex, p.points.len);
                defer allocator.free(verts);
                for (p.points, 0..) |pt, vi| {
                    verts[vi] = vertex(ox + pt[0], oy + pt[1], zero2, p.color, .zero, flat_hs, 0.0);
                }

                const n_tris = p.points.len - 2;
                const fan_indices = try allocator.alloc(u32, n_tris * 3);
                defer allocator.free(fan_indices);
                for (0..n_tris) |i| {
                    fan_indices[i * 3] = 0;
                    fan_indices[i * 3 + 1] = @as(u32, @intCast(i)) + 1;
                    fan_indices[i * 3 + 2] = @as(u32, @intCast(i)) + 2;
                }
                try draw_list.push(verts, fan_indices, null, clip);
            },
        }
    }
}

fn vertex(
    x: f32,
    y: f32,
    uv: [2]f32,
    color: [4]f32,
    corner_radius: Radius,
    half_size: [2]f32,
    prim_type: f32,
) gpu.Vertex {
    return .{
        .pos = .{ x, y },
        .uv = uv,
        .color = color,
        .corner_radius = corner_radius.value,
        .half_size = half_size,
        .border_width = BorderWidth.zero.value,
        .border_color = zero4,
        .prim_type = prim_type,
    };
}
