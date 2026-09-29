# 下一波冷却提醒（语音 + 屏幕中部文字）设计

日期：2026-09-22
状态：已确认，待实现

## 1. 目标

波次推进时，用语音念出下一波计划里要开的爆发技能（"下一波嗜血，下一波爆发药水，下一波升腾"），
同时在屏幕中部显示同一句文字。

## 2. 已确认的产品决策

| # | 决策 | 取值 |
|---|------|------|
| 1 | 触发时机 | 波次索引推进时（`state.currentNextPull` 变化），不做距离/ETA 判断 |
| 2 | 语音实现 | 游戏内置 TTS：`C_VoiceChat.SpeakText`，不自带录音 |
| 3 | 无计划时 | 完全静默——不发音、不显示文字 |
| 4 | 中部文字 | 自建 Frame + FontString + AnimationGroup，不复用 RaidWarningFrame / UIErrorsFrame |
| 5 | 设置粒度 | 两个独立开关（语音 / 文字），默认都开；不做分项开关 |

## 3. 触发点：`MDT_NPT:UpdateAll()`

`UpdateAll()`（Core.lua:227）是所有状态变更的唯一汇聚点——`Start`、`Stop`、
`Scenario.onScenarioForcesUpdate` 的力量值推进、`MarkComplete`、`MarkIncomplete`、
`SkipTo` 全部经过它。因此只在这一处加一行挂钩，即可覆盖自动推进与全部手动操作。

被否决的两个方案：

- **挂在 `State.recomputeNextPull()`**：`SkipTo` 直接赋值 `state.currentNextPull`
  而不走它（API.lua:83），`Start` 也是全新建表，需要补三处挂钩，漏一处就静默失效。
- **在 1 秒 ticker 里轮询比对**：最多 1 秒延迟，且与 `Scenario` 重复读同一份状态，没有收益。

## 4. 模块划分

沿用仓库既有的「纯逻辑 / UI 薄层」分工（`CooldownData` 纯数据 ↔ `CooldownPlanRender` 渲染）。

### 4.1 `Modules/CooldownAlert.lua`

决定**何时说、说什么**。不创建任何 Frame，输入是 `(dbChar, uid, pullIndex)`，
输出是字符串。全部逻辑可在 busted 中直接断言。

对外接口：

```lua
MDT_NPT.CooldownAlert:OnUpdateAll()  -- Core.lua 的挂钩点，负责去重 + 排定去抖定时器
MDT_NPT.CooldownAlert:Reset()        -- 清去重键 + 取消待定定时器
MDT_NPT.CooldownAlert:SpeakNow()     -- /npt alert 用，绕过去重与去抖，返回文本或 nil
```

`OnUpdateAll` 的定时器回调与 `SpeakNow` 共用同一个内部 `fire(state)`：
读开关、`buildText`、`speak`、`AlertText:Show` 只有一份实现，两条入口不会走偏。
区别仅在于 `SpeakNow` 不去重、不延迟，且把文本返回给调用方。

内部纯函数（导出以便测试）：

```lua
CooldownAlert.buildText(dbChar, uid, pullIndex) -> string|nil
```

### 4.2 `Modules/AlertText.lua`

决定**怎么显示**。懒创建一个挂在 `UIParent` 上的 Frame，只暴露两个方法：

```lua
MDT_NPT.AlertText:Show(text)
MDT_NPT.AlertText:Hide()
```

两个文件都加进 `Modules/load_modules.xml`，排在 `CooldownLust.lua` 之后、
`CooldownPlanEditor.lua` 之前。

## 5. 数据流

```
Core.lua  MDT_NPT:UpdateAll()                     ← 唯一新增挂钩，1 行
   └─> CooldownAlert:OnUpdateAll()
         ├─ state = MDT_NPT.state
         ├─ state 为 nil / 非 active / currentNextPull 为 nil
         │      → Reset() → return
         ├─ key = presetUID .. "#" .. currentNextPull
         ├─ key == lastKey → return                ← 去重，防 UpdateAll 重入
         ├─ lastKey = key
         └─ 重排去抖定时器 → ANNOUNCE_DELAY 秒后：
               ├─ text = buildText(dbChar, uid, pullIndex)
               ├─ text 为 nil → return             ← 完全静默
               ├─ db.beacon.alertVoice → speak(text)
               └─ db.beacon.alertText  → AlertText:Show(text)
```

### 5.1 去重键

`lastKey = presetUID .. "#" .. pullIndex`。

- 同一 `(uid, pullIndex)` 上 `UpdateAll` 被反复调用（设置面板改动、每次力量值轮询）
  不会重复播报。
