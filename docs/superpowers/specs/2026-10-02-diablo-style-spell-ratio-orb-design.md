# 暗黑风格元素冲击/地震术配比球设计

## 目标

把 `SpellRatioOrb` 的视觉表现从「圆形遮罩裁剪两个纯色矩形色块」换成 `!!!_Diablo` 那套真正的液体球：贴图液面、装饰环、液面高光线，以及反向旋转的气泡层动画。

**数据语义完全不变**：仍然只展示导入的 WCL 历史配比，不统计实战；仍然按十等分档位绘制液位；仍然是上半电光紫代表元素冲击、下半岩土金代表地震术。本次只改渲染层与部件结构。

本设计**修订并取代** `2026-10-01-wcl-wave-spell-ratio-orb-design.md` 的「游戏内圆球」与「模块边界」两节中关于渲染实现的部分。统计口径、导出数据流、导入格式、存储模型、更新时机、设置开关全部沿用原设计，本文不重复。

## 参考实现的三条事实校正

逆向 `!!!_Diablo`（`units\player.lua`、`units\db.lua`）后确认：

1. `orb_filling1..33` **不是 33 个液位档位**，是 33 种液面材质风格（用户下拉菜单选项，见 `units\db.lua:1078-1113`）。本设计采用的 `orb_filling15` 在该列表里的 key 正是 `diablo3`。
2. `power_r.tga` / `power_y.tga` / `power_b/g/c/_.tga` 是 **256×32 的 statusbar 长条贴图，全插件零引用**，属于死资产，与球体无关。暗黑的球从不靠贴图区分颜色，而是「一张中性液体贴图 + `SetVertexColor` 染色」，所有层从同一个 RGB 派生（`units\player.lua:213-239`）。因此地震/元素冲击的区分**必须**靠同一张 `orb_filling15` 染两次色实现。
3. `orb_grid1.tga` 确实是装饰环（暗黑里 210² 套在 160² 球外，每边溢出 25px），但默认 `orbgridalpha = 0` 是关掉的。`orb_grid2/3` 零引用。

## 资产

从 `!!!_Diablo/media/` 拷贝 **9 个文件**到 `Media/orb/`，自包含，不写运行时探测与降级分支：

| 文件 | 用途 | 尺寸 |
| --- | --- | --- |
| `orb_back.tga` | 球底暗背景 | 256² / 256K |
| `orb_filling15.tga` | 液体主体（`diablo3` 风格），染两次色当两种液体 | 256² / 256K |
| `orb_grid1.tga` | 装饰边框环 | 256² / 256K |
| `orb_rotation_bubbles1.tga` | 气泡层 1，两种液体共用 | 256² / 256K |
| `orb_rotation_bubbles2.tga` | 气泡层 2，两种液体共用 | 256² / 256K |
| `orb_spark.tga` | 液面高光线 | 256×32 / 32K |
| `orb_spark_mask.tga` | 高光线的圆形遮罩 | 256² / 106K |
| `orb_gloss.tga` | 玻璃高光 | 256² / 256K |
| `orb_shadow.tga` | 内缘暗影 | 256² / 256K |

合计约 **1.9 MB**（`Media/` 现为 876K）。`.pkgmeta` 的 `ignore` 列表不含 `Media`，新文件自动进包，无需改动打包配置。

不需要 `galaxy1/3`、`orb_filling31/32`（moire/ghostly）——那 4 张属于本次不做的长周期背景层，见「明确不做」。

**已接受的风险**：`!!!_Diablo` 目录内无任何 LICENSE / README，而本仓库 TOC 带 `X-Curse-Project-ID: 1519738` 与 `X-Wago-ID: vNAgqQKo`，`.pkgmeta` 配了发布流水线。把无授权的第三方美术打进自包含包体是本次的显式取舍，由维护者在对外发布前自行判断。256² 无压缩 TGA 每张 256K，将来要瘦身可转 BLP/DXT（约 4× 压缩），但需要额外工具链，初版不做。

## 模块边界

`SpellRatioOrb.lua` 现 363 行，已混合 DB 持久化、拖拽缩放、点击穿透、专精门控、数据查找、比例运算与渲染。直接加渲染栈会到 ~650 行且渲染无法独立测试，因此拆分：

