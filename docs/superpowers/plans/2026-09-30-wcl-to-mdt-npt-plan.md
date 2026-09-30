# WCL → MDT 路线 → NPT 冷却计划 管线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给一条 WCL 报告链接，产出可直接导入 MDT 的 `!~MDT2~` 路线字符串（按实战合波），以及配套的 NPT 冷却计划（每波嗜血/升腾/药水的使用次数），通过 `/npt importplan` 写入游戏内。

**Architecture:** Node 侧纯函数工具（`tools/wclplan/`）负责 MDT 字符串编解码、合波、plan 行生成；数据采集（WCL 每波窗口/每波 cast、Threechest 路线串）是 runbook 步骤，产出一个输入 JSON，工具不联网。Lua 侧新增纯逻辑模块 `Modules/ImportPlan.lua` + `Slash.lua` 一条命令，fingerprint 在游戏内用 `CooldownData.computePullFingerprint` 现算，不跨端传输。

**Tech Stack:** Node 24（`node --test`、`node:zlib`）、自写 CBOR 子集编解码、Lua 5.1（CI busted）/ fengari（本地 minibusted）。

**已验证的前提（2026-09-30 实测，勿重新调查）：**
- 本机 MDT v6.2.20 只认 `!~MDT2~` + `C_EncodingUtil.SerializeCBOR` → Deflate(raw) → Base64（installed `MythicDungeonTools/Modules/Transmission.lua:12-30`）。
- Threechest `POST https://threechest.io/api/wclRoute` body `{code, fightId}` 返回整局路线所需事件；其 Export MDT 串与本管线编码互通（端到端导入实测通过）。
- WCL 的 fight 列表 = 每波（Pull 1..N）+ 局内起止偏移；报告页公开可读。
- 合波判据（+22 纳洛拉克洞穴报告 C9pFgkRJwMvHB4KY 实测）：本波窗口内 0 死亡，或与下一波间隔 < 8s（该报告三组合并间隔 0s/1s/5s，正常波间隔 ≥10s）。
- ~~WCL V2 API 对本账户不可用~~ **已可用**（2026-09-30 用户建成 V2 client）：token 走 `https://www.warcraftlogs.com/oauth/token`（HTTP Basic = client_id:client_secret，`grant_type=client_credentials`），查询走 `/api/v2/client`。cn 站没有 `/api` 与 `/oauth`，必须用 www。凭据只走环境变量，**不入库、不写记忆**。`filterExpression` 的 token 不可靠（`sourceID=1` 返回 0 行），改用不带过滤的 events 再本地筛。

**输入 JSON 约定（`tools/wclplan/input.json`，runbook 产出）：**
```json
{
  "routeString": "!~MDT2~....",
  "mdtDungeonFile": "C:/Program Files (x86)/World of Warcraft/_retail_/Interface/AddOns/MythicDungeonTools/Midnight/DenOfNalorakk.lua",
  "deathEvents": [{ "gameId": 241814, "timestamp": 65468 }],
  "castEvents": [{ "skill": "asc", "t": 46.4 }],
  "debuffEvents": [{ "spellId": 57723, "timestamp": 46600, "targetId": 3 }],
  "usage": [{ "lust": 0, "asc": 1, "pot": 1 }],
  "wclWindows": [{ "start": 22, "end": 100 }],
  "wclDeathCounts": [13, 4, 0, 4],
  "lastWaveEnemies": [25, 26],
  "meta": { "dungeon": "nalo", "key": 22, "report": "C9pFgkRJwMvHB4KY" }
}
```
- `deathEvents` 来自 Threechest `/api/wclRoute` 的 deathEvents（timestamp 为整局相对毫秒）；窗口与死亡数由 Task 4 的对齐在**路线空间**推出。
- `castEvents`（Task 9，combat 粒度必需）：`skill` ∈ `asc|lust|pot`，`t` 为整局相对**秒**。combat 模式由它自动归属每波 usage；fight 模式仍读人工填的 `usage`。
- `debuffEvents`（喂 `lust.js` 的 `detectLustUses`）：WCL 原始事件形状 `{ abilityGameID, type: "applydebuff", timestamp, targetID }`，族 ID 57723=精疲力尽 / 80354=时空位移。**timestamp 是报告绝对毫秒**（本 fixture 里钥匙起点 = 2263350），与 `deathEvents`/`castEvents` 的整局相对时间不同轴，用前先减钥匙起点。
- `usage` 按**路线 pull 序**（长度 = 路线 pulls 数），runbook 把每波 cast 时间戳落进对齐后的路线 pull 窗口分桶。
- `wclWindows`/`wclDeathCounts` fight 粒度必需；combat 粒度不读。
- `lastWaveEnemies`（Task 9）：要补挂到最后一波的 MDT enemyIdx。Threechest 导出的路线不含 `count=0` 的 boss（本副本 25 Nalorakk / 26 Zul'jarra），少了它们最后一波会被 NPT 的零 forces 自动跳过；补谁属于人工判断（同副本还有 27 Echo of Nalorakk 等召唤物，按用户 2026-09-30 的决定不补），所以 cli 只列候选、不自动挂。

**CLI：** `node tools/wclplan/cli.js <input.json> <out-dir> [--granularity=fight|combat]`（默认 `fight`，见 Task 9）。

---

### Task 1: CBOR 子集编解码器

**Files:**
- Create: `tools/wclplan/cbor.js`
- Test: `tools/wclplan/cbor.test.js`

- [x] **Step 1: 写失败测试**

```js
// tools/wclplan/cbor.test.js
const test = require("node:test");
const assert = require("node:assert/strict");
const { encodeCbor, decodeCbor } = require("./cbor.js");

function roundTrip(value) {
  return decodeCbor(encodeCbor(value));
}

test("整数与负整数往返", () => {
  for (const n of [0, 1, 23, 24, 255, 256, 65535, 65536, 2 ** 31, -(2 ** 31)]) {
    assert.equal(roundTrip(n), n);
  }
});

test("字符串与布尔与 null 往返", () => {
  assert.equal(roundTrip("hello"), "hello");
  assert.equal(roundTrip(""), "");
  assert.equal(roundTrip(true), true);
  assert.equal(roundTrip(false), false);
  assert.equal(roundTrip(null), null);
});

test("非整数走 float64", () => {
  assert.equal(roundTrip(1.5), 1.5);
  assert.equal(roundTrip(-0.25), -0.25);
});

test("数组保持顺序、嵌套往返", () => {
  const v = [1, [2, 3], ["a"], []];
  assert.deepEqual(roundTrip(v), v);
});

test("对象数字键编码为 CBOR 整数键并还原为数字键对象", () => {
  const v = { 3: [1, 2], 10: [4], color: "ff0000" };
  const out = roundTrip(v);
  assert.deepEqual(out[3], [1, 2]);
  assert.deepEqual(out[10], [4]);
  assert.equal(out.color, "ff0000");
});

test("解码器拒绝截断输入", () => {
  const buf = encodeCbor({ a: [1, 2] });
  assert.throws(() => decodeCbor(buf.subarray(0, buf.length - 1)));
});
```

- [x] **Step 2: 跑测试确认失败**

Run: `node --test tools/wclplan/cbor.test.js`
Expected: FAIL，`Cannot find module './cbor.js'`

- [x] **Step 3: 最小实现**

