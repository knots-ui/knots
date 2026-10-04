const std = @import("std");
const wgpu = @import("wgpu");
const Surface = @import("Surface.zig");
const RenderPass = @import("RenderPass.zig");
const BindGroup = @import("BindGroup.zig");
const gpu = @import("gpu");

const Frame = @This();
const is_browser_wasm = @import("builtin").cpu.arch.isWasm();

surface_texture: ?wgpu.Texture,
view: ?wgpu.TextureView,
encoder: ?wgpu.CommandEncoder,
surface: *Surface,

pub const ContextHandle = struct {
    frame: *Frame,
    upload_slot: u32,

    pub fn createBindGroup(self: *const ContextHandle, desc: BindGroup.Desc) !BindGroup {
        return self.frame.surface.device.createBindGroup(desc);
    }

    pub fn beginRenderPass(self: *ContextHandle, desc: RenderPass.Desc) !RenderPass {
        return self.frame.beginRenderPass(desc);
    }

    pub fn submit(self: *ContextHandle) !void {
        try self.frame.submit();
    }

    pub fn submitReadback(self: *ContextHandle, allocator: std.mem.Allocator) !gpu.SurfaceReadback {
        return self.frame.submitReadback(allocator);
    }
};

pub const Context = ContextHandle;

pub fn create(surface: *Surface) !Frame {
    return .{
        .surface_texture = null,
        .view = null,
        .encoder = null,
        .surface = surface,
    };
}

pub fn begin(self: *Frame) !ContextHandle {
    // A recoverable surface error can abandon an encoded offscreen pass.
    // Never append the next frame to that unsubmitted command encoder.
    self.clearFrameState();
    _ = self.surface.device.device.poll(true);
    return .{ .frame = self, .upload_slot = 0 };
}

pub fn uploadSlotCount(_: *const Frame) u32 {
    return 1;
}

pub fn prepareResize(self: *Frame) void {
    self.clearFrameState();
    _ = self.surface.device.device.poll(true);
}

pub fn deinit(self: *Frame) void {
    self.clearFrameState();
}

fn clearFrameState(self: *Frame) void {
    if (self.encoder) |encoder| encoder.deinit();
    self.encoder = null;
    if (self.view) |view| view.deinit();
    self.view = null;
    if (self.surface_texture) |texture| texture.deinit();
    self.surface_texture = null;
    std.debug.assert(self.encoder == null);
    std.debug.assert(self.surface_texture == null);
}

fn beginRenderPass(self: *Frame, desc: RenderPass.Desc) !RenderPass {
    errdefer self.clearFrameState();
    if (self.encoder == null) {
        self.encoder = try self.surface.device.device.createCommandEncoder(.{ .label = "frame_encoder" });
    }

    const target_view = if (desc.color_attachment.target) |target| blk: {
        break :blk target.view;
    } else blk: {
        if (self.surface_texture == null) {
            self.surface_texture = switch (self.surface.surface.getCurrentTexture()) {
                .success, .suboptimal => |texture| texture,
                .outdated, .lost => retry: {
                    _ = self.surface.device.device.poll(true);
                    self.surface.configure(self.surface.surface_width, self.surface.surface_height);
                    break :retry switch (self.surface.surface.getCurrentTexture()) {
                        .success, .suboptimal => |texture| texture,
                        .timeout, .occluded, .outdated => return error.SurfaceUnavailable,
                        .lost => return error.SurfaceLost,
                        .validation => return error.BackendFailure,
                    };
                },
                .timeout, .occluded => return error.SurfaceUnavailable,
                .validation => return error.BackendFailure,
            };
            self.view = try self.surface_texture.?.createView(.{ .format = self.surface.device.surface_format });
        }
        break :blk self.view.?;
    };

    return RenderPass.create(self.encoder.?, target_view, desc);
}

fn submit(self: *Frame) !void {
    defer self.clearFrameState();

    const cmd = try self.encoder.?.finish(.{});
    self.surface.device.queue.submitCommands(&.{cmd});
    try self.surface.surface.present();
}

fn submitReadback(self: *Frame, allocator: std.mem.Allocator) !gpu.SurfaceReadback {
    if (comptime is_browser_wasm) {
        return error.SurfaceReadbackUnsupported;
    }
    return self.submitReadbackCopy(allocator);
}

fn submitReadbackCopy(self: *Frame, allocator: std.mem.Allocator) !gpu.SurfaceReadback {
    errdefer {
        if (self.encoder) |e| e.deinit();
        self.encoder = null;
        if (self.view) |v| v.deinit();
        self.view = null;
        if (self.surface_texture) |t| t.deinit();
        self.surface_texture = null;
    }

    if (!self.surface.surface_copy_src) return error.SurfaceReadbackUnsupported;
    if (self.encoder == null or self.surface_texture == null) return error.SurfaceReadbackUnavailable;

    const width = self.surface.surface_width;
    const height = self.surface.surface_height;
    const format = self.surface.format();
    const row_bytes = try readbackRowBytes(width, format);
    const padded_row_bytes = (std.math.add(usize, row_bytes, 255) catch return error.SurfaceReadbackTooLarge) & ~@as(usize, 255);
    const readback_size = std.math.mul(usize, padded_row_bytes, @as(usize, height)) catch return error.SurfaceReadbackTooLarge;
    var readback_buffer = try self.surface.device.device.createBuffer(.{
        .label = "surface_readback",
        .size = readback_size,
        .usage = .{ .copy_dst = true, .map_read = true },
    });
    defer readback_buffer.deinit();

    const c = wgpu.c;
    c.wgpuCommandEncoderCopyTextureToBuffer(
        self.encoder.?.encoder,
        &.{
            .texture = self.surface_texture.?.texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        },
        &.{
            .buffer = readback_buffer.buffer,
            .layout = .{ .offset = 0, .bytesPerRow = @intCast(padded_row_bytes), .rowsPerImage = height },
        },
        &.{ .width = width, .height = height, .depthOrArrayLayers = 1 },
    );
    try self.submit();

    const MapState = struct {
        done: std.atomic.Value(bool) = .init(false),
        success: std.atomic.Value(bool) = .init(false),
    };
    var state: MapState = .{};
    _ = c.wgpuBufferMapAsync(
        readback_buffer.buffer,
        c.WGPUMapMode_Read,
        0,
        readback_size,
        .{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowSpontaneous,
            .callback = struct {
                fn callback(status: c.WGPUMapAsyncStatus, _: c.WGPUStringView, userdata: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                    const map_state: *MapState = @ptrCast(@alignCast(userdata.?));
                    map_state.success.store(status == c.WGPUMapAsyncStatus_Success, .monotonic);
                    map_state.done.store(true, .release);
                }
            }.callback,
            .userdata1 = &state,
            .userdata2 = null,
        },
    );
    while (!state.done.load(.acquire)) _ = self.surface.device.device.poll(true);
    if (!state.success.load(.monotonic)) return error.SurfaceReadbackMapFailed;

    const mapped = readback_buffer.getConstMappedRange(u8, 0, readback_size) orelse return error.SurfaceReadbackMapFailed;
    defer readback_buffer.unmap();
    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .format = format,
        .bytes_per_row = padded_row_bytes,
        .bytes = try allocator.dupe(u8, mapped),
    };
}

fn readbackRowBytes(width: u32, format: gpu.Texture.Format) !usize {
    return std.math.mul(usize, @as(usize, width), gpu.SurfaceReadback.bytesPerPixel(format)) catch error.SurfaceReadbackTooLarge;
}

pub fn waitForCompletion(self: *Frame) !void {
    _ = self.surface.device.device.poll(true);
}
