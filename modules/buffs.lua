-- Buffs Module - manual raid/group buffing console (no automation).
-- Mirrors modules/travel.lua: a point-and-click (and slash-command) window
-- that lets one caster buff a whole raid by group, plus single-target buffs
-- on filtered class groups, self buffs and pet buffs. Casts are fire-once and
-- non-blocking, draining a queue one cast at a time via /rgl cast.
local mq        = require('mq')
local Base      = require("modules.base")
local Core      = require("utils.core")
local Casting   = require("utils.casting")
local Config    = require("utils.config")
local Globals   = require("utils.globals")
local Logger    = require("utils.logger")
local Modules   = require("utils.modules")
local Targeting = require("utils.targeting")
local Ui        = require("utils.ui")
local Tables    = require("utils.tables")

local Module    = { _version = '0.1a', _name = "Buffs", _author = 'tuffinmuffin', }
Module.__index  = Module
setmetatable(Module, { __index = Base, })

Module.FAQ             = {}
Module.CommandHandlers = {}

Module.DefaultConfig   = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    [string.format("%s_SavedSets", Module._name)] = {
        DisplayName = Module._name .. " Saved Sets",
        Type = "Custom",
        Default = {},
    },
    [string.format("%s_UserSpells", Module._name)] = {
        DisplayName = Module._name .. " User Spells",
        Type = "Custom",
        Default = {},
    },
}

Module.TempSettings                  = {}
Module.TempSettings.Catalog          = { group = {}, single = {}, self = {}, pet = {}, }
Module.TempSettings.CatalogSeen      = {}
Module.TempSettings.FilterText       = ""
Module.TempSettings.FilteredCatalog  = { group = {}, single = {}, self = {}, pet = {}, }
Module.TempSettings.Queue            = {}
Module.TempSettings.LastCastClock    = 0
Module.TempSettings.Roster           = { inRaid = false, groups = {}, }
Module.TempSettings.RosterClock      = 0
Module.TempSettings.SelectedSetIdx   = 1
Module.TempSettings.CheckedGroupIdx  = 1
Module.TempSettings.SetChecks        = {}  -- key -> bool (include-in-set)
Module.TempSettings.SingleFilters    = {}  -- key -> filter combo index
Module.TempSettings.NewSetName       = ""
Module.TempSettings.NewBuffName      = ""

-- Single-target filter options (combo). Index 1 == "All".
Module.SingleFilterOptions = { "All", "Casters", "Melee", "Tanks", }

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function Module:New()
    return Base.New(self)
end

function Module:Init()
    Logger.log_debug("Buffs Module Loaded.")
    self.TempSettings.Queue = {}
    self.TempSettings.Catalog = { group = {}, single = {}, self = {}, pet = {}, }
    self.TempSettings.CatalogSeen = {}

    self:LoadSettings()
    self:BuildCatalog()
    self:BuildRoster()

    return { self = self, defaults = self.DefaultConfig, }
end

function Module:ShouldRender()
    local c = self.TempSettings.Catalog
    return #c.group > 0 or #c.single > 0 or #c.self > 0 or #c.pet > 0
end

----------------------------------------------------------------------
-- Catalog building
----------------------------------------------------------------------

--- A spell counts as a buff if valid, beneficial, and has a lasting duration.
function Module:isBuff(spell)
    if not spell or not spell() then return false end
    if not spell.Beneficial() then return false end
    return (spell.Duration.TotalSeconds() or 0) > 0
end

-- Spell effect IDs (SPAs) that mark NPC-control / crowd-control spells (lull,
-- blind, charm, fear, mez). These are never cast on group/raid members even
-- though the game may flag the spell "Beneficial", so they should not show up
-- as castable player buffs.
Module.NonBuffSPAs = {
    18, -- Pacify / Lull / Harmony (reduce NPC aggro radius)
    20, -- Blind
    22, -- Charm
    23, -- Fear
    31, -- Mesmerize
}

