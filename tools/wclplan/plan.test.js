const test = require("node:test");
const assert = require("node:assert/strict");
const { buildEntrySpec, buildPlanLines, computeRouteKey, specLines, sumUsagePerWave } = require("./plan.js");

test("entrySpec 语法 id:kind:action[:uses]，分号分隔", () => {
  const spec = buildEntrySpec({ lust: 1, asc: 2, pot: 1 });
  assert.equal(spec, "32182:spell:use;114050:spell:use:2;241308:item:use");
});

test("零使用的技能不出现", () => {
  assert.equal(buildEntrySpec({ lust: 0, asc: 1, pot: 0 }), "114050:spell:use");
  assert.equal(buildEntrySpec({ lust: 0, asc: 0, pot: 0 }), "");
});

test("uses 上限 5：4 保留、7 钳到 5", () => {
  assert.equal(buildEntrySpec({ lust: 0, asc: 4, pot: 0 }), "114050:spell:use:4");
  assert.equal(buildEntrySpec({ lust: 0, asc: 7, pot: 0 }), "114050:spell:use:5");
});

test("plan 行按合并组编号且 usage 按组求和，行首带 routeKey", () => {
  const groups = [[1], [2, 3]];
  const usage = [
    { lust: 0, asc: 1, pot: 0 },
    { lust: 1, asc: 0, pot: 1 },
    { lust: 0, asc: 1, pot: 0 },
  ];
  const lines = buildPlanLines(groups, usage, "00000001");
  assert.deepEqual(lines, [
    "/npt importplan 00000001 1 114050:spell:use",
    "/npt importplan 00000001 2 32182:spell:use;114050:spell:use;241308:item:use",
  ]);
});

test("整波无规划不产出行", () => {
  assert.deepEqual(buildPlanLines([[1]], [{ lust: 0, asc: 0, pot: 0 }], "00000001"), []);
});

test("specLines 空波不产出行，但波号仍按全波计数", () => {
  const lines = specLines([
    { lust: 1, asc: 0, pot: 0 },
    { lust: 0, asc: 0, pot: 0 },
    { lust: 0, asc: 2, pot: 1 },
  ], "00000001");
  assert.deepEqual(lines, [
    "/npt importplan 00000001 1 32182:spell:use",
    "/npt importplan 00000001 3 114050:spell:use:2;241308:item:use",
  ]);
});

test("sumUsagePerWave 按 cast 归属波计数，未知技能忽略", () => {
  const usage = sumUsagePerWave(3, [
    { skill: "asc", t: 10 },
    { skill: "asc", t: 20 },
    { skill: "lust", t: 30 },
    { skill: "pot", t: 40 },
    { skill: "asc", t: 50 },
  ], [0, 0, 2, 2, -1]);
  assert.deepEqual(usage, [
    { lust: 0, asc: 2, pot: 0 },
    { lust: 0, asc: 0, pot: 0 },
    { lust: 1, asc: 0, pot: 1 },
  ]);
});

test("routeKey 对相同 pulls 稳定、clone 数变化即变化", () => {
  const a = [{ 3: [1, 2] }, { 5: [1] }];
  assert.equal(computeRouteKey(a), computeRouteKey([{ 3: [1, 2] }, { 5: [1] }]));
  assert.notEqual(computeRouteKey(a), computeRouteKey([{ 3: [1] }, { 5: [1] }]));
  assert.match(computeRouteKey(a), /^[0-9a-f]{8}$/);
});
