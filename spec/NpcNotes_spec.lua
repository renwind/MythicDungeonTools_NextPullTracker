local mocks = require("wow_mocks")

-- Helper: minimal StaticPopup editBox mock recording text operations.
local function makeEditBox()
  local eb = { text = "", focusCount = 0, highlightCount = 0 }
  function eb:SetText(t) eb.text = t end
  function eb:GetText() return eb.text end
  function eb:SetFocus() eb.focusCount = eb.focusCount + 1 end
  function eb:HighlightText() eb.highlightCount = eb.highlightCount + 1 end
  return eb
end

describe("NpcNotes — keyFor", function()
  local NpcNotes

  before_each(function()
    mocks.reset()
    function _G.MDT_NPT:GetDB() return { npcNotes = {} } end
    mocks.loadSource("Modules/NpcNotes.lua")
    NpcNotes = _G.MDT_NPT.NpcNotes
  end)

  it("keys by NPC id when present", function()
    assert.equals("npc:184122", NpcNotes.keyFor({ id = 184122 }))
  end)

  it("falls back to a name key when the id is missing", function()
    assert.equals("name:Voidweaver", NpcNotes.keyFor({ name = "Voidweaver" }))
  end)

  it("returns nil when neither id nor name exists", function()
    assert.is_nil(NpcNotes.keyFor({ level = 91 }))
  end)

  it("string-typed ids hash the same as numeric ids", function()
    assert.equals(NpcNotes.keyFor({ id = 184122 }), NpcNotes.keyFor({ id = "184122" }))
  end)

  it("prefers the id over the name when both exist", function()
    assert.equals("npc:7", NpcNotes.keyFor({ id = 7, name = "Foo" }))
  end)

  it("returns nil for non-table enemies", function()
    assert.is_nil(NpcNotes.keyFor(nil))
    assert.is_nil(NpcNotes.keyFor("Bristlecone"))
  end)
end)

describe("NpcNotes — get / set / clear", function()
  local NpcNotes
  local mockDb

  before_each(function()
    mocks.reset()
    mockDb = { npcNotes = {} }
    function _G.MDT_NPT:GetDB() return mockDb end
    mocks.loadSource("Modules/NpcNotes.lua")
    NpcNotes = _G.MDT_NPT.NpcNotes
  end)

  it("round-trips a note through set/get", function()
    NpcNotes.set("npc:1", "prioritize interrupt")
    assert.equals("prioritize interrupt", NpcNotes.get("npc:1"))
  end)

  it("stores colour escapes verbatim (no sanitising)", function()
    NpcNotes.set("npc:1", "|cffff4040优先打断|r")
    assert.equals("|cffff4040优先打断|r", NpcNotes.get("npc:1"))
  end)

  it("clear removes the note", function()
    NpcNotes.set("npc:1", "x")
    NpcNotes.clear("npc:1")
    assert.is_nil(NpcNotes.get("npc:1"))
  end)

  it("treats an empty string as a clear", function()
    NpcNotes.set("npc:1", "")
    assert.is_nil(NpcNotes.get("npc:1"))
  end)

  it("keeps whitespace-only notes as-is (no trim)", function()
    NpcNotes.set("npc:1", "  ")
    assert.equals("  ", NpcNotes.get("npc:1"))
  end)

  it("is a no-op when the db is not ready", function()
    function _G.MDT_NPT:GetDB() return nil end
    assert.is_nil(NpcNotes.get("npc:1"))
    assert.has_no_errors(function() NpcNotes.set("npc:1", "x") end)
    assert.has_no_errors(function() NpcNotes.clear("npc:1") end)
  end)

  it("lazily creates the npcNotes table when the db lacks it", function()
    mockDb.npcNotes = nil
    NpcNotes.set("npc:1", "hello")
    assert.equals("hello", mockDb.npcNotes["npc:1"])
  end)

  it("ignores non-string keys", function()
    assert.has_no_errors(function() NpcNotes.set(42, "x") end)
    assert.is_nil(NpcNotes.get(42))
  end)
end)

