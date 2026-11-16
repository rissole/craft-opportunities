local addonName, Crafts = ...

-- Craft Opportunities: profitable crafts across this account's characters. Recipes, requirements and learned-recipe
-- records come from SkillUp Forever's addon API (SkillUp.lua). Prices come from TradeSkillMaster when it is
-- installed, else follow SkillUp Forever's own rules (Prices.lua). Only settings and a little character metadata are
-- saved.
-- The addon table is Crafts itself; Init.lua, loaded last, runs its lifecycle.
Crafts.name = addonName
Crafts.events = {"PLAYER_ENTERING_WORLD", "SKILL_LINES_CHANGED", "NEW_RECIPE_LEARNED",
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
    {"local", "This realm and faction"},
    {"all", "All recorded characters"},
}


-- WoW Forever characters have a surname. UnitName hands it back as its second value (on retail that slot is the
-- realm, which is nil for the player); UnitNameUnmodified ignores the show-surname preference. A full name joins the
-- two with the client's separator, as Blizzard's frames do. SkillUp's character keys use the first name only.
local SURNAME_SEPARATOR = Constants and Constants.CharacterNameSeparatorConsts
    and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR or " "

function Crafts.CurrentSurname()
    local _, surname = (UnitNameUnmodified or UnitName)("player")
    if issecretvalue and issecretvalue(surname) then return nil end
    if type(surname) == "string" and surname ~= "" then return surname end
    return nil
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
        vendorMaterials = "cheaper",
        market = "local",
        character = "all",
        -- The profession filter's unticked professions, [skillLine] = true. Holding the unticked ones means a
        -- profession learned later shows until it is unticked.
        hiddenProfessions = {},
        availability = "default",
        profitableOnly = false,
        -- "profit" or "return" (Calc.SORTS), chosen by clicking a column heading.
        sort = "profit",
        window = {},
        -- ["Name-Realm"] = {realm, faction, surname, updated, professions = {[skillLine] = {base, scanned, name}}}
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
    if not valid(self.MARKET_OPTIONS, saved.market) then saved.market = defaults.market end
    if not valid(self.Calc.AVAILABILITY, saved.availability) then saved.availability = defaults.availability end
    if not valid(self.Calc.SORTS, saved.sort) then saved.sort = defaults.sort end
    for skillLine, value in pairs(saved.hiddenProfessions) do
        if type(skillLine) ~= "number" or value ~= true then saved.hiddenProfessions[skillLine] = nil end
    end
    -- A blank expression follows the defaults.
    for _, key in ipairs({"materialPrice", "salePrice"}) do
        if not saved[key]:find("%S") then saved[key] = "" end
    end
    for key, record in pairs(saved.characters) do
        if type(key) ~= "string" or type(record) ~= "table" then
            saved.characters[key] = nil
        else
            if type(record.professions) ~= "table" then record.professions = {} end
            if record.surname ~= nil and (type(record.surname) ~= "string" or record.surname == "") then
                record.surname = nil
            end
            for skillLine, entry in pairs(record.professions) do
                if type(skillLine) ~= "number" or type(entry) ~= "table" or type(entry.base) ~= "number" then
                    record.professions[skillLine] = nil
                elseif entry.scanned ~= nil and type(entry.scanned) ~= "number" then
                    entry.scanned = nil
                end
            end
        end
    end
end

-- Dependencies -------------------------------------------------------------------------------------------------

