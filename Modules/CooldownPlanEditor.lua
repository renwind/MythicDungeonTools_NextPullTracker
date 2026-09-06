local MDT_NPT = MDT_NPT

local CooldownData = MDT_NPT.CooldownData
local CooldownPlan = MDT_NPT.CooldownPlan
local Theme = MDT_NPT.Theme

-- CooldownPlanEditor: standalone edit panel (wave list + per-wave use/save cells).
-- Opened via /npt plan and Beacon right-click. Design 7.
MDTNPTCooldownPlanMixin = {}

-- compact panel: two seed columns max; height matches the beacon frame (216)
local PANEL_W, PANEL_H = 240, 216
local CELL_SIZE = 28

-- How often (seconds) the shown editor polls MDT for a route change.
local ROUTE_CHECK_INTERVAL = 0.5

-- Read the identity of MDT's current route/preset. Returns the tuple the editor
-- compares to decide whether a reload is needed: the route uid, the number of
-- pulls, and the dungeon index. Kept in one place so ReloadPlans and the
-- OnUpdate route-change check stay in lockstep.
local function readRouteIdentity()
  local preset = MDT_NPT.MDT and MDT_NPT.MDT.GetCurrentPreset and MDT_NPT.MDT:GetCurrentPreset() or nil
  local uid = preset and preset.uid or nil
  uid = (uid and uid ~= "") and uid or nil
  local pulls = preset and preset.value and preset.value.pulls
  local pullCount = pulls and #pulls or 0
  local dungeonIndex = (preset and preset.value and preset.value.currentDungeonIdx)
    or (MDT_NPT.MDT and MDT_NPT.MDT.GetDB and MDT_NPT.MDT:GetDB().currentDungeonIdx) or nil
  return uid, pullCount, dungeonIndex
end

-- EUI-style slim scrollbar geometry: thumb height/offset from the scroll range.
function MDTNPTCooldownPlanMixin:UpdateWaveThumb()
  if not self.waveThumb then return end
  local view = self.waveList:GetHeight()
  local content = self.waveListContent:GetHeight()
  local range = self.waveList:GetVerticalScrollRange()
  if content <= 0 or range <= 0 then
    self.waveThumb:Hide()
    return
  end
  local thumbH = math.max(24, view * (view / content))
  local offset = -(self.waveList:GetVerticalScroll() / range) * (view - thumbH)
  self.waveThumb:SetHeight(thumbH)
  self.waveThumb:ClearAllPoints()
  self.waveThumb:SetPoint("TOPLEFT", self.waveTrack, "TOPLEFT", 0, offset)
  self.waveThumb:SetPoint("TOPRIGHT", self.waveTrack, "TOPRIGHT", 0, offset)
  self.waveThumb:Show()
end