- **`Modules/OrbLiquid.lua`（新增）** — 纯视觉部件。不知道 MDT、不知道 DB、不知道技能 ID、不读 `MDT_NPT.state`。
  ```lua
  OrbLiquid:New(parent, size) -> orb        -- size = 球体边长（正方形）
  orb:SetSplit(topTenths, bottomTenths)     -- 0..10 整数；top=元素冲击，bottom=地震术
  orb:SetColors(topColor, bottomColor)      -- {r,g,b,a}
  ```
  与项目既有约定一致，file scope 捕获 `local Theme = MDT_NPT.Theme`，贴图路径直接读 `Theme.textures.orb`，颜色由调用方经 `SetColors` 注入。各层 alpha（back / grid / gloss / shadow / bubble）是 `OrbLiquid.lua` 内的 file-local 常量，不进 DB、不进设置面板。

  职责边界：给定一个父框、一个边长、两种颜色，构建出「上下对向填充的双液体暗黑球」并暴露一个设值方法。仅此而已，不做 N 区域泛化、不做材质下拉、不做 alpha 可配置。
- **`Modules/SpellRatioOrb.lua`（改造）** — 保留框体外壳、Alt 拖拽、右下角把手缩放、位置与缩放持久化、点击穿透、专精 262 门控、fingerprint `Verify`、图标与比例文字；渲染部分改为持有并驱动一个 `OrbLiquid` 实例。
- **`Modules/SpellRatioData.lua`（增一个纯函数）** — 新增 `SpellRatioData:FillTenths(row)`，与既有的 `RatioTenths(row)` 并列。
- **`Modules/Theme.lua`** — 新增 `Theme.textures.orb` 收纳 9 条贴图路径；`FALLBACK` 新增 `spellRatioElemental` / `spellRatioEarthquake` 两个语义色。
- `Modules/load_modules.xml` — `OrbLiquid.lua` 必须插在 `SpellRatioOrb.lua` **之前**。

这个切法与项目里 `CooldownPlan.lua` / `CooldownPlanRender.lua` 的既有分离方式一致。

### 两套十等分规则必须保持分离

`FillTenths` 与 `RatioTenths` 是**不同**算法，不可合并：

- `FillTenths`（液位）：四舍五入到最近十等分；**双方原始次数都非零时各自 clamp 到 1..9**；单侧为零时允许 0/10。因此 `1/46 → 液位 1:9`、`14%→1`、`15%→2`。
- `RatioTenths`（文字）：不 clamp，`1/46 → 文字 0:10`。

现状是液位这套逻辑内联在 `SpellRatioOrb.lua:326-332`，只被高度断言间接覆盖。抽成 `SpellRatioData` 上的纯函数后，可以脱离任何 UI mock 直接单测，且不受本次渲染重构影响。

## 渲染栈

自底向上，括号内为 96px 球的具体数值，均由暗黑 160px 原值等比换算：

