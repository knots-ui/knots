//! Moves the variables of a module to its next build. Values match by
//! name, so a reordered or renamed field keeps what it can, and a value that
//! no longer fits keeps the new default.

const std = @import("std");

pub const bytes_max: usize = 32 * 1024 * 1024;
pub const declaration_name = "knots.hmr.vars";

const depth_max: u32 = 64;

pub const Error = error{ OutOfMemory, SnapshotTooLarge, InvalidSnapshot, SnapshotTooDeep };

const Tag = enum(u8) {
    skipped = 0,
    void,
    bool,
    int,
    float,
    enumeration,
    optional,
    array,
    structure,
    slice,
    byte_slice,
    allocator,
    @"union",
    map,
};

pub fn snapshot(comptime vars: anytype, module_allocator: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    var writer: Writer = .{ .list = out, .allocator = module_allocator };
    try writer.int(u32, vars.len);
    inline for (vars) |variable| {
        try writer.bytes(variable.name);
        try writer.int(u64, variable.initial);
        try writer.value(@TypeOf(variable.pointer.*), variable.pointer, 0);
    }
}

pub fn restore(comptime vars: anytype, bytes: []const u8, module_allocator: std.mem.Allocator, report: *std.ArrayList(u8)) Error!void {
    var reader: Reader = .{ .data = bytes, .allocator = module_allocator };
    defer reader.path.deinit(module_allocator);
    defer reader.resets.deinit(module_allocator);

    const count = try reader.int(u32);
    var restored: u32 = 0;
    for (0..count) |_| {
        const name = try reader.bytes();
        const initial = try reader.int(u64);
        const matched = inline for (vars) |variable| {
            if (std.mem.eql(u8, name, variable.name)) {
                if (try reader.variable(variable, initial))
                    restored += 1;

                break true;
            }
        } else false;

        // The new build removed this variable.
        if (!matched)
            try reader.skip();
    }

    if (reader.offset != reader.data.len)
        return error.InvalidSnapshot;

    try report.print(module_allocator, "restored={d} reset=[{s}]", .{ restored, reader.resets.items });
}

