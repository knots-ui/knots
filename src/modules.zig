//! Public application facade. Build configuration selects module execution.
//! Compiled-in modules import this as `knots`, so it also has the portable API.
const knots = @import("knots");
const portable = @import("portable");
pub const App = knots.App;
pub const View = knots.View;
pub const Modules = @import("modules");
pub const debug = knots.debug;
pub const platform = knots.platform;
pub const web = knots.web;
pub const Frame = portable.Frame;
pub const component = portable.component;

comptime {
    for (@typeInfo(portable).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("src/modules.zig must export the portable declaration " ++ name);
    }
}
