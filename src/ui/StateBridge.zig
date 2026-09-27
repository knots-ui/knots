const std = @import("std");
const signal = @import("signal");
const host_graph_enabled = @import("state_bridge_config").host_graph_enabled;
const Graph = if (host_graph_enabled) signal.Graph else struct {};

pub const entries_max: u32 = 1024;
pub const dependencies_max: u32 = entries_max;
pub const subscribers_max: u32 = 128;
pub const edges_max: u32 = 4096;
pub const value_bytes_max: u32 = 4096;

comptime {
    std.debug.assert(entries_max > 0);
    std.debug.assert(dependencies_max >= entries_max);
    std.debug.assert(subscribers_max > 0);
    std.debug.assert(edges_max > 0);
    std.debug.assert(value_bytes_max >= 256);
    std.debug.assert(value_bytes_max <= 64 * 1024);
}

pub const Value = struct {
    domain: u64 = 0,
    key: u64,
    schema: u64,
    bytes: []const u8,
};

pub const Dependency = struct {
    domain: u64,
    key: u64,
};

const Entry = struct {
    domain: u64,
    key: u64,
    schema: u64,
    bytes: []u8,
    signal: signal.Id,
};

const SignalEntry = struct {
    domain: u64,
    key: u64,
    signal: signal.Id,
};

const EntryKey = struct {
    domain: u64,
    key: u64,
};

const SubscriberEntry = struct {
    identity: u64,
    subscriber: signal.Subscriber,
};

allocator: std.mem.Allocator,
graph: Graph,
entries: std.ArrayList(Entry) = .empty,
entry_indices: std.AutoHashMapUnmanaged(EntryKey, u32) = .empty,
signals: std.ArrayList(SignalEntry) = .empty,
signal_indices: std.AutoHashMapUnmanaged(EntryKey, u32) = .empty,
mutation: u64 = 0,
subscribers: std.ArrayList(SubscriberEntry) = .empty,
dependencies: std.ArrayList(Dependency) = .empty,
scope: u64 = 0,
revision: u64 = 0,
collecting_dependencies: bool = false,
active_tracking: ?signal.Tracking = null,

const StateBridge = @This();

pub fn init(allocator: std.mem.Allocator) !StateBridge {
    const graph: Graph = if (comptime host_graph_enabled) try signal.Graph.init(allocator, .{
        .signals_max = entries_max,
        .subscribers_max = subscribers_max,
        .edges_max = edges_max,
    }) else .{};
    return .{ .allocator = allocator, .graph = graph };
}

pub fn deinit(self: *StateBridge) void {
    std.debug.assert(self.active_tracking == null);
    std.debug.assert(!self.collecting_dependencies);
    self.clear();
    if (comptime host_graph_enabled) {
        for (self.subscribers.items) |entry| self.graph.destroySubscriber(entry.subscriber) catch @panic("subscriber cleanup failed");
    }
    self.subscribers.deinit(self.allocator);
    self.signals.deinit(self.allocator);
    self.signal_indices.deinit(self.allocator);
    self.dependencies.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.entry_indices.deinit(self.allocator);
    if (comptime host_graph_enabled) self.graph.deinit();
    self.* = undefined;
}

pub fn clear(self: *StateBridge) void {
    std.debug.assert(self.active_tracking == null);
    std.debug.assert(!self.collecting_dependencies);
    for (self.entries.items) |entry| self.allocator.free(entry.bytes);
    self.entries.clearRetainingCapacity();
    self.entry_indices.clearRetainingCapacity();
    if (comptime host_graph_enabled) {
        for (self.signals.items) |entry| self.graph.destroySignal(entry.signal) catch @panic("signal cleanup failed");
    }
    self.signals.clearRetainingCapacity();
    self.signal_indices.clearRetainingCapacity();
    self.mutation +%= 1;
    self.dependencies.clearRetainingCapacity();
    if (comptime host_graph_enabled) self.graph.markAllDirty();
}

/// Non-zero domains are local to one module execution scope. Domain zero is
/// deliberately global for named application state such as theme bindings.
pub fn setScope(self: *StateBridge, scope: u64) void {
    std.debug.assert(self.entries.items.len <= entries_max);
    self.scope = scope;
}

