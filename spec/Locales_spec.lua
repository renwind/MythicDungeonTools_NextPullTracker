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

  it("zhCN 把 seed 名与横幅标签都译成中文", function()
    mocks.withCooldownRuntime(function()
      local L = loadRealLocale("zhCN")
      assert.equals("嗜血", L["Bloodlust"])
      assert.equals("升腾", L["Ascendance"])
      assert.equals("爆发药水", L["Burst Potion"])
      assert.equals("下一波", L["Next Pull"])
    end)
  end)

  it("enUS 提供横幅标签与 seed 名", function()
    mocks.withCooldownRuntime(function()
      local L = loadRealLocale("enUS")
      assert.equals("Next pull", L["Next Pull"])
      assert.equals("Bloodlust", L["Bloodlust"])
    end)
  end)

  it("设置面板与斜杠命令的文案两种语言都齐", function()
    mocks.withCooldownRuntime(function()
      local expected = {
        ["Alerts"] = "冷却提醒",
        ["Voice Alert"] = "语音提醒",
        ["Center Text Alert"] = "屏幕中部文字",
        ["No Planned Uses - %d"] = "第 %d 波没有规划要开的冷却",
        ["Speak the next pull's planned cooldowns when the wave advances."] = "波次推进时，语音念出下一波计划要开的爆发技能。",
        ["Show the same reminder as large text in the middle of the screen."] = "在屏幕中部用大字显示同一条提醒。",
      }
      local en = loadRealLocale("enUS")
      for key in pairs(expected) do assert.is_not_nil(en[key]) end
      -- 叠了 enUS 基底的表里，漏译会静默回落成英文，所以必须比对中文字面值本身；
      -- 光断言 not_nil 抓不到「enUS 加了、zhCN 忘了」。测试 2 同理。
      local zh = loadRealLocale("zhCN")
      for key, value in pairs(expected) do assert.equals(value, zh[key]) end
    end)
  end)
end)
