#!/usr/bin/env node
/* 在 Node 里模拟 WKWebView（DSFC_NATIVE + ReadableStream + base64），
 * 跑一遍 ios-bridge.js 的关键路径。

模拟对象：
  * DSFC_NATIVE —— 只实现 http/cancelAll，按 Net.swift 的语义回调
    __dsfcBridgeHead / __dsfcBridgeChunk / __dsfcBridgeDone
  * TextDecoder / atob / btoa / ReadableStream —— 用 Node 自带的实现挂到 window
  * Response / Headers / Request / FormData / Blob —— 由 jsdom 或 Node 提供

* 用法：node test_ios_bridge.js
*/

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const util = require('util');

// 必须用 Node 自带的实现：自写的类实例在 vm 沙箱里 typeof 不是 'function'，会被 ios-bridge 当成“没有”
const NodeTextEncoder = util.TextEncoder;
const NodeTextDecoder = util.TextDecoder;

const WWW = path.join(__dirname, 'DSFC', 'Resources', 'www');
const results = [];

function check(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log((ok ? '[OK]   ' : '[FAIL] ') + name + (detail ? '  ' + detail : ''));
}

function makeFormDataFrame(boundary, name, filename, contentType, bytes) {
  const head = Buffer.from(
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="' + name + '"; filename="' + filename + '"\r\n' +
    'Content-Type: ' + contentType + '\r\n\r\n', 'utf8');
  const tail = Buffer.from('\r\n', 'utf8');
  const parts = [];
  parts.push(head);
  parts.push(Buffer.from(bytes));
  parts.push(tail);
  return Buffer.concat(parts);
}

// ---------------------------------------------------------------- 构造环境
const hasJsdom = (() => {
  try { require.resolve('jsdom', { paths: [__dirname] }); return true; } catch (e) { return false; }
})();
console.log('jsdom 可用: ' + hasJsdom);

let sandbox;

function buildWebLike() {
  // 最小 Web 对象集合，不依赖 jsdom
  const { TextEncoder: NodeTextEncoder, TextDecoder: NodeTextDecoder } = require('util');
  const { ReadableStream } = require('stream/web');
  const atob = (s) => Buffer.from(s, 'base64').toString('binary');
  const btoa = (s) => Buffer.from(s, 'binary').toString('base64');
  class Headers {
    constructor(init) { this.map = {}; if (init) Object.keys(init).forEach((k) => this.set(k, init[k])); }
    set(k, v) { this.map[String(k).toLowerCase()] = String(v); }
    get(k) { const v = this.map[String(k).toLowerCase()]; return v === undefined ? null : v; }
    has(k) { return Object.prototype.hasOwnProperty.call(this.map, String(k).toLowerCase()); }
    forEach(cb) { Object.keys(this.map).forEach((k) => cb(this.map[k], k)); }
  }
  class Response {
    constructor(body, options) {
      this.status = options && options.status || 200;
      this.ok = this.status >= 200 && this.status < 300;
      this.headers = (options && options.headers) || new Headers();
      this._body = body;
      this.body = body instanceof ReadableStream ? body : null;
    }
    async text() {
      if (this._body instanceof ReadableStream) {
        const reader = this._body.getReader();
        const chunks = [];
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          chunks.push(Buffer.from(value));
        }
        return Buffer.concat(chunks).toString('utf8');
      }
      return Buffer.from(this._body || []).toString('utf8');
    }
    async json() { return JSON.parse(await this.text()); }
  }
  class FormData {
    constructor() { this.parts = []; }
    append(name, value, filename) { this.parts.push({ name, value, filename: filename || (value && value.name) }); }
  }
  // 把 FormData 编成真实的 multipart 正文（浏览器会在发请求时做同样的事）
  function encodeFormData(form, boundary) {
    const chunks = [];
    form.parts.forEach((part) => {
      let head = '--' + boundary + '\r\n';
      if (part.filename) {
        head += 'Content-Disposition: form-data; name="' + part.name + '"; filename="' + part.filename + '"\r\n';
        head += 'Content-Type: ' + (part.value.type || 'application/octet-stream') + '\r\n\r\n';
      } else {
        head += 'Content-Disposition: form-data; name="' + part.name + '"\r\n\r\n';
      }
      chunks.push(Buffer.from(head, 'utf8'));
      chunks.push(Buffer.from(new Uint8Array(part.value instanceof Blob ? blobBytes(part.value) : Buffer.from(String(part.value)))));
      chunks.push(Buffer.from('\r\n', 'utf8'));
    });
    chunks.push(Buffer.from('--' + boundary + '--\r\n', 'utf8'));
    return Buffer.concat(chunks);
  }
  function blobBytes(blob) {
    return Buffer.concat(blob.parts.map((p) => Buffer.from(new Uint8Array(p))));
  }
  // 注意：TextDecoder/TextEncoder 必须用 Node 自带的，自实现的类实例在 vm 沙箱里 typeof 不是 'function'
  let readers = new WeakMap();
  class Blob {
    constructor(parts, options) {
      this.parts = parts || [];
      this.type = options && options.type || '';
    }
    get size() { return Buffer.concat(this.parts.map((p) => Buffer.from(p))).length; }
    arrayBuffer() { return Promise.resolve(new Uint8Array(blobBytes(this)).buffer); }
  }
  // FormData 读取时走 FileReader（和 WKWebView 一样），这里补一个最小实现
  class FileReader {
    readAsArrayBuffer(blob) {
      const bytes = Buffer.concat(blob.parts.map((p) => Buffer.from(new Uint8Array(p))));
      const result = new Uint8Array(bytes).buffer;
      this.result = result;
      setTimeout(() => {
        if (this.onload) this.onload({ target: this });
      }, 0);
    }
  }
  // 模拟浏览器：Request 也能读 FormData 的二进制内容（真实 main 线程没有 FileReaderSync）
  class Request {
    constructor(url, init) {
      this.url = url;
      this.method = init && init.method || 'GET';
      this.body = init && init.body || null;
      const boundary = '----DSFCBoundary' + Math.random().toString(16).slice(2);
      this.headers = new Headers(init && init.body instanceof FormData
        ? { 'content-type': 'multipart/form-data; boundary=' + boundary }
        : {});
      this._body = init && init.body instanceof FormData ? encodeFormData(init.body, boundary) : null;
      this._boundary = boundary;
    }
    arrayBuffer() {
      if (this._body) return Promise.resolve(new Uint8Array(this._body).buffer);
      return Promise.resolve(new Uint8Array(0).buffer);
    }
  }
  return { Headers, Response, FormData, Blob, Request, FileReader, encodeFormData, TextEncoder: NodeTextEncoder, TextDecoder: NodeTextDecoder, ReadableStream, atob, btoa };
}

