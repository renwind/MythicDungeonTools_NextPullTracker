local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT
local pairs, ipairs, tonumber, type = pairs, ipairs, tonumber, type
local math_max, math_min, math_huge = math.max, math.min, math.huge
local math_cos, math_sin, math_pi = math.cos, math.sin, math.pi
local table_sort = table.sort
local Theme = MDT_NPT.Theme

local SIZE = 208                -- viewport width/height in pixels
local GRID_COLS = 15
local GRID_ROWS = 10
local BASE_TILE = 840 / GRID_COLS -- 56 world units per tile in MDT's native coord space

-- Adaptive zoom bounds
local PADDING = 40                              -- world units padded around the pull bbox
local MIN_BBOX = 120                            -- floor on bbox size so single-enemy pulls don't over-zoom
local MIN_SCALE = SIZE / (GRID_COLS * BASE_TILE) -- "show whole map" floor (~0.179)
local AUTO_MAX_SCALE = 0.8                      -- cap for the auto-zoom calc (keeps tiny pulls from filling the viewport)
local MAX_SCALE = 2.5                           -- absolute cap, reachable only via user zoom
local DEFAULT_TILE_SIZE = 22                    -- initial tile pixel size before first render applies zoom

-- User-controlled zoom (applied on top of auto-zoom via mouse wheel)
local ZOOM_STEP = 1.2                           -- geometric factor per wheel tick
local USER_ZOOM_MIN = 0.5                       -- how far below auto-zoom the user may go
local USER_ZOOM_MAX = 6.0                       -- how far above auto-zoom the user may go (final scale still clamped by MAX_SCALE)

local function applyZoom(frame, scale)
  if not frame or not frame.minimapContainer or not frame.minimapTiles then return end
  frame.minimapScale = scale
  local tileSize = BASE_TILE * scale
  frame.minimapContainer:SetSize(GRID_COLS * tileSize, GRID_ROWS * tileSize)
  for i = 1, GRID_ROWS do
    for j = 1, GRID_COLS do
      local tileIndex = (i - 1) * GRID_COLS + j
      local tile = frame.minimapTiles[tileIndex]
      if tile then
        tile:SetSize(tileSize, tileSize)
        tile:SetPoint(
          "TOPLEFT",
          frame.minimapContainer,
          "TOPLEFT",
          (j - 1) * tileSize,
          -(i - 1) * tileSize
        )
      end
    end
  end
end

---Loads dungeon map textures into the mini-map tiles of the given beacon frame.
local function loadTextures(beaconFrame, dungeonIndex, sublevel)
  if not beaconFrame or not beaconFrame.minimapTiles then return end

  local dungeonMaps = MDT.dungeonMaps and MDT.dungeonMaps[dungeonIndex]
  if not dungeonMaps then return end

  local textureInfo = dungeonMaps[sublevel] or dungeonMaps[1]
  if not textureInfo then return end

  for i = 1, GRID_ROWS do
    for j = 1, GRID_COLS do
      local tileIndex = (i - 1) * GRID_COLS + j
      local tile = beaconFrame.minimapTiles[tileIndex]
      if tile then
        local textureName
        if type(textureInfo) == "string" then
          local mapName = MDT.mapInfo[dungeonIndex] and MDT.mapInfo[dungeonIndex].englishName or ""
          textureName = "Interface\\WorldMap\\"..mapName.."\\"..textureInfo..tileIndex
        elseif type(textureInfo) == "table" then
          textureName = textureInfo.customTextures.."\\"..(sublevel or 1).."_"..tileIndex..".png"
        end

        if textureName then
          tile:SetTexture(textureName)
          tile:Show()
        else
          tile:Hide()
        end
      end
    end
  end
end

---Computes the centroid and axis-aligned bounding box of the given pull's enemies on the active sublevel.
local function calculatePullBounds(pull, sublevel, enemies)
  if not pull or not enemies then return nil end

  local sumX, sumY, count = 0, 0, 0
  local minX, minY = math_huge, math_huge
  local maxX, maxY = -math_huge, -math_huge
  for enemyIndex, clones in pairs(pull) do
    if tonumber(enemyIndex) and enemies[enemyIndex] then
      for _, cloneIndex in ipairs(clones) do
        local clone = enemies[enemyIndex].clones and enemies[enemyIndex].clones[cloneIndex]
        if clone and (clone.sublevel == sublevel or not clone.sublevel) then
          sumX = sumX + clone.x
          sumY = sumY + clone.y
          count = count + 1
          if clone.x < minX then minX = clone.x end
          if clone.x > maxX then maxX = clone.x end
          if clone.y < minY then minY = clone.y end
          if clone.y > maxY then maxY = clone.y end
        end
      end
    end
  end
  if count == 0 then return nil end
  return {
    centroidX = sumX / count,
    centroidY = sumY / count,
    minX = minX, minY = minY,
    maxX = maxX, maxY = maxY,
  }
