-- votingFrame.lua  Council board (redesign step 3). Items rail on the left (state per item), the answers grouped by
-- the guild's ladder (MS BiS > MS alt/upgrade > Upgrade roll > OS BiS > OS; passes and no-answers folded away),
-- inside a group only the /roll orders (BiS, alt and plain answers share a rank; no "+1"). Side panel for the selected
-- player with the award buttons (inline confirm, no popups). Footer: answered count, ask the tied players to /roll,
-- disenchant / bank to the names from settings, end session. Council votes are optional (mldb.councilVotes).
-- The comms (lootTable, response, vote, awarded, roll, ...) are RCLC's and unchanged.

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local BRCVotingFrame = addon:NewModule("BRCVotingFrame", "AceComm-3.0", "AceTimer-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("betterRCLC")
local Deflate = LibStub("LibDeflate")
local UI = addon.UI

local ROW_H = 24
local db
local session = 1 -- the session we're viewing
local lootTable = {} -- from the ML, plus .candidates per session
local active = false -- in a session?
local candidates = {} -- initial candidate data from the ML
local councilInGroup = {}

function BRCVotingFrame:OnInitialize()
	self.expanded = false -- folded tail of the ladder (passes, no answer...) open?
end

function BRCVotingFrame:OnEnable()
	self:RegisterComm("betterRCLC")
	db = addon:Getdb()
	active = true
	self.frame = self:GetFrame()
end

function BRCVotingFrame:OnDisable() -- We never really call this
	self:Hide()
	wipe(lootTable)
	active = false
	session = 1
	self:UnregisterAllComm()
end

function BRCVotingFrame:Hide()
	local M = addon.Main
	if M.frame and M.current == "council" then M.frame:Hide() end
end

function BRCVotingFrame:IsActive()
	return active and self.frame ~= nil
end

function BRCVotingFrame:Show()
	if self.frame and lootTable[session] then
		councilInGroup = addon:GetCouncilInGroup()
		addon.Main:Open("council") -- the main window's Council tab calls SwitchSession via onShow
	else
		addon:Print(L["No session running"])
	end
end

function BRCVotingFrame:EndSession(hide)
	active = false
	if self.frame and self.frame:IsVisible() then self:Update() end
	if hide then self:Hide() end
end

function BRCVotingFrame:OnCommReceived(prefix, serializedMsg, distri, sender)
	if prefix ~= "betterRCLC" then return end
	local decoded = Deflate:DecodeForPrint(serializedMsg)
	if not decoded then return end -- an old version or a bad message
	local decompressed = Deflate:DecompressDeflate(decoded)
	local test, command, data = addon:Deserialize(decompressed)
	addon.lastComm = command
	if addon:HandleXRealmComms(self, command, data, sender) then return end
	addon:DebugLog("VotingComm received:", command, "from:", sender, "distri:", distri)
	if not test then return end
	local fromML = addon:UnitIsUnit(sender, addon.masterLooter)

	if command == "vote" then
		if addon:IsCouncil(sender) or fromML then
			local s, name, vote = unpack(data)
			self:HandleVote(s, name, vote, sender)
		end

	elseif command == "history_request" and addon.isMasterLooter then
		local requested_name = unpack(data)
		local req = addon.successful_history_requests[requested_name]
		if req and (req.ts + 20 > time() or req[sender]) then return end
		addon.successful_history_requests[requested_name] = req or {}
		addon.successful_history_requests[requested_name].ts = time()
		addon.successful_history_requests[requested_name][sender] = true
		local playerDB = addon:GetHistoryDB()[requested_name] or {}
		local response, count = {}, 0
		for i = 1, #playerDB do -- main-spec wins and the last 5 other wins
			local entry = playerDB[i]
			if addon:IsMSWin(entry) then
				tinsert(response, entry)
			elseif not entry.isAwardReason and count < 5 then
				tinsert(response, entry)
				count = count + 1
			end
		end
		addon:SendCommand("group", "update_history", requested_name, response)

	elseif command == "update_history" and fromML then
		local entry_name, entries = unpack(data)
		addon.mlhistory[entry_name] = entries

	elseif command == "change_response" and fromML then
		local ses, name, response = unpack(data)
		self:SetCandidateData(ses, name, "response", response)
		self:Update()

	elseif command == "lootAck" then
		local name = unpack(data)
		for i = 1, #lootTable do
			if self:GetCandidateData(i, name, "response") == "ANNOUNCED" then self:SetCandidateData(i, name, "response", "WAIT") end
		end
		self:Update()

	elseif command == "awarded" and fromML then
		local ses, winner = unpack(data)
		if lootTable[ses] then
			lootTable[ses].awarded = true
			lootTable[ses].awardFailed = nil
			lootTable[ses].winner = winner
		end
		if addon.isMasterLooter and session ~= #lootTable and ses == session then
			self:SwitchSession(session + 1) -- the ML moves on to the next item
		else
			self:Update()
		end

	elseif command == "candidates" and fromML then
		candidates = unpack(data)

	elseif command == "offline_timer" and fromML then
		for i = 1, #lootTable do
			for name in pairs(lootTable[i].candidates) do
				if self:GetCandidateData(i, name, "response") == "ANNOUNCED" then
					self:SetCandidateData(i, name, "response", "NOTHING")
				end
			end
		end
		self:Update()

	elseif command == "lootTable" and fromML then
		active = true
		self:Setup(unpack(data))
		if not addon.enabled then return end
		-- the loot master's board opens by itself; raiders and council only when they ticked "open the board"
		if addon.isMasterLooter then
			if db.autoOpen then self:Show() end
		elseif db.autoOpenBoard then
			self:Show()
		elseif addon.isCouncil then
			addon:Print("Loot council session started: left-click the betterRCLC minimap button to watch.")
		end

	elseif command == "rollResult" then -- a raider's own server roll for an item they answered (Modules/rolls.lua)
		local ses, value = unpack(data)
		self:SetCandidateData(ses, sender, "roll", value)
		self:Update()

	elseif command == "response" then
		local ses, name, t = unpack(data)
		if addon.isMasterLooter and not addon.mldb.chatRolls then self:RollFor(ses, name, t) end
		if t.ms then -- remember specs: the loot queue's "BiS for N" chips use them before the next session
			addon.db.global.specCache = addon.db.global.specCache or {}
			addon.db.global.specCache[name] = {t.ms, t.os, t.oss}
		end
		for k, v in pairs(t) do
			self:SetCandidateData(ses, name, k, v)
		end
		self:Update()

	elseif command == "reawarded" and fromML then -- the ML moved an award that was still in his bags
		local ses, winner = unpack(data)
		if lootTable[ses] then lootTable[ses].winner = winner end
		self:Update()

	elseif command == "boardSync" and fromML then -- answers of everyone, after my /reload
		self:ImportBoard((unpack(data)))
		self:Update()

	elseif command == "roll" and fromML then
		local ses, rolls = unpack(data)
		for name, val in pairs(rolls) do
			self:SetCandidateData(ses, name, "roll", val)
		end
		self:Update()
	end
end

-- Getter/Setter for candidate data (ignores unknown sessions/candidates)
function BRCVotingFrame:SetCandidateData(ses, candidate, key, val)
	local c = lootTable[ses] and lootTable[ses].candidates and lootTable[ses].candidates[candidate]
	if c then c[key] = val else addon:Debug("SetCandidateData: unknown", ses, candidate, key) end
end

function BRCVotingFrame:GetCandidateData(ses, candidate, key)
	local c = lootTable[ses] and lootTable[ses].candidates and lootTable[ses].candidates[candidate]
	return c and c[key]
end

function BRCVotingFrame:Setup(t)
	lootTable = t
	session = 1
	for _, item in ipairs(lootTable) do
		item.haveVoted = false
		item.candidates = {}
		for name, v in pairs(candidates) do
			local offline = (UnitInRaid(name) or UnitInParty(name)) and not UnitIsConnected(name)
			item.candidates[name] = {
				class = v.class, rank = v.rank, role = v.role,
				response = (addon.mldb.blocked and addon.mldb.blocked[name]) and "BLOCKED" or offline and "NOTHING" or "ANNOUNCED",
				ilvl = "", diff = "", votes = 0, roll = "", voters = {}, haveVoted = false,
			}
		end
	end
	self.selected, self.awardFor = nil, nil
	self.startedAt, self.autoSkip, self.autoTry, self.autoNudged = GetTime(), {}, {}, nil
	if self.frame and self.frame:IsVisible() then self:SwitchSession(1) end
end

------------------------------------------------------------------------
-- auto-award (ML option autoCouncil): once an item is ready, the board's top player gets it, or the disenchanter
-- when nobody wanted it. Ready = everyone answered, or the ML's answer timer (+5 s) ran out; with no timer set it
-- waits for every answer. A tie is
-- decided by a random pick among the tied players; an item the ML picked someone for by hand is left alone (the ML is handling it).
------------------------------------------------------------------------
local BOARD_FIELDS = {"response", "roll", "ms", "os", "oss", "gear1", "gear2", "ilvl", "diff", "note", "epMS", "epOS", "votes"}

--- Everything the board knows about the answers of the running session (sent to a raider who reloaded, saved at logout).
function BRCVotingFrame:ExportBoard()
	local out = {}
	for ses, t in ipairs(lootTable) do
		local s = {awarded = t.awarded or nil, winner = t.winner, inBags = t.inBags, bagTime = t.bagTime, c = {}}
		for name, c in pairs(t.candidates or {}) do
			local f = {}
			for _, k in ipairs(BOARD_FIELDS) do f[k] = c[k] end
			s.c[name] = f
		end
		out[ses] = s
	end
	return out
end

--- Applies an ExportBoard table to the current session (the lootTable must have arrived first).
function BRCVotingFrame:ImportBoard(board)
	if type(board) ~= "table" then return end
	for ses, s in pairs(board) do
		local t = lootTable[ses]
		if t and type(s) == "table" then
			if s.awarded then t.awarded, t.winner, t.inBags, t.bagTime = true, s.winner, s.inBags, s.bagTime end
			for name, f in pairs(s.c or {}) do
				local c = t.candidates and t.candidates[name]
				if c and type(f) == "table" then for k, v in pairs(f) do c[k] = v end end
			end
		end
	end
	self:Update()
end

--- Loot master: raiders who left the group or went offline after the session started no longer count as "not
-- answered" (the footer, "ready", and auto-award would wait for them forever).
function BRCVotingFrame:PruneGone()
	if not (active and addon.isMasterLooter) then return end
	local gone = {}
	for _, t in ipairs(lootTable) do
		if not t.awarded then
			for name, c in pairs(t.candidates or {}) do
				if (c.response == "ANNOUNCED" or c.response == "WAIT") and not addon:UnitIsUnit(name, "player") then
					local inGroup = UnitInRaid(name) or UnitInParty(name)
					if not inGroup or not UnitIsConnected(name) then c.response = "NOTHING" gone[name] = inGroup and "went offline" or "left the group" end
				end
			end
		end
	end
	if next(gone) then
		for name, why in pairs(gone) do
			if db and db.autoCouncilMsgs ~= false then addon:Print(format("%s %s: not waited for any more.", name, why)) end
		end
		self:Update()
	end
end

--- A give the server refused (ML:AwardFailed): the item stays on the corpse. The rail row glows orange and the side
-- panel offers Retry / Loot to me (trade later). A new session replaces the table, so unattended marks disappear with it.
function BRCVotingFrame:MarkFailed(p)
	if lootTable[p.session] then lootTable[p.session].awardFailed = p end
	self:Update()
end

local function SayOnce(self, ses, why)
	if self.autoSkip[ses] then return end
	self.autoSkip[ses] = why
	addon:Print(format("Auto-award: %s. %s", lootTable[ses].link or ("item " .. ses), why))
end

--- One pass over the session's items; at most one award per call (awards are async, the next pass sees the result).
function BRCVotingFrame:AutoStep()
	if not (active and addon.isMasterLooter and db and db.autoCouncil and self.startedAt) then return end
	local ML = addon:GetActiveModule("masterlooter")
	if not ML or not ML.lootTable then return end
	local waited = db.lootFrameTimerEnabled and GetTime() - self.startedAt >= (db.lootFrameTimerDuration or 30) + 5
	for ses, t in ipairs(lootTable) do
		local mt = ML.lootTable[ses]
		if mt and not t.awarded and not mt.awarded and not self.autoSkip[ses] and GetTime() - (self.autoTry[ses] or -99) > 8 then
			local n, total = self:Answered(ses)
			local rollsIn = true -- with chat rolls the numbers arrive after the answers; do not decide on empty rolls
			if addon.mldb.chatRolls and not waited then
				for _, c in pairs(t.candidates) do
					if type(c.response) == "number" and (c.roll == nil or c.roll == "") then rollsIn = false end
				end
			end
			local canGive = ML.lootOpen or mt.bagged or addon.testMode
			if total > 0 and (n >= total or waited) and rollsIn and not canGive and not self.autoNudged then
				self.autoNudged = true
				addon:Print("Auto-award: items are ready but the loot window is closed. Open the corpse and they go out by themselves.")
			end
			if total > 0 and (n >= total or waited) and rollsIn and canGive then
				local keep = session
				session = ses
				local manual = ses == keep and self.selected and self.selected ~= self.autoPick
				local done
				if manual then
					session = keep -- the ML picked someone on this item: not ours to award
				else
					done = self:AutoAward(ses)
					if session == ses and ses ~= keep then session = keep end
				end
				if done then return end
			end
		end
	end
end

--- Award item ses (session is already ses). Returns true when an award was attempted this pass.
function BRCVotingFrame:AutoAward(ses)
	local winner
	for _, r in ipairs(self:BuildRows()) do
		if r.name and r.tier < 100 then winner = r break end
	end
	local tied = self:Tied() -- same group and roll: a coin flip between them, the board's other rolls stay as they are
	if #tied >= 2 then
		local pick = tied[math.random(1, #tied)]
		if db.autoCouncilMsgs ~= false then addon:Print(format("Auto-award: %s tied (%s), %s won the re-roll.", lootTable[ses].link, table.concat(tied, ", "), pick)) end
		for _, r in ipairs(self:BuildRows()) do if r.name == pick then winner = r break end end
	end
	self.autoSkip[ses] = true -- one try per item: a refused give opens the award problem window for the ML
	if winner then
		local c = lootTable[ses].candidates[winner.name]
		local key = (type(c.response) == "number" and c.response <= 3) and c.response or 1
		self.autoMode = true
		local ok = self:Award(winner.name, key)
		self.autoMode = nil
		if ok and db.autoCouncilMsgs ~= false then addon:Print(format("Auto-awarded %s to %s (%s%s).", lootTable[ses].link, winner.name, winner.label ~= "" and winner.label .. ", " or "",
			addon:GetResponseText(key))) end
	else
		local name, reason = db.disenchanter, self.ReasonWhere("disenchant")
		if not reason then SayOnce(self, ses, "nobody wants it and there is no disenchant reason (Settings > Loot rules).") return false end
		if not name or name == "" then SayOnce(self, ses, "nobody wants it: set a disenchanter (Loot tab) and I will send it there.") return false end
		self.autoMode = true
		local ok = self:Award(name, nil, reason)
		self.autoMode = nil
		if ok and db.autoCouncilMsgs ~= false then addon:Print(format("Auto-sent %s to %s (nobody wanted it).", lootTable[ses].link, name)) end
	end
	return true
end

local autoClock, liveClock = 0, 0
CreateFrame("Frame"):SetScript("OnUpdate", function(_, dt)
	autoClock = autoClock + dt
	if autoClock < 1 then return end
	autoClock = 0
	BRCVotingFrame:PruneGone()
	liveClock = liveClock + 1
	if liveClock >= 5 and addon.isMasterLooter then
		liveClock = 0
		local ML = addon:GetActiveModule("masterlooter")
		if ML and ML.KeepLive then ML:KeepLive() end
	end
	if db and db.autoCouncil then BRCVotingFrame:AutoStep() end
end)

function BRCVotingFrame:HandleVote(ses, name, vote, voter)
	local c = lootTable[ses] and lootTable[ses].candidates[name]
	if not c then return end
	c.votes = (c.votes or 0) + vote
	if vote == 1 then
		tinsert(c.voters, voter)
	else
		for i, n in ipairs(c.voters) do
			if addon:UnitIsUnit(voter, n) then tremove(c.voters, i) break end
		end
	end
	self:Update()
end

------------------------------------------------------------------------
-- ladder
------------------------------------------------------------------------
--- Loot priority of a candidate on the current item, lower = first:
-- 1 MS + BiS (or an alt marked equal) for their main spec, 2 MS + listed alt, 3 MS, 4 Upgrade roll,
-- 5 OS + BiS for their off spec, 6 OS, then other buttons, then statuses (pass/autopass/waiting/blocked).
-- What a button counts as: addon:ButtonKind (the three fixed buttons in core.lua).
-- Returns tier, label, color.
function BRCVotingFrame:GetPriority(name)
	local c = lootTable[session].candidates[name]
	local link = lootTable[session].link
	-- before they answer, the specs they sent with their last answer (the answer carries them otherwise)
	local cache = addon.db.global and addon.db.global.specCache and addon.db.global.specCache[name]
	local msKey = c.ms or (cache and cache[1])
	local ms = msKey and addon.BIS:Status(msKey, link)
	local osList, known = addon.BIS:CandidateOS(c, cache)
	local osKey, os = addon.BIS:BestStatus(osList, link)
	if not ms and not os and not known and c.class and msKey then -- older client, no off spec sent: other class lists
		osKey, os = addon.BIS:OtherSpecStatus(c.class, msKey, link)
	end
	local label, color = "", {0.6, 0.6, 0.6, 1}
	local blocked = addon.mldb.blocked and addon.mldb.blocked[name]
	local sr = lootTable[session].sr
	if blocked then
		return 100 + (addon:GetResponseSort("BLOCKED") or 0), "Blocked" .. (blocked ~= "" and (": " .. blocked) or ""), {0.85, 0.3, 0.3, 1}
	elseif sr and sr[name] and type(c.response) == "number" then -- soft reserve: only reservers answer, they go first
		return 0, "SR" .. (sr[name] > 0 and (" +" .. sr[name]) or ""), {0.86, 0.65, 0.5, 1}
	elseif ms then
		label = (ms.bis and "BiS" or ("Alt " .. ms.rank)) .. " " .. addon.BIS:SpecName(msKey)
		color = ms.bis and {0.2, 1, 0.2, 1} or {0.55, 0.85, 0.55, 1}
	elseif os then
		label = (os.bis and "OS BiS" or ("OS alt " .. os.rank)) .. " " .. addon.BIS:SpecName(osKey)
		color = {0.886, 0.722, 0.302, 1} -- amber: off-spec list, MS BiS stays green
	elseif msKey then
		label = addon.BIS:SpecName(msKey)
	end
	local r, tier = c.response
	local kind = addon:ButtonKind(r)
	if kind == "ms" then
		tier = (ms and ms.bis) and 1 or (ms and 2 or 3)
	elseif kind == "os" then
		tier = (os and os.bis) and 5 or 6
	elseif kind == "up" then -- "Upgrade roll": after MS, before any off-spec roll (the cards' order BiS | Upgrade | OS)
		tier = 4
	elseif type(r) == "number" then
		tier = 6 + r
	else
		tier = 100 + (addon:GetResponseSort(r) or 0)
	end
	return tier, label, color
end

-- tier -> board group, the way people roll: MS, Upgrade, OS, Pass are always shown with their count;
-- "Soft reserve", "Other" (extra ML buttons) and "Waiting" only when someone is in them. Inside MS the guild list
-- still orders (BiS, alt, plain), inside OS the off-spec BiS goes first.
local GROUPS = {
	{key = "sr", name = "Soft reserve", tiers = {[0] = true}, optional = true},
	{key = "ms", name = "BiS", tiers = {[1] = true, [2] = true, [3] = true}},
	{key = "up", name = "Upgrade", tiers = {[4] = true}},
	{key = "os", name = "OS", tiers = {[5] = true, [6] = true}},
	{key = "other", name = "Other", optional = true}, -- 7..99: extra ML buttons
	{key = "pass", name = "Pass", statuses = {PASS = true, AUTOPASS = true, REMOVED = true, BLOCKED = true}},
	{key = "wait", name = "Waiting", optional = true, statuses = {ANNOUNCED = true, WAIT = true, NOTHING = true}},
}
BRCVotingFrame.GROUPS = GROUPS

local function GroupOf(tier, response)
	for i, g in ipairs(GROUPS) do
		if g.tiers and g.tiers[tier] then return i end
		if g.statuses and g.statuses[response] then return i end
	end
	return tier < 100 and 5 or 6
end

--- Main-spec items a player won in the last 7 days (the "+1" tie-break; local loot history, award reasons not counted).
-- shortcut: a rolling 7 days, not the server's weekly reset; switch to the reset day if the guild asks.
local WEEK = 7 * 24 * 3600
function BRCVotingFrame:WonThisWeek(name)
	local list, n, items = addon.lootDB.factionrealm[name], 0, {}
	for _, e in ipairs(list or {}) do
		local d, m, y = (e.date or ""):match("(%d+)/(%d+)/(%d+)")
		if d and not e.isAwardReason and time() - time({year = 2000 + tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12}) <= WEEK then
			local ms = addon:IsMSWin(e)
			items[#items + 1] = {link = e.lootWon, response = e.response, ms = ms, date = e.date}
			if ms then n = n + 1 end
		end
	end
	return n, items
end

--- Answered BiS (main spec) although the item is not BiS on their main-spec list: tier 2 (an alt) or 3 (not listed).
-- Only when their main spec is known (from the answer or the spec cache); otherwise we can't tell.
function BRCVotingFrame:NotBis(name, tier)
	if tier ~= 2 and tier ~= 3 then return false end
	local c = lootTable[session].candidates[name]
	local cache = addon.db.global and addon.db.global.specCache and addon.db.global.specCache[name]
	return (c.ms or (cache and cache[1])) ~= nil
end

--- The board's rows for the current item: {header = group} and {name = ...} entries, in display order.
function BRCVotingFrame:BuildRows()
	local byGroup = {}
	for name, c in pairs(lootTable[session].candidates) do
		local tier, label, color = self:GetPriority(name)
		local gi = GroupOf(tier, c.response)
		byGroup[gi] = byGroup[gi] or {}
		local won = self:WonThisWeek(name)
		local plus = tier == 0 and lootTable[session].sr[name] or 0 -- SR+ adds to the roll
		-- rank: BiS / alt / plain inside the BiS and OS groups share one rank, so only the roll orders them
		local rank = (GROUPS[gi].key == "ms" or GROUPS[gi].key == "os") and gi or tier
		tinsert(byGroup[gi], {name = name, tier = tier, rank = rank, label = label, color = color, won = won, roll = (tonumber(c.roll) or 0) + plus,
			notBis = self:NotBis(name, tier)})
	end
	for _, list in pairs(byGroup) do
		table.sort(list, function(a, b)
			if a.rank ~= b.rank then return a.rank < b.rank end
			if a.roll ~= b.roll then return a.roll > b.roll end
			return a.name < b.name
		end)
	end
	local rows = {}
	for gi, g in ipairs(GROUPS) do
		local list = byGroup[gi] or {}
		if #list > 0 or not g.optional then
			local b = (g.key == "ms" or g.key == "os" or g.key == "up") and addon:ButtonOf(g.key) -- these groups carry the button name
			rows[#rows + 1] = {header = (b and addon:ShortButtonText(b) or g.name) .. " (" .. #list .. ")", count = #list, key = g.key}
			for _, r in ipairs(list) do rows[#rows + 1] = r end
		end
	end
	return rows
end

--- Players tied at the top of the board: same group, same main-spec wins and the same roll (or no roll yet).
function BRCVotingFrame:Tied()
	local best
	for _, r in ipairs(self:BuildRows()) do
		if r.name and r.tier < 100 then
			if not best then best = {r}
			elseif r.rank == best[1].rank and r.roll == best[1].roll then tinsert(best, r)
			else break end
		elseif r.header and best then
			break
		end
	end
	if not best or #best < 2 then return {} end
	local names = {}
	for _, r in ipairs(best) do names[#names + 1] = r.name end
	return names
end

function BRCVotingFrame:Answered(ses)
	local n, total = 0, 0
	for _, c in pairs(lootTable[ses or session].candidates) do
		if c.response ~= "BLOCKED" and c.response ~= "NOTHING" then
			total = total + 1
			if c.response ~= "ANNOUNCED" and c.response ~= "WAIT" and c.response ~= "NOTHING" then n = n + 1 end
		end
	end
	return n, total
end

------------------------------------------------------------------------
-- award (ML)
------------------------------------------------------------------------
--- Everyone who answered the current item, for the history entry (History tab > click an award).
-- Compact keys because it travels with the history comm: c class, k answer kind (ms/os/up/other/PASS), t answer text,
-- r roll, s main spec, g1/g2 worn items, e EP gain, v votes, n note, l list label, w main-spec wins in 7 days.
function BRCVotingFrame:Snapshot()
	local out = {}
	for name, c in pairs(lootTable[session].candidates) do
		if type(c.response) == "number" or c.response == "PASS" or c.response == "AUTOPASS" then
			local kind = addon:ButtonKind(c.response)
			local _, label = self:GetPriority(name)
			out[name] = {c = c.class, k = kind or c.response, t = type(c.response) == "number" and addon:GetResponseText(c.response) or nil,
				r = tonumber(c.roll), s = c.ms, g1 = c.gear1, g2 = c.gear2, e = kind == "os" and c.epOS or c.epMS,
				v = c.votes ~= 0 and c.votes or nil, n = c.note, l = label ~= "" and label or nil, w = self:WonThisWeek(name)}
		end
	end
	return out
end

--- The ToTrade entry of an awarded item that is still in my bags: index, entry (nil when it already left, e.g. a
-- master-loot give straight from the corpse: then only the winner can trade it on).
function BRCVotingFrame:BagEntry(ses)
	local t = lootTable[ses]
	if not (t and t.awarded and t.winner) then return nil end
	for i, e in ipairs(addon:ToTrade()) do
		if e.link == t.link and addon:UnitIsUnit(e.winner, t.winner) then return i, e end
	end
	-- moved to myself earlier: the item sits in my bags without a To trade entry, and can still be moved on
	if t.inBags and addon:UnitIsUnit(t.winner, "player") then return 0, {link = t.link, time = t.bagTime} end
end

--- Give an awarded item (still in my bags) to another player without a reroll: the To trade list, the history entry,
-- the board and the raid follow; the first winner's award card is withdrawn, the new winner gets one.
function BRCVotingFrame:Reaward(name)
	local ses = session
	local t = lootTable[ses]
	local i, e = self:BagEntry(ses)
	if not i or not name or addon:UnitIsUnit(name, t.winner) then return end
	local old = t.winner
	local c = t.candidates[name] or {}
	if addon:UnitIsUnit(name, "player") then -- mine: nothing left to trade, but remember it is still in my bags
		if i > 0 then tremove(addon:ToTrade(), i) end
		t.inBags, t.bagTime = true, e.time
	elseif i > 0 then
		e.winner, e.warned = name, nil
	else -- back out of my own bags onto the To trade list
		tinsert(addon:ToTrade(), {link = t.link, winner = name, time = e.time or time()})
		t.inBags = nil
	end
	addon:HistoryReaward(old, t.link, name, c.class)
	t.winner = name
	addon:SendCommand("group", "reawarded", ses, name)
	addon:SendCommand(old, "award_revoked", t.link)
	local key = (type(c.response) == "number" and c.response <= 3) and c.response or 1
	if not addon:UnitIsUnit(name, "player") then
		addon:GetActiveModule("masterlooter"):SendAwardToast(name, t.link, key)
	end
	addon:Print(format("%s moved from %s to %s%s.", t.link, old, name, addon:UnitIsUnit(name, "player") and " (stays with you)" or ": trade it to them"))
	self:Update()
end

--- Award the current item. response = 1..n (a button) or nil with reason = an award reason table.
function BRCVotingFrame:Award(name, response, reason)
	local ML = addon:GetActiveModule("masterlooter")
	local t = ML.lootTable[session]
	if not t then return end
	local c = lootTable[session].candidates[name] or {}
	-- ML:Award logs the history entry itself once the item really left ("pending" = waiting for the server)
	local awarded = ML:Award(session, name, response, reason, {votes = c.votes, gear1 = c.gear1, gear2 = c.gear2, council = self:Snapshot(), auto = self.autoMode})
	if addon.testMode and ML:HasAllItemsBeenAwarded() then ML:EndSession() end
	return awarded
end

--- The server refused a give (full bags, offline, left the group, out of range): the item stays on the corpse.
-- Retry = give it again; Loot to me = into my bags and on the To trade list for the winner.
function addon:ShowAwardProblem(p)
	local w = self.awardProblem
	if not w then
		w = UI:Window("awardproblem", "Award failed", 380, 128, "DIALOG")
		w.text = UI:Text(w.body, 12, "ink")
		w.text:SetPoint("TOPLEFT", 12, -12)
		w.text:SetPoint("RIGHT", w.body, "RIGHT", -12, 0)
		w.text:SetWordWrap(true)
		w.retry = UI:Button(w.body, "Retry", 80, 24, "primary")
		w.retry:SetPoint("BOTTOMLEFT", 12, 10)
		w.mine = UI:Button(w.body, "Loot to me, trade later", nil, 24, "default")
		w.mine:SetPoint("LEFT", w.retry, "RIGHT", 6, 0)
		w.close = UI:Button(w.body, "Close", nil, 24, "quiet", function() w:Hide() end)
		w.close:SetPoint("BOTTOMRIGHT", -12, 10)
		self.awardProblem = w
	end
	local ML = self:GetActiveModule("masterlooter")
	w.text:SetText(format("%s did not get %s: %s.\nIt is still on the corpse. Ask them to make room, then Retry, or loot it to yourself and trade it.",
		p.viaMe and "You" or p.winner, p.link or "the item", p.why))
	w.retry:SetScript("OnClick", function() w:Hide() ML:Award(p.session, p.winner, p.response, p.reason, p.log, p.viaMe) end)
	w.mine:SetScript("OnClick", function() w:Hide() ML:Award(p.session, p.winner, p.response, p.reason, p.log, true) end)
	if p.viaMe then w.mine:Hide() else w.mine:Show() end
	w:Show()
end

local function ReasonWhere(field)
	for i, v in ipairs(db.awardReasons) do
		if i > db.numAwardReasons then break end
		if field == "disenchant" and v.disenchant then return v end
		if field == "bank" and (v.text == L["Banking"] or v.text == "Banking") then return v end
		if field == "free" and (v.text == L["Free"] or v.text == "Free") then return v end
	end
end
BRCVotingFrame.ReasonWhere = ReasonWhere

--- Disenchant / bank: to the name from settings, else pick from the raid in a menu.
function BRCVotingFrame:AwardTo(kind, anchor)
	local reason = ReasonWhere(kind)
	if not reason then return addon:Print("No award reason for " .. kind .. " (Settings > Loot rules).") end
	local name = kind == "disenchant" and db.disenchanter or db.banker
	if name and name ~= "" then
		self:Confirm(anchor, "To " .. name .. "?", function() self:Award(name, nil, reason) end)
		return
	end
	self:PickHelper(kind)
end

--- Pick the disenchanter / banker (grid of the raid, enchanters first). Kept in the profile for the whole raid.
function BRCVotingFrame:PickHelper(kind)
	local marked = {}
	if kind == "disenchant" then
		for n, v in pairs(candidates) do if v.enchanter then marked[n] = "(E)" end end
	end
	UI:PickPlayer(kind == "disenchant" and "Disenchanter" or "Bank character", function(n)
		db = db or addon:Getdb()
		if kind == "disenchant" then db.disenchanter = n else db.banker = n end
		addon:Print((kind == "disenchant" and "Disenchanter: " or "Bank: ") .. n .. ". Right-click the button to change.")
		self:Update()
	end, marked)
end

--- The loot master changed their mind mid-session: every unawarded item on the corpse goes to my bags (it joins the
-- Loot tab like "To my bags, roll later"), items already in my bags stay there, and the session ends for everyone.
function BRCVotingFrame:LootAllToBags()
	local ML = addon:GetActiveModule("masterlooter")
	local corpse = 0
	for _, t in ipairs(ML.lootTable) do if not t.awarded and not t.bagged then corpse = corpse + 1 end end
	if corpse > 0 and not ML.lootOpen then
		return addon:Print("Open the boss's loot window first, then press To my bags again.")
	end
	local stored = 0
	for i, t in ipairs(ML.lootTable) do
		if not t.awarded and not t.bagged then
			ML:Award(i) -- no winner: loot it to me and keep it as pending
			stored = stored + 1
		end
	end
	ML:EndSession()
	self:EndSession(false)
	addon:Print(format("Session cancelled; %d item(s) looted to your bags. Roll them from the Loot tab when you want.", stored))
	addon.Main:Open("loot")
end

--- Inline confirm: the button's label turns into the question; a second click within 4 s runs fn.
function BRCVotingFrame:Confirm(button, question, fn)
	if button.confirming then
		button.confirming = nil
		button:SetLabel(button.label0)
		fn()
		return
	end
	button.label0 = button.label0 or button.text:GetText()
	button.confirming = true
	button:SetLabel(question)
	self:ScheduleTimer(function()
		if button.confirming then button.confirming = nil button:SetLabel(button.label0) end
	end, 4)
end


--- Loot master, rolls without chat (default): my addon rolls for each answer once and sends it to the raid as
-- "roll" (the board's Roll column). The raiders' clients never roll, so nobody picks their own number.
function BRCVotingFrame:RollFor(ses, name, t)
	local c = lootTable[ses] and lootTable[ses].candidates[name]
	local max = t and ((t.sr and t.response == 1) and 100 or addon:ButtonRoll(t.response)) -- button range, SR 1-100
	if not c or not max or (c.roll ~= nil and c.roll ~= "") then return end
	c.roll = math.random(1, max)
	addon:SendCommand("group", "roll", ses, {[name] = c.roll})
end

--- Ask the tied players to /roll (server roll, read from chat by the ML: ml_core RollWatch).
-- Without chat rolls the addon simply rolls again for them (1-100).
function BRCVotingFrame:AskTiedToRoll()
	local names = self:Tied()
	if #names < 2 then return addon:Print("No tie to roll off.") end
	if not addon.mldb.chatRolls then
		local rolls = {}
		for _, n in ipairs(names) do
			rolls[n] = math.random(1, 100)
			self:SetCandidateData(session, n, "roll", rolls[n])
		end
		addon:SendCommand("group", "roll", session, rolls)
		addon:Print("Rolled again for " .. table.concat(names, ", ") .. ".")
		return self:Update()
	end
	for _, n in ipairs(names) do self:SetCandidateData(session, n, "roll", "") end
	local ML = addon:GetActiveModule("masterlooter")
	if ML.WatchRolls then ML:WatchRolls(session, names) end
	addon:SendCommand("group", "rollRequest", session, lootTable[session].link, names)
	addon:Print("Asked " .. table.concat(names, ", ") .. " to /roll.")
	self:Update()
end

------------------------------------------------------------------------
-- frame
------------------------------------------------------------------------
local function ClassColor(class)
	local c = class and RAID_CLASS_COLORS[class]
	return c and {c.r, c.g, c.b} or {1, 1, 1}
end

local function IlvlDiff(c, ilvl)
	local il = c.gear1 and select(4, GetItemInfo(c.gear1))
	if not il or not ilvl then return il and tostring(il) or "", 0 end
	local d = ilvl - il
	return il .. (d > 0 and (" |cff57c27a+" .. d .. "|r") or d < 0 and (" |cffd9534f" .. d .. "|r") or " ±0"), d
end

--- Upgrade column text in green (gain) / red (loss).
local function UpgradeText(c)
	local mode = addon.mldb.upgradeMode or "ep"
	local text = addon.Upgrade:Text(mode, c)
	if text == "" then return "" end
	local v
	if mode == "ilvl" then v = tonumber(c.diff) else v = c.epMS or c.epOS end
	if v and v > 0 then return "|cff57c27a" .. text .. "|r" elseif v and v < 0 then return "|cffd9534f" .. text .. "|r" end
	return text
end

--- The roll, plus the SR+ bonus when there is one ("87 +10").
local function RollText(c, name)
	if not c.roll or c.roll == "" then return "" end
	local sr = lootTable[session].sr
	local plus = sr and sr[name] and c.response == 1 and sr[name] or 0
	return tostring(c.roll) .. (plus > 0 and (" |cffdca77f+" .. plus .. "|r") or "")
end

--- Display order only: never reorder lootTable, whose indices are the comms/session IDs.
-- Stable partition keeps both groups in their original order, including duplicate items.
function BRCVotingFrame:BuildItemRows()
	local rows, rest = {}, {}
	for ses, item in ipairs(lootTable) do
		local row = {ses = ses, item = item}
		if self.myWinsFirst and item.awarded and item.winner == addon.playerName then
			rows[#rows + 1] = row
		else
			rest[#rest + 1] = row
		end
	end
	for _, row in ipairs(rest) do rows[#rows + 1] = row end
	return rows
end

local NUM_W = 38 -- width of the Won / Roll / Votes columns (header and cells)

function BRCVotingFrame:GetFrame()
	if self.frame then return self.frame end
	-- drawn into the main window's Council tab (Modules/main.lua)
	local f = addon.Main:Page("council")
	f.body = f
	function f:SetTitle(_, sub) addon.Main:SetSub("council", sub) end
	addon.Main.onShow.council = function() if lootTable[session] then BRCVotingFrame:SwitchSession(session) end end
	local body = f

	-- items rail
	f.rail = CreateFrame("Frame", nil, body)
	f.rail:SetPoint("TOPLEFT", 6, -6)
	f.rail:SetPoint("BOTTOMLEFT", 6, 50)
	f.rail:SetWidth(206)
	UI:Panel(f.rail, "bg2", "border", 1)
	f.railTitle = UI:Text(f.rail, 11, "ink3")
	f.railTitle:SetPoint("TOPLEFT", 10, -8)
	f.railTitle:SetText("ITEMS")
	f.myWins = UI:Button(f.rail, "My wins first: Off", 186, 22, "default", function()
		self.myWinsFirst = not self.myWinsFirst
		f.myWins:SetActive(self.myWinsFirst)
		f.myWins:SetLabel(self.myWinsFirst and "My wins first: On" or "My wins first: Off")
		f.items.offset = 0
		self:Update()
	end)
	f.myWins:SetPoint("TOPLEFT", 10, -26)
	f.myWins.tip = {"My wins first", "Show items awarded to you at the top. Click again for the original order. Only changes your view; resets on reload."}
	f.items = UI:List(f.rail, 44, function(list)
		local r = CreateFrame("Button", nil, list)
		UI:Panel(r, "bg2", false, 1)
		r.icon = UI:Icon(r, 30)
		r.icon:SetPoint("LEFT", 8, 0)
		r.icon:EnableMouse(false)
		r.name = UI:Text(r, 12, "ink")
		r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, -1)
		r.name:SetPoint("RIGHT", r, "RIGHT", -6, 0)
		r.state = UI:Text(r, 11, "ink3")
		r.state:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
		r.mark = r:CreateTexture(nil, "OVERLAY")
		r.mark:SetTexture(UI.FLAT)
		r.mark:SetWidth(2)
		r.mark:SetPoint("TOPLEFT")
		r.mark:SetPoint("BOTTOMLEFT")
		r.glow = CreateFrame("Frame", nil, r) -- orange pulsing border: the give failed, the item is still on the corpse
		r.glow:SetAllPoints()
		r.glow:SetBackdrop(UI:Backdrop(r.glow))
		r.glow:SetBackdropColor(0, 0, 0, 0)
		r.glow:SetBackdropBorderColor(1, 0.55, 0.1, 1)
		r.glow:Hide()
		r.glow:SetScript("OnUpdate", function(g) g:SetAlpha(0.55 + 0.45 * math.sin(GetTime() * 4)) end)
		r:SetScript("OnClick", function(self) BRCVotingFrame:SwitchSession(self.ses) end)
		return r
	end, function(r, row)
		local item, i = row.item, row.ses
		r.ses = i
		r.icon:SetItem(item.link)
		r.name:SetText(item.name or item.link or "?")
		local qr, qg, qb = 1, 1, 1
		if item.quality and GetItemQualityColor then qr, qg, qb = GetItemQualityColor(item.quality) end
		UI:Recolor(r.name, {qr, qg, qb})
		local p = UI:Palette()
		if item.awarded then
			local w = item.winner and item.candidates and item.candidates[item.winner]
			r.state:SetText(item.winner and (UI:SpecTag(w and w.ms, w and w.class, 12) .. UI:ClassName(item.winner, w and w.class)) or "|cff57c27aAwarded|r")
		else
			local n, total = 0, 0
			for _, c in pairs(item.candidates or {}) do
				if c.response ~= "BLOCKED" and c.response ~= "NOTHING" then
					total = total + 1
					if c.response ~= "ANNOUNCED" and c.response ~= "WAIT" and c.response ~= "NOTHING" then n = n + 1 end
				end
			end
			r.ready = total > 0 and n == total
			r.state:SetText(r.ready and ("|cff57c27aReady to award|r · " .. n .. "/" .. total) or (n .. " / " .. total .. " answered"))
		end
		if item.awardFailed and not item.awarded then r.glow:Show() r.state:SetText("|cffff8c1aStill on the corpse|r") else r.glow:Hide() end
		local on = i == session
		r:SetBackdropColor(on and p.rowHover[1] or p.bg2[1], on and p.rowHover[2] or p.bg2[2], on and p.rowHover[3] or p.bg2[3], 1)
		local c = (r.ready and not item.awarded and not on) and p.ok or p.accent -- green edge: every answer is in
		r.mark:SetVertexColor(c[1], c[2], c[3], (on or (r.ready and not item.awarded)) and 1 or 0)
	end)
	f.items:SetPoint("TOPLEFT", f.rail, "TOPLEFT", 1, -54)
	f.items:SetPoint("BOTTOMRIGHT", f.rail, "BOTTOMRIGHT", -1, 1)

	-- side panel (selected player)
	f.side = CreateFrame("Frame", nil, body)
	f.side:SetPoint("TOPRIGHT", -6, -6)
	f.side:SetPoint("BOTTOMRIGHT", -6, 50)
	f.side:SetWidth(244)
	UI:Panel(f.side, "bg2", "border", 1)
	self:BuildSide(f.side)

	-- main: item header, column titles, rows
	local main = CreateFrame("Frame", nil, body)
	main:SetPoint("TOPLEFT", f.rail, "TOPRIGHT", 6, 0)
	main:SetPoint("BOTTOMRIGHT", f.side, "BOTTOMLEFT", -6, 0)
	UI:Panel(main, "bg", "border", 1)
	f.main = main
	f.icon = UI:Icon(main, 40)
	f.icon:SetPoint("TOPLEFT", 12, -10)
	f.itemName = UI:Text(main, 15, "ink")
	f.itemName:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, 0)
	f.itemSub = UI:Text(main, 12, "ink2")
	f.itemSub:SetPoint("TOPLEFT", f.itemName, "BOTTOMLEFT", 0, -4)
	f.chips = {UI:Chip(main), UI:Chip(main), UI:Chip(main)}
	f.chips[2]:SetPoint("TOPRIGHT", main, "TOPRIGHT", -10, -12)
	f.chips[1]:SetPoint("RIGHT", f.chips[2], "LEFT", -6, 0)
	f.chips[3]:SetPoint("RIGHT", f.chips[1], "LEFT", -6, 0) -- BiS answers on items that are not their BiS

	local cols = CreateFrame("Frame", nil, main)
	cols:SetPoint("TOPLEFT", 0, -62)
	cols:SetPoint("TOPRIGHT", 0, -62)
	cols:SetHeight(18)
	f.colsHead = cols
	-- x >= 0: from the row's left edge; x < 0: from its right edge (Won / Roll / Votes follow the window width,
	-- so nothing runs past the panel). The header spans the list's 1 px inset + the rows' 6 px right margin more.
	-- The number columns (x < 0) are NUM_W wide and centred, header and cell alike, so a "2" sits under "Won".
	self.COLS = {{"Player", 12}, {"List", 110}, {"Wears", 218}, {"Upgrade", 296}, {"Won", -178}, {"Roll", -140}, {"Votes", -102}}
	f.colText = {}
	for i, c in ipairs(self.COLS) do
		local t = UI:Text(cols, 11, "ink3")
		if c[2] < 0 then
			t:SetPoint("LEFT", cols, "RIGHT", c[2] - 7, 0)
			t:SetWidth(NUM_W)
			t:SetJustifyH("CENTER")
		else
			t:SetPoint("LEFT", c[2] + 1, 0) -- + the list's 1 px inset, so headers sit exactly over the cells
		end
		t:SetText(c[1])
		f.colText[i] = t
	end

	f.rows = UI:List(main, ROW_H, function(list) return self:MakeRow(list) end, function(r, item) self:FillRow(r, item) end)
	f.rows:SetPoint("TOPLEFT", main, "TOPLEFT", 1, -82)
	f.rows:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -1, 4)

	-- footer
	local foot = CreateFrame("Frame", nil, body)
	foot:SetPoint("BOTTOMLEFT", 6, 6)
	foot:SetPoint("BOTTOMRIGHT", -6, 6)
	foot:SetHeight(38)
	UI:Panel(foot, "bg2", "border", 1)
	f.answered = UI:Text(foot, 13, "ink2")
	f.answered:SetPoint("LEFT", 12, 0)
	f.sideBtn = UI:Button(foot, "Player panel", nil, 24, "default", function() self:ToggleSide() end)
	f.sideBtn:SetPoint("LEFT", f.answered, "RIGHT", 14, 0)
	f.endBtn = UI:Button(foot, "End session", nil, 24, "danger", function(b)
		if addon.isMasterLooter and active then
			local left = 0
			for _, t in ipairs(lootTable) do if not t.awarded then left = left + 1 end end
			self:Confirm(b, left > 0 and format("End it? %d not awarded", left) or "End the session?", function()
				addon:GetActiveModule("masterlooter"):EndSession()
				CloseLoot()
				self:EndSession(true)
			end)
		else
			self:Hide()
		end
	end)
	f.endBtn:SetPoint("RIGHT", -10, 0)
	f.bank = UI:Button(foot, "Bank", nil, 24, "default", function(b, mouse)
		if mouse == "RightButton" then self:PickHelper("bank") else self:AwardTo("bank", b) end
	end)
	f.bank:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	f.bank:SetPoint("RIGHT", f.endBtn, "LEFT", -6, 0)
	f.de = UI:Button(foot, "DE", nil, 24, "default", function(b, mouse)
		if mouse == "RightButton" then self:PickHelper("disenchant") else self:AwardTo("disenchant", b) end
	end)
	f.de:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	f.de:SetIcon("Interface\\Icons\\INV_Enchant_Disenchant")
	f.de:SetPoint("RIGHT", f.bank, "LEFT", -6, 0)
	f.rollBtn = UI:Button(foot, "Reroll ties", nil, 24, "default", function() self:AskTiedToRoll() end)
	f.rollBtn:SetPoint("RIGHT", f.de, "LEFT", -6, 0)
	f.toBags = UI:Button(foot, "To my bags", nil, 24, "default", function(b)
		self:Confirm(b, "Cancel + loot all?", function() self:LootAllToBags() end)
	end)
	f.toBags:SetPoint("RIGHT", f.rollBtn, "LEFT", -6, 0)
	f.toBags.tip = {"To my bags", "Changed your mind: loot every item still on the corpse to yourself, end this session for "
		.. "everyone (their cards close) and roll the items later from the Loot tab."}
	return f
end

function BRCVotingFrame:MakeRow(list)
	local r = CreateFrame("Button", nil, list)
	r:SetBackdrop({bgFile = UI.FLAT})
	r:SetBackdropColor(0, 0, 0, 0)
	r.square = r:CreateTexture(nil, "ARTWORK")
	r.square:SetTexture(UI.FLAT)
	r.square:SetSize(7, 7)
	r.square:SetPoint("LEFT", 12, 0)
	r.head = UI:Text(r, 11, "accent")
	r.head:SetPoint("LEFT", 26, 0)
	r.bar = r:CreateTexture(nil, "OVERLAY") -- selected player: accent edge on the left
	r.bar:SetTexture(UI.FLAT)
	r.bar:SetWidth(2)
	r.bar:SetPoint("TOPLEFT")
	r.bar:SetPoint("BOTTOMLEFT")
	r.cells = {}
	for i, c in ipairs(self.COLS) do
		r.cells[i] = UI:Text(r, 12, "ink")
		if c[2] < 0 then
			r.cells[i]:SetPoint("LEFT", r, "RIGHT", c[2], 0)
			r.cells[i]:SetWidth(NUM_W)
			r.cells[i]:SetJustifyH("CENTER")
		else
			r.cells[i]:SetPoint("LEFT", c[2], 0)
		end
	end
	r.spec = r:CreateTexture(nil, "ARTWORK")
	r.spec:SetSize(16, 16)
	r.spec:SetPoint("LEFT", self.COLS[1][2], 0)
	r.cells[1]:ClearAllPoints()
	r.cells[1]:SetPoint("LEFT", self.COLS[1][2] + 20, 0)
	r.cells[1]:SetWidth(76)
	r.cells[2]:SetWidth(104)
	r.cells[4]:SetWidth(46) -- Upgrade: never into the Won column (at the 1000 px minimum: 296 + 46 < row - 178)
	r.wear = UI:Icon(r, 18)
	r.wear:SetPoint("LEFT", self.COLS[3][2], 0)
	r.cells[3]:ClearAllPoints()
	r.cells[3]:SetPoint("LEFT", r.wear, "RIGHT", 4, 0)
	r.note = r:CreateTexture(nil, "OVERLAY")
	r.note:SetTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
	r.note:SetSize(14, 14)
	r.note:SetPoint("RIGHT", -6, 0)
	r.vote = UI:Button(r, "Vote", 36, 18, "default")
	r.vote:SetPoint("RIGHT", -24, 0)
	r:SetScript("OnEnter", function(self)
		if self.item and self.item.name then
			local p = UI:Palette()
			self:SetBackdropColor(p.rowHover[1], p.rowHover[2], p.rowHover[3], 1)
			local c = lootTable[session].candidates[self.item.name]
			if c and c.note then UI:Tip(self, "Note", c.note) end
		end
	end)
	r:SetScript("OnLeave", function(self) BRCVotingFrame:PaintRow(self) GameTooltip:Hide() end)
	r:SetScript("OnClick", function(self)
		local it = self.item
		if it.fold then BRCVotingFrame.expanded = not BRCVotingFrame.expanded BRCVotingFrame:Update()
		elseif it.name then BRCVotingFrame.selected, BRCVotingFrame.autoPick = it.name, nil BRCVotingFrame:Update() end
	end)
	return r
end

-- group colours = the answer colours (core.lua ANSWER_COLORS); soft reserve accent, the rest grey
local function GroupColor(key)
	local c = addon.ANSWER_COLORS
	if key == "ms" or key == "os" or key == "up" or key == "pass" then return c[key] end
	if key == "sr" then return UI:Palette().accent end
	return c.wait
end

function BRCVotingFrame:PaintRow(r)
	local p = UI:Palette()
	local sel = r.item and r.item.name and r.item.name == self.selected
	r.bar:SetVertexColor(p.accent[1], p.accent[2], p.accent[3], 1)
	if sel then r.bar:Show() else r.bar:Hide() end
	if r.item and r.item.header then
		local c = GroupColor(r.item.key)
		r.square:SetVertexColor(c[1], c[2], c[3], 1)
		r.square:Show()
	else
		r.square:Hide()
	end
	if sel then
		r:SetBackdropColor(p.row[1], p.row[2], p.row[3], 1)
	elseif r.item and r.item.header then
		r:SetBackdropColor(p.bg2[1], p.bg2[2], p.bg2[3], 1)
	else
		r:SetBackdropColor(0, 0, 0, 0)
	end
end

function BRCVotingFrame:FillRow(r, item)
	r.item = item
	local isRow = item.name ~= nil
	for _, t in ipairs(r.cells) do t:SetText("") if isRow then t:Show() else t:Hide() end end
	r.wear:Hide() r.note:Hide() r.vote:Hide() r.spec:Hide()
	if item.header then
		r.head:SetText(item.header)
		local gc = GroupColor(item.key)
		UI:Recolor(r.head, {gc[1], gc[2], gc[3]})
		r.head:Show()
	elseif item.fold then
		r.head:SetText(item.fold)
		UI:Recolor(r.head, "ink2")
		r.head:Show()
	else
		r.head:Hide()
		local c = lootTable[session].candidates[item.name]
		local cached = addon.db.global and addon.db.global.specCache and addon.db.global.specCache[item.name]
		UI:SetSpecIcon(r.spec, c.ms or (cached and cached[1]), c.class)
		r.cells[1]:SetText(item.name)
		UI:Recolor(r.cells[1], ClassColor(c.class))
		r.cells[2]:SetText((item.notBis and "|cffe2b84dnot BiS|r " or "") .. (item.label ~= "" and item.label or "not listed"))
		UI:Recolor(r.cells[2], item.label ~= "" and {item.color[1], item.color[2], item.color[3]} or "ink3")
		if c.gear1 then r.wear:SetItem(c.gear1) r.wear:Show() end
		r.cells[3]:SetText((IlvlDiff(c, lootTable[session].ilvl)))
		r.cells[4]:SetText(UpgradeText(c))
		r.cells[5]:SetText(item.won)
		r.cells[6]:SetText(RollText(c, item.name))
		if addon.mldb.councilVotes then
			r.cells[7]:SetText(c.votes or 0)
			if active and not lootTable[session].awarded and (addon.isCouncil or addon.isMasterLooter) then
				r.vote:SetLabel(c.haveVoted and "Unvote" or "Vote")
				r.vote:SetScript("OnClick", function() self:Vote(item.name) end)
				r.vote:Show()
			end
		end
		if c.note then r.note:Show() end
	end
	self:PaintRow(r)
end

function BRCVotingFrame:Vote(name)
	local item = lootTable[session]
	local c = item.candidates[name]
	if c.haveVoted then
		addon:SendCommand("group", "vote", session, name, -1)
		c.haveVoted = false
		item.haveVoted = false
		for _, v in pairs(item.candidates) do if v.haveVoted then item.haveVoted = true end end
	else
		if not addon.mldb.selfVote and addon:UnitIsUnit("player", name) then
			return addon:Print(L["The Master Looter doesn't allow votes for yourself."])
		end
		if not addon.mldb.multiVote and item.haveVoted then
			return addon:Print(L["The Master Looter doesn't allow multiple votes."])
		end
		addon:SendCommand("group", "vote", session, name, 1)
		c.haveVoted = true
		item.haveVoted = true
	end
	self:Update()
end

-- side panel
local AWARD_AS = {{1, "BiS"}, {3, "Upg"}, {2, "OS"}, {"free", "Free"}} -- the cards' order: BiS | Upgrade | OS

function BRCVotingFrame:BuildSide(s)
	s.name = UI:Text(s, 15, "ink")
	s.name:SetPoint("TOPLEFT", 12, -12)
	s.specs = UI:Text(s, 11, "ink2")
	s.specs:SetPoint("TOPLEFT", s.name, "BOTTOMLEFT", 0, -4)
	s.specs:SetWidth(226)
	s.lines = {}
	local labels = {"Answer", "List", "Wears", "Upgrade", "BiS wins", "Roll", "Note"}
	for i, l in ipairs(labels) do
		local k = UI:Text(s, 11, "ink3")
		k:SetPoint("TOPLEFT", 12, -52 - (i - 1) * 20)
		k:SetText(l)
		local v = UI:Text(s, 12, "ink")
		v:SetPoint("TOPLEFT", 112, -52 - (i - 1) * 20)
		v:SetWidth(126)
		s.lines[i] = v
	end
	-- Wears: up to two worn items as icon + name (one item) or icon + item level (two), hover = item tooltip
	s.wear = {}
	for k = 1, 2 do
		local b = CreateFrame("Button", nil, s)
		b:SetHeight(16)
		b.icon = UI:Icon(b, 16)
		b.icon:SetPoint("LEFT", 0, 0)
		b.icon:EnableMouse(false) -- the whole entry shows the tooltip
		b.text = UI:Text(b, 12, "ink")
		b.text:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
		b:SetScript("OnEnter", function(self)
			if not self.link then return end
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:SetHyperlink(self.link)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetScript("OnClick", function(self) if self.link and IsModifiedClick() then HandleModifiedItemClick(self.link) end end)
		s.wear[k] = b
	end
	s.wear[1]:SetPoint("TOPLEFT", 112, -52 - 2 * 20 + 2)
	s.listChip = UI:Chip(s, 10)
	s.listChip:SetPoint("TOPLEFT", 110, -70)
	s.lastTitle = UI:Text(s, 11, "ink3")
	s.lastTitle:SetPoint("TOPLEFT", 12, -200)
	s.lastTitle:SetText("Last wins")
	s.last = {}
	for i = 1, 3 do
		s.last[i] = UI:Text(s, 11, "ink2")
		s.last[i]:SetPoint("TOPLEFT", 12, -200 - i * 16)
		s.last[i]:SetWidth(226)
	end
	s.awardTitle = UI:Text(s, 11, "ink3")
	s.awardTitle:SetPoint("BOTTOMLEFT", 12, 72)
	s.awardTitle:SetText("Award as")
	s.awardAs = UI:Segmented(s, AWARD_AS, function(k) self.awardAs = k end, 22, 54)
	for _, b in ipairs(s.awardAs.buttons) do if type(b.key) == "number" then b:SetTextTint(addon:AnswerColor(b.key)) end end
	s.awardAs:SetPoint("BOTTOMLEFT", 12, 44)
	-- accent outline (not filled) so the winner's name can be in class colour and stay readable
	s.award = UI:Button(s, "Award", 222, 26, "default", function(b)
		local name, as = self.selected, self.awardAs
		if not name then return end
		local cand = lootTable[session] and lootTable[session].candidates[name]
		if lootTable[session].awarded then -- already awarded, still in my bags: move it
			return self:Confirm(b, "Confirm: move to " .. UI:ClassName(name, cand and cand.class) .. "?", function() self:Reaward(name) end)
		end
		self:Confirm(b, "Confirm: award to " .. UI:ClassName(name, cand and cand.class) .. "?", function()
			if as == "free" then self:Award(name, nil, ReasonWhere("free")) else self:Award(name, as) end
		end)
	end)
	s.award:SetPoint("BOTTOMLEFT", 12, 10)
	s.empty = UI:Text(s, 12, "ink3")
	s.empty:SetPoint("CENTER")
	s.empty:SetText("Click a player")
	-- nobody wants the item: send it to the disenchanter (or pick one first)
	s.toDE = UI:Button(s, "", 222, 26, "default", function(b)
		if (db.disenchanter or "") ~= "" then self:AwardTo("disenchant", b) else self:PickHelper("disenchant") end
	end)
	s.toDE:SetIcon("Interface\\Icons\\INV_Enchant_Disenchant")
	s.toDE:SetPoint("TOP", s.empty, "BOTTOM", 0, -14)
	s.toDE:Hide()
	-- the give failed: the item is still on the corpse
	s.failText = UI:Text(s, 12, "ink")
	s.failText:SetPoint("TOPLEFT", 12, -16)
	s.failText:SetPoint("RIGHT", s, "RIGHT", -12, 0)
	s.failText:SetJustifyH("LEFT")
	s.failText:SetWordWrap(true)
	s.failRetry = UI:Button(s, "Retry the give", 222, 26, "default", function() self:RetryFailed(false) end)
	s.failRetry:SetPoint("TOP", s.failText, "BOTTOM", 0, -90)
	s.failMine = UI:Button(s, "Loot to me, trade later", 222, 26, "primary", function() self:RetryFailed(true) end)
	s.failMine:SetPoint("TOP", s.failRetry, "BOTTOM", 0, -6)
	s.failText:Hide() s.failRetry:Hide() s.failMine:Hide()
end

--- Side panel button on a failed item: give it again, or loot it to my bags and put it on the To trade list.
function BRCVotingFrame:RetryFailed(viaMe)
	local p = lootTable[session] and lootTable[session].awardFailed
	if not p then return end
	lootTable[session].awardFailed = nil
	addon:GetActiveModule("masterlooter"):Award(p.session, p.winner, p.response, p.reason, p.log, viaMe or p.viaMe)
	self:Update()
end

function BRCVotingFrame:UpdateSide()
	local s = self.frame.side
	local p = lootTable[session].awardFailed
	local failed = p and not lootTable[session].awarded and addon.isMasterLooter
	if failed then
		s.failText:SetText(format("The give to %s failed: %s.\n\nThe item is still on the corpse. Ask them to make room and retry, or loot it to your bags and trade it to them later (it goes on your To trade list for 2 hours). Starting a new session drops this.", p.winner, p.why or "unknown"))
		s.failText:Show() s.failRetry:Show() s.failMine:Show()
		if p.viaMe then s.failMine:Hide() end
	else
		s.failText:Hide() s.failRetry:Hide() s.failMine:Hide()
	end
	local c = not failed and self.selected and lootTable[session].candidates[self.selected] or nil
	local show = c ~= nil
	for _, r in ipairs({s.name, s.specs, s.lastTitle, s.awardTitle}) do if show then r:Show() else r:Hide() end end
	for _, r in ipairs(s.lines) do if show then r:Show() else r:Hide() end end
	for _, r in ipairs(s.last) do if show then r:Show() else r:Hide() end end
	if not show then for _, b in ipairs(s.wear) do b:Hide() end end
	local canAward = show and addon.isMasterLooter and active and not lootTable[session].awarded
	-- awarded, but the item is still in my bags (not traded yet): another player can get it without a reroll
	local canMove = show and addon.isMasterLooter and active and lootTable[session].awarded and self.selected ~= lootTable[session].winner
		and self:BagEntry(session) ~= nil
	if canAward then s.awardAs:Show() s.award:Show() elseif canMove then s.awardAs:Hide() s.award:Show() else s.awardAs:Hide() s.award:Hide() end
	if not show and not failed and self.nobody and addon.isMasterLooter and active and not lootTable[session].awarded then
		s.toDE:Show()
		if not s.toDE.confirming then s.toDE:SetLabel((db.disenchanter or "") ~= "" and ("Send to " .. db.disenchanter) or "Pick a disenchanter") end
	else
		s.toDE:Hide()
	end
	if not show then if failed then s.empty:Hide() else s.empty:Show() end s.listChip:Set(nil) return end
	s.empty:Hide()
	local name = self.selected
	s.name:SetText(UI:SpecTag(c.ms, c.class, 16) .. name)
	UI:Recolor(s.name, ClassColor(c.class))
	local cls = c.class and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[c.class] or c.class) or ""
	local oss = addon.BIS:CandidateOS(c, addon.db.global and addon.db.global.specCache and addon.db.global.specCache[name])
	s.specs:SetText(cls .. (c.ms and (" · " .. addon.BIS:SpecName(c.ms) .. " (MS)") or "") .. (#oss > 0 and (" · " .. addon.BIS:SpecNames(oss) .. " (OS)") or ""))
	local tier, label, lcolor = self:GetPriority(name)
	local resp = type(c.response) == "number" and addon:GetResponseText(c.response) or ({ANNOUNCED = "No answer yet", WAIT = "Waiting", NOTHING = "Offline / no addon", PASS = "Pass", AUTOPASS = "Autopass", BLOCKED = "Blocked", REMOVED = "Removed"})[c.response] or tostring(c.response)
	local won, wins = self:WonThisWeek(name)
	s.lines[1]:SetText(addon:AnswerText(c.response, resp) .. (self:NotBis(name, tier) and "  |cffe2b84d(not their BiS)|r" or ""))
	-- on the list: a coloured chip and the panel edge in the same colour (green MS BiS, amber OS BiS)
	local kind = (tier == 1 and "ok") or (tier == 5 and "warn") or (tier == 0 and "accent")
		or (label:find("^Alt") and "accent") or (label:find("^OS") and "warn") or nil
	if kind and label ~= "" then
		s.listChip:Set(label, kind)
		s.lines[2]:SetText("")
	else
		s.listChip:Set(nil)
		s.lines[2]:SetText(label ~= "" and label or "not listed")
		UI:Recolor(s.lines[2], label ~= "" and {lcolor[1], lcolor[2], lcolor[3]} or "ink3")
	end
	local edge = UI:Palette()[(kind == "ok" or kind == "warn") and kind or "border"]
	s:SetBackdropBorderColor(edge[1], edge[2], edge[3], 1)
	local worn = {}
	for _, link in ipairs({c.gear1 or false, c.gear2 or false}) do if link then worn[#worn + 1] = link end end
	s.lines[3]:SetText(#worn == 0 and "-" or "")
	for k, b in ipairs(s.wear) do
		local link = worn[k]
		if link then
			local name, full, _, ilvl = GetItemInfo(link)
			b.link = full or link
			b.icon:SetItem(link)
			if #worn == 1 then -- one item: its name in quality colour (cut to the panel)
				b.text:SetWidth(108)
				b.text:SetText(((full or link):gsub("[%[%]]", "")))
			else
				b.text:SetWidth(0)
				b.text:SetText(ilvl and tostring(ilvl) or "?")
			end
			b:SetWidth(20 + math.min(b.text:GetStringWidth(), #worn == 1 and 108 or 40))
			b:Show()
		else
			b.link = nil
			b:Hide()
		end
	end
	s.wear[2]:ClearAllPoints()
	s.wear[2]:SetPoint("LEFT", s.wear[1], "RIGHT", 10, 0)
	s.lines[4]:SetText(UpgradeText(c))
	s.lines[5]:SetText(won)
	s.lines[6]:SetText(RollText(c, name) ~= "" and RollText(c, name) or "-")
	s.lines[7]:SetText(c.note or "-")
	for i = 1, 3 do
		local w = wins[#wins - i + 1]
		local tex = w and w.link and select(10, GetItemInfo(w.link))
		s.last[i]:SetText(w and ((tex and ("|T" .. tex .. ":16:16:0:0:64:64:5:59:5:59|t ") or "") .. (w.link or "?") .. " |cff6f6a62" .. (w.date or "") .. "|r") or (i == 1 and "none in 7 days" or ""))
	end
	if canMove then
		s.award:SetActive(true)
		s.award:SetLabel("Move award to " .. UI:ClassName(name, c.class))
		s.award.label0 = nil
		s.award.confirming = nil
	end
	if canAward then
		local key = (type(c.response) == "number" and c.response <= 3) and c.response or 1
		if self.awardFor ~= name then self.awardFor, self.awardAs = name, key end
		s.awardAs:Select(self.awardAs)
		s.award:SetActive(true)
		s.award:SetLabel("Award to " .. UI:ClassName(name, c.class))
		s.award.label0 = nil
		s.award.confirming = nil
	end
end

function BRCVotingFrame:Update()
	local f = self.frame
	-- hidden board (every raider gets the data when the ML allows watching): redrawn by the Council tab's onShow
	if not f or not lootTable[session] or not f:IsVisible() then return end
	self:LayoutSide()
	f.empty:Hide()
	local t = lootTable[session]
	f.items:SetData(self:BuildItemRows())
	local rows = self:BuildRows()
	if self.selected and not t.candidates[self.selected] then self.selected = nil end
	-- until the loot master clicks a player, the pick follows the top of the board as answers come in
	if not self.selected or self.selected == self.autoPick then
		self.selected = nil
		-- passes / no answers (tier 100+) are never pre-selected: with only those left the loot master is pointed at DE / Bank
		for _, r in ipairs(rows) do if r.name and r.tier < 100 then self.selected = r.name break end end
		self.autoPick = self.selected
	end
	local nobody = not self.selected and next(t.candidates) ~= nil and select(1, self:Answered()) >= select(2, self:Answered())
	self.nobody = nobody
	self.frame.side.empty:SetText(not nobody and "Click a player"
		or (db.disenchanter or "") ~= "" and "Nobody wants it.\nSend it to your disenchanter."
		or "Nobody wants it.\nPick a disenchanter, then send it to them.")
	f.rows:SetData(rows)
	self:UpdateSide()
	-- header: item and list summary
	f.icon:SetItem(t.link)
	f.itemName:SetText(t.name or t.link)
	local qr, qg, qb = 1, 1, 1
	if t.quality and GetItemQualityColor then qr, qg, qb = GetItemQualityColor(t.quality) end
	UI:Recolor(f.itemName, {qr, qg, qb})
	local slot = t.equipLoc and t.equipLoc ~= "" and _G[t.equipLoc] or "Token"
	local sub = (t.subType and t.subType ~= "Miscellaneous" and t.subType ~= "Junk") and t.subType or nil
	f.itemSub:SetText(UI.Join(" · ", slot, sub, t.ilvl and ("ilvl " .. t.ilvl), t.boss))
	local ms, os = 0, 0
	for name in pairs(t.candidates) do
		local tier = self:GetPriority(name)
		if tier == 1 then ms = ms + 1 elseif tier == 5 then os = os + 1 end
	end
	f.chips[1]:Set(ms > 0 and ("BiS for " .. ms) or nil, "ok")
	f.chips[2]:Set(os > 0 and ("OS BiS for " .. os) or nil, "warn")
	local wrong = 0
	for name in pairs(t.candidates) do if self:NotBis(name, (self:GetPriority(name))) then wrong = wrong + 1 end end
	f.chips[3]:Set(wrong > 0 and (wrong .. " BiS answer" .. (wrong > 1 and "s" or "") .. " not BiS") or nil, "warn")
	local prev -- chain the visible chips from the right, so a hidden one leaves no gap
	for _, i in ipairs({2, 1, 3}) do
		local ch = f.chips[i]
		if ch:IsShown() then
			ch:ClearAllPoints()
			if prev then ch:SetPoint("RIGHT", prev, "LEFT", -6, 0) else ch:SetPoint("TOPRIGHT", f.main, "TOPRIGHT", -10, -12) end
			prev = ch
		end
	end
	if addon.mldb.councilVotes then f.colText[7]:Show() else f.colText[7]:Hide() end
	f:SetTitle("Loot council", (GetInstanceInfo and GetInstanceInfo() or "") .. " · " .. #lootTable .. " item" .. (#lootTable > 1 and "s" or ""))
	-- footer
	local n, total = self:Answered()
	f.answered:SetText(t.awarded and ("|cff57c27aAwarded" .. (t.winner and (" to " .. t.winner) or "") .. "|r") or (n .. " / " .. total .. " answered" .. (total > n and (" · " .. (total - n) .. " waiting") or "")))
	local ml = addon.isMasterLooter and active and not t.awarded
	for _, b in ipairs({f.rollBtn, f.de, f.bank, f.toBags}) do if ml then b:Show() else b:Hide() end end
	if #self:Tied() >= 2 then f.rollBtn:Enable() else f.rollBtn:Disable() end
	if not f.de.confirming then f.de:SetLabel((db.disenchanter or "") ~= "" and ("DE: " .. db.disenchanter) or "DE") end
	if not f.bank.confirming then f.bank:SetLabel((db.banker or "") ~= "" and ("Bank: " .. db.banker) or "Bank") end
	if not f.endBtn.confirming then f.endBtn:SetLabel((addon.isMasterLooter and active) and "End session" or "Close") end
end

--- The side panel (selected player, last wins, award buttons) is always open for the loot master. Raiders and the
-- council can't award, so for them it is folded by default (db.boardSide) and the board takes its width.
function BRCVotingFrame:SideOpen()
	return addon.isMasterLooter or db.boardSide == true
end

function BRCVotingFrame:LayoutSide()
	local f = self.frame
	local open = self:SideOpen()
	if addon.isMasterLooter then f.sideBtn:Hide() else f.sideBtn:Show() end
	f.sideBtn:SetLabel(open and "Hide player panel" or "Player panel")
	if f.sideOpen == open then return end
	f.sideOpen = open
	f.main:ClearAllPoints()
	f.main:SetPoint("TOPLEFT", f.rail, "TOPRIGHT", 6, 0)
	if open then
		f.side:Show()
		f.main:SetPoint("BOTTOMRIGHT", f.side, "BOTTOMLEFT", -6, 0)
	else
		f.side:Hide()
		f.main:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 50)
	end
end

function BRCVotingFrame:ToggleSide()
	db.boardSide = not self:SideOpen()
	self:Update()
end

function BRCVotingFrame:SwitchSession(s)
	if not lootTable[s] then return end
	session = s
	self.selected, self.awardFor = nil, nil -- Award as starts from the player's answer again on every item
	self.frame.rows.offset = 0
	self:Update()
end

addon:TimeComms(BRCVotingFrame, "board")
