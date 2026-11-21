const oronBoxPluginBootstrap = r'''
(() => {
  const callbacks = Object.create(null);
  const events = Object.create(null);
  const timers = Object.create(null);
  const hostRequests = Object.create(null);
  const scopedCallbacks = new Set();
  const renderedCallbacks = new Map();
  const pendingRenders = new Map();
  const providerCallbacks = new Map();
  const appSideCallbacks = new Map();
  let nextRender = 0;
  let nextCallback = 0;
  let nextTimer = 0;
  let nextHostRequest = 0;

  function host(method, args = []) {
    const requestId = `ob_host_${++nextHostRequest}`;
    return new Promise((resolve, reject) => {
      hostRequests[requestId] = {resolve, reject};
      try {
        sendMessage('OronBoxHost', JSON.stringify({requestId, method, args}));
      } catch (error) {
        delete hostRequests[requestId];
        reject(error);
      }
    });
  }

  globalThis.__obSettleHostRequest = (requestId, succeeded, payload) => {
    const request = hostRequests[requestId];
    if (!request) return;
    delete hostRequests[requestId];
    if (succeeded) request.resolve(payload);
    else request.reject(new Error(String(payload)));
  };

  function registerCallback(fn, scoped = false) {
    if (typeof fn !== 'function') throw new TypeError('Expected a function');
    const id = `ob_callback_${++nextCallback}`;
    callbacks[id] = fn;
    if (scoped) scopedCallbacks.add(id);
    return id;
  }

  function releaseUiCallbacks() {
    const retained = new Set();
    for (const ids of [...renderedCallbacks.values(), ...pendingRenders.values()]) {
      for (const id of ids) retained.add(id);
    }
    for (const id of scopedCallbacks) {
      if (retained.has(id)) continue;
      scopedCallbacks.delete(id);
      delete callbacks[id];
    }
  }

  async function publishUi(method, tree) {
    const ids = new Set();
    const visit = value => {
      if (typeof value === 'string' && scopedCallbacks.has(value)) ids.add(value);
      else if (value && typeof value === 'object') Object.values(value).forEach(visit);
    };
    visit(tree);
    const revision = ++nextRender;
    pendingRenders.set(revision, ids);
    try {
      const result = await host(method, [tree]);
      const target = method === 'ui.openPage' ? 'page' : 'root';
      const current = renderedCallbacks.get(target);
      if (!current || current.revision < revision) {
        ids.revision = revision;
        renderedCallbacks.set(target, ids);
      }
      return result;
    } finally {
      pendingRenders.delete(revision);
      releaseUiCallbacks();
    }
  }

  function scheduleTimer(fn, delay, repeat) {
    const id = ++nextTimer;
    timers[id] = {fn, repeat};
    host('runtime.setTimer', [id, Number(delay) || 0, repeat]);
    return id;
  }

  globalThis.console = {
    log: (...args) => host('log.info', args.map(String)),
    debug: (...args) => host('log.debug', args.map(String)),
    info: (...args) => host('log.info', args.map(String)),
    warn: (...args) => host('log.warning', args.map(String)),
    error: (...args) => host('log.error', args.map(String)),
  };

  globalThis.__obSetRuntimeGlobals = (id, name, version, runtimeVersion) => {
    Object.defineProperty(globalThis, 'PLUGIN', {
      value: Object.freeze({id, name, version, runtimeVersion}),
      writable: false,
      configurable: false,
    });
  };

  globalThis.setTimeout = (fn, delay = 0) => scheduleTimer(fn, delay, false);
  globalThis.setInterval = (fn, delay = 0) => scheduleTimer(fn, delay, true);
  globalThis.clearTimeout = globalThis.clearInterval = (id) => {
    delete timers[id];
    host('runtime.clearTimer', [Number(id)]);
  };

  const base64Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  globalThis.btoa = value => {
    const source = String(value);
    let result = '';
    for (let offset = 0; offset < source.length; offset += 3) {
      const a = source.charCodeAt(offset);
      const b = source.charCodeAt(offset + 1);
      const c = source.charCodeAt(offset + 2);
      if (a > 255 || b > 255 || c > 255) throw new TypeError('Invalid base64 input');
      const bits = a << 16 | (b || 0) << 8 | (c || 0);
      result += base64Alphabet[bits >>> 18] + base64Alphabet[bits >>> 12 & 63];
      result += Number.isNaN(b) ? '=' : base64Alphabet[bits >>> 6 & 63];
      result += Number.isNaN(c) ? '=' : base64Alphabet[bits & 63];
    }
    return result;
  };
  globalThis.atob = value => {
    let source = String(value).replace(/[\t\n\f\r ]/g, '');
    if (source.length % 4 === 0) source = source.replace(/==?$/, '');
    if (source.length % 4 === 1 || /[^A-Za-z0-9+/]/.test(source)) throw new TypeError('Invalid base64 input');
    let bits = 0;
    let length = 0;
    let result = '';
    for (const char of source) {
      bits = bits << 6 | base64Alphabet.indexOf(char);
      length += 6;
      if (length >= 8) {
        length -= 8;
        result += String.fromCharCode(bits >>> length & 255);
      }
    }
    return result;
  };

  const api = {
    storage: {
      get: (key) => host('storage.get', [key]),
      set: (key, value) => host('storage.set', [key, value]),
      remove: (key) => host('storage.remove', [key]),
      clear: () => host('storage.clear'),
    },
    file: {
      read: (path, options) => host('file.read', [path, options]),
      write: (path, data, options) => host('file.write', [path, data, options]),
      list: (path) => host('file.list', [path]),
      stat: (path) => host('file.stat', [path]),
      mkdir: (path) => host('file.mkdir', [path]),
      copy: (source, destination) =>
        host('file.copy', [source, destination]),
      move: (source, destination) =>
        host('file.move', [source, destination]),
      remove: (path) => host('file.remove', [path]),
      pick: (options) => host('file.pick', [options]),
      unload: (path, options) => host('file.unload', [path, options]),
    },
    network: {
      fetch: (url, options) => host('network.fetch', [url, options]),
      download: (url, path, options) =>
        host('network.download', [url, path, options]),
    },
    interconnect: {
      send: (packageName, data, deviceId) =>
        host('interconnect.send', [packageName, data, deviceId]),
      onMessage: async (fn) => {
        await host('interconnect.observe');
        events.interconnect = (payload) => fn(
          typeof payload === 'string' ? JSON.parse(payload) : payload
        );
        return () => {
          delete events.interconnect;
          return host('interconnect.unobserve');
        };
      },
    },
    provider: {
      register: async (definition) => {
        const value = {...definition};
        const ids = [];
        for (const key of ['categories', 'query', 'detail', 'download']) {
          if (typeof value[key] === 'function') {
            value[key] = registerCallback(value[key]);
            ids.push(value[key]);
          }
        }
        try {
          const result = await host('provider.register', [value]);
          for (const id of providerCallbacks.get(value.id) || []) delete callbacks[id];
          providerCallbacks.set(value.id, ids);
          return result;
        } catch (error) {
          for (const id of ids) delete callbacks[id];
          throw error;
        }
      },
      unregister: async id => {
        const result = await host('provider.unregister', [id]);
        for (const callback of providerCallbacks.get(id) || []) delete callbacks[callback];
        providerCallbacks.delete(id);
        return result;
      },
    },
    device: {
      list: () => host('device.list'),
      info: (id) => host('device.info', [id]),
      connect: (id) => host('device.connect', [id]),
      disconnect: (id) => host('device.disconnect', [id]),
      apps: {
        list: (id) => host('device.apps.list', [id]),
        launch: (packageName, options) =>
          host('device.apps.launch', [packageName, options]),
        uninstall: (packageName) => host('device.apps.uninstall', [packageName]),
      },
      install: (path, options) => host('device.install', [path, options]),
    },
    protocol: {
      send: (data, options) => host('protocol.send', [data, options]),
      request: (data, options) => host('protocol.request', [data, options]),
      observe: async (fn) => {
        await host('protocol.observe');
        events['protocol.data'] = (payload) => fn(
          typeof payload === 'string' ? JSON.parse(payload) : payload
        );
        return () => {
          delete events['protocol.data'];
          return host('protocol.unobserve');
        };
      },
    },
    os: {
      arch: () => host('os.arch'),
      hostname: () => host('os.hostname'),
      locale: () => host('os.locale'),
      platform: () => host('os.platform'),
      version: () => host('os.version'),
      language: () => host('os.language'),
      appearance: () => host('os.appearance'),
      timezone: () => host('os.timezone'),
    },
    watchface: {
      list: (deviceId) => host('watchface.list', [deviceId]),
      set: (watchfaceId, deviceId) =>
        host('watchface.set', [watchfaceId, deviceId]),
    },
    appside: {
      list: () => host('appside.list'),
      start: (appId) => host('appside.start', [appId]),
      stop: (appId) => host('appside.stop', [appId]),
      send: (appId, hexData) => host('appside.send', [appId, hexData]),
      inject: (appId, hexData) => host('appside.inject', [appId, hexData]),
      sessions: () => host('appside.sessions'),
      events: (appId) => host('appside.events', [appId]),
      clearEvents: (appId) => host('appside.clearEvents', [appId]),
      attach: async (options) => {
        if (!options || typeof options !== 'object') {
          throw new TypeError('appside.attach options are required');
        }
        const appId = Number(options.appId);
        const context = {
          appId,
          request: (message, requestOptions) =>
            host('appside.zml.request', [appId, message, requestOptions]),
          call: (message) => host('appside.zml.call', [appId, message]),
          detach: async () => {
            const result = await host('appside.zml.detach', [appId]);
            if (appSideCallbacks.get(appId) === hooks) {
              Object.values(hooks).forEach(id => delete callbacks[id]);
              appSideCallbacks.delete(appId);
            }
            return result;
          },
        };
        const hooks = {};
        for (const name of ['onInit', 'onRun', 'onDestroy', 'onRequest', 'onCall']) {
          if (typeof options[name] === 'function') {
            hooks[name] = registerCallback(name === 'onRequest'
              ? (request) => new Promise(resolve => {
                  let settled = false;
                  const respond = (error, result) => {
                    if (settled) return;
                    settled = true;
                    resolve(error == null ? {result} : {error});
                  };
                  Promise.resolve(options[name].call(context, request, respond))
                    .then(value => {
                      if (!settled && value !== undefined) {
                        settled = true;
                        resolve({result: value});
                      }
                    })
                    .catch(error => respond({
                      code: 'PLUGIN_HOOK_FAILED',
                      message: String(error && error.message || error),
                    }));
                })
              : (...args) => options[name].call(context, ...args));
          }
        }
        try {
          await host('appside.zml.attach', [appId, hooks]);
          Object.values(appSideCallbacks.get(appId) || {}).forEach(id => delete callbacks[id]);
          appSideCallbacks.set(appId, hooks);
          return Object.freeze(context);
        } catch (error) {
          Object.values(hooks).forEach(id => delete callbacks[id]);
          throw error;
        }
      },
    },
    ui: (() => {
      const n = (type, props, children) => {
        const p = {};
        for (const [k, v] of Object.entries(props || {})) {
          p[k] = typeof v === 'function' ? registerCallback(v, true) : v;
        }
        return { type, props: p, children: children || [] };
      };
      const e = (type) => (...args) => {
        const props = args.length === 2 ? args[0] : {};
        const kids = args.length === 2 ? args[1] : args[0];
        const arr = Array.isArray(kids) ? kids : kids != null ? [kids] : [];
        return n(type, props, arr);
      };
      return {
        render: (tree) => publishUi('ui.render', tree),
        update: (nodes) => publishUi('ui.update', nodes),
        openPage: (tree) => publishUi('ui.openPage', tree),
        openExternal: (url) => host('ui.openExternal', [url]),
        getRenderSize: () => host('ui.getRenderSize'),
        dialog: (opts) => host('ui.dialog', [opts]),
        callback: registerCallback,
        action: (fn, render) => registerCallback(async (...args) => {
          const result = await fn(...args);
          if (typeof render === 'function') await render();
          return result;
        }),
        Column: e('Column'), Row: e('Row'), LazyColumn: e('LazyColumn'),
        Spacer: () => n('Spacer', {}, []),
        Text: (value, p) => n('Text', { value, ...p }, []),
        Button: (label, p) => n('Button', { text: label, ...p }, []),
        Image: (src, p) => n('Image', { src, ...p }, []),
        Divider: (p) => n('Divider', p || {}, []),
        HtmlDocument: (p) => n('HtmlDocument', p || {}, []),
        Badge: (p, child) => n('Badge', p || {}, [child]),
        TextField: (p) => n('TextField', p || {}, []),
        Switch: (checked, p) => n('Switch', { checked, ...p }, []),
        Checkbox: (checked, p) => n('Checkbox', { checked, ...p }, []),
        Slider: (value, p) => n('Slider', { value, ...p }, []),
        Dropdown: (value, p) => n('Dropdown', { value, ...p }, []),
        Card: (p, child) => n('Card', p || {}, [child]),
        Modal: (p, child) => n('Modal', p || {}, [child]),
        Tooltip: (p, child) => n('Tooltip', p || {}, [child]),
        Tabs: (p) => n('Tabs', p || {}, []),
        TabContent: (tabId, activeId, child) => n('TabContent', { tabId, activeId }, [child]),
        CircularProgress: (p) => n('CircularProgress', p || {}, []),
        LinearProgress: (value, p) => n('LinearProgress', { value, ...p }, []),
      };
    })(),
    wasm: {
      load: async (path, options) => {
        const id = await host('wasm.load', [path, options]);
        return Object.freeze({
          id,
          call: (name, ...args) => host('wasm.call', [id, name, args]),
          readMemory: (offset, length, memory = 'memory') =>
            host('wasm.memory.read', [id, memory, offset, length]),
          writeMemory: (offset, data, memory = 'memory') =>
            host('wasm.memory.write', [id, memory, offset, data]),
          dispose: () => host('wasm.dispose', [id]),
        });
      },
    },
  };

  Object.defineProperty(globalThis, 'OronBox', {
    value: Object.freeze(api),
    writable: false,
    configurable: false,
  });

  globalThis.__obInvokeRegistered = async (id, args) => {
    const callback = callbacks[id];
    if (typeof callback !== 'function') throw new Error(`Callback not found: ${id}`);
    return await callback(...args);
  };
  globalThis.__obDispatchEvent = async (name, payload) => {
    const callback = events[name];
    if (typeof callback === 'function') await callback(payload);
  };
  globalThis.__obFireTimer = async (id) => {
    const timer = timers[id];
    if (!timer) return;
    if (!timer.repeat) delete timers[id];
    await timer.fn();
  };
  globalThis.__obStartPlugin = async () => {
    if (typeof globalThis.activate === 'function') await globalThis.activate(PLUGIN);
  };
})();
''';
