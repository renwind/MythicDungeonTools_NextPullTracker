const test = require("node:test");
const assert = require("node:assert/strict");
const fixture = require("./fixtures/confirmed-combat.json");
const { buildCombatWaveDetail, buildCombatWaves, castWaves, bossPullNumbers, ascCountPerPull, splitWaveByAscCap, anchorCutPoints, cutPullsAt, distributeAscTimes } = require("./waves.js");
const { sumUsagePerWave } = require("./plan.js");

const input = () => structuredClone(fixture);
const groups = detail => detail.waves.map(w => w.pulls);

test("明确脱战保留零升腾波，Threechest 3+4 一升腾、5+6 双升腾", () => {
  const data = input();
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3, 4], [5, 6]]);
  const assignments = castWaves(data.castEvents, detail);
  assert.deepEqual(assignments, [0, 0, 2, 3, 3, 3]);
  assert.deepEqual(sumUsagePerWave(4, data.castEvents, assignments).map(u => u.asc), [1, 0, 1, 2]);
  assert.equal(detail.waves[3].bossStart, 300);
  assert.equal(detail.waves[3].firstBossAscendance, 302);
  assert.equal(detail.waves[3].castStart, 300);
});

test("缺少连续战斗证据时保留所有原分段，不从死亡空窗或三次升腾猜合并", () => {
  const data = input();
  data.combatSegments = [];
  data.deathSeconds = [10, 200, 400];
  data.deathPulls = [1, 3, 6];
  data.burstCasts = [30, 230];
  data.ascCasts = [30, 230, 420];
  assert.deepEqual(buildCombatWaves(data), [[1], [2], [3], [4], [5], [6]]);
});

test("没有时间数据仍保留零死亡及纯Boss原分段", () => {
  const detail = buildCombatWaveDetail({ pullCount: 3 });
  assert.deepEqual(groups(detail), [[1], [2], [3]]);
  assert.equal(detail.waves[2].start, null);
  assert.equal(detail.waves[2].end, null);
  assert.deepEqual(castWaves([{ skill: "asc", t: 50 }], detail), [-1]);
  assert.deepEqual(castWaves([{ skill: "asc", t: 50, pull: 3 }], detail), [2]);
});

test("明确脱战边界不能被临近死亡或爆发合并覆盖", () => {
  const data = input();
  data.combatSegments = [
    { start: 0, end: 55 }, { start: 60, end: 95 },
    { start: 100, end: 145 }, { start: 150, end: 239 }, { start: 240, end: 510 },
  ];
  assert.deepEqual(buildCombatWaves(data), [[1], [2], [3], [4], [5, 6]]);
});

test("Boss波升腾超上限2时按pull拆分；单个boss pull超限则保留一波并告警", () => {
  const data = input();
  data.castEvents.push({ skill: "asc", t: 470 }, { skill: "asc", t: 490 });
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3, 4], [5], [6]]);
  assert.equal(sumUsagePerWave(5, data.castEvents, castWaves(data.castEvents, detail))[4].asc, 4);
  assert.ok(detail.warnings.some(w => /pull 6/i.test(w) && /ascendance/i.test(w)));
});

test("纯小怪连续战斗含2次升腾拆成两波，reason=asc-cap", () => {
  const data = input();
  data.bossEncounters = [];
  data.castEvents = [{ skill: "asc", t: 110 }, { skill: "asc", t: 200 }];
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3], [4, 5, 6]]);
  assert.ok(detail.waves.filter(w => w.reason === "asc-cap").length >= 1);
});

test("再拆分后每波升腾不超上限，且 castWaves 归属与拆分自洽", () => {
  const data = input();
  data.castEvents.push({ skill: "asc", t: 470 }, { skill: "asc", t: 490 });
  const detail = buildCombatWaveDetail(data);
  const bossPulls = bossPullNumbers(data.bossEncounters);
  const usage = sumUsagePerWave(detail.waves.length, data.castEvents, castWaves(data.castEvents, detail));
  usage.forEach((u, i) => {
    const hasBoss = detail.waves[i].pulls.some(p => bossPulls.has(p));
    const isAtomicWarned = detail.waves[i].pulls.length === 1 &&
      detail.warnings.some(w => w.includes("pull " + detail.waves[i].pulls[0]));
    const cap = hasBoss ? 2 : 1;
    assert.ok(u.asc <= cap || isAtomicWarned, `wave ${i + 1} asc ${u.asc} exceeds cap ${cap} without atomic warning`);
  });
  assert.ok(castWaves(data.castEvents, detail).every(w => w >= 0));
});

