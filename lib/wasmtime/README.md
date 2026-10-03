# Wasmtime for Zig

Bindings for Wasmtime 48.0.2. Import the dependency's `wasmtime` module:

```zig
const wasmtime = b.dependency("wasmtime", .{ .target = target, .optimize = optimize });
executable.root_module.addImport("wasmtime", wasmtime.module("wasmtime"));
```

The package handles C header translation and native linking. Supported targets
are macOS ARM64, Linux x86-64 and Windows x86-64. macOS and Linux use the pinned
shared library and its package directory as an rpath to coexist with wgpu-native;
distributing that executable requires distributing the shared library and
configuring its search path. Windows MSVC links `wasmtime.dll`, which must ship
beside the executable, its directory is the `dll_dir` named lazy path.
Cross-compiling for MSVC requires the MSVC runtime and SDK passed with `--libc`.

`Engine`, `Module` and `Store` own their resources and require `deinit`.
Destroy stores and modules before the engine. Treat these as single-owner values;
assigning them does not clone ownership. `Instance`, `Function` and `Memory`
borrow their store and must not outlive it. Store access must be serialized.

```zig
var engine = try wasmtime.Engine.init(.{ .consume_fuel = true });
defer engine.deinit();
var module = try wasmtime.Module.init(engine, wasm_bytes, null);
defer module.deinit();
var store = try wasmtime.Store.init(engine, &.{
    .memory_bytes = 16 * 1024 * 1024,
    .table_elements = 1000,
    .instances = 1,
    .tables = 1,
    .memories = 1,
});
defer store.deinit();
try store.setFuel(100_000, null);
const instance = try wasmtime.Instance.init(&store, &module, &.{}, null);
const start = try instance.function("start");
try start.call(&.{}, &.{}, null); // Expects a function with no arguments or results.
```

Calls accept slices of `Value` (the C tagged value type), validate signatures,
and return `error.Trap` separately from `error.WasmtimeFailure`. Successful
results are caller-owned: call `unrootValues` before reusing their storage.
Reference arguments and imports must belong to the instance's store.

Pass an initialized `Diagnostics` pointer instead of `null` to retain the native
error or trap. Its `message(allocator)` returns caller-owned text. Subsequent
operations replace the diagnostic; call `deinit` when finished. The bindings
do not log or choose an application error policy.

`Memory.range` checks bounds and integer overflow. Its slice is borrowed;
reacquire it after guest calls because memory growth can relocate the backing
allocation. `wat2wasm` returns an allocator-owned binary. The complete C API is
available through `wasmtime.c`, including linker, WASI and component APIs;
those APIs retain their C ownership and safety contracts.

Knots uses this package internally for desktop HMR. Knots app consumers do not
need to import it or manage these resources.

Run `zig build test` here. `zig build check -Dtarget=...` compiles and links the
tests without running them.
