import { createBridgeImports } from "./js-bridge.js";
import { createWasiImports } from "./knots-wasi.js";

const WASM_MEMORY_INITIAL_PAGES = 256;
const WASM_MEMORY_MAX_PAGES = 32768;
const browserHmrDefault = new URL(import.meta.url).searchParams.has("knots-hmr") ? {} : undefined;
const textDecoder = new TextDecoder("utf-8");
const textEncoder = new TextEncoder();

function isCanvas(value) {
  return typeof HTMLCanvasElement !== "undefined" && value instanceof HTMLCanvasElement;
}

function requireCanvas(value) {
  if (!isCanvas(value))
    throw new Error("Knots canvas resolver did not return an HTMLCanvasElement");
  return value;
}

function resolveCanvasOption(canvas, selector) {
  if (isCanvas(canvas)) return canvas;
  if (typeof canvas === "function") return requireCanvas(canvas(selector));
  if (typeof canvas === "string") return requireCanvas(document.querySelector(selector || canvas));
  throw new Error("Knots requires a canvas element, selector string, or resolver function");
}

const keyCodes = new Map(
  Object.entries({
    Space: 32,
    Quote: 39,
    Comma: 44,
    Minus: 45,
    Period: 46,
    Slash: 47,
    Digit0: 48,
    Digit1: 49,
    Digit2: 50,
    Digit3: 51,
    Digit4: 52,
    Digit5: 53,
    Digit6: 54,
    Digit7: 55,
    Digit8: 56,
    Digit9: 57,
    Semicolon: 59,
    Equal: 61,
    KeyA: 65,
    KeyB: 66,
    KeyC: 67,
    KeyD: 68,
    KeyE: 69,
    KeyF: 70,
    KeyG: 71,
    KeyH: 72,
    KeyI: 73,
    KeyJ: 74,
    KeyK: 75,
    KeyL: 76,
    KeyM: 77,
    KeyN: 78,
    KeyO: 79,
    KeyP: 80,
    KeyQ: 81,
    KeyR: 82,
    KeyS: 83,
    KeyT: 84,
    KeyU: 85,
    KeyV: 86,
    KeyW: 87,
    KeyX: 88,
    KeyY: 89,
    KeyZ: 90,
    BracketLeft: 91,
    Backslash: 92,
    BracketRight: 93,
    Backquote: 96,
    IntlBackslash: 161,
    IntlRo: 162,
    Escape: 256,
    Enter: 257,
    Tab: 258,
    Backspace: 259,
    Insert: 260,
    Delete: 261,
    ArrowRight: 262,
    ArrowLeft: 263,
    ArrowDown: 264,
    ArrowUp: 265,
    PageUp: 266,
    PageDown: 267,
    Home: 268,
    End: 269,
    CapsLock: 280,
    ScrollLock: 281,
    NumLock: 282,
    PrintScreen: 283,
    Pause: 284,
    F1: 290,
    F2: 291,
    F3: 292,
    F4: 293,
    F5: 294,
    F6: 295,
    F7: 296,
    F8: 297,
    F9: 298,
    F10: 299,
    F11: 300,
    F12: 301,
    F13: 302,
    F14: 303,
    F15: 304,
    F16: 305,
    F17: 306,
    F18: 307,
    F19: 308,
    F20: 309,
    F21: 310,
    F22: 311,
    F23: 312,
    F24: 313,
    F25: 314,
    Numpad0: 320,
    Numpad1: 321,
    Numpad2: 322,
    Numpad3: 323,
    Numpad4: 324,
    Numpad5: 325,
    Numpad6: 326,
    Numpad7: 327,
    Numpad8: 328,
    Numpad9: 329,
    NumpadDecimal: 330,
    NumpadDivide: 331,
    NumpadMultiply: 332,
    NumpadSubtract: 333,
    NumpadAdd: 334,
    NumpadEnter: 335,
    NumpadEqual: 336,
    ShiftLeft: 340,
    ControlLeft: 341,
    AltLeft: 342,
    MetaLeft: 343,
    ShiftRight: 344,
    ControlRight: 345,
    AltRight: 346,
    MetaRight: 347,
    OSLeft: 343,
    OSRight: 347,
    ContextMenu: 348,
  }),
);