test("Boss进战前的升腾归前一波，恰好在进战时归Boss波", () => {
  const data = input();
  data.castEvents = [{ skill: "asc", t: 299.999 }, { skill: "asc", t: 300 }];
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3, 4], [5, 6]]);
  assert.deepEqual(castWaves(data.castEvents, detail), [2, 3]);
});

test("施法原pull提示不能绕过已确认的Boss时间边界", () => {
  const data = input();
  data.castEvents = [{ skill: "asc", t: 299, pull: 5 }, { skill: "asc", t: 302, pull: 6 }];
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(castWaves(data.castEvents, detail), [2, 3]);
});

test("规则应用于每个Boss，不只首王，前一Boss的升腾不算下一Boss前爆发", () => {
  const data = input();
  data.pullCount = 8;
  data.pullTimings.push({ start: 520, end: 590 }, { start: 600, end: 800 });
  data.combatSegments[2].end = 810;
  data.bossEncounters.push({ start: 600, end: 800, pull: 8 });
  data.castEvents.push({ skill: "asc", t: 540 }, { skill: "asc", t: 620 }, { skill: "asc", t: 760 });
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3, 4], [5, 6], [7], [8]]);
  assert.deepEqual(castWaves(data.castEvents.slice(-3), detail), [4, 5, 5]);
});

test("缺少Boss进战证据时不按boss拆分，但小怪升腾上限1仍拆（reason=asc-cap，均分无告警）", () => {
  const data = input();
  data.bossEncounters = [];
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3], [4], [5, 6]]);
  assert.equal(detail.waves[2].reason, "asc-cap");
  assert.deepEqual(detail.warnings.filter(w => /ascendance/i.test(w)), []);
});

test("缺少连续战段的部分只保留原段，已确认的部分仍可合并", () => {
  const data = input();
  data.combatSegments = [{ start: 100, end: 510 }];
  assert.deepEqual(buildCombatWaves(data), [[1], [2], [3, 4], [5, 6]]);
});

test("战斗间空隙里的施法不猜最近波，显式pull归属可以用于战前药水", () => {
  const detail = buildCombatWaveDetail(input());
  assert.deepEqual(castWaves([{ skill: "pot", t: 58 }], detail), [-1]);
  assert.deepEqual(castWaves([{ skill: "pot", t: 58, pull: 2 }], detail), [1]);
});

test("无明确连续信息时，时间重叠的原段按最新进怪批次分配，不重排原段", () => {
  const data = { pullCount: 2, pullTimings: [{ start: 0, end: 100 }, { start: 50, end: 150 }] };
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2]]);
  assert.deepEqual(castWaves([{ skill: "asc", t: 75 }], detail), [1]);
});

test("无Boss起手升腾时不猜Boss前爆发拆分，但仍保留Boss结束边界", () => {
  const data = input();
  data.castEvents = [{ skill: "asc", t: 110 }];
  assert.deepEqual(buildCombatWaves(data), [[1], [2], [3, 4, 5, 6]]);
});

test("拒绝错序/重叠战斗区间、非法时间和越界pull", () => {
  const overlap = input();
  overlap.combatSegments[1].start = 40;
  assert.throws(() => buildCombatWaveDetail(overlap), /combatSegments/);
  const outOfOrder = input();
  outOfOrder.pullTimings[2].start = 30;
  assert.throws(() => buildCombatWaveDetail(outOfOrder), /pullTimings/);
  const invalidBoss = input();
  invalidBoss.bossEncounters[0].firstPull = 7;
  assert.throws(() => buildCombatWaveDetail(invalidBoss), /firstPull/);
  const missingBossStart = input();
  delete missingBossStart.bossEncounters[0].start;
  assert.throws(() => buildCombatWaveDetail(missingBossStart), /bossEncounters/);
  assert.throws(() => buildCombatWaveDetail({ pullCount: 0 }), /pullCount/);
  assert.throws(() => castWaves([{ skill: "asc", t: NaN }], buildCombatWaveDetail(input())), /cast/);
  assert.throws(() => castWaves([{ skill: "asc", t: 10, pull: 7 }], buildCombatWaveDetail(input())), /pull/);
});

