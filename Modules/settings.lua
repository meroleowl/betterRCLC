-- settings.lua  Settings window and import window (redesign step 6). One window grouped by who uses it: "Me" for every
-- raider, "Loot master" for the ML and officers, "Addon". The BiS editor shows each slot's items as icons. The import
-- window takes a wowsims link or JSON export, Discord text, a list of item links, or a full guild export string.
-- 0.4.0: the old AceConfig pages are gone; this window is the only settings UI.

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local UI = addon.UI
local BIS = addon.BIS

local S = {pages = {}}
addon.Settings = S

local W, NAV_W, ROW = 800, 180, 30
local function P() return addon.db.profile end
local function Changed(key) addon:ConfigTableChanged(key) end

------------------------------------------------------------------------
-- page builder: a page is a frame with a vertical cursor; controls refresh themselves when the page is shown
------------------------------------------------------------------------
local Page = {}
Page.__index = Page

-- scroll = the page scrolls with the mouse wheel (content taller than the window); the BiS editor scrolls its own list
local function NewPage(parent, scroll)
	local outer = CreateFrame(scroll and "ScrollFrame" or "Frame", nil, parent)
	outer:SetPoint("TOPLEFT", NAV_W + 1, 0)
	outer:SetPoint("BOTTOMRIGHT")
	local f = outer
	if scroll then
		f = CreateFrame("Frame", nil, outer)
		f:SetSize(W - NAV_W - 2, 1000)
		outer:SetScrollChild(f)
		outer:EnableMouseWheel(true)
		outer:SetScript("OnMouseWheel", function(self, d)
			local max = math.max(0, f:GetHeight() - (self:GetHeight() or 0))
			self:SetVerticalScroll(math.max(0, math.min(max, (self:GetVerticalScroll() or 0) - d * 40)))
		end)
	end
	return setmetatable({frame = f, outer = outer, y = -16, refresh = {}}, Page)
end

function Page:Refresh() for _, fn in ipairs(self.refresh) do fn() end end

function Page:Title(text)
	local t = UI:Text(self.frame, 15, "accent")
	t:SetPoint("TOPLEFT", 20, self.y)
	t:SetText(text)
	self.y = self.y - 26
	return t
end

