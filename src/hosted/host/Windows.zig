const std = @import("std");
const window = @import("window");
const gpu = @import("gpu_impl");
const abi = @import("abi");
const Gpu = @import("Gpu.zig");
const Reply = @import("Reply.zig");

const Windows = @This();
const log = std.log.scoped(.dev_host);

pub const Entry = struct {
    windows: *Windows,
    handle: abi.Window,
    window: window.Window,
    surface: ?*gpu.Surface = null,
    title: []u8,

    pub fn metrics(entry: *Entry) abi.Metrics {
        return .{ .logical = entry.window.getSize(), .physical = entry.window.getFramebufferSize(), .content_scale = entry.window.getContentScale() };
    }

    fn step(context: *anyopaque) void {
        const entry: *Entry = @ptrCast(@alignCast(context));
        entry.windows.on_frame.run(entry.windows.on_frame.context, entry);
    }
};

gpa: std.mem.Allocator,
io: std.Io,
entries: std.ArrayList(?*Entry) = .empty,
opened: u32 = 0,
on_frame: struct { context: *anyopaque, run: *const fn (*anyopaque, *Entry) void },

pub fn deinit(self: *Windows, device: *Gpu) void {
    for (self.entries.items) |slot| if (slot) |entry| self.destroy(entry, device);
    self.entries.deinit(self.gpa);
}

pub fn get(self: *Windows, handle: abi.Window) !*Entry {
    const index = @backingInt(handle);
    if (index >= self.entries.items.len) return error.WindowUnavailable;
    return self.entries.items[index] orelse error.WindowUnavailable;
}

pub fn main(self: *Windows) ?*Entry {
    if (self.entries.items.len == 0) return null;
    return self.entries.items[0];
}

pub fn closeUnopened(self: *Windows, device: *Gpu) void {
    for (self.entries.items[@min(self.opened, self.entries.items.len)..]) |*slot| if (slot.*) |entry| {
        slot.* = null;
        self.destroy(entry, device);
    };
}

pub fn call(self: *Windows, request: abi.WindowCall, reply: *Reply) !void {
    switch (request) {
        inline else => |args, tag| try reply.ok(abi.WindowCall.Result(tag), try self.answer(tag, args)),
    }
}

fn answer(self: *Windows, comptime tag: std.meta.Tag(abi.WindowCall), args: @FieldType(abi.WindowCall, @tagName(tag))) !abi.WindowCall.Result(tag) {
    switch (tag) {
        .open => return self.open(args),
        .set_title => try self.setTitle(try self.get(args[0]), args[1]),
        .set_display_mode => return (try self.get(args[0])).window.setDisplayMode(args[1]),
        .display_mode => return (try self.get(args)).window.getDisplayMode(),
        .request_paste => try (try self.get(args)).window.requestPaste(),
        .set_clipboard_text => return (try self.get(args[0])).window.setClipboardText(self.gpa, args[1]),
    }
}

pub fn command(self: *Windows, request: abi.WindowCommand, device: *Gpu) !void {
    switch (request) {
        .close => |handle| {
            const entry = try self.get(handle);
            log.info("event=window_closed id={d}", .{@backingInt(handle)});
            self.entries.items[@backingInt(handle)] = null;
            self.destroy(entry, device);
        },
        .request_frame => |handle| (try self.get(handle)).window.requestFrame(),
        .set_cursor_visible => |args| (try self.get(args[0])).window.setCursorVisible(args[1]),
        .set_cursor_shape => |args| (try self.get(args[0])).window.setCursorShape(args[1]),
    }
}

fn open(self: *Windows, desc: abi.Open) !abi.Opened {
    const handle: abi.Window = @fromBackingInt(self.opened);
    if (self.get(handle)) |entry| {
        self.opened += 1;
        try self.setTitle(entry, desc.title);
        log.info("event=window_reopened id={d}", .{self.opened - 1});
        return .{ .window = handle, .metrics = entry.metrics() };
    } else |_| {}

    const entry = try self.gpa.create(Entry);
    errdefer self.gpa.destroy(entry);
    const title = try self.gpa.dupe(u8, desc.title);
    errdefer self.gpa.free(title);
    const cfg: window.Config = .{
        .width = desc.width,
        .height = desc.height,
        .title = title,
        .resizable = desc.resizable,
        .min_size = desc.min_size,
        .max_size = desc.max_size,
    };
    try self.entries.ensureTotalCapacity(self.gpa, self.opened + 1);
    entry.* = .{
        .windows = self,
        .handle = handle,
        .title = title,
        .window = try if (self.main()) |primary|
            window.Window.initSecondary(&primary.window, self.io, self.gpa, cfg)
        else
            window.Window.init(self.io, self.gpa, cfg),
    };
    entry.window.startCapture();
    entry.window.setFrameHandler(.{ .ctx = entry, .step = Entry.step });
    while (self.entries.items.len <= self.opened) self.entries.appendAssumeCapacity(null);
    self.entries.items[self.opened] = entry;
    self.opened += 1;
    log.info("event=window_opened id={d} title=\"{s}\"", .{ @backingInt(handle), desc.title });
    return .{ .window = handle, .metrics = entry.metrics() };
}

fn setTitle(self: *Windows, entry: *Entry, title: []const u8) !void {
    const copy = try self.gpa.dupe(u8, title);
    errdefer self.gpa.free(copy);
    try entry.window.setTitle(copy);
    self.gpa.free(entry.title);
    entry.title = copy;
}

fn destroy(self: *Windows, entry: *Entry, device: *Gpu) void {
    device.destroySurface(entry);
    entry.window.deinit();
    self.gpa.free(entry.title);
    self.gpa.destroy(entry);
}