test("Boss拖入批次不能越过明确的脱战边界", () => {
  const data = input();
  data.bossEncounters[0].firstPull = 2;
  assert.throws(() => buildCombatWaveDetail(data), /combat boundary/);
});

test("缺失中间批次时间时，上一波不能延伸覆盖未知批次", () => {
  const detail = buildCombatWaveDetail({
    pullCount: 3,
    pullTimings: [{ start: 0, end: 50 }, null, { start: 100, end: 150 }],
    combatSegments: [{ start: 0, end: 200 }],
  });
  assert.deepEqual(groups(detail), [[1], [2], [3]]);
  assert.deepEqual(castWaves([{ skill: "asc", t: 75 }], detail), [-1]);
  assert.deepEqual(castWaves([{ skill: "asc", t: 75, pull: 2 }], detail), [1]);
});

test("Boss前中间批次缺时间属于证据不足，不是已确认脱战冲突", () => {
  const data = input();
  data.bossEncounters[0].firstPull = 4;
  data.pullTimings[4] = null;
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3, 4], [5], [6]]);
  assert.ok(detail.warnings.length);
});

test("原批次时间跨明确脱战点时拒绝相互矛盾的证据", () => {
  assert.throws(() => buildCombatWaveDetail({
    pullCount: 2,
    pullTimings: [{ start: 0, end: 50 }, { start: 10, end: 40 }],
    combatSegments: [{ start: 0, end: 20 }, { start: 30, end: 60 }],
  }), /pullTimings.*combat/);
});

test("后一个Boss起手升腾不能作为前一个Boss末尾升腾", () => {
  const data = input();
  data.pullCount = 7;
  data.pullTimings.push({ start: 500, end: 700 });
  data.combatSegments[2].end = 710;
  data.bossEncounters.push({ start: 500, end: 700, pull: 7 });
  data.castEvents = [{ skill: "asc", t: 110 }, { skill: "asc", t: 500 }];
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3, 4, 5, 6], [7]]);
  assert.equal(detail.waves.some(w => w.bossStart === 300), false);
  assert.deepEqual(castWaves(data.castEvents, detail), [2, 3]);
});

test("后个Boss前的升腾不能倒灌到已经结束的前个Boss", () => {
  const data = {
    pullCount: 4,
    pullTimings: [{ start: 0, end: 10 }, { start: 10, end: 30 }, { start: 30, end: 40 }, { start: 40, end: 60 }],
    combatSegments: [{ start: 0, end: 60 }],
    bossEncounters: [{ start: 10, end: 30, pull: 2 }, { start: 40, end: 60, pull: 4, firstPull: 3 }],
    castEvents: [5, 15, 35, 45].map(t => ({ skill: "asc", t })),
  };
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3], [4]]);
  assert.deepEqual(castWaves(data.castEvents, detail), [0, 1, 2, 3]);
  assert.deepEqual(castWaves([{ skill: "asc", t: 35, pull: 3 }], detail), [2]);
  assert.equal(detail.waves[1].castEnd, 30);
});

test("Boss结束到下一批怪之间的施法不延长到已经结束的Boss波", () => {
  const data = input();
  data.pullCount = 7;
  data.pullTimings.push({ start: 520, end: 600 });
  data.combatSegments[2].end = 610;
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3, 4], [5, 6], [7]]);
  assert.equal(detail.waves[3].castEnd, 500);
  assert.deepEqual(castWaves([{ skill: "asc", t: 510 }], detail), [-1]);
  assert.deepEqual(castWaves([{ skill: "pot", t: 510, pull: 7 }], detail), [4]);
});

test("Boss拖入批次引用前一个Boss时拒绝矛盾输入，不能覆盖计数边界", () => {
  assert.throws(() => buildCombatWaveDetail({
    pullCount: 3,
    pullTimings: [{ start: 0, end: 10 }, { start: 10, end: 30 }, { start: 30, end: 60 }],
    combatSegments: [{ start: 0, end: 60 }],
    bossEncounters: [{ start: 10, end: 30, pull: 2 }, { start: 40, end: 60, pull: 3, firstPull: 2 }],
    castEvents: [5, 15, 35, 45].map(t => ({ skill: "asc", t })),
  }), /bossEncounters.*order|previous boss/);
});

