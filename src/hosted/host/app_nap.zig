//! App Nap would slow reloads while the editor is in front.

const builtin = @import("builtin");

pub fn disable() void {
    if (builtin.os.tag != .macos) return;
    const objc = @import("objc");
    const process = objc.getClass("NSProcessInfo") orelse return;
    const info = process.msgSend(objc.Object, "processInfo", .{});
    const string = objc.getClass("NSString") orelse return;
    const reason = string.msgSend(objc.Object, "stringWithUTF8String:", .{"knots dev host reloads on every save"});
    // NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical
    const options: u64 = (0x00FFFFFF & ~@as(u64, 1 << 20)) | 0xFF00000000;
    const activity = info.msgSend(objc.Object, "beginActivityWithOptions:reason:", .{ options, reason });
    // The activity lasts as long as the process.
    _ = activity.msgSend(objc.Object, "retain", .{});
}
