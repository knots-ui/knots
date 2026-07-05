const builtin = @import("builtin");

pub const is_browser_wasm = builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding;
