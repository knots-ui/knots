const objc = @import("objc");

pub const c = objc.c;

pub const IVAR_OWNER: [:0]const u8 = "knots_owner";

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };
pub const NSRange = extern struct { location: c_ulong, length: c_ulong };

pub const NSWindowStyleMaskBorderless: c_ulong = 0;
pub const NSWindowStyleMaskTitled: c_ulong = 1 << 0;
pub const NSWindowStyleMaskClosable: c_ulong = 1 << 1;
pub const NSWindowStyleMaskMiniaturizable: c_ulong = 1 << 2;
pub const NSWindowStyleMaskResizable: c_ulong = 1 << 3;
pub const NSWindowStyleMaskFullScreen: c_ulong = 1 << 14;

pub const NSNormalWindowLevel: c_long = 0;
pub const NSMainMenuWindowLevel: c_long = 24;

pub const NSBackingStoreBuffered: c_ulong = 2;
pub const NSApplicationActivationPolicyRegular: c_long = 0;
pub const NSEventMaskAny: c_ulong = @import("std").math.maxInt(c_ulong);
pub const NSEventTypeApplicationDefined: c_ulong = 15;

pub const NSEventModifierFlagShift: c_ulong = 1 << 17;
pub const NSEventModifierFlagControl: c_ulong = 1 << 18;
pub const NSEventModifierFlagOption: c_ulong = 1 << 19;
pub const NSEventModifierFlagCommand: c_ulong = 1 << 20;

pub const NSDragOperationCopy: c_ulong = 1;
pub const NSUTF8StringEncoding: c_ulong = 4;

pub extern const NSDefaultRunLoopMode: c.id;
pub extern const NSPasteboardTypeFileURL: c.id;
pub extern const NSPasteboardTypeString: c.id;

pub const CFRunLoopSourceRef = *anyopaque;
pub const CFRunLoopSourceContext = extern struct {
    version: c_long,
    info: ?*anyopaque,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copy_description: ?*const anyopaque,
    equal: ?*const anyopaque,
    hash: ?*const anyopaque,
    schedule: ?*const anyopaque,
    cancel: ?*const anyopaque,
    perform: *const fn (?*anyopaque) callconv(.c) void,
};

pub extern const kCFRunLoopCommonModes: ?*const anyopaque;
pub extern fn CFRunLoopGetMain() *anyopaque;
pub extern fn CFRunLoopSourceCreate(allocator: ?*const anyopaque, order: c_long, context: *CFRunLoopSourceContext) ?CFRunLoopSourceRef;
pub extern fn CFRunLoopAddSource(run_loop: *anyopaque, source: CFRunLoopSourceRef, mode: ?*const anyopaque) void;
pub extern fn CFRunLoopSourceSignal(source: CFRunLoopSourceRef) void;
pub extern fn CFRunLoopSourceInvalidate(source: CFRunLoopSourceRef) void;
pub extern fn CFRunLoopWakeUp(run_loop: *anyopaque) void;
pub extern fn CFRelease(value: *const anyopaque) void;

pub fn boolParam(b: bool) c.BOOL {
    return switch (c.BOOL) {
        bool => b,
        i8 => @intFromBool(b),
        else => @compileError("unexpected BOOL type"),
    };
}

pub fn sharedApp() objc.Object {
    const NSApplication = objc.getClass("NSApplication").?;
    return NSApplication.msgSend(objc.Object, "sharedApplication", .{});
}

pub fn defaultRunLoopMode() objc.Object {
    return .{ .value = NSDefaultRunLoopMode };
}

pub fn nsstring(s: []const u8) objc.Object {
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithBytes:length:encoding:", .{ s.ptr, @as(c_ulong, @intCast(s.len)), NSUTF8StringEncoding });
}

pub fn wrapPointer(ptr: anytype) objc.Object {
    const NSValue = objc.getClass("NSValue").?;
    return NSValue.msgSend(objc.Object, "valueWithPointer:", .{@as(*const anyopaque, @ptrCast(ptr))});
}

const std = @import("std");
const Window = @import("window").Window;

pub fn unwrapOwner(self_id: c.id) ?*Window {
    const obj = objc.Object.fromId(self_id);
    const value = obj.getInstanceVariable(IVAR_OWNER);
    if (value.value == null) return null;
    const ptr = value.msgSend(?*anyopaque, "pointerValue", .{}) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn pushUtf8Chars(owner: *Window, slice: []const u8, comptime filter_function_keys: bool) void {
    var i: usize = 0;
    while (i < slice.len) {
        const len = std.unicode.utf8ByteSequenceLength(slice[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > slice.len) break;
        const cp = std.unicode.utf8Decode(slice[i..][0..len]) catch {
            i += len;
            continue;
        };
        i += len;
        if (cp < 0x20 or cp == 0x7F) continue;

        // 0xF700-0xF8FF is the NSFunctionKey range AppKit emits for arrow keys, F-keys, etc, those must stay out of the chars channel.
        if (filter_function_keys and cp >= 0xF700 and cp <= 0xF8FF) continue;
        owner.pushChar(cp);
    }
}
