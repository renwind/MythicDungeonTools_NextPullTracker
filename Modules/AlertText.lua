local MDT_NPT = MDT_NPT
local Theme = MDT_NPT.Theme

-- AlertText: 屏幕中部的瞬态大字提醒（设计 §8）。只负责显示，不含任何计划逻辑——
-- 说什么由 CooldownAlert 决定，这里只管怎么画出来。
local AlertText = {}

local Y_OFFSET   = 120   -- 正中心会被角色模型和战斗文字压住，上移约 11% 屏高
local MAX_WIDTH  = 900   -- FontString 的换行宽度约束
local BOX_HEIGHT = 80
local FONT_SIZE  = 30
local FONT_FLAGS = "THICKOUTLINE"
local FADE_IN, HOLD, FADE_OUT = 0.15, 2.5, 0.6

local frame, text, anim

-- 字体文件优先取 EUI 主题字体，否则取暴雪当前语言的字体文件——不硬编码路径。
-- 不新增 Theme 字体槽：Theme.refreshFonts() 只在 EUI 存在时运行，非 EUI 环境下
-- Theme.fonts.* 只会拿到 GameFontNormalLarge（14pt），对全屏提醒太小（设计 §8.2）。
-- 描边必须走 SetFont 的 flags：12.x 客户端没有 FontString:SetOutlined。
local function applyFont()
  local file = (Theme.GetFontPath and Theme.GetFontPath()) or GameFontNormalLarge:GetFont()
  if not file then return end
  text:SetFont(file, FONT_SIZE, FONT_FLAGS)
end

local function ensureFrame()
  if frame then return frame end

  frame = CreateFrame("Frame", "MDTNPTAlertText", UIParent)
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, Y_OFFSET)
  frame:SetSize(MAX_WIDTH, BOX_HEIGHT)
  frame:EnableMouse(false)   -- 绝不拦截点击：提醒出现在战斗正酣的时候
  frame:Hide()

  text = frame:CreateFontString(nil, "OVERLAY")
  text:SetPoint("CENTER", frame, "CENTER", 0, 0)
  text:SetWidth(MAX_WIDTH)
  text:SetJustifyH("CENTER")
  text:SetJustifyV("MIDDLE")
  text:SetWordWrap(true)
  applyFont()

  local color = Theme.colors.accent
  text:SetTextColor(color[1], color[2], color[3], 1)
  text:SetShadowColor(0, 0, 0, 1)
  text:SetShadowOffset(1, -1)

  -- 动画组建在 FontString 上：Alpha 动画对文字区是明确定义的。
  anim = text:CreateAnimationGroup()
  local fadeIn = anim:CreateAnimation("Alpha")
  fadeIn:SetOrder(1); fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(1); fadeIn:SetDuration(FADE_IN)
  local hold = anim:CreateAnimation("Alpha")
  hold:SetOrder(2); hold:SetFromAlpha(1); hold:SetToAlpha(1); hold:SetDuration(HOLD)
  local fadeOut = anim:CreateAnimation("Alpha")
  fadeOut:SetOrder(3); fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0); fadeOut:SetDuration(FADE_OUT)
  anim:SetOnFinished(function() frame:Hide() end)

  -- EUI 主题变化后重新取字体文件（Theme.lua:253）。
  if Theme.RegisterRefreshCallback then
    Theme.RegisterRefreshCallback(function()
      if text then applyFont() end
    end)
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
  anim:Play()
end

function AlertText:Hide()
  if not frame then return end
  if anim:IsPlaying() then anim:Stop() end
  frame:Hide()
end

MDT_NPT.AlertText = AlertText
