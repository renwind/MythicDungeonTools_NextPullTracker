// 嗜血族使用检测：不看谁 cast 了英勇/时光，而是看精疲力尽族 debuff 的 apply 簇。
// 任一职业的嗜血类技能都会给全团上 debuff，簇（clusterWindowMs 内的 apply）= 一次使用。
// 族 ID 为 2026-09-30 报告 C9pFgkRJwMvHB4KY 实测：57723=精疲力尽(嗜血族)、80354=时空位移(时光)；
// 遇到新族 ID（猎人/龙希尔等）用 opts.familyIds 扩展，不要凭记忆加。
// 死人守卫：近期死亡目标身上的 apply 不计入簇的「存活计数」；整簇全死人则丢弃。
"use strict";

const DEFAULT_FAMILY = [57723, 80354];
const DEFAULT_CLUSTER_MS = 2500;
const DEAD_RECENT_MS = 60000;

function detectLustUses(debuffEvents, opts = {}) {
  const family = new Set(opts.familyIds || DEFAULT_FAMILY);
  const clusterMs = opts.clusterWindowMs ?? DEFAULT_CLUSTER_MS;
  const deaths = opts.friendlyDeaths || [];
  const deadRecently = (targetID, ts) =>
    deaths.some((d) => d.target === targetID && d.t <= ts && ts - d.t <= DEAD_RECENT_MS);

  const applies = debuffEvents
    .filter((e) => family.has(e.abilityGameID) && e.type === "applydebuff")
    .sort((a, b) => a.timestamp - b.timestamp);

  const clusters = [];
  for (const e of applies) {
    const last = clusters[clusters.length - 1];
    const alive = !deadRecently(e.targetID, e.timestamp);
    if (last && e.timestamp - last.timestamp <= clusterMs) {
      last.count += 1;
      if (alive) last.alive += 1;
    } else {
      clusters.push({ timestamp: e.timestamp, count: 1, alive: alive ? 1 : 0 });
    }
  }
  return clusters.filter((c) => c.alive > 0).map((c) => c.timestamp);
}

module.exports = { detectLustUses, DEFAULT_FAMILY, DEFAULT_CLUSTER_MS, DEAD_RECENT_MS };