- `MarkIncomplete` / `/npt revert` 把 `currentNextPull` 退回 N-1，键变化 → 重新播报。
  这是正确行为：回退后玩家确实需要重新听到那一波的计划。
- `Stop()` 在 `MDT_NPT.state = nil` 之后调用 `UpdateAll()`，因此会走到 `Reset()`，
  下次开始追踪时不会被上一次的键挡住。

### 5.2 去抖定时器（必需，非优化）

`ANNOUNCE_DELAY = 1.25` 秒，可取消。

**不变量：本值必须大于 `Core.lua:307` 那个 `C_Timer.NewTicker(1.0)` 的轮询周期。**
`Start()` 先建轮询 ticker、随后才调 `UpdateAll()`，所以中途开局时 Start 排定的
pull 1 播报必须活到 t=1.0s 的轮询来取消它；否则它会在轮询之前就播出去，去抖
形同不存在。旧值 0.75 正是这个 bug（0.75 < 1.0），中途开局照样双播。改轮询
周期的人必须同步改这里。

**它修的是一个具体的 bug**：没有去抖时，中途开始追踪会连播两次。`Start()` 先为
pull 1 触发一次 `UpdateAll()`，约 1 秒后第一次力量值轮询把已完成的波次一次性
吃掉、推进到真正的当前波（pull k+1），再触发一次 `UpdateAll()`。

加去抖后（中途开局）：t=0 `Start` 为 pull 1 排定定时器（到期 t=1.25）；t=1.0s
的轮询推进到 pull k+1，取消 pull 1 那次并重排；t≈2.25s 只播出 pull k+1。
全程一条。

正常开局（钥匙刚开、还没有力量值增量）：t=0 排定 pull 1，t=1.0s 的轮询无增量、
不重排，t=1.25s 播出 pull 1。行为正确。

常规推进：pull N 完成 → 1.25 秒后播 pull N+1。对"下一波来临之前"这个语义无影响。

`Reset()` 必须同时取消待定定时器。

**考虑过并否决的替代方案**：在 `Start()` 里同步消费一次力量值，让中途开局根本
不排定过期的 pull 1（这样 0.75 秒本可以保留）。否决理由：它依赖 scenario
criteria 在 `CHALLENGE_MODE_START` 时已经填充完毕，而这没有保证；且它改变的是
整个插件的 `Start()` 行为，而不是本功能自己的行为。

## 6. 播报内容

### 6.1 取材

复用 `CooldownData.getActiveEntries(dbChar, uid, pullIndex)`，筛
`entry.plan and entry.plan.action == "use"`。

非元素萨满（specID ≠ 262）时 `getSeedEntries()` 返回 `{}`，`buildText` 自然得到 nil，
不需要额外的专精判断。

### 6.2 顺序：seed 逆序

`getActiveEntries` 按 `SEED_TABLE` 顺序返回 `[升腾, 爆发药水, 嗜血]`
（CooldownData.lua:13-44）。但 `layoutRow`（CooldownPlanRender.lua:198）是**右对齐**的
——"entry 1 hugs the row's right edge, later entries stack leftwards"，所以信标上
从左到右的视觉顺序是 `[嗜血][爆发药水][升腾]`。

因此 `buildText` **逆序遍历** entries，让听到的顺序与从左到右扫过图标行的顺序一致：
嗜血 → 爆发药水 → 升腾。逆序的理由必须在代码里写注释，否则后人会当成笔误改回去。

### 6.3 本地化

新增键（enUS 为基底，zhCN 覆盖；ruRU/frFR 缺键时自动回落英文）：

| 键 | enUS | zhCN |
|---|---|---|
| `L["Bloodlust"]` | `Bloodlust` | `嗜血` |
| `L["Next Pull Alert - %s"]` | `Next pull %s` | `下一波%s` |
| `L["Alert List Joiner"]` | `, ` | `，` |

`L["Bloodlust"]` 是**补既有缺口**：种子名 `"Bloodlust"` 目前在 enUS/zhCN 里都没有对应
条目，图标 tooltip 走的是 `entry.seed.name`，所以中文客户端上一直显示裸英文。

zhCN 拼接结果：`下一波嗜血，下一波爆发药水，下一波升腾`
enUS 拼接结果：`Next pull Bloodlust, Next pull Burst Potion, Next pull Ascendance`

语音和文字用**同一个字符串**——听到什么就看到什么，是这个功能的全部意义。

> 注意这与需求原话的顺序（嗜血、升腾、爆发药水）不同：原话是随口列举，
> 这里改为严格跟随信标图标行的左→右视觉顺序，由 §6.2 的逆序规则决定。
> 若日后 `SEED_TABLE` 调整了条目顺序，播报顺序会自动跟随，无需改这里。

### 6.4 明确不做

