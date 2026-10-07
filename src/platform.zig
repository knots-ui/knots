const config = @import("platform_config");

pub const Platform = @TypeOf(config.platform);
pub const current: Platform = config.platform;
pub const is_wasm = current != .native;
pub const secondary_windows = current != .browser;
pub const dev = config.dev;
