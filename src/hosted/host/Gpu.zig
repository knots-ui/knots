const std = @import("std");
const impl = @import("gpu_impl");
const abi = @import("abi");
const Windows = @import("Windows.zig");
const Reply = @import("Reply.zig");

const Gpu = @This();

gpa: std.mem.Allocator,
device: ?*impl.Device = null,
buffers: Pool(impl.Buffer, abi.Buffer) = .{},
textures: Pool(impl.Texture, abi.Texture) = .{},
samplers: Pool(impl.Sampler, abi.Sampler) = .{},
pipelines: Pool(impl.Pipeline, abi.Pipeline) = .{},
bind_groups: Pool(impl.BindGroup, abi.BindGroup) = .{},
frames: Pool(Frame, abi.Frame) = .{},

const Frame = struct {
    frame: impl.Frame,
    context: ?impl.Frame.Context = null,
    pass: ?impl.RenderPass = null,

    pub fn deinit(self: *Frame) void {
        if (self.pass) |*active| active.end();
        self.frame.deinit();
    }
};

pub fn deinit(self: *Gpu) void {
    self.releaseGuest();
    self.buffers.deinit(self.gpa);
    self.textures.deinit(self.gpa);
    self.samplers.deinit(self.gpa);
    self.pipelines.deinit(self.gpa);
    self.bind_groups.deinit(self.gpa);
    self.frames.deinit(self.gpa);
    if (self.device) |device| {
        device.deinit();
        self.gpa.destroy(device);
    }
}

pub fn releaseGuest(self: *Gpu) void {
    if (self.device) |device| device.waitIdle() catch {};
    self.frames.clear(self.gpa);
    self.bind_groups.clear(self.gpa);
    self.pipelines.clear(self.gpa);
    self.samplers.clear(self.gpa);
    self.textures.clear(self.gpa);
    self.buffers.clear(self.gpa);
}

pub fn destroySurface(self: *Gpu, entry: *Windows.Entry) void {
    const surface = entry.surface orelse return;
    if (self.device) |device| device.waitIdle() catch {};
    surface.deinit();
    self.gpa.destroy(surface);
    entry.surface = null;
}

pub fn call(self: *Gpu, request: abi.GpuCall, windows: *Windows, reply: *Reply) !void {
    switch (request) {
        inline else => |args, tag| try reply.ok(abi.GpuCall.Result(tag), try self.answer(tag, args, windows)),
    }
}

fn answer(self: *Gpu, comptime tag: std.meta.Tag(abi.GpuCall), args: @FieldType(abi.GpuCall, @tagName(tag)), windows: *Windows) !abi.GpuCall.Result(tag) {
    switch (tag) {
        .device => {
            const device = self.device orelse device: {
                const device = try self.gpa.create(impl.Device);
                errdefer self.gpa.destroy(device);
                device.* = try impl.Device.init(self.gpa, (try windows.get(args)).window.getWindowHandle());
                self.device = device;
                break :device device;
            };
            return .{ .surface_format = device.surfaceFormat(), .surface_is_srgb = device.surfaceIsSrgb() };
        },
        .wait_idle => try (try self.getDevice()).waitIdle(),
        .create_buffer => return self.buffers.add(self.gpa, try (try self.getDevice()).createBuffer(args)),
        .resize_buffer => try (try self.buffers.get(args[0])).resize(@intCast(args[1])),
        .create_texture => return self.textures.add(self.gpa, try (try self.getDevice()).createTexture(args)),
        .write_texture => try (try self.textures.get(args.texture)).write(args.data.ptr, args.data.len, args.x, args.y, args.width, args.height, args.bytes_per_row),
        .create_sampler => return self.samplers.add(self.gpa, try (try self.getDevice()).createSampler(args)),
        .create_pipeline => return self.pipelines.add(self.gpa, try (try self.getDevice()).createPipeline(args)),
        .create_bind_group => {
            var entries: [16]impl.BindGroup.BindingEntry = undefined;
            return self.bind_groups.add(self.gpa, try (try self.getDevice()).createBindGroup(try self.bindGroupDesc(args, &entries)));
        },
        .configure_surface => {
            const entry = try windows.get(args[0]);
            if (entry.surface) |surface| return surface.reconfigure(args[1]);
            const surface = try self.gpa.create(impl.Surface);
            errdefer self.gpa.destroy(surface);
            surface.* = try impl.Surface.init(try self.getDevice(), entry.window.getWindowHandle(), args[1]);
            entry.surface = surface;
        },
        .resize_surface => try (try surfaceOf(windows, args[0])).resize(args[1], args[2]),
        .present_modes => return (try surfaceOf(windows, args)).supportedPresentModes(),
        .create_frame => return self.frames.add(self.gpa, .{ .frame = try impl.Frame.create(try surfaceOf(windows, args)) }),
        .upload_slot_count => return (try self.frames.get(args)).frame.uploadSlotCount(),
        .begin_frame => {
            const frame = try self.frames.get(args);
            frame.context = try frame.frame.begin();
            return frame.context.?.upload_slot;
        },
        .begin_render_pass => {
            const frame = try self.frames.get(args[0]);
            if (frame.pass != null) return error.RenderPassActive;
            const context = if (frame.context) |*context| context else return error.FrameNotBegun;
            frame.pass = try context.beginRenderPass(try self.renderPassDesc(args[1]));
        },
        .submit => {
            const frame = try self.frames.get(args);
            defer frame.context = null;
            const context = if (frame.context) |*context| context else return error.FrameNotBegun;
            try context.submit();
        },
        .wait_for_completion => try (try self.frames.get(args)).frame.waitForCompletion(),
    }
}

