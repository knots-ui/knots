const textDecoder = new TextDecoder("utf-8");
const textEncoder = new TextEncoder();

const ARG_SIZE = 24;
const ARG_TAG = 0;
const ARG_A = 8;
const ARG_B = 16;

const TAG_UNDEFINED = 0;
const TAG_NULL = 1;
const TAG_BOOLEAN = 2;
const TAG_I32 = 3;
const TAG_U32 = 4;
const TAG_F64 = 5;
const TAG_HANDLE = 6;
const TAG_STRING = 7;
const TAG_BYTES = 8;
const TAG_U64 = 9;
const TAG_USIZE = 10;

const TYPE_UNDEFINED = 0;
const TYPE_NULL = 1;
const TYPE_BOOLEAN = 2;
const TYPE_NUMBER = 3;
const TYPE_STRING = 4;
const TYPE_BIGINT = 5;
const TYPE_FUNCTION = 6;
const TYPE_OBJECT = 7;

const MAX_U32 = 0xffffffff;
const MAX_SAFE_INDEX = BigInt(Number.MAX_SAFE_INTEGER);

function toSafeNumber(value, name = "value") {
  if (typeof value === "bigint") {
    if (value < 0n || value > MAX_SAFE_INDEX)
      throw new RangeError(`${name} is outside the JS safe integer range`);
    return Number(value);
  }
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n < 0)
    throw new RangeError(`${name} is outside the JS safe integer range`);
  return n;
}

function isError(value) {
  return value instanceof Error;
}

export class JsBridge {
  constructor() {
    this.exports = null;
    this.memory = null;
    this.bytes = null;
    this.view = null;
    this.host = null;
    this.pointerSize = 4;
    this.lastError = "";
    this.symbols = {
      dispatch: "js_bridge_dispatch",
      pointerSize: "js_bridge_pointer_size",
    };
    this.freeHandles = [];
    this.values = [null, undefined, null, true, false, globalThis];
    const jsBridgeImports = this.wrapImports(this.createImports());
    // Also allow the namespace object itself to be passed as the wasm import object.
    jsBridgeImports.js_bridge = jsBridgeImports;
    this.imports = {
      js_bridge: jsBridgeImports,
    };
  }

  setWasmExports(exports) {
    this.exports = exports;
    this.memory = exports.memory;
    if (!this.memory) throw new Error("wasm module must export memory");
    const pointerSize = exports[this.symbols.pointerSize];
    if (typeof pointerSize !== "function")
      throw new Error(`wasm export ${this.symbols.pointerSize} is not attached`);
    this.pointerSize = Number(pointerSize());
    if (this.pointerSize !== 4 && this.pointerSize !== 8)
      throw new Error(`unsupported wasm pointer size: ${this.pointerSize}`);
    this.refreshMemory();
  }

  setHost(host) {
    this.host = host;
  }

  setExportSymbols(symbols = {}) {
    for (const [name, value] of Object.entries(symbols)) {
      if (value !== undefined) this.symbols[name] = value;
    }
  }

  refreshMemory() {
    if (!this.memory) throw new Error("wasm exports are not attached");
    if (this.bytes?.buffer === this.memory.buffer) return;
    this.bytes = new Uint8Array(this.memory.buffer);
    this.view = new DataView(this.memory.buffer);
  }

  wrapImports(imports) {
    const wrapped = {};
    for (const [name, fn] of Object.entries(imports)) {
      wrapped[name] = (...args) => {
        if (this.memory) this.refreshMemory();
        try {
          return fn(...args);
        } catch (err) {
          this.lastError = isError(err) ? `${err.name}: ${err.message}` : String(err);
          return this.failureValueFor(name);
        }
      };
    }
    return wrapped;
  }

  failureValueFor(name) {
    if (
      name === "js_bridge_set" ||
      name === "js_bridge_set_index" ||
      name === "js_bridge_array_push" ||
      name === "js_bridge_as_bool" ||
      name === "js_bridge_string_eq" ||
      name === "js_bridge_strict_equal"
    ) {
      return 0;
    }
    if (
      name === "js_bridge_as_i32" ||
      name === "js_bridge_as_u32" ||
      name === "js_bridge_as_usize" ||
      name === "js_bridge_string_len" ||
      name === "js_bridge_string_copy"
    ) {
      return 0;
    }
    if (name === "js_bridge_last_error_len" || name === "js_bridge_last_error_copy")
      return this.pointerSize === 8 ? 0n : 0;
    if (name === "js_bridge_as_f64") return 0.0;
    return 0;
  }

  insert(value) {
    if (value === undefined) return 1;
    if (value === null) return 2;
    if (value === true) return 3;
    if (value === false) return 4;

    const reused = this.freeHandles.pop();
    if (reused !== undefined) {
      this.values[reused] = value;
      return reused;
    }

    this.values.push(value);
    return this.values.length - 1;
  }

