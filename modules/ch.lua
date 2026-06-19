-- CH (Complete Heal) Chain Module - manual cleric CH-chain coordinator.
--
-- A CH chain keeps a single tank topped off: several clerics stagger their long
-- Complete Heal casts so a CH lands every few seconds. Each cleric, shortly after
-- starting its cast, announces the NEXT cleric to begin. This module lets a cleric
-- START a chain or AUTOMATICALLY FIT IN to one by watching chat:
--   * roster: a manual, ordered list of cleric names (+ saved sets, fill-from-raid).
--   * trigger: a single chat event whose pattern is built from a configurable
--     template; when a line names ME it's my turn.
--   * on my turn: hand-roll a NON-BLOCKING /cast of CH on the chosen tank, then
--     (after a delay measured from cast start) announce the next caller into the
--     chosen channel.
--   * suspension: while a chain is active Globals.CHChainActive suspends ALL other
--     RGMercs activity (see init.lua Main() + modules/class.lua GiveTime guards), so
--     the cleric does nothing but CH on its turns until the chain stops/times out.
--
-- The casting + announce timing is driven from GiveTime as a small state machine
-- (the chat callback is intentionally thin) because every Casting.* helper blocks
-- for the full ~10s cast, which would defeat the stagger.
local mq        = require('mq')
local Base      = require("modules.base")
local Core      = require("utils.core")
local Config    = require("utils.config")
local Globals   = require("utils.globals")
local Logger    = require("utils.logger")
local Targeting = require("utils.targeting")
local Ui        = require("utils.ui")

local Module    = { _version = '0.1a', _name = "CH", _author = 'tuffinmuffin', }
Module.__index  = Module
setmetatable(Module, { __index = Base, })

Module.FAQ             = {}
Module.CommandHandlers = {} -- /rgl ch* commands live in utils/binds.lua (full vararg handling), mirroring Buffs.

-- The single named chat event we (re)register; matched against incoming chat each frame.
Module.TriggerEventName = "RGMercs_CHChainGo"

Module.ChannelOptions   = { "Say", "Group", "Raid", "Auction", "Custom", }

-- Timings are stored in EQ /pause units (1 = 1/10s), so they match the in-game CH
-- social macros (e.g. /pause 20 = 2s). Convert to milliseconds with EQ_DELAY_TO_MS.
Module.EQ_DELAY_TO_MS   = 100

Module.DefaultConfig    = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    ["CH_Roster"] = { DisplayName = "CH Roster", Type = "Custom", Default = {}, },            -- ordered array of cleric names
    ["CH_SavedSets"] = { DisplayName = "CH Saved Sets", Type = "Custom", Default = {}, },      -- name -> ordered roster
    ["CH_TargetName"] = { DisplayName = "CH Target", Type = "Custom", Default = "", },         -- tank name (resolved at cast time)
    ["CH_SpellName"] = { DisplayName = "CH Spell", Type = "Custom", Default = "", },           -- override; "" = auto-detect
    ["CH_ChannelType"] = { DisplayName = "CH Channel", Type = "Custom", Default = "Auction", },   -- Say | Group | Raid | Auction | Custom
    ["CH_CustomChannel"] = { DisplayName = "CH Custom Channel", Type = "Custom", Default = "", },
    -- Defaults mirror the standard /auction CH-chain social format from the game:
    --   status:   [3] -CH < %T > --[3]      announce: [4] -- Jennie GO! -- [4]
    ["CH_AnnounceTemplate"] = { DisplayName = "CH Announce Template", Type = "Custom", Default = "[{nextpos}] -- {next} GO! -- [{nextpos}]", },
    ["CH_StatusTemplate"] = { DisplayName = "CH Status Template", Type = "Custom", Default = "[{pos}] -CH < {target} > --[{pos}]", },
    ["CH_TriggerTemplate"] = { DisplayName = "CH Trigger Template", Type = "Custom", Default = "{me} GO", },
    -- EQ /pause units (1/10s): 20 = 2.0s announce delay, 200 = 20s chain timeout.
    ["CH_AnnounceDelay"] = { DisplayName = "CH Announce Delay (1/10s)", Type = "Custom", Default = 20, },
    ["CH_ChainTimeout"] = { DisplayName = "CH Chain Timeout (1/10s)", Type = "Custom", Default = 200, },
}

