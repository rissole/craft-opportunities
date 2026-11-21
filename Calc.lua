local _, Crafts = ...

-- What a recipe is worth and who could make it. Everything here is temporary: a job's rows and the price cache
-- live while the window is open and are dropped when it closes.
local Calc = {}
Crafts.Calc = Calc

Calc.KNOWN, Calc.MEETS, Calc.HIGHER, Calc.UNKNOWN = 1, 2, 3, 4
Calc.STATE_LABEL = {"Known", "Can learn", "Higher skill needed", "Not scanned / unknown"}
Calc.STATE_SHORT = {"Known", "Can learn", "Needs skill", "Unknown"}

-- {id, label, lowest state, highest state}. Meeting the skill requirement never means learnable now.
Calc.AVAILABILITY = {
    {"default", "Known or can learn", 1, 2},
    {"known", "Known only", 1, 1},
    {"meets", "Can learn, not known", 2, 2},
    {"higher", "Also higher skill needed", 1, 3},
    {"all", "Everything, including unknown", 1, 4},
}

-- Why a listed row has no sale proceeds.
Calc.ISSUE_TEXT = {
    unsupported = "Unsupported recipe",
    nosale = "No sale price",
}
-- Recipes that can never be sold are not listed at all, only counted: no item made (enchantments and other effects)
-- and soulbound results (bind on pickup or quest items).
Calc.EXCLUDED = {noitem = true, soulbound = true}

-- Item types ------------------------------------------------------------------------------------------------------

-- The game's item classes (Enum.ItemClass) in the auction house's category order. Calc.OTHER_CLASS holds products the
-- client has no class for, and recipes without an item. Weapons and armor are gear.
local ItemClass = Enum and Enum.ItemClass or {}
Calc.OTHER_CLASS = -1
Calc.CLASS_ORDER = {ItemClass.Weapon or 2, ItemClass.Armor or 4, ItemClass.Container or 1, ItemClass.Consumable or 0,
    ItemClass.Tradegoods or 7, ItemClass.Projectile or 6, ItemClass.Quiver or 11, ItemClass.Recipe or 9,
    ItemClass.Reagent or 5, ItemClass.Miscellaneous or 15, ItemClass.Questitem or 12, ItemClass.Key or 13}
Calc.GEAR = {[ItemClass.Weapon or 2] = true, [ItemClass.Armor or 4] = true}

-- A product's item class, from the client's own item data: no wait for the server.
function Calc.ItemClass(itemID)
    local classID = itemID and select(6, C_Item.GetItemInfoInstant(itemID))
    return type(classID) == "number" and classID or Calc.OTHER_CLASS
end