  value(handle) {
    handle = toSafeNumber(handle, "handle");
    if (
      handle <= 0 ||
      handle >= this.values.length ||
      (this.values[handle] === null && handle !== 2)
    ) {
      throw new Error(`invalid JS handle: ${handle}`);
    }
    return this.values[handle];
  }

  retain(handle) {
    return this.insert(this.value(handle));
  }

  release(handle) {
    handle = toSafeNumber(handle, "handle");
    if (handle < 6 || handle >= this.values.length) return;
    if (this.values[handle] === null) return;
    this.values[handle] = null;
    this.freeHandles.push(handle);
  }

  readString(ptr, len) {
    ptr = toSafeNumber(ptr, "string pointer");
    len = toSafeNumber(len, "string length");
    if (ptr === 0 || len === 0) return "";
    this.checkMemoryRange(ptr, len);
    return textDecoder.decode(this.bytes.subarray(ptr, ptr + len));
  }

  readName(ptr, len) {
    return this.readString(ptr, len);
  }

  readBytes(ptr, len) {
    ptr = toSafeNumber(ptr, "bytes pointer");
    len = toSafeNumber(len, "bytes length");
    this.checkMemoryRange(ptr, len);
    return new Uint8Array(this.memory.buffer, ptr, len);
  }

  readArg(ptr) {
    ptr = toSafeNumber(ptr, "argument pointer");
    this.checkMemoryRange(ptr, ARG_SIZE);
    const tag = this.view.getUint32(ptr + ARG_TAG, true);
    const a = this.view.getBigUint64(ptr + ARG_A, true);
    const b = this.view.getBigUint64(ptr + ARG_B, true);

    switch (tag) {
      case TAG_UNDEFINED:
        return undefined;
      case TAG_NULL:
        return null;
      case TAG_BOOLEAN:
        return a !== 0n;
      case TAG_I32:
        return Number(BigInt.asIntN(64, a));
      case TAG_U32:
        return Number(a & 0xffffffffn);
      case TAG_F64:
        return new Float64Array(new BigUint64Array([a]).buffer)[0];
      case TAG_HANDLE:
        return this.value(Number(a));
      case TAG_STRING:
        return this.readString(a, b);
      case TAG_BYTES:
        return this.readBytes(a, b);
      case TAG_U64:
        return a;
      case TAG_USIZE:
        return toSafeNumber(a, "usize argument");
      default:
        throw new Error(`unknown bridge argument tag: ${tag}`);
    }
  }

  readArgs(ptr, len) {
    ptr = toSafeNumber(ptr, "arguments pointer");
    len = toSafeNumber(len, "arguments length");
    if (len > 0) this.checkMemoryRange(ptr, len * ARG_SIZE);
    const args = [];
    for (let i = 0; i < len; i += 1) args.push(this.readArg(ptr + i * ARG_SIZE));
    return args;
  }

  copyStringToMemory(value, outPtr, outLen) {
    outPtr = toSafeNumber(outPtr, "string output pointer");
    outLen = toSafeNumber(outLen, "string output length");
    const encoded = textEncoder.encode(String(value));
    const len = Math.min(encoded.length, outLen);
    if (len > 0) this.checkMemoryRange(outPtr, len);
    this.bytes.set(encoded.subarray(0, len), outPtr);
    return len;
  }

  writeU32(ptr, value) {
    ptr = toSafeNumber(ptr, "u32 output pointer");
    this.checkMemoryRange(ptr, 4);
    this.view.setUint32(ptr, Number(value), true);
  }

  writeI32(ptr, value) {
    ptr = toSafeNumber(ptr, "i32 output pointer");
    this.checkMemoryRange(ptr, 4);
    this.view.setInt32(ptr, Number(value), true);
  }

  writeF64(ptr, value) {
    ptr = toSafeNumber(ptr, "f64 output pointer");
    this.checkMemoryRange(ptr, 8);
    this.view.setFloat64(ptr, Number(value), true);
  }

  writeUsize(ptr, value) {
    ptr = toSafeNumber(ptr, "usize output pointer");
    const n = toSafeNumber(value, "usize value");
    if (this.pointerSize === 8) {
      this.checkMemoryRange(ptr, 8);
      this.view.setBigUint64(ptr, BigInt(n), true);
    } else {
      if (n > MAX_U32) throw new RangeError("usize value does not fit wasm32");
      this.writeU32(ptr, n);
    }
  }

  returnUsize(value) {
    const n = toSafeNumber(value, "usize return value");
    if (this.pointerSize === 8) return BigInt(n);
    if (n > MAX_U32) throw new RangeError("usize return value does not fit wasm32");
    return n;
  }

  checkMemoryRange(ptr, len) {
    const end = ptr + len;
    if (!Number.isSafeInteger(end) || len < 0 || ptr > this.bytes.length || end > this.bytes.length)
      throw new RangeError("wasm memory range is outside the current memory buffer");
  }

