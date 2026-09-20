//! Internal guest support. Applications use knots.Frame.
const std = @import("std");
const ui = @import("ui");

pub const Protocol = @import("Protocol.zig");
pub const Status = @import("Status.zig");
pub const FrameProtocol = @import("FrameProtocol.zig");
pub const Wire = @import("Wire.zig");
pub const Panels = @import("Panels.zig");

comptime {
    std.debug.assert(Protocol.version == Wire.version);
    std.debug.assert(Protocol.bytes_max == Wire.bytes_max);
}

pub const Guest = struct {
    executor: ui.Context,
    main: *const fn (*ui.Frame) anyerror!void,

    pub fn init(allocator: std.mem.Allocator, main: *const fn (*ui.Frame) anyerror!void) !Guest {
        std.debug.assert(@intFromPtr(main) > 0);
        std.debug.assert(Protocol.version == Wire.version);
        return .{ .executor = try .init(allocator, .{ .ui = .{}, .arena_reset_mode = .retain_capacity }), .main = main };
    }

    pub fn deinit(self: *Guest) void {
        std.debug.assert(self.executor.generation < std.math.maxInt(u64));
        std.debug.assert(@intFromPtr(self.main) > 0);
        self.executor.deinit();
    }

    pub fn execute(self: *Guest, request: *const FrameProtocol.Request) !FrameProtocol.Response {
        std.debug.assert(@intFromPtr(self.main) > 0);
        std.debug.assert(request.frame.content_scale > 0);
        std.debug.assert(request.state_scope > 0);
        self.executor.setStateScope(request.state_scope);
        try self.executor.loadState(request.state);
        self.executor.beginDependencyCollection();
        var collection_active = true;
        defer {
            if (collection_active) self.executor.cancelDependencyCollection();
        }
        var context = try self.executor.beginFrame(request.frame);
        defer context.deinit();
        const root: ui.component.Rect = .{
            .key = .str("knots.module.root"),
            .width = .fixed(@floatFromInt(request.frame.logical_extent.width)),
            .height = .fixed(@floatFromInt(request.frame.logical_extent.height)),
            .padding = .init(12, 12, 12, 12),
            .dir = .column,
            .overflow = .scroll,
            .style = .{ .color = .elevated },
        };
        _ = try root.open(&context);
        self.main(&context) catch |err| {
            self.executor.cancelDependencyCollection();
            collection_active = false;
            return err;
        };
        try root.close(&context);
        const dependencies = self.executor.endDependencyCollection();
        collection_active = false;
        const output = try self.executor.endFrame(&context);
        return .{
            .contribution = .{ .packet = output.packet },
            .state = try self.executor.stateValues(),
            .dependencies = dependencies,
            .effects = .{
                .cursor_shape = output.cursor_shape,
                .capture_pointer = output.capture_pointer,
                .capture_keyboard = output.capture_keyboard,
                .text_input = output.text_input,
                .redraw = output.redraw,
                .close = output.close,
                .clipboard_write = output.clipboard_write,
            },
        };
    }
};

test {
    _ = Wire;
    _ = Status;
    _ = FrameProtocol;
    _ = Panels;
}

test "guest reports state reads as dependencies" {
    const Main = struct {
        fn render(frame: *ui.Frame) !void {
            _ = try frame.bindState(u32, "guest.counter", 0);
        }
    };
    var guest = try Guest.init(std.testing.allocator, &Main.render);
    defer guest.deinit();
    const request: FrameProtocol.Request = .{
        .frame = .{
            .input = .{ .pos = .{ -1, -1 } },
            .now_ms = 0,
            .delta_ns = 0,
            .logical_extent = .{ .width = 100, .height = 100 },
            .physical_extent = .{ .width = 100, .height = 100 },
            .content_scale = 1,
        },
        .state_scope = 1,
    };
    const response = try guest.execute(&request);
    const counter_key = ui.StateBridge.key("guest.counter");
    var found_counter = false;
    for (response.dependencies) |dependency| {
        if (dependency.domain == 0) {
            if (dependency.key == counter_key) found_counter = true;
        }
    }
    try std.testing.expect(found_counter);
}
