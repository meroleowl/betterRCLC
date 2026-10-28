-- pug.lua  Pug rolls: loot by plain /roll in raid chat, nobody else needs an addon (replaces RollFor).
-- Settings > General "Use as loot master" = Pug rolls. As master looter, corpse items at or above the loot threshold
-- go into the Pug loot window (/brc pug); bag items are added with /brc roll <link> or the Add button.
-- Rules: soft reserved item -> only its reservers roll (/roll 100, roll + SR+), one reserver wins outright.
-- Otherwise MS /roll 100 beats OS /roll 99; with the +1 rule, fewer MS wins this raid come first, then the roll.
-- Equal best rolls -> the tied players roll again. Raid roll = the loot master rolls 1-N over the roster.
-- Give = master loot from the open corpse (bag items go to the "To trade" list, lootBags.lua fills the trade).

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local UI = addon.UI

local P = {items = {}}
addon.Pug = P

local PLUS_RESET = 6 * 3600 -- +1 counts older than this are from another raid
local ORDER = {SR = 1, MS = 2, OS = 3}

------------------------------------------------------------------------
-- settings + saved +1 counts
------------------------------------------------------------------------
function P:Enabled() return addon.db.profile.usage and addon.db.profile.usage.state == "pug" end
function P:Timer() return addon.db.profile.pugTimer or 15 end
function P:PlusOne() return addon.db.profile.pugPlusOne end

function P:Plus()
	local p = addon.db.profile
	if p.pugPlusTime and time() - p.pugPlusTime > PLUS_RESET then p.pugPlus = nil end
	p.pugPlus = p.pugPlus or {}
	return p.pugPlus
end

function P:AddPlus(name)
	local t = self:Plus()
	t[name] = (t[name] or 0) + 1
	addon.db.profile.pugPlusTime = time()
end

function P:ResetPlus()
	addon.db.profile.pugPlus, addon.db.profile.pugPlusTime = {}, nil
	addon:Print("+1 counts reset.")
	self:Update()
end

