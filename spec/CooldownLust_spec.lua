local mocks = require("wow_mocks")

-- CooldownLust v4：真就绪边沿（语音 lust-ready + 脉冲环）与精疲力尽 T-30s
-- 预提醒（语音 lust-sated-soon）。声音断言走 env.played（PlaySoundFile 记录），
-- 路径解析由 CooldownAlert_spec 守着，这里只钉「播了哪条、播了几次」。
local SATED_ID = 57724

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    mocks.loadSource("Modules/CooldownData.lua")
    mocks.loadSource("Modules/CooldownAlert.lua")
    mocks.loadSource("Modules/CooldownLust.lua")
    fn(env, MDT_NPT.CooldownLust)
  end)
end

-- 精疲力尽 debuff：剩余秒数 -> aura 表（expirationTime 用当前 env.time 折算）。
local function satedFor(env, seconds)
  if seconds == nil then
    env.auras[SATED_ID] = nil
  else
    env.auras[SATED_ID] = { expirationTime = env.time + seconds }
  end
end

-- 模拟 0.5s 轮询走一拍：真实客户端由 C_Timer.NewTicker 驱动，测试手动触发。
local function tick(env)
  env.tickers[1].callback()
end

local function playedKeys(env)
  local keys = {}
  for _, p in ipairs(env.played) do
    keys[#keys + 1] = p.path:match("\\([^\\]+)%.mp3$")
  end
  return keys
end

describe("CooldownLust 真就绪边沿", function()
  before_each(function() mocks.reset() end)

  it(">0 跨到 0 播一次 lust-ready 并脉冲，停在下一次跨越前不重播", function()
    scenario(function(env, lust)
      local row = CreateFrame("Frame", nil, nil)
      satedFor(env, 10)                 -- ready=10，第一次 Update 只播种
      lust:Update(row)
      assert.equals(0, #env.played)

      satedFor(env, nil)                -- debuff 消失、无 CD -> ready=0，跨越
      tick(env)
      assert.same({ "lust-ready" }, playedKeys(env))
      assert.equals("Master", env.played[1].channel)
      local f = row.lustFrame
      assert.is_true(f.pulse:IsShown())
      assert.equals(1, f.pulseAnim.plays)

      tick(env)                         -- 停在 0 再采样不重播
      assert.equals(1, #env.played)
      assert.equals(1, f.pulseAnim.plays)
    end)
  end)

  it("ready 一直 >0 时不出任何提示", function()
    scenario(function(env, lust)
      local row = CreateFrame("Frame", nil, nil)
      satedFor(env, 100)
      lust:Update(row)
      satedFor(env, 90)                 -- 100 -> 90，没跨 30，也没到 0
      tick(env)
      satedFor(env, 60)
      tick(env)
      assert.equals(0, #env.played)
      assert.is_false(row.lustFrame.pulse:IsShown())
      assert.equals(0, row.lustFrame.pulseAnim.plays)
    end)
  end)

  it("Hide 之后重新 Update 只播种：隐藏期间发生的就绪不补播", function()
    scenario(function(env, lust)
      local row = CreateFrame("Frame", nil, nil)
      satedFor(env, 10)
      lust:Update(row)
      lust:Hide(row)
      satedFor(env, nil)                -- 隐藏期间 ready 变成 0
      lust:Update(row)                  -- 重新显示：这次采样是播种，不是跨越
      assert.equals(0, #env.played)
      assert.is_false(row.lustFrame.pulse:IsShown())
      tick(env)                         -- 播种后停在 0，再采样也不播
      assert.equals(0, #env.played)
    end)
  end)
end)

describe("CooldownLust 精疲力尽预提醒", function()
  before_each(function() mocks.reset() end)

  it("sated 是约束项时 40 -> 25 播一次 lust-sated-soon，不脉冲", function()
    scenario(function(env, lust)
      local row = CreateFrame("Frame", nil, nil)
      satedFor(env, 40)
      lust:Update(row)
      satedFor(env, 25)                 -- 跨越 30s 门槛，satedLeft == ready（约束项）
      tick(env)
      assert.same({ "lust-sated-soon" }, playedKeys(env))
      assert.is_false(row.lustFrame.pulse:IsShown())
      assert.equals(0, row.lustFrame.pulseAnim.plays)
      satedFor(env, 20)                 -- 已经在 <=30 区间内，不再重播
      tick(env)
      assert.equals(1, #env.played)
    end)
  end)

  it("CD 是约束项（无 debuff）时跨进 30s 内什么都不播", function()
    scenario(function(env, lust)
      local row = CreateFrame("Frame", nil, nil)
      env.cooldown = { isEnabled = true, isActive = true, startTime = 60, duration = 80 }
      lust:Update(row)                  -- ready=40（140-100），satedLeft=0
      env.time = 115                    -- ready=25，跨进 30s 内，但约束是 CD 不是 sated
      tick(env)
      assert.equals(0, #env.played)
    end)
  end)
end)

describe("CooldownLust 开关与渲染", function()
  before_each(function() mocks.reset() end)

  it("lustAlert 关掉时两种跨越都不播、不脉冲", function()
    scenario(function(env, lust)
      env.db.beacon.lustAlert = false
      local row = CreateFrame("Frame", nil, nil)
      satedFor(env, 40)
      lust:Update(row)
      satedFor(env, 25)                 -- 预提醒跨越：开关关，静默
      tick(env)
      satedFor(env, nil)                -- 就绪跨越：开关关，静默
      tick(env)
      assert.equals(0, #env.played)
      assert.is_false(row.lustFrame.pulse:IsShown())
      assert.equals(0, row.lustFrame.pulseAnim.plays)
    end)
  end)

  it("倒计时文本渲染不回归：90 -> 1.5m，20 -> 20，0 -> 空", function()
    scenario(function(env, lust)
      local row = CreateFrame("Frame", nil, nil)
      satedFor(env, 90)
      lust:Update(row)
      assert.equals("1.5m", row.lustFrame.text:GetText())
      satedFor(env, 20)
      tick(env)
      assert.equals("20", row.lustFrame.text:GetText())
      -- 倒计时期图标半透、不叠状态色（v8 渲染语言）
      assert.equals(0.45, row.lustFrame.icon.alpha)
      assert.same({ 1, 1, 1, 1 }, row.lustFrame.icon.vertexColor)
      satedFor(env, nil)
      tick(env)
      assert.equals("", row.lustFrame.text:GetText())
      -- 可用就是清晰原画：不透明、不染绿
      assert.equals(1, row.lustFrame.icon.alpha)
      assert.same({ 1, 1, 1, 1 }, row.lustFrame.icon.vertexColor)
    end)
  end)
end)

describe("CooldownLust 行格倒计时位置", function()
  before_each(function() mocks.reset() end)

  it("行格倒计时仍在图标下方（对照窗才在上方）", function()
    scenario(function(env, lust)
      local row = CreateFrame("Frame", nil, nil)
      lust:Update(row)
      local p = row.lustFrame.text.points[1]
      assert.equals("TOP", p[1])
      assert.equals(row.lustFrame, p[2])
      assert.equals("BOTTOM", p[3])
    end)
  end)
end)
