local addonName, Crafts = ...

-- Craft Opportunities: profitable crafts across this account's characters. Recipes and requirements come from
-- SkillUp Forever's addon API (SkillUp.lua) when it is installed, else only the recorded recipes, read from the client
-- (Client.lua); each character's professions and learned recipes are recorded here (Characters.lua). Prices come
-- from TradeSkillMaster when it is installed, else from Auctionator and vendors (Prices.lua). Only settings and those character records are saved.
-- The addon table is Crafts itself; Init.lua, loaded last, runs its lifecycle.
Crafts.name = addonName
Crafts.events = {"PLAYER_ENTERING_WORLD", "SKILL_LINES_CHANGED", "SPELLS_CHANGED", "NEW_RECIPE_LEARNED",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "GET_ITEM_INFO_RECEIVED"}

function Crafts.Copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = Crafts.Copy(v) end
    return result
end

function Crafts:Message(message)
    print("|cffffd166Craft Opportunities:|r " .. message)
end

Crafts.MARKET_OPTIONS = {
    {"local", "This ruleset and faction"},
    {"all", "All recorded characters"},
}


-- WoW Forever characters have a surname. UnitName hands it back as its second value (on retail that slot is the
-- realm, which is nil for the player); UnitNameUnmodified ignores the show-surname preference. A full name joins the
-- two with the client's separator, as Blizzard's frames do.
local SURNAME_SEPARATOR = Constants and Constants.CharacterNameSeparatorConsts
    and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR or " "

function Crafts.CurrentSurname()
    local _, surname = (UnitNameUnmodified or UnitName)("player")
    if issecretvalue and issecretvalue(surname) then return nil end
    if type(surname) == "string" and surname ~= "" then return surname end
    return nil
end

-- This character's ruleset, named as TSM names it: "Normal", "PvP", "Roleplay", "Roleplay PvP" or "Hardcore". WoW
-- Forever has no realms; its auction houses are one per ruleset and faction. Nil when the client has no game rules.
function Crafts.Ruleset()
    local rules = C_GameRules
    if not (rules and type(rules.IsGameRuleActive) == "function" and Enum and Enum.GameRule) then return nil end
    local function active(rule) return rule ~= nil and rules.IsGameRuleActive(rule) == true end
    local rp, pvp = active(Enum.GameRule.RPRuleset), active(Enum.GameRule.PvPRuleset)
    if active(Enum.GameRule.HardcoreRuleset) then return "Hardcore" end
    if rp and pvp then return "Roleplay PvP" end
    if rp then return "Roleplay" end
    if pvp then return "PvP" end
    return "Normal"
end

function Crafts.FullName(name, surname)
    if type(surname) ~= "string" or surname == "" then return name end
    return name .. SURNAME_SEPARATOR .. surname
end

