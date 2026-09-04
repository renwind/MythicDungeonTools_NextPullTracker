local MDT_NPT = MDT_NPT

-- CooldownLust: bloodlust monitor shown to the RIGHT of the cooldown-plan icon row.
-- Shows when bloodlust becomes usable/effective again = max(sated-family debuff remaining,
-- own bloodlust CD remaining), to avoid casting bloodlust while sated.
-- Reference: GearInsight KeyTimeline.lua lustReadyIn().
local Lust = {}

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

local function ensureLustFrame(parent)
  if parent.lustFrame then return parent.lustFrame end
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(24, 24)
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetAllPoints(f)
  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.text:SetPoint("TOP", f, "BOTTOM", 0, 0)
  local lf, ls, _ = f.text:GetFont()
  if lf then f.text:SetFont(lf, ls + 1, "OUTLINE") end
  f.text:SetShadowColor(0, 0, 0, 1)
  f.text:SetShadowOffset(1, -1)
  parent.lustFrame = f
  return f
end

local ticker

-- Update the lust indicator anchored to the right of the current-pull icon row.
function Lust:Update(rowFrame)
  if not rowFrame then return end
  local f = ensureLustFrame(rowFrame)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", rowFrame, "TOPRIGHT", 4, 0)
  local ready, sid = lustReadyIn()
  local icon = sid and C_Spell.GetSpellTexture(sid) or "Interface\\ICONS\\Spell_Shaman_Bloodlust"
  f.icon:SetTexture(icon or "Interface\\ICONS\\Spell_Shaman_Bloodlust")
  if ready > 0 then
    f.icon:SetVertexColor(1, 1, 1, 1)
    f.icon:SetAlpha(0.6)
    f.text:SetText(string.format("%d", math.ceil(ready)))
    f.text:SetTextColor(1, 0.3, 0.3, 1)  -- red: not usable yet (sated / on CD)
  else
    f.icon:SetVertexColor(0.6, 1, 0.6, 1)
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
        if r2 > 0 then
          rowFrame.lustFrame.icon:SetVertexColor(1, 1, 1, 1)
          rowFrame.lustFrame.icon:SetAlpha(0.6)
          rowFrame.lustFrame.text:SetText(string.format("%d", math.ceil(r2)))
          rowFrame.lustFrame.text:SetTextColor(1, 0.3, 0.3, 1)
        else
          rowFrame.lustFrame.icon:SetVertexColor(0.6, 1, 0.6, 1)
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