const keyDefaults = new Set([32, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269]);

// Loads HMR modules for the browser host and runs them on behalf of
// src/hmr/Browser.zig, which refers to them by handle.
class BrowserHmr {
  constructor(host, options) {
    options = typeof options === "object" ? options : {};
    this.host = host;
    this.manifestUrl = new URL(options.manifestUrl ?? "../hmr/manifest.json", import.meta.url);
    this.artifactBaseUrl = new URL(options.artifactBaseUrl ?? "../hmr/artifacts/", import.meta.url);
    this.eventsUrl = new URL(options.eventsUrl ?? "../hmr/events", import.meta.url);
    // Increments when the manifest or a loaded module changes. The runtime polls it.
    this.revision = 0;
    this.manifestText = "";
    this.manifestBytes = new Uint8Array();
    this.loaded = new Map(); // `${id}\0${hash}` -> module
    this.handles = new Map(); // handle -> module
    this.nextHandle = 1;
    this.refreshing = false;
    this.refreshPending = false;
  }

  // Resolves when the first manifest loads. The server sends a change event
  // on each connection, so a reconnect also refreshes.
  init() {
    return new Promise((resolve, reject) => {
      let ready = false;
      const events = new EventSource(this.eventsUrl);
      events.addEventListener("change", () => {
        this.refresh().then(
          () => {
            ready = true;
            resolve();
          },
          (error) => {
            if (!ready) reject(error);
            else this.host.log(2, `Knots HMR refresh failed: ${errorMessage(error)}`);
          },
        );
      });
      events.onerror = () => {
        if (!ready) reject(new Error(`Knots HMR event stream failed: ${this.eventsUrl}`));
      };
    });
  }

  // Change events during a refresh cause one more refresh, not one each.
  async refresh() {
    if (this.refreshing) {
      this.refreshPending = true;
      return;
    }
    this.refreshing = true;
    try {
      do {
        this.refreshPending = false;
        await this.refreshOnce();
      } while (this.refreshPending);
    } finally {
      this.refreshing = false;
    }
  }

  async refreshOnce() {
    const response = await fetch(this.manifestUrl, { cache: "no-store" });
    if (!response.ok) throw new Error(`Knots HMR manifest request failed (${response.status})`);
    const text = await response.text();
    const wanted = new Map(JSON.parse(text).modules.map((entry) => [`${entry.id}\0${entry.hash}`, entry]));
    const fresh = [...wanted].filter(([key]) => !this.loaded.has(key));
    await Promise.all(
      fresh.map(async ([key, entry]) => {
        try {
          this.loaded.set(key, await this.load(entry.hash));
        } catch (error) {
          this.host.log(2, `Knots HMR module rejected (${entry.id}): ${errorMessage(error)}`);
        }
      }),
    );
    for (const [key, module] of this.loaded) {
      if (wanted.has(key)) continue;
      this.loaded.delete(key);
      this.release(module);
    }
    if (text === this.manifestText && fresh.length === 0) return;
    this.manifestText = text;
    this.manifestBytes = textEncoder.encode(text);
    this.revision = (this.revision % 0xffffffff) + 1;
    this.host.requestFrame();
  }

