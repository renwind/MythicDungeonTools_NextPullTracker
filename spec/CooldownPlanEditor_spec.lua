local mocks = require("wow_mocks")

describe("CooldownPlanEditor.lua", function()
  local Editor

  -- Install an MDT adapter stub whose GetCurrentPreset returns `preset`.
  local function setPreset(preset, dbCurrentDungeonIdx)
    _G.MDT_NPT.MDT = {
      GetCurrentPreset = function() return preset end,
      GetDB = function() return { currentDungeonIdx = dbCurrentDungeonIdx } end,
    }
  end

  before_each(function()
    mocks.reset()
    _G.InCombatLockdown = function() return false end
    _G.UIParent = {}
    mocks.loadSource("Modules/CooldownPlanEditor.lua")
    Editor = _G.MDT_NPT.CooldownPlanEditor
  end)

  -- A fake frame that inherits the real mixin methods but stubs the two
  -- frame-only rebuild methods, so the pure route-tracking logic can be
  -- exercised without real CreateFrame widgets.
  local function makeFrame()
    local frame = setmetatable({}, { __index = _G.MDTNPTCooldownPlanMixin })
    frame.rebuildWaveCalls = 0
    frame.rebuildCellCalls = 0
    function frame:RebuildWaveList() self.rebuildWaveCalls = self.rebuildWaveCalls + 1 end
    function frame:RebuildCells() self.rebuildCellCalls = self.rebuildCellCalls + 1 end
    return frame
  end

  describe("ReloadPlans", function()
    it("stores the current route's uid, pull count and dungeon index", function()
      setPreset({ uid = "route-a", value = { currentDungeonIdx = 7, pulls = { {}, {}, {} } } })
      local frame = makeFrame()
      frame:ReloadPlans()
      assert.equals("route-a", frame.uid)
      assert.equals(3, frame.pullCount)
      assert.equals(7, frame.dungeonIndex)
    end)

    it("normalizes an empty uid to nil and falls back to the db dungeon index", function()
      setPreset({ uid = "", value = { pulls = {} } }, 12)
      local frame = makeFrame()
      frame:ReloadPlans()
      assert.is_nil(frame.uid)
      assert.equals(0, frame.pullCount)
      assert.equals(12, frame.dungeonIndex)
    end)
  end)

  describe("CheckRouteChanged", function()
    it("returns false and does not reload when the route is unchanged", function()
      setPreset({ uid = "route-a", value = { currentDungeonIdx = 7, pulls = { {}, {} } } })
      local frame = makeFrame()
      frame:ReloadPlans()
      local before = frame.rebuildCellCalls
      assert.is_false(frame:CheckRouteChanged())
      assert.equals(before, frame.rebuildCellCalls)
    end)

    it("reloads when the route uid changes (user switched MDT route)", function()
      local preset = { uid = "route-a", value = { currentDungeonIdx = 7, pulls = { {}, {} } } }
      setPreset(preset)
      local frame = makeFrame()
      frame:ReloadPlans()
      preset.uid = "route-b"
      assert.is_true(frame:CheckRouteChanged())
      assert.equals("route-b", frame.uid)
    end)

    it("reloads when the pull count changes (pulls edited in MDT)", function()
      local preset = { uid = "route-a", value = { currentDungeonIdx = 7, pulls = { {}, {} } } }
      setPreset(preset)
      local frame = makeFrame()
      frame:ReloadPlans()
      table.insert(preset.value.pulls, {})
      assert.is_true(frame:CheckRouteChanged())
      assert.equals(3, frame.pullCount)
    end)

    it("reloads when the dungeon index changes", function()
      local preset = { uid = "route-a", value = { currentDungeonIdx = 7, pulls = { {} } } }
      setPreset(preset)
      local frame = makeFrame()
      frame:ReloadPlans()
      preset.value.currentDungeonIdx = 9
      assert.is_true(frame:CheckRouteChanged())
      assert.equals(9, frame.dungeonIndex)
    end)
  end)

  describe("OnShow / OnHide", function()
    local function makePollableFrame()
      local frame = makeFrame()
      frame.scripts = {}
      function frame:SetScript(name, fn) self.scripts[name] = fn end
      return frame
    end

    it("arms an OnUpdate poll on show and clears it on hide", function()
      setPreset({ uid = "route-a", value = { currentDungeonIdx = 7, pulls = { {} } } })
      local frame = makePollableFrame()
      frame:OnShow()
      assert.is_function(frame.scripts.OnUpdate)
      frame:OnHide()
      assert.is_nil(frame.scripts.OnUpdate)
    end)

    it("reloads via the poll only after the throttle interval elapses", function()
      local preset = { uid = "route-a", value = { currentDungeonIdx = 7, pulls = { {} } } }
      setPreset(preset)
      local frame = makePollableFrame()
      frame:OnShow()
      preset.uid = "route-b"
      local poll = frame.scripts.OnUpdate
      poll(frame, 0.1) -- below the 0.5s throttle: no reload yet
      assert.equals("route-a", frame.uid)
      poll(frame, 0.5) -- accumulated past the threshold: reload fires
      assert.equals("route-b", frame.uid)
    end)
  end)

  describe("Refresh", function()
    it("does nothing when no editor frame has been created", function()
      assert.has_no.errors(function() Editor:Refresh() end)
    end)

    it("reloads the editor frame when it is open", function()
      setPreset({ uid = "route-a", value = { currentDungeonIdx = 7, pulls = { {} } } })
      local reloadCount = 0
      _G.CreateFrame = function()
        return {
          shown = false,
          Show = function(self) self.shown = true end,
          IsShown = function(self) return self.shown end,
          ReloadPlans = function() reloadCount = reloadCount + 1 end,
        }
      end
      Editor:Open()
      Editor:Refresh()
      assert.equals(1, reloadCount)
    end)
  end)
end)
