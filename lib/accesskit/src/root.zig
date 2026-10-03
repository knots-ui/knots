//! The official AccessKit C API. Node and update ownership is transferred when
//! pushed into a tree update; adapter ownership stays with the window host.
const std = @import("std");
const builtin = @import("builtin");
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

test "node wrapper round-trips through the C API" {
    var node = try Node.init(c.ACCESSKIT_ROLE_BUTTON);
    defer node.deinit();
    node.setLabel("Submit and more"[0..6]);
    c.accesskit_node_push_child(node.handle, 7);
    c.accesskit_node_push_child(node.handle, 9);
    c.accesskit_node_add_action(node.handle, c.ACCESSKIT_ACTION_CLICK);

    try std.testing.expectEqual(c.ACCESSKIT_ROLE_BUTTON, c.accesskit_node_role(node.handle));
    const label = c.accesskit_node_label(node.handle) orelse return error.MissingLabel;
    defer c.accesskit_string_free(label);
    try std.testing.expectEqualStrings("Submit", std.mem.span(label));
    const children = c.accesskit_node_children(node.handle);
    try std.testing.expectEqualSlices(u64, &.{ 7, 9 }, children.values[0..children.length]);
    try std.testing.expect(c.accesskit_node_supports_action(node.handle, c.ACCESSKIT_ACTION_CLICK));
    try std.testing.expect(!c.accesskit_node_supports_action(node.handle, c.ACCESSKIT_ACTION_FOCUS));
}

test "tree update takes ownership of pushed nodes" {
    var update = try TreeUpdate.init(1);
    var root = try Node.init(c.ACCESSKIT_ROLE_WINDOW);
    c.accesskit_node_push_child(root.handle, 2);
    update.pushNode(1, &root);
    var child = try Node.init(c.ACCESSKIT_ROLE_LABEL);
    child.setLabel("hi");
    update.pushNode(2, &child);
    c.accesskit_tree_update_set_tree_info(update.handle, c.accesskit_tree_info_new(1) orelse return error.OutOfMemory);
    c.accesskit_tree_update_set_focus(update.handle, 2);
    c.accesskit_tree_update_free(update.release());
}

test "windows handle types match the platform ABI" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const params = @typeInfo(@TypeOf(c.accesskit_windows_adapter_handle_wm_getobject)).@"fn".param_types;
    try std.testing.expectEqual(usize, params[1].?);
    try std.testing.expectEqual(isize, params[2].?);
    try std.testing.expectEqual(isize, @FieldType(c.accesskit_opt_lresult, "value"));
    const hwnd = @typeInfo(@TypeOf(c.accesskit_windows_adapter_new)).@"fn".param_types[0].?;
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(hwnd));
}
