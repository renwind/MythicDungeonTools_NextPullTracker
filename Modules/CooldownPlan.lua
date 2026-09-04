local MDT_NPT = MDT_NPT

local CooldownData = MDT_NPT.CooldownData

-- CooldownPlan: CRUD over dbChar.cooldownPlans[uid][pullIndex] (design 5.2/5.3).
local CooldownPlan = {}

local function dbChar()
  return MDT_NPT:GetDBChar()
end

local function ensurePlan(uid, pullIndex)
  local dc = dbChar()
  if not dc or not uid or not pullIndex then return nil end
  dc.cooldownPlans = dc.cooldownPlans or {}
  dc.cooldownPlans[uid] = dc.cooldownPlans[uid] or {}
  dc.cooldownPlans[uid][pullIndex] = dc.cooldownPlans[uid][pullIndex] or { entries = {}, fingerprint = nil }
  return dc.cooldownPlans[uid][pullIndex]
end

-- Get the stored plan (sanitized). nil when absent / uid invalid.
function CooldownPlan:Get(uid, pullIndex)
  return CooldownData.getPullPlan(dbChar(), uid, pullIndex)
end

-- Set (or overwrite) one entry's action for a given id/kind.
-- @param id number spellID or itemID
-- @param kind string "spell"|"item"
-- @param action string "use"|"save"
function CooldownPlan:SetEntry(uid, pullIndex, id, kind, action)
  local plan = ensurePlan(uid, pullIndex)
  if not plan or not id or not action then return false end
  plan.entries = plan.entries or {}
  for _, e in ipairs(plan.entries) do
    if e.id == id then
      e.action = action
      e.kind = kind or e.kind
      return true
    end
  end
  table.insert(plan.entries, { id = id, kind = kind or "spell", action = action })
  return true
end

-- Remove one entry by id.
function CooldownPlan:ClearEntry(uid, pullIndex, id)
  local plan = CooldownData.getPullPlan(dbChar(), uid, pullIndex)
  if not plan or not plan.entries or not id then return false end
  for i = #plan.entries, 1, -1 do
    if plan.entries[i].id == id then
      table.remove(plan.entries, i)
      return true
    end
  end
  return false
end

-- Clear all entries for a pull.
function CooldownPlan:ClearPull(uid, pullIndex)
  local dc = dbChar()
  if not dc or not uid or not pullIndex then return false end
  if dc.cooldownPlans and dc.cooldownPlans[uid] then
    dc.cooldownPlans[uid][pullIndex] = nil
    return true
  end
  return false
end

-- Store the fingerprint computed at plan-build time (design 5.5).
function CooldownPlan:SetFingerprint(uid, pullIndex, fingerprint)
  local plan = ensurePlan(uid, pullIndex)
  if not plan then return false end
  plan.fingerprint = fingerprint
  return true
end

-- Verify a live pull against the stored fingerprint.
-- @return boolean matched, boolean hasStored  (no stored fingerprint => matched=true, design 5.5)
function CooldownPlan:VerifyFingerprint(uid, pullIndex, pull, enemies)
  local plan = CooldownData.getPullPlan(dbChar(), uid, pullIndex)
  if not plan or plan.fingerprint == nil then
    return true, false
  end
  local live = CooldownData.computePullFingerprint(pull, enemies)
  -- live fingerprint uncomputable (pull structure differs) => no data, do NOT warn mismatch
  if live == nil then
    return true, false
  end
  return (live == plan.fingerprint), true
end

MDT_NPT.CooldownPlan = CooldownPlan
