const App = @import("knots").App;
const UI = @import("ui").UI;
const Element = @import("layout").Element;

texture_id: u32,
width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .grow(),
position: Element.Position = .static,
tint: [4]f32 = .{ 1, 1, 1, 1 },
key: UI.Key,

const Image = @This();

pub fn open(self: *const Image, app: *App) !Element.Id {
    return try app.ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
        .position = self.position,
        .overflow = .hidden,
    }, .{ .image = .{
        .texture_id = self.texture_id,
        .tint = self.tint,
    } });
}

pub fn close(_: *const Image, app: *App) !void {
    app.ui.close();
}
