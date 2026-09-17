const std = @import("std");
const input_types = @import("input");
const render = @import("render");
const text = @import("text");
const UI = @import("UI.zig");
const Frame = @import("Frame.zig");

pub const Config = struct {
    ui: UI.Config = .{},
    arena_reset_mode: std.heap.ArenaAllocator.ResetMode = .retain_capacity,
};

const Context = @This();

allocator: std.mem.Allocator,
frame_arena: std.heap.ArenaAllocator,
ui: UI,
draw_list: render.DrawList,
packet_commands: std.ArrayList(render.DrawList.Command),
cfg: Config,
frame_input: input_types.FrameInput,
frame_state: ?Frame.State,
generation: u64,
atlas_id: u32,
glyph_revision_emitted: u64,

pub fn init(allocator: std.mem.Allocator, cfg: Config) !Context {
    var ui = try UI.init(allocator, cfg.ui);
    errdefer ui.deinit();

    return .{
        .allocator = allocator,
        .frame_arena = .init(allocator),
        .ui = ui,
        .draw_list = .init(allocator),
        .packet_commands = .empty,
        .cfg = cfg,
        .frame_input = undefined,
        .frame_state = null,
        .generation = 0,
        .atlas_id = render.GlyphAtlas.allocateId(),
        .glyph_revision_emitted = 0,
    };
}

pub fn deinit(self: *Context) void {
    std.debug.assert(!self.frameIsActive());
    self.packet_commands.deinit(self.allocator);
    self.draw_list.deinit();
    self.ui.deinit();
    self.frame_arena.deinit();
    self.* = undefined;
}

/// Begin one embedded frame.
///
/// `input` and every slice it references are borrowed until `endFrame` or
/// `abortFrame`. Beginning another frame first returns `FrameAlreadyActive`.
pub fn beginFrame(self: *Context, input: input_types.FrameInput) !Frame {
    if (self.frameIsActive()) return error.FrameAlreadyActive;
    try validateInput(&input);

    if (self.generation == std.math.maxInt(u64)) return error.FrameGenerationExhausted;
    self.generation += 1;
    _ = self.frame_arena.reset(self.cfg.arena_reset_mode);
    self.packet_commands.clearRetainingCapacity();
    self.frame_input = input;
    try self.ui.resolveWindow(input.input, input.now_ms, input.content_scale);
    self.ui.reset();
    self.frame_state = .init(
        &self.ui,
        self.frame_arena.allocator(),
        self.frame_arena.queryCapacity(),
        &self.frame_input,
        self.generation,
    );

    return .{
        ._state = &self.frame_state.?,
        ._generation = self.generation,
    };
}

/// Finish one frame for every backend. Output is borrowed until the next
/// beginFrame attempt or Context.deinit; failure also releases the active frame.
pub fn endFrame(self: *Context, frame: *Frame) !Frame.Output {
    if (!self.frameIsActive()) return error.FrameNotActive;
    if (frame._state != &self.frame_state.?) return error.InvalidFrame;
    if (frame._generation != self.generation) return error.InvalidFrame;
    errdefer self.frame_state.?.active = false;
    try self.ui.endFrame();
    try self.ui.resolve();
    self.draw_list.reset();
    try self.ui.tessellate(self.frame_arena.allocator(), &self.draw_list);
    const hover_changed = self.ui.resolveHit();
    self.frame_state.?.active = false;
    const packet = try self.draw_list.buildPacket(&self.packet_commands, self.glyphAtlas());
    return .{
        .packet = packet,
        .cursor_shape = self.ui.cursor_shape,
        .capture_pointer = self.ui.state.hovered != UI.INVALID_ID,
        .capture_keyboard = self.ui.state.focused != UI.INVALID_ID,
        .text_input = self.ui.text_input_requested,
        .redraw = self.frame_state.?.effects.redraw or hover_changed or
            self.ui.anim_active,
        .close = self.frame_state.?.effects.close,
        .clipboard_write = self.frame_state.?.effects.clipboard_write,
    };
}

/// Cancel an active frame after user code fails, allowing a later retry.
/// Aborting an already-finished frame returns `error.FrameNotActive`.
pub fn abortFrame(self: *Context, frame: *Frame) !void {
    if (!self.frameIsActive()) return error.FrameNotActive;
    if (frame._state != &self.frame_state.?) return error.InvalidFrame;
    if (frame._generation != self.generation) return error.InvalidFrame;
    self.frame_state.?.active = false;
}

fn frameIsActive(self: *const Context) bool {
    const frame_state = self.frame_state orelse return false;
    return frame_state.active;
}

fn glyphAtlas(self: *Context) render.GlyphAtlas {
    const builder = self.ui.font.glyph_builder;
    comptime {
        std.debug.assert(text.GlyphBuilder.texture_width == render.GlyphAtlas.width);
        std.debug.assert(@sizeOf(text.GlyphBuilder.CurveTexel) == render.GlyphAtlas.texel_bytes);
        std.debug.assert(@sizeOf(text.GlyphBuilder.BandTexel) == render.GlyphAtlas.texel_bytes);
    }
    const atlas: render.GlyphAtlas = .{
        .id = self.atlas_id,
        .revision = builder.revision(),
        .base_revision = self.glyph_revision_emitted,
        .curve_row_start = if (builder.curveDirtyRange()) |range| range.y_start else builder.curveTextureHeight(),
        .band_row_start = if (builder.bandDirtyRange()) |range| range.y_start else builder.bandTextureHeight(),
        .curve = std.mem.sliceAsBytes(builder.curve_data.items),
        .band = std.mem.sliceAsBytes(builder.band_data.items),
    };
    atlas.validate();
    // A missed output is safe: consumers with an older revision use full data.
    self.glyph_revision_emitted = atlas.revision;
    builder.markClean();
    return atlas;
}

