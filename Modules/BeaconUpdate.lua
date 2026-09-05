local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT
local L = MDT_NPT.L
local db

local Beacon = MDT_NPT.Beacon

local BeaconFrame = MDT_NPT.BeaconFrame
local BeaconMinimap = MDT_NPT.BeaconMinimap
local Wow = MDT_NPT.Wow
local Utils = MDT_NPT.Utils
local Theme = MDT_NPT.Theme

function Beacon:Update()
  Theme.Refresh()
  local frame = self:GetFrame()

  if not db then db = MDT_NPT:GetDB() end
  if not db.beacon.enabled then
    Beacon:Hide()
    return
  end

  local state = MDT_NPT.state
  if not state or not state.active then
    Beacon:Hide()
    return
  end

  -- Role check: hide for non-tanks unless overridden or user manually started tracking.
  -- showCooldownPlan (design 12.2) also forces visibility for non-tanks (first of the two
  -- intentional modifications to NPT's own logic).
  if not db.beacon.showForNonTank and not db.beacon.showCooldownPlan and not state.manuallyStarted then
    local role = Wow and Wow.getPlayerRole and Wow.getPlayerRole() or nil
    if role ~= "TANK" then
      Beacon:Hide()
      return
    end
  end

  local dungeonIndex = state.dungeonIndex
  local totalForcesMax = MDT.dungeonTotalCount[dungeonIndex] and MDT.dungeonTotalCount[dungeonIndex].normal or 1
  -- Keep rendering the route that tracking was built from even if MDT's UI
  -- changes its own current dungeon selection later.
  local preset = MDT:GetCurrentPreset(dungeonIndex)
  local pulls = preset and preset.value and preset.value.pulls

  local nextPull = state.currentNextPull
  if not nextPull then
    BeaconFrame.renderRouteComplete(frame, state, totalForcesMax)
    Beacon:Show()
    return
  end

  local currentPercentage
  local numCriteria = Wow.getScenarioStepInfo()
  local bestPercentage, bestTotal = nil, 0

  for i = 1, numCriteria do
    local criteriaInfo = Wow.getScenarioCriteriaInfo(i)
    if criteriaInfo then
      local quantity = Utils.parseNum(criteriaInfo.quantity)
      local totalQuantity = Utils.parseNum(criteriaInfo.totalQuantity)

      -- Weighted progress: quantity is already the 0-100 percentage shown in-game.
      if criteriaInfo.isWeightedProgress and totalQuantity > 0 then
        currentPercentage = quantity
        break
      end

      if totalQuantity > bestTotal and totalQuantity > 10 then
        bestTotal = totalQuantity
        bestPercentage = (quantity / totalQuantity) * 100
      end
    end
  end

  if currentPercentage == nil then currentPercentage = bestPercentage end

  local pullState = state.pullStates[nextPull]

  BeaconFrame.renderPullHeader(frame, nextPull, pullState, #state.pullStates)

  local pullPercentage = (pullState.totalForces / totalForcesMax) * 100
  local bestPercentageForText = currentPercentage or 0

  -- Route target: cumulative forces % from pull 1 through this pull (from MDT preset)
  local cumulativeForces = 0
  for i = 1, nextPull do
    local cumulativePullState = state.pullStates[i]
    if cumulativePullState then
      cumulativeForces = cumulativeForces + (cumulativePullState.totalForces or 0)
    end
  end

  local targetPercentage = (cumulativeForces / totalForcesMax) * 100
  BeaconFrame.renderPercentageInfoText(
    frame,
    pullState.totalCount,
    bestPercentageForText,
    pullPercentage,
    targetPercentage
  )

  BeaconFrame.updateProgressBar(frame, currentPercentage)

  BeaconFrame.renderCurrentPullContribution(frame, bestPercentageForText, pullPercentage)

  local pull = pulls and pulls[nextPull]
  local enemies = MDT.dungeonEnemies[dungeonIndex]
  BeaconFrame.renderEnemiesPortraits(frame, pull, enemies)

  BeaconFrame.renderUpcomingPreview(
    frame,
    state.pullStates,
    nextPull,
    db.beacon.showUpcoming,
    totalForcesMax
  )

  local sublevel = (preset and preset.value and preset.value.currentSublevel) or 1

  local bounds = BeaconMinimap.calculatePullBounds(pull, sublevel, enemies)
  BeaconMinimap.applyZoom(frame, BeaconMinimap.computeZoomScale(bounds, frame.userZoomMultiplier))
  BeaconMinimap.loadTextures(frame, dungeonIndex, sublevel)

  if bounds then
    BeaconMinimap.centerMinimapOnPull(frame, bounds.centroidX, bounds.centroidY)
  end
  BeaconMinimap.updateMinimapDots(frame, state, pulls, enemies, sublevel)
  BeaconMinimap.drawCurrentPullOutline(frame, pull, sublevel, enemies, pullState and pullState.state)

  -- Cooldown plan icon rows (design 11.1): render before Show so layout is final.
  if MDT_NPT.CooldownPlanRender then
    MDT_NPT.CooldownPlanRender:Render(frame, state, preset, nextPull)
  end

  Beacon:Show()
end
