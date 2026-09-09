local MDT_NPT                   = MDT_NPT
local L                         = MDT_NPT.L

local Settings_API              = _G.Settings

local M                         = {}
MDT_NPT.Settings                = M

-- Key-binding labels surfaced under WoW's Esc → Key Bindings → Addons.
-- Matches the suffixes used in Bindings.xml (header="MDTNPT_HEADER", name="MDTNPT_*").
_G.BINDING_HEADER_MDTNPT_HEADER = L["MDT Next Pull Tracker"]
_G.BINDING_NAME_MDTNPT_TOGGLE   = L["Toggle Beacon"]
_G.BINDING_NAME_MDTNPT_NEXT     = L["Next Pull"]
_G.BINDING_NAME_MDTNPT_PREV     = L["Previous Pull"]
_G.BINDING_NAME_MDTNPT_LOCK     = L["Toggle Lock"]
_G.BINDING_NAME_MDTNPT_SETTINGS = L["Open Settings"]

local categoryRef

local function getDB() return MDT_NPT:GetDB() end

local function makeBoolProxy(category, variable, name, defaultValue, tooltip, getter, setter, onChange)
  local setting = Settings_API.RegisterProxySetting(
    category,
    variable,
    type(defaultValue),
    name,
    defaultValue,
    getter,
    function(value)
      setter(value)
      if onChange then onChange(value) end
    end
  )
  Settings_API.CreateCheckbox(category, setting, tooltip)
  return setting
end

local function makeBeaconBool(category, variable, name, key, tooltip, onChange, defaultValue)
  if defaultValue == nil then defaultValue = true end
  return makeBoolProxy(
    category, variable, name, defaultValue, tooltip,
    function()
      local db = getDB()
      return db and db.beacon and db.beacon[key]
    end,
    function(value)
      local db = getDB()
      if db and db.beacon then db.beacon[key] = value end
    end,
    onChange
  )
end

local function makeRootBool(category, variable, name, key, tooltip, onChange)
  return makeBoolProxy(
    category, variable, name, true, tooltip,
    function()
      local db = getDB()
      return db and db[key]
    end,
    function(value)
      local db = getDB()
      if db then db[key] = value end
    end,
    onChange
  )
end

local function refreshBeacon()
  if MDT_NPT.Beacon and MDT_NPT.Beacon.Update then
    MDT_NPT.Beacon:Update()
  end
end

local function buildPanel()
  local category, layout = Settings_API.RegisterVerticalLayoutCategory(L["MDT Next Pull Tracker"])
  categoryRef = category

  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L["General"]))

  makeRootBool(category, "MDTNPT_ENABLED", L["Enable Tracking"],
    "enabled", L["Master toggle for tracking and the beacon HUD."],
    refreshBeacon)

  makeRootBool(category, "MDTNPT_AUTOSTART", L["Auto-start in Mythic+"],
    "autoStartInKey", L["Begin tracking automatically when a Mythic+ key starts."])

  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L["Beacon"]))

  makeBeaconBool(category, "MDTNPT_BEACON_ENABLED", L["Show Beacon"],
    "enabled", L["Show or hide the beacon HUD."],
    refreshBeacon)

  makeBeaconBool(category, "MDTNPT_BEACON_LOCKED", L["Locked"],
    "locked", L["When locked, the beacon cannot be dragged or resized."])

  makeBeaconBool(category, "MDTNPT_BEACON_UPCOMING", L["Show Upcoming"],
    "showUpcoming", L["Preview the pull after the current one."],
    refreshBeacon)

  makeBeaconBool(category, "MDTNPT_BEACON_UNSELECTED", L["Show monsters not on route"],
    "showUnselected", L["Display dungeon monsters that are not selected in any pull of the route."],
    refreshBeacon, false)

  makeBeaconBool(category, "MDTNPT_BEACON_MAPONLY", L["Map Only"],
    "mapOnly", L["Show only the minimap, hiding the pull info panel."],
    refreshBeacon, false)

  makeBeaconBool(category, "MDTNPT_BEACON_NOTES", L["Show Notes"],
    "showNpcNotes", L["Show note strips above the beacon for the current pull and its annotated mobs."],
    refreshBeacon, false)

  makeBeaconBool(category, "MDTNPT_BEACON_NONTANK", L["Show for non-tanks"],
    "showForNonTank", L["Display the beacon for healers and DPS, not only tanks."],
    refreshBeacon)

  makeBeaconBool(category, "MDTNPT_BEACON_ASK", L["Ask on Mythic+ start"],
    "askOnStart", L["Prompt non-tanks to display the beacon when a key starts."])

  -- Opacity slider: 30% → 100% in 5% steps.
  local alphaSetting = Settings_API.RegisterProxySetting(
    category, "MDTNPT_BEACON_ALPHA", "number", L["Opacity"], 1.0,
    function()
      local db = getDB()
      return (db and db.beacon and db.beacon.alpha) or 1.0
    end,
    function(value)
      MDT_NPT.Beacon:ApplyAlpha(value)
    end
  )
  local alphaOptions = Settings_API.CreateSliderOptions(0.3, 1.0, 0.05)
  alphaOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
    function(value) return string.format("%d%%", math.floor(value * 100 + 0.5)) end)
  Settings_API.CreateSlider(category, alphaSetting, alphaOptions,
    L["Make the beacon more transparent so it doesn't block your view."])

  -- Beacon scope dropdown.
  local scopeSetting = Settings_API.RegisterProxySetting(
    category, "MDTNPT_BEACON_SCOPE", "string", L["Beacon Scope"], "char",
    function()
      local db = getDB()
      return (db and db.beaconScope) or "char"
    end,
    function(value)
      local db = getDB()
      if db then db.beaconScope = value end
      refreshBeacon()
    end
  )
  local function scopeOptions()
    local container = Settings_API.CreateControlTextContainer()
    container:Add("char", L["Per Character"])
    container:Add("global", L["Account-wide"])
    return container:GetData()
  end
  Settings_API.CreateDropdown(category, scopeSetting, scopeOptions,
    L["Save the beacon position and size per character or shared across the account."])

  -- Pull colors: a clickable live preview per state (dots + ring) plus a
  -- reset-to-defaults button, for the minimap dots and the outline around the
  -- current pull. Lives in a custom widget (see SettingsPullColors.lua); wrapped
  -- so a failure can't block panel registration.
  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L["Pull Colors"]))
  pcall(function()
    local pullColorsInit = Settings_API.CreateElementInitializer("MDTNPTPullColorsTemplate", {})
    pullColorsInit.GetExtent = function() return 208 end
    layout:AddInitializer(pullColorsInit)
  end)

  Settings_API.RegisterAddOnCategory(category)
end

function M:Open()
  if not categoryRef then return end
  Settings_API.OpenToCategory(categoryRef:GetID())
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self)
  if Settings_API and Settings_API.RegisterVerticalLayoutCategory then
    buildPanel()
  end
  self:UnregisterAllEvents()
end)
