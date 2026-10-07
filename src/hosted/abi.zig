const std = @import("std");
const input = @import("input");
const gpu = @import("gpu");
const window = @import("window");

pub const module = "knots_hosted";

pub const Window = enum(u32) { _ };
pub const Buffer = enum(u32) { _ };
pub const Texture = enum(u32) { _ };
pub const Sampler = enum(u32) { _ };
pub const Pipeline = enum(u32) { _ };
pub const BindGroup = enum(u32) { _ };
pub const Frame = enum(u32) { _ };

pub const Call = union(enum) {
    window: WindowCall,
    gpu: GpuCall,
};

pub const Command = union(enum) {
    window: WindowCommand,
    gpu: GpuCommand,
};

pub fn Reply(comptime T: type) type {
    return union(enum) {
        ok: T,
        failed: Failure,
    };
}

pub const Error = error{
    HostCallFailed,
    OutOfMemory,
    WindowUnavailable,
    SurfaceUnavailable,
    SurfaceLost,
    UnsupportedPresentMode,
    DeviceLost,
};

pub const Failure = enum(u8) {
    host_call_failed,
    out_of_memory,
    window_unavailable,
    surface_unavailable,
    surface_lost,
    unsupported_present_mode,
    device_lost,

    pub fn of(err: anyerror) Failure {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.WindowUnavailable => .window_unavailable,
            error.SurfaceUnavailable => .surface_unavailable,
            error.SurfaceLost => .surface_lost,
            error.UnsupportedPresentMode => .unsupported_present_mode,
            error.DeviceLost => .device_lost,
            else => .host_call_failed,
        };
    }

    pub fn toError(failure: Failure) Error {
        return switch (failure) {
            .host_call_failed => error.HostCallFailed,
            .out_of_memory => error.OutOfMemory,
            .window_unavailable => error.WindowUnavailable,
            .surface_unavailable => error.SurfaceUnavailable,
            .surface_lost => error.SurfaceLost,
            .unsupported_present_mode => error.UnsupportedPresentMode,
            .device_lost => error.DeviceLost,
        };
    }
};

pub const WindowCall = union(enum) {
    open: Open,
    set_title: struct { Window, []const u8 },
    set_display_mode: struct { Window, window.DisplayMode },
    display_mode: Window,
    request_paste: Window,
    set_clipboard_text: struct { Window, []const u8 },

    pub fn Result(comptime tag: std.meta.Tag(WindowCall)) type {
        return switch (tag) {
            .open => Opened,
            .set_display_mode, .set_clipboard_text => bool,
            .display_mode => window.DisplayMode,
            .set_title, .request_paste => void,
        };
    }
};

pub const WindowCommand = union(enum) {
    close: Window,
    request_frame: Window,
    set_cursor_visible: struct { Window, bool },
    set_cursor_shape: struct { Window, input.CursorShape },
};

pub const Open = struct {
    width: u32,
    height: u32,
    title: []const u8,
    resizable: bool,
    min_size: ?input.Size,
    max_size: ?input.Size,
};

pub const Opened = struct {
    window: Window,
    metrics: Metrics,
};

pub const Metrics = struct {
    logical: input.Size,
    physical: input.Size,
    content_scale: f32,
};

pub const Input = struct {
    metrics: Metrics,
    resized: bool,
    closed: bool,
    input: input.Input,
    paste: ?[]const u8,
    drops: []const []const u8,
};

pub const GpuCall = union(enum) {
    device: Window,
    wait_idle,
    create_buffer: gpu.Buffer.Desc,
    resize_buffer: struct { Buffer, u64 },
    create_texture: gpu.Texture.Desc,
    write_texture: TextureWrite,
    create_sampler: gpu.Sampler.Desc,
    create_pipeline: gpu.Pipeline.Desc,
    create_bind_group: BindGroupDesc,
    configure_surface: struct { Window, gpu.Context.Config },
    resize_surface: struct { Window, u32, u32 },
    present_modes: Window,
    create_frame: Window,
    upload_slot_count: Frame,
    begin_frame: Frame,
    begin_render_pass: struct { Frame, RenderPassDesc },
    submit: Frame,
    wait_for_completion: Frame,

    pub fn Result(comptime tag: std.meta.Tag(GpuCall)) type {
        return switch (tag) {
            .device => Device,
            .create_buffer => Buffer,
            .create_texture => Texture,
            .create_sampler => Sampler,
            .create_pipeline => Pipeline,
            .create_bind_group => BindGroup,
            .create_frame => Frame,
            .present_modes => gpu.Context.PresentModes,
            .upload_slot_count, .begin_frame => u32,
            .wait_idle,
            .resize_buffer,
            .write_texture,
            .configure_surface,
            .resize_surface,
            .begin_render_pass,
            .submit,
            .wait_for_completion,
            => void,
        };
    }
};

pub const GpuCommand = union(enum) {
    destroy: Object,
    write_buffer: struct { Buffer, u64, []const u8 },
    prepare_resize: Frame,
    end_render_pass: Frame,
    bind_pipeline: struct { Frame, Pipeline },
    set_bind_group: struct { Frame, u32, BindGroup },
    set_vertex_buffer: struct { Frame, u32, Buffer, u64, u64 },
    set_index_buffer: struct { Frame, Buffer, u64, u64 },
    set_scissor_rect: struct { Frame, u32, u32, u32, u32 },
    set_viewport: struct { Frame, f32, f32, f32, f32 },
    draw: struct { Frame, u32, u32, u32, u32 },
    draw_indexed: struct { Frame, u32, u32, u32, i32, u32 },
};

pub const Object = union(enum) {
    buffer: Buffer,
    texture: Texture,
    sampler: Sampler,
    pipeline: Pipeline,
    bind_group: BindGroup,
    frame: Frame,
    surface: Window,
};

pub const Device = struct {
    surface_format: gpu.Texture.Format,
    surface_is_srgb: bool,
};

pub const TextureWrite = struct {
    texture: Texture,
    data: []const u8,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bytes_per_row: ?u32,
};

pub const BindGroupDesc = struct {
    label: []const u8,
    pipeline: Pipeline,
    layout_index: u32,
    entries: []const BindGroupEntry,
};

pub const BindGroupEntry = struct {
    binding: u32,
    resource: union(enum) {
        buffer: BufferBinding,
        read_only_storage_buffer: BufferBinding,
        texture_view: Texture,
        sampler: Sampler,
    },
};

pub const BufferBinding = struct {
    buffer: Buffer,
    offset: u64,
    size: u64,
};

pub const LoadOp = enum { clear, load };
pub const StoreOp = enum { store, discard };

pub const RenderPassDesc = struct {
    label: []const u8,
    color: struct {
        load_op: LoadOp,
        store_op: StoreOp,
        clear_color: [4]f32,
        target: ?Texture,
    },
    depth: ?struct {
        load_op: LoadOp,
        store_op: StoreOp,
        clear_value: f32,
        target: Texture,
    },
};
