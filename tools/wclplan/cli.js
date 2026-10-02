"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { decodeMdtString, encodeMdtString } = require("./mdtstring.js");
const { specLines, sumUsagePerWave, sumUsage, buildPlanPackLine, computeRouteKey } = require("./plan.js");
const { loadNpcIds, loadEnemyMeta, assignDeathsToPulls } = require("./align.js");
const { buildCombatWaveDetail, castWaves } = require("./waves.js");
const { assignRotationEvents, summarizeRotation, buildRatioPackLine } = require("./rotation.js");

const USAGE = `usage: node tools/wclplan/cli.js <input.json> <out-dir> [--granularity=combat|fight]
combat (default): count castEvents; fight: sum manually supplied per-pull usage.
Both modes use the same evidence-based groups.
pullTimings: one {start,end} or null per Threechest pull.
combatSegments: verified continuous {start,end} intervals; not WCL summary windows.
bossEncounters: {start,end,pull,firstPull?}; firstPull includes confirmed trailing trash.
Times are seconds since the run started; pull numbers are 1-based.
castEvents: {skill:asc|lust|pot,t,pull?}; explicit pull can locate a pre-combat cast.
rotationCastEvents: required array of {type:cast,spellId:117014|61882,t}; successful casts only; assigned to final waves.
Outputs: route.mdt.txt, importplan.txt, importplan-pack.txt, importratiopack.txt, summary.json.
No continuity evidence means retain original boundaries, never infer from deaths.
Example evidence: tools/wclplan/fixtures/confirmed-combat.json`;

function parseArgs(argv) {
  const positional = [];
  let granularity = "combat";
  for (const arg of argv) {
    if (arg.startsWith("--granularity=")) granularity = arg.slice("--granularity=".length);
    else if (arg.startsWith("--")) throw new Error("cli: unknown flag " + arg);
    else positional.push(arg);
  }
  if (granularity !== "fight" && granularity !== "combat") {
    throw new Error("cli: --granularity must be fight or combat, got " + granularity);
  }
  if (positional.length !== 2) throw new Error("cli: input and output paths are required");
  return { inputPath: positional[0], outDir: positional[1], granularity };
}

function manualUsage(usage, count) {
  if (!Array.isArray(usage) || usage.length !== count) throw new Error("cli: usage must contain one entry per route pull");
  for (const row of usage) {
    if (!row || typeof row !== "object" || Array.isArray(row)) throw new Error("cli: invalid usage entry");
    for (const [skill, value] of Object.entries(row)) {
      if (!["asc", "lust", "pot"].includes(skill) || !Number.isInteger(value) || value < 0) {
        throw new Error("cli: usage must contain non-negative integer skill counts");
      }
    }
  }
  return usage;
}

