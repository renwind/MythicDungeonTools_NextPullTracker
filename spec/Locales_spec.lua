local mocks = require("wow_mocks")

-- 用真实 locale 文件替换 mock 的恒等 L 表：mock 的 __index 会把缺键伪装成命中，
-- 只有真表才能暴露「忘了加条目」。
local function loadRealLocale(locale)
  MDT_NPT.L = {}
  _G.GetLocale = function() return locale end
  mocks.loadSource("Locales/enUS.lua")
  if locale ~= "enUS" then mocks.loadSource("Locales/" .. locale .. ".lua") end
  return MDT_NPT.L
end

describe("本地化完整性", function()
  before_each(function() mocks.reset() end)

  it("每个冷却 seed 名在英文基底里都有条目", function()
    mocks.withCooldownRuntime(function()
      local L = loadRealLocale("enUS")
      mocks.loadSource("Modules/CooldownData.lua")
      local seeds = MDT_NPT.CooldownData.getSeedEntries()
      assert.equals(3, #seeds)
      for _, seed in ipairs(seeds) do
        assert.is_not_nil(L[seed.name])
      end
    end)
  end)

  it("zhCN 把 seed 名与提醒模板都译成中文", function()
    mocks.withCooldownRuntime(function()
      local L = loadRealLocale("zhCN")
      assert.equals("嗜血", L["Bloodlust"])
      assert.equals("升腾", L["Ascendance"])
      assert.equals("爆发药水", L["Burst Potion"])
      assert.equals("下一波%s", L["Next Pull Alert - %s"])
      assert.equals("，", L["Alert List Joiner"])
    end)
  end)

  it("enUS 提供提醒模板与列表连接符", function()
    mocks.withCooldownRuntime(function()
      local L = loadRealLocale("enUS")
      assert.equals("Next pull %s", L["Next Pull Alert - %s"])
      assert.equals(", ", L["Alert List Joiner"])
      assert.equals("Bloodlust", L["Bloodlust"])
    end)
  end)

  it("设置面板与斜杠命令的文案两种语言都齐", function()
    mocks.withCooldownRuntime(function()
      local keys = {
        "Alerts", "Voice Alert", "Center Text Alert", "No Planned Uses - %d",
        "Speak the next pull's planned cooldowns when the wave advances.",
        "Show the same reminder as large text in the middle of the screen.",
        "Repeat the next pull's cooldown reminder now",
      }
      local en = loadRealLocale("enUS")
      for _, key in ipairs(keys) do assert.is_not_nil(en[key]) end
      local zh = loadRealLocale("zhCN")
      for _, key in ipairs(keys) do assert.is_not_nil(zh[key]) end
    end)
  end)
end)
