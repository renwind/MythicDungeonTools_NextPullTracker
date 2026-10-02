# 暗黑风格配比球 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `SpellRatioOrb` 的「圆形遮罩裁剪两个纯色矩形」换成 `!!!_Diablo` 那套真正的液体球——贴图液面、装饰环、液面高光线、4 层反向旋转气泡动画，数据语义与门控逻辑完全不变。

**Architecture:** 新增纯视觉部件 `Modules/OrbLiquid.lua`（不知道 MDT / DB / 技能 ID），用「隐形 VERTICAL StatusBar 当高度发生器 + `SetClipsChildren(true)` 裁剪框 + 满尺寸从不缩放的液体贴图」实现液位；两个独立 driver bar（地震侧正向、元素冲击侧 `SetReverseFill`）保证 `0:0` 波次两侧全空。`SpellRatioOrb.lua` 退化为外壳（拖拽/缩放/门控/图标/文字）并驱动一个 `OrbLiquid` 实例。液位十等分运算抽成 `SpellRatioData:FillTenths` 纯函数。

**Tech Stack:** WoW 12.1 Lua 5.1，`StatusBar` / `SetClipsChildren` / `MaskTexture` / `AnimationGroup`，原生 `Enum.StatusBarInterpolation.ExponentialEaseOut` 缓动（无需 oUF）。测试：本机 fengari + `minibusted`（CI 上才是真 busted）。

> **提交约定：** 用户要求「子代理实现不提交」。每个任务以「全套测试绿」收尾，**不执行 `git add` / `git commit`**；提交由用户在全部完成后统一处理。
>
> **测试命令（本机无 lua/luarocks/busted，只能用这个）：**
> ```bash
> node .tmp-npt-task/luaenv/minibusted.js spec/<file>_spec.lua        # 单文件
> ```
> 运行目录必须是仓库根 `G:\Work\NPT-Dev`（`minibusted.lua` 里 `package.path` 与 `loadSource` 都用相对路径）。退出码非 0 即有失败。
>
> **不要用 `spec/*_spec.lua` 一次跑全套**：`spec/Core_alert_hook_spec.lua`、`Core_popup_spec.lua`、`NpcNotes_spec.lua` 各自把 `_G.print` 置为空函数且不恢复，会连带吞掉 runner 自己的汇总行。逐文件循环才可靠：
> ```bash
> for f in spec/*_spec.lua; do
>   out=$(node .tmp-npt-task/luaenv/minibusted.js "$f" 2>&1); rc=$?
>   echo "$f :: $(echo "$out" | grep -E '^[0-9]+ tests' || echo 'NO SUMMARY') :: exit=$rc"
> done
> ```
> `NO SUMMARY` + `exit=0` 即通过（失败走 stderr，吞掉 `print` 藏不住失败）。
>
> **全套「绿」的定义（Task 1 之后确立的基线）：** 唯一允许的失败是 `spec/CooldownPlanRender_spec.lua` 的 **2 条**——`Modules/CooldownPlanRender.lua:95` 的 `seed.hideCD and nil or id` 是既有产品 bug（`(true and nil) or id` 恒等于 `id`），已提交在 main 上、与本计划无关、CI 上同样红。**本次不修它。** 每个任务的门槛是「不新增失败、且那 2 条不变」。
>
> **本机 runner 已被修过两处（`.tmp-npt-task/` 是 gitignored 的本地环境，换机器不会带上）：**
> 1. `describe` 里原有的 `beforeEach = nil` 会让**嵌套 describe 内的 `it` 拿不到外层 `before_each`**，本地曾有 124 条纯噪声失败。已移除该行，现在嵌套可用（Task 3 依赖这一点）。
> 2. 补了 `assert.truthy` / `assert.has_no_errors` 两个 luassert 原生拼写的别名转发（此前 10 条失败）。
>
> 若在新机器上跑本计划，这两处需要先补，否则会看到一百多条与代码无关的失败。
>
> **关键约束（勿违反）：**
> - **所有派生尺寸必须写成 `size * N / 160`（先乘后除）**，不能写 `size * (N/160)`。后者的浮点舍入结果与十进制字面量不一致（例如 `96*(168/160) ~= 100.8`），spec 的 `assert.equals` 会假红。
> - **裁剪框必须 parent 到 `orb`，不能 parent 到 driver bar。** driver bar 是 `SetAlpha(0)` 的，框 alpha 会向子级传播，挂上去整条液体会变透明。暗黑正是把 `clipFrame` 挂在 `orb` 上（`units\player.lua:401`）。
> - **`scroll` 框必须锚到 `orb` 而非裁剪框**（`SetPoint("BOTTOM", orb, "BOTTOM")`）。裁剪框高度随液位变化，其 CENTER 会移动，气泡锚上去会随液位「游泳」。
> - **每个 Alpha 动画必须显式 `SetFromAlpha` / `SetToAlpha`。** 暗黑原版这两行是注释掉的、靠调用方后补（`units\player.lua:158-165`），照抄会静默退化成 fade-to-1。
> - **`orb_grid1` 装饰环只允许中性灰压暗**（`SetVertexColor(0.38,0.38,0.38)` + `alpha 1.0`；0.38 为 2026-10-03 真机定值，此前试过 0.68 仍偏亮），**不得染成 `Theme.colors.accent`**——不跟 EUI 主题。有测试用「三通道相等」钉住中性。
> - **不臆造 mock 方法。** `spec/helpers/wow_mocks.lua` 里记录过一次事故：臆造 `SetOnFinished` 导致产品代码调用不存在的客户端方法而 spec 全绿。Task 1 新增的每个 stub 都已在 `!!!_Diablo` 线上代码或既有 NPT 代码中确认真实存在。
> - **`circle_mask.png` 文件不得删除**：`AlertBanner.lua:27` 仍在用，`spec/AlertBanner_spec.lua:207` 有断言。只删 `SpellRatioOrb.lua` 里的引用。

**Spec：** `docs/superpowers/specs/2026-10-02-diablo-style-spell-ratio-orb-design.md`（已批准）

---

## File Structure

| 文件 | 动作 | 职责 |
| --- | --- | --- |
| `spec/helpers/wow_mocks.lua` | 修改 | 补 StatusBar / 裁剪 / blend / sublayer / Rotation 的录制型 stub + `Enum.StatusBarInterpolation` |
| `spec/WowMocks_spec.lua` | 新建 | 钉住新 stub 的录制契约，防止静默漂移 |
| `Media/orb/*.tga` | 新建（9 个） | 从 `!!!_Diablo` 拷来的球体贴图 |
| `Modules/Theme.lua` | 修改 | 新增 `Theme.textures.orb`（9 条路径）+ `spellRatioElemental` / `spellRatioEarthquake` 两个语义色 |
| `spec/Theme_spec.lua` | 修改 | `expectedKeys` 补两个新 token；新增 textures.orb 断言 |
| `Modules/SpellRatioData.lua` | 修改 | 新增纯函数 `FillTenths(row)`（带 1..9 clamp），与既有 `RatioTenths` 并列 |
| `spec/SpellRatioData_spec.lua` | 修改 | `FillTenths` vs `RatioTenths` 的分歧用例 |
| `Modules/OrbLiquid.lua` | 新建 | 纯视觉双液体球部件：渲染栈 + 动画 + `SetSplit` / `SetColors` |
| `spec/OrbLiquid_spec.lua` | 新建 | 结构契约断言（裁剪/锚点/动画/可见性规则） |
| `Modules/load_modules.xml` | 修改 | `OrbLiquid.lua` 插在 `SpellRatioOrb.lua` 之前 |
| `Modules/SpellRatioOrb.lua` | 修改 | 换成 OrbLiquid 驱动；几何 64→96；删遮罩/inner/setFillHeight/Theme.Refresh |
| `spec/SpellRatioOrb_spec.lua` | 修改 | 10 个作废断言原地改写为新契约 |

---

## Task 1: 扩展 wow_mocks 的 StatusBar / 裁剪 / 动画录制能力

**Files:**
- Modify: `spec/helpers/wow_mocks.lua`
- Test: `spec/WowMocks_spec.lua`（新建）

- [ ] **Step 1: 写失败的测试**

新建 `spec/WowMocks_spec.lua`：

```lua
local mocks = require("wow_mocks")

describe("wow_mocks StatusBar / clip / rotation stubs", function()
  before_each(function() mocks.reset() end)

  it("records statusbar configuration and value with its interpolation mode", function()
    mocks.withCooldownRuntime(function()
      local bar = CreateFrame("StatusBar", nil, UIParent)
      bar:SetOrientation("VERTICAL")
      bar:SetReverseFill(true)
      bar:SetMinMaxValues(0, 10)
      bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
      bar:SetValue(7, Enum.StatusBarInterpolation.ExponentialEaseOut)

      assert.equals("StatusBar", bar.kind)
      assert.equals("VERTICAL", bar.orientation)
      assert.is_true(bar.reverseFill)
      assert.same({ 0, 10 }, bar.minMax)
      assert.equals("Interface\\Buttons\\WHITE8X8", bar.statusBarTexture)
      assert.equals(7, bar.value)
      assert.equals(Enum.StatusBarInterpolation.ExponentialEaseOut, bar.interpolation)
    end)
  end)

  it("returns an identity-comparable region from GetStatusBarTexture", function()
    mocks.withCooldownRuntime(function()
      local bar = CreateFrame("StatusBar", nil, UIParent)
      local tex = bar:GetStatusBarTexture()
      assert.is_not_nil(tex)
      assert.equals(tex, bar:GetStatusBarTexture())
      assert.equals(bar, tex.parent)
    end)
  end)

  it("records clipping, blend mode and texture sublayer", function()
    mocks.withCooldownRuntime(function()
      local clip = CreateFrame("Frame", nil, UIParent)
      clip:SetClipsChildren(true)
      assert.is_true(clip.clipsChildren)

      local tex = clip:CreateTexture(nil, "BACKGROUND", nil, -7)
      assert.equals("BACKGROUND", tex.layer)
      assert.equals(-7, tex.sublayer)

      tex:SetBlendMode("ADD")
      assert.equals("ADD", tex.blendMode)

      -- 真实签名 SetDrawLayer(layer[, subLayer])；driver 的贴图靠它压到 BACKGROUND 0
      tex:SetDrawLayer("BACKGROUND", 0)
      assert.equals("BACKGROUND", tex.drawLayer)
      assert.equals(0, tex.drawSublayer)
    end)
  end)

  it("records Rotation animation degrees", function()
    mocks.withCooldownRuntime(function()
      local tex = UIParent:CreateTexture(nil, "ARTWORK")
      local ag = tex:CreateAnimationGroup()
      local rot = ag:CreateAnimation("Rotation")
      rot:SetDegrees(-360)
      rot:SetDuration(45)
      rot:SetOrder(1)

      assert.equals("Rotation", rot.kind)
      assert.equals(-360, rot.degrees)
      assert.equals(45, rot.duration)
      assert.equals(1, rot.order)
      assert.equals(tex, ag.owner)
    end)
  end)

  it("exposes StatusBarInterpolation enum members", function()
    mocks.withCooldownRuntime(function()
      assert.is_not_nil(Enum.StatusBarInterpolation)
      assert.is_number(Enum.StatusBarInterpolation.ExponentialEaseOut)
      -- 保留既有的 SpellBookSpellBank，不能被新枚举覆盖掉
      assert.equals(0, Enum.SpellBookSpellBank.Player)
    end)
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/WowMocks_spec.lua`
Expected: FAIL —`attempt to call method 'SetOrientation' (a nil value)`（5 个 it 块全红，因为 stub 还不存在）

- [ ] **Step 3: 在 widget 工厂里补录制型 stub**

在 `spec/helpers/wow_mocks.lua` 的 `widget()` 内，紧跟现有 `function w:SetAtlas(atlas) self.atlas = atlas end`（约 :183）之后插入：

```lua
    -- StatusBar / 裁剪 / 混合：OrbLiquid 的液位技法全靠这些。只录制不模拟——
    -- SetClipsChildren 的真实裁剪行为在 mock 里根本无法复现，视觉结果只能真机验收。
    function w:SetClipsChildren(clips) self.clipsChildren = clips end
    function w:SetOrientation(orientation) self.orientation = orientation end
    function w:SetReverseFill(reverse) self.reverseFill = reverse end
    function w:SetMinMaxValues(min, max) self.minMax = { min, max } end
    function w:SetStatusBarTexture(texture) self.statusBarTexture = texture end
    function w:SetStatusBarColor(...) self.statusBarColor = { ... } end
    function w:GetStatusBarColor() return table.unpack(self.statusBarColor or { 1, 1, 1, 1 }) end
    -- 真实签名 SetValue(value[, interpolation])；第二参数是 Enum.StatusBarInterpolation。
    function w:SetValue(value, interpolation) self.value = value; self.interpolation = interpolation end
    function w:GetValue() return self.value end
    function w:SetBlendMode(mode) self.blendMode = mode end
    function w:SetDrawLayer(layer, sublayer) self.drawLayer = layer; self.drawSublayer = sublayer end
    -- 返回一个稳定的 region，让「裁剪框的移动边锚到 driver 贴图」这类断言能按 identity 比较。
    function w:GetStatusBarTexture()
      if not self._statusBarTextureRegion then
        self._statusBarTextureRegion = widget("Texture", self)
        self.regions[#self.regions + 1] = self._statusBarTextureRegion
      end
      return self._statusBarTextureRegion
    end
```

