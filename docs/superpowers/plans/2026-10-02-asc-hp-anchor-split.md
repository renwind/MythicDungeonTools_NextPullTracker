# 升腾 HP 锚点分波修正 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复连续战斗段内升腾被退化 Voronoi 甩给最后一个 pull 的 bug，改用「段内最高血量敌人所在 pull」作锚点切分、升腾按时刻中点子窗均分，使红玉第 2/5 波含德拉加尔/烈焰之咽。

**Architecture:** 只改**纯小怪波**（cap 1）的拆分：新增 HP 锚点切点 + 升腾时刻中点子窗两个纯函数，接入 `buildCombatWaveDetail` 的拆分循环（按 `hasBoss` 分支）。**boss 波（cap 2）路径完全不变**（其 pull 时刻互异、Voronoi 归属可靠、升腾集中于 boss）。`health` 由 `align.js` 从 MDT 副本 Lua 解析、`cli.js` 汇成每 pull 最高血、传入分波层。

**Tech Stack:** Node.js（`node --test`），CommonJS，纯函数 + 既有 `tools/wclplan/*` 管线。

> **提交约定：** 用户要求「子代理实现不提交」。每个任务以「全套测试绿」收尾，**不执行 `git commit`**；提交由用户在全部完成后统一处理。

> **关键约束（勿违反）：**
> - boss 波（含 `bossEncounters` 里的 pull）走现有 `ascCountPerPull`+`splitWaveByAscCap`，**一行都不要动它的行为**——`waves.test.js:50`、`cli.test.js:148` 依赖它。
> - `loadEnemyMeta` 的 `health` 必须是**可选**捕获组：cli 测试的 `dungeon.lua` 没有 `health` 字段，正则若强制 health 会漏解析敌人、连累 forces/npcId。
> - 缺 `pullMaxHealth`（老 fixture）时锚点回退为「pull 号小者优先」，保证既有小怪用例 `waves.test.js:59` 结果不变。

---

## File Structure

- `tools/wclplan/align.js` — `loadEnemyMeta` 增加 `health` 字段（可选解析）。
- `tools/wclplan/waves.js` — 新增纯函数 `anchorCutPoints`/`cutPullsAt`/`distributeAscTimes`/`splitTrashWaveByAnchor`；`buildCombatWaveDetail` 接受 `pullMaxHealth` 并按 `hasBoss` 分支；导出新函数。
- `tools/wclplan/cli.js` — 计算 `pullMaxHealth` 并传入 `buildCombatWaveDetail`；`loadEnemyMeta` 调用点前移。
- `tools/wclplan/align.test.js` / `waves.test.js` — 新增/更新测试。
- `deploy/wcl-CxtJgwnRbAKja36z-f11/`、`deploy/wcl-Mcdmtnwx4h6CYHNT-f11/` — 重导产物（Task 6）。

---

## Task 1: `loadEnemyMeta` 解析 health（可选）

**Files:**
- Modify: `tools/wclplan/align.js:19-38`（`loadEnemyMeta`）
- Test: `tools/wclplan/align.test.js`

- [ ] **Step 1: 写失败测试**

在 `tools/wclplan/align.test.js` 末尾追加（若文件未 require `loadEnemyMeta`，在顶部 require 处补上）：

```js
test("loadEnemyMeta 解析 health，缺失时默认 0", () => {
  const lua = 'MDT.dungeonEnemies[1] = {\n' +
    '  [1] = {\n    ["name"] = "Elite",\n    ["id"] = 187897,\n    ["count"] = 30,\n    ["health"] = 9729765,\n    ["clones"] = {\n      [1] = {},\n    },\n  },\n' +
    '  [2] = {\n    ["name"] = "Trash",\n    ["id"] = 101,\n    ["count"] = 5,\n    ["clones"] = {\n      [1] = {}, [2] = {},\n    },\n  },\n}\n';
  const meta = loadEnemyMeta(lua);
  assert.equal(meta[1].health, 9729765);
  assert.equal(meta[1].count, 30);
  assert.equal(meta[2].health, 0);   // 无 health 字段 → 0
  assert.equal(meta[2].clones, 2);
});
```

- [ ] **Step 2: 运行验证失败**

