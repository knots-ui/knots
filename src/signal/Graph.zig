//! Bounded dependency tracking for host-owned reactive values.
const std = @import("std");
const Id = @import("root.zig").Id;
const Limits = @import("Limits.zig");
const Subscriber = @import("root.zig").Subscriber;
const Tracking = @import("Tracking.zig");
const Value = @import("root.zig").Value;

pub const Error = error{
    InvalidLimits,
    TooManySignals,
    TooManySubscribers,
    TooManyDependencies,
    InvalidSignal,
    InvalidSubscriber,
    TrackingAlreadyActive,
    TrackingNotActive,
    TrackingEpochExhausted,
};

const invalid_index: u32 = std.math.maxInt(u32);
const index_max: u32 = (1 << 24) - 1;

comptime {
    std.debug.assert(@bitSizeOf(Id) == 32);
    std.debug.assert(@bitSizeOf(Subscriber) == 32);
    std.debug.assert(@sizeOf(Value) == 8);
    std.debug.assert(index_max > 0);
}

const Slot = struct {
    value: Value = 0,
    generation: u8 = 1,
    free_next: u32 = invalid_index,
    edge_head: u32 = invalid_index,
    alive: bool = false,
    retired: bool = false,
};

const SubscriberSlot = struct {
    generation: u8 = 1,
    free_next: u32 = invalid_index,
    dependency_head: u32 = invalid_index,
    tracking_epoch: u32 = 0,
    dirty: bool = true,
    tracking_active: bool = false,
    alive: bool = false,
    retired: bool = false,
};

const Edge = struct {
    signal: Id = undefined,
    subscriber: Subscriber = undefined,
    signal_next: u32 = invalid_index,
    signal_previous: u32 = invalid_index,
    subscriber_next: u32 = invalid_index,
    subscriber_previous: u32 = invalid_index,
    last_seen: u32 = 0,
    free_next: u32 = invalid_index,
    alive: bool = false,
};

allocator: std.mem.Allocator,
limits: Limits,
signals: []Slot,
subscribers: []SubscriberSlot,
edges: []Edge,
free_signal: u32,
free_subscriber: u32,
free_edge: u32,

const Graph = @This();

pub fn init(allocator: std.mem.Allocator, limits: Limits) !Graph {
    try validateLimits(limits);

    const signals = try allocator.alloc(Slot, @intCast(limits.signals_max));
    errdefer allocator.free(signals);
    const subscribers = try allocator.alloc(SubscriberSlot, @intCast(limits.subscribers_max));
    errdefer allocator.free(subscribers);
    const edges = try allocator.alloc(Edge, @intCast(limits.edges_max));
    errdefer allocator.free(edges);

    var graph: Graph = .{
        .allocator = allocator,
        .limits = limits,
        .signals = signals,
        .subscribers = subscribers,
        .edges = edges,
        .free_signal = 0,
        .free_subscriber = 0,
        .free_edge = 0,
    };
    graph.initializeFreeLists();
    std.debug.assert(graph.signals.len == @as(usize, @intCast(limits.signals_max)));
    std.debug.assert(graph.subscribers.len == @as(usize, @intCast(limits.subscribers_max)));
    std.debug.assert(graph.edges.len == @as(usize, @intCast(limits.edges_max)));
    return graph;
}

pub fn deinit(self: *Graph) void {
    std.debug.assert(self.signals.len > 0);
    std.debug.assert(self.subscribers.len > 0);
    std.debug.assert(self.edges.len > 0);
    var subscriber_index: u32 = 0;
    while (subscriber_index < self.limits.subscribers_max) : (subscriber_index += 1) {
        const subscriber = &self.subscribers[@intCast(subscriber_index)];
        std.debug.assert(!subscriber.tracking_active);
    }
    self.allocator.free(self.edges);
    self.allocator.free(self.subscribers);
    self.allocator.free(self.signals);
    self.* = undefined;
}

pub fn createSignal(self: *Graph, value: Value) Error!Id {
    std.debug.assert(self.signals.len > 0);
    std.debug.assert(self.limits.signals_max <= index_max);
    const index = self.free_signal;
    if (index == invalid_index) return error.TooManySignals;

    const slot = &self.signals[@intCast(index)];
    std.debug.assert(!slot.alive);
    std.debug.assert(!slot.retired);
    const generation = slot.generation;
    self.free_signal = slot.free_next;
    slot.* = .{
        .value = value,
        .generation = generation,
        .free_next = invalid_index,
        .edge_head = invalid_index,
        .alive = true,
        .retired = false,
    };
    const result: Id = .{ .index = @intCast(index), .generation = generation };
    std.debug.assert(try self.read(result) == value);
    return result;
}

