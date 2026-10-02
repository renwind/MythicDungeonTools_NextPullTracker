# 升腾上限分波规则 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `tools/wclplan` 分波逻辑中新增「升腾上限拆分」：含 boss 的波升腾上限 2、纯小怪波上限 1，超限按 MDT 路线 pull 边界贪心再拆，单 pull 超限则保留并告警。

**Architecture:** 保留现有「连续战斗段合并 + boss 进战拆分」两级证据分波不动，在其产出的波次之上追加一道 asc-cap 再拆分 pass（方案 A）。升腾按 pull 归属用与 `castWaves` 一致的 Voronoi（按 pull 起点，波内约束），拆分后重算每波 cast 窗口，保证最终 `castWaves` 归属与拆分自洽。拆分纯函数化、可独立单测。

**Tech Stack:** Node 24（`node --test`）、纯函数、既有 `tools/wclplan/{waves,plan,cli,report}.js` 与 `fixtures/confirmed-combat.json`。

**设计依据:** `docs/superpowers/specs/2026-10-02-asc-cap-wave-splitting-design.md`

---

## File Structure

- `tools/wclplan/waves.js`（改）：抽出 `computeWaveWindows` 助手；新增 `bossPullNumbers`、`ascCountPerPull`、`splitWaveByAscCap` 三个纯函数；在 `buildCombatWaveDetail` 末尾接入再拆分 pass。导出新增函数供单测。
- `tools/wclplan/waves.test.js`（改）：反转既有「boss 3–4 升腾算一波」用例；新增小怪拆分、单 pull 原子告警、混合波上限、归属自洽用例。
- `tools/wclplan/cli.test.js`（核对，通常不改）：fixture `confirmed-combat.json` 的 boss 波恰为 2 次升腾、不触发拆分，故现有断言（groups `[[1],[2],[3,4],[5,6]]`、routeKey `648e7d8d` 等）应保持不变——本计划以其为回归护栏。
- `tools/wclplan/report.js`（改）：更新第 300 行说明文案（不再声称「不按施法次数分波」），补充 asc-cap 规划拆分的说明。
- `tools/wclplan/report.test.js`（核对）：若断言了旧文案则同步更新。
- 重导产物：`deploy/wcl-Mcdmtnwx4h6CYHNT-f11/`、`deploy/wcl-CxtJgwnRbAKja36z-f11/`。

**运行测试的统一命令**（本仓库本机无 `busted`，node 侧用 `node --test`）：
`node --test tools/wclplan/waves.test.js`、`node --test tools/wclplan/cli.test.js`、`node --test tools/wclplan/*.test.js`。

---

## Task 1: 抽出 `computeWaveWindows` 助手（纯重构，行为不变）

**Files:**
- Modify: `tools/wclplan/waves.js`（当前 114–134 行的窗口计算内联块）
- Test: `tools/wclplan/waves.test.js`（现有全套作回归）

- [ ] **Step 1: 先跑现有测试建立绿基线**

Run: `node --test tools/wclplan/waves.test.js`
Expected: 全部 PASS（记录通过数，重构后必须一致）。

- [ ] **Step 2: 抽出窗口计算为模块级函数**

在 `waves.js` 中 `buildCombatWaveDetail` 之前新增（逐字复制现有 119–134 行逻辑，参数化依赖）：

```js
// 由波次的 pulls/segment/bossStart 计算 start/end/castStart/castEnd 与 reason，
// 并按后波 castStart 夹逼前波 castEnd。bossEnds: Map(pullNumber -> bossEndTime)。
function computeWaveWindows(waves, { timings, segments, bossEnds }) {
  for (const wave of waves) {
    const known = wave.pulls.map(p => timings[p - 1]).filter(t => t !== null);
    wave.start = known.length ? Math.min(...known.map(t => t.start)) : null;
    wave.end = known.length ? Math.max(...known.map(t => t.end)) : null;
    wave.castStart = wave.bossStart ?? wave.start;
    wave.castEnd = wave.segment === -1 ? wave.end : segments[wave.segment].end;
    const bossEnd = bossEnds.get(wave.pulls.at(-1));
    if (bossEnd !== undefined && wave.castEnd !== null) wave.castEnd = Math.min(wave.castEnd, bossEnd);
    if (wave.bossStart !== undefined) wave.reason = "boss-entry";
    else if (wave.reason !== "asc-cap" && wave.pulls.length > 1) wave.reason = "confirmed-combat";
  }
  for (let i = 0; i < waves.length - 1; i++) {
    const wave = waves[i], next = waves[i + 1];
    if (next.castStart === null) wave.castEnd = wave.end;
    else if (wave.castEnd !== null) wave.castEnd = Math.min(wave.castEnd, next.castStart);
  }
}
```

