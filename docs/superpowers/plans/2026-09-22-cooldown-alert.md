# 下一波冷却提醒（语音 + 屏幕中部文字）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 波次推进时用游戏内置 TTS 念出下一波计划里要开的爆发技能，并在屏幕中部显示同一句文字。

**Architecture:** 两个新模块 —— `CooldownAlert.lua`（纯逻辑：何时说、说什么）与 `AlertText.lua`（UI 薄层：怎么显示）。触发点只有一处：`MDT_NPT:UpdateAll()`，它是 `Start`/`Stop`/力量值推进/手动 mark/skip/revert 的唯一汇聚点。播报经 0.75 秒可取消去抖定时器，去重键为 `presetUID#pullIndex`。

**Tech Stack:** WoW 12.1 (Interface 120100) Lua 5.1、`C_VoiceChat.SpeakText`、AnimationGroup、AceDB-3.0、busted 2.x（CI）/ fengari minibusted（本地）。

**设计文档:** `docs/superpowers/specs/2026-09-22-cooldown-alert-design.md`（下称「设计 §N」）

---

## 已知既有失败基线（不要修，与本功能无关）

在 `6b5c157`（本功能开工前的 main）上，本地 fengari 跑 `spec/CooldownData_spec.lua`
与 `spec/CooldownPlanRender_spec.lua` 已经是 **32 passed / 3 failed**。已用「替换回
baseline 版 wow_mocks 再跑」验证过：失败集合与本功能的改动无关，且是确定性的、
与 Lua 版本无关（不是 fengari 假象）。

三个失败：

1. `CooldownData 单波使用次数 / sanitize 钳制越界与非整数且丢弃非数字但保留条目`
   —— expected 3, got 4
2. `CooldownPlanRender 真实渲染序号 / 基线真实入口维持当前与预览尺寸和独立倒计时`
   —— expected 2, got 3
3. `CooldownPlanRender 真实渲染序号 / 嗜血格纯规划标注：无冷却扫过无倒计时无就绪辉光`
   —— expected false, got true

第 1 个的根因已定位：`spec/CooldownData_spec.lua:264-278` 调
`getActiveEntries(dbChar, "a", 4)` 后断言 pull 1/2/3 的 `uses` 被钳制，但
`getPullPlan`（`Modules/CooldownData.lua:154-169`）只清洗**被请求的那一波**；
`getUseOrdinal` 走早先波次时只调 `findPlanEntry` + `entryUses`，都不写回钳制值。
所以 `plans[1].entries[1].uses` 恒为 4。

**决定（用户 2026-09-23）**：这三个失败留给 `renwind`（它们来自其 2026-09-21 的
`ee6b01a` / `0acb93d`），本计划不修。判断「测试写错了」还是「产品代码回归了」
需要原作者的意图，尤其第 3 个看起来像 `hideCD` 的真实回归。

**因此本计划的验收标准是「不新增失败」，不是「全绿」。**
Task 8 Step 5 的全量回归，预期结果就是这 3 个失败依旧、且只有这 3 个。
任何实现者看到这 3 个失败都**不要**去修，也**不要**报 BLOCKED。

## 实现期修正：C_Timer.After 不可取消

计划 Task 5 原本用 `C_Timer.After` 排定去抖定时器并保存句柄。**零售客户端的
`C_Timer.After` 不返回句柄**，只有 `C_Timer.NewTimer` 返回可 `:Cancel()` 的句柄
（`Core.lua:292` 的 `NewTicker` 同理）。原写法下 `pending` 恒为 nil，去抖静默失效，
中途开局会连播两条、`/npt stop` 也压不住已排定的播报。

之所以没被测试抓到：Task 1 的 mock 给 `After` 臆造了返回值——和 commit `ee6b01a`
的臆造 mock 方法同类，只是发生在返回值上。已改为 `NewTimer`，并把 mock 的 `After`
修正为不返回任何值。

## 测试命令

- 本地单个 spec：`node .tmp-npt-task/luaenv/minibusted.js spec/CooldownAlert_spec.lua`
  （必须在仓库根目录执行；退出码非 0 = 有失败）
- 本地多个 spec：把路径依次追加到同一条命令后面
- **`spec/MDTAdapter_spec.lua` 必须单独跑**：它断言 `assert.is_nil(_G.MDT)`，混跑会被其他 spec 的 mock 污染而假失败
- CI 全量：`busted`（Lua 5.1 + busted 2.x，本地绿不代表 CI 绿，最终以 CI 为准）

## 关键既有事实（实现时不要重新推导）

| 事实 | 位置 |
|---|---|
| `getActiveEntries` 返回顺序 = seed 顺序 = `[1]升腾 [2]爆发药水 [3]嗜血` | `Modules/CooldownData.lua:13-44`、`:222-237` |
| 图标行**右对齐**：entry 1 贴右边缘，后续向左堆 → 视觉左→右是 `[嗜血][药水][升腾]` | `Modules/CooldownPlanRender.lua:198-211` |
| `UpdateAll()` 是所有状态变更的唯一汇聚点 | `Core.lua:227-237` |
| `Stop()` 先置 `state = nil` 再调 `UpdateAll()` | `Core.lua:303-319` |
| `SkipTo` 直接赋值 `currentNextPull`，不走 `recomputeNextPull` | `Modules/API.lua:83` |
| `getPlanKey(state)` 读 `state.presetUID`，空则返回 nil | `Modules/CooldownData.lua:87-94` |
| `Theme.GetFontPath()` 公开，无 EUI 时返回 nil | `Modules/Theme.lua:247-249` |
| `Theme.RegisterRefreshCallback(fn)` 公开 | `Modules/Theme.lua:253-257` |
| 12.x 没有 `FontString:SetOutlined`，描边走 `SetFont` 的 flags | commit `ee6b01a` |
| `makeBeaconBool(category, variable, name, key, tooltip, onChange, defaultValue)` | `Modules/Settings.lua:39-53` |
| 本地化：enUS 无 locale 守卫、是基底；zhCN/ruRU/frFR 有 `if locale ~= X then return end` | `Locales/enUS.lua:1-3`、`Locales/zhCN.lua:1-3` |

---

## Task 1: 扩展 `wow_mocks` 的运行时（TTS / 定时器 / 动画 / UIParent）

后续所有 spec 都依赖这些 mock，先落地并确认没打破既有测试。

**Files:**
- Modify: `spec/helpers/wow_mocks.lua`

- [ ] **Step 1: 在 `withCooldownRuntime` 的 `names` 列表里登记新全局**

`names` 是保存/恢复白名单，漏登记会污染其他 spec 文件（同一进程共享全局）。找到：

```lua
  local names = {
    "C_SpecializationInfo", "C_SpellBook", "Enum", "C_Spell", "C_Item", "C_Timer",
    "GetTime", "GetPhysicalScreenSize", "CreateFrame", "EllesmereUI", "unpack",
    "IsControlKeyDown", "MDTNPTCooldownPlanMixin",
  }
```

改为：

```lua
  local names = {
    "C_SpecializationInfo", "C_SpellBook", "Enum", "C_Spell", "C_Item", "C_Timer",
    "GetTime", "GetPhysicalScreenSize", "CreateFrame", "EllesmereUI", "unpack",
    "IsControlKeyDown", "MDTNPTCooldownPlanMixin",
    "C_VoiceChat", "C_TTSSettings", "UIParent", "GameFontNormalLarge", "GetLocale",
  }
```

- [ ] **Step 2: 给 `env` 增加记录表**

找到：

```lua
  local env = {
    specID = 262, time = 100, tickers = {},
    dbChar = { cooldownPotionID = 241308, cooldownPlans = {} },
    db = { beacon = { showCooldownPlan = true } },
    cooldown = { isEnabled = true, isActive = false, startTime = 0, duration = 0 },
  }
```

改为：

```lua
  local env = {
    specID = 262, time = 100, tickers = {},
    dbChar = { cooldownPotionID = 241308, cooldownPlans = {} },
    db = { beacon = { showCooldownPlan = true, alertVoice = true, alertText = true } },
    cooldown = { isEnabled = true, isActive = false, startTime = 0, duration = 0 },
    -- 冷却提醒（设计 §12.1）
    spoken = {},        -- 每次 SpeakText 的参数快照
    shown = {},         -- 每次 AlertText:Show 的文本
    timers = {},        -- C_Timer.After / NewTimer 排定的定时器
    animations = {},    -- 每个 CreateAnimationGroup 的产物
    ttsVoices = { { voiceID = 7, name = "Test Voice" } },
    tts = { voiceOptionID = 7, rate = 0, volume = 80 },
  }
  -- 手动触发所有未取消的 After 定时器；去抖断言全靠它，不依赖真实时间。
  function env.fireTimers()
    local due = env.timers
    env.timers = {}
    for _, t in ipairs(due) do
      if not t.cancelled then t.fn(t) end
    end
  end
```

- [ ] **Step 3: 给 widget 补动画与排版方法**

在 `widget(kind, parent, layer, font)` 内部，`function w:CreateFontString(...)` **之前**插入：

