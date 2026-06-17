const App = @import("knots").App;
const Element = @import("layout").Element;
const ui_mod = @import("ui");

const Color = ui_mod.Color;
const Key = ui_mod.Key;
const Style = ui_mod.Style;

pub const CloseReason = enum {
    escape,
    backdrop,
};

is_open: *bool,
key: Key,
onClose: ?*const fn (*App, CloseReason) anyerror!void = null,

close_on_escape: bool = true,
close_on_backdrop_press: bool = true,
z_index: u8 = 200,
margin: f32 = 24,

width: Element.sizing.Axis = .{ .kind = .fit, .max = 640 },
height: Element.sizing.Axis = .fit(),
padding: Element.Padding = .init(16, 16, 16, 16),
gap: f32 = 0,
dir: Element.Direction = .column,
panel_style: Style = .{ .color = .elevated, .corner_radius = .md, .border_color = .toned, .border_width = .all(1) },
backdrop_color: Color.Input = .{ .color = .{ .value = .{ 0, 0, 0, 0.45 } } },

const Dialog = @This();

const BACKDROP_INDEX: usize = 1;
const PANEL_INDEX: usize = 2;

pub fn open(self: *const Dialog, app: *App) !Element.Id {
    if (!self.is_open.*) return Element.INVALID_ID;

    const ui = &app.ui;
    const size = app.window.getSize();
    const viewport_w: f32 = @floatFromInt(size.width);
    const viewport_h: f32 = @floatFromInt(size.height);
    const panel_max_w = @max(0, viewport_w - self.margin * 2);
    const panel_max_h = @max(0, viewport_h - self.margin * 2);

    const root_id = try ui.openRoot(self.key, 0, 0, .{
        .width = .fixed(viewport_w),
        .height = .fixed(viewport_h),
        .direction = .layer,
        .alignment = .center,
        .justify = .center,
        .z_index = self.z_index,
    }, .none);
    try ui.beginInputScope(root_id, .modal);

    _ = try ui.open(self.key.indexed(BACKDROP_INDEX), .{
        .width = .grow(),
        .height = .grow(),
        .position = .absolute,
        .interactive = true,
    }, .{ .rect = .{
        .color = self.backdrop_color.resolve(&ui.theme),
        .corner_radius = .zero,
        .border_width = .zero,
        .border_color = .{ 0, 0, 0, 0 },
    } });
    ui.close();

    const panel_id = try ui.open(self.key.indexed(PANEL_INDEX), .{
        .width = clampAxisToMax(self.width, panel_max_w),
        .height = clampAxisToMax(self.height, panel_max_h),
        .direction = self.dir,
        .padding = self.padding,
        .gap = self.gap,
        .overflow = .scroll_y,
        .interactive = true,
    }, .{ .rect = self.panel_style.toRect(&ui.theme) });
    try ui.setAccessibility(panel_id, .{
        .role = .dialog,
        .state = .{ .expanded = true },
    });

    return root_id;
}

pub fn close(self: *const Dialog, app: *App) !void {
    const ui = &app.ui;
    const root_id = self.key.hash();
    if (ui.layout_ctx.slotForId(root_id) == null) return;

    if (ui.isActiveScope(root_id)) {
        const backdrop_id = self.key.indexed(BACKDROP_INDEX).hash();
        if (self.close_on_backdrop_press and ui.leftClicked(backdrop_id)) {
            try self.requestClose(app, .backdrop);
        } else if (self.close_on_escape and ui.input.containsKey(.escape)) {
            try self.requestClose(app, .escape);
            ui.input.consumeKeyboard();
        }
    }

    if (!self.is_open.*) ui.cancelInputScope(root_id);

    ui.close();
    ui.endInputScope(root_id);
    ui.close();
}

fn requestClose(self: *const Dialog, app: *App, reason: CloseReason) !void {
    if (!self.is_open.*) return;
    self.is_open.* = false;
    if (self.onClose) |cb| try cb(app, reason);
    try app.signal(.redraw);
}

fn clampAxisToMax(axis: Element.sizing.Axis, max_size: f32) Element.sizing.Axis {
    var out = axis;
    out.min = @min(out.min, max_size);
    out.max = @min(out.max, max_size);
    if (out.max < out.min) out.max = out.min;
    return out;
}
