local _, Crafts = ...

-- Where prices come from, decided by whether TradeSkillMaster is installed.
--
--   With TSM:    everything is priced through TSM's public price API, with the material and sale expressions, auction
--                and vendor option set in Pricing. By default it matches TSM's own Crafting Cost and profit: materials
--                at TSM's MatPrice (its material cost method), products at TSM's craft value for that item (a Crafting
--                operation's override, else the Default craft value method). No auction house cut is ever taken: as in
--                TSM, a sale expression carries its own (for example * 0.95).
--   Without TSM: prices follow SkillUp Forever's own rules (its Integrations/Prices.lua): Auctionator's latest buyout;
--                a material costs the cheaper of that and a vendor's price; what a product sells for follows SkillUp's
--                own "Count what crafts sell for" setting (SkillUp.lua's CraftValue).
--
-- Prices.Current picks one for each calculation and returns a snapshot of the settings it uses. Calc.lua asks the
-- snapshot for prices; the window asks it what to say. Every snapshot has:
--   Material(reader, itemID) -> copper, source          one unit of a material
--   Sale(reader, itemID)     -> copper, source, cut     one unit of a product before the cut; the cut in percent
--   Problem()             -> nil, or why it cannot price
--   Explain(), Note()     -> the Pricing panel's text
--   mode ("tsm" or "skillup"), label (the status line) and key (equal keys price identically, for the cache).
-- A missing price is nil, never 0. Owned and gathered materials are priced as bought in both, never free.
local Prices = {}
Crafts.Prices = Prices

-- TSM's own material cost: MatPrice covers the materials of recipes TSM has scanned (with any per-material override);
-- any other material takes TSM's Default material cost method directly, which is what MatPrice would use. TSM's own
-- default method stands in when its setting cannot be read.
Prices.TSM_MAT_METHOD_DEFAULT = "min(dbmarket, crafting, vendorbuy, convert(dbmarket))"
-- The fallbacks, used only when TSM's own methods cannot be used here. When TSM offers Auctionator's auction value as
-- its AtrValue source, both follow it: materials also take TSM's conversions (for example three lesser essences for a
-- greater one). Without AtrValue they fall back to SkillUp Forever's TSM expression: the latest snapshot, its lowest
-- buyout, then the 14-day market value. The sale fallbacks take the 5% auction house cut in the expression, as TSM's
-- own default craft value does, since the TSM pricing takes none itself.
Prices.AUCTIONATOR_MATERIAL = "min(AtrValue, convert(AtrValue))"
Prices.AUCTIONATOR_SALE = "AtrValue * 0.95"
Prices.SKILLUP_TSM = "first(DBRecent, DBMinBuyout, DBMarket)"
Prices.SKILLUP_TSM_SALE = Prices.SKILLUP_TSM .. " * 0.95"
-- The sale expression while the "Sell to a vendor" toggle is on.
Prices.VENDOR_SALE = "VendorSell"
-- SkillUp's fixed auction house cut, in percent (without TSM only).
Prices.SKILLUP_CUT = 5

Prices.VENDOR_OPTIONS = {
    {"cheaper", "Cheaper of vendor and TSM price"},
    {"tsm", "TSM price only"},
}

local function Positive(value)
    if type(value) == "number" and value > 0 and value < math.huge then return value end
    return nil
end

-- 5 -> "5", 2.5 -> "2.5".
function Prices.Percent(value)
    return (string.format("%.2f", value):gsub("%.?0+$", ""))
end

function Prices.HasTSM()
    return TSM_API ~= nil and type(TSM_API.GetCustomPriceValue) == "function"
end

local function AuctionatorAPI()
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    return api and type(api.GetAuctionPriceByItemID) == "function" and api or nil
end

-- A vendor's price for a material, and where it came from: what a merchant showed (reputation discounts included),
-- else SkillUp's bundled list.
local function Vendor(reader, itemID)
    local price, origin = reader.VendorPrice(itemID)
    price = Positive(price)
    if not price then return nil end
    return price, origin == "seen" and "Vendor" or "Vendor list price"
end

-- TradeSkillMaster ----------------------------------------------------------------------------------------------

-- The default material and sale expressions, which fallback they use ("auctionator" or "skillup"), and whether each
-- is TSM's own (the sale's fourth value, the material's fifth). TSM's own are its material cost (Prices.TSMMaterial)
-- and its Default craft value method (Settings > Crafting), when usable here. TSM registers its AtrValue source only
-- when Auctionator is enabled, so a valid AtrValue means Auctionator prices are available.
function Prices.DefaultExpressions()
    local material, sale, origin = Prices.SKILLUP_TSM, Prices.SKILLUP_TSM_SALE, "skillup"
    if TSM_API and type(TSM_API.IsCustomPriceValid) == "function" then
        local ok, valid = pcall(TSM_API.IsCustomPriceValid, "AtrValue")
        if ok and valid then material, sale, origin = Prices.AUCTIONATOR_MATERIAL, Prices.AUCTIONATOR_SALE, "auctionator" end
    end
    local tsmMaterial, craftValue = Prices.TSMMaterial(), Prices.TSMCraftValue()
    return tsmMaterial or material, craftValue or sale, origin, craftValue ~= nil, tsmMaterial ~= nil
end

-- One of TSM's Crafting settings, trimmed; nil when unset. TSM has no API for them, so they are read from its saved
-- settings, which TSM keeps current while it runs.
local function TSMCraftingSetting(key)
    local db = type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB or nil
    local value = db and db["g@ @craftingOptions@" .. key]
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    return value ~= "" and value or nil
end

-- TSM's material cost as an expression: MatPrice where TSM tracks the material, else TSM's Default material cost
-- method. Nil when TSM cannot evaluate it.
function Prices.TSMMaterial()
    local expression = "first(MatPrice, " .. (TSMCraftingSetting("defaultMatCostMethod") or Prices.TSM_MAT_METHOD_DEFAULT)
        .. ")"
    if Prices.CheckExpression(expression, "material") then return nil end
    return expression
end

-- TSM's default craft value method, nil when it is unset or cannot be used as a sale expression here.
function Prices.TSMCraftValue()
    local value = TSMCraftingSetting("defaultCraftPriceMethod")
    if not value or Prices.CheckExpression(value, "sale") then return nil end
    return value
end

-- This character's key and faction-realm as TSM writes them in an operation's ignore lists: "Name - Horde - Normal"
-- and "Horde - Normal", where the realm is the realm's ruleset, not its name.
local function TSMPlayerKeys()
    local ruleset = GetRealmName()
    local rules = C_GameRules
    if rules and type(rules.IsGameRuleActive) == "function" and Enum and Enum.GameRule then
        local function active(rule) return rule ~= nil and rules.IsGameRuleActive(rule) end
        local rp, pvp = active(Enum.GameRule.RPRuleset), active(Enum.GameRule.PvPRuleset)
        if active(Enum.GameRule.HardcoreRuleset) then ruleset = "Hardcore"
        elseif rp and pvp then ruleset = "Roleplay PvP"
        elseif rp then ruleset = "Roleplay"
        elseif pvp then ruleset = "PvP"
        else ruleset = "Normal" end
    end
    local factionrealm = (UnitFactionGroup("player") or "") .. " - " .. (ruleset or "")
    return (UnitName("player") or "") .. " - " .. factionrealm, factionrealm
end

-- The craft value override TSM uses for one item, or nil for its Default craft value method. As TSM picks it: the
-- first Crafting operation on the item's group (ungrouped items have the base group's) that is not ignored for this
-- character or faction-realm, following a link of its craft value to another operation. Read from TSM's saved
-- settings for its active profile; nil whenever they cannot be read or the override cannot be used here.
function Prices.TSMCraftOverride(itemID)
    local db = type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB or nil
    if not db or type(TSM_API.GetActiveProfile) ~= "function" or type(TSM_API.GetGroupPathByItem) ~= "function" then
        return nil
    end
    local okProfile, profile = pcall(TSM_API.GetActiveProfile)
    local okPath, path = pcall(TSM_API.GetGroupPathByItem, "i:" .. itemID)
    if not okProfile or type(profile) ~= "string" or not okPath then return nil end
    local groups = db["p@" .. profile .. "@userData@groups"]
    local operations = db["p@" .. profile .. "@userData@operations"]
    local group = type(groups) == "table" and groups[path or ""]
    local assigned = type(group) == "table" and group.Crafting
    operations = type(operations) == "table" and operations.Crafting
    if type(assigned) ~= "table" or type(operations) ~= "table" then return nil end
    local character, factionrealm = TSMPlayerKeys()
    for _, name in ipairs(assigned) do
        local operation = operations[name]
        if type(operation) == "table"
            and not (type(operation.ignorePlayer) == "table" and operation.ignorePlayer[character])
            and not (type(operation.ignoreFactionrealm) == "table" and operation.ignoreFactionrealm[factionrealm]) then
            local seen = {}
            while not seen[operation] and type(operation.relationships) == "table"
                and type(operations[operation.relationships.craftPriceMethod]) == "table" do
                seen[operation] = true
                operation = operations[operation.relationships.craftPriceMethod]
            end
            local method = type(operation.craftPriceMethod) == "string" and operation.craftPriceMethod:match("^%s*(.-)%s*$")
            if not method or method == "" or Prices.CheckExpression(method, "sale") then return nil end
            return method
        end
    end
    return nil
