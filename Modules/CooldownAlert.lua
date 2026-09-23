local MDT_NPT = MDT_NPT
local L = MDT_NPT.L

local CooldownData = MDT_NPT.CooldownData

-- CooldownAlert: 波次推进时播报下一波计划里要开的爆发技能（设计 2026-09-22）。
-- 纯逻辑层——不创建任何 Frame。文字显示交给 AlertText，本模块只决定「何时说、说什么」。
local CooldownAlert = {}

-- 无可用 TTS 语音时只提示一次（沿用 BeaconState.corruptionWarned 的手法）。
local ttsWarned = false
local function warnNoVoiceOnce()
  if ttsWarned then return end
  ttsWarned = true
  print("|cff00ff00[MDT]|r No text-to-speech voice is available; cooldown alerts cannot be spoken.")
end

---12.x 的签名是 SpeakText(voiceID, text, rate, volume[, overlap])——destination
---参数已被移除，换成可选的 overlap。整句提醒是一次调用，不存在自我重叠，所以
---overlap 留默认。不包 pcall：.toc 只声明 120100，写对的调用并在 spec 里精确
---mock，比兜住一个不该发生的错误更有价值。
---@return boolean spoke  false 表示没有可用语音，调用方不必重试
function CooldownAlert.speak(text)
  if not (C_VoiceChat and C_VoiceChat.SpeakText) then
    warnNoVoiceOnce()
    return false
  end

  local voiceID
  if C_TTSSettings and C_TTSSettings.GetVoiceOptionID and Enum and Enum.TtsVoiceType then
    voiceID = C_TTSSettings.GetVoiceOptionID(Enum.TtsVoiceType.Standard)
  end
  if not voiceID then
    local voices = C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()
    voiceID = voices and voices[1] and voices[1].voiceID
  end
  if not voiceID then
    warnNoVoiceOnce()
    return false
  end

  -- 音色/语速/音量全部跟随客户端自带的 TTS 设置，不新增选项（决策 5）。
  -- volume 的量纲是 0-100，不是 0-1。
  local rate = (C_TTSSettings and C_TTSSettings.GetSpeechRate and C_TTSSettings.GetSpeechRate()) or 0
  local volume = (C_TTSSettings and C_TTSSettings.GetSpeechVolume and C_TTSSettings.GetSpeechVolume()) or 100

  C_VoiceChat.SpeakText(voiceID, text, rate, volume)
  return true
end

---组装播报文本；没有任何 use 条目时返回 nil（完全静默，设计 §6.1、决策 3）。
---
---逆序遍历是必须的，不是笔误：getActiveEntries 按 seed 顺序返回
---[升腾, 爆发药水, 嗜血]，而 layoutRow（CooldownPlanRender.lua:198）是右对齐的
---——entry 1 贴行右边缘、后续向左堆，所以信标上从左到右读作
---[嗜血][爆发药水][升腾]。倒着念才和眼睛扫过图标行的方向一致（设计 §6.2）。
function CooldownAlert.buildText(dbChar, uid, pullIndex)
  local entries = CooldownData.getActiveEntries(dbChar, uid, pullIndex)
  if not entries or #entries == 0 then return nil end

  local parts = {}
  for i = #entries, 1, -1 do
    local entry = entries[i]
    if entry.plan and entry.plan.action == "use" then
      -- seed.name 兜底：Locales_spec 只能守住今天已有的 seed，将来新增 seed 忘了配
      -- locale 时，这里降级成英文键名，而不是 format(nil) 在大秘境中途抛错。
      parts[#parts + 1] = L["Next Pull Alert - %s"]:format(L[entry.seed.name] or entry.seed.name)
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, L["Alert List Joiner"])
end

-- 去抖延迟（秒）。中途开局时 Start 会先为 pull 1 排定一次播报，随后第一次力量值
-- 轮询把已清完的波次一次性吃掉、推进到真正的当前波并重排一次；没有去抖就会连播
-- 两条，而第一条已经过期（设计 §5.2）。这不是优化，是正确性要求。
--
-- 不变量：本值必须**大于** Core.lua:307 那个 NewTicker(1.0) 的轮询周期。
-- 否则 Start 排定的那次会在轮询有机会取消它之前就播出去，去抖形同不存在
-- ——0.75 曾经就是这样，中途开局照样双播。改轮询周期的人必须同步改这里。
--
-- 必须用 C_Timer.NewTimer 而不是 C_Timer.After：After 在零售客户端不返回句柄，
-- 取消不了，去抖会静默失效（Core.lua 的 NewTicker 同理才拿得到 :Cancel()）。
local ANNOUNCE_DELAY = 1.25

local lastKey
local pending

local function cancelPending()
  if pending then pending:Cancel() end
  pending = nil
end

---读开关并输出。去抖定时器与 SpeakNow 共用这一份实现，两条入口不会走偏。
---开关在**播出时**读取，而不是排定时——用户在去抖窗口内关掉语音应当立刻生效。
---@return string|nil 实际播报的文本；没有内容时为 nil
local function fire(uid, pullIndex)
  local db = MDT_NPT:GetDB()
  if not db or not db.beacon then return nil end   -- 设计 §11：ADDON_LOADED 之前的极早期
  local beacon = db.beacon

  local text = CooldownAlert.buildText(MDT_NPT:GetDBChar(), uid, pullIndex)
  if not text then return nil end

  if beacon.alertVoice then CooldownAlert.speak(text) end
  if beacon.alertText and MDT_NPT.AlertText then MDT_NPT.AlertText:Show(text) end
  return text
end

---UpdateAll 的挂钩点。去重键 = presetUID#pullIndex，因此设置面板改动、
---每秒力量值轮询这些不改变波次的调用都不会重复播报；而 revert 把波次号退回
---N-1 时键变化，会重新播报——回退后玩家确实需要重新听到那一波的计划。
function CooldownAlert:OnUpdateAll()
  local state = MDT_NPT.state
  if not state or not state.active then
    self:Reset()
    return
  end
  local uid = CooldownData.getPlanKey(state)
  local pullIndex = state.currentNextPull
  if not uid or not pullIndex then
    self:Reset()
    return
  end

  local key = uid .. "#" .. pullIndex
  if key == lastKey then return end
  lastKey = key

  cancelPending()
  pending = C_Timer.NewTimer(ANNOUNCE_DELAY, function()
    pending = nil
    fire(uid, pullIndex)
  end)
end

---清去重键、取消待定播报、收起屏幕上正在显示的提醒。Stop() 把 state 置 nil 后
---会经 UpdateAll 走到这里，所以下次开始追踪不会被上一次的键挡住，
---而已经淡入到一半的那条也不会挂在没有追踪的画面上继续播完。
function CooldownAlert:Reset()
  lastKey = nil
  cancelPending()
  if MDT_NPT.AlertText then MDT_NPT.AlertText:Hide() end
end

---/npt alert：绕过去重与去抖，立即播报当前 NEXT 波（设计 §10）。
---@return string|nil 播出去的文本；无内容或未在追踪时为 nil
function CooldownAlert:SpeakNow()
  local state = MDT_NPT.state
  if not state or not state.active then return nil end
  local uid = CooldownData.getPlanKey(state)
  if not uid or not state.currentNextPull then return nil end
  return fire(uid, state.currentNextPull)
end

MDT_NPT.CooldownAlert = CooldownAlert
