// 用法: node tools/wclplan/report.js <input.json> <out-dir>
// 读 cli.js 在 <out-dir> 写出的 summary.json / route.mdt.txt，加上 input.json 里的
// 死亡与 cast 事件，渲染一个自包含网页 <out-dir>/report.html：
//   时间轴（死亡簇 → 波次带 → cast 标记）/ 路线串与 plan 行（带复制按钮）/ 波次明细表。
// 换报告时改 input.json 即可重跑；页面只读产物，不联网。
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { decodeMdtString } = require("./mdtstring.js");
const { loadNpcIds, loadEnemyMeta, assignDeathsToPulls } = require("./align.js");
const { buildCombatWaveDetail, castWaves } = require("./waves.js");

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
  const packLine = fs.readFileSync(path.join(outDir, "importplan-pack.txt"), "utf8").trim();
  const luaText = fs.readFileSync(input.mdtDungeonFile, "utf8");

  // 敌人名字/兵力（副本 Lua 里 name 紧跟 id/count）
  const names = {};
  {
    const block = luaText.slice(luaText.indexOf("MDT.dungeonEnemies["));
    const re = /\[(\d+)\] = \{\s*\["name"\] = "([^"]*)",\s*\["id"\] = (\d+),\s*\["count"\] = (\d+)/g;
    let m;
    while ((m = re.exec(block)) !== null) names[Number(m[1])] = { name: m[2], count: Number(m[4]) };
  }
  const meta = loadEnemyMeta(luaText);

  const aligned = assignDeathsToPulls(decodeMdtString(input.routeString).value.pulls, loadNpcIds(luaText), input.deathEvents);
  const casts = input.castEvents || [];
  const detail = buildCombatWaveDetail({
    deathSeconds: aligned.deathSeconds,
    deathPulls: aligned.deathPulls,
    burstCasts: casts.filter((c) => c.skill !== "pot").map((c) => c.t),
    ascCasts: casts.filter((c) => c.skill === "asc").map((c) => c.t),
  });
  const waveOfCluster = [];
  detail.waves.forEach((w, i) => w.clusters.forEach((ci) => { waveOfCluster[ci] = i; }));
  // 与 cli 生成 plan 行时用的同一套归属（castWaves），保证页面与 importplan 一致
  const castWave = castWaves(casts, detail);

  const fmt = (s) => Math.floor(s / 60) + ":" + String(Math.floor(s % 60)).padStart(2, "0");

  const merged = decodeMdtString(routeText).value.pulls;
  const waves = summary.groups.map((group, i) => {
    const clusters = detail.waves[i].clusters.map((ci) => detail.clusters[ci]);
    const start = Math.min(...clusters.map((c) => c.start));
    const end = Math.max(...clusters.map((c) => c.end));
    const comp = [];
    let forces = 0;
    for (const [idx, clones] of Object.entries(merged[i])) {
      const n = Number(idx);
      if (!Number.isInteger(n) || !Array.isArray(clones)) continue;
      const count = meta[n] ? meta[n].count : 0;
      forces += count * clones.length;
      comp.push({ name: names[n] ? names[n].name : "idx" + n, n: clones.length, count, forces: count * clones.length });
    }
    comp.sort((a, b) => b.forces - a.forces || b.n - a.n);
    return {
      no: i + 1, group, start, end, forces, comp,
      usage: summary.waveUsage[i] || { lust: 0, asc: 0, pot: 0 },
      deaths: clusters.reduce((s, c) => s + c.deaths.length, 0),
      clusters: clusters.map((c) => ({ start: c.start, end: c.end, deaths: c.deaths.length })),
    };
  });
  const totalForces = waves.reduce((s, w) => s + w.forces, 0);
  const totalDur = Math.max(...detail.clusters.map((c) => c.end)) + 30;

  // ---- 时间轴 SVG ----
  const W = 1180, PAD = 46, PLOT = W - PAD - 18;
  const x = (t) => PAD + (t / totalDur) * PLOT;
  const hue = (i) => (i * 360) / waves.length;
  const svg = [];
  svg.push(`<svg viewBox="0 0 ${W} 250" xmlns="http://www.w3.org/2000/svg" font-family="Segoe UI,Microsoft YaHei,sans-serif">`);
  for (let t = 0; t <= totalDur; t += 120) {
    svg.push(`<line x1="${x(t).toFixed(1)}" y1="30" x2="${x(t).toFixed(1)}" y2="212" stroke="#ffffff10"/>`);
    svg.push(`<text x="${x(t).toFixed(1)}" y="230" fill="#8b93a7" font-size="11" text-anchor="middle">${fmt(t)}</text>`);
  }
  const CAST_COLOR = { asc: "#c084fc", lust: "#fb7185", pot: "#4ade80" };
  const CAST_LABEL = { asc: "升腾", lust: "嗜血", pot: "药水" };
  casts.forEach((c, ci) => {
    const wi = castWave[ci];
    svg.push(`<circle cx="${x(c.t).toFixed(1)}" cy="20" r="5" fill="${CAST_COLOR[c.skill]}" stroke="#0b0e14" stroke-width="1.5"><title>${fmt(c.t)} ${CAST_LABEL[c.skill]} → 计入第 ${wi + 1} 波</title></circle>`);
  });
  waves.forEach((w, i) => {
    const x1 = x(w.start), x2 = Math.max(x(w.end), x1 + 3);
    svg.push(`<rect x="${x1.toFixed(1)}" y="44" width="${(x2 - x1).toFixed(1)}" height="30" rx="5" fill="hsl(${hue(i)} 70% 55% / .28)" stroke="hsl(${hue(i)} 80% 65% / .9)"><title>第 ${w.no} 波 ${fmt(w.start)}–${fmt(w.end)}｜原 pull ${w.group.join("+")}｜兵力 ${w.forces}</title></rect>`);
    if (x2 - x1 > 26) svg.push(`<text x="${((x1 + x2) / 2).toFixed(1)}" y="64" fill="hsl(${hue(i)} 90% 78%)" font-size="12" font-weight="600" text-anchor="middle">${w.no}</text>`);
  });
  detail.clusters.forEach((c, ci) => {
    const wi = waveOfCluster[ci];
    const x1 = x(c.start), x2 = Math.max(x(c.end), x1 + 2.5);
    svg.push(`<rect x="${x1.toFixed(1)}" y="92" width="${(x2 - x1).toFixed(1)}" height="16" rx="3" fill="hsl(${hue(wi)} 65% 50% / .85)"><title>簇 ${ci + 1} ${fmt(c.start)}–${fmt(c.end)}｜${c.deaths.length} 只死亡｜归第 ${wi + 1} 波</title></rect>`);
    if (x2 - x1 > 18) svg.push(`<text x="${((x1 + x2) / 2).toFixed(1)}" y="104" fill="#0b0e14" font-size="10" font-weight="700" text-anchor="middle">${c.deaths.length}</text>`);
  });
  waves.forEach((w, i) => {
    if (w.clusters.length < 2) return;
    const x1 = x(w.clusters[0].start), x2 = x(w.clusters[w.clusters.length - 1].end);
    svg.push(`<path d="M${x1.toFixed(1)} 118 L${x1.toFixed(1)} 126 L${x2.toFixed(1)} 126 L${x2.toFixed(1)} 118" fill="none" stroke="hsl(${hue(i)} 80% 65% / .8)" stroke-width="1.5"/>`);
    svg.push(`<text x="${((x1 + x2) / 2).toFixed(1)}" y="142" fill="hsl(${hue(i)} 85% 75%)" font-size="11" text-anchor="middle">合并（空窗里有战中爆发）</text>`);
  });
  svg.push(`<g font-size="11" fill="#8b93a7">
<circle cx="${PAD}" cy="176" r="5" fill="${CAST_COLOR.asc}"/><text x="${PAD + 10}" y="180">升腾</text>
<circle cx="${PAD + 58}" cy="176" r="5" fill="${CAST_COLOR.lust}"/><text x="${PAD + 68}" y="180">嗜血</text>
<circle cx="${PAD + 116}" cy="176" r="5" fill="${CAST_COLOR.pot}"/><text x="${PAD + 126}" y="180">药水</text>
<rect x="${PAD + 176}" y="171" width="22" height="10" rx="3" fill="#ffffff30"/><text x="${PAD + 204}" y="180">波次</text>
<rect x="${PAD + 246}" y="171" width="22" height="10" rx="3" fill="#ffffff80"/><text x="${PAD + 274}" y="180">死亡簇（数字=死亡只数）</text>
</g>`);
  svg.push(`<text x="${PAD}" y="205" fill="#5d6577" font-size="11">时间轴为钥匙内相对时间；升腾/嗜血归属波次是按规则推断（簇内→空窗接战→最近簇），不是日志里的精确归属。</text>`);
  svg.push("</svg>");

  // ---- 波次表 ----
  const rows = waves.map((w, i) => {
    const comp = w.comp.map((c) => c.count === 0
      ? `<span class="boss" title="count=0，不占兵力">${c.name} ★${c.n}</span>`
      : `<span title="单只兵力 ${c.count}">${c.name} ×${c.n}<em>${c.forces}</em></span>`).join("");
    const pct = totalForces > 0 ? ((w.forces / totalForces) * 100).toFixed(1) : "0.0";
    const cell = (n) => (n > 0 ? `<b>${n}</b>` : `<i>—</i>`);
    return `<tr>
    <td class="wno" style="--h:${hue(i)}">${w.no}</td>
    <td class="mono">${fmt(w.start)}–${fmt(w.end)}</td>
    <td class="mono dim">${w.group.join("+")}</td>
    <td class="num">${w.forces}<span class="pct">${pct}%</span></td>
    <td class="comp">${comp}</td>
    <td class="num">${w.deaths}</td>
    <td class="num lust">${cell(w.usage.lust)}</td>
    <td class="num asc">${cell(w.usage.asc)}</td>
    <td class="num pot">${cell(w.usage.pot)}</td>
  </tr>`;
  }).join("\n");

  const lineRows = summary.lines.map((l) => `<div class="line"><code>${l}</code><button data-copy="${l.replace(/"/g, "&quot;")}">复制</button></div>`).join("\n");
  const preset = decodeMdtString(routeText);

  const html = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>NPT 产物 · ${input.meta ? input.meta.dungeon : ""} +${input.meta ? input.meta.key : ""}</title>
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
<div class="sub">报告 ${input.meta ? input.meta.report : ""}｜${input.meta ? input.meta.dungeon : ""} +${input.meta ? input.meta.key : ""}｜切波粒度 <b>${summary.granularity}</b>（死亡时间簇）</div>
<div class="chips">
  <span class="chip">路线串原始 pull <b>${decodeMdtString(input.routeString).value.pulls.length}</b></span>
  <span class="chip">合并后波次 <b>${waves.length}</b></span>
  <span class="chip">routeKey <b>${summary.routeKey}</b></span>
  <span class="chip">总兵力 <b>${totalForces}</b></span>
  <span class="chip">死亡簇 <b>${detail.clusters.length}</b></span>
  <span class="chip">plan 行 <b>${summary.lines.length}</b></span>
