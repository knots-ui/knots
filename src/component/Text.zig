const App = @import("knots").App;
const UI = @import("ui").UI;
const State = @import("ui").State;
const Color = @import("ui").Color;
const Element = @import("layout").Element;
const Size = @import("ui").Size;
const Key = @import("ui").Key;
const util = @import("util.zig");

width: Element.sizing.Axis = .fit(),
height: Element.sizing.Axis = .fit(),
size: Size.Input = .sm,
content: []const u8,
color: Color.Input = .text,
font: ?[]const u8 = null,
selectable: bool = true,
wrap: bool = false,
highlight_color: Color.Input = .primary,
key: Key,

const Text = @This();

const BODY_INDEX: usize = 1; // text decoration
const SPANS_BASE: usize = 16; // selection line overlays start here, one per line

pub fn open(self: *const Text, app: *App) !Element.Id {
    const ui = &app.ui;
    if (!self.selectable) {
        var decoration = try ui.textDecoration(self.content, self.size.resolve(), self.font, self.wrap);
        decoration.text.color = self.color.resolve(&ui.theme);
        return try ui.open(self.key, .{
            .width = self.width,
            .height = self.height,
        }, decoration);
    }

    return try ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
        .interactive = true,
    }, .none);
}

pub fn close(self: *const Text, app: *App) !void {
    const ui = &app.ui;
    if (!self.selectable) {
        ui.close();
        return;
    }

    const id = self.key.hash();
    const s = try ui.state.getOrCreate(.text_select, ui.allocator, id);

    if (ui.input.mouseButton(.left).released) s.dragging = false;

    const len: u32 = @intCast(self.content.len);
    const press_here = ui.input.mouseButton(.left).pressed and ui.hovering(id);
    const is_drag = ui.pressing(id) and ui.input.mouseButton(.left).down;
    const need_hit_test = (press_here or is_drag) and s.box.w() > 0 and s.box.h() > 0;
    const has_prior_selection = @min(s.anchor_byte, len) != @min(s.cursor_byte, len);

    if (need_hit_test or has_prior_selection) {
        try self.closeSlow(ui, s, need_hit_test, press_here);
        return;
    }

    var deco = try ui.textDecoration(self.content, self.size.resolve(), self.font, self.wrap);
    deco.text.color = self.color.resolve(&ui.theme);
    const inner_w: Element.sizing.Axis = if (self.wrap) .grow() else .fit();
    _ = try ui.open(self.key.indexed(BODY_INDEX), .{ .width = inner_w, .height = .fit() }, deco);
    ui.close();

    ui.close();
}

fn closeSlow(self: *const Text, ui: *UI, s: *State.TextSelect, need_hit_test: bool, press_here: bool) !void {
    const scale = ui.content_scale;
    const face = try ui.font.getFace(self.font);
    const size = self.size.resolve();
    const wrap_px: f32 = if (self.wrap) @max(0, s.box.w() * scale) else 0;
    const shaped = try face.shapeWrapped(self.content, size.value * scale, wrap_px);
    const line_h = shaped.line_height / scale;

    if (need_hit_test) {
        const mx: f32 = @floatCast(ui.input.mouse_pos[0]);
        const my: f32 = @floatCast(ui.input.mouse_pos[1]);
        const local: util.Pos = .{ .x = mx - s.box.x(), .y = my - s.box.y() };
        const byte = util.byteAtPos(shaped, local, scale);
        if (press_here) {
            s.dragging = true;
            s.anchor_byte = byte;
            s.cursor_byte = byte;
        } else if (s.dragging) {
            s.cursor_byte = byte;
        }
    }

    const len: u32 = @intCast(self.content.len);
    const anchor = @min(s.anchor_byte, len);
    const cursor = @min(s.cursor_byte, len);
    const sel_lo = @min(anchor, cursor);
    const sel_hi = @max(anchor, cursor);

    if (sel_lo != sel_hi) {
        ui.state.selection_text = self.content[sel_lo..sel_hi];

        var hc = self.highlight_color.resolve(&ui.theme);
        hc[3] = 0.4;

        const spans = try util.lineSpansForRange(ui.allocator, shaped, sel_lo, sel_hi, scale);
        defer ui.allocator.free(spans);

        for (spans, 0..) |sp, i| {
            _ = try ui.openAt(self.key.indexed(SPANS_BASE + i), sp.x, sp.y, sp.w, line_h, .{}, .{ .rect = .{ .color = hc } });
            ui.close();
        }
    }

    var deco = try ui.textDecoration(self.content, size, self.font, self.wrap);
    deco.text.color = self.color.resolve(&ui.theme);
    const inner_w: Element.sizing.Axis = if (self.wrap) .grow() else .fit();
    _ = try ui.open(self.key.indexed(BODY_INDEX), .{ .width = inner_w, .height = .fit() }, deco);
    ui.close();

    ui.close();
}
