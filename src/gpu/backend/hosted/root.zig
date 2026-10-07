const std = @import("std");
const gpu = @import("gpu");
const guest = @import("hosted");
const abi = guest.abi;

fn call(comptime tag: std.meta.Tag(abi.GpuCall), args: @FieldType(abi.GpuCall, @tagName(tag))) abi.Error!abi.GpuCall.Result(tag) {
    return guest.call(abi.GpuCall.Result(tag), .{ .gpu = @unionInit(abi.GpuCall, @tagName(tag), args) });
}

fn queue(command: abi.GpuCommand) void {
    guest.queue(.{ .gpu = command });
}

pub const Device = struct {
    pub const clip_space_y_down = gpu.Backend == .vulkan;

    info: abi.Device,

    pub fn init(_: std.mem.Allocator, window_handle: gpu.Context.WindowHandle) !Device {
        return .{ .info = try call(.device, @fromBackingInt(window_handle.hosted)) };
    }

    pub fn deinit(_: *Device) void {}

    pub fn waitIdle(_: *Device) !void {
        try call(.wait_idle, {});
    }

    pub fn createBuffer(_: *Device, desc: gpu.Buffer.Desc) !Buffer {
        try gpu.Buffer.validateDesc(desc);
        return .{ .handle = try call(.create_buffer, desc), .size = desc.size };
    }

    pub fn createPipeline(_: *Device, desc: gpu.Pipeline.Desc) !Pipeline {
        return .{ .handle = try call(.create_pipeline, desc) };
    }

    pub fn createBindGroup(_: *Device, desc: BindGroup.Desc) !BindGroup {
        return BindGroup.create(desc);
    }

    pub fn createTexture(_: *Device, desc: gpu.Texture.Desc) !Texture {
        return .{ .handle = try call(.create_texture, desc), .width = desc.width, .height = desc.height, .format = desc.format };
    }

    pub fn createSampler(_: *Device, desc: gpu.Sampler.Desc) !Sampler {
        return .{ .handle = try call(.create_sampler, desc) };
    }

    pub fn surfaceFormat(self: *const Device) gpu.Texture.Format {
        return self.info.surface_format;
    }

    pub fn surfaceIsSrgb(self: *const Device) bool {
        return self.info.surface_is_srgb;
    }
};

pub const Surface = struct {
    window: abi.Window,
    device: *Device,
    cfg: gpu.Context.Config,

    pub fn init(device: *Device, window_handle: gpu.Context.WindowHandle, cfg: gpu.Context.Config) !Surface {
        const window: abi.Window = @fromBackingInt(window_handle.hosted);
        try call(.configure_surface, .{ window, cfg });
        return .{ .window = window, .device = device, .cfg = cfg };
    }

    pub fn deinit(self: *Surface) void {
        queue(.{ .destroy = .{ .surface = self.window } });
    }

    pub fn resize(self: *Surface, width: u32, height: u32) !void {
        try call(.resize_surface, .{ self.window, width, height });
        self.cfg.window_width = width;
        self.cfg.window_height = height;
    }

    pub fn reconfigure(self: *Surface, cfg: gpu.Context.Config) !void {
        try call(.configure_surface, .{ self.window, cfg });
        self.cfg = cfg;
    }

    pub fn supportedPresentModes(self: *const Surface) gpu.Context.PresentModes {
        return call(.present_modes, self.window) catch .empty;
    }

    pub fn format(self: *const Surface) gpu.Texture.Format {
        return self.device.surfaceFormat();
    }
};

pub const Buffer = struct {
    handle: abi.Buffer,
    size: usize,

    pub fn deinit(self: *Buffer) void {
        queue(.{ .destroy = .{ .buffer = self.handle } });
    }

    pub fn load(self: *Buffer, comptime T: type, data: []const T) void {
        self.loadOffset(T, data, 0);
    }

    pub fn loadOffset(self: *Buffer, comptime T: type, data: []const T, offset: usize) void {
        std.debug.assert(offset <= self.size and data.len * @sizeOf(T) <= self.size - offset);
        queue(.{ .write_buffer = .{ self.handle, offset, std.mem.sliceAsBytes(data) } });
    }

    pub fn getSize(self: *const Buffer) usize {
        return self.size;
    }

    pub fn resize(self: *Buffer, new_size: usize) !void {
        try call(.resize_buffer, .{ self.handle, new_size });
        self.size = new_size;
    }
};

