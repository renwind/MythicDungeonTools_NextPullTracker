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

-- 显式可选的冷却测试环境；即使断言失败也立即恢复全局，不依赖 after_each。
function M.withCooldownRuntime(fn)
  local names = {
    "C_SpecializationInfo", "C_SpellBook", "Enum", "C_Spell", "C_Item", "C_Timer",
    "GetTime", "GetPhysicalScreenSize", "CreateFrame", "EllesmereUI", "unpack",
    "IsControlKeyDown", "MDTNPTCooldownPlanMixin",
  }
  local saved = {}
  for _, name in ipairs(names) do saved[name] = _G[name] end
  local env = {
    specID = 262, time = 100, tickers = {},
    dbChar = { cooldownPotionID = 241308, cooldownPlans = {} },
    db = { beacon = { showCooldownPlan = true } },
    cooldown = { isEnabled = true, isActive = false, startTime = 0, duration = 0 },
  }
  local function widget(kind, parent, layer, font)
    local w = {
      kind = kind, parent = parent, layer = layer, font = font,
      shown = true, text = "", points = {}, scripts = {}, regions = {},
      textHistory = {}, level = parent and (parent.level or 0) + 1 or 0,
    }
    function w:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function w:ClearAllPoints() self.points = {} end
    function w:SetAllPoints(target) self.allPoints = target or self.parent end
    function w:SetSize(width, height) self.width = width; self.height = height end
    function w:SetWidth(width) self.width = width end
    function w:SetHeight(height) self.height = height end
    function w:GetWidth() return self.width end
    function w:GetHeight() return self.height end
    function w:GetParent() return self.parent end
    function w:GetEffectiveScale() return 1 end
    function w:GetFrameLevel() return self.level end
    function w:SetFrameLevel(level) self.level = level end
    function w:Show() self.shown = true end
    function w:Hide() self.shown = false end
    function w:IsShown() return self.shown end
    function w:SetText(text)
      self.text = tostring(text)
      self.textHistory[#self.textHistory + 1] = self.text
    end
    function w:GetText() return self.text end
    function w:SetTextColor(...) self.color = { ... } end
    function w:SetShadowColor(...) self.shadowColor = { ... } end
    function w:SetShadowOffset(...) self.shadowOffset = { ... } end
    function w:SetColorTexture(...) self.color = { ... } end
    function w:SetTexture(texture) self.texture = texture end
    function w:SetTexCoord(...) self.texCoord = { ... } end
    function w:SetVertexColor(...) self.vertexColor = { ... } end
    function w:SetAtlas(atlas) self.atlas = atlas end
    function w:SetAlpha(alpha) self.alpha = alpha end
    function w:SetScript(name, callback) self.scripts[name] = callback end
    function w:EnableMouse(enabled) self.mouseEnabled = enabled end
    function w:SetCooldown(start, duration) self.cooldown = { start, duration } end
    function w:SetHideCountdownNumbers(hide) self.hideCountdownNumbers = hide end
    function w:Clear() self.cooldown = nil end
    function w:CreateTexture(_, drawLayer)
      local region = widget("Texture", self, drawLayer)
      self.regions[#self.regions + 1] = region
      return region
    end
    function w:CreateFontString(_, drawLayer, fontObject)
      local region = widget("FontString", self, drawLayer, fontObject)
      self.regions[#self.regions + 1] = region
      return region
    end
    return w
  end
  local ok, err = pcall(function()
    _G.unpack = _G.unpack or table.unpack
    _G.EllesmereUI = nil
    _G.C_SpecializationInfo = {
      GetSpecialization = function() return 1 end,
      GetSpecializationInfo = function() return env.specID end,
    }
    _G.C_SpellBook = { IsSpellInSpellBook = function() return true end }
    _G.Enum = { SpellBookSpellBank = { Player = 0 } }
    _G.C_Spell = {
      GetSpellTexture = function(id) return "spell:" .. id end,
      GetSpellCooldown = function() return env.cooldown end,
    }
    _G.C_Item = { GetItemIconByID = function(id) return "item:" .. id end }
    _G.C_Timer = { NewTicker = function(_, callback)
      local ticker = { callback = callback, Cancel = function(self) self.cancelled = true end }
      env.tickers[#env.tickers + 1] = ticker
      return ticker
    end }
    _G.GetTime = function() return env.time end
    _G.GetPhysicalScreenSize = function() return 1920, 1080 end
    _G.IsControlKeyDown = function() return false end
    _G.CreateFrame = function(kind, _, parent) return widget(kind, parent) end
    _G.MDT_NPT.MDT = _G.MDT
    _G.MDT_NPT.GetDBChar = function() return env.dbChar end
    _G.MDT_NPT.GetDB = function() return env.db end
    fn(env)
  end)
  for _, name in ipairs(names) do _G[name] = saved[name] end
  if not ok then error(err, 0) end
end

return M
