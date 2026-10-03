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
local CROP_MIN, CROP_MAX = 0.05, 0.95   -- 取源图内侧 90% 铺满同一显示矩形（放大 ≈1.11×），把硬边与 mipmap 毛刺挤到框外

-- 填充方向的具名实参：New 里 createDriver / createClip 四个调用点连排出现，
-- 裸 false/true 读不出哪个对应哪一侧。
local FORWARD, REVERSE = false, true

local BACK_ALPHA   = 0.4    -- 暗黑默认 0.1，但 0:0 空球时只剩这一层，太淡会像球消失了
local GLOSS_ALPHA  = 0.35   -- 暗黑原值 0.8；真机反馈球内太暗两度减淡（仍保留顶部高光）。
                            -- 提亮走 gloss 而不是气泡：气泡是 ADD 泡沫层，调高只增噪不增亮
local SHADOW_ALPHA = 0.10   -- 暗黑原值 0.25；真机反馈球内太暗，内缘黑边两度减淡
local LIQUID_LIFT  = 0.25   -- 顶点色与液体贴图逐通道相乘会压暗球内：先把主题色按最大通道
                            -- 归一（保色相、主通道拉满亮），再按此比例向白色抬升，
                            -- 球内才读得到「明亮轻快」而不是暗色玻璃
local GRID_ALPHA   = 1.0    -- 暗黑默认 0（关掉的），我们要它当边框。必须不透明：
                            -- alpha<1 会让饱和的游戏背景从环里透出来，给灰环加一层蓝调
local GRID_TINT    = 0.38   -- 中性压暗系数，见 grid 创建处注释；0.38 为 2026-10-03 真机定值

-- 暗黑 160px 原值的分子。一律先乘后除（size * N / DIABLO_BASE）：
-- size * (N / DIABLO_BASE) 的浮点舍入与十进制字面量不一致，spec 无法精确断言。
local DIABLO_BASE = 160   -- 暗黑球体边长（px）；每个 N 都是相对它的原值
local GRID_N      = 210   -- 装饰环，每边溢出
local GLOSS_N     = 162
local SHADOW_N    = 162   -- 有意等于 GLOSS_N：高光与内缘暗影两层完全重合
local MASK_N      = 184   -- 高光线圆形遮罩
local SPARK_W_N   = 192   -- 高光线，比遮罩宽，两端被切掉
local SPARK_H_N   = 8

-- 两层气泡贴图各比球大一点，且溢出量不同（暗黑原值 160+8 / 160+2）。
-- 必须溢出：裁剪框才永远切进气泡场内部，气泡看起来是从液面下冒出/沉下去，
-- 而不是在一个看得见的方块里打转。两层溢出量不同则视差不同。
local BUBBLE1_N    = 168
local BUBBLE2_N    = 162
local BUBBLE_ALPHA = 0.3   -- 静止 alpha，同时也是脉冲上界（暗黑原值）；真机试过 0.4 只增泡沫噪点不增亮，回退
local BUBBLE_DIM   = 0.3   -- 脉冲下界比例：下界 = BUBBLE_ALPHA × BUBBLE_DIM（暗黑 0.3*bubblesalpha 同款）

local WHITE_8X8 = "Interface\\Buttons\\WHITE8X8"

local function scaled(size, numerator)
  return size * numerator / DIABLO_BASE
end

--- 居中的正方形贴图；用 SetSize + CENTER 而非暗黑的四边内缩锚点，
--- 后者算出的 inset 有浮点误差、无法精确断言，几何结果两者一致。
local function centeredSquare(texture, anchorTo, size, numerator)
  local edge = scaled(size, numerator)
  texture:SetSize(edge, edge)
  texture:SetPoint("CENTER", anchorTo, "CENTER", 0, 0)
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
  bar:EnableMouse(false)   -- 点击穿透：SpellRatioOrb 依赖没有子框吃点击（同 AlertBanner.lua:53）
  if reverse then bar:SetReverseFill(true) end
  return bar
end

