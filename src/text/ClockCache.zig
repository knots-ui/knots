//! Byte-budgeted cache keyed by owned bytes. Eviction runs at the end of a frame
//! with the CLOCK algorithm and never touches entries used in that frame.

const std = @import("std");

pub fn ClockCache(comptime Value: type, comptime Context: type) type {
    return struct {
        map: std.StringHashMapUnmanaged(u32) = .empty,
        entries: std.ArrayList(Entry) = .empty,
        bytes: usize = 0,
        budget: usize,
        hand: u32 = 0,

        const Self = @This();

        const Entry = struct {
            key: []const u8,
            value: Value,
            bytes: usize,
            used_frame: u32,
            referenced: bool,
        };

        pub fn init(budget: usize) Self {
            return .{ .budget = budget };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            for (self.entries.items) |entry| {
                Context.free(gpa, entry.value);
                gpa.free(entry.key);
            }
            self.entries.deinit(gpa);
            self.map.deinit(gpa);
        }

        pub fn count(self: *const Self) usize {
            return self.entries.items.len;
        }

        pub fn get(self: *Self, key: []const u8, frame: u32) ?Value {
            const index = self.map.get(key) orelse return null;
            const entry = &self.entries.items[index];
            entry.used_frame = frame;
            entry.referenced = true;
            return entry.value;
        }

        /// Takes ownership of `value`, freeing it if the insert fails.
        pub fn put(self: *Self, gpa: std.mem.Allocator, key: []const u8, value: Value, frame: u32) !Value {
            errdefer Context.free(gpa, value);
            const owned = try gpa.dupe(u8, key);
            errdefer gpa.free(owned);
            try self.entries.ensureUnusedCapacity(gpa, 1);
            try self.map.putNoClobber(gpa, owned, @intCast(self.entries.items.len));
            const bytes = Context.bytes(value) + owned.len;
            self.entries.appendAssumeCapacity(.{ .key = owned, .value = value, .bytes = bytes, .used_frame = frame, .referenced = true });
            self.bytes += bytes;
            return value;
        }

        pub fn evict(self: *Self, gpa: std.mem.Allocator, frame: u32) void {
            var steps = self.entries.items.len * 2;
            while (self.bytes > self.budget and steps > 0 and self.entries.items.len > 0) : (steps -= 1) {
                if (self.hand >= self.entries.items.len) self.hand = 0;
                const entry = &self.entries.items[self.hand];
                if (entry.used_frame == frame) {
                    self.hand += 1;
                    continue;
                }
                if (entry.referenced) {
                    entry.referenced = false;
                    self.hand += 1;
                    continue;
                }
                self.remove(gpa, self.hand);
            }
        }

        fn remove(self: *Self, gpa: std.mem.Allocator, index: u32) void {
            const entry = self.entries.items[index];
            _ = self.map.remove(entry.key);
            self.bytes -= entry.bytes;
            Context.free(gpa, entry.value);
            gpa.free(entry.key);
            _ = self.entries.swapRemove(index);
            if (index < self.entries.items.len) self.map.getPtr(self.entries.items[index].key).?.* = index;
        }
    };
}

test "keeps entries used this frame and evicts cold ones first" {
    const Bytes = struct {
        fn free(gpa: std.mem.Allocator, value: []u8) void {
            gpa.free(value);
        }
        fn bytes(value: []u8) usize {
            return value.len;
        }
    };
    const gpa = std.testing.allocator;
    var cache = ClockCache([]u8, Bytes).init(8);
    defer cache.deinit(gpa);
    _ = try cache.put(gpa, "old", try gpa.dupe(u8, "1234"), 0);
    cache.evict(gpa, 0);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    _ = try cache.put(gpa, "new", try gpa.dupe(u8, "5678"), 1);
    cache.evict(gpa, 1);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expect(cache.get("new", 2) != null);
}
