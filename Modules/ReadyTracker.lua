local MDT_NPT = MDT_NPT
local Theme = MDT_NPT.Theme

-- ReadyTracker（v5）：独立可拖动小窗，并排两格对照嗜血与爆发药水的就绪倒计时。
-- 分开做窗而不是加宽信标行：对照是规划动作，需要自己常驻的位置，不该挤进战斗 HUD。
local ReadyTracker = {}

-- load_modules.xml 保证 CooldownLust 先于本模块加载，格子工厂与就绪探测全部复用它。
local Lust = MDT_NPT.CooldownLust

-- 药水图标走 CooldownAlert.seedIcon 物品分支同一条路；默认值是 CooldownData SEED_TABLE 的 defaultItemID。
local DEFAULT_POTION_ITEM = 241308

local CELL, GAP, PAD = 36, 6, 4  -- 格子边长 / 两格间距 / 窗口内边距

-- 非 combo 时的边框色：与 createIconBorder 的默认黑一致，每拍直接刷回。
local BLACK = { 0, 0, 0, 1 }
local BORDER_KEYS = { "borderTop", "borderBottom", "borderLeft", "borderRight" }

local frame

local function potionIcon()
  local dbChar = MDT_NPT.GetDBChar and MDT_NPT:GetDBChar()
  return C_Item.GetItemIconByID((dbChar and dbChar.cooldownPotionID) or DEFAULT_POTION_ITEM)
end

-- 拖完把当前锚点写回 db（{point, x, y}）；相对点固定 CENTER——初锚就是 CENTER/CENTER，拖动不会换相对点。
local function savePos(f)
  local db = MDT_NPT:GetDB()
  if not (db and db.beacon) then return end
  local point, _, _, x, y = f:GetPoint()
  if not point then return end
  db.beacon.readyTrackerPos = { point, x, y }
end

local function ensureFrame()
  if frame then return frame end
  frame = CreateFrame("Frame", "MDTNPTReadyTracker", UIParent)
  -- HIGH 而非 FULLSCREEN_DIALOG：常驻工具窗，不该压过瞬时提醒横幅。
  frame:SetFrameStrata("HIGH")
  frame:SetSize(CELL * 2 + GAP + PAD * 2, CELL + PAD * 2)
  -- 普通交互窗：整窗可拖，不做信标那套 Alt 点击穿透。
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame.lustCell = Lust.makeCell(frame)
  frame.lustCell:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
  frame.potionCell = Lust.makeCell(frame)
  frame.potionCell:SetPoint("TOPLEFT", frame.lustCell, "TOPRIGHT", GAP, 0)
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePos(self)
  end)
  local db = MDT_NPT:GetDB()
  local pos = db and db.beacon and db.beacon.readyTrackerPos
  if pos and pos[1] then
    frame:SetPoint(pos[1], UIParent, "CENTER", pos[2] or 0, pos[3] or 0)
  else
    -- 默认位：屏幕中上，避开 +120 处的提醒横幅。
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 240)
  end
  frame:Hide()
  return frame
end

-- 八条边框一起染色：combo 窗口开 = 就绪绿，否则刷回默认黑。
local function tintBorders(f, c)
  for _, cell in ipairs({ f.lustCell, f.potionCell }) do
    for _, key in ipairs(BORDER_KEYS) do
      cell[key]:SetColorTexture(c[1], c[2], c[3], c[4])
    end
  end
end

local function paint(f)
  local lustReady, sid = Lust.lustReadyIn()
  local potionReady = Lust.potionReadyIn()
  Lust.paintCell(f.lustCell, lustReady, sid and C_Spell.GetSpellTexture(sid))
  Lust.paintCell(f.potionCell, potionReady, potionIcon())
  -- 两者同时为 0 才是「一起开」的窗口期：只有这时边框染就绪色。
  local combo = lustReady <= 0 and potionReady <= 0
  tintBorders(f, combo and Theme.colors.lustReady or BLACK)
end

local function tick()
  -- ADDON_LOADED 前 GetDB 可能是 nil：拿不到 db 视同开关未开，绝不建窗。
  local db = MDT_NPT:GetDB()
  local beacon = db and db.beacon
  if not (beacon and beacon.readyTracker) then
    if frame then frame:Hide() end
    return
  end
  local f = ensureFrame()
  paint(f)
  f:Show()
end

local ticker

-- 自驱动：加载即挂唯一一个 0.5s ticker，开关判定与绘制都在回调里，不新建第二个。
local function ensureTicker()
  if not ticker then ticker = C_Timer.NewTicker(0.5, tick) end
end

-- 测试与将来可能的 /npt 挂钩用：拿到当前窗体（未建窗时是 nil）。
function ReadyTracker.getFrame()
  return frame
end

ensureTicker()

MDT_NPT.ReadyTracker = ReadyTracker
