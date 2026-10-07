local mocks = require("wow_mocks")

local ORB_MEDIA = "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\orb\\"
local ORB_SIZE = 96
local GRID_SIZE = 126
local FRAME_W = 126
local FRAME_H = 144
local EASE = nil   -- 在 scenario 内捕获，见下
local SIZE_GRABBER_UP = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up"
local SIZE_GRABBER_HIGHLIGHT = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight"
local SIZE_GRABBER_DOWN = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down"

--- 比例文字的两个数字分别染成球内液体的实际颜色（与 OrbLiquid.Tint 同公式），
--- 冒号沿用 FontString 基准色。断言必须走同一套转义，否则和产品代码各写一份 hex 会漂移。
local function tintEscape(c)
  local m = math.max(c[1], c[2], c[3])
  local r, g, b = c[1] / m, c[2] / m, c[3] / m
  r = r + (1 - r) * 0.25
  g = g + (1 - g) * 0.25
  b = b + (1 - b) * 0.25
  return string.format("|cFF%02X%02X%02X",
    math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end
local EB_ESC = tintEscape({ 179 / 255, 76 / 255, 255 / 255 })
local EQ_ESC = tintEscape({ 230 / 255, 190 / 255, 114 / 255 })
local function ratio(text)
  local eb, eq = text:match("^(%d+):(%d+)$")
  return EB_ESC .. eb .. "|r : " .. EQ_ESC .. eq .. "|r"
end

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    env.dbChar.rotationRatios = {}
    env.db.beacon.spellRatioOrb = true
    env.liveFingerprint = "fp"
    env.activePull = { [1] = { 1 } }
    env.preset = {
      uid = "uid1",
      value = {
        currentDungeonIdx = 1,
        pulls = { env.activePull },
      },
    }

    MDT_NPT.MDT = MDT
    MDT.GetCurrentPreset = function(_, dungeonIndex)
      env.requestedDungeonIndex = dungeonIndex
      return env.currentPreset or env.preset
    end
    -- Mirrors the adapter: the tracked route is resolved by uid, independent of
    -- MDT's (possibly drifted) current selection for the dungeon.
    MDT.GetTrackedPreset = function(_, st)
      env.trackedState = st
      return env.trackedPreset or env.preset
    end
    MDT.dungeonEnemies = { [1] = { [1] = { clones = {} } } }
    MDT_NPT.state = {
      active = true,
      currentNextPull = 1,
      presetUID = "uid1",
      dungeonIndex = 1,
    }
    MDT_NPT.CooldownData = {
      computePullFingerprint = function(pull, enemies)
        env.verifiedPull = pull
        env.verifiedEnemies = enemies
        if not pull or not enemies then return nil end
        return env.liveFingerprint
      end,
    }
    env.beaconFrame = CreateFrame("Frame", nil, UIParent)
    MDT_NPT.Beacon = { GetFrame = function() return env.beaconFrame end }

    local createFrame = CreateFrame
    env.createdFrames = {}
    CreateFrame = function(...)
      local created = createFrame(...)
      env.createdFrames[#env.createdFrames + 1] = created
      return created
    end

    mocks.loadSource("Modules/Theme.lua")
    mocks.loadSource("Modules/SpellRatioData.lua")
    mocks.loadSource("Modules/OrbLiquid.lua")
    mocks.loadSource("Modules/SpellRatioOrb.lua")
    EASE = Enum.StatusBarInterpolation.ExponentialEaseOut
    fn(env, MDT_NPT.SpellRatioOrb)
  end)
end

local function seed(elementalBlast, earthquake, fingerprint)
  assert.is_true(MDT_NPT.SpellRatioData:Set(
    "uid1", 1, elementalBlast, earthquake, fingerprint or "fp"))
end

local function point(region)
  return region.points[#region.points]
end

--- region 的 SetPoint 记录里是否存在一条锚到 target 的 pointName
local function anchorsTo(region, target, pointName)
  for _, p in ipairs(region.points) do
    if p[2] == target and p[3] == pointName then return true end
  end
  return false
end

describe("SpellRatioOrb frame", function()
  before_each(function() mocks.reset() end)

  it("renders the tracked route even after MDT's dungeon selection drifts", function()
    scenario(function(env, orb)
      seed(8, 2)
      -- MDT re-pointed its current selection at a different route (season default
      -- overriding the manual pick); the orb must still follow the tracked uid.
      env.currentPreset = { uid = "drifted", value = { currentDungeonIdx = 1, pulls = { env.activePull } } }
      env.trackedPreset = env.preset
      orb:Update()
      assert.equals(MDT_NPT.state, env.trackedState)
      assert.is_true(orb:GetFrame():IsShown())
    end)
  end)

  it("registers a module-load specialization event and updates only for player", function()
    scenario(function(env, orb)
      assert.equals(1, #env.createdFrames)
      local eventFrame = env.createdFrames[1]
      assert.is_nil(eventFrame:GetName())
      assert.same({ "PLAYER_SPECIALIZATION_CHANGED" }, eventFrame.events)

      local updateCalls = 0
      orb.Update = function(self)
        assert.equals(orb, self)
        updateCalls = updateCalls + 1
      end

      eventFrame.scripts.OnEvent(eventFrame, "PLAYER_SPECIALIZATION_CHANGED", "party1")
      assert.equals(0, updateCalls)
      eventFrame.scripts.OnEvent(eventFrame, "PLAYER_SPECIALIZATION_CHANGED", "player")
      assert.equals(1, updateCalls)
    end)
  end)

  it("creates the named 96px orb inside a 126-wide frame with no icons and no ticker", function()
    scenario(function(env, orb)
      local frame = orb:GetFrame()
      assert.equals("MDTNPTSpellRatioOrb", frame:GetName())
      assert.equals(ORB_SIZE, frame.orb:GetWidth())
      assert.equals(ORB_SIZE, frame.orb:GetHeight())
      assert.equals(GRID_SIZE, frame.orb.grid:GetWidth())
      -- 球必须内缩 GRID_OVERHANG，装饰环的外接矩形才正好等于框体：于是缩放把手落在环的
      -- 外角、SetClampedToScreen 的夹取范围与可见美术一致。符号写反或写成 0,0 会让整球
      -- 在框内斜移 15px，而其它断言全都察觉不到——这是唯一钉住这个偏移的地方。
      assert.same({ "TOPLEFT", frame, "TOPLEFT", 15, -15 }, point(frame.orb))
      assert.equals(frame, frame.orb.parent)
      -- 球旁的技能图标已按用户要求移除：比例只由液体颜色与下方文字表达
      assert.is_nil(frame.primaryIcon)
      assert.is_nil(frame.secondaryIcon)
      assert.is_true(frame.clamped)
      assert.equals(0, #env.tickers)
    end)
  end)

  it("defaults to scale one without changing base geometry", function()
    scenario(function(_, orb)
      local frame = orb:GetFrame()
      assert.equals(1, frame:GetScale())
      assert.equals(FRAME_W, frame:GetWidth())
      assert.equals(FRAME_H, frame:GetHeight())
    end)
  end)

  it("restores a valid saved scale", function()
    scenario(function(env, orb)
      env.db.beacon.spellRatioOrbScale = 1.25
      assert.equals(1.25, orb:GetFrame():GetScale())
    end)
  end)

  it("clamps finite saved scales to the supported range", function()
    for _, case in ipairs({ { 0.25, 0.5 }, { 2.75, 2.0 } }) do
      scenario(function(env, orb)
        env.db.beacon.spellRatioOrbScale = case[1]
        assert.equals(case[2], orb:GetFrame():GetScale())
      end)
    end
  end)

  it("falls back to scale one for damaged saved values", function()
    for _, savedScale in ipairs({ "1.5", math.huge, -math.huge, 0 / 0 }) do
      scenario(function(env, orb)
        env.db.beacon.spellRatioOrbScale = savedScale
        assert.equals(1, orb:GetFrame():GetScale())
      end)
    end
  end)

  it("creates a bottom-right 16px resize grip with ChatFrame textures", function()
    scenario(function(_, orb)
      local frame = orb:GetFrame()
      local grip = frame.resizeGrip
      assert.is_not_nil(grip)
      assert.equals("Button", grip.kind)
      assert.equals(16, grip:GetWidth())
      assert.equals(16, grip:GetHeight())
      assert.same({ "BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0 }, point(grip))
      assert.equals(SIZE_GRABBER_UP, grip.normalTexture)
      assert.equals(SIZE_GRABBER_HIGHLIGHT, grip.highlightTexture)
      assert.equals(SIZE_GRABBER_DOWN, grip.pushedTexture)
    end)
  end)

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
      -- SetColors 是 top 先 bottom 后；两侧搞反不会报错，只会得到颜色互换但仍然好看的球，
      -- 所以必须端到端钉住实际落到液体上的顶点色（含 OrbLiquid 的归一 + 0.25 提亮）。
      local function tint(c)
        local m = math.max(c[1], c[2], c[3])
        local r, g, b = c[1] / m, c[2] / m, c[3] / m
        return { r + (1 - r) * 0.25, g + (1 - g) * 0.25, b + (1 - b) * 0.25, c[4] }
      end
      assert.same(tint({ 179 / 255, 76 / 255, 255 / 255, 1 }), o.ebLiquid.vertexColor)
      assert.same(tint({ 230 / 255, 190 / 255, 114 / 255, 1 }), o.eqLiquid.vertexColor)
    end)
  end)

  it("keeps the decorative grid ring neutral-dimmed and never theme-tinted", function()
    scenario(function(_, orb)
      local o = orb:GetFrame().orb
      assert.equals(ORB_MEDIA .. "orb_grid1.tga", o.grid.texture)
      assert.equals(1.0, o.grid.alpha)
      -- 锁定用户决定：环只用中性灰压暗（美术本身是纯灰度，用户嫌太亮），不跟 EUI 主题走。
      -- 别把它「修正」回 Theme.colors.accent。
      assert.same({ 0.38, 0.38, 0.38 }, o.grid.vertexColor)
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

  it("defaults twelve pixels to the right of Beacon", function()
    scenario(function(env, orb)
      local frame = orb:GetFrame()
      assert.same({ "LEFT", env.beaconFrame, "RIGHT", 12, 0 }, point(frame))
      assert.is_false(frame:IsShown())
    end)
  end)

  it("restores a saved position relative to UIParent", function()
    scenario(function(env, orb)
      env.db.beacon.spellRatioOrbPos = { "TOPLEFT", "BOTTOMLEFT", 14, -9 }
      local frame = orb:GetFrame()
      assert.same({ "TOPLEFT", UIParent, "BOTTOMLEFT", 14, -9 }, point(frame))
    end)
  end)

  it("falls back to Beacon for a damaged point or relativePoint", function()
    local invalidPositions = {
      { "NOT_AN_ANCHOR", "BOTTOMLEFT", 14, -9 },
      { "TOPLEFT", "NOT_AN_ANCHOR", 14, -9 },
    }
    for _, savedPosition in ipairs(invalidPositions) do
      scenario(function(env, orb)
        env.db.beacon.spellRatioOrbPos = savedPosition
        assert.same({ "LEFT", env.beaconFrame, "RIGHT", 12, 0 }, point(orb:GetFrame()))
      end)
    end
  end)

  it("falls back to Beacon for non-number or non-finite offsets", function()
    local invalidOffsets = {
      { "14", -9 },
      { 14, "-9" },
      { math.huge, -9 },
      { -math.huge, -9 },
      { 0 / 0, -9 },
      { 14, math.huge },
      { 14, -math.huge },
      { 14, 0 / 0 },
    }
    for _, offsets in ipairs(invalidOffsets) do
      scenario(function(env, orb)
        env.db.beacon.spellRatioOrbPos = { "TOPLEFT", "BOTTOMLEFT", offsets[1], offsets[2] }
        assert.same({ "LEFT", env.beaconFrame, "RIGHT", 12, 0 }, point(orb:GetFrame()))
      end)
    end
  end)
end)

describe("SpellRatioOrb rendering", function()
  before_each(function() mocks.reset() end)

  it("renders exact 8:2 splits and text", function()
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
      assert.equals(ratio("8:2"), frame.ratioText:GetText())
      assert.is_true(frame.ratioText:IsShown())
      assert.equals(env.activePull, env.verifiedPull)
      assert.equals(MDT.dungeonEnemies[1], env.verifiedEnemies)
      -- Resolved via the tracked state (uid-first), not MDT's ambient selection.
      assert.equals(MDT_NPT.state, env.trackedState)
    end)
  end)

  it("keeps both nonzero sides visible at a minimum ten-percent fill", function()
    scenario(function(_, orb)
      seed(1, 45)
      orb:Update()
      local frame = orb:GetFrame()
      assert.equals(1, frame.orb.ebDriver.value)
      assert.equals(9, frame.orb.eqDriver.value)
      assert.equals(ratio("0:10"), frame.ratioText:GetText())
    end)
  end)

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

  it("renders Earthquake as the larger fill", function()
    scenario(function(_, orb)
      seed(2, 8)
      orb:Update()
      local frame = orb:GetFrame()
      assert.equals(2, frame.orb.ebDriver.value)
      assert.equals(8, frame.orb.eqDriver.value)
      assert.equals(ratio("2:8"), frame.ratioText:GetText())
    end)
  end)

  it("keeps 5:5 text for equal and near-equal raw counts", function()
    scenario(function(_, orb)
      seed(3, 3)
      orb:Update()
      local frame = orb:GetFrame()
      assert.equals(ratio("5:5"), frame.ratioText:GetText())
      assert.equals(5, frame.orb.ebDriver.value)
      assert.equals(5, frame.orb.eqDriver.value)

      MDT_NPT.SpellRatioData:Set("uid1", 1, 51, 49, "fp")
      orb:Update()
      assert.equals(ratio("5:5"), frame.ratioText:GetText())
    end)
  end)

  it("keeps the dark empty orb visible for imported zero-zero", function()
    scenario(function(_, orb)
      seed(8, 2)
      orb:Update()
      local frame = orb:GetFrame()
      assert.is_true(frame.ratioText:IsShown())

      MDT_NPT.SpellRatioData:Set("uid1", 1, 0, 0, "fp")
      -- 先藏起来：0:0 分支必须自己把框 Show 回来（「暗色空球仍然可见」），
      -- 否则上一次 8:2 留下的显示状态会替它作证，这条断言就成了永真式。
      frame:Hide()
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
    end)
  end)
end)

describe("SpellRatioOrb visibility", function()
  before_each(function() mocks.reset() end)

  it("hides when the current wave has not been imported", function()
    scenario(function(env, orb)
      seed(8, 2)
      orb:Update()
      assert.is_true(orb:GetFrame():IsShown())
      env.dbChar.rotationRatios.uid1[1] = nil
      orb:Update()
      assert.is_false(orb:GetFrame():IsShown())
    end)
  end)

  it("hides when the imported fingerprint no longer matches", function()
    scenario(function(env, orb)
      seed(8, 2)
      orb:Update()
      assert.is_true(orb:GetFrame():IsShown())
      env.liveFingerprint = "changed"
      orb:Update()
      assert.is_false(orb:GetFrame():IsShown())
    end)
  end)

  it("hides when the current preset UID no longer matches tracking", function()
    scenario(function(env, orb)
      seed(8, 2)
      orb:Update()
      assert.is_true(orb:GetFrame():IsShown())
      env.preset.uid = "other-uid"
      orb:Update()
      assert.is_false(orb:GetFrame():IsShown())
    end)
  end)

  it("hides when tracking is absent or inactive", function()
    scenario(function(_, orb)
      seed(8, 2)
      local state = MDT_NPT.state
      orb:Update()
      assert.is_true(orb:GetFrame():IsShown())

      state.active = false
      orb:Update()
      assert.is_false(orb:GetFrame():IsShown())

      state.active = true
      orb:Update()
      assert.is_true(orb:GetFrame():IsShown())
      MDT_NPT.state = nil
      orb:Update()
      assert.is_false(orb:GetFrame():IsShown())
    end)
  end)

  it("hides without currentNextPull or preset UID", function()
    scenario(function(_, orb)
      seed(8, 2)
      orb:Update()
      assert.is_true(orb:GetFrame():IsShown())

      MDT_NPT.state.currentNextPull = nil
      orb:Update()
      assert.is_false(orb:GetFrame():IsShown())

      MDT_NPT.state.currentNextPull = 1
      orb:Update()
      assert.is_true(orb:GetFrame():IsShown())
      MDT_NPT.state.presetUID = nil
      orb:Update()
      assert.is_false(orb:GetFrame():IsShown())
    end)
  end)

  it("hides when the independent switch is off", function()
    scenario(function(env, orb)
      seed(8, 2)
      orb:Update()
      assert.is_true(orb:GetFrame():IsShown())
      env.db.beacon.spellRatioOrb = false
      orb:Update()
      assert.is_false(orb:GetFrame():IsShown())
    end)
  end)

  it("hides outside Elemental specialization 262", function()
    scenario(function(env, orb)
      seed(8, 2)
      orb:Update()
      assert.is_true(orb:GetFrame():IsShown())
      env.specID = 263
      orb:Update()
      assert.is_false(orb:GetFrame():IsShown())
    end)
  end)
end)

describe("SpellRatioOrb Alt interaction", function()
  before_each(function() mocks.reset() end)

  it("shows and enables the frame and grip only while Alt is held", function()
    scenario(function(env, orb)
      local frame = orb:GetFrame()
      local grip = frame.resizeGrip
      assert.is_false(frame:IsMouseEnabled())
      assert.is_false(grip:IsMouseEnabled())
      assert.is_false(grip:IsShown())

      env.alt = true
      frame.scripts.OnEvent(frame, "MODIFIER_STATE_CHANGED")
      assert.is_true(frame:IsMouseEnabled())
      assert.is_true(grip:IsMouseEnabled())
      assert.is_true(grip:IsShown())
      assert.equals(0.7, grip.alpha)

      grip.scripts.OnEnter(grip)
      assert.equals(1, grip.alpha)
      grip.scripts.OnLeave(grip)
      assert.equals(0.7, grip.alpha)

      env.alt = false
      frame.scripts.OnEvent(frame, "MODIFIER_STATE_CHANGED")
      assert.is_false(frame:IsMouseEnabled())
      assert.is_false(grip:IsMouseEnabled())
      assert.is_false(grip:IsShown())
      assert.is_nil(env.db.beacon.spellRatioOrbPos)
    end)
  end)

  it("scales uniformly from the dominant cursor axis, clamps and saves on mouse up", function()
    scenario(function(env, orb)
      local frame = orb:GetFrame()
      local grip = frame.resizeGrip
      UIParent.effectiveScale = 2
      env.alt = true
      frame.scripts.OnEvent(frame, "MODIFIER_STATE_CHANGED")

      env.cursorX, env.cursorY = 100, 100
      grip.scripts.OnMouseDown(grip, "LeftButton")
      assert.is_not_nil(grip:GetScript("OnUpdate"))
      -- 横向拖「基准宽度的一半」（屏幕像素 = FRAME_W × effectiveScale × 0.5）→ scale +0.5。
      -- 光标位移是被 FRAME_BASE_W/H 归一化的，所以这两个数必须跟着基准几何走，
      -- 否则量到的就不是「半宽」而是一截任意长度。
      env.cursorX = 100 + FRAME_W
      grip:GetScript("OnUpdate")(grip)
      assert.equals(1.5, frame:GetScale())
      -- SetScale 不改基准几何
      assert.equals(FRAME_W, frame:GetWidth())
      assert.equals(FRAME_H, frame:GetHeight())

      env.cursorX = 1000
      grip:GetScript("OnUpdate")(grip)
      assert.equals(2.0, frame:GetScale())
      env.cursorX = -1000
      grip:GetScript("OnUpdate")(grip)
      assert.equals(0.5, frame:GetScale())

      grip.scripts.OnMouseUp(grip, "LeftButton")
      assert.is_nil(grip:GetScript("OnUpdate"))
      assert.is_false(grip.dragging)
      assert.equals(0.5, env.db.beacon.spellRatioOrbScale)
      assert.is_nil(env.db.beacon.spellRatioOrbPos)
    end)
  end)

  it("uses vertical cursor movement when it is the dominant axis", function()
    scenario(function(env, orb)
      local frame = orb:GetFrame()
      local grip = frame.resizeGrip
      UIParent.effectiveScale = 2
      env.alt = true
      frame.scripts.OnEvent(frame, "MODIFIER_STATE_CHANGED")

      env.cursorX, env.cursorY = 100, 100
      grip.scripts.OnMouseDown(grip, "LeftButton")
      -- 纵向拖「基准高度的一半」（effectiveScale 2）→ +0.5；横向只挪 10px，
      -- 归一化后远小于纵向，所以主导轴必须是纵向。
      env.cursorX, env.cursorY = 110, 100 - FRAME_H
      grip:GetScript("OnUpdate")(grip)
      assert.equals(1.5, frame:GetScale())
      grip.scripts.OnMouseUp(grip, "LeftButton")
    end)
  end)

  it("is click-through by default and saves on OnDragStop", function()
    scenario(function(env, orb)
      local frame = orb:GetFrame()
      assert.is_false(frame:IsMouseEnabled())
      assert.same({ "LeftButton" }, frame.dragButtons)
      assert.same({ "MODIFIER_STATE_CHANGED" }, frame.events)

      env.alt = true
      frame.scripts.OnEvent(frame, "MODIFIER_STATE_CHANGED")
      assert.is_true(frame:IsMouseEnabled())
      frame.scripts.OnDragStart(frame)
      assert.is_true(frame.moving)
      assert.is_true(frame.dragging)
      frame:ClearAllPoints()
      frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 20, -30)
      frame.scripts.OnDragStop(frame)
      assert.is_false(frame.moving)
      assert.is_false(frame.dragging)
      assert.same({ "TOPLEFT", "BOTTOMLEFT", 20, -30 }, env.db.beacon.spellRatioOrbPos)
    end)
  end)

  it("ignores OnDragStop when moving never started", function()
    scenario(function(env, orb)
      local frame = orb:GetFrame()
      frame.scripts.OnDragStop(frame)
      assert.is_nil(env.db.beacon.spellRatioOrbPos)
    end)
  end)

  it("releasing Alt while scaling stops OnUpdate, saves and restores click-through", function()
    scenario(function(env, orb)
      local frame = orb:GetFrame()
      local grip = frame.resizeGrip
      env.alt = true
      frame.scripts.OnEvent(frame, "MODIFIER_STATE_CHANGED")
      env.cursorX, env.cursorY = 100, 100
      grip.scripts.OnMouseDown(grip, "LeftButton")
      -- 本用例的 effectiveScale 是默认的 1，所以半宽就是 FRAME_W / 2 个光标像素。
      env.cursorX = 100 + FRAME_W / 2
      grip:GetScript("OnUpdate")(grip)
      assert.equals(1.5, frame:GetScale())

      env.alt = false
      frame.scripts.OnEvent(frame, "MODIFIER_STATE_CHANGED")
      assert.is_nil(grip:GetScript("OnUpdate"))
      assert.is_false(grip.dragging)
      assert.equals(1.5, env.db.beacon.spellRatioOrbScale)
      assert.is_nil(env.db.beacon.spellRatioOrbPos)
      assert.is_false(frame:IsMouseEnabled())
      assert.is_false(grip:IsMouseEnabled())
      assert.is_false(grip:IsShown())
    end)
  end)

  it("releasing Alt mid-drag stops, saves and restores click-through", function()
    scenario(function(env, orb)
      local frame = orb:GetFrame()
      env.alt = true
      frame.scripts.OnEvent(frame, "MODIFIER_STATE_CHANGED")
      frame.scripts.OnDragStart(frame)
      assert.is_true(frame.dragging)
      frame:ClearAllPoints()
      frame:SetPoint("CENTER", UIParent, "CENTER", 7, 11)

      env.alt = false
      frame.scripts.OnEvent(frame, "MODIFIER_STATE_CHANGED")
      assert.is_false(frame.moving)
      assert.is_false(frame.dragging)
      assert.is_false(frame:IsMouseEnabled())
      assert.same({ "CENTER", "CENTER", 7, 11 }, env.db.beacon.spellRatioOrbPos)
    end)
  end)

  it("restores the previous IsAltKeyDown global after the runtime", function()
    local original = _G.IsAltKeyDown
    local previous = function() return "previous" end
    _G.IsAltKeyDown = previous

    scenario(function(_, orb)
      orb:GetFrame()
    end)

    local restored = _G.IsAltKeyDown
    _G.IsAltKeyDown = original
    assert.equals(previous, restored)
  end)
end)