Run: `node --test tools/wclplan/align.test.js`
Expected: FAIL —— `meta[1].health` 为 `undefined`（当前未解析 health）。

- [ ] **Step 3: 实现**

把 `align.js:23` 的正则与 `align.js:29` 的赋值改为：

```js
  const re = /\["id"\]\s*=\s*(\d+),\s*\["count"\]\s*=\s*(\d+)(?:,\s*\["health"\]\s*=\s*(\d+))?/g;
```
```js
    meta[idx] = { id: Number(m[1]), count: Number(m[2]), clones: 0, health: m[3] ? Number(m[3]) : 0 };
```

（`cloneRe` 那段不动。）

- [ ] **Step 4: 运行验证通过**

Run: `node --test tools/wclplan/align.test.js`
Expected: PASS（新测试 + 既有 align 测试全绿）。

- [ ] **Step 5: 全套绿**

Run: `node --test tools/wclplan/*.test.js`
Expected: PASS（此时 waves/cli 尚未用到 health，应仍全绿）。

---

## Task 2: 纯函数 `anchorCutPoints` + `cutPullsAt`

**Files:**
- Modify: `tools/wclplan/waves.js`（新增两函数 + 导出）
- Test: `tools/wclplan/waves.test.js`

- [ ] **Step 1: 写失败测试**

在 `waves.test.js` 顶部 require 处补 `anchorCutPoints, cutPullsAt`，末尾追加：

```js
test("anchorCutPoints：切点=最高血 pull（排除首 pull），血量相同取 pull 号小者", () => {
  // pulls [1,2,3]，pull2 血最高 → k=2 取 1 个切点 = pull2
  assert.deepEqual(anchorCutPoints([1, 2, 3], [6500000, 9700000, 3600000], 2), [2]);
  // pull1 最高但被排除 → 退到次高的 pull2
  assert.deepEqual(anchorCutPoints([1, 2, 3], [9700000, 5000000, 3600000], 2), [2]);
  // pull2/pull3 同血 → 取号小的 pull2
  assert.deepEqual(anchorCutPoints([1, 2, 3], [1000000, 5000000, 5000000], 2), [2]);
  // k=3 取 2 个切点，按血量降序 = pull2, pull3（升序返回）
  assert.deepEqual(anchorCutPoints([1, 2, 3, 4], [1, 9000000, 3000000, 7000000], 3), [2, 4]);
  // 缺 pullMaxHealth → 全 0，tie 取号小者：candidates[2,3,4] → [2,3]
  assert.deepEqual(anchorCutPoints([1, 2, 3, 4], undefined, 3), [2, 3]);
});

test("cutPullsAt：按升序切点分组，切点等于组首时不产生空组", () => {
  assert.deepEqual(cutPullsAt([1, 2, 3], [2]), [[1], [2, 3]]);
  assert.deepEqual(cutPullsAt([1, 2, 3, 4], [2, 4]), [[1], [2, 3], [4]]);
  assert.deepEqual(cutPullsAt([1, 2, 3], []), [[1, 2, 3]]);
});
```

- [ ] **Step 2: 运行验证失败**

Run: `node --test tools/wclplan/waves.test.js`
Expected: FAIL —— `anchorCutPoints is not a function` / `cutPullsAt is not a function`。

- [ ] **Step 3: 实现**

在 `waves.js` 的 `splitWaveByAscCap` 之后新增：

```js
// 段内最高血量敌人所在 pull 作锚点：在 pulls[1..]（排除首 pull，首 pull 前无处可切）
// 按 pullMaxHealth 降序取前 k-1 个作切点，血量相同则 pull 号小者优先，升序返回。
// pullMaxHealth 缺失或某项为空按 0 处理（回退为 pull 顺序）。
function anchorCutPoints(pulls, pullMaxHealth, k) {
  const hp = pullMaxHealth || [];
  const candidates = pulls.slice(1);
  const ranked = candidates.slice().sort((a, b) => {
    const d = (hp[b - 1] || 0) - (hp[a - 1] || 0);
    return d !== 0 ? d : a - b;
  });
  return ranked.slice(0, Math.max(0, k - 1)).sort((a, b) => a - b);
}

// 按升序切点把 pulls 切成连续组；切点落在组首（idx===start）时跳过，避免空组。
function cutPullsAt(pulls, cutPoints) {
  const groups = [];
  let start = 0;
  for (const c of cutPoints) {
    const idx = pulls.indexOf(c);
    if (idx > start) { groups.push(pulls.slice(start, idx)); start = idx; }
  }
  groups.push(pulls.slice(start));
  return groups;
}
```

