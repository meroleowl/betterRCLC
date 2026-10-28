-- lootHistory.lua  Loot history (redesign step 5). Everyone keeps the history the loot master sends
-- (addon.lootDB.factionrealm[name] = {entries}). A table with filters by player, raid, this week, main spec only and
-- an item search; "Export CSV" copies the filtered rows (a copy window, Ctrl+C) for a spreadsheet or Discord.
-- "Won 7d" = that player's main-spec wins in the last 7 days from today (the council board's +1 number), the same on
-- every row of a player. Click an award to see everyone who answered (the council snapshot saved with the entry).

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local LootHistory = addon:NewModule("BRCLootHistory")
local UI = addon.UI

local ROW_H = 26
local Stamp
local WEEK = 7 * 24 * 3600
local DAYS = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}

function LootHistory:OnInitialize()
	self.filter = {player = nil, raid = nil, week = false, ms = false, search = ""}
end

function LootHistory:OnEnable()
	self:Show()
end

-- The council snapshot is ~2 KB per award: drop it from entries older than this (the award itself stays).
-- shortcut: fixed 60 days, make it a setting if guilds want the details for longer.
local KEEP_DETAILS = 60 * 24 * 3600
function LootHistory:PruneDetails()
	local now = time()
	for _, list in pairs(addon.lootDB.factionrealm) do
		for _, e in ipairs(list) do
			if e.council and now - (Stamp(e) or now) > KEEP_DETAILS then e.council = nil end
		end
	end
end

function LootHistory:OnDisable()
	self:Hide()
end

function LootHistory:Show()
	self:PruneDetails()
	addon.Main:Open("history")
end

function LootHistory:Hide()
	local M = addon.Main
	if M.frame and M.current == "history" then M.frame:Hide() end
end

--- The main window's History tab was shown.
function LootHistory:Refresh()
	self.filter = self.filter or {player = nil, raid = nil, week = false, ms = false, search = ""}
	self:GetFrame()
	self:Update()
end
addon.Main.onShow.history = function() LootHistory:Refresh() end

------------------------------------------------------------------------
-- data
------------------------------------------------------------------------
function Stamp(e)
	local d, m, y = (e.date or ""):match("(%d+)/(%d+)/(%d+)")
	if not d then return nil end
	local h, mi, s = (e.time or ""):match("(%d+):(%d+):?(%d*)")
	return time({year = 2000 + tonumber(y), month = tonumber(m), day = tonumber(d), hour = tonumber(h) or 12,
		min = tonumber(mi) or 0, sec = tonumber(s) or 0})
end

