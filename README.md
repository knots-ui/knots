# Knots

Knots is a cross-platform immediate-mode GUI library written in Zig. The UI
engine is independent of windows and graphics APIs. `App` is the bundled window
and renderer integration; `ui.Context` and `render.Packet` are the embedding
boundary.

## Supported platforms

| Platform            | GPU APIs                    |
| ------------------- | --------------------------- |
| macOS               | WebGPU, Vulkan (MoltenVK)   |
| Linux               | WebGPU, Vulkan              |
| Windows             | WebGPU, Vulkan              |
| WASM (freestanding) | WebGPU                      |


## Known limitations
- Linux windowing is Wayland-only.
- Text rendering is UTF-8/codepoint based. HarfBuzz shaping, bidi layout, ligatures, font fallback, and IME composition are not implemented yet.

## Install

```sh
zig fetch --save git+https://codeberg.org/shahwali/knots.git
```

## Requirements

- Zig compiler, minimum version can be found in [build.zig.zon](build.zig.zon). I try to keep up with the master branch.
- On Linux, Wayland development packages are required: wayland-client, wayland-cursor, wayland-protocols, wayland-scanner, pkg-config, and xkbcommon.

## Minimal app

To develop with independently reloadable UI modules in a native window, see the
[playground and HMR quick start](examples/playground/README.md).

Add the `knots` and `ui` modules to your executable:

```zig
const knots = b.dependency("knots", .{ .target = target, .optimize = optimize });

exe.root_module.addImport("knots", knots.module("knots"));
exe.root_module.addImport("ui", knots.module("ui"));
```

Build the UI in a frame callback:

```zig
const std = @import("std");
const knots = @import("knots");
const ui = @import("ui");

pub fn main(init: std.process.Init) !void {
    var app = try knots.App.init(init.io, init.gpa, .{
        .window = .{ .width = 1280, .height = 720, .title = "Knots" },
    });
    defer app.deinit();
    try app.start(frame);
}

fn frame(_: *knots.View, frame_context: *ui.Frame) !void {
    const size = frame_context.input().logical_extent;
    try frame_context.e(ui.component.Rect{
        .width = .fixed(@floatFromInt(size.width)),
        .height = .fixed(@floatFromInt(size.height)),
        .padding = .init(16, 16, 16, 16),
        .key = .src(@src()),
    });
}
```

`View` is callback data containing the owning `app`, the viewport `id`, and a
renderer status snapshot. Use `view.app` for viewport actions. Application state
can embed `knots.App` and recover itself with `@fieldParentPtr("app", view.app)`;
keep the `App` at a stable address until `start` returns.

## Embedding in an existing renderer

Import `ui`, `input`, and `render`. Add `renderer` when using Knots' bundled GPU
backend:

```zig
app_module.addImport("ui", knots_dependency.module("ui"));
app_module.addImport("input", knots_dependency.module("input"));
app_module.addImport("render", knots_dependency.module("render"));
app_module.addImport("renderer", knots_dependency.module("renderer"));
```

```zig
var context = try ui.Context.init(allocator, .{});
defer context.deinit();

var frame = try context.beginFrame(host_input);
defer frame.deinit();
try buildUi(&frame);

const output = try context.endFrame(&frame);
window.setCursorShape(output.cursor_shape);
if (output.clipboard_write) |value| {
    _ = try window.setClipboardText(allocator, value);
}

const prepared = try painter.prepare(&output.packet, &.{
    .width = target_width,
    .height = target_height,
    .content_scale = host_input.content_scale,
    .upload_slot = submission.upload_slot,
    .frame_context = submission,
    .linear_target = false,
});
try painter.encode(&prepared, host_pass);
```

Use `Renderer.render` when Knots owns the surface. Use `Painter.prepare` and
`Painter.encode` when the host owns render passes, submission, or presentation.
`render.Packet` is graphics-API independent, but its geometry, glyph, clipping,
and shader conventions are Knots' protocol. A renderer for another API consumes
the packet directly; `Painter` uses the bundled backend types.

## Ownership and lifetime

- Packet data, input slices, image bytes, and callback data are borrowed. Consume
  them before the next frame or copy them for asynchronous work.
- The host must keep textures and callback resources alive until GPU completion.
- Complete the previous work for an upload slot before reusing it in
  `Painter.prepare`. Call `Painter.destroyAfterWait` only after all GPU work is
  complete.
- `Frame.deinit` aborts unfinished frames and is safe across copied handles.
- Apply cursor and clipboard effects once; the host decides when to redraw or
  close a window.
- Custom backends must validate packet extensions and reject unsupported commands.

The bundled renderer synchronizes glyph atlas uploads and retires replaced
resources by upload slot. Its cache and packet data are bounded; no glyph
acknowledgement API is required.

## Browser WASM

The browser build uses the same `App` and frame callback. Install the web host
with `Knots.installWeb`:

```zig
const Knots = @import("knots");

const knots = b.dependency("knots", .{
    .target = target,
    .optimize = optimize,
    .web_threads = true,
});

const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "knots", .module = knots.module("knots") },
        .{ .name = "ui", .module = knots.module("ui") },
    },
});
const exe = b.addExecutable(.{ .name = "app", .root_module = exe_mod });
exe.entry = .disabled;
Knots.installWeb(b, knots, exe_mod, exe, .{});
```

Build with:

```sh
zig build -Dtarget=wasm32-freestanding
```

Threaded builds need a cross-origin isolated page:

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Set `.web_threads = false` for a non-shared build. See `examples` for complete
desktop and embedding programs, and the [web playground](https://shahwali.codeberg.page/knots/).
