const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vk");
const gpu = @import("gpu");

const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");
const MemoryAllocator = @import("MemoryAllocator.zig");

const Device = @This();
const required_api_version = vk.API_VERSION_1_3;
const upload_batch_max = 64;

pub const clip_space_y_down = true;

const DescriptorPoolEntry = struct {
    pool: vk.DescriptorPool,
};

const DescriptorAllocation = struct {
    set: vk.DescriptorSet,
    pool: vk.DescriptorPool,
};

const PendingUpload = struct {
    image: vk.Image,
    buffer_offset: vk.DeviceSize,
    buffer_row_length: u32,
    image_offset: vk.Offset3D,
    image_extent: vk.Extent3D,
};

const PendingUploadImage = struct {
    image: vk.Image,
    old_layout: vk.ImageLayout,
};

const VulkanLoader = struct {
    get_instance_proc_addr: vk.PfnGetInstanceProcAddr,
    lib: if (builtin.os.tag == .windows) void else std.DynLib,
};

/// Serializes access to the graphics queue when the device is shared.
pub const QueueLock = struct {
    context: *anyopaque,
    lock: *const fn (context: *anyopaque, family: u32, index: u32) void,
    unlock: *const fn (context: *anyopaque, family: u32, index: u32) void,
};

/// A device created by another library.
/// The owner must have created the instance with Vulkan 1.3 and enabled
/// `synchronization2`, `dynamicRendering`, `shaderInt8` and `shaderInt16`.
/// `initExternal` can check the API version, but Vulkan does not expose which
/// optional features were enabled when the device was created.
/// Provide `queue_lock` when another user may access the selected queue.
pub const External = struct {
    get_instance_proc_addr: *const anyopaque,
    instance: usize,
    physical_device: usize,
    device: usize,
    queue_family: u32,
    queue_index: u32 = 0,
    queue_lock: ?QueueLock = null,
    /// Format that offscreen targets use.
    target_format: gpu.Texture.Format = .rgba8,
};

pub const SurfaceFormat = struct {
    format: vk.Format,
    color_space: vk.ColorSpaceKHR,
};

allocator: std.mem.Allocator,
/// Null for devices imported with `initExternal`.
loader: ?VulkanLoader,
/// False when the instance and device belong to another library.
owns_device: bool = true,
queue_lock: ?QueueLock = null,
queue_index: u32 = 0,
vki: vk.InstanceWrapper,
vkd: vk.DeviceWrapper,
instance: vk.Instance,
debug_messenger: vk.DebugUtilsMessengerEXT,
debug_utils: bool,
validation_enabled: bool,
physical_device: vk.PhysicalDevice,
device: vk.Device,
queue_family: u32,
graphics_queue: vk.Queue,
pipeline_cache: vk.PipelineCache,
surface_format: vk.Format,
surface_color_space: vk.ColorSpaceKHR,
surface_is_srgb: bool,
memory_allocator: MemoryAllocator,
descriptor_pools: std.ArrayList(DescriptorPoolEntry),
pending_upload_bytes: std.ArrayList(u8),
pending_uploads: std.ArrayList(PendingUpload),
pending_upload_images: std.ArrayList(PendingUploadImage),
upload_barriers_before: std.ArrayList(vk.ImageMemoryBarrier2),
upload_barriers_after: std.ArrayList(vk.ImageMemoryBarrier2),

