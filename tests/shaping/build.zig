//! The shaping test harness, a package of its own so HarfBuzz and the test data never reach
//! knots' build. Run from this directory: `zig build fetch`, then `zig build test`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const text = b.dependency("knots", .{ .target = target, .optimize = optimize }).module("text");
    // The harness reads and writes paths relative to the repository root.
    const root = b.path("../..");

    const tool = b.addExecutable(.{
        .name = "shaping-tool",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tool.zig"),
            .imports = &.{.{ .name = "text", .module = text }},
        }),
    });
    const fetch = b.addRunArtifact(tool);
    fetch.addArg("fetch");
    fetch.addDirectoryArg(root);
    fetch.has_side_effects = true;
    b.step("fetch", "Download the shaping font corpus and Unicode data").dependOn(&fetch.step);
    const digests = b.addRunArtifact(tool);
    digests.addArg("digests");
    digests.addDirectoryArg(root);
    digests.has_side_effects = true;
    b.step("digests", "Record cmap, advance and outline digests of the shaping fonts").dependOn(&digests.step);

    const gen_unicode = b.addExecutable(.{
        .name = "gen-unicode",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSafe,
            .root_source_file = b.path("gen_unicode.zig"),
        }),
    });
    const tables = b.path("../../src/text/unicode/tables.zig");
    const run_gen_unicode = b.addRunArtifact(gen_unicode);
    run_gen_unicode.addDirectoryArg(b.path("../../.cache/shaping/ucd"));
    run_gen_unicode.addFileArg(tables);
    run_gen_unicode.has_side_effects = true;
    const fmt_tables = b.addFmt(.{ .paths = &.{tables} });
    fmt_tables.step.dependOn(&run_gen_unicode.step);
    b.step("unicode-tables", "Regenerate src/text/unicode/tables.zig from the fetched UCD").dependOn(&fmt_tables.step);

    // HarfBuzz is not under test, so it is always optimized and built without sanitizers.
    const harfbuzz_dep = b.dependency("harfbuzz", .{});
    const harfbuzz = b.addLibrary(.{
        .name = "harfbuzz",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libcpp = true,
        }),
    });
    harfbuzz.root_module.addCSourceFile(.{
        .file = harfbuzz_dep.path("src/harfbuzz.cc"),
        .flags = &.{ "-std=c++11", "-fno-exceptions", "-fno-rtti", "-fno-threadsafe-statics" },
    });

    const runner = b.addExecutable(.{
        .name = "shaping-runner",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("runner.zig"),
            .imports = &.{.{ .name = "text", .module = text }},
        }),
    });
    runner.root_module.linkLibrary(harfbuzz);
    const run_runner = b.addRunArtifact(runner);
    run_runner.addDirectoryArg(root);
    run_runner.has_side_effects = true;

    const manifest_tests = b.addTest(.{ .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("manifest.zig"),
    }) });
    const test_step = b.step("test", "Compare the shaper against HarfBuzz");
    test_step.dependOn(&run_runner.step);
    test_step.dependOn(&b.addRunArtifact(manifest_tests).step);

    const bench = b.addExecutable(.{
        .name = "bench-text",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("bench.zig"),
            .imports = &.{.{ .name = "text", .module = text }},
        }),
    });
    bench.root_module.linkLibrary(harfbuzz);
    const run_bench = b.addRunArtifact(bench);
    run_bench.addDirectoryArg(root);
    run_bench.has_side_effects = true;
    b.step("bench", "Run the text benchmarks (use -Doptimize=ReleaseFast)").dependOn(&run_bench.step);
}
