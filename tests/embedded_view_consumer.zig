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

test "accessibility snapshot flattens visual ancestors and keeps semantic revision stable" {
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    var revision: u64 = 0;
    for (0..2) |iteration| {
        var frame = try view.beginFrame(frameInput(@intCast(iteration * 16)));
        defer frame.deinit();
        const layout = frame.ui();
        const root = try layout.open(ui.Key.str("visual-root"), .{ .width = .fixed(300), .height = .fixed(200) }, .none);
        const parent = try layout.open(ui.Key.str("semantic-parent"), .{ .width = .fixed(100), .height = .fixed(80) }, .none);
        try layout.setAccessibility(parent, .{ .role = .dialog, .name = "Parent" });
        _ = try layout.open(ui.Key.str("visual-only"), .{ .width = .fixed(50), .height = .fixed(30) }, .none);
        const child = try layout.open(ui.Key.str("semantic-child"), .{ .width = .fixed(20), .height = .fixed(10) }, .none);
        try layout.setAccessibility(child, .{ .role = .button, .name = "Child" });
        layout.close();
        layout.close();
        layout.close();
        layout.close();
        const output = try view.endFrame(&frame);
        try std.testing.expectEqual(@as(usize, 3), output.accessibility.nodes.len);
        try std.testing.expectEqual(@as(usize, 2), output.accessibility.children.len);
        try std.testing.expectEqual(@as(u64, 0), output.accessibility.nodes[0].id);
        try std.testing.expectEqual(parent, output.accessibility.nodes[2].parent);
        try std.testing.expectEqual(parent, output.accessibility.nodes[1].id);
        try std.testing.expectEqual(child, output.accessibility.nodes[2].id);
        try std.testing.expect(output.accessibility.nodes[2].actions.contains(.click));
        try std.testing.expect(root != parent);
        if (iteration == 0) {
            revision = output.accessibility.revision;
            try std.testing.expect(revision > 0);
        } else try std.testing.expectEqual(revision, output.accessibility.revision);
    }
    var removed = try view.beginFrame(frameInput(32));
    defer removed.deinit();
    const output = try view.endFrame(&removed);
    try std.testing.expectEqual(@as(usize, 1), output.accessibility.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), output.accessibility.children.len);
    try std.testing.expect(output.accessibility.revision > revision);
}

test "accessibility action queue copies text and rejects invalid or overflowing requests" {
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    try std.testing.expectError(error.InvalidAccessibilityTarget, view.enqueueAccessibilityAction(.{ .id = 0, .action = .click }));
    var value = [_]u8{ 'O', 'K' };
    try view.enqueueAccessibilityAction(.{ .id = 17, .action = .set_value, .value_text = &value });
    value[0] = 'N';
    for (1..ui.Accessibility.actions_max) |_| try view.enqueueAccessibilityAction(.{ .id = 17, .action = .click });
    try std.testing.expectError(error.TooManyAccessibilityActions, view.enqueueAccessibilityAction(.{ .id = 17, .action = .click }));
    var frame = try view.beginFrame(frameInput(0));
    defer frame.deinit();
    const request = frame.ui().consumeAccessibilityAction(17, .set_value).?;
    try std.testing.expectEqualStrings("OK", request.value_text.?);
    try std.testing.expect(frame.ui().consumeAccessibilityAction(17, .set_value) == null);
    _ = try view.endFrame(&frame);
}

test "accessibility actions take the ordinary button checkbox and slider paths" {
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    var checked = false;
    var value: f32 = 0;
    const button: ui.component.Button = .{ .key = ui.Key.str("button") };
    const checkbox: ui.component.Checkbox = .{ .key = ui.Key.str("checkbox"), .checked = &checked };
    const slider: ui.component.SliderInput = .{ .key = ui.Key.str("slider"), .value = &value };
    for (0..2) |iteration| {
        var frame = try view.beginFrame(frameInput(@intCast(iteration * 16)));
        defer frame.deinit();
        _ = try frame.ui().open(ui.Key.str("root"), .{ .width = .fixed(300), .height = .fixed(200) }, .none);
        const button_response = try button.interact(&frame);
        const checkbox_response = try checkbox.interact(&frame);
        const slider_response = try slider.interact(&frame);
        frame.ui().close();
        try std.testing.expectEqual(iteration == 1, button_response.clicked);
        try std.testing.expectEqual(iteration == 1, checkbox_response.changed);
        try std.testing.expectEqual(iteration == 1, slider_response.changed);
        const output = try view.endFrame(&frame);
        try std.testing.expectEqual(@as(usize, 4), output.accessibility.nodes.len);
        try std.testing.expectEqual(@as(u32, 3), output.accessibility.nodes[0].child_count);
        for (output.accessibility.nodes[1..]) |node| {
            try std.testing.expect(node.role != .generic);
            try std.testing.expect(node.actions.contains(.focus));
        }
        if (iteration == 0) {
            try view.enqueueAccessibilityAction(.{ .id = button.key.hash(), .action = .click });
            try view.enqueueAccessibilityAction(.{ .id = checkbox.key.hash(), .action = .click });
            try view.enqueueAccessibilityAction(.{ .id = slider.key.hash(), .action = .set_value, .value_number = 0.75 });
        }
    }
    try std.testing.expect(checked);
    try std.testing.expectEqual(@as(f32, 0.75), value);
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
