//! Backdrop snapshots: group planning and the Dual Kawase blur chain.
//!
//! A blurred group halves its region of the scene target `levels` times, then
//! upsamples back to level 1. An unblurred group copies it to level 0. Levels
//! are sized to the whole surface so moving regions reuse them; each pass
//! renders into the region's corner of its level.

const std = @import("std");
const gpu_impl = @import("gpu_impl");
const math = @import("math");
const render = @import("render");

const Command = render.Command;
const pipelines = @import("pipelines.zig");
const Context = @import("Context.zig");
const FrameUploads = @import("FrameUploads.zig");

pub const groups_max = Command.Backdrop.groups_max;
pub const levels_max = 6;

/// Sigma of one level at unit offset, per `blurPlan`'s approximation.
const sigma_per_level: f32 = 0.7;
/// Largest tap spread before adding a level.
const offset_max: f32 = 1.5;
/// Tap spread limit at `levels_max`; wider looks blotchy.
const offset_limit: f32 = 3.0;

/// Physical pixels.
pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const BlurPlan = struct {
    levels: u8,
    offset: f32,

    /// Level the glass samples: 1 after any blur, else the sharp copy.
    pub fn finalLevel(self: BlurPlan) u8 {
        return @min(self.levels, 1);
    }
};

pub const Group = struct {
    region: Region,
    blur: BlurPlan,
};

pub const Plan = struct {
    groups: [groups_max]?Group = @splat(null),
};

/// Approximate Dual Kawase sizing: `levels` halvings with tap spread `offset`
/// give sigma ≈ 0.7 × offset × 2^levels physical pixels. Offsets change
/// continuously with sigma, so animated blur does not step between levels.
pub fn blurPlan(sigma: f32) BlurPlan {
    if (!(sigma > 0.5)) return .{ .levels = 0, .offset = 0 };
    const levels_f = std.math.clamp(@ceil(std.math.log2(sigma / (sigma_per_level * offset_max))), 1, levels_max);
    const levels: u8 = @intFromFloat(levels_f);
    const offset = sigma / (sigma_per_level * std.math.exp2(levels_f));
    return .{ .levels = levels, .offset = @min(offset, offset_limit) };
}

/// Texels of `extent` at `level`, never zero.
pub fn levelExtent(extent: u32, level: u8) u32 {
    std.debug.assert(level <= levels_max);
    const divisor = @as(u32, 1) << @intCast(level);
    return @max(1, std.math.divCeil(u32, extent, divisor) catch unreachable);
}

