const std = @import("std");
const win32 = @import("win32").everything;
const window = @import("window");
const gpu = @import("gpu");

const events = @import("events.zig");
const keymap = @import("keymap.zig");

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("KnotsWindow");
const system_theme_registry_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");

const WHEEL_PAGESCROLL: u32 = std.math.maxInt(u32);
const WheelAxis = enum { x, y };
var class_registered: bool = false;

fn clientPxToLogical(hwnd: win32.HWND, pos: [2]f64) [2]f64 {
    const dpi = win32.GetDpiForWindow(hwnd);
    const scale: f64 = if (dpi == 0) 1.0 else @as(f64, @floatFromInt(dpi)) / 96.0;

    return .{
        pos[0] / scale,
        pos[1] / scale,
    };
}

fn mousePos(hwnd: win32.HWND, lparam: win32.LPARAM) [2]f64 {
    const pt = lparamPoint(lparam);
    return clientPxToLogical(hwnd, .{
        @floatFromInt(pt.x),
        @floatFromInt(pt.y),
    });
}

fn lparamPoint(lparam: win32.LPARAM) win32.POINT {
    const lp: u64 = @bitCast(@as(i64, lparam));
    const x_raw: u16 = @truncate(lp & 0xFFFF);
    const y_raw: u16 = @truncate((lp >> 16) & 0xFFFF);
    const x: i16 = @bitCast(x_raw);
    const y: i16 = @bitCast(y_raw);
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

fn wheelMousePos(hwnd: win32.HWND, lparam: win32.LPARAM) [2]f64 {
    var pt = lparamPoint(lparam);
    _ = win32.ScreenToClient(hwnd, &pt);
    return clientPxToLogical(hwnd, .{
        @floatFromInt(pt.x),
        @floatFromInt(pt.y),
    });
}

fn systemPrefersDarkTheme() bool {
    var hkey: ?win32.HKEY = undefined;

    if (win32.RegOpenKeyExW(win32.HKEY_CURRENT_USER, system_theme_registry_key, 0, win32.KEY_READ, &hkey) != win32.ERROR_SUCCESS)
        return false;

    defer _ = win32.RegCloseKey(hkey);

    var value: u32 = 1;
    var value_size: u32 = @sizeOf(u32);
    var value_type: win32.REG_VALUE_TYPE = .NONE;
    const value_name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");

    if (win32.RegQueryValueExW(
        hkey,
        value_name,
        null,
        &value_type,
        @ptrCast(&value),
        &value_size,
    ) != win32.ERROR_SUCCESS) {
        return false;
    }

    return value_type == win32.REG_DWORD and value == 0;
}

pub const Backend = struct {
    allocator: std.mem.Allocator,
    hwnd: win32.HWND,
    hinstance: win32.HINSTANCE,
    high_surrogate: u16 = 0,
    cursor_visible: bool = true,
    cursor_shape: window.CursorShape = .default,
    is_fullscreen: bool = false,
    should_close: bool = false,
    wheel_scroll_lines: u32 = 3,
    wheel_scroll_chars: u32 = 3,
    saved_placement: win32.WINDOWPLACEMENT = std.mem.zeroes(win32.WINDOWPLACEMENT),
    saved_style: win32.WINDOW_STYLE = .{},
    drop_paths_buf: [64][260]u8 = undefined,
    drop_slices: [64][]const u8 = undefined,
    min_size: ?window.Size,
    max_size: ?window.Size,

    const Self = @This();

    pub fn deinit(self: *const Self) void {
        _ = win32.SetWindowLongPtrW(self.hwnd, win32.GWLP_USERDATA, 0);
        _ = win32.DestroyWindow(self.hwnd);
    }

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        _ = win32.SetWindowLongPtrW(self.hwnd, win32.GWLP_USERDATA, @bitCast(@as(usize, @intFromPtr(owner))));
    }

    pub fn pollEvents(_: *const Self, _: std.Io) void {
        var msg: win32.MSG = undefined;
        while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
    }

    pub fn waitEvents(self: *const Self, io: std.Io) void {
        var msg: win32.MSG = undefined;
        const got = win32.GetMessageW(&msg, null, 0, 0);
        if (got > 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
        self.pollEvents(io);
    }

    pub fn postEmptyEvent(self: *const Self) void {
        _ = win32.PostMessageW(self.hwnd, win32.WM_NULL, 0, 0);
    }

    pub fn requestFrame(self: *const Self, _: *window.Window) void {
        _ = win32.InvalidateRect(self.hwnd, null, 0);
    }

    pub fn isOpen(self: *const Self) bool {
        return !self.should_close;
    }

    pub fn close(self: *Self) void {
        self.should_close = true;
    }

    pub fn getSize(self: *const Self) window.Size {
        var rect: win32.RECT = undefined;
        _ = win32.GetClientRect(self.hwnd, &rect);
        const scale = self.computeContentScale();
        return .{
            .width = @intFromFloat(@round(@as(f32, @floatFromInt(rect.right - rect.left)) / scale)),
            .height = @intFromFloat(@round(@as(f32, @floatFromInt(rect.bottom - rect.top)) / scale)),
        };
    }

    pub fn getFramebufferSize(self: *const Self) window.Size {
        var rect: win32.RECT = undefined;
        _ = win32.GetClientRect(self.hwnd, &rect);
        return .{
            .width = @intCast(rect.right - rect.left),
            .height = @intCast(rect.bottom - rect.top),
        };
    }

    pub fn computeContentScale(self: *const Self) f32 {
        const dpi = win32.GetDpiForWindow(self.hwnd);
        if (dpi == 0) return 1.0;
        return @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    pub fn getCursorPos(self: *const Self) [2]f64 {
        var pt: win32.POINT = undefined;
        _ = win32.GetCursorPos(&pt);
        _ = win32.ScreenToClient(self.hwnd, &pt);

        return clientPxToLogical(self.hwnd, .{
            @floatFromInt(pt.x),
            @floatFromInt(pt.y),
        });
    }

    pub fn getNativeHandle(self: *const Self, _: ?[:0]const u8) gpu.Context.WindowHandle {
        return .{ .windows = .{
            .hwnd = @ptrCast(self.hwnd),
            .hinstance = @ptrCast(self.hinstance),
        } };
    }

    pub fn setCursorVisible(self: *Self, visible: bool) void {
        if (visible == self.cursor_visible) return;
        if (visible) {
            while (win32.ShowCursor(1) < 0) {}
        } else {
            while (win32.ShowCursor(0) >= 0) {}
        }
        self.cursor_visible = visible;
    }

    pub fn setCursorShape(self: *Self, shape: window.CursorShape) void {
        if (self.cursor_shape == shape) return;
        self.cursor_shape = shape;
        _ = win32.SetCursor(loadCursor(shape));
    }

    pub fn setTitle(self: *Self, title: []const u8) !void {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, title);
        defer self.allocator.free(wide);
        if (win32.SetWindowTextW(self.hwnd, wide.ptr) == 0) return error.SetTitleFailed;
    }

    pub fn setDisplayMode(self: *Self, mode: window.DisplayMode) bool {
        switch (mode) {
            .windowed => {
                if (!self.is_fullscreen) return true;
                const style_bits: u32 = @bitCast(self.saved_style);
                _ = win32.SetWindowLongPtrW(self.hwnd, win32.GWL_STYLE, @bitCast(@as(usize, style_bits)));
                _ = win32.SetWindowPlacement(self.hwnd, &self.saved_placement);
                _ = win32.SetWindowPos(self.hwnd, null, 0, 0, 0, 0, .{
                    .NOMOVE = 1,
                    .NOSIZE = 1,
                    .NOZORDER = 1,
                    .DRAWFRAME = 1,
                });
                self.is_fullscreen = false;
                return true;
            },
            .fullscreen => {
                if (!self.is_fullscreen) {
                    self.saved_placement.length = @sizeOf(win32.WINDOWPLACEMENT);
                    _ = win32.GetWindowPlacement(self.hwnd, &self.saved_placement);
                    const cur: u32 = @intCast(win32.GetWindowLongPtrW(self.hwnd, win32.GWL_STYLE) & 0xFFFFFFFF);
                    self.saved_style = @bitCast(cur);
                }
                const monitor = win32.MonitorFromWindow(self.hwnd, .NEAREST) orelse return false;
                var mi: win32.MONITORINFO = .{
                    .cbSize = @sizeOf(win32.MONITORINFO),
                    .rcMonitor = undefined,
                    .rcWork = undefined,
                    .dwFlags = 0,
                };
                if (win32.GetMonitorInfoW(monitor, &mi) == 0) return false;
                var stripped = self.saved_style;
                stripped.THICKFRAME = 0;
                stripped.DLGFRAME = 0;
                stripped.BORDER = 0;
                stripped.SYSMENU = 0;
                stripped.GROUP = 0;
                stripped.TABSTOP = 0;
                const stripped_bits: u32 = @bitCast(stripped);
                _ = win32.SetWindowLongPtrW(self.hwnd, win32.GWL_STYLE, @bitCast(@as(usize, stripped_bits)));
                const r = mi.rcMonitor;
                _ = win32.SetWindowPos(self.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, .{
                    .NOZORDER = 1,
                    .DRAWFRAME = 1,
                });
                self.is_fullscreen = true;
                return true;
            },
        }
    }

    pub fn getDisplayMode(self: *const Self) window.DisplayMode {
        return if (self.is_fullscreen) .fullscreen else .windowed;
    }

    pub fn consumeResize(self: *Self, owner: *window.Window) ?window.ResizeEvent {
        if (!owner.resized) return null;
        owner.resized = false;
        return .{
            .logical = self.getSize(),
            .physical = self.getFramebufferSize(),
            .content_scale = self.computeContentScale(),
        };
    }

    pub fn consumeDrops(self: *Self, _: *window.Window, allocator: std.mem.Allocator, n: usize) ![][]const u8 {
        const out = try allocator.alloc([]const u8, n);
        errdefer allocator.free(out);
        for (0..n) |i| out[i] = try allocator.dupe(u8, self.drop_slices[i]);
        return out;
    }

    pub fn getClipboardText(self: *Self, allocator: std.mem.Allocator) !?[]u8 {
        if (win32.IsClipboardFormatAvailable(@intFromEnum(win32.CF_UNICODETEXT)) == 0) return null;
        if (win32.OpenClipboard(self.hwnd) == 0) return null;
        defer _ = win32.CloseClipboard();

        const handle = win32.GetClipboardData(@intFromEnum(win32.CF_UNICODETEXT)) orelse return null;
        const raw_handle: isize = @bitCast(@intFromPtr(handle));
        const locked = win32.GlobalLock(raw_handle) orelse return null;
        defer _ = win32.GlobalUnlock(raw_handle);

        const byte_len = win32.GlobalSize(raw_handle);
        if (byte_len < @sizeOf(u16)) return null;
        const max_len = byte_len / @sizeOf(u16);
        const wide: [*]const u16 = @ptrCast(@alignCast(locked));

        var len: usize = 0;
        while (len < max_len and wide[len] != 0) : (len += 1) {}
        if (len == 0) return try allocator.dupe(u8, "");
        return try std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..len]);
    }

    pub fn setClipboardText(self: *Self, allocator: std.mem.Allocator, text: []const u8) !bool {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
        defer allocator.free(wide);

        const byte_len = (wide.len + 1) * @sizeOf(u16);
        const handle = win32.GlobalAlloc(win32.GMEM_MOVEABLE, byte_len);
        if (handle == 0) return false;
        var transferred = false;
        defer _ = if (!transferred) win32.GlobalFree(handle);

        const locked = win32.GlobalLock(handle) orelse return false;
        @memcpy(@as([*]u16, @ptrCast(@alignCast(locked)))[0 .. wide.len + 1], wide.ptr[0 .. wide.len + 1]);
        _ = win32.GlobalUnlock(handle);

        if (win32.OpenClipboard(self.hwnd) == 0) return false;
        defer _ = win32.CloseClipboard();

        if (win32.EmptyClipboard() == 0) return false;
        const clipboard_handle: win32.HANDLE = @ptrFromInt(@as(usize, @bitCast(handle)));
        if (win32.SetClipboardData(@intFromEnum(win32.CF_UNICODETEXT), clipboard_handle) == null) return false;
        transferred = true;

        return true;
    }

    pub fn applyTitleBarTheme(self: *const Self) void {
        var enabled: win32.BOOL = @intFromBool(systemPrefersDarkTheme());
        _ = win32.DwmSetWindowAttribute(
            self.hwnd,
            win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
            &enabled,
            @sizeOf(win32.BOOL),
        );
    }

    fn refreshWheelSettings(self: *Self) void {
        self.wheel_scroll_lines = scrollSetting(win32.SPI_GETWHEELSCROLLLINES, 3);
        self.wheel_scroll_chars = scrollSetting(win32.SPI_GETWHEELSCROLLCHARS, 3);
    }
};

