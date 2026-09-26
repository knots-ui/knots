const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const renderer = @import("renderer");
const shader_config = @import("gpu_shader_config");

const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const GPUCanvas = ui.component.GPUCanvas;
const Rect = ui.component.Rect;
const SliderInput = ui.component.SliderInput;
const Spacer = ui.component.Spacer;
const Text = ui.component.Text;

const max_particles = 8192;
const index_count = 60;

const canvas_background = ui.Color.rgba(4, 7, 16, 255);

const wgsl: []const u8 = if (shader_config.has_wgsl) @embedFile("gpu_shader_wgsl") else "";
const vertex_spirv_bytes align(@alignOf(u32)) = if (shader_config.has_spirv) @embedFile("gpu_shader_vert_spv").* else [_]u8{};
const fragment_spirv_bytes align(@alignOf(u32)) = if (shader_config.has_spirv) @embedFile("gpu_shader_frag_spv").* else [_]u8{};

const MeshVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

const Particle = extern struct {
    parameters: [4]f32,
};

const Uniforms = extern struct {
    viewport: [4]f32,
    camera: [4]f32,
    geometry: [4]f32,
    clip_transform: [4]f32,
};

const mesh_positions = [_][3]f32{
    .{ -0.525731, 0.850651, 0 },
    .{ 0.525731, 0.850651, 0 },
    .{ -0.525731, -0.850651, 0 },
    .{ 0.525731, -0.850651, 0 },
    .{ 0, -0.525731, 0.850651 },
    .{ 0, 0.525731, 0.850651 },
    .{ 0, -0.525731, -0.850651 },
    .{ 0, 0.525731, -0.850651 },
    .{ 0.850651, 0, -0.525731 },
    .{ 0.850651, 0, 0.525731 },
    .{ -0.850651, 0, -0.525731 },
    .{ -0.850651, 0, 0.525731 },
};

const mesh_vertices = blk: {
    var vertices: [mesh_positions.len]MeshVertex = undefined;
    for (mesh_positions, 0..) |position, i| vertices[i] = .{ .position = position, .normal = position };
    break :blk vertices;
};

const mesh_indices = [_]u32{
    0, 11, 5, 0, 5,  1,  0,  1,  7,  0,  7, 10, 0, 10, 11,
    1, 5,  9, 5, 11, 4,  11, 10, 2,  10, 7, 6,  7, 1,  8,
    3, 9,  4, 3, 4,  2,  3,  2,  6,  3,  6, 8,  3, 8,  9,
    4, 9,  5, 2, 4,  11, 6,  2,  10, 8,  6, 7,  9, 8,  1,
};

comptime {
    std.debug.assert(mesh_indices.len == index_count);
    std.debug.assert(@sizeOf(MeshVertex) == 24);
    std.debug.assert(@offsetOf(MeshVertex, "normal") == 12);
    std.debug.assert(@sizeOf(Particle) == 16);
    std.debug.assert(@sizeOf(Uniforms) == 64);
    std.debug.assert(@offsetOf(Uniforms, "camera") == 16);
    std.debug.assert(@offsetOf(Uniforms, "geometry") == 32);
    std.debug.assert(@offsetOf(Uniforms, "clip_transform") == 48);
}

pub fn render(desktop: *knots.App, app: *ui.Frame) !void {
    try ui_helpers.panel(desktop, app, "Knot Laboratory", body);
}