test("分组和技能分配不依赖死亡时间或原数组被排序的副作用", () => {
  const data = input();
  const before = JSON.stringify(data);
  const first = buildCombatWaves(data);
  data.deathSeconds = [1, 1000];
  data.deathPulls = [6, 1];
  assert.deepEqual(buildCombatWaves(data), first);
  delete data.deathSeconds;
  delete data.deathPulls;
  assert.equal(JSON.stringify(data), before);
});

test("bossPullNumbers 收集每个 boss 的 boss pull 号", () => {
  assert.deepEqual([...bossPullNumbers([{ pull: 6, firstPull: 5 }, { pull: 9 }])].sort((a, b) => a - b), [6, 9]);
  assert.deepEqual([...bossPullNumbers([])], []);
});

test("ascCountPerPull 按波内 pull 起点 Voronoi 归属升腾，窗口重叠时归较晚起点", () => {
  const casts = [{ skill: "asc", t: 302 }, { skill: "asc", t: 440 }, { skill: "asc", t: 11 }];
  const waves = [
    { pulls: [1], castStart: 0, castEnd: 55, segment: 0 },
    { pulls: [2], castStart: null, castEnd: null, segment: -1 },
    { pulls: [3, 4], castStart: null, castEnd: null, segment: -1 },
    { pulls: [5, 6], castStart: 300, castEnd: 500, segment: 2, bossStart: 300 },
  ];
  const timings = [
    { start: 0, end: 50 }, { start: 60, end: 90 }, { start: 100, end: 145 },
    { start: 150, end: 230 }, { start: 240, end: 350 }, { start: 300, end: 500 },
  ];
  const per = ascCountPerPull(casts, waves, timings, 6);
  assert.equal(per.get(6), 2);   // t=302,440 -> pull6 (later start wins the 240/300 overlap)
  assert.equal(per.get(1), 1);   // t=11 -> pull1
  assert.equal(per.get(5) || 0, 0);
});

test("splitWaveByAscCap：小怪波 2 次升腾拆成两波（各 <=1）", () => {
  const warnings = [];
  const { groups } = splitWaveByAscCap([3, 4], new Map([[3, 1], [4, 1]]), new Set(), warnings);
  assert.deepEqual(groups, [[3], [4]]);
  assert.deepEqual(warnings, []);
});

test("splitWaveByAscCap：含 boss 的波允许 2 次升腾不拆", () => {
  const warnings = [];
  const { groups } = splitWaveByAscCap([5, 6], new Map([[5, 0], [6, 2]]), new Set([6]), warnings);
  assert.deepEqual(groups, [[5, 6]]);
  assert.deepEqual(warnings, []);
});

test("splitWaveByAscCap：单个 boss pull 3 次升腾无法拆，保留一波并告警", () => {
  const warnings = [];
  const { groups } = splitWaveByAscCap([6], new Map([[6, 3]]), new Set([6]), warnings);
  assert.deepEqual(groups, [[6]]);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /pull 6/i);
  assert.match(warnings[0], /ascendance/i);
});

test("splitWaveByAscCap：混合波按含 boss 用上限 2，切出的纯小怪子波按 1", () => {
  const warnings = [];
  const { groups } = splitWaveByAscCap([7, 8, 9], new Map([[7, 1], [8, 1], [9, 1]]), new Set([9]), warnings);
  assert.deepEqual(groups, [[7], [8, 9]]);
  assert.deepEqual(warnings, []);
});

test("splitWaveByAscCap：0 升腾波不拆", () => {
  const { groups, warnings } = splitWaveByAscCap([1, 2], new Map(), new Set(), []);
  assert.deepEqual(groups, [[1, 2]]);
  assert.deepEqual(warnings, []);
});

