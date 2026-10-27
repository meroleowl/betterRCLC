--[[	betterRCLC by Potdisc
ml_core.lua	Contains core elements for the MasterLooter
	-	Although possible, this module shouldn't be replaced unless closely replicated as other default modules depend on it.
	-	Assumes several functions in SessionFrame and VotingFrame

	TODOs/NOTES:
		- SendMessage() on AddItem() to let userModules know it's safe to add to lootTable. Might have to do it other places too.
]]

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
betterRCLCML = addon:NewModule("betterRCLCML", "AceEvent-3.0", "AceBucket-3.0", "AceComm-3.0", "AceTimer-3.0", "AceHook-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("betterRCLC")
local LibDialog = LibStub("LibDialog-1.0")
local Deflate = LibStub("LibDeflate")

local db;

function betterRCLCML:OnInitialize()
	addon:Debug("ML initialized!")
end

function betterRCLCML:OnDisable()
	addon:Debug("ML Disabled")
	self:UnregisterAllEvents()
	self:UnregisterAllBuckets()
	self:UnregisterAllComm()
	self:UnregisterAllMessages()
	self:UnhookAll()
end

function betterRCLCML:OnEnable()
	addon:Debug("ML Enabled")
	db = addon:Getdb()
	self.candidates = {} 	-- candidateName = { class, role, rank }
	self.lootTable = {} 		-- The MLs operating lootTable
	-- self.lootTable[session] = {	bagged, lootSlot, awarded, name, link, quality, ilvl, type, subType, equipLoc, texture, boe	}
	-- Loot kept in our bags lives in addon:Pending() / addon:ToTrade() (Modules/lootBags.lua, saved per character)
	self.council = addon:GetCouncilInGroup()		-- the currently active council
	self.lootOpen = false 	-- is the ML lootWindow open or closed?
	self.running = false		-- true if we're handling a session

	self:RegisterComm("betterRCLC", "OnCommReceived")
	self:RegisterEvent("LOOT_OPENED","OnEvent")
	self:RegisterEvent("LOOT_CLOSED","OnEvent")
	self:RegisterEvent("LOOT_SLOT_CLEARED", "OnGiveEvent")
	self:RegisterEvent("UI_ERROR_MESSAGE", "OnGiveEvent")
	-- /reload or logout mid-session: the session is saved and picked up again. AceDB clears db.char on PLAYER_LOGOUT
	-- before a plain event handler runs, so this uses AceDB's own shutdown callback (fired before the clearing).
	if addon.db.RegisterCallback then addon.db.RegisterCallback(self, "OnDatabaseShutdown", "SaveLive") end
	self:RegisterBucketEvent("RAID_ROSTER_UPDATE", 10, "UpdateGroup") -- Bursts in group creation, and we should have plenty of time to handle it
	self:RegisterEvent("CHAT_MSG_WHISPER","OnEvent")
	self:RegisterBucketMessage("BRCConfigTableChanged", 2, "ConfigTableChanged") -- The messages can burst
end

--- Add an item to the lootTable
-- @paramsig item[, bagged, slotIndex, index]
-- @param item Any: ItemID|itemString|itemLink
-- @param bagged True if the item is in the ML's inventory
-- @param slotIndex Index of the lootSlot, or nil if none - either this or 'bagged' needs to be supplied
-- @param index Index in self.lootTable, used to set data in a specific session
-- @param pending The addon:Pending() entry when the item comes from the ML's stored loot (gives boss + loot time)
function betterRCLCML:AddItem(item, bagged, slotIndex, index, pending)
	addon:DebugLog("ML:AddItem", item, bagged, slotIndex, index)
	local name, link, rarity, ilvl, iMinLevel, type, subType, iStackCount, equipLoc, texture = GetItemInfo(item)

	-- Item isn't properly loaded, so update the data in 0.5 sec (Should only happen with /brc test)
	if not name then
		self:ScheduleTimer("Timer", 0.5, "AddItem", item, bagged, slotIndex, index, pending)
		GameTooltip:SetHyperlink("item:"..item) -- cace item asap
		addon:Debug("Started timer:", "AddItem", "for", item)
		return
	end

	if BRCTokenTable[item] then 
		ilvl = BRCTokenLevel[item] 
		equipLoc = BRCTokenTable[item]
	end

	self.lootTable[index or #self.lootTable + 1] = {
		["bagged"]		= bagged,
		["lootSlot"]	= slotIndex,
		["awarded"]		= false,
		["name"]		= name,
		["link"]		= link,
		["quality"]		= rarity,
		["ilvl"]		= ilvl,
		["subType"]		= subType,
		["equipLoc"]	= equipLoc,
		["texture"]		= texture,
		["boe"]			= addon:IsItemBoE(link),
		["lootTime"]	= pending and pending.time,
		["boss"]		= pending and pending.boss or addon.target,
	}
end

--- Removes a session from the lootTable
-- @param session The session (index) in lootTable to remove
function betterRCLCML:RemoveItem(session)
	tremove(self.lootTable, session)
end

function betterRCLCML:AddCandidate(name, class, role, rank, enchant, lvl)
	addon:DebugLog("ML:AddCandidate",name, class, role, rank, enchant, lvl)
	self.candidates[name] = {
		["class"]		= class,
		["role"]		= role or "DAMAGER",
		["rank"]		= rank or "", -- Rank cannot be nil for votingFrame
		["enchanter"] 	= enchant,
		["enchant_lvl"]	= lvl,
	}
end

function betterRCLCML:RemoveCandidate(name)
	addon:DebugLog("ML:RemoveCandidate", name)
	self.candidates[name] = nil
end

function betterRCLCML:UpdateGroup(ask)
	if self == nil then 
		self = betterRCLCML -- why?
	end
	addon:DebugLog("UpdateGroup", ask)
	if type(ask) ~= "boolean" then ask = false end
	local group_copy = {}
	local updates = false
	for name in pairs(self.candidates) do	group_copy[name] = true end

	if addon:IsInRaid() then
		for i = 1, addon:GetNumGroupMembers() do
			local name, _, _, _, _, class, _, _, _, _, _ = GetRaidRosterInfo(i)
			
			if name then
				local role = addon:GetUnitRole(name)
				if group_copy[name] then	-- If they're already registered
					group_copy[name] = nil	-- remove them from the check
				else -- add them
					if not ask then -- ask for playerInfo?
						addon:SendCommand(name, "playerInfoRequest")
						addon:SendCommand(name, "MLdb", addon.mldb) -- and send mlDB
					end
					self:AddCandidate(name, class, role) -- Add them in case they haven't installed the adoon
					updates = true
				end
			end
		end
	elseif addon:IsInGroup() then 
		for i = 0, addon:GetNumGroupMembers() do 
			local name, class, role = nil, nil, nil
			if i == 0 then 
				name, class, role =  UnitName("player"), select(2, UnitClass("player")), addon:GetPlayerRole()
			else
				name, class, role =  UnitName("party"..i), select(2, UnitClass("party"..i)), addon:GetUnitRole("party"..i)
			end
			if name then 
				if group_copy[name] then 
					group_copy[name] = nil 
				else
					if not ask then -- ask for playerInfo?
						addon:SendCommand(name, "playerInfoRequest")
						addon:SendCommand(name, "MLdb", addon.mldb) -- and send mlDB
					end
					self:AddCandidate(name, class, role) -- Add them in case they haven't installed the adoon
					updates = true
				end
			end
		end
	end
	-- If anything's left in group_copy it means they left the raid, so lets remove them
	for name, v in pairs(group_copy) do
		if v then self:RemoveCandidate(name); updates = true end
	end
	if updates then
		addon:SendCommand("group", "candidates", self.candidates) 

		local oldCouncil = self.council 
		self.council = addon:GetCouncilInGroup()
		local council_updated = false
		if #self.council ~= #oldCouncil then 
			council_updated = true 
		else
			for i in ipairs(self.council) do
				if self.council[i] ~= oldCouncil[i] then 
					council_updated = true 
					break
				end
			end
		end

		if council_updated then 
			addon:SendCommand("group", "council", self.council)
		end
	end
end

function betterRCLCML:StartSession()
	addon:Debug("ML:StartSession()")
	self.council = addon:GetCouncilInGroup()
	-- ensure we are ready
	if not self.candidates[addon.playerName] or #self.council == 0 then
		addon:Print(L["Please wait a few seconds until all data has been synchronized."])
		return addon:Debug("Data wasn't ready", self.candidates[addon.playerName], #self.council)
	end

	self.running = true
	self.sid = time() .. "-" .. math.random(1000, 9999) -- raiders remember what they answered under this id (core.lua RecordAnswer)
	for _, item in ipairs(self.lootTable) do -- soft / hard reserves travel with the item (Modules/rolls.lua)
		item.sid = self.sid
		local sr, hr = addon.Rolls:SR(item.link)
		item.hr = hr or nil
		item.sr = nil
		if sr and #sr > 0 then
			item.sr = {}
			for _, r in ipairs(sr) do item.sr[r.name] = r.plus or 0 end
		end
	end
	addon:SendCommand("group", "lootTable", self.lootTable)

	self:AnnounceItems()
	-- Start a timer to set response as offline/not installed unless we receive an ack
	self:ScheduleTimer("Timer", 10, "LootSend")
end

function betterRCLCML:AddUserItem(item)
	if self.running then return addon:Print(L["You're already running a session."]) end
	if not item or (type(item) == "string" and not item:find("%S")) then
		return addon:Print("Usage: /brc add <item ID or link>")
	end
	local usage = addon:Getdb().usage
	if usage.never or not usage.ml then
		return addon:Print("Enable Loot council in Settings > General > Use as loot master first.")
	end
	-- Initialize only when Loot council is enabled in the settings.
	if not self:IsEnabled() then
		addon:CallModule("masterlooter")
		self:NewML(addon.masterLooter)
	end
	addon:CallModule("sessionframe")
	local queue = addon:GetActiveModule("sessionframe")
	if queue:AddManual(tostring(item)) then queue:Show() end
end

function betterRCLCML:SessionFromBags()
	if self.running then return addon:Print(L["You're already running a session."]) end
	local pending = addon:Pending()
	if #pending == 0 then return addon:Print(L["No items to award later registered"]) end
	wipe(self.lootTable)
	for _, p in ipairs(pending) do self:AddItem(p.link, true, nil, nil, p) end
	if db.autoStart then
		if #self.lootTable == #pending then -- every item is known to the client: no reason to wait
			self:StartSession()
		else
			self:ScheduleTimer("StartSession", 1) -- uncached items get a moment (AddItem retries after 0.5 s)
		end
	else
		addon:CallModule("sessionframe")
		addon:GetActiveModule("sessionframe"):Show(self.lootTable)
	end
end

function betterRCLCML:PrintAwardedInBags()
	addon:PrintBags()
end

--- Loot modes "bags" and "batch": give an item on the corpse to ourselves and remember it as pending.
-- @param free Free bag slots left (counted once per loot window; GiveMasterLoot is asynchronous)
function betterRCLCML:LootToBags(slot, link, quality, free)
	if free < 1 then
		addon:Print(format("Your bags are full: %s stays on the corpse.", link))
		return false
	end
	if not self:LootToSelf(slot, link, quality) then return false end
	tinsert(addon:Pending(), {link = link, boss = addon.target, time = time()})
	return true
end

--- Loot one corpse slot to myself (master loot to me, or a plain loot below the threshold). true when done.
function betterRCLCML:LootToSelf(slot, link, quality)
	if (quality or 0) < GetLootThreshold() then
		LootSlot(slot)
		return true
	end
	for i = 1, MAX_RAID_MEMBERS do
		if addon:UnitIsUnit(GetMasterLootCandidate(i), "player") then
			GiveMasterLoot(slot, i)
			return true
		end
	end
	addon:Print(format("Could not loot %s to yourself (not a loot candidate?).", link))
	return false
end

-- Runed Orb (Ulduar crafting material); recipes are every item of the auction house class "Recipe"
local MAT_IDS = {[45087] = true}
function betterRCLCML:IsMat(link)
	local id = tonumber(link:match("item:(%d+)"))
	if id and MAT_IDS[id] then return true end
	local itemType = select(6, GetItemInfo(link))
	local recipe = GetAuctionItemClasses and select(9, GetAuctionItemClasses()) or "Recipe"
	return itemType ~= nil and itemType == recipe
end

--- Corpse mode, before reading a new corpse: a leftover session no longer blocks it. A stale one (a test, or every
-- item already awarded) is ended; a real unfinished one from another corpse is reported instead of failing
-- silently (that used to look like "the session does not start"). Returns false when this corpse must wait.
function betterRCLCML:PrepareCorpse()
	if self.running then
		local thisCorpse = false
		for i = 1, GetNumLootItems() do
			local link = GetLootSlotLink(i)
			for _, t in ipairs(self.lootTable) do
				if link and t.link == link and not t.awarded and not t.bagged then thisCorpse = true end
			end
		end
		if thisCorpse then return true end -- reopened the same corpse: the loop below updates the loot slots
		if addon.testMode or self:HasAllItemsBeenAwarded() then
			self:EndSession()
			local vf = addon:GetActiveModule("votingframe")
			if vf and vf.EndSession then vf:EndSession(false) end
		else
			local open = 0
			for _, t in ipairs(self.lootTable) do if not t.awarded then open = open + 1 end end
			addon:Print(format("A loot council session is still running (%d item(s) not awarded). Award them, or press "
				.. "End session / To my bags, then open this corpse again.", open))
			addon.Main:Open("council")
			return false
		end
	end
	for i = #self.lootTable, 1, -1 do -- corpse items of an earlier corpse: their loot slots are gone
		if not self.lootTable[i].bagged then tremove(self.lootTable, i) end
	end
	return true
end

function betterRCLCML:ConfigTableChanged(val)
	-- The db was changed, so check if we should make a new mldb
	-- We can do this by checking if the changed value is a key in mldb
	if not addon.mldb then return self:UpdateMLdb() end -- mldb isn't made, so just make it
	for val in pairs(val) do
		for key in pairs(addon.mldb) do
			if key == val then return self:UpdateMLdb() end
		end
	end
end


function betterRCLCML:CouncilChanged()
	-- The council was changed, so send out the council
	self.council = addon:GetCouncilInGroup()
	addon:SendCommand("group", "council", self.council)
	-- Send candidates so new council members can register it
	addon:SendCommand("group", "candidates", self.candidates)
end

function betterRCLCML:UpdateMLdb()
	-- The db has changed, so update the mldb and send the changes
	addon:Debug("UpdateMLdb")
	addon.mldb = self:BuildMLdb()
	addon:SendCommand("group", "MLdb", addon.mldb)
end

function betterRCLCML:BuildMLdb()
	-- the fixed answer buttons (core.lua BUTTONS) go out whole, so older raider clients show the same three
	local changedResponses = {};
	for i, b in ipairs(addon.BUTTONS) do
		changedResponses[i] = {text = b.text, color = db.responses[i].color, sort = db.responses[i].sort}
	end
	-- every button goes out whole (text, kind, roll): raiders must never fall back to their own button settings
	local changedButtons = {};
	for i, b in ipairs(addon.BUTTONS) do
		changedButtons[i] = {text = b.text, whisperKey = db.buttons[i].whisperKey, kind = b.kind, roll = b.roll}
	end
	-- Extract changed award reasons
	local changedAwardReasons = {}
	for i = 1, db.numAwardReasons do
		if db.awardReasons[i].text ~= addon.defaults.profile.awardReasons[i].text then
			changedAwardReasons[i] = db.awardReasons[i]
		end
	end
	return {
		selfVote			= db.selfVote,
		multiVote		= db.multiVote,
		anonymousVoting = db.anonymousVoting,
		allowNotes		= db.allowNotes,
		numButtons		= #addon.BUTTONS,
		hideVotes		= db.hideVotes,
		observe			= db.observe,
		lootFrameTimerEnabled	= db.lootFrameTimerEnabled,
		lootFrameTimerDuration	= db.lootFrameTimerDuration,
		awardReasons	= changedAwardReasons,
		buttons			= changedButtons,
		responses		= changedResponses,
		bisVer			= addon.BIS:Own().ver, -- raiders with another version ask for the lists ("bis_request")
		upgradeMode		= db.upgradeMode,
		forceBis		= db.forceBis, -- raiders use my BiS lists instead of their own while in my group
		chatRolls		= db.chatRolls, -- answers roll with /roll in chat (off: the loot master's addon rolls, no chat)
		councilVotes	= db.councilVotes,
		blocked			= db.blocked, -- [name] = reason
	}
end

--- Saved at logout / reload while a session runs: the items (with awarded flags) and the board's answers.
local LIVE_MAX_AGE = 3 * 60 * 60
--- Writes the running session into the character data (kept current while the session runs, so a logout, a
-- disconnect or a reload finds it whatever order the shutdown handlers run in). Returns true when something was saved.
function betterRCLCML:KeepLive()
	local c = addon.db and addon.db.char
	if not c or not self.running or addon.testMode or #self.lootTable == 0 then return false end
	local vf = addon:GetModule("BRCVotingFrame", true)
	c.live = {t = time(), sid = self.sid, items = self.lootTable, board = vf and vf.ExportBoard and vf:ExportBoard() or nil}
	return true
end

--- AceDB shutdown callback (logout / reload): last save; no running session = nothing to restore.
function betterRCLCML:SaveLive()
	local c = addon.db and addon.db.char
	if c and not self:KeepLive() then c.live = nil end
end

--- Right after the login of the loot master: take the saved session back. Raiders get the lootTable again (they skip
-- what they answered and send those answers once more, which fills the board), my own board gets the saved answers
-- and rolls first so nothing is rolled twice. Corpse slots are found again when the corpse is reopened.
function betterRCLCML:RestoreLive(retry)
	local c = addon.db and addon.db.char
	local live = c and c.live
	if not live or self.running or not live.items or #live.items == 0 or time() - (live.t or 0) > LIVE_MAX_AGE then
		if c then c.live = nil end
		return
	end
	if not addon:InAnyGroup() then -- not grouped (yet): try once more shortly, then give up and say so
		if not retry then
			addon:ScheduleTimer(function() betterRCLCML:RestoreLive(true) end, 8)
		else
			c.live = nil
			addon:Print("A saved loot session was found, but you are not in a group, so it was dropped.")
		end
		return
	end
	c.live = nil
	self.lootTable, self.running, self.sid = live.items, true, live.sid
	local open = 0
	for _, t in ipairs(self.lootTable) do if not t.awarded then open = open + 1 end end
	if open == 0 then self.lootTable, self.running = {}, false return end
	addon:Print(format("Session restored after the reload: %d of %d item(s) still to award%s.", open, #self.lootTable,
		self.lootOpen and "" or " (open the corpse again to give out corpse items)"))
	addon:SendCommand("group", "lootTable", self.lootTable, true)
	addon:ScheduleTimer(function()
		local vf = addon:GetModule("BRCVotingFrame", true)
		if vf and vf.ImportBoard then vf:ImportBoard(live.board) end
	end, 1)
end

function betterRCLCML:NewML(newML)
	addon:DebugLog("ML:NewML", newML)
	if addon:UnitIsUnit(newML, "player") then -- we are the the ML
		if #addon:Pending() > 0 then
			addon:Print(format("You have %d stored item(s) waiting for a session: /brc award (list: /brc winners).", #addon:Pending()))
		end
		addon:SendCommand("group", "playerInfoRequest")
		self:UpdateMLdb() -- Will build and send mldb
		self:UpdateGroup(true)
		self.council = addon:GetCouncilInGroup()
		addon:SendCommand("group", "council", self.council)
		-- Set a timer to send out the incoming playerInfo changes
		self:ScheduleTimer("Timer", 10, "GroupUpdate")
		addon:ScheduleTimer(function() betterRCLCML:RestoreLive() end, 2) -- an addon timer: it survives the module being toggled
	else
		self:Disable() -- We don't want to use this if we're not the ML
	end
end

function betterRCLCML:Timer(type, ...)
	if type == "AddItem" then
		self:AddItem(...)

	elseif type == "LootSend" then
		addon:SendCommand("group", "offline_timer")

	elseif type == "Restore" then
		self:RestoreLive()

	elseif type == "GroupUpdate" then
		addon:SendCommand("group", "candidates", self.candidates)
	end
end

function betterRCLCML:OnCommReceived(prefix, serializedMsg, distri, sender)
	if prefix == "betterRCLC" then
		-- data is always a table
		local decoded = Deflate:DecodeForPrint(serializedMsg)
		if not decoded then 
			return -- probably an old version or somehow a bad message idk just throw this away
		end 
		local decompressed = Deflate:DecompressDeflate(decoded)
		local test, command, data = addon:Deserialize(decompressed)
		if addon:HandleXRealmComms(self, command, data, sender) then return end
		addon:DebugLog("MLComm received:", command, "from:", sender, "distri:", distri)

		if not addon.isMasterLooter then 
			addon.isMasterLooter, addon.masterLooter = addon:GetML()
		end

		if test and addon.isMasterLooter then -- only ML receives these commands
			if command == "playerInfo" then
				self:AddCandidate(unpack(data))

			elseif command == "MLdb_request" then
				addon:SendCommand(sender, "MLdb", addon.mldb)

			elseif command == "bis_request" then
				addon.BIS:QueueBroadcast()

			elseif command == "council_request" then
				self.council = addon:GetCouncilInGroup()
				addon:SendCommand(sender, "council", self.council)

			elseif command == "reconnect" and not addon:UnitIsUnit(sender, addon.playerName) then -- Don't receive our own reconnect
				-- Someone asks for mldb, council and candidates
				addon:SendCommand(sender, "MLdb", addon.mldb)
				self.council = addon:GetCouncilInGroup()
				addon:SendCommand(sender, "council", self.council)

			--[[NOTE: For some reason this can silently fail, but adding a 1 sec timer on the rest of the calls seems to fix it
				v2.0.1: With huge candidates/lootTable we get AceComm lostdatawarning "First", presumeably due to the 4kb ChatThrottleLib limit.
				Bumping loottable to 4 secs is tested to work with 27 candidates + 10 items.]]

				addon:ScheduleTimer("SendCommand", 1, sender, "candidates", self.candidates)
				if self.running then -- Resend lootTable, then the board's answers (the council window needs them)
					addon:ScheduleTimer("SendCommand", 4, sender, "lootTable", self.lootTable)
					addon:ScheduleTimer(function()
						local vf = addon:GetModule("BRCVotingFrame", true)
						if vf and vf.ExportBoard then addon:SendCommand(sender, "boardSync", vf:ExportBoard()) end
					end, 7)
				end
				addon:Debug("Responded to reconnect from", sender)
			end
		elseif addon.isMasterLooter then
			addon:Debug("Error in deserializing ML comm: ", command)
		end
	end
end

function betterRCLCML:OnEvent(event, ...)
	addon:DebugLog("ML event", event)
	if event == "LOOT_OPENED" then -- IDEA Check if event LOOT_READY is useful here (also check GetLootInfo() for this)
		self.lootOpen = true
		self:LootOpened()
	elseif event == "LOOT_CLOSED" then
		self.lootOpen = false

	elseif event == "CHAT_MSG_WHISPER" and addon.isMasterLooter and db.acceptWhispers then
		local msg, sender = ...
		if msg == "rchelp" then
			self:SendWhisperHelp(sender)
		elseif self.running then
			self:GetItemsFromMessage(msg, sender)
		end
	end
end

function betterRCLCML:LootOpened()
	if not addon.isMasterLooter and GetNumLootItems() > 0 then
		addon:Print(format("Loot opened but you are not the master looter (loot method: %s), so no session starts.", tostring((GetLootMethod()))))
	end
	if addon.isMasterLooter and GetNumLootItems() > 0 then
		addon.target = GetUnitName("target") or L["Unknown/Chest"] -- capture the boss name
		local toBags = db.lootMode == "bags" or db.lootMode == "batch"
		local free, stored = 0, 0
		if toBags then
			for bag = 0, NUM_BAG_SLOTS do free = free + (GetContainerNumFreeSlots(bag) or 0) end
		end
		if not toBags and not self:PrepareCorpse() then return end
		local matDone = {} -- slots looted to me below: the slot clears a moment later, the loop must skip them
		if db.autoLootMats then -- recipes and Runed Orbs straight to me, before anything else is looked at
			for i = 1, GetNumLootItems() do
				local link = GetLootSlotLink(i)
				local _, _, quantity, quality = GetLootSlotInfo(i)
				if link and quantity > 0 and self:IsMat(link) and self:LootToSelf(i, link, quality) then matDone[i] = true end
			end
		end
		for i = 1, GetNumLootItems() do
			-- We have reopened the loot frame, so check if we should update .lootSlot (bag modes never award from the corpse)
			if self.running and not toBags then
				local item = GetLootSlotLink(i)
				for session = 1, #self.lootTable do
					if item == self.lootTable[session].link then
						if i ~= self.lootTable[session].lootSlot then -- It has changed!
							self.lootTable[session].lootSlot = i -- and update it
						end
						-- Lets see if we have more of the same item in the rest of the lootTable
						for ses = session, #self.lootTable do
							if item == self.lootTable[ses].link then
								-- We have! Lets give this one the current slot, as the first will be updated once we reach it in the main loops
								self.lootTable[ses].lootSlot = i
								break
							end
						end
						break
					end
				end
			else
				if db.altClickLooting then self:ScheduleTimer("HookLootButton", 0.5, i) end -- Delay lootbutton hooking to ensure other addons have had time to build their frames
				local _, _, quantity, quality = GetLootSlotInfo(i)
				local item = GetLootSlotLink(i)
				if matDone[i] then
					-- recipe / Runed Orb already looted to me
				elseif self:ShouldAutoAward(item, quality) and quantity > 0 then
					self:AutoAward(i, item, quality, db.autoAwardTo, db.autoAwardReason, addon.target)

				elseif toBags and self:CanWeLootItem(item, quality) and quantity > 0 then
					if self:LootToBags(i, item, quality, free) then
						free, stored = free - 1, stored + 1
					end

				elseif self:CanWeLootItem(item, quality) and quantity > 0 then -- check if our options allows us to loot it
					self:AddItem(item, false, i)

				elseif quantity == 0 then -- it's coin, just loot it
					LootSlot(i)
				else
					local why = not item and "no item link yet" or self:IsItemIgnored(item) and "on the ignore list"
						or quality < GetLootThreshold() and "below the loot threshold" or "not taken by the auto-loot options"
					addon:Print(format("Skipped %s: %s.", item or ("slot " .. i), why))
				end
			end
		end
		if stored > 0 and db.lootMode == "batch" then
			addon:Print(format("Stored %d item(s) in your bags, %d waiting in total. Left-click the betterRCLC minimap button, tick items and Start session.", stored, #addon:Pending()))
		elseif stored > 0 and db.lootMode == "bags" and self.running then
			addon:Print(format("Stored %d item(s); a session is running, start the next one with /brc award.", stored))
		elseif stored > 0 and db.lootMode == "bags" then
			self:SessionFromBags()
		elseif #self.lootTable > 0 and not self.running then
			if db.autoStart then -- Settings say go
				self:StartSession()
			else
				addon:CallModule("sessionframe")
				addon:GetActiveModule("sessionframe"):Show(self.lootTable)
			end
		end
	end
end

function betterRCLCML:CanWeLootItem(item, quality)
	local ret = false
	if db.autoLoot and (IsEquippableItem(item) or db.autolootEverything) and quality >= GetLootThreshold() and not self:IsItemIgnored(item) then -- it's something we're allowed to loot
		-- Let's check if it's BoE
		-- Don't bother checking if we know we want to loot it
		ret = db.autolootBoE or not addon:IsItemBoE(item)
	end
	addon:Debug("CanWeLootItem", item, ret)
	return ret
end

function betterRCLCML:HookLootButton(i)
	local lootButton = getglobal("LootButton"..i)
	if XLoot then -- hook XLoot
		lootButton = getglobal("XLootButton"..i)
	end
	if XLootFrame then -- if XLoot 1.0
		lootButton = getglobal("XLootFrameButton"..i)
	end
	if getglobal("ElvLootSlot"..i) then -- if ElvUI
		lootButton = getglobal("ElvLootSlot"..i)
	end
	local hooked = self:IsHooked(lootButton, "OnClick")
	if lootButton and not hooked then
		addon:DebugLog("ML:HookLootButton", i)
		self:HookScript(lootButton, "OnClick", "LootOnClick")
	end
end

function betterRCLCML:LootOnClick(button)
	if not IsAltKeyDown() or not db.altClickLooting or IsShiftKeyDown() or IsControlKeyDown() then return; end
	addon:DebugLog("LootAltClick()", button)

	if getglobal("ElvLootFrame") then
		button.slot = button:GetID() -- ElvUI hack
	end

	-- Check we're not already looting that item
	for ses, v in ipairs(self.lootTable) do
		if button.slot == v.lootSlot then
			addon:Print(L["The loot is already on the list"])
			return
		end
	end

	self:AddItem(GetLootSlotLink(button.slot), false, button.slot)
	addon:CallModule("sessionframe")
	addon:GetActiveModule("sessionframe"):Show(self.lootTable)
end

--@param session	The session to award
--@param winner	Nil/false if items should be stored in inventory and awarded later
--@param response	The candidates response, index in db.responses
--@param reason	Entry in db.awardReasons
--@returns True if awarded successfully
--- Why a player can't take master loot right now (not a loot candidate).
function addon:WhyNoLoot(name)
	if not (UnitInRaid(name) or UnitInParty(name)) then return "not in the group" end
	if not UnitIsConnected(name) then return "offline" end
	return "can't take master loot (out of range, or was not in the instance when the boss died)"
end

--- The award really happened: tell the raid, announce, log the history entry, end the session when all are given.
--- Tells the winner (only them) what they won and whether to trade me for it: the award card in their roll queue.
function betterRCLCML:SendAwardToast(winner, link, response, reason)
	if addon:UnitIsUnit(winner, "player") then return end
	local trade = false
	for _, t in ipairs(addon:ToTrade()) do
		if t.link == link and addon:UnitIsUnit(t.winner, winner) then trade = true break end
	end
	addon:SendCommand(winner, "award_toast", link, reason and reason.text or addon:GetResponseText(response), trade)
end

function betterRCLCML:Awarded(session, winner, response, reason, log)
	local t = self.lootTable[session]
	if not t or t.awarded then return end
	local item, boss = t.link, t.boss or addon.target
	addon:SendCommand("group", "awarded", session, winner)
	t.awarded = true
	self:SendAwardToast(winner, item, response, reason)
	self:AnnounceAward(winner, item, reason and reason.text or addon:GetResponseText(response))
	if log then self:TrackAndLogLoot(winner, item, response, boss, log.votes, log.gear1, log.gear2, reason, log.council) end
	if self:HasAllItemsBeenAwarded() then self:EndSession() end
end

function betterRCLCML:AwardFailed(session, winner, response, reason, log, why, viaMe)
	local t = self.lootTable[session]
	if not t then return end
	addon:Print(format("|cffd9534f%s did not get %s|r: %s.", viaMe and "You" or winner, t.link, why))
	local p = {session = session, winner = winner, response = response, reason = reason, log = log, why = why, viaMe = viaMe, link = t.link}
	local vf = addon:GetModule("BRCVotingFrame", true)
	if vf and vf.MarkFailed then vf:MarkFailed(p) end -- orange item on the board, the side panel offers Retry / Loot to me
	if addon.ShowAwardProblem and not (log and log.auto) then addon:ShowAwardProblem(p) end
end

--- Waits for the server to empty the loot slot after GiveMasterLoot. done(true) on LOOT_SLOT_CLEARED; done(false, err)
-- when the slot still holds the item after GIVE_WAIT seconds (err = the last red error the server sent meanwhile, e.g.
-- "Inventory is full."; 3.3.5 has no master-loot specific message). A closed loot window without an error counts as
-- given: the slot can't be read any more.
local GIVE_WAIT = 2
function betterRCLCML:WatchGive(slot, link, done)
	self.gives = self.gives or {}
	if self.gives[slot] then self.gives[slot].done(false, "given again before the server answered") end
	local g = {slot = slot, link = link, done = done}
	self.gives[slot] = g
	self:ScheduleTimer(function()
		if self.gives[slot] ~= g then return end
		self.gives[slot] = nil
		local still = self.lootOpen and addon:GetItemIDFromLink(GetLootSlotLink(slot)) == addon:GetItemIDFromLink(link)
		if still or (g.err and self.lootOpen) then done(false, g.err) else done(true) end
	end, GIVE_WAIT)
end

function betterRCLCML:OnGiveEvent(event, arg)
	if not self.gives then return end
	if event == "LOOT_SLOT_CLEARED" then
		local g = self.gives[arg]
		if g then self.gives[arg] = nil g.done(true) end
	else -- UI_ERROR_MESSAGE
		for _, g in pairs(self.gives) do g.err = arg end
	end
end

function betterRCLCML:Award(session, winner, response, reason, log, viaMe)
	addon:DebugLog("ML:Award", session, winner, response, reason)
	if addon.testMode then
		if winner then
			addon:SendCommand("group", "awarded", session, winner)
			self:SendAwardToast(winner, self.lootTable[session].link, response, reason)
			addon:Print(format(L["The item would now be awarded to 'player'"], winner))
			self.lootTable[session].awarded = true
			if self:HasAllItemsBeenAwarded() then
				 addon:Print(L["All items have been awarded and  the loot session concluded"])
				 self:EndSession()
			end
		end
		return true
	end
	if not self.lootTable[session].lootSlot and not self.lootTable[session].bagged then
		addon:SessionError("Session "..session.." didn't have lootSlot")
		return false
	end
	-- Determine if we should award the item now or just store it in our bags
	-- 0.4.2: a corpse give is only "awarded" once the server empties the loot slot (WatchGive); a refused give
	-- (full bags, offline, left the group, out of range) opens the award problem window with Retry / Loot to me.
	-- log = {votes, gear1, gear2} for the history entry, written here once the item really left (callers don't log).
	-- viaMe = loot it to myself and put it on the To trade list for the winner (the window's second button).
	if winner then
		local t = self.lootTable[session]
		if t.bagged then   -- indirect mode (the item is in a bag): the trade helper hands it over
			addon:PendingAwarded(t.link, t.lootTime, winner)
			if not (UnitInRaid(winner) or UnitInParty(winner)) or not UnitIsConnected(winner) then
				addon:Print(format("%s is offline or not in the group: %s waits in your To trade list (2 hours).", winner, t.link))
			end
			self:Awarded(session, winner, response, reason, log)
			return true
		end
		if not self.lootOpen then -- we can't give out loot without the loot window open
			addon:Print(L["Unable to give out loot without the loot window open."])
			return false
		end
		local to = viaMe and "player" or winner
		if t.quality < GetLootThreshold() then
			LootSlot(t.lootSlot)
			if not addon:UnitIsUnit(winner, "player") then
				addon:Print(format(L["Cannot give 'item' to 'player' due to Blizzard limitations. Gave it to you for distribution."], t.link, winner))
				tinsert(addon:ToTrade(), {link = t.link, winner = winner, time = time()})
			end
			self:Awarded(session, winner, response, reason, log)
			return true
		end
		local index
		for i = 1, MAX_RAID_MEMBERS do
			if addon:UnitIsUnit(GetMasterLootCandidate(i), to) then index = i break end
		end
		if not index then
			self:AwardFailed(session, winner, response, reason, log, addon:WhyNoLoot(winner))
			return false
		end
		addon:Debug("GiveMasterLoot", index)
		GiveMasterLoot(t.lootSlot, index)
		self:WatchGive(t.lootSlot, t.link, function(ok, err)
			if ok then
				if viaMe and not addon:UnitIsUnit(winner, "player") then
					tinsert(addon:ToTrade(), {link = t.link, winner = winner, time = time()})
					addon:Print(format("%s is in your bags: trade it to %s (2 hours).", t.link, winner))
				end
				self:Awarded(session, winner, response, reason, log)
			else
				self:AwardFailed(session, winner, response, reason, log, err or "the item is still on the corpse", viaMe)
			end
		end)
		return "pending"

	else -- Store in bags and award later
		if not self.lootOpen then return addon:Print(L["Unable to give out loot without the loot window open."]) end
		if self.lootTable[session].quality < GetLootThreshold() then
			LootSlot(self.lootTable[session].lootSlot)
		else
			for i = 1, MAX_RAID_MEMBERS do
				if addon:UnitIsUnit(GetMasterLootCandidate(i), "player") then
					GiveMasterLoot(self.lootTable[session].lootSlot, i)
					break
				end
			end
		end
		self.lootTable[session].stored = true -- in my bags now (EndSession's leftover report skips it)
		tinsert(addon:Pending(), {link = self.lootTable[session].link, boss = self.lootTable[session].boss, time = time()}) -- and store data
		return false -- Item hasn't been awarded
	end
	return false
end

function betterRCLCML:AnnounceItems()
	if not db.announceItems then return end
	addon:DebugLog("ML:AnnounceItems()")
	SendChatMessage(db.announceText, addon:GetAnnounceChannel(db.announceChannel))
	for k,v in ipairs(self.lootTable) do
		SendChatMessage(k .. ": " .. v.link, addon:GetAnnounceChannel(db.announceChannel))
	end
end

function betterRCLCML:AnnounceAward(name, link, text)
	if db.announceAward then
		for k,v in pairs(db.awardText) do
			if v.channel ~= "NONE" then
				local message = gsub(v.text, "&p", name)
				message = gsub(message, "&i", link)
				message = gsub(message, "&r", text)
				SendChatMessage(message, addon:GetAnnounceChannel(v.channel))
			end
		end
	end
end

function betterRCLCML:ShouldAutoAward(item, quality)
	if db.autoAward and quality >= db.autoAwardLowerThreshold and quality <= db.autoAwardUpperThreshold then
		if db.autoAwardLowerThreshold >= GetLootThreshold() or db.autoAwardLowerThreshold < 2 then
			if UnitInRaid(db.autoAwardTo) or UnitInParty(db.autoAwardTo) then -- TEST perhaps use self.group?
				return true;
			else
				addon:Print(L["Cannot autoaward:"])
				addon:Print(format(L["Could not find 'player' in the group."], db.autoAwardTo))
			end
		else
			addon:Print(format(L["Could not Auto Award i because the Loot Threshold is too high!"], item))
		end
	end
	return false
end

function betterRCLCML:AutoAward(lootIndex, item, quality, name, reason, boss)
	addon:DebugLog("ML:AutoAward", lootIndex, item, quality, name, reason, boss)
	local awarded = false
	if db.autoAwardLowerThreshold < 2 and quality < 2 then
		if addon:UnitIsUnit("player",name) then -- give it to the player
			LootSlot(lootIndex)
			awarded = true
		else
			addon:Print(L["Cannot autoaward:"])
			addon:Print(format(L["You can only auto award items with a quality lower than 'quality' to yourself due to Blizaard restrictions"],"|cff1eff00"..getglobal("ITEM_QUALITY2_DESC").."|r"))
			return false
		end
	else
		for i = 1, MAX_RAID_MEMBERS do
			if addon:UnitIsUnit(GetMasterLootCandidate(i), name) then
				GiveMasterLoot(lootIndex,i)
				awarded = true
				break
			end
		end
	end
	if awarded then
		addon:Print(format(L["Auto awarded 'item'"], item))
		self:AnnounceAward(name, item, db.awardReasons[reason].text)
		self:TrackAndLogLoot(name, item, reason, boss, 0, nil, nil, db.awardReasons[reason])
	else
		addon:Print(L["Cannot autoaward:"])
		addon:Print(format(L["Unable to give 'item' to 'player' - (player offline, left group or instance?)"], item, name))
	end
	return awarded
end

local history_table = {}
function betterRCLCML:TrackAndLogLoot(name, item, response, boss, votes, itemReplaced1, itemReplaced2, reason, council)
	if reason and not reason.log then return end -- Reason says don't log
	if not (db.sendHistory or db.enableHistory) then return end -- No reason to do stuff when we won't use it
	if addon.testMode and not addon.nnp then return end -- We shouldn't track testing awards.
	local instanceName, _, _, difficultyName = GetInstanceInfo()
	addon:Debug("ML:TrackAndLogLoot()")
	history_table["lootWon"] 		= item
	history_table["date"] 			= date("%d/%m/%y")
	history_table["time"] 			= date("%H:%M:%S")
	history_table["instance"] 		= instanceName.."-"..difficultyName
	history_table["boss"] 			= boss
	history_table["votes"] 			= votes
	history_table["itemReplaced1"]= itemReplaced1
	history_table["itemReplaced2"]= itemReplaced2
	history_table["response"] 		= reason and reason.text or addon:GetResponseText(response)
	history_table["responseID"] 	= response or reason.sort - 400 										-- Changed in v2.0 (reason responseID was 0 pre v2.0)
	history_table["color"]			= reason and reason.color or db.responses[response].color	-- New in v2.0
	history_table["class"]			= self.candidates[name].class											-- New in v2.0
	history_table["isAwardReason"] = reason and true or false											-- New in v2.0
	history_table["kind"]			= not reason and addon:ButtonKind(response) or nil						-- 0.4.0: ms / os / up / other
	history_table["council"]		= council																-- 0.4.x: who answered what (nil for old paths)

	if db.sendHistory then -- Send it, and let comms handle the logging
		addon:SendCommand("group", "history", name, history_table)
	elseif db.enableHistory then -- Just log it
		addon:SendCommand("player", "history", name, history_table)
	end
end

------------------------------------------------------------------------
-- Real /roll tie-break: the council board asks the tied players to roll; the server prints each roll in system chat
-- (RANDOM_ROLL_RESULT, can't be faked by an addon) and we send the first 1-100 roll of each asked player as "roll".
------------------------------------------------------------------------
function betterRCLCML.RollPattern()
	local p = (RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"):gsub("%%s", "\001"):gsub("%%d", "\002")
	p = p:gsub("[%(%)%.%-%+%*%?%[%]%^%$%%]", "%%%0")
	return "^" .. p:gsub("\001", "(.+)"):gsub("\002", "(%%d+)") .. "$"
end

function betterRCLCML:WatchRolls(session, names)
	self.rollWatch = {session = session, wanted = {}, got = {}, until_ = time() + 90}
	for _, n in ipairs(names) do self.rollWatch.wanted[n] = true end
	self:RegisterEvent("CHAT_MSG_SYSTEM", "OnRollMessage")
end

function betterRCLCML:OnRollMessage(_, msg)
	local w = self.rollWatch
	if not w or time() > w.until_ then self:UnregisterEvent("CHAT_MSG_SYSTEM") self.rollWatch = nil return end
	local name, roll, low, high = (msg or ""):match(self.RollPattern())
	if not name or tonumber(low) ~= 1 or tonumber(high) ~= 100 then return end
	for n in pairs(w.wanted) do
		if not w.got[n] and addon:UnitIsUnit(n, name) then
			w.got[n] = tonumber(roll)
			addon:SendCommand("group", "roll", w.session, {[n] = tonumber(roll)})
		end
	end
	for n in pairs(w.wanted) do if not w.got[n] then return end end
	self:UnregisterEvent("CHAT_MSG_SYSTEM")
	self.rollWatch = nil
end

function betterRCLCML:HasAllItemsBeenAwarded()
	local moreItems = true
	for i = 1, #self.lootTable do
		if not self.lootTable[i].awarded then
			moreItems = false
		end
	end
	return moreItems
end

--- What an ending session leaves behind: unawarded corpse items stay on the body (reopen it for a new session), unawarded
-- bag items stay in the pending list (Loot tab). Said out loud so nothing is forgotten.
function betterRCLCML:Leftovers()
	local corpse, bags = {}, 0
	for _, t in ipairs(self.lootTable) do
		if not t.awarded and not t.stored then
			if t.bagged then bags = bags + 1 else corpse[#corpse + 1] = t.link end
		end
	end
	return corpse, bags
end

function betterRCLCML:EndSession()
	addon:DebugLog("ML:EndSession()")
	if addon.db and addon.db.char then addon.db.char.live = nil end
	self.sid = nil
	if not addon.testMode then
		local corpse, bags = self:Leftovers()
		if #corpse > 0 then
			addon:Print(format("|cffe2b84d%d item(s) were not awarded and are still on the corpse|r: %s. Open the corpse again to start a new session for them; they are gone when the body despawns.", #corpse, table.concat(corpse, " ")))
		end
		if bags > 0 then
			addon:Print(format("|cffe2b84d%d item(s) were not awarded and stay in your bags|r. They wait on the Loot tab: start a session for them or trade them (2 hours from the drop).", bags))
		end
	end
	self.lootTable = {}
	addon:SendCommand("group", "session_end")
	self.running = false
	self:CancelAllTimers()
	if addon.testMode then -- We need to undo our ML status
		addon.testMode = false
		addon:ScheduleTimer("NewMLCheck", 1) -- Delay it a bit
	end
	addon.testMode = false
end

-- Initiates a session with the items handed
function betterRCLCML:Test(items)
	-- check if we're added in self.group
	-- (We might not be on solo test)
	if not tContains(self.candidates, addon.playerName) then
		self:AddCandidate(addon.playerName, addon.playerClass, addon:GetPlayerRole(), addon.guildRank)
	end
	-- We must send candidates now, since we can't wait the normal 10 secs
	addon:SendCommand("group", "candidates", self.candidates)
	-- Add the items
	for session, iName in ipairs(items) do
		self:AddItem(iName, false, false)
	end
	if db.autoStart then
		addon:Print(L["Autostart isn't supported when testing"])
	end
	addon:CallModule("sessionframe")
	addon:GetActiveModule("sessionframe"):Show(self.lootTable)
end

-- Returns true if we are ignoring the item
function betterRCLCML:IsItemIgnored(link)
	local itemID = addon:GetItemIDFromLink(link) -- extract itemID
	return tContains(db.ignore, itemID)
end

function betterRCLCML:GetItemsFromMessage(msg, sender)
	addon:Debug("GetItemsFromMessage()", msg, sender)
	if not addon.isMasterLooter then return end

	local ses, arg1, arg2, arg3 = addon:GetArgs(msg, 4) -- We only require session to be correct, we can do some error checking on the rest
	ses = tonumber(ses)
	-- Let's test the input
	if not ses or type(ses) ~= "number" or ses > #self.lootTable then return end -- We need a valid session
	-- Set some locals
	local item1, item2
	local response = 1
	if arg1:find("|Hitem:") then -- they didn't give a response
		item1, item2 = arg1, arg2
	else
		-- No reason to continue if they didn't provide an item
		if not arg2 or not arg2:find("|Hitem:") then return end
		item1, item2 = arg2, arg3

		-- check if the response is valid
		local whisperKeys = {}
		for i = 1, #addon.BUTTONS do --go through all the button
			gsub(db.buttons[i]["whisperKey"], '[%w]+', function(x) tinsert(whisperKeys, {key = x, num = i}) end) -- extract the whisperKeys to a table
		end
		for _,v in ipairs(whisperKeys) do
			if strmatch(arg1, v.key) then -- if we found a match
				response = v.num
				break;
			end
		end
	end
	local diff = 0
	if item1 then diff = (self.lootTable[ses].ilvl - select(4, GetItemInfo(item1))) end
	local toSend = {
		gear1 = item1,
		gear2 = item2,
		ilvl = nil,
		diff = diff,
		note = nil,
		response = response
	}
	addon:SendCommand("group", "response", ses, sender, toSend)
	-- Let people know we've done stuff
	addon:Print(format(L["Item received and added from 'player'"], sender))
	SendChatMessage("[betterRCLC]: "..format(L["Acknowledged as 'response'"], addon:GetResponseText(response) ), "WHISPER", nil, sender)
end

function betterRCLCML:SendWhisperHelp(target)
	addon:DebugLog("SendWhisperHelp", target)
	local msg
	SendChatMessage(L["whisper_guide"], "WHISPER", nil, target)
	for i = 1, #addon.BUTTONS do
		msg = "[betterRCLC]: "..addon:GetButtonText(i)..":  " -- i.e. MainSpec/Need:
		msg = msg..""..db.buttons[i]["whisperKey"].."." -- need, mainspec, etc
		SendChatMessage(msg, "WHISPER", nil, target)
	end
	SendChatMessage(L["whisper_guide2"], "WHISPER", nil, target)
	addon:Print(format(L["Sent whisper help to 'player'"], target))
end

--------ML Popups ------------------
LibDialog:Register("BETTERRCLC_CONFIRM_ABORT", {
	text = L["Are you sure you want to abort?"],
	buttons = {
		{	text = L["Yes"],
			on_click = function(self)
				addon:DebugLog("ML aborted session")
				betterRCLCML:EndSession()
				CloseLoot() -- close the lootlist
				addon:GetActiveModule("votingframe"):EndSession(true)
			end,
		},
		{	text = L["No"],
		},
	},
	hide_on_escape = true,
	show_while_dead = true,
})
LibDialog:Register("BETTERRCLC_CONFIRM_AWARD", {
	text = "something_went_wrong",
	icon = "",
	on_show = function(self, data)
		local session, player = unpack(data)
		self.text:SetText(format(L["Are you sure you want to give #item to #player?"], betterRCLCML.lootTable[session].link, player))
		self.icon:SetTexture(betterRCLCML.lootTable[session].texture)
	end,
	buttons = {
		{	text = L["Yes"],
			on_click = function(self, data)
				-- IDEA Perhaps come up with a better way of handling this
				local session, player, response, reason, votes, item1, item2 = unpack(data,1,7)
				betterRCLCML:Award(session, player, response, reason, {votes = votes, gear1 = item1, gear2 = item2}) -- logs once given
				-- We need to delay the test mode disabling so comms have a chance to be send first!
				if addon.testMode and betterRCLCML:HasAllItemsBeenAwarded() then betterRCLCML:EndSession() end
			end,
		},
		{	text = L["No"],
		},
	},
	hide_on_escape = true,
	show_while_dead = true,
})