function MDTNPTCooldownPlanMixin:OnLoad()
  self.planEntries = {}
  self.selectedPull = 1
  -- Theme panel chrome: flat bg + 1px EUI-style border (same look as the beacon)
  self.themeBg = self:CreateTexture(nil, "BACKGROUND")
  self.themeBg:SetAllPoints()
  local bgC = Theme.colors.panelBg
  self.themeBg:SetColorTexture(bgC[1], bgC[2], bgC[3], bgC[4])
  self.themeEdges = Theme.CreateBorder(self)
  -- draggable; once the user moves it we stop auto-snapping to the beacon
  self:SetMovable(true)
  self:RegisterForDrag("LeftButton")
  self:SetScript("OnDragStart", function(f)
    if InCombatLockdown() then return end
    f.userMoved = true
    f:StartMoving()
  end)
  self:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)
  Theme.RegisterRefreshCallback(function()
    if not self.themeBg then return end
    local bg = Theme.colors.panelBg
    self.themeBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    Theme.UpdateBorder(self.themeEdges)
    local m = Theme.colors.textMuted
    if self.potionHint then self.potionHint:SetTextColor(m[1], m[2], m[3], m[4]) end
    if self.waveTrack then
      local tr = Theme.colors.panelBorder
      self.waveTrack:SetColorTexture(tr[1], tr[2], tr[3], tr[4])
    end
    if self.waveThumb then
      local th = Theme.colors.textSecondary
      self.waveThumb:SetColorTexture(th[1], th[2], th[3], 0.6)
    end
  end)
  -- child controls (programmatic; XML supplies only the frame + mixin)
  -- EUI-style wave list: bare ScrollFrame + wheel + slim flat scrollbar (no blizz arrows)
  self.waveList = CreateFrame("ScrollFrame", nil, self)
  self.waveList:SetPoint("TOPLEFT", self, "TOPLEFT", 12, -12)
  self.waveList:SetSize(100, PANEL_H - 60)
  self.waveList:EnableMouseWheel(true)
  self.waveList:SetScript("OnMouseWheel", function(f, delta)
    local max = f:GetVerticalScrollRange()
    local next = math.max(0, math.min(max, f:GetVerticalScroll() - delta * 24))
    f:SetVerticalScroll(next)
  end)
  self.waveList:SetScript("OnVerticalScroll", function(f)
    if f:GetParent().UpdateWaveThumb then f:GetParent():UpdateWaveThumb() end
  end)
  self.waveListContent = CreateFrame("Frame", nil, self.waveList)
  self.waveListContent:SetSize(100, PANEL_H - 60)
  self.waveList:SetScrollChild(self.waveListContent)
  -- 4px flat track + thumb, colours from Theme
  self.waveTrack = self:CreateTexture(nil, "OVERLAY")
  self.waveTrack:SetWidth(4)
  self.waveTrack:SetPoint("TOPLEFT", self.waveList, "TOPRIGHT", 6, 0)
  self.waveTrack:SetPoint("BOTTOMLEFT", self.waveList, "BOTTOMRIGHT", 6, 0)
  local trC = Theme.colors.panelBorder
  self.waveTrack:SetColorTexture(trC[1], trC[2], trC[3], trC[4])
  self.waveThumb = self:CreateTexture(nil, "OVERLAY", nil, 1)
  local thC = Theme.colors.textSecondary
  self.waveThumb:SetColorTexture(thC[1], thC[2], thC[3], 0.6)
  self.waveThumb:Hide()
  self.cellArea = CreateFrame("Frame", nil, self)
  self.cellArea:SetPoint("TOPLEFT", self.waveList, "TOPRIGHT", 16, 0)
  self.cellArea:SetSize(80, 60)
  self.potionHint = self:CreateFontString(nil, "OVERLAY", Theme.fonts.small)
  self.potionHint:SetPoint("TOP", self.cellArea, "BOTTOM", 0, -8)
  self.potionHint:SetText(MDT_NPT.L and MDT_NPT.L["Drag Potion Here"] or "Drag Potion Here")
  local hintC = Theme.colors.textMuted
  self.potionHint:SetTextColor(hintC[1], hintC[2], hintC[3], hintC[4])
  self.potionHint:Hide()
  self.applyButton = CreateFrame("Button", nil, self)
  self.applyButton:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -12, 12)
  self.applyButton:SetSize(90, 24)
  Theme.StyleButton(self.applyButton, MDT_NPT.L and MDT_NPT.L["Apply"] or "Apply", Theme.fonts.small)
  self.applyButton:SetScript("OnClick", function()
    self:Hide()
  end)
end

function MDTNPTCooldownPlanMixin:OnShow()
  self:ReloadPlans()
  -- OnShow only fires on hidden->visible. While the editor stays open the user
  -- can switch MDT routes (or edit pulls), so poll for route changes and reload
  -- when the current route identity no longer matches (design 7.2).
  self.routeCheckElapsed = 0
  self:SetScript("OnUpdate", function(frame, dt)
    frame.routeCheckElapsed = (frame.routeCheckElapsed or 0) + (dt or 0)
    if frame.routeCheckElapsed < ROUTE_CHECK_INTERVAL then return end
    frame.routeCheckElapsed = 0
    frame:CheckRouteChanged()
  end)
end

-- Re-read current route's plans, rebuild wave list + cells (design 7.2 OnShow reload).
function MDTNPTCooldownPlanMixin:ReloadPlans()
  -- Resolve uid/pullCount from the MDT current preset (works in town, not only while tracking).
  self.uid, self.pullCount, self.dungeonIndex = readRouteIdentity()
  -- default-select the tracking current next pull so the editor matches the beacon current row
  self.selectedPull = (MDT_NPT.state and MDT_NPT.state.currentNextPull) or self.selectedPull or 1
  self:RebuildWaveList()
  self:RebuildCells()