</div>

<h2>时间轴</h2>
<div class="card">${svg.join("")}</div>

<h2>① MDT 路线串（导入：MDT → Import）</h2>
<div class="card">
  <textarea id="route" readonly>${routeText}</textarea>
  <div class="bar"><button data-copy-target="route">复制路线串</button><span class="note">${routeText.length} 字符｜预设名「${preset.text}」</span></div>
</div>

<h2>② NPT 冷却计划（需先选中上面导入的预设）</h2>
<div class="card">
  <div class="line"><code>${packLine}</code><button data-copy="${packLine.replace(/"/g, "&quot;")}">复制整包</button></div>
  <div class="note" style="margin:2px 0 10px">整包命令：聊天框粘这一行回车，一次导完全部 ${summary.lines.length} 波（应回 imported cooldown plan for N pulls）。下面是逐行备用——WoW 聊天框是单行输入框，只能一条一条粘。</div>
  ${lineRows}
  <div class="bar"><button id="copyAll">复制全部 ${summary.lines.length} 行</button><span class="note">没有行的波 = 实战那一波没开嗜血/升腾/药水。routeKey 对不上插件会整批拒写。</span></div>
</div>

<h2>③ 波次明细</h2>
<div class="card" style="padding:0;overflow:auto">
<table>
<thead><tr><th>波</th><th>时间</th><th>原 pull</th><th>兵力</th><th>敌人组成</th><th>死亡</th><th>嗜血</th><th>升腾</th><th>药水</th></tr></thead>
<tbody>
${rows}
</tbody></table>
</div>
<div class="note">★ = count=0 的 boss/召唤物，不占兵力。「时间」是该波死亡簇的起止（钥匙内相对时间）；「死亡」是归到该波的死亡事件数。兵力占比按 MDT count 值累加。</div>

