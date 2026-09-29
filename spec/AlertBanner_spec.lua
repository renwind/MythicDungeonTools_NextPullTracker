local mocks = require("wow_mocks")

local LABEL_SIZE = 28
local ICON_SIZE  = 44
local GLOW_SIZE  = ICON_SIZE * 1.5
local PAD, GAP, ICON_GAP = 10, 12, 8
-- mock 的 GetStringWidth 每字符 12px，"Next Pull" 9 字符 = 108
local LABEL_W = 108

local MEDIA       = "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\"
local CIRCLE_MASK = MEDIA .. "circle_mask.png"
local RING_GLOW   = MEDIA .. "ring_glow.png"

-- 动画组建在横幅框上，所以 group.owner 就是横幅框；标签、辉光、图标、遮罩都是它的
-- region（mock 的 CreateFontString / CreateTexture / CreateMaskTexture 会分别追加到
-- frame.regions / frame.masks）。辉光靠贴图路径识别，其余 Texture 即图标槽。
local function parts(env)
  local plate = env.animations[1].owner
  local label, icons, glows = nil, {}, {}
  for _, r in ipairs(plate.regions) do
    if r.kind == "FontString" then label = r
    elseif r.kind == "Texture" then
      if r.texture == RING_GLOW then glows[#glows + 1] = r
      else icons[#icons + 1] = r end
    end
  end
  return plate, label, icons, glows, env.animations[1]
end

describe("AlertBanner 屏幕中部图标横幅（v6 无底板 + 圆形发光图标）", function()
  before_each(function() mocks.reset() end)

  local function scenario(fn)
    mocks.withCooldownRuntime(function(env)
      mocks.loadSource("Modules/Theme.lua")
      mocks.loadSource("Modules/AlertBanner.lua")
      fn(env, MDT_NPT.AlertBanner)
    end)
  end

  it("Show 显示标签与一个图标、显示横幅框并播放动画", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local plate, label, icons, glows, group = parts(env)
      assert.is_true(plate.shown)
      -- mock 的 L 是恒等表，所以标签文本就是键名本身
      assert.equals("Next Pull", label.text)
      assert.is_true(icons[1].shown)
      assert.equals("spell:2825", icons[1].texture)
      assert.is_true(glows[1].shown)
      assert.is_false(icons[2].shown)
      assert.is_false(icons[3].shown)
      assert.is_false(glows[2].shown)
      assert.is_false(glows[3].shown)
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
      local plate, _, icons = parts(env)
      assert.equals(3, #icons)
      assert.is_true(icons[3].shown)
      assert.equals("c", icons[3].texture)
      -- 横幅框宽度按 3 个图标算：20(内衬) + 108(标签) + 12 + 3*44 + 2*8
      assert.equals(288, plate.width)
    end)
  end)

  it("nil 或空列表不创建框体", function()
    scenario(function(env, banner)
      banner:Show(nil)
      banner:Show({})
      assert.equals(0, #env.animations)
    end)
  end)

  it("横幅框尺寸按布局公式算：n=1/2/3", function()
    scenario(function(env, banner)
      banner:Show({ "a" })
      local plate = parts(env)
      assert.equals(PAD * 2 + LABEL_W + GAP + ICON_SIZE, plate.width)
      assert.equals(PAD * 2 + ICON_SIZE, plate.height)
      banner:Show({ "a", "b" })
      assert.equals(PAD * 2 + LABEL_W + GAP + 2 * ICON_SIZE + ICON_GAP, plate.width)
      banner:Show({ "a", "b", "c" })
      assert.equals(PAD * 2 + LABEL_W + GAP + 3 * ICON_SIZE + 2 * ICON_GAP, plate.width)
      assert.equals(288, plate.width)
      assert.equals(64, plate.height)
    end)
  end)

  it("横幅框内左起排版：标签在左内衬处，图标依次右排", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825", "item:241308", "spell:114050" })
      local plate, label, icons = parts(env)
      assert.equals(LABEL_W, label:GetStringWidth())
      -- SetPoint 的实参被 mock 记成 points[i] = { point, relativeTo, relativePoint, x, y }
      assert.equals("LEFT", label.points[1][1])
      assert.same(plate, label.points[1][2])
      assert.equals(PAD, label.points[1][4])
      assert.equals(0, label.points[1][5])
      assert.equals(PAD + LABEL_W + GAP, icons[1].points[1][4])
      assert.equals(PAD + LABEL_W + GAP + ICON_SIZE + ICON_GAP, icons[2].points[1][4])
      assert.equals(PAD + LABEL_W + GAP + 2 * (ICON_SIZE + ICON_GAP), icons[3].points[1][4])
    end)
  end)

  it("连续 Show 先停掉旧动画再播新的", function()
    scenario(function(env, banner)
      banner:Show({ "a" })
      banner:Show({ "b" })
      local _, _, icons, _, group = parts(env)
      assert.equals(1, #env.animations)          -- 复用同一个动画组
      assert.equals(1, group.stops)
      assert.equals(2, group.plays)
      assert.equals("b", icons[1].texture)
    end)
  end)

  it("动画播完后隐藏横幅框", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local plate, _, _, _, group = parts(env)
      group:_testFinish()
      assert.is_false(plate.shown)
    end)
  end)

  it("Hide 停止动画并隐藏", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local plate, _, _, _, group = parts(env)
      banner:Hide()
      assert.is_false(plate.shown)
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

  it("横幅框不拦截鼠标，层级设为 FULLSCREEN_DIALOG", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local plate = parts(env)
      assert.is_false(plate.mouseEnabled)
      assert.equals("FULLSCREEN_DIALOG", plate.strata)
    end)
  end)

  it("无背景底板与边框：框不挂 BackdropTemplate（v6 去掉）", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local plate = parts(env)
      -- mock 只给带 BackdropTemplate 模板的框挂 SetBackdrop* 记录器；
      -- 记录器不存在 = 产品代码没再碰背景/边框。
      assert.is_nil(plate.backdrop)
      assert.is_nil(plate.backdropCalls)
    end)
  end)

  it("每个可见图标恰好一张圆形遮罩，用自带 circle_mask 与 CLAMPTOBLACKADDITIVE", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825", "item:241308", "spell:114050" })
      local plate, _, icons = parts(env)
      assert.equals(3, #plate.masks)
      for i = 1, 3 do
        assert.equals(1, #icons[i].maskList)
        local mask = icons[i].maskList[1]
        assert.equals(CIRCLE_MASK, mask.texture)
        assert.equals("CLAMPTOBLACKADDITIVE", mask.textureArgs[2])
        assert.equals("CLAMPTOBLACKADDITIVE", mask.textureArgs[3])
        -- 遮罩盖满图标本体，圆形裁切才对得上图标边界
        assert.same(icons[i], mask.allPoints)
      end
    end)
  end)

  it("辉光环用自带 ring_glow，尺寸外扩且染成主题色", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local _, _, icons, glows = parts(env)
      local accent = MDT_NPT.Theme.colors.accent
      for i = 1, 3 do
        assert.equals(RING_GLOW, glows[i].texture)
        assert.equals(GLOW_SIZE, glows[i].width)
        assert.equals(GLOW_SIZE, glows[i].height)
        assert.equals("OVERLAY", glows[i].layer)
        assert.same(accent, glows[i].vertexColor)
        -- 辉光钉在图标中心：锚点相对图标本体，挪图标即挪辉光
        assert.equals("CENTER", glows[i].points[1][1])
        assert.same(icons[i], glows[i].points[1][2])
      end
      assert.equals("ARTWORK", icons[1].layer)
      assert.same(accent, { 12 / 255, 210 / 255, 157 / 255, 1 })
    end)
  end)

  it("EUI 主题刷新后重新染色标签与辉光", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local _, label, _, glows = parts(env)
      assert.same(MDT_NPT.Theme.colors.accent, glows[1].vertexColor)
      _G.EllesmereUI = { GetAccentColor = function() return 0.2, 0.4, 0.6 end }
      MDT_NPT.Theme.Refresh()
      assert.same({ 0.2, 0.4, 0.6, 1 }, glows[1].vertexColor)
      assert.same({ 0.2, 0.4, 0.6, 1 }, label.color)
    end)
  end)

  it("三段 Alpha 动画：淡入 / 停留 / 淡出", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local _, _, _, _, group = parts(env)
      local alphas = {}
      for _, a in ipairs(group.animations) do
        if a.kind == "Alpha" then alphas[#alphas + 1] = a end
      end
      assert.equals(3, #alphas)
      assert.equals(1, alphas[1].order); assert.equals(0, alphas[1].from); assert.equals(1, alphas[1].to)
      assert.equals(2, alphas[2].order); assert.equals(1, alphas[2].from); assert.equals(1, alphas[2].to)
      assert.equals(3, alphas[3].order); assert.equals(1, alphas[3].from); assert.equals(0, alphas[3].to)
      assert.equals(0.15, alphas[1].duration)
      assert.equals(2.5, alphas[2].duration)
      assert.equals(0.6, alphas[3].duration)
    end)
  end)

  it("淡入组里带 Scale 弹出：0.9→1.0，同序同长，绕中心", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local _, _, _, _, group = parts(env)
      local scale
      for _, a in ipairs(group.animations) do
        if a.kind == "Scale" then scale = a end
      end
      assert.is_not_nil(scale)
      assert.equals(1, scale.order)
      assert.equals(0.15, scale.duration)
      assert.same({ "CENTER", 0, 0 }, scale.origin)
      assert.same({ 0.9, 0.9 }, scale.fromScale)
      assert.same({ 1, 1 }, scale.toScale)
    end)
  end)

  it("用真实的 SetScript(\"OnFinished\") 而不是臆造的 SetOnFinished", function()
    scenario(function(env, banner)
      banner:Show({ "spell:2825" })
      local _, _, _, _, group = parts(env)
      -- 客户端的 AnimationGroup 没有 SetOnFinished；mock 也不提供它，
      -- 所以产品代码一旦改回那个不存在的方法，这里会因为 nil 调用直接炸。
      assert.is_function(group.scripts.OnFinished)
    end)
  end)
end)
