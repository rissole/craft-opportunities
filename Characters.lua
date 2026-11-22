local _, Crafts = ...

-- This account's characters, as Craft Opportunities records them itself: who each one is, its professions and their
-- base skill, and the recipes it knows. Records are keyed by the character's GUID. A name cannot be the key: WoW
-- Forever characters can share a first name and differ only by surname.
--
-- A character's learned recipes come only from that character, while it is logged in:
--   * its spellbook, read at login and whenever its skills or spells change, adds what it knows of each profession;
--   * a complete scan of one of its own profession windows replaces that profession's recipes;
--   * a recipe it learns (NEW_RECIPE_LEARNED) is added straight away.
-- A dropped profession takes its recipes with it. The spellbook is checked against SkillUp Forever's recipe lists
-- (SkillUp.lua), or without SkillUp against the recipes other characters have recorded (Client.lua).

-- A player GUID, "Player-<server>-<id>". Records saved before 3.0.0 were keyed "Name-Realm" and are dropped.
local GUID_PATTERN = "^Player%-"

-- Saved records ------------------------------------------------------------------------------------------------------

-- [GUID] = {name, surname, ruleset, faction, updated, professions = {[skillLine] = {base, scanned, name}},
--           known = {[recipeID] = the skill line it was recorded under}}
function Crafts:ValidateCharacters(saved)
    for key, record in pairs(saved.characters) do
        if type(key) ~= "string" or not key:find(GUID_PATTERN) or type(record) ~= "table"
            or type(record.name) ~= "string" or record.name == "" then
            saved.characters[key] = nil
        else
            -- Records before 3.3.2 held a realm name, which WoW Forever no longer has; the ruleset replaces it.
            record.realm = nil
            if record.ruleset ~= nil and type(record.ruleset) ~= "string" then record.ruleset = nil end
            if type(record.professions) ~= "table" then record.professions = {} end
            if type(record.known) ~= "table" then record.known = {} end
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
            for recipeID, skillLine in pairs(record.known) do
                if type(recipeID) ~= "number" or type(skillLine) ~= "number" then record.known[recipeID] = nil end
            end
        end
    end
    -- The character filter names a record by its key.
    if saved.character ~= "all" and not saved.characters[saved.character] then saved.character = "all" end
end

-- This character -----------------------------------------------------------------------------------------------------

-- This character's GUID (its record's key), first name, ruleset (Crafts.Ruleset) and English faction group. Nil while
-- the client has no GUID or name for it yet. WoW Forever has no realms: its auction houses are one per ruleset and
-- faction.
function Crafts.CurrentCharacter()
    local key, name = UnitGUID("player"), UnitName("player")
    if issecretvalue and (issecretvalue(key) or issecretvalue(name)) then return nil end
    if type(key) ~= "string" or not key:find(GUID_PATTERN) or type(name) ~= "string" or name == "" then
        return nil
    end
    return key, name, Crafts.Ruleset(), UnitFactionGroup("player")
end

local function IsSpellKnown(recipeID)
    local book = C_SpellBook and C_SpellBook.IsSpellKnown
    if book then return book(recipeID) == true end
    return IsPlayerSpell ~= nil and IsPlayerSpell(recipeID) == true
end

-- This character's professions now, a fresh array sorted by skill line: {skillLine, name, icon, base, max,
-- modifier}. Empty is also the client's answer early in login, so it never confirms a profession was dropped.
function Crafts.LiveProfessions()
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

-- This character's record, made on first use. Nil until the client knows who it is.
local function CurrentRecord(self)
    local key, name, ruleset, faction = Crafts.CurrentCharacter()
    if not (key and self.saved) then return nil, false end
    self.current = {key = key, ruleset = ruleset, faction = faction}
    local record, changed = self.saved.characters[key], false
    if not record then
        record = {professions = {}, known = {}}
        self.saved.characters[key] = record
        changed = true
    end
    if record.name ~= name or record.ruleset ~= ruleset or record.faction ~= faction then
        record.name, record.ruleset, record.faction, changed = name, ruleset, faction, true
    end
    local surname = Crafts.CurrentSurname()
    if surname and record.surname ~= surname then record.surname, changed = surname, true end
    return record, changed