--- True if the spell carries any NPC-control effect (lull/charm/mez/fear/blind).
function Module:isNpcControlSpell(spell)
    if not spell or not spell() then return false end
    for _, spa in ipairs(self.NonBuffSPAs) do
        if spell.HasSPA(spa)() then return true end
    end
    return false
end

--- Maps an mq TargetType string to a catalog bucket name, or nil to skip.
function Module:bucketForType(tt)
    if tt == "Group v1" or tt == "Group v2" then
        return "group"
    elseif tt == "Single" then
        return "single"
    elseif tt == "Self" then
        return "self"
    elseif tt == "Pet" then
        return "pet"
    end
    return nil
end

--- Adds a resolved spell object to the catalog (de-duped by rank name).
function Module:AddCatalogEntry(spell, source, isCommon)
    if not self:isBuff(spell) then return end
    -- Auto-discovered sources skip crowd-control spells (lull etc.); an explicit
    -- user-added spell is always honored so flexibility is preserved.
    if source ~= "user" and self:isNpcControlSpell(spell) then return end

    local tt = spell.TargetType() or ""
    local bucket = self:bucketForType(tt)
    if not bucket then return end

    local key = spell.RankName() or spell.Name()
    if not key or key == "" then return end
    if self.TempSettings.CatalogSeen[key] then return end
    self.TempSettings.CatalogSeen[key] = true

    local name = spell.Name() or key
    local subcat = spell.Subcategory() or ""

    local entry = {
        key    = key,
        name   = name,
        type   = tt,
        level  = spell.Level() or 0,
        subcat = subcat,
        common = isCommon and true or false,
        source = source,
        v2     = (tt == "Group v2"),
        search = string.format("%s,%s,%s", name, subcat, tt):lower(),
    }

    table.insert(self.TempSettings.Catalog[bucket], entry)
end

function Module:BuildCatalog()
    self.TempSettings.Catalog = { group = {}, single = {}, self = {}, pet = {}, }
    self.TempSettings.CatalogSeen = {}

    -- Source 1: class config AbilitySets (resolved to level) -> COMMON.
    local classMod = Modules.ModuleList and Modules.ModuleList.Class
    local classConfig = classMod and classMod.ClassConfig
    if classConfig and classConfig.AbilitySets then
        for setName, _ in pairs(classConfig.AbilitySets) do
            local resolved = Core.GetResolvedActionMapItem(setName)
            if resolved and resolved() then
                self:AddCatalogEntry(resolved, "ability", true)
            end
        end
    end

    -- Source 2: spellbook scan -> EXTRA (rare).
    for i = 1, Globals.Constants.SpellBookSlots do
        local s = mq.TLO.Me.Book(i)
        if s and s() then
            self:AddCatalogEntry(s, "book", false)
        end
    end

    -- Source 3: user-added spell names -> EXTRA.
    local userSpells = Config:GetSetting("Buffs_UserSpells") or {}
    for _, name in ipairs(userSpells) do
        local s = mq.TLO.Spell(name)
        if s and s() then
            self:AddCatalogEntry(s, "user", false)
        end
    end

    -- Sort each bucket: common first, then level desc, then name.
    local function sorter(a, b)
        if a.common ~= b.common then
            return a.common
        end
        if a.level ~= b.level then
            return a.level > b.level
        end
        return a.name < b.name
    end
    for _, bucket in pairs(self.TempSettings.Catalog) do
        table.sort(bucket, sorter)
    end

    self:GenerateFilteredCatalog()
end

function Module:GenerateFilteredCatalog()
    self.TempSettings.FilteredCatalog = { group = {}, single = {}, self = {}, pet = {}, }
    local filter = (self.TempSettings.FilterText or ""):lower()

    for bucketName, bucket in pairs(self.TempSettings.Catalog) do
        for _, entry in ipairs(bucket) do
            if filter:len() < 1 then
                table.insert(self.TempSettings.FilteredCatalog[bucketName], entry)
            else
                local s = string.find(entry.search, filter, 1, true)
                if s ~= nil then
                    table.insert(self.TempSettings.FilteredCatalog[bucketName], entry)
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- Catalog lookup helpers
----------------------------------------------------------------------

