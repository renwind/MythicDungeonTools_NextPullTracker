--- NpcNotes.lua — per-NPC user notes (design: NPT 怪物注释功能, 2026-09-07).
--
-- Pure-logic module with no frames and no WoW UI calls, so everything here is
-- busted-testable. Responsibilities:
--   * keyFor         — stable note key from an MDT enemy (npc:<id> / name:<name>)
--   * get/set/clear  — db.global.npcNotes access, nil-safe before the db is up
--   * collectForPull — ordered, deduped, capped list of annotated mobs for the
--                      note-strip panel
--   * truncate       — escape-aware single-line display truncator: WoW escape
--                      sequences (|cXXXXXXXX / |r / |T..|t / |A..|a / |n) are
--                      atomic and never cut open; |n folds to a space; a cut
--                      inside an open |c segment closes it with |r so the
--                      ellipsis is not tinted.

local _, MDT_NPT = ...
local NpcNotes = {}
MDT_NPT.NpcNotes = NpcNotes

---Cap for collectForPull; mirrors the portrait area's PORTRAIT_MAX so the
---note strip panel never has more rows than the beacon has portrait slots.
local COLLECT_MAX = 8

---Default creature display id, same fallback the portrait area uses.
local DEFAULT_DISPLAY_ID = 39490

---------------------------------------------------------------------------
-- Key generation
---------------------------------------------------------------------------

---Stable key for an MDT dungeonEnemies entry: "npc:<id>" when an NPC id is
---available, else "name:<name>", else nil (caller skips the enemy entirely).
---The prefixes keep the two degenerate keyspaces from colliding, and tostring
---normalises string-typed ids so write and read paths always agree.
function NpcNotes.keyFor(enemy)
  if type(enemy) ~= "table" then return nil end
  if enemy.id ~= nil then
    local idStr = tostring(enemy.id)
    if idStr ~= "" then return "npc:" .. idStr end
  end
  if type(enemy.name) == "string" and enemy.name ~= "" then
    return "name:" .. enemy.name
  end
  return nil
end

---------------------------------------------------------------------------
-- Storage (db.global.npcNotes)
---------------------------------------------------------------------------

local function getDB()
  if MDT_NPT.GetDB then
    local ok, db = pcall(MDT_NPT.GetDB, MDT_NPT)
    if ok and type(db) == "table" then return db end
  end
  return nil
end

---Returns the stored note for `key`, or nil when absent / db not ready.
function NpcNotes.get(key)
  if type(key) ~= "string" then return nil end
  local db = getDB()
  local notes = db and db.npcNotes
  if type(notes) ~= "table" then return nil end
  return notes[key]
end

---Stores `text` under `key`. The empty string is treated as nil (cleared);
---never caches the db reference so it follows the login timeline.
function NpcNotes.set(key, text)
  if type(key) ~= "string" then return end
  local db = getDB()
  if not db then return end
  if text == "" then text = nil end
  if text == nil then
    if type(db.npcNotes) == "table" then db.npcNotes[key] = nil end
  else
    if type(db.npcNotes) ~= "table" then db.npcNotes = {} end
    db.npcNotes[key] = text
  end
end

---Removes the note for `key`.
function NpcNotes.clear(key)
  NpcNotes.set(key, nil)
end

---------------------------------------------------------------------------
-- Per-pull collection (note-strip panel data source)
---------------------------------------------------------------------------

