const ESUCCESS = 0;
const EBADF = 8;
const ENOSYS = 52;

const decoder = new TextDecoder("utf-8");

export function createWasiImports(getMemory, log = console) {
  const lines = { 1: "", 2: "" };

  function view() {
    return new DataView(getMemory().buffer);
  }

  function bytes() {
    return new Uint8Array(getMemory().buffer);
  }

  function flushLine(fd, text) {
    let buffer = lines[fd] + text;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline);
      if (fd === 2) log.warn(line);
      else log.log(line);
      buffer = buffer.slice(newline + 1);
    }
    lines[fd] = buffer;
  }

  const imports = {
    args_sizes_get(argcPtr, bufSizePtr) {
      const v = view();
      v.setUint32(argcPtr, 0, true);
      v.setUint32(bufSizePtr, 0, true);
      return ESUCCESS;
    },
    args_get() {
      return ESUCCESS;
    },
    environ_sizes_get(countPtr, bufSizePtr) {
      const v = view();
      v.setUint32(countPtr, 0, true);
      v.setUint32(bufSizePtr, 0, true);
      return ESUCCESS;
    },
    environ_get() {
      return ESUCCESS;
    },
    clock_res_get(_id, resPtr) {
      view().setBigUint64(resPtr, 1000n, true);
      return ESUCCESS;
    },
    clock_time_get(id, _precision, timePtr) {
      const ns =
        id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
      view().setBigUint64(timePtr, ns, true);
      return ESUCCESS;
    },
    random_get(ptr, len) {
      const out = bytes().subarray(ptr, ptr + len);
      // getRandomValues rejects views of shared memory.
      const tmp = new Uint8Array(Math.min(len, 65536));
      for (let offset = 0; offset < len; offset += tmp.length) {
        const chunk = tmp.subarray(0, Math.min(tmp.length, len - offset));
        crypto.getRandomValues(chunk);
        out.set(chunk, offset);
      }
      return ESUCCESS;
    },
    fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
      const v = view();
      const mem = bytes();

      let written = 0;
      let text = "";
      for (let i = 0; i < iovsLen; i++) {
        const ptr = v.getUint32(iovsPtr + i * 8, true);
        const len = v.getUint32(iovsPtr + i * 8 + 4, true);
        // TextDecoder rejects views of shared memory.
        text += decoder.decode(mem.slice(ptr, ptr + len));
        written += len;
      }

      if (fd !== 1 && fd !== 2) return EBADF;
      flushLine(fd, text);
      v.setUint32(nwrittenPtr, written, true);
      return ESUCCESS;
    },
    fd_fdstat_get(fd, statPtr) {
      if (fd > 2) return EBADF;

      const v = view();
      for (let i = 0; i < 24; i += 4) {
        v.setUint32(statPtr + i, 0, true);
      }

      v.setUint8(statPtr, 2); // character device
      return ESUCCESS;
    },
    fd_prestat_get() {
      return EBADF;
    },
    fd_prestat_dir_name() {
      return EBADF;
    },
    fd_close(fd) {
      return fd <= 2 ? ESUCCESS : EBADF;
    },
    fd_seek() {
      return EBADF;
    },
    fd_read() {
      return EBADF;
    },
    fd_filestat_get() {
      return EBADF;
    },
    path_open() {
      return ENOSYS;
    },
    path_filestat_get() {
      return ENOSYS;
    },
    poll_oneoff() {
      return ENOSYS;
    },
    sched_yield() {
      return ESUCCESS;
    },
    proc_exit(code) {
      throw new Error(`wasm called exit(${code})`);
    },
    proc_raise() {
      return ENOSYS;
    },
  };

  const reported = new Set();
  return new Proxy(imports, {
    get(target, name) {
      if (name in target) return target[name];

      if (typeof name !== "string") return undefined;

      return () => {
        if (!reported.has(name)) {
          reported.add(name);
          log.warn(`wasi_snapshot_preview1.${name} is not supported in the browser`);
        }

        return name.startsWith("fd_") ? EBADF : ENOSYS;
      };
    },
    has() {
      return true;
    },
  });
}
