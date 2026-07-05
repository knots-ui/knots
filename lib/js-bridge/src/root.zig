const std = @import("std");

pub const Handle = u32;

pub const Type = enum(u32) {
    undefined,
    null,
    boolean,
    number,
    string,
    bigint,
    function,
    object,
};

pub const Error = error{
    JavaScriptException,
    TooManyCallbacks,
};

pub const Arg = extern struct {
    tag: u32,
    _pad: u32 = 0,
    a: u64 = 0,
    b: u64 = 0,

    pub const Tag = enum(u32) {
        undefined,
        null,
        boolean,
        i32,
        u32,
        f64,
        handle,
        string,
        bytes,
        u64,
        usize,
    };

    pub fn @"undefined"() Arg {
        return .{ .tag = @intFromEnum(Tag.undefined) };
    }

    pub fn @"null"() Arg {
        return .{ .tag = @intFromEnum(Tag.null) };
    }

    pub fn boolean(v: bool) Arg {
        return .{ .tag = @intFromEnum(Tag.boolean), .a = @intFromBool(v) };
    }

    pub fn @"i32"(v: i32) Arg {
        return .{ .tag = @intFromEnum(Tag.i32), .a = @bitCast(@as(i64, v)) };
    }

    pub fn @"u32"(v: u32) Arg {
        return .{ .tag = @intFromEnum(Tag.u32), .a = v };
    }

    pub fn @"f64"(v: f64) Arg {
        return .{ .tag = @intFromEnum(Tag.f64), .a = @bitCast(v) };
    }

    pub fn value(v: Value) Arg {
        return .{ .tag = @intFromEnum(Tag.handle), .a = v.handle };
    }

    pub fn string(v: []const u8) Arg {
        return .{
            .tag = @intFromEnum(Tag.string),
            .a = @intCast(@intFromPtr(v.ptr)),
            .b = @intCast(v.len),
        };
    }

    pub fn bytes(v: []const u8) Arg {
        return .{
            .tag = @intFromEnum(Tag.bytes),
            .a = @intCast(@intFromPtr(v.ptr)),
            .b = @intCast(v.len),
        };
    }

    pub fn @"u64"(v: u64) Arg {
        return .{ .tag = @intFromEnum(Tag.u64), .a = v };
    }

    pub fn @"usize"(v: usize) Arg {
        return .{ .tag = @intFromEnum(Tag.usize), .a = @intCast(v) };
    }
};

