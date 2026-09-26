const std = @import("std");
const Element = @import("layout").Element;
const Layer = @import("layout").Layer;

const InputScope = @This();

pub const Config = union(enum) {
    modal,
};

const ModalEntry = struct {
    id: Element.Id,
    z_index: Layer,
    order: u32,
};

const Entry = union(enum) {
    modal: ModalEntry,

    fn id(self: Entry) Element.Id {
        return switch (self) {
            .modal => |entry| entry.id,
        };
    }
};

const Active = union(enum) {
    none,
    modal: Element.Id,
};

stack: std.ArrayList(Element.Id) = .empty,
entries: std.ArrayList(Entry) = .empty,
active: Active = .none,
next_order: u32 = 0,

pub fn deinit(self: *InputScope, allocator: std.mem.Allocator) void {
    self.stack.deinit(allocator);
    self.entries.deinit(allocator);
}

pub fn resetFrame(self: *InputScope) void {
    self.stack.clearRetainingCapacity();
    self.entries.clearRetainingCapacity();
    self.next_order = 0;
}

pub fn current(self: *const InputScope) Element.Id {
    if (self.stack.items.len == 0) return Element.INVALID_ID;
    return self.stack.items[self.stack.items.len - 1];
}

pub fn begin(self: *InputScope, allocator: std.mem.Allocator, id: Element.Id, config: Config, z_index: Layer) !void {
    try self.stack.ensureUnusedCapacity(allocator, 1);
    switch (config) {
        .modal => try self.entries.ensureUnusedCapacity(allocator, 1),
    }

    self.stack.appendAssumeCapacity(id);
    switch (config) {
        .modal => {
            self.entries.appendAssumeCapacity(.{ .modal = .{
                .id = id,
                .z_index = z_index,
                .order = self.next_order,
            } });
            self.next_order += 1;
        },
    }
}

pub fn end(self: *InputScope, id: Element.Id) void {
    std.debug.assert(self.stack.items.len > 0);
    const top = self.stack.pop().?;
    std.debug.assert(top == id);
}

pub fn cancel(self: *InputScope, id: Element.Id) void {
    var write: usize = 0;
    for (self.entries.items) |entry| {
        if (entry.id() == id) continue;
        self.entries.items[write] = entry;
        write += 1;
    }
    self.entries.shrinkRetainingCapacity(write);
}

pub fn resolveActive(self: *InputScope) void {
    self.active = .none;
    var has_best = false;
    var best_z: Layer = Layer.base;
    var best_order: u32 = 0;

    for (self.entries.items) |entry| {
        switch (entry) {
            .modal => |modal| if (!has_best or
                modal.z_index.above(best_z) or
                (modal.z_index.eql(best_z) and modal.order > best_order))
            {
                self.active = .{ .modal = modal.id };
                has_best = true;
                best_z = modal.z_index;
                best_order = modal.order;
            },
        }
    }
}

pub fn hasActive(self: *const InputScope) bool {
    return switch (self.active) {
        .none => false,
        .modal => true,
    };
}

pub fn isActive(self: *const InputScope, id: Element.Id) bool {
    return switch (self.active) {
        .none => false,
        .modal => |active_id| active_id == id,
    };
}

pub fn allows(self: *const InputScope, scope: Element.Id) bool {
    return switch (self.active) {
        .none => true,
        .modal => |active_id| scope == active_id,
    };
}
