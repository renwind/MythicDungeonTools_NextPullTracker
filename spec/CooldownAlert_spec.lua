local mocks = require("wow_mocks")

local THREE = "下一波嗜血，下一波爆发药水，下一波升腾"

-- 把 mock 的恒等 L 表换成中文真值，断言才能读起来像游戏里的实际输出。
local function chineseLocale()
  local L = MDT_NPT.L
  L["Bloodlust"] = "嗜血"
  L["Ascendance"] = "升腾"
  L["Burst Potion"] = "爆发药水"
  L["Next Pull Alert - %s"] = "下一波%s"
  L["Alert List Joiner"] = "，"
end

local function spell(action, id)
  return { kind = "spell", id = id or 114050, action = action or "use" }
end
local function potion(action)
  return { kind = "item", id = 241308, action = action or "use" }
end
local function lust(action, id)
  return { kind = "spell", id = 2825, action = action or "use" }
end
local function plan(...)
  return { entries = { ... } }
end

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    mocks.loadSource("Modules/CooldownData.lua")
    mocks.loadSource("Modules/CooldownPlan.lua")
    chineseLocale()
    mocks.loadSource("Modules/CooldownAlert.lua")
    fn(env, MDT_NPT.CooldownAlert)
  end)
end

describe("CooldownAlert.buildText", function()
  before_each(function() mocks.reset() end)

  it("三项全开时按图标行的左到右顺序播报", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell(), potion(), lust()) }
      assert.equals(THREE, alert.buildText(env.dbChar, "a", 1))
    end)
  end)

  it("只播标记为使用的条目，留着的和未规划的不播", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell("save"), potion("use"), lust("use")) }
      assert.equals("下一波嗜血，下一波爆发药水", alert.buildText(env.dbChar, "a", 1))
    end)
  end)

  it("全部留着或根本没配计划时返回 nil", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell("save"), potion("save")) }
      assert.is_nil(alert.buildText(env.dbChar, "a", 1))
      assert.is_nil(alert.buildText(env.dbChar, "a", 9))
      assert.is_nil(alert.buildText(env.dbChar, "nosuchuid", 1))
    end)
  end)

  it("非元素萨满专精返回 nil", function()
    scenario(function(env, alert)
      env.specID = 253
      env.dbChar.cooldownPlans.a = { [1] = plan(spell(), potion(), lust()) }
      assert.is_nil(alert.buildText(env.dbChar, "a", 1))
    end)
  end)

  it("升腾的每波次数不进文本", function()
    scenario(function(env, alert)
      local asc = spell("use")
      asc.uses = 3
      env.dbChar.cooldownPlans.a = { [1] = plan(asc) }
      assert.equals("下一波升腾", alert.buildText(env.dbChar, "a", 1))
    end)
  end)

  it("嗜血 seed 族内任一 ID 都认得", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(lust("use", 32182)) }
      assert.equals("下一波嗜血", alert.buildText(env.dbChar, "a", 1))
    end)
  end)
end)