test("anchorCutPoints：切点=最高血 pull（排除首 pull），血量相同取 pull 号小者", () => {
  // pulls [1,2,3]，pull2 血最高 → k=2 取 1 个切点 = pull2
  assert.deepEqual(anchorCutPoints([1, 2, 3], [6500000, 9700000, 3600000], 2), [2]);
  // pull1 最高但被排除 → 退到次高的 pull2
  assert.deepEqual(anchorCutPoints([1, 2, 3], [9700000, 5000000, 3600000], 2), [2]);
  // pull2/pull3 同血 → 取号小的 pull2
  assert.deepEqual(anchorCutPoints([1, 2, 3], [1000000, 5000000, 5000000], 2), [2]);
  // k=3 取 2 个切点，按血量降序 = pull2(9M), pull4(7M)（升序返回）
  assert.deepEqual(anchorCutPoints([1, 2, 3, 4], [1, 9000000, 3000000, 7000000], 3), [2, 4]);
  // 缺 pullMaxHealth → 全 0，tie 取号小者：candidates[2,3,4] → [2,3]
  assert.deepEqual(anchorCutPoints([1, 2, 3, 4], undefined, 3), [2, 3]);
});

test("cutPullsAt：按升序切点分组，切点等于组首时不产生空组", () => {
  assert.deepEqual(cutPullsAt([1, 2, 3], [2]), [[1], [2, 3]]);
  assert.deepEqual(cutPullsAt([1, 2, 3, 4], [2, 4]), [[1], [2, 3], [4]]);
  assert.deepEqual(cutPullsAt([1, 2, 3], []), [[1, 2, 3]]);
});

test("distributeAscTimes：cap1 均分，边界取相邻升腾中点", () => {
  // 2 升腾 @30/150，窗口 [10,200] → 中点 90；两段 [10,90] [90,200]
  const w = distributeAscTimes([150, 30], 2, 1, 10, 200);
  assert.deepEqual(w, [{ castStart: 10, castEnd: 90 }, { castStart: 90, castEnd: 200 }]);
});

test("distributeAscTimes：cap2 贪心每组填满至 2", () => {
  // 4 升腾 @100/200/300/400，k=2 cap=2，窗口 [50,500]
  // 组0={100,200} 组1={300,400}，边界=中点(200,300)=250
  const w = distributeAscTimes([100, 200, 300, 400], 2, 2, 50, 500);
  assert.deepEqual(w, [{ castStart: 50, castEnd: 250 }, { castStart: 250, castEnd: 500 }]);
});

test("distributeAscTimes：单组直接返回整窗", () => {
  assert.deepEqual(distributeAscTimes([42], 1, 1, 0, 100), [{ castStart: 0, castEnd: 100 }]);
});

const sharedStart = (pullMaxHealth) => ({
  pullCount: 3,
  pullTimings: [{ start: 10, end: 200 }, { start: 10, end: 200 }, { start: 10, end: 200 }],
  combatSegments: [{ start: 10, end: 200 }],
  castEvents: [{ skill: "asc", t: 30 }, { skill: "asc", t: 150 }],
  ...(pullMaxHealth ? { pullMaxHealth } : {}),
});

test("小怪段内 pull 起始时刻相同时按最高血 pull 锚点拆分并均分升腾", () => {
  const data = sharedStart([6500000, 9700000, 3600000]); // pull2 = 大精英
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2, 3]]);
  assert.deepEqual(sumUsagePerWave(2, data.castEvents, castWaves(data.castEvents, detail)).map(u => u.asc), [1, 1]);
  assert.deepEqual(detail.warnings, []);
  assert.equal(detail.waves[1].reason, "asc-cap");
});

test("锚点是首 pull 时切点退到次高血 pull", () => {
  const detail = buildCombatWaveDetail(sharedStart([9700000, 5000000, 3600000]));
  assert.deepEqual(groups(detail), [[1], [2, 3]]);
});

test("缺 pullMaxHealth 时锚点回退为 pull 号小者优先", () => {
  const detail = buildCombatWaveDetail(sharedStart(undefined));
  assert.deepEqual(groups(detail), [[1], [2, 3]]);
});

test("单 pull 小怪波升腾超上限无法拆，保留并告警", () => {
  const detail = buildCombatWaveDetail({
    pullCount: 1,
    pullTimings: [{ start: 10, end: 200 }],
    combatSegments: [{ start: 10, end: 200 }],
    castEvents: [{ skill: "asc", t: 30 }, { skill: "asc", t: 150 }],
    pullMaxHealth: [9700000],
  });
  assert.deepEqual(groups(detail), [[1]]);
  assert.ok(detail.warnings.some(w => /pull 1/i.test(w) && /ascendance/i.test(w)));
});