  typeOf(value) {
    if (value === undefined) return TYPE_UNDEFINED;
    if (value === null) return TYPE_NULL;
    switch (typeof value) {
      case "boolean":
        return TYPE_BOOLEAN;
      case "number":
        return TYPE_NUMBER;
      case "string":
        return TYPE_STRING;
      case "bigint":
        return TYPE_BIGINT;
      case "function":
        return TYPE_FUNCTION;
      default:
        return TYPE_OBJECT;
    }
  }

  createImports() {
    return {
      js_bridge_host: () => {
        if (!this.host) throw new Error("Knots browser host is not attached");
        return this.insert(this.host);
      },
      js_bridge_global: (namePtr, nameLen) =>
        this.insert(globalThis[this.readName(namePtr, nameLen)]),
      js_bridge_get: (object, namePtr, nameLen) =>
        this.insert(this.value(object)[this.readName(namePtr, nameLen)]),
      js_bridge_get_index: (object, index) =>
        this.insert(this.value(object)[toSafeNumber(index, "index")]),
      js_bridge_set: (object, namePtr, nameLen, argPtr) => {
        this.value(object)[this.readName(namePtr, nameLen)] = this.readArg(argPtr);
        return 1;
      },
      js_bridge_set_index: (object, index, argPtr) => {
        this.value(object)[toSafeNumber(index, "index")] = this.readArg(argPtr);
        return 1;
      },
      js_bridge_call: (object, namePtr, nameLen, argsPtr, argsLen) => {
        const target = this.value(object);
        const method = target[this.readName(namePtr, nameLen)];
        if (typeof method !== "function")
          throw new Error(`property is not callable: ${this.readName(namePtr, nameLen)}`);
        return this.insert(method.apply(target, this.readArgs(argsPtr, argsLen)));
      },
      js_bridge_call_function: (fnHandle, thisHandle, argsPtr, argsLen) => {
        const fn = this.value(fnHandle);
        if (typeof fn !== "function") throw new Error("handle is not callable");
        return this.insert(fn.apply(this.value(thisHandle), this.readArgs(argsPtr, argsLen)));
      },
      js_bridge_construct: (constructor, argsPtr, argsLen) => {
        const ctor = this.value(constructor);
        return this.insert(new ctor(...this.readArgs(argsPtr, argsLen)));
      },
      js_bridge_new_object: () => this.insert({}),
      js_bridge_new_array: () => this.insert([]),
      js_bridge_array_push: (array, argPtr) => {
        this.value(array).push(this.readArg(argPtr));
        return 1;
      },
      js_bridge_callback: (id) =>
        this.insert((...args) => {
          const dispatch = this.exports?.[this.symbols.dispatch];
          if (typeof dispatch !== "function")
            throw new Error(`wasm export ${this.symbols.dispatch} is not attached`);
          const argsHandle = this.insert(args);
          try {
            dispatch(toSafeNumber(id, "callback id"), argsHandle, args.length);
          } finally {
            this.release(argsHandle);
          }
        }),
      js_bridge_retain: (handle) => this.retain(handle),
      js_bridge_release: (handle) => this.release(handle),
      js_bridge_typeof: (handle) => this.typeOf(this.value(handle)),
      js_bridge_as_bool: (handle, outPtr) => {
        this.writeU32(outPtr, this.value(handle) ? 1 : 0);
        return 1;
      },
      js_bridge_as_i32: (handle, outPtr) => {
        this.writeI32(outPtr, Number(this.value(handle)) | 0);
        return 1;
      },
      js_bridge_as_u32: (handle, outPtr) => {
        this.writeU32(outPtr, Number(this.value(handle)) >>> 0);
        return 1;
      },
      js_bridge_as_usize: (handle, outPtr) => {
        this.writeUsize(outPtr, this.value(handle));
        return 1;
      },
      js_bridge_as_f64: (handle, outPtr) => {
        this.writeF64(outPtr, Number(this.value(handle)));
        return 1;
      },
      js_bridge_string_len: (handle, outPtr) => {
        this.writeUsize(outPtr, textEncoder.encode(String(this.value(handle))).length);
        return 1;
      },
      js_bridge_string_copy: (handle, outPtr, outLen, outCopiedPtr) => {
        this.writeUsize(outCopiedPtr, this.copyStringToMemory(this.value(handle), outPtr, outLen));
        return 1;
      },
      js_bridge_string_eq: (handle, expectedPtr, expectedLen) =>
        String(this.value(handle)) === this.readString(expectedPtr, expectedLen) ? 1 : 0,
      js_bridge_strict_equal: (a, b) => (this.value(a) === this.value(b) ? 1 : 0),
      js_bridge_last_error_len: () => this.returnUsize(textEncoder.encode(this.lastError).length),
      js_bridge_last_error_copy: (outPtr, outLen) =>
        this.returnUsize(this.copyStringToMemory(this.lastError, outPtr, outLen)),
    };
  }
}

export function createBridgeImports() {
  return new JsBridge();
}
