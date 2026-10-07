local MDT_NPT = MDT_NPT
local Theme = MDT_NPT.Theme

-- AlertBanner: 屏幕中部的瞬态提醒横幅（设计 §8；v2 起是图标横幅，不再是整句文字）。
-- 只负责显示，不含任何计划逻辑——播什么由 CooldownAlert 决定。
-- 图标比句子快得多：战斗正酣时眼睛扫一下就知道该开什么。
-- v3 把图标裁成圆形并带主题色圆环辉光——方形裸图标会被误认成动作条按钮。
-- v6 去掉背景底板与边框：真机观感底板太「UI」，辉光圆环已足够把整行聚成一个物件。
-- v7 去掉「下波」文字标签：真机反馈两个字是噪声，只留图标。
local AlertBanner = {}

local Y_OFFSET    = 120   -- 设计 §8.1：正中心会被角色模型和战斗文字压住，上移约 11% 屏高
local ICON_SIZE   = 44    -- 比信标格的 24px 大近一倍，全屏扫视才够醒目
local GLOW_SIZE   = ICON_SIZE * 1.5   -- 辉光要比图标外扩半格，圆环才不会被裁掉
local ICON_GAP    = 8
local PAD         = 10    -- 横幅框四边内衬（框本身不可见，只承担排版）
local MAX_ICONS   = 3     -- seed 表当前只有三项；真出现第四项时截断比溢出安全
local FADE_IN, HOLD, FADE_OUT = 0.15, 2.5, 0.6   -- 设计 §8.3：淡入 / 停留 / 淡出

-- 自带的白底贴图，运行时 SetVertexColor 染色：换主题色不用重新生成资产。
-- 不用暴雪圆形 atlas 也不用 LibCustomGlow 的 proc 贴图——那是方形动作条视觉语言，正是 v3 要摆脱的。
local ADDON_MEDIA = "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\"
local CIRCLE_MASK = ADDON_MEDIA .. "circle_mask.png"
local RING_GLOW   = ADDON_MEDIA .. "ring_glow.png"

local frame, icons, glows, anim

local function applyStyle()
  -- 圆环辉光吃主题色；EUI 换色后 Refresh 回调会整体重染。
  local color = Theme.colors.accent
  for i = 1, MAX_ICONS do
    glows[i]:SetVertexColor(color[1], color[2], color[3], 1)
  end
end

local function ensureFrame()
  if frame then return frame end

  local f = CreateFrame("Frame", "MDTNPTAlertBanner", UIParent)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetPoint("CENTER", UIParent, "CENTER", 0, Y_OFFSET)
  f:EnableMouse(false)   -- 绝不拦截点击：提醒出现在战斗正酣的时候
  f:Hide()

  local texs, glowTexs = {}, {}
  for i = 1, MAX_ICONS do
    local glow = f:CreateTexture(nil, "OVERLAY")
    glow:SetSize(GLOW_SIZE, GLOW_SIZE)
    glow:SetTexture(RING_GLOW)

    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetSize(ICON_SIZE, ICON_SIZE)
    -- 与信标格同一裁切系数，去掉图标自带的黑边
    t:SetTexCoord(0.055, 0.945, 0.055, 0.945)
    -- 每槽一张独立 mask：圆形裁切让方形图标彻底告别动作条观感。
    local mask = f:CreateMaskTexture()
    mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(t)
    t:AddMaskTexture(mask)

    -- 辉光钉在图标中心：Show 里挪图标时辉光自动跟随，不必二次排版。
    glow:SetPoint("CENTER", t, "CENTER", 0, 0)
    glow:Hide()
    t:Hide()
    texs[i] = t
    glowTexs[i] = glow
  end

  -- 动画组建在横幅框上：Alpha 淡掉整个物件，Scale 同组同序弹出——一体感的关键。
  local ag = f:CreateAnimationGroup()
  local pop = ag:CreateAnimation("Scale")
  pop:SetOrder(1); pop:SetOrigin("CENTER", 0, 0)
  -- 12.x 的方法名是 SetScaleFrom/SetScaleTo：旧名 SetFromScale/SetToScale 只活在
  -- LibDFramework 之类的老库里，零售客户端上调用它们是 nil（真机炸过一轮）。
  pop:SetScaleFrom(0.9, 0.9); pop:SetScaleTo(1, 1); pop:SetDuration(FADE_IN)
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
  frame, icons, glows, anim = f, texs, glowTexs, ag
  applyStyle()

  -- EUI 主题变化后重新取字体文件与主题色（Theme.lua:253）。
  if Theme.RegisterRefreshCallback then
    Theme.RegisterRefreshCallback(applyStyle)
  end

  return frame
end

---显示横幅：至多 MAX_ICONS 个圆形发光图标，框内左起排版（整框居中于屏幕）。
---@param iconList string[] 贴图路径，顺序即显示顺序
function AlertBanner:Show(iconList)
  if not iconList or #iconList == 0 then return end
  ensureFrame()

  local n = math.min(#iconList, MAX_ICONS)
  for i = 1, MAX_ICONS do
    if i <= n then
      icons[i]:SetTexture(iconList[i])
      icons[i]:Show()
      glows[i]:Show()
    else
      icons[i]:Hide()
      glows[i]:Hide()
    end
  end

  frame:SetSize(PAD * 2 + n * ICON_SIZE + (n - 1) * ICON_GAP, PAD * 2 + ICON_SIZE)

  local x = PAD
  for i = 1, n do
    icons[i]:ClearAllPoints()
    icons[i]:SetPoint("LEFT", frame, "LEFT", x, 0)
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
