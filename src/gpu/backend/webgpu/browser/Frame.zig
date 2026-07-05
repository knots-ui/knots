const std = @import("std");
const js = @import("js-bridge");
const Surface = @import("Surface.zig");
const RenderPass = @import("RenderPass.zig");
const gpu = @import("gpu");
const webgpu = @import("webgpu.zig");

const Frame = @This();

surface_texture: ?js.Value,
view: ?js.Value,
encoder: ?js.Value,
surface: *Surface,

pub const ContextHandle = struct {
    frame: *Frame,
    upload_slot: u32,

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
    return .{ .frame = self, .upload_slot = 0 };
}

pub fn uploadSlotCount(_: *const Frame) u32 {
    return 1;
}

pub fn prepareResize(self: *Frame) void {
    self.clearFrameState();
}

pub fn deinit(self: *Frame) void {
    self.clearFrameState();
}

fn beginRenderPass(self: *Frame, desc: RenderPass.Desc) !RenderPass {
    if (self.encoder == null) {
        var encoder_desc = try js.ObjectBuilder.init();
        defer encoder_desc.finish().release();
        try encoder_desc.set("label", js.Arg.string("frame_encoder"));
        self.encoder = try self.surface.device.device.call("createCommandEncoder", &.{js.Arg.value(encoder_desc.value)});
    }

    const target_view = if (desc.color_attachment.target) |target|
        target.view
    else
        try self.surfaceView();

    return RenderPass.create(self.encoder.?, target_view, desc);
}

fn submit(self: *Frame) !void {
    defer self.clearFrameState();
    if (webgpu.takeError()) |err| return err;
    const encoder = self.encoder orelse return;

    var finish_desc = try js.ObjectBuilder.init();
    defer finish_desc.finish().release();
    const command = try encoder.call("finish", &.{js.Arg.value(finish_desc.value)});
    defer command.release();

    const commands = try js.newArray();
    defer commands.release();
    try commands.push(js.Arg.value(command));
    try self.surface.device.queue.callVoid("submit", &.{js.Arg.value(commands)});
    if (webgpu.takeError()) |err| return err;
}

fn submitReadback(_: *Frame, _: std.mem.Allocator) !gpu.SurfaceReadback {
    return error.SurfaceReadbackUnsupported;
}

fn surfaceView(self: *Frame) !js.Value {
    if (self.view) |view| return view;

    const texture = try self.surface.context.call("getCurrentTexture", &.{});
    errdefer texture.release();

    var view_desc = try js.ObjectBuilder.init();
    defer view_desc.finish().release();
    try view_desc.set("format", js.Arg.string(webgpu.formatName(self.surface.device.surface_format)));
    const view = try texture.call("createView", &.{js.Arg.value(view_desc.value)});

    self.surface_texture = texture;
    self.view = view;
    return view;
}

fn clearFrameState(self: *Frame) void {
    if (self.encoder) |encoder| encoder.release();
    self.encoder = null;
    if (self.view) |view| view.release();
    self.view = null;
    if (self.surface_texture) |texture| texture.release();
    self.surface_texture = null;
}

pub fn waitForCompletion(_: *Frame) !void {}