并把 `module.exports`（`waves.js:241`）改为追加两函数：

```js
module.exports = { buildCombatWaves, buildCombatWaveDetail, castWaves, bossPullNumbers, ascCountPerPull, splitWaveByAscCap, anchorCutPoints, cutPullsAt, ASC_CAP };
```

- [ ] **Step 4: 运行验证通过**

Run: `node --test tools/wclplan/waves.test.js`
Expected: PASS（两条新测试绿；既有 waves 测试不受影响）。

---

## Task 3: 纯函数 `distributeAscTimes`

**Files:**
- Modify: `tools/wclplan/waves.js`（新增 + 导出）
- Test: `tools/wclplan/waves.test.js`

- [ ] **Step 1: 写失败测试**

在 `waves.test.js` require 处补 `distributeAscTimes`，末尾追加：

```js
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
```

- [ ] **Step 2: 运行验证失败**

Run: `node --test tools/wclplan/waves.test.js`
Expected: FAIL —— `distributeAscTimes is not a function`。

- [ ] **Step 3: 实现**

在 `cutPullsAt` 之后新增：

```js
// 把升腾时刻贪心每组填满至 cap，分成 k 组；返回 k 个 {castStart,castEnd}，
// 相邻组边界取「前组末升腾」与「后组首升腾」的中点，使窗口式 castWaves 自然均分。
// 前置条件：ascTimes.length <= k*cap 且 k>=1（调用方保证）。
function distributeAscTimes(ascTimes, k, cap, winStart, winEnd) {
  const t = ascTimes.slice().sort((a, b) => a - b);
  const cuts = [];
  for (let j = 1; j < k; j++) cuts.push((t[j * cap - 1] + t[j * cap]) / 2);
  const windows = [];
  for (let j = 0; j < k; j++) {
    windows.push({ castStart: j === 0 ? winStart : cuts[j - 1], castEnd: j === k - 1 ? winEnd : cuts[j] });
  }
  return windows;
}
```

`module.exports` 追加 `distributeAscTimes`。

- [ ] **Step 4: 运行验证通过**

Run: `node --test tools/wclplan/waves.test.js`
Expected: PASS。

---

## Task 4: `splitTrashWaveByAnchor` + 接入 `buildCombatWaveDetail`（hasBoss 分支）

**Files:**
- Modify: `tools/wclplan/waves.js:101-223`（`buildCombatWaveDetail`）、新增 `splitTrashWaveByAnchor`、导出
- Test: `tools/wclplan/waves.test.js`

- [ ] **Step 1: 写失败测试（锚点真路径 + 回退 + 反转 line 111）**

在 `waves.test.js` 末尾追加：

```js
test("小怪段内 pull 起始时刻相同时按最高血 pull 锚点拆分并均分升腾", () => {
  const data = {
    pullCount: 3,
    pullTimings: [{ start: 10, end: 200 }, { start: 10, end: 200 }, { start: 10, end: 200 }],
    combatSegments: [{ start: 10, end: 200 }],
    castEvents: [{ skill: "asc", t: 30 }, { skill: "asc", t: 150 }],
    pullMaxHealth: [6500000, 9700000, 3600000], // pull2 = 大精英
  };
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2, 3]]);
  assert.deepEqual(sumUsagePerWave(2, data.castEvents, castWaves(data.castEvents, detail)).map(u => u.asc), [1, 1]);
  assert.deepEqual(detail.warnings, []);
  assert.equal(detail.waves[1].reason, "asc-cap");
});

test("锚点是首 pull 时切点退到次高血 pull", () => {
  const data = {
    pullCount: 3,
    pullTimings: [{ start: 10, end: 200 }, { start: 10, end: 200 }, { start: 10, end: 200 }],
    combatSegments: [{ start: 10, end: 200 }],
    castEvents: [{ skill: "asc", t: 30 }, { skill: "asc", t: 150 }],
    pullMaxHealth: [9700000, 5000000, 3600000],
  };
  assert.deepEqual(groups(buildCombatWaveDetail(data)), [[1], [2, 3]]);
});

test("缺 pullMaxHealth 时锚点回退为 pull 号小者优先", () => {
  const data = {
    pullCount: 3,
    pullTimings: [{ start: 10, end: 200 }, { start: 10, end: 200 }, { start: 10, end: 200 }],
    combatSegments: [{ start: 10, end: 200 }],
    castEvents: [{ skill: "asc", t: 30 }, { skill: "asc", t: 150 }],
  };
  assert.deepEqual(groups(buildCombatWaveDetail(data)), [[1], [2, 3]]);
});

test("单 pull 小怪波升腾超上限无法拆，保留并告警", () => {
  const data = {
    pullCount: 1,
    pullTimings: [{ start: 10, end: 200 }],
    combatSegments: [{ start: 10, end: 200 }],
    castEvents: [{ skill: "asc", t: 30 }, { skill: "asc", t: 150 }],
    pullMaxHealth: [9700000],
  };
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1]]);
  assert.ok(detail.warnings.some(w => /pull 1/i.test(w) && /ascendance/i.test(w)));
});
```

