const test = require("node:test");
const assert = require("node:assert/strict");
const { encodeMdtString, decodeMdtString } = require("./mdtstring.js");

test("往返保留 preset 结构", () => {
  const preset = {
    text: "wcl route",
    uid: "abc123",
    value: {
      currentDungeonIdx: 41,
      currentSublevel: 1,
      currentPull: 2,
      pulls: [{ 3: [1, 2], color: "ff0000" }, { 5: [1] }],
    },
  };
  assert.deepEqual(decodeMdtString(encodeMdtString(preset)), preset);
});

test("输出以 !~MDT2~ 开头且主体是标准 base64", () => {
  const s = encodeMdtString({ text: "x", value: { pulls: [] } });
  assert.ok(s.startsWith("!~MDT2~"));
  assert.match(s.slice(7), /^[A-Za-z0-9+/=]+$/);
});

test("非 MDT2 前缀拒绝", () => {
  assert.throws(() => decodeMdtString("!MDT:garbage"), /prefix/);
});

test("损坏 base64 拒绝", () => {
  assert.throws(() => decodeMdtString("!~MDT2~!!!not-base64!!!"));
});

// 真实互操作 fixture：Threechest 对 WCL 报告 C9pFgkRJwMvHB4KY(fight 4) 的导出串，
// 2026-09-30 在内置浏览器捕获。暴雪 SerializeCBOR 用字节串(major 2)存字符串，
// 这个 fixture 守住该约定不被「优化」成 text string。
const REAL_EXPORT =
  "!~MDT2~XZBPbxJBGMadP/sPll1AC6Rq0ujRmJBmD5J4EAFrW7S1PZiaxkRghmC3C2F3aZto4juATRoPejReLEX4Bp65ePEbePFsvDcx4WJoa1g8zjy/9zfzPoO8x/a94tNcceFxtri2cGtxMb/H2A5aqdQ4r5V92zvAOb9W2chlGg+qOxsre49aD+9bq1u3rULrhe2zwWrZbzaZ4637tn1p7eKw6Zds1mI2enJxkfedKqs7y5X91PGyy2xW9mp1502h4du2+36AhSSTwxChsqJqFCRT6JFYG1OpUK7b9ebSTc6tNOdDBBIGjUCUAjE7EziVAuUfNEEy/AsGlYBJQTFFNBYUWOleFNCULt3hvI9FKEzexuKXr8wlYiKsTwcmIz0MelBvpQfyITLMaCyOFUCqQFgDZIrUfOpq8KkMH1JhmHKbUEkVhGqCSqEz8FrqelDI+VACJHf1iKyoCkiqkGQNlBDgqS7DrXRfbofCmioUNR5cYaIYhAUmEUAGoASg5DTOnK0wCAsq6UAjAhMDaBLobKknOkgJgclsi725qee8u74OxACSBDLb4IkBOBn87gRfZw7bPci6bq3q7DLHcz8v1UsvWdlz271spTu+V33WOnqufh+P/A7+3eiG0Wm+6Lte1jk9z5tHxtc/d+fHo+q77V8fb3z7P++8/pC0C6/Go63spx8/jzen+V8=";

test("解码 Threechest 真实导出串", () => {
  const preset = decodeMdtString(REAL_EXPORT);
  assert.equal(preset.text, "WCL NALO +22");
  assert.equal(preset.uid, "C9pFgkRJwMvHB4KY-4");
  assert.equal(preset.value.currentDungeonIdx, 161);
  assert.equal(preset.value.pulls.length, 16);
  assert.deepEqual(preset.value.pulls[0][2], [5, 6]);
  assert.equal(preset.value.pulls[0].color, "#ff40ff");
});
