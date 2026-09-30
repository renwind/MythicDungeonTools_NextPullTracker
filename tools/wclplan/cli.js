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
const { loadNpcIds, assignDeathsToPulls } = require("./align.js");

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
  const groups = mergePulls(aligned.windows, aligned.deathCounts);
  if (input.wclWindows) {
    const wclGroups = mergePulls(input.wclWindows, input.wclDeathCounts);
    if (wclGroups.length !== groups.length) {
      console.error("warn: merged waves route-space " + groups.length + " != wcl-space " + wclGroups.length);
    }
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
