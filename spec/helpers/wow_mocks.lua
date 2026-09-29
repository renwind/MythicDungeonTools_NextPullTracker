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
    "PlaySoundFile", "UIParent", "GameFontNormalLarge", "GetLocale",
  }
  local saved = {}
  for _, name in ipairs(names) do saved[name] = _G[name] end
  local env = {
    specID = 262, time = 100, tickers = {},
    dbChar = { cooldownPotionID = 241308, cooldownPlans = {} },
    db = { beacon = { showCooldownPlan = true, alertVoice = true, alertText = true } },
    cooldown = { isEnabled = true, isActive = false, startTime = 0, duration = 0 },
    -- 冷却提醒（设计 §12.1）
    played = {},        -- 每次 PlaySoundFile 的 {path, channel}
    shown = {},         -- 每次 AlertBanner:Show 的图标列表
    timers = {},        -- C_Timer.After / NewTimer 排定的定时器
    animations = {},    -- 每个 CreateAnimationGroup 的产物
  }
  -- 手动触发所有未取消的 After / NewTimer 定时器；去抖断言全靠它，不依赖真实时间。
  function env.fireTimers()
    local due = env.timers
    env.timers = {}
    for _, t in ipairs(due) do
      if not t.cancelled then t.fn(t) end
    end
  end
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
    -- GetStringWidth 是真实的 FontString 方法（横幅要靠它排版）。* 12 是任意但
    -- 确定的替身宽度：每字符 12px，断言就能按字符数算出确切的像素值。
    function w:GetStringWidth() return #tostring(self.text or "") * 12 end
    function w:SetTextColor(...) self.color = { ... } end
    function w:GetFont() return self._fontPath or "Fonts\\dummy.ttf", self._fontSize or 12, self._fontFlags or "" end
    function w:SetFont(path, size, flags) self._fontPath, self._fontSize, self._fontFlags = path, size, flags end
    function w:SetShadowColor(...) self.shadowColor = { ... } end
    function w:SetShadowOffset(...) self.shadowOffset = { ... } end
    function w:SetColorTexture(...) self.color = { ... } end
    -- 变参一并记录：遮罩贴图靠 SetTexture(path, "CLAMPTOBLACKADDITIVE", ...) 的包裹模式生效。
    function w:SetTexture(texture, horizWrap, vertWrap)
      self.texture = texture
      self.textureArgs = { texture, horizWrap, vertWrap }
    end
    function w:SetTexCoord(...) self.texCoord = { ... } end
    function w:SetVertexColor(...) self.vertexColor = { ... } end
    -- 真实 Texture 的遮罩挂接 API：AddMaskTexture / RemoveMaskTexture。
    function w:AddMaskTexture(mask)
      self.maskList = self.maskList or {}
      self.maskList[#self.maskList + 1] = mask
    end
    function w:RemoveMaskTexture(mask)
      self.maskList = self.maskList or {}
      for i, m in ipairs(self.maskList) do
        if m == mask then table.remove(self.maskList, i); break end
      end
    end
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
    -- 遮罩区域与 Texture 共用 widget：它需要的 SetTexture/SetAllPoints/Show/Hide/SetSize 全在上面。
    function w:CreateMaskTexture()
      local mask = widget("MaskTexture", self)
      self.masks = self.masks or {}
      self.masks[#self.masks + 1] = mask
      return mask
    end
    -- 有意不区分 kind：真实客户端里 SetJustifyH/V、SetWordWrap 只属于 FontString，
    -- SetFrameStrata 只属于 Frame。沿用本文件既有的「一个通用 widget」做法
    -- （SetText 也是哪都挂），按 kind 拆工厂属于过度设计。代价是产品代码把这些
    -- 方法调到错误的 region 上时，spec 会绿而客户端会崩——写新 UI 时自己留意。
    function w:SetFrameStrata(strata) self.strata = strata end
    function w:SetJustifyH(j) self.justifyH = j end
    function w:SetJustifyV(j) self.justifyV = j end
    function w:SetWordWrap(wrap) self.wordWrap = wrap end
    function w:SetNonSpaceWrap(wrap) self.nonSpaceWrap = wrap end
    function w:CreateAnimationGroup()
      local group = { animations = {}, playing = false, plays = 0, stops = 0, scripts = {} }
      function group:CreateAnimation(kind)
        local a = { kind = kind }
        function a:SetOrder(n) self.order = n end
        function a:SetFromAlpha(v) self.from = v end
        function a:SetToAlpha(v) self.to = v end
        function a:SetDuration(d) self.duration = d end
        -- Scale 动画（AlertBanner v3 的弹出）：与 Alpha 记录器同风格。
        function a:SetOrigin(point, x, y) self.origin = { point, x, y } end
        function a:SetScaleFrom(x, y) self.fromScale = { x, y } end
        function a:SetScaleTo(x, y) self.toScale = { x, y } end
        self.animations[#self.animations + 1] = a
        return a
      end
      function group:Play() self.playing = true; self.plays = self.plays + 1 end
      function group:Stop() self.playing = false; self.stops = self.stops + 1 end
      function group:IsPlaying() return self.playing end
      function group:SetScript(name, fn) self.scripts[name] = fn end
      -- 仅测试用：真实 AnimationGroup 没有 Finish。下划线前缀提醒它不是客户端 API，
      -- 产品代码绝不可调用（「臆造 mock 方法」的教训，见下文 C_Timer.After 的注释）。
      -- 只 mock 真实存在的 SetScript("OnFinished", fn)：AnimationGroup 没有
      -- SetOnFinished 方法（全机 AddOns 零命中，SetScript 形式 55 命中）。
      -- 曾经臆造过它，于是产品代码调一个不存在的方法而 spec 全绿。
      function group:_testFinish()
        self.playing = false
        if self.scripts.OnFinished then self.scripts.OnFinished(self) end
      end
      group.owner = self   -- 测试抓手：谁创建了这个动画组（AlertBanner 里是 Frame）
      env.animations[#env.animations + 1] = group
      return group
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
    _G.C_Timer = {
      NewTicker = function(_, callback)
        local ticker = { callback = callback, Cancel = function(self) self.cancelled = true end }
        env.tickers[#env.tickers + 1] = ticker
        return ticker
      end,
      -- 零售客户端的 After 不返回句柄，取消不了；要可取消必须用 NewTimer。
      -- 本机 AddOns 里没有任何插件捕获 After 的返回值，而 NewTimer 的句柄到处
      -- 被 :Cancel()。曾经让 After 返回句柄，于是去抖失效的 bug 在 spec 里全绿
      -- ——和本仓库臆造过 FontString:SetOutlined 是同一类陷阱，只是发生在返回值上。
      After = function(delay, fn)
        env.timers[#env.timers + 1] = { delay = delay, fn = fn }
      end,
      NewTimer = function(delay, fn)
        local timer = { delay = delay, fn = fn, Cancel = function(self) self.cancelled = true end }
        env.timers[#env.timers + 1] = timer
        return timer
      end,
    }
    _G.GetTime = function() return env.time end
    _G.GetPhysicalScreenSize = function() return 1920, 1080 end
    _G.IsControlKeyDown = function() return false end
    _G.CreateFrame = function(kind, _, parent, template)
      local w = widget(kind, parent)
      -- 零售客户端只有 BackdropTemplate 框才有 SetBackdrop*；mock 同样按模板挂。
      if type(template) == "string" and template:find("BackdropTemplate", 1, true) then
        function w:SetBackdrop(t)
          self.backdrop = t
          self.backdropCalls = (self.backdropCalls or 0) + 1
        end
        function w:SetBackdropColor(...) self.backdropColor = { ... } end
        function w:SetBackdropBorderColor(...) self.backdropBorderColor = { ... } end
      end
      return w
    end
    _G.PlaySoundFile = function(path, channel)
      env.played[#env.played + 1] = { path = path, channel = channel }
    end
    -- AlertBanner 的字体回落路径会调 GameFontNormalLarge:GetFont()；不存在的话
    -- 回落分支的断言会因为 nil 索引而假绿。
    _G.GameFontNormalLarge = { GetFont = function() return "Fonts\\blizzard.ttf", 16, "" end }
    -- Locales/*.lua 在加载期就调 GetLocale()（zhCN/ruRU/frFR 用守卫提前 return），
    -- 所以在 withCooldownRuntime 内 loadSource 真实 locale 文件时它必须存在。
    -- 这不是本地化完整性检查的机制，只是让那些文件能被加载。
    _G.GetLocale = function() return "enUS" end
    _G.UIParent = widget("Frame", nil)
    -- 桩：让 CooldownAlert_spec 只断言 env.shown，不必加载真 UI 模块。
    -- AlertBanner_spec 会 loadSource 真模块覆盖掉它。这是 MDT_NPT 的字段写入，
    -- 不经 names 白名单恢复——安全的前提是 M.reset() 会整体重建 MDT_NPT，
    -- 与上面既有的 GetDB/GetDBChar 赋值同一模式。
    _G.MDT_NPT.AlertBanner = {
      Show = function(_, iconList) env.shown[#env.shown + 1] = iconList end,
      Hide = function() end,
    }
    _G.MDT_NPT.MDT = _G.MDT
    _G.MDT_NPT.GetDBChar = function() return env.dbChar end
    _G.MDT_NPT.GetDB = function() return env.db end
    fn(env)
  end)
  for _, name in ipairs(names) do _G[name] = saved[name] end
  if not ok then error(err, 0) end
end

return M
