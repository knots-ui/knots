const std = @import("std");
const wasm = @import("root.zig");
const allocator = std.testing.allocator;
const limits: wasm.Store.Limits = .{ .memory_bytes = 2 * 65536, .table_elements = 100, .instances = 2, .tables = 1, .memories = 1 };

test "calls validate signatures, preserve numeric values and support multiple results" {
    var engine = try wasm.Engine.init(.{ .consume_fuel = true });
    defer engine.deinit();
    const bytes = try wasm.wat2wasm(allocator,
        \\(module
        \\ (func (export "echo") (param i32 i64 f32 f64) (result i32 i64 f32 f64)
        \\  local.get 0 local.get 1 local.get 2 local.get 3))
    , null);
    defer allocator.free(bytes);
    var module = try wasm.Module.init(engine, bytes, null);
    defer module.deinit();
    var store = try wasm.Store.init(engine, &limits);
    defer store.deinit();
    try store.setFuel(10000, null);
    const instance = try wasm.Instance.init(&store, &module, &.{}, null);
    const function = try instance.function("echo");
    const arguments = [_]wasm.Value{
        .{ .kind = wasm.c.WASMTIME_I32, .of = .{ .i32 = -12 } },
        .{ .kind = wasm.c.WASMTIME_I64, .of = .{ .i64 = std.math.minInt(i64) } },
        .{ .kind = wasm.c.WASMTIME_F32, .of = .{ .f32 = 1.5 } },
        .{ .kind = wasm.c.WASMTIME_F64, .of = .{ .f64 = -2.5 } },
    };
    var results: [4]wasm.Value = undefined;
    try function.call(&arguments, &results, null);
    defer wasm.unrootValues(&results);
    try std.testing.expectEqual(-12, results[0].of.i32);
    try std.testing.expectEqual(std.math.minInt(i64), results[1].of.i64);
    try std.testing.expectEqual(1.5, results[2].of.f32);
    try std.testing.expectEqual(-2.5, results[3].of.f64);
    try std.testing.expect(try store.fuel(null) < 10000);
    try std.testing.expectError(error.WasmtimeFailure, function.call(&.{}, &results, null));
    try std.testing.expectError(error.WasmtimeFailure, function.call(&arguments, &.{}, null));
    var wrong = arguments;
    wrong[0] = arguments[1];
    try std.testing.expectError(error.WasmtimeFailure, function.call(&wrong, &results, null));
    try std.testing.expectError(error.MissingExport, instance.function("missing"));
    try std.testing.expectError(error.WrongExportType, instance.memory("echo"));
}

test "memory ranges survive reacquisition after growth and reject overflow" {
    var engine = try wasm.Engine.init(.{ .consume_fuel = false });
    defer engine.deinit();
    const bytes = try wasm.wat2wasm(allocator,
        \\(module (memory (export "memory") 1 3)
        \\ (func (export "grow") (result i32) i32.const 1 memory.grow))
    , null);
    defer allocator.free(bytes);
    var module = try wasm.Module.init(engine, bytes, null);
    defer module.deinit();
    var store = try wasm.Store.init(engine, &limits);
    defer store.deinit();
    const instance = try wasm.Instance.init(&store, &module, &.{}, null);
    const memory = try instance.memory("memory");
    try std.testing.expectEqual(65536, memory.size());
    (try memory.range(65535, 1))[0] = 42;
    try std.testing.expectEqual(0, (try memory.range(65536, 0)).len);
    try std.testing.expectError(error.InvalidMemoryRange, memory.range(65536, 1));
    try std.testing.expectError(error.InvalidMemoryRange, memory.range(65537, 0));
    try std.testing.expectError(error.InvalidMemoryRange, memory.range(1, std.math.maxInt(usize)));
    try std.testing.expectError(error.InvalidMemoryRange, memory.range(std.math.maxInt(usize), 1));
    try std.testing.expectError(error.WrongExportType, instance.function("memory"));
    const grow = try instance.function("grow");
    var result: [1]wasm.Value = undefined;
    try grow.call(&.{}, &result, null);
    try std.testing.expectEqual(1, result[0].of.i32);
    wasm.unrootValues(&result);
    try std.testing.expectEqual(2 * 65536, memory.size());
    try std.testing.expectEqual(42, (try memory.range(65535, 1))[0]);
    try grow.call(&.{}, &result, null);
    defer wasm.unrootValues(&result);
    try std.testing.expectEqual(-1, result[0].of.i32);
    try std.testing.expectEqual(2 * 65536, memory.size());
}