--- Every entry as {name, e, ts}, newest first, after the current filters (nil filter = all entries).
function LootHistory:Entries(filter)
	local out = {}
	local search = filter and filter.search and filter.search:lower() or ""
	local now = time()
	for name, list in pairs(addon.lootDB.factionrealm) do
		for _, e in ipairs(list) do
			local ts = Stamp(e) or 0
			local ok = true
			if filter then
				if filter.player and name ~= filter.player then ok = false end
				if filter.raid and e.instance ~= filter.raid then ok = false end
				if filter.week and now - ts > WEEK then ok = false end
				if filter.ms and not addon:IsMSWin(e) then ok = false end
				if search ~= "" and not ((e.lootWon or ""):match("%[(.-)%]") or ""):lower():find(search, 1, true) then ok = false end
			end
			if ok then out[#out + 1] = {name = name, e = e, ts = ts} end
		end
	end
	table.sort(out, function(a, b) if a.ts ~= b.ts then return a.ts > b.ts end return a.name < b.name end)
	return out
end

--- Main-spec wins of a player in the last 7 days.
function LootHistory:MSWins(name)
	local n, now = 0, time()
	for _, e in ipairs(addon.lootDB.factionrealm[name] or {}) do
		if addon:IsMSWin(e) and now - (Stamp(e) or 0) <= WEEK then n = n + 1 end
	end
	return n
end

local function csv(v)
	v = tostring(v or "")
	if v:find('[,"\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
	return v
end

--- CSV of the entries (all, or the filtered ones), newest first. Returns text, row count.
function LootHistory:CSV(filter)
	local out = {"date,time,player,class,item,itemID,response,boss,instance,votes"}
	local rows = self:Entries(filter)
	for _, r in ipairs(rows) do
		local e, link = r.e, r.e.lootWon or ""
		local d, m, y = (e.date or ""):match("(%d+)/(%d+)/(%d+)")
		local f = {
			d and format("20%02d-%02d-%02d", tonumber(y), tonumber(m), tonumber(d)) or (e.date or ""), e.time or "",
			r.name, e.class or "", link:match("%[(.-)%]") or link, link:match("item:(%d+)") or "",
			e.response or "", e.boss or "", e.instance or "", e.votes or "",
		}
		for i = 1, #f do f[i] = csv(f[i]) end
		out[#out + 1] = table.concat(f, ",")
	end
	return table.concat(out, "\n"), #rows
end

--- Copy window with the CSV of the filtered rows (Ctrl+C).
function LootHistory:ShowExport()
	local text, n = self:CSV(self.frame and self.frame:IsVisible() and self.filter or nil)
	local w = self.export
	if not w then
		w = UI:Window("historyExport", "Export loot history", 720, 420, "DIALOG")
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

------------------------------------------------------------------------
-- frame
------------------------------------------------------------------------
local COLS = {{"When", 12}, {"Item", 96}, {"Player", 330}, {"Answer", 440}, {"Boss", 560}, {"Won 7d", 840}, {"Raid", 690}}

function LootHistory:GetFrame()
	if self.frame then return self.frame end
	local f = addon.Main:Page("history") -- the main window's History tab
	local body = f

	-- filters
	f.player = UI:Button(body, "Player: all", nil, 22, "default", function(b) self:PickMenu(b, "player") end)
	f.player:SetPoint("TOPLEFT", 12, -12)
	f.raid = UI:Button(body, "Raid: all", nil, 22, "default", function(b) self:PickMenu(b, "raid") end)
	f.raid:SetPoint("LEFT", f.player, "RIGHT", 6, 0)
	f.week = UI:Button(body, "This week", nil, 22, "default", function() self.filter.week = not self.filter.week self:Update() end)
	f.week:SetPoint("LEFT", f.raid, "RIGHT", 6, 0)
	f.ms = UI:Button(body, "BiS only", nil, 22, "default", function() self.filter.ms = not self.filter.ms self:Update() end)
	f.ms:SetPoint("LEFT", f.week, "RIGHT", 6, 0)
	f.export = UI:Button(body, "Export CSV", nil, 22, "default", function() self:ShowExport() end)
	f.export:SetPoint("TOPRIGHT", -12, -12)
	f.clear = UI:Button(body, "Clear", nil, 22, "default", function(b) self:ClearMenu(b) end)
	f.clear:SetPoint("RIGHT", f.export, "LEFT", -6, 0)
	f.clear.tip = {"Clear history", "Removes awards from your own copy of the history (everything, old ones, or one player). Other raiders keep theirs."}
	f.search = UI:Edit(body, 150, 22, false, "Search items")
	f.search:SetPoint("RIGHT", f.clear, "LEFT", -6, 0)
	f.search.onChange = function(text) self.filter.search = text or "" self:Update() end

	local cols = CreateFrame("Frame", nil, body)
	cols:SetPoint("TOPLEFT", 0, -44)
	cols:SetPoint("TOPRIGHT", 0, -44)
	cols:SetHeight(18)
	for _, c in ipairs(COLS) do
		local t = UI:Text(cols, 11, "ink3")
		t:SetPoint("LEFT", c[2], 0)
		t:SetText(c[1])
	end
	local hint = UI:Text(cols, 11, "ink3", "RIGHT")
	hint:SetPoint("RIGHT", -14, 0)
	hint:SetText("Click items for details")
	f.list = UI:List(body, ROW_H, function(list) return self:MakeRow(list) end, function(r, item) self:FillRow(r, item) end)
	f.list:SetPoint("TOPLEFT", 0, -64)
	f.list:SetPoint("BOTTOMRIGHT", 0, 6)
	f.empty:SetText("No awards match these filters.")
	self.frame = f
	return f
end

function LootHistory:PickMenu(anchor, key)
	local values, seen = {}, {}
	for name, list in pairs(addon.lootDB.factionrealm) do
		if key == "player" then
			values[#values + 1] = name
		else
			for _, e in ipairs(list) do
				if e.instance and not seen[e.instance] then seen[e.instance] = true values[#values + 1] = e.instance end
			end
		end
	end
	table.sort(values)
	local items = {{text = "All", checked = not self.filter[key], func = function() self.filter[key] = nil self:Update() end}}
	for _, v in ipairs(values) do
		items[#items + 1] = {text = v, checked = self.filter[key] == v, func = function() self.filter[key] = v self:Update() end}
	end
	UI:Menu(anchor, items)
end

function LootHistory:MakeRow(list)
	local r = CreateFrame("Frame", nil, list)
	r.cells = {}
	for i, c in ipairs(COLS) do
		r.cells[i] = UI:Text(r, 12, i == 1 and "ink2" or "ink")
		r.cells[i]:SetPoint("LEFT", c[2] + (i == 2 and 24 or 0), 0)
	end
	r.cells[2]:SetWidth(206)
	r.cells[4]:SetWidth(116)
	r.cells[5]:SetWidth(130)
	r.cells[7]:SetWidth(160)
	r.icon = UI:Icon(r, 20)
	r.icon:SetPoint("LEFT", COLS[2][2], 0)
	r.hl = r:CreateTexture(nil, "BACKGROUND")
	r.hl:SetTexture(UI.FLAT)
	r.hl:SetAllPoints()
	r.hl:Hide()
	UI:Paint(function(p) r.hl:SetVertexColor(p.rowHover[1], p.rowHover[2], p.rowHover[3], p.rowHover[4] or 0.5) end)
	r:EnableMouse(true)
	r:SetScript("OnEnter", function() if r.item and r.item.e.council then r.hl:Show() end end)
	r:SetScript("OnLeave", function() r.hl:Hide() end)
	r:SetScript("OnMouseUp", function(_, btn) if btn == "LeftButton" and r.item and r.item.e.council then self:ShowDetails(r.item) end end)
	r.line = r:CreateTexture(nil, "BORDER") -- thin line under each row
	r.line:SetTexture(UI.FLAT)
	r.line:SetHeight(1)
	r.line:SetPoint("BOTTOMLEFT", 8, 0)
	r.line:SetPoint("BOTTOMRIGHT", -8, 0)
	UI:Paint(function(p) r.line:SetVertexColor(p.border[1], p.border[2], p.border[3], 0.55) end)
	r.edit = UI:Button(r, "Edit", 44, 20, "quiet", function() self:EditOwner(r.item) end)
	r.edit:SetPoint("RIGHT", -12, 0)
	r.edit.tip = {"Edit", "Change who has this item (they traded it between themselves)."}
	r.reroll = UI:Button(r, "Reroll", 56, 20, "default", function() self:Reroll(r.item) end)
	r.reroll:SetPoint("RIGHT", r.edit, "LEFT", -4, 0)
	r.reroll.tip = {"Roll again", "Puts the item back in your Loot tab to roll it out again; the new winner replaces this "
		.. "entry. Only while it can still be traded (2 h) or when it is bind on equip."}
	return r
end

function LootHistory:FillRow(r, item)
	local e = item.e
	r.cells[1]:SetText(item.ts > 0 and (DAYS[tonumber(date("%w", item.ts)) + 1] .. " " .. date("%H:%M", item.ts)) or (e.date or ""))
	r.icon:SetItem(e.lootWon)
	r.cells[2]:SetText((e.lootWon or ""):match("%[(.-)%]") or e.lootWon or "?")
	local q = e.lootWon and select(3, GetItemInfo(e.lootWon))
	local qr, qg, qb = 1, 1, 1
	if q and GetItemQualityColor then qr, qg, qb = GetItemQualityColor(q) end
	UI:Recolor(r.cells[2], {qr, qg, qb})
	r.cells[3]:SetText(item.name)
	UI:Recolor(r.cells[3], UI:ClassColor(e.class))
	local answer = e.response == "Main spec" and "BiS" or (e.response or "") -- entries from before 0.2.7
	r.cells[4]:SetText(answer)
	-- answers in their colours (BiS green, OS gold, Upgrade blue); award reasons (DE, bank, free) grey
	local kind = e.kind or ({"ms", "os", "up"})[e.responseID]
	local ac = not e.isAwardReason and kind and addon.ANSWER_COLORS[kind]
	UI:Recolor(r.cells[4], ac and {ac[1], ac[2], ac[3]} or "ink3")
	r.cells[5]:SetText(e.boss or "")
	r.cells[6]:SetText(e.isAwardReason and "-" or self:MSWins(item.name))
	r.cells[7]:SetText(((e.instance or ""):gsub(" Player$", ""):gsub("%-", " ", 1)))
	r.item = item
	if self:CanReroll(item) then r.reroll:Show() else r.reroll:Hide() end
end

------------------------------------------------------------------------
-- clear
------------------------------------------------------------------------
local function Remove(keep) -- keep(e, name) true = stays; returns how many went
	local n = 0
	for name, list in pairs(addon.lootDB.factionrealm) do
		for i = #list, 1, -1 do
			if not keep(list[i], name) then tremove(list, i) n = n + 1 end
		end
		if #list == 0 then addon.lootDB.factionrealm[name] = nil end
	end
	return n
end

--- Two steps: the menu picks what to clear, the button then asks "Confirm" for 6 seconds.
function LootHistory:AskClear(text, keep)
	local b = self.frame.clear
	self.clearKeep = keep
	b:SetLabel("Confirm: " .. text)
	b:SetTextTint(UI:Palette().bad)
	local token = {}
	self.clearToken = token
	addon:ScheduleTimer(function()
		if self.clearToken == token then self:ResetClear() end
	end, 6)
end

function LootHistory:ResetClear()
	self.clearKeep, self.clearToken = nil, nil
	self.frame.clear:SetLabel("Clear")
	self.frame.clear:SetTextTint(nil)
end

function LootHistory:ClearMenu(b)
	if self.clearKeep then -- second click
		local n = Remove(self.clearKeep)
		self:ResetClear()
		addon:Print(format("Cleared %d award%s from your history.", n, n == 1 and "" or "s"))
		return self:Update()
	end
	local now = time()
	local items = {
		{text = "Older than 30 days", func = function() self:AskClear("older than 30 days", function(e) return now - (Stamp(e) or now) <= 30 * 86400 end) end},
		{text = "Older than 7 days", func = function() self:AskClear("older than 7 days", function(e) return now - (Stamp(e) or now) <= 7 * 86400 end) end},
	}
	local who = self.filter.player
	if who then
		items[#items + 1] = {text = "Everything of " .. who, func = function() self:AskClear(who, function(_, name) return name ~= who end) end}
	end
	items[#items + 1] = {text = "Everything", func = function() self:AskClear("everything", function() return false end) end}
	UI:Menu(b, items)
end

------------------------------------------------------------------------
-- council details (click an award)
------------------------------------------------------------------------
-- the answers sit in groups like on the council board: a header row per group, a colour bar and every other row tinted
local KIND_ORDER = {ms = 1, up = 2, os = 3, PASS = 5, AUTOPASS = 5}
local GROUP = {{"BiS", {0.34, 0.76, 0.48}}, {"Upgrade", {0.35, 0.65, 0.95}}, {"OS", {0.886, 0.722, 0.302}},
	{"Other", {0.75, 0.55, 0.9}}, {"Pass", {0.5, 0.5, 0.5}}}

function LootHistory:DetailRows(item)
	local by = {}
	for name, c in pairs(item.e.council or {}) do
		local g = KIND_ORDER[c.k] or 4
		by[g] = by[g] or {}
		by[g][#by[g] + 1] = {name = name, c = c, winner = name == item.name, color = GROUP[g][2]}
	end
	local rows = {}
	for g = 1, #GROUP do
		local list = by[g]
		if list then
			table.sort(list, function(a, b)
				if (a.c.r or 0) ~= (b.c.r or 0) then return (a.c.r or 0) > (b.c.r or 0) end
				return a.name < b.name
			end)
			rows[#rows + 1] = {header = GROUP[g][1] .. " (" .. #list .. ")", color = GROUP[g][2]}
			for i, r in ipairs(list) do r.alt = i % 2 == 0 rows[#rows + 1] = r end
		end
	end
	return rows
end

local DCOLS = {{"Player", 12}, {"Answer", 150}, {"List", 236}, {"Wears", 372}, {"EP", 444}, {"Roll", 500}, {"Won 7d", 544}, {"Note", 602}}

function LootHistory:ShowDetails(item)
	local w = self.detail
	if not w then
		w = UI:Window("historyDetail", "Council details", 780, 460, "DIALOG")
		w.icon = UI:Icon(w.body, 36)
		w.icon:SetPoint("TOPLEFT", 12, -10)
		w.name = UI:Text(w.body, 14, "ink")
		w.name:SetPoint("TOPLEFT", w.icon, "TOPRIGHT", 10, -1)
		w.info = UI:Text(w.body, 12, "ink2")
		w.info:SetPoint("TOPLEFT", w.name, "BOTTOMLEFT", 0, -4)
		local cols = CreateFrame("Frame", nil, w.body)
		cols:SetPoint("TOPLEFT", 0, -56)
		cols:SetPoint("TOPRIGHT", 0, -56)
		cols:SetHeight(18)
		for _, c in ipairs(DCOLS) do
			local t = UI:Text(cols, 11, "ink3")
			t:SetPoint("LEFT", c[2], 0)
			t:SetText(c[1])
		end
		w.list = UI:List(w.body, 30, function(list)
			local r = CreateFrame("Frame", nil, list)
			r.cells = {}
			for i, c in ipairs(DCOLS) do
				r.cells[i] = UI:Text(r, 12, "ink")
				r.cells[i]:SetPoint("LEFT", c[2], 0)
			end
			r.cells[1]:SetWidth(134)
			r.cells[2]:SetWidth(84)
			r.cells[3]:SetWidth(132)
			r.cells[8]:SetWidth(150)
			r.g = {UI:Icon(r, 22), UI:Icon(r, 22)}
			r.g[1]:SetPoint("LEFT", DCOLS[4][2], 0)
			r.g[2]:SetPoint("LEFT", DCOLS[4][2] + 26, 0)
			r.mark = r:CreateTexture(nil, "OVERLAY")
			r.mark:SetTexture(UI.FLAT)
			r.mark:SetWidth(3)
			r.mark:SetPoint("TOPLEFT")
			r.mark:SetPoint("BOTTOMLEFT")
			r.bg = r:CreateTexture(nil, "BACKGROUND") -- every other row, and the winner, tinted
			r.bg:SetTexture(UI.FLAT)
			r.bg:SetAllPoints()
			r.line = r:CreateTexture(nil, "ARTWORK") -- thin line above a group header
			r.line:SetTexture(UI.FLAT)
			r.line:SetHeight(1)
			r.line:SetPoint("TOPLEFT")
			r.line:SetPoint("TOPRIGHT")
			r.head = UI:Text(r, 12, "ink")
			r.head:SetPoint("LEFT", 12, -2)
			return r
		end, function(r, d)
			if d.header then
				for _, cell in ipairs(r.cells) do cell:SetText("") end
				r.g[1]:Hide() r.g[2]:Hide()
				r.head:SetText(d.header)
				UI:Recolor(r.head, d.color)
				r.head:Show()
				r.line:SetVertexColor(d.color[1], d.color[2], d.color[3], 0.8)
				r.line:Show()
				r.bg:SetVertexColor(d.color[1], d.color[2], d.color[3], 0.12)
				r.mark:SetVertexColor(d.color[1], d.color[2], d.color[3], 1)
				return
			end
			r.head:Hide()
			r.line:Hide()
			local c = d.c
			r.cells[1]:SetText(d.name)
			UI:Recolor(r.cells[1], UI:ClassColor(c.c))
			r.cells[2]:SetText(c.t or (c.k == "AUTOPASS" and "Autopass") or (c.k == "PASS" and "Pass") or tostring(c.k or ""))
			local ac = addon.ANSWER_COLORS[c.k]
			UI:Recolor(r.cells[2], ac and {ac[1], ac[2], ac[3]} or "ink3")
			r.cells[3]:SetText(c.l or "")
			for k, key in ipairs({"g1", "g2"}) do
				if c[key] then r.g[k]:SetItem(c[key]) r.g[k]:Show() else r.g[k]:Hide() end
			end
			r.cells[5]:SetText(c.e and UI:Signed(c.e) or "")
			r.cells[6]:SetText(c.r or "")
			r.cells[7]:SetText(c.w or "")
			r.cells[8]:SetText((c.v and ("votes " .. c.v .. "  ") or "") .. (c.n or ""))
			local p = UI:Palette()
			r.mark:SetVertexColor(d.color[1], d.color[2], d.color[3], 0.9)
			if d.winner then
				r.bg:SetVertexColor(p.ok[1], p.ok[2], p.ok[3], 0.22) -- the winner's row is green
				r.cells[1]:SetText(d.name .. " |cff57c27a(won)|r")
			else
				r.bg:SetVertexColor(1, 1, 1, d.alt and 0.05 or 0)
			end
		end)
		w.list:SetPoint("TOPLEFT", 0, -76)
		w.list:SetPoint("BOTTOMRIGHT", 0, 6)
		self.detail = w
	end
	local e = item.e
	w.icon:SetItem(e.lootWon)
	w.name:SetText(e.lootWon or "?")
	local when = item.ts > 0 and (DAYS[tonumber(date("%w", item.ts)) + 1] .. " " .. date("%d/%m %H:%M", item.ts)) or (e.date or "")
	local raid = ((e.instance or ""):gsub(" Player$", ""):gsub("%-", " ", 1))
	w.info:SetText(UI.Join(" · ", "Awarded to " .. item.name, e.response, e.boss, raid, when))
	w.list:SetData(self:DetailRows(item))
	local n = 0
	for _, r in ipairs(w.list.data) do if r.name then n = n + 1 end end
	w:SetTitle("Council details", n .. " answered")
	w:Show()
end

------------------------------------------------------------------------
-- roll again / change owner
------------------------------------------------------------------------
local TRADE_WINDOW = 2 * 60 * 60

local function Key(e)
	return (e.lootWon or "") .. "@" .. (e.date or "") .. " " .. (e.time or "")
end
LootHistory.Key = Key

--- Loot master, award reasons excluded, and the item can still change hands: < 2 h since the award, or bind on equip.
function LootHistory:CanReroll(item)
	if not addon.isMasterLooter or item.e.isAwardReason then return false end
	if item.ts > 0 and time() - item.ts < TRADE_WINDOW then return true end
	return addon.IsItemBoE and addon:IsItemBoE(item.e.lootWon) or false
end

--- Back into the Loot tab (ticked); the next award replaces this entry everywhere (lootBags.lua PendingAwarded).
function LootHistory:Reroll(item)
	if not self:CanReroll(item) then return end
	if addon:IsBlueDisenchantable(item.e.lootWon) then
		return addon:Print("This item is blue disenchantable gear; its existing award and delivery were left unchanged.")
	end
	local e = item.e
	local p = {link = e.lootWon, boss = e.boss, time = item.ts > 0 and item.ts or time(), reroll = {owner = item.name, key = Key(e)}}
	tinsert(addon:Pending(), p)
	local toTrade = addon:ToTrade()
	for i, t in ipairs(toTrade) do -- not traded yet: it never left my bags
		if t.link == e.lootWon and addon:UnitIsUnit(t.winner, item.name) then tremove(toTrade, i) break end
	end
	local q = addon:GetModule("BRCSessionFrame")
	q.selected["p" .. p.time .. p.link] = true
	addon:Print(format("%s is back in the Loot tab. If %s already has it, get it traded back before the next session.", e.lootWon or "?", item.name))
	addon.Main:Open("loot")
end

--- Pick the real owner (raid grid or a typed name); moved here and, as loot master, for the whole raid.
function LootHistory:EditOwner(item)
	UI:PickPlayer("Who has " .. ((item.e.lootWon or ""):match("%[(.-)%]") or "it") .. "?", function(name, class)
		addon:HistoryMove(item.name, Key(item.e), name, class, true)
		self:Update()
	end, nil, true)
end

local function Find(owner, key)
	local list = addon.lootDB.factionrealm[owner]
	for i, e in ipairs(list or {}) do if Key(e) == key then return list, i, e end end
end

--- Removes an entry (a rerolled item that went to someone else). broadcast = tell the raid (loot master only).
function addon:HistoryRemove(owner, key, broadcast)
	local list, i = Find(owner, key)
	if list then tremove(list, i) end
	if broadcast and self.isMasterLooter then self:SendCommand("group", "history_remove", owner, key) end
end

--- Moves an entry to another owner (class: theirs when known).
function addon:HistoryMove(owner, key, newOwner, class, broadcast)
	local list, i, e = Find(owner, key)
	if not list or owner == newOwner then return end
	tremove(list, i)
	e.class = class or e.class
	local db = self.lootDB.factionrealm
	db[newOwner] = db[newOwner] or {}
	tinsert(db[newOwner], e)
	if broadcast and self.isMasterLooter then self:SendCommand("group", "history_edit", owner, key, newOwner, class) end
end

--- The latest history entry of an item under its old winner moves to the new one (a re-award, no reroll).
function addon:HistoryReaward(owner, link, newOwner, class)
	local list = self.lootDB.factionrealm[owner]
	for i = #(list or {}), 1, -1 do
		if list[i].lootWon == link then return self:HistoryMove(owner, Key(list[i]), newOwner, class, true) end
	end
end

function LootHistory:Update()
	local f = self.frame
	if not f then return end
	local rows = self:Entries(self.filter)
	f.list:SetData(rows)
	if #rows == 0 then f.empty:Show() else f.empty:Hide() end
	addon.Main:SetSub("history", #rows .. " award" .. (#rows == 1 and "" or "s"))
	f.player:SetLabel("Player: " .. (self.filter.player or "all"))
	f.raid:SetLabel("Raid: " .. (self.filter.raid or "all"))
	f.raid:ClearAllPoints() f.raid:SetPoint("LEFT", f.player, "RIGHT", 6, 0)
	f.week:SetActive(self.filter.week)
	f.ms:SetActive(self.filter.ms)
end