| # | 层 | 贴图 | Layer / Sublevel | Blend | 尺寸 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `back` | `orb_back` | BACKGROUND / -6 | BLEND | AllPoints(orb) | alpha **0.4**（暗黑默认 0.1 过淡，见「配色」） |
| 2 | `eqDriver` | `WHITE8X8` | — | — | AllPoints(orb) | **`SetAlpha(0)` 隐形**，`VERTICAL`，minmax `0..10` |
| 3 | `eqClip` | — | FrameLevel orb+1 | — | BL/BR→eqDriver，**TOP→eqDriver 贴图 TOP** | `SetClipsChildren(true)` |
| 3a | └ `eqScroll` | — | Frame | — | 96²，BOTTOM→orb BOTTOM | 锚到**球**而非裁剪框，见「结构陷阱」 |
| 3b | └ 液体 | `orb_filling15` | BACKGROUND / -7 | BLEND | **AllPoints(orb)** | TexCoord `(0.05,0.95,0.05,0.95)`，染岩土金 |
| 3c | └ 气泡 ×2 | `bubbles1` / `bubbles2` | ARTWORK / -1,-2 | **ADD** | 100.8² / 97.2² | 挂在 `eqScroll` 上，随液位被裁剪 |
| 4 | `ebDriver` | `WHITE8X8` | — | — | AllPoints(orb) | **`SetAlpha(0)` 隐形**，`VERTICAL` + **`SetReverseFill(true)`**，minmax `0..10` |
| 5 | `ebClip` | — | FrameLevel orb+1 | — | TL/TR→orb，**BOTTOM→ebDriver 贴图 BOTTOM** | `SetClipsChildren(true)` |
| 5a-c | └ 三件套 | 同 3a-3c | | | | 染电光紫；气泡镜像 `SetTexCoord(1,0,0,1)` |
| 6 | `overlay` | — | FrameLevel orb+2 | — | AllPoints(orb) | 6a-6e 全在其上，**不受任何裁剪** |
| 6a | `sparkMask` | `orb_spark_mask` | MaskTexture | — | 110.4²（每边 +7.2） | `CLAMPTOBLACKADDITIVE`；**锚到 overlay，不锚到 spark** |
| 6b | `spark` | `orb_spark` | BACKGROUND / -3 | **ADD** | 115.2 × 4.8 | `CENTER → eqClip TOP`，挂 mask = 分界线高光 |
| 6c | `gloss` | `orb_gloss` | BACKGROUND / 3 | BLEND | 97.2² | TexCoord 同裁剪，alpha 0.8 |
| 6d | `orbshadow` | `orb_shadow` | BACKGROUND / 3 | BLEND | 97.2² | `SetVertexColor(0,0,0)`，alpha 0.25；**创建顺序在 gloss 之后**，同 sublevel 靠创建顺序压在 gloss 上 |
| 6e | `grid` | `orb_grid1` | BACKGROUND / **4** | BLEND | 126²（每边 +15） | alpha **0.9**（暗黑默认 0）。**保留原图色，不染色** |

两处对暗黑的有意偏离：

- 6e 的 sublevel 从暗黑的 3 提到 **4**，让装饰环压在 gloss/shadow 之上保持锐利。
- 6a 的遮罩锚到 `overlay`（固定满球）而非 `spark`。这是必须的：分界线高度会变，固定圆形遮罩才能在任意高度正确切掉高光线的两端。暗黑就是这么做的（遮罩 184² < 高光线 192 宽），我们等比后 110.4 < 115.2，同理成立。

### 零液位可见性规则

不能只靠「裁剪框高度归零自然不渲染」。液体和气泡都在裁剪框子树里，若只 `Hide()` 液体贴图，**气泡会作为孤儿继续旋转**，空球里凭空转着两团泡沫。因此：

- 某一侧 `tenths == 0` 时，`Hide()` 该侧**整个裁剪框**（`eqClip` / `ebClip`），液体与气泡一并消失；`tenths > 0` 时 `Show()`。
- `spark` 高光线仅在 `total > 0` 时 `Show()`。它锚在 `eqClip TOP`，而隐藏一个框不会使其锚点失效（几何仍然解算），所以 `total == 0` 时它会停在球底——那是没有液体的位置，必须显式隐藏。
- `back` / `gloss` / `orbshadow` / `grid` 恒显。`total == 0` 时整球只剩这四层，即原设计要求的「暗色空球」。

这条规则取代现有的 `setFillHeight()`（`SpellRatioOrb.lua:80-87`，靠 `SetHeight(0)` + `Hide()` 表达空液位），该辅助函数随之删除。

## 液位机制：为什么必须两个 driver bar

技法本体来自暗黑：**隐形 VERTICAL StatusBar 只当「高度发生器」，一个 `SetClipsChildren(true)` 的框把移动边锚到该 bar 的贴图上，框内放永远满尺寸、从不缩放的液体贴图**。液位变化时液体花纹不被拉伸，这是整套技法的全部价值——`SetHeight` 直接缩放贴图会把花纹压糊。

**不能用单个 driver bar。** 单 bar 方案（地震侧向上长，元素冲击侧取其补集从顶向下）在 `total == 0` 时语义错误：value=0 会让元素冲击侧**填满整球**，而既有行为要求 0:0 波次两侧全空、只露暗底（`spec/SpellRatioOrb_spec.lua:352` 正在断言这一点）。故采用两个独立 driver，`total == 0` 时两个都 `SetValue(0)`。