end

-- Reload only when MDT's route identity (uid, pull count, or dungeon) differs
-- from what the editor last rendered. Returns true when a reload happened.
function MDTNPTCooldownPlanMixin:CheckRouteChanged()
  local uid, pullCount, dungeonIndex = readRouteIdentity()
  if uid ~= self.uid or pullCount ~= self.pullCount or dungeonIndex ~= self.dungeonIndex then
    self:ReloadPlans()
    return true
  end
  return false
end

function MDTNPTCooldownPlanMixin:RebuildWaveList()
  -- wave list buttons Pull 1..N (vertical scroll frame self.waveList)
  if not self.waveList then return end
  self.waveButtons = self.waveButtons or {}
  local parent = self.waveListContent or self.waveList
  local n = self.pullCount or 0
  for i = 1, n do
    local btn = self.waveButtons[i]
    if not btn then
      btn = CreateFrame("Button", nil, parent)
      btn:SetSize(90, 22)
      btn.themeText = Theme.StyleButton(btn, "", Theme.fonts.small)
      btn:SetScript("OnClick", function(b)
        self.selectedPull = b.pullIndex
        self:RebuildCells()
        self:RebuildWaveList()
      end)
      self.waveButtons[i] = btn
    end
    btn.pullIndex = i
    btn.themeText:SetText("Pull " .. i)
    -- selected wave reads accent, the rest secondary
    local tc = (i == self.selectedPull) and Theme.colors.accent or Theme.colors.textSecondary
    btn.themeText:SetTextColor(tc[1], tc[2], tc[3], tc[4])
    btn:ClearAllPoints()
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * 24)
    btn:Show()
  end
  for i = n + 1, #(self.waveButtons or {}) do
    self.waveButtons[i]:Hide()
  end
  -- grow the scroll content with the wave count so the slim scrollbar tracks it
  local viewH = self.waveList:GetHeight()
  self.waveListContent:SetHeight(math.max(viewH, n * 24))
  self.waveList:UpdateScrollChildRect()
  self:UpdateWaveThumb()
end

function MDTNPTCooldownPlanMixin:RebuildCells()
  if not self.cellArea then return end
  local dbChar = MDT_NPT:GetDBChar()
  local uid = self.uid
  local pullIndex = self.selectedPull
  self.cellArea.cells = self.cellArea.cells or {}
  local seed = CooldownData.getSeedEntries()
  local plan = uid and CooldownPlan:Get(uid, pullIndex) or nil
  for i, seedEntry in ipairs(seed) do
    local cell = self.cellArea.cells[i]
    if not cell then
      cell = CreateFrame("Button", nil, self.cellArea)
      cell:SetSize(CELL_SIZE, CELL_SIZE)
      cell.icon = cell:CreateTexture(nil, "ARTWORK")
      cell.icon:SetAllPoints(cell)
      cell.edges = Theme.CreateBorder(cell)
      cell.label = cell:CreateFontString(nil, "OVERLAY", Theme.fonts.small)
      cell.label:SetPoint("TOP", cell, "BOTTOM", 0, -2)
      cell:SetScript("OnClick", function(c, button)
        self:OnCellClick(c, button)
      end)
      self.cellArea.cells[i] = cell
    end
    cell.seedEntry = seedEntry
    local icon
    if seedEntry.kind == "spell" then
      icon = C_Spell.GetSpellTexture(type(seedEntry.id) == "table" and seedEntry.id[1] or seedEntry.id)
    else
      icon = C_Item.GetItemIconByID((dbChar and dbChar.cooldownPotionID) or seedEntry.defaultItemID)
    end
    cell.icon:SetTexture(icon or "Interface\\ICONS\\INV_Misc_QuestionMark")
    -- current action
    local action
    if plan and plan.entries then
      for _, e in ipairs(plan.entries) do
        local sid = seedEntry.id
        local match = (type(sid) == "table") and (function() for _, s in ipairs(sid) do if e.id == s then return true end end return false end)()
          or (e.id == sid) or (seedEntry.kind == "item" and e.id == (dbChar and dbChar.cooldownPotionID))
        if match then action = e.action break end
      end
    end
    cell.action = action
    cell.label:SetText(action == "use" and (MDT_NPT.L["Use"] or "Use") or (action == "save" and (MDT_NPT.L["Save"] or "Save") or ""))
    local lc = (action == "use") and Theme.colors.cdUse or ((action == "save") and Theme.colors.cdSave or Theme.colors.textMuted)
    cell.label:SetTextColor(lc[1], lc[2], lc[3], lc[4])
    cell:ClearAllPoints()
    cell:SetPoint("TOPLEFT", self.cellArea, "TOPLEFT", (i - 1) * (CELL_SIZE + 8), 0)
    cell:Show()
  end
