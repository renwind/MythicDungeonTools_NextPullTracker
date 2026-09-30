const test = require("node:test");
const assert = require("node:assert/strict");
const { mergePulls } = require("./merge.js");

const WINDOWS = [
  { start: 22, end: 100 }, { start: 113, end: 179 }, { start: 189, end: 228 },
  { start: 228, end: 452 }, { start: 467, end: 553 }, { start: 570, end: 875 },
  { start: 876, end: 1105 }, { start: 1140, end: 1205 }, { start: 1221, end: 1427 },
  { start: 1446, end: 1455 }, { start: 1460, end: 1669 },
];
const DEATHS = [13, 4, 0, 4, 11, 31, 7, 5, 8, 0, 5];

test("零死亡波与紧邻波合并，其余保持独立", () => {
  const groups = mergePulls(WINDOWS, DEATHS);
  assert.deepEqual(groups, [[1], [2], [3, 4], [5], [6, 7], [8], [9], [10, 11]]);
});

test("间隔阈值可配：阈值调小则不再按间隔合并", () => {
  const groups = mergePulls(WINDOWS, DEATHS, { gapSeconds: 0.5 });
  // 0s 间隔（3->4）仍合并；1s（6->7）与 5s（10->11）不再因间隔合并，
  // 但 10 是零死亡波，仍并入 11。
  assert.deepEqual(groups, [[1], [2], [3, 4], [5], [6], [7], [8], [9], [10, 11]]);
});

test("全零死亡的退化输入合并成单组不崩", () => {
  const w = [{ start: 0, end: 10 }, { start: 10, end: 20 }];
  assert.deepEqual(mergePulls(w, [0, 0]), [[1, 2]]);
});

test("长度不一致抛错", () => {
  assert.throws(() => mergePulls(WINDOWS, DEATHS.slice(0, 3)), /length/);
});
