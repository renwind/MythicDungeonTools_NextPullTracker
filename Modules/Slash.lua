local MDT_NPT = MDT_NPT

local PREFIX       = "|cFF00FF00MDT-NextPullTracker|r"
local CMD_COLOR    = "|cff00ff7f"
local LABEL_COLOR  = "|cffffd100"
local DIM          = "|cff808080"

-- Command metadata — source of truth for dispatch AND help output.
-- Adding a new command: append an entry here with { name, usage, help, handler }.
-- Dispatch runs by matching `name` against the first whitespace-delimited token
-- of the slash args; the rest of the string is passed to `handler(rest)`.
local commands = {}

local function printHelp()
  print(PREFIX.." commands:")
  for _, c in ipairs(commands) do
    local usage = CMD_COLOR.."/npt "..c.usage.."|r"
    print("  "..usage.." "..DIM.."—|r "..c.help)
  end
end

local function commandByName(name)
  for _, c in ipairs(commands) do
    if c.name == name then return c end
  end
  return nil
end

-- ============ handlers ============

local function handleStart(rest)
  local arg = (rest or ""):match("^%s*(%S*)%s*$")
  if arg == nil or arg == "" then
    MDT_NPT:Start(true)
    return
  end
  if arg == "last" then
    local charDB = MDT_NPT.GetDBChar and MDT_NPT:GetDBChar()
    MDT_NPT:Start(true, nil, nil, nil, { uid = (charDB and charDB.lastImportedPlanUID) or "" })
    return
  end
  local dungeon = tonumber(arg)
  if not dungeon or dungeon < 1 or dungeon % 1 ~= 0 then
    print(PREFIX..": usage: "..CMD_COLOR.."/npt start [last|<dungeonIndex>]|r")
    return
  end
  MDT_NPT:Start(true, nil, nil, nil, { dungeon = dungeon })
end

local function handleStop()
  MDT_NPT:Stop()
end

local function handleStatus()
  if not MDT_NPT:IsActive() then
    print(PREFIX..": tracking is not active.")
    return
  end
  local idx = MDT_NPT:GetCurrentNextPull()
  if not idx then
    print(PREFIX..": route complete.")
    return
  end
  local ps = MDT_NPT:GetPullStateData(idx)
  print(PREFIX..": "..LABEL_COLOR.."pull #"..idx.."|r "
    ..DIM.."("..ps.state..")|r "
    ..LABEL_COLOR.."mobs|r "..ps.totalCount.." "
    ..LABEL_COLOR.."forces|r "..ps.forcesKilled.."/"..ps.totalForces)
end

local function handleShow()
  if not (MDT_NPT.Beacon and MDT_NPT.Beacon.Update) then
    print(PREFIX..": beacon module not loaded.")
    return
  end
  -- Right-click "Hide Beacon" persists db.beacon.enabled = false; flip it back on
  -- so Beacon:Update() no longer short-circuits and the HUD can appear again.
  local db = MDT_NPT.GetDB and MDT_NPT:GetDB()
  if db and db.beacon then db.beacon.enabled = true end
  MDT_NPT.Beacon:Update()
end

local function handleHide()
  if not (MDT_NPT.Beacon and MDT_NPT.Beacon.Hide) then return end
  local db = MDT_NPT.GetDB and MDT_NPT:GetDB()
  if db and db.beacon then db.beacon.enabled = false end
  MDT_NPT.Beacon:Hide()
end

local function handleSkip(rest)
  local n = tonumber(rest)
  if not n then
    print(PREFIX..": "..CMD_COLOR.."/npt skip <N>|r requires a pull number.")
    return
  end
  if not MDT_NPT:IsActive() then
    print(PREFIX..": tracking is not active; run "..CMD_COLOR.."/npt start|r first.")
    return
  end
  MDT_NPT:SkipTo(n)
  print(PREFIX..": skipped to pull "..n..".")
end