end

---Picks a zoom scale that fits the pull's bbox + padding into the viewport, clamped to sane bounds.
---`userMultiplier` (default 1) lets the user override the auto-zoom via mouse wheel.
local function computeZoomScale(bounds, userMultiplier)
  userMultiplier = userMultiplier or 1
  local scale
  if not bounds then
    scale = MIN_SCALE
  else
    local bboxW = math_max(bounds.maxX - bounds.minX, MIN_BBOX)
    local bboxH = math_max(bounds.maxY - bounds.minY, MIN_BBOX)
    scale = math_min(SIZE / (bboxW + 2 * PADDING), SIZE / (bboxH + 2 * PADDING))
    scale = math_min(scale, AUTO_MAX_SCALE)
  end
  return math_max(MIN_SCALE, math_min(MAX_SCALE, scale * userMultiplier))
end

---Bumps the user's zoom multiplier one wheel tick in the given direction, clamped to sane bounds.
local function adjustUserZoom(frame, delta)
  if not frame then return end
  local mult = frame.userZoomMultiplier or 1
  mult = mult * (delta > 0 and ZOOM_STEP or (1 / ZOOM_STEP))
  if mult < USER_ZOOM_MIN then mult = USER_ZOOM_MIN end
  if mult > USER_ZOOM_MAX then mult = USER_ZOOM_MAX end
  frame.userZoomMultiplier = mult
end

---Pans the container so the given centroid lands at the viewport's center,
---but clamps the offset so the container never leaves the viewport partially
---uncovered (no black space on any side). If the container is smaller than the
---viewport on an axis (e.g. height at MIN_SCALE for wide maps), the container
---is centered on that axis instead.
local function centerMinimapOnPull(frame, centroidX, centroidY)
  if not frame or not frame.minimapContainer then return end
  local scale = frame.minimapScale or MIN_SCALE
  local containerW = GRID_COLS * BASE_TILE * scale
  local containerH = GRID_ROWS * BASE_TILE * scale

  local panX = -centroidX * scale + SIZE / 2
  local panY = -centroidY * scale - SIZE / 2

  if containerW <= SIZE then
    panX = (SIZE - containerW) / 2
  else
    if panX > 0 then panX = 0 end
    if panX < SIZE - containerW then panX = SIZE - containerW end
  end

  if containerH <= SIZE then
    panY = (containerH - SIZE) / 2
  else
    if panY < 0 then panY = 0 end
    if panY > containerH - SIZE then panY = containerH - SIZE end
  end

  frame.minimapContainer:ClearAllPoints()
  frame.minimapContainer:SetPoint("TOPLEFT", frame.minimapFrame, "TOPLEFT", panX, panY)
end

local function getDot(frame, dotIndex)
  dotIndex = dotIndex + 1
  local dot = frame.dots[dotIndex]
  if not dot then
    dot = frame.minimapContainer:CreateTexture(nil, "OVERLAY")
    dot:SetTexture("Interface\\AddOns\\MythicDungeonTools\\Textures\\Circle_White")
    frame.dots[dotIndex] = dot
  end
  return dot, dotIndex
end

local HALO_RADIUS = 18      -- world units: padding disc around each enemy so the hull wraps with slack
local HALO_SEGMENTS = 10    -- points sampled around each halo; more = rounder outline
local OUTLINE_THICKNESS = 2 -- pixels

-- Fallback palette, used when no saved color exists for a state:
-- next=green, active=orange, completed=gray, upcoming/unknown=yellow,
-- unselected (not included anywhere in the route)=light gray.
local DEFAULT_PULL_COLORS = Theme.pullColors

-- Default outline (circle) colors. Only the current pull (next/active) gets an
-- outline; defaults match the dot palette so the look is unchanged out of the box.
local DEFAULT_OUTLINE_COLORS = Theme.pullOutlineColors

