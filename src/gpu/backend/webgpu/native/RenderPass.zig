const wgpu = @import("wgpu");
const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");

const RenderPass = @This();

pass: wgpu.RenderPassEncoder,

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

pub fn create(encoder: wgpu.CommandEncoder, view: wgpu.TextureView, desc: Desc) !RenderPass {
    const ca = desc.color_attachment;

    const pass = try encoder.beginRenderPass(.{
        .label = if (desc.label.len > 0) desc.label else "render_pass",
        .color_attachments = &.{
            .{
                .view = view,
                .load_op = switch (ca.load_op) {
                    .clear => .clear,
                    .load => .load,
                },
                .store_op = switch (ca.store_op) {
                    .store => .store,
                    .discard => .discard,
                },
                .clear_value = .{
                    .r = ca.clear_color[0],
                    .g = ca.clear_color[1],
                    .b = ca.clear_color[2],
                    .a = ca.clear_color[3],
                },
            },
        },
    });

    return .{
        .pass = pass,
    };
}

pub fn end(self: *RenderPass) void {
    self.pass.end();
    self.pass.deinit();
}

pub fn bindPipeline(self: *RenderPass, pipeline: *const Pipeline) void {
    self.pass.setPipeline(pipeline.render_pipeline);
}

pub fn setBindGroup(self: *RenderPass, group_index: u32, group: *const BindGroup) void {
    self.pass.setBindGroup(group_index, group.bind_group, &.{});
}

pub fn setVertexBuffer(self: *RenderPass, slot: u32, buf: *const Buffer, offset: usize, size: usize) void {
    self.pass.setVertexBuffer(slot, buf.buffer, offset, size);
}

pub fn setIndexBuffer(self: *RenderPass, buf: *const Buffer, offset: usize, size: usize) void {
    self.pass.setIndexBuffer(buf.buffer, .uint32, offset, size);
}

pub fn setScissorRect(self: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
    self.pass.setScissorRect(x, y, w, h);
}

pub fn drawIndexed(self: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    self.pass.drawIndexed(index_count, instance_count, first_index, base_vertex, first_instance);
}
