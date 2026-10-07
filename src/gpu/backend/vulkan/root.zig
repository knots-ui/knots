pub const vk = @import("vk");
pub const Device = @import("Device.zig");
pub const Surface = @import("Surface.zig");
pub const Buffer = @import("Buffer.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const BindGroup = @import("BindGroup.zig");
pub const Frame = @import("Frame.zig");
pub const RenderPass = @import("RenderPass.zig");
pub const Texture = @import("Texture.zig");
pub const Sampler = @import("Sampler.zig");

test {
    _ = @import("MemoryAllocator.zig");
    // Nothing in the tree calls `initExternal` yet; keep it analyzed.
    _ = &Device.initExternal;
}
