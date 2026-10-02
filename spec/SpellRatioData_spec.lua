local mocks = require("wow_mocks")

local function scenario(fn, capturePrint)
  mocks.withCooldownRuntime(function(env)
    env.dbChar.rotationRatios = {}
    MDT_NPT.CooldownData = {
      computePullFingerprint = function(pull, enemies)
        if not pull or not enemies then return nil end
        return pull.fp
      end,
    }

    local originalPrint = _G.print
    local messages = {}
    if capturePrint then
      _G.print = function(message)
        messages[#messages + 1] = message
      end
    end

    local ok, err = pcall(function()
      mocks.loadSource("Modules/SpellRatioData.lua")
      fn(env, MDT_NPT.SpellRatioData, messages)
    end)
    _G.print = originalPrint
    if not ok then error(err, 0) end
  end)
end

local function row(elementalBlast, earthquake, fingerprint)
  return {
    elementalBlast = elementalBlast,
    earthquake = earthquake,
    fingerprint = fingerprint,
  }
end

describe("SpellRatioData", function()
  before_each(function() mocks.reset() end)

  it("returns nil for missing data and stores valid rows including zero-zero", function()
    scenario(function(env, data)
      assert.is_nil(data:Get("uid", 1))
      assert.is_true(data:Set("uid", 1, 8, 2, "fp1"))
      assert.same(row(8, 2, "fp1"), data:Get("uid", 1))

      assert.is_true(data:Set("uid", 2, 0, 0, "fp2"))
      assert.same(row(0, 0, "fp2"), env.dbChar.rotationRatios.uid[2])
    end)
  end)

  it("returns a field copy without exposing the stored row", function()
    scenario(function(_, data)
      assert.is_true(data:Set("uid", 1, 8, 2, "fp1"))

      local result = data:Get("uid", 1)
      result.elementalBlast = 99
      result.fingerprint = "changed"

      assert.same(row(8, 2, "fp1"), data:Get("uid", 1))
    end)
  end)

  it("rejects invalid Set arguments without changing stored data", function()
    scenario(function(env, data)
      assert.is_true(data:Set("uid", 1, 3, 4, "old"))
      local stored = env.dbChar.rotationRatios.uid[1]

      assert.is_false(data:Set(nil, 1, 1, 1, "fp"))
      assert.is_false(data:Set("", 1, 1, 1, "fp"))
      assert.is_false(data:Set("uid", 0, 1, 1, "fp"))
      assert.is_false(data:Set("uid", 1.5, 1, 1, "fp"))
      assert.is_false(data:Set("uid", 1, -1, 1, "fp"))
      assert.is_false(data:Set("uid", 1, 1.5, 1, "fp"))
      assert.is_false(data:Set("uid", 1, math.huge, 1, "fp"))
      assert.is_false(data:Set("uid", 1, 1, -1, "fp"))
      assert.is_false(data:Set("uid", 1, 1, 1.5, "fp"))
      assert.is_false(data:Set("uid", 1, 1, 1, 7))

      assert.equals(stored, env.dbChar.rotationRatios.uid[1])
      assert.is_nil(env.dbChar.rotationRatios[""])
    end)
  end)

  it("deletes corrupt waves and warns only once for the module lifetime", function()
    scenario(function(env, data, messages)
      env.dbChar.rotationRatios.uid = {
        [1] = row(-1, 2, "fp"),
        [2] = row(1, 2.5, "fp"),
        [3] = row(1, 2, 99),
        [4] = "not a row",
      }

      for pullIndex = 1, 4 do
        assert.is_nil(data:Get("uid", pullIndex))
        assert.is_nil(env.dbChar.rotationRatios.uid[pullIndex])
      end
      assert.equals(1, #messages)
      assert.is_string(messages[1])
    end, true)
  end)

  it("validates every replacement before atomically replacing one route", function()
    scenario(function(env, data)
      assert.is_true(data:Set("uid", 9, 9, 9, "old"))
      local oldRoute = env.dbChar.rotationRatios.uid

      assert.is_false(data:ReplaceRoute("uid", {
        [1] = row(1, 2, "a"),
        [0] = row(2, 1, "bad-key"),
      }))
      assert.equals(oldRoute, env.dbChar.rotationRatios.uid)

      assert.is_false(data:ReplaceRoute("uid", {
        [1] = row(1, 2, "a"),
        [2] = row(2, -1, "bad-row"),
      }))
      assert.equals(oldRoute, env.dbChar.rotationRatios.uid)

      assert.is_false(data:ReplaceRoute("uid", {
        [1] = row(1, 2, "a"),
        ["2"] = row(2, 1, "bad-key-type"),
      }))
      assert.equals(oldRoute, env.dbChar.rotationRatios.uid)

      local replacement = {
        [1] = row(1, 2, "a"),
        [2] = row(0, 0, "b"),
      }
      assert.is_true(data:ReplaceRoute("uid", replacement))
      assert.is_nil(data:Get("uid", 9))
      assert.same(replacement, env.dbChar.rotationRatios.uid)
    end)
  end)

  it("rejects invalid replacement containers and uid without changing storage", function()
    scenario(function(env, data)
      assert.is_true(data:Set("uid", 1, 2, 3, "old"))
      local oldRoute = env.dbChar.rotationRatios.uid

      assert.is_false(data:ReplaceRoute("", {}))
      assert.is_false(data:ReplaceRoute(nil, {}))
      assert.is_false(data:ReplaceRoute("uid", "not rows"))
      assert.equals(oldRoute, env.dbChar.rotationRatios.uid)
    end)
  end)

  it("verifies a stored row against a computable live fingerprint", function()
    scenario(function(_, data)
      assert.is_true(data:Set("uid", 1, 1, 3, "same"))
      assert.is_true(data:Verify("uid", 1, { fp = "same" }, {}))
      assert.is_false(data:Verify("uid", 1, { fp = "different" }, {}))
      assert.is_false(data:Verify("uid", 1, nil, {}))
      assert.is_false(data:Verify("uid", 1, { fp = "same" }, nil))
      assert.is_false(data:Verify("uid", 2, { fp = "same" }, {}))
    end)
  end)

  it("rounds to complementary tenths and returns nil for zero-zero", function()
    scenario(function(_, data)
      assert.same({ elementalBlast = 8, earthquake = 2 }, data:RatioTenths(row(8, 2, "fp")))
      assert.same({ elementalBlast = 7, earthquake = 3 }, data:RatioTenths(row(2, 1, "fp")))
      assert.same({ elementalBlast = 1, earthquake = 9 }, data:RatioTenths(row(1, 19, "fp")))
      assert.same({ elementalBlast = 0, earthquake = 10 }, data:RatioTenths(row(1, 42, "fp")))
      assert.is_nil(data:RatioTenths(row(0, 0, "fp")))
    end)
  end)
end)

describe("SpellRatioData:FillTenths", function()
  before_each(function() mocks.reset() end)

  it("rounds to the nearest tenth", function()
    scenario(function(_, data)
      assert.same({ elementalBlast = 8, earthquake = 2 }, data:FillTenths(row(8, 2, "fp")))
      assert.same({ elementalBlast = 2, earthquake = 8 }, data:FillTenths(row(2, 8, "fp")))
      assert.same({ elementalBlast = 5, earthquake = 5 }, data:FillTenths(row(3, 3, "fp")))
    end)
  end)

  it("clamps both sides to at least one tenth when both counts are nonzero", function()
    scenario(function(_, data)
      -- 1/46 = 2.2% → 未 clamp 会是 0，clamp 后为 1
      assert.same({ elementalBlast = 1, earthquake = 9 }, data:FillTenths(row(1, 45, "fp")))
      -- 14% → 1（floor(1.4+0.5)=1）；15% → 2（floor(1.5+0.5)=2）
      assert.same({ elementalBlast = 1, earthquake = 9 }, data:FillTenths(row(14, 86, "fp")))
      assert.same({ elementalBlast = 2, earthquake = 8 }, data:FillTenths(row(15, 85, "fp")))
      -- 45/1 → 上限：earthquake 真的施放过，不能被四舍五入吃成 0
      assert.same({ elementalBlast = 9, earthquake = 1 }, data:FillTenths(row(45, 1, "fp")))
    end)
  end)

  it("allows a truly zero side to occupy the full range", function()
    scenario(function(_, data)
      assert.same({ elementalBlast = 0, earthquake = 10 }, data:FillTenths(row(0, 5, "fp")))
      assert.same({ elementalBlast = 10, earthquake = 0 }, data:FillTenths(row(5, 0, "fp")))
    end)
  end)

  it("returns nil for a zero-zero row, mirroring RatioTenths", function()
    scenario(function(_, data)
      assert.is_nil(data:FillTenths(row(0, 0, "fp")))
      assert.is_nil(data:RatioTenths(row(0, 0, "fp")))
    end)
  end)

  it("returns nil for malformed rows", function()
    scenario(function(_, data)
      assert.is_nil(data:FillTenths(nil))
      assert.is_nil(data:FillTenths("nope"))
      assert.is_nil(data:FillTenths(row(-1, 5, "fp")))
      assert.is_nil(data:FillTenths(row(1.5, 5, "fp")))
    end)
  end)

  it("diverges from RatioTenths, which never clamps", function()
    scenario(function(_, data)
      local stored = row(1, 45, "fp")
      assert.same({ elementalBlast = 1, earthquake = 9 }, data:FillTenths(stored))
      assert.same({ elementalBlast = 0, earthquake = 10 }, data:RatioTenths(stored))
    end)
  end)

  it("does not require a fingerprint on the row", function()
    scenario(function(_, data)
      assert.same({ elementalBlast = 1, earthquake = 9 },
        data:FillTenths({ elementalBlast = 1, earthquake = 45 }))
      assert.same({ elementalBlast = 0, earthquake = 10 },
        data:RatioTenths({ elementalBlast = 1, earthquake = 45 }))
    end)
  end)
end)
