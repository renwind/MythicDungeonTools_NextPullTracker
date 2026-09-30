describe("MDTAdapter.lua", function()
  local function loadAdapter(namespace)
    local chunk = assert(loadfile("Modules/MDTAdapter.lua"))
    chunk("MythicDungeonTools_NextPullTracker", namespace)
    return namespace.MDT
  end

  before_each(function()
    _G.MythicDungeonToolsDB = nil
    _G.MythicDungeonToolsAPI = nil
    _G.C_AddOns = nil
    -- Other specs' wow_mocks install a global MDT stub; the first test below
    -- asserts the adapter neither reads nor creates that global, so start it
    -- from a known-nil state regardless of suite run order.
    _G.MDT = nil
  end)

  after_each(function()
    _G.MythicDungeonToolsDB = nil
    _G.MythicDungeonToolsAPI = nil
    _G.C_AddOns = nil
    _G.MDT = nil
  end)

  it("uses the public MDT database without relying on the removed global", function()
    local db = { currentDungeonIdx = 7, currentPreset = { [7] = 2 }, presets = { [7] = {} } }
    db.presets[7][2] = { uid = "route-7", value = { pulls = { {} } } }
    _G.MythicDungeonToolsAPI = { GetDB = function() return db end }

    local namespace = { L = {} }
    local adapter = loadAdapter(namespace)

    assert.is_nil(_G.MDT)
    assert.equals(db, adapter:GetDB())
    assert.equals("route-7", adapter:GetCurrentPreset().uid)
  end)

  it("falls back to MDT saved variables when the public API is unavailable", function()
    local db = { currentDungeonIdx = 3 }
    _G.MythicDungeonToolsDB = { global = db }

    local adapter = loadAdapter({ L = {} })
    assert.equals(db, adapter:GetDB())
  end)

  it("prefers the active AceDB table over MDT's stale bootstrap database", function()
    local bootstrapDB = { currentDungeonIdx = 1 }
    local activeDB = { currentDungeonIdx = 8, currentPreset = { [8] = 1 }, presets = { [8] = {} } }
    activeDB.presets[8][1] = { uid = "ace-route", value = { pulls = { {} } } }
    _G.MythicDungeonToolsAPI = { GetDB = function() return bootstrapDB end }
    _G.MythicDungeonToolsDB = { global = activeDB }

    local adapter = loadAdapter({ L = {} })
    assert.equals(activeDB, adapter:GetDB())
    assert.equals("ace-route", adapter:GetCurrentPreset().uid)
  end)

  it("ignores a defaults-only saved table and reads the live API database", function()
    -- 实测 6.2.20 主城：SavedVariables 那张表只剩赛季默认值（currentDungeonIdx=160、
    -- 无 presets），活表在 PublicAPI 后面；读错表会把选中副本读成默认副本。
    local staleDB = { currentDungeonIdx = 160, currentPreset = {} }
    local liveDB = { currentDungeonIdx = 161, currentPreset = { [161] = 1 }, presets = { [161] = {} } }
    liveDB.presets[161][1] = { uid = "live-route", value = { pulls = { {} } } }
    _G.MythicDungeonToolsAPI = { GetDB = function() return liveDB end }
    _G.MythicDungeonToolsDB = { global = staleDB }

    local adapter = loadAdapter({ L = {} })
    assert.equals(liveDB, adapter:GetDB())
    assert.equals("live-route", adapter:GetCurrentPreset().uid)
  end)

  it("updates the selected dungeon and initializes its preset selection", function()
    local db = { currentPreset = {}, presets = {} }
    _G.MythicDungeonToolsAPI = { GetDB = function() return db end }

    local adapter = loadAdapter({ L = {} })
    assert.is_true(adapter:UpdateToDungeon(42))
    assert.equals(42, db.currentDungeonIdx)
    assert.equals(1, db.currentPreset[42])
  end)

  it("returns nil safely when no preset is selected", function()
    _G.MythicDungeonToolsAPI = { GetDB = function() return {} end }
    local adapter = loadAdapter({ L = {} })
    assert.is_nil(adapter:GetCurrentPreset())
  end)

  it("loads MDT's UI addon before reading its presets", function()
    local uiLoaded = false
    local db = { currentDungeonIdx = 9, currentPreset = { [9] = 1 }, presets = { [9] = {} } }
    db.presets[9][1] = { uid = "loaded-route", value = { pulls = { {} } } }
    _G.MythicDungeonToolsAPI = { GetDB = function() return db end }
    _G.C_AddOns = {
      IsAddOnLoaded = function() return uiLoaded end,
      LoadAddOn = function(addonName)
        assert.equals("MythicDungeonTools_UI", addonName)
        uiLoaded = true
        return true
      end,
    }

    local adapter = loadAdapter({ L = {} })
    assert.equals("loaded-route", adapter:GetCurrentPreset().uid)
    assert.is_true(uiLoaded)
  end)

  it("accepts migrated string keys and skips MDT's empty new-preset entry", function()
    local db = {
      currentDungeonIdx = 12,
      currentPreset = { ["12"] = "2" },
      presets = { ["12"] = {
        ["1"] = { uid = "usable", value = { pulls = { {} } } },
        ["2"] = { value = 0 },
      } },
    }
    _G.MythicDungeonToolsDB = { global = db }

    local adapter = loadAdapter({ L = {} })
    assert.equals("usable", adapter:GetCurrentPreset().uid)
  end)

  it("reads a requested dungeon independently of MDT's current selection", function()
    local db = {
      currentDungeonIdx = 160,
      currentPreset = { [160] = 1, [161] = 2 },
      presets = {
        [160] = {
          [1] = { uid = "murder-route", value = { currentDungeonIdx = 160, pulls = { {} } } },
        },
        [161] = {
          [2] = { uid = "nalorakk-route", value = { currentDungeonIdx = 161, pulls = { {} } } },
        },
      },
    }
    _G.MythicDungeonToolsDB = { global = db }

    local adapter = loadAdapter({ L = {} })
    assert.equals("nalorakk-route", adapter:GetCurrentPreset(161).uid)
    assert.equals(160, db.currentDungeonIdx)
  end)

  it("maps registered zones onto their dungeon", function()
    local adapter = loadAdapter({ L = {} })
    adapter:RegisterDungeonLocation(153, { zoneIds = { 2424, 2511 }, subzoneAreaIDs = { 16814 } })

    assert.equals(153, adapter.zoneIdToDungeonIdx[2424])
    assert.equals(153, adapter.zoneIdToDungeonIdx[2511])
  end)

  it("keeps the first dungeon registered for a zone two dungeons share", function()
    local adapter = loadAdapter({ L = {} })
    adapter:RegisterDungeonLocation(161, { zoneIds = { 2437, 2513 } })
    adapter:RegisterDungeonLocation(157, { zoneIds = { 2437, 2501 } })

    assert.equals(161, adapter.zoneIdToDungeonIdx[2437])
    assert.equals(157, adapter.zoneIdToDungeonIdx[2501])
  end)

  -- MDT's Midnight data files are loaded into this namespace by the TOC and
  -- call RegisterDungeonLocation before registering enemy data. A missing
  -- method aborts the file, leaving dungeonEnemies empty so pull tracking
  -- reports "no pulls in current preset".
  it("lets an MDT dungeon data file finish loading in this namespace", function()
    local namespace = { L = {} }
    loadAdapter(namespace)

    local dataFile = assert((loadstring or load)([[
      local _, MDT = ...
      local dungeonIndex = 153
      MDT:RegisterDungeonLocation(dungeonIndex, { zoneIds = { 2424 } })
      MDT.dungeonTotalCount[dungeonIndex] = { normal = 585 }
      MDT.dungeonEnemies[dungeonIndex] = { [1] = { name = "Arcane Magister", count = 7 } }
    ]], "=midnightFixture"))
    dataFile("MythicDungeonTools", namespace)

    assert.equals(585, namespace.dungeonTotalCount[153].normal)
    assert.equals(7, namespace.dungeonEnemies[153][1].count)
    assert.equals(153, namespace.zoneIdToDungeonIdx[2424])
  end)
end)
