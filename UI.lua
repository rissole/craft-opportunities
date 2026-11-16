local _, Crafts = ...
local Calc = Crafts.Calc
local Prices = Crafts.Prices

-- The Craft Opportunities window, in SkillUp Forever's native style: a portrait frame, inset panels, the game's own
-- dropdowns and buttons, and a scroll box that draws only the rows on screen.

local FRAME_NAME = "CraftOpportunitiesFrame"
local ROW_TEMPLATE = "CraftOpportunityRowTemplate"
local WIDTH, HEIGHT, DETAILS_WIDTH = 1016, 620, 330
local LIST_WIDTH = WIDTH - 20 - DETAILS_WIDTH - 6
-- Money columns, then the narrower return column at the right.
local ROW_HEIGHT, COLUMN, RETURN_COLUMN, SCROLL_BAR = 38, 86, 56, 20
local NAME_WIDTH = LIST_WIDTH - 4 - SCROLL_BAR - 41 - 3 * COLUMN - RETURN_COLUMN - 10
local DETAIL_WIDTH = DETAILS_WIDTH - 8 - 26 - 4
local BUDGET_MS, CACHE_SECONDS = 4, 300
local ICON = "Interface\\Icons\\INV_Misc_Coin_02"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local PROFESSION_ICONS = {
    [129] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
    [164] = "Interface\\Icons\\Trade_BlackSmithing",
    [165] = "Interface\\Icons\\INV_Misc_ArmorKit_17",
    [171] = "Interface\\Icons\\Trade_Alchemy",
    [182] = "Interface\\Icons\\Trade_Herbalism",
    [185] = "Interface\\Icons\\INV_Misc_Food_15",
    [186] = "Interface\\Icons\\Trade_Mining",
    [197] = "Interface\\Icons\\Trade_Tailoring",
    [202] = "Interface\\Icons\\Trade_Engineering",
    [333] = "Interface\\Icons\\Trade_Engraving",
    [356] = "Interface\\Icons\\Trade_Fishing",
    [393] = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
}
local STATE_COLORS = {{0.25, 0.85, 0.25}, {1, 0.82, 0}, {1, 0.5, 0.25}, {0.6, 0.6, 0.6}}
local DISCLOSURE = "An estimate from current auction prices, not a guaranteed sale. Not counted: recipe and training "
    .. "costs, auction deposits and relisting, and time to sell. Materials you own or gather are valued at their "
    .. "price, never free."

local frame, list, message, status, header, pricing, detailBody, searchBox, profitable
local dropdowns = {}
-- Temporary while the window is open, released when it closes: SkillUp's reader, the finished job whose rows are
-- shown, the job still calculating (shown once it finishes, so a refresh never blanks the list), the filtered view,
-- the price cache and the filter the view was drawn with.
local reader, job, work, view, cache, filter
local selected, searchText, paused = nil, "", false
local restartAt, viewAt, redrawAt

local function report(err)
    local handler = geterrorhandler and geterrorhandler()
    if handler then handler(err) end
end

-- Text ----------------------------------------------------------------------------------------------------------

local GOLD = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

-- Copper as coins; compact drops copper above a gold and silver above 100 gold, to fit a column.
local function Money(copper, compact)
    if type(copper) ~= "number" then return "-" end
    local value = math.floor(math.abs(copper) + 0.5)
    local gold, silver, rest = math.floor(value / 10000), math.floor(value / 100) % 100, value % 100
    local text
    if gold > 0 then
        text = (BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or tostring(gold)) .. GOLD
        if not compact or gold < 100 then text = text .. " " .. silver .. SILVER end
        if not compact then text = text .. " " .. rest .. COPPER end
    elseif silver > 0 then
        text = silver .. SILVER .. " " .. rest .. COPPER
    else
        text = rest .. COPPER
    end
    if copper < 0 and value > 0 then text = "-" .. text end
    return text
end

local function Signed(copper, compact)
    if type(copper) ~= "number" then return "-" end
    local color = copper > 0.5 and "|cff40ff40+" or (copper < -0.5 and "|cffff5050" or "|cffffffff")
    return color .. Money(copper, compact) .. "|r"
end

local function Number(value)
    if value % 1 == 0 then return tostring(value) end
    return (string.format("%.2f", value):gsub("0+$", ""))
end

-- A return on materials as a multiple: "2.00x", "12.3x", "150x"; green from 1x up, red below.
local function Multiple(ratio)
    if type(ratio) ~= "number" then return "-" end
    local text
    if ratio < 10 then
        text = string.format("%.2fx", ratio)
    elseif ratio < 100 then
        text = string.format("%.1fx", ratio)
    else
        text = string.format("%dx", math.floor(ratio))
    end
    return (ratio >= 1 and "|cff40ff40" or "|cffff5050") .. text .. "|r"
end

-- The profit as a percentage of the material cost: a 2.00x return is +100%.
local function ProfitPercent(ratio)
    return string.format("%+.0f%%", (ratio - 1) * 100)
end

local function ItemName(itemID)
    local name = C_Item.GetItemNameByID(itemID)
    if name then return name end
    C_Item.RequestLoadItemDataByID(itemID)
    return "item " .. itemID
end

local function QualityColor(itemID)
    local quality = itemID and C_Item.GetItemQualityByID(itemID)
    if quality and C_Item.GetItemQualityColor then
        local r, g, b = C_Item.GetItemQualityColor(quality)
        if r then return r, g, b end
    end
    return 1, 0.82, 0
end

local function ItemIcon(itemID)
    return itemID and C_Item.GetItemIconByID(itemID) or QUESTION
end

local function RecipeTitle(recipeID)
    local outputID, quantity = reader.RecipeOutput(recipeID)
    local name = reader.RecipeName(recipeID) or (outputID and ItemName(outputID)) or ("recipe " .. recipeID)
    if quantity and quantity ~= 1 then name = name .. " x" .. Number(quantity) end
    return name, outputID, quantity
end

local function ProfessionName(skillLine)
    return skillLine and reader.ProfessionName(skillLine) or "Unknown profession"
end

-- A character's full name (with the surname once recorded), and its realm when that is not this one. The rows' short
-- summaries use first names only, for room.
local function CrafterLabel(crafter)
    if crafter.elsewhere and crafter.realm then return crafter.fullName .. " (" .. crafter.realm .. ")" end
    return crafter.fullName
end

-- Controls ----------------------------------------------------------------------------------------------------

-- Under the gamepad interface the client's gamepad frame manager takes any menu an addon opens into its focus under
-- that addon's taint (SkillUp Forever #398), so a click steps to the next choice instead of opening the menu. A menu
-- of checkboxes has no next choice, so it passes its own step.
local function GamepadSafe(dropdown, step)
    if not (DropdownButtonMixin and InputUtil and InputUtil.IsGamepadUIEnabled) then return end
    function dropdown:OpenMenu()
        if not InputUtil.IsGamepadUIEnabled() then return DropdownButtonMixin.OpenMenu(self) end
        if not self:IsEnabled() then return end
        if step then return step() end
        self:GenerateMenu()
        local _, nextRadio = self:CollectSelectionData()
        if nextRadio and MenuInputContext then self:Pick(nextRadio, MenuInputContext.MouseWheel) end
    end