end

-- Nil when the expression can be used for `kind` ("material" or "sale"), else why not.
function Prices.CheckExpression(expression, kind)
    if type(expression) ~= "string" or not expression:find("%S") then
        return "Enter a TSM price expression."
    end
    -- TSM itself refuses Crafting in a craft value; materials may use it, as TSM's material cost does.
    local lower = expression:lower()
    if kind == "sale" and lower:find("%f[%w]crafting%f[^%w]") then
        return "Crafting is TSM's crafting cost, not a sale price (TSM refuses it in a craft value too)."
    end
    if kind == "sale" and lower:find("%f[%w]matprice%f[^%w]") then
        return "MatPrice is TSM's material valuation, which can include crafting costs, not a sale price."
    end
    if TSM_API and type(TSM_API.IsCustomPriceValid) == "function" then
        local ok, isValid, err = pcall(TSM_API.IsCustomPriceValid, expression)
        if not ok then return "TSM could not check this expression." end
        if not isValid then return "TSM: " .. tostring(err or "invalid price expression") end
    end
    return nil
end

-- TSM's value for one item, nil when TSM has none (never 0).
function Prices.TSMValue(expression, itemID)
    if not Prices.HasTSM() then return nil end
    local ok, value = pcall(TSM_API.GetCustomPriceValue, expression, "i:" .. itemID)
    return ok and Positive(value) or nil