pub fn init(allocator: std.mem.Allocator, window_handle: gpu.Context.WindowHandle) !Device {
    var loader = try loadVulkan();
    errdefer if (builtin.os.tag != .windows) loader.lib.close();

    const vkb = vk.BaseWrapper.load(loader.get_instance_proc_addr);
    const required_instance_extensions = getInstanceExtensions(window_handle);
    const available_instance_extensions = try vkb.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
    defer allocator.free(available_instance_extensions);
    const debug_utils = hasExtension(available_instance_extensions, vk.extensions.ext_debug_utils.name);
    var instance_extensions: [4][*:0]const u8 = undefined;
    for (required_instance_extensions, 0..) |extension, i| instance_extensions[i] = extension;
    var instance_extension_count: u32 = @intCast(required_instance_extensions.len);
    if (debug_utils) {
        instance_extensions[instance_extension_count] = vk.extensions.ext_debug_utils.name;
        instance_extension_count += 1;
    }

    const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
    const available_layers = try vkb.enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(available_layers);
    const validation = builtin.mode == .debug and hasLayer(available_layers, validation_layers[0]);
    const instance = try vkb.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "knots",
            .application_version = 0,
            .p_engine_name = "knots",
            .engine_version = 0,
            .api_version = required_api_version.toU32(),
        },
        .enabled_extension_count = instance_extension_count,
        .pp_enabled_extension_names = &instance_extensions,
        .enabled_layer_count = if (validation) 1 else 0,
        .pp_enabled_layer_names = if (validation) &validation_layers else null,
        .flags = if (builtin.os.tag.isDarwin()) .{ .enumerate_portability_khr = true } else .{},
    }, null);

    const vki = vk.InstanceWrapper.load(instance, vkb.dispatch.vkGetInstanceProcAddr.?);
    errdefer vki.destroyInstance(instance, null);
    const debug_messenger = if (debug_utils and builtin.mode == .debug)
        try vki.createDebugUtilsMessengerEXT(instance, &.{
            .message_severity = .{ .warning_ext = true, .error_ext = true },
            .message_type = .{ .general_ext = true, .validation_ext = true, .performance_ext = true },
            .pfn_user_callback = debugCallback,
        }, null)
    else
        vk.DebugUtilsMessengerEXT.null_handle;
    errdefer if (debug_messenger != .null_handle) vki.destroyDebugUtilsMessengerEXT(instance, debug_messenger, null);
    const surface = try createSurface(vki, instance, window_handle);
    defer vki.destroySurfaceKHR(instance, surface, null);

    const phys = try pickPhysicalDevice(vki, instance, surface);
    const chosen_format = try chooseSurfaceFormat(vki, phys.device, surface);

    const available_device_extensions = try vki.enumerateDeviceExtensionPropertiesAlloc(phys.device, null, allocator);
    defer allocator.free(available_device_extensions);
    const memory_budget = hasExtension(available_device_extensions, vk.extensions.ext_memory_budget.name);
    var device_extensions: [3][*:0]const u8 = undefined;
    var device_extension_count: u32 = 0;
    device_extensions[device_extension_count] = vk.extensions.khr_swapchain.name;
    device_extension_count += 1;
    if (builtin.os.tag.isDarwin()) {
        device_extensions[device_extension_count] = "VK_KHR_portability_subset";
        device_extension_count += 1;
    }
    if (memory_budget) {
        device_extensions[device_extension_count] = vk.extensions.ext_memory_budget.name;
        device_extension_count += 1;
    }

    const queue_priority = [_]f32{1.0};
    var vk12_features = vk.PhysicalDeviceVulkan12Features{
        .shader_int_8 = .true,
    };
    var vk13_features = vk.PhysicalDeviceVulkan13Features{
        .synchronization_2 = .true,
        .dynamic_rendering = .true,
    };
    vk12_features.p_next = &vk13_features;
    const enabled_features = vk.PhysicalDeviceFeatures{
        .shader_int_16 = .true,
    };
    const device = try vki.createDevice(phys.device, &.{
        .p_next = &vk12_features,
        .queue_create_info_count = 1,
        .p_queue_create_infos = &[_]vk.DeviceQueueCreateInfo{.{
            .queue_family_index = phys.queue_family,
            .queue_count = 1,
            .p_queue_priorities = &queue_priority,
        }},
        .enabled_extension_count = device_extension_count,
        .pp_enabled_extension_names = &device_extensions,
        .p_enabled_features = &enabled_features,
    }, null);

    const vkd = vk.DeviceWrapper.load(device, vki.dispatch.vkGetDeviceProcAddr.?);
    errdefer vkd.destroyDevice(device, null);
    const pipeline_cache = try vkd.createPipelineCache(device, &.{}, null);
    errdefer vkd.destroyPipelineCache(device, pipeline_cache, null);
    var memory_allocator = MemoryAllocator.init(allocator, vki, vkd, phys.device, device, memory_budget, debug_utils);
    errdefer memory_allocator.deinit();

    var descriptor_pools = try createDescriptorPools(allocator, vkd, device);
    errdefer destroyDescriptorPools(allocator, vkd, device, &descriptor_pools);

    var result = Device{
        .allocator = allocator,
        .loader = loader,
        .vki = vki,
        .vkd = vkd,
        .instance = instance,
        .debug_messenger = debug_messenger,
        .debug_utils = debug_utils,
        .validation_enabled = validation,
        .physical_device = phys.device,
        .device = device,
        .queue_family = phys.queue_family,
        .graphics_queue = vkd.getDeviceQueue(device, phys.queue_family, 0),
        .pipeline_cache = pipeline_cache,
        .surface_format = chosen_format.format,
        .surface_color_space = chosen_format.color_space,
        .surface_is_srgb = isSrgbFormat(chosen_format.format),
        .memory_allocator = memory_allocator,
        .descriptor_pools = descriptor_pools,
        .pending_upload_bytes = .empty,
        .pending_uploads = .empty,
        .pending_upload_images = .empty,
        .upload_barriers_before = .empty,
        .upload_barriers_after = .empty,
    };
    result.setDebugName(.pipeline_cache, @backingInt(pipeline_cache), "pipeline_cache");
    for (result.descriptor_pools.items) |entry| result.setDebugName(.descriptor_pool, @backingInt(entry.pool), "descriptor_pool");
    return result;
}