- 不播报升腾的 ×N 次数。中文 TTS 念 "×2" 的结果不可控，而规划了 2 次的人本来就知道。
- 不做"下一波无爆发"之类的否定播报（决策 3）。
- 不在开场对 pull 1 做特殊处理：`Start` 走同一条路径，会正常播报第 1 波。

## 7. 语音输出

12.x 的签名是 `C_VoiceChat.SpeakText(voiceID, text, rate, volume[, overlap])`
——destination 参数已移除，改为可选的 overlap。本机安装的 MRT / TargetedSpells /
EXBoss 均按此调用，已实测确认。

```lua
local function speak(text)
  if not (C_VoiceChat and C_VoiceChat.SpeakText) then return false end

  local voiceID
  if C_TTSSettings and C_TTSSettings.GetVoiceOptionID and Enum and Enum.TtsVoiceType then
    voiceID = C_TTSSettings.GetVoiceOptionID(Enum.TtsVoiceType.Standard)
  end
  if not voiceID then
    local voices = C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()
    voiceID = voices and voices[1] and voices[1].voiceID
  end
  if not voiceID then
    warnNoVoiceOnce()   -- 系统无可用 TTS 语音，聊天框提示一次
    return false
  end

  local rate   = (C_TTSSettings and C_TTSSettings.GetSpeechRate   and C_TTSSettings.GetSpeechRate())   or 0
  local volume = (C_TTSSettings and C_TTSSettings.GetSpeechVolume and C_TTSSettings.GetSpeechVolume()) or 100
  C_VoiceChat.SpeakText(voiceID, text, rate, volume)
  return true
end
```

要点：

- **音色 / 语速 / 音量全部跟随客户端自带的 TTS 设置**，不新增选项（决策 5）。
  `volume` 的量纲是 0-100，不是 0-1。
- `overlap` 用默认值（false）。整句提醒是一次 `SpeakText` 调用，不存在自我重叠；
  连续两波快速推进时由去抖定时器保证只有最后一条会播。
- 不用 `pcall` 包 `SpeakText`。本插件 `.toc` 只声明 `Interface: 120100`，
  按仓库既有原则（commit ee6b01a："drop the invented mock method so specs cannot
  pass where the client would crash"）写正确的 12.x 调用，并在 spec 里精确 mock。
  只对 API **是否存在**做守卫，那是真实的系统边界。
- 已知局限：若玩家在客户端 TTS 设置里选的是纯英文语音，中文文本可能念不出来。
  这是客户端/系统层面的事，插件无法探测语音的语言。缓解手段是屏幕中部文字
  始终独立显示（两个开关互相独立）。

## 8. 屏幕中部文字

### 8.1 Frame

```lua
local f = CreateFrame("Frame", "MDTNPTAlertText", UIParent)
f:SetFrameStrata("FULLSCREEN_DIALOG")   -- 盖住绝大多数 UI
f:SetPoint("CENTER", UIParent, "CENTER", 0, Y_OFFSET)
f:SetSize(MAX_WIDTH, 80)
f:EnableMouse(false)                    -- 绝不拦截点击
f:Hide()
```

常量（模块顶部，不做成设置项）：

- `Y_OFFSET = 120`：正中心会被角色模型和战斗文字压住，上移约 11% 屏高。
- `MAX_WIDTH = 900`：FontString 的换行宽度约束。
- `FONT_SIZE = 30`、`FONT_FLAGS = "THICKOUTLINE"`。

### 8.2 字体

不新增 `Theme` 字体槽。原因：`Theme.refreshFonts()` 只在 EUI 存在时运行
（`Theme.Refresh()` 在没有 EUI 时提前 return），所以 `Theme.fonts.*` 在非 EUI 环境
只会拿到暴雪的 `GameFontNormalLarge`（14pt），对全屏提醒太小。

改为直接解析字体文件、显式设定字号：

```lua
local file = (Theme.GetFontPath and Theme.GetFontPath())
  or GameFontNormalLarge:GetFont()   -- 取暴雪当前语言的字体文件，不硬编码路径
fs:SetFont(file, FONT_SIZE, FONT_FLAGS)
```

`Theme.GetFontPath()` 已是公开 API（Theme.lua:247）。用 `GetFont()` 取文件路径而非
硬编码 `STANDARD_TEXT_FONT`，与 `applyOrdinalStyle`（CooldownPlanRender.lua）同一手法。

描边必须走 `SetFont` 的 flags 参数——12.x 客户端没有 `FontString:SetOutlined`。

通过 `Theme.RegisterRefreshCallback`（Theme.lua:253）在 EUI 主题变化时重新应用字体。

### 8.3 颜色与动画

