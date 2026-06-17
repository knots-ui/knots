const std = @import("std");
const wgpu = @import("wgpu");
const GpuContext = @import("Context.zig");
const RenderPass = @import("RenderPass.zig");

const Frame = @This();

surface_texture: ?wgpu.Texture,
view: ?wgpu.TextureView,
encoder: ?wgpu.CommandEncoder,
ctx: *GpuContext,

pub const ContextHandle = struct {
    frame: *Frame,
    upload_slot: u32,

    pub fn beginRenderPass(self: *ContextHandle, desc: RenderPass.Desc) !RenderPass {
        return self.frame.beginRenderPass(desc);
    }

    pub fn submit(self: *ContextHandle) !void {
        return self.frame.submit();
    }
};

pub const Context = ContextHandle;

pub fn create(_: std.mem.Allocator, ctx: *GpuContext) !Frame {
    return .{
        .surface_texture = null,
        .view = null,
        .encoder = null,
        .ctx = ctx,
    };
}

pub fn begin(self: *Frame) !ContextHandle {
    _ = self.ctx.device.poll(true);
    return .{ .frame = self, .upload_slot = 0 };
}

pub fn uploadSlotCount(_: *const Frame) u32 {
    return 1;
}

pub fn prepareResize(self: *Frame) void {
    if (self.view) |v| v.deinit();
    self.view = null;
    if (self.surface_texture) |t| t.deinit();
    self.surface_texture = null;
    _ = self.ctx.device.poll(true);
}

pub fn deinit(self: *Frame) void {
    if (self.encoder) |e| e.deinit();
    if (self.view) |v| v.deinit();
    if (self.surface_texture) |t| t.deinit();
}

fn beginRenderPass(self: *Frame, desc: RenderPass.Desc) !RenderPass {
    if (self.encoder == null) {
        self.encoder = try self.ctx.device.createCommandEncoder(.{ .label = "frame_encoder" });
    }

    const target_view = if (desc.color_attachment.target) |target| blk: {
        break :blk target.view;
    } else blk: {
        if (self.surface_texture == null) {
            self.surface_texture = self.ctx.surface.getCurrentTexture() catch |err| switch (err) {
                error.CurrentTextureOutdated, error.CurrentTextureLost => retry: {
                    _ = self.ctx.device.poll(true);
                    self.ctx.reconfigureSurface(self.ctx.surface_width, self.ctx.surface_height);
                    break :retry try self.ctx.surface.getCurrentTexture();
                },
                else => return err,
            };
            self.view = try self.surface_texture.?.createView(.{ .format = self.ctx.surface_format });
        }
        break :blk self.view.?;
    };

    return RenderPass.create(self.ctx.allocator, self.encoder.?, target_view, desc);
}

fn submit(self: *Frame) !void {
    const cmd = try self.encoder.?.finish(.{});
    self.ctx.queue.submitCommands(&.{cmd});
    try self.ctx.surface.present();

    if (self.encoder) |e| e.deinit();
    self.encoder = null;
    if (self.view) |v| v.deinit();
    self.view = null;
    if (self.surface_texture) |t| t.deinit();
    self.surface_texture = null;
}

pub fn waitForCompletion(self: *Frame) !void {
    _ = self.ctx.device.poll(true);
}
