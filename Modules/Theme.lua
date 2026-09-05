--- Theme.lua — NPT single visual truth source with EUI dynamic bridge.
--
-- Every color, texture path, and font object name used by NPT's UI lives here.
-- At load time the module probes _G.EllesmereUI; when present it maps EUI's
-- palette over the built-in fallback so NPT automatically follows EUI themes.
-- When EUI is absent the built-in constants (extracted from EllesmereUI's own
-- defaults) ensure the same visual appearance.
--
-- Consumer modules capture `local Theme = MDT_NPT.Theme` at file scope and
-- read `Theme.colors.<token>` tables.  Hot render paths use indexed access
-- (`c[1], c[2], c[3], c[4]`) to avoid unpack() overhead.
--
-- Call `Theme.Refresh()` once per Beacon:Update() cycle to pick up any EUI
-- theme change without a /reload.

local _, MDT_NPT = ...
local Theme = {}

---------------------------------------------------------------------------
-- EUI detection (one-shot, re-probed lazily by Refresh if nil)
---------------------------------------------------------------------------
local EUI = nil
do
  local ok, ref = pcall(function() return _G.EllesmereUI end)
  if ok and type(ref) == "table" then EUI = ref end
end

local _fontPath  -- cached EUI font path (nil when EUI absent or has no font API)
local _refreshCallbacks = {}  -- registered chrome-refresh callbacks

