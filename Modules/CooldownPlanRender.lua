local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT

local CooldownData = MDT_NPT.CooldownData
local CooldownPlan = MDT_NPT.CooldownPlan

local pairs, ipairs = pairs, ipairs

-- CooldownPlanRender: runtime rendering of the per-pull cooldown plan icon rows
-- on the Beacon (current pull row + smaller next-pull preview row). Design 10/11.
local Render = {}

-- Color semantics (design 11.2): {r,g,b,a} border colors.
local COLOR_USE      = { 0, 1, 0.4, 1 }     -- use: green
local COLOR_SAVE     = { 0.7, 0.2, 0.2, 1 } -- save: red-grey
local COLOR_CONFLICT = { 1, 0.6, 0, 1 }     -- marked use but still on CD: warning
local COLOR_MISMATCH = { 1, 0.8, 0, 1 }     -- pull fingerprint mismatch
local COLOR_EMPTY    = { 0.3, 0.3, 0.3, 0.5 } -- not planned

local ICON_SIZE = 24
local NEXT_ICON_SIZE = 16

local function borderColorFor(entry, mismatch)
  if mismatch then return COLOR_MISMATCH end
  if not entry.plan then return COLOR_EMPTY end
  if entry.plan.action == "use" then
    -- conflict: marked use but still on CD
    local cdID = (entry.seed.kind == "item") and entry.seed.useEffectSpellID or entry.resolved
    if cdID then
      local info = C_Spell.GetSpellCooldown(cdID)
      if info and info.startTime and info.startTime > 0 and info.duration and info.duration > 1.5 then
        return COLOR_CONFLICT
      end
    end
    return COLOR_USE
  elseif entry.plan.action == "save" then
    return COLOR_SAVE
  end
  return COLOR_EMPTY
end

-- Resolve runtime spellID + icon for a seed entry (design 6.2 / 8.2).
local function resolveEntry(entry, dbChar)
  local seed = entry.seed
  if seed.kind == "spell" then
    local id = seed.id
    if type(id) == "table" then
      id = CooldownData.resolveAscendanceID(id)
    end
    entry.resolved = id
    return id, C_Spell.GetSpellTexture(id), (seed.kind == "item") and seed.useEffectSpellID or id
  else
    -- item: icon from itemID; CD/icon from shared use-effect spell
    local itemID = (dbChar and dbChar.cooldownPotionID) or seed.defaultItemID
    entry.resolved = itemID
    local icon = itemID and C_Item.GetItemIconByID(itemID)
    return itemID, icon, seed.useEffectSpellID
  end
end

local function ensureCells(row, count, size)
  row.cells = row.cells or {}
  for i = 1, count do
    local cell = row.cells[i]
    if not cell then
      cell = CreateFrame("Frame", nil, row)
      cell:SetSize(size, size)
      cell.icon = cell:CreateTexture(nil, "ARTWORK")
      cell.icon:SetAllPoints(cell)
      cell.border = cell:CreateTexture(nil, "OVERLAY")
      cell.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
      cell.border:SetAllPoints(cell)
      cell.cd = CreateFrame("Cooldown", nil, cell, "CooldownFrameTemplate")
      cell.cd:SetAllPoints(cell)
      cell.label = cell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      cell.label:SetPoint("BOTTOM", cell, "BOTTOM", 0, 0)
      row.cells[i] = cell
    end
    cell:SetSize(size, size)
  end
  -- hide extras
  for i = count + 1, #row.cells do
    row.cells[i]:Hide()
  end
end

local function layoutRow(row, count, size)
  for i = 1, count do
    local cell = row.cells[i]
    cell:ClearAllPoints()
    cell:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * (size + 2), 0)
    cell:Show()
  end
end

local cdTickers = {}

local function startCDTicker(cell, getCDID)
  if cell.cdTicker then return end
  cell.cdTicker = C_Timer.NewTicker(0.1, function()
    local cdID = getCDID()
    if not cdID then cell.cd:Clear() return end
    local info = C_Spell.GetSpellCooldown(cdID)
    if info and info.startTime and info.startTime > 0 and info.duration and info.duration > 1.5 then
      cell.cd:SetCooldown(info.startTime, info.duration)
      cell.cd:SetHideCountdownNumbers(false)
    else
      cell.cd:Clear()
    end
  end)
end

