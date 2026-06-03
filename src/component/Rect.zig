const App = @import("knots").App;
const Style = @import("ui").Style;
const Key = @import("ui").Key;
const Decoration = @import("ui").Decoration;
const Element = @import("layout").Element;
const Grid = @import("layout").Grid;

pub const GridTrack = Grid.Track;
pub const GridTemplate = Grid.Template;
pub const GridPlacement = Grid.Placement;

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
key: Key,

/// Set on grid containers (`dir = .grid`) to declare row/column tracks.
grid_template: ?GridTemplate = null,
/// Set on direct children of a grid to declare cell placement.
grid_placement: ?GridPlacement = null,

const Rect = @This();

pub fn open(self: *const Rect, app: *App) !Element.Id {
    const rect = self.style.toRect(&app.ui.theme);
    const needs_clip_shape = self.overflow != .visible and !rect.corner_radius.isZero();
    const decoration: Decoration = if (self.style.hasDecoration() or needs_clip_shape)
        .{ .rect = rect }
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
        .grid_template = self.grid_template,
        .grid_placement = self.grid_placement,
    }, decoration);
}

pub fn close(_: *const Rect, app: *App) !void {
    app.ui.close();
}