end

local TSM = {mode = "tsm"}
TSM.__index = TSM

-- TSM's material price, or a vendor's when that is cheaper (or when TSM has none) under the "cheaper" setting.
function TSM:Material(reader, itemID)
    local market = Prices.TSMValue(self.materialPrice, itemID)
    local vendor, source = Vendor(reader, itemID)
    if vendor and self.vendorMaterials == "cheaper" and (not market or vendor <= market) then return vendor, source end
    if market then return market, "TSM" end
    return nil
end

-- Following TSM's craft value, an item a Crafting operation overrides takes that operation's method.
function TSM:Sale(_, itemID)
    local expression = self.followCraftValue and Prices.TSMCraftOverride(itemID) or self.salePrice
    local value = Prices.TSMValue(expression, itemID)
    if value then return value, self.followCraftValue and "TSM craft value" or "TSM", 0 end
    return nil
end

function TSM:Problem()
    local field, problem = "Material price", Prices.CheckExpression(self.materialPrice, "material")
    if not problem then field, problem = "Sale price", Prices.CheckExpression(self.salePrice, "sale") end
    if not problem then return nil end
    return "A saved TSM price expression cannot be used.\n\n" .. field .. ": " .. problem
        .. "\n\nOpen Pricing to change it."
end

function TSM:Explain()
    local text = "TradeSkillMaster is installed, so everything is priced through TSM. "
    if self.materialFromTSM then
        text = text .. "The default material price is TSM's material cost, as in its Crafting Cost: MatPrice, else "
            .. "TSM's Default material cost method (TSM Settings > Crafting). "
    elseif self.origin == "auctionator" then
        text = text .. "The default material price follows Auctionator through TSM's AtrValue source: "
            .. Prices.AUCTIONATOR_MATERIAL .. ". "
    else
        text = text .. "TSM has no AtrValue source (Auctionator is not enabled), so the default material price is "
            .. "SkillUp Forever's: " .. Prices.SKILLUP_TSM .. ". "
    end
    if self.saleVendor then
        return text .. "Sell to a vendor is on: sales are valued at VendorSell."
    end
    if self.saleFromTSM then
        return text .. "The default sale price is TSM's craft value, as in its profit: a Crafting operation's "
            .. "override, else the Default craft value method (" .. self.defaultSale .. ")."
    end
    return text .. "The default sale price is " .. self.defaultSale .. "."