  async load(hash) {
    const response = await fetch(new URL(`${hash}.wasm`, this.artifactBaseUrl));
    if (!response.ok) throw new Error(`Module request failed (${response.status})`);
    const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {});
    const exports = instance.exports;
    if (exports.knots_hmr_init() !== 0) throw new Error("Module initialization failed");
    const source = guestBytes(exports, exports.knots_hmr_source(), exports.knots_hmr_source_length());
    return { exports, source, output: new Uint8Array(), references: 1 };
  }

  open(id, hash) {
    const module = this.loaded.get(`${id}\0${hash}`);
    if (!module) return 0;
    const handle = this.nextHandle;
    this.nextHandle = (this.nextHandle % 0xffffffff) + 1;
    module.references += 1;
    this.handles.set(handle, module);
    return handle;
  }

  close(handle) {
    const module = this.handles.get(handle);
    if (!module) return;
    this.handles.delete(handle);
    this.release(module);
  }

  release(module) {
    module.references -= 1;
    if (module.references === 0) module.exports.knots_hmr_deinit();
  }

  module(handle) {
    const module = this.handles.get(handle);
    if (!module) throw new Error(`Invalid Knots HMR handle: ${handle}`);
    return module;
  }

  // Keeps the output until the runtime copies it.
  call(handle, name, input) {
    const module = this.module(handle);
    const exports = module.exports;
    if (input) {
      const offset = exports.knots_hmr_input(input.length) >>> 0;
      if (offset === 0) throw new Error("Module input allocation failed");
      new Uint8Array(exports.memory.buffer).set(input, offset);
    }
    if (exports[name]() !== 0) throw new Error(`Module call failed: ${name}`);
    module.output = guestBytes(exports, exports.knots_hmr_output(), exports.knots_hmr_output_length());
  }
}

function guestBytes(exports, offset, length) {
  offset >>>= 0;
  length >>>= 0;
  return new Uint8Array(exports.memory.buffer.slice(offset, offset + length));
}

class KnotsBrowserHost {
  constructor(options) {
    this.canvas = options.canvas;
    this.fullscreenElementOption = options.fullscreenElement ?? null;
    this.logTarget = options.log ?? console;
    this.onError = typeof options.onError === "function" ? options.onError : null;
    this.gpuAdapter = null;
    this.gpuDevice = null;
    this.gpuQueue = null;
    this.preferredFormat = "bgra8unorm";
    this.pendingFullscreenCanvas = null;
    this.mouseCaptures = new Map();
    this.serviceFullscreen = this.serviceFullscreen.bind(this);
    for (const event of ["pointerdown", "mousedown", "keydown", "touchstart"]) {
      document.addEventListener(event, this.serviceFullscreen, true);
    }
    this.workerPool = null;
    this.frameCallback = null;
    this.frameRequest = null;
    this.hmr = options.hmr ? new BrowserHmr(this, options.hmr) : null;
    this.ready = this.hmr ? Promise.all([this.initGpu(), this.hmr.init()]) : this.initGpu();
  }

  setWorkerPool(workerPool) {
    this.workerPool = workerPool;
  }

  spawnConcurrent(task, group, start, context) {
    return this.workerPool?.dispatch(task, group, start, context) ? 1 : 0;
  }

  forgetConcurrentGroup(group) {
    this.workerPool?.forgetGroup(group);
  }

  setFrameCallback(callback) {
    this.frameCallback = callback;
  }

  clearFrameCallback() {
    this.cancelFrame();
    this.frameCallback = null;
  }

  requestFrame() {
    if (!this.frameCallback || this.frameRequest !== null) return;
    this.frameRequest = requestAnimationFrame((timestamp) => {
      this.frameRequest = null;
      this.frameCallback?.(timestamp);
    });
  }

  cancelFrame() {
    if (this.frameRequest === null) return;
    cancelAnimationFrame(this.frameRequest);
    this.frameRequest = null;
  }

  async initGpu() {
    if (!navigator.gpu) throw new Error("WebGPU is not available in this browser");
    this.gpuAdapter = await navigator.gpu.requestAdapter();
    if (!this.gpuAdapter) throw new Error("WebGPU adapter unavailable");
    this.gpuDevice = await this.gpuAdapter.requestDevice();
    this.gpuQueue = this.gpuDevice.queue;
    this.preferredFormat = navigator.gpu.getPreferredCanvasFormat();
  }

  resolveCanvas(selector) {
    return resolveCanvasOption(this.canvas, selector);
  }