/// Group regions from member bounds widened by their sampling reach, and one
/// glass instance per backdrop command in packet order. Groups whose region
/// misses the surface stay null; their members get an empty instance.
pub fn plan(
    commands: []const Command,
    content_scale: f32,
    phys_w: u32,
    phys_h: u32,
    glass: *std.ArrayList(pipelines.GlassInstance),
    allocator: std.mem.Allocator,
) !Plan {
    std.debug.assert(content_scale > 0 and std.math.isFinite(content_scale));
    var bounds: [groups_max]?[2]math.Vec2 = @splat(null);
    var sigma: [groups_max]f32 = @splat(0);
    var count: u32 = 0;
    for (commands) |command| {
        const backdrop = switch (command.payload) {
            .backdrop => |value| value,
            else => continue,
        };
        const reach = backdrop.material.reach();
        const lo = backdrop.bounds.min() - @as(math.Vec2, @splat(reach));
        const hi = backdrop.bounds.max() + @as(math.Vec2, @splat(reach));
        const slot = &bounds[backdrop.group];
        slot.* = if (slot.*) |current| .{ @min(current[0], lo), @max(current[1], hi) } else .{ lo, hi };
        sigma[backdrop.group] = @max(sigma[backdrop.group], backdrop.material.blur * content_scale);
        count += 1;
    }

    var result: Plan = .{};
    for (bounds, 0..) |maybe, index| {
        const extent = maybe orelse continue;
        const region = physicalRegion(extent, content_scale, phys_w, phys_h) orelse continue;
        result.groups[index] = .{ .region = region, .blur = blurPlan(sigma[index]) };
    }

    glass.clearRetainingCapacity();
    try glass.ensureTotalCapacity(allocator, count);
    for (commands) |command| {
        const backdrop = switch (command.payload) {
            .backdrop => |value| value,
            else => continue,
        };
        const group = result.groups[backdrop.group] orelse {
            glass.appendAssumeCapacity(std.mem.zeroes(pipelines.GlassInstance));
            continue;
        };
        const level = group.blur.finalLevel();
        const texels_per_logical = content_scale / std.math.exp2(@as(f32, @floatFromInt(level)));
        glass.appendAssumeCapacity(.{
            .rect = backdrop.bounds.v,
            .corner_radius = backdrop.corner_radius,
            .sample_map = .{
                @as(f32, @floatFromInt(group.region.x)) / content_scale,
                @as(f32, @floatFromInt(group.region.y)) / content_scale,
                texels_per_logical / @as(f32, @floatFromInt(levelExtent(phys_w, level))),
                texels_per_logical / @as(f32, @floatFromInt(levelExtent(phys_h, level))),
            },
            .params = .{ backdrop.material.saturation, @floatFromInt(command.clip.node), 0, 0 },
            .optics = .{ backdrop.material.refraction, backdrop.material.bezel, backdrop.material.dispersion, backdrop.material.specular },
        });
    }
    return result;
}

fn physicalRegion(extent: [2]math.Vec2, scale: f32, phys_w: u32, phys_h: u32) ?Region {
    const w: f32 = @floatFromInt(phys_w);
    const h: f32 = @floatFromInt(phys_h);
    const left = std.math.clamp(@floor(extent[0][0] * scale), 0, w);
    const top = std.math.clamp(@floor(extent[0][1] * scale), 0, h);
    const right = std.math.clamp(@ceil(extent[1][0] * scale), 0, w);
    const bottom = std.math.clamp(@ceil(extent[1][1] * scale), 0, h);
    if (!(right > left and bottom > top)) return null;
    return .{
        .x = @intFromFloat(left),
        .y = @intFromFloat(top),
        .width = @intFromFloat(right - left),
        .height = @intFromFloat(bottom - top),
    };
}

pub const Level = struct {
    texture: gpu_impl.Texture,
    bind_group: gpu_impl.BindGroup,
    width: u32,
    height: u32,

    pub fn deinit(self: *Level) void {
        self.bind_group.deinit();
        self.texture.deinit();
    }
};

/// Surface-sized levels of one group slot, created on first use.
pub const Targets = struct {
    levels: [levels_max + 1]?Level = @splat(null),

    /// Ensure `level` matches the surface. A replaced level is returned for the
    /// caller to release once in-flight frames finish with it.
    pub fn ensure(self: *Targets, context: *Context, level: u8, phys_w: u32, phys_h: u32) !?Level {
        const width = levelExtent(phys_w, level);
        const height = levelExtent(phys_h, level);
        const slot = &self.levels[level];
        if (slot.*) |current| {
            if (current.width == width and current.height == height) return null;
        }
        var texture = try context.device.createTexture(.{
            .width = width,
            .height = height,
            .format = context.sceneFormat(),
            .usage = .{ .texture_binding = true, .render_attachment = true },
            .label = "backdrop_level",
        });
        errdefer texture.deinit();
        const bind_group = try context.device.createBindGroup(.{
            .label = "backdrop_level_bg",
            .pipeline = &context.blur_down_pipeline,
            .layout_index = 1,
            .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = &texture } },
                .{ .binding = 1, .resource = .{ .sampler = &context.scene_sampler } },
            },
        });
        const replaced = slot.*;
        slot.* = .{ .texture = texture, .bind_group = bind_group, .width = width, .height = height };
        return replaced;
    }

    pub fn deinit(self: *Targets) void {
        for (&self.levels) |*slot| if (slot.*) |*level| level.deinit();
        self.levels = @splat(null);
    }
};

