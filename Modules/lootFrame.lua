-- lootFrame.lua  Roll cards: what every raider sees when a session starts (like group-loot roll frames: glance,
-- click, keep pulling). One compact card per item, stacked top right (3 at once, "show all" for the rest):
--   left: the item (icon, name, slot · type · ilvl) and its list chip (BiS / alt / off-spec BiS / SR);
--   top right: what I wear in that slot (icons, ilvl difference under each) and the EP gain;
--   bottom: BiS / Upgrade / OS / Pass and a note field; soft-reserved items: Roll (SR) / Pass.
-- Answering rolls for you (MS 100, OS 99, Upgrade 98, SR 100; Modules/rolls.lua). Main-spec BiS cards pulse.
-- Same module API as RCLC's loot frame (Start / ReRoll), so core.lua's comms are unchanged.

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local LootFrame = addon:NewModule("BRCLootFrame", "AceTimer-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("betterRCLC")
local LibToken = LibStub("LibArmorToken-1.0")
local UI = addon.UI

local CARD_W, CARD_H, GAP = 330, 82, 5 -- buttons + note sit right under the icon row
local function Visible() return addon.db.profile.cardsVisible or 3 end -- cards shown before "+N more" (setting)

-- items also holds award cards ({award = true, link, text, trade, from}) after the roll items: "you won this", dismissed by hand.
local items = {} -- [session index] = {name, link, ilvl, texture, rolled, note, session, equipLoc, time, sr}
local cards = {}

------------------------------------------------------------------------
-- data
------------------------------------------------------------------------
local function NewItem(t, session)
	return {name = t.name, link = t.link, ilvl = t.ilvl, texture = t.texture, rolled = false,
		session = session, sid = t.sid, equipLoc = t.equipLoc, sr = t.sr and t.sr[addon.playerName] ~= nil or nil,
		srPlus = t.sr and t.sr[addon.playerName]}
end

--- The award cards in items (they outlive a session: new rolls queue in front of them).
local function Awards()
	local keep = {}
	for _, v in ipairs(items) do if v.award then keep[#keep + 1] = v end end
	return keep
end

function LootFrame:Start(table)
	addon:DebugLog("LootFrame:Start()")
	local keep = Awards()
	wipe(items)
	for k = 1, #table do
		if table[k].autopass then
			items[k] = {rolled = true} -- autopassed (or someone else's soft reserve): no card
		else
			items[k] = NewItem(table[k], k)
		end
	end
	for _, a in ipairs(keep) do items[#items + 1] = a end
	self.showAll = false
	self:Show()
end

--- The loot master awarded me an item: a card at the end of the queue (trade = I have to get it from them).
function LootFrame:AddAward(from, link, text, trade)
	if not link then return end
	local name, _, quality, ilvl = GetItemInfo(link)
	tinsert(items, {award = true, link = link, name = name, text = text, trade = trade, from = from, rolled = false})
	self:Show()
end

--- The loot master moved an item to another player: my award card for it goes.
function LootFrame:RemoveAward(link)
	for i = #items, 1, -1 do
		if items[i].award and items[i].link == link then tremove(items, i) end
	end
	if self.frame then self:Update() end
end

function LootFrame:ReRoll(table)
	for _, v in ipairs(table) do tinsert(items, NewItem(v, v.session)) end
	self:Show()
end

function LootFrame:OnEnable()
	self.frame = self:GetFrame()
end

function LootFrame:OnDisable() -- the session ended: roll cards go, award cards stay until dismissed
	local keep = Awards()
	wipe(items)
	for _, a in ipairs(keep) do items[#items + 1] = a end
	self:CancelAllTimers()
	if #keep > 0 then self:Update() elseif self.frame then self.frame:Hide() end
end

function LootFrame:Show()
	self.frame:Show()
	self:Update()
	self:CancelAllTimers()
	self:ScheduleRepeatingTimer("Tick", 0.2) -- no-op (and cancels itself) if the ML has the timer off
end

--- What the card says about an item for me: list chip, which answer to highlight, worn gear, EP, glow.
function LootFrame:Describe(item)
	local d = {}
	local id = addon:GetItemIDFromLink(item.link)
	local _, _, quality, _, _, itemType, subType, _, equipLoc = GetItemInfo(item.link)
	d.quality = quality
	equipLoc = (equipLoc and equipLoc ~= "") and equipLoc or item.equipLoc
	local token = id and LibToken:ItemIsToken(id)
	local slotName = token and "Token" or (equipLoc and _G[equipLoc]) or itemType or ""
	local kind = (not token and subType and subType ~= slotName and subType ~= "Miscellaneous") and subType or nil
	d.sub = UI.Join(" · ", slotName, kind, item.ilvl and ("ilvl " .. item.ilvl))

	local slot = (equipLoc and equipLoc ~= "") and equipLoc or (id and BRCTokenTable and BRCTokenTable[id])
	d.g1, d.g2 = addon:GetPlayersGear(item.link, slot)
	local g1id, g2id = d.g1 and addon:GetItemIDFromLink(d.g1), d.g2 and addon:GetItemIDFromLink(d.g2)
	local _, class = UnitClass("player")
	d.same = (id and (id == g1id or id == g2id)) or (token and g1id and LibToken:FindTokenForItemByClass(g1id, class) == id) or false

	if item.sr then
		d.chip, d.chipKind, d.glow = "Soft reserved" .. ((item.srPlus or 0) > 0 and (" +" .. item.srPlus) or ""), "accent", "accent"
	else
		-- off-spec suggestions only for the off specs I ticked (none ticked = never)
		local ms, _, oss = addon.BIS:MySpecs()
		local s, onOS, os = addon.BIS:Status(ms, id), false, nil
		if not s then
			os, s = addon.BIS:BestStatus(oss, id)
			onOS = s ~= nil
		end
		if s then
			local spec = addon.BIS:SpecName(onOS and os or ms)
			d.chip = (onOS and "OS " or "") .. (s.bis and "BiS" or ("alt " .. s.rank)) .. " · " .. spec
			d.chipKind = onOS and "warn" or (s.bis and "ok" or "accent")
			d.suggest = addon:ButtonOf(onOS and "os" or "ms")
			d.glow = (not onOS and s.bis) and "ok" or (onOS and s.bis and "warn") or nil
		end
	end
	d.ep = addon.Upgrade:EP((addon.BIS:MySpecs()), item.link)
	return d
end

local function IlvlOf(link)
	return link and select(4, GetItemInfo(link))
end

------------------------------------------------------------------------
-- frames
------------------------------------------------------------------------
function LootFrame:GetFrame()
	if self.frame then return self.frame end
	local f = CreateFrame("Frame", "BRCRollCards", UIParent)
	f:SetScale(UI:CardScale()) -- the "Roll cards" size setting (before the cards exist)
	UI.cards = f
	f:SetSize(CARD_W, 16)
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	local pos = addon.db.profile.ui and addon.db.profile.ui.cards
	if pos then f:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3]) else f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -240, -170) end
	local head = CreateFrame("Frame", nil, f) -- drag handle: the small title above the cards
	head:SetPoint("TOPLEFT")
	head:SetPoint("TOPRIGHT")
	head:SetHeight(16)
	head:EnableMouse(true)
	head:RegisterForDrag("LeftButton")
	head:SetScript("OnDragStart", function() f:StartMoving() end)
	head:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
		local point, _, _, x, y = f:GetPoint()
		addon.db.profile.ui = addon.db.profile.ui or {}
		addon.db.profile.ui.cards = {point, x, y}
	end)
	head.text = UI:Text(head, 11, "ink2")
	head.text:SetPoint("LEFT", 2, 0)
	f.head = head
	f.more = UI:Button(f, "", nil, 18, "quiet", function() self.showAll = not self.showAll self:Update() end)
	f:Hide()
	return f
end

-- coloured edge around a card: pulsing for main-spec BiS, static for OS BiS and soft reserves
-- Main-spec BiS ("ok", setting bisFx on) also gets: a pulsing proc glow around the item icon (3.3.5's action-button
-- border art, additive), the card background breathing in the same colour (fainter than the edge) and a green flash
-- when the card first shows that item. OS BiS ("warn"): steady amber icon glow + faint amber background.
-- All driven by the glow frame's OnUpdate (only while shown). 0.4.7: the light sweep was too much, removed.
local PROC = "Interface\\Buttons\\UI-ActionButton-Border"
local BG_MIN, BG_MAX = 0.03, 0.11 -- background tint alpha range (the edge pulses 0.45-1)

local function Effects(c)
	if c.fx then return c.fx end
	local fx = {}
	fx.icon = c:CreateTexture(nil, "OVERLAY")
	fx.icon:SetTexture(PROC)
	fx.icon:SetBlendMode("ADD")
	fx.icon:SetSize(76, 76) -- the art's glow ring sits inside its square: ~1.9x the 40 px icon
	fx.icon:SetPoint("CENTER", c.icon, "CENTER", 0, 0)
	fx.bg = c:CreateTexture(nil, "BORDER")
	fx.bg:SetTexture(UI.FLAT)
	fx.bg:SetBlendMode("ADD")
	fx.bg:SetPoint("TOPLEFT", 1, -1)
	fx.bg:SetPoint("BOTTOMRIGHT", -1, 1)
	fx.flash = c:CreateTexture(nil, "ARTWORK")
	fx.flash:SetTexture(UI.FLAT)
	fx.flash:SetBlendMode("ADD")
	fx.flash:SetPoint("TOPLEFT", 1, -1)
	fx.flash:SetPoint("BOTTOMRIGHT", -1, 1)
	c.fx = fx
	return fx
end

local function HideEffects(c)
	if not c.fx then return end
	for _, t in pairs(c.fx) do t:Hide() end
end

local function Glow(c, kind, itemKey)
	if not kind then c.glow:Hide() c.glow:SetScript("OnUpdate", nil) HideEffects(c) c.fxKey = nil return end
	local col = UI:Palette()[kind]
	local r, g, b = col[1], col[2], col[3]
	c.glow:SetBackdropBorderColor(r, g, b, 1)
	c.glow:Show()
	local fancy = addon.db.profile.bisFx ~= false
	if not fancy then HideEffects(c) end
	if kind ~= "ok" then
		c.glow:SetScript("OnUpdate", nil)
		c.glow:SetAlpha(0.8)
		if fancy then
			local fx = Effects(c)
			HideEffects(c)
			fx.icon:SetVertexColor(r, g, b) fx.icon:SetAlpha(0.6) fx.icon:Show()
			fx.bg:SetVertexColor(r, g, b) fx.bg:SetAlpha(0.06) fx.bg:Show()
		end
		c.fxKey = nil
		return
	end
	local fx = fancy and Effects(c)
	if fx then
		fx.icon:SetVertexColor(r, g, b) fx.icon:Show()
		fx.bg:SetVertexColor(r, g, b) fx.bg:Show()
		fx.flash:SetVertexColor(r, g, b)
	end
	local fresh = itemKey ~= c.fxKey -- a new item on this card: flash once
	c.fxKey = itemKey
	if fresh then c.fxT = 0 end
	c.glow:SetScript("OnUpdate", function(self, e)
		c.fxT = (c.fxT or 0) + e
		local t = c.fxT
		local pulse = math.abs(math.sin(t * 2.6))
		self:SetAlpha(0.45 + 0.55 * pulse)
		if not fx then return end
		fx.icon:SetAlpha(0.35 + 0.65 * pulse)
		fx.bg:SetAlpha(BG_MIN + (BG_MAX - BG_MIN) * pulse)
		local f = 0.45 - t * 1.1 -- flash: from 0.45 to nothing in ~0.4 s
		if f > 0 then fx.flash:SetAlpha(f) fx.flash:Show() else fx.flash:Hide() end
	end)
end

function LootFrame:GetCard(i)
	if cards[i] then return cards[i] end
	local c = CreateFrame("Frame", nil, self.frame)
	c:SetSize(CARD_W, CARD_H)
	UI:Panel(c, "bg", "border", 0.97)
	c:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -16 - (i - 1) * (CARD_H + GAP))
	local m = UI:Mult(c)
	c.glow = CreateFrame("Frame", nil, c)
	c.glow:SetPoint("TOPLEFT", -2 * m, 2 * m)
	c.glow:SetPoint("BOTTOMRIGHT", 2 * m, -2 * m)
	c.glow:SetBackdrop({edgeFile = UI.FLAT, edgeSize = 2 * m})
	c.glow:Hide()

	-- left: icon 40; name, slot line and list chip fill exactly its height (chip bottom = icon bottom)
	c.icon = UI:Icon(c, 40)
	c.icon:SetPoint("TOPLEFT", 8, -8)
	c.name = UI:Text(c, 12, "ink")
	c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 8, 1)
	c.name:SetWidth(CARD_W - 56 - 82)
	c.sub = UI:Text(c, 10, "ink2")
	c.sub:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -1)
	c.sub:SetWidth(CARD_W - 56 - 82)
	c.chip = UI:Chip(c, 9)
	c.chip:SetPoint("BOTTOMLEFT", c.icon, "BOTTOMRIGHT", 8, 0)

	-- right: what I wear (icon 30, ilvl difference inside its bottom right corner), EP gain right under it
	c.worn = {}
	for k = 1, 2 do
		local w = UI:Icon(c, 30)
		w.diff = UI:Text(w, 10, "ink", "RIGHT")
		w.diff:SetFont(UI:Font(), 10, "OUTLINE")
		w.diff:SetShadowOffset(0, 0)
		w.diff:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", -1, 2)
		c.worn[k] = w
	end
	c.worn[1]:SetPoint("TOPRIGHT", -8, -8)
	c.worn[2]:SetPoint("RIGHT", c.worn[1], "LEFT", -4, 0)
	c.gain = UI:Text(c, 10, "ink2", "RIGHT")
	c.gain:SetPoint("TOPRIGHT", -8, -40)
	c.same = UI:Chip(c, 9)
	c.same:SetPoint("TOPRIGHT", -8, -40)

	-- answers + note on one row
	c.buttons = {}
	c.note = UI:Edit(c, 100, 20, false, "Note")
	c.note:SetPoint("BOTTOMRIGHT", -8, 8)
	c.note.onChange = function(text, user)
		local item = c.realID and items[c.realID]
		if item and user ~= false then item.note = text ~= "" and text or nil end
	end
	c.note.edit:SetScript("OnEnterPressed", function(e) e:ClearFocus() end)

	c.timer = UI:Bar(c, 2)
	c.timer:SetPoint("BOTTOMLEFT", 1, 1)
	c.timer:SetPoint("BOTTOMRIGHT", -1, 1)
	cards[i] = c
	return c
