# WCL Wave Spell Ratio Orb Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import each final MDT/NPT wave's historical Elemental Blast versus Earthquake cast mix from WCL and display it in-game as a draggable Diablo-style two-color orb.

**Architecture:** The Node exporter treats successful rotation casts as a second event stream, assigns them through the already-finalized wave intervals, and emits a route-keyed ratio pack. The addon parses that pack atomically into a character-scoped store keyed by preset UID and pull index; a focused `SpellRatioOrb` module reads the current NPT wave and renders a masked purple/orange orb without polling.

**Tech Stack:** Node.js 24 (`node:test`), WoW 12.1 Lua 5.1, AceDB-3.0, WoW `MaskTexture`, Busted 2.x / local fengari minibusted.

---

## File map

**Create**

- `tools/wclplan/rotation.js` — validate/assign rotation casts, count by wave, normalize display ratio, build import pack.
- `tools/wclplan/rotation.test.js` — pure Node tests for all rotation calculations and serialization.
- `Modules/SpellRatioData.lua` — character-scoped storage, sanitization, ratio calculation, fingerprint verification.
- `Modules/ImportRatio.lua` — route-keyed ratio-pack parser and atomic importer.
- `Modules/SpellRatioOrb.lua` — masked orb UI, current-wave refresh, dragging and visibility.
- `spec/SpellRatioData_spec.lua` — storage and ratio unit tests.
- `spec/ImportRatio_spec.lua` — parser, atomic import and slash tests.
- `spec/SpellRatioOrb_spec.lua` — rendering, lifecycle and drag tests.

**Modify**

- `tools/wclplan/cli.js` — require `rotationCastEvents`, persist assignments/usage, emit `importratiopack.txt`.
- `tools/wclplan/cli.test.js` — fixture and integration assertions.
- `tools/wclplan/report.js` — validate/render persisted ratio data and copy command.
- `tools/wclplan/report.test.js` — fixture and pairing/render tests.
- `Core.lua` — defaults and `UpdateAll()` hook.
- `Modules/Slash.lua` — `/npt importratiopack` dispatch.
- `Modules/Settings.lua` — independent enabled toggle.
- `Modules/load_modules.xml` — dependency-safe module load order.
- `Locales/enUS.lua`, `Locales/zhCN.lua`, `Locales/frFR.lua`, `Locales/ruRU.lua` — setting labels/tooltips.
- `spec/helpers/wow_mocks.lua` — ratio DB defaults and frame APIs needed by the orb.
- `spec/Locales_spec.lua` — locale key parity.
- `deploy/wcl-qQKAyptwcMg6n43x-f12/input.json` — add successful rotation cast events for the current report.

## Conventions fixed by the approved design

- Spell IDs: Elemental Blast `117014`, Earthquake `61882`.
- Count only WCL events whose `type` is exactly `cast`.
- Orb fill uses the nearest 10% step. When both skills are nonzero, clamp the Elemental Blast step to `10%–90%`; single-sided data may use `0%/100%`. The label independently keeps the original tenths algorithm.
- `0:0` is an imported value, distinct from missing data.
- The ratio pack must contain exactly one token for every final route wave so an import fully replaces stale route data.
- All commit steps below require explicit user approval before execution.

## Final review amendments (authoritative)

The implementation review tightened three cross-platform contracts; these rules supersede older code samples below where they differ:

- `rotationCastEvents` uses `{ type: "cast", spellId: 117014|61882, t }`. The exporter and report reject `begincast`, unknown IDs, and invalid times.
- Ratio packs are ordered lowercase-base36 pairs, not verbose wave tokens: `<eb36>.<eq36>,...`. Token position is the 1-based wave; the token count must equal the route pull count. The exporter rejects commands longer than 255 characters.
- The report recomputes assignments and usage from persisted rotation events and final wave bounds before accepting the copied command.
- The orb uses icon-matched colors: Elemental Blast electric violet `#B34CFF`, Earthquake earth gold `#C9902E`.
- The orb liquid uses the nearest 10% step: `floor(EB / total * 10 + 0.5) * 10`. When both skills are nonzero, clamp it to `10%–90%`; single-sided data remains `0%/100%`. The text remains unchanged, so `1/46` renders a `10:90` liquid split while the label remains `0:10`.
- Holding Alt reveals a bottom-right scale grip. Dragging it scales the complete frame proportionally from `0.5` to `2.0`; `db.beacon.spellRatioOrbScale` persists the value. Releasing Alt mid-scale finalizes, saves and restores click-through.
- Successful in-game import refreshes the orb immediately. `PLAYER_SPECIALIZATION_CHANGED` for `player` also refreshes it; there is still no ticker.

Current fixture oracle:

```text
/npt importratiopack 648e7d8d 1.1,0.1,1.1,2.1
```

### Amendment task: stepped liquid and proportional scaling

**Files:**
- Modify: `Modules/SpellRatioOrb.lua`
- Modify: `spec/SpellRatioOrb_spec.lua`
- Modify: `spec/helpers/wow_mocks.lua` only if a real Frame API used below is absent

- [ ] Add failing tests that `1/46` produces fill heights `60 * 10 / 100` and `60 * 90 / 100`, while the label remains `0:10`; also cover `14%→10%`, `15%→20%`, and true single-sided `0%/100%`.
- [ ] Add failing tests for default scale `1`, saved scale restoration/clamping, a bottom-right grip visible and mouse-enabled only while Alt is held, cursor-driven `SetScale`, saving a `0.5–2.0` scale, and finalization when Alt is released mid-scale.
- [ ] Implement nearest-10% fill rounding with a `10%–90%` clamp only when both raw counts are nonzero, without changing `SpellRatioData:RatioTenths`.
- [ ] Implement proportional frame scaling via `frame:SetScale(scale)`; the base geometry remains unchanged so orb, icons and text scale together.
- [ ] Persist only validated finite scale values to `db.beacon.spellRatioOrbScale`; clamp restored and newly calculated values to `0.5–2.0`.
- [ ] Add a 16-pixel bottom-right grip following `BeaconFrame.createResizeGrip`: on mouse-down capture `GetCursorPosition()`, `frame:GetScale()` and `UIParent:GetEffectiveScale()`; on `OnUpdate`, use the dominant-axis cursor delta divided by base frame width/height to set the clamped scale. The grip is interactive only while Alt is held; no ticker is added.
- [ ] Run:

```bash
node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioOrb_spec.lua spec/SpellRatioData_spec.lua spec/ReadyTracker_spec.lua
node --test tools/wclplan/*.test.js
git diff --check
```

Expected: all tests pass; no Node exporter artifacts change because this amendment is UI-only.

---

### Task 1: Pure Node rotation calculations and pack format

**Files:**
- Create: `tools/wclplan/rotation.js`
- Create: `tools/wclplan/rotation.test.js`

- [ ] **Step 1: Write failing tests for validation, wave assignment, counts and serialization**

Create `tools/wclplan/rotation.test.js`:

