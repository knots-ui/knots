pub const App = @import("App.zig");
pub const NativeAccessibility = if (@import("platform.zig").is_browser_wasm) void else @import("native_accessibility");
pub const View = @import("View.zig");
pub const debug = @import("debug/root.zig");
pub const platform = @import("platform.zig");
pub const web = if (platform.is_browser_wasm) @import("browser_exports") else struct {};

test {
    _ = debug.DevTools;
}
