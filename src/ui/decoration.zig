const Radius = @import("Radius.zig");
const BorderWidth = @import("BorderWidth.zig");
const DrawList = @import("render").DrawList;

pub const Decoration = union(enum) {
    none: void,
    rect: Rect,
    text: Text,
    canvas: Canvas,
    gpu_canvas: GPUCanvas,
    image: Image,
    range: Range,

    pub const Rect = struct {
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: Radius = .zero,
        border_width: BorderWidth = .zero,
        border_color: [4]f32 = .{ 0, 0, 0, 0 },
    };

    pub const Text = struct {
        content: []const u8 = "",
        size: f32 = 14,
        color: [4]f32 = .{ 1, 1, 1, 1 },
        font: ?[]const u8 = null,
        intrinsic_w: f32 = 0,
        intrinsic_h: f32 = 0,
        wrap: bool = false,
    };

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
