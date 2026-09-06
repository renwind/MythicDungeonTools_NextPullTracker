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

local FRAME_BASE_W, FRAME_BASE_H = 418, 216  -- wider minimap viewport (208) + 188 info panel;
  -- height = minimap 208 + 4px margins so the map fills the left column exactly
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

---Selects a pull in MDT's right-side pull list. Calls the pull button widget's own
---OnClickNormal callback with force=true (the widget ignores simulated clicks unless
---the cursor hovers its scroll frame). True on success; needs the MDT UI initialized.
local function trySelectMDTPull(pullIndex)
  local top = _G.MDTTopPanel
  local mainFrame = top and top:GetParent()
  -- pull buttons live on the side panel (ReloadPullButtons uses main_frame.sidePanel)
  local side = mainFrame and mainFrame.sidePanel
  local pool = (side and side.newPullButtons) or (mainFrame and mainFrame.newPullButtons)
  local btn = pool and pool[pullIndex]
  if not btn then return false end
  if btn.callbacks and btn.callbacks.OnClickNormal then
    btn.callbacks.OnClickNormal(nil, "LeftButton", true)
    return true
  end
  if btn.frame and btn.frame.Click then
    btn.frame:Click()
    return true
  end
  return false
end

---Opens ExwindTools' dungeon spell encyclopedia (EXSP) and locates the mob whose
---npcID matches. Mirrors the addon's own /exsp slash flow (create -> show -> tab),
---then selects the mob through its public globals. True on success.
local function tryOpenExwindSpellInfo(npcID)
  local EXSP = _G.EXSP
  if not npcID or not EXSP or not EXSP.Database then return false end
  local dName, mName
  for d, mobs in pairs(EXSP.Database) do
    for name, data in pairs(mobs) do
      if type(data) == "table" and data.npcID == npcID then
        dName, mName = d, name
        break
      end
    end
    if dName then break end
  end
  if not dName then return false end
  if not EXSP.MainFrame and EXSP.CreateMainFrame then EXSP.CreateMainFrame() end
  if not EXSP.MainFrame then return false end
  EXSP.MainFrame:Show()
  if not EXSP.CurrentDungeon and EXSP.Tabs and EXSP.Tabs[1] then EXSP.Tabs[1]:Click() end
  if EXSP.CurrentDungeon ~= dName and EXSP.Tabs and EXSP.DungeonList then
    for i, name in ipairs(EXSP.DungeonList) do
      if name == dName and EXSP.Tabs[i] then
        EXSP.Tabs[i]:Click()
        break
      end
    end
  end
  EXSP.CurrentMob = mName
  if _G.EXSP_RefreshRightPanel then _G.EXSP_RefreshRightPanel(dName, mName) end
  if _G.EXSP_RefreshMobList then _G.EXSP_RefreshMobList(dName) end
  return true
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
  -- revert of the half-opacity experiment: frame alpha stays full (content must
  -- not fade); the panel translucency lives on the background texture instead
  if db and db.beacon and db.beacon.alphaHalfApplied then
    db.beacon.alpha = 1.0
    db.beacon.alphaHalfApplied = nil
  end
  beaconFrame:SetAlpha((db and db.beacon and db.beacon.alpha) or 1.0)

  local background = beaconFrame:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints()
  -- EUI's default-theme blue-green panel art when EUI is present; flat colour else.
  -- Half-alpha background = translucent panel while map/text/icons stay crisp.
  beaconFrame.usesEuiBg = C_AddOns.IsAddOnLoaded("EllesmereUI")
  if beaconFrame.usesEuiBg then
    background:SetTexture("Interface\\AddOns\\EllesmereUI\\backgrounds\\eui-bg-all-compressed.png")
    background:SetTexCoord(0, 1, 0, 1)
  else
    background:SetColorTexture(unpack(MDT.BackdropColor or Theme.colors.panelBg))
  end
  background:SetAlpha(0.75)  -- translucent panel; content stays fully opaque
  beaconFrame._bgTexture = background

  -- Frame border: 4×1px edges via Theme helper.
  beaconFrame._borderTextures = Theme.CreateBorder(beaconFrame)

  --- Re-apply panel background and border colours from the current Theme.
  --- Called by Theme.Refresh() via the registered callback so EUI colour
  --- changes propagate without a /reload.
  function beaconFrame:RefreshChrome()
    local bgC = Theme.colors.panelBg
    if self._bgTexture and not self.usesEuiBg then
      self._bgTexture:SetColorTexture(bgC[1], bgC[2], bgC[3], bgC[4])
    end
    if self.cdBandBg then
      local bandC = Theme.colors.accent
      self.cdBandBg:SetColorTexture(bandC[1], bandC[2], bandC[3], 0.28)
    end
    Theme.UpdateBorder(self.cdBandBorder)
    if self.mapBorder then
      local mc = Theme.colors.accent
      for _, t in ipairs(self.mapBorder) do t:SetColorTexture(mc[1], mc[2], mc[3], 1) end
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
  beaconFrame.minimapFrame:SetPoint("TOPLEFT", beaconFrame, "TOPLEFT", 4, -4)
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

  -- (the old white Theme.CreateBorder edge was removed: stacked with the
  -- accent border below it read as a 2px rim)

  -- EUI minimap-style border: thin 1px solid strip in the EUI theme teal
  -- (accent); same construction as EUI's square minimap border, just slimmer
  local bs = 1
  local mapBorder = {}
  do
    local mf = beaconFrame.minimapFrame
    local mc = Theme.colors.accent
    local function edge(p1, p2, horiz, o1x, o1y, o2x, o2y)
      local t = beaconFrame:CreateTexture(nil, "OVERLAY", nil, 5)
      t:SetColorTexture(mc[1], mc[2], mc[3], 1)
      t:SetPoint(p1, mf, p1, o1x, o1y)
      t:SetPoint(p2, mf, p2, o2x, o2y)
      if horiz then t:SetHeight(bs) else t:SetWidth(bs) end
      mapBorder[#mapBorder + 1] = t
    end
    edge("TOPLEFT", "TOPRIGHT", true, -bs, bs, bs, bs)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", true, -bs, -bs, bs, -bs)
    edge("TOPLEFT", "BOTTOMLEFT", false, -bs, 0, -bs, 0)
    edge("TOPRIGHT", "BOTTOMRIGHT", false, bs, 0, bs, 0)
  end
  beaconFrame.mapBorder = mapBorder

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
  local infoPanelX = Minimap.SIZE + 12
  local infoPanelWidth = FRAME_BASE_W - infoPanelX - 10

  -- Pull number badge
  local infoPanelPullBadge = beaconFrame:CreateFontString(nil, "OVERLAY", Theme.fonts.large)
  infoPanelPullBadge:SetPoint("TOPLEFT", beaconFrame, "TOPLEFT", infoPanelX, -10)
  infoPanelPullBadge:SetTextColor(unpack(Theme.colors.accent))
  beaconFrame.pullBadge = infoPanelPullBadge

  -- Status text (NEXT / IN COMBAT / ROUTE COMPLETE...): top-flush with the badge
  -- top edge; right edge clears the 4-button control row
  local infoPanelStatusText = beaconFrame:CreateFontString(nil, "OVERLAY", Theme.fonts.small)
  infoPanelStatusText:SetPoint("TOPRIGHT", beaconFrame, "TOPRIGHT", -72, -10)  -- clear of the 4-button control row
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
    -- left-click: open MDT and select the beacon's current pull; right-click: Exwind
    -- spell encyclopedia located on this mob. MDT 6.2 keeps its addon table private,
    -- so both paths go through the public API plus widget-level simulation.
    hover:SetScript("OnMouseDown", function(self, button)
      if button == "RightButton" then
        -- right-click: Exwind dungeon spell encyclopedia, located on this mob
        if self.npcID then tryOpenExwindSpellInfo(self.npcID) end
        return
      end
      if button ~= "LeftButton" then return end
      -- left-click: open MDT (never toggle-close) and select the beacon's current pull
      GameTooltip:Hide()
      local pullIndex = MDT_NPT.state and MDT_NPT.state.currentNextPull
      local selected = (pullIndex and trySelectMDTPull(pullIndex)) or false
      local top = _G.MDTTopPanel
      local mainFrame = top and top:GetParent()
      if not (mainFrame and mainFrame:IsShown()) then
        local api = _G.MythicDungeonToolsAPI
        if api and api.ShowInterface then api:ShowInterface() end
        if pullIndex and not selected then
          C_Timer.After(0.8, function() trySelectMDTPull(pullIndex) end)
        end
      end
    end)
    beaconFrame.portraitHovers[i] = hover
  end

  -- Progress bar (for active pull): sits between the info text and the portraits
  local progressBar = CreateFrame("StatusBar", nil, beaconFrame)
  progressBar:SetSize(infoPanelWidth, 8)
  progressBar:SetPoint("TOPLEFT", beaconFrame, "TOPLEFT", infoPanelX, -44)
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

  -- Upcoming preview (next+1 pull): reserved slot under the bar (hidden while the
  -- cooldown-plan rows are on, so the slot reads as plain spacing then)
  local upcomingText = beaconFrame:CreateFontString(nil, "OVERLAY", Theme.fonts.small)
  upcomingText:SetPoint("TOPLEFT", progressBar, "BOTTOMLEFT", 0, -2)
  upcomingText:SetTextColor(unpack(Theme.colors.textMuted))
  upcomingText:SetScale(0.85)
  beaconFrame.upcomingText = upcomingText

  -- Cooldown plan icon rows (design 10.1/16.2): current-pull row (24px) + next-pull
  -- preview row (16px). Fixed y (-152, matches COOLDOWN_ROW_Y) so the portrait area
  -- never jitters; the extra -16 gap leaves room for the 开/留 labels under the icons.
  local cooldownIconsRow = CreateFrame("Frame", nil, beaconFrame)
  cooldownIconsRow:SetPoint("TOPLEFT", beaconFrame, "TOPLEFT", infoPanelX, -152)
  cooldownIconsRow:SetSize(infoPanelWidth, 24)
  beaconFrame.cooldownIconsRow = cooldownIconsRow
  local upcomingIconsRow = CreateFrame("Frame", nil, beaconFrame)
  upcomingIconsRow:SetPoint("TOPLEFT", cooldownIconsRow, "BOTTOMLEFT", 0, -12)  -- tightened under the CD text band
  upcomingIconsRow:SetSize(infoPanelWidth, 16)
  beaconFrame.upcomingIconsRow = upcomingIconsRow

  -- Light-blue band behind the cooldown plan cluster (both icon rows); padded
  -- 4px past the outer icon edges so it reads as a panel, not a tight crop
  local cdBandBg = beaconFrame:CreateTexture(nil, "BACKGROUND", nil, 1)
  cdBandBg:SetPoint("TOPLEFT", cooldownIconsRow, "TOPLEFT", -4, 4)
  -- bottom flush with the map's bottom edge (-212): next-row bottom -204 minus 8
  cdBandBg:SetPoint("BOTTOMRIGHT", upcomingIconsRow, "BOTTOMRIGHT", 4, -8)
  local bandC = Theme.colors.accent  -- EUI theme teal, bridged live
  cdBandBg:SetColorTexture(bandC[1], bandC[2], bandC[3], 0.28)
  beaconFrame.cdBandBg = cdBandBg

  -- Same white 1px border as the beacon window (Theme.panelBorder, BORDER
  -- stratum), keyed like Theme.CreateBorder's return so UpdateBorder works;
  -- parented to the beacon, anchored inside the band's edges
  do
    local c = Theme.colors.panelBorder
    local edges = {}
    local function mk(key, p1, p2, horiz)
      local t = beaconFrame:CreateTexture(nil, "BORDER")
      t:SetColorTexture(c[1], c[2], c[3], c[4])
      t:SetPoint(p1, cdBandBg, p1)
      t:SetPoint(p2, cdBandBg, p2)
      if horiz then t:SetHeight(1) else t:SetWidth(1) end
      edges[key] = t
    end
    mk("top", "TOPLEFT", "TOPRIGHT", true)
    mk("bottom", "BOTTOMLEFT", "BOTTOMRIGHT", true)
    mk("left", "TOPLEFT", "BOTTOMLEFT", false)
    mk("right", "TOPRIGHT", "BOTTOMRIGHT", false)
    beaconFrame.cdBandBorder = edges
  end

  ---Shows/hides the plan-cluster band together with its border.
  function beaconFrame:SetCdBandShown(show)
    if self.cdBandBg then self.cdBandBg:SetShown(show) end
    if self.cdBandBorder then
      for _, key in ipairs({ "top", "bottom", "left", "right" }) do
        local t = self.cdBandBorder[key]
        if t then t:SetShown(show) end
      end
    end
  end

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
  local function createControlButton(parent, texture, offsetX, tooltip, onClick, aspect, glyphSize)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(14, 14)
    btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", offsetX, -10)  -- top-flush with the badge top edge
    btn._offsetX = offsetX  -- remembered for the runtime header alignment pass
    -- a Button auto-fits its normal texture to the button rect, so the glyph is
    -- a plain child texture (smaller than the hit area; ratio kept for tall art)
    local nt = btn:CreateTexture(nil, "ARTWORK")
    nt:SetTexture(texture)
    local gw, gh = glyphSize or 12, glyphSize or 12
    if aspect and aspect < 1 then
      gw = math.floor(gw * aspect + 0.5)
    elseif aspect and aspect > 1 then
      gh = math.floor(gh / aspect + 0.5)
    end
    nt:SetSize(gw, gh)
    nt:SetPoint("TOP", btn, "TOP", 0, -1)  -- glyph tops flush with the badge cap line
    btn._glyphH = gh  -- runtime header alignment centers glyphs of differing sizes
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
    "Interface\\AddOns\\EllesmereUIDamageMeters\\Media\\dm_home_enemytaken.png",
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
    end,
    nil, 15  -- reticle is the primary action; stroke art scales clean
  )

  beaconFrame.skipBtn = createControlButton(
    beaconFrame,
    "Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-arrow-right.png",
    -19,
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
    "Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-arrow-left.png",
    -34,
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

  beaconFrame.planBtn = createControlButton(
    beaconFrame,
    "Interface\\AddOns\\EllesmereUI\\media\\icons\\cogs-3.png",
    -49,
    L["Toggle Plan Editor"] or "NPT Plan",
    function()
      local E = MDT_NPT.CooldownPlanEditor
      if not E then return end
      local f = _G.MDTNPTCooldownPlanEditorFrame
      if f and f:IsShown() then E:Close() else E:Open() end
    end
  )

  beaconFrame.resizeGrip = createResizeGrip(beaconFrame)

  beaconFrame:SetScript("OnEnter", function(self)
    self.completeBtn:SetAlpha(0.7)
    self.skipBtn:SetAlpha(0.7)
    self.revertBtn:SetAlpha(0.7)
    self.planBtn:SetAlpha(0.7)
    self.resizeGrip:SetAlpha(0.7)
  end)

  beaconFrame:SetScript("OnLeave", function(self)
    if not isMouseOver(self) then
      self.completeBtn:SetAlpha(0)
      self.skipBtn:SetAlpha(0)
      self.revertBtn:SetAlpha(0)
      self.planBtn:SetAlpha(0)
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

  -- Optical vertical alignment: font line-box metrics differ per size, so fixed
  -- anchor offsets never line up across the 14px badge / 10px status / 12px
  -- glyphs. Center status text and button glyphs on the badge's rendered box
  -- (heights are valid one frame after text set; Beacon:Update re-converges).
  local bh = (frame.pullBadge and frame.pullBadge.GetHeight) and frame.pullBadge:GetHeight() or 0
  if bh and bh > 0 then
    local center = -10 - bh / 2
    local sh = (frame.statusText and frame.statusText.GetHeight) and frame.statusText:GetHeight() or 0
    frame.statusText:ClearAllPoints()
    frame.statusText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -72, center + sh / 2)
    for _, b in ipairs({ frame.planBtn, frame.revertBtn, frame.skipBtn, frame.completeBtn }) do
      if b and b._offsetX then
        b:ClearAllPoints()
        -- glyph is top-anchored 1px under the button top: center = top -1 -glyphH/2
        b:SetPoint("TOPRIGHT", frame, "TOPRIGHT", b._offsetX, center + 1 + (b._glyphH or 12) / 2)
      end
    end
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
local PORTRAIT_TOP_Y = -66
local PORTRAIT_PER_ROW = 4
local PORTRAIT_ROW_GAP = 4
local PORTRAIT_LABEL_H = 12        -- vertical band reserved for the short-name label under each portrait
local PORTRAIT_LABEL_MAX_CHARS = 5 -- CJK chars that fit a portrait column at the 6px label font
local COOLDOWN_ROW_Y = -152        -- cooldown icon row top: below the always-reserved 2x4 portrait grid + labels

---Frame height is constant (the portrait area always reserves the 2x4 grid), except
---in map-only mode where the info panel is hidden entirely.
local function syncFrameHeight(frame)
  local db = MDT_NPT:GetDB()
  local mapOnly = (db and db.beacon and db.beacon.mapOnly) or false
  local MAP_ONLY_H = Minimap.SIZE + 8
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
---pushing into the progress bar below. Slots fill from the RIGHT edge leftwards,
---top→bottom within a column: rank 1 = top-right, rank 2 = bottom-right (two rows),
---rank 3 = top of the second-to-last column, etc.
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

  local rows = twoRow and 2 or 1
  local colFromRight = math.floor((i - 1) / rows)
  local row = (i - 1) % rows
  local col = PORTRAIT_PER_ROW - 1 - colFromRight
  local x = frame.portraitInfoPanelX + col * (size + colGap)
  local y = PORTRAIT_TOP_Y - row * (size + PORTRAIT_ROW_GAP + PORTRAIT_LABEL_H)

  portrait:ClearAllPoints()
  portrait:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
end

-- MDT tooltip efficiency score: 2.5 * (forces/totalForces) * 13000 / (health/20000).
-- Returns nil when the required MDT data is unavailable (score then never grays).
local function efficiencyScoreOf(enemy, clones)
  local health = enemy.health
  if not health or health <= 0 then return nil end
  -- pull[enemyIndex] holds clone INDICES (numbers), not clone tables; resolve via enemy.clones
  local cloneIdx = (type(clones) == "table") and clones[1]
  local clone = (type(cloneIdx) == "number") and enemy.clones and enemy.clones[cloneIdx]
  local forces = (clone and clone.count) or enemy.count
  if not forces then return nil end
  local ok, mdtDb = pcall(MDT.GetDB, MDT)
  local idx = ok and mdtDb and mdtDb.currentDungeonIdx
  local totals = idx and MDT.dungeonTotalCount and MDT.dungeonTotalCount[idx]
  local totalCount = totals and totals.normal
  if not totalCount or totalCount <= 0 then return nil end
  return 2.5 * (forces / totalCount) * 13000 / (health / 20000)
end

local GRAY_COLOR = { 0.55, 0.55, 0.55 } -- low efficiency (score < 1): ring + texts go gray

local function renderEnemiesPortraits(frame, pull, enemies)
  local enemyIndices = {}
  if pull and enemies then
    for enemyIndex in pairs(pull) do
      if tonumber(enemyIndex) and enemies[enemyIndex] and #enemyIndices < PORTRAIT_MAX then
        enemyIndices[#enemyIndices + 1] = enemyIndex
      end
    end
  end

  -- Kill-priority order: higher level > has an interruptible spell > higher MDT
  -- efficiency score > higher health (scaled by MDT's selected keystone difficulty).
  local hpByKey, effByKey = {}, {}
  for _, ei in ipairs(enemyIndices) do
    local e = enemies[ei]
    local hp = e.health or 0
    if MDT.CalculateEnemyHealth and MDT.GetDB then
      local ok, mdtDb = pcall(MDT.GetDB, MDT)
      local diff = ok and mdtDb and mdtDb.currentDifficulty
      if diff then
        local ok2, v = pcall(MDT.CalculateEnemyHealth, MDT, e.isBoss or false, hp, diff, e.ignoreFortified)
        if ok2 and type(v) == "number" then hp = v end
      end
    end
    hpByKey[ei] = hp
    effByKey[ei] = efficiencyScoreOf(e, pull[ei])
  end
  table.sort(enemyIndices, function(a, b)
    local ea, eb = enemies[a], enemies[b]
    -- low-efficiency (gray, score < 1) mobs carry no progress: always sink them last
    local ga = effByKey[a] ~= nil and effByKey[a] < 1
    local gb = effByKey[b] ~= nil and effByKey[b] < 1
    if ga ~= gb then return not ga end
    local la, lb = ea.level or 0, eb.level or 0
    if la ~= lb then return la > lb end
    local ia, ib = hasInterruptibleSpell(ea), hasInterruptibleSpell(eb)
    if ia ~= ib then return ia end
    local sa, sb = effByKey[a] or -1, effByKey[b] or -1
    if sa ~= sb then return sa > sb end
    return (hpByKey[a] or 0) > (hpByKey[b] or 0)
  end)

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
    nm:SetText(fitLabel(shortEnemyName(zh) or "", (count > PORTRAIT_PER_ROW) and 4 or PORTRAIT_LABEL_MAX_CHARS))
    -- low efficiency (<1) paints ring + name + count gray; otherwise the mob-type color
    local eff = effByKey[enemyIndices[i]]
    local mc = (eff ~= nil and eff < 1) and GRAY_COLOR or MOB_COLORS[staticMobType(enemy)] or MOB_COLORS.other
    nm:SetTextColor(mc[1], mc[2], mc[3], 1)
    -- Tint the white circle ring around the portrait with the same mob-type color.
    frame.portraitOutlines[i]:SetVertexColor(mc[1], mc[2], mc[3], 1)
    nm:Show()
    -- clone count badge at the portrait's top-left ("x2" etc.; a single mob shows nothing)
    local clones = pull[enemyIndices[i]]
    local cloneCount = (type(clones) == "table" and #clones) or 1
    local ct = frame.portraitCounts and frame.portraitCounts[i]
    if not ct then
      ct = frame:CreateFontString(nil, "OVERLAY", Theme.fonts.npcName)
      ct:SetShadowColor(unpack(Theme.colors.shadow))
      ct:SetShadowOffset(1, -1)
      frame.portraitCounts = frame.portraitCounts or {}
      frame.portraitCounts[i] = ct
    end
    ct:ClearAllPoints()
    ct:SetPoint("TOPLEFT", frame.portraits[i], "TOPLEFT", -3, 3)
    if cloneCount > 1 then
      ct:SetText("x"..cloneCount)
      ct:SetTextColor(mc[1], mc[2], mc[3], 1)  -- same mob-type color as the name label
      ct:Show()
    else
      ct:Hide()
    end
    if frame.portraitHovers and frame.portraitHovers[i] then
      frame.portraitHovers[i].mobName = rawName and (zh or rawName) or nil
      frame.portraitHovers[i].enemyIdx = tonumber(enemyIndices[i])
      frame.portraitHovers[i].cloneIdx = (type(clones) == "table" and clones[1]) or nil
      frame.portraitHovers[i].npcID = enemy.id
      frame.portraitHovers[i]:Show()
    end
  end
  for i = count + 1, PORTRAIT_MAX do
    frame.portraits[i]:Hide()
    frame.portraitOutlines[i]:Hide()
    if frame.portraitNames and frame.portraitNames[i] then frame.portraitNames[i]:Hide() end
    if frame.portraitCounts and frame.portraitCounts[i] then frame.portraitCounts[i]:Hide() end
    if frame.portraitHovers and frame.portraitHovers[i] then
      frame.portraitHovers[i].mobName = nil
      frame.portraitHovers[i].enemyIdx = nil
      frame.portraitHovers[i].cloneIdx = nil
      frame.portraitHovers[i].npcID = nil
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

local MAP_ONLY_W = Minimap.SIZE + 8 -- minimap plus its 4px margins on each side

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

  -- the plan-cluster band follows the rows' own visibility (set by the render
  -- pass); map-only mode force-hides it here since the render knows nothing of it
  if mapOnly then frame:SetCdBandShown(false) end

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
      if frame.portraitCounts and frame.portraitCounts[i] then frame.portraitCounts[i]:Hide() end
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