```js
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  assignRotationEvents,
  summarizeRotation,
  ratioTenths,
  buildRatioPack,
  buildRatioPackLine,
} = require("./rotation.js");

const waves = [
  { pulls: [1], castStart: 0, castEnd: 50 },
  { pulls: [2], castStart: 60, castEnd: 100 },
];

test("assigns successful rotation casts with the same latest-wave boundary rule", () => {
  const events = [
    { skill: "elementalBlast", t: 10 },
    { skill: "earthquake", t: 50 },
    { skill: "earthquake", t: 70 },
  ];
  assert.deepEqual(assignRotationEvents(events, waves), [0, 0, 1]);
  assert.deepEqual(summarizeRotation(2, events, [0, 0, 1]), [
    { elementalBlast: 1, earthquake: 1 },
    { elementalBlast: 0, earthquake: 1 },
  ]);
});

test("rejects invalid skill, time and wave assignment", () => {
  assert.throws(() => assignRotationEvents([{ skill: "asc", t: 10 }], waves), /invalid rotation event/);
  assert.throws(() => assignRotationEvents([{ skill: "earthquake", t: NaN }], waves), /invalid rotation event/);
  assert.deepEqual(assignRotationEvents([{ skill: "earthquake", t: 55 }], waves), [-1]);
  assert.throws(() => summarizeRotation(2, [{ skill: "earthquake", t: 55 }], [-1]), /unassigned rotation cast/);
});

test("normalizes text to tenths while preserving exact counts for fill", () => {
  assert.deepEqual(ratioTenths({ elementalBlast: 8, earthquake: 2 }), { elementalBlast: 8, earthquake: 2 });
  assert.deepEqual(ratioTenths({ elementalBlast: 1, earthquake: 42 }), { elementalBlast: 0, earthquake: 10 });
  assert.deepEqual(ratioTenths({ elementalBlast: 1, earthquake: 1 }), { elementalBlast: 5, earthquake: 5 });
  assert.equal(ratioTenths({ elementalBlast: 0, earthquake: 0 }), null);
});

test("serializes every wave including zero-zero", () => {
  const usage = [
    { elementalBlast: 8, earthquake: 2 },
    { elementalBlast: 0, earthquake: 0 },
    { elementalBlast: 1, earthquake: 42 },
  ];
  assert.equal(buildRatioPack(usage), "1:e8q2;2:e0q0;3:e1q42");
  assert.equal(buildRatioPackLine(usage, "abc12345"),
    "/npt importratiopack abc12345 1:e8q2;2:e0q0;3:e1q42");
});
```

- [ ] **Step 2: Run the test and verify it fails because the module does not exist**

Run:

```bash
node --test tools/wclplan/rotation.test.js
```

Expected: FAIL with `Cannot find module './rotation.js'`.

- [ ] **Step 3: Implement the pure rotation module**

Create `tools/wclplan/rotation.js`:

```js
"use strict";

const SKILLS = new Set(["elementalBlast", "earthquake"]);

function validateRotationEvents(events) {
  if (!Array.isArray(events)) throw new Error("rotation: rotationCastEvents must be an array");
  for (const event of events) {
    if (!event || !SKILLS.has(event.skill) || !Number.isFinite(event.t) || event.t < 0) {
      throw new Error("rotation: invalid rotation event");
    }
  }
}

function assignRotationEvents(events, waves) {
  validateRotationEvents(events);
  if (!Array.isArray(waves)) throw new Error("rotation: waves must be an array");
  return events.map(event => {
    for (let i = waves.length - 1; i >= 0; i--) {
      const wave = waves[i];
      if (Number.isFinite(wave.castStart) && Number.isFinite(wave.castEnd) &&
          event.t >= wave.castStart && event.t <= wave.castEnd) return i;
    }
    return -1;
  });
}

function summarizeRotation(waveCount, events, assignments) {
  validateRotationEvents(events);
  if (!Number.isInteger(waveCount) || waveCount < 1 || !Array.isArray(assignments) || assignments.length !== events.length) {
    throw new Error("rotation: invalid assignment input");
  }
  const usage = Array.from({ length: waveCount }, () => ({ elementalBlast: 0, earthquake: 0 }));
  events.forEach((event, i) => {
    const wave = assignments[i];
    if (!Number.isInteger(wave) || wave < 0 || wave >= waveCount) {
      throw new Error("rotation: unassigned rotation cast at " + event.t);
    }
    usage[wave][event.skill] += 1;
  });
  return usage;
}

function ratioTenths(usage) {
  const total = usage.elementalBlast + usage.earthquake;
  if (total === 0) return null;
  const elementalBlast = Math.floor(usage.elementalBlast / total * 10 + 0.5);
  return { elementalBlast, earthquake: 10 - elementalBlast };
}

function buildRatioPack(usage) {
  return usage.map((row, i) => `${i + 1}:e${row.elementalBlast}q${row.earthquake}`).join(";");
}

function buildRatioPackLine(usage, routeKey) {
  return "/npt importratiopack " + routeKey + " " + buildRatioPack(usage);
}

module.exports = {
  assignRotationEvents,
  summarizeRotation,
  ratioTenths,
  buildRatioPack,
  buildRatioPackLine,
};
```

- [ ] **Step 4: Run the focused test**

Run:

```bash
node --test tools/wclplan/rotation.test.js
```

Expected: 4 tests PASS.

- [ ] **Step 5: Commit if explicitly authorized**

```bash
git add tools/wclplan/rotation.js tools/wclplan/rotation.test.js
git commit -m "feat: add per-wave rotation ratio calculations"
```

---

### Task 2: CLI integration and persisted artifacts

**Files:**
- Modify: `tools/wclplan/cli.js:1-16,61-85,117-134`
- Modify: `tools/wclplan/cli.test.js:1-149`

- [ ] **Step 1: Extend the CLI fixture and add failing integration assertions**

In the `input` fixture in `tools/wclplan/cli.test.js`, add:

```js
rotationCastEvents: [
  { skill: "elementalBlast", t: 20 },
  { skill: "earthquake", t: 30 },
  { skill: "earthquake", t: 70 },
  { skill: "elementalBlast", t: 120 },
  { skill: "earthquake", t: 200 },
  { skill: "elementalBlast", t: 260 },
  { skill: "elementalBlast", t: 320 },
  { skill: "earthquake", t: 330 },
],
```

Extend `run()` so successful output reads:

```js
result.ratioPack = fs.readFileSync(path.join(outDir, "importratiopack.txt"), "utf8").trim();
```

Add tests:

```js
test("exports per-final-wave rotation usage and a route-keyed complete ratio pack", () => {
  const out = run();
  succeeded(out);
  assert.deepEqual(out.summary.rotationUsage, [
    { elementalBlast: 1, earthquake: 1 },
    { elementalBlast: 0, earthquake: 1 },
    { elementalBlast: 1, earthquake: 1 },
    { elementalBlast: 2, earthquake: 1 },
  ]);
  assert.equal(out.summary.rotationAssignments.length, 8);
  assert.equal(out.ratioPack,
    `/npt importratiopack ${out.summary.routeKey} 1:e1q1;2:e0q1;3:e1q1;4:e2q1`);
  assert.equal(out.summary.ratioPackLine, out.ratioPack);
});

test("missing or unassigned rotation events fail before artifacts are written", () => {
  const missing = run(input => { delete input.rotationCastEvents; });
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /rotationCastEvents/);
  assert.equal(missing.wroteOutput, false);

  const unassigned = run(input => { input.rotationCastEvents.push({ skill: "earthquake", t: 58 }); });
  assert.notEqual(unassigned.status, 0);
  assert.match(unassigned.stderr, /unassigned rotation cast/);
  assert.equal(unassigned.wroteOutput, false);
});
```

