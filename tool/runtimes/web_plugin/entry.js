import { newQuickJSWASMModuleFromVariant } from "quickjs-emscripten";
import variant from "@jitl/quickjs-singlefile-browser-release-sync";
import { instantiateCore } from "./core_wasm.js";

let quickJs;

async function create(bootstrap, hostCall) {
  quickJs ??= newQuickJSWASMModuleFromVariant(variant).catch(error => {
    quickJs = undefined;
    throw error;
  });
  const engine = await quickJs;
  const runtime = engine.newRuntime({
    memoryLimitBytes: 64 * 1024 * 1024,
    maxStackSizeBytes: 1024 * 1024,
  });
  const context = runtime.newContext();
  const timers = new Map();
  const operations = new Map();
  let closed = false;
  let deadline;
  runtime.setInterruptHandler(() => performance.now() > deadline);

  function unwrap(result) {
    if (!result.error) return result.value;
    const error = context.dump(result.error);
    result.error.dispose();
    throw new Error(error?.message ?? String(error));
  }

  function evaluate(source, name, options) {
    if (closed) throw new Error("JavaScript runtime is closed");
    deadline = performance.now() + 10000;
    return unwrap(context.evalCode(source, name, options));
  }

  function pump() {
    deadline = performance.now() + 10000;
    try {
      unwrap(runtime.executePendingJobs());
    } catch (error) {
      rejectOperations(error);
      throw error;
    }
    for (const [handle, operation] of operations) {
      const result = context.getPromiseState(handle);
      if (result.type === "pending") continue;
      operations.delete(handle);
      try {
        const value = unwrap(result);
        try {
          operation.resolve(operation.readResult ? JSON.stringify(context.dump(value) ?? null) : "null");
        } finally {
          if (!result.notAPromise) value.dispose();
        }
      } catch (error) {
        operation.reject(error);
      } finally {
        handle.dispose();
      }
    }
  }

  function rejectOperations(error) {
    for (const [handle, { reject }] of operations) {
      handle.dispose();
      reject(error);
    }
    operations.clear();
  }

  function settle(handle, readResult = true) {
    return new Promise((resolve, reject) => {
      operations.set(handle, { resolve, reject, readResult });
      pump();
    });
  }

  function invoke(name, args) {
    return settle(evaluate(`globalThis[${JSON.stringify(name)}](...${args})`, "callback.js"));
  }

  function reportError(error) {
    if (!closed) Promise.resolve(hostCall("runtime.reportError", JSON.stringify([String(error)]))).catch(() => {});
  }

  function clearTimer(id) {
    clearTimeout(timers.get(id));
    return timers.delete(id);
  }

  async function request(method, args) {
    if (method === "runtime.clearTimer") return clearTimer(args[0]);
    if (method === "runtime.setTimer") {
      const [id, delay, repeat] = args;
      clearTimer(id);
      const fire = () => {
        if (!repeat) timers.delete(id);
        try {
          invoke("__obFireTimer", JSON.stringify([id])).catch(reportError);
        } catch (error) {
          reportError(error);
        }
      };
      timers.set(id, repeat ? setInterval(fire, delay) : setTimeout(fire, delay));
      return id;
    }
    return JSON.parse(await hostCall(method, JSON.stringify(args)));
  }

  async function serve({ requestId, method, args }) {
    if (closed) return;
    let success = true;
    let result;
    try {
      result = await request(method, args);
    } catch (error) {
      success = false;
      result = String(error);
    }
    if (closed) return;
    try {
      evaluate(`__obSettleHostRequest(${JSON.stringify(requestId)}, ${success}, ${JSON.stringify(result)})`, "host_result.js").dispose();
      pump();
    } catch (error) {
      reportError(error);
    }
  }

  function close() {
    if (closed) return;
    closed = true;
    for (const id of timers.keys()) clearTimer(id);
    rejectOperations(new Error("JavaScript runtime closed"));
    context.dispose();
    runtime.dispose();
  }

  try {
    const sendMessage = context.newFunction("sendMessage", (channel, message) => {
      if (context.getString(channel) !== "OronBoxHost") return;
      const payload = JSON.parse(context.getString(message));
      queueMicrotask(() => serve(payload));
    });
    context.setProp(context.global, "sendMessage", sendMessage);
    sendMessage.dispose();
    evaluate(bootstrap, "bootstrap.js").dispose();
  } catch (error) {
    close();
    throw error;
  }

  return {
    async evaluateEntry(source, name, modules) {
      const sources = new Map(Object.entries(JSON.parse(modules)));
      runtime.setModuleLoader(path => {
        if (!sources.has(path)) throw new Error(`Plugin module not found: ${path}`);
        return sources.get(path);
      });
      return settle(evaluate(source, name, name.endsWith(".mjs") ? { type: "module" } : undefined), false);
    },
    invoke,
    close,
  };
}

globalThis.OronBoxPluginRuntime = { create, instantiateCore };
