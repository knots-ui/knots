const std = @import("std");
const gpu = @import("gpu");
const gpu_impl = @import("gpu_impl");

const Texture = @This();

allocator: std.mem.Allocator,
device: *gpu_impl.Device,
texture: gpu_impl.Texture,
sampler: gpu_impl.Sampler,
bind_group: gpu_impl.BindGroup,
width: u32,
height: u32,
format: gpu.Texture.Format,

pub fn create(
    allocator: std.mem.Allocator,
    device: *gpu_impl.Device,
    pipeline: *const gpu_impl.Pipeline,
    width: u32,
    height: u32,
    format: gpu.Texture.Format,
    filter: gpu.Sampler.FilterMode,
    label: []const u8,
) !*Texture {
    if (width == 0 or height == 0) return error.InvalidTextureWrite;

    var texture = try device.createTexture(.{
        .width = width,
        .height = height,
        .format = format,
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .label = label,
    });
    errdefer texture.deinit();

    var sampler = try device.createSampler(.{
        .mag_filter = filter,
        .min_filter = filter,
        .label = label,
    });
    errdefer sampler.deinit();

    var bind_group = try device.createBindGroup(.{
        .label = label,
        .pipeline = pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &texture } },
            .{ .binding = 1, .resource = .{ .sampler = &sampler } },
        },
    });
    errdefer bind_group.deinit();

    const self = try allocator.create(Texture);
    self.* = .{
        .allocator = allocator,
        .device = device,
        .texture = texture,
        .sampler = sampler,
        .bind_group = bind_group,
        .width = width,
        .height = height,
        .format = format,
    };
    return self;
}

/// The texture must no longer be referenced by any future draw list.
pub fn destroy(self: *Texture) void {
    self.device.waitIdle() catch {};
    self.destroyAfterWait();
}

pub fn destroyAfterWait(self: *Texture) void {
    self.bind_group.deinit();
    self.texture.deinit();
    self.sampler.deinit();
    self.allocator.destroy(self);
}

pub fn write(self: *Texture, data: []const u8, width: u32, height: u32, bytes_per_row: ?u32) !void {
    if (width > self.width or height > self.height)
        return error.InvalidTextureWrite;

    const required = try requiredBytes(width, height, self.format.bytesPerPixel(), bytes_per_row);
    if (data.len < required)
        return error.InvalidTextureWrite;

    try self.texture.write(data.ptr, data.len, 0, 0, width, height, bytes_per_row);
}

pub fn isReady(self: *const Texture) bool {
    return self.texture.isReady();
}

fn requiredBytes(width: u32, height: u32, bpp: usize, bytes_per_row: ?u32) !usize {
    if (width == 0 or height == 0)
        return error.InvalidTextureWrite;

    const row_bytes = try std.math.mul(usize, @as(usize, width), bpp);
    if (bytes_per_row) |stride_u32| {
        const stride: usize = stride_u32;

        if (stride < row_bytes or stride % bpp != 0)
            return error.InvalidTextureWrite;

        const prefix = try std.math.mul(usize, @as(usize, height - 1), stride);
        return std.math.add(usize, prefix, row_bytes);
    }
    return std.math.mul(usize, row_bytes, @as(usize, height));
}
