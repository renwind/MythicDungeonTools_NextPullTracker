"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  assignRotationEvents,
  summarizeRotation,
  ratioTenths,
  buildRatioPack,
  buildRatioPackLine,
} = require("./rotation.js");

const waves = [
  { pulls: [1], castStart: 0, castEnd: 50 },
  { pulls: [2], castStart: 60, castEnd: 100 },
];

test("rotation casts 按 castStart/castEnd 归属波次", () => {
  const events = [
    { type: "cast", spellId: 117014, t: 10 },
    { type: "cast", spellId: 61882, t: 50 },
    { type: "cast", spellId: 61882, t: 70 },
  ];
  assert.deepEqual(assignRotationEvents(events, waves), [0, 0, 1]);
});

test("重叠边界按倒序查找归后波", () => {
  const overlappingWaves = [
    { castStart: 0, castEnd: 50 },
    { castStart: 50, castEnd: 100 },
  ];
  assert.deepEqual(assignRotationEvents([{ type: "cast", spellId: 117014, t: 50 }], overlappingWaves), [1]);
});

test("只接受成功 cast、固定 spellId 和非负有限时间", () => {
  const invalid = [
    { type: "begincast", spellId: 117014, t: 10 },
    { type: "cast", spellId: 999999, t: 10 },
    { type: "cast", spellId: 61882, t: NaN },
    { type: "cast", spellId: 61882, t: Infinity },
    { type: "cast", spellId: 61882, t: -1 },
    { skill: "elementalBlast", t: 10 },
  ];
  for (const event of invalid) {
    assert.throws(
      () => assignRotationEvents([event], waves),
      /rotation: invalid rotation event at index 0/,
    );
  }
});

test("无法归属的 rotation cast 返回 -1", () => {
  assert.deepEqual(assignRotationEvents([{ type: "cast", spellId: 61882, t: 55 }], waves), [-1]);
});

test("summarizeRotation 按波次和 spellId 映射计数", () => {
  const events = [
    { type: "cast", spellId: 117014, t: 10 },
    { type: "cast", spellId: 61882, t: 20 },
    { type: "cast", spellId: 61882, t: 70 },
  ];
  assert.deepEqual(summarizeRotation(2, events, [0, 0, 1]), [
    { elementalBlast: 1, earthquake: 1 },
    { elementalBlast: 0, earthquake: 1 },
  ]);
});

test("summarizeRotation 拒绝未归属、越界和非法 assignment", () => {
  const events = [{ type: "cast", spellId: 61882, t: 55 }];
  assert.throws(() => summarizeRotation(2, events, [-1]), /unassigned rotation cast/);
  assert.throws(() => summarizeRotation(2, events, [2]), /unassigned rotation cast/);
  assert.throws(() => summarizeRotation(2, events, [0.5]), /unassigned rotation cast/);
});

test("ratioTenths 对 0:0 返回 null", () => {
  assert.equal(ratioTenths({ elementalBlast: 0, earthquake: 0 }), null);
});

test("ratioTenths 四舍五入为总和 10 的十等分", () => {
  assert.deepEqual(ratioTenths({ elementalBlast: 8, earthquake: 2 }), { elementalBlast: 8, earthquake: 2 });
  assert.deepEqual(ratioTenths({ elementalBlast: 1, earthquake: 42 }), { elementalBlast: 0, earthquake: 10 });
  assert.deepEqual(ratioTenths({ elementalBlast: 1, earthquake: 1 }), { elementalBlast: 5, earthquake: 5 });
});

test("buildRatioPack 按波顺序输出 base36 双值 token", () => {
  const usage = [
    { elementalBlast: 0, earthquake: 26 },
    { elementalBlast: 1, earthquake: 42 },
  ];
  assert.equal(buildRatioPack(usage), "0.q,1.16");
});

test("buildRatioPack 拒绝非非负 safe integer 计数", () => {
  for (const value of [-1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, undefined]) {
    assert.throws(
      () => buildRatioPack([{ elementalBlast: value, earthquake: 0 }]),
      /nonnegative safe integer/i,
    );
    assert.throws(
      () => buildRatioPack([{ elementalBlast: 0, earthquake: value }]),
      /nonnegative safe integer/i,
    );
  }
});

test("buildRatioPackLine 输出完整导入命令", () => {
  const usage = [
    { elementalBlast: 8, earthquake: 2 },
    { elementalBlast: 0, earthquake: 0 },
  ];
  assert.equal(buildRatioPackLine(usage, "abc12345"),
    "/npt importratiopack abc12345 8.2,0.0");
});

test("buildRatioPackLine 接受 255 字符并拒绝更长聊天命令", () => {
  const rows = Array.from({ length: 56 }, () => ({ elementalBlast: 0, earthquake: 0 }));
  const line = buildRatioPackLine(rows, "abcdefghij");
  assert.equal(line.length, 255);
  assert.throws(
    () => buildRatioPackLine([...rows, { elementalBlast: 0, earthquake: 0 }], "abcdefghij"),
    /255 characters/i,
  );
});