```lua
    function w:SetFrameStrata(strata) self.strata = strata end
    function w:SetJustifyH(j) self.justifyH = j end
    function w:SetJustifyV(j) self.justifyV = j end
    function w:SetWordWrap(wrap) self.wordWrap = wrap end
    function w:CreateAnimationGroup()
      local group = { animations = {}, playing = false, plays = 0, stops = 0 }
      function group:CreateAnimation(kind)
        local a = { kind = kind }
        function a:SetOrder(n) self.order = n end
        function a:SetFromAlpha(v) self.from = v end
        function a:SetToAlpha(v) self.to = v end
        function a:SetDuration(d) self.duration = d end
        self.animations[#self.animations + 1] = a
        return a
      end
      function group:Play() self.playing = true; self.plays = self.plays + 1 end
      function group:Stop() self.playing = false; self.stops = self.stops + 1 end
      function group:IsPlaying() return self.playing end
      function group:SetOnFinished(fn) self.onFinished = fn end
      -- 仅测试用：真实 AnimationGroup 没有 Finish。下划线前缀提醒它不是客户端 API，
      -- 产品代码绝不可调用（参见 commit ee6b01a 关于「臆造 mock 方法」的教训）。
      function group:_testFinish()
        self.playing = false
        if self.onFinished then self.onFinished() end
      end
      env.animations[#env.animations + 1] = group
      return group
    end
```

- [ ] **Step 4: 装上 TTS / 定时器 / 字体 / UIParent 全局**

在 `pcall(function()` 内部，找到 `_G.C_Timer = { NewTicker = ... }` 整段，替换为：

```lua
    _G.C_Timer = {
      NewTicker = function(_, callback)
        local ticker = { callback = callback, Cancel = function(self) self.cancelled = true end }
        env.tickers[#env.tickers + 1] = ticker
        return ticker
      end,
      -- 零售客户端的 After 不返回句柄，取消不了；要可取消必须用 NewTimer。
      -- 本机 AddOns 里没有任何插件捕获 After 的返回值，而 NewTimer 的句柄到处
      -- 被 :Cancel()。曾经让 After 返回句柄，于是去抖失效的 bug 在 spec 里全绿
      -- ——和 commit ee6b01a 的臆造 mock 方法是同一类陷阱，只是发生在返回值上。
      After = function(delay, fn)
        env.timers[#env.timers + 1] = { delay = delay, fn = fn }
      end,
      NewTimer = function(delay, fn)
        local timer = { delay = delay, fn = fn, Cancel = function(self) self.cancelled = true end }
        env.timers[#env.timers + 1] = timer
        return timer
      end,
    }
```

紧接着，在 `_G.Enum = { SpellBookSpellBank = { Player = 0 } }` 那一行改为：

```lua
    _G.Enum = { SpellBookSpellBank = { Player = 0 }, TtsVoiceType = { Standard = 0 } }
```

然后在 `_G.CreateFrame = function(kind, _, parent) return widget(kind, parent) end` **之后**追加：

```lua
    _G.C_VoiceChat = {
      SpeakText = function(voiceID, text, rate, volume, overlap)
        env.spoken[#env.spoken + 1] = {
          voiceID = voiceID, text = text, rate = rate, volume = volume, overlap = overlap,
        }
      end,
      GetTtsVoices = function() return env.ttsVoices end,
      StopSpeakingText = function() end,
    }
    _G.C_TTSSettings = {
      GetVoiceOptionID = function() return env.tts.voiceOptionID end,
      GetSpeechRate = function() return env.tts.rate end,
      GetSpeechVolume = function() return env.tts.volume end,
    }
    -- AlertText 的字体回落路径会调 GameFontNormalLarge:GetFont()；不存在的话
    -- 回落分支的断言会因为 nil 索引而假绿。
    _G.GameFontNormalLarge = { GetFont = function() return "Fonts\\blizzard.ttf", 16, "" end }
    _G.GetLocale = function() return "enUS" end
    _G.UIParent = widget("Frame", nil)
    _G.MDT_NPT.AlertText = {
      Show = function(_, text) env.shown[#env.shown + 1] = text end,
      Hide = function() end,
    }
```

> 说明：`MDT_NPT.AlertText` 桩放在 mock 里，`CooldownAlert_spec` 就能只断言 `env.shown`
> 而不必加载真实 UI 模块；`AlertText_spec` 会在自己的 `loadSource` 之后覆盖掉它。

- [ ] **Step 5: 跑既有 spec 确认没打破**

Run:
```bash
node .tmp-npt-task/luaenv/minibusted.js spec/CooldownData_spec.lua spec/CooldownPlanRender_spec.lua spec/CooldownPlanEditor_spec.lua spec/State_spec.lua spec/Scenario_spec.lua
```
Expected: 全部 PASS，退出码 0

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/MDTAdapter_spec.lua`
Expected: PASS（单独跑）

- [ ] **Step 6: Commit**

```bash
git add spec/helpers/wow_mocks.lua
git commit -m "test: mock the TTS, deferred-timer and animation surface

Cooldown alerts speak through C_VoiceChat.SpeakText and fade through an
AnimationGroup, and the debounce that keeps a mid-key start from
announcing twice needs C_Timer.After handles a test can fire by hand.
Register every new global in the save/restore list so specs keep running
in one shared process without leaking into each other."
```

---

## Task 2: 本地化键 + 完整性守卫

**为什么先做**：`wow_mocks` 的 `MDT_NPT.L` 带 `__index = function(_, k) return k end`，
**缺键时返回键名而不是 nil**，所以普通 spec 抓不到「忘了加 `L["Bloodlust"]`」——
真实客户端里那会 `format` 出 `下一波nil`，甚至在 `:format(nil)` 上直接抛错。
这个 task 用真实 locale 文件补上这道防线。

**Files:**
- Modify: `Locales/enUS.lua`（追加到文件末尾）
- Modify: `Locales/zhCN.lua`（插在既有冷却计划键之后、`NPC_ZH` 块之前）
- Test: `spec/Locales_spec.lua`（新建）

- [ ] **Step 1: 写失败的测试**

新建 `spec/Locales_spec.lua`：

```lua
local mocks = require("wow_mocks")

-- 用真实 locale 文件替换 mock 的恒等 L 表：mock 的 __index 会把缺键伪装成命中，
-- 只有真表才能暴露「忘了加条目」。
local function loadRealLocale(locale)
  MDT_NPT.L = {}
  _G.GetLocale = function() return locale end
  mocks.loadSource("Locales/enUS.lua")
  if locale ~= "enUS" then mocks.loadSource("Locales/" .. locale .. ".lua") end
  return MDT_NPT.L
end

