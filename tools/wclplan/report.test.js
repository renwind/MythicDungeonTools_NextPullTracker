const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const FIXTURE = path.join(__dirname, "fixtures/nalo22-C9pFgkRJwMvHB4KY.input.json");
const CLI = path.join(__dirname, "cli.js");
const REPORT = path.join(__dirname, "report.js");
// 波次表要读 MDT 安装目录里的副本敌人表，换机器时路径可能不在 -> 跳过而不是红。
const DUNGEON_FILE = JSON.parse(fs.readFileSync(FIXTURE, "utf8")).mdtDungeonFile;
const SKIP = fs.existsSync(DUNGEON_FILE) ? false : "MDT dungeon data not found: " + DUNGEON_FILE;

test("report.html 汇总 cli 产物：routeKey、11 行波次表、8 个 plan 行复制按钮", { skip: SKIP }, () => {
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), "wclplan-report-"));
  const cli = spawnSync(process.execPath, [CLI, FIXTURE, outDir, "--granularity=combat"], { encoding: "utf8" });
  assert.equal(cli.status, 0, cli.stderr);
  const rep = spawnSync(process.execPath, [REPORT, FIXTURE, outDir], { encoding: "utf8" });
  assert.equal(rep.status, 0, rep.stderr);

  const html = fs.readFileSync(path.join(outDir, "report.html"), "utf8");
  assert.match(html, /4624dc42/);
  assert.equal((html.match(/class="wno"/g) || []).length, 11);
  assert.equal((html.match(/data-copy="/g) || []).length, 9);
  assert.match(html, /!~MDT2~/);
  // 页面里的 plan 行与 importplan.txt 逐条一致
  const lines = fs.readFileSync(path.join(outDir, "importplan.txt"), "utf8").trim().split("\n");
  for (const line of lines) assert.ok(html.includes(line), "missing line: " + line);
  // 整包命令也在页面上（一个大复制按钮）
  const pack = fs.readFileSync(path.join(outDir, "importplan-pack.txt"), "utf8").trim();
  assert.ok(html.includes(pack), "missing pack line");
  fs.rmSync(outDir, { recursive: true, force: true });
});

test("缺参数退出码 2", () => {
  const res = spawnSync(process.execPath, [REPORT], { encoding: "utf8" });
  assert.equal(res.status, 2);
  assert.match(res.stderr, /usage: node tools\/wclplan\/report\.js/);
});