function Crafts:Defaults()
    return {
        -- The TSM pricing's settings (Prices.lua), kept but unused while TSM is not installed. An empty expression
        -- follows the default (Prices.DefaultExpressions).
        materialPrice = "",
        salePrice = "",
        -- True values sales at VendorSell instead of the sale expression (the Pricing toggle).
        saleVendor = false,
        -- Without TSM, what a product sells for (Prices.SALE_OPTIONS): "vendor" or "auction".
        saleWithoutTSM = "vendor",
        vendorMaterials = "cheaper",
        market = "local",
        character = "all",
        -- The profession filter's unticked professions, [skillLine] = true. Holding the unticked ones means a
        -- profession learned later shows until it is unticked.
        hiddenProfessions = {},
        -- The item type filter's unticked item classes, [classID] = true (Calc.ItemClass), the same way.
        hiddenItemClasses = {},
        availability = "default",
        profitableOnly = false,
        -- The Sales filter's minimum sold per day (a Market.SOLD_STEPS value) and sale rate (0 to 1), used only with
        -- TSM and its sales data.
        salesMinSold = 0,
        salesMinRate = 0,
        -- "profit" or "return" (Calc.SORTS), chosen by clicking a column heading.
        sort = "profit",
        -- Recommendation cards closed with their ×, [CurseForge slug] = true (UI.lua's SUGGESTIONS).
        dismissed = {},
        window = {},
        -- [GUID] = this account's characters (Characters.lua)
        characters = {},
    }
end

local function valid(options, value)
    for _, option in ipairs(options) do
        if option[1] == value then return true end
    end
    return false
end

-- Whatever loaded is kept where it is valid; a missing or malformed value takes its default.
function Crafts:OnInitialize(saved)
    self.saved = saved
    local defaults = self:Defaults()
    for key, value in pairs(defaults) do
        if type(saved[key]) ~= type(value) then saved[key] = value end
    end
    if not valid(self.Prices.VENDOR_OPTIONS, saved.vendorMaterials) then
        saved.vendorMaterials = defaults.vendorMaterials
    end
    if not valid(self.Prices.SALE_OPTIONS, saved.saleWithoutTSM) then saved.saleWithoutTSM = defaults.saleWithoutTSM end
    if not valid(self.MARKET_OPTIONS, saved.market) then saved.market = defaults.market end
    if not valid(self.Calc.AVAILABILITY, saved.availability) then saved.availability = defaults.availability end
    if not valid(self.Calc.SORTS, saved.sort) then saved.sort = defaults.sort end
    saved.salesMinSold = self.Market.SOLD_STEPS[self.Market.SoldStep(saved.salesMinSold)]
    saved.salesMinRate = self.Market.SnapRate(saved.salesMinRate)
    for _, key in ipairs({"hiddenProfessions", "hiddenItemClasses"}) do
        local hidden = saved[key]
        for id, value in pairs(hidden) do
            if type(id) ~= "number" or value ~= true then hidden[id] = nil end
        end
    end
    for slug, value in pairs(saved.dismissed) do
        if type(slug) ~= "string" or value ~= true then saved.dismissed[slug] = nil end
    end
    -- A blank expression follows the defaults.
    for _, key in ipairs({"materialPrice", "salePrice"}) do
        if not saved[key]:find("%S") then saved[key] = "" end
    end
    self:ValidateCharacters(saved)
end

-- Dependencies -------------------------------------------------------------------------------------------------

-- Whether SkillUp Forever is loaded. An addon cannot load later in a session, so this holds once logged in.
function Crafts.HasSkillUp()
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("SkillUpForever")
    return loaded and true or false
end

-- The recipe reader and a status: "ok" with SkillUp Forever's reader (SkillUp.lua), or with the client's (Client.lua)
-- when SkillUp is not loaded; otherwise nil and why not ("skillupBroken", "old", "loading"), each with the message the
-- window shows.
function Crafts:Dependencies()
    if not Crafts.HasSkillUp() then return self.Client.Open(), "ok" end
    local reader, reason = self.SkillUp.Open()
    if reader then
        -- Prices never stop it: without TSM it prices with Auctionator, and without Auctionator either, on vendor
        -- prices alone (Prices.lua); the status line says which.
        return reader, "ok"
    elseif reason == "skillup" then
        return nil, "skillupBroken", "SkillUp Forever is loaded but did not start.\n\nIts own on-screen message "
            .. "says why; usually ForeverCore or SkillUp Forever needs updating."
    elseif reason == "old" then
        local version = C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("SkillUpForever", "Version") or "?"
        return nil, "old", "SkillUp Forever " .. version .. " is too old for Craft Opportunities.\n\nCraft "
            .. "Opportunities reads SkillUp's recipes through its addon API (Recipes, Recipe and RecipeRequirement), "
            .. "which needs SkillUp Forever " .. Crafts.SkillUp.MINIMUM .. " or later. Update SkillUp Forever, then "
            .. "restart the game."
    end
    return nil, "loading", "SkillUp Forever is still loading. Try again in a moment."
end

-- The reader, only when it can answer.
function Crafts:Source()
    if not Crafts.HasSkillUp() then return self.Client.Open() end
    return (self.SkillUp.Open())
end

function Crafts:OnLogin()
    self:UpdateCharacter()
end

function Crafts:OnEvent(event, ...)
    if event == "PLAYER_REGEN_DISABLED" then
        self:CombatChanged(true)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if self.skillsPending and self:UpdateCharacter() then self:DataChanged() end
        self.skillsPending = nil
        self:CombatChanged(false)
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        self:ItemInfo(...)
    elseif event == "NEW_RECIPE_LEARNED" then
        self:NoteLearned((...))
        self:DataChanged()
    elseif InCombatLockdown() then
        -- Weapon skill-ups fire SKILL_LINES_CHANGED in combat; read the professions once it ends.
        self.skillsPending = true
    else
        if self:UpdateCharacter() then self:DataChanged() end
    end
end

-- A fresh pricing snapshot for one calculation: TSM's when TSM is installed, else Auctionator's (Prices.lua).
function Crafts:Pricing()
    return self.Prices.Current(self.saved)
end

function Crafts:OnSlash()
    self:OpenWindow()
end

-- The window's hooks, replaced by UI.lua.
function Crafts:DataChanged() end
function Crafts:CombatChanged() end
function Crafts:ItemInfo() end
function Crafts:OpenWindow() end

function Crafts.Ago(time)
    if type(time) ~= "number" then return nil end
    local seconds = math.max(0, GetServerTime() - time)
    if seconds < 90 then return "just now" end
    if seconds < 5400 then return string.format("%d min ago", math.floor(seconds / 60 + 0.5)) end
    if seconds < 129600 then return string.format("%d h ago", math.floor(seconds / 3600 + 0.5)) end
    return string.format("%d days ago", math.floor(seconds / 86400 + 0.5))
end
