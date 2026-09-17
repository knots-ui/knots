const gpu = @import("gpu");
const renderer_api = @import("renderer");
const App = @import("App.zig");
const Viewport = @import("Viewport.zig");

const View = @This();

/// State for one App callback. Renderer status is a snapshot for this callback;
/// use App operations to request changes or transfer readback ownership.
app: *App,
id: Viewport.Id,
renderer: RendererStatus,

pub const RendererStatus = struct {
    config: renderer_api.Renderer.Config,
    supported_present_modes: gpu.Context.PresentModes,
    reconfigure_error: ?renderer_api.Renderer.ReconfigureError,
};