fn body(desktop: *knots.App, app: *ui.Frame) !void {
    const self = Self.of(desktop);
    const state = &self.demo_state;
    if (state.gpu_resources == null) {
        state.gpu_resources = try createResources(desktop, self.allocator);
    }

    const delta_seconds = @as(f32, @floatFromInt(app.input().delta_ns)) * 0.000000001;
    state.gpu_time += delta_seconds;
    if (!state.gpu_dragging) state.gpu_orbit += delta_seconds * state.gpu_spin;

    try app.e(Text{
        .content = "A live T(3,4) torus knot built from thousands of indexed, instanced icosahedra. Drag the canvas to orbit it and reshape the sculpture in real time.",
        .key = .src(@src()),
        .style = &.{ .font_size = .sm, .foreground = .dimmed, .wrap = true, .width = .grow() },
    });
    try app.e(Text{
        .content = "INDEXED INSTANCING  ·  PERSISTENT BUFFERS  ·  LIVE UNIFORMS",
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .accented, .width = .grow() },
    });
    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(12) } });

    const first_row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 14 } };
    _ = try first_row.open(app);
    try slider(app, "Density", &state.gpu_density, 1024, max_particles, 256);
    try slider(app, "Strand width", &state.gpu_strand_width, 0.02, 0.32, 0);
    try slider(app, "Facet size", &state.gpu_facet_size, 0.4, 1.8, 0);
    try slider(app, "Twist", &state.gpu_twist, 0, 12, 0.25);
    try first_row.close(app);

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(10) } });
    const second_row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 14 } };
    _ = try second_row.open(app);
    try slider(app, "Zoom", &state.gpu_zoom, 0.65, 1.65, 0);
    try slider(app, "Perspective", &state.gpu_perspective, 30, 75, 1);
    try slider(app, "Spin", &state.gpu_spin, 0, 1.2, 0);
    try second_row.close(app);

    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(14) } });
    const canvas_panel = Rect{
        .key = .src(@src()),
        .style = &.{ .width = .grow(), .height = .grow(), .padding = .init(1, 1, 1, 1), .overflow = .hidden, .background = .{ .color = canvas_background }, .border_color = .toned, .border_width = .all(1), .radius = .sm },
    };
    _ = try canvas_panel.open(app);
    const canvas = GPUCanvas{
        .interactive = true,
        .paint = renderer.gpu.paintCallback(self, drawKnot),
        .key = .src(@src()),
        .style = &.{ .width = .grow(), .height = .grow() },
    };
    const canvas_id = try canvas.open(app);
    const raw_mouse = app.ui().input.mouse_pos;
    const mouse = [2]f32{ @floatCast(raw_mouse[0]), @floatCast(raw_mouse[1]) };
    const left = app.ui().input.mouseButton(.left);
    if (app.ui().leftPressed(canvas_id, .exact)) {
        state.gpu_dragging = true;
        state.gpu_drag_position = mouse;
    }
    if (state.gpu_dragging) {
        if (left.down) {
            state.gpu_camera[0] += (mouse[0] - state.gpu_drag_position[0]) * 0.008;
            state.gpu_camera[1] = std.math.clamp(
                state.gpu_camera[1] + (mouse[1] - state.gpu_drag_position[1]) * 0.008,
                -1.2,
                1.2,
            );
            state.gpu_drag_position = mouse;
        } else {
            state.gpu_dragging = false;
        }
    }
    try canvas.close(app);
    try canvas_panel.close(app);

    app.requestRedraw();
}

fn control(app: *ui.Frame, comptime label: []const u8, value: anytype) !void {
    try app.e(.{
        Rect{
            .key = .str("gpu-control:" ++ label),
            .style = &.{ .width = .grow(), .direction = .column, .gap = 6 },
        },
        .{
            Text{ .content = label, .key = .str("gpu-label:" ++ label), .style = &.{ .font_size = .xs, .foreground = .dimmed } },
            value,
        },
    });
}

fn slider(app: *ui.Frame, comptime label: []const u8, value: *f32, min: f32, max: f32, steps: f32) !void {
    try control(app, label, SliderInput{
        .value = value,
        .min = min,
        .max = max,
        .steps = steps,
        .key = .str("gpu-slider:" ++ label),
        .style = &.{ .width = .grow() },
    });
}

