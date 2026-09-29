local MDT_NPT = MDT_NPT
local L = MDT_NPT.L
local Theme = MDT_NPT.Theme

-- AlertBanner: 屏幕中部的瞬态提醒横幅（设计 §8；v2 起是「下一波」标签 + 图标，
-- 不再是整句文字）。只负责显示，不含任何计划逻辑——播什么由 CooldownAlert 决定。
-- 图标比句子快得多：战斗正酣时眼睛扫一下就知道该开什么。
local AlertBanner = {}

local Y_OFFSET    = 120   -- 设计 §8.1：正中心会被角色模型和战斗文字压住，上移约 11% 屏高
local ICON_SIZE   = 44    -- 比信标格的 24px 大近一倍，全屏扫视才够醒目
local ICON_GAP    = 8
local LABEL_GAP   = 10
local LABEL_SIZE  = 28
local LABEL_FLAGS = "THICKOUTLINE"
local MAX_ICONS   = 3     -- seed 表当前只有三项；真出现第四项时截断比溢出安全
local FADE_IN, HOLD, FADE_OUT = 0.15, 2.5, 0.6   -- 设计 §8.3：淡入 / 停留 / 淡出

local frame, label, icons, anim

-- 字体文件优先取 EUI 主题字体，否则取暴雪当前语言的字体文件——不硬编码路径。
-- 不新增 Theme 字体槽：Theme.refreshFonts() 只在 EUI 存在时运行，非 EUI 环境下
-- Theme.fonts.* 只会拿到 GameFontNormalLarge（14pt），对全屏提醒太小（设计 §8.2）。
local function applyStyle()
  local file = Theme.GetFontPath() or GameFontNormalLarge:GetFont()
  -- 描边必须走 SetFont 的 flags：12.x 客户端没有 FontString:SetOutlined。
  label:SetFont(file, LABEL_SIZE, LABEL_FLAGS)
  local color = Theme.colors.accent
  label:SetTextColor(color[1], color[2], color[3], 1)
end

local function ensureFrame()
  if frame then return frame end

  local f = CreateFrame("Frame", "MDTNPTAlertBanner", UIParent)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetPoint("CENTER", UIParent, "CENTER", 0, Y_OFFSET)
  f:EnableMouse(false)   -- 绝不拦截点击：提醒出现在战斗正酣的时候
  f:Hide()

  local lb = f:CreateFontString(nil, "OVERLAY")
  lb:SetJustifyH("LEFT")
  lb:SetJustifyV("MIDDLE")

  local texs = {}
  for i = 1, MAX_ICONS do
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetSize(ICON_SIZE, ICON_SIZE)
    -- 与信标格同一裁切系数，去掉图标自带的黑边
    t:SetTexCoord(0.055, 0.945, 0.055, 0.945)
    t:Hide()
    texs[i] = t
  end

  -- 动画组建在 Frame 上：一次 Alpha 同时淡掉标签和全部图标。
  local ag = f:CreateAnimationGroup()
  local fadeIn = ag:CreateAnimation("Alpha")
  fadeIn:SetOrder(1); fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(1); fadeIn:SetDuration(FADE_IN)
  local hold = ag:CreateAnimation("Alpha")
  hold:SetOrder(2); hold:SetFromAlpha(1); hold:SetToAlpha(1); hold:SetDuration(HOLD)
  local fadeOut = ag:CreateAnimation("Alpha")
  fadeOut:SetOrder(3); fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0); fadeOut:SetDuration(FADE_OUT)
  ag:SetScript("OnFinished", function() f:Hide() end)

  -- 全部建成之后才落地上值。中途抛错若已经把 frame 赋上，下面的
  -- `if frame then return frame end` 就会永久跳过剩下的构建，
  -- 留下一个没有 OnFinished 处理器的框——提醒再也藏不掉。
  frame, label, icons, anim = f, lb, texs, ag
  applyStyle()

  -- EUI 主题变化后重新取字体文件与主题色（Theme.lua:253）。
  if Theme.RegisterRefreshCallback then
    Theme.RegisterRefreshCallback(applyStyle)
  end

  return frame
end

---显示横幅：标签 + 至多 MAX_ICONS 个图标，整行水平居中。
---@param iconList string[] 贴图路径，顺序即显示顺序
function AlertBanner:Show(iconList)
  if not iconList or #iconList == 0 then return end
  ensureFrame()

  label:SetText(L["Next Pull"])
  local n = math.min(#iconList, MAX_ICONS)
  for i = 1, MAX_ICONS do
    if i <= n then
      icons[i]:SetTexture(iconList[i])
      icons[i]:Show()
    else
      icons[i]:Hide()
    end
  end

  -- 先量标签宽度再排：中文「下一波」和英文 "Next pull" 宽度差很多，
  -- 写死偏移会让其中一种语言偏出中心。
  local labelW = label:GetStringWidth()
  local total = labelW + LABEL_GAP + n * ICON_SIZE + (n - 1) * ICON_GAP
  frame:SetSize(total, ICON_SIZE)

  local x = -total / 2
  label:ClearAllPoints()
  label:SetPoint("LEFT", frame, "CENTER", x, 0)
  x = x + labelW + LABEL_GAP
  for i = 1, n do
    icons[i]:ClearAllPoints()
    icons[i]:SetPoint("LEFT", frame, "CENTER", x, 0)
    x = x + ICON_SIZE + ICON_GAP
  end

  frame:Show()
  -- 重入：新提醒立刻顶掉旧的，而不是等上一条播完（设计 §8.3）。
  if anim:IsPlaying() then anim:Stop() end
  -- 不必先 SetAlpha(1)：第一段的 SetFromAlpha(0) 每次 Play 都从 0 重新驱动，
  -- 上一轮停在哪个透明度都无所谓。
  anim:Play()
end

function AlertBanner:Hide()
  if not frame then return end
  if anim:IsPlaying() then anim:Stop() end
  frame:Hide()
end

MDT_NPT.AlertBanner = AlertBanner