---------------------------------------------------------------------------
-- Built-in fallback palette — values extracted from EllesmereUI defaults.
-- Each entry is {r, g, b, a}.  Comments note the hex origin or purpose.
---------------------------------------------------------------------------
local FALLBACK = {
  -- Accent (EUI #0CD29D)
  accent         = { 12/255, 210/255, 157/255, 1 },
  accentSoft     = { 12/255, 210/255, 157/255, 0.6 },   -- button border
  accentBar      = { 12/255, 210/255, 157/255, 0.8 },   -- progress bar fill
  accentHoverBg  = { 6/255,  105/255, 79/255,  0.9 },   -- hover (accent ×0.5)

  -- Panel chrome
  panelBg        = { 0.058, 0.058, 0.058, 0.9 },
  panelBorder    = { 1, 1, 1, 0.15 },                    -- EUI white low-opacity 1px
  minimapBg      = { 0.02, 0.02, 0.02, 1 },
  minimapBorder  = { 1, 1, 1, 0.15 },
  buttonBg       = { 0, 0, 0, 0.65 },

  -- Text
  textPrimary    = { 1, 1, 1, 1 },
  textSecondary  = { 0.8, 0.8, 0.8, 1 },
  textMuted      = { 0.6, 0.6, 0.6, 1 },
  shadow         = { 0, 0, 0, 1 },

  -- Status & progress (semantic colours — not derived from accent)
  statusCombat   = { 1, 0.3, 0.3, 1 },                  -- "In Combat" red
  progressCurrent= { 0, 0.75, 1, 0.8 },                 -- active bar blue
  progressPreview= { 1, 0.84, 0, 0.65 },                -- preview overlay gold
  progressBg     = { 0, 0, 0, 0.5 },

  -- Mob type (semantic game colours)
  mobCaster      = { 0x4C/255, 0xE0/255, 0xD2/255, 1 }, -- #4CE0D2
  mobMiniboss    = { 0x6E/255, 0x24/255, 0xEC/255, 1 }, -- #6E24EC
  mobBoss        = { 0xEB/255, 0x84/255, 0x26/255, 1 }, -- #EB8426
  mobOther       = { 0xAE/255, 0x12/255, 0x00/255, 1 }, -- #AE1200

  -- Cooldown plan (semantic)
  cdUse          = { 0, 1, 0.4, 1 },                    -- "use" green
  cdSave         = { 0.7, 0.2, 0.2, 1 },                -- "save" red-grey
  cdConflict     = { 1, 0.6, 0, 1 },                    -- conflict warning
  cdMismatch     = { 1, 0.8, 0, 1 },                    -- fingerprint mismatch
  cdEmpty        = { 0.3, 0.3, 0.3, 0.5 },              -- not planned

  -- Bloodlust / Heroism
  lustNotReady   = { 1, 0.3, 0.3, 1 },                  -- on CD text red
  lustReady      = { 0.6, 1, 0.6, 1 },                  -- ready icon green tint

  -- Settings panel
  settingsBoxBg  = { 0.06, 0.06, 0.06, 1 },
  swatchBorder   = { 0, 0, 0, 1 },
}

---------------------------------------------------------------------------
-- Theme.colors — mutable cache, updated in-place by Refresh().
-- Deep-copied from FALLBACK so each token is an independent table.
---------------------------------------------------------------------------
Theme.colors = {}
for k, v in pairs(FALLBACK) do
  Theme.colors[k] = { v[1], v[2], v[3], v[4] }
end

---------------------------------------------------------------------------
-- Pull colour defaults (canonical source — replaces BeaconMinimap.DEFAULT_*)
-- "next" entries share the accent table reference so they auto-follow EUI.
---------------------------------------------------------------------------
Theme.pullColors = {
  ["next"]       = Theme.colors.accent,
  ["active"]     = { 1, 0.5, 0, 1 },
  ["completed"]  = { 0.4, 0.4, 0.4, 0.6 },
  ["upcoming"]   = { 1, 1, 0, 0.7 },
  ["unselected"] = { 0.75, 0.75, 0.75, 0.7 },
}

Theme.pullOutlineColors = {
  ["next"]   = Theme.colors.accent,
  ["active"] = { 1, 0.5, 0, 1 },
}

---------------------------------------------------------------------------
-- Shared texture paths
---------------------------------------------------------------------------
Theme.textures = {
  circleWhite = "Interface\\AddOns\\MythicDungeonTools\\Textures\\Circle_White",
  statusBar   = "Interface\\TargetingFrame\\UI-StatusBar",
}

---------------------------------------------------------------------------
-- Font object names — defaults point to WoW globals; when EUI provides a
-- custom font path, refreshFonts() creates NPT_* FontObjects and updates
-- these values so every consumer automatically uses the bridged font.
---------------------------------------------------------------------------
local FONT_DEFAULTS = {
  large          = "GameFontNormalLarge",
  small          = "GameFontNormalSmall",
  normal         = "GameFontNormal",
  highlightSmall = "GameFontHighlightSmall",
  npcName        = "GameFontNormalSmall",   -- no built-in 6pt font; fall back to 10pt
  cdText         = "GameFontNormalSmall",   -- no built-in 11pt font; fall back to 10pt
}

--- Custom FontObject definitions: key = Theme.fonts slot, obj = global name,
--- size = pt size matching the GameFont* counterpart, flags = font flags.
local FONT_DEFS = {
  large          = { obj = "NPT_FontNormalLarge",    size = 14, flags = "" },
  small          = { obj = "NPT_FontNormalSmall",    size = 10, flags = "" },
  normal         = { obj = "NPT_FontNormal",         size = 12, flags = "" },
  highlightSmall = { obj = "NPT_FontHighlightSmall", size = 10, flags = "" },
  npcName        = { obj = "NPT_FontNpcName",        size = 10, flags = "OUTLINE" },
  cdText         = { obj = "NPT_FontCdText",         size = 11, flags = "OUTLINE" },
}

Theme.fonts = {}
for k, v in pairs(FONT_DEFAULTS) do Theme.fonts[k] = v end

---------------------------------------------------------------------------
-- Internal: update a colour sub-table in-place (no table rebuild).
---------------------------------------------------------------------------
local function setColor(tbl, r, g, b, a)
  tbl[1], tbl[2], tbl[3], tbl[4] = r, g, b, a or 1
end

---------------------------------------------------------------------------
-- Theme.Refresh() — call once per Beacon:Update() cycle.
-- Re-reads EUI colours via pcall; on failure retains previous values.
---------------------------------------------------------------------------
function Theme.Refresh()
  -- Lazy re-probe: if EUI wasn't available at load time it may have loaded since.
  if not EUI then
    local ok, ref = pcall(function() return _G.EllesmereUI end)
    if ok and type(ref) == "table" then
      EUI = ref
    else
      return  -- no EUI, nothing to refresh
    end
  end

  -- Accent colour from EUI
  if type(EUI.GetAccentColor) == "function" then
    local ok, r, g, b = pcall(EUI.GetAccentColor, EUI)
    if ok and r then
      setColor(Theme.colors.accent,        r, g, b, 1)
      setColor(Theme.colors.accentSoft,    r, g, b, 0.6)
      setColor(Theme.colors.accentBar,     r, g, b, 0.8)
      setColor(Theme.colors.accentHoverBg, r * 0.5, g * 0.5, b * 0.5, 0.9)
      -- pullColors/pullOutlineColors["next"] share the accent table — already updated.
    end
  end

  -- Panel background colour from EUI (probe multiple possible API names)
  local bgBridged = false
  for _, fnName in ipairs({ "GetBackdropColor", "GetPanelColor", "GetPanelBgColor" }) do
    if type(EUI[fnName]) == "function" then
      local ok, r, g, b, a = pcall(EUI[fnName], EUI)
      if ok and r then
        setColor(Theme.colors.panelBg, r, g, b, a or 0.9)
        bgBridged = true
        break
      end
    end
  end

  -- Panel border colour from EUI
  local borderBridged = false
  for _, fnName in ipairs({ "GetBorderColor", "GetPanelBorderColor" }) do
    if type(EUI[fnName]) == "function" then
      local ok, r, g, b, a = pcall(EUI[fnName], EUI)
      if ok and r then
        setColor(Theme.colors.panelBorder, r, g, b, a or 0.15)
        borderBridged = true
        break
      end
    end
  end

  -- Font path from EUI
  if type(EUI.GetFontPath) == "function" then
    local ok, path = pcall(EUI.GetFontPath, EUI)
    if ok and type(path) == "string" then
      _fontPath = path
    end
  end

  -- Apply font bridge: create / update NPT_* FontObjects when EUI provides a
  -- font path, or fall back to the built-in GameFont* names when absent.
  if _fontPath then
    for key, def in pairs(FONT_DEFS) do
      local fontObj = _G[def.obj]
      if not fontObj then
        fontObj = CreateFont(def.obj)
      end
      fontObj:SetFont(_fontPath, def.size, def.flags)
      Theme.fonts[key] = def.obj
    end
  else
    for key, default in pairs(FONT_DEFAULTS) do
      Theme.fonts[key] = default
    end
  end

  -- Notify registered consumers (e.g. BeaconFrame chrome) of colour changes.
  for i = 1, #_refreshCallbacks do
    local cbOk, cbErr = pcall(_refreshCallbacks[i])
    -- silently drop broken callbacks
  end
end

---------------------------------------------------------------------------
-- Public helpers
---------------------------------------------------------------------------

--- Returns true when EllesmereUI was detected (cached).
function Theme.IsEUIAvailable()
  return EUI ~= nil
end

--- Returns the EUI font file path, or nil when EUI is absent / has no font API.
function Theme.GetFontPath()
  return _fontPath
end

--- Register a callback to be invoked at the end of every Theme.Refresh().
--- Used by BeaconFrame to re-apply panel chrome colours without tight coupling.
function Theme.RegisterRefreshCallback(fn)
  if type(fn) == "function" then
    _refreshCallbacks[#_refreshCallbacks + 1] = fn
  end
end

---------------------------------------------------------------------------
-- Theme.CreateBorder(parent) — 4×1px edge textures, EUI pixel-perfect style.
-- Returns { top, bottom, left, right }.
---------------------------------------------------------------------------
function Theme.CreateBorder(parent)
  local c = Theme.colors.panelBorder
  local edges = {}

  local top = parent:CreateTexture(nil, "BORDER")
  top:SetColorTexture(c[1], c[2], c[3], c[4])
  top:SetPoint("TOPLEFT")
  top:SetPoint("TOPRIGHT")
  top:SetHeight(1)
  edges.top = top

  local bottom = parent:CreateTexture(nil, "BORDER")
  bottom:SetColorTexture(c[1], c[2], c[3], c[4])
  bottom:SetPoint("BOTTOMLEFT")
  bottom:SetPoint("BOTTOMRIGHT")
  bottom:SetHeight(1)
  edges.bottom = bottom

  local left = parent:CreateTexture(nil, "BORDER")
  left:SetColorTexture(c[1], c[2], c[3], c[4])
  left:SetPoint("TOPLEFT")
  left:SetPoint("BOTTOMLEFT")
  left:SetWidth(1)
  edges.left = left

  local right = parent:CreateTexture(nil, "BORDER")
  right:SetColorTexture(c[1], c[2], c[3], c[4])
  right:SetPoint("TOPRIGHT")
  right:SetPoint("BOTTOMRIGHT")
  right:SetWidth(1)
  edges.right = right

  return edges
end

---------------------------------------------------------------------------
-- Theme.UpdateBorder(edges, colorOverride) — recolour an existing border
-- set returned by CreateBorder.  Uses panelBorder when no override given.
---------------------------------------------------------------------------
function Theme.UpdateBorder(edges, colorOverride)
  if not edges then return end
  local c = colorOverride or Theme.colors.panelBorder
  for _, key in ipairs({ "top", "bottom", "left", "right" }) do
    if edges[key] then
      edges[key]:SetColorTexture(c[1], c[2], c[3], c[4])
    end
  end
end

---------------------------------------------------------------------------
-- Theme.StyleButton(btn, label, fontObj) — EUI-style accent hover button.
-- Creates bg/border textures, a centred FontString, and hover scripts.
-- Returns the FontString so the caller can update its text later.
---------------------------------------------------------------------------
function Theme.StyleButton(btn, label, fontObj)
  local bgC     = Theme.colors.buttonBg
  local borderC = Theme.colors.accentSoft
  local textC   = Theme.colors.accent
  local hoverC  = Theme.colors.accentHoverBg

  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(bgC[1], bgC[2], bgC[3], bgC[4])

  local border = btn:CreateTexture(nil, "BORDER")
  border:SetPoint("TOPLEFT", btn, "TOPLEFT", -1, 1)
  border:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 1, -1)
  border:SetColorTexture(borderC[1], borderC[2], borderC[3], borderC[4])

  local text = btn:CreateFontString(nil, "OVERLAY", fontObj or Theme.fonts.large)
  text:SetPoint("CENTER", btn, "CENTER", 0, 1)
  text:SetText(label or "")
  text:SetTextColor(textC[1], textC[2], textC[3], textC[4])

  btn:SetScript("OnEnter", function()
    bg:SetColorTexture(hoverC[1], hoverC[2], hoverC[3], hoverC[4])
  end)
  btn:SetScript("OnLeave", function()
    bg:SetColorTexture(bgC[1], bgC[2], bgC[3], bgC[4])
  end)

  return text
end

---------------------------------------------------------------------------
-- Initial resolve + registration
---------------------------------------------------------------------------
Theme.Refresh()

MDT_NPT.Theme = Theme