注意：`reason` 分支新增了 `wave.reason !== "asc-cap"` 守卫（为 Task 4 预留；本任务中不会有 asc-cap 波，行为等价）。

- [ ] **Step 3: 在 `buildCombatWaveDetail` 内改用该函数**

把现有 114–134 行替换为：

```js
  const waves = [];
  for (let i = 0; i < pullCount; i++) {
    if (cuts.has(i)) waves.push({ pulls: [], segment: segmentOf[i], reason: "original", ...bossCuts.get(i) });
    waves.at(-1).pulls.push(i + 1);
  }
  computeWaveWindows(waves, { timings, segments, bossEnds });
  return { waves, pullCount, warnings };
```

- [ ] **Step 4: 跑测试确认重构无回归**

Run: `node --test tools/wclplan/waves.test.js`
Expected: 与 Step 1 相同的通过数、全 PASS。

Run: `node --test tools/wclplan/cli.test.js`
Expected: 全 PASS（fixture 断言不变）。

- [ ] **Step 5: 提交**

```bash
git add tools/wclplan/waves.js
git commit -m "refactor: extract computeWaveWindows from buildCombatWaveDetail"
```

---

## Task 2: `bossPullNumbers` 与 `ascCountPerPull` 纯函数

**Files:**
- Modify: `tools/wclplan/waves.js`（新增函数 + 导出）
- Test: `tools/wclplan/waves.test.js`（新增用例）

- [ ] **Step 1: 写失败测试**

在 `waves.test.js` 末尾（`require` 处补充导入 `bossPullNumbers, ascCountPerPull`）新增：

```js
const { bossPullNumbers, ascCountPerPull } = require("./waves.js");

test("bossPullNumbers 收集每个 boss 的 boss pull 号", () => {
  assert.deepEqual([...bossPullNumbers([{ pull: 6, firstPull: 5 }, { pull: 9 }])].sort((a, b) => a - b), [6, 9]);
  assert.deepEqual([...bossPullNumbers([])], []);
});

test("ascCountPerPull 按波内 pull 起点 Voronoi 归属升腾，窗口重叠时归较晚起点", () => {
  // pull5 [240,350] 与 pull6 [300,500] 窗口重叠；t=302 归起点更晚的 pull6。
  const timings = [null, null, null, null, { start: 240, end: 350 }, { start: 300, end: 500 }];
  const waves = [
    { pulls: [1], castStart: 0, castEnd: 55, segment: 0 },
    { pulls: [5, 6], castStart: 300, castEnd: 500, segment: 2, bossStart: 300 },
  ];
  // 补齐 castWaves 需要的字段：wave.castStart/castEnd 已给；其余波用 null 时间不影响本例。
  const casts = [{ skill: "asc", t: 302 }, { skill: "asc", t: 440 }, { skill: "asc", t: 11 }];
  const full = [
    { pulls: [1], castStart: 0, castEnd: 55, segment: 0 },
    { pulls: [2], castStart: null, castEnd: null, segment: -1 },
    { pulls: [3, 4], castStart: null, castEnd: null, segment: -1 },
    { pulls: [5, 6], castStart: 300, castEnd: 500, segment: 2, bossStart: 300 },
  ];
  const per = ascCountPerPull(casts, full, [
    { start: 0, end: 50 }, { start: 60, end: 90 }, { start: 100, end: 145 },
    { start: 150, end: 230 }, { start: 240, end: 350 }, { start: 300, end: 500 },
  ], 6);
  assert.equal(per.get(6), 2);   // t=302,440 -> pull6
  assert.equal(per.get(1), 1);   // t=11 -> pull1
  assert.equal(per.get(5) || 0, 0);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node --test tools/wclplan/waves.test.js`
Expected: FAIL —`bossPullNumbers is not a function` / `ascCountPerPull is not a function`（导出缺失）。

- [ ] **Step 3: 实现两个函数并导出**

在 `waves.js` 新增（放在 `computeWaveWindows` 之后）：

