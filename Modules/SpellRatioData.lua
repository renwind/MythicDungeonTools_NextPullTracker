local MDT_NPT = MDT_NPT
local CooldownData = MDT_NPT.CooldownData

local SpellRatioData = {}
local corruptionWarned = false

local function dbChar()
  return MDT_NPT:GetDBChar()
end

local function validUID(uid)
  return type(uid) == "string" and uid ~= ""
end

local function validInteger(value)
  return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

local function validPullIndex(pullIndex)
  return validInteger(pullIndex) and pullIndex >= 1
end

local function validRow(row)
  return type(row) == "table"
    and validInteger(row.elementalBlast)
    and validInteger(row.earthquake)
    and type(row.fingerprint) == "string"
end

local function warnCorruption()
  if corruptionWarned then return end
  corruptionWarned = true
  print("|cff00ff00[MDT]|r Spell ratio data was invalid and has been removed.")
end

function SpellRatioData:Get(uid, pullIndex)
  if not validUID(uid) or not validPullIndex(pullIndex) then return nil end
  local dc = dbChar()
  local ratios = dc and dc.rotationRatios
  local byUID = type(ratios) == "table" and ratios[uid] or nil
  if type(byUID) ~= "table" then return nil end

  local stored = byUID[pullIndex]
  if stored == nil then return nil end
  if not validRow(stored) then
    byUID[pullIndex] = nil
    warnCorruption()
    return nil
  end
  return {
    elementalBlast = stored.elementalBlast,
    earthquake = stored.earthquake,
    fingerprint = stored.fingerprint,
  }
end

function SpellRatioData:Set(uid, pullIndex, elementalBlast, earthquake, fingerprint)
  if not validUID(uid) or not validPullIndex(pullIndex)
    or not validInteger(elementalBlast) or not validInteger(earthquake)
    or type(fingerprint) ~= "string" then
    return false
  end

  local dc = dbChar()
  if not dc then return false end
  if type(dc.rotationRatios) ~= "table" then dc.rotationRatios = {} end
  if type(dc.rotationRatios[uid]) ~= "table" then dc.rotationRatios[uid] = {} end
  dc.rotationRatios[uid][pullIndex] = {
    elementalBlast = elementalBlast,
    earthquake = earthquake,
    fingerprint = fingerprint,
  }
  return true
end

function SpellRatioData:ReplaceRoute(uid, rows)
  if not validUID(uid) or type(rows) ~= "table" then return false end

  local replacement = {}
  for pullIndex, stored in pairs(rows) do
    if not validPullIndex(pullIndex) or not validRow(stored) then return false end
    replacement[pullIndex] = {
      elementalBlast = stored.elementalBlast,
      earthquake = stored.earthquake,
      fingerprint = stored.fingerprint,
    }
  end

  local dc = dbChar()
  if not dc then return false end
  if type(dc.rotationRatios) ~= "table" then dc.rotationRatios = {} end
  dc.rotationRatios[uid] = replacement
  return true
end

function SpellRatioData:Verify(uid, pullIndex, pull, enemies)
  local stored = self:Get(uid, pullIndex)
  if not stored or not CooldownData or type(CooldownData.computePullFingerprint) ~= "function" then
    return false
  end
  local live = CooldownData.computePullFingerprint(pull, enemies)
  return live ~= nil and live == stored.fingerprint
end

--- 文字用的十等分，不 clamp；液位请改用 FillTenths（双方非零时各占至少一档）。
function SpellRatioData:RatioTenths(row)
  if type(row) ~= "table" or not validInteger(row.elementalBlast)
    or not validInteger(row.earthquake) then
    return nil
  end
  local total = row.elementalBlast + row.earthquake
  if total == 0 then return nil end
  local elementalBlast = math.floor(row.elementalBlast / total * 10 + 0.5)
  return {
    elementalBlast = elementalBlast,
    earthquake = 10 - elementalBlast,
  }
end

--- 液位用的十等分。与 RatioTenths 刻意不同：双方原始次数都非零时各自 clamp 到
-- 1..9，保证任一侧只要真的施放过就至少占一档；单侧为零时仍允许 0/10。
-- 文字用 RatioTenths（不 clamp），所以 1/46 的液位是 1:9 而文字是 0:10。
function SpellRatioData:FillTenths(row)
  if type(row) ~= "table" or not validInteger(row.elementalBlast)
    or not validInteger(row.earthquake) then
    return nil
  end
  local total = row.elementalBlast + row.earthquake
  if total == 0 then return nil end
  local elementalBlast = math.floor(row.elementalBlast / total * 10 + 0.5)
  if row.elementalBlast > 0 and row.earthquake > 0 then
    elementalBlast = math.max(1, math.min(9, elementalBlast))
  end
  return {
    elementalBlast = elementalBlast,
    earthquake = 10 - elementalBlast,
  }
end

MDT_NPT.SpellRatioData = SpellRatioData
