const std = @import("std");
const ui = @import("knots-ui");
const input = @import("knots-input");
const render = @import("knots-render");
const renderer = @import("knots-renderer");

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

test "independent renderer caches consume the same output without acknowledgements" {
    const Uploader = struct {
        calls: u32 = 0,
        pub fn uploadGlyphAtlas(self: *@This(), atlas: *const render.GlyphAtlas) !void {
            atlas.validate();
            std.debug.assert(self.calls < 4);
            self.calls += 1;
        }
    };
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    var first_cache: renderer.GlyphAtlasCache = .{};
    var second_cache: renderer.GlyphAtlasCache = .{};
    var uploader: Uploader = .{};
    var frame = try view.beginFrame(frameInput(0));
    defer frame.deinit();
    const output = try view.endFrame(&frame);
    try first_cache.sync(&output.packet.glyphAtlas().?, &uploader, Uploader.uploadGlyphAtlas);
    try second_cache.sync(&output.packet.glyphAtlas().?, &uploader, Uploader.uploadGlyphAtlas);
    try std.testing.expectEqual(@as(u32, 2), uploader.calls);
    var next = try view.beginFrame(frameInput(16));
    defer next.deinit();
    const next_output = try view.endFrame(&next);
    try first_cache.sync(&next_output.packet.glyphAtlas().?, &uploader, Uploader.uploadGlyphAtlas);
    try std.testing.expectEqual(@as(u32, 2), uploader.calls);
    var other = try ui.Context.init(std.testing.allocator, .{});
    defer other.deinit();
    var other_frame = try other.beginFrame(frameInput(16));
    defer other_frame.deinit();
    const other_output = try other.endFrame(&other_frame);
    try std.testing.expect(other_output.packet.glyphAtlas().?.id != first_cache.id);
    try first_cache.sync(&other_output.packet.glyphAtlas().?, &uploader, Uploader.uploadGlyphAtlas);
    try std.testing.expectEqual(@as(u32, 3), uploader.calls);
}

test "copied frame cleanup cannot abort a reused backing state" {
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    var frame = try view.beginFrame(frameInput(0));
    var copy = frame;
    frame.deinit();
    copy.deinit();
    var next = try view.beginFrame(frameInput(16));
    defer next.deinit();
    copy.deinit();
    try std.testing.expectError(error.InvalidFrame, view.endFrame(&copy));
    try std.testing.expectError(error.InvalidFrame, view.abortFrame(&copy));
    _ = try view.endFrame(&next);
    next.deinit();
}

test "frame lifecycle errors and foreign handles preserve the active frame" {
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    var other = try ui.Context.init(std.testing.allocator, .{});
    defer other.deinit();
    var foreign = try other.beginFrame(frameInput(0));
    defer foreign.deinit();
    var frame = try view.beginFrame(frameInput(0));
    defer frame.deinit();
    try std.testing.expectError(error.FrameAlreadyActive, view.beginFrame(frameInput(0)));
    try std.testing.expectError(error.InvalidFrame, view.endFrame(&foreign));
    _ = try view.endFrame(&frame);
    try std.testing.expectError(error.FrameNotActive, view.endFrame(&frame));
}

test "a failed UI build is aborted by deferred frame cleanup" {
    const Host = struct {
        fn build(view: *ui.Context) !void {
            var frame = try view.beginFrame(frameInput(0));
            defer frame.deinit();
            return error.BuildFailed;
        }
    };
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    try std.testing.expectError(error.BuildFailed, Host.build(&view));
    var next = try view.beginFrame(frameInput(16));
    defer next.deinit();
    _ = try view.endFrame(&next);
}
