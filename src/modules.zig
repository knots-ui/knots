//! Public application facade. Build configuration selects module execution.
const knots = @import("knots");
pub const App = knots.App;
pub const View = knots.View;
pub const Modules = @import("modules");
pub const debug = knots.debug;
pub const platform = knots.platform;
pub const web = knots.web;
