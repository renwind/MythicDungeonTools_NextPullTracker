local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT

local CooldownData = MDT_NPT.CooldownData
local CooldownPlan = MDT_NPT.CooldownPlan

local pairs, ipairs = pairs, ipairs

local Theme = MDT_NPT.Theme

-- CooldownPlanRender: runtime rendering of the per-pull cooldown plan icon rows
-- on the Beacon (current pull row + smaller next-pull preview row). Design 10/11.
local Render = {}

-- EUI-style pixel-perfect border helpers.
local function getPixelSize(frame)
  local scale = frame:GetEffectiveScale()
  return 768 / (select(2, GetPhysicalScreenSize()) * scale)
end

local function createIconBorder(cell)
  local px = getPixelSize(cell)
  local r, g, b, a = 0, 0, 0, 1  -- pure black like EUI

  cell.borderTop = cell:CreateTexture(nil, "OVERLAY", nil, 2)
  cell.borderTop:SetColorTexture(r, g, b, a)
  cell.borderTop:SetPoint("TOPLEFT", cell, "TOPLEFT", 0, 0)
  cell.borderTop:SetPoint("TOPRIGHT", cell, "TOPRIGHT", 0, 0)
  cell.borderTop:SetHeight(px)

  cell.borderBottom = cell:CreateTexture(nil, "OVERLAY", nil, 2)
  cell.borderBottom:SetColorTexture(r, g, b, a)
  cell.borderBottom:SetPoint("BOTTOMLEFT", cell, "BOTTOMLEFT", 0, 0)
  cell.borderBottom:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 0, 0)
  cell.borderBottom:SetHeight(px)

  cell.borderLeft = cell:CreateTexture(nil, "OVERLAY", nil, 2)
  cell.borderLeft:SetColorTexture(r, g, b, a)
  cell.borderLeft:SetPoint("TOPLEFT", cell, "TOPLEFT", 0, -px)
  cell.borderLeft:SetPoint("BOTTOMLEFT", cell, "BOTTOMLEFT", 0, px)
  cell.borderLeft:SetWidth(px)

  cell.borderRight = cell:CreateTexture(nil, "OVERLAY", nil, 2)
  cell.borderRight:SetColorTexture(r, g, b, a)
  cell.borderRight:SetPoint("TOPRIGHT", cell, "TOPRIGHT", 0, -px)
  cell.borderRight:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 0, px)
  cell.borderRight:SetWidth(px)
end

-- Color semantics (design 11.2): {r,g,b,a} border colors.
local COLOR_USE      = Theme.colors.cdUse
local COLOR_SAVE     = Theme.colors.cdSave
local COLOR_CONFLICT = Theme.colors.cdConflict
local COLOR_MISMATCH = Theme.colors.cdMismatch
local COLOR_EMPTY    = Theme.colors.cdEmpty

-- Center overlay badges: green check = use, red cross = save (blizz ready-check art).
local BADGE_USE  = "Interface\\RaidFrame\\ReadyCheck-Ready"
local BADGE_SAVE = "Interface\\RaidFrame\\ReadyCheck-NotReady"

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
      cell.bg = cell:CreateTexture(nil, "BACKGROUND")
      cell.bg:SetAllPoints(cell)
      cell.bg:SetColorTexture(0.06, 0.06, 0.06, 0.9)
      cell.icon = cell:CreateTexture(nil, "ARTWORK")
      cell.icon:SetAllPoints(cell)
      cell.icon:SetTexCoord(0.055, 0.945, 0.055, 0.945)
      createIconBorder(cell)
      cell.cd = CreateFrame("Cooldown", nil, cell, "CooldownFrameTemplate")
      cell.cd:SetAllPoints(cell)
      -- badge lives on its own frame above the Cooldown swipe (child frames outrank
      -- parent textures, so a plain cell texture would sit under the gray swipe)
      cell.badgeFrame = CreateFrame("Frame", nil, cell)
      cell.badgeFrame:SetAllPoints(cell)
      cell.badgeFrame:SetFrameLevel(cell.cd:GetFrameLevel() + 10)
      cell.badge = cell.badgeFrame:CreateTexture(nil, "OVERLAY")
      cell.badge:SetPoint("CENTER", cell, "CENTER", 0, 0)
      cell.badge:SetSize(math.floor(size * 0.8), math.floor(size * 0.8))
      cell.badge:Hide()
      cell.label = cell:CreateFontString(nil, "OVERLAY", Theme.fonts.cdText)
      cell.label:SetPoint("TOP", cell, "BOTTOM", 0, -1)  -- CD countdown under the icon
      cell.label:SetShadowColor(unpack(Theme.colors.shadow))
      cell.label:SetShadowOffset(1, -1)
      cell.label:Hide()
      row.cells[i] = cell
    end
    cell:SetSize(size, size)
    if cell.badge then cell.badge:SetSize(math.floor(size * 0.8), math.floor(size * 0.8)) end
  end
  -- hide extras
  for i = count + 1, #row.cells do
    row.cells[i]:Hide()
  end
