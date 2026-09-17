const std = @import("std");
const vk = @import("vk");

const MemoryAllocator = @This();

pub const ResourceClass = enum { linear, optimal };
pub const Resource = union(enum) { buffer: vk.Buffer, image: vk.Image };

const host_block_size: vk.DeviceSize = 8 * 1024 * 1024;
const device_block_size: vk.DeviceSize = 32 * 1024 * 1024;

const Range = struct {
    offset: vk.DeviceSize,
    size: vk.DeviceSize,
};

const RangeAllocator = struct {
    free_ranges: std.ArrayList(Range) = .empty,
    allocation_count: usize = 0,

    fn init(allocator: std.mem.Allocator, size: vk.DeviceSize) !RangeAllocator {
        var result: RangeAllocator = .{};
        try result.free_ranges.append(allocator, .{ .offset = 0, .size = size });
        return result;
    }

    fn deinit(self: *RangeAllocator, allocator: std.mem.Allocator) void {
        self.free_ranges.deinit(allocator);
    }

    fn allocate(self: *RangeAllocator, allocator: std.mem.Allocator, size: vk.DeviceSize, alignment: vk.DeviceSize) !?vk.DeviceSize {
        std.debug.assert(size != 0);
        std.debug.assert(std.math.isPowerOfTwo(alignment));
        for (self.free_ranges.items, 0..) |range, i| {
            const offset = std.mem.alignForward(vk.DeviceSize, range.offset, alignment);
            const padding = offset - range.offset;
            if (padding > range.size or size > range.size - padding) continue;

            try self.free_ranges.ensureTotalCapacity(allocator, self.free_ranges.items.len + self.allocation_count + 2);
            const suffix_offset = offset + size;
            const suffix_size = range.offset + range.size - suffix_offset;
            if (padding != 0 and suffix_size != 0) {
                self.free_ranges.items[i] = .{ .offset = range.offset, .size = padding };
                self.free_ranges.insertAssumeCapacity(i + 1, .{ .offset = suffix_offset, .size = suffix_size });
            } else if (padding != 0) {
                self.free_ranges.items[i].size = padding;
            } else if (suffix_size != 0) {
                self.free_ranges.items[i] = .{ .offset = suffix_offset, .size = suffix_size };
            } else {
                _ = self.free_ranges.orderedRemove(i);
            }
            self.allocation_count += 1;
            return offset;
        }
        return null;
    }

    fn free(self: *RangeAllocator, offset: vk.DeviceSize, size: vk.DeviceSize) void {
        std.debug.assert(self.allocation_count != 0);
        std.debug.assert(size != 0);
        var i: usize = 0;
        while (i < self.free_ranges.items.len and self.free_ranges.items[i].offset < offset) : (i += 1) {}
        self.free_ranges.insertAssumeCapacity(i, .{ .offset = offset, .size = size });
        self.allocation_count -= 1;

        if (i > 0) {
            const previous = &self.free_ranges.items[i - 1];
            if (previous.offset + previous.size == offset) {
                previous.size += size;
                _ = self.free_ranges.orderedRemove(i);
                i -= 1;
            }
        }
        if (i + 1 < self.free_ranges.items.len) {
            const current = &self.free_ranges.items[i];
            const next = self.free_ranges.items[i + 1];
            if (current.offset + current.size == next.offset) {
                current.size += next.size;
                _ = self.free_ranges.orderedRemove(i + 1);
            }
        }
    }
};

pub const Block = struct {
    memory: vk.DeviceMemory,
    memory_type_index: u32,
    class: ResourceClass,
    properties: vk.MemoryPropertyFlags,
    mapped: ?[*]u8,
    ranges: RangeAllocator,
};

pub const Allocation = struct {
    memory: vk.DeviceMemory,
    offset: vk.DeviceSize,
    size: vk.DeviceSize,
    mapped: ?[*]u8,
    block: ?*Block,
    properties: vk.MemoryPropertyFlags,
};

