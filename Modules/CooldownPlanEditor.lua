local MDT_NPT = MDT_NPT

local CooldownData = MDT_NPT.CooldownData
local CooldownPlan = MDT_NPT.CooldownPlan
local Theme = MDT_NPT.Theme

-- CooldownPlanEditor: standalone edit panel (wave list + per-wave use/save cells).
-- Opened via /npt plan and Beacon right-click. Design 7.
MDTNPTCooldownPlanMixin = {}

local PANEL_W, PANEL_H = 420, 340
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

function MDTNPTCooldownPlanMixin:OnLoad()
  self.planEntries = {}
  self.selectedPull = 1
  -- Backdrop set in code (XML Backdrop/AbsInset attrs are unrecognized by the 12.x parser).
  self:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 11, right = 11, top = 11, bottom = 11 },
  })
  -- child controls (programmatic; XML supplies only the frame + mixin)
  self.waveList = CreateFrame("ScrollFrame", nil, self, "UIPanelScrollFrameTemplate")
  self.waveList:SetPoint("TOPLEFT", self, "TOPLEFT", 12, -40)
  self.waveList:SetSize(110, PANEL_H - 90)
  self.waveListContent = CreateFrame("Frame", nil, self.waveList)
  self.waveListContent:SetSize(110, PANEL_H - 90)
  self.waveList:SetScrollChild(self.waveListContent)
  self.cellArea = CreateFrame("Frame", nil, self)
  self.cellArea:SetPoint("TOPLEFT", self.waveList, "TOPRIGHT", 20, 0)
  self.cellArea:SetSize(240, 60)
  self.potionHint = self:CreateFontString(nil, "OVERLAY", Theme.fonts.small)
  self.potionHint:SetPoint("TOP", self.cellArea, "BOTTOM", 0, -8)
  self.potionHint:SetText(MDT_NPT.L and MDT_NPT.L["Drag Potion Here"] or "Drag Potion Here")
  self.potionHint:Hide()
  self.applyButton = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
  self.applyButton:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -12, 12)
  self.applyButton:SetSize(90, 24)
  self.applyButton:SetText(MDT_NPT.L and MDT_NPT.L["Apply"] or "Apply")
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
      btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
      btn:SetSize(90, 22)
      btn:SetScript("OnClick", function(b)
        self.selectedPull = b.pullIndex
        self:RebuildCells()
      end)
      self.waveButtons[i] = btn
    end
    btn.pullIndex = i
    btn:SetText("Pull " .. i)
    btn:ClearAllPoints()
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * 24)
    btn:Show()
  end
  for i = n + 1, #(self.waveButtons or {}) do
    self.waveButtons[i]:Hide()
  end
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