颜色用 `Theme.colors.accent`（EUI 主题色，缺省为青绿 12/210/157），可读性由
`SetFont` 的 `THICKOUTLINE` 描边承担。

投影调用（`SetShadowColor` / `SetShadowOffset`）已移除：运行时
`FontString:SetShadowColor` / `SetShadowOffset` **不渲染**——本机安装的三个插件
（EllesmereUI、EllesmereUIQoL、EllesmereUIRaidFrames）各自独立记录了这一点，
投影只有由 FontObject 携带时才会渲染。若游戏内验证发现 `THICKOUTLINE` 在明亮
副本地板上不够可读，正确修法是换一个携带 shadow 的 FontObject，在 `SetFont`
**之前**经 `SetFontObject` 应用（EUI 的 `PrimeFontShadow` 手法），而不是把那两行
调用加回来。

AnimationGroup 三段，`SetOrder` 1/2/3：

| 段 | 类型 | 时长 | 效果 |
|---|---|---|---|
| 淡入 | Alpha | 0.15s | 0 → 1 |
| 停留 | Alpha | 2.5s | 1 → 1 |
| 淡出 | Alpha | 0.6s | 1 → 0 |

`SetScript("OnFinished", ...)` 里 `Hide()`。**`AnimationGroup` 没有 `SetOnFinished` 方法**——
全机 AddOns 里 `setonfinished` 零命中、`SetScript("OnFinished"` 55 命中，只能走 `SetScript`。

**重入**：`Show()` 被再次调用时先 `Stop()` 再 `Play()`，让新提醒立刻顶掉旧的，
而不是等上一条播完。

## 9. 配置

### 9.1 存储位置

`db.beacon.alertVoice` / `db.beacon.alertText`，默认均为 `true`，加进
Core.lua 的 `defaultSavedVars.global.beacon`。

命名空间并不贴切——提醒在信标被隐藏时照样响。选它的理由是 `showCooldownPlan`
已是同样先例（一个冷却计划功能的开关放在 `beacon` 下），且能直接复用
`Settings.lua` 的 `makeBeaconBool` 帮手，不必新加 helper。Core.lua 里要写注释
说明这两个键**不影响、也不依赖**信标可见性。

按 BeaconState.lua 的既有约定，功能开关一律账号级、留在 `db.global.beacon`，
不进 char 作用域。

### 9.2 不依赖 `showCooldownPlan`

计划数据是 char 级、独立于 HUD 存在的。哪怕没开图标行、哪怕信标被隐藏、
哪怕是治疗或 DPS，只要该波有 `use` 标记就提醒。

### 9.3 设置面板

`Settings.lua` 在 "Pull Colors" 分区之前插入一个新分区：

```lua
layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L["Alerts"]))

makeBeaconBool(category, "MDTNPT_ALERT_VOICE", L["Voice Alert"],
  "alertVoice", L["Speak the next pull's planned cooldowns when the wave advances."],
  nil, true)

makeBeaconBool(category, "MDTNPT_ALERT_TEXT", L["Center Text Alert"],
  "alertText", L["Show the same reminder as large text in the middle of the screen."],
  nil, true)
```

两个开关都不需要 `onChange` 回调——它们只在下一次播报时被读取。

## 10. `/npt alert`

`Slash.lua` 的 `commands` 表新增一条：

```lua
{ name = "alert", usage = "alert", help = "repeat the next pull's cooldown reminder now", handler = handleAlert },
```

`handleAlert` 调 `CooldownAlert:SpeakNow()`：绕过去重与去抖，立即组装并播报当前
NEXT 波的提醒，返回文本。返回 nil 时由 **`handleAlert`**（不是 `SpeakNow`）在聊天框
打印 "pull N has no planned cooldown uses"——`SpeakNow` 保持无副作用的返回值语义，
打印属于命令层的用户反馈。

这条命令的用途就是当场验证文案和样式，所以此处必须出声反馈而不能静默；
它与决策 3 不冲突，决策 3 约束的是自动播报路径。

存在理由：没有它，游戏内验证必须真跑完一波大秘境。

## 11. 错误处理

| 情形 | 行为 |
|---|---|
| `C_VoiceChat.SpeakText` 不存在 | `speak` 返回 false，聊天框提示一次（模块级 `warned` 标志，沿用 `corruptionWarned` 的既有手法） |
| `C_VoiceChat.GetTtsVoices()` 为空且 `C_TTSSettings` 取不到 voiceID | 同上，提示一次 |
| `C_TTSSettings` 整个不存在 | rate 回落 0、volume 回落 100，照常播 |
| `presetUID` 为 nil | `CooldownData.getPlanKey` 已返回 nil，`getActiveEntries` 拿不到计划 → 静默 |
| 路由完成（`currentNextPull` 为 nil） | `Reset()` 并静默 |
| `MDT_NPT:GetDB()` 返回 nil（ADDON_LOADED 之前的极早期） | `fire` 读不到开关 → 直接 return，不提醒 |
| `AlertText` 模块未加载 | `if MDT_NPT.AlertText then` 守卫后再调 |