  canvasSize(canvas, fallbackW, fallbackH) {
    const rect = canvas.getBoundingClientRect();
    const cssW = rect.width > 0 ? rect.width : fallbackW;
    const cssH = rect.height > 0 ? rect.height : fallbackH;
    const dpr = globalThis.devicePixelRatio || 1;
    const logicalW = Math.round(cssW);
    const logicalH = Math.round(cssH);
    const physicalW = Math.round(cssW * dpr);
    const physicalH = Math.round(cssH * dpr);
    canvas.width = physicalW;
    canvas.height = physicalH;
    return { logicalW, logicalH, physicalW, physicalH, contentScale: dpr };
  }

  eventPos(canvas, event) {
    const rect = canvas.getBoundingClientRect();
    return { x: event.clientX - rect.left, y: event.clientY - rect.top };
  }

  modsOf(event) {
    return (
      (event.shiftKey ? 1 : 0) |
      (event.ctrlKey ? 2 : 0) |
      (event.altKey ? 4 : 0) |
      (event.metaKey ? 8 : 0)
    );
  }

  keyCode(code) {
    return keyCodes.get(code) ?? -1;
  }

  textCodepoint(event) {
    if (!event.key) return 0;
    const chars = Array.from(event.key);
    if (chars.length !== 1) return 0;
    if ((event.ctrlKey && !event.altKey) || event.metaKey) return 0;
    return chars[0].codePointAt(0) ?? 0;
  }

  shouldHandleEvent(event, catcher) {
    const target = event.target;
    if (!target || target === catcher) return 1;
    const element =
      typeof Element !== "undefined" && target instanceof Element ? target : target.parentElement;
    if (!element) return 1;
    const tag = element.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA") return 0;
    if (element.isContentEditable) return 0;
    return 1;
  }

  shouldPreventKeyDefault(event, key) {
    if (event.defaultPrevented) return 0;
    const command = (event.ctrlKey && !event.altKey) || event.metaKey;
    if (command) return key === 65 || key === 67 || key === 86 || key === 88 ? 1 : 0;
    if (event.ctrlKey || event.metaKey) return 0;
    if (event.altKey) return key >= 262 && key <= 265 ? 1 : 0;
    return keyDefaults.has(key) || (key >= 32 && key <= 162) ? 1 : 0;
  }

  createPasteCatcher() {
    const catcher = document.createElement("textarea");
    catcher.readOnly = true;
    catcher.ariaHidden = "true";
    Object.assign(catcher.style, {
      position: "fixed",
      left: "-10000px",
      top: "0",
      width: "1px",
      height: "1px",
      opacity: "0",
    });
    document.body.appendChild(catcher);
    return catcher;
  }

  preparePaste(catcher) {
    catcher.readOnly = false;
    catcher.value = "";
    catcher.focus();
    catcher.select();
    setTimeout(() => {
      catcher.readOnly = true;
      if (document.activeElement === catcher) catcher.blur();
    }, 1000);
  }

  copy(text) {
    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.readOnly = true;
    Object.assign(textarea.style, {
      position: "fixed",
      left: "-10000px",
      top: "0",
      width: "1px",
      height: "1px",
      opacity: "0",
    });
    document.body.appendChild(textarea);
    textarea.focus();
    textarea.select();

    let copied = false;
    try {
      copied = document.execCommand("copy");
    } catch {
      copied = false;
    }
    textarea.remove();
    return copied ? 1 : 0;
  }

  isFullscreen(canvas) {
    return document.fullscreenElement === this.fullscreenTarget(canvas);
  }

  requestFullscreen(canvas) {
    if (document.fullscreenElement === this.fullscreenTarget(canvas)) return 1;
    if (!canvas.requestFullscreen) return 0;
    this.pendingFullscreenCanvas = canvas;
    if (!navigator.userActivation || navigator.userActivation.isActive) this.serviceFullscreen();
    return 1;
  }

  /// The element that goes fullscreen for `canvas`: the canvas itself, or
  /// the `fullscreenElement` option when the page stacks other content
  /// (such as a second canvas) with it.
  fullscreenTarget(canvas) {
    const option = this.fullscreenElementOption;
    if (!option) return canvas;
    return (typeof option === "string" ? document.querySelector(option) : option) ?? canvas;
  }

