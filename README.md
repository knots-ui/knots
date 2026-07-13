# Knots

Knots is a high performance cross-platform immediate-mode GUI library written in Zig.

## Goals

Below goals are listed in order of importance.

1. Provide a way to build highly performant cross-platform desktop applications.
2. UI code should get out of the way, letting the developer spend more time on actual problems.
3. Minimal lean builds, fast compile times.
4. Highly configurable, with sane defaults.

## Known limitations

- Linux windowing is Wayland-only.
- Text rendering is UTF-8/codepoint based. HarfBuzz shaping, bidi layout, ligatures, font fallback, and IME composition are not implemented yet.

## Requirements

- Zig compiler, minimum version can be found in [build.zig.zon](build.zig.zon). I try to keep up with the master branch.
- On Linux, Wayland development packages are required: wayland-client, wayland-cursor, wayland-protocols, wayland-scanner, pkg-config, and xkbcommon.

## Supported platforms

| Platform            | Supported GPU APIs           |
| ------------------- | ---------------------------- |
| macOS               | WebGPU and Vulkan (MoltenVK) |
| Linux               | WebGPU and Vulkan            |
| Windows             | WebGPU and Vulkan            |
| WASM (freestanding) | WebGPU                       |

## Install

```sh
zig fetch --save git+https://codeberg.org/shahwali/knots.git
```

## Minimal app

```zig
// build.zig
const knots = b.dependency("knots", .{ .target = target, .optimize = optimize });

exe.root_module.addImport(knots.module("knots"));
// or
mod.addImport(knots.module("knots"));
```

```zig
const std = @import("std");
const knots = @import("knots");

pub fn main(init: std.process.Init) !void {
    var app = try knots.App.init(init.io, init.gpa, .{
        .window = .{
            .width = 1280,
            .height = 720,
            .title = "Playground",
        },
    });
    defer app.deinit();

    try app.start(frameCb);
}

fn frameCb(app: *knots.App) !void {
    const size = app.viewport.window.getSize();
    return app.e(.{
        knots.component.Rect{
            .width = .fixed(@floatFromInt(size.width)),
            .height = .fixed(@floatFromInt(size.height)),
            .padding = .init(16, 16, 16, 16),
            .dir = .column,
            .key = .src(@src()),
        },
    });
}
```

## Browser WASM

The following is a complete web-only application.

```zig
// build.zig
const std = @import("std");
const Knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const knots = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .web_threads = true,
    });
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "knots", .module = knots.module("knots") }},
    });
    const exe = b.addExecutable(.{ .name = "app", .root_module = exe_mod });
    exe.entry = .disabled;

    Knots.installWeb(b, knots, exe_mod, exe, .{
        .index_html = b.path("src/index.html"),
    });
}
```

```zig
// src/main.zig
const std = @import("std");
const knots = @import("knots");

pub const std_options: std.Options = .{ .logFn = knots.web.logFn };

fn frame(app: *knots.App) !void {
    const size = app.viewport.window.getSize();
    try app.e(.{
        knots.component.Rect{
            .width = .fixed(@floatFromInt(size.width)),
            .height = .fixed(@floatFromInt(size.height)),
            .padding = .init(16, 16, 16, 16),
            .key = .src(@src()),
        },
        .{
            knots.component.Text{
                .content = "Hello from Knots",
                .key = .src(@src()),
            },
        },
    });
}

export fn main() callconv(.{ .wasm_mvp = .{} }) i32 {
    const allocator = knots.web.allocator; // synchronizes Zig's single-threaded WASM allocator across workers.
    const io = knots.web.io; // provides worker dispatch, atomic waits, cancellation, clocks, randomness, and non-UI-blocking sleep.
    const app = allocator.create(knots.App) catch |err| return knots.web.fail(err);
    app.* = knots.App.init(io, allocator, .{
        .window = .{
            .width = 1280,
            .height = 720,
            .title = "Knots Web App",
            .canvas_selector = "#canvas",
        },
    }) catch |err| {
        allocator.destroy(app);
        return knots.web.fail(err);
    };
    app.start(frame) catch |err| {
        app.deinit();
        allocator.destroy(app);
        return knots.web.fail(err);
    };
    return 0;
}
```

```html
<!-- src/index.html -->
<!doctype html>
<html>
  <body>
    <canvas id="canvas"></canvas>
    <script type="module">
      import { startKnots } from "./knots.js";
      startKnots({ wasmUrl: "./app.wasm", canvas: "#canvas" }).catch(
        console.error,
      );
    </script>
  </body>
</html>
```

```sh
zig build -Dtarget=wasm32-freestanding
```

Web threads remain enabled by default when `web_threads` is omitted. Threaded builds configure shared memory and install the WASM and worker files. They must be served over HTTP with:

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

These headers isolate the page so browsers can safely expose `SharedArrayBuffer`, which shared WebAssembly memory requires. Cross-origin resources must allow CORS or embedding via `Cross-Origin-Resource-Policy`.

`wasm64-freestanding` also works in browsers with memory64 support. With `.web_threads = false`, `installWeb` emits an ordinary, non-shared WebAssembly module and does not install worker files. It can be served by a normal static server:

```sh
python3 -m http.server 8000 --directory zig-out/web
```

### Distributing Vulkan applications on macOS

Knots checks for a bundled Vulkan loader before falling back to the system loader. A standalone application bundle using the Vulkan backend must include the loader, MoltenVK, and its ICD manifest:

```text
MyApp.app/Contents/Frameworks/libvulkan.1.dylib
MyApp.app/Contents/Frameworks/libMoltenVK.dylib
MyApp.app/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json
```

The manifest's `library_path` must resolve to the bundled `libMoltenVK.dylib`.

## Examples

See [examples](examples), you can also try the web version of the playground [here](https://shahwali.codeberg.page/knots/).
