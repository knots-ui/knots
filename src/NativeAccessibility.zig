//! One native AccessKit adapter per viewport. Callbacks never enter the UI.
const std = @import("std");
const accesskit = @import("accesskit");
const c = accesskit.c;
const Accessibility = @import("ui").Accessibility;
const Context = @import("ui").Context;
const WindowHandle = @import("gpu").Context.WindowHandle;

const os_tag = @import("builtin").target.os.tag;

const Adapter = @This();

allocator: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,
arena: std.heap.ArenaAllocator,
snapshot: Accessibility.Snapshot = .{ .nodes = &.{.{ .id = Accessibility.root_id, .role = .generic }} },
changed_nodes: [Accessibility.nodes_max]bool = @splat(false),
tree_initialized: bool = false,
adapter: switch (os_tag) {
    .linux => *c.accesskit_unix_adapter,
    .windows => *c.accesskit_windows_adapter,
    .macos => *c.accesskit_macos_subclassing_adapter,
    else => void,
},
actions: [Accessibility.actions_max]QueuedAction = undefined,
action_count: u32 = 0,
actions_dropped: u32 = 0,
wake_context: *anyopaque,
wake: *const fn (*anyopaque) void,

const QueuedAction = struct {
    request: Accessibility.ActionRequest,
    text: [Accessibility.text_bytes_max]u8 = undefined,
};

pub fn create(allocator: std.mem.Allocator, io: std.Io, handle: WindowHandle, wake_context: *anyopaque, wake: *const fn (*anyopaque) void) !*Adapter {
    const self = try allocator.create(Adapter);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .arena = .init(allocator),
        .adapter = undefined,
        .wake_context = wake_context,
        .wake = wake,
    };
    switch (os_tag) {
        .linux => {
            self.adapter = c.accesskit_unix_adapter_new(activate, self, action, self, deactivate, self) orelse return error.AccessibilityAdapterUnavailable;
        },
        .windows => self.adapter = c.accesskit_windows_adapter_new(@ptrCast(handle.windows.hwnd), true, action, self) orelse return error.AccessibilityAdapterUnavailable,
        .macos => self.adapter = c.accesskit_macos_subclassing_adapter_for_window(handle.macos.ns_window, activate, self, action, self) orelse return error.AccessibilityAdapterUnavailable,
        else => @compileError("AccessKit adapters require a native desktop target"),
    }
    return self;
}

pub fn destroy(self: *Adapter) void {
    switch (os_tag) {
        .linux => c.accesskit_unix_adapter_free(self.adapter),
        .windows => c.accesskit_windows_adapter_free(self.adapter),
        .macos => c.accesskit_macos_subclassing_adapter_free(self.adapter),
        else => unreachable,
    }
    self.arena.deinit();
    self.allocator.destroy(self);
}

/// Copy before the UI's borrowed output is invalidated by the next frame.
pub fn publish(self: *Adapter, snapshot: Accessibility.Snapshot, focused: bool) !void {
    if (snapshot.nodes.len == 0) return error.MissingAccessibilityRoot;
    if (snapshot.nodes.len > Accessibility.nodes_max) return error.TooManyAccessibilityNodes;
    if (snapshot.children.len > Accessibility.nodes_max) return error.TooManyAccessibilityNodes;
    if (snapshot.nodes[0].id != Accessibility.root_id) return error.InvalidAccessibilityRoot;
    for (snapshot.nodes) |node| {
        if (node.child_start > snapshot.children.len) return error.InvalidAccessibilityChildren;
        if (node.child_count > snapshot.children.len - node.child_start) return error.InvalidAccessibilityChildren;
    }
    self.mutex.lockUncancelable(self.io);
    const changed = self.snapshot.revision != snapshot.revision;
    self.mutex.unlock(self.io);
    if (!changed) {
        self.updateFocus(focused);
        return;
    }
    var next_arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer next_arena.deinit();
    const memory = next_arena.allocator();
    const nodes = try memory.dupe(Accessibility.Node, snapshot.nodes);
    // Child lists retain traversal order; sorting this owned copy makes ID diffs linear.
    std.mem.sort(Accessibility.Node, nodes, {}, lessAccessibilityNodeById);
    if (nodes[0].id != Accessibility.root_id) return error.InvalidAccessibilityRoot;
    var previous_id = nodes[0].id;
    for (nodes[1..]) |node| {
        if (previous_id == node.id) return error.DuplicateAccessibilityId;
        previous_id = node.id;
    }
    for (nodes) |*node| {
        node.name = try memory.dupe(u8, node.name);
        if (node.state.value_text) |value| node.state.value_text = try memory.dupe(u8, value);
    }
    const children = try memory.dupe(@TypeOf(Accessibility.root_id), snapshot.children);
    const next_snapshot: Accessibility.Snapshot = .{
        .revision = snapshot.revision,
        .content_scale = snapshot.content_scale,
        .nodes = nodes,
        .children = children,
        .focus = snapshot.focus,
    };
    self.mutex.lockUncancelable(self.io);
    changedNodeMask(self.snapshot, next_snapshot, &self.changed_nodes);
    var previous_arena = self.arena;
    self.arena = next_arena;
    self.snapshot = next_snapshot;
    self.mutex.unlock(self.io);
    previous_arena.deinit();
    switch (os_tag) {
        .linux => {
            c.accesskit_unix_adapter_update_if_active(self.adapter, update, self);
        },
        .windows => {
            if (c.accesskit_windows_adapter_update_if_active(self.adapter, update, self)) |events| c.accesskit_windows_queued_events_raise(events);
        },
        .macos => {
            if (c.accesskit_macos_subclassing_adapter_update_if_active(self.adapter, update, self)) |events| c.accesskit_macos_queued_events_raise(events);
        },
        else => unreachable,
    }
    self.updateFocus(focused);
}

