const std = @import("std");

pub const memory_initial = 16 * 1024 * 1024;
pub const memory_max = 2 * 1024 * 1024 * 1024;

pub const bridge_export_symbol_names = [_][]const u8{
    "js_bridge_alloc",
    "js_bridge_free",
    "js_bridge_dispatch",
    "js_bridge_pointer_size",
    "knots_last_error_len",
    "knots_last_error_copy",
};

const thread_export_symbol_names = [_][]const u8{
    "knots_worker_run",
    "knots_worker_complete",
    "knots_worker_release",
    "knots_worker_abort",
    "knots_worker_stack_alloc",
    "knots_worker_stack_free",
    "__stack_pointer",
};

pub const Options = struct {
    start_symbol: []const u8 = "main",
    extra_export_symbol_names: []const []const u8 = &.{},
};

pub fn configureExecutable(b: *std.Build, root_module: *std.Build.Module, executable: *std.Build.Step.Compile, threads: bool, options: Options) void {
    std.debug.assert(root_module.resolved_target != null);
    std.debug.assert(executable.root_module.resolved_target != null);
    configureTarget(&root_module.resolved_target.?, threads);
    configureTarget(&executable.root_module.resolved_target.?, threads);
    executable.import_memory = threads;
    executable.export_memory = true;
    executable.export_table = threads;
    executable.shared_memory = threads;
    executable.initial_memory = memory_initial;
    executable.max_memory = memory_max;

    const thread_export_count = if (threads) thread_export_symbol_names.len else 0;
    const names = b.allocator.alloc([]const u8, 1 + bridge_export_symbol_names.len + thread_export_count + options.extra_export_symbol_names.len) catch @panic("OOM");
    names[0] = options.start_symbol;
    for (bridge_export_symbol_names, 0..) |name, index| names[index + 1] = name;
    if (threads) {
        for (thread_export_symbol_names, 0..) |name, index| names[index + 1 + bridge_export_symbol_names.len] = name;
    }
    const extra_start = 1 + bridge_export_symbol_names.len + thread_export_count;
    for (options.extra_export_symbol_names, 0..) |name, index| names[extra_start + index] = name;
    root_module.export_symbol_names = names;
}

pub fn configureTarget(target: *std.Build.ResolvedTarget, threads: bool) void {
    if (!isBrowserWasmTarget(target.result)) return;
    if (!threads) {
        const feature = std.Target.wasm.Feature.atomics;
        target.query.cpu_features_add.removeFeature(@backingInt(feature));
        target.query.cpu_features_sub.addFeature(@backingInt(feature));
        target.result.cpu.features.removeFeature(@backingInt(feature));
        return;
    }
    inline for (.{
        std.Target.wasm.Feature.atomics,
        std.Target.wasm.Feature.bulk_memory,
        std.Target.wasm.Feature.bulk_memory_opt,
    }) |feature| {
        target.query.cpu_features_sub.removeFeature(@backingInt(feature));
        target.query.cpu_features_add.addFeature(@backingInt(feature));
        target.result.cpu.features.addFeature(@backingInt(feature));
    }
}

fn isBrowserWasmTarget(target: std.Target) bool {
    return target.cpu.arch.isWasm() and target.os.tag == .freestanding;
}
