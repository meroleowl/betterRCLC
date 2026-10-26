-- main.lua  The main window (tabs Loot / Council / History / Raid, the modules draw into its pages), the minimap button
-- (left click = main window, right click = MRT-style menu with the loot master's main options), the "use betterRCLC
-- with this group?" popup and the test items (taken from the loot master's own BiS list).

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local UI = addon.UI

local M = {pages = {}, subs = {}, onShow = {}}
addon.Main = M

local TABS = {{"loot", "Loot"}, {"council", "Council"}, {"history", "History"}, {"raid", "Raid"}}
local EMPTY = {
	loot = "",
	council = "No loot council session is running.",
	history = "",
	raid = "",
}

function M:Build()
	if self.frame then return self.frame end
	local f = UI:Window("main", "Loot council", 1000, 570)
	UI:Resizable(f, "main", 1000, 440) -- narrower clips the board's columns, lower clips its side panel
	f.tabs = UI:Segmented(f.head, TABS, function(k) self:Select(k) end, 20, 78)
	f.tabs:SetPoint("RIGHT", f.head.close, "LEFT", -12, 0)
	f.autoTrade = UI:Check(f.head, "Auto trade", function(on) addon.db.profile.autoTrade = on end) -- loot master: on every tab
	f.autoTrade:SetPoint("RIGHT", f.tabs, "LEFT", -16, 0)
	-- one setting, three places that change it (this switch, the minimap menu, Settings): the switch re-reads it a few
	-- times a second, so it can never disagree with them
	local acc = 0
	f.autoTrade:SetScript("OnUpdate", function(b, dt)
		acc = acc + dt
		if acc < 0.25 then return end
		acc = 0
		local on = addon.db.profile.autoTrade and true or false
		if b.checked ~= on then b:SetChecked(on) end
	end)
	self.frame = f
	for _, t in ipairs(TABS) do
		local p = CreateFrame("Frame", nil, f.body)
		p:SetAllPoints(f.body)
		p.empty = UI:Text(p, 13, "ink3", "CENTER")
		p.empty:SetPoint("CENTER")
		p.empty:SetText(EMPTY[t[1]])
		p:Hide()
		self.pages[t[1]] = p
	end
	return f
end

--- The page frame a module draws into.
function M:Page(key)
	self:Build()
	return self.pages[key]
end

function M:SetSub(key, text)
	self.subs[key] = text
	if self.current == key and self.frame then self.frame:SetTitle("Loot council", text) end
end

--- The header's Auto trade switch follows the setting (the minimap menu and Settings change it too); loot master only.
function M:RefreshAutoTrade()
	local f = self.frame
	if not f or not f.autoTrade then return end
	f.autoTrade:SetChecked(addon.db.profile.autoTrade)
	if addon.isMasterLooter then f.autoTrade:Show() else f.autoTrade:Hide() end
end

function M:Select(key)
	self:Build()
	self:RefreshAutoTrade()
	self.current = key
	for k, p in pairs(self.pages) do if k == key then p:Show() else p:Hide() end end
	self.frame.tabs:Select(key)
	self.frame:SetTitle("Loot council", self.subs[key])
	if self.onShow[key] then self.onShow[key]() end
end

--- Opens the main window on a tab (nil = the council during a session, else the loot list for the ML, else history).
function M:Open(tab)
	self:Build()
	if not tab then
		local vf = addon:GetModule("BRCVotingFrame", true)
		if vf and vf:IsActive() then tab = "council"
		elseif addon.isMasterLooter then tab = "loot"
		else tab = self.current or "history" end
	end
	self.frame:Show()
	self:Select(tab)
end

function M:Toggle()
	if self.frame and self.frame:IsShown() then self.frame:Hide() else self:Open() end
end

------------------------------------------------------------------------
-- minimap button + menu
------------------------------------------------------------------------
local MODES = {{"window", "Stays on the corpse"}, {"bags", "To my bags, roll now"}, {"batch", "To my bags, roll later"}}
local UPGRADE = {{"ep", "EP (stat weights)"}, {"ilvl", "Item level"}}

local function LabelOf(list, key)
	for _, o in ipairs(list) do if o[1] == key then return o[2] end end
	return list[1][2]
end

local function Pick(list, key)
	local p = addon.db.profile
	local items = {}
	for _, o in ipairs(list) do
		items[#items + 1] = {text = o[2], checked = p[key] == o[1], func = function() p[key] = o[1] addon:ConfigTableChanged(key) end}
	end
	return items
end

--- Right-click menu: everyday things only, sections split by thin lines; the rest lives in Settings (/brc config).
-- The loot master block shows only when "Use as loot master" is not Off.
function M:MenuItems()
	local p = addon.db.profile
	local S = addon.Settings
	-- answer timer presets; any other length is set in Settings > Loot rules
	local timer = {}
	for _, sec in ipairs({0, 30, 45, 60, 90}) do
		timer[#timer + 1] = {text = sec == 0 and "Off" or (sec .. " seconds"),
			checked = (sec == 0 and not p.lootFrameTimerEnabled) or (p.lootFrameTimerEnabled and p.lootFrameTimerDuration == sec),
			func = function()
				p.lootFrameTimerEnabled = sec > 0
				if sec > 0 then p.lootFrameTimerDuration = sec end
				addon:ConfigTableChanged("lootFrameTimerEnabled")
			end}
	end
	local timers = {}
	for _, sec in ipairs({10, 15, 20, 30}) do
		timers[#timers + 1] = {text = sec .. " seconds", checked = (p.pugTimer or 15) == sec, func = function() p.pugTimer = sec end}
	end
	local BIS = addon.BIS
	-- my main / off spec, the same values as Settings > My specs (nil = auto from talents)
	local function SpecPick(field)
		local cur = addon.db.char[field]
		local items = {{text = "Auto (talents)", checked = cur == nil, func = function() addon.db.char[field] = nil BIS:SendMine() end}}
		for _, name in ipairs(BIS.SPECS[addon.playerClass] or {}) do
			local key = addon.playerClass .. ":" .. name
			items[#items + 1] = {text = name, checked = cur == key, func = function() addon.db.char[field] = key BIS:SendMine() end}
		end
		return items
	end
	local ms, _, oss = BIS:MySpecs()
	-- off specs: several can be ticked (each click toggles one and closes the menu); Auto / None reset the set
	local mode = BIS:OSMode()
	local osItems = {
		{text = "Auto (other dual spec)", checked = mode == "auto", func = function() BIS:SetOS("auto") end},
		{text = "None", checked = mode ~= "auto" and next(mode) == nil, func = function() BIS:SetOS("none") end},
	}
	for _, name in ipairs(BIS.SPECS[addon.playerClass] or {}) do
		local key = addon.playerClass .. ":" .. name
		local on = mode ~= "auto" and mode[key] == true
		osItems[#osItems + 1] = {text = name, checked = on, func = function() BIS:SetOS(key, not on) end}
	end
	-- window / roll card size presets (Settings > General has the sliders)
	local function Scales(key)
		local items = {}
		for _, v in ipairs({0.7, 0.8, 0.9, 1.0, 1.1, 1.2}) do
			items[#items + 1] = {text = math.floor(v * 100 + 0.5) .. "%", checked = math.abs((p[key] or 1) - v) < 0.01,
				func = function() p[key] = v UI:ApplyScale() end}
		end
		return items
	end
	local usage = p.usage.state == "ml" and "Loot council" or p.usage.state == "pug" and "Pug rolls" or "Off"
	local items = {
		{text = "Open loot council", func = function() M:Open() end},
		{text = "Use as loot master: " .. usage, sub = {
			{text = "Loot council (guild raids)", checked = p.usage.state == "ml", func = function() addon:SetUsage("ml") end},
			{text = "Pug rolls (/roll in chat)", checked = p.usage.state == "pug", func = function() addon:SetUsage("pug") end},
			{text = "Off", checked = p.usage.state ~= "ml" and p.usage.state ~= "pug", func = function() addon:SetUsage("never") end},
		}},
		{sep = true},
		{text = "My specs", sub = {
			{text = "Main spec: " .. BIS:SpecName(ms), sub = SpecPick("msSpec")},
			{text = "Off specs: " .. BIS:SpecNames(oss), sub = osItems},
		}},
		{text = "Size", sub = {
			{text = "Windows", sub = Scales("uiScale")},
			{text = "Roll cards", sub = Scales("cardScale")},
		}},
	}
	local function add(it) items[#items + 1] = it end
	-- loot master settings people change mid-raid. Shown inline while usage is Loot council / Pug rolls; with usage
	-- Off (every raider) they stay reachable under one "Loot master" submenu so the raider menu stays short.
	local ml = {}
	local function mladd(it) ml[#ml + 1] = it end
	if p.usage.state == "pug" then
		mladd({text = "Pug loot window", func = function() addon.Pug:Open() end})
		mladd({text = "Pug roll time: " .. (p.pugTimer or 15) .. " s", sub = timers})
		mladd({text = "Pug +1 rule", checked = p.pugPlusOne, func = function() p.pugPlusOne = not p.pugPlusOne addon.Pug:Update() end})
		mladd({text = "Reset pug +1 counts", func = function() addon.Pug:ResetPlus() end})
		mladd({sep = true})
	end
	mladd({text = "Loot goes: " .. LabelOf(MODES, p.lootMode), sub = Pick(MODES, "lootMode")})
	mladd({text = "Answer timer: " .. (p.lootFrameTimerEnabled and ((p.lootFrameTimerDuration or 30) .. " s") or "off"), sub = timer})
	mladd({text = "Upgrade column: " .. LabelOf(UPGRADE, p.upgradeMode), sub = Pick(UPGRADE, "upgradeMode")})
	mladd({text = "Auto-award", checked = p.autoCouncil, func = function() p.autoCouncil = not p.autoCouncil end})
	mladd({text = "Expiry warnings", checked = p.expiryWarn ~= false, func = function() p.expiryWarn = not (p.expiryWarn ~= false) end})
	mladd({text = "Auto-start trades", checked = p.autoTrade, func = function() p.autoTrade = not p.autoTrade addon.Main:RefreshAutoTrade() end})
	mladd({text = "Rolls in chat", checked = p.chatRolls, func = function() p.chatRolls = not p.chatRolls addon:ConfigTableChanged("chatRolls") end})
	mladd({text = "Council votes", checked = p.councilVotes, func = function() p.councilVotes = not p.councilVotes addon:ConfigTableChanged("councilVotes") end})
	mladd({text = "Raiders may watch the board", checked = p.observe, func = function() p.observe = not p.observe addon:ConfigTableChanged("observe") end})
	mladd({text = "Auto-loot recipes and orbs", checked = p.autoLootMats, func = function() p.autoLootMats = not p.autoLootMats end})
	mladd({text = "Force my BiS lists on the raid", checked = p.forceBis, func = function()
		p.forceBis = not p.forceBis
		addon:ConfigTableChanged("forceBis")
		addon:Print(p.forceBis and "Raiders use your BiS lists while in your group (their own lists come back when they leave)."
			or "Raiders use their own BiS lists again (yours fill only the specs they have none for).")
	end})
	mladd({sep = true})
	mladd({text = "Disenchanter: " .. ((p.disenchanter or "") ~= "" and p.disenchanter or "none"), func = function() addon:GetModule("BRCVotingFrame"):PickHelper("disenchant") end})
	mladd({text = "Bank: " .. ((p.banker or "") ~= "" and p.banker or "none"), func = function() addon:GetModule("BRCVotingFrame"):PickHelper("bank") end})
	mladd({text = "Soft reserves...", func = function() addon.Rolls:OpenImport() end})
	mladd({text = "Ask raid for their specs", func = function() addon:SendCommand("group", "specRequest") addon:Print("Asked the raid for their main / off specs.") end})
	add({sep = true})
	if p.usage.state == "ml" or p.usage.state == "pug" then
		for _, it in ipairs(ml) do add(it) end
	else
		add({text = "Loot master", sub = ml})
	end
	add({sep = true})
	add({text = "Settings", sub = {
		{text = "General", func = function() S:Open("general") end},
		{text = "My specs", func = function() S:Open("specs") end},
		{text = "Roll cards", func = function() S:Open("cards") end},
		{text = "Loot rules", func = function() S:Open("rules") end},
		{text = "Pug rolls", func = function() S:Open("pug") end},
		{text = "BiS lists", func = function() S:Open("bis") end},
		{text = "Import a BiS list", func = function() S:OpenImport() end},
		{text = "Council & officers", func = function() S:Open("council") end},
		{text = "Announcements", func = function() S:Open("announce") end},
	}})
	return items
end

--- "ml" (loot council), "pug" (chat rolls, the council stays off) or "never".
function addon:SetUsage(v)
	local u = self.db.profile.usage
	for k in pairs(u) do if k ~= "state" then u[k] = k == v end end
	u.never = v ~= "ml" -- the council module must not start in pug mode
	u.state = v
	if v ~= "ml" and self.isMasterLooter then
		local ml = self:GetActiveModule("masterlooter")
		if ml then ml:Disable() end
	end
	if v == "ml" then self:NewMLCheck() end
end

function M:MinimapDB()
	local g = addon.db.global
	g.minimap = g.minimap or {}
	return g.minimap
end

function M:CreateMinimap()
	if self.button or not (CHSkin and CHSkin.MinimapButton) then return end
	self.button = CHSkin.MinimapButton({
		name = "betterRCLC",
		icon = "Interface\\Icons\\INV_Misc_Bag_10_Black",
		db = self:MinimapDB(),
		onClick = function(b, mouse)
			if mouse == "RightButton" then UI:Menu(b, M:MenuItems(), "cursor") else M:Toggle() end
		end,
		tooltip = function(tt)
			tt:AddLine("betterRCLC")
			tt:AddLine("Left click: loot council", 1, 1, 1)
			tt:AddLine("Right click: options", 1, 1, 1)
			tt:AddLine("Drag: move", 0.6, 0.6, 0.6)
		end,
	})
end

function M:ShowMinimap(show)
	self:MinimapDB().mmHide = not show or nil
	if self.button then if show then self.button:Show() else self.button:Hide() end end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function() if addon.db then M:CreateMinimap() end end)

------------------------------------------------------------------------
-- "Use betterRCLC with this group?" (core.lua keeps the Yes/No actions in addon.usageDialog)
------------------------------------------------------------------------
function addon:AskUsage()
	local w = M.usage
	if not w then
		w = UI:Window("usage", "betterRCLC", 360, 120, "DIALOG")
		w.text = UI:Text(w.body, 13, "ink")
		w.text:SetPoint("TOPLEFT", 14, -14)
		w.text:SetText("You are the master looter. Use betterRCLC for this group?")
		w.yes = UI:Button(w.body, "Use it", 110, 26, "primary", function() w:Hide() addon.usageDialog.buttons[1].on_click() end)
		w.yes:SetPoint("BOTTOMLEFT", 14, 12)
		w.no = UI:Button(w.body, "Not this time", 110, 26, "default", function() w:Hide() addon.usageDialog.buttons[2].on_click() end)
		w.no:SetPoint("LEFT", w.yes, "RIGHT", 6, 0)
		M.usage = w
	end
	w:Show()
end

------------------------------------------------------------------------
-- test items: the loot master's own main-spec BiS list (not what they wear), then a fixed list
------------------------------------------------------------------------
local FALLBACK = {40384, 19019, 46017, 40343, 43952, 40399, 46038, 45038}

function addon:TestItems(num)
	local worn = {}
	for slot = 1, 19 do
		local id = GetInventoryItemID("player", slot)
		if id then worn[id] = true end
	end
	local ms = self.BIS:MySpecs()
	local pool, seen = {}, {}
	local function add(id) if id and not worn[id] and not seen[id] then seen[id] = true pool[#pool + 1] = id end end
	for _, e in ipairs((self.BIS:Parse(ms and self.BIS:ListText(ms)))) do
		for _, id in ipairs(e.ids) do add(id) end
	end
	if #pool < num then for _, id in ipairs(FALLBACK) do add(id) end end
	local items = {}
	for _ = 1, math.min(num, #pool) do
		local j = math.random(1, #pool)
		items[#items + 1] = table.remove(pool, j)
	end
	return items
end