pub fn destroySignal(self: *Graph, signal: Id) Error!void {
    const index = try self.signalIndex(signal);
    var removed_edges: u32 = 0;
    while (self.signals[@intCast(index)].edge_head != invalid_index) {
        if (removed_edges == self.limits.edges_max) @panic("signal edge list exceeded its bound");
        self.removeEdge(self.signals[@intCast(index)].edge_head);
        removed_edges += 1;
    }
    self.releaseSignal(index);
    std.debug.assert(!self.signals[@intCast(index)].alive);
}

pub fn read(self: *const Graph, signal: Id) Error!Value {
    const index = try self.signalIndex(signal);
    const slot = &self.signals[@intCast(index)];
    std.debug.assert(slot.alive);
    std.debug.assert(slot.generation == signal.generation);
    return slot.value;
}

pub fn set(self: *Graph, signal: Id, value: Value) Error!bool {
    const index = try self.signalIndex(signal);
    const slot = &self.signals[@intCast(index)];
    std.debug.assert(slot.alive);
    if (slot.value == value) return false;
    slot.value = value;
    self.markSubscribersDirty(index);
    std.debug.assert(try self.read(signal) == value);
    return true;
}

pub fn createSubscriber(self: *Graph) Error!Subscriber {
    std.debug.assert(self.subscribers.len > 0);
    std.debug.assert(self.limits.subscribers_max <= index_max);
    const index = self.free_subscriber;
    if (index == invalid_index) return error.TooManySubscribers;

    const slot = &self.subscribers[@intCast(index)];
    std.debug.assert(!slot.alive);
    std.debug.assert(!slot.retired);
    const generation = slot.generation;
    self.free_subscriber = slot.free_next;
    slot.* = .{
        .generation = generation,
        .free_next = invalid_index,
        .dependency_head = invalid_index,
        .tracking_epoch = 0,
        .dirty = true,
        .tracking_active = false,
        .alive = true,
        .retired = false,
    };
    const result: Subscriber = .{ .index = @intCast(index), .generation = generation };
    std.debug.assert(try self.isDirty(result));
    return result;
}

pub fn destroySubscriber(self: *Graph, subscriber: Subscriber) Error!void {
    const index = try self.subscriberIndex(subscriber);
    const slot = &self.subscribers[@intCast(index)];
    std.debug.assert(slot.alive);
    if (slot.tracking_active) return error.TrackingAlreadyActive;

    var removed_edges: u32 = 0;
    while (self.subscribers[@intCast(index)].dependency_head != invalid_index) {
        if (removed_edges == self.limits.edges_max) @panic("subscriber edge list exceeded its bound");
        self.removeEdge(self.subscribers[@intCast(index)].dependency_head);
        removed_edges += 1;
    }
    self.releaseSubscriber(index);
    std.debug.assert(!self.subscribers[@intCast(index)].alive);
}

pub fn beginTracking(self: *Graph, subscriber: Subscriber) Error!Tracking {
    const index = try self.subscriberIndex(subscriber);
    const slot = &self.subscribers[@intCast(index)];
    std.debug.assert(slot.alive);
    if (slot.tracking_active) return error.TrackingAlreadyActive;
    if (slot.tracking_epoch == std.math.maxInt(u32)) return error.TrackingEpochExhausted;
    slot.tracking_epoch += 1;
    slot.tracking_active = true;
    const result: Tracking = .{ .subscriber = subscriber, .epoch = slot.tracking_epoch };
    std.debug.assert(result.epoch > 0);
    std.debug.assert(self.subscribers[@intCast(index)].tracking_active);
    return result;
}

pub fn get(self: *Graph, tracking: Tracking, signal: Id) Error!Value {
    const subscriber_index = try self.trackingIndex(tracking);
    const signal_index = try self.signalIndex(signal);
    const subscriber = &self.subscribers[@intCast(subscriber_index)];
    std.debug.assert(subscriber.tracking_active);
    std.debug.assert(subscriber.tracking_epoch == tracking.epoch);

    if (self.findEdge(subscriber_index, signal)) |edge_index| {
        self.edges[@intCast(edge_index)].last_seen = tracking.epoch;
    } else {
        try self.addEdge(signal_index, subscriber_index, signal, tracking);
    }
    const value = self.signals[@intCast(signal_index)].value;
    std.debug.assert(self.signals[@intCast(signal_index)].alive);
    std.debug.assert(self.edgesForSubscriberContains(subscriber_index, signal));
    return value;
}