pub const Value = struct {
    handle: Handle,

    pub const invalid: Value = .{ .handle = 0 };
    pub const @"undefined": Value = .{ .handle = 1 };
    pub const @"null": Value = .{ .handle = 2 };
    pub const true_value: Value = .{ .handle = 3 };
    pub const false_value: Value = .{ .handle = 4 };
    pub const global_this: Value = .{ .handle = 5 };

    pub fn retain(self: Value) Value {
        return .{ .handle = imports.js_bridge_retain(self.handle) };
    }

    pub fn release(self: Value) void {
        imports.js_bridge_release(self.handle);
    }

    pub fn get(self: Value, name: []const u8) Error!Value {
        return valueFromHandle(imports.js_bridge_get(self.handle, name.ptr, name.len));
    }

    pub fn getIndex(self: Value, index: u32) Error!Value {
        return valueFromHandle(imports.js_bridge_get_index(self.handle, index));
    }

    pub fn set(self: Value, name: []const u8, arg: Arg) Error!void {
        if (imports.js_bridge_set(self.handle, name.ptr, name.len, &arg) == 0) return error.JavaScriptException;
    }

    pub fn setIndex(self: Value, index: u32, arg: Arg) Error!void {
        if (imports.js_bridge_set_index(self.handle, index, &arg) == 0) return error.JavaScriptException;
    }

    pub fn call(self: Value, name: []const u8, args: []const Arg) Error!Value {
        return valueFromHandle(imports.js_bridge_call(self.handle, name.ptr, name.len, argPtr(args), args.len));
    }

    pub fn callVoid(self: Value, name: []const u8, args: []const Arg) Error!void {
        const result = try self.call(name, args);
        result.release();
    }

    pub fn callFunction(self: Value, this_arg: Value, args: []const Arg) Error!Value {
        return valueFromHandle(imports.js_bridge_call_function(self.handle, this_arg.handle, argPtr(args), args.len));
    }

    pub fn callFunctionVoid(self: Value, this_arg: Value, args: []const Arg) Error!void {
        const result = try self.callFunction(this_arg, args);
        result.release();
    }

    pub fn push(self: Value, arg: Arg) Error!void {
        if (imports.js_bridge_array_push(self.handle, &arg) == 0) return error.JavaScriptException;
    }

    pub fn typeOf(self: Value) Type {
        return @enumFromInt(imports.js_bridge_typeof(self.handle));
    }

    pub fn isNullish(self: Value) bool {
        const t = self.typeOf();
        return t == .undefined or t == .null;
    }

    pub fn tryBool(self: Value) Error!bool {
        var out: u32 = 0;
        if (imports.js_bridge_as_bool(self.handle, &out) == 0) return error.JavaScriptException;
        return out != 0;
    }

    pub fn tryI32(self: Value) Error!i32 {
        var out: i32 = 0;
        if (imports.js_bridge_as_i32(self.handle, &out) == 0) return error.JavaScriptException;
        return out;
    }

    pub fn tryU32(self: Value) Error!u32 {
        var out: u32 = 0;
        if (imports.js_bridge_as_u32(self.handle, &out) == 0) return error.JavaScriptException;
        return out;
    }

    pub fn tryUsize(self: Value) Error!usize {
        var out: usize = 0;
        if (imports.js_bridge_as_usize(self.handle, &out) == 0) return error.JavaScriptException;
        return out;
    }

    pub fn tryF64(self: Value) Error!f64 {
        var out: f64 = 0;
        if (imports.js_bridge_as_f64(self.handle, &out) == 0) return error.JavaScriptException;
        return out;
    }

    pub fn eqlString(self: Value, expected: []const u8) bool {
        return imports.js_bridge_string_eq(self.handle, expected.ptr, expected.len) != 0;
    }

    pub fn strictEqual(self: Value, other: Value) bool {
        return imports.js_bridge_strict_equal(self.handle, other.handle) != 0;
    }

    pub fn toOwnedString(self: Value, allocator: std.mem.Allocator) ![]u8 {
        var len_raw: usize = 0;
        if (imports.js_bridge_string_len(self.handle, &len_raw) == 0) return error.JavaScriptException;
        const len = len_raw;
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        if (len == 0) return out;
        var copied: usize = 0;
        if (imports.js_bridge_string_copy(self.handle, out.ptr, out.len, &copied) == 0) return error.JavaScriptException;
        if (copied != len) return error.JavaScriptException;
        return out;
    }
};

pub const ObjectBuilder = struct {
    value: Value,

    pub fn init() Error!ObjectBuilder {
        return .{ .value = try newObject() };
    }

    pub fn set(self: *const ObjectBuilder, name: []const u8, arg: Arg) Error!void {
        try self.value.set(name, arg);
    }

    pub fn finish(self: ObjectBuilder) Value {
        return self.value;
    }
};

pub const Callback = struct {
    id: u32,
    function: Value,

    pub fn init(context: ?*anyopaque, invoke: *const fn (?*anyopaque, Value, u32) void) Error!Callback {
        const id = registerCallback(.{ .context = context, .invoke = invoke }) orelse return error.TooManyCallbacks;
        const function = valueFromHandle(imports.js_bridge_callback(id)) catch |err| {
            unregisterCallback(id);
            return err;
        };
        return .{ .id = id, .function = function };
    }

    pub fn deinit(self: *Callback) void {
        self.function.release();
        unregisterCallback(self.id);
        self.id = 0;
        self.function = .invalid;
    }
};

const CallbackEntry = struct {
    context: ?*anyopaque,
    invoke: *const fn (?*anyopaque, Value, u32) void,
};

const max_callbacks = 256;
var callbacks: [max_callbacks]?CallbackEntry = @splat(null);

pub fn global(name: []const u8) Error!Value {
    return valueFromHandle(imports.js_bridge_global(name.ptr, name.len));
}

pub fn host() Error!Value {
    return valueFromHandle(imports.js_bridge_host());
}

pub fn newObject() Error!Value {
    return valueFromHandle(imports.js_bridge_new_object());
}

pub fn newArray() Error!Value {
    return valueFromHandle(imports.js_bridge_new_array());
}

pub fn construct(constructor: Value, args: []const Arg) Error!Value {
    return valueFromHandle(imports.js_bridge_construct(constructor.handle, argPtr(args), args.len));
}

pub fn lastError(allocator: std.mem.Allocator) ![]u8 {
    const len = imports.js_bridge_last_error_len();
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    if (len == 0) return out;
    const copied = imports.js_bridge_last_error_copy(out.ptr, out.len);
    if (copied != len) return error.JavaScriptException;
    return out;
}

pub fn alloc(len: usize) usize {
    if (len == 0) return 0;
    const bytes = std.heap.wasm_allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(bytes.ptr);
}