正常态 `ebTenths + eqTenths == 10` 恒成立。两条边在同一帧写入、使用同一 `ExponentialEaseOut` 曲线，中间值严格互补：

```
A(t) = a₀ + (a₁ - a₀)·e(t)
B(t) = b₀ + (b₁ - b₀)·e(t)
a₁ + b₁ = 10 且 a₀ + b₀ = 10  ⟹  A(t) + B(t) = 10
```

因此升降过程中分界线两侧不会出缝也不会重叠。从 `0:0` 切到有数据的波次时，`A(t)+B(t)` 由 0 渐增至 10，两液同时从空升起在中间汇合——这个「注入」观感是免费的副作用，可接受。

`StatusBar:SetValue(value, Enum.StatusBarInterpolation.ExponentialEaseOut)` 是**原生 API**（oUF 只是直接调用它，未重写 `SetValue`），所以缓动无需引入 oUF 依赖，也**不写任何存在性 guard**——WoW 12.1 必定提供该枚举。

## 动画

4 层气泡，每层一个 Rotation 组 + 一个 Alpha 组，构造时 `Play()` 一次、`SetLooping("REPEAT")`，**全程零 per-frame Lua**（无 `OnUpdate`、无 `C_Timer`）：

| 层 | 贴图 | 旋转 | Alpha 脉冲相位时长 | Blend | 默认 alpha |
| --- | --- | --- | --- | --- | --- |
| 地震 气泡1 | `bubbles1` | +360° / 30s | 16s | ADD | 0.3 |
| 地震 气泡2 | `bubbles2`（镜像） | −360° / 45s | 21s | ADD | 0.3 |
| 元素 气泡1 | `bubbles1`（镜像） | −360° / 30s | 16s | ADD | 0.3 |
| 元素 气泡2 | `bubbles2` | +360° / 45s | 21s | ADD | 0.3 |

相位时长沿用暗黑公式 `duration/3 + 6`，把脉冲速率耦合到自转速率——转得慢的层脉得也慢，这是「液体」错觉的来源之一。

三条必须照做的要点：

1. **镜像层要把两个 Alpha 动画的 `SetOrder` 对调**（暗黑 `createGalaxy_fh` 的做法，`units\player.lua:175-210`），使两层脉冲错开半个周期。两个反相的周期信号叠加读起来是非周期的，这是整套效果里最便宜也最有效的一招。
2. **每个 Alpha 动画必须显式 `SetFromAlpha` / `SetToAlpha`**，在 `alpha ↔ 0.3*alpha` 之间摆。暗黑原版这两行是**注释掉的**、靠调用方后补（`units\player.lua:158-165`），照抄会静默退化成默认的 fade-to-1，观感完全不同。
3. 30 与 45 的 LCM 是 90，两层气泡每 90 秒才回到同一构型，肉眼读不出循环。

「沸腾」观感的其余来源：`ADD` 混合让气泡交叠处加亮（读作光在液体里折射，而不是一层遮另一层）；两层用不同贴图且其中一层镜像，避免读成同一张图叠两次。

## 结构陷阱

两条最容易漏、且**无法在 mock 里验证**的结构约束：

1. **`eqScroll` / `ebScroll` 必须 `SetSize(orb)` + `SetPoint("BOTTOM", orb, "BOTTOM")`，绝不能锚到裁剪框。** 裁剪框高度随液位变化，其 CENTER 会上下移动；气泡若锚在它上面就会随液位「游泳」。锚到球体本身，中心永远稳定在球心。这也是暗黑要额外造一层 `scrollChild` 的真实原因。
2. **旋转层必须故意做大**：气泡1 = 100.8² 对 96² 球（直径 +4.8px，每边 +2.4px）；气泡2 = 97.2²（直径 +1.2px，每边 +0.6px）。裁剪框才永远切进气泡场内部，气泡看起来是从液面下冒出/沉下去，而不是在一个可见的方块里打转。