--- 裁剪框必须 parent 到 orb 而不是 driver：driver 是 SetAlpha(0) 的，
--- 框 alpha 会向子级传播，挂上去整条液体会变透明。
local function createClip(orb, driver, reverse)
  local clip = CreateFrame("Frame", nil, orb)
  clip:SetFrameLevel(orb:GetFrameLevel() + 1)
  clip:EnableMouse(false)   -- 点击穿透：SpellRatioOrb 依赖没有子框吃点击（同 AlertBanner.lua:53）
  local driverTex = driver:GetStatusBarTexture()
  -- 两个分支把「固定边」锚到不同的框（反向→orb，正向→driver）。driver 是 SetAllPoints(orb)，
  -- 两种写法几何等价，而设计文档渲染栈表第 3、5 行分别规定了它们——别为了对称统一掉。
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
  -- -7 这个 sublayer 是惰性的：裁剪框里没有别的 region 与它排序，而气泡挂在 scroll（clip 的
  -- 子框）上、子框恒画在父框贴图之上，与 draw layer 无关。保留 -7 只因渲染栈表这么规定。
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
  scroll:EnableMouse(false)   -- 点击穿透：SpellRatioOrb 依赖没有子框吃点击（同 AlertBanner.lua:53）
  return scroll
end

--- 一层旋转的气泡场。旋转周期与 Alpha 脉冲周期耦合（duration/3 + 6）：
--- 转得慢的层脉得也慢，这是「液体」错觉的来源之一。
--- mirrored 层额外把两个 Alpha 动画的 Order 对调，使两层脉冲错开半个周期——
--- 两个反相的周期信号叠加读起来是非周期的，这是整套效果里最便宜的一招。
local function createBubble(scroll, size, texturePath, numerator, sublayer, degrees, duration, mirrored)
  -- sublayer 由调用方逐层给定、两侧同一套（bubbles1 恒压在 bubbles2 之上），不随 mirrored 翻转。
  -- 两层都是 ADD、加性混合可交换，怎么排都零像素差异；统一它只因渲染栈表 3c 与 5a-c 写的都是 -1,-2。
  local t = scroll:CreateTexture(nil, "ARTWORK", nil, sublayer)
  centeredSquare(t, scroll, size, numerator)
  t:SetTexture(texturePath)
  -- 镜像一半的层：否则两层读起来是同一张图叠了两次，而不是两团独立的气泡
  if mirrored then t:SetTexCoord(1, 0, 0, 1) end
  t:SetBlendMode("ADD")     -- ADD=发光：交叠处加亮，读作光在液体里折射而非一层遮另一层
  -- 静止 alpha 不是冗余：WoW 的 Alpha 动画覆盖 region alpha 而非乘算，
  -- 少了这一行首帧会以默认 1.0 满亮 ADD 闪一下；组被 Stop 后停住的也是这个值。
  t:SetAlpha(BUBBLE_ALPHA)

  -- spin 与 pulse 必须是两个独立的组，别「简化」成一个：同组内的动画按 Order 串行播放，
  -- REPEAT 又从 Order 1 重来。合成一组就会转满 30s 后僵住 16s、等明暗跑完才重启。
  -- 暗黑把 t.ag / t.aga 分开正是这个原因（units\player.lua:142-166），只是从没写出来。
  local spin = t:CreateAnimationGroup()
  -- 有意不调 rotation:SetOrigin：Rotation 默认绕 region 的 CENTER 转，而 centeredSquare
  -- 已把该点落在 scroll 的 CENTER（= 球心），正是我们要的旋转轴。
  local rotation = spin:CreateAnimation("Rotation")
  rotation:SetDegrees(degrees)
  rotation:SetDuration(duration)
  rotation:SetOrder(1)
  spin:SetLooping("REPEAT")   -- 先设循环再 Play：暗黑把这两行写反了（客户端恰好容忍），别照抄
  spin:Play()

  local pulse = t:CreateAnimationGroup()
  local phase = duration / 3 + 6
  -- 暗黑把下面这两组 SetFromAlpha/SetToAlpha 注释掉、靠调用方后补
  -- （units\player.lua:158-165）；照抄会静默退化成默认的 fade-to-1，观感完全不同。
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

--- 一侧的两层气泡。reverseSide=true 的 eb 侧整体反向（sign），使两侧旋向互为镜像；
--- 每侧的第二层再翻一次镜像标志，保证「一层正、一层镜像」在两侧都成立。
--- reverseSide 说的是「哪一侧」，与 createBubble 的 mirrored（「这一层是否水平翻转」）不是同一件事。
local function createBubbles(scroll, size, tex, reverseSide)
  local sign = reverseSide and -1 or 1
  return {
    -- 30 与 45 的 LCM 是 90：两层每 90 秒才回到同一构型，肉眼读不出循环
    createBubble(scroll, size, tex.bubbles1, BUBBLE1_N, -1, sign * 360, 30, reverseSide),
    createBubble(scroll, size, tex.bubbles2, BUBBLE2_N, -2, -sign * 360, 45, not reverseSide),
  }
