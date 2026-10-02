local mocks = require("wow_mocks")

-- ReadyTracker v5：嗜血/爆发药水就绪对照窗。0.5s 轮询手动触发（env.tickers[1]）。
-- 必须加载真 Theme.lua，避免 stub 的黑色默认值掩盖主题边框错误。
local SATED_ID = 57724

local function scenario(fn)
  mocks.withCooldownRuntime(function(env)
    mocks.loadSource("Modules/Theme.lua")
    mocks.loadSource("Modules/CooldownLust.lua")
    mocks.loadSource("Modules/ReadyTracker.lua")
    fn(env, MDT_NPT.ReadyTracker)
  end)
end

-- 模拟 0.5s 轮询走一拍：真实客户端由 C_Timer.NewTicker 驱动，测试手动触发。
local function tick(env)
  env.tickers[1].callback()
end

-- 精疲力尽 debuff：剩余秒数 -> aura 表（expirationTime 用当前 env.time 折算）。
local function satedFor(env, seconds)
  if seconds == nil then
    env.auras[SATED_ID] = nil
  else
    env.auras[SATED_ID] = { expirationTime = env.time + seconds }
  end
end

local function cdRemaining(env, remaining, itemID)
  itemID = itemID or env.dbChar.cooldownPotionID or 241308
  env.itemCooldowns[itemID] = { startTime = env.time + remaining - 300, duration = 300 }
end

-- 八条边框（两格 x 四边）的颜色收集成列表，断言一眼看全。
local function borderColors(f)
  local out = {}
  for _, cell in ipairs({ f.lustCell, f.potionCell }) do
    for _, key in ipairs({ "borderTop", "borderBottom", "borderLeft", "borderRight" }) do
      out[#out + 1] = cell[key].color
    end
  end
  return out
end

describe("ReadyTracker 对照绘制", function()
  before_each(function() mocks.reset() end)

  it("药水在左、嗜血在右，图标间距不变", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      tick(env)
      local f = rt.getFrame()
      assert.same({ "TOPLEFT", f, "TOPLEFT", 4, -4 }, f.potionCell.points[1])
      assert.same({ "TOPLEFT", f.potionCell, "TOPRIGHT", 6, 0 }, f.lustCell.points[1])
    end)
  end)

  it("开关开：两格倒计时分别取嗜血与药水的就绪秒数（90 -> 1.5m，20 -> 20）", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      satedFor(env, 90)
      cdRemaining(env, 20)
      tick(env)
      local f = rt.getFrame()
      assert.is_not_nil(f)
      assert.is_true(f:IsShown())
      assert.equals("1.5m", f.lustCell.text:GetText())
      assert.equals("20", f.potionCell.text:GetText())
      -- 图标来源：嗜血走法术贴图，药水走当前药水 itemID 的物品贴图
      assert.equals("spell:2825", f.lustCell.icon.texture)
      assert.equals("item:241308", f.potionCell.icon.texture)
    end)
  end)

  it("冷却和就绪状态都保持 EUI 主题边框，图标与倒计时照常变化", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      tick(env)
      local f = rt.getFrame()
      assert.equals("", f.lustCell.text:GetText())
      assert.equals("", f.potionCell.text:GetText())
      assert.equals(1, f.lustCell.icon.alpha)
      assert.equals(1, f.potionCell.icon.alpha)
      for _, c in ipairs(borderColors(f)) do
        assert.same(MDT_NPT.Theme.colors.accent, c)
      end

      satedFor(env, 10)
      tick(env)
      assert.equals("10", f.lustCell.text:GetText())
      assert.equals("", f.potionCell.text:GetText())
      assert.equals(0.45, f.lustCell.icon.alpha)
      for _, c in ipairs(borderColors(f)) do
        assert.same(MDT_NPT.Theme.colors.accent, c)
      end

      cdRemaining(env, 20)
      tick(env)
      assert.equals("20", f.potionCell.text:GetText())
      assert.equals(0.45, f.potionCell.icon.alpha)
      for _, c in ipairs(borderColors(f)) do
        assert.same(MDT_NPT.Theme.colors.accent, c)
      end
    end)
  end)

  it("独立轮询会跟随 EUI 主题色变化", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      local color = { 0.1, 0.5, 0.9, 1 }
      _G.EllesmereUI = { GetAccentColor = function() return color[1], color[2], color[3] end }
      tick(env)
      local f = rt.getFrame()
      for _, c in ipairs(borderColors(f)) do assert.same(color, c) end

      color = { 0.2, 0.6, 0.8, 1 }
      tick(env)
      for _, c in ipairs(borderColors(f)) do assert.same(color, c) end
    end)
  end)
