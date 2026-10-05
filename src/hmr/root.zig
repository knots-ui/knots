//! Internal guest support. Applications use knots.Frame.

const std = @import("std");
const ui = @import("ui");
const input = @import("input");
const render = @import("render");

pub const protocol = @import("protocol.zig");
pub const wire = @import("wire.zig");
pub const panels = @import("panels.zig");
pub const transfer = @import("transfer.zig");

pub const Request = struct {
    frame: input.FrameInput,
    theme: ui.Theme,
};

pub const Effects = struct {
    cursor_shape: input.CursorShape = .default,
    capture_pointer: bool = false,
    capture_keyboard: bool = false,
    text_input: bool = false,
    redraw: bool = false,
    close: bool = false,
    clipboard_write: ?[]const u8 = null,
    theme: ?ui.Theme = null,
};

pub const Response = struct {
    packet: render.Packet,
    effects: Effects = .{},
};

pub const DecodedResponse = struct {
    packet: panels.Parts,
    effects: Effects = .{},
};

comptime {
    if (wire.fingerprint(DecodedResponse) != wire.fingerprint(Response))
        @compileError("Panels.Parts must match render.Packet");
}

/// A host loads a module only if their frame encodings match. An edit to
/// knots can change the encoding, and the host then needs a restart.
pub const fingerprint = wire.fingerprint(struct { request: Request, response: Response });

pub const Guest = struct {
    executor: ui.Context,
    main: *const fn (*ui.Frame) anyerror!void,

    pub fn init(allocator: std.mem.Allocator, main: *const fn (*ui.Frame) anyerror!void) !Guest {
        return .{ .executor = try .init(allocator, .{}), .main = main };
    }

    pub fn deinit(self: *Guest) void {
        self.executor.deinit();
    }

    pub fn execute(self: *Guest, request: *const Request) !Response {
        self.executor.ui.theme = request.theme;
        var context = try self.executor.beginFrame(request.frame);
        defer context.deinit();

        const root: ui.component.Rect = .{
            .key = .str("knots.module.root"),
            .style = &.{
                .width = .fixed(@floatFromInt(request.frame.logical_extent.width)),
                .height = .fixed(@floatFromInt(request.frame.logical_extent.height)),
                .padding = .all(12),
                .direction = .column,
                .overflow = .scroll,
                .background = .elevated,
            },
        };
        _ = try root.open(&context);
        try self.main(&context);
        try root.close(&context);

        const output = try self.executor.endFrame(&context);
        const theme_changed = !std.meta.eql(self.executor.ui.theme, request.theme);

        return .{
            .packet = output.packet,
            .effects = .{
                .cursor_shape = output.cursor_shape,
                .capture_pointer = output.capture_pointer,
                .capture_keyboard = output.capture_keyboard,
                .text_input = output.text_input,
                .redraw = output.redraw,
                .close = output.close,
                .clipboard_write = output.clipboard_write,
                .theme = if (theme_changed) self.executor.ui.theme else null,
            },
        };
    }
};

test {
    _ = @import("changes.zig");
    _ = @import("command.zig");
    _ = @import("diagnostics.zig");
    _ = @import("graph.zig");
    _ = wire;
    _ = panels;
    _ = transfer;
}

const test_frame: input.FrameInput = .{
    .input = .{ .pos = .{ -1, -1 } },
    .now_ms = 0,
    .delta_ns = 0,
    .logical_extent = .{ .width = 100, .height = 100 },
    .physical_extent = .{ .width = 100, .height = 100 },
    .content_scale = 1,
};

test "guest reports theme changes as an effect" {
    const Main = struct {
        fn render(frame: *ui.Frame) !void {
            frame.ui().theme = ui.Theme.light;
        }
    };
    var guest = try Guest.init(std.testing.allocator, &Main.render);
    defer guest.deinit();

    var request: Request = .{ .frame = test_frame, .theme = ui.Theme.dark };
    const changed = try guest.execute(&request);
    try std.testing.expect(std.meta.eql(ui.Theme.light, changed.effects.theme.?));

    request.theme = ui.Theme.light;
    const unchanged = try guest.execute(&request);
    try std.testing.expect(unchanged.effects.theme == null);
}

test "a guest frame survives the wire in both directions" {
    const Main = struct {
        fn render(frame: *ui.Frame) !void {
            try frame.e(ui.component.Text{ .content = "wire", .key = .str("text") });
        }
    };
    var guest = try Guest.init(std.testing.allocator, &Main.render);
    defer guest.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var request_bytes: std.ArrayList(u8) = .empty;
    try wire.encode(allocator, &request_bytes, Request{ .frame = test_frame, .theme = ui.Theme.dark });
    const request = try wire.decode(Request, allocator, request_bytes.items);
    const response = try guest.execute(&request);

    var response_bytes: std.ArrayList(u8) = .empty;
    try wire.encode(allocator, &response_bytes, response);
    const decoded = try wire.decode(Response, allocator, response_bytes.items);

    try std.testing.expectEqual(response.packet.textInstances().len, decoded.packet.textInstances().len);
    try std.testing.expect(decoded.packet.textInstances().len > 0);
    try std.testing.expectEqual(response.packet.commands().len, decoded.packet.commands().len);
    try std.testing.expectEqualSlices(u8, response.packet.glyphAtlas().?.curve, decoded.packet.glyphAtlas().?.curve);
}
