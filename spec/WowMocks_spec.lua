local mocks = require("wow_mocks")

describe("wow_mocks StatusBar / clip / rotation stubs", function()
  before_each(function() mocks.reset() end)

  it("records statusbar configuration and value with its interpolation mode", function()
    mocks.withCooldownRuntime(function()
      local bar = CreateFrame("StatusBar", nil, UIParent)
      bar:SetOrientation("VERTICAL")
      bar:SetReverseFill(true)
      bar:SetMinMaxValues(0, 10)
      bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
      bar:SetValue(7, Enum.StatusBarInterpolation.ExponentialEaseOut)

      assert.equals("StatusBar", bar.kind)
      assert.equals("VERTICAL", bar.orientation)
      assert.is_true(bar.reverseFill)
      assert.same({ 0, 10 }, bar.minMax)
      assert.equals("Interface\\Buttons\\WHITE8X8", bar.statusBarTexture)
      assert.equals(7, bar.value)
      assert.equals(7, bar:GetValue())
      assert.equals(Enum.StatusBarInterpolation.ExponentialEaseOut, bar.interpolation)
    end)
  end)

  it("defaults GetStatusBarColor to a fresh bar's white and records SetStatusBarColor", function()
    mocks.withCooldownRuntime(function()
      local bar = CreateFrame("StatusBar", nil, UIParent)
      -- 真实客户端新建的状态条报 1,1,1,1；这里返回 nil 才是凭空造出分歧，
      -- 并会让产品代码里合法的 local r,g,b,a = bar:GetStatusBarColor() 直接崩掉。
      local dr, dg, db, da = bar:GetStatusBarColor()
      assert.equals(1, dr)
      assert.equals(1, dg)
      assert.equals(1, db)
      assert.equals(1, da)

      -- 0.5 / 0.25 二进制可精确表示，且值经 {...} + unpack 原样穿过、没有任何运算，
      -- 所以精确相等断言不会踩到本仓库的浮点陷阱。
      bar:SetStatusBarColor(0.5, 0.25, 0, 1)
      local r, g, b, a = bar:GetStatusBarColor()
      assert.equals(0.5, r)
      assert.equals(0.25, g)
      assert.equals(0, b)
      assert.equals(1, a)
      assert.same({ 0.5, 0.25, 0, 1 }, bar.statusBarColor)
    end)
  end)

  it("returns an identity-comparable region from GetStatusBarTexture", function()
    mocks.withCooldownRuntime(function()
      local bar = CreateFrame("StatusBar", nil, UIParent)
      local tex = bar:GetStatusBarTexture()
      assert.is_not_nil(tex)
      assert.equals(tex, bar:GetStatusBarTexture())
      assert.equals(bar, tex.parent)
      -- getter 会把自己的 region 追加进 regions（与其它子工厂一致），而那是 CreateTexture
      -- 造不出来的 .texture == nil 项；钉死「第二次调用不重复追加」，免得按 #regions 计数的断言被它悄悄改写。
      assert.equals(1, #bar.regions)
      assert.equals(tex, bar.regions[1])
    end)
  end)

  it("records clipping, blend mode and texture sublayer", function()
    mocks.withCooldownRuntime(function()
      local clip = CreateFrame("Frame", nil, UIParent)
      clip:SetClipsChildren(true)
      assert.is_true(clip.clipsChildren)

      local tex = clip:CreateTexture(nil, "BACKGROUND", nil, -7)
      assert.equals("BACKGROUND", tex.layer)
      assert.equals(-7, tex.sublayer)

      tex:SetBlendMode("ADD")
      assert.equals("ADD", tex.blendMode)

      -- 真实签名 SetDrawLayer(layer[, subLayer])；driver 的贴图靠它压到 BACKGROUND 0
      tex:SetDrawLayer("BACKGROUND", 0)
      assert.equals("BACKGROUND", tex.drawLayer)
      assert.equals(0, tex.drawSublayer)
    end)
  end)

  it("records Rotation animation degrees", function()
    mocks.withCooldownRuntime(function()
      local tex = UIParent:CreateTexture(nil, "ARTWORK")
      local ag = tex:CreateAnimationGroup()
      local rot = ag:CreateAnimation("Rotation")
      rot:SetDegrees(-360)
      rot:SetDuration(45)
      rot:SetOrder(1)

      assert.equals("Rotation", rot.kind)
      assert.equals(-360, rot.degrees)
      assert.equals(45, rot.duration)
      assert.equals(1, rot.order)
      assert.equals(tex, ag.owner)
    end)
  end)

  it("exposes StatusBarInterpolation enum members", function()
    mocks.withCooldownRuntime(function()
      assert.is_not_nil(Enum.StatusBarInterpolation)
      assert.is_number(Enum.StatusBarInterpolation.ExponentialEaseOut)
      -- 真实客户端只有这两个成员（原计划里的 Linear = 1 是臆造的）。必须钉死数值与键数：
      -- 录制断言比的是「枚举成员 == 它自己」，表漂回错误版本时整条套件照样全绿。
      assert.equals(0, Enum.StatusBarInterpolation.Immediate)
      assert.equals(1, Enum.StatusBarInterpolation.ExponentialEaseOut)
      local memberCount = 0
      for _ in pairs(Enum.StatusBarInterpolation) do memberCount = memberCount + 1 end
      assert.equals(2, memberCount)
      -- 保留既有的 SpellBookSpellBank，不能被新枚举覆盖掉
      assert.equals(0, Enum.SpellBookSpellBank.Player)
    end)
  end)
end)
