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

    const dll_dir: ?std.Build.LazyPath = switch (target.result.os.tag) {
        .linux => blk: {
            if (target.result.abi != .gnu) @panic("AccessKit Linux archive requires the GNU ABI");
            if (target.result.cpu.arch != .x86_64) @panic("Unsupported AccessKit Linux architecture");
            module.addObjectFile(release.path("lib/linux/x86_64/static/libaccesskit.a"));
            module.linkSystemLibrary("dl", .{});
            module.linkSystemLibrary("pthread", .{});
            module.linkSystemLibrary("gcc_s", .{});
            break :blk null;
        },
        .macos => blk: {
            const shared_library = release.path(switch (target.result.cpu.arch) {
                .aarch64 => "lib/macos/arm64/shared",
                .x86_64 => "lib/macos/x86_64/shared",
                else => @panic("Unsupported AccessKit macOS architecture"),
            });
            module.addLibraryPath(shared_library);
            module.addRPath(shared_library);
            module.linkSystemLibrary("accesskit", .{ .preferred_link_mode = .dynamic });
            module.linkFramework("AppKit", .{});
            module.linkFramework("Foundation", .{});
            module.linkFramework("ApplicationServices", .{});
            break :blk null;
        },
        .windows => blk: {
            for ([_][]const u8{ "ole32", "oleaut32", "user32", "advapi32", "shell32", "ntdll", "bcrypt" }) |name|
                module.linkSystemLibrary(name, .{});
            switch (target.result.abi) {
                .gnu => {
                    if (target.result.cpu.arch != .x86_64) @panic("Unsupported AccessKit Windows GNU architecture");
                    module.addObjectFile(release.path("lib/windows/x86_64/mingw/static/libaccesskit.a"));
                    module.link_libcpp = true;
                    break :blk null;
                },
                .msvc => {
                    const shared_library = release.path(switch (target.result.cpu.arch) {
                        .x86_64 => "lib/windows/x86_64/msvc/shared",
                        .aarch64 => "lib/windows/arm64/msvc/shared",
                        else => @panic("Unsupported AccessKit Windows MSVC architecture"),
                    });
                    module.addObjectFile(shared_library.path(b, "accesskit.lib"));
                    break :blk shared_library;
                },
                else => @panic("Unsupported AccessKit Windows ABI"),
            }
        },
        else => @panic("Unsupported AccessKit operating system"),
    };

    const tests = b.addTest(.{ .root_module = module });
    b.step("check", "Compile AccessKit bindings").dependOn(&tests.step);

    const run_tests = b.addRunArtifact(tests);

    if (dll_dir) |dir| {
        b.addNamedLazyPath("dll_dir", dir);
        run_tests.setCwd(dir);
    }
    b.step("test", "Test AccessKit bindings").dependOn(&run_tests.step);
}
