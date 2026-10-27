-- lootBags.lua  Loot kept in the Master Looter's bags: items waiting for a session (pending) and awarded items
-- waiting to be traded (toTrade). Both are saved per character, so they survive /reload and relogs.
-- Opening a trade with a winner puts their awarded items into the trade window.

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")

local TRADE_WINDOW = 2 * 60 * 60 -- raid loot can be traded to people who were there for 2 hours

function addon:Pending()
	local c = self.db.char
	c.pending = c.pending or {} -- { {link, boss, time}, ... }
	return c.pending
end

function addon:ToTrade()
	local c = self.db.char
	c.toTrade = c.toTrade or {} -- { {link, winner, time}, ... }
	return c.toTrade
end

function addon:TradeTimeLeft(t)
	return t and (TRADE_WINDOW - (time() - t)) or 0
end

local function ItemID(link)
	return link and tonumber(link:match("item:(%d+)"))
end

--- Moves a pending item to toTrade (or just drops it when the ML keeps it). Matches link + loot time.
function addon:PendingAwarded(link, lootTime, winner)
	local pending = self:Pending()
	for i, p in ipairs(pending) do
		if p.link == link and p.time == lootTime then
			tremove(pending, i)
			if p.reroll then self:HistoryRemove(p.reroll.owner, p.reroll.key, true) end -- rolled again: the new winner replaces it
			break
		end
	end
	if winner and not self:UnitIsUnit(winner, "player") then
		tinsert(self:ToTrade(), {link = link, winner = winner, time = lootTime or time()})
	end
end