const Writer = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn raw(self: *Writer, data: []const u8) Error!void {
        if (data.len > bytes_max - self.list.items.len)
            return error.SnapshotTooLarge;

        try self.list.appendSlice(self.allocator, data);
    }

    fn int(self: *Writer, comptime I: type, number: I) Error!void {
        var buffer: [@sizeOf(I)]u8 = undefined;
        std.mem.writeInt(I, &buffer, number, .little);
        try self.raw(&buffer);
    }

    fn tag(self: *Writer, kind: Tag) Error!void {
        try self.int(u8, @backingInt(kind));
    }

    fn bytes(self: *Writer, data: []const u8) Error!void {
        if (data.len > bytes_max)
            return error.SnapshotTooLarge;

        try self.int(u32, @intCast(data.len));
        try self.raw(data);
    }

    fn value(self: *Writer, comptime T: type, pointer: *const T, depth: u32) Error!void {
        if (depth > depth_max)
            return error.SnapshotTooDeep;

        if (T == std.mem.Allocator) {
            try self.tag(.allocator);
            return self.int(u8, @intFromBool(sameAllocator(pointer.*, self.allocator)));
        }

        if (comptime mapLike(T)) {
            try self.tag(.map);
            if (pointer.count() > std.math.maxInt(u32))
                return error.SnapshotTooLarge;

            try self.int(u32, @intCast(pointer.count()));
            var iterator = pointer.iterator();
            while (iterator.next()) |entry| {
                try self.value(MapKey(T), entry.key_ptr, depth + 1);
                try self.value(MapValue(T), entry.value_ptr, depth + 1);
            }
            return;
        }

        switch (@typeInfo(T)) {
            .void => try self.tag(.void),
            .bool => {
                try self.tag(.bool);
                try self.int(u8, @intFromBool(pointer.*));
            },
            .int => |info| {
                if (info.bits > 128)
                    return self.tag(.skipped);

                try self.tag(.int);
                try self.int(u8, @intFromBool(info.signedness == .signed));
                if (info.signedness == .signed) {
                    try self.int(i128, pointer.*);
                } else {
                    try self.int(u128, pointer.*);
                }
            },
            .float => |info| {
                if (info.bits > 64)
                    return self.tag(.skipped);

                try self.tag(.float);
                try self.int(u64, @bitCast(@as(f64, @floatCast(pointer.*))));
            },
            .@"enum" => |info| {
                inline for (info.field_names, info.field_values) |name, field_value| {
                    if (@backingInt(pointer.*) == field_value) {
                        try self.tag(.enumeration);
                        return self.bytes(name);
                    }
                }

                try self.tag(.skipped);
            },
            .optional => |info| {
                try self.tag(.optional);
                if (pointer.*) |child| {
                    try self.int(u8, 1);
                    try self.value(info.child, &child, depth + 1);
                } else {
                    try self.int(u8, 0);
                }
            },
            .array => |info| {
                try self.tag(.array);
                try self.int(u32, info.len);
                for (pointer) |*element|
                    try self.value(info.child, element, depth + 1);
            },
            .vector => |info| {
                const items: [info.len]info.child = pointer.*;
                try self.value([info.len]info.child, &items, depth);
            },
            .@"struct" => |info| {
                try self.tag(.structure);
                comptime var fields: u32 = 0;
                inline for (info.field_attrs) |attrs| {
                    if (!attrs.@"comptime")
                        fields += 1;
                }

                try self.int(u32, fields);
                inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                    if (attrs.@"comptime")
                        continue;

                    try self.bytes(name);

                    // A packed field has no address.
                    const field_value: Field = @field(pointer.*, name);
                    try self.value(Field, &field_value, depth + 1);
                }
            },
            .pointer => |info| {
                if (info.size != .slice or !runtimeType(info.child))
                    return self.tag(.skipped);

                if (info.child == u8) {
                    try self.tag(.byte_slice);
                    return self.bytes(pointer.*);
                }

                try self.tag(.slice);
                if (pointer.len > std.math.maxInt(u32))
                    return error.SnapshotTooLarge;

                try self.int(u32, @intCast(pointer.len));
                for (pointer.*) |*element|
                    try self.value(info.child, element, depth + 1);
            },
            .@"union" => |info| {
                const Kind = info.tag_type orelse return self.tag(.skipped);
                inline for (info.field_names, info.field_types) |name, Field| {
                    if (pointer.* == @field(Kind, name)) {
                        try self.tag(.@"union");
                        try self.bytes(name);
                        const payload: Field = @field(pointer.*, name);
                        return self.value(Field, &payload, depth + 1);
                    }
                }
                unreachable;
            },
            else => try self.tag(.skipped),
        }
    }
};

