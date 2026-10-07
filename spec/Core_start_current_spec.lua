local mocks = require("wow_mocks")

describe("Core.lua — /npt start current 与启动回显", function()
  local frames, prints, getCurrentCalls, presetStub, mockDb

  local function fireOnEvent(event, ...)
    frames[1]._scripts.OnEvent(frames[1], event, ...)
  end

  before_each(function()
    mocks.reset()
    frames = {}
    prints = {}
    getCurrentCalls = {}

    _G.CreateFrame = function(_)
      local f = { _scripts = {}, _events = {} }
      function f:SetScript(n, fn) self._scripts[n] = fn end
      function f:RegisterEvent(e) self._events[e] = true end
      function f:UnregisterEvent(e) self._events[e] = nil end
      table.insert(frames, f)
      return f
    end

    mockDb = { enabled = true, beacon = { enabled = true, askOnStart = false } }
    _G.LibStub = function()
      return { New = function() return { global = mockDb, char = { beacon = {} } } end }
    end

    _G.print = function(msg) table.insert(prints, tostring(msg)) end
    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show = function() end
    _G.C_Timer = {
      After = function() end,
      NewTicker = function() return { Cancel = function() end } end,
    }

    presetStub = {
      uid = "uid-preview",
      text = "WCL TOS +22",
      value = { currentDungeonIdx = 20, pulls = { { [1] = { 1 } } } },
    }
    _G.MDT_NPT.MDT = {
      GetDB = function() return { currentDungeonIdx = 20 } end,
      GetCurrentPreset = function(_, idx)
        table.insert(getCurrentCalls, idx)
        return presetStub
      end,
      FindPresetByUID = function() return nil end,
      UpdateToDungeon = function() end,
      dungeonSelectionToIndex = { { 160, 161, 162, 163, 164, 42, 20, 17 } },
      GetDungeonName = function(_, idx) return "D" .. idx end,
    }
    _G.MDT_NPT.State = {
      buildStateFromPreset = function(preset)
        return {
          active = true,
          dungeonIndex = preset.value.currentDungeonIdx,
          presetUID = preset.uid,
          pullStates = { { state = "next" } },
          currentNextPull = 1,
        }
      end,
    }
    _G.MDT_NPT.Scenario = {}
    _G.MDT_NPT.Beacon = {}
    _G.MDT_NPT.Mdt = { syncMDTDungeonToPlayerZone = function() return true, nil end }

    local chunk = assert(loadfile("Core.lua"))
    chunk("MythicDungeonTools_NextPullTracker")
    fireOnEvent("ADDON_LOADED", "MythicDungeonTools_NextPullTracker")

    _G.SlashCmdList = {}
    mocks.loadSource("Modules/Slash.lua")
  end)

  local function joinedPrints()
    return table.concat(prints, "\n")
  end

  it("start current 跟 MDT 当前预览：选中项按 MDT 的 currentDungeonIdx 取", function()
    MDT_NPT:Slash("start current")
    assert.equals(1, #getCurrentCalls)
    assert.equals(20, getCurrentCalls[1])
    assert.is_not_nil(MDT_NPT.state)
    assert.equals("uid-preview", MDT_NPT.state.presetUID)
    assert.equals(20, MDT_NPT.state.dungeonIndex)
  end)

  it("启动回显带上预设名、uid、副本与波数，跟错路线时一眼可见", function()
    MDT_NPT:Slash("start current")
    local out = joinedPrints()
    assert.is_true(out:find("WCL TOS +22", 1, true) ~= nil)
    assert.is_true(out:find("uid=uid-preview", 1, true) ~= nil)
    assert.is_true(out:find("dungeon 20", 1, true) ~= nil)
    assert.is_true(out:find("1 pulls", 1, true) ~= nil)
  end)

  it("start current 在 MDT 没有选中路线时报错且不建立 state", function()
    presetStub = nil
    _G.MDT_NPT.MDT.GetCurrentPreset = function() return nil end
    MDT_NPT:Slash("start current")
    assert.is_nil(MDT_NPT.state)
    assert.is_true(joinedPrints():find("no selected route", 1, true) ~= nil)
  end)

  it("无参 start 不走 current 分支：区域判定优先", function()
    local synced = 0
    _G.MDT_NPT.Mdt.syncMDTDungeonToPlayerZone = function()
      synced = synced + 1
      return true, 17
    end
    _G.MDT_NPT.MDT.GetCurrentPreset = function(_, idx)
      table.insert(getCurrentCalls, idx)
      return presetStub
    end
    MDT_NPT:Slash("start")
    assert.equals(1, synced)
    assert.equals(17, getCurrentCalls[1])
  end)

  it("cur 是 current 的缩写，走同一分支", function()
    MDT_NPT:Slash("start cur")
    assert.equals(1, #getCurrentCalls)
    assert.equals(20, getCurrentCalls[1])
    assert.equals("uid-preview", MDT_NPT.state.presetUID)
  end)

  it("start 给不存在的副本索引时列出赛季池 8 个 ID 与名字", function()
    _G.MDT_NPT.MDT.GetCurrentPreset = function() return nil end
    MDT_NPT:Slash("start 40")
    local out = joinedPrints()
    assert.is_true(out:find("no non-empty MDT route for dungeon 40", 1, true) ~= nil)
    for _, idx in ipairs({ 160, 161, 162, 163, 164, 42, 20, 17 }) do
      assert.is_true(out:find(idx .. " D" .. idx, 1, true) ~= nil)
    end
    assert.is_nil(MDT_NPT.state)
  end)

  it("未知参数打印含 current 的用法", function()
    MDT_NPT:Slash("start bogus")
    assert.is_true(joinedPrints():find("last|current|<dungeonIndex>", 1, true) ~= nil)
    assert.is_nil(MDT_NPT.state)
  end)
end)
