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
-- Keep in sync with the Bloodlust seed id list in CooldownData.SEED_TABLE (2026-09-12).
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
-- 第三返回值 satedLeft 只算 debuff 一条腿（无 debuff 恒为 0）：预提醒不能拿 max 后的 ready 反推。
local function lustReadyIn()
  local r = 0
  local satedLeft = 0
  local now = GetTime()
  local sated = hasAnyAura(SATED)
  -- 12.x secret values: any comparison on a secret number hard-errors while
  -- execution is tainted, so every numeric probe runs inside pcall
  if sated and sated.expirationTime then
    pcall(function()
      if not isSecret(sated.expirationTime) then
        satedLeft = math.max(0, sated.expirationTime - now)
        r = math.max(r, satedLeft)
      end
    end)
  end
  local sid = getBloodlustID()
  if sid and C_Spell and C_Spell.GetSpellCooldown then
    local cd = C_Spell.GetSpellCooldown(sid)
    if cd and cd.isEnabled and cd.isActive then
      pcall(function()
        if cd.duration > 2 then
          r = math.max(r, cd.startTime + cd.duration - now)
        end
      end)
    end
  end
  return r, sid, satedLeft
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

-- 白底圆环贴图，运行时 SetVertexColor 染主题色（与 AlertBanner v3 同一套资产/路数）。
local ADDON_MEDIA = "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\"
local RING_GLOW = ADDON_MEDIA .. "ring_glow.png"

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
  -- 就绪脉冲环：36px 格外扩 ~4px、sublevel 3 盖过图标，默认隐藏，只在真就绪边沿播放。
  f.pulse = f:CreateTexture(nil, "OVERLAY", nil, 3)
  f.pulse:SetPoint("TOPLEFT", f, "TOPLEFT", -4, 4)
  f.pulse:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 4, -4)
  f.pulse:SetTexture(RING_GLOW)
  local lr0 = Theme.colors.lustReady
  f.pulse:SetVertexColor(lr0[1], lr0[2], lr0[3], lr0[4])
  f.pulse:Hide()
  -- AnimationGroup 没有 SetOnFinished，只能 SetScript("OnFinished", fn)（本机实测）。
  local ag = f:CreateAnimationGroup()
  -- 两次「亮 0.25s → 灭 0.75s」，orders 1-4；播完自动藏环，重触发时先 Stop 再 Play。
  local seq = { { 0, 1, 0.25 }, { 1, 0, 0.75 }, { 0, 1, 0.25 }, { 1, 0, 0.75 } }
  for i, s in ipairs(seq) do
    local a = ag:CreateAnimation("Alpha")
    a:SetOrder(i)
    a:SetFromAlpha(s[1])
    a:SetToAlpha(s[2])
    a:SetDuration(s[3])
  end
  ag:SetScript("OnFinished", function() f.pulse:Hide() end)
  f.pulseAnim = ag
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

-- 触发脉冲：停掉可能在播的上一轮再重头播，环显示出来交给 OnFinished 收尾藏回。
local function firePulse(f)
  if not (f and f.pulse and f.pulseAnim) then return end
  f.pulse:Show()
  f.pulseAnim:Stop()
  f.pulseAnim:Play()
end

-- 播报复用 CooldownAlert.play（路径解析/Master 声道不重造）；晚解引用，缺它时静默。
local function speak(key)
  if MDT_NPT.CooldownAlert then MDT_NPT.CooldownAlert.play(key) end
end

-- 边沿状态：nil = 未播种；可见后首次 sample 只播种，Hide() 重置回 nil 防隐藏期跨越被补播。
local prevReady, prevSated

-- 把图标/文字/染色按当前 ready 值刷新一遍（Update 与 0.5s 轮询共用）。
local function paintLustFrame(f, ready, sid)
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
end

-- 单次采样 = 刷新画面 + 边沿检测；Update 与 0.5s 轮询共用，不新建第二个 ticker。
local function sample(f)
  local ready, sid, satedLeft = lustReadyIn()
  paintLustFrame(f, ready, sid)

  if prevReady == nil or prevSated == nil then
    -- 播种：cell 刚可见时的第一次采样只记录基线，绝不触发（否则每次显示都会响）。
    prevReady, prevSated = ready, satedLeft
    return
  end

  -- 开关在触发时读取（与 CooldownAlert.fire() 同模式）：ADDON_LOADED 前 GetDB 可能是 nil。
  local db = MDT_NPT:GetDB()
  local beacon = db and db.beacon
  local alertOn = beacon and beacon.lustAlert

  -- 真就绪边沿：readyIn 从 >0 跨到 0（技能 CD 与精疲力尽都已清空），一次跨越只播一次。
  if alertOn and prevReady > 0 and ready <= 0 then
    speak("lust-ready")
    firePulse(f)
  end

  -- 预提醒：仅当 sated 是约束项（satedLeft>0 且 ==ready）且从 >30 跨到 <=30；不脉冲。
  if alertOn and satedLeft > 0 and satedLeft >= ready and prevSated > 30 and satedLeft <= 30 then
    speak("lust-sated-soon")
  end

  prevReady, prevSated = ready, satedLeft
end

local ticker

-- Update the lust indicator anchored to the left end of the current-pull icon row.
function Lust:Update(rowFrame)
  if not rowFrame then return end
  local f = ensureLustFrame(rowFrame)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 0, 0)
  f:Show()
  sample(f)
  if not ticker then
    ticker = C_Timer.NewTicker(0.5, function()
      if rowFrame and rowFrame.lustFrame and rowFrame.lustFrame:IsShown() then
        sample(rowFrame.lustFrame)
      end
    end)
  end
end

function Lust:Hide(rowFrame)
  if rowFrame and rowFrame.lustFrame then rowFrame.lustFrame:Hide() end
  -- 回到未播种态：隐藏期间发生的就绪/预提醒跨越不该在下次显示时补播。
  prevReady, prevSated = nil, nil
end

MDT_NPT.CooldownLust = Lust
