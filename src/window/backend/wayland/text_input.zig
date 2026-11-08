//! Dead keys and compose sequences (xkb_compose), and input methods (text-input-v3).
const std = @import("std");
const wayland = @import("wayland");
const input_types = @import("input");
const window = @import("window");
const xkb = @import("xkb.zig");

const wl = wayland.client.wl;
const zwp = wayland.client.zwp;
const Window = window.Window;
const State = window.TextInputState;
const TextRange = input_types.TextRange;

/// Wayland caps surrounding text at 4000 bytes.
const surrounding_max = 4000;

fn showPreedit(owner: *Window, text: []const u8, caret: TextRange) void {
    if (!owner.text_input.active) return;
    owner.pushTextEdit(.{
        .session = owner.text_input.id,
        .text = text,
        .compose = .{ .caret = caret },
    });
}

fn clearPreedit(owner: *Window) void {
    const composition = owner.text_input.composition orelse return;
    owner.pushTextEdit(.{ .session = owner.text_input.id, .replace = composition, .text = "", .compose = .{ .caret = .at(0) } });
}

pub const Compose = struct {
    table: ?*xkb.ComposeTable = null,
    state: ?*xkb.ComposeState = null,
    /// The keys typed so far, shown as the composition.
    preedit: [64]u8 = undefined,
    preedit_len: usize = 0,

    pub const Result = enum {
        pass,
        consumed,
    };

    pub fn init(self: *Compose, context: *xkb.Context) void {
        if (self.table != null) return;
        const table = xkb.xkb_compose_table_new_from_locale(context, locale(), xkb.COMPOSE_COMPILE_NO_FLAGS) orelse return;
        const state = xkb.xkb_compose_state_new(table, xkb.COMPOSE_STATE_NO_FLAGS) orelse {
            xkb.xkb_compose_table_unref(table);
            return;
        };
        self.table = table;
        self.state = state;
    }

    pub fn deinit(self: *Compose) void {
        if (self.state) |state| xkb.xkb_compose_state_unref(state);
        if (self.table) |table| xkb.xkb_compose_table_unref(table);
        self.* = .{};
    }

    pub fn reset(self: *Compose) void {
        if (self.state) |state| xkb.xkb_compose_state_reset(state);
        self.preedit_len = 0;
    }

    pub fn feed(self: *Compose, owner: *Window, keysym: u32) Result {
        const state = self.state orelse return .pass;
        if (xkb.xkb_compose_state_feed(state, keysym) != .accepted) return .pass;
        switch (xkb.xkb_compose_state_get_status(state)) {
            .composing => {
                self.append(keysym);
                const text = self.preedit[0..self.preedit_len];
                showPreedit(owner, text, .at(@intCast(text.len)));
                return .consumed;
            },
            .composed => {
                var buf: [64]u8 = undefined;
                const n = xkb.xkb_compose_state_get_utf8(state, &buf, buf.len);
                self.reset();
                if (n > 0) {
                    owner.pushText(buf[0..@intCast(@min(n, buf.len - 1))]);
                } else {
                    clearPreedit(owner);
                }
                return .consumed;
            },
            .cancelled => {
                self.reset();
                clearPreedit(owner);
                return .consumed;
            },
            else => return .pass,
        }
    }

    fn append(self: *Compose, keysym: u32) void {
        var buf: [8]u8 = undefined;
        const text = spacingForm(keysym) orelse blk: {
            const n = xkb.xkb_keysym_to_utf8(keysym, &buf, buf.len);
            if (n <= 1) break :blk "·";
            break :blk buf[0..@intCast(n - 1)];
        };
        if (self.preedit_len + text.len > self.preedit.len) return;
        @memcpy(self.preedit[self.preedit_len..][0..text.len], text);
        self.preedit_len += text.len;
    }

    /// The visible form of a dead key, which itself types nothing.
    fn spacingForm(keysym: u32) ?[]const u8 {
        return switch (keysym) {
            0xfe50 => "`",
            0xfe51 => "´",
            0xfe52 => "^",
            0xfe53 => "~",
            0xfe54 => "¯",
            0xfe55 => "˘",
            0xfe56 => "˙",
            0xfe57 => "¨",
            0xfe58 => "˚",
            0xfe59 => "˝",
            0xfe5a => "ˇ",
            0xfe5b => "¸",
            0xfe5c => "˛",
            0xff20 => "·", // Multi_key
            else => null,
        };
    }

    fn locale() [*:0]const u8 {
        for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
            if (std.c.getenv(name)) |value| {
                if (value[0] != 0) return value;
            }
        }
        return "C";
    }
};

