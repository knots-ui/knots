const std = @import("std");

const App = @import("knots").App;
const UI = @import("ui").UI;
const State = @import("ui").State;
const Style = @import("ui").Style;
const Color = @import("ui").Color;
const Size = @import("ui").Size;
const Key = @import("ui").Key;
const Decoration = @import("ui").Decoration;

const Element = @import("layout").Element;
const util = @import("util.zig");
const edit = @import("text_edit.zig");

const BODY_INDEX: usize = 1; // text decoration
const CURSOR_INDEX: usize = 2; // cursor overlay
const SELECTION_BASE: usize = 16; // selection line overlays start here, one per line

width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .fit(),
size: Size.Input = .sm,
buf: *std.ArrayList(u8),
placeholder: []const u8 = "",
color: Color.Input = .text,
placeholder_color: Color.Input = .dimmed,
style: Style = .{ .color = .elevated, .border_color = .toned, .border_width = .all(1) },
hover_style: ?Style.Override = .{ .border_color = .dimmed },
focused_style: Style = .{ .color = .elevated, .border_color = .primary, .border_width = .all(1) },
padding: Element.Padding = .init(6, 10, 6, 10),
key: Key,

const TextInput = @This();

pub fn open(self: *const TextInput, app: *App) !Element.Id {
    const ui = &app.ui;
    const id = self.key.hash();
    const is_focused = ui.focused(id);

    if (is_focused) {
        const s = try ui.state.getOrCreate(.text_input, ui.allocator, id);
        try edit.processInputEarly(self.buf, app, s, false);
    }

    const is_hovered = ui.hovering(id);
    const current_style = if (is_focused)
        self.focused_style
    else if (is_hovered)
        if (self.hover_style) |hs| self.style.merge(hs) else self.style
    else
        self.style;

    var height = self.height;
    height.min = try ui.lineHeight(self.size.resolve(), null) + self.padding.top() + self.padding.bottom();

    const decoration: Decoration = if (current_style.hasDecoration())
        .{ .rect = current_style.toRect(&ui.theme) }
    else
        .none;
    return try ui.open(self.key, .{
        .width = self.width,
        .height = height,
        .overflow = .scroll_x,
        .interactive = true,
        .alignment = .center,
        .padding = self.padding,
    }, decoration);
}

pub fn close(self: *const TextInput, app: *App) !void {
    const ui = &app.ui;
    const id = self.key.hash();
    const is_focused = ui.focused(id);
    const items = self.buf.items;
    const resolved_color = self.color.resolve(&ui.theme);
    const size = self.size.resolve();

    const display, const color = if (!is_focused and items.len == 0)
        .{ self.placeholder, self.placeholder_color.resolve(&ui.theme) }
    else
        .{ items, resolved_color };

    if (is_focused) {
        const s = ui.state.get(.text_input, id).?;
        const scale = ui.content_scale;

        const face = try ui.font.getFace(null);
        const shaped = try face.shapeWrapped(items, size.value * scale, 0);
        const line_h = shaped.line_height / scale;

        try edit.processInputLate(self.buf, false, ui, s, shaped, line_h);
        ui.input.consumeKeyboard();

        const sel_lo = @min(s.cursor, s.sel_anchor);
        const sel_hi = @max(s.cursor, s.sel_anchor);
        const has_sel = sel_lo != sel_hi;

        if (has_sel) {
            const sel_color = blk: {
                const base: Color.Input = .primary;
                var c = base.resolve(&ui.theme);
                c[3] = 0.4;
                break :blk c;
            };
            const spans = try util.lineSpansForRange(ui.allocator, shaped, sel_lo, sel_hi, scale);
            defer ui.allocator.free(spans);
            for (spans, 0..) |sp, i| {
                _ = try ui.openAt(self.key.indexed(SELECTION_BASE + i), sp.x, sp.y, sp.w, line_h, .{}, .{ .rect = .{ .color = sel_color } });
                ui.close();
            }
        } else {
            const p = util.posAtByte(shaped, s.cursor, scale);
            _ = try ui.openAt(self.key.indexed(CURSOR_INDEX), p.x, p.y, 1, line_h, .{}, .{ .rect = .{ .color = resolved_color } });
            ui.close();
        }

        if (has_sel) ui.state.selection_text = items[sel_lo..sel_hi];
    }

    if (display.len > 0) {
        var deco = try ui.textDecoration(display, size, null, false);
        deco.text.color = color;
        _ = try ui.open(self.key.indexed(BODY_INDEX), .{ .width = .fit(), .height = .fit() }, deco);
        ui.close();
    }

    ui.close();
}
