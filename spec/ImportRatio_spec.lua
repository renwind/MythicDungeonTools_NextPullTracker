local mocks = require("wow_mocks")

local function presetWith(pulls, uid)
  return {
    uid = uid == nil and "uid1" or uid,
    value = { currentDungeonIdx = 1, currentSublevel = 1, currentPull = 1, pulls = pulls },
  }
end

local function enemiesFor(...)
  local enemies = {}
  for n = 1, select("#", ...) do
    local pull = select(n, ...)
    for idx in pairs(pull or {}) do enemies[idx] = { clones = {} } end
  end
  return enemies
end

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    env.dbChar.rotationRatios = {}
    mocks.loadSource("Modules/CooldownData.lua")
    mocks.loadSource("Modules/ImportPlan.lua")
    mocks.loadSource("Modules/SpellRatioData.lua")
    mocks.loadSource("Modules/ImportRatio.lua")
    fn(env)
  end)
end

local function capturePrint(fn)
  local originalPrint = _G.print
  local messages = {}
  _G.print = function(message) messages[#messages + 1] = tostring(message) end
  local ok, err = pcall(fn)
  _G.print = originalPrint
  if not ok then error(err, 0) end
  return messages
end

local function assertContains(text, expected)
  assert.is_truthy(text and text:find(expected, 1, true), tostring(text))
end

describe("ImportRatio parsePack", function()
  before_each(function() mocks.reset() end)

  it("decodes lowercase base36 pairs and assigns waves by token order", function()
    scenario(function()
      local rows, err = MDT_NPT.ImportRatio.parsePack("0.q,1.16")
      assert.is_nil(err)
      assert.equals(2, #rows)
      assert.same({ wave = 1, elementalBlast = 0, earthquake = 26 }, rows[1])
      assert.same({ wave = 2, elementalBlast = 1, earthquake = 42 }, rows[2])
    end)
  end)

  it("rejects empty tokens, wrong separators, uppercase and malformed pairs", function()
    scenario(function()
      local bad = {
        "", ".", "0", ".1", "1.", "0.q!", "-1.2", "1.-2", "A.1", "1.Z",
        ",0.q", "0.q,", "0.q,,1.16", "0.q;1.16", "0:q", "0.1.2", "0 .q", "0.q ",
      }
      for _, pack in ipairs(bad) do
        local rows, err = MDT_NPT.ImportRatio.parsePack(pack)
        assert.is_nil(rows, "should reject: " .. pack)
        assert.is_string(err)
      end
    end)
  end)

  it("accepts Number.MAX_SAFE_INTEGER and rejects longer or overflowing base36 values", function()
    scenario(function()
      local rows, err = MDT_NPT.ImportRatio.parsePack("2gosa7pa2gv.0")
      assert.is_nil(err)
      assert.equals(9007199254740991, rows[1].elementalBlast)

      for _, pack in ipairs({
        "2gosa7pa2gw.0",
        string.rep("z", 400) .. ".0",
        "0." .. string.rep("z", 400),
      }) do
        local rejected, rejectErr = MDT_NPT.ImportRatio.parsePack(pack)
        assert.is_nil(rejected)
        assert.is_string(rejectErr)
      end
    end)
  end)
end)

describe("ImportRatio applyPack", function()
  before_each(function() mocks.reset() end)

  it("replaces exactly once with every route wave and its pull fingerprint", function()
    scenario(function()
      local pulls = { { [3] = { 1 } }, { [5] = { 1, 2 } } }
      local preset = presetWith(pulls)
      MDT.GetCurrentPreset = function() return preset end
      MDT.dungeonEnemies = { [1] = enemiesFor(pulls[1], pulls[2]) }
      local key = MDT_NPT.ImportPlan.computeRouteKey(pulls)
      local replaceCalls = 0
      local realReplaceRoute = MDT_NPT.SpellRatioData.ReplaceRoute
      MDT_NPT.SpellRatioData.ReplaceRoute = function(self, uid, rows)
        replaceCalls = replaceCalls + 1
        return realReplaceRoute(self, uid, rows)
      end

      local ok, err, count = MDT_NPT.ImportRatio:applyPack("0.q,1.16", key)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.equals(2, count)
      assert.equals(1, replaceCalls)
      assert.same({ elementalBlast = 0, earthquake = 26, fingerprint = "3:1" },
        MDT_NPT.SpellRatioData:Get("uid1", 1))
      assert.same({ elementalBlast = 1, earthquake = 42, fingerprint = "5:2" },
        MDT_NPT.SpellRatioData:Get("uid1", 2))
    end)
  end)

  it("requires exactly one ordered token per pull without changing old route data", function()
    scenario(function(env)
      local pulls = { { [3] = { 1 } }, { [5] = { 1 } } }
      MDT.GetCurrentPreset = function() return presetWith(pulls) end
      MDT.dungeonEnemies = { [1] = enemiesFor(pulls[1], pulls[2]) }
      local key = MDT_NPT.ImportPlan.computeRouteKey(pulls)
      assert.is_true(MDT_NPT.SpellRatioData:Set("uid1", 9, 7, 8, "old"))
      local oldRoute = env.dbChar.rotationRatios.uid1

      local shortOK, shortErr = MDT_NPT.ImportRatio:applyPack("1.2", key)
      assert.is_false(shortOK)
      assertContains(shortErr, "token count")
      assert.equals(oldRoute, env.dbChar.rotationRatios.uid1)

      local longOK, longErr = MDT_NPT.ImportRatio:applyPack("1.2,2.1,3.0", key)
      assert.is_false(longOK)
      assertContains(longErr, "token count")
      assert.equals(oldRoute, env.dbChar.rotationRatios.uid1)
      assert.same({ elementalBlast = 7, earthquake = 8, fingerprint = "old" },
        MDT_NPT.SpellRatioData:Get("uid1", 9))
    end)
  end)

  it("rejects route key mismatch atomically", function()
    scenario(function(env)
      local pulls = { { [3] = { 1 } } }
      MDT.GetCurrentPreset = function() return presetWith(pulls) end
      MDT.dungeonEnemies = { [1] = enemiesFor(pulls[1]) }
      assert.is_true(MDT_NPT.SpellRatioData:Set("uid1", 1, 7, 8, "old"))
      local oldRoute = env.dbChar.rotationRatios.uid1

      local ok, err = MDT_NPT.ImportRatio:applyPack("1.2", "deadbeef")

      assert.is_false(ok)
      assertContains(err, "route key mismatch")
      assert.equals(oldRoute, env.dbChar.rotationRatios.uid1)
    end)
  end)

  it("rejects absent preset, invalid uid, and missing pulls", function()
    scenario(function()
      MDT.GetCurrentPreset = nil
      local noPreset, noPresetErr = MDT_NPT.ImportRatio:applyPack("1.2", "deadbeef")
      assert.is_false(noPreset)
      assertContains(noPresetErr, "no current preset")

      MDT.GetCurrentPreset = function() return presetWith({ { [1] = { 1 } } }, "") end
      local noUID, noUIDErr = MDT_NPT.ImportRatio:applyPack("1.2", "deadbeef")
      assert.is_false(noUID)
      assertContains(noUIDErr, "no current preset uid")

      MDT.GetCurrentPreset = function() return { uid = "uid1", value = {} } end
      local noPulls, noPullsErr = MDT_NPT.ImportRatio:applyPack("1.2", "deadbeef")
      assert.is_false(noPulls)
      assertContains(noPullsErr, "no pulls")
    end)
  end)

  it("does not replace old data when parsing fails or storage rejects replacement", function()
    scenario(function(env)
      local pulls = { { [3] = { 1 } } }
      MDT.GetCurrentPreset = function() return presetWith(pulls) end
      MDT.dungeonEnemies = { [1] = enemiesFor(pulls[1]) }
      local key = MDT_NPT.ImportPlan.computeRouteKey(pulls)
      assert.is_true(MDT_NPT.SpellRatioData:Set("uid1", 1, 7, 8, "old"))
      local oldRoute = env.dbChar.rotationRatios.uid1
      local replaceCalls = 0
      MDT_NPT.SpellRatioData.ReplaceRoute = function()
        replaceCalls = replaceCalls + 1
        return false
      end

      local parseOK = MDT_NPT.ImportRatio:applyPack("1.2!", key)
      assert.is_false(parseOK)
      assert.equals(0, replaceCalls)
      assert.equals(oldRoute, env.dbChar.rotationRatios.uid1)

      local storageOK, storageErr = MDT_NPT.ImportRatio:applyPack("1.2", key)
      assert.is_false(storageOK)
      assertContains(storageErr, "storage")
      assert.equals(1, replaceCalls)
      assert.equals(oldRoute, env.dbChar.rotationRatios.uid1)
    end)
  end)
end)

describe("Slash dispatch importratiopack", function()
  before_each(function() mocks.reset() end)

  it("late-dereferences ImportRatio, imports the pack, updates the orb, and reports the wave count", function()
    scenario(function()
      local pulls = { { [3] = { 1, 2 } } }
      MDT.GetCurrentPreset = function() return presetWith(pulls) end
      MDT.dungeonEnemies = { [1] = enemiesFor(pulls[1]) }
      local key = MDT_NPT.ImportPlan.computeRouteKey(pulls)
      local importRatio = MDT_NPT.ImportRatio
      MDT_NPT.ImportRatio = nil
      SlashCmdList = {}
      mocks.loadSource("Modules/Slash.lua")
      MDT_NPT.ImportRatio = importRatio
      local updateCalls = 0
      MDT_NPT.SpellRatioOrb = {
        Update = function(self)
          assert.equals(MDT_NPT.SpellRatioOrb, self)
          updateCalls = updateCalls + 1
        end,
      }

      local messages = capturePrint(function()
        MDT_NPT:Slash("importratiopack " .. key .. " 8.2")
      end)

      assert.equals(8, MDT_NPT.SpellRatioData:Get("uid1", 1).elementalBlast)
      assert.equals(1, updateCalls)
      assert.equals(1, #messages)
      assertContains(messages[1], "imported spell ratios for 1 pulls")
    end)
  end)

  it("prints usage for missing or extra arguments without invoking the importer", function()
    scenario(function()
      SlashCmdList = {}
      mocks.loadSource("Modules/Slash.lua")
      local calls = 0
      MDT_NPT.ImportRatio = {
        applyPack = function()
          calls = calls + 1
          return true, nil, 1
        end,
      }

      local messages = capturePrint(function()
        MDT_NPT:Slash("importratiopack")
        MDT_NPT:Slash("importratiopack deadbeef 1.2 extra")
      end)
      local helpMessages = capturePrint(function()
        MDT_NPT:Slash("help")
      end)
      local ratioHelp
      for _, message in ipairs(helpMessages) do
        if message:find("/npt importratiopack", 1, true) then ratioHelp = message end
      end

      assert.equals(0, calls)
      assert.equals(2, #messages)
      assertContains(messages[1], "usage:")
      assertContains(messages[2], "usage:")
      assert.is_truthy(ratioHelp)
      for _, message in ipairs({ messages[1], messages[2], ratioHelp }) do
        assertContains(message, "/npt importratiopack")
        assertContains(message, "<eb36>.<eq36>,...")
        assertContains(message, "base36")
        assertContains(message, "token order corresponds to wave order")
        assert.is_nil(message:find("e<count>q<count>", 1, true), message)
      end
    end)
  end)

  it("prints the importer error clearly without updating the orb", function()
    scenario(function()
      SlashCmdList = {}
      mocks.loadSource("Modules/Slash.lua")
      MDT_NPT.ImportRatio = {
        applyPack = function() return false, "route key mismatch: test" end,
      }
      local updateCalls = 0
      MDT_NPT.SpellRatioOrb = {
        Update = function() updateCalls = updateCalls + 1 end,
      }

      local messages = capturePrint(function()
        MDT_NPT:Slash("importratiopack deadbeef 1.2")
      end)

      assert.equals(0, updateCalls)
      assert.equals(1, #messages)
      assertContains(messages[1], "importratiopack failed")
      assertContains(messages[1], "route key mismatch: test")
    end)
  end)
end)