不做 `pcall` 兜底：上表已覆盖所有真实边界，其余错误应当暴露出来。

## 12. 测试

本地用 `.tmp-npt-task/luaenv/minibusted.js`（fengari）快速验证，最终以 CI 的
Lua 5.1 + busted 2.x 为准。

### 12.1 `spec/helpers/wow_mocks.lua` 扩展

`withCooldownRuntime` 的 `names` 保存/恢复列表必须加上新全局，否则会污染其他 spec：
`C_VoiceChat`、`C_TTSSettings`、`UIParent`。

新增 mock：

- `C_VoiceChat.SpeakText(...)` → 追加到 `env.spoken`（记录 voiceID/text/rate/volume）
- `C_VoiceChat.GetTtsVoices()` → `env.ttsVoices`（默认 `{{ voiceID = 1, name = "Test" }}`，可置空测回退）
- `C_TTSSettings.GetVoiceOptionID / GetSpeechRate / GetSpeechVolume` → 读 `env.tts`
- `Enum.TtsVoiceType = { Standard = 0 }`（并入已有的 `Enum` 表）
- `C_Timer.After(delay, fn)` → 不返回任何值（与零售客户端一致，不可取消）；
  `C_Timer.NewTimer(delay, fn)` → 返回可 `:Cancel()` 的句柄。两者都追加到
  `env.timers`，并提供 `env.fireTimers()` 手动触发；`NewTicker` 已有，保持不动
- widget mock 补 `CreateAnimationGroup()`，返回带 `CreateAnimation` / `Play` / `Stop` /
  `SetScript` 的对象，并记录 `env.animations`。`AnimationGroup` 没有 `SetOnFinished`，
  mock 也不许臆造它——只能提供真实的 `SetScript("OnFinished", fn)`
- widget mock 补 `SetFrameStrata` / `SetJustifyH` / `SetJustifyV` / `SetWordWrap` /
  `SetShadowColor`（已有）/ `SetShadowOffset`（已有）
- `_G.GameFontNormalLarge`：§8.2 的字体回落路径会调它的 `GetFont()`，
  mock 里必须存在并返回一个可辨识的路径（如 `"Fonts\\blizzard.ttf"`），
  否则回落分支的断言会因为 nil 索引而假绿
- `_G.UIParent`：一个 widget 实例，作为 AlertText 的父框

### 12.2 `spec/CooldownAlert_spec.lua`

- `buildText`：三项全 `use` → 三段，且顺序为 seed **逆序**（嗜血/药水/升腾）
- 部分 `use`、全 `save`、无计划条目 → 段数正确；空时返回 nil
- 非 262 专精 → nil
- `uses >= 2` 的升腾 → 文本里**不含**次数（§6.4 的回归锁）
- 去重：同一 `(uid, pullIndex)` 连续两次 `OnUpdateAll` + `fireTimers` → 只播一次
- `pullIndex` 变化 / `presetUID` 变化 → 重新播
- 去抖：两次 `OnUpdateAll` 之间不 `fireTimers`，只在最后 `fireTimers` → 只播最后那条
  （§5.2 中途开局 bug 的回归锁）
- `state` 为 nil → `Reset()`，且待定定时器被取消
- 开关独立性：`alertVoice=false` 只走文字；`alertText=false` 只走语音；都 false 都不走
- 路由完成（`currentNextPull=nil`）→ 静默 + Reset
- TTS 回退：`C_TTSSettings` 缺失时用 `GetTtsVoices()[1].voiceID`；两者都无时不播且不报错

### 12.3 `spec/AlertText_spec.lua`

- `Show(text)` 设置文本、显示、启动动画
- 连续 `Show` → 先 `Stop` 再 `Play`
- `SetScript("OnFinished", ...)` 回调触发后隐藏
- 字体：显式字号 30 + `THICKOUTLINE`；`Theme.GetFontPath()` 返回路径时用该路径，
  返回 nil 时回落到 `GameFontNormalLarge:GetFont()`

### 12.4 本地化完整性

`wow_mocks` 的 `MDT_NPT.L` 带 `__index = function(_, k) return k end`，
**缺键时返回键名而非 nil**，所以普通 spec 抓不到"忘了加 `L["Bloodlust"]`"这类 bug
——真实客户端里那会拼出 `下一波nil`。