第 2 条依赖一个待实测确认的前提：`SetClipsChildren(true)` 的裁剪是否传播到**孙**级（气泡是 `scrollChild` 的子 region，而 `scrollChild` 才是 `clipFrame` 的子框）。暗黑线上版本依赖此行为且工作正常，据此认为传播成立，但仍列入游戏内验收必查项。

## 几何

`ORB_SIZE` 由 64 提到 **96**（暗黑 160 的等比缩放，贴图降采样比由 4.3:1 改善到 2.67:1，气泡细节不至于糊成噪点）。其余尺寸全部按比例从暗黑原值换算，不在代码里写死绝对像素：

```
GRID_SIZE    = ORB_SIZE * 210/160 = 126      -- 每边溢出 15
FRAME_BASE_W = GRID_SIZE           = 126     -- 原 92
FRAME_BASE_H = GRID_SIZE + 18      = 144     -- 原 82
orb TOPLEFT  = frame TOPLEFT + (GRID_OVERHANG, -GRID_OVERHANG) = (15, -15)
```

框体取 grid 环的外接矩形，使右下角缩放把手落在环的外角、且 `SetClampedToScreen` 的夹取范围与可见美术一致。

20px 图标仍锚 `orb TOPRIGHT +3,-3`：换算后落在 x∈[104,124]、y∈[2,22]，在 126 宽的框内尚有 2px 余量，**无需额外加宽**。比例文字仍锚 grid 底部 -2。

`INNER_SIZE`（原 60）这个概念消失——液体直接 AllPoints 到 orb，不再有独立的内圆。

`circle_mask.png` **文件保留**：`SpellRatioOrb.lua:17` 与 `spec/SpellRatioOrb_spec.lua:3` 的引用随遮罩方案一并删除，但 `AlertBanner.lua:27` 仍在使用它，且 `spec/AlertBanner_spec.lua:207` 有断言覆盖。本次不得删除该文件。

Alt 拖拽移动、Alt+把手缩放 `0.5–2.0`（等效 63×72 ~ 252×288）、点击穿透逻辑全部不动。`db.beacon.spellRatioOrbPos` / `spellRatioOrbScale` 语义不变，老用户位置保留，仅球体变大。

## 配色

- **`orb_grid1` 装饰环保留原图色，不做 `SetVertexColor` 染色。** 这是明确决定：项目里存在「边框跟随 EUI 主题色」的既有约定（BeaconFrame 地图边框、底带白边），但本处用户明确要求保留参考美术原色。实施与后续审查都**不得**把它「修正」回 `Theme.colors.accent`。
- 由于球体不再消费任何 EUI 派生色，`SpellRatioOrb.lua:311-313` 现有的 `Theme.Refresh()` 与 `f.ring:SetColorTexture(accent...)` 一并删除。比例文字用的 `Theme.colors.textPrimary` 本就只在创建时读取一次，故无回归。
- **`orb_back` alpha 定为 0.4**（暗黑默认 0.1）。理由：0:0 空球态下整球只剩 `back` 可见，0.1 几乎看不见，会退化成「球消失了」。0.4 为初版取值，属可调参数。
- 两个技能色 `#B34CFF` / `#C9902E` 从 `SpellRatioOrb.lua:18-19` 的 file-local 提到 `Theme.FALLBACK`，命名 `spellRatioElemental` / `spellRatioEarthquake`，归入该表已有的「semantic colours — not derived from accent」段落（与 `mobBoss`、`cdUse` 同类）。
- 9 条贴图路径进 `Theme.textures.orb`，与既有 `Theme.textures.circleWhite` / `statusBar` 并列，不再散落硬编码。

## 异常处理

- **不加贴图缺失降级路径**：资产自包含在 `Media/orb/`，缺失属于打包错误，应在部署校验阶段暴露而非运行时静默降级。
- **不加 `Enum.StatusBarInterpolation` 存在性 guard**：12.1 原生提供。
- **不加隐藏时暂停动画**：框体是懒创建的——`Update()` 在通过全部门控前只调 `hide()`（`if frame then frame:Hide() end`），从不 `ensureFrame()`。因此非元素专精、未追踪、无数据的用户根本不会创建动画组。已创建后再被隐藏仍会空转，但受众很小，列为后续观察项而非初版工作。
- 沿用原设计的异常口径：fingerprint 漂移隐藏、存档损坏清洗并只警告一次、`importratiopack` 整包拒绝。