fn updateFocus(self: *Adapter, focused: bool) void {
    switch (os_tag) {
        .linux => c.accesskit_unix_adapter_update_window_focus_state(self.adapter, focused),
        .windows => if (c.accesskit_windows_adapter_update_window_focus_state(self.adapter, focused)) |events| c.accesskit_windows_queued_events_raise(events),
        .macos => if (c.accesskit_macos_subclassing_adapter_update_view_focus_state(self.adapter, focused)) |events| c.accesskit_macos_queued_events_raise(events),
        else => unreachable,
    }
}

pub fn drain(self: *Adapter, context: *Context) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var index: u32 = 0;
    while (index < self.action_count) : (index += 1) {
        const queued = &self.actions[index];
        var request = queued.request;
        if (request.value_text) |text| request.value_text = queued.text[0..text.len];
        context.enqueueAccessibilityAction(request) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.actions_dropped +|= 1;
        };
    }
    self.action_count = 0;
}

pub fn hasActions(self: *Adapter) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.action_count != 0;
}

pub fn handleWmGetobject(self: *Adapter, wparam: usize, lparam: isize) ?isize {
    if (comptime os_tag == .windows) {
        const result = c.accesskit_windows_adapter_handle_wm_getobject(self.adapter, wparam, lparam, activate, self);
        return if (result.has_value) result.value else null;
    }
    return null;
}

fn activate(userdata: ?*anyopaque) callconv(.c) ?*c.accesskit_tree_update {
    const self: *Adapter = @ptrCast(@alignCast(userdata.?));
    self.mutex.lockUncancelable(self.io);
    const initialized = self.snapshot.revision != 0;
    self.mutex.unlock(self.io);
    if (!initialized) return null;
    return self.makeUpdate(true);
}

fn update(userdata: ?*anyopaque) callconv(.c) ?*c.accesskit_tree_update {
    const self: *Adapter = @ptrCast(@alignCast(userdata.?));
    return self.makeUpdate(false);
}

fn deactivate(_: ?*anyopaque) callconv(.c) void {}