pub fn load(self: *StateBridge, snapshot: []const Value) !void {
    if (snapshot.len > entries_max) return error.TooManyStateValues;

    var replacement: std.ArrayList(Entry) = .empty;
    errdefer {
        for (replacement.items) |entry| self.allocator.free(entry.bytes);
        replacement.deinit(self.allocator);
    }
    try replacement.ensureTotalCapacity(self.allocator, snapshot.len);
    var replacement_indices: std.AutoHashMapUnmanaged(EntryKey, u32) = .empty;
    errdefer replacement_indices.deinit(self.allocator);
    try replacement_indices.ensureTotalCapacity(self.allocator, @intCast(snapshot.len));

    for (snapshot, 0..) |value, index| {
        try validateValue(value);
        const slot = replacement_indices.getOrPutAssumeCapacity(.{ .domain = value.domain, .key = value.key });
        if (slot.found_existing) return error.DuplicateStateKey;
        slot.value_ptr.* = @intCast(index);
        replacement.appendAssumeCapacity(.{
            .domain = value.domain,
            .key = value.key,
            .schema = value.schema,
            .bytes = try self.allocator.dupe(u8, value.bytes),
            .signal = undefined,
        });
    }

    std.debug.assert(replacement.items.len == snapshot.len);
    std.debug.assert(replacement.items.len <= entries_max);
    for (replacement.items, snapshot) |*entry, value| {
        entry.signal = try self.ensureSignal(value.domain, value.key);
    }
    if (comptime host_graph_enabled) try self.markSnapshotChanges(snapshot);
    for (self.entries.items) |entry| self.allocator.free(entry.bytes);
    self.entries.deinit(self.allocator);
    self.entries = replacement;
    self.entry_indices.deinit(self.allocator);
    self.entry_indices = replacement_indices;
    self.mutation +%= 1;
}

pub fn values(self: *const StateBridge, allocator: std.mem.Allocator) ![]Value {
    std.debug.assert(self.entries.items.len <= entries_max);
    const result = try allocator.alloc(Value, self.entries.items.len);
    for (self.entries.items, result) |entry, *value| {
        value.* = .{
            .domain = entry.domain,
            .key = entry.key,
            .schema = entry.schema,
            .bytes = entry.bytes,
        };
    }
    return result;
}

pub fn read(self: *StateBridge, comptime T: type, key_value: u64) !?T {
    return self.readDomain(T, 0, key_value);
}

pub fn readDomain(self: *StateBridge, comptime T: type, domain: u64, key_value: u64) !?T {
    comptime validateType(T);
    if (key_value == 0) return error.InvalidStateKey;

    const scoped_domain = self.scopedDomain(domain);
    try self.trackDependency(scoped_domain, key_value);
    const entry = self.find(scoped_domain, key_value) orelse return null;
    if (entry.schema != schemaFor(T)) return error.StateSchemaMismatch;
    if (entry.bytes.len != encodedSize(T)) return error.InvalidStateValue;

    var offset: u32 = 0;
    const result = try decode(T, entry.bytes, &offset);
    if (offset != entry.bytes.len) return error.InvalidStateValue;
    return result;
}

pub fn write(self: *StateBridge, comptime T: type, key_value: u64, value: T) !void {
    return self.writeDomain(T, 0, key_value, value);
}