local function handleComplete()
  if not MDT_NPT:IsActive() then
    print(PREFIX..": tracking is not active.")
    return
  end
  local state = MDT_NPT.state
  local PullState = MDT_NPT.PullState
  for i, ps in ipairs(state.pullStates) do
    if ps.state == PullState.ACTIVE or ps.state == PullState.NEXT then
      MDT_NPT:MarkComplete(i)
      print(PREFIX..": marked pull "..i.." complete.")
      return
    end
  end
  print(PREFIX..": no active/next pull to complete.")
end

local function handleRevert()
  if not MDT_NPT:IsActive() then
    print(PREFIX..": tracking is not active.")
    return
  end
  local idx = MDT_NPT:GetCurrentNextPull()
  local target = idx and (idx - 1) or nil
  if not target or target < 1 then
    print(PREFIX..": nothing to revert.")
    return
  end
  MDT_NPT:MarkIncomplete(target)
  print(PREFIX..": reverted pull "..target..".")
end

local function handleTest()
  if MDT_NPT.test and MDT_NPT.test.RunAllTests then
    MDT_NPT.test:RunAllTests()
  else
    print(PREFIX..": test harness not loaded.")
  end
end

local function handleSettings()
  if MDT_NPT.Settings and MDT_NPT.Settings.Open then
    MDT_NPT.Settings:Open()
  else
    print(PREFIX..": settings panel not loaded yet.")
  end
end

-- 立即重播当前 NEXT 波的提醒。没有它，游戏内验证文案和样式必须真跑完一波大秘境。
-- CooldownAlert 在 load_modules.xml 里排在 Slash.lua 之后，所以必须在函数体内
-- 后取，不能在文件顶层捕获成 upvalue（与 handlePlan 同一手法）。
local function handleAlert()
  if not MDT_NPT:IsActive() then
    print(PREFIX..": tracking is not active.")
    return
  end
  local idx = MDT_NPT:GetCurrentNextPull()
  if not idx then
    print(PREFIX..": route complete.")
    return
  end
  local alert = MDT_NPT.CooldownAlert
  local items = alert and alert:SpeakNow()
  -- 自动播报路径在无计划时保持静默（设计决策 3），但这条命令是给人当场验证用的，
  -- 静默会让人以为坏了，所以这里必须出声反馈。
  if not items then
    print(PREFIX..": "..MDT_NPT.L["No Planned Uses - %d"]:format(idx))
  end
end

-- ============ key-binding actions ============
-- Keep behaviour identical to the slash equivalents, minus the chat noise — these
-- fire from key bindings or the right-click menu, so they should be silent.

function MDT_NPT:ToggleBeacon()
  local db = self:GetDB()
  if not db or not db.beacon then return end
  if db.beacon.enabled and self.Beacon and self.Beacon.frame and self.Beacon.frame:IsShown() then
    db.beacon.enabled = false
    self.Beacon:Hide()
  else
    db.beacon.enabled = true
    if self.Beacon and self.Beacon.Update then self.Beacon:Update() end
  end
end

function MDT_NPT:NextPullManual()
  local state = self.state
  if not state or not state.active then return end
  for i, ps in ipairs(state.pullStates) do
    if ps.state == self.PullState.ACTIVE or ps.state == self.PullState.NEXT then
      self:MarkComplete(i)
      return
    end
  end
end

function MDT_NPT:PrevPullManual()
  if not self:IsActive() then return end
  local idx = self:GetCurrentNextPull()
  local target = idx and (idx - 1) or nil
  if not target or target < 1 then return end
  self:MarkIncomplete(target)
end

function MDT_NPT:ToggleBeaconLock()
  local state = self:GetBeaconState()
  if state then state.locked = not state.locked end
end

-- Open the cooldown plan editor (design 7.1). Late-deref of CooldownPlanEditor so the
-- load order (Slash.lua loads before CooldownPlanEditor.lua) is safe at runtime.
local function handlePlan()
  if MDT_NPT.CooldownPlanEditor then
    MDT_NPT.CooldownPlanEditor:Open()
  end
