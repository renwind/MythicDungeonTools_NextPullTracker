local MDT_NPT = MDT_NPT
local Theme = MDT_NPT.Theme

-- AlertText: 屏幕中部的瞬态大字提醒（设计 §8）。只负责显示，不含任何计划逻辑——
-- 说什么由 CooldownAlert 决定，这里只管怎么画出来。
local AlertText = {}

local Y_OFFSET     = 120   -- 设计 §8.1：正中心会被角色模型和战斗文字压住，上移约 11% 屏高
local MAX_WIDTH    = 900   -- 设计 §8.1：FontString 的换行宽度约束（UI 像素，非物理像素）
local FRAME_HEIGHT = 80    -- 设计 §8.1：不裁剪文字，多行照样渲染；调它不影响显示
local FONT_SIZE    = 30    -- 设计 §8.1：全屏提醒必须显式设字号，Theme 字体槽最大只有 14pt
local FONT_FLAGS   = "THICKOUTLINE"
local FADE_IN, HOLD, FADE_OUT = 0.15, 2.5, 0.6   -- 设计 §8.3：淡入 / 停留 / 淡出

local frame, text, anim

-- 字体文件优先取 EUI 主题字体，否则取暴雪当前语言的字体文件——不硬编码路径。
-- 不新增 Theme 字体槽：Theme.refreshFonts() 只在 EUI 存在时运行，非 EUI 环境下
-- Theme.fonts.* 只会拿到 GameFontNormalLarge（14pt），对全屏提醒太小（设计 §8.2）。
-- 字体文件与主题色都要能重取：Theme.Refresh() 就地改 Theme.colors.accent，
-- EUI 换主题/换配色后，只在创建期快照一次的话提醒会留在旧颜色上。
local function applyStyle()
  local file = Theme.GetFontPath() or GameFontNormalLarge:GetFont()
  -- 描边必须走 SetFont 的 flags：12.x 客户端没有 FontString:SetOutlined。
  text:SetFont(file, FONT_SIZE, FONT_FLAGS)
  local color = Theme.colors.accent
  text:SetTextColor(color[1], color[2], color[3], 1)
end

local function ensureFrame()
  if frame then return frame end

  local f = CreateFrame("Frame", "MDTNPTAlertText", UIParent)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetPoint("CENTER", UIParent, "CENTER", 0, Y_OFFSET)
  f:SetSize(MAX_WIDTH, FRAME_HEIGHT)
  f:EnableMouse(false)   -- 绝不拦截点击：提醒出现在战斗正酣的时候
  f:Hide()

  local fs = f:CreateFontString(nil, "OVERLAY")
  fs:SetPoint("CENTER", f, "CENTER", 0, 0)
  fs:SetWidth(MAX_WIDTH)
  fs:SetJustifyH("CENTER")
  fs:SetJustifyV("MIDDLE")
  fs:SetWordWrap(true)
  -- SetWordWrap 只在空格处断行；zhCN 用全角逗号连接，整句没有空格，超宽会被省略号
  -- 截断而不是换行。暴雪自己的聊天气泡也成对设这两个（ChatBubbleTemplates.xml）。
  fs:SetNonSpaceWrap(true)

  -- 动画组建在 FontString 上而不是 Frame 上：Alpha 动画对文字区是明确定义的。
  local ag = fs:CreateAnimationGroup()
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
  frame, text, anim = f, fs, ag
  applyStyle()

  -- EUI 主题变化后重新取字体文件与主题色（Theme.lua:253）。
  if Theme.RegisterRefreshCallback then
    Theme.RegisterRefreshCallback(applyStyle)
  end

  return frame
end

function AlertText:Show(message)
  if not message or message == "" then return end
  ensureFrame()
  text:SetText(message)
  frame:Show()
  -- 重入：新提醒立刻顶掉旧的，而不是等上一条播完（设计 §8.3）。
  if anim:IsPlaying() then anim:Stop() end
  -- 不必先 SetAlpha(1)：第一段的 SetFromAlpha(0) 每次 Play 都从 0 重新驱动，
  -- 上一轮停在哪个透明度都无所谓。
  anim:Play()
end

function AlertText:Hide()
  if not frame then return end
  if anim:IsPlaying() then anim:Stop() end
  frame:Hide()
end

MDT_NPT.AlertText = AlertText
