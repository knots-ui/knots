const std = @import("std");

const App = @import("knots").App;
const Element = @import("layout").Element;
const ui_mod = @import("ui");

const Color = ui_mod.Color;
const Decoration = ui_mod.Decoration;
const DrawCmd = Decoration.DrawCmd;
const Key = ui_mod.Key;
const Style = ui_mod.Style;

key: Key,
width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .fixed(64),
style: Style = .{},
inset: Element.Padding = .init(0, 0, 0, 0),
x_domain: ?Domain = null,
y_domain: ?Domain = null,
series: []const Series = &.{},
rules: []const Rule = &.{},

const Graph = @This();

pub const Point = struct { x: f32, y: f32 };
pub const Domain = struct { min: f32, max: f32 };

pub const Data = union(enum) {
    y_values: []const f32,
    points: []const Point,
};

pub const Kind = enum { line, bars, points };

pub const Series = struct {
    data: Data,
    kind: Kind = .line,
    color: Color.Input = .primary,
    thickness: f32 = 2,
    radius: f32 = 2,
    bar_gap: f32 = 1,
    baseline: f32 = 0,
};

pub const Axis = enum { x, y };

pub const Rule = struct {
    axis: Axis,
    value: f32,
    color: Color.Input = .dimmed,
    thickness: f32 = 1,
};

pub fn open(self: *const Graph, app: *App) !Element.Id {
    const id = self.key.hash();
    _ = try app.ui.state.getOrCreate(.measured, app.ui.allocator, id);
    const rect = self.style.toRect(&app.ui.theme);
    const needs_clip_shape = !rect.corner_radius.isZero() or !rect.border_width.isZero();
    const decoration: Decoration = if (self.style.hasDecoration() or needs_clip_shape)
        .{ .rect = rect }
    else
        .none;
    return try app.ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
        .overflow = .hidden,
    }, decoration);
}

pub fn close(self: *const Graph, app: *App) !void {
    const ui = &app.ui;
    const slot = ui.currentSlot();
    const s = self.size(ui);

    var canvas_cmds: []const DrawCmd = &.{};

    if (s.w > 0 and s.h > 0) {
        const plot = Plot.fromSize(s, self.inset);
        const graph_cmd_count = if (plot.w > 0 and plot.h > 0) self.maxGraphCommandCount() else 0;
        const capacity = self.maxStyleCommandCount() + graph_cmd_count;

        if (capacity > 0) {
            var writer = CommandWriter{ .cmds = try app.arena().alloc(DrawCmd, capacity) };
            self.appendStyle(&writer, app, s);

            if (graph_cmd_count > 0) {
                const x_domain = expandDomain(self.x_domain orelse self.autoDomain(.x));
                const y_domain = expandDomain(self.y_domain orelse self.autoDomain(.y));
                const mapper = Mapper{
                    .plot = plot,
                    .x_min = x_domain.min,
                    .y_min = y_domain.min,
                    .x_inv_range = 1.0 / (x_domain.max - x_domain.min),
                    .y_inv_range = 1.0 / (y_domain.max - y_domain.min),
                };

                for (self.rules) |rule| appendRule(&writer, app, mapper, rule);
                for (self.series) |series| appendSeries(&writer, app, mapper, series);
            }

            canvas_cmds = writer.items();
        }
    }

    ui.setDecoration(slot, .{ .canvas = .{ .cmds = canvas_cmds } });
    ui.close();
}

const CommandWriter = struct {
    cmds: []DrawCmd,
    len: usize = 0,

    fn append(self: *CommandWriter, cmd: DrawCmd) void {
        std.debug.assert(self.len < self.cmds.len);
        self.cmds[self.len] = cmd;
        self.len += 1;
    }

    fn items(self: *const CommandWriter) []const DrawCmd {
        return self.cmds[0..self.len];
    }
};

const Mapper = struct {
    plot: Plot,
    x_min: f32,
    y_min: f32,
    x_inv_range: f32,
    y_inv_range: f32,

    fn x(self: Mapper, value: f32) f32 {
        const t = std.math.clamp((value - self.x_min) * self.x_inv_range, 0, 1);
        return self.plot.x + t * self.plot.w;
    }

    fn y(self: Mapper, value: f32) f32 {
        const t = std.math.clamp((value - self.y_min) * self.y_inv_range, 0, 1);
        return self.plot.y + self.plot.h - t * self.plot.h;
    }
};

fn maxStyleCommandCount(self: *const Graph) usize {
    return if (self.style.hasDecoration()) 2 else 0;
}