pub fn writeDomain(self: *StateBridge, comptime T: type, domain: u64, key_value: u64, value: T) !void {
    comptime validateType(T);
    if (key_value == 0) return error.InvalidStateKey;

    const size = comptime encodedSize(T);
    if (size > value_bytes_max) unreachable;
    var bytes: [size]u8 = undefined;
    var offset: u32 = 0;
    try encode(T, value, &bytes, &offset);
    std.debug.assert(offset == bytes.len);

    const scoped_domain = self.scopedDomain(domain);
    if (self.findMutable(scoped_domain, key_value)) |entry| {
        if (entry.schema != schemaFor(T)) return error.StateSchemaMismatch;
        if (entry.bytes.len != bytes.len) return error.StateSchemaMismatch;
        if (std.mem.eql(u8, entry.bytes, &bytes)) return;
        @memcpy(entry.bytes, &bytes);
        self.mutation +%= 1;
        try self.bumpSignal(entry.signal);
        return;
    }

    if (self.entries.items.len == entries_max) return error.TooManyStateValues;
    const state_signal = try self.ensureSignal(scoped_domain, key_value);
    const owned = try self.allocator.dupe(u8, &bytes);
    errdefer self.allocator.free(owned);
    try self.entry_indices.ensureUnusedCapacity(self.allocator, 1);
    try self.entries.ensureUnusedCapacity(self.allocator, 1);
    self.entry_indices.putAssumeCapacityNoClobber(.{ .domain = scoped_domain, .key = key_value }, @intCast(self.entries.items.len));
    self.mutation +%= 1;
    self.entries.appendAssumeCapacity(.{
        .domain = scoped_domain,
        .key = key_value,
        .schema = schemaFor(T),
        .bytes = owned,
        .signal = state_signal,
    });
    try self.bumpSignal(state_signal);
}

pub fn key(name: []const u8) u64 {
    std.debug.assert(name.len > 0);
    const result = std.hash.Wyhash.hash(0x6b6e6f74732d7374, name);
    return if (result == 0) 1 else result;
}

pub fn ensureSubscriber(self: *StateBridge, identity: u64) !signal.Subscriber {
    if (comptime !host_graph_enabled)
        return error.UnsupportedReactiveGraph;
    std.debug.assert(self.subscribers.items.len <= subscribers_max);
    if (identity == 0)
        return error.InvalidSubscriberIdentity;
    for (self.subscribers.items) |entry| {
        if (entry.identity == identity)
            return entry.subscriber;
    }
    if (self.subscribers.items.len == subscribers_max)
        return error.TooManySubscribers;

    const subscriber = try self.graph.createSubscriber();
    errdefer self.graph.destroySubscriber(subscriber) catch @panic("subscriber rollback failed");
    try self.subscribers.append(self.allocator, .{ .identity = identity, .subscriber = subscriber });
    return subscriber;
}

pub fn retainSubscribers(self: *StateBridge, identities: []const u64) !void {
    if (comptime !host_graph_enabled) {
        std.debug.assert(self.subscribers.items.len == 0);
        return;
    }
    std.debug.assert(self.active_tracking == null);
    std.debug.assert(identities.len <= subscribers_max);
    var index: u32 = 0;
    while (index < self.subscribers.items.len) {
        const entry = self.subscribers.items[@intCast(index)];
        var retained = false;
        for (identities) |identity| {
            if (identity == entry.identity) {
                retained = true;
                break;
            }
        }
        if (retained) {
            index += 1;
            continue;
        }
        try self.graph.destroySubscriber(entry.subscriber);
        _ = self.subscribers.orderedRemove(@intCast(index));
    }
}

pub fn beginTracking(self: *StateBridge, subscriber: signal.Subscriber) !signal.Tracking {
    if (comptime !host_graph_enabled) {
        return error.UnsupportedReactiveGraph;
    }
    if (self.active_tracking != null) return error.TrackingAlreadyActive;
    const tracking = try self.graph.beginTracking(subscriber);
    self.active_tracking = tracking;
    return tracking;
}

pub fn endTracking(self: *StateBridge, tracking: signal.Tracking) !void {
    if (comptime !host_graph_enabled) {
        return error.UnsupportedReactiveGraph;
    }
    const active = self.active_tracking orelse return error.TrackingNotActive;
    if (active.epoch != tracking.epoch) return error.TrackingNotActive;
    if (active.subscriber.index != tracking.subscriber.index) return error.TrackingNotActive;
    if (active.subscriber.generation != tracking.subscriber.generation) return error.TrackingNotActive;
    try self.graph.endTracking(tracking);
    self.active_tracking = null;
}

pub fn replaceDependencies(self: *StateBridge, subscriber: signal.Subscriber, dependencies: []const Dependency) !void {
    if (dependencies.len > dependencies_max) return error.TooManyDependencies;
    for (dependencies, 0..) |dependency, index| {
        if (dependency.key == 0) return error.InvalidStateKey;
        for (dependencies[0..index]) |previous| {
            if (previous.domain == dependency.domain) {
                if (previous.key == dependency.key) return error.DuplicateDependency;
            }
        }
    }

    const tracking = try self.beginTracking(subscriber);
    var tracking_active = true;
    defer if (tracking_active) self.endTracking(tracking) catch @panic("dependency tracking rollback failed");
    for (dependencies) |dependency| try self.trackDependency(dependency.domain, dependency.key);
    try self.endTracking(tracking);
    tracking_active = false;
}

