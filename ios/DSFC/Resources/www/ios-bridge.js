/*!
 * ios-bridge.js — iOS 版网络桥（由 build_www_bridge.py 生成，请勿手工修改）
 *
 * 与 android-bridge.js 接口完全一致：
 *   fetch / XHR 之外的部分（__dsfcBridgeHead / __dsfcBridgeChunk / __dsfcBridgeDone）
 * 均由原生 WebShell 回调，页面代码无需改动。
 */
(function () {
  'use strict';
  if (window.__dsfcBridgeInstalled) return;
  window.__dsfcBridgeInstalled = true;

  var N = window.DSFC_NATIVE;
  if (!N || typeof N.http !== 'function') {
    console.warn('[dsfc] DSFC_NATIVE 未注入，网络请求将直接失败');
    return;
  }
  if (typeof window.__dsfcSetScope === 'function') window.__dsfcSetScope('main');

  var seq = 0;
  var jobs = {};          // id -> job
  // 注意：先存下系统原生的 fetch，后面会被包装成桥接版本，内部不再引用它
  var nativeFetch = typeof window.fetch === 'function' ? window.fetch.bind(window) : null;
  var NativeResponse = window.Response;
  var NativeFileReader = typeof FileReader === 'function' ? FileReader : null;
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  // ---------------------------------------------------------------- 工具
  function toBase64(u8) {
    var out = '';
    var i = 0;
    var len = u8.length;
    for (; i + 2 < len; i += 3) {
      var n = (u8[i] << 16) | (u8[i + 1] << 8) | u8[i + 2];
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
    }
    if (i < len) {
      if (i + 1 < len) {
        var m = (u8[i] << 16) | (u8[i + 1] << 8);
        out += B64[(m >> 18) & 63] + B64[(m >> 12) & 63] + B64[(m >> 6) & 63] + '=';
      } else {
        var k = u8[i] << 16;
        out += B64[(k >> 18) & 63] + B64[(k >> 12) & 63] + '==';
      }
    }
    return out;
  }

  function fromBase64(b64) {
    if (!b64) return new Uint8Array(0);
    var clean = String(b64).replace(/[^A-Za-z0-9+/]/g, '');
    var pad = clean.length % 4;
    if (pad) clean += pad === 2 ? '==' : '=';
    var bin = atob(clean);
    var u8 = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    return u8;
  }

  function strToBytes(text) {
    var s = String(text == null ? '' : text);
    var out = new Uint8Array(s.length * 4);
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c < 0x80) {
        out[n++] = c;
      } else if (c < 0x800) {
        out[n++] = 0xc0 | (c >> 6);
        out[n++] = 0x80 | (c & 63);
      } else if (c >= 0xd800 && c < 0xdc00) {
        var c2 = s.charCodeAt(++i);
        var cp = 0x10000 + ((c - 0xd800) << 10) + ((c2 - 0xdc00) & 1023);
        out[n++] = 0xf0 | (cp >> 18);
        out[n++] = 0x80 | ((cp >> 12) & 63);
        out[n++] = 0x80 | ((cp >> 6) & 63);
        out[n++] = 0x80 | (cp & 63);
      } else {
        out[n++] = 0xe0 | (c >> 12);
        out[n++] = 0x80 | ((c >> 6) & 63);
        out[n++] = 0x80 | (c & 63);
      }
    }
    return out.slice(0, n);
  }

  function concatBytes(parts) {
    var total = 0;
    for (var i = 0; i < parts.length; i++) total += parts[i] ? parts[i].length : 0;
    var out = new Uint8Array(total);
    var at = 0;
    for (var j = 0; j < parts.length; j++) {
      if (!parts[j] || !parts[j].length) continue;
      out.set(parts[j], at);
      at += parts[j].length;
    }
    return out;
  }

  function bytesToText(bytes) {    try { return new TextDecoder('utf-8').decode(bytes); } catch (e) {
      return new TextDecoder().decode(bytes);
    }
  }

  function isAbsoluteHttp(url) {
    return /^https?:\/\//i.test(String(url || ''));
  }

  function headersToObject(headers) {
    var out = {};
    if (!headers) return out;
    try {
      if (typeof headers.forEach === 'function' && typeof headers.get === 'function') {
        headers.forEach(function (v, k) { out[k] = v; });
      } else if (Array.isArray(headers)) {
        headers.forEach(function (pair) { out[pair[0]] = pair[1]; });
      } else {
        Object.keys(headers).forEach(function (k) { out[k] = headers[k]; });
      }
    } catch (e) { /* ignore */ }
    return out;
  }

  function requestBodyHasStream(text) {
    return /"stream"\s*:\s*true/.test(text || '');
  }

  // 原生已经把正文整包 base64 带回来了：优先用它，避免累积时丢字节
  function decodeBodyB64(b64) {
    try {
      if (!b64) return null;
      var bin = atob(String(b64));
      var out = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out;
    } catch (e) { return null; }
  }

  // ---------------------------------------------------------------- 请求体
  function readBlob(blob) {
    if (blob && typeof blob.arrayBuffer === 'function') {
      return blob.arrayBuffer().then(function (ab) { return new Uint8Array(ab); }).then(function (bytes) {
        // 个别环境里 Blob.arrayBuffer() 会返回空缓冲，这时退回 FileReader
        if (bytes && bytes.length) return bytes;
        return readViaFileReader(blob);
      });
    }
    return readViaFileReader(blob);
  }

  // FormData 的正文：让 Request 自己编码出带 boundary 的 multipart，再逐段手工拼装。
  // 不直接用 body.arrayBuffer()，因为个别环境会返回空缓冲导致上传内容丢失。
  function readFormDataBody(request, form) {
    var boundary = '';
    try { boundary = (request.headers.get('content-type') || '').split('boundary=')[1] || ''; } catch (e) { boundary = ''; }
    if (!boundary) boundary = '----DSFCForm' + Math.random().toString(16).slice(2);
    boundary = boundary.replace(/;\s*$/, '');
    var parts = [];
    var pending = [];
    var entries = [];
    try {
      if (form && typeof form.entries === 'function') {
        var it = form.entries();
        for (var step = it.next(); !step.done; step = it.next()) entries.push(step.value);
      } else if (typeof form.forEach === 'function') {
        form.forEach(function (value, key) { entries.push([key, value]); });
      } else if (form && Array.isArray(form.parts)) {
        form.parts.forEach(function (p) { entries.push([p.name, p.value]); });
      }
    } catch (e) { return Promise.reject(e); }
    try {
      entries.forEach(function (entry) {
        var key = entry[0];
        var value = entry[1];
        var head = '--' + boundary + '\r\n';
        if (typeof Blob !== 'undefined' && value instanceof Blob) {
          var filename = value.name || 'blob';
          head += 'Content-Disposition: form-data; name="' + key.replace(/"/g, '%22') +
            '"; filename="' + String(filename).replace(/"/g, '%22') + '"\r\n';
          head += 'Content-Type: ' + (value.type || 'application/octet-stream') + '\r\n\r\n';
          parts.push(strToBytes(head));
          parts.push(null); // 占位，等全部 FileReader 读完再一次性拼起来，保证顺序
          pending.push(readViaFileReader(value));
          parts.push(strToBytes('\r\n'));
        } else {
          head += 'Content-Disposition: form-data; name="' + key.replace(/"/g, '%22') + '"\r\n\r\n';
          parts.push(strToBytes(head));
          parts.push(strToBytes(String(value)));
          parts.push(strToBytes('\r\n'));
        }
      });
    } catch (e) { return Promise.reject(e); }
    return Promise.all(pending).then(function (blobs) {
      for (var i = 0, j = 0; i < parts.length; i++) {
        if (parts[i] === null) parts[i] = blobs[j++];
      }
      parts.push(strToBytes('--' + boundary + '--\r\n'));
      return concatBytes(parts);
    });
  }

  function readViaFileReader(blob) {
    return new Promise(function (resolve, reject) {
      // 必须在保存下来的原始构造器上 new，不能依赖全局 FileReader 变量
      if (!NativeFileReader) { reject(new Error('read body failed')); return; }
      var reader = new NativeFileReader();
      reader.onload = function () { resolve(new Uint8Array(reader.result)); };
      reader.onerror = function () { reject(reader.error || new Error('read body failed')); };
      reader.readAsArrayBuffer(blob);
    });
  }

  var USE_FILE_READER_SYNC = false;
  try { USE_FILE_READER_SYNC = typeof FileReaderSync === 'function'; } catch (e) { USE_FILE_READER_SYNC = false; }

  function readBlobSync(blob) {
    if (!USE_FILE_READER_SYNC) return null;
    try { return new Uint8Array(new FileReaderSync().readAsArrayBuffer(blob)); } catch (e) { return null; }
  }

  // 返回 Promise<{ headers, body, binary }>
  function prepareBody(req) {
    var body = req && req.body;
    if (body === null || body === undefined) {
      return Promise.resolve({ headers: {}, body: '', binary: false });
    }
    if (typeof body === 'string') {
      return Promise.resolve({ headers: {}, body: body, binary: false });
    }
    if (typeof FormData !== 'undefined' && body instanceof FormData) {
      var started = Date.now();
      var syncBytes = readBlobSync(body);
      if (syncBytes && Date.now() - started < 1000) {
        // 同步通道可用（Worker 环境）：保持安卓版一样的同步语义
        var syncRequest = new Request('https://dsfc.local/', { method: 'POST', body: body });
        var syncType = syncRequest.headers.get('content-type') || '';
        return Promise.resolve({
          headers: syncType ? { 'Content-Type': syncType } : {},
          body: JSON.stringify({ __dsfcForm: 1, contentType: syncType, body: toBase64(syncBytes) }),
          binary: true
        });
      }
      var request = new Request('https://dsfc.local/', { method: 'POST', body: body });
      var contentType = request.headers.get('content-type') || '';
      return readFormDataBody(request, body).then(function (bytes) {
        return {
          headers: contentType ? { 'Content-Type': contentType } : {},
          body: JSON.stringify({ __dsfcForm: 1, contentType: contentType, body: toBase64(bytes) }),
          binary: true
        };
      });
    }
    if (body instanceof ArrayBuffer || (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView(body))) {
      var view = body instanceof ArrayBuffer ? new Uint8Array(body) : new Uint8Array(body.buffer, body.byteOffset, body.byteLength);
      return Promise.resolve({ headers: {}, body: toBase64(view), binary: true });
    }
    if (typeof Blob !== 'undefined' && body instanceof Blob) {
      return readBlob(body).then(function (bytes) {
        return { headers: {}, body: toBase64(bytes), binary: true };
      });
    }
    if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
      return Promise.resolve({
        headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
        body: body.toString(),
        binary: false
      });
    }
    if (body && typeof body === 'object') {
      return Promise.resolve({ headers: {}, body: JSON.stringify(body), binary: false });
    }
    return Promise.resolve({ headers: {}, body: String(body), binary: false });
  }

  // ---------------------------------------------------------------- 原生回调
  function push(job, bytes) {
    if (!job || !bytes || !bytes.length) return;
    try {
      if (job.controller && job.controller.enqueue(bytes)) return;
    } catch (e) { /* 队列已关闭：只累积 */ }
    job.buffers.push(bytes);
  }

  function enqueueIntoStream(job, bytes) {
    if (!bytes || !bytes.length || !job.controller) return;
    try { job.controller.enqueue(bytes); } catch (e) { /* ignore */ }
  }

  window.__dsfcBridgeHead = function (id, status, headersJson) {
    var job = jobs[id];
    if (!job) return;
    if (job.headed) return;
    job.headed = true;
    job.status = status;
    try { job.headers = JSON.parse(headersJson || '{}'); } catch (e) { job.headers = {}; }
    if (job.live && job.controller && !job.responded) {
      job.responded = true;
      var stream = new ReadableStream({
        start: function (c) { job.controller = c; }
      }, { highWaterMark: 0 });
      // 头部到达之前已经收到的块，按顺序补进去
      var pending = job.buffers;
      job.buffers = [];
      pending.forEach(function (bytes) {
        try { job.controller.enqueue(bytes); } catch (e) { /* ignore */ }
      });
      job.resolve(buildResponse(job, null, stream));
    }
  };

  window.__dsfcBridgeChunk = function (id, b64) {
    var job = jobs[id];
    if (!job) return;
    var bytes = fromBase64(b64);
    if (job.live && job.controller) {
      enqueueIntoStream(job, bytes);
    } else {
      job.buffers.push(bytes);
    }
  };

  window.__dsfcBridgeDone = function (id, status, headersJson, bodyB64, binary) {
    var job = jobs[id];
    if (!job) return;
    delete jobs[id];
    var finalStatus = status;
    try { job.headers = JSON.parse(headersJson || '{}'); } catch (e) { /* ignore */ }
    if (finalStatus >= 0) job.status = finalStatus;

    if (job.live) {
      if (status < 0) {
        if (!job.responded) {
          job.settled = true;
          job.reject(new Error(extractNetError(bodyB64) || 'NETERR'));
        } else {
          try { job.controller.close(); } catch (e) { /* ignore */ }
        }
        return;
      }
      if (!job.responded) {
        job.responded = true;
        var stream = new ReadableStream({
          start: function (c) {
            job.controller = c;
            job.buffers.forEach(function (bytes) {
              try { c.enqueue(bytes); } catch (e) { /* ignore */ }
            });
            job.buffers = [];
            try { c.close(); } catch (e) { /* ignore */ }
          }
        });
        job.settled = true;
        job.resolve(buildResponse(job, null, stream));
        return;
      }
      try { job.controller.close(); } catch (e) { /* ignore */ }
      return;
    }

    if (status < 0) {
      job.settled = true;
      job.reject(new Error(extractNetError(bodyB64) || 'NETERR'));
      return;
    }
    var collected = job.buffers.reduce(function (total, item) { return total + item.length; }, 0);
    var all = new Uint8Array(collected);
    var offset = 0;
    job.buffers.forEach(function (item) { all.set(item, offset); offset += item.length; });
    var decoded = decodeBodyB64(bodyB64);
    if (decoded) all = decoded;
    job.settled = true;
    job.resolve(buildResponse(job, all, null));
  };

  function extractNetError(b64) {
    try {
      var text = bytesToText(fromBase64(b64 || ''));
      if (text.indexOf('NETERR|') === 0) return text.slice(7) || 'NETERR';
    } catch (e) { /* ignore */ }
    return '';
  }

  function buildResponse(job, bytes, stream) {
    var headers = new window.Headers();
    Object.keys(job.headers || {}).forEach(function (key) {
      try { headers.set(key, job.headers[key]); } catch (e) { /* ignore */ }
    });
    var options = { status: job.status || 200, statusText: '', headers: headers };
    if (stream) {
      options.body = stream;
      options.duplex = 'half';
    } else {
      options.body = bytes;
    }
    if (NativeResponse) {
      try { return new NativeResponse(options.body, options); } catch (e) { /* 退回自实现 */ }
    }
    return fakeResponse(options, bytes, stream);
  }

  // 极旧系统没有 Response 时的兜底实现
  function fakeResponse(options, bytes, stream) {
    var self = {};
    var consumed = false;
    self.ok = options.status >= 200 && options.status < 300;
    self.status = options.status;
    self.statusText = '';
    self.headers = options.headers;
    self.url = '';
    self.type = 'basic';
    self.body = stream || null;
    self.bodyUsed = false;
    self.text = function () {
      if (consumed) return Promise.resolve('');
      consumed = true; self.bodyUsed = true;
      return Promise.resolve(bytes ? bytesToText(bytes) : '');
    };
    self.json = function () { return self.text().then(function (t) { return JSON.parse(t); }); };
    self.arrayBuffer = function () {
      if (consumed) return Promise.resolve(new ArrayBuffer(0));
      consumed = true; self.bodyUsed = true;
      return Promise.resolve((bytes || new Uint8Array(0)).buffer);
    };
    self.blob = function () { return self.arrayBuffer().then(function (ab) { return new Blob([ab]); }); };
    self.clone = function () { return self; };
    return self;
  }

  // ---------------------------------------------------------------- fetch
  function bridgeFetch(input, init) {
    var config = init || {};
    var req = input;
    if (typeof Request !== 'undefined' && input instanceof Request && !init) {
      config = {
        method: input.method,
        headers: input.headers,
        body: input.body,
        signal: input.signal,
        mode: input.mode
      };
      // Request.body 是只读流，真正读取需要先 clone
      try { req = input.clone(); config.body = req.body; } catch (e) { /* ignore */ }
      try { req = input.clone(); } catch (e) { req = input; }
    }
    var url;
    if (typeof input === 'string') url = input;
    else if (input && input.url) url = input.url;
    else url = String(input);

    var method = (config.method || (input && input.method) || 'GET').toUpperCase();
    var headers = headersToObject(config.headers || (input && input.headers));
    var signal = config.signal;

    if (!isAbsoluteHttp(url)) {
      if (nativeFetch) return nativeFetch(input, init);
      return Promise.reject(new Error('DSFC: 不支持的请求地址 ' + url));
    }

    var id = 'r' + (++seq).toString(36) + Math.random().toString(36).slice(2, 7);
    var job = {
      id: id,
      live: false,
      headed: false,
      responded: false,
      settled: false,
      status: 0,
      headers: {},
      buffers: [],
      controller: null
    };

    return new Promise(function (resolve, reject) {
      job.resolve = function (value) {
        if (!job.settled) { job.settled = true; }
        resolve(value);
      };
      job.reject = function (error) {
        // 注意：取消时也必须 reject，否则页面上的 fetch 永远悬着（流式对话会卡住）
        reject(error);
      };
      prepareBody({ method: method, body: config.body })
        .then(function (prepared) {
          var merged = {};
          Object.keys(headers).forEach(function (k) { merged[k] = headers[k]; });
          Object.keys(prepared.headers).forEach(function (k) {
            var exists = Object.keys(merged).some(function (m) { return m.toLowerCase() === k.toLowerCase(); });
            if (!exists) merged[k] = prepared.headers[k];
          });
          var text = prepared.binary ? '' : String(prepared.body || '');
          job.live = requestBodyHasStream(text) || /text\/event-stream/i.test(merged['Accept'] || '') ||
            /text\/event-stream/i.test(merged['accept'] || '');
          jobs[id] = job;
          if (signal) {
            if (signal.aborted) { cancelJob(id, job); return; }
            signal.addEventListener('abort', function () { cancelJob(id, job); }, { once: true });
          }
          if (job.live) {
            // 流式响应：先建立流，等头部
            job.controller = null;
            job.pending = new ReadableStream({
              start: function (c) { job.controller = c; }
            }, { highWaterMark: 0 });
            // 头部可能比 start 早到：交给 __dsfcBridgeHead 延迟补发
            var pendingBytes = job.buffers;
            job.buffers = [];
            job.pendingBytes = pendingBytes;
          }
          try {
            N.http(id, method, url, JSON.stringify(merged), prepared.body || '', !!prepared.binary);
          } catch (e) {
            delete jobs[id];
            reject(e);
          }
        })
        .catch(function (error) {
          delete jobs[id];
          reject(error);
        });
    });
  }

  function cancelJob(id, job) {
    if (!job || job.cancelled) return;
    job.cancelled = true;
    delete jobs[id];
    try {
      if (job.controller) job.controller.close();
    } catch (e) { /* ignore */ }
    try { N.cancelAll(); } catch (e) { /* ignore */ }
    if (!job.settled) {
      job.settled = true;
      job.reject(Object.assign(new Error('请求已取消'), { name: 'AbortError' }));
    }
  }

  if (NativeResponse || window.fetch) {
    window.fetch = function (input, init) {
      try {
        return bridgeFetch(input, init);
      } catch (error) {
        return Promise.reject(error);
      }
    };
  }
})();
