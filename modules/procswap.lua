-- ProcSwap Module - swaps to a Bandolier "proc" weapon set until a configured
-- buff (self) or debuff (target) lands, then swaps to a "main" set until the
-- effect drops off (self) or the target changes/dies (target), repeating for
-- the whole fight. Class-agnostic: rules are user-defined via the GUI, no
-- class_config wiring needed.
local mq          = require('mq')
local Base        = require("modules.base")
local Casting     = require("utils.casting")
local Combat      = require("utils.combat")
local Config      = require("utils.config")
local Core        = require("utils.core")
local Globals     = require("utils.globals")
local Logger      = require("utils.logger")
local Targeting   = require("utils.targeting")
local Ui          = require("utils.ui")

local Module      = { _version = '0.1a', _name = "ProcSwap", _author = 'tuffinmuffin', }
Module.__index    = Module
setmetatable(Module, { __index = Base, })

Module.FAQ             = {}
Module.CommandHandlers = {}

Module.DefaultConfig   = {
    [string.format("%s_Popped", Module._name)] = {
        DisplayName = Module._name .. " Popped",
        Type = "Custom",
        Default = false,
    },
    [string.format("%s_Rules", Module._name)] = {
        DisplayName = Module._name .. " Rules",
        Type = "Custom",
        Default = {},
    },
}

Module.ScopeOptions   = { "Self", "Target", }
Module.EvalThrottleMs = 200 -- re-check each rule at most 5x/sec; GiveTime runs every frame

Module.TempSettings              = {}
Module.TempSettings.Rules        = {}
Module.TempSettings.RuleRuntime  = {} -- id -> { lastEvalMs, lastKnownActive, setMissingWarned }
Module.TempSettings.NewRuleName  = ""

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function Module:New()
    return Base.New(self)
end

function Module:NewRuleId()
    return string.format("%d_%d", mq.gettime(), math.random(1000, 9999))
end

--- Writes the current in-memory rule list to persisted config.
function Module:PersistRules()
    Config:SetSetting("ProcSwap_Rules", self.TempSettings.Rules)
end

function Module:Init()
    Logger.log_debug("ProcSwap Module Loaded.")

    self:LoadSettings()
    self.TempSettings.Rules = Config:GetSetting("ProcSwap_Rules") or {}
    self.TempSettings.RuleRuntime = {}

    if #self.TempSettings.Rules == 0 then
        table.insert(self.TempSettings.Rules, {
            id      = self:NewRuleId(),
            name    = "Avatar",
            enabled = false,
            scope   = "self",
            effect  = "Avatar",
            procSet = "avatar",
            mainSet = "",
        })
        self:PersistRules()
    end

    return { self = self, defaults = self.DefaultConfig, }
end

function Module:ShouldRender()
    return true
end

----------------------------------------------------------------------
-- Rule evaluation
----------------------------------------------------------------------

-- Activates a Bandolier set directly (bypassing ItemManager.BandolierSwap):
-- that helper gates on the 'UseBandolier' setting, which several class
-- configs define independently for their own tank-weapon-swap features --
-- it isn't a real global toggle, so on classes that never register it,
-- ItemManager.BandolierSwap's Config:GetSetting('UseBandolier') call errors
-- every time. ProcSwap is class-agnostic, so each rule's own Enabled
-- checkbox is the only gate it needs.
local function bandolierActivate(indexName)
    if mq.TLO.Me.Bandolier(indexName).Index() and not mq.TLO.Me.Bandolier(indexName).Active() then
        Core.DoCmd("/bandolier activate %s", indexName)
    end
end

--- Decides which Bandolier set should be active for one rule and swaps if needed.
function Module:EvaluateRule(rule, runtime)
    if rule.effect == "" or rule.procSet == "" or rule.mainSet == "" then return end

    local procMissing = not mq.TLO.Me.Bandolier(rule.procSet).Index()
    local mainMissing = not mq.TLO.Me.Bandolier(rule.mainSet).Index()
    if procMissing or mainMissing then
        if not runtime.setMissingWarned then
            Logger.log_warn("\arProcSwap: rule '%s' references a missing Bandolier set (proc='%s' main='%s').",
                rule.name, rule.procSet, rule.mainSet)
            runtime.setMissingWarned = true
        end
        return
    end
    runtime.setMissingWarned = false

    local effectActive
    if rule.scope == "target" then
        effectActive = Targeting.TargetIsType("NPC") and Casting.TargetHasBuff(rule.effect, nil, false) or false
    else
        effectActive = Casting.IHaveBuff(rule.effect)
    end

    runtime.lastKnownActive = effectActive
    bandolierActivate(effectActive and rule.mainSet or rule.procSet)
