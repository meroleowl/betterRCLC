-- rolls.lua  Answer rolls and soft reserves (the player picker is UI:PickPlayer in kit.lua).
--
-- Answer rolls: answering a card makes the game roll for you (BiS 1-100, OS 1-99, Upgrade 1-98; SR 1-100),
-- so the range itself shows the answer in raid chat. The server prints the roll in system chat; each client reads its
-- OWN roll there, pairs it with the oldest waiting answer of that range and sends "rollResult" to the council.
-- Soft reserves: the RollFor / softres.it export string (base64, zlib, JSON) or softres.it's CSV. The loot master's
-- client attaches the reservers to each item of a session; only they get a card (one Roll button), everyone else
-- passes silently. Hard reserved items get no cards at all.

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local UI = addon.UI

local R = {queue = {}}
addon.Rolls = R

------------------------------------------------------------------------
-- answer rolls
------------------------------------------------------------------------
function R.Pattern()
	local p = (RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"):gsub("%%s", "\001"):gsub("%%d", "\002")
	p = p:gsub("[%(%)%.%-%+%*%?%[%]%^%$%%]", "%%%0")
	return "^" .. p:gsub("\001", "(.+)"):gsub("\002", "(%%d+)") .. "$"
end

--- Rolls 1-max for an answered item; the result is sent when the server prints it.
function R:Roll(session, max)
	local now = GetTime()
	for i = #self.queue, 1, -1 do -- forget rolls the server never answered
		if now - self.queue[i].t > 30 then table.remove(self.queue, i) end
	end
	tinsert(self.queue, {session = session, max = max, t = now})
	RandomRoll(1, max)
end

--- System chat line -> my roll for the oldest waiting answer with that range. Returns session, value if used.
function R:OnSystem(msg)
	local name, roll, low, high = (msg or ""):match(self.Pattern())
	if not name or name ~= UnitName("player") or tonumber(low) ~= 1 then return end
	for i, q in ipairs(self.queue) do
		if q.max == tonumber(high) then
			table.remove(self.queue, i)
			addon:SendCommand("group", "rollResult", q.session, tonumber(roll))
			return q.session, tonumber(roll)
		end
	end
end

------------------------------------------------------------------------
-- soft reserves
------------------------------------------------------------------------
local function Short(name) return name and (name:gsub("%-.*$", "")) end

local function GroupNames()
	local out = {}
	local n = GetNumRaidMembers()
	if n > 0 then
		for i = 1, n do local name, _, _, _, _, class = GetRaidRosterInfo(i) if name then out[#out + 1] = {name = name, class = class} end end
	else
		out[1] = {name = UnitName("player"), class = select(2, UnitClass("player"))}
		for i = 1, GetNumPartyMembers() do out[#out + 1] = {name = UnitName("party" .. i), class = select(2, UnitClass("party" .. i))} end
	end
	return out
end

local function Key(s) return (s or ""):lower():gsub("#.*$", ""):gsub("[^%a]", "") end -- "Aleksa#1234" / "aleksa_" -> "aleksa"

local function Distance(a, b)
	if math.abs(#a - #b) > 2 then return 99 end
	local prev = {}
	for j = 0, #b do prev[j] = j end
	for i = 1, #a do
		local cur = {[0] = i}
		for j = 1, #b do
			cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a:sub(i, i) == b:sub(j, j) and 0 or 1))
		end
		prev = cur
	end
	return prev[#b]
end


--- {[itemId] = {{name, plus}, ...}}, {[itemId] = true} (hard reserves), number of players; or nil, error.
function R:ParseSR(text)
	text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return nil, "paste the soft reserve export" end
	local items, hr, players = {}, {}, {}
	local function add(id, name, plus)
		id = tonumber(id)
		name = Short(name)
		if not id or not name or name == "" then return end
		items[id] = items[id] or {}
		for _, r in ipairs(items[id]) do if r.name == name then return end end
		tinsert(items[id], {name = name, plus = tonumber(plus) or 0})
		players[name] = true
	end
	local header = text:match("^[^\n]*")
	if header:lower():find("itemid") and header:find(",") then -- softres.it CSV: Item,ItemId,From,Name,Class,Spec,Note,Plus,Date
		local cols = {}
		local i = 0
		for c in (header .. ","):gmatch("([^,]*),") do i = i + 1 cols[c:lower():gsub("[^%a]", "")] = i end
		if not cols.itemid or not cols.name then return nil, "CSV without ItemId / Name columns" end
		for line in text:gmatch("[^\r\n]+") do
			if line ~= header then
				local f, j = {}, 0
				for v in (line .. ","):gmatch('%s*"?([^,"]*)"?%s*,') do j = j + 1 f[j] = v end
				add(f[cols.itemid], f[cols.name], cols.plus and f[cols.plus])
			end
		end
	else -- RollFor / softres.it string: base64 of (zlib of) JSON
		local raw = addon.SimImport.Base64(text)
		if not raw or raw == "" then return nil, "not a soft reserve string" end
		local json = LibStub("LibDeflate"):DecompressZlib(raw) or raw
		local ok, data = pcall(function() return LibStub("Json-0.1.2").decode(json) end)
		if not ok or type(data) ~= "table" then return nil, "could not read the soft reserve data" end
		for _, sr in ipairs(data.softreserves or {}) do
			for _, it in ipairs(sr.items or {}) do add(it.id, sr.name, it.sr_plus) end
		end
		for _, it in ipairs(data.hardreserves or {}) do if it.id then hr[it.id] = true end end
	end
	local n = 0
	for _ in pairs(players) do n = n + 1 end
	if n == 0 and not next(hr) then return nil, "no reserves found" end
	return items, hr, n
end

function R:Store()
	local p = addon.db.profile
	p.softres = p.softres or {items = {}, hr = {}}
	return p.softres
end

function R:Import(text)
	local items, hr, n = self:ParseSR(text)
	if not items then return nil, hr end
	local s = self:Store()
	s.items, s.hr, s.players, s.time = items, hr, n, time()
	local count = 0
	for _ in pairs(items) do count = count + 1 end
	return n, count
end

function R:Clear()
	local s = self:Store()
	s.items, s.hr, s.players, s.time = {}, {}, 0, nil
end

--- Reservers of an item (list of {name, plus}) or nil; hard reserved = true as second value.
function R:SR(link)
	local id = type(link) == "number" and link or addon:GetItemIDFromLink(link)
	local s = self:Store()
	if not id then return nil end
	return s.items[id], s.hr[id] == true
end

function R:Summary()
	local s = self:Store()
	if not s.time then return "No soft reserves loaded." end
	local items = 0
	for _ in pairs(s.items) do items = items + 1 end
	return format("Soft reserves: %d players on %d items, imported %s.", s.players or 0, items, date("%d/%m %H:%M", s.time))
end

--- Preview rows of the loaded reserves: {id, names = "Aleksa +10, Thorvek", hr = bool}, by item name.
function R:PreviewRows()
	local st, rows = self:Store(), {}
	local here, grouped = {}, GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0
	for _, g in ipairs(GroupNames()) do here[g.name:lower()] = true end
	for id, list in pairs(st.items) do
		local names = {}
		for _, r in ipairs(list) do
			local n = (grouped and not here[r.name:lower()]) and ("|cffd9534f" .. r.name .. "|r") or r.name -- red: not in the group
			names[#names + 1] = n .. ((r.plus or 0) > 0 and (" |cffdca77f+" .. r.plus .. "|r") or "")
		end
		table.sort(names)
		rows[#rows + 1] = {id = id, names = table.concat(names, ", "), count = #list}
	end
	for id in pairs(st.hr) do rows[#rows + 1] = {id = id, names = "|cffd9534fHard reserved|r", hr = true} end
	local function name(r) return (GetItemInfo(r.id)) or ("item " .. r.id) end
	table.sort(rows, function(a, b)
		if (a.hr or false) ~= (b.hr or false) then return a.hr == true end
		return name(a) < name(b)
	end)
	return rows
end

------------------------------------------------------------------------
-- raid check: who has no reserve, and reserve names that match nobody in the group (Discord names, typos)
------------------------------------------------------------------------
--- Closest group member to a reserve name (only players without a reserve), or nil.
function R:Suggest(name, candidates)
	local k = Key(name)
	if k == "" then return nil end
	local best, bestD
	for _, c in ipairs(candidates) do
		local ck = Key(c.name)
		local d = (ck == k) and 0 or ((#k >= 3 and #ck >= 3) and (ck:find(k, 1, true) or k:find(ck, 1, true)) and 1) or Distance(k, ck)
		if d <= 2 and (not bestD or d < bestD) then best, bestD = c.name, d end
	end
	return best
end

--- {unknown = {{name, items, suggest}}, missing = {{name, class}}, ok = n}
function R:Check()
	local group, inGroup, reserved = GroupNames(), {}, {}
	for _, g in ipairs(group) do inGroup[g.name:lower()] = g.name end
	local items = {}
	for _, list in pairs(self:Store().items) do
		for _, r in ipairs(list) do
			reserved[r.name:lower()] = true
			items[r.name] = (items[r.name] or 0) + 1
		end
	end
	local out = {unknown = {}, missing = {}, ok = 0}
	for _, g in ipairs(group) do
		if reserved[g.name:lower()] then out.ok = out.ok + 1 else out.missing[#out.missing + 1] = g end
	end
	for name, n in pairs(items) do
		if not inGroup[name:lower()] then
			out.unknown[#out.unknown + 1] = {name = name, items = n, suggest = self:Suggest(name, out.missing)}
		end
	end
	table.sort(out.unknown, function(a, b) return a.name < b.name end)
	table.sort(out.missing, function(a, b) return a.name < b.name end)
	return out
end

--- Renames a reserver on every item (keeps the higher SR+ if the new name already reserved that item).
function R:Rename(old, new)
	if not new or new == "" or new == old then return end
	for _, list in pairs(self:Store().items) do
		local from, to
		for i, r in ipairs(list) do
			if r.name == old then from = i elseif r.name:lower() == new:lower() then to = r end
		end
		if from then
			if to then
				to.plus = math.max(to.plus or 0, list[from].plus or 0)
				table.remove(list, from)
			else
				list[from].name = new -- in place: items already in the pug window see it too
			end
		end
	end
	addon:Print(format("Soft reserves of %s now belong to %s.", old, new))
end

--- Raid chat line with everyone who has no reserve yet.
function R:AnnounceMissing()
	local names = {}
	for _, g in ipairs(self:Check().missing) do names[#names + 1] = g.name end
	if #names == 0 then return addon:Print("Everyone in the group has a soft reserve.") end
	local msg = "No soft reserve yet: " .. table.concat(names, ", ")
	local ch = GetNumRaidMembers() > 0 and "RAID" or GetNumPartyMembers() > 0 and "PARTY"
	if not ch then return addon:Print(msg) end
	while #msg > 0 do -- chat lines are capped at 255 characters
		SendChatMessage(msg:sub(1, 250), ch)
		msg = msg:sub(251)
	end
end

--- Rows of the Raid check tab: headers, unknown reserve names, players without a reserve.
function R:CheckRows()
	local c, rows = self:Check(), {}
	rows[#rows + 1] = {header = format("Reserve names not in the group (%d)", #c.unknown)}
	for _, u in ipairs(c.unknown) do rows[#rows + 1] = {unknown = u} end
	rows[#rows + 1] = {header = format("In the group without a reserve (%d)", #c.missing)}
	for _, m in ipairs(c.missing) do rows[#rows + 1] = {missing = m} end
	return rows, c
end

--- Import window: paste box on top, the loaded reserves below (item, who reserved it, SR+), like RollFor's list.
function R:OpenImport()
	local w = self.importWin
	if not w then
		w = UI:Window("srimport", "Soft reserves", 600, 520, "DIALOG")
		w.box = UI:Edit(w.body, 576, 70, true, "Paste the RollFor / softres.it export string, or softres.it's CSV")
		w.box:SetPoint("TOPLEFT", 12, -12)
		w.import = UI:Button(w.body, "Import", 90, 24, "primary", function()
			local n, items = R:Import(w.box:GetText())
			if n then
				addon:Print(format("Soft reserves imported: %d players, %d items.", n, items))
				local bad = #R:Check().unknown
				if bad > 0 and (GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0) then
					addon:Print(format("%d reserve name(s) match nobody in the group: see Raid check.", bad))
					R.tab = "check"
				end
				w.box:SetText("")
				R:RefreshImport()
			else
				w.status:SetText("|cffd9534f" .. tostring(items) .. "|r")
			end
		end)
		w.import:SetPoint("TOPRIGHT", -12, -90)
		w.clear = UI:Button(w.body, "Clear reserves", nil, 24, "quiet", function() R:Clear() R:RefreshImport() end)
		w.clear:SetPoint("RIGHT", w.import, "LEFT", -6, 0)
		w.status = UI:Text(w.body, 12, "ink2")
		w.status:SetPoint("TOPLEFT", 12, -95)
		w.status:SetWidth(330)
		w.tabs = UI:Segmented(w.body, {{"list", "Reserves"}, {"check", "Raid check"}}, function(k) R.tab = k R:RefreshImport() end, 22)
		w.tabs:SetPoint("TOPLEFT", 12, -122)
		w.announce = UI:Button(w.body, "Announce missing in raid", nil, 22, "default", function() R:AnnounceMissing() end)
		w.announce:SetPoint("TOPRIGHT", -12, -122)
		local box = CreateFrame("Frame", nil, w.body)
		box:SetPoint("TOPLEFT", 12, -150)
		box:SetPoint("BOTTOMRIGHT", -12, 12)
		UI:Panel(box, "bg2", "border", 1)
		w.check = UI:List(box, 28, function(list)
			local r = CreateFrame("Frame", nil, list)
			r.name = UI:Text(r, 12, "ink")
			r.name:SetPoint("LEFT", 10, 0)
			r.name:SetWidth(200)
			r.info = UI:Text(r, 12, "ink2")
			r.info:SetPoint("LEFT", 214, 0)
			r.info:SetWidth(150)
			r.edit = UI:Button(r, "Rename...", nil, 22, "default", function()
				local u = r.row and r.row.unknown
				if u then UI:PickPlayer("Reserves of " .. u.name .. " belong to", function(n) R:Rename(u.name, n) R:RefreshImport() end, nil, true) end
			end)
			r.edit:SetPoint("RIGHT", -8, 0)
			r.use = UI:Button(r, "", nil, 22, "primary", function()
				local u = r.row and r.row.unknown
				if u and u.suggest then R:Rename(u.name, u.suggest) R:RefreshImport() end
			end)
			r.use:SetPoint("RIGHT", r.edit, "LEFT", -6, 0)
			return r
		end, function(r, row) R:FillCheck(r, row) end)
		w.check:SetPoint("TOPLEFT", 1, -4)
		w.check:SetPoint("BOTTOMRIGHT", -1, 1)
		w.list = UI:List(box, 26, function(list)
			local r = CreateFrame("Frame", nil, list)
			r.icon = UI:Icon(r, 20)
			r.icon:SetPoint("LEFT", 8, 0)
			r.name = UI:Text(r, 12, "ink")
			r.name:SetPoint("LEFT", 34, 0)
			r.name:SetWidth(210)
			r.who = UI:Text(r, 12, "ink2")
			r.who:SetPoint("LEFT", 252, 0)
			r.who:SetPoint("RIGHT", r, "RIGHT", -8, 0)
			return r
		end, function(r, item)
			r.icon:SetItem(item.id)
			local name, _, quality = GetItemInfo(item.id)
			r.name:SetText(name or ("item " .. item.id))
			local qr, qg, qb = 1, 1, 1
			if quality and GetItemQualityColor then qr, qg, qb = GetItemQualityColor(quality) end
			UI:Recolor(r.name, {qr, qg, qb})
			r.who:SetText(item.names)
		end)
		w.list:SetPoint("TOPLEFT", 1, -4)
		w.list:SetPoint("BOTTOMRIGHT", -1, 1)
		w.empty = UI:Text(box, 12, "ink3", "CENTER")
		w.empty:SetPoint("CENTER")
		w.empty:SetText("No soft reserves loaded.")
		self.importWin = w
	end
	w.box:SetText("")
	w:Show()
	self:RefreshImport()
	w.box.edit:SetFocus()
end

function R:RefreshImport()
	local w = self.importWin
	if not w then return end
	local rows = self:PreviewRows()
	local check, c = self:CheckRows()
	local loaded = next(self:Store().items) ~= nil
	local bad = loaded and #c.unknown or 0
	w.status:SetText(self:Summary() .. (bad > 0 and format("  |cffd9534f%d name(s) not in the group.|r", bad) or ""))
	w.tabs.buttons[2]:SetLabel(format("Raid check: %d no SR, %d unknown", #c.missing, bad))
	w.tabs:Relayout()
	w.tabs:Select(self.tab or "list")
	if self.tab == "check" then
		w.list:Hide() w.check:Show() w.announce:Show()
		w.check:SetData(check)
		w.empty:Hide()
	else
		w.check:Hide() w.list:Show() w.announce:Hide()
		w.list:SetData(rows)
		w.empty:SetText("No soft reserves loaded.")
		if #rows == 0 then w.empty:Show() else w.empty:Hide() end
	end
end

function R:FillCheck(r, row)
	r.row = row
	r.use:Hide() r.edit:Hide()
	if row.header then
		r.name:SetText(row.header:upper()) UI:Recolor(r.name, "ink2")
		r.info:SetText("")
	elseif row.unknown then
		local u = row.unknown
		r.name:SetText(u.name) UI:Recolor(r.name, "bad")
		r.info:SetText(u.items .. (u.items == 1 and " item" or " items") .. (u.suggest and (", probably " .. u.suggest) or ""))
		r.edit:Show()
		if u.suggest then r.use:SetLabel("Use " .. u.suggest) r.use:Show() end
	else
		r.name:SetText(row.missing.name) UI:Recolor(r.name, UI:ClassColor(row.missing.class))
		r.info:SetText("no reserve")
	end
end

------------------------------------------------------------------------
-- my own rolls arrive in system chat
------------------------------------------------------------------------
local chat = CreateFrame("Frame")
chat:RegisterEvent("CHAT_MSG_SYSTEM")
chat:SetScript("OnEvent", function(_, _, msg) R:OnSystem(msg) end)
