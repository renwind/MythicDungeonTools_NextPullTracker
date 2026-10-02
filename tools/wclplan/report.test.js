"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const { spawnSync } = require("node:child_process");
const { encodeMdtString } = require("./mdtstring.js");
const { computeRouteKey, specLines, buildPlanPackLine } = require("./plan.js");
const { buildRatioPackLine } = require("./rotation.js");

const REPORT = path.join(__dirname, "report.js");

// Self-contained persisted CLI artifacts: no installed MDT data or CLI execution.
function fixture(t, change = () => {}) {
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), "wclplan report-"));
  t.after(() => fs.rmSync(outDir, { recursive: true, force: true }));
  const preset = { text: "Persisted route", value: { pulls: [{ 1: [1, 2] }, { 2: [1] }] } };
  const routeKey = computeRouteKey(preset.value.pulls);
  const waveUsage = [{ lust: 0, asc: 1, pot: 0 }, { lust: 1, asc: 1, pot: 0 }];
  const rotationUsage = [
    { elementalBlast: 8, earthquake: 2 },
    { elementalBlast: 1, earthquake: 9 },
  ];
  const rotationCastEvents = [
    ...Array.from({ length: 8 }, (_, i) => ({ type: "cast", spellId: 117014, t: 11 + i })),
    ...Array.from({ length: 2 }, (_, i) => ({ type: "cast", spellId: 61882, t: 21 + i })),
    { type: "cast", spellId: 117014, t: 61 },
    ...Array.from({ length: 9 }, (_, i) => ({ type: "cast", spellId: 61882, t: 62 + i })),
  ];
  const data = {
    preset,
    enemyName: "Fixture guard",
    input: { mdtDungeonFile: path.join(outDir, "dungeon.lua") },
    summary: {
      meta: { report: "persisted-report", dungeon: "Fixture dungeon", key: 22 },
      granularity: "combat",
      groups: [[1, 2], [3]],
      routeKey,
      waveUsage,
      lines: specLines(waveUsage, routeKey),
      packLine: buildPlanPackLine(waveUsage, routeKey),
      rotationCastEvents,
      rotationAssignments: [...Array(10).fill(0), ...Array(10).fill(1)],
      rotationUsage,
      ratioPackLine: buildRatioPackLine(rotationUsage, routeKey),
      waves: [
        { pulls: [1, 2], start: 10, end: 40, castStart: 0, castEnd: 45, reason: "confirmed-combat" },
        { pulls: [3], start: 60, end: 120, castStart: 45, castEnd: 140, reason: "boss-entry", bossStart: 60, firstBossAscendance: 75 },
      ],
      castEvents: [{ skill: "asc", t: 8 }, { skill: "lust", t: 48 }, { skill: "asc", t: 75, pull: 3 }, { skill: "pot", t: 145 }],
      castAssignments: [0, 1, 1, -1],
      deaths: [{ t: 20, wave: 0 }, { t: 31, wave: 0 }, { t: 65, wave: null }],
      warnings: ["Fixture warning: missing pull evidence"],
    },
  };
  change(data);
  const inputPath = path.join(outDir, "input.json");
  fs.writeFileSync(inputPath, JSON.stringify(data.input));
  fs.writeFileSync(data.input.mdtDungeonFile, `MDT.dungeonEnemies[1] = {
  [1] = {
    ["name"] = "${data.enemyName}",
    ["id"] = 1001,
    ["count"] = 5,
  },
  [2] = {
    ["name"] = "Fixture boss",
    ["id"] = 1002,
    ["count"] = 0,
  },
}`);
  fs.writeFileSync(path.join(outDir, "summary.json"), JSON.stringify(data.summary));
  fs.writeFileSync(path.join(outDir, "route.mdt.txt"), encodeMdtString(data.preset) + "\n");
  fs.writeFileSync(path.join(outDir, "importplan-pack.txt"), (data.packFile ?? data.summary.packLine) + "\n");
  fs.writeFileSync(path.join(outDir, "importratiopack.txt"), (data.ratioPackFile ?? data.summary.ratioPackLine) + "\n");
  return { ...data, outDir, inputPath };
}

