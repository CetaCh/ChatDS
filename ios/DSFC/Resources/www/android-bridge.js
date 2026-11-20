/* =====================================================================
   DS-FC 安卓外壳的跨域转发
   只在 APK 里注入（网页版没有这个文件）。
   WebView 的页面源是 file://，直接 fetch 第三方 API 会被 CORS 拦下；
   这里把 fetch 改写成走原生 DSFC_NATIVE.http()，由 Java 层用
   HttpURLConnection 发出请求，再把结果包装成标准 Response 交还给网页。
   正文是 base64 传输，二进制安全；流式接口会整段读完再返回。
   ===================================================================== */
(function () {
  'use strict';
  var NATIVE = window.DSFC_NATIVE;
  if (!NATIVE || typeof NATIVE.http !== 'function' || window.DSFC_BRIDGE) return;
  window.DSFC_BRIDGE = true;

  var seq = 0;
  var waiting = {};

  function decodeB64(b64) {
    var bin = atob(b64);
    var len = bin.length;
    var bytes = new Uint8Array(len);
    for (var i = 0; i < len; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }

  function encodeUtf8(str) {
    var out = unescape(encodeURIComponent(str || ''));
    var bytes = new Uint8Array(out.length);
    for (var i = 0; i < out.length; i++) bytes[i] = out.charCodeAt(i);
    return bytes;
  }

  function textDecoder() {
    if (typeof TextDecoder !== 'undefined') return new TextDecoder('utf-8');
    return {
      decode: function (buf) {
        var s = '';
        for (var i = 0; i < buf.length; i++) s += String.fromCharCode(buf[i]);
        try { return decodeURIComponent(escape(s)); } catch (e) { return s; }
      }
    };
  }

  function arrayBufferOf(bytes) {
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  }

  // 流式分块：原生边读边推过来的 base64 片段
  var chunkHandlers = {};
  // 流式开始：状态码 + 响应头
  var headHandlers = {};
  window.__dsfcBridgeHead = function (id, status, hjson) {
    var h = headHandlers[id];
    if (h) { try { h(status, hjson); } catch (e) { /* ignore */ } }
    delete headHandlers[id];
  };

  window.__dsfcBridgeChunk = function (id, b64) {
    var h = chunkHandlers[id];
    if (!h) return;
    try { h(decodeB64(b64 || '')); } catch (e) { /* ignore */ }
  };

  window.__dsfcBridgeDone = function (id, status, headersJson, bodyB64, binary) {
    var cb = waiting[id];
    if (!cb) return;
    delete waiting[id];
    cb(status, headersJson, bodyB64, binary);
  };

  var origFetch = window.fetch ? window.fetch.bind(window) : null;

  window.fetch = function (input, init) {
    init = init || {};
    var url = typeof input === 'string' ? input : (input && input.url) || String(input);
    var method = (init.method || (input && input.method) || 'GET').toUpperCase();

    // 只转发发往 http(s) 的请求；本地 file:// 资源、data: 等继续走原生 fetch
    if (!/^https?:\/\//i.test(url)) {
      if (origFetch) return origFetch(input, init);
      return Promise.reject(new TypeError('不支持该地址：' + url));
    }

    var headersJson = '{}';
    var h = init.headers || (input && input.headers) || {};
    try {
      var obj = {};
      if (typeof h.forEach === 'function' && !Array.isArray(h)) {
        h.forEach(function (value, name) { obj[name] = value; });
      } else if (Array.isArray(h)) {
        h.forEach(function (pair) { if (pair && pair.length === 2) obj[pair[0]] = pair[1]; });
      } else {
        Object.keys(h).forEach(function (k) { obj[k] = h[k]; });
      }
      headersJson = JSON.stringify(obj);
    } catch (e) { headersJson = '{}'; }

    var body = null;
    if (typeof init.body === 'string') body = init.body;
    else if (init.body instanceof FormData) {
      // FormData -> multipart/form-data 文本（语音识别上传音频走这条路）
      var boundary = '----DSFCForm' + Date.now().toString(36) + Math.random().toString(36).slice(2);
      var parts = [];
      try {
        init.body.forEach(function (value, key) {
          if (typeof value === 'string') {
            parts.push('--' + boundary + '\r\n' +
              'Content-Disposition: form-data; name="' + key + '"\r\n\r\n' +
              value + '\r\n');
          } else {
            var filename = value.name || 'file';
            var mime = value.type || 'application/octet-stream';
            var reader = new FileReaderSync();
            var dataUrl = reader.readAsDataURL(value);
            var base64 = dataUrl.slice(dataUrl.indexOf(',') + 1);
            parts.push('--' + boundary + '\r\n' +
              'Content-Disposition: form-data; name="' + key + '"; filename="' + filename + '"\r\n' +
              'Content-Type: ' + mime + '\r\n' +
              'Content-Transfer-Encoding: base64\r\n\r\n' +
              base64 + '\r\n');
          }
        });
      } catch (e) { /* ignore */ }
      parts.push('--' + boundary + '--\r\n');
      body = parts.join('');
      try {
        var ho = JSON.parse(headersJson);
        ho['content-type'] = 'multipart/form-data; boundary=' + boundary;
        headersJson = JSON.stringify(ho);
      } catch (e) { /* ignore */ }
    }
    else if (init.body && init.body.type === 'application/x-www-form-urlencoded') body = init.body;

    var id = 'r' + (++seq);
    var signal = init.signal;

    return new Promise(function (resolve, reject) {
      var finished = false;
      var aborted = false;
      if (signal) {
        if (signal.aborted) { reject(abortError()); return; }
        if (signal.addEventListener) {
          signal.addEventListener('abort', function () {
            if (aborted) return;
            aborted = true;
            delete waiting[id];
            delete chunkHandlers[id];
            delete headHandlers[id];
            // 真正断开原生连接，停止后台继续拉取（避免继续计费）
            // 断开原生连接，停止后台继续拉取
            try { if (NATIVE.cancelAll) NATIVE.cancelAll(); } catch (e) { /* ignore */ }
            reject(abortError());
          });
        }
      }
      // 实时流：原生边读边推 chunk，桥立刻转成字节流交给页面
      var liveCtrl = null;
      var liveClosed = false;
      var livePending = [];
      var liveStream = null;
      if (typeof ReadableStream !== 'undefined') {
        liveStream = new ReadableStream({
          start: function (c) {
            liveCtrl = c;
            for (var i = 0; i < livePending.length; i++) {
              try { c.enqueue(new Uint8Array(livePending[i])); } catch (e) {}
            }
            livePending = [];
          }
        }, { highWaterMark: 0 });
      }
      var liveBytes = 0;
      var liveMode = false;
      var collectedAll = [];
      var bodyStream = null;
      var wantsLive = /"stream"\s*:\s*true/.test(body || '');
      chunkHandlers[id] = function (bytes) {
        liveBytes += bytes.length;
        if (liveCtrl) {
          try { liveCtrl.enqueue(new Uint8Array(bytes)); } catch (e) {}
        } else {
          livePending.push(bytes);
        }
      };

      // ---------- 官方原版方式：等原生读完，把完整数据包成流 ----------
      // demo 的 SSE 解析器按块读取，这里把整段文本切块喂进去即可。
      // response 对象（两条路径共用）；流式请求先返回它
      var hdrs = {};
      var headersObj = {
        get: function (name) {
          var k = String(name || '').toLowerCase();
          for (var key in hdrs) { if (key.toLowerCase() === k) return hdrs[key]; }
          return null;
        },
        has: function (name) { return this.get(name) !== null; }
      };
      var response = {
        ok: true, status: 200, statusText: '', headers: headersObj, url: url,
        type: 'basic', redirected: false, bodyUsed: false,
        clone: function () { return response; },
        text: function () { return Promise.resolve(new textDecoder().decode(finalBytes())); },
        json: function () { return response.text().then(function (t) { return JSON.parse(t); }); },
        arrayBuffer: function () { return Promise.resolve(finalBytes().buffer); },
        blob: function () { return Promise.resolve(new Blob([finalBytes()], { type: hdrs['content-type'] || 'application/octet-stream' })); }
      };
      var fullBytes = null;
      function finalBytes() {
        if (fullBytes) return fullBytes;
        var total = 0, i;
        for (i = 0; i < collectedAll.length; i++) total += collectedAll[i].length;
        var out = new Uint8Array(total), off = 0;
        for (i = 0; i < collectedAll.length; i++) { out.set(collectedAll[i], off); off += collectedAll[i].length; }
        return out;
      }
      Object.defineProperty(response, 'body', {
        get: function () {
          if (typeof ReadableStream === 'undefined') return null;
          if (bodyStream) return bodyStream;
          // 流式请求用实时流（可以等待，数据陆续推入）
          if (wantsLive) {
            if (liveStream) { bodyStream = liveStream; return bodyStream; }
            return null;
          }
          // 非流式请求（TTS 音频、/models、错误响应）：整段一次性返回，
          // 不做节奏切分，否则收完整数据会拖很久
          var all = finalBytes();
          bodyStream = new ReadableStream({
            start: function (c) {
              try { c.enqueue(new Uint8Array(all)); } catch (e) {}
              try { c.close(); } catch (e) {}
            }
          });
          return bodyStream;
          // 回退：把完整内容按节奏切块
          var bytes = finalBytes();
          var full = new textDecoder().decode(bytes) || '';
          var total = full.length;
          var CHUNK = total > 8000 ? 160 : total > 2000 ? 80 : 40;
          var pos = 0;
          bodyStream = new ReadableStream({
            start: function (c) {
              function tick() {
                if (pos >= total) { try { c.close(); } catch (e) {} return; }
                var end = Math.min(total, pos + CHUNK);
                var nl = full.indexOf('\n', end);
                if (nl > 0 && nl - end < CHUNK) end = nl + 1;
                try { c.enqueue(encodeUtf8(full.slice(pos, end))); } catch (e) { return; }
                pos = end;
                setTimeout(tick, 30);
              }
              setTimeout(tick, 30);
            }
          });
          return bodyStream;
        }
      });

      if (wantsLive) {
        // 流式：立刻返回，头部先占位 SSE，数据随后通过实时流到达
        hdrs['content-type'] = 'text/event-stream';
        response.headers = headersObj;
        resolve(response);
      }

      waiting[id] = function (status, hjson, b64, binary) {
        if (finished) return;
        finished = true;
        delete chunkHandlers[id];
        delete headHandlers[id];
        delete waiting[id];
        // 关闭实时流
        if (liveCtrl && !liveClosed) {
          for (var pi = 0; pi < livePending.length; pi++) {
            try { liveCtrl.enqueue(new Uint8Array(livePending[pi])); } catch (e) {}
          }
          livePending = [];
          liveClosed = true;
          try { liveCtrl.close(); } catch (e) {}
        }
        // 记录完整内容（供 text()/json() 与回退流使用）
        try { if (b64) collectedAll.push(decodeB64(b64)); } catch (e) {}
        try {
          var parsed = JSON.parse(hjson || '{}');
          for (var hk in parsed) hdrs[hk] = parsed[hk];
        } catch (e) {}
        // 只有 SSE 才保持 event-stream 标记；其他类型（如 OpenAI 的 json 流）用真实类型
        if (wantsLive && !hdrs['content-type']) hdrs['content-type'] = 'text/event-stream';
        response.status = status;
        response.ok = status >= 200 && status < 300;
        if (!wantsLive) {
          if (status < 0) reject(new TypeError('网络请求失败'));
          else resolve(response);
        }
      };

      try {
        NATIVE.http(id, method, url, headersJson, body, false);
      } catch (e) {
        delete waiting[id];
        reject(new TypeError('原生转发不可用：' + (e && e.message)));
      }
    });
  };

  function abortError() {
    try { return new DOMException('The operation was aborted.', 'AbortError'); }
    catch (e) {
      var err = new Error('aborted');
      err.name = 'AbortError';
      return err;
    }
  }
})();