end

-- 导入外部生成的冷却计划（tools/wclplan 产物）。ImportPlan 在 Slash.lua 之后加载，
-- 与 handlePlan/handleAlert 同一手法：函数体内后取，不在文件顶层捕获 upvalue。
local function handleImportPlan(rest)
  local routeKey, waveText, spec = rest:match("^(%S+)%s+(%S+)%s+(.*)$")
  local wave = tonumber(waveText or "")
  if not routeKey or not wave or not spec or spec == "" then
    print(PREFIX..": usage: "..CMD_COLOR.."/npt importplan <routeKey> <wave> <id:kind:action[:uses];...>|r")
    return
  end
  local ok, err = MDT_NPT.ImportPlan:apply(wave, spec, routeKey)
  if not ok then
    print(PREFIX..": importplan failed: "..tostring(err))
    return
  end
  print(PREFIX..": imported cooldown plan for pull "..wave..".")
end

-- 整包导入（tools/wclplan 的 importplan-pack.txt 那一行）：一次粘完全部波。
local function handleImportPlanPack(rest)
  local routeKey, pack = rest:match("^(%S+)%s+(%S+)$")
  if not routeKey or not pack then
    print(PREFIX..": usage: "..CMD_COLOR.."/npt importplanpack <routeKey> <wave:l<a<p;...>|r")
    return
  end
  local ok, err, n = MDT_NPT.ImportPlan:applyPack(pack, routeKey)
  if not ok then
    print(PREFIX..": importplanpack failed: "..tostring(err))
    return
  end
  print(PREFIX..": imported cooldown plan for "..n.." pulls.")
end

-- ============ command table ============

commands = {
  { name = "start",    usage = "start [last|<dungeonIndex>]", help = "begin tracking; last = remembered planned route, index = force a dungeon", handler = handleStart },
  { name = "stop",     usage = "stop",        help = "stop tracking and clear tracking state",            handler = handleStop },
  { name = "status",   usage = "status",      help = "print the current pull's state and forces",         handler = handleStatus },
  { name = "skip",     usage = "skip <N>",    help = "jump directly to pull N (marks prior pulls done)",  handler = handleSkip },
  { name = "complete", usage = "complete",    help = "mark the current active/next pull as complete",     handler = handleComplete },
  { name = "revert",   usage = "revert",      help = "undo the most recent pull completion",              handler = handleRevert },
  { name = "show",     usage = "show",        help = "enable and show the beacon HUD",                    handler = handleShow },
  { name = "hide",     usage = "hide",        help = "disable and hide the beacon HUD",                   handler = handleHide },
  { name = "settings", usage = "settings",    help = "open the settings panel",                           handler = handleSettings },
  { name = "plan",     usage = "plan",        help = "open the cooldown plan editor",                     handler = handlePlan },
  { name = "importplan", usage = "importplan <routeKey> <wave> <spec>", help = "import a generated cooldown plan for wave N", handler = handleImportPlan },
  { name = "importplanpack", usage = "importplanpack <routeKey> <pack>", help = "import a whole generated plan in one line", handler = handleImportPlanPack },
  { name = "alert",    usage = "alert",       help = "repeat the next pull's cooldown reminder now",      handler = handleAlert },
  { name = "test",     usage = "test",        help = "run the integration test suite",                    handler = handleTest },
  { name = "help",     usage = "help",        help = "show this help message",                            handler = printHelp },
}

function MDT_NPT:Slash(args)
  args = args or ""
  local cmd, rest = args:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()

  local command = commandByName(cmd)
  if command then
    command.handler(rest)
  else
    printHelp()
  end
end

SLASH_MDTNPT1 = "/npt"
SlashCmdList["MDTNPT"] = function(msg) MDT_NPT:Slash(msg or "") end