end

function Module:GiveTime()
    if Combat.GetCombatState() ~= "Combat" then return end

    local now = Globals.GetTimeMS()
    for _, rule in ipairs(self.TempSettings.Rules) do
        if rule.enabled then
            local runtime = self.TempSettings.RuleRuntime[rule.id]
            if not runtime then
                runtime = { lastEvalMs = 0, }
                self.TempSettings.RuleRuntime[rule.id] = runtime
            end

            if (now - runtime.lastEvalMs) >= Module.EvalThrottleMs then
                runtime.lastEvalMs = now
                self:EvaluateRule(rule, runtime)
            end
        end
    end
end

----------------------------------------------------------------------
-- Slash commands (/rgl procswap ...)
----------------------------------------------------------------------

function Module:HandleBindCommand(subcmd, ruleName)
    subcmd = (subcmd or ""):lower()

    if subcmd == "toggle" then
        if not ruleName or ruleName == "" then
            Logger.log_error("/rgl procswap toggle - a rule name is required! Use /rgl procswap toggle <ruleName>.")
            return
        end
        for _, rule in ipairs(self.TempSettings.Rules) do
            if rule.name:lower() == ruleName:lower() then
                rule.enabled = not rule.enabled
                self:PersistRules()
                Logger.log_info("\agProcSwap: rule '%s' is now %s.", rule.name, rule.enabled and "enabled" or "disabled")
                return
            end
        end
        Logger.log_error("\arProcSwap: no rule named '%s'.", ruleName)
    elseif subcmd == "list" then
        if #self.TempSettings.Rules == 0 then
            Logger.log_info("\ayProcSwap: no rules configured.")
            return
        end
        for _, rule in ipairs(self.TempSettings.Rules) do
            local runtime = self.TempSettings.RuleRuntime[rule.id]
            local status = "--"
            if runtime and runtime.lastKnownActive ~= nil then
                status = runtime.lastKnownActive and "Wearing Main" or "Seeking Proc"
            end
            Logger.log_info("\ag%s\ax: scope=%s enabled=%s effect=%s proc=%s main=%s status=%s",
                rule.name, rule.scope, tostring(rule.enabled), rule.effect, rule.procSet, rule.mainSet, status)
        end
    else
        Logger.log_error("/rgl procswap - usage: /rgl procswap <toggle|list> [ruleName]")
    end
end

----------------------------------------------------------------------
-- Render
----------------------------------------------------------------------

--- Renders the Status column for one rule row.
function Module:RenderRuleStatus(rule)
    if rule.effect == "" or rule.procSet == "" or rule.mainSet == "" then
        Ui.RenderText("\ayIncomplete")
        return
    end

    if not mq.TLO.Me.Bandolier(rule.procSet).Index() then
        Ui.RenderText("\arBad Proc Set")
        return
    end
    if not mq.TLO.Me.Bandolier(rule.mainSet).Index() then
        Ui.RenderText("\arBad Main Set")
        return
    end

    if not rule.enabled then
        Ui.RenderText("\ay(disabled)")
        return
    end

    local runtime = self.TempSettings.RuleRuntime[rule.id]
    if runtime and runtime.lastKnownActive ~= nil then
        Ui.RenderText(runtime.lastKnownActive and "\agWearing Main" or "\aySeeking Proc")
    else
        Ui.RenderText("--")
    end
end