/// Imports a device created elsewhere. The device is not destroyed by `deinit`.
pub fn initExternal(allocator: std.mem.Allocator, external: External) !Device {
    const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @ptrCast(external.get_instance_proc_addr);
    const instance: vk.Instance = @ptrFromInt(external.instance);
    const physical_device: vk.PhysicalDevice = @ptrFromInt(external.physical_device);
    const device: vk.Device = @ptrFromInt(external.device);

    const vki = vk.InstanceWrapper.load(instance, get_instance_proc_addr);
    const vkd = vk.DeviceWrapper.load(device, vki.dispatch.vkGetDeviceProcAddr.?);
    if (vki.getPhysicalDeviceProperties(physical_device).api_version < required_api_version.toU32())
        return error.UnsupportedVulkanVersion;

    const pipeline_cache = try vkd.createPipelineCache(device, &.{}, null);
    errdefer vkd.destroyPipelineCache(device, pipeline_cache, null);
    var memory_allocator = MemoryAllocator.init(allocator, vki, vkd, physical_device, device, false, false);
    errdefer memory_allocator.deinit();

    var descriptor_pools = try createDescriptorPools(allocator, vkd, device);
    errdefer destroyDescriptorPools(allocator, vkd, device, &descriptor_pools);

    const target_format = Texture.toVkFormat(external.target_format);
    return .{
        .allocator = allocator,
        .loader = null,
        .owns_device = false,
        .queue_lock = external.queue_lock,
        .queue_index = external.queue_index,
        .vki = vki,
        .vkd = vkd,
        .instance = instance,
        .debug_messenger = .null_handle,
        .debug_utils = false,
        .validation_enabled = false,
        .physical_device = physical_device,
        .device = device,
        .queue_family = external.queue_family,
        .graphics_queue = vkd.getDeviceQueue(device, external.queue_family, external.queue_index),
        .pipeline_cache = pipeline_cache,
        .surface_format = target_format,
        .surface_color_space = .srgb_nonlinear_khr,
        .surface_is_srgb = isSrgbFormat(target_format),
        .memory_allocator = memory_allocator,
        .descriptor_pools = descriptor_pools,
        .pending_upload_bytes = .empty,
        .pending_uploads = .empty,
        .pending_upload_images = .empty,
        .upload_barriers_before = .empty,
        .upload_barriers_after = .empty,
    };
}

/// Takes the graphics queue lock. Pair every call with `unlockQueue`.
pub fn lockQueue(self: *const Device) void {
    if (self.queue_lock) |ql| ql.lock(ql.context, self.queue_family, self.queue_index);
}

pub fn unlockQueue(self: *const Device) void {
    if (self.queue_lock) |ql| ql.unlock(ql.context, self.queue_family, self.queue_index);
}

pub fn waitQueueIdle(self: *Device) !void {
    self.lockQueue();
    defer self.unlockQueue();
    try self.vkd.queueWaitIdle(self.graphics_queue);
}

pub fn deinit(self: *Device) void {
    if (self.owns_device) self.vkd.deviceWaitIdle(self.device) catch {} else self.waitQueueIdle() catch {};
    self.pending_upload_bytes.deinit(self.allocator);
    self.pending_uploads.deinit(self.allocator);
    self.pending_upload_images.deinit(self.allocator);
    self.upload_barriers_before.deinit(self.allocator);
    self.upload_barriers_after.deinit(self.allocator);
    destroyDescriptorPools(self.allocator, self.vkd, self.device, &self.descriptor_pools);
    self.memory_allocator.deinit();
    self.vkd.destroyPipelineCache(self.device, self.pipeline_cache, null);
    if (!self.owns_device) return;
    self.vkd.destroyDevice(self.device, null);
    if (self.debug_messenger != .null_handle) self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, null);
    self.vki.destroyInstance(self.instance, null);
    if (builtin.os.tag != .windows) if (self.loader) |*loader| loader.lib.close();
}

pub fn waitIdle(self: *Device) !void {
    if (!self.owns_device) return self.waitQueueIdle();
    try self.vkd.deviceWaitIdle(self.device);
}

pub fn createBuffer(self: *Device, desc: gpu.Buffer.Desc) !Buffer {
    return Buffer.create(self, desc);
}

pub fn createPipeline(self: *Device, desc: gpu.Pipeline.Desc) !Pipeline {
    return Pipeline.create(self.allocator, self, desc);
}

