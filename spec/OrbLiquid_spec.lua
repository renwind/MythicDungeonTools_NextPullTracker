local mocks = require("wow_mocks")

local SIZE = 96

-- 前缀提到 local（同 spec/Theme_spec.lua），但断言仍写独立字面量，不去比对
-- Theme.textures.orb.*——那样就查不出 key 写错，路径映射由 Theme_spec 负责。
local ORB_MEDIA = "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\"

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

--- region 的 SetPoint 记录里是否存在一条锚到 target 的 pointName
local function anchorsTo(region, target, pointName)
  for _, p in ipairs(region.points) do
    if p[2] == target and p[3] == pointName then return true end
  end
  return false
end

--- 取该 texture 创建的所有动画组：mock 用 ag.owner 记录归属，
--- 全局抓手 __orbTestAnimations 由 scenario 在 New 前后挂上/摘掉
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

describe("OrbLiquid render stack", function()
  before_each(function() mocks.reset() end)

  it("creates a square orb frame of the requested size", function()
    scenario(function(_, orb)
      assert.equals("Frame", orb.kind)
      assert.equals(SIZE, orb:GetWidth())
      assert.equals(SIZE, orb:GetHeight())
      -- parent 必须真的落到传进来的那个框上：SpellRatioOrb 要把球塞进自己的框里
      assert.equals(UIParent, orb.parent)
      -- 环尺寸推导必须导出而非各消费方重算 210/160：框体、缩放把手、屏幕夹取都以它为准
      assert.equals(126, MDT_NPT.OrbLiquid.GridSize(SIZE))
      assert.equals(15, MDT_NPT.OrbLiquid.GridOverhang(SIZE))
    end)
  end)

  it("lays a full-size backdrop at BACKGROUND sublayer -6", function()
    scenario(function(_, orb)
      assert.equals(ORB_MEDIA .. "orb_back.tga", orb.back.texture)
      assert.equals(0.4, orb.back.alpha)
      assert.equals("BACKGROUND", orb.back.layer)
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
        -- 整条裁剪几何都建立在「driver 恰好与球同尺寸」上：换成 SetSize + BOTTOM 锚点
        -- 在 mock 里同样能解算出 4 个锚点，但游戏内液位会整体偏移。
        assert.equals(orb, driver.allPoints)
        assert.equals("BACKGROUND", driver:GetStatusBarTexture().drawLayer)
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
      -- anchorsTo 只查「有没有」，两个分支的锚点都挂上去也照样全绿，所以钉住总数
      assert.equals(4, #orb.eqClip.points)
    end)
  end)

  it("anchors the elemental clip top to the orb and bottom to the reverse-filled texture", function()
    scenario(function(_, orb)
      local tex = orb.ebDriver:GetStatusBarTexture()
      assert.is_true(anchorsTo(orb.ebClip, orb, "TOPLEFT"))
      assert.is_true(anchorsTo(orb.ebClip, orb, "TOPRIGHT"))
      assert.is_true(anchorsTo(orb.ebClip, tex, "BOTTOMLEFT"))
      assert.is_true(anchorsTo(orb.ebClip, tex, "BOTTOMRIGHT"))
      assert.equals(4, #orb.ebClip.points)
    end)
  end)

  it("sizes each liquid to the full orb so the artwork never scales", function()
    scenario(function(_, orb)
      for _, liquid in ipairs({ orb.eqLiquid, orb.ebLiquid }) do
        assert.equals(orb, liquid.allPoints)
        assert.equals(ORB_MEDIA .. "orb_filling15.tga", liquid.texture)
        assert.same({ 0.05, 0.95, 0.05, 0.95 }, liquid.texCoord)
        assert.equals("BACKGROUND", liquid.layer)
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
        assert.equals(1, #scroll.points)
      end
      assert.equals(orb.eqClip, orb.eqScroll.parent)
      assert.equals(orb.ebClip, orb.ebScroll.parent)
    end)
  end)

  it("builds the overlay above the clips with gloss, shadow and grid", function()
    scenario(function(_, orb)
      assert.equals(orb:GetFrameLevel() + 2, orb.overlay:GetFrameLevel())
      assert.equals(orb, orb.overlay.allPoints)

      assert.equals(ORB_MEDIA .. "orb_gloss.tga", orb.gloss.texture)
      assert.equals(97.2, orb.gloss:GetWidth())
      assert.equals(97.2, orb.gloss:GetHeight())
      assert.equals(0.35, orb.gloss.alpha)
      assert.equals("BACKGROUND", orb.gloss.layer)
      assert.equals(3, orb.gloss.sublayer)
      assert.same({ 0.05, 0.95, 0.05, 0.95 }, orb.gloss.texCoord)

      assert.equals(ORB_MEDIA .. "orb_shadow.tga", orb.orbshadow.texture)
      assert.same({ 0, 0, 0 }, orb.orbshadow.vertexColor)
      assert.equals(0.10, orb.orbshadow.alpha)
      assert.equals("BACKGROUND", orb.orbshadow.layer)
      assert.equals(3, orb.orbshadow.sublayer)
      -- 两半一起钉：gloss 裁、shadow 不裁是照抄暗黑（units\player.lua:585 对 :591-600）的
      -- 有意不对称，任一半单独漂移都算 bug。
      assert.is_nil(orb.orbshadow.texCoord)

      assert.equals(ORB_MEDIA .. "orb_grid1.tga", orb.grid.texture)
      assert.equals(126, orb.grid:GetWidth())
      assert.equals(1.0, orb.grid.alpha)
      assert.equals("BACKGROUND", orb.grid.layer)
      assert.equals(4, orb.grid.sublayer)
      -- 环只允许中性灰压暗（美术是纯灰度，用户嫌太亮），三个通道必须相等。
      -- 别把它「修正」成 Theme.colors.accent——那是被明确否掉的方案。
      assert.same({ 0.38, 0.38, 0.38 }, orb.grid.vertexColor)

      -- 同为 sublevel 3 时创建顺序决定谁在上面，设计要求 shadow 压在 gloss 之后。
      -- sparkMask 不在这个列表里：mock 把 CreateMaskTexture 收进单独的 masks 表。
      assert.same({ orb.overlay.regions[2], orb.overlay.regions[3] }, { orb.gloss, orb.orbshadow })
    end)
  end)

  it("masks the spark strip to the orb and centers it on the liquid boundary", function()
    scenario(function(_, orb)
      assert.equals("MaskTexture", orb.sparkMask.kind)
      assert.equals(ORB_MEDIA .. "orb_spark_mask.tga", orb.sparkMask.texture)
      -- 包裹模式对遮罩是承重的：它决定 0..1 UV 框之外采样返回什么，
      -- 即高光线两端是被干净切掉还是被拖花。渲染栈表第 6a 行要求它。
      assert.equals("CLAMPTOBLACKADDITIVE", orb.sparkMask.textureArgs[2])
      assert.equals("CLAMPTOBLACKADDITIVE", orb.sparkMask.textureArgs[3])
      assert.equals(110.4, orb.sparkMask:GetWidth())
      -- 遮罩必须锚到固定的 overlay 而不是会移动的高光线，
      -- 否则分界线在不同高度时切不出正确的圆形端点
      assert.is_true(anchorsTo(orb.sparkMask, orb.overlay, "CENTER"))
      assert.equals(1, #orb.sparkMask.points)

      assert.equals(ORB_MEDIA .. "orb_spark.tga", orb.spark.texture)
      assert.equals(115.2, orb.spark:GetWidth())
      assert.equals(4.8, orb.spark:GetHeight())
      assert.equals("BACKGROUND", orb.spark.layer)
      assert.equals("ADD", orb.spark.blendMode)
      assert.equals(orb.sparkMask, orb.spark.maskList[1])
      -- 高光线压在分界线上 = 地震侧裁剪框的 TOP
      assert.is_true(anchorsTo(orb.spark, orb.eqClip, "TOP"))
      assert.equals(orb.overlay, orb.spark.parent)
    end)
  end)
end)

describe("OrbLiquid bubble animation", function()
  before_each(function() mocks.reset() end)

  it("creates four oversized bubble layers parented to the scroll frames", function()
    scenario(function(_, orb)
      assert.equals(2, #orb.eqBubbles)
      assert.equals(2, #orb.ebBubbles)
      for _, b in ipairs(orb.eqBubbles) do
        assert.equals(orb.eqScroll, b.parent)
        -- parent 只带来裁剪继承；中心稳不稳全看锚点。挂到 eqClip 的 CENTER 时这些断言照样全绿，
        -- 但 clip 高度随液位变化，气泡就会跟着液面上下「游泳」——正是本设计要防的那个 bug。
        assert.is_true(anchorsTo(b, orb.eqScroll, "CENTER"))
        assert.equals(1, #b.points)   -- anchorsTo 只查「有没有」，多锚一条也算通过，故钉总数
        assert.equals("ADD", b.blendMode)
        assert.is_true(b:GetWidth() > SIZE)   -- 故意溢出，裁剪框才切进气泡场内部
        -- WoW 的 Alpha 动画是覆盖 region alpha 而非乘算，所以 SetAlpha(0.3) 不是冗余：
        -- 它让首个 tick 之前的 alpha 就等于脉冲上界，否则会先以默认 1.0 满亮 ADD 闪一帧
        assert.equals(0.3, b.alpha)
        assert.equals("ARTWORK", b.layer)   -- 渲染栈表 3c
      end
      for _, b in ipairs(orb.ebBubbles) do
        assert.equals(orb.ebScroll, b.parent)
        assert.is_true(anchorsTo(b, orb.ebScroll, "CENTER"))
        assert.equals(1, #b.points)
        assert.equals("ADD", b.blendMode)
        assert.is_true(b:GetWidth() > SIZE)
        assert.equals(0.3, b.alpha)
        assert.equals("ARTWORK", b.layer)   -- 渲染栈表 5a-c 与 3c 同
      end
      -- 两层溢出量不同：bubbles1 = 168/160（100.8），bubbles2 = 162/160（97.2）
      assert.equals(100.8, orb.eqBubbles[1]:GetWidth())
      assert.equals(97.2, orb.eqBubbles[2]:GetWidth())
      assert.equals(ORB_MEDIA .. "orb_rotation_bubbles1.tga", orb.eqBubbles[1].texture)
      assert.equals(ORB_MEDIA .. "orb_rotation_bubbles2.tga", orb.eqBubbles[2].texture)
      -- sublayer 逐层给定、两侧同一套（渲染栈表 3c 与 5a-c 都是 -1,-2），不随侧翻转。
      -- 两层同为 ADD、加性混合可交换，改回去零像素差异，这四条是唯一能发现漂移的断言。
      assert.equals(-1, orb.eqBubbles[1].sublayer)
      assert.equals(-2, orb.eqBubbles[2].sublayer)
      assert.equals(-1, orb.ebBubbles[1].sublayer)
      assert.equals(-2, orb.ebBubbles[2].sublayer)
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
      -- 镜像层把两个 Alpha 动画的 Order 对调，叠加出非周期感的晃动。
      -- 用 same 而非 equals 比对表：两边都是新建的字面量表，== 恒为 false。
      assert.same({ 1, 2 }, { normal.dim.order, normal.bright.order })
      assert.same({ 2, 1 }, { mirrored.dim.order, mirrored.bright.order })
    end)
  end)

  it("plays every animation group on repeat", function()
    scenario(function(env)
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

describe("OrbLiquid SetSplit / SetColors", function()
  before_each(function() mocks.reset() end)

  it("writes both driver bars with the exponential ease interpolation", function()
    scenario(function(_, orb)
      -- 方法必须真的挂在实例上：New 返回的是 Frame，若改用 setmetatable(orb, {__index=OrbLiquid})
      -- 会顶掉 Frame 自带的 metatable，连带废掉 SetSize/CreateTexture 等全部 widget 方法。
      -- rawget 绕过 __index，所以只有「直接赋值到实例」这一种写法能通过本断言。
      assert.is_function(rawget(orb, "SetSplit"))
      assert.is_function(rawget(orb, "SetColors"))
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
      -- 产品代码先按最大通道归一（保色相、主通道满亮）再向白色抬升 0.25，
      -- 否则顶点色与液体贴图相乘会把球内压成暗色玻璃
      local function tint(c)
        local m = math.max(c[1], c[2], c[3])
        local r, g, b = c[1] / m, c[2] / m, c[3] / m
        return { r + (1 - r) * 0.25, g + (1 - g) * 0.25, b + (1 - b) * 0.25, c[4] }
      end
      orb:SetColors(purple, gold)

      assert.same(tint(purple), orb.ebLiquid.vertexColor)
      assert.same(tint(gold), orb.eqLiquid.vertexColor)
      for _, b in ipairs(orb.ebBubbles) do assert.same(tint(purple), b.vertexColor) end
      for _, b in ipairs(orb.eqBubbles) do assert.same(tint(gold), b.vertexColor) end
      -- 装饰环不在 SetColors 的染色范围内：它只带自己的中性压暗，不跟技能色走
      assert.same({ 0.38, 0.38, 0.38 }, orb.grid.vertexColor)
    end)
  end)

  it("defaults the alpha channel when a color has only three components", function()
    scenario(function(_, orb)
      orb:SetColors({ 0.5, 0.25, 0.75 }, { 0.1, 0.2, 0.3 })
      -- {0.5,0.25,0.75} 归一后 = {2/3,1/3,1}；{0.1,0.2,0.3} 归一后 = {1/3,2/3,1}
      assert.same({ 2 / 3 + (1 / 3) * 0.25, 1 / 3 + (2 / 3) * 0.25, 1, 1 }, orb.ebLiquid.vertexColor)
      assert.same({ 1 / 3 + (2 / 3) * 0.25, 2 / 3 + (1 / 3) * 0.25, 1, 1 }, orb.eqLiquid.vertexColor)
    end)
  end)

  it("starts fully empty before the first SetSplit", function()
    scenario(function(_, orb)
      assert.equals(0, orb.ebDriver.value)
      assert.equals(0, orb.eqDriver.value)
    end)
  end)
end)
