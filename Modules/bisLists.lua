-- bisLists.lua  Guild BiS lists per spec (Discord-style text), synced from the Master Looter, and the player's MS/OS spec.
--
-- List format, one line per slot:   <slot name> <item id> [alt id] [=alt id] ...
--   first id = BiS, later ids = alternatives in order, "=" before an alt = counts as BiS (equal to it).
--   Lines starting with # or -- are comments. Item links are accepted in place of ids.
-- Storage (account wide): db.global.bis = {ver, specs = {["CLASS:Spec"] = text}} = my lists (editable),
--                         db.global.bisSynced = {from, ver, specs} = the lists last received from a Master Looter.

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local LibToken = LibStub("LibArmorToken-1.0")

local BIS = {}
addon.BIS = BIS

-- First three = talent trees in tree order; DK "Tank" and druid "Feral (Bear)" are extra and never auto-detected.
BIS.SPECS = {
	WARRIOR = {"Arms", "Fury", "Protection"},
	PALADIN = {"Holy", "Protection", "Retribution"},
	HUNTER = {"Beast Mastery", "Marksmanship", "Survival"},
	ROGUE = {"Assassination", "Combat", "Subtlety"},
	PRIEST = {"Discipline", "Holy", "Shadow"},
	DEATHKNIGHT = {"Blood", "Frost", "Unholy", "Tank"},
	SHAMAN = {"Elemental", "Enhancement", "Restoration"},
	MAGE = {"Arcane", "Fire", "Frost"},
	WARLOCK = {"Affliction", "Demonology", "Destruction"},
	DRUID = {"Balance", "Feral (Cat)", "Restoration", "Feral (Bear)"},
}
BIS.CLASS_ORDER = {"DEATHKNIGHT", "DRUID", "HUNTER", "MAGE", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR"}

local SLOTS = {
	helm = "Head", head = "Head", neck = "Neck", necklace = "Neck", amulet = "Neck",
	shoulder = "Shoulder", shoulders = "Shoulder", cape = "Back", cloak = "Back", back = "Back",
	chest = "Chest", wrist = "Wrist", wrists = "Wrist", bracer = "Wrist", bracers = "Wrist",
	hands = "Hands", hand = "Hands", gloves = "Hands", belt = "Waist", waist = "Waist",
	legs = "Legs", leg = "Legs", pants = "Legs", feet = "Feet", boots = "Feet",
	ring = "Finger", rings = "Finger", finger = "Finger", trinket = "Trinket", trinkets = "Trinket",
	mainhand = "Main Hand", mh = "Main Hand", weapon = "Main Hand", twohand = "Main Hand", twohanded = "Main Hand",
	["2h"] = "Main Hand", ["1h"] = "Main Hand", onehand = "Main Hand",
	offhand = "Off Hand", oh = "Off Hand", shield = "Off Hand",
	ranged = "Ranged", relic = "Ranged", idol = "Ranged", totem = "Ranged", libram = "Ranged", sigil = "Ranged",
	wand = "Ranged", thrown = "Ranged", gun = "Ranged", bow = "Ranged", crossbow = "Ranged",
}

function BIS:ClassName(class)
	return LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or class
end

function BIS:SpecName(key)
	return key and key:match(":(.+)$") or "-"
end

--- Parses one spec's list. Returns entries {slot, ids = {...}, eq = {[i] = true}} and a list of error strings.
function BIS:Parse(text)
	local entries, errors, n = {}, {}, 0
	for raw in (text or ""):gmatch("[^\r\n]+") do
		n = n + 1
		local line = raw:gsub("|c%x%x%x%x%x%x%x%x|Hitem:(%d+)[^|]*|h[^|]*|h|r", " %1 ")
		if line:match("%S") and not line:match("^%s*#") and not line:match("^%s*%-%-") then
			local words, ids, eq = {}, {}, {}
			for tok in line:gmatch("[^%s,;:]+") do
				local e, id = tok:match("^(=?)(%d%d%d+)$")
				if id then
					ids[#ids + 1] = tonumber(id)
					eq[#ids] = e == "=" or nil
				elseif #ids == 0 then
					words[#words + 1] = tok
				end
			end
			local key = (table.concat(words):lower():gsub("[%-_%.]", ""):gsub("%d+$", ""))
			local slot = SLOTS[key]
			if not slot then
				errors[#errors + 1] = format("line %d: unknown slot '%s'", n, table.concat(words, " "))
			elseif #ids == 0 then
				errors[#errors + 1] = format("line %d: no item id", n)
			else
				entries[#entries + 1] = {slot = slot, ids = ids, eq = eq}
			end
		end
	end
	return entries, errors
end

--- Entries back to list text (the inverse of Parse; slot names as Parse reads them back).
function BIS:Serialize(entries)
	local out = {}
	for _, e in ipairs(entries) do
		local ids = {}
		for i, id in ipairs(e.ids) do ids[#ids + 1] = (e.eq[i] and "=" or "") .. id end
		if #ids > 0 then out[#out + 1] = (e.slot == "Finger" and "Ring" or e.slot) .. " " .. table.concat(ids, " ") end
	end
	return table.concat(out, "\n")
end

-- entries keyed by slot and occurrence ("Finger#2" = the second ring line)
local function BySlot(entries)
	local t, n = {}, {}
	for _, e in ipairs(entries) do
		n[e.slot] = (n[e.slot] or 0) + 1
		t[e.slot .. "#" .. n[e.slot]] = e
	end
	return t
end

--- For each new entry: "new" (slot not on the list), "same" (same BiS) or "changed".
function BIS:Diff(currentText, newEntries)
	local cur, n, out = BySlot((self:Parse(currentText))), {}, {}
	for i, e in ipairs(newEntries) do
		n[e.slot] = (n[e.slot] or 0) + 1
		local c = cur[e.slot .. "#" .. n[e.slot]]
		out[i] = not c and "new" or (c.ids[1] == e.ids[1] and "same" or "changed")
	end
	return out
end

--- "Add as alternatives": keeps the current list and appends the new ids that are not on that slot line yet.
function BIS:MergeAlternatives(currentText, newEntries)
	local entries = self:Parse(currentText)
	local cur, n = BySlot(entries), {}
	for _, e in ipairs(newEntries) do
		n[e.slot] = (n[e.slot] or 0) + 1
		local c = cur[e.slot .. "#" .. n[e.slot]]
		if c then
			for _, id in ipairs(e.ids) do
				if not tContains(c.ids, id) then c.ids[#c.ids + 1] = id end
			end
		else
			entries[#entries + 1] = {slot = e.slot, ids = {unpack(e.ids)}, eq = {}}
		end
	end
	return self:Serialize(entries)
end

-- Is a better than b? BiS beats alt, then lower rank wins.
local function Better(a, b)
	if not b then return true end
	if a.bis ~= b.bis then return a.bis end
	return a.rank < b.rank
end

local cache = {} -- [text] = {[itemID] = {rank, bis, slot}}
local function Index(text)
	if not text then return nil end
	local idx = cache[text]
	if idx then return idx end
	idx = {}
	for _, e in ipairs((BIS:Parse(text))) do
		for i, id in ipairs(e.ids) do
			local new = {rank = i, bis = i == 1 or e.eq[i] == true, slot = e.slot}
			if Better(new, idx[id]) then idx[id] = new end
		end
	end
	cache[text] = idx
	return idx
end

function BIS:Own()
	local g = addon.db.global
	g.bis = g.bis or {ver = 0, specs = {}}
	return g.bis
end

function BIS:Synced()
	return addon.db.global.bisSynced
end

--- The lists in use: the Master Looter's (as received), unless we are the ML or never received any.
function BIS:Active()
	local s = self:Synced()
	if s and not addon.isMasterLooter and s.from ~= addon.playerName then return s end
	return self:Own()
end

--- The list text used for a spec. My own list by default; the loot master's (as received) fills specs I have no
-- list for, and replaces mine while that loot master forces their lists (mldb.forceBis) in their group. Nothing is
-- overwritten: leaving the group (no loot master) brings my own lists back by itself.
function BIS:ListText(key)
	if not key then return nil end
	local own = self:Own().specs[key]
	local s = self:Synced()
	local fromML = s and not addon.isMasterLooter and addon.masterLooter and s.from == addon.masterLooter
	if fromML and addon.mldb and addon.mldb.forceBis then return s.specs[key] end
	if own and own:match("%S") then return own end
	return s and s.from ~= addon.playerName and s.specs[key] or nil
end

--- Where an item stands on a spec's list: nil, or {rank = n, bis = bool, slot = "Head"}. Tokens match the pieces they buy.
function BIS:Status(specKey, item)
	if not specKey or not item then return nil end
	local id = type(item) == "number" and item or addon:GetItemIDFromLink(item)
	local idx = Index(self:ListText(specKey))
	if not idx or not id then return nil end
	local best = idx[id]
	if LibToken:ItemIsToken(id) then
		for _, piece in LibToken:IterateItemsForTokenAndClass(id, specKey:match("^(%u+):")) do
			if idx[piece] and Better(idx[piece], best) then best = idx[piece] end
		end
	end
	return best
end

--- The best list status of an item over a class's OTHER specs (raiders who never picked an off spec):
-- specKey, status or nil. Used to show "OS BiS · Feral (Cat)" for a Balance druid answering off spec.
function BIS:OtherSpecStatus(class, exceptSpec, item)
	local bestKey, best
	for _, name in ipairs(class and self.SPECS[class] or {}) do
		local key = class .. ":" .. name
		if key ~= exceptSpec then
			local st = self:Status(key, item)
			if st and Better(st, best) then bestKey, best = key, st end
		end
	end
	return bestKey, best
end

------------------------------------------------------------------------
-- Player specs
------------------------------------------------------------------------
local function TreeSpec(group)
	local best, bestPts = nil, 0
	for i = 1, 3 do
		local _, _, pts = GetTalentTabInfo(i, false, false, group) -- 3.3.5 returns name, icon, pointsSpent
		if pts and pts > bestPts then best, bestPts = i, pts end
	end
	return best and (addon.playerClass .. ":" .. BIS.SPECS[addon.playerClass][best]) or nil
end

--- My off specs: db.char.osSpecs = nil (auto: the other dual spec if it differs from the main spec) or a set
-- {["CLASS:Spec"] = true} (empty = no off spec: nothing is ever suggested as off spec). 0.4.4: several off specs;
-- the old single db.char.osSpec ("none" / a key) is moved over once.
local function OSSet()
	local c = addon.db.char
	if c.osSpec ~= nil and c.osSpecs == nil then
		c.osSpecs = c.osSpec == "none" and {} or {[c.osSpec] = true}
	end
	c.osSpec = nil
	return c.osSpecs
end

--- Returns msKey, osKey (first off spec, for older clients), osList (every off spec, may be empty).
-- Unset = taken from talents.
function BIS:MySpecs()
	local c = addon.db.char
	local active = GetActiveTalentGroup and GetActiveTalentGroup(false, false) or 1
	local ms = c.msSpec or TreeSpec(active)
	local list = {}
	local set = OSSet()
	if set == nil then
		local dual = TreeSpec(3 - active)
		if dual and dual ~= ms then list[1] = dual end
	else
		for _, name in ipairs(self.SPECS[addon.playerClass] or {}) do -- spec order, not hash order
			local key = addon.playerClass .. ":" .. name
			if set[key] and key ~= ms then list[#list + 1] = key end
		end
	end
	return ms, list[1], list
end

--- Off-spec picks for the settings and the menu: "auto", or the set.
function BIS:OSMode() local set = OSSet() return set == nil and "auto" or set end

--- Tick / untick one off spec ("auto" = back to talents, "none" = no off spec at all).
function BIS:SetOS(key, on)
	local c = addon.db.char
	if key == "auto" then c.osSpecs = nil
	elseif key == "none" then c.osSpecs = {}
	else
		c.osSpecs = OSSet() or {}
		c.osSpecs[key] = on and true or nil
	end
	self:SendMine()
end

--- Best list status of an item over several specs: specKey, status (or nil).
function BIS:BestStatus(keys, item)
	local bestKey, best
	for _, key in ipairs(keys or {}) do
		local st = self:Status(key, item)
		if st and Better(st, best) then bestKey, best = key, st end
	end
	return bestKey, best
end

--- "Feral (Bear), Restoration" (or "None").
function BIS:SpecNames(keys)
	local t = {}
	for _, k in ipairs(keys or {}) do t[#t + 1] = self:SpecName(k) end
	return #t > 0 and table.concat(t, ", ") or "None"
end

--- Tell the loot master my main / off specs, so the board knows them before my first answer. Sent when the loot
-- master's settings arrive (ML set, joining, /reload), when they ask ("specRequest"), and when my specs change.
-- Only sends again when something changed, unless force.
function BIS:SendMine(force)
	local ml = addon.masterLooter
	if not ml then return end
	local ms, os, oss = self:MySpecs()
	if addon:UnitIsUnit(ml, "player") then return self:ReceiveSpecs(addon.playerName, ms, os, oss) end
	local key = ml .. "|" .. (ms or "") .. "|" .. table.concat(oss, ",")
	if not force and self.sentSpecs == key then return end
	self.sentSpecs = key
	addon:SendCommand(ml, "mySpecs", ms, os, oss)
end

--- Loot master: a raider's specs arrived (or my own); the board and the Loot tab read them from the cache.
-- oss = every off spec (nil from older clients, which only send one).
function BIS:ReceiveSpecs(name, ms, os, oss)
	local g = addon.db.global
	g.specCache = g.specCache or {}
	g.specCache[name] = {ms, os, oss}
end

--- A candidate's off specs and whether they are final: list, known. known = false for older clients that never sent
-- a list (the board then still falls back to the class's other lists).
function BIS:CandidateOS(c, cache)
	if c.oss then return c.oss, true end
	if cache and cache[3] then return cache[3], true end
	local os = c.os or (cache and cache[2])
	return os and {os} or {}, false
end

local specEvents = CreateFrame("Frame")
specEvents:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED") -- dual spec switch: "Auto" specs change with it
specEvents:SetScript("OnEvent", function() if addon.db then BIS:SendMine() end end)

------------------------------------------------------------------------
-- Sync: the ML puts its list version in mldb; raiders with another version ask, the ML broadcasts once.
------------------------------------------------------------------------
function BIS:Touch()
	self:Own().ver = time()
	if addon.isMasterLooter then
		local ml = addon:GetActiveModule("masterlooter")
		if ml and ml.UpdateMLdb then ml:UpdateMLdb() end
	end
end

function BIS:CheckSync(mldb, ml)
	local ver = mldb and mldb.bisVer
	if not ver or ver == 0 or not ml or addon:UnitIsUnit(ml, "player") then return end
	local s = self:Synced()
	if s and s.from == ml and s.ver == ver then return end
	if self.lastRequest and GetTime() - self.lastRequest < 30 then return end
	self.lastRequest = GetTime()
	addon:SendCommand(ml, "bis_request")
end

function BIS:Receive(sender, ver, specs)
	if type(specs) ~= "table" then return end
	addon.db.global.bisSynced = {from = sender, ver = ver, specs = specs}
	addon:Print(format("Guild BiS lists received from %s.", sender))
end

function BIS:QueueBroadcast()
	if self.broadcastTimer then return end
	self.broadcastTimer = addon:ScheduleTimer(function()
		BIS.broadcastTimer = nil
		local own = BIS:Own()
		addon:SendCommand("group", "bisLists", own.ver, own.specs)
	end, 3) -- one broadcast for everyone who asks within 3 s
end

------------------------------------------------------------------------
-- Import / export of all specs:  "### Class - Spec" headers, each followed by its list.
------------------------------------------------------------------------
local function norm(s) return (s:lower():gsub("[^%a]", "")) end

function BIS:SpecFromName(text)
	local want = norm(text)
	for _, class in ipairs(self.CLASS_ORDER) do
		for _, name in ipairs(self.SPECS[class]) do
			if want == norm(self:ClassName(class) .. name) or want == norm(class .. name) then
				return class .. ":" .. name
			end
		end
	end
end

function BIS:ExportAll(store)
	local out = {}
	for _, class in ipairs(self.CLASS_ORDER) do
		for _, name in ipairs(self.SPECS[class]) do
			local text = store.specs[class .. ":" .. name]
			if text and text:match("%S") then
				out[#out + 1] = "### " .. self:ClassName(class) .. " - " .. name
				out[#out + 1] = (text:gsub("%s+$", ""))
				out[#out + 1] = ""
			end
		end
	end
	return table.concat(out, "\n")
end

--- Returns {[specKey] = text} for every header in the text, a list of errors (nothing is applied on error) and the
-- guild export extras {council = {{name}, ...}, blocked = {{name, reason}, ...}} from "### Council" / "### Block list".
function BIS:ImportAll(text)
	local result, errors, cur, buf, extras = {}, {}, nil, {}, {}
	local function flush()
		if cur and cur:sub(1, 1) == "@" then
			local list = {}
			for _, l in ipairs(buf) do
				local name, reason = l:match("^%s*(%S+)%s*(.-)%s*$")
				if name then list[#list + 1] = {name, reason} end
			end
			extras[cur:sub(2)] = list
		elseif cur then
			result[cur] = table.concat(buf, "\n")
			local _, errs = self:Parse(result[cur])
			for _, e in ipairs(errs) do errors[#errors + 1] = self:SpecName(cur) .. ", " .. e end
		end
		buf = {}
	end
	for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
		local head = line:match("^%s*###%s*(.-)%s*$")
		if head then
			flush()
			local special = ({council = "@council", blocklist = "@blocked"})[norm(head)]
			cur = special or self:SpecFromName(head) or false -- false = skip the lines under an unknown header
			if not cur then errors[#errors + 1] = "unknown spec header: " .. head end
		elseif cur then
			buf[#buf + 1] = line
		elseif cur == nil and line:match("%S") then
			errors[#errors + 1] = "text before the first ### header: " .. line
		end
	end
	flush()
	return result, errors, extras
end

--- One string for another officer: every list + "### Council" + "### Block list" (ImportAll reads it back).
function BIS:ExportGuild()
	local out = {self:ExportAll(self:Own())}
	local p = addon.db.profile
	if p.council and #p.council > 0 then out[#out + 1] = "### Council\n" .. table.concat(p.council, "\n") .. "\n" end
	local blocked = {}
	for name, reason in pairs(p.blocked or {}) do blocked[#blocked + 1] = name .. (reason ~= "" and (" " .. reason) or "") end
	table.sort(blocked)
	if #blocked > 0 then out[#out + 1] = "### Block list\n" .. table.concat(blocked, "\n") .. "\n" end
	return table.concat(out, "\n")
end

local LINK_SLOT = {
	INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder", INVTYPE_CLOAK = "Back", INVTYPE_CHEST = "Chest",
	INVTYPE_ROBE = "Chest", INVTYPE_WRIST = "Wrist", INVTYPE_HAND = "Hands", INVTYPE_WAIST = "Waist", INVTYPE_LEGS = "Legs",
	INVTYPE_FEET = "Feet", INVTYPE_FINGER = "Ring", INVTYPE_TRINKET = "Trinket", INVTYPE_WEAPON = "Main Hand",
	INVTYPE_2HWEAPON = "Main Hand", INVTYPE_WEAPONMAINHAND = "Main Hand", INVTYPE_WEAPONOFFHAND = "Off Hand",
	INVTYPE_SHIELD = "Off Hand", INVTYPE_HOLDABLE = "Off Hand", INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged",
	INVTYPE_THROWN = "Ranged", INVTYPE_RELIC = "Ranged",
}
--- Lines that are only item links (no slot name) get their slot from the item, so a pasted list of links parses.
-- Returns the text and the number of links whose slot is unknown (item not cached yet, or a token).
function BIS:SlotLinks(text)
	local unknown, out = 0, {}
	for raw in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
		local line = raw
		local bare = line:gsub("|c%x%x%x%x%x%x%x%x|Hitem:%d+[^|]*|h[^|]*|h|r", "")
		local id = tonumber(line:match("|Hitem:(%d+)"))
		if id and not bare:match("%a") then
			local slot = LINK_SLOT[select(9, GetItemInfo(id)) or ""]
			if slot then line = slot .. " " .. line else unknown = unknown + 1 end
		end
		out[#out + 1] = line
	end
	return table.concat(out, "\n"), unknown
end