<h2>④ 游戏内验证步骤</h2>
<div class="card"><ol>
<li>插件已部署，进游戏先 <code>/reload</code></li>
<li>MDT → Import → 粘贴 ① 的路线串，导入后<b>选中这个预设</b></li>
<li>聊天框粘贴 ② 的整包行回车（应回 <code>imported cooldown plan for N pulls</code>）；要逐行核对就粘备用的 ${summary.lines.length} 条（每条回一行 imported cooldown plan for pull N）</li>
<li>开钥匙后 <code>/npt start</code>，用 <code>/npt alert</code> 核对每波接战时播报的嗜血/升腾计划与 ③ 表一致；主城里 <code>/npt start</code> 会自动跟最后一次导入计划的这条路线（改 MDT 选中后需 <code>/npt stop</code> 再 start）</li>
</ol></div>

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
document.getElementById("copyAll").addEventListener("click",function(){copyText(${JSON.stringify(summary.lines.join("\n"))},this)});
</script>
</body></html>
`;

  fs.writeFileSync(path.join(outDir, "report.html"), html);
  console.log("wrote " + path.join(outDir, "report.html").replace(/\\/g, "/"));
  waves.forEach((w) => console.log(`  波${w.no} ${fmt(w.start)}-${fmt(w.end)} pulls[${w.group.join("+")}] 兵力${w.forces} 死亡${w.deaths} 嗜血${w.usage.lust} 升腾${w.usage.asc} 药水${w.usage.pot}`));
}

main();
