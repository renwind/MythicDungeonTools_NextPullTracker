local mocks = require("wow_mocks")

describe("BeaconFrame.lua", function()
  local BeaconFrame

  before_each(function()
    mocks.reset()
    mocks.loadSource("Modules/Theme.lua")
    -- BeaconFrame captures MDT_NPT.BeaconMinimap at module-load time (for Minimap.drawCurrentPullOutline).
    mocks.loadSource("Modules/BeaconMinimap.lua")
    mocks.loadSource("Modules/BeaconFrame.lua")
    BeaconFrame = _G.MDT_NPT.BeaconFrame
  end)

  local function makeFontString()
    local fs = {}
    function fs:SetText(t) self.text = t end
    function fs:SetTextColor(r, g, b, a) self.color = { r, g, b, a } end
    return fs
  end

  local function makeHeaderFrame()
    return {
      pullBadge = makeFontString(),
      statusText = makeFontString(),
    }
  end

  describe("renderPullHeader", function()
    it("formats the pull badge as 'Pull X / Total'", function()
      local frame = makeHeaderFrame()
      BeaconFrame.renderPullHeader(frame, 3, { state = "next" }, 10)
      assert.equals("Pull 3 / 10", frame.pullBadge.text)
    end)

    it("handles totals of 1 without special-casing", function()
      local frame = makeHeaderFrame()
      BeaconFrame.renderPullHeader(frame, 1, { state = "next" }, 1)
      assert.equals("Pull 1 / 1", frame.pullBadge.text)
    end)

    it("shows 'In Combat' in red when the pull is ACTIVE", function()
      local frame = makeHeaderFrame()
      BeaconFrame.renderPullHeader(frame, 2, { state = "active" }, 5)
      assert.equals("In Combat", frame.statusText.text)
      assert.same({ 1, 0.3, 0.3, 1 }, frame.statusText.color)
    end)

    it("shows 'Next' in green for any non-ACTIVE state", function()
      local frame = makeHeaderFrame()
      BeaconFrame.renderPullHeader(frame, 2, { state = "next" }, 5)
      assert.equals("Next", frame.statusText.text)
      local accent = _G.MDT_NPT.Theme.colors.accent
      assert.same(accent, frame.statusText.color)
    end)
  end)

  describe("isMouseOver", function()
    it("uses the region method without depending on the removed global helper", function()
      _G.MouseIsOver = nil
      assert.is_true(BeaconFrame.isMouseOver({ IsMouseOver = function() return true end }))
      assert.is_false(BeaconFrame.isMouseOver({ IsMouseOver = function() return false end }))
    end)

    it("returns false safely for objects without IsMouseOver", function()
      assert.is_false(BeaconFrame.isMouseOver({}))
      assert.is_false(BeaconFrame.isMouseOver(nil))
    end)
  end)
end)