const Reader = struct {
    data: []const u8,
    offset: usize = 0,
    allocator: std.mem.Allocator,
    path: std.ArrayList(u8) = .empty,
    resets: std.ArrayList(u8) = .empty,
    reset_count: u32 = 0,
    uncaptured: bool = false,

    fn variable(self: *Reader, comptime entry: anytype, initial: u64) Error!bool {
        self.path.clearRetainingCapacity();
        try self.path.appendSlice(self.allocator, entry.name);
        if (initial != entry.initial) {
            try self.skip();
            try self.reset("default changed");
            return false;
        }

        const resets_before = self.reset_count;
        self.uncaptured = false;
        _ = try self.value(@TypeOf(entry.pointer.*), entry.pointer, true, 0);
        if (self.uncaptured and self.reset_count == resets_before)
            try self.reset("not captured");

        return self.reset_count == resets_before;
    }

    fn raw(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.data.len - self.offset)
            return error.InvalidSnapshot;

        const result = self.data[self.offset..][0..count];
        self.offset += count;
        return result;
    }

    fn int(self: *Reader, comptime I: type) Error!I {
        return std.mem.readInt(I, (try self.raw(@sizeOf(I)))[0..@sizeOf(I)], .little);
    }

    fn tag(self: *Reader) Error!Tag {
        const number = try self.int(u8);
        inline for (@typeInfo(Tag).@"enum".field_values) |field_value| {
            if (number == field_value)
                return @fromBackingInt(field_value);
        }
        return error.InvalidSnapshot;
    }

    fn bytes(self: *Reader) Error![]const u8 {
        return self.raw(try self.int(u32));
    }

    fn reset(self: *Reader, reason: []const u8) Error!void {
        if (self.resets.items.len > 0)
            try self.resets.append(self.allocator, ',');

        try self.resets.print(self.allocator, "{s} ({s})", .{ self.path.items, reason });
        self.reset_count += 1;
    }

    /// If `valid` is true, `target` holds the new default, and a value that
    /// does not fit leaves it unchanged. If `valid` is false, `target` is
    /// undefined, and the result tells if it is now fully initialized.
    fn value(self: *Reader, comptime T: type, target: *T, valid: bool, depth: u32) Error!bool {
        if (depth > depth_max)
            return error.SnapshotTooDeep;

        const kind = try self.tag();
        if (kind == .skipped) {
            self.uncaptured = true;
            return self.keep(valid, "not captured");
        }

        if (T == std.mem.Allocator) {
            if (kind != .allocator)
                return self.mismatch(kind, valid);

            if (try self.int(u8) == 1) {
                target.* = self.allocator;
                return true;
            }

            return self.keep(valid, "foreign allocator");
        }

        if (comptime mapLike(T)) {
            if (kind != .map)
                return self.mismatch(kind, valid);

            return self.map(T, target, valid, depth);
        }

        switch (@typeInfo(T)) {
            .void => {
                if (kind != .void)
                    return self.mismatch(kind, valid);

                return true;
            },
            .bool => {
                if (kind != .bool)
                    return self.mismatch(kind, valid);

                target.* = try self.int(u8) != 0;
                return true;
            },
            .int => {
                if (kind != .int)
                    return self.mismatch(kind, valid);

                target.* = try self.integer(T) orelse return self.keep(valid, "out of range");
                return true;
            },
            .float => {
                if (kind != .float)
                    return self.mismatch(kind, valid);

                target.* = @floatCast(@as(f64, @bitCast(try self.int(u64))));
                return true;
            },
            .@"enum" => |info| {
                if (kind != .enumeration)
                    return self.mismatch(kind, valid);

                const name = try self.bytes();
                inline for (info.field_names) |field_name| {
                    if (std.mem.eql(u8, name, field_name)) {
                        target.* = @field(T, field_name);
                        return true;
                    }
                }

                return self.keep(valid, "enum tag removed");
            },
            .optional => |info| {
                if (kind != .optional)
                    return self.mismatch(kind, valid);

                if (try self.int(u8) == 0) {
                    target.* = null;
                    return true;
                }

                const child_valid = valid and target.* != null;
                var child: info.child = undefined;
                if (child_valid)
                    child = target.*.?;

                if (!try self.value(info.child, &child, child_valid, depth + 1))
                    return valid;

                target.* = child;
                return true;
            },
            .array => |info| {
                if (kind != .array)
                    return self.mismatch(kind, valid);

                return self.elements(info.child, info.len, target, valid, depth);
            },
            .vector => |info| {
                if (kind != .array)
                    return self.mismatch(kind, valid);

                var items: [info.len]info.child = undefined;
                if (valid)
                    items = target.*;

                if (!try self.elements(info.child, info.len, &items, valid, depth))
                    return false;

                target.* = items;
                return true;
            },
            .@"struct" => {
                if (kind != .structure)
                    return self.mismatch(kind, valid);

                return self.structure(T, target, valid, depth);
            },
            .pointer => |info| {
                if (info.size != .slice)
                    return self.mismatch(kind, valid);

                target.* = try self.slice(info, kind, depth) orelse return self.keep(valid, "element type changed");
                return true;
            },
            .@"union" => |info| {
                if (info.tag_type == null or kind != .@"union")
                    return self.mismatch(kind, valid);

                return self.variant(T, target, valid, depth);
            },
            else => return self.mismatch(kind, valid),
        }
    }

    fn integer(self: *Reader, comptime T: type) Error!?T {
        if (try self.int(u8) != 0)
            return std.math.cast(T, try self.int(i128));

        return std.math.cast(T, try self.int(u128));
    }

    fn structure(self: *Reader, comptime T: type, target: *T, valid: bool, depth: u32) Error!bool {
        const info = @typeInfo(T).@"struct";

        // An ArrayList's capacity must match the new allocation.
        const list_like = comptime listLike(T);
        const count = try self.int(u32);
        const outer_uncaptured = self.uncaptured;
        defer self.uncaptured = outer_uncaptured;
        self.uncaptured = false;

        var result: T = undefined;
        if (valid)
            result = target.*;

        var seen: [info.field_names.len]bool = @splat(false);
        var fields_valid = true;
        for (0..count) |_| {
            const name = try self.bytes();
            const matched = inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, Field, attrs, index| {
                if (!attrs.@"comptime" and std.mem.eql(u8, name, field_name)) {
                    if (list_like and comptime std.mem.eql(u8, field_name, "capacity")) {
                        try self.skip();
                    } else {
                        seen[index] = true;
                        const mark = try self.push(".{s}", .{field_name});
                        defer self.pop(mark);

                        var field_value: Field = @field(result, field_name);
                        if (!try self.value(Field, &field_value, valid, depth + 1))
                            fields_valid = false;

                        @field(result, field_name) = field_value;
                    }
                    break true;
                }
            } else false;

            if (!matched)
                try self.skip();
        }

        if (self.uncaptured)
            return self.keep(valid, "holds a pointer");

        if (list_like and (valid or seen[comptime fieldIndex(T, "items")])) {
            result.capacity = result.items.len;
            seen[comptime fieldIndex(T, "capacity")] = true;
        }

        if (valid) {
            target.* = result;
            return true;
        }

        // A new field without a default makes the value unusable.
        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, Field, attrs, index| {
            if (!attrs.@"comptime" and !seen[index]) {
                if (attrs.defaultValue(Field)) |default| {
                    @field(result, field_name) = default;
                } else {
                    fields_valid = false;
                }
            }
        }

        if (fields_valid)
            target.* = result;

        return fields_valid;
    }

    fn variant(self: *Reader, comptime T: type, target: *T, valid: bool, depth: u32) Error!bool {
        const info = @typeInfo(T).@"union";
        const name = try self.bytes();
        inline for (info.field_names, info.field_types) |field_name, Field| {
            if (std.mem.eql(u8, name, field_name)) {
                const same = valid and target.* == @field(info.tag_type.?, field_name);
                var payload: Field = undefined;
                if (same)
                    payload = @field(target.*, field_name);

                const mark = try self.push("({s})", .{field_name});
                defer self.pop(mark);

                if (!try self.value(Field, &payload, same, depth + 1))
                    return self.keep(valid, "variant changed");

                target.* = @unionInit(T, field_name, payload);
                return true;
            }
        }

        try self.skip();
        return self.keep(valid, "variant removed");
    }

    fn keep(self: *Reader, valid: bool, reason: []const u8) Error!bool {
        if (valid)
            try self.reset(reason);

        return valid;
    }

    fn map(self: *Reader, comptime T: type, target: *T, valid: bool, depth: u32) Error!bool {
        const count = try self.int(u32);
        var result: T = .{};
        var all_valid = true;
        for (0..count) |_| {
            var key: MapKey(T) = undefined;
            var entry_value: MapValue(T) = undefined;
            const key_valid = try self.value(MapKey(T), &key, false, depth + 1);
            const value_valid = try self.value(MapValue(T), &entry_value, false, depth + 1);
            if (!key_valid or !value_valid) {
                all_valid = false;
                continue;
            }

            if (all_valid)
                try result.putContext(self.allocator, key, entry_value, undefined);
        }

        // A discarded map leaks, like a discarded slice.
        if (all_valid) {
            target.* = result;
            return true;
        }

        return self.keep(valid, "entry type changed");
    }

    fn elements(self: *Reader, comptime Child: type, comptime len: usize, target: *[len]Child, valid: bool, depth: u32) Error!bool {
        const count = try self.int(u32);
        var all_valid = count >= len;
        for (0..count) |index| {
            if (index >= len) {
                try self.skip();
                continue;
            }

            const mark = try self.push("[{d}]", .{index});
            defer self.pop(mark);

            if (!try self.value(Child, &target[index], valid, depth + 1))
                all_valid = false;
        }

        if (count != len and valid)
            try self.reset("length changed");

        return valid or all_valid;
    }

    fn slice(self: *Reader, comptime info: std.builtin.Type.Pointer, kind: Tag, depth: u32) Error!?SliceType(info) {
        const Child = info.child;
        if (!runtimeType(Child)) {
            try self.skipPayload(kind);
            return null;
        }

        if (kind == .byte_slice) {
            if (Child != u8) {
                try self.skipPayload(kind);
                return null;
            }
            const data = try self.bytes();
            const result = try self.allocSlice(info, data.len);
            @memcpy(result, data);
            return result;
        }

        if (kind != .slice) {
            try self.skipPayload(kind);
            return null;
        }

        const count = try self.int(u32);
        const result = try self.allocSlice(info, count);
        var all_valid = true;
        for (result) |*element| {
            if (!try self.value(Child, element, false, depth + 1))
                all_valid = false;
        }

        // A discarded slice leaks. This is acceptable in development builds.
        if (!all_valid)
            return null;

        return result;
    }

    fn allocSlice(self: *Reader, comptime info: std.builtin.Type.Pointer, count: usize) Error!MutableSlice(info) {
        if (comptime info.sentinel()) |sentinel| {
            if (info.attrs.@"align" != null)
                @compileError("aligned sentinel slices are not supported");

            return self.allocator.allocSentinel(info.child, count, sentinel);
        }

        const bytes_align = info.attrs.@"align" orelse return self.allocator.alignedAlloc(info.child, null, count);
        return self.allocator.alignedAlloc(info.child, .fromByteUnits(bytes_align), count);
    }

    fn mismatch(self: *Reader, kind: Tag, valid: bool) Error!bool {
        try self.skipPayload(kind);
        return self.keep(valid, "type changed");
    }

    fn skip(self: *Reader) Error!void {
        try self.skipPayload(try self.tag());
    }

    fn skipPayload(self: *Reader, kind: Tag) Error!void {
        switch (kind) {
            .skipped, .void => {},
            .bool, .allocator => _ = try self.raw(1),
            .int => _ = try self.raw(1 + 16),
            .float => _ = try self.raw(8),
            .enumeration, .byte_slice => _ = try self.bytes(),
            .optional => if (try self.int(u8) != 0) try self.skip(),
            .array, .slice => for (0..try self.int(u32)) |_| try self.skip(),
            .structure => for (0..try self.int(u32)) |_| {
                _ = try self.bytes();
                try self.skip();
            },
            .@"union" => {
                _ = try self.bytes();
                try self.skip();
            },
            .map => for (0..try self.int(u32)) |_| {
                try self.skip();
                try self.skip();
            },
        }
    }

    fn push(self: *Reader, comptime format: []const u8, arguments: anytype) Error!usize {
        const mark = self.path.items.len;
        try self.path.print(self.allocator, format, arguments);
        return mark;
    }

    fn pop(self: *Reader, mark: usize) void {
        self.path.shrinkRetainingCapacity(mark);
    }
};

