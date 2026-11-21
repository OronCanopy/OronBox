export async function instantiateCore(bytes, withWasi) {
  let instance;
  const memory = () => instance.exports.memory.buffer;
  const setU32 = (offset, value) => new DataView(memory()).setUint32(offset, value, true);
  const wasi = {
    args_get: () => 0,
    args_sizes_get(count, size) {
      setU32(count, 0);
      setU32(size, 0);
      return 0;
    },
    fd_seek: () => 8, // EBADF
    fd_close: () => 8,
    fd_write(fd, iovs, count, written) {
      if (fd !== 1 && fd !== 2) return 8;
      const view = new DataView(memory());
      let total = 0;
      for (let index = 0; index < count; index++) {
        total += view.getUint32(iovs + index * 8 + 4, true);
      }
      setU32(written, total);
      return 0;
    },
    proc_exit(code) {
      throw new Error(`Wasm exited with code ${code}`);
    },
    random_get(offset, length) {
      const bytes = new Uint8Array(memory(), offset, length);
      for (let index = 0; index < length; index += 65536) {
        crypto.getRandomValues(bytes.subarray(index, index + 65536));
      }
      return 0;
    },
  };
  ({ instance } = await WebAssembly.instantiate(bytes, withWasi ? { wasi_snapshot_preview1: wasi } : {}));

  return {
    call(name, args) {
      const fn = instance.exports[name];
      if (typeof fn !== "function") throw new Error(`Unknown Wasm function: ${name}`);
      const result = fn(...args);
      return result === undefined ? [] : (Array.isArray(result) ? result : [result]).map(Number);
    },
    read(name, offset, length) {
      return new Uint8Array(instance.exports[name].buffer, offset, length).slice();
    },
    write(name, offset, bytes) {
      new Uint8Array(instance.exports[name].buffer, offset, bytes.length).set(bytes);
    },
  };
}
