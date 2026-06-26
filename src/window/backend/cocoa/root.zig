const std = @import("std");
const objc = @import("objc");
const gpu = @import("gpu");
const window = @import("window");
const ak = @import("appkit.zig");
const classes = @import("classes.zig");

const c = ak.c;

var classes_registered: bool = false;
var KnotsView: objc.Class = undefined;
var KnotsDelegate: objc.Class = undefined;

pub const Backend = struct {
    ns_window: objc.Object,
    ns_view: objc.Object,
    delegate: objc.Object,
    should_close: bool = false,
    cursor_visible: bool = true,
    cursor_shape: window.CursorShape = .default,
    display_mode: window.DisplayMode = .windowed,
    desired_display_mode: window.DisplayMode = .windowed,
    display_mode_transition: bool = false,
    frame_source: ?ak.CFRunLoopSourceRef = null,
    frame_requested: bool = false,

    // fixme: should be dynamic size
    drop_paths_buf: [64][1024]u8 = undefined,
    drop_slices: [64][]const u8 = undefined,

    const Self = @This();

    pub fn deinit(self: *const Self) void {
        if (self.frame_source) |source| {
            ak.CFRunLoopSourceInvalidate(source);
            ak.CFRelease(source);
        }
        self.ns_window.msgSend(void, "close", .{});
    }

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        const owner_value = ak.wrapPointer(owner);
        self.ns_view.setInstanceVariable(ak.IVAR_OWNER, owner_value);
        self.delegate.setInstanceVariable(ak.IVAR_OWNER, owner_value);
        self.ns_window.msgSend(void, "makeFirstResponder:", .{self.ns_view});

        var context: ak.CFRunLoopSourceContext = .{
            .version = 0,
            .info = owner,
            .retain = null,
            .release = null,
            .copy_description = null,
            .equal = null,
            .hash = null,
            .schedule = null,
            .cancel = null,
            .perform = frameSourcePerform,
        };
        const source = ak.CFRunLoopSourceCreate(null, 0, &context) orelse @panic("failed to create frame run-loop source");
        ak.CFRunLoopAddSource(ak.CFRunLoopGetMain(), source, ak.kCFRunLoopCommonModes);
        self.frame_source = source;
    }

    pub fn pollEvents(_: *const Self, _: std.Io) void {
        drainEventQueue(ak.sharedApp());
    }

    pub fn waitEvents(self: *const Self, io: std.Io) void {
        const NSApp = ak.sharedApp();
        const NSDate = objc.getClass("NSDate").?;
        const distant_future = NSDate.msgSend(objc.Object, "distantFuture", .{});
        const event = NSApp.msgSend(
            objc.Object,
            "nextEventMatchingMask:untilDate:inMode:dequeue:",
            .{ ak.NSEventMaskAny, distant_future, ak.defaultRunLoopMode(), ak.boolParam(true) },
        );
        if (event.value != null) NSApp.msgSend(void, "sendEvent:", .{event});
        self.pollEvents(io);
    }

    pub fn postEmptyEvent(_: *const Self) void {
        const NSApp = ak.sharedApp();
        const NSEvent = objc.getClass("NSEvent").?;
        const zero = ak.NSPoint{ .x = 0, .y = 0 };
        const event = NSEvent.msgSend(
            objc.Object,
            "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:",
            .{
                ak.NSEventTypeApplicationDefined,
                zero,
                @as(c_ulong, 0),
                @as(f64, 0),
                @as(c_long, 0),
                @as(c.id, null),
                @as(c_short, 0),
                @as(c_long, 0),
                @as(c_long, 0),
            },
        );
        NSApp.msgSend(void, "postEvent:atStart:", .{ event, ak.boolParam(true) });
    }

    pub fn requestFrame(self: *Self, owner: *window.Window) void {
        if (self.frame_requested or !owner.isOpen()) return;
        const source = self.frame_source orelse return;
        self.frame_requested = true;
        ak.CFRunLoopSourceSignal(source);
        ak.CFRunLoopWakeUp(ak.CFRunLoopGetMain());
    }

    pub fn isOpen(self: *const Self) bool {
        return !self.should_close;
    }

    pub fn close(self: *Self) void {
        self.should_close = true;
    }

    pub fn getSize(self: *const Self) window.Size {
        const view_frame = self.ns_view.msgSend(ak.NSRect, "frame", .{});
        return .{
            .width = @intFromFloat(@round(view_frame.size.width)),
            .height = @intFromFloat(@round(view_frame.size.height)),
        };
    }

    pub fn getFramebufferSize(self: *const Self) window.Size {
        const view_frame = self.ns_view.msgSend(ak.NSRect, "frame", .{});
        const backing = self.ns_view.msgSend(ak.NSRect, "convertRectToBacking:", .{view_frame});
        return .{
            .width = @intFromFloat(@round(backing.size.width)),
            .height = @intFromFloat(@round(backing.size.height)),
        };
    }

    pub fn computeContentScale(self: *const Self) f32 {
        return @floatCast(self.ns_window.msgSend(f64, "backingScaleFactor", .{}));
    }

    pub fn getCursorPos(self: *const Self) [2]f64 {
        const point_in_window = self.ns_window.msgSend(ak.NSPoint, "mouseLocationOutsideOfEventStream", .{});
        const point = self.ns_view.msgSend(ak.NSPoint, "convertPoint:fromView:", .{ point_in_window, @as(c.id, null) });
        return .{ point.x, point.y };
    }

    pub fn getNativeHandle(self: *const Self, _: ?[:0]const u8) gpu.Context.WindowHandle {
        return .{ .macos = .{ .ns_window = @ptrCast(self.ns_window.value) } };
    }

    pub fn setCursorVisible(self: *Self, visible: bool) void {
        if (visible == self.cursor_visible) return;
        const NSCursor = objc.getClass("NSCursor").?;
        if (visible) {
            NSCursor.msgSend(void, "unhide", .{});
        } else {
            NSCursor.msgSend(void, "hide", .{});
        }
        self.cursor_visible = visible;
    }

    pub fn setCursorShape(self: *Self, shape: window.CursorShape) void {
        if (self.cursor_shape == shape) return;
        self.cursor_shape = shape;
        const NSCursor = objc.getClass("NSCursor").?;
        const cursor = switch (shape) {
            .default => NSCursor.msgSend(objc.Object, "arrowCursor", .{}),
            .text => NSCursor.msgSend(objc.Object, "IBeamCursor", .{}),
            .pointer => NSCursor.msgSend(objc.Object, "pointingHandCursor", .{}),
            .crosshair => NSCursor.msgSend(objc.Object, "crosshairCursor", .{}),
            .move => NSCursor.msgSend(objc.Object, "openHandCursor", .{}),
            .resize_horizontal => NSCursor.msgSend(objc.Object, "resizeLeftRightCursor", .{}),
            .resize_vertical => NSCursor.msgSend(objc.Object, "resizeUpDownCursor", .{}),
            .resize_diagonal_nw_se => NSCursor.msgSend(objc.Object, "resizeNorthwestSoutheastCursor", .{}),
            .resize_diagonal_ne_sw => NSCursor.msgSend(objc.Object, "resizeNortheastSouthwestCursor", .{}),
            .not_allowed => NSCursor.msgSend(objc.Object, "operationNotAllowedCursor", .{}),
        };
        cursor.msgSend(void, "set", .{});
    }

    pub fn setTitle(self: *Self, title: []const u8) !void {
        self.ns_window.msgSend(void, "setTitle:", .{ak.nsstring(title)});
    }

    pub fn setDisplayMode(self: *Self, mode: window.DisplayMode) bool {
        self.desired_display_mode = mode;
        self.reconcileDisplayMode();
        return true;
    }

    pub fn reconcileDisplayMode(self: *Self) void {
        if (self.display_mode_transition or self.display_mode == self.desired_display_mode) return;
        self.display_mode_transition = true;
        self.ns_window.msgSend(void, "toggleFullScreen:", .{@as(c.id, null)});
    }

    pub fn getDisplayMode(self: *const Self) window.DisplayMode {
        return self.display_mode;
    }

    pub fn consumeResize(self: *Self, owner: *window.Window) ?window.ResizeEvent {
        if (!owner.resized) return null;
        owner.resized = false;
        return .{
            .logical = self.getSize(),
            .physical = self.getFramebufferSize(),
            .content_scale = self.computeContentScale(),
        };
    }

    pub fn consumeDrops(self: *Self, _: *window.Window, allocator: std.mem.Allocator, n: usize) ![][]const u8 {
        const out = try allocator.alloc([]const u8, n);
        errdefer allocator.free(out);
        for (0..n) |i| out[i] = try allocator.dupe(u8, self.drop_slices[i]);
        return out;
    }

    pub fn getClipboardText(_: *Self, allocator: std.mem.Allocator) !?[]u8 {
        const NSPasteboard = objc.getClass("NSPasteboard").?;
        const pasteboard = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
        if (pasteboard.value == null) return null;

        const str = pasteboard.msgSend(objc.Object, "stringForType:", .{objc.Object{ .value = ak.NSPasteboardTypeString }});
        if (str.value == null) return null;

        const utf8 = str.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
        return try allocator.dupe(u8, std.mem.sliceTo(utf8, 0));
    }

    pub fn setClipboardText(_: *Self, _: std.mem.Allocator, text: []const u8) !bool {
        const NSPasteboard = objc.getClass("NSPasteboard").?;
        const pasteboard = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
        if (pasteboard.value == null) return false;

        const NSString = objc.getClass("NSString").?;
        const str = NSString
            .msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithBytes:length:encoding:", .{
            text.ptr,
            @as(c_ulong, @intCast(text.len)),
            ak.NSUTF8StringEncoding,
        });
        if (str.value == null) return false;
        defer str.msgSend(void, "release", .{});

        pasteboard.msgSend(void, "clearContents", .{});
        return pasteboard.msgSend(bool, "setString:forType:", .{ str, objc.Object{ .value = ak.NSPasteboardTypeString } });
    }
};