---Returns the user-configured (or default) rgba DOT color for a pull state. Any
---state other than next/active/completed maps to the "upcoming" entry.
local function colorForPullState(pullState)
  local key = DEFAULT_PULL_COLORS[pullState] and pullState or "upcoming"
  local db = MDT_NPT:GetDB()
  local custom = db and db.beacon and db.beacon.pullColors and db.beacon.pullColors[key]
  local c = custom or DEFAULT_PULL_COLORS[key]
  return c[1], c[2], c[3], c[4] or 1
end

---Returns the user-configured (or default) rgba OUTLINE color for the current
---pull. States without a dedicated outline color fall back to the dot color.
local function outlineColorForPullState(pullState)
  local db = MDT_NPT:GetDB()
  local custom = db and db.beacon and db.beacon.pullOutlineColors and db.beacon.pullOutlineColors[pullState]
  local c = custom or DEFAULT_OUTLINE_COLORS[pullState]
  if c then return c[1], c[2], c[3], c[4] or 1 end
  return colorForPullState(pullState)
end

-- Precomputed unit offsets for the halo around each enemy
local haloOffsets = {}
for i = 1, HALO_SEGMENTS do
  local angle = (i - 1) * 2 * math_pi / HALO_SEGMENTS
  haloOffsets[i] = { x = math_cos(angle), y = math_sin(angle) }
end

---Collects a "halo" of points around each enemy in the pull on the active sublevel.
local function collectHaloPoints(pull, sublevel, enemies)
  local points = {}
  for enemyIndex, clones in pairs(pull) do
    if tonumber(enemyIndex) and enemies[enemyIndex] then
      for _, cloneIndex in ipairs(clones) do
        local clone = enemies[enemyIndex].clones and enemies[enemyIndex].clones[cloneIndex]
        if clone and (clone.sublevel == sublevel or not clone.sublevel) then
          for _, off in ipairs(haloOffsets) do
            points[#points + 1] = {
              x = clone.x + off.x * HALO_RADIUS,
              y = clone.y + off.y * HALO_RADIUS,
            }
          end
        end
      end
    end
  end
  return points
end

