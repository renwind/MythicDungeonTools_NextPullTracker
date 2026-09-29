local mocks = require("wow_mocks")

local LABEL_SIZE = 28
local ICON_SIZE  = 44

-- 动画组建在 Frame 上，所以 group.owner 就是框体本身；标签与图标都是它的 region
-- （mock 的 CreateFontString / CreateTexture 会追加到 frame.regions），
-- 顺序即创建顺序：标签在前，三个图标槽在后。
local function parts(env)
  local frame = env.animations[1].owner
  local label, icons = nil, {}
  for _, r in ipairs(frame.regions) do
    if r.kind == "FontString" then label = r
    elseif r.kind == "Texture" then icons[#icons + 1] = r end
  end
  return frame, label, icons, env.animations[1]
end

describe("AlertBanner 屏幕中部图标横幅", function()
  before_each(function() mocks.reset() end)

  local function scenario(fn)
    mocks.withCooldownRuntime(function(env)
      mocks.loadSource("Modules/Theme.lua")
      mocks.loadSource("Modules/AlertBanner.lua")
      fn(env, MDT_NPT.AlertBanner)
    end)
  end

  it("Show 显示标签与一个图标、显示框体并播放动画", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local frame, label, icons, group = parts(env)
      assert.is_true(frame.shown)
      -- mock 的 L 是恒等表，所以标签文本就是键名本身
      assert.equals("Next Pull", label.text)
      assert.is_true(icons[1].shown)
      assert.equals("spell:2825", icons[1].texture)
      assert.is_false(icons[2].shown)
      assert.is_false(icons[3].shown)
      assert.equals(1, group.plays)
    end)
  end)

  it("三个图标按给定顺序全部显示", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825", "item:241308", "spell:114050" })
      local _, _, icons = parts(env)
      assert.is_true(icons[1].shown)
      assert.is_true(icons[2].shown)
      assert.is_true(icons[3].shown)
      assert.equals("spell:2825", icons[1].texture)
      assert.equals("item:241308", icons[2].texture)
      assert.equals("spell:114050", icons[3].texture)
    end)
  end)

  it("图标多于 MAX_ICONS 时截断，不溢出布局", function()
    scenario(function(env, banner)
      banner:Show({ "a", "b", "c", "d" })
      local frame, _, icons = parts(env)
      assert.equals(3, #icons)
      assert.is_true(icons[3].shown)
      assert.equals("c", icons[3].texture)
      -- 整行宽度按 3 个图标算：108(标签) + 10 + 3*44 + 2*8
      assert.equals(266, frame.width)
    end)
  end)

  it("nil 或空列表不创建框体", function()
    scenario(function(env, banner)
      banner:Show(nil)
      banner:Show({})
      assert.equals(0, #env.animations)
    end)
  end)

  it("整行水平居中：宽度与各元素偏移按标签实测宽度算出", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825", "item:241308", "spell:114050" })
      local frame, label, icons = parts(env)
      -- mock 的 GetStringWidth 是每字符 12px，"Next Pull" 9 字符 = 108
      assert.equals(108, label:GetStringWidth())
      assert.equals(266, frame.width)
      assert.equals(ICON_SIZE, frame.height)
      -- SetPoint 的实参被 mock 记成 points[i] = { point, relativeTo, relativePoint, x, y }
      assert.equals(-133, label.points[1][4])                 -- -266/2
      assert.equals(-15, icons[1].points[1][4])               -- -133 + 108 + 10
      assert.equals(-15 + ICON_SIZE + 8, icons[2].points[1][4])
    end)
  end)

  it("连续 Show 先停掉旧动画再播新的", function()
    scenario(function(env, banner)
      banner:Show({ "a" })
      banner:Show({ "b" })
      local _, _, icons, group = parts(env)
      assert.equals(1, #env.animations)          -- 复用同一个动画组
      assert.equals(1, group.stops)
      assert.equals(2, group.plays)
      assert.equals("b", icons[1].texture)
    end)
  end)

  it("动画播完后隐藏框体", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local frame, _, _, group = parts(env)
      group:_testFinish()
      assert.is_false(frame.shown)
    end)
  end)

  it("Hide 停止动画并隐藏", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local frame, _, _, group = parts(env)
      banner:Hide()
      assert.is_false(frame.shown)
      assert.equals(1, group.stops)
    end)
  end)

  it("Hide 在从未 Show 过时不报错", function()
    scenario(function(_, banner)
      assert.has_no.errors(function() banner:Hide() end)
    end)
  end)

  it("标签显式设定字号与粗描边，不用臆造的 SetOutlined", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local _, label = parts(env)
      assert.equals(LABEL_SIZE, label._fontSize)
      assert.equals("THICKOUTLINE", label._fontFlags)
    end)
  end)

  it("没有 EUI 时回落到暴雪当前语言的字体文件", function()
    scenario(function(env, banner)
      assert.is_nil(MDT_NPT.Theme.GetFontPath())
      banner:Show({ "spell:2825" })
      local _, label = parts(env)
      assert.equals("Fonts\\blizzard.ttf", label._fontPath)
    end)
  end)

  it("有 EUI 字体时用 EUI 的字体文件", function()
    scenario(function(env, banner)
      MDT_NPT.Theme.GetFontPath = function() return "Interface\\AddOns\\EUI\\font.ttf" end
      banner:Show({ "spell:2825" })
      local _, label = parts(env)
      assert.equals("Interface\\AddOns\\EUI\\font.ttf", label._fontPath)
    end)
  end)

  it("框体不拦截鼠标，层级设为 FULLSCREEN_DIALOG", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local frame = parts(env)
      assert.is_false(frame.mouseEnabled)
      assert.equals("FULLSCREEN_DIALOG", frame.strata)
    end)
  end)

  it("三段动画：淡入 / 停留 / 淡出", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local _, _, _, group = parts(env)
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

  it("用真实的 SetScript(\"OnFinished\") 而不是臆造的 SetOnFinished", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local _, _, _, group = parts(env)
      -- 客户端的 AnimationGroup 没有 SetOnFinished；mock 也不提供它，
      -- 所以产品代码一旦改回那个不存在的方法，这里会因为 nil 调用直接炸。
      assert.is_function(group.scripts.OnFinished)
    end)
  end)
end)
