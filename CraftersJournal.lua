local _, Crafts = ...

-- Recipes from Crafter's Journal, when SkillUp Forever is not loaded. Crafter's Journal has no public API: this reads
-- its bundled tables through its global (CraftersJournal.Data and CraftersJournal.Waypoints), and checks their shape
-- on opening, so a Crafter's Journal that has changed them leaves Craft Opportunities on the client's reader.
--
-- Its profession tables are Data.<Profession> = {skillLine, recipes = {[recipeID] = {r = {{itemID, quantity}}, out =
-- {itemID, quantity}, train (required skill), t (skill thresholds), fee (trainer), basic, trainer, scroll (the recipe
-- item)}}}, and where a recipe item comes from is Data.ItemSources[itemID] = {v = vendors, q = quests, d = drops, w, o}.
local Journal = {}
Crafts.CraftersJournal = Journal

local function Positive(value)
    if type(value) == "number" and value > 0 and value < math.huge then return value end
    return nil
end

local function Addon()
    local journal = _G.CraftersJournal
    return type(journal) == "table" and type(journal.Data) == "table" and journal or nil
end

-- Whether Crafter's Journal is loaded. An addon cannot load later in a session, so this holds once logged in.
function Journal.Loaded()
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("CraftersJournal")
    return loaded and Addon() ~= nil or false
end

-- Recipe records -----------------------------------------------------------------------------------------------------

-- Every recipe ID, sorted; [recipeID] = its record; [recipeID] = skill line; [skillLine] = its recipe IDs, sorted.
-- Built once: the tables are bundled. Records are held here because Crafter's Journal drops the other faction's
-- recipes from its own tables at login, and this account's other characters may be of that faction.
local allRecipes, recordOf, lineOf, byLine

