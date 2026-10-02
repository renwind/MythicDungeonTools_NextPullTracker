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

local frame

local function isFiniteNumber(v)
  return type(v) == "number" and v == v and math.abs(v) < math.huge
end

local function validPosition(pos)
  return type(pos) == "table"
    and type(pos[1]) == "string" and VALID_ANCHORS[pos[1]]
    and type(pos[2]) == "string" and VALID_ANCHORS[pos[2]]
    and isFiniteNumber(pos[3])
    and isFiniteNumber(pos[4])
end

local function clampScale(value)
  if not isFiniteNumber(value) then return 1 end
  if value < SCALE_MIN then return SCALE_MIN end
  if value > SCALE_MAX then return SCALE_MAX end
  return value
end

local function savePosition(f)
  local db = MDT_NPT:GetDB()
  if not (db and db.beacon) then return end

  local point, _, relativePoint, x, y = f:GetPoint()
  if not point then return end
  db.beacon.spellRatioOrbPos = {
    point,
    relativePoint or point,
    x or 0,
    y or 0,
  }
end

local function saveScale(f)
  local db = MDT_NPT:GetDB()
  if db and db.beacon then
    db.beacon.spellRatioOrbScale = f:GetScale()
  end
end

local function finishMoving(f)
  f:StopMovingOrSizing()
  savePosition(f)
end

local function createResizeGrip(parent)
  local grip = CreateFrame("Button", nil, parent)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
  grip:SetFrameLevel(parent:GetFrameLevel() + 5)
  grip:SetAlpha(0.7)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

  local function applyScaleFromDrag(self)
    local cursorX, cursorY = GetCursorPosition()
    local deltaX = (cursorX - self.startX) / (FRAME_BASE_W * self.uiScale)
    local deltaY = (self.startY - cursorY) / (FRAME_BASE_H * self.uiScale)
    local delta = math.abs(deltaX) > math.abs(deltaY) and deltaX or deltaY
    parent:SetScale(clampScale(self.startScale + delta))
  end

  local function finishScaling(self)
    if not self.dragging then return end
    self.dragging = false
    self:SetScript("OnUpdate", nil)
    saveScale(parent)
  end

  grip:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" or not IsAltKeyDown() then return end
    self.dragging = true
    self.startX, self.startY = GetCursorPosition()
    self.startScale = parent:GetScale()
    self.uiScale = UIParent:GetEffectiveScale()
    self:SetScript("OnUpdate", applyScaleFromDrag)
  end)

  grip:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then finishScaling(self) end
  end)
  grip:SetScript("OnEnter", function(self)
    self:SetAlpha(1)
  end)
  grip:SetScript("OnLeave", function(self)
    if not self.dragging then self:SetAlpha(0.7) end
  end)

  grip:EnableMouse(false)
  grip:Hide()
  return grip, finishScaling
end

local function ensureFrame()
  if frame then return frame end

  local db = MDT_NPT:GetDB()
  local beacon = db and db.beacon
  local restoredScale = clampScale(beacon and beacon.spellRatioOrbScale)

  frame = CreateFrame("Frame", "MDTNPTSpellRatioOrb", UIParent)
  frame:SetSize(FRAME_BASE_W, FRAME_BASE_H)
  frame:SetScale(restoredScale)
  if beacon then beacon.spellRatioOrbScale = restoredScale end
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:EnableMouse(false)

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

  local finishScaling
  frame.resizeGrip, finishScaling = createResizeGrip(frame)

  frame:SetScript("OnDragStart", function(self)
    if IsAltKeyDown() then
      self:StartMoving()
      self.dragging = true
    end
  end)
  frame:SetScript("OnDragStop", function(self)
    if not self.dragging then return end
    self.dragging = false
    finishMoving(self)
  end)

  local function applyClickThrough()
    local interactive = IsAltKeyDown() and true or false
    if not interactive then
      finishScaling(frame.resizeGrip)
      if frame.dragging then
        frame.dragging = false
        finishMoving(frame)
      end
    end
    frame:EnableMouse(interactive)
    frame.resizeGrip:EnableMouse(interactive)
    if interactive then
      frame.resizeGrip:SetAlpha(0.7)
      frame.resizeGrip:Show()
    else
      frame.resizeGrip:Hide()
    end
  end

  frame:RegisterEvent("MODIFIER_STATE_CHANGED")
  frame:SetScript("OnEvent", function(_, event)
    if event == "MODIFIER_STATE_CHANGED" then applyClickThrough() end
  end)
  applyClickThrough()

  local pos = beacon and beacon.spellRatioOrbPos
  if validPosition(pos) then
    frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
  else
    frame:SetPoint("LEFT", MDT_NPT.Beacon:GetFrame(), "RIGHT", 12, 0)
  end

  frame:Hide()
  return frame
end

local function elementalSpecActive()
  if not (C_SpecializationInfo
      and type(C_SpecializationInfo.GetSpecialization) == "function"
      and type(C_SpecializationInfo.GetSpecializationInfo) == "function") then
    return false
  end
  local specIndex = C_SpecializationInfo.GetSpecialization()
  return specIndex ~= nil and C_SpecializationInfo.GetSpecializationInfo(specIndex) == 262
end

local function hide()
  if frame then frame:Hide() end
end

function SpellRatioOrb:GetFrame()
  return ensureFrame()
end

function SpellRatioOrb:Update()
  local db = MDT_NPT:GetDB()
  local state = MDT_NPT.state
  if not (db and db.beacon and db.beacon.spellRatioOrb
      and state and state.active
      and state.currentNextPull and state.presetUID
      and elementalSpecActive()) then
    hide()
    return
  end

  -- Follow the route tracking was built from (by uid), not MDT's current selection:
  -- the season default can re-point the dungeon's selection after import, which
  -- would otherwise hide the orb even though the tracked route is still present.
  local preset = MDT and MDT.GetTrackedPreset and MDT:GetTrackedPreset(state)
  if not (preset and preset.uid == state.presetUID) then
    hide()
    return
  end

  local presetValue = preset.value
  local pull = presetValue and presetValue.pulls and presetValue.pulls[state.currentNextPull]
  local enemies = presetValue and MDT.dungeonEnemies
    and MDT.dungeonEnemies[presetValue.currentDungeonIdx]
  local row = SpellRatioData:Get(state.presetUID, state.currentNextPull)
  if not row or not SpellRatioData:Verify(
      state.presetUID, state.currentNextPull, pull, enemies) then
    hide()
    return
  end

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

MDT_NPT.SpellRatioOrb = SpellRatioOrb

local specializationEventFrame = CreateFrame("Frame")
specializationEventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
specializationEventFrame:SetScript("OnEvent", function(_, event, unit)
  if event == "PLAYER_SPECIALIZATION_CHANGED" and unit == "player" then
    SpellRatioOrb:Update()
  end
end)