  exitFullscreen() {
    this.pendingFullscreenCanvas = null;
    if (!document.fullscreenElement) return 1;
    const request = document.exitFullscreen?.();
    if (!request) return 0;
    request.catch((err) => this.fullscreenFailed("exit", err));
    return 1;
  }

  cancelFullscreen(canvas) {
    if (!canvas || this.pendingFullscreenCanvas === canvas) this.pendingFullscreenCanvas = null;
  }

  serviceFullscreen(event) {
    if (event && event.isTrusted === false) return;
    const canvas = this.pendingFullscreenCanvas;
    if (!canvas) return;
    this.pendingFullscreenCanvas = null;
    const request = this.fullscreenTarget(canvas).requestFullscreen?.();
    if (!request) {
      document.dispatchEvent(new Event("knotsfullscreenfailed"));
      return;
    }
    request.catch((err) => this.fullscreenFailed("request", err));
  }

  fullscreenFailed(action, err) {
    this.log(3, `Fullscreen ${action} failed: ${errorMessage(err)}`);
    document.dispatchEvent(new Event("knotsfullscreenfailed"));
  }

  beginMouseCapture(canvas, callback) {
    const existing = this.mouseCaptures.get(canvas);
    if (existing === callback) return;
    if (existing) document.removeEventListener("mousemove", existing, false);
    document.addEventListener("mousemove", callback, false);
    this.mouseCaptures.set(canvas, callback);
  }

  endMouseCapture(canvas, callback) {
    const existing = this.mouseCaptures.get(canvas);
    if (!existing || existing !== callback) return;
    document.removeEventListener("mousemove", existing, false);
    this.mouseCaptures.delete(canvas);
  }

  nowMs(clock) {
    return clock === 0 ? Date.now() : performance.now();
  }

  randomSecure(bytes) {
    if (!globalThis.crypto?.getRandomValues) throw new Error("Secure random is unavailable");
    const maxBytes = 65536;
    for (let offset = 0; offset < bytes.length; offset += maxBytes) {
      globalThis.crypto.getRandomValues(bytes.subarray(offset, offset + maxBytes));
    }
  }

  log(level, message) {
    const logger = this.logTarget;
    if (level >= 3) (logger.error ?? console.error).call(logger, message);
    else if (level === 2) (logger.warn ?? console.warn).call(logger, message);
    else (logger.log ?? console.log).call(logger, message);
  }

  fatalError(message) {
    const error = new Error(String(message));
    error.name = "KnotsFrameError";
    this.log(3, `${error.name}: ${error.message}`);
    if (!this.onError) return;
    try {
      this.onError(error);
    } catch (err) {
      this.log(3, `Knots onError callback failed: ${errorMessage(err)}`);
    }
  }
}