- [ ] **Step 2: Run the CLI tests and verify the new tests fail**

Run:

```bash
node --test tools/wclplan/cli.test.js
```

Expected: FAIL because `rotationUsage`, `ratioPackLine`, and `importratiopack.txt` do not exist.

- [ ] **Step 3: Wire rotation calculation into `cli.js`**

Add the import:

```js
const { assignRotationEvents, summarizeRotation, buildRatioPackLine } = require("./rotation.js");
```

After final `detail`/`groups` are known and before any file is written:

```js
if (!Array.isArray(input.rotationCastEvents)) {
  throw new Error("cli: rotationCastEvents must be an array of successful casts");
}
const rotationAssignments = assignRotationEvents(input.rotationCastEvents, detail.waves);
const rotationUsage = summarizeRotation(groups.length, input.rotationCastEvents, rotationAssignments);
```

After `routeKey` is computed:

```js
const ratioPackLine = buildRatioPackLine(rotationUsage, routeKey);
```

Extend summary without removing current fields:

```js
const summary = {
  meta: input.meta || {}, granularity, groups, routeKey, waveUsage, lines, packLine,
  waves: detail.waves, castEvents: casts, castAssignments: assignments, deaths, warnings,
  rotationCastEvents: input.rotationCastEvents,
  rotationAssignments,
  rotationUsage,
  ratioPackLine,
};
```

Write the new artifact before logging success:

```js
fs.writeFileSync(path.join(outDir, "importratiopack.txt"), ratioPackLine + "\n");
```

Update `USAGE` and the success path list to name `rotationCastEvents` and `importratiopack.txt`.

- [ ] **Step 4: Run focused and full Node tests**

Run:

```bash
node --test tools/wclplan/rotation.test.js tools/wclplan/cli.test.js
node --test tools/wclplan/*.test.js
```

Expected: all tests PASS; existing group and cooldown plan assertions remain unchanged.

- [ ] **Step 5: Commit if explicitly authorized**

```bash
git add tools/wclplan/cli.js tools/wclplan/cli.test.js
git commit -m "feat: export rotation ratios with WCL plans"
```

---

### Task 3: Report verification and copy control

**Files:**
- Modify: `tools/wclplan/report.js:16-62,74-120,215-315`
- Modify: `tools/wclplan/report.test.js:15-104`

- [ ] **Step 1: Add ratio artifacts to the report fixture**

In `report.test.js`, define:

```js
const rotationUsage = [
  { elementalBlast: 8, earthquake: 2 },
  { elementalBlast: 1, earthquake: 9 },
];
```

Add to `summary`:

```js
rotationCastEvents: [],
rotationAssignments: [],
rotationUsage,
ratioPackLine: `/npt importratiopack ${routeKey} 1:e8q2;2:e1q9`,
```

Write the paired file in `fixture()`:

```js
fs.writeFileSync(path.join(outDir, "importratiopack.txt"),
  (data.ratioPackFile ?? data.summary.ratioPackLine) + "\n");
```

Add tests:

```js
test("renders per-wave ratio text and the paired ratio import command", t => {
  const html = render(fixture(t));
  assert.match(tableRows(html)[0], /8:2/);
  assert.match(tableRows(html)[1], /1:9/);
  assert.ok(html.includes("/npt importratiopack"));
  assert.match(html, /复制配比整包/);
});

test("rejects ratio usage and ratio artifact mismatches", t => {
  expectRejected(t, d => { d.summary.rotationUsage.pop(); }, /rotationUsage/);
  expectRejected(t, d => { d.ratioPackFile = "/npt importratiopack deadbeef 1:e1q1"; }, /ratioPackLine/);
});
```

- [ ] **Step 2: Run report tests and verify failure**

Run:

```bash
node --test tools/wclplan/report.test.js
```

Expected: FAIL because the report does not read or render the ratio artifact.

- [ ] **Step 3: Validate and render only persisted ratio output**

In `main()`, read:

```js
const ratioPackText = fs.readFileSync(path.join(outDir, "importratiopack.txt"), "utf8");
```

Pass it to `validateSummary()` and add these checks:

```js
if (!Array.isArray(summary.rotationCastEvents) ||
    !Array.isArray(summary.rotationAssignments) ||
    !Array.isArray(summary.rotationUsage)) fail("rotation fields must be arrays");
if (summary.rotationUsage.length !== summary.groups.length) fail("rotationUsage / groups length mismatch");
if (summary.rotationAssignments.length !== summary.rotationCastEvents.length) {
  fail("rotationAssignments / rotationCastEvents length mismatch");
}
for (const usage of summary.rotationUsage) {
  if (!usage || !Number.isInteger(usage.elementalBlast) || usage.elementalBlast < 0 ||
      !Number.isInteger(usage.earthquake) || usage.earthquake < 0) {
    fail("rotationUsage must contain nonnegative integer counts");
  }
}
if (typeof summary.ratioPackLine !== "string" ||
    ratioPackText.replace(/\r?\n$/, "") !== summary.ratioPackLine) {
  fail("ratioPackLine / importratiopack.txt mismatch");
}
```

Add a ratio cell to each wave row using exact counts for the normalized label:

```js
const rotation = summary.rotationUsage[i];
const rotationTotal = rotation.elementalBlast + rotation.earthquake;
const elementalTenths = rotationTotal === 0 ? null
  : Math.floor(rotation.elementalBlast / rotationTotal * 10 + 0.5);
const ratioText = elementalTenths === null ? "—" : elementalTenths + ":" + (10 - elementalTenths);
```

Add one table header `技能配比` and one escaped cell containing `ratioText`. Add a copy row for `summary.ratioPackLine` labelled `复制配比整包` next to the existing plan import section.

- [ ] **Step 4: Run report and full Node tests**

Run:

```bash
node --test tools/wclplan/report.test.js
node --test tools/wclplan/*.test.js
```

Expected: all tests PASS and no `NaN`, `Infinity`, or `undefined` appears in generated HTML.

- [ ] **Step 5: Commit if explicitly authorized**

```bash
git add tools/wclplan/report.js tools/wclplan/report.test.js
git commit -m "feat: show rotation ratios in WCL reports"
```

---

### Task 4: Character-scoped ratio storage

**Files:**
- Create: `Modules/SpellRatioData.lua`
- Create: `spec/SpellRatioData_spec.lua`
- Modify: `Core.lua:88-102`

- [ ] **Step 1: Write failing storage and ratio tests**

Create `spec/SpellRatioData_spec.lua`:

