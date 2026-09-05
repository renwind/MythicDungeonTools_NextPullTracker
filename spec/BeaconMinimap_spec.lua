local mocks = require("wow_mocks")

describe("BeaconMinimap.lua", function()
  local Minimap

  before_each(function()
    mocks.reset()
    mocks.loadSource("Modules/Theme.lua")
    mocks.loadSource("Modules/BeaconMinimap.lua")
    Minimap = _G.MDT_NPT.BeaconMinimap
  end)

  describe("computeZoomScale", function()
    it("returns MIN_SCALE when bounds is nil", function()
      assert.equals(Minimap.MIN_SCALE, Minimap.computeZoomScale(nil))
    end)

    it("applies userMultiplier on top of MIN_SCALE when bounds is nil", function()
      -- Without a bbox, fit-scale is MIN_SCALE; user multiplier lifts it until clamped by MAX_SCALE.
      local scale = Minimap.computeZoomScale(nil, 2)
      assert.is_true(scale > Minimap.MIN_SCALE)
      assert.is_true(scale <= Minimap.MAX_SCALE)
      assert.equals(Minimap.MIN_SCALE * 2, scale)
    end)

    it("clamps the auto scale so single-enemy pulls don't fill the viewport", function()
      -- Degenerate bounds (point): bbox=0, would yield a huge fit-scale. Auto cap keeps it sane.
      local bounds = { minX = 100, maxX = 100, minY = 100, maxY = 100 }
      local scale = Minimap.computeZoomScale(bounds)
      assert.is_true(scale <= Minimap.MAX_SCALE)
      -- Without user override, a tiny bbox should sit at the auto cap, not at MAX_SCALE.
      assert.is_true(scale < Minimap.MAX_SCALE)
    end)

    it("lets the user zoom in beyond the auto cap via userMultiplier", function()
      local bounds = { minX = 100, maxX = 100, minY = 100, maxY = 100 }
      local auto = Minimap.computeZoomScale(bounds, 1)
      local zoomed = Minimap.computeZoomScale(bounds, 4)
      assert.is_true(zoomed > auto)
      assert.is_true(zoomed <= Minimap.MAX_SCALE)
    end)

    it("clamps the final scale to MAX_SCALE regardless of userMultiplier", function()
      local bounds = { minX = 0, maxX = 50, minY = 0, maxY = 50 }
      local absurd = Minimap.computeZoomScale(bounds, 1000)
      assert.equals(Minimap.MAX_SCALE, absurd)
    end)

    it("clamps the final scale to MIN_SCALE for huge pulls", function()
      local bounds = { minX = 0, maxX = 100000, minY = 0, maxY = 100000 }
      assert.equals(Minimap.MIN_SCALE, Minimap.computeZoomScale(bounds))
    end)

    it("never drops below MIN_SCALE even with a tiny userMultiplier", function()
      local bounds = { minX = 0, maxX = 100000, minY = 0, maxY = 100000 }
      assert.equals(Minimap.MIN_SCALE, Minimap.computeZoomScale(bounds, 0.01))
    end)

    it("treats userMultiplier=1 as a no-op equivalent to omitting the argument", function()
      local bounds = { minX = 0, maxX = 500, minY = 0, maxY = 500 }
      assert.equals(Minimap.computeZoomScale(bounds), Minimap.computeZoomScale(bounds, 1))
    end)
  end)

  describe("adjustUserZoom", function()
    it("initializes the multiplier to 1 then applies a single tick", function()
      local frame = {}
      Minimap.adjustUserZoom(frame, 1) -- wheel up = zoom in
      assert.is_true(frame.userZoomMultiplier > 1)
    end)

    it("multiplies by the same factor on wheel up and divides on wheel down (symmetric)", function()
      local frame = {}
      Minimap.adjustUserZoom(frame, 1)
      local up = frame.userZoomMultiplier
      Minimap.adjustUserZoom(frame, -1)
      -- One tick up followed by one tick down returns to 1 (within float epsilon).
      assert.is_true(math.abs(frame.userZoomMultiplier - 1) < 1e-9)
      -- And the up step alone was > 1.
      assert.is_true(up > 1)
    end)

    it("clamps at an upper bound so repeated wheel-up does not grow without limit", function()
      local frame = {}
      for _ = 1, 100 do Minimap.adjustUserZoom(frame, 1) end
      local capped = frame.userZoomMultiplier
      Minimap.adjustUserZoom(frame, 1)
      assert.equals(capped, frame.userZoomMultiplier)
    end)

    it("clamps at a lower bound so repeated wheel-down does not shrink to zero", function()
      local frame = {}
      for _ = 1, 100 do Minimap.adjustUserZoom(frame, -1) end
      local capped = frame.userZoomMultiplier
      assert.is_true(capped > 0)
      Minimap.adjustUserZoom(frame, -1)
      assert.equals(capped, frame.userZoomMultiplier)
    end)

    it("is a no-op on a nil frame (defensive)", function()
      assert.has_no.errors(function() Minimap.adjustUserZoom(nil, 1) end)
    end)
  end)

  describe("calculatePullBounds", function()
    local function enemiesFixture()
      return {
        [1] = {
          clones = {
            [1] = { x = 100, y = 200, sublevel = 1 },
            [2] = { x = 300, y = 400, sublevel = 1 },
            [3] = { x = 0,   y = 0,   sublevel = 2 }, -- wrong sublevel, should be ignored
          },
        },
        [2] = {
          clones = {
            [1] = { x = 200, y = 300, sublevel = 1 },
          },
        },
      }
    end

    it("returns nil when no enemies on this sublevel", function()
      local pull = { [1] = { 3 } } -- only the sublevel=2 clone
      assert.is_nil(Minimap.calculatePullBounds(pull, 1, enemiesFixture()))
    end)

    it("computes centroid and bbox across clones on the active sublevel", function()
      local pull = { [1] = { 1, 2 }, [2] = { 1 } }
      local b = Minimap.calculatePullBounds(pull, 1, enemiesFixture())
      assert.equals(100, b.minX)
      assert.equals(300, b.maxX)
      assert.equals(200, b.minY)
      assert.equals(400, b.maxY)
      -- centroid = mean of (100,200), (300,400), (200,300) = (200, 300)
      assert.equals(200, b.centroidX)
      assert.equals(300, b.centroidY)
    end)

    it("returns nil for an empty pull", function()
      assert.is_nil(Minimap.calculatePullBounds({}, 1, enemiesFixture()))
    end)
  end)

  describe("drawCurrentPullOutline", function()
    local function makeMockLine()
      local line = {}
      function line:SetThickness(t) self.thickness = t end
      function line:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
      function line:SetStartPoint(_, _, x, y) self.start = { x = x, y = y } end
      function line:SetEndPoint(_, _, x, y) self.finish = { x = x, y = y } end
      function line:Show() self.shown = true end
      function line:Hide() self.shown = false end
      return line
    end

    local function makeOutlineFrame(scale)
      local container = { lines = {} }
      function container:CreateLine(_, layer, _, subLayer)
        local line = makeMockLine()
        line.layer, line.subLayer = layer, subLayer
        self.lines[#self.lines + 1] = line
        return line
      end
      return { minimapContainer = container, minimapScale = scale or 0.5 }
    end

    local function shownLines(frame)
      local count = 0
      for _, line in ipairs(frame.minimapContainer.lines) do
        if line.shown then count = count + 1 end
      end
      return count
    end

    local enemies
    before_each(function()
      enemies = {
        [1] = {
          clones = {
            [1] = { x = 0,   y = 0,   sublevel = 1 },
            [2] = { x = 100, y = 0,   sublevel = 1 },
            [3] = { x = 50,  y = 100, sublevel = 1 },
            [4] = { x = 0,   y = 0,   sublevel = 2 }, -- wrong sublevel
          },
        },
      }
    end)

    it("creates no lines when pull is nil", function()
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, nil, 1, enemies, "next")
      assert.equals(0, #frame.minimapContainer.lines)
    end)

    it("creates no lines when enemies is nil", function()
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, { [1] = { 1, 2, 3 } }, 1, nil, "next")
      assert.equals(0, #frame.minimapContainer.lines)
    end)

    it("draws a closed polygon (>=3 visible segments) for a 3-enemy pull", function()
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, { [1] = { 1, 2, 3 } }, 1, enemies, "next")
      assert.is_true(shownLines(frame) >= 3)
    end)

    it("still draws a polygon for a single-enemy pull (via the halo)", function()
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, { [1] = { 1 } }, 1, enemies, "next")
      -- 1 enemy * 10 halo points -> hull is a 10-gon
      assert.is_true(shownLines(frame) >= 3)
    end)

    it("hides all lines when re-rendered with pull=nil", function()
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, { [1] = { 1, 2, 3 } }, 1, enemies, "next")
      assert.is_true(shownLines(frame) > 0)
      Minimap.drawCurrentPullOutline(frame, nil, 1, enemies, "next")
      assert.equals(0, shownLines(frame))
    end)

    it("filters enemies by sublevel (clone on another sublevel is ignored)", function()
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, { [1] = { 4 } }, 1, enemies, "next")
      assert.equals(0, #frame.minimapContainer.lines)
    end)

    it("reuses line objects across renders (pool does not grow)", function()
      local frame = makeOutlineFrame()
      local pull = { [1] = { 1, 2, 3 } }
      Minimap.drawCurrentPullOutline(frame, pull, 1, enemies, "next")
      local first = #frame.minimapContainer.lines
      Minimap.drawCurrentPullOutline(frame, pull, 1, enemies, "next")
      assert.equals(first, #frame.minimapContainer.lines)
    end)

    it("colors the outline green for pull state 'next'", function()
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, { [1] = { 1, 2, 3 } }, 1, enemies, "next")
      local accent = _G.MDT_NPT.Theme.colors.accent
      for _, line in ipairs(frame.minimapContainer.lines) do
        if line.shown then
          assert.same(accent, line.color)
        end
      end
    end)

    it("colors the outline orange for pull state 'active'", function()
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, { [1] = { 1, 2, 3 } }, 1, enemies, "active")
      for _, line in ipairs(frame.minimapContainer.lines) do
        if line.shown then
          assert.same({ 1, 0.5, 0, 1 }, line.color)
        end
      end
    end)

    it("colors the outline yellow for an unknown/upcoming pull state", function()
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, { [1] = { 1, 2, 3 } }, 1, enemies, nil)
      for _, line in ipairs(frame.minimapContainer.lines) do
        if line.shown then
          assert.same({ 1, 1, 0, 0.7 }, line.color)
        end
      end
    end)

    it("recolors on re-render when the pull state flips next -> active", function()
      local frame = makeOutlineFrame()
      local pull = { [1] = { 1, 2, 3 } }
      Minimap.drawCurrentPullOutline(frame, pull, 1, enemies, "next")
      Minimap.drawCurrentPullOutline(frame, pull, 1, enemies, "active")
      for _, line in ipairs(frame.minimapContainer.lines) do
        if line.shown then
          assert.same({ 1, 0.5, 0, 1 }, line.color)
        end
      end
    end)

    it("uses a custom outline color from the DB", function()
      _G.MDT_NPT.GetDB = function()
        return { beacon = { pullOutlineColors = { ["next"] = { 0.1, 0.2, 0.3, 0.4 } } } }
      end
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, { [1] = { 1, 2, 3 } }, 1, enemies, "next")
      for _, line in ipairs(frame.minimapContainer.lines) do
        if line.shown then
          assert.same({ 0.1, 0.2, 0.3, 0.4 }, line.color)
        end
      end
    end)

    it("colors the outline independently from the dots", function()
      _G.MDT_NPT.GetDB = function()
        return {
          beacon = {
            pullColors = { ["next"] = { 1, 0, 0, 1 } },        -- dots red
            pullOutlineColors = { ["next"] = { 0, 0, 1, 1 } }, -- outline blue
          },
        }
      end
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, { [1] = { 1, 2, 3 } }, 1, enemies, "next")
      for _, line in ipairs(frame.minimapContainer.lines) do
        if line.shown then
          assert.same({ 0, 0, 1, 1 }, line.color) -- the outline color, not the dot color
        end
      end
    end)

    it("falls back to the dot color when the state has no dedicated outline color", function()
      _G.MDT_NPT.GetDB = function()
        return { beacon = { pullColors = { ["completed"] = { 0.2, 0.2, 0.2, 0.5 } } } }
      end
      local frame = makeOutlineFrame()
      Minimap.drawCurrentPullOutline(frame, { [1] = { 1, 2, 3 } }, 1, enemies, "completed")
      for _, line in ipairs(frame.minimapContainer.lines) do
        if line.shown then
          assert.same({ 0.2, 0.2, 0.2, 0.5 }, line.color)
        end
      end
    end)
  end)

  describe("updateMinimapDots", function()
    local function makeDotFrame(scale)
      local container = {}
      function container:CreateTexture()
        local dot = {}
        function dot:SetTexture() end
        function dot:SetVertexColor(r, g, b, a) self.color = { r, g, b, a } end
        function dot:SetPoint() end
        function dot:SetSize() end
        function dot:ClearAllPoints() end
        function dot:Show() self.shown = true end
        function dot:Hide() self.shown = false end
        return dot
      end
      return { minimapContainer = container, minimapScale = scale or 0.5, dots = {} }
    end

    local enemies, pulls, state
    before_each(function()
      enemies = { [1] = { clones = { [1] = { x = 0, y = 0, sublevel = 1 } } } }
      pulls = { [1] = { [1] = { 1 } } }
      state = { currentNextPull = 1, pullStates = { [1] = { state = "next" } } }
    end)

    it("colors dots with the default palette", function()
      local frame = makeDotFrame()
      Minimap.updateMinimapDots(frame, state, pulls, enemies, 1)
      local accent = _G.MDT_NPT.Theme.colors.accent
      local shown = 0
      for _, dot in ipairs(frame.dots) do
        if dot.shown then
          shown = shown + 1
          assert.same(accent, dot.color)
        end
      end
      assert.is_true(shown > 0)
    end)

    it("uses a custom dot color from the DB", function()
      _G.MDT_NPT.GetDB = function()
        return { beacon = { pullColors = { ["next"] = { 0.9, 0.8, 0.7, 0.6 } } } }
      end
      local frame = makeDotFrame()
      Minimap.updateMinimapDots(frame, state, pulls, enemies, 1)
      for _, dot in ipairs(frame.dots) do
        if dot.shown then
          assert.same({ 0.9, 0.8, 0.7, 0.6 }, dot.color)
        end
      end
    end)

    it("does not show monsters outside the route when the option is disabled", function()
      enemies[1].clones[2] = { x = 10, y = 20, sublevel = 1 }
      local frame = makeDotFrame()
      Minimap.updateMinimapDots(frame, state, pulls, enemies, 1)
      local shown = 0
      for _, dot in ipairs(frame.dots) do if dot.shown then shown = shown + 1 end end
      assert.equals(1, shown)
    end)

    it("shows only monsters absent from the whole route in light gray", function()
      enemies[1].clones[2] = { x = 10, y = 20, sublevel = 1 }
      enemies[1].clones[3] = { x = 30, y = 40, sublevel = 2 }
      pulls[2] = { [1] = { 3 } } -- selected elsewhere in the route, and on another floor
      _G.MDT_NPT.GetDB = function()
        return { beacon = { showUnselected = true } }
      end
      local frame = makeDotFrame()
      Minimap.updateMinimapDots(frame, state, pulls, enemies, 1)
      local colors = {}
      for _, dot in ipairs(frame.dots) do
        if dot.shown then colors[#colors + 1] = dot.color end
      end
      assert.equals(2, #colors) -- one off-route clone plus the current route clone
      assert.same({ 0.75, 0.75, 0.75, 0.7 }, colors[1])
      local accent = _G.MDT_NPT.Theme.colors.accent
      assert.same(accent, colors[2])
    end)

    it("uses the configured color for monsters outside the route", function()
      enemies[1].clones[2] = { x = 10, y = 20, sublevel = 1 }
      _G.MDT_NPT.GetDB = function()
        return {
          beacon = {
            showUnselected = true,
            pullColors = { unselected = { 0.1, 0.2, 0.3, 0.4 } },
          },
        }
      end
      local frame = makeDotFrame()
      Minimap.updateMinimapDots(frame, state, pulls, enemies, 1)
      assert.same({ 0.1, 0.2, 0.3, 0.4 }, frame.dots[1].color)
    end)
  end)
end)