fn createResources(app: *knots.App, allocator: std.mem.Allocator) !Self.DemoState.GpuResources {
    const gpu = app.gpuContext();
    var pipeline = try gpu.createPipeline(.{
        .label = "playground_knot_laboratory",
        .shader = if (shader_config.has_wgsl)
            .{ .wgsl = wgsl }
        else
            .{ .spirv = .{ .vs = &vertex_spirv_bytes, .fs = &fragment_spirv_bytes } },
        .vertex_buffers = &.{
            .{
                .stride = @sizeOf(MeshVertex),
                .step_mode = .vertex,
                .attributes = &.{
                    .{ .location = 0, .offset = @offsetOf(MeshVertex, "position"), .format = .f32x3 },
                    .{ .location = 1, .offset = @offsetOf(MeshVertex, "normal"), .format = .f32x3 },
                },
            },
            .{
                .stride = @sizeOf(Particle),
                .step_mode = .instance,
                .attributes = &.{.{ .location = 2, .offset = 0, .format = .f32x4 }},
            },
        },
        .bind_group_layouts = &.{.{
            .label = "playground_knot_uniforms",
            .entries = &.{.{
                .binding = 0,
                .visibility = .{ .vertex = true, .fragment = true },
                .type = .uniform_buffer,
            }},
        }},
        .color_target = .{
            .format = gpu.drawFormat(),
            .blend = .{
                .color = .{ .src_factor = .one, .dst_factor = .one },
                .alpha = .{ .src_factor = .one, .dst_factor = .one },
            },
        },
    });
    errdefer pipeline.deinit();

    var vertex_buffer = try gpu.createBuffer(.{
        .size = @sizeOf(@TypeOf(mesh_vertices)),
        .usage = .{ .vertex = true },
        .initial_data = std.mem.sliceAsBytes(mesh_vertices[0..]),
        .label = "playground_knot_vertices",
    });
    errdefer vertex_buffer.deinit();

    var index_buffer = try gpu.createBuffer(.{
        .size = @sizeOf(@TypeOf(mesh_indices)),
        .usage = .{ .index = true },
        .initial_data = std.mem.sliceAsBytes(mesh_indices[0..]),
        .label = "playground_knot_indices",
    });
    errdefer index_buffer.deinit();

    const particles = try allocator.alloc(Particle, max_particles);
    defer allocator.free(particles);
    for (particles, 0..) |*particle, i| {
        const fi: f32 = @floatFromInt(i);
        const golden_phase = fi * 0.61803398875;
        particle.* = .{ .parameters = .{
            golden_phase - @floor(golden_phase),
            unitHash(@intCast(i)) * 6.28318530718,
            @sqrt(unitHash(@as(u32, @intCast(i)) +% 0x9e3779b9)),
            unitHash(@as(u32, @intCast(i)) +% 0x85ebca6b),
        } };
    }
    var instance_buffer = try gpu.createBuffer(.{
        .size = particles.len * @sizeOf(Particle),
        .usage = .{ .vertex = true },
        .initial_data = std.mem.sliceAsBytes(particles),
        .label = "playground_knot_instances",
    });
    errdefer instance_buffer.deinit();

    return .{
        .pipeline = pipeline,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .instance_buffer = instance_buffer,
    };
}

fn unitHash(seed: u32) f32 {
    var value = seed;
    value ^= value >> 16;
    value *%= 0x7feb352d;
    value ^= value >> 15;
    value *%= 0x846ca68b;
    value ^= value >> 16;
    return @as(f32, @floatFromInt(value)) * (1.0 / 4294967295.0);
}

fn drawKnot(user_data: ?*anyopaque, context: *renderer.gpu.DrawContext) !void {
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const state = &self.demo_state;
    const resources = &state.gpu_resources.?;
    const density = std.math.clamp(state.gpu_density, 1024, max_particles);
    const density_compensation = @sqrt(4096.0 / density);
    const uniforms = Uniforms{
        .viewport = .{
            context.logical_bounds.width,
            context.logical_bounds.height,
            state.gpu_time,
            state.gpu_twist,
        },
        .camera = .{
            state.gpu_camera[0] + state.gpu_orbit,
            state.gpu_camera[1],
            state.gpu_zoom,
            @tan(state.gpu_perspective * std.math.pi / 360.0),
        },
        .geometry = .{
            state.gpu_strand_width,
            state.gpu_facet_size,
            std.math.clamp(density_compensation, 0.75, 1.5),
            std.math.clamp(density_compensation, 0.65, 1.5),
        },
        .clip_transform = .{
            context.clip_space_transform.scale[0],
            context.clip_space_transform.scale[1],
            context.clip_space_transform.offset[0],
            context.clip_space_transform.offset[1],
        },
    };
    const uniform_view = try context.frame.upload(Uniforms, &.{uniforms}, .{ .uniform = true });
    const bind_group = try context.frame.createBindGroup(.{
        .label = "playground_knot_uniforms",
        .pipeline = &resources.pipeline,
        .layout_index = 0,
        .entries = &.{.{ .binding = 0, .resource = .{ .buffer = uniform_view } }},
    });

    context.pass.bindPipeline(&resources.pipeline);
    try context.pass.setBindGroup(0, bind_group);
    try context.pass.setVertexBuffer(0, resources.vertex_buffer.view());
    try context.pass.setVertexBuffer(1, resources.instance_buffer.view());
    try context.pass.setIndexBuffer(resources.index_buffer.view());
    const particle_count: u32 = @intFromFloat(density);
    context.pass.drawIndexed(index_count, particle_count, 0, 0, 0);
}