```lua
local mocks = require("wow_mocks")

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    env.dbChar.rotationRatios = {}
    MDT_NPT.CooldownData = {
      computePullFingerprint = function(pull) return pull and pull.fp end,
    }
    mocks.loadSource("Modules/SpellRatioData.lua")
    fn(env, MDT_NPT.SpellRatioData)
  end)
end

describe("SpellRatioData", function()
  before_each(function() mocks.reset() end)

  it("stores zero values and returns normalized tenths", function()
    scenario(function(_, data)
      assert.is_true(data:Set("uid", 1, 8, 2, "fp1"))
      assert.same({ elementalBlast = 8, earthquake = 2, fingerprint = "fp1" }, data:Get("uid", 1))
      assert.same({ elementalBlast = 8, earthquake = 2 }, data:RatioTenths(data:Get("uid", 1)))
      assert.is_true(data:Set("uid", 2, 0, 0, "fp2"))
      assert.is_nil(data:RatioTenths(data:Get("uid", 2)))
    end)
  end)

  it("distinguishes absent data and rejects corrupt records", function()
    scenario(function(env, data)
      assert.is_nil(data:Get("uid", 1))
      env.dbChar.rotationRatios.uid = {
        [1] = { elementalBlast = -1, earthquake = 2, fingerprint = "fp" },
      }
      assert.is_nil(data:Get("uid", 1))
    end)
  end)

  it("verifies the current pull fingerprint", function()
    scenario(function(_, data)
      data:Set("uid", 1, 1, 3, "same")
      assert.is_true(data:Verify("uid", 1, { fp = "same" }))
      assert.is_false(data:Verify("uid", 1, { fp = "different" }))
    end)
  end)

  it("atomically replaces all rows for one route", function()
    scenario(function(_, data)
      data:Set("uid", 9, 9, 9, "old")
      assert.is_true(data:ReplaceRoute("uid", {
        [1] = { elementalBlast = 1, earthquake = 2, fingerprint = "a" },
        [2] = { elementalBlast = 0, earthquake = 0, fingerprint = "b" },
      }))
      assert.is_nil(data:Get("uid", 9))
      assert.equals(2, data:Get("uid", 2).earthquake)
    end)
  end)
end)
```

- [ ] **Step 2: Run and verify failure**

Run:

```bash
node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioData_spec.lua
```

Expected: FAIL because `Modules/SpellRatioData.lua` does not exist.

- [ ] **Step 3: Implement `SpellRatioData`**

Create `Modules/SpellRatioData.lua` with these complete public behaviors:

```lua
local MDT_NPT = MDT_NPT
local CooldownData = MDT_NPT.CooldownData
local SpellRatioData = {}
local warned = false

local function dbChar()
  return MDT_NPT:GetDBChar()
end

local function validCount(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end

function SpellRatioData:Get(uid, pullIndex)
  local dc = dbChar()
  local row = dc and dc.rotationRatios and dc.rotationRatios[uid]
    and dc.rotationRatios[uid][pullIndex]
  if not row then return nil end
  if not validCount(row.elementalBlast) or not validCount(row.earthquake)
    or type(row.fingerprint) ~= "string" then
    dc.rotationRatios[uid][pullIndex] = nil
    if not warned then
      warned = true
      print("|cff00ff00[MDT]|r Spell ratio data was invalid and has been removed.")
    end
    return nil
  end
  return row
end

function SpellRatioData:Set(uid, pullIndex, elementalBlast, earthquake, fingerprint)
  if type(uid) ~= "string" or uid == "" or not validCount(pullIndex) or pullIndex < 1
    or not validCount(elementalBlast) or not validCount(earthquake)
    or type(fingerprint) ~= "string" then return false end
  local dc = dbChar()
  if not dc then return false end
  dc.rotationRatios = dc.rotationRatios or {}
  dc.rotationRatios[uid] = dc.rotationRatios[uid] or {}
  dc.rotationRatios[uid][pullIndex] = {
    elementalBlast = elementalBlast,
    earthquake = earthquake,
    fingerprint = fingerprint,
  }
  return true
end

function SpellRatioData:ReplaceRoute(uid, rows)
  local dc = dbChar()
  if not dc or type(uid) ~= "string" or uid == "" or type(rows) ~= "table" then return false end
  dc.rotationRatios = dc.rotationRatios or {}
  dc.rotationRatios[uid] = rows
  return true
end

function SpellRatioData:Verify(uid, pullIndex, pull, enemies)
  local row = self:Get(uid, pullIndex)
  if not row then return false end
  local live = CooldownData.computePullFingerprint(pull, enemies)
  return live ~= nil and live == row.fingerprint
end

function SpellRatioData:RatioTenths(row)
  if not row then return nil end
  local total = row.elementalBlast + row.earthquake
  if total == 0 then return nil end
  local elementalBlast = math.floor(row.elementalBlast / total * 10 + 0.5)
  return { elementalBlast = elementalBlast, earthquake = 10 - elementalBlast }
end

MDT_NPT.SpellRatioData = SpellRatioData
```

Add to `Core.lua` character defaults:

```lua
rotationRatios = {},
```

- [ ] **Step 4: Run focused storage tests**

Run:

```bash
node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioData_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Commit if explicitly authorized**

```bash
git add Core.lua Modules/SpellRatioData.lua spec/SpellRatioData_spec.lua
git commit -m "feat: store route-bound spell ratios"
```

---

### Task 5: Atomic in-game ratio import

**Files:**
- Create: `Modules/ImportRatio.lua`
- Create: `spec/ImportRatio_spec.lua`
- Modify: `Modules/Slash.lua:222-269`

- [ ] **Step 1: Write failing parser/import/slash tests**

Create `spec/ImportRatio_spec.lua`:

```lua
local mocks = require("wow_mocks")

local function presetWith(pulls)
  return {
    uid = "uid1",
    value = { currentDungeonIdx = 1, currentSublevel = 1, currentPull = 1, pulls = pulls },
  }
end

local function enemiesFor(...)
  local enemies = {}
  for n = 1, select("#", ...) do
    for idx in pairs(select(n, ...)) do enemies[idx] = { clones = {} } end
  end
  return enemies
end

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    env.dbChar.rotationRatios = {}
    mocks.loadSource("Modules/CooldownData.lua")
    mocks.loadSource("Modules/ImportPlan.lua")
    mocks.loadSource("Modules/SpellRatioData.lua")
    mocks.loadSource("Modules/ImportRatio.lua")
    fn(env)
  end)
end

