// 用法: node tools/wclplan/cli.js <input.json> <out-dir>
// 读输入 JSON（见 docs/superpowers/plans/2026-09-30-wcl-to-mdt-npt-plan.md 头部约定），写:
//   <out-dir>/route.mdt.txt   合并后的 MDT 导入字符串
//   <out-dir>/importplan.txt  每波一条 /npt importplan 行
//   <out-dir>/summary.json    合并组、routeKey 与每波 usage，供人工核对
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { decodeMdtString, encodeMdtString } = require("./mdtstring.js");
const { mergePulls } = require("./merge.js");
const { buildPlanLines, computeRouteKey } = require("./plan.js");
const { loadNpcIds, assignDeathsToPulls, mapPullsToFights } = require("./align.js");

function main() {
  const [inputPath, outDir] = process.argv.slice(2);
  if (!inputPath || !outDir) {
    console.error("usage: node tools/wclplan/cli.js <input.json> <out-dir>");
    process.exitCode = 2;
    return;
  }
  const input = JSON.parse(fs.readFileSync(inputPath, "utf8"));
  const preset = decodeMdtString(input.routeString);
  const pulls = preset.value.pulls;
  const npcIds = loadNpcIds(fs.readFileSync(input.mdtDungeonFile, "utf8"));
  const aligned = assignDeathsToPulls(pulls, npcIds, input.deathEvents);
  if (aligned.unassigned.length > 0) {
    console.error("warn: " + aligned.unassigned.length + " deaths unassigned (route/log mismatch?)");
  }
  // 合波判据只在 WCL fight 空间做（脱战信息只在那里可靠）；
  // 再用对齐结果把每个路线 pull 映射回 fight，同波的路线 pull 合成一个 wave。
  const fightGroups = mergePulls(input.wclWindows, input.wclDeathCounts);
  const fightOfPull = mapPullsToFights(input.wclWindows, aligned);
  const groups = [];
  let pending = [];
  let currentWave = null;
  for (let i = 0; i < pulls.length; i++) {
    const fight = fightOfPull[i];
    if (fight === null) { pending.push(i + 1); continue; }
    const wave = fightGroups.findIndex((g) => g.includes(fight)) + 1;
    if (wave !== currentWave) { groups.push([]); currentWave = wave; }
    groups[groups.length - 1].push(...pending, i + 1);
    pending = [];
  }
  if (pending.length > 0) groups[groups.length - 1].push(...pending);
  if (groups.length !== fightGroups.length) {
    console.error("warn: merged waves " + groups.length + " != wcl-space " + fightGroups.length);
  }
  preset.value.pulls = groups.map((group) => {
    const merged = {};
    for (const pullNumber of group) {
      const pull = pulls[pullNumber - 1];
      for (const [enemyIdx, clones] of Object.entries(pull)) {
        merged[enemyIdx] = (merged[enemyIdx] || []).concat(clones);
      }
    }
    return merged;
  });
  preset.value.currentPull = 1;

  const routeKey = computeRouteKey(preset.value.pulls);
  const lines = buildPlanLines(groups, input.usage, routeKey);
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, "route.mdt.txt"), encodeMdtString(preset) + "\n");
  fs.writeFileSync(path.join(outDir, "importplan.txt"), lines.join("\n") + "\n");
  fs.writeFileSync(path.join(outDir, "summary.json"),
    JSON.stringify({ meta: input.meta || {}, groups, routeKey, lines }, null, 2) + "\n");
  console.log("groups: " + JSON.stringify(groups));
  console.log("routeKey: " + routeKey);
  console.log("wrote " + outDir + "/{route.mdt.txt,importplan.txt,summary.json}");
}

main();
