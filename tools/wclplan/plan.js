// 把「每波冷却使用」翻译成 /npt importplan 命令行。
// ID 与 Modules/CooldownData.lua SEED_TABLE[262] 对齐：
//   嗜血族取萨满英勇 32182；升腾取 114050；药水取默认 itemID 241308。
// uses 只在 >=2 时出现在 spec 里（Lua 侧 SetUses 对 1 的处理是删字段）。
"use strict";

const SKILL_IDS = { lust: 32182, asc: 114050, pot: 241308 };
const SKILL_KIND = { lust: "spell", asc: "spell", pot: "item" };
const SKILL_ORDER = ["lust", "asc", "pot"];

function buildEntrySpec(usage) {
  const parts = [];
  for (const skill of SKILL_ORDER) {
    const count = usage[skill] || 0;
    if (count < 1) continue;
    let token = SKILL_IDS[skill] + ":" + SKILL_KIND[skill] + ":use";
    if (count >= 2) token += ":" + Math.min(5, count);
    parts.push(token);
  }
  return parts.join(";");
}

function buildPlanLines(groups, usagePerOriginalPull, routeKey) {
  const lines = [];
  groups.forEach((group, waveIndex) => {
    const summed = { lust: 0, asc: 0, pot: 0 };
    for (const pull of group) {
      const usage = usagePerOriginalPull[pull - 1] || {};
      for (const skill of SKILL_ORDER) summed[skill] += usage[skill] || 0;
    }
    const spec = buildEntrySpec(summed);
    if (spec === "") return;
    lines.push("/npt importplan " + routeKey + " " + (waveIndex + 1) + " " + spec);
  });
  return lines;
}

// 与 Lua 侧 ImportPlan.computeRouteKey 逐字节同公式：
// 每波 "idx:count" 字典序排序后逗号连接，波之间分号连接，
// 再对整串做 (hash*31+byte) mod 2^32 滚动哈希，输出 8 位小写 hex。
// 不依赖 MDT enemies 表（与存库的 per-pull fingerprint 是两套东西）。
function pullFingerprint(pull) {
  const parts = [];
  for (const [key, clones] of Object.entries(pull || {})) {
    const idx = Number(key);
    if (Number.isInteger(idx) && Array.isArray(clones)) parts.push(idx + ":" + clones.length);
  }
  parts.sort();
  return parts.join(",");
}

function computeRouteKey(pulls) {
  const joined = pulls.map(pullFingerprint).join(";");
  let hash = 0;
  for (let i = 0; i < joined.length; i++) {
    hash = (hash * 31 + joined.charCodeAt(i)) % 4294967296;
  }
  return hash.toString(16).padStart(8, "0");
}

module.exports = { buildEntrySpec, buildPlanLines, computeRouteKey, SKILL_IDS };