```js
// tools/wclplan/cbor.js
// CBOR (RFC 8949) 子集：够 MDT preset 表用即可。
// 编码：整数(0/1)、文本(3)、字节(2)、数组(4)、map(5)、float64(7)、true/false/null。
// 对象键若为纯数字字符串则编码为 CBOR 整数键（MDT pulls 表就是整数键）。
"use strict";

function writeHead(parts, major, value) {
  const m = major << 5;
  if (value < 24) parts.push(m | value);
  else if (value < 2 ** 8) parts.push(m | 24, value);
  else if (value < 2 ** 16) parts.push(m | 25, value >> 8, value & 255);
  else if (value < 2 ** 32)
    parts.push(m | 26, (value >>> 24) & 255, (value >>> 16) & 255, (value >>> 8) & 255, value & 255);
  else {
    const hi = Math.floor(value / 2 ** 32);
    const lo = value % 2 ** 32;
    parts.push(m | 27, (hi >>> 24) & 255, (hi >>> 16) & 255, (hi >>> 8) & 255, hi & 255,
      (lo >>> 24) & 255, (lo >>> 16) & 255, (lo >>> 8) & 255, lo & 255);
  }
}

function encodeInto(value, parts) {
  if (value === null) { parts.push(0xf6); return; }
  if (value === true) { parts.push(0xf5); return; }
  if (value === false) { parts.push(0xf4); return; }
  if (value instanceof Uint8Array) {
    writeHead(parts, 2, value.length);
    for (const b of value) parts.push(b);
    return;
  }
  if (typeof value === "string") {
    const bytes = Buffer.from(value, "utf8");
    writeHead(parts, 3, bytes.length);
    for (const b of bytes) parts.push(b);
    return;
  }
  if (typeof value === "number") {
    if (Number.isInteger(value)) {
      if (value >= 0) writeHead(parts, 0, value);
      else writeHead(parts, 1, -1 - value);
    } else {
      const buf = Buffer.alloc(8);
      buf.writeDoubleBE(value, 0);
      parts.push(0xfb, ...buf);
    }
    return;
  }
  if (Array.isArray(value)) {
    writeHead(parts, 4, value.length);
    for (const item of value) encodeInto(item, parts);
    return;
  }
  if (typeof value === "object") {
    const keys = Object.keys(value);
    writeHead(parts, 5, keys.length);
    for (const key of keys) {
      if (/^\d+$/.test(key)) encodeInto(Number(key), parts);
      else encodeInto(key, parts);
      encodeInto(value[key], parts);
    }
    return;
  }
  throw new Error("cbor: unsupported type " + typeof value);
}

function encodeCbor(value) {
  const parts = [];
  encodeInto(value, parts);
  return Buffer.from(parts);
}

class Reader {
  constructor(buf) { this.buf = buf; this.pos = 0; }
  byte() {
    if (this.pos >= this.buf.length) throw new Error("cbor: truncated");
    return this.buf[this.pos++];
  }
  uint(additional) {
    if (additional < 24) return additional;
    const sizes = { 24: 1, 25: 2, 26: 4, 27: 8 };
    const size = sizes[additional];
    if (!size) throw new Error("cbor: bad additional " + additional);
    if (this.pos + size > this.buf.length) throw new Error("cbor: truncated");
    let value = 0;
    for (let i = 0; i < size; i++) value = value * 256 + this.buf[this.pos++];
    return value;
  }
  bytes(n) {
    if (this.pos + n > this.buf.length) throw new Error("cbor: truncated");
    const out = this.buf.subarray(this.pos, this.pos + n);
    this.pos += n;
    return out;
  }
}

function decodeItem(reader) {
  const initial = reader.byte();
  const major = initial >> 5;
  const additional = initial & 31;
  if (major === 0) return reader.uint(additional);
  if (major === 1) return -1 - reader.uint(additional);
  if (major === 2) return new Uint8Array(reader.bytes(reader.uint(additional)));
  if (major === 3) return Buffer.from(reader.bytes(reader.uint(additional))).toString("utf8");
  if (major === 4) {
    const n = reader.uint(additional);
    const out = [];
    for (let i = 0; i < n; i++) out.push(decodeItem(reader));
    return out;
  }
  if (major === 5) {
    const n = reader.uint(additional);
    const out = {};
    for (let i = 0; i < n; i++) {
      const key = decodeItem(reader);
      out[typeof key === "number" ? key : String(key)] = decodeItem(reader);
    }
    return out;
  }
  if (major === 7) {
    if (additional === 20) return false;
    if (additional === 21) return true;
    if (additional === 22) return null;
    if (additional === 27) {
      const b = reader.bytes(8);
      return Buffer.from(b).readDoubleBE(0);
    }
    throw new Error("cbor: unsupported simple " + additional);
  }
  throw new Error("cbor: unsupported major " + major);
}

function decodeCbor(buf) {
  const reader = new Reader(buf);
  const value = decodeItem(reader);
  if (reader.pos !== buf.length) throw new Error("cbor: trailing bytes");
  return value;
}

module.exports = { encodeCbor, decodeCbor };
```

- [x] **Step 4: 跑测试确认通过**

Run: `node --test tools/wclplan/cbor.test.js`
Expected: PASS（6 个 test 全绿）

- [x] **Step 5: 提交**

```bash
git add tools/wclplan/cbor.js tools/wclplan/cbor.test.js
git commit -m "feat: add CBOR subset codec for MDT route strings"
```

---

### Task 2: MDT 字符串编解码（前缀 + deflate-raw + base64）

**Files:**
- Create: `tools/wclplan/mdtstring.js`
- Test: `tools/wclplan/mdtstring.test.js`

- [x] **Step 1: 写失败测试**

```js
// tools/wclplan/mdtstring.test.js
const test = require("node:test");
const assert = require("node:assert/strict");
const { encodeMdtString, decodeMdtString } = require("./mdtstring.js");

test("往返保留 preset 结构", () => {
  const preset = {
    text: "wcl route",
    uid: "abc123",
    value: {
      currentDungeonIdx: 41,
      currentSublevel: 1,
      currentPull: 2,
      pulls: [{ 3: [1, 2], color: "ff0000" }, { 5: [1] }],
    },
  };
  assert.deepEqual(decodeMdtString(encodeMdtString(preset)), preset);
});

test("输出以 !~MDT2~ 开头且主体是标准 base64", () => {
  const s = encodeMdtString({ text: "x", value: { pulls: [] } });
  assert.ok(s.startsWith("!~MDT2~"));
  assert.match(s.slice(7), /^[A-Za-z0-9+/=]+$/);
});

test("非 MDT2 前缀拒绝", () => {
  assert.throws(() => decodeMdtString("!MDT:garbage"), /prefix/);
});

test("损坏 base64 拒绝", () => {
  assert.throws(() => decodeMdtString("!~MDT2~!!!not-base64!!!"));
});
```

- [x] **Step 2: 跑测试确认失败**

Run: `node --test tools/wclplan/mdtstring.test.js`
Expected: FAIL，`Cannot find module './mdtstring.js'`

- [x] **Step 3: 最小实现**

