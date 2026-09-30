const test = require("node:test");
const assert = require("node:assert/strict");
const { detectLustUses } = require("./lust.js");

const apply = (t, target, a = 57723) => ({ abilityGameID: a, type: "applydebuff", timestamp: t, targetID: target });

test("同毫秒五人 apply 聚为一次使用", () => {
  const uses = detectLustUses([apply(1000, 1), apply(1000, 2), apply(1001, 3), apply(1002, 4), apply(1003, 5)]);
  assert.deepEqual(uses, [1000]);
});

test("跨族 ID 同时出现仍是一次使用（时光+嗜血不会双计）", () => {
  const uses = detectLustUses([apply(1000, 1, 80354), apply(1000, 2, 57723), apply(1001, 3, 80354)]);
  assert.deepEqual(uses, [1000]);
});

test("间隔超过簇窗口的两次 apply 算两次使用", () => {
  const uses = detectLustUses([apply(1000, 1), apply(1000, 2), apply(900000, 1), apply(900001, 2)]);
  assert.deepEqual(uses, [1000, 900000]);
});

test("整簇都落在近期死亡目标上则丢弃", () => {
  const deaths = [{ target: 1, t: 500 }, { target: 2, t: 600 }];
  const uses = detectLustUses([apply(1000, 1), apply(1001, 2)], { friendlyDeaths: deaths });
  assert.deepEqual(uses, []);
});

test("簇内有存活目标则保留（死人只扣除自己的计数）", () => {
  const deaths = [{ target: 1, t: 500 }];
  const uses = detectLustUses([apply(1000, 1), apply(1001, 2)], { friendlyDeaths: deaths });
  assert.deepEqual(uses, [1000]);
});

test("非族 ID 与 refresh 事件忽略", () => {
  const uses = detectLustUses([
    { abilityGameID: 999999, type: "applydebuff", timestamp: 1000, targetID: 1 },
    { abilityGameID: 57723, type: "refreshdebuff", timestamp: 1200, targetID: 2 },
  ]);
  assert.deepEqual(uses, []);
});
