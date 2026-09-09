local mocks = require("wow_mocks")

---Two-enemy wave; enemies is keyed by MDT enemyIndex like the real dungeonEnemies.
local function makeEnemies()
  return {
    [7]  = { id = 101, name = "Alpha" },
    [17] = { id = 102, name = "Beta" },
    [23] = { id = 103, name = "Gamma" },
  }
end

describe("PullNotes — locate", function()
  local PullNotes

  before_each(function()
    mocks.reset()
    function _G.MDT_NPT:GetDB() return { pullNotes = {} } end
    mocks.loadSource("Modules/PullNotes.lua")
    PullNotes = _G.MDT_NPT.PullNotes
  end)

  it("returns uid and pullIndex from live state", function()
    local uid, idx = PullNotes.locate({ presetUID = "u1", currentNextPull = 4 })
    assert.equals("u1", uid)
    assert.equals(4, idx)
  end)

  it("returns nil when the preset uid is missing", function()
    assert.is_nil(PullNotes.locate({ currentNextPull = 4 }))
  end)

  it("returns nil for an empty-string uid", function()
    assert.is_nil((PullNotes.locate({ presetUID = "", currentNextPull = 4 })))
  end)

  it("returns nil when currentNextPull is not a number", function()
    assert.is_nil((PullNotes.locate({ presetUID = "u1", currentNextPull = nil })))
    assert.is_nil((PullNotes.locate({ presetUID = "u1", currentNextPull = "4" })))
  end)

  it("returns nil for a nil state", function()
    assert.is_nil((PullNotes.locate(nil)))
  end)
end)

describe("PullNotes — fingerprintOf", function()
  local PullNotes

  before_each(function()
    mocks.reset()
    function _G.MDT_NPT:GetDB() return { pullNotes = {} } end
    mocks.loadSource("Modules/PullNotes.lua")
    PullNotes = _G.MDT_NPT.PullNotes
  end)

  it("emits sorted enemyIndex:cloneCount pairs", function()
    local fp = PullNotes.fingerprintOf({ [17] = { 1, 2 }, [7] = { 5 } }, makeEnemies())
    assert.equals("17:2,7:1", fp)
  end)

  it("is stable regardless of pairs() traversal order", function()
    local a = PullNotes.fingerprintOf({ [7] = { 1 }, [17] = { 2, 3 } }, makeEnemies())
    local b = PullNotes.fingerprintOf({ [17] = { 2, 3 }, [7] = { 1 } }, makeEnemies())
    assert.equals(a, b)
  end)

  it("excludes ghost keys left behind by route edits", function()
    -- [23] is an MDT route-edit leftover: enemy key present, clone list empty.
    local clean = PullNotes.fingerprintOf({ [7] = { 1 }, [17] = { 2 } }, makeEnemies())
    local ghosted = PullNotes.fingerprintOf({ [7] = { 1 }, [17] = { 2 }, [23] = {} }, makeEnemies())
    assert.equals(clean, ghosted)
  end)

  it("accepts a numeric clone value", function()
    assert.equals("7:1", PullNotes.fingerprintOf({ [7] = 1 }, makeEnemies()))
  end)

  it("ignores indices absent from enemies", function()
    assert.equals("7:1", PullNotes.fingerprintOf({ [7] = { 1 }, [999] = { 2 } }, makeEnemies()))
  end)

  it("returns nil for a wave with no real content", function()
    assert.is_nil(PullNotes.fingerprintOf({ [23] = {} }, makeEnemies()))
    assert.is_nil(PullNotes.fingerprintOf({}, makeEnemies()))
  end)

  it("returns nil for a non-table pull", function()
    assert.is_nil(PullNotes.fingerprintOf(nil, makeEnemies()))
    assert.is_nil(PullNotes.fingerprintOf("nope", makeEnemies()))
  end)
end)

