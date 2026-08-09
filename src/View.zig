const std = @import("std");
const input_types = @import("input");
const render = @import("render");
const text = @import("text");
const UI = @import("ui").UI;
const Frame = @import("Frame.zig");
const FrameState = @import("FrameState.zig");

pub const Config = struct {
    ui: UI.Config = .{},
    arena_reset_mode: std.heap.ArenaAllocator.ResetMode = .retain_capacity,
};

/// `Frame.Output` for hosts driving Knots' own renderer: the draw list is handed
/// over directly instead of projected into a packet.
pub const RendererOutput = struct {
    draw_list: *const render.DrawList,
    glyph_builder: *text.GlyphBuilder,
    cursor_shape: input_types.CursorShape,
    capture_pointer: bool,
    capture_keyboard: bool,
    text_input: bool,
    redraw: bool,
    close: bool,
    clipboard_write: ?[]const u8,
};

_impl: *Impl,

const View = @This();

const Impl = struct {
    allocator: std.mem.Allocator,
    frame_arena: std.heap.ArenaAllocator,
    ui_state: UI,
    draw_list: render.DrawList,
    packet_commands: std.ArrayList(render.Packet.Command),
    cfg: Config,
    frame_input: input_types.FrameInput,
    frame_state: ?FrameState,
    glyph_generation: u64,
    glyph_generation_pending: ?u64,
    glyph_revision_emitted: u64,
};

pub fn init(allocator: std.mem.Allocator, cfg: Config) !View {
    const impl = try allocator.create(Impl);
    errdefer allocator.destroy(impl);
    var ui_state = try UI.init(allocator, cfg.ui);
    errdefer ui_state.deinit();
    impl.* = .{
        .allocator = allocator,
        .frame_arena = .init(allocator),
        .ui_state = ui_state,
        .draw_list = .init(allocator),
        .packet_commands = .empty,
        .cfg = cfg,
        .frame_input = undefined,
        .frame_state = null,
        .glyph_generation = 0,
        .glyph_generation_pending = null,
        .glyph_revision_emitted = 0,
    };
    return .{ ._impl = impl };
}

pub fn deinit(self: *View) void {
    const impl = self.implPtr();
    std.debug.assert(!self.frameIsActive());
    impl.packet_commands.deinit(impl.allocator);
    impl.draw_list.deinit();
    impl.ui_state.deinit();
    impl.frame_arena.deinit();
    impl.allocator.destroy(impl);
    self.* = undefined;
}

/// Begin one embedded frame.
///
/// `input` and every slice it references are borrowed until `endFrame` or
/// `abortFrame`. Beginning another frame first returns `FrameAlreadyActive`.
pub fn beginFrame(
    self: *View,
    input: input_types.FrameInput,
) !Frame {
    return self.beginFrameInternal(input);
}

fn beginFrameInternal(
    self: *View,
    input: input_types.FrameInput,
) !Frame {
    if (self.frameIsActive()) return error.FrameAlreadyActive;
    try validateInput(&input);

    const impl = self.implPtr();
    _ = impl.frame_arena.reset(impl.cfg.arena_reset_mode);
    impl.packet_commands.clearRetainingCapacity();
    impl.frame_input = input;
    try impl.ui_state.resolveWindow(input.input, input.now_ms, input.content_scale);
    impl.ui_state.reset();
    impl.frame_state = .init(
        &impl.ui_state,
        impl.frame_arena.allocator(),
        impl.frame_arena.queryCapacity(),
        &impl.frame_input,
    );

    return .{
        ._state = &impl.frame_state.?,
    };
}

/// Finalize portable output. Its packet and effect slices remain valid until
/// this view begins its next frame.
pub fn endFrame(self: *View, frame: *Frame) !Frame.Output {
    const hover_changed = try self.finishFrame(frame);
    const impl = self.implPtr();
    const packet = try impl.draw_list.buildPacket(
        &impl.packet_commands,
        self.glyphUpdate(),
    );
    return .{
        .packet = packet,
        .cursor_shape = impl.ui_state.cursor_shape,
        .capture_pointer = impl.ui_state.state.hovered != UI.INVALID_ID,
        .capture_keyboard = impl.ui_state.state.focused != UI.INVALID_ID,
        .text_input = impl.ui_state.text_input_requested,
        .redraw = impl.frame_state.?.effects.redraw or hover_changed or
            impl.ui_state.anim_active,
        .close = impl.frame_state.?.effects.close,
        .clipboard_write = impl.frame_state.?.effects.clipboard_write,
    };
}

pub fn endRendererFrame(self: *View, frame: *Frame) !RendererOutput {
    const hover_changed = try self.finishFrame(frame);
    const impl = self.implPtr();
    return .{
        .draw_list = &impl.draw_list,
        .glyph_builder = impl.ui_state.font.glyph_builder,
        .cursor_shape = impl.ui_state.cursor_shape,
        .capture_pointer = impl.ui_state.state.hovered != UI.INVALID_ID,
        .capture_keyboard = impl.ui_state.state.focused != UI.INVALID_ID,
        .text_input = impl.ui_state.text_input_requested,
        .redraw = impl.frame_state.?.effects.redraw or hover_changed or
            impl.ui_state.anim_active,
        .close = impl.frame_state.?.effects.close,
        .clipboard_write = impl.frame_state.?.effects.clipboard_write,
    };
}

