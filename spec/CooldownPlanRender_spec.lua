local mocks = require("wow_mocks")

-- 渲染入口、数据匹配、CRUD 和计时回调均使用生产实现；仅 WoW API 为可观测控件桩。
describe("CooldownPlanRender 真实渲染序号", function()
  before_each(function() mocks.reset() end)

  local function scenario(fn)
    mocks.withCooldownRuntime(function(env)
      MDT_NPT.Theme.colors.cdUse = { 0, 1, 0, 1 }
      MDT_NPT.Theme.colors.cdConflict = { 1, 0, 0, 1 }
      MDT_NPT.Theme.colors.cdMismatch = { 1, 0.8, 0, 1 }
      MDT_NPT.Theme.fonts.large = "GameFontNormalLarge"
      mocks.loadSource("Modules/CooldownData.lua")
      mocks.loadSource("Modules/CooldownPlan.lua")
      mocks.loadSource("Modules/CooldownPlanRender.lua")
      env.state = { presetUID = "a", currentNextPull = 7, dungeonIndex = 1, pullStates = {} }
      env.preset = { uid = "a", value = { currentDungeonIdx = 1, pulls = {} } }
      for i = 1, 40 do
        env.state.pullStates[i] = "upcoming"
        env.preset.value.pulls[i] = {}
      end
      MDT_NPT.MDT.GetCurrentPreset = function() return env.preset end
      local frame = CreateFrame("Frame")
      frame.cooldownIconsRow = CreateFrame("Frame", nil, frame)
      frame.upcomingIconsRow = CreateFrame("Frame", nil, frame)
      function frame:SetCdBandShown(shown) self.bandShown = shown end
      local store = MDT_NPT.CooldownPlan
      for _, i in ipairs({ 1, 4, 7, 8 }) do store:SetEntry("a", i, 114050, "spell", "use") end
      for _, i in ipairs({ 4, 7 }) do store:SetEntry("a", i, 241308, "item", "use") end
      store:SetEntry("a", 8, 241308, "item", "save")
      local function render(nextPull)
        MDT_NPT.CooldownPlanRender:Render(frame, env.state, env.preset, nextPull)
      end
      fn(env, frame, store, render)
    end)
  end

  local function number(cell, expected)
    assert.is_not_nil(cell.ordinalText)
    assert.equals(tostring(expected), cell.ordinalText:GetText())
    assert.is_true(cell.ordinalText:IsShown())
    assert.is_false(cell.badge:IsShown())
  end

  local function emptyNumber(cell)
    assert.is_not_nil(cell.ordinalText)
    assert.equals("", cell.ordinalText:GetText())
    assert.is_false(cell.ordinalText:IsShown())
  end

  local function clearedRows(frame)
    for _, row in ipairs({ frame.cooldownIconsRow, frame.upcomingIconsRow }) do
      for _, cell in ipairs(row.cells) do emptyNumber(cell) end
    end
  end

  it("基线真实入口维持当前与预览尺寸和独立倒计时", function()
    scenario(function(env, frame, _, render)
      env.cooldown = { isEnabled = true, isActive = true, startTime = 90, duration = 180 }
      render()
      local cell = frame.cooldownIconsRow.cells[1]
      local preview = frame.upcomingIconsRow.cells[1]
      assert.is_true(frame.bandShown)
      assert.equals(24, cell:GetWidth())
      assert.equals(16, preview:GetWidth())
      assert.equals("2:50", cell.label:GetText())
      assert.is_true(cell.cd:IsShown())
      assert.is_false(preview.cd:IsShown())
      assert.is_false(preview.label:IsShown())
      assert.is_false(preview.glowOn)
      assert.equals(2, #env.tickers)
    end)
  end)

  it("当前波使用数字替代勾号且文字层高于冷却遮罩", function()
    scenario(function(_, frame, _, render)
      render()
      local cell = frame.cooldownIconsRow.cells[1]
      number(cell, 3)
      number(frame.cooldownIconsRow.cells[2], 2)
      assert.equals(cell.badgeFrame, cell.ordinalText:GetParent())
      assert.is_true(cell.ordinalText:GetParent():GetFrameLevel() > cell.cd:GetFrameLevel())
      assert.equals("CENTER", cell.ordinalText.points[1][1])
      assert.equals("OVERLAY", cell.ordinalText.layer)
      assert.equals(MDT_NPT.Theme.fonts.large, cell.ordinalText.font)
      assert.same(MDT_NPT.Theme.colors.cdUse, cell.ordinalText.color)
      assert.not_equals(cell.label, cell.ordinalText)
    end)
  end)

  it("冷却和就绪回调只改变计时高亮不改变计划序号", function()
    scenario(function(env, frame, _, render)
      render()
      local cell = frame.cooldownIconsRow.cells[1]
      number(cell, 3)
      assert.is_true(cell.glowOn)
      env.cooldown = { isEnabled = true, isActive = true, startTime = 90, duration = 180 }
      render()
      number(cell, 3)
      assert.equals("2:50", cell.label:GetText())
      assert.is_false(cell.glowOn)
      env.time = 110
      env.tickers[1].callback()
      number(cell, 3)
      assert.equals("2:40", cell.label:GetText())
      env.cooldown = { isEnabled = true, isActive = false, startTime = 0, duration = 0 }
      env.tickers[1].callback()
      number(cell, 3)
      assert.equals("", cell.label:GetText())
      assert.is_true(cell.glowOn)
    end)
  end)

  it("预览保留勾叉且从不写入派生数字并清理复用残留", function()
    scenario(function(env, frame, _, render)
      render()
      local cells = frame.upcomingIconsRow.cells
      assert.equals(4, MDT_NPT.CooldownData.getActiveEntries(env.dbChar, "a", 8)[1].useOrdinal)
      for _, cell in ipairs(cells) do
        emptyNumber(cell)
        assert.is_true(cell.badge:IsShown())
        for _, text in ipairs(cell.ordinalText.textHistory) do assert.equals("", text) end
      end
      assert.equals("Interface\\RaidFrame\\ReadyCheck-Ready", cells[1].badge.texture)
      assert.equals("Interface\\RaidFrame\\ReadyCheck-NotReady", cells[2].badge.texture)
      cells[1].ordinalText:SetText("残留")
      cells[1].ordinalText:Show()
      render()
      emptyNumber(cells[1])
    end)
  end)

  it("当前开留未规划切换清空数字且保留留的叉号", function()
    scenario(function(_, frame, store, render)
      render()
      local cell = frame.cooldownIconsRow.cells[1]
      number(cell, 3)
      store:SetEntry("a", 7, 114050, "spell", "save")
      render()
      emptyNumber(cell)
      assert.is_true(cell.badge:IsShown())
      assert.equals("Interface\\RaidFrame\\ReadyCheck-NotReady", cell.badge.texture)
      assert.is_false(cell.glowOn)
      store:ClearEntry("a", 7, 114050)
      render()
      emptyNumber(cell)
      assert.is_false(cell.badge:IsShown())
      assert.equals(0.5, cell.icon.alpha)
      store:SetEntry("a", 7, 114050, "spell", "use")
      render()
      number(cell, 3)
    end)
  end)

  it("当前波按追踪状态取序号而非预览参数并支持跳波回退", function()
    scenario(function(env, frame, _, render)
      for _, row in ipairs({ { 7, 3 }, { 1, 1 }, { 4, 2 }, { 7, 3 } }) do
        env.state.currentNextPull = row[1]
        render(3)
        number(frame.cooldownIconsRow.cells[1], row[2])
        emptyNumber(frame.upcomingIconsRow.cells[1])
      end
    end)
  end)

  it("当前两位序号完整显示", function()
    scenario(function(env, frame, store, render)
      for i = 1, 12 do store:SetEntry("a", i, 114050, "spell", "use") end
      env.state.currentNextPull = 12
      render()
      number(frame.cooldownIconsRow.cells[1], 12)
    end)
  end)

  it("关闭再开启功能清空并恢复复用数字", function()
    scenario(function(env, frame, _, render)
      render()
      local cell = frame.cooldownIconsRow.cells[1]
      number(cell, 3)
      env.db.beacon.showCooldownPlan = false
      render()
      clearedRows(frame)
      assert.is_false(frame.cooldownIconsRow:IsShown())
      assert.is_false(frame.upcomingIconsRow:IsShown())
      assert.is_false(frame.bandShown)
      env.db.beacon.showCooldownPlan = true
      render()
      assert.equals(cell, frame.cooldownIconsRow.cells[1])
      number(cell, 3)
    end)
  end)

  it("缺失路线或当前波的提前返回会清空旧数字", function()
    scenario(function(env, frame, _, render)
      for _, field in ipairs({ "presetUID", "currentNextPull" }) do
        env.state.presetUID, env.state.currentNextPull = "a", 7
        render()
        number(frame.cooldownIconsRow.cells[1], 3)
        env.state[field] = nil
        render()
        clearedRows(frame)
        assert.is_false(frame.bandShown)
      end
    end)
  end)

  it("专精不支持时清空多余控件并能恢复", function()
    scenario(function(env, frame, _, render)
      render()
      number(frame.cooldownIconsRow.cells[1], 3)
      env.specID = 263
      render()
      clearedRows(frame)
      for _, row in ipairs({ frame.cooldownIconsRow, frame.upcomingIconsRow }) do
        for _, cell in ipairs(row.cells) do assert.is_false(cell:IsShown()) end
      end
      env.specID = 262
      render()
      number(frame.cooldownIconsRow.cells[1], 3)
    end)
  end)

  it("超过路线末尾隐藏预览时清理文字残留", function()
    scenario(function(_, frame, _, render)
      render()
      local cell = frame.upcomingIconsRow.cells[1]
      assert.is_not_nil(cell.ordinalText)
      cell.ordinalText:SetText("残留")
      cell.ordinalText:Show()
      render(40)
      assert.is_false(frame.upcomingIconsRow:IsShown())
      emptyNumber(cell)
      number(frame.cooldownIconsRow.cells[1], 3)
    end)
  end)

  it("指纹不匹配保留计划序号及原有倒计时警告色", function()
    scenario(function(env, frame, store, render)
      store:SetFingerprint("a", 7, "stale")
      env.cooldown = { isEnabled = true, isActive = true, startTime = 90, duration = 180 }
      render()
      local cell = frame.cooldownIconsRow.cells[1]
      number(cell, 3)
      assert.same(MDT_NPT.Theme.colors.cdMismatch, cell.label.color)
      assert.same(MDT_NPT.Theme.colors.cdUse, cell.ordinalText.color)
    end)
  end)

  it("编辑器真实点击前波后通过更新入口即时影响当前波数字", function()
    scenario(function(_, frame, _, render)
      mocks.loadSource("Modules/CooldownPlanEditor.lua")
      local editor = setmetatable(CreateFrame("Frame"), { __index = MDTNPTCooldownPlanMixin })
      editor.cellArea = CreateFrame("Frame", nil, editor)
      editor.uid, editor.selectedPull = "a", 1
      editor:RebuildCells()
      MDT_NPT.Beacon = { Update = function() render() end }
      render()
      number(frame.cooldownIconsRow.cells[1], 3)
      local cell = editor.cellArea.cells[1]
      cell.scripts.OnClick(cell, "LeftButton")
      number(frame.cooldownIconsRow.cells[1], 2)
      emptyNumber(cell)
      emptyNumber(frame.upcomingIconsRow.cells[1])
    end)
  end)
end)
