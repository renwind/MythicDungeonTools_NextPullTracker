// CBOR (RFC 8949) 子集：够 MDT preset 表用即可。
// 编码：整数(0/1)、文本(3)、字节(2)、数组(4)、map(5)、float64(7)、true/false/null。
// 对象键若为纯数字字符串则编码为 CBOR 整数键（MDT pulls 表就是整数键）。
"use strict";

function writeHead(parts, major, value) {
  const m = major << 5;
  if (value < 24) parts.push(m | value);
  else if (value < 2 ** 8) parts.push(m | 24, value);
  else if (value < 2 ** 16) parts.push(m | 25, value >> 8, value & 255);
  else if (value < 2 ** 32)
    parts.push(m | 26, (value >>> 24) & 255, (value >>> 16) & 255, (value >>> 8) & 255, value & 255);
  else {
    const hi = Math.floor(value / 2 ** 32);
    const lo = value % 2 ** 32;
    parts.push(m | 27, (hi >>> 24) & 255, (hi >>> 16) & 255, (hi >>> 8) & 255, hi & 255,
      (lo >>> 24) & 255, (lo >>> 16) & 255, (lo >>> 8) & 255, lo & 255);
  }
}

function encodeInto(value, parts) {
  if (value === null) { parts.push(0xf6); return; }
  if (value === true) { parts.push(0xf5); return; }
  if (value === false) { parts.push(0xf4); return; }
  if (value instanceof Uint8Array) {
    writeHead(parts, 2, value.length);
    for (const b of value) parts.push(b);
    return;
  }
  if (typeof value === "string") {
    const bytes = Buffer.from(value, "utf8");
    writeHead(parts, 3, bytes.length);
    for (const b of bytes) parts.push(b);
    return;
  }
  if (typeof value === "number") {
    if (Number.isInteger(value)) {
      if (value >= 0) writeHead(parts, 0, value);
      else writeHead(parts, 1, -1 - value);
    } else {
      const buf = Buffer.alloc(8);
      buf.writeDoubleBE(value, 0);
      parts.push(0xfb, ...buf);
    }
    return;
  }
  if (Array.isArray(value)) {
    writeHead(parts, 4, value.length);
    for (const item of value) encodeInto(item, parts);
    return;
  }
  if (typeof value === "object") {
    const keys = Object.keys(value);
    writeHead(parts, 5, keys.length);
    for (const key of keys) {
      if (/^\d+$/.test(key)) encodeInto(Number(key), parts);
      else encodeInto(key, parts);
      encodeInto(value[key], parts);
    }
    return;
  }
  throw new Error("cbor: unsupported type " + typeof value);
}

function encodeCbor(value) {
  const parts = [];
  encodeInto(value, parts);
  return Buffer.from(parts);
}

class Reader {
  constructor(buf) { this.buf = buf; this.pos = 0; }
  byte() {
    if (this.pos >= this.buf.length) throw new Error("cbor: truncated");
    return this.buf[this.pos++];
  }
  uint(additional) {
    if (additional < 24) return additional;
    const sizes = { 24: 1, 25: 2, 26: 4, 27: 8 };
    const size = sizes[additional];
    if (!size) throw new Error("cbor: bad additional " + additional);
    if (this.pos + size > this.buf.length) throw new Error("cbor: truncated");
    let value = 0;
    for (let i = 0; i < size; i++) value = value * 256 + this.buf[this.pos++];
    return value;
  }
  bytes(n) {
    if (this.pos + n > this.buf.length) throw new Error("cbor: truncated");
    const out = this.buf.subarray(this.pos, this.pos + n);
    this.pos += n;
    return out;
  }
}

function decodeItem(reader) {
  const initial = reader.byte();
  const major = initial >> 5;
  const additional = initial & 31;
  if (major === 0) return reader.uint(additional);
  if (major === 1) return -1 - reader.uint(additional);
  if (major === 2) return new Uint8Array(reader.bytes(reader.uint(additional)));
  if (major === 3) return Buffer.from(reader.bytes(reader.uint(additional))).toString("utf8");
  if (major === 4) {
    const n = reader.uint(additional);
    const out = [];
    for (let i = 0; i < n; i++) out.push(decodeItem(reader));
    return out;
  }
  if (major === 5) {
    const n = reader.uint(additional);
    const out = {};
    for (let i = 0; i < n; i++) {
      const key = decodeItem(reader);
      out[typeof key === "number" ? key : String(key)] = decodeItem(reader);
    }
    return out;
  }
  if (major === 7) {
    if (additional === 20) return false;
    if (additional === 21) return true;
    if (additional === 22) return null;
    if (additional === 27) {
      const b = reader.bytes(8);
      return Buffer.from(b).readDoubleBE(0);
    }
    throw new Error("cbor: unsupported simple " + additional);
  }
  throw new Error("cbor: unsupported major " + major);
}

function decodeCbor(buf) {
  const reader = new Reader(buf);
  const value = decodeItem(reader);
  if (reader.pos !== buf.length) throw new Error("cbor: trailing bytes");
  return value;
}

module.exports = { encodeCbor, decodeCbor };