allocator: std.mem.Allocator,
vki: vk.InstanceWrapper,
vkd: vk.DeviceWrapper,
physical_device: vk.PhysicalDevice,
device: vk.Device,
memory_properties: vk.PhysicalDeviceMemoryProperties,
memory_budget: bool,
debug_utils: bool,
block_serial: u32 = 0,
blocks: std.ArrayList(*Block) = .empty,

pub fn init(
    allocator: std.mem.Allocator,
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    memory_budget: bool,
    debug_utils: bool,
) MemoryAllocator {
    return .{
        .allocator = allocator,
        .vki = vki,
        .vkd = vkd,
        .physical_device = physical_device,
        .device = device,
        .memory_properties = vki.getPhysicalDeviceMemoryProperties(physical_device),
        .memory_budget = memory_budget,
        .debug_utils = debug_utils,
    };
}

pub fn deinit(self: *MemoryAllocator) void {
    for (self.blocks.items) |block| {
        if (block.mapped != null) self.vkd.unmapMemory(self.device, block.memory);
        self.vkd.freeMemory(self.device, block.memory, null);
        block.ranges.deinit(self.allocator);
        self.allocator.destroy(block);
    }
    self.blocks.deinit(self.allocator);
}

pub fn allocate(
    self: *MemoryAllocator,
    requirements: vk.MemoryRequirements,
    dedicated_requirements: vk.MemoryDedicatedRequirements,
    resource: Resource,
    class: ResourceClass,
    required: vk.MemoryPropertyFlags,
    preferred: vk.MemoryPropertyFlags,
) !Allocation {
    const memory_type_index = try self.findMemoryType(requirements.memory_type_bits, required, preferred);
    const properties = self.memory_properties.memory_types[memory_type_index].property_flags;
    const default_size = defaultBlockSize(class);
    const dedicated = dedicated_requirements.requires_dedicated_allocation == .true or
        requirements.size > default_size / 2 or
        (dedicated_requirements.prefers_dedicated_allocation == .true and requirements.size >= default_size / 2);
    if (dedicated) return self.allocateDedicated(requirements.size, memory_type_index, properties, resource);

    for (self.blocks.items) |block| {
        if (block.memory_type_index != memory_type_index or block.class != class) continue;
        if (try block.ranges.allocate(self.allocator, requirements.size, requirements.alignment)) |offset| {
            return allocationFromBlock(block, offset, requirements.size);
        }
    }

    const block = try self.createBlock(memory_type_index, properties, class, requirements.size);
    errdefer self.destroyLastBlock(block);
    const offset = try block.ranges.allocate(self.allocator, requirements.size, requirements.alignment);
    std.debug.assert(offset != null);
    return allocationFromBlock(block, offset.?, requirements.size);
}

pub fn free(self: *MemoryAllocator, allocation: Allocation) void {
    if (allocation.block) |block| {
        block.ranges.free(allocation.offset, allocation.size);
        if (block.ranges.allocation_count == 0) {
            std.debug.assert(block.ranges.free_ranges.items.len == 1);
            std.debug.assert(block.ranges.free_ranges.items[0].offset == 0);
            // Keep at most one empty block per memory type and resource class.
            for (self.blocks.items) |other| {
                if (other == block) continue;
                if (other.memory_type_index != block.memory_type_index) continue;
                if (other.class != block.class) continue;
                if (other.ranges.allocation_count == 0) {
                    self.releaseBlock(block);
                    break;
                }
            }
        }
        return;
    }
    if (allocation.mapped != null) self.vkd.unmapMemory(self.device, allocation.memory);
    self.vkd.freeMemory(self.device, allocation.memory, null);
}

pub fn trim(self: *MemoryAllocator) void {
    var index = self.blocks.items.len;
    while (index > 0) {
        index -= 1;
        std.debug.assert(index < self.blocks.items.len);
        const block = self.blocks.items[index];
        std.debug.assert(block.memory != .null_handle);
        if (block.ranges.allocation_count == 0) self.releaseBlock(block);
    }
}

