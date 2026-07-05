const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vk");
const gpu = @import("gpu");

const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const Device = @This();
const required_api_version = vk.API_VERSION_1_3;

pub const clip_space_y_down = true;

const DescriptorPoolEntry = struct {
    pool: vk.DescriptorPool,
};

const DescriptorAllocation = struct {
    set: vk.DescriptorSet,
    pool: vk.DescriptorPool,
};

const VulkanLoader = struct {
    get_instance_proc_addr: vk.PfnGetInstanceProcAddr,
    lib: if (builtin.os.tag == .windows) void else std.DynLib,
};

pub const SurfaceFormat = struct {
    format: vk.Format,
    color_space: vk.ColorSpaceKHR,
};

allocator: std.mem.Allocator,
loader: VulkanLoader,
vki: vk.InstanceWrapper,
vkd: vk.DeviceWrapper,
instance: vk.Instance,
physical_device: vk.PhysicalDevice,
device: vk.Device,
queue_family: u32,
graphics_queue: vk.Queue,
surface_format: vk.Format,
surface_color_space: vk.ColorSpaceKHR,
surface_is_srgb: bool,
transient_command_pool: vk.CommandPool,
descriptor_pools: std.ArrayList(DescriptorPoolEntry),

pub fn init(allocator: std.mem.Allocator, window_handle: gpu.Context.WindowHandle) !Device {
    var loader = try loadVulkan();
    errdefer if (builtin.os.tag != .windows) loader.lib.close();

    const vkb = vk.BaseWrapper.load(loader.get_instance_proc_addr);
    const instance_extensions = getInstanceExtensions(window_handle);
    const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
    const instance = try vkb.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "knots",
            .application_version = 0,
            .p_engine_name = "knots",
            .engine_version = 0,
            .api_version = required_api_version.toU32(),
        },
        .enabled_extension_count = @intCast(instance_extensions.len),
        .pp_enabled_extension_names = &instance_extensions,
        .enabled_layer_count = if (builtin.mode == .Debug) 1 else 0,
        .pp_enabled_layer_names = if (builtin.mode == .Debug) &validation_layers else undefined,
        .flags = if (builtin.os.tag.isDarwin()) .{ .enumerate_portability_bit_khr = true } else .{},
    }, null);

    const vki = vk.InstanceWrapper.load(instance, vkb.dispatch.vkGetInstanceProcAddr.?);
    errdefer vki.destroyInstance(instance, null);
    const surface = try createSurface(vki, instance, window_handle);
    defer vki.destroySurfaceKHR(instance, surface, null);

    const phys = try pickPhysicalDevice(vki, instance, surface);
    const chosen_format = try chooseSurfaceFormat(vki, phys.device, surface);

    const portability_subset: [1][*:0]const u8 = .{"VK_KHR_portability_subset"};
    const device_extensions: []const [*:0]const u8 = if (builtin.os.tag.isDarwin())
        &(.{vk.extensions.khr_swapchain.name} ++ portability_subset)
    else
        &.{vk.extensions.khr_swapchain.name};

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
        .enabled_extension_count = @intCast(device_extensions.len),
        .pp_enabled_extension_names = @ptrCast(device_extensions.ptr),
        .p_enabled_features = &enabled_features,
    }, null);

    const vkd = vk.DeviceWrapper.load(device, vki.dispatch.vkGetDeviceProcAddr.?);
    errdefer vkd.destroyDevice(device, null);
    const transient_command_pool = try vkd.createCommandPool(device, &.{
        .queue_family_index = phys.queue_family,
        .flags = .{ .transient_bit = true },
    }, null);
    errdefer vkd.destroyCommandPool(device, transient_command_pool, null);

    var descriptor_pools = try createDescriptorPools(allocator, vkd, device);
    errdefer destroyDescriptorPools(allocator, vkd, device, &descriptor_pools);

    return .{
        .allocator = allocator,
        .loader = loader,
        .vki = vki,
        .vkd = vkd,
        .instance = instance,
        .physical_device = phys.device,
        .device = device,
        .queue_family = phys.queue_family,
        .graphics_queue = vkd.getDeviceQueue(device, phys.queue_family, 0),
        .surface_format = chosen_format.format,
        .surface_color_space = chosen_format.color_space,
        .surface_is_srgb = isSrgbFormat(chosen_format.format),
        .transient_command_pool = transient_command_pool,
        .descriptor_pools = descriptor_pools,
    };
}

