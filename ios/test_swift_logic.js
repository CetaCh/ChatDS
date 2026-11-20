#!/usr/bin/env node
/* 覆盖 Swift 那一侧（Net.swift / JSAPI 分发）的纯逻辑：JsString、__dsfcForm 解码、二进制信封识别、
 * 流式判定。这些都没有 UIKit/WebKit 依赖，可以照搬规则到 JS 里做一致性验证。
 *
 * 用法：node test_swift_logic.js
 */
const results = [];
function check(name, ok, detail) {
  results.push({ name, ok });
  console.log((ok ? '[OK]   ' : '[FAIL] ') + name + (detail ? '  ' + detail : ''));
}

// ---------------------------------------------------------------- 1) jsString：与 Bridge.swift 一致的转义规则
function jsString(value) {
  let out = '"';
  for (const ch of value) {
    const code = ch.codePointAt(0);
    if (ch === '"') out += '\\"';
    else if (ch === '\\') out += '\\\\';
    else if (ch === "'") out += "'";
    else if (ch === '\n') out += '\\n';
    else if (ch === '\r') out += '\\r';
    else if (ch === '\t') out += '\\t';
    else if (code === 0x2028) out += '\\u2028';
    else if (code === 0x2029) out += '\\u2029';
    else if (code < 0x20) out += '\\u' + code.toString(16).padStart(4, '0');
    else if (code >= 32 && code < 127) out += ch;
    else out += ch;
  }
  return out + '"';
}

function testJsString() {
  const samples = [
    '{"version":"15.6","platform":"ios"}',
    'line1\nline2\ttab\r\n',
    '引号 " 和反斜杠 \\ 以及单引号 \'',
    '中文测试 😀 表情',
    '控制字符 \u0001\u001f',
    '分隔符 \u2028\u2029'
  ];
  let ok = true;
  for (const sample of samples) {
    const literal = jsString(sample);
    const back = JSON.parse(literal.startsWith('"') ? literal : '"' + literal + '"');
    if (back !== sample) { ok = false; console.log('  失败样本: ' + JSON.stringify(sample)); }
  }
  check('jsString 转义后可被 JS 原样还原', ok);
}

// ---------------------------------------------------------------- 2) __dsfcForm 信封
function decodeFormEnvelope(text) {
  if (!text.startsWith('{')) return null;
  let object;
  try { object = JSON.parse(text); } catch (e) { return null; }
  if (!object || object.__dsfcForm !== 1) return null;
  if (typeof object.body !== 'string') return null;
  let body;
  try { body = Buffer.from(object.body, 'base64'); } catch (e) { return null; }
  const contentType = object.contentType || '';
  if (!contentType) return null;
  return { contentType, body };
}

function testFormEnvelope() {
  const raw = Buffer.from('--b\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n\r\nRIFF\r\n--b--\r\n');
  const envelope = JSON.stringify({ __dsfcForm: 1, contentType: 'multipart/form-data; boundary=b', body: raw.toString('base64') });
  const decoded = decodeFormEnvelope(envelope);
  check('__dsfcForm 信封可还原 multipart 正文', !!decoded && decoded.body.equals(raw));
  check('__dsfcForm 保留边界', !!decoded && /boundary=b/.test(decoded.contentType));
  check('普通 JSON 请求体不会被当信封', decodeFormEnvelope(JSON.stringify({ model: 'x', stream: true })) === null);
  check('缺少 contentType 时不误判', decodeFormEnvelope(JSON.stringify({ __dsfcForm: 1, body: '' })) === null);
}

// ---------------------------------------------------------------- 4) 纯 base64 二进制信封
function decodeBinaryEnvelope(text) {
  if (!text || text.includes('"__dsfcForm"')) return null;
  if (!/^[A-Za-z0-9+/=\r\n]+$/.test(text)) return null;
  const compact = text.replace(/[\r\n]/g, '');
  if (compact.length < 4 || compact.length % 4 !== 0) return null;
  return Buffer.from(compact, 'base64');
}

function testBinaryEnvelope() {
  const bytes = Buffer.from([0, 1, 2, 255, 254, 10, 13]);
  const encoded = bytes.toString('base64');
  const decoded = decodeBinaryEnvelope(encoded);
  check('base64 二进制请求体可还原', !!decoded && decoded.equals(bytes));
  check('JSON 文本不会被当二进制', decodeBinaryEnvelope('{"a":1}') === null);
  check('中文文本不会被当二进制', decodeBinaryEnvelope('你好世界') === null);
  check('信封本身不会被当二进制', decodeBinaryEnvelope('{"__dsfcForm":1}') === null);
}

// ---------------------------------------------------------------- 5) 流式判定
function wantsLive(body, contentType) {
  const regex = /"stream"\s*:\s*true/;
  return regex.test(body || '') || /text\/event-stream/.test((contentType || '').toLowerCase());
}

function testWantsLive() {
  check('stream:true（紧凑 JSON）判为流式', wantsLive(JSON.stringify({ model: 'deepseek-chat', stream: true }), ''));
  check('stream: false 判为非流式', !wantsLive(JSON.stringify({ model: 'deepseek-chat', stream: false }), 'application/json'));
  check('stream : true（带空格）也判为流式', wantsLive('{"stream" : true}', ''));
  check('text/event-stream 判为流式', wantsLive('', 'text/event-stream; charset=utf-8'));
  check('语音上传（multipart，无 stream）判为非流式', !wantsLive('{"__dsfcForm":1}', 'multipart/form-data'));
}

// ---------------------------------------------------------------- 6) UTF-8 边界截断（对应 trimToUTF8Boundary）
function trimToUTF8Boundary(bytes) {
  if (!bytes.length) return bytes;
  for (let index = bytes.length - 1, back = 0; index >= 0 && back < 4; index -= 1, back += 1) {
    const byte = bytes[index];
    if ((byte & 0x80) === 0) return bytes;
    if ((byte & 0xc0) === 0xc0) {
      let need = 2;
      if ((byte & 0xf0) === 0xe0) need = 3;
      else if ((byte & 0xf8) === 0xf0) need = 4;
      const available = bytes.length - index;
      return available < need ? bytes.subarray(0, index) : bytes;
    }
  }
  return bytes;
}

function testUtf8Boundary() {
  const text = '中文流式数据测试';
  const bytes = Buffer.from(text, 'utf8');
  let ok = true;
  for (let cut = 1; cut < bytes.length; cut += 1) {
    const part = trimToUTF8Boundary(bytes.subarray(0, cut));
    const decoded = part.toString('utf8');
    if (decoded.includes('\ufffd')) { ok = false; break; }
  }
  check('任意位置截断都不会把汉字劈成乱码', ok);
}

testJsString();
testFormEnvelope();
testBinaryEnvelope();
testWantsLive();
testUtf8Boundary();

const failed = results.filter((r) => !r.ok);
console.log('');
console.log('通过 ' + (results.length - failed.length) + ' / ' + results.length);
process.exit(failed.length ? 1 : 0);