end

local function layoutRow(row, count, size, parentSize, yOff)
  local ps = parentSize or size
  local p = ps + 14
  local inset = (ps - size) / 2  -- center smaller icons under the parent row's columns
  for i = 1, count do
    local cell = row.cells[i]
    cell:ClearAllPoints()
    -- Right-aligned: entry 1 hugs the row's right edge, later entries stack
    -- leftwards; parentSize centers the smaller next-pull icons under the
    -- current row's columns. yOff kept for future band offsets (0 = top-flush).
    cell:SetPoint("TOPRIGHT", row, "TOPRIGHT", -((i - 1) * p + inset), yOff or 0)
    cell:Show()
  end
end

local function formatCD(rem)
  if rem <= 0 then return "" end
  if rem >= 60 then return string.format("%d:%02d", math.floor(rem / 60), math.floor(rem % 60)) end
  return string.format("%d", math.ceil(rem))
end

---Ready-and-planned-use highlight (current-pull row only): EUI's flipbook glow in
---its "GCD" mode (RotationHelper_Ants_Flipbook) — the same ring its aura/buff
---reminders show when that glow type is selected. Without EUI a self-drawn cyan
---ring pulses via the CD ticker instead.
local GLOW_COLOR = { 0.4, 0.9, 1 }  -- EUI reminder-ring cyan, one notch brighter
local GLOW_ENTRY = { atlas = "RotationHelper_Ants_Flipbook", texPadding = 1.6 }
local function blendAdd(f)
  for _, region in ipairs({ f:GetRegions() }) do
    if region.SetBlendMode then region:SetBlendMode("ADD") end
  end
end

local function startEuiGlow(cell)
  local G = EllesmereUI and EllesmereUI.Glows
  if not (G and G.StartFlipBookGlow) then return false end
  local sz = cell:GetWidth() or 24
  if not cell.glowWrapper then
    local w = CreateFrame("Frame", nil, cell)
    w:SetAllPoints(cell)
    w:SetFrameLevel(cell.cd:GetFrameLevel() + 5)
    cell.glowWrapper = w
  end
  local ok = pcall(G.StartFlipBookGlow, cell.glowWrapper, sz, GLOW_ENTRY,
    GLOW_COLOR[1], GLOW_COLOR[2], GLOW_COLOR[3])
  if not ok then return false end
  -- additive blend: at 24px the ring stroke is thin and alpha-blending reads
  -- dimmer than EUI's 40px reminders; ADD stacks light instead of covering
  blendAdd(cell.glowWrapper)
  -- faux-bold: a second in-phase flipbook pass offset 1px diagonally thickens
  -- the marching dots by ~1px without enlarging the ring diameter
  if not cell.glowWrapperBold then
    local w2 = CreateFrame("Frame", nil, cell)
    w2:SetPoint("TOPLEFT", cell, "TOPLEFT", 1, -1)
    w2:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 1, -1)
    w2:SetFrameLevel(cell.cd:GetFrameLevel() + 5)
    cell.glowWrapperBold = w2
  end
  local ok2 = pcall(G.StartFlipBookGlow, cell.glowWrapperBold, sz, GLOW_ENTRY,
    GLOW_COLOR[1], GLOW_COLOR[2], GLOW_COLOR[3])
  if ok2 then
    blendAdd(cell.glowWrapperBold)
    cell.glowWrapperBold:Show()
  else
    cell.glowWrapperBold:Hide()
  end
  cell.glowWrapper:Show()
  return true
end
local function stopEuiGlow(cell)
  local G = EllesmereUI and EllesmereUI.Glows
  if not (G and G.StopFlipBookGlow) then return end
  if cell.glowWrapper then pcall(G.StopFlipBookGlow, cell.glowWrapper) end
  if cell.glowWrapperBold then pcall(G.StopFlipBookGlow, cell.glowWrapperBold) end
end
local function ensureGlowRing(cell)
  if cell.glowFrame then return cell.glowFrame end
  local gf = CreateFrame("Frame", nil, cell)
  gf:SetFrameLevel(cell.cd:GetFrameLevel() + 4)
  gf:SetPoint("TOPLEFT", cell, "TOPLEFT", -1, 1)
  gf:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 1, -1)
  local function edge(p1, p2, horiz)
    local t = gf:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(GLOW_COLOR[1], GLOW_COLOR[2], GLOW_COLOR[3], 1)
    t:SetPoint(p1, gf, p1)
    t:SetPoint(p2, gf, p2)
    if horiz then t:SetHeight(2) else t:SetWidth(2) end
  end
  edge("TOPLEFT", "TOPRIGHT", true)
  edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
  edge("TOPLEFT", "BOTTOMLEFT", false)
  edge("TOPRIGHT", "BOTTOMRIGHT", false)
  cell.glowFrame = gf
  return gf
