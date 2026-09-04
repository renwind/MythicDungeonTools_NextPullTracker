local MDT = MDT_NPT.MDT or MDT
local MDT_NPT = MDT_NPT
local T = MDT_NPT.test

local CooldownData = MDT_NPT.CooldownData
local CooldownPlan = MDT_NPT.CooldownPlan

-- End-to-end cooldown plan integration (design 17.2): create plan -> verify CRUD ->
-- fingerprint -> render row present.
local function testFunc()
  if not MDT:GetCurrentPreset() then
    T.skip("no MDT preset selected")
  end

  MDT_NPT:Start(true)

  local state = MDT_NPT.state
  if not state or not state.pullStates or #state.pullStates < 1 then
    MDT_NPT:Stop()
    T.skip("no pulls in current preset")
  end

  local uid = CooldownData.getPlanKey(state)
  if not uid then
    MDT_NPT:Stop()
    T.skip("preset has no valid uid (plan feature degraded)")
  end

  local dbChar = MDT_NPT:GetDBChar()
  local pullIndex = 1

  -- CRUD: set an entry then read it back
  local seed = CooldownData.getSeedEntries()
  if not seed or #seed == 0 then
    MDT_NPT:Stop()
    T.skip("no seed entries for current spec")
  end
  local firstID = seed[1].id
  if type(firstID) == "table" then firstID = firstID[1] end
  CooldownPlan:SetEntry(uid, pullIndex, firstID, "spell", "use")
  local plan = CooldownPlan:Get(uid, pullIndex)
  T.assertEquals("table", type(plan), "plan table exists after SetEntry")
  T.assertEquals(1, #plan.entries, "one entry stored")
  T.assertEquals("use", plan.entries[1].action, "entry action = use")

  -- fingerprint: set then verify matches live pull
  local pull = state.pullStates[pullIndex] and state.pullStates[pullIndex].pull
  local enemies = MDT.dungeonEnemies and MDT.dungeonEnemies[state.dungeonIndex]
  CooldownPlan:SetFingerprint(uid, pullIndex, CooldownData.computePullFingerprint(pull, enemies))
  local matched, hasStored = CooldownPlan:VerifyFingerprint(uid, pullIndex, pull, enemies)
  T.assertEquals(true, hasStored, "fingerprint stored")
  T.assertEquals(true, matched, "fingerprint matches live pull")

  -- render row present on the beacon frame
  local frame = MDT_NPT.Beacon and MDT_NPT.Beacon.GetFrame and MDT_NPT.Beacon:GetFrame() or nil
  T.assertEquals("table", type(frame and frame.cooldownIconsRow or nil), "cooldownIconsRow exists on beacon frame")

  -- cleanup
  CooldownPlan:ClearPull(uid, pullIndex)
  MDT_NPT:Stop()
end

tinsert(T.testList, {
  name = "CooldownPlan integration (CRUD + fingerprint + render row)",
  func = testFunc,
  duration = 2,
})
