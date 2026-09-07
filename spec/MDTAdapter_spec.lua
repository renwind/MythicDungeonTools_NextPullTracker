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
end)
