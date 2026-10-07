pub const App = @import("App.zig");
pub const NativeAccessibility = if (@import("platform.zig").is_wasm) void else @import("native_accessibility");
pub const View = @import("View.zig");
pub const debug = @import("debug/root.zig");
pub const platform = @import("platform.zig");
pub const wasm = if (platform.is_wasm) @import("platform_impl") else struct {};

test {
    _ = debug.DevTools;
}