end

local function Dropdown(parent, width, setup, step)
    local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dropdown:SetWidth(width)
    dropdown:SetupMenu(function(_, root)
        if root.SetScrollMode then root:SetScrollMode(20 * 20) end
        setup(root)
    end)
    GamepadSafe(dropdown, step)
    return dropdown
end

local function Radio(root, text, value, get, set)
    root:CreateRadio(text, function(data) return get() == data end, function(data) set(data) end, value)
end

local function Button(parent, text, width)
    local button = CreateFrame("Button", nil, parent, "SharedButtonSmallTemplate")
    button:SetSize(width, 22)
    button:SetText(text)
    return button
end

local function Edit(parent, width)
    local edit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    edit:SetSize(width, 20)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(255)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return edit
end

local function Text(parent, font, width)
    local text = parent:CreateFontString(nil, "ARTWORK", font)
    text:SetJustifyH("LEFT")
    if width then text:SetWidth(width) end
    return text
end

local function Crafters()
    local source = job or work
    return source and source.crafters or {}
end

-- The profession filter ------------------------------------------------------------------------------------------

-- The professions the compared characters have, by name.
local function ListedProfessions()
    local lines, seen = {}, {}
    for _, crafter in ipairs(Crafters()) do
        for skillLine in pairs(crafter.professions or crafter.observed or {}) do
            if not seen[skillLine] then
                seen[skillLine] = true
                lines[#lines + 1] = skillLine
            end
        end
    end
    table.sort(lines, function(a, b) return ProfessionName(a) < ProfessionName(b) end)
    return lines
end

-- How many listed professions are ticked, how many are listed, and the last ticked one.
local function ProfessionCounts()
    local lines, hidden = ListedProfessions(), Crafts.saved.hiddenProfessions
    local shown, last = 0, nil
    for _, skillLine in ipairs(lines) do
        if not hidden[skillLine] then shown, last = shown + 1, skillLine end
    end
    return shown, #lines, last
end

-- The closed dropdown's text: "All professions", the one ticked profession, "3 professions" or "No professions".
local function ProfessionsText()
    local shown, total, last = ProfessionCounts()
    if shown == total then return "All professions" end
    if shown == 0 then return "No professions" end
    if shown == 1 then return ProfessionName(last) end
    return shown .. " professions"
end

local function UpdateProfessionsText()
    local dropdown = dropdowns.profession
    if not dropdown then return end
    if dropdown.OverrideText then dropdown:OverrideText(ProfessionsText()) else dropdown:SetText(ProfessionsText()) end
end

-- After any change: redraw the list, relabel the dropdown, and keep an open menu open with its ticks redrawn.
local function ProfessionsChanged()
    viewAt = 0
    UpdateProfessionsText()
    return MenuResponse and MenuResponse.Refresh
end

local function ProfessionLabel(skillLine)
    local icon = PROFESSION_ICONS[skillLine]
    return (icon and ("|T" .. icon .. ":16|t ") or "") .. ProfessionName(skillLine)
end

-- Select all and Select none at the top, as in the game's own filter menus, then a checkbox per profession. The two
-- buttons grey out when they would change nothing.
local function ProfessionMenu(root)
    local hidden = Crafts.saved.hiddenProfessions
    local lines = ListedProfessions()
    local all = root:CreateButton("Select all", function()
        wipe(hidden)
        return ProfessionsChanged()
    end)
    local none = root:CreateButton("Select none", function()
        for _, skillLine in ipairs(lines) do hidden[skillLine] = true end
        return ProfessionsChanged()
    end)
    if all.SetEnabled then
        all:SetEnabled(function()
            local shown, total = ProfessionCounts()
            return shown < total
        end)
        none:SetEnabled(function() return (ProfessionCounts()) > 0 end)
    end
    root:CreateDivider()
    for _, skillLine in ipairs(lines) do
        root:CreateCheckbox(ProfessionLabel(skillLine), function(data) return not hidden[data] end, function(data)
            hidden[data] = not hidden[data] or nil
            return ProfessionsChanged()
        end, skillLine)
    end
end

-- The gamepad step: all professions, then each one alone in menu order, then all again.
local function StepProfessions()
    local lines, hidden = ListedProfessions(), Crafts.saved.hiddenProfessions
    if #lines == 0 then return end
    local shown, _, last = ProfessionCounts()
    local nextIndex = 1
    if shown == 1 then
        for index, skillLine in ipairs(lines) do
            if skillLine == last then nextIndex = index + 1 end
        end
    end
    wipe(hidden)
    if nextIndex <= #lines then
        for index, skillLine in ipairs(lines) do
            if index ~= nextIndex then hidden[skillLine] = true end
        end
    end
    ProfessionsChanged()
end

local function RefreshMenus()
    for _, dropdown in pairs(dropdowns) do
        if dropdown.GenerateMenu then dropdown:GenerateMenu() end
    end
    UpdateProfessionsText()
end

-- Wowhead links -------------------------------------------------------------------------------------------------

-- The game cannot open a browser for an addon (LaunchURL is restricted to Blizzard's code), so a Ctrl-click (Cmd-click on a Mac) shows the page's address selected, ready to
-- copy, in a small window over this one, as ForeverCore's profile link does. Ctrl+C closes it.
local WOWHEAD = "https://www.wowhead.com/forever/"
local LINK_WIDTH, LINK_HEIGHT = 440, 132
local linkWindow

local function LinkModifier()
    return IsControlKeyDown() or (IsMetaKeyDown ~= nil and IsMetaKeyDown())
end

local function ShowWowhead(kind, id, name, icon)
    if not linkWindow then
        local window = CreateFrame("Frame", nil, frame, "PortraitFrameTemplate")
        window:SetSize(LINK_WIDTH, LINK_HEIGHT)
        -- The main window is DIALOG too, and its own rows and panes sit at higher frame levels, so the same
        -- strata would draw the link under them. A stratum above keeps it on top; it is still this window's
        -- child, so it closes with it.
        window:SetFrameStrata("FULLSCREEN_DIALOG")
        if window.SetFixedFrameStrata then window:SetFixedFrameStrata(true) end
        window:SetToplevel(true)
        window:SetClampedToScreen(true)
        window:SetMovable(true)
        window:EnableMouse(true)
        window:RegisterForDrag("LeftButton")
        window:SetScript("OnDragStart", window.StartMoving)
        window:SetScript("OnDragStop", window.StopMovingOrSizing)
        window:SetTitle("Wowhead link")
        window.Name = Text(window, "GameFontNormal", LINK_WIDTH - 76 - 16)
        window.Name:SetPoint("TOPLEFT", 76, -32)
        window.Name:SetWordWrap(false)
        local hint = Text(window, "GameFontHighlightSmall", LINK_WIDTH - 76 - 16)
        hint:SetPoint("TOPLEFT", window.Name, "BOTTOMLEFT", 0, -4)
        hint:SetText("The link is selected. Press Ctrl+C (Cmd+C on a Mac), then paste it into a browser.")
        window.Edit = Edit(window, LINK_WIDTH - 40)
        window.Edit:SetPoint("BOTTOMLEFT", 22, 40)
        window.Edit:SetMaxLetters(0)
        -- Read only: a stray key puts the link back, still selected.
        window.Edit:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                self:SetText(window.url)
                self:HighlightText()
            end
        end)
        window.Edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        window.Edit:SetScript("OnEscapePressed", function() window:Hide() end)
        window.Edit:SetScript("OnEnterPressed", function() window:Hide() end)
        window.Edit:SetScript("OnKeyDown", function(_, key)
            if key == "C" and LinkModifier() then C_Timer.After(0.05, function() window:Hide() end) end
        end)
        local close = Button(window, "Close", 80)
        close:SetPoint("BOTTOMRIGHT", -12, 12)
        close:SetScript("OnClick", function() window:Hide() end)
        linkWindow = window
    end
    local window = linkWindow
    window.url = WOWHEAD .. kind .. "=" .. string.format("%d", id)
    window.Name:SetText(name or window.url)
    local portrait = window.GetPortrait and window:GetPortrait()
    if portrait then
        portrait:SetTexCoord(0, 1, 0, 1)
        portrait:SetTexture(icon or ICON)
        portrait:SetSize(62, 62)
    end
    window:ClearAllPoints()
    window:SetPoint("CENTER", frame, "CENTER")
    window:Show()
    window:Raise()
    window.Edit:SetText(window.url)
    window.Edit:SetFocus()
    window.Edit:HighlightText()
end

local function AddLinkHints(tooltip, chat)
    local add = GameTooltip_AddInstructionLine or function(tip, text) tip:AddLine(text, 0, 1, 0) end
    if chat then add(tooltip, "Shift-click to link it in chat.") end
    add(tooltip, "Ctrl-click for a Wowhead link.")
end

local function InsertItemLink(itemID)
    local _, link = C_Item.GetItemInfo(itemID)
    if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
end

-- A linked detail line: an item's own tooltip, or an NPC's or quest's name and place.
local function OnDetailEnter(line)
    local link = line.link
    if not link then return end
    line.Highlight:Show()
    GameTooltip:SetOwner(line, "ANCHOR_RIGHT")
    if link.kind == "item" then
        GameTooltip:SetItemByID(link.id)
    else
        GameTooltip:SetText(line.Left:GetText() or "", 1, 1, 1, 1, true)
        if link.where then GameTooltip:AddLine(link.where, 0.6, 0.6, 0.6, true) end
    end
    AddLinkHints(GameTooltip, link.kind == "item")
    GameTooltip:Show()
end

local function OnDetailLeave(line)
    line.Highlight:Hide()
    GameTooltip:Hide()
end

local function OnDetailClick(line, button)
    local link = line.link
    if not link or button ~= "LeftButton" then return end
    if LinkModifier() then
        local name, icon = line.Left:GetText(), nil
        if link.kind == "item" then
            name, icon = ItemName(link.id), ItemIcon(link.id)
        end
        ShowWowhead(link.kind, link.id, name, icon)
    elseif link.kind == "item" and IsModifiedClick and IsModifiedClick("CHATLINK") then
        InsertItemLink(link.id)
    end
end

-- Details ----------------------------------------------------------------------------------------------------

local STYLES = {
    title = {font = "GameFontNormalLarge", icon = 32, gap = 6},
    heading = {font = "GameFontNormal", gap = 4, top = 8, color = {1, 0.82, 0}},
    text = {font = "GameFontHighlightSmall", gap = 3},
    note = {font = "GameFontDisableSmall", gap = 5},
    pair = {font = "GameFontHighlightSmall", gap = 3, right = 130, color = {0.8, 0.8, 0.8}},
    item = {font = "GameFontHighlightSmall", icon = 16, gap = 4, right = 96},
    total = {font = "GameFontNormal", gap = 8, top = 4, right = 150},
    -- A recipe item's sources, indented under it: what and who, then where.
    source = {font = "GameFontHighlightSmall", gap = 1, indent = 22},
    place = {font = "GameFontDisableSmall", gap = 4, indent = 22},
}
local lines, cursor, used = {}, 0, 0

local function BeginDetails()
    cursor, used = -2, 0
end

local function AddDetail(style, left, right, icon, r, g, b)
    local s = STYLES[style]
    used = used + 1
    local line = lines[used]
    if not line then
        line = CreateFrame("Frame", nil, detailBody)
        line.Highlight = line:CreateTexture(nil, "BACKGROUND")
        line.Highlight:SetPoint("TOPLEFT", -2, 1)
        line.Highlight:SetPoint("BOTTOMRIGHT", 2, -1)
        line.Highlight:SetColorTexture(1, 1, 1, 0.08)
        line:SetScript("OnEnter", OnDetailEnter)
        line:SetScript("OnLeave", OnDetailLeave)
        line:SetScript("OnMouseUp", OnDetailClick)
        line.Icon = line:CreateTexture(nil, "ARTWORK")
        line.Left = Text(line, "GameFontHighlightSmall")
        line.Left:SetWordWrap(true)
        line.Right = Text(line, "GameFontHighlightSmall")
        line.Right:SetJustifyH("RIGHT")
        line.Right:SetPoint("TOPRIGHT")
        lines[used] = line
    end
    -- Pooled: a line is plain text until Linked says what it points at.
    line.link = nil
    line:EnableMouse(false)
    line.Highlight:Hide()
    cursor = cursor - (s.top or 0)
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", detailBody, "TOPLEFT", 0, cursor)
    line:SetWidth(DETAIL_WIDTH)
    local font = _G[s.font] or s.font
    line.Left:SetFontObject(font)
    line.Right:SetFontObject(font)
    local x = s.indent or 0
    if icon and s.icon then
        line.Icon:SetTexture(icon)
        line.Icon:SetSize(s.icon, s.icon)
        line.Icon:ClearAllPoints()
        line.Icon:SetPoint("TOPLEFT", x, 0)
        line.Icon:Show()
        x = x + s.icon + 6
    else
        line.Icon:Hide()
    end
    local rightWidth = right and (s.right or 110) or 0
    line.Left:ClearAllPoints()
    line.Left:SetPoint("TOPLEFT", x, 0)
    line.Left:SetWidth(DETAIL_WIDTH - x - rightWidth)
    line.Left:SetText(left or "")
    local color = s.color
    if r then
        line.Left:SetTextColor(r, g, b)
    elseif color then
        line.Left:SetTextColor(color[1], color[2], color[3])
    else
        line.Left:SetTextColor(1, 1, 1)
    end
    if right then
        line.Right:SetWidth(rightWidth)
        line.Right:SetText(right)
        line.Right:Show()
    else
        line.Right:SetText("")
        line.Right:Hide()
    end
    local height = math.max(line.Left:GetStringHeight(), right and line.Right:GetStringHeight() or 0,
        icon and s.icon or 0, 12)
    line:SetHeight(height)
    line:Show()
    cursor = cursor - height - s.gap
    return line
end

-- Points a detail line at a Wowhead page ("item", "npc" or "quest"): it highlights under the mouse, shows a
-- tooltip, and takes Ctrl-click (and Shift-click for an item).
local function Linked(line, kind, id, where)
    if not id then return end
    line.link = {kind = kind, id = id, where = where}
    line:EnableMouse(true)
end

local function FinishDetails()
    for index = used + 1, #lines do lines[index]:Hide() end
    if detailBody then detailBody:SetHeight(math.max(1, 8 - cursor)) end
end

local function FindRow(recipeID)
    for _, row in ipairs(view or {}) do
        if row.id == recipeID then return row end
    end
end

-- The recipe item and where it comes from, as SkillUp's catalogue has it (RecipeSources, when SkillUp has it): vendors this
-- character can deal with first, then quests, named drops with their chance, and world drops. Another faction's
-- vendor or quest is red, as in SkillUp's tooltips. Every line takes Ctrl-click for its Wowhead page.
local VENDORS_SHOWN = 3
local OTHER_SIDE = {1, 0.31, 0.31}

local function AddSource(text, entry, kind, id)
    local r, g, b = 1, 1, 1
    if entry.usable == false then r, g, b = OTHER_SIDE[1], OTHER_SIDE[2], OTHER_SIDE[3] end
    local line = AddDetail("source", text, nil, nil, r, g, b)
    Linked(line, kind, id, entry.zone)
    if entry.zone then AddDetail("place", entry.zone) end
end

local function RecipeItemDetails(recipeID, recipeItem)
    AddDetail("heading", "Recipe item")
    Linked(AddDetail("item", ItemName(recipeItem), nil, ItemIcon(recipeItem), QualityColor(recipeItem)), "item",
        recipeItem)
    local found, reason = reader.RecipeSources(recipeID)
    if not found then
        if reason == "unavailable" then
            AddDetail("place", "Ctrl-click the recipe item for its Wowhead page.")
        elseif reason == "loading" then
            AddDetail("place", "Looking up where it comes from...")
            -- The catalogue reads a profession over a few frames; draw again once it may have finished.
            redrawAt = redrawAt or GetTime() + 1
        else
            AddDetail("place", "Source not known. Ctrl-click the recipe item for its Wowhead page.")
        end
        return
    end
    for index, vendor in ipairs(found.vendors) do
        if index > VENDORS_SHOWN then
            AddDetail("place", "+" .. (#found.vendors - VENDORS_SHOWN) .. " more vendors")
            break
        end
        AddSource("Sold by " .. vendor.name, vendor, "npc", vendor.npcID)
    end
    for _, quest in ipairs(found.quests) do
        AddSource("Quest: " .. quest.title, quest, "quest", quest.questID)
    end
    for _, drop in ipairs(found.drops) do
        AddSource("Dropped by " .. drop.name .. " (" .. Number(drop.chance) .. "%)", drop, "npc", drop.npcID)
    end
    if found.world then AddDetail("source", "World drop") end
    if #found.vendors + #found.quests + #found.drops == 0 and not found.world then
        AddDetail("place", "Where it comes from is not known.")
    end
end

local function RenderDetails()
    if not detailBody then return end
    BeginDetails()
    local row = job and selected and FindRow(selected)
    if not row then
        if job then
            AddDetail("note", "Select a recipe to see its materials, sale assumptions and who can make it.")
        end
        FinishDetails()
        return
    end
    local recipeID = row.id
    local title, outputID, quantity = RecipeTitle(recipeID)
    Linked(AddDetail("title", title, nil, outputID and ItemIcon(outputID) or reader.RecipeIcon(recipeID) or QUESTION,
        QualityColor(outputID)), "item", outputID)
    if outputID then
        AddDetail("text", "Makes " .. Number(quantity) .. " x " .. ItemName(outputID)
            .. (quantity % 1 ~= 0 and " on average" or "") .. " per craft.")
    else
        AddDetail("text", "SkillUp's data has no product for this recipe, so it is not priced.")
    end

    local skillLine = reader.RecipeProfession(recipeID)
    local skill, source, recipeItem, fee = reader.RecipeRequirement(recipeID)
    AddDetail("pair", "Profession", ProfessionName(skillLine))
    local where = source == "trainer" and "trainer" or (source == "item" and "recipe item" or "source unknown")
    AddDetail("pair", "Required skill", (skill and tostring(skill) or "Unknown") .. " (" .. where .. ")")
    if source == "trainer" then
        local text = "Trainer"
        if type(fee) == "number" and fee > 0 then text = text .. "; fee " .. Money(fee) .. " not counted" end
        AddDetail("pair", "Recipe source", text)
    elseif source == "item" and not recipeItem then
        AddDetail("pair", "Recipe source", "Recipe item, not identified")
    elseif not recipeItem then
        AddDetail("pair", "Recipe source", "Unknown")
    end
    if recipeItem then RecipeItemDetails(recipeID, recipeItem) end

    AddDetail("heading", "Characters")
    for index, crafter in ipairs(job.crafters) do
        local state = tonumber(row.states:sub(index, index))
        if state and state > 0 then
            local entry = crafter.professions and crafter.professions[skillLine]
            local text = CrafterLabel(crafter) .. ": " .. Calc.STATE_LABEL[state]
            if state == Calc.KNOWN then
                text = text .. (crafter.current and " (learned)" or " (learned, as recorded)")
            elseif state == Calc.MEETS then
                text = text .. " (has " .. entry.base .. ")"
            elseif state == Calc.HIGHER then
                text = text .. " (has " .. entry.base .. ", needs " .. skill .. ")"
            elseif entry and not skill then
                text = text .. " (requirement unknown)"
            end
            local color = STATE_COLORS[state]
            AddDetail("text", text, nil, nil, color[1], color[2], color[3])
            AddDetail("note", Crafts:Freshness(crafter, skillLine))
        end
    end

    AddDetail("heading", "Materials per craft")
    for _, itemID, need in reader.Reagents(recipeID) do
        local unit, from = Calc.MaterialPrice(reader, cache, itemID)
        local left = Number(need) .. " x " .. ItemName(itemID)
        if unit then left = left .. "\n" .. Money(unit) .. " each, " .. from end
        Linked(AddDetail("item", left, unit and Money(unit * need) or "|cffff5050No price|r", ItemIcon(itemID)),
            "item", itemID)
    end
    AddDetail("pair", "Material cost", row.cost and Money(row.cost)
        or ("|cffff5050Unknown|r, " .. row.missing .. " without a price"))

    AddDetail("heading", "Sale (estimate)")
    if outputID then
        local unit, from, rate = Calc.SalePrice(reader, cache, outputID)
        AddDetail("pair", "Sale price each" .. (from and " (" .. from .. ")" or ""),
            unit and Money(unit) or "|cffff5050No price|r")
        AddDetail("pair", "Mean yield per craft", Number(quantity))
        if unit and rate > 0 then
            AddDetail("pair", "Auction house cut (" .. Number(rate) .. "%)", "-" .. Money(unit * quantity * rate / 100))
        end
        AddDetail("pair", "Est. sale proceeds", row.proceeds and Money(row.proceeds) or "Unknown")
    else
        AddDetail("text", Calc.ISSUE_TEXT[row.issue] or "No sale price")
    end
    local sell = outputID and reader.SellPrice(outputID)
    if sell and sell > 0 then AddDetail("pair", "A vendor would pay", Money(sell * quantity)) end
    AddDetail("total", "Estimated profit", row.profit and Signed(row.profit) or "Unknown")
    if row.ratio then
        AddDetail("pair", "Return on materials", Multiple(row.ratio) .. " (" .. ProfitPercent(row.ratio) .. ")")
    end
    AddDetail("note", DISCLOSURE)
    FinishDetails()
end

-- The list ------------------------------------------------------------------------------------------------------

local function Cell(row, x, width)
    local cell = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cell:SetPoint("RIGHT", row, "RIGHT", x, 0)
    cell:SetWidth((width or COLUMN) - 6)
    cell:SetJustifyH("RIGHT")
    cell:SetWordWrap(false)
    return cell
end

local function OnRowClick(row)
    if not row.recipeID then return end
    if LinkModifier() then
        if row.outputID then
            ShowWowhead("item", row.outputID, ItemName(row.outputID), ItemIcon(row.outputID))
        else
            ShowWowhead("spell", row.recipeID, RecipeTitle(row.recipeID), reader.RecipeIcon(row.recipeID))
        end
        return
    end
    if row.outputID and IsModifiedClick and IsModifiedClick("CHATLINK") then
        InsertItemLink(row.outputID)
        return
    end
    selected = row.recipeID
    list:ForEachFrame(function(other)
        if other.Selected then other.Selected:SetShown(other.recipeID == selected) end
    end)
    RenderDetails()
end

local function OnRowEnter(row)
    if not row.recipeID then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if row.outputID then
        GameTooltip:SetItemByID(row.outputID)
    else
        GameTooltip:SetSpellByID(row.recipeID)
    end
    AddLinkHints(GameTooltip, row.outputID ~= nil)
    GameTooltip:Show()
end

local function BuildRow(row)
    row:SetHeight(ROW_HEIGHT)
    row.Selected = row:CreateTexture(nil, "BACKGROUND")
    row.Selected:SetAllPoints()
    row.Selected:SetColorTexture(1, 0.82, 0, 0.14)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(32, 32)
    row.Icon:SetPoint("LEFT", 3, 0)
    row.Name = Text(row, "GameFontNormal", NAME_WIDTH)
    row.Name:SetPoint("TOPLEFT", row.Icon, "TOPRIGHT", 6, -1)
    row.Name:SetWordWrap(false)
    row.Detail = Text(row, "GameFontHighlightSmall", NAME_WIDTH)
    row.Detail:SetPoint("BOTTOMLEFT", row.Icon, "BOTTOMRIGHT", 6, 1)
    row.Detail:SetWordWrap(false)
    row.Detail:SetTextColor(0.6, 0.6, 0.6)
    row.Return = Cell(row, -6, RETURN_COLUMN)
    row.Profit = Cell(row, -6 - RETURN_COLUMN)
    row.Proceeds = Cell(row, -6 - RETURN_COLUMN - COLUMN)
    row.Cost = Cell(row, -6 - RETURN_COLUMN - 2 * COLUMN)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", OnRowClick)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
end

local function InitRow(row, data)
    if not row.Name then BuildRow(row) end
    local title, outputID = RecipeTitle(data.id)
    row.recipeID, row.outputID = data.id, outputID
    row.Icon:SetTexture(outputID and ItemIcon(outputID) or reader.RecipeIcon(data.id) or QUESTION)
    row.Name:SetText(title)
    row.Name:SetTextColor(QualityColor(outputID))
    local skill = reader.RecipeRequirement(data.id)
    row.Detail:SetText(ProfessionName(reader.RecipeProfession(data.id)) .. " " .. (skill or "?") .. "  ·  "
        .. Calc.CraftersText(job, data, filter and filter.crafter))
    row.Cost:SetText(data.cost and Money(data.cost, true)
        or (data.missing > 0 and ("|cff999999" .. data.missing .. " unpriced|r") or "-"))
    row.Proceeds:SetText(data.proceeds and Money(data.proceeds, true)
        or ("|cff999999" .. (Calc.ISSUE_TEXT[data.issue] or "-") .. "|r"))
    row.Profit:SetText(Signed(data.profit, true))
    row.Return:SetText(Multiple(data.ratio))
    row.Selected:SetShown(data.id == selected)
end

local function SetRows(rows)
    if list then
        list:SetDataProvider(CreateDataProvider(rows or {}), ScrollBoxConstants.RetainScrollPosition)
    end
end

-- The clickable column headings that sort the list. The one in use is white and underlined; the other is gold.
local sortHeadings = {}
local function UpdateSortHeadings()
    for _, button in ipairs(sortHeadings) do
        local active = button.sortKey == Crafts.saved.sort
        if active then button.Label:SetTextColor(1, 1, 1) else button.Label:SetTextColor(1, 0.82, 0) end
        button.Underline:SetShown(active)
    end
end

-- State ---------------------------------------------------------------------------------------------------------

local function UpdateStatus()
    if not status then return end
    if work and not job then
        local percent = work.total > 0 and math.floor(work.processed / work.total * 100) or 0
        status:SetText((paused and "Paused during combat: " or "Calculating: ") .. percent .. "%")
    elseif not job then
        status:SetText("")
    else
        -- A recalculation behind the shown results keeps their summary rather than swapping the whole line.
        local total, profitable, unpriced = Calc.Summary(view or {})
        status:SetText(string.format("%d recipes, %d profitable, %d without a full price. Not listed: %d no item, "
            .. "%d soulbound. Prices: %s.", total, profitable, unpriced, job.excluded.noitem, job.excluded.soulbound,
            job.pricing.label) .. (work and (paused and "  Paused during combat." or "  Updating...") or ""))
    end
end

local function ShowMessage(text)
    job, work, view = nil, nil, nil
    SetRows(nil)
    header:Hide()
    message:SetText(text)
    message:Show()
    BeginDetails()
    FinishDetails()
    UpdateStatus()
end

local function CurrentFilter()
    local settings, index = Crafts.saved, 0
    if settings.character ~= "all" then
        for i, crafter in ipairs(job.crafters) do
            if crafter.key == settings.character then index = i end
        end
    end
    return {crafter = index, hiddenProfessions = settings.hiddenProfessions, availability = settings.availability,
        search = searchText, profitableOnly = settings.profitableOnly, sort = settings.sort}
end

local function RebuildView()
    viewAt = nil
    if not job then return end
    filter = CurrentFilter()
    view = Calc.View(reader, job, filter)
    SetRows(view)
    if not FindRow(selected) then selected = view[1] and view[1].id or nil end
    if #view == 0 and ProfessionCounts() == 0 then
        message:SetText("No professions are selected.\n\nTick at least one in the profession filter, or choose "
            .. "Select all.")
        message:Show()
    elseif #view == 0 then
        message:SetText("Nothing matches these filters.\n\nThe default lists recipes a character knows or meets "
            .. "the skill requirement for. Choose Everything under availability to include recipes that need more "
            .. "skill or whose status is unknown.")
        message:Show()
    else
        message:Hide()
    end
    RenderDetails()
    UpdateStatus()
end

local function Start(resetPrices)
    restartAt = nil
    local state, text
    reader, state, text = Crafts:Dependencies()
    if state ~= "ok" then
        ShowMessage(text)
        return
    end
    local prices = Crafts:Pricing()
    local problem = prices:Problem()
    if problem then
        ShowMessage(problem)
        return
    end
    Crafts:UpdateCharacter()
    -- A cache only serves the pricing it was made for.
    if resetPrices or not cache or cache.pricing.key ~= prices.key or GetTime() - cache.created > CACHE_SECONDS then
        cache = Calc.NewCache(prices)
    end
    local crafters = Crafts:Crafters(reader)
    if #crafters == 0 then
        ShowMessage("No characters to compare yet.\n\nLog in on each character and open its professions once "
            .. "with SkillUp Forever enabled, so their recipes and skill are recorded.")
        return
    end
    work = Calc.NewJob(reader, cache, crafters)
    work.pricing = cache.pricing
    message:Hide()
    header:Show()
    RefreshMenus()
    UpdateStatus()
end

local function Finished()
    local done = work
    work = nil
    if done.error then
        report(done.error)
        ShowMessage("The calculation stopped with an error:\n\n" .. tostring(done.error))
        return
    end
    job = done
    RefreshMenus()
    RebuildView()
end

local function Redraw()
    if list and job then
        list:ForEachFrame(function(row, data) InitRow(row, data) end)
        RenderDetails()
    end
end

local function OnUpdate()
    local now = GetTime()
    if InCombatLockdown() then
        if work and not paused then
            paused = true
            UpdateStatus()
        end
        return
    end
    paused = false
    if restartAt and now >= restartAt then
        Start(false)
    elseif work then
        if Calc.Step(work, BUDGET_MS) then Finished() else UpdateStatus() end
    else
        if viewAt and now >= viewAt then RebuildView() end
        if redrawAt and now >= redrawAt then
            redrawAt = nil
            Redraw()
        end
    end
end

local function Release()
    job, work, view, cache, reader, filter = nil, nil, nil, nil, nil, nil
    restartAt, viewAt, redrawAt, paused = nil, nil, nil, false
    SetRows(nil)
    BeginDetails()
    FinishDetails()
    if pricing then pricing:Hide() end
end

-- Pricing -------------------------------------------------------------------------------------------------------

-- The panel shows what the pricing in effect uses: TSM's expressions and vendor option only while TSM is
-- installed, and which characters are compared either way.
local function LayoutPricing(tsmMode)
    local y = -4
    for _, row in ipairs(pricing.rows) do
        local control = row[1]
        local shown = tsmMode or not row.tsm
        control:SetShown(shown)
        if shown then
            control:ClearAllPoints()
            control:SetPoint("TOPLEFT", row.x or 0, y)
            y = y - (row[2] or (math.max(control:GetStringHeight() or 0, 28) + 10))
        end
    end
end

-- The Sale field shows the sale expression, or VendorSell (read-only) while Sell to a vendor is on.
local function ShowSaleField()
    local vendor = pricing.SaleVendor:GetChecked()
    pricing.Sale:SetText(vendor and Prices.VENDOR_SALE or pricing.saleText)
    pricing.Sale:SetEnabled(not vendor)
    pricing.Sale:SetTextColor(vendor and 0.5 or 1, vendor and 0.5 or 1, vendor and 0.5 or 1)
    pricing.Sale:ClearFocus()
end

-- Sell to a vendor applies at once: saved, recalculated, and the panel's text updated. Other unapplied edits stay.
local function ToggleSaleVendor()
    -- Turning it on keeps the expression being edited, to show again when it is turned off.
    if pricing.SaleVendor:GetChecked() then pricing.saleText = pricing.Sale:GetText():match("^%s*(.-)%s*$") end
    Crafts.saved.saleVendor = pricing.SaleVendor:GetChecked() and true or false
    ShowSaleField()
    local prices = Crafts:Pricing()
    pricing.Default:SetText(prices:Explain())
    LayoutPricing(true)
    Start(true)
end

local function LoadPricing()
    local settings, prices = Crafts.saved, Crafts:Pricing()
    local tsmMode = prices.mode == "tsm"
    pricing.mode = prices.mode
    pricing.Default:SetText(prices:Explain())
    if tsmMode then
        pricing.Material:SetText(prices.materialPrice)
        pricing.saleText = settings.salePrice ~= "" and settings.salePrice or select(2, Prices.DefaultExpressions())
        pricing.SaleVendor:SetChecked(settings.saleVendor)
        ShowSaleField()
        pricing.vendor = settings.vendorMaterials
        pricing.Vendor:GenerateMenu()
    end
    pricing.market = settings.market
    pricing.Market:GenerateMenu()
    pricing.Error:SetText("")
    pricing.Note:SetText(prices:Note())
    LayoutPricing(tsmMode)
end

local function ApplyPricing()
    local settings = Crafts.saved
    if pricing.mode == "tsm" then
        local material = pricing.Material:GetText():match("^%s*(.-)%s*$")
        local sale = pricing.SaleVendor:GetChecked() and pricing.saleText or pricing.Sale:GetText():match("^%s*(.-)%s*$")
        local problem = Prices.CheckExpression(material, "material")
        if problem then
            pricing.Error:SetText("Material price: " .. problem)
            return
        end
        problem = Prices.CheckExpression(sale, "sale")
        if problem then
            pricing.Error:SetText("Sale price: " .. problem)
            return
        end
        -- An expression equal to its current default is saved as "" so it keeps following the default.
        local defaultMaterial, defaultSale = Prices.DefaultExpressions()
        settings.materialPrice = material ~= defaultMaterial and material or ""
        settings.salePrice = sale ~= defaultSale and sale or ""
        settings.vendorMaterials = pricing.vendor
    end
    settings.market = pricing.market
    pricing:Hide()
    Start(true)
end

local function DefaultPricing()
    if pricing.mode == "tsm" then
        local material, sale = Prices.DefaultExpressions()
        pricing.Material:SetText(material)
        pricing.saleText = sale
        ShowSaleField()
        pricing.vendor = "cheaper"
        pricing.Vendor:GenerateMenu()
    end
    pricing.market = "local"
    pricing.Market:GenerateMenu()
end

local function BuildPricing(parent, details)
    pricing = CreateFrame("Frame", nil, parent)
    pricing:SetPoint("TOPLEFT", 10, -8)
    pricing:SetPoint("BOTTOMRIGHT", -10, 8)
    pricing:EnableMouse(true)
    pricing:Hide()
    -- The details scroll child sits a frame level above this panel and would draw over its background, so the
    -- details are hidden while the panel is open.
    pricing:SetScript("OnShow", function() details:Hide() end)
    pricing:SetScript("OnHide", function() details:Show() end)
    local background = pricing:CreateTexture(nil, "BACKGROUND")
    background:SetPoint("TOPLEFT", -6, 4)
    background:SetPoint("BOTTOMRIGHT", 6, -4)
    background:SetColorTexture(0.05, 0.05, 0.05, 0.96)
    local width = DETAILS_WIDTH - 32
    local function Label(text, font)
        local label = Text(pricing, font or "GameFontNormal", width)
        label:SetText(text)
        return label
    end
    local title = Label("Pricing", "GameFontNormalLarge")
    pricing.Default = Text(pricing, "GameFontHighlightSmall", width)
    pricing.Default:SetWordWrap(true)
    local materialLabel = Label("Material price (TSM expression)")
    pricing.Material = Edit(pricing, width - 8)
    local saleLabel = Label("Sale price (TSM expression)")
    pricing.Sale = Edit(pricing, width - 8)
    pricing.SaleVendor = CreateFrame("CheckButton", nil, pricing, "UICheckButtonTemplate")
    pricing.SaleVendor:SetSize(24, 24)
    pricing.SaleVendor:SetScript("OnClick", ToggleSaleVendor)
    local saleVendorLabel = Text(pricing.SaleVendor, "GameFontHighlightSmall")
    saleVendorLabel:SetPoint("LEFT", pricing.SaleVendor, "RIGHT", 2, 0)
    saleVendorLabel:SetText("Sell to a vendor (VendorSell). Applies at once.")
    local vendorLabel = Label("Vendor-sold materials")
    pricing.Vendor = Dropdown(pricing, width, function(root)
        for _, option in ipairs(Prices.VENDOR_OPTIONS) do
            Radio(root, option[2], option[1], function() return pricing.vendor end,
                function(value) pricing.vendor = value end)
        end
    end)
    local marketLabel = Label("Compare characters on")
    pricing.Market = Dropdown(pricing, width, function(root)
        for _, option in ipairs(Crafts.MARKET_OPTIONS) do
            Radio(root, option[2], option[1], function() return pricing.market end,
                function(value) pricing.market = value end)
        end
    end)
    local apply = Button(pricing, "Apply", 80)
    apply:SetScript("OnClick", ApplyPricing)
    local defaults = Button(pricing, "Defaults", 80)
    defaults:SetPoint("LEFT", apply, "RIGHT", 6, 0)
    defaults:SetScript("OnClick", DefaultPricing)
    local cancel = Button(pricing, "Cancel", 80)
    cancel:SetPoint("LEFT", defaults, "RIGHT", 6, 0)
    cancel:SetScript("OnClick", function() pricing:Hide() end)
    pricing.Error = Text(pricing, "GameFontHighlightSmall", width)
    pricing.Error:SetPoint("TOPLEFT", apply, "BOTTOMLEFT", 0, -8)
    pricing.Error:SetTextColor(1, 0.31, 0.31)
    pricing.Error:SetWordWrap(true)
    pricing.Note = Text(pricing, "GameFontDisableSmall", width)
    pricing.Note:SetPoint("TOPLEFT", pricing.Error, "BOTTOMLEFT", 0, -8)
    pricing.Note:SetWordWrap(true)
    -- Top to bottom: {control, height (nil: the text's own), x = indent, tsm = shown only while TSM prices}.
    pricing.rows = {
        {title, 28},
        {pricing.Default},
        {materialLabel, 18, tsm = true},
        {pricing.Material, 30, x = 6, tsm = true},
        {saleLabel, 18, tsm = true},
        {pricing.Sale, 26, x = 6, tsm = true},
        {pricing.SaleVendor, 28, tsm = true},
        {vendorLabel, 18, tsm = true},
        {pricing.Vendor, 34, tsm = true},
        {marketLabel, 18},
        {pricing.Market, 36},
        {apply, 30},
    }
end

-- The window ----------------------------------------------------------------------------------------------------

local function SavePosition(self)
    self:StopMovingOrSizing()
    local x, y = self:GetCenter()
    local px, py = UIParent:GetCenter()
    if x and px then Crafts.saved.window.x, Crafts.saved.window.y = x - px, y - py end
end

local function Create()
    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "PortraitFrameTemplate")
    table.insert(UISpecialFrames, FRAME_NAME)
    frame:SetSize(WIDTH, HEIGHT)
    local position = Crafts.saved.window
    frame:SetPoint("CENTER", UIParent, "CENTER", tonumber(position.x) or 0, tonumber(position.y) or 0)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", SavePosition)
    frame:SetTitle("Craft Opportunities")
    local portrait = frame.GetPortrait and frame:GetPortrait()
    if portrait then
        portrait:SetTexCoord(0, 1, 0, 1)
        portrait:SetTexture(ICON)
        portrait:SetSize(62, 62)
    end

    -- Filters, clear of the portrait that overhangs the top-left corner.
    dropdowns.character = Dropdown(frame, 160, function(root)
        local get = function() return Crafts.saved.character end
        local set = function(value) Crafts.saved.character, viewAt = value, 0 end
        Radio(root, "All characters", "all", get, set)
        for _, crafter in ipairs(Crafters()) do
            Radio(root, CrafterLabel(crafter), crafter.key, get, set)
        end
    end)
    dropdowns.character:SetPoint("TOPLEFT", 76, -32)
    if dropdowns.character.SetDefaultText then dropdowns.character:SetDefaultText("All characters") end
    dropdowns.profession = Dropdown(frame, 160, ProfessionMenu, StepProfessions)
    dropdowns.profession:SetPoint("LEFT", dropdowns.character, "RIGHT", 8, 0)
    UpdateProfessionsText()
    dropdowns.availability = Dropdown(frame, 220, function(root)
        local get = function() return Crafts.saved.availability end
        local set = function(value) Crafts.saved.availability, viewAt = value, 0 end
        for _, option in ipairs(Calc.AVAILABILITY) do Radio(root, option[2], option[1], get, set) end
    end)
    dropdowns.availability:SetPoint("LEFT", dropdowns.profession, "RIGHT", 8, 0)

    searchBox = Edit(frame, 150)
    searchBox:SetPoint("LEFT", dropdowns.availability, "RIGHT", 18, 0)
    local hint = Text(searchBox, "GameFontDisableSmall")
    hint:SetPoint("LEFT", 0, 0)
    hint:SetText("Search")
    searchBox:SetScript("OnTextChanged", function(self)
        searchText = (self:GetText() or ""):lower():match("^%s*(.-)%s*$")
        hint:SetShown(searchText == "" and not self:HasFocus())
        viewAt = GetTime() + 0.25
    end)
    searchBox:SetScript("OnEditFocusGained", function() hint:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function() hint:SetShown(searchText == "") end)

    profitable = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    profitable:SetSize(24, 24)
    profitable:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
    profitable:SetScript("OnClick", function(self)
        Crafts.saved.profitableOnly, viewAt = self:GetChecked() and true or false, 0
    end)
    local profitableLabel = Text(profitable, "GameFontNormalSmall")
    profitableLabel:SetPoint("LEFT", profitable, "RIGHT", 2, 0)
    profitableLabel:SetText("Profitable only")

    status = Text(frame, "GameFontHighlightSmall", 560)
    status:SetPoint("TOPLEFT", 78, -68)
    status:SetWordWrap(false)
    local refresh = Button(frame, "Refresh", 96)
    refresh:SetPoint("TOPRIGHT", -14, -62)
    refresh:SetScript("OnClick", function() Start(true) end)
    local pricingButton = Button(frame, "Pricing", 96)
    pricingButton:SetPoint("RIGHT", refresh, "LEFT", -6, 0)

    -- The list, its column headings and the message that stands in for it.
    local listInset = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    listInset:SetPoint("TOPLEFT", 10, -90)
    listInset:SetPoint("BOTTOMLEFT", 10, 10)
    listInset:SetWidth(LIST_WIDTH)
    header = CreateFrame("Frame", nil, listInset)
    header:SetPoint("TOPLEFT", 4, -4)
    header:SetPoint("TOPRIGHT", -SCROLL_BAR, -4)
    header:SetHeight(18)
    local recipeHeading = Text(header, "GameFontNormalSmall")
    recipeHeading:SetPoint("LEFT", 41, 0)
    recipeHeading:SetText("Recipe, profession and skill, characters")
    -- Right to left, matching the row cells: {title, width, sort, tooltip}.
    local columns = {
        {"Return", RETURN_COLUMN, "return", "Sort by return on materials: sale proceeds divided by material cost, "
            .. "highest first. 2.00x means the proceeds are twice what the materials cost, a profit of 100%."},
        {"Est. profit", COLUMN, "profit", "Sort by estimated profit: sale proceeds less material cost, highest first."},
        {"Est. proceeds", COLUMN},
        {"Materials", COLUMN},
    }
    local x = -6
    for _, column in ipairs(columns) do
        local title, width, sort, tip = column[1], column[2], column[3], column[4]
        local heading
        if sort then
            local button = CreateFrame("Button", nil, header)
            button:SetSize(width - 6, 18)
            button:SetPoint("RIGHT", x, 0)
            heading = Text(button, "GameFontNormalSmall", width - 6)
            heading:SetPoint("RIGHT", 0, 0)
            button.sortKey, button.Label = sort, heading
            button.Underline = button:CreateTexture(nil, "ARTWORK")
            button.Underline:SetColorTexture(1, 0.82, 0, 0.8)
            button.Underline:SetHeight(1)
            button.Underline:SetPoint("BOTTOMLEFT", 0, 0)
            button.Underline:SetPoint("BOTTOMRIGHT", 0, 0)
            button:SetScript("OnClick", function()
                Crafts.saved.sort, viewAt = sort, 0
                UpdateSortHeadings()
            end)
            button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(title, 1, 0.82, 0)
                GameTooltip:AddLine(tip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            button:SetScript("OnLeave", GameTooltip_Hide)
            sortHeadings[#sortHeadings + 1] = button
        else
            heading = Text(header, "GameFontNormalSmall", width - 6)
            heading:SetPoint("RIGHT", x, 0)
        end
        heading:SetJustifyH("RIGHT")
        heading:SetText(title)
        x = x - width
    end
    UpdateSortHeadings()
    list = CreateFrame("Frame", nil, listInset, "WowScrollBoxList")
    list:SetPoint("TOPLEFT", 4, -24)
    list:SetPoint("BOTTOMRIGHT", -SCROLL_BAR, 4)
    local bar = CreateFrame("EventFrame", nil, listInset, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", list, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 4, 0)
    bar:SetHideIfUnscrollable(true)
    local listView = CreateScrollBoxListLinearView()
    listView:SetElementExtentCalculator(function() return ROW_HEIGHT end)
    listView:SetElementFactory(function(factory) factory(ROW_TEMPLATE, InitRow) end)
    ScrollUtil.InitScrollBoxListWithScrollBar(list, bar, listView)
    message = Text(listInset, "GameFontNormal", LIST_WIDTH - 60)
    message:SetPoint("TOP", 0, -60)
    message:SetWordWrap(true)
    message:Hide()

    -- Details, and the pricing settings over them.
    local detailsInset = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
    detailsInset:SetPoint("TOPLEFT", listInset, "TOPRIGHT", 6, 0)
    detailsInset:SetPoint("BOTTOMRIGHT", -10, 10)
    local scroll = CreateFrame("ScrollFrame", nil, detailsInset, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -26, 8)
    detailBody = CreateFrame("Frame", nil, scroll)
    detailBody:SetSize(DETAIL_WIDTH, 1)
    scroll:SetScrollChild(detailBody)
    BuildPricing(detailsInset, scroll)
    pricingButton:SetScript("OnClick", function()
        if pricing:IsShown() then
            pricing:Hide()
        else
            -- Shown first, so the wrapped explanation has its height when the panel is laid out.
            pricing:Show()
            LoadPricing()
        end
    end)

    frame:SetScript("OnShow", function()
        profitable:SetChecked(Crafts.saved.profitableOnly)
        UpdateSortHeadings()
        Start(false)
    end)
    frame:SetScript("OnHide", Release)
    frame:SetScript("OnUpdate", OnUpdate)
    frame:Hide()
end

function Crafts:OpenWindow()
    if not self.saved then
        Crafts:Message("Craft Opportunities could not load its settings; reload the UI.")
        return
    end
    if not frame then Create() end
    if frame:IsShown() then
        frame:Raise()
    else
        frame:Show()
    end
end

-- Hooks from Crafts.lua --------------------------------------------------------------------------------------

function Crafts:DataChanged()
    if frame and frame:IsShown() then restartAt = GetTime() + 1 end
end

function Crafts:CombatChanged()
    if frame and frame:IsShown() then UpdateStatus() end
end

-- An output's binding arrived: price it again. Any other item's name arrived: redraw the rows on screen. A failed
-- load (an item the client's data lacks) changes nothing, so it neither restarts nor redraws.
function Crafts:ItemInfo(itemID, success)
    if not (frame and frame:IsShown()) or success == false then
        if cache then cache.pending[itemID] = nil end
        return
    end
    if cache and cache.pending[itemID] then
        cache.pending[itemID] = nil
        restartAt = restartAt or GetTime() + 2
    else
        redrawAt = GetTime() + 0.3
    end
end