end)

describe("ReadyTracker 开关与拖动", function()
  before_each(function() mocks.reset() end)

  it("开关关：窗口隐藏且绘制 no-op（倒计时不再刷新）", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      satedFor(env, 30)
      tick(env)
      local f = rt.getFrame()
      assert.is_true(f:IsShown())
      assert.equals("30", f.lustCell.text:GetText())

      env.db.beacon.readyTracker = false
      satedFor(env, 25)
      tick(env)
      assert.is_false(f:IsShown())
      assert.equals("30", f.lustCell.text:GetText())
    end)
  end)

  it("OnDragStop 把 {point, x, y} 写进 db.beacon.readyTrackerPos（默认锚 CENTER 0,240）", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      tick(env)
      local f = rt.getFrame()
      -- 默认锚点先落位，拖完保存的就是它
      assert.equals("CENTER", f.points[1][1])
      f.scripts.OnDragStop(f)
      assert.same({ "CENTER", 0, 240 }, env.db.beacon.readyTrackerPos)
      -- db 引用稳定：写进的正是测试同一张 db 表
      assert.equals(env.db, MDT_NPT:GetDB())
    end)
  end)

  it("有已存位置时 ensureFrame 用它 SetPoint（相对点固定 CENTER）", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      env.db.beacon.readyTrackerPos = { "TOPLEFT", 12, -34 }
      tick(env)
      local p = rt.getFrame().points[1]
      assert.equals("TOPLEFT", p[1])
      assert.equals(_G.UIParent, p[2])
      assert.equals("CENTER", p[3])
      assert.equals(12, p[4])
      assert.equals(-34, p[5])
    end)
  end)
end)

describe("ReadyTracker 药水图标", function()
  before_each(function() mocks.reset() end)

  it("dbChar.cooldownPotionID 有覆盖时图标跟随覆盖值", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      env.dbChar.cooldownPotionID = 999
      tick(env)
      assert.equals("item:999", rt.getFrame().potionCell.icon.texture)
    end)
  end)

  it("未配置时回落 241308 默认药水（CooldownData SEED_TABLE defaultItemID）", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      env.dbChar.cooldownPotionID = nil
      tick(env)
      assert.equals("item:241308", rt.getFrame().potionCell.icon.texture)
    end)
  end)
end)

describe("ReadyTracker 药水冷却来源", function()
  before_each(function() mocks.reset() end)

  it("技能CD未激活时仍显示物品的剩余CD与背景", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      cdRemaining(env, 180)
      tick(env)
      local f = rt.getFrame()
      assert.equals("", f.lustCell.text:GetText())
      assert.equals("3m", f.potionCell.text:GetText())
      assert.equals(0.45, f.potionCell.icon.alpha)
      assert.is_true(f.potionCell.textBg:IsShown())
    end)
  end)

  it("物品无CD时不会把技能冷却误显示为药水CD", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      env.cooldown = { isEnabled = true, isActive = true, startTime = env.time, duration = 300 }
      tick(env)
      assert.equals("", rt.getFrame().potionCell.text:GetText())
      assert.is_false(rt.getFrame().potionCell.textBg:IsShown())
    end)
  end)

  it("自定义药水仅查询所选物品，不借用默认药水的CD", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      env.dbChar.cooldownPotionID = 999
      cdRemaining(env, 180, 241308)
      cdRemaining(env, 25, 999)
      tick(env)
      assert.equals("item:999", rt.getFrame().potionCell.icon.texture)
      assert.equals("25", rt.getFrame().potionCell.text:GetText())
    end)
  end)

  it("各品质和临时药水的残留CD都可读，不要求背包中仍有剩余", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      C_Item.GetItemCount = function() return 0 end
      for _, itemID in ipairs({ 241308, 241309, 245898, 245897 }) do
        env.itemCooldowns = {}
        cdRemaining(env, 180, itemID)
        tick(env)
        assert.equals("3m", rt.getFrame().potionCell.text:GetText())
      end
    end)
  end)

  it("优先读取容器物品CD，缺失时读取C_Item", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      env.containerCooldowns[241308] = { startTime = env.time - 15, duration = 60 }
      tick(env)
      assert.equals("45", rt.getFrame().potionCell.text:GetText())
      env.containerCooldowns = {}
      cdRemaining(env, 25)
      tick(env)
      assert.equals("25", rt.getFrame().potionCell.text:GetText())
    end)
  end)

  it("容器冷却不可读时仍能使用物品CD", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      C_Container.GetItemCooldown = function() return {}, {} end
      cdRemaining(env, 20)
      tick(env)
      assert.equals("20", rt.getFrame().potionCell.text:GetText())
    end)
  end)

  it("物品CD到期后清空倒计时和背景", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      cdRemaining(env, 20)
      tick(env)
      assert.equals("20", rt.getFrame().potionCell.text:GetText())
      env.time = env.time + 20
      tick(env)
      assert.equals("", rt.getFrame().potionCell.text:GetText())
      assert.equals(1, rt.getFrame().potionCell.icon.alpha)
      assert.is_false(rt.getFrame().potionCell.textBg:IsShown())
    end)
  end)

  it("忽略物品公共冷却和空冷却返回", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      env.itemCooldowns[241308] = { startTime = env.time, duration = 1.5 }
      tick(env)
      assert.equals("", rt.getFrame().potionCell.text:GetText())
      C_Item.GetItemCooldown = function() return nil, nil end
      tick(env)
      assert.equals("", rt.getFrame().potionCell.text:GetText())
    end)
  end)
