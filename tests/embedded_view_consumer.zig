const std = @import("std");
const input = @import("input");
const render = @import("render");
const View = @import("view");

fn frameInput(now_ms: i64) input.FrameInput {
    return .{
        .input = .{ .pos = .{ 0, 0 } },
        .now_ms = now_ms,
        .delta_ns = 16 * std.time.ns_per_ms,
        .logical_extent = .{ .width = 320, .height = 240 },
        .physical_extent = .{ .width = 640, .height = 480 },
        .content_scale = 2,
    };
}

const HostEncoder = struct {
    primitive_indices: u64 = 0,
    instances: u64 = 0,
    text_indices: u64 = 0,
    uploaded_generation: ?u64 = null,

    fn encode(self: *HostEncoder, packet: *const render.Packet) !void {
        for (packet.commands()) |command| {
            if (command.clip.node >= packet.clipNodes().len) return error.InvalidClipNode;
            switch (command.payload) {
                .primitive => |range| self.primitive_indices += range.count,
                .instances => |range| self.instances += range.count,
                .text => |range| self.text_indices += range.count,
            }
        }
        if (packet.glyphUpdate()) |update| {
            if (update.curve) |plane| {
                const rows = plane.row_end - plane.row_start;
                if (plane.bytes.len > rows * plane.row_bytes) return error.GlyphPlaneOverrun;
            }
            self.uploaded_generation = update.generation;
        }
    }
};

test "a renderer-free host can drive a view and acknowledge glyph uploads" {
    var view = try View.init(std.testing.allocator, .{});
    defer view.deinit();

    var host: HostEncoder = .{};

    var frame = try view.beginFrame(frameInput(0));
    errdefer view.abortFrame(&frame) catch {};
    const first = try view.endFrame(&frame);
    try host.encode(&first.packet);

    const generation = host.uploaded_generation orelse return error.ExpectedGlyphUpload;
    try std.testing.expect(view.acknowledgeGlyphUpload(generation));
    try std.testing.expect(!view.acknowledgeGlyphUpload(generation));

    host.uploaded_generation = null;
    var second_frame = try view.beginFrame(frameInput(16));
    const second = try view.endFrame(&second_frame);
    try host.encode(&second.packet);
    try std.testing.expectEqual(@as(?u64, null), host.uploaded_generation);
}

test "an acknowledgement that arrives after new glyph work is rejected" {
    var view = try View.init(std.testing.allocator, .{});
    defer view.deinit();

    var frame = try view.beginFrame(frameInput(0));
    const first = try view.endFrame(&frame);
    const generation = (first.packet.glyphUpdate() orelse
        return error.ExpectedGlyphUpload).generation;

    view.markGlyphsDirty();

    try std.testing.expect(!view.acknowledgeGlyphUpload(generation));

    var next = try view.beginFrame(frameInput(16));
    const second = try view.endFrame(&next);
    try std.testing.expect(second.packet.glyphUpdate() != null);
}

test "frame lifecycle errors are reported rather than trapped" {
    var view = try View.init(std.testing.allocator, .{});
    defer view.deinit();

    var frame = try view.beginFrame(frameInput(0));
    try std.testing.expectError(error.FrameAlreadyActive, view.beginFrame(frameInput(0)));
    _ = try view.endFrame(&frame);
    try std.testing.expectError(error.FrameNotActive, view.endFrame(&frame));
}
