-- Modules/ImportPlan.lua
-- 纯逻辑：解析 /npt importplan 的 entrySpec，并把计划写入当前 MDT 预设 uid。
-- fingerprint 在游戏内现算（CooldownData.computePullFingerprint），不跨端传输，
-- 保证与 VerifyFingerprint 的 live 计算逐字节一致。
local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT

local CooldownData = MDT_NPT.CooldownData
local CooldownPlan = MDT_NPT.CooldownPlan

local string_format, string_concat, table_sort = string.format, string.concat, table.sort

local ImportPlan = {}

local VALID_KIND = { spell = true, item = true }
local VALID_ACTION = { use = true, save = true }

-- entrySpec 语法: "id:kind:action[:uses]" 多条以 ";" 分隔。
-- uses=1 不存（读侧缺省即 1）；>=2 才保留，与 CooldownPlan:SetUses 语义一致。
---@return table|nil entries, string|nil err
function ImportPlan.parseEntrySpec(spec)
  local entries = {}
  if spec == nil or spec == "" then return entries end
  for token in spec:gmatch("[^;]+") do
    local idText, kind, action, usesText = token:match("^([^:]+):([^:]+):([^:]+):?([^:]*)$")
    if not idText then
      return nil, "bad token: " .. token
    end
    local id = tonumber(idText)
    if not id then return nil, "bad id in token: " .. token end
    if not VALID_KIND[kind] then return nil, "bad kind in token: " .. token end
    if not VALID_ACTION[action] then return nil, "bad action in token: " .. token end
    local entry = { id = id, kind = kind, action = action }
    if usesText ~= "" then
      local uses = tonumber(usesText)
      if not uses or uses < 1 or uses > 5 then return nil, "bad uses in token: " .. token end
      if uses >= 2 then entry.uses = math.floor(uses) end
    end
    entries[#entries + 1] = entry
  end
  return entries
end

-- routeKey：防「粘行时当前预设不是目标路线」的配对校验码。
-- 与 tools/wclplan/plan.js computeRouteKey 逐字节同公式：
-- 每波 "idx:count" 字典序排序逗号连接、波间分号连接，(hash*31+byte) mod 2^32，%08x。
-- 刻意不复用 computePullFingerprint：那个要 enemies 表且会跳过未知 enemyIndex，
-- 而 routeKey 必须离线/游戏内两侧算出同一个值。
local function pullKey(pull)
  local parts = {}
  for key, clones in pairs(pull or {}) do
    local idx = tonumber(key)
    if idx and idx % 1 == 0 and type(clones) == "table" then
      parts[#parts + 1] = string_format("%d:%d", idx, #clones)
    end
  end
  table_sort(parts)
  return string_concat(parts, ",")
end

function ImportPlan.computeRouteKey(pulls)
  local joined = {}
  for i = 1, #pulls do joined[i] = pullKey(pulls[i]) end
  local s = string_concat(joined, ";")
  local hash = 0
  for i = 1, #s do
    hash = (hash * 31 + s:byte(i)) % 4294967296
  end
  return string_format("%08x", hash)
end

---@return boolean ok, string|nil err
function ImportPlan:apply(wave, entrySpec, routeKey)
  local entries, parseErr = ImportPlan.parseEntrySpec(entrySpec)
  if not entries then return false, parseErr end
  if type(wave) ~= "number" or wave < 1 or wave % 1 ~= 0 then
    return false, "wave must be a positive integer"
  end
  if type(routeKey) ~= "string" or #routeKey == 0 then
    return false, "missing route key"
  end

  local preset = MDT and MDT.GetCurrentPreset and MDT:GetCurrentPreset()
  if not preset or not preset.uid or preset.uid == "" then
    return false, "no current preset uid; import the MDT route first"
  end
  local pulls = preset.value and preset.value.pulls
  local pull = pulls and pulls[wave]
  if not pull then
    return false, "preset has no pull " .. wave
  end
  local liveKey = ImportPlan.computeRouteKey(pulls)
  if liveKey ~= routeKey then
    return false, "route key mismatch: line says " .. routeKey .. ", current preset is " .. liveKey
  end
  local enemies = MDT.dungeonEnemies and MDT.dungeonEnemies[preset.value.currentDungeonIdx]

  for _, entry in ipairs(entries) do
    CooldownPlan:SetEntry(preset.uid, wave, entry.id, entry.kind, entry.action)
    if entry.uses then
      CooldownPlan:SetUses(preset.uid, wave, entry.id, entry.uses)
    end
  end
  CooldownPlan:SetFingerprint(preset.uid, wave, CooldownData.computePullFingerprint(pull, enemies))
  return true
end

MDT_NPT.ImportPlan = ImportPlan