end
local function setCellGlow(cell, on)
  on = on and true or false
  if on == cell.glowOn then return end
  cell.glowOn = on
  local ring = ensureGlowRing(cell)
  if on then
    cell.glowHasAnts = startEuiGlow(cell)
    if cell.glowHasAnts then
      ring:Hide()  -- the (faux-bold) flipbook ring is self-sufficient
    else
      stopEuiGlow(cell)
      if cell.glowWrapper then cell.glowWrapper:Hide() end
      if cell.glowWrapperBold then cell.glowWrapperBold:Hide() end
      ring:SetAlpha(0.55)
      ring:Show()
    end
  else
    ring:Hide()
    cell.glowHasAnts = false
    stopEuiGlow(cell)
    if cell.glowWrapper then cell.glowWrapper:Hide() end
    if cell.glowWrapperBold then cell.glowWrapperBold:Hide() end
  end
end

local cdTickers = {}

local function startCDTicker(cell, getCDID)
  if cell.cdTicker then return end
  cell.cdTicker = C_Timer.NewTicker(0.1, function()
    local cdID = getCDID()
    if not cdID then
      cell.cd:Clear()
      if cell.label then cell.label:SetText("") end
      setCellGlow(cell, cell.glowAllowed and cell.planUse)
      return
    end
    local info = C_Spell.GetSpellCooldown(cdID)
    if info and info.startTime and info.startTime > 0 and info.duration and info.duration > 1.5 then
      cell.cd:SetCooldown(info.startTime, info.duration)
      cell.cd:SetHideCountdownNumbers(true)  -- numbers live under the icon now
      if cell.label then cell.label:SetText(formatCD(info.startTime + info.duration - GetTime())) end
      setCellGlow(cell, false)  -- still on CD: no ready glow
    else
      cell.cd:Clear()
      if cell.label then cell.label:SetText("") end
      setCellGlow(cell, cell.glowAllowed and cell.planUse)  -- ready: glow when this pull plans "use"
    end
    -- pulse the ring only when EUI ants are not marching on top of it
    if cell.glowOn and not cell.glowHasAnts and cell.glowFrame and cell.glowFrame:IsShown() then
      cell.glowFrame:SetAlpha(0.45 + 0.35 * math.sin(GetTime() * 6))
    end
  end)
end