pub fn clearDirty(self: *StateBridge, subscriber: signal.Subscriber) !void {
    if (comptime !host_graph_enabled) {
        return error.UnsupportedReactiveGraph;
    }
    try self.graph.clearDirty(subscriber);
}

pub fn isDirty(self: *const StateBridge, subscriber: signal.Subscriber) !bool {
    if (comptime !host_graph_enabled) {
        return error.UnsupportedReactiveGraph;
    }
    return self.graph.isDirty(subscriber);
}

pub fn beginDependencyCollection(self: *StateBridge) void {
    std.debug.assert(!self.collecting_dependencies);
    std.debug.assert(self.active_tracking == null);
    self.dependencies.clearRetainingCapacity();
    self.collecting_dependencies = true;
}

pub fn cancelDependencyCollection(self: *StateBridge) void {
    std.debug.assert(self.collecting_dependencies);
    self.collecting_dependencies = false;
    self.dependencies.clearRetainingCapacity();
}

pub fn endDependencyCollection(self: *StateBridge) []const Dependency {
    std.debug.assert(self.collecting_dependencies);
    self.collecting_dependencies = false;
    return self.dependencies.items;
}

pub fn forEachDomain(
    self: *StateBridge,
    domain: u64,
    context: anytype,
    comptime callback: fn (@TypeOf(context), *StateBridge, u64) anyerror!void,
) !void {
    std.debug.assert(self.entries.items.len <= entries_max);
    const scoped_domain = self.scopedDomain(domain);
    for (self.entries.items) |entry| {
        if (entry.domain == scoped_domain) try callback(context, self, entry.key);
    }
}

fn trackDependency(self: *StateBridge, domain: u64, key_value: u64) !void {
    std.debug.assert(key_value != 0);
    if (self.collecting_dependencies) {
        for (self.dependencies.items) |dependency| {
            if (dependency.domain == domain) {
                if (dependency.key == key_value) return;
            }
        }
        if (self.dependencies.items.len == dependencies_max) return error.TooManyDependencies;
        try self.dependencies.append(self.allocator, .{ .domain = domain, .key = key_value });
    }
    if (comptime host_graph_enabled) {
        if (self.active_tracking) |tracking| {
            const state_signal = try self.ensureSignal(domain, key_value);
            _ = try self.graph.get(tracking, state_signal);
        }
    }
}

fn ensureSignal(self: *StateBridge, domain: u64, key_value: u64) !signal.Id {
    std.debug.assert(key_value != 0);
    if (comptime !host_graph_enabled) return .{ .index = 0, .generation = 0 };
    if (self.findSignal(domain, key_value)) |state_signal| return state_signal;
    if (self.signals.items.len == entries_max) return error.TooManyStateSignals;
    try self.signal_indices.ensureUnusedCapacity(self.allocator, 1);
    try self.signals.ensureUnusedCapacity(self.allocator, 1);
    const state_signal = try self.graph.createSignal(self.revision);
    self.signal_indices.putAssumeCapacityNoClobber(.{ .domain = domain, .key = key_value }, @intCast(self.signals.items.len));
    self.signals.appendAssumeCapacity(.{ .domain = domain, .key = key_value, .signal = state_signal });
    return state_signal;
}

fn findSignal(self: *const StateBridge, domain: u64, key_value: u64) ?signal.Id {
    std.debug.assert(key_value != 0);
    const index = self.signal_indices.get(.{ .domain = domain, .key = key_value }) orelse return null;
    return self.signals.items[index].signal;
}

fn bumpSignal(self: *StateBridge, state_signal: signal.Id) !void {
    if (comptime !host_graph_enabled) {
        return;
    }
    if (self.revision == std.math.maxInt(u64)) return error.SignalRevisionExhausted;
    self.revision += 1;
    _ = try self.graph.set(state_signal, self.revision);
}