--- Returns a key -> entry map across all buckets.
function Module:CatalogByKey()
    local byKey = {}
    for _, bucket in pairs(self.TempSettings.Catalog) do
        for _, entry in ipairs(bucket) do
            byKey[entry.key] = entry
        end
    end
    return byKey
end

--- Returns the bucket name for an entry based on its type.
function Module:BucketOf(entry)
    return self:bucketForType(entry.type)
end

function Module:SavedSetNames()
    local names = {}
    local sets = Config:GetSetting("Buffs_SavedSets") or {}
    for name, _ in pairs(sets) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

----------------------------------------------------------------------
-- Roster
----------------------------------------------------------------------

--- Resolves a PC member by name to an in-zone spawn id (0 if not present).
local function resolvePcId(name)
    if not name or name == "" then return 0 end
    local spawn = mq.TLO.Spawn("pc =" .. name)
    if spawn and spawn() and (spawn.ID() or 0) > 0 then
        return spawn.ID()
    end
    return 0
end

function Module:BuildRoster()
    local roster = { inRaid = false, groups = {}, }

    if (mq.TLO.Raid.Members() or 0) > 0 then
        roster.inRaid = true
        for i = 1, mq.TLO.Raid.Members() do
            local m = mq.TLO.Raid.Member(i)
            if m and m() then
                local gn = m.Group() or 0
                if gn > 0 then
                    roster.groups[gn] = roster.groups[gn] or { anchorId = 0, anchorName = "", members = {}, }
                    local id = resolvePcId(m.Name())
                    if id > 0 then
                        table.insert(roster.groups[gn].members, id)
                        if roster.groups[gn].anchorId == 0 then
                            roster.groups[gn].anchorId = id
                            roster.groups[gn].anchorName = m.Name()
                        end
                    end
                end
            end
        end
    else
        -- Fallback: single logical group [1] = self + group members.
        local g = { anchorId = mq.TLO.Me.ID() or 0, anchorName = mq.TLO.Me.CleanName() or "", members = {}, }
        if (mq.TLO.Me.ID() or 0) > 0 then
            table.insert(g.members, mq.TLO.Me.ID())
        end
        for i = 1, (mq.TLO.Group.Members() or 0) do
            local m = mq.TLO.Group.Member(i)
            if m and m() and (m.ID() or 0) > 0 then
                table.insert(g.members, m.ID())
            end
        end
        roster.groups[1] = g
    end

    self.TempSettings.Roster = roster
    self.TempSettings.RosterClock = mq.gettime()
end

--- Returns a sorted array of group numbers present in the roster.
function Module:RosterGroupNums()
    local nums = {}
    for gn, _ in pairs(self.TempSettings.Roster.groups) do
        table.insert(nums, gn)
    end
    table.sort(nums)
    return nums
end

----------------------------------------------------------------------
-- Enqueue helpers
----------------------------------------------------------------------

function Module:Enqueue(spellName, targetId, label, group, ignoreMana)
    if not targetId or targetId <= 0 then return end
    table.insert(self.TempSettings.Queue, {
        spellName = spellName,
        targetId = targetId,
        label = label,
        group = group,
        ignoreMana = ignoreMana == true,
    })
end

--- Enqueue a group buff. groupNum nil = all groups. Group v2 (PBAE) only ever
--- affects the caster's own group -> a single self-targeted cast.
function Module:EnqueueGroupBuff(entry, groupNum, ignoreMana)
    if entry.v2 then
        self:Enqueue(entry.key, mq.TLO.Me.ID() or 0, entry.name .. " (Caster Group)", nil, ignoreMana)
        return
    end

    if groupNum == nil then
        for _, gn in ipairs(self:RosterGroupNums()) do
            local g = self.TempSettings.Roster.groups[gn]
            if g and (g.anchorId or 0) > 0 then
                self:Enqueue(entry.key, g.anchorId, string.format("%s (G%d)", entry.name, gn), gn, ignoreMana)
            end
        end
    else
        local g = self.TempSettings.Roster.groups[groupNum]
        if g and (g.anchorId or 0) > 0 then
            self:Enqueue(entry.key, g.anchorId, string.format("%s (G%d)", entry.name, groupNum), groupNum, ignoreMana)
        end
    end
