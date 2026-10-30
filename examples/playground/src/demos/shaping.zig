const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const TextArea = ui.component.TextArea;
const Button = ui.component.Button;
const Checkbox = ui.component.Checkbox;
const SliderInput = ui.component.SliderInput;
const Feature = ui.Feature;
const TextSystem = ui.text.TextSystem;
const TextLayout = ui.text.TextLayout;

const Preset = struct { name: []const u8, text: []const u8 };

const presets = [_]Preset{
    .{ .name = "Code", .text = "if (a != b && c >= d) return x -> y; // => |> <=> ::= www 0xFF ..." },
    .{ .name = "Kerning", .text = "AVATAR WAVE Type To. LT Yo VA Wo P." },
    .{ .name = "Marks", .text = "e\u{301} a\u{308} n\u{303} o\u{328}\u{301} a\u{323}\u{302} \u{e9}" },
    .{ .name = "Emoji", .text = "\u{1F44D}\u{1F3FD} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F1F8}\u{1F1EA} \u{2764}\u{FE0F}" },
    .{ .name = "Scripts", .text = "Latin \u{395}\u{3BB}\u{3BB}\u{3B7}\u{3BD}\u{3B9}\u{3BA}\u{3AC} \u{41A}\u{438}\u{440}\u{438}\u{43B}\u{43B}\u{438}\u{446}\u{430} caf\u{e9}" },
    .{ .name = "Fractions", .text = "1/2 3/4 10/16 and 2\u{2044}3" },
};

/// Features HarfBuzz turns on by default for simple scripts, so their checkboxes start checked.
const default_on = [_]*const [4]u8{ "calt", "ccmp", "clig", "curs", "dist", "kern", "liga", "locl", "mark", "mkmk", "rclt", "rlig" };

/// Glyph cells shown in the inspector; longer texts are cut off with a count.
const cells_max = 160;
const toggle_columns = [_]Rect.GridTrack{ .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 } };
/// Inspector cells, also looked up to find the hovered glyph.
const cell_key = ui.Key.str("shaping.cell");
const preview_key = ui.Key.str("shaping.preview");

editor: std.ArrayList(u8) = .empty,
font: u16 = 1,
size: f32 = 0.35,
/// Feature tags of `tags_font` and whether each is on.
tags: []u32 = &.{},
enabled: []bool = &.{},
tags_font: ?u16 = null,

const Shaping = @This();

pub fn render(self: *Shaping, app: *knots.App, frame: *ui.Frame) !void {
    const system = &frame.ui().text_system;
    if (self.editor.items.len == 0) try self.editor.appendSlice(app.allocator, presets[0].text);
    try self.loadTags(app.allocator, system);

    const root = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .column, .gap = 10 } };
    _ = try root.open(frame);
    try self.renderControls(app.allocator, frame, system);
    try self.renderToggles(frame);
    try frame.e(TextArea{ .buf = &self.editor, .allocator = app.allocator, .key = .src(@src()), .style = &.{ .font = "jetbrains-mono", .width = .grow(), .height = .fixed(64) } });

    const deco: ui.Decoration.Text = .{
        .content = self.editor.items,
        .size = 12 + self.size * 60,
        .font = system.faces.items[self.font].name,
        .features = try self.featureOverrides(frame.arena()),
    };
    const layout = try frame.ui().styledTextLayout(&deco, 0);
    const hovered = try hoveredGlyph(frame, layout);
    try renderPreview(frame, &deco, layout, hovered);
    try renderInspector(frame, system, layout, hovered);
    try root.close(frame);
}

fn renderControls(self: *Shaping, allocator: std.mem.Allocator, frame: *ui.Frame, system: *TextSystem) !void {
    const row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .gap = 6, .@"align" = .center } };
    _ = try row.open(frame);
    for (presets, 0..) |preset, index| {
        if ((try frame.interact(Button{ .label = preset.name, .key = ui.Key.src(@src()).indexed(index), .style = &small_button })).clicked) {
            self.editor.clearRetainingCapacity();
            try self.editor.appendSlice(allocator, preset.text);
        }
    }
    try row.close(frame);

    const fonts = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .gap = 6, .@"align" = .center } };
    _ = try fonts.open(frame);
    for (system.faces.items, 0..) |face, index| {
        const style = if (index == self.font) &small_selected else &small_button;
        if ((try frame.interact(Button{ .label = face.name, .key = ui.Key.src(@src()).indexed(index), .style = style })).clicked) self.font = @intCast(index);
    }
    try frame.e(Text{ .content = try std.fmt.allocPrint(frame.arena(), "{d:.0} px", .{12 + self.size * 60}), .key = .src(@src()), .selectable = false, .style = &.{ .font_size = .xs, .foreground = .dimmed } });
    _ = try frame.interact(SliderInput{ .value = &self.size, .key = .src(@src()), .style = &.{ .width = .fixed(120) } });
    try fonts.close(frame);
}

