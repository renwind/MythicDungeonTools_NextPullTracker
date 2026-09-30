// 战斗簇粒度的切波（--granularity combat）。
// 规则（2026-09-30 对 +22 纳洛拉克洞穴报告标定，用户看录像确认过合并结果）：
//  1. 死亡时间间隔 > gapSeconds 切战斗簇（空窗里没死怪 = 脱战）；
//  2. 空窗里若有升腾/嗜血 cast，且该 cast 距下一簇首死 >= midCombatMinSeconds，
//     说明战斗没停（坦克怪活着没人死）→ 两簇合并。接战爆发（距首死 <= engageGrace）不合并；
//  3. 一波内升腾次数 > maxAscPerWave 时在该簇处再切（守卫：簇阈值粘错时的自动纠错）；
//  4. cast 归属：簇内 [start, end+tailSeconds]；否则空窗里归下一簇（接战）；
//     都不沾边时归时间上最近的簇（boss 战收尾的浪费 cast 落在最后一簇）。
//  5. 路线 pull 归簇按「该 pull 的死亡多数落在哪簇」投票，避免个别拉远击杀把
//     整条 pull 拖进相邻簇（+22 报告里 p9 有 1 只死在 15:35 的 p10 簇中）。
// 药水不参与合并判定（战前偷药是合法脱战行为）。
// deathSeconds 必须升序（assignDeathsToPulls 已排序），deathPulls 与之同序，null = 没对上号。
"use strict";

const DEFAULTS = {
  gapSeconds: 30,
  tailSeconds: 5,
  engageGraceSeconds: 120,
  midCombatMinSeconds: 60,
  maxAscPerWave: 2,
};

function clusterDeaths(deathSeconds, gapSeconds) {
  const clusters = [];
  for (const t of deathSeconds) {
    const last = clusters[clusters.length - 1];
    if (!last || t - last.end > gapSeconds) clusters.push({ start: t, end: t, deaths: [t] });
    else { last.end = t; last.deaths.push(t); }
  }
  return clusters;
}

function clusterIndexOf(clusters, t) {
  for (let i = 0; i < clusters.length; i++) {
    if (t >= clusters[i].start && t <= clusters[i].end) return i;
  }
  return -1;
}

function assignCastCluster(clusters, t, opts) {
  for (let i = 0; i < clusters.length; i++) {
    if (t >= clusters[i].start && t <= clusters[i].end + opts.tailSeconds) return i;
  }
  for (let i = 0; i < clusters.length; i++) {
    if (t < clusters[i].start && clusters[i].start - t <= opts.engageGraceSeconds) return i;
  }
  let best = clusters.length - 1;
  let bestDist = Infinity;
  clusters.forEach((c, i) => {
    const dist = t < c.start ? c.start - t : t - c.end;
    if (dist < bestDist) { bestDist = dist; best = i; }
  });
  return best;
}

// pull -> 簇：多数票，平票取靠前的簇（pull 从那儿开始）。
function majorityPullSets(clusters, deathSeconds, deathPulls) {
  const votes = clusters.map(() => ({}));
  deathSeconds.forEach((t, i) => {
    const pull = deathPulls[i];
    if (!pull) return;
    const ci = clusterIndexOf(clusters, t);
    if (ci < 0) return;
    votes[ci][pull] = (votes[ci][pull] || 0) + 1;
  });
  const owner = {};
  votes.forEach((counts, ci) => {
    for (const [pull, n] of Object.entries(counts)) {
      if (!owner[pull] || n > owner[pull].n) owner[pull] = { ci, n };
    }
  });
  const sets = clusters.map(() => new Set());
  for (const [pull, o] of Object.entries(owner)) sets[o.ci].add(Number(pull));
  return sets;
}

function buildCombatWaveDetail(args, optsOverride = {}) {
  const opts = Object.assign({}, DEFAULTS, optsOverride);
  const { deathSeconds, deathPulls } = args;
  const burstCasts = args.burstCasts || [];
  const ascCasts = args.ascCasts || [];
  const clusters = clusterDeaths(deathSeconds, opts.gapSeconds);
  const clusterPulls = majorityPullSets(clusters, deathSeconds, deathPulls);

  const ascOf = clusters.map(() => 0);
  for (const t of ascCasts) ascOf[assignCastCluster(clusters, t, opts)] += 1;

  const merged = [];
  for (let i = 0; i < clusters.length; i++) {
    const last = merged[merged.length - 1];
    let join = false;
    if (last) {
      const prev = clusters[last.clusters[last.clusters.length - 1]];
      const gapCasts = burstCasts.filter((t) => t > prev.end && t < clusters[i].start);
      join = gapCasts.some((t) => clusters[i].start - t >= opts.midCombatMinSeconds);
    }
    if (join) last.clusters.push(i);
    else merged.push({ clusters: [i] });
  }

  const waves = [];
  for (const group of merged) {
    let current = null;
    for (const ci of group.clusters) {
      if (current && current.asc + ascOf[ci] > opts.maxAscPerWave) {
        waves.push(current);
        current = null;
      }
      if (!current) current = { clusters: [], asc: 0 };
      current.clusters.push(ci);
      current.asc += ascOf[ci];
    }
    if (current) waves.push(current);
  }

  for (const w of waves) {
    const pulls = new Set();
    for (const ci of w.clusters) for (const p of clusterPulls[ci]) pulls.add(p);
    w.pulls = Array.from(pulls).sort((a, b) => a - b);
  }
  return { clusters, waves, opts };
}

function buildCombatWaves(args, optsOverride = {}) {
  return buildCombatWaveDetail(args, optsOverride).waves.map((w) => w.pulls);
}

// 每个 cast 事件落在哪一波（-1 不会出现在正常数据里）。
function castWaves(castEvents, detail) {
  return castEvents.map((c) => {
    const ci = assignCastCluster(detail.clusters, c.t, detail.opts);
    return detail.waves.findIndex((w) => w.clusters.includes(ci));
  });
}

module.exports = {
  buildCombatWaves, buildCombatWaveDetail, castWaves,
  clusterDeaths, clusterIndexOf, assignCastCluster, majorityPullSets, DEFAULTS,
};