Module.TempSettings                  = {}
Module.TempSettings.Active           = false -- chain is running -> suppress everything (mirrors Globals.CHChainActive)
Module.TempSettings.Armed            = false -- listening for my turn (auto fit-in)
Module.TempSettings.GoPending        = false -- a turn was triggered; start the cast next frame
Module.TempSettings.Casting          = false -- we issued a /cast and are watching it
Module.TempSettings.Announced        = false -- already called the next cleric this turn
Module.TempSettings.CastStartTime    = 0
Module.TempSettings.AnnounceAt       = 0      -- 0 until our cast is confirmed started
Module.TempSettings.LastGoTime       = 0      -- liveness clock for the chain timeout
Module.TempSettings.IgnoreTriggerUntil = 0    -- brief self-echo guard after we announce
Module.TempSettings.CHScanName       = nil    -- cached spellbook-scan result
-- UI working buffers (seeded from config; committed on Save).
Module.TempSettings.BufAnnounce      = ""
Module.TempSettings.BufStatus        = ""
Module.TempSettings.BufTrigger       = ""
Module.TempSettings.BufDelay         = 20  -- EQ /pause units (1/10s)
Module.TempSettings.BufTimeout       = 200 -- EQ /pause units (1/10s)
Module.TempSettings.NewRosterName    = ""
Module.TempSettings.NewSetName       = ""
Module.TempSettings.CustomChannelBuf = ""
Module.TempSettings.SelectedSetIdx   = 1

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Logger.log_debug("CH Module Loaded.")
    self:LoadSettings()

    -- Defensive: a fresh script instance must never start suppressed.
    Globals.CHChainActive = false
    self.TempSettings.Active = false
    self.TempSettings.GoPending = false
    self.TempSettings.Casting = false

    self:SeedBuffers()
    self:RegisterTrigger()

    return { self = self, defaults = self.DefaultConfig, }
end

--- Only clerics have Complete Heal -> only clerics see the tab / drive chains.
function Module:ShouldRender()
    return Core.MyClassIs("CLR")
end

--- Copy persisted text/number settings into the editable UI buffers.
function Module:SeedBuffers()
    self.TempSettings.BufAnnounce      = Config:GetSetting('CH_AnnounceTemplate') or ""
    self.TempSettings.BufStatus        = Config:GetSetting('CH_StatusTemplate') or ""
    self.TempSettings.BufTrigger       = Config:GetSetting('CH_TriggerTemplate') or ""
    self.TempSettings.BufDelay         = Config:GetSetting('CH_AnnounceDelay') or 20
    self.TempSettings.BufTimeout       = Config:GetSetting('CH_ChainTimeout') or 200
    self.TempSettings.CustomChannelBuf = Config:GetSetting('CH_CustomChannel') or ""
end

----------------------------------------------------------------------
-- Roster / identity helpers
----------------------------------------------------------------------

function Module:MyName()
    return mq.TLO.Me.CleanName() or ""
end

function Module:Roster()
    return Config:GetSetting('CH_Roster') or {}
end

function Module:SaveRoster(roster)
    Config:SetSetting('CH_Roster', roster)
end

--- My 1-based slot in the roster (case-insensitive), or nil if I'm not listed.
function Module:MyPosition()
    local me = self:MyName():lower()
    for i, n in ipairs(self:Roster()) do
        if (n or ""):lower() == me then return i end
    end
    return nil
end

--- The cleric after me (wraps around), and their position. nil if I'm not in the roster.
function Module:NextCaster()
    local roster = self:Roster()
    local n = #roster
    if n == 0 then return nil, nil end
    local pos = self:MyPosition()
    if not pos then return nil, nil end
    local nextpos = (pos % n) + 1
    return roster[nextpos], nextpos
end

function Module:AddToRoster(name)
    if not name or name == "" then
        Logger.log_error("\arCH: no name given to add to the roster.")
        return
    end
    local roster = self:Roster()
    for _, n in ipairs(roster) do
        if (n or ""):lower() == name:lower() then
            Logger.log_info("\ayCH: '%s' is already in the roster.", name)
            return
        end
    end
    table.insert(roster, name)
    self:SaveRoster(roster)
    self:RegisterTrigger() -- position may now resolve / change
    Logger.log_info("\agCH: added '%s' to the roster.", name)
end

function Module:RemoveFromRoster(idx)
    local roster = self:Roster()
    if roster[idx] then
        local n = table.remove(roster, idx)
        self:SaveRoster(roster)
        self:RegisterTrigger()
        Logger.log_info("\ayCH: removed '%s' from the roster.", n)
    end
end