end

--- True if spawn matches the given filter ("all"/"caster"/"melee"/"tank"/<CLR>).
function Module:MatchesFilter(spawn, filter)
    if not spawn or not spawn() then return false end
    filter = (filter or "all"):lower()
    if filter == "all" then return true end
    if filter == "caster" or filter == "casters" then return Targeting.TargetIsACaster(spawn) end
    if filter == "melee" then return Targeting.TargetIsAMelee(spawn) end
    if filter == "tank" or filter == "tanks" then return Targeting.TargetIsATank(spawn) end
    -- Explicit class short name compare.
    local cls = spawn.Class and spawn.Class.ShortName() or ""
    return cls:upper() == filter:upper()
end

--- Enqueue a single-target buff on every unique roster member matching filter.
function Module:EnqueueSingleBuff(entry, filter, ignoreMana)
    local seen = {}
    for _, gn in ipairs(self:RosterGroupNums()) do
        local g = self.TempSettings.Roster.groups[gn]
        for _, id in ipairs(g.members or {}) do
            if not seen[id] then
                seen[id] = true
                local spawn = mq.TLO.Spawn(id)
                if spawn and spawn() and self:MatchesFilter(spawn, filter) then
                    self:Enqueue(entry.key, id, string.format("%s -> %s", entry.name, spawn.CleanName() or tostring(id)), nil, ignoreMana)
                end
            end
        end
    end
end

function Module:EnqueueSelfBuff(entry, ignoreMana)
    self:Enqueue(entry.key, mq.TLO.Me.ID() or 0, entry.name .. " (Self)", nil, ignoreMana)
end

function Module:EnqueuePetBuff(entry, ignoreMana)
    local petId = mq.TLO.Me.Pet.ID() or 0
    if petId <= 0 then
        Logger.log_debug("\ayBuffs: no pet to buff with %s", entry.name)
        return
    end
    self:Enqueue(entry.key, petId, entry.name .. " (Pet)", nil, ignoreMana)
end

----------------------------------------------------------------------
-- Queue processing (fire-once, non-blocking)
----------------------------------------------------------------------