function createSandbox(httpImpl) {

  const web = buildWebLike();
  const native = {
    http(id, method, url, headers, body, binary) {
      httpImpl({ id, method, url, headers, body, binary });
    },
    cancelAll() { (sandbox.__cancelled = sandbox.__cancelled || []).push(Date.now()); },
    info() { return JSON.stringify({ version: '15.6', versionCode: 113, platform: 'ios', sdk: 0 }); }
  };
  sandbox = {
    console,
    setTimeout,
    clearTimeout,
    Promise,
    JSON,
    Math,
    Date,
    Object,
    Array,
    String,
    Number,
    Error,
    TypeError,
    RegExp,
    Uint8Array,
    ArrayBuffer,
    // 浏览器的额外全局：WKWebView 里这些始终存在，沙箱也要给全，否则桥会以为环境不支持而跳过包装
    URL,
    URLSearchParams: util.URLSearchParams,
    Blob: web.Blob,
    File: class File extends web.Blob {},
    FormDataLikeProbe: true,
    FileReader: web.FileReader,
    FormData: web.FormData,
    Headers: web.Headers,
    Request: web.Request,
    Response: web.Response,
    AbortController: class AbortController {
      constructor() {
        const listeners = [];
        this.signal = {
          aborted: false,
          addEventListener: (type, fn) => { if (type === 'abort') listeners.push(fn); },
          removeEventListener: () => {}
        };
        this._listeners = listeners;
      }
      abort() {
        this.signal.aborted = true;
        this._listeners.forEach((fn) => fn({ type: 'abort' }));
      }
    },
    atob: web.atob,
    btoa: web.btoa,
    TextDecoder: NodeTextDecoder,
    TextEncoder: NodeTextEncoder,
    ReadableStream: web.ReadableStream,
    DSFC_NATIVE: native,
    __dsfcCallbacks: {}
  };
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  const context = vm.createContext(sandbox);
  const code = fs.readFileSync(path.join(WWW, 'ios-bridge.js'), 'utf8');
  vm.runInContext(code, context, { filename: 'ios-bridge.js' });
  return sandbox;
}

