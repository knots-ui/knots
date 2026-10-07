//! Wasmtime's C API plus owning Zig handles for core module execution.
//! Engine, Module, Store and Diagnostics have single ownership: do not copy them.
//! Destroy modules and stores before their engine. Store access is single-threaded.
const std = @import("std");
const assert = std.debug.assert;

/// Complete translated C API, including APIs not wrapped below.
pub const c = @import("c");
pub const Value = c.wasmtime_val_t;
pub const Extern = c.wasmtime_extern_t;
pub const Error = error{ OutOfMemory, WasmtimeFailure, Trap, MissingExport, WrongExportType, InvalidMemoryRange };

/// Optional owned diagnostic. Operations replace its previous contents.
pub const Diagnostics = struct {
    failure: ?*c.wasmtime_error_t = null,
    trap: ?*c.wasm_trap_t = null,

    pub fn deinit(self: *Diagnostics) void {
        if (self.failure) |failure| c.wasmtime_error_delete(failure);
        if (self.trap) |trap| c.wasm_trap_delete(trap);
        self.* = .{};
        assert(self.failure == null);
        assert(self.trap == null);
    }

    /// The caller owns the returned message, including for an empty diagnostic.
    pub fn message(self: *const Diagnostics, allocator: std.mem.Allocator) ![]u8 {
        var bytes: c.wasm_byte_vec_t = undefined;
        if (self.failure) |failure| {
            c.wasmtime_error_message(failure, &bytes);
        } else if (self.trap) |trap| {
            c.wasm_trap_message(trap, &bytes);
        } else return allocator.dupe(u8, "");
        defer c.wasm_byte_vec_delete(&bytes);
        assert(bytes.size > 0);
        assert(bytes.data != null);
        return allocator.dupe(u8, std.mem.trimEnd(u8, bytes.data[0..bytes.size], "\x00"));
    }
};

fn check(failure: ?*c.wasmtime_error_t, trap: ?*c.wasm_trap_t, diagnostics: ?*Diagnostics) Error!void {
    // The C API reports either an error or a trap, never both.
    if (failure != null) assert(trap == null);
    if (trap != null) assert(failure == null);
    if (diagnostics) |output| {
        output.deinit();
        output.* = .{ .failure = failure, .trap = trap };
    } else {
        if (failure) |value| c.wasmtime_error_delete(value);
        if (trap) |value| c.wasm_trap_delete(value);
    }
    if (failure != null) return error.WasmtimeFailure;
    if (trap != null) return error.Trap;
}

pub const Engine = struct {
    handle: *c.wasm_engine_t,

    pub const Options = struct {
        consume_fuel: bool,
        compiler: enum { cranelift, winch } = .cranelift,
        threads: bool = false,
        optimize: bool = true,
    };

    pub fn init(options: Options) Error!Engine {
        const config = c.wasm_config_new() orelse return error.OutOfMemory;
        c.wasmtime_config_consume_fuel_set(config, options.consume_fuel);
        c.wasmtime_config_wasm_threads_set(config, options.threads);
        c.wasmtime_config_shared_memory_set(config, options.threads);
        if (!options.optimize) c.wasmtime_config_cranelift_opt_level_set(config, c.WASMTIME_OPT_LEVEL_NONE);
        c.wasmtime_config_strategy_set(config, switch (options.compiler) {
            .cranelift => c.WASMTIME_STRATEGY_CRANELIFT,
            .winch => c.WASMTIME_STRATEGY_WINCH,
        });
        // Engine creation takes ownership of config, including on failure.
        const handle = c.wasm_engine_new_with_config(config) orelse return error.OutOfMemory;
        assert(@intFromPtr(handle) != 0);
        assert(@intFromPtr(config) != 0);
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Engine) void {
        assert(@intFromPtr(self.handle) != 0);
        c.wasm_engine_delete(self.handle);
        self.* = undefined;
    }
};

pub const Module = struct {
    handle: *c.wasmtime_module_t,
    engine: *c.wasm_engine_t,

    pub fn init(engine: Engine, bytes: []const u8, diagnostics: ?*Diagnostics) Error!Module {
        assert(@intFromPtr(engine.handle) != 0);
        var handle: ?*c.wasmtime_module_t = null;
        try check(c.wasmtime_module_new(engine.handle, bytes.ptr, bytes.len, &handle), null, diagnostics);
        assert(handle != null);
        return .{ .handle = handle.?, .engine = engine.handle };
    }

    pub fn deinit(self: *Module) void {
        assert(@intFromPtr(self.handle) != 0);
        assert(@intFromPtr(self.engine) != 0);
        c.wasmtime_module_delete(self.handle);
        self.* = undefined;
    }
};

