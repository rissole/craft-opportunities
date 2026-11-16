local addonName, Crafts = ...

-- The addon's lifecycle, loaded after every other file so the whole Crafts table exists. Saved variables load into
-- CraftOpportunitiesDB. Each handler's error reaches the error handler without stopping the next event.

local function report(err)
    local handler = geterrorhandler and geterrorhandler()
    if handler then handler(err) else print(err) end
end

local function call(method, ...)
    local fn = Crafts[method]
    if type(fn) ~= "function" then return end
    local args, n = {...}, select("#", ...)
    xpcall(function() fn(Crafts, unpack(args, 1, n)) end, report)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
local listened = {}
for _, event in ipairs(Crafts.events) do
    listened[event] = true
    events:RegisterEvent(event)
end

events:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= addonName or Crafts.saved then return end
        events:UnregisterEvent("ADDON_LOADED")
        if type(CraftOpportunitiesDB) ~= "table" then CraftOpportunitiesDB = Crafts:Defaults() end
        call("OnInitialize", CraftOpportunitiesDB)
    elseif event == "PLAYER_LOGIN" then
        call("OnLogin")
    elseif listened[event] and Crafts.saved then
        call("OnEvent", event, ...)
    end
end)

SLASH_CRAFTOPPORTUNITIES1 = "/craftops"
SLASH_CRAFTOPPORTUNITIES2 = "/cops"
SlashCmdList.CRAFTOPPORTUNITIES = function(message)
    Crafts:OnSlash(message)
end

-- The minimap's addon compartment entry (## AddonCompartmentFunc).
function CraftOpportunities_OnAddonCompartmentClick()
    Crafts:OpenWindow()
end