function wait(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function testJsonPost() {
  let captured = null;
  const win = createSandbox((req) => { captured = req; });
  const promise = win.fetch('https://api.example.com/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer sk-test' },
    body: JSON.stringify({ model: 'deepseek-chat', messages: [{ role: 'user', content: '你好' }], stream: false })
  });
  await wait(10);
  const headers = JSON.parse(captured.headers);
  check('JSON POST 交给原生', captured.method === 'POST' && captured.url === 'https://api.example.com/v1/chat/completions', captured.url);
  check('JSON POST 头部透传', headers.Authorization === 'Bearer sk-test' && headers['Content-Type'] === 'application/json');
  check('JSON POST 非二进制', captured.binary === false || captured.binary === 0);
  const body = JSON.parse(captured.body);
  check('JSON POST 请求体不变', body.model === 'deepseek-chat' && body.stream === false);

  // 模拟原生一次性返回
  const respText = JSON.stringify({ id: 'x', choices: [] });
  const b64 = Buffer.from(respText).toString('base64');
  win.__dsfcBridgeHead(captured.id, 200, JSON.stringify({ 'content-type': 'application/json' }));
  win.__dsfcBridgeDone(captured.id, 200, JSON.stringify({ 'content-type': 'application/json' }), b64, false);
  const response = await promise;
  const text = await response.text();
  check('非流式响应可读取', response.status === 200 && text === respText, 'len=' + text.length);
}

async function testStream() {
  let captured = null;
  const win = createSandbox((req) => { captured = req; });
  const promise = win.fetch('https://api.example.com/v1/messages', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ stream: true, messages: [] })
  });
  await wait(10);
  const sse = 'data: {"type":"content_block_delta","delta":{"text":"你"}}\n\n' +
    'data: {"type":"content_block_delta","delta":{"text":"好"}}\n\n' +
    'data: [DONE]\n\n';
  const bytes = Buffer.from(sse, 'utf8');
  // 头部先到
  win.__dsfcBridgeHead(captured.id, 200, JSON.stringify({ 'content-type': 'text/event-stream' }));
  const response = await promise;
  check('流式响应先返回头部', response.status === 200 && !!response.body);
  // 分两段推
  win.__dsfcBridgeChunk(captured.id, bytes.slice(0, 40).toString('base64'));
  win.__dsfcBridgeChunk(captured.id, bytes.slice(40).toString('base64'));
  win.__dsfcBridgeDone(captured.id, 200, JSON.stringify({ 'content-type': 'text/event-stream' }), '', false);
  const text = await response.text();
  check('流式正文完整', text === sse, 'len=' + text.length);
}

async function testHeadersArriveBeforeResolve() {
  // 头部到达时读者还没取到流：bridgeFetch 应当缓存 pending 数据
  let captured = null;
  const win = createSandbox((req) => { captured = req; });
  const promise = win.fetch('https://api.example.com/x', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ stream: true })
  });
  await wait(10);
  const bytes = Buffer.from('data: 1\n\n', 'utf8');
  win.__dsfcBridgeHead(captured.id, 200, '{}');
  const response = await promise;
  win.__dsfcBridgeChunk(captured.id, bytes.toString('base64'));
  win.__dsfcBridgeDone(captured.id, 200, '{}', '', false);
  const text = await response.text();
  check('流式分块拼装正确', text === 'data: 1\n\n', JSON.stringify(text));
}

