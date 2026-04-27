const std = @import("std");
const knots = @import("knots");
const Perf = @import("Perf.zig");

pub const GPUBackend = @import("gpu_backend").Backend;
pub const PresentMode = @import("gpu").Context.PresentMode;

const FpsToggle = enum { off, on };

const SelectInput = knots.component.SelectInput;
const Button = knots.component.Button;
const Text = knots.component.Text;
const Spacer = knots.component.Spacer;

const If = knots.control.If;

const present_modes = std.enums.values(PresentMode);

const State = struct {
    backend_idx: u32,
    present_mode_idx: u32,
    show_fps_idx: u32 = 0,
    perf: Perf = .{ .fps_buf = &.{} },
    fps_buf: [128]u8 = undefined,

    fn initFpsBuf(self: *State) void {
        self.perf.fps_buf = &self.fps_buf;
    }
};

state: *State,
onClick: ?*const fn (*knots.App) anyerror!void = null,

const RendererSettings = @This();

fn mustFindIdx(slice: anytype, needle: anytype) u32 {
    for (slice, 0..) |be, i| {
        if (needle == be) {
            return @intCast(i);
        }
    }

    unreachable;
}

fn enumTagNames(comptime T: type, comptime values: []const T) [][]const u8 {
    comptime var names: [values.len][]const u8 = undefined;
    inline for (values, 0..) |v, i| names[i] = @tagName(v);
    const fixed: [values.len][]const u8 = names;
    return @constCast(&fixed);
}

pub fn init(allocator: std.mem.Allocator, gpu_backend: GPUBackend, present_mode: PresentMode) !RendererSettings {
    const state = try allocator.create(State);
    state.* = .{
        .backend_idx = mustFindIdx(GPUBackend.availableSlice(), gpu_backend),
        .present_mode_idx = mustFindIdx(present_modes, present_mode),
    };
    state.initFpsBuf();

    return .{ .state = state };
}

pub fn deinit(self: *const RendererSettings, allocator: std.mem.Allocator) void {
    allocator.destroy(self.state);
}

const apply_key: knots.ui.Key = .str("renderer_settings_apply");
const backend_key: knots.ui.Key = .str("renderer_settings_backend");
const present_mode_key: knots.ui.Key = .str("renderer_settings_present_mode");
const fps_key: knots.ui.Key = .str("renderer_settings_fps");

fn selectedIdx(app: *knots.App, key: knots.ui.Key, fallback: u32) u32 {
    const s = app.ui.state.get(.select_input, key.hash()) orelse return fallback;
    return s.selected orelse fallback;
}

pub fn render(self: *const RendererSettings, app: *knots.App) anyerror!void {
    self.state.show_fps_idx = selectedIdx(app, fps_key, self.state.show_fps_idx);

    if (self.state.show_fps_idx == 1) {
        self.state.perf.updateFps(app.timer.delta) catch {};
    }

    try app.e(.{
        Text{ .content = "GPU API", .size = 12, .key = .src(@src()) },
        SelectInput(GPUBackend){
            .key = backend_key,
            .initial_selected = self.state.backend_idx,
            .width = .fixed(100),
            .labels = enumTagNames(GPUBackend, GPUBackend.availableSlice()),
            .values = GPUBackend.availableSlice(),
        },
        Text{ .content = "Present mode", .size = 12, .key = .src(@src()) },
        SelectInput(PresentMode){
            .key = present_mode_key,
            .initial_selected = self.state.present_mode_idx,
            .width = .fixed(120),
        },
        Text{ .content = "FPS", .size = 12, .key = .src(@src()) },
        SelectInput(FpsToggle){
            .key = fps_key,
            .initial_selected = self.state.show_fps_idx,
            .width = .fixed(60),
        },
        Button{
            .height = .fixed(28),
            .width = .fixed(55),
            .style = .{ .color = .primary, .corner_radius = .sm },
            .key = apply_key,
            .justify = .center,
            .@"align" = .center,
            .onClick = self.onClick,
            .text = .{ .content = "Apply", .size = 12 },
        },
    });

    if (app.ui.clicked(apply_key.hash())) {
        const backend_idx = selectedIdx(app, backend_key, self.state.backend_idx);
        const present_mode_idx = selectedIdx(app, present_mode_key, self.state.present_mode_idx);
        self.state.backend_idx = backend_idx;
        self.state.present_mode_idx = present_mode_idx;
        try app.reconfigureRenderer(.{
            .gpu_backend = GPUBackend.availableSlice()[backend_idx],
            .present_mode = present_modes[present_mode_idx],
        });
    }

    if (self.state.show_fps_idx == 1) {
        try app.e(.{&self.state.perf});
    }
}