test "diagnostics own errors and traps, replacement clears prior failure" {
    var diagnostics: wasm.Diagnostics = .{};
    defer diagnostics.deinit();
    try std.testing.expectError(error.WasmtimeFailure, wasm.wat2wasm(allocator, "invalid", &diagnostics));
    const message = try diagnostics.message(allocator);
    defer allocator.free(message);
    try std.testing.expect(message.len > 0);
    var engine = try wasm.Engine.init(.{ .consume_fuel = true });
    defer engine.deinit();
    try std.testing.expectError(error.WasmtimeFailure, wasm.Module.init(engine, "invalid", &diagnostics));
    const bytes = try wasm.wat2wasm(allocator, "(module (func (export \"spin\") (loop br 0)))", &diagnostics);
    defer allocator.free(bytes);
    try std.testing.expect(diagnostics.failure == null);
    var module = try wasm.Module.init(engine, bytes, &diagnostics);
    defer module.deinit();
    // Repeated destruction covers trapped stores and diagnostic replacement.
    for (0..16) |_| {
        var store = try wasm.Store.init(engine, &limits);
        defer store.deinit();
        try store.setFuel(100, &diagnostics);
        const instance = try wasm.Instance.init(&store, &module, &.{}, &diagnostics);
        const spin = try instance.function("spin");
        try std.testing.expectError(error.Trap, spin.call(&.{}, &.{}, &diagnostics));
        const trap_message = try diagnostics.message(allocator);
        defer allocator.free(trap_message);
        try std.testing.expect(trap_message.len > 0);
        try std.testing.expectEqual(0, try store.fuel(null));
    }
}

test "instantiation reports start traps and missing imports" {
    var engine = try wasm.Engine.init(.{ .consume_fuel = false });
    defer engine.deinit();
    for ([_][]const u8{
        "(module (func $start unreachable) (start $start))",
        "(module (import \"host\" \"function\" (func)))",
    }, 0..) |wat, index| {
        const bytes = try wasm.wat2wasm(allocator, wat, null);
        defer allocator.free(bytes);
        var module = try wasm.Module.init(engine, bytes, null);
        defer module.deinit();
        var store = try wasm.Store.init(engine, &limits);
        defer store.deinit();
        try std.testing.expectError(if (index == 0) error.Trap else error.WasmtimeFailure, wasm.Instance.init(&store, &module, &.{}, null));
    }
}

test "reference results have independent roots and finalize on store destruction" {
    var engine = try wasm.Engine.init(.{ .consume_fuel = false });
    defer engine.deinit();
    const bytes = try wasm.wat2wasm(allocator, "(module (func (export \"echo\") (param externref) (result externref) local.get 0))", null);
    defer allocator.free(bytes);
    var module = try wasm.Module.init(engine, bytes, null);
    defer module.deinit();
    var finalized: usize = 0;
    {
        var store = try wasm.Store.init(engine, &limits);
        defer store.deinit();
        const instance = try wasm.Instance.init(&store, &module, &.{}, null);
        const echo = try instance.function("echo");
        var arguments: [1]wasm.Value = .{.{ .kind = wasm.c.WASMTIME_EXTERNREF, .of = undefined }};
        try std.testing.expect(wasm.c.wasmtime_externref_new(store.context, &finalized, referenceFinalize, &arguments[0].of.externref));
        defer wasm.unrootValues(&arguments);
        var results: [1]wasm.Value = undefined;
        try echo.call(&arguments, &results, null);
        defer wasm.unrootValues(&results);
        try std.testing.expectEqual(@as(?*anyopaque, &finalized), wasm.c.wasmtime_externref_data(store.context, &results[0].of.externref));
        try std.testing.expectEqual(0, finalized);
    }
    try std.testing.expectEqual(1, finalized);
}

fn referenceFinalize(data: ?*anyopaque) callconv(.c) void {
    std.debug.assert(data != null);
    const count: *usize = @ptrCast(@alignCast(data.?));
    std.debug.assert(count.* == 0);
    count.* += 1;
}