fn releaseBlock(self: *MemoryAllocator, block: *Block) void {
    std.debug.assert(block.ranges.allocation_count == 0);
    std.debug.assert(block.ranges.free_ranges.items.len == 1);
    for (self.blocks.items, 0..) |entry, index| {
        if (entry == block) {
            _ = self.blocks.swapRemove(index);
            if (block.mapped != null) self.vkd.unmapMemory(self.device, block.memory);
            self.vkd.freeMemory(self.device, block.memory, null);
            block.ranges.deinit(self.allocator);
            self.allocator.destroy(block);
            return;
        }
    }
    unreachable;
}

fn findMemoryType(self: *const MemoryAllocator, type_filter: u32, required: vk.MemoryPropertyFlags, preferred: vk.MemoryPropertyFlags) !u32 {
    var fallback: ?u32 = null;
    for (0..self.memory_properties.memory_type_count) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const properties = self.memory_properties.memory_types[i].property_flags;
        if (!properties.contains(required)) continue;
        if (properties.contains(preferred)) return @intCast(i);
        if (fallback == null) fallback = @intCast(i);
    }
    return fallback orelse error.NoSuitableMemoryType;
}

fn allocateDedicated(
    self: *MemoryAllocator,
    size: vk.DeviceSize,
    memory_type_index: u32,
    properties: vk.MemoryPropertyFlags,
    resource: Resource,
) !Allocation {
    const dedicated_info = switch (resource) {
        .buffer => |buffer| vk.MemoryDedicatedAllocateInfo{ .buffer = buffer },
        .image => |image| vk.MemoryDedicatedAllocateInfo{ .image = image },
    };
    const memory = try self.allocateMemory(&.{
        .p_next = &dedicated_info,
        .allocation_size = size,
        .memory_type_index = memory_type_index,
    });
    errdefer self.vkd.freeMemory(self.device, memory, null);
    const mapped: ?[*]u8 = if (properties.host_visible)
        @ptrCast(try self.vkd.mapMemory(self.device, memory, 0, size, .{}))
    else
        null;
    return .{ .memory = memory, .offset = 0, .size = size, .mapped = mapped, .block = null, .properties = properties };
}

fn createBlock(
    self: *MemoryAllocator,
    memory_type_index: u32,
    properties: vk.MemoryPropertyFlags,
    class: ResourceClass,
    required_size: vk.DeviceSize,
) !*Block {
    var size = @max(defaultBlockSize(class), std.mem.alignForward(vk.DeviceSize, required_size, 4096));
    if (self.remainingBudget(memory_type_index)) |remaining| {
        const aligned_remaining = std.mem.alignBackward(vk.DeviceSize, remaining, 4096);
        if (aligned_remaining >= required_size and aligned_remaining < size) size = aligned_remaining;
    }
    const memory = try self.allocateMemory(&.{
        .allocation_size = size,
        .memory_type_index = memory_type_index,
    });
    errdefer self.vkd.freeMemory(self.device, memory, null);
    const mapped: ?[*]u8 = if (properties.host_visible)
        @ptrCast(try self.vkd.mapMemory(self.device, memory, 0, size, .{}))
    else
        null;
    errdefer if (mapped != null) self.vkd.unmapMemory(self.device, memory);

    const block = try self.allocator.create(Block);
    errdefer self.allocator.destroy(block);
    block.* = .{
        .memory = memory,
        .memory_type_index = memory_type_index,
        .class = class,
        .properties = properties,
        .mapped = mapped,
        .ranges = try .init(self.allocator, size),
    };
    errdefer block.ranges.deinit(self.allocator);
    try self.blocks.append(self.allocator, block);
    if (self.debug_utils) {
        var label_buffer: [64]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&label_buffer, "memory_{s}_{d}", .{ @tagName(class), self.block_serial }, 0x00)) |label|
            self.vkd.setDebugUtilsObjectNameEXT(self.device, &.{
                .object_type = .device_memory,
                .object_handle = @backingInt(memory),
                .p_object_name = label,
            }) catch {}
        else |_| {}
        self.block_serial += 1;
    }
    return block;
}

