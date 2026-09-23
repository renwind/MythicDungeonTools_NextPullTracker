local mocks = require("wow_mocks")

-- UpdateAll 是整个提醒功能唯一的触发点；漏掉这一行挂钩，前面所有代码都是死代码。
describe("Core.lua UpdateAll 挂钩", function()
  local frames, alertCalls, capturedDefaults

  local function fireOnEvent(event, ...)
    frames[1]._scripts.OnEvent(frames[1], event, ...)
  end

  before_each(function()
    mocks.reset()

    frames = {}
    _G.CreateFrame = function()
      local f = { _scripts = {}, _events = {} }
      function f:SetScript(n, fn) self._scripts[n] = fn end
      function f:RegisterEvent(e) self._events[e] = true end
      function f:UnregisterEvent(e) self._events[e] = nil end
      frames[#frames + 1] = f
      return f
    end

    local mockDb = {
      enabled = true,
      autoStartInKey = false,
      beacon = { enabled = true, showForNonTank = false, askOnStart = false },
    }
    -- 抓住传给 AceDB New() 的 defaults 实参：那才是 Core.lua 里真实的
    -- defaultSavedVars。断言 mockDb 上的字段只会断言到测试自己刚写进去的值。
    capturedDefaults = nil
    _G.LibStub = function()
      return {
        New = function(_, _name, defaults)
          capturedDefaults = defaults
          return { global = mockDb, char = { beacon = {} } }
        end,
      }
    end

    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show = function() end
    _G.YES, _G.NO = "Yes", "No"
    _G.C_Timer = { After = function() end }
    _G.print = function() end

    -- Core.lua 在 load 时捕获成 upvalue 的子模块。
    _G.MDT_NPT.State = { buildStateFromPreset = function() return nil end }
    _G.MDT_NPT.Scenario = {}
    _G.MDT_NPT.Beacon = {}
    _G.MDT_NPT.Mdt = { syncMDTDungeonToPlayerZone = function() end }
    _G.MDT_NPT.CooldownPlanEditor = nil

    alertCalls = 0
    _G.MDT_NPT.CooldownAlert = {
      OnUpdateAll = function() alertCalls = alertCalls + 1 end,
    }

    local chunk = assert(loadfile("Core.lua"))
    chunk("MythicDungeonTools_NextPullTracker")
    fireOnEvent("ADDON_LOADED", "MythicDungeonTools_NextPullTracker")
  end)

  it("UpdateAll 每次都驱动提醒模块", function()
    MDT_NPT:UpdateAll()
    MDT_NPT:UpdateAll()
    assert.equals(2, alertCalls)
  end)

  it("提醒模块缺席时 UpdateAll 不报错", function()
    _G.MDT_NPT.CooldownAlert = nil
    assert.has_no.errors(function() MDT_NPT:UpdateAll() end)
  end)

  it("默认存档里两个提醒开关都是开的", function()
    assert.is_not_nil(capturedDefaults)
    assert.is_true(capturedDefaults.global.beacon.alertVoice)
    assert.is_true(capturedDefaults.global.beacon.alertText)
  end)
end)