## 验证

### Mock 缺口（本次最大风险）

`spec/helpers/wow_mocks.lua` 是**单一泛型 widget 工厂**，其自身注释已警告：

> 按 kind 拆工厂属于过度设计。代价是产品代码把这些方法调到错误的 region 上时，spec 会绿而客户端会崩——写新 UI 时自己留意。

同文件记录过一次真实事故：曾臆造 `SetOnFinished`，产品代码调用了不存在的方法而 spec 全绿。

当前 mock 里 **StatusBar 相关 API 一个都没有**：`CreateFrame("StatusBar")` 不按 kind 分化（`:328`），缺 `SetClipsChildren`、`SetOrientation`、`SetReverseFill`、`SetStatusBarTexture`、`GetStatusBarTexture`、`SetStatusBarColor`、`SetValue(v, interpolation)`、`SetBlendMode`、`SetAllPoints`。

补齐原则：**只加录制型 stub，不模拟行为**。`GetStatusBarTexture()` 必须返回一个真实的录制 region，否则裁剪框锚点断言无从写起。补 `Enum.StatusBarInterpolation` 常量表。**严禁臆造任何客户端不存在的方法**——补之前逐条对照暗黑线上代码确认该 API 真实存在。

### Lua 测试：旧断言 → 新断言映射

裁剪、遮罩、旋转在 mock 里**根本无法模拟**，因此 spec 只能断言*结构契约*，不能断言视觉结果。`spec/SpellRatioOrb_spec.lua`（640 行）中以下 `it()` 块需原地改写，每条都保留原始意图。

下表的 `SetValue` 一律按 **`(eb元素冲击, eq地震术)`** 顺序书写，即第一个数写给顶部反向填充的 `ebDriver`、第二个数写给底部正向填充的 `eqDriver`：

| 现有断言 | 行 | 原意图 | 改写后 |
| --- | --- | --- | --- |
| `creates the named 64/60 orb and 20px icons without a ticker` | :113 | 几何固定、无高频 ticker | 96/126 + 图标仍 20px + `#env.tickers == 0` |
| `defaults to scale one without changing base geometry` | :130 | scale 1 时框体基准尺寸 | 126 × 144 |
| `attaches real circular masks and places purple above orange` | :179 | 遮罩真实挂接 + 紫上金下 | 两个 clip 框 `clipsChildren == true`；eb 侧 driver 有 `SetReverseFill(true)` 且 `orientation == "VERTICAL"`；两液均 `SetAllPoints(orb)`（**不是** AllPoints 到裁剪框）；紫液属 `ebClip`、金液属 `eqClip` |
| `uses Theme.colors.accent for the outer ring` | :195 | 外圈跟随主题 | **删除**。改为断言 `grid` 未调用 `SetVertexColor`（锁定「保留原图色」这一决定，防止将来被误改回主题色） |
| `renders exact 8:2 heights, text and Elemental Blast icon` | :257 | 8:2 → 精确液位 + 文字 + 图标 | `ebDriver:SetValue(8, ease)` / `eqDriver:SetValue(2, ease)`；文字与图标断言不变 |
| `keeps both nonzero sides visible at a minimum ten-percent fill` | :277 | 双方非零保底 10% | `SetValue(1)` / `SetValue(9)`，文字仍 `0:10` |
| `rounds fill levels to the nearest ten-percent boundary` | :288 | `14%→10%`、`15%→20%` | SetValue 入参 `1/9` 与 `2/8` |
| `allows a truly zero side to use the full zero-to-one-hundred range` | :303 | 单侧为零时另一侧可占满 0–100% | 保留原测试的**双向** loop：`(0,5) → SetValue(0)/(10)`，`(5,0) → SetValue(10)/(0)`；并断言零侧的裁剪框被 `Hide()` |
| `renders Earthquake as the dominant icon and lower fill` | :318 | 地震主导时图标与液位 | `SetValue(2)` / `SetValue(8)`，文字 `2:8` 与图标断言不变 |
| `keeps the dark empty orb visible for imported zero-zero` | :352 | 0:0 显示暗空球 | 两侧 `SetValue(0)`、**两个裁剪框均 `IsShown() == false`**、`spark` 隐藏、文字与图标隐藏、框体仍 `IsShown()`。原断言 `frame.inner.color == {0.03,0.04,0.06,0.92}` 改为断言 `back` 层的贴图为 `orb_back` 且 alpha 为 0.4——`inner` 纯色层已不存在 |

