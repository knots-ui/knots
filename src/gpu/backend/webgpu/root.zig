const builtin = @import("builtin");

const is_wasm_freestanding = switch (builtin.cpu.arch) {
    .wasm32, .wasm64 => true,
    else => false,
} and builtin.os.tag == .freestanding;

pub const Device = if (is_wasm_freestanding) @import("browser/Device.zig") else @import("native/Device.zig");
pub const Surface = if (is_wasm_freestanding) @import("browser/Surface.zig") else @import("native/Surface.zig");
pub const Buffer = if (is_wasm_freestanding) @import("browser/Buffer.zig") else @import("native/Buffer.zig");
pub const Pipeline = if (is_wasm_freestanding) @import("browser/Pipeline.zig") else @import("native/Pipeline.zig");
pub const BindGroup = if (is_wasm_freestanding) @import("browser/BindGroup.zig") else @import("native/BindGroup.zig");
pub const Frame = if (is_wasm_freestanding) @import("browser/Frame.zig") else @import("native/Frame.zig");
pub const RenderPass = if (is_wasm_freestanding) @import("browser/RenderPass.zig") else @import("native/RenderPass.zig");
pub const Texture = if (is_wasm_freestanding) @import("browser/Texture.zig") else @import("native/Texture.zig");
pub const Sampler = if (is_wasm_freestanding) @import("browser/Sampler.zig") else @import("native/Sampler.zig");