fn markSnapshotChanges(self: *StateBridge, snapshot: []const Value) !void {
    for (self.entries.items) |entry| {
        const replacement = findSnapshotValue(snapshot, entry.domain, entry.key);
        if (replacement) |value| {
            if (entry.schema == value.schema) {
                if (std.mem.eql(u8, entry.bytes, value.bytes)) continue;
            }
        }
        try self.bumpSignal(entry.signal);
    }
    for (snapshot) |value| {
        if (self.find(value.domain, value.key) == null) {
            const state_signal = self.findSignal(value.domain, value.key) orelse unreachable;
            try self.bumpSignal(state_signal);
        }
    }
}

fn findSnapshotValue(snapshot: []const Value, domain: u64, key_value: u64) ?Value {
    std.debug.assert(key_value != 0);
    for (snapshot) |value| {
        if (value.domain == domain) {
            if (value.key == key_value) return value;
        }
    }
    return null;
}

fn scopedDomain(self: *const StateBridge, domain: u64) u64 {
    if (domain == 0) return 0;
    if (self.scope == 0) return domain;
    const result = std.hash.Wyhash.hash(self.scope, std.mem.asBytes(&domain));
    return if (result == 0) 1 else result;
}

fn find(self: *const StateBridge, domain: u64, key_value: u64) ?*const Entry {
    std.debug.assert(key_value != 0);
    const index = self.entry_indices.get(.{ .domain = domain, .key = key_value }) orelse return null;
    return &self.entries.items[index];
}

fn findMutable(self: *StateBridge, domain: u64, key_value: u64) ?*Entry {
    std.debug.assert(key_value != 0);
    const index = self.entry_indices.get(.{ .domain = domain, .key = key_value }) orelse return null;
    return &self.entries.items[index];
}

fn validateValue(value: Value) !void {
    if (value.key == 0) return error.InvalidStateKey;
    if (value.schema == 0) return error.InvalidStateSchema;
    if (value.bytes.len == 0) return error.InvalidStateValue;
    if (value.bytes.len > value_bytes_max) return error.StateValueTooLarge;
}

pub fn schemaFor(comptime T: type) u64 {
    const type_hash = std.hash.Wyhash.hash(0x6b6e6f74732d6162, @typeName(T));
    const size_hash = std.hash.Wyhash.hash(type_hash, std.mem.asBytes(&@as(u32, encodedSize(T))));
    return if (size_hash == 0) 1 else size_hash;
}

fn validateType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .bool => {},
        .int => |integer| {
            if (integer.bits == 0) @compileError("state integers must have an explicit size");
            if (integer.bits % 8 != 0) @compileError("state integers must use whole bytes");
        },
        .float => |float_info| {
            if (float_info.bits == 32) {
                std.debug.assert(float_info.bits <= 64);
            } else {
                if (float_info.bits != 64) @compileError("state floats must be f32 or f64");
            }
        },
        .@"enum" => {},
        .optional => |optional| validateType(optional.child),
        .array => |array| validateType(array.child),
        .vector => |vector| validateType(vector.child),
        .@"struct" => |structure| {
            if (structure.is_tuple) @compileError("tuple state is not supported");
            inline for (structure.field_types) |Field| validateType(Field);
        },
        else => @compileError("state must contain only fixed-size scalars, enums, optionals, arrays, vectors, and structs"),
    }
}

fn encodedSize(comptime T: type) u32 {
    validateType(T);
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |integer| integer.bits / 8,
        .float => |float_info| float_info.bits / 8,
        .@"enum" => 4,
        .optional => |optional| 1 + encodedSize(optional.child),
        .array => |array| @intCast(array.len * encodedSize(array.child)),
        .vector => |vector| @intCast(vector.len * encodedSize(vector.child)),
        .@"struct" => |structure| blk: {
            var result: u32 = 0;
            inline for (structure.field_types) |Field| result += encodedSize(Field);
            break :blk result;
        },
        else => unreachable,
    };
}

