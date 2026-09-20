const renderer = @import("renderer");

pub const GpuResources = struct {
    pipeline: renderer.gpu.Pipeline,
    vertex_buffer: renderer.gpu.Buffer,
    index_buffer: renderer.gpu.Buffer,
    instance_buffer: renderer.gpu.Buffer,

    pub fn deinit(self: *GpuResources) void {
        self.instance_buffer.deinit();
        self.index_buffer.deinit();
        self.vertex_buffer.deinit();
        self.pipeline.deinit();
    }
};

counter: isize = 0,
gpu_resources: ?GpuResources = null,
gpu_time: f32 = 0,
gpu_orbit: f32 = 0,
gpu_camera: [2]f32 = .{ 0.35, -0.2 },
gpu_drag_position: [2]f32 = .{ 0, 0 },
gpu_dragging: bool = false,
gpu_density: f32 = 4096,
gpu_strand_width: f32 = 0.14,
gpu_facet_size: f32 = 1.0,
gpu_twist: f32 = 3.0,
gpu_zoom: f32 = 1.0,
gpu_perspective: f32 = 48,
gpu_spin: f32 = 0.32,
pending_async: usize = 0,
floating_window_open: bool = false,
floating_window_second_open: bool = false,

pub fn deinit(self: *@This()) void {
    if (self.gpu_resources) |*resources| resources.deinit();
}
