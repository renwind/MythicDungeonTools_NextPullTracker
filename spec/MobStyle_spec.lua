local mocks = require("wow_mocks")

describe("MobStyle.lua", function()
  local MobStyle, Theme

  before_each(function()
    mocks.reset()
    mocks.loadSource("Modules/Theme.lua")
    mocks.loadSource("Modules/MobStyle.lua")
    MobStyle = _G.MDT_NPT.MobStyle
    Theme = _G.MDT_NPT.Theme
  end)

  describe("typeOf", function()
    it("classifies isBoss as boss", function()
      assert.equals("boss", MobStyle.typeOf({ isBoss = true, level = 90 }))
    end)

    it("classifies level > 91 as boss", function()
      assert.equals("boss", MobStyle.typeOf({ level = 92 }))
    end)

    it("classifies level 91 as miniboss", function()
      assert.equals("miniboss", MobStyle.typeOf({ level = 91 }))
    end)

    it("classifies an interruptible spell as caster", function()
      assert.equals("caster", MobStyle.typeOf({ level = 90, spells = { [1310324] = { interruptible = true } } }))
    end)

    it("ignores spells without the interruptible flag", function()
      assert.equals("other", MobStyle.typeOf({ level = 90, spells = { [1227020] = {} } }))
    end)

    it("classifies a plain mob as other", function()
      assert.equals("other", MobStyle.typeOf({ level = 90 }))
    end)

    it("boss tier beats caster (priority boss > elite > caster)", function()
      assert.equals("boss", MobStyle.typeOf({ isBoss = true, spells = { [1] = { interruptible = true } } }))
    end)
  end)

  describe("ringColors", function()
    -- Real Voidscar Arena case: Voidminder 244708, count 7 / health 6227050 in a
    -- 738-count dungeon -> efficiency ~0.990, just under the gray gate.
    local function lowEffEnemy(extra)
      _G.MDT.dungeonTotalCount[1] = { normal = 738 }
      local e = { level = 90, count = 7, health = 6227050, clones = { [1] = { count = 7 } } }
      for k, v in pairs(extra or {}) do e[k] = v end
      return e
    end

    it("plain caster: accent ring, no border", function()
      local base, border = MobStyle.ringColors(
        { level = 90, spells = { [1] = { interruptible = true } } }, { 1 })
      assert.same(Theme.colors.accent, base)
      assert.is_nil(border)
    end)

    it("miniboss + interruptible: purple base with accent border", function()
      local base, border = MobStyle.ringColors(
        { level = 91, spells = { [1] = { interruptible = true } } }, { 1 })
      assert.same(Theme.colors.mobMiniboss, base)
      assert.same(Theme.colors.accent, border)
    end)

    it("boss + interruptible: orange base with accent border", function()
      local base, border = MobStyle.ringColors(
        { isBoss = true, spells = { [1] = { interruptible = true } } }, { 1 })
      assert.same(Theme.colors.mobBoss, base)
      assert.same(Theme.colors.accent, border)
    end)

    it("miniboss without interruptible: purple base, no border", function()
      local base, border = MobStyle.ringColors({ level = 91 }, { 1 })
      assert.same(Theme.colors.mobMiniboss, base)
      assert.is_nil(border)
    end)

    it("high-efficiency other: dark red, no border", function()
      local base, border = MobStyle.ringColors({ level = 90 }, { 1 })
      assert.same(Theme.colors.mobOther, base)
      assert.is_nil(border)
    end)

    it("low-efficiency other: gray, no border", function()
      local base, border = MobStyle.ringColors(lowEffEnemy(), { 1 })
      assert.same({ 0.55, 0.55, 0.55 }, base)
      assert.is_nil(border)
    end)

    it("low-efficiency caster: gray gate exempt, accent ring", function()
      local base, border = MobStyle.ringColors(
        lowEffEnemy({ spells = { [1310324] = { interruptible = true } } }), { 1 })
      assert.same(Theme.colors.accent, base)
      assert.is_nil(border)
    end)

    it("low-efficiency miniboss: mandatory kill, stays purple", function()
      local base = MobStyle.ringColors(lowEffEnemy({ level = 91 }), { 1 })
      assert.same(Theme.colors.mobMiniboss, base)
    end)

    it("unknown efficiency (no dungeon totals): type colour, never gray", function()
      local base = MobStyle.ringColors({ level = 90, count = 7, health = 6227050 }, { 1 })
      assert.same(Theme.colors.mobOther, base)
    end)
  end)
end)
