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
  print("|cff00ff00[MDT]|r No text-to-speech voice is available; cooldown alerts will show text only.")
end

---12.x 的签名是 SpeakText(voiceID, text, rate, volume[, overlap])——destination
---参数已被移除，换成可选的 overlap。整句提醒是一次调用，不存在自我重叠，所以
---overlap 留默认。不包 pcall：.toc 只声明 120100，写对的调用并在 spec 里精确
---mock，比兜住一个不该发生的错误更有价值（参见 commit ee6b01a）。
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

-- 组装播报文本；没有任何 use 条目时返回 nil（完全静默，设计 §6.1、决策 3）。
--
-- 逆序遍历是必须的，不是笔误：getActiveEntries 按 seed 顺序返回
-- [升腾, 爆发药水, 嗜血]，而 layoutRow（CooldownPlanRender.lua:198）是右对齐的
-- ——entry 1 贴行右边缘、后续向左堆，所以信标上从左到右读作
-- [嗜血][爆发药水][升腾]。倒着念才和眼睛扫过图标行的方向一致（设计 §6.2）。
function CooldownAlert.buildText(dbChar, uid, pullIndex)
  local entries = CooldownData.getActiveEntries(dbChar, uid, pullIndex)
  if not entries or #entries == 0 then return nil end

  local parts = {}
  for i = #entries, 1, -1 do
    local entry = entries[i]
    if entry.plan and entry.plan.action == "use" then
      -- seed.name 兜底：新增 seed 忘了配 locale 时降级成英文，而不是
      -- format(nil) 在大秘境中途抛错。Locales_spec 会先一步拦住这种遗漏。
      parts[#parts + 1] = L["Next Pull Alert - %s"]:format(L[entry.seed.name] or entry.seed.name)
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, L["Alert List Joiner"])
end

MDT_NPT.CooldownAlert = CooldownAlert
