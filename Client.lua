local _, Crafts = ...

-- Recipes without SkillUp Forever: the ones this account's characters have recorded as known (Characters.lua), with
-- what each makes and needs read from the client's own recipe data. It answers the same questions as SkillUp.lua's
-- reader, except learn requirements and recipe sources, which only SkillUp has: Reader.learning is false, so only
-- known recipes are compared.
local Client = {}
Crafts.Client = Client

local function Positive(value)
    if type(value) == "number" and value > 0 and value < math.huge then return value end
    return nil
end

-- The recipe list ----------------------------------------------------------------------------------------------------

-- Every recipe a recorded character knows, sorted; [recipeID] = its skill line; [skillLine] = its recipe IDs, sorted.
-- Rebuilt by each Client.Open: a calculation keeps iterating the list it started with.
local allRecipes, lineOf, byLine = {}, {}, {}

local function Rebuild()
    local ids, lines, lists = {}, {}, {}
    for _, record in pairs(Crafts.saved and Crafts.saved.characters or {}) do
        for recipeID, skillLine in pairs(record.known) do
            if lines[recipeID] == nil then
                lines[recipeID] = skillLine
                ids[#ids + 1] = recipeID
                lists[skillLine] = lists[skillLine] or {}
                table.insert(lists[skillLine], recipeID)
            end
        end
    end
    table.sort(ids)
    for _, list in pairs(lists) do table.sort(list) end
    allRecipes, lineOf, byLine = ids, lines, lists
end

-- The client's profession for a recipe no character has recorded, as the base skill line professions are recorded
-- under. Nil when the client cannot say.
local function ClientProfession(recipeID)
    local api = C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoByRecipeID
    if type(api) ~= "function" then return nil end
    local ok, info = pcall(api, recipeID)
    if not ok or type(info) ~= "table" then return nil end
    return Positive(info.parentProfessionID) or Positive(info.professionID)
end

-- Recipe records -----------------------------------------------------------------------------------------------------

-- {output = {itemID, quantity} or false, reagents = {{itemID, quantity}}} from the client's schematic: basic reagents
-- only, since optional and finishing slots don't have to be filled. Nil when the client has no complete schematic;
-- that is asked again next time. Cached weakly, as SkillUp.lua does.
local records = setmetatable({}, {__mode = "v"})

local function Record(recipeID)
    local record = records[recipeID]
    if record then return record end
    local api = C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic
    if type(api) ~= "function" then return nil end
    local ok, schematic = pcall(api, recipeID, false)
    if not ok or type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then return nil end
    local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
    local reagents = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        if basic ~= nil and slot.reagentType == basic then
            local first = type(slot.reagents) == "table" and slot.reagents[1]
            if not (first and Positive(first.itemID) and Positive(slot.quantityRequired)) then return nil end
            reagents[#reagents + 1] = {itemID = first.itemID, quantity = slot.quantityRequired}
        end
    end
    local output = false
    if Positive(schematic.outputItemID) then
        local low = Positive(schematic.quantityMin) or 1
        local high = Positive(schematic.quantityMax) or low
        -- For salvage and gathering recipes the client's range is a reagent cost, not a yield.
        local types = Enum and Enum.TradeskillRecipeType
        if types and (schematic.recipeType == types.Salvage or schematic.recipeType == types.Gathering)
            or high < low then
            low, high = 1, 1
        end
        output = {itemID = schematic.outputItemID, quantity = (low + high) / 2}
    end
    record = {output = output, reagents = reagents}
    records[recipeID] = record
    return record
end

-- The reader ---------------------------------------------------------------------------------------------------------

local Reader = {learning = false}
Client.Reader = Reader

local NONE = {}

function Reader.Recipes()
    local list, index = allRecipes, 0
    return function()
        index = index + 1
        return list[index]
    end
end

function Reader.RecipeCount()
    return #allRecipes
end

function Reader.RecipeProfession(recipeID)
    return lineOf[recipeID] or ClientProfession(recipeID)
end

function Reader.ProfessionRecipes(skillLine)
    return byLine[skillLine] or NONE
end

function Reader.RecipeOutput(recipeID)
    local record = Record(recipeID)
    if not record then return nil, nil, "unknown" end
    if not record.output then return nil, nil, "none" end
    return record.output.itemID, record.output.quantity, "item"
end

function Reader.ReagentCount(recipeID)
    local record = Record(recipeID)
    return record and #record.reagents or 0
end

function Reader.Reagent(recipeID, index)
    local record = Record(recipeID)
    local reagent = record and record.reagents[index]
    if reagent then return reagent.itemID, reagent.quantity end
end

local function NextReagent(recipeID, index)
    index = index + 1
    local itemID, quantity = Reader.Reagent(recipeID, index)
    if itemID then return index, itemID, quantity end
end

function Reader.Reagents(recipeID)
    return NextReagent, recipeID, 0
end

function Reader.RecipeRequirement()
    return nil
end

function Reader.RecipeSources()
    return nil, "unavailable"
end

-- Names, icons and prices come from the client, Auctionator and TSM the same way with or without SkillUp.
for _, name in ipairs({"RecipeName", "RecipeIcon", "ProfessionName", "VendorPrice", "SellPrice"}) do
    Reader[name] = Crafts.SkillUp.Reader[name]
end

-- The reader, with the recipe list as the characters' records have it now.
function Client.Open()
    Rebuild()
    return Reader
end