fn makeUpdate(self: *Adapter, force_full: bool) ?*c.accesskit_tree_update {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    std.debug.assert(self.snapshot.nodes.len > 0);
    std.debug.assert(self.snapshot.nodes[0].id == Accessibility.root_id);
    const full_update = force_full or !self.tree_initialized;
    var tree = accesskit.TreeUpdate.init(self.snapshot.focus) catch @panic("AccessKit tree allocation failed");
    if (full_update) {
        if (c.accesskit_tree_info_new(Accessibility.root_id)) |info| c.accesskit_tree_update_set_tree_info(tree.handle, info);
    }
    const node_count: u32 = @intCast(self.snapshot.nodes.len);
    var node_index: u32 = 0;
    while (node_index < node_count) : (node_index += 1) {
        const semantic = self.snapshot.nodes[node_index];
        if (!full_update and !self.changed_nodes[node_index]) continue;
        var node = accesskit.Node.init(role(semantic)) catch @panic("AccessKit node allocation failed");
        if (semantic.role != .text_run) node.setLabel(semantic.name);
        if (semantic.state.value_text) |value| c.accesskit_node_set_value_with_length(node.handle, value.ptr, value.len);
        if (semantic.role == .text_run) setCharacterLengths(self.allocator, node.handle, semantic.state.value_text orelse &.{});
        if (semantic.state.selection_anchor) |anchor| {
            if (semantic.state.selection_focus) |focus| {
                const text_run_id = semantic.text_run_id orelse @panic("Text input is missing its text run");
                c.accesskit_node_set_text_selection(node.handle, .{
                    .anchor = .{ .node = text_run_id, .character_index = anchor },
                    .focus = .{ .node = text_run_id, .character_index = focus },
                });
            }
        }
        if (semantic.state.value_number) |value| c.accesskit_node_set_numeric_value(node.handle, value);
        if (semantic.state.min) |value| c.accesskit_node_set_min_numeric_value(node.handle, value);
        if (semantic.state.max) |value| c.accesskit_node_set_max_numeric_value(node.handle, value);
        if (semantic.state.disabled) c.accesskit_node_set_disabled(node.handle);
        if (semantic.state.checked) |value| c.accesskit_node_set_toggled(node.handle, if (value) c.ACCESSKIT_TOGGLED_TRUE else c.ACCESSKIT_TOGGLED_FALSE);
        if (semantic.state.selected) |value| c.accesskit_node_set_selected(node.handle, value);
        if (semantic.state.expanded) |value| c.accesskit_node_set_expanded(node.handle, value);
        // AccessKit expects physical pixels relative to the window. The Unix
        // adapter can add the window's screen origin on X11, but Wayland does
        // not expose that origin to clients, so we never invent one here.
        const scale = self.snapshot.content_scale;
        const bounds = semantic.bounds;
        std.debug.assert(semantic.child_start <= self.snapshot.children.len);
        std.debug.assert(semantic.child_count <= self.snapshot.children.len - semantic.child_start);
        c.accesskit_node_set_bounds(node.handle, .{
            .x0 = @floatCast(bounds.x() * scale),
            .y0 = @floatCast(bounds.y() * scale),
            .x1 = @floatCast((bounds.x() + bounds.w()) * scale),
            .y1 = @floatCast((bounds.y() + bounds.h()) * scale),
        });
        for (self.snapshot.children[semantic.child_start..][0..semantic.child_count]) |child| c.accesskit_node_push_child(node.handle, child);
        inline for (.{ .focus, .click, .collapse, .expand, .decrement, .increment, .set_value, .replace_selected_text, .set_text_selection }) |kind| {
            if (semantic.actions.contains(kind)) c.accesskit_node_add_action(node.handle, nativeAction(kind));
        }
        tree.pushNode(semantic.id, &node);
    }
    self.tree_initialized = true;
    return tree.release();
}

fn changedNodeMask(previous: Accessibility.Snapshot, current: Accessibility.Snapshot, changed: *[Accessibility.nodes_max]bool) void {
    std.debug.assert(previous.nodes.len > 0);
    std.debug.assert(current.nodes.len > 0);
    std.debug.assert(previous.nodes.len <= Accessibility.nodes_max);
    std.debug.assert(current.nodes.len <= Accessibility.nodes_max);
    std.debug.assert(previous.nodes[0].id == Accessibility.root_id);
    std.debug.assert(current.nodes[0].id == Accessibility.root_id);
    @memset(changed[0..current.nodes.len], false);
    if (previous.content_scale != current.content_scale) {
        @memset(changed[0..current.nodes.len], true);
        return;
    }

    const previous_count: u32 = @intCast(previous.nodes.len);
    const current_count: u32 = @intCast(current.nodes.len);
    var previous_index: u32 = 0;
    var current_index: u32 = 0;
    while (current_index < current_count) : (current_index += 1) {
        const node = current.nodes[current_index];
        while (previous_index < previous_count and previous.nodes[previous_index].id < node.id) : (previous_index += 1) {}
        if (previous_index == previous_count) {
            changed[current_index] = true;
            continue;
        }
        const old_node = previous.nodes[previous_index];
        if (old_node.id != node.id) {
            changed[current_index] = true;
            continue;
        }
        changed[current_index] = !accessibilityNodeEql(previous, old_node, current, node);
        previous_index += 1;
    }
}