并**修改** `waves.test.js:111-118` 那条（旧期望是 Voronoi 退化产物）。整条替换为：

```js
test("缺少Boss进战证据时不按boss拆分，但小怪升腾上限1仍拆（reason=asc-cap，均分无告警）", () => {
  const data = input();
  data.bossEncounters = [];
  const detail = buildCombatWaveDetail(data);
  assert.deepEqual(groups(detail), [[1], [2], [3], [4], [5, 6]]);
  assert.equal(detail.waves[2].reason, "asc-cap");
  assert.deepEqual(detail.warnings.filter(w => /ascendance/i.test(w)), []);
});
```

- [ ] **Step 2: 运行验证失败**

Run: `node --test tools/wclplan/waves.test.js`
Expected: FAIL —— 新锚点用例得到旧 Voronoi 结果（如 `[[1],[2,3]]` 变成 `[[1,2],[3]]` 或含告警）；line 111 得到旧 `[[1],[2],[3,4,5],[6]]`。

- [ ] **Step 3: 实现 `splitTrashWaveByAnchor`**

在 `waves.js` 的 `cutPullsAt`/`distributeAscTimes` 之后、`buildCombatWaveDetail` 之前新增：

```js
// 纯小怪波（cap 1）升腾超上限时的锚点拆分：切点取段内最高血 pull，升腾按时刻中点子窗均分。
// 返回子波数组（带 _ascWindow，供 buildCombatWaveDetail 在 computeWaveWindows 后覆写 castStart/castEnd）。
function splitTrashWaveByAnchor(wave, casts, pullMaxHealth, warnings) {
  const cap = ASC_CAP.trash;
  const ws = wave.castStart, we = wave.castEnd;
  const ascTimes = (ws === null || we === null) ? []
    : casts.filter(c => c.skill === "asc" && c.t >= ws && c.t <= we).map(c => c.t);
  const A = ascTimes.length;
  if (A <= cap) return [wave];
  if (wave.pulls.length < 2) {
    warnings.push("pull " + wave.pulls[0] + " has " + A + " ascendance in a single pull (cap " + cap + "); cannot split further, kept as one wave");
    return [wave];
  }
  const k = Math.ceil(A / cap);
  let groups = cutPullsAt(wave.pulls, anchorCutPoints(wave.pulls, pullMaxHealth, k));
  if (groups.length < k) {
    groups = wave.pulls.map(p => [p]);
    if (A > cap * groups.length) {
      warnings.push("pulls " + wave.pulls.join("+") + " have " + A + " ascendance across " + groups.length + " pulls (cap " + cap + " each); cannot split to cap, kept atomic per pull");
    }
  }
  const windows = distributeAscTimes(ascTimes, groups.length, cap, ws, we);
  return groups.map((pulls, j) => ({ pulls, segment: wave.segment, reason: "asc-cap", _ascWindow: windows[j] }));
}
```

- [ ] **Step 4: 接入 `buildCombatWaveDetail`**

`buildCombatWaveDetail` 的签名体（`waves.js:101`）解构处补 `pullMaxHealth`：把 `const { pullCount } = args;` 改为 `const { pullCount, pullMaxHealth } = args;`。