pub const Store = struct {
    handle: *c.wasmtime_store_t,
    context: *c.wasmtime_context_t,
    engine: *c.wasm_engine_t,

    /// Negative limits select Wasmtime's defaults. Memory/table limits apply
    /// per memory/table, while instance/table/memory counts apply to the store.
    pub const Limits = struct {
        memory_bytes: i64,
        table_elements: i64,
        instances: i64,
        tables: i64,
        memories: i64,
    };

    pub fn init(engine: Engine, limits: *const Limits) Error!Store {
        assert(@intFromPtr(engine.handle) != 0);
        const handle = c.wasmtime_store_new(engine.handle, null, null) orelse return error.OutOfMemory;
        c.wasmtime_store_limiter(handle, limits.memory_bytes, limits.table_elements, limits.instances, limits.tables, limits.memories);
        const context = c.wasmtime_store_context(handle).?;
        assert(@intFromPtr(context) != 0);
        return .{ .handle = handle, .context = context, .engine = engine.handle };
    }

    pub fn deinit(self: *Store) void {
        assert(@intFromPtr(self.handle) != 0);
        assert(@intFromPtr(self.context) != 0);
        c.wasmtime_store_delete(self.handle);
        self.* = undefined;
    }

    pub fn setFuel(self: *Store, amount: u64, diagnostics: ?*Diagnostics) Error!void {
        assert(@intFromPtr(self.handle) != 0);
        assert(@intFromPtr(self.context) != 0);
        try check(c.wasmtime_context_set_fuel(self.context, amount), null, diagnostics);
    }

    pub fn fuel(self: *const Store, diagnostics: ?*Diagnostics) Error!u64 {
        assert(@intFromPtr(self.handle) != 0);
        assert(@intFromPtr(self.context) != 0);
        var remaining: u64 = undefined;
        try check(c.wasmtime_context_get_fuel(self.context, &remaining), null, diagnostics);
        return remaining;
    }
};

/// Borrowed handles retain their originating context and must not outlive its store.
pub const Instance = struct {
    handle: c.wasmtime_instance_t,
    context: *c.wasmtime_context_t,

    /// Imports must belong to this store and match the module's import order.
    pub fn init(store: *Store, module: *const Module, imports: []const Extern, diagnostics: ?*Diagnostics) Error!Instance {
        assert(store.engine == module.engine);
        assert(@intFromPtr(store.context) != 0);
        var handle: c.wasmtime_instance_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        const failure = c.wasmtime_instance_new(store.context, module.handle, imports.ptr, imports.len, &handle, &trap);
        try check(failure, trap, diagnostics);
        return .{ .handle = handle, .context = store.context };
    }

    fn getExport(self: *const Instance, name: []const u8) Error!Extern {
        assert(@intFromPtr(self.context) != 0);
        assert(self.handle.store_id != 0);
        var exported: Extern = undefined;
        if (!c.wasmtime_instance_export_get(self.context, &self.handle, name.ptr, name.len, &exported)) return error.MissingExport;
        assert(exported.kind <= c.WASMTIME_EXTERN_TAG);
        return exported;
    }

    pub fn function(self: *const Instance, name: []const u8) Error!Function {
        var exported = try self.getExport(name);
        defer c.wasmtime_extern_delete(&exported);
        if (exported.kind != c.WASMTIME_EXTERN_FUNC) return error.WrongExportType;
        assert(@intFromPtr(self.context) != 0);
        assert(exported.kind == c.WASMTIME_EXTERN_FUNC);
        return .{ .handle = exported.of.func, .context = self.context };
    }

    pub fn setGlobal(self: *const Instance, name: []const u8, value: Value, diagnostics: ?*Diagnostics) Error!void {
        var exported = try self.getExport(name);
        defer c.wasmtime_extern_delete(&exported);
        if (exported.kind != c.WASMTIME_EXTERN_GLOBAL) return error.WrongExportType;
        try check(c.wasmtime_global_set(self.context, &exported.of.global, &value), null, diagnostics);
    }

    pub fn memory(self: *const Instance, name: []const u8) Error!Memory {
        var exported = try self.getExport(name);
        defer c.wasmtime_extern_delete(&exported);
        if (exported.kind != c.WASMTIME_EXTERN_MEMORY) return error.WrongExportType;
        assert(@intFromPtr(self.context) != 0);
        assert(exported.kind == c.WASMTIME_EXTERN_MEMORY);
        return .{ .handle = exported.of.memory, .context = self.context };
    }
};