describe("ImportRatio", function()
  before_each(function() mocks.reset() end)

it("parses multi-digit counts including zero", function()
  scenario(function(env)
    local rows, err = MDT_NPT.ImportRatio.parsePack("1:e0q26;2:e12q3")
    assert.is_nil(err)
    assert.same({ wave = 1, elementalBlast = 0, earthquake = 26 }, rows[1])
    assert.same({ wave = 2, elementalBlast = 12, earthquake = 3 }, rows[2])
  end)
end)

it("rejects malformed, duplicate and incomplete packs", function()
  scenario(function(env)
    for _, pack in ipairs({ "", "1:e1", "1:q2e1", "1:e-1q2", "1:e1q2;1:e2q1", "1:e1q2!" }) do
      local rows, err = MDT_NPT.ImportRatio.parsePack(pack)
      assert.is_nil(rows, pack)
      assert.is_string(err)
    end
  end)
end)

it("validates all waves and route key before replacing storage", function()
  scenario(function(env)
    local preset = presetWith({ { [3] = { 1 } }, { [5] = { 1, 2 } } })
    MDT.GetCurrentPreset = function() return preset end
    MDT.dungeonEnemies = { [1] = enemiesFor(preset.value.pulls[1], preset.value.pulls[2]) }
    local key = MDT_NPT.ImportPlan.computeRouteKey(preset.value.pulls)
    local ok, err, count = MDT_NPT.ImportRatio:applyPack("1:e1q2;2:e0q0", key)
    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals(2, count)
    assert.equals(2, MDT_NPT.SpellRatioData:Get("uid1", 1).earthquake)

    local bad = MDT_NPT.ImportRatio:applyPack("1:e9q9", key)
    assert.is_false(bad)
    assert.equals(2, MDT_NPT.SpellRatioData:Get("uid1", 1).earthquake)
  end)
end)

it("dispatches /npt importratiopack", function()
  scenario(function(env)
    local preset = presetWith({ { [3] = { 1 } } })
    MDT.GetCurrentPreset = function() return preset end
    MDT.dungeonEnemies = { [1] = enemiesFor(preset.value.pulls[1]) }
    SlashCmdList = {}
    mocks.loadSource("Modules/Slash.lua")
    local key = MDT_NPT.ImportPlan.computeRouteKey(preset.value.pulls)
    MDT_NPT:Slash("importratiopack " .. key .. " 1:e8q2")
    assert.equals(8, MDT_NPT.SpellRatioData:Get("uid1", 1).elementalBlast)
  end)
end)
end)
```

- [ ] **Step 2: Run and verify failure**

Run:

```bash
node .tmp-npt-task/luaenv/minibusted.js spec/ImportRatio_spec.lua
```

Expected: FAIL because `ImportRatio` is absent.

- [ ] **Step 3: Implement parser and atomic importer**

Create `Modules/ImportRatio.lua`:

```lua
local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT
local ImportPlan = MDT_NPT.ImportPlan
local CooldownData = MDT_NPT.CooldownData
local SpellRatioData = MDT_NPT.SpellRatioData
local ImportRatio = {}

function ImportRatio.parsePack(pack)
  if type(pack) ~= "string" or pack == "" then return nil, "empty pack" end
  local rows, seen = {}, {}
  for token in pack:gmatch("[^;]+") do
    local waveText, elementalText, earthquakeText = token:match("^(%d+):e(%d+)q(%d+)$")
    local wave = tonumber(waveText or "")
    local elementalBlast = tonumber(elementalText or "")
    local earthquake = tonumber(earthquakeText or "")
    if not wave or wave < 1 or wave % 1 ~= 0 or elementalBlast == nil or earthquake == nil then
      return nil, "bad token: " .. token
    end
    if seen[wave] then return nil, "duplicate wave in pack: " .. wave end
    seen[wave] = true
    rows[#rows + 1] = { wave = wave, elementalBlast = elementalBlast, earthquake = earthquake }
  end
  if #rows == 0 then return nil, "empty pack" end
  return rows
end

function ImportRatio:applyPack(pack, routeKey)
  local rows, parseErr = ImportRatio.parsePack(pack)
  if not rows then return false, parseErr end
  local preset = MDT and MDT.GetCurrentPreset and MDT:GetCurrentPreset()
  if not preset or not preset.uid or preset.uid == "" then
    return false, "no current preset uid; import the MDT route first"
  end
  local pulls = preset.value and preset.value.pulls
  if not pulls then return false, "current preset has no pulls" end
  local liveKey = ImportPlan.computeRouteKey(pulls)
  if liveKey ~= routeKey then
    return false, "route key mismatch: pack says " .. tostring(routeKey) .. ", current preset is " .. liveKey
  end
  if #rows ~= #pulls then return false, "pack must contain every route wave" end
  local byWave = {}
  for _, row in ipairs(rows) do
    if not pulls[row.wave] then return false, "preset has no pull " .. row.wave end
    byWave[row.wave] = row
  end
  for wave = 1, #pulls do
    if not byWave[wave] then return false, "pack is missing pull " .. wave end
  end
  local enemies = MDT.dungeonEnemies and MDT.dungeonEnemies[preset.value.currentDungeonIdx]
  local replacement = {}
  for wave = 1, #pulls do
    local row = byWave[wave]
    replacement[wave] = {
      elementalBlast = row.elementalBlast,
      earthquake = row.earthquake,
      fingerprint = CooldownData.computePullFingerprint(pulls[wave], enemies),
    }
  end
  if not SpellRatioData:ReplaceRoute(preset.uid, replacement) then return false, "ratio storage unavailable" end
  return true, nil, #rows
end

MDT_NPT.ImportRatio = ImportRatio
```

Add a late-bound slash handler to `Modules/Slash.lua`:

```lua
local function handleImportRatioPack(rest)
  local routeKey, pack = rest:match("^(%S+)%s+(%S+)$")
  if not routeKey or not pack then
    print(PREFIX..": usage: "..CMD_COLOR.."/npt importratiopack <routeKey> <wave:e<count>q<count>;...>|r")
    return
  end
  local ok, err, n = MDT_NPT.ImportRatio:applyPack(pack, routeKey)
  if not ok then
    print(PREFIX..": importratiopack failed: "..tostring(err))
    return
  end
  print(PREFIX..": imported spell ratios for "..n.." pulls.")
end
```

Register:

```lua
{ name = "importratiopack", usage = "importratiopack <routeKey> <pack>", help = "import WCL spell ratios for all pulls", handler = handleImportRatioPack },
```

- [ ] **Step 4: Run import tests**

Run:

```bash
node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioData_spec.lua spec/ImportRatio_spec.lua spec/ImportPlan_spec.lua
```

Expected: PASS; existing cooldown-plan imports remain unchanged.

- [ ] **Step 5: Commit if explicitly authorized**

```bash
git add Modules/ImportRatio.lua Modules/Slash.lua spec/ImportRatio_spec.lua
git commit -m "feat: import complete WCL spell ratio packs"
```

---

### Task 6: Draggable masked ratio orb

**Files:**
- Create: `Modules/SpellRatioOrb.lua`
- Create: `spec/SpellRatioOrb_spec.lua`
- Modify: `spec/helpers/wow_mocks.lua:90-354`

- [ ] **Step 1: Extend mocks only with real WoW APIs used by the orb**

Add `SetClampedToScreen` to the generic widget:

```lua
function w:SetClampedToScreen(value) self.clamped = value end
```

Ensure the mock DB defaults include:

```lua
dbChar = { cooldownPotionID = 241308, cooldownPlans = {}, rotationRatios = {} },
db = { beacon = {
  showCooldownPlan = true,
  alertVoice = true,
  alertText = true,
  lustAlert = true,
  spellRatioOrb = true,
} },
```

Do not add invented APIs; `CreateMaskTexture`, `AddMaskTexture`, `SetTexture`, `SetHeight`, `SetPoint`, `C_Spell.GetSpellTexture`, and drag methods already exist in the mock.

- [ ] **Step 2: Write failing orb tests**

Create `spec/SpellRatioOrb_spec.lua` with this setup followed by the assertions below:

```lua
local mocks = require("wow_mocks")

local activePull = { [1] = { 1 } }

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    env.dbChar.rotationRatios = {}
    env.db.beacon.spellRatioOrb = true
    MDT_NPT.MDT = MDT
    MDT.GetCurrentPreset = function()
      return { uid = "uid1", value = { currentDungeonIdx = 1, pulls = { activePull } } }
    end
    MDT.dungeonEnemies = { [1] = { [1] = {} } }
    MDT_NPT.state = { active = true, currentNextPull = 1, presetUID = "uid1", dungeonIndex = 1 }
    MDT_NPT.CooldownData = { computePullFingerprint = function() return "fp" end }
    MDT_NPT.Beacon = { GetFrame = function() return UIParent end }
    mocks.loadSource("Modules/Theme.lua")
    mocks.loadSource("Modules/SpellRatioData.lua")
    mocks.loadSource("Modules/SpellRatioOrb.lua")
    fn(env, MDT_NPT.SpellRatioOrb)
  end)
