//! IMM32 input method support.
//!
//! The input method's composition is drawn inline by the UI, so the default
//! composition window is hidden; only the candidate window is positioned, next
//! to the composition. Queries (`WM_IME_REQUEST`) are answered from the window's
//! copy of the text input session. IMM32 speaks UTF-16 offsets; they are
//! converted to bytes here and nowhere else.
const std = @import("std");
const win32 = @import("win32").everything;
const input_types = @import("input");
const window = @import("window");

const Window = window.Window;
const State = window.TextInputState;
const TextRange = input_types.TextRange;
const Segment = input_types.CompositionSegment;

const composition_units_max = 1024;

/// Per-window input method state, kept on the backend.
pub const Ime = struct {
    /// IMM32 is composing; the keys belong to it.
    composing: bool = false,
    /// A dead key's accent is showing as the composition, waiting for the next character.
    dead_key: bool = false,
    /// Where the candidate window was last placed, to skip placing it again.
    placed: ?win32.RECT = null,
};

fn dpiScale(hwnd: win32.HWND) f32 {
    const dpi = win32.GetDpiForWindow(hwnd);
    return if (dpi == 0) 1.0 else @as(f32, @floatFromInt(dpi)) / 96.0;
}

fn physicalRect(hwnd: win32.HWND, r: input_types.TextRect) win32.RECT {
    const s = dpiScale(hwnd);
    return .{
        .left = @intFromFloat(@round(r.x * s)),
        .top = @intFromFloat(@round(r.y * s)),
        .right = @intFromFloat(@round((r.x + r.w) * s)),
        .bottom = @intFromFloat(@round((r.y + r.h) * s)),
    };
}

/// Hides the default composition window: the UI draws the composition itself.
pub fn onSetContext(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
    const flags: isize = @bitCast(@as(usize, win32.ISC_SHOWUICOMPOSITIONWINDOW));
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam & ~flags);
}

/// Places the candidate window under the composition, or under the caret,
/// when that moved since it was last placed or `force` is set.
pub fn position(hwnd: win32.HWND, owner: *Window, force: bool) void {
    if (!owner.text_input.active) return;
    const anchor = if (owner.text_input.composition_rects.items.len > 0)
        owner.text_input.composition_rects.items[0]
    else
        owner.text_input.caret;
    const rect = physicalRect(hwnd, anchor);
    const state = &owner.backend.ime;
    if (!force) if (state.placed) |placed| if (std.meta.eql(placed, rect)) return;
    const himc = win32.ImmGetContext(hwnd) orelse return;
    defer _ = win32.ImmReleaseContext(hwnd, himc);
    state.placed = rect;
    var composition: win32.COMPOSITIONFORM = .{
        .dwStyle = win32.CFS_POINT,
        .ptCurrentPos = .{ .x = rect.left, .y = rect.top },
        .rcArea = rect,
    };
    _ = win32.ImmSetCompositionWindow(himc, &composition);
    var candidate: win32.CANDIDATEFORM = .{
        .dwIndex = 0,
        .dwStyle = win32.CFS_EXCLUDE,
        .ptCurrentPos = .{ .x = rect.left, .y = rect.bottom },
        .rcArea = rect,
    };
    _ = win32.ImmSetCandidateWindow(himc, &candidate);
}

pub fn onStartComposition(hwnd: win32.HWND, owner: *Window) bool {
    if (!owner.text_input.active) return false;
    owner.backend.ime.composing = true;
    position(hwnd, owner, true);
    return true;
}

/// Turns IMM32's composition and result strings into edits. Returns false to
/// let the default window procedure handle it (no field has focus).
pub fn onComposition(hwnd: win32.HWND, owner: *Window, lparam: win32.LPARAM) bool {
    if (!owner.text_input.active) return false;
    const himc = win32.ImmGetContext(hwnd) orelse return true;
    defer _ = win32.ImmReleaseContext(hwnd, himc);
    const flags: u32 = @truncate(@as(usize, @bitCast(lparam)));
    const result_flag: u32 = @bitCast(win32.GCS_RESULTSTR);
    const comp_flag: u32 = @bitCast(win32.GCS_COMPSTR);

    var utf8_buf: [composition_units_max * 3]u8 = undefined;
    if (flags & result_flag != 0) {
        const text = compositionString(himc, win32.GCS_RESULTSTR, &utf8_buf) orelse "";
        owner.pushTextEdit(.{ .session = owner.text_input.id, .replace = owner.text_input.target(), .text = text });
    }
    if (flags & comp_flag != 0) {
        const text = compositionString(himc, win32.GCS_COMPSTR, &utf8_buf) orelse "";
        var segments_buf: [64]Segment = undefined;
        const segments = clauses(himc, text, &segments_buf);
        const cursor_units: i32 = win32.ImmGetCompositionStringW(himc, win32.GCS_CURSORPOS, null, 0);
        const caret = State.byteOffset(text, @intCast(@max(cursor_units, 0)));
        owner.pushTextEdit(.{
            .session = owner.text_input.id,
            .replace = owner.text_input.target(),
            .text = text,
            .compose = .{ .caret = .at(caret), .segments = segments },
        });
    } else if (flags & result_flag == 0) {
        // Neither string: the input method cancelled the composition.
        cancel(owner);
    }
    position(hwnd, owner, false);
    return true;
}