describe("本地化完整性", function()
  before_each(function() mocks.reset() end)

  it("每个冷却 seed 名在英文基底里都有条目", function()
    mocks.withCooldownRuntime(function()
      local L = loadRealLocale("enUS")
      mocks.loadSource("Modules/CooldownData.lua")
      local seeds = MDT_NPT.CooldownData.getSeedEntries()
      assert.equals(3, #seeds)
      for _, seed in ipairs(seeds) do
        assert.is_not_nil(L[seed.name])
      end
    end)
  end)

  it("zhCN 把 seed 名与提醒模板都译成中文", function()
    mocks.withCooldownRuntime(function()
      local L = loadRealLocale("zhCN")
      assert.equals("嗜血", L["Bloodlust"])
      assert.equals("升腾", L["Ascendance"])
      assert.equals("爆发药水", L["Burst Potion"])
      assert.equals("下一波%s", L["Next Pull Alert - %s"])
      assert.equals("，", L["Alert List Joiner"])
    end)
  end)

  it("enUS 提供提醒模板与列表连接符", function()
    mocks.withCooldownRuntime(function()
      local L = loadRealLocale("enUS")
      assert.equals("Next pull %s", L["Next Pull Alert - %s"])
      assert.equals(", ", L["Alert List Joiner"])
      assert.equals("Bloodlust", L["Bloodlust"])
    end)
  end)

  it("设置面板与斜杠命令的文案两种语言都齐", function()
    mocks.withCooldownRuntime(function()
      local keys = {
        "Alerts", "Voice Alert", "Center Text Alert", "No Planned Uses - %d",
        "Speak the next pull's planned cooldowns when the wave advances.",
        "Show the same reminder as large text in the middle of the screen.",
        "Repeat the next pull's cooldown reminder now",
      }
      local en = loadRealLocale("enUS")
      for _, key in ipairs(keys) do assert.is_not_nil(en[key]) end
      local zh = loadRealLocale("zhCN")
      for _, key in ipairs(keys) do assert.is_not_nil(zh[key]) end
    end)
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/Locales_spec.lua`
Expected: FAIL —— `expected: not nil` / `expected "嗜血" got nil`（键还不存在）

- [ ] **Step 3: 给 `Locales/enUS.lua` 追加键**

在文件末尾（`L["Show note strips above the beacon..."]` 之后）追加。enUS 是自映射基底，
且**没有** locale 守卫：

```lua
L["Bloodlust"] = "Bloodlust"
L["Next Pull Alert - %s"] = "Next pull %s"
L["Alert List Joiner"] = ", "
L["Alerts"] = "Alerts"
L["Voice Alert"] = "Voice Alert"
L["Center Text Alert"] = "Center Text Alert"
L["Speak the next pull's planned cooldowns when the wave advances."] = "Speak the next pull's planned cooldowns when the wave advances."
L["Show the same reminder as large text in the middle of the screen."] = "Show the same reminder as large text in the middle of the screen."
L["Repeat the next pull's cooldown reminder now"] = "Repeat the next pull's cooldown reminder now"
L["No Planned Uses - %d"] = "No planned cooldown uses for pull %d"
```

> `L["Bloodlust"]` 是补既有缺口：种子名一直是裸英文，中文客户端上图标 tooltip
> 显示的是 "Bloodlust" 而非 "嗜血"。

- [ ] **Step 4: 给 `Locales/zhCN.lua` 追加键**

插在既有冷却计划键块之后（`L["Ascendance"] = "升腾"` 附近，`MDT_NPT.NPC_ZH` 块之前）。
zhCN.lua 开头有 `if locale ~= "zhCN" then return end` 守卫，不要动它：

```lua
L["Bloodlust"] = "嗜血"
L["Next Pull Alert - %s"] = "下一波%s"
L["Alert List Joiner"] = "，"
L["Alerts"] = "冷却提醒"
L["Voice Alert"] = "语音提醒"
L["Center Text Alert"] = "屏幕中部文字"
L["Speak the next pull's planned cooldowns when the wave advances."] = "波次推进时，语音念出下一波计划要开的爆发技能。"
L["Show the same reminder as large text in the middle of the screen."] = "在屏幕中部用大字显示同一条提醒。"
L["Repeat the next pull's cooldown reminder now"] = "立即重播下一波的冷却提醒"
L["No Planned Uses - %d"] = "第 %d 波没有规划要开的冷却"
```

- [ ] **Step 5: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/Locales_spec.lua`
Expected: PASS（4 个 it 全绿）

- [ ] **Step 6: Commit**

```bash
git add Locales/enUS.lua Locales/zhCN.lua spec/Locales_spec.lua
git commit -m "feat: localize the bloodlust seed name and the alert strings

Bloodlust was the one cooldown seed with no L[] entry, so its icon
tooltip read raw English on every non-English client. Add it alongside
the alert template and joiner, plus the settings and slash-command copy.

The completeness spec loads the real locale files instead of the mock L
table on purpose: the mock's __index answers every missing key with the
key itself, which would hide exactly the omission this catches."
```

---

## Task 3: `CooldownAlert.buildText` —— 播报文本组装

**Files:**
- Create: `Modules/CooldownAlert.lua`
- Test: `spec/CooldownAlert_spec.lua`（新建）

- [ ] **Step 1: 写失败的测试**

新建 `spec/CooldownAlert_spec.lua`：

```lua
local mocks = require("wow_mocks")

local THREE = "下一波嗜血，下一波爆发药水，下一波升腾"

-- 把 mock 的恒等 L 表换成中文真值，断言才能读起来像游戏里的实际输出。
local function chineseLocale()
  local L = MDT_NPT.L
  L["Bloodlust"] = "嗜血"
  L["Ascendance"] = "升腾"
  L["Burst Potion"] = "爆发药水"
  L["Next Pull Alert - %s"] = "下一波%s"
  L["Alert List Joiner"] = "，"
end

local function spell(action, id)
  return { kind = "spell", id = id or 114050, action = action or "use" }
end
local function potion(action)
  return { kind = "item", id = 241308, action = action or "use" }
end
local function lust(action)
  return { kind = "spell", id = 2825, action = action or "use" }
end
local function plan(...)
  return { entries = { ... } }
end

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    mocks.loadSource("Modules/CooldownData.lua")
    mocks.loadSource("Modules/CooldownPlan.lua")
    chineseLocale()
    mocks.loadSource("Modules/CooldownAlert.lua")
    fn(env, MDT_NPT.CooldownAlert)
  end)
end

describe("CooldownAlert.buildText", function()
  before_each(function() mocks.reset() end)

  it("三项全开时按图标行的左到右顺序播报", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell(), potion(), lust()) }
      assert.equals(THREE, alert.buildText(env.dbChar, "a", 1))
    end)
  end)

  it("只播标记为使用的条目，留着的和未规划的不播", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell("save"), potion("use"), lust("use")) }
      assert.equals("下一波嗜血，下一波爆发药水", alert.buildText(env.dbChar, "a", 1))
    end)
  end)

  it("全部留着或根本没配计划时返回 nil", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell("save"), potion("save")) }
      assert.is_nil(alert.buildText(env.dbChar, "a", 1))
      assert.is_nil(alert.buildText(env.dbChar, "a", 9))
      assert.is_nil(alert.buildText(env.dbChar, "nosuchuid", 1))
    end)
  end)

  it("非元素萨满专精返回 nil", function()
    scenario(function(env, alert)
      env.specID = 253
      env.dbChar.cooldownPlans.a = { [1] = plan(spell(), potion(), lust()) }
      assert.is_nil(alert.buildText(env.dbChar, "a", 1))
    end)
  end)

  it("升腾的每波次数不进文本", function()
    scenario(function(env, alert)
      local asc = spell("use")
      asc.uses = 3
      env.dbChar.cooldownPlans.a = { [1] = plan(asc) }
      assert.equals("下一波升腾", alert.buildText(env.dbChar, "a", 1))
    end)
  end)

  it("嗜血 seed 族内任一 ID 都认得", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(lust("use", 32182)) }
      assert.equals("下一波嗜血", alert.buildText(env.dbChar, "a", 1))
    end)
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/CooldownAlert_spec.lua`
Expected: FAIL —— `Modules/CooldownAlert.lua` 不存在，`loadSource` 的 `assert(chunk, err)` 抛错

- [ ] **Step 3: 写实现**

新建 `Modules/CooldownAlert.lua`：

```lua
local MDT_NPT = MDT_NPT
local L = MDT_NPT.L

local CooldownData = MDT_NPT.CooldownData

-- CooldownAlert: 波次推进时播报下一波计划里要开的爆发技能（设计 2026-09-22）。
-- 纯逻辑层——不创建任何 Frame。文字显示交给 AlertText，本模块只决定「何时说、说什么」。
local CooldownAlert = {}

-- 组装播报文本；没有任何 use 条目时返回 nil（完全静默，设计 §6.1、决策 3）。
--
-- 逆序遍历是必须的，不是笔误：getActiveEntries 按 seed 顺序返回
-- [升腾, 爆发药水, 嗜血]，而 layoutRow（CooldownPlanRender.lua:198）是右对齐的
-- ——entry 1 贴行右边缘、后续向左堆，所以信标上从左到右读作
-- [嗜血][爆发药水][升腾]。倒着念才和眼睛扫过图标行的方向一致（设计 §6.2）。
function CooldownAlert.buildText(dbChar, uid, pullIndex)
  local entries = CooldownData.getActiveEntries(dbChar, uid, pullIndex)
  if not entries or #entries == 0 then return nil end

  local parts = {}
  for i = #entries, 1, -1 do
    local entry = entries[i]
    if entry.plan and entry.plan.action == "use" then
      -- seed.name 兜底：新增 seed 忘了配 locale 时降级成英文，而不是
      -- format(nil) 在大秘境中途抛错。Locales_spec 会先一步拦住这种遗漏。
      parts[#parts + 1] = L["Next Pull Alert - %s"]:format(L[entry.seed.name] or entry.seed.name)
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, L["Alert List Joiner"])
end

MDT_NPT.CooldownAlert = CooldownAlert
```

- [ ] **Step 4: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/CooldownAlert_spec.lua`
Expected: PASS（6 个 it 全绿）

- [ ] **Step 5: Commit**

```bash
git add Modules/CooldownAlert.lua spec/CooldownAlert_spec.lua
git commit -m "feat: build the next-pull cooldown alert text

Reads the same per-pull plan the beacon's icon row reads and keeps only
the entries marked use. Walks the entries in reverse: layoutRow is
right-aligned, so seed order reads backwards against the icons, and the
callout should match the direction the eye already scans.

Nothing planned reads as nil, which is what keeps the feature silent on
every wave that isn't a burn."
```

---

## Task 4: `CooldownAlert.speak` —— TTS 输出

**Files:**
- Modify: `Modules/CooldownAlert.lua`
- Test: `spec/CooldownAlert_spec.lua`

- [ ] **Step 1: 写失败的测试**

在 `spec/CooldownAlert_spec.lua` 末尾（最后一个 `end)` 之前）追加：

```lua
describe("CooldownAlert.speak", function()
  before_each(function() mocks.reset() end)

  local function scenario(fn)
    mocks.withCooldownRuntime(function(env)
      mocks.loadSource("Modules/CooldownData.lua")
      chineseLocale()
      mocks.loadSource("Modules/CooldownAlert.lua")
      fn(env, MDT_NPT.CooldownAlert)
    end)
  end

  it("用客户端 TTS 设置的音色语速音量播报", function()
    scenario(function(env, alert)
      env.tts = { voiceOptionID = 3, rate = 2, volume = 55 }
      assert.is_true(alert.speak("下一波嗜血"))
      assert.equals(1, #env.spoken)
      assert.equals(3, env.spoken[1].voiceID)
      assert.equals("下一波嗜血", env.spoken[1].text)
      assert.equals(2, env.spoken[1].rate)
      assert.equals(55, env.spoken[1].volume)
    end)
  end)

  it("C_TTSSettings 缺失时回落到第一个可用音色", function()
    scenario(function(env, alert)
      _G.C_TTSSettings = nil
      env.ttsVoices = { { voiceID = 11, name = "Fallback" } }
      assert.is_true(alert.speak("下一波嗜血"))
      assert.equals(11, env.spoken[1].voiceID)
      assert.equals(0, env.spoken[1].rate)
      assert.equals(100, env.spoken[1].volume)
    end)
  end)

  it("没有任何可用音色时不播报也不报错", function()
    scenario(function(env, alert)
      _G.C_TTSSettings = nil
      env.ttsVoices = {}
      assert.is_false(alert.speak("下一波嗜血"))
      assert.equals(0, #env.spoken)
    end)
  end)

  it("客户端没有 SpeakText 时安静地放弃", function()
    scenario(function(env, alert)
      _G.C_VoiceChat = { GetTtsVoices = function() return env.ttsVoices end }
      assert.is_false(alert.speak("下一波嗜血"))
      assert.equals(0, #env.spoken)
    end)
  end)

  it("12.x 签名不传 destination，也不默认 overlap", function()
    scenario(function(env, alert)
      alert.speak("下一波嗜血")
      assert.is_nil(env.spoken[1].overlap)
    end)
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/CooldownAlert_spec.lua`
Expected: FAIL —— `attempt to call a nil value` (alert.speak 未定义)

- [ ] **Step 3: 写实现**

在 `Modules/CooldownAlert.lua` 中，`local CooldownAlert = {}` 之后、`buildText` 之前插入：

```lua
-- 无可用 TTS 语音时只提示一次（沿用 BeaconState.corruptionWarned 的手法）。
local ttsWarned = false
local function warnNoVoiceOnce()
  if ttsWarned then return end
  ttsWarned = true
  print("|cff00ff00[MDT]|r No text-to-speech voice is available; cooldown alerts will show text only.")
end

---12.x 的签名是 SpeakText(voiceID, text, rate, volume[, overlap])——destination
---参数已被移除，换成可选的 overlap。整句提醒是一次调用，不存在自我重叠，所以
---overlap 留默认。不包 pcall：.toc 只声明 120100，写对的调用并在 spec 里精确
---mock，比兜住一个不该发生的错误更有价值（参见 commit ee6b01a）。
function CooldownAlert.speak(text)
  if not (C_VoiceChat and C_VoiceChat.SpeakText) then
    warnNoVoiceOnce()
    return false
  end

  local voiceID
  if C_TTSSettings and C_TTSSettings.GetVoiceOptionID and Enum and Enum.TtsVoiceType then
    voiceID = C_TTSSettings.GetVoiceOptionID(Enum.TtsVoiceType.Standard)
  end
  if not voiceID then
    local voices = C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()
    voiceID = voices and voices[1] and voices[1].voiceID
  end
  if not voiceID then
    warnNoVoiceOnce()
    return false
  end

  -- 音色/语速/音量全部跟随客户端自带的 TTS 设置，不新增选项（决策 5）。
  -- volume 的量纲是 0-100，不是 0-1。
  local rate = (C_TTSSettings and C_TTSSettings.GetSpeechRate and C_TTSSettings.GetSpeechRate()) or 0
  local volume = (C_TTSSettings and C_TTSSettings.GetSpeechVolume and C_TTSSettings.GetSpeechVolume()) or 100

  C_VoiceChat.SpeakText(voiceID, text, rate, volume)
  return true
end
```

- [ ] **Step 4: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/CooldownAlert_spec.lua`
Expected: PASS（11 个 it 全绿）

- [ ] **Step 5: Commit**

```bash
git add Modules/CooldownAlert.lua spec/CooldownAlert_spec.lua
git commit -m "feat: speak the cooldown alert through the client's TTS

Voice, rate and volume all come from the client's own text-to-speech
settings rather than new options of our own. Falls back to the first
available voice when C_TTSSettings is missing, and gives up quietly with
a one-time chat notice when the system has no TTS voice at all -- the
center text still shows, since the two channels are independent."
```

---

## Task 5: 触发编排 —— 去重、去抖、开关、`Reset`、`SpeakNow`

**Files:**
- Modify: `Modules/CooldownAlert.lua`
- Test: `spec/CooldownAlert_spec.lua`

- [ ] **Step 1: 写失败的测试**

在 `spec/CooldownAlert_spec.lua` 末尾追加：

```lua
local function activeState(uid, pullIndex)
  local state = {
    active = true,
    presetUID = uid,
    currentNextPull = pullIndex,
    dungeonIndex = 1,
    pullStates = { [1] = { state = "completed" } },
  }
  -- pullIndex 为 nil 表示路由完成；不能写成 pullStates[pullIndex] = ...，
  -- 那是 table index is nil 的硬错误。
  if pullIndex then state.pullStates[pullIndex] = { state = "next" } end
  return state
end

describe("CooldownAlert 触发编排", function()
  before_each(function() mocks.reset() end)

  local function scenario(fn)
    mocks.withCooldownRuntime(function(env)
      mocks.loadSource("Modules/CooldownData.lua")
      mocks.loadSource("Modules/CooldownPlan.lua")
      chineseLocale()
      mocks.loadSource("Modules/CooldownAlert.lua")
      fn(env, MDT_NPT.CooldownAlert)
    end)
  end

  -- 每条路线的两波都配满三项 use。
  local function seedPlans(env)
    env.dbChar.cooldownPlans.a = {
      [1] = plan(spell(), potion(), lust()),
      [4] = plan(spell(), potion(), lust()),
    }
  end

  it("波次推进后经去抖播报下一波", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll()
      assert.equals(0, #env.spoken)   -- 还没到点
      env.fireTimers()
      assert.equals(1, #env.spoken)
      assert.equals(THREE, env.spoken[1].text)
      assert.equals(THREE, env.shown[1])
    end)
  end)

  it("同一波反复 UpdateAll 只播一次", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      for _ = 1, 5 do alert:OnUpdateAll(); env.fireTimers() end
      assert.equals(1, #env.spoken)
    end)
  end)

  it("中途开局连播两次被去抖收敛成一条", function()
    scenario(function(env, alert)
      seedPlans(env)
      -- Start() 先为 pull 1 排定一次；约 1 秒后第一次力量值轮询把已清完的
      -- 波次一次性吃掉、推进到 pull 4 再排定一次。没有去抖就是两条（设计 §5.2）。
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll()
      MDT_NPT.state = activeState("a", 4)
      alert:OnUpdateAll()
      env.fireTimers()
      assert.equals(1, #env.spoken)
      assert.equals(THREE, env.spoken[1].text)
    end)
  end)

  it("波次号变化会重新播报", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      MDT_NPT.state = activeState("a", 4)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(2, #env.spoken)
    end)
  end)

  it("回退到上一波会重新播报", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 4)
      alert:OnUpdateAll(); env.fireTimers()
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(2, #env.spoken)
    end)
  end)

  it("换路线（presetUID 变化）会重新播报同一波号", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.dbChar.cooldownPlans.b = { [1] = plan(spell(), potion(), lust()) }
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      MDT_NPT.state = activeState("b", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(2, #env.spoken)
    end)
  end)

  it("state 为 nil（Stop 之后）清空去重键并取消待定播报", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll()
      MDT_NPT.state = nil
      alert:OnUpdateAll()
      env.fireTimers()
      assert.equals(0, #env.spoken)
      -- 重新开追踪后必须还能播，说明 lastKey 真的被清了
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(1, #env.spoken)
    end)
  end)

  it("路由完成时静默", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", nil)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(0, #env.spoken)
      assert.equals(0, #env.shown)
    end)
  end)

  it("关掉语音时只显示文字", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.db.beacon.alertVoice = false
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(0, #env.spoken)
      assert.equals(1, #env.shown)
    end)
  end)

  it("关掉文字时只播报语音", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.db.beacon.alertText = false
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(1, #env.spoken)
      assert.equals(0, #env.shown)
    end)
  end)

  it("两个开关都关时什么都不做", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.db.beacon.alertVoice = false
      env.db.beacon.alertText = false
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(0, #env.spoken)
      assert.equals(0, #env.shown)
    end)
  end)

  it("开关在去抖窗口内被关掉也生效", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll()
      env.db.beacon.alertVoice = false
      env.fireTimers()
      assert.equals(0, #env.spoken)
    end)
  end)

  it("没有 use 条目时既不播也不显示，但仍记住这一波已处理", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell("save")) }
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(0, #env.spoken)
      assert.equals(0, #env.shown)
    end)
  end)

  it("SpeakNow 绕过去重与去抖立即播报并返回文本", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      assert.equals(THREE, alert:SpeakNow())
      assert.equals(THREE, alert:SpeakNow())   -- 连按两次都出声
      assert.equals(2, #env.spoken)
      assert.equals(0, #env.timers)       -- 不排定时器
    end)
  end)

  it("SpeakNow 在无计划或未追踪时返回 nil", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell("save")) }
      MDT_NPT.state = activeState("a", 1)
      assert.is_nil(alert:SpeakNow())
      assert.equals(0, #env.spoken)
      MDT_NPT.state = nil
      assert.is_nil(alert:SpeakNow())
    end)
  end)

  it("提醒不依赖信标或冷却图标行的可见性", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.db.beacon.showCooldownPlan = false
      env.db.beacon.enabled = false
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(1, #env.spoken)
      assert.equals(1, #env.shown)
    end)
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/CooldownAlert_spec.lua`
Expected: FAIL —— `attempt to call a nil value (method 'OnUpdateAll')`

- [ ] **Step 3: 写实现**

在 `Modules/CooldownAlert.lua` 中，`speak` 之后、`MDT_NPT.CooldownAlert = CooldownAlert` 之前插入：

```lua
-- 去抖延迟（秒）。中途开局时 Start 会先为 pull 1 排定一次播报，约 1 秒后第一次
-- 力量值轮询把已清完的波次一次性吃掉、再排定一次；没有去抖就会连播两条，
-- 而第一条已经过期（设计 §5.2）。这不是优化，是正确性要求。
-- 必须用 C_Timer.NewTimer 而不是 C_Timer.After：After 在零售客户端不返回句柄，
-- 取消不了，去抖会静默失效（Core.lua:292 的 NewTicker 同理才拿得到 :Cancel()）。
local ANNOUNCE_DELAY = 0.75

local lastKey
local pending

local function cancelPending()
  if pending then pending:Cancel() end
  pending = nil
end

---读开关并输出。去抖定时器与 SpeakNow 共用这一份实现，两条入口不会走偏。
---开关在**播出时**读取，而不是排定时——用户在 0.75 秒窗口内关掉语音应当立刻生效。
---@return string|nil 实际播报的文本；没有内容时为 nil
local function fire(uid, pullIndex)
  local db = MDT_NPT:GetDB()
  if not db or not db.beacon then return nil end   -- 设计 §11：ADDON_LOADED 之前的极早期
  local beacon = db.beacon

  local text = CooldownAlert.buildText(MDT_NPT:GetDBChar(), uid, pullIndex)
  if not text then return nil end

  if beacon.alertVoice then CooldownAlert.speak(text) end
  if beacon.alertText and MDT_NPT.AlertText then MDT_NPT.AlertText:Show(text) end
  return text
end

---UpdateAll 的挂钩点。去重键 = presetUID#pullIndex，因此设置面板改动、
---每秒力量值轮询这些不改变波次的调用都不会重复播报；而 revert 把波次号退回
---N-1 时键变化，会重新播报——回退后玩家确实需要重新听到那一波的计划。
function CooldownAlert:OnUpdateAll()
  local state = MDT_NPT.state
  if not state or not state.active then
    self:Reset()
    return
  end
  local uid = CooldownData.getPlanKey(state)
  local pullIndex = state.currentNextPull
  if not uid or not pullIndex then
    self:Reset()
    return
  end

  local key = uid .. "#" .. pullIndex
  if key == lastKey then return end
  lastKey = key

  cancelPending()
  pending = C_Timer.NewTimer(ANNOUNCE_DELAY, function()
    pending = nil
    fire(uid, pullIndex)
  end)
end

---清去重键并取消待定播报。Stop() 把 state 置 nil 后会经 UpdateAll 走到这里，
---所以下次开始追踪不会被上一次的键挡住。
function CooldownAlert:Reset()
  lastKey = nil
  cancelPending()
end

---/npt alert：绕过去重与去抖，立即播报当前 NEXT 波（设计 §10）。
---@return string|nil 播出去的文本；无内容或未在追踪时为 nil
function CooldownAlert:SpeakNow()
  local state = MDT_NPT.state
  if not state or not state.active then return nil end
  local uid = CooldownData.getPlanKey(state)
  if not uid or not state.currentNextPull then return nil end
  return fire(uid, state.currentNextPull)
end
```

- [ ] **Step 4: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/CooldownAlert_spec.lua`
Expected: PASS（27 个 it 全绿）

- [ ] **Step 5: Commit**

```bash
git add Modules/CooldownAlert.lua spec/CooldownAlert_spec.lua
git commit -m "feat: fire the cooldown alert on wave advance, debounced

Hooks the single UpdateAll fan-out point, so scenario advances and every
manual mark/skip/revert route through one dedupe key of
presetUID#pullIndex.

The 0.75s debounce is correctness, not polish. A mid-key Start announces
pull 1, then the first forces poll swallows the already-cleared waves and
announces the real pull -- two callouts a second apart, the first stale.
Re-arming on each advance collapses that to one, and the spec locks it.

Toggles are read when the alert fires rather than when it is armed, so
muting voice inside the debounce window takes effect immediately."
```

---

## Task 6: `AlertText` —— 屏幕中部文字框

**Files:**
- Create: `Modules/AlertText.lua`
- Test: `spec/AlertText_spec.lua`（新建）

- [ ] **Step 1: 写失败的测试**

新建 `spec/AlertText_spec.lua`：

```lua
local mocks = require("wow_mocks")

local FONT_SIZE = 30

-- 动画组建在 FontString 上，所以 group.owner 是文字区、group.owner.parent 是框体
-- （mock 的 widget 一直记着 parent，不需要额外字段）。
local function parts(env)
  local group = env.animations[1]
  return group.owner, group.owner.parent, group
end

describe("AlertText 屏幕中部文字", function()
  before_each(function() mocks.reset() end)

  local function scenario(fn)
    mocks.withCooldownRuntime(function(env)
      mocks.loadSource("Modules/Theme.lua")
      mocks.loadSource("Modules/AlertText.lua")
      fn(env, MDT_NPT.AlertText)
    end)
  end

  it("Show 设置文本、显示框体并播放动画", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local fs, frame, group = parts(env)
      assert.is_true(frame.shown)
      assert.equals("下一波嗜血", fs.text)
      assert.equals(1, group.plays)
    end)
  end)

  it("连续 Show 先停掉旧动画再播新的", function()
    scenario(function(env, alertText)
      alertText:Show("第一条")
      alertText:Show("第二条")
      local fs, _, group = parts(env)
      assert.equals(1, #env.animations)          -- 复用同一个动画组
      assert.equals(1, group.stops)
      assert.equals(2, group.plays)
      assert.equals("第二条", fs.text)
    end)
  end)

  it("动画播完后隐藏框体", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local _, frame, group = parts(env)
      group:_testFinish()
      assert.is_false(frame.shown)
    end)
  end)

  it("Hide 停止动画并隐藏", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local _, frame, group = parts(env)
      alertText:Hide()
      assert.is_false(frame.shown)
      assert.equals(1, group.stops)
    end)
  end)

  it("Hide 在从未 Show 过时不报错", function()
    scenario(function(_, alertText)
      assert.has_no.errors(function() alertText:Hide() end)
    end)
  end)

  it("空文本不创建框体", function()
    scenario(function(env, alertText)
      alertText:Show(nil)
      alertText:Show("")
      assert.equals(0, #env.animations)
    end)
  end)

  it("显式设定字号与粗描边，不用臆造的 SetOutlined", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local fs = parts(env)
      assert.equals(FONT_SIZE, fs._fontSize)
      assert.equals("THICKOUTLINE", fs._fontFlags)
    end)
  end)

  it("没有 EUI 时回落到暴雪当前语言的字体文件", function()
    scenario(function(env, alertText)
      assert.is_nil(MDT_NPT.Theme.GetFontPath())
      alertText:Show("下一波嗜血")
      assert.equals("Fonts\\blizzard.ttf", parts(env)._fontPath)
    end)
  end)

  it("有 EUI 字体时用 EUI 的字体文件", function()
    scenario(function(env, alertText)
      MDT_NPT.Theme.GetFontPath = function() return "Interface\\AddOns\\EUI\\font.ttf" end
      alertText:Show("下一波嗜血")
      assert.equals("Interface\\AddOns\\EUI\\font.ttf", parts(env)._fontPath)
    end)
  end)

  it("框体不拦截鼠标，且盖在常规 UI 之上", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local _, frame = parts(env)
      assert.is_false(frame.mouseEnabled)
      assert.equals("FULLSCREEN_DIALOG", frame.strata)
    end)
  end)

  it("三段动画：淡入 / 停留 / 淡出", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local _, _, group = parts(env)
      local anims = group.animations
      assert.equals(3, #anims)
      assert.equals(1, anims[1].order); assert.equals(0, anims[1].from); assert.equals(1, anims[1].to)
      assert.equals(2, anims[2].order); assert.equals(1, anims[2].from); assert.equals(1, anims[2].to)
      assert.equals(3, anims[3].order); assert.equals(1, anims[3].from); assert.equals(0, anims[3].to)
      assert.equals(0.15, anims[1].duration)
      assert.equals(2.5, anims[2].duration)
      assert.equals(0.6, anims[3].duration)
    end)
  end)
end)
```

> `parts()` 依赖 Step 3 加到 mock 里的 `group.owner`（= 创建动画组的那个 widget）。
> 这是测试抓手，不是客户端 API。

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/AlertText_spec.lua`
Expected: FAIL —— `Modules/AlertText.lua` 不存在

- [ ] **Step 3: 给 widget mock 补一个测试抓手**

spec 需要从动画组反查到创建它的 widget。`spec/helpers/wow_mocks.lua` 的
`CreateAnimationGroup` 里，`env.animations[#env.animations + 1] = group` 之前插入一行：

```lua
      group.owner = self   -- 测试抓手：谁创建了这个动画组（AlertText 里是 FontString）
```

`owner` 是 FontString，框体则是 `owner.parent`——mock 的 widget 从创建起就记着
`parent`，不需要再加字段。`owner` 是纯测试字段，产品代码不可引用。

- [ ] **Step 4: 写实现**

新建 `Modules/AlertText.lua`：

```lua
local MDT_NPT = MDT_NPT
local Theme = MDT_NPT.Theme

-- AlertText: 屏幕中部的瞬态大字提醒（设计 §8）。只负责显示，不含任何计划逻辑——
-- 说什么由 CooldownAlert 决定，这里只管怎么画出来。
local AlertText = {}

local Y_OFFSET   = 120   -- 正中心会被角色模型和战斗文字压住，上移约 11% 屏高
local MAX_WIDTH  = 900   -- FontString 的换行宽度约束
local BOX_HEIGHT = 80
local FONT_SIZE  = 30
local FONT_FLAGS = "THICKOUTLINE"
local FADE_IN, HOLD, FADE_OUT = 0.15, 2.5, 0.6

local frame, text, anim

-- 字体文件优先取 EUI 主题字体，否则取暴雪当前语言的字体文件——不硬编码路径。
-- 不新增 Theme 字体槽：Theme.refreshFonts() 只在 EUI 存在时运行，非 EUI 环境下
-- Theme.fonts.* 只会拿到 GameFontNormalLarge（14pt），对全屏提醒太小（设计 §8.2）。
-- 描边必须走 SetFont 的 flags：12.x 客户端没有 FontString:SetOutlined。
local function applyFont()
  local file = (Theme.GetFontPath and Theme.GetFontPath()) or GameFontNormalLarge:GetFont()
  if not file then return end
  text:SetFont(file, FONT_SIZE, FONT_FLAGS)
end

local function ensureFrame()
  if frame then return frame end

  frame = CreateFrame("Frame", "MDTNPTAlertText", UIParent)
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, Y_OFFSET)
  frame:SetSize(MAX_WIDTH, BOX_HEIGHT)
  frame:EnableMouse(false)   -- 绝不拦截点击：提醒出现在战斗正酣的时候
  frame:Hide()

  text = frame:CreateFontString(nil, "OVERLAY")
  text:SetPoint("CENTER", frame, "CENTER", 0, 0)
  text:SetWidth(MAX_WIDTH)
  text:SetJustifyH("CENTER")
  text:SetJustifyV("MIDDLE")
  text:SetWordWrap(true)
  applyFont()

  local color = Theme.colors.accent
  text:SetTextColor(color[1], color[2], color[3], 1)
  text:SetShadowColor(0, 0, 0, 1)
  text:SetShadowOffset(1, -1)

  -- 动画组建在 FontString 上：Alpha 动画对文字区是明确定义的。
  anim = text:CreateAnimationGroup()
  local fadeIn = anim:CreateAnimation("Alpha")
  fadeIn:SetOrder(1); fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(1); fadeIn:SetDuration(FADE_IN)
  local hold = anim:CreateAnimation("Alpha")
  hold:SetOrder(2); hold:SetFromAlpha(1); hold:SetToAlpha(1); hold:SetDuration(HOLD)
  local fadeOut = anim:CreateAnimation("Alpha")
  fadeOut:SetOrder(3); fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0); fadeOut:SetDuration(FADE_OUT)
  anim:SetOnFinished(function() frame:Hide() end)

  -- EUI 主题变化后重新取字体文件（Theme.lua:253）。
  if Theme.RegisterRefreshCallback then
    Theme.RegisterRefreshCallback(function()
      if text then applyFont() end
    end)
  end

  return frame
end

function AlertText:Show(message)
  if not message or message == "" then return end
  ensureFrame()
  text:SetText(message)
  frame:Show()
  -- 重入：新提醒立刻顶掉旧的，而不是等上一条播完（设计 §8.3）。
  if anim:IsPlaying() then anim:Stop() end
  anim:Play()
end

function AlertText:Hide()
  if not frame then return end
  if anim:IsPlaying() then anim:Stop() end
  frame:Hide()
end

MDT_NPT.AlertText = AlertText
```

- [ ] **Step 5: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/AlertText_spec.lua`
Expected: PASS（11 个 it 全绿）

> 注意 `AlertText_spec` 的 `scenario` 会 `loadSource("Modules/Theme.lua")`，
> 它覆盖掉 Task 1 里 mock 装的 `MDT_NPT.AlertText` 桩——这是有意的，本 spec 测真货。
> `CooldownAlert_spec` 不加载 Theme/AlertText，继续用桩。

- [ ] **Step 6: Commit**

```bash
git add Modules/AlertText.lua spec/AlertText_spec.lua spec/helpers/wow_mocks.lua
git commit -m "feat: centered fade-in text for the cooldown alert

Own frame on FULLSCREEN_DIALOG rather than borrowing RaidWarningFrame or
UIErrorsFrame, so it cannot be shoved aside by another addon's warning
and can carry the theme accent. Mouse is explicitly disabled: this pops
mid-fight.

The font file comes from EUI when present and from
GameFontNormalLarge:GetFont() otherwise, with the size set explicitly. A
Theme font slot would not do -- refreshFonts only runs under EUI, so
non-EUI users would be left with a 14pt full-screen callout."
```

---

## Task 7: 接线 —— 模块注册、Core 挂钩、存档默认值

**Files:**
- Modify: `Modules/load_modules.xml`
- Modify: `Core.lua:46-60`（默认值）、`Core.lua:227-237`（挂钩）
- Test: `spec/Core_alert_hook_spec.lua`（新建）

- [ ] **Step 1: 写失败的测试**

新建 `spec/Core_alert_hook_spec.lua`：

```lua
local mocks = require("wow_mocks")

-- UpdateAll 是整个提醒功能唯一的触发点；漏掉这一行挂钩，前面所有代码都是死代码。
describe("Core.lua UpdateAll 挂钩", function()
  local frames, alertCalls

  local function fireOnEvent(event, ...)
    frames[1]._scripts.OnEvent(frames[1], event, ...)
  end

  before_each(function()
    mocks.reset()

    frames = {}
    _G.CreateFrame = function()
      local f = { _scripts = {}, _events = {} }
      function f:SetScript(n, fn) self._scripts[n] = fn end
      function f:RegisterEvent(e) self._events[e] = true end
      function f:UnregisterEvent(e) self._events[e] = nil end
      frames[#frames + 1] = f
      return f
    end

    local mockDb = {
      enabled = true,
      autoStartInKey = false,
      beacon = { enabled = true, showForNonTank = false, askOnStart = false,
                 alertVoice = true, alertText = true },
    }
    _G.LibStub = function()
      return { New = function() return { global = mockDb, char = { beacon = {} } } end }
    end

    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show = function() end
    _G.YES, _G.NO = "Yes", "No"
    _G.C_Timer = { After = function() end }
    _G.print = function() end

    -- Core.lua 在 load 时捕获成 upvalue 的子模块。
    _G.MDT_NPT.State = { buildStateFromPreset = function() return nil end }
    _G.MDT_NPT.Scenario = {}
    _G.MDT_NPT.Beacon = {}
    _G.MDT_NPT.Mdt = { syncMDTDungeonToPlayerZone = function() end }
    _G.MDT_NPT.CooldownPlanEditor = nil

    alertCalls = 0
    _G.MDT_NPT.CooldownAlert = {
      OnUpdateAll = function() alertCalls = alertCalls + 1 end,
    }

    local chunk = assert(loadfile("Core.lua"))
    chunk("MythicDungeonTools_NextPullTracker")
    fireOnEvent("ADDON_LOADED", "MythicDungeonTools_NextPullTracker")
  end)

  it("UpdateAll 每次都驱动提醒模块", function()
    MDT_NPT:UpdateAll()
    MDT_NPT:UpdateAll()
    assert.equals(2, alertCalls)
  end)

  it("提醒模块缺席时 UpdateAll 不报错", function()
    _G.MDT_NPT.CooldownAlert = nil
    assert.has_no.errors(function() MDT_NPT:UpdateAll() end)
  end)

  it("默认存档里两个提醒开关都是开的", function()
    local db = MDT_NPT:GetDB()
    assert.is_true(db.beacon.alertVoice)
    assert.is_true(db.beacon.alertText)
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/Core_alert_hook_spec.lua`
Expected: FAIL —— `expected 2 got 0`（挂钩不存在）、`expected true got nil`（默认值不存在）

- [ ] **Step 3: 注册模块加载顺序**

`Modules/load_modules.xml`，把：

```xml
  <Script file='CooldownLust.lua'/>
  <Script file='CooldownPlanEditor.lua'/>
```

改为：

```xml
  <Script file='CooldownLust.lua'/>
  <Script file='AlertText.lua'/>
  <Script file='CooldownAlert.lua'/>
  <Script file='CooldownPlanEditor.lua'/>
```

> 顺序有约束：`CooldownAlert.lua` 在 load 时捕获 `MDT_NPT.CooldownData` 和
> `MDT_NPT.L` 成 upvalue，所以必须排在 `CooldownData.lua` 之后；`locales.xml`
> 在 `.toc` 里已经先于 `load_modules.xml`，`L` 此时已填充完毕。
> `AlertText.lua` 在 load 时捕获 `MDT_NPT.Theme`，必须排在 `Theme.lua` 之后。

- [ ] **Step 4: 给 `Core.lua` 加存档默认值**

`Core.lua` 的 `defaultSavedVars.global.beacon` 里，找到：

```lua
      -- Independent visibility switch for the NPC note strips shown above the
      -- beacon (design: NpcNotes 5.1). Purely additive: follows the beacon's
      -- existing visibility conditions, never forces the beacon visible.
      showNpcNotes = false,
```

在其后插入：

```lua
      -- Cooldown alert output channels (design 2026-09-22 §9). They live under
      -- `beacon` only to reuse makeBeaconBool, exactly like showCooldownPlan;
      -- the alert neither depends on nor affects beacon visibility, and fires
      -- even with the HUD hidden. Account-wide per the BeaconState convention
      -- that feature toggles never go char-scoped.
      alertVoice = true,
      alertText = true,
```

- [ ] **Step 5: 给 `Core.lua` 的 `UpdateAll()` 加挂钩**

把：

```lua
function MDT_NPT:UpdateAll()
  if Beacon.Update then
    Beacon:Update()
  end
  -- Keep the standalone plan editor in sync during active tracking (e.g. next
  -- pull advances). Route switches while idle are handled by the editor's own
  -- OnUpdate poll, since UpdateAll only fires during the 1s tracking timer.
  if MDT_NPT.CooldownPlanEditor and MDT_NPT.CooldownPlanEditor.Refresh then
    MDT_NPT.CooldownPlanEditor:Refresh()
  end
end
```

改为：

```lua
function MDT_NPT:UpdateAll()
  if Beacon.Update then
    Beacon:Update()
  end
  -- Keep the standalone plan editor in sync during active tracking (e.g. next
  -- pull advances). Route switches while idle are handled by the editor's own
  -- OnUpdate poll, since UpdateAll only fires during the 1s tracking timer.
  if MDT_NPT.CooldownPlanEditor and MDT_NPT.CooldownPlanEditor.Refresh then
    MDT_NPT.CooldownPlanEditor:Refresh()
  end
  -- Single fan-out point for wave advances: Start, Stop, the scenario forces
  -- poll and every manual mark/skip/revert all route through here, so the
  -- alert module needs no hooks of its own (design 2026-09-22 §3). Late-deref
  -- like the editor line above, so load order can't break it.
  if MDT_NPT.CooldownAlert and MDT_NPT.CooldownAlert.OnUpdateAll then
    MDT_NPT.CooldownAlert:OnUpdateAll()
  end
end
```

- [ ] **Step 6: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/Core_alert_hook_spec.lua`
Expected: PASS（3 个 it 全绿）

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/Core_popup_spec.lua`
Expected: PASS（确认没打破既有 Core spec）

- [ ] **Step 7: Commit**

```bash
git add Modules/load_modules.xml Core.lua spec/Core_alert_hook_spec.lua
git commit -m "feat: wire the cooldown alert into the UpdateAll fan-out

UpdateAll is the one place every state change already converges, so the
alert needs no hooks of its own and cannot miss a path -- SkipTo assigns
currentNextPull directly without going through recomputeNextPull, which
is what ruled out hooking there.

The toggles default on and live under db.beacon only to reuse
makeBeaconBool, like showCooldownPlan before them; they neither depend
on nor affect beacon visibility."
```

---

## Task 8: 设置面板 + `/npt alert` + 文档

**Files:**
- Modify: `Modules/Settings.lua:160-171`（"Pull Colors" 分区之前）
- Modify: `Modules/Slash.lua`（handler + commands 表）
- Modify: `CHANGELOG.md`（`## [Unreleased] / ### Added`）
- Modify: `README.md`（功能列表）

- [ ] **Step 1: 设置面板加 "Alerts" 分区**

`Modules/Settings.lua`，找到：

```lua
  -- Pull colors: a clickable live preview per state (dots + ring) plus a
```

在它**之前**插入：

```lua
  -- Cooldown alert channels (design 2026-09-22 §9.3). No onChange callback:
  -- both are read when the alert fires, not when the beacon redraws.
  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L["Alerts"]))

  makeBeaconBool(category, "MDTNPT_ALERT_VOICE", L["Voice Alert"],
    "alertVoice", L["Speak the next pull's planned cooldowns when the wave advances."],
    nil, true)

  makeBeaconBool(category, "MDTNPT_ALERT_TEXT", L["Center Text Alert"],
    "alertText", L["Show the same reminder as large text in the middle of the screen."],
    nil, true)

```

- [ ] **Step 2: Slash 加 `alert` 命令**

`Modules/Slash.lua`，在 `handleSettings` 之后插入：

```lua
-- 立即重播当前 NEXT 波的提醒。没有它，游戏内验证文案和样式必须真跑完一波大秘境。
local function handleAlert()
  if not MDT_NPT:IsActive() then
    print(PREFIX..": tracking is not active.")
    return
  end
  local idx = MDT_NPT:GetCurrentNextPull()
  if not idx then
    print(PREFIX..": route complete.")
    return
  end
  local alert = MDT_NPT.CooldownAlert
  local text = alert and alert:SpeakNow()
  -- 自动播报路径在无计划时保持静默（决策 3），但这条命令是给人当场验证用的，
  -- 静默会让人以为坏了，所以这里必须出声反馈。
  if not text then
    print(PREFIX..": "..MDT_NPT.L["No Planned Uses - %d"]:format(idx))
  end
end
```

然后在 `commands` 表里，`plan` 那一行之后插入：

```lua
  { name = "alert",    usage = "alert",       help = "repeat the next pull's cooldown reminder now",       handler = handleAlert },
```

- [ ] **Step 3: 更新 CHANGELOG**

`CHANGELOG.md` 的 `## [Unreleased]` → `### Added` 下追加一条：

```markdown
- Next-pull cooldown alerts: when the wave advances, the cooldowns you planned to use on the next pull are spoken aloud through the client's text-to-speech voice and shown as large centered text ("下一波嗜血，下一波爆发药水，下一波升腾" / "Next pull Bloodlust, Next pull Burst Potion, Next pull Ascendance"). Waves with nothing planned stay completely silent. Voice and text are independent toggles under a new Alerts section in the settings panel, both on by default; speech rate, volume and voice follow the client's own Text To Speech options. The alert fires even when the beacon is hidden and does not require the cooldown plan rows to be shown. `/npt alert` repeats the current reminder on demand.
```

- [ ] **Step 4: 更新 README**

`README.md` 的功能列表里，紧跟现有的 cooldown plan 那一条（第 22 行附近）之后插入：

```markdown
- Next-pull cooldown alerts: planned burst cooldowns for the incoming wave are spoken via the client's TTS voice and shown as large centered text the moment the wave advances; silent on waves with nothing planned. Independent voice / text toggles, `/npt alert` to repeat on demand
```

- [ ] **Step 5: 全量本地回归**

Run:
```bash
node .tmp-npt-task/luaenv/minibusted.js spec/API_spec.lua spec/BeaconFrame_spec.lua spec/BeaconMinimap_spec.lua spec/BeaconState_spec.lua spec/CooldownAlert_spec.lua spec/CooldownData_spec.lua spec/CooldownPlanEditor_spec.lua spec/CooldownPlanRender_spec.lua spec/Core_alert_hook_spec.lua spec/Core_popup_spec.lua spec/AlertText_spec.lua spec/Locales_spec.lua spec/Mdt_spec.lua spec/NpcNotes_spec.lua spec/PullNotes_spec.lua spec/Scenario_spec.lua spec/State_spec.lua spec/Theme_spec.lua spec/Wow_spec.lua
```
Expected: 全部 PASS，退出码 0

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/MDTAdapter_spec.lua`
Expected: PASS（必须单独跑）

- [ ] **Step 6: 语法检查（只编译不执行）**

Run:
```bash
node .tmp-npt-task/luaenv/syntaxcheck.js Modules/CooldownAlert.lua Modules/AlertText.lua Modules/Settings.lua Modules/Slash.lua Core.lua Locales/enUS.lua Locales/zhCN.lua spec/CooldownAlert_spec.lua spec/AlertText_spec.lua spec/Locales_spec.lua spec/Core_alert_hook_spec.lua spec/helpers/wow_mocks.lua
```
Expected: 每行 `OK  <path>`，退出码 0。任何 `ERR` 都要先修掉再提交——
fengari 是 Lua 5.3，`//` 整除、`goto` 之类 5.1 没有的语法它能编过，
所以这一步只查笔误，不代替 CI。

- [ ] **Step 7: Commit**

```bash
git add Modules/Settings.lua Modules/Slash.lua CHANGELOG.md README.md
git commit -m "feat: settings toggles and /npt alert for the cooldown reminder

Two independent switches rather than a per-cooldown matrix: muting one
channel is the real need, and 'do not remind me about bloodlust' is
already expressible by marking it save in the plan editor.

/npt alert replays the current wave's callout on demand. Without it,
checking a wording or font tweak means running an actual mythic+ pull."
```

---

## Task 9: 游戏内验证

代码全绿只证明逻辑正确，不证明玩家在屏幕上看到/听到的东西正确。以下必须真人进游戏跑一遍。

**Files:** 无（只验证）

- [ ] **Step 1: 部署到游戏目录**

先干跑，确认镜像范围没把 `docs/`、`spec/`、`tools/` 之类带进去：

Run: `powershell -ExecutionPolicy Bypass -File tools/Deploy-Robocopy.ps1 -DryRun`
Expected: 只打印将变更的文件列表，不写盘

确认无误后正式部署：

Run: `powershell -ExecutionPolicy Bypass -File tools/Deploy-Robocopy.ps1`
Expected: robocopy 摘要无失败项

> 默认目标是 `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns`，
> 属系统保护目录，脚本会要求**管理员权限**的 PowerShell；未提权会直接报错退出而不会
> 静默改系统目录。本机 PowerShell 跑在 Constrained Language Mode 下，脚本已适配，
> 但如果报语言模式相关错误，用管理员身份重开一个 PowerShell 再跑。
> 部署前脚本会自动备份到 `deploy\backup\<时间戳>\`（已在 .gitignore 内）。

- [ ] **Step 2: 冷启动无报错**

进游戏，`/reload`。检查 BugSack/BugGrabber（机器上已装）没有新错误。
Expected: 无 Lua error

- [ ] **Step 3: 验证 `/npt alert` 的静默与出声反馈**

在城里（未追踪）输入 `/npt alert`。
Expected: 聊天框出现 `tracking is not active.`，且**没有** Lua error

- [ ] **Step 4: 验证语音真的出声**

用元素萨满（specID 262）开一把大秘境或 `/npt start`，在 `/npt plan` 里给第 1 波
勾上三项 use，然后 `/npt alert`。
Expected:
- 听到中文 TTS 念出「下一波嗜血，下一波爆发药水，下一波升腾」
- 屏幕中部偏上出现同一段青色大字，淡入 → 停留约 2.5 秒 → 淡出
- 文字不拦截鼠标（把鼠标移到文字上，仍能点到身后的东西）

> 若听不到声音但文字正常：先看聊天框有没有 `No text-to-speech voice is available`，
> 再去 暴雪设置 → 辅助功能 → 文字转语音 确认音色与「启用」状态。

- [ ] **Step 5: 验证顺序与信标图标行一致**

`/npt alert` 时对照信标上的图标行。
Expected: 听到的顺序 = 从左到右扫过图标的顺序（嗜血 → 药水 → 升腾）

- [ ] **Step 6: 验证真实波次推进**

打完第 1 波，等波次号跳到 2。
Expected: 约 0.75 秒后播出第 2 波的计划；同一波内不重复播

- [ ] **Step 7: 验证中途开局只播一条**（设计 §5.2 的回归）

打到第 4 波左右，`/npt stop` 再 `/npt start`。
Expected: **只播一条**，内容是当前真正 NEXT 的那一波，不是第 1 波

- [ ] **Step 8: 验证无计划波次静默**

给某一波全部标 save（或不配），推进到它。
Expected: 既不出声也不出文字

- [ ] **Step 9: 验证两个开关独立**

暴雪设置 → MDT Next Pull Tracker → 冷却提醒，分别只关语音、只关文字，各 `/npt alert` 一次。
Expected: 只关语音 → 有字无声；只关文字 → 有声无字

- [ ] **Step 10: 验证非元素萨满不播**

切成别的专精 `/npt alert`。
Expected: 聊天框提示 `第 N 波没有规划要开的冷却`（`getSeedEntries` 返回空表）

- [ ] **Step 11: 若字号/位置需要微调**

改 `Modules/AlertText.lua` 顶部的 `Y_OFFSET` / `FONT_SIZE` / `MAX_WIDTH` /
`FADE_IN` / `HOLD` / `FADE_OUT` 常量，重新部署再看。
这些是设计 §14 明确的非设置项，不要顺手加成设置面板选项。

- [ ] **Step 12: 推送并看 CI**

```bash
git push
```
然后确认 GitHub Actions 的 Tests workflow（`busted`，Lua 5.1）全绿——
本地 fengari 是 Lua 5.3，绿不代表 CI 绿。

---

## Self-Review 记录

**1. Spec 覆盖**

| 设计章节 | 实现于 |
|---|---|
| §3 触发点 UpdateAll | Task 7 Step 5 |
| §4.1 CooldownAlert 模块 | Task 3/4/5 |
| §4.2 AlertText 模块 | Task 6 |
| §5 数据流 | Task 5 Step 3 |
| §5.1 去重键 | Task 5（4 个 it） |
| §5.2 去抖定时器 | Task 5（「中途开局」it）+ Task 9 Step 7 |
| §6.1 取材与非 262 静默 | Task 3（2 个 it） |
| §6.2 seed 逆序 | Task 3（「左到右顺序」it） |
| §6.3 本地化三键 + 补 Bloodlust | Task 2 |
| §6.4 不播 ×N | Task 3（「每波次数不进文本」it） |
| §7 speak 与 TTS 回退 | Task 4（5 个 it） |
| §8.1 Frame 常量 | Task 6（「不拦截鼠标」it） |
| §8.2 字体解析 | Task 6（2 个 it） |
| §8.3 三段动画 + 重入 | Task 6（3 个 it） |
| §9.1 存档默认值与命名空间 | Task 7 Step 4 + Task 8 Step 1 |
| §9.2 不依赖 showCooldownPlan | Task 5（「不依赖可见性」it） |
| §9.3 设置面板 | Task 8 Step 1 |
| §10 /npt alert | Task 8 Step 2 + Task 9 Step 3 |
| §11 错误处理表 | Task 4/5/6 各 it + Task 7（「模块缺席」it） |
| §12.1 mocks 扩展 | Task 1 + Task 6 Step 3 |
| §12.2 CooldownAlert_spec | Task 3/4/5 |
| §12.3 AlertText_spec | Task 6 |
| §12.4 本地化完整性 | Task 2 |
| §13 改动清单 | 全部 Task；`.pkgmeta` 已随 spec 提交（`fffbf6b`） |
| §14 范围外 | Task 9 Step 11 明确禁止顺手加设置项 |

无遗漏。

**2. 占位符扫描**：无 TBD / TODO / 「类似 Task N」；每个改动步骤都给了完整代码。

**3. 类型与命名一致性**（跨 task 逐一核对）：

- `CooldownAlert.buildText(dbChar, uid, pullIndex)` —— Task 3 定义，Task 5 的 `fire` 与全部 spec 调用签名一致
- `CooldownAlert.speak(text)` —— Task 4 定义并导出，Task 5 以 `CooldownAlert.speak(text)` 调用（不是 `speak(text)`，因为 `fire` 里要走导出名以便 spec 打桩）
- `CooldownAlert:OnUpdateAll()` / `:Reset()` / `:SpeakNow()` —— Task 5 定义，Task 7 挂钩与 Task 8 的 `handleAlert` 调用名一致
- `AlertText:Show(message)` / `:Hide()` —— Task 6 定义，Task 1 的 mock 桩与 Task 5 的 `fire` 调用签名一致
- `env.spoken` / `env.shown` / `env.timers` / `env.animations` / `env.fireTimers()` —— Task 1 定义，Task 3-6 的 spec 使用名一致
- `db.beacon.alertVoice` / `db.beacon.alertText` —— Task 1（mock）、Task 5（读取）、Task 7（默认值）、Task 8（设置面板 key）四处拼写一致
- locale 键名 —— Task 2 定义，Task 3（`Next Pull Alert - %s`、`Alert List Joiner`）与 Task 8（`Alerts`、`Voice Alert`、`Center Text Alert`、`No Planned Uses - %d`）使用名一致
- `group.owner`（mock 字段）/ `owner.parent`（框体）—— Task 6 Step 3 定义、Step 1 的 `parts()` 使用；实现侧不需要任何测试专用字段

**4. 自查中修掉的三处会导致假绿或硬报错的问题**（记录在此，避免实现时又改回去）：

- `activeState(uid, nil)` 原本写成 `pullStates = { [1] = ..., [pullIndex] = ... }`，
  `pullIndex` 为 nil 时是 `table index is nil` 硬错误 → 改为条件赋值
- Task 3「只播标记为使用」的期望值原本写成 `下一波爆发药水，下一波嗜血`，
  与 §6.2 的逆序规则相反 → 改为 `下一波嗜血，下一波爆发药水`
- Task 6 的 spec 原本从 `group.owner.textRegion` 取文字区，但动画组建在 FontString 上，
  `owner` 本身就是文字区、框体是 `owner.parent` → 改用 `parts()` 统一取，
  并删掉实现里的 `frame.textRegion = text`（那会是只服务于测试的产品代码字段）