```js
// tools/wclplan/mdtstring.js
// 与本机 MDT v6.2.20 Transmission.lua:12-30 同管线：
// "!~MDT2~" .. Base64(DeflateRaw(SerializeCBOR(table)))
"use strict";
const zlib = require("node:zlib");
const { encodeCbor, decodeCbor } = require("./cbor.js");

const PREFIX = "!~MDT2~";

function encodeMdtString(preset) {
  const cbor = encodeCbor(preset);
  const deflated = zlib.deflateRawSync(cbor, { level: 9 });
  return PREFIX + deflated.toString("base64");
}

function decodeMdtString(text) {
  if (typeof text !== "string" || !text.startsWith(PREFIX)) {
    throw new Error("mdtstring: unsupported prefix, expected " + PREFIX);
  }
  const body = text.slice(PREFIX.length);
  if (!/^[A-Za-z0-9+/=]+$/.test(body)) {
    throw new Error("mdtstring: body is not base64");
  }
  const inflated = zlib.inflateRawSync(Buffer.from(body, "base64"));
  return decodeCbor(inflated);
}

module.exports = { encodeMdtString, decodeMdtString, PREFIX };
```

- [x] **Step 4: 跑测试确认通过**

Run: `node --test tools/wclplan/mdtstring.test.js`
Expected: PASS（4 个 test 全绿）

- [x] **Step 5: 提交**

```bash
git add tools/wclplan/mdtstring.js tools/wclplan/mdtstring.test.js
git commit -m "feat: add MDT !~MDT2~ string codec"
```

---

### Task 3: 合波规则

**Files:**
- Create: `tools/wclplan/merge.js`
- Test: `tools/wclplan/merge.test.js`

- [x] **Step 1: 写失败测试**（fixture 为 +22 纳洛拉克洞穴实测值）

```js
// tools/wclplan/merge.test.js
const test = require("node:test");
const assert = require("node:assert/strict");
const { mergePulls } = require("./merge.js");

const WINDOWS = [
  { start: 22, end: 100 }, { start: 113, end: 179 }, { start: 189, end: 228 },
  { start: 228, end: 452 }, { start: 467, end: 553 }, { start: 570, end: 875 },
  { start: 876, end: 1105 }, { start: 1140, end: 1205 }, { start: 1221, end: 1427 },
  { start: 1446, end: 1455 }, { start: 1460, end: 1669 },
];
const DEATHS = [13, 4, 0, 4, 11, 31, 7, 5, 8, 0, 5];

test("零死亡波与紧邻波合并，其余保持独立", () => {
  const groups = mergePulls(WINDOWS, DEATHS);
  assert.deepEqual(groups, [[1], [2], [3, 4], [5], [6, 7], [8], [9], [10, 11]]);
});

test("间隔阈值可配：阈值调小则不再按间隔合并", () => {
  const groups = mergePulls(WINDOWS, DEATHS, { gapSeconds: 0.5 });
  // 0s 间隔（3->4）仍合并；1s（6->7）与 5s（10->11）不再因间隔合并，
  // 但 10 是零死亡波，仍并入 11。
  assert.deepEqual(groups, [[1], [2], [3, 4], [5], [6], [7], [8], [9], [10, 11]]);
});

test("全零死亡的退化输入合并成单组不崩", () => {
  const w = [{ start: 0, end: 10 }, { start: 10, end: 20 }];
  assert.deepEqual(mergePulls(w, [0, 0]), [[1, 2]]);
});

test("长度不一致抛错", () => {
  assert.throws(() => mergePulls(WINDOWS, DEATHS.slice(0, 3)), /length/);
});
```

- [x] **Step 2: 跑测试确认失败**

Run: `node --test tools/wclplan/merge.test.js`
Expected: FAIL，`Cannot find module './merge.js'`

- [x] **Step 3: 最小实现**

```js
// tools/wclplan/merge.js
// 合波判据（2026-09-30 对 +22 纳洛拉克洞穴报告实测标定）：
//  (a) 本波窗口内 0 死亡 => 只 tag 没打，并入下一波；
//  (b) 与下一波窗口间隔 < gapSeconds => 实战未脱战，合并。
// 该报告三组合并间隔 0s/1s/5s，正常波间隔 >=10s，默认阈值 8s 有充足余量。
"use strict";

const DEFAULT_GAP_SECONDS = 8;

function mergePulls(windows, deathCounts, opts = {}) {
  if (!Array.isArray(windows) || !Array.isArray(deathCounts) || windows.length !== deathCounts.length) {
    throw new Error("merge: windows/deathCounts length mismatch");
  }
  const gap = opts.gapSeconds ?? DEFAULT_GAP_SECONDS;
  const groups = [];
  for (let i = 0; i < windows.length; i++) {
    const last = groups[groups.length - 1];
    const prev = i - 1;
    const joinPrevious = last && (
      deathCounts[prev] === 0 ||
      windows[i].start - windows[prev].end < gap
    );
    if (joinPrevious) last.push(i + 1);
    else groups.push([i + 1]);
  }
  return groups;
}

module.exports = { mergePulls, DEFAULT_GAP_SECONDS };
```

- [x] **Step 4: 跑测试确认通过**

Run: `node --test tools/wclplan/merge.test.js`
Expected: PASS（4 个 test 全绿）

- [x] **Step 5: 提交**

```bash
git add tools/wclplan/merge.js tools/wclplan/merge.test.js
git commit -m "feat: add pull merge rule calibrated on +22 NALO report"
```

---

### Task 4: 死亡事件 → pull 对齐（npcId 队列贪心）

**背景（执行中发现，2026-09-30）**：Threechest 路线 pulls 数（该报告 16）≠ WCL fights 数（11），
不能把 WCL 窗口直接套路线 pulls。改为：用 MDT 副本 Lua 表拿 enemyIdx→npcId，
把 deathEvents 按 npcId 分队列、按时间序贪心填进路线的各 pull（同 npc 的 clone 按波序死亡）。
**合波判据只在 WCL fight 空间做**（脱战信息只在那里可靠；执行中实测：把判据搬到路线空间会失效，
因为贪心赋值后 tag-only 波不再零死亡、间隔也被拉长）。路线 pull 经 `mapPullsToFights`
（死亡窗口中点落回 fight 窗口）映射回 fight，再按 fight 的合并组聚成 wave；
映射为 null 的 tag-only 路线 pull 前向并入下一个有映射的 pull 所在 wave。
合并波取并集，故合并内部的分配误差不影响产物。

**Files:**
- Create: `tools/wclplan/align.js`
- Create: `tools/wclplan/align.test.js`
- Modify: `tools/wclplan/merge.js`（窗口为 null 时跳过间隔判据）
- Modify: `tools/wclplan/merge.test.js`

- [x] **Step 1: 写失败测试**

```js
// tools/wclplan/align.test.js
const test = require("node:test");
const assert = require("node:assert/strict");
const { loadNpcIds, assignDeathsToPulls } = require("./align.js");

const LUA_SNIPPET = [
  "MDT.dungeonEnemies[dungeonIndex] = {",
  "  [1] = {",
  '    ["name"] = "Spirit of Hunger",',
  '    ["id"] = 245855,',
  '    ["clones"] = { [1] = { ["x"] = 1 }, [2] = { ["x"] = 2 } },',
  "  },",
  "  [2] = {",
  '    ["id"] = 241814,',
  '    ["clones"] = { [1] = { ["x"] = 3 } },',
  "  },",
  "}",
].join("\n");

test("loadNpcIds 按 enemyIdx 顺序取 id", () => {
  const npcIds = loadNpcIds(LUA_SNIPPET);
  assert.equal(npcIds[1], 245855);
  assert.equal(npcIds[2], 241814);
  assert.equal(npcIds[3], undefined);
});

test("同 npc 的死亡按时间序填入各 pull 队列", () => {
  const pulls = [{ 1: [1, 2] }, { 1: [3] }];
  const npcIds = { 1: 100 };
  const deaths = [
    { gameId: 100, timestamp: 30000 },
    { gameId: 100, timestamp: 10000 },
    { gameId: 100, timestamp: 20000 },
  ];
  const { windows, deathCounts, unassigned } = assignDeathsToPulls(pulls, npcIds, deaths);
  assert.deepEqual(deathCounts, [2, 1]);
  assert.deepEqual(windows[0], { start: 10, end: 20 });
  assert.deepEqual(windows[1], { start: 30, end: 30 });
  assert.deepEqual(unassigned, []);
});

test("队列耗尽的死亡进 unassigned 不崩", () => {
  const pulls = [{ 1: [1] }];
  const npcIds = { 1: 100 };
  const deaths = [{ gameId: 100, timestamp: 1000 }, { gameId: 100, timestamp: 2000 }];
  const { deathCounts, unassigned } = assignDeathsToPulls(pulls, npcIds, deaths);
  assert.deepEqual(deathCounts, [1]);
  assert.equal(unassigned.length, 1);
});

test("路线里没有的 npc 死亡进 unassigned", () => {
  const pulls = [{ 1: [1] }];
  const npcIds = { 1: 100 };
  const { unassigned } = assignDeathsToPulls(pulls, npcIds, [{ gameId: 999, timestamp: 5 }]);
  assert.equal(unassigned.length, 1);
});
```

