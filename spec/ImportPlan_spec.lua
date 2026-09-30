local mocks = require("wow_mocks")

local function presetWith(pulls)
  return {
    uid = "uid1",
    value = { currentDungeonIdx = 1, currentSublevel = 1, currentPull = 1, pulls = pulls },
  }
end

-- enemies 只需让 computePullFingerprint 认为 enemyIndex 存在。
local function enemiesFor(pull)
  local enemies = {}
  for idx in pairs(pull) do enemies[idx] = { clones = {} } end
  return enemies
end

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    mocks.loadSource("Modules/CooldownData.lua")
    mocks.loadSource("Modules/CooldownPlan.lua")
    mocks.loadSource("Modules/ImportPlan.lua")
    fn(env)
  end)
end

describe("ImportPlan entrySpec 解析", function()
  before_each(function() mocks.reset() end)

  it("解析 id:kind:action[:uses] 并忽略 uses=1", function()
    scenario(function(env)
      local entries, err = MDT_NPT.ImportPlan.parseEntrySpec("32182:spell:use;114050:spell:use:2;241308:item:use")
      assert.is_nil(err)
      assert.equals(3, #entries)
      assert.equals(32182, entries[1].id)
      assert.equals("spell", entries[1].kind)
      assert.equals("use", entries[1].action)
      assert.is_nil(entries[1].uses)
      assert.equals(2, entries[2].uses)
      assert.equals("item", entries[3].kind)
    end)
  end)

  it("非法 kind/action/非数字 id 报错", function()
    scenario(function(env)
      local _, err1 = MDT_NPT.ImportPlan.parseEntrySpec("32182:wand:use")
      assert.is_string(err1)
      local _, err2 = MDT_NPT.ImportPlan.parseEntrySpec("32182:spell:hold")
      assert.is_string(err2)
      local _, err3 = MDT_NPT.ImportPlan.parseEntrySpec("abc:spell:use")
      assert.is_string(err3)
    end)
  end)

  it("空串解析为零条", function()
    scenario(function(env)
      local entries, err = MDT_NPT.ImportPlan.parseEntrySpec("")
      assert.is_nil(err)
      assert.equals(0, #entries)
    end)
  end)
end)

describe("ImportPlan apply", function()
  before_each(function() mocks.reset() end)

  it("写入当前预设 uid 的 plan 并落 fingerprint", function()
    scenario(function(env)
      local pull = { [3] = { 1, 2 }, [5] = { 1 } }
      local preset = presetWith({ pull, { [7] = { 1 } } })
      _G.MDT.GetCurrentPreset = function() return preset end
      _G.MDT.dungeonEnemies = { [1] = enemiesFor(pull) }
      local key = MDT_NPT.ImportPlan.computeRouteKey(preset.value.pulls)

      local ok, err = MDT_NPT.ImportPlan:apply(1, "32182:spell:use;114050:spell:use:2", key)
      assert.is_nil(err)
      assert.is_true(ok)

      local plan = MDT_NPT.CooldownPlan:Get("uid1", 1)
      assert.equals(2, #plan.entries)
      assert.equals(2, plan.entries[2].uses)
      assert.equals("3:2,5:1", plan.fingerprint)
    end)
  end)

  it("routeKey 对不上拒绝写入", function()
    scenario(function(env)
      local pull = { [3] = { 1, 2 } }
      local preset = presetWith({ pull })
      _G.MDT.GetCurrentPreset = function() return preset end
      _G.MDT.dungeonEnemies = { [1] = enemiesFor(pull) }

      local ok, err = MDT_NPT.ImportPlan:apply(1, "32182:spell:use", "deadbeef")
      assert.is_false(ok)
      assert.is_string(err)
      assert.is_nil(MDT_NPT.CooldownPlan:Get("uid1", 1))
    end)
  end)

  it("无预设 uid 或波次越界报错且不写库", function()
    scenario(function(env)
      local preset = presetWith({ { [3] = { 1 } } })
      _G.MDT.GetCurrentPreset = function() return preset end
      local key = MDT_NPT.ImportPlan.computeRouteKey(preset.value.pulls)
      local ok1, err1 = MDT_NPT.ImportPlan:apply(9, "32182:spell:use", key)
      assert.is_false(ok1)
      assert.is_string(err1)
      assert.is_nil(MDT_NPT.CooldownPlan:Get("uid1", 9))

      _G.MDT.GetCurrentPreset = function() return { value = { pulls = {} } } end
      local ok2, err2 = MDT_NPT.ImportPlan:apply(1, "32182:spell:use", "00000000")
      assert.is_false(ok2)
      assert.is_string(err2)
    end)
  end)
end)