function Module:ProcessQueue()
    if #self.TempSettings.Queue == 0 then return end

    -- Gate: skip this frame (never block).
    if mq.TLO.Me.Casting() then return end
    if (mq.TLO.Cursor.ID() or 0) > 0 then return end
    if (mq.gettime() - self.TempSettings.LastCastClock) < 250 then return end

    local job = self.TempSettings.Queue[1]

    -- Respect the BuffMinMana floor for window-initiated jobs; hold (don't drop)
    -- until mana recovers. Slash-command jobs set ignoreMana and bypass this.
    if not job.ignoreMana and not Casting.HaveManaToBuff() then
        if (mq.gettime() - (self.TempSettings.LastManaHoldLog or 0)) > 5000 then
            Logger.log_debug("\ayBuffs: holding '%s' -- mana %d%% below BuffMinMana (%d%%).",
                job.label or job.spellName, mq.TLO.Me.PctMana() or 0, Config:GetSetting('BuffMinMana'))
            self.TempSettings.LastManaHoldLog = mq.gettime()
        end
        return
    end

    -- Re-validate the target spawn; drop the job if it's gone (no retry).
    local spawn = mq.TLO.Spawn(job.targetId)
    if not (spawn and spawn()) then
        Logger.log_debug("\ayBuffs: target %d no longer valid, dropping '%s'.", job.targetId, job.label or job.spellName)
        table.remove(self.TempSettings.Queue, 1)
        return
    end

    Targeting.SetTarget(job.targetId, true)
    Core.DoCmd('/rgl cast "%s" %d', job.spellName, job.targetId)
    self.TempSettings.LastCastClock = mq.gettime()
    table.remove(self.TempSettings.Queue, 1)
end

function Module:BuffStop()
    self.TempSettings.Queue = {}
    Logger.log_info("\ayBuffs: queue cleared.")
end

function Module:GiveTime()
    self:ProcessQueue()

    -- Refresh roster on a ~3s cadence.
    if (mq.gettime() - self.TempSettings.RosterClock) > 3000 then
        self:BuildRoster()
    end
end

----------------------------------------------------------------------
-- Saved sets & command targets
----------------------------------------------------------------------

--- Cast a saved set. scope is "all" or a group number. ignoreMana=true skips
--- the BuffMinMana floor (slash commands); the window omits it to respect it.
function Module:CastSet(setName, scope, ignoreMana)
    self:BuildRoster()

    local sets = Config:GetSetting("Buffs_SavedSets") or {}
    local set = sets[setName]
    if not set then
        Logger.log_error("\arBuffs: saved set '%s' not found.", tostring(setName))
        return
    end

    local byKey = self:CatalogByKey()
    local groupNum = nil
    if scope ~= nil and tostring(scope):lower() ~= "all" then
        groupNum = tonumber(scope)
    end

    for key, on in pairs(set.spells or {}) do
        if on then
            local entry = byKey[key]
            if entry then
                local bucket = self:BucketOf(entry)
                if bucket == "group" then
                    self:EnqueueGroupBuff(entry, groupNum, ignoreMana)
                elseif bucket == "single" then
                    local filter = (set.filters and set.filters[key]) or "all"
                    self:EnqueueSingleBuff(entry, filter, ignoreMana)
                elseif bucket == "self" then
                    self:EnqueueSelfBuff(entry, ignoreMana)
                elseif bucket == "pet" then
                    self:EnqueuePetBuff(entry, ignoreMana)
                end
            else
                Logger.log_debug("\ayBuffs: set '%s' references unknown buff key '%s'.", setName, key)
            end
        end
    end

    Logger.log_info("\agBuffs: queued set '%s' (%s).", setName, groupNum and ("group " .. groupNum) or "all groups")
end

--- Enqueue all currently-checked group buffs onto group n.
function Module:CastGroupNum(n, ignoreMana)
    self:BuildRoster()
    if not n or not self.TempSettings.Roster.groups[n] then
        Logger.log_error("\arBuffs: group %s is not present in the roster.", tostring(n))
        return
    end

    local count = 0
    for _, entry in ipairs(self.TempSettings.Catalog.group) do
        if self.TempSettings.SetChecks[entry.key] then
            self:EnqueueGroupBuff(entry, n, ignoreMana)
            count = count + 1
        end
    end
    Logger.log_info("\agBuffs: queued %d checked group buff(s) onto group %d.", count, n)
end

--- Returns how many buffs are currently checked (include-in-set boxes).
function Module:CheckedCount()
    local n = 0
    for _, on in pairs(self.TempSettings.SetChecks) do
        if on then n = n + 1 end
    end
    return n
end

--- Clears all include-in-set checkboxes.
function Module:ClearChecks()
    self.TempSettings.SetChecks = {}
end

--- Cast every currently-checked buff now, without saving a set. scope is "all"
--- or a group number (group number only affects group buffs; single/self/pet
--- always fire on their matched targets).
function Module:CastChecked(scope, ignoreMana)
    self:BuildRoster()

    local groupNum = nil
    if scope ~= nil and tostring(scope):lower() ~= "all" then
        groupNum = tonumber(scope)
    end

    local byKey = self:CatalogByKey()
    local count = 0
    for key, on in pairs(self.TempSettings.SetChecks) do
        if on then
            local entry = byKey[key]
            if entry then
                local bucket = self:BucketOf(entry)
                if bucket == "group" then
                    self:EnqueueGroupBuff(entry, groupNum, ignoreMana)
                elseif bucket == "single" then
                    local idx = self.TempSettings.SingleFilters[key] or 1
                    local filter = (self.SingleFilterOptions[idx] or "All"):lower()
                    self:EnqueueSingleBuff(entry, filter, ignoreMana)
                elseif bucket == "self" then
                    self:EnqueueSelfBuff(entry, ignoreMana)
                elseif bucket == "pet" then
                    self:EnqueuePetBuff(entry, ignoreMana)
                end
                count = count + 1
            end
        end
    end

    Logger.log_info("\agBuffs: queued %d checked buff(s) (%s).", count, groupNum and ("group " .. groupNum) or "all groups")
end

--- Read current UI checkbox/filter state into a saved set and persist.
function Module:SaveSet(name)
    if not name or name == "" then
        Logger.log_error("\arBuffs: cannot save a set with no name.")
        return
    end

    local spells = {}
    local filters = {}
    local byKey = self:CatalogByKey()
    for key, on in pairs(self.TempSettings.SetChecks) do
        if on and byKey[key] then
            spells[key] = true
            local entry = byKey[key]
            if self:BucketOf(entry) == "single" then
                local idx = self.TempSettings.SingleFilters[key] or 1
                filters[key] = (self.SingleFilterOptions[idx] or "All"):lower()
            end
        end
    end

    local sets = Config:GetSetting("Buffs_SavedSets") or {}
    sets[name] = { spells = spells, filters = filters, }
    Config:SetSetting("Buffs_SavedSets", sets)
    Logger.log_info("\agBuffs: saved set '%s' (%d buff(s)).", name, Tables.GetTableSize(spells))
end

--- Append a spell name to the user list, persist, and rebuild the catalog.
function Module:AddUserSpell(name)
    if not name or name == "" then
        Logger.log_error("\arBuffs: no spell name given to add.")
        return
    end

    local s = mq.TLO.Spell(name)
    if not (s and s()) then
        Logger.log_error("\arBuffs: '%s' is not a valid spell name.", name)
        return
    end

    local userSpells = Config:GetSetting("Buffs_UserSpells") or {}
    for _, existing in ipairs(userSpells) do
        if existing:lower() == name:lower() then
            Logger.log_info("\ayBuffs: '%s' is already in the user list.", name)
            return
        end
    end
    table.insert(userSpells, name)
    Config:SetSetting("Buffs_UserSpells", userSpells)
    self:BuildCatalog()
    Logger.log_info("\agBuffs: added '%s' to the buff list.", name)
end

----------------------------------------------------------------------
-- Render
----------------------------------------------------------------------

--- Renders one filtered bucket. isGroup toggles group vs single/self/pet rows.
function Module:RenderBuffSection(bucketName, isGroup)
    local entries = self.TempSettings.FilteredCatalog[bucketName] or {}

    local common = {}
    local extra = {}
    for _, entry in ipairs(entries) do
        if entry.common then
            table.insert(common, entry)
        else
            table.insert(extra, entry)
        end
    end

    for _, entry in ipairs(common) do
        self:RenderBuffRow(bucketName, entry, isGroup)
    end

    if #extra > 0 then
        if ImGui.CollapsingHeader(string.format("More / Rare %s Buffs (%d)##rare_%s", isGroup and "Group" or "", #extra, bucketName)) then
            for _, entry in ipairs(extra) do
                self:RenderBuffRow(bucketName, entry, isGroup)
            end
        end
    end

    if #common == 0 and #extra == 0 then
        Ui.RenderText("\ay(no matching buffs)")
    end
end

function Module:RenderBuffRow(bucketName, entry, isGroup)
    ImGui.PushID(entry.key)

    -- Include-in-set checkbox.
    local checked = self.TempSettings.SetChecks[entry.key] or false
    local newChecked = ImGui.Checkbox("##set_" .. entry.key, checked)
    self.TempSettings.SetChecks[entry.key] = newChecked
    if ImGui.IsItemHovered() then
        Ui.MultilineTooltipWithColors({
            { text = "Include in the current set when you Save.", color = Globals.Constants.Colors.FAQDescColor, },
        })
    end
    ImGui.SameLine()

    Ui.RenderText("%s", entry.name)
    if ImGui.IsItemHovered() then
        Ui.MultilineTooltipWithColors({
            { text = string.format("Spell: %s", entry.name),               color = Globals.Constants.Colors.FAQUsageAnswerColor, },
            { text = string.format("Level: %d", entry.level),              color = Globals.Constants.Colors.ConditionPassColor, },
            { text = string.format("Type: %s", entry.type),               color = Globals.Constants.Colors.FAQDescColor, },
            { text = string.format("Subcategory: %s", entry.subcat ~= "" and entry.subcat or "n/a"), color = Globals.Constants.Colors.FAQDescColor, },
            { text = string.format("Source: %s", entry.source),           color = Globals.Constants.Colors.FAQDescColor, },
        })
    end

    if bucketName == "group" then
        ImGui.SameLine()
        if entry.v2 then
            if ImGui.SmallButton("Caster Group##v2_" .. entry.key) then
                self:EnqueueGroupBuff(entry, nil)
            end
            if ImGui.IsItemHovered() then
                Ui.MultilineTooltipWithColors({
                    { text = "Group v2 (PBAE) - only buffs YOUR group regardless of target.", color = Globals.Constants.Colors.ConditionFailColor, },
                })
            end
            -- Disabled per-group buttons to make the limitation visible.
            ImGui.BeginDisabled()
            for _, gn in ipairs(self:RosterGroupNums()) do
                ImGui.SameLine()
                ImGui.SmallButton(string.format("G%d##v2dis_%s", gn, entry.key))
            end
            ImGui.EndDisabled()
        else
            if ImGui.SmallButton("All Groups##all_" .. entry.key) then
                self:EnqueueGroupBuff(entry, nil)
            end
            for _, gn in ipairs(self:RosterGroupNums()) do
                ImGui.SameLine()
                if ImGui.SmallButton(string.format("G%d##g%d_%s", gn, gn, entry.key)) then
                    self:EnqueueGroupBuff(entry, gn)
                end
            end
        end
    elseif bucketName == "single" then
        ImGui.SameLine()
        local idx = self.TempSettings.SingleFilters[entry.key] or 1
        ImGui.PushItemWidth(110)
        local newIdx, changed = ImGui.Combo("##filter_" .. entry.key, idx, self.SingleFilterOptions)
        ImGui.PopItemWidth()
        if changed then
            self.TempSettings.SingleFilters[entry.key] = newIdx
        end
        ImGui.SameLine()
        if ImGui.SmallButton("Cast##cast_" .. entry.key) then
            local filter = (self.SingleFilterOptions[self.TempSettings.SingleFilters[entry.key] or 1] or "All"):lower()
            self:EnqueueSingleBuff(entry, filter)
        end
    elseif bucketName == "self" then
        ImGui.SameLine()
        if ImGui.SmallButton("Cast##selfcast_" .. entry.key) then
            self:EnqueueSelfBuff(entry)
        end
    elseif bucketName == "pet" then
        ImGui.SameLine()
        if ImGui.SmallButton("Cast##petcast_" .. entry.key) then
            self:EnqueuePetBuff(entry)
        end
    end

    ImGui.PopID()
end

function Module:Render()
    Base.Render(self)
    ImGui.NewLine()

    local changed

    -- Roster status line.
    local roster = self.TempSettings.Roster
    local groupNums = self:RosterGroupNums()
    if roster.inRaid then
        Ui.RenderText("Roster: \agRaid\ax - %d group(s)", #groupNums)
    else
        Ui.RenderText("Roster: \agGroup mode\ax")
    end
    ImGui.SameLine()
    if ImGui.SmallButton("Refresh Roster") then
        self:BuildRoster()
    end
    ImGui.SameLine()
    if ImGui.SmallButton("Stop / Clear Queue") then
        self:BuffStop()
    end
    ImGui.SameLine()
    Ui.RenderText("Queued: \at%d", #self.TempSettings.Queue)

    ImGui.Separator()

    -- Ad-hoc "cast what's checked now" bar (no saving required).
    Ui.RenderText("Checked: \at%d", self:CheckedCount())
    ImGui.SameLine()
    if ImGui.SmallButton("Cast Checked -> All Groups") then
        self:CastChecked("all")
    end
    ImGui.SameLine()
    if #groupNums > 0 then
        local groupLabels = {}
        for _, gn in ipairs(groupNums) do table.insert(groupLabels, "G" .. gn) end
        if self.TempSettings.CheckedGroupIdx > #groupLabels then
            self.TempSettings.CheckedGroupIdx = 1
        end
        ImGui.PushItemWidth(70)
        self.TempSettings.CheckedGroupIdx, changed = ImGui.Combo("##checked_group", self.TempSettings.CheckedGroupIdx, groupLabels)
        ImGui.PopItemWidth()
        ImGui.SameLine()
        if ImGui.SmallButton("Cast Checked -> Group") then
            self:CastChecked(groupNums[self.TempSettings.CheckedGroupIdx])
        end
        ImGui.SameLine()
    end
    if ImGui.SmallButton("Clear Checks") then
        self:ClearChecks()
    end

    ImGui.Separator()

    -- Saved-set bar.
    local setNames = self:SavedSetNames()
    if #setNames > 0 then
        if self.TempSettings.SelectedSetIdx > #setNames then
            self.TempSettings.SelectedSetIdx = 1
        end
        ImGui.PushItemWidth(160)
        self.TempSettings.SelectedSetIdx, changed = ImGui.Combo("##saved_sets", self.TempSettings.SelectedSetIdx, setNames)
        ImGui.PopItemWidth()
        ImGui.SameLine()
        if ImGui.SmallButton("Cast Set -> All Groups") then
            local name = setNames[self.TempSettings.SelectedSetIdx]
            if name then self:CastSet(name, "all") end
        end
    else
        Ui.RenderText("\ay(no saved sets yet)")
    end

    -- Save current as set.
    Ui.RenderText("Save Current as Set: ")
    ImGui.SameLine()
    ImGui.PushItemWidth(160)
    self.TempSettings.NewSetName = ImGui.InputText("##new_set_name", self.TempSettings.NewSetName)
    ImGui.PopItemWidth()
    ImGui.SameLine()
    if ImGui.SmallButton("Save Set") then
        if self.TempSettings.NewSetName ~= "" then
            self:SaveSet(self.TempSettings.NewSetName)
            self.TempSettings.NewSetName = ""
        end
    end

    ImGui.Separator()

    -- Filter.
    Ui.RenderText("Filter Buffs: ")
    ImGui.SameLine()
    ImGui.PushItemWidth(200)
    self.TempSettings.FilterText, changed = ImGui.InputText("##buff_filter", self.TempSettings.FilterText)
    ImGui.PopItemWidth()
    if changed then
        self:GenerateFilteredCatalog()
    end

    ImGui.Separator()

    if ImGui.CollapsingHeader("Group Buffs", ImGuiTreeNodeFlags.DefaultOpen) then
        self:RenderBuffSection("group", true)
    end
    if ImGui.CollapsingHeader("Single-Target Buffs", ImGuiTreeNodeFlags.DefaultOpen) then
        self:RenderBuffSection("single", false)
    end
    if ImGui.CollapsingHeader("Self Buffs") then
        self:RenderBuffSection("self", false)
    end
    if ImGui.CollapsingHeader("Pet Buffs") then
        self:RenderBuffSection("pet", false)
    end

    ImGui.Separator()

    -- Add buff by name.
    Ui.RenderText("+ Add Buff by Name: ")
    ImGui.SameLine()
    ImGui.PushItemWidth(200)
    self.TempSettings.NewBuffName = ImGui.InputText("##new_buff_name", self.TempSettings.NewBuffName)
    ImGui.PopItemWidth()
    ImGui.SameLine()
    if ImGui.SmallButton("Add Buff") then
        if self.TempSettings.NewBuffName ~= "" then
            self:AddUserSpell(self.TempSettings.NewBuffName)
            self.TempSettings.NewBuffName = ""
        end
    end
end

return Module
