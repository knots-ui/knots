const Radius = @import("style").Radius;
const BorderWidth = @import("style").BorderWidth;
const DrawList = @import("render").DrawList;
const text = @import("text");

pub const Decoration = union(enum) {
    none: void,
    rect: Rect,
    text: Text,
    canvas: Canvas,
    gpu_canvas: GPUCanvas,
    image: Image,
    range: Range,

    pub const Rect = @import("style").Surface;

    pub const Text = struct {
        content: []const u8 = "",
        size: f32 = 14,
        color: [4]f32 = .{ 1, 1, 1, 1 },
        font: ?[]const u8 = null,
        intrinsic_w: f32 = 0,
        intrinsic_h: f32 = 0,
        wrap: bool = false,
        /// Font, size (logical pixels) and features over byte ranges of `content`.
        runs: []const text.TextSystem.StyleRun = &.{},
        colors: []const ColorSpan = &.{},
        underlines: []const Underline = &.{},
        /// Global or ranged over bytes of `content`, e.g. `-calt` under the caret.
        features: []const text.shape.Plan.Feature = &.{},
        tab_size: u8 = text.TextSystem.tab_size_default,
        /// The element's identity. Keyed layouts are cached per key and style: content is
        /// compared instead of hashed, and an edit relayouts only the paragraphs it touches.
        key: ?u64 = null,
        /// Bump to force a relayout of keyed content.
        revision: u32 = 0,
    };

    pub const ColorSpan = struct { start: u32, end: u32, color: [4]f32 };

    pub const Underline = struct { start: u32, end: u32, color: ?[4]f32 = null };

    pub const Canvas = struct {
        cmds: []const DrawCmd,
    };

    pub const GPUCanvas = @import("render").PaintCallback;

    pub const Image = struct {
        source: DrawList.TextureSource,
        tint: [4]f32 = .{ 1, 1, 1, 1 },
        @"opaque": bool = false,
    };

    pub const Range = struct {
        progress: f32,
        track_color: [4]f32,
        fill_color: [4]f32,
        corner_radius: Radius = Radius.all(4),
        track_height: ?f32 = null,
        knob_radius: f32 = 0,
        knob_color: [4]f32 = .{ 1, 1, 1, 1 },
        halo_radius: f32 = 0,
        halo_color: [4]f32 = .{ 1, 1, 1, 0 },
    };

    pub const DrawCmd = union(enum) {
        fill_rect: FillRect,
        fill_rect_gradient: FillRectGradient,
        stroke_rect: StrokeRect,
        fill_circle: FillCircle,
        stroke_circle: StrokeCircle,
        line: Line,
        fill_triangle: FillTriangle,
        fill_convex_polygon: FillConvexPolygon,

        pub const FillRect = struct { x: f32, y: f32, w: f32, h: f32, color: [4]f32, corner_radius: Radius = .zero };
        pub const FillRectGradient = struct { x: f32, y: f32, w: f32, h: f32, colors: [4][4]f32, corner_radius: Radius = .zero };
        pub const StrokeRect = struct { x: f32, y: f32, w: f32, h: f32, color: [4]f32, corner_radius: Radius = .zero, thickness: f32 = 1, edge_widths: ?BorderWidth = null };
        pub const FillCircle = struct { cx: f32, cy: f32, radius: f32, color: [4]f32 };
        pub const StrokeCircle = struct { cx: f32, cy: f32, radius: f32, color: [4]f32, thickness: f32 = 1 };
        pub const Line = struct { from: [2]f32, to: [2]f32, color: [4]f32, thickness: f32 = 1 };
        pub const FillTriangle = struct { points: [3][2]f32, color: [4]f32 };
        pub const FillConvexPolygon = struct { points: []const [2]f32, color: [4]f32 };
    };
};
