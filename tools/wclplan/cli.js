// 用法: node tools/wclplan/cli.js <input.json> <out-dir> [--granularity=fight|combat]
// 读输入 JSON（见 docs/superpowers/plans/2026-09-30-wcl-to-mdt-npt-plan.md 头部约定），写:
//   <out-dir>/route.mdt.txt   合并后的 MDT 导入字符串
//   <out-dir>/importplan.txt  每波一条 /npt importplan 行
//   <out-dir>/summary.json    合并组、routeKey 与每波 usage，供人工核对
//
// granularity:
//   fight  (默认) 按 WCL fight 窗口 + 死亡数合波，usage 取输入里的 input.usage（人工读报告）
//   combat 按死亡时间簇合波（waves.js 规则），usage 由 input.castEvents 自动归属
//
// input.lastWaveEnemies: 需要补挂到最后一波的 MDT enemyIdx 数组。Threechest 导出的路线
// 不含 count=0 的 boss（如纳洛拉克洞穴 25 Nalorakk / 26 Zul'jarra），少了它们最后一波
// 会被 NPT 的零 forces 自动跳过；但补谁属于人工判断（同副本还有 27 Echo 之类召唤物），
// 所以这里不猜，由输入显式给。
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { decodeMdtString, encodeMdtString } = require("./mdtstring.js");
const { mergePulls } = require("./merge.js");
const { buildPlanLines, specLines, sumUsagePerWave, sumUsage, buildPlanPackLine, computeRouteKey } = require("./plan.js");
const { loadNpcIds, loadEnemyMeta, assignDeathsToPulls, mapPullsToFights } = require("./align.js");
const { buildCombatWaveDetail, castWaves } = require("./waves.js");

function parseArgs(argv) {
  const positional = [];
  let granularity = "fight";
  for (const arg of argv) {
    if (arg.startsWith("--granularity=")) granularity = arg.slice("--granularity=".length);
    else if (arg.startsWith("--")) throw new Error("cli: unknown flag " + arg);
    else positional.push(arg);
  }
  if (granularity !== "fight" && granularity !== "combat") {
    throw new Error("cli: --granularity must be fight or combat, got " + granularity);
  }
  return { inputPath: positional[0], outDir: positional[1], granularity };
}

// fight 粒度：合波判据只在 WCL fight 空间做（脱战信息只在那里可靠）；
// 再用对齐结果把每个路线 pull 映射回 fight，同波的路线 pull 合成一个 wave。
function fightGroups(input, pulls, aligned) {
  const merged = mergePulls(input.wclWindows, input.wclDeathCounts);
  const fightOfPull = mapPullsToFights(input.wclWindows, aligned);
  const groups = [];
  let pending = [];
  let currentWave = null;
  for (let i = 0; i < pulls.length; i++) {
    const fight = fightOfPull[i];
    if (fight === null) { pending.push(i + 1); continue; }
    const wave = merged.findIndex((g) => g.includes(fight)) + 1;
    if (wave !== currentWave) { groups.push([]); currentWave = wave; }
    groups[groups.length - 1].push(...pending, i + 1);
    pending = [];
  }
  if (pending.length > 0) groups[groups.length - 1].push(...pending);
  if (groups.length !== merged.length) {
    console.error("warn: merged waves " + groups.length + " != wcl-space " + merged.length);
  }
  return groups;
}