/// One text-input-v3 object per seat.
pub const Ime = struct {
    allocator: std.mem.Allocator,
    text_input: ?*zwp.TextInputV3 = null,
    entered: ?*wl.Surface = null,
    enabled: bool = false,
    /// What was last sent, to commit only on change.
    sent_digest: u64 = 0,
    /// Edits arrived from the input method since the last state was sent.
    edited: bool = false,
    pending: Pending = .{},

    const Pending = struct {
        preedit: std.ArrayList(u8) = .empty,
        preedit_set: bool = false,
        cursor_begin: i32 = -1,
        cursor_end: i32 = -1,
        commit: std.ArrayList(u8) = .empty,
        commit_set: bool = false,
        delete_before: u32 = 0,
        delete_after: u32 = 0,
    };

    pub fn deinit(self: *Ime) void {
        if (self.text_input) |ti| ti.destroy();
        self.pending.preedit.deinit(self.allocator);
        self.pending.commit.deinit(self.allocator);
        self.text_input = null;
    }

    /// `done` applies the events since the last one.
    pub fn handle(self: *Ime, event: zwp.TextInputV3.Event, owner: ?*Window) void {
        switch (event) {
            .enter => |e| {
                self.entered = e.surface;
                self.enabled = false;
                self.sent_digest = 0;
            },
            .leave => {
                self.entered = null;
                self.enabled = false;
            },
            .preedit_string => |e| {
                self.pending.preedit.clearRetainingCapacity();
                if (e.text) |text| self.pending.preedit.appendSlice(self.allocator, std.mem.span(text)) catch {};
                self.pending.preedit_set = true;
                self.pending.cursor_begin = e.cursor_begin;
                self.pending.cursor_end = e.cursor_end;
            },
            .commit_string => |e| {
                self.pending.commit.clearRetainingCapacity();
                if (e.text) |text| self.pending.commit.appendSlice(self.allocator, std.mem.span(text)) catch {};
                self.pending.commit_set = true;
            },
            .delete_surrounding_text => |e| {
                self.pending.delete_before = e.before_length;
                self.pending.delete_after = e.after_length;
            },
            .done => {
                if (owner) |o| self.apply(o);
                self.pending.preedit.clearRetainingCapacity();
                self.pending.commit.clearRetainingCapacity();
                self.pending = .{ .preedit = self.pending.preedit, .commit = self.pending.commit };
            },
        }
    }

    /// The protocol's order: drop the old preedit, delete around the cursor,
    /// insert the commit string, then show the new preedit.
    fn apply(self: *Ime, owner: *Window) void {
        if (!owner.text_input.active) return;
        const p = &self.pending;
        const state = &owner.text_input;
        // Only deleting around the cursor needs a range.
        const replace: ?TextRange = if (p.delete_before == 0 and p.delete_after == 0) null else blk: {
            const target = state.target();
            const len: u32 = @intCast(state.text.items.len);
            break :blk .{
                .start = target.start -| p.delete_before,
                .end = @min(target.end +| p.delete_after, len),
            };
        };
        if (state.composition != null or p.commit_set or p.delete_before > 0 or p.delete_after > 0) {
            owner.pushTextEdit(.{ .session = state.id, .replace = replace, .text = p.commit.items });
        }
        if (p.preedit_set and p.preedit.items.len > 0) {
            const text = p.preedit.items;
            const text_len: u32 = @intCast(text.len);
            // A negative cursor hides it; put the caret at the end.
            const caret: TextRange = if (p.cursor_begin < 0 or p.cursor_end < 0)
                .at(text_len)
            else
                .{ .start = @min(@as(u32, @intCast(p.cursor_begin)), text_len), .end = @min(@as(u32, @intCast(p.cursor_end)), text_len) };
            showPreedit(owner, text, caret);
        }
        self.edited = true;
    }

    pub fn sync(self: *Ime, surface: *wl.Surface, owner: *Window, change: State.Change) void {
        const ti = self.text_input orelse return;
        if (self.entered != surface) return;
        const state = &owner.text_input;
        if (!state.active) {
            if (self.enabled) {
                ti.disable();
                ti.commit();
                self.enabled = false;
            }
            return;
        }
        if (change.started or change.composition_dropped or !self.enabled) {
            // Enabling resets the input method, dropping any composition it holds.
            if (self.enabled) ti.disable();
            ti.enable();
            self.enabled = true;
            self.sent_digest = 0;
        }

        // Surrounding text excludes the composition and stays within the protocol's limit.
        var buf: [surrounding_max + 1]u8 = undefined;
        const text = state.text.items;
        const cut = state.composition orelse TextRange.at(state.selection.start);
        const before = text[0..cut.start];
        const after = text[cut.end..];
        const anchor_doc = if (state.composition != null) cut.start else state.selection.start;
        const cursor_doc = if (state.composition != null) cut.start else state.selection.end;
        const keep_before = floorBoundary(before, before.len -| surrounding_max / 2);
        const window_before = before[keep_before..];
        const window_after = after[0..floorBoundary(after, @min(after.len, surrounding_max - window_before.len))];
        @memcpy(buf[0..window_before.len], window_before);
        @memcpy(buf[window_before.len..][0..window_after.len], window_after);
        buf[window_before.len + window_after.len] = 0;
        const surrounding: [:0]const u8 = buf[0 .. window_before.len + window_after.len :0];
        const cursor: i32 = @intCast(cursor_doc - @as(u32, @intCast(keep_before)));
        const anchor: i32 = @intCast(anchor_doc -| @as(u32, @intCast(keep_before)));

        const caret = state.caret;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(surrounding);
        hasher.update(std.mem.asBytes(&cursor));
        hasher.update(std.mem.asBytes(&anchor));
        hasher.update(std.mem.asBytes(&caret));
        hasher.update(std.mem.asBytes(&state.purpose));
        const digest = hasher.final() | 1;
        if (digest == self.sent_digest) return;

        ti.setSurroundingText(surrounding.ptr, cursor, anchor);
        ti.setTextChangeCause(if (self.edited) .input_method else .other);
        ti.setContentType(.{ .multiline = state.purpose == .multiline }, .normal);
        ti.setCursorRectangle(
            @intFromFloat(@round(caret.x)),
            @intFromFloat(@round(caret.y)),
            @intFromFloat(@max(@round(caret.w), 1)),
            @intFromFloat(@max(@round(caret.h), 1)),
        );
        ti.commit();
        self.sent_digest = digest;
        self.edited = false;
    }
};

fn floorBoundary(text: []const u8, byte: usize) usize {
    var b = @min(byte, text.len);
    while (b > 0 and b < text.len and (text[b] & 0xC0) == 0x80) b -= 1;
    return b;
}