pub fn endTracking(self: *Graph, tracking: Tracking) Error!void {
    const subscriber_index = try self.trackingIndex(tracking);
    const subscriber = &self.subscribers[@intCast(subscriber_index)];
    std.debug.assert(subscriber.tracking_active);
    std.debug.assert(subscriber.tracking_epoch == tracking.epoch);

    var edge_index = subscriber.dependency_head;
    var visited_edges: u32 = 0;
    while (edge_index != invalid_index) {
        if (visited_edges == self.limits.edges_max) @panic("subscriber edge list exceeded its bound");
        const next = self.edges[@intCast(edge_index)].subscriber_next;
        if (self.edges[@intCast(edge_index)].last_seen != tracking.epoch) self.removeEdge(edge_index);
        edge_index = next;
        visited_edges += 1;
    }
    subscriber.tracking_active = false;
    std.debug.assert(!subscriber.tracking_active);
    const current_index = self.subscriberIndex(tracking.subscriber) catch @panic("tracking subscriber disappeared");
    std.debug.assert(current_index == tracking.subscriber.index);
}

pub fn clearDirty(self: *Graph, subscriber: Subscriber) Error!void {
    const index = try self.subscriberIndex(subscriber);
    const slot = &self.subscribers[@intCast(index)];
    std.debug.assert(slot.alive);
    slot.dirty = false;
    std.debug.assert(!(try self.isDirty(subscriber)));
}

pub fn isDirty(self: *const Graph, subscriber: Subscriber) Error!bool {
    const index = try self.subscriberIndex(subscriber);
    const slot = &self.subscribers[@intCast(index)];
    std.debug.assert(slot.alive);
    return slot.dirty;
}

/// Return one dirty subscriber without clearing it. The caller clears it only
/// after the corresponding work succeeds, so failed work remains retryable.
pub fn takeDirty(self: *const Graph) ?Subscriber {
    std.debug.assert(self.subscribers.len > 0);
    var index: u32 = 0;
    while (index < self.limits.subscribers_max) : (index += 1) {
        const slot = &self.subscribers[@intCast(index)];
        if (!slot.alive) continue;
        if (!slot.dirty) continue;
        const result: Subscriber = .{ .index = @intCast(index), .generation = slot.generation };
        std.debug.assert(self.subscriberIndex(result) == index);
        return result;
    }
    return null;
}

pub fn markAllDirty(self: *Graph) void {
    std.debug.assert(self.subscribers.len > 0);
    var index: u32 = 0;
    while (index < self.limits.subscribers_max) : (index += 1) {
        const slot = &self.subscribers[@intCast(index)];
        if (!slot.alive) continue;
        slot.dirty = true;
    }
}

pub fn edgeCount(self: *const Graph) u32 {
    std.debug.assert(self.edges.len > 0);
    var count: u32 = 0;
    var index: u32 = 0;
    while (index < self.limits.edges_max) : (index += 1) {
        if (self.edges[@intCast(index)].alive) count += 1;
    }
    std.debug.assert(count <= self.limits.edges_max);
    return count;
}

fn validateLimits(limits: Limits) Error!void {
    std.debug.assert(index_max > 0);
    std.debug.assert(std.math.maxInt(u8) > 0);
    if (limits.signals_max == 0) return error.InvalidLimits;
    if (limits.subscribers_max == 0) return error.InvalidLimits;
    if (limits.edges_max == 0) return error.InvalidLimits;
    if (limits.signals_max > index_max) return error.InvalidLimits;
    if (limits.subscribers_max > index_max) return error.InvalidLimits;
    std.debug.assert(limits.signals_max > 0);
    std.debug.assert(limits.subscribers_max > 0);
}

fn initializeFreeLists(self: *Graph) void {
    std.debug.assert(self.signals.len > 0);
    std.debug.assert(self.subscribers.len > 0);
    std.debug.assert(self.edges.len > 0);

    var signal_index: u32 = 0;
    while (signal_index < self.limits.signals_max) : (signal_index += 1) {
        const slot = &self.signals[@intCast(signal_index)];
        slot.* = .{ .free_next = nextIndex(signal_index, self.limits.signals_max) };
    }

    var subscriber_index: u32 = 0;
    while (subscriber_index < self.limits.subscribers_max) : (subscriber_index += 1) {
        const slot = &self.subscribers[@intCast(subscriber_index)];
        slot.* = .{ .free_next = nextIndex(subscriber_index, self.limits.subscribers_max) };
    }

    var edge_index: u32 = 0;
    while (edge_index < self.limits.edges_max) : (edge_index += 1) {
        self.edges[@intCast(edge_index)] = .{ .free_next = nextIndex(edge_index, self.limits.edges_max) };
    }
    std.debug.assert(self.free_signal == 0);
    std.debug.assert(self.free_subscriber == 0);
    std.debug.assert(self.free_edge == 0);
}

