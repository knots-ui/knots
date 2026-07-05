const js = @import("js-bridge");
const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");
const webgpu = @import("webgpu.zig");

const RenderPass = @This();

pass: js.Value,

pub const LoadOp = enum { clear, load };
pub const StoreOp = enum { store, discard };

pub const ColorAttachment = struct {
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    target: ?*Texture = null,
};

pub const Desc = struct {
    label: []const u8 = "",
    color_attachment: ColorAttachment = .{},
};

pub fn create(encoder: js.Value, view: js.Value, desc: Desc) !RenderPass {
    const attachment = try colorAttachment(view, desc.color_attachment);
    defer attachment.release();

    const attachments = try js.newArray();
    defer attachments.release();
    try attachments.push(js.Arg.value(attachment));

    var pass_desc = try js.ObjectBuilder.init();
    defer pass_desc.finish().release();
    try pass_desc.set("label", js.Arg.string(if (desc.label.len > 0) desc.label else "render_pass"));
    try pass_desc.set("colorAttachments", js.Arg.value(attachments));

    return .{ .pass = try encoder.call("beginRenderPass", &.{js.Arg.value(pass_desc.value)}) };
}

pub fn end(self: *RenderPass) void {
    self.pass.callVoid("end", &.{}) catch |err| webgpu.recordError(err);
    self.pass.release();
}

pub fn bindPipeline(self: *RenderPass, pipeline: *const Pipeline) void {
    self.pass.callVoid("setPipeline", &.{js.Arg.value(pipeline.render_pipeline)}) catch |err| webgpu.recordError(err);
}

pub fn setBindGroup(self: *RenderPass, group_index: u32, group: *const BindGroup) void {
    self.pass.callVoid("setBindGroup", &.{
        js.Arg.u32(group_index),
        js.Arg.value(group.bind_group),
    }) catch |err| webgpu.recordError(err);
}

pub fn setVertexBuffer(self: *RenderPass, slot: u32, buf: *const Buffer, offset: usize, size: usize) void {
    self.pass.callVoid("setVertexBuffer", &.{
        js.Arg.u32(slot),
        js.Arg.value(buf.buffer),
        js.Arg.usize(offset),
        js.Arg.usize(size),
    }) catch |err| webgpu.recordError(err);
}

pub fn setIndexBuffer(self: *RenderPass, buf: *const Buffer, offset: usize, size: usize) void {
    self.pass.callVoid("setIndexBuffer", &.{
        js.Arg.value(buf.buffer),
        js.Arg.string("uint32"),
        js.Arg.usize(offset),
        js.Arg.usize(size),
    }) catch |err| webgpu.recordError(err);
}

pub fn setScissorRect(self: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
    self.pass.callVoid("setScissorRect", &.{
        js.Arg.u32(x),
        js.Arg.u32(y),
        js.Arg.u32(w),
        js.Arg.u32(h),
    }) catch |err| webgpu.recordError(err);
}

pub fn drawIndexed(self: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    self.pass.callVoid("drawIndexed", &.{
        js.Arg.u32(index_count),
        js.Arg.u32(instance_count),
        js.Arg.u32(first_index),
        js.Arg.i32(base_vertex),
        js.Arg.u32(first_instance),
    }) catch |err| webgpu.recordError(err);
}

fn colorAttachment(view: js.Value, desc: ColorAttachment) !js.Value {
    var out = try js.ObjectBuilder.init();
    try out.set("view", js.Arg.value(view));
    try out.set("loadOp", js.Arg.string(switch (desc.load_op) {
        .clear => "clear",
        .load => "load",
    }));
    try out.set("storeOp", js.Arg.string(switch (desc.store_op) {
        .store => "store",
        .discard => "discard",
    }));

    const clear = try clearValue(desc.clear_color);
    defer clear.release();
    try out.set("clearValue", js.Arg.value(clear));
    return out.finish();
}

fn clearValue(color: [4]f32) !js.Value {
    var out = try js.ObjectBuilder.init();
    try out.set("r", js.Arg.f64(color[0]));
    try out.set("g", js.Arg.f64(color[1]));
    try out.set("b", js.Arg.f64(color[2]));
    try out.set("a", js.Arg.f64(color[3]));
    return out.finish();
}