end)

describe("ReadyTracker 缩放", function()
  before_each(function() mocks.reset() end)

  it("右缘把手横向拖：窗宽决定格边长与字号，松手写回 db", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      tick(env)
      local f = rt.getFrame()
      assert.is_true(f.resizable)
      f.grip.scripts.OnMouseDown(f.grip)
      assert.equals("RIGHT", f.sizing)
      f:SetSize(140, 999)  -- 真客户端在 StartSizing 期间改宽度；mock 手动设值代替
      f.grip.scripts.OnMouseUp(f.grip)
      assert.equals(63, f.lustCell.width)   -- (140 - 6 - 8) / 2
      assert.equals(63, f.potionCell.width)
      assert.equals(71, f.height)           -- 格边长 + 上下内衬
      -- 字号随边长等比：基准 19（mock cdText 12 + 7）* 63/36 = 33.25 -> 33
      local _, size = f.lustCell.text:GetFont()
      assert.equals(33, size)
      assert.equals(140, env.db.beacon.readyTrackerWidth)
    end)
  end)

  it("建窗时按 db.beacon.readyTrackerWidth 还原并夹到边界", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      env.db.beacon.readyTrackerWidth = 999
      tick(env)
      local f = rt.getFrame()
      assert.equals(240, f.width)           -- MAX_W 夹住
      assert.equals(113, f.lustCell.width)  -- (240 - 6 - 8) / 2
    end)
  end)
end)

describe("ReadyTracker 把手显隐", function()
  before_each(function() mocks.reset() end)

  it("把手悬停才显形：默认藏、进入显、离开藏；拖拽中离开不藏，把手外松手藏", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      tick(env)
      local grip = rt.getFrame().grip
      assert.is_false(grip.tex:IsShown())
      grip.scripts.OnEnter(grip)
      assert.is_true(grip.tex:IsShown())
      grip.scripts.OnLeave(grip)
      assert.is_false(grip.tex:IsShown())
      -- 拖拽中鼠标常滑出把手：此时藏掉等于盲拖
      grip.scripts.OnEnter(grip)
      grip.scripts.OnMouseDown(grip)
      grip.scripts.OnLeave(grip)
      assert.is_true(grip.tex:IsShown())
      grip.mouseOver = false  -- mock：松手时鼠标已不在把手上
      grip.scripts.OnMouseUp(grip)
      assert.is_false(grip.tex:IsShown())
    end)
  end)
end)