fn nextIndex(index: u32, count: u32) u32 {
    std.debug.assert(count > 0);
    std.debug.assert(index < count);
    if (index + 1 < count) return index + 1;
    return invalid_index;
}

fn signalIndex(self: *const Graph, signal: Id) Error!u32 {
    std.debug.assert(self.signals.len > 0);
    std.debug.assert(self.limits.signals_max <= index_max);
    if (signal.index >= self.limits.signals_max) return error.InvalidSignal;
    const slot = &self.signals[@intCast(signal.index)];
    if (!slot.alive) return error.InvalidSignal;
    if (slot.generation != signal.generation) return error.InvalidSignal;
    return signal.index;
}

fn subscriberIndex(self: *const Graph, subscriber: Subscriber) Error!u32 {
    std.debug.assert(self.subscribers.len > 0);
    std.debug.assert(self.limits.subscribers_max <= index_max);
    if (subscriber.index >= self.limits.subscribers_max) return error.InvalidSubscriber;
    const slot = &self.subscribers[@intCast(subscriber.index)];
    if (!slot.alive) return error.InvalidSubscriber;
    if (slot.generation != subscriber.generation) return error.InvalidSubscriber;
    return subscriber.index;
}

fn trackingIndex(self: *const Graph, tracking: Tracking) Error!u32 {
    const index = try self.subscriberIndex(tracking.subscriber);
    const slot = &self.subscribers[@intCast(index)];
    std.debug.assert(slot.alive);
    if (!slot.tracking_active) return error.TrackingNotActive;
    if (slot.tracking_epoch != tracking.epoch) return error.TrackingNotActive;
    return index;
}

fn findEdge(self: *const Graph, subscriber_index: u32, signal: Id) ?u32 {
    std.debug.assert(subscriber_index < self.limits.subscribers_max);
    std.debug.assert(signal.index < self.limits.signals_max);
    var edge_index = self.subscribers[@intCast(subscriber_index)].dependency_head;
    var visited_edges: u32 = 0;
    while (edge_index != invalid_index) {
        if (visited_edges == self.limits.edges_max) @panic("subscriber edge list exceeded its bound");
        const edge = &self.edges[@intCast(edge_index)];
        std.debug.assert(edge.alive);
        if (edge.signal.index == signal.index) {
            if (edge.signal.generation == signal.generation) return edge_index;
        }
        edge_index = edge.subscriber_next;
        visited_edges += 1;
    }
    return null;
}

fn addEdge(self: *Graph, signal_index: u32, subscriber_index: u32, signal: Id, tracking: Tracking) Error!void {
    std.debug.assert(signal_index < self.limits.signals_max);
    std.debug.assert(subscriber_index < self.limits.subscribers_max);
    std.debug.assert(tracking.epoch > 0);
    const edge_index = self.free_edge;
    if (edge_index == invalid_index) return error.TooManyDependencies;

    const signal_slot = &self.signals[@intCast(signal_index)];
    const subscriber_slot = &self.subscribers[@intCast(subscriber_index)];
    const edge = &self.edges[@intCast(edge_index)];
    std.debug.assert(signal_slot.alive);
    std.debug.assert(subscriber_slot.alive);
    std.debug.assert(!edge.alive);
    self.free_edge = edge.free_next;
    edge.* = .{
        .signal = signal,
        .subscriber = tracking.subscriber,
        .signal_next = signal_slot.edge_head,
        .signal_previous = invalid_index,
        .subscriber_next = subscriber_slot.dependency_head,
        .subscriber_previous = invalid_index,
        .last_seen = tracking.epoch,
        .free_next = invalid_index,
        .alive = true,
    };
    if (signal_slot.edge_head != invalid_index) self.edges[@intCast(signal_slot.edge_head)].signal_previous = edge_index;
    if (subscriber_slot.dependency_head != invalid_index) self.edges[@intCast(subscriber_slot.dependency_head)].subscriber_previous = edge_index;
    signal_slot.edge_head = edge_index;
    subscriber_slot.dependency_head = edge_index;
    std.debug.assert(self.edges[@intCast(edge_index)].alive);
    std.debug.assert(self.edgesForSubscriberContains(subscriber_index, signal));
}