local function fillRow(row, entries, dbChar, mismatch, size, showCD, pullIdx)
  ensureCells(row, #entries, size)
  layoutRow(row, #entries, size)
  for i, entry in ipairs(entries) do
    local cell = row.cells[i]
    local _, icon, cdID = resolveEntry(entry, dbChar)
    cell.icon:SetTexture(icon or "Interface\\ICONS\\INV_Misc_QuestionMark")
    -- State shown via icon vertex tint (no overlay frame; removes stray grey frames).
    cell.border:Hide()
    local stateColor
    if mismatch then
      stateColor = COLOR_MISMATCH
    elseif not entry.plan then
      stateColor = nil
    elseif entry.plan.action == "use" then
      local cdID2 = (entry.seed.kind == "item") and entry.seed.useEffectSpellID or entry.resolved
      local onCD = false
      if cdID2 then
        local ci = C_Spell.GetSpellCooldown(cdID2)
        if ci and ci.startTime and ci.startTime > 0 and ci.duration and ci.duration > 1.5 then onCD = true end
      end
      stateColor = onCD and COLOR_CONFLICT or COLOR_USE
    else
      stateColor = COLOR_SAVE
    end
    -- icon stays natural color; state conveyed by label TEXT + label COLOR only
    -- (tinting the icon multiplied with the spell icon's own color and read as muddy).
    cell.icon:SetVertexColor(1, 1, 1, 1)
    cell.icon:SetAlpha(entry.plan and 1 or 0.5)
    if cell.label then
      if entry.plan then
        local L = MDT_NPT.L
        cell.label:SetText(entry.plan.action == "use" and (L and L["Use"] or "开") or (L and L["Save"] or "留"))
        cell.label:SetTextColor(stateColor[1], stateColor[2], stateColor[3], 1)
      else
        cell.label:SetText("")
      end
    end
    if showCD then
      startCDTicker(cell, function() return cdID end)
      local info = cdID and C_Spell.GetSpellCooldown(cdID)
      if info and info.startTime and info.startTime > 0 and info.duration and info.duration > 1.5 then
        cell.cd:Show()
        cell.cd:SetCooldown(info.startTime, info.duration)
        cell.cd:SetHideCountdownNumbers(false)
      else
        cell.cd:Clear()
        cell.cd:Hide()
      end
    else
      cell.cd:Clear()
      cell.cd:Hide()
    end
    -- tooltip (design 11.5)
    cell:EnableMouse(true)
    cell:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(entry.seed.name or "?")
      local status = entry.plan and entry.plan.action or nil
      GameTooltip:AddLine(status == "use" and (MDT_NPT.L and MDT_NPT.L["Use"] or "Use") or (status == "save" and (MDT_NPT.L and MDT_NPT.L["Save"] or "Save") or (MDT_NPT.L and MDT_NPT.L["Not Planned"] or "Not Planned")))
      if mismatch then
        GameTooltip:AddLine((MDT_NPT.L and MDT_NPT.L["Pull Mismatch"]) or "Pull Mismatch", 1, 0.8, 0)
      end
      GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
end

-- Main render entry, called from Beacon:Update (design 11.1).
function Render:Render(frame, state, preset, nextPull)
  local dbChar = MDT_NPT:GetDBChar()
  local showRow = frame.cooldownIconsRow
  local nextRow = frame.upcomingIconsRow
  if not showRow or not nextRow then return end

  local db = MDT_NPT:GetDB()
  local active = db and db.beacon and db.beacon.showCooldownPlan
  if not active then
    for _, r in ipairs({ showRow, nextRow }) do
      if r then
        r:Hide()
        if r.cells then
          for _, c in ipairs(r.cells) do c:Hide() end
        end
      end
    end
    return
  end

  local uid = CooldownData.getPlanKey(state)
  local pullIndex = state and state.currentNextPull
  if not uid or not pullIndex then
    showRow:Hide(); nextRow:Hide()
    return
  end

  local pull = preset and preset.value and preset.value.pulls and preset.value.pulls[pullIndex]
  local dungeonIndex = (state and state.dungeonIndex) or (preset and preset.value and preset.value.currentDungeonIdx)
  local enemies = MDT.dungeonEnemies and MDT.dungeonEnemies[dungeonIndex]
  local matched, hasStored = CooldownPlan:VerifyFingerprint(uid, pullIndex, pull, enemies)
  local mismatch = hasStored and not matched

  local entries = CooldownData.getActiveEntries(dbChar, uid, pullIndex)
  showRow:Show()
  fillRow(showRow, entries, dbChar, mismatch, ICON_SIZE, true)

  -- next-pull preview row (design 11.4): nextPull+1, smaller, no CD
  local nextIndex = (nextPull or pullIndex) + 1
  local pullCount = state.pullStates and #state.pullStates or 0
  if nextIndex <= pullCount then
    local nextEntries = CooldownData.getActiveEntries(dbChar, uid, nextIndex)
    nextRow:Show()
    fillRow(nextRow, nextEntries, dbChar, false, NEXT_ICON_SIZE, false)
  else
    nextRow:Hide()
  end
end

MDT_NPT.CooldownPlanRender = Render