function createHmrImports(host, bridge) {
  const hmr = host.hmr;

  function manager() {
    if (!hmr) throw new Error("Knots browser HMR is not enabled");
    return hmr;
  }

  function mainBytes(pointer, length) {
    pointer = safeUsizeNumber(pointer, "HMR pointer");
    length = safeUsizeNumber(length, "HMR length");
    bridge.refreshMemory();
    const end = pointer + length;
    if (!Number.isSafeInteger(end) || end > bridge.bytes.length)
      throw new RangeError("Knots HMR byte range is outside main memory");
    return bridge.bytes.subarray(pointer, end);
  }

  function copyToMain(bytes, pointer, capacity) {
    const output = mainBytes(pointer, capacity);
    if (output.length !== bytes.length) return 0;
    output.set(bytes);
    return bytes.length;
  }

  function decode(pointer, length) {
    return textDecoder.decode(mainBytes(pointer, length));
  }

  // Returns 1 on success. On failure, logs the error and returns 0.
  function call(handle, name, input) {
    return guarded(0, () => {
      manager().call(handle, name, input);
      return 1;
    });
  }

  function guarded(fallback, operation) {
    try {
      return operation();
    } catch (error) {
      host.log(2, `Knots browser HMR operation failed: ${errorMessage(error)}`);
      return fallback;
    }
  }

  return {
    revision: () => guarded(0, () => manager().revision),
    manifestLength: () => guarded(0, () => manager().manifestBytes.length),
    manifestCopy: (pointer, capacity) =>
      guarded(0, () => copyToMain(manager().manifestBytes, pointer, capacity)),
    open: (idPointer, idLength, hashPointer, hashLength) =>
      guarded(0, () =>
        manager().open(decode(idPointer, idLength), decode(hashPointer, hashLength)),
      ),
    close: (handle) => guarded(undefined, () => manager().close(handle)),
    fingerprint: (handle) =>
      guarded(0, () => manager().module(handle).exports.knots_hmr_fingerprint() >>> 0),
    sourceLength: (handle) => guarded(0, () => manager().module(handle).source.length),
    sourceCopy: (handle, pointer, capacity) =>
      guarded(0, () => copyToMain(manager().module(handle).source, pointer, capacity)),
    frame: (handle, pointer, length) => call(handle, "knots_hmr_frame", mainBytes(pointer, length)),
    snapshot: (handle) => call(handle, "knots_hmr_snapshot"),
    restore: (handle, pointer, length) =>
      call(handle, "knots_hmr_restore", mainBytes(pointer, length)),
    outputLength: (handle) => guarded(0, () => manager().module(handle).output.length),
    outputCopy: (handle, pointer, capacity) =>
      guarded(0, () => copyToMain(manager().module(handle).output, pointer, capacity)),
  };
}

export function createKnotsImports(options) {
  const bridge = createBridgeImports();
  bridge.setExportSymbols({
    dispatch: options.symbols?.dispatch,
    pointerSize: options.symbols?.pointerSize,
  });
  const host = new KnotsBrowserHost(options);
  bridge.setHost(host);
  if (options.wasmExports) bridge.setWasmExports(options.wasmExports);
  let wasiMemory = null;
  let wasmExports = options.wasmExports ?? null;
  // Import modules of the application's own (for C code that calls into the
  // page). They run on the main thread only; workers get stubs.
  const extraImports =
    typeof options.imports === "function"
      ? options.imports(
          () => wasiMemory ?? bridge.memory,
          () => wasmExports,
        )
      : (options.imports ?? {});
  const imports = {
    ...extraImports,
    ...bridge.imports,
    knots_hmr: createHmrImports(host, bridge),
    wasi_snapshot_preview1: createWasiImports(
      () => wasiMemory ?? bridge.memory,
      options.log ?? console,
    ),
  };

  return {
    imports,
    ready: host.ready,
    bridge,
    host,
    setWasmExports(exports) {
      wasmExports = exports;
      bridge.setWasmExports(exports);
    },
    setMemory(memory) {
      wasiMemory = memory;
    },
  };
}

function errorMessage(err) {
  return err instanceof Error ? `${err.name}: ${err.message}` : String(err);
}

function safeUsizeNumber(value, name) {
  if (typeof value === "bigint") {
    if (value < 0n || value > BigInt(Number.MAX_SAFE_INTEGER))
      throw new RangeError(`${name} is outside the JS safe integer range`);
    return Number(value);
  }
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n < 0)
    throw new RangeError(`${name} is outside the JS safe integer range`);
  return n;
}

function pointerSizeOf(exports, symbols) {
  const fn = exports[symbols.pointerSize];
  if (typeof fn !== "function")
    throw new Error(`Knots wasm export not found: ${symbols.pointerSize}`);
  const size = Number(fn());
  if (size !== 4 && size !== 8) throw new Error(`Unsupported Knots wasm pointer size: ${size}`);
  return size;
}

function wasmUsizeArg(value, pointerSize, name) {
  const n = safeUsizeNumber(value, name);
  if (pointerSize === 8) return BigInt(n);
  if (n > 0xffffffff) throw new RangeError(`${name} does not fit wasm32`);
  return n;
}

