local MDT_NPT = MDT_NPT
local MDT = MDT_NPT.MDT or MDT
local Theme = MDT_NPT.Theme

---Single source of truth for mob-type colouring, shared by the BeaconFrame
---portrait rings and the minimap's current-wave dots. Mob typing comes from
---static MDT data only (no nameplate parsing, to keep M+ frames cheap).

local MobStyle = {}

-- caster shares the accent table reference, so the kick cyan auto-follows EUI
-- (same auto-follow pattern as pullColors["next"] in Theme.lua) and matches the
-- note-strip rings: the old flat #4CE0D2 read as gray-white at 1px ring width.
MobStyle.colors = {
  caster   = Theme.colors.accent,
  miniboss = Theme.colors.mobMiniboss,
  boss     = Theme.colors.mobBoss,
  other    = Theme.colors.mobOther,
}

MobStyle.gray = { 0.55, 0.55, 0.55 } -- low efficiency (score < 1)

local ELITE_LEVEL = 91 -- MDT enemy level tier: <=90 normal, ==91 elite, >91 boss

---Static caster signal from MDT: Enemy Info lists the mob's spells; any spell
---flagged interruptible means the mob casts (mirrors MDT's right-click Enemy
---Info spell list).
function MobStyle.hasInterruptibleSpell(enemy)
  if not enemy.spells then return false end
  for _, flags in pairs(enemy.spells) do
    if flags and flags.interruptible then return true end
  end
  return false
end

---Level tiers per MDT enemy info. Priority: boss > elite > caster > other.
function MobStyle.typeOf(enemy)
  local level = enemy.level or 0
  if enemy.isBoss or level > ELITE_LEVEL then return "boss" end
  if level == ELITE_LEVEL then return "miniboss" end
  if MobStyle.hasInterruptibleSpell(enemy) then return "caster" end
  return "other"
end

---MDT tooltip efficiency score: 2.5 * (forces/totalForces) * 13000 / (health/20000).
---Returns nil when the required MDT data is unavailable (score then never grays).
---`clones` is pull[enemyIndex]: clone INDICES (numbers), resolved via enemy.clones.
function MobStyle.efficiencyScoreOf(enemy, clones)
  local health = enemy.health
  if not health or health <= 0 then return nil end
  local cloneIdx = (type(clones) == "table") and clones[1]
  local clone = (type(cloneIdx) == "number") and enemy.clones and enemy.clones[cloneIdx]
  local forces = (clone and clone.count) or enemy.count
  if not forces then return nil end
  local ok, mdtDb = pcall(MDT.GetDB, MDT)
  local idx = ok and mdtDb and mdtDb.currentDungeonIdx
  local totals = idx and MDT.dungeonTotalCount and MDT.dungeonTotalCount[idx]
  local totalCount = totals and totals.normal
  if not totalCount or totalCount <= 0 then return nil end
  return 2.5 * (forces / totalCount) * 13000 / (health / 20000)
end

---The gray "no progress" gate skips bosses/minibosses (mandatory kills: the
---raw-health denominator always sinks them under 1) and casters (the must-kick
---signal outranks the low-efficiency warning).
function MobStyle.isGrayScore(score, mobType)
  if not (score ~= nil and score < 1) then return false end
  return mobType ~= "boss" and mobType ~= "miniboss" and mobType ~= "caster"
end

---Kick-cyan border for a mob whose tier colour alone would hide the kick signal
---(boss > elite > caster priority collapses a casting boss/miniboss to its tier).
---Returns nil for everything else.
function MobStyle.borderColor(enemy, mobType)
  if (mobType == "boss" or mobType == "miniboss") and MobStyle.hasInterruptibleSpell(enemy) then
    return MobStyle.colors.caster
  end
  return nil
end

---Full parity rule in one call: base ring/dot colour + optional border colour.
function MobStyle.ringColors(enemy, clones)
  local mt = MobStyle.typeOf(enemy)
  local base = MobStyle.isGrayScore(MobStyle.efficiencyScoreOf(enemy, clones), mt)
    and MobStyle.gray or MobStyle.colors[mt] or MobStyle.colors.other
  return base, MobStyle.borderColor(enemy, mt)
end

MDT_NPT.MobStyle = MobStyle