local function Index()
    if allRecipes then return allRecipes end
    local ids, records, lines, lists = {}, {}, {}, {}
    for _, profession in pairs(Addon().Data) do
        local skillLine = type(profession) == "table" and Positive(profession.skillLine)
        if skillLine and type(profession.recipes) == "table" then
            for recipeID, record in pairs(profession.recipes) do
                if type(recipeID) == "number" and type(record) == "table" and not records[recipeID] then
                    ids[#ids + 1] = recipeID
                    records[recipeID], lines[recipeID] = record, skillLine
                    lists[skillLine] = lists[skillLine] or {}
                    table.insert(lists[skillLine], recipeID)
                end
            end
        end
    end
    table.sort(ids)
    for _, list in pairs(lists) do table.sort(list) end
    allRecipes, recordOf, lineOf, byLine = ids, records, lines, lists
    return ids
end

-- The reader ---------------------------------------------------------------------------------------------------------

local Reader = {learning = true}
Journal.Reader = Reader

local NONE = {}

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
    Index()
    return lineOf[recipeID]
end

function Reader.ProfessionRecipes(skillLine)
    Index()
    return byLine[skillLine] or NONE
end

-- A pair {itemID, quantity} as numbers, else nil.
local function Pair(pair)
    if type(pair) == "table" and Positive(pair[1]) and Positive(pair[2]) then return pair[1], pair[2] end
end

function Reader.RecipeOutput(recipeID)
    Index()
    local record = recordOf[recipeID]
    if not record then return nil, nil, "unknown" end
    if record.out == nil then return nil, nil, "none" end
    local itemID, quantity = Pair(record.out)
    if not itemID then return nil, nil, "unknown" end
    return itemID, quantity, "item"
end

function Reader.ReagentCount(recipeID)
    Index()
    local record = recordOf[recipeID]
    return record and type(record.r) == "table" and #record.r or 0
end

function Reader.Reagent(recipeID, index)
    Index()
    local record = recordOf[recipeID]
    return Pair(record and type(record.r) == "table" and record.r[index])
end

local function NextReagent(recipeID, index)
    index = index + 1
    local itemID, quantity = Reader.Reagent(recipeID, index)
    if itemID then return index, itemID, quantity end
end

function Reader.Reagents(recipeID)
    return NextReagent, recipeID, 0
end

-- As SkillUp.lua's: the required skill (its trainer level, else where the recipe turns orange), "trainer" or "item",
-- the recipe item and the trainer's fee.
function Reader.RecipeRequirement(recipeID)
    Index()
    local record = recordOf[recipeID]
    if not record then return nil end
    local skill = Positive(record.train) or Positive(type(record.t) == "table" and record.t[1])
    local recipeItem = Positive(record.scroll)
    local source = recipeItem and "item" or ((record.fee or record.basic or record.trainer) and "trainer") or nil
    return skill, source, recipeItem, Positive(record.fee)
end

local SIDES = {Alliance = "A", Horde = "H"}

-- A vendor, quest giver or creature as Crafter's Journal places it: its name and zone, and whether this character's
-- faction can deal with it ("" is both, "X" is hostile to both).
local function Usable(side)
    local mine = SIDES[UnitFactionGroup("player")]
    if side == "" or not mine or (side ~= "A" and side ~= "H") then return true end
    return side == mine
end

local function NPC(waypoints, npcID)
    local ok, npc = pcall(waypoints.NPC, npcID)
    if not ok or type(npc) ~= "table" or type(npc.name) ~= "string" then return nil end
    local zone
    if type(waypoints.ZoneName) == "function" then
        local named, name = pcall(waypoints.ZoneName, npc)
        zone = named and type(name) == "string" and name or nil
    end
    return {npcID = npcID, name = npc.name, zone = zone, usable = Usable(npc.side)}
end

-- As SkillUp.lua's: {itemID, vendors, quests, drops, world, containers}, vendors this character can deal with first; otherwise
-- nil and "none", or "unavailable" when Crafter's Journal cannot place NPCs.
function Reader.RecipeSources(recipeID)
    local _, _, recipeItem = Reader.RecipeRequirement(recipeID)
    local journal = Addon()
    local waypoints = journal.Waypoints
    local sources = type(journal.Data.ItemSources) == "table" and journal.Data.ItemSources
    if not (type(waypoints) == "table" and type(waypoints.NPC) == "function" and sources) then
        return nil, "unavailable"
    end
    local item = recipeItem and sources[recipeItem]
    if type(item) ~= "table" then return nil, "none" end
    local found = {itemID = recipeItem, vendors = {}, quests = {}, drops = {}, world = Positive(item.w) and true,
        containers = Positive(item.o) and true}
    local later = {}
    for _, npcID in ipairs(type(item.v) == "table" and item.v or NONE) do
        local vendor = NPC(waypoints, npcID)
        if vendor then table.insert(vendor.usable and found.vendors or later, vendor) end
    end
    for _, vendor in ipairs(later) do found.vendors[#found.vendors + 1] = vendor end
    local quests = type(waypoints.Quest) == "function" and type(item.q) == "table" and item.q or NONE
    for _, questID in ipairs(quests) do
        local ok, quest = pcall(waypoints.Quest, questID)
        if ok and type(quest) == "table" and type(quest.name) == "string" then
            found.quests[#found.quests + 1] = {questID = questID, title = quest.name, usable = Usable(quest.side)}
        end
    end
    for _, npcID in ipairs(type(item.d) == "table" and item.d or NONE) do
        local creature = NPC(waypoints, npcID)
        if creature then
            creature.usable = nil
            found.drops[#found.drops + 1] = creature
        end
    end
    return found
end

-- Names, icons and prices come from the client, Auctionator and TSM the same way with any reader.
for _, name in ipairs({"RecipeName", "RecipeIcon", "ProfessionName", "VendorPrice", "SellPrice"}) do
    Reader[name] = Crafts.SkillUp.Reader[name]
end

-- The reader when Crafter's Journal is loaded and its tables have the shape above, else nil.
function Journal.Open()
    local journal = Addon()
    if not journal then return nil end
    local ok, count = pcall(function() return #Index() end)
    if not ok or count == 0 then
        allRecipes = nil
        return nil
    end
    return Reader
end
