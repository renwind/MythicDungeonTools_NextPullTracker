local MDT_NPT = MDT_NPT

local CooldownData = MDT_NPT.CooldownData

-- CooldownAlert: 波次推进时提醒下一波计划里要开的爆发技能（设计 2026-09-22）。
-- v2 起不再用客户端 TTS 念句子：本模块只决定「何时提醒、播哪条内置录音、
-- 把哪几个图标交给横幅」。纯逻辑层——不创建任何 Frame，声音走 PlaySoundFile，
-- 画面由 AlertBanner 画出来。
local CooldownAlert = {}

-- 音频文件名片段：seed.name -> 文件名。组合键按播报顺序拼接（见 buildItems 的逆序）。
local AUDIO_TAG = {
  Bloodlust = "lust",
  ["Burst Potion"] = "potion",
  Ascendance = "asc",
}

-- 图标取法与信标格一致（CooldownPlanRender.resolveEntry 的图标那一半）：
-- 法术走 seed.id（族内多 ID 时取第一个已知且有贴图的），物品走当前配置的药水 ID。
local function seedIcon(seed, dbChar)
  if seed.kind == "item" then
    local itemID = (dbChar and dbChar.cooldownPotionID) or seed.defaultItemID
    return itemID and C_Item.GetItemIconByID(itemID)
  end
  local id = seed.id
  if type(id) == "table" then id = CooldownData.resolveAscendanceID(id) end
  return C_Spell.GetSpellTexture(id)
end

---组装下一波的提醒内容；没有任何 use 条目时返回 nil（完全静默，设计 §6.1、决策 3）。
---
---逆序遍历是必须的，不是笔误：getActiveEntries 按 seed 顺序返回
---[升腾, 爆发药水, 嗜血]，而 layoutRow（CooldownPlanRender.lua:198）是右对齐的
---——entry 1 贴行右边缘、后续向左堆，所以信标上从左到右读作
---[嗜血][爆发药水][升腾]。图标横幅与音频句子都按这个方向，才和眼睛扫过
---图标行的顺序一致（设计 §6.2）。
---@return table|nil items { icons = string[], audioKey = string }
function CooldownAlert.buildItems(dbChar, uid, pullIndex)
  local entries = CooldownData.getActiveEntries(dbChar, uid, pullIndex)
  if not entries or #entries == 0 then return nil end

  local icons, tags = {}, {}
  for i = 1, #entries do
    local entry = entries[i]
    if entry.plan and entry.plan.action == "use" then
      icons[#icons + 1] = seedIcon(entry.seed, dbChar)
      tags[#tags + 1] = AUDIO_TAG[entry.seed.name] or entry.seed.name
    end
  end
  if #icons == 0 then return nil end
  return { icons = icons, audioKey = table.concat(tags, "-") }
end

-- 录音只做了中英两套；其余客户端语言回落英文，总比没声音好。
local VOICE_DIR = { zhCN = "zh-CN" }

---播放内置录音。路径缺失时 PlaySoundFile 静默不响、不抛错，所以不需要存在性检查。
---@param audioKey string buildItems 给出的组合键，如 "lust-potion-asc"
function CooldownAlert.play(audioKey)
  local dir = VOICE_DIR[GetLocale()] or "en-US"
  -- 目录名来自 .pkgmeta 的 package-as，打包后不会变。
  local path = "Interface\\AddOns\\MythicDungeonTools_NextPullTracker\\Media\\voice\\"
    .. dir .. "\\" .. audioKey .. ".mp3"
  -- Master 声道：与本机所有喊话类插件（EUI/SeUI/TitanMedia 的 PlaySoundFile 调用）一致，
  -- 保证一定听得到；单独的静音需求由设置里的「语音提醒」开关承担。
  PlaySoundFile(path, "Master")
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
---@return table|nil items 实际播出的提醒内容；没有内容时为 nil
local function fire(uid, pullIndex)
  local db = MDT_NPT:GetDB()
  if not db or not db.beacon then return nil end   -- 设计 §11：ADDON_LOADED 之前的极早期
  local beacon = db.beacon

  local items = CooldownAlert.buildItems(MDT_NPT:GetDBChar(), uid, pullIndex)
  if not items then return nil end

  if beacon.alertVoice then CooldownAlert.play(items.audioKey) end
  if beacon.alertText and MDT_NPT.AlertBanner then MDT_NPT.AlertBanner:Show(items.icons) end
  return items
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

---清去重键、取消待定播报、收起屏幕上正在显示的横幅。Stop() 把 state 置 nil 后
---会经 UpdateAll 走到这里，所以下次开始追踪不会被上一次的键挡住，
---而已经淡入到一半的那条横幅也不会挂在没有追踪的画面上继续播完。
function CooldownAlert:Reset()
  lastKey = nil
  cancelPending()
  if MDT_NPT.AlertBanner then MDT_NPT.AlertBanner:Hide() end
end

---/npt alert：绕过去重与去抖，立即播报当前 NEXT 波（设计 §10）。
---@return table|nil items 播出去的提醒内容；无内容或未在追踪时为 nil
function CooldownAlert:SpeakNow()
  local state = MDT_NPT.state
  if not state or not state.active then return nil end
  local uid = CooldownData.getPlanKey(state)
  if not uid or not state.currentNextPull then return nil end
  return fire(uid, state.currentNextPull)
end

MDT_NPT.CooldownAlert = CooldownAlert
