-- raidPanel.lua  Raid tab: every raider's gear, main / off specs, average item level and gear problems (missing
-- enchants, empty sockets, low durability). Nobody is inspected: each raider's own client reads its own equipment and
-- sends it over the addon channel ("myGear"), so it works at any range, shows the real item behind a transmog, and
-- only people running betterRCLC have data (the rest are listed greyed out). The panel asks the group ("gearRequest")
-- when it opens; people also send on login, group change, gear change and spec change (debounced).

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local UI = addon.UI
local RP = {roster = {}, filter = {issues = false}, sort = "ilvl"}
addon.RaidPanel = RP

-- wowsims order: left column, right column, weapons
local SLOTS = {1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18}
local ENCHANTABLE = {[1] = true, [3] = true, [15] = true, [5] = true, [9] = true, [10] = true, [7] = true, [8] = true, [16] = true}
local SORTS = {"ilvl", "class", "name"}
local ROW_H, ICON, STEP = 28, 20, 24
local DEBOUNCE, ASK_EVERY = 4, 60

------------------------------------------------------------------------
-- my own snapshot (sent to the group)
------------------------------------------------------------------------
--- "id:ench:g1:g2:g3:g4:suffix:..." -> the first 7 fields as strings ("0" for an empty one). Done with a find loop:
-- Lua 5.1's gmatch("[^:]*") returns an extra empty string after every field, which shifted enchants and gems.
local function Fields(s)
	local f, pos = {}, 1
	while #f < 7 do
		local stop = s:find(":", pos, true)
		local v = s:sub(pos, (stop or #s + 1) - 1)
		f[#f + 1] = v ~= "" and v or "0"
		if not stop then break end
		pos = stop + 1
	end
	while #f < 7 do f[#f + 1] = "0" end
	return f
end
RP.Fields = Fields

--- {class, ms, oss, gear = {[slot] = "id:ench:g1:g2:g3:g4:suffix"}, flag = {[slot] = "e"|"s"|"es"}, ilvl, dur, ver}
function RP:Snapshot()
	local gear, flag, sum, lowest = {}, {}, 0, 100
	local mh2h, hasOH
	for _, slot in ipairs(SLOTS) do
		local link = GetInventoryItemLink("player", slot)
		if link then
			local f = Fields(link:match("item:([^|]+)") or "")
			gear[slot] = table.concat(f, ":")
			local _, _, _, ilvl, _, _, _, _, loc = GetItemInfo(link)
			sum = sum + (ilvl or 0)
			if slot == 16 then mh2h = loc == "INVTYPE_2HWEAPON" and (ilvl or 0) end
			if slot == 17 then hasOH = true end
			local fl = ""
			if ENCHANTABLE[slot] and (tonumber(f[2]) or 0) == 0 then fl = fl .. "e" end
			-- sockets: what the bare item has minus the gems in the link (a blacksmith socket adds one: never negative)
			local base = GetItemStats and GetItemStats("item:" .. f[1])
			if base then
				local total, filled = 0, 0
				for k, v in pairs(base) do if k:find("^EMPTY_SOCKET_") then total = total + v end end
				for i = 3, 6 do if (tonumber(f[i]) or 0) > 0 then filled = filled + 1 end end
				if total > filled then fl = fl .. "s" end
			end
			if fl ~= "" then flag[slot] = fl end
		end
	end
	if mh2h and not hasOH then sum = sum + mh2h end -- a two-hander counts for both weapon slots
	for slot = 1, 18 do
		local cur, max
		if GetInventoryItemDurability then cur, max = GetInventoryItemDurability(slot) end
		if cur and max and max > 0 then lowest = math.min(lowest, math.floor(cur / max * 100)) end
	end
	local ms, _, oss = addon.BIS:MySpecs()
	return {class = addon.playerClass, ms = ms, oss = oss, gear = gear, flag = flag, ilvl = math.floor(sum / 17 * 10 + 0.5) / 10,
		dur = lowest, ver = addon.version}
end

--- /brc raid: what this client has seen (to find out why a row stays empty).
function RP:Diag()
	local n = 0
	for _ in pairs(self.roster) do n = n + 1 end
	addon:Print(format("Raid tab: %d row(s) with data, %d gear message(s) received (last: %s), %d request(s) answered, %d sent. In group: %s.",
		n, self.seen or 0, self.lastWhy or "none yet", self.asks or 0, self.sent or 0, tostring(addon:InAnyGroup() and true or false)))
end

function RP:SendMine(target)
	local snap = self:Snapshot()
	self:Receive(addon.playerName, snap)
	if not addon:InAnyGroup() then return end
	self.sent = (self.sent or 0) + 1
	if target then addon:SendCommand(target, "myGear", snap) else addon:SendCommand("group", "myGear", snap) end
end

local function Key(s)
	local t = {s.ms or "", table.concat(s.oss or {}, ","), s.ilvl, s.dur}
	for _, slot in ipairs(SLOTS) do t[#t + 1] = s.gear[slot] or "" end
	return table.concat(t, "|")
end

--- Send soon (debounced); skipped when nothing changed since the last send, unless force.
function RP:Queue(force)
	self.due = GetTime() + DEBOUNCE
	self.force = self.force or force
end

local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function()
	if RP.due and GetTime() >= RP.due and addon.db then
		RP.due = nil
		local force = RP.force
		RP.force = nil
		local key = Key(RP:Snapshot())
		if force or key ~= RP.lastKey then
			RP.lastKey = key
			RP:SendMine()
		end
	end
end)
ticker:RegisterEvent("PLAYER_ENTERING_WORLD")
ticker:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ticker:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
ticker:RegisterEvent("PARTY_MEMBERS_CHANGED") -- 3.3.5 name
ticker:RegisterEvent("RAID_ROSTER_UPDATE")
ticker:SetScript("OnEvent", function(_, event)
	if not addon.db then return end
	if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
		local grouped = addon:InAnyGroup() and true or false
		if grouped == RP.wasGrouped then return end -- only when I join / leave, not on every roster tick
		RP.wasGrouped = grouped
		if not grouped then return end
		RP:Queue(true)
	else
		RP:Queue(event == "PLAYER_ENTERING_WORLD")
	end
end)

------------------------------------------------------------------------
-- comms
------------------------------------------------------------------------
--- Is this name in my group? Walks the roster tokens instead of asking UnitInRaid / UnitInParty with a name (those
-- depend on the client resolving the name, which did not work for the second account in the first live test).
local function InGroup(name)
	if name == addon.playerName then return true end
	for i = 1, GetNumRaidMembers() do if UnitName("raid" .. i) == name then return true end end
	for i = 1, GetNumPartyMembers() do if UnitName("party" .. i) == name then return true end end
	return false
end
RP.InGroup = InGroup

local function CleanGear(t)
	local out = {}
	for slot, s in pairs(type(t) == "table" and t or {}) do
		if type(slot) == "number" and type(s) == "string" and #s < 60 and s:match("^[%d:%-]+$") then out[slot] = s end
	end
	return out
end

--- A raider's snapshot arrived (or mine). Unknown or malformed data is dropped.
function RP:Receive(sender, d)
	self.seen = (self.seen or 0) + 1
	if type(d) ~= "table" or type(sender) ~= "string" then self.lastWhy = "malformed from " .. tostring(sender) return end
	local name = sender:gsub("%-.*", "")
	if not InGroup(name) then self.lastWhy = name .. " is not in my group (raid " .. GetNumRaidMembers() .. ", party " .. GetNumPartyMembers() .. ")" return end
	self.lastWhy = "ok from " .. name
	local flag = {}
	for slot, v in pairs(type(d.flag) == "table" and d.flag or {}) do
		if type(slot) == "number" and (v == "e" or v == "s" or v == "es") then flag[slot] = v end
	end
	local oss = {}
	for _, k in ipairs(type(d.oss) == "table" and d.oss or {}) do if type(k) == "string" then oss[#oss + 1] = k end end
	self.roster[name] = {class = type(d.class) == "string" and d.class or nil, ms = type(d.ms) == "string" and d.ms or nil, oss = oss,
		gear = CleanGear(d.gear), flag = flag, ilvl = tonumber(d.ilvl) or 0, dur = tonumber(d.dur), ver = d.ver, ts = time()}
	if self.frame and self.frame:IsVisible() then self:Update() end
end

--- A group member asks for everyone's gear: answer them directly, a little later so 25 replies don't arrive at once.
function RP:Reply(sender)
	self.asks = (self.asks or 0) + 1
	if not InGroup((sender:gsub("%-.*", ""))) or sender == addon.playerName then return end
	addon:ScheduleTimer(function() RP:SendMine(sender) end, math.random() * 3)
end

function RP:Ask(force)
	if not addon:InAnyGroup() then return end
	if not force and self.asked and GetTime() - self.asked < ASK_EVERY then return end
	self.asked = GetTime()
	addon:SendCommand("group", "gearRequest")
end

------------------------------------------------------------------------
-- the roster the panel lists (group members, with or without data)
------------------------------------------------------------------------
function RP:Members()
	local out = {}
	local function add(name, class)
		if not name then return end
		out[#out + 1] = {name = name, class = class, d = self.roster[name]}
	end
	if GetNumRaidMembers and GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers() do
			local name, _, _, _, _, class = GetRaidRosterInfo(i)
			add(name and name:gsub("%-.*", ""), class)
		end
	elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
		add(addon.playerName, addon.playerClass)
		for i = 1, GetNumPartyMembers() do
			local _, class = UnitClass("party" .. i)
			add(UnitName("party" .. i), class)
		end
	else
		add(addon.playerName, addon.playerClass)
	end
	for _, m in ipairs(out) do m.class = (m.d and m.d.class) or m.class end
	return out
end

--- 1 / 0 / -1 for "0.5.5" vs "0.5.4" style versions (missing = oldest).
local function CmpVer(a, b)
	local function parts(v) local t = {} for n in tostring(v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end return t end
	local x, y = parts(a), parts(b)
	for i = 1, math.max(#x, #y) do
		local p, q = x[i] or 0, y[i] or 0
		if p ~= q then return p > q and 1 or -1 end
	end
	return 0
end
RP.CmpVer = CmpVer

--- The newest addon version seen in the group (mine included): what "up to date" means here.
function RP:Newest()
	local best = addon.version
	for _, d in pairs(self.roster) do if d.ver and CmpVer(d.ver, best) > 0 then best = d.ver end end
	return best
end

local function Issues(d)
	local e, s = 0, 0
	for _, v in pairs(d.flag) do
		if v:find("e") then e = e + 1 end
		if v:find("s") then s = s + 1 end
	end
	return e, s
end

function RP:Rows()
	local list, newest = {}, self:Newest()
	for _, m in ipairs(self:Members()) do
		local e, s = 0, 0
		if m.d then e, s = Issues(m.d) end
		m.e, m.s = e, s
		m.old = m.d and CmpVer(m.d.ver, newest) < 0
		if not self.filter.issues or (m.d and (e > 0 or s > 0 or (m.d.dur or 100) < 30 or m.old)) then list[#list + 1] = m end
	end
	local mode = self.sort
	table.sort(list, function(a, b)
		if (a.d ~= nil) ~= (b.d ~= nil) then return a.d ~= nil end -- people without data last
		if mode == "ilvl" and a.d and a.d.ilvl ~= b.d.ilvl then return a.d.ilvl > b.d.ilvl end
		if mode == "class" and (a.class or "") ~= (b.class or "") then return (a.class or "") < (b.class or "") end
		return a.name < b.name
	end)
	return list
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------
local X_SPEC, X_ILVL, X_ISSUE, X_VER, X_ICONS = 140, 330, 372, 480, 545

function RP:MakeRow(list)
	local r = CreateFrame("Frame", nil, list)
	r.name = UI:Text(r, 12, "ink")
	r.name:SetPoint("LEFT", 10, 0)
	r.spec = UI:Text(r, 11, "ink2")
	r.spec:SetPoint("LEFT", X_SPEC, 0)
	r.ilvl = UI:Text(r, 12, "ink")
	r.ilvl:SetPoint("LEFT", X_ILVL, 0)
	r.issue = UI:Text(r, 11, "ink2")
	r.issue:SetPoint("LEFT", X_ISSUE, 0)
	r.ver = UI:Text(r, 11, "ink2")
	r.ver:SetPoint("LEFT", X_VER, 0)
	r.icons = {}
	for i = 1, #SLOTS do
		local b = UI:Icon(r, ICON)
		b:SetPoint("LEFT", X_ICONS + (i - 1) * STEP, 0)
		b.mark = UI:Text(b, 12, "ink")
		b.mark:SetPoint("TOPRIGHT", 3, 3)
		r.icons[i] = b
	end
	return r
end

function RP:FillRow(r, m)
	local d = m.d
	r.name:SetText(UI:ClassName(m.name, m.class))
	if not d then
		r.spec:SetText("|cff6f6a62no betterRCLC data|r")
		r.ilvl:SetText("")
		r.issue:SetText("")
		r.ver:SetText("-")
		for _, b in ipairs(r.icons) do b:Hide() end
		return
	end
	local spec = UI:SpecTag(d.ms, d.class, 14) .. (d.ms and addon.BIS:SpecName(d.ms) or "?")
	for i, k in ipairs(d.oss) do spec = spec .. (i == 1 and "  " or "") .. UI:SpecTag(k, d.class, 14) end -- SpecTag ends with one space
	r.spec:SetText(spec)
	r.ilvl:SetText(format("%.1f", d.ilvl))
	local t = {}
	if m.e > 0 then t[#t + 1] = "|cffd9534f" .. m.e .. " ench|r" end
	if m.s > 0 then t[#t + 1] = "|cffe2b84d" .. m.s .. " gem|r" end
	if d.dur and d.dur < 30 then t[#t + 1] = "|cffd9534f" .. d.dur .. "% dur|r" end
	r.issue:SetText(#t > 0 and table.concat(t, " ") or "|cff57c27aok|r")
	r.ver:SetText(d.ver and ((m.old and "|cffe2b84d" or "|cff57c27a") .. d.ver .. "|r") or "|cffe2b84d< 0.5.5|r")
	for i, slot in ipairs(SLOTS) do
		local b, s = r.icons[i], d.gear[slot]
		b:Show()
		if s then
			b:SetItem("item:" .. s)
			if not GetItemInfo("item:" .. s) then self.unresolved = true end
		else
			b:SetItem(nil)
		end
		local fl = d.flag[slot]
		b.mark:SetText(fl and "|cffd9534f!|r" or "")
	end
end

function RP:Update()
	local f = self.frame
	if not f then return end
	local rows = self:Rows()
	self.unresolved = false
	f.list:SetData(rows)
	f.list:Refresh()
	local have, sum = 0, 0
	for _, m in ipairs(self:Members()) do if m.d then have = have + 1 sum = sum + m.d.ilvl end end
	local old, newest = 0, self:Newest()
	for _, m in ipairs(self:Members()) do if m.d and CmpVer(m.d.ver, newest) < 0 then old = old + 1 end end
	f.count:SetText(format("%d / %d with betterRCLC%s%s", have, #self:Members(), have > 0 and format(" · average ilvl %.1f", sum / have) or "",
		old > 0 and format(" · |cffe2b84d%d outdated|r", old) or ""))
	f.sortBtn:SetLabel("Sort: " .. self.sort)
	f.issuesBtn:SetLabel(self.filter.issues and "Problems only: on" or "Problems only")
	if self.unresolved and not self.retry then
		self.retry = true -- uncached items get their icon once the client knows them
		addon:ScheduleTimer(function() RP.retry = nil if f:IsVisible() then RP:Update() end end, 2)
	end
end

------------------------------------------------------------------------
-- CSV export (what the panel lists, in its current order)
------------------------------------------------------------------------
local SLOT_NAMES = {[1] = "Head", [2] = "Neck", [3] = "Shoulder", [15] = "Back", [5] = "Chest", [9] = "Wrist", [10] = "Hands", [6] = "Waist",
	[7] = "Legs", [8] = "Feet", [11] = "Ring1", [12] = "Ring2", [13] = "Trinket1", [14] = "Trinket2", [16] = "MainHand", [17] = "OffHand", [18] = "Ranged"}

local function csv(v)
	v = tostring(v == nil and "" or v)
	if v:find('[,"\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
	return v
end

--- Text, row count. Members without data get a row with only the name, so the sheet shows who is missing.
function RP:CSV()
	local head = {"player", "class", "main_spec", "off_specs", "ilvl", "missing_enchants", "empty_sockets", "lowest_durability", "addon_version"}
	for _, slot in ipairs(SLOTS) do head[#head + 1] = SLOT_NAMES[slot] end
	local out, rows = {table.concat(head, ",")}, self:Rows()
	for _, m in ipairs(rows) do
		local d = m.d
		local f = {m.name, m.class or ""}
		if d then
			local oss = {}
			for _, k in ipairs(d.oss) do oss[#oss + 1] = addon.BIS:SpecName(k) end
			f[#f + 1] = d.ms and addon.BIS:SpecName(d.ms) or ""
			f[#f + 1] = table.concat(oss, "/")
			f[#f + 1] = d.ilvl
			f[#f + 1] = m.e
			f[#f + 1] = m.s
			f[#f + 1] = d.dur or ""
			f[#f + 1] = d.ver or ""
			for _, slot in ipairs(SLOTS) do
				local s = d.gear[slot]
				f[#f + 1] = s and ((GetItemInfo("item:" .. s)) or s:match("^(%d+)")) or ""
			end
		end
		for i = 1, #f do f[i] = csv(f[i]) end
		out[#out + 1] = table.concat(f, ",")
	end
	return table.concat(out, "\n"), #rows
end

function RP:ShowExport()
	local text, n = self:CSV()
	local w = self.export
	if not w then
		w = UI:Window("raidExport", "Export raid gear", 720, 420, "DIALOG")
		w.box = UI:Edit(w.body, 696, 340, true)
		w.box:SetPoint("TOPLEFT", 12, -12)
		w.box.edit:SetScript("OnEscapePressed", function() w:Hide() end)
		w.hint = UI:Text(w.body, 12, "ink2")
		w.hint:SetPoint("BOTTOMLEFT", 12, 12)
		self.export = w
	end
	w.box:SetText(text)
	w.hint:SetText(n .. " rows. Ctrl+C to copy, then paste into a spreadsheet or Discord.")
	w:Show()
	w.box.edit:SetFocus()
	w.box.edit:HighlightText()
end

function RP:GetFrame()
	if self.frame then return self.frame end
	local f = addon.Main:Page("raid")
	f.empty:Hide()
	f.sortBtn = UI:Button(f, "Sort: ilvl", nil, 22, "default", function()
		for i, k in ipairs(SORTS) do if k == self.sort then self.sort = SORTS[i % #SORTS + 1] break end end
		self:Update()
	end)
	f.sortBtn:SetPoint("TOPLEFT", 12, -12)
	f.issuesBtn = UI:Button(f, "Problems only", nil, 22, "default", function() self.filter.issues = not self.filter.issues self:Update() end)
	f.issuesBtn:SetPoint("LEFT", f.sortBtn, "RIGHT", 6, 0)
	f.issuesBtn.tip = {"Problems only", "Missing enchants, empty sockets, durability under 30%, or an older addon version. Rings and off-hands are not checked for enchants."}
	f.refresh = UI:Button(f, "Refresh", nil, 22, "default", function() RP:SendMine() RP:Ask(true) end)
	f.refresh:SetPoint("TOPRIGHT", -12, -12)
	f.export = UI:Button(f, "Export CSV", nil, 22, "default", function() RP:ShowExport() end)
	f.export:SetPoint("RIGHT", f.refresh, "LEFT", -6, 0)
	f.count = UI:Text(f, 11, "ink3", "RIGHT")
	f.count:SetPoint("RIGHT", f.export, "LEFT", -10, 0)
	local cols = CreateFrame("Frame", nil, f)
	cols:SetPoint("TOPLEFT", 0, -44)
	cols:SetPoint("TOPRIGHT", 0, -44)
	cols:SetHeight(18)
	for _, c in ipairs({{"Player", 10}, {"Specs (main, off)", X_SPEC}, {"ilvl", X_ILVL}, {"Problems", X_ISSUE}, {"Addon", X_VER}, {"Gear", X_ICONS}}) do
		local t = UI:Text(cols, 11, "ink3")
		t:SetPoint("LEFT", c[2], 0)
		t:SetText(c[1])
	end
	f.list = UI:List(f, ROW_H, function(list) return self:MakeRow(list) end, function(r, m) self:FillRow(r, m) end)
	f.list:SetPoint("TOPLEFT", 0, -64)
	f.list:SetPoint("BOTTOMRIGHT", 0, 6)
	self.frame = f
	return f
end

addon.Main.onShow.raid = function()
	RP:GetFrame()
	RP:SendMine() -- my own row is always current
	RP:Ask()
	RP:Update()
end