function main({ inputPath, outDir, granularity }) {
  const input = JSON.parse(fs.readFileSync(inputPath, "utf8"));
  const luaText = fs.readFileSync(input.mdtDungeonFile, "utf8");
  const preset = decodeMdtString(input.routeString);
  const pulls = preset.value && preset.value.pulls;
  if (!Array.isArray(pulls) || !pulls.length) throw new Error("cli: route must contain pulls");
  for (const pull of pulls) {
    if (!pull || typeof pull !== "object") throw new Error("cli: invalid route pull");
    for (const [key, clones] of Object.entries(pull)) {
      if (!/^\d+$/.test(key)) continue;
      if (!Array.isArray(clones) || clones.some(id => !Number.isInteger(id) || id < 1)) throw new Error("cli: invalid clone list");
    }
  }
  const enemyMeta = loadEnemyMeta(luaText);
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
  const groups = detail.waves.map(w => w.pulls);
  const assignments = castWaves(casts, detail);
  const rotationCastEvents = input.rotationCastEvents;
  const rotationAssignments = assignRotationEvents(rotationCastEvents, detail.waves);
  const rotationUsage = summarizeRotation(detail.waves.length, rotationCastEvents, rotationAssignments);
  const warnings = detail.warnings.slice();
  const unassigned = assignments.flatMap((wave, i) => wave === -1 ? [casts[i].t] : []);
  let waveUsage;
  if (granularity === "combat") {
    if (!Array.isArray(input.castEvents)) throw new Error("cli: combat mode requires castEvents (an empty array means no casts)");
    if (unassigned.length) throw new Error("cli: unassigned cast at " + unassigned.join(", ") + "; supply pullTimings or explicit cast pull");
    waveUsage = sumUsagePerWave(groups.length, casts, assignments);
  } else {
    const usage = manualUsage(input.usage, pulls.length);
    waveUsage = groups.map(g => sumUsage(g, usage));
    if (unassigned.length) warnings.push("Unassigned cast times: " + unassigned.join(", ") + "; plan counts come from manual usage.");
  }
  for (const [i, usage] of waveUsage.entries()) {
    if (Object.values(usage).some(n => n > 5)) throw new Error("cli: NPT supports at most 5 uses per skill in wave " + (i + 1) + "; counts were not truncated or used to split the wave");
  }

  const deathEvents = input.deathEvents ?? [];
  if (!Array.isArray(deathEvents) || deathEvents.some(e => !e || !Number.isInteger(e.gameId) || e.gameId < 1 || !Number.isFinite(e.timestamp) || e.timestamp < 0)) {
    throw new Error("cli: invalid deathEvents");
  }
  const aligned = assignDeathsToPulls(pulls, loadNpcIds(luaText), deathEvents);
  if (aligned.unassigned.length) warnings.push(aligned.unassigned.length + " deaths have no matching route enemy; death alignment does not determine wave boundaries.");
  const waveOfPull = new Map();
  groups.forEach((g, i) => g.forEach(p => waveOfPull.set(p, i)));
  const deaths = aligned.deathSeconds.map((t, i) => ({ t, wave: waveOfPull.get(aligned.deathPulls[i]) ?? null }));

  preset.value.pulls = groups.map(group => {
    const merged = Object.fromEntries(Object.entries(pulls[group[0] - 1]).filter(([key]) => !/^\d+$/.test(key)));
    for (const pullNumber of group) {
      for (const [key, clones] of Object.entries(pulls[pullNumber - 1])) {
        if (/^\d+$/.test(key)) merged[key] = (merged[key] || []).concat(clones);
      }
    }
    return merged;
  });
  const lastPull = preset.value.pulls.at(-1);
  const extraEnemies = input.lastWaveEnemies ?? [];
  if (!Array.isArray(extraEnemies) || extraEnemies.some(idx => !Number.isInteger(idx) || !enemyMeta[idx])) {
    throw new Error("cli: invalid lastWaveEnemies");
  }
  for (const idx of extraEnemies) {
    lastPull[idx] = lastPull[idx] || [];
    if (!lastPull[idx].includes(1)) lastPull[idx].push(1);
  }
  preset.value.currentPull = 1;
  const routeKey = computeRouteKey(preset.value.pulls);
  const lines = specLines(waveUsage, routeKey);
  const packLine = buildPlanPackLine(waveUsage, routeKey);
  const ratioPackLine = buildRatioPackLine(rotationUsage, routeKey);
  const summary = {
    meta: input.meta || {}, granularity, groups, routeKey, waveUsage, lines, packLine,
    waves: detail.waves, castEvents: casts, castAssignments: assignments,
    rotationCastEvents, rotationAssignments, rotationUsage, ratioPackLine,
    deaths, warnings,
  };
  const routeText = encodeMdtString(preset);
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, "route.mdt.txt"), routeText + "\n");
  fs.writeFileSync(path.join(outDir, "importplan.txt"), lines.join("\n") + "\n");
  fs.writeFileSync(path.join(outDir, "importplan-pack.txt"), packLine + "\n");
  fs.writeFileSync(path.join(outDir, "importratiopack.txt"), ratioPackLine + "\n");
  fs.writeFileSync(path.join(outDir, "summary.json"), JSON.stringify(summary, null, 2) + "\n");
  for (const warning of warnings) console.error("warn: " + warning);
  console.log("groups: " + JSON.stringify(groups));
  console.log("routeKey: " + routeKey);
  console.log(packLine);
  console.log(ratioPackLine);
  console.log("wrote " + outDir + "/{route.mdt.txt,importplan.txt,importplan-pack.txt,importratiopack.txt,summary.json}");
}

if (process.argv.length === 3 && process.argv[2] === "--help") {
  console.log(USAGE);
} else {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(error.message + "\n" + USAGE);
    process.exitCode = 2;
  }
  if (args) {
    try {
      main(args);
    } catch (error) {
      console.error(error.message);
      process.exitCode = 1;
    }
  }
}
