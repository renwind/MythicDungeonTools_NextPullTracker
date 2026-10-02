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
local MIN_W, MAX_W = 60, 240     -- 格边长 24..114：再小塞不下倒计时，再大抢屏幕

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

-- 宽度决定一切：格边长由窗宽推出，字号随边长等比，高度跟随边长。
-- 只支持横向缩放（"RIGHT"）：单行控件没有第二个自由度，二维拖拽只会拖出无效高度。
local function applySize(f, width)
  local cell = (width - GAP - PAD * 2) / 2
  for _, c in ipairs({ f.lustCell, f.potionCell }) do
    c:SetSize(cell, cell)
    if c.textBase then
      local size = math.floor(c.textBase[2] * cell / CELL + 0.5)
      c.text:SetFont(c.textBase[1], math.max(8, size), c.textBase[3])
    end
    local _, fontSize = c.text:GetFont()
    c.textBg:SetSize(cell, fontSize + 4)
  end
  f:SetSize(width, cell + PAD * 2)
end

local function saveSize(f)
  local db = MDT_NPT:GetDB()
  if not (db and db.beacon) then return end
  db.beacon.readyTrackerWidth = f:GetWidth()
end

local function ensureFrame()
  if frame then return frame end
  frame = CreateFrame("Frame", "MDTNPTReadyTracker", UIParent)
  -- HIGH 而非 FULLSCREEN_DIALOG：常驻工具窗，不该压过瞬时提醒横幅。
  frame:SetFrameStrata("HIGH")
  -- 点击穿透是默认态：对照窗与信标一样浮在战斗画面上，空白区要把点击让给后面的怪。
  -- Alt 按住才恢复鼠标，拖动与缩放只在那时生效（与 BeaconFrame 的 applyClickThrough 同语言）。
  frame:EnableMouse(false)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetResizable(true)
  frame:SetResizeBounds(MIN_W, 20, MAX_W, 200)
  frame.potionCell = Lust.makeCell(frame, true)
  frame.potionCell:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
  frame.lustCell = Lust.makeCell(frame, true)
  frame.lustCell:SetPoint("TOPLEFT", frame.potionCell, "TOPRIGHT", GAP, 0)
  for _, cell in ipairs({ frame.lustCell, frame.potionCell }) do
    cell.textBg = cell:CreateTexture(nil, "BACKGROUND")
    cell.textBg:SetPoint("BOTTOMLEFT", cell, "TOPLEFT", 0, 0)
    cell.textBg:SetColorTexture(0, 0, 0, 0.65)
    cell.textBg:Hide()
    cell.text:ClearAllPoints()
    cell.text:SetPoint("CENTER", cell.textBg, "CENTER", 0, 0)
  end
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePos(self)
  end)
  -- 缩放把手：右缘细条，横向拖改宽度；鼠标跟随 Alt，穿透态不能独自吃点击。
  local grip = CreateFrame("Frame", nil, frame)
  grip:SetWidth(6)
  grip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
  grip:EnableMouse(false)
  grip.tex = grip:CreateTexture(nil, "OVERLAY")
  grip.tex:SetAllPoints(grip)
  grip.tex:SetColorTexture(0.35, 0.35, 0.35, 0.5)
  grip.tex:Hide()  -- 悬停才显形：常驻灰条在屏幕上像个异物
  local sizing
  -- 松开 Alt 也算松手：OnDragStop/OnMouseUp 不会触发，收尾必须主动做（信标同款教训）。
  local function finalize()
    sizing = false
    frame:StopMovingOrSizing()
    applySize(frame, frame:GetWidth())
    savePos(frame)
    saveSize(frame)
  end
  grip:SetScript("OnEnter", function() grip.tex:Show() end)
  grip:SetScript("OnLeave", function() if not sizing then grip.tex:Hide() end end)
  grip:SetScript("OnMouseDown", function()
    sizing = true
    frame:StartSizing("RIGHT")
  end)
  grip:SetScript("OnMouseUp", function()
    finalize()
    if not grip:IsMouseOver() then grip.tex:Hide() end
  end)
  frame.grip = grip
  local function applyClickThrough()
    local interactive = IsAltKeyDown() and true or false
    if not interactive and frame:IsMouseEnabled() then finalize() end
    frame:EnableMouse(interactive)
    grip:EnableMouse(interactive)
    if not interactive then grip.tex:Hide() end
  end
  frame:RegisterEvent("MODIFIER_STATE_CHANGED")
  frame:SetScript("OnEvent", function(_, event)
    -- 直接重读 Alt、不解析事件的键参数：左右 Alt 都覆盖，别的键触发也能自纠正（信标同款手法）。
    if event == "MODIFIER_STATE_CHANGED" then applyClickThrough() end
  end)
  applyClickThrough()
  local db = MDT_NPT:GetDB()
  local beacon = db and db.beacon
  local width = beacon and beacon.readyTrackerWidth
  if type(width) ~= "number" then width = CELL * 2 + GAP + PAD * 2 end
  applySize(frame, math.min(math.max(width, MIN_W), MAX_W))
  local pos = beacon and beacon.readyTrackerPos
  if pos and pos[1] then
    frame:SetPoint(pos[1], UIParent, "CENTER", pos[2] or 0, pos[3] or 0)
  else
    -- 默认位：屏幕中上，避开 +120 处的提醒横幅。
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 240)
  end
  frame:Hide()
  return frame
end

local function tintBorders(f, c)
  for _, cell in ipairs({ f.lustCell, f.potionCell }) do
    for _, key in ipairs(BORDER_KEYS) do
      cell[key]:SetColorTexture(c[1], c[2], c[3], c[4])
    end
  end
end

local function paint(f)
  Theme.Refresh()
  local lustReady, sid = Lust.lustReadyIn()
  local potionReady = Lust.potionReadyIn()
  Lust.paintCell(f.lustCell, lustReady, sid and C_Spell.GetSpellTexture(sid))
  Lust.paintCell(f.potionCell, potionReady, potionIcon())
  if lustReady > 0 then f.lustCell.textBg:Show() else f.lustCell.textBg:Hide() end
  if potionReady > 0 then f.potionCell.textBg:Show() else f.potionCell.textBg:Hide() end
  tintBorders(f, Theme.colors.accent)
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