并在 `merge.test.js` 追加：

```js
test("零死亡波窗口为 null 时只靠零死亡判据合并", () => {
  const w = [{ start: 0, end: 10 }, { start: null, end: null }, { start: 30, end: 40 }];
  assert.deepEqual(mergePulls(w, [3, 0, 2]), [[1, 2], [3]]);
});
```

- [x] **Step 2: 跑测试确认失败**

Run: `node --test tools/wclplan/align.test.js tools/wclplan/merge.test.js`
Expected: FAIL（align.js 不存在；merge 的 null 窗口用例失败）

- [x] **Step 3: 实现 align.js 并让 merge.js 容忍 null 窗口**

```js
// tools/wclplan/align.js
// enemyIdx→npcId 取自 MDT 副本 Lua 表（["id"] = 按 enemyIdx 有序出现）。
// 对齐：每个 (pull, npc) 开一个容量=clone 数的队列，死亡按时间序消费队首。
"use strict";

function loadNpcIds(luaText) {
  const start = luaText.indexOf("MDT.dungeonEnemies[");
  if (start < 0) throw new Error("align: dungeonEnemies block not found");
  const ids = [];
  const re = /\["id"\]\s*=\s*(\d+)/g;
  let m;
  while ((m = re.exec(luaText.slice(start))) !== null) ids.push(Number(m[1]));
  const out = {};
  ids.forEach((id, i) => { out[i + 1] = id; });
  return out;
}

function assignDeathsToPulls(pulls, npcIds, deathEvents) {
  const queues = {};
  pulls.forEach((pull, pullIndex) => {
    for (const [idx, clones] of Object.entries(pull)) {
      const npc = npcIds[Number(idx)];
      if (!npc || !Array.isArray(clones) || clones.length === 0) continue;
      (queues[npc] = queues[npc] || []).push({ pull: pullIndex + 1, remaining: clones.length });
    }
  });
  const windows = pulls.map(() => ({ start: null, end: null }));
  const deathCounts = pulls.map(() => 0);
  const unassigned = [];
  const sorted = deathEvents.slice().sort((a, b) => a.timestamp - b.timestamp);
  for (const death of sorted) {
    const entry = (queues[death.gameId] || []).find((q) => q.remaining > 0);
    if (!entry) { unassigned.push(death); continue; }
    entry.remaining -= 1;
    const seconds = death.timestamp / 1000;
    const w = windows[entry.pull - 1];
    w.start = w.start === null ? seconds : Math.min(w.start, seconds);
    w.end = w.end === null ? seconds : Math.max(w.end, seconds);
    deathCounts[entry.pull - 1] += 1;
  }
  return { windows, deathCounts, unassigned };
}

module.exports = { loadNpcIds, assignDeathsToPulls };
```

`merge.js` 的 `joinPrevious` 改为：

```js
    const joinPrevious = last && (
      deathCounts[prev] === 0 ||
      (windows[prev].end !== null && windows[i].start !== null &&
        windows[i].start - windows[prev].end < gap)
    );
```

- [x] **Step 4: 跑测试确认通过**

Run: `node --test tools/wclplan/align.test.js tools/wclplan/merge.test.js tools/wclplan/cbor.test.js tools/wclplan/mdtstring.test.js`
Expected: 全绿

- [x] **Step 5: 提交**

```bash
git add tools/wclplan/align.js tools/wclplan/align.test.js tools/wclplan/merge.js tools/wclplan/merge.test.js
git commit -m "feat: align WCL deaths to route pulls via npcId queues"
```

---

### Task 5: plan 行生成与 CLI

**Files:**
- Create: `tools/wclplan/plan.js`
- Create: `tools/wclplan/cli.js`
- Test: `tools/wclplan/plan.test.js`

- [x] **Step 1: 写失败测试**

```js
// tools/wclplan/plan.test.js
const test = require("node:test");
const assert = require("node:assert/strict");
const { buildEntrySpec, buildPlanLines, computeRouteKey } = require("./plan.js");

test("entrySpec 语法 id:kind:action[:uses]，分号分隔", () => {
  const spec = buildEntrySpec({ lust: 1, asc: 2, pot: 1 });
  assert.equal(spec, "32182:spell:use;114050:spell:use:2;241308:item:use");
});

test("零使用的技能不出现", () => {
  assert.equal(buildEntrySpec({ lust: 0, asc: 1, pot: 0 }), "114050:spell:use");
  assert.equal(buildEntrySpec({ lust: 0, asc: 0, pot: 0 }), "");
});

test("plan 行按合并组编号且 usage 按组求和，行首带 routeKey", () => {
  const groups = [[1], [2, 3]];
  const usage = [
    { lust: 0, asc: 1, pot: 0 },
    { lust: 1, asc: 0, pot: 1 },
    { lust: 0, asc: 1, pot: 0 },
  ];
  const lines = buildPlanLines(groups, usage, "00000001");
  assert.deepEqual(lines, [
    "/npt importplan 00000001 1 114050:spell:use",
    "/npt importplan 00000001 2 32182:spell:use;114050:spell:use;241308:item:use",
  ]);
});

test("整波无规划不产出行", () => {
  assert.deepEqual(buildPlanLines([[1]], [{ lust: 0, asc: 0, pot: 0 }], "00000001"), []);
});

test("routeKey 对相同 pulls 稳定、clone 数变化即变化", () => {
  const a = [{ 3: [1, 2] }, { 5: [1] }];
  assert.equal(computeRouteKey(a), computeRouteKey([{ 3: [1, 2] }, { 5: [1] }]));
  assert.notEqual(computeRouteKey(a), computeRouteKey([{ 3: [1] }, { 5: [1] }]));
  assert.match(computeRouteKey(a), /^[0-9a-f]{8}$/);
});
```

- [x] **Step 2: 跑测试确认失败**

Run: `node --test tools/wclplan/plan.test.js`
Expected: FAIL，`Cannot find module './plan.js'`

- [x] **Step 3: 最小实现 plan.js**

