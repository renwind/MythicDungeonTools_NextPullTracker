"use strict";

const SKILLS = new Set(["asc", "lust", "pot"]);
const validTime = value => Number.isFinite(value) && value >= 0;

function validateCasts(casts, pullCount) {
  if (!Array.isArray(casts)) throw new Error("waves: castEvents must be an array");
  for (const cast of casts) {
    if (!cast || !Number.isFinite(cast.t) || !SKILLS.has(cast.skill)) {
      throw new Error("waves: invalid cast time or skill");
    }
    if (cast.pull !== undefined && (!Number.isInteger(cast.pull) || cast.pull < 1 || cast.pull > pullCount)) {
      throw new Error("waves: cast pull is outside the route");
    }
  }
}

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

// 贪心把一波的 pulls 拆成若干子波，使每个子波升腾 <= 其上限（含 boss pull 用 2，否则 1）。
// 单个 pull 自身升腾即超上限时无法再拆，单独成波并向 warnings 追加一条告警。
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

// 纯小怪波（cap 1）升腾超上限时的锚点拆分：切点取段内最高血 pull，升腾按时刻中点子窗均分。
// ascTimes 由调用方用 castWaves 归属到本波（每次升腾只归一波，避免段边界处的升腾被重复计数）。
// 返回子波数组（带 _ascWindow，供 buildCombatWaveDetail 在 computeWaveWindows 后覆写 castStart/castEnd）。
function splitTrashWaveByAnchor(wave, ascTimes, pullMaxHealth, warnings) {
  const cap = ASC_CAP.trash;
  const ws = wave.castStart, we = wave.castEnd;
  const A = ascTimes.length;
  if (A <= cap || ws === null || we === null) return [wave];
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

function buildCombatWaveDetail(args) {
  const { pullCount, pullMaxHealth } = args;
  if (!Number.isInteger(pullCount) || pullCount < 1) throw new Error("waves: pullCount must be positive");
  const timings = args.pullTimings ?? Array(pullCount).fill(null);
  if (!Array.isArray(timings) || timings.length !== pullCount) {
    throw new Error("waves: pullTimings must have one entry per route pull");
  }
  let previousStart = -Infinity;
  for (const timing of timings) {
    if (timing === null) continue;
    if (!timing || !validTime(timing.start) || !validTime(timing.end) || timing.end < timing.start || timing.start < previousStart) {
      throw new Error("waves: pullTimings must contain ordered finite start/end times");
    }
    previousStart = timing.start;
  }

  const segments = args.combatSegments ?? [];
  const bosses = args.bossEncounters ?? [];
  const casts = args.castEvents ?? [];
  validateCasts(casts, pullCount);
  for (const [name, intervals] of [["combatSegments", segments], ["bossEncounters", bosses]]) {
    if (!Array.isArray(intervals)) throw new Error("waves: " + name + " must be an array");
    let previousEnd = -Infinity;
    for (const interval of intervals) {
      if (!interval || !validTime(interval.start) || !validTime(interval.end) || interval.end <= interval.start || interval.start < previousEnd) {
        throw new Error("waves: " + name + " must be ordered non-overlapping intervals");
      }
      previousEnd = interval.end;
    }
  }
  const segmentAt = t => segments.findIndex(s => t >= s.start && t < s.end);
  const segmentOf = timings.map(t => t === null ? -1 : segmentAt(t.start));
  timings.forEach((timing, i) => {
    if (segmentOf[i] !== -1 && timing.end > segments[segmentOf[i]].end) {
      throw new Error("waves: pullTimings cross a confirmed combat boundary");
    }
  });
  const cuts = new Set([0]);
  for (let i = 1; i < pullCount; i++) {
    if (segmentOf[i] === -1 || segmentOf[i] !== segmentOf[i - 1]) cuts.add(i);
  }

  const hardCuts = new Set(cuts);
  const bossEnds = new Map();
  const bossCuts = new Map();
  const warnings = [];
  if (segmentOf.includes(-1)) warnings.push("Unconfirmed combat continuity: original pull boundaries retained.");
  for (const [bi, boss] of bosses.entries()) {
    const firstPull = boss.firstPull ?? boss.pull;
    if (!Number.isInteger(boss.pull) || boss.pull < 1 || boss.pull > pullCount) {
      throw new Error("waves: bossEncounters pull is outside the route");
    }
    if (!Number.isInteger(firstPull) || firstPull < 1 || firstPull > boss.pull) {
      throw new Error("waves: boss firstPull must precede or equal its boss pull");
    }
    if (bi > 0 && firstPull <= bosses[bi - 1].pull) {
      throw new Error("waves: bossEncounters pull order overlaps a previous boss");
    }
    const si = segmentAt(boss.start);
    const first = firstPull - 1;
    const bossIndex = boss.pull - 1;
    if (si === -1 || segmentOf[bossIndex] === -1 || timings[first] === null) {
      warnings.push("Boss pull " + boss.pull + " lacks confirmed combat continuity; original boundaries retained.");
      continue;
    }
    const involvedSegments = segmentOf.slice(first, bossIndex + 1);
    if (boss.end > segments[si].end || involvedSegments.some(id => id !== -1 && id !== si)) {
      throw new Error("waves: boss firstPull crosses a confirmed combat boundary");
    }
    if (involvedSegments.includes(-1)) {
      warnings.push("Boss pull " + boss.pull + " has incomplete pull timing evidence; original boundaries retained.");
      continue;
    }
    if (timings[bossIndex].start >= boss.end || (first < bossIndex && timings[first].start > boss.start)) {
      throw new Error("waves: bossEncounters do not match pullTimings");
    }

    const previousBossEnd = bosses.slice(0, bi).reduce((end, other) => Math.max(end, other.end), segments[si].start);
    const preBoss = casts.some(c => c.skill === "asc" && c.t >= previousBossEnd && c.t < boss.start);
    const bossCasts = casts.filter(c => c.skill === "asc" && c.t >= boss.start && c.t < boss.end);
    const phaseFirst = Math.max(...[...hardCuts].filter(i => i <= bossIndex));
    // Moving a hard boundary to boss.start would send pre-boss casts into a finished phase.
    const split = first === phaseFirst ? bossIndex : first;
    if (preBoss && bossCasts.length && split > phaseFirst) {
      cuts.add(split);
      bossCuts.set(split, { bossStart: boss.start, firstBossAscendance: Math.min(...bossCasts.map(c => c.t)) });
    }
    // Boss deaths are an explicit phase boundary, unlike an absence of trash deaths.
    const afterBoss = timings.findIndex((t, i) => i > bossIndex && segmentOf[i] === si && t.start >= boss.end);
    if (afterBoss !== -1) {
      cuts.add(afterBoss);
      hardCuts.add(afterBoss);
    }
    bossEnds.set(bossIndex + 1, boss.end);
  }

  const waves = [];
  for (let i = 0; i < pullCount; i++) {
    if (cuts.has(i)) waves.push({ pulls: [], segment: segmentOf[i], reason: "original", ...bossCuts.get(i) });
    waves.at(-1).pulls.push(i + 1);
  }
  computeWaveWindows(waves, { timings, segments, bossEnds });

  // 拆分：boss 波走现有 Voronoi+贪心（时刻互异、升腾集中于 boss）；小怪波走 HP 锚点均分。
  const bossPulls = bossPullNumbers(bosses);
  const ascPerPull = ascCountPerPull(casts, waves, timings, pullCount);
  const initialAssign = castWaves(casts, { waves, pullCount });
  const splitWaves = [];
  for (let wi = 0; wi < waves.length; wi++) {
    const wave = waves[wi];
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
    const ascTimes = casts.filter((c, i) => c.skill === "asc" && initialAssign[i] === wi).map(c => c.t);
    for (const sub of splitTrashWaveByAnchor(wave, ascTimes, pullMaxHealth, warnings)) splitWaves.push(sub);
  }
  computeWaveWindows(splitWaves, { timings, segments, bossEnds });
  // 锚点子波用升腾中点子窗覆写 castStart/castEnd（computeWaveWindows 的段级窗口会让子波共享同一窗）。
  for (const w of splitWaves) {
    if (w._ascWindow) { w.castStart = w._ascWindow.castStart; w.castEnd = w._ascWindow.castEnd; delete w._ascWindow; }
  }
  return { waves: splitWaves, pullCount, warnings };
}

function buildCombatWaves(args) {
  return buildCombatWaveDetail(args).waves.map(w => w.pulls);
}

function castWaves(castEvents, detail) {
  validateCasts(castEvents, detail.pullCount);
  return castEvents.map(cast => {
    for (let i = detail.waves.length - 1; i >= 0; i--) {
      const wave = detail.waves[i];
      if (wave.castStart !== null && wave.castEnd !== null && cast.t >= wave.castStart && cast.t <= wave.castEnd) return i;
    }
    if (cast.pull !== undefined) return detail.waves.findIndex(w => w.pulls.includes(cast.pull));
    return -1;
  });
}

module.exports = { buildCombatWaves, buildCombatWaveDetail, castWaves, bossPullNumbers, ascCountPerPull, splitWaveByAscCap, anchorCutPoints, cutPullsAt, distributeAscTimes, splitTrashWaveByAnchor, ASC_CAP };