end

--- The answer buttons: the ML's buttons (shortened) + Pass, or Roll (SR) + Pass for a soft reserve.
function LootFrame:LayoutButtons(c, item, suggest)
	local list = {}
	if item.sr then
		list = {{"Roll (SR)", 1}, {L["Pass"], "PASS"}}
	else
		for _, k in ipairs(addon.BUTTON_ORDER) do list[#list + 1] = {addon:ShortButtonText(k), k} end -- BiS | Upgrade | OS
		list[#list + 1] = {L["Pass"], "PASS"}
	end
	for k, b in ipairs(c.buttons) do if k > #list then b:Hide() end end
	local last
	for k, e in ipairs(list) do
		local b = c.buttons[k]
		if not b then
			b = UI:Button(c, "", nil, 20, "default")
			c.buttons[k] = b
		end
		b:SetLabel(e[1])
		b:SetWidth(math.max(34, b.text:GetStringWidth() + 14))
		b:SetActive(suggest == e[2] or (item.sr and e[2] == 1))
		b:SetTextTint(addon:AnswerColor(e[2])) -- BiS green, Upgrade blue, OS gold, Pass red (as in BetterRolls)
		b:SetScript("OnClick", function() if c.realID then self:OnRoll(c.realID, e[2]) end end)
		b:ClearAllPoints()
		if k == 1 then b:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 8, 8) else b:SetPoint("LEFT", last, "RIGHT", 3, 0) end
		b:Show()
		last = b
	end
	c.note:ClearAllPoints()
	c.note:SetPoint("LEFT", last, "RIGHT", 6, 0)
	c.note:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -8, 8)