pub fn deinit(self: *Device) void {
    self.vkd.deviceWaitIdle(self.device) catch {};
    destroyDescriptorPools(self.allocator, self.vkd, self.device, &self.descriptor_pools);
    self.vkd.destroyCommandPool(self.device, self.transient_command_pool, null);
    self.vkd.destroyDevice(self.device, null);
    self.vki.destroyInstance(self.instance, null);
    if (builtin.os.tag != .windows) self.loader.lib.close();
}

pub fn createBuffer(self: *Device, size: usize, usage: gpu.Buffer.Usage) !Buffer {
    return Buffer.create(self, size, usage);
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

pub fn createSurfaceHandle(self: *const Device, window_handle: gpu.Context.WindowHandle) !vk.SurfaceKHR {
    return createSurface(self.vki, self.instance, window_handle);
}

pub fn surfaceFormat(self: *const Device) gpu.Texture.Format {
    return formatFromVk(self.surface_format);
}

pub fn surfaceIsSrgb(self: *const Device) bool {
    return self.surface_is_srgb;
}

pub fn findMemoryType(self: *const Device, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    const mem_props = self.vki.getPhysicalDeviceMemoryProperties(self.physical_device);
    for (0..mem_props.memory_type_count) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and
            mem_props.memory_types[i].property_flags.contains(properties))
        {
            return @intCast(i);
        }
    }
    return error.NoSuitableMemoryType;
}

pub const SingleTimeSubmission = struct {
    command_buffer: vk.CommandBuffer,
    fence: vk.Fence,
};

pub fn beginSingleTimeCommands(self: *const Device) !vk.CommandBuffer {
    var cmd: [1]vk.CommandBuffer = undefined;
    try self.vkd.allocateCommandBuffers(self.device, &.{
        .command_pool = self.transient_command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, &cmd);
    try self.vkd.beginCommandBuffer(cmd[0], &.{
        .flags = .{ .one_time_submit_bit = true },
    });
    return cmd[0];
}

pub fn endSingleTimeCommands(self: *const Device, cmd: vk.CommandBuffer) !SingleTimeSubmission {
    errdefer self.vkd.freeCommandBuffers(self.device, self.transient_command_pool, &.{cmd});
    try self.vkd.endCommandBuffer(cmd);
    const fence = try self.vkd.createFence(self.device, &.{ .flags = .{} }, null);
    errdefer self.vkd.destroyFence(self.device, fence, null);
    try self.vkd.queueSubmit2(self.graphics_queue, &.{.{
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &[_]vk.CommandBufferSubmitInfo{.{
            .command_buffer = cmd,
            .device_mask = 1,
        }},
    }}, fence);
    return .{ .command_buffer = cmd, .fence = fence };
}

pub fn finishSingleTimeCommands(self: *const Device, submission: SingleTimeSubmission) !void {
    _ = try self.vkd.waitForFences(self.device, &.{submission.fence}, .true, std.math.maxInt(u64));
    self.vkd.destroyFence(self.device, submission.fence, null);
    self.vkd.freeCommandBuffers(self.device, self.transient_command_pool, &.{submission.command_buffer});
}

pub fn allocateDescriptorSetWithPool(self: *Device, layout: vk.DescriptorSetLayout) !DescriptorAllocation {
    for (self.descriptor_pools.items) |entry| {
        var set: [1]vk.DescriptorSet = undefined;
        self.vkd.allocateDescriptorSets(self.device, &.{
            .descriptor_pool = entry.pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{layout},
        }, &set) catch continue;
        return .{ .set = set[0], .pool = entry.pool };
    }

    const new_pool = try createDescriptorPool(self.vkd, self.device);
    try self.descriptor_pools.append(self.allocator, .{ .pool = new_pool });
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

fn createDescriptorPool(vkd: vk.DeviceWrapper, device: vk.Device) !vk.DescriptorPool {
    return vkd.createDescriptorPool(device, &.{
        .flags = .{ .free_descriptor_set_bit = true },
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

fn createDescriptorPools(allocator: std.mem.Allocator, vkd: vk.DeviceWrapper, device: vk.Device) !std.ArrayList(DescriptorPoolEntry) {
    var descriptor_pools: std.ArrayList(DescriptorPoolEntry) = .empty;
    errdefer destroyDescriptorPools(allocator, vkd, device, &descriptor_pools);

    const initial_pool = try createDescriptorPool(vkd, device);
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
        if (prop.queue_flags.graphics_bit and (try vki.getPhysicalDeviceSurfaceSupportKHR(device, idx, surface)) == .true)
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