```js
// tools/wclplan/plan.js
// 把「每波冷却使用」翻译成 /npt importplan 命令行。
// ID 与 Modules/CooldownData.lua SEED_TABLE[262] 对齐：
//   嗜血族取萨满英勇 32182；升腾取 114050；药水取默认 itemID 241308。
// uses 只在 >=2 时出现在 spec 里（Lua 侧 SetUses 对 1 的处理是删字段）。
"use strict";

const SKILL_IDS = { lust: 32182, asc: 114050, pot: 241308 };
const SKILL_KIND = { lust: "spell", asc: "spell", pot: "item" };
const SKILL_ORDER = ["lust", "asc", "pot"];

function buildEntrySpec(usage) {
  const parts = [];
  for (const skill of SKILL_ORDER) {
    const count = usage[skill] || 0;
    if (count < 1) continue;
    let token = SKILL_IDS[skill] + ":" + SKILL_KIND[skill] + ":use";
    if (count >= 2) token += ":" + Math.min(3, count);
    parts.push(token);
  }
  return parts.join(";");
}

function buildPlanLines(groups, usagePerOriginalPull, routeKey) {
  const lines = [];
  groups.forEach((group, waveIndex) => {
    const summed = { lust: 0, asc: 0, pot: 0 };
    for (const pull of group) {
      const usage = usagePerOriginalPull[pull - 1] || {};
      for (const skill of SKILL_ORDER) summed[skill] += usage[skill] || 0;
    }
    const spec = buildEntrySpec(summed);
    if (spec === "") return;
    lines.push("/npt importplan " + routeKey + " " + (waveIndex + 1) + " " + spec);
  });
  return lines;
}

// 与 Lua 侧 ImportPlan.computeRouteKey 逐字节同公式：
// 每波 "idx:count" 字典序排序后逗号连接，波之间分号连接，
// 再对整串做 (hash*31+byte) mod 2^32 滚动哈希，输出 8 位小写 hex。
// 不依赖 MDT enemies 表（与存库的 per-pull fingerprint 是两套东西）。
function pullFingerprint(pull) {
  const parts = [];
  for (const [key, clones] of Object.entries(pull || {})) {
    const idx = Number(key);
    if (Number.isInteger(idx) && Array.isArray(clones)) parts.push(idx + ":" + clones.length);
  }
  parts.sort();
  return parts.join(",");
}

function computeRouteKey(pulls) {
  const joined = pulls.map(pullFingerprint).join(";");
  let hash = 0;
  for (let i = 0; i < joined.length; i++) {
    hash = (hash * 31 + joined.charCodeAt(i)) % 4294967296;
  }
  return hash.toString(16).padStart(8, "0");
}

module.exports = { buildEntrySpec, buildPlanLines, computeRouteKey, SKILL_IDS };
```

- [x] **Step 4: 最小实现 cli.js**

```js
// tools/wclplan/cli.js
// 用法: node tools/wclplan/cli.js <input.json> <out-dir>
// 读输入 JSON（见 plan 头部约定），写:
//   <out-dir>/route.mdt.txt   合并后的 MDT 导入字符串
//   <out-dir>/importplan.txt  每波一条 /npt importplan 行
//   <out-dir>/summary.json    合并组与每波 usage，供人工核对
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
```

- [x] **Step 5: 跑测试确认通过**

Run: `node --test tools/wclplan/plan.test.js`
Expected: PASS（4 个 test 全绿）

- [x] **Step 6: 提交**

```bash
git add tools/wclplan/plan.js tools/wclplan/plan.test.js tools/wclplan/cli.js
git commit -m "feat: add plan line builder and pipeline CLI"
```

---

### Task 6: Lua 侧 ImportPlan 纯逻辑模块

**Files:**
- Create: `Modules/ImportPlan.lua`
- Test: `spec/ImportPlan_spec.lua`

- [x] **Step 1: 写失败测试**

```lua
-- spec/ImportPlan_spec.lua
local mocks = require("wow_mocks")

local function presetWith(pulls)
  return {
    uid = "uid1",
    value = { currentDungeonIdx = 1, currentSublevel = 1, currentPull = 1, pulls = pulls },
  }
end

-- enemies 只需让 computePullFingerprint 认为 enemyIndex 存在。
local function enemiesFor(pull)
  local enemies = {}
  for idx in pairs(pull) do enemies[idx] = { clones = {} } end
  return enemies
end

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    mocks.loadSource("Modules/CooldownData.lua")
    mocks.loadSource("Modules/CooldownPlan.lua")
    mocks.loadSource("Modules/ImportPlan.lua")
    fn(env)
  end)
end

describe("ImportPlan entrySpec 解析", function()
  before_each(function() mocks.reset() end)

  it("解析 id:kind:action[:uses] 并忽略 uses=1", function()
    scenario(function(env)
      local entries, err = MDT_NPT.ImportPlan.parseEntrySpec("32182:spell:use;114050:spell:use:2;241308:item:use")
      assert.is_nil(err)
      assert.equals(3, #entries)
      assert.equals(32182, entries[1].id)
      assert.equals("spell", entries[1].kind)
      assert.equals("use", entries[1].action)
      assert.is_nil(entries[1].uses)
      assert.equals(2, entries[2].uses)
      assert.equals("item", entries[3].kind)
    end)
  end)

  it("非法 kind/action/非数字 id 报错", function()
    scenario(function(env)
      local _, err1 = MDT_NPT.ImportPlan.parseEntrySpec("32182:wand:use")
      assert.is_string(err1)
      local _, err2 = MDT_NPT.ImportPlan.parseEntrySpec("32182:spell:hold")
      assert.is_string(err2)
      local _, err3 = MDT_NPT.ImportPlan.parseEntrySpec("abc:spell:use")
      assert.is_string(err3)
    end)
  end)

  it("空串解析为零条", function()
    scenario(function(env)
      local entries, err = MDT_NPT.ImportPlan.parseEntrySpec("")
      assert.is_nil(err)
      assert.equals(0, #entries)
    end)
  end)
end)

describe("ImportPlan apply", function()
  before_each(function() mocks.reset() end)

  it("写入当前预设 uid 的 plan 并落 fingerprint", function()
    scenario(function(env)
      local pull = { [3] = { 1, 2 }, [5] = { 1 } }
      local preset = presetWith({ pull, { [7] = { 1 } } })
      _G.MDT.GetCurrentPreset = function() return preset end
      _G.MDT.dungeonEnemies = { [1] = enemiesFor(pull) }
      local key = MDT_NPT.ImportPlan.computeRouteKey(preset.value.pulls)

      local ok, err = MDT_NPT.ImportPlan:apply(1, "32182:spell:use;114050:spell:use:2", key)
      assert.is_nil(err)
      assert.is_true(ok)

      local plan = MDT_NPT.CooldownPlan:Get("uid1", 1)
      assert.equals(2, #plan.entries)
      assert.equals(2, plan.entries[2].uses)
      assert.equals("3:2,5:1", plan.fingerprint)
    end)
  end)

  it("routeKey 对不上拒绝写入", function()
    scenario(function(env)
      local pull = { [3] = { 1, 2 } }
      local preset = presetWith({ pull })
      _G.MDT.GetCurrentPreset = function() return preset end
      _G.MDT.dungeonEnemies = { [1] = enemiesFor(pull) }

      local ok, err = MDT_NPT.ImportPlan:apply(1, "32182:spell:use", "deadbeef")
      assert.is_false(ok)
      assert.is_string(err)
      assert.is_nil(MDT_NPT.CooldownPlan:Get("uid1", 1))
    end)
  end)

  it("无预设 uid 或波次越界报错且不写库", function()
    scenario(function(env)
      local preset = presetWith({ { [3] = { 1 } } })
      _G.MDT.GetCurrentPreset = function() return preset end
      local key = MDT_NPT.ImportPlan.computeRouteKey(preset.value.pulls)
      local ok1, err1 = MDT_NPT.ImportPlan:apply(9, "32182:spell:use", key)
      assert.is_false(ok1)
      assert.is_string(err1)
      assert.is_nil(MDT_NPT.CooldownPlan:Get("uid1", 9))

      _G.MDT.GetCurrentPreset = function() return { value = { pulls = {} } } end
      local ok2, err2 = MDT_NPT.ImportPlan:apply(1, "32182:spell:use", "00000000")
      assert.is_false(ok2)
      assert.is_string(err2)
    end)
  end)
end)
```