describe("NpcNotes — collectForPull", function()
  local NpcNotes
  local mockDb

  local function makeEnemies()
    return {
      [2]  = { id = 101, name = "Alpha", displayId = 111 },
      [7]  = { id = 102, name = "Beta", displayId = 222 },
      [17] = { id = 103, name = "Gamma" },          -- no displayId -> default
      [30] = { id = 104, name = "Delta", displayId = 444 },
      [31] = { name = "NoId" },                     -- name-only key
      [32] = { level = 90 },                        -- no key at all
    }
  end

  before_each(function()
    mocks.reset()
    mockDb = { npcNotes = {} }
    function _G.MDT_NPT:GetDB() return mockDb end
    mocks.loadSource("Modules/NpcNotes.lua")
    NpcNotes = _G.MDT_NPT.NpcNotes
  end)

  it("returns only enemies that have a note", function()
    mockDb.npcNotes["npc:102"] = "note for beta"
    local items = NpcNotes.collectForPull({ [2] = 1, [7] = 1, [17] = 1 }, makeEnemies())
    assert.equals(1, #items)
    assert.equals("npc:102", items[1].key)
    assert.equals("Beta", items[1].rawName)
    assert.equals(222, items[1].displayId)
    assert.equals("note for beta", items[1].note)
  end)

  it("sorts entries by enemyIndex ascending regardless of pull key order", function()
    mockDb.npcNotes["npc:101"] = "a"
    mockDb.npcNotes["npc:103"] = "c"
    mockDb.npcNotes["npc:104"] = "d"
    local items = NpcNotes.collectForPull({ [17] = 1, [2] = 1, [30] = 1 }, makeEnemies())
    assert.equals(3, #items)
    assert.equals("npc:101", items[1].key)
    assert.equals("npc:103", items[2].key)
    assert.equals("npc:104", items[3].key)
  end)

  it("is stable across repeated calls on the same pull", function()
    mockDb.npcNotes["npc:101"] = "a"
    mockDb.npcNotes["npc:102"] = "b"
    mockDb.npcNotes["npc:103"] = "c"
    mockDb.npcNotes["npc:104"] = "d"
    local pull = { [17] = 1, [2] = 1, [30] = 1, [7] = 1 }
    local first = NpcNotes.collectForPull(pull, makeEnemies())
    for _ = 1, 5 do
      local again = NpcNotes.collectForPull(pull, makeEnemies())
      for i = 1, #first do
        assert.equals(first[i].key, again[i].key)
      end
    end
  end)

  it("caps the result at 8 entries, keeping the lowest indices", function()
    local enemies, pull = {}, {}
    for i = 1, 10 do
      enemies[i] = { id = 1000 + i, name = "Mob" .. i }
      pull[i] = 1
      mockDb.npcNotes["npc:" .. (1000 + i)] = "note " .. i
    end
    local items = NpcNotes.collectForPull(pull, enemies)
    assert.equals(8, #items)
    assert.equals("npc:1001", items[1].key)
    assert.equals("npc:1008", items[8].key)
  end)

  it("skips enemies without a usable key", function()
    mockDb.npcNotes["name:NoId"] = "name keyed"
    local items = NpcNotes.collectForPull({ [31] = 1, [32] = 1 }, makeEnemies())
    assert.equals(1, #items)
    assert.equals("name:NoId", items[1].key)
  end)

  it("deduplicates identical keys (same npc cloned in one pull)", function()
    local enemies = { [1] = { id = 7, name = "Clone" }, [2] = { id = 7, name = "Clone" } }
    mockDb.npcNotes["npc:7"] = "shared note"
    local items = NpcNotes.collectForPull({ [1] = 1, [2] = 1 }, enemies)
    assert.equals(1, #items)
    assert.equals("shared note", items[1].note)
  end)

  it("defaults displayId to 39490 when the enemy has none", function()
    mockDb.npcNotes["npc:103"] = "x"
    local items = NpcNotes.collectForPull({ [17] = 1 }, makeEnemies())
    assert.equals(39490, items[1].displayId)
  end)

  it("returns an empty table when pull or enemies is nil", function()
    assert.same({}, NpcNotes.collectForPull(nil, makeEnemies()))
    assert.same({}, NpcNotes.collectForPull({ [2] = 1 }, nil))
    assert.same({}, NpcNotes.collectForPull(nil, nil))
  end)

  it("returns an empty table when the db is not ready", function()
    function _G.MDT_NPT:GetDB() return nil end
    local items = NpcNotes.collectForPull({ [2] = 1 }, makeEnemies())
    assert.same({}, items)
  end)
end)

describe("NpcNotes — truncate (escape-aware)", function()
  local NpcNotes

  before_each(function()
    mocks.reset()
    function _G.MDT_NPT:GetDB() return { npcNotes = {} } end
    mocks.loadSource("Modules/NpcNotes.lua")
    NpcNotes = _G.MDT_NPT.NpcNotes
  end)

  it("returns the empty string for nil text", function()
    assert.equals("", NpcNotes.truncate(nil, 5))
  end)

  it("returns the text unchanged when it fits", function()
    local s = "一二三"
    assert.equals(s, NpcNotes.truncate(s, 5))
  end)

  it("keeps the head and appends an ellipsis on overflow", function()
    assert.equals("一二三…", NpcNotes.truncate("一二三四五", 3))
  end)

  it("counts visible glyphs, not escape sequences", function()
    local s = "|cffff4040红|r黑"
    assert.equals(s, NpcNotes.truncate(s, 2)) -- 红 + 黑 = 2 visible glyphs
  end)

  it("closes an open colour before the ellipsis when truncating inside a |c segment", function()
    assert.equals("|cffff4040优先打断|r…", NpcNotes.truncate("|cffff4040优先打断法师|r", 4))
  end)

  it("does not append a stray |r when the colour is already closed", function()
    assert.equals("黑|cffff4040红红|r…", NpcNotes.truncate("黑|cffff4040红红红红|r尾", 3))
  end)

  it("never splits a |cXXXXXXXX sequence across the cut", function()
    local out = NpcNotes.truncate("一|cffff0000二三四", 3)
    assert.not_equals("|", out:sub(2, 2)) -- the |c sequence stays atomic
    assert.truthy(out:find("|cffff0000", 1, true))
    assert.equals("一|cffff0000二三|r…", out)
    assert.equals("…", out:sub(-3))
  end)

  it("never splits a |T...|t icon sequence across the cut", function()
    local icon = "|TInterface\\Icons\\INV_Misc_QuestionMark:22:22|t"
    local out = NpcNotes.truncate("一" .. icon .. "二三四", 3)
    assert.truthy(out:find(icon, 1, true))
    assert.equals("一" .. icon .. "二三…", out)
  end)

  it("never splits a |A...|a atlas sequence across the cut", function()
    local atlas = "|Apoi-genericalert:22:22|a"
    local out = NpcNotes.truncate("一" .. atlas .. "二三四", 3)
    assert.truthy(out:find(atlas, 1, true))
    assert.equals("一" .. atlas .. "二三…", out)
  end)

  it("never splits |r across the cut", function()
    local out = NpcNotes.truncate("|cffff4040一|r二三四", 3)
    assert.truthy(out:find("|r", 1, true))
  end)

  it("folds |n into a space and counts it as one visible glyph", function()
    assert.equals("一 …", NpcNotes.truncate("一|n二|n三", 2))
  end)

  it("leaves a fitting |n intact (no folding when untruncated)", function()
    local s = "一|n二"
    assert.equals(s, NpcNotes.truncate(s, 3))
  end)

  it("treats a lone | as a plain glyph", function()
    assert.equals("一|…", NpcNotes.truncate("一|二三", 2))
  end)
end)

describe("Core.lua — MDT_NPT_NPC_NOTE popup", function()
  local NpcNotes
  local mockDb
  local beaconUpdates
  local editBox

  local function fireOnEvent(eventFrame, event, ...)
    eventFrame._scripts.OnEvent(eventFrame, event, ...)
  end

  before_each(function()
    mocks.reset()

    -- Frames: capture every CreateFrame so the test can fire events on the first one.
    local frames = {}
    _G.CreateFrame = function()
      local f = { _scripts = {}, _events = {} }
      function f:SetScript(n, fn) f._scripts[n] = fn end
      function f:RegisterEvent(e) f._events[e] = true end
      function f:UnregisterEvent(e) f._events[e] = nil end
      table.insert(frames, f)
      return f
    end

    -- AceDB via LibStub: hand Core.lua a pre-built db/dbChar.
    mockDb = {
      enabled = true,
      autoStartInKey = false,
      beacon = { enabled = true, showForNonTank = false, askOnStart = true },
      npcNotes = {},
    }
    _G.LibStub = function()
      return { New = function() return { global = mockDb, char = { beacon = {} } } end }
    end

    _G.StaticPopupDialogs = {}
    _G.YES = "Yes"
    _G.NO = "No"
    _G.CANCEL = "Cancel"

    _G.C_Timer = { After = function() end }

    _G.GetSpecialization = function() return 1 end
    _G.GetSpecializationRole = function() return "DAMAGER" end
    mocks.loadSource("Utils/Wow.lua")

    _G.MDT_NPT.State = { buildStateFromPreset = function() return nil end }
    _G.MDT_NPT.Scenario = {}
    _G.MDT_NPT.Mdt = { syncMDTDungeonToPlayerZone = function() end }
    beaconUpdates = 0
    _G.MDT_NPT.Beacon = { Update = function() beaconUpdates = beaconUpdates + 1 end }

    _G.print = function() end

    -- Load the real NpcNotes module first so Core.lua captures it as an upvalue.
    mocks.loadSource("Modules/NpcNotes.lua")
    NpcNotes = _G.MDT_NPT.NpcNotes

    local chunk = assert(loadfile("Core.lua"))
    chunk("MythicDungeonTools_NextPullTracker")

    fireOnEvent(frames[1], "ADDON_LOADED", "MythicDungeonTools_NextPullTracker")
  end)

  it("registers the popup with three buttons and an edit box", function()
    local popup = _G.StaticPopupDialogs["MDT_NPT_NPC_NOTE"]
    assert.is_not_nil(popup)
    assert.is_string(popup.text)
    assert.is_string(popup.button1)
    assert.is_string(popup.button2)
    assert.is_string(popup.button3)
    assert.is_true(popup.hasEditBox)
    assert.is_true(popup.hideOnEscape)
    assert.is_true(popup.whileDead)
    assert.is_function(popup.OnShow)
    assert.is_function(popup.OnAccept)
    assert.is_function(popup.OnAlt)
    assert.is_function(popup.EditBoxOnEnterPressed)
  end)

  it("OnShow prefills the edit box with the stored note and focuses it", function()
    mockDb.npcNotes["npc:184122"] = "会施放束缚之网，优先打断"
    editBox = makeEditBox()
    local dialog = { text_arg1 = "虚空织网者", text_arg2 = "npc:184122", editBox = editBox }
    _G.StaticPopupDialogs["MDT_NPT_NPC_NOTE"].OnShow(dialog)
    assert.equals("会施放束缚之网，优先打断", editBox.text)
    assert.equals(1, editBox.focusCount)
    assert.equals(1, editBox.highlightCount)
  end)

  it("OnAccept saves the edited text and refreshes the beacon", function()
    editBox = makeEditBox()
    editBox:SetText("|cffff4040优先打断|r")
    local dialog = { text_arg1 = "虚空织网者", text_arg2 = "npc:184122", editBox = editBox }
    _G.StaticPopupDialogs["MDT_NPT_NPC_NOTE"].OnAccept(dialog)
    assert.equals("|cffff4040优先打断|r", mockDb.npcNotes["npc:184122"])
    assert.equals(1, beaconUpdates)
  end)

  it("OnAccept with an empty string clears the note (set semantics)", function()
    mockDb.npcNotes["npc:184122"] = "old"
    editBox = makeEditBox()
    editBox:SetText("")
    local dialog = { text_arg1 = "虚空织网者", text_arg2 = "npc:184122", editBox = editBox }
    _G.StaticPopupDialogs["MDT_NPT_NPC_NOTE"].OnAccept(dialog)
    assert.is_nil(mockDb.npcNotes["npc:184122"])
    assert.equals(1, beaconUpdates)
  end)

  it("OnAlt clears the stored note and refreshes the beacon", function()
    mockDb.npcNotes["npc:184122"] = "old"
    local dialog = { text_arg1 = "虚空织网者", text_arg2 = "npc:184122", editBox = makeEditBox() }
    _G.StaticPopupDialogs["MDT_NPT_NPC_NOTE"].OnAlt(dialog)
    assert.is_nil(mockDb.npcNotes["npc:184122"])
    assert.equals(1, beaconUpdates)
  end)
end)
