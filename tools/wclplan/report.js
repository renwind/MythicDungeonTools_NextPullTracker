// 用法: node tools/wclplan/report.js <input.json> <out-dir>
// 只渲染 CLI 已配对的 summary.json / route.mdt.txt / importplan-pack.txt / importratiopack.txt。
// input.json 仅提供 mdtDungeonFile（敌人名字/兵力）；报告不重新推断分组或事件归属。
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { decodeMdtString } = require("./mdtstring.js");
const { computeRouteKey } = require("./plan.js");
const { assignRotationEvents, summarizeRotation, buildRatioPackLine } = require("./rotation.js");

const CAST_COLOR = { asc: "#c084fc", lust: "#fb7185", pot: "#4ade80" };
const CAST_LABEL = { asc: "升腾", lust: "嗜血", pot: "药水" };
const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, c => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
})[c]);
const scriptJson = value => JSON.stringify(value).replace(/</g, "\\u003c").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
const fmt = seconds => {
  if (!Number.isFinite(seconds)) return "未确认";
  const s = Math.floor(Math.abs(seconds));
  return (seconds < 0 ? "-" : "") + Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
};

function validateSummary(summary, preset, packText, ratioPackText) {
  const fail = message => { throw new Error("report: " + message); };
  for (const field of ["groups", "waves", "waveUsage", "castEvents", "castAssignments", "rotationCastEvents", "rotationAssignments", "rotationUsage", "deaths", "warnings", "lines"]) {
    if (!Array.isArray(summary?.[field])) fail("summary." + field + " must be an array");
  }
  if (JSON.stringify(summary.groups) !== JSON.stringify(summary.waves.map(w => w?.pulls))) {
    fail("groups / waves pulls mismatch");
  }
  const seen = new Set();
  for (const group of summary.groups) {
    if (!Array.isArray(group) || group.length === 0) fail("groups must contain nonempty original pull arrays");
    for (const pull of group) {
      if (!Number.isInteger(pull) || pull < 1 || seen.has(pull)) fail("groups contain invalid or duplicate original pulls");
      seen.add(pull);
    }
  }
  const pulls = preset?.value?.pulls;
  if (!Array.isArray(pulls) || pulls.length !== summary.groups.length) fail("encoded route pull count / groups mismatch");
  if (computeRouteKey(pulls) !== summary.routeKey) fail("encoded route routeKey / summary mismatch");
  // Only the text files' terminal line ending is optional; preserve each command verbatim.
  if (typeof summary.packLine !== "string" || packText.replace(/\r?\n$/, "") !== summary.packLine) fail("packLine / importplan-pack.txt mismatch");
  if (summary.waveUsage.length !== summary.groups.length) fail("waveUsage / groups length mismatch");
  if (summary.rotationUsage.length !== summary.groups.length) fail("rotationUsage / groups length mismatch");
  if (summary.castAssignments.length !== summary.castEvents.length) fail("castAssignments / castEvents length mismatch");
  if (summary.rotationAssignments.length !== summary.rotationCastEvents.length) fail("rotationAssignments / rotationCastEvents length mismatch");
  const validWave = wave => Number.isInteger(wave) && wave >= 0 && wave < summary.waves.length;
  const validTime = time => time === null || Number.isFinite(time);
  for (const w of summary.waves) {
    if (["start", "end", "castStart", "castEnd"].some(key => !validTime(w[key])) ||
        ["bossStart", "firstBossAscendance"].some(key => w[key] !== undefined && !validTime(w[key])) ||
        typeof w.reason !== "string") fail("waves must contain finite or null times and a reason");
    if ((w.start !== null && w.end !== null && w.end < w.start) ||
        (w.castStart !== null && w.castEnd !== null && w.castEnd < w.castStart)) fail("waves contain reversed time bounds");
  }
  for (const usage of summary.waveUsage) {
    if (!usage || Object.keys(CAST_LABEL).some(skill => !Number.isInteger(usage[skill] ?? 0) || (usage[skill] ?? 0) < 0)) {
      fail("waveUsage must contain nonnegative integer counts");
    }
  }
  for (const cast of summary.castEvents) {
    if (!cast || !Object.hasOwn(CAST_LABEL, cast.skill) || !Number.isFinite(cast.t)) fail("castEvents contain invalid skill or time");
  }
  for (const wave of summary.castAssignments) {
    if (wave !== -1 && !validWave(wave)) fail("castAssignments contain an invalid final wave index");
  }

  let expectedAssignments;
  try {
    expectedAssignments = assignRotationEvents(summary.rotationCastEvents, summary.waves);
  } catch (error) {
    fail(error.message);
  }
  if (expectedAssignments.some(wave => wave === -1)) fail("unassigned rotation cast");
  if (JSON.stringify(expectedAssignments) !== JSON.stringify(summary.rotationAssignments)) {
    fail("rotationAssignments / recomputed assignments mismatch");
  }

  let expectedUsage;
  try {
    expectedUsage = summarizeRotation(summary.waves.length, summary.rotationCastEvents, expectedAssignments);
  } catch (error) {
    fail(error.message);
  }
  if (JSON.stringify(expectedUsage) !== JSON.stringify(summary.rotationUsage)) {
    fail("rotationUsage / recomputed usage mismatch");
  }

  let expectedRatioPackLine;
  try {
    expectedRatioPackLine = buildRatioPackLine(summary.rotationUsage, summary.routeKey);
  } catch (error) {
    fail(error.message);
  }
  if (typeof summary.ratioPackLine !== "string" || summary.ratioPackLine !== expectedRatioPackLine) {
    fail("rotationUsage / ratioPackLine mismatch");
  }
  if (ratioPackText.replace(/\r?\n$/, "") !== expectedRatioPackLine) {
    fail("ratioPackLine / importratiopack.txt mismatch");
  }
  for (const death of summary.deaths) {
    if (!death || !Number.isFinite(death.t) || (death.wave !== null && !validWave(death.wave))) fail("deaths contain an invalid time or final wave index");
  }
  if ([...summary.lines, ...summary.warnings].some(text => typeof text !== "string")) fail("lines and warnings must contain strings");
}