fn encode(comptime T: type, value: T, bytes: []u8, offset: *u32) !void {
    std.debug.assert(offset.* <= bytes.len);
    switch (@typeInfo(T)) {
        .bool => {
            try reserve(bytes, offset, 1);
            bytes[offset.*] = @intFromBool(value);
            offset.* += 1;
        },
        .int => |integer| {
            const size = integer.bits / 8;
            try reserve(bytes, offset, size);
            std.mem.writeInt(T, bytes[offset.*..][0..size], value, .little);
            offset.* += size;
        },
        .float => |float_info| {
            if (!std.math.isFinite(value)) return error.InvalidStateValue;
            const Integer = @Int(.unsigned, float_info.bits);
            try encode(Integer, @bitCast(value), bytes, offset);
        },
        .@"enum" => try encode(u32, @intCast(@backingInt(value)), bytes, offset),
        .optional => |optional| {
            try encode(bool, value != null, bytes, offset);
            if (value) |child| {
                try encode(optional.child, child, bytes, offset);
            } else {
                const size = encodedSize(optional.child);
                try reserve(bytes, offset, size);
                @memset(bytes[offset.*..][0..size], 0);
                offset.* += size;
            }
        },
        .array => for (value) |item| try encode(@TypeOf(item), item, bytes, offset),
        .vector => |vector| {
            inline for (0..vector.len) |index| try encode(vector.child, value[index], bytes, offset);
        },
        .@"struct" => |structure| inline for (structure.field_names, structure.field_types) |name, Field| {
            try encode(Field, @field(value, name), bytes, offset);
        },
        else => unreachable,
    }
}

fn decode(comptime T: type, bytes: []const u8, offset: *u32) !T {
    std.debug.assert(offset.* <= bytes.len);
    return switch (@typeInfo(T)) {
        .bool => blk: {
            try reserve(bytes, offset, 1);
            const value = bytes[offset.*];
            offset.* += 1;
            if (value > 1) return error.InvalidStateValue;
            break :blk value == 1;
        },
        .int => |integer| blk: {
            const size = integer.bits / 8;
            try reserve(bytes, offset, size);
            const value = std.mem.readInt(T, bytes[offset.*..][0..size], .little);
            offset.* += size;
            break :blk value;
        },
        .float => |float_info| blk: {
            const Integer = @Int(.unsigned, float_info.bits);
            const value: T = @bitCast(try decode(Integer, bytes, offset));
            if (!std.math.isFinite(value)) return error.InvalidStateValue;
            break :blk value;
        },
        .@"enum" => try decodeEnum(T, bytes, offset),
        .optional => |optional| blk: {
            const present = try decode(bool, bytes, offset);
            const child = try decode(optional.child, bytes, offset);
            break :blk if (present) child else null;
        },
        .array => |array| blk: {
            var result: T = undefined;
            for (&result) |*item| item.* = try decode(array.child, bytes, offset);
            break :blk result;
        },
        .vector => |vector| blk: {
            var result: T = undefined;
            inline for (0..vector.len) |index| result[index] = try decode(vector.child, bytes, offset);
            break :blk result;
        },
        .@"struct" => |structure| blk: {
            var result: T = undefined;
            inline for (structure.field_names, structure.field_types) |name, Field| {
                @field(result, name) = try decode(Field, bytes, offset);
            }
            break :blk result;
        },
        else => unreachable,
    };
}

fn decodeEnum(comptime T: type, bytes: []const u8, offset: *u32) !T {
    const raw = try decode(u32, bytes, offset);
    inline for (@typeInfo(T).@"enum".field_values) |field_value| {
        if (field_value >= 0) {
            if (field_value <= std.math.maxInt(u32)) {
                if (raw == @as(u32, @intCast(field_value))) return @fromBackingInt(@intCast(@as(@typeInfo(T).@"enum".tag_type, @intCast(raw))));
            }
        }
    }
    return error.InvalidStateValue;
}

fn reserve(bytes: []const u8, offset: *const u32, count: u32) !void {
    if (offset.* > bytes.len) return error.InvalidStateValue;
    if (count > bytes.len - offset.*) return error.InvalidStateValue;
}