pub fn command(self: *Gpu, request: abi.GpuCommand, windows: *Windows) !void {
    switch (request) {
        .destroy => |object| switch (object) {
            .buffer => |handle| try self.buffers.destroy(self.gpa, handle),
            .texture => |handle| try self.textures.destroy(self.gpa, handle),
            .sampler => |handle| try self.samplers.destroy(self.gpa, handle),
            .pipeline => |handle| try self.pipelines.destroy(self.gpa, handle),
            .bind_group => |handle| try self.bind_groups.destroy(self.gpa, handle),
            .frame => |handle| try self.frames.destroy(self.gpa, handle),
            .surface => |handle| self.destroySurface(try windows.get(handle)),
        },
        .write_buffer => |args| (try self.buffers.get(args[0])).loadOffset(u8, args[2], @intCast(args[1])),
        .prepare_resize => |handle| (try self.frames.get(handle)).frame.prepareResize(),
        .end_render_pass => |handle| {
            const frame = try self.frames.get(handle);
            if (frame.pass) |*active| active.end();
            frame.pass = null;
        },
        .bind_pipeline => |args| (try self.renderPass(args[0])).bindPipeline(try self.pipelines.get(args[1])),
        .set_bind_group => |args| (try self.renderPass(args[0])).setBindGroup(args[1], try self.bind_groups.get(args[2])),
        .set_vertex_buffer => |args| (try self.renderPass(args[0])).setVertexBuffer(args[1], try self.buffers.get(args[2]), @intCast(args[3]), @intCast(args[4])),
        .set_index_buffer => |args| (try self.renderPass(args[0])).setIndexBuffer(try self.buffers.get(args[1]), @intCast(args[2]), @intCast(args[3])),
        .set_scissor_rect => |args| (try self.renderPass(args[0])).setScissorRect(args[1], args[2], args[3], args[4]),
        .set_viewport => |args| (try self.renderPass(args[0])).setViewport(args[1], args[2], args[3], args[4]),
        .draw => |args| (try self.renderPass(args[0])).draw(args[1], args[2], args[3], args[4]),
        .draw_indexed => |args| (try self.renderPass(args[0])).drawIndexed(args[1], args[2], args[3], args[4], args[5]),
    }
}

fn getDevice(self: *Gpu) !*impl.Device {
    return self.device orelse error.DeviceLost;
}

fn surfaceOf(windows: *Windows, handle: abi.Window) !*impl.Surface {
    return (try windows.get(handle)).surface orelse error.SurfaceUnavailable;
}