function readExportedString(exports, symbols) {
  const lenName = symbols.lastErrorLen;
  const copyName = symbols.lastErrorCopy;
  if (typeof exports[lenName] !== "function" || typeof exports[copyName] !== "function") return "";
  const pointerSize = pointerSizeOf(exports, symbols);
  const len = safeUsizeNumber(exports[lenName](), "exported string length");
  if (!Number.isFinite(len) || len <= 0) return "";
  if (typeof exports[symbols.alloc] !== "function" || typeof exports[symbols.free] !== "function")
    return "";
  const lenArg = wasmUsizeArg(len, pointerSize, "exported string allocation length");
  const ptrRaw = exports[symbols.alloc](lenArg);
  const ptr = safeUsizeNumber(ptrRaw, "exported string pointer");
  if (ptr === 0) return "";
  try {
    const copied = safeUsizeNumber(
      exports[copyName](ptrRaw, lenArg),
      "exported string copied length",
    );

    const byteLength = Math.min(copied, len);
    return new TextDecoder("utf-8").decode(
      Uint8Array.from(new Uint8Array(exports.memory.buffer, ptr, byteLength)),
    );
  } finally {
    exports[symbols.free](ptrRaw, lenArg);
  }
}

function requireKnotsExports(exports, symbols) {
  for (const name of Object.values(symbols)) {
    if (typeof exports[name] !== "function")
      throw new Error(`Knots wasm export not found: ${name}`);
  }
}

function requireBridgeImports(imports) {
  const jsBridge = imports?.js_bridge;
  if (!jsBridge || typeof jsBridge !== "object")
    throw new Error("Knots JS bridge imports must contain a js_bridge module");
  for (const name of [
    "js_bridge_host",
    "js_bridge_global",
    "js_bridge_get",
    "js_bridge_call",
    "js_bridge_release",
  ]) {
    if (typeof jsBridge[name] !== "function")
      throw new Error(`Knots JS bridge import is not a function: ${name}`);
  }
}

function normalizeSymbols(symbols) {
  return {
    start: symbols?.start ?? "main",
    alloc: symbols?.alloc ?? "js_bridge_alloc",
    free: symbols?.free ?? "js_bridge_free",
    dispatch: symbols?.dispatch ?? "js_bridge_dispatch",
    pointerSize: symbols?.pointerSize ?? "js_bridge_pointer_size",
    lastErrorLen: symbols?.lastErrorLen ?? "knots_last_error_len",
    lastErrorCopy: symbols?.lastErrorCopy ?? "knots_last_error_copy",
  };
}

