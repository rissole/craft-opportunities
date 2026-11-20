local _, Crafts = ...

-- How well a product sells, from TradeSkillMaster's region statistics: the number sold per day across the region,
-- the sale rate (the share of postings that end in a sale) and the region sale average. They come from TSM's
-- DBRegionSoldPerDay, DBRegionSaleRate and DBRegionSaleAvg. Without them (no TSM, or TSM without its region data)
-- there is no sales data and the window shows none of the sales features.
local Market = {}
Crafts.Market = Market

-- Whether TSM has region sales data, worked out once.
local available

local function TSMValue(expression, itemID)
    local ok, value = pcall(TSM_API.GetCustomPriceValue, expression, "i:" .. itemID)
    return ok and type(value) == "number" and value / 1000 or nil
end

-- Whether sales data is loaded. TSM rounds every value to a whole number, so these come scaled by 1000, as TSM's own
-- tooltip asks for them.
function Market.Available()
    if available == nil then
        available = Crafts.Prices.HasTSM() and TSM_API and type(TSM_API.GetCustomPriceValue) == "function"
            and TSMValue("DBRegionSoldPerDay * 1000", 2589) ~= nil or false
    end
    return available
end

-- Sold per day, sale rate (0 to 1) and region sale average (copper) for an item, or nil when there is no data, or
-- none for this item: TSM lists only items that have been on the auction house.
function Market.Get(itemID)
    if not (itemID and Market.Available()) then return nil end
    local sold = TSMValue("DBRegionSoldPerDay * 1000", itemID)
    if sold == nil then return nil end
    local ok, average = pcall(TSM_API.GetCustomPriceValue, "DBRegionSaleAvg", "i:" .. itemID)
    average = ok and type(average) == "number" and average > 0 and average or nil
    return sold, TSMValue("DBRegionSaleRate * 1000", itemID), average
end

-- The Sales filter's two sliders. Sold per day steps through SOLD_STEPS (0 is any, HAS_SOLD any sale at all);
-- the sale rate runs 0 to RATE_MAX in RATE_STEP. A row without data never passes a minimum above 0. In the US data
-- (2026-11) 52% of crafted products have never sold, and a third of those selling 1 to 10 a day sell under 20% of
-- postings.
Market.HAS_SOLD = 0.001
Market.SOLD_STEPS = {0, Market.HAS_SOLD, 0.25, 0.5, 1, 2, 3, 5, 10, 25, 50, 100}
Market.RATE_STEP, Market.RATE_MAX = 0.05, 0.6
-- The fixed warning levels in the list, whatever the sliders say: Sold/day is red under 1 and green from 10; a
-- product selling 1+ a day is flagged under RATE_FLAG sale rate, and a sale price is flagged when the region sale
-- average is under PRICE_FLAG of it.
Market.RATE_FLAG, Market.PRICE_FLAG = 0.2, 0.75

-- The step at or nearest below a saved minimum.
function Market.SoldStep(value)
    local index = 1
    for i, step in ipairs(Market.SOLD_STEPS) do
        if type(value) == "number" and value >= step then index = i end
    end
    return index
end

function Market.SnapRate(value)
    if type(value) ~= "number" then return 0 end
    local steps = math.floor(value / Market.RATE_STEP + 0.5)
    return math.max(0, math.min(Market.RATE_MAX, steps * Market.RATE_STEP))
end