fn MutableSlice(comptime info: std.builtin.Type.Pointer) type {
    var attrs = info.attrs;
    attrs.@"const" = false;
    return @Pointer(.slice, attrs, info.child, info.sentinel());
}

fn SliceType(comptime info: std.builtin.Type.Pointer) type {
    return @Pointer(.slice, info.attrs, info.child, info.sentinel());
}

fn runtimeType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"opaque", .@"fn", .type, .comptime_int, .comptime_float, .enum_literal, .noreturn => false,
        else => true,
    };
}

fn listLike(comptime T: type) bool {
    if (!@hasField(T, "items") or !@hasField(T, "capacity"))
        return false;

    const Items = @FieldType(T, "items");
    if (@typeInfo(Items) != .pointer or @typeInfo(Items).pointer.size != .slice)
        return false;

    return @FieldType(T, "capacity") == usize;
}

/// `std.HashMapUnmanaged` and `std.ArrayHashMapUnmanaged` whose context
/// needs no state. Managed maps contain one of these.
fn mapLike(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct")
        return false;

    if (!@hasDecl(T, "KV") or !@hasDecl(T, "putContext") or !@hasDecl(T, "iterator"))
        return false;

    if (!@hasField(T, "metadata") and !@hasField(T, "index_header"))
        return false;

    return @sizeOf(@typeInfo(@TypeOf(T.putContext)).@"fn".param_types[4].?) == 0;
}

