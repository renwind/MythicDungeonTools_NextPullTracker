// enemyIdx→npcId 取自 MDT 副本 Lua 表（["id"] = 按 enemyIdx 有序出现）。
// 对齐：每个 (pull, npc) 开一个容量=clone 数的队列，死亡按时间序消费队首。
// 合并波取并集，故合并内部的分配误差不影响产物。
"use strict";

function loadNpcIds(luaText) {
  const start = luaText.indexOf("MDT.dungeonEnemies[");
  if (start < 0) throw new Error("align: dungeonEnemies block not found");
  const ids = [];
  const re = /\["id"\]\s*=\s*(\d+)/g;
  let m;
  while ((m = re.exec(luaText.slice(start))) !== null) ids.push(Number(m[1]));
  const out = {};
  ids.forEach((id, i) => { out[i + 1] = id; });
  return out;
}

// enemyIdx -> {id, count, clones, health}；count=0 的是 boss/召唤物（不占兵力）；health 缺失默认 0。
function loadEnemyMeta(luaText) {
  const start = luaText.indexOf("MDT.dungeonEnemies[");
  if (start < 0) throw new Error("align: dungeonEnemies block not found");
  const block = luaText.slice(start);
  const re = /\["id"\]\s*=\s*(\d+),\s*\["count"\]\s*=\s*(\d+)(?:,\s*\["health"\]\s*=\s*(\d+))?/g;
  const meta = {};
  let m;
  let idx = 0;
  while ((m = re.exec(block)) !== null) {
    idx += 1;
    meta[idx] = { id: Number(m[1]), count: Number(m[2]), clones: 0, health: m[3] ? Number(m[3]) : 0 };
  }
  const cloneRe = /\["clones"\] = \{([\s\S]*?)\n    \}/g;
  idx = 0;
  while ((m = cloneRe.exec(block)) !== null) {
    idx += 1;
    if (meta[idx]) meta[idx].clones = (m[1].match(/\[\d+\] = \{/g) || []).length;
  }
  return meta;
}

function assignDeathsToPulls(pulls, npcIds, deathEvents) {
  const queues = {};
  pulls.forEach((pull, pullIndex) => {
    for (const [idx, clones] of Object.entries(pull)) {
      const npc = npcIds[Number(idx)];
      if (!npc || !Array.isArray(clones) || clones.length === 0) continue;
      (queues[npc] = queues[npc] || []).push({ pull: pullIndex + 1, remaining: clones.length });
    }
  });
  const windows = pulls.map(() => ({ start: null, end: null }));
  const deathCounts = pulls.map(() => 0);
  const unassigned = [];
  const deathPulls = [];
  const sorted = deathEvents.slice().sort((a, b) => a.timestamp - b.timestamp);
  for (const death of sorted) {
    const entry = (queues[death.gameId] || []).find((q) => q.remaining > 0);
    if (!entry) { unassigned.push(death); deathPulls.push(null); continue; }
    entry.remaining -= 1;
    const seconds = death.timestamp / 1000;
    const w = windows[entry.pull - 1];
    w.start = w.start === null ? seconds : Math.min(w.start, seconds);
    w.end = w.end === null ? seconds : Math.max(w.end, seconds);
    deathCounts[entry.pull - 1] += 1;
    deathPulls.push(entry.pull);
  }
  return { windows, deathCounts, unassigned, deathPulls, deathSeconds: sorted.map((d) => d.timestamp / 1000) };
}

// 把每个路线 pull 映射回它所属的 WCL fight（1-based）：用该 pull 死亡窗口中点
// 落在哪个 fight 窗口内判定。零死亡 pull 无中点，返回 null，
// 由调用方按「tag-only 并入下一波」处理（合波判据只在 fight 空间做）。
function mapPullsToFights(fightWindows, aligned) {
  return aligned.windows.map((w) => {
    if (w.start === null || w.end === null) return null;
    const mid = (w.start + w.end) / 2;
    for (let i = 0; i < fightWindows.length; i++) {
      if (mid >= fightWindows[i].start - 2 && mid <= fightWindows[i].end + 2) return i + 1;
    }
    return null;
  });
}

module.exports = { loadNpcIds, loadEnemyMeta, assignDeathsToPulls, mapPullsToFights };
