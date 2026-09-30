const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { decodeMdtString } = require("./mdtstring.js");

const FIXTURE = path.join(__dirname, "fixtures/nalo22-C9pFgkRJwMvHB4KY.input.json");
const CLI = path.join(__dirname, "cli.js");
// 对齐要读 MDT 安装目录里的副本敌人表，换机器时路径可能不在 -> 跳过而不是红。
const DUNGEON_FILE = JSON.parse(fs.readFileSync(FIXTURE, "utf8")).mdtDungeonFile;
const SKIP = fs.existsSync(DUNGEON_FILE) ? false : "MDT dungeon data not found: " + DUNGEON_FILE;

function run(extraArgs) {
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), "wclplan-cli-"));
  const res = spawnSync(process.execPath, [CLI, FIXTURE, outDir, ...extraArgs], { encoding: "utf8" });
  const out = {
    dir: outDir,
    stdout: res.stdout,
    summary: JSON.parse(fs.readFileSync(path.join(outDir, "summary.json"), "utf8")),
    route: fs.readFileSync(path.join(outDir, "route.mdt.txt"), "utf8").trim(),
    lines: fs.readFileSync(path.join(outDir, "importplan.txt"), "utf8").trim().split("\n"),
  };
  fs.rmSync(outDir, { recursive: true, force: true });
  return out;
}

test("combat 粒度：+22 洞穴报告切 11 波、boss 补挂、8 条 plan 行", { skip: SKIP }, () => {
  const out = run(["--granularity=combat"]);
  assert.deepEqual(out.summary.groups, [
    [1], [2], [3, 4], [5, 6], [7], [8], [9], [10], [11], [12, 13, 14], [15, 16],
  ]);
  assert.equal(out.summary.routeKey, "4624dc42");
  assert.deepEqual(out.lines, [
    "/npt importplan 4624dc42 1 32182:spell:use;114050:spell:use;241308:item:use",
    "/npt importplan 4624dc42 3 114050:spell:use:2",
    "/npt importplan 4624dc42 4 114050:spell:use;241308:item:use",
    "/npt importplan 4624dc42 5 114050:spell:use",
    "/npt importplan 4624dc42 7 32182:spell:use;114050:spell:use",
    "/npt importplan 4624dc42 8 114050:spell:use:2;241308:item:use",
    "/npt importplan 4624dc42 10 114050:spell:use:2;241308:item:use",
    "/npt importplan 4624dc42 11 32182:spell:use;114050:spell:use:2;241308:item:use",
  ]);
  const preset = decodeMdtString(out.route);
  assert.equal(preset.value.pulls.length, 11);
  assert.equal(preset.value.currentPull, 1);
  // 最后一波含 boss 战 trio（25 Nalorakk / 26 Zul'jarra），否则被 NPT 零 forces 跳过
  const last = preset.value.pulls[10];
  assert.deepEqual(last["25"], [1]);
  assert.deepEqual(last["26"], [1]);
});

test("combat 粒度的 usage 由 castEvents 归属得出（第 8 波两次升腾来自跨簇合并）", { skip: SKIP }, () => {
  const out = run(["--granularity=combat"]);
  assert.deepEqual(out.summary.waveUsage[7], { lust: 0, asc: 2, pot: 1 });
  assert.deepEqual(out.summary.waveUsage[1], { lust: 0, asc: 0, pot: 0 });
});

test("fight 粒度（默认）：按 WCL fight 合波，8 波", { skip: SKIP }, () => {
  const out = run([]);
  assert.equal(out.summary.granularity, "fight");
  assert.deepEqual(out.summary.groups, [
    [1], [2], [3, 4], [5, 6], [7, 8, 9, 10], [11], [12, 13], [14, 15, 16],
  ]);
  assert.equal(decodeMdtString(out.route).value.pulls.length, 8);
  // usage 来自输入的人工读数（第 5 波合了 4 个原 pull，升腾 4 次），而非 castEvents
  assert.ok(out.lines.some((l) => / 5 32182:spell:use;114050:spell:use:4;241308:item:use$/.test(l)),
    "wave 5 line missing: " + out.lines.join(" | "));
});

test("未知 flag 报错退出码 2", () => {
  const res = spawnSync(process.execPath, [CLI, FIXTURE, "out", "--granularity=bogus"], { encoding: "utf8" });
  assert.equal(res.status, 2);
  assert.match(res.stderr, /must be fight or combat/);
});