end

local function seedActiveWave(_, elementalBlast, earthquake)
  MDT_NPT.SpellRatioData:Set("uid1", 1, elementalBlast, earthquake, "fp")
end

describe("SpellRatioOrb", function()
  before_each(function() mocks.reset() end)

it("renders exact 8:2 fill, label and dominant Elemental Blast icon", function()
  scenario(function(env, orb)
    seedActiveWave(env, 8, 2)
    orb:Update()
    local frame = orb:GetFrame()
    assert.is_true(frame:IsShown())
    assert.equals(48, frame.elementalFill:GetHeight())
    assert.equals(12, frame.earthquakeFill:GetHeight())
    assert.equals("8:2", frame.ratioText:GetText())
    assert.equals("spell:117014", frame.primaryIcon.texture)
    assert.is_true(frame.primaryIcon:IsShown())
    assert.is_false(frame.secondaryIcon:IsShown())
  end)
end)

it("shows both icons for equal raw counts", function()
  scenario(function(env, orb)
    seedActiveWave(env, 3, 3)
    orb:Update()
    local frame = orb:GetFrame()
    assert.equals("5:5", frame.ratioText:GetText())
    assert.equals("spell:117014", frame.primaryIcon.texture)
    assert.equals("spell:61882", frame.secondaryIcon.texture)
    assert.is_true(frame.secondaryIcon:IsShown())
  end)
end)

it("shows an empty orb without label or icons for imported zero-zero", function()
  scenario(function(env, orb)
    seedActiveWave(env, 0, 0)
    orb:Update()
    local frame = orb:GetFrame()
    assert.is_true(frame:IsShown())
    assert.equals(0, frame.elementalFill:GetHeight())
    assert.equals(0, frame.earthquakeFill:GetHeight())
    assert.is_false(frame.ratioText:IsShown())
    assert.is_false(frame.primaryIcon:IsShown())
    assert.is_false(frame.secondaryIcon:IsShown())
  end)
end)

it("hides for missing data, fingerprint mismatch, inactive tracking and non-elemental spec", function()
  scenario(function(env, orb)
    seedActiveWave(env, 8, 2)
    env.specID = 263
    orb:Update()
    assert.is_false(orb:GetFrame():IsShown())
  end)
end)

it("uses masks on both fills and persists Alt-gated drag position", function()
  scenario(function(env, orb)
    seedActiveWave(env, 8, 2)
    orb:Update()
    local frame = orb:GetFrame()
    assert.equals(frame.mask, frame.elementalFill.maskList[1])
    assert.equals(frame.mask, frame.earthquakeFill.maskList[1])
    assert.is_false(frame:IsMouseEnabled())
    env.alt = true
    frame.scripts.OnEvent(frame, "MODIFIER_STATE_CHANGED")
    assert.is_true(frame:IsMouseEnabled())
    frame.scripts.OnDragStop(frame)
    assert.is_not_nil(env.db.beacon.spellRatioOrbPos)
  end)
end)
end)
```

- [ ] **Step 3: Run and verify failure**

Run:

```bash
node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioOrb_spec.lua
```

Expected: FAIL because the orb module does not exist.

- [ ] **Step 4: Implement the orb module**

Create `Modules/SpellRatioOrb.lua`:

```lua
local MDT_NPT = MDT_NPT
local Theme = MDT_NPT.Theme
local SpellRatioData = MDT_NPT.SpellRatioData
local ORB_SIZE, INNER_SIZE, ICON_SIZE = 64, 60, 20
local ELEMENTAL_BLAST_ID, EARTHQUAKE_ID = 117014, 61882
local ELEMENTAL_COLOR = { 0.58, 0.28, 0.95, 1 }
local EARTHQUAKE_COLOR = { 0.95, 0.45, 0.08, 1 }
local MASK_TEXTURE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local SpellRatioOrb = {}
local frame

local function savePosition(f)
  local db = MDT_NPT:GetDB()
  if not (db and db.beacon) then return end
  local point, _, relativePoint, x, y = f:GetPoint()
  if point then db.beacon.spellRatioOrbPos = { point, relativePoint, x, y } end
end

local function finalizeMove(f)
  f:StopMovingOrSizing()
  savePosition(f)
end