新增一个 spec，用 `helpers.loadSource("Locales/enUS.lua")` 载入真实基底表，
断言 `SEED_TABLE` 里每个 `name` 都有非 nil 的 `L[name]`。
zhCN 同理载入后断言 `L["Bloodlust"] == "嗜血"` 等新增键存在。

## 13. 改动清单

新增：

- `Modules/CooldownAlert.lua`
- `Modules/AlertText.lua`
- `spec/CooldownAlert_spec.lua`
- `spec/AlertText_spec.lua`
- `spec/Locales_spec.lua`

修改：

- `Core.lua`：`defaultSavedVars.global.beacon` 加 `alertVoice` / `alertText`；
  `UpdateAll()` 加 `CooldownAlert:OnUpdateAll()` 挂钩；`Stop()` 路径经 `UpdateAll`
  已覆盖，无需额外改动
- `Modules/load_modules.xml`：注册两个新文件
- `Modules/Settings.lua`：新增 "Alerts" 分区与两个复选框
- `Modules/Slash.lua`：新增 `alert` 命令
- `Locales/enUS.lua`、`Locales/zhCN.lua`：新增 §6.3 的键 + §9.3 的设置文案
- `spec/helpers/wow_mocks.lua`：§12.1
- `.pkgmeta`：ignore 列表加 `- docs`（本文件所在目录不应打进 CurseForge 包）
- `CHANGELOG.md`：`## [Unreleased] / ### Added` 加一条
- `README.md`：功能列表加一条

## 14. 范围外

- 自带录音回退（决策 2 已选 TTS）
- 音色 / 语速 / 音量设置项（跟随客户端）
- 提醒位置、字号、停留时长的设置项（模块常量，需要时改一行）
- 分项开关（嗜血/升腾/药水各自开关）——与计划编辑器的 use/save 语义重复
- 距离或 ETA 判断（插件没有这个概念）
- 播报升腾 ×N 次数

## v2（2026-09-29）：内置录音与图标横幅

> 本节记录 v2 对上文的取代关系。§6/§7/§8 描述的是已被取代的 v1 方案，保留作历史记录，不要照它实现。

**为什么放弃客户端 TTS（§7）**：`C_VoiceChat.SpeakText` 的效果完全取决于玩家在
系统里装了哪些 TTS 语音——中文文本配上纯英文语音念不出或直接吞掉，音色也无法
保证；实测本机默认语音念整句提醒的效果刺耳、不像喊话。加上这个功能开发史上
已经三次被客户端 API 的现实打脸（`SetOutlined`、`C_Timer.After` 返回值、
`SetOnFinished`），继续把核心体验押在一个探测不了、控制不了的客户端能力上
不值得。改为**自带录音**。

**音频管线**：`tools/voice/gen.js` 用 Microsoft Edge 神经 TTS（node-edge-tts）
离线生成 mp3（24kHz 48kbps 单声道），中英两套各 7 条，覆盖嗜血/爆发药水/升腾
的全部非空组合；文件名 = `buildItems` 拼出的 `audioKey`（如 `lust-potion-asc.mp3`）。
运行时 `CooldownAlert.play(audioKey)` 走 `PlaySoundFile(path, "Master")`：
zhCN 客户端取 `Media/voice/zh-CN/`，其余语言回落 `Media/voice/en-US/`。
Master 声道与本机所有喊话类插件一致，保证听得到；静音需求由「语音提醒」开关承担。
新增 seed 时重跑一遍脚本即可，不需要任何运行时拼接。

**为什么整句大字变成了标签 + 图标横幅（§6.3、§8）**：录音把「说了什么」固定进了
音频文件，屏幕中部再重复一整句本地化文字是冗余的；而计划编辑器和信标图标行
已经教会了用户「图标 = 一项冷却」。v2 的 `AlertBanner` 只显示本地化的
`L["Next Pull"]` 标签加最多 3 个冷却图标（顺序仍由 §6.2 的 seed 逆序规则决定，
这条规则在 `buildItems` 里继续生效），居中、三段淡入淡出——比整句文字更快扫读，
也不再需要为「听到什么就看到什么」维护拼接模板与连接符两个 locale 键。

**模块更名**：`Modules/AlertText.lua` → `Modules/AlertBanner.lua`
（`MDT_NPT.AlertText` → `MDT_NPT.AlertBanner`），接口从 `Show(text)` 变为
`Show(icons)`；它现在画的是图标横幅，不是文字。

## v3（2026-09-29）：背景底板与圆形发光图标

游戏内实测反馈：v2 的裸文字 + 方图标一行会融进战斗背景，方形图标被误认成
动作条按钮 / buff 图标。v3 的对策（对 §8 呈现层的取代，接口 `Show(icons)` 不变）：

