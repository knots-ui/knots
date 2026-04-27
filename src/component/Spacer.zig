const App = @import("knots").App;
const UI = @import("ui").UI;
const Element = @import("layout").Element;

width: Element.sizing.Axis = .fixed(0),
height: Element.sizing.Axis = .fixed(0),
key: UI.Key,

const Spacer = @This();

pub fn open(self: *const Spacer, app: *App) !Element.Id {
    return try app.ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
    }, .none);
}

pub fn close(_: *const Spacer, app: *App) !void {
    app.ui.close();
}
