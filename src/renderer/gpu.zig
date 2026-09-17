const common = @import("gpu");
const gpu_impl = @import("gpu_impl");

const RenderContext = @import("Context.zig");
const FrameUploads = @import("FrameUploads.zig");

pub const Context = struct {
    inner: *RenderContext,
    draw_format: ?common.Texture.Format = null,

    pub fn waitIdle(self: Context) !void {
        try self.inner.device.waitIdle();
    }

    pub fn drawFormat(self: Context) common.Texture.Format {
        if (self.draw_format) |format| return format;
        const context = self.inner;
        return if (context.linear_pipeline != null) .rgba8 else context.device.surfaceFormat();
    }

    pub fn createPipeline(self: Context, desc: common.Pipeline.Desc) !Pipeline {
        return .{ .inner = try self.inner.createPipeline(desc) };
    }

    pub fn createBuffer(self: Context, desc: common.Buffer.Desc) !Buffer {
        return .{ .inner = try self.inner.device.createBuffer(desc) };
    }

    pub fn createTexture(self: Context, desc: common.Texture.Desc) !Texture {
        return .{ .inner = try self.inner.device.createTexture(desc) };
    }

    pub fn createSampler(self: Context, desc: common.Sampler.Desc) !Sampler {
        return .{ .inner = try self.inner.device.createSampler(desc) };
    }

    pub fn createBindGroup(self: Context, desc: BindGroup.Desc) !BindGroup {
        var entries: [16]gpu_impl.BindGroup.BindingEntry = undefined;
        const native_desc = try bindGroupDesc(desc, &entries, null);
        return .{ .inner = try self.inner.device.createBindGroup(native_desc) };
    }
};

pub const Frame = struct {
    inner: *FrameUploads,

    /// Uploads data for this frame. The returned view expires after the draw callback.
    pub fn upload(self: *Frame, comptime T: type, values: []const T, usage: common.Buffer.Usage) !BufferView {
        const view = try self.inner.upload(T, values, usage);
        return .{
            .source = .{ .frame = .{ .uploads = self.inner, .chunk_index = view.chunk_index, .epoch = view.epoch } },
            .offset = view.offset,
            .size = view.size,
        };
    }

    /// Creates a bind group for this frame. The returned handle expires after the draw callback.
    pub fn createBindGroup(self: *Frame, desc: BindGroup.Desc) !BindGroupHandle {
        var entries: [16]gpu_impl.BindGroup.BindingEntry = undefined;
        const reference = try self.inner.createBindGroup(try bindGroupDesc(desc, &entries, self.inner));
        return .{ .source = .{ .frame = .{
            .uploads = self.inner,
            .slot_index = reference.slot_index,
            .epoch = reference.epoch,
        } } };
    }
};

pub const Pipeline = struct {
    inner: gpu_impl.Pipeline,

    pub fn deinit(self: *Pipeline) void {
        self.inner.deinit();
    }
};

pub const BufferView = struct {
    source: Source,
    offset: usize,
    size: usize,

    const Source = union(enum) {
        persistent: *const gpu_impl.Buffer,
        frame: struct {
            uploads: *FrameUploads,
            chunk_index: u32,
            epoch: u64,
        },
    };

    fn checkedImpl(self: BufferView) !*const gpu_impl.Buffer {
        const buffer = switch (self.source) {
            .persistent => |value| value,
            .frame => |value| value.uploads.uploadBuffer(value.chunk_index, value.epoch) orelse
                return error.ExpiredFrameResource,
        };
        const buffer_size = buffer.getSize();
        if (self.size == 0 or self.offset > buffer_size or self.size > buffer_size - self.offset)
            return error.InvalidBufferView;
        return buffer;
    }
};

pub const Buffer = struct {
    inner: gpu_impl.Buffer,

    pub fn view(self: *const Buffer) BufferView {
        return .{ .source = .{ .persistent = &self.inner }, .offset = 0, .size = self.inner.getSize() };
    }

    pub fn deinit(self: *Buffer) void {
        self.inner.deinit();
    }
};

pub const Texture = struct {
    inner: gpu_impl.Texture,

    pub fn write(self: *Texture, data: []const u8, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
        try self.inner.write(data.ptr, data.len, x, y, width, height, bytes_per_row);
    }

    pub fn deinit(self: *Texture) void {
        self.inner.deinit();
    }
};

pub const Sampler = struct {
    inner: gpu_impl.Sampler,

    pub fn deinit(self: *Sampler) void {
        self.inner.deinit();
    }
};

pub const BindGroupHandle = struct {
    source: Source,

    fn impl(self: BindGroupHandle) !*const gpu_impl.BindGroup {
        return switch (self.source) {
            .persistent => |value| value,
            .frame => |value| value.uploads.uploadBindGroup(value.slot_index, value.epoch) orelse
                return error.ExpiredFrameResource,
        };
    }

    const Source = union(enum) {
        persistent: *const gpu_impl.BindGroup,
        frame: struct {
            uploads: *FrameUploads,
            slot_index: u32,
            epoch: u64,
        },
    };
};

pub const BindGroup = struct {
    inner: gpu_impl.BindGroup,

    pub const Resource = union(enum) {
        buffer: BufferView,
        read_only_storage_buffer: BufferView,
        texture: *const Texture,
        sampler: *const Sampler,
    };

    pub const Entry = struct {
        binding: u32,
        resource: Resource,
    };

    pub const Desc = struct {
        label: []const u8 = "",
        pipeline: *const Pipeline,
        layout_index: u32,
        entries: []const Entry,
    };

    pub fn handle(self: *const BindGroup) BindGroupHandle {
        return .{ .source = .{ .persistent = &self.inner } };
    }

    pub fn deinit(self: *BindGroup) void {
        self.inner.deinit();
    }
};

