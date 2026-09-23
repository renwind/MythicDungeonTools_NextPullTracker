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

describe("CooldownAlert.speak", function()
  before_each(function() mocks.reset() end)

  local function scenario(fn)
    mocks.withCooldownRuntime(function(env)
      mocks.loadSource("Modules/CooldownData.lua")
      chineseLocale()
      mocks.loadSource("Modules/CooldownAlert.lua")
      fn(env, MDT_NPT.CooldownAlert)
    end)
  end

  it("用客户端 TTS 设置的音色语速音量播报", function()
    scenario(function(env, alert)
      env.tts = { voiceOptionID = 3, rate = 2, volume = 55 }
      assert.is_true(alert.speak("下一波嗜血"))
      assert.equals(1, #env.spoken)
      assert.equals(3, env.spoken[1].voiceID)
      assert.equals("下一波嗜血", env.spoken[1].text)
      assert.equals(2, env.spoken[1].rate)
      assert.equals(55, env.spoken[1].volume)
    end)
  end)

  it("C_TTSSettings 缺失时回落到第一个可用音色", function()
    scenario(function(env, alert)
      _G.C_TTSSettings = nil
      env.ttsVoices = { { voiceID = 11, name = "Fallback" } }
      assert.is_true(alert.speak("下一波嗜血"))
      assert.equals(11, env.spoken[1].voiceID)
      assert.equals(0, env.spoken[1].rate)
      assert.equals(100, env.spoken[1].volume)
    end)
  end)

  it("没有任何可用音色时不播报也不报错", function()
    scenario(function(env, alert)
      _G.C_TTSSettings = nil
      env.ttsVoices = {}
      assert.is_false(alert.speak("下一波嗜血"))
      assert.equals(0, #env.spoken)
    end)
  end)

  it("客户端没有 SpeakText 时安静地放弃", function()
    scenario(function(env, alert)
      _G.C_VoiceChat = { GetTtsVoices = function() return env.ttsVoices end }
      assert.is_false(alert.speak("下一波嗜血"))
      assert.equals(0, #env.spoken)
    end)
  end)

  it("12.x 签名不传 destination，也不默认 overlap", function()
    scenario(function(env, alert)
      alert.speak("下一波嗜血")
      assert.is_nil(env.spoken[1].overlap)
    end)
  end)
end)