pub fn init(_: std.Io, _: std.mem.Allocator, cfg: window.Config) !Backend {
    if (!classes_registered) {
        const registered = try classes.registerClasses();
        KnotsView = registered.view;
        KnotsDelegate = registered.delegate;
        classes_registered = true;
    }

    const NSApp = ak.sharedApp();
    NSApp.msgSend(void, "setActivationPolicy:", .{ak.NSApplicationActivationPolicyRegular});
    NSApp.msgSend(void, "finishLaunching", .{});

    const NSWindowClass = objc.getClass("NSWindow").?;
    const style: c_ulong = ak.NSWindowStyleMaskTitled | ak.NSWindowStyleMaskClosable |
        ak.NSWindowStyleMaskMiniaturizable | (if (cfg.resizable) ak.NSWindowStyleMaskResizable else 0);
    const frame = ak.NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(cfg.width), .height = @floatFromInt(cfg.height) },
    };
    const ns_window = NSWindowClass
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(
        objc.Object,
        "initWithContentRect:styleMask:backing:defer:",
        .{ frame, style, ak.NSBackingStoreBuffered, ak.boolParam(false) },
    );
    ns_window.msgSend(void, "setTitle:", .{ak.nsstring(cfg.title)});
    if (cfg.min_size) |size| ns_window.msgSend(void, "setContentMinSize:", .{ak.NSSize{
        .width = @floatFromInt(size.width),
        .height = @floatFromInt(size.height),
    }});
    if (cfg.max_size) |size| ns_window.msgSend(void, "setContentMaxSize:", .{ak.NSSize{
        .width = @floatFromInt(size.width),
        .height = @floatFromInt(size.height),
    }});
    ns_window.msgSend(void, "setReleasedWhenClosed:", .{ak.boolParam(false)});
    ns_window.msgSend(void, "setAcceptsMouseMovedEvents:", .{ak.boolParam(true)});
    ns_window.msgSend(void, "center", .{});

    const view = KnotsView
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
    ns_window.msgSend(void, "setContentView:", .{view});

    const NSArray = objc.getClass("NSArray").?;
    const drag_types = NSArray.msgSend(objc.Object, "arrayWithObject:", .{objc.Object{ .value = ak.NSPasteboardTypeFileURL }});
    view.msgSend(void, "registerForDraggedTypes:", .{drag_types});

    const delegate = KnotsDelegate
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    ns_window.msgSend(void, "setDelegate:", .{delegate});

    NSApp.msgSend(void, "activateIgnoringOtherApps:", .{ak.boolParam(true)});
    ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(c.id, null)});

    drainEventQueue(NSApp);

    return .{
        .ns_window = ns_window,
        .ns_view = view,
        .delegate = delegate,
    };
}

fn frameSourcePerform(info: ?*anyopaque) callconv(.c) void {
    const owner: *window.Window = @ptrCast(@alignCast(info orelse return));
    owner.backend.frame_requested = false;
    if (owner.isOpen()) owner.stepFrame();
}

fn drainEventQueue(NSApp: objc.Object) void {
    const NSDate = objc.getClass("NSDate").?;
    const distant_past = NSDate.msgSend(objc.Object, "distantPast", .{});
    while (true) {
        const event = NSApp.msgSend(
            objc.Object,
            "nextEventMatchingMask:untilDate:inMode:dequeue:",
            .{ ak.NSEventMaskAny, distant_past, ak.defaultRunLoopMode(), ak.boolParam(true) },
        );
        if (event.value == null) break;
        NSApp.msgSend(void, "sendEvent:", .{event});
    }
}