pub fn createBindGroup(self: *Device, desc: BindGroup.Desc) !BindGroup {
    return BindGroup.create(self, desc);
}

pub fn createTexture(self: *Device, desc: Texture.Desc) !Texture {
    return Texture.create(self, desc);
}

pub fn createSampler(self: *Device, desc: gpu.Sampler.Desc) !Sampler {
    return Sampler.create(self, desc);
}

pub fn queueTextureUpload(
    self: *Device,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    data: []const u8,
    bytes_per_pixel: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bytes_per_row: ?u32,
) !void {
    std.debug.assert(bytes_per_pixel != 0);
    std.debug.assert(width != 0 and height != 0);
    const alignment: usize = @max(4, bytes_per_pixel);
    const offset = std.mem.alignForward(usize, self.pending_upload_bytes.items.len, alignment);
    const old_len = self.pending_upload_bytes.items.len;
    try self.pending_upload_bytes.resize(self.allocator, offset + data.len);
    @memset(self.pending_upload_bytes.items[old_len..offset], 0);
    @memcpy(self.pending_upload_bytes.items[offset..][0..data.len], data);
    errdefer self.pending_upload_bytes.shrinkRetainingCapacity(old_len);

    try self.pending_uploads.append(self.allocator, .{
        .image = image,
        .buffer_offset = @intCast(offset),
        .buffer_row_length = if (bytes_per_row) |stride| stride / bytes_per_pixel else 0,
        .image_offset = .{ .x = @intCast(x), .y = @intCast(y), .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    });
    errdefer _ = self.pending_uploads.pop();

    for (self.pending_upload_images.items) |pending| if (pending.image == image) return;
    try self.pending_upload_images.append(self.allocator, .{ .image = image, .old_layout = old_layout });
}

pub fn cancelTextureUploads(self: *Device, image: vk.Image) void {
    var i = self.pending_uploads.items.len;
    while (i > 0) {
        i -= 1;
        if (self.pending_uploads.items[i].image == image) _ = self.pending_uploads.orderedRemove(i);
    }
    for (self.pending_upload_images.items, 0..) |pending, index| {
        if (pending.image == image) {
            _ = self.pending_upload_images.orderedRemove(index);
            break;
        }
    }
    if (self.pending_uploads.items.len == 0) self.clearPendingUploads();
}

pub fn preparePendingUploads(self: *Device, upload_buffer: *?Buffer) !void {
    if (self.pending_uploads.items.len == 0) return;
    const required = self.pending_upload_bytes.items.len;
    if (upload_buffer.*) |*buffer| {
        if (buffer.size < required) try buffer.resize(required);
        buffer.load(u8, self.pending_upload_bytes.items);
    } else {
        var buffer = try self.createBuffer(.{
            .size = required,
            .usage = .{ .copy_src = true },
            .label = "frame_texture_uploads",
        });
        buffer.load(u8, self.pending_upload_bytes.items);
        upload_buffer.* = buffer;
    }

    self.upload_barriers_before.clearRetainingCapacity();
    self.upload_barriers_after.clearRetainingCapacity();
    try self.upload_barriers_before.ensureTotalCapacity(self.allocator, self.pending_upload_images.items.len);
    try self.upload_barriers_after.ensureTotalCapacity(self.allocator, self.pending_upload_images.items.len);
    for (self.pending_upload_images.items) |pending| {
        const range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        self.upload_barriers_before.appendAssumeCapacity(.{
            .src_stage_mask = if (pending.old_layout == .undefined) .{} else .{ .vertex_shader = true, .fragment_shader = true },
            .src_access_mask = if (pending.old_layout == .undefined) .{} else .{ .shader_sampled_read = true },
            .dst_stage_mask = .{ .all_transfer = true },
            .dst_access_mask = .{ .transfer_write = true },
            .old_layout = pending.old_layout,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = pending.image,
            .subresource_range = range,
        });
        self.upload_barriers_after.appendAssumeCapacity(.{
            .src_stage_mask = .{ .all_transfer = true },
            .src_access_mask = .{ .transfer_write = true },
            .dst_stage_mask = .{ .vertex_shader = true, .fragment_shader = true },
            .dst_access_mask = .{ .shader_sampled_read = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = pending.image,
            .subresource_range = range,
        });
    }
}

pub fn recordPendingUploads(self: *Device, command_buffer: vk.CommandBuffer, upload_buffer: *const Buffer) void {
    if (self.pending_uploads.items.len == 0) return;
    self.vkd.cmdPipelineBarrier2(command_buffer, &.{
        .image_memory_barrier_count = @intCast(self.upload_barriers_before.items.len),
        .p_image_memory_barriers = self.upload_barriers_before.items.ptr,
    });
    var batch_start: usize = 0;
    for (self.pending_uploads.items, 0..) |upload, index| {
        std.debug.assert(batch_start <= index);
        std.debug.assert(index - batch_start <= upload_batch_max);
        // Bound overlap detection to at most 64 comparisons per copy.
        var needs_barrier = index - batch_start == upload_batch_max;
        if (!needs_barrier) {
            for (self.pending_uploads.items[batch_start..index]) |previous| {
                if (previous.image != upload.image) continue;
                if (uploadsOverlap(&previous, &upload)) {
                    needs_barrier = true;
                    break;
                }
            }
        }
        if (needs_barrier) {
            self.vkd.cmdPipelineBarrier2(command_buffer, &.{
                .memory_barrier_count = 1,
                .p_memory_barriers = &[_]vk.MemoryBarrier2{.{
                    .src_stage_mask = .{ .copy = true },
                    .src_access_mask = .{ .transfer_write = true },
                    .dst_stage_mask = .{ .copy = true },
                    .dst_access_mask = .{ .transfer_write = true },
                }},
            });
            batch_start = index;
        }
        self.vkd.cmdCopyBufferToImage(command_buffer, upload_buffer.buffer, upload.image, .transfer_dst_optimal, &.{.{
            .buffer_offset = upload.buffer_offset,
            .buffer_row_length = upload.buffer_row_length,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = upload.image_offset,
            .image_extent = upload.image_extent,
        }});
    }
    self.vkd.cmdPipelineBarrier2(command_buffer, &.{
        .image_memory_barrier_count = @intCast(self.upload_barriers_after.items.len),
        .p_image_memory_barriers = self.upload_barriers_after.items.ptr,
    });
}

pub fn clearPendingUploads(self: *Device) void {
    self.pending_upload_bytes.clearRetainingCapacity();
    self.pending_uploads.clearRetainingCapacity();
    self.pending_upload_images.clearRetainingCapacity();
    self.upload_barriers_before.clearRetainingCapacity();
    self.upload_barriers_after.clearRetainingCapacity();
}

fn uploadsOverlap(previous: *const PendingUpload, next: *const PendingUpload) bool {
    std.debug.assert(previous.image_extent.width > 0);
    std.debug.assert(next.image_extent.width > 0);
    const previous_right = @as(i64, previous.image_offset.x) + previous.image_extent.width;
    const next_right = @as(i64, next.image_offset.x) + next.image_extent.width;
    if (previous.image_offset.x >= next_right) return false;
    if (next.image_offset.x >= previous_right) return false;
    const previous_bottom = @as(i64, previous.image_offset.y) + previous.image_extent.height;
    const next_bottom = @as(i64, next.image_offset.y) + next.image_extent.height;
    if (previous.image_offset.y >= next_bottom) return false;
    if (next.image_offset.y >= previous_bottom) return false;
    return true;
}

pub fn createSurfaceHandle(self: *const Device, window_handle: gpu.Context.WindowHandle) !vk.SurfaceKHR {
    return createSurface(self.vki, self.instance, window_handle);
}

pub fn surfaceFormat(self: *const Device) gpu.Texture.Format {
    return formatFromVk(self.surface_format);
}

pub fn surfaceIsSrgb(self: *const Device) bool {
    return self.surface_is_srgb;
}

pub fn allocateDescriptorSetWithPool(self: *Device, layout: vk.DescriptorSetLayout) !DescriptorAllocation {
    for (self.descriptor_pools.items) |entry| {
        var set: [1]vk.DescriptorSet = undefined;
        self.vkd.allocateDescriptorSets(self.device, &.{
            .descriptor_pool = entry.pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{layout},
        }, &set) catch |err| switch (err) {
            error.OutOfPoolMemory, error.FragmentedPool => continue,
            else => return err,
        };
        return .{ .set = set[0], .pool = entry.pool };
    }

    const new_pool = try createDescriptorPool(self.vkd, self.device, true);
    self.setDebugName(.descriptor_pool, @backingInt(new_pool), "descriptor_pool");
    self.descriptor_pools.append(self.allocator, .{ .pool = new_pool }) catch |err| {
        self.vkd.destroyDescriptorPool(self.device, new_pool, null);
        return err;
    };
    var set: [1]vk.DescriptorSet = undefined;
    try self.vkd.allocateDescriptorSets(self.device, &.{
        .descriptor_pool = new_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = &[_]vk.DescriptorSetLayout{layout},
    }, &set);
    return .{ .set = set[0], .pool = new_pool };
}

fn openVulkan(path: []const u8) !VulkanLoader {
    var lib = std.DynLib.open(path) catch return error.VulkanUnavailable;
    errdefer lib.close();
    return .{
        .get_instance_proc_addr = lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse
            return error.VulkanUnavailable,
        .lib = lib,
    };
}

fn loadVulkan() !VulkanLoader {
    switch (builtin.os.tag) {
        inline .windows => {
            const HMODULE = *anyopaque;
            const extern_LoadLibraryA = struct {
                extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?HMODULE;
            };
            const extern_GetProcAddress = struct {
                extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
            };
            const handle = extern_LoadLibraryA.LoadLibraryA("vulkan-1.dll") orelse return error.VulkanUnavailable;
            const ptr = extern_GetProcAddress.GetProcAddress(handle, "vkGetInstanceProcAddr") orelse return error.VulkanUnavailable;
            return .{ .get_instance_proc_addr = @ptrCast(ptr), .lib = {} };
        },
        inline .macos => {
            var exe_path_buf: [std.posix.PATH_MAX + 1]u8 = undefined;
            var exe_path_buf_len: u32 = exe_path_buf.len;
            if (std.c._NSGetExecutablePath(&exe_path_buf, &exe_path_buf_len) == 0) {
                if (std.fs.path.dirname(std.mem.sliceTo(&exe_path_buf, 0))) |exe_dir| {
                    var bundled_loader_buf: [std.fs.max_path_bytes]u8 = undefined;
                    if (std.fmt.bufPrint(
                        &bundled_loader_buf,
                        "{s}/../Frameworks/libvulkan.1.dylib",
                        .{exe_dir},
                    )) |bundled_loader| {
                        if (openVulkan(bundled_loader)) |loader| return loader else |_| {}
                    } else |_| {}
                }
            }

            return openVulkan("libvulkan.1.dylib");
        },

        inline else => return openVulkan("libvulkan.so.1"),
    }
}

pub fn createDescriptorPool(vkd: vk.DeviceWrapper, device: vk.Device, free_sets: bool) !vk.DescriptorPool {
    return vkd.createDescriptorPool(device, &.{
        .flags = .{ .free_descriptor_set = free_sets },
        .max_sets = 64,
        .pool_size_count = 4,
        .p_pool_sizes = &[_]vk.DescriptorPoolSize{
            .{ .type = .uniform_buffer, .descriptor_count = 64 },
            .{ .type = .storage_buffer, .descriptor_count = 64 },
            .{ .type = .sampled_image, .descriptor_count = 64 },
            .{ .type = .sampler, .descriptor_count = 64 },
        },
    }, null);
}

pub fn setDebugName(self: *const Device, object_type: vk.ObjectType, object_handle: u64, label: []const u8) void {
    if (!self.debug_utils or label.len == 0) return;
    var label_buffer: [256]u8 = undefined;
    const label_z = std.fmt.bufPrintSentinel(&label_buffer, "{s}", .{label}, 0x00) catch return;
    self.vkd.setDebugUtilsObjectNameEXT(self.device, &.{
        .object_type = object_type,
        .object_handle = object_handle,
        .p_object_name = label_z,
    }) catch {};
}

fn hasExtension(properties: []const vk.ExtensionProperties, name: [*:0]const u8) bool {
    const expected = std.mem.span(name);
    for (properties) |property| {
        if (std.mem.eql(u8, std.mem.sliceTo(&property.extension_name, 0), expected)) return true;
    }
    return false;
}

fn hasLayer(properties: []const vk.LayerProperties, name: [*:0]const u8) bool {
    const expected = std.mem.span(name);
    for (properties) |property| {
        if (std.mem.eql(u8, std.mem.sliceTo(&property.layer_name, 0), expected)) return true;
    }
    return false;
}

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    const data = callback_data orelse return .false;
    const message = if (data.p_message) |value| std.mem.span(value) else "Vulkan validation message";
    if (severity.error_ext)
        std.log.err("{s}", .{message})
    else
        std.log.warn("{s}", .{message});
    return .false;
}

fn createDescriptorPools(allocator: std.mem.Allocator, vkd: vk.DeviceWrapper, device: vk.Device) !std.ArrayList(DescriptorPoolEntry) {
    var descriptor_pools: std.ArrayList(DescriptorPoolEntry) = .empty;
    errdefer destroyDescriptorPools(allocator, vkd, device, &descriptor_pools);

    const initial_pool = try createDescriptorPool(vkd, device, true);
    errdefer vkd.destroyDescriptorPool(device, initial_pool, null);
    try descriptor_pools.append(allocator, .{ .pool = initial_pool });
    return descriptor_pools;
}

fn destroyDescriptorPools(allocator: std.mem.Allocator, vkd: vk.DeviceWrapper, device: vk.Device, descriptor_pools: *std.ArrayList(DescriptorPoolEntry)) void {
    for (descriptor_pools.items) |entry| vkd.destroyDescriptorPool(device, entry.pool, null);
    descriptor_pools.deinit(allocator);
}

fn getMetalLayer(ns_window: *anyopaque) ?*anyopaque {
    if (builtin.os.tag != .macos) unreachable;
    const sel = struct {
        extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
        extern "c" fn objc_msgSend() void;
        extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
        extern "c" fn object_getClass(obj: *anyopaque) ?*anyopaque;
    };
    const msgSend = @as(*const fn (*anyopaque, *anyopaque) callconv(.c) ?*anyopaque, @ptrCast(&sel.objc_msgSend));
    const msgSendBool = @as(*const fn (*anyopaque, *anyopaque, bool) callconv(.c) void, @ptrCast(&sel.objc_msgSend));
    const msgSendObj = @as(*const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) void, @ptrCast(&sel.objc_msgSend));
    const msgSendF64 = @as(*const fn (*anyopaque, *anyopaque) callconv(.c) f64, @ptrCast(&sel.objc_msgSend));
    const msgSendCGFloat = @as(*const fn (*anyopaque, *anyopaque, f64) callconv(.c) void, @ptrCast(&sel.objc_msgSend));
    const content_view_sel = sel.sel_registerName("contentView") orelse return null;
    const set_wants_layer_sel = sel.sel_registerName("setWantsLayer:") orelse return null;
    const layer_sel = sel.sel_registerName("layer") orelse return null;
    const set_layer_sel = sel.sel_registerName("setLayer:") orelse return null;
    const backing_scale_sel = sel.sel_registerName("backingScaleFactor") orelse return null;
    const set_contents_scale_sel = sel.sel_registerName("setContentsScale:") orelse return null;
    const set_delegate_sel = sel.sel_registerName("setDelegate:") orelse return null;
    const ca_metal_layer_class = sel.objc_getClass("CAMetalLayer") orelse return null;

    const view = msgSend(ns_window, content_view_sel) orelse return null;
    msgSendBool(view, set_wants_layer_sel, true);

    const scale = msgSendF64(ns_window, backing_scale_sel);

    const layer = blk: {
        if (msgSend(view, layer_sel)) |existing_layer| {
            if (sel.object_getClass(existing_layer) == ca_metal_layer_class)
                break :blk existing_layer;
        }
        const alloc_sel = sel.sel_registerName("alloc") orelse return null;
        const init_sel = sel.sel_registerName("init") orelse return null;
        const raw = msgSend(ca_metal_layer_class, alloc_sel) orelse return null;
        const new_layer = msgSend(raw, init_sel) orelse return null;
        msgSendObj(view, set_layer_sel, new_layer);
        // MoltenVK uses the view delegate to track the layer's display timing.
        msgSendObj(new_layer, set_delegate_sel, view);
        break :blk new_layer;
    };

    // CAMetalLayer defaults to contentsScale=1, which makes the Vulkan
    // swapchain report a points-sized surface on Retina.
    msgSendCGFloat(layer, set_contents_scale_sel, scale);
    return layer;
}