```js
const ASC_CAP = { boss: 2, trash: 1 };

// boss pull 号集合：仅 bossEncounters[].pull 本身（firstPull..pull-1 是进战前小怪，不算 boss pull）。
function bossPullNumbers(bossEncounters) {
  const set = new Set();
  for (const boss of bossEncounters || []) {
    if (Number.isInteger(boss.pull)) set.add(boss.pull);
  }
  return set;
}

// 升腾按 pull 归属：先用 castWaves 把每条 asc 落到波，再在波内按 pull 起点 Voronoi
// （最后一个 start <= t 的 pull；都晚于 t 则归首个 pull）。与 castWaves 的窗口归属自洽。
function ascCountPerPull(casts, waves, timings, pullCount) {
  const perPull = new Map();
  const assign = castWaves(casts, { waves, pullCount });
  casts.forEach((cast, i) => {
    if (cast.skill !== "asc") return;
    const w = assign[i];
    if (w < 0) return;
    const pulls = waves[w].pulls;
    let target = pulls[0];
    for (const p of pulls) {
      const t = timings[p - 1];
      if (t !== null && t.start <= cast.t) target = p;
    }
    perPull.set(target, (perPull.get(target) || 0) + 1);
  });
  return perPull;
}
```

在文件底部 `module.exports` 补充导出：

```js
module.exports = { buildCombatWaves, buildCombatWaveDetail, castWaves, bossPullNumbers, ascCountPerPull, splitWaveByAscCap, ASC_CAP };
```

（`splitWaveByAscCap` 在 Task 3 实现；本步先加进导出列表会导致 undefined——改为 Task 3 再补该导出名。本任务只导出 `bossPullNumbers, ascCountPerPull, ASC_CAP`。）

- [ ] **Step 4: 跑测试确认通过**

Run: `node --test tools/wclplan/waves.test.js`
Expected: 新增 2 用例 PASS，其余仍 PASS。

- [ ] **Step 5: 提交**

```bash
git add tools/wclplan/waves.js tools/wclplan/waves.test.js
git commit -m "feat: add bossPullNumbers and ascCountPerPull helpers"
```

---

## Task 3: `splitWaveByAscCap` 贪心拆分纯函数

**Files:**
- Modify: `tools/wclplan/waves.js`（新增函数 + 补导出名）
- Test: `tools/wclplan/waves.test.js`（新增用例）

- [ ] **Step 1: 写失败测试**

在 `waves.test.js` 的 require 补 `splitWaveByAscCap`，新增：

```js
test("splitWaveByAscCap：小怪波 2 次升腾拆成两波（各 <=1）", () => {
  const ascPerPull = new Map([[3, 1], [4, 1]]);
  const warnings = [];
  const { groups } = splitWaveByAscCap([3, 4], ascPerPull, new Set(), warnings);
  assert.deepEqual(groups, [[3], [4]]);
  assert.deepEqual(warnings, []);
});

test("splitWaveByAscCap：含 boss 的波允许 2 次升腾不拆", () => {
  const ascPerPull = new Map([[5, 0], [6, 2]]);
  const warnings = [];
  const { groups } = splitWaveByAscCap([5, 6], ascPerPull, new Set([6]), warnings);
  assert.deepEqual(groups, [[5, 6]]);
  assert.deepEqual(warnings, []);
});

test("splitWaveByAscCap：单个 boss pull 3 次升腾无法拆，保留一波并告警", () => {
  const ascPerPull = new Map([[6, 3]]);
  const warnings = [];
  const { groups } = splitWaveByAscCap([6], ascPerPull, new Set([6]), warnings);
  assert.deepEqual(groups, [[6]]);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /pull 6/i);
  assert.match(warnings[0], /ascendance/i);
});

test("splitWaveByAscCap：混合波按含 boss 用上限 2，切出的纯小怪子波按 1", () => {
  // pulls [7(trash,1asc), 8(trash,1asc), 9(boss,1asc)]：7 单独（1<=1），8+9 合并（含 boss，2<=2）
  const ascPerPull = new Map([[7, 1], [8, 1], [9, 1]]);
  const warnings = [];
  const { groups } = splitWaveByAscCap([7, 8, 9], ascPerPull, new Set([9]), warnings);
  assert.deepEqual(groups, [[7], [8, 9]]);
  assert.deepEqual(warnings, []);
});

test("splitWaveByAscCap：0 升腾波不拆", () => {
  const { groups, warnings } = splitWaveByAscCap([1, 2], new Map(), new Set(), []);
  assert.deepEqual(groups, [[1, 2]]);
  assert.deepEqual(warnings, []);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node --test tools/wclplan/waves.test.js`
