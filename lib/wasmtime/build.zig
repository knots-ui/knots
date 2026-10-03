const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const package_name: []const u8 = switch (target.result.os.tag) {
        .macos => switch (target.result.cpu.arch) {
            .aarch64 => "wasmtime_macos_aarch64",
            else => @panic("Unsupported Wasmtime architecture"),
        },
        .linux => switch (target.result.cpu.arch) {
            .x86_64 => "wasmtime_linux_x86_64",
            else => @panic("Unsupported Wasmtime architecture"),
        },
        .windows => switch (target.result.cpu.arch) {
            .x86_64 => "wasmtime_windows_x86_64",
            else => @panic("Unsupported Wasmtime architecture"),
        },
        else => @panic("Unsupported Wasmtime platform"),
    };
    const wasmtime_dep = b.dependency(package_name, .{});


    // translate-c fails on the MSVC headers; the GNU ABI headers produce the same
    // declarations on Windows, and the module still links against the MSVC archive.
    const translate_target = if (target.result.os.tag == .windows and target.result.abi == .msvc)
        b.resolveTargetQuery(.{ .cpu_arch = target.result.cpu.arch, .os_tag = .windows, .abi = .gnu })
    else
        target;
    const translated = b.addTranslateC(.{
        .target = translate_target,
        .optimize = optimize,
        .root_source_file = wasmtime_dep.path("include/wasmtime.h"),
        .link_libc = true,
    });

    translated.addIncludePath(wasmtime_dep.path("include"));
    const mod = b.addModule("wasmtime", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = translated.createModule() },
        },
    });

    switch (target.result.os.tag) {
        .windows => {
            translated.defineCMacro("WASM_API_EXTERN", "");
            translated.defineCMacro("WASI_API_EXTERN", "");
            mod.addObjectFile(wasmtime_dep.path("lib/wasmtime.lib"));

            for ([_][]const u8{ "ws2_32", "advapi32", "userenv", "ntdll", "shell32", "ole32", "bcrypt" }) |library| mod.linkSystemLibrary(library, .{});
        },
        .macos, .linux => {
            // Avoid duplicate Rust runtime symbols when also linking wgpu-native.
            mod.addLibraryPath(wasmtime_dep.path("lib"));
            mod.addRPath(wasmtime_dep.path("lib"));
            mod.linkSystemLibrary("wasmtime", .{ .preferred_link_mode = .dynamic });
        },
        else => unreachable,
    }

    const tests = b.addTest(.{ .root_module = mod });
    b.step("check", "Compile and link tests without executing them").dependOn(&tests.step);
    b.step("test", "Test Wasmtime bindings").dependOn(&b.addRunArtifact(tests).step);
}