---Collects annotated mobs for one pull. Iterates the pull's enemy indices
---(tonumber-filtered, same traversal as renderEnemiesPortraits), sorts them
---ascending so the strips never shuffle between renders, dedupes by key
---(clones of the same NPC share one note), and keeps at most COLLECT_MAX
---entries with a note. Each entry is { key, rawName, displayId, note }.
---@return table array (possibly empty)
function NpcNotes.collectForPull(pull, enemies)
  local result = {}
  if type(pull) ~= "table" or type(enemies) ~= "table" then return result end

  local indices = {}
  for enemyIndex in pairs(pull) do
    local n = tonumber(enemyIndex)
    if n and enemies[enemyIndex] then indices[#indices + 1] = n end
  end
  table.sort(indices)

  local seen = {}
  for i = 1, #indices do
    if #result >= COLLECT_MAX then break end
    local enemy = enemies[indices[i]]
    local key = NpcNotes.keyFor(enemy)
    if key and not seen[key] then
      seen[key] = true
      local note = NpcNotes.get(key)
      if note then
        result[#result + 1] = {
          key = key,
          rawName = enemy.name,
          displayId = enemy.displayId or DEFAULT_DISPLAY_ID,
          note = note,
        }
      end
    end
  end
  return result
end

---------------------------------------------------------------------------
-- Escape-aware truncation (note-strip single-line display)
---------------------------------------------------------------------------

---Splits text into atomic tokens for truncation.
--- * escape tokens: |cXXXXXXXX, |r, |n, |T...|t, |A...|a — count as zero
---   visible glyphs (|n counts one, it folds to a space on output)
--- * glyph tokens: one UTF-8 sequence each, counts as one visible glyph
--- * a '|' not followed by a known control char is a plain glyph (mirrors
---   WoW rendering a malformed sequence literally)
local function tokenize(text)
  local tokens = {}
  local i, len = 1, #text
  while i <= len do
    local b = text:byte(i)
    if b == 124 then -- '|'
      local c = text:sub(i + 1, i + 1)
      if c == "c" then
        local hex = text:sub(i + 2, i + 9)
        if #hex == 8 and hex:match("^[0-9a-fA-F]+$") then
          tokens[#tokens + 1] = { text = text:sub(i, i + 9), colorOpen = true }
          i = i + 10
        else
          tokens[#tokens + 1] = { text = "|", visible = 1 }
          i = i + 1
        end
      elseif c == "r" then
        tokens[#tokens + 1] = { text = text:sub(i, i + 1), colorClose = true }
        i = i + 2
      elseif c == "n" then
        tokens[#tokens + 1] = { text = text:sub(i, i + 1), visible = 1, newline = true }
        i = i + 2
      elseif c == "T" or c == "A" then
        local closer = (c == "T") and "|t" or "|a"
        local _, closeEnd = text:find(closer, i + 2, true)
        if closeEnd then
          tokens[#tokens + 1] = { text = text:sub(i, closeEnd) }
          i = closeEnd + 1
        else
          tokens[#tokens + 1] = { text = "|", visible = 1 }
          i = i + 1
        end
      else
        tokens[#tokens + 1] = { text = "|", visible = 1 }
        i = i + 1
      end
    else
      -- One UTF-8 sequence: lead byte plus continuation bytes.
      local glyphEnd = i
      local nb = text:byte(glyphEnd + 1)
      while nb and nb >= 128 and nb <= 191 do
        glyphEnd = glyphEnd + 1
        nb = text:byte(glyphEnd + 1)
      end
      tokens[#tokens + 1] = { text = text:sub(i, glyphEnd), visible = 1 }
      i = glyphEnd + 1
    end
  end
  return tokens
end

---Single-line display version of a note: keeps the head up to `maxChars`
---visible glyphs and appends an ellipsis. Escape sequences are atomic (never
---cut open), |n folds to a space, and a cut inside an open |c segment gets a
---closing |r so the ellipsis stays untinted. Returns "" for nil text and the
---text unchanged when it already fits.
function NpcNotes.truncate(text, maxChars)
  if type(text) ~= "string" or text == "" then return "" end
  if not maxChars then return text end

  local tokens = tokenize(text)
  local visible = 0
  for _, tok in ipairs(tokens) do visible = visible + (tok.visible or 0) end
  if visible <= maxChars then return text end

  local out, used, openColor = {}, 0, false
  for _, tok in ipairs(tokens) do
    local v = tok.visible or 0
    if used + v > maxChars then break end
    if tok.newline then
      out[#out + 1] = " "
    else
      out[#out + 1] = tok.text
    end
    if tok.colorOpen then openColor = true end
    if tok.colorClose then openColor = false end
    used = used + v
  end
  if openColor then out[#out + 1] = "|r" end
  out[#out + 1] = "…"
  return table.concat(out)
end
