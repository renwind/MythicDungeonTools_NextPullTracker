const test = require("node:test");
const assert = require("node:assert/strict");
const { loadNpcIds, assignDeathsToPulls } = require("./align.js");

const LUA_SNIPPET = [
  "MDT.dungeonEnemies[dungeonIndex] = {",
  "  [1] = {",
  '    ["name"] = "Spirit of Hunger",',
  '    ["id"] = 245855,',
  '    ["clones"] = { [1] = { ["x"] = 1 }, [2] = { ["x"] = 2 } },',
  "  },",
  "  [2] = {",
  '    ["id"] = 241814,',
  '    ["clones"] = { [1] = { ["x"] = 3 } },',
  "  },",
  "}",
].join("\n");

test("loadNpcIds 按 enemyIdx 顺序取 id", () => {
  const npcIds = loadNpcIds(LUA_SNIPPET);
  assert.equal(npcIds[1], 245855);
  assert.equal(npcIds[2], 241814);
  assert.equal(npcIds[3], undefined);
});

test("同 npc 的死亡按时间序填入各 pull 队列", () => {
  const pulls = [{ 1: [1, 2] }, { 1: [3] }];
  const npcIds = { 1: 100 };
  const deaths = [
    { gameId: 100, timestamp: 30000 },
    { gameId: 100, timestamp: 10000 },
    { gameId: 100, timestamp: 20000 },
  ];
  const { windows, deathCounts, unassigned } = assignDeathsToPulls(pulls, npcIds, deaths);
  assert.deepEqual(deathCounts, [2, 1]);
  assert.deepEqual(windows[0], { start: 10, end: 20 });
  assert.deepEqual(windows[1], { start: 30, end: 30 });
  assert.deepEqual(unassigned, []);
});

test("队列耗尽的死亡进 unassigned 不崩", () => {
  const pulls = [{ 1: [1] }];
  const npcIds = { 1: 100 };
  const deaths = [{ gameId: 100, timestamp: 1000 }, { gameId: 100, timestamp: 2000 }];
  const { deathCounts, unassigned } = assignDeathsToPulls(pulls, npcIds, deaths);
  assert.deepEqual(deathCounts, [1]);
  assert.equal(unassigned.length, 1);
});

test("路线里没有的 npc 死亡进 unassigned", () => {
  const pulls = [{ 1: [1] }];
  const npcIds = { 1: 100 };
  const { unassigned } = assignDeathsToPulls(pulls, npcIds, [{ gameId: 999, timestamp: 5 }]);
  assert.equal(unassigned.length, 1);
});
