const std = @import("std");
const input_types = @import("input");
const gpu = @import("gpu");
const window = @import("window");
const wire = @import("wire");
const guest = @import("hosted");
const buffer = &@import("wasm_buffer").bytes;
const drop_paths = @import("window_drop_paths");
const abi = guest.abi;

const windows_max = 32;
var windows: [windows_max]?*Backend = @splat(null);

export fn knots_hosted_frame(handle: u32) void {
    if (handle >= windows_max) return;
    const self = windows[handle] orelse return;
    const owner = self.owner orelse return;
    var arena = std.heap.ArenaAllocator.init(guest.allocator);
    defer arena.deinit();
    const frame = wire.decode(abi.Input, arena.allocator(), buffer.items) catch |err|
        return std.log.err("hosted: invalid frame input: {t}", .{err});
    self.metrics = frame.metrics;
    owner.setInput(frame.input);
    if (frame.resized) owner.markResized();
    if (frame.closed) owner.markClosed();
    if (frame.paste) |text| owner.pushPaste(text);
    // The paths live as long as the frame.
    self.drops = frame.drops;
    defer self.drops = &.{};
    owner.markDropped(frame.drops.len);
    owner.stepFrame();
}

fn call(comptime tag: std.meta.Tag(abi.WindowCall), args: @FieldType(abi.WindowCall, @tagName(tag))) abi.Error!abi.WindowCall.Result(tag) {
    return guest.call(abi.WindowCall.Result(tag), .{ .window = @unionInit(abi.WindowCall, @tagName(tag), args) });
}

pub const Backend = struct {
    handle: abi.Window,
    metrics: abi.Metrics,
    owner: ?*window.Window = null,
    open: bool = true,
    drops: []const []const u8 = &.{},

    const Self = @This();

    pub fn deinit(self: *Self) void {
        windows[@backingInt(self.handle)] = null;
        guest.queue(.{ .window = .{ .close = self.handle } });
    }

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        self.owner = owner;
        windows[@backingInt(self.handle)] = self;
    }

    pub fn pollEvents(_: *const Self, _: std.Io) void {}
    pub fn waitEvents(_: *const Self, _: std.Io) void {}
    pub fn postEmptyEvent(_: *const Self) void {}

    pub fn requestFrame(self: *Self, _: *window.Window) void {
        guest.queue(.{ .window = .{ .request_frame = self.handle } });
    }

    pub fn isOpen(self: *const Self) bool {
        return self.open;
    }

    pub fn close(self: *Self) void {
        self.open = false;
    }

    pub fn getSize(self: *const Self) input_types.Size {
        return self.metrics.logical;
    }

    pub fn getFramebufferSize(self: *const Self) input_types.Size {
        return self.metrics.physical;
    }

    pub fn computeContentScale(self: *const Self) f32 {
        return self.metrics.content_scale;
    }

    pub fn getCursorPos(_: *const Self) [2]f64 {
        return .{ 0, 0 };
    }

    pub fn getNativeHandle(self: *const Self, _: ?[:0]const u8) gpu.Context.WindowHandle {
        return .{ .hosted = @backingInt(self.handle) };
    }

    pub fn setCursorVisible(self: *Self, visible: bool) void {
        guest.queue(.{ .window = .{ .set_cursor_visible = .{ self.handle, visible } } });
    }

    pub fn setCursorShape(self: *Self, shape: input_types.CursorShape) void {
        guest.queue(.{ .window = .{ .set_cursor_shape = .{ self.handle, shape } } });
    }

    pub fn setTitle(self: *Self, title: []const u8) !void {
        try call(.set_title, .{ self.handle, title });
    }

    pub fn setDisplayMode(self: *Self, mode: window.DisplayMode) bool {
        return call(.set_display_mode, .{ self.handle, mode }) catch false;
    }

    pub fn getDisplayMode(self: *const Self) window.DisplayMode {
        return call(.display_mode, self.handle) catch .windowed;
    }

    pub fn consumeResize(self: *Self, owner: *window.Window) ?window.ResizeEvent {
        if (!owner.resized) return null;
        owner.resized = false;
        return .{ .logical = self.metrics.logical, .physical = self.metrics.physical, .content_scale = self.metrics.content_scale };
    }

    pub fn consumeDrops(self: *Self, _: *window.Window, allocator: std.mem.Allocator, n: usize) ![][]const u8 {
        return drop_paths.copy(allocator, self.drops[0..@min(n, self.drops.len)]);
    }

    pub fn requestPaste(self: *Self, _: *window.Window) !void {
        try call(.request_paste, self.handle);
    }

    pub fn setClipboardText(self: *Self, _: std.mem.Allocator, text: []const u8) !bool {
        return call(.set_clipboard_text, .{ self.handle, text });
    }
};

pub fn init(_: std.Io, _: std.mem.Allocator, cfg: window.Config) !Backend {
    return open(cfg);
}

pub fn initSecondary(_: *const Backend, _: std.Io, _: std.mem.Allocator, cfg: window.Config) !Backend {
    return open(cfg);
}

fn open(cfg: window.Config) !Backend {
    const opened = try call(.open, .{
        .width = cfg.width,
        .height = cfg.height,
        .title = cfg.title,
        .resizable = cfg.resizable,
        .min_size = cfg.min_size,
        .max_size = cfg.max_size,
    });
    if (@backingInt(opened.window) >= windows_max) return error.WindowUnavailable;
    return .{ .handle = opened.window, .metrics = opened.metrics };
}
