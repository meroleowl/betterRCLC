-- sessionFrame.lua  The Loot tab of the main window: what the loot master holds. Items on the corpse and items looted
-- to my bags that nobody has rolled for yet, grouped by boss with the 2 h trade timer and a "BiS for N" chip; tick the
-- ones to roll (click a boss header to tick its whole group) and Start session, so e.g. all tank loot goes in one batch.
-- Awarded items drop to "Ready for trade" at the bottom with a Trade button (opens the trade, lootBags.lua puts the
-- items in). Traded items leave the list; the award itself is in the History tab.
-- Same module API as before (Show(lootTable)), so ml_core's calls are unchanged.

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local Queue = addon:NewModule("BRCSessionFrame", "AceTimer-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("betterRCLC")
local UI = addon.UI
local LibToken = LibStub("LibArmorToken-1.0")

local ROW_H = 30
local WARN = 20 * 60 -- trade timers under 20 minutes turn amber
local MODES = {{"window", "Stays on the corpse"}, {"bags", "To my bags, roll now"}, {"batch", "To my bags, roll later"}}

Queue.selected = {}
Queue.tab = "roll" -- sub-tab: "roll" | "trade" | "raid"

function Queue:OnEnable()
	self.ml = addon:GetActiveModule("masterlooter")
end

function Queue:OnDisable()
	self:CancelAllTimers()
	self.ticking = nil
end

--- ml_core calls this with its lootTable (corpse items): open the Loot tab with them ticked.
function Queue:Show(data)
	for i in ipairs(data or {}) do self.selected["c" .. i] = true end
	addon.Main:Open("loot")
end

function Queue:Hide()
	local M = addon.Main
	if M.frame and M.current == "loot" then M.frame:Hide() end
end

--- Main window tab shown: build, fill, keep the timers ticking while it is open.
function Queue:Refresh()
	self.ml = self.ml or addon:GetActiveModule("masterlooter")
	self:GetFrame()
	self:Update()
	if not self.ticking then
		self.ticking = self:ScheduleRepeatingTimer(function()
			if self.frame:IsVisible() then self:Update() end
		end, 10)
	end
end
addon.Main.onShow.loot = function() Queue:Refresh() end

------------------------------------------------------------------------
-- data
------------------------------------------------------------------------
--- Raid members whose cached main spec (from their last answer) has the item as BiS.
function Queue:BisCount(link)
	local n = 0
	for name, specs in pairs(addon.db.global.specCache or {}) do
		if UnitInRaid(name) or UnitInParty(name) then
			local s = specs[1] and addon.BIS:Status(specs[1], link)
			if s and s.bis then n = n + 1 end
		end
	end
	return n
end

local function Clock(t) return t and date("%H:%M", t) or "" end

local function TimeLeft(t)
	local left = addon:TradeTimeLeft(t)
	return left > 0 and format("%d:%02d left", math.floor(left / 3600), math.floor(left % 3600 / 60)) or "expired", left
end

--- Rows: corpse group, bag groups by boss (newest first), then "Ready for trade".
function Queue:Rows()
	local rows = {}
	local corpse = {header = addon.target or "Loot", sub = "on the corpse", keys = {}}
	for i, v in ipairs(self.ml and self.ml.lootTable or {}) do
		if not v.bagged then
			if #corpse.keys == 0 then rows[#rows + 1] = corpse end
			rows[#rows + 1] = {key = "c" .. i, link = v.link, name = v.name, session = i}
			corpse.keys[#corpse.keys + 1] = "c" .. i
		end
	end
	local groups, order = {}, {}
	for _, p in ipairs(addon:Pending()) do
		local boss = p.boss or "?"
		if not groups[boss] then groups[boss] = {time = p.time, list = {}} order[#order + 1] = boss end
		groups[boss].time = math.max(groups[boss].time or 0, p.time or 0)
		tinsert(groups[boss].list, {key = "p" .. (p.time or 0) .. p.link, link = p.link, time = p.time, pending = p})
	end
	table.sort(order, function(a, b) return groups[a].time > groups[b].time end)
	for _, boss in ipairs(order) do
		local head = {header = boss, sub = "looted " .. Clock(groups[boss].time), keys = {}}
		rows[#rows + 1] = head
		for _, r in ipairs(groups[boss].list) do rows[#rows + 1] = r head.keys[#head.keys + 1] = r.key end
	end
	return rows
end

--- To trade: awarded items waiting for their winner, by winner.
function Queue:TradeRows()
	local rows = {}
	local list = {}
	for _, t in ipairs(addon:ToTrade()) do list[#list + 1] = t end
	table.sort(list, function(a, b) if a.winner ~= b.winner then return a.winner < b.winner end return (a.time or 0) < (b.time or 0) end)
	for _, t in ipairs(list) do rows[#rows + 1] = {link = t.link, winner = t.winner, time = t.time, entry = t} end
	return rows
end

--- Raid: who has betterRCLC (missing first).
function Queue:RaidRows()
	local rows = {}
	local cands = self.ml and self.ml.candidates or {}
	for i = 1, GetNumRaidMembers() do
		local name, _, _, _, _, class = GetRaidRosterInfo(i)
		local specs = addon.db.global.specCache and addon.db.global.specCache[name]
		if name then rows[#rows + 1] = {player = name, class = class, ok = cands[name] ~= nil, ms = specs and specs[1], oss = specs and (specs[3] or (specs[2] and {specs[2]}))} end
	end
	table.sort(rows, function(a, b) if a.ok ~= b.ok then return not a.ok end return a.player < b.player end)
	return rows
end

function Queue:Coverage()
	local have, total, missing = 0, 0, {}
	local cands = self.ml and self.ml.candidates or {}
	for i = 1, GetNumRaidMembers() do
		local name = GetRaidRosterInfo(i)
		if name then
			total = total + 1
			if cands[name] then have = have + 1 else missing[#missing + 1] = name end
		end
	end
	return have, total, missing
end

function Queue:SelectAll()
	local keys = {}
	for _, r in ipairs(self:Rows()) do if r.key then keys[#keys + 1] = r.key end end
	local on = self:SelectedCount() < #keys
	for _, k in ipairs(keys) do self.selected[k] = on or nil end
	self:Update()
end

function Queue:SelectedCount()
	local n = 0
	for _, r in ipairs(self:Rows()) do if r.key and self.selected[r.key] then n = n + 1 end end
	return n
end

--- Start a session with the ticked items: unticked corpse items are dropped, ticked bag items are added.
--- The council module only runs when "Use as loot master" is Loot council (or auto-started); starting a session from
-- the Loot tab is an explicit "I'm the loot master", so switch it on instead of failing on a missing lootTable.
function Queue:EnsureML()
	local ml = addon:GetActiveModule("masterlooter")
	if ml and addon.isMasterLooter and not ml.lootTable then
		addon:CallModule("masterlooter")
		ml:NewML(addon.masterLooter)
	end
	self.ml = ml
	return ml
end

function Queue:Start()
	local ml = self:EnsureML()
	if not ml or not addon.isMasterLooter then return addon:Print(L["You cannot use this command without being the Master Looter"]) end
	if ml.running then return addon:Print(L["You're already running a session."]) end
	local rows = self:Rows()
	for i = #ml.lootTable, 1, -1 do
		if ml.lootTable[i].bagged or not self.selected["c" .. i] then ml:RemoveItem(i) end
	end
	local added = 0
	for _, r in ipairs(rows) do
		if r.pending and self.selected[r.key] then
			ml:AddItem(r.pending.link, true, nil, nil, r.pending)
			self.selected[r.key] = nil
			added = added + 1
		end
	end
	if #ml.lootTable == 0 and added == 0 then return addon:Print("Tick at least one item.") end
	if added > 0 then
		ml:ScheduleTimer("StartSession", 1) -- uncached items (AddItem retries after 0.5 s) get a moment
	else
		ml:StartSession()
	end
	self:Update()
end

--- Corpse items: loot them to my bags and keep them for later (they join the bag list).
function Queue:KeepForLater()
	local ml = self:EnsureML()
	if not ml or not ml.lootTable then return end
	for i, v in ipairs(ml.lootTable) do
		if not v.bagged and self.selected["c" .. i] then ml:Award(i) end
	end
	ml.lootTable = {}
	self:Update()
end

--- Opens a trade with the winner (must be close); lootBags.lua then puts their awarded items in.
function Queue:Trade(winner)
	for i = 1, 40 do
		for _, unit in ipairs({"raid" .. i, i <= 4 and ("party" .. i) or "none"}) do
			if UnitName(unit) == winner then
				if not CheckInteractDistance(unit, 2) then return addon:Print(winner .. " is too far away to trade.") end
				return InitiateTrade(unit)
			end
		end
	end
	addon:Print(winner .. " is not in your group.")
end

------------------------------------------------------------------------
-- frame (the main window's Loot page)
------------------------------------------------------------------------
function Queue:GetFrame()
	if self.frame then return self.frame end
	local f = addon.Main:Page("loot")
	f.tabs = UI:Segmented(f, {{"roll", "To roll"}, {"trade", "To trade"}, {"raid", "Raid"}}, function(k) self.tab = k self:Update() end, 22)
	f.tabs:SetPoint("TOPLEFT", 8, -8)
	f.modeLabel = UI:Text(f, 12, "ink2")
	f.modeLabel:SetPoint("TOPLEFT", 12, -42)
	f.modeLabel:SetText("Loot goes")
	f.mode = UI:Segmented(f, MODES, function(k) addon.db.profile.lootMode = k addon:ConfigTableChanged("lootMode") end, 22)
	f.mode:SetPoint("LEFT", f.modeLabel, "RIGHT", 10, 0)

	local box = CreateFrame("Frame", nil, f) -- bordered section around the list
	box:SetPoint("TOPLEFT", 6, -68)
	box:SetPoint("BOTTOMRIGHT", -6, 50)
	UI:Panel(box, "bg", "border", 1)
	f.list = UI:List(box, ROW_H, function(list) return self:MakeRow(list) end, function(r, item) self:FillRow(r, item) end)
	f.list:SetPoint("TOPLEFT", 1, -1)
	f.list:SetPoint("BOTTOMRIGHT", -1, 1)
	f.empty:SetText("Nothing to roll. Looted items show up here; with \"To my bags, roll later\" they wait until you tick them and press Start session.")
	f.empty:SetWidth(600)
	f.empty:SetWordWrap(true)

	local foot = CreateFrame("Frame", nil, f)
	foot:SetPoint("BOTTOMLEFT", 6, 6)
	foot:SetPoint("BOTTOMRIGHT", -6, 6)
	foot:SetHeight(38)
	UI:Panel(foot, "bg2", "border", 1)
	f.count = UI:Text(foot, 12, "ink2")
	f.count:SetPoint("LEFT", 14, 0)
	f.start = UI:Button(foot, "Start session", 140, 26, "primary", function() self:Start() end)
	f.start:SetPoint("RIGHT", -12, 0)
	f.later = UI:Button(foot, "Keep for later", nil, 26, "default", function() self:KeepForLater() end)
	f.later:SetPoint("RIGHT", f.start, "LEFT", -6, 0)
	f.clear = UI:Button(foot, "Clear corpse list", nil, 26, "quiet", function() self.ml.lootTable = {} self:Update() end)
	f.clear:SetPoint("RIGHT", f.later, "LEFT", -6, 0)
	-- one click ticks every item in the list (or clears them when all are ticked already)
	f.all = UI:Button(foot, "Select all", 90, 26, "default", function() self:SelectAll() end)
	f.all:SetPoint("LEFT", f.count, "RIGHT", 24, 0)
	f.add = UI:Button(foot, "Add items", nil, 26, "default", function() self:ShowBagPicker() end)
	f.add:SetPoint("LEFT", f.all, "RIGHT", 6, 0)
	f.ask = UI:Button(foot, "Ask raid for specs", nil, 26, "default", function()
		addon:SendCommand("group", "specRequest")
		addon:Print("Asked the raid for their main / off specs.")
	end)
	f.ask:SetPoint("RIGHT", -12, 0)
	self.frame = f
	return f
end

function Queue:MakeRow(list)
	local r = CreateFrame("Button", nil, list)
	r:SetBackdrop({bgFile = UI.FLAT})
	r:SetBackdropColor(0, 0, 0, 0)
	r.check = UI:Check(r, "", function(on) if r.item and r.item.key then self.selected[r.item.key] = on self:UpdateFooter() end end)
	r.check:SetPoint("LEFT", 14, 0)
	r.icon = UI:Icon(r, 24)
	r.icon:SetPoint("LEFT", 38, 0)
	r.name = UI:Text(r, 12, "ink")
	r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
	r.name:SetWidth(300)
	r.chip = UI:Chip(r, 10)
	r.chip:SetPoint("LEFT", 390, 0)
	r.right = UI:Text(r, 12, "ink2", "RIGHT")
	r.right:SetPoint("RIGHT", -110, 0)
	r.trade = UI:Button(r, "Trade", 80, 22, "default", function() if r.item and r.item.winner then self:Trade(r.item.winner) end end)
	r.trade:SetPoint("RIGHT", -16, 0)
	r.del = UI:Button(r, "X", 22, 22, "danger", function() if r.item then self:RemoveItem(r.item) end end)
	r.head = UI:Text(r, 12, "accent")
	r.head:SetPoint("LEFT", 14, 0)
	r.headSub = UI:Text(r, 11, "ink3", "RIGHT")
	r.headSub:SetPoint("RIGHT", -14, 0)
	r:SetScript("OnClick", function()
		local it = r.item
		if not it then return end
		if it.key then
			r.check:Click()
		elseif it.keys then -- boss header: tick / untick the whole group
			local all = true
			for _, k in ipairs(it.keys) do if not self.selected[k] then all = false end end
			for _, k in ipairs(it.keys) do self.selected[k] = not all end
			self:Update()
		end
	end)
	return r
end

function Queue:FillRow(r, item)
	r.item = item
	local p = UI:Palette()
	for _, w in ipairs({r.check, r.icon, r.name, r.chip, r.right, r.trade, r.del}) do w:Hide() end
	if item.header then
		r.head:SetText(item.header:upper()) r.head:Show()
		UI:Recolor(r.head, "ink2")
		r.headSub:SetText((item.sub or ""):upper()) r.headSub:Show()
		r:SetBackdropColor(p.bg2[1], p.bg2[2], p.bg2[3], 1)
		return
	end
	r.head:Hide() r.headSub:Hide()
	r:SetBackdropColor(0, 0, 0, 0)
	if item.player then -- Raid tab
		r.name:SetText(item.player) r.name:Show()
		UI:Recolor(r.name, UI:ClassColor(item.class))
		r.chip:Set(item.ok and "has betterRCLC" or "missing", item.ok and "ok" or "bad")
		local B = addon.BIS
		r.right:SetText(item.ms and (UI:SpecTag(item.ms, item.class, 14) .. B:SpecName(item.ms) .. (item.oss and #item.oss > 0 and ("  |cff6f6a62OS|r " .. B:SpecNames(item.oss)) or ""))
			or "|cff6f6a62specs not received yet|r")
		UI:Recolor(r.right, "ink")
		r.right:Show()
		return
	end
	r.icon:SetItem(item.link) r.icon:Show()
	r.name:SetText(item.name or (GetItemInfo(item.link)) or item.link or "?") r.name:Show()
	UI:Recolor(r.name, "ink")
	if item.winner then
		r.chip:Set("to " .. item.winner, "accent")
		local text, left = TimeLeft(item.time)
		r.right:SetText(text) UI:Recolor(r.right, left < WARN and "warn" or "ink2") r.right:Show()
		r.trade:Show()
		r.del:ClearAllPoints() r.del:SetPoint("RIGHT", -100, 0) r.del:Show()
		return
	end
	r.check:SetChecked(self.selected[item.key]) r.check:Show()
	local n = self:BisCount(item.link)
	r.chip:Set(n > 0 and ("BiS for " .. n) or "on no list", n > 0 and "ok" or "muted")
	if item.pending and item.pending.boe then
		r.right:SetText("BoE") UI:Recolor(r.right, "ink2")
	elseif item.time then
		local text, left = TimeLeft(item.time)
		r.right:SetText(text) UI:Recolor(r.right, left < WARN and "warn" or "ink2")
	else
		r.right:SetText("on corpse") UI:Recolor(r.right, "ink3")
	end
	r.right:Show()
	r.del:ClearAllPoints() r.del:SetPoint("RIGHT", -14, 0) r.del:Show()
end

--- Manual clean-up: drop one item from the roll list (corpse or bags) or the trade list. Nothing is awarded.
function Queue:RemoveItem(item)
	if item.session then
		if self.ml.running then return addon:Print("Wait for the session to end before removing corpse items.") end
		self.ml:RemoveItem(item.session)
	else
		for _, list in ipairs({addon:Pending(), addon:ToTrade()}) do
			for i, e in ipairs(list) do
				if e == item.pending or e == item.entry then tremove(list, i) break end
			end
		end
	end
	if item.key then self.selected[item.key] = nil end
	self:Update()
end

--- Manual add: a pasted item link or an item ID goes to the bag list, where it is ticked and rolled like any other item.
function Queue:AddManual(text)
	text = text or ""
	local link = text:match("|c%x+|Hitem:.-|h%[.-%]|h|r")
	local id = tonumber(text:match("^%s*(%d+)%s*$"))
	if not link and id then select(2, GetItemInfo(id)) link = select(2, GetItemInfo(id)) or ("item:" .. id) end
	if not link then return addon:Print("That is not an item link or ID.") end
	tinsert(addon:Pending(), {link = link, boss = "Added manually", time = time()})
	self:Update()
	return true
end

--- Can another raider still get this bag item? "boe" (not bound yet), seconds left on the 2 h loot-trade timer, or nil.
-- shortcut: reads the tooltip text, so it relies on the client's own strings (enUS "1 hour 23 min" for the timer).
local scanTip, tradePattern
function Queue.TradeInfo(bag, slot)
	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "BRCScanTip", nil, "GameTooltipTemplate")
		tradePattern = "^" .. BIND_TRADE_TIME_REMAINING:gsub("%%s", "\001"):gsub("[%(%)%.%-%+%*%?%[%]%^%$%%]", "%%%0"):gsub("\001", "(.+)")
	end
	scanTip:SetOwner(UIParent, "ANCHOR_NONE")
	scanTip:ClearLines()
	scanTip:SetBagItem(bag, slot)
	local bound, boe
	for i = 2, scanTip:NumLines() do
		local t = _G["BRCScanTipTextLeft" .. i]:GetText() or ""
		local left = t:match(tradePattern)
		if left then
			local h, m = tonumber(left:match("(%d+) hour")) or 0, tonumber(left:match("(%d+) min")) or 0
			return math.max(60, h * 3600 + m * 60)
		end
		if t == ITEM_SOULBOUND then bound = true elseif t == ITEM_BIND_ON_EQUIP or t == ITEM_BIND_ON_USE then boe = true end
	end
	return (boe and not bound) and "boe" or nil
end

--- Only raid loot: gear, tier tokens, recipes and Runed Orbs (no potions, food, reagents...).
function Queue:IsLoot(link)
	local id = tonumber(link:match("item:(%d+)"))
	return IsEquippableItem(link) or (id and LibToken:ItemIsToken(id)) or (self.ml and self.ml:IsMat(link)) or false
end

--- Bag items the raid can still receive (IsLoot): BoEs (rare or better) and anything with a loot-trade timer,
-- minus the copies already on the Loot tab or waiting for trade.
function Queue:BagItems()
	local have = {}
	for _, p in ipairs(addon:Pending()) do have[p.link] = (have[p.link] or 0) + 1 end
	for _, t in ipairs(addon:ToTrade()) do have[t.link] = (have[t.link] or 0) + 1 end
	local out = {}
	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, GetContainerNumSlots(bag) do
			local link = GetContainerItemLink(bag, slot)
			local left = link and self:IsLoot(link) and self.TradeInfo(bag, slot)
			if left and (left ~= "boe" or (select(3, GetItemInfo(link)) or 0) >= 3) then
				if (have[link] or 0) > 0 then have[link] = have[link] - 1
				else out[#out + 1] = {link = link, left = left} end
			end
		end
	end
	return out
end

--- "Add items": the bag items above as a grid (click = tick / untick), added in one go; or an ID / Shift+clicked link.
function Queue:ShowBagPicker()
	local w = self.picker
	if not w then
		w = UI:Window("bagpick", "Add items from your bags", 452, 200, "DIALOG")
		w.icons, w.picked = {}, {}
		-- top: type an ID / paste a link, Add puts it on the roll list
		w.edit = UI:Edit(w.body, 362, 22, false, "item ID or Shift+click an item")
		w.edit:SetPoint("TOPLEFT", 12, -10)
		w.one = UI:Button(w.body, "Add", 60, 22, "default", function()
			if self:AddManual(w.edit:GetText()) then w.edit:SetText("") end
		end)
		w.one:SetPoint("TOPRIGHT", -12, -10)
		w.edit.edit:SetScript("OnEnterPressed", function() w.one:Click() end)
		w.sep = w.body:CreateTexture(nil, "ARTWORK")
		w.sep:SetPoint("TOPLEFT", 12, -42)
		w.sep:SetPoint("TOPRIGHT", -12, -42)
		w.sep:SetHeight(1)
		UI:Paint(function(p) w.sep:SetTexture(p.border[1], p.border[2], p.border[3], 1) end)
		w.note = UI:Text(w.body, 11, "ink3")
		w.note:SetPoint("TOPLEFT", 12, -52)
		w.note:SetPoint("TOPRIGHT", -12, -52)
		w.note:SetWordWrap(true)
		-- bottom: adds the ticked bag items, disabled until one is ticked
		w.go = UI:Button(w.body, "Add", 428, 26, "primary", function() self:AddPicked() end)
		if hooksecurefunc then -- Shift+click on an item (bags, chat) pastes it while the field has focus
			hooksecurefunc("ChatEdit_InsertLink", function(link) if w:IsShown() and w.edit.edit:HasFocus() then w.edit:SetText(link) end end)
		end
		self.picker = w
	end
	w.items = self:BagItems()
	wipe(w.picked)
	local COLS, S, GAP = 10, 38, 5 -- 10 columns fit the 428 px body
	w.note:SetText(#w.items > 0 and "Click the items to roll, then add them. Gear, tokens, recipes and Runed Orbs that are BoE or still tradeable."
		or "No tradeable gear, tokens, recipes or Runed Orbs in your bags.")
	local top = -52 - math.ceil(w.note:GetStringHeight()) - 10
	for i, it in ipairs(w.items) do
		local b = w.icons[i]
		if not b then
			b = UI:Icon(w.body, S)
			b.tick = b:CreateTexture(nil, "OVERLAY")
			b.tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
			b.tick:SetSize(22, 22)
			b.tick:SetPoint("BOTTOMRIGHT", 4, -4)
			b.timer = UI:Text(b, 10, "ink", "CENTER")
			b.timer:SetPoint("TOP", b, "BOTTOM", 0, -1)
			w.icons[i] = b
		end
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", 12 + ((i - 1) % COLS) * (S + GAP), top - math.floor((i - 1) / COLS) * (S + GAP + 12))
		b:SetItem(it.link)
		b.timer:SetText(it.left == "boe" and "BoE" or format("%d:%02d", math.floor(it.left / 3600), math.floor(it.left % 3600 / 60)))
		b.tick:Hide()
		b:SetAlpha(0.55)
		b:SetScript("OnClick", function(btn)
			if IsModifiedClick() then return HandleModifiedItemClick(it.link) end
			w.picked[i] = not w.picked[i] or nil
			if w.picked[i] then btn.tick:Show() else btn.tick:Hide() end
			btn:SetAlpha(w.picked[i] and 1 or 0.55)
			self:UpdatePicker()
		end)
		b:Show()
	end
	for i = #w.items + 1, #w.icons do w.icons[i]:Hide() end
	local rows = math.max(1, math.ceil(#w.items / COLS))
	local gridH = #w.items > 0 and rows * (S + GAP + 12) or 0
	local goY = top - gridH - 6
	w.go:ClearAllPoints()
	w.go:SetPoint("TOPLEFT", 12, goY)
	w.edit:SetText("")
	w:SetHeight(29 - goY + 26 + 12) -- header 29, button 26, bottom gap 12
	self:UpdatePicker()
	w:Show()
end

function Queue:UpdatePicker()
	local w, n = self.picker, 0
	for _ in pairs(w.picked) do n = n + 1 end
	w.go:SetLabel(n > 1 and ("Add " .. n .. " items") or n == 1 and "Add item" or "Tick items to add")
	if n > 0 then w.go:Enable() else w.go:Disable() end
end

function Queue:AddPicked()
	local w, now, n = self.picker, time(), 0
	for i, it in ipairs(w.items) do
		if w.picked[i] then
			n = n + 1
			-- BoEs have no timer (shown as BoE); the -n keeps two copies of one item apart (rows and awards key on link + time)
			local boe = it.left == "boe"
			tinsert(addon:Pending(), {link = it.link, boss = "From bags", time = (boe and now or (now - (7200 - it.left))) - n, boe = boe or nil})
		end
	end
	w:Hide()
	addon:Print(format("Added %d item(s) from your bags to the Loot tab.", n))
	self:Update()
end

function Queue:UpdateFooter()
	local f = self.frame
	if self.tab == "raid" and addon.isMasterLooter then f.ask:Show() else f.ask:Hide() end
	if self.tab ~= "roll" then
		for _, b in ipairs({f.start, f.later, f.clear, f.add, f.all}) do b:Hide() end
		f.count:SetText(self.tab == "trade" and "Trade opens a trade with the winner and puts their items in."
			or "Specs arrive by themselves when you become loot master; players without betterRCLC can't answer.")
		return
	end
	f.start:Show() f.add:Show() f.all:Show()
	local n = self:SelectedCount()
	local total = 0
	for _, r in ipairs(self:Rows()) do if r.key then total = total + 1 end end
	f.all:SetLabel(total > 0 and n == total and "Select none" or "Select all")
	if total > 0 then f.all:Enable() else f.all:Disable() end
	f.count:SetText(n .. " ticked")
	local corpse = false
	for _, v in ipairs(self.ml and self.ml.lootTable or {}) do if not v.bagged then corpse = true end end
	if corpse then f.later:Show() f.clear:Show() else f.later:Hide() f.clear:Hide() end
	local running = self.ml and self.ml.running
	if n > 0 and addon.isMasterLooter and not running then f.start:Enable() else f.start:Disable() end
	f.start:SetLabel(running and "Session running" or "Start session")
end

--- Pulsing amber tab while items wait for a trade (the loot master must hand them out).
local function Pulse(b, on)
	on = on and true or false
	if b.pulsing == on then return end
	b.pulsing = on
	if on then
		b.pulseT = 0
		b:SetScript("OnUpdate", function(self, e)
			self.pulseT = self.pulseT + e
			local p = UI:Palette()
			local c, k = p.warn, 0.5 + 0.5 * math.sin(self.pulseT * 3.2)
			self:SetBackdropColor(c[1] * (0.15 + 0.3 * k), c[2] * (0.15 + 0.3 * k), c[3] * (0.15 + 0.3 * k), 1)
			self:SetBackdropBorderColor(c[1], c[2], c[3], 0.45 + 0.55 * k)
			self.text:SetTextColor(c[1], c[2], c[3])
		end)
	else
		b:SetScript("OnUpdate", nil)
		b:SetActive(b.kitActive) -- repaint with the normal colours
	end
end

function Queue:Update()
	local f = self.frame
	if not f then return end
	local roll = self:Rows()
	local pending = 0
	for _, r in ipairs(roll) do if r.key then pending = pending + 1 end end
	local trade = addon:ToTrade()
	addon.Main:SetSub("loot", pending .. " to roll · " .. #trade .. " to trade")
	local have, total = self:Coverage()
	f.tabs.buttons[1]:SetLabel("To roll " .. pending)
	f.tabs.buttons[2]:SetLabel("To trade " .. #trade)
	Pulse(f.tabs.buttons[2], #trade > 0)
	f.tabs.buttons[3]:SetLabel(total > 0 and ("Raid " .. have .. " / " .. total .. " have the addon") or "Raid")
	f.tabs:Relayout()
	f.tabs:Select(self.tab)
	f.mode:Select(addon.db.profile.lootMode or "window")
	local rows = self.tab == "trade" and self:TradeRows() or self.tab == "raid" and self:RaidRows() or roll
	f.list:SetData(rows)
	f.empty:SetText(self.tab == "trade" and "Nothing waiting for a trade."
		or self.tab == "raid" and "Not in a raid."
		or "Nothing to roll. Looted items show up here; with \"To my bags, roll later\" they wait until you tick them and press Start session.")
	if #rows == 0 then f.empty:Show() else f.empty:Hide() end
	self:UpdateFooter()
end
