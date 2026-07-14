const App = @import("knots").App;
const gpu = @import("knots").render.gpu;
const Element = @import("layout").Element;
const Key = @import("ui").Key;

width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .grow(),
interactive: bool = false,
onDraw: gpu.DrawCallback,
user_data: ?*anyopaque = null,
key: Key,

const GPUCanvas = @This();

pub fn open(self: *const GPUCanvas, app: *App) !Element.Id {
    return app.viewport.ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
        .overflow = .hidden,
        .interactive = self.interactive,
    }, .none);
}

pub fn close(self: *const GPUCanvas, app: *App) !void {
    app.viewport.ui.setDecoration(app.viewport.ui.currentSlot(), .{ .gpu_canvas = .{
        .on_draw = self.onDraw,
        .user_data = self.user_data,
    } });
    app.viewport.ui.close();
}