function Module:Render()
    Base.Render(self)
    ImGui.NewLine()

    if Combat.GetCombatState() ~= "Combat" then
        Ui.RenderText("\ay(Idle -- ProcSwap only evaluates rules while in combat)")
    end

    ImGui.Separator()

    if ImGui.BeginTable("procswap_rules", 8, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.SizingFixedFit) then
        ImGui.TableSetupColumn("On", ImGuiTableColumnFlags.WidthFixed, 30.0)
        ImGui.TableSetupColumn("Name", ImGuiTableColumnFlags.WidthFixed, 100.0)
        ImGui.TableSetupColumn("Scope", ImGuiTableColumnFlags.WidthFixed, 80.0)
        ImGui.TableSetupColumn("Effect", ImGuiTableColumnFlags.WidthFixed, 120.0)
        ImGui.TableSetupColumn("Proc Set", ImGuiTableColumnFlags.WidthFixed, 100.0)
        ImGui.TableSetupColumn("Main Set", ImGuiTableColumnFlags.WidthFixed, 100.0)
        ImGui.TableSetupColumn("Status", ImGuiTableColumnFlags.WidthFixed, 100.0)
        ImGui.TableSetupColumn("", ImGuiTableColumnFlags.WidthFixed, 30.0)
        ImGui.TableHeadersRow()

        local ruleToDelete = nil
        for i, rule in ipairs(self.TempSettings.Rules) do
            ImGui.PushID(rule.id)
            ImGui.TableNextRow()

            ImGui.TableNextColumn()
            local newEnabled = ImGui.Checkbox("##enabled", rule.enabled)
            if newEnabled ~= rule.enabled then
                rule.enabled = newEnabled
                self:PersistRules()
            end

            ImGui.TableNextColumn()
            ImGui.SetNextItemWidth(-1)
            local newName, nameChanged = ImGui.InputText("##name", rule.name)
            if nameChanged then
                rule.name = newName
                self:PersistRules()
            end

            ImGui.TableNextColumn()
            ImGui.SetNextItemWidth(-1)
            local scopeIdx = (rule.scope == "target") and 2 or 1
            local newIdx, scopeChanged = ImGui.Combo("##scope", scopeIdx, self.ScopeOptions)
            if scopeChanged then
                rule.scope = (newIdx == 2) and "target" or "self"
                self:PersistRules()
            end

            ImGui.TableNextColumn()
            ImGui.SetNextItemWidth(-1)
            local newEffect, effectChanged = ImGui.InputText("##effect", rule.effect)
            if effectChanged then
                rule.effect = newEffect
                self:PersistRules()
            end

            ImGui.TableNextColumn()
            ImGui.SetNextItemWidth(-1)
            local newProcSet, procSetChanged = ImGui.InputText("##procset", rule.procSet)
            if procSetChanged then
                rule.procSet = newProcSet
                self:PersistRules()
            end

            ImGui.TableNextColumn()
            ImGui.SetNextItemWidth(-1)
            local newMainSet, mainSetChanged = ImGui.InputText("##mainset", rule.mainSet)
            if mainSetChanged then
                rule.mainSet = newMainSet
                self:PersistRules()
            end

            ImGui.TableNextColumn()
            self:RenderRuleStatus(rule)

            ImGui.TableNextColumn()
            if ImGui.SmallButton("X") then
                ruleToDelete = i
            end

            ImGui.PopID()
        end
        ImGui.EndTable()

        if ruleToDelete then
            table.remove(self.TempSettings.Rules, ruleToDelete)
            self:PersistRules()
        end
    end

    ImGui.Separator()

    Ui.RenderText("+ Add Rule: ")
    ImGui.SameLine()
    ImGui.PushItemWidth(140)
    self.TempSettings.NewRuleName = ImGui.InputText("##new_rule_name", self.TempSettings.NewRuleName)
    ImGui.PopItemWidth()
    ImGui.SameLine()
    if ImGui.SmallButton("Add") then
        if self.TempSettings.NewRuleName ~= "" then
            table.insert(self.TempSettings.Rules, {
                id      = self:NewRuleId(),
                name    = self.TempSettings.NewRuleName,
                enabled = false,
                scope   = "self",
                effect  = "",
                procSet = "",
                mainSet = "",
            })
            self.TempSettings.NewRuleName = ""
            self:PersistRules()
        end
    end
end

return Module