**一整块底板**：横幅改建于 `BackdropTemplate` 框上，`SetBackdrop` 用实测过的
Tooltip 背景 + 边框贴图，黑底 0.8、边框染主题色——标签和图标从此读作一个物件。
淡入 / 停留 / 淡出三段 Alpha 与一段 0.9→1.0 的 Scale 弹出同组同序，
整块底板一体弹出、一体消失。

**圆形发光图标**：每个图标槽 = 辉光贴图（OVERLAY，尺寸为图标 1.5 倍，染主题色）
+ 图标贴图（ARTWORK，经 per-slot `CreateMaskTexture` 圆形裁切）。圆环 + 外辉光
让图标彻底告别方形动作条观感。

**为什么资产是自带的白底 PNG**：暴雪的圆形遮罩 / 圆环 atlas 与 LibCustomGlow 的
proc 类贴图（IconAlertAnts、Stealable 边框等）都是方形动作条 / proc 视觉语言，
正是本次要摆脱的东西。改为 `tools/media/gen-glow.js`（零依赖、确定性输出）
生成 `Media/circle_mask.png`（白色圆盘遮罩）与 `Media/ring_glow.png`
（圆环 + 径向外辉光），运行时 `SetVertexColor` 染主题色——换色不需要重新生成资产，
与 EUI 自带 circle_mask.tga 的做法同一路数。

## v4（2026-09-30）：嗜血真就绪边沿提醒与精疲力尽预提醒

游戏内实测反馈：信标图标行左端的嗜血格只有一个安静的倒计时数字，副本进行中
从来没人盯着它看——小而静的 UI 在战斗里等于不存在。v4 给它加两条主动提示
（`Modules/CooldownLust.lua`，开关 `beacon.lustAlert`，账号级，默认开）：

**真就绪边沿**：`readyIn` 从 >0 跨到 0 的那一刻——注意语义是**两条约束都清空**
（技能 CD 与精疲力尽/心满意足族 debuff 的 max 归零，不是只 CD 转好）——播
`lust-ready` 录音并在嗜血格上脉冲一圈 `lustReady` 色圆环（复用 v3 的
`Media/ring_glow.png`，Alpha 0→1→0 两遍共 2s，播完自动隐藏）。一次跨越只播
一次；停在 0 上反复采样不重播。

**精疲力尽预提醒**：当 sated debuff 是约束项（`satedLeft >= cdLeft`，即
`readyIn == satedLeft`）且剩余时间从 >30s 跨到 <=30s 时，播 `lust-sated-soon`
一次，不脉冲——离真正可用还有半分钟，脉冲会让人误以为现在就能开。CD 是约束项
时的同款跨越保持静默：那只是普通转CD，没有决策价值。

**边沿状态**：模块级 `prevReady/prevSated`，nil = 未播种。cell 每次变为可见后的
第一次采样只播种不触发；`Lust:Hide()` 把两者重置回 nil，隐藏期间发生的跨越
不会被迟到的采样补播。采样收敛为单一 `sample()`：`Lust:Update` 与既有的 0.5s
`C_Timer.NewTicker` 轮询共用（不新建第二个 ticker），所以边沿检测的分辨率是
0.5s，与 UpdateAll 的节奏无关。

**开关与播放**：`lustAlert` 在**触发时**读取（守卫模式与 `CooldownAlert.fire()`
一致：`MDT_NPT:GetDB()` 与 `.beacon` 判 nil）；播放复用
`MDT_NPT.CooldownAlert.play(key)`（晚解引用），路径解析、Master 声道、zh/en
回落全部沿用 v2 的管线，不重造。

**新音频**：`tools/voice/gen.js` 增加独立于组合 ORDER/mask 逻辑的 PHRASES 表，
中英各两句（`lust-ready`、`lust-sated-soon`），嗓音与输出格式同 v2。

## v5（2026-09-30）：嗜血/爆发药水就绪对照窗

新模块 `Modules/ReadyTracker.lua`（开关 `beacon.readyTracker`，账号级，默认开）：
一个独立的可拖动小窗（`MDTNPTReadyTracker`，HIGH strata），并排两格 36px 格子，
左边嗜血、右边爆发药水，各自显示就绪倒计时；**两者同时为 0** 时八条边框一起染
`lustReady` 色——那就是「一起开」的 combo 窗口，坦克一眼就能对比出还要等多久。

**为什么是独立窗口而不是加宽信标行**：对照是*规划*动作——它发生在拉怪之前、
读条间隙、灭团复盘时，需要一块自己常驻的屏幕位置让眼睛形成肌肉记忆；信标行是
战斗 HUD 的一部分，跟着波次刷新走，把规划工具塞进去会让两种节奏互相干扰，而且
非信标用户（map-only、隐藏 HUD）就永远看不到对照。位置存
`beacon.readyTrackerPos = { point, x, y }`（拖动结束从 `GetPoint()` 写回，重建时
恢复；默认 `CENTER, UIParent, CENTER, 0, 240`，在 +120 的提醒横幅上方），跨会话
持久。