end

--- An award card: what I won, and to get it from the loot master if it is in their bags. One "Got it" button.
function LootFrame:FillAward(c, index, item)
	c.realID = index
	c.icon:SetItem(item.link)
	local _, _, quality = GetItemInfo(item.link)
	local qr, qg, qb = 1, 1, 1
	if quality and GetItemQualityColor then qr, qg, qb = GetItemQualityColor(quality) end
	c.name:SetText(item.name or item.link)
	UI:Recolor(c.name, {qr, qg, qb})
	c.sub:SetText("You won this" .. (item.text and item.text ~= "" and (" · " .. item.text) or ""))
	if item.trade then c.chip:Set("Trade " .. (item.from or "the loot master"), "warn") else c.chip:Set("Sent to your bags", "ok") end
	Glow(c, item.trade and "warn" or "ok", "award" .. index)
	for k = 1, 2 do c.worn[k]:Hide() c.worn[k].diff:Hide() end
	c.same:Set(nil)
	c.gain:SetText("")
	for _, b in ipairs(c.buttons) do b:Hide() end
	c.note:Hide()
	c.timer:Hide()
	if not c.dismiss then
		c.dismiss = UI:Button(c, "Got it", 60, 20, "default")
		c.dismiss:SetPoint("BOTTOMLEFT", 8, 8)
	end
	c.dismiss:SetScript("OnClick", function()
		if c.realID and items[c.realID] and items[c.realID].award then tremove(items, c.realID) end
		self:Update()
	end)
	c.dismiss:Show()
	c:Show()