end

function TSM:Note()
    return "Prices are this character's realm and faction market. Sale proceeds are the sale price times the mean "
        .. "yield. No auction house cut is taken, as in TSM's own profit, so a sale expression should take its own: "
        .. "for example max(AtrValue * 0.95, VendorSell). An expression left at its default keeps following it."
end

-- SkillUp Forever's rules ---------------------------------------------------------------------------------------

local SkillUp = {mode = "skillup"}
SkillUp.__index = SkillUp

-- Auctionator's latest recorded buyout, as SkillUp reads it.
function SkillUp:Auction(itemID)
    local api = AuctionatorAPI()
    if not api then return nil end
    local ok, value = pcall(api.GetAuctionPriceByItemID, Crafts.name or "CraftOpportunities", itemID)
    return ok and Positive(value) or nil
end

-- The cheaper of a vendor's price and the auction price; on a tie, the vendor.
function SkillUp:Material(reader, itemID)
    local market = self:Auction(itemID)
    local vendor, source = Vendor(reader, itemID)
    if vendor and (not market or vendor <= market) then return vendor, source end
    if market then return market, "Auctionator" end
    return nil
end

-- What a product sells for, by SkillUp's "Count what crafts sell for" (SkillUp's ItemValue): "vendor", its vendor
-- sell price; "auction", its auction price, which pays the 5% cut, or the vendor sell price, which pays none, when that
-- brings more; "sale" (SkillUp 1.10+), TSM's regional sale average, which this TSM-less snapshot never has, so the
-- vendor sell price, as SkillUp falls back to; "none", nothing, which Problem() reports instead.
function SkillUp:Sale(reader, itemID)
    if self.craftValue == "none" then return nil end
    local sell = Positive((reader.SellPrice(itemID)))
    local market = self.craftValue == "auction" and self:Auction(itemID) or nil
    if market and (not sell or market * (1 - Prices.SKILLUP_CUT / 100) > sell) then
        return market, "Auctionator", Prices.SKILLUP_CUT
    end
    if sell then return sell, "Vendor sell price", 0 end
    return nil
end