fn validateInput(input: *const input_types.FrameInput) !void {
    if (input.logical_extent.width == 0) return error.InvalidFrameExtent;
    if (input.logical_extent.height == 0) return error.InvalidFrameExtent;
    if (input.physical_extent.width == 0) return error.InvalidFrameExtent;
    if (input.physical_extent.height == 0) return error.InvalidFrameExtent;
    if (!std.math.isFinite(input.content_scale)) return error.InvalidContentScale;
    if (input.content_scale <= 0) return error.InvalidContentScale;
}

test "frame lifecycle rejects invalid ordering and supports abort" {
    var view = try Context.init(std.testing.allocator, .{});
    defer view.deinit();

    const input: input_types.FrameInput = .{
        .input = .{ .pos = .{ 0, 0 } },
        .now_ms = 0,
        .delta_ns = 0,
        .logical_extent = .{ .width = 10, .height = 10 },
        .physical_extent = .{ .width = 10, .height = 10 },
        .content_scale = 1,
    };
    var frame = try view.beginFrame(input);
    try view.abortFrame(&frame);
    try std.testing.expectError(error.FrameNotActive, view.abortFrame(&frame));
    frame = try view.beginFrame(input);
    _ = try view.endFrame(&frame);
    try std.testing.expectError(error.FrameNotActive, view.endFrame(&frame));
}

test "frame carries host input, effects, and retryable glyph data" {
    var view = try Context.init(std.testing.allocator, .{});
    defer view.deinit();

    const dropped = [_][]const u8{"asset.glb"};
    const input: input_types.FrameInput = .{
        .input = .{ .pos = .{ 2, 3 } },
        .now_ms = 12,
        .delta_ns = 16,
        .logical_extent = .{ .width = 100, .height = 50 },
        .physical_extent = .{ .width = 200, .height = 100 },
        .content_scale = 2,
        .paste_text = "paste",
        .dropped_paths = &dropped,
    };

    var frame = try view.beginFrame(input);
    try std.testing.expectEqualStrings("paste", frame.pasteText().?);
    try std.testing.expectEqualStrings("asset.glb", frame.droppedPaths()[0]);
    try std.testing.expectEqual(@as(u32, 200), frame.input().physical_extent.width);
    frame.requestRedraw();
    frame.requestClose();
    try frame.writeClipboard("copy");
    const first = try view.endFrame(&frame);
    try std.testing.expect(first.redraw);
    try std.testing.expect(first.close);
    try std.testing.expectEqualStrings("copy", first.clipboard_write.?);

    const glyph = first.packet.glyphAtlas().?;
    frame = try view.beginFrame(input);
    const second = try view.endFrame(&frame);
    try std.testing.expectEqual(glyph.id, second.packet.glyphAtlas().?.id);
    try std.testing.expectEqual(glyph.revision, second.packet.glyphAtlas().?.revision);
}

test "frame validates extents and scale" {
    var view = try Context.init(std.testing.allocator, .{});
    defer view.deinit();
    const base: input_types.FrameInput = .{
        .input = .{ .pos = .{ 0, 0 } },
        .now_ms = 0,
        .delta_ns = 0,
        .logical_extent = .{ .width = 0, .height = 1 },
        .physical_extent = .{ .width = 1, .height = 1 },
        .content_scale = 1,
    };
    try std.testing.expectError(error.InvalidFrameExtent, view.beginFrame(base));
    var invalid_scale = base;
    invalid_scale.logical_extent.width = 1;
    invalid_scale.content_scale = 0;
    try std.testing.expectError(error.InvalidContentScale, view.beginFrame(invalid_scale));
}

test "every finalization allocation failure releases the frame and permits retry" {
    const input: input_types.FrameInput = .{
        .input = .{ .pos = .{ 0, 0 } },
        .now_ms = 0,
        .delta_ns = 0,
        .logical_extent = .{ .width = 100, .height = 100 },
        .physical_extent = .{ .width = 100, .height = 100 },
        .content_scale = 1,
    };
    var completed = false;
    var failure_offset: u32 = 0;
    while (failure_offset < 64) : (failure_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = std.math.maxInt(usize),
            .resize_fail_index = std.math.maxInt(usize),
        });
        var view = try Context.init(failing.allocator(), .{});
        defer view.deinit();
        var frame = try view.beginFrame(input);
        defer frame.deinit();
        _ = try frame.ui().open(.src(@src()), .{
            .width = .fixed(40),
            .height = .fixed(40),
        }, .{ .rect = .{ .color = .{ 1, 0, 0, 1 } } });
        frame.ui().close();
        failing.fail_index = failing.alloc_index + failure_offset;
        failing.resize_fail_index = failing.resize_index;
        if (view.endFrame(&frame)) |_| {
            completed = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(!view.frameIsActive());
        }
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        var next = try view.beginFrame(input);
        defer next.deinit();
        _ = try view.endFrame(&next);
        if (completed) break;
    }
    try std.testing.expect(completed);
    try std.testing.expect(failure_offset > 0);
}
