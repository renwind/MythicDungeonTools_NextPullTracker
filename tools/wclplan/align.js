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
  const sorted = deathEvents.slice().sort((a, b) => a.timestamp - b.timestamp);
  for (const death of sorted) {
    const entry = (queues[death.gameId] || []).find((q) => q.remaining > 0);
    if (!entry) { unassigned.push(death); continue; }
    entry.remaining -= 1;
    const seconds = death.timestamp / 1000;
    const w = windows[entry.pull - 1];
    w.start = w.start === null ? seconds : Math.min(w.start, seconds);
    w.end = w.end === null ? seconds : Math.max(w.end, seconds);
    deathCounts[entry.pull - 1] += 1;
  }
  return { windows, deathCounts, unassigned };
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

module.exports = { loadNpcIds, assignDeathsToPulls, mapPullsToFights };