Expected: FAIL — `splitWaveByAscCap is not a function`。

- [ ] **Step 3: 实现并补导出**

在 `waves.js` 新增：

```js
// 贪心把一波的 pulls 拆成若干子波，使每个子波升腾 <= 其上限（含 boss pull 用 2，否则 1）。
// 单个 pull 自身升腾即超上限时无法再拆，单独成波并向 warnings 追加一条告警。
// 返回 { groups: [[pull,...],...], warnings }（warnings 就地追加传入数组并回传）。
function splitWaveByAscCap(pulls, ascPerPull, bossPulls, warnings) {
  const capOf = hasBoss => (hasBoss ? ASC_CAP.boss : ASC_CAP.trash);
  const groups = [];
  let cur = [], curAsc = 0, curBoss = false;
  const openWith = (pull) => {
    const asc = ascPerPull.get(pull) || 0;
    const isBoss = bossPulls.has(pull);
    cur = [pull]; curAsc = asc; curBoss = isBoss;
    if (asc > capOf(isBoss)) {
      warnings.push("pull " + pull + " has " + asc + " ascendance in a single pull (cap " +
        capOf(isBoss) + "); cannot split further, kept as one wave");
    }
  };
  for (const pull of pulls) {
    const asc = ascPerPull.get(pull) || 0;
    const isBoss = bossPulls.has(pull);
    if (cur.length === 0) { openWith(pull); continue; }
    const nextBoss = curBoss || isBoss;
    if (curAsc + asc <= capOf(nextBoss)) {
      cur.push(pull); curAsc += asc; curBoss = nextBoss;
    } else {
      groups.push(cur);
      openWith(pull);
    }
  }
  if (cur.length) groups.push(cur);
  return { groups: groups.length ? groups : [pulls.slice()], warnings };
}
```

在 `module.exports` 补上 `splitWaveByAscCap`（此时完整导出）：

```js
module.exports = { buildCombatWaves, buildCombatWaveDetail, castWaves, bossPullNumbers, ascCountPerPull, splitWaveByAscCap, ASC_CAP };
```

- [ ] **Step 4: 跑测试确认通过**

Run: `node --test tools/wclplan/waves.test.js`
Expected: 新增 5 用例 PASS，其余 PASS。

- [ ] **Step 5: 提交**

```bash
git add tools/wclplan/waves.js tools/wclplan/waves.test.js
git commit -m "feat: add splitWaveByAscCap greedy asc-cap splitter"
```

---

## Task 4: 接入 `buildCombatWaveDetail`（再拆分 pass）并反转既有 boss 用例

**Files:**
- Modify: `tools/wclplan/waves.js`（`buildCombatWaveDetail` 返回前）
- Test: `tools/wclplan/waves.test.js`（反转 line 50 用例 + 新增端到端用例）

- [ ] **Step 1: 反转既有「boss 3–4 升腾算一波」用例为失败测试**

把 `waves.test.js` 中现有用例

```js
test("Boss内部三次或四次升腾仍属于同一Boss波", () => {
  const data = input();
  data.castEvents.push({ skill: "asc", t: 470 }, { skill: "asc", t: 490 });
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3, 4], [5, 6]]);
  assert.equal(sumUsagePerWave(4, data.castEvents, castWaves(data.castEvents, detail))[3].asc, 4);
});
```

整体替换为：

```js
test("Boss波升腾超上限2时按pull拆分；单个boss pull超限则保留一波并告警", () => {
  const data = input();
  // boss pull6 现有 t=302,440 两次升腾，再推 470,490 -> pull6 共 4 次；pull5(进战前小怪) 0 次。
  data.castEvents.push({ skill: "asc", t: 470 }, { skill: "asc", t: 490 });
  const detail = buildCombatWaveDetail(data);
  // [5,6] 拆开：pull5(0升腾)单独成波，pull6(4升腾、单pull超上限2)保留并告警。
  assert.deepEqual(groups(detail), [[1], [2], [3, 4], [5], [6]]);
  assert.equal(sumUsagePerWave(5, data.castEvents, castWaves(data.castEvents, detail))[4].asc, 4);
  assert.ok(detail.warnings.some(w => /pull 6/i.test(w) && /ascendance/i.test(w)));
});

test("纯小怪连续战斗含2次升腾拆成两波，reason=asc-cap", () => {
  const data = input();
  // 段[2]覆盖 pull3..6；把 boss 移除使 [3,4,5,6] 成一整段连续小怪战斗。
  data.bossEncounters = [];
  // pull3 一次(t=110)、pull4 一次(t=200) -> [3,4,5,6] 含 2 次升腾，按上限1拆。
  data.castEvents = [{ skill: "asc", t: 110 }, { skill: "asc", t: 200 }];
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3], [4], [5, 6]]);
  const ascCapWaves = detail.waves.filter(w => w.reason === "asc-cap");
  assert.ok(ascCapWaves.length >= 1);
});
```