-- The item classes among some rows: those in Calc.CLASS_ORDER in that order, then any other by ID, then
-- Calc.OTHER_CLASS.
function Calc.ListedClasses(rows)
    local present, listed, rest = {}, {}, {}
    for _, row in ipairs(rows) do present[row.itemClass] = true end
    for _, classID in ipairs(Calc.CLASS_ORDER) do
        if present[classID] then
            listed[#listed + 1], present[classID] = classID, nil
        end
    end
    for classID in pairs(present) do
        if classID ~= Calc.OTHER_CLASS then rest[#rest + 1] = classID end
    end
    table.sort(rest)
    for _, classID in ipairs(rest) do listed[#listed + 1] = classID end
    if present[Calc.OTHER_CLASS] then listed[#listed + 1] = Calc.OTHER_CLASS end
    return listed
end

-- Prices -------------------------------------------------------------------------------------------------------

-- A per-calculation cache over one pricing snapshot (Prices.Current): material[itemID] and sale[itemID] are copper or
-- false for no price, source[itemID] and saleSource[itemID] where those came from, saleCut[itemID] the auction house
-- cut (in percent) that sale pays, bind[itemID] whether an output can be sold, pending[itemID] outputs whose binding
-- the client is still loading, and requested[itemID] those already asked for. Each is asked for once per cache: the
-- client answers some (items its data lacks) with a failure every time, and asking again would restart the
-- calculation forever.
function Calc.NewCache(pricing)
    return {pricing = pricing, material = {}, source = {}, sale = {}, saleSource = {}, saleCut = {}, bind = {},
        pending = {}, requested = {}, created = GetTime()}
end

-- One unit of a material and where its price came from, under the cache's pricing.
function Calc.MaterialPrice(reader, cache, itemID)
    local value = cache.material[itemID]
    if value == nil then
        local price, source = cache.pricing:Material(reader, itemID)
        value = price or false
        cache.material[itemID], cache.source[itemID] = value, source
    end
    return value or nil, cache.source[itemID]
end

-- One unit of a product before the auction house cut, where that came from, and the cut (in percent) its sale pays.
function Calc.SalePrice(reader, cache, itemID)
    local value = cache.sale[itemID]
    if value == nil then
        local price, source, cut = cache.pricing:Sale(reader, itemID)
        value = price or false
        cache.sale[itemID], cache.saleSource[itemID], cache.saleCut[itemID] = value, source, cut or 0
    end
    return value or nil, cache.saleSource[itemID], cache.saleCut[itemID]
end

-- Bind on pickup and quest items cannot be listed. Nil while the client is still loading the item.
local NOT_TRADABLE = {[1] = true, [4] = true}
function Calc.Tradable(cache, itemID)
    local cached = cache.bind[itemID]
    if cached ~= nil then return cached end
    local bindType = select(14, C_Item.GetItemInfo(itemID))
    if type(bindType) ~= "number" then
        if not cache.requested[itemID] then
            cache.requested[itemID], cache.pending[itemID] = true, true
            C_Item.RequestLoadItemDataByID(itemID)
        end
        return nil
    end
    cache.pending[itemID] = nil
    cached = not NOT_TRADABLE[bindType]
    cache.bind[itemID] = cached
    return cached
end

-- One craft: estimated profit, material cost, net sale proceeds, why sale proceeds are missing, and how many
-- materials have no price. Proceeds = sale price x mean yield x (1 - the cut that sale pays). An unknown figure is
-- nil, never 0, and so is any profit that depends on it. A recipe in Calc.EXCLUDED returns only its issue, before any
-- price is read.
function Calc.Evaluate(reader, cache, recipeID)
    local outputID, quantity, kind = reader.RecipeOutput(recipeID)
    if kind == "none" then return nil, nil, nil, "noitem", 0 end
    local count = reader.ReagentCount(recipeID)
    if kind ~= "item" or type(quantity) ~= "number" or quantity <= 0 or count == 0 then
        return nil, nil, nil, "unsupported", 0
    end
    -- Still loading (nil) counts as sellable; the window recalculates when the item arrives.
    if Calc.Tradable(cache, outputID) == false then return nil, nil, nil, "soulbound", 0 end
    local cost, missing = 0, 0
    for index = 1, count do
        local itemID, need = reader.Reagent(recipeID, index)
        local unit = itemID and need and Calc.MaterialPrice(reader, cache, itemID)
        if unit then
            cost = cost + unit * need
        else
            missing = missing + 1
        end
    end
    if missing > 0 then cost = nil end
    local proceeds, issue
    local unit, _, cut = Calc.SalePrice(reader, cache, outputID)
    if unit then
        proceeds = unit * quantity * (1 - cut / 100)
    else
        issue = "nosale"
    end
    local profit = cost and proceeds and proceeds - cost or nil
    return profit, cost, proceeds, issue, missing
end

-- The return on materials: net sale proceeds divided by material cost, so 2 means the proceeds are twice what the
-- materials cost (a profit of 100% of the cost). Nil when either is unknown, or the materials cost nothing.
function Calc.Return(cost, proceeds)
    if type(cost) ~= "number" or type(proceeds) ~= "number" or cost <= 0 then return nil end
    return proceeds / cost
end

-- Eligibility --------------------------------------------------------------------------------------------------

-- One character's state for one recipe, or nil when it does not have the profession. Without `learning` (a reader
-- that knows only recorded recipes) a character that does not know it has none either.
function Calc.State(crafter, recipeID, skillLine, required, learning)
    local entry = skillLine and crafter.professions[skillLine]
    if not entry then return nil end
    if Crafts.Knows(crafter, recipeID) then return Calc.KNOWN end
    if not learning then return nil end
    if not required then return Calc.UNKNOWN end
    return entry.base >= required and Calc.MEETS or Calc.HIGHER
end

-- The job ---------------------------------------------------------------------------------------------------------

-- One row per recipe at least one crafter has a state for, built a slice at a time:
-- {id, states (one digit per crafter, 0 for none), best, profit, cost, proceeds, ratio (Calc.Return), issue,
-- missing, itemClass (Calc.ItemClass), sold, saleRate and saleAverage (Market.Get, nil without data)}. Names, icons and requirements stay with the reader and are read when a row
-- is drawn. Recipes in Calc.EXCLUDED get no row;
-- job.excluded counts them by issue.
function Calc.NewJob(reader, cache, crafters)
    local job = {rows = {}, excluded = {noitem = 0, soulbound = 0}, crafters = crafters, processed = 0,
        total = reader.RecipeCount(), done = false, deadline = 0}
    job.thread = coroutine.create(function()
        local digits = {}
        for recipeID in reader.Recipes() do
            local skillLine = reader.RecipeProfession(recipeID)
            local best
            local required = reader.RecipeRequirement(recipeID)
            for index, crafter in ipairs(crafters) do
                local state = Calc.State(crafter, recipeID, skillLine, required, reader.learning)
                digits[index] = state or 0
                if state and (not best or state < best) then best = state end
            end
            if best then
                local profit, cost, proceeds, issue, missing = Calc.Evaluate(reader, cache, recipeID)
                if Calc.EXCLUDED[issue] then
                    job.excluded[issue] = job.excluded[issue] + 1
                else
                    local outputID, _, kind = reader.RecipeOutput(recipeID)
                    local sold, saleRate, saleAverage
                    if kind == "item" then sold, saleRate, saleAverage = Crafts.Market.Get(outputID) end
                    job.rows[#job.rows + 1] = {id = recipeID, states = table.concat(digits, "", 1, #crafters),
                        best = best, profit = profit, cost = cost, proceeds = proceeds,
                        ratio = Calc.Return(cost, proceeds), issue = issue, missing = missing,
                        itemClass = Calc.ItemClass(kind == "item" and outputID or nil), sold = sold,
                        saleRate = saleRate, saleAverage = saleAverage}
                end
            end
            job.processed = job.processed + 1
            if debugprofilestop() >= job.deadline then coroutine.yield() end
        end
    end)
    return job
end

-- Runs the job for about `budget` milliseconds; true once it has finished (job.error says if it failed).
function Calc.Step(job, budget)
    if job.done then return true end
    job.deadline = debugprofilestop() + (budget or 4)
    local ok, err = coroutine.resume(job.thread)
    if not ok then
        job.done, job.error = true, err
    elseif coroutine.status(job.thread) == "dead" then
        job.done = true
    end
    return job.done
end

function Calc.Availability(id)
    for _, option in ipairs(Calc.AVAILABILITY) do
        if option[1] == id then return option end
    end
    return Calc.AVAILABILITY[1]
end

-- The digit for one crafter, or the row's best state when no crafter is chosen.
function Calc.RowState(row, crafterIndex)
    if crafterIndex and crafterIndex > 0 then
        local state = tonumber(row.states:sub(crafterIndex, crafterIndex))
        return state ~= 0 and state or nil
    end
    return row.best
end

function Calc.Matches(reader, recipeID, search)
    local name = reader.RecipeName(recipeID)
    if name and name:lower():find(search, 1, true) then return true end
    local outputID = reader.RecipeOutput(recipeID)
    local itemName = outputID and C_Item.GetItemNameByID(outputID)
    return itemName ~= nil and itemName:lower():find(search, 1, true) ~= nil
end

-- The sort orders: {id, label}. Both put the highest first and unknown values last.
Calc.SORTS = {
    {"profit", "Estimated profit"},
    {"return", "Return (proceeds / materials)"},
    {"sold", "Sold per day"},
}

-- True when a known value comes first; nil when it does not decide (equal, or both unknown).
local function Higher(x, y)
    if x and y then
        if x ~= y then return x > y end
    elseif x or y then
        return x ~= nil
    end
    return nil
end

-- Profit: known profit first, highest first. Return: the highest return first, then by profit. Then the rest by
-- state and recipe ID.
local function ByProfit(a, b)
    local first = Higher(a.profit, b.profit)
    if first ~= nil then return first end
    if a.state ~= b.state then return a.state < b.state end
    return a.id < b.id
end
local function ByReturn(a, b)
    local first = Higher(a.ratio, b.ratio)
    if first ~= nil then return first end
    return ByProfit(a, b)
end
local function BySold(a, b)
    local first = Higher(a.sold, b.sold)
    if first ~= nil then return first end
    return ByProfit(a, b)
end
local SORTERS = {profit = ByProfit, ["return"] = ByReturn, sold = BySold}

-- Whether a row meets a minimum sold per day and sale rate. A row without data passes only minimums of 0.
function Calc.SellsEnough(row, minSold, minRate)
    if minSold > 0 and (row.sold or 0) < minSold then return false end
    return minRate <= 0 or (row.saleRate or 0) >= minRate - 1e-9
end

-- The rows the filters let through, sorted, and how many rows of each item class the other filters let through
-- ([classID] = count), whether that class is ticked or not. filter = {crafter (index, 0 for all), hiddenProfessions
-- ([skillLine] = true for each unticked one), hiddenItemClasses ([classID] = true for each unticked one),
-- availability (option id), search (lower case, "" for none), profitableOnly, minSold and minSaleRate (0 for none),
-- sort (Calc.SORTS)}. Each
-- row's `state` is set to the state shown for it under this filter.
function Calc.View(reader, job, filter)
    local option = Calc.Availability(filter.availability)
    local low, high = option[3], option[4]
    local hiddenClasses = filter.hiddenItemClasses or {}
    local minSold, minRate = filter.minSold or 0, filter.minSaleRate or 0
    local view, counts = {}, {}
    for _, row in ipairs(job.rows) do
        local state = Calc.RowState(row, filter.crafter)
        if state and state >= low and state <= high
            and not filter.hiddenProfessions[reader.RecipeProfession(row.id) or false]
            and (not filter.profitableOnly or (row.profit ~= nil and row.profit > 0))
            and (filter.search == "" or Calc.Matches(reader, row.id, filter.search))
            and Calc.SellsEnough(row, minSold, minRate) then
            counts[row.itemClass] = (counts[row.itemClass] or 0) + 1
            if not hiddenClasses[row.itemClass] then
                row.state = state
                view[#view + 1] = row
            end
        end
    end
    table.sort(view, SORTERS[filter.sort] or ByProfit)
    return view, counts
end

-- "Name: state" for each crafter shown for a row.
function Calc.CraftersText(job, row, crafterIndex)
    local parts = {}
    for index, crafter in ipairs(job.crafters) do
        local state = tonumber(row.states:sub(index, index))
        if state and state > 0 and (not crafterIndex or crafterIndex == 0 or crafterIndex == index) then
            parts[#parts + 1] = crafter.fullName .. ": " .. Calc.STATE_SHORT[state]
        end
    end
    return table.concat(parts, ", ")
end

-- Profitable, unpriced and total rows in a view.
function Calc.Summary(view)
    local profitable, unpriced = 0, 0
    for _, row in ipairs(view) do
        if row.profit == nil then
            unpriced = unpriced + 1
        elseif row.profit > 0 then
            profitable = profitable + 1
        end
    end
    return #view, profitable, unpriced
end
