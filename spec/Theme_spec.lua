local mocks = require("wow_mocks")

describe("Theme.lua", function()
  local Theme

  before_each(function()
    mocks.reset()
    _G.EllesmereUI = nil
    mocks.loadSource("Modules/Theme.lua")
    Theme = _G.MDT_NPT.Theme
  end)

  describe("token completeness", function()
    it("provides all expected color tokens as 4-element tables", function()
      local expectedKeys = {
        "accent", "accentSoft", "accentBar", "accentHoverBg",
        "panelBg", "panelBorder", "minimapBg", "minimapBorder", "buttonBg",
        "textPrimary", "textSecondary", "textMuted", "shadow",
        "statusCombat", "progressCurrent", "progressPreview", "progressBg",
        "mobCaster", "mobMiniboss", "mobBoss", "mobOther",
        "cdUse", "cdSave", "cdConflict", "cdMismatch", "cdEmpty",
        "lustNotReady", "lustReady",
        "settingsBoxBg", "swatchBorder",
      }
      for _, key in ipairs(expectedKeys) do
        local c = Theme.colors[key]
        assert.is_table(c, "missing color token: " .. key)
        assert.equals(4, #c, "color token " .. key .. " must have 4 elements")
        for i = 1, 4 do
          assert.is_number(c[i], key .. "[" .. i .. "] must be a number")
        end
      end
    end)
  end)

  describe("pull palette", function()
    it("pullColors.next shares the accent table reference", function()
      assert.equals(Theme.colors.accent, Theme.pullColors["next"])
    end)

    it("pullOutlineColors.next shares the accent table reference", function()
      assert.equals(Theme.colors.accent, Theme.pullOutlineColors["next"])
    end)

    it("contains all expected pull state keys", function()
      for _, key in ipairs({ "next", "active", "completed", "upcoming", "unselected" }) do
        assert.is_table(Theme.pullColors[key], "missing pullColors key: " .. key)
      end
      for _, key in ipairs({ "next", "active" }) do
        assert.is_table(Theme.pullOutlineColors[key], "missing pullOutlineColors key: " .. key)
      end
    end)
  end)

  describe("EUI fallback", function()
    it("does not error when EllesmereUI is nil", function()
      assert.has_no.errors(function()
        Theme.Refresh()
      end)
    end)

    it("accent is the built-in fallback when EUI is absent", function()
      -- #0CD29D = 12/255, 210/255, 157/255
      local a = Theme.colors.accent
      assert.is_true(math.abs(a[1] - 12/255) < 0.001)
      assert.is_true(math.abs(a[2] - 210/255) < 0.001)
      assert.is_true(math.abs(a[3] - 157/255) < 0.001)
      assert.equals(1, a[4])
    end)

    it("IsEUIAvailable returns false when EUI is absent", function()
      assert.is_false(Theme.IsEUIAvailable())
    end)

    it("GetFontPath returns nil when EUI is absent", function()
      assert.is_nil(Theme.GetFontPath())
    end)
  end)

  describe("EUI detection", function()
    it("picks up accent colour from EUI.GetAccentColor", function()
      mocks.reset()
      _G.EllesmereUI = {
        GetAccentColor = function() return 0.1, 0.2, 0.3 end,
      }
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme
      local a = Theme.colors.accent
      assert.is_true(math.abs(a[1] - 0.1) < 0.001)
      assert.is_true(math.abs(a[2] - 0.2) < 0.001)
      assert.is_true(math.abs(a[3] - 0.3) < 0.001)
    end)

    it("picks up font path from EUI.GetFontPath", function()
      mocks.reset()
      _G.EllesmereUI = {
        GetFontPath = function() return "Fonts\\MyFont.ttf" end,
      }
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme
      assert.equals("Fonts\\MyFont.ttf", Theme.GetFontPath())
    end)

    it("IsEUIAvailable returns true when EUI is present", function()
      mocks.reset()
      _G.EllesmereUI = {}
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme
      assert.is_true(Theme.IsEUIAvailable())
    end)
  end)

  describe("EUI error safety", function()
    it("survives GetAccentColor throwing an error", function()
      mocks.reset()
      _G.EllesmereUI = {
        GetAccentColor = function() error("boom") end,
      }
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme
      -- Should have fallen back to built-in accent, no crash
      local a = Theme.colors.accent
      assert.is_true(math.abs(a[1] - 12/255) < 0.001)
    end)

    it("survives GetFontPath throwing an error", function()
      mocks.reset()
      _G.EllesmereUI = {
        GetFontPath = function() error("no font") end,
      }
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme
      assert.is_nil(Theme.GetFontPath())
    end)
  end)

  describe("Refresh in-place update", function()
    it("Refresh updates accent in-place after EUI appears", function()
      -- Start without EUI
      mocks.reset()
      _G.EllesmereUI = nil
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme

      local accentRef = Theme.colors.accent  -- capture reference
      local originalR = accentRef[1]

      -- Simulate EUI appearing
      _G.EllesmereUI = {
        GetAccentColor = function() return 0.9, 0.8, 0.7 end,
      }
      Theme.Refresh()

      -- Same table reference, updated values
      assert.equals(accentRef, Theme.colors.accent)
      assert.is_true(math.abs(accentRef[1] - 0.9) < 0.001)
      assert.is_true(math.abs(accentRef[2] - 0.8) < 0.001)
      assert.is_true(math.abs(accentRef[3] - 0.7) < 0.001)
    end)
  end)

  describe("CreateBorder", function()
    local function makeMockParent()
      local parent = { textures = {} }
      function parent:CreateTexture(_, layer)
        local tex = { points = {}, layer = layer }
        function tex:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
        function tex:SetPoint(anchor, ...) self.points[#self.points + 1] = anchor end
        function tex:SetHeight(h) self.height = h end
        function tex:SetWidth(w) self.width = w end
        parent.textures[#parent.textures + 1] = tex
        return tex
      end
      return parent
    end

    it("returns a table with top, bottom, left, right edges", function()
      local parent = makeMockParent()
      local edges = Theme.CreateBorder(parent)
      assert.is_table(edges.top)
      assert.is_table(edges.bottom)
      assert.is_table(edges.left)
      assert.is_table(edges.right)
    end)

    it("creates exactly 4 textures on the BORDER layer", function()
      local parent = makeMockParent()
      Theme.CreateBorder(parent)
      assert.equals(4, #parent.textures)
      for _, tex in ipairs(parent.textures) do
        assert.equals("BORDER", tex.layer)
      end
    end)

    it("applies panelBorder color to all edges", function()
      local parent = makeMockParent()
      local edges = Theme.CreateBorder(parent)
      local expected = Theme.colors.panelBorder
      assert.same(expected, edges.top.color)
      assert.same(expected, edges.bottom.color)
      assert.same(expected, edges.left.color)
      assert.same(expected, edges.right.color)
    end)

    it("sets 1px thickness on top/bottom (height) and left/right (width)", function()
      local parent = makeMockParent()
      local edges = Theme.CreateBorder(parent)
      assert.equals(1, edges.top.height)
      assert.equals(1, edges.bottom.height)
      assert.equals(1, edges.left.width)
      assert.equals(1, edges.right.width)
    end)
  end)

  describe("StyleButton", function()
    local function makeMockButton()
      local btn = { textures = {}, fontStrings = {}, scripts = {} }
      function btn:CreateTexture(_, layer)
        local tex = { layer = layer }
        function tex:SetAllPoints() self.allPoints = true end
        function tex:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
        function tex:SetPoint(...) end
        btn.textures[#btn.textures + 1] = tex
        return tex
      end
      function btn:CreateFontString(_, overlay, fontObj)
        local fs = { overlay = overlay, fontObj = fontObj }
        function fs:SetPoint() end
        function fs:SetText(t) self.text = t end
        function fs:SetTextColor(r, g, b, a) self.color = { r, g, b, a } end
        btn.fontStrings[#btn.fontStrings + 1] = fs
        return fs
      end
      function btn:SetScript(name, fn) self.scripts[name] = fn end
      return btn
    end

    it("returns a FontString", function()
      local btn = makeMockButton()
      local fs = Theme.StyleButton(btn, "Test")
      assert.is_table(fs)
      assert.equals("Test", fs.text)
    end)

    it("creates bg and border textures", function()
      local btn = makeMockButton()
      Theme.StyleButton(btn, "X")
      assert.equals(2, #btn.textures)
      assert.equals("BACKGROUND", btn.textures[1].layer)
      assert.equals("BORDER", btn.textures[2].layer)
    end)

    it("colors the text with the accent token", function()
      local btn = makeMockButton()
      local fs = Theme.StyleButton(btn, "Go")
      assert.same(Theme.colors.accent, fs.color)
    end)

    it("applies buttonBg to the background texture", function()
      local btn = makeMockButton()
      Theme.StyleButton(btn, "Go")
      assert.same(Theme.colors.buttonBg, btn.textures[1].color)
    end)

    it("applies accentSoft to the border texture", function()
      local btn = makeMockButton()
      Theme.StyleButton(btn, "Go")
      assert.same(Theme.colors.accentSoft, btn.textures[2].color)
    end)

    it("installs OnEnter/OnLeave hover scripts", function()
      local btn = makeMockButton()
      Theme.StyleButton(btn, "Go")
      assert.is_function(btn.scripts["OnEnter"])
      assert.is_function(btn.scripts["OnLeave"])
    end)

    it("OnEnter swaps bg to accentHoverBg and OnLeave restores buttonBg", function()
      local btn = makeMockButton()
      Theme.StyleButton(btn, "Go")
      local bg = btn.textures[1]
      -- Simulate hover
      btn.scripts["OnEnter"]()
      assert.same(Theme.colors.accentHoverBg, bg.color)
      -- Simulate leave
      btn.scripts["OnLeave"]()
      assert.same(Theme.colors.buttonBg, bg.color)
    end)

    it("uses a custom font object when provided", function()
      local btn = makeMockButton()
      Theme.StyleButton(btn, "Go", "MyCustomFont")
      assert.equals("MyCustomFont", btn.fontStrings[1].fontObj)
    end)

    it("defaults to Theme.fonts.large when no font object given", function()
      local btn = makeMockButton()
      Theme.StyleButton(btn, "Go")
      assert.equals(Theme.fonts.large, btn.fontStrings[1].fontObj)
    end)
  end)

  describe("GetFontPath", function()
    it("returns nil by default without EUI", function()
      assert.is_nil(Theme.GetFontPath())
    end)

    it("returns the cached path after Refresh with EUI", function()
      _G.EllesmereUI = {
        GetFontPath = function() return "Fonts\\Test.ttf" end,
      }
      mocks.reset()
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme
      assert.equals("Fonts\\Test.ttf", Theme.GetFontPath())
    end)
  end)

  describe("textures", function()
    it("provides circleWhite path", function()
      assert.is_string(Theme.textures.circleWhite)
    end)

    it("provides statusBar path", function()
      assert.is_string(Theme.textures.statusBar)
    end)
  end)

  describe("fonts", function()
    it("provides all expected font keys", function()
      for _, key in ipairs({ "large", "small", "normal", "highlightSmall", "npcName", "cdText" }) do
        assert.is_string(Theme.fonts[key], "missing font key: " .. key)
      end
    end)
  end)

  describe("font bridge", function()
    it("updates Theme.fonts to NPT_* names when EUI provides a font path", function()
      mocks.reset()
      _G.EllesmereUI = {
        GetFontPath = function() return "Fonts\\MyCustom.ttf" end,
      }
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme

      assert.equals("NPT_FontNormalLarge",    Theme.fonts.large)
      assert.equals("NPT_FontNormalSmall",    Theme.fonts.small)
      assert.equals("NPT_FontNormal",         Theme.fonts.normal)
      assert.equals("NPT_FontHighlightSmall", Theme.fonts.highlightSmall)
    end)

    it("creates global FontObjects with the correct font path and sizes", function()
      mocks.reset()
      _G.EllesmereUI = {
        GetFontPath = function() return "Fonts\\Bridge.ttf" end,
      }
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme

      local obj = _G["NPT_FontNormal"]
      assert.is_table(obj)
      local path, size = obj:GetFont()
      assert.equals("Fonts\\Bridge.ttf", path)
      assert.equals(12, size)

      local objLarge = _G["NPT_FontNormalLarge"]
      assert.is_table(objLarge)
      local pathL, sizeL = objLarge:GetFont()
      assert.equals("Fonts\\Bridge.ttf", pathL)
      assert.equals(14, sizeL)

      local objSmall = _G["NPT_FontNormalSmall"]
      assert.is_table(objSmall)
      local _, sizeS = objSmall:GetFont()
      assert.equals(10, sizeS)
    end)

    it("keeps GameFont* defaults when EUI provides no font path", function()
      mocks.reset()
      _G.EllesmereUI = nil
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme

      assert.equals("GameFontNormalLarge",     Theme.fonts.large)
      assert.equals("GameFontNormalSmall",     Theme.fonts.small)
      assert.equals("GameFontNormal",          Theme.fonts.normal)
      assert.equals("GameFontHighlightSmall",  Theme.fonts.highlightSmall)
    end)

    it("is idempotent: multiple Refresh calls do not duplicate FontObjects", function()
      mocks.reset()
      _G.EllesmereUI = {
        GetFontPath = function() return "Fonts\\First.ttf" end,
      }
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme

      -- Capture the FontObject reference from the first creation.
      local firstRef = _G["NPT_FontNormal"]
      assert.is_table(firstRef)

      -- Second Refresh with a different path should reuse the same object.
      _G.EllesmereUI.GetFontPath = function() return "Fonts\\Second.ttf" end
      assert.has_no.errors(function() Theme.Refresh() end)

      assert.equals(firstRef, _G["NPT_FontNormal"])
      local path = firstRef:GetFont()
      assert.equals("Fonts\\Second.ttf", path)
    end)

    it("reverts to GameFont* defaults when font path disappears", function()
      mocks.reset()
      _G.EllesmereUI = {
        GetFontPath = function() return "Fonts\\Temp.ttf" end,
      }
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme
      assert.equals("NPT_FontNormal", Theme.fonts.normal)

      -- Simulate EUI going away (unlikely but tests robustness).
      -- _fontPath is still set from last Refresh, so we need EUI to disappear
      -- AND fontPath to be nil.  Since _fontPath is a local, we simulate by
      -- reloading without EUI.
      mocks.reset()
      _G.EllesmereUI = nil
      mocks.loadSource("Modules/Theme.lua")
      Theme = _G.MDT_NPT.Theme
      assert.equals("GameFontNormal", Theme.fonts.normal)
    end)
  end)
end)