pub const Pipeline = struct {
    handle: abi.Pipeline,

    pub fn deinit(self: *Pipeline) void {
        queue(.{ .destroy = .{ .pipeline = self.handle } });
    }
};

pub const Sampler = struct {
    handle: abi.Sampler,

    pub fn deinit(self: *Sampler) void {
        queue(.{ .destroy = .{ .sampler = self.handle } });
    }
};

pub const Texture = struct {
    pub const NativeHandle = struct { handle: abi.Texture };

    handle: abi.Texture,
    width: u32,
    height: u32,
    format: gpu.Texture.Format,
    ready: bool = false,
    native_handle: NativeHandle = undefined,

    pub fn deinit(self: *Texture) void {
        queue(.{ .destroy = .{ .texture = self.handle } });
    }

    pub fn write(self: *Texture, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
        try call(.write_texture, .{
            .texture = self.handle,
            .data = data[0..len],
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .bytes_per_row = bytes_per_row,
        });
        self.ready = true;
    }

    pub fn isReady(self: *const Texture) bool {
        return self.ready;
    }

    pub fn nativeHandle(self: *Texture) *anyopaque {
        self.native_handle = .{ .handle = self.handle };
        return &self.native_handle;
    }
};

pub const BindGroup = struct {
    handle: abi.BindGroup,

    pub const BufferBinding = struct {
        buffer: *const Buffer,
        offset: u64 = 0,
        size: u64 = 0,
    };

    pub const Entry = union(enum) {
        buffer: BufferBinding,
        read_only_storage_buffer: BufferBinding,
        texture_view: *const Texture,
        sampler: *const Sampler,
    };

    pub const BindingEntry = struct {
        binding: u32,
        resource: Entry,
    };

    pub const Desc = struct {
        label: []const u8 = "",
        pipeline: *const Pipeline,
        layout_index: u32,
        entries: []const BindingEntry,
    };

    fn create(desc: Desc) !BindGroup {
        var entries: [16]abi.BindGroupEntry = undefined;
        if (desc.entries.len > entries.len) return error.TooManyBindings;
        for (desc.entries, entries[0..desc.entries.len]) |entry, *out| out.* = .{
            .binding = entry.binding,
            .resource = switch (entry.resource) {
                .buffer => |binding| .{ .buffer = bufferBinding(binding) },
                .read_only_storage_buffer => |binding| .{ .read_only_storage_buffer = bufferBinding(binding) },
                .texture_view => |texture| .{ .texture_view = texture.handle },
                .sampler => |sampler| .{ .sampler = sampler.handle },
            },
        };
        return .{ .handle = try call(.create_bind_group, .{
            .label = desc.label,
            .pipeline = desc.pipeline.handle,
            .layout_index = desc.layout_index,
            .entries = entries[0..desc.entries.len],
        }) };
    }

    fn bufferBinding(binding: BufferBinding) abi.BufferBinding {
        return .{ .buffer = binding.buffer.handle, .offset = binding.offset, .size = binding.size };
    }

    pub fn deinit(self: *BindGroup) void {
        queue(.{ .destroy = .{ .bind_group = self.handle } });
    }
};

