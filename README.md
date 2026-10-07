# Knots

Knots is a cross-platform immediate-mode GUI library for Zig. You write the
interface as Zig code, and the same code runs on macOS, Windows, Linux, and in
the browser.

The UI engine does not depend on a window system or a graphics API. `App` is the
bundled window and renderer. `ui.Context` and `render.Packet` let you embed
Knots in your own window or renderer.

- [Documentation](https://knotsui.com/docs/)
- [Tutorial: build a todo app](https://knotsui.com/docs/tutorial.html)
- [Web playground](https://playground.knotsui.com/)

## Supported platforms

| Platform            | Default backend | Other backends    |
| ------------------- | --------------- | ----------------- |
| macOS               | WebGPU          | Vulkan (MoltenVK) |
| Linux (Wayland)     | Vulkan          | WebGPU            |
| Windows             | Vulkan          | WebGPU            |
| WASM (freestanding) | WebGPU          | —                 |

Select a backend with the `gpu_backend` dependency option. Read
[GPU backends](https://knotsui.com/docs/gpu-backends.html).

## Known limitations

- Linux windows use Wayland only. There is no X11 support.
- Text uses one glyph for each Unicode codepoint. There is no complex shaping,
  bidirectional text, ligatures, kerning, font fallback, or IME composition.
- Accessibility (AccessKit) is available on macOS, Windows, and Linux. It is
  not available in the browser.

## Requirements

- Zig. The minimum version is in [build.zig.zon](build.zig.zon). Knots follows
  the Zig master branch.
- On Linux: the Wayland development packages `wayland-client`,
  `wayland-cursor`, `wayland-protocols`, `wayland-scanner`, `pkg-config`, and
  `xkbcommon`.
- For the Vulkan backend: a Vulkan 1.3 driver with dynamic rendering.
- For the browser: a browser with WebGPU.

## Dependencies

| Dependency | Used for | Linking |
| --- | --- | --- |
| [wgpu](https://codeberg.org/shahwali/wgpu-zig) | WebGPU backend (native) | Static, shared on Windows MSVC (ship `wgpu_native.dll`) |
| vulkan, vulkan_headers | Vulkan backend | Vulkan loader at runtime |
| accesskit (`lib/accesskit`) | Native accessibility | Static, patched so it links next to wgpu-native |
| zig_objc | macOS windowing | - |
| wayland | Linux windowing | System `libwayland` |
| TrueType | Text | - |
| js_bridge (`lib/js-bridge`) | Browser host | - |
| celer, watch, wasmtime | Hot reloading (dev only) | wasmtime shared |

## Install

```sh
zig fetch --save git+https://github.com/knots-ui/knots.git
```

## Minimal app

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

fn frame(_: *knots.View, context: *ui.Frame) !void {
    const size = context.input().logical_extent;
    try context.e(.{
        ui.component.Rect{ .key = .src(@src()), .style = &.{
            .width = .fixed(@floatFromInt(size.width)),
            .height = .fixed(@floatFromInt(size.height)),
            .padding = .all(16),
            .background = .bg,
        } },
        .{
            ui.component.Text{ .key = .src(@src()), .content = "Hello from Knots" },
        },
    });
}
```

`View` contains the owning `app`, the viewport `id`, and a snapshot of the
renderer status. To get your own state, put `knots.App` in a field of your
struct and use `@fieldParentPtr("app", view.app)`. Keep the `App` at one
address until `start` returns.

## Hot reloading

`zig build dev` rebuilds your app to WebAssembly on every save and swaps it in
while it runs. Widget state carries over; build errors and crashes show over
the app.

```zig
const dev = Knots.HMR.init(b, .{ .target = target });
const exe = buildApp(b, dev.knots, dev.target);
dev.addRunner(exe, b.step("dev", "Run with HMR"));
```

Native apps run in a dev host that keeps their windows open. Browser apps
reload the page. See [Hot reloading](https://knotsui.com/docs/hot-reloading.html)
and the [playground](examples/playground).

## Embedding in an existing renderer

Import `ui`, `input`, and `render`. Add `renderer` when you use the bundled GPU
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

var submission = try gpu_frame.begin();
const prepared = try painter.prepare(&output.packet, &.{
    .width = target_width,
    .height = target_height,
    .content_scale = host_input.content_scale,
    .upload_slot = submission.upload_slot,
    .frame_context = submission,
    .linear_target = false,
});
try painter.encode(&prepared, &host_pass);
```

Use `Renderer.render` when Knots owns the surface. Use `Painter.prepare` and
`Painter.encode` when the host owns render passes, submission, or presentation.
`render.Packet` does not depend on a graphics API, but its geometry, glyph,
clip, and shader conventions are the Knots protocol. A renderer for another API
reads the packet directly. `Painter` uses the bundled backend types. See
[examples/embedded](examples/embedded) and
[Embedding](https://knotsui.com/docs/embedding.html).

## Ownership and lifetime

- Packet data, input slices, image bytes, and callback data are borrowed. Use
  them before the next frame, or copy them for async work.
- The host must keep textures and callback resources alive until the GPU
  completes the work.
- Complete the previous work for an upload slot before you use it again in
  `Painter.prepare`. Call `Painter.destroyAfterWait` only after all GPU work is
  complete.
- `Frame.deinit` aborts a frame that did not end. It is safe on copied handles.
- Apply cursor and clipboard effects one time. The host decides when to redraw
  or close a window.
- Custom backends must validate packet extensions and reject unsupported
  commands.

The bundled renderer synchronizes glyph atlas uploads and releases replaced
resources by upload slot. Its cache and packet data are bounded. You do not need
to acknowledge glyph uploads.

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

A browser build exports a start function instead of `main`. Read
[Compile & distribute](https://knotsui.com/docs/distribution.html) for the
entry point and the HTML page.

Threaded builds need a cross-origin isolated page:

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Set `.web_threads = false` for a build without shared memory.

## Examples

- [examples/playground](examples/playground): a component catalog, with hot reloading.
- [examples/embedded](examples/embedded): a host that owns its render passes.
- [examples/triangle](examples/triangle): drawing with the `Canvas` component.
- [examples/benchmark](examples/benchmark): a stress test with Tracy zones.
