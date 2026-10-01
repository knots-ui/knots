const is_browser_wasm = @import("builtin").cpu.arch.isWasm();

pub const Device = if (is_browser_wasm) @import("browser/Device.zig") else @import("native/Device.zig");
pub const Surface = if (is_browser_wasm) @import("browser/Surface.zig") else @import("native/Surface.zig");
pub const Buffer = if (is_browser_wasm) @import("browser/Buffer.zig") else @import("native/Buffer.zig");
pub const Pipeline = if (is_browser_wasm) @import("browser/Pipeline.zig") else @import("native/Pipeline.zig");
pub const BindGroup = if (is_browser_wasm) @import("browser/BindGroup.zig") else @import("native/BindGroup.zig");
pub const Frame = if (is_browser_wasm) @import("browser/Frame.zig") else @import("native/Frame.zig");
pub const RenderPass = if (is_browser_wasm) @import("browser/RenderPass.zig") else @import("native/RenderPass.zig");
pub const Texture = if (is_browser_wasm) @import("browser/Texture.zig") else @import("native/Texture.zig");
pub const Sampler = if (is_browser_wasm) @import("browser/Sampler.zig") else @import("native/Sampler.zig");
