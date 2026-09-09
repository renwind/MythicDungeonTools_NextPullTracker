--- PullNotes.lua — per-wave user notes (design: NPT 波次注释功能, 2026-09-09).
--
-- Pure-logic module with no frames and no WoW UI calls, so everything here is
-- busted-testable. Sibling to NpcNotes (per-mob notes): the two share the
-- escape-aware truncate / mrtToNative helpers but keep separate storage, since
-- their keys mean different things.
--   * NpcNotes  — keyed by NPC id, follows a mob across every route
--   * PullNotes — keyed by preset uid + pull index, follows one route's wave
--
-- Responsibilities:
--   * locate        — resolve (uid, pullIndex) from live state, nil-degrading
--   * fingerprintOf — wave-content fingerprint, immune to MDT's ghost pull keys
--   * get/set/clear — db.global.pullNotes[uid][pullIndex] access
--
-- Drift: MDT route edits shift every later pullIndex, so a stored note can end
-- up attached to the wrong wave. Each write therefore snapshots the wave's
-- fingerprint and reads compare it, reporting matched=false so the renderer can
-- flag the strip rather than silently show stale tactics mid-key. Flagging only
-- — never auto-relocating, because two identical waves share a fingerprint and
-- guessing would attach the note to the wrong one.

local _, MDT_NPT = ...
local PullNotes = {}
MDT_NPT.PullNotes = PullNotes

---------------------------------------------------------------------------
-- Storage helpers
---------------------------------------------------------------------------

local function getDB()
  if MDT_NPT.GetDB then
    local ok, db = pcall(MDT_NPT.GetDB, MDT_NPT)
    if ok and type(db) == "table" then return db end
  end
  return nil
end

---True for a usable preset uid (same guard CooldownData.getPlanKey applies).
local function validUID(uid)
  return type(uid) == "string" and uid ~= ""
end

---True for a pull-table value that represents real mobs. MDT leaves enemy keys
---behind after route edits with the clone list emptied (observed 10 keys for a
---2-mob wave); same gate as renderEnemiesPortraits and NpcNotes.collectForPull.
local function hasClones(clones)
  return (type(clones) == "table" and #clones > 0) or type(clones) == "number"
end

---------------------------------------------------------------------------
-- Key resolution
---------------------------------------------------------------------------

---Resolves the storage key pair from live tracking state. Returns nil when
---tracking is not running or the preset uid is unavailable, so every caller
---degrades to read-only instead of writing under a bogus key.
---@return string|nil uid, number|nil pullIndex
function PullNotes.locate(state)
  local uid = state and state.presetUID
  if not validUID(uid) then return nil end
  local pullIndex = state and state.currentNextPull
  if type(pullIndex) ~= "number" then return nil end
  return uid, pullIndex
end

---------------------------------------------------------------------------
-- Wave fingerprint
---------------------------------------------------------------------------

---Wave-content fingerprint: sorted "enemyIndex:cloneCount" pairs.
---
---Deliberately NOT CooldownData.computePullFingerprint. That one counts every
---key in the pull table, ghost keys included, so plain MDT housekeeping would
---read as a content change and flag every stored note as drifted. Fixing it
---there is not an option either: stored cooldownPlans fingerprints depend on
---its exact current output.
---@return string|nil nil when the wave has no real content to compare
function PullNotes.fingerprintOf(pull, enemies)
  if type(pull) ~= "table" then return nil end
  local parts = {}
  for enemyIndex, clones in pairs(pull) do
    local idx = tonumber(enemyIndex)
    if idx and hasClones(clones) and enemies and enemies[enemyIndex] then
      local count = (type(clones) == "table") and #clones or 1
      parts[#parts + 1] = string.format("%d:%d", idx, count)
    end
  end
  if #parts == 0 then return nil end
  table.sort(parts)
  return table.concat(parts, ",")
end

---------------------------------------------------------------------------
-- CRUD (db.global.pullNotes[uid][pullIndex])
---------------------------------------------------------------------------

---Reads the note stored for one wave.
---
---`pull`/`enemies` are optional: omit them to skip the fingerprint check
---(matched comes back true), which is what the edit popup's prefill wants.
---Pass all four when rendering, so a drifted note can be flagged.
---@return string|nil text, boolean matched
function PullNotes.get(uid, pullIndex, pull, enemies)
  if not (validUID(uid) and type(pullIndex) == "number") then return nil, true end
  local db = getDB()
  local byUID = db and db.pullNotes
  if type(byUID) ~= "table" then return nil, true end
  local byPull = byUID[uid]
  if type(byPull) ~= "table" then return nil, true end
  local rec = byPull[pullIndex]
  if type(rec) ~= "table" or type(rec.text) ~= "string" then return nil, true end
  -- No stored fingerprint (written before the field existed, or a wave whose
  -- content could not be fingerprinted) => no basis to claim drift.
  if rec.fingerprint == nil then return rec.text, true end
  local live = PullNotes.fingerprintOf(pull, enemies)
  -- Live fingerprint uncomputable (empty/odd pull) => stay silent, same
  -- direction as CooldownPlan:VerifyFingerprint.
  if live == nil then return rec.text, true end
  return rec.text, (live == rec.fingerprint)
end

---Stores `text` for one wave, snapshotting the current fingerprint so a later
---route edit stays detectable. The empty string clears, matching NpcNotes.set.
---Never caches the db reference, so it follows the login timeline.
---@return boolean true when written or cleared
function PullNotes.set(uid, pullIndex, text, pull, enemies)
  if not (validUID(uid) and type(pullIndex) == "number") then return false end
  local db = getDB()
  if not db then return false end
  if text == "" then text = nil end
  if type(db.pullNotes) ~= "table" then db.pullNotes = {} end
  if text == nil then
    if type(db.pullNotes[uid]) == "table" then db.pullNotes[uid][pullIndex] = nil end
    return true
  end
  if type(db.pullNotes[uid]) ~= "table" then db.pullNotes[uid] = {} end
  db.pullNotes[uid][pullIndex] = {
    text = text,
    fingerprint = PullNotes.fingerprintOf(pull, enemies),
  }
  return true
end

---Removes the note (and its fingerprint) for one wave.
---@return boolean
function PullNotes.clear(uid, pullIndex)
  return PullNotes.set(uid, pullIndex, nil)
end
