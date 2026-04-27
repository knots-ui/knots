pub const Decoration = union(enum) {
    none: void,
    rect: Rect,
    text: Text,
    canvas: Canvas,
    image: Image,
    slider: Slider,

    pub const Rect = struct {
        color: [4]f32 = .{ 0, 0, 0, 0 },
        corner_radius: f32 = 0,
        border_width: f32 = 0,
        border_color: [4]f32 = .{ 0, 0, 0, 0 },
    };

    pub const Text = struct {
        content: []const u8 = "",
        size: f32 = 14,
        color: [4]f32 = .{ 1, 1, 1, 1 },
        font: ?[]const u8 = null,
        intrinsic_w: f32 = 0,
        intrinsic_h: f32 = 0,
    };

    pub const Canvas = struct {
        cmds: []const DrawCmd,
    };

    pub const Image = struct {
        texture_id: u32,
        tint: [4]f32 = .{ 1, 1, 1, 1 },
    };

    pub const Slider = struct {
        progress: f32,
        track_color: [4]f32,
        fill_color: [4]f32,
        corner_radius: f32 = 2,
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

        pub const FillRect = struct { x: f32, y: f32, w: f32, h: f32, color: [4]f32, corner_radius: f32 = 0 };
        pub const FillRectGradient = struct { x: f32, y: f32, w: f32, h: f32, colors: [4][4]f32, corner_radius: f32 = 0 };
        pub const StrokeRect = struct { x: f32, y: f32, w: f32, h: f32, color: [4]f32, corner_radius: f32 = 0, thickness: f32 = 1 };
        pub const FillCircle = struct { cx: f32, cy: f32, radius: f32, color: [4]f32 };
        pub const StrokeCircle = struct { cx: f32, cy: f32, radius: f32, color: [4]f32, thickness: f32 = 1 };
        pub const Line = struct { from: [2]f32, to: [2]f32, color: [4]f32, thickness: f32 = 1 };
        pub const FillTriangle = struct { points: [3][2]f32, color: [4]f32 };
        pub const FillConvexPolygon = struct { points: []const [2]f32, color: [4]f32 };
    };
};
