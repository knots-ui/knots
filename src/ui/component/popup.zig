const std = @import("std");
const math = @import("math");

pub const Placement = struct {
    x: f32,
    y: f32,
    width: f32,
    max_height: f32,
};

/// Opens below the anchor, start-aligned. Each axis flips to the opposite
/// side when the popup overflows and that side has more room, then clamps
/// to the viewport.
pub fn place(viewport: math.Rect, anchor: math.Rect, requested_width: f32, estimated_height: f32) Placement {
    const viewport_w = @max(0, viewport.w());
    const viewport_h = @max(0, viewport.h());
    const width = @max(0, @min(requested_width, viewport_w));

    const left = viewport.x();
    const top = viewport.y();
    const right = left + viewport_w;
    const bottom = top + viewport_h;

    const anchor_right = anchor.x() + anchor.w();
    const space_after = @max(0, right - anchor.x());
    const space_before = @max(0, anchor_right - left);
    const end_aligned = width > space_after and space_before > space_after;
    var raw_x = anchor.x();
    if (end_aligned) {
        raw_x = anchor_right - width;
    }

    const anchor_bottom = anchor.y() + anchor.h();
    const space_below = @max(0, bottom - anchor_bottom);
    const space_above = @max(0, anchor.y() - top);
    const opens_above = estimated_height > space_below and space_above > space_below;
    var max_height = space_below;
    var raw_y = anchor_bottom;
    if (opens_above) {
        max_height = space_above;
        raw_y = anchor.y() - @min(estimated_height, max_height);
    }
    const height = @min(estimated_height, max_height);

    return .{
        .x = clampAxis(raw_x, left, right - width),
        .y = clampAxis(raw_y, top, bottom - height),
        .width = width,
        .max_height = max_height,
    };
}

pub fn clampAxis(value: f32, min: f32, max: f32) f32 {
    if (max <= min) {
        return min;
    }
    return std.math.clamp(value, min, max);
}