describe("ReadyTracker 点击穿透", function()
  before_each(function() mocks.reset() end)

  it("默认穿透：整窗与把手都 EnableMouse(false)", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      tick(env)
      local f = rt.getFrame()
      assert.is_false(f:IsMouseEnabled())
      assert.is_false(f.grip:IsMouseEnabled())
      assert.same({ "MODIFIER_STATE_CHANGED" }, f.events)
    end)
  end)

  it("Alt 按住恢复交互：整窗与把手都启用", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      tick(env)
      local f = rt.getFrame()
      env.alt = true
      f.scripts.OnEvent(f, "MODIFIER_STATE_CHANGED")
      assert.is_true(f:IsMouseEnabled())
      assert.is_true(f.grip:IsMouseEnabled())
    end)
  end)

  it("缩放中松开 Alt：主动收尾，宽度写回 db 并回到穿透", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      env.alt = true
      tick(env)
      local f = rt.getFrame()
      f.grip.scripts.OnMouseDown(f.grip)
      f:SetSize(140, 999)
      env.alt = false
      f.scripts.OnEvent(f, "MODIFIER_STATE_CHANGED")  -- 没有 OnMouseUp，靠事件收尾
      assert.equals(140, env.db.beacon.readyTrackerWidth)
      assert.is_false(f:IsMouseEnabled())
      assert.is_false(f.grip.tex:IsShown())
    end)
  end)

  it("拖动中松开 Alt：位置写回 db 并回到穿透", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      env.alt = true
      tick(env)
      local f = rt.getFrame()
      f.scripts.OnDragStart(f)
      env.alt = false
      f.scripts.OnEvent(f, "MODIFIER_STATE_CHANGED")
      assert.is_not_nil(env.db.beacon.readyTrackerPos)
      assert.is_false(f:IsMouseEnabled())
    end)
  end)
end)

describe("ReadyTracker 倒计时背景", function()
  before_each(function() mocks.reset() end)

  it("倒计时在图标上方的等宽黑色半透明背景内居中", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      satedFor(env, 90)
      cdRemaining(env, 20)
      tick(env)
      local f = rt.getFrame()
      for _, cell in ipairs({ f.lustCell, f.potionCell }) do
        local bg = cell.textBg
        assert.is_not_nil(bg)
        assert.equals("BACKGROUND", bg.layer)
        assert.same({ 0, 0, 0, 0.65 }, bg.color)
        assert.equals(cell:GetWidth(), bg:GetWidth())
        assert.same({ "BOTTOMLEFT", cell, "TOPLEFT", 0, 0 }, bg.points[1])
        assert.same({ "CENTER", bg, "CENTER", 0, 0 }, cell.text.points[1])
        assert.equals(1, #cell.text.points)
      end
    end)
  end)

  it("背景跟随各自冷却显隐，就绪后不留空底色", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      tick(env)
      local f = rt.getFrame()
      assert.is_not_nil(f.lustCell.textBg)
      assert.is_not_nil(f.potionCell.textBg)
      assert.is_false(f.lustCell.textBg:IsShown())
      assert.is_false(f.potionCell.textBg:IsShown())

      satedFor(env, 30)
      tick(env)
      assert.is_true(f.lustCell.textBg:IsShown())
      assert.is_false(f.potionCell.textBg:IsShown())

      cdRemaining(env, 20)
      tick(env)
      assert.is_true(f.lustCell.textBg:IsShown())
      assert.is_true(f.potionCell.textBg:IsShown())

      satedFor(env, nil)
      env.itemCooldowns = {}
      tick(env)
      assert.equals("", f.lustCell.text:GetText())
      assert.equals("", f.potionCell.text:GetText())
      assert.is_false(f.lustCell.textBg:IsShown())
      assert.is_false(f.potionCell.textBg:IsShown())
    end)
  end)

  it("初始尺寸及缩放后背景宽度等于图标，高度随字号保留上下内边距", function()
    scenario(function(env, rt)
      env.db.beacon.readyTracker = true
      tick(env)
      local f = rt.getFrame()
      for _, width in ipairs({ f:GetWidth(), 60, 140, 240 }) do
        f.grip.scripts.OnMouseDown(f.grip)
        f:SetSize(width, 999)
        f.grip.scripts.OnMouseUp(f.grip)
        for _, cell in ipairs({ f.lustCell, f.potionCell }) do
          assert.is_not_nil(cell.textBg)
          local _, fontSize = cell.text:GetFont()
          assert.equals(cell:GetWidth(), cell.textBg:GetWidth())
          assert.equals(fontSize + 4, cell.textBg:GetHeight())
        end
      end
    end)
  end)
end)