fn removeEdge(self: *Graph, edge_index: u32) void {
    std.debug.assert(edge_index < self.limits.edges_max);
    const edge = &self.edges[@intCast(edge_index)];
    std.debug.assert(edge.alive);
    const signal_index = edge.signal.index;
    const subscriber_index = edge.subscriber.index;
    std.debug.assert(signal_index < self.limits.signals_max);
    std.debug.assert(subscriber_index < self.limits.subscribers_max);
    std.debug.assert(self.signals[@intCast(signal_index)].alive);
    std.debug.assert(self.subscribers[@intCast(subscriber_index)].alive);

    if (edge.signal_previous == invalid_index) {
        self.signals[@intCast(signal_index)].edge_head = edge.signal_next;
    } else {
        self.edges[@intCast(edge.signal_previous)].signal_next = edge.signal_next;
    }
    if (edge.signal_next != invalid_index) self.edges[@intCast(edge.signal_next)].signal_previous = edge.signal_previous;
    if (edge.subscriber_previous == invalid_index) {
        self.subscribers[@intCast(subscriber_index)].dependency_head = edge.subscriber_next;
    } else {
        self.edges[@intCast(edge.subscriber_previous)].subscriber_next = edge.subscriber_next;
    }
    if (edge.subscriber_next != invalid_index) self.edges[@intCast(edge.subscriber_next)].subscriber_previous = edge.subscriber_previous;
    edge.* = .{ .free_next = self.free_edge };
    self.free_edge = edge_index;
    std.debug.assert(!self.edges[@intCast(edge_index)].alive);
}

fn markSubscribersDirty(self: *Graph, signal_index: u32) void {
    std.debug.assert(signal_index < self.limits.signals_max);
    std.debug.assert(self.signals[@intCast(signal_index)].alive);
    var edge_index = self.signals[@intCast(signal_index)].edge_head;
    var visited_edges: u32 = 0;
    while (edge_index != invalid_index) {
        if (visited_edges == self.limits.edges_max) @panic("signal edge list exceeded its bound");
        const edge = &self.edges[@intCast(edge_index)];
        std.debug.assert(edge.alive);
        const subscriber_index = edge.subscriber.index;
        std.debug.assert(subscriber_index < self.limits.subscribers_max);
        const subscriber = &self.subscribers[@intCast(subscriber_index)];
        std.debug.assert(subscriber.alive);
        std.debug.assert(subscriber.generation == edge.subscriber.generation);
        subscriber.dirty = true;
        edge_index = edge.signal_next;
        visited_edges += 1;
    }
}

fn releaseSignal(self: *Graph, index: u32) void {
    std.debug.assert(index < self.limits.signals_max);
    const slot = &self.signals[@intCast(index)];
    std.debug.assert(slot.alive);
    slot.alive = false;
    slot.value = 0;
    slot.edge_head = invalid_index;
    if (slot.generation == std.math.maxInt(u8)) {
        slot.retired = true;
        slot.free_next = invalid_index;
    } else {
        slot.generation += 1;
        slot.free_next = self.free_signal;
        self.free_signal = index;
    }
    std.debug.assert(!slot.alive);
}

fn releaseSubscriber(self: *Graph, index: u32) void {
    std.debug.assert(index < self.limits.subscribers_max);
    const slot = &self.subscribers[@intCast(index)];
    std.debug.assert(slot.alive);
    slot.alive = false;
    slot.dirty = false;
    slot.dependency_head = invalid_index;
    slot.tracking_active = false;
    if (slot.generation == std.math.maxInt(u8)) {
        slot.retired = true;
        slot.free_next = invalid_index;
    } else {
        slot.generation += 1;
        slot.free_next = self.free_subscriber;
        self.free_subscriber = index;
    }
    std.debug.assert(!slot.alive);
}

fn edgesForSubscriberContains(self: *const Graph, subscriber_index: u32, signal: Id) bool {
    std.debug.assert(subscriber_index < self.limits.subscribers_max);
    std.debug.assert(signal.index < self.limits.signals_max);
    var edge_index = self.subscribers[@intCast(subscriber_index)].dependency_head;
    var visited_edges: u32 = 0;
    while (edge_index != invalid_index) {
        if (visited_edges == self.limits.edges_max) @panic("subscriber edge list exceeded its bound");
        const edge = &self.edges[@intCast(edge_index)];
        std.debug.assert(edge.alive);
        if (edge.signal.index == signal.index) {
            if (edge.signal.generation == signal.generation) return true;
        }
        edge_index = edge.subscriber_next;
        visited_edges += 1;
    }
    return false;
}

