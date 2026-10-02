const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { decodeMdtString, encodeMdtString } = require("./mdtstring.js");
const { computeRouteKey, specLines, buildPlanPackLine } = require("./plan.js");
const fixture = require("./fixtures/confirmed-combat.json");
const CLI = path.join(__dirname, "cli.js");

function run(change = () => {}, extraArgs = []) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "wclplan-cli-"));
  try {
    const dungeon = path.join(dir, "dungeon.lua");
    fs.writeFileSync(dungeon, 'MDT.dungeonEnemies[1] = {\n  [1] = {\n    ["name"] = "Trash",\n    ["id"] = 101,\n    ["count"] = 5,\n    ["clones"] = {\n      [1] = {}, [2] = {}, [3] = {}, [4] = {}, [5] = {},\n    },\n  },\n  [2] = {\n    ["name"] = "Boss",\n    ["id"] = 202,\n    ["count"] = 0,\n    ["isBoss"] = true,\n    ["clones"] = {\n      [1] = {},\n    },\n  },\n}\n');
    const original = { text: "Confirmed waves", uid: "confirmed-1", value: { currentDungeonIdx: 1, currentPull: 3, pulls: Array.from({ length: 6 }, (_, i) => i === 5 ? { 2: [1], color: "#123456" } : { 1: [i + 1], color: "#123456" }) } };
    const input = { ...structuredClone(fixture), mdtDungeonFile: dungeon, routeString: encodeMdtString(original),
      deathEvents: [50, 90, 145, 230, 350, 500].map((t, i) => ({ gameId: i === 5 ? 202 : 101, timestamp: t * 1000 })),
      usage: [{ lust: 1, asc: 1 }, {}, { asc: 1 }, {}, {}, { asc: 2, pot: 1 }],
    };
    change(input);
    const inputPath = path.join(dir, "input.json");
    fs.writeFileSync(inputPath, JSON.stringify(input));
    const outDir = path.join(dir, "out");
    const res = spawnSync(process.execPath, [CLI, inputPath, outDir, ...extraArgs], { encoding: "utf8" });
    const result = {
      ...res,
      outputFiles: fs.existsSync(outDir) ? fs.readdirSync(outDir).sort() : [],
      wroteOutput: fs.existsSync(path.join(outDir, "summary.json")),
      original,
    };
    if (result.wroteOutput) {
      result.summary = JSON.parse(fs.readFileSync(path.join(outDir, "summary.json"), "utf8"));
      result.route = decodeMdtString(fs.readFileSync(path.join(outDir, "route.mdt.txt"), "utf8").trim());
      result.lines = fs.readFileSync(path.join(outDir, "importplan.txt"), "utf8").trim().split("\n").filter(Boolean);
      result.pack = fs.readFileSync(path.join(outDir, "importplan-pack.txt"), "utf8").trim();
      result.ratioPack = fs.readFileSync(path.join(outDir, "importratiopack.txt"), "utf8").trim();
    }
    return result;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function succeeded(out) { assert.equal(out.status, 0, out.stderr); }

test("默认使用明确边界，MDT/计划/summary保留同一四波（包括零使用第2波）", () => {
  const out = run();
  succeeded(out);
  assert.equal(out.summary.granularity, "combat");
  assert.deepEqual(out.summary.groups, [[1], [2], [3, 4], [5, 6]]);
  assert.deepEqual(out.summary.waves.map(w => w.pulls), out.summary.groups);
  assert.deepEqual(out.summary.waveUsage.map(u => u.asc), [1, 0, 1, 2]);
  assert.deepEqual(out.summary.castAssignments, [0, 0, 2, 3, 3, 3]);
  assert.equal(out.route.value.pulls.length, 4);
  assert.equal(out.route.value.currentPull, 1);
  assert.equal(typeof out.route.value.pulls[2].color, "string");
  assert.deepEqual(out.route.value.pulls[2][1], [3, 4]);
  assert.deepEqual(out.route.value.pulls[3][2], [1]);
  assert.equal(out.summary.routeKey, "648e7d8d");
  assert.equal(out.summary.routeKey, computeRouteKey(out.route.value.pulls));
  assert.deepEqual(out.lines, specLines(out.summary.waveUsage, out.summary.routeKey));
  assert.equal(out.pack, "/npt importplanpack 648e7d8d 1:l1a1;3:a1;4:a2p1");
  assert.equal(out.pack, buildPlanPackLine(out.summary.waveUsage, out.summary.routeKey));
  assert.deepEqual(out.summary.rotationCastEvents, fixture.rotationCastEvents);
  assert.deepEqual(out.summary.rotationAssignments, [0, 0, 1, 2, 2, 3, 3, 3]);
  assert.deepEqual(out.summary.rotationUsage, [
    { elementalBlast: 1, earthquake: 1 },
    { elementalBlast: 0, earthquake: 1 },
    { elementalBlast: 1, earthquake: 1 },
    { elementalBlast: 2, earthquake: 1 },
  ]);
  const ratioCommand = "/npt importratiopack 648e7d8d 1.1,0.1,1.1,2.1";
  assert.equal(out.summary.ratioPackLine, ratioCommand);
  assert.equal(out.ratioPack, ratioCommand);
  assert.match(out.stdout, new RegExp(ratioCommand.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.match(out.stdout, /importratiopack\.txt/);
  assert.ok(!out.lines.some(line => / 2 /.test(line)));
  assert.equal(out.summary.deaths.length, 6);
  assert.equal(out.summary.deaths.at(-1).wave, 3);
});

test("缺少连续战斗证据时保留原分段，旧wclWindows和零死亡不再强行合并", () => {
  const out = run(input => {
    delete input.combatSegments;
    input.wclWindows = [{ start: 0, end: 500 }];
    input.wclDeathCounts = [0];
  });
  succeeded(out);
  assert.deepEqual(out.summary.groups, [[1], [2], [3], [4], [5], [6]]);
  assert.equal(out.summary.waveUsage[5].asc, 2);
  assert.ok(out.summary.warnings.some(w => /continuity/.test(w)));
});

test("缺少timings但有明确施法pull时仍可成对导出，不丢零死亡波", () => {
  const out = run(input => {
    delete input.pullTimings;
    delete input.combatSegments;
    delete input.bossEncounters;
    input.deathEvents = [];
    input.rotationCastEvents = [];
    input.castEvents.forEach((c, i) => { c.pull = [1, 1, 3, 6, 6, 6][i]; });
  });
  succeeded(out);
  assert.equal(out.summary.groups.length, 6);
  assert.equal(out.summary.waves[0].start, null);
  assert.equal(out.summary.waveUsage[5].asc, 2);
});

test("无法归属施法时在写文件前报错，不把它猜到最近波", () => {
  const out = run(input => { input.castEvents.push({ skill: "asc", t: 58 }); });
  assert.notEqual(out.status, 0);
  assert.match(out.stderr, /unassigned cast/i);
  assert.equal(out.wroteOutput, false);
});

test("缺少或无法归属 rotationCastEvents 时不写任何产物", () => {
  const missing = run(input => { delete input.rotationCastEvents; });
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /rotationCastEvents.*array/i);
  assert.deepEqual(missing.outputFiles, []);

  const unassigned = run(input => {
    input.rotationCastEvents.push({ type: "cast", spellId: 61882, t: 58 });
  });
  assert.notEqual(unassigned.status, 0);
  assert.match(unassigned.stderr, /unassigned rotation cast at 58/i);
  assert.deepEqual(unassigned.outputFiles, []);
});

test("begincast 和未知 rotation spellId 在写文件前拒绝", () => {
  const beginCast = run(input => {
    input.rotationCastEvents[0].type = "begincast";
  });
  assert.notEqual(beginCast.status, 0);
  assert.match(beginCast.stderr, /invalid rotation event at index 0/i);
  assert.deepEqual(beginCast.outputFiles, []);

  const wrongSpell = run(input => {
    input.rotationCastEvents[0].spellId = 999999;
  });
  assert.notEqual(wrongSpell.status, 0);
  assert.match(wrongSpell.stderr, /invalid rotation event at index 0/i);
  assert.deepEqual(wrongSpell.outputFiles, []);
});

test("Boss波升腾超上限2时按pull拆分，单个boss pull超限保留并告警", () => {
  const out = run(input => { input.castEvents.push({ skill: "asc", t: 470 }, { skill: "asc", t: 490 }); });
  succeeded(out);
  assert.deepEqual(out.summary.groups, [[1], [2], [3, 4], [5], [6]]);
  assert.equal(out.summary.waveUsage[4].asc, 4);
  assert.match(out.pack, /5:a4p1/);
  assert.ok(out.summary.warnings.some(w => /pull 6/i.test(w) && /ascendance/i.test(w)));
});

test("超过NPT格式的5次上限明确报错，不拆波或静默截断次数", () => {
  const out = run(input => {
    for (const t of [450, 460, 470, 480]) input.castEvents.push({ skill: "asc", t });
  });
  assert.notEqual(out.status, 0);
  assert.match(out.stderr, /5 uses/);
  assert.equal(out.wroteOutput, false);
});

test("手工usage模式仍共用同一明确分组", () => {
  const out = run(() => {}, ["--granularity=fight"]);
  succeeded(out);
  assert.deepEqual(out.summary.groups, [[1], [2], [3, 4], [5, 6]]);
  assert.deepEqual(out.summary.waveUsage.map(u => u.asc), [1, 0, 1, 2]);
  assert.deepEqual(out.lines, out.summary.lines);
});

test("非法手工usage和缺省手工usage不生成半套计划", () => {
  const out = run(input => { input.usage[2] = { asc: -1 }; }, ["--granularity=fight"]);
  assert.notEqual(out.status, 0);
  assert.match(out.stderr, /usage/);
  assert.equal(out.wroteOutput, false);
  const missing = run(input => { delete input.usage; }, ["--granularity=fight"]);
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /usage/);
});

test("空路线和错序边界在生成前拒绝", () => {
  const out = run(input => { input.routeString = encodeMdtString({ value: { pulls: [] } }); });
  assert.notEqual(out.status, 0);
  assert.equal(out.wroteOutput, false);
  const unordered = run(input => { input.pullTimings[1].start = -1; });
  assert.notEqual(unordered.status, 0);
  assert.match(unordered.stderr, /pullTimings/);
});

test("未知flag和缺参数给出用法与明确输入字段", () => {
  const invalid = run(() => {}, ["--granularity=bogus"]);
  assert.equal(invalid.status, 2);
  assert.match(invalid.stderr, /must be fight or combat/);
  const missing = spawnSync(process.execPath, [CLI], { encoding: "utf8" });
  assert.equal(missing.status, 2);
  assert.match(missing.stderr, /pullTimings/);
  assert.match(missing.stderr, /combatSegments/);
  assert.match(missing.stderr, /bossEncounters/);
  assert.match(missing.stderr, /rotationCastEvents: required array of \{type:cast,spellId:117014\|61882,t\}/);
  assert.match(missing.stderr, /successful casts only/);
  assert.doesNotMatch(missing.stderr, /\{skill:elementalBlast\|earthquake,t\}/);
  assert.match(missing.stderr, /importratiopack\.txt/);
});

test("端到端：小怪段最高血 pull 作锚点（区别于 pull 顺序回退），升腾均分", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "wclplan-anchor-"));
  try {
    const dungeon = path.join(dir, "d.lua");
    fs.writeFileSync(dungeon,
      "MDT.dungeonEnemies[1] = {\n" +
      '  [1] = {\n    ["name"] = "Trash",\n    ["id"] = 101,\n    ["count"] = 5,\n    ["health"] = 1000000,\n    ["clones"] = {\n      [1] = {},\n    },\n  },\n' +
      '  [2] = {\n    ["name"] = "Mid",\n    ["id"] = 202,\n    ["count"] = 10,\n    ["health"] = 3000000,\n    ["clones"] = {\n      [1] = {},\n    },\n  },\n' +
      '  [3] = {\n    ["name"] = "Elite",\n    ["id"] = 303,\n    ["count"] = 30,\n    ["health"] = 9700000,\n    ["clones"] = {\n      [1] = {},\n    },\n  },\n' +
      "}\n");
    const original = { text: "Anchor", uid: "anchor-1", value: { currentDungeonIdx: 1, currentPull: 1,
      pulls: [{ 1: [1], color: "#123456" }, { 2: [1], color: "#123456" }, { 3: [1], color: "#123456" }] } };
    const input = {
      meta: { dungeon: "Anchor Test", key: 22 },
      mdtDungeonFile: dungeon,
      routeString: encodeMdtString(original),
      pullTimings: [{ start: 10, end: 200 }, { start: 10, end: 200 }, { start: 10, end: 200 }],
      combatSegments: [{ start: 10, end: 200 }],
      bossEncounters: [],
      castEvents: [{ skill: "asc", t: 30 }, { skill: "asc", t: 150 }],
      rotationCastEvents: [],
      deathEvents: [],
    };
    const inputPath = path.join(dir, "in.json");
    fs.writeFileSync(inputPath, JSON.stringify(input));
    const outDir = path.join(dir, "out");
    const res = spawnSync(process.execPath, [CLI, inputPath, outDir], { encoding: "utf8" });
    assert.equal(res.status, 0, res.stderr);
    const summary = JSON.parse(fs.readFileSync(path.join(outDir, "summary.json"), "utf8"));
    assert.deepEqual(summary.groups, [[1, 2], [3]]); // 锚点=pull3(Elite 9.7M)；回退会给 [[1],[2,3]]
    assert.deepEqual(summary.waveUsage.map(u => u.asc), [1, 1]);
    assert.deepEqual(summary.warnings, []);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