--- Move a roster entry by dir (-1 up, +1 down).
function Module:MoveRoster(idx, dir)
    local roster = self:Roster()
    local j = idx + dir
    if roster[idx] and roster[j] then
        roster[idx], roster[j] = roster[j], roster[idx]
        self:SaveRoster(roster)
        self:RegisterTrigger()
    end
end

--- Replace the roster with the clerics currently in the raid (or group), in order.
function Module:FillFromRaidOrGroup()
    local names, seen = {}, {}
    local function add(name)
        if name and name ~= "" and not seen[name:lower()] then
            seen[name:lower()] = true
            table.insert(names, name)
        end
    end

    if (mq.TLO.Raid.Members() or 0) > 0 then
        for i = 1, mq.TLO.Raid.Members() do
            local m = mq.TLO.Raid.Member(i)
            if m and m() and m.Class and m.Class.ShortName() == "CLR" then add(m.Name()) end
        end
    else
        if self:MyName() ~= "" and Core.MyClassIs("CLR") then add(self:MyName()) end
        for i = 1, (mq.TLO.Group.Members() or 0) do
            local m = mq.TLO.Group.Member(i)
            if m and m() and m.Class and m.Class.ShortName() == "CLR" then add(m.CleanName()) end
        end
    end

    self:SaveRoster(names)
    self:RegisterTrigger()
    Logger.log_info("\agCH: filled roster with %d cleric(s).", #names)
end

function Module:SavedSetNames()
    local names = {}
    for name, _ in pairs(Config:GetSetting('CH_SavedSets') or {}) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

function Module:SaveSet(name)
    if not name or name == "" then
        Logger.log_error("\arCH: a set name is required to save.")
        return
    end
    local sets = Config:GetSetting('CH_SavedSets') or {}
    local copy = {}
    for i, n in ipairs(self:Roster()) do copy[i] = n end
    sets[name] = copy
    Config:SetSetting('CH_SavedSets', sets)
    Logger.log_info("\agCH: saved roster set '%s' (%d cleric(s)).", name, #copy)
end

function Module:LoadSet(name)
    local sets = Config:GetSetting('CH_SavedSets') or {}
    local set = sets[name]
    if not set then
        Logger.log_error("\arCH: saved set '%s' not found.", tostring(name))
        return
    end
    local copy = {}
    for i, n in ipairs(set) do copy[i] = n end
    self:SaveRoster(copy)
    self:RegisterTrigger()
    Logger.log_info("\agCH: loaded roster set '%s'.", name)
end

----------------------------------------------------------------------
-- Target / spell resolution
----------------------------------------------------------------------

function Module:TargetName()
    return Config:GetSetting('CH_TargetName') or ""
end

--- Resolve the configured tank name to a live spawn id (PC first, then any spawn). 0 if not found.
function Module:ResolveTarget()
    local name = self:TargetName()
    if not name or name == "" then return 0 end
    local spawn = mq.TLO.Spawn("pc =" .. name)
    if spawn and spawn() and (spawn.ID() or 0) > 0 then return spawn.ID() end
    spawn = mq.TLO.Spawn("=" .. name)
    if spawn and spawn() and (spawn.ID() or 0) > 0 then return spawn.ID() end
    return 0
end

function Module:SetTargetName(name)
    if not name or name == "" then name = mq.TLO.Target.CleanName() end
    if not name or name == "" then
        Logger.log_error("\arCH: no name given and no valid target to set.")
        return
    end
    Config:SetSetting('CH_TargetName', name)
    Logger.log_info("\agCH: chain target set to '%s'.", name)
end

--- The CH spell to cast: explicit override -> class-resolved CompleteHeal -> spellbook scan.
function Module:GetCHSpell()
    local override = Config:GetSetting('CH_SpellName')
    if override and override ~= "" then
        local s = mq.TLO.Spell(override)
        if s and s() then return s end
    end

    local resolved = Core.GetResolvedActionMapItem('CompleteHeal')
    if resolved and resolved() then return resolved end

    if not self.TempSettings.CHScanName then
        for i = 1, Globals.Constants.SpellBookSlots do
            local s = mq.TLO.Me.Book(i)
            if s and s() and (s.Name() or ""):find("Complete Heal") then
                -- Book() is highest-first per rank; keep the highest level seen.
                if not self.TempSettings.CHScanName or (s.Level() or 0) > (mq.TLO.Spell(self.TempSettings.CHScanName).Level() or 0) then
                    self.TempSettings.CHScanName = s.Name()
                end
            end
        end
    end
    if self.TempSettings.CHScanName then
        local s = mq.TLO.Spell(self.TempSettings.CHScanName)
        if s and s() then return s end
    end
    return nil
end

local function spellRankName(sp)
    if not sp or not sp() then return nil end
    local rn = sp.RankName and sp.RankName()
    if rn and rn ~= "" then return rn end
    return sp.Name()
end

----------------------------------------------------------------------
-- Templates & announcing
----------------------------------------------------------------------

--- Substitute {me}{pos}{next}{nextpos}{target} from current state.
function Module:RenderTemplate(tpl)
    if not tpl then return "" end
    local nextName, nextPos = self:NextCaster()
    local subs = {
        ["{me}"]      = self:MyName(),
        ["{pos}"]     = tostring(self:MyPosition() or 0),
        ["{next}"]    = nextName or "?",
        ["{nextpos}"] = tostring(nextPos or 0),
        ["{target}"]  = self:TargetName() ~= "" and self:TargetName() or "?",
    }
    local out = tpl
    for k, v in pairs(subs) do
        out = out:gsub(k, function() return v end) -- function repl avoids % escaping issues
    end
    return out
end

--- A configured EQ /pause-unit value (1/10s) as milliseconds.
function Module:DelayMs(settingKey, defaultUnits)
    local units = Config:GetSetting(settingKey) or defaultUnits
    return units * self.EQ_DELAY_TO_MS
end

--- Send a fully-rendered message to the configured channel.
function Module:Announce(msg)
    if not msg or msg == "" then return end
    local t = Config:GetSetting('CH_ChannelType') or "Auction"
    if t == "Say" then
        Core.DoCmd("/say %s", msg)
    elseif t == "Group" then
        Core.DoCmd("/gsay %s", msg)
    elseif t == "Raid" then
        Core.DoCmd("/rsay %s", msg)
    elseif t == "Auction" then
        Core.DoCmd("/auction %s", msg)
    else
        local ch = (Config:GetSetting('CH_CustomChannel') or ""):gsub("^/", "")
        if ch == "" then
            Logger.log_error("\arCH: custom channel selected but no channel name set.")
            return
        end
        Core.DoCmd("/%s %s", ch, msg)
    end
end

----------------------------------------------------------------------
-- Chat trigger (single broad-but-specific event; re-registered on changes)
----------------------------------------------------------------------

--- Build the event pattern from the trigger template: identity placeholders are
--- filled in (so the line must name ME), everything else becomes a wildcard, and
--- the whole thing is wrapped so it can match anywhere inside a chat line.
function Module:TriggerPattern()
    local tpl = Config:GetSetting('CH_TriggerTemplate') or "{me} GO"
    local pat = tpl:gsub("{me}", self:MyName())
        :gsub("{pos}", tostring(self:MyPosition() or 0))
        :gsub("{next}", "#*#")
        :gsub("{nextpos}", "#*#")
        :gsub("{target}", "#*#")
    return "#*#" .. pat .. "#*#"
end

function Module:RegisterTrigger()
    pcall(function() mq.unevent(self.TriggerEventName) end)
    local ok, err = pcall(function()
        mq.event(self.TriggerEventName, self:TriggerPattern(), function(line) self:OnTriggerLine(line) end)
    end)
    if not ok then
        Logger.log_error("\arCH: failed to register trigger event: %s", tostring(err))
    end
end

--- Thin chat callback: only mark intent, let GiveTime do the work.
function Module:OnTriggerLine(line)
    if not Core.MyClassIs("CLR") then return end
    if not (self.TempSettings.Armed or self.TempSettings.Active) then return end
    if mq.gettime() < (self.TempSettings.IgnoreTriggerUntil or 0) then return end -- our own echo
    if self.TempSettings.GoPending or self.TempSettings.Casting then return end   -- already taking a turn
    if not self:MyPosition() then
        Logger.log_debug("\ayCH: GO matched but I'm not in the roster - ignoring.")
        return
    end
    Logger.log_debug("\agCH: turn trigger matched: %s", line or "?")
    self:HandleGo()
end

----------------------------------------------------------------------
-- Chain control
----------------------------------------------------------------------

--- Begin (or refresh) my participation: become active and queue a cast turn.
function Module:HandleGo()
    self.TempSettings.Active = true
    Globals.CHChainActive = true
    self.TempSettings.GoPending = true
    self.TempSettings.LastGoTime = mq.gettime()
end

--- Kick off the chain (I'm the starter): cast immediately, then call the next cleric.
function Module:StartChain()
    if not Core.MyClassIs("CLR") then
        Logger.log_error("\arCH: chains are cleric-only.")
        return
    end
    if not self:MyPosition() then
        Logger.log_error("\arCH: you (%s) are not in the roster - add yourself first.", self:MyName())
        return
    end
    if self:ResolveTarget() <= 0 then
        Logger.log_error("\arCH: no valid chain target. Use /rgl chtarget <name> (or target the tank).")
        return
    end
    self.TempSettings.Armed = true
    Logger.log_info("\agCH: starting chain on '%s'.", self:TargetName())
    self:HandleGo()
end

--- Stop the chain and clear suppression. Does NOT disarm (still listens for the next chain).
function Module:Stop(reason)
    if self.TempSettings.Active then
        Logger.log_info("\ayCH: chain stopped%s.", reason and (" (" .. reason .. ")") or "")
    end
    self.TempSettings.Active = false
    self.TempSettings.GoPending = false
    self.TempSettings.Casting = false
    self.TempSettings.Announced = false
    self.TempSettings.AnnounceAt = 0
    Globals.CHChainActive = false
end

--- Arm / disarm auto fit-in. Disarming also stops any active chain.
function Module:SetArmed(on)
    self.TempSettings.Armed = on and true or false
    Logger.log_info("\ayCH: auto fit-in %s.", self.TempSettings.Armed and "\agARMED" or "\arOFF")
    if not self.TempSettings.Armed then self:Stop("disarmed") end
end

----------------------------------------------------------------------
-- Per-frame state machine
----------------------------------------------------------------------

--- Start a non-blocking CH cast on the tank. Returns true if the cast was issued.
function Module:BeginCast()
    local tankId = self:ResolveTarget()
    if tankId <= 0 then
        Logger.log_error("\arCH: target '%s' not found - stopping chain.", self:TargetName())
        self:Stop("no target")
        return false
    end

    local sp = self:GetCHSpell()
    local rank = spellRankName(sp)
    if not rank then
        Logger.log_error("\arCH: no Complete Heal spell resolved - stopping chain.")
        self:Stop("no spell")
        return false
    end

    -- A chain cleric keeps CH memorized; never block to memorize mid-chain.
    local gem = mq.TLO.Me.Gem(rank)()
    if not gem or gem == 0 then
        Logger.log_error("\arCH: '%s' is not memorized - cannot chain. Mem it and retry.", rank)
        self:Stop("not memmed")
        return false
    end
    if not mq.TLO.Me.SpellReady(rank)() then
        -- On cooldown right when called: skip our cast but keep the chain alive.
        Logger.log_warn("\ayCH: '%s' not ready on my turn - passing to next.", rank)
        self:Announce(self:RenderTemplate(Config:GetSetting('CH_AnnounceTemplate')))
        self.TempSettings.IgnoreTriggerUntil = mq.gettime() + 2000
        self.TempSettings.LastGoTime = mq.gettime()
        return false
    end

    Core.DoCmd("/stopcast")
    Core.DoCmd("/attack off")
    Targeting.SetTarget(tankId, true)
    mq.delay(100, function() return (mq.TLO.Target.ID() or 0) == tankId end)
    Core.DoCmd("/cast %d", gem)

    self.TempSettings.Casting = true
    self.TempSettings.Announced = false
    self.TempSettings.CastStartTime = mq.gettime()
    self.TempSettings.AnnounceAt = 0
    return true
end

--- Watch the in-progress cast: schedule + send the next-caller announce, detect end.
function Module:WatchCast()
    local casting = (mq.TLO.Me.Casting.ID() or 0) ~= 0

    -- Cast confirmed started: schedule the staggered announce + (optional) status line.
    if casting and self.TempSettings.AnnounceAt == 0 then
        self.TempSettings.AnnounceAt = mq.gettime() + self:DelayMs('CH_AnnounceDelay', 20)
        local status = Config:GetSetting('CH_StatusTemplate')
        if status and status ~= "" then self:Announce(self:RenderTemplate(status)) end
    end

    -- Time to call the next cleric.
    if not self.TempSettings.Announced and self.TempSettings.AnnounceAt > 0 and mq.gettime() >= self.TempSettings.AnnounceAt then
        self:Announce(self:RenderTemplate(Config:GetSetting('CH_AnnounceTemplate')))
        self.TempSettings.Announced = true
        self.TempSettings.IgnoreTriggerUntil = mq.gettime() + 2000
    end

    -- Cast finished (or was interrupted) after it had started.
    if self.TempSettings.AnnounceAt > 0 and not casting then
        if not self.TempSettings.Announced then -- very short / interrupted cast: still hand off
            self:Announce(self:RenderTemplate(Config:GetSetting('CH_AnnounceTemplate')))
            self.TempSettings.Announced = true
            self.TempSettings.IgnoreTriggerUntil = mq.gettime() + 2000
        end
        self.TempSettings.Casting = false
        self.TempSettings.LastGoTime = mq.gettime()
    end

    -- Cast never started (fizzled to begin / interrupted instantly): don't stall the chain.
    if self.TempSettings.AnnounceAt == 0 and (mq.gettime() - self.TempSettings.CastStartTime) > 3000 then
        Logger.log_warn("\ayCH: cast didn't start - passing to next.")
        self:Announce(self:RenderTemplate(Config:GetSetting('CH_AnnounceTemplate')))
        self.TempSettings.Casting = false
        self.TempSettings.IgnoreTriggerUntil = mq.gettime() + 2000
        self.TempSettings.LastGoTime = mq.gettime()
    end
end

function Module:GiveTime()
    if not self.TempSettings.Active then return end

    -- Keep the global suppression flag in lockstep with our active state.
    Globals.CHChainActive = true

    if self.TempSettings.GoPending and not self.TempSettings.Casting then
        self.TempSettings.GoPending = false
        self:BeginCast()
    end

    if self.TempSettings.Casting then
        self:WatchCast()
        return
    end

    -- Idle between turns: stay suspended, but bail if the chain has gone quiet or
    -- the target vanished.
    if self:ResolveTarget() <= 0 then
        self:Stop("target gone")
        return
    end
    if (mq.gettime() - (self.TempSettings.LastGoTime or 0)) > self:DelayMs('CH_ChainTimeout', 200) then
        self:Stop("timeout")
    end
end

function Module:OnZone()
    self:Stop("zoned")
end

function Module:OnDeath()
    self:Stop("died")
end

----------------------------------------------------------------------
-- Render
----------------------------------------------------------------------

function Module:RenderStatus()
    local active = self.TempSettings.Active
    local stateColor = active and Globals.Constants.Colors.ConditionFailColor or Globals.Constants.Colors.ConditionPassColor
    Ui.RenderText("State: ")
    ImGui.SameLine()
    Ui.RenderColoredText(stateColor, active and "CHAIN ACTIVE (all else suspended)" or "Idle")

    Ui.RenderText("Auto fit-in: ")
    ImGui.SameLine()
    Ui.RenderColoredText(self.TempSettings.Armed and Globals.Constants.Colors.ConditionPassColor or Globals.Constants.Colors.ConditionFailColor,
        self.TempSettings.Armed and "Armed" or "Off")

    local pos = self:MyPosition()
    local nextName = select(1, self:NextCaster())
    local sp = self:GetCHSpell()
    Ui.RenderText("Me: \at%s\ax  Pos: \at%s\ax  Next: \at%s\ax", self:MyName(), pos and tostring(pos) or "(not in roster)", nextName or "?")
    Ui.RenderText("Target: \at%s\ax  CH Spell: \at%s\ax", self:TargetName() ~= "" and self:TargetName() or "(none)", spellRankName(sp) or "(none detected)")

    if active and self.TempSettings.Casting and self.TempSettings.AnnounceAt > 0 and not self.TempSettings.Announced then
        local left = math.max(0, self.TempSettings.AnnounceAt - mq.gettime())
        Ui.RenderText("Announcing next in: \am%.1fs", left / 1000)
    end
end

function Module:RenderControls()
    if ImGui.SmallButton("Start Chain") then self:StartChain() end
    ImGui.SameLine()
    if ImGui.SmallButton("Stop Chain") then self:Stop("manual") end
    ImGui.SameLine()
    if ImGui.SmallButton(self.TempSettings.Armed and "Disarm Auto Fit-In" or "Arm Auto Fit-In") then
        self:SetArmed(not self.TempSettings.Armed)
    end
    ImGui.SameLine()
    -- Force the chain to proceed now: cast CH on the target and announce the next
    -- caller immediately, without waiting for a chat trigger. Use this to recover a
    -- missed/stalled chain (a dropped call, a fizzle, etc.).
    if ImGui.SmallButton("Force Chain Now") then self:StartChain() end
    if ImGui.IsItemHovered() then
        Ui.MultilineTooltipWithColors({
            { text = "Force the CH chain to proceed from you right now:", color = Globals.Constants.Colors.FAQDescColor, },
            { text = "cast CH on the target and call the next cleric, without", color = Globals.Constants.Colors.FAQDescColor, },
            { text = "waiting for a chat trigger. Recovers a missed/stalled chain.", color = Globals.Constants.Colors.FAQDescColor, },
        })
    end
end

function Module:RenderTargetAndChannel()
    Ui.RenderText("Chain Target: ")
    ImGui.SameLine()
    ImGui.PushItemWidth(160)
    local newName, changedT = ImGui.InputText("##ch_target", self:TargetName())
    ImGui.PopItemWidth()
    if changedT then Config:SetSetting('CH_TargetName', newName) end
    ImGui.SameLine()
    if ImGui.SmallButton("Use Current Target") then self:SetTargetName(nil) end

    Ui.RenderText("Announce Channel: ")
    ImGui.SameLine()
    local cur = Config:GetSetting('CH_ChannelType') or "Raid"
    local idx = 3
    for i, c in ipairs(self.ChannelOptions) do if c == cur then idx = i end end
    ImGui.PushItemWidth(110)
    local newIdx, changedC = ImGui.Combo("##ch_channel", idx, self.ChannelOptions)
    ImGui.PopItemWidth()
    if changedC then Config:SetSetting('CH_ChannelType', self.ChannelOptions[newIdx]) end

    if (Config:GetSetting('CH_ChannelType') or "Raid") == "Custom" then
        ImGui.SameLine()
        Ui.RenderText("Channel: ")
        ImGui.SameLine()
        ImGui.PushItemWidth(120)
        local newCh, changedCh = ImGui.InputText("##ch_customchannel", self.TempSettings.CustomChannelBuf)
        ImGui.PopItemWidth()
        if changedCh then
            self.TempSettings.CustomChannelBuf = newCh
            Config:SetSetting('CH_CustomChannel', newCh)
        end
    end
end

function Module:RenderTemplatesAndTimings()
    local changed
    Ui.RenderText("Announce (call next): ")
    ImGui.SameLine()
    ImGui.PushItemWidth(300)
    self.TempSettings.BufAnnounce = ImGui.InputText("##ch_tpl_announce", self.TempSettings.BufAnnounce)
    ImGui.PopItemWidth()

    Ui.RenderText("Status (on cast, blank=off): ")
    ImGui.SameLine()
    ImGui.PushItemWidth(300)
    self.TempSettings.BufStatus = ImGui.InputText("##ch_tpl_status", self.TempSettings.BufStatus)
    ImGui.PopItemWidth()

    Ui.RenderText("Trigger (my turn): ")
    ImGui.SameLine()
    ImGui.PushItemWidth(300)
    self.TempSettings.BufTrigger = ImGui.InputText("##ch_tpl_trigger", self.TempSettings.BufTrigger)
    ImGui.PopItemWidth()
    if ImGui.IsItemHovered() then
        Ui.MultilineTooltipWithColors({
            { text = "Placeholders: {me} {pos} {next} {nextpos} {target}", color = Globals.Constants.Colors.FAQDescColor, },
            { text = "Keep the Trigger consistent with what others' Announce produces for you,", color = Globals.Constants.Colors.FAQDescColor, },
            { text = "so the line that names you matches (default: announce '{next} GO' / trigger '{me} GO').", color = Globals.Constants.Colors.FAQDescColor, },
        })
    end

    -- Timings use EQ /pause units (1/10s), matching the in-game CH socials (/pause 20 = 2s).
    ImGui.PushItemWidth(160)
    self.TempSettings.BufDelay, changed = ImGui.InputInt("Announce Delay (1/10s, like /pause)##ch_delay", math.floor(self.TempSettings.BufDelay or 20), 1, 5, ImGuiInputTextFlags.None)
    if changed and self.TempSettings.BufDelay < 0 then self.TempSettings.BufDelay = 0 end
    self.TempSettings.BufTimeout, changed = ImGui.InputInt("Chain Timeout (1/10s)##ch_timeout", math.floor(self.TempSettings.BufTimeout or 200), 10, 50, ImGuiInputTextFlags.None)
    if changed and self.TempSettings.BufTimeout < 10 then self.TempSettings.BufTimeout = 10 end
    ImGui.PopItemWidth()
    Ui.RenderText("\ay(Announce delay \at%.1fs\ay, chain timeout \at%.1fs\ay)", (self.TempSettings.BufDelay or 0) / 10, (self.TempSettings.BufTimeout or 0) / 10)

    if ImGui.SmallButton("Save Settings") then
        Config:SetSetting('CH_AnnounceTemplate', self.TempSettings.BufAnnounce)
        Config:SetSetting('CH_StatusTemplate', self.TempSettings.BufStatus)
        Config:SetSetting('CH_TriggerTemplate', self.TempSettings.BufTrigger)
        Config:SetSetting('CH_AnnounceDelay', self.TempSettings.BufDelay)
        Config:SetSetting('CH_ChainTimeout', self.TempSettings.BufTimeout)
        self:RegisterTrigger()
        Logger.log_info("\agCH: settings saved.")
    end
    ImGui.SameLine()
    if ImGui.SmallButton("Revert") then self:SeedBuffers() end
end

function Module:RenderRoster()
    local roster = self:Roster()
    local me = self:MyName():lower()
    for i, name in ipairs(roster) do
        ImGui.PushID("ch_roster_" .. i)
        local isMe = (name or ""):lower() == me
        Ui.RenderColoredText(isMe and Globals.Constants.Colors.ConditionPassColor or Globals.Constants.Colors.FAQUsageAnswerColor,
            "%d. %s%s", i, name, isMe and "  <- me" or "")
        ImGui.SameLine()
        if ImGui.SmallButton("Up") then self:MoveRoster(i, -1) end
        ImGui.SameLine()
        if ImGui.SmallButton("Dn") then self:MoveRoster(i, 1) end
        ImGui.SameLine()
        if ImGui.SmallButton("X") then self:RemoveFromRoster(i) end
        ImGui.PopID()
    end
    if #roster == 0 then Ui.RenderText("\ay(roster is empty)") end

    Ui.RenderText("Add Cleric: ")
    ImGui.SameLine()
    ImGui.PushItemWidth(160)
    self.TempSettings.NewRosterName = ImGui.InputText("##ch_addname", self.TempSettings.NewRosterName)
    ImGui.PopItemWidth()
    ImGui.SameLine()
    if ImGui.SmallButton("Add") then
        if self.TempSettings.NewRosterName ~= "" then
            self:AddToRoster(self.TempSettings.NewRosterName)
            self.TempSettings.NewRosterName = ""
        end
    end
    ImGui.SameLine()
    if ImGui.SmallButton("Add Me") then self:AddToRoster(self:MyName()) end
    ImGui.SameLine()
    if ImGui.SmallButton("Fill from Raid/Group") then self:FillFromRaidOrGroup() end
end

function Module:RenderSavedSets()
    local setNames = self:SavedSetNames()
    if #setNames > 0 then
        if self.TempSettings.SelectedSetIdx > #setNames then self.TempSettings.SelectedSetIdx = 1 end
        ImGui.PushItemWidth(160)
        self.TempSettings.SelectedSetIdx = ImGui.Combo("##ch_sets", self.TempSettings.SelectedSetIdx, setNames)
        ImGui.PopItemWidth()
        ImGui.SameLine()
        if ImGui.SmallButton("Load Set") then
            local n = setNames[self.TempSettings.SelectedSetIdx]
            if n then self:LoadSet(n) end
        end
    else
        Ui.RenderText("\ay(no saved roster sets yet)")
    end

    Ui.RenderText("Save Roster as: ")
    ImGui.SameLine()
    ImGui.PushItemWidth(160)
    self.TempSettings.NewSetName = ImGui.InputText("##ch_newset", self.TempSettings.NewSetName)
    ImGui.PopItemWidth()
    ImGui.SameLine()
    if ImGui.SmallButton("Save Set") then
        if self.TempSettings.NewSetName ~= "" then
            self:SaveSet(self.TempSettings.NewSetName)
            self.TempSettings.NewSetName = ""
        end
    end
end

function Module:Render()
    Base.Render(self)
    ImGui.NewLine()

    self:RenderStatus()
    ImGui.Separator()
    self:RenderControls()
    ImGui.Separator()
    self:RenderTargetAndChannel()
    ImGui.Separator()

    if ImGui.CollapsingHeader("Roster", ImGuiTreeNodeFlags.DefaultOpen) then
        self:RenderRoster()
        ImGui.NewLine()
        self:RenderSavedSets()
    end

    if ImGui.CollapsingHeader("Templates & Timings") then
        self:RenderTemplatesAndTimings()
    end
end

return Module