pub const Function = struct {
    handle: c.wasmtime_func_t,
    context: *c.wasmtime_context_t,

    /// Wasmtime checks argument/result arity and argument types. On success the
    /// caller must unroot results, including reference values, with unrootValues.
    /// On failure results are uninitialized and must not be read or unrooted.
    pub fn call(self: *const Function, arguments: []const Value, results: []Value, diagnostics: ?*Diagnostics) Error!void {
        assert(@intFromPtr(self.context) != 0);
        assert(self.handle.store_id != 0);
        var trap: ?*c.wasm_trap_t = null;
        const failure = c.wasmtime_func_call(self.context, &self.handle, arguments.ptr, arguments.len, results.ptr, results.len, &trap);
        if (failure != null) assert(trap == null);
        try check(failure, trap, diagnostics);
    }
};

pub fn unrootValues(values: []Value) void {
    for (values) |*value| {
        assert(value.kind <= c.WASMTIME_EXNREF);
        c.wasmtime_val_unroot(value);
    }
    // Consumed roots must never be reused or unrooted a second time.
    @memset(values, undefined);
}

pub const Memory = struct {
    handle: c.wasmtime_memory_t,
    context: *c.wasmtime_context_t,

    pub fn size(self: *const Memory) usize {
        assert(@intFromPtr(self.context) != 0);
        return c.wasmtime_memory_data_size(self.context, &self.handle);
    }

    /// Borrowed bytes are invalidated by memory growth or store destruction.
    /// Reacquire after every guest call. Overflow is checked before slicing.
    pub fn range(self: *const Memory, offset: usize, length: usize) Error![]u8 {
        const length_total = self.size();
        if (offset > length_total) return error.InvalidMemoryRange;
        if (length > length_total - offset) return error.InvalidMemoryRange;
        assert(offset <= length_total);
        assert(length <= length_total - offset);
        const pointer = c.wasmtime_memory_data(self.context, &self.handle);
        return pointer[offset..][0..length];
    }
};

pub const SharedMemory = struct {
    handle: *c.wasmtime_sharedmemory_t,

    pub fn init(engine: Engine, minimum: u64, maximum: u64, diagnostics: ?*Diagnostics) Error!SharedMemory {
        var memory_type: ?*c.wasm_memorytype_t = null;
        try check(c.wasmtime_memorytype_new(minimum, true, maximum, false, true, 16, &memory_type), null, diagnostics);
        defer c.wasm_memorytype_delete(memory_type);
        var handle: ?*c.wasmtime_sharedmemory_t = null;
        try check(c.wasmtime_sharedmemory_new(engine.handle, memory_type, &handle), null, diagnostics);
        return .{ .handle = handle.? };
    }

    pub fn clone(self: SharedMemory) SharedMemory {
        return .{ .handle = c.wasmtime_sharedmemory_clone(self.handle).? };
    }

    pub fn deinit(self: *SharedMemory) void {
        c.wasmtime_sharedmemory_delete(self.handle);
        self.* = undefined;
    }

    pub fn range(self: SharedMemory, offset: usize, length: usize) Error![]u8 {
        const length_total = c.wasmtime_sharedmemory_data_size(self.handle);
        if (offset > length_total) return error.InvalidMemoryRange;
        if (length > length_total - offset) return error.InvalidMemoryRange;
        const pointer = c.wasmtime_sharedmemory_data(self.handle);
        return pointer[offset..][0..length];
    }
};