-- With crafts counted as selling for nothing there is nothing to compare, so the window says why instead of listing
-- every recipe without a sale price.
function SkillUp:Problem()
    if self.craftValue ~= "none" then return nil end
    return "SkillUp Forever is set not to count what crafts sell for (Count what crafts sell for: "
        .. self.craftValueLabel .. ", in its Prices settings), so no sale can be estimated.\n\nChoose Vendor sell "
        .. "price or Auction price if higher there, then click Refresh. With TradeSkillMaster installed, Craft "
        .. "Opportunities prices sales through TSM instead."
end

-- What "Count what crafts sell for" means for a product under this snapshot.
function SkillUp:SaleRule()
    if self.craftValue == "auction" then
        return "its auction price less the 5% auction house cut, or its vendor sell price when that is more"
    end
    if self.craftValue == "sale" then
        return "its vendor sell price (the region sale average needs TradeSkillMaster)"
    end
    return "its vendor sell price"
end

function SkillUp:Explain()
    local where = self.source and "Auctionator's latest scan"
        or "nowhere: Auctionator is not loaded either, so only vendor prices are known"
    return "TradeSkillMaster is not installed, so prices follow SkillUp Forever's own rules. Auction prices come from "
        .. where .. ". A material costs the cheaper of a vendor's price and the auction price. What a product sells "
        .. "for follows SkillUp's Count what crafts sell for setting (" .. self.craftValueLabel .. "): "
        .. self:SaleRule() .. "."
end

function SkillUp:Note()
    return "Prices are this character's realm and faction market. Change Count what crafts sell for in SkillUp "
        .. "Forever's settings (Prices), then click Refresh. Install TradeSkillMaster to price with TSM expressions "
        .. "instead."
end

-- The pricing ---------------------------------------------------------------------------------------------------

-- The pricing for one calculation, chosen by whether TSM is installed: a fresh snapshot of the saved settings it uses
-- (for TSM) or of SkillUp's (without it; `reader` is SkillUp.lua's reader). A saved expression of "" follows the
-- current default.
function Prices.Current(saved, reader)
    if Prices.HasTSM() then
        local material, sale, origin, saleFromTSM, materialFromTSM = Prices.DefaultExpressions()
        local saleDefault = not saved.saleVendor and saved.salePrice == ""
        -- No cut is taken: a TSM sale expression carries its own, as TSM's craft value does.
        local followCraftValue = saleDefault and saleFromTSM
        local snapshot = setmetatable({
            materialPrice = saved.materialPrice ~= "" and saved.materialPrice or material,
            salePrice = saved.saleVendor and Prices.VENDOR_SALE or (saved.salePrice ~= "" and saved.salePrice or sale),
            materialDefault = saved.materialPrice == "",
            saleDefault = saleDefault,
            saleVendor = saved.saleVendor,
            origin = origin,
            defaultSale = sale,
            saleFromTSM = saleFromTSM,
            materialFromTSM = materialFromTSM,
            followCraftValue = followCraftValue,
            vendorMaterials = saved.vendorMaterials,
        }, TSM)
        snapshot.label = saved.saleVendor and "TSM, sold to a vendor"
            or followCraftValue and "TSM crafting cost and craft value"
            or "TSM, own sale expression"
        snapshot.key = table.concat({"tsm", snapshot.materialPrice, snapshot.salePrice, saved.vendorMaterials},
            "\031")
        return snapshot
    end
    local source = AuctionatorAPI() and "Auctionator" or nil
    -- SkillUp's own default, "vendor", while its setting cannot be read.
    local craftValue, craftValueLabel
    if reader and type(reader.CraftValue) == "function" then craftValue, craftValueLabel = reader.CraftValue() end
    if not craftValue then craftValue, craftValueLabel = "vendor", "Vendor sell price" end
    return setmetatable({
        source = source,
        craftValue = craftValue,
        craftValueLabel = craftValueLabel or craftValue,
        label = "SkillUp Forever's rules (" .. (source or "no TSM or Auctionator") .. "), crafts sell for: "
            .. (craftValueLabel or craftValue),
        key = table.concat({"skillup", tostring(source), craftValue}, "\031"),
    }, SkillUp)
end
