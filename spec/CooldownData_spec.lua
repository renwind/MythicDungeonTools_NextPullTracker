local mocks = require("wow_mocks")

local function plan(...)
  return { entries = { ... } }
end
local function spell(action, id)
  return { kind = "spell", id = id or 114050, action = action or "use" }
end
local function item(action, id)
  return { kind = "item", id = id or 241308, action = action or "use" }
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end
local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    mocks.loadSource("Modules/CooldownData.lua")
    mocks.loadSource("Modules/CooldownPlan.lua")
    fn(env, MDT_NPT.CooldownData, MDT_NPT.CooldownPlan)
  end)
end

describe("CooldownData 计划使用序号", function()
  before_each(function() mocks.reset() end)

  it("稀疏波次按技能独立从一累计且包含当前波", function()
    scenario(function(env, data)
      env.dbChar.cooldownPlans.a = {
        [1] = plan(spell()), [4] = plan(spell(), item()),
        [7] = plan(spell(), item()), [10] = plan(spell(), item()),
      }
      for _, row in ipairs({ { 1, 1, nil }, { 4, 2, 1 }, { 7, 3, 2 } }) do
        local entries = data.getActiveEntries(env.dbChar, "a", row[1])
        assert.equals(row[2], entries[1].useOrdinal)
        assert.equals(row[3], entries[2].useOrdinal)
      end
    end)
  end)

  it("角色和路线分别隔离", function()
    scenario(function(env, data)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell()), [4] = plan(spell()) }
      env.dbChar.cooldownPlans.b = { [4] = plan(spell()) }
      local other = { cooldownPotionID = 241308, cooldownPlans = { a = { [4] = plan(spell()) } } }
      assert.equals(2, data.getActiveEntries(env.dbChar, "a", 4)[1].useOrdinal)
      assert.equals(1, data.getActiveEntries(env.dbChar, "b", 4)[1].useOrdinal)
      assert.equals(1, data.getActiveEntries(other, "a", 4)[1].useOrdinal)
    end)
  end)

  it("两种升腾 ID 归为同一技能并保留 seed 和 plan 引用", function()
    scenario(function(env, data)
      local current = spell("use", 1219480)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell()), [4] = plan(current) }
      local entry = data.getActiveEntries(env.dbChar, "a", 4)[1]
      assert.equals(data.getSeedEntries()[1], entry.seed)
      assert.equals(current, entry.plan)
      assert.equals(2, entry.useOrdinal)
    end)
  end)

  it("同一波重复 ID 和别名最多贡献一次", function()
    scenario(function(env, data)
      env.dbChar.cooldownPlans.a = {
        [1] = plan(spell(), spell("use", 1219480), spell(), item(), item()),
        [4] = plan(spell(), spell(), item(), item()),
      }
      local entries = data.getActiveEntries(env.dbChar, "a", 4)
      assert.equals(2, entries[1].useOrdinal)
      assert.equals(2, entries[2].useOrdinal)
    end)
  end)

  it("历史只计有效同 kind 的 use 且不清洗历史记录", function()
    scenario(function(env, data)
      local history = {
        [1] = plan(item("use", 114050), spell("use", 241308)),
        [2] = plan(spell("save"), item("save")),
        [3] = plan(spell("invalid"), item("invalid"), "损坏记录"),
        [4] = plan(spell("use", "114050"), item("use", "241308")),
        [5] = plan(spell("use", 999), item("use", 999)),
        [6] = plan(spell("use", 1219480), item()),
        [7] = plan(spell(), item()),
        ["8"] = plan(spell(), item()),
        metadata = plan(spell(), item()),
      }
      env.dbChar.cooldownPlans.a = history
      local before = copy(env.dbChar)
      local entries = data.getActiveEntries(env.dbChar, "a", 7)
      assert.same(before, env.dbChar)
      assert.equals(2, entries[1].useOrdinal)
      assert.equals(2, entries[2].useOrdinal)
    end)
  end)

  it("当前匹配也排除错误 kind 和无效 action 而不遮挡后面的有效项", function()
    scenario(function(env, data)
      local valid = spell("use", 1219480)
      env.dbChar.cooldownPlans.a = {
        [1] = plan(item("use", 114050), spell("invalid"), valid),
      }
      local entry = data.getActiveEntries(env.dbChar, "a", 1)[1]
      assert.equals(valid, entry.plan)
      assert.equals(1, entry.useOrdinal)
    end)
  end)

  it("无有效当前项时不误匹配清洗后的 nil ID", function()
    scenario(function(env, data)
      env.dbChar.cooldownPlans.a = {
        [1] = plan(item("use", 114050), item("use", "241308"), spell("invalid")),
      }
      local entries = data.getActiveEntries(env.dbChar, "a", 1)
      for _, entry in ipairs(entries) do
        assert.is_nil(entry.plan)
        assert.is_nil(entry.useOrdinal)
      end
    end)
  end)

  it("药水只按当前配置 ID 计数且切换后立即重算", function()
    scenario(function(env, data)
      env.dbChar.cooldownPlans.a = {
        [1] = plan(item()), [3] = plan(item()), [4] = plan(item("use", 999)),
        [7] = plan(item(), item("use", 999)),
      }
      assert.equals(3, data.getActiveEntries(env.dbChar, "a", 7)[2].useOrdinal)
      env.dbChar.cooldownPotionID = 999
      local entry = data.getActiveEntries(env.dbChar, "a", 7)[2]
      assert.equals(999, entry.plan.id)
      assert.equals(2, entry.useOrdinal)
    end)
  end)

  it("save 和未规划没有序号且不贡献计数", function()
    scenario(function(env, data)
      env.dbChar.cooldownPlans.a = {
        [1] = plan(spell(), item()), [4] = plan(spell("save")), [7] = plan(spell()),
      }
      local saved = data.getActiveEntries(env.dbChar, "a", 4)
      assert.equals("save", saved[1].plan.action)
      assert.is_nil(saved[1].useOrdinal)
      assert.is_nil(saved[2].useOrdinal)
      assert.is_nil(data.getActiveEntries(env.dbChar, "a", 5)[1].useOrdinal)
      assert.equals(2, data.getActiveEntries(env.dbChar, "a", 7)[1].useOrdinal)
    end)
  end)

  it("修改前波或删除计划后通过真实 CRUD 即时重算", function()
    scenario(function(env, data, store)
      for _, index in ipairs({ 1, 4, 7 }) do store:SetEntry("a", index, 114050, "spell", "use") end
      local function ordinal() return data.getActiveEntries(env.dbChar, "a", 7)[1].useOrdinal end
      assert.equals(3, ordinal())
      store:SetEntry("a", 1, 114050, "spell", "save")
      assert.equals(2, ordinal())
      store:ClearPull("a", 4)
      assert.equals(1, ordinal())
      store:ClearEntry("a", 7, 114050)
      assert.is_nil(ordinal())
    end)
  end)

  it("序号只为派生值且完整有效存档保持不变", function()
    scenario(function(env, data)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell()), [4] = plan(spell(), item()) }
      local before = copy(env.dbChar)
      local entries = data.getActiveEntries(env.dbChar, "a", 4)
      assert.equals(2, entries[1].useOrdinal)
      assert.same(before, env.dbChar)
      assert.is_nil(entries[1].seed.useOrdinal)
      assert.is_nil(entries[1].plan.useOrdinal)
      assert.is_nil(entries[1].plan.ordinal)
    end)
  end)

  it("跳波回退和实际冷却变化不改变计划序号且不调用冷却 API", function()
    scenario(function(env, data)
      env.dbChar.cooldownPlans.a = { [1] = plan(spell()), [4] = plan(spell()), [7] = plan(spell()) }
      C_Spell.GetSpellCooldown = function() error("计算序号不得读取冷却") end
      for _, row in ipairs({ { 7, 3 }, { 1, 1 }, { 4, 2 }, { 7, 3 } }) do
        MDT_NPT.state = { currentNextPull = row[1], pullStates = { "completed" }, lastCast = env.time }
        env.time = env.time + 180
        assert.equals(row[2], data.getActiveEntries(env.dbChar, "a", row[1])[1].useOrdinal)
      end
    end)
  end)

  it("两位序号不截断", function()
    scenario(function(env, data, store)
      for i = 1, 12 do store:SetEntry("a", i * 3, 114050, "spell", "use") end
      assert.equals(12, data.getActiveEntries(env.dbChar, "a", 36)[1].useOrdinal)
    end)
  end)

  it("空角色路线波次和不支持专精安全返回", function()
    scenario(function(env, data)
      for _, entries in ipairs({
        data.getActiveEntries(nil, "a", 1), data.getActiveEntries(env.dbChar, nil, 1),
        data.getActiveEntries(env.dbChar, "a", nil), data.getActiveEntries(env.dbChar, "missing", 1),
      }) do
        for _, entry in ipairs(entries) do assert.is_nil(entry.useOrdinal); assert.is_nil(entry.plan) end
      end
      env.specID = 263
      assert.same({}, data.getActiveEntries(env.dbChar, "a", 1))
    end)
  end)

  it("可选环境在失败时恢复原全局且不扩大 reset 安装面", function()
    local previous = _G.CreateFrame
    local ok = pcall(function()
      mocks.withCooldownRuntime(function() error("有意中断") end)
    end)
    assert.is_false(ok)
    assert.equals(previous, _G.CreateFrame)
  end)
end)