> 说明：第二个用例中 `[5,6]` 仍为一波（0 升腾，未触发拆分），`[3]`、`[4]` 因各含 1 次升腾被拆开、reason 标为 `asc-cap`。若实际 `buildCombatWaveDetail` 对该输入的分组与断言不符，以「每波升腾 ≤ 上限、拆分点标 asc-cap」为准调整断言中的具体分组，但不得放宽上限语义。

- [ ] **Step 2: 跑测试确认失败**

Run: `node --test tools/wclplan/waves.test.js`
Expected: 上述两用例 FAIL（当前无再拆分逻辑，groups 仍为 `[[1],[2],[3,4],[5,6]]` 等旧值）。

- [ ] **Step 3: 在 `buildCombatWaveDetail` 返回前接入再拆分 pass**

把 Task 1 Step 3 得到的结尾：

```js
  computeWaveWindows(waves, { timings, segments, bossEnds });
  return { waves, pullCount, warnings };
```

替换为：

```js
  computeWaveWindows(waves, { timings, segments, bossEnds });

  // 升腾上限再拆分（用户确认的规划规则，覆盖连续战斗合并）：含 boss 的波上限 2、纯小怪上限 1。
  const bossPulls = bossPullNumbers(bosses);
  const ascPerPull = ascCountPerPull(casts, waves, timings, pullCount);
  const splitWaves = [];
  for (const wave of waves) {
    const { groups: subGroups } = splitWaveByAscCap(wave.pulls, ascPerPull, bossPulls, warnings);
    if (subGroups.length === 1) { splitWaves.push(wave); continue; }
    for (const pulls of subGroups) {
      const containsBoss = pulls.some(p => bossPulls.has(p));
      const sub = { pulls, segment: wave.segment, reason: "asc-cap" };
      if (wave.bossStart !== undefined && containsBoss) {
        sub.bossStart = wave.bossStart;
        sub.firstBossAscendance = wave.firstBossAscendance;
      }
      splitWaves.push(sub);
    }
  }
  computeWaveWindows(splitWaves, { timings, segments, bossEnds });
  return { waves: splitWaves, pullCount, warnings };
```

- [ ] **Step 4: 跑测试确认通过 + 归属自洽**

Run: `node --test tools/wclplan/waves.test.js`
Expected: 全 PASS（含反转用例、新增用例，以及所有既有边界用例）。

Run: `node --test tools/wclplan/cli.test.js`
Expected: 全 PASS。fixture `confirmed-combat.json` 的 boss 波恰 2 次升腾、不触发拆分，故 groups/routeKey/pack 断言不变——若此处变红，说明再拆分误伤了未超限的波，必须修 `splitWaveByAscCap`/归属逻辑，**不得**改 cli.test.js 断言迁就。

- [ ] **Step 5: 补一条归属自洽断言（防拆分后 castWaves 与 ascPerPull 不一致）**

在 `waves.test.js` 新增：

```js
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
```

