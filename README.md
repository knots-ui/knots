# Knots

Knots is a high performance cross-platform immediate-mode GUI library written in Zig.

## Requirements

- Zig 0.16.0 and newer.
- If using the Vulkan backend, glslc must be installed and accessible on the system. This is due to the shaders used in the Vulkan backend being compiled as part of building knots.
- On Linux, Wayland development packages are required: wayland-client, wayland-cursor, wayland-protocols, wayland-scanner, pkg-config, and xkbcommon.

## Install

```sh
zig fetch --save git+https://codeberg.org/shahwali/knots.git
```

## Minimal app

```zig
// build.zig
const GPUBackend = @import("knots").GPUBackend;

const knots = b.dependency("knots", .{ .target = target, .optimize = optimize, .gpu_backends = &[_]GPUBackend{ .vulkan, .wgpu } });


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
    const size = app.window.getSize();
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

| Platform         | Supported GPU APIs           |
| ---------------- | ---------------------------- |
| macOS            | WebGPU and Vulkan (MoltenVK) |
| Linux            | WebGPU and Vulkan            |
| Windows          | WebGPU and Vulkan            |
| Web (emscripten) | WebGPU                       |

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
- In general, text rendering is in very early stages.