把 `waves.js:202-222`（第一个 `computeWaveWindows(waves,...)` 之后到 `return` 之前）整段替换为：

```js
  computeWaveWindows(waves, { timings, segments, bossEnds });

  // 拆分：boss 波走现有 Voronoi+贪心（时刻互异、升腾集中于 boss）；小怪波走 HP 锚点均分。
  const bossPulls = bossPullNumbers(bosses);
  const ascPerPull = ascCountPerPull(casts, waves, timings, pullCount);
  const splitWaves = [];
  for (const wave of waves) {
    if (wave.pulls.some(p => bossPulls.has(p))) {
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
      continue;
    }
    for (const sub of splitTrashWaveByAnchor(wave, casts, pullMaxHealth, warnings)) splitWaves.push(sub);
  }
  computeWaveWindows(splitWaves, { timings, segments, bossEnds });
  // 锚点子波用升腾中点子窗覆写 castStart/castEnd（computeWaveWindows 的段级窗口会让子波共享同一窗）。
  for (const w of splitWaves) {
    if (w._ascWindow) { w.castStart = w._ascWindow.castStart; w.castEnd = w._ascWindow.castEnd; delete w._ascWindow; }
  }
  return { waves: splitWaves, pullCount, warnings };
```

`module.exports` 追加 `splitTrashWaveByAnchor`。

- [ ] **Step 5: 运行验证通过**

Run: `node --test tools/wclplan/waves.test.js`
Expected: PASS —— 4 条新锚点用例绿；line 111 新期望绿；**boss 用例（line 50/84/99 等）与 line 59 仍绿**。

- [ ] **Step 6: 全套绿**

Run: `node --test tools/wclplan/*.test.js`
Expected: PASS（cli 尚未传 pullMaxHealth，其 trash 波不超 cap，故 cli 测试仍绿）。

---

## Task 5: `cli.js` 计算并传入 `pullMaxHealth`

**Files:**
- Modify: `tools/wclplan/cli.js:53-71`、`tools/wclplan/cli.js:112`
- Test: `tools/wclplan/cli.test.js`

- [ ] **Step 1: 写失败测试（小怪锚点端到端）**

在 `cli.test.js` 末尾追加。用带 `health` 的 dungeon.lua + 段内同起始时刻，验证大精英 pull 进入含升腾的波：

```js
test("端到端：小怪段最高血 pull 作锚点，升腾均分到大精英所在波", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "wclplan-anchor-"));
  try {
    const dungeon = path.join(dir, "d.lua");
    fs.writeFileSync(dungeon,
      'MDT.dungeonEnemies[1] = {\n' +
      '  [1] = { ["name"]="Trash", ["id"]=101, ["count"]=5, ["health"]=1000000, ["clones"]={ [1]={}, } },\n' +
      '  [2] = { ["name"]="Elite", ["id"]=202, ["count"]=30, ["health"]=9700000, ["clones"]={ [1]={}, } },\n' +
      '}\n');
    const original = { text: "Anchor", uid: "anchor-1", value: { currentDungeonIdx: 1, currentPull: 1,
      pulls: [ { 1: [1], color: "#123456" }, { 2: [1], color: "#123456" }, { 1: [2], color: "#123456" } ] } };
    const input = {
      meta: { dungeon: "Anchor Test", key: 22 },
      mdtDungeonFile: dungeon,
      routeString: encodeMdtString(original),
      pullTimings: [{ start: 10, end: 200 }, { start: 10, end: 200 }, { start: 10, end: 200 }],
      combatSegments: [{ start: 10, end: 200 }],
      bossEncounters: [],
      castEvents: [{ skill: "asc", t: 30 }, { skill: "asc", t: 150 }],
      rotationCastEvents: [],
      deathEvents: [],
    };
    const inputPath = path.join(dir, "in.json");
    fs.writeFileSync(inputPath, JSON.stringify(input));
    const outDir = path.join(dir, "out");
    const res = spawnSync(process.execPath, [CLI, inputPath, outDir], { encoding: "utf8" });
    assert.equal(res.status, 0, res.stderr);
    const summary = JSON.parse(fs.readFileSync(path.join(outDir, "summary.json"), "utf8"));
    assert.deepEqual(summary.groups, [[1], [2, 3]]); // 锚点=pull2(Elite 9.7M)
    assert.deepEqual(summary.waveUsage.map(u => u.asc), [1, 1]);
    assert.deepEqual(summary.warnings, []);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
```