function addon:PrintBags()
	local pending, toTrade = self:Pending(), self:ToTrade()
	if #pending == 0 and #toTrade == 0 then return self:Print("Nothing stored: no pending items and nothing to trade.") end
	if #pending > 0 then
		self:Print(format("Pending (%d), start a session with /brc award:", #pending))
		for _, p in ipairs(pending) do
			print(format("   %s  %s, %d min left to trade", p.link, p.boss or "?", max(0, floor(self:TradeTimeLeft(p.time) / 60))))
		end
	end
	if #toTrade > 0 then
		self:Print(format("To trade (%d):", #toTrade))
		for _, t in ipairs(toTrade) do
			print(format("   %s  ->  %s, %d min left", t.link, t.winner, max(0, floor(self:TradeTimeLeft(t.time) / 60))))
		end
	end
end

------------------------------------------------------------------------
-- Trade helper
------------------------------------------------------------------------
local tradeTarget, inWindow = nil, {} -- tradeTarget is kept after TRADE_CLOSED: "Trade complete" may arrive after it

local function FindInBags(id, used)
	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, GetContainerNumSlots(bag) do
			local link = GetContainerItemLink(bag, slot)
			local _, _, locked = GetContainerItemInfo(bag, slot)
			if link and not locked and ItemID(link) == id and not used[bag .. ":" .. slot] then
				used[bag .. ":" .. slot] = true
				return bag, slot
			end
		end
	end
end

--- Pause automation, not manual trading or completed-trade bookkeeping.
local function CouncilRunning()
	local ml = addon:GetActiveModule("masterlooter")
	return addon.isMasterLooter and ml and ml.running
end

local function FillTrade()
	if CouncilRunning() or not tradeTarget or CursorHasItem() then return end
	local used, n, put = {}, 1, 0
	for _, t in ipairs(addon:ToTrade()) do
		if addon:UnitIsUnit(t.winner, tradeTarget) then
			while n <= MAX_TRADABLE_ITEMS and GetTradePlayerItemLink(n) do n = n + 1 end
			if n > MAX_TRADABLE_ITEMS then break end
			local bag, slot = FindInBags(ItemID(t.link), used)
			if bag then
				PickupContainerItem(bag, slot)
				ClickTradeButton(n)
				put = put + 1
				n = n + 1
			end
		end
	end
	if put > 0 then
		addon:Print(format("Put %d awarded item(s) for %s in the trade window.", put, tradeTarget))
	end
end

------------------------------------------------------------------------
-- Auto-start trades (option autoTrade, ONLY the loot master's client, one request at a time): a winner with items waiting who stands in trade range for
-- autoTradeDelay seconds gets a trade request. Each player is tried at most once per TRADE_RETRY seconds (also after
-- ANY trade window with them opened, so a winner who started it first is not asked again), and never while a trade
-- window is open (combat is fine). Both players still click Accept themselves (an addon can't accept for them).
------------------------------------------------------------------------
local TRADE_RETRY = 10
local near, tried = {}, {}

local function UnitOf(name)
	name = name:gsub("%-.*", "")
	for i = 1, GetNumRaidMembers() do if UnitName("raid" .. i) == name then return "raid" .. i end end
	for i = 1, GetNumPartyMembers() do if UnitName("party" .. i) == name then return "party" .. i end end
end

--- One pass; returns the name it asked, if any.
function addon:AutoTradeStep()
	local p = self.db and self.db.profile
	if not (p and p.autoTrade and self.isMasterLooter) or CouncilRunning() or (TradeFrame and TradeFrame:IsShown()) or UnitIsDeadOrGhost("player") then
		wipe(near)
		return
	end
	local now, want = GetTime(), {}
	for _, t in ipairs(self:ToTrade()) do
		-- the item must still be in my bags: one already handed over some other way (or a quest item that never went
		-- into them) would otherwise be asked for every 10 s until the entry is removed by hand
		if self:TradeTimeLeft(t.time) > 0 and not self:UnitIsUnit(t.winner, "player") and FindInBags(ItemID(t.link), {}) then want[t.winner] = true end
	end
	for name in pairs(near) do if not want[name] then near[name] = nil end end
	for name in pairs(want) do
		local u = UnitOf(name)
		if u and UnitIsConnected(u) and not UnitIsDeadOrGhost(u) and CheckInteractDistance(u, 2) then
			near[name] = near[name] or now
			if now - near[name] >= (p.autoTradeDelay or 3) and now - (tried[name] or -99) >= TRADE_RETRY then
				tried[name], near[name] = now, nil
				InitiateTrade(u)
				return name
			end
		else
			near[name] = nil
		end
	end
end

------------------------------------------------------------------------
-- Trade window expiry (option expiryWarn, minimap menu): items in my bags can only be traded for 2 hours after the
-- drop. Each item is mentioned ONCE, when 15 minutes are left, and everything that crosses the line in the same check
-- goes into one message (a boss drop = one line, not one per item). Awarded-but-untraded items (winner or
-- disenchanter / bank character still waiting) and items nobody has been awarded yet are told apart.
------------------------------------------------------------------------
local WARN_LEFT = 15 * 60

function addon:ExpiryCheck()
	local p = self.db and self.db.profile
	if not p or p.expiryWarn == false then return end
	local lines, n = {}, 0
	local function add(t, text)
		local left = self:TradeTimeLeft(t.time)
		if t.warned or left <= 0 or left > WARN_LEFT then return end
		t.warned = true
		n = n + 1
		if #lines < 4 then lines[#lines + 1] = format("   %s  %s, %d min left", t.link, text, max(1, floor(left / 60))) end
	end
	for _, t in ipairs(self:ToTrade()) do
		local who = t.winner
		local kind = (who == p.disenchanter and "for disenchant: ") or (who == p.banker and "for the bank: ") or "awarded to "
		add(t, kind .. tostring(who))
	end
	for _, t in ipairs(self:Pending()) do add(t, "not awarded yet") end
	if n == 0 then return end
	self:Print(format("|cffe2b84d%d item(s) can only be traded for about 15 more minutes|r:", n))
	for _, l in ipairs(lines) do print(l) end
	if n > #lines then print(format("   ...and %d more (Loot tab).", n - #lines)) end
	print("   Trade them now, or use History > Reroll to give an awarded one to someone else. Minimap menu > Expiry warnings turns this off.")
end

local tradeClock, expiryClock = 0, 0
CreateFrame("Frame"):SetScript("OnUpdate", function(_, dt)
	tradeClock, expiryClock = tradeClock + dt, expiryClock + dt
	if expiryClock >= 30 then
		expiryClock = 0
		if addon.db then addon:ExpiryCheck() end
	end
	if tradeClock < 0.5 then return end
	tradeClock = 0
	addon:AutoTradeStep()
end)

local frame = CreateFrame("Frame")
frame:RegisterEvent("TRADE_SHOW")
frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
frame:RegisterEvent("UI_INFO_MESSAGE")
frame:SetScript("OnEvent", function(_, event, msg)
	if event == "TRADE_SHOW" then
		tradeTarget = UnitName("NPC")
		if tradeTarget then tried[tradeTarget] = GetTime() end
		wipe(inWindow)
		FillTrade()
	elseif event == "TRADE_ACCEPT_UPDATE" then -- remember what is in the window when someone accepts
		wipe(inWindow)
		for i = 1, MAX_TRADABLE_ITEMS do
			local link = GetTradePlayerItemLink(i)
			if link then inWindow[#inWindow + 1] = ItemID(link) end
		end
	elseif event == "UI_INFO_MESSAGE" and msg == ERR_TRADE_COMPLETE and tradeTarget then
		local toTrade = addon:ToTrade()
		for _, id in ipairs(inWindow) do
			for i, t in ipairs(toTrade) do
				if ItemID(t.link) == id and addon:UnitIsUnit(t.winner, tradeTarget) then
					addon:Print(format("Delivered %s to %s.", t.link, t.winner))
					tremove(toTrade, i)
					break
				end
			end
		end
		wipe(inWindow)
		local q = addon:GetModule("BRCSessionFrame", true)
		if q and q.frame then q:Update() end -- traded items leave the Loot tab
	end
end)