fn accessibilityNodeEql(previous: Accessibility.Snapshot, old_node: Accessibility.Node, current: Accessibility.Snapshot, node: Accessibility.Node) bool {
    if (old_node.id != node.id) return false;
    if (old_node.parent != node.parent) return false;
    if (old_node.text_run_id != node.text_run_id) return false;
    if (old_node.role != node.role) return false;
    if (!std.mem.eql(u8, old_node.name, node.name)) return false;
    if (!std.meta.eql(old_node.bounds, node.bounds)) return false;
    if (old_node.state.disabled != node.state.disabled) return false;
    if (old_node.state.focused != node.state.focused) return false;
    if (old_node.state.checked != node.state.checked) return false;
    if (old_node.state.selected != node.state.selected) return false;
    if (old_node.state.expanded != node.state.expanded) return false;
    if (old_node.state.multiline != node.state.multiline) return false;
    if (old_node.state.selection_anchor != node.state.selection_anchor) return false;
    if (old_node.state.selection_focus != node.state.selection_focus) return false;
    if (!optionalTextEql(old_node.state.value_text, node.state.value_text)) return false;
    if (old_node.state.value_number != node.state.value_number) return false;
    if (old_node.state.min != node.state.min) return false;
    if (old_node.state.max != node.state.max) return false;
    if (old_node.actions.bits != node.actions.bits) return false;
    std.debug.assert(old_node.child_start <= previous.children.len);
    std.debug.assert(old_node.child_count <= previous.children.len - old_node.child_start);
    std.debug.assert(node.child_start <= current.children.len);
    std.debug.assert(node.child_count <= current.children.len - node.child_start);
    const old_children = previous.children[old_node.child_start..][0..old_node.child_count];
    const children = current.children[node.child_start..][0..node.child_count];
    return std.mem.eql(@TypeOf(Accessibility.root_id), old_children, children);
}

fn optionalTextEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_text| {
        if (right) |right_text| return std.mem.eql(u8, left_text, right_text);
        return false;
    }
    return right == null;
}

fn lessAccessibilityNodeById(_: void, left: Accessibility.Node, right: Accessibility.Node) bool {
    return left.id < right.id;
}

test "incremental diff includes insertions, changes and parent child lists" {
    const previous_nodes = [_]Accessibility.Node{
        .{ .id = 0, .role = .generic, .child_count = 2 },
        .{ .id = 10, .parent = 0, .role = .generic },
        .{ .id = 20, .parent = 0, .role = .generic },
    };
    const previous_children = [_]@TypeOf(Accessibility.root_id){ 10, 20 };
    const current_nodes = [_]Accessibility.Node{
        .{ .id = 0, .role = .generic, .child_count = 2 },
        .{ .id = 20, .parent = 0, .role = .generic },
        .{ .id = 30, .parent = 0, .role = .generic },
    };
    const current_children = [_]@TypeOf(Accessibility.root_id){ 20, 30 };
    const previous: Accessibility.Snapshot = .{
        .nodes = &previous_nodes,
        .children = &previous_children,
    };
    var current: Accessibility.Snapshot = .{
        .nodes = &current_nodes,
        .children = &current_children,
    };
    var changed: [Accessibility.nodes_max]bool = @splat(false);

    changedNodeMask(previous, current, &changed);
    const expected_structure = [_]bool{ true, false, true };
    try std.testing.expectEqualSlices(bool, &expected_structure, changed[0..current.nodes.len]);

    var changed_nodes = current_nodes;
    changed_nodes[1].state.selected = true;
    current.nodes = &changed_nodes;
    changedNodeMask(previous, current, &changed);
    const expected_state = [_]bool{ true, true, true };
    try std.testing.expectEqualSlices(bool, &expected_state, changed[0..current.nodes.len]);
}