local function fillRow(row, entries, dbChar, mismatch, size, showCD, pullIdx, parentSize)
  ensureCells(row, #entries, size)
  layoutRow(row, #entries, size, parentSize, 0)  -- tops flush with the lust icon top
  for i, entry in ipairs(entries) do
    local cell = row.cells[i]
    local _, icon, cdID = resolveEntry(entry, dbChar)
    cell.icon:SetTexture(icon or "Interface\\ICONS\\INV_Misc_QuestionMark")
    cell.icon:SetTexCoord(0.055, 0.945, 0.055, 0.945)
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
    -- icon stays natural color; the decision (use/save) reads from the center badge,
    -- timing from the countdown under the icon (tinting the icon read as muddy).
    cell.icon:SetVertexColor(1, 1, 1, 1)
    cell.icon:SetAlpha(entry.plan and 1 or 0.5)
    cell.planUse = not not (entry.plan and entry.plan.action == "use")
    cell.glowAllowed = showCD and true or false  -- highlight rings the current-pull row only
    if cell.badge then
      if entry.plan then
        cell.badge:SetTexture(entry.plan.action == "use" and BADGE_USE or BADGE_SAVE)
        cell.badge:Show()
      else
        cell.badge:Hide()
      end
    end
    if showCD then
      startCDTicker(cell, function() return cdID end)
      local info = cdID and C_Spell.GetSpellCooldown(cdID)
      if info and info.startTime and info.startTime > 0 and info.duration and info.duration > 1.5 then
        cell.cd:Show()
        cell.cd:SetCooldown(info.startTime, info.duration)
        cell.cd:SetHideCountdownNumbers(true)
        if cell.label then cell.label:SetText(formatCD(info.startTime + info.duration - GetTime())) end
      else
        cell.cd:Clear()
        cell.cd:Hide()
        if cell.label then cell.label:SetText("") end
      end
      if cell.label then
        local lc = (mismatch and COLOR_MISMATCH) or (stateColor == COLOR_CONFLICT and COLOR_CONFLICT) or Theme.colors.textPrimary
        cell.label:SetTextColor(lc[1], lc[2], lc[3], 1)
        cell.label:Show()
      end
      local onCDNow = info and info.startTime and info.startTime > 0 and info.duration and info.duration > 1.5
      setCellGlow(cell, cell.glowAllowed and cell.planUse and not onCDNow)
    else
      cell.cd:Clear()
      cell.cd:Hide()
      if cell.label then cell.label:Hide() end
      setCellGlow(cell, false)
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

-- Dispel preview: does any enemy in the pull carry a curse / poison spell flag
-- (same flags MDT's enemy info shows as small icons)? Aggregated from MDT static data.
local function pullHasDispel(pull, enemies)
  local curse, poison = false, false
  if pull and enemies then
    for enemyIndex in pairs(pull) do
      local e = enemies[tonumber(enemyIndex)]
      if e and e.spells then
        for _, flags in pairs(e.spells) do
          if flags then
            if flags.curse then curse = true end
            if flags.poison then poison = true end
          end
        end
      end
    end
  end
  return curse, poison
end

-- Two-slot vertical stack (curse on top, poison below) reusing MDT's 16x16 atlases.
local function ensureDispelFrame(row)
  if row.dispelFrame then return row.dispelFrame end
  local f = CreateFrame("Frame", nil, row)
  f:SetSize(16, 34)
  f.curse = f:CreateTexture(nil, "OVERLAY")
  f.curse:SetSize(16, 16)
  f.curse:SetAtlas("icons_16x16_curse")
  f.curse:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  f.curse:Hide()
  f.poison = f:CreateTexture(nil, "OVERLAY")
  f.poison:SetSize(16, 16)
  f.poison:SetAtlas("icons_16x16_poison")
  f.poison:SetPoint("TOPLEFT", f.curse, "BOTTOMLEFT", 0, -2)
  f.poison:Hide()
  f:Hide()
  row.dispelFrame = f
  return f
end

local function updateDispels(row, pull, enemies)
  if not row then return end
  local f = ensureDispelFrame(row)
  local curse, poison = pullHasDispel(pull, enemies)
  -- top-flush with the lust icon so the whole band shares one top line
  local yOff = 0
  f:ClearAllPoints()
  if row.lustFrame then
    f:SetPoint("TOPLEFT", row.lustFrame, "TOPRIGHT", 4, yOff)
  else
    f:SetPoint("TOPLEFT", row, "TOPLEFT", 0, yOff)
  end
  if curse then f.curse:Show() else f.curse:Hide() end
  if poison then
    f.poison:ClearAllPoints()
    if curse then
      f.poison:SetPoint("TOPLEFT", f.curse, "BOTTOMLEFT", 0, -2)
    else
      f.poison:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    end
    f.poison:Show()
  else
    f.poison:Hide()
  end
  if curse or poison then f:Show() else f:Hide() end
end

local function hideDispels(row)
  if row and row.dispelFrame then row.dispelFrame:Hide() end
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
    if MDT_NPT.CooldownLust then MDT_NPT.CooldownLust:Hide(showRow) end
    hideDispels(showRow)
    frame:SetCdBandShown(false)
    return
  end

  local uid = CooldownData.getPlanKey(state)
  local pullIndex = state and state.currentNextPull
  if not uid or not pullIndex then
    showRow:Hide(); nextRow:Hide()
    if MDT_NPT.CooldownLust then MDT_NPT.CooldownLust:Hide(showRow) end
    hideDispels(showRow)
    frame:SetCdBandShown(false)
    return
  end

  local pull = preset and preset.value and preset.value.pulls and preset.value.pulls[pullIndex]
  local dungeonIndex = (state and state.dungeonIndex) or (preset and preset.value and preset.value.currentDungeonIdx)
  local enemies = MDT.dungeonEnemies and MDT.dungeonEnemies[dungeonIndex]
  local matched, hasStored = CooldownPlan:VerifyFingerprint(uid, pullIndex, pull, enemies)
  local mismatch = hasStored and not matched

  local entries = CooldownData.getActiveEntries(dbChar, uid, pullIndex)
  showRow:Show()
  frame:SetCdBandShown(true)
  fillRow(showRow, entries, dbChar, mismatch, ICON_SIZE, true)
  -- bloodlust monitor to the right of the current-pull row
  if MDT_NPT.CooldownLust then MDT_NPT.CooldownLust:Update(showRow) end
  -- curse/poison preview to the right of the bloodlust monitor
  updateDispels(showRow, pull, enemies)

  -- next-pull preview row (design 11.4): nextPull+1, smaller, no CD
  local nextIndex = (nextPull or pullIndex) + 1
  local pullCount = state.pullStates and #state.pullStates or 0
  if nextIndex <= pullCount then
    local nextEntries = CooldownData.getActiveEntries(dbChar, uid, nextIndex)
    nextRow:Show()
    fillRow(nextRow, nextEntries, dbChar, false, NEXT_ICON_SIZE, false, nil, ICON_SIZE)
  else
    nextRow:Hide()
  end
end

MDT_NPT.CooldownPlanRender = Render