function Page:Note(text, color)
	local t = UI:Text(self.frame, 12, color or "ink2")
	t:SetPoint("TOPLEFT", 20, self.y)
	t:SetWidth(W - NAV_W - 50)
	t:SetWordWrap(true)
	t:SetJustifyV("TOP")
	if type(text) == "function" then table.insert(self.refresh, function() t:SetText(text()) end) else t:SetText(text) end
	local lines = type(text) == "string" and math.max(1, math.ceil(#text / 95)) or 1
	self.y = self.y - lines * 15 - 8
	return t
end

function Page:Gap(h) self.y = self.y - (h or 10) end

local function Label(page, text)
	local t = UI:Text(page.frame, 12, "ink")
	t:SetPoint("TOPLEFT", 20, page.y - 4)
	t:SetText(text)
	return t
end

--- Toggle bound to db.profile[key], or to get/set functions.
function Page:Toggle(key, label, get, set)
	local c = UI:Check(self.frame, label, function(on)
		if set then set(on) else P()[key] = on Changed(key) end
	end)
	c:SetPoint("TOPLEFT", 20, self.y - 2)
	table.insert(self.refresh, function() c:SetChecked(get and get() or P()[key]) end)
	self.y = self.y - 24
	return c
end

--- Choice of a few values as a segmented switch. options = {{value, text}, ...}.
function Page:Choice(key, label, options, get, set)
	Label(self, label)
	local seg = UI:Segmented(self.frame, options, function(v) if set then set(v) else P()[key] = v Changed(key) end self:Refresh() end, 22)
	seg:SetPoint("TOPLEFT", 200, self.y)
	table.insert(self.refresh, function() seg:Select(get and get() or P()[key]) end)
	self.y = self.y - ROW
	return seg
end

--- Text (or number) field bound to db.profile[key]; saved on Enter and when it loses focus.
function Page:Field(key, label, width, numeric, get, set)
	Label(self, label)
	local e = UI:Edit(self.frame, width or 160, 22)
	e:SetPoint("TOPLEFT", 200, self.y)
	local function save()
		local v = e:GetText()
		if numeric then v = tonumber(v) if not v then return end end
		if set then set(v) else P()[key] = v Changed(key) end
	end
	e.edit:SetScript("OnEnterPressed", function(b) save() b:ClearFocus() end)
	e.edit:HookScript("OnEditFocusLost", save)
	table.insert(self.refresh, function() local v if get then v = get() else v = P()[key] end e:SetText(v ~= nil and tostring(v) or "") end)
	self.y = self.y - ROW
	return e
end

--- Multi-line box with a Save button.
function Page:Lines(label, height, get, set, help)
	Label(self, label)
	self.y = self.y - 20
	local e = UI:Edit(self.frame, W - NAV_W - 50, height, true)
	e:SetPoint("TOPLEFT", 20, self.y)
	self.y = self.y - height - 6
	local save = UI:Button(self.frame, "Save", nil, 22, "default", function() set(e:GetText()) end)
	save:SetPoint("TOPLEFT", 20, self.y)
	if help then
		local h = UI:Text(self.frame, 11, "ink3")
		h:SetPoint("LEFT", save, "RIGHT", 10, 0)
		h:SetText(help)
	end
	table.insert(self.refresh, function() e:SetText(get()) end)
	self.y = self.y - ROW
	return e
end

--- Slider bound to db.profile[key] (saved and applied when the mouse is released).
function Page:Slider(key, label, min, max, step, fmt, onSet, def)
	Label(self, label)
	local sl = UI:Slider(self.frame, 160, min, max, step, fmt, function(v)
		P()[key] = v
		if onSet then onSet(v) end
	end)
	sl:SetPoint("TOPLEFT", 200, self.y - 5)
	table.insert(self.refresh, function() sl:SetTo(P()[key] or def or 1) end)
	self.y = self.y - ROW
	return sl
end

function Page:Buttons(list)
	local x = 20
	for _, b in ipairs(list) do
		local btn = UI:Button(self.frame, b[1], nil, 24, b[3] or "default", b[2])
		btn:SetPoint("TOPLEFT", x, self.y)
		x = x + btn:GetWidth() + 6
		b.button = btn
	end
	self.y = self.y - ROW - 4
	return list
end

------------------------------------------------------------------------
-- pages
------------------------------------------------------------------------
local NAV = {
	{"ME"},
	{"general", "General"}, {"specs", "My specs"}, {"cards", "Roll cards"}, {"theme", "Theme"}, {"history", "Loot history"},
	{"LOOT MASTER"},
	{"rules", "Loot rules"}, {"bis", "BiS lists"}, {"council", "Council & officers"},
	{"announce", "Announcements"}, {"pug", "Pug rolls"},
	{"ADDON"},
	{"about", "About"},
}

local function SpecOptions()
	local t = {{"auto", "Auto"}}
	for _, name in ipairs(BIS.SPECS[addon.playerClass] or {}) do t[#t + 1] = {addon.playerClass .. ":" .. name, name} end
	return t
end

local BUILD = {}

--- Theme page: one tile per palette (panel colour, border, accent title, glow line); click = use it everywhere at once.
function BUILD.theme(p)
	p:Title("Theme")
	p:Note("Pick the colours of every betterRCLC window. Each theme is a dark panel with an accent and a second glow colour.")
	local tiles = {{"follow", "Follow ElvUI", nil}}
	for _, key in ipairs(addon.THEME_ORDER or {}) do tiles[#tiles + 1] = {key, addon.THEMES[key].name, addon.THEMES[key]} end
	local COLS, TW, TH, GAPX = 3, 180, 52, 8
	local buttons = {}
	local function C(c, a) return c.r, c.g, c.b, a or 1 end
	for i, tile in ipairs(tiles) do
		local b = CreateFrame("Button", nil, p.frame)
		b:SetSize(TW, TH)
		b:SetPoint("TOPLEFT", 20 + ((i - 1) % COLS) * (TW + GAPX), p.y - math.floor((i - 1) / COLS) * (TH + GAPX))
		b:SetBackdrop(UI:Backdrop(b))
		local t = tile[3]
		if t then
			b:SetBackdropColor(C(t.backdrop))
			b:SetBackdropBorderColor(C(t.border))
			b.title = UI:Text(b, 12, {t.accent.r, t.accent.g, t.accent.b})
			b.glow = b:CreateTexture(nil, "OVERLAY")
			b.glow:SetTexture(UI.FLAT)
			b.glow:SetVertexColor(C(t.line or t.accent, 0.9))
			b.glow:SetPoint("BOTTOMLEFT", 6, 7)
			b.glow:SetPoint("BOTTOMRIGHT", -6, 7)
			b.glow:SetHeight(3)
			b.dot = b:CreateTexture(nil, "OVERLAY")
			b.dot:SetTexture(UI.FLAT)
			b.dot:SetVertexColor(C(t.cast))
			b.dot:SetSize(18, 3)
			b.dot:SetPoint("BOTTOMLEFT", b.glow, "TOPLEFT", 0, 5)
		else
			b:SetBackdropColor(0.1, 0.1, 0.1, 1)
			b:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
			b.title = UI:Text(b, 12, "ink")
		end
		b.title:SetPoint("TOPLEFT", 8, -8)
		b.title:SetText(tile[2])
		b.key = tile[1]
		b:SetScript("OnClick", function() P().theme = tile[1] UI:Repaint() p:Refresh() end)
		buttons[#buttons + 1] = b
	end
	table.insert(p.refresh, function()
		local cur = P().theme or "follow"
		local acc = UI:Palette().accent
		for _, b in ipairs(buttons) do
			if b.key == cur then b:SetBackdropBorderColor(acc[1], acc[2], acc[3], 1)
			elseif addon.THEMES[b.key] then b:SetBackdropBorderColor(C(addon.THEMES[b.key].border))
			else b:SetBackdropBorderColor(0.3, 0.3, 0.3, 1) end
		end
	end)
	p.y = p.y - math.ceil(#tiles / COLS) * (TH + GAPX) - 6
	p:Note("Follow ElvUI uses the theme of your ElvUI profile when the ElvUI fork is installed, otherwise Forever Bronze.")
end

function BUILD.general(p)
	p:Title("General")
	p:Choice(nil, "Use as loot master", {{"ml", "Loot council"}, {"pug", "Pug rolls"}, {"never", "Off"}},
		function() return P().usage.state end,
		function(v) addon:SetUsage(v) end)
	p:Note("Only matters when you are the master looter. Loot council: betterRCLC runs the loot (guild raids, raiders need the addon). Pug rolls: items are rolled with /roll in raid chat and nobody else needs the addon (settings: Pug rolls page). Off: the addon only shows you roll cards when someone else is the loot master. Raiders leave this on Off.")
	p:Gap(4)
	p:Toggle("autoOpenBoard", "Open the council board when the loot master starts a session")
	p:Note("Shows every answer, roll and BiS status live while the raid rolls, so you can see where you stand. Works when the loot master allows watching (Council & officers > Raiders may watch the board, on by default). Without this tick you open it yourself: left-click the minimap button.", "ink3")
	p:Toggle("autoOpen", "As loot master: open the board when I start a session")
	p:Gap(4)
	local pct = function(v) return math.floor(v * 100 + 0.5) .. "%" end
	p:Slider("uiScale", "Window size", 0.6, 1.3, 0.05, pct, function() UI:ApplyScale() end)
	p:Slider("cardScale", "Roll card size", 0.6, 1.3, 0.05, pct, function() UI:ApplyScale() end)
	p:Slider("cardsVisible", "Cards shown at once", 1, 8, 1, function(v) return tostring(v) end, function() local lf = addon:GetModule("BRCLootFrame", true) if lf and lf.frame and lf.frame:IsShown() then lf:Update() end end, 3)
	p:Note("Roll cards and \"you won\" cards queue; the rest wait behind a \"+N more\" button that opens them all.", "ink3")
	p:Note("Smaller screens: shrink the windows and the roll cards here (applied when you let go of the slider).", "ink3")
	p:Toggle(nil, "Show the minimap button", function() return not addon.Main:MinimapDB().mmHide end, function(on) addon.Main:ShowMinimap(on) end)
	p:Toggle(nil, "Active (untick to switch betterRCLC off until the next /reload)", function() return addon.enabled end, function()
		addon.enabled = not addon.enabled
		if not addon.enabled and addon.isMasterLooter then
			addon.isMasterLooter = false
			addon.masterLooter = nil
			addon:GetActiveModule("masterlooter"):Disable()
		else
			addon:NewMLCheck()
		end
	end)
end

function BUILD.pug(p)
	p:Title("Pug rolls")
	p:Note("For groups where most people don't have the addon. Turn it on with General > Use as loot master > Pug rolls. As master looter, every item at or above the loot threshold goes into the Pug loot window; press Roll and the addon announces it, reads the /rolls from chat and shows the winner. Soft reserved items: only the reservers roll (/roll 100, +SR bonus). Otherwise main spec rolls /roll 100, off spec /roll 99. Bag items: /brc roll <item link>.")
	p:Choice("pugTimer", "Roll time", {{10, "10 s"}, {15, "15 s"}, {20, "20 s"}, {30, "30 s"}},
		function() return P().pugTimer or 15 end)
	p:Toggle("pugPlusOne", "+1 rule: players with fewer main-spec wins this raid beat higher rolls")
	p:Note("Main-spec wins are counted from your gives this raid (SR, OS, raid roll and disenchant do not count) and forgotten after 6 hours without a give.", "ink3")
	p:Buttons({{"Open pug loot window", function() S.frame:Hide() addon.Pug:Open() end},
		{"Reset +1 counts", function() addon.Pug:ResetPlus() end, "quiet"},
		{"Soft reserves...", function() addon.Rolls:OpenImport() end}})
end

function BUILD.about(p)
	p:Title("About")
	p:Note(function() return "betterRCLC " .. (addon.version or "?") .. " (guild loot council, based on RCLootCouncil 2.0.4)" end, "ink")
	p:Note("Version check lists who in the raid or guild has betterRCLC and which version. Players without the addon never get roll cards.")
	p:Buttons({{"Version check", function() addon:CallModule("version") end}})
	p:Note("Commands: /brc (main window), /brc config (this window), /brc spec, /brc bis, /brc sr, /brc pug, /brc minimap.", "ink3")
	p:Gap(6)
	p:Note("Found a bug or want something changed? Contact |cffdca77fBabumbus|r on Discord: |cffdca77fdamienapril|r", "ink")
end

function BUILD.specs(p)
	p:Title("My specs")
	p:Note("The loot council sees which spec you roll for and where the item is on the guild BiS list for it. Auto uses your talent tree. Tanks and feral bears pick their spec here.")
	p:Choice(nil, "Main spec", SpecOptions(), function() return addon.db.char.msSpec or "auto" end,
		function(v) addon.db.char.msSpec = v ~= "auto" and v or nil BIS:SendMine() end)
	p:Gap(4)
	Label(p, "Off specs")
	p.y = p.y - 22
	p:Note("Tick every spec you would also roll off spec for. Roll cards only suggest OS (amber chip, OS button lit) for items on those lists. Tick none if you never roll off spec. Auto = your other dual spec.", "ink3")
	p:Toggle(nil, "Auto (my other dual spec)", function() return BIS:OSMode() == "auto" end,
		function(on) BIS:SetOS(on and "auto" or "none") p:Refresh() end)
	for _, name in ipairs(BIS.SPECS[addon.playerClass] or {}) do
		local key = addon.playerClass .. ":" .. name
		p:Toggle(nil, "  " .. name, function() local m = BIS:OSMode() return m ~= "auto" and m[key] == true end,
			function(on) BIS:SetOS(key, on) p:Refresh() end)
	end
	p:Note(function()
		local ms, _, oss = BIS:MySpecs()
		return "Rolling as main spec |cffdca77f" .. BIS:SpecName(ms) .. "|r, off specs |cffdca77f" .. BIS:SpecNames(oss) .. "|r."
	end, "ink")
end

function BUILD.cards(p)
	p:Title("Roll cards")
	p:Note("When the loot master starts a session you get one card per item: the item, what you wear in that slot (item level difference and EP gain for your main spec), and a chip if the item is on your BiS list (green = BiS, amber = off-spec list). The button that fits your list is already highlighted; click an answer or Pass. The note box sends a short note to the council.")
	p:Toggle("bisFx", "Animate BiS cards (glowing icon and background, flash when the card appears)")
	p:Gap(4)
	p:Toggle("autoPass", "Pass automatically on items my class can't use")
	p:Note("Off by default: the class filter is loose and hid items some players could roll on. Turn it on only if you want fewer cards. Soft reserved items you did not reserve are always passed for you.", "ink3")
	p:Toggle("autoPassBoE", "  ...also on bind-on-equip items")
	p:Toggle("silentAutoPass", "  ...without a chat line")
end

function BUILD.history(p)
	p:Title("Loot history")
	p:Toggle("enableHistory", "Keep the loot history the loot master sends")
	p:Toggle("sendHistory", "Send my awards to the raid (as loot master)")
	p:Gap()
	local b = p:Buttons({{"Open history", function() addon:CallModule("history") end},
		{"Export CSV", function() addon:GetModule("BRCLootHistory"):ShowExport() end}, {"Clear history", nil, "quiet"}})
	b[3].button:SetScript("OnClick", function(btn)
		addon:GetModule("BRCVotingFrame"):Confirm(btn, "Delete every entry?", function() wipe(addon.lootDB.factionrealm) addon:Print("Loot history cleared.") end)
	end)
end

function BUILD.rules(p)
	p:Title("Loot rules")
	p:Note("Board order: BiS > Upgrade > OS. Inside a step the highest roll wins, whoever has won before. The first player of the highest step with an answer is pre-selected; click someone else to override. You award; the addon only sorts. Raiders answer BiS (rolls 1-100), Upgrade (1-98) or OS (1-99); the buttons are the same for everyone.")
	p:Gap(4)
	p:Choice("lootMode", "Loot goes", {{"window", "Stays on corpse"}, {"bags", "To my bags, roll now"}, {"batch", "To my bags, roll later"}})
	p:Note("Stays on corpse: award straight from the boss's loot window. To my bags: you loot everything first and trade it to the winners (2 hours); 'roll later' keeps the items in the Loot tab until you start a session.", "ink3")
	p:Toggle("autoStart", "Start the session by itself after looting")
	p:Toggle("autoLoot", "Put equippable items on the list automatically")
	p:Toggle("autolootBoE", "  ...including bind-on-equip items")
	p:Toggle("altClickLooting", "Alt+click a loot slot to add it by hand")
	p:Toggle("autoLootMats", "Loot recipes and Runed Orbs to me when I open a corpse (they never get a session)")
	p:Gap(4)
	p:Toggle("lootFrameTimerEnabled", "Answer timer: unanswered roll cards pass by themselves")
	p:Slider("lootFrameTimerDuration", "  Time to answer", 10, 180, 5, function(v) return v .. " s" end, function() Changed("lootFrameTimerDuration") end)
	p:Toggle("autoCouncil", "Auto-award: give each item to the top of the board when everyone answered or the answer timer ran out")
	p:Note("Top of the board = BiS, then Upgrade, then OS, highest roll first (a tie is a random pick). Nobody wants it: sent to your disenchanter. Without the answer timer it waits until every raider has answered. If you click a player on an item yourself, that item is left to you. Works for items on the corpse and for items in your bags (Loot goes: To my bags). A give the server refuses marks the item orange on the board.", "ink3")
	p:Toggle("autoCouncilMsgs", "  Print each auto-award in my chat")
	p:Toggle("expiryWarn", "Warn once per item when its trade window has 15 minutes left (awarded, disenchant, not yet awarded)")
	p:Toggle("autoTrade", "Start trades by myself: ask a winner for a trade when they are in range and items wait for them")
	p:Slider("autoTradeDelay", "  Seconds in range first", 1, 15, 1, function(v) return v .. " s" end)
	p:Note("The request is sent once per player every 10 s and never while a trade window is open (combat is fine). Both of you still press Accept. Untested: the client may block InitiateTrade for addons.", "ink3")
	p:Toggle("chatRolls", "Rolls in raid chat (/roll)")
	p:Note("Off (default): your addon rolls for every answer and sends the numbers to the board, nothing appears in chat. On: each raider's client does a visible /roll with the range of the button they clicked.", "ink3")
	p:Choice("upgradeMode", "Upgrade column", {{"ep", "EP (stat weights)"}, {"ilvl", "Item level"}})
	p:Note("EP = how much the item adds over what the raider wears, with wowsims stat weights for their main spec (trinket procs and set bonuses are not valued).", "ink3")
	p:Field("disenchanter", "Disenchant to", 160)
	p:Field("banker", "Bank to", 160)
	p:Note(function() return addon.Rolls:Summary() end, "ink")
	p:Buttons({{"Import soft reserves", function() addon.Rolls:OpenImport() end}, {"Clear soft reserves", function() addon.Rolls:Clear() p:Refresh() end, "quiet"}})
	p:Toggle("autoAward", "Award low items automatically")
	p:Field("autoAwardTo", "  to", 160)
end

local function BlockedText()
	local names, out = {}, {}
	for name in pairs(P().blocked) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local reason = P().blocked[name]
		out[#out + 1] = reason ~= "" and (name .. " " .. reason) or name
	end
	return table.concat(out, "\n")
end

local function SetBlocked(v)
	local blocked = {}
	for line in v:gmatch("[^\r\n]+") do
		local name, reason = line:match("^%s*([^%s,:%-]+)[%s,:%-]*(.-)%s*$")
		if name then blocked[name] = reason or "" end
	end
	P().blocked = blocked
	Changed("blocked")
end

function BUILD.council(p)
	p:Title("Council & officers")
	p:Lines("Council (one name per line)", 70, function() return table.concat(P().council, "\n") end, function(v)
		local t = {}
		for name in v:gmatch("[^%s,]+") do t[#t + 1] = name end
		P().council = t
		addon:CouncilChanged()
	end, "or add guild ranks:")
	local rankBtn = UI:Button(p.frame, "Ranks...", nil, 22, "default", function(b)
		GuildRoster()
		local items = {{text = "Everyone at or above", title = true}}
		for i = 1, GuildControlGetNumRanks() do
			items[#items + 1] = {text = i .. " - " .. GuildControlGetRankName(i), checked = P().minRank == i,
				func = function() P().minRank = i addon:AddGuildRanksToCouncil(i) p:Refresh() end}
		end
		UI:Menu(b, items)
	end)
	rankBtn:SetPoint("TOPLEFT", 200, p.y + ROW)
	p:Toggle("councilVotes", "Officers vote on the board (you still award)")
	p:Toggle("selfVote", "  Allow votes for yourself")
	p:Toggle("multiVote", "  Allow more than one vote per item")
	p:Toggle("anonymousVoting", "  Anonymous votes")
	p:Toggle("observe", "Raiders may watch the board (they see every answer and roll; only the council votes)")
	p:Note("With this on, raiders who tick General > Open the council board get it as soon as you start a session; the others can open it from their minimap button.", "ink3")
	p:Lines("Blocked players (\"Name reason\" per line)", 70, BlockedText, SetBlocked, "no loot popup, shown at the bottom")
end

local CHANNELS = {{"group", "Group"}, {"RAID_WARNING", "Raid warning"}, {"GUILD", "Guild"}, {"OFFICER", "Officer"}, {"NONE", "Off"}}
function BUILD.announce(p)
	p:Title("Announcements")
	p:Toggle("announceAward", "Announce awards")
	p:Choice(nil, "  Channel", CHANNELS, function() return P().awardText[1].channel end, function(v) P().awardText[1].channel = v end)
	p:Field(nil, "  Message", 360, false, function() return P().awardText[1].text end, function(v) P().awardText[1].text = v end)
	p:Note("&p = player, &i = item, &r = answer.", "ink3")
	p:Toggle("announceItems", "Announce the items at the start of a session")
	p:Choice("announceChannel", "  Channel", CHANNELS)
	p:Field("announceText", "  Message", 360)
end


------------------------------------------------------------------------
-- BiS editor
------------------------------------------------------------------------
local SLOT_ORDER = {"Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet",
	"Finger", "Finger", "Trinket", "Trinket", "Main Hand", "Off Hand", "Ranged"}
local MAX_ALTS = 7

S.bis = {class = nil, spec = nil, sel = nil} -- sel = {row, col}

function S:BisKey()
	local b = self.bis
	b.class = b.class or addon.playerClass
	if not b.spec or not tContains(BIS.SPECS[b.class], b.spec) then b.spec = BIS.SPECS[b.class][1] end
	return b.class .. ":" .. b.spec
end

--- Editor rows: one per SLOT_ORDER position, filled from the list (n-th ring line = n-th ring row); extra lines kept.
function S:BisRows()
	local entries = BIS:Parse(BIS:Own().specs[self:BisKey()])
	local rows, used, n = {}, {}, {}
	for i, slot in ipairs(SLOT_ORDER) do
		n[slot] = (n[slot] or 0) + 1
		local k = 0
		for j, e in ipairs(entries) do
			if e.slot == slot and not used[j] then
				k = k + 1
				if k == 1 then used[j] = true rows[i] = {slot = slot, ids = e.ids, eq = e.eq} break end
			end
		end
		rows[i] = rows[i] or {slot = slot, ids = {}, eq = {}}
	end
	for j, e in ipairs(entries) do if not used[j] then rows[#rows + 1] = e end end
	return rows
end

function S:SaveBisRows(rows)
	BIS:Own().specs[self:BisKey()] = BIS:Serialize(rows)
	BIS:Touch()
	self:RefreshBis()
end

--- Sets (or appends at col = #ids + 1) an item in a row; id nil removes it.
function S:SetBisItem(row, col, id)
	local rows = self:BisRows()
	local r = rows[row]
	if not r then return end
	if id then
		r.ids[col] = id
	else
		table.remove(r.ids, col)
		local eq = {}
		for i = 1, #r.ids + 1 do if i < col then eq[i] = r.eq[i] elseif i > col then eq[i - 1] = r.eq[i] end end
		eq[1] = nil -- the first id is the BiS itself, never "equal to BiS"
		r.eq = eq
	end
	self:SaveBisRows(rows)
end

function S:ToggleEqual(row, col)
	if col <= 1 then return end
	local rows = self:BisRows()
	local r = rows[row]
	if r and r.ids[col] then r.eq[col] = not r.eq[col] or nil self:SaveBisRows(rows) end
end

local function ItemFromText(text)
	return tonumber((text or ""):match("item:(%d+)") or (text or ""):match("^%s*(%d+)%s*$"))
end

local function CursorItem()
	local kind, id = GetCursorInfo()
	if kind == "item" then ClearCursor() return id end
end

function BUILD.bis(p)
	local f = p.frame
	p:Title("BiS lists")
	local force = UI:Check(f, "Force my lists on the raid (loot master; only while raiders are in my group)", function(on)
		P().forceBis = on
		Changed("forceBis")
	end)
	force:SetPoint("TOPLEFT", 140, p.y + 22)
	table.insert(p.refresh, function() force:SetChecked(P().forceBis) end)
	local class = UI:Button(f, "", nil, 22, "default", function(b)
		local items = {}
		for _, c in ipairs(BIS.CLASS_ORDER) do
			items[#items + 1] = {text = BIS:ClassName(c), checked = S.bis.class == c, func = function() S.bis.class, S.bis.spec = c, nil S.bis.sel = nil S:RefreshBis(true) end}
		end
		UI:Menu(b, items)
	end)
	class:SetPoint("TOPLEFT", 20, p.y)
	S.bis.classBtn = class
	S.bis.specHolder = CreateFrame("Frame", nil, f)
	S.bis.specHolder:SetPoint("LEFT", class, "RIGHT", 8, 0)
	S.bis.specHolder:SetSize(10, 22)
	local imp = UI:Button(f, "Import...", nil, 22, "default", function() S:OpenImport() end)
	imp:SetPoint("TOPRIGHT", -20, p.y)
	local copy = UI:Button(f, "Copy all", nil, 22, "default", function() S:ShowText("Guild export", BIS:ExportGuild(),
		"Every list, the council and the block list. Another officer pastes it into Import.") end)
	copy:SetPoint("RIGHT", imp, "LEFT", -6, 0)
	p.y = p.y - 32

	S.bis.list = UI:List(f, 30, function(list)
		local r = CreateFrame("Frame", nil, list)
		r.label = UI:Text(r, 12, "ink2")
		r.label:SetPoint("LEFT", 20, 0)
		r.icons = {}
		for i = 1, MAX_ALTS do
			local ic = UI:Icon(r, 26)
			ic:SetPoint("LEFT", 110 + (i - 1) * 34, 0)
			ic:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			ic.eq = UI:Text(ic, 11, "ok")
			ic.eq:SetPoint("BOTTOMRIGHT", 2, -2)
			ic:SetScript("OnClick", function(self, button)
				local id = CursorItem()
				if id then return S:SetBisItem(r.index, i, id) end
				if button == "RightButton" then return S:ToggleEqual(r.index, i) end
				if IsModifiedClick() and self.link then return HandleModifiedItemClick(self.link) end
				S.bis.sel = {r.index, i}
				S:RefreshBis()
			end)
			ic:SetScript("OnReceiveDrag", function() local id = CursorItem() if id then S:SetBisItem(r.index, i, id) end end)
			r.icons[i] = ic
		end
		r.add = UI:Button(r, "+", 26, 26, "default", function()
			local id = CursorItem()
			local n = #(S:BisRows()[r.index].ids)
			if id then return S:SetBisItem(r.index, n + 1, id) end
			S.bis.sel = {r.index, n + 1}
			S:RefreshBis()
		end)
		r.add:SetScript("OnReceiveDrag", function() local id = CursorItem() if id then S:SetBisItem(r.index, #(S:BisRows()[r.index].ids) + 1, id) end end)
		return r
	end, function(r, row, index)
		r.index = index
		r.label:SetText(row.slot == "Finger" and "Ring" or row.slot)
		local sel = S.bis.sel
		for i, ic in ipairs(r.icons) do
			local id = row.ids[i]
			if id then
				ic:SetItem(id)
				ic.eq:SetText(row.eq[i] and "=" or "")
				ic:Show()
				if sel and sel[1] == index and sel[2] == i then ic:SetBackdropBorderColor(unpack(UI:Palette().accent)) end
			else
				ic:Hide()
			end
		end
		r.add:ClearAllPoints()
		r.add:SetPoint("LEFT", 110 + math.min(#row.ids, MAX_ALTS - 1) * 34 + (#row.ids >= MAX_ALTS and 34 or 0), 0)
		if #row.ids >= MAX_ALTS then r.add:Hide() else r.add:Show() end
	end)
	S.bis.list:SetPoint("TOPLEFT", 0, p.y)
	S.bis.list:SetPoint("BOTTOMRIGHT", 0, 76)

	-- edit bar for the selected icon
	local bar = CreateFrame("Frame", nil, f)
	bar:SetPoint("BOTTOMLEFT", 0, 0)
	bar:SetPoint("BOTTOMRIGHT", 0, 0)
	bar:SetHeight(72)
	UI:Panel(bar, "bg2", false, 1)
	bar.what = UI:Text(bar, 12, "ink2")
	bar.what:SetPoint("TOPLEFT", 20, -10)
	bar.edit = UI:Edit(bar, 220, 22, false, "item id or Shift+click a link")
	bar.edit:SetPoint("TOPLEFT", 20, -32)
	local function set()
		local sel = S.bis.sel
		local id = ItemFromText(bar.edit:GetText())
		if sel and id then S:SetBisItem(sel[1], sel[2], id) bar.edit:SetText("") end
	end
	bar.edit.edit:SetScript("OnEnterPressed", function(e) set() e:ClearFocus() end)
	bar.set = UI:Button(bar, "Set", nil, 22, "primary", set)
	bar.set:SetPoint("LEFT", bar.edit, "RIGHT", 6, 0)
	bar.remove = UI:Button(bar, "Remove", nil, 22, "default", function()
		local sel = S.bis.sel
		if sel then S.bis.sel = nil S:SetBisItem(sel[1], sel[2], nil) end
	end)
	bar.remove:SetPoint("LEFT", bar.set, "RIGHT", 6, 0)
	bar.equal = UI:Button(bar, "Equal to BiS", nil, 22, "default", function() local sel = S.bis.sel if sel then S:ToggleEqual(sel[1], sel[2]) end end)
	bar.equal:SetPoint("LEFT", bar.remove, "RIGHT", 6, 0)
	bar.help = UI:Text(bar, 11, "ink3")
	bar.help:SetPoint("TOPRIGHT", -20, -10)
	bar.help:SetText("Drag an item onto an icon. Right-click an alt: equal to BiS.")
	S.bis.bar = bar
	-- Shift+click on an item link anywhere pastes it into the field while it has focus
	if not S.linkHooked and hooksecurefunc then
		S.linkHooked = true
		hooksecurefunc("ChatEdit_InsertLink", function(link)
			if bar.edit.edit:HasFocus() then bar.edit:SetText(link) end
		end)
	end
	table.insert(p.refresh, function() S:RefreshBis(true) end)
end

function S:RefreshBis(specsChanged)
	local b = self.bis
	if not b.list then return end
	local key = self:BisKey()
	b.classBtn:SetLabel(BIS:ClassName(b.class))
	if specsChanged or not b.specSeg or b.specSegClass ~= b.class then
		if b.specSeg then b.specSeg:Hide() end
		local opts = {}
		for _, name in ipairs(BIS.SPECS[b.class]) do opts[#opts + 1] = {name, name} end
		b.specSeg = UI:Segmented(b.specHolder, opts, function(v) b.spec = v b.sel = nil self:RefreshBis() end, 22)
		b.specSeg:SetPoint("LEFT", 0, 0)
		b.specSegClass = b.class
	end
	b.specSeg:Select(b.spec)
	local rows = self:BisRows()
	b.list:SetData(rows)
	local sel = b.sel
	local bar = b.bar
	if sel and rows[sel[1]] then
		local r = rows[sel[1]]
		local id = r.ids[sel[2]]
		local name = id and (GetItemInfo(id) or ("item " .. id)) or "new alternative"
		bar.what:SetText((r.slot == "Finger" and "Ring" or r.slot) .. " · " .. (sel[2] == 1 and "BiS" or ("alt " .. sel[2])) .. ": " .. name)
		for _, w in ipairs({bar.edit, bar.set, bar.remove, bar.equal}) do w:Show() end
		if not id then bar.remove:Hide() end
		if sel[2] == 1 or not id then bar.equal:Hide() else bar.equal:SetActive(r.eq[sel[2]]) end
	else
		bar.what:SetText("Click an icon to change it, or + to add an alternative.")
		for _, w in ipairs({bar.edit, bar.set, bar.remove, bar.equal}) do w:Hide() end
	end
	local _ = key
end

------------------------------------------------------------------------
-- window
------------------------------------------------------------------------
function S:Open(page)
	if not self.frame then self:Build() end
	self.frame:Show()
	self:ShowPage(page or self.current or "general")
end

function S:Build()
	local f = UI:Window("settings", "betterRCLC settings", W, 600)
	local nav = CreateFrame("Frame", nil, f.body)
	nav:SetPoint("TOPLEFT")
	nav:SetPoint("BOTTOMLEFT")
	nav:SetWidth(NAV_W)
	UI:Panel(nav, "bg2", false, 1)
	f.navButtons = {}
	local y = -12
	for _, n in ipairs(NAV) do
		if not n[2] then
			local t = UI:Text(nav, 11, "ink3")
			t:SetPoint("TOPLEFT", 14, y - 6)
			t:SetText(n[1])
			y = y - 24
		else
			local b = UI:Button(nav, n[2], NAV_W - 16, 22, "quiet", function() self:ShowPage(n[1]) end)
			b.text:ClearAllPoints()
			b.text:SetPoint("LEFT", 10, 0)
			b:SetPoint("TOPLEFT", 8, y)
			f.navButtons[n[1]] = b
			y = y - 24
		end
	end
	self.frame = f
end

function S:ShowPage(key)
	for k, pg in pairs(self.pages) do pg.outer:Hide() end
	local page = self.pages[key]
	if not page then
		page = NewPage(self.frame.body, key ~= "bis")
		BUILD[key](page)
		if key ~= "bis" then page.frame:SetHeight(-page.y + 20) end
		self.pages[key] = page
	end
	page.outer:Show()
	page:Refresh()
	self.current = key
	for k, b in pairs(self.frame.navButtons) do b:SetActive(k == key) end
end

--- Read-only text window (exports): selected, Ctrl+C to copy.
function S:ShowText(title, text, hint)
	local w = self.textWin
	if not w then
		w = UI:Window("text", title, 640, 420, "DIALOG")
		w.box = UI:Edit(w.body, 616, 340, true)
		w.box:SetPoint("TOPLEFT", 12, -12)
		w.hint = UI:Text(w.body, 12, "ink2")
		w.hint:SetPoint("BOTTOMLEFT", 12, 12)
		self.textWin = w
	end
	w:SetTitle(title)
	w.box:SetText(text)
	w.hint:SetText((hint or "") .. "  Ctrl+C to copy.")
	w:Show()
	w.box.edit:SetFocus()
	w.box.edit:HighlightText()
end

------------------------------------------------------------------------
-- import window: paste anything, see what it is and a diff, then save
------------------------------------------------------------------------
--- What a pasted text is: {kind, ...}. Kinds: "sim" (wowsims link/JSON), "guild" (### headers), "list" (Discord/links).
function S:Detect(text)
	if not text or not text:match("%S") then return nil end
	if text:find("^%s*{") or text:find("https?://[^%s]*#") then
		local sim, err = addon.SimImport:Parse(text)
		if not sim then return {kind = "error", msg = "wowsims: " .. err} end
		local entries = BIS:Parse(addon.SimImport:ToText(sim))
		return {kind = "sim", class = sim.class, spec = sim.spec, entries = entries,
			msg = "wowsims " .. (text:find("^%s*{") and "JSON" or "link") .. " found: " .. BIS:ClassName(sim.class) .. " · " .. (sim.spec or "?") .. ", " .. #entries .. " items, gems and enchants ignored"}
	end
	if text:find("###") then
		local specs, errors, extras = BIS:ImportAll(text)
		local n = 0
		for _ in pairs(specs) do n = n + 1 end
		if #errors > 0 then return {kind = "error", msg = errors[1] .. (#errors > 1 and (" (+" .. (#errors - 1) .. " more)") or "")} end
		return {kind = "guild", specs = specs, extras = extras,
			msg = "Guild export: " .. n .. " lists" .. (extras.council and (", council of " .. #extras.council) or "") .. (extras.blocked and (", " .. #extras.blocked .. " blocked") or "")}
	end
	local slotted, unknown = BIS:SlotLinks(text)
	local entries, errors = BIS:Parse(slotted)
	if #errors > 0 or #entries == 0 then
		return {kind = "error", msg = (errors[1] or "nothing recognised") .. (unknown > 0 and (" (" .. unknown .. " item links not cached yet: hover them once and paste again)") or "")}
	end
	return {kind = "list", entries = entries, msg = "List with " .. #entries .. " slots"}
end

function S:OpenImport()
	local w = self.importWin
	if not w then
		w = UI:Window("import", "Import BiS list", 640, 560, "DIALOG")
		w:SetTitle("Import BiS list", "paste anything below")
		w.box = UI:Edit(w.body, 616, 70, true, "wowsims link or JSON, Discord text, item links, or a guild export")
		w.box:SetPoint("TOPLEFT", 12, -12)
		w.box.onChange = function() self:UpdateImport() end
		w.found = UI:Chip(w.body, 11)
		w.found:SetPoint("TOPLEFT", 12, -92)
		w.saveAs = UI:Text(w.body, 12, "ink2")
		w.saveAs:SetPoint("TOPLEFT", 12, -124)
		w.saveAs:SetText("Save as")
		w.class = UI:Button(w.body, "", nil, 22, "default", function(b)
			local items = {}
			for _, c in ipairs(BIS.CLASS_ORDER) do items[#items + 1] = {text = BIS:ClassName(c), func = function() w.target.class, w.target.spec = c, BIS.SPECS[c][1] self:UpdateImport(true) end} end
			UI:Menu(b, items)
		end)
		w.class:SetPoint("TOPLEFT", 70, -120)
		w.spec = UI:Button(w.body, "", nil, 22, "default", function(b)
			local items = {}
			for _, s in ipairs(BIS.SPECS[w.target.class]) do items[#items + 1] = {text = s, func = function() w.target.spec = s self:UpdateImport(true) end} end
			UI:Menu(b, items)
		end)
		w.spec:SetPoint("LEFT", w.class, "RIGHT", 6, 0)
		w.mode = UI:Segmented(w.body, {{"replace", "Replace the list"}, {"alts", "Add as alternatives"}}, function(k) w.target.mode = k end, 22)
		w.mode:SetPoint("TOPRIGHT", -12, -120)
		w.list = UI:List(w.body, 24, function(list)
			local r = CreateFrame("Frame", nil, list)
			r.slot = UI:Text(r, 12, "ink2")
			r.slot:SetPoint("LEFT", 12, 0)
			r.icon = UI:Icon(r, 20)
			r.icon:SetPoint("LEFT", 92, 0)
			r.name = UI:Text(r, 12, "ink")
			r.name:SetPoint("LEFT", 120, 0)
			r.name:SetWidth(360)
			r.chip = UI:Chip(r, 10)
			r.chip:SetPoint("RIGHT", -12, 0)
			return r
		end, function(r, item)
			r.slot:SetText(item.slot == "Finger" and "Ring" or item.slot)
			r.icon:SetItem(item.id)
			r.name:SetText(GetItemInfo(item.id) or ("item " .. item.id))
			r.chip:Set(item.status ~= "same" and item.status or "same", item.status == "new" and "ok" or item.status == "changed" and "warn" or "muted")
		end)
		w.list:SetPoint("TOPLEFT", 0, -152)
		w.list:SetPoint("BOTTOMRIGHT", 0, 48)
		w.summary = UI:Text(w.body, 12, "ink2")
		w.summary:SetPoint("BOTTOMLEFT", 12, 16)
		w.import = UI:Button(w.body, "Import", nil, 26, "primary", function() self:DoImport() end)
		w.import:SetPoint("BOTTOMRIGHT", -12, 10)
		w.cancel = UI:Button(w.body, "Cancel", nil, 26, "default", function() w:Hide() end)
		w.cancel:SetPoint("RIGHT", w.import, "LEFT", -6, 0)
		self.importWin = w
	end
	w.target = {class = self.bis.class or addon.playerClass, spec = self.bis.spec, mode = "replace"}
	if not w.target.spec then w.target.spec = BIS.SPECS[w.target.class][1] end
	w.box:SetText("")
	w:Show()
	w.box.edit:SetFocus()
	self:UpdateImport()
end

function S:UpdateImport(keepTarget)
	local w = self.importWin
	local d = self:Detect(w.box:GetText())
	w.detected = d
	if d and d.kind == "sim" and not keepTarget then w.target.class, w.target.spec = d.class, d.spec or BIS.SPECS[d.class][1] end
	w.found:Set(d and d.msg, d and (d.kind == "error" and "bad" or "ok"))
	local single = d and (d.kind == "sim" or d.kind == "list")
	for _, x in ipairs({w.saveAs, w.class, w.spec, w.mode}) do if single then x:Show() else x:Hide() end end
	w.class:SetLabel(BIS:ClassName(w.target.class))
	w.spec:SetLabel(w.target.spec)
	w.mode:Select(w.target.mode)
	local rows = {}
	if single then
		local cur = BIS:Own().specs[w.target.class .. ":" .. w.target.spec]
		local status = BIS:Diff(cur, d.entries)
		local counts = {new = 0, changed = 0, same = 0}
		for i, e in ipairs(d.entries) do
			rows[#rows + 1] = {slot = e.slot, id = e.ids[1], status = status[i]}
			counts[status[i]] = counts[status[i]] + 1
		end
		w.summary:SetText(counts.new .. " new, " .. counts.changed .. " changed, " .. counts.same .. " same as the current list")
	elseif d and d.kind == "guild" then
		w.summary:SetText("Replaces the lists it contains" .. (d.extras.council and ", the council" or "") .. (d.extras.blocked and " and the block list" or "") .. ".")
	else
		w.summary:SetText("")
	end
	w.list:SetData(rows)
	if d and d.kind ~= "error" then w.import:Enable() else w.import:Disable() end
end

function S:DoImport()
	local w = self.importWin
	local d = w.detected
	if not d or d.kind == "error" then return end
	local own = BIS:Own()
	if d.kind == "guild" then
		for k, v in pairs(d.specs) do own.specs[k] = v:match("%S") and v or nil end
		if d.extras.council then
			local t = {}
			for _, x in ipairs(d.extras.council) do t[#t + 1] = x[1] end
			P().council = t
			addon:CouncilChanged()
		end
		if d.extras.blocked then
			local b = {}
			for _, x in ipairs(d.extras.blocked) do b[x[1]] = x[2] or "" end
			P().blocked = b
			Changed("blocked")
		end
		addon:Print("Guild export imported.")
	else
		local key = w.target.class .. ":" .. w.target.spec
		own.specs[key] = w.target.mode == "alts" and BIS:MergeAlternatives(own.specs[key], d.entries) or BIS:Serialize(d.entries)
		self.bis.class, self.bis.spec = w.target.class, w.target.spec
		addon:Print("Imported the " .. BIS:ClassName(w.target.class) .. " " .. w.target.spec .. " list.")
	end
	BIS:Touch()
	w:Hide()
	if self.frame and self.frame:IsShown() and self.current == "bis" then self:RefreshBis(true) end
end
