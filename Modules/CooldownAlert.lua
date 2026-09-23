local MDT_NPT = MDT_NPT
local L = MDT_NPT.L

local CooldownData = MDT_NPT.CooldownData

-- CooldownAlert: 波次推进时播报下一波计划里要开的爆发技能（设计 2026-09-22）。
-- 纯逻辑层——不创建任何 Frame。文字显示交给 AlertText，本模块只决定「何时说、说什么」。
local CooldownAlert = {}

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