fn getInstanceExtensions(window_handle: gpu.Context.WindowHandle) [if (builtin.os.tag.isDarwin()) 3 else 2][*:0]const u8 {
    const surface_ext: [*:0]const u8 = switch (window_handle) {
        .macos => vk.extensions.ext_metal_surface.name,
        .windows => vk.extensions.khr_win_32_surface.name,
        .linux => |lin| switch (lin) {
            .wayland => vk.extensions.khr_wayland_surface.name,
            .x11 => vk.extensions.khr_xlib_surface.name,
        },
        .web => @panic("browser wasm not supported with the vulkan backend"),
    };

    if (builtin.os.tag.isDarwin())
        return .{ vk.extensions.khr_surface.name, surface_ext, vk.extensions.khr_portability_enumeration.name }
    else
        return .{ vk.extensions.khr_surface.name, surface_ext };
}

fn createSurface(vki: vk.InstanceWrapper, instance: vk.Instance, window_handle: gpu.Context.WindowHandle) !vk.SurfaceKHR {
    return blk: switch (window_handle) {
        .macos => |mac| {
            const ns_window = switch (mac) {
                .ns_view => |v| v,
                .ns_window => |w| w,
            };
            const layer = getMetalLayer(ns_window) orelse return error.MetalLayerNotFound;
            break :blk vki.createMetalSurfaceEXT(instance, &.{ .p_layer = @ptrCast(layer) }, null);
        },
        .windows => |win| vki.createWin32SurfaceKHR(instance, &.{ .hinstance = @ptrCast(win.hinstance), .hwnd = @ptrCast(win.hwnd) }, null),
        .linux => |lin| switch (lin) {
            .wayland => |wl| vki.createWaylandSurfaceKHR(instance, &.{ .display = @ptrCast(wl.display), .surface = @ptrCast(wl.surface) }, null),
            .x11 => |x11| vki.createXlibSurfaceKHR(instance, &.{ .dpy = @ptrCast(x11.display), .window = @intCast(x11.window) }, null),
        },
        .web => @panic("browser wasm not supported with the vulkan backend"),
    };
}