function runReport(f) {
  return spawnSync(process.execPath, [REPORT, f.inputPath, f.outDir], { encoding: "utf8" });
}

function render(f) {
  const result = runReport(f);
  assert.equal(result.status, 0, result.stderr);
  const html = fs.readFileSync(path.join(f.outDir, "report.html"), "utf8");
  assert.doesNotMatch(html, /NaN|Infinity|undefined/);
  return html;
}

function tableRows(html) {
  return html.match(/<tbody>([\s\S]*?)<\/tbody>/)[1].match(/<tr[\s\S]*?<\/tr>/g) || [];
}

function expectRejected(t, change, message) {
  const f = fixture(t, change);
  const result = runReport(f);
  assert.notEqual(result.status, 0, "mismatched artifacts must fail");
  assert.match(result.stderr, message);
  assert.equal(fs.existsSync(path.join(f.outDir, "report.html")), false);
}

test("renders persisted groups, plan lines and copy controls with only mdtDungeonFile in input", t => {
  const f = fixture(t);
  const html = render(f);
  assert.match(html, /persisted-report/);
  assert.ok(html.includes(f.summary.routeKey));
  assert.equal(tableRows(html).length, 2);
  assert.match(tableRows(html)[0], /1\+2/);
  assert.match(tableRows(html)[0], /0:10–0:40/);
  assert.match(tableRows(html)[0], /Fixture guard/);
  assert.match(tableRows(html)[0], /<td class="num">10/);
  assert.match(tableRows(html)[0], /<td class="num">8:2<\/td>/);
  assert.match(tableRows(html)[1], /1:00–2:00/);
  assert.match(tableRows(html)[1], /<td class="num">1:9<\/td>/);
  assert.match(html, /<th>技能配比<\/th>/);
  assert.equal((html.match(/data-copy="/g) || []).length, f.summary.lines.length + 2);
  for (const line of [...f.summary.lines, f.summary.packLine, f.summary.ratioPackLine]) assert.ok(html.includes(line));
  assert.match(html, new RegExp(`data-copy="${f.summary.ratioPackLine}"[^>]*>复制配比整包<`));
  assert.match(html, /<textarea id="route" readonly>!~MDT2~/);
  assert.match(html, /data-copy-target="route"/);
  assert.match(html, /id="copyAll"/);
  assert.doesNotMatch(html, /死亡簇|最近簇|空窗接战|插件已部署|实战那一波没开/);
});

test("ignores contradictory input metadata, casts, route and WCL evidence", t => {
  const f = fixture(t, d => {
    d.input.meta = { report: "DO-NOT-RENDER", dungeon: "DO-NOT-RENDER", key: 99 };
    d.input.routeString = "not an MDT string";
    d.input.castEvents = [{ skill: "pot", t: 9999 }];
    d.input.rotationCastEvents = [{ type: "cast", spellId: 61882, t: 9999 }];
    d.input.rotationUsage = [{ elementalBlast: 0, earthquake: 99 }];
    d.input.ratioPackLine = "DO-NOT-RENDER";
    d.input.deathEvents = [{ timestamp: 9999000, gameId: 1001 }];
    d.input.wclWindows = [[9990, 9999]];
    d.input.wclDeathCounts = [900];
    d.input.combatSegments = [{ start: 9990, end: 9999 }];
    d.input.bossEncounters = [{ pull: 1, start: 9990, end: 9999 }];
  });
  const html = render(f);
  assert.match(html, /persisted-report/);
  assert.doesNotMatch(html, /DO-NOT-RENDER|9999/);
  assert.equal(tableRows(html).length, 2);
  assert.match(tableRows(html)[0], /<td class="num">8:2<\/td>/);
  assert.match(html, /0:48 嗜血 → 计入第 2 波/);
});

test("honors persisted pull overrides instead of reassigning casts from visual time bounds", t => {
  const f = fixture(t, d => {
    d.summary.castEvents[0].pull = 3;
    d.summary.castAssignments[0] = 1;
    d.summary.waveUsage[0].asc = 0;
    d.summary.waveUsage[1].asc = 2;
    d.summary.lines = specLines(d.summary.waveUsage, d.summary.routeKey);
    d.summary.packLine = buildPlanPackLine(d.summary.waveUsage, d.summary.routeKey);
  });
  const html = render(f);
  assert.match(html, /0:08 升腾 → 计入第 2 波/);
  assert.match(tableRows(html)[0], /class="num asc"><i>—<\/i>/);
  assert.match(tableRows(html)[1], /class="num asc"><b>2<\/b>/);
});

test("draws one actual-bound bar per wave and recorded deaths as individual dots", t => {
  const html = render(fixture(t));
  assert.equal((html.match(/class="wave-bar"/g) || []).length, 2);
  assert.match(html, /<rect class="wave-bar"[^>]*data-start="60"[^>]*data-end="120"/);
  assert.equal((html.match(/<circle class="death-event"/g) || []).length, 3);
  for (const time of [20, 31, 65]) assert.match(html, new RegExp(`<circle class="death-event"[^>]*data-time="${time}"`));
  assert.equal((html.match(/<circle class="cast-event"/g) || []).length, 4);
  assert.match(html, /技能计入区间 0:45–2:20/);
  assert.match(html, /未归属施法 <b>1<\/b>/);
  assert.match(html, /未归属死亡 <b>1<\/b>/);
  assert.match(html, /2:25 药水 → 未归属/);
  assert.match(html, /1:05 死亡 → 未归属/);
  assert.match(html, /Fixture warning: missing pull evidence/);
  assert.doesNotMatch(html, /第 0 波|第 -1 波/);
});

test("Boss-entry wave and burst-reset explanation do not depend on a Boss death", t => {
  const html = render(fixture(t, d => { d.summary.deaths = []; }));
  assert.equal(tableRows(html).length, 2);
  assert.match(tableRows(html)[1], /boss-entry/);
  assert.match(tableRows(html)[1], /Boss 进场 1:00/);
  assert.match(tableRows(html)[1], /首次升腾 1:15/);
  assert.match(tableRows(html)[1], /<td class="num">0<\/td>/);
  assert.match(html, /Boss 进场.*重置/);
  assert.match(html, /已确认.*接战/);
  assert.equal((html.match(/class="wave-bar"/g) || []).length, 2);
  assert.equal((html.match(/class="death-event"/g) || []).length, 0);
});

test("no timing, casts or deaths still renders all rows and empty-plan copy controls", t => {
  const f = fixture(t, d => {
    d.summary.waves.forEach(w => {
      Object.assign(w, { start: null, end: null, castStart: null, castEnd: null, reason: "original" });
      delete w.bossStart;
      delete w.firstBossAscendance;
    });
    d.summary.castEvents = [];
    d.summary.castAssignments = [];
    d.summary.rotationCastEvents = [];
    d.summary.rotationAssignments = [];
    d.summary.rotationUsage = [{ elementalBlast: 0, earthquake: 0 }, { elementalBlast: 0, earthquake: 0 }];
    d.summary.ratioPackLine = buildRatioPackLine(d.summary.rotationUsage, d.summary.routeKey);
    d.summary.deaths = [];
    d.summary.waveUsage = [{ lust: 0, asc: 0, pot: 0 }, { lust: 0, asc: 0, pot: 0 }];
    d.summary.lines = [];
    d.summary.packLine = buildPlanPackLine(d.summary.waveUsage, d.summary.routeKey);
    d.summary.warnings = [];
  });
  const html = render(f);
  assert.equal(tableRows(html).length, 2);
  for (const row of tableRows(html)) {
    assert.match(row, /未确认–未确认/);
    assert.match(row, /<td class="num"><i>—<\/i><\/td>\s*<\/tr>/);
  }
  assert.equal((html.match(/class="wave-bar"/g) || []).length, 2);
  assert.match(html, /暂无已确认时间记录/);
  assert.doesNotMatch(html, /0:00/);
  assert.equal((html.match(/data-copy="/g) || []).length, 2);
  assert.match(html, /复制全部 0 行/);
  assert.match(html, /无警告/);
});

test("partially missing times remain unconfirmed instead of becoming zero", t => {
  const html = render(fixture(t, d => {
    d.summary.waves[0].start = null;
    d.summary.waves[1].end = null;
    d.summary.waves[1].firstBossAscendance = null;
  }));
  assert.match(tableRows(html)[0], /未确认–0:40/);
  assert.match(tableRows(html)[1], /1:00–未确认/);
  assert.match(tableRows(html)[1], /技能计入区间 0:45–2:20/);
  assert.match(tableRows(html)[1], /首次升腾 未确认/);
});

test("fight usage is manual while final groups and persisted cast assignments stay unchanged", t => {
  const f = fixture(t, d => {
    d.summary.granularity = "fight";
    d.summary.waveUsage[0] = { lust: 3, asc: 4, pot: 2 };
    d.summary.lines = specLines(d.summary.waveUsage, d.summary.routeKey);
    d.summary.packLine = buildPlanPackLine(d.summary.waveUsage, d.summary.routeKey);
    d.input.usage = [{ lust: 99, asc: 99, pot: 99 }];
  });
  const html = render(f);
  assert.match(html, /fight.*人工/);
  assert.equal(tableRows(html).length, 2);
  assert.match(tableRows(html)[0], /1\+2/);
  assert.match(tableRows(html)[0], /class="num lust"><b>3<\/b>/);
  assert.match(tableRows(html)[0], /class="num asc"><b>4<\/b>/);
  assert.match(tableRows(html)[0], /class="num pot"><b>2<\/b>/);
  assert.match(html, /0:48 嗜血 → 计入第 2 波/);
});

test("rejects a summary routeKey that does not match the encoded route", t => {
  expectRejected(t, d => { d.summary.routeKey = "ffffffff"; }, /report:.*routeKey.*mismatch/i);
});

test("rejects a different encoded route even with the same number of waves", t => {
  expectRejected(t, d => { d.preset.value.pulls[0][1].push(3); }, /report:.*routeKey.*mismatch/i);
});

test("rejects encoded pull-count mismatch independently of routeKey", t => {
  expectRejected(t, d => {
    d.preset.value.pulls.push({ 1: [3] });
    d.summary.routeKey = computeRouteKey(d.preset.value.pulls);
  }, /report:.*pull count.*mismatch/i);
});

test("rejects groups differing from persisted wave pulls", t => {
  expectRejected(t, d => { d.summary.groups = [[1], [2, 3]]; }, /report:.*groups.*waves.*mismatch/i);
});

test("rejects duplicated original pulls even if groups and waves agree", t => {
  expectRejected(t, d => {
    d.summary.groups[1] = [2, 3];
    d.summary.waves[1].pulls = [2, 3];
  }, /report:.*groups.*pull/i);
});

test("rejects waveUsage length inconsistent with final groups", t => {
  expectRejected(t, d => { d.summary.waveUsage.pop(); }, /report:.*waveUsage.*mismatch/i);
});

test("rejects castEvents and castAssignments pairing mismatch", t => {
  expectRejected(t, d => { d.summary.castAssignments.pop(); }, /report:.*castAssignments.*mismatch/i);
});

test("rejects non-array rotation summary fields", t => {
  for (const field of ["rotationCastEvents", "rotationAssignments", "rotationUsage"]) {
    expectRejected(t, d => { d.summary[field] = {}; }, new RegExp(`report:.*${field}.*array`, "i"));
  }
});

test("rejects rotationUsage length inconsistent with final groups", t => {
  expectRejected(t, d => { d.summary.rotationUsage.pop(); }, /report:.*rotationUsage.*groups.*length.*mismatch/i);
});

test("rejects rotationCastEvents and rotationAssignments pairing mismatch", t => {
  expectRejected(t, d => { d.summary.rotationAssignments.pop(); }, /report:.*rotationAssignments.*rotationCastEvents.*length.*mismatch/i);
});

test("rejects begincast, unknown rotation spellId and invalid time", t => {
  expectRejected(t, d => { d.summary.rotationCastEvents[0].type = "begincast"; }, /report:.*invalid rotation event/i);
  expectRejected(t, d => { d.summary.rotationCastEvents[0].spellId = 999999; }, /report:.*invalid rotation event/i);
  expectRejected(t, d => { d.summary.rotationCastEvents[0].t = Infinity; }, /report:.*invalid rotation event/i);
});

test("rejects invalid rotation usage counts", t => {
  expectRejected(t, d => { d.summary.rotationUsage[0].elementalBlast = -1; }, /report:.*rotationUsage.*mismatch/i);
  expectRejected(t, d => { d.summary.rotationUsage[0].earthquake = 1.5; }, /report:.*rotationUsage.*mismatch/i);
  expectRejected(t, d => { delete d.summary.rotationUsage[0].elementalBlast; }, /report:.*rotationUsage.*mismatch/i);
});

test("rejects invalid or unassigned rotation assignments", t => {
  expectRejected(t, d => { d.summary.rotationAssignments[0] = -2; }, /report:.*rotationAssignments.*mismatch/i);
  expectRejected(t, d => { d.summary.rotationAssignments[0] = 2; }, /report:.*rotationAssignments.*mismatch/i);
  expectRejected(t, d => { d.summary.rotationAssignments[0] = -1; }, /report:.*rotationAssignments.*mismatch|unassigned rotation cast/i);
});

test("rejects a valid-looking but tampered rotation assignment", t => {
  expectRejected(t, d => { d.summary.rotationAssignments[0] = 1; }, /report:.*rotationAssignments.*mismatch/i);
});

test("rejects a rotation cast that both recomputation and summary leave unassigned", t => {
  expectRejected(t, d => {
    d.summary.rotationCastEvents[0].t = 200;
    d.summary.rotationAssignments[0] = -1;
  }, /report:.*unassigned rotation cast/i);
});

test("rejects cast assignments outside final groups", t => {
  expectRejected(t, d => { d.summary.castAssignments[0] = 2; }, /report:.*castAssignments.*wave/i);
});

test("rejects death assignments outside final groups", t => {
  expectRejected(t, d => { d.summary.deaths[0].wave = -1; }, /report:.*deaths.*wave/i);
});

test("rejects pack text differing from summary.packLine", t => {
  expectRejected(t, d => { d.packFile = d.summary.packLine.replace("1:a1", "1:a2"); }, /report:.*packLine.*mismatch/i);
});

test("rejects differing pack command whitespace instead of silently normalizing it", t => {
  expectRejected(t, d => { d.packFile = " " + d.summary.packLine; }, /report:.*packLine.*mismatch/i);
});

test("accepts the pack file's final CRLF without changing the copied command", t => {
  const f = fixture(t, d => { d.packFile = d.summary.packLine + "\r"; });
  const html = render(f);
  assert.ok(html.includes(`data-copy="${f.summary.packLine}"`));
});

test("rejects ratio pack text differing from summary.ratioPackLine", t => {
  expectRejected(t, d => { d.ratioPackFile = d.summary.ratioPackLine.replace("8.2", "7.3"); }, /report:.*ratioPackLine.*mismatch/i);
});

test("rejects tampered rotationUsage even when ratio command and file match it", t => {
  expectRejected(t, d => {
    d.summary.rotationUsage[0] = { elementalBlast: 7, earthquake: 3 };
    d.summary.ratioPackLine = buildRatioPackLine(d.summary.rotationUsage, d.summary.routeKey);
  }, /report:.*rotationUsage.*mismatch/i);
});

test("rejects extra ratio pack line endings instead of normalizing them", t => {
  expectRejected(t, d => { d.ratioPackFile = d.summary.ratioPackLine + "\n"; }, /report:.*ratioPackLine.*mismatch/i);
});

test("rejects a non-string summary.ratioPackLine", t => {
  expectRejected(t, d => { d.summary.ratioPackLine = []; }, /report:.*ratioPackLine.*mismatch/i);
});

test("accepts the ratio pack file's final CRLF without changing the copied command", t => {
  const f = fixture(t, d => { d.ratioPackFile = d.summary.ratioPackLine + "\r"; });
  const html = render(f);
  assert.ok(html.includes(`data-copy="${f.summary.ratioPackLine}">复制配比整包`));
});

test("escapes metadata, preset names, enemy names, reasons, warnings and copy payloads", t => {
  const hostile = '</script><img src=x onerror=alert(1)>&"\'\u2028\u2029';
  const enemy = "</span><img src=x onerror=alert(2)>&'";
  const f = fixture(t, d => {
    d.summary.meta = { report: hostile, dungeon: hostile, key: hostile };
    d.preset.text = hostile;
    d.enemyName = enemy;
    d.summary.waves[0].reason = hostile;
    d.summary.warnings = [hostile];
    d.summary.lines = [`/npt ${hostile}`, "literal &quot; must stay literal"];
    d.summary.packLine += " " + hostile;
  });
  const html = render(f);
  assert.equal((html.match(/<script>/g) || []).length, 1);
  assert.equal((html.match(/<\/script>/g) || []).length, 1);
  assert.doesNotMatch(html, /<img\b/);
  assert.ok(!html.includes(hostile));
  assert.match(html, /&lt;\/script&gt;&lt;img src=x onerror=alert\(1\)&gt;&amp;&quot;&#39;/);
  assert.match(html, /&lt;\/span&gt;&lt;img src=x onerror=alert\(2\)&gt;&amp;&#39;/);
  assert.match(html, /data-copy="literal &amp;quot; must stay literal"/);
  assert.match(html, /data-copy="\/npt &lt;\/script&gt;&lt;img/);
  assert.match(html, /data-copy="\/npt importratiopack [^"]*">复制配比整包<\/button>/);
  const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  assert.doesNotThrow(() => new vm.Script(script));
  assert.match(script, /\\u003c\/script>/);
  const copyArgument = script.match(/copyText\(("(?:[^"\\]|\\.)*"),this\)/)[1];
  assert.equal(vm.runInNewContext(copyArgument), f.summary.lines.join("\n"));
});

test("actual CLI output and report share the 3+4 / 5+6 split including the zero-use wave", t => {
  const evidence = require("./fixtures/confirmed-combat.json");
  const f = fixture(t, d => {
    d.preset = { text: "Confirmed integration", uid: "confirmed", value: { currentDungeonIdx: 1, pulls: Array.from({ length: 6 }, (_, i) => i === 5 ? { 2: [1] } : { 1: [i + 1] }) } };
    Object.assign(d.input, structuredClone(evidence), {
      routeString: encodeMdtString(d.preset),
      deathEvents: [50, 90, 145, 230, 350, 500].map((seconds, i) => ({ gameId: i === 5 ? 1002 : 1001, timestamp: seconds * 1000 })),
    });
  });
  const cli = spawnSync(process.execPath, [path.join(__dirname, "cli.js"), f.inputPath, f.outDir], { encoding: "utf8" });
  assert.equal(cli.status, 0, cli.stderr);
  const actual = JSON.parse(fs.readFileSync(path.join(f.outDir, "summary.json"), "utf8"));
  assert.deepEqual(actual.groups, [[1], [2], [3, 4], [5, 6]]);
  assert.deepEqual(actual.waveUsage.map(u => u.asc), [1, 0, 1, 2]);
  const html = render(f);
  const rows = tableRows(html);
  assert.equal(rows.length, 4);
  assert.match(rows[0], /<td class="num">5:5<\/td>/);
  assert.match(rows[1], /class="num asc"><i>—<\/i>/);
  assert.match(rows[1], /<td class="num">0:10<\/td>/);
  assert.match(rows[2], /3\+/);
  assert.match(rows[2], /class="num asc"><b>1<\/b>/);
  assert.match(rows[2], /<td class="num">5:5<\/td>/);
  assert.match(rows[3], /5\+/);
  assert.match(rows[3], /class="num asc"><b>2<\/b>/);
  assert.match(rows[3], /<td class="num">7:3<\/td>/);
  for (const line of [...actual.lines, actual.packLine, actual.ratioPackLine]) assert.ok(html.includes(line));
});

test("missing arguments exit with usage and status 2", () => {
  const result = spawnSync(process.execPath, [REPORT], { encoding: "utf8" });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /usage: node tools\/wclplan\/report\.js/);
});
