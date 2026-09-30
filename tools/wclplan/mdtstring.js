// 与本机 MDT v6.2.20 Transmission.lua:12-30 同管线：
// "!~MDT2~" .. Base64(DeflateRaw(SerializeCBOR(table)))
"use strict";
const zlib = require("node:zlib");
const { encodeCbor, decodeCbor } = require("./cbor.js");

const PREFIX = "!~MDT2~";

function encodeMdtString(preset) {
  const cbor = encodeCbor(preset);
  const deflated = zlib.deflateRawSync(cbor, { level: 9 });
  return PREFIX + deflated.toString("base64");
}

function decodeMdtString(text) {
  if (typeof text !== "string" || !text.startsWith(PREFIX)) {
    throw new Error("mdtstring: unsupported prefix, expected " + PREFIX);
  }
  const body = text.slice(PREFIX.length);
  if (!/^[A-Za-z0-9+/=]+$/.test(body)) {
    throw new Error("mdtstring: body is not base64");
  }
  const inflated = zlib.inflateRawSync(Buffer.from(body, "base64"));
  return decodeCbor(inflated);
}

module.exports = { encodeMdtString, decodeMdtString, PREFIX };
