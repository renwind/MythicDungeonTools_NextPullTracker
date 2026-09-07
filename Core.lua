local AddonName = ...
local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT
local State = MDT_NPT.State
local Scenario = MDT_NPT.Scenario
local Beacon = MDT_NPT.Beacon
local Mdt = MDT_NPT.Mdt
local Wow = MDT_NPT.Wow
local Theme = MDT_NPT.Theme
local L = MDT_NPT.L
local NpcNotes = MDT_NPT.NpcNotes

local function copyPalette(src)
  local t = {}
  for k, v in pairs(src) do t[k] = { v[1], v[2], v[3], v[4] } end
  return t
end

local db, dbChar
local pollTimer
local startGeneration = 0
local eventFrame = CreateFrame("Frame")

local defaultSavedVars = {
  global = {
    enabled = true,
    autoStartInKey = true,
    beaconScope = "char",
    beacon = {
      enabled = true,
      scale = 1.0,
      alpha = 1.0,
      anchorFrom = "TOP",
      anchorTo = "TOP",
      xoffset = 0,
      yoffset = -50,
      locked = false,
      showForNonTank = false,
      showUpcoming = true,
      showUnselected = false,
      askOnStart = true,
      -- When true, the beacon shrinks to just the minimap and hides the info
      -- panel (pull header, mob count, portraits, progress bar, upcoming).
      mapOnly = false,
      -- Independent visibility switch for the cooldown-plan icon rows (design 12.2).
      -- Default off; when on, the Beacon shows even for non-tanks.
      showCooldownPlan = false,
      -- Independent visibility switch for the NPC note strips shown above the
      -- beacon (design: NpcNotes 5.1). Purely additive: follows the beacon's
      -- existing visibility conditions, never forces the beacon visible.
      showNpcNotes = false,
      -- Per-state colors for the minimap pull DOTS. {r, g, b, a}. Keys match
      -- BeaconMinimap's pull states.
      pullColors = copyPalette(Theme.pullColors),
      -- Color of the OUTLINE (circle) drawn around the current pull, kept
      -- separate from the dot colors. Only the current pull (next/active) has
      -- an outline. Defaults match the dot colors so the look is unchanged.
      pullOutlineColors = copyPalette(Theme.pullOutlineColors),
    },
    sync = {
      authority = "auto",
    },
    -- User notes per NPC kind (design: NpcNotes 2.5). Keys come from
    -- NpcNotes.keyFor ("npc:<id>" / "name:<name>"); values are raw strings
    -- that may contain WoW colour escapes. Account-wide by design.
    npcNotes = {},
    _migratedFromParent = false,
  },
  char = {
    beacon = {
      anchorFrom = "TOP",
      anchorTo = "TOP",
      xoffset = 0,
      yoffset = -50,
      scale = 1.0,
      locked = false,
    },
    -- Cooldown plan data, char-scoped (design 5.1). MUST stay under `char`
    -- (AceDB validateDefaults rejects unknown top-level keys).
    cooldownPlans = {},
    cooldownPotionID = 241308,   -- burst potion itemID default (Light's Potential ilvl295)
    _cooldownPlanVersion = 1,    -- migration version marker (design 5.4)
  },
}

StaticPopupDialogs["NPT_BEACON_ASK"] = {
  text = "Mythic+ started. Display the MDT Next Pull Beacon on your screen?",
  button1 = YES,
  button2 = NO,
  button3 = "Never ask",
  OnAccept = function()
    db.beacon.showForNonTank = true
    MDT_NPT:UpdateAll()
  end,
  OnCancel = function()
    db.beacon.showForNonTank = false
  end,
  OnAlt = function()
    db.beacon.showForNonTank = false
    db.beacon.askOnStart = false
  end,
  timeout = 30,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- Per-NPC note editor (design: NpcNotes 3.2). Shown via
-- StaticPopup_Show("MDT_NPT_NPC_NOTE", mobName, npcKey): text_arg1 is the mob
-- name (fills the "%s" in the title), text_arg2 is the NpcNotes key the
-- handlers read/write. Three buttons because ESC maps to button2 — a
-- save/clear-only pair would make "cancel" clear the note.
-- 12.x StaticPopup renamed dialog fields (editBox -> EditBox, button1 ->
-- Buttons[1]); keep both spellings so the handlers work across client versions.
local function popupEditBox(dialog)
  return dialog.editBox or dialog.EditBox
end
local function popupAcceptButton(dialog)
  return dialog.button1 or (dialog.Buttons and dialog.Buttons[1])
end

StaticPopupDialogs["MDT_NPT_NPC_NOTE"] = {
  text = L["NPC Note - %s"],
  button1 = L["Save Note"],
  button2 = CANCEL,
  button3 = L["Clear Note"],
  hasEditBox = true,
  hideOnEscape = true,
  whileDead = true,
  preferredIndex = 3,
  OnShow = function(self)
    -- 12.x StaticPopup_Show no longer forwards text_arg1/2 to the dialog, so
    -- the click site stashes { key, name } in MDT_NPT.noteEdit instead.
    local pe = MDT_NPT.noteEdit
    if pe and self.Text then
      self.Text:SetText((L["NPC Note - %s"]):format(pe.name or ""))
    end
    -- The edit box shows the raw stored text (colour escapes render live),
    -- pre-selected so typing overwrites.
    local eb = popupEditBox(self)
    if eb then
      eb:SetText(pe and NpcNotes.get(pe.key) or "")
      eb:SetFocus()
      eb:HighlightText()
    end
  end,
  EditBoxOnEnterPressed = function(self)
    -- 12.x StaticPopup: the edit box is no longer a direct child of the dialog
    -- frame; owningDialog points at it (GetParent() returns a buttonless
    -- container, hence the nil button1 crash).
    local dialog = self.owningDialog or self:GetParent()
    local btn = dialog and popupAcceptButton(dialog)
    if btn then btn:Click() end
  end,
  EditBoxOnEscapePressed = function(self)
    local dialog = self.owningDialog or self:GetParent()
    if dialog then dialog:Hide() end
  end,
  OnAccept = function(self)
    local pe = MDT_NPT.noteEdit
    if pe then
      local eb = popupEditBox(self)
      NpcNotes.set(pe.key, eb and eb:GetText() or "")
    end
    if Beacon.Update then Beacon:Update() end
  end,
  OnCancel = function() end, -- just close; ESC lands here
  OnAlt = function(self)
    local pe = MDT_NPT.noteEdit
    if pe then NpcNotes.clear(pe.key) end
    if Beacon.Update then Beacon:Update() end
  end,
}

function MDT_NPT:GetDB() return db end

function MDT_NPT:GetDBChar() return dbChar end

-- =====================================================================
-- UpdateAll — fan out to child modules
-- =====================================================================

function MDT_NPT:UpdateAll()
  if Beacon.Update then
    Beacon:Update()
  end
  -- Keep the standalone plan editor in sync during active tracking (e.g. next
  -- pull advances). Route switches while idle are handled by the editor's own
  -- OnUpdate poll, since UpdateAll only fires during the 1s tracking timer.
  if MDT_NPT.CooldownPlanEditor and MDT_NPT.CooldownPlanEditor.Refresh then
    MDT_NPT.CooldownPlanEditor:Refresh()
  end
end

-- =====================================================================
-- Start / Stop
-- =====================================================================

function MDT_NPT:Start(manual, retryCount, generation, challengeExpected)
  retryCount = retryCount or 0
  if not generation then
    startGeneration = startGeneration + 1
    generation = startGeneration
  end

  if not db then db = self:GetDB() end
  if not db or not db.enabled then return end

  local dungeonReady, detectedDungeonIndex = Mdt.syncMDTDungeonToPlayerZone(challengeExpected)
  if dungeonReady == false then
    if retryCount < 10 and C_Timer and C_Timer.After then
      C_Timer.After(0.2, function()
        if generation == startGeneration then
          MDT_NPT:Start(manual, retryCount + 1, generation, challengeExpected)
        end
      end)
    else
      print("|cFF00FF00MDT-NextPullTracker|r: Cannot start tracking — the active Mythic+ dungeon could not be identified.")
    end
    return
  end

  -- Read the route for the dungeon we just detected explicitly. MDT's UI
  -- initialization can replace or mutate its current selection while loading.
  local preset = MDT:GetCurrentPreset(detectedDungeonIndex)
  if not preset then
    local diagnostics = MDT.GetPresetDiagnostics and MDT:GetPresetDiagnostics() or "diagnostics unavailable"
    print("|cFF00FF00MDT-NextPullTracker|r: Cannot start tracking — no non-empty MDT route is available ("..diagnostics..").")
    return
  end

  local state = State.buildStateFromPreset(preset)
  if not state then
    print("|cFF00FF00MDT-NextPullTracker|r: Cannot start tracking — no pulls in current preset.")
    return
  end

  if manual then state.manuallyStarted = true end
  state.lastForces = 0

  MDT_NPT.state = state

  eventFrame:RegisterEvent("SCENARIO_CRITERIA_UPDATE")
  eventFrame:RegisterEvent("SCENARIO_UPDATE")
  eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
  eventFrame:RegisterEvent("CHALLENGE_MODE_RESET")

  if pollTimer then pollTimer:Cancel() end
  pollTimer = C_Timer.NewTicker(1.0, function()
    if MDT_NPT.state and MDT_NPT.state.active and Scenario and Scenario.onScenarioForcesUpdate then
      Scenario.onScenarioForcesUpdate()
    end
  end)

  self:UpdateAll()
  print("|cFF00FF00MDT-NextPullTracker|r: Tracking started. Pull 1 is next.")
end

function MDT_NPT:Stop()
  startGeneration = startGeneration + 1
  MDT_NPT.state = nil

  eventFrame:UnregisterEvent("SCENARIO_CRITERIA_UPDATE")
  eventFrame:UnregisterEvent("SCENARIO_UPDATE")
  eventFrame:UnregisterEvent("CHALLENGE_MODE_COMPLETED")
  eventFrame:UnregisterEvent("CHALLENGE_MODE_RESET")

  if pollTimer then
    pollTimer:Cancel()
    pollTimer = nil
  end

  self:UpdateAll()
  print("|cFF00FF00MDT-NextPullTracker|r: Tracking stopped.")
end

---Maybe show the non-tank prompt on dungeon start
local function maybePromptForBeacon()
  if not db.beacon.askOnStart then return end
  if db.beacon.showForNonTank then return end -- already opted in
  local role = Wow and Wow.getPlayerRole and Wow.getPlayerRole() or nil
  if role == "TANK" then return end -- tanks don't need to be asked
  -- Delay the popup slightly so it appears after UI is stable
  C_Timer.After(1, function()
    StaticPopup_Show("NPT_BEACON_ASK")
  end)
end

-- =====================================================================
-- Lifecycle events
-- =====================================================================

eventFrame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    local addon = ...
    if addon == AddonName then
      local childDB = LibStub("AceDB-3.0"):New("MythicDungeonToolsNextPullDB", defaultSavedVars, true)
      db = childDB.global
      dbChar = childDB.char
      -- First-load plan init: fill cooldownPotionID from seed default + migration version (design 8.2/5.4).
      if MDT_NPT.CooldownData then
        MDT_NPT.CooldownData.InitializePlans(dbChar)
      end
      eventFrame:UnregisterEvent("ADDON_LOADED")
    end
  elseif event == "CHALLENGE_MODE_START" then
    if db and db.enabled and db.autoStartInKey then
      MDT_NPT:Start(false, nil, nil, true)
    end
    maybePromptForBeacon()
  elseif event == "CHALLENGE_MODE_COMPLETED" or event == "CHALLENGE_MODE_RESET" then
    MDT_NPT:Stop()
  elseif event == "SCENARIO_CRITERIA_UPDATE" or event == "SCENARIO_UPDATE" then
    if Scenario and Scenario.onScenarioForcesUpdate then
      Scenario.onScenarioForcesUpdate()
    end
  end
end)

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHALLENGE_MODE_START")