/// One checkbox per feature the font defines, four to a row.
fn renderToggles(self: *Shaping, frame: *ui.Frame) !void {
    const rows = try frame.arena().alloc(Rect.GridTrack, (self.tags.len + toggle_columns.len - 1) / toggle_columns.len);
    @memset(rows, .{ .fixed = 22 });
    const grid = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .grid, .grid = .{ .cols = &toggle_columns, .rows = rows }, .gap = 4, .padding = .all(8), .background = .muted, .radius = .sm } };
    _ = try grid.open(frame);
    for (self.tags, 0..) |tag, index| {
        const cell = Rect{ .key = ui.Key.src(@src()).indexed(index), .style = &.{ .grid_cell = .{ .row = @intCast(index / toggle_columns.len), .col = @intCast(index % toggle_columns.len) } } };
        _ = try cell.open(frame);
        var name: [4]u8 = undefined;
        std.mem.writeInt(u32, &name, tag, .big);
        _ = try frame.interact(Checkbox{ .checked = &self.enabled[index], .label = try frame.arena().dupe(u8, &name), .key = ui.Key.src(@src()).indexed(index) });
        try cell.close(frame);
    }
    try grid.close(frame);
}

/// The rendered text, with the hovered glyph's source bytes highlighted.
fn renderPreview(frame: *ui.Frame, deco: *const ui.Decoration.Text, layout: *const TextLayout, hovered: ?u32) !void {
    var colors: []const ui.Decoration.ColorSpan = &.{};
    if (hovered) |index| {
        const bytes = layout.clusterBytes(index);
        const accent = frame.ui().parentContent().color(.primary, &frame.ui().theme);
        colors = try frame.arena().dupe(ui.Decoration.ColorSpan, &.{.{ .start = bytes[0], .end = bytes[1], .color = accent }});
    }
    try frame.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .padding = .all(12), .background = .elevated, .radius = .sm, .border_width = .all(1), .border_color = .toned, .overflow = .scroll_x } },
        .{Text{ .content = deco.content, .key = preview_key, .features = deco.features, .colors = colors, .selectable = false, .style = &.{ .font = deco.font, .font_size = .{ .px = deco.size } } }},
    });
}