end

-- Click toggles use<->save; Ctrl+click on potion cell opens drag mode (design 7.2/8.2).
function MDTNPTCooldownPlanMixin:OnCellClick(cell, button)
  local seedEntry = cell.seedEntry
  if not seedEntry then return end
  if button == "LeftButton" and IsControlKeyDown() and seedEntry.kind == "item" then
    self.awaitingPotion = true
    if self.potionHint then self.potionHint:Show() end
    return
  end
  local uid = self.uid
  local pullIndex = self.selectedPull
  if not uid or not pullIndex then return end
  local id = seedEntry.kind == "spell" and (type(seedEntry.id) == "table" and seedEntry.id[1] or seedEntry.id)
    or (MDT_NPT:GetDBChar() and MDT_NPT:GetDBChar().cooldownPotionID) or seedEntry.defaultItemID
  local nextAction = (cell.action == "use") and "save" or "use"
  CooldownPlan:SetEntry(uid, pullIndex, id, seedEntry.kind, nextAction)
  -- store fingerprint at plan-build time (design 5.5)
  -- fingerprint from the preset's pull (works in town, not only while tracking)
  local preset = MDT_NPT.MDT and MDT_NPT.MDT.GetCurrentPreset and MDT_NPT.MDT:GetCurrentPreset() or nil
  local pull = preset and preset.value and preset.value.pulls and preset.value.pulls[pullIndex]
  local enemies = MDT_NPT.MDT and MDT_NPT.MDT.dungeonEnemies and MDT_NPT.MDT.dungeonEnemies[self.dungeonIndex]
  if pull then
    CooldownPlan:SetFingerprint(uid, pullIndex, CooldownData.computePullFingerprint(pull, enemies))
  end
  self:RebuildCells()
  -- refresh the beacon icon rows immediately (no need to toggle showCooldownPlan)
  if MDT_NPT.Beacon and MDT_NPT.Beacon.Update then MDT_NPT.Beacon:Update() end
end

function MDTNPTCooldownPlanMixin:OnHide()
  -- Stop the route-change poll while hidden; OnShow re-arms it.
  self:SetScript("OnUpdate", nil)
  if MDT_NPT.Beacon and MDT_NPT.Beacon.Update then MDT_NPT.Beacon:Update() end
end

-- Lazy-instantiate the editor frame from the XML template (the template .xml loads
-- AFTER this .lua, so the frame must be created at first Open, not at load).
local editorFrame
local CooldownPlanEditor = {}
function CooldownPlanEditor:Open()
  if InCombatLockdown() then return end
  if not editorFrame then
    editorFrame = CreateFrame("Frame", "MDTNPTCooldownPlanEditorFrame", UIParent, "MDTNPTCooldownPlanTemplate")
  end
  -- default dock: hug the beacon's right edge until the user drags the panel away
  if not editorFrame.userMoved then
    local beacon = _G.MDTNextPullBeaconFrame
    editorFrame:ClearAllPoints()
    if beacon then
      editorFrame:SetPoint("TOPLEFT", beacon, "TOPRIGHT", 8, 0)
    else
      editorFrame:SetPoint("CENTER")
    end
  end
  editorFrame:Show()
end
function CooldownPlanEditor:Close()
  if editorFrame then editorFrame:Hide() end
end

-- Public refresh hook (used by Core:UpdateAll and external callers). editorFrame
-- is a file-local, so this method is the only supported way to force a reload of
-- the open editor from outside this module.
function CooldownPlanEditor:Refresh()
  if editorFrame and editorFrame:IsShown() then
    editorFrame:ReloadPlans()
  end
end

MDT_NPT.CooldownPlanEditor = CooldownPlanEditor
