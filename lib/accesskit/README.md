# AccessKit for Zig

- Links the static archive on every target, GNU links libc++ for libunwind. The archive bundles Rust's runtime, so the build patches a copy of it (`patch_archive.zig`): it drops Rust's `compiler_builtins`, which Zig's compiler_rt provides and collides with on MSVC, and renames `rust_eh_personality`, which other Rust static libraries (e.g. wgpu-native) also define.
- Windows translates a wrapper defining the four handle types instead of `windows.h`, against mingw headers since translate-c ignores `--libc`.
