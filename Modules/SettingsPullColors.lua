local MDT_NPT = MDT_NPT
local L = MDT_NPT.L
local Theme = MDT_NPT.Theme

-- Custom settings widget for the per-state pull colors. Layout, top to bottom:
--   * a small minimap-style preview (display only) showing the next/active/
--     upcoming/off-route dots, with the outline ring around next/active;
--   * clickable color swatch buttons -- next & active each get a Dots and an
--     Outline swatch, upcoming and off-route each get a Dots swatch
--     (completed is fixed);
--   * a "Reset to Defaults" button.
--
-- Plain Buttons/Textures, not CreateSettingsButtonInitializer, whose signature
-- is not stable across client versions (it asserted on 12.0).

MDTNPTPullColorsMixin = {}

-- "pullColors" holds dot colors; "pullOutlineColors" holds outline colors.
local DOTS_DB = "pullColors"
local OUTLINE_DB = "pullOutlineColors"

-- Editable controls. `outline = true` adds an outline swatch for that state.
local CONTROLS = {
  { key = "next", labelKey = "Next", outline = true },
  { key = "active", labelKey = "Active", outline = true },
  { key = "upcoming", labelKey = "Upcoming", outline = false },
  { key = "unselected", labelKey = "Not on route", outline = false },
}
-- States drawn in the preview (left to right). `ring` = has an outline.
local PREVIEW_STATES = {
  { key = "next", ring = true },
  { key = "active", ring = true },
  { key = "upcoming", ring = false },
  { key = "unselected", ring = false },
}

local CIRCLE_TEX = Theme.textures.circleWhite
local BOX_COLOR = Theme.colors.settingsBoxBg
local DOT_OFFSETS = { { 0, 0 }, { 6, 3 }, { -5, 4 }, { 4, -5 }, { -5, -4 } }

-- Layout constants. LEFT_MARGIN matches the inset Blizzard's settings controls
-- and section headers use, so this widget lines up with the rest of the panel.
local LEFT_MARGIN = 37
local LABEL_X, DOT_X, OUTLINE_X = LEFT_MARGIN, LEFT_MARGIN + 130, LEFT_MARGIN + 240
local HEADER_Y = -68
local ROWS_TOP = -82
local ROW_H = 24
local SWATCH = 18

local function getColor(dbKey, stateKey)
  local db = MDT_NPT:GetDB()
  local c = db and db.beacon and db.beacon[dbKey] and db.beacon[dbKey][stateKey]
  if not c then return 1, 1, 1, 1 end
  return c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
end

local function refreshBeacon()
  if MDT_NPT.Beacon and MDT_NPT.Beacon.Update then
    MDT_NPT.Beacon:Update()
  end
end