pub const RenderPass = struct {
    frame: abi.Frame,

    pub const LoadOp = abi.LoadOp;
    pub const StoreOp = abi.StoreOp;

    pub const ColorAttachment = struct {
        load_op: LoadOp = .clear,
        store_op: StoreOp = .store,
        clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
        target: ?*Texture = null,
    };

    pub const DepthAttachment = struct {
        load_op: LoadOp = .clear,
        store_op: StoreOp = .store,
        clear_value: f32 = 1.0,
        target: *Texture,
    };

    pub const Desc = struct {
        label: []const u8 = "",
        color_attachment: ColorAttachment = .{},
        depth_attachment: ?DepthAttachment = null,
    };

    pub fn end(self: *RenderPass) void {
        queue(.{ .end_render_pass = self.frame });
    }

    pub fn bindPipeline(self: *RenderPass, pipeline: *const Pipeline) void {
        queue(.{ .bind_pipeline = .{ self.frame, pipeline.handle } });
    }

    pub fn setBindGroup(self: *RenderPass, group_index: u32, group: *const BindGroup) void {
        queue(.{ .set_bind_group = .{ self.frame, group_index, group.handle } });
    }

    pub fn setVertexBuffer(self: *RenderPass, slot: u32, buf: *const Buffer, offset: usize, size: usize) void {
        queue(.{ .set_vertex_buffer = .{ self.frame, slot, buf.handle, offset, size } });
    }

    pub fn setIndexBuffer(self: *RenderPass, buf: *const Buffer, offset: usize, size: usize) void {
        queue(.{ .set_index_buffer = .{ self.frame, buf.handle, offset, size } });
    }

    pub fn setScissorRect(self: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
        queue(.{ .set_scissor_rect = .{ self.frame, x, y, w, h } });
    }

    pub fn setViewport(self: *RenderPass, x: f32, y: f32, width: f32, height: f32) void {
        queue(.{ .set_viewport = .{ self.frame, x, y, width, height } });
    }

    pub fn draw(self: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        queue(.{ .draw = .{ self.frame, vertex_count, instance_count, first_vertex, first_instance } });
    }

    pub fn drawIndexed(self: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        queue(.{ .draw_indexed = .{ self.frame, index_count, instance_count, first_index, base_vertex, first_instance } });
    }
};

pub const Frame = struct {
    handle: abi.Frame,

    pub const Context = struct {
        frame: *Frame,
        upload_slot: u32,

        pub fn createBindGroup(_: *const Context, desc: BindGroup.Desc) !BindGroup {
            return BindGroup.create(desc);
        }

        pub fn beginRenderPass(self: *Context, desc: RenderPass.Desc) !RenderPass {
            const color = desc.color_attachment;
            try call(.begin_render_pass, .{ self.frame.handle, .{
                .label = desc.label,
                .color = .{
                    .load_op = color.load_op,
                    .store_op = color.store_op,
                    .clear_color = color.clear_color,
                    .target = if (color.target) |texture| texture.handle else null,
                },
                .depth = if (desc.depth_attachment) |depth| .{
                    .load_op = depth.load_op,
                    .store_op = depth.store_op,
                    .clear_value = depth.clear_value,
                    .target = depth.target.handle,
                } else null,
            } });
            return .{ .frame = self.frame.handle };
        }

        pub fn submit(self: *Context) !void {
            try call(.submit, self.frame.handle);
        }

        pub fn submitReadback(_: *Context, _: std.mem.Allocator) !gpu.SurfaceReadback {
            return error.SurfaceReadbackUnsupported;
        }
    };

    pub const ContextHandle = Context;

    pub fn create(surface: *Surface) !Frame {
        return .{ .handle = try call(.create_frame, surface.window) };
    }

    pub fn begin(self: *Frame) !Context {
        return .{ .frame = self, .upload_slot = try call(.begin_frame, self.handle) };
    }

    pub fn uploadSlotCount(self: *const Frame) u32 {
        return call(.upload_slot_count, self.handle) catch 1;
    }

    pub fn prepareResize(self: *Frame) void {
        queue(.{ .prepare_resize = self.handle });
    }

    pub fn deinit(self: *Frame) void {
        queue(.{ .destroy = .{ .frame = self.handle } });
    }

    pub fn waitForCompletion(self: *Frame) !void {
        try call(.wait_for_completion, self.handle);
    }
};
