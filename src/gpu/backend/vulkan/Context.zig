const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vk");

const gpu = @import("gpu");

const Buffer = @import("Buffer.zig");
const Frame = @import("Frame.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const Context = @This();
const required_api_version = vk.API_VERSION_1_3;

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

allocator: std.mem.Allocator,
loader: VulkanLoader,
vki: vk.InstanceWrapper,
vkd: vk.DeviceWrapper,
instance: vk.Instance,
physical_device: vk.PhysicalDevice,
device: vk.Device,
graphics_queue: vk.Queue,
surface: vk.SurfaceKHR,
swapchain: vk.SwapchainKHR,
swapchain_images: []vk.Image,
swapchain_views: []vk.ImageView,
swapchain_format: vk.Format,
swapchain_is_srgb: bool,
swapchain_copy_src: bool,
swapchain_extent: vk.Extent2D,
transient_command_pool: vk.CommandPool,
command_pools: []vk.CommandPool,
descriptor_pools: std.ArrayList(DescriptorPoolEntry),
cfg: gpu.Context.Config,
present_modes: gpu.Context.PresentModes,

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

pub fn init(allocator: std.mem.Allocator, window_handle: gpu.Context.WindowHandle, cfg: gpu.Context.Config) !Context {
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
    const surface = try createSurface(vki, instance, window_handle);
    const phys = try pickPhysicalDevice(vki, instance, surface);

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
    const graphics_queue = vkd.getDeviceQueue(device, phys.queue_family, 0);

    const sc = try createSwapchain(vki, vkd, phys.device, device, surface, cfg.window_width, cfg.window_height, .null_handle, cfg);

    const images = try getSwapchainImages(allocator, vkd, device, sc.swapchain);
    errdefer allocator.free(images);

    const views = try createImageViews(allocator, vkd, device, images, sc.format);
    errdefer {
        for (views) |v| vkd.destroyImageView(device, v, null);
        allocator.free(views);
    }

    const command_pools = try allocator.alloc(vk.CommandPool, images.len);
    errdefer allocator.free(command_pools);
    var pools_created: usize = 0;
    errdefer for (command_pools[0..pools_created]) |pool| vkd.destroyCommandPool(device, pool, null);
    for (command_pools) |*pool| {
        pool.* = try vkd.createCommandPool(device, &.{
            .queue_family_index = phys.queue_family,
            .flags = .{ .reset_command_buffer_bit = true },
        }, null);
        pools_created += 1;
    }

    const transient_command_pool = try vkd.createCommandPool(device, &.{
        .queue_family_index = phys.queue_family,
        .flags = .{ .transient_bit = true },
    }, null);

    var descriptor_pools: std.ArrayList(DescriptorPoolEntry) = .empty;
    errdefer {
        for (descriptor_pools.items) |entry| vkd.destroyDescriptorPool(device, entry.pool, null);
        descriptor_pools.deinit(allocator);
    }
    const initial_pool = try createDescriptorPool(vkd, device);
    try descriptor_pools.append(allocator, .{ .pool = initial_pool });

    return .{
        .allocator = allocator,
        .loader = loader,
        .vki = vki,
        .vkd = vkd,
        .instance = instance,
        .physical_device = phys.device,
        .device = device,
        .graphics_queue = graphics_queue,
        .surface = surface,
        .swapchain = sc.swapchain,
        .swapchain_images = images,
        .swapchain_views = views,
        .swapchain_format = sc.format,
        .swapchain_is_srgb = sc.is_srgb,
        .swapchain_copy_src = sc.copy_src,
        .swapchain_extent = sc.extent,
        .command_pools = command_pools,
        .transient_command_pool = transient_command_pool,
        .descriptor_pools = descriptor_pools,
        .cfg = cfg,
        .present_modes = sc.present_modes,
    };
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

pub fn allocateDescriptorSetWithPool(self: *Context, layout: vk.DescriptorSetLayout) !DescriptorAllocation {
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

pub fn clipSpaceYDown(_: *const Context) bool {
    return true;
}

pub fn deinit(self: *Context) void {
    self.vkd.deviceWaitIdle(self.device) catch {};
    for (self.descriptor_pools.items) |entry| {
        self.vkd.destroyDescriptorPool(self.device, entry.pool, null);
    }
    self.descriptor_pools.deinit(self.allocator);
    self.vkd.destroyCommandPool(self.device, self.transient_command_pool, null);
    for (self.command_pools) |pool| {
        self.vkd.destroyCommandPool(self.device, pool, null);
    }
    self.allocator.free(self.command_pools);
    for (self.swapchain_views) |v| self.vkd.destroyImageView(self.device, v, null);
    self.allocator.free(self.swapchain_views);
    self.allocator.free(self.swapchain_images);
    self.vkd.destroySwapchainKHR(self.device, self.swapchain, null);
    self.vkd.destroyDevice(self.device, null);
    self.vki.destroySurfaceKHR(self.instance, self.surface, null);
    self.vki.destroyInstance(self.instance, null);
    if (builtin.os.tag != .windows) self.loader.lib.close();
}

pub fn createBuffer(self: *Context, size: usize, usage: gpu.Buffer.Usage) !Buffer {
    return Buffer.create(self.allocator, self, size, usage);
}

pub fn createFrame(self: *Context) !Frame {
    return Frame.create(self.allocator, self);
}

pub fn createPipeline(self: *Context, desc: gpu.Pipeline.Desc) !Pipeline {
    return Pipeline.create(self.allocator, self, desc);
}

pub fn createBindGroup(self: *Context, desc: BindGroup.Desc) !BindGroup {
    return BindGroup.create(self.allocator, self, desc);
}

pub fn createTexture(self: *Context, desc: Texture.Desc) !Texture {
    return Texture.create(self.allocator, self, desc);
}

pub fn createSampler(self: *Context, desc: gpu.Sampler.Desc) !Sampler {
    return Sampler.create(self.allocator, self, desc);
}

pub fn resize(self: *Context, width: u32, height: u32) !void {
    try self.vkd.deviceWaitIdle(self.device);
    try self.recreateSwapchain(width, height);
    self.cfg.window_width = width;
    self.cfg.window_height = height;
}

pub fn reconfigure(self: *Context, cfg: gpu.Context.Config) !void {
    try self.vkd.deviceWaitIdle(self.device);

    const old_cfg = self.cfg;
    self.cfg = cfg;
    self.recreateSwapchain(cfg.window_width, cfg.window_height) catch |err| {
        self.cfg = old_cfg;
        return err;
    };
}

pub fn supportedPresentModes(self: *const Context) gpu.Context.PresentModes {
    return self.present_modes;
}

pub fn surfaceFormat(self: *const Context) gpu.Texture.Format {
    return vkFormatToGpu(self.swapchain_format);
}

pub fn surfaceIsSrgb(self: *const Context) bool {
    return self.swapchain_is_srgb;
}

fn vkFormatToGpu(f: vk.Format) gpu.Texture.Format {
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

pub fn recreateSwapchain(self: *Context, width: u32, height: u32) !void {
    const old_swapchain = self.swapchain;
    const sc = try createSwapchain(self.vki, self.vkd, self.physical_device, self.device, self.surface, width, height, old_swapchain, self.cfg);
    errdefer self.vkd.destroySwapchainKHR(self.device, sc.swapchain, null);
    if (sc.format != self.swapchain_format) return error.SwapchainFormatChanged;

    const new_images = try getSwapchainImages(self.allocator, self.vkd, self.device, sc.swapchain);
    errdefer self.allocator.free(new_images);

    const new_views = try createImageViews(self.allocator, self.vkd, self.device, new_images, sc.format);
    errdefer {
        for (new_views) |v| self.vkd.destroyImageView(self.device, v, null);
        self.allocator.free(new_views);
    }

    for (self.swapchain_views) |v| self.vkd.destroyImageView(self.device, v, null);
    self.allocator.free(self.swapchain_views);
    self.allocator.free(self.swapchain_images);
    self.vkd.destroySwapchainKHR(self.device, old_swapchain, null);

    self.swapchain = sc.swapchain;
    self.swapchain_images = new_images;
    self.swapchain_views = new_views;
    self.swapchain_format = sc.format;
    self.swapchain_is_srgb = sc.is_srgb;
    self.swapchain_copy_src = sc.copy_src;
    self.swapchain_extent = sc.extent;
    self.present_modes = sc.present_modes;
}

pub fn findMemoryType(self: *const Context, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
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

pub fn beginSingleTimeCommands(self: *const Context) !vk.CommandBuffer {
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

pub const SingleTimeSubmission = struct {
    command_buffer: vk.CommandBuffer,
    fence: vk.Fence,
};

pub fn endSingleTimeCommands(self: *const Context, cmd: vk.CommandBuffer) !SingleTimeSubmission {
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

pub fn finishSingleTimeCommands(self: *const Context, submission: SingleTimeSubmission) !void {
    _ = try self.vkd.waitForFences(self.device, &.{submission.fence}, .true, std.math.maxInt(u64));
    self.vkd.destroyFence(self.device, submission.fence, null);
    self.vkd.freeCommandBuffers(self.device, self.transient_command_pool, &.{submission.command_buffer});
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
    // swapchain report a points-sized (half-resolution) surface on Retina.
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
        .emscripten => @panic("emscripten not supported with the vulkan backend"),
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
        .emscripten => @panic("emscripten not supported with the vulkan backend"),
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

const SwapchainInfo = struct {
    swapchain: vk.SwapchainKHR,
    format: vk.Format,
    extent: vk.Extent2D,
    is_srgb: bool,
    copy_src: bool,
    present_modes: gpu.Context.PresentModes,
};

fn createSwapchain(vki: vk.InstanceWrapper, vkd: vk.DeviceWrapper, physical_device: vk.PhysicalDevice, device: vk.Device, surface: vk.SurfaceKHR, width: u32, height: u32, old_swapchain: vk.SwapchainKHR, cfg: gpu.Context.Config) !SwapchainInfo {
    const caps = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);
    const copy_src = caps.supported_usage_flags.transfer_src_bit;
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
    const is_srgb = switch (cf.format) {
        .b8g8r8a8_srgb, .r8g8b8a8_srgb => true,
        else => false,
    };
    const extent = if (caps.current_extent.width != 0xFFFFFFFF) caps.current_extent else vk.Extent2D{
        .width = std.math.clamp(width, caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(height, caps.min_image_extent.height, caps.max_image_extent.height),
    };
    if (extent.width == 0 or extent.height == 0) return error.SurfaceUnavailable;
    const present_modes = try queryPresentModes(vki, physical_device, surface);
    const present_mode = choosePresentMode(present_modes, cfg.present_mode) orelse return error.UnsupportedPresentMode;
    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0 and image_count > caps.max_image_count) image_count = caps.max_image_count;
    const swapchain = try vkd.createSwapchainKHR(device, &.{
        .surface = surface,
        .min_image_count = image_count,
        .image_format = cf.format,
        .image_color_space = cf.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_src_bit = copy_src },
        .image_sharing_mode = .exclusive,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = .true,
        .old_swapchain = old_swapchain,
    }, null);
    return .{ .swapchain = swapchain, .format = cf.format, .extent = extent, .is_srgb = is_srgb, .copy_src = copy_src, .present_modes = present_modes };
}

fn choosePresentMode(modes: gpu.Context.PresentModes, requested: gpu.Context.PresentMode) ?vk.PresentModeKHR {
    if (!modes.contains(requested)) return null;
    return switch (requested) {
        .fifo => .fifo_khr,
        .fifo_relaxed => .fifo_relaxed_khr,
        .immediate => .immediate_khr,
        .mailbox => .mailbox_khr,
    };
}

fn queryPresentModes(vki: vk.InstanceWrapper, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !gpu.Context.PresentModes {
    var modes = gpu.Context.PresentModes.empty;
    var count: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &count, null);
    var modes_buf: [16]vk.PresentModeKHR = undefined;
    if (count > modes_buf.len) count = @intCast(modes_buf.len);
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &count, &modes_buf);
    for (modes_buf[0..@as(usize, @intCast(count))]) |mode| switch (mode) {
        .fifo_khr => modes.insert(.fifo),
        .fifo_relaxed_khr => modes.insert(.fifo_relaxed),
        .immediate_khr => modes.insert(.immediate),
        .mailbox_khr => modes.insert(.mailbox),
        else => {},
    };
    return modes;
}

fn getSwapchainImages(allocator: std.mem.Allocator, vkd: vk.DeviceWrapper, device: vk.Device, swapchain: vk.SwapchainKHR) ![]vk.Image {
    var count: u32 = 0;
    _ = try vkd.getSwapchainImagesKHR(device, swapchain, &count, null);
    const images = try allocator.alloc(vk.Image, count);
    _ = try vkd.getSwapchainImagesKHR(device, swapchain, &count, images.ptr);
    return images;
}

fn createImageViews(allocator: std.mem.Allocator, vkd: vk.DeviceWrapper, device: vk.Device, images: []vk.Image, format: vk.Format) ![]vk.ImageView {
    const views = try allocator.alloc(vk.ImageView, images.len);
    var created: usize = 0;
    errdefer {
        for (views[0..created]) |v| vkd.destroyImageView(device, v, null);
        allocator.free(views);
    }
    for (images, 0..) |img, i| {
        views[i] = try vkd.createImageView(device, &.{
            .image = img,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        }, null);
        created += 1;
    }
    return views;
}