---Creates a clickable color swatch button for one (db table, state) pair.
function MDTNPTPullColorsMixin:CreateSwatch(dbKey, stateKey, x, y)
  local swatch = CreateFrame("Button", nil, self)
  swatch:SetSize(SWATCH, SWATCH)
  swatch:SetPoint("TOPLEFT", self, "TOPLEFT", x, y)
  swatch.dbKey, swatch.stateKey = dbKey, stateKey

  local border = swatch:CreateTexture(nil, "BACKGROUND")
  border:SetPoint("TOPLEFT", -1, 1)
  border:SetPoint("BOTTOMRIGHT", 1, -1)
  border:SetColorTexture(unpack(Theme.colors.swatchBorder))

  local fill = swatch:CreateTexture(nil, "ARTWORK")
  fill:SetAllPoints()
  swatch.fill = fill

  swatch:SetScript("OnClick", function(btn) self:OpenColorPicker(btn.dbKey, btn.stateKey) end)
  swatch:SetScript("OnEnter", function(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["Click to change this color."], 1, 1, 1)
    GameTooltip:Show()
  end)
  swatch:SetScript("OnLeave", function() GameTooltip:Hide() end)

  self.swatches[#self.swatches + 1] = swatch
  return swatch
end

---Builds one preview cluster (dots, plus a thin ring for current-pull states).
function MDTNPTPullColorsMixin:CreatePreviewCluster(state, centerX)
  local cluster = { key = state.key, dots = {} }

  if state.ring then
    local ringOuter = self:CreateTexture(nil, "BORDER")
    ringOuter:SetTexture(CIRCLE_TEX)
    ringOuter:SetSize(28, 28)
    ringOuter:SetPoint("CENTER", self, "TOP", centerX, -34)
    cluster.ringOuter = ringOuter

    local ringInner = self:CreateTexture(nil, "ARTWORK")
    ringInner:SetTexture(CIRCLE_TEX)
    ringInner:SetSize(24, 24)
    ringInner:SetPoint("CENTER", ringOuter, "CENTER")
    ringInner:SetVertexColor(BOX_COLOR[1], BOX_COLOR[2], BOX_COLOR[3], 1)
  end

  for i, off in ipairs(DOT_OFFSETS) do
    local dot = self:CreateTexture(nil, "OVERLAY")
    dot:SetTexture(CIRCLE_TEX)
    dot:SetSize(5, 5)
    dot:SetPoint("CENTER", self, "TOP", centerX + off[1], -34 + off[2])
    cluster.dots[i] = dot
  end

  return cluster
end

function MDTNPTPullColorsMixin:OnLoad()
  self.swatches = {}

  -- Preview backdrop.
  local box = self:CreateTexture(nil, "BACKGROUND")
  box:SetColorTexture(BOX_COLOR[1], BOX_COLOR[2], BOX_COLOR[3], 0.9)
  box:SetPoint("TOPLEFT", self, "TOPLEFT", LEFT_MARGIN, -6)
  box:SetPoint("TOPRIGHT", self, "TOPRIGHT", -LEFT_MARGIN, -6)
  box:SetHeight(52)

  self.previewClusters = {}
  local pn = #PREVIEW_STATES
  for i, state in ipairs(PREVIEW_STATES) do
    local centerX = (i - (pn + 1) / 2) * 84
    self.previewClusters[state.key] = self:CreatePreviewCluster(state, centerX)
  end

  -- Column headers for the swatch grid.
  local dotsHeader = self:CreateFontString(nil, "ARTWORK", Theme.fonts.highlightSmall)
  dotsHeader:SetPoint("LEFT", self, "TOPLEFT", DOT_X, HEADER_Y)
  dotsHeader:SetText(L["Dots"])
  local outlineHeader = self:CreateFontString(nil, "ARTWORK", Theme.fonts.highlightSmall)
  outlineHeader:SetPoint("LEFT", self, "TOPLEFT", OUTLINE_X, HEADER_Y)
  outlineHeader:SetText(L["Outline"])

  -- One row per editable state.
  for i, ctrl in ipairs(CONTROLS) do
    local y = ROWS_TOP - (i - 1) * ROW_H
    local label = self:CreateFontString(nil, "ARTWORK", Theme.fonts.normal)
    label:SetPoint("LEFT", self, "TOPLEFT", LABEL_X, y - SWATCH / 2)
    label:SetText(L[ctrl.labelKey])

    self:CreateSwatch(DOTS_DB, ctrl.key, DOT_X, y)
    if ctrl.outline then
      self:CreateSwatch(OUTLINE_DB, ctrl.key, OUTLINE_X, y)
    end
  end

  local reset = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
  reset:SetSize(150, 22)
  reset:SetText(L["Reset to Defaults"])
  reset:SetPoint("BOTTOM", self, "BOTTOM", 0, 6)
  reset:SetScript("OnClick", function() self:ResetDefaults() end)
  self.resetButton = reset

  MDT_NPT.pullColorsWidget = self
  self:UpdateVisuals()
end

---Repaints every swatch and preview cluster from the current saved colors.
function MDTNPTPullColorsMixin:UpdateVisuals()
  if self.swatches then
    for _, swatch in ipairs(self.swatches) do
      swatch.fill:SetColorTexture(getColor(swatch.dbKey, swatch.stateKey))
    end
  end
  if self.previewClusters then
    for key, cluster in pairs(self.previewClusters) do
      local r, g, b, a = getColor(DOTS_DB, key)
      for _, dot in ipairs(cluster.dots) do
        dot:SetVertexColor(r, g, b, a)
      end
      if cluster.ringOuter then
        cluster.ringOuter:SetVertexColor(getColor(OUTLINE_DB, key))
      end
    end
  end
end

-- Settings list re-binds the pooled frame to our category on each open.
function MDTNPTPullColorsMixin:Init()
  self:UpdateVisuals()
end

---Opens Blizzard's color picker (with opacity) for one (db table, state), live.
function MDTNPTPullColorsMixin:OpenColorPicker(dbKey, stateKey)
  local db = MDT_NPT:GetDB()
  if not (db and db.beacon) then return end
  db.beacon[dbKey] = db.beacon[dbKey] or {}
  local r, g, b, a = getColor(dbKey, stateKey)

  local function set(nr, ng, nb, na)
    db.beacon[dbKey][stateKey] = { nr, ng, nb, na }
    self:UpdateVisuals()
    refreshBeacon()
  end

  local function onChange()
    local nr, ng, nb = ColorPickerFrame:GetColorRGB()
    set(nr, ng, nb, ColorPickerFrame:GetColorAlpha())
  end

  ColorPickerFrame:SetupColorPickerAndShow({
    r = r, g = g, b = b,
    hasOpacity = true,
    opacity = a,
    swatchFunc = onChange,
    opacityFunc = onChange,
    cancelFunc = function(previous)
      if previous then set(previous.r, previous.g, previous.b, previous.a or 1) end
    end,
  })
end

---Restores dot and outline colors to BeaconMinimap's default palettes.
function MDTNPTPullColorsMixin:ResetDefaults()
  local db = MDT_NPT:GetDB()
  local minimap = MDT_NPT.BeaconMinimap
  if not (db and db.beacon and minimap) then return end

  local function restore(dbKey, defaults)
    if not defaults then return end
    db.beacon[dbKey] = db.beacon[dbKey] or {}
    for key, c in pairs(defaults) do
      db.beacon[dbKey][key] = { c[1], c[2], c[3], c[4] or 1 } -- copy, don't share refs
    end
  end

  restore(DOTS_DB, minimap.DEFAULT_PULL_COLORS)
  restore(OUTLINE_DB, minimap.DEFAULT_OUTLINE_COLORS)
  self:UpdateVisuals()
  refreshBeacon()
end