- [ ] **Step 2: 运行验证失败**

Run: `node --test tools/wclplan/cli.test.js`
Expected: FAIL —— 未传 `pullMaxHealth`，退化为回退切点，`groups` 可能为 `[[1],[2,3]]` 巧合通过或不通过；关键断言 `waveUsage.map(asc)===[1,1]` 在未接入子窗前会失败（升腾堆到最后一波）。

> 注：本用例的锚点恰为 pull2，回退（号小优先）也切 pull2，故 `groups` 可能已对；但**子窗均分**依赖 Task 4 的 `_ascWindow`，且 `pullMaxHealth` 未传时 `waves.js` 收到 `undefined`——本步先确认测试对 `waveUsage` 的断言能反映接入前后的差异。若 Step 2 意外全绿，说明该用例未覆盖到「非回退」路径，改用 `pullMaxHealth=[1000000,3600000,9700000]`（锚点 pull3）令回退与锚点结果不同后再验失败。

- [ ] **Step 3: 实现**

`cli.js:53` 之后、`buildCombatWaveDetail` 调用之前插入 `enemyMeta`/`pullMaxHealth` 计算，并把 `loadEnemyMeta` 从 `cli.js:112` 前移（删除 112 行那次重复调用，复用同一 `enemyMeta`）：

```js
  const luaText = fs.readFileSync(input.mdtDungeonFile, "utf8");
  const enemyMeta = loadEnemyMeta(luaText);
  const preset = decodeMdtString(input.routeString);
  const pulls = preset.value && preset.value.pulls;
  if (!Array.isArray(pulls) || !pulls.length) throw new Error("cli: route must contain pulls");
  // ...（保留原有 pull/clone 校验循环不变）...
  const pullMaxHealth = pulls.map(pull => {
    let mx = 0;
    for (const [idx, clones] of Object.entries(pull)) {
      if (!/^\d+$/.test(idx)) continue;
      if (Array.isArray(clones) && clones.length > 0) mx = Math.max(mx, (enemyMeta[idx] && enemyMeta[idx].health) || 0);
    }
    return mx;
  });
  const casts = input.castEvents ?? [];
  const detail = buildCombatWaveDetail({
    pullCount: pulls.length,
    pullTimings: input.pullTimings,
    combatSegments: input.combatSegments,
    bossEncounters: input.bossEncounters,
    castEvents: casts,
    pullMaxHealth,
  });
```

并把原 `cli.js:112` 的 `const enemyMeta = loadEnemyMeta(luaText);` 删除（后续 `extraEnemies` 校验继续用前移后的 `enemyMeta`）。

- [ ] **Step 4: 运行验证通过**

Run: `node --test tools/wclplan/cli.test.js`
Expected: PASS（新端到端用例 + 既有全部 cli 用例，含 line 148 boss 用例 `[[1],[2],[3,4],[5],[6]]`、line 48 默认 `[[1],[2],[3,4],[5,6]]`）。

- [ ] **Step 5: 全套绿**

Run: `node --test tools/wclplan/*.test.js`
Expected: PASS。

---

## Task 6: 重导两份产物并核验

**Files:**
- 产物目录：`deploy/wcl-CxtJgwnRbAKja36z-f11/`、`deploy/wcl-Mcdmtnwx4h6CYHNT-f11/`
- 参考：`docs/superpowers/specs/2026-10-02-asc-hp-anchor-split-design.md` §7

- [ ] **Step 1: 重导红玉**

Run:
```bash
node tools/wclplan/cli.js deploy/wcl-CxtJgwnRbAKja36z-f11/input.json deploy/wcl-CxtJgwnRbAKja36z-f11
```
Expected: `groups: [[1],[2,3],[4],[5],[6,7],[8,9],[10,11],[12,13],[14],[15]]`；**无 ascendance 告警**（德拉加尔→wave2、烈焰之咽→wave5、Ryvati→wave9）。

- [ ] **Step 2: 重导密谋**

