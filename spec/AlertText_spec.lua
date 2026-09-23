local mocks = require("wow_mocks")

local FONT_SIZE = 30

-- 动画组建在 FontString 上，所以 group.owner 是文字区、group.owner.parent 是框体
-- （mock 的 widget 一直记着 parent，不需要额外字段）。
local function parts(env)
  local group = env.animations[1]
  return group.owner, group.owner.parent, group
end

describe("AlertText 屏幕中部文字", function()
  before_each(function() mocks.reset() end)

  local function scenario(fn)
    mocks.withCooldownRuntime(function(env)
      mocks.loadSource("Modules/Theme.lua")
      mocks.loadSource("Modules/AlertText.lua")
      fn(env, MDT_NPT.AlertText)
    end)
  end

  it("Show 设置文本、显示框体并播放动画", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local fs, frame, group = parts(env)
      assert.is_true(frame.shown)
      assert.equals("下一波嗜血", fs.text)
      assert.equals(1, group.plays)
    end)
  end)

  it("连续 Show 先停掉旧动画再播新的", function()
    scenario(function(env, alertText)
      alertText:Show("第一条")
      alertText:Show("第二条")
      local fs, _, group = parts(env)
      assert.equals(1, #env.animations)          -- 复用同一个动画组
      assert.equals(1, group.stops)
      assert.equals(2, group.plays)
      assert.equals("第二条", fs.text)
    end)
  end)

  it("动画播完后隐藏框体", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local _, frame, group = parts(env)
      group:_testFinish()
      assert.is_false(frame.shown)
    end)
  end)

  it("Hide 停止动画并隐藏", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local _, frame, group = parts(env)
      alertText:Hide()
      assert.is_false(frame.shown)
      assert.equals(1, group.stops)
    end)
  end)

  it("Hide 在从未 Show 过时不报错", function()
    scenario(function(_, alertText)
      assert.has_no.errors(function() alertText:Hide() end)
    end)
  end)

  it("空文本不创建框体", function()
    scenario(function(env, alertText)
      alertText:Show(nil)
      alertText:Show("")
      assert.equals(0, #env.animations)
    end)
  end)

  it("显式设定字号与粗描边，不用臆造的 SetOutlined", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local fs = parts(env)
      assert.equals(FONT_SIZE, fs._fontSize)
      assert.equals("THICKOUTLINE", fs._fontFlags)
    end)
  end)

  it("没有 EUI 时回落到暴雪当前语言的字体文件", function()
    scenario(function(env, alertText)
      assert.is_nil(MDT_NPT.Theme.GetFontPath())
      alertText:Show("下一波嗜血")
      assert.equals("Fonts\\blizzard.ttf", parts(env)._fontPath)
    end)
  end)

  it("有 EUI 字体时用 EUI 的字体文件", function()
    scenario(function(env, alertText)
      MDT_NPT.Theme.GetFontPath = function() return "Interface\\AddOns\\EUI\\font.ttf" end
      alertText:Show("下一波嗜血")
      assert.equals("Interface\\AddOns\\EUI\\font.ttf", parts(env)._fontPath)
    end)
  end)

  it("框体不拦截鼠标，且盖在常规 UI 之上", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local _, frame = parts(env)
      assert.is_false(frame.mouseEnabled)
      assert.equals("FULLSCREEN_DIALOG", frame.strata)
    end)
  end)

  it("三段动画：淡入 / 停留 / 淡出", function()
    scenario(function(env, alertText)
      alertText:Show("下一波嗜血")
      local _, _, group = parts(env)
      local anims = group.animations
      assert.equals(3, #anims)
      assert.equals(1, anims[1].order); assert.equals(0, anims[1].from); assert.equals(1, anims[1].to)
      assert.equals(2, anims[2].order); assert.equals(1, anims[2].from); assert.equals(1, anims[2].to)
      assert.equals(3, anims[3].order); assert.equals(1, anims[3].from); assert.equals(0, anims[3].to)
      assert.equals(0.15, anims[1].duration)
      assert.equals(2.5, anims[2].duration)
      assert.equals(0.6, anims[3].duration)
    end)
  end)
end)