end

function LootFrame:FillCard(c, index, item)
	if item.award then return self:FillAward(c, index, item) end
	if c.dismiss then c.dismiss:Hide() end
	c.note:Show()
	c.realID = index
	local d = self:Describe(item)
	c.icon:SetItem(item.link)
	c.name:SetText(item.name or item.link)
	local qr, qg, qb = 1, 1, 1
	if d.quality and GetItemQualityColor then qr, qg, qb = GetItemQualityColor(d.quality) end
	UI:Recolor(c.name, {qr, qg, qb})
	c.sub:SetText(d.sub)
	c.chip:Set(d.chip, d.chipKind) -- nothing when the item is on none of my lists
	Glow(c, d.glow, index .. ":" .. tostring(item.link))

	for k, link in ipairs({d.g1 or false, d.g2 or false}) do
		local w = c.worn[k]
		if link then
			w:SetItem(link)
			local il = IlvlOf(link)
			w.diff:SetText((item.ilvl and il) and UI:Signed(item.ilvl - il) or "")
			w:Show() w.diff:Show()
		else
			w:Hide() w.diff:Hide()
		end
	end
	if d.same then
		c.same:Set("same item", "muted")
		c.gain:SetText("")
	else
		c.same:Set(nil)
		c.gain:SetText(d.ep and UI:Signed(d.ep, " EP") or "")
	end

	c.note:SetText(item.note or "")
	self:LayoutButtons(c, item, d.suggest)
	if addon.mldb.lootFrameTimerEnabled then c.timer:Show() c.timer:SetProgress(1) else c.timer:Hide() end
	c:Show()