local function ensureFrame()
  if frame then return frame end
  frame = CreateFrame("Frame", "MDTNPTSpellRatioOrb", UIParent)
  frame:SetSize(ORB_SIZE + ICON_SIZE + 8, ORB_SIZE + 18)
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:EnableMouse(false)

  frame.ring = frame:CreateTexture(nil, "BACKGROUND")
  frame.ring:SetSize(ORB_SIZE, ORB_SIZE)
  frame.ring:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  frame.outerMask = frame:CreateMaskTexture()
  frame.outerMask:SetTexture(MASK_TEXTURE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  frame.outerMask:SetAllPoints(frame.ring)
  frame.ring:AddMaskTexture(frame.outerMask)

  frame.inner = frame:CreateTexture(nil, "ARTWORK")
  frame.inner:SetSize(INNER_SIZE, INNER_SIZE)
  frame.inner:SetPoint("CENTER", frame.ring, "CENTER", 0, 0)
  frame.inner:SetColorTexture(0.03, 0.04, 0.06, 0.92)
  frame.mask = frame:CreateMaskTexture()
  frame.mask:SetTexture(MASK_TEXTURE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  frame.mask:SetAllPoints(frame.inner)
  frame.inner:AddMaskTexture(frame.mask)

  frame.elementalFill = frame:CreateTexture(nil, "OVERLAY")
  frame.elementalFill:SetWidth(INNER_SIZE)
  frame.elementalFill:SetPoint("TOP", frame.inner, "TOP", 0, 0)
  frame.elementalFill:SetColorTexture(unpack(ELEMENTAL_COLOR))
  frame.elementalFill:AddMaskTexture(frame.mask)

  frame.earthquakeFill = frame:CreateTexture(nil, "OVERLAY")
  frame.earthquakeFill:SetWidth(INNER_SIZE)
  frame.earthquakeFill:SetPoint("BOTTOM", frame.inner, "BOTTOM", 0, 0)
  frame.earthquakeFill:SetColorTexture(unpack(EARTHQUAKE_COLOR))
  frame.earthquakeFill:AddMaskTexture(frame.mask)

  frame.ratioText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  frame.ratioText:SetPoint("TOP", frame.ring, "BOTTOM", 0, -2)

  frame.primaryIcon = frame:CreateTexture(nil, "OVERLAY")
  frame.primaryIcon:SetSize(ICON_SIZE, ICON_SIZE)
  frame.primaryIcon:SetPoint("CENTER", frame.ring, "TOPRIGHT", 3, -3)
  frame.secondaryIcon = frame:CreateTexture(nil, "OVERLAY")
  frame.secondaryIcon:SetSize(ICON_SIZE, ICON_SIZE)
  frame.secondaryIcon:SetPoint("RIGHT", frame.primaryIcon, "LEFT", -2, 0)

  frame:SetScript("OnDragStart", function(self)
    self:StartMoving()
  end)
  frame:SetScript("OnDragStop", function(self)
    finalizeMove(self)
  end)
  local function applyClickThrough()
    local interactive = IsAltKeyDown() and true or false
    if not interactive and frame:IsMouseEnabled() then finalizeMove(frame) end
    frame:EnableMouse(interactive)
  end
  frame:RegisterEvent("MODIFIER_STATE_CHANGED")
  frame:SetScript("OnEvent", function(_, event)
    if event == "MODIFIER_STATE_CHANGED" then applyClickThrough() end
  end)
  applyClickThrough()

  local db = MDT_NPT:GetDB()
  local pos = db and db.beacon and db.beacon.spellRatioOrbPos
  if pos and pos[1] then
    frame:SetPoint(pos[1], UIParent, pos[2], pos[3] or 0, pos[4] or 0)
  else
    frame:SetPoint("LEFT", MDT_NPT.Beacon:GetFrame(), "RIGHT", 12, 0)
  end
  frame:Hide()
  return frame
end

function SpellRatioOrb:GetFrame()
  return frame or ensureFrame()
end

function SpellRatioOrb:Update()
  local db = MDT_NPT:GetDB()
  local state = MDT_NPT.state
  local specIndex = C_SpecializationInfo.GetSpecialization()
  local specID = specIndex and C_SpecializationInfo.GetSpecializationInfo(specIndex)
  if not (db and db.beacon and db.beacon.spellRatioOrb and state and state.active
      and state.currentNextPull and state.presetUID and specID == 262) then
    if frame then frame:Hide() end
    return
  end
  local preset = MDT_NPT.MDT:GetCurrentPreset(state.dungeonIndex)
  local pull = preset and preset.value and preset.value.pulls and preset.value.pulls[state.currentNextPull]
  local enemies = preset and MDT_NPT.MDT.dungeonEnemies
    and MDT_NPT.MDT.dungeonEnemies[preset.value.currentDungeonIdx]
  local row = SpellRatioData:Get(state.presetUID, state.currentNextPull)
  if not row or not SpellRatioData:Verify(state.presetUID, state.currentNextPull, pull, enemies) then
    if frame then frame:Hide() end
    return
  end

  local f = ensureFrame()
  Theme.Refresh()
  f.ring:SetColorTexture(unpack(Theme.colors.accent))
  local total = row.elementalBlast + row.earthquake
  if total == 0 then
    f.elementalFill:SetHeight(0)
    f.earthquakeFill:SetHeight(0)
    f.ratioText:Hide()
    f.primaryIcon:Hide()
    f.secondaryIcon:Hide()
    f:Show()
    return
  end

  local elementalRatio = row.elementalBlast / total
  f.elementalFill:SetHeight(INNER_SIZE * elementalRatio)
  f.earthquakeFill:SetHeight(INNER_SIZE * (1 - elementalRatio))
  local tenths = SpellRatioData:RatioTenths(row)
  f.ratioText:SetText(tenths.elementalBlast .. ":" .. tenths.earthquake)
  f.ratioText:Show()
  if row.elementalBlast == row.earthquake then
    f.primaryIcon:SetTexture(C_Spell.GetSpellTexture(ELEMENTAL_BLAST_ID))
    f.secondaryIcon:SetTexture(C_Spell.GetSpellTexture(EARTHQUAKE_ID))
    f.primaryIcon:Show()
    f.secondaryIcon:Show()
  else
    local id = row.elementalBlast > row.earthquake and ELEMENTAL_BLAST_ID or EARTHQUAKE_ID
    f.primaryIcon:SetTexture(C_Spell.GetSpellTexture(id))
    f.primaryIcon:Show()
    f.secondaryIcon:Hide()
  end
  f:Show()
end

MDT_NPT.SpellRatioOrb = SpellRatioOrb
```

Do not add a ticker; `UpdateAll()` owns refresh timing.

- [ ] **Step 5: Run focused UI tests**

Run:

```bash
node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioData_spec.lua spec/SpellRatioOrb_spec.lua
```

Expected: PASS.

- [ ] **Step 6: Commit if explicitly authorized**

```bash
git add Modules/SpellRatioOrb.lua spec/SpellRatioOrb_spec.lua spec/helpers/wow_mocks.lua
git commit -m "feat: add draggable spell ratio orb"
```

---

### Task 7: Runtime wiring, setting, localization and load order

**Files:**
- Modify: `Modules/load_modules.xml:18-27`
- Modify: `Core.lua:25-102,240-257`
- Modify: `Modules/Settings.lua:160-180`
- Modify: `Locales/enUS.lua`
- Modify: `Locales/zhCN.lua`
- Modify: `Locales/frFR.lua`
- Modify: `Locales/ruRU.lua`
- Modify: `spec/Locales_spec.lua`
- Modify: `spec/Core_alert_hook_spec.lua:5-81`
- Test: `spec/SpellRatioOrb_spec.lua`

- [ ] **Step 1: Add failing lifecycle/default/locale tests**

In `spec/Core_alert_hook_spec.lua`, add `orbCalls` to the local declaration, initialize it before loading `Core.lua`, and expose a stub:

```lua
orbCalls = 0
_G.MDT_NPT.SpellRatioOrb = {
  Update = function() orbCalls = orbCalls + 1 end,
}
```

Add these tests to the existing describe block:

```lua
it("UpdateAll 每次都驱动技能配比球", function()
  MDT_NPT:UpdateAll()
  MDT_NPT:UpdateAll()
  assert.equals(2, orbCalls)
end)

it("技能配比球模块缺席时 UpdateAll 不报错", function()
  _G.MDT_NPT.SpellRatioOrb = nil
  assert.has_no.errors(function() MDT_NPT:UpdateAll() end)
end)
```

Extend the existing default-value test with:

```lua
assert.is_true(capturedDefaults.global.beacon.spellRatioOrb)
assert.same({}, capturedDefaults.char.rotationRatios)
```

In `spec/Locales_spec.lua`, add both keys to the existing required-key table:

```lua
"Spell Ratio Orb",
"Spell Ratio Orb Tooltip",
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioOrb_spec.lua spec/Locales_spec.lua
```

Expected: FAIL for missing default/hook/locale keys.

- [ ] **Step 3: Add load order and runtime hook**

In `Modules/load_modules.xml`, load modules in this dependency order immediately after `ImportPlan.lua`:

```xml
<Script file='SpellRatioData.lua'/>
<Script file='ImportRatio.lua'/>
<Script file='SpellRatioOrb.lua'/>
```

In `Core.lua` global beacon defaults add:

```lua
spellRatioOrb = true,
```

`rotationRatios = {}` was already added to character defaults in Task 4; do not duplicate it.

At the end of `MDT_NPT:UpdateAll()` add a late lookup:

```lua
if MDT_NPT.SpellRatioOrb and MDT_NPT.SpellRatioOrb.Update then
  MDT_NPT.SpellRatioOrb:Update()
end
```

- [ ] **Step 4: Add setting and all locale strings**

In the Alerts section of `Settings.lua` add:

```lua
makeBeaconBool(category, "MDTNPT_SPELL_RATIO_ORB", L["Spell Ratio Orb"],
  "spellRatioOrb", L["Spell Ratio Orb Tooltip"],
  function()
    if MDT_NPT.SpellRatioOrb then MDT_NPT.SpellRatioOrb:Update() end
  end, true)
```

Use these translations:

```lua
-- enUS
L["Spell Ratio Orb"] = "Spell Ratio Orb"
L["Spell Ratio Orb Tooltip"] = "Show the imported WCL Elemental Blast and Earthquake ratio for the current pull."

-- zhCN
L["Spell Ratio Orb"] = "技能配比球"
L["Spell Ratio Orb Tooltip"] = "显示当前波导入的 WCL 元素冲击与地震术施法配比。"

-- frFR
L["Spell Ratio Orb"] = "Orbe de répartition des sorts"
L["Spell Ratio Orb Tooltip"] = "Affiche la répartition WCL importée entre Explosion élémentaire et Séisme pour la vague actuelle."

-- ruRU
L["Spell Ratio Orb"] = "Сфера соотношения заклинаний"
L["Spell Ratio Orb Tooltip"] = "Показывает импортированное из WCL соотношение Выброса стихий и Землетрясения для текущей группы."
```

- [ ] **Step 5: Run all Lua specs**

Run locally:

```bash
node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioData_spec.lua spec/ImportRatio_spec.lua spec/SpellRatioOrb_spec.lua spec/ImportPlan_spec.lua spec/ReadyTracker_spec.lua spec/Locales_spec.lua
```

Run in a Lua 5.1 environment when available:

```bash
busted
```

Expected: all specs PASS. Treat Lua 5.1 Busted as authoritative over fengari.

- [ ] **Step 6: Commit if explicitly authorized**

```bash
git add Core.lua Modules/load_modules.xml Modules/Settings.lua Locales/enUS.lua Locales/zhCN.lua Locales/frFR.lua Locales/ruRU.lua spec/Locales_spec.lua
git commit -m "feat: wire spell ratio orb into NPT"
```

---

### Task 8: Regenerate the current WCL export and verify in game

**Files:**
- Modify: `deploy/wcl-qQKAyptwcMg6n43x-f12/input.json`
- Regenerate: `deploy/wcl-qQKAyptwcMg6n43x-f12/summary.json`
- Regenerate: `deploy/wcl-qQKAyptwcMg6n43x-f12/route.mdt.txt`
- Regenerate: `deploy/wcl-qQKAyptwcMg6n43x-f12/importplan.txt`
- Regenerate: `deploy/wcl-qQKAyptwcMg6n43x-f12/importplan-pack.txt`
- Create: `deploy/wcl-qQKAyptwcMg6n43x-f12/importratiopack.txt`
- Regenerate: `deploy/wcl-qQKAyptwcMg6n43x-f12/report.html`

- [ ] **Step 1: Extract successful casts from the cached WCL response**

Run a one-shot Node command that reads `wcl-events.json`, uses `fight.startTime` as the origin, keeps only `type === "cast"`, and maps IDs:

```js
const SKILLS = { 117014: "elementalBlast", 61882: "earthquake" };
const rotationCastEvents = raw.events.casts.data
  .filter(event => event.type === "cast" && SKILLS[event.abilityGameID])
  .map(event => ({
    skill: SKILLS[event.abilityGameID],
    t: (event.timestamp - raw.fight.startTime) / 1000,
  }));
```

Write this array into `input.json` without changing the established `pullTimings`, `combatSegments`, `bossEncounters`, cooldown casts, deaths, route string, or metadata.

- [ ] **Step 2: Re-run the exporter and report**

Run:

```bash
node tools/wclplan/cli.js deploy/wcl-qQKAyptwcMg6n43x-f12/input.json deploy/wcl-qQKAyptwcMg6n43x-f12
node tools/wclplan/report.js deploy/wcl-qQKAyptwcMg6n43x-f12/input.json deploy/wcl-qQKAyptwcMg6n43x-f12
```

Expected:

- routeKey remains `3f891ced`;
- 10 final waves remain unchanged;
- `rotationUsage` equals:

```json
[
  { "elementalBlast": 0, "earthquake": 26 },
  { "elementalBlast": 1, "earthquake": 42 },
  { "elementalBlast": 1, "earthquake": 45 },
  { "elementalBlast": 1, "earthquake": 20 },
  { "elementalBlast": 29, "earthquake": 0 },
  { "elementalBlast": 1, "earthquake": 20 },
  { "elementalBlast": 28, "earthquake": 0 },
  { "elementalBlast": 0, "earthquake": 30 },
  { "elementalBlast": 0, "earthquake": 21 },
  { "elementalBlast": 17, "earthquake": 26 }
]
```

- `importratiopack.txt` contains all 10 waves, including any zero side.

- [ ] **Step 3: Run automated verification**

Run:

```bash
node --test tools/wclplan/*.test.js
node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioData_spec.lua spec/ImportRatio_spec.lua spec/SpellRatioOrb_spec.lua spec/ImportPlan_spec.lua spec/ReadyTracker_spec.lua spec/Locales_spec.lua
```

Expected: all tests PASS.

- [ ] **Step 4: Deploy to the local WoW AddOns directory with full hash verification**

Use the repository deployment script, not incremental copy:

```powershell
powershell -ExecutionPolicy Bypass -File tools/Deploy-Robocopy.ps1
```

Expected: deployment completes and the script reports no source/destination hash mismatch.

- [ ] **Step 5: Perform mandatory in-game UI verification**

1. `/reload`.
2. Import `route.mdt.txt` into MDT and select the imported preset.
3. Paste `importplan-pack.txt`, then paste `importratiopack.txt`.
4. Run `/npt start last`.
5. Verify wave 1 is orange-only with `0:10`, wave 5 is purple-only with `10:0`, and wave 10 is a mixed orb near `4:6`.
6. Advance, skip and revert waves; verify the orb follows the same current pull as NPT Plan.
7. Hold Alt, drag the orb, release Alt mid-drag, `/reload`, and verify the position persists.
8. Verify the window hides when tracking stops, when the setting is disabled, and on a non-Elemental specialization.
9. Verify an imported `0:0` fixture shows only the dark empty orb.

- [ ] **Step 6: Inspect repository changes**

Run:

```bash
git status --short
git diff --stat
git diff --check
```

Expected: only planned source, test, design/plan and regenerated export files changed; `git diff --check` exits 0.

- [ ] **Step 7: Commit if explicitly authorized**

Stage exact files only after reviewing `git status` and the full diff, then create a new commit without amending or skipping hooks.