Run: `node --test tools/wclplan/waves.test.js`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add tools/wclplan/waves.js tools/wclplan/waves.test.js
git commit -m "feat: split waves by ascendance cap (boss 2 / trash 1)"
```

---

## Task 5: 更新 `report.js` 说明文案

**Files:**
- Modify: `tools/wclplan/report.js:300`
- Test: `tools/wclplan/report.test.js`（核对是否断言旧文案）

- [ ] **Step 1: 核对 report.test.js 是否锁定旧文案**

Run: `grep -n "不按施法次数" tools/wclplan/report.test.js`
Expected: 若无输出，跳到 Step 2；若有，记下该行，Step 3 同步更新断言。

- [ ] **Step 2: 更新 report.js 第 300 行说明**

把

```js
<div class="note">仅展示 summary 中已确认的接战/脱战边界与 Boss 进场证据；Boss 进场重置爆发计数（boss-entry），不按施法次数猜测分波。缺失边界标为「未确认」。</div>
```

替换为

```js
<div class="note">展示 summary 中已确认的接战/脱战边界与 Boss 进场证据；Boss 进场重置爆发计数（boss-entry）。此外按用户规划规则拆分：含 Boss 波升腾上限 2、纯小怪波上限 1（asc-cap），单个 pull 超限则保留并在告警区标注。缺失边界标为「未确认」。</div>
```

- [ ] **Step 3: 若 Step 1 命中，同步更新 report.test.js 的对应断言文本**

将断言中的旧子串替换为新文案中稳定存在的子串（例如 `/asc-cap/` 或 `/升腾上限/`）。

- [ ] **Step 4: 跑测试**

Run: `node --test tools/wclplan/report.test.js`
Expected: 全 PASS。

- [ ] **Step 5: 提交**

```bash
git add tools/wclplan/report.js tools/wclplan/report.test.js
git commit -m "docs: report note reflects asc-cap planning split"
```

---

## Task 6: 全套回归 + 重导两份产物

**Files:**
- 产物：`deploy/wcl-Mcdmtnwx4h6CYHNT-f11/`、`deploy/wcl-CxtJgwnRbAKja36z-f11/`

- [ ] **Step 1: node 全套测试**

Run: `node --test tools/wclplan/*.test.js`
Expected: 全 PASS，0 fail（记录总数）。

- [ ] **Step 2: Lua 侧不受影响的确认**

本规则只改 node 导出侧，不改 Lua 导入/渲染语法。跑一次 Lua 导入测试确认无回归：
Run: `node .tmp-npt-task/luaenv/minibusted.js spec/ImportPlan_spec.lua`
Expected: 17 passed, 0 failed。

- [ ] **Step 3: 重导密谋小径**

Run: `node tools/wclplan/cli.js deploy/wcl-Mcdmtnwx4h6CYHNT-f11/input.json deploy/wcl-Mcdmtnwx4h6CYHNT-f11 --granularity=combat`
Expected: 打印新的 `groups`（波数 ≥ 原 11）、新 `routeKey`、新的 importplanpack/importratiopack 行。记录新 routeKey。

Run: `node tools/wclplan/report.js deploy/wcl-Mcdmtnwx4h6CYHNT-f11/input.json deploy/wcl-Mcdmtnwx4h6CYHNT-f11`
Expected: 写出 report.html 且校验通过；波次表出现 reason=asc-cap 的波（若该报告有小怪波 >1 升腾）。

- [ ] **Step 4: 重导红玉**

Run: `node tools/wclplan/cli.js deploy/wcl-CxtJgwnRbAKja36z-f11/input.json deploy/wcl-CxtJgwnRbAKja36z-f11 --granularity=combat`
Expected: 新 groups/routeKey/命令行。原红玉第1波（pulls 1+2+3、2 次升腾、纯小怪）应被拆成两波各 ≤1 升腾。

Run: `node tools/wclplan/report.js deploy/wcl-CxtJgwnRbAKja36z-f11/input.json deploy/wcl-CxtJgwnRbAKja36z-f11`
Expected: 校验通过。

- [ ] **Step 5: 交叉核验两份产物一致性**

对每份产物运行（替换 `<dir>` 与新 routeKey）：

```bash
node - <<'NODE'
const assert=require('assert/strict'),fs=require('fs');
const {decodeMdtString}=require('./tools/wclplan/mdtstring.js');
const {computeRouteKey}=require('./tools/wclplan/plan.js');
const d=process.argv[1];
const s=require(d+'/summary.json');
const route=decodeMdtString(fs.readFileSync(d+'/route.mdt.txt','utf8').trim());
assert.equal(route.value.pulls.length,s.groups.length);
assert.equal(computeRouteKey(route.value.pulls),s.routeKey);
assert.equal(fs.readFileSync(d+'/importplan-pack.txt','utf8').trim(),s.packLine);
assert.equal(fs.readFileSync(d+'/importratiopack.txt','utf8').trim(),s.ratioPackLine);
const boss=new Set((require(d+'/input.json').bossEncounters||[]).map(b=>b.pull));
s.waveUsage.forEach((u,i)=>{const pulls=s.groups[i];const hasBoss=pulls.some(p=>boss.has(p));const cap=hasBoss?2:1;
  const atomic=pulls.length===1&&s.warnings.some(w=>w.includes('pull '+pulls[0]));
  assert.ok(u.asc<=cap||atomic,`wave ${i+1} asc ${u.asc} > cap ${cap}`);});
console.log(d,'OK routeKey',s.routeKey,'waves',s.groups.length);
NODE
```

Run（两份各一次）：
`node <上述脚本> deploy/wcl-Mcdmtnwx4h6CYHNT-f11`
`node <上述脚本> deploy/wcl-CxtJgwnRbAKja36z-f11`
Expected: 各打印 `OK routeKey <新key> waves <N>`，无断言失败。

> 注：Step 5 的 heredoc 需把 `process.argv[1]` 改为脚本参数传入目录；执行时用 `node -  deploy/... <<'NODE'` 或落地为临时脚本文件运行，二选一，确保目录参数正确传入。

- [ ] **Step 6: 交付新导入串给用户**

把两份的新 `route.mdt.txt`、`importplan-pack.txt`、`importratiopack.txt` 内容与新 routeKey 汇总给用户，并说明：游戏内需先在 MDT 里导入**新**路线串（会成为当前选中预设），再依次跑新的 `/npt importplanpack <新key> ...` 与 `/npt importratiopack <新key> ...`，最后 `/npt start last`。

- [ ] **Step 7: 提交（产物 + 计划勾选）**

```bash
git add deploy/wcl-Mcdmtnwx4h6CYHNT-f11 deploy/wcl-CxtJgwnRbAKja36z-f11 docs/superpowers/plans/2026-10-02-asc-cap-wave-splitting.md docs/superpowers/specs/2026-10-02-asc-cap-wave-splitting-design.md
git commit -m "feat: re-export Murder Row and Ruby Life Pools with asc-cap wave splitting"
```

---

## Self-Review

**1. Spec coverage:**
- 「含 boss 波上限 2 / 纯小怪上限 1」→ Task 3 `splitWaveByAscCap` + `ASC_CAP`。
- 「超上限按 pull 边界贪心再拆」→ Task 3 贪心 + Task 4 接入。
- 「单 pull 超限保留并告警」→ Task 3 `openWith` 告警 + Task 4 反转用例断言 warning。
- 「升腾按 pull 归属（Voronoi，与 castWaves 自洽）」→ Task 2 `ascCountPerPull` + Task 4 Step 5 自洽断言。
- 「reason=asc-cap 标注」→ Task 1 Step 2 reason 守卫 + Task 4 sub.reason。
- 「拆分后重算 cast 窗口」→ Task 4 Step 3 二次 `computeWaveWindows`。
- 「反转既有 boss 3–4 升腾合并用例」→ Task 4 Step 1。
- 「fixture/cli 回归护栏」→ Task 4 Step 4（fixture 恰 2 升腾不拆，断言不变）。
- 「report 文案」→ Task 5。
- 「重导两份 + routeKey 变 + 重新导入指引」→ Task 6。
- 「>5 硬上限关系」「YAGNI 项」→ 设计文档已述，代码不改 cli 的 >5 检查（升腾经此规则 ≤2，不再触发）。

**2. Placeholder scan:** 无 TBD/TODO；每个改码步骤附完整代码；每个测试步骤附完整测试代码与预期。Task 6 Step 5 的 heredoc 传参已加注说明避免 `process.argv` 误用。

**3. Type consistency:** `ASC_CAP={boss,trash}`、`bossPullNumbers(bossEncounters)->Set<number>`、`ascCountPerPull(casts,waves,timings,pullCount)->Map<number,number>`、`splitWaveByAscCap(pulls,ascPerPull,bossPulls,warnings)->{groups,warnings}`、`computeWaveWindows(waves,{timings,segments,bossEnds})` 在各 Task 间签名一致；导出名在 Task 2/3 分步补齐，Task 3 为完整导出。

**已知风险与处置:**
- 若 Task 4 Step 1 第二个用例（纯小怪拆分）的实际分组与断言不符：以「每波升腾≤上限 + 拆分点 reason=asc-cap」为准调整断言的具体分组数字，但不得放宽上限或改 `splitWaveByAscCap` 语义去凑断言。
- 若 Task 4 Step 4 的 `cli.test.js` 变红：说明再拆分误伤未超限波，修逻辑而非改断言（fixture boss 波恰 2 升腾，不应触发拆分）。