end

--- 装饰环的外接边长与每边溢出量。消费方（SpellRatioOrb）的框体尺寸、缩放把手位置
--- 与屏幕夹取范围都以此为基准，必须从这里导出而不是各自重算 210/160：
--- 否则改了 GRID_N，框体会静默与美术脱节，而且没有任何测试能发现。
function OrbLiquid.GridSize(size)
  return scaled(size, GRID_N)
end

function OrbLiquid.GridOverhang(size)
  return (OrbLiquid.GridSize(size) - size) / 2
end

function OrbLiquid:New(parent, size)
  local tex = Theme.textures.orb
  local orb = CreateFrame("Frame", nil, parent)
  orb:SetSize(size, size)

  -- -6 与液体的 -7 不构成叠放次序：sublayer 只在同一个框内排序（overlay 上那四张才是靠它排的），
  -- 而液体挂在 frameLevel+1 的 eqClip/ebClip 上，整棵裁剪子树都画在 orb 自己的 region 之上。
  orb.back = orb:CreateTexture(nil, "BACKGROUND", nil, -6)
  orb.back:SetAllPoints(orb)
  orb.back:SetTexture(tex.back)
  orb.back:SetAlpha(BACK_ALPHA)

  -- 地震术：底部，正向填充
  orb.eqDriver = createDriver(orb, FORWARD)
  orb.eqClip   = createClip(orb, orb.eqDriver, FORWARD)
  orb.eqLiquid = createLiquid(orb, orb.eqClip, tex.filling)
  orb.eqScroll = createScroll(orb, orb.eqClip, size)
  -- 气泡挂 scroll 而不是 clip：这样才继承 SetClipsChildren 的液位裁剪，同时中心恒在球心
  orb.eqBubbles = createBubbles(orb.eqScroll, size, tex, false)

  -- 元素冲击：顶部，反向填充
  orb.ebDriver = createDriver(orb, REVERSE)
  orb.ebClip   = createClip(orb, orb.ebDriver, REVERSE)
  orb.ebLiquid = createLiquid(orb, orb.ebClip, tex.filling)
  orb.ebScroll = createScroll(orb, orb.ebClip, size)
  orb.ebBubbles = createBubbles(orb.ebScroll, size, tex, true)

  -- overlay 指「不被裁剪的顶层组」，不是 WoW 的 OVERLAY 绘制层：它上面的每张贴图都是
  -- BACKGROUND，所以下面那些 CreateTexture(nil, "BACKGROUND", nil, 3) 不是自相矛盾。
  orb.overlay = CreateFrame("Frame", nil, orb)
  orb.overlay:SetFrameLevel(orb:GetFrameLevel() + 2)
  orb.overlay:SetAllPoints(orb)
  orb.overlay:EnableMouse(false)   -- 点击穿透：SpellRatioOrb 依赖没有子框吃点击（同 AlertBanner.lua:53）

  -- 遮罩锚到固定的 overlay：分界线高度会变，固定圆形遮罩才能在任意高度
  -- 正确切掉高光线的两端。
  orb.sparkMask = orb.overlay:CreateMaskTexture()
  orb.sparkMask:SetTexture(tex.sparkMask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  centeredSquare(orb.sparkMask, orb.overlay, size, MASK_N)

  orb.spark = orb.overlay:CreateTexture(nil, "BACKGROUND", nil, -3)
  orb.spark:SetSize(scaled(size, SPARK_W_N), scaled(size, SPARK_H_N))
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
  -- 有意不加 SetTexCoord：暗黑 units\player.lua:579-587 裁 gloss、:591-600 不裁 orbshadow。
  -- 两层同为 162/160（97.2²）却只有 gloss 裁，是照抄参考实现，不是漏写。
  orb.orbshadow = orb.overlay:CreateTexture(nil, "BACKGROUND", nil, 3)
  centeredSquare(orb.orbshadow, orb.overlay, size, SHADOW_N)
  orb.orbshadow:SetTexture(tex.shadow)
  orb.orbshadow:SetVertexColor(0, 0, 0)
  orb.orbshadow:SetAlpha(SHADOW_ALPHA)

  -- sublevel 4（暗黑是 3）：让装饰环压在 gloss/shadow 之上保持锐利。
  orb.grid = orb.overlay:CreateTexture(nil, "BACKGROUND", nil, 4)
  centeredSquare(orb.grid, orb.overlay, size, GRID_N)
  orb.grid:SetTexture(tex.grid)
  orb.grid:SetAlpha(GRID_ALPHA)
  -- 中性灰压暗，不是染色：orb_grid1 的美术是纯灰度（非透明像素均值 55.8/55.8/55.8，
  -- 带 255 的镜面高光），用户反馈整环太亮、太「铬」。顶点色是逐通道相乘，灰乘灰只降
  -- 亮度、不加色相。别换成 Theme.colors.accent——那是另一个被明确否掉的方案。
  orb.grid:SetVertexColor(GRID_TINT, GRID_TINT, GRID_TINT)

  -- New 返回的是 Frame，不是带 __index 的表，方法必须显式挂到实例上；
  -- 也不能 setmetatable 覆盖——Frame 自带的 metatable 承载全部 widget 方法，换掉它
  -- orb:SetSize / orb:CreateTexture 就全废了。
  -- 这里按名查表，所以 SetSplit / SetColors 定义在 New 之后也能正常工作
  -- （New 的函数体在调用时才求值，那时整个文件已加载完）。
  orb.SetSplit = OrbLiquid.SetSplit
  orb.SetColors = OrbLiquid.SetColors

  return orb
end

--- 染色范围是「液体 + 该侧两层气泡」，三者必须同色：气泡贴图是白/灰度遮罩，
--- 本就设计成靠顶点色上色，只染液体不染气泡会得到一团白色泡沫浮在有色液体上。
--- 有意不染 grid（装饰环）：用户明确要求保留原图色、不跟 EUI 主题。
local function applyColor(liquid, bubbles, color)
  local maxChannel = math.max(color[1], color[2], color[3])
  local r, g, b = color[1], color[2], color[3]
  if maxChannel > 0 then
    r, g, b = r / maxChannel, g / maxChannel, b / maxChannel
  end
  r = r + (1 - r) * LIQUID_LIFT
  g = g + (1 - g) * LIQUID_LIFT
  b = b + (1 - b) * LIQUID_LIFT
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
--- 两个独立 driver bar 而非一个互补 bar：单 bar 在 0:0 时会让反向侧填满整球，
--- 而设计要求 0:0 是一个暗色空球（两侧都 SetValue(0) + 都隐藏）。
--- 两侧同帧写入同一缓动曲线，目标值合计 10 时中间值也严格互补，分界线不出缝不重叠。
--- 缓动交给客户端原生插值，不自造 tween、不加 per-frame Lua。
---
--- 高光线是「两种液体的交界弯月面」，只有一侧有液体时不存在交界，所以判据必须是
--- 「两侧都 >0」而不是「合计 >0」：spark 锚在 eqClip TOP，eq==0 时 eqClip 塌缩到球底，
--- 于是 eb=10/eq=0（整球紫）会把高光线画在球底边缘——满球的液面却在球顶。
--- eb=0/eq=10 时高光线虽落在球顶（位置说得通），但单一液体同样没有交界可高亮。
--- 隐藏框不会使其锚点失效（几何照样解算），所以 spark 必须显式 Hide()，不会自己消失。
---
--- 用点号 + 显式 orb 形参：这两个方法要挂到 New 返回的那个 Frame 实例上（见 New 末尾），
--- 所以不能用冒号语法定义在 self 上。调用方照旧写 orb:SetSplit(...)。
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

--- topColor / bottomColor：{r, g, b[, a]}，缺省 a 视作 1（调用方常只给三通道语义色）。
--- 顺序是 top 先、bottom 后，与 SetSplit 一致；top = 元素冲击（紫），bottom = 地震术（金）。
--- 两侧搞反不会报错，只会得到一个颜色互换但仍然好看的球，所以调用方要自己盯住。
---
--- 必须与 New() 在同一次 Lua 执行内调用：气泡刻意不留灰色占位顶点色（暗黑那个
--- SetVertexColor(0.5,0.5,0.5) 是为覆盖「事件驱动的颜色钩子晚一帧」的空档，我们这里
--- 由 Update() 同步调用，Lua 跑完客户端才渲染，可证明零帧未染色）。把本方法推迟到
--- 事件回调里就会有一帧全亮 ADD 闪白。
function OrbLiquid.SetColors(orb, topColor, bottomColor)
  applyColor(orb.ebLiquid, orb.ebBubbles, topColor)
  applyColor(orb.eqLiquid, orb.eqBubbles, bottomColor)
end

MDT_NPT.OrbLiquid = OrbLiquid