---Andrew's monotone chain convex hull. Returns vertices in CCW order; strips collinear points.
local function convexHull(points)
  local n = #points
  if n < 3 then return points end

  table_sort(points, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)

  local function cross(o, a, b)
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
  end

  local hull = {}
  for i = 1, n do
    while #hull >= 2 and cross(hull[#hull - 1], hull[#hull], points[i]) <= 0 do
      hull[#hull] = nil
    end
    hull[#hull + 1] = points[i]
  end

  local lowerPlusOne = #hull + 1
  for i = n - 1, 1, -1 do
    while #hull >= lowerPlusOne and cross(hull[#hull - 1], hull[#hull], points[i]) <= 0 do
      hull[#hull] = nil
    end
    hull[#hull + 1] = points[i]
  end

  hull[#hull] = nil -- last point duplicates the hull's starting point
  return hull
end

---Draws a polygonal outline that follows the shape of the current (next) pull's enemies.
---Pass `pull = nil` (or a pull with no enemies on this sublevel) to hide the outline.
---`pullState` selects the outline color (matches the dot palette).
local function drawCurrentPullOutline(frame, pull, sublevel, enemies, pullState)
  if not frame or not frame.minimapContainer then return end

  frame.outlineLines = frame.outlineLines or {}
  local lines = frame.outlineLines

  local function hideAll()
    for _, line in ipairs(lines) do line:Hide() end
  end

  if not pull or not enemies then hideAll() return end

  local points = collectHaloPoints(pull, sublevel, enemies)
  if #points < 3 then hideAll() return end

  local hull = convexHull(points)
  local hullSize = #hull
  if hullSize < 3 then hideAll() return end

  local scale = frame.minimapScale or MIN_SCALE
  local r, g, b, a = outlineColorForPullState(pullState)

  for i = 1, hullSize do
    local line = lines[i]
    if not line then
      line = frame.minimapContainer:CreateLine(nil, "OVERLAY", nil, -1)
      line:SetThickness(OUTLINE_THICKNESS)
      lines[i] = line
    end
    line:SetColorTexture(r, g, b, a)
    local va = hull[i]
    local vb = hull[(i % hullSize) + 1]
    line:SetStartPoint("TOPLEFT", frame.minimapContainer, va.x * scale, va.y * scale)
    line:SetEndPoint("TOPLEFT", frame.minimapContainer, vb.x * scale, vb.y * scale)
    line:Show()
  end

  for i = hullSize + 1, #lines do
    lines[i]:Hide()
  end
end

local function updateMinimapDots(frame, state, pulls, enemies, sublevel)
  if not frame or not frame.minimapContainer then return end
  if not enemies then return end

  local scale = frame.minimapScale or MIN_SCALE

  -- Hide all existing dots
  for _, dot in ipairs(frame.dots) do
    dot:Hide()
  end

  -- Draw dots for relevant pulls (next, +/-1 for context)
  local nextPull = state.currentNextPull
  if not nextPull then return end

  local dotIndex = 0

  -- Optionally draw every dungeon clone that is absent from the entire route.
  -- These are rendered first so route dots remain visually dominant if MDT ever
  -- provides overlapping clone coordinates.
  local db = MDT_NPT:GetDB()
  if db and db.beacon and db.beacon.showUnselected then
    local selected = {}
    for _, routePull in pairs(pulls or {}) do
      if type(routePull) == "table" then
        for enemyIndex, clones in pairs(routePull) do
          if tonumber(enemyIndex) and type(clones) == "table" then
            selected[enemyIndex] = selected[enemyIndex] or {}
            for _, cloneIndex in ipairs(clones) do
              selected[enemyIndex][cloneIndex] = true
            end
          end
        end
      end
    end

    local r, g, b, a = colorForPullState("unselected")
    for enemyIndex, enemy in pairs(enemies) do
      for cloneIndex, clone in pairs(enemy.clones or {}) do
        local selectedClones = selected[enemyIndex]
        if clone and not (selectedClones and selectedClones[cloneIndex])
          and (clone.sublevel == sublevel or not clone.sublevel) then
          local dot
          dot, dotIndex = getDot(frame, dotIndex)
          dot:SetVertexColor(r, g, b, a)
          dot:ClearAllPoints()
          dot:SetPoint("CENTER", frame.minimapContainer, "TOPLEFT", clone.x * scale, clone.y * scale)
          dot:SetSize(5, 5)
          dot:Show()
        end
      end
    end
  end

  for pullIndex = math.max(1, nextPull - 1), math.min(#pulls, nextPull + 1) do
    local pull = pulls[pullIndex]
    if pull then
      local pullState = state.pullStates[pullIndex] and state.pullStates[pullIndex].state
      local r, g, b, a = colorForPullState(pullState)

      for enemyIndex, clones in pairs(pull) do
        if tonumber(enemyIndex) and enemies[enemyIndex] then
          for _, cloneIndex in ipairs(clones) do
            local clone = enemies[enemyIndex].clones and enemies[enemyIndex].clones[cloneIndex]
            if clone and (clone.sublevel == sublevel or not clone.sublevel) then
              local dot
              dot, dotIndex = getDot(frame, dotIndex)
              dot:SetVertexColor(r, g, b, a)
              -- Position relative to the container (scaled from original coords)
              local scaledX = clone.x * scale
              local scaledY = clone.y * scale
              dot:ClearAllPoints()
              dot:SetPoint("CENTER", frame.minimapContainer, "TOPLEFT", scaledX, scaledY)
              dot:SetSize(5, 5)
              dot:Show()
            end
          end
        end
      end
    end
  end
end

MDT_NPT.BeaconMinimap = {
  SIZE = SIZE,
  GRID_COLS = GRID_COLS,
  GRID_ROWS = GRID_ROWS,
  BASE_TILE = BASE_TILE,
  DEFAULT_TILE_SIZE = DEFAULT_TILE_SIZE,
  MIN_SCALE = MIN_SCALE,
  MAX_SCALE = MAX_SCALE,
  applyZoom = applyZoom,
  loadTextures = loadTextures,
  calculatePullBounds = calculatePullBounds,
  computeZoomScale = computeZoomScale,
  adjustUserZoom = adjustUserZoom,
  centerMinimapOnPull = centerMinimapOnPull,
  updateMinimapDots = updateMinimapDots,
  drawCurrentPullOutline = drawCurrentPullOutline,
  DEFAULT_PULL_COLORS = DEFAULT_PULL_COLORS,
  DEFAULT_OUTLINE_COLORS = DEFAULT_OUTLINE_COLORS,
}
