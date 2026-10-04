const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = b.dependency("release", .{});

    const translated = b.addTranslateC(.{
        .root_source_file = if (target.result.os.tag == .windows) b.addWriteFiles().add("accesskit_windows.h",
            \\#include <stdint.h>
            \\#define _WINDOWS_
            \\typedef struct HWND__ *HWND;
            \\typedef uintptr_t WPARAM;
            \\typedef intptr_t LPARAM;
            \\typedef intptr_t LRESULT;
            \\#include "accesskit.h"
            \\
        ) else release.path("include/accesskit.h"),
        .target = if (target.result.os.tag == .windows and target.result.abi == .msvc) b.resolveTargetQuery(.{
            .cpu_arch = target.result.cpu.arch,
            .os_tag = .windows,
            .abi = .gnu,
        }) else target,
        .optimize = optimize,
        .link_libc = true,
    });
    translated.addIncludePath(release.path("include"));

    const module = b.addModule("accesskit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = b.createModule(.{
            .root_source_file = translated.getOutput(),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) }},
    });

    const archive: std.Build.LazyPath, const archive_name: []const u8 = switch (target.result.os.tag) {
        .linux => blk: {
            if (target.result.abi != .gnu) @panic("AccessKit Linux archive requires the GNU ABI");
            if (target.result.cpu.arch != .x86_64) @panic("Unsupported AccessKit Linux architecture");
            module.linkSystemLibrary("dl", .{});
            module.linkSystemLibrary("pthread", .{});
            module.linkSystemLibrary("gcc_s", .{});
            break :blk .{ release.path("lib/linux/x86_64/static/libaccesskit.a"), "libaccesskit.a" };
        },
        .macos => blk: {
            module.linkFramework("AppKit", .{});
            module.linkFramework("Foundation", .{});
            module.linkFramework("ApplicationServices", .{});
            const path = switch (target.result.cpu.arch) {
                .aarch64 => "lib/macos/arm64/static/libaccesskit.a",
                .x86_64 => "lib/macos/x86_64/static/libaccesskit.a",
                else => @panic("Unsupported AccessKit macOS architecture"),
            };
            break :blk .{ release.path(path), "libaccesskit.a" };
        },
        .windows => blk: {
            for ([_][]const u8{ "ole32", "oleaut32", "user32", "advapi32", "shell32", "ntdll", "bcrypt" }) |name|
                module.linkSystemLibrary(name, .{});
            switch (target.result.abi) {
                .gnu => {
                    if (target.result.cpu.arch != .x86_64) @panic("Unsupported AccessKit Windows GNU architecture");
                    module.link_libcpp = true;
                    break :blk .{ release.path("lib/windows/x86_64/mingw/static/libaccesskit.a"), "libaccesskit.a" };
                },
                .msvc => {
                    const path = switch (target.result.cpu.arch) {
                        .x86_64 => "lib/windows/x86_64/msvc/static/accesskit.lib",
                        .aarch64 => "lib/windows/arm64/msvc/static/accesskit.lib",
                        else => @panic("Unsupported AccessKit Windows MSVC architecture"),
                    };
                    break :blk .{ release.path(path), "accesskit.lib" };
                },
                else => @panic("Unsupported AccessKit Windows ABI"),
            }
        },
        else => @panic("Unsupported AccessKit operating system"),
    };

    // The archive bundles Rust's runtime, which collides with Zig's compiler_rt and other Rust
    // static libraries (e.g. wgpu-native). See patch_archive.zig.
    const patch_archive = b.addExecutable(.{
        .name = "patch_archive",
        .root_module = b.createModule(.{
            .root_source_file = b.path("patch_archive.zig"),
            .target = b.graph.host,
        }),
    });
    const members = b.addSystemCommand(&.{ b.graph.zig_exe, "ar", "t" });
    members.addFileArg(archive);
    const patch = b.addRunArtifact(patch_archive);
    patch.addArg(b.graph.zig_exe);
    patch.addFileArg(archive);
    patch.addFileArg(members.captureStdOut(.{}));
    module.addObjectFile(patch.addOutputFileArg(archive_name));
    _ = patch.addOutputFileArg("compiler_builtins.rsp");

    const tests = b.addTest(.{ .root_module = module });
    b.step("check", "Compile AccessKit bindings").dependOn(&tests.step);

    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Test AccessKit bindings").dependOn(&run_tests.step);
}