-- SkillUp Forever's reader (SkillUp.lua) when Craft Opportunities can use it, and a status: "ok"; otherwise nil and
-- why not ("skillup", "skillupBroken", "old", "loading"), each with the message the window shows.
function Crafts:Dependencies()
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("SkillUpForever")
    if not loaded then
        return nil, "skillup", "SkillUp Forever is not loaded.\n\nCraft Opportunities reads its recipe data and the "
            .. "recipes it recorded for each character. Enable SkillUp Forever and ForeverCore in the AddOns list, "
            .. "then restart the game."
    end
    local reader, reason = self.SkillUp.Open()
    if reader then
        -- Prices never stop it: without TSM it prices by SkillUp's rules, and without Auctionator either, on vendor
        -- prices alone (Prices.lua); the status line says which.
        return reader, "ok"
    elseif reason == "skillup" then
        return nil, "skillupBroken", "SkillUp Forever is loaded but did not start.\n\nIts own on-screen message "
            .. "says why; usually ForeverCore or SkillUp Forever needs updating."
    elseif reason == "old" then
        local version = C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("SkillUpForever", "Version") or "?"
        return nil, "old", "SkillUp Forever " .. version .. " is too old for Craft Opportunities.\n\nCraft "
            .. "Opportunities reads SkillUp's recipes and learned-recipe records through its addon API (Recipes, "
            .. "Recipe, RecipeRequirement, Characters and Knows), which needs SkillUp Forever "
            .. Crafts.SkillUp.MINIMUM .. " or later. Update SkillUp Forever, then restart the game."
    end
    return nil, "loading", "SkillUp Forever is still loading its saved data. Try again in a moment."
end

-- The reader, only when SkillUp can answer.
function Crafts:Source()
    return (self.SkillUp.Open())
end

-- Character metadata -------------------------------------------------------------------------------------------

-- Records this character's realm, faction, surname and profession base levels. A profession the client no longer
-- lists is dropped, with its scan time. An empty list is what the client answers early in login, so it changes
-- nothing. Returns true when something Craft Opportunities reads moved.
function Crafts:UpdateCharacter()
    local reader, saved = self:Source(), self.saved
    if not (reader and saved) then return false end
    local key, _, realm, faction = reader.CurrentCharacter()
    if not (key and realm) then return false end
    self.current = {key = key, realm = realm, faction = faction}
    local record, changed = saved.characters[key], false
    if not record then
        record = {professions = {}}
        saved.characters[key] = record
        changed = true
    end
    if record.realm ~= realm or record.faction ~= faction then
        record.realm, record.faction, changed = realm, faction, true
    end
    local surname = Crafts.CurrentSurname()
    if surname and record.surname ~= surname then record.surname, changed = surname, true end
    local professions = reader.LiveProfessions()
    if not professions or #professions == 0 then return changed end
    local present = {}
    for _, profession in ipairs(professions) do
        present[profession.skillLine] = true
        local entry = record.professions[profession.skillLine]
        if not entry then
            entry = {}
            record.professions[profession.skillLine] = entry
            changed = true
        end
        if entry.base ~= profession.base then entry.base, changed = profession.base, true end
        if type(profession.name) == "string" and profession.name ~= "" then entry.name = profession.name end
    end
    for skillLine in pairs(record.professions) do
        if not present[skillLine] then
            record.professions[skillLine] = nil
            changed = true
        end
    end
    record.updated = GetServerTime()
    return changed
end

-- One of this character's profession windows was completely recorded (SkillUp.lua's OnScan).
function Crafts:OnScan(skillLine, time, _, _, base, changed)
    self:UpdateCharacter()
    local record = self.current and self.saved.characters[self.current.key]
    if not record then return end
    local entry = record.professions[skillLine]
    if not entry then
        entry = {}
        record.professions[skillLine] = entry
    end
    if type(base) == "number" then entry.base = base end
    entry.scanned = time
    if changed then self:DataChanged() end
end

function Crafts:OnLogin()
    self.SkillUp.OnScan(function(...) self:OnScan(...) end)
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
        self:DataChanged()
    elseif InCombatLockdown() then
        -- Weapon skill-ups fire SKILL_LINES_CHANGED in combat; read the professions once it ends.
        self.skillsPending = true
    else
        if self:UpdateCharacter() then self:DataChanged() end
    end
end