fn MapKey(comptime T: type) type {
    return @FieldType(T.KV, "key");
}

fn MapValue(comptime T: type) type {
    return @FieldType(T.KV, "value");
}

fn fieldIndex(comptime T: type, comptime name: []const u8) usize {
    for (@typeInfo(T).@"struct".field_names, 0..) |field_name, index| {
        if (std.mem.eql(u8, field_name, name))
            return index;
    }
    unreachable;
}

fn sameAllocator(left: std.mem.Allocator, right: std.mem.Allocator) bool {
    return left.ptr == right.ptr and left.vtable == right.vtable;
}

const testing = std.testing;

fn transfer(comptime old: anytype, comptime new: anytype, allocator: std.mem.Allocator) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try snapshot(old, allocator, &bytes);

    var report: std.ArrayList(u8) = .empty;
    try restore(new, bytes.items, allocator, &report);

    return report.items;
}

test "variables survive by name and keep new defaults where they no longer fit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Old = struct {
        const Mode = enum { light, dark, system };
        const Form = struct {
            email: std.ArrayList(u8) = .empty,
            volume: f32 = 0.7,
            role: u32 = 0,
            removed: bool = false,
        };
        var counter: isize = 0;
        var label: []const u8 = "none";
        var mode: Mode = .light;
        var form: Form = .{};
        var cached: ?std.mem.Allocator = null;
        var items: [3]i32 = .{ 0, 0, 0 };
        var gone: u8 = 1;
        var renamed_default: u32 = 1;
        var offset: @Vector(2, f32) = .{ 0, 0 };
    };
    const New = struct {
        const Mode = enum { system, dark, light, high_contrast };
        const Form = struct {
            added: u8 = 9,
            email: std.ArrayList(u8) = .empty,
            volume: u32 = 5,
            role: u64 = 0,
        };
        var counter: isize = 0;
        var label: []const u8 = "none";
        var mode: Mode = .system;
        var form: Form = .{};
        var cached: ?std.mem.Allocator = null;
        var items: [2]i32 = .{ 0, 0 };
        var fresh: u8 = 3;
        var renamed_default: u32 = 2;
        var offset: [2]f32 = .{ 0, 0 };
    };

    Old.counter = 42;
    Old.label = "clicked";
    Old.mode = .dark;
    try Old.form.email.appendSlice(allocator, "a@b.c");
    Old.form.volume = 0.25;
    Old.form.role = 7;
    Old.cached = allocator;
    Old.items = .{ 1, 2, 3 };
    Old.renamed_default = 100;
    Old.offset = .{ 3, 4 };

    const old = .{
        .{ .name = "counter", .pointer = &Old.counter, .initial = 1 },
        .{ .name = "label", .pointer = &Old.label, .initial = 2 },
        .{ .name = "mode", .pointer = &Old.mode, .initial = 3 },
        .{ .name = "form", .pointer = &Old.form, .initial = 4 },
        .{ .name = "cached", .pointer = &Old.cached, .initial = 5 },
        .{ .name = "items", .pointer = &Old.items, .initial = 6 },
        .{ .name = "gone", .pointer = &Old.gone, .initial = 7 },
        .{ .name = "renamed_default", .pointer = &Old.renamed_default, .initial = 8 },
        .{ .name = "offset", .pointer = &Old.offset, .initial = 9 },
    };
    const new = .{
        .{ .name = "counter", .pointer = &New.counter, .initial = 1 },
        .{ .name = "label", .pointer = &New.label, .initial = 2 },
        .{ .name = "mode", .pointer = &New.mode, .initial = 3 },
        .{ .name = "form", .pointer = &New.form, .initial = 4 },
        .{ .name = "cached", .pointer = &New.cached, .initial = 5 },
        .{ .name = "items", .pointer = &New.items, .initial = 6 },
        .{ .name = "fresh", .pointer = &New.fresh, .initial = 7 },
        .{ .name = "renamed_default", .pointer = &New.renamed_default, .initial = 99 },
        .{ .name = "offset", .pointer = &New.offset, .initial = 9 },
    };
    const report = try transfer(old, new, allocator);

    try testing.expectEqual(@as(isize, 42), New.counter);
    try testing.expectEqualStrings("clicked", New.label);
    try testing.expect(New.label.ptr != Old.label.ptr);
    try testing.expectEqual(New.Mode.dark, New.mode);
    try testing.expectEqualStrings("a@b.c", New.form.email.items);
    try testing.expectEqual(New.form.email.items.len, New.form.email.capacity);
    try New.form.email.append(allocator, '!');
    try testing.expectEqual(@as(u32, 5), New.form.volume);
    try testing.expectEqual(@as(u64, 7), New.form.role);
    try testing.expectEqual(@as(u8, 9), New.form.added);
    try testing.expect(New.cached != null);
    try testing.expect(sameAllocator(New.cached.?, allocator));
    try testing.expectEqual([2]i32{ 1, 2 }, New.items);
    try testing.expectEqual(@as(u8, 3), New.fresh);
    try testing.expectEqual(@as(u32, 2), New.renamed_default);
    try testing.expectEqual([2]f32{ 3, 4 }, New.offset);
    try testing.expectEqualStrings(
        "restored=5 reset=[form.volume (type changed),items (length changed),renamed_default (default changed)]",
        report,
    );
}