fn role(semantic: Accessibility.Node) c.accesskit_role {
    if (semantic.id == Accessibility.root_id) return c.ACCESSKIT_ROLE_WINDOW;
    return switch (semantic.role) {
        .generic => c.ACCESSKIT_ROLE_GENERIC_CONTAINER,
        .text_run => c.ACCESSKIT_ROLE_TEXT_RUN,
        .button => c.ACCESSKIT_ROLE_BUTTON,
        .checkbox => c.ACCESSKIT_ROLE_CHECK_BOX,
        .radio => c.ACCESSKIT_ROLE_RADIO_BUTTON,
        .slider => c.ACCESSKIT_ROLE_SLIDER,
        .text_input => if (semantic.state.multiline) c.ACCESSKIT_ROLE_MULTILINE_TEXT_INPUT else c.ACCESSKIT_ROLE_TEXT_INPUT,
        .select => c.ACCESSKIT_ROLE_COMBO_BOX,
        .list_box => c.ACCESSKIT_ROLE_LIST_BOX,
        .list_box_option => c.ACCESSKIT_ROLE_LIST_BOX_OPTION,
        .dialog => c.ACCESSKIT_ROLE_DIALOG,
        .menu => c.ACCESSKIT_ROLE_MENU,
        .tooltip => c.ACCESSKIT_ROLE_TOOLTIP,
    };
}

fn nativeAction(kind: Accessibility.Action) c.accesskit_action {
    return switch (kind) {
        .focus => c.ACCESSKIT_ACTION_FOCUS,
        .click => c.ACCESSKIT_ACTION_CLICK,
        .collapse => c.ACCESSKIT_ACTION_COLLAPSE,
        .expand => c.ACCESSKIT_ACTION_EXPAND,
        .decrement => c.ACCESSKIT_ACTION_DECREMENT,
        .increment => c.ACCESSKIT_ACTION_INCREMENT,
        .set_value => c.ACCESSKIT_ACTION_SET_VALUE,
        .replace_selected_text => c.ACCESSKIT_ACTION_REPLACE_SELECTED_TEXT,
        .set_text_selection => c.ACCESSKIT_ACTION_SET_TEXT_SELECTION,
    };
}

fn action(raw: ?*c.accesskit_action_request, userdata: ?*anyopaque) callconv(.c) void {
    const request = raw orelse return;
    defer c.accesskit_action_request_free(request);
    const self: *Adapter = @ptrCast(@alignCast(userdata.?));
    const kind: Accessibility.Action = switch (request.action) {
        c.ACCESSKIT_ACTION_FOCUS => .focus,
        c.ACCESSKIT_ACTION_CLICK => .click,
        c.ACCESSKIT_ACTION_COLLAPSE => .collapse,
        c.ACCESSKIT_ACTION_EXPAND => .expand,
        c.ACCESSKIT_ACTION_DECREMENT => .decrement,
        c.ACCESSKIT_ACTION_INCREMENT => .increment,
        c.ACCESSKIT_ACTION_SET_VALUE => .set_value,
        c.ACCESSKIT_ACTION_REPLACE_SELECTED_TEXT => .replace_selected_text,
        c.ACCESSKIT_ACTION_SET_TEXT_SELECTION => .set_text_selection,
        else => return,
    };
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var target_node: ?*const Accessibility.Node = null;
    for (self.snapshot.nodes) |*node| {
        if (node.id != request.target_node) continue;
        target_node = node;
        break;
    }
    const semantic = target_node orelse {
        self.actions_dropped +|= 1;
        return;
    };
    if (!semantic.actions.contains(kind)) {
        self.actions_dropped +|= 1;
        return;
    }
    if (self.action_count == Accessibility.actions_max) {
        self.actions_dropped +|= 1;
        return;
    }
    const slot = &self.actions[self.action_count];
    slot.request = .{ .id = request.target_node, .action = kind };
    if (request.data.has_value) {
        const data = request.data.value;
        switch (data.tag) {
            c.ACCESSKIT_ACTION_DATA_VALUE => {
                const pointer = data.unnamed_0.unnamed_1.value;
                if (pointer == null) return;
                var length: u32 = 0;
                while (length <= Accessibility.text_bytes_max) : (length += 1) {
                    if (pointer[length] == 0) break;
                }
                if (length > Accessibility.text_bytes_max) {
                    self.actions_dropped +|= 1;
                    return;
                }
                @memcpy(slot.text[0..length], pointer[0..length]);
                slot.request.value_text = slot.text[0..length];
            },
            c.ACCESSKIT_ACTION_DATA_NUMERIC_VALUE => slot.request.value_number = data.unnamed_0.unnamed_2.numeric_value,
            c.ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION => {
                const selection = data.unnamed_0.unnamed_7.set_text_selection;
                const target_text_run_id = semantic.text_run_id orelse return;
                if (selection.anchor.node != target_text_run_id) return;
                if (selection.focus.node != target_text_run_id) return;
                slot.request.selection_anchor = @intCast(@min(selection.anchor.character_index, std.math.maxInt(u32)));
                slot.request.selection_focus = @intCast(@min(selection.focus.character_index, std.math.maxInt(u32)));
            },
            else => {},
        }
    }
    self.action_count += 1;
    self.wake(self.wake_context);
}

