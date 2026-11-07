//! Mark positioning for fonts without GPOS, ported from hb-ot-shape-fallback.cc.

const std = @import("std");
const font = @import("font");
const FontProgram = font.FontProgram;
const Buffer = @import("Buffer.zig");
const props = @import("props.zig");

const Extents = FontProgram.Extents;

const attached_below_left = 200;
const attached_below = 202;
const attached_above = 214;
const attached_above_right = 216;
const below_left = 218;
const below = 220;
const below_right = 222;
const above_left = 228;
const above = 230;
const above_right = 232;
const double_below = 233;
const double_above = 234;

/// Maps script-specific combining classes to positional ones, before glyph mapping.
pub fn recategorizeMarks(buffer: *Buffer) void {
    const s = buffer.slice();
    for (s.items(.id)[0..buffer.len], s.items(.unicode_props)[0..buffer.len]) |codepoint, *unicode_props| {
        if (props.generalCategory(unicode_props.*) != .non_spacing_mark) {
            continue;
        }
        props.setModifiedCombiningClass(unicode_props, recategorize(codepoint, props.modifiedCombiningClass(unicode_props.*)));
    }
}

fn recategorize(codepoint: u32, class: u8) u8 {
    if (class >= 200) {
        return class;
    }
    var result = class;
    if (codepoint & ~@as(u32, 0xFF) == 0x0E00) {
        if (result == 0) {
            switch (codepoint) {
                0x0E31, 0x0E34, 0x0E35, 0x0E36, 0x0E37, 0x0E47, 0x0E4C, 0x0E4D, 0x0E4E => result = above_right,
                0x0EB1, 0x0EB4, 0x0EB5, 0x0EB6, 0x0EB7, 0x0EBB, 0x0ECC, 0x0ECD => result = above,
                0x0EBC => result = below,
                else => {},
            }
        } else if (codepoint == 0x0E3A) {
            result = below_right;
        }
    }
    // Modified classes, see HB_MODIFIED_COMBINING_CLASS_CCC* in hb-unicode.hh.
    return switch (result) {
        15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 => below,
        13 => attached_above,
        10 => above_right,
        11, 14 => above_left,
        26 => above,
        27, 28, 29, 31, 32, 34, 35, 36 => above,
        30, 33 => below,
        3 => below_right,
        107 => above_right,
        118 => below,
        122 => above,
        129, 131 => below,
        132 => above,
        else => result,
    };
}