- [ ] **Step 4: 让 CreateTexture 记录 sublayer，让 Rotation 记录 degrees**

同文件，把现有 `CreateTexture`（约 :211-215）替换为：

```lua
    -- 真实签名 CreateTexture([name],[layer],[inherits],[sublayer])；渲染栈的叠放次序
    -- 靠 sublayer 决定（gloss/shadow 同为 3、grid 为 4），所以必须录下来。
    function w:CreateTexture(_, drawLayer, _, sublayer)
      local region = widget("Texture", self, drawLayer)
      region.sublayer = sublayer
      self.regions[#self.regions + 1] = region
      return region
    end
```

把 `CreateAnimationGroup` 里 `CreateAnimation` 的动画记录器（约 :235-243）中，紧跟 `function a:SetDuration(d) self.duration = d end` 之后插入一行：

```lua
        function a:SetDegrees(degrees) self.degrees = degrees end
```

- [ ] **Step 5: 补 Enum.StatusBarInterpolation**

同文件，把 `_G.Enum = { SpellBookSpellBank = { Player = 0 } }`（约 :279）替换为：

```lua
    _G.Enum = {
      SpellBookSpellBank = { Player = 0 },
      -- 原生状态条插值模式；oUF 直接把它传给 StatusBar:SetValue 的第二参数。
      -- 只有这两个成员：warcraft.wiki.gg 的 Enum.StatusBarInterpolation 表与本机
      -- AddOns 的 88 处实际用法一致（55×Immediate、33×ExponentialEaseOut、8×防御性
      -- None）。不存在 Linear——臆造成员会让产品代码传 nil 而 spec 全绿。
      StatusBarInterpolation = {
        Immediate = 0,
        ExponentialEaseOut = 1,
      },
    }
```

> ✅ **Task 1 已完成。** 实现时纠正了本节初稿的两处错误：枚举原本写成 `{Immediate=0, Linear=1, ExponentialEaseOut=2}`，其中 `Linear` 是臆造的、`ExponentialEaseOut` 的值也错了；已按客户端真实值改为上表，并在 `spec/WowMocks_spec.lua` 里用显式数值 + 键计数（恰好 2 个）钉死，防止回退。另外补录了 `SetDrawLayer`（初稿漏了，driver 贴图要靠它压到 `BACKGROUND 0`）。`spec/WowMocks_spec.lua` 现为 6 条全绿。

- [ ] **Step 6: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/WowMocks_spec.lua`
Expected: PASS — `5 tests, 5 passed, 0 failed`

- [ ] **Step 7: 跑全套确认无回归**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/*_spec.lua`
Expected: PASS，`0 failed`。`CreateTexture` 多收了一个参数、`Enum` 多了一个键，都不应影响既有 spec。

- [ ] **Step 8: 交付说明（不提交）**

报告：新增了哪些 stub、全套测试条数与通过数。**不执行 `git commit`。**

---

## Task 2: 拷贝 9 个球体贴图到 Media/orb/

**Files:**
- Create: `Media/orb/orb_back.tga`、`orb_filling15.tga`、`orb_grid1.tga`、`orb_rotation_bubbles1.tga`、`orb_rotation_bubbles2.tga`、`orb_spark.tga`、`orb_spark_mask.tga`、`orb_gloss.tga`、`orb_shadow.tga`

无自动化测试（二进制资产），验证方式为逐文件 md5 比对源文件。

- [ ] **Step 1: 建目录并拷贝**

Run（仓库根执行）:

```bash
mkdir -p Media/orb
SRC="D:/software/World of Warcraft/_retail_/Interface/AddOns/!!!_Diablo/media"
for f in orb_back orb_filling15 orb_grid1 orb_rotation_bubbles1 orb_rotation_bubbles2 orb_spark orb_spark_mask orb_gloss orb_shadow; do
  cp "$SRC/$f.tga" "Media/orb/$f.tga"
done
ls -la Media/orb
```

Expected: 9 个 `.tga`。其中 `orb_spark.tga` ≈ 32K、`orb_spark_mask.tga` ≈ 106K，其余 7 个各 ≈ 256K。

- [ ] **Step 2: 逐文件 md5 比对源文件**

Run:

```bash
SRC="D:/software/World of Warcraft/_retail_/Interface/AddOns/!!!_Diablo/media"
for f in Media/orb/*.tga; do
  n=$(basename "$f")
  a=$(md5sum "$f" | cut -d' ' -f1)
  b=$(md5sum "$SRC/$n" | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then echo "OK   $n"; else echo "DIFF $n"; fi
done
```

Expected: 9 行全部 `OK`，无任何 `DIFF`。（本项目有过「逐文件同步导致游戏目录落后且静默失效」的教训，拷贝阶段就全量比对。）

- [ ] **Step 3: 确认总体积**

Run: `du -sh Media/orb`
Expected: 约 `1.9M`

- [ ] **Step 4: 交付说明（不提交）**

报告 9 个文件的 md5 比对结果与总体积。**不执行 `git commit`。**

---

## Task 3: Theme 新增 orb 贴图路径与两个语义色

**Files:**
- Modify: `Modules/Theme.lua`
- Test: `spec/Theme_spec.lua`

- [ ] **Step 1: 写失败的测试**

在 `spec/Theme_spec.lua` 的 `expectedKeys` 表（约 :14-24）末尾，`"settingsBoxBg", "swatchBorder",` 之后追加两项：

```lua
        "spellRatioElemental", "spellRatioEarthquake",
```

并在该文件顶层 `describe("Theme.lua", ...)` 内新增一个 `describe` 块（放在 `describe("token completeness", ...)` 之后）：

```lua
  describe("orb assets", function()
    it("maps all nine orb textures under Media/orb", function()
      local orb = Theme.textures.orb
      assert.is_table(orb)
      local prefix = "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\"
      local expected = {
        back      = prefix .. "orb_back.tga",
        filling   = prefix .. "orb_filling15.tga",
        grid      = prefix .. "orb_grid1.tga",
        bubbles1  = prefix .. "orb_rotation_bubbles1.tga",
        bubbles2  = prefix .. "orb_rotation_bubbles2.tga",
        spark     = prefix .. "orb_spark.tga",
        sparkMask = prefix .. "orb_spark_mask.tga",
        gloss     = prefix .. "orb_gloss.tga",
        shadow    = prefix .. "orb_shadow.tga",
      }
      for key, path in pairs(expected) do
        assert.equals(path, orb[key], "missing or wrong orb texture: " .. key)
      end
    end)

    it("keeps the two spell ratio colors as opaque semantic tokens", function()
      assert.same({ 179 / 255, 76 / 255, 255 / 255, 1 }, Theme.colors.spellRatioElemental)
      assert.same({ 201 / 255, 144 / 255, 46 / 255, 1 }, Theme.colors.spellRatioEarthquake)
    end)
  end)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/Theme_spec.lua`
Expected: FAIL —`missing or wrong orb texture: back`（`Theme.textures.orb` 为 nil），以及 token completeness 块报 `missing color token: spellRatioElemental`

- [ ] **Step 3: 加两个语义色**

在 `Modules/Theme.lua` 的 `FALLBACK` 表里，`-- Bloodlust / Heroism` 段落之前插入：

```lua
  -- Spell ratio orb（语义色 — 被比较的两个萨满技能，不随 accent 派生）
  spellRatioElemental  = { 179/255, 76/255,  255/255, 1 },  -- #B34CFF 元素冲击
  spellRatioEarthquake = { 201/255, 144/255, 46/255,  1 },  -- #C9902E 地震术

```

- [ ] **Step 4: 加 orb 贴图路径**

把 `Modules/Theme.lua` 里现有的 `Theme.textures` 表（约 :112-115）替换为：

```lua
local ORB_MEDIA = "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\"

Theme.textures = {
  circleWhite = "Interface\\AddOns\\MythicDungeonTools\\Textures\\Circle_White",
  statusBar   = "Interface\\TargetingFrame\\UI-StatusBar",
  -- 暗黑风格液体球。filling 一张染两次色当两种液体（暗黑就是这么做的，
  -- 从不靠换贴图区分颜色）；grid 是装饰环，按用户要求保留原图色、不染色。
  orb = {
    back      = ORB_MEDIA .. "orb_back.tga",
    filling   = ORB_MEDIA .. "orb_filling15.tga",
    grid      = ORB_MEDIA .. "orb_grid1.tga",
    bubbles1  = ORB_MEDIA .. "orb_rotation_bubbles1.tga",
    bubbles2  = ORB_MEDIA .. "orb_rotation_bubbles2.tga",
    spark     = ORB_MEDIA .. "orb_spark.tga",
    sparkMask = ORB_MEDIA .. "orb_spark_mask.tga",
    gloss     = ORB_MEDIA .. "orb_gloss.tga",
    shadow    = ORB_MEDIA .. "orb_shadow.tga",
  },
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/Theme_spec.lua`
Expected: PASS，`0 failed`