fn maxGraphCommandCount(self: *const Graph) usize {
    var count: usize = self.rules.len;
    for (self.series) |series_| {
        const n = dataLen(series_.data);
        count += switch (series_.kind) {
            .line => if (n >= 2) n - 1 else 0,
            .bars, .points => n,
        };
    }
    return count;
}

fn appendStyle(self: *const Graph, writer: *CommandWriter, app: *App, s: Size) void {
    if (!self.style.hasDecoration()) return;

    const rect = self.style.toRect(&app.ui.theme);
    if (rect.color[3] > 0) {
        writer.append(.{ .fill_rect = .{
            .x = 0,
            .y = 0,
            .w = s.w,
            .h = s.h,
            .color = rect.color,
            .corner_radius = rect.corner_radius,
        } });
    }

    const border_width = rect.border_width;
    if (!border_width.isZero() and rect.border_color[3] > 0) {
        const top = border_width.value[0];
        const right = border_width.value[1];
        const bottom = border_width.value[2];
        const left = border_width.value[3];
        const max_width = border_width.max();
        writer.append(.{ .stroke_rect = .{
            .x = left * 0.5,
            .y = top * 0.5,
            .w = @max(0, s.w - (left + right) * 0.5),
            .h = @max(0, s.h - (top + bottom) * 0.5),
            .color = rect.border_color,
            .corner_radius = rect.corner_radius.shrink(max_width * 0.5),
            .thickness = max_width,
            .edge_widths = border_width,
        } });
    }
}

fn appendRule(writer: *CommandWriter, app: *App, mapper: Mapper, rule: Rule) void {
    if (rule.thickness <= 0) return;

    const color = rule.color.resolve(&app.ui.theme);
    if (color[3] <= 0) return;

    const plot = mapper.plot;
    switch (rule.axis) {
        .x => {
            const x = mapper.x(rule.value);
            writer.append(.{ .line = .{
                .from = .{ x, plot.y },
                .to = .{ x, plot.y + plot.h },
                .color = color,
                .thickness = rule.thickness,
            } });
        },
        .y => {
            const y = mapper.y(rule.value);
            writer.append(.{ .line = .{
                .from = .{ plot.x, y },
                .to = .{ plot.x + plot.w, y },
                .color = color,
                .thickness = rule.thickness,
            } });
        },
    }
}

fn appendSeries(writer: *CommandWriter, app: *App, mapper: Mapper, series_: Series) void {
    switch (series_.kind) {
        .line => appendLine(writer, app, mapper, series_),
        .bars => appendBars(writer, app, mapper, series_),
        .points => appendPoints(writer, app, mapper, series_),
    }
}

fn appendLine(writer: *CommandWriter, app: *App, mapper: Mapper, series_: Series) void {
    if (series_.thickness <= 0) return;

    const color = series_.color.resolve(&app.ui.theme);
    if (color[3] <= 0) return;

    switch (series_.data) {
        .y_values => |values| {
            if (values.len < 2) return;

            var prev_x = mapper.x(0);
            var prev_y = mapper.y(values[0]);
            for (values[1..], 1..) |value, i| {
                const x = mapper.x(@floatFromInt(i));
                const y = mapper.y(value);
                writer.append(.{ .line = .{
                    .from = .{ prev_x, prev_y },
                    .to = .{ x, y },
                    .color = color,
                    .thickness = series_.thickness,
                } });
                prev_x = x;
                prev_y = y;
            }
        },
        .points => |points| {
            if (points.len < 2) return;

            var prev_x = mapper.x(points[0].x);
            var prev_y = mapper.y(points[0].y);
            for (points[1..]) |point| {
                const x = mapper.x(point.x);
                const y = mapper.y(point.y);
                writer.append(.{ .line = .{
                    .from = .{ prev_x, prev_y },
                    .to = .{ x, y },
                    .color = color,
                    .thickness = series_.thickness,
                } });
                prev_x = x;
                prev_y = y;
            }
        },
    }
}