/// One cell per glyph: the source it came from, its id, cluster and advance in font units,
/// the shaping face as the border tone, and break and concat safety as markers.
fn renderInspector(frame: *ui.Frame, system: *TextSystem, layout: *const TextLayout, hovered: ?u32) !void {
    const glyphs = layout.glyphs;
    const count = @min(glyphs.ids.len, cells_max);
    const arena = frame.arena();
    const strip = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .gap = 4, .padding = .all(8), .background = .muted, .radius = .sm, .overflow = .scroll_x } };
    _ = try strip.open(frame);
    var run_index: usize = 0;
    for (0..count) |index| {
        while (layout.runs[run_index].glyph_end <= index) run_index += 1;
        const run = layout.runs[run_index];
        const units = system.faceById(run.face).unitsPerEm() / run.size;
        const bytes = layout.clusterBytes(@intCast(index));
        const flags = glyphs.flags[index];
        const source = layout.text[bytes[0]..bytes[1]];
        const cell = Rect{ .key = cell_key.indexed(index), .interactive = true, .style = &.{
            .width = .fixed(70),
            .direction = .column,
            .gap = 2,
            .padding = .all(6),
            .radius = .sm,
            .background = if (hovered == @as(?u32, @intCast(index))) .toned else .elevated,
            .border_width = .edges(1, 1, 1, if (flags & ui.text.shape.shaper.unsafe_to_break != 0) 3 else 1),
            .border_color = faceTone(run.face),
        } };
        try frame.e(.{ cell, .{
            Text{ .content = if (std.mem.eql(u8, source, " ")) "space" else source, .key = ui.Key.src(@src()).indexed(index), .selectable = false, .style = &.{ .font = "jetbrains-mono", .font_size = .md } },
            Text{
                .content = try std.fmt.allocPrint(arena, "g {d}\ncl {d}\nadv {d:.0}", .{ glyphs.ids[index], glyphs.cluster[index], glyphs.advance[index] * units }),
                .key = ui.Key.src(@src()).indexed(index),
                .selectable = false,
                .style = &.{ .font = "jetbrains-mono", .font_size = .xs, .foreground = .dimmed },
            },
            Text{ .content = if (flags & ui.text.shape.shaper.unsafe_to_concat != 0) "concat" else " ", .key = ui.Key.src(@src()).indexed(index), .selectable = false, .style = &.{ .font_size = .xs, .foreground = .warning } },
        } });
    }
    if (glyphs.ids.len > count) {
        try frame.e(Text{ .content = try std.fmt.allocPrint(arena, "+{d} more", .{glyphs.ids.len - count}), .key = .src(@src()), .selectable = false, .style = &.{ .font_size = .xs, .foreground = .dimmed } });
    }
    try strip.close(frame);
    try frame.e(Text{
        .content = "Border tone: the face that shaped the run. Thick left border: unsafe to break before the glyph. Hover a glyph or the text to link them.",
        .key = .src(@src()),
        .selectable = false,
        .style = &.{ .font_size = .xs, .foreground = .dimmed, .wrap = true, .width = .grow() },
    });
}

/// The glyph under the pointer, from an inspector cell or the preview text.
fn hoveredGlyph(frame: *ui.Frame, layout: *const TextLayout) !?u32 {
    const ui_ = frame.ui();
    for (0..@min(layout.glyphs.ids.len, cells_max)) |index| {
        if (ui_.isHoveredWithin(cell_key.indexed(index).hash())) return @intCast(index);
    }
    const box = (try ui_.state.getOrCreate(.measured, ui_.allocator, preview_key.hash())).box;
    const x: f32 = @as(f32, @floatCast(ui_.input.mouse_pos[0])) - box.x();
    const y: f32 = @as(f32, @floatCast(ui_.input.mouse_pos[1])) - box.y();
    if (x < 0 or y < 0 or x >= box.w() or y >= box.h()) return null;
    // Layouts are in physical pixels.
    return layout.glyphAt(.{ .x = x * ui_.content_scale, .y = y * ui_.content_scale });
}

/// Refreshes the feature list when the font changes.
fn loadTags(self: *Shaping, gpa: std.mem.Allocator, system: *TextSystem) !void {
    if (self.tags_font == self.font) return;
    const tags = try system.faceById(self.font).program.featureTags(gpa);
    errdefer gpa.free(tags);
    const enabled = try gpa.alloc(bool, tags.len);
    for (tags, enabled) |tag, *on| on.* = isDefaultOn(tag);
    gpa.free(self.tags);
    gpa.free(self.enabled);
    self.tags = tags;
    self.enabled = enabled;
    self.tags_font = self.font;
}

/// The checkboxes that differ from the default.
fn featureOverrides(self: *const Shaping, arena: std.mem.Allocator) ![]const Feature {
    var list: std.ArrayList(Feature) = .empty;
    for (self.tags, self.enabled) |tag, on| {
        if (on != isDefaultOn(tag)) try list.append(arena, .{ .tag = tag, .value = @intFromBool(on) });
    }
    return list.items;
}

fn isDefaultOn(tag: u32) bool {
    for (default_on) |name| {
        if (std.mem.readInt(u32, name, .big) == tag) return true;
    }
    return false;
}

fn faceTone(face: u16) ui.style.Color.Input {
    const tones = [_]ui.style.Color.Input{ .primary, .success, .warning, .info };
    return tones[face % tones.len];
}

const small_button: ui.Style = .{ .height = .fixed(26), .padding = .xy(10, 0), .font_size = .sm };
const small_selected: ui.Style = small_button.with(.{ .tone = .success });

pub fn deinit(self: *Shaping, allocator: std.mem.Allocator) void {
    self.editor.deinit(allocator);
    allocator.free(self.tags);
    allocator.free(self.enabled);
}
