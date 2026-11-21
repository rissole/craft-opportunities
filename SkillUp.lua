local _, Crafts = ...

-- What Craft Opportunities reads from SkillUp Forever, behind one reader the rest of the addon uses.
--
-- SkillUp Forever's public API (SkillUpForever.API, minor 7 or later, first released in SkillUp Forever v1.12.0)
-- supplies the bundled recipes and reagents (Recipes, Recipe) and learn requirements (RecipeRequirement). Where a
-- recipe item comes from is RecipeSources, when SkillUp has it. Which characters know which recipes is Craft
-- Opportunities' own record (Characters.lua), not SkillUp's.
--
-- Vendor prices come from Auctionator or TSM. The rest comes from the client: recipe names and icons, profession
-- names and sell prices.
local Source = {}
Crafts.SkillUp = Source
-- The first SkillUp Forever release with every public member below, for the "too old" message.
Source.MINIMUM = "v1.12.0"

-- The public members this addon needs (SkillUp issue #724).
local RECIPE_MEMBERS = {"Recipes", "Recipe", "RecipeRequirement"}
-- The professions SkillUp's data has, to list each one's recipes without reading every recipe record. A recipe of any
-- other skill line is found by reading its record.
local SKILL_LINES = {129, 164, 165, 171, 182, 185, 186, 197, 202, 333, 356, 393, 755, 773}

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

-- SkillUp's API, set by Source.Open once it has every recipe member.
local public

local function Positive(value)
    if type(value) == "number" and value > 0 and value < math.huge then return value end
    return nil
end

-- Recipe records ------------------------------------------------------------------------------------------------

-- Every bundled recipe ID, sorted, [recipeID] = skill line, and [skillLine] = its recipe IDs, sorted: read once, since
-- SkillUp's bundle never changes in a session. Recipe records are cached weakly: the collector drops them while the
-- window is closed.
local allRecipes, lineOf, byLine
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
    if allRecipes then return allRecipes, lineOf, byLine end
    local ids = public.Recipes() or {}
    local lines, lists = {}, {}
    for _, skillLine in ipairs(SKILL_LINES) do
        for _, recipeID in ipairs(public.Recipes(skillLine) or {}) do lines[recipeID] = skillLine end
    end
    for _, recipeID in ipairs(ids) do
        if not lines[recipeID] then
            local record = public.Recipe(recipeID)
            lines[recipeID] = type(record) == "table" and record.skillLineID or false
        end
        local skillLine = lines[recipeID]
        if skillLine then
            lists[skillLine] = lists[skillLine] or {}
            table.insert(lists[skillLine], recipeID)
        end
    end
    allRecipes, lineOf, byLine = ids, lines, lists
    return ids, lines, lists
end

-- The reader ---------------------------------------------------------------------------------------------------------

-- learning: SkillUp knows every recipe and its learn requirement, so characters that could learn one are compared too.
local Reader = {learning = true}
Source.Reader = Reader

local NONE = {}

-- `for recipeID in Reader.Recipes() do`: every bundled recipe ID. Safe across frames: the list never changes.
function Reader.Recipes()
    local list, index = Index(), 0
    return function()
        index = index + 1
        return list[index]
    end
end

function Reader.RecipeCount()
    return #Index()
end

function Reader.RecipeProfession(recipeID)
    local _, lines = Index()
    return lines[recipeID] or nil
end

-- One profession's bundled recipe IDs, sorted; read only.
function Reader.ProfessionRecipes(skillLine)
    local _, _, lists = Index()
    return lists[skillLine] or NONE
end

-- itemID, mean yield, "item"; nil, nil, "none" for a recipe that makes no item; nil, nil, "unknown".
function Reader.RecipeOutput(recipeID)
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
    local record = Record(recipeID)
    return record and type(record.reagents) == "table" and #record.reagents or 0
end

function Reader.Reagent(recipeID, index)
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
-- it, and the trainer's fee.
function Reader.RecipeRequirement(recipeID)
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
    if type(public.RecipeSources) ~= "function" then return nil, "unavailable" end
    local found, reason = public.RecipeSources(recipeID)
    if type(found) ~= "table" then return nil, reason == "loading" and "loading" or "none" end
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
end

-- Prices -------------------------------------------------------------------------------------------------------------

-- What a vendor charges for one, "seen": what Auctionator saw at a merchant, else TSM's VendorBuy. Nil for an item no
-- vendor is known to sell.
function Reader.VendorPrice(itemID)
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

-- What a vendor pays for one, "live": the client's sell price. Nil while the item's data loads.
function Reader.SellPrice(itemID)
    local sell = select(11, C_Item.GetItemInfo(itemID))
    if issecretvalue and issecretvalue(sell) then sell = nil end
    if type(sell) == "number" then return sell, "live" end
    C_Item.RequestLoadItemDataByID(itemID)
    return nil
end

-- Opening ------------------------------------------------------------------------------------------------------------

-- The reader when SkillUp Forever can answer: Reader; otherwise nil and why: "skillup" (no SkillUp API), "old" (its
-- API lacks the recipe members) or "loading" (its saved variables are still loading).
function Source.Open()
    local api = PublicAPI()
    if not api then return nil, "skillup" end
    if not HasPublic(api) then return nil, "old" end
    public = api
    if public.Recipes() == nil then return nil, "loading" end
    return Reader
end
