//! The official AccessKit C API. Node and update ownership is transferred when
//! pushed into a tree update; adapter ownership stays with the window host.
const std = @import("std");
pub const c = @import("c");

pub const Node = struct {
    handle: *c.accesskit_node,

    pub fn init(role: c.accesskit_role) !Node {
        return .{ .handle = c.accesskit_node_new(role) orelse return error.OutOfMemory };
    }

    pub fn deinit(self: *Node) void {
        c.accesskit_node_free(self.handle);
        self.* = undefined;
    }

    pub fn setLabel(self: *Node, label: []const u8) void {
        std.debug.assert(label.len <= std.math.maxInt(u32));
        c.accesskit_node_set_label_with_length(self.handle, label.ptr, label.len);
    }
};

pub const TreeUpdate = struct {
    handle: *c.accesskit_tree_update,

    pub fn init(focus: u64) !TreeUpdate {
        return .{ .handle = c.accesskit_tree_update_with_focus(focus) orelse return error.OutOfMemory };
    }

    pub fn deinit(self: *TreeUpdate) void {
        c.accesskit_tree_update_free(self.handle);
        self.* = undefined;
    }

    pub fn pushNode(self: *TreeUpdate, id: u64, node: *Node) void {
        std.debug.assert(id != std.math.maxInt(u64));
        c.accesskit_tree_update_push_node(self.handle, id, node.handle);
        node.* = undefined;
    }

    pub fn release(self: *TreeUpdate) *c.accesskit_tree_update {
        const handle = self.handle;
        self.* = undefined;
        return handle;
    }
};