- [ ] **Step 6: 跑全套 + 交付说明（不提交）**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/*_spec.lua`
Expected: PASS，`0 failed`

报告新增的 token 与路径。**不执行 `git commit`。**

---

## Task 4: SpellRatioData:FillTenths 纯函数

**Files:**
- Modify: `Modules/SpellRatioData.lua`
- Test: `spec/SpellRatioData_spec.lua`

- [ ] **Step 1: 写失败的测试**

在 `spec/SpellRatioData_spec.lua` 末尾（最后一个 `end)` 之前，或文件末尾新增一个顶层块）追加：

```lua
describe("SpellRatioData:FillTenths", function()
  before_each(function() mocks.reset() end)

  local function load()
    mocks.withCooldownRuntime(function(env)
      env.dbChar.rotationRatios = {}
      mocks.loadSource("Modules/SpellRatioData.lua")
    end)
    return MDT_NPT.SpellRatioData
  end

  it("rounds to the nearest tenth", function()
    local d = load()
    assert.same({ elementalBlast = 8, earthquake = 2 }, d:FillTenths({ elementalBlast = 8, earthquake = 2 }))
    assert.same({ elementalBlast = 2, earthquake = 8 }, d:FillTenths({ elementalBlast = 2, earthquake = 8 }))
    assert.same({ elementalBlast = 5, earthquake = 5 }, d:FillTenths({ elementalBlast = 3, earthquake = 3 }))
  end)

  it("clamps both sides to at least one tenth when both counts are nonzero", function()
    local d = load()
    -- 1/46 = 2.2% → 未 clamp 会是 0，clamp 后为 1
    assert.same({ elementalBlast = 1, earthquake = 9 }, d:FillTenths({ elementalBlast = 1, earthquake = 45 }))
    -- 14% → 1（floor(1.4+0.5)=1）；15% → 2（floor(1.5+0.5)=2）
    assert.same({ elementalBlast = 1, earthquake = 9 }, d:FillTenths({ elementalBlast = 14, earthquake = 86 }))
    assert.same({ elementalBlast = 2, earthquake = 8 }, d:FillTenths({ elementalBlast = 15, earthquake = 85 }))
  end)

  it("allows a truly zero side to occupy the full range", function()
    local d = load()
    assert.same({ elementalBlast = 0, earthquake = 10 }, d:FillTenths({ elementalBlast = 0, earthquake = 5 }))
    assert.same({ elementalBlast = 10, earthquake = 0 }, d:FillTenths({ elementalBlast = 5, earthquake = 0 }))
  end)

  it("returns nil for a zero-zero row, mirroring RatioTenths", function()
    local d = load()
    assert.is_nil(d:FillTenths({ elementalBlast = 0, earthquake = 0 }))
    assert.is_nil(d:RatioTenths({ elementalBlast = 0, earthquake = 0 }))
  end)

  it("returns nil for malformed rows", function()
    local d = load()
    assert.is_nil(d:FillTenths(nil))
    assert.is_nil(d:FillTenths("nope"))
    assert.is_nil(d:FillTenths({ elementalBlast = -1, earthquake = 5 }))
    assert.is_nil(d:FillTenths({ elementalBlast = 1.5, earthquake = 5 }))
  end)

  it("diverges from RatioTenths, which never clamps", function()
    local d = load()
    local row = { elementalBlast = 1, earthquake = 45 }
    assert.same({ elementalBlast = 1, earthquake = 9 }, d:FillTenths(row))
    assert.same({ elementalBlast = 0, earthquake = 10 }, d:RatioTenths(row))
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioData_spec.lua`
Expected: FAIL —`attempt to call method 'FillTenths' (a nil value)`

- [ ] **Step 3: 实现 FillTenths**

在 `Modules/SpellRatioData.lua` 的 `RatioTenths` 之后（`MDT_NPT.SpellRatioData = SpellRatioData` 之前）插入：

```lua
--- 液位用的十等分。与 RatioTenths 刻意不同：双方原始次数都非零时各自 clamp 到
-- 1..9，保证任一侧只要真的施放过就至少占一档；单侧为零时仍允许 0/10。
-- 文字用 RatioTenths（不 clamp），所以 1/46 的液位是 1:9 而文字是 0:10。
function SpellRatioData:FillTenths(row)
  if type(row) ~= "table" or not validInteger(row.elementalBlast)
    or not validInteger(row.earthquake) then
    return nil
  end
  local total = row.elementalBlast + row.earthquake
  if total == 0 then return nil end
  local elementalBlast = math.floor(row.elementalBlast / total * 10 + 0.5)
  if row.elementalBlast > 0 and row.earthquake > 0 then
    elementalBlast = math.max(1, math.min(9, elementalBlast))
  end
  return {
    elementalBlast = elementalBlast,
    earthquake = 10 - elementalBlast,
  }
end
```

- [ ] **Step 4: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioData_spec.lua`
Expected: PASS，`0 failed`

- [ ] **Step 5: 跑全套 + 交付说明（不提交）**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/*_spec.lua`
Expected: PASS，`0 failed`（`RatioTenths` 未被触碰，既有断言不受影响）

报告新增的用例数。**不执行 `git commit`。**

---

## Task 5: OrbLiquid 静态渲染栈

**Files:**
- Create: `Modules/OrbLiquid.lua`
- Modify: `Modules/load_modules.xml`
- Test: `spec/OrbLiquid_spec.lua`（新建）

- [ ] **Step 1: 写失败的测试**

新建 `spec/OrbLiquid_spec.lua`：

```lua
local mocks = require("wow_mocks")

local SIZE = 96

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    mocks.loadSource("Modules/Theme.lua")
    mocks.loadSource("Modules/OrbLiquid.lua")
    env.orb = MDT_NPT.OrbLiquid:New(UIParent, SIZE)
    fn(env, env.orb)
  end)
end

--- region 的 SetPoint 记录里是否存在一条锚到 target 的 pointName
local function anchorsTo(region, target, pointName)
  for _, p in ipairs(region.points) do
    if p[2] == target and p[3] == pointName then return true end
  end
  return false
end

describe("OrbLiquid render stack", function()
  before_each(function() mocks.reset() end)

  it("creates a square orb frame of the requested size", function()
    scenario(function(_, orb)
      assert.equals("Frame", orb.kind)
      assert.equals(SIZE, orb:GetWidth())
      assert.equals(SIZE, orb:GetHeight())
    end)
  end)

  it("lays a full-size backdrop at BACKGROUND sublayer -6", function()
    scenario(function(_, orb)
      assert.equals("Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\orb_back.tga",
        orb.back.texture)
      assert.equals(0.4, orb.back.alpha)
      assert.equals(-6, orb.back.sublayer)
      assert.equals(orb, orb.back.allPoints)
    end)
  end)

  it("drives each liquid with an invisible vertical statusbar", function()
    scenario(function(_, orb)
      for _, driver in ipairs({ orb.eqDriver, orb.ebDriver }) do
        assert.equals("StatusBar", driver.kind)
        assert.equals("VERTICAL", driver.orientation)
        assert.equals(0, driver.alpha)
        assert.same({ 0, 10 }, driver.minMax)
        assert.equals("Interface\\Buttons\\WHITE8X8", driver.statusBarTexture)
        assert.equals(orb, driver.parent)
      end
      -- 只有元素冲击侧（顶部）反向填充
      assert.is_true(orb.ebDriver.reverseFill)
      assert.is_nil(orb.eqDriver.reverseFill)
    end)
  end)

  it("clips children and parents the clip frames to the orb, not the driver", function()
    scenario(function(_, orb)
      assert.is_true(orb.eqClip.clipsChildren)
      assert.is_true(orb.ebClip.clipsChildren)
      -- 关键：driver 是 SetAlpha(0) 的，框 alpha 会传播给子级，挂上去液体会变透明
      assert.equals(orb, orb.eqClip.parent)
      assert.equals(orb, orb.ebClip.parent)
      assert.equals(orb:GetFrameLevel() + 1, orb.eqClip:GetFrameLevel())
      assert.equals(orb:GetFrameLevel() + 1, orb.ebClip:GetFrameLevel())
      assert.is_false(orb.eqClip:IsMouseEnabled())
      assert.is_false(orb.ebClip:IsMouseEnabled())
    end)
  end)

  it("anchors the earthquake clip bottom to the orb and top to the driver texture", function()
    scenario(function(_, orb)
      local tex = orb.eqDriver:GetStatusBarTexture()
      assert.is_true(anchorsTo(orb.eqClip, orb.eqDriver, "BOTTOMLEFT"))
      assert.is_true(anchorsTo(orb.eqClip, orb.eqDriver, "BOTTOMRIGHT"))
      assert.is_true(anchorsTo(orb.eqClip, tex, "TOPLEFT"))
      assert.is_true(anchorsTo(orb.eqClip, tex, "TOPRIGHT"))
    end)
  end)

  it("anchors the elemental clip top to the orb and bottom to the reverse-filled texture", function()
    scenario(function(_, orb)
      local tex = orb.ebDriver:GetStatusBarTexture()
      assert.is_true(anchorsTo(orb.ebClip, orb, "TOPLEFT"))
      assert.is_true(anchorsTo(orb.ebClip, orb, "TOPRIGHT"))
      assert.is_true(anchorsTo(orb.ebClip, tex, "BOTTOMLEFT"))
      assert.is_true(anchorsTo(orb.ebClip, tex, "BOTTOMRIGHT"))
    end)
  end)

  it("sizes each liquid to the full orb so the artwork never scales", function()
    scenario(function(_, orb)
      for _, liquid in ipairs({ orb.eqLiquid, orb.ebLiquid }) do
        assert.equals(orb, liquid.allPoints)
        assert.equals("Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\orb_filling15.tga",
          liquid.texture)
        assert.same({ 0.05, 0.95, 0.05, 0.95 }, liquid.texCoord)
        assert.equals(-7, liquid.sublayer)
        assert.equals("BLEND", liquid.blendMode)
      end
      assert.equals(orb.eqClip, orb.eqLiquid.parent)
      assert.equals(orb.ebClip, orb.ebLiquid.parent)
    end)
  end)

  it("anchors each scroll frame to the orb bottom so bubbles cannot swim", function()
    scenario(function(_, orb)
      for _, scroll in ipairs({ orb.eqScroll, orb.ebScroll }) do
        assert.equals(SIZE, scroll:GetWidth())
        assert.equals(SIZE, scroll:GetHeight())
        assert.is_true(anchorsTo(scroll, orb, "BOTTOM"))
      end
      assert.equals(orb.eqClip, orb.eqScroll.parent)
      assert.equals(orb.ebClip, orb.ebScroll.parent)
    end)
  end)

  it("builds the overlay above the clips with spark, gloss, shadow and grid", function()
    scenario(function(_, orb)
      assert.equals(orb:GetFrameLevel() + 2, orb.overlay:GetFrameLevel())
      assert.equals(orb, orb.overlay.allPoints)

      assert.equals("Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\orb_gloss.tga",
        orb.gloss.texture)
      assert.equals(97.2, orb.gloss:GetWidth())
      assert.equals(0.8, orb.gloss.alpha)
      assert.equals(3, orb.gloss.sublayer)

      assert.equals("Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\orb_shadow.tga",
        orb.orbshadow.texture)
      assert.same({ 0, 0, 0 }, orb.orbshadow.vertexColor)
      assert.equals(0.25, orb.orbshadow.alpha)
      assert.equals(3, orb.orbshadow.sublayer)

      assert.equals("Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\orb_grid1.tga",
        orb.grid.texture)
      assert.equals(126, orb.grid:GetWidth())
      assert.equals(0.9, orb.grid.alpha)
      assert.equals(4, orb.grid.sublayer)
      -- 用户明确要求：装饰环保留原图色，不跟 EUI 主题。别把它「修正」回 accent。
      assert.is_nil(orb.grid.vertexColor)
    end)
  end)

  it("masks the spark strip to the orb and centers it on the liquid boundary", function()
    scenario(function(_, orb)
      assert.equals("MaskTexture", orb.sparkMask.kind)
      assert.equals(
        "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\orb_spark_mask.tga",
        orb.sparkMask.texture)
      assert.equals(110.4, orb.sparkMask:GetWidth())
      -- 遮罩必须锚到固定的 overlay 而不是会移动的高光线，
      -- 否则分界线在不同高度时切不出正确的圆形端点
      assert.is_true(anchorsTo(orb.sparkMask, orb.overlay, "CENTER"))

      assert.equals("Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\orb_spark.tga",
        orb.spark.texture)
      assert.equals(115.2, orb.spark:GetWidth())
      assert.equals(4.8, orb.spark:GetHeight())
      assert.equals("ADD", orb.spark.blendMode)
      assert.equals(orb.sparkMask, orb.spark.maskList[1])
      -- 高光线压在分界线上 = 地震侧裁剪框的 TOP
      assert.is_true(anchorsTo(orb.spark, orb.eqClip, "TOP"))
      assert.equals(orb.overlay, orb.spark.parent)
    end)
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/OrbLiquid_spec.lua`
Expected: FAIL —`LOAD FAIL spec/OrbLiquid_spec.lua: cannot open Modules/OrbLiquid.lua: No such file or directory`

- [ ] **Step 3: 写 Modules/OrbLiquid.lua（静态栈，暂不含动画）**

新建 `Modules/OrbLiquid.lua`：

```lua
--- OrbLiquid.lua — 暗黑风格双液体球（纯视觉部件）。
--
-- 液位不用缩放贴图，而是「隐形 StatusBar 当高度发生器 + SetClipsChildren 裁剪框 +
-- 框内满尺寸液体贴图」，这样液位变化时液面花纹不会被拉伸糊掉。技法来自
-- !!!_Diablo（units\player.lua:381-418）。
--
-- 本模块不知道 MDT、不知道 DB、不知道技能 ID。调用方通过 SetColors 注入两种颜色、
-- 通过 SetSplit 注入上下两侧的十等分液位。

local MDT_NPT = MDT_NPT
local Theme = MDT_NPT.Theme

local OrbLiquid = {}

local MAX_TENTHS = 10
local CROP_MIN, CROP_MAX = 0.05, 0.95   -- 裁掉 256² 源图 5% 边缘，遮住硬边与 mipmap 毛刺

local BACK_ALPHA   = 0.4    -- 暗黑默认 0.1，但 0:0 空球时只剩这一层，太淡会像球消失了
local GLOSS_ALPHA  = 0.8
local SHADOW_ALPHA = 0.25
local GRID_ALPHA   = 0.9    -- 暗黑默认 0（关掉的），我们要它当边框

-- 暗黑 160px 原值的分子。一律先乘后除（size * N / DIABLO_BASE）：
-- size * (N / DIABLO_BASE) 的浮点舍入与十进制字面量不一致，spec 无法精确断言。
local DIABLO_BASE = 160
local GRID_N      = 210   -- 装饰环，每边溢出
local GLOSS_N     = 162
local SHADOW_N    = 162
local MASK_N      = 184   -- 高光线圆形遮罩
local SPARK_W_N   = 192   -- 高光线，比遮罩宽，两端被切掉
local SPARK_H_N   = 8

local WHITE_8X8 = "Interface\\Buttons\\WHITE8X8"

local function side(size, numerator)
  return size * numerator / DIABLO_BASE
end

--- 居中的正方形贴图；用 SetSize + CENTER 而非暗黑的四边内缩锚点，
-- 后者算出的 inset 有浮点误差、无法精确断言，几何结果两者一致。
local function centeredSquare(texture, parent, size, numerator)
  local edge = side(size, numerator)
  texture:SetSize(edge, edge)
  texture:SetPoint("CENTER", parent, "CENTER", 0, 0)
end

local function createDriver(orb, reverse)
  local bar = CreateFrame("StatusBar", nil, orb)
  bar:SetAllPoints(orb)
  bar:SetMinMaxValues(0, MAX_TENTHS)
  bar:SetOrientation("VERTICAL")
  bar:SetStatusBarTexture(WHITE_8X8)
  bar:GetStatusBarTexture():SetDrawLayer("BACKGROUND", 0)
  bar:SetValue(0)
  bar:SetAlpha(0)          -- 纯几何驱动器，本身永不可见
  bar:EnableMouse(false)
  if reverse then bar:SetReverseFill(true) end
  return bar
end

--- 裁剪框必须 parent 到 orb 而不是 driver：driver 是 SetAlpha(0) 的，
-- 框 alpha 会向子级传播，挂上去整条液体会变透明。
local function createClip(orb, driver, reverse)
  local clip = CreateFrame("Frame", nil, orb)
  clip:SetFrameLevel(orb:GetFrameLevel() + 1)
  clip:EnableMouse(false)
  local driverTex = driver:GetStatusBarTexture()
  if reverse then
    -- 反向填充：贴图 TOP 固定在球顶，BOTTOM 是移动边 = 分界线
    clip:SetPoint("TOPLEFT", orb, "TOPLEFT")
    clip:SetPoint("TOPRIGHT", orb, "TOPRIGHT")
    clip:SetPoint("BOTTOMLEFT", driverTex, "BOTTOMLEFT")
    clip:SetPoint("BOTTOMRIGHT", driverTex, "BOTTOMRIGHT")
  else
    -- 正向填充：贴图 BOTTOM 固定在球底，TOP 是移动边 = 分界线
    clip:SetPoint("BOTTOMLEFT", driver, "BOTTOMLEFT")
    clip:SetPoint("BOTTOMRIGHT", driver, "BOTTOMRIGHT")
    clip:SetPoint("TOPLEFT", driverTex, "TOPLEFT")
    clip:SetPoint("TOPRIGHT", driverTex, "TOPRIGHT")
  end
  clip:SetClipsChildren(true)
  return clip
end

local function createLiquid(orb, clip, texturePath)
  local liquid = clip:CreateTexture(nil, "BACKGROUND", nil, -7)
  liquid:SetAllPoints(orb)     -- 满尺寸、从不缩放；裁剪框负责露出多少
  liquid:SetTexture(texturePath)
  liquid:SetTexCoord(CROP_MIN, CROP_MAX, CROP_MIN, CROP_MAX)
  liquid:SetBlendMode("BLEND")
  return liquid
end

--- 气泡的挂载框。锚到 orb 而不是 clip：clip 高度随液位变化、其 CENTER 会移动，
--- 气泡锚上去会随液位「游泳」。这也是暗黑要额外造一层 scrollChild 的真实原因。
local function createScroll(orb, clip, size)
  local scroll = CreateFrame("Frame", nil, clip)
  scroll:SetSize(size, size)
  scroll:SetPoint("BOTTOM", orb, "BOTTOM")
  scroll:EnableMouse(false)
  return scroll
end

function OrbLiquid:New(parent, size)
  local tex = Theme.textures.orb
  local orb = CreateFrame("Frame", nil, parent)
  orb:SetSize(size, size)
  orb.size = size

  orb.back = orb:CreateTexture(nil, "BACKGROUND", nil, -6)
  orb.back:SetAllPoints(orb)
  orb.back:SetTexture(tex.back)
  orb.back:SetAlpha(BACK_ALPHA)

  -- 地震术：底部，正向填充
  orb.eqDriver = createDriver(orb, false)
  orb.eqClip   = createClip(orb, orb.eqDriver, false)
  orb.eqLiquid = createLiquid(orb, orb.eqClip, tex.filling)
  orb.eqScroll = createScroll(orb, orb.eqClip, size)

  -- 元素冲击：顶部，反向填充
  orb.ebDriver = createDriver(orb, true)
  orb.ebClip   = createClip(orb, orb.ebDriver, true)
  orb.ebLiquid = createLiquid(orb, orb.ebClip, tex.filling)
  orb.ebScroll = createScroll(orb, orb.ebClip, size)

  orb.overlay = CreateFrame("Frame", nil, orb)
  orb.overlay:SetFrameLevel(orb:GetFrameLevel() + 2)
  orb.overlay:SetAllPoints(orb)
  orb.overlay:EnableMouse(false)

  -- 遮罩锚到固定的 overlay：分界线高度会变，固定圆形遮罩才能在任意高度
  -- 正确切掉高光线的两端。
  orb.sparkMask = orb.overlay:CreateMaskTexture()
  orb.sparkMask:SetTexture(tex.sparkMask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  centeredSquare(orb.sparkMask, orb.overlay, size, MASK_N)

  orb.spark = orb.overlay:CreateTexture(nil, "BACKGROUND", nil, -3)
  orb.spark:SetSize(side(size, SPARK_W_N), side(size, SPARK_H_N))
  orb.spark:SetPoint("CENTER", orb.eqClip, "TOP", 0, 0)
  orb.spark:SetTexture(tex.spark)
  orb.spark:SetBlendMode("ADD")
  orb.spark:AddMaskTexture(orb.sparkMask)

  orb.gloss = orb.overlay:CreateTexture(nil, "BACKGROUND", nil, 3)
  centeredSquare(orb.gloss, orb.overlay, size, GLOSS_N)
  orb.gloss:SetTexture(tex.gloss)
  orb.gloss:SetTexCoord(CROP_MIN, CROP_MAX, CROP_MIN, CROP_MAX)
  orb.gloss:SetAlpha(GLOSS_ALPHA)

  -- 创建顺序在 gloss 之后：同 sublevel 3 时靠创建顺序压在 gloss 上
  orb.orbshadow = orb.overlay:CreateTexture(nil, "BACKGROUND", nil, 3)
  centeredSquare(orb.orbshadow, orb.overlay, size, SHADOW_N)
  orb.orbshadow:SetTexture(tex.shadow)
  orb.orbshadow:SetVertexColor(0, 0, 0)
  orb.orbshadow:SetAlpha(SHADOW_ALPHA)

  -- sublevel 4（暗黑是 3）：让装饰环压在 gloss/shadow 之上保持锐利。
  -- 有意不调 SetVertexColor —— 保留原图色，不跟 EUI 主题。
  orb.grid = orb.overlay:CreateTexture(nil, "BACKGROUND", nil, 4)
  centeredSquare(orb.grid, orb.overlay, size, GRID_N)
  orb.grid:SetTexture(tex.grid)
  orb.grid:SetAlpha(GRID_ALPHA)

  return orb
end

MDT_NPT.OrbLiquid = OrbLiquid
```

- [ ] **Step 4: 注册到加载清单**

在 `Modules/load_modules.xml` 里，把 `<Script file='SpellRatioOrb.lua'/>` 替换为：

```xml
  <Script file='OrbLiquid.lua'/>
  <Script file='SpellRatioOrb.lua'/>
```

（必须在 `Theme.lua` 之后——`OrbLiquid.lua` 在 file scope 读 `MDT_NPT.Theme`。现有清单里 `Theme.lua` 已在第 6 行，满足。）

- [ ] **Step 5: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/OrbLiquid_spec.lua`
Expected: PASS — `10 tests, 10 passed, 0 failed`

- [ ] **Step 6: 跑全套 + 交付说明（不提交）**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/*_spec.lua`
Expected: PASS，`0 failed`

报告新增的断言数。**不执行 `git commit`。**

> ✅ **Task 5 已完成，并因代码质量评审做了如下修订（后续任务以修订后为准）：**
> - `side(size, numerator)` 已重命名为 **`scaled(size, numerator)`**（Task 6 的 `createBubble` 必须调 `scaled`，见上面已同步的代码）。原因：Task 7 会引入 `applySide(clip, tenths)`，那里的 "side" 指两种液体之一，与本函数的「长度」含义冲突。
> - `centeredSquare` 的形参 `parent` 已重命名为 **`anchorTo`**（它只作锚点参照，贴图真正的 parent 由各调用点的 `overlay:CreateTexture` 决定）。
> - 删除了只写不读的 `orb.size = size`。
> - 新增导出 **`OrbLiquid.GridSize(size)` / `OrbLiquid.GridOverhang(size)`**，Task 8 必须调它们而不是自己重算 `210/160`（已在 Task 8 Step 3 同步）。
> - 新增 file-local **`FORWARD, REVERSE = false, true`**，`New` 里的 `createDriver` / `createClip` 调用点用具名常量而非裸布尔。
> - `gloss` 裁剪而 `orbshadow` 不裁剪是**忠实于暗黑原实现**（`units\player.lua:585` 裁 `highlight`，`:591-600` 不裁 `orbshadow`），已在代码注释与本设计文档 6c/6d 行注明，不得「修正」成对称。
> - spec 补了约 22 条断言（draw layer、遮罩 wrap mode、gloss/orbshadow 创建顺序、锚点计数、driver allPoints 与 drawLayer、parent、gloss 高度、GridSize/GridOverhang），`it` 块数仍为 10。三处变异验证均已通过。
> - `spec/OrbLiquid_spec.lua` 10/10 绿；全套基线：唯一失败仍是 `CooldownPlanRender_spec` 的 2 条既有产品 bug。

---

## Task 6: OrbLiquid 气泡层与旋转动画

**Files:**
- Modify: `Modules/OrbLiquid.lua`
- Test: `spec/OrbLiquid_spec.lua`

- [ ] **Step 1: 写失败的测试**

在 `spec/OrbLiquid_spec.lua` 末尾追加一个新的顶层 `describe`：

```lua
describe("OrbLiquid bubble animation", function()
  before_each(function() mocks.reset() end)

  it("creates four oversized bubble layers parented to the scroll frames", function()
    scenario(function(_, orb)
      assert.equals(2, #orb.eqBubbles)
      assert.equals(2, #orb.ebBubbles)
      for _, b in ipairs(orb.eqBubbles) do
        assert.equals(orb.eqScroll, b.parent)
        assert.equals("ADD", b.blendMode)
        assert.is_true(b:GetWidth() > SIZE)   -- 故意溢出，裁剪框才切进气泡场内部
      end
      for _, b in ipairs(orb.ebBubbles) do
        assert.equals(orb.ebScroll, b.parent)
        assert.equals("ADD", b.blendMode)
        assert.is_true(b:GetWidth() > SIZE)
      end
      -- 内层 168/160、外层 162/160
      assert.equals(100.8, orb.eqBubbles[1]:GetWidth())
      assert.equals(97.2, orb.eqBubbles[2]:GetWidth())
      assert.equals(
        "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\orb_rotation_bubbles1.tga",
        orb.eqBubbles[1].texture)
      assert.equals(
        "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\orb_rotation_bubbles2.tga",
        orb.eqBubbles[2].texture)
    end)
  end)

  it("spins each layer one turn with coprime-ish periods", function()
    scenario(function(_, orb)
      -- 地震侧：+360/30s 与 -360/45s（LCM 90s，肉眼读不出循环）
      assert.same({ degrees = 360, duration = 30 }, rotationOf(orb.eqBubbles[1]))
      assert.same({ degrees = -360, duration = 45 }, rotationOf(orb.eqBubbles[2]))
      -- 元素侧反向，与地震侧互为镜像
      assert.same({ degrees = -360, duration = 30 }, rotationOf(orb.ebBubbles[1]))
      assert.same({ degrees = 360, duration = 45 }, rotationOf(orb.ebBubbles[2]))
    end)
  end)

  it("mirrors the second earthquake layer and the first elemental layer", function()
    scenario(function(_, orb)
      assert.is_nil(orb.eqBubbles[1].texCoord)
      assert.same({ 1, 0, 0, 1 }, orb.eqBubbles[2].texCoord)
      assert.same({ 1, 0, 0, 1 }, orb.ebBubbles[1].texCoord)
      assert.is_nil(orb.ebBubbles[2].texCoord)
    end)
  end)

  it("gives every alpha animation an explicit from and to", function()
    scenario(function(_, orb)
      local BUBBLE_ALPHA = 0.3
      local DIMMED = 0.3 * 0.3   -- 与产品代码同一浮点表达式，避免舍入不等
      local checked = 0
      for _, bubble in ipairs({
        orb.eqBubbles[1], orb.eqBubbles[2], orb.ebBubbles[1], orb.ebBubbles[2],
      }) do
        for _, a in ipairs(alphaAnimationsOf(bubble)) do
          -- 暗黑原版把 SetFromAlpha/SetToAlpha 注释掉靠调用方后补，照抄会静默
          -- 退化成 fade-to-1。这里钉死两者都必须显式给出，且只能是这一对值之一。
          assert.is_number(a.from, "alpha animation missing SetFromAlpha")
          assert.is_number(a.to, "alpha animation missing SetToAlpha")
          local isDimming = a.from == BUBBLE_ALPHA and a.to == DIMMED
          local isBrightening = a.from == DIMMED and a.to == BUBBLE_ALPHA
          assert.is_true(isDimming or isBrightening,
            "unexpected alpha range: " .. tostring(a.from) .. " -> " .. tostring(a.to))
          checked = checked + 1
        end
      end
      assert.equals(8, checked)   -- 4 层 × 2 个 Alpha 动画
    end)
  end)

  it("oscillates each layer between its alpha and 30 percent of it", function()
    scenario(function(_, orb)
      local b = orb.eqBubbles[1]
      local alphas = alphaAnimationsOf(b)
      assert.equals(2, #alphas)
      -- 非镜像层：dim 是 Order 1（0.3 → 0.09），bright 是 Order 2（0.09 → 0.3）
      local dim, bright
      for _, a in ipairs(alphas) do
        if a.from > a.to then dim = a else bright = a end
      end
      assert.equals(1, dim.order)
      assert.equals(2, bright.order)
      assert.equals(16, dim.duration)      -- 30/3 + 6
      assert.equals(16, bright.duration)
      assert.equals(0.3, dim.from)
      assert.equals(0.3 * 0.3, dim.to)
      assert.equals(0.3 * 0.3, bright.from)
      assert.equals(0.3, bright.to)
      -- 外层气泡自转 45s，脉冲相位随之变长（duration/3 + 6）
      assert.equals(21, alphaAnimationsOf(orb.eqBubbles[2])[1].duration)
    end)
  end)

  it("swaps the alpha order on mirrored layers so pulses run half a cycle apart", function()
    scenario(function(_, orb)
      local normal = orderPair(orb.eqBubbles[1])
      local mirrored = orderPair(orb.eqBubbles[2])
      -- 镜像层把两个 Alpha 动画的 Order 对调，叠加出非周期感的晃动
      assert.equals({ 1, 2 }, { normal.dim.order, normal.bright.order })
      assert.equals({ 2, 1 }, { mirrored.dim.order, mirrored.bright.order })
    end)
  end)

  it("plays every animation group on repeat", function()
    scenario(function(env, orb)
      -- 4 层 × 2 组（Rotation + Alpha）= 8 组，全部构造时就在播放
      assert.equals(8, #env.animations)
      for _, ag in ipairs(env.animations) do
        assert.is_true(ag:IsPlaying())
        assert.equals("REPEAT", ag.looping)
        assert.equals(1, ag.plays)
      end
    end)
  end)

  it("creates no ticker and no OnUpdate script", function()
    scenario(function(env, orb)
      assert.equals(0, #env.tickers)
      assert.is_nil(orb.eqScroll:GetScript("OnUpdate"))
      assert.is_nil(orb.ebScroll:GetScript("OnUpdate"))
      assert.is_nil(orb.overlay:GetScript("OnUpdate"))
    end)
  end)
end)
```

并在 `spec/OrbLiquid_spec.lua` 顶部的 `anchorsTo` 之后补三个测试辅助函数：

```lua
--- 从 widget 的 regions 里取该 texture 创建的动画组（mock 用 ag.owner 记录归属）
local function groupsOf(texture)
  local out = {}
  for _, ag in ipairs(_G.__orbTestAnimations or {}) do
    if ag.owner == texture then out[#out + 1] = ag end
  end
  return out
end

local function rotationOf(texture)
  for _, ag in ipairs(groupsOf(texture)) do
    for _, a in ipairs(ag.animations) do
      if a.kind == "Rotation" then return { degrees = a.degrees, duration = a.duration } end
    end
  end
  error("no Rotation animation on texture")
end

local function alphaAnimationsOf(texture)
  local out = {}
  for _, ag in ipairs(groupsOf(texture)) do
    for _, a in ipairs(ag.animations) do
      if a.kind == "Alpha" then out[#out + 1] = a end
    end
  end
  return out
end

--- 按 from/to 分辨「变暗」与「变亮」两个 Alpha 动画，用于断言 Order 是否被对调
local function orderPair(texture)
  local dim, bright
  for _, a in ipairs(alphaAnimationsOf(texture)) do
    if a.from > a.to then dim = a else bright = a end
  end
  assert.is_not_nil(dim, "no dimming alpha animation")
  assert.is_not_nil(bright, "no brightening alpha animation")
  return { dim = dim, bright = bright }
end
```

`groupsOf` 需要能枚举本次 scenario 里创建的所有动画组。`wow_mocks` 已经把它们收进 `env.animations`，所以把 `scenario` 改成在创建 orb 前把 `env.animations` 暴露给测试辅助函数——将 `spec/OrbLiquid_spec.lua` 里的 `scenario` 替换为：

```lua
local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    mocks.loadSource("Modules/Theme.lua")
    mocks.loadSource("Modules/OrbLiquid.lua")
    _G.__orbTestAnimations = env.animations   -- 测试抓手，见 groupsOf
    env.orb = MDT_NPT.OrbLiquid:New(UIParent, SIZE)
    fn(env, env.orb)
    _G.__orbTestAnimations = nil
  end)
end
```

- [ ] **Step 2: 在 mock 里补 SetLooping 记录**

`spec/OrbLiquid_spec.lua` 断言了 `ag.looping`，而 `wow_mocks.lua` 的动画组记录器还没有它。在 `spec/helpers/wow_mocks.lua` 的 `function group:IsPlaying() return self.playing end`（约 :249）之后插入：

```lua
      function group:SetLooping(mode) self.looping = mode end
```

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/WowMocks_spec.lua`
Expected: PASS，`0 failed`（新方法是纯增补，不影响既有断言）

- [ ] **Step 3: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/OrbLiquid_spec.lua`
Expected: FAIL —`attempt to index field 'eqBubbles' (a nil value)`；前一个 describe 的 10 条仍 PASS

- [ ] **Step 4: 实现气泡层**

在 `Modules/OrbLiquid.lua` 里，`local SPARK_H_N   = 8` 之后追加常量：

```lua
local BUBBLE1_N   = 168   -- 内层，故意比球大，裁剪框才切进气泡场内部
local BUBBLE2_N   = 162
local BUBBLE_ALPHA = 0.3
local BUBBLE_DIM   = 0.3  -- 脉冲下界 = alpha × 0.3
```

在 `createScroll` 之后插入气泡工厂：

```lua
--- 一层反向旋转的气泡。旋转周期与 Alpha 脉冲周期耦合（duration/3 + 6），
--- 转得慢的层脉得也慢，这是「液体」错觉的来源之一。
-- mirrored 层把两个 Alpha 动画的 Order 对调，使两层脉冲错开半个周期：
-- 两个反相的周期信号叠加读起来是非周期的。
local function createBubble(scroll, size, texturePath, numerator, degrees, duration, mirrored)
  local t = scroll:CreateTexture(nil, "ARTWORK", nil, mirrored and -2 or -1)
  local edge = scaled(size, numerator)   -- Task 5 已把 side() 重命名为 scaled()
  t:SetSize(edge, edge)
  t:SetPoint("CENTER", scroll, "CENTER", 0, 0)
  t:SetTexture(texturePath)
  if mirrored then t:SetTexCoord(1, 0, 0, 1) end
  t:SetBlendMode("ADD")     -- ADD=发光：交叠处加亮，读作光在液体里折射
  t:SetAlpha(BUBBLE_ALPHA)

  local spin = t:CreateAnimationGroup()
  local rotation = spin:CreateAnimation("Rotation")
  rotation:SetDegrees(degrees)
  rotation:SetDuration(duration)
  rotation:SetOrder(1)
  spin:SetLooping("REPEAT")
  spin:Play()

  local pulse = t:CreateAnimationGroup()
  local phase = duration / 3 + 6
  local dim = pulse:CreateAnimation("Alpha")
  dim:SetDuration(phase)
  dim:SetFromAlpha(BUBBLE_ALPHA)
  dim:SetToAlpha(BUBBLE_ALPHA * BUBBLE_DIM)
  local bright = pulse:CreateAnimation("Alpha")
  bright:SetDuration(phase)
  bright:SetFromAlpha(BUBBLE_ALPHA * BUBBLE_DIM)
  bright:SetToAlpha(BUBBLE_ALPHA)
  if mirrored then
    dim:SetOrder(2)
    bright:SetOrder(1)
  else
    dim:SetOrder(1)
    bright:SetOrder(2)
  end
  pulse:SetLooping("REPEAT")
  pulse:Play()

  return t
end

local function createBubbles(scroll, size, tex, mirrored)
  -- 与地震侧互为镜像：度数取反、镜像层互换，避免读成同一张图叠两次
  local sign = mirrored and -1 or 1
  return {
    createBubble(scroll, size, tex.bubbles1, BUBBLE1_N, sign * 360, 30, mirrored),
    createBubble(scroll, size, tex.bubbles2, BUBBLE2_N, -sign * 360, 45, not mirrored),
  }
end
```

在 `OrbLiquid:New` 里，紧跟 `orb.eqScroll = createScroll(orb, orb.eqClip, size)` 之后插入一行：

```lua
  orb.eqBubbles = createBubbles(orb.eqScroll, size, tex, false)
```

紧跟 `orb.ebScroll = createScroll(orb, orb.ebClip, size)` 之后插入一行：

```lua
  orb.ebBubbles = createBubbles(orb.ebScroll, size, tex, true)
```

- [ ] **Step 5: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/OrbLiquid_spec.lua`
Expected: PASS — `18 tests, 18 passed, 0 failed`

若 `spins each layer one turn with coprime-ish periods` 报度数不符，检查 `createBubbles` 里 `sign` 的取反是否把「元素侧整体反向」与「每侧第二层镜像」两个概念混在了一起：期望值为 eq = `{+360, -360}`、eb = `{-360, +360}`。

- [ ] **Step 6: 跑全套 + 交付说明（不提交）**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/*_spec.lua`
Expected: PASS，`0 failed`

报告动画组总数与断言数。**不执行 `git commit`。**

> ✅ **Task 6 已完成，并因评审做了如下修订（后续任务以修订后为准）：**
> - **计划里有一处 bug 已被实现方纠正**：order-swap 测试原本写 `assert.equals({1,2}, {...})`，两个表字面量用 `equals` 比是**按 identity 比**（`minibusted.lua:35` 用 `expected == actual`，真 luassert 的 `are.equal` 也是浅比较），即使产品代码正确也必红。已改为 `assert.same`。全仓库 `grep "assert.equals({"` 零命中，没有第二处。
> - `createBubble` 的 sublayer **不再由 `mirrored` 派生**，改为显式形参，`createBubbles` 对两侧都传 `-1`（层1）/ `-2`（层2）。原式 `mirrored and -2 or -1` 会让 eb 侧变成 `-2,-1`，与设计文档 3c/5a-c 行矛盾。ADD 混合可交换，像素零变化。因此 `createBubble` 现为 **8 个形参**（`sublayer` 放在动画三元组之前，与暗黑 `…, texture, sublevel, degree, blend` 的次序一致）。
> - `createBubbles` 的形参 `mirrored` 已重命名为 **`reverseSide`**：它与 `createBubble` 的 `mirrored`（指该层是否水平翻转）同名不同义，且 `createBubbles` 会把 `mirrored` 与 `not mirrored` 传下去，极易误读。
> - 气泡复用了 Task 5 的 `centeredSquare` 助手而非内联 `SetSize`+`SetPoint`（几何逐字节等价，且把「先乘后除」不变量收在一处）。
> - 新增注释：`spin` 与 `pulse` **必须是两个独立 AnimationGroup**——同组内动画按 `Order` 顺序播放且 `REPEAT` 从 Order 1 重启，合并会导致自转 30s 后**冻结 16s**；以及为何不调 `SetOrigin`（`Rotation` 默认绕 region CENTER，而 `centeredSquare` 已把它放在球心）。
> - **Alpha 动画语义已定案：覆盖（override），不是乘算。** 铁证来自零售线上代码 `Ayije_CDM/Libs/LibCustomGlow-1.0/LibCustomGlow-1.0.lua:794-808`——它把基准 `SetAlpha(0)` 后动画到 `1`，乘算语义下永远不可见。故 `t:SetAlpha(BUBBLE_ALPHA)` 保留：它让首帧前的 alpha 等于脉冲上界而非默认 1.0，避免一帧全亮 ADD 闪白，也是动画停止后的静息值。
> - **气泡不做 `SetVertexColor` 占位**（暗黑那个 0.5 灰是为覆盖「事件驱动的颜色钩子晚一帧」的空档；我们的 `SetColors` 由 `Update()` 同步调用，Lua 跑完才渲染，可证明零帧未染色）。Task 7 的 `SetColors` 直接给全色。
> - 两侧第二层都用 **45s**（暗黑反填充球用 60s，但 `LCM(30,60)=60` 比我们的 `LCM(30,45)=90` 更早重合，我们的更好）。
> - spec 仍为 **18 个 `it`**（10 + 8），新增约 12 条断言：气泡 CENTER 锚到本侧 `scroll`（**这是唯一的真实漏洞**——只钉 parent 不钉锚点的话，改锚到 clip CENTER 会全绿却在游戏里随液位「游泳」）、锚点计数 1、sublayer、`alpha == 0.3`、`layer == "ARTWORK"`。三处变异验证均已通过。
> - `spec/helpers/wow_mocks.lua` 仅增一行 `group:SetLooping(mode)` 录制器。

---

## Task 7: OrbLiquid 的 SetSplit / SetColors

**Files:**
- Modify: `Modules/OrbLiquid.lua`
- Test: `spec/OrbLiquid_spec.lua`

- [ ] **Step 1: 写失败的测试**

在 `spec/OrbLiquid_spec.lua` 末尾追加：

```lua
describe("OrbLiquid SetSplit / SetColors", function()
  before_each(function() mocks.reset() end)

  it("writes both driver bars with the exponential ease interpolation", function()
    scenario(function(_, orb)
      orb:SetSplit(8, 2)
      assert.equals(8, orb.ebDriver.value)
      assert.equals(2, orb.eqDriver.value)
      assert.equals(Enum.StatusBarInterpolation.ExponentialEaseOut, orb.ebDriver.interpolation)
      assert.equals(Enum.StatusBarInterpolation.ExponentialEaseOut, orb.eqDriver.interpolation)
    end)
  end)

  it("shows both regions for an ordinary split", function()
    scenario(function(_, orb)
      orb:SetSplit(7, 3)
      assert.is_true(orb.ebClip:IsShown())
      assert.is_true(orb.eqClip:IsShown())
      assert.is_true(orb.spark:IsShown())
    end)
  end)

  it("hides the whole clip frame for a zero side so bubbles cannot orphan", function()
    scenario(function(_, orb)
      orb:SetSplit(0, 10)
      assert.is_false(orb.ebClip:IsShown())
      assert.is_true(orb.eqClip:IsShown())
      -- 只有一种液体时不存在交界弯月面；且 eqClip TOP 此时塌缩到球底，
      -- 显示出来会是一条画在满球底缘的错位高光线
      assert.is_false(orb.spark:IsShown())

      orb:SetSplit(10, 0)
      assert.is_true(orb.ebClip:IsShown())
      assert.is_false(orb.eqClip:IsShown())
      assert.is_false(orb.spark:IsShown())
    end)
  end)

  it("hides both clips and the spark for an empty orb", function()
    scenario(function(_, orb)
      orb:SetSplit(0, 0)
      assert.is_false(orb.ebClip:IsShown())
      assert.is_false(orb.eqClip:IsShown())
      -- 高光线锚在 eqClip TOP；隐藏框不会让锚点失效，所以它会停在球底那个
      -- 没有液体的位置，必须显式隐藏
      assert.is_false(orb.spark:IsShown())
      -- 恒显的四层不受影响
      assert.is_true(orb.back:IsShown())
      assert.is_true(orb.gloss:IsShown())
      assert.is_true(orb.orbshadow:IsShown())
      assert.is_true(orb.grid:IsShown())
    end)
  end)

  it("restores a region that was hidden by a previous split", function()
    scenario(function(_, orb)
      orb:SetSplit(0, 10)
      assert.is_false(orb.ebClip:IsShown())
      orb:SetSplit(4, 6)
      assert.is_true(orb.ebClip:IsShown())
      assert.is_true(orb.eqClip:IsShown())
    end)
  end)

  it("tints each liquid and its bubbles from the injected colors", function()
    scenario(function(_, orb)
      local purple = { 179 / 255, 76 / 255, 255 / 255, 1 }
      local gold = { 201 / 255, 144 / 255, 46 / 255, 1 }
      orb:SetColors(purple, gold)

      assert.same(purple, orb.ebLiquid.vertexColor)
      assert.same(gold, orb.eqLiquid.vertexColor)
      for _, b in ipairs(orb.ebBubbles) do assert.same(purple, b.vertexColor) end
      for _, b in ipairs(orb.eqBubbles) do assert.same(gold, b.vertexColor) end
      -- 装饰环不在染色范围内
      assert.is_nil(orb.grid.vertexColor)
    end)
  end)

  it("defaults the alpha channel when a color has only three components", function()
    scenario(function(_, orb)
      orb:SetColors({ 0.5, 0.25, 0.75 }, { 0.1, 0.2, 0.3 })
      assert.same({ 0.5, 0.25, 0.75, 1 }, orb.ebLiquid.vertexColor)
      assert.same({ 0.1, 0.2, 0.3, 1 }, orb.eqLiquid.vertexColor)
    end)
  end)

  it("starts fully empty before the first SetSplit", function()
    scenario(function(_, orb)
      assert.equals(0, orb.ebDriver.value)
      assert.equals(0, orb.eqDriver.value)
    end)
  end)
end)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/OrbLiquid_spec.lua`
Expected: FAIL —`attempt to call method 'SetSplit' (a nil value)`；前 18 条仍 PASS

- [ ] **Step 3: 实现 SetSplit 与 SetColors**

在 `Modules/OrbLiquid.lua` 的 `OrbLiquid:New` 之后、`MDT_NPT.OrbLiquid = OrbLiquid` 之前插入：

```lua
local function applyColor(liquid, bubbles, color)
  local r, g, b = color[1], color[2], color[3]
  local a = color[4] or 1
  liquid:SetVertexColor(r, g, b, a)
  for _, bubble in ipairs(bubbles) do
    bubble:SetVertexColor(r, g, b, a)
  end
end

--- 某一侧为 0 时隐藏整个裁剪框，而不是只隐藏液体：液体和气泡都在裁剪框子树里，
--- 只隐藏液体会让气泡作为孤儿继续旋转，空球里凭空转着两团泡沫。
local function applySide(clip, tenths)
  if tenths > 0 then
    clip:Show()
  else
    clip:Hide()
  end
end

--- topTenths / bottomTenths：0..10 整数。top = 元素冲击（反向填充），bottom = 地震术。
--- 两侧同帧写入同一缓动曲线，目标值合计 10 时中间值也严格互补，分界线不出缝不重叠。
--- 高光线是「两种液体的交界弯月面」，只有一侧有液体时不存在交界。
--- 必须两侧都 >0：spark 锚在 eqClip TOP，eq==0 时 eqClip 塌缩到球底，
--- 于是 eb=10/eq=0（整球紫）会把高光线画在球底边缘——而满球的液面其实在球顶。
--- 隐藏框不会使其锚点失效，所以必须显式 Hide()。
function OrbLiquid.SetSplit(orb, topTenths, bottomTenths)
  local ease = Enum.StatusBarInterpolation.ExponentialEaseOut
  orb.ebDriver:SetValue(topTenths, ease)
  orb.eqDriver:SetValue(bottomTenths, ease)
  applySide(orb.ebClip, topTenths)
  applySide(orb.eqClip, bottomTenths)
  if topTenths > 0 and bottomTenths > 0 then
    orb.spark:Show()
  else
    orb.spark:Hide()
  end
end

function OrbLiquid.SetColors(orb, topColor, bottomColor)
  applyColor(orb.ebLiquid, orb.ebBubbles, topColor)
  applyColor(orb.eqLiquid, orb.eqBubbles, bottomColor)
end
```

- [ ] **Step 4: 把两个方法挂到实例上**

⚠️ **这一步不做，前面所有 `orb:SetSplit(...)` 调用都会 `attempt to call method 'SetSplit' (a nil value)`。**

`OrbLiquid:New` 返回的是 `CreateFrame("Frame", ...)` 的结果——一个 **Frame**，不是带 `__index = OrbLiquid` 的表。Frame 已经有自己的 metatable 承载 widget 方法，**不能**用 `setmetatable(orb, { __index = OrbLiquid })` 覆盖它（那会让 `orb:SetSize` 之类全部失效）。所以直接把方法赋值到实例上。

在 `Modules/OrbLiquid.lua` 的 `OrbLiquid:New` 里，把结尾的：

```lua
  return orb
end
```

替换为：

```lua
  -- New 返回的是 Frame，不是带 __index 的表，方法必须显式挂到实例上。
  -- 这里按名查表，所以 SetSplit / SetColors 定义在 New 之后也能正常工作
  -- （New 的函数体在调用时才求值，那时整个文件已加载完）。
  orb.SetSplit = OrbLiquid.SetSplit
  orb.SetColors = OrbLiquid.SetColors

  return orb
end
```

- [ ] **Step 5: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/OrbLiquid_spec.lua`
Expected: PASS — `26 tests, 26 passed, 0 failed`

- [ ] **Step 6: 跑全套 + 交付说明（不提交）**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/*_spec.lua`
Expected: PASS，`0 failed`

**不执行 `git commit`。**

> ✅ **Task 7 已完成，代码与计划逐字节一致（仅注释为纯增补）。26/26 绿；评审跑了 21 处变异，20 处被捕获。补充修订：**
> - 唯一存活的变异是**把两行方法挂载换成 `setmetatable(orb, {__index = OrbLiquid})`——26 条测试全绿**，因为 mock 没有真正的 Frame metatable。已补 `assert.is_function(rawget(orb, "SetSplit"))` / `SetColors` 两条断言钉死：`rawget` 绕过 `__index`，只有直接赋值能通过。变异复验已确认能捕获。
> - `SetColors` 文档注释补了两条 Task 8 必须遵守的契约：**参数是 top 先 bottom 后**（搞反不报错，只得到颜色互换但仍然好看的球）；**必须与 `New()` 在同一次 Lua 执行内调用**（气泡刻意无占位顶点色，推迟到事件回调会有一帧全亮 ADD 闪白）。
> - `SetSplit` 文档注释补了一句说明为何用点号 + 显式 `orb` 形参而非冒号语法。
> - 修正了本文档与设计文档里的一处措辞错误：`eb=10, eq=0`（整球紫）时高光线落在球**底**，而满球的液面其实在球**顶**——原写成「液面却在底部」，代码注释是对的，两份文档已改。

---

## Task 8: SpellRatioOrb 改用 OrbLiquid

**Files:**
- Modify: `Modules/SpellRatioOrb.lua`
- Modify: `spec/SpellRatioOrb_spec.lua`

- [ ] **Step 1: 改写 10 个作废断言（先让测试表达新契约）**

在 `spec/SpellRatioOrb_spec.lua` 顶部，把 `local MASK_TEXTURE = ...`（:3）整行删除，替换为：

```lua
local ORB_MEDIA = "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\"
local ORB_SIZE = 96
local GRID_SIZE = 126
local FRAME_W = 126
local FRAME_H = 144
local EASE = nil   -- 在 scenario 内捕获，见下
```

把 `scenario` 里的加载序列（:61-63）替换为：

```lua
    mocks.loadSource("Modules/Theme.lua")
    mocks.loadSource("Modules/SpellRatioData.lua")
    mocks.loadSource("Modules/OrbLiquid.lua")
    mocks.loadSource("Modules/SpellRatioOrb.lua")
    EASE = Enum.StatusBarInterpolation.ExponentialEaseOut
```

在 `local function point(region)`（:73-75）之后追加：

```lua
--- region 的 SetPoint 记录里是否存在一条锚到 target 的 pointName
local function anchorsTo(region, target, pointName)
  for _, p in ipairs(region.points) do
    if p[2] == target and p[3] == pointName then return true end
  end
  return false
end
```

然后逐块替换下列 10 个 `it()`：

**① 替换 `creates the named 64/60 orb and 20px icons without a ticker`（:113-128）：**

```lua
  it("creates the named 96px orb inside a 126-wide frame with 20px icons and no ticker", function()
    scenario(function(env, orb)
      local frame = orb:GetFrame()
      assert.equals("MDTNPTSpellRatioOrb", frame:GetName())
      assert.equals(ORB_SIZE, frame.orb:GetWidth())
      assert.equals(ORB_SIZE, frame.orb:GetHeight())
      assert.equals(GRID_SIZE, frame.orb.grid:GetWidth())
      assert.equals(20, frame.primaryIcon:GetWidth())
      assert.equals(20, frame.primaryIcon:GetHeight())
      assert.equals(20, frame.secondaryIcon:GetWidth())
      assert.equals(20, frame.secondaryIcon:GetHeight())
      assert.is_true(frame.clamped)
      assert.equals(0, #env.tickers)
    end)
  end)
```

**② 替换 `defaults to scale one without changing base geometry`（:130-137）：**

```lua
  it("defaults to scale one without changing base geometry", function()
    scenario(function(_, orb)
      local frame = orb:GetFrame()
      assert.equals(1, frame:GetScale())
      assert.equals(FRAME_W, frame:GetWidth())
      assert.equals(FRAME_H, frame:GetHeight())
    end)
  end)
```

**③ 替换 `attaches real circular masks and places purple above orange`（:179-193）：**

```lua
  it("clips two full-size liquids with the purple side reverse-filled above the gold", function()
    scenario(function(_, orb)
      local o = orb:GetFrame().orb
      assert.is_true(o.eqClip.clipsChildren)
      assert.is_true(o.ebClip.clipsChildren)
      assert.equals("VERTICAL", o.eqDriver.orientation)
      assert.equals("VERTICAL", o.ebDriver.orientation)
      assert.is_true(o.ebDriver.reverseFill)
      assert.is_nil(o.eqDriver.reverseFill)
      -- 液体满尺寸、从不缩放；裁剪框负责露出多少
      assert.equals(o, o.eqLiquid.allPoints)
      assert.equals(o, o.ebLiquid.allPoints)
      assert.equals(o.eqClip, o.eqLiquid.parent)
      assert.equals(o.ebClip, o.ebLiquid.parent)
      assert.equals(ORB_MEDIA .. "orb_filling15.tga", o.eqLiquid.texture)
      assert.equals(ORB_MEDIA .. "orb_filling15.tga", o.ebLiquid.texture)
      -- 裁剪框挂在 orb 上而不是 driver 上（driver 是 SetAlpha(0) 的）
      assert.equals(o, o.eqClip.parent)
      assert.equals(o, o.ebClip.parent)
      assert.is_true(anchorsTo(o.spark, o.eqClip, "TOP"))
    end)
  end)
```

**④ 替换 `uses Theme.colors.accent for the outer ring`（:195-203）：**

```lua
  it("keeps the decorative grid ring in its original artwork color", function()
    scenario(function(_, orb)
      local o = orb:GetFrame().orb
      assert.equals(ORB_MEDIA .. "orb_grid1.tga", o.grid.texture)
      assert.equals(0.9, o.grid.alpha)
      -- 锁定用户决定：环保留参考美术原色，不跟 EUI 主题。别把它「修正」回 accent。
      assert.is_nil(o.grid.vertexColor)
      -- 球体不再消费任何 EUI 派生色，所以 Update 也不该再刷主题
      seed(8, 2)
      local refreshCalls = 0
      local realRefresh = MDT_NPT.Theme.Refresh
      MDT_NPT.Theme.Refresh = function() refreshCalls = refreshCalls + 1 end
      orb:Update()
      MDT_NPT.Theme.Refresh = realRefresh
      assert.equals(0, refreshCalls)
    end)
  end)
```

**⑤ 替换 `renders exact 8:2 heights, text and Elemental Blast icon`（:257-274）：**

```lua
  it("renders exact 8:2 splits, text and Elemental Blast icon", function()
    scenario(function(env, orb)
      seed(8, 2)
      orb:Update()
      local frame = orb:GetFrame()
      assert.is_true(frame:IsShown())
      assert.equals(8, frame.orb.ebDriver.value)
      assert.equals(2, frame.orb.eqDriver.value)
      assert.equals(EASE, frame.orb.ebDriver.interpolation)
      assert.equals(EASE, frame.orb.eqDriver.interpolation)
      assert.is_true(frame.orb.ebClip:IsShown())
      assert.is_true(frame.orb.eqClip:IsShown())
      assert.is_true(frame.orb.spark:IsShown())
      assert.equals("8:2", frame.ratioText:GetText())
      assert.is_true(frame.ratioText:IsShown())
      assert.equals("spell:" .. ELEMENTAL_BLAST_ID, frame.primaryIcon.texture)
      assert.is_true(frame.primaryIcon:IsShown())
      assert.is_false(frame.secondaryIcon:IsShown())
      assert.equals(env.activePull, env.verifiedPull)
      assert.equals(MDT.dungeonEnemies[1], env.verifiedEnemies)
      assert.equals(MDT_NPT.state, env.trackedState)
    end)
  end)
```

**⑥ 替换 `keeps both nonzero sides visible at a minimum ten-percent fill`（:277-286）：**

```lua
  it("keeps both nonzero sides visible at a minimum ten-percent fill", function()
    scenario(function(_, orb)
      seed(1, 45)
      orb:Update()
      local frame = orb:GetFrame()
      assert.equals(1, frame.orb.ebDriver.value)
      assert.equals(9, frame.orb.eqDriver.value)
      assert.equals("0:10", frame.ratioText:GetText())
    end)
  end)
```

**⑦ 替换 `rounds fill levels to the nearest ten-percent boundary`（:288-301）：**

```lua
  it("rounds fill levels to the nearest ten-percent boundary", function()
    for _, case in ipairs({
      { elementalBlast = 14, earthquake = 86, eb = 1, eq = 9 },
      { elementalBlast = 15, earthquake = 85, eb = 2, eq = 8 },
    }) do
      scenario(function(_, orb)
        seed(case.elementalBlast, case.earthquake)
        orb:Update()
        local o = orb:GetFrame().orb
        assert.equals(case.eb, o.ebDriver.value)
        assert.equals(case.eq, o.eqDriver.value)
      end)
    end
  end)
```

**⑧ 替换 `allows a truly zero side to use the full zero-to-one-hundred range`（:303-316）：**

```lua
  it("allows a truly zero side to use the full zero-to-one-hundred range", function()
    for _, case in ipairs({
      { elementalBlast = 0, earthquake = 5, eb = 0, eq = 10 },
      { elementalBlast = 5, earthquake = 0, eb = 10, eq = 0 },
    }) do
      scenario(function(_, orb)
        seed(case.elementalBlast, case.earthquake)
        orb:Update()
        local o = orb:GetFrame().orb
        assert.equals(case.eb, o.ebDriver.value)
        assert.equals(case.eq, o.eqDriver.value)
        -- 零侧整个裁剪框隐藏，气泡不会作为孤儿继续转
        assert.equals(case.eb > 0, o.ebClip:IsShown())
        assert.equals(case.eq > 0, o.eqClip:IsShown())
      end)
    end
  end)
```

**⑨ 替换 `renders Earthquake as the dominant icon and lower fill`（:318-330）：**

```lua
  it("renders Earthquake as the dominant icon and the larger fill", function()
    scenario(function(_, orb)
      seed(2, 8)
      orb:Update()
      local frame = orb:GetFrame()
      assert.equals(2, frame.orb.ebDriver.value)
      assert.equals(8, frame.orb.eqDriver.value)
      assert.equals("2:8", frame.ratioText:GetText())
      assert.equals("spell:" .. EARTHQUAKE_ID, frame.primaryIcon.texture)
      assert.is_true(frame.primaryIcon:IsShown())
      assert.is_false(frame.secondaryIcon:IsShown())
    end)
  end)
```

**⑩ 替换 `keeps the dark empty orb visible for imported zero-zero`（:352-372）：**

```lua
  it("keeps the dark empty orb visible for imported zero-zero", function()
    scenario(function(_, orb)
      seed(8, 2)
      orb:Update()
      local frame = orb:GetFrame()
      assert.is_true(frame.ratioText:IsShown())
      assert.is_true(frame.primaryIcon:IsShown())

      MDT_NPT.SpellRatioData:Set("uid1", 1, 0, 0, "fp")
      orb:Update()
      local o = frame.orb
      assert.is_true(frame:IsShown())
      assert.equals(0, o.ebDriver.value)
      assert.equals(0, o.eqDriver.value)
      assert.is_false(o.ebClip:IsShown())
      assert.is_false(o.eqClip:IsShown())
      assert.is_false(o.spark:IsShown())
      -- 空球态只剩恒显的四层
      assert.equals(ORB_MEDIA .. "orb_back.tga", o.back.texture)
      assert.equals(0.4, o.back.alpha)
      assert.is_true(o.back:IsShown())
      assert.is_true(o.gloss:IsShown())
      assert.is_true(o.orbshadow:IsShown())
      assert.is_true(o.grid:IsShown())
      assert.is_false(frame.ratioText:IsShown())
      assert.is_false(frame.primaryIcon:IsShown())
      assert.is_false(frame.secondaryIcon:IsShown())
    end)
  end)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioOrb_spec.lua`
Expected: FAIL —`attempt to index field 'orb' (a nil value)`（10 个改写块全红）；未改写的 visibility / Alt 交互 / 缩放 / 位置 / grip 块仍 PASS

> 只有本文件 `loadSource("Modules/SpellRatioOrb.lua")`。`Core_alert_hook_spec.lua`、`ImportRatio_spec.lua`、`Settings_spell_ratio_spec.lua` 虽然引用 `SpellRatioOrb` 符号，但都是**打桩**而非加载真模块，因此不需要为它们补 `OrbLiquid.lua` 的加载。

- [ ] **Step 3: 替换 SpellRatioOrb.lua 的常量块**

把 `Modules/SpellRatioOrb.lua` 的 :1-31（从 `local MDT_NPT = MDT_NPT` 到 `VALID_ANCHORS` 表结束的 `}`）替换为：

```lua
local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT
local Theme = MDT_NPT.Theme
local SpellRatioData = MDT_NPT.SpellRatioData
local OrbLiquid = MDT_NPT.OrbLiquid

local SpellRatioOrb = {}

local ORB_SIZE = 96
-- 框体取装饰环的外接矩形，所以这两个值必须由 OrbLiquid 导出、不能在此重新推导：
-- 否则改了 OrbLiquid 的 GRID_N，框体/缩放把手/屏幕夹取会静默与美术脱节，且无测试能发现。
local GRID_SIZE = OrbLiquid.GridSize(ORB_SIZE)          -- 126
local GRID_OVERHANG = OrbLiquid.GridOverhang(ORB_SIZE)  -- 15
local ICON_SIZE = 20
local FRAME_BASE_W = GRID_SIZE                         -- 126
local FRAME_BASE_H = GRID_SIZE + 18                    -- 144
local SCALE_MIN = 0.5
local SCALE_MAX = 2.0
local ELEMENTAL_BLAST_ID = 117014
local EARTHQUAKE_ID = 61882
local VALID_ANCHORS = {
  TOPLEFT = true,
  TOP = true,
  TOPRIGHT = true,
  LEFT = true,
  CENTER = true,
  RIGHT = true,
  BOTTOMLEFT = true,
  BOTTOM = true,
  BOTTOMRIGHT = true,
}
```

（删除的常量：`INNER_SIZE`、`MASK_TEXTURE`、`ELEMENTAL_COLOR`、`EARTHQUAKE_COLOR`、`INNER_COLOR`——后两个已提为 Theme token。）

- [ ] **Step 4: 删除 setFillHeight**

删除 `Modules/SpellRatioOrb.lua` 里的整个 `setFillHeight` 函数（原 :80-87）：

```lua
local function setFillHeight(fill, height)
  fill:SetHeight(height)
  if height > 0 then
    fill:Show()
  else
    fill:Hide()
  end
end
```

空液位现在由 `OrbLiquid.SetSplit` 内的裁剪框显隐表达。

- [ ] **Step 5: 替换 ensureFrame 的渲染段**

把 `ensureFrame` 里从 `frame.ring = frame:CreateTexture(nil, "BACKGROUND")` 到 `frame.secondaryIcon:Hide()` 的整段（原 :155-208）替换为：

```lua
  -- 球体锚在框内 (GRID_OVERHANG, -GRID_OVERHANG)，让装饰环的外接矩形正好等于框体，
  -- 于是右下角缩放把手落在环的外角、SetClampedToScreen 的夹取范围与可见美术一致。
  frame.orb = OrbLiquid:New(frame, ORB_SIZE)
  frame.orb:SetPoint("TOPLEFT", frame, "TOPLEFT", GRID_OVERHANG, -GRID_OVERHANG)
  frame.orb:SetColors(
    Theme.colors.spellRatioElemental,
    Theme.colors.spellRatioEarthquake)
  frame.orb:SetSplit(0, 0)

  frame.ratioText = frame:CreateFontString(nil, "OVERLAY", Theme.fonts.large)
  frame.ratioText:SetPoint("TOP", frame.orb.grid, "BOTTOM", 0, -2)
  local textColor = Theme.colors.textPrimary
  frame.ratioText:SetTextColor(textColor[1], textColor[2], textColor[3], textColor[4])
  frame.ratioText:Hide()

  frame.primaryIcon = frame:CreateTexture(nil, "OVERLAY")
  frame.primaryIcon:SetSize(ICON_SIZE, ICON_SIZE)
  frame.primaryIcon:SetPoint("CENTER", frame.orb, "TOPRIGHT", 3, -3)
  frame.primaryIcon:Hide()

  frame.secondaryIcon = frame:CreateTexture(nil, "OVERLAY")
  frame.secondaryIcon:SetSize(ICON_SIZE, ICON_SIZE)
  frame.secondaryIcon:SetPoint("RIGHT", frame.primaryIcon, "LEFT", -2, 0)
  frame.secondaryIcon:Hide()
```

`ensureFrame` 的其余部分（`frame` 创建与 `SetSize`/`SetScale`/`SetFrameStrata`/`SetClampedToScreen`/`SetMovable`/`RegisterForDrag`/`EnableMouse`、resize grip、拖拽脚本、`applyClickThrough`、位置恢复、`frame:Hide()`）保持不变。

- [ ] **Step 6: 替换 Update 的渲染段**

把 `Update()` 里从 `local f = ensureFrame()` 到函数末尾 `f:Show()`（原 :310-351）替换为：

```lua
  local f = ensureFrame()

  local total = row.elementalBlast + row.earthquake
  if total == 0 then
    f.orb:SetSplit(0, 0)
    f.ratioText:Hide()
    f.primaryIcon:Hide()
    f.secondaryIcon:Hide()
    f:Show()
    return
  end

  local fill = SpellRatioData:FillTenths(row)
  f.orb:SetSplit(fill.elementalBlast, fill.earthquake)

  local tenths = SpellRatioData:RatioTenths(row)
  f.ratioText:SetText(tenths.elementalBlast .. ":" .. tenths.earthquake)
  f.ratioText:Show()

  if row.elementalBlast == row.earthquake then
    f.primaryIcon:SetTexture(C_Spell.GetSpellTexture(ELEMENTAL_BLAST_ID))
    f.secondaryIcon:SetTexture(C_Spell.GetSpellTexture(EARTHQUAKE_ID))
    f.primaryIcon:Show()
    f.secondaryIcon:Show()
  else
    local spellID = row.elementalBlast > row.earthquake
      and ELEMENTAL_BLAST_ID or EARTHQUAKE_ID
    f.primaryIcon:SetTexture(C_Spell.GetSpellTexture(spellID))
    f.primaryIcon:Show()
    f.secondaryIcon:Hide()
  end

  f:Show()
end
```

（删除的三行：`Theme.Refresh()`、`local accent = Theme.colors.accent`、`f.ring:SetColorTexture(...)`——球体不再消费 EUI 派生色。`Update()` 前半部分的全部门控逻辑一字不动。）

- [ ] **Step 7: 跑测试确认通过**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/SpellRatioOrb_spec.lua`
Expected: PASS — `36 tests, 36 passed, 0 failed`（条数与改造前一致：10 块改写、26 块存活）

若条数不是 36，说明改写时误删或重复了 `it()` 块。改造前的基线可用 `grep -c "^  it(" spec/SpellRatioOrb_spec.lua` 复核，逐块核对 Step 1 的 ①–⑩。

- [ ] **Step 8: 跑全套 + 交付说明（不提交）**

Run: `node .tmp-npt-task/luaenv/minibusted.js spec/*_spec.lua`
Expected: PASS，`0 failed`

报告全套条数。**不执行 `git commit`。**

---

## Task 9: 部署与游戏内验收

> 🛑 **部署前必须先处理凭据泄漏（本次干跑发现，阻塞项）**
> `.tmp-wcl/` 目录（含 `token.txt`，一个 1081 字节的 JWT — WCL OAuth 凭据）**既不在 `.gitignore` 里，也不在部署脚本的 `$ExcludeDirs`（`tools/Deploy-Robocopy.ps1:78`）里**。直接部署会把一个有效凭据复制进 `AddOns\MythicDungeonTools_NextPullTracker\.tmp-wcl\token.txt`；而 `git add -A` 会把它提交进仓库。
> 两处都要补：`.gitignore` 加 `.tmp-wcl/`，`$ExcludeDirs` 加 `'.tmp-wcl'`。修完再跑干跑确认变更清单里没有 `.tmp-wcl`，才能真部署。
>
> 另注：干跑显示 `Modules\ImportPlan.lua` 为「**较旧的**」（源比目标旧），说明游戏目录里那份比仓库新。robocopy 默认仍会用较旧的源覆盖它。部署前确认这是时间戳假象而非有人在游戏目录里直接改过文件。

**Files:** 无代码改动。

> ⚠️ `tools/Deploy-Robocopy.ps1` 的 `$DefaultTargetPath` 指向 `C:\Program Files (x86)\World of Warcraft\...`，**该路径在本机不存在**。本机实际安装目录是 `D:\software\World of Warcraft\_retail_\Interface\AddOns\`。必须显式传 `-TargetPath`。（修正脚本默认值属于本次范围外的独立改动，交由用户决定。）

- [ ] **Step 1: 干跑确认变更集**

Run:

```bash
powershell -ExecutionPolicy Bypass -File ./tools/Deploy-Robocopy.ps1 -DryRun -TargetPath 'D:\software\World of Warcraft\_retail_\Interface\AddOns\MythicDungeonTools_NextPullTracker'
```

Expected: 列表里出现 `Media\orb\` 下 9 个 `.tga`（NEW）、`Modules\OrbLiquid.lua`（NEW）、`Modules\SpellRatioOrb.lua` / `Theme.lua` / `SpellRatioData.lua` / `load_modules.xml`（CHANGE）。**确认没有任何意外的 `*EXTRA` 删除项**——脚本用 `robocopy /MIR` 镜像模式，多余的删除意味着仓库里少了文件。

- [ ] **Step 2: 正式部署**

Run:

```bash
powershell -ExecutionPolicy Bypass -File ./tools/Deploy-Robocopy.ps1 -TargetPath 'D:\software\World of Warcraft\_retail_\Interface\AddOns\MythicDungeonTools_NextPullTracker'
```

Expected: 脚本先备份到 `deploy\backup\<时间戳>\`，然后 robocopy 摘要无失败项，末尾提示进游戏 `/reload`。

- [ ] **Step 3: 全量哈希比对部署结果**

Run:

```bash
DST="D:/software/World of Warcraft/_retail_/Interface/AddOns/MythicDungeonTools_NextPullTracker"
for f in Media/orb/*.tga Modules/OrbLiquid.lua Modules/SpellRatioOrb.lua Modules/Theme.lua Modules/SpellRatioData.lua Modules/load_modules.xml; do
  a=$(md5sum "$f" | cut -d' ' -f1)
  b=$(md5sum "$DST/$f" | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then echo "OK   $f"; else echo "DIFF $f"; fi
done
```

Expected: 14 行全部 `OK`（9 个 tga + 5 个源文件），无 `DIFF`、无 `No such file`。本项目有过「逐文件同步导致游戏目录落后且静默失效」的教训，部署后必须全量比对。

- [ ] **Step 4: 游戏内验收（逐项，必须真机）**

裁剪、遮罩、旋转动画、缓动**全部无法在 mock 里验证**。进游戏 `/reload`，导入一套已知 WCL 配比并用 `/npt start last` 开始追踪，然后逐波用 `/npt skip` / 手动跳波核对：

> ⚠️ **调参前先知道：这些常量被 spec 硬钉住了。** 若为观感调整 `BUBBLE_ALPHA`（`spec/OrbLiquid_spec.lua` 4 处）、`BACK_ALPHA`（1 处）、`GRID_ALPHA`（1 处）或 `ORB_SIZE` / `GRID_SIZE`（`spec/SpellRatioOrb_spec.lua` 与 `OrbLiquid_spec.lua` 多处），**必须同步改对应断言**，否则会看到一片红——那是断言过期，不是回归。`BUBBLE_ALPHA` 同时喂静态 alpha 与脉冲上下界，调它会整体缩放脉冲包络并保持 `BUBBLE_DIM` 比例，不会让两者失步。

1. 9 个 `.tga` 全部正常显示，无红块、无空白贴图、无 `Interface\AddOns\...\Media\orb\... not found` 报错。
2. 液面随波次切换**平滑升降**（缓动生效），而非瞬跳。**切换过程中盯住分界线**：不得露出 `orb_back` 的细缝，也不得出现两液重叠的暗带。从 `0:0` 注入到有数据的波次时，两侧同时升起在中间汇合是设计接受的观感，不是 bug。
3. `0:0` 波次两侧全空，只露 `orb_back` 暗底 + gloss/shadow/grid；**球内没有孤儿气泡在转、球底没有残留高光线**。单侧为零（`0:10`）时空的那一侧同样不得有气泡。
4. 气泡被液面**裁断**，不在方块内打转；液位变化时气泡**不上下「游泳」**（验证 scroll 框锚到 orb）。
   **用不可能看漏的探针验裁断**：168/160 的溢出量每边只有 2.4px，方角几乎看不见。临时把 `OrbLiquid.lua` 的 `BUBBLE1_N` 改成 `320`、`BUBBLE_ALPHA` 改成 `1.0`，`/reload`：正常应在液面处看到一条硬边裁切；若看到覆盖整球的亮方块就是裁剪没覆盖到 `scroll` 的 region。验完改回 `168` / `0.3`。
   **已备好的退路**（万一裁剪真没覆盖到气泡）：把气泡改挂到 `clip` 上——`clip:CreateTexture(...)` + `SetPoint("CENTER", orb, "CENTER", 0, 0)`。该路径由暗黑 `player.lua:411-412` 的 `filling2` 先例证明一定被裁（它是 `clipFrame` 自己的 region，满球尺寸而 `clipFrame` 塌缩到液位高度，确实被裁住），且锚到 `orb` 而非 `clip`，中心依然稳定。代价是 `createBubble` 的 parent 实参与一处锚点，`eqScroll`/`ebScroll` 随之变死代码可删。
5. `spark` 高光线**仅在两侧都非零时出现**，且正好压在紫/金分界线上，两端被圆形遮罩切掉、不溢出球体；分界线在球顶/球底附近时端点仍被正确修剪。切到 `0:10` 与 `10:0` 两个极端波次确认高光线**消失**——尤其 `10:0`（整球紫），若它出现在球底边缘就是 bug（`eqClip` 此时塌缩到球底）。
6. `orb_grid1` 装饰环为**中性压暗的暗钢色**（不是青绿主题色，也不是初版那种亮铬色），不遮挡右上技能图标，不与文字重叠。亮度旋钮是 `OrbLiquid.lua` 的 `GRID_TINT`（当前 0.38，真机定值；改完同步改两个 spec 里的 `{0.38,0.38,0.38}`）。
   ⚠️ **这里有一处 Task 8 引入的真实绘制次序变化，必须专门看**：`primaryIcon` / `secondaryIcon` 是**父框 `frame` 的 region**，而球是 `frame` 的**子框**——WoW 里子框的 region 一律画在父框所有 region 之上，与 `OVERLAY` 层级无关。所以图标现在渲染在**整个球子树之下**（含 `gloss`/`orbshadow` 97.2² 与 `grid` 126²），而改造前它们是 `frame` 的同级 `OVERLAY` region、压在 `frame.ring` 的 `BACKGROUND` 之上。
   几何上大概没事：图标中心落在球局部坐标 `(99, -3)`，在 96² 球体之外，而圆形 gloss/shadow 在其外接方框角落处是透明的。但这是**美术 alpha 问题，不是几何问题**，只能真机看。
   **验**：右上技能图标不得被 gloss/shadow/grid 压暗或发灰。若被压暗，一行修好——把两个图标改建在 `frame.orb.overlay` 上（或一个 `frameLevel = orb + 3` 的同级框），而不是 `frame`。
   `ratioText` 安全：它落在 y∈[128,144]，完全在 grid 的 y∈[0,126] 之下。
7. `gloss` / `orbshadow` 叠出玻璃质感，装饰环压在二者之上保持锐利。
8. `orb_back` alpha 0.4 是否够看得见空球；不够则调 `OrbLiquid.lua` 的 `BACK_ALPHA`。
9. Alt 拖拽移动、Alt+右下角把手缩放（0.5–2.0）、松手持久化、`/reload` 后位置与缩放恢复，全部仍正常。
10. 非 Alt 态点击穿透，能点到球下方的游戏 UI。
11. 切到非元素专精球消失；切回出现。停止追踪、fingerprint 漂移后隐藏。
12. 96px 下气泡细节是否可读；若糊成噪点，上调 `ORB_SIZE`（`GRID_SIZE` / `FRAME_BASE_W` / `FRAME_BASE_H` 会自动跟着算）或改选 `Theme.textures.orb.filling` 指向其它 `orb_filling<N>`。
13. 聊天框与 `/reload` 过程无 Lua 报错（`Interface\AddOns\...\OrbLiquid.lua` 相关）。
14. **`/reload` 后第一帧不得有白色 ADD 闪白**：气泡刻意不做 `SetVertexColor` 占位，前提是 `New()` 与 `SetColors()` 在同一次 Lua 执行内完成（Lua 跑完客户端才渲染，故可证明零帧未染色）。若看到闪白，说明 `SetColors` 被推迟到了事件回调里，需要把它移回 `ensureFrame()` 内紧跟 `New()`。
15. 气泡在 `ADD` 混合 + 全色染色下是否过亮/过刺眼。峰值叠加约为 `0.76（美术亮度）× 0.3（alpha 上界）≈ 0.23 × 技能色`，与暗黑 `bubblesalpha = 0.3` + 全资源色的线上表现同量级。若仍嫌刺眼，下调 `BUBBLE_ALPHA`（不要改成给气泡加灰色 `SetVertexColor` 占位——那会在任何「建了球但没染色」的路径上留下静默 bug）。

- [ ] **Step 5: 交付说明（不提交）**

报告：13 项验收逐条结果（通过/失败 + 现象）、任何调过的常量（`BACK_ALPHA` / `GRID_ALPHA` / `BUBBLE_ALPHA` / `ORB_SIZE`）及其新值、以及部署哈希比对输出。

**不执行 `git commit`** —— 全部 9 个任务完成后由用户统一提交。
