local MDT_NPT = MDT_NPT
local ImportPlan = MDT_NPT.ImportPlan
local CooldownData = MDT_NPT.CooldownData
local SpellRatioData = MDT_NPT.SpellRatioData

local ImportRatio = {}
local MAX_SAFE_INTEGER = 9007199254740991.0

local function decodeBase36(text)
  local value = 0.0
  for index = 1, #text do
    local byte = text:byte(index)
    local digit
    if byte >= 48 and byte <= 57 then
      digit = byte - 48
    elseif byte >= 97 and byte <= 122 then
      digit = byte - 87
    else
      return nil
    end
    if value > math.floor((MAX_SAFE_INTEGER - digit) / 36) then return nil end
    value = value * 36 + digit
  end
  return value
end

function ImportRatio.parsePack(pack)
  if type(pack) ~= "string" or pack == "" then return nil, "empty pack" end
  if pack:sub(1, 1) == "," or pack:sub(-1) == "," or pack:find(",,", 1, true) then
    return nil, "bad pack separators"
  end

  local rows = {}
  for token in pack:gmatch("[^,]+") do
    local elementalText, earthquakeText = token:match("^([0-9a-z]+)%.([0-9a-z]+)$")
    local elementalBlast = elementalText and decodeBase36(elementalText)
    local earthquake = earthquakeText and decodeBase36(earthquakeText)
    if elementalBlast == nil or earthquake == nil then return nil, "bad token: " .. token end
    rows[#rows + 1] = {
      wave = #rows + 1,
      elementalBlast = elementalBlast,
      earthquake = earthquake,
    }
  end
  if #rows == 0 then return nil, "empty pack" end
  return rows
end

function ImportRatio:applyPack(pack, routeKey)
  local mdt = MDT_NPT.MDT or MDT
  local preset = mdt and mdt.GetCurrentPreset and mdt:GetCurrentPreset()
  if not preset or type(preset.uid) ~= "string" or preset.uid == "" then
    return false, "no current preset uid; import the MDT route first"
  end

  local pulls = preset.value and preset.value.pulls
  if type(pulls) ~= "table" or #pulls == 0 then
    return false, "current preset has no pulls"
  end
  if type(routeKey) ~= "string" or routeKey == "" then
    return false, "missing route key"
  end

  local liveKey = ImportPlan.computeRouteKey(pulls)
  if liveKey ~= routeKey then
    return false, "route key mismatch: pack says " .. routeKey .. ", current preset is " .. liveKey
  end

  local rows, parseErr = ImportRatio.parsePack(pack)
  if not rows then return false, parseErr end
  if #rows ~= #pulls then
    return false, "pack token count " .. #rows .. " does not match pull count " .. #pulls
  end

  local enemies = mdt.dungeonEnemies and mdt.dungeonEnemies[preset.value.currentDungeonIdx]
  local replacement = {}
  for wave = 1, #pulls do
    local row = rows[wave]
    replacement[wave] = {
      elementalBlast = row.elementalBlast,
      earthquake = row.earthquake,
      fingerprint = CooldownData.computePullFingerprint(pulls[wave], enemies),
    }
  end

  if not SpellRatioData:ReplaceRoute(preset.uid, replacement) then
    return false, "ratio storage unavailable"
  end
  return true, nil, #rows
end

MDT_NPT.ImportRatio = ImportRatio
