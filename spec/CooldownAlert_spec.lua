local mocks = require("wow_mocks")

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
    mocks.loadSource("Modules/CooldownAlert.lua")
    fn(env, MDT_NPT.CooldownAlert)
  end)
end

-- mock 的 C_Spell.GetSpellTexture 返回 "spell:<id>"、C_Item.GetItemIconByID 返回
-- "item:<id>"，所以图标断言是确定的字符串，不需要真贴图。
describe("CooldownAlert.buildItems", function()
  before_each(function() mocks.reset() end)

  it("三项全开时按图标行的左到右顺序组装", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell(), potion(), lust()) }
      local items = alert.buildItems(env.dbChar, "a", 1)
      assert.equals("lust-potion-asc", items.audioKey)
      assert.same({ "spell:2825", "item:241308", "spell:114050" }, items.icons)
    end)
  end)

  it("只收标记为使用的条目，留着的和未规划的不收", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell("save"), potion("use"), lust("use")) }
      local items = alert.buildItems(env.dbChar, "a", 1)
      -- 逆序遍历剩下 [嗜血, 爆发药水]，升腾被 save 挡掉
      assert.equals("lust-potion", items.audioKey)
      assert.same({ "spell:2825", "item:241308" }, items.icons)
    end)
  end)

  it("全部留着或根本没配计划时返回 nil", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell("save"), potion("save")) }
      assert.is_nil(alert.buildItems(env.dbChar, "a", 1))
      assert.is_nil(alert.buildItems(env.dbChar, "a", 9))
      assert.is_nil(alert.buildItems(env.dbChar, "nosuchuid", 1))
    end)
  end)

  it("非元素萨满专精返回 nil", function()
    scenario(function(env, alert)
      env.specID = 253
      env.dbChar.cooldownPlans.a = { [1] = plan(spell(), potion(), lust()) }
      assert.is_nil(alert.buildItems(env.dbChar, "a", 1))
    end)
  end)

  it("升腾的每波次数不进音频键，图标也只出一个", function()
    scenario(function(env, alert)
      local asc = spell("use")
      asc.uses = 3
      env.dbChar.cooldownPlans.a = { [1] = plan(asc) }
      local items = alert.buildItems(env.dbChar, "a", 1)
      assert.equals("asc", items.audioKey)
      assert.same({ "spell:114050" }, items.icons)
    end)
  end)

  it("嗜血 seed 族内任一 ID 都认得，图标取族内第一个已知项", function()
    scenario(function(env, alert)
      -- 存档里记的是 32182（英雄嗜血），但图标经 resolveAscendanceID 解析：
      -- 族内第一个「已知且有贴图」的成员是 2825，所以图标不是 "spell:32182"。
      env.dbChar.cooldownPlans.a = { [1] = plan(lust("use", 32182)) }
      local items = alert.buildItems(env.dbChar, "a", 1)
      assert.equals("lust", items.audioKey)
      assert.same({ "spell:2825" }, items.icons)
    end)
  end)
end)

describe("CooldownAlert.play", function()
  before_each(function() mocks.reset() end)

  it("默认语言播 en-US 的录音，走 Master 声道", function()
    scenario(function(env, alert)
      alert.play("lust-potion-asc")
      assert.equals(1, #env.played)
      assert.equals("Master", env.played[1].channel)
      assert.equals(
        "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\voice\\en-US\\lust-potion-asc.mp3",
        env.played[1].path)
    end)
  end)

  it("中文客户端播 zh-CN 的录音", function()
    scenario(function(env, alert)
      _G.GetLocale = function() return "zhCN" end
      alert.play("lust-potion-asc")
      assert.equals(1, #env.played)
      assert.truthy(env.played[1].path:find("\\zh-CN\\lust-potion-asc.mp3", 1, true))
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

  it("波次推进后经去抖播报下一波，且去抖长于轮询周期", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll()
      -- 不变量：去抖时长必须盖过 Core.lua:307 的 NewTicker(1.0) 轮询周期，否则
      -- Start 排定的那次会在轮询取消它之前就播出去。断言下界而不是字面量——
      -- 断 0.75 那种写法在把常量改成 0.1（客户端里必定双播）时依然是绿的。
      assert.is_true(env.timers[1].delay > 1.0)
      assert.equals(0, #env.played)   -- 还没到点
      env.fireTimers()
      assert.equals(1, #env.played)
      -- 路径前缀由 play 的那组测试专门守住，这里只钉住「播的是哪一条录音」。
      assert.truthy(env.played[1].path:find("\\en-US\\lust-potion-asc.mp3", 1, true))
      assert.equals(1, #env.shown)
      assert.equals(3, #env.shown[1])
    end)
  end)

  it("同一波反复 UpdateAll 只播一次", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      for _ = 1, 5 do alert:OnUpdateAll(); env.fireTimers() end
      assert.equals(1, #env.played)
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
      assert.equals(1, #env.played)
      assert.truthy(env.played[1].path:find("\\en-US\\lust-potion-asc.mp3", 1, true))
    end)
  end)

  it("波次号变化会重新播报", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      MDT_NPT.state = activeState("a", 4)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(2, #env.played)
    end)
  end)

  it("回退到上一波会重新播报", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 4)
      alert:OnUpdateAll(); env.fireTimers()
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(2, #env.played)
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
      assert.equals(2, #env.played)
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
      assert.equals(0, #env.played)
      -- 重新开追踪后必须还能播，说明 lastKey 真的被清了
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(1, #env.played)
    end)
  end)

  it("停止追踪会立刻收起屏幕上的横幅", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(1, #env.shown)
      local hideCalls = 0
      MDT_NPT.AlertBanner.Hide = function() hideCalls = hideCalls + 1 end
      MDT_NPT.state = nil
      alert:OnUpdateAll()
      assert.equals(1, hideCalls)
    end)
  end)

  it("路由完成时静默", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", nil)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(0, #env.played)
      assert.equals(0, #env.shown)
    end)
  end)

  it("关掉语音时只显示横幅", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.db.beacon.alertVoice = false
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(0, #env.played)
      assert.equals(1, #env.shown)
    end)
  end)

  it("关掉横幅时只播放语音", function()
    scenario(function(env, alert)
      seedPlans(env)
      env.db.beacon.alertText = false
      MDT_NPT.state = activeState("a", 1)
      alert:OnUpdateAll(); env.fireTimers()
      assert.equals(1, #env.played)
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
      assert.equals(0, #env.played)
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
      assert.equals(0, #env.played)
      assert.equals(1, #env.shown)   -- 文字开关还开着，横幅照样出
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
      assert.equals(0, #env.played)
      assert.equals(0, #env.shown)
    end)
  end)

  it("SpeakNow 绕过去重与去抖立即播报并返回 items", function()
    scenario(function(env, alert)
      seedPlans(env)
      MDT_NPT.state = activeState("a", 1)
      assert.equals("lust-potion-asc", alert:SpeakNow().audioKey)
      assert.equals("lust-potion-asc", alert:SpeakNow().audioKey)   -- 连按两次都出声
      assert.equals(2, #env.played)
      assert.equals(0, #env.timers)       -- 不排定时器
    end)
  end)

  it("SpeakNow 在无计划或未追踪时返回 nil", function()
    scenario(function(env, alert)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell("save")) }
      MDT_NPT.state = activeState("a", 1)
      assert.is_nil(alert:SpeakNow())
      assert.equals(0, #env.played)
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
      assert.equals(1, #env.played)
      assert.equals(1, #env.shown)
    end)
  end)
end)
