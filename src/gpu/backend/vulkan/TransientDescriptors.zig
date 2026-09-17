const std = @import("std");
const vk = @import("vk");
const Device = @import("Device.zig");

const TransientDescriptors = @This();

pools: std.ArrayList(vk.DescriptorPool) = .empty,
current: usize = 0,

pub fn allocate(self: *TransientDescriptors, device: *Device, layout: vk.DescriptorSetLayout) !vk.DescriptorSet {
    std.debug.assert(layout != .null_handle);
    std.debug.assert(self.current <= self.pools.items.len);
    while (self.current < self.pools.items.len) : (self.current += 1) {
        var sets: [1]vk.DescriptorSet = undefined;
        device.vkd.allocateDescriptorSets(device.device, &.{
            .descriptor_pool = self.pools.items[self.current],
            .descriptor_set_count = 1,
            .p_set_layouts = &.{layout},
        }, &sets) catch |err| switch (err) {
            error.OutOfPoolMemory, error.FragmentedPool => continue,
            else => return err,
        };
        return sets[0];
    }

    const pool = try Device.createDescriptorPool(device.vkd, device.device, false);
    errdefer device.vkd.destroyDescriptorPool(device.device, pool, null);
    var sets: [1]vk.DescriptorSet = undefined;
    try device.vkd.allocateDescriptorSets(device.device, &.{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = &.{layout},
    }, &sets);
    try self.pools.append(device.allocator, pool);
    device.setDebugName(.descriptor_pool, @backingInt(pool), "frame_descriptors");
    return sets[0];
}

pub fn reset(self: *TransientDescriptors, device: *Device) !void {
    std.debug.assert(self.current <= self.pools.items.len);
    for (self.pools.items) |pool| {
        std.debug.assert(pool != .null_handle);
        try device.vkd.resetDescriptorPool(device.device, pool, .{});
    }
    self.current = 0;
}

pub fn deinit(self: *TransientDescriptors, device: *Device) void {
    std.debug.assert(self.current <= self.pools.items.len);
    for (self.pools.items) |pool| {
        std.debug.assert(pool != .null_handle);
        device.vkd.destroyDescriptorPool(device.device, pool, null);
    }
    self.pools.deinit(device.allocator);
}