test "slices are all-or-nothing and nested lists survive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Old = struct {
        const Item = struct { id: u32, label: []const u8 };
        var paths: std.ArrayList([]const u8) = .empty;
        var items: []Item = &.{};
        var choice: union(enum) { none, picked: u32 } = .none;
    };
    const New = struct {
        const Item = struct { id: u64, label: []const u8, done: bool = false };
        var paths: std.ArrayList([]const u8) = .empty;
        var items: []Item = &.{};
        var choice: union(enum) { none, picked: u32 } = .none;
    };
    try Old.paths.append(allocator, "/tmp/a");
    try Old.paths.append(allocator, "/tmp/b");
    Old.items = try allocator.dupe(Old.Item, &.{ .{ .id = 1, .label = "one" }, .{ .id = 2, .label = "two" } });
    Old.choice = .{ .picked = 4 };

    const old = .{
        .{ .name = "paths", .pointer = &Old.paths, .initial = 0 },
        .{ .name = "items", .pointer = &Old.items, .initial = 0 },
        .{ .name = "choice", .pointer = &Old.choice, .initial = 0 },
    };
    const new = .{
        .{ .name = "paths", .pointer = &New.paths, .initial = 0 },
        .{ .name = "items", .pointer = &New.items, .initial = 0 },
        .{ .name = "choice", .pointer = &New.choice, .initial = 0 },
    };
    const report = try transfer(old, new, allocator);

    try testing.expectEqual(@as(usize, 2), New.paths.items.len);
    try testing.expectEqualStrings("/tmp/b", New.paths.items[1]);
    try testing.expectEqual(@as(usize, 2), New.items.len);
    try testing.expectEqual(@as(u64, 2), New.items[1].id);
    try testing.expectEqualStrings("two", New.items[1].label);
    try testing.expect(!New.items[1].done);
    try testing.expectEqual(@as(u32, 4), New.choice.picked);
    try testing.expectEqualStrings("restored=3 reset=[]", report);
}