fn allocateMemory(self: *MemoryAllocator, info: *const vk.MemoryAllocateInfo) !vk.DeviceMemory {
    std.debug.assert(info.allocation_size > 0);
    std.debug.assert(info.memory_type_index < self.memory_properties.memory_type_count);
    return self.vkd.allocateMemory(self.device, info, null) catch |err| {
        if (err != error.OutOfDeviceMemory) return err;
        // Release cached blocks before one bounded retry under memory pressure.
        self.trim();
        return self.vkd.allocateMemory(self.device, info, null);
    };
}

fn destroyLastBlock(self: *MemoryAllocator, block: *Block) void {
    std.debug.assert(self.blocks.pop().? == block);
    if (block.mapped != null) self.vkd.unmapMemory(self.device, block.memory);
    self.vkd.freeMemory(self.device, block.memory, null);
    block.ranges.deinit(self.allocator);
    self.allocator.destroy(block);
}

fn remainingBudget(self: *const MemoryAllocator, memory_type_index: u32) ?vk.DeviceSize {
    if (!self.memory_budget) return null;
    var budget = vk.PhysicalDeviceMemoryBudgetPropertiesEXT{ .heap_budget = undefined, .heap_usage = undefined };
    var properties = vk.PhysicalDeviceMemoryProperties2{ .p_next = &budget, .memory_properties = undefined };
    self.vki.getPhysicalDeviceMemoryProperties2(self.physical_device, &properties);
    const heap_index = properties.memory_properties.memory_types[memory_type_index].heap_index;
    return budget.heap_budget[heap_index] -| budget.heap_usage[heap_index];
}

fn allocationFromBlock(block: *Block, offset: vk.DeviceSize, size: vk.DeviceSize) Allocation {
    return .{
        .memory = block.memory,
        .offset = offset,
        .size = size,
        .mapped = if (block.mapped) |mapped| mapped + @as(usize, @intCast(offset)) else null,
        .block = block,
        .properties = block.properties,
    };
}

fn defaultBlockSize(class: ResourceClass) vk.DeviceSize {
    return switch (class) {
        .linear => host_block_size,
        .optimal => device_block_size,
    };
}

test "range allocator aligns, splits, reuses, and coalesces" {
    const allocator = std.testing.allocator;
    var ranges = try RangeAllocator.init(allocator, 256);
    defer ranges.deinit(allocator);

    const a = (try ranges.allocate(allocator, 32, 64)).?;
    const b = (try ranges.allocate(allocator, 48, 16)).?;
    try std.testing.expectEqual(@as(vk.DeviceSize, 0), a);
    try std.testing.expectEqual(@as(vk.DeviceSize, 32), b);

    ranges.free(a, 32);
    const c = (try ranges.allocate(allocator, 16, 16)).?;
    try std.testing.expectEqual(@as(vk.DeviceSize, 0), c);

    ranges.free(c, 16);
    ranges.free(b, 48);
    try std.testing.expectEqual(@as(usize, 1), ranges.free_ranges.items.len);
    try std.testing.expectEqual(Range{ .offset = 0, .size = 256 }, ranges.free_ranges.items[0]);
}

test "range allocator reports fragmentation and exhaustion" {
    const allocator = std.testing.allocator;
    var ranges = try RangeAllocator.init(allocator, 64);
    defer ranges.deinit(allocator);

    const a = (try ranges.allocate(allocator, 24, 1)).?;
    const b = (try ranges.allocate(allocator, 24, 1)).?;
    try std.testing.expect((try ranges.allocate(allocator, 24, 1)) == null);
    ranges.free(a, 24);
    try std.testing.expect((try ranges.allocate(allocator, 32, 1)) == null);
    ranges.free(b, 24);
    try std.testing.expectEqual(@as(vk.DeviceSize, 0), (try ranges.allocate(allocator, 64, 1)).?);
}