pub fn onEndComposition(owner: *Window) bool {
    owner.backend.ime.composing = false;
    if (!owner.text_input.active) return false;
    cancel(owner);
    return true;
}

/// A dead key: shows its accent as the composition until `WM_CHAR` brings the
/// composed character, which replaces it. Returns false when no field has focus.
pub fn onDeadChar(owner: *Window, w: u16) bool {
    if (!owner.text_input.active) return false;
    var encoded: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(w, &encoded) catch return false;
    owner.pushTextEdit(.{
        .session = owner.text_input.id,
        .replace = owner.text_input.target(),
        .text = encoded[0..n],
        .compose = .{ .caret = .at(@intCast(n)) },
    });
    owner.backend.ime.dead_key = true;
    return true;
}

/// A key that types nothing followed the dead key, which the keyboard layout
/// has already dropped; drop its accent too.
pub fn endDeadKey(owner: *Window) void {
    owner.backend.ime.dead_key = false;
    cancel(owner);
}

/// Clears a dead key the keyboard layout still holds, after the UI committed or
/// dropped its accent, so the next key does not type it again.
fn flushDeadKey() void {
    var state: [256]u8 = @splat(0);
    var buf: [4]u16 = undefined;
    const space: u32 = @backingInt(win32.VK_SPACE);
    var tries: u32 = 0;
    while (tries < 2 and win32.ToUnicode(space, 0x39, &state, @ptrCast(&buf), buf.len, 0) < 0) : (tries += 1) {}
}

fn cancel(owner: *Window) void {
    const composition = owner.text_input.composition orelse return;
    owner.pushTextEdit(.{ .session = owner.text_input.id, .replace = composition, .text = "", .compose = .{ .caret = .at(0) } });
}

fn compositionString(himc: win32.HIMC, which: win32.IME_COMPOSITION_STRING, out: []u8) ?[]const u8 {
    var units: [composition_units_max]u16 = undefined;
    const bytes = win32.ImmGetCompositionStringW(himc, which, &units, @sizeOf(@TypeOf(units)));
    if (bytes < 0) return null;
    const n: usize = @intCast(@divTrunc(bytes, 2));
    const len = std.unicode.utf16LeToUtf8(out, units[0..n]) catch return null;
    return out[0..len];
}

/// Clauses from GCS_COMPCLAUSE; the one whose attribute is a conversion target is active.
fn clauses(himc: win32.HIMC, text: []const u8, out: []Segment) []const Segment {
    var bounds: [65]u32 = undefined;
    const clause_bytes = win32.ImmGetCompositionStringW(himc, win32.GCS_COMPCLAUSE, &bounds, @sizeOf(@TypeOf(bounds)));
    if (clause_bytes < 8) return &.{};
    var attrs: [composition_units_max]u8 = undefined;
    const attr_len = win32.ImmGetCompositionStringW(himc, win32.GCS_COMPATTR, &attrs, attrs.len);

    const count: usize = @min(@as(usize, @intCast(@divTrunc(clause_bytes, 4))) - 1, out.len);
    for (0..count) |i| {
        const start_units = bounds[i];
        const attr: u32 = if (attr_len > 0 and start_units < @as(u32, @intCast(attr_len))) attrs[start_units] else 0;
        out[i] = .{
            .start = State.byteOffset(text, start_units),
            .end = State.byteOffset(text, bounds[i + 1]),
            .active = attr == win32.ATTR_TARGET_CONVERTED or attr == win32.ATTR_TARGET_NOTCONVERTED,
        };
    }
    return out[0..count];
}

