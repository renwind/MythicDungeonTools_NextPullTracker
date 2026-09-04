local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT

local tonumber, pairs, ipairs, tostring = tonumber, pairs, ipairs, tostring
local string_format, string_concat, table_sort = string.format, table.concat, table.sort

-- CooldownData: seed table, pull fingerprint, spec resolution, plan save/read, sanitize.
-- All plan data lives under dbChar.cooldownPlans[presetUID][pullIndex] (char scope, design 5.1/5.2).
local CooldownData = {}

-- Seed table: only long-CD, spec-relevant cooldowns worth per-pull planning (design 6.1).
-- Spell IDs are the dump-verified truth (simc SpellDataDump/shaman.txt); do not add undumped IDs.
local SEED_TABLE = {
  [262] = { -- Elemental Shaman
    {
      id       = { 114050, 1219480 }, -- Ascendance dual ID (talent-granted vs 12.x cast version)
      kind     = "spell",
      name     = "Ascendance",
      icon     = nil, -- resolved at runtime
      baseCD   = 180,
    },
    {
      id       = 79206, -- Spiritwalker's Grace
      kind     = "spell",
      name     = "Spiritwalker's Grace",
      icon     = nil,
      baseCD   = 120,
    },
    {
      id       = nil, -- filled at runtime from dbChar.cooldownPotionID
      kind     = "item",
      name     = "Burst Potion",
      icon     = nil,
      baseCD   = nil, -- potion CD comes from shared use-effect spell 1236616 (300s)
      defaultItemID = 241308,      -- Light's Potential (ilvl 295); out-of-the-box (design 6/Q1)
      useEffectSpellID = 1236616,  -- stable key for CD/icon across the 4 itemIDs (design 8.2/Q2)
    },
  },
}

-- Pull fingerprint: (enemyIndex, cloneCount) pairs, normalized + sorted (design 5.5).
-- enemyIndex may be a string-form number; tonumber() normalization is mandatory.
local function computePullFingerprint(pull, enemies)
  if not pull then return nil end
  local parts = {}
  for enemyIndex, clones in pairs(pull) do
    local idx = tonumber(enemyIndex)
    if idx and enemies and enemies[enemyIndex] then
      parts[#parts + 1] = string_format("%d:%d", idx, #clones)
    end
  end
  table_sort(parts)
  return string_concat(parts, ",")
end
CooldownData.computePullFingerprint = computePullFingerprint

-- Resolve which Ascendance spellID is usable at runtime (design 6.2).
local function resolveAscendanceID(idList)
  if type(idList) ~= "table" then return idList end
  for _, id in ipairs(idList) do
    local known = C_SpellBook.IsSpellInSpellBook(id, Enum.SpellBookSpellBank.Player, true)
    local icon  = C_Spell.GetSpellTexture(id)
    if known and icon then
      return id
    end
  end
  return idList[1]
end
CooldownData.resolveAscendanceID = resolveAscendanceID

-- Current spec's active seed entries (design 5.7). Non-supported spec -> {} (hide row).
local function getSeedEntries()
  local specIndex = C_SpecializationInfo.GetSpecialization()
  if not specIndex then return {} end
  local specID = C_SpecializationInfo.GetSpecializationInfo(specIndex)
  if not specID then return {} end
  return SEED_TABLE[specID] or {}
end
CooldownData.getSeedEntries = getSeedEntries

-- Plan key from state; nil uid -> nil (read-only degrade, design 5.6).
local function getPlanKey(state)
  local uid = state and state.presetUID
  if not uid or uid == "" then
    return nil
  end
  return uid
end
CooldownData.getPlanKey = getPlanKey

-- First-load init: fill dbChar.cooldownPotionID from seed defaultItemID when nil (design 8.2 step 1).
local function InitializePlans(dbChar)
  if not dbChar then return end
  dbChar.cooldownPlans = dbChar.cooldownPlans or {}
  if dbChar.cooldownPotionID == nil then
    local seed = SEED_TABLE[262]
    if seed then
      for _, entry in ipairs(seed) do
        if entry.kind == "item" and entry.defaultItemID then
          dbChar.cooldownPotionID = entry.defaultItemID
          break
        end
      end
    end
  end
  if dbChar._cooldownPlanVersion == nil then
    dbChar._cooldownPlanVersion = 1
  end
end
CooldownData.InitializePlans = InitializePlans

-- Entry sanitize (design 5.8): invalid kind/action/id -> nil + warn once.
local cooldownPlanCorruptionWarned = false
local ENTRY_SCHEMA = {
  kind   = { valid = { spell = true, item = true } },
  action = { valid = { use = true, save = true } },
  id     = { type = "number" },
}
local function sanitizePlanEntry(entry)
  if type(entry) ~= "table" then return nil end
  local fixed = false
  for key, rule in pairs(ENTRY_SCHEMA) do
    local v = entry[key]
    if rule.type and type(v) ~= rule.type then
      entry[key] = nil; fixed = true
    elseif rule.valid and not rule.valid[v] then
      entry[key] = nil; fixed = true
    end
  end
  if fixed and not cooldownPlanCorruptionWarned then
    cooldownPlanCorruptionWarned = true
    print("|cff00ff00[MDT]|r Cooldown plan entry had invalid fields; removed.")
  end
  return entry
end
CooldownData.sanitizePlanEntry = sanitizePlanEntry

-- Read the stored plan for a pull (sanitized). Returns nil when absent.
local function getPullPlan(dbChar, uid, pullIndex)
  if not dbChar or not uid or not pullIndex then return nil end
  local byUID = dbChar.cooldownPlans and dbChar.cooldownPlans[uid]
  if not byUID then return nil end
  local plan = byUID[pullIndex]
  if not plan then return nil end
  if plan.entries then
    for i = #plan.entries, 1, -1 do
      if not sanitizePlanEntry(plan.entries[i]) then
        table.remove(plan.entries, i)
      end
    end
  end
  return plan
end
CooldownData.getPullPlan = getPullPlan

-- Build the runtime active entries for a pull: seed x stored plan (design 5.7).
local function getActiveEntries(dbChar, uid, pullIndex)
  local seed = getSeedEntries()
  if not seed or #seed == 0 then return {} end
  local plan = getPullPlan(dbChar, uid, pullIndex)
  local result = {}
  for _, seedEntry in ipairs(seed) do
    local planEntry
    if plan and plan.entries then
      for _, e in ipairs(plan.entries) do
        local seedID = seedEntry.id
        local match = false
        if type(seedID) == "table" then
          for _, sid in ipairs(seedID) do
            if e.id == sid then match = true break end
          end
        else
          match = (e.id == seedID) or (seedEntry.kind == "item" and e.id == dbChar.cooldownPotionID)
        end
        if match then planEntry = e break end
      end
    end
    result[#result + 1] = { seed = seedEntry, plan = planEntry }
  end
  return result
end
CooldownData.getActiveEntries = getActiveEntries

MDT_NPT.CooldownData = CooldownData