async function testFormData() {
  let captured = null;
  const win = createSandbox((req) => { captured = req; });
  const form = new win.FormData();
  const wav = Buffer.from([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 5]); // "RIFF" + 若干字节
  // 浏览器里 filename 来自 File（Blob 带 name）；沙箱的 append 只记 filename，这里补一份 name 供桥读取
  const wavFile = new win.Blob([wav], { type: 'audio/wav' });
  Object.defineProperty(wavFile, 'name', { value: 'recording.wav', enumerable: false });
  form.append('file', wavFile, 'recording.wav');
  form.append('model', 'gpt-4o-transcribe');
  const promise = win.fetch('https://api.example.com/audio/transcriptions', {
    method: 'POST',
    headers: { Authorization: 'Bearer sk-test' },
    body: form
  });
  await wait(20);
  check('FormData 以二进制方式交给原生', captured.binary === true || captured.binary === 1, 'binary=' + captured.binary);
  let envelope = null;
  try { envelope = JSON.parse(captured.body); } catch (e) { envelope = null; }
  if (!envelope) {
    console.log('  原始 body:', typeof captured.body, JSON.stringify(String(captured.body).slice(0, 200)));
  }
  check('FormData 封装为 __dsfcForm', !!envelope && envelope.__dsfcForm === 1);
  if (envelope) {
    check('FormData 保留 multipart 边界', /multipart\/form-data; boundary=/.test(envelope.contentType), envelope.contentType);
    const boundary = (envelope.contentType.match(/boundary=(.*)$/i) || [])[1];
    const raw = Buffer.from(envelope.body, 'base64');
    const text = raw.toString('latin1');

    const expected = makeFormDataFrame(boundary, 'file', 'recording.wav', 'audio/wav', wav).toString('latin1');
    const modelPart = '--' + boundary + '\r\nContent-Disposition: form-data; name="model"\r\n\r\ngpt-4o-transcribe\r\n';
    const ends = '--' + boundary + '--\r\n';
    check('FormData 正文与浏览器编码逐字节一致', text === (expected + modelPart + ends), 'len=' + text.length + ' expect=' + (expected + modelPart + ends).length);

    const headers = JSON.parse(captured.headers);
    check('FormData 未误设 application/json', !/application\/json/.test(headers['Content-Type'] || ''));
  }
  win.__dsfcBridgeDone(captured.id, 200, '{}', Buffer.from(JSON.stringify({ text: '你好' }), 'utf8').toString('base64'), false);
  const response = await promise;
  const json = await response.json();
  check('语音识别响应可解析', json.text === '你好');
}

async function testNetworkError() {
  let captured = null;
  const win = createSandbox((req) => { captured = req; });
  const promise = win.fetch('https://api.example.com/v1/models', { method: 'GET' });
  await wait(10);
  const message = Buffer.from('NETERR|网络连接已断开，请检查 Wi-Fi 或移动数据', 'utf8').toString('base64');
  win.__dsfcBridgeDone(captured.id, -1, '{}', message, false);
  let error = null;
  try { await promise; } catch (e) { error = e; }
  check('网络错误转成异常', !!error && /网络连接已断开/.test(error.message), error && error.message);
}

async function testAbort() {
  let captured = null;
  const win = createSandbox((req) => { captured = req; });
  const controller = new AbortController();
  const promise = win.fetch('https://api.example.com/v1/chat/completions', {
    method: 'POST',
    body: JSON.stringify({ stream: true }),
    signal: controller.signal
  });
  await wait(10);
  controller.abort();
  let error = null;
  try {
    await Promise.race([promise, wait(200).then(function () { throw new Error('__timeout__'); })]);
  } catch (e) {
    error = e;
  }
  if (error && error.message === '__timeout__') {
    check('中止请求抛出 AbortError', false, '请求在 200ms 内没有结束（挂起）');
    return;
  }
  check('中止请求抛出 AbortError', !!error && error.name === 'AbortError');
  check('中止时调用 cancelAll', !!(win.__cancelled && win.__cancelled.length));
  // 中止后迟到的回调不应该炸
  win.__dsfcBridgeDone(captured.id, 200, '{}', '', false);
  check('中止后迟到回调安全', true);
}

async function testRelativeUrl() {
  const win = createSandbox(() => {});
  win.fetch = undefined;
  const win2 = createSandbox(() => {});
  let error = null;
  try { await win2.fetch('static/js/main.de040f79.js'); } catch (e) { error = e; }
  check('相对地址交给原生 fetch（无原生时给出明确错误）', !!error && /不支持的请求地址/.test(error.message));
}

(async () => {
  const syntaxOk = (() => {
    try { new vm.Script(fs.readFileSync(path.join(WWW, 'ios-bridge.js'), 'utf8')); return true; } catch (e) { return e.message; }
  })();
  check('ios-bridge.js 语法', syntaxOk === true, syntaxOk === true ? '' : String(syntaxOk));

  await testJsonPost();
  await testStream();
  await testHeadersArriveBeforeResolve();
  await testFormData();
  await testNetworkError();
  await testAbort();
  await testRelativeUrl();

  const failed = results.filter((r) => !r.ok);
  console.log('');
  console.log('通过 ' + (results.length - failed.length) + ' / ' + results.length);
  process.exit(failed.length ? 1 : 0);
})().catch((error) => {
  console.error('测试自身异常：', error);
  process.exit(2);
});