**存活不动**：全部 visibility 门控（:378-471）、Alt 交互（:473-639）、缩放 clamp（:139-162）、位置持久化（:205-252）、resize grip（:164-177）。

`SetValue` 的第二参数必须被断言为 ease 枚举——否则丢掉缓动不会被任何测试发现。

### 新增 spec

- **`spec/OrbLiquid_spec.lua`**：driver bar 为 `VERTICAL` + `alpha 0`、元素侧有 `SetReverseFill(true)`；两个 clip 框 `clipsChildren == true` 且移动边锚到对应 driver 贴图；液体 `SetAllPoints(orb)`；气泡 parent 是 scroll 框、且尺寸**大于** orb（锁定「故意溢出」）；scroll 框锚到 orb 而非 clip 框（锁定「不游泳」）；创建 4 个 rotation 组 + 4 个 alpha 组且全部 `IsPlaying()`；**每个 Alpha 动画都有显式 from 与 to**（专防暗黑那个坑）；镜像层的 Alpha `order` 被对调；`SetSplit` 传入 0 时隐藏对应 clip 框、传入非零时恢复（锁定「零液位可见性规则」，防孤儿气泡）。
- **`spec/SpellRatioData_spec.lua` 增补**：`FillTenths` 与 `RatioTenths` 的分歧用例——`1/46 → FillTenths 1:9 而 RatioTenths 0:10`、`14%→1`、`15%→2`、单侧为零时 `0:10`、`0:0` 时 `0:0`。纯函数，零 UI mock。

### 游戏内验收清单

裁剪、遮罩、旋转动画、缓动**全部只能真机验证**。部署须走全量哈希比对（逐文件同步会导致游戏目录落后且静默失效）。`/reload` 后逐项核对：

1. 9 个 `.tga` 确实落到游戏目录 `Media/orb/`，无红块/空白贴图。
2. 液面随波次切换**平滑升降**（缓动生效），而非瞬跳。
3. `0:0` 波次两侧全空，只露 `orb_back` 暗底 + gloss/shadow/grid（alpha 0.4 是否够看得见），**且球内没有孤儿气泡在转、球底没有残留高光线**。单侧为零（如 `0:10`）时同理：空的那一侧不得有气泡。
4. 气泡被液面**裁断**，不在方块内打转；液位变化时气泡不上下「游泳」。→ 直接验证「结构陷阱」两条与孙级裁剪传播。
5. `spark` 高光线正好压在紫/金分界线上，两端被圆形遮罩切掉，不溢出球体。
6. `orb_grid1` 装饰环为**原图色**，不遮挡右上技能图标，不与文字重叠。
7. `gloss` / `orbshadow` 叠出玻璃质感，环压在二者之上保持锐利。
8. Alt 拖拽移动、Alt+右下角把手缩放（0.5–2.0）、松手持久化、`/reload` 后位置与缩放恢复，全部仍正常。
9. 非 Alt 态点击穿透，能点到球下方的游戏 UI。
10. 切到非元素专精球消失；切回出现。停止追踪、fingerprint 漂移后隐藏。
11. 在 96px 下气泡细节是否可读；若糊成噪点，上调 `ORB_SIZE` 或改选其它 `orb_filling<N>` 风格。

## 明确不做

不加 fallback 渲染路径、不加 API 存在性 guard、不加暗黑那 4 层长周期背景（`galaxy1/3`、`moire`、`ghostly`）、不加 `PlayerModel`、不加低血红光与骷髅（无血量语义）、不加隐藏时暂停动画、不加液面材质下拉菜单（固定 `diablo3`）、不改双球布局、不把比例文字搬进球内。以上均属「后续美化」范畴。