end

-- Learned recipes ----------------------------------------------------------------------------------------------------

-- Removes the recipes recorded under one skill line.
local function Forget(record, skillLine)
    for recipeID, line in pairs(record.known) do
        if line == skillLine then record.known[recipeID] = nil end
    end
end

-- Adds what the spellbook knows of each of this character's professions. It only adds: early in login the spellbook
-- can still be empty, and a profession's recipes are removed only by a scan of its window or by dropping it.
local function ReadSpellbook(record, professions)
    local reader = Crafts:Source()
    if not reader then return false end
    local known, changed = record.known, false
    for _, profession in ipairs(professions) do
        for _, recipeID in ipairs(reader.ProfessionRecipes(profession.skillLine)) do
            if known[recipeID] == nil and IsSpellKnown(recipeID) then
                known[recipeID] = profession.skillLine
                changed = true
            end
        end
    end
    return changed
end

-- Records this character's name, ruleset, faction, surname, profession base levels and what its spellbook knows. A
-- profession the client no longer lists is dropped, with its recipes and scan time. An empty list is what the client
-- answers early in login, so it changes nothing. Returns true when something Craft Opportunities reads moved.
function Crafts:UpdateCharacter()
    local record, changed = CurrentRecord(self)
    if not record then return false end
    local professions = Crafts.LiveProfessions()
    if #professions == 0 then return changed end
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
            Forget(record, skillLine)
            changed = true
        end
    end
    if ReadSpellbook(record, professions) then changed = true end
    record.updated = GetServerTime()
    return changed
end

-- A recipe this character just learned, recorded under its profession when the character has it. Otherwise the next
-- scan or spellbook read finds it.
function Crafts:NoteLearned(recipeID)
    if type(recipeID) ~= "number" then return end
    local record = CurrentRecord(self)
    local reader = self:Source()
    local skillLine = reader and reader.RecipeProfession(recipeID)
    if record and skillLine and record.professions[skillLine] then record.known[recipeID] = skillLine end
end

-- One of this character's profession windows was completely read: `learned` is [recipeID] = true for each recipe the
-- window shows as learned. It replaces that profession's recorded recipes.
function Crafts:OnScan(skillLine, time, learned, base)
    local changed = self:UpdateCharacter()
    local record = self.current and self.saved.characters[self.current.key]
    if not record then return end
    local entry = record.professions[skillLine]
    if not entry then
        entry = {}
        record.professions[skillLine] = entry
        changed = true
    end
    if type(base) == "number" and entry.base ~= base then entry.base, changed = base, true end
    entry.scanned = time
    local known = record.known
    for recipeID, line in pairs(known) do
        if line == skillLine and not learned[recipeID] then
            known[recipeID] = nil
            changed = true
        end
    end
    for recipeID in pairs(learned) do
        if known[recipeID] ~= skillLine then
            known[recipeID] = skillLine
            changed = true
        end
    end
    if changed then self:DataChanged() end
end

-- Whether a compared character knows a recipe: as recorded, and for this character also its live spellbook.
function Crafts.Knows(crafter, recipeID)
    if crafter.known[recipeID] ~= nil then return true end
    return crafter.current == true and IsSpellKnown(recipeID)
end

-- Profession window scans ----------------------------------------------------------------------------------------

-- A completed scan is this character's own profession window, ready, with an answer for every recipe it lists. The
-- client can still be filling it a moment after its events, so a missing answer is retried up to MAX_ATTEMPTS times.
-- Linked, guild and NPC windows show someone else's recipes and are never recorded.
local generation, attempts, windowOpen, pending = 0, 0, false, false
local MAX_ATTEMPTS, RETRY_SECONDS, SETTLE_SECONDS = 10, 0.25, 0.5

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

