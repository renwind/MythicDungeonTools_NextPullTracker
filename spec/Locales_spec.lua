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
      assert.equals("下波", L["Next Pull"])
    end)
  end)

  it("enUS 提供横幅标签与 seed 名", function()
    mocks.withCooldownRuntime(function()
      local L = loadRealLocale("enUS")
      assert.equals("Next Pull", L["Next Pull"])
      assert.equals("Bloodlust", L["Bloodlust"])
    end)
  end)

  it("设置面板与斜杠命令的文案四种语言都齐", function()
    mocks.withCooldownRuntime(function()
      local expected = {
        ["Alerts"] = "冷却提醒",
        ["Voice Alert"] = "语音提醒",
        ["Center Icon Banner"] = "屏幕中部图标横幅",
        ["No Planned Uses - %d"] = "第 %d 波没有规划要开的冷却",
        ["Speak the next pull's planned cooldowns when the wave advances."] = "波次推进时，语音念出下波计划要开的爆发技能。",
        ["Show the next pull's planned cooldowns as a centered icon banner."] = "在屏幕中部用「下波」加图标横幅显示同一条提醒。",
        ["Ready Tracker Window Tooltip"] = "可拖动的小窗，左侧药水、右侧嗜血，边框跟随 EUI 主题色，分别显示就绪倒计时。",
        ["Spell Ratio Orb"] = "技能配比球",
        ["Spell Ratio Orb Tooltip"] = "显示当前波导入的 WCL 元素冲击与地震术施法配比。",
      }
      local en = loadRealLocale("enUS")
      assert.equals("A small draggable window with burst potion on the left and bloodlust on the right, EUI accent borders, and separate readiness countdowns.", en["Ready Tracker Window Tooltip"])
      assert.equals("Spell Ratio Orb", en["Spell Ratio Orb"])
      assert.equals("Show the imported WCL Elemental Blast and Earthquake ratio for the current pull.", en["Spell Ratio Orb Tooltip"])
      for key in pairs(expected) do assert.is_not_nil(en[key]) end
      -- 叠了 enUS 基底的表里，漏译会静默回落成英文，所以必须比对中文字面值本身；
      -- 光断言 not_nil 抓不到「enUS 加了、zhCN 忘了」。测试 2 同理。
      local zh = loadRealLocale("zhCN")
      for key, value in pairs(expected) do assert.equals(value, zh[key]) end

      local fr = loadRealLocale("frFR")
      assert.equals("Orbe de répartition des sorts", fr["Spell Ratio Orb"])
      assert.equals("Affiche la répartition WCL importée entre Explosion élémentaire et Séisme pour la vague actuelle.", fr["Spell Ratio Orb Tooltip"])

      local ru = loadRealLocale("ruRU")
      assert.equals("Сфера соотношения заклинаний", ru["Spell Ratio Orb"])
      assert.equals("Показывает импортированное из WCL соотношение заклинаний «Выброс стихий» и «Землетрясение» для текущей группы.", ru["Spell Ratio Orb Tooltip"])
    end)
  end)
end)
