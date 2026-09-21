local _, MDT_NPT = ...

-- MDT 6.2 (WoW 12.1) intentionally removed the legacy `_G.MDT` table. Its
-- public API exposes the saved-variable database, but not the selected preset
-- or the clone coordinates required by the beacon. The TOC therefore loads
-- MDT's static Midnight dungeon files into this addon's private table and this
-- adapter supplies the small database surface used by the tracker.
local Adapter = MDT_NPT
local PublicAPI = _G.MythicDungeonToolsAPI
local UI_ADDON_NAME = "MythicDungeonTools_UI"

Adapter.AddonName = "MythicDungeonTools"
Adapter.BackdropColor = { 0.058823399245739, 0.058823399245739, 0.058823399245739, 0.9 }
Adapter.dungeonEnemies = Adapter.dungeonEnemies or {}
Adapter.dungeonList = Adapter.dungeonList or {}
Adapter.dungeonMaps = Adapter.dungeonMaps or {}
Adapter.dungeonSubLevels = Adapter.dungeonSubLevels or {}
Adapter.dungeonTotalCount = Adapter.dungeonTotalCount or {}
Adapter.mapInfo = Adapter.mapInfo or {}
Adapter.mapPOIs = Adapter.mapPOIs or {}
Adapter.scaleMultiplier = Adapter.scaleMultiplier or {}
Adapter.zoneIdToDungeonIdx = Adapter.zoneIdToDungeonIdx or {}

-- MDT dungeon files look localized names up through MDT.L. Preserve this
-- addon's translations and fall back to the source key for MDT-owned strings.
local localeMeta = getmetatable(Adapter.L) or {}
if localeMeta.__index == nil then
  localeMeta.__index = function(_, key) return key end
  setmetatable(Adapter.L, localeMeta)
end

-- MDT 6.2.17 made every Midnight dungeon file call this before it registers
-- dungeonEnemies/dungeonTotalCount. MDT defines it in its load-on-demand UI
-- addon, which is not loaded when our TOC cross-loads those files, so the
-- adapter has to answer it or each file aborts mid-load.
function Adapter:RegisterDungeonLocation(dungeonIdx, location)
  local zoneIds = location and location.zoneIds
  if not zoneIds then return end
  for _, zoneId in ipairs(zoneIds) do
    -- Two dungeons can share an overworld zone and this addon has none of
    -- MDT's dungeon-selection ordering to break the tie, so first wins.
    if Adapter.zoneIdToDungeonIdx[zoneId] == nil then
      Adapter.zoneIdToDungeonIdx[zoneId] = dungeonIdx
    end
  end
end

function Adapter:GetDB()
  -- MDT's core API captures its small bootstrap DB before the load-on-demand
  -- UI initializes AceDB. Once the UI is loaded, MythicDungeonToolsDB.global
  -- is the authoritative table containing presets/currentPreset; prefer it so
  -- we do not keep reading the stale bootstrap table returned by API:GetDB().
  local saved = _G.MythicDungeonToolsDB
  if saved and type(saved.global) == "table" then
    return saved.global
  end
  if PublicAPI and PublicAPI.GetDB then
    return PublicAPI:GetDB()
  end
  return nil
end

local function tableValue(tbl, key)
  if type(tbl) ~= "table" or key == nil then return nil end
  return tbl[key] or tbl[tostring(key)] or (tonumber(key) and tbl[tonumber(key)])
end

local function isUsablePreset(preset)
  return type(preset) == "table" and type(preset.value) == "table" and
    type(preset.value.pulls) == "table" and #preset.value.pulls > 0
end

local function resolvePreset(db, dungeonIndex)
  if type(db) ~= "table" then return nil end
  dungeonIndex = dungeonIndex or db.currentDungeonIdx
  local dungeonPresets = tableValue(db.presets, dungeonIndex)
  local presetIndex = tableValue(db.currentPreset, dungeonIndex)
  local selected = tableValue(dungeonPresets, presetIndex)
  if isUsablePreset(selected) then return selected end

  -- A route can remain valid while currentPreset points at MDT's synthetic
  -- "<New Preset>" entry or while a migrated key changed numeric type. Prefer
  -- the first real, non-empty route belonging to the selected dungeon.
  if type(dungeonPresets) == "table" then
    for _, preset in pairs(dungeonPresets) do
      if isUsablePreset(preset) then return preset end
    end
  end
  return nil
end

local function isUIAddonLoaded()
  if not C_AddOns or not C_AddOns.IsAddOnLoaded then return true end
  local loadedOrLoading, loaded = C_AddOns.IsAddOnLoaded(UI_ADDON_NAME)
  return loaded == nil and loadedOrLoading or loaded
end

-- MDT 6.2 keeps presets in its load-on-demand UI addon. Loading it directly
-- initializes the route database without opening MDT's window.
function Adapter:EnsureUIReady()
  if isUIAddonLoaded() then return true end
  if not C_AddOns or not C_AddOns.LoadAddOn then return false, "API unavailable" end

  local loaded, reason = C_AddOns.LoadAddOn(UI_ADDON_NAME)
  if loaded or isUIAddonLoaded() then return true end
  return false, reason or "unknown error"
end

function Adapter:GetCurrentPreset(dungeonIndex)
  local ready = self:EnsureUIReady()
  if not ready then return nil end

  local saved = _G.MythicDungeonToolsDB
  local savedDB = saved and saved.global
  local preset = resolvePreset(savedDB, dungeonIndex)
  if preset then return preset end

  local apiDB = PublicAPI and PublicAPI.GetDB and PublicAPI:GetDB() or nil
  if apiDB ~= savedDB then return resolvePreset(apiDB, dungeonIndex) end
  return nil
end

function Adapter:GetPresetDiagnostics()
  local db = self:GetDB()
  local dungeonIndex = db and db.currentDungeonIdx
  local presetIndex = db and tableValue(db.currentPreset, dungeonIndex)
  local dungeonPresets = db and tableValue(db.presets, dungeonIndex)
  local presetCount = 0
  if type(dungeonPresets) == "table" then
    for _ in pairs(dungeonPresets) do presetCount = presetCount + 1 end
  end
  return "dungeon="..tostring(dungeonIndex)..
    ", selection="..tostring(presetIndex)..
    ", presets="..tostring(type(db and db.presets) == "table")..
    ", dungeonPresets="..tostring(presetCount)..
    ", uiLoaded="..tostring(isUIAddonLoaded())
end

function Adapter:UpdateToDungeon(dungeonIndex)
  local db = self:GetDB()
  if not db or not dungeonIndex then return false end

  db.currentDungeonIdx = dungeonIndex
  db.currentPreset = db.currentPreset or {}
  if not db.currentPreset[dungeonIndex] then
    db.currentPreset[dungeonIndex] = 1
  end
  return true
end

MDT_NPT.MDT = Adapter