-- A fresh pricing snapshot for one calculation: TSM's when TSM is installed, else SkillUp's rules, with SkillUp's
-- own "Count what crafts sell for" (Prices.lua).
function Crafts:Pricing()
    return self.Prices.Current(self.saved, self:Source())
end

function Crafts:OnSlash()
    self:OpenWindow()
end

-- The window's hooks, replaced by UI.lua.
function Crafts:DataChanged() end
function Crafts:CombatChanged() end
function Crafts:ItemInfo() end
function Crafts:OpenWindow() end

-- The characters to compare, as transient descriptors (rebuilt for each calculation, never saved):
-- {key, name (first name, from the key), fullName (with the surname once recorded), realm, faction, current,
-- professions (recorded [skillLine] = {base, scanned}, the saved table itself, read only) or observed
-- ([skillLine] = recorded recipe count, for a character whose professions were never recorded), updated}. A
-- character with neither is not compared. Outside "all", only this realm and faction; a character whose faction was
-- never recorded stays in, marked.
function Crafts:Crafters(reader)
    local saved, current = self.saved, self.current
    local keys, seen = {}, {}
    local function add(key)
        if type(key) == "string" and not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    if current then add(current.key) end
    for key in reader.Characters() do add(key) end
    for key in pairs(saved.characters) do add(key) end
    local crafters = {}
    for _, key in ipairs(keys) do
        local record = saved.characters[key]
        local name, keyRealm = key:match("^([^-]+)%-(.+)$")
        local realm = record and record.realm or keyRealm
        local faction = record and record.faction
        local here = current ~= nil and realm == current.realm and (faction == nil or faction == current.faction)
        if saved.market == "all" or here or not current then
            -- A recorded profession list is authoritative; without one, the professions SkillUp saw recipes for.
            local professions, observed
            if record and next(record.professions) then
                professions = record.professions
            else
                observed = reader.KnownSkillLines(key)
                if not next(observed) then observed = nil end
            end
            if professions or observed then
                crafters[#crafters + 1] = {
                    key = key,
                    name = name or key,
                    fullName = Crafts.FullName(name or key, record and record.surname),
                    realm = realm,
                    faction = faction,
                    current = current ~= nil and key == current.key,
                    elsewhere = current ~= nil and not here,
                    professions = professions,
                    observed = observed,
                    updated = record and record.updated,
                }
            end
        end
    end
    table.sort(crafters, function(a, b)
        if a.current ~= b.current then return a.current end
        return a.key < b.key
    end)
    return crafters
end

function Crafts.Ago(time)
    if type(time) ~= "number" then return nil end
    local seconds = math.max(0, GetServerTime() - time)
    if seconds < 90 then return "just now" end
    if seconds < 5400 then return string.format("%d min ago", math.floor(seconds / 60 + 0.5)) end
    if seconds < 129600 then return string.format("%d h ago", math.floor(seconds / 3600 + 0.5)) end
    return string.format("%d days ago", math.floor(seconds / 86400 + 0.5))
end

-- How current a character's knowledge of one profession is, in words.
function Crafts:Freshness(crafter, skillLine)
    if not crafter.professions then
        return "Only previously observed recipes; log in on " .. crafter.fullName .. " to record its professions."
    end
    local entry = crafter.professions[skillLine]
    if not entry then return "Profession not recorded." end
    local text
    if entry.scanned then
        text = "Recipes scanned " .. Crafts.Ago(entry.scanned) .. "."
    else
        text = "Recipes not scanned since Craft Opportunities began tracking; open the profession on " .. crafter.fullName .. "."
    end
    if not crafter.current and crafter.updated then
        text = text .. " Skill recorded " .. Crafts.Ago(crafter.updated) .. "."
    end
    if crafter.faction == nil then
        text = text .. " Faction not recorded yet."
    elseif crafter.elsewhere then
        text = text .. " Other realm or faction: priced at this character's market."
    end
    return text
end