fn appendBars(writer: *CommandWriter, app: *App, mapper: Mapper, series_: Series) void {
    const color = series_.color.resolve(&app.ui.theme);
    if (color[3] <= 0) return;

    const baseline = mapper.y(series_.baseline);
    const plot = mapper.plot;

    switch (series_.data) {
        .y_values => |values| {
            if (values.len == 0) return;

            const slot_w = plot.w / @as(f32, @floatFromInt(values.len));
            const bar_w = @max(0, slot_w - series_.bar_gap);
            if (bar_w <= 0) return;

            for (values, 0..) |value, i| {
                const x_center = plot.x + slot_w * (@as(f32, @floatFromInt(i)) + 0.5);
                const y = mapper.y(value);
                writer.append(.{ .fill_rect = .{
                    .x = x_center - bar_w * 0.5,
                    .y = @min(y, baseline),
                    .w = bar_w,
                    .h = @abs(baseline - y),
                    .color = color,
                } });
            }
        },
        .points => |points| {
            if (points.len == 0) return;

            const slot_w = plot.w / @as(f32, @floatFromInt(points.len));
            const bar_w = @max(0, slot_w - series_.bar_gap);
            if (bar_w <= 0) return;

            for (points) |point| {
                const x_center = mapper.x(point.x);
                const y = mapper.y(point.y);
                writer.append(.{ .fill_rect = .{
                    .x = x_center - bar_w * 0.5,
                    .y = @min(y, baseline),
                    .w = bar_w,
                    .h = @abs(baseline - y),
                    .color = color,
                } });
            }
        },
    }
}

fn appendPoints(writer: *CommandWriter, app: *App, mapper: Mapper, series_: Series) void {
    if (series_.radius <= 0) return;

    const color = series_.color.resolve(&app.ui.theme);
    if (color[3] <= 0) return;

    switch (series_.data) {
        .y_values => |values| {
            for (values, 0..) |value, i| {
                writer.append(.{ .fill_circle = .{
                    .cx = mapper.x(@floatFromInt(i)),
                    .cy = mapper.y(value),
                    .radius = series_.radius,
                    .color = color,
                } });
            }
        },
        .points => |points| {
            for (points) |point| {
                writer.append(.{ .fill_circle = .{
                    .cx = mapper.x(point.x),
                    .cy = mapper.y(point.y),
                    .radius = series_.radius,
                    .color = color,
                } });
            }
        },
    }
}

fn autoDomain(self: *const Graph, axis: Axis) Domain {
    var domain = Domain{ .min = 0, .max = 1 };
    var initialized = false;

    for (self.series) |series_| {
        if (axis == .y and series_.kind == .bars) {
            includeValue(&domain, &initialized, series_.baseline);
        }

        includeDataDomain(&domain, &initialized, axis, series_.data);
    }

    return domain;
}

fn includeDataDomain(domain: *Domain, initialized: *bool, axis: Axis, data: Data) void {
    switch (data) {
        .y_values => |values| switch (axis) {
            .x => if (values.len > 0) {
                includeValue(domain, initialized, 0);
                includeValue(domain, initialized, @floatFromInt(values.len - 1));
            },
            .y => for (values) |value| includeValue(domain, initialized, value),
        },
        .points => |points| for (points) |point| {
            includeValue(domain, initialized, switch (axis) {
                .x => point.x,
                .y => point.y,
            });
        },
    }
}

fn includeValue(domain: *Domain, initialized: *bool, value: f32) void {
    if (!initialized.*) {
        domain.* = .{ .min = value, .max = value };
        initialized.* = true;
    } else {
        domain.min = @min(domain.min, value);
        domain.max = @max(domain.max, value);
    }
}

fn expandDomain(domain: Domain) Domain {
    if (domain.min != domain.max) return domain;
    return .{ .min = domain.min - 0.5, .max = domain.max + 0.5 };
}

fn dataLen(data: Data) usize {
    return switch (data) {
        .y_values => |values| values.len,
        .points => |points| points.len,
    };
}

const Size = struct { w: f32, h: f32 };

const Plot = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    fn fromSize(s: Size, inset: Element.Padding) Plot {
        const left = inset.left();
        const right = inset.right();
        const top = inset.top();
        const bottom = inset.bottom();
        return .{
            .x = left,
            .y = top,
            .w = @max(0, s.w - left - right),
            .h = @max(0, s.h - top - bottom),
        };
    }
};

fn size(self: *const Graph, ui: *ui_mod.UI) Size {
    const measured = ui.state.get(.measured, self.key.hash());
    return .{
        .w = if (measured) |m| fallbackSize(m.width, self.width) else axisFallback(self.width),
        .h = if (measured) |m| fallbackSize(m.height, self.height) else axisFallback(self.height),
    };
}

fn fallbackSize(measured: f32, axis: Element.sizing.Axis) f32 {
    if (measured > 0) return measured;
    return axisFallback(axis);
}

fn axisFallback(axis: Element.sizing.Axis) f32 {
    return if (axis.kind == .fixed) axis.value else 0;
}
