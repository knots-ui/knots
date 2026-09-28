const std = @import("std");
const ui = @import("knots-ui");
const renderer = @import("knots-renderer");
const Window = @import("knots-window").Window;

pub fn main(init: std.process.Init) !void {
    var window = try Window.init(init.io, init.gpa, .{
        .width = 640,
        .height = 480,
        .title = "Embedded Knots",
        .resizable = false,
    });
    defer window.deinit();

    window.startCapture();

    var device = try renderer.backend.Device.init(init.gpa, window.getWindowHandle());
    defer device.deinit();

    const context = try renderer.Context.createForDevice(init.gpa, &device, false);
    defer context.destroy();

    const extent = window.getFramebufferSize();

    var surface = try renderer.backend.Surface.init(&device, window.getWindowHandle(), .{
        .window_width = extent.width,
        .window_height = extent.height,
        .present_mode = .fifo,
    });
    defer surface.deinit();

    var gpu_frame = try renderer.backend.Frame.create(&surface);
    defer gpu_frame.deinit();

    const painter = try renderer.Painter.create(init.gpa, context, gpu_frame.uploadSlotCount());
    defer painter.destroyAfterWait();

    var target = try device.createTexture(.{
        .width = extent.width,
        .height = extent.height,
        .format = device.surfaceFormat(),
        .usage = .{ .render_attachment = true, .texture_binding = true },
        .label = "host_target",
    });
    defer target.deinit();

    // Also complete GPU work on an error, before any borrowed resources are freed.
    defer device.waitIdle() catch |err| std.log.err("GPU completion failed: {s}", .{@errorName(err)});

    var context_ui = try ui.Context.init(init.gpa, .{});
    defer context_ui.deinit();

    var tick: u32 = 0;
    while (tick < 600) : (tick += 1) {
        window.pollEvents(init.io);
        if (!window.isOpen()) break;
        defer window.finishInputFrame();

        var frame = try context_ui.beginFrame(.{
            .input = try window.collectInput(),
            .now_ms = @as(i64, tick) * 16,
            .delta_ns = 16 * std.time.ns_per_ms,
            .logical_extent = window.getSize(),
            .physical_extent = extent,
            .content_scale = window.getContentScale(),
        });
        defer frame.deinit();

        try frame.e(ui.component.Rect{
            .key = .src(@src()),
            .style = &.{ .width = .fixed(240), .height = .fixed(100), .background = .{ .color = .{ .value = .{ 0.2, 0.4, 0.8, 1 } } } },
        });

        const response = try frame.interact(ui.component.Button{ .key = .src(@src()), .label = "Close" });
        if (response.clicked) frame.requestClose();

        const output = try context_ui.endFrame(&frame);
        window.setCursorShape(output.cursor_shape);

        if (output.clipboard_write) |value| _ = try window.setClipboardText(init.gpa, value);
        if (output.close) break;

        var submission = try gpu_frame.begin();
        const prepared = try painter.prepare(&output.packet, &.{
            .width = extent.width,
            .height = extent.height,
            .content_scale = window.getContentScale(),
            .upload_slot = submission.upload_slot,
            .linear_target = false,
        });

        // The same prepared packet can be encoded into compatible host targets.
        var offscreen = try submission.beginRenderPass(.{
            .label = "host_offscreen",
            .color_attachment = .{ .target = &target, .clear_color = .{ 0, 0, 0, 1 } },
        });
        {
            defer offscreen.end();
            try painter.encode(&prepared, &offscreen);
        }

        var onscreen = try submission.beginRenderPass(.{
            .label = "host_onscreen",
            .color_attachment = .{ .clear_color = .{ 0.04, 0.04, 0.04, 1 } },
        });
        {
            defer onscreen.end();
            try painter.encode(&prepared, &onscreen);
        }

        try submission.submit();

        // This example uses a single offscreen target; finish before reusing it.
        try gpu_frame.waitForCompletion();
    }
}
