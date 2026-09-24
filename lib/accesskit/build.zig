const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = b.dependency("release", .{});
    const prefix = "";
    if (target.result.os.tag == .windows and target.result.abi != .msvc) @panic("AccessKit Windows archive requires the MSVC ABI");
    if (target.result.os.tag == .linux and target.result.abi != .gnu) @panic("AccessKit Linux archive requires the GNU ABI");
    const static_library = switch (target.result.os.tag) {
        .linux => switch (target.result.cpu.arch) {
            .x86_64 => prefix ++ "lib/linux/x86_64/static/libaccesskit.a",
            else => @panic("Unsupported AccessKit Linux architecture"),
        },
        .macos => switch (target.result.cpu.arch) {
            .aarch64 => prefix ++ "lib/macos/arm64/static/libaccesskit.a",
            .x86_64 => prefix ++ "lib/macos/x86_64/static/libaccesskit.a",
            else => @panic("Unsupported AccessKit macOS architecture"),
        },
        .windows => switch (target.result.cpu.arch) {
            .x86_64 => prefix ++ "lib/windows/x86_64/msvc/static/accesskit.lib",
            .aarch64 => prefix ++ "lib/windows/arm64/msvc/static/accesskit.lib",
            else => @panic("Unsupported AccessKit Windows architecture"),
        },
        else => @panic("Unsupported AccessKit operating system"),
    };
    const translated = b.addTranslateC(.{
        .root_source_file = release.path(prefix ++ "include/accesskit.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const module = b.addModule("accesskit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = translated.createModule() }},
    });
    switch (target.result.os.tag) {
        .linux => {
            module.addObjectFile(release.path(static_library));
            module.linkSystemLibrary("dl", .{});
            module.linkSystemLibrary("pthread", .{});
            module.linkSystemLibrary("gcc_s", .{});
        },
        .macos => {
            // Both AccessKit and wgpu-native are Rust libraries. Linking their
            // static archives into the same executable duplicates Rust runtime
            // symbols such as rust_eh_personality. Keep AccessKit in its shared
            // library so its runtime remains in a separate linkage unit.
            const shared_library = switch (target.result.cpu.arch) {
                .aarch64 => "lib/macos/arm64/shared",
                .x86_64 => "lib/macos/x86_64/shared",
                else => unreachable,
            };
            module.addLibraryPath(release.path(shared_library));
            module.addRPath(release.path(shared_library));
            module.linkSystemLibrary("accesskit", .{ .preferred_link_mode = .dynamic });
            module.linkFramework("AppKit", .{});
            module.linkFramework("Foundation", .{});
            module.linkFramework("ApplicationServices", .{});
        },
        .windows => {
            module.addObjectFile(release.path(static_library));
            for ([_][]const u8{ "ole32", "oleaut32", "user32", "advapi32", "shell32", "ntdll", "bcrypt" }) |name|
                module.linkSystemLibrary(name, .{});
        },
        else => unreachable,
    }
    const tests = b.addTest(.{ .root_module = module });
    b.step("check", "Compile AccessKit bindings").dependOn(&tests.step);
    b.step("test", "Test AccessKit bindings").dependOn(&b.addRunArtifact(tests).step);
}
