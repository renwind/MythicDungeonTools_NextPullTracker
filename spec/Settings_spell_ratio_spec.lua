local mocks = require("wow_mocks")

describe("Settings 技能配比球开关", function()
  local loginFrame, proxySettings, db, orbUpdates, beaconUpdates

  before_each(function()
    mocks.reset()

    proxySettings = {}
    db = { beacon = { spellRatioOrb = true } }
    orbUpdates = 0
    beaconUpdates = 0

    function MDT_NPT:GetDB() return db end
    MDT_NPT.SpellRatioOrb = {
      Update = function() orbUpdates = orbUpdates + 1 end,
    }
    MDT_NPT.Beacon = {
      Update = function() beaconUpdates = beaconUpdates + 1 end,
      ApplyAlpha = function() end,
    }

    _G.Settings = {}

    function Settings.RegisterVerticalLayoutCategory()
      local category = {}
      function category:GetID() return 1 end

      local layout = {}
      function layout:AddInitializer() end

      return category, layout
    end

    function Settings.RegisterProxySetting(category, variable, valueType, name, defaultValue, getter, setter)
      local setting = {
        category = category,
        variable = variable,
        valueType = valueType,
        name = name,
        defaultValue = defaultValue,
        getter = getter,
        setter = setter,
      }
      proxySettings[variable] = setting
      return setting
    end

    function Settings.CreateCheckbox() end

    function Settings.CreateSliderOptions()
      local options = {}
      function options:SetLabelFormatter() end
      return options
    end

    function Settings.CreateSlider() end

    function Settings.CreateControlTextContainer()
      local container = { data = {} }
      function container:Add(value, text)
        self.data[#self.data + 1] = { value = value, text = text }
      end
      function container:GetData() return self.data end
      return container
    end

    function Settings.CreateDropdown() end
    function Settings.CreateElementInitializer() return {} end
    function Settings.RegisterAddOnCategory() end
    function Settings.OpenToCategory() end

    _G.CreateSettingsListSectionHeaderInitializer = function(text)
      return { text = text }
    end
    _G.MinimalSliderWithSteppersMixin = { Label = { Right = "RIGHT" } }

    _G.CreateFrame = function()
      local frame = { scripts = {}, events = {} }
      function frame:RegisterEvent(event) self.events[event] = true end
      function frame:SetScript(name, callback) self.scripts[name] = callback end
      function frame:UnregisterAllEvents() self.events = {} end
      loginFrame = frame
      return frame
    end

    mocks.loadSource("Modules/Settings.lua")
    assert.is_true(loginFrame.events.PLAYER_LOGIN)
    loginFrame.scripts.OnEvent(loginFrame, "PLAYER_LOGIN")
  end)

  it("读写独立开关并且只刷新技能配比球", function()
    local setting = proxySettings.MDTNPT_SPELL_RATIO_ORB
    assert.is_not_nil(setting)
    assert.is_function(setting.getter)
    assert.is_function(setting.setter)

    assert.is_true(setting.getter())
    db.beacon.spellRatioOrb = false
    assert.is_false(setting.getter())
    db.beacon.spellRatioOrb = true

    -- RegisterProxySetting 收到的 setter 已由 Settings.lua 包含 onChange；
    -- 直接调用它，避免给 Settings API 臆造额外的通知方法。
    setting.setter(false)
    assert.is_false(db.beacon.spellRatioOrb)
    assert.equals(1, orbUpdates)
    assert.equals(0, beaconUpdates)

    setting.setter(true)
    assert.is_true(db.beacon.spellRatioOrb)
    assert.equals(2, orbUpdates)
    assert.equals(0, beaconUpdates)
  end)
end)