function main() {
  const [inputPath, outDir] = process.argv.slice(2);
  if (!inputPath || !outDir) {
    console.error("usage: node tools/wclplan/report.js <input.json> <out-dir>");
    process.exitCode = 2;
    return;
  }
  const input = JSON.parse(fs.readFileSync(inputPath, "utf8"));
  const summary = JSON.parse(fs.readFileSync(path.join(outDir, "summary.json"), "utf8"));
  const routeText = fs.readFileSync(path.join(outDir, "route.mdt.txt"), "utf8").trim();
  const packText = fs.readFileSync(path.join(outDir, "importplan-pack.txt"), "utf8");
  const ratioPackText = fs.readFileSync(path.join(outDir, "importratiopack.txt"), "utf8");
  const preset = decodeMdtString(routeText);
  validateSummary(summary, preset, packText, ratioPackText);
  const packLine = summary.packLine;
  const ratioPackLine = summary.ratioPackLine;
  const meta = summary.meta || {};
  const luaText = fs.readFileSync(input.mdtDungeonFile, "utf8");

  // 敌人名字/兵力只用于已编码路线的组成展示，不参与分波。
  const names = {};
  const blockStart = luaText.indexOf("MDT.dungeonEnemies[");
  if (blockStart < 0) throw new Error("report: dungeonEnemies block not found");
  const re = /\[(\d+)\]\s*=\s*\{\s*\["name"\]\s*=\s*"((?:\\.|[^"\\])*)",\s*\["id"\]\s*=\s*\d+,\s*\["count"\]\s*=\s*(\d+)/g;
  let match;
  const block = luaText.slice(blockStart);
  while ((match = re.exec(block)) !== null) names[Number(match[1])] = { name: match[2], count: Number(match[3]) };

  const casts = summary.castEvents;
  const deathCounts = Array(summary.waves.length).fill(0);
  for (const death of summary.deaths) if (death.wave !== null) deathCounts[death.wave]++;
  const waves = summary.waves.map((wave, i) => {
    const comp = [];
    let forces = 0;
    for (const [idx, clones] of Object.entries(preset.value.pulls[i])) {
      const n = Number(idx);
      if (!Number.isInteger(n) || !Array.isArray(clones)) continue;
      const enemy = names[n] || { name: "idx" + n, count: 0 };
      forces += enemy.count * clones.length;
      comp.push({ name: enemy.name, n: clones.length, count: enemy.count, forces: enemy.count * clones.length });
    }
    comp.sort((a, b) => b.forces - a.forces || b.n - a.n);
    return {
      ...wave, no: i + 1, group: wave.pulls, forces, comp,
      usage: summary.waveUsage[i], rotationUsage: summary.rotationUsage[i], deaths: deathCounts[i],
    };
  });
  const totalForces = waves.reduce((s, w) => s + w.forces, 0);
  const originalPullCount = summary.groups.reduce((n, group) => n + group.length, 0);
  const unassignedCasts = summary.castAssignments.filter(w => w === -1).length;
  const unassignedDeaths = summary.deaths.filter(d => d.wave === null).length;
  const warnings = summary.warnings.length
    ? `<ul>${summary.warnings.map(w => `<li>${escapeHtml(w)}</li>`).join("")}</ul>`
    : `<div class="note">无警告</div>`;
  const usageNote = summary.granularity === "fight"
    ? "fight 粒度的使用次数来自人工计划（summary.waveUsage），不是施法次数统计；最终分组仍与 MDT/NPT 相同。"
    : "使用次数来自 summary.waveUsage；施法与死亡归属直接读取 summary，未归属事件不计入任何波。";

  // ---- 时间轴 SVG：实际波次边界与逐条事件，不从死亡或施法推断时间 ----
  const times = [...waves.flatMap(w => [w.start, w.end]), ...casts.map(c => c.t), ...summary.deaths.map(d => d.t)].filter(Number.isFinite);
  const axisStart = times.reduce((min, t) => Math.min(min, t), 0);
  const axisEnd = times.reduce((max, t) => Math.max(max, t), 0) + 30;
  const W = 1180, PAD = 46, PLOT = W - PAD - 18;
  const x = t => PAD + ((t - axisStart) / (axisEnd - axisStart)) * PLOT;
  const hue = i => (i * 360) / Math.max(1, waves.length);
  const svg = [];
  svg.push(`<svg viewBox="0 0 ${W} 250" xmlns="http://www.w3.org/2000/svg" font-family="Segoe UI,Microsoft YaHei,sans-serif">`);
  const step = Math.max(120, Math.ceil((axisEnd - axisStart) / 1200) * 120);
  if (times.length) {
    for (let t = Math.ceil(axisStart / step) * step; t <= axisEnd; t += step) {
      svg.push(`<line x1="${x(t).toFixed(1)}" y1="30" x2="${x(t).toFixed(1)}" y2="212" stroke="#ffffff10"/>`);
      svg.push(`<text x="${x(t).toFixed(1)}" y="230" fill="#8b93a7" font-size="11" text-anchor="middle">${fmt(t)}</text>`);
    }
  } else {
    svg.push(`<text x="${PAD}" y="28" fill="#8b93a7" font-size="12">暂无已确认时间记录</text>`);
  }
  casts.forEach((c, ci) => {
    const wi = summary.castAssignments[ci];
    const assigned = wi === -1 ? "未归属" : `计入第 ${wi + 1} 波`;
    svg.push(`<circle class="cast-event" data-time="${c.t}" data-wave="${wi === -1 ? "unassigned" : wi + 1}" cx="${x(c.t).toFixed(1)}" cy="20" r="5" fill="${CAST_COLOR[c.skill]}" stroke="#0b0e14" stroke-width="1.5"><title>${fmt(c.t)} ${CAST_LABEL[c.skill]} → ${assigned}</title></circle>`);
  });
  const untimed = waves.filter(w => w.start === null || w.end === null);
  let untimedIndex = 0;
  waves.forEach((w, i) => {
    const known = w.start !== null && w.end !== null;
    // 虚线条只在独立的「未确认」行按序排布，不把缺失时间伪装成零秒。
    const slot = PLOT / Math.max(1, untimed.length);
    const x1 = known ? x(w.start) : PAD + untimedIndex++ * slot;
    const x2 = known ? Math.max(x(w.end), x1 + 3) : x1 + Math.max(3, slot - 6);
    const y = known ? 44 : 118;
    svg.push(`<rect class="wave-bar" data-wave="${w.no}" data-start="${w.start ?? "未确认"}" data-end="${w.end ?? "未确认"}" x="${x1.toFixed(1)}" y="${y}" width="${(x2 - x1).toFixed(1)}" height="30" rx="5" ${known ? "" : 'stroke-dasharray="4 3"'} fill="hsl(${hue(i)} 70% 55% / .28)" stroke="hsl(${hue(i)} 80% 65% / .9)"><title>第 ${w.no} 波 ${fmt(w.start)}–${fmt(w.end)}｜原 pull ${w.group.join("+")}｜${escapeHtml(w.reason)}｜兵力 ${w.forces}</title></rect>`);
    if (x2 - x1 > 26) svg.push(`<text x="${((x1 + x2) / 2).toFixed(1)}" y="${y + 20}" fill="hsl(${hue(i)} 90% 78%)" font-size="12" font-weight="600" text-anchor="middle">${w.no}${known ? "" : " · 未确认"}</text>`);
  });
  summary.deaths.forEach(death => {
    const assigned = death.wave === null ? "未归属" : `计入第 ${death.wave + 1} 波`;
    const color = death.wave === null ? "#8b93a7" : `hsl(${hue(death.wave)} 80% 65%)`;
    svg.push(`<circle class="death-event" data-time="${death.t}" data-wave="${death.wave === null ? "unassigned" : death.wave + 1}" cx="${x(death.t).toFixed(1)}" cy="98" r="3" fill="${color}"><title>${fmt(death.t)} 死亡 → ${assigned}</title></circle>`);
  });
  svg.push(`<g font-size="11" fill="#8b93a7">
<circle cx="${PAD}" cy="176" r="5" fill="${CAST_COLOR.asc}"/><text x="${PAD + 10}" y="180">升腾</text>
<circle cx="${PAD + 58}" cy="176" r="5" fill="${CAST_COLOR.lust}"/><text x="${PAD + 68}" y="180">嗜血</text>
<circle cx="${PAD + 116}" cy="176" r="5" fill="${CAST_COLOR.pot}"/><text x="${PAD + 126}" y="180">药水</text>
<rect x="${PAD + 176}" y="171" width="22" height="10" rx="3" fill="#ffffff30"/><text x="${PAD + 204}" y="180">实际波次边界</text>
<circle cx="${PAD + 310}" cy="176" r="3" fill="#ffffff80"/><text x="${PAD + 322}" y="180">死亡事件（逐条记录时间）</text>
</g>`);
  svg.push(`<text x="${PAD}" y="205" fill="#8b93a7" font-size="11">时间为钥匙内相对时间；虚线条表示时间未确认，不对应横轴位置。所有波次与事件归属均来自 CLI summary。</text>`);
  svg.push("</svg>");

  // ---- 波次表 ----
  const rows = waves.map((w, i) => {
    const comp = w.comp.map(c => c.count === 0
      ? `<span class="boss" title="count=0，不占兵力">${escapeHtml(c.name)} ×${c.n}</span>`
      : `<span title="单只兵力 ${c.count}">${escapeHtml(c.name)} ×${c.n}<em>${c.forces}</em></span>`).join("");
    const pct = totalForces > 0 ? ((w.forces / totalForces) * 100).toFixed(1) : "0.0";
    const cell = n => n > 0 ? `<b>${n}</b>` : `<i>—</i>`;
    const rotationTotal = w.rotationUsage.elementalBlast + w.rotationUsage.earthquake;
    const elementalBlastTenths = rotationTotal === 0 ? 0 : Math.floor(w.rotationUsage.elementalBlast / rotationTotal * 10 + 0.5);
    const ratio = rotationTotal === 0 ? `<i>—</i>` : `${elementalBlastTenths}:${10 - elementalBlastTenths}`;
    const boss = [
      w.bossStart !== undefined ? `Boss 进场 ${fmt(w.bossStart)}` : "",
      w.firstBossAscendance !== undefined ? `首次升腾 ${fmt(w.firstBossAscendance)}` : "",
    ].filter(Boolean).join("｜");
    return `<tr>
    <td class="wno" style="--h:${hue(i)}">${w.no}</td>
    <td class="mono">${fmt(w.start)}–${fmt(w.end)}<div class="note">${escapeHtml(w.reason)}</div><div class="note">技能计入区间 ${fmt(w.castStart)}–${fmt(w.castEnd)}</div>${boss ? `<div class="note">${boss}</div>` : ""}</td>
    <td class="mono dim">${w.group.join("+")}</td>
    <td class="num">${w.forces}<span class="pct">${pct}%</span></td>
    <td class="comp">${comp}</td>
    <td class="num">${w.deaths}</td>
    <td class="num lust">${cell(w.usage.lust)}</td>
    <td class="num asc">${cell(w.usage.asc)}</td>
    <td class="num pot">${cell(w.usage.pot)}</td>
    <td class="num">${ratio}</td>
  </tr>`;
  }).join("\n");

  const lineRows = summary.lines.map(l => `<div class="line"><code>${escapeHtml(l)}</code><button data-copy="${escapeHtml(l)}">复制</button></div>`).join("\n");

  const html = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>NPT 产物 · ${escapeHtml(meta.dungeon)} +${escapeHtml(meta.key)}</title>
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;padding:28px 32px 60px;background:#0b0e14;color:#e6e9f0;font:14px/1.6 "Segoe UI","Microsoft YaHei",sans-serif}
h1{font-size:20px;margin:0 0 4px}
h2{font-size:15px;margin:34px 0 10px;color:#aab3c5;letter-spacing:.04em}
.sub{color:#8b93a7;font-size:13px}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin:14px 0 6px}
.chip{background:#161b26;border:1px solid #262d3d;border-radius:999px;padding:4px 12px;font-size:12px;color:#c3cadb}
.chip b{color:#7dd3fc;font-family:ui-monospace,Consolas,monospace}
.card{background:#121722;border:1px solid #232a3a;border-radius:10px;padding:14px 16px}
textarea{width:100%;height:112px;background:#0b0e14;color:#9fe8b6;border:1px solid #262d3d;border-radius:8px;padding:10px;font:12px/1.5 ui-monospace,Consolas,monospace;resize:vertical}
button{background:#1d2534;color:#cfe3ff;border:1px solid #2f3a52;border-radius:7px;padding:5px 12px;font-size:12px;cursor:pointer}
button:hover{background:#26314a}
button.ok{background:#14351f;border-color:#2c6b3f;color:#8ef0a8}
.bar{display:flex;gap:8px;align-items:center;margin-top:10px}
.line{display:flex;gap:10px;align-items:center;padding:5px 0;border-bottom:1px dashed #1e2534}
.line:last-child{border-bottom:0}
.line code{flex:1;font:12.5px/1.6 ui-monospace,Consolas,monospace;color:#f0d9a8;word-break:break-all}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{padding:7px 8px;border-bottom:1px solid #1e2534;text-align:left;vertical-align:top}
th{color:#8b93a7;font-weight:600;font-size:12px;background:#101520;position:sticky;top:0}
td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
td.mono,.mono{font-family:ui-monospace,Consolas,monospace;font-size:12px}
.dim{color:#6f7789}
.wno{font-weight:700;text-align:center;width:34px;color:hsl(var(--h) 85% 72%);border-left:3px solid hsl(var(--h) 75% 55%)}
.pct{display:block;color:#6f7789;font-size:11px}
.comp span{display:inline-block;background:#171d2a;border:1px solid #252d3f;border-radius:6px;padding:1px 7px;margin:2px 3px 2px 0;font-size:12px}
.comp span em{color:#7dd3fc;font-style:normal;margin-left:5px;font-size:11px}
.comp .boss{border-color:#4b3a63;background:#1d1830;color:#d9c6ff}
.lust b{color:#fb7185}.asc b{color:#c084fc}.pot b{color:#4ade80}
td i{color:#3f4657;font-style:normal}
.note{color:#6f7789;font-size:12px;margin-top:8px}
ol{margin:8px 0 0;padding-left:20px;color:#c3cadb}
ol code{color:#f0d9a8}
</style></head><body>
<h1>WCL → MDT 路线 + NPT 冷却计划</h1>
<div class="sub">报告 ${escapeHtml(meta.report)}｜${escapeHtml(meta.dungeon)} +${escapeHtml(meta.key)}｜使用次数粒度 <b>${escapeHtml(summary.granularity)}</b>（分组使用 CLI 最终结果）</div>
<div class="chips">
  <span class="chip">路线串原始 pull <b>${originalPullCount}</b></span>
  <span class="chip">合并后波次 <b>${waves.length}</b></span>
  <span class="chip">routeKey <b>${escapeHtml(summary.routeKey)}</b></span>
  <span class="chip">总兵力 <b>${totalForces}</b></span>
  <span class="chip">死亡记录 <b>${summary.deaths.length}</b></span>
  <span class="chip">未归属施法 <b>${unassignedCasts}</b></span>
  <span class="chip">未归属死亡 <b>${unassignedDeaths}</b></span>
  <span class="chip">plan 行 <b>${summary.lines.length}</b></span>
</div>

<h2>时间轴</h2>
<div class="card">${svg.join("")}</div>
<div class="note">展示 summary 中已确认的接战/脱战边界与 Boss 进场证据；Boss 进场重置爆发计数（boss-entry）。此外按用户规划规则拆分：含 Boss 波升腾上限 2、纯小怪波上限 1（asc-cap），单个 pull 超限则保留并在告警区标注。缺失边界标为「未确认」。</div>
<div class="note">波条是实际批次起止；技能计入区间可能与波条不同，详见下表。${usageNote}</div>
<h2>证据警告与未归属状态</h2>
<div class="card">${warnings}<div class="note">未归属施法 ${unassignedCasts} 条；未归属死亡 ${unassignedDeaths} 条。零死亡记录不代表没有战斗，零使用次数不代表实战未施放。</div></div>

<h2>① MDT 路线串（导入：MDT → Import）</h2>
<div class="card">
  <textarea id="route" readonly>${escapeHtml(routeText)}</textarea>
  <div class="bar"><button data-copy-target="route">复制路线串</button><span class="note">${routeText.length} 字符｜预设名「${escapeHtml(preset.text)}」</span></div>
</div>

<h2>② NPT 冷却计划（需先选中上面导入的预设）</h2>
<div class="card">
  <div class="line"><code>${escapeHtml(packLine)}</code><button data-copy="${escapeHtml(packLine)}">复制整包</button></div>
  <div class="line"><code>${escapeHtml(ratioPackLine)}</code><button data-copy="${escapeHtml(ratioPackLine)}">复制配比整包</button></div>
  <div class="note" style="margin:2px 0 10px">整包命令用于导入 summary 中的计划；共 ${summary.lines.length} 条逐波计划。下面是逐行备用——WoW 聊天框是单行输入框，只能一条一条粘。没有计划行时请勿将空整包视为已导入。</div>
  ${lineRows}
  <div class="bar"><button id="copyAll">复制全部 ${summary.lines.length} 行</button><span class="note">没有行的波只表示 summary 未提供该波的冷却计划。routeKey 对不上插件会整批拒写。</span></div>
</div>

<h2>③ 波次明细</h2>
<div class="card" style="padding:0;overflow:auto">
<table>
<thead><tr><th>波</th><th>时间</th><th>原 pull</th><th>兵力</th><th>敌人组成</th><th>死亡</th><th>嗜血</th><th>升腾</th><th>药水</th><th>技能配比</th></tr></thead>
<tbody>
${rows}
</tbody></table>
</div>
<div class="note">紫色敌人标签表示 count=0，不占兵力。「时间」是 summary 中的实际批次起止；「死亡」仅统计 summary 已归到该波的事件。兵力占比按 MDT count 值累加。</div>

<h2>④ 游戏内验证步骤（尚未验证）</h2>
<div class="card"><ol>
<li>确认已安装所需插件后，进游戏执行 <code>/reload</code></li>
<li>MDT → Import → 粘贴 ① 的路线串，导入后<b>选中这个预设</b></li>
<li>有计划行时，聊天框粘贴 ② 的整包行并检查实际返回；逐行备用共 ${summary.lines.length} 条，核对反馈中的 pull 编号</li>
<li>开钥匙后 <code>/npt start</code>，用 <code>/npt alert</code> 核对每波接战时播报的嗜血/升腾计划与 ③ 表一致；如切换路线，先确认 MDT 预设与导入计划对应</li>
</ol><div class="note">生成报告仅确认文件配对，不代表游戏内导入或实战验证成功。</div></div>

<script>
function flash(btn, text){const old=btn.textContent;btn.textContent=text||"已复制";btn.classList.add("ok");setTimeout(()=>{btn.textContent=old;btn.classList.remove("ok")},1200)}
function fallback(text,done){const ta=document.createElement("textarea");ta.value=text;ta.style.position="fixed";ta.style.opacity="0";document.body.appendChild(ta);ta.select();try{document.execCommand("copy");done()}catch(e){alert("复制失败，请手动选中")}document.body.removeChild(ta)}
function copyText(text, btn){
  const done=()=>flash(btn);
  if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(text).then(done,()=>fallback(text,done));return}
  fallback(text,done);
}
document.querySelectorAll("button[data-copy]").forEach(b=>b.addEventListener("click",()=>copyText(b.getAttribute("data-copy"),b)));
document.querySelectorAll("button[data-copy-target]").forEach(b=>b.addEventListener("click",()=>copyText(document.getElementById(b.getAttribute("data-copy-target")).value,b)));
document.getElementById("copyAll").addEventListener("click",function(){copyText(${scriptJson(summary.lines.join("\n"))},this)});
</script>
</body></html>
`;

  fs.writeFileSync(path.join(outDir, "report.html"), html);
  console.log("wrote " + path.join(outDir, "report.html").replace(/\\/g, "/"));
  waves.forEach((w) => console.log(`  波${w.no} ${fmt(w.start)}-${fmt(w.end)} pulls[${w.group.join("+")}] 兵力${w.forces} 死亡${w.deaths} 嗜血${w.usage.lust ?? 0} 升腾${w.usage.asc ?? 0} 药水${w.usage.pot ?? 0}`));
}

try {
  main();
} catch (err) {
  console.error(err.message);
  process.exitCode = 1;
}
