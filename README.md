# Knots

Knots is a high performance cross-platform immediate-mode GUI library written in Zig.

## Requirements

- Zig compiler, minimum version can be found in [build.zig.zon](build.zig.zon). I try to keep up with the master branch.
- On Linux, Wayland development packages are required: wayland-client, wayland-cursor, wayland-protocols, wayland-scanner, pkg-config, and xkbcommon.

## Install

```sh
zig fetch --save git+https://codeberg.org/shahwali/knots.git
```

## Minimal app

```zig
// build.zig
const GPUBackend = @import("knots").GPUBackend;

const knots = b.dependency("knots", .{ .target = target, .optimize = optimize, .gpu_backend = GPUBackend.vulkan });


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

## Supported platforms:

| Platform            | Supported GPU APIs           |
| ------------------- | ---------------------------- |
| macOS               | WebGPU and Vulkan (MoltenVK) |
| Linux               | WebGPU and Vulkan            |
| Windows             | WebGPU and Vulkan            |
| WASM (freestanding) | WebGPU                       |

Browser WASM dispatch is cooperative and immediate-only. Work scheduled with `app.dispatch` runs on the main thread, so it must not block or rely on `std.Io.sleep` unless a future worker-backed runtime is added.

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

## Goals

Below goals are listed in order of importance.

1. Provide a way to build highly performant cross-platform desktop applications.
2. UI code should get out of the way, letting the developer spend more time on actual problems.
3. Minimal lean builds, fast compile times.
4. Highly configurable, with sane defaults.

## Known limitations

- Linux windowing is Wayland-only.
- Text rendering is UTF-8/codepoint based. HarfBuzz shaping, bidi layout, ligatures, font fallback, and IME composition are not implemented yet.