test "typed values round trip without struct padding" {
    const Example = struct {
        enabled: bool,
        count: u32,
        ratio: f32,
        values: [2]i16,
    };

    var bridge = try StateBridge.init(std.testing.allocator);
    defer bridge.deinit();
    const name = key("example");
    const expected: Example = .{ .enabled = true, .count = 42, .ratio = 0.5, .values = .{ -2, 7 } };
    try bridge.write(Example, name, expected);
    try std.testing.expectEqualDeep(expected, (try bridge.read(Example, name)).?);
    try std.testing.expectEqual(@as(usize, 13), bridge.entries.items[0].bytes.len);
    try bridge.writeDomain(u32, 1, name, 7);
    try bridge.writeDomain(u32, 2, name, 9);
    try std.testing.expectEqual(@as(u32, 7), (try bridge.readDomain(u32, 1, name)).?);
    try std.testing.expectEqual(@as(u32, 9), (try bridge.readDomain(u32, 2, name)).?);
}

test "load rejects duplicate and malformed values" {
    var bridge = try StateBridge.init(std.testing.allocator);
    defer bridge.deinit();
    try bridge.write(u32, key("retained"), 11);
    const value: Value = .{ .key = 1, .schema = 2, .bytes = &.{0} };
    try std.testing.expectError(error.DuplicateStateKey, bridge.load(&.{ value, value }));
    try std.testing.expectEqual(@as(u32, 11), (try bridge.read(u32, key("retained"))).?);
    try std.testing.expectError(error.InvalidStateKey, bridge.load(&.{.{ .key = 0, .schema = 2, .bytes = &.{0} }}));
    try std.testing.expectError(error.InvalidStateSchema, bridge.load(&.{.{ .key = 1, .schema = 0, .bytes = &.{0} }}));
}

test "non-zero domains are isolated by module scope" {
    var bridge = try StateBridge.init(std.testing.allocator);
    defer bridge.deinit();
    const domain = key("widget-state");
    const value_key = key("button");

    bridge.setScope(11);
    try bridge.writeDomain(u32, domain, value_key, 17);
    bridge.setScope(22);
    try bridge.writeDomain(u32, domain, value_key, 29);
    try std.testing.expectEqual(@as(u32, 29), (try bridge.readDomain(u32, domain, value_key)).?);
    bridge.setScope(11);
    try std.testing.expectEqual(@as(u32, 17), (try bridge.readDomain(u32, domain, value_key)).?);

    try bridge.write(u32, value_key, 41);
    bridge.setScope(22);
    try std.testing.expectEqual(@as(u32, 41), (try bridge.read(u32, value_key)).?);
}

test "state reads build subscriber dependencies and writes dirty only dependents" {
    var bridge = try StateBridge.init(std.testing.allocator);
    defer bridge.deinit();
    const left_key = key("left");
    const right_key = key("right");
    try bridge.write(u32, left_key, 1);
    try bridge.write(u32, right_key, 2);
    const left_subscriber = try bridge.ensureSubscriber(11);
    const right_subscriber = try bridge.ensureSubscriber(22);
    try bridge.clearDirty(left_subscriber);
    try bridge.clearDirty(right_subscriber);

    const left_tracking = try bridge.beginTracking(left_subscriber);
    try std.testing.expectEqual(@as(u32, 1), (try bridge.read(u32, left_key)).?);
    try bridge.endTracking(left_tracking);
    const right_tracking = try bridge.beginTracking(right_subscriber);
    try std.testing.expectEqual(@as(u32, 2), (try bridge.read(u32, right_key)).?);
    try bridge.endTracking(right_tracking);
    try bridge.clearDirty(left_subscriber);
    try bridge.clearDirty(right_subscriber);

    try bridge.write(u32, left_key, 3);
    try std.testing.expect(try bridge.isDirty(left_subscriber));
    try std.testing.expect(!(try bridge.isDirty(right_subscriber)));
}

test "missing state reads become dependencies before the value exists" {
    var bridge = try StateBridge.init(std.testing.allocator);
    defer bridge.deinit();
    const subscriber = try bridge.ensureSubscriber(1);
    const future_key = key("future");
    const dependencies = &.{Dependency{ .domain = 0, .key = future_key }};
    try bridge.replaceDependencies(subscriber, dependencies);
    try bridge.clearDirty(subscriber);

    try bridge.write(u32, future_key, 7);
    try std.testing.expect(try bridge.isDirty(subscriber));
}
