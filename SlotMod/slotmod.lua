-- SlotMod menu for Slotbound. F1 (or Insert) opens/closes the menu.
-- Menu keys: Tab / PageUp / PageDown switch tabs, Up/Down select, Enter/Space toggle or apply, Esc close.
--   Left/Right change a value (Shift = x10 step, Ctrl = x100 step).
--   Type digits on a value row to enter an exact number, Enter to confirm.
-- Mouse: left-click toggles/applies, wheel changes the value (Shift/Ctrl too).
-- F2 (menu closed): max out the roster unit under the mouse cursor.
-- This file is hot-reloaded when saved while the game is running.
-- The odds features are adapted from Slotbound OddsMod by TokioKaze (MIT), see THIRD_PARTY_NOTICES.md.
local DIR = (debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])")) or ""
local P = package.loaded

local function log(s)
  local f = io.open(DIR .. "slotmod_log.txt", "a")
  if f then f:write(os.date("%H:%M:%S "), s, "\n"); f:close() end
end

-- undo the previous version's wrappers (hot reload)
local old = rawget(_G, "__SLOTMOD")
if old and old.unwrap then pcall(old.unwrap) end

local M = { open = false, sel = 2, wrapped = {}, orig = {}, input = nil }
rawset(_G, "__SLOTMOD", M)

---------------------------------------------------------------- settings
local S = {
  gemLock = false, gemMult = false, gemMultV = 2, gemSetV = 1000,
  goldLock = false, goldMult = false, goldMultV = 2, goldSetV = 1000,
  shardLock = false, shardMult = false, shardMultV = 2, shardSetV = 100,
  rerollFree = false, rerollV = 0, coreReroll = false,
  shopBig = false, shopBigV = 5, invBig = false, invBigV = 12,
  spinLock = false, spinFix = false, spinFixV = 100, machineInf = false, god = false, speed = false, speedV = 2,
  eHp = false, eHpV = 0.5, eDmg = false, eDmgV = 0.5, eSpd = false, eSpdV = 0.5,
  eFreeze = false, eOneHit = false,
  aDmg = false, aDmgV = 2, aAspd = false, aAspdV = 1.5, aInv = false,
  unlockUpg = false, unlockStages = false,
  oddsPresetV = 1, rAdv = false, rAdvV = 20, rRare = false, rRareV = 10, rLeg = false, rLegV = 5,
  rPrism = false, rPrismV = 2, rLocked = false, stoneBoost = false, stoneBoostV = 4,
  symW = false, symWV = 20, symA = false, symAV = 20, symS = false, symSV = 20,
  symH = false, symHV = 15, symM = false, symMV = 15, symD = false, symDV = 10,
  joker = false, jokerV = 5, jokerLine = false,
  freeSpin = false, heartsSetV = 10, stoneReroll = false,
  blockLb = true,
}
local SETTINGS = DIR .. "slotmod_settings.txt"
do
  local f = io.open(SETTINGS, "r")
  if f then
    for line in f:lines() do
      local k, v = line:match("^(%w+)=(.*)$")
      if k and S[k] ~= nil then
        if v == "true" then S[k] = true elseif v == "false" then S[k] = false
        elseif tonumber(v) then S[k] = tonumber(v) end
      end
    end
    f:close()
  end
end
if S.shopBigV > 15 then S.shopBigV = 15 end
local function saveSettings()
  local f = io.open(SETTINGS, "w")
  if not f then return end
  local ks = {}
  for k in pairs(S) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do f:write(k, "=", tostring(S[k]), "\n") end
  f:close()
end

---------------------------------------------------------------- game access
local function mm() return P["src.ui.mainmenu"] end
local function upg() return P["src.ui.upgrade"] end
local function getGems()
  local m = mm(); if m and m.getOriginiteAmount then return tonumber(m.getOriginiteAmount()) end
end
local function setGems(v)
  local m = mm(); if m and m.setOriginiteAmount then m.setOriginiteAmount(math.max(0, math.floor(v))) end
end
local function bf()
  local b = P["src.game.battlefield"]
  if type(b) == "table" and b.baseHP ~= nil then return b end
  local f = P["src.ui.flow"]
  b = f and f.mode_select and f.mode_select.state and f.mode_select.state.ui and f.mode_select.state.ui.battlefield
  if type(b) == "table" and b.baseHP ~= nil then return b end
end
local function getGold() return tonumber(rawget(_G, "coins")) end
local function setGold(v)
  v = math.max(0, math.floor(v))
  rawset(_G, "coins", v)
  if rawget(_G, "displayCoins") ~= nil then rawset(_G, "displayCoins", v) end
end

local function gameUI()
  local f = P["src.ui.flow"]
  return f and f.mode_select and f.mode_select.state and f.mode_select.state.ui
end
-- blue shards ("jungsu" in the game code), used in the in-run shop
local function getShards() return tonumber(rawget(_G, "jungsu")) end
local function setShards(v)
  v = math.max(0, math.floor(v))
  rawset(_G, "jungsu", v)
  if rawget(_G, "displayJungsu") ~= nil then rawset(_G, "displayJungsu", v) end
  local ui = gameUI()
  if ui then
    if ui.jungsuBalance ~= nil then ui.jungsuBalance = v end
    if ui.jungsuBalanceTarget ~= nil then ui.jungsuBalanceTarget = v end
  end
end

---------------------------------------------------------------- unlock all (reversible, backup on disk)
local BACKUP = DIR .. "slotmod_unlock_backup.txt"

local function readBackup()
  local f = io.open(BACKUP, "r")
  if not f then return nil end
  local b = {}
  for line in f:lines() do
    local kind, a, c, d = line:match("^(%a+) (%S+) ?(%S*) ?(%S*)$")
    if kind == "U" then
      b.upg = b.upg or {}
      if a ~= "-" then b.upg[a] = (c == "true") and true or tonumber(c) or c end
    elseif kind == "S" then
      b.stages = b.stages or {}
      if a ~= "-" then b.stages[tonumber(a)] = (c == "true") end
    elseif kind == "D" then
      b.diffs = b.diffs or {}
      if a ~= "-" then
        local s = tonumber(a)
        b.diffs[s] = b.diffs[s] or {}
        if c ~= "-" then b.diffs[s][tonumber(c)] = (d == "true") end
      end
    end
  end
  f:close()
  return b
end
local function writeBackup(b)
  local f = io.open(BACKUP, "w")
  if not f then return end
  if b.upg then
    f:write("U -\n")
    for k, v in pairs(b.upg) do f:write("U ", tostring(k), " ", tostring(v), "\n") end
  end
  if b.stages then
    f:write("S -\n")
    for k, v in pairs(b.stages) do f:write("S ", tostring(k), " ", tostring(v), "\n") end
  end
  if b.diffs then
    f:write("D -\n")
    for s, t in pairs(b.diffs) do
      f:write("D ", s, " -\n")
      for d, v in pairs(t) do f:write("D ", s, " ", d, " ", tostring(v), "\n") end
    end
  end
  f:close()
end