fn setCharacterLengths(allocator: std.mem.Allocator, node: *c.accesskit_node, value: []const u8) void {
    const lengths = allocator.alloc(u8, value.len) catch @panic("AccessKit text allocation failed");
    defer allocator.free(lengths);
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < value.len) {
        const width = std.unicode.utf8ByteSequenceLength(value[offset]) catch @panic("Invalid UTF-8 in accessibility text");
        std.debug.assert(offset + width <= value.len);
        lengths[count] = width;
        offset += width;
        count += 1;
    }
    c.accesskit_node_set_character_lengths(node, count, lengths.ptr);
}

test "native conversion constructs an owned complete tree" {
    var adapter: Adapter = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .arena = .init(std.testing.allocator),
        .adapter = undefined,
        .wake_context = undefined,
        .wake = undefined,
        .snapshot = .{
            .nodes = &.{
                .{ .id = 0, .role = .generic, .child_count = 1 },
                .{ .id = 123, .parent = 0, .role = .button, .name = "Activate", .actions = blk: {
                    var actions: std.EnumSet(Accessibility.Action) = .empty;
                    actions.insert(.focus);
                    actions.insert(.click);
                    break :blk actions;
                } },
            },
            .children = &.{123},
            .focus = 123,
        },
    };
    defer adapter.arena.deinit();
    const update_handle = adapter.makeUpdate(true) orelse return error.AccessibilityUpdateUnavailable;
    defer c.accesskit_tree_update_free(update_handle);
    const description = c.accesskit_tree_update_debug(update_handle) orelse return error.AccessibilityUpdateUnavailable;
    defer c.accesskit_string_free(description);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(description), "Activate") != null);
    var button = try accesskit.Node.init(c.ACCESSKIT_ROLE_BUTTON);
    defer button.deinit();
    try std.testing.expectEqual(c.ACCESSKIT_ROLE_BUTTON, c.accesskit_node_role(button.handle));
    c.accesskit_node_add_action(button.handle, c.ACCESSKIT_ACTION_FOCUS);
    c.accesskit_node_add_action(button.handle, c.ACCESSKIT_ACTION_CLICK);
    try std.testing.expect(c.accesskit_node_supports_action(button.handle, c.ACCESSKIT_ACTION_FOCUS));
    try std.testing.expect(c.accesskit_node_supports_action(button.handle, c.ACCESSKIT_ACTION_CLICK));
}

test "incremental native conversion omits unchanged nodes" {
    var adapter: Adapter = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .arena = .init(std.testing.allocator),
        .adapter = undefined,
        .wake_context = undefined,
        .wake = undefined,
        .snapshot = .{
            .nodes = &.{
                .{ .id = 0, .role = .generic, .child_count = 2 },
                .{ .id = 123, .parent = 0, .role = .button, .name = "Unchanged" },
                .{ .id = 234, .parent = 0, .role = .button, .name = "Changed" },
            },
            .children = &.{ 123, 234 },
            .focus = 0,
        },
        .tree_initialized = true,
    };
    defer adapter.arena.deinit();
    adapter.changed_nodes[0] = true;
    adapter.changed_nodes[2] = true;
    const update_handle = adapter.makeUpdate(false) orelse return error.AccessibilityUpdateUnavailable;
    defer c.accesskit_tree_update_free(update_handle);
    const description = c.accesskit_tree_update_debug(update_handle) orelse return error.AccessibilityUpdateUnavailable;
    defer c.accesskit_string_free(description);
    const update_text = std.mem.span(description);
    try std.testing.expect(std.mem.indexOf(u8, update_text, "Changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, update_text, "Unchanged") == null);
}
