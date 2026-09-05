-- Minimal stubs for the slice of the WoW runtime + parent-MDT surface that the
-- pure-Lua child-addon modules (State, Scenario, API, BeaconState) actually touch.
-- Extend as more modules come under test.

local M = {}

local function installGlobals()
  _G.GetTime = function() return 0 end
  _G.C_SpecializationInfo = nil
  _G.GetSpecialization = nil
  _G.GetSpecializationRole = nil

  -- CreateFont mock: mirrors WoW's global FontObject factory.
  -- Created objects are stored as _G[name] and support SetFont / GetFont.
  _G.CreateFont = function(name)
    if _G[name] then error("Font '" .. name .. "' already exists") end
    local fontObj = { _name = name }
    function fontObj:SetFont(path, size, flags)
      self._path = path; self._size = size; self._flags = flags or ""
    end
    function fontObj:GetFont()
      return self._path, self._size, self._flags
    end
    _G[name] = fontObj
    return fontObj
  end

  _G.MDT = {
    dungeonEnemies = {},
    dungeonTotalCount = {},
    -- L[key] returns the key itself so assertions can compare on English text
    L = setmetatable({}, { __index = function(_, k) return k end }),
  }
  function _G.MDT:GetDB()     return { currentDungeonIdx = 1 } end
  function _G.MDT:GetDBChar() return {} end

  -- Matches init.lua's shape so Modules/*.lua files capture the same fields.
  _G.MDT_NPT = {
    -- L[key] returns the key itself so render tests can assert on English strings.
    L = setmetatable({}, { __index = function(_, k) return k end }),
    PullState = {
      COMPLETED = "completed",
      ACTIVE    = "active",
      NEXT      = "next",
      UPCOMING  = "upcoming",
    },
  }
  -- No saved colors by default, so colorForPullState falls back to its palette.
  function _G.MDT_NPT:GetDB() return {} end

  -- Minimal Theme stub so modules that capture MDT_NPT.Theme at load time don't error.
  _G.MDT_NPT.Theme = {
    colors = setmetatable({}, { __index = function() return { 0, 0, 0, 1 } end }),
    pullColors = {},
    pullOutlineColors = {},
    textures = {},
    fonts = {},
    Refresh = function() end,
    IsEUIAvailable = function() return false end,
    GetFontPath = function() return nil end,
    CreateBorder = function() return { top = {}, bottom = {}, left = {}, right = {} } end,
    StyleButton = function(_, btn)
      local fs = {}
      function fs:SetText() end
      function fs:SetTextColor() end
      return fs
    end,
  }
end

---Fresh mock state. Call in `before_each` so every test starts from a known baseline.
function M.reset()
  -- Remove any NPT_* FontObjects created by previous Theme.Refresh() runs.
  for k in pairs(_G) do
    if type(k) == "string" and k:sub(1, 4) == "NPT_" then _G[k] = nil end
  end
  installGlobals()
end

---Executes a child-addon source file (repo-relative path) in the current globals.
---Re-executing is cheap and gives tests a fresh MDT_NPT.<Module> each call.
function M.loadSource(relPath)
  local chunk, err = loadfile(relPath)
  assert(chunk, err)
  -- Pass addon name + addon table so files using `local _, MDT_NPT = ...` work.
  return chunk("MythicDungeonTools_NextPullTracker", _G.MDT_NPT)
end

return M