end

function LootFrame:Update()
	local open = {}
	for k, v in ipairs(items) do
		if not v.rolled then open[#open + 1] = k end
	end
	if #open == 0 then self:Disable() if self.frame then self.frame:Hide() end return end -- Disable is a no-op once the module is off
	local VISIBLE = Visible()
	local max = self.showAll and math.min(#open, 12) or math.min(#open, VISIBLE)
	for i = 1, max do self:FillCard(self:GetCard(i), open[i], items[open[i]]) end
	for i = max + 1, #cards do cards[i]:Hide() cards[i].realID = nil Glow(cards[i], nil) end
	self.frame.head.text:SetText("Loot · " .. #open)
	local more = self.frame.more
	more:ClearAllPoints()
	more:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -16 - max * (CARD_H + GAP))
	if #open > max then
		more:SetLabel("+" .. (#open - max) .. " more")
		more:Show()
	elseif self.showAll and #open > VISIBLE then
		more:SetLabel("show fewer")
		more:Show()
	else
		more:Hide()
	end
	self.frame:SetHeight(16 + max * (CARD_H + GAP))
end

-- Ticks the per item timer down and auto passes anything that expired.
function LootFrame:Tick()
	if not addon.mldb.lootFrameTimerEnabled then
		self:CancelAllTimers()
		return
	end
	local duration = math.max(addon.mldb.lootFrameTimerDuration or 30, 1)
	for _, c in ipairs(cards) do
		local item = c:IsShown() and c.realID and items[c.realID]
		if item and not item.rolled and not item.award then
			item.time = item.time or GetTime()
			local remaining = duration - (GetTime() - item.time)
			if remaining <= 0 then
				self:OnRoll(c.realID, "PASS")
				if not addon.db.profile.silentAutoPass then
					addon:Print(format(L["Autopassed on 'item'"], item.link))
				end
				return -- OnRoll re-laid the cards out
			end
			c.timer:SetProgress(remaining / duration, remaining < 10)
		end
	end
end

--- Answer a card: send the response, then roll for it (MS 100 / OS 99 / Upgrade 98 / SR 100).
function LootFrame:OnRoll(index, button)
	local item = items[index]
	if not item or item.rolled then return end
	local ses, name, t = addon:CreateResponse(item.session, item.link, item.ilvl, button, item.equipLoc, item.note)
	t.sr = item.sr
	addon:SendCommand("group", "response", ses, name, t)
	addon:RecordAnswer(item.sid, ses, item.link, {ses, name, t})
	item.rolled = true
	-- rolls in chat (ML option): my client /rolls and reports it; otherwise the loot master's addon rolls for me
	local max = item.sr and button == 1 and 100 or addon:ButtonRoll(button)
	if max and addon.mldb.chatRolls then addon.Rolls:Roll(item.session, max) end
	self:Update()
end

--- The loot master asks me to roll again for a tie: one button, the roll is sent like an answer roll.
function addon:ShowRollPrompt(link, session)
	local f = self.rollPrompt
	if not f then
		f = UI:Window("rollprompt", "Tie", 300, 96, "DIALOG")
		f.text = UI:Text(f.body, 12, "ink")
		f.text:SetPoint("TOPLEFT", 12, -10)
		f.text:SetPoint("RIGHT", f.body, "RIGHT", -12, 0)
		f.text:SetWordWrap(true)
		f.roll = UI:Button(f.body, "Roll", 90, 24, "primary")
		f.roll:SetPoint("BOTTOMLEFT", 12, 10)
		self.rollPrompt = f
	end
	f.roll:SetScript("OnClick", function() addon.Rolls:Roll(session, 100) f:Hide() end)
	f.text:SetText("Tied for " .. (link or "an item") .. ": roll again.")
	f:Show()
end
