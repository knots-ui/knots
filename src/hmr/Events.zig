const std = @import("std");

const Events = @This();

condition: std.Io.Condition = .init,
mutex: std.Io.Mutex = .init,
revision: u64 = 1,

pub fn publish(events: *Events, io: std.Io) void {
    events.mutex.lockUncancelable(io);
    defer events.mutex.unlock(io);
    events.revision +%= 1;
    events.condition.broadcast(io);
}