fn scrollSetting(action: win32.SYSTEM_PARAMETERS_INFO_ACTION, fallback: u32) u32 {
    var value: u32 = fallback;
    if (win32.SystemParametersInfoW(action, 0, @ptrCast(&value), .{}) == 0)
        return fallback;
    return value;
}

fn wheelSteps(delta: i16) f64 {
    return @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(win32.WHEEL_DELTA));
}

fn applyWheelLines(owner: *window.Window, axis: WheelAxis, steps: f64, setting: u32) void {
    if (setting == 0) return;
    if (axis == .y and setting == WHEEL_PAGESCROLL) {
        owner.addScrollPages(0, -steps);
        return;
    }

    const units = steps * @as(f64, @floatFromInt(setting));
    switch (axis) {
        .x => owner.addScrollLines(units, 0),
        .y => owner.addScrollLines(0, -units),
    }
}

pub fn init(_: std.Io, allocator: std.mem.Allocator, cfg: window.Config) !Backend {
    _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    const hinstance = win32.GetModuleHandleW(null) orelse return error.NoModuleHandle;

    if (!class_registered) {
        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{ .HREDRAW = 1, .VREDRAW = 1 },
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        if (win32.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
        class_registered = true;
    }

    var style: win32.WINDOW_STYLE = win32.WS_OVERLAPPEDWINDOW;
    if (!cfg.resizable) {
        style.THICKFRAME = 0;
        style.TABSTOP = 0;
    }

    const dpi = win32.GetDpiForSystem();
    const scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    var rect = win32.RECT{
        .left = 0,
        .top = 0,
        .right = @intFromFloat(@round(@as(f32, @floatFromInt(cfg.width)) * scale)),
        .bottom = @intFromFloat(@round(@as(f32, @floatFromInt(cfg.height)) * scale)),
    };
    _ = win32.AdjustWindowRectExForDpi(&rect, style, 0, .{}, dpi);
    const win_w = rect.right - rect.left;
    const win_h = rect.bottom - rect.top;

    var title_buf: [512]u16 = undefined;
    const title_len = std.unicode.utf8ToUtf16Le(&title_buf, cfg.title) catch return error.InvalidTitle;
    if (title_len >= title_buf.len) return error.TitleTooLong;
    title_buf[title_len] = 0;
    const title_z: [*:0]const u16 = @ptrCast(&title_buf);

    const hwnd = win32.CreateWindowExW(
        .{},
        class_name,
        title_z,
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win_w,
        win_h,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.CreateWindowFailed;

    _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    _ = win32.UpdateWindow(hwnd);
    win32.DragAcceptFiles(hwnd, 1);

    var backend = Backend{
        .allocator = allocator,
        .hwnd = hwnd,
        .hinstance = hinstance,
        .min_size = cfg.min_size,
        .max_size = cfg.max_size,
    };
    backend.refreshWheelSettings();
    backend.applyTitleBarTheme();

    return backend;
}

fn ownerOf(hwnd: win32.HWND) ?*window.Window {
    const raw: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA));
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

fn loadCursor(shape: window.CursorShape) ?win32.HCURSOR {
    const name = switch (shape) {
        .default => win32.IDC_ARROW,
        .text => win32.IDC_IBEAM,
        .pointer => win32.IDC_HAND,
        .crosshair => win32.IDC_CROSS,
        .move => win32.IDC_SIZEALL,
        .resize_horizontal => win32.IDC_SIZEWE,
        .resize_vertical => win32.IDC_SIZENS,
        .resize_diagonal_nw_se => win32.IDC_SIZENWSE,
        .resize_diagonal_ne_sw => win32.IDC_SIZENESW,
        .not_allowed => win32.IDC_NO,
    };
    return win32.LoadCursorW(null, name);
}

fn trackSize(hwnd: win32.HWND, size: window.Size, scale: f32) win32.POINT {
    var outer: win32.RECT = undefined;
    var client: win32.RECT = undefined;
    _ = win32.GetWindowRect(hwnd, &outer);
    _ = win32.GetClientRect(hwnd, &client);
    const non_client_width = (outer.right - outer.left) - (client.right - client.left);
    const non_client_height = (outer.bottom - outer.top) - (client.bottom - client.top);
    return .{
        .x = @as(i32, @intFromFloat(@as(f32, @floatFromInt(size.width)) * scale)) + non_client_width,
        .y = @as(i32, @intFromFloat(@as(f32, @floatFromInt(size.height)) * scale)) + non_client_height,
    };
}

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CLOSE => {
            if (ownerOf(hwnd)) |o| {
                o.markClosed();
                o.backend.should_close = true;
            }
            return 0;
        },
        win32.WM_GETMINMAXINFO => {
            if (ownerOf(hwnd)) |o| {
                const info: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                const scale = o.backend.computeContentScale();
                if (o.backend.min_size) |size| {
                    info.ptMinTrackSize = trackSize(hwnd, size, scale);
                }
                if (o.backend.max_size) |size| {
                    info.ptMaxTrackSize = trackSize(hwnd, size, scale);
                }
            }
            return 0;
        },
        win32.WM_DESTROY => return 0,
        win32.WM_PAINT => {
            var paint: win32.PAINTSTRUCT = undefined;
            _ = win32.BeginPaint(hwnd, &paint);
            defer _ = win32.EndPaint(hwnd, &paint);
            if (ownerOf(hwnd)) |o| if (o.isOpen()) o.stepFrame();
            return 0;
        },
        win32.WM_SIZE => {
            if (ownerOf(hwnd)) |o| {
                o.markResized();
                o.requestFrame();
            }
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            if (ownerOf(hwnd)) |o| o.setCursorPos(mousePos(hwnd, lparam));
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            _ = win32.SetCapture(hwnd);
            if (ownerOf(hwnd)) |o| o.setMouseButton(.left, true, mousePos(hwnd, lparam));
            return 0;
        },
        win32.WM_LBUTTONUP => {
            if (ownerOf(hwnd)) |o| {
                o.setMouseButton(.left, false, mousePos(hwnd, lparam));
                if (!o.anyMouseButtonDown()) _ = win32.ReleaseCapture();
            } else {
                _ = win32.ReleaseCapture();
            }
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            _ = win32.SetCapture(hwnd);
            if (ownerOf(hwnd)) |o| o.setMouseButton(.right, true, mousePos(hwnd, lparam));
            return 0;
        },
        win32.WM_RBUTTONUP => {
            if (ownerOf(hwnd)) |o| {
                o.setMouseButton(.right, false, mousePos(hwnd, lparam));
                if (!o.anyMouseButtonDown()) _ = win32.ReleaseCapture();
            } else {
                _ = win32.ReleaseCapture();
            }
            return 0;
        },
        win32.WM_MBUTTONDOWN, win32.WM_XBUTTONDOWN => {
            _ = win32.SetCapture(hwnd);
            if (ownerOf(hwnd)) |o| {
                const button: window.MouseButton = if (msg == win32.WM_MBUTTONDOWN) .middle else if (((wparam >> 16) & 0xFFFF) == 1) .back else .forward;
                o.setMouseButton(button, true, mousePos(hwnd, lparam));
            }
            return 0;
        },
        win32.WM_MBUTTONUP, win32.WM_XBUTTONUP => {
            if (ownerOf(hwnd)) |o| {
                const button: window.MouseButton = if (msg == win32.WM_MBUTTONUP) .middle else if (((wparam >> 16) & 0xFFFF) == 1) .back else .forward;
                o.setMouseButton(button, false, mousePos(hwnd, lparam));
                if (!o.anyMouseButtonDown()) _ = win32.ReleaseCapture();
            }
            return 0;
        },
        win32.WM_SETCURSOR => {
            const hit_test: u16 = @truncate(@as(usize, @bitCast(lparam)));
            if (hit_test == win32.HTCLIENT) {
                if (ownerOf(hwnd)) |o| {
                    _ = win32.SetCursor(loadCursor(o.backend.cursor_shape));
                    return 1;
                }
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_CONTEXTMENU => return 0,
        win32.WM_SETFOCUS => {
            if (ownerOf(hwnd)) |o| {
                o.setFocused(true);
                o.setMods(events.modsFromKeyState());
            }
            return 0;
        },
        win32.WM_KILLFOCUS => {
            if (ownerOf(hwnd)) |o| o.setFocused(false);
            if (win32.GetCapture() == hwnd) _ = win32.ReleaseCapture();
            return 0;
        },
        win32.WM_CAPTURECHANGED => {
            if (ownerOf(hwnd)) |o| if (o.anyMouseButtonDown()) o.cancelPointerInput();
            return 0;
        },
        win32.WM_MOUSEWHEEL => {
            const hi: u16 = @truncate((wparam >> 16) & 0xFFFF);
            const delta: i16 = @bitCast(hi);
            if (ownerOf(hwnd)) |o| {
                o.setCursorPos(wheelMousePos(hwnd, lparam));
                applyWheelLines(o, .y, wheelSteps(delta), o.backend.wheel_scroll_lines);
            }
            return 0;
        },
        win32.WM_MOUSEHWHEEL => {
            const hi: u16 = @truncate((wparam >> 16) & 0xFFFF);
            const delta: i16 = @bitCast(hi);
            if (ownerOf(hwnd)) |o| {
                o.setCursorPos(wheelMousePos(hwnd, lparam));
                applyWheelLines(o, .x, wheelSteps(delta), o.backend.wheel_scroll_chars);
            }
            return 0;
        },
        win32.WM_SETTINGCHANGE => {
            if (ownerOf(hwnd)) |o| {
                o.backend.refreshWheelSettings();
                o.backend.applyTitleBarTheme();
            }
            return 0;
        },
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            if (ownerOf(hwnd)) |o| events.onKey(o, wparam, lparam, true);
            if (msg == win32.WM_SYSKEYDOWN) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },
        win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            if (ownerOf(hwnd)) |o| events.onKey(o, wparam, lparam, false);
            if (msg == win32.WM_SYSKEYUP) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },
        win32.WM_CHAR => {
            if (ownerOf(hwnd)) |o| {
                events.onChar(o, &o.backend.high_surrogate, @truncate(wparam));
            }
            return 0;
        },
        win32.WM_DROPFILES => {
            if (ownerOf(hwnd)) |o| {
                const hdrop: win32.HDROP = @ptrFromInt(wparam);
                events.onDropFiles(&o.backend, o, hdrop);
            }
            return 0;
        },
        win32.WM_DPICHANGED => {
            const lp_usize: usize = @bitCast(lparam);
            const suggested: *const win32.RECT = @ptrFromInt(lp_usize);
            _ = win32.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                .{ .NOZORDER = 1, .NOACTIVATE = 1 },
            );
            if (ownerOf(hwnd)) |o| o.markResized();

            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