describe("PullNotes — get / set / clear", function()
  local PullNotes, mockDb

  before_each(function()
    mocks.reset()
    mockDb = { pullNotes = {} }
    function _G.MDT_NPT:GetDB() return mockDb end
    mocks.loadSource("Modules/PullNotes.lua")
    PullNotes = _G.MDT_NPT.PullNotes
  end)

  it("round-trips a note", function()
    assert.is_true(PullNotes.set("u1", 3, "先集火左边", { [7] = { 1 } }, makeEnemies()))
    assert.equals("先集火左边", (PullNotes.get("u1", 3)))
  end)

  it("snapshots the fingerprint on write", function()
    PullNotes.set("u1", 3, "x", { [7] = { 1, 2 } }, makeEnemies())
    assert.equals("7:2", mockDb.pullNotes["u1"][3].fingerprint)
  end)

  it("treats the empty string as a clear", function()
    PullNotes.set("u1", 3, "x", { [7] = { 1 } }, makeEnemies())
    PullNotes.set("u1", 3, "")
    assert.is_nil((PullNotes.get("u1", 3)))
  end)

  it("clear removes the record and its fingerprint", function()
    PullNotes.set("u1", 3, "x", { [7] = { 1 } }, makeEnemies())
    assert.is_true(PullNotes.clear("u1", 3))
    assert.is_nil(mockDb.pullNotes["u1"][3])
  end)

  it("lazily creates the pullNotes table when the db lacks it", function()
    mockDb.pullNotes = nil
    PullNotes.set("u1", 3, "hello", { [7] = { 1 } }, makeEnemies())
    assert.equals("hello", mockDb.pullNotes["u1"][3].text)
  end)

  it("scopes notes by uid", function()
    PullNotes.set("u1", 3, "route A", { [7] = { 1 } }, makeEnemies())
    PullNotes.set("u2", 3, "route B", { [7] = { 1 } }, makeEnemies())
    assert.equals("route A", (PullNotes.get("u1", 3)))
    assert.equals("route B", (PullNotes.get("u2", 3)))
  end)

  it("scopes notes by pullIndex", function()
    PullNotes.set("u1", 3, "wave three", { [7] = { 1 } }, makeEnemies())
    assert.is_nil((PullNotes.get("u1", 4)))
  end)

  it("degrades to a no-op for an invalid uid", function()
    assert.is_false(PullNotes.set(nil, 3, "x"))
    assert.is_false(PullNotes.set("", 3, "x"))
    assert.is_nil((PullNotes.get(nil, 3)))
    assert.has_no_errors(function() PullNotes.clear(nil, 3) end)
  end)

  it("degrades to a no-op for a non-numeric pullIndex", function()
    assert.is_false(PullNotes.set("u1", nil, "x"))
    assert.is_false(PullNotes.set("u1", "3", "x"))
  end)

  it("returns nil when the db is not ready", function()
    function _G.MDT_NPT:GetDB() return nil end
    assert.is_false(PullNotes.set("u1", 3, "x"))
    assert.is_nil((PullNotes.get("u1", 3)))
  end)
end)

describe("PullNotes — drift detection", function()
  local PullNotes

  before_each(function()
    mocks.reset()
    local mockDb = { pullNotes = {} }
    function _G.MDT_NPT:GetDB() return mockDb end
    mocks.loadSource("Modules/PullNotes.lua")
    PullNotes = _G.MDT_NPT.PullNotes
  end)

  it("reports matched while the wave content agrees", function()
    local wave = { [7] = { 1 }, [17] = { 2 } }
    PullNotes.set("u1", 3, "note", wave, makeEnemies())
    local text, matched = PullNotes.get("u1", 3, wave, makeEnemies())
    assert.equals("note", text)
    assert.is_true(matched)
  end)

  it("reports unmatched when a route edit shifted the wave under the note", function()
    -- Written against wave A at index 3...
    PullNotes.set("u1", 3, "note", { [7] = { 1 }, [17] = { 2 } }, makeEnemies())
    -- ...then a pull was inserted, so index 3 now holds a different wave.
    local text, matched = PullNotes.get("u1", 3, { [23] = { 9 } }, makeEnemies())
    assert.equals("note", text)
    assert.is_false(matched)
  end)

  it("reports unmatched when only the clone count changed", function()
    PullNotes.set("u1", 3, "note", { [7] = { 1 } }, makeEnemies())
    local _, matched = PullNotes.get("u1", 3, { [7] = { 1, 2 } }, makeEnemies())
    assert.is_false(matched)
  end)

  it("does not read ghost-key housekeeping as drift", function()
    -- The important one: MDT emptying a clone list must not flag the note.
    PullNotes.set("u1", 3, "note", { [7] = { 1 }, [17] = { 2 } }, makeEnemies())
    local text, matched =
      PullNotes.get("u1", 3, { [7] = { 1 }, [17] = { 2 }, [23] = {} }, makeEnemies())
    assert.equals("note", text)
    assert.is_true(matched)
  end)

  it("treats a missing stored fingerprint as matched", function()
    PullNotes.set("u1", 3, "note")  -- no pull/enemies -> fingerprint nil
    local text, matched = PullNotes.get("u1", 3, { [7] = { 1 } }, makeEnemies())
    assert.equals("note", text)
    assert.is_true(matched)
  end)

  it("treats an uncomputable live fingerprint as matched", function()
    PullNotes.set("u1", 3, "note", { [7] = { 1 } }, makeEnemies())
    local text, matched = PullNotes.get("u1", 3, {}, makeEnemies())
    assert.equals("note", text)
    assert.is_true(matched)
  end)

  it("skips the check when pull/enemies are omitted (popup prefill path)", function()
    PullNotes.set("u1", 3, "note", { [7] = { 1 } }, makeEnemies())
    local text, matched = PullNotes.get("u1", 3)
    assert.equals("note", text)
    assert.is_true(matched)
  end)
end)