/// Snapshot the group's region of the scene and blur it. Call outside any open
/// render pass, with every level the group uses ensured.
pub fn capture(
    context: *Context,
    frame_ctx: *gpu_impl.Frame.Context,
    uploads: *FrameUploads,
    scene: *const gpu_impl.BindGroup,
    scene_w: u32,
    scene_h: u32,
    group: Group,
    targets: *Targets,
) !void {
    const region = group.region;
    const levels = group.blur.levels;
    var steps: [2 * levels_max]Step = undefined;
    var count: usize = 0;
    if (levels == 0) {
        steps[0] = .{ .kind = .down, .source = null, .target = 0 };
        count = 1;
    } else {
        var level: u8 = 1;
        while (level <= levels) : (level += 1) {
            steps[count] = .{ .kind = .down, .source = if (level == 1) null else level - 1, .target = level };
            count += 1;
        }
        level = levels - 1;
        while (level >= 1) : (level -= 1) {
            steps[count] = .{ .kind = .up, .source = level + 1, .target = level };
            count += 1;
        }
    }

    var instances: [2 * levels_max]pipelines.BlurInstance = undefined;
    for (steps[0..count], instances[0..count]) |step, *instance| {
        // The scene source is the region at full resolution, offset in the target.
        const source: Source = if (step.source) |level| .{
            .texture_w = targets.levels[level].?.width,
            .texture_h = targets.levels[level].?.height,
            .width = levelExtent(region.width, level),
            .height = levelExtent(region.height, level),
        } else .{
            .texture_w = scene_w,
            .texture_h = scene_h,
            .x = region.x,
            .y = region.y,
            .width = region.width,
            .height = region.height,
        };
        instance.* = source.blurInstance(
            levelExtent(region.width, step.target),
            levelExtent(region.height, step.target),
            if (levels == 0) 0 else group.blur.offset,
        );
    }

    const view = try uploads.upload(pipelines.BlurInstance, instances[0..count], .{ .vertex = true });
    const buffer = uploads.uploadBuffer(view.chunk_index, view.epoch).?;
    for (steps[0..count], 0..) |step, index| {
        const target = &targets.levels[step.target].?;
        const width = levelExtent(region.width, step.target);
        const height = levelExtent(region.height, step.target);
        var pass = try frame_ctx.beginRenderPass(.{
            .label = "backdrop_blur",
            .color_attachment = .{ .target = &target.texture, .clear_color = .{ 0, 0, 0, 0 } },
        });
        defer pass.end();
        pass.setViewport(0, 0, @floatFromInt(width), @floatFromInt(height));
        pass.setScissorRect(0, 0, width, height);
        pass.bindPipeline(switch (step.kind) {
            .down => &context.blur_down_pipeline,
            .up => &context.blur_up_pipeline,
        });
        pass.setBindGroup(0, &uploads.instance_uniform_bg);
        pass.setBindGroup(1, if (step.source) |level| &targets.levels[level].?.bind_group else scene);
        pass.setVertexBuffer(0, buffer, view.offset, view.size);
        pass.draw(3, 1, 0, @intCast(index));
    }
}

const Step = struct {
    kind: pipelines.BlurStep,
    /// Null reads the scene target.
    source: ?u8,
    target: u8,
};

/// A texel rect of a source texture.
const Source = struct {
    texture_w: u32,
    texture_h: u32,
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,

    fn blurInstance(self: Source, target_w: u32, target_h: u32, offset: f32) pipelines.BlurInstance {
        const tw: f32 = @floatFromInt(self.texture_w);
        const th: f32 = @floatFromInt(self.texture_h);
        const x: f32 = @floatFromInt(self.x);
        const y: f32 = @floatFromInt(self.y);
        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);
        return .{
            .source = .{ x / tw, y / th, w / tw, h / th },
            .bounds = .{ (x + 0.5) / tw, (y + 0.5) / th, (x + w - 0.5) / tw, (y + h - 0.5) / th },
            // Half a destination texel, in source UV.
            .tap = .{ offset * 0.5 * (w / tw) / @as(f32, @floatFromInt(target_w)), offset * 0.5 * (h / th) / @as(f32, @floatFromInt(target_h)) },
        };
    }
};