local function allUpgradeIds()
  local u = upg()
  if not (u and u.toggleSandboxUnlockAll) then return nil end
  local _, defs = debug.getupvalue(u.toggleSandboxUnlockAll, 2)
  if type(defs) ~= "table" then return nil end
  local ids = {}
  for k, v in pairs(defs) do if type(k) == "string" and type(v) == "table" then ids[#ids + 1] = k end end
  return ids
end

local function setUnlockUpgrades(on)
  local u = upg()
  if not (u and u.getUpgradeState and u.setUpgradeState) then return false end
  local b = readBackup() or {}
  if on then
    local ids = allUpgradeIds()
    if not ids then log("unlock upgrades: list not found"); return false end
    local cur = u.getUpgradeState() or {}
    if not b.upg then
      b.upg = {}
      for k, v in pairs(cur) do b.upg[k] = v end
      writeBackup(b)
    end
    local new = {}
    for k, v in pairs(cur) do new[k] = v end
    for _, id in ipairs(ids) do new[id] = true end
    u.setUpgradeState(new)
    log("unlock upgrades ON (" .. #ids .. " ids, backup saved)")
  else
    if not b.upg then return true end
    local restore = {}
    for k, v in pairs(b.upg) do restore[k] = v end
    u.setUpgradeState(restore)
    b.upg = nil
    writeBackup(b)
    log("unlock upgrades OFF (restored backup)")
  end
  return true
end

local function setUnlockStages(on)
  local m = mm()
  local ss = m and m.stageSelect
  if not (ss and ss.unlockedStages and ss.unlockedDifficulties) then return false end
  local b = readBackup() or {}
  local maxS = tonumber(ss.maxStages) or 6
  if on then
    if not b.stages then
      b.stages, b.diffs = {}, {}
      for k, v in pairs(ss.unlockedStages) do b.stages[k] = v end
      for s, t in pairs(ss.unlockedDifficulties) do
        b.diffs[s] = {}
        for d, v in pairs(t) do b.diffs[s][d] = v end
      end
      writeBackup(b)
    end
    for s = 1, maxS do
      ss.unlockedStages[s] = true
      ss.unlockedDifficulties[s] = ss.unlockedDifficulties[s] or {}
      for d = 1, 3 do ss.unlockedDifficulties[s][d] = true end
    end
    log("unlock stages ON (backup saved)")
  else
    if not b.stages then return true end
    for k in pairs(ss.unlockedStages) do ss.unlockedStages[k] = b.stages[k] or false end
    for s, t in pairs(ss.unlockedDifficulties) do
      local bt = b.diffs and b.diffs[s]
      if bt then for d in pairs(t) do t[d] = bt[d] or false end
      else ss.unlockedDifficulties[s] = nil end
    end
    b.stages, b.diffs = nil, nil
    writeBackup(b)
    log("unlock stages OFF (restored backup)")
  end
  return true
end

---------------------------------------------------------------- entity stat modifiers
-- per entity + field: remember the game's own value, apply our multiplier on top,
-- and notice when the game changes the value itself (buffs etc.) so OFF restores cleanly.
local est = setmetatable({}, { __mode = "k" })

local function modField(e, f, mult, isPeriod, integer)
  local cur = e[f]
  if type(cur) ~= "number" then return end
  local st = est[e]
  if not st then st = {}; est[e] = st end
  local r = st[f]
  if not r or cur ~= r.set then r = { base = cur }; st[f] = r end
  local want
  if isPeriod then want = (mult > 0) and r.base / mult or r.base * 1000
  else want = r.base * mult end
  if integer then want = math.max(1, math.floor(want + 0.5)) end
  if want ~= cur then
    if f == "maxhp" and type(e.hp) == "number" and cur > 0 then
      e.hp = math.max(math.min(e.hp, 1), e.hp * want / cur)
    end
    e[f] = want
  end
  r.set = want
end

local function eachAlive(list, fn)
  if type(list) ~= "table" then return end
  for _, e in ipairs(list) do
    if type(e) == "table" and e.alive ~= false and not e.dying then fn(e) end
  end
end

local function applyEntities(b)
  local eHp = S.eHp and S.eHpV or 1
  local eDmg = S.eFreeze and 0 or (S.eDmg and S.eDmgV or 1)
  local eSpd = S.eFreeze and 0 or (S.eSpd and S.eSpdV or 1)
  eachAlive(b.enemies, function(e)
    modField(e, "maxhp", eHp)
    modField(e, "dmg", eDmg)
    modField(e, "speed", eSpd)
    if S.eOneHit and type(e.hp) == "number" and e.hp > 1 then e.hp = 1 end
  end)
  local aDmg = S.aDmg and S.aDmgV or 1
  local aAs = S.aAspd and S.aAspdV or 1
  eachAlive(b.allies, function(a)
    modField(a, "dmg", aDmg)
    modField(a, "atkPeriod", aAs, true)
    modField(a, "atkTicks", aAs, true, true)
    if S.aInv and type(a.hp) == "number" and type(a.maxhp) == "number" and a.hp < a.maxhp then a.hp = a.maxhp end
  end)
end

---------------------------------------------------------------- cheats (per frame)
local lockGem, lastGem, lockGold, lastGold, lockSpin, lockHP, lockShard, lastShard
local spinOrig -- original cost-step values while "fixed spin cost" is on

-- shift (nudge) / explosion (blast): the game marks the machine as used for this spin/wave;
-- clearing the marks makes it usable again.
local machLogs = 0
local function applyMachine()
  if not S.machineInf then return end
  local ui = gameUI()
  if not ui then return end
  if ui._nudgeUsedSpinIndex ~= nil or ui._nudgeUsedWaveId ~= nil or ui._nudgeUsedSpinWaveId ~= nil then
    ui._nudgeUsedSpinIndex, ui._nudgeUsedSpinWaveId, ui._nudgeUsedWaveId = nil, nil, nil
    if machLogs < 5 then
      machLogs = machLogs + 1
      M.machCheckAt = love.timer.getTime() + 0.5
    end
  end
  if M.machCheckAt and love.timer.getTime() > M.machCheckAt then
    M.machCheckAt = nil
    log(("machine reset: nudgeEnabled=%s blastEnabled=%s"):format(tostring(ui._nudgeEnabled), tostring(ui._blastEnabled)))
  end
end

local function applySpinCost()
  local econ = P["src.data.constants"] and P["src.data.constants"].economy
  local es = econ and econ.spins
  -- the game's real price step, remembered across hot reloads (game default is 50)
  local ORIG = rawget(_G, "__SLOTMOD_ORIG")
  if not ORIG then ORIG = {}; rawset(_G, "__SLOTMOD_ORIG", ORIG) end
  if es and tonumber(es.paidCostStep) and es.paidCostStep > 0 and not S.spinFix then ORIG.estep = es.paidCostStep end
  local realStep = ORIG.estep or 50
  if S.spinFix then
    spinOrig = true
    if rawget(_G, "spinCostStep") ~= nil then rawset(_G, "spinCostStep", 0) end
    if es and es.paidCostStep then es.paidCostStep = 0 end
    if rawget(_G, "spinCost") ~= nil and rawget(_G, "spinCost") ~= S.spinFixV then rawset(_G, "spinCost", S.spinFixV) end
  else
    -- OFF: undo any zeroed step, also one carried over from a saved run
    if es and es.paidCostStep == 0 then es.paidCostStep = realStep end
    if rawget(_G, "spinCostStep") == 0 then rawset(_G, "spinCostStep", realStep) end
    if spinOrig then
      spinOrig = nil
      local sc, start = tonumber(rawget(_G, "spinCost")), es and tonumber(es.paidStartCost) or 100
      if sc and sc < start then rawset(_G, "spinCost", start) end
    end
  end
end

local function applyCheats()
  local g = getGems()
  if g then
    if S.gemMult and lastGem and g > lastGem then
      g = g + (g - lastGem) * (S.gemMultV - 1); setGems(g)
    end
    if S.gemLock then
      if not lockGem or g > lockGem then lockGem = g end
      if g < lockGem then g = lockGem; setGems(g) end
    else lockGem = nil end
    lastGem = getGems()
  end
  local c = getGold()
  if c then
    if S.goldMult and lastGold and c > lastGold then
      c = c + (c - lastGold) * (S.goldMultV - 1); setGold(c)
    end
    if S.goldLock then
      if not lockGold or c > lockGold then lockGold = c end
      if c < lockGold then c = lockGold; setGold(c) end
    else lockGold = nil end
    lastGold = getGold()
  end
  local j = getShards()
  if j then
    if S.shardMult and lastShard and j > lastShard then
      j = j + (j - lastShard) * (S.shardMultV - 1); setShards(j)
    end
    if S.shardLock then
      if not lockShard or j > lockShard then lockShard = j end
      if j < lockShard then j = lockShard; setShards(j) end
    else lockShard = nil end
    lastShard = getShards()
  end
  local ui = gameUI()
  if ui then
    if S.rerollFree and ui._itemRerollCost ~= nil and ui._itemRerollCost ~= S.rerollV then ui._itemRerollCost = S.rerollV end
    -- shop size: the layout only draws slots.countSell offers
    local sl = ui.itemShop and ui.itemShop.slots
    if sl and tonumber(sl.countSell) then
      local ORIG = rawget(_G, "__SLOTMOD_ORIG") or {}
      rawset(_G, "__SLOTMOD_ORIG", ORIG)
      if not ORIG.countSell and not S.shopBig then ORIG.countSell = sl.countSell end
      local base = ORIG.countSell or 3
      local want = S.shopBig and math.max(base, S.shopBigV) or base
      if sl.countSell ~= want then sl.countSell = want end
      -- shrink slots so the bigger shop keeps the original width (reroll button stays visible)
      if not ORIG.slotScale and not S.shopBig then ORIG.slotScale, ORIG.slotSpacing = sl.scale, sl.spacingPx end
      local sc0, sp0 = ORIG.slotScale or 1, ORIG.slotSpacing or 6
      local wantScale = sc0 * math.min(1, base / want)
      if sl.scale ~= wantScale then sl.scale = wantScale end
      local wantSp = math.floor(sp0 * math.min(1, base / want) + 0.5)
      if sl.spacingPx ~= wantSp then sl.spacingPx = wantSp end
      -- icons are scaled separately; shrink them with the slots so they don't overlap
      local il = ui.itemShop.itemLayout
      if il and tonumber(il.iconScale) then
        if not ORIG.iconScale and not S.shopBig then ORIG.iconScale = il.iconScale end
        local is0 = ORIG.iconScale or 1
        local wantIcon = is0 * math.min(1, (base / want) * 1.15)
        if il.iconScale ~= wantIcon then il.iconScale = wantIcon end
        -- icon goes in the upper frame, price (half size) in the lower strip
        if not ORIG.priceX and not S.shopBig then
          ORIG.priceX, ORIG.priceY, ORIG.priceS, ORIG.iconY = il.priceOffsetX, il.priceOffsetY, il.priceScale, il.iconOffsetY
        end
        local px0, py0, ps0, iy0 = ORIG.priceX or 10, ORIG.priceY or 54, ORIG.priceS or 1, ORIG.iconY or 7
        local f = math.min(1, base / want)
        local T = rawget(_G, "__SLOTMOD_TUNE") or {}
        local wantPX = (f < 1) and (T.px or 2) or px0
        local wantPY = (f < 1) and (T.py or math.floor(py0 * f - 1)) or py0
        local wantPS = (f < 1) and ps0 * 0.5 or ps0
        local wantIY = (f < 1) and (T.iy or math.floor(iy0 * f - 4)) or iy0
        if il.priceOffsetX ~= wantPX then il.priceOffsetX = wantPX end
        if il.priceOffsetY ~= wantPY then il.priceOffsetY = wantPY end
        if il.priceScale ~= wantPS then il.priceScale = wantPS end
        if il.iconOffsetY ~= wantIY then il.iconOffsetY = wantIY end
      end
    end
  end
  if S.freeSpin then
    local fc = tonumber(rawget(_G, "freeSpinCredits"))
    if fc and fc < 1 then rawset(_G, "freeSpinCredits", 1); M.addedCredit = true end
  elseif M.addedCredit then
    M.addedCredit = nil
    if tonumber(rawget(_G, "freeSpinCredits")) == 1 then rawset(_G, "freeSpinCredits", 0) end
  end
  if S.stoneReroll and ui and ui._stoneRerollUsed ~= nil then ui._stoneRerollUsed = nil end
  if S.coreReroll then
    local r = tonumber(rawget(_G, "coreFreeRerollsRemaining"))
    if r and r < 1 then rawset(_G, "coreFreeRerollsRemaining", 1) end
    -- the core screen decides right after each reroll whether the next one is free
    -- (rerollCost 0 + _usesUpgradeFreeReroll); keep both open/deferred screens on "free"
    if ui then
      for _, cs in ipairs({ ui._coreSelect, ui._deferredCoreSelect }) do
        if type(cs) == "table" and cs.rerollCost ~= nil then
          if cs.rerollCost ~= 0 then cs.rerollCost = 0 end
          if cs._usesUpgradeFreeReroll == false then cs._usesUpgradeFreeReroll = true end
        end
      end
    end
  end
  local sp = tonumber(rawget(_G, "spinsLeft"))
  if sp then
    if S.spinLock then
      if not lockSpin or sp > lockSpin then lockSpin = sp end
      if sp < lockSpin then rawset(_G, "spinsLeft", lockSpin) end
    else lockSpin = nil end
  end
  applySpinCost()
  applyMachine()
  local b = bf()
  if b then
    if tonumber(b.baseHP) then
      if S.god then
        if not lockHP or b.baseHP > lockHP then lockHP = b.baseHP end
        if b.baseHP < lockHP then b.baseHP = lockHP end
      else lockHP = nil end
    end
    applyEntities(b)
  end
end

---------------------------------------------------------------- odds
-- Rarity / class-symbol / Joker / Fate Stone odds.
-- Adapted from "Slotbound OddsMod" by TokioKaze (MIT License, Copyright (c) 2026 TokioKaze),
-- https://github.com/TokioKaze/-Slotbound-OddsMod- . See THIRD_PARTY_NOTICES.md.
local GRADES = { "normal", "advanced", "rare", "legendary", "prism" }
local SYMBOLS = { "W", "A", "S", "H", "M", "D" }
local JOKER_MAX = 0.05 -- the game caps the Joker chance at 5%
local function fmtPct(x) return (string.format("%.2f", x * 100):gsub("0+$", ""):gsub("%.$", "")) .. "%" end

-- persistent across hot reloads: hooks are installed once and read the current settings at call time
local ODDS = rawget(_G, "__SLOTMOD_ODDS") or {}
rawset(_G, "__SLOTMOD_ODDS", ODDS)

-- base: the game's weights; targets: { key = probability 0..1 } to pin; the other keys share
-- the remaining probability in their original proportions. respect: keys at 0% (locked) stay 0%.
local function transformKeys(base, keys, targets, respect)
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  if not targets or not next(targets) then return out end
  local p, sum = {}, 0
  for _, g in ipairs(keys) do
    local v = tonumber(base[g]) or 0
    if v ~= v or v < 0 then v = 0 end
    p[g] = v; sum = sum + v
  end
  if sum <= 0 then return out end
  for _, g in ipairs(keys) do p[g] = p[g] / sum end
  local tgt, T = {}, 0
  for _, g in ipairs(keys) do
    local t = targets[g]
    if t ~= nil and not (respect and p[g] <= 0 and t > 0) then tgt[g] = t; T = T + t end
  end
  if T <= 0 and not next(tgt) then return out end
  if T > 1 then for g, t in pairs(tgt) do tgt[g] = t / T end; T = 1 end
  local rest = 0
  for _, g in ipairs(keys) do if tgt[g] == nil then rest = rest + p[g] end end
  if rest <= 0 and T <= 0 then return out end
  local R = math.max(0, 1 - T)
  for _, g in ipairs(keys) do
    if tgt[g] ~= nil then out[g] = (rest > 0 or T <= 0) and tgt[g] or tgt[g] / T
    elseif rest > 0 then out[g] = R * p[g] / rest
    else out[g] = 0 end
  end
  return out
end

-- current settings, rebuilt from S on every call (S changes when the menu is used)
ODDS.settings = function()
  local slot = {}
  if S.rAdv then slot.advanced = S.rAdvV / 100 end
  if S.rRare then slot.rare = S.rRareV / 100 end
  if S.rLeg then slot.legendary = S.rLegV / 100 end
  if S.rPrism then slot.prism = S.rPrismV / 100 end
  local sym = {}
  for _, k in ipairs(SYMBOLS) do if S["sym" .. k] then sym[k] = S["sym" .. k .. "V"] / 100 end end
  return {
    slot = next(slot) and slot or nil, respect = not S.rLocked,
    sym = next(sym) and sym or nil,
    stoneMult = S.stoneBoost and S.stoneBoostV or nil,
    joker = S.joker and math.max(0, math.min(JOKER_MAX, S.jokerV / 100)) or nil,
    jokerLine = S.jokerLine,
  }
end
ODDS.transformKeys = transformKeys

local function installOdds()
  local C = P["src.data.constants"]
  -- slot rarity: proxy constants.unitGrades.probabilities (the upgrade code writes it in place)
  local probs = type(C) == "table" and type(C.unitGrades) == "table" and C.unitGrades.probabilities
  if type(probs) == "table" and not ODDS.slotDone then
    local mt = getmetatable(probs)
    if mt then
      ODDS.slotDone = true
      if not mt.__slotmod then log("slot rarity table already hooked by another mod; SlotMod rarity odds disabled") end
    else
      local shadow = {}
      for k, v in pairs(probs) do shadow[k] = v end
      for k in pairs(shadow) do rawset(probs, k, nil) end
      -- the game writes advanced/rare/legendary/prism, reads advanced back to compute normal,
      -- then writes normal: between those writes, reads return the raw values
      local writing = false
      setmetatable(probs, {
        __slotmod = true,
        __index = function(_, k)
          if writing then
            if k == "advanced" then return shadow[k] end
            writing = false
          end
          local st = ODDS.settings and ODDS.settings()
          if not (st and st.slot) then return shadow[k] end
          local v = ODDS.transformKeys(shadow, GRADES, st.slot, st.respect)[k]
          if v == nil then v = shadow[k] end
          return v
        end,
        __newindex = function(_, k, v)
          if k == "advanced" then writing = true elseif k == "normal" then writing = false end
          shadow[k] = v
        end,
      })
      ODDS.slotShadow = shadow
      ODDS.slotDone = true
      log("odds: slot rarity hooked")
    end
  end
  -- class symbols: proxy the symbolWeights key of constants.slot (some cores swap the whole table)
  local slotT = type(C) == "table" and C.slot
  if type(slotT) == "table" and not ODDS.symDone then
    ODDS.symDone = true
    if getmetatable(slotT) then
      log("constants.slot already hooked by another mod; SlotMod class odds disabled")
    elseif type(rawget(slotT, "symbolWeights")) == "table" then
      local held = rawget(slotT, "symbolWeights")
      rawset(slotT, "symbolWeights", nil)
      setmetatable(slotT, {
        __slotmod = true,
        __index = function(_, k)
          if k ~= "symbolWeights" then return nil end
          local st = ODDS.settings and ODDS.settings()
          if not (st and st.sym) or type(held) ~= "table" then return held end
          return ODDS.transformKeys(held, SYMBOLS, st.sym, true)
        end,
        __newindex = function(t, k, v)
          if k == "symbolWeights" then held = v else rawset(t, k, v) end
        end,
      })
      ODDS.symBase = function() return held end
      log("odds: class symbols hooked")
    end
  end
  -- Joker chance and forced Joker line
  local cores = P["src.game.cores"]
  if type(cores) == "table" then
    if type(cores.getJokerChance) == "function" and cores.getJokerChance ~= ODDS.gjcWrap then
      local o = cores.getJokerChance
      ODDS.gjcWrap = function(...)
        local st = ODDS.settings and ODDS.settings()
        if st and st.joker then return st.joker end
        return o(...)
      end
      cores.getJokerChance = ODDS.gjcWrap
    end
    if type(cores.prepareSpin) == "function" and cores.prepareSpin ~= ODDS.prepWrap then
      local o = cores.prepareSpin
      ODDS.prepWrap = function(...)
        local r = o(...)
        local st = ODDS.settings and ODDS.settings()
        if st and type(r) == "table" then
          if st.joker then r.jokerChance = st.joker end
          if st.jokerLine then
            -- the game's own forceJokerCells mechanism: Jokers on the whole middle row
            local cells = {}
            if type(r.forceJokerCells) == "table" then for _, c in ipairs(r.forceJokerCells) do cells[#cells + 1] = c end end
            for col = 1, 3 do cells[#cells + 1] = { row = 2, col = col } end
            r.forceJokerCells = cells
          end
        end
        return r
      end
      cores.prepareSpin = ODDS.prepWrap
    end
  end
  -- Fate Stones: scale legendary + prismatic weights in stone.effectiveProbs
  local stone = P["src.game.stone"]
  if type(stone) == "table" and type(stone.effectiveProbs) == "function" and stone.effectiveProbs ~= ODDS.stoneWrap then
    local o = stone.effectiveProbs
    ODDS.stoneWrap = function(...)
      local r = o(...)
      local st = ODDS.settings and ODDS.settings()
      if not (st and st.stoneMult) or type(r) ~= "table" then return r end
      local out, sum = {}, 0
      for k, v in pairs(r) do out[k] = v end
      for _, g in ipairs(GRADES) do
        local v = tonumber(r[g]) or 0
        if g == "legendary" or g == "prism" then v = v * st.stoneMult end
        out[g] = v; sum = sum + v
      end
      if sum > 0 then for _, g in ipairs(GRADES) do out[g] = out[g] / sum end end
      return out
    end
    stone.effectiveProbs = ODDS.stoneWrap
  end
end

-- current effective slot rarity, for the help line
local function slotOddsText()
  local probs = ODDS.slotShadow
  if not probs then return "" end
  local st = ODDS.settings()
  local out = st.slot and transformKeys(probs, GRADES, st.slot, st.respect) or probs
  local sum = 0
  for _, g in ipairs(GRADES) do sum = sum + (tonumber(out[g]) or 0) end
  if sum <= 0 then return "" end
  local n = { normal = "C", advanced = "U", rare = "R", legendary = "L", prism = "P" }
  local parts = {}
  for _, g in ipairs(GRADES) do parts[#parts + 1] = n[g] .. " " .. fmtPct((tonumber(out[g]) or 0) / sum) end
  return "Now: " .. table.concat(parts, "  ")
end

local PRESETS = {
  { name = "Original" },
  { name = "Hard", leg = 1, prism = 0.3, stone = 1.5 },
  { name = "Medium", leg = 2.5, prism = 0.8, stone = 2.5 },
  { name = "Easy", leg = 5, prism = 2, stone = 4 },
  { name = "Bliss", rare = 20, leg = 15, prism = 8, stone = 8 },
}
local PRESET_NAMES = {}
for i, p in ipairs(PRESETS) do PRESET_NAMES[i] = p.name end
local function applyPreset(i)
  local p = PRESETS[i]
  if not p then return end
  S.rAdv = false
  S.rRare = p.rare ~= nil; if p.rare then S.rRareV = p.rare end
  S.rLeg = p.leg ~= nil; if p.leg then S.rLegV = p.leg end
  S.rPrism = p.prism ~= nil; if p.prism then S.rPrismV = p.prism end
  S.stoneBoost = p.stone ~= nil; if p.stone then S.stoneBoostV = p.stone end
end

---------------------------------------------------------------- max out units
local function toast(msg)
  M.toast, M.toastT = msg, love.timer.getTime() + 2.5
  log(msg)
end

-- roster unit nearest to the mouse cursor (game space = screen / screenScale)
local function unitUnderCursor()
  local b = bf()
  if not (b and type(b.rosterUnits) == "table") then return nil end
  local mx, my = love.mouse.getPosition()
  local sc = tonumber(rawget(_G, "screenScale")) or 1
  local gx = (mx - (tonumber(rawget(_G, "screenOffsetX")) or 0)) / sc
  local gy = (my - (tonumber(rawget(_G, "screenOffsetY")) or 0)) / sc
  local best, bd
  for _, u in ipairs(b.rosterUnits) do
    if type(u) == "table" and tonumber(u.x) and tonumber(u.y) then
      -- unit position is at its feet; the sprite is above it
      local dx, dy = gx - u.x, gy - (u.y - 12)
      local d = dx * dx + dy * dy
      if not bd or d < bd then best, bd = u, d end
    end
  end
  if best and bd <= 28 * 28 then return best end
end

local function maxOutUnit(u)
  if type(u) ~= "table" then return false end
  local E = P["src.data.constants"] and P["src.data.constants"].evolution
  local grade = u.grade or "normal"
  local maxRank = (E and E.maxRankByGrade and E.maxRankByGrade[grade]) or 3
  local r0, lv0 = tonumber(u.rank) or 1, tonumber(u.absorbLV) or 1
  local atk0, hp0 = u.stats and u.stats.atk, u.stats and u.stats.hp
  if r0 >= maxRank then return false, "already max rank" end
  -- 1) the game's own rank-up (used by a Fate Stone): recalculates everything itself
  local raise = rawget(_G, "__slotStoneRaiseRank")
  if type(raise) == "function" then
    for _ = 1, maxRank do
      local before = tonumber(u.rank) or 1
      if before >= maxRank then break end
      local ok = pcall(raise, u, 1)
      if not ok or (tonumber(u.rank) or 1) <= before then break end
    end
  end
  -- 2) fallback: rank, absorb level and rank multiplier by hand
  local r1 = tonumber(u.rank) or 1
  if r1 < maxRank then
    local th = E and E.rankThresholds and E.rankThresholds[grade]
    local mul = E and E.rankMultipliers and E.rankMultipliers[grade]
    if th and th[maxRank] and (tonumber(u.absorbLV) or 1) < th[maxRank] then u.absorbLV = th[maxRank] end
    if mul and mul[r1] and mul[maxRank] and type(u.stats) == "table" then
      local f = mul[maxRank] / mul[r1]
      if tonumber(u.stats.atk) then u.stats.atk = u.stats.atk * f end
      if tonumber(u.stats.hp) then u.stats.hp = u.stats.hp * f end
    end
    u.rank = maxRank
    M.lastMaxWay = "manual"
  else
    M.lastMaxWay = "game"
  end
  log(("max out %s %s: rank %s->%s lv %s->%s atk %s->%s hp %s->%s (%s)"):format(tostring(u.sym), grade, r0, tostring(u.rank),
    lv0, tostring(u.absorbLV), tostring(atk0), tostring(u.stats and u.stats.atk), tostring(hp0), tostring(u.stats and u.stats.hp), M.lastMaxWay))
  return true
end

local function maxOutAll()
  local b = bf()
  if not (b and type(b.rosterUnits) == "table") then toast("No units (start a run first)"); return end
  local n = 0
  for _, u in ipairs(b.rosterUnits) do if maxOutUnit(u) then n = n + 1 end end
  toast(n > 0 and ("Maxed out " .. n .. " unit(s)") or "All units are already max rank")
end

local function maxOutHovered()
  local u = unitUnderCursor()
  if not u then toast("No unit under the cursor"); return end
  local ok, why = maxOutUnit(u)
  toast(ok and "Unit maxed out (rank " .. tostring(u.rank) .. ")" or ("Unit " .. (why or "not changed")))
end

---------------------------------------------------------------- menu layout (tabs)
-- toggle rows: key (+ optional vkey value); set rows: action + vkey; info = help line
local TABS = {
  { name = "Money", rows = {
    { head = "Gems (Originite)" },
    { key = "gemLock", label = "Lock gems", info = "Gems never go down. Earning still adds more." },
    { key = "gemMult", label = "Gem gain", vkey = "gemMultV", min = 1, max = 10000, step = 1, pre = "x", info = "Multiplies every gem gain." },
    { label = "Set gems", vkey = "gemSetV", min = 0, max = 99999999, step = 1, info = "Click APPLY (or Enter) to set your gems to this amount.",
      action = function() setGems(S.gemSetV); lockGem = nil; lastGem = getGems() end },
    { head = "Gold (in run)" },
    { key = "goldLock", label = "Lock gold", info = "Gold never goes down during a run." },
    { key = "goldMult", label = "Gold gain", vkey = "goldMultV", min = 1, max = 10000, step = 1, pre = "x", info = "Multiplies every gold gain." },
    { label = "Set gold", vkey = "goldSetV", min = 0, max = 99999999, step = 1, info = "Sets the gold of the current run.",
      action = function() if getGold() then setGold(S.goldSetV); lockGold = nil; lastGold = getGold() end end },
    { head = "Blue shards (in run)" },
    { key = "shardLock", label = "Lock shards", info = "Blue shards never go down." },
    { key = "shardMult", label = "Shard gain", vkey = "shardMultV", min = 1, max = 10000, step = 1, pre = "x", info = "Multiplies every shard gain." },
    { label = "Set shards", vkey = "shardSetV", min = 0, max = 99999999, step = 1, info = "Sets the blue shards of the current run.",
      action = function() if getShards() then setShards(S.shardSetV); lockShard = nil; lastShard = getShards() end end },
  } },
  { name = "Shop", rows = {
    { head = "Item shop" },
    { key = "shopBig", label = "Shop size", vkey = "shopBigV", min = 3, max = 15, step = 1, info = "Items per shop roll (icons shrink to fit). Takes effect on the next reroll." },
    { key = "invBig", label = "Item inventory size", vkey = "invBigV", min = 1, max = 30, step = 1, info = "How many items you can hold." },
    { key = "rerollFree", label = "Fixed reroll cost", vkey = "rerollV", min = 0, max = 1000, step = 1, info = "Shop reroll always costs this many shards (0 = free)." },
    { head = "Cores + Fate Stones" },
    { key = "coreReroll", label = "Unlimited free core rerolls", info = "Always keeps one free reroll on the core selection." },
    { key = "stoneReroll", label = "Free Fate Stone rerolls", info = "Fate Stone rerolls stay available. (from OddsMod)" },
  } },
  { name = "Run", rows = {
    { head = "Slot machine" },
    { key = "spinLock", label = "Lock spins left", info = "Spins left never go down." },
    { key = "spinFix", label = "Fixed spin cost", vkey = "spinFixV", min = 0, max = 100000, step = 1, info = "Paid spins always cost this much; price no longer increases." },
    { key = "machineInf", label = "Unlimited shift / explosion", info = "The machine ability can be used again right away." },
    { key = "freeSpin", label = "Free spins", info = "Always keeps one free spin credit, so spins cost nothing. (from OddsMod)" },
    { head = "General" },
    { key = "god", label = "God mode", info = "Your base HP (hearts) can't drop." },
    { label = "Set hearts", vkey = "heartsSetV", min = 1, max = 999, step = 1, info = "Sets your base HP (hearts) in the current run. (from OddsMod)",
      action = function() local b = bf(); if b and tonumber(b.baseHP) then b.baseHP = S.heartsSetV; b._prevBaseHP = S.heartsSetV; lockHP = nil end end },
    { key = "speed", label = "Game speed", vkey = "speedV", min = 0.1, max = 10, step = 0.1, pre = "x", info = "Speeds up (or slows down) the whole game." },
  } },
  { name = "Combat", rows = {
    { head = "Enemies" },
    { key = "eHp", label = "Enemy HP", vkey = "eHpV", min = 0.05, max = 50, step = 0.05, pre = "x", info = "Multiplies enemy max HP." },
    { key = "eDmg", label = "Enemy damage", vkey = "eDmgV", min = 0, max = 50, step = 0.05, pre = "x", info = "Multiplies enemy damage." },
    { key = "eSpd", label = "Enemy speed", vkey = "eSpdV", min = 0, max = 10, step = 0.05, pre = "x", info = "Multiplies enemy move speed." },
    { key = "eFreeze", label = "Freeze enemies", info = "Enemies don't move and deal no damage." },
    { key = "eOneHit", label = "One-hit kills", info = "Every enemy has 1 HP." },
    { head = "Allies" },
    { key = "aDmg", label = "Ally damage", vkey = "aDmgV", min = 0.1, max = 100, step = 0.1, pre = "x", info = "Multiplies ally damage." },
    { key = "aAspd", label = "Ally attack speed", vkey = "aAspdV", min = 0.1, max = 10, step = 0.1, pre = "x", info = "Multiplies ally attack speed." },
    { key = "aInv", label = "Invincible allies", info = "Allies are healed to full every frame." },
    { head = "Units" },
    { label = "Max out all units", info = "Every unit on your roster goes to max rank. Tip: hover one unit and press F2.",
      action = function() maxOutAll() end },
  } },
  { name = "Odds", rows = {
    { head = "Slot machine rarity (chance per unit)" },
    { label = "Preset", vkey = "oddsPresetV", min = 1, max = #PRESETS, step = 1, names = PRESET_NAMES,
      info = "Pick a preset and click APPLY. Sets the rarity and Fate Stone rows below.",
      action = function() applyPreset(S.oddsPresetV) end },
    { key = "rAdv", label = "Uncommon", vkey = "rAdvV", min = 0, max = 100, step = 0.1, post = "%", info = slotOddsText },
    { key = "rRare", label = "Rare", vkey = "rRareV", min = 0, max = 100, step = 0.1, post = "%", info = slotOddsText },
    { key = "rLeg", label = "Legendary", vkey = "rLegV", min = 0, max = 100, step = 0.1, post = "%", info = slotOddsText },
    { key = "rPrism", label = "Prismatic", vkey = "rPrismV", min = 0, max = 100, step = 0.1, post = "%", info = slotOddsText },
    { key = "rLocked", label = "Allow locked rarities", info = "Also apply chances to rarities you haven't unlocked yet (normally they stay 0%)." },
    { key = "stoneBoost", label = "Fate Stone L+P weight", vkey = "stoneBoostV", min = 0.1, max = 100, step = 0.1, pre = "x", info = "Multiplies the Legendary and Prismatic weights of every Fate Stone." },
    { head = "Class symbols (chance per symbol)" },
    { key = "symW", label = "Warrior", vkey = "symWV", min = 0, max = 100, step = 1, post = "%", info = "Pinned chance; unpinned classes share the rest." },
    { key = "symA", label = "Archer", vkey = "symAV", min = 0, max = 100, step = 1, post = "%", info = "Pinned chance; unpinned classes share the rest." },
    { key = "symS", label = "Spearman", vkey = "symSV", min = 0, max = 100, step = 1, post = "%", info = "Pinned chance; unpinned classes share the rest." },
    { key = "symH", label = "Cavalry", vkey = "symHV", min = 0, max = 100, step = 1, post = "%", info = "Pinned chance; unpinned classes share the rest." },
    { key = "symM", label = "Mage", vkey = "symMV", min = 0, max = 100, step = 1, post = "%", info = "Pinned chance; unpinned classes share the rest." },
    { key = "symD", label = "Duelist", vkey = "symDV", min = 0, max = 100, step = 1, post = "%", info = "Pinned chance; unpinned classes share the rest." },
    { key = "joker", label = "Joker chance", vkey = "jokerV", min = 0, max = 5, step = 0.1, post = "%", info = "Chance of a Joker symbol (the game caps it at 5%)." },
    { key = "jokerLine", label = "Guaranteed Joker line", info = "Every spin puts Jokers on the whole middle row (summons a Joker unit)." },
  } },
  { name = "Unlocks", rows = {
    { head = "Reversible (OFF restores your old state)" },
    { key = "unlockUpg", label = "All upgrades", onToggle = function(on) return setUnlockUpgrades(on) end, info = "Owns every upgrade. A backup is saved first." },
    { key = "unlockStages", label = "All stages + difficulties", onToggle = function(on) return setUnlockStages(on) end, info = "Unlocks every stage and difficulty. A backup is saved first." },
    { head = "Safety" },
    { key = "blockLb", label = "Block leaderboard uploads", info = "Keeps modded runs off the online leaderboard." },
  } },
}
M.tab = M.tab or 1

local function curRows() return TABS[M.tab].rows end
local function selectable(i) local r = curRows()[i]; return r and not r.head end
local function firstSel()
  for i = 1, #curRows() do if selectable(i) then return i end end
  return 1
end
if not selectable(M.sel) then M.sel = firstSel() end
local function moveSel(d)
  local rows, i = curRows(), M.sel
  repeat i = (i - 1 + d) % #rows + 1 until selectable(i)
  M.sel = i; M.input = nil
end
local function setTab(t)
  M.tab = (t - 1) % #TABS + 1
  M.sel = firstSel(); M.input = nil
end
local function fmtNum(v)
  if v == math.floor(v) then return tostring(math.floor(v)) end
  return (string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", ""))
end
local function clampRow(r, v)
  v = math.max(r.min, math.min(r.max, v))
  if r.step < 1 then v = math.floor(v / r.step + 0.5) * r.step; v = tonumber(string.format("%.4f", v)) end
  return v
end
local function activate(r)
  if r.action then
    r.action(); log("apply " .. tostring(r.label) .. " = " .. tostring(S[r.vkey]))
  elseif r.key then
    local want = not S[r.key]
    if r.onToggle then
      local ok, res = pcall(r.onToggle, want)
      if not ok then log("toggle error: " .. tostring(res)); return end
      if res == false then log("toggle not available here: " .. r.label); return end
    end
    S[r.key] = want
    log("toggle " .. r.key .. " = " .. tostring(want))
  end
  saveSettings()
end
local function stepMul()
  local kd = love.keyboard.isDown
  local m = 1
  if kd("lshift", "rshift") then m = m * 10 end
  if kd("lctrl", "rctrl") then m = m * 100 end
  return m
end
local function change(r, d)
  if not (r and r.vkey) then return end
  S[r.vkey] = clampRow(r, S[r.vkey] + d * r.step * stepMul())
  saveSettings()
end
local function commitInput(r)
  local v = tonumber(M.input or "")
  M.input = nil
  if v and r.vkey then S[r.vkey] = clampRow(r, v); saveSettings(); return true end
end

-- re-apply persistent unlock toggles once the menu module exists
local unlockSynced = false
local function syncUnlocks()
  if unlockSynced or not (mm() and upg()) then return end
  unlockSynced = true
  if S.unlockUpg then pcall(setUnlockUpgrades, true) end
  if S.unlockStages then pcall(setUnlockStages, true) end
end

---------------------------------------------------------------- drawing
local C = {
  bg = { 0.07, 0.07, 0.10, 0.94 }, panel = { 0.11, 0.11, 0.15, 1 }, border = { 0.85, 0.68, 0.28, 1 },
  gold = { 0.95, 0.78, 0.35, 1 }, text = { 0.92, 0.92, 0.95, 1 }, dim = { 0.55, 0.56, 0.62, 1 },
  on = { 0.30, 0.78, 0.45, 1 }, off = { 0.28, 0.29, 0.34, 1 }, hover = { 1, 1, 1, 0.07 }, sel = { 0.95, 0.78, 0.35, 0.13 },
  btn = { 0.20, 0.21, 0.27, 1 }, btnHi = { 0.30, 0.31, 0.39, 1 }, apply = { 0.25, 0.45, 0.85, 1 },
}
M.win = M.win or { x = 12, y = 12 }
local WW, TITLE, TABH, ROWH, FOOT, PADX = 400, 26, 24, 22, 40, 10
local font, fontSmall
local hit = {} -- clickable rects built while drawing

local function inR(r, x, y) return x >= r[1] and x <= r[1] + r[3] and y >= r[2] and y <= r[2] + r[4] end
local function winH() return TITLE + TABH + 6 + #curRows() * ROWH + FOOT end

local function drawMenu()
  local lg = love.graphics
  font = font or lg.newFont(14)
  fontSmall = fontSmall or lg.newFont(12)
  hit = {}
  local mx, my = love.mouse.getPosition()
  lg.push("all")
  lg.origin(); lg.setShader(); lg.setCanvas(); lg.setScissor()
  local x0, y0, H = M.win.x, M.win.y, winH()
  -- window
  lg.setColor(0, 0, 0, 0.35); lg.rectangle("fill", x0 + 3, y0 + 4, WW, H, 8, 8)
  lg.setColor(C.bg); lg.rectangle("fill", x0, y0, WW, H, 8, 8)
  lg.setColor(C.border); lg.setLineWidth(1); lg.rectangle("line", x0 + 0.5, y0 + 0.5, WW - 1, H - 1, 8, 8)
  -- title bar
  lg.setFont(font)
  lg.setColor(C.gold); lg.print("SlotMod", x0 + PADX, y0 + 6)
  lg.setFont(fontSmall); lg.setColor(C.dim)
  local hint = "F1 close   Tab: tabs   Shift/Ctrl: x10/x100"
  lg.print(hint, x0 + WW - PADX - fontSmall:getWidth(hint), y0 + 8)
  hit[#hit + 1] = { kind = "drag", r = { x0, y0, WW, TITLE } }
  -- tabs
  local tw = (WW - PADX * 2) / #TABS
  local ty = y0 + TITLE
  for t, tab in ipairs(TABS) do
    local r = { x0 + PADX + (t - 1) * tw, ty, tw - 2, TABH }
    local active = t == M.tab
    lg.setColor(active and C.panel or (inR(r, mx, my) and C.btn or { 0, 0, 0, 0 }))
    lg.rectangle("fill", r[1], r[2], r[3], r[4], 4, 4)
    if active then lg.setColor(C.gold); lg.rectangle("fill", r[1] + 6, r[2] + r[4] - 2, r[3] - 12, 2) end
    lg.setFont(fontSmall); lg.setColor(active and C.text or C.dim)
    lg.print(tab.name, r[1] + (r[3] - fontSmall:getWidth(tab.name)) / 2, r[2] + 5)
    hit[#hit + 1] = { kind = "tab", t = t, r = r }
  end
  -- rows
  local ry = ty + TABH + 6
  for i, row in ipairs(curRows()) do
    local y = ry + (i - 1) * ROWH
    local rr = { x0 + 6, y, WW - 12, ROWH - 2 }
    if row.head then
      lg.setFont(fontSmall); lg.setColor(C.gold)
      lg.print(row.head:upper(), x0 + PADX, y + 6)
    else
      if i == M.sel then lg.setColor(C.sel); lg.rectangle("fill", rr[1], rr[2], rr[3], rr[4], 4, 4)
      elseif inR(rr, mx, my) then lg.setColor(C.hover); lg.rectangle("fill", rr[1], rr[2], rr[3], rr[4], 4, 4) end
      hit[#hit + 1] = { kind = "row", i = i, r = rr }
      lg.setFont(font)
      local active = row.key and S[row.key]
      lg.setColor(active and C.text or (row.key and C.dim or C.text))
      lg.print(row.label, x0 + PADX + 2, y + 2)
      local right = x0 + WW - PADX
      -- switch or apply button
      if row.key then
        local sw = { right - 34, y + 3, 34, 15 }
        lg.setColor(active and C.on or C.off); lg.rectangle("fill", sw[1], sw[2], sw[3], sw[4], 7.5, 7.5)
        lg.setColor(1, 1, 1, 1); lg.circle("fill", active and (sw[1] + sw[3] - 7.5) or (sw[1] + 7.5), sw[2] + 7.5, 5.5)
        hit[#hit + 1] = { kind = "toggle", i = i, r = { sw[1] - 4, sw[2] - 3, sw[3] + 8, sw[4] + 6 } }
        right = sw[1] - 8
      elseif row.action then
        local bw = 46
        local b = { right - bw, y + 1, bw, ROWH - 4 }
        lg.setColor(inR(b, mx, my) and { 0.35, 0.55, 0.95, 1 } or C.apply); lg.rectangle("fill", b[1], b[2], b[3], b[4], 4, 4)
        lg.setFont(fontSmall); lg.setColor(1, 1, 1, 1); lg.print("APPLY", b[1] + (bw - fontSmall:getWidth("APPLY")) / 2, b[2] + 3)
        hit[#hit + 1] = { kind = "apply", i = i, r = b }
        right = b[1] - 8
      end
      -- value box  [-] value [+]
      if row.vkey then
        lg.setFont(font)
        local s
        if i == M.sel and M.input then s = (row.pre or "") .. M.input .. "_" .. (row.post or "")
        elseif row.names then s = row.names[S[row.vkey]] or "?"
        else s = (row.pre or "") .. fmtNum(S[row.vkey]) .. (row.post or "") end
        local vw = math.max(56, font:getWidth(s) + 12)
        local plus = { right - 18, y + 2, 18, ROWH - 6 }
        local box = { plus[1] - 2 - vw, y + 2, vw, ROWH - 6 }
        local minus = { box[1] - 20, y + 2, 18, ROWH - 6 }
        for _, b in ipairs({ minus, plus }) do
          lg.setColor(inR(b, mx, my) and C.btnHi or C.btn); lg.rectangle("fill", b[1], b[2], b[3], b[4], 3, 3)
        end
        lg.setColor(C.text)
        lg.print("-", minus[1] + 6, minus[2] + 1); lg.print("+", plus[1] + 5, plus[2] + 1)
        lg.setColor(0, 0, 0, 0.35); lg.rectangle("fill", box[1], box[2], box[3], box[4], 3, 3)
        lg.setColor((i == M.sel and M.input) and C.gold or C.text)
        lg.print(s, box[1] + (vw - font:getWidth(s)) / 2, box[2] + 1)
        hit[#hit + 1] = { kind = "minus", i = i, r = minus }
        hit[#hit + 1] = { kind = "plus", i = i, r = plus }
        hit[#hit + 1] = { kind = "value", i = i, r = box }
      end
    end
  end
  -- footer: help line + currencies
  local fy = y0 + H - FOOT
  lg.setColor(C.panel); lg.rectangle("fill", x0 + 6, fy, WW - 12, FOOT - 6, 4, 4)
  lg.setFont(fontSmall)
  local sel = curRows()[M.sel]
  lg.setColor(C.dim)
  local info = sel and sel.info
  if type(info) == "function" then local ok, t = pcall(info); info = ok and t or "" end
  lg.print(info or "", x0 + PADX + 2, fy + 3)
  local g, c, j = getGems(), getGold(), getShards()
  lg.setColor(C.text)
  lg.print(("Gems %s    Gold %s    Shards %s"):format(g and math.floor(g) or "-", c and math.floor(c) or "-", j and math.floor(j) or "-"),
    x0 + PADX + 2, fy + 18)
  lg.pop()
end

local function hitAt(x, y)
  -- later entries (buttons) win over the row background
  for k = #hit, 1, -1 do if inR(hit[k].r, x, y) then return hit[k] end end
end

---------------------------------------------------------------- love callback wrappers
local W_ = {}
function W_.update(orig)
  return function(dt, ...)
    syncUnlocks()
    local ok, e = pcall(applyCheats)
    if not ok then
      M.errs = (M.errs or 0) + 1
      if M.errs < 20 then log("cheat error: " .. tostring(e)) end
    end
    if M.drag then
      if love.mouse.isDown(1) then
        local mx, my = love.mouse.getPosition()
        local w, h = love.graphics.getDimensions()
        M.win.x = math.max(0, math.min(w - WW, mx - M.drag[1]))
        M.win.y = math.max(0, math.min(h - 40, my - M.drag[2]))
      else M.drag = nil end
    end
    if S.speed and type(dt) == "number" then
      local n = S.speedV
      if n < 1 then return orig(dt * n, ...) end
      local whole = math.floor(n)
      for _ = 1, whole - 1 do orig(dt, ...) end
      if n > whole then orig(dt * (n - whole), ...) end
    end
    return orig(dt, ...)
  end
end
function W_.draw(orig)
  return function(...)
    local r = orig(...)
    if M.toast then
      if love.timer.getTime() > (M.toastT or 0) then M.toast = nil
      else
        pcall(function()
          local lg = love.graphics
          lg.push("all"); lg.origin(); lg.setShader(); lg.setCanvas()
          font = font or lg.newFont(14)
          lg.setFont(font)
          local w = font:getWidth(M.toast) + 24
          local x = (lg.getWidth() - w) / 2
          lg.setColor(0.07, 0.07, 0.10, 0.92); lg.rectangle("fill", x, 18, w, 28, 6, 6)
          lg.setColor(0.95, 0.78, 0.35, 1); lg.rectangle("line", x + 0.5, 18.5, w - 1, 27, 6, 6)
          lg.setColor(1, 1, 1, 1); lg.print(M.toast, x + 12, 24)
          lg.pop()
        end)
      end
    end
    if M.open then
      local ok, e = pcall(drawMenu)
      if not ok then log("draw error: " .. tostring(e)); pcall(love.graphics.pop) end
    end
    return r
  end
end
function W_.keypressed(orig)
  return function(key, ...)
    if key == "f1" or key == "insert" then M.open = not M.open; M.input = nil; return end
    if key == "f2" and not M.open then
      local ok, e = pcall(maxOutHovered)
      if not ok then log("max out error: " .. tostring(e)) end
      return
    end
    if M.open then
      local r = curRows()[M.sel]
      if M.input then
        if key == "backspace" then M.input = M.input:sub(1, -2); if M.input == "" then M.input = nil end
        elseif key == "return" or key == "kpenter" then if commitInput(r) and r.action then activate(r) end
        elseif key == "escape" then M.input = nil
        elseif key == "up" or key == "down" then moveSel(key == "up" and -1 or 1)
        end
        return
      end
      if key == "tab" then setTab(M.tab + (love.keyboard.isDown("lshift", "rshift") and -1 or 1))
      elseif key == "pageup" then setTab(M.tab - 1)
      elseif key == "pagedown" then setTab(M.tab + 1)
      elseif key == "up" then moveSel(-1)
      elseif key == "down" then moveSel(1)
      elseif key == "left" then change(r, -1)
      elseif key == "right" then change(r, 1)
      elseif key == "return" or key == "space" or key == "kpenter" then if r then activate(r) end
      elseif key == "escape" then M.open = false
      end
      return
    end
    return orig(key, ...)
  end
end
function W_.textinput(orig)
  return function(t, ...)
    if M.open then
      local r = curRows()[M.sel]
      if r and r.vkey and t:match("^[%d%.]$") then
        if #(M.input or "") < 10 then M.input = (M.input or "") .. t end
      end
      return
    end
    return orig(t, ...)
  end
end
local function eatWhenOpen(orig) return function(...) if M.open then return end return orig(...) end end
W_.keyreleased = eatWhenOpen
function W_.mousereleased(orig)
  return function(...) M.drag = nil; if M.open then return end return orig(...) end
end
local function overMenu(x, y)
  return x >= M.win.x and x <= M.win.x + WW and y >= M.win.y and y <= M.win.y + winH()
end
function W_.mousepressed(orig)
  return function(x, y, b, ...)
    if M.open then
      local mx, my = love.mouse.getPosition() -- the game passes scaled coordinates
      local h = hitAt(mx, my)
      if h then
        local rows = curRows()
        if h.i and h.i ~= M.sel then M.input = nil end
        if h.i then M.sel = h.i end
        local r = h.i and rows[h.i]
        if h.kind == "drag" then M.drag = { mx - M.win.x, my - M.win.y }
        elseif h.kind == "tab" then setTab(h.t)
        elseif h.kind == "toggle" or h.kind == "apply" then activate(r)
        elseif h.kind == "minus" then change(r, -1)
        elseif h.kind == "plus" then change(r, 1)
        elseif h.kind == "row" and b == 1 and r and r.key and not r.vkey then activate(r)
        end
      end
      if overMenu(mx, my) then return end
      return
    end
    return orig(x, y, b, ...)
  end
end
function W_.wheelmoved(orig)
  return function(x, y, ...)
    if M.open then
      local mx, my = love.mouse.getPosition()
      local h = hitAt(mx, my)
      if h and h.i then
        local r = curRows()[h.i]
        if r and r.vkey then
          if h.i ~= M.sel then M.input = nil end
          M.sel = h.i; change(r, y > 0 and 1 or -1)
        end
      elseif h and h.kind == "tab" then setTab(M.tab + (y > 0 and -1 or 1))
      end
      return
    end
    return orig(x, y, ...)
  end
end

local function noop() end
local function ensureWrapped()
  for name, mk in pairs(W_) do
    local cur = love[name]
    if cur ~= M.wrapped[name] then
      M.orig[name] = cur or noop
      M.wrapped[name] = mk(cur or noop)
      love[name] = M.wrapped[name]
    end
  end
  -- leaderboard guard
  local lb = P["src.leaderboard"]
  if type(lb) == "table" and type(lb.submit) == "function" and lb.submit ~= M.lbWrap then
    local o = lb.submit
    M.lbOrig, M.lbTable = o, lb
    M.lbWrap = function(...) if S.blockLb then return false end return o(...) end
    lb.submit = M.lbWrap
  end
  local okO, eO = pcall(installOdds)
  if not okO and not M.oddsErr then M.oddsErr = true; log("odds install error: " .. tostring(eO)) end
  -- bigger item shop: first argument of item.offer is the number of offers
  local it = P["src.game.item"]
  if type(it) == "table" and type(it.offer) == "function" and it.offer ~= M.offerWrap then
    local o = it.offer
    M.offerOrig, M.offerTable = o, it
    M.offerWrap = function(n, ...)
      if S.shopBig and type(n) == "number" and n >= 3 and n < S.shopBigV then n = S.shopBigV end
      return o(n, ...)
    end
    it.offer = M.offerWrap
  end
  -- bigger item inventory
  local cap = rawget(_G, "getItemInventoryCapacity")
  if type(cap) == "function" and cap ~= M.capWrap then
    M.capOrig = cap
    M.capWrap = function(...)
      local v = cap(...)
      if S.invBig and type(v) == "number" and v < S.invBigV then return S.invBigV end
      return v
    end
    rawset(_G, "getItemInventoryCapacity", M.capWrap)
  end
end

function M.unwrap()
  for name, w in pairs(M.wrapped) do
    if love[name] == w then love[name] = (M.orig[name] ~= noop) and M.orig[name] or nil end
  end
  if M.lbTable and M.lbTable.submit == M.lbWrap then M.lbTable.submit = M.lbOrig end
  if M.offerTable and M.offerTable.offer == M.offerWrap then M.offerTable.offer = M.offerOrig end
  if M.capOrig and rawget(_G, "getItemInventoryCapacity") == M.capWrap then rawset(_G, "getItemInventoryCapacity", M.capOrig) end
end

-- leftovers from debug probes: restore original item functions
do
  local it = P["src.game.item"]
  if type(it) == "table" then
    local po = rawget(_G, "__probeOffer")
    if po then it.offer = po; rawset(_G, "__probeOffer", nil) end
    for _, n in ipairs({ "isMaxed", "owns", "levelOf", "isAvailableForStage" }) do
      local o = rawget(_G, "__probe_" .. n)
      if o then it[n] = o; rawset(_G, "__probe_" .. n, nil) end
    end
  end
end

log("menu loaded (F1 / Insert)")
return function() ensureWrapped() end