- [x] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/ImportPlan_spec.lua`
Expected: FAIL，`loadfile` 找不到 `Modules/ImportPlan.lua`

- [x] **Step 3: 最小实现**

```lua
-- Modules/ImportPlan.lua
-- 纯逻辑：解析 /npt importplan 的 entrySpec，并把计划写入当前 MDT 预设 uid。
-- fingerprint 在游戏内现算（CooldownData.computePullFingerprint），不跨端传输，
-- 保证与 VerifyFingerprint 的 live 计算逐字节一致。
local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT

local CooldownData = MDT_NPT.CooldownData
local CooldownPlan = MDT_NPT.CooldownPlan

local string_format, string_concat, table_sort = string.format, string.concat, table.sort

local ImportPlan = {}

local VALID_KIND = { spell = true, item = true }
local VALID_ACTION = { use = true, save = true }

-- entrySpec 语法: "id:kind:action[:uses]" 多条以 ";" 分隔。
-- uses=1 不存（读侧缺省即 1）；>=2 才保留，与 CooldownPlan:SetUses 语义一致。
---@return table|nil entries, string|nil err
function ImportPlan.parseEntrySpec(spec)
  local entries = {}
  if spec == nil or spec == "" then return entries end
  for token in spec:gmatch("[^;]+") do
    local idText, kind, action, usesText = token:match("^([^:]+):([^:]+):([^:]+):?([^:]*)$")
    if not idText then
      return nil, "bad token: " .. token
    end
    local id = tonumber(idText)
    if not id then return nil, "bad id in token: " .. token end
    if not VALID_KIND[kind] then return nil, "bad kind in token: " .. token end
    if not VALID_ACTION[action] then return nil, "bad action in token: " .. token end
    local entry = { id = id, kind = kind, action = action }
    if usesText ~= "" then
      local uses = tonumber(usesText)
      if not uses or uses < 1 or uses > 3 then return nil, "bad uses in token: " .. token end
      if uses >= 2 then entry.uses = math.floor(uses) end
    end
    entries[#entries + 1] = entry
  end
  return entries
end

-- routeKey：防「粘行时当前预设不是目标路线」的配对校验码。
-- 与 tools/wclplan/plan.js computeRouteKey 逐字节同公式：
-- 每波 "idx:count" 字典序排序逗号连接、波间分号连接，(hash*31+byte) mod 2^32，%08x。
-- 刻意不复用 computePullFingerprint：那个要 enemies 表且会跳过未知 enemyIndex，
-- 而 routeKey 必须离线/游戏内两侧算出同一个值。
local function pullKey(pull)
  local parts = {}
  for key, clones in pairs(pull or {}) do
    local idx = tonumber(key)
    if idx and idx % 1 == 0 and type(clones) == "table" then
      parts[#parts + 1] = string_format("%d:%d", idx, #clones)
    end
  end
  table_sort(parts)
  return string_concat(parts, ",")
end

function ImportPlan.computeRouteKey(pulls)
  local joined = {}
  for i = 1, #pulls do joined[i] = pullKey(pulls[i]) end
  local s = string_concat(joined, ";")
  local hash = 0
  for i = 1, #s do
    hash = (hash * 31 + s:byte(i)) % 4294967296
  end
  return string_format("%08x", hash)
end

---@return boolean ok, string|nil err
function ImportPlan:apply(wave, entrySpec, routeKey)
  local entries, parseErr = ImportPlan.parseEntrySpec(entrySpec)
  if not entries then return false, parseErr end
  if type(wave) ~= "number" or wave < 1 or wave % 1 ~= 0 then
    return false, "wave must be a positive integer"
  end
  if type(routeKey) ~= "string" or #routeKey == 0 then
    return false, "missing route key"
  end

  local preset = MDT and MDT.GetCurrentPreset and MDT:GetCurrentPreset()
  if not preset or not preset.uid or preset.uid == "" then
    return false, "no current preset uid; import the MDT route first"
  end
  local pulls = preset.value and preset.value.pulls
  local pull = pulls and pulls[wave]
  if not pull then
    return false, "preset has no pull " .. wave
  end
  local liveKey = ImportPlan.computeRouteKey(pulls)
  if liveKey ~= routeKey then
    return false, "route key mismatch: line says " .. routeKey .. ", current preset is " .. liveKey
  end
  local enemies = MDT.dungeonEnemies and MDT.dungeonEnemies[preset.value.currentDungeonIdx]

  for _, entry in ipairs(entries) do
    CooldownPlan:SetEntry(preset.uid, wave, entry.id, entry.kind, entry.action)
    if entry.uses then
      CooldownPlan:SetUses(preset.uid, wave, entry.id, entry.uses)
    end
  end
  CooldownPlan:SetFingerprint(preset.uid, wave, CooldownData.computePullFingerprint(pull, enemies))
  return true
end

MDT_NPT.ImportPlan = ImportPlan
```

- [x] **Step 4: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/ImportPlan_spec.lua`
Expected: PASS（5 个 it 全绿）

- [x] **Step 5: 提交**

```bash
git add Modules/ImportPlan.lua spec/ImportPlan_spec.lua
git commit -m "feat: add ImportPlan pure logic for /npt importplan"
```

---

### Task 7: Slash 命令接线

**Files:**
- Modify: `Modules/Slash.lua`（加 handler + commands 表条目）
- Modify: `MythicDungeonTools_NextPullTracker.toc` 或对应 xml（若 ImportPlan.lua 未列入加载顺序；见 Step 1 检查）
- Test: `spec/ImportPlan_spec.lua`（追加 dispatch 用例）

- [x] **Step 1: 检查加载顺序**

Run: `grep -n "ImportPlan\|CooldownPlan.lua\|Slash.lua" MythicDungeonTools_NextPullTracker.toc locales.xml 2>/dev/null; grep -rn "Slash.lua" --include=*.xml .`
Expected: 找到 Slash.lua 与 CooldownPlan.lua 的加载位置；把 `Modules/ImportPlan.lua` 加在 CooldownPlan.lua 之后、Slash.lua 之前（同一 xml/TOC 列表）。

- [x] **Step 2: 写失败测试（dispatch 到 ImportPlan）**

在 `spec/ImportPlan_spec.lua` 的 `describe("ImportPlan apply", ...)` 之后追加：

```lua
describe("Slash dispatch importplan", function()
  before_each(function() mocks.reset() end)

  it("/npt importplan <routeKey> <wave> <spec> 落到当前预设", function()
    scenario(function(env)
      local pull = { [3] = { 1, 2 } }
      local preset = presetWith({ pull })
      _G.MDT.GetCurrentPreset = function() return preset end
      _G.MDT.dungeonEnemies = { [1] = enemiesFor(pull) }
      _G.SlashCmdList = {}
      mocks.loadSource("Modules/Slash.lua")
      local key = MDT_NPT.ImportPlan.computeRouteKey(preset.value.pulls)

      MDT_NPT:Slash("importplan " .. key .. " 1 32182:spell:use:2")
      local plan = MDT_NPT.CooldownPlan:Get("uid1", 1)
      assert.equals(1, #plan.entries)
      assert.equals(2, plan.entries[1].uses)
      assert.equals("3:2", plan.fingerprint)
    end)
  end)

  it("参数缺失打印用法不写库", function()
    scenario(function(env)
      _G.MDT.GetCurrentPreset = function() return presetWith({ { [3] = { 1 } } }) end
      _G.SlashCmdList = {}
      mocks.loadSource("Modules/Slash.lua")
      MDT_NPT:Slash("importplan")
      assert.is_nil(MDT_NPT.CooldownPlan:Get("uid1", 1))
    end)
  end)
end)
```

- [x] **Step 3: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/ImportPlan_spec.lua`
Expected: FAIL，`importplan` 未识别（走到 printHelp，plan 为 nil 断言过但 uses 断言失败）

- [x] **Step 4: 实现 handler 与命令条目**

在 `Modules/Slash.lua` 的 `handlePlan` 之后加：

```lua
-- 导入外部生成的冷却计划（tools/wclplan 产物）。ImportPlan 在 Slash.lua 之后加载，
-- 与 handlePlan/handleAlert 同一手法：函数体内后取，不在文件顶层捕获 upvalue。
local function handleImportPlan(rest)
  local routeKey, waveText, spec = rest:match("^(%S+)%s+(%S+)%s+(.*)$")
  local wave = tonumber(waveText or "")
  if not routeKey or not wave or not spec or spec == "" then
    print(PREFIX..": usage: "..CMD_COLOR.."/npt importplan <routeKey> <wave> <id:kind:action[:uses];...>|r")
    return
  end
  local ok, err = MDT_NPT.ImportPlan:apply(wave, spec, routeKey)
  if not ok then
    print(PREFIX..": importplan failed: "..tostring(err))
    return
  end
  print(PREFIX..": imported cooldown plan for pull "..wave..".")
end
```

在 `commands = { ... }` 表中 `{ name = "plan", ... }` 一行之后加：

```lua
  { name = "importplan", usage = "importplan <routeKey> <wave> <spec>", help = "import a generated cooldown plan for wave N", handler = handleImportPlan },
```

- [x] **Step 5: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/ImportPlan_spec.lua`
Expected: PASS（7 个 it 全绿）

- [x] **Step 6: 全量本地回归**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/CooldownData_spec.lua spec/CooldownPlanEditor_spec.lua spec/ImportPlan_spec.lua`
Expected: 全绿（MDTAdapter_spec 需单跑，见 luaenv 记忆）

- [x] **Step 7: 提交**

```bash
git add Modules/Slash.lua spec/ImportPlan_spec.lua MythicDungeonTools_NextPullTracker.toc
git commit -m "feat: wire /npt importplan slash command"
```

---

### Task 8: 端到端 runbook（+22 纳洛拉克洞穴）

**Files:**
- Create: `tools/wclplan/fixtures/nalo22-C9pFgkRJwMvHB4KY.input.json`（runbook 产出，入库作回归 fixture）
- Modify: `tools/wclplan/mdtstring.test.js`（追加真实串 fixture 解码用例）

- [x] **Step 1: 取路线串**：内置浏览器开 `https://threechest.io/`，Ctrl+V 粘贴 `https://cn.warcraftlogs.com/reports/C9pFgkRJwMvHB4KY?fight=4`，等导入完成；覆盖 `window.prompt` 捕获 Export MDT（Ctrl+E）输出，存为 `routeString`。（步骤与 2026-09-30 实测一致；prompt 捕获脚本见当日会话。）

- [x] **Step 2: 取每波窗口与死亡数**：报告页战斗下拉读 Pull 1..11 的 `(时长) +偏移`；死亡数用 Threechest `/api/wclRoute` 的 deathEvents 按窗口分桶（本 plan 头部 fixture 即该报告实测值，可直接复用）。

- [x] **Step 3: 取每波冷却使用**：fight 粒度靠人工读报告页（`?fight=N&type=casts&source=<萨满sourceID>`，萨满 sourceID = cast 过 32182 的 actor，本报告为 sourceID 1）填 `usage`；combat 粒度改用 WCL V2 API 拉 cast 事件填 `castEvents`（`skill` ∈ asc/lust/pot，`t` 为整局相对秒），每波 usage 由 cli 自动归属，不用人工分桶。

- [x] **Step 4: 生成产物**

Run: `node tools/wclplan/cli.js tools/wclplan/fixtures/nalo22-C9pFgkRJwMvHB4KY.input.json .tmp-npt-task/nalo22 --granularity=combat`
Expected: `groups: [[1],[2],[3,4],[5,6],[7],[8],[9],[10],[11],[12,13,14],[15,16]]`、`routeKey: 4624dc42`、8 条 importplan 行，三个产物文件写出。
（fight 粒度 `--granularity=fight` 得 8 波 `[[1],[2],[3,4],[5,6],[7,8,9,10],[11],[12,13],[14,15,16]]`；实战录像核对下来 combat 才是对的，见 Task 9。）

- [x] **Step 5: 真实串 fixture 用例**：把 Step 1 捕获的串（脱敏后）加入 `mdtstring.test.js`：解码后断言 `value.currentDungeonIdx` 为纳洛拉克索引、`value.pulls.length == 16`——Threechest 导出的是**未合并**的原始 16 pull（合并发生在 cli 里，产物 11 波）。

- [ ] **Step 6: 游戏内验证**：MDT 导入 `route.mdt.txt`；逐行粘贴 `importplan.txt`；`/npt start` 后 `/npt alert` 确认合并波（combat 粒度第 3 波 = 原路线 P3+P4）在接战时即播报嗜血/升腾计划。**（唯一未完成步：等用户真机验证。）**

- [x] **Step 7: 提交**

```bash
git add tools/wclplan/fixtures/nalo22-C9pFgkRJwMvHB4KY.input.json tools/wclplan/mdtstring.test.js
git commit -m "test: add +22 NALO end-to-end fixture"
```

---

### Task 9: 战斗簇粒度切波（`--granularity=combat`）

**背景（2026-09-30 用户看录像标定）：** fight 粒度按 WCL 的 fight 分段合波，但 WCL 的分段本身受脱战判定影响，实战里「一波」常常跨两个 fight，或一个 fight 里其实打了两波。用户核对录像后确认的正确切法是**按死亡时间簇**：没怪死超过 30s = 脱战；空窗里若有升腾/嗜血且距下一簇首死 ≥60s，说明坦克怪还活着、战斗没停 → 合并；接战爆发（距首死 <60s，含战前偷药）不合并。

**Files:**
- Create: `tools/wclplan/waves.js`、`tools/wclplan/waves.test.js`、`tools/wclplan/cli.test.js`
- Create: `tools/wclplan/report.js`、`tools/wclplan/report.test.js`（本地网页展示：时间轴 + 波次表 + 复制按钮，读 cli 产物，不联网）
- Modify: `tools/wclplan/align.js`（`assignDeathsToPulls` 增返 `deathPulls`/`deathSeconds`；新增 `loadEnemyMeta`）
- Modify: `tools/wclplan/plan.js`（拆出 `specLines`；新增 `sumUsagePerWave`）
- Modify: `tools/wclplan/cli.js`（`--granularity`、castEvents 归属、`lastWaveEnemies` 补挂、count=0 候选提示）
- Modify: `tools/wclplan/fixtures/nalo22-C9pFgkRJwMvHB4KY.input.json`（增 `castEvents` 20 条、`lastWaveEnemies: [25,26]`）
- Modify: `spec/ImportPlan_spec.lua`（真机产物 routeKey 跨语言锁定）

- [x] **Step 1: 规则与阈值写进 `waves.js`**

`DEFAULTS = { gapSeconds: 30, tailSeconds: 5, engageGraceSeconds: 120, midCombatMinSeconds: 60, maxAscPerWave: 2 }`。四个函数：`clusterDeaths`（间隔切簇）、`majorityPullSets`（pull 归簇按死亡多数票）、`assignCastCluster`（cast 归簇：簇内 → 空窗接战 → 最近簇）、`buildCombatWaveDetail`（合并 + 升腾上限再切）。

多数票是标定出来的必需项：+22 报告里 p9 有 1 只（npc 241911）死在 15:35，落进 p10 的簇，按「任一死亡即归簇」会把 p9 同时塞进第 7、8 两波；多数票（p9 的 10 只死在 13:23–14:08）把它留在第 7 波。

升腾上限 2 是自动纠错守卫：簇阈值粘错时，一波里出现 3+ 次升腾必然不是一波（120s CD）。本 fixture 没触发切分（合并组内最多 2 次）。

- [x] **Step 2: 单测锁阈值行为 + fixture 锁 11 波**

Run: `node --test tools/wclplan/waves.test.js`
Expected: 6 passed（空窗无爆发不合并 / 战中爆发合并 / 接战爆发不合并 / 升腾超上限再切 / 多数票归簇 / fixture 11 波）。

fixture 标定表（键相对时间；`d` = 空窗 cast 距下一簇首死秒数）：

| 簇 | 时间 | 路线 pull | 空窗 cast(d) | 与前簇 |
|---|---|---|---|---|
| c1 | 1:05–1:40 | 1 | — | — |
| c2 | 2:51–3:00 | 2 | — | 不合并 |
| c3 | 4:34–4:55 | 3 | 3:52(42) | 不合并 |
| c4 | 7:33 | 4 | 6:02(92) | **合并** |
| c5 | 8:31–9:13 | 5,6 | 8:11(20) | 不合并 |
| c6 | 10:34–11:11 | 7 | 10:11(23) | 不合并 |
| c7 | 12:14–12:43 | 8 | — | 不合并 |
| c8 | 13:23–14:08 | 9 | 13:05(18) 13:09(14) | 不合并 |
| c9 | 15:34–15:52 | 10 | 15:11(23) | 不合并 |
| c10 | 18:25 | 10 | 17:12(73) | **合并** |
| c11 | 19:50–20:05 | 11 | — | 不合并 |
| c12 | 21:03–22:18 | 12,13 | 20:35(28) | 不合并 |
| c13 | 23:59 | 14 | 22:40(79) | **合并** |
| c14 | 25:15–26:25 | 15,16 | 24:24(51) 24:40(35) | 不合并 |

14 簇 → 11 波：`[[1],[2],[3,4],[5,6],[7],[8],[9],[10],[11],[12,13,14],[15,16]]`（与用户看录像确认的分组逐波一致）。

- [x] **Step 3: usage 由 castEvents 自动归属**

`waves.castWaves(castEvents, detail)` 给出每条 cast 落在哪一波，`plan.sumUsagePerWave` 计数。校验：产物 8 条行与之前人工填的 `WAVE_USAGE` 逐项相同（如第 8 波 `114050:spell:use:2;241308:item:use` = c9 的 15:11 升腾 + c10 的 17:12 升腾 + 14:46 偷药）。

- [x] **Step 4: boss 补挂走显式输入，不猜**

`loadEnemyMeta` 拿 `count`/`clones`；cli 只**提示**路线里缺失的 count=0 敌人（本副本输出 `19,20,27,28,29,30,32`），实际补挂读 `input.lastWaveEnemies`。原因：本副本 count=0 的敌人有 14 个（含 4 个 `isBoss=true`、共用 encounterID 2777），没有可靠结构特征能自动挑出「最后一波的 boss 战 trio」；25 Nalorakk（ Zul'jarra 的宝宝）+ 26 Zul'jarra 是用户点名要的，27 Echo of Nalorakk 明确不补。

- [x] **Step 5: 端到端 + 跨语言校验**

Run: `node --test tools/wclplan/cbor.test.js tools/wclplan/mdtstring.test.js tools/wclplan/merge.test.js tools/wclplan/align.test.js tools/wclplan/plan.test.js tools/wclplan/lust.test.js tools/wclplan/waves.test.js tools/wclplan/cli.test.js`
Expected: 49 passed / 0 failed。

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/ImportPlan_spec.lua`
Expected: 10 passed —— 含新用例「Lua 侧对同一条 11 波路线算出 `4624dc42`」，锁住 JS/Lua routeKey 同公式（游戏内 importplan 靠它校验，算不一致会整批拒写）。

注：`cli.test.js`/`waves.test.js` 的 fixture 用例要读本机 MDT 安装目录的副本 Lua（`input.mdtDungeonFile`），文件不存在时 skip 而非红。

- [x] **Step 5b: 本地网页展示**

Run: `node tools/wclplan/report.js tools/wclplan/fixtures/nalo22-C9pFgkRJwMvHB4KY.input.json .tmp-npt-task/nalo22-combat`
Expected: 写出 `<out-dir>/report.html`（时间轴 SVG、路线串/plan 行带复制按钮、波次明细表、游戏内验证步骤）。cast 归属波次与 cli 生成 plan 行用同一套 `castWaves`，页面与 importplan 不会各说各话。

- [x] **Step 6: 提交**

```bash
git add tools/wclplan/waves.js tools/wclplan/waves.test.js tools/wclplan/cli.js tools/wclplan/cli.test.js \
        tools/wclplan/align.js tools/wclplan/align.test.js tools/wclplan/plan.js tools/wclplan/plan.test.js \
        tools/wclplan/report.js tools/wclplan/report.test.js \
        tools/wclplan/fixtures/nalo22-C9pFgkRJwMvHB4KY.input.json spec/ImportPlan_spec.lua \
        docs/superpowers/plans/2026-09-30-wcl-to-mdt-npt-plan.md
git commit -m "feat: cut waves by combat clusters, derive usage from cast events"
```

（实际分两次入库：主提交 `7a0d3f7`；`report.js`/`report.test.js` 与 Step 5b 在后续提交单独入库。）

---

## 自审记录

- **Spec 覆盖**：合波规则→Task 3；MDT 字符串→Task 1/2/7；plan 写入→Task 5/6；每波冷却数据来源→Task 7 runbook；fingerprint→Task 5（游戏内现算）。
- **占位符**：无 TBD/TODO；每个代码步含完整代码；runbook 步含确切 URL 与命令。
- **类型一致**：`parseEntrySpec`/`apply` 签名在 Task 5 定义、Task 6 测试与 handler 调用一致；`mergePulls(windows, deathCounts, opts)` 在 Task 3 定义、Task 4 cli 调用一致；entrySpec 语法在 plan.js 与 ImportPlan.lua 两侧互为镜像（`uses` 仅 ≥2 出现）。
- **已知边界**：seed 表仅元素萨（262），其他 spec 的 plan 行会被 `getSeedEntries` 过滤为空——runbook 只对元素萨角色有意义，已在 Goal 注明。
