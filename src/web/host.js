import { createBridgeImports } from "./js-bridge.js";

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

class KnotsBrowserHost {
  constructor(options) {
    this.canvas = options.canvas;
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
    this.ready = this.initGpu();
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
    return document.fullscreenElement === canvas;
  }

  requestFullscreen(canvas) {
    if (document.fullscreenElement === canvas) return 1;
    if (!canvas.requestFullscreen) return 0;
    this.pendingFullscreenCanvas = canvas;
    if (!navigator.userActivation || navigator.userActivation.isActive) this.serviceFullscreen();
    return 1;
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
    const request = canvas.requestFullscreen?.();
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

export function createKnotsImports(options) {
  const bridge = createBridgeImports();
  bridge.setExportSymbols({
    dispatch: options.symbols?.dispatch,
    pointerSize: options.symbols?.pointerSize,
  });
  const host = new KnotsBrowserHost(options);
  bridge.setHost(host);
  if (options.wasmExports) bridge.setWasmExports(options.wasmExports);

  return {
    imports: bridge.imports,
    ready: host.ready,
    bridge,
    host,
    setWasmExports(exports) {
      bridge.setWasmExports(exports);
    },
  };
}

async function instantiateWasm(wasmUrl, imports) {
  if (WebAssembly.instantiateStreaming) {
    try {
      return await WebAssembly.instantiateStreaming(fetch(wasmUrl), imports);
    } catch (err) {
      if (!(err instanceof TypeError || err instanceof WebAssembly.CompileError)) throw err;
    }
  }
  const response = await fetch(wasmUrl);
  const bytes = await response.arrayBuffer();
  return WebAssembly.instantiate(bytes, imports);
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
    const bytes = new Uint8Array(exports.memory.buffer, ptr, Math.min(copied, len));
    return new TextDecoder("utf-8").decode(bytes);
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
}) {
  const exports = wasmExports;
  const resolvedSymbols = normalizeSymbols({
    ...symbols,
    start: startSymbol ?? symbols?.start,
  });
  const imports = createKnotsImports({
    canvas,
    wasmExports: exports,
    log,
    onError,
    symbols: resolvedSymbols,
  });
  await imports.ready;
  requireBridgeImports(imports.imports);
  const result = exports
    ? { instance: { exports }, module: null }
    : await instantiateWasm(wasmUrl, imports.imports);
  requireKnotsExports(result.instance.exports, {
    start: resolvedSymbols.start,
    alloc: resolvedSymbols.alloc,
    free: resolvedSymbols.free,
    dispatch: resolvedSymbols.dispatch,
    pointerSize: resolvedSymbols.pointerSize,
  });
  imports.setWasmExports(result.instance.exports);
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