const PhysicalDeviceSelection = struct { device: vk.PhysicalDevice, queue_family: u32 };

fn pickPhysicalDevice(vki: vk.InstanceWrapper, instance: vk.Instance, surface: vk.SurfaceKHR) !PhysicalDeviceSelection {
    var device_count: u32 = 0;
    _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);
    if (device_count == 0) return error.NoVulkanDevices;
    var devices_buf: [16]vk.PhysicalDevice = undefined;
    if (device_count > 16) device_count = 16;
    _ = try vki.enumeratePhysicalDevices(instance, &device_count, &devices_buf);
    for (devices_buf[0..device_count]) |dev| {
        if (vki.getPhysicalDeviceProperties(dev).api_version < required_api_version.toU32()) continue;

        var vk12_features = vk.PhysicalDeviceVulkan12Features{};
        var vk13_features = vk.PhysicalDeviceVulkan13Features{};
        vk12_features.p_next = &vk13_features;
        var features = vk.PhysicalDeviceFeatures2{ .p_next = &vk12_features, .features = .{} };
        vki.getPhysicalDeviceFeatures2(dev, &features);
        if (features.features.shader_int_16 != .true or
            vk12_features.shader_int_8 != .true or
            vk13_features.synchronization_2 != .true or
            vk13_features.dynamic_rendering != .true)
        {
            continue;
        }

        if (try findGraphicsQueueFamily(vki, dev, surface)) |qf| return .{ .device = dev, .queue_family = qf };
    }
    return error.NoSuitableDevice;
}