/// Answers the input method's questions about the field. Returns null to fall
/// back to the default window procedure.
pub fn onRequest(hwnd: win32.HWND, owner: *Window, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    if (!owner.text_input.active) return null;
    const state = &owner.text_input;
    switch (@as(u32, @truncate(wparam))) {
        win32.IMR_QUERYCHARPOSITION => {
            const query: *win32.IMECHARPOSITION = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const base = if (state.composition) |c| c.start else state.selection.end;
            const base_units = State.utf16Offset(state.text.items, base);
            const byte = State.byteOffset(state.text.items, base_units + query.dwCharPos);
            var rect = physicalRect(hwnd, state.rectFor(byte));
            var top_left: win32.POINT = .{ .x = rect.left, .y = rect.top };
            _ = win32.ClientToScreen(hwnd, &top_left);
            query.pt = top_left;
            query.cLineHeight = @intCast(@max(rect.bottom - rect.top, 0));
            _ = win32.GetClientRect(hwnd, &rect);
            var doc_tl: win32.POINT = .{ .x = rect.left, .y = rect.top };
            var doc_br: win32.POINT = .{ .x = rect.right, .y = rect.bottom };
            _ = win32.ClientToScreen(hwnd, &doc_tl);
            _ = win32.ClientToScreen(hwnd, &doc_br);
            query.rcDocument = .{ .left = doc_tl.x, .top = doc_tl.y, .right = doc_br.x, .bottom = doc_br.y };
            return 1;
        },
        win32.IMR_DOCUMENTFEED => return reconvertString(owner, lparam, state.composition orelse state.selection),
        win32.IMR_RECONVERTSTRING => {
            if (state.composition != null or state.selection.start == state.selection.end) return 0;
            return reconvertString(owner, lparam, state.selection);
        },
        win32.IMR_CONFIRMRECONVERTSTRING => {
            // The input method may widen the target; select what it will replace.
            const rs: *const win32.RECONVERTSTRING = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const units_start = rs.dwCompStrOffset / 2;
            const selection = State.byteRange(state.text.items, .{ .start = units_start, .end = units_start + rs.dwCompStrLen });
            owner.pushTextEdit(.{ .session = state.id, .replace = .at(selection.start), .text = "", .selection = selection });
            return 1;
        },
        else => return null,
    }
}

/// RECONVERTSTRING over the whole field, with `target` as the composition.
/// With `lparam == 0` the input method asks only for the size.
fn reconvertString(owner: *Window, lparam: win32.LPARAM, target: TextRange) win32.LRESULT {
    const text = owner.text_input.text.items;
    const units = State.utf16Offset(text, @intCast(text.len));
    const size: u32 = @sizeOf(win32.RECONVERTSTRING) + (units + 1) * 2;
    if (lparam == 0) return @intCast(size);

    const rs: *win32.RECONVERTSTRING = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (rs.dwSize < size) return 0;
    const dest: [*]u16 = @ptrFromInt(@intFromPtr(rs) + @sizeOf(win32.RECONVERTSTRING));
    const written = std.unicode.utf8ToUtf16Le(dest[0..units], text) catch return 0;
    dest[written] = 0;
    const t = State.utf16Range(text, target);
    rs.* = .{
        .dwSize = size,
        .dwVersion = 0,
        .dwStrLen = @intCast(written),
        .dwStrOffset = @sizeOf(win32.RECONVERTSTRING),
        .dwCompStrLen = t.len(),
        .dwCompStrOffset = t.start * 2,
        .dwTargetStrLen = t.len(),
        .dwTargetStrOffset = t.start * 2,
    };
    return @intCast(size);
}

/// Enables the input method only while a field has focus, and drops its
/// composition when focus moves or the UI committed it.
pub fn update(hwnd: win32.HWND, owner: *Window, change: State.Change) void {
    const state = &owner.backend.ime;
    if (change.any()) {
        if (win32.ImmGetContext(hwnd)) |himc| {
            _ = win32.ImmNotifyIME(himc, win32.NI_COMPOSITIONSTR, win32.CPS_CANCEL, 0);
            _ = win32.ImmReleaseContext(hwnd, himc);
        }
        if (state.dead_key) flushDeadKey();
        state.dead_key = false;
    }
    if (change.started) _ = win32.ImmAssociateContextEx(hwnd, null, win32.IACE_DEFAULT);
    if (change.ended) {
        _ = win32.ImmAssociateContextEx(hwnd, null, 0);
        state.composing = false;
    }
    position(hwnd, owner, change.started);
}