export async function startKnots({
  wasmUrl,
  startSymbol,
  symbols,
  canvas = "#canvas",
  wasmExports,
  log,
  onError,
  hmr = browserHmrDefault,
  extensions = [],
  minWorkers = 0,
  fullscreenElement,
  imports: extraImports,
}) {
  const extensionUrls = extensions.map((url) => new URL(url, document.baseURI).href);
  const module = wasmExports ? null : await compileWasm(wasmUrl);
  const threaded =
    module !== null &&
    WebAssembly.Module.exports(module).some(({ name }) => name === "knots_worker_run");
  if (threaded && !globalThis.crossOriginIsolated)
    throw new Error(
      "Knots worker dispatch requires cross-origin isolation (COOP and COEP headers)",
    );
  const exports = wasmExports;
  const resolvedSymbols = normalizeSymbols({
    ...symbols,
    start: startSymbol ?? symbols?.start,
  });
  const imports = createKnotsImports({
    canvas,
    fullscreenElement,
    imports: extraImports,
    wasmExports: exports,
    log,
    onError,
    hmr,
    symbols: resolvedSymbols,
  });
  await imports.ready;
  requireBridgeImports(imports.imports);
  const instantiated = exports
    ? { instance: { exports }, memory: null, pointerSize: null }
    : threaded
      ? await instantiateThreadedWasm(module, imports.imports)
      : {
          instance: await WebAssembly.instantiate(module, imports.imports),
          memory: null,
          pointerSize: null,
        };
  const result = { instance: instantiated.instance, module };
  requireKnotsExports(result.instance.exports, {
    start: resolvedSymbols.start,
    alloc: resolvedSymbols.alloc,
    free: resolvedSymbols.free,
    dispatch: resolvedSymbols.dispatch,
    pointerSize: resolvedSymbols.pointerSize,
  });
  if (threaded)
    requireKnotsExports(result.instance.exports, {
      run: "knots_worker_run",
      complete: "knots_worker_complete",
      release: "knots_worker_release",
      abort: "knots_worker_abort",
      stackAlloc: "knots_worker_stack_alloc",
      stackFree: "knots_worker_stack_free",
    });
  imports.setWasmExports(result.instance.exports);
  const memory = instantiated.memory ?? result.instance.exports.memory;
  imports.setMemory(memory);
  for (const url of extensionUrls) {
    const extension = await import(url);
    await extension.installMain?.({
      host: imports.host,
      bridge: imports.bridge,
      memory,
      exports: result.instance.exports,
      module: result.module,
    });
  }
  if (
    threaded &&
    pointerSizeOf(result.instance.exports, resolvedSymbols) !== instantiated.pointerSize
  )
    throw new Error("Knots worker runtime pointer size does not match the WebAssembly module");
  let workerPool = null;
  if (threaded) {
    const { WorkerPool } = await import("./knots-worker-pool.js");
    workerPool = new WorkerPool({
      module,
      memory: instantiated.memory,
      exports: result.instance.exports,
      pointerSize: instantiated.pointerSize,
      extensions: extensionUrls,
      minWorkers,
      onComplete: () => imports.host.requestFrame(),
      onError: (error) => imports.host.fatalError(errorMessage(error)),
    });
    await workerPool.init();
    imports.host.setWorkerPool(workerPool);
  }
  // Exported by wasm32-wasi builds only.
  result.instance.exports.__wasm_call_ctors?.();
  const start = result.instance.exports[resolvedSymbols.start];
  const rc = start();
  if (rc !== 0) {
    const detail = readExportedString(result.instance.exports, resolvedSymbols);
    throw new Error(`Knots start failed: ${rc}${detail ? `: ${detail}` : ""}`);
  }
  return {
    instance: result.instance,
    module: result.module,
    host: imports.host,
    bridge: imports.bridge,
  };
}

async function compileWasm(wasmUrl) {
  if (WebAssembly.compileStreaming) {
    try {
      return await WebAssembly.compileStreaming(fetch(wasmUrl));
    } catch (err) {
      if (!(err instanceof TypeError || err instanceof WebAssembly.CompileError)) throw err;
    }
  }
  const response = await fetch(wasmUrl);
  return WebAssembly.compile(await response.arrayBuffer());
}

async function instantiateThreadedWasm(module, imports) {
  let wasm32Error;
  try {
    return await instantiateThreadedWasmWithPointerSize(module, imports, 4);
  } catch (error) {
    if (!(error instanceof WebAssembly.LinkError)) throw error;
    wasm32Error = error;
  }

  try {
    return await instantiateThreadedWasmWithPointerSize(module, imports, 8);
  } catch (error) {
    if (error instanceof WebAssembly.LinkError) throw wasm32Error;
    throw error;
  }
}

async function instantiateThreadedWasmWithPointerSize(module, imports, pointerSize) {
  const initial = pointerSize === 8 ? BigInt(WASM_MEMORY_INITIAL_PAGES) : WASM_MEMORY_INITIAL_PAGES;
  const maximum = pointerSize === 8 ? BigInt(WASM_MEMORY_MAX_PAGES) : WASM_MEMORY_MAX_PAGES;
  const memory = new WebAssembly.Memory({
    initial,
    maximum,
    shared: true,
    ...(pointerSize === 8 ? { address: "i64" } : {}),
  });
  const pointerType = pointerSize === 8 ? "i64" : "i32";
  const workerTask = new WebAssembly.Global(
    { value: pointerType, mutable: true },
    pointerSize === 8 ? 0n : 0,
  );
  const instance = await WebAssembly.instantiate(module, {
    ...imports,
    env: { ...imports.env, memory, knots_worker_task: workerTask },
  });
  return { instance, memory, pointerSize };
}
