local MDT_NPT = MDT_NPT
local Theme = MDT_NPT.Theme

-- CooldownLust: bloodlust monitor shown at the LEFT end of the cooldown-plan icon
-- row (where the plan icons used to start; plan icons are now right-aligned).
-- Shows when bloodlust becomes usable/effective again = max(sated-family debuff remaining,
-- own bloodlust CD remaining), to avoid casting bloodlust while sated.
-- Reference: GearInsight KeyTimeline.lua lustReadyIn().
local Lust = {}

local function getPixelSize(frame)
  local scale = frame:GetEffectiveScale()
  return 768 / (select(2, GetPhysicalScreenSize()) * scale)
end

local function createIconBorder(cell)
  local px = getPixelSize(cell)
  local r, g, b, a = 0, 0, 0, 1

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

-- Bloodlust-family buffs (first known wins). Reference: GearInsight LiveGuide LUST_BUFFS.
local BLOODLUST_SPELLS = { 2825, 32182, 80353, 264667, 390386 }  -- 嗜血/英勇/时间扭曲/原始狂怒/飞龙振翅
-- Sated-family debuffs (筋疲力尽/心满意足/时空错位/疲惫). Reference: GearInsight SATED.
local SATED = { 57724, 57723, 80354, 264689 }

local function isSecret(v)
  return v == nil or v ~= v or v < 0 or v > 1e9
end

local function hasAnyAura(ids)
  if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil end
  for _, id in ipairs(ids) do
    local a = C_UnitAuras.GetPlayerAuraBySpellID(id)
    if a then return a end
  end
  return nil
end

local function getBloodlustID()
  for _, id in ipairs(BLOODLUST_SPELLS) do
    if C_SpellBook.IsSpellInSpellBook(id, Enum.SpellBookSpellBank.Player, true) then
      return id
    end
  end
  return nil
end

-- Seconds until bloodlust is usable/effective again (0 = ready now). Reference lustReadyIn.
local function lustReadyIn()
  local r = 0
  local now = GetTime()
  local sated = hasAnyAura(SATED)
  if sated and sated.expirationTime and not isSecret(sated.expirationTime) then
    r = math.max(r, sated.expirationTime - now)
  end
  local sid = getBloodlustID()
  if sid and C_Spell and C_Spell.GetSpellCooldown then
    local cd = C_Spell.GetSpellCooldown(sid)
    if cd and cd.duration and cd.duration > 2 then
      r = math.max(r, (cd.startTime or 0) + cd.duration - now)
    end
  end
  return r, sid
end

local function formatReady(r)
  if r > 60 then
    -- round to nearest 0.5m (30s): 90s -> 1.5m, 100s -> 1.5m, 140s -> 2.5m
    local halves = math.floor(r / 30 + 0.5)
    if halves % 2 == 0 then return string.format("%dm", halves / 2) end
    return string.format("%d.5m", (halves - 1) / 2)
  end
  return string.format("%d", math.ceil(r))
end

local function ensureLustFrame(parent)
  if parent.lustFrame then return parent.lustFrame end
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(36, 36)  -- 1.5x the 24px plan icon size
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints(f)
  f.bg:SetColorTexture(0.06, 0.06, 0.06, 0.9)
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetAllPoints(f)
  f.icon:SetTexCoord(0.055, 0.945, 0.055, 0.945)
  createIconBorder(f)
  f.text = f:CreateFontString(nil, "OVERLAY", Theme.fonts.cdText)
  -- bump the countdown 7pt above the shared cdText size (it sits under a 36px icon)
  local lf, ls, lo = f.text:GetFont()
  if lf then f.text:SetFont(lf, ls + 7, lo) end
  f.text:SetPoint("TOP", f, "BOTTOM", 0, 0)
  f.text:SetShadowColor(unpack(Theme.colors.shadow))
  f.text:SetShadowOffset(1, -1)
  parent.lustFrame = f
  return f
end

local ticker

-- Update the lust indicator anchored to the left end of the current-pull icon row.
function Lust:Update(rowFrame)
  if not rowFrame then return end
  local f = ensureLustFrame(rowFrame)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 0, 0)
  local ready, sid = lustReadyIn()
  local icon = sid and C_Spell.GetSpellTexture(sid) or "Interface\\ICONS\\Spell_Shaman_Bloodlust"
  f.icon:SetTexture(icon or "Interface\\ICONS\\Spell_Shaman_Bloodlust")
  f.icon:SetTexCoord(0.055, 0.945, 0.055, 0.945)
  if ready > 0 then
    f.icon:SetVertexColor(1, 1, 1, 1)
    f.icon:SetAlpha(1)  -- stay opaque; the red countdown text carries the "not ready" state
    f.text:SetText(formatReady(ready))
    local ln = Theme.colors.lustNotReady
    f.text:SetTextColor(ln[1], ln[2], ln[3], ln[4])
  else
    local lr = Theme.colors.lustReady
    f.icon:SetVertexColor(lr[1], lr[2], lr[3], lr[4])
    f.icon:SetAlpha(1)
    f.text:SetText("")
  end
  f:Show()
  if not ticker then
    ticker = C_Timer.NewTicker(0.5, function()
      if rowFrame and rowFrame.lustFrame and rowFrame.lustFrame:IsShown() then
        local r2, sid2 = lustReadyIn()
        local ic = sid2 and C_Spell.GetSpellTexture(sid2) or "Interface\\ICONS\\Spell_Shaman_Bloodlust"
        rowFrame.lustFrame.icon:SetTexture(ic or "Interface\\ICONS\\Spell_Shaman_Bloodlust")
        rowFrame.lustFrame.icon:SetTexCoord(0.055, 0.945, 0.055, 0.945)
        if r2 > 0 then
          rowFrame.lustFrame.icon:SetVertexColor(1, 1, 1, 1)
          rowFrame.lustFrame.icon:SetAlpha(1)
          rowFrame.lustFrame.text:SetText(formatReady(r2))
          local ln = Theme.colors.lustNotReady
          rowFrame.lustFrame.text:SetTextColor(ln[1], ln[2], ln[3], ln[4])
        else
          local lr = Theme.colors.lustReady
          rowFrame.lustFrame.icon:SetVertexColor(lr[1], lr[2], lr[3], lr[4])
          rowFrame.lustFrame.icon:SetAlpha(1)
          rowFrame.lustFrame.text:SetText("")
        end
      end
    end)
  end
end

function Lust:Hide(rowFrame)
  if rowFrame and rowFrame.lustFrame then rowFrame.lustFrame:Hide() end
end

MDT_NPT.CooldownLust = Lust