fn finishFrame(self: *View, frame: *Frame) !bool {
    const impl = self.implPtr();
    if (!self.frameIsActive()) return error.FrameNotActive;
    if (frame._state != &impl.frame_state.?) return error.InvalidFrame;
    errdefer impl.frame_state.?.active = false;
    try impl.ui_state.endFrame();
    try impl.ui_state.resolve();
    impl.draw_list.reset();
    try impl.ui_state.tessellate(impl.frame_arena.allocator(), &impl.draw_list);
    const hover_changed = impl.ui_state.resolveHit();
    impl.frame_state.?.active = false;
    return hover_changed;
}

/// Cancel an active frame after user code fails, allowing a later retry.
/// Aborting an already-finished frame returns `error.FrameNotActive`.
pub fn abortFrame(self: *View, frame: *Frame) !void {
    const impl = self.implPtr();
    if (!self.frameIsActive()) return error.FrameNotActive;
    if (frame._state != &impl.frame_state.?) return error.InvalidFrame;
    impl.frame_state.?.active = false;
}

/// Acknowledge an uploaded glyph generation. Call between `endFrame` and the
/// next `beginFrame`.
///
/// Returns false for stale, duplicate or unknown generations, and once the atlas
/// has changed again — clearing then would drop rows the host never received.
pub fn acknowledgeGlyphUpload(self: *View, generation: u64) bool {
    const impl = self.implPtr();
    if (impl.glyph_generation_pending != generation) return false;
    const builder = impl.ui_state.font.glyph_builder;
    if (builder.revision() != impl.glyph_revision_emitted) return false;
    builder.markClean();
    impl.glyph_generation_pending = null;
    return true;
}

pub fn markGlyphsDirty(self: *View) void {
    self.implPtr().ui_state.font.glyph_builder.markAllDirty();
}

pub fn ui(self: *View) *UI {
    return &self.implPtr().ui_state;
}

fn frameIsActive(self: *const View) bool {
    const frame_state = self.implPtrConst().frame_state orelse return false;
    return frame_state.active;
}

fn glyphUpdate(self: *View) ?render.Packet.GlyphUpdate {
    const impl = self.implPtr();
    const builder = impl.ui_state.font.glyph_builder;
    const curve_range = builder.curveDirtyRange();
    const band_range = builder.bandDirtyRange();
    if (curve_range == null and band_range == null) return null;

    // A null pending means the last generation was retired, so these rows need a
    // fresh one even if the revision has not moved.
    if (builder.revision() != impl.glyph_revision_emitted or
        impl.glyph_generation_pending == null)
    {
        impl.glyph_generation +%= 1;
        if (impl.glyph_generation == 0) impl.glyph_generation = 1;
        impl.glyph_generation_pending = impl.glyph_generation;
        impl.glyph_revision_emitted = builder.revision();
    }

    return .{
        .generation = impl.glyph_generation_pending.?,
        .curve = if (curve_range) |range| .{
            .bytes = builder.curveBytes(range),
            .row_start = range.y_start,
            .row_end = range.y_end,
            .row_texels = text.GlyphBuilder.texture_width,
            .row_bytes = text.GlyphBuilder.texture_width *
                @sizeOf(text.GlyphBuilder.CurveTexel),
            .texel_size_bytes = @sizeOf(text.GlyphBuilder.CurveTexel),
        } else null,
        .band = if (band_range) |range| .{
            .bytes = builder.bandBytes(range),
            .row_start = range.y_start,
            .row_end = range.y_end,
            .row_texels = text.GlyphBuilder.texture_width,
            .row_bytes = text.GlyphBuilder.texture_width *
                @sizeOf(text.GlyphBuilder.BandTexel),
            .texel_size_bytes = @sizeOf(text.GlyphBuilder.BandTexel),
        } else null,
    };
}

fn implPtr(self: *View) *Impl {
    return self._impl;
}

fn implPtrConst(self: *const View) *const Impl {
    return self._impl;
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
    var view = try View.init(std.testing.allocator, .{});
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
    var view = try View.init(std.testing.allocator, .{});
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

    const glyph = first.packet.glyphUpdate().?;
    frame = try view.beginFrame(input);
    const second = try view.endFrame(&frame);
    try std.testing.expectEqual(glyph.generation, second.packet.glyphUpdate().?.generation);
    try std.testing.expect(view.acknowledgeGlyphUpload(glyph.generation));
    try std.testing.expect(!view.acknowledgeGlyphUpload(glyph.generation));

    frame = try view.beginFrame(input);
    const third = try view.endFrame(&frame);
    try std.testing.expectEqual(@as(?render.Packet.GlyphUpdate, null), third.packet.glyphUpdate());
}

test "frame validates extents and scale" {
    var view = try View.init(std.testing.allocator, .{});
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
