# AccessKit for Zig

- Linux and Windows GNU link the static archive, GNU links libc++ for libunwind.
- macOS and Windows MSVC link the shared library to avoid duplicate Rust runtime symbols. Ship `accesskit.dll` beside the executable, its directory is the `dll_dir` named lazy path. MSVC cross-compiles need `--libc` (e.g. `xwin`).
- Windows translates a wrapper defining the four handle types instead of `windows.h`, against mingw headers since translate-c ignores `--libc`.