const Positioner = struct {
    buffer: *Buffer,
    program: *const FontProgram,
    gpa: std.mem.Allocator,
    adjust_offsets: bool,

    fn unicodeProps(self: *const Positioner, i: u32) u16 {
        return self.buffer.field(.unicode_props)[i];
    }

    fn isMark(self: *const Positioner, i: u32) bool {
        return props.isUnicodeMark(self.unicodeProps(i));
    }

    fn isSkipped(self: *const Positioner, i: u32) bool {
        return props.isHidden(self.unicodeProps(i)) or props.isDefaultIgnorable(self.unicodeProps(i), self.buffer.field(.glyph_props)[i]);
    }

    fn cluster(self: *const Positioner, start: u32, end: u32) !void {
        if (end - start < 2) {
            return;
        }
        var i = start;
        while (i < end) : (i += 1) {
            if (self.isMark(i)) {
                continue;
            }
            var j = i + 1;
            while (j < end) : (j += 1) {
                if (self.isSkipped(j)) {
                    continue;
                }
                if (!self.isMark(j)) {
                    break;
                }
            }
            try self.aroundBase(i, j);
            i = j - 1;
        }
    }

    fn zeroMarkAdvances(self: *const Positioner, start: u32, end: u32) void {
        const s = self.buffer.slice();
        for (start..end) |i| {
            if (props.generalCategory(s.items(.unicode_props)[i]) != .non_spacing_mark) {
                continue;
            }
            if (self.adjust_offsets) {
                s.items(.x_offset)[i] -|= s.items(.x_advance)[i];
            }
            s.items(.x_advance)[i] = 0;
        }
    }

    fn aroundBase(self: *const Positioner, base: u32, end: u32) !void {
        const buffer = self.buffer;
        buffer.unsafeToBreak(base, end);
        const s = buffer.slice();
        const ids = s.items(.id);
        var base_extents = try self.program.glyphExtents(self.gpa, ids[base]) orelse {
            self.zeroMarkAdvances(base + 1, end);
            return;
        };
        base_extents.y_bearing +|= s.items(.y_offset)[base];
        base_extents.x_bearing = 0;
        base_extents.width = self.program.advance(ids[base]);

        const lig_props = s.items(.lig_props);
        const lig_id = props.ligId(lig_props[base]);
        const components: i32 = props.ligNumComps(lig_props[base], s.items(.glyph_props)[base]);
        var x_offset: i32 = 0 -| s.items(.x_advance)[base];

        var component_extents = base_extents;
        var last_component: i32 = -1;
        var last_class: u32 = 255;
        var cluster_extents = base_extents;
        for (base + 1..end) |index| {
            const i: u32 = @intCast(index);
            const class = props.modifiedCombiningClass(s.items(.unicode_props)[i]);
            if (class == 0) {
                x_offset -|= s.items(.x_advance)[i];
                continue;
            }
            if (components > 1) {
                var component: i32 = @as(i32, props.ligComp(lig_props[i])) - 1;
                if (lig_id == 0 or lig_id != props.ligId(lig_props[i]) or component >= components) {
                    component = components - 1;
                }
                if (last_component != component) {
                    last_component = component;
                    last_class = 255;
                    component_extents = base_extents;
                    component_extents.x_bearing = clamp(@as(i64, component_extents.x_bearing) + @divTrunc(@as(i64, component) * component_extents.width, components));
                    component_extents.width = @divTrunc(component_extents.width, components);
                }
            }
            if (last_class != class) {
                last_class = class;
                cluster_extents = component_extents;
            }
            try self.mark(&cluster_extents, i, class);
            s.items(.x_advance)[i] = 0;
            s.items(.x_offset)[i] +|= x_offset;
        }
    }

    fn mark(self: *const Positioner, base: *Extents, i: u32, class: u8) !void {
        const s = self.buffer.slice();
        const extents = try self.program.glyphExtents(self.gpa, s.items(.id)[i]) orelse return;
        const y_gap: i32 = @divTrunc(@as(i32, self.program.units_per_em), 16);
        const x_offset = &s.items(.x_offset)[i];
        const y_offset = &s.items(.y_offset)[i];

        x_offset.* = switch (class) {
            double_below, double_above => clamp(@as(i64, base.x_bearing) + base.width - @divTrunc(extents.width, 2) - extents.x_bearing),
            attached_below_left, below_left, above_left => base.x_bearing -| extents.x_bearing,
            attached_above_right, below_right, above_right => clamp(@as(i64, base.x_bearing) + base.width - extents.width - extents.x_bearing),
            else => clamp(@as(i64, base.x_bearing) + @divTrunc(@as(i64, base.width) - extents.width, 2) - extents.x_bearing),
        };
        y_offset.* = 0;

        switch (class) {
            double_below, below_left, below, below_right, attached_below_left, attached_below => {
                switch (class) {
                    attached_below_left, attached_below => {},
                    else => base.height -|= y_gap,
                }
                y_offset.* = clamp(@as(i64, base.y_bearing) + base.height - extents.y_bearing);
                // Never shift "below" marks up.
                if ((y_gap > 0) == (y_offset.* > 0)) {
                    base.height -|= y_offset.*;
                    y_offset.* = 0;
                }
                base.height +|= extents.height;
            },
            double_above, above_left, above, above_right, attached_above, attached_above_right => {
                switch (class) {
                    attached_above, attached_above_right => {},
                    else => {
                        base.y_bearing +|= y_gap;
                        base.height -|= y_gap;
                    },
                }
                y_offset.* = clamp(@as(i64, base.y_bearing) - extents.y_bearing - extents.height);
                // Don't shift "above" marks down too far.
                if ((y_gap > 0) != (y_offset.* > 0)) {
                    const correction = -@divTrunc(y_offset.*, 2);
                    base.y_bearing +|= correction;
                    base.height -|= correction;
                    y_offset.* +|= correction;
                }
                base.y_bearing -|= extents.height;
                base.height +|= extents.height;
            },
            else => {},
        }
    }
};

fn clamp(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// Stacks marks on their base by Unicode combining class, using glyph extents.
pub fn positionMarks(buffer: *Buffer, program: *const FontProgram, gpa: std.mem.Allocator, adjust_offsets: bool) !void {
    const positioner: Positioner = .{ .buffer = buffer, .program = program, .gpa = gpa, .adjust_offsets = adjust_offsets };
    var start: u32 = 0;
    var i: u32 = 1;
    while (i < buffer.len) : (i += 1) {
        if (positioner.isMark(i) or positioner.isSkipped(i)) {
            continue;
        }
        try positioner.cluster(start, i);
        start = i;
    }
    try positioner.cluster(start, buffer.len);
}