**为什么显示剩余秒数而不是「第几波能用上」的推演**：推演需要预知未来每波的
战斗时长，而拉怪长度根本不可知（打断失误、减员、开怪节奏全在人）；秒数是唯一
诚实的语义，「能不能赶上下一波」留给人自己判断。

**复用而非重写**：`CooldownLust` 最小重构出 `Lust.makeCell(parent)`（36px 格子
工厂：bg/icon/四边描边/倒计时文字，`ensureLustFrame` 改为在其上加脉冲环）、
`Lust.paintCell(cell, readyIn, icon)`（行格与对照窗共用同一份渲染语言：>0 红字
倒计时 + 白图标，0 空字 + 就绪色图标）、并暴露 `lustReadyIn`/`formatReady` 与新增
`potionReadyIn()`——爆发药水 4 个 itemID 共享使用效果法术 1236616（与
`CooldownData.lua:30` 的 `useEffectSpellID` 同源），CD 探测沿用嗜血 CD 分支的
pcall 纪律（12.x secret 数值在 tainted 执行下比较即硬错）。药水图标走
`CooldownAlert.seedIcon` 物品分支同一条路：`dbChar.cooldownPotionID` 覆盖优先，
默认 241308。行格行为与 v4 边沿/预提醒语义零变化。

**驱动**：模块加载即懒建唯一一个 `C_Timer.NewTicker(0.5, tick)`；回调判 nil-guard
GetDB、读开关——关则隐藏窗体（若有）直接返回，开则 ensureFrame + 双格绘制 +
Show。窗口是普通交互窗（EnableMouse/SetMovable/RegisterForDrag("LeftButton")，
OnDragStart→StartMoving，OnDragStop→StopMovingOrSizing+保存），不做信标那套
Alt 点击穿透。无标题无底板，chrome-free 两格。

## v6（2026-09-30）：横幅去底板

**动机**：v3 的背景底板+描边在真机观感里太「UI」——一块不透明矩形压在战斗画面上，
比它要解决的「融进背景」更抢眼。用户拍板：去掉背景与边框。

**改动**：`AlertBanner.lua` 不再挂 `BackdropTemplate`/`SetBackdrop*`；框退化为不可见的
排版容器（尺寸公式、左起排版、Scale+Alpha 一体动画、主题色重染全部保留）。凝聚力改由
圆形裁切+主题色圆环辉光承担——辉光本身就把整行读成一个物件，且不与任何暴雪 UI 语言撞车。

**守卫**：spec 断言框上不存在 backdrop 记录器（mock 只给带 BackdropTemplate 模板的框挂
SetBackdrop* 记录器，记录器缺席 = 产品代码没再碰背景/边框）；变异证明为把模板与
SetBackdrop 加回去，该测试变红。

## v7（2026-09-30）：就绪对照窗可调大小

右缘 6px 细条把手横向拖（`StartSizing("RIGHT")`，实证于本机插件的把手模式）：
窗宽推出格边长 `(w - GAP - 2*PAD) / 2`，倒计时字号随边长等比（基准记在
`cell.textBase`），高度跟随边长——单行控件只给一个自由度，二维拖拽只会拖出无效高度。
宽度存 `db.beacon.readyTrackerWidth`，建窗时还原并夹到 [60, 240]（格边长 24..113）。
把手吃掉鼠标，不与整窗拖动冲突。

## v8（2026-09-30）：图标不再叠状态色

真机反馈：就绪绿染在图标上让原画看起来像坏了（绿糊糊的药水瓶）。新渲染语言——
**图标永远不叠状态色**：可用 = 清晰原画（vertexColor 白、alpha 1、空文字）；
倒计时 = 半透原画（alpha 0.45）+ 红色倒计时文字。ready 的边框语义只留在对照窗的
八条边框上（combo 染色不变），行格与对照窗共用 `Lust.paintCell`，两处一起改。
回归测试断言 `icon.alpha` 与 `vertexColor`；变异 `DIM_ALPHA = 1` 会被测试捕获。

把手显隐（v7 补充）：灰条默认隐藏，OnEnter 显形、OnLeave 藏回；拖拽中（sizing 为真）
OnLeave 不藏——鼠标拖拽时必然滑出把手，藏掉等于盲拖；OnMouseUp 用 IsMouseOver()
（实证于本机插件）判断松手位置，不在把手上则藏回。