function combatGroups(input, aligned) {
  const casts = input.castEvents || [];
  const detail = buildCombatWaveDetail({
    deathSeconds: aligned.deathSeconds,
    deathPulls: aligned.deathPulls,
    burstCasts: casts.filter((c) => c.skill !== "pot").map((c) => c.t),
    ascCasts: casts.filter((c) => c.skill === "asc").map((c) => c.t),
  });
  const usage = sumUsagePerWave(detail.waves.length, casts, castWaves(casts, detail));
  return { groups: detail.waves.map((w) => w.pulls), usage };
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(err.message);
    console.error("usage: node tools/wclplan/cli.js <input.json> <out-dir> [--granularity=fight|combat]");
    process.exitCode = 2;
    return;
  }
  const { inputPath, outDir, granularity } = args;
  if (!inputPath || !outDir) {
    console.error("usage: node tools/wclplan/cli.js <input.json> <out-dir> [--granularity=fight|combat]");
    process.exitCode = 2;
    return;
  }
  const input = JSON.parse(fs.readFileSync(inputPath, "utf8"));
  const luaText = fs.readFileSync(input.mdtDungeonFile, "utf8");
  const preset = decodeMdtString(input.routeString);
  const pulls = preset.value.pulls;
  const aligned = assignDeathsToPulls(pulls, loadNpcIds(luaText), input.deathEvents);
  if (aligned.unassigned.length > 0) {
    console.error("warn: " + aligned.unassigned.length + " deaths unassigned (route/log mismatch?)");
  }

  let groups;
  let waveUsage;
  if (granularity === "combat") {
    if (!Array.isArray(input.castEvents)) throw new Error("cli: combat granularity needs input.castEvents");
    const combat = combatGroups(input, aligned);
    groups = combat.groups;
    waveUsage = combat.usage;
  } else {
    groups = fightGroups(input, pulls, aligned);
    waveUsage = groups.map((group) => sumUsage(group, input.usage));
  }

  preset.value.pulls = groups.map((group) => {
    const merged = {};
    for (const pullNumber of group) {
      for (const [enemyIdx, clones] of Object.entries(pulls[pullNumber - 1])) {
        merged[enemyIdx] = (merged[enemyIdx] || []).concat(clones);
      }
    }
    return merged;
  });
  const lastPull = preset.value.pulls[preset.value.pulls.length - 1];
  for (const enemyIdx of input.lastWaveEnemies || []) {
    lastPull[String(enemyIdx)] = (lastPull[String(enemyIdx)] || []).concat([1]);
  }
  preset.value.currentPull = 1;

  const routeKey = computeRouteKey(preset.value.pulls);
  const lines = granularity === "combat"
    ? specLines(waveUsage, routeKey)
    : buildPlanLines(groups, input.usage, routeKey);
  const packLine = buildPlanPackLine(waveUsage, routeKey);

  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, "route.mdt.txt"), encodeMdtString(preset) + "\n");
  fs.writeFileSync(path.join(outDir, "importplan.txt"), lines.join("\n") + "\n");
  fs.writeFileSync(path.join(outDir, "importplan-pack.txt"), packLine + "\n");
  fs.writeFileSync(path.join(outDir, "summary.json"),
    JSON.stringify({ meta: input.meta || {}, granularity, groups, routeKey, waveUsage, lines, packLine }, null, 2) + "\n");
  reportUnusedBosses(luaText, preset.value.pulls);
  console.log("granularity: " + granularity);
  console.log("groups: " + JSON.stringify(groups));
  console.log("routeKey: " + routeKey);
  console.log(packLine);
  console.log(lines.join("\n"));
  console.log("wrote " + outDir + "/{route.mdt.txt,importplan.txt,importplan-pack.txt,summary.json}");
}

// count=0 的敌人不占兵力，Threechest 的导出可能整条漏掉；列出来让人判断要不要
// 用 lastWaveEnemies 补挂（boss 战若不在任何波里，NPT 会按零 forces 跳过）。
function reportUnusedBosses(luaText, finalPulls) {
  const meta = loadEnemyMeta(luaText);
  const used = new Set();
  for (const pull of finalPulls) for (const idx of Object.keys(pull)) used.add(Number(idx));
  const unused = Object.keys(meta)
    .map(Number)
    .filter((idx) => meta[idx].count === 0 && !used.has(idx));
  if (unused.length > 0) {
    console.error("note: count=0 enemies absent from the route: " + unused.join(",") +
      " (add to input.lastWaveEnemies if the final boss is missing)");
  }
}

main();
