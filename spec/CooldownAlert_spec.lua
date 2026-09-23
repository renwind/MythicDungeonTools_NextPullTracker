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
  return { kind = "spell", id = id or 2825, action = action or "use" }
end
local function plan(...)
  return { entries = { ... } }
end

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    mocks.loadSource("Modules/CooldownData.lua")
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

  it("12.x 签名不把 overlap 当默认值传出去", function()
    scenario(function(env, alert)
      alert.speak("下一波嗜血")
      assert.is_nil(env.spoken[1].overlap)
    end)
  end)
end)

local function activeState(uid, pullIndex)
  local state = {
    active = true,
    presetUID = uid,
    currentNextPull = pullIndex,
    dungeonIndex = 1,
    pullStates = { [1] = { state = "completed" } },
  }
  -- pullIndex 为 nil 表示路由完成；不能写成 pullStates[pullIndex] = ...，
  -- 那是 table index is nil 的硬错误。
  if pullIndex then state.pullStates[pullIndex] = { state = "next" } end
  return state
end

describe("CooldownAlert 触发编排", function()
  before_each(function() mocks.reset() end)

  -- 每条路线的两波都配满三项 use。
  local function seedPlans(env)
    env.dbChar.cooldownPlans.a = {
      [1] = plan(spell(), potion(), lust()),
      [4] = plan(spell(), potion(), lust()),
    }
  end

  it("波次推进后经去抖播报下一波", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll()
      -- 去抖时长是正确性参数：必须长到能盖过 Start 与第一次力量值轮询之间的那一秒，
      -- 否则中途开局会连播两条。见 CooldownAlert.lua 的 ANNOUNCE_DELAY 注释。
      assert.equals(0.75, env.timers[1].delay)
      assert.equals(0, #env.spoken)   -- 还没到点
      env.fireTimers()
      assert.equals(1, #env.spoken)
      assert.equals(THREE, env.spoken[1].text)
      assert.equals(THREE, env.shown[1])
    end)
  end)

  it("同一波反复 UpdateAll 只播一次", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      for _ = 1, 5 do alert:OnUpdateAll(); env.fireTimers() end
      assert.equals(1, #env.spoken)
    end)
  end)

  it("中途开局连播两次被去抖收敛成一条", function()
    scenario(function(env, alert)
      seedPlans(env)
      -- Start() 先为 pull 1 排定一次；约 1 秒后第一次力量值轮询把已清完的
      -- 波次一次性吃掉、推进到 pull 4 再排定一次。没有去抖就是两条（设计 §5.2）。
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll()
      MDT_NPT.state = activeState("a", 4)
      alert:OnUpdateAll()
      env.fireTimers()
      assert.equals(1, #env.spoken)
      assert.equals(THREE, env.spoken[1].text)
    end)
  end)

  it("波次号变化会重新播报", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      MDT_NPT.state = activeState("a", 4)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(2, #env.spoken)
    end)
  end)

  it("回退到上一波会重新播报", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 4)
      alert:OnUpdateAll(); env.fireTimers()
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(2, #env.spoken)
    end)
  end)

  it("换路线（presetUID 变化）会重新播报同一波号", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.dbChar.cooldownPlans.b = { [1] = plan(spell(), potion(), lust()) }
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      MDT_NPT.state = activeState("b", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(2, #env.spoken)
    end)
  end)

  it("state 为 nil（Stop 之后）清空去重键并取消待定播报", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll()
      MDT_NPT.state = nil
      alert:OnUpdateAll()
      env.fireTimers()
      assert.equals(0, #env.spoken)
      -- 重新开追踪后必须还能播，说明 lastKey 真的被清了
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(1, #env.spoken)
    end)
  end)

  it("路由完成时静默", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", nil)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(0, #env.spoken)
      assert.equals(0, #env.shown)
    end)
  end)

  it("关掉语音时只显示文字", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.db.beacon.alertVoice = false
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(0, #env.spoken)
      assert.equals(1, #env.shown)
    end)
  end)

  it("关掉文字时只播报语音", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.db.beacon.alertText = false
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(1, #env.spoken)
      assert.equals(0, #env.shown)
    end)
  end)

  it("两个开关都关时什么都不做", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.db.beacon.alertVoice = false
      env.db.beacon.alertText = false
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(0, #env.spoken)
      assert.equals(0, #env.shown)
    end)
  end)

  it("开关在去抖窗口内被关掉也生效", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll()
      env.db.beacon.alertVoice = false
      env.fireTimers()
      assert.equals(0, #env.spoken)
    end)
  end)

  it("没有 use 条目时既不播也不显示，但仍记住这一波已处理", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell("save")) }
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll()
      alert:OnUpdateAll()
      -- 静默的波次同样写进去重键，所以第二次没有再排定时器
      assert.equals(1, #env.timers)
      env.fireTimers()
      assert.equals(0, #env.spoken)
      assert.equals(0, #env.shown)
    end)
  end)

  it("SpeakNow 绕过去重与去抖立即播报并返回文本", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      assert.equals(THREE, alert:SpeakNow())
      assert.equals(THREE, alert:SpeakNow())   -- 连按两次都出声
      assert.equals(2, #env.spoken)
      assert.equals(0, #env.timers)       -- 不排定时器
    end)
  end)

  it("SpeakNow 在无计划或未追踪时返回 nil", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell("save")) }
      MDT_NPT.state = activeState("a", 1)
      assert.is_nil(alert:SpeakNow())
      assert.equals(0, #env.spoken)
      MDT_NPT.state = nil
      assert.is_nil(alert:SpeakNow())
    end)
  end)

  it("提醒不依赖信标或冷却图标行的可见性", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.db.beacon.showCooldownPlan = false
      env.db.beacon.enabled = false
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(1, #env.spoken)
      assert.equals(1, #env.shown)
    end)
  end)
end)