test "signals mark only subscribers of the changed value" {
    var graph = try Graph.init(std.testing.allocator, .{ .signals_max = 4, .subscribers_max = 4, .edges_max = 8 });
    defer graph.deinit();
    const left_signal = try graph.createSignal(10);
    const right_signal = try graph.createSignal(20);
    const left_subscriber = try graph.createSubscriber();
    const right_subscriber = try graph.createSubscriber();
    try graph.clearDirty(left_subscriber);
    try graph.clearDirty(right_subscriber);

    const left_tracking = try graph.beginTracking(left_subscriber);
    try std.testing.expectEqual(@as(Value, 10), try graph.get(left_tracking, left_signal));
    try graph.endTracking(left_tracking);
    const right_tracking = try graph.beginTracking(right_subscriber);
    try std.testing.expectEqual(@as(Value, 20), try graph.get(right_tracking, right_signal));
    try graph.endTracking(right_tracking);

    try std.testing.expect(try graph.set(left_signal, 11));
    try std.testing.expect(try graph.isDirty(left_subscriber));
    try std.testing.expect(!(try graph.isDirty(right_subscriber)));
    try std.testing.expect(!(try graph.set(left_signal, 11)));
}

test "dynamic dependencies remove edges not seen in the current tracking epoch" {
    var graph = try Graph.init(std.testing.allocator, .{ .signals_max = 4, .subscribers_max = 2, .edges_max = 4 });
    defer graph.deinit();
    const first_signal = try graph.createSignal(1);
    const second_signal = try graph.createSignal(2);
    const subscriber = try graph.createSubscriber();
    try graph.clearDirty(subscriber);

    const first_tracking = try graph.beginTracking(subscriber);
    _ = try graph.get(first_tracking, first_signal);
    _ = try graph.get(first_tracking, second_signal);
    try graph.endTracking(first_tracking);
    try std.testing.expectEqual(@as(u32, 2), graph.edgeCount());

    const second_tracking = try graph.beginTracking(subscriber);
    _ = try graph.get(second_tracking, second_signal);
    try graph.endTracking(second_tracking);
    try std.testing.expectEqual(@as(u32, 1), graph.edgeCount());

    try std.testing.expect(try graph.set(first_signal, 3));
    try std.testing.expect(!(try graph.isDirty(subscriber)));
    try graph.clearDirty(subscriber);
    try std.testing.expect(try graph.set(second_signal, 4));
    try std.testing.expect(try graph.isDirty(subscriber));
}

test "stale handles and active tracking are rejected" {
    var graph = try Graph.init(std.testing.allocator, .{ .signals_max = 1, .subscribers_max = 1, .edges_max = 1 });
    defer graph.deinit();
    const signal = try graph.createSignal(1);
    const subscriber = try graph.createSubscriber();
    const tracking = try graph.beginTracking(subscriber);
    try std.testing.expectError(error.TrackingAlreadyActive, graph.beginTracking(subscriber));
    try std.testing.expectError(error.TrackingAlreadyActive, graph.destroySubscriber(subscriber));
    try std.testing.expectError(error.TrackingNotActive, graph.get(.{ .subscriber = subscriber, .epoch = tracking.epoch + 1 }, signal));
    try graph.endTracking(tracking);
    try graph.destroySignal(signal);
    try std.testing.expectError(error.InvalidSignal, graph.read(signal));
    try graph.destroySubscriber(subscriber);
    try std.testing.expectError(error.InvalidSubscriber, graph.destroySubscriber(subscriber));
}

test "bounds reject more live graph objects and edges" {
    var graph = try Graph.init(std.testing.allocator, .{ .signals_max = 2, .subscribers_max = 1, .edges_max = 1 });
    defer graph.deinit();
    const first_signal = try graph.createSignal(1);
    const second_signal = try graph.createSignal(2);
    const subscriber = try graph.createSubscriber();
    try std.testing.expectError(error.TooManySignals, graph.createSignal(3));
    const tracking = try graph.beginTracking(subscriber);
    _ = try graph.get(tracking, first_signal);
    try std.testing.expectError(error.TooManyDependencies, graph.get(tracking, second_signal));
    try graph.endTracking(tracking);
}
