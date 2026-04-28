const std = @import("std");
const win32 = @import("win32").everything;
const window = @import("window");
const gpu = @import("gpu");

const events = @import("events.zig");
const keymap = @import("keymap.zig");

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("KnotsWindow");
var class_registered: bool = false;

pub const Backend = struct {
    hwnd: win32.HWND,
    hinstance: win32.HINSTANCE,
    high_surrogate: u16 = 0,
    cursor_visible: bool = true,
    is_fullscreen: bool = false,
    saved_placement: win32.WINDOWPLACEMENT = std.mem.zeroes(win32.WINDOWPLACEMENT),
    saved_style: win32.WINDOW_STYLE = .{},
    drop_paths_buf: [64][260]u8 = undefined,
    drop_slices: [64][]const u8 = undefined,

    const Self = @This();

    pub fn deinit(self: *const Self) void {
        _ = win32.DestroyWindow(self.hwnd);
    }

    pub fn startCapture(self: *Self, owner: *window.Window) void {
        _ = win32.SetWindowLongPtrW(self.hwnd, win32.GWLP_USERDATA, @bitCast(@as(usize, @intFromPtr(owner))));
    }

    pub fn setDropCallback(self: *Self, _: *window.Window) void {
        win32.DragAcceptFiles(self.hwnd, 1);
    }

    pub fn pollEvents(_: *const Self) void {
        var msg: win32.MSG = undefined;
        while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
    }

    pub fn waitEvents(self: *const Self) void {
        var msg: win32.MSG = undefined;
        const got = win32.GetMessageW(&msg, null, 0, 0);
        if (got > 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
        self.pollEvents();
    }

    pub fn postEmptyEvent(self: *const Self) void {
        _ = win32.PostMessageW(self.hwnd, win32.WM_NULL, 0, 0);
    }

    pub fn isOpen(_: *const Self) bool {
        return true;
    }

    pub fn close(_: *Self) void {}

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
        return .{ @floatFromInt(pt.x), @floatFromInt(pt.y) };
    }

    pub fn getNativeHandle(self: *const Self, _: ?[:0]const u8) gpu.Context.WindowHandle {
        return .{ .windows = .{
            .hwnd = @ptrCast(self.hwnd),
            .hinstance = @ptrCast(self.hinstance),
        } };
    }

    pub fn setCursorVisible(self: *const Self, visible: bool) void {
        const m: *Self = @constCast(self);
        if (visible == m.cursor_visible) return;
        _ = win32.ShowCursor(if (visible) 1 else 0);
        m.cursor_visible = visible;
    }

    pub fn setDisplayMode(self: *Self, mode: window.DisplayMode) void {
        switch (mode) {
            .windowed => {
                if (!self.is_fullscreen) return;
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
            },
            .fullscreen, .fullscreen_windowed => {
                if (!self.is_fullscreen) {
                    self.saved_placement.length = @sizeOf(win32.WINDOWPLACEMENT);
                    _ = win32.GetWindowPlacement(self.hwnd, &self.saved_placement);
                    const cur: u32 = @intCast(win32.GetWindowLongPtrW(self.hwnd, win32.GWL_STYLE) & 0xFFFFFFFF);
                    self.saved_style = @bitCast(cur);
                }
                const monitor = win32.MonitorFromWindow(self.hwnd, .NEAREST) orelse return;
                var mi: win32.MONITORINFO = .{
                    .cbSize = @sizeOf(win32.MONITORINFO),
                    .rcMonitor = undefined,
                    .rcWork = undefined,
                    .dwFlags = 0,
                };
                if (win32.GetMonitorInfoW(monitor, &mi) == 0) return;
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
            },
        }
    }

    pub fn applyEmscriptenSize(_: *Self, _: window.ResizeEvent) void {
        @compileError("emscripten not supported with windows backend");
    }
};

pub fn init(cfg: window.Config, _: *window.Window) !Backend {
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
    var rect = win32.RECT{
        .left = 0,
        .top = 0,
        .right = @intCast(cfg.width),
        .bottom = @intCast(cfg.height),
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

    return .{ .hwnd = hwnd, .hinstance = hinstance };
}

fn ownerOf(hwnd: win32.HWND) ?*window.Window {
    const raw: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA));
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CLOSE => {
            if (ownerOf(hwnd)) |o| o.markClosed();
            return 0;
        },
        win32.WM_DESTROY => return 0,
        win32.WM_SIZE => {
            if (ownerOf(hwnd)) |o| o.markResized();
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            _ = win32.SetCapture(hwnd);
            if (ownerOf(hwnd)) |o| o.setMouseDown(true);
            return 0;
        },
        win32.WM_LBUTTONUP => {
            _ = win32.ReleaseCapture();
            if (ownerOf(hwnd)) |o| o.setMouseDown(false);
            return 0;
        },
        win32.WM_MOUSEWHEEL => {
            const hi: u16 = @truncate((wparam >> 16) & 0xFFFF);
            const delta: i16 = @bitCast(hi);
            const dy: f64 = @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(win32.WHEEL_DELTA));
            if (ownerOf(hwnd)) |o| o.addScroll(0, dy);
            return 0;
        },
        win32.WM_MOUSEHWHEEL => {
            const hi: u16 = @truncate((wparam >> 16) & 0xFFFF);
            const delta: i16 = @bitCast(hi);
            const dx: f64 = @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(win32.WHEEL_DELTA));
            if (ownerOf(hwnd)) |o| o.addScroll(dx, 0);
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
