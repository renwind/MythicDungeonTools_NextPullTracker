-- Modules/ImportPlan.lua
-- 纯逻辑：解析 /npt importplan 的 entrySpec，并把计划写入当前 MDT 预设 uid。
-- fingerprint 在游戏内现算（CooldownData.computePullFingerprint），不跨端传输，
-- 保证与 VerifyFingerprint 的 live 计算逐字节一致。
local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT

local CooldownData = MDT_NPT.CooldownData
local CooldownPlan = MDT_NPT.CooldownPlan

-- 注意是 table.concat：string.concat 不是标准 Lua（WoW 里它的行为是把两个参数直接
-- ..，传表会报 "attempt to concatenate a table value"；本地 fengari 根本没有它，
-- 曾被 minibusted 的 polyfill 掩盖过）。
local string_format, string_concat, table_sort = string.format, table.concat, table.sort

local ImportPlan = {}

local VALID_KIND = { spell = true, item = true }
local VALID_ACTION = { use = true, save = true }
local HEX_DIGITS = "0123456789abcdef"

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
  -- 手写 hex，不用 string.format("%08x")：hash 可达 2^32-1，而各 Lua 版本对 %x 的
  -- 整数语义不一致（5.1 按 unsigned int 截断、5.3 要求 integer、fengari 对 >=2^31 报错），
  -- 手动逐位取能保证 5.1（游戏/CI）与 5.3/fengari（本地）输出逐字节相同。
  local hex = ""
  for i = 7, 0, -1 do
    local digit = math.floor(hash / 16 ^ i) % 16
    hex = hex .. HEX_DIGITS:sub(digit + 1, digit + 1)
  end
  return hex
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

-- planPack 语法（整包导入，一条聊天行）: "波:l<次>a<次>p<次>;波:..."
-- 字母 = l 嗜血(32182 spell) / a 升腾(114050 spell) / p 药水(241308 item)；
-- 次数 1-5（0 不写）、每波每字母至多一次、字母顺序任意（导出侧固定 l,a,p）。
-- 与 tools/wclplan/plan.js buildPlanPack 互为镜像：同一条串两侧解析结果必须一致。
local PACK_SKILL = {
  l = { id = 32182, kind = "spell" },
  a = { id = 114050, kind = "spell" },
  p = { id = 241308, kind = "item" },
}
local PACK_ORDER = { "l", "a", "p" }

---@return table|nil waves, string|nil err   waves[i] = { wave = n, spec = entrySpec }
function ImportPlan.parsePlanPack(pack)
  if type(pack) ~= "string" or pack == "" then return nil, "empty pack" end
  local waves = {}
  for token in pack:gmatch("[^;]+") do
    local waveText, body = token:match("^(%d+):(.+)$")
    local wave = tonumber(waveText or "")
    if not wave or wave < 1 or wave % 1 ~= 0 then
      return nil, "bad wave in token: " .. token
    end
    local seen, counts = {}, {}
    for letter, countText in body:gmatch("([lap])(%d)") do
      local count = tonumber(countText)
      if seen[letter] then return nil, "duplicate skill in token: " .. token end
      if not count or count < 1 or count > 5 then return nil, "bad count in token: " .. token end
      seen[letter] = true
      counts[letter] = count
    end
    if body:gsub("[lap]%d", "") ~= "" then
      return nil, "bad body in token: " .. token
    end
    local spec = {}
    for _, letter in ipairs(PACK_ORDER) do
      local count = counts[letter]
      if count then
        local skill = PACK_SKILL[letter]
        spec[#spec + 1] = count >= 2
          and string_format("%d:%s:use:%d", skill.id, skill.kind, count)
          or string_format("%d:%s:use", skill.id, skill.kind)
      end
    end
    if #spec == 0 then return nil, "empty body in token: " .. token end
    waves[#waves + 1] = { wave = wave, spec = string_concat(spec, ";") }
  end
  if #waves == 0 then return nil, "empty pack" end
  return waves
end

-- 整包写入：先校验 routeKey 与全部波号，再逐波 apply，避免半套计划落库。
---@return boolean ok, string|nil err, number|nil imported
function ImportPlan:applyPack(pack, routeKey)
  local waves, parseErr = ImportPlan.parsePlanPack(pack)
  if not waves then return false, parseErr end
  if type(routeKey) ~= "string" or #routeKey == 0 then
    return false, "missing route key"
  end

  local preset = MDT and MDT.GetCurrentPreset and MDT:GetCurrentPreset()
  if not preset or not preset.uid or preset.uid == "" then
    return false, "no current preset uid; import the MDT route first"
  end
  local pulls = preset.value and preset.value.pulls
  if not pulls then return false, "current preset has no pulls" end
  local liveKey = ImportPlan.computeRouteKey(pulls)
  if liveKey ~= routeKey then
    return false, "route key mismatch: pack says " .. routeKey .. ", current preset is " .. liveKey
  end
  local seenWave = {}
  for _, w in ipairs(waves) do
    if not pulls[w.wave] then return false, "preset has no pull " .. w.wave end
    if seenWave[w.wave] then return false, "duplicate wave in pack: " .. w.wave end
    seenWave[w.wave] = true
  end
  for _, w in ipairs(waves) do
    local ok, err = self:apply(w.wave, w.spec, routeKey)
    if not ok then return false, err end
  end
  return true, nil, #waves
end

MDT_NPT.ImportPlan = ImportPlan