------------------------------------------------------------------------
-- group + chat
------------------------------------------------------------------------
--- Group members in raid roster order (the raid roll maps 1-N onto it).
function P:Members()
	local out = {}
	local n = GetNumRaidMembers()
	if n > 0 then
		for i = 1, n do out[#out + 1] = (GetRaidRosterInfo(i)) end
	else
		out[1] = UnitName("player")
		for i = 1, GetNumPartyMembers() do out[#out + 1] = UnitName("party" .. i) end
	end
	return out
end

function P:IsMember(name)
	for _, n in ipairs(self:Members()) do if n == name then return true end end
end

function P:Say(msg, warning)
	local ch
	if GetNumRaidMembers() > 0 then
		ch = (warning and (IsRaidLeader() or IsRaidOfficer())) and "RAID_WARNING" or "RAID"
	elseif GetNumPartyMembers() > 0 then
		ch = "PARTY"
	end
	if ch then SendChatMessage(msg, ch) else addon:Print(msg) end -- alone (testing): only to me
end

------------------------------------------------------------------------
-- items
------------------------------------------------------------------------
function P:AddItem(link, corpse, boss)
	if addon:IsFilteredGear(link) then return nil end -- green or blue disenchantable gear stays off every loot list
	local list = addon.Rolls:SR(link)
	local it = {link = link, corpse = corpse, boss = boss, time = time(), rolls = {}, sr = list and #list > 0 and list or nil}
	tinsert(self.items, it)
	return it
end

--- Master loot window opened: add its items (at or above the loot threshold) that are not in the list yet.
function P:OnLootOpened()
	if not self:Enabled() then return end
	local method, partyML, raidML = GetLootMethod()
	if method ~= "master" then return end
	if not ((raidML and UnitIsUnit("raid" .. raidML, "player")) or partyML == 0) then return end
	local boss = UnitExists("target") and UnitIsDead("target") and UnitName("target") or "Loot"
	local have, added = {}, 0 -- corpse items already listed, per link (the same item can drop twice)
	for _, it in ipairs(self.items) do
		if it.corpse and not it.given then have[it.link] = (have[it.link] or 0) + 1 end
	end
	for slot = 1, GetNumLootItems() do -- in slot order
		local link = GetLootSlotLink(slot)
		local quality = select(4, GetLootSlotInfo(slot))
		if link and quality and quality >= GetLootThreshold() then
			if (have[link] or 0) > 0 then have[link] = have[link] - 1
			else local it = self:AddItem(link, true, boss) if it then added = added + 1 end end
		end
	end
	if added > 0 then
		self:Open()
		if not self.sel or self.sel.given then self:Select(self:NextItem()) end
	end
end

function P:NextItem()
	for _, it in ipairs(self.items) do if not it.given and not it.winner then return it end end
	return self.items[1]
end

--- /brc roll <link> and the Add button: an item from my bags.
function P:AddFromBags(text)
	local link = (text or ""):match("|c%x+|Hitem:.-|h%[.-%]|h|r")
	local id = tonumber((text or ""):match("^%s*(%d+)%s*$"))
	if not link and id then link = select(2, GetItemInfo(id)) end
	if not link then return addon:Print("That is not an item link or ID.") end
	local it = self:AddItem(link, false, "From bags")
	if not it then return addon:Print("That item is green or blue disenchantable gear and is kept off the loot list.") end
	self:Open()
	self:Select(it)
	return it
end

------------------------------------------------------------------------
-- rolling
------------------------------------------------------------------------
local function Has(list, v) for _, x in ipairs(list) do if x == v then return true end end end

--- Reservers of the item who are in the group now.
function P:Present(it)
	local out = {}
	for _, r in ipairs(it.sr or {}) do if self:IsMember(r.name) then out[#out + 1] = r end end
	return out
end

function P:Reservers(it)
	local out = {}
	for _, r in ipairs(it.sr or {}) do out[#out + 1] = r.name .. ((r.plus or 0) > 0 and (" +" .. r.plus) or "") end
	return table.concat(out, ", ")
end

local function SRPlus(it, name)
	for _, r in ipairs(it.sr or {}) do if r.name:lower() == name:lower() then return r.plus or 0 end end
end

--- mode: "sr" (reservers only), "open" (MS / OS for everyone), "tie" (names = the tied players), "raid"
function P:Start(it, mode, names)
	it = it or self.sel
	if not it or it.given then return end
	if self.cur then return addon:Print("A roll is already running.") end
	mode = mode or (it.sr and "sr" or "open")
	if mode == "sr" then
		local here = self:Present(it)
		if #here == 0 then -- reservers left the group: everyone may roll
			addon:Print("None of the reservers is in the group: rolling MS / OS for everyone.")
			mode = "open"
		elseif #here == 1 then -- one reserver: theirs without a roll
			it.winner, it.winKind, it.rolls, it.none = here[1].name, "SR", {}, nil
			self:Say(format("%s goes to %s (soft reserve).", it.link, it.winner))
			return self:Update()
		end
	end
	if mode ~= "tie" then it.rolls, it.winner, it.winKind, it.none = {}, nil, nil, nil end
	local cur = {item = it, mode = mode, names = names, ends = GetTime() + self:Timer(), warned = false, rolls = {}}
	if mode == "raid" then
		cur.members = self:Members()
		cur.ends = GetTime() + 10
		self.cur = cur
		self:Say(format("Raid roll for %s: rolling 1-%d.", it.link, #cur.members), true)
		RandomRoll(1, #cur.members)
		return self:Update()
	end
	self.cur = cur
	local t = self:Timer()
	if mode == "sr" then
		self:Say(format("Roll for %s, soft reserved by %s: /roll (%d s).", it.link, self:Reservers(it), t), true)
	elseif mode == "tie" then
		cur.max = names.max
		self:Say(format("Tie on %s: %s, /roll %d again (%d s).", it.link, table.concat(names, ", "), cur.max, t), true)
	else
		self:Say(format("Roll for %s: MS /roll, OS /roll 99 (%d s)%s.", it.link, t, self:PlusOne() and ", +1 rule" or ""), true)
	end
	self:Update()
end

--- A /roll line from system chat (anyone's).
function P:OnSystem(msg)
	local cur = self.cur
	if not cur then return end
	local name, roll, low, high = (msg or ""):match(addon.Rolls.Pattern())
	if not name then return end
	roll, low, high = tonumber(roll), tonumber(low), tonumber(high)
	if cur.mode == "raid" then
		if name == UnitName("player") and low == 1 and high == #cur.members then
			local it = cur.item
			self.cur = nil
			it.winner, it.winKind = cur.members[roll], "Raid roll"
			self:Say(format("Raid roll: %d = %s wins %s.", roll, it.winner or "?", it.link))
			self:Update()
		end
		return
	end
	local it = cur.item
	if cur.rolls[name] then return end -- only the first roll counts
	local row = {name = name, roll = roll, wins = self:Plus()[name] or 0}
	cur.rolls[name] = row
	if low ~= 1 then row.ign = "not 1-" .. high
	elseif not self:IsMember(name) then row.ign = "not in group"
	elseif cur.mode == "tie" then
		if not Has(cur.names, name) then row.ign = "not in the tie"
		elseif high ~= cur.max then row.ign = "wrong range"
		else row.kind = cur.names.kind row.score = roll end
	elseif cur.mode == "sr" then
		local plus = SRPlus(it, name)
		if not plus then row.ign = "no SR"
		elseif high ~= 100 then row.ign = "SR rolls /roll 100"
		else row.kind, row.score, row.plus = "SR", roll + plus, plus end
	else
		if high == 100 then row.kind = "MS" elseif high == 99 then row.kind = "OS" else row.ign = "1-" .. high .. "?" end
		row.score = roll
	end
	if cur.mode == "tie" then it.tieRolls = it.tieRolls or {} tinsert(it.tieRolls, row) else tinsert(it.rolls, row) end
	-- every reserver in the group rolled: no need to wait
	if cur.mode == "sr" and row.kind then
		local all = true
		for _, r in ipairs(self:Present(it)) do if not cur.rolls[r.name] then all = false end end
		if all then return self:Finish() end
	end
	self:Update()
end

--- Valid rows best first: SR > MS > OS; inside MS with the +1 rule fewer wins first; then the higher roll.
function P:Rank(rows, plusOne)
	local valid = {}
	for _, r in ipairs(rows) do if r.kind then valid[#valid + 1] = r end end
	table.sort(valid, function(a, b)
		if ORDER[a.kind] ~= ORDER[b.kind] then return ORDER[a.kind] < ORDER[b.kind] end
		if plusOne and a.kind == "MS" and a.wins ~= b.wins then return a.wins < b.wins end
		if a.score ~= b.score then return a.score > b.score end
		return a.name < b.name
	end)
	return valid
end

--- Best row and everyone tied with it.
function P:Best(rows, plusOne)
	local ranked = self:Rank(rows, plusOne)
	local top = ranked[1]
	if not top then return nil end
	local tied = {}
	for _, r in ipairs(ranked) do
		if r.kind == top.kind and r.score == top.score and not (plusOne and r.kind == "MS" and r.wins ~= top.wins) then
			tied[#tied + 1] = r
		end
	end
	return top, tied
end

function P:Finish()
	local cur = self.cur
	if not cur then return end
	self.cur = nil
	local it = cur.item
	if cur.mode == "raid" then
		addon:Print("The raid roll got no result; press Raid roll again.")
		return self:Update()
	end
	local plusOne = self:PlusOne() and cur.mode ~= "tie"
	local top, tied = self:Best(cur.mode == "tie" and (it.tieRolls or {}) or it.rolls, plusOne)
	if cur.mode == "tie" then it.tieRolls = nil end
	if not top then
		it.none = true
		self:Say(format(cur.mode == "tie" and "Nobody rerolled on %s." or "Nobody rolled on %s.", it.link))
		return self:Update()
	elseif #tied > 1 then
		local names = {kind = top.kind, max = top.kind == "OS" and 99 or 100}
		for _, r in ipairs(tied) do names[#names + 1] = r.name end
		self:Update()
		return self:Start(it, "tie", names)
	else
		it.winner, it.winKind = top.name, top.kind
	end
	local detail = top.kind == "SR" and (top.plus or 0) > 0 and format("%d+%d", top.roll, top.plus) or tostring(top.roll)
	self:Say(format("%s wins %s (%s, %s).", it.winner, it.link, it.winKind, detail))
	self:Update()
end

function P:Stop()
	if self.cur then self:Finish() end
end

function P:Cancel()
	local cur = self.cur
	if not cur then return end
	self.cur = nil
	self:Say(format("Roll on %s cancelled.", cur.item.link))
	self:Update()
end

--- Timer: 5 s warning, then the roll closes.
function P:Tick()
	local cur = self.cur
	if not cur then return end
	local left = cur.ends - GetTime()
	if left <= 0 then
		if cur.mode == "raid" then self.cur = nil addon:Print("No raid roll result seen.") return self:Update() end
		return self:Finish()
	end
	if left <= 5 and not cur.warned and cur.mode ~= "raid" and self:Timer() > 8 then
		cur.warned = true
		self:Say(format("5 s left to roll on %s.", cur.item.link))
	end
	if self.frame and self.frame:IsShown() then self.frame.bar:SetProgress(left / self:Timer(), left <= 5) end
end

------------------------------------------------------------------------
-- giving the item
------------------------------------------------------------------------
--- Gives the item to name. kind = "SR" / "MS" / "OS" / "Raid roll" / "Disenchant" / "Bank" / "Free". Returns true when done.
function P:Give(it, name, kind)
	if not it or not name or it.given then return end
	if it.corpse then
		local slot
		for s = 1, GetNumLootItems() do if GetLootSlotLink(s) == it.link then slot = s break end end
		if not slot then return addon:Print(format("Open the corpse with %s, then press Give again.", it.link)) end
		local idx
		for i = 1, 40 do if GetMasterLootCandidate(i) == name then idx = i break end end
		if not idx then return addon:Print(format("%s can't receive %s (not eligible, out of range or offline).", name, it.link)) end
		GiveMasterLoot(slot, idx) -- shortcut: a refused give (winner's bags full) still counts as given; check the corpse if unsure
	elseif name ~= UnitName("player") then
		tinsert(addon:ToTrade(), {link = it.link, winner = name, time = it.time})
		addon:Print(format("%s goes to %s: open a trade with them (it is in the Loot tab > To trade).", it.link, name))
	end
	it.given, it.givenKind = name, kind
	if kind == "MS" then self:AddPlus(name) end
	self:Log(it, name, kind)
	if self.sel == it then self:Select(self:NextItem()) end
	self:Update()
	return true
end

--- Loot history entry (local; pug raiders have no addon to send it to).
function P:Log(it, name, kind)
	local db = addon.lootDB and addon.lootDB.factionrealm
	if not db or addon.db.profile.enableHistory == false then return end
	local instance, _, _, diff = GetInstanceInfo()
	local award = kind == "Disenchant" or kind == "Bank" or kind == "Free"
	db[name] = db[name] or {}
	tinsert(db[name], {
		lootWon = it.link, date = date("%d/%m/%y"), time = date("%H:%M:%S"), instance = (instance or "") .. "-" .. (diff or ""),
		boss = it.boss, votes = 0, response = "Pug " .. kind, responseID = (kind == "MS" or kind == "SR") and 1 or kind == "OS" and 2 or 0,
		color = {1, 1, 1, 1}, class = select(2, UnitClass(name)), isAwardReason = award,
	})
end

------------------------------------------------------------------------
-- window
------------------------------------------------------------------------
function P:Open()
	self:Build()
	self.frame:Show()
	if not self.sel then self.sel = self:NextItem() end
	self:Update()
end

function P:Toggle()
	if self.frame and self.frame:IsShown() then self.frame:Hide() else self:Open() end
end

function P:Select(it)
	self.sel = it
	self:Update()
end

function P:Build()
	if self.frame then return self.frame end
	local f = UI:Window("pug", "Pug loot", 640, 430)
	local b = f.body

	local rail = CreateFrame("Frame", nil, b)
	rail:SetPoint("TOPLEFT", 6, -6)
	rail:SetPoint("BOTTOMLEFT", 6, 40)
	rail:SetWidth(210)
	UI:Panel(rail, "bg2", "border", 1)
	f.rail = UI:List(rail, 32, function(list)
		local r = CreateFrame("Button", nil, list)
		r:SetBackdrop({bgFile = UI.FLAT})
		r:SetBackdropColor(0, 0, 0, 0)
		r.icon = UI:Icon(r, 24)
		r.icon:SetPoint("LEFT", 6, 0)
		r.name = UI:Text(r, 12, "ink")
		r.name:SetPoint("TOPLEFT", 36, -3)
		r.name:SetWidth(166)
		r.sub = UI:Text(r, 10, "ink3")
		r.sub:SetPoint("BOTTOMLEFT", 36, 3)
		r.sub:SetWidth(166)
		r:SetScript("OnClick", function() if r.item then P:Select(r.item) end end)
		return r
	end, function(r, it) P:FillRail(r, it) end)
	f.rail:SetPoint("TOPLEFT", 1, -1)
	f.rail:SetPoint("BOTTOMRIGHT", -1, 1)
	f.add = UI:Button(b, "Add item", nil, 24, "default", function() StaticPopup_Show("BRC_PUG_ADD") end)
	f.add:SetPoint("BOTTOMLEFT", 6, 8)
	f.clear = UI:Button(b, "Clear done", nil, 24, "quiet", function()
		for i = #P.items, 1, -1 do if P.items[i].given then tremove(P.items, i) end end
		P:Select(P:NextItem())
	end)
	f.clear:SetPoint("LEFT", f.add, "RIGHT", 6, 0)

	local x = 228
	f.icon = UI:Icon(b, 36)
	f.icon:SetPoint("TOPLEFT", x, -10)
	f.name = UI:Text(b, 14, "ink")
	f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -2)
	f.name:SetWidth(380)
	f.sub = UI:Text(b, 12, "ink2")
	f.sub:SetPoint("BOTTOMLEFT", f.icon, "BOTTOMRIGHT", 10, 2)
	f.sub:SetWidth(380)
	f.bar = UI:Bar(b, 3)
	f.bar:SetPoint("TOPLEFT", x, -54)
	f.bar:SetPoint("RIGHT", b, "RIGHT", -10, 0)
	f.bar:SetProgress(0)

	f.roll = UI:Button(b, "Roll", nil, 24, "primary", function() P:Start() end)
	f.roll:SetPoint("TOPLEFT", x, -64)
	f.open = UI:Button(b, "Open to all", nil, 24, "default", function() P:Start(nil, "open") end)
	f.open:SetPoint("LEFT", f.roll, "RIGHT", 6, 0)
	f.raid = UI:Button(b, "Raid roll", nil, 24, "default", function() P:Start(nil, "raid") end)
	f.raid:SetPoint("LEFT", f.open, "RIGHT", 6, 0)
	f.stop = UI:Button(b, "Stop now", nil, 24, "default", function() P:Stop() end)
	f.stop:SetPoint("LEFT", f.raid, "RIGHT", 6, 0)
	f.cancel = UI:Button(b, "Cancel", nil, 24, "danger", function() P:Cancel() end)
	f.cancel:SetPoint("LEFT", f.stop, "RIGHT", 6, 0)

	local box = CreateFrame("Frame", nil, b)
	box:SetPoint("TOPLEFT", x - 6, -96)
	box:SetPoint("BOTTOMRIGHT", -6, 76)
	UI:Panel(box, "bg", "border", 1)
	f.list = UI:List(box, 22, function(list)
		local r = CreateFrame("Frame", nil, list)
		r.name = UI:Text(r, 12, "ink")
		r.name:SetPoint("LEFT", 10, 0)
		r.name:SetWidth(150)
		r.kind = UI:Text(r, 12, "ink2")
		r.kind:SetPoint("LEFT", 166, 0)
		r.roll = UI:Text(r, 12, "ink", "RIGHT")
		r.roll:SetPoint("LEFT", 200, 0)
		r.roll:SetWidth(50)
		r.note = UI:Text(r, 11, "ink3")
		r.note:SetPoint("LEFT", 264, 0)
		r.note:SetWidth(130)
		return r
	end, function(r, row) P:FillRoll(r, row) end)
	f.list:SetPoint("TOPLEFT", 1, -3)
	f.list:SetPoint("BOTTOMRIGHT", -1, 1)
	f.empty = UI:Text(box, 12, "ink3", "CENTER")
	f.empty:SetPoint("CENTER")

	f.winner = UI:Text(b, 13, "ink")
	f.winner:SetPoint("BOTTOMLEFT", x, 50)
	f.winner:SetWidth(170)
	f.give = UI:Button(b, "Give", nil, 24, "primary", function() local it = P.sel if it then P:Give(it, it.winner, it.winKind) end end)
	f.give:SetPoint("BOTTOMRIGHT", -10, 44)
	f.bank = UI:Button(b, "Bank", nil, 24, "default", function() P:Helper("banker", "Bank") end)
	f.bank:SetPoint("RIGHT", f.give, "LEFT", -6, 0)
	f.de = UI:Button(b, "Disenchant", nil, 24, "default", function() P:Helper("disenchanter", "Disenchant") end)
	f.de:SetPoint("RIGHT", f.bank, "LEFT", -6, 0)
	f.other = UI:Button(b, "Give to...", nil, 24, "quiet", function()
		local it = P.sel
		if it then UI:PickPlayer("Give " .. ((GetItemInfo(it.link)) or "item") .. " to", function(name) P:Give(it, name, "Free") end) end
	end)
	f.other:SetPoint("RIGHT", f.de, "LEFT", -6, 0)

	f.plus = UI:Check(b, "+1 rule (fewer MS wins first)", function(on) addon.db.profile.pugPlusOne = on P:Update() end)
	f.plus:SetPoint("BOTTOMLEFT", x, 12)
	f.reset = UI:Button(b, "Reset +1", nil, 22, "quiet", function() P:ResetPlus() end)
	f.reset:SetPoint("LEFT", f.plus, "RIGHT", 10, 0)
	f.sr = UI:Button(b, "Soft reserves...", nil, 22, "quiet", function() addon.Rolls:OpenImport() end)
	f.sr:SetPoint("BOTTOMRIGHT", -10, 10)
	self.frame = f
	return f
end

--- Disenchanter / bank from the loot master settings (picked once, kept in the profile).
function P:Helper(key, kind)
	local it = self.sel
	if not it then return end
	local name = addon.db.profile[key]
	if name and name ~= "" then return self:Give(it, name, kind) end
	UI:PickPlayer(kind .. ": who?", function(n) addon.db.profile[key] = n self:Give(it, n, kind) end)
end

function P:Status(it)
	if it.given then return "to " .. it.given .. " (" .. (it.givenKind or "") .. ")", "ink3" end
	if self.cur and self.cur.item == it then return self.cur.mode == "tie" and "tie reroll..." or "rolling...", "accent" end
	if it.winner then return it.winner .. " won (" .. it.winKind .. "), give it", "ok" end
	if it.none then return "nobody rolled", "warn" end
	if it.sr then return "SR: " .. self:Reservers(it), "accent" end
	return it.corpse and "on the corpse" or "in my bags", "ink3"
end

function P:FillRail(r, it)
	local p = UI:Palette()
	r.item = it
	r.icon:SetItem(it.link)
	local name, _, q = GetItemInfo(it.link)
	r.name:SetText(name or it.link)
	local qr, qg, qb = 1, 1, 1
	if q and GetItemQualityColor then qr, qg, qb = GetItemQualityColor(q) end
	UI:Recolor(r.name, it.given and "ink3" or {qr, qg, qb})
	local text, color = self:Status(it)
	r.sub:SetText(text)
	UI:Recolor(r.sub, color)
	if it == self.sel then r:SetBackdropColor(p.rowHover[1], p.rowHover[2], p.rowHover[3], 1) else r:SetBackdropColor(0, 0, 0, 0) end
end

function P:FillRoll(r, row)
	r.name:SetText(row.name)
	local _, class = UnitClass(row.name)
	UI:Recolor(r.name, row.ign and "ink3" or (class and UI:ClassColor(class)) or "ink")
	r.kind:SetText(row.kind or "")
	r.roll:SetText(row.plus and row.plus > 0 and format("%d+%d", row.roll, row.plus) or tostring(row.roll))
	UI:Recolor(r.roll, row.ign and "ink3" or row.best and "ok" or "ink")
	local note = row.ign or (self:PlusOne() and row.kind == "MS" and row.wins > 0 and ("+" .. row.wins .. " MS won")) or ""
	r.note:SetText(note)
end

function P:Update()
	local f = self.frame
	if not f or not f:IsShown() then return end
	f.rail:SetData(self.items)
	local open, given = 0, 0
	for _, it in ipairs(self.items) do if it.given then given = given + 1 else open = open + 1 end end
	f:SetTitle("Pug loot", format("%d to roll · %d given", open, given) .. (self:Enabled() and "" or " · pug mode is off (Settings > General)"))
	f.plus:SetChecked(self:PlusOne())
	local unknown = next(addon.Rolls:Store().items) and #addon.Rolls:Check().unknown or 0
	f.sr:SetLabel(unknown > 0 and format("Soft reserves (%d names not in group)", unknown) or "Soft reserves...")
	f.sr:SetTextTint(unknown > 0 and UI:Palette().bad or nil)
	local it = self.sel
	local all = {f.roll, f.open, f.raid, f.stop, f.cancel, f.give, f.de, f.bank, f.other}
	if not it then
		f.icon:SetItem(nil)
		f.name:SetText("No items")
		f.sub:SetText("Loot a boss as master looter, or add an item from your bags.")
		for _, w in ipairs(all) do w:Hide() end
		f.winner:SetText("")
		f.list:SetData({})
		f.empty:SetText("")
		return
	end
	f.icon:SetItem(it.link)
	f.name:SetText((GetItemInfo(it.link)) or it.link)
	local text = self:Status(it)
	f.sub:SetText((it.boss and (it.boss .. " · ") or "") .. text)
	local rolling = self.cur ~= nil
	local mine = rolling and self.cur.item == it
	for _, w in ipairs(all) do if it.given then w:Hide() else w:Show() end end
	f.winner:SetText(it.given and ("Given to " .. it.given) or "")
	if not it.given then
		f.roll:SetLabel(it.sr and "Roll SR" or "Roll MS / OS")
		if not it.sr then f.open:Hide() end
		for _, w in ipairs({f.roll, f.open, f.raid}) do if rolling then w:Disable() else w:Enable() end end
		if not mine then f.stop:Hide() f.cancel:Hide() end
		if it.winner and not mine then
			f.give:SetLabel("Give to " .. it.winner) f.give:Enable()
		else
			f.give:SetLabel("Give") f.give:Disable()
		end
	end
	if not mine then f.bar:SetProgress(0) end
	-- roll rows: valid ones ranked, then ignored ones
	local rows = mine and self.cur.mode == "tie" and (it.tieRolls or {}) or it.rolls
	local ranked = self:Rank(rows, self:PlusOne() and not (mine and self.cur.mode == "tie"))
	local data = {}
	for i, r in ipairs(ranked) do r.best = i == 1 data[#data + 1] = r end
	for _, r in ipairs(rows) do if r.ign then data[#data + 1] = r end end
	f.list:SetData(data)
	f.empty:SetText(#data > 0 and "" or (mine and "Waiting for /rolls..." or "No rolls yet."))
end

------------------------------------------------------------------------
-- events
------------------------------------------------------------------------
StaticPopupDialogs["BRC_PUG_ADD"] = {
	text = "Roll an item from your bags.\nShift-click it into this box or type its item ID:",
	button1 = ACCEPT, button2 = CANCEL, hasEditBox = 1, maxLetters = 300, timeout = 0, whileDead = 1, hideOnEscape = 1,
	OnAccept = function(self) P:AddFromBags(self.editBox:GetText()) end,
	EditBoxOnEnterPressed = function(self) P:AddFromBags(self:GetText()) self:GetParent():Hide() end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

-- Shift+click on an item pastes it into the box (the game only fills chat boxes by itself)
if hooksecurefunc then
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		local d = StaticPopup_FindVisible and StaticPopup_FindVisible("BRC_PUG_ADD")
		local box = d and _G[d:GetName() .. "EditBox"]
		if box and link then box:SetText(link) end
	end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("LOOT_OPENED")
ev:RegisterEvent("CHAT_MSG_SYSTEM")
ev:SetScript("OnEvent", function(_, event, msg)
	if not addon.db then return end
	if event == "LOOT_OPENED" then P:OnLootOpened() else P:OnSystem(msg) end
end)
ev:SetScript("OnUpdate", function() if P.cur then P:Tick() end end)
