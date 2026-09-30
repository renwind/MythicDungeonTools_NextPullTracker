const test = require("node:test");
const assert = require("node:assert/strict");
const { encodeCbor, decodeCbor } = require("./cbor.js");

function roundTrip(value) {
  return decodeCbor(encodeCbor(value));
}

test("整数与负整数往返", () => {
  for (const n of [0, 1, 23, 24, 255, 256, 65535, 65536, 2 ** 31, -(2 ** 31)]) {
    assert.equal(roundTrip(n), n);
  }
});

test("字符串与布尔与 null 往返", () => {
  assert.equal(roundTrip("hello"), "hello");
  assert.equal(roundTrip(""), "");
  assert.equal(roundTrip(true), true);
  assert.equal(roundTrip(false), false);
  assert.equal(roundTrip(null), null);
});

test("非整数走 float64", () => {
  assert.equal(roundTrip(1.5), 1.5);
  assert.equal(roundTrip(-0.25), -0.25);
});

test("数组保持顺序、嵌套往返", () => {
  const v = [1, [2, 3], ["a"], []];
  assert.deepEqual(roundTrip(v), v);
});

test("对象数字键编码为 CBOR 整数键并还原为数字键对象", () => {
  const v = { 3: [1, 2], 10: [4], color: "ff0000" };
  const out = roundTrip(v);
  assert.deepEqual(out[3], [1, 2]);
  assert.deepEqual(out[10], [4]);
  assert.equal(out.color, "ff0000");
});

test("解码器拒绝截断输入", () => {
  const buf = encodeCbor({ a: [1, 2] });
  assert.throws(() => decodeCbor(buf.subarray(0, buf.length - 1)));
});
