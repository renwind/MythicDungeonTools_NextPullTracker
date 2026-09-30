const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { buildCombatWaves } = require("./waves.js");
const { decodeMdtString } = require("./mdtstring.js");
const { loadNpcIds, assignDeathsToPulls } = require("./align.js");

const FIXTURE = path.join(__dirname, "fixtures/nalo22-C9pFgkRJwMvHB4KY.input.json");
// 对齐要读 MDT 安装目录里的副本敌人表，换机器时路径可能不在 -> 跳过而不是红。
const DUNGEON_FILE = JSON.parse(fs.readFileSync(FIXTURE, "utf8")).mdtDungeonFile;
const SKIP = fs.existsSync(DUNGEON_FILE) ? false : "MDT dungeon data not found: " + DUNGEON_FILE;

test("死亡间隔切簇：空窗无爆发则不合并", () => {
  const groups = buildCombatWaves({
    deathSeconds: [10, 12, 100, 102, 200, 202],
    deathPulls: [1, 1, 2, 2, 3, 3],
    burstCasts: [50, 150],
    ascCasts: [50, 150],
  });
  assert.deepEqual(groups, [[1], [2], [3]]);
});

test("空窗内战中爆发（距下簇首死 >=60s）合并两簇", () => {
  const groups = buildCombatWaves({
    deathSeconds: [10, 12, 100, 102],
    deathPulls: [1, 1, 2, 2],
    burstCasts: [30],
    ascCasts: [30],
  });
  assert.deepEqual(groups, [[1, 2]]);
});

test("接战爆发（距下簇首死 <60s）不合并", () => {
  const groups = buildCombatWaves({
    deathSeconds: [10, 12, 100, 102],
    deathPulls: [1, 1, 2, 2],
    burstCasts: [85],
    ascCasts: [85],
  });
  assert.deepEqual(groups, [[1], [2]]);
});

test("合并组内升腾超上限时在簇边界再切", () => {
  // 三簇被战中爆发串成一组（每段空窗的 cast 距下簇首死 >=60s），
  // 但每簇各 1 次升腾、上限 2 -> 在第三簇边界再切成两波
  const groups = buildCombatWaves({
    deathSeconds: [10, 100, 200],
    deathPulls: [1, 2, 3],
    burstCasts: [30, 130],
    ascCasts: [10, 100, 200],
  });
  assert.deepEqual(groups, [[1, 2], [3]]);
});

test("pull 归簇按死亡多数票：拉远击杀不把整条 pull 拖进邻簇", () => {
  // pull1 三只死在第一簇、一只死在第二簇 -> 仍属第一簇；第二簇只有 pull2
  const groups = buildCombatWaves({
    deathSeconds: [10, 12, 14, 100, 102, 104],
    deathPulls: [1, 1, 1, 2, 2, 1],
    burstCasts: [],
    ascCasts: [],
  });
  assert.deepEqual(groups, [[1], [2]]);
});

test("fixture 锁定：+22 纳洛拉克洞穴切出 11 波", { skip: SKIP }, () => {
  const input = JSON.parse(fs.readFileSync(FIXTURE, "utf8"));
  const pulls = decodeMdtString(input.routeString).value.pulls;
  const npcIds = loadNpcIds(fs.readFileSync(input.mdtDungeonFile, "utf8"));
  const aligned = assignDeathsToPulls(pulls, npcIds, input.deathEvents);
  const casts = input.castEvents;
  const groups = buildCombatWaves({
    deathSeconds: aligned.deathSeconds,
    deathPulls: aligned.deathPulls,
    burstCasts: casts.filter((c) => c.skill !== "pot").map((c) => c.t),
    ascCasts: casts.filter((c) => c.skill === "asc").map((c) => c.t),
  });
  assert.deepEqual(groups, [
    [1], [2], [3, 4], [5, 6], [7], [8], [9], [10], [11], [12, 13, 14], [15, 16],
  ]);
});