fn renderPass(self: *Gpu, handle: abi.Frame) !*impl.RenderPass {
    const frame = try self.frames.get(handle);
    return if (frame.pass) |*value| value else error.NoRenderPass;
}

fn bindGroupDesc(self: *Gpu, desc: abi.BindGroupDesc, entries: []impl.BindGroup.BindingEntry) !impl.BindGroup.Desc {
    if (desc.entries.len > entries.len) return error.TooManyBindings;
    for (desc.entries, entries[0..desc.entries.len]) |entry, *out| out.* = .{
        .binding = entry.binding,
        .resource = switch (entry.resource) {
            .buffer => |binding| .{ .buffer = try self.bufferBinding(binding) },
            .read_only_storage_buffer => |binding| .{ .read_only_storage_buffer = try self.bufferBinding(binding) },
            .texture_view => |handle| .{ .texture_view = try self.textures.get(handle) },
            .sampler => |handle| .{ .sampler = try self.samplers.get(handle) },
        },
    };
    return .{
        .label = desc.label,
        .pipeline = try self.pipelines.get(desc.pipeline),
        .layout_index = desc.layout_index,
        .entries = entries[0..desc.entries.len],
    };
}

fn bufferBinding(self: *Gpu, binding: abi.BufferBinding) !impl.BindGroup.BufferBinding {
    return .{ .buffer = try self.buffers.get(binding.buffer), .offset = binding.offset, .size = binding.size };
}

fn renderPassDesc(self: *Gpu, desc: abi.RenderPassDesc) !impl.RenderPass.Desc {
    return .{
        .label = desc.label,
        .color_attachment = .{
            .load_op = loadOp(desc.color.load_op),
            .store_op = storeOp(desc.color.store_op),
            .clear_color = desc.color.clear_color,
            .target = if (desc.color.target) |handle| try self.textures.get(handle) else null,
        },
        .depth_attachment = if (desc.depth) |depth| .{
            .load_op = loadOp(depth.load_op),
            .store_op = storeOp(depth.store_op),
            .clear_value = depth.clear_value,
            .target = try self.textures.get(depth.target),
        } else null,
    };
}

fn loadOp(op: abi.LoadOp) impl.RenderPass.LoadOp {
    return switch (op) {
        .clear => .clear,
        .load => .load,
    };
}

fn storeOp(op: abi.StoreOp) impl.RenderPass.StoreOp {
    return switch (op) {
        .store => .store,
        .discard => .discard,
    };
}

/// Each object has its own allocation: some point into themselves.
fn Pool(comptime T: type, comptime Handle: type) type {
    return struct {
        objects: std.ArrayList(?*T) = .empty,
        free: std.ArrayList(u32) = .empty,

        const Self = @This();

        fn add(self: *Self, gpa: std.mem.Allocator, value: T) !Handle {
            var owned = value;
            errdefer owned.deinit();
            const object = try gpa.create(T);
            errdefer gpa.destroy(object);
            try self.free.ensureTotalCapacity(gpa, self.objects.items.len + 1);
            const index = self.free.pop() orelse index: {
                try self.objects.append(gpa, null);
                break :index self.objects.items.len - 1;
            };
            object.* = owned;
            self.objects.items[index] = object;
            return @fromBackingInt(@intCast(index));
        }

        fn get(self: *Self, handle: Handle) !*T {
            const index = @backingInt(handle);
            if (index >= self.objects.items.len) return error.InvalidHandle;
            return self.objects.items[index] orelse error.InvalidHandle;
        }

        fn destroy(self: *Self, gpa: std.mem.Allocator, handle: Handle) !void {
            const object = try self.get(handle);
            object.deinit();
            gpa.destroy(object);
            self.objects.items[@backingInt(handle)] = null;
            self.free.appendAssumeCapacity(@backingInt(handle));
        }

        fn clear(self: *Self, gpa: std.mem.Allocator) void {
            for (self.objects.items) |slot| if (slot) |object| {
                object.deinit();
                gpa.destroy(object);
            };
            self.objects.clearRetainingCapacity();
            self.free.clearRetainingCapacity();
        }

        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.clear(gpa);
            self.objects.deinit(gpa);
            self.free.deinit(gpa);
        }
    };
}