pub const Linker = struct {
    handle: *c.wasmtime_linker_t,
    engine: *c.wasm_engine_t,

    pub fn init(engine: Engine) Error!Linker {
        const handle = c.wasmtime_linker_new(engine.handle) orelse return error.OutOfMemory;
        return .{ .handle = handle, .engine = engine.handle };
    }

    pub fn deinit(self: *Linker) void {
        c.wasmtime_linker_delete(self.handle);
        self.* = undefined;
    }

    pub fn defineFunction(
        self: *Linker,
        module: []const u8,
        name: []const u8,
        comptime Context: type,
        context: *Context,
        comptime function: anytype,
        diagnostics: ?*Diagnostics,
    ) Error!void {
        const Function_ = @TypeOf(function);
        const info = @typeInfo(Function_).@"fn";
        const parameter_types = info.param_types[1..];
        const Result = switch (@typeInfo(info.return_type.?)) {
            .error_union => |error_union| error_union.payload,
            else => info.return_type.?,
        };

        var parameters: c.wasm_valtype_vec_t = undefined;
        var kinds: [parameter_types.len]?*c.wasm_valtype_t = undefined;
        inline for (parameter_types, 0..) |Parameter, index| kinds[index] = c.wasm_valtype_new(comptime valueKind(Parameter.?));
        c.wasm_valtype_vec_new(&parameters, kinds.len, &kinds);
        var results: c.wasm_valtype_vec_t = undefined;
        if (Result == void) {
            c.wasm_valtype_vec_new_empty(&results);
        } else {
            var result_kinds = [1]?*c.wasm_valtype_t{c.wasm_valtype_new(comptime valueKind(Result))};
            c.wasm_valtype_vec_new(&results, 1, &result_kinds);
        }
        const function_type = c.wasm_functype_new(&parameters, &results) orelse return error.OutOfMemory;
        defer c.wasm_functype_delete(function_type);

        const Callback = struct {
            fn call(env: ?*anyopaque, _: ?*c.wasmtime_caller_t, arguments: [*c]const Value, _: usize, results_out: [*c]Value, _: usize) callconv(.c) ?*c.wasm_trap_t {
                const self_context: *Context = @ptrCast(@alignCast(env.?));
                var values: std.meta.ArgsTuple(Function_) = undefined;
                values[0] = self_context;
                inline for (parameter_types, 0..) |Parameter, index| values[index + 1] = fromValue(Parameter.?, arguments[index]);
                const returned = @call(.auto, function, values);
                const result = if (Result == info.return_type.?) returned else returned catch |err|
                    return c.wasmtime_trap_new(@errorName(err).ptr, @errorName(err).len);
                if (Result != void) results_out[0] = toValue(Result, result);
                return null;
            }
        };
        try check(c.wasmtime_linker_define_func(self.handle, module.ptr, module.len, name.ptr, name.len, function_type, Callback.call, context, null), null, diagnostics);
    }

    pub fn defineSharedMemory(self: *Linker, store: *Store, module: []const u8, name: []const u8, memory: SharedMemory, diagnostics: ?*Diagnostics) Error!void {
        c.wasmtime_linker_allow_shadowing(self.handle, true);
        var item: Extern = .{ .kind = c.WASMTIME_EXTERN_SHAREDMEMORY, .of = .{ .sharedmemory = memory.handle } };
        try check(c.wasmtime_linker_define(self.handle, store.context, module.ptr, module.len, name.ptr, name.len, &item), null, diagnostics);
    }

    pub fn instantiate(self: *Linker, store: *Store, module: *const Module, diagnostics: ?*Diagnostics) Error!Instance {
        assert(store.engine == self.engine);
        var handle: c.wasmtime_instance_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        try check(c.wasmtime_linker_instantiate(self.handle, store.context, module.handle, &handle, &trap), trap, diagnostics);
        return .{ .handle = handle, .context = store.context };
    }

    fn valueKind(comptime T: type) c.wasm_valkind_t {
        return switch (T) {
            bool, u8, u16, u32, i32, usize => c.WASM_I32,
            u64, i64 => c.WASM_I64,
            f32 => c.WASM_F32,
            f64 => c.WASM_F64,
            else => @compileError("unsupported host function type " ++ @typeName(T)),
        };
    }

    fn fromValue(comptime T: type, value: Value) T {
        return switch (T) {
            bool => value.of.i32 != 0,
            u8, u16, u32, usize => @intCast(@as(u32, @bitCast(value.of.i32))),
            i32 => value.of.i32,
            u64 => @bitCast(value.of.i64),
            i64 => value.of.i64,
            f32 => value.of.f32,
            f64 => value.of.f64,
            else => unreachable,
        };
    }

    fn toValue(comptime T: type, value: T) Value {
        return switch (T) {
            bool => .{ .kind = c.WASMTIME_I32, .of = .{ .i32 = @intFromBool(value) } },
            u8, u16, u32, usize => .{ .kind = c.WASMTIME_I32, .of = .{ .i32 = @bitCast(@as(u32, @intCast(value))) } },
            i32 => .{ .kind = c.WASMTIME_I32, .of = .{ .i32 = value } },
            u64 => .{ .kind = c.WASMTIME_I64, .of = .{ .i64 = @bitCast(value) } },
            i64 => .{ .kind = c.WASMTIME_I64, .of = .{ .i64 = value } },
            f32 => .{ .kind = c.WASMTIME_F32, .of = .{ .f32 = value } },
            f64 => .{ .kind = c.WASMTIME_F64, .of = .{ .f64 = value } },
            else => unreachable,
        };
    }
};

/// Converts text format into a caller-owned Wasm binary.
pub fn wat2wasm(allocator: std.mem.Allocator, wat: []const u8, diagnostics: ?*Diagnostics) ![]u8 {
    var bytes: c.wasm_byte_vec_t = undefined;
    try check(c.wasmtime_wat2wasm(wat.ptr, wat.len, &bytes), null, diagnostics);
    defer c.wasm_byte_vec_delete(&bytes);
    assert(bytes.size > 0);
    assert(bytes.data != null);
    return allocator.dupe(u8, bytes.data[0..bytes.size]);
}

test {
    _ = @import("tests.zig");
}