fn findGraphicsQueueFamily(vki: vk.InstanceWrapper, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !?u32 {
    var count: u32 = 0;
    vki.getPhysicalDeviceQueueFamilyProperties(device, &count, null);
    var props_buf: [32]vk.QueueFamilyProperties = undefined;
    if (count > 32) count = 32;
    vki.getPhysicalDeviceQueueFamilyProperties(device, &count, &props_buf);
    for (props_buf[0..count], 0..) |prop, i| {
        const idx: u32 = @intCast(i);
        if (prop.queue_flags.graphics and (try vki.getPhysicalDeviceSurfaceSupportKHR(device, idx, surface)) == .true)
            return idx;
    }
    return null;
}

fn chooseSurfaceFormat(vki: vk.InstanceWrapper, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !SurfaceFormat {
    var format_count: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null);
    var formats_buf: [32]vk.SurfaceFormatKHR = undefined;
    if (format_count > 32) format_count = 32;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, &formats_buf);
    if (format_count == 0) return error.NoSurfaceFormatFound;

    var chosen_format: ?vk.SurfaceFormatKHR = null;
    for (formats_buf[0..format_count]) |f| {
        if (f.format == .b8g8r8a8_srgb and f.color_space == .srgb_nonlinear_khr) {
            chosen_format = f;
            break;
        }
    }
    if (chosen_format == null) for (formats_buf[0..format_count]) |f| {
        if (f.format == .r8g8b8a8_srgb and f.color_space == .srgb_nonlinear_khr) {
            chosen_format = f;
            break;
        }
    };
    if (chosen_format == null) for (formats_buf[0..format_count]) |f| switch (f.format) {
        .r8g8b8a8_unorm, .b8g8r8a8_unorm, .r8_unorm, .r32g32b32a32_sfloat, .r32g32b32a32_uint => {
            chosen_format = f;
            break;
        },
        else => {},
    };
    const cf = chosen_format orelse return error.UnsupportedSurfaceFormat;
    return .{ .format = cf.format, .color_space = cf.color_space };
}

fn isSrgbFormat(format: vk.Format) bool {
    return switch (format) {
        .b8g8r8a8_srgb, .r8g8b8a8_srgb => true,
        else => false,
    };
}

pub fn formatFromVk(f: vk.Format) gpu.Texture.Format {
    return switch (f) {
        .r8g8b8a8_unorm => .rgba8,
        .r8g8b8a8_srgb => .rgba8_srgb,
        .b8g8r8a8_unorm => .bgra8,
        .b8g8r8a8_srgb => .bgra8_srgb,
        .r8_unorm => .r8,
        .r32g32b32a32_sfloat => .rgba32f,
        .r32g32b32a32_uint => .rgba32u,
        else => unreachable,
    };
}
