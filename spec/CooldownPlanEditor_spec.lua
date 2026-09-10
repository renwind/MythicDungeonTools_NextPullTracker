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
          -- Open() docks the editor beside the beacon via ClearAllPoints/SetPoint;
          -- the mock only needs the calls to exist, their effect is irrelevant here.
          ClearAllPoints = function() end,
          SetPoint = function() end,
        }
      end
      Editor:Open()
      Editor:Refresh()
      assert.equals(1, reloadCount)
    end)
  end)
end)

-- 只替换 WoW 控件边界；执行真实数据、CRUD、RebuildCells 和点击处理。
describe("CooldownPlanEditor 真实单元格序号", function()
  before_each(function() mocks.reset() end)

  local function scenario(fn)
    mocks.withCooldownRuntime(function(env)
      mocks.loadSource("Modules/CooldownData.lua")
      mocks.loadSource("Modules/CooldownPlan.lua")
      mocks.loadSource("Modules/CooldownPlanEditor.lua")
      env.preset = { uid = "a", value = { pulls = { {}, {}, {}, {}, {}, {}, {} } } }
      MDT_NPT.MDT.GetCurrentPreset = function() return env.preset end
      MDT_NPT.Theme.colors.cdUse = { 0, 1, 0, 1 }
      local frame = setmetatable(CreateFrame("Frame"), { __index = MDTNPTCooldownPlanMixin })
      frame.cellArea = CreateFrame("Frame", nil, frame)
      frame.uid, frame.selectedPull = "a", 4
      fn(env, frame, MDT_NPT.CooldownPlan)
    end)
  end

  local function number(cell, expected)
    assert.is_not_nil(cell.ordinalText)
    assert.equals(tostring(expected), cell.ordinalText:GetText())
    assert.is_true(cell.ordinalText:IsShown())
  end

  local function emptyNumber(cell)
    assert.is_not_nil(cell.ordinalText)
    assert.equals("", cell.ordinalText:GetText())
    assert.is_false(cell.ordinalText:IsShown())
  end

  local function click(cell)
    cell.scripts.OnClick(cell, "LeftButton")
  end

  it("真实重建显示技能独立序号并保留开留标签", function()
    scenario(function(_, frame, store)
      store:SetEntry("a", 1, 114050, "spell", "use")
      store:SetEntry("a", 4, 1219480, "spell", "use")
      store:SetEntry("a", 4, 241308, "item", "use")
      frame:RebuildCells()
      local cells = frame.cellArea.cells
      number(cells[1], 2)
      number(cells[2], 1)
      assert.equals("Use", cells[1].label:GetText())
      assert.equals("Use", cells[2].label:GetText())
      assert.equals(cells[1], cells[1].ordinalText:GetParent())
      assert.equals("CENTER", cells[1].ordinalText.points[1][1])
      assert.same(MDT_NPT.Theme.colors.cdUse, cells[1].ordinalText.color)
    end)
  end)

  it("真实点击在未规划开留之间立即更新并清空旧数字", function()
    scenario(function(_, frame, store)
      local updates = 0
      MDT_NPT.Beacon = { Update = function() updates = updates + 1 end }
      frame:RebuildCells()
      local cell = frame.cellArea.cells[1]
      emptyNumber(cell)
      click(cell)
      number(cell, 1)
      assert.equals("use", store:Get("a", 4).entries[1].action)
      assert.is_nil(store:Get("a", 4).entries[1].useOrdinal)
      click(cell)
      emptyNumber(cell)
      assert.equals("Save", cell.label:GetText())
      click(cell)
      number(cell, 1)
      assert.equals(3, updates)
      store:ClearPull("a", 4)
      frame:RebuildCells()
      emptyNumber(cell)
      assert.equals("", cell.label:GetText())
    end)
  end)

  it("编辑前波后重新查看后波使用重算结果", function()
    scenario(function(_, frame, store)
      for _, index in ipairs({ 1, 4, 7 }) do store:SetEntry("a", index, 114050, "spell", "use") end
      frame.selectedPull = 7
      frame:RebuildCells()
      local cell = frame.cellArea.cells[1]
      number(cell, 3)
      frame.selectedPull = 1
      frame:RebuildCells()
      click(cell)
      emptyNumber(cell)
      frame.selectedPull = 7
      frame:RebuildCells()
      number(cell, 2)
    end)
  end)

  it("真实路线重载隔离序号且空 UID 清空数字", function()
    scenario(function(env, frame, store)
      store:SetEntry("a", 1, 114050, "spell", "use")
      store:SetEntry("a", 4, 114050, "spell", "use")
      store:SetEntry("b", 4, 114050, "spell", "use")
      frame:ReloadPlans()
      local cell = frame.cellArea.cells[1]
      number(cell, 2)
      env.preset.uid = "b"
      assert.is_true(frame:CheckRouteChanged())
      number(cell, 1)
      env.preset.uid = ""
      assert.is_true(frame:CheckRouteChanged())
      emptyNumber(cell)
      assert.equals("", cell.label:GetText())
    end)
  end)

  it("当前匹配跳过错误类型和动作并接受有效别名", function()
    scenario(function(env, frame)
      env.dbChar.cooldownPlans.a = { [4] = { entries = {
        { kind = "item", id = 114050, action = "save" },
        { kind = "spell", id = 114050, action = "invalid" },
        { kind = "spell", id = 1219480, action = "use" },
      } } }
      frame:RebuildCells()
      local cell = frame.cellArea.cells[1]
      assert.equals("use", cell.action)
      number(cell, 1)
    end)
  end)

  it("药水配置切换在复用单元格中重算并清理无匹配状态", function()
    scenario(function(env, frame, store)
      store:SetEntry("a", 1, 241308, "item", "use")
      store:SetEntry("a", 4, 241308, "item", "use")
      store:SetEntry("a", 4, 999, "item", "use")
      frame:RebuildCells()
      local cell = frame.cellArea.cells[2]
      number(cell, 2)
      env.dbChar.cooldownPotionID = 999
      frame:RebuildCells()
      number(cell, 1)
      assert.equals("item:999", cell.icon.texture)
      env.dbChar.cooldownPotionID = 888
      frame:RebuildCells()
      emptyNumber(cell)
    end)
  end)

  it("不支持专精隐藏多余单元格并清空数字和标签", function()
    scenario(function(env, frame, store)
      store:SetEntry("a", 4, 114050, "spell", "use")
      store:SetEntry("a", 4, 241308, "item", "use")
      frame:RebuildCells()
      local cells = frame.cellArea.cells
      number(cells[1], 1)
      number(cells[2], 1)
      env.specID = 263
      frame:RebuildCells()
      for _, cell in ipairs(cells) do
        assert.is_false(cell:IsShown())
        emptyNumber(cell)
        assert.equals("", cell.label:GetText())
        assert.is_nil(cell.action)
        assert.is_nil(cell.seedEntry)
      end
      env.specID = 262
      frame:RebuildCells()
      assert.equals(cells[1], frame.cellArea.cells[1])
      assert.is_true(cells[1]:IsShown())
      number(cells[1], 1)
    end)
  end)

  it("两位数字完整显示且切换到空波时清空", function()
    scenario(function(_, frame, store)
      for index = 1, 12 do store:SetEntry("a", index, 114050, "spell", "use") end
      frame.selectedPull = 12
      frame:RebuildCells()
      local cell = frame.cellArea.cells[1]
      number(cell, 12)
      frame.selectedPull = 13
      frame:RebuildCells()
      emptyNumber(cell)
      frame.selectedPull = nil
      frame:RebuildCells()
      emptyNumber(cell)
    end)
  end)
end)
