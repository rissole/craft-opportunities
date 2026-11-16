local _, Crafts = ...

-- What Craft Opportunities reads from SkillUp Forever, behind one reader the rest of the addon uses.
--
-- SkillUp Forever's public API (SkillUpForever.API, minor 7 or later) supplies the bundled recipes and reagents
-- (Recipes, Recipe), learn requirements (RecipeRequirement) and the learned recipes SkillUp records for every
-- character (Characters, Knows). Where a recipe item comes from is RecipeSources, when SkillUp has it.
--
-- Compatibility: a SkillUp Forever build carrying the local SkillUpForever.API.Reol table (version 2 or later) is
-- used for whatever the public API does not have yet: those recipe members on an older SkillUp, recipe item sources
-- (RecipeItemSources, version 3), the vendor prices SkillUp knows, and its "Count what crafts sell for" setting.
-- Without it, vendor prices come from Auctionator or TSM, and the setting is read from SkillUp's saved settings.
--
-- The rest comes from the client: recipe names and icons, profession names and levels, this character's key, sell
-- prices, and when one of this character's own profession windows was completely recorded (OnScan).
local Source = {}
Crafts.SkillUp = Source

-- The public members this addon needs (SkillUp issue #724).
local RECIPE_MEMBERS = {"Recipes", "Recipe", "RecipeRequirement", "Characters", "Knows"}
local COMPAT_VERSION = 2
-- The professions SkillUp's data has, to list each one's recipes without reading every recipe record. A recipe of any
-- other skill line is found by reading its record.
local SKILL_LINES = {129, 164, 165, 171, 182, 185, 186, 197, 202, 333, 356, 393, 755, 773}
-- SkillUp's "Count what crafts sell for" choices and their labels, as its Prices settings show them.
local CRAFT_VALUES = {
    none = "Don't count it",
    vendor = "Vendor sell price",
    auction = "Auction price if higher",
    sale = "Region sale average if higher",
}

local function PublicAPI()
    local api = SkillUpForever and SkillUpForever.API
    return type(api) == "table" and api or nil
end

local function HasPublic(api)
    if not api then return false end
    for _, name in ipairs(RECIPE_MEMBERS) do
        if type(api[name]) ~= "function" then return false end
    end
    return true
end

local function Compat(api)
    local compat = api and api.Reol
    if type(compat) == "table" and type(compat.version) == "number" and compat.version >= COMPAT_VERSION
        and type(compat.Ready) == "function" then
        return compat
    end
end

-- Resolved by Source.Open: `public` is the API when it has every recipe member, else nil and `compat` reads them.
local public, compat

local function Positive(value)
    if type(value) == "number" and value > 0 and value < math.huge then return value end
    return nil
end

-- Recipe records (public API) ------------------------------------------------------------------------------------

-- Every bundled recipe ID, sorted, and [recipeID] = skill line: read once, since SkillUp's bundle never changes in a
-- session. Recipe records are cached weakly: the collector drops them while the window is closed.
local allRecipes, lineOf
local records = setmetatable({}, {__mode = "v"})

local function Record(recipeID)
    local record = records[recipeID]
    if record == nil then
        record = public.Recipe(recipeID)
        if type(record) ~= "table" then return nil end
        records[recipeID] = record
    end
    return record
end

-- Built on first use, once SkillUp has loaded (Source.Open has checked).
local function Index()
    if allRecipes then return allRecipes, lineOf end
    local ids = public.Recipes() or {}
    local lines = {}
    for _, skillLine in ipairs(SKILL_LINES) do
        for _, recipeID in ipairs(public.Recipes(skillLine) or {}) do lines[recipeID] = skillLine end
    end
    for _, recipeID in ipairs(ids) do
        if not lines[recipeID] then
            local record = public.Recipe(recipeID)
            lines[recipeID] = type(record) == "table" and record.skillLineID or false
        end
    end
    allRecipes, lineOf = ids, lines
    return ids, lines
end

-- The reader ---------------------------------------------------------------------------------------------------------

local Reader = {}
Source.Reader = Reader

local function NoNext() return nil end

-- `for recipeID in Reader.Recipes() do`: every bundled recipe ID. Safe across frames: the list never changes.
function Reader.Recipes()
    if not public then return compat.Recipes() end
    local list, index = Index(), 0
    return function()
        index = index + 1
        return list[index]
    end
end

function Reader.RecipeCount()
    if not public then return compat.RecipeCount() end
    return #Index()
end

function Reader.RecipeProfession(recipeID)
    if not public then return compat.RecipeProfession(recipeID) end
    local _, lines = Index()
    return lines[recipeID] or nil
end

-- itemID, mean yield, "item"; nil, nil, "none" for a recipe that makes no item; nil, nil, "unknown".
function Reader.RecipeOutput(recipeID)
    if not public then return compat.RecipeOutput(recipeID) end
    local record = Record(recipeID)
    if not record then return nil, nil, "unknown" end
    local output = record.output
    if output == false then return nil, nil, "none" end
    if type(output) ~= "table" or type(output.itemID) ~= "number" or type(output.quantity) ~= "number" then
        return nil, nil, "unknown"
    end
    return output.itemID, output.quantity, "item"
end

function Reader.ReagentCount(recipeID)
    if not public then return compat.ReagentCount(recipeID) end
    local record = Record(recipeID)
    return record and type(record.reagents) == "table" and #record.reagents or 0
end

function Reader.Reagent(recipeID, index)
    if not public then return compat.Reagent(recipeID, index) end
    local record = Record(recipeID)
    local reagent = record and type(record.reagents) == "table" and record.reagents[index]
    if type(reagent) == "table" then return reagent.itemID, reagent.quantity end
end

local function NextReagent(recipeID, index)
    index = index + 1
    local itemID, quantity = Reader.Reagent(recipeID, index)
    if itemID then return index, itemID, quantity end
end

-- `for index, itemID, quantity in Reader.Reagents(recipeID) do`
function Reader.Reagents(recipeID)
    return NextReagent, recipeID, 0
end

-- The required base skill (nil when unknown, never 0), its source ("trainer" or "item"), the recipe item that teaches
-- it, the trainer's fee, and where the requirement came from when SkillUp says ("seen", "bundled", "catalogue").
function Reader.RecipeRequirement(recipeID)
    if not public then return compat.RecipeRequirement(recipeID) end
    local requirement = public.RecipeRequirement(recipeID)
    if type(requirement) ~= "table" then return nil end
    local source = (requirement.source == "trainer" or requirement.source == "item") and requirement.source or nil
    return Positive(requirement.skill), source, requirement.recipeItem, requirement.trainerFee
end

local function UsableFirst(list)
    local sorted = {}
    for _, entry in ipairs(list) do
        if entry.usable ~= false then sorted[#sorted + 1] = entry end
    end
    for _, entry in ipairs(list) do
        if entry.usable == false then sorted[#sorted + 1] = entry end
    end
    return sorted
end

-- Where the item that teaches a recipe comes from: {itemID, vendors = {{npcID, name, zone, usable}}, quests =
-- {{questID, title, usable}}, drops = {{npcID, name, zone, chance, usable}}, world}, vendors this character can deal
-- with first. Otherwise nil and why: "loading" (ask again shortly), "none", or "unavailable" when this SkillUp cannot
-- say.
function Reader.RecipeSources(recipeID)
    local api = PublicAPI()
    local found, reason
    if api and type(api.RecipeSources) == "function" then
        found, reason = api.RecipeSources(recipeID)
    elseif compat and type(compat.RecipeItemSources) == "function" then
        found, reason = compat.RecipeItemSources(recipeID)
    else
        return nil, "unavailable"
    end
    if type(found) ~= "table" then
        return nil, (reason == "loading" or reason == "reading") and "loading" or "none"
    end
    found.vendors = UsableFirst(type(found.vendors) == "table" and found.vendors or {})
    if type(found.quests) ~= "table" then found.quests = {} end
    if type(found.drops) ~= "table" then found.drops = {} end
    return found
end

function Reader.RecipeName(recipeID)
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(recipeID)
    return type(name) == "string" and name ~= "" and name or nil
end

function Reader.RecipeIcon(recipeID)
    return C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(recipeID) or nil
end

-- The client's name for a profession, else the one recorded with a character's professions.
function Reader.ProfessionName(skillLine)
    if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName then
        local ok, name = pcall(C_TradeSkillUI.GetTradeSkillDisplayName, skillLine)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    for _, record in pairs(Crafts.saved and Crafts.saved.characters or {}) do
        local entry = record.professions and record.professions[skillLine]
        if entry and type(entry.name) == "string" then return entry.name end
    end
    if compat and type(compat.ProfessionName) == "function" then return compat.ProfessionName(skillLine) end
end

-- Characters ---------------------------------------------------------------------------------------------------------

-- This character's realm in the client's normalized form, as SkillUp keys its saved records.
local function NormalizedRealm()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then realm = ((GetRealmName() or ""):gsub("[%s%-]", "")) end
    return realm ~= "" and realm or nil
end

-- This character: SkillUp's "Name-Realm" key (first name only), name, normalized realm, English faction group. Nil
-- while the client has no name or realm yet; once it has, they cannot change within a session.
local currentKey, currentName, currentRealm
function Reader.CurrentCharacter()
    if not currentKey then
        local name, realm = UnitName("player"), NormalizedRealm()
        if type(name) ~= "string" or name == "" or not realm then return nil end
        currentKey, currentName, currentRealm = name .. "-" .. realm, name, realm
    end
    return currentKey, currentName, currentRealm, UnitFactionGroup("player")
end

-- `for characterKey in Reader.Characters() do`: every "Name-Realm" SkillUp has learned-recipe records for.
function Reader.Characters()
    if not public then return compat.Characters() end
    local keys = public.Characters()
    if type(keys) ~= "table" then return NoNext end
    local index = 0
    return function()
        index = index + 1
        return keys[index]
    end
end

local function IsSpellKnown(recipeID)
    local book = C_SpellBook and C_SpellBook.IsSpellKnown
    if book then return book(recipeID) == true end
    return IsPlayerSpell ~= nil and IsPlayerSpell(recipeID) == true
end

-- What SkillUp recorded: true, false, or nil for a recipe it cannot answer for.
local function Recorded(key, recipeID)
    if public then
        local knows = public.Knows(key, recipeID)
        if knows == nil then return nil end
        return knows == true
    end
    return compat.Knows(key, recipeID) == true
end

-- Whether a character knows a recipe, and how: "live" for this character (its spellbook or SkillUp's record),
-- "recorded" for another (what SkillUp saw when that character last had the profession open).
function Reader.Knows(key, recipeID)
    if key == (currentKey or Reader.CurrentCharacter()) then
        return IsSpellKnown(recipeID) or Recorded(key, recipeID) == true, "live"
    end
    return Recorded(key, recipeID) == true, "recorded"
end

-- A fresh [skillLine] = recorded recipe count, for the professions SkillUp saw recipes of for a character.
function Reader.KnownSkillLines(key)
    if not public then return compat.KnownSkillLines(key) end
    local lines, ids, lineOfRecipe = {}, Index()
    for _, recipeID in ipairs(ids) do
        local skillLine = lineOfRecipe[recipeID]
        if skillLine and public.Knows(key, recipeID) == true then lines[skillLine] = (lines[skillLine] or 0) + 1 end
    end
    return lines
end

-- This character's professions now, a fresh array sorted by skill line: {skillLine, name, icon, base, max,
-- modifier}. Empty is also the client's answer early in login, so it never confirms a profession was dropped.
function Reader.LiveProfessions()
    local list = {}
    if not GetProfessions then return list end
    local indexes = {GetProfessions()}
    for i = 1, 6 do
        local index = indexes[i]
        if index then
            local name, icon, rank, maxRank, _, _, skillLine, modifier = GetProfessionInfo(index)
            if type(skillLine) == "number" and type(rank) == "number" then
                list[#list + 1] = {skillLine = skillLine, name = name, icon = icon, base = rank, max = maxRank,
                    modifier = modifier or 0}
            end
        end
    end
    table.sort(list, function(a, b) return a.skillLine < b.skillLine end)
    return list
end

-- Prices -------------------------------------------------------------------------------------------------------------

-- What a vendor charges for one, and how that is known: "seen" at a merchant, or "bundled" in SkillUp's list. Without
-- SkillUp's list, what Auctionator saw at a merchant, else TSM's VendorBuy. Nil for an item no vendor is known to
-- sell.
function Reader.VendorPrice(itemID)
    if compat and type(compat.VendorPrice) == "function" then return compat.VendorPrice(itemID) end
    local auctionator = Auctionator and Auctionator.API and Auctionator.API.v1
    if auctionator and type(auctionator.GetVendorPriceByItemID) == "function" then
        local ok, price = pcall(auctionator.GetVendorPriceByItemID, Crafts.name or "CraftOpportunities", itemID)
        if ok and Positive(price) then return price, "seen" end
    end
    if TSM_API and type(TSM_API.GetCustomPriceValue) == "function" then
        local ok, price = pcall(TSM_API.GetCustomPriceValue, "VendorBuy", "i:" .. itemID)
        if ok and Positive(price) then return price, "seen" end
    end
    return nil
end

-- What a vendor pays for one: the client's sell price ("live"), else SkillUp's bundled one while the item loads.
function Reader.SellPrice(itemID)
    local sell = select(11, C_Item.GetItemInfo(itemID))
    if issecretvalue and issecretvalue(sell) then sell = nil end
    if type(sell) == "number" then return sell, "live" end
    C_Item.RequestLoadItemDataByID(itemID)
    if compat and type(compat.SellPrice) == "function" then return compat.SellPrice(itemID) end
    return nil
end

-- SkillUp's "Count what crafts sell for" ("none", "vendor", "auction" or "sale") and its label; nil when it cannot
-- be read. Read on every call, so a change in SkillUp's settings is seen on the next calculation.
function Reader.CraftValue()
    if compat and type(compat.CraftValue) == "function" then return compat.CraftValue() end
    local saved = type(SkillUpForeverDB) == "table" and SkillUpForeverDB.craftValue
    if CRAFT_VALUES[saved] then return saved, CRAFT_VALUES[saved] end
    return nil
end

-- Opening ------------------------------------------------------------------------------------------------------------

-- Whether SkillUp's saved variables are loaded, so its answers can be trusted.
local function Ready()
    if public then return public.Characters() ~= nil end
    return compat ~= nil and compat.Ready() == true
end

-- The reader when SkillUp Forever can answer: Reader; otherwise nil and why: "skillup" (no SkillUp API), "old" (it
-- has neither the public recipe members nor the compatibility table) or "loading".
function Source.Open()
    local api = PublicAPI()
    if not api then return nil, "skillup" end
    public = HasPublic(api) and api or nil
    compat = Compat(api)
    if not (public or compat) then return nil, "old" end
    if not Ready() then return nil, "loading" end
    return Reader
end

-- Which way the recipe data is read, for the status line: "api" or "compat".
function Source.Mode()
    return public and "api" or "compat"
end

-- Completed profession scans ------------------------------------------------------------------------------------------

-- A completed scan is this character's own profession window, ready, with SkillUp's record agreeing with every recipe
-- it lists. SkillUp writes that record a frame after the window's events, so a disagreement is retried up to
-- MAX_ATTEMPTS times. Linked, guild and NPC windows show someone else's recipes and are never reported.
local scans, listeners = {}, {}
local generation, attempts, windowOpen, pending = 0, 0, false, false
local MAX_ATTEMPTS, RETRY_SECONDS, SETTLE_SECONDS = 10, 0.25, 0.5

local function Notify(skillLine, scan, changed)
    for _, callback in ipairs({unpack(listeners)}) do
        xpcall(function()
            callback(skillLine, scan.time, scan.recipes, scan.known, scan.base, changed)
        end, geterrorhandler())
    end
end

-- Nil while the client is still filling the window.
local function OwnWindow()
    local T = C_TradeSkillUI
    if (T.IsTradeSkillLinked and T.IsTradeSkillLinked()) or (T.IsTradeSkillGuild and T.IsTradeSkillGuild())
        or (T.IsNPCCrafting and T.IsNPCCrafting()) then
        return false
    end
    if (T.IsTradeSkillReady and not T.IsTradeSkillReady()) or (T.IsDataSourceChanging and T.IsDataSourceChanging()) then
        return nil
    end
    return true
end

local Verify

local function Retry(token)
    attempts = attempts + 1
    if attempts < MAX_ATTEMPTS then
        C_Timer.After(RETRY_SECONDS, function() Verify(token) end)
    end
end

-- The open window's profession among this character's: its live entry, or nil.
local function OpenProfession()
    local base = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
    if not (base and base.professionID) then return nil end
    for _, profession in ipairs(Reader.LiveProfessions()) do
        if profession.skillLine == base.professionID or profession.name == base.professionName then
            return profession
        end
    end
    return false
end

function Verify(token)
    if token ~= generation or not windowOpen or not Source.Open() then return end
    local own = OwnWindow()
    if own == false then return end
    if own == nil or not C_TradeSkillUI.GetAllRecipeIDs then return Retry(token) end
    local profession = OpenProfession()
    if profession == nil then return Retry(token) end
    local key = Reader.CurrentCharacter()
    if not (profession and key) then return end
    local recipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
    if type(recipeIDs) ~= "table" or #recipeIDs == 0 then return Retry(token) end
    local known, sum = 0, 0
    for _, recipeID in ipairs(recipeIDs) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if not info then return Retry(token) end
        local live = info.learned == true
        local recorded = Recorded(key, recipeID)
        if recorded ~= nil and recorded ~= live then return Retry(token) end
        if live then
            known = known + 1
            sum = (sum + recipeID) % 2147483647
        end
    end
    attempts = 0
    local skillLine = profession.skillLine
    local scan = {time = GetServerTime(), recipes = #recipeIDs, known = known, base = profession.base,
        signature = known .. ":" .. sum}
    local previous = scans[skillLine]
    scans[skillLine] = scan
    Notify(skillLine, scan, not previous or previous.signature ~= scan.signature or previous.base ~= scan.base)
end

local function Schedule()
    generation = generation + 1
    attempts = 0
    local token = generation
    C_Timer.After(SETTLE_SECONDS, function() Verify(token) end)
end

-- Calls callback(skillLine, serverTime, recipes, known, base, changed) after each completed scan; `changed` is false
-- when the known recipes and skill match this session's previous scan of that profession.
function Source.OnScan(callback)
    listeners[#listeners + 1] = callback
end

local events = CreateFrame("Frame")
for _, event in ipairs({"TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED", "NEW_RECIPE_LEARNED"}) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event)
    if event == "TRADE_SKILL_CLOSE" then
        windowOpen = false
        generation = generation + 1
        return
    elseif event == "TRADE_SKILL_SHOW" then
        windowOpen = true
    end
    -- One check a burst, half a second after its first event: the window sends many list updates while crafting.
    if windowOpen and not pending then
        pending = true
        C_Timer.After(0, function()
            pending = false
            Schedule()
        end)
    end
end)