test "blur plan grows levels continuously" {
    try std.testing.expectEqual(@as(u8, 0), blurPlan(0).levels);
    try std.testing.expectEqual(@as(u8, 0), blurPlan(std.math.nan(f32)).levels);
    var previous: f32 = 0;
    var sigma: f32 = 1;
    while (sigma < 128) : (sigma += 0.25) {
        const blur = blurPlan(sigma);
        try std.testing.expect(blur.levels >= 1 and blur.levels <= levels_max);
        try std.testing.expect(blur.offset > 0 and blur.offset <= offset_limit);
        // Offsets stay in range until the last level, so the estimate tracks sigma.
        const estimate = sigma_per_level * blur.offset * std.math.exp2(@as(f32, @floatFromInt(blur.levels)));
        try std.testing.expectApproxEqRel(sigma, estimate, 1e-4);
        try std.testing.expect(estimate >= previous);
        previous = estimate;
    }
}

test "plan unions members, clamps to the surface, and keeps glass order" {
    const allocator = std.testing.allocator;
    var glass: std.ArrayList(pipelines.GlassInstance) = .empty;
    defer glass.deinit(allocator);
    const material: render.types.Material = .{ .blur = 2 };
    const commands = [_]Command{
        .{ .clip = .{}, .payload = .{ .backdrop = .{ .bounds = .init(10, 10, 20, 20), .corner_radius = @splat(0), .material = material, .group = 0 } } },
        .{ .clip = .{ .node = 3 }, .payload = .{ .backdrop = .{ .bounds = .init(40, 10, 20, 20), .corner_radius = @splat(4), .material = .{ .saturation = 1.5, .refraction = 1, .bezel = 2, .dispersion = 0.5, .specular = 0.25 }, .group = 0 } } },
        .{ .clip = .{}, .payload = .{ .backdrop = .{ .bounds = .init(500, 500, 10, 10), .corner_radius = @splat(0), .material = material, .group = 1 } } },
    };
    const result = try plan(&commands, 2, 200, 100, &glass, allocator);
    // Group 0: the first member widened by 3 * blur = 6 and the second by its
    // refraction reach of 1.5 union to x 4-61.5, y 4-36, then double.
    try std.testing.expectEqual(Region{ .x = 8, .y = 8, .width = 115, .height = 64 }, result.groups[0].?.region);
    try std.testing.expectEqual(blurPlan(4), result.groups[0].?.blur);
    try std.testing.expectEqual(@as(?Group, null), result.groups[1]);
    try std.testing.expectEqual(@as(usize, 3), glass.items.len);
    try std.testing.expectEqual([4]f32{ 40, 10, 20, 20 }, glass.items[1].rect);
    try std.testing.expectEqual([4]f32{ 1.5, 3, 0, 0 }, glass.items[1].params);
    try std.testing.expectEqual([4]f32{ 1, 2, 0.5, 0.25 }, glass.items[1].optics);
    // Level 1 texels per logical pixel (2 / 2) over the 100-texel-wide level.
    try std.testing.expectEqual([4]f32{ 4, 4, 0.01, 0.02 }, glass.items[0].sample_map);
    try std.testing.expectEqual(std.mem.zeroes(pipelines.GlassInstance), glass.items[2]);
}

test "level extents halve and round up" {
    try std.testing.expectEqual(@as(u32, 101), levelExtent(101, 0));
    try std.testing.expectEqual(@as(u32, 51), levelExtent(101, 1));
    try std.testing.expectEqual(@as(u32, 2), levelExtent(101, 6));
    try std.testing.expectEqual(@as(u32, 1), levelExtent(1, 6));
}
