local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT
local L = MDT_NPT.L

local Beacon = MDT_NPT.Beacon
local Minimap = MDT_NPT.BeaconMinimap
local PullState = MDT_NPT.PullState
local pairs, ipairs, unpack, string_format, tonumber = pairs, ipairs, unpack, string.format, tonumber
local math_abs = math.abs
local Theme = MDT_NPT.Theme

-- MDT's AceLocale table (zhCN contains English->Chinese enemy names).
-- MDT UI is load-on-demand, so its locale may not be registered at Start; use silent=true
-- and retry on hover. Only cache successful lookups.
local mdtLocale
local function getMDTLocale()
  if mdtLocale then return mdtLocale end
  local ok, lib = pcall(LibStub, "AceLocale-3.0")
  if ok and lib then
    local ok2, loc = pcall(lib.GetLocale, lib, "MythicDungeonTools", true)
    if ok2 and loc then
      mdtLocale = loc
      return mdtLocale
    end
  end
  return nil
end

-- Short enemy name: exact NPC_ZH_FINAL override first (prefix/middle-head names),
-- then longest head-noun suffix from NPC_ZH_HEAD, then "…的" strip, else full name.
local function shortEnemyName(zh)
  if not zh or zh == "" then return nil end
  if MDT_NPT.NPC_ZH_FINAL and MDT_NPT.NPC_ZH_FINAL[zh] then return MDT_NPT.NPC_ZH_FINAL[zh] end
  local heads = MDT_NPT.NPC_ZH_HEAD
  if heads then
    local best
    for _, head in ipairs(heads) do
      if #zh >= #head and zh:sub(-#head) == head then
        if not best or #head > #best then best = head end
      end
    end
    if best then return best end
  end
  local after = zh:match("^.-的(.+)$")
  if after and after ~= "" then return after end
  return zh
end

-- Mob typing from static MDT data only (no nameplate parsing, to keep M+ frames
-- cheap). Level tiers per MDT enemy info: <=90 normal, 91 elite, >91 boss; isBoss
-- also forces boss. Priority: boss > elite > caster (interruptible spell) > other.
-- Tints the portrait short-name label.
local MOB_COLORS = {
  caster   = Theme.colors.mobCaster,
  miniboss = Theme.colors.mobMiniboss,
  boss     = Theme.colors.mobBoss,
  other    = Theme.colors.mobOther,
}

---Static caster signal from MDT: Enemy Info lists the mob's spells; any spell flagged
---interruptible means the mob casts (mirrors MDT's right-click Enemy Info spell list).
local function hasInterruptibleSpell(enemy)
  if not enemy.spells then return false end
  for _, flags in pairs(enemy.spells) do
    if flags and flags.interruptible then return true end
  end
  return false
end

local ELITE_LEVEL = 91 -- MDT enemy level tier: <=90 normal, ==91 elite, >91 boss

local function staticMobType(enemy)
  local level = enemy.level or 0
  if enemy.isBoss or level > ELITE_LEVEL then return "boss" end
  if level == ELITE_LEVEL then return "miniboss" end
  if hasInterruptibleSpell(enemy) then return "caster" end
  return "other"
end

local FRAME_BASE_W, FRAME_BASE_H = 418, 234  -- wider minimap viewport (208) + 184 info panel;
                                             -- height reserves the 2x4 portrait grid plus
                                             -- plan rows whose 开/留 labels sit below icons
local SCALE_MIN, SCALE_MAX = 0.5, 2.0

-- The old global MouseIsOver helper is no longer available in WoW 12.1.
-- Frames and regions expose the equivalent check as an instance method.
local function isMouseOver(region)
  return region ~= nil and type(region.IsMouseOver) == "function" and region:IsMouseOver() or false
end

---Drives uniform `SetScale` on the parent from cursor drag, then persists the
---final scale on release. Locked beacons ignore the drag.
local function createResizeGrip(parent)
  local grip = CreateFrame("Button", nil, parent)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
  grip:SetFrameLevel(parent:GetFrameLevel() + 5)
  grip:SetAlpha(0)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

  -- Per-axis cursor delta → scale: drag of one frame-edge worth of raw pixels
  -- equals one base-scale unit of growth, so the grip tracks the cursor on the
  -- dominant axis. The non-dominant axis is ignored to avoid double-counting on
  -- diagonal drags.
  local function applyScaleFromDrag(self)
    local nx, ny = GetCursorPosition()
    local dx = nx - self.startX
    local dy = self.startY - ny
    local denom = FRAME_BASE_W * self.uiScale
    local dsX = dx / denom
    local dsY = dy / (FRAME_BASE_H * self.uiScale)
    local ds = (math_abs(dsX) > math_abs(dsY)) and dsX or dsY
    local newScale = self.startScale + ds
    if newScale < SCALE_MIN then newScale = SCALE_MIN end
    if newScale > SCALE_MAX then newScale = SCALE_MAX end
    parent:SetScale(newScale)
  end

  grip:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    if MDT_NPT:GetBeaconState().locked then return end
    self.dragging = true
    self.startX, self.startY = GetCursorPosition()
    self.startScale = parent:GetScale()
    self.uiScale = UIParent:GetEffectiveScale()
    self:SetScript("OnUpdate", applyScaleFromDrag)
  end)

  grip:SetScript("OnMouseUp", function(self, button)
    if button ~= "LeftButton" then return end
    if not self.dragging then return end
    self.dragging = false
    self:SetScript("OnUpdate", nil)
    MDT_NPT:GetBeaconState().scale = parent:GetScale()
    -- The drag suppressed the normal OnLeave fade, so re-evaluate now.
    if not isMouseOver(parent) then
      local onLeave = parent:GetScript("OnLeave")
      if onLeave then onLeave(parent) end
    elseif not isMouseOver(self) then
      self:SetAlpha(0.7)
    end
  end)

  grip:SetScript("OnEnter", function(self)
    self:SetAlpha(1)
    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
    GameTooltip:SetText(L["Resize"], 1, 1, 1)
    GameTooltip:Show()
  end)

  grip:SetScript("OnLeave", function(self)
    if not self.dragging then self:SetAlpha(0.7) end
    GameTooltip:Hide()
  end)

  return grip