Run:
```bash
node tools/wclplan/cli.js deploy/wcl-Mcdmtnwx4h6CYHNT-f11/input.json deploy/wcl-Mcdmtnwx4h6CYHNT-f11
```
Expected: 段 [11,12,13] 变为 `[11] | [12,13]`（大怪包含升腾），pull13 原子告警消失。逐波打印核对，其余波次与 §7 描述一致；若有出入以实际数据为准并在交付说明。

- [ ] **Step 3: 生成报告并自校验**

Run（若 report 由 cli 之外的入口生成，按仓库既有方式；否则跳过，用 Step 4 脚本核验）：
```bash
node --test tools/wclplan/report.test.js
```
Expected: PASS。

- [ ] **Step 4: 交叉核验两份产物**

Run:
```bash
node -e '
const fs=require("fs");const {decodeMdtString}=require("./tools/wclplan/mdtstring.js");const {computeRouteKey}=require("./tools/wclplan/plan.js");
for(const dir of ["deploy/wcl-CxtJgwnRbAKja36z-f11","deploy/wcl-Mcdmtnwx4h6CYHNT-f11"]){
 const s=JSON.parse(fs.readFileSync(dir+"/summary.json","utf8"));
 const pulls=decodeMdtString(fs.readFileSync(dir+"/route.mdt.txt","utf8").trim()).value.pulls;
 const ok=pulls.length===s.groups.length&&computeRouteKey(pulls)===s.routeKey;
 const ascWarn=s.warnings.filter(w=>/ascendance/i.test(w)).length;
 console.log(dir.split("/")[1],"routeKey="+s.routeKey,"waves="+s.groups.length,"decode/keyOK="+ok,"ascWarnings="+ascWarn);
 s.waves.forEach((w,i)=>{const cap=w.pulls.length? (s.waveUsage[i].asc) :0;});
 console.log("  asc per wave:",s.waveUsage.map(u=>u.asc).join(","));
}'
```
Expected: 两份 `decode/keyOK=true`；红玉 `ascWarnings=0`、`asc per wave` 每个小怪波 ≤1、boss 波 ≤2；密谋 `ascWarnings=0`。

- [ ] **Step 5: 交付说明（不提交）**

向用户汇报：两份新 routeKey、新 MDT 路线串、新 `importplanpack`/`importratiopack`、逐波表；强调 **routeKey 变了必须先重导新路线串再跑导入命令**；列出本次改动文件（align.js/waves.js/cli.js + 两个 .test.js + 本 spec/plan）与此前未提交 WIP 区分。等待用户提交与游戏内实测。

---

## Self-Review

**Spec coverage：**
- §3 boss=等级92、isBoss 不用 → Task 4 保留 boss 路径不动（bossPullNumbers 仍取 bossEncounters）✓
- §5.1 HP 锚点（排除首 pull、tie 号小、k=A 子波）→ Task 2 `anchorCutPoints` + Task 4 `splitTrashWaveByAnchor` ✓
- §5.1 均分 + §5.2 中点子窗 → Task 3 `distributeAscTimes` + Task 4 `_ascWindow` 覆写 ✓
- §6.1 align health → Task 1 ✓；§6.2 cli pullMaxHealth → Task 5 ✓；§6.3 hasBoss 分支 → Task 4 Step 4 ✓；§6.4 缺 pullMaxHealth 回退 → Task 2/4 测试 ✓
- §7 预期结果 → Task 6 Step 1/2 断言 ✓；§8 测试影响 → Task 1-5 覆盖（line 111 反转在 Task 4，boss 用例保持）✓；§10 重导+routeKey → Task 6 ✓

**Placeholder scan：** 无 TBD/TODO；每个改代码步骤均给出完整代码与确切命令。

**Type consistency：** `anchorCutPoints(pulls, pullMaxHealth, k)`、`cutPullsAt(pulls, cutPoints)`、`distributeAscTimes(ascTimes, k, cap, winStart, winEnd)`、`splitTrashWaveByAnchor(wave, casts, pullMaxHealth, warnings)` 在 Task 2/3/4 定义并在 Task 4 接入处一致调用；`pullMaxHealth` 入参名在 waves.js/cli.js/测试三处一致；`health` 字段名在 align.js/cli.js 一致。