pub fn free(ptr: usize, len: usize) void {
    if (ptr == 0 or len == 0) return;
    const bytes: [*]u8 = @ptrFromInt(ptr);
    std.heap.wasm_allocator.free(bytes[0..len]);
}

pub fn dispatch(id: u32, args_handle: Handle, args_len: u32) void {
    if (id == 0 or id > callbacks.len) return;
    const entry = callbacks[id - 1] orelse return;
    entry.invoke(entry.context, .{ .handle = args_handle }, args_len);
}

fn valueFromHandle(handle: Handle) Error!Value {
    if (handle == 0) return error.JavaScriptException;
    return .{ .handle = handle };
}

fn argPtr(args: []const Arg) ?[*]const Arg {
    return if (args.len == 0) null else args.ptr;
}

fn registerCallback(entry: CallbackEntry) ?u32 {
    for (&callbacks, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = entry;
            return @intCast(i + 1);
        }
    }
    return null;
}

fn unregisterCallback(id: u32) void {
    if (id == 0 or id > callbacks.len) return;
    callbacks[id - 1] = null;
}

const imports = struct {
    extern "js_bridge" fn js_bridge_host() Handle;
    extern "js_bridge" fn js_bridge_global(name_ptr: [*]const u8, name_len: usize) Handle;
    extern "js_bridge" fn js_bridge_get(object: Handle, name_ptr: [*]const u8, name_len: usize) Handle;
    extern "js_bridge" fn js_bridge_get_index(object: Handle, index: u32) Handle;
    extern "js_bridge" fn js_bridge_set(object: Handle, name_ptr: [*]const u8, name_len: usize, arg: *const Arg) i32;
    extern "js_bridge" fn js_bridge_set_index(object: Handle, index: u32, arg: *const Arg) i32;
    extern "js_bridge" fn js_bridge_call(object: Handle, name_ptr: [*]const u8, name_len: usize, args: ?[*]const Arg, args_len: usize) Handle;
    extern "js_bridge" fn js_bridge_call_function(function: Handle, this_arg: Handle, args: ?[*]const Arg, args_len: usize) Handle;
    extern "js_bridge" fn js_bridge_construct(constructor: Handle, args: ?[*]const Arg, args_len: usize) Handle;
    extern "js_bridge" fn js_bridge_new_object() Handle;
    extern "js_bridge" fn js_bridge_new_array() Handle;
    extern "js_bridge" fn js_bridge_array_push(array: Handle, arg: *const Arg) i32;
    extern "js_bridge" fn js_bridge_callback(id: u32) Handle;
    extern "js_bridge" fn js_bridge_retain(handle: Handle) Handle;
    extern "js_bridge" fn js_bridge_release(handle: Handle) void;
    extern "js_bridge" fn js_bridge_typeof(handle: Handle) u32;
    extern "js_bridge" fn js_bridge_as_bool(handle: Handle, out: *u32) i32;
    extern "js_bridge" fn js_bridge_as_i32(handle: Handle, out: *i32) i32;
    extern "js_bridge" fn js_bridge_as_u32(handle: Handle, out: *u32) i32;
    extern "js_bridge" fn js_bridge_as_usize(handle: Handle, out: *usize) i32;
    extern "js_bridge" fn js_bridge_as_f64(handle: Handle, out: *f64) i32;
    extern "js_bridge" fn js_bridge_string_len(handle: Handle, out: *usize) i32;
    extern "js_bridge" fn js_bridge_string_copy(handle: Handle, out_ptr: [*]u8, out_len: usize, out_copied: *usize) i32;
    extern "js_bridge" fn js_bridge_string_eq(handle: Handle, expected_ptr: [*]const u8, expected_len: usize) i32;
    extern "js_bridge" fn js_bridge_strict_equal(a: Handle, b: Handle) i32;
    extern "js_bridge" fn js_bridge_last_error_len() usize;
    extern "js_bridge" fn js_bridge_last_error_copy(out_ptr: [*]u8, out_len: usize) usize;
};

test "argument layout is stable for the JS decoder" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Arg));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Arg, "tag"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Arg, "a"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Arg, "b"));
}

test "reserved handles match the JS runtime" {
    try std.testing.expectEqual(@as(Handle, 0), Value.invalid.handle);
    try std.testing.expectEqual(@as(Handle, 1), Value.undefined.handle);
    try std.testing.expectEqual(@as(Handle, 2), Value.null.handle);
    try std.testing.expectEqual(@as(Handle, 5), Value.global_this.handle);
}

test "usize arguments preserve the native pointer width" {
    const arg = Arg.usize(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(usize)), arg.a);
}