pub const RenderPass = struct {
    inner: *gpu_impl.RenderPass,

    pub fn bindPipeline(self: *RenderPass, pipeline: *const Pipeline) void {
        self.inner.bindPipeline(&pipeline.inner);
    }

    pub fn setBindGroup(self: *RenderPass, index: u32, bind_group: BindGroupHandle) !void {
        self.inner.setBindGroup(index, try bind_group.impl());
    }

    pub fn setVertexBuffer(self: *RenderPass, slot: u32, view: BufferView) !void {
        self.inner.setVertexBuffer(slot, try view.checkedImpl(), view.offset, view.size);
    }

    pub fn setIndexBuffer(self: *RenderPass, view: BufferView) !void {
        self.inner.setIndexBuffer(try view.checkedImpl(), view.offset, view.size);
    }

    pub fn draw(self: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        self.inner.draw(vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn drawIndexed(self: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
        self.inner.drawIndexed(index_count, instance_count, first_index, base_vertex, first_instance);
    }
};

pub const LogicalBounds = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const PhysicalViewport = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const PhysicalScissor = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const ClipSpaceTransform = struct {
    scale: [2]f32,
    offset: [2]f32,
};

pub const DrawContext = struct {
    context: Context,
    frame: Frame,
    pass: RenderPass,
    logical_bounds: LogicalBounds,
    viewport: PhysicalViewport,
    scissor: PhysicalScissor,
    clip_space_transform: ClipSpaceTransform,
    content_scale: f32,
};

/// Typed form of `render.CustomDrawCallback`. `draw_context` is scoped
/// to the canvas bounds and valid only for the call.
pub const DrawCallback = *const fn (
    user_data: ?*anyopaque,
    draw_context: *DrawContext,
) anyerror!void;

/// Wrap a typed renderer callback without coupling UI components to this module.
/// The callback is selected at compile time; user_data remains borrowed.
pub fn paintCallback(user_data: ?*anyopaque, comptime callback: DrawCallback) @import("render").PaintCallback {
    const descriptor: @import("render").PaintCallback = .{
        .extension = .knots,
        .callback = struct {
            fn invoke(data: ?*anyopaque, erased_context: *anyopaque) !void {
                const std = @import("std");
                const context: *DrawContext = @ptrCast(@alignCast(erased_context));
                std.debug.assert(std.math.isFinite(context.content_scale));
                std.debug.assert(context.content_scale > 0);
                try callback(data, context);
            }
        }.invoke,
        .user_data = user_data,
    };
    descriptor.validate();
    return descriptor;
}

fn bindGroupDesc(desc: BindGroup.Desc, entries: *[16]gpu_impl.BindGroup.BindingEntry, frame_uploads: ?*FrameUploads) !gpu_impl.BindGroup.Desc {
    if (desc.entries.len > entries.len) return error.TooManyBindGroupEntries;
    for (desc.entries, 0..) |entry, i| {
        entries[i] = .{
            .binding = entry.binding,
            .resource = switch (entry.resource) {
                .buffer => |view| .{ .buffer = .{
                    .buffer = try bindGroupBuffer(view, frame_uploads),
                    .offset = view.offset,
                    .size = view.size,
                } },
                .read_only_storage_buffer => |view| .{ .read_only_storage_buffer = .{
                    .buffer = try bindGroupBuffer(view, frame_uploads),
                    .offset = view.offset,
                    .size = view.size,
                } },
                .texture => |texture| .{ .texture_view = &texture.inner },
                .sampler => |sampler| .{ .sampler = &sampler.inner },
            },
        };
    }
    return .{
        .label = desc.label,
        .pipeline = &desc.pipeline.inner,
        .layout_index = desc.layout_index,
        .entries = entries[0..desc.entries.len],
    };
}

fn bindGroupBuffer(view: BufferView, frame_uploads: ?*FrameUploads) !*const gpu_impl.Buffer {
    switch (view.source) {
        .persistent => {},
        .frame => |value| {
            const expected = frame_uploads orelse return error.FrameResourceRequiresFrameBindGroup;
            if (value.uploads != expected) return error.FrameResourceFromDifferentFrame;
        },
    }
    return view.checkedImpl();
}

test "paint adapter forwards context and user data and propagates callback errors" {
    const std = @import("std");
    const State = struct {
        calls: u32 = 0,
        fail: bool = false,

        fn draw(user_data: ?*anyopaque, context: *DrawContext) !void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.calls < 2);
            try std.testing.expectEqual(@as(f32, 2), context.content_scale);
            self.calls += 1;
            if (self.fail) return error.CallbackFailed;
        }
    };
    var state: State = .{};
    // The callback only accesses scale; no GPU resource is needed for this test.
    var context: DrawContext = undefined;
    context.content_scale = 2;
    const paint = paintCallback(&state, State.draw);
    try std.testing.expectEqual(@import("render").Extension.knots, paint.extension);
    try paint.callback(paint.user_data, &context);
    try std.testing.expectEqual(@as(u32, 1), state.calls);
    state.fail = true;
    try std.testing.expectError(error.CallbackFailed, paint.callback(paint.user_data, &context));
    try std.testing.expectEqual(@as(u32, 2), state.calls);
}