end

---Builds the Beacon's UI frame and all its child widgets. Caller owns the returned frame.
local function create()
  local db = MDT_NPT:GetDB()

  -- === Beacon Frame ===
  local beaconFrame = CreateFrame("Frame", "MDTNextPullBeaconFrame", UIParent)
  beaconFrame:SetSize(FRAME_BASE_W, FRAME_BASE_H)
  beaconFrame:SetFrameStrata("MEDIUM")
  beaconFrame:SetClampedToScreen(true)
  beaconFrame:SetMovable(true)
  beaconFrame:EnableMouse(true)
  beaconFrame:RegisterForDrag("LeftButton")

  local anchor = MDT_NPT:GetBeaconState()
  beaconFrame:SetPoint(anchor.anchorFrom, UIParent, anchor.anchorTo, anchor.xoffset, anchor.yoffset)
  beaconFrame:SetScale(anchor.scale)
  beaconFrame:SetAlpha((db and db.beacon and db.beacon.alpha) or 1.0)

  local background = beaconFrame:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints()
  background:SetColorTexture(unpack(MDT.BackdropColor or Theme.colors.panelBg))
  beaconFrame._bgTexture = background

  -- Frame border: 4×1px edges via Theme helper.
  beaconFrame._borderTextures = Theme.CreateBorder(beaconFrame)

  --- Re-apply panel background and border colours from the current Theme.
  --- Called by Theme.Refresh() via the registered callback so EUI colour
  --- changes propagate without a /reload.
  function beaconFrame:RefreshChrome()
    local bgC = Theme.colors.panelBg
    if self._bgTexture then
      self._bgTexture:SetColorTexture(bgC[1], bgC[2], bgC[3], bgC[4])
    end
    Theme.UpdateBorder(self._borderTextures)
  end

  -- Register so Theme.Refresh() automatically re-skins this frame.
  Theme.RegisterRefreshCallback(function()
    if beaconFrame and beaconFrame.RefreshChrome then
      beaconFrame:RefreshChrome()
    end
  end)

  -- === MINIMAP ===
  -- Viewport (fixed size, clips the scrollable container so only a SIZE x SIZE window is visible)
  beaconFrame.minimapFrame = CreateFrame("Frame", nil, beaconFrame)
  beaconFrame.minimapFrame:SetSize(Minimap.SIZE, Minimap.SIZE)
  beaconFrame.minimapFrame:SetPoint("TOPLEFT", beaconFrame, "TOPLEFT", 8, -8)
  beaconFrame.minimapFrame:SetClipsChildren(true)
  beaconFrame.minimapFrame:EnableMouseWheel(true)
  beaconFrame.minimapFrame:SetScript("OnMouseWheel", function(_, delta)
    Minimap.adjustUserZoom(beaconFrame, delta)
    Beacon:Update()
  end)

  -- Dark background so the viewport is visible even before tiles load
  local minimapBackground = beaconFrame.minimapFrame:CreateTexture(nil, "BACKGROUND")
  minimapBackground:SetAllPoints()
  minimapBackground:SetColorTexture(unpack(Theme.colors.minimapBg))

  -- Scrollable container holding all 15x10 tiles; panned by centerOnPull.
  -- Size and tile positioning are set dynamically each render by BeaconMinimap.applyZoom.
  beaconFrame.minimapContainer = CreateFrame("Frame", nil, beaconFrame.minimapFrame)
  beaconFrame.minimapContainer:SetSize(Minimap.GRID_COLS * Minimap.DEFAULT_TILE_SIZE, Minimap.GRID_ROWS * Minimap.DEFAULT_TILE_SIZE)
  beaconFrame.minimapContainer:SetPoint("TOPLEFT", beaconFrame.minimapFrame, "TOPLEFT", 0, 0)

  -- Create the 150 mini tile textures (sizes/positions set by applyZoom on first render)
  beaconFrame.minimapTiles = {}
  for i = 1, Minimap.GRID_ROWS do
    for j = 1, Minimap.GRID_COLS do
      local tileIndex = (i - 1) * Minimap.GRID_COLS + j
      local tile = beaconFrame.minimapContainer:CreateTexture(nil, "ARTWORK")
      tile:SetSize(Minimap.DEFAULT_TILE_SIZE, Minimap.DEFAULT_TILE_SIZE)
      tile:SetPoint(
        "TOPLEFT",
        beaconFrame.minimapContainer,
        "TOPLEFT",
        (j - 1) * Minimap.DEFAULT_TILE_SIZE,
        -(i - 1) * Minimap.DEFAULT_TILE_SIZE
      )
      tile:Hide()
      beaconFrame.minimapTiles[tileIndex] = tile
    end
  end

  -- This table will contain enemy positions
  beaconFrame.dots = {}

  -- Minimap border overlay
  local minimapBorder = beaconFrame.minimapFrame:CreateTexture(nil, "OVERLAY")
  minimapBorder:SetAllPoints()
  minimapBorder:SetColorTexture(Theme.colors.accent[1], Theme.colors.accent[2], Theme.colors.accent[3], 0.5)
  -- Hollow rectangle effect using 4 thin textures is nicer but simpler to skip
  -- We'll just use a thin colored overlay that wraps - actually let's just do a thin border
  minimapBorder:Hide()

  Theme.CreateBorder(beaconFrame.minimapFrame)

  -- Zoom buttons (bottom-right corner of minimap)
  local function createZoomButton(label, offsetY, delta)
    local btn = CreateFrame("Button", nil, beaconFrame.minimapFrame)
    btn:SetSize(16, 16)
    btn:SetPoint("BOTTOMRIGHT", beaconFrame.minimapFrame, "BOTTOMRIGHT", -2, offsetY)

    local text = Theme.StyleButton(btn, label, Theme.fonts.large)
    btn:SetScript("OnClick", function()
      Minimap.adjustUserZoom(beaconFrame, delta)
      Beacon:Update()
    end)
    return btn
  end

  createZoomButton("+", 20, 1)
  createZoomButton("-", 2, -1)

  -- === Information panel (right side of the beacon) ===
  local infoPanelX = Minimap.SIZE + 16
  local infoPanelWidth = FRAME_BASE_W - infoPanelX - 10

  -- Pull number badge
  local infoPanelPullBadge = beaconFrame:CreateFontString(nil, "OVERLAY", Theme.fonts.large)
  infoPanelPullBadge:SetPoint("TOPLEFT", beaconFrame, "TOPLEFT", infoPanelX, -10)
  infoPanelPullBadge:SetTextColor(unpack(Theme.colors.accent))
  beaconFrame.pullBadge = infoPanelPullBadge

  -- Status text (NEXT / IN COMBAT / ROUTE COMPLETE...)
  local infoPanelStatusText = beaconFrame:CreateFontString(nil, "OVERLAY", Theme.fonts.small)
  infoPanelStatusText:SetPoint("TOPRIGHT", beaconFrame, "TOPRIGHT", -10, -10)
  infoPanelStatusText:SetTextColor(unpack(Theme.colors.textSecondary))
  beaconFrame.statusText = infoPanelStatusText

  -- Mob count + forces next info text
  local mobAndForceInfoText = beaconFrame:CreateFontString(nil, "OVERLAY", Theme.fonts.small)
  mobAndForceInfoText:SetPoint("TOPLEFT", infoPanelPullBadge, "BOTTOMLEFT", 0, -2)
  mobAndForceInfoText:SetTextColor(unpack(Theme.colors.textPrimary))
  beaconFrame.infoText = mobAndForceInfoText

  -- Enemies portraits (up to 8, laid out by renderEnemiesPortraits per pull).
  -- ≤4 mobs → single row at 34x34; >4 mobs → 2x4 grid at 28x28.
  beaconFrame.portraits = {}
  beaconFrame.portraitOutlines = {}
  beaconFrame.portraitHovers = {}
  beaconFrame.portraitInfoPanelX = infoPanelX -- stored so the render fn can re-anchor
  for i = 1, 8 do
    local portrait = beaconFrame:CreateTexture(nil, "ARTWORK")
    portrait:SetMask("Interface\\Masks\\CircleMaskScalable") -- circular mask
    portrait:Hide()
    beaconFrame.portraits[i] = portrait

    -- Thin white ring: filled circle 2px larger than the portrait; the portrait's
    -- circular mask leaves a ~1px ring of white visible around it.
    local outline = beaconFrame:CreateTexture(nil, "BORDER")
    outline:SetTexture("Interface\\AddOns\\MythicDungeonTools\\Textures\\Circle_White")
    outline:SetVertexColor(unpack(Theme.colors.textPrimary))
    outline:SetPoint("CENTER", portrait, "CENTER", 0, 0)
    outline:Hide()
    beaconFrame.portraitOutlines[i] = outline

    -- Transparent hover region matching the portrait, used to display the mob
    -- name on tooltip. Textures don't receive mouse input, so we overlay a frame.
    local hover = CreateFrame("Frame", nil, beaconFrame)
    hover:SetAllPoints(portrait)
    hover:EnableMouse(true)
    hover:Hide()
    hover:SetScript("OnEnter", function(self)
      if not self.mobName then return end
      GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
      GameTooltip:SetText(self.mobName, 1, 1, 1)
      GameTooltip:Show()
    end)
    hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    beaconFrame.portraitHovers[i] = hover
  end

  -- Progress bar (for active pull)
  local progressBar = CreateFrame("StatusBar", nil, beaconFrame)
  progressBar:SetSize(infoPanelWidth, 8)
  progressBar:SetPoint("BOTTOMLEFT", beaconFrame, "BOTTOMLEFT", infoPanelX, 8)
  progressBar:SetStatusBarTexture(Theme.textures.statusBar)
  progressBar:SetStatusBarColor(unpack(Theme.colors.accentBar))
  progressBar:SetMinMaxValues(0, 1)
  progressBar:SetValue(0)
  beaconFrame.progressBarWidth = infoPanelWidth
  beaconFrame.progressBar = progressBar

  -- Preview overlay (showing what this pull will add)
  local previewOverlay = progressBar:CreateTexture(nil, "OVERLAY")
  previewOverlay:SetColorTexture(unpack(Theme.colors.progressPreview))
  previewOverlay:SetHeight(8)
  previewOverlay:Hide()
  beaconFrame.previewOverlay = previewOverlay

  local progressBarBackground = progressBar:CreateTexture(nil, "BACKGROUND")
  progressBarBackground:SetAllPoints()
  progressBarBackground:SetColorTexture(unpack(Theme.colors.progressBg))

  -- Upcoming preview (next+1 pull)
  local upcomingText = beaconFrame:CreateFontString(nil, "OVERLAY", Theme.fonts.small)
  upcomingText:SetPoint("BOTTOMLEFT", progressBar, "TOPLEFT", 0, 4)
  upcomingText:SetTextColor(unpack(Theme.colors.textMuted))
  upcomingText:SetScale(0.85)
  beaconFrame.upcomingText = upcomingText

  -- Cooldown plan icon rows (design 10.1/16.2): current-pull row (24px) + next-pull
  -- preview row (16px). Fixed y (-144, matches COOLDOWN_ROW_Y) so the portrait area
  -- never jitters; the extra -16 gap leaves room for the 开/留 labels under the icons.
  local cooldownIconsRow = CreateFrame("Frame", nil, beaconFrame)
  cooldownIconsRow:SetPoint("TOPLEFT", beaconFrame, "TOPLEFT", infoPanelX, -144)
  cooldownIconsRow:SetSize(infoPanelWidth, 24)
  beaconFrame.cooldownIconsRow = cooldownIconsRow
  local upcomingIconsRow = CreateFrame("Frame", nil, beaconFrame)
  upcomingIconsRow:SetPoint("TOPLEFT", cooldownIconsRow, "BOTTOMLEFT", 0, -16)
  upcomingIconsRow:SetSize(infoPanelWidth, 16)
  beaconFrame.upcomingIconsRow = upcomingIconsRow

  -- === Beacon Actions ===
  beaconFrame:SetScript("OnDragStart", function(self)
    if not MDT_NPT:GetBeaconState().locked then
      self:StartMoving()
    end
  end)

  beaconFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint()
    local state = MDT_NPT:GetBeaconState()
    state.anchorFrom = point
    state.anchorTo = relativePoint
    state.xoffset = x
    state.yoffset = y
  end)

  beaconFrame:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
      MenuUtil.CreateContextMenu(self, function(_, rootDescription)
        rootDescription:CreateTitle(L["Next Pull Beacon"])
        rootDescription:CreateCheckbox(L["Locked"],
          function() return MDT_NPT:GetBeaconState().locked end,
          function()
            local state = MDT_NPT:GetBeaconState()
            state.locked = not state.locked
          end)
        rootDescription:CreateCheckbox(L["Show Upcoming"], function() return db.beacon.showUpcoming end, function()
          db.beacon.showUpcoming = not db.beacon.showUpcoming
          Beacon:Update()
        end)
        rootDescription:CreateCheckbox(L["Map Only"], function() return db.beacon.mapOnly end, function()
          db.beacon.mapOnly = not db.beacon.mapOnly
          Beacon:Update()
        end)
        rootDescription:CreateSpacer()
        rootDescription:CreateCheckbox(L["Show Cooldown Plan"],
          function() return db.beacon.showCooldownPlan end,
          function()
            db.beacon.showCooldownPlan = not db.beacon.showCooldownPlan
            Beacon:Update()
          end)
        rootDescription:CreateButton(L["Edit Cooldown Plan"], function()
          if not InCombatLockdown() and MDT_NPT.CooldownPlanEditor then
            MDT_NPT.CooldownPlanEditor:Open()
          end
        end)
        rootDescription:CreateButton(L["Open Settings"], function()
          if MDT_NPT.Settings and MDT_NPT.Settings.Open then
            MDT_NPT.Settings:Open()
          end
        end)
        rootDescription:CreateButton(L["Reset Position & Size"], function()
          if MDT_NPT.Beacon and MDT_NPT.Beacon.ResetPosition then
            MDT_NPT.Beacon:ResetPosition()
            MDT_NPT.Beacon:Update()
          end
        end)
        rootDescription:CreateButton(L["Hide Beacon"], function()
          db.beacon.enabled = false
          beaconFrame:Hide()
        end)
        rootDescription:CreateButton(L["Stop Tracking"], function()
          MDT_NPT:Stop()
        end)
      end)
    end
  end)

  -- Manual pull buttons
  local function createControlButton(parent, texture, offsetX, tooltip, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(16, 16)
    btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", offsetX, -4)
    btn:SetNormalTexture(texture)
    btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    btn:SetAlpha(0)
    btn:SetScript("OnClick", onClick)
    btn:SetScript("OnEnter", function(self)
      self:SetAlpha(1)
      GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
      GameTooltip:SetText(tooltip, 1, 1, 1)
      GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
      self:SetAlpha(0)
      GameTooltip:Hide()
    end)
    return btn
  end

  beaconFrame.completeBtn = createControlButton(
    beaconFrame,
    "Interface\\RAIDFRAME\\ReadyCheck-Ready",
    -4,
    L["Mark Complete"],
    function()
      local state = MDT_NPT.state
      if state and state.active then
        for i, pullState in ipairs(state.pullStates) do
          if pullState.state == PullState.ACTIVE or pullState.state == PullState.NEXT then
            MDT_NPT:MarkComplete(i)
            return
          end
        end
      end
    end
  )

  beaconFrame.skipBtn = createControlButton(
    beaconFrame,
    "Interface\\MINIMAP\\MiniMap-VignetteArrow",
    -22,
    L["Skip Pull"],
    function()
      local state = MDT_NPT.state
      if state and state.active and state.currentNextPull then
        local nextIdx = state.currentNextPull + 1
        if nextIdx <= #state.pullStates then
          MDT_NPT:SkipTo(nextIdx)
        end
      end
    end
  )

  beaconFrame.revertBtn = createControlButton(
    beaconFrame,
    "Interface\\BUTTONS\\UI-RefreshButton",
    -40,
    L["Revert Pull"],
    function()
      local state = MDT_NPT.state
      if state and state.active and state.currentNextPull then
        local prevIdx = state.currentNextPull - 1
        if prevIdx >= 1 then
          MDT_NPT:MarkIncomplete(prevIdx)
        end
      end
    end
  )

  beaconFrame.resizeGrip = createResizeGrip(beaconFrame)

  beaconFrame:SetScript("OnEnter", function(self)
    self.completeBtn:SetAlpha(0.7)
    self.skipBtn:SetAlpha(0.7)
    self.revertBtn:SetAlpha(0.7)
    self.resizeGrip:SetAlpha(0.7)
  end)

  beaconFrame:SetScript("OnLeave", function(self)
    if not isMouseOver(self) then
      self.completeBtn:SetAlpha(0)
      self.skipBtn:SetAlpha(0)
      self.revertBtn:SetAlpha(0)
      self.resizeGrip:SetAlpha(0)
    end
  end)

  beaconFrame:Hide()
  return beaconFrame
end

local function renderRouteComplete(frame, state, totalForcesMax)
  local totalKilled = 0
  for _, ps in ipairs(state.pullStates) do
    totalKilled = totalKilled + ps.totalForces
  end

  local overUnder = totalKilled - totalForcesMax
  local pctText = string_format("%.1f%%", (overUnder / totalForcesMax) * 100)

  frame.pullBadge:SetText(L["Done"])
  frame.statusText:SetText(L["Route Complete"])
  frame.infoText:SetText((overUnder >= 0 and "+" or "")..pctText.." "..L["forces"])
  frame.progressBar:SetValue(1)
  frame.previewOverlay:Hide()
  frame.upcomingText:SetText("")

  for i = 1, #frame.portraits do
    frame.portraits[i]:Hide()
    frame.portraitOutlines[i]:Hide()
    if frame.portraitHovers and frame.portraitHovers[i] then
      frame.portraitHovers[i]:Hide()
    end
  end
  for _, dot in ipairs(frame.dots) do dot:Hide() end
  Minimap.drawCurrentPullOutline(frame, nil)
end

local function renderPullHeader(frame, nextPull, pullState, totalPulls)
  frame.pullBadge:SetText(L["Pull"].." "..nextPull.." / "..totalPulls)

  if pullState.state == PullState.ACTIVE then
    frame.statusText:SetText(L["In Combat"])
    local sc = Theme.colors.statusCombat
    frame.statusText:SetTextColor(sc[1], sc[2], sc[3], sc[4])
  else
    frame.statusText:SetText(L["Next"])
    local sn = Theme.colors.accent
    frame.statusText:SetTextColor(sn[1], sn[2], sn[3], sn[4])
  end
end

local function renderPercentageInfoText(frame, totalCount, basePercentageForText, pullPercentage, targetPercentage)
  local currentStr = string.format("|cFF00BFFF%.1f%%|r", basePercentageForText)
  local pullStr = string.format("|cFFFFD700+%.1f%%|r", pullPercentage)
  local targetStr = string.format("|cFF00FF7F%.1f%%|r", targetPercentage)
  frame.infoText:SetText(totalCount.." "..L["mobs"].."  "..
    currentStr.." "..pullStr.." / "..targetStr)
end

local function updateProgressBar(frame, currentPct)
  local basePercentage = currentPct or 0
  frame.progressBar:SetValue(basePercentage / 100)
  local pc = Theme.colors.progressCurrent
  frame.progressBar:SetStatusBarColor(pc[1], pc[2], pc[3], pc[4])
end


local function renderCurrentPullContribution(frame, basePercentage, pullPercentage)
  local barWidth = frame.progressBarWidth or 180
  local startPercentage = math.min(basePercentage, 100)
  local endPercentage = math.min(basePercentage + pullPercentage, 100)
  local overlayWidth = (endPercentage - startPercentage) / 100 * barWidth

  if overlayWidth > 0.5 then
    frame.previewOverlay:ClearAllPoints()
    frame.previewOverlay:SetPoint(
      "LEFT",
      frame.progressBar,
      "LEFT",
      (startPercentage / 100) * barWidth,
      0
    )
    frame.previewOverlay:SetSize(overlayWidth, 8)
    frame.previewOverlay:Show()
  else
    frame.previewOverlay:Hide()
  end
end

local PORTRAIT_MAX = 8
local PORTRAIT_TOP_Y = -56
local PORTRAIT_PER_ROW = 4
local PORTRAIT_ROW_GAP = 4
local PORTRAIT_LABEL_H = 12        -- vertical band reserved for the short-name label under each portrait
local PORTRAIT_LABEL_MAX_CHARS = 5 -- CJK chars that fit a portrait column at the 6px label font
local COOLDOWN_ROW_Y = -144        -- cooldown icon row top: below the always-reserved 2x4 portrait grid + labels

---Frame height is constant (the portrait area always reserves the 2x4 grid), except
---in map-only mode where the info panel is hidden entirely.
local function syncFrameHeight(frame)
  local db = MDT_NPT:GetDB()
  local mapOnly = (db and db.beacon and db.beacon.mapOnly) or false
  local MAP_ONLY_H = Minimap.SIZE + 16
  frame:SetHeight(mapOnly and MAP_ONLY_H or FRAME_BASE_H)
end

---UTF-8 aware char split, then keep the tail (the head noun sits at the end of a
---Chinese compound) so an over-long short name never overlaps its neighbours.
local function fitLabel(s, maxChars)
  local chars = {}
  for c in s:gmatch("[\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = c end
  if #chars <= maxChars then return s end
  local out = ""
  for i = #chars - maxChars + 1, #chars do out = out .. chars[i] end
  return out
end

---Anchors the i-th portrait slot for a pull with `count` visible portraits.
---≤4 → one row at 34x34; >4 → 2x4 grid at 28x28 so the extra mobs fit without
---pushing into the progress bar below.
local function layoutPortraitSlot(frame, i, count)
  local twoRow = count > PORTRAIT_PER_ROW
  local size = twoRow and 28 or 34
  -- Spread the 4 columns to exactly fill the info panel width (same right edge as
  -- the progress bar), so there is no dead space to the right of the portraits.
  local panelW = frame.progressBarWidth or 184
  local colGap = math.floor((panelW - PORTRAIT_PER_ROW * size) / (PORTRAIT_PER_ROW - 1))

  local portrait = frame.portraits[i]
  local outline = frame.portraitOutlines[i]
  portrait:SetSize(size, size)
  outline:SetSize(size + 2, size + 2)

  local row = math.floor((i - 1) / PORTRAIT_PER_ROW)
  local col = (i - 1) % PORTRAIT_PER_ROW
  local x = frame.portraitInfoPanelX + col * (size + colGap)
  local y = PORTRAIT_TOP_Y - row * (size + PORTRAIT_ROW_GAP + PORTRAIT_LABEL_H)

  portrait:ClearAllPoints()
  portrait:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
end

local function renderEnemiesPortraits(frame, pull, enemies)
  local enemyIndices = {}
  if pull and enemies then
    for enemyIndex in pairs(pull) do
      if tonumber(enemyIndex) and enemies[enemyIndex] and #enemyIndices < PORTRAIT_MAX then
        enemyIndices[#enemyIndices + 1] = enemyIndex
      end
    end
  end

  local count = #enemyIndices
  -- The portrait area always reserves the 2x4 grid height, so the cooldown rows sit
  -- at a fixed y and the frame height never changes between pulls.
  frame.cooldownIconsRow:ClearAllPoints()
  frame.cooldownIconsRow:SetPoint("TOPLEFT", frame, "TOPLEFT", frame.portraitInfoPanelX, COOLDOWN_ROW_Y)
  syncFrameHeight(frame)
  for i = 1, count do
    layoutPortraitSlot(frame, i, count)
    local enemy = enemies[enemyIndices[i]]
    local displayId = enemy.displayId or 39490
    SetPortraitTextureFromCreatureDisplayID(frame.portraits[i], displayId)
    frame.portraits[i]:Show()
    frame.portraitOutlines[i]:Show()
    -- short Chinese name under the portrait
    local rawName = enemy.name
    local zh = (MDT_NPT.NPC_ZH and MDT_NPT.NPC_ZH[rawName]) or (getMDTLocale() and getMDTLocale()[rawName]) or (MDT.L and MDT.L[rawName])
    local nm = frame.portraitNames and frame.portraitNames[i]
    if not nm then
      nm = frame:CreateFontString(nil, "OVERLAY", Theme.fonts.npcName)
      nm:SetShadowColor(unpack(Theme.colors.shadow))
      nm:SetShadowOffset(1, -1)
      frame.portraitNames = frame.portraitNames or {}
      frame.portraitNames[i] = nm
    end
    nm:ClearAllPoints()
    nm:SetPoint("TOP", frame.portraits[i], "BOTTOM", 0, 0)
    nm:SetText(fitLabel(shortEnemyName(zh) or "", PORTRAIT_LABEL_MAX_CHARS))
    local mc = MOB_COLORS[staticMobType(enemy)] or MOB_COLORS.other
    nm:SetTextColor(mc[1], mc[2], mc[3], 1)
    -- Tint the white circle ring around the portrait with the same mob-type color.
    frame.portraitOutlines[i]:SetVertexColor(mc[1], mc[2], mc[3], 1)
    nm:Show()
    if frame.portraitHovers and frame.portraitHovers[i] then
      frame.portraitHovers[i].mobName = rawName and (zh or rawName) or nil
      frame.portraitHovers[i]:Show()
    end
  end
  for i = count + 1, PORTRAIT_MAX do
    frame.portraits[i]:Hide()
    frame.portraitOutlines[i]:Hide()
    if frame.portraitNames and frame.portraitNames[i] then frame.portraitNames[i]:Hide() end
    if frame.portraitHovers and frame.portraitHovers[i] then
      frame.portraitHovers[i].mobName = nil
      frame.portraitHovers[i]:Hide()
    end
  end
end

local function renderUpcomingPreview(frame, pullStates, nextPull, showUpcoming, totalForcesMax)
  if showUpcoming and nextPull + 1 <= #pullStates then
    local upcomingPullState = pullStates[nextPull + 1]
    if upcomingPullState and upcomingPullState.state ~= PullState.COMPLETED then
      local upcomingForcePercentage = string.format(
        "%.1f%%",
        (upcomingPullState.totalForces / totalForcesMax) * 100
      )
      frame.upcomingText:SetText(L["Then"]..
        ": "..L["Pull"].." "..(nextPull + 1).." - "..upcomingPullState.totalCount.." "..L["mobs"].." - "..upcomingForcePercentage)
      frame.upcomingText:Show()
    else
      frame.upcomingText:Hide()
    end
  else
    frame.upcomingText:Hide()
  end
end

local MAP_ONLY_W = Minimap.SIZE + 16 -- minimap plus its 8px margins on each side

---Switches the beacon between the full layout (minimap + info panel) and a
---compact map-only layout that hides the info panel and shrinks the frame down
---to just the minimap. Driven by `db.beacon.mapOnly`; called on every Show, so
---it runs after the per-pull render has set widget visibility.
local function applyLayoutMode(frame)
  local db = MDT_NPT:GetDB()
  local mapOnly = (db and db.beacon and db.beacon.mapOnly) or false

  for _, widget in ipairs({ frame.pullBadge, frame.statusText, frame.infoText, frame.progressBar,
                            frame.cooldownIconsRow, frame.upcomingIconsRow }) do
    if widget then widget:SetShown(not mapOnly) end
  end

  -- upcomingText: hidden in mapOnly, OR when the cooldown-plan rows are visible
  -- (the next-pull icon row functionally replaces it; design 10.2). This is the second
  -- intentional modification to NPT's own visibility logic.
  if frame.upcomingText then
    local cooldownPlanActive = (db and db.beacon and db.beacon.showCooldownPlan) and frame.cooldownIconsRow
    frame.upcomingText:SetShown(not mapOnly and not cooldownPlanActive)
  end

  -- Portraits are normally shown/hidden by the per-pull render; in map-only we
  -- force them all hidden (the render runs before this on the way back to full).
  if mapOnly then
    for i = 1, #frame.portraits do
      frame.portraits[i]:Hide()
      frame.portraitOutlines[i]:Hide()
      if frame.portraitNames and frame.portraitNames[i] then frame.portraitNames[i]:Hide() end
      if frame.portraitHovers[i] then frame.portraitHovers[i]:Hide() end
    end
  end

  frame:SetWidth(mapOnly and MAP_ONLY_W or FRAME_BASE_W)
  syncFrameHeight(frame)
end

MDT_NPT.BeaconFrame = {
  create = create,
  isMouseOver = isMouseOver,
  applyLayoutMode = applyLayoutMode,
  renderRouteComplete = renderRouteComplete,
  renderPullHeader = renderPullHeader,
  renderPercentageInfoText = renderPercentageInfoText,
  updateProgressBar = updateProgressBar,
  renderCurrentPullContribution = renderCurrentPullContribution,
  renderEnemiesPortraits = renderEnemiesPortraits,
  renderUpcomingPreview = renderUpcomingPreview,
}