test "maps move as entries and structs with pointers keep their defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Old = struct {
        const Cache = struct { first: ?[*]u8 = null, len: usize = 0 };
        var scores: std.StringHashMapUnmanaged(u32) = .empty;
        var ordered: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .empty;
        var cache: Cache = .{};
        var target: ?*u32 = null;
    };
    const New = struct {
        const Cache = struct { first: ?[*]u8 = null, len: usize = 0 };
        var scores: std.StringHashMapUnmanaged(u64) = .empty;
        var ordered: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .empty;
        var cache: Cache = .{};
        var target: ?*u32 = null;
    };
    try Old.scores.put(allocator, "ada", 3);
    try Old.scores.put(allocator, "bob", 5);
    try Old.ordered.put(allocator, 7, "seven");
    var bytes = [_]u8{ 1, 2 };
    Old.cache = .{ .first = &bytes, .len = 2 };
    var number: u32 = 1;
    Old.target = &number;

    const old = .{
        .{ .name = "scores", .pointer = &Old.scores, .initial = 0 },
        .{ .name = "ordered", .pointer = &Old.ordered, .initial = 0 },
        .{ .name = "cache", .pointer = &Old.cache, .initial = 0 },
        .{ .name = "target", .pointer = &Old.target, .initial = 0 },
    };
    const new = .{
        .{ .name = "scores", .pointer = &New.scores, .initial = 0 },
        .{ .name = "ordered", .pointer = &New.ordered, .initial = 0 },
        .{ .name = "cache", .pointer = &New.cache, .initial = 0 },
        .{ .name = "target", .pointer = &New.target, .initial = 0 },
    };
    const report = try transfer(old, new, allocator);

    try testing.expectEqual(@as(u64, 5), New.scores.get("bob").?);
    try testing.expectEqual(@as(u32, 2), New.scores.count());
    try New.scores.put(allocator, "cy", 1);
    try testing.expectEqualStrings("seven", New.ordered.get(7).?);
    try testing.expectEqual(@as(usize, 0), New.cache.len);
    try testing.expect(New.target == null);
    try testing.expectEqualStrings(
        "restored=2 reset=[cache (holds a pointer),target (not captured)]",
        report,
    );
}

test "corrupt snapshots are rejected" {
    const Vars = struct {
        var counter: u32 = 0;
    };
    const vars = .{.{ .name = "counter", .pointer = &Vars.counter, .initial = 0 }};

    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(testing.allocator);

    try testing.expectError(error.InvalidSnapshot, restore(vars, "nope", testing.allocator, &report));
    try testing.expectError(error.InvalidSnapshot, restore(vars, "\x01\x00\x00\x00", testing.allocator, &report));
}
