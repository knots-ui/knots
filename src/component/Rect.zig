const App = @import("knots").App;
const UI = @import("ui").UI;
const Style = @import("ui").Style;
const Element = @import("layout").Element;

@"align": Element.Align = .start,
justify: Element.Justify = .start,
width: Element.sizing.Axis = .fit(),
height: Element.sizing.Axis = .fit(),
padding: Element.Padding = .init(0, 0, 0, 0),
dir: Element.Direction = .row,
overflow: Element.Overflow = .visible,
position: Element.Position = .static,
gap: f32 = 0,
style: Style = .{},
key: UI.Key,

const Rect = @This();

pub fn open(self: *const Rect, app: *App) !Element.Id {
    const decoration: @import("ui").UI.Decoration = if (self.style.hasDecoration())
        .{ .rect = self.style.toRect() }
    else
        .none;
    return try app.ui.open(self.key, .{
        .alignment = self.@"align",
        .justify = self.justify,
        .width = self.width,
        .height = self.height,
        .padding = self.padding,
        .overflow = self.overflow,
        .position = self.position,
        .direction = self.dir,
        .gap = self.gap,
    }, decoration);
}

pub fn close(_: *const Rect, app: *App) !void {
    app.ui.close();
}