-- The open window's profession among this character's: its live entry, nil while the client has no answer, or false
-- when it is not one of this character's.
local function OpenProfession()
    local base = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
    if not (base and base.professionID) then return nil end
    for _, profession in ipairs(Crafts.LiveProfessions()) do
        if profession.skillLine == base.professionID or profession.name == base.professionName then
            return profession
        end
    end
    return false
end

function Verify(token)
    if token ~= generation or not windowOpen or not Crafts.saved then return end
    local own = OwnWindow()
    if own == false then return end
    if own == nil or not C_TradeSkillUI.GetAllRecipeIDs then return Retry(token) end
    local profession = OpenProfession()
    if profession == nil then return Retry(token) end
    if not (profession and Crafts.CurrentCharacter()) then return end
    local recipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
    if type(recipeIDs) ~= "table" or #recipeIDs == 0 then return Retry(token) end
    local learned = {}
    for _, recipeID in ipairs(recipeIDs) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if not info then return Retry(token) end
        if info.learned == true then learned[recipeID] = true end
    end
    attempts = 0
    xpcall(function()
        Crafts:OnScan(profession.skillLine, GetServerTime(), learned, profession.base)
    end, geterrorhandler())
end

local function Schedule()
    generation = generation + 1
    attempts = 0
    local token = generation
    C_Timer.After(SETTLE_SECONDS, function() Verify(token) end)
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

-- Compared characters ------------------------------------------------------------------------------------------------

-- The characters to compare, as transient descriptors (rebuilt for each calculation, never saved):
-- {key, name (first name), fullName (with the surname once recorded), ruleset, faction, current, elsewhere, market
-- (for a character elsewhere, its ruleset when that differs, else its faction), professions ([skillLine] = {base,
-- scanned}) and known ([recipeID] = skillLine), both the saved tables themselves and read only, updated}. A character
-- with no recorded profession is not compared. Outside "all", only this ruleset and faction; a character whose
-- ruleset or faction was never recorded stays in.
function Crafts:Crafters()
    local saved, current = self.saved, self.current
    local crafters = {}
    for key, record in pairs(saved.characters) do
        local here = current ~= nil
            and (record.ruleset == nil or record.ruleset == current.ruleset)
            and (record.faction == nil or record.faction == current.faction)
        if next(record.professions) and (saved.market == "all" or here or not current) then
            local market
            if current ~= nil and not here then
                market = record.ruleset ~= current.ruleset and record.ruleset or record.faction
            end
            crafters[#crafters + 1] = {
                key = key,
                name = record.name,
                fullName = Crafts.FullName(record.name, record.surname),
                ruleset = record.ruleset,
                faction = record.faction,
                current = current ~= nil and key == current.key,
                elsewhere = current ~= nil and not here,
                market = market,
                professions = record.professions,
                known = record.known,
                updated = record.updated,
            }
        end
    end
    table.sort(crafters, function(a, b)
        if a.current ~= b.current then return a.current end
        if a.fullName ~= b.fullName then return a.fullName < b.fullName end
        if (a.ruleset or "") ~= (b.ruleset or "") then return (a.ruleset or "") < (b.ruleset or "") end
        return a.key < b.key
    end)
    return crafters
end

-- How current a character's knowledge of one profession is, in words.
function Crafts:Freshness(crafter, skillLine)
    local entry = crafter.professions[skillLine]
    if not entry then return "Profession not recorded." end
    local text
    if entry.scanned then
        text = "Recipes scanned " .. Crafts.Ago(entry.scanned) .. "."
    else
        text = "Recipes read from the spellbook; open the profession on " .. crafter.fullName .. " to confirm them."
    end
    if not crafter.current and crafter.updated then
        text = text .. " Skill recorded " .. Crafts.Ago(crafter.updated) .. "."
    end
    if crafter.elsewhere then
        text = text .. " Other ruleset or faction: priced at this character's market."
    end
    return text
end
