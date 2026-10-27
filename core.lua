--[[	betterRCLC by Potdisc
core.lua	Contains core elements of the addon

--------------------------------
TODOs/Notes
	Things marked with "todo"
		- IDEA add an observer/council string to show players their role?
		- If we truly want to be able to edit votingframe scrolltable with modules, it needs to have GetCol by name
		- Pressing shift while hovering an item should do the same as vanilla
		- The 4'th cell in @line81 in versionCheck should not be static
--------------------------------
CHANGELOG
	-- SEE CHANGELOG.TXT
]]

betterRCLC = LibStub("AceAddon-3.0"):NewAddon("betterRCLC", "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0", "AceHook-3.0", "AceTimer-3.0");
local LibDialog = LibStub("LibDialog-1.0")
local L = LibStub("AceLocale-3.0"):GetLocale("betterRCLC")
local lwin = LibStub("LibWindow-1.1")
local Deflate = LibStub("LibDeflate")
local LibGroupTalents = LibStub("LibGroupTalents-1.0")

local GUILD_DEMOTE_PATTERN = "^".._G.ERR_GUILD_DEMOTE_SSS:gsub('%%s', '(.+)').."$"
local GUILD_PROMOTE_PATTERN = "^".._G.ERR_GUILD_PROMOTE_SSS:gsub('%%s', '(.+)').."$"

betterRCLC:SetDefaultModuleState(false)

-- Init shorthands
local db, historyDB, debugLog;-- = self.db.profile, self.lootDB.factionrealm, self.db.global.log
-- init modules
local defaultModules = {
	masterlooter =	"betterRCLCML",
	lootframe =		"BRCLootFrame",
	history =		"BRCLootHistory",
	version =		"BRCVersionCheck",
	sessionframe =	"BRCSessionFrame",
	votingframe =	"BRCVotingFrame",
}
local userModules = {
	masterlooter = nil,
	lootframe = nil,
	history = nil,
	version = nil,
	sessionframe = nil,
	votingframe = nil,
}

local frames = {} -- Contains all frames created by betterRCLC:CreateFrame()
local unregisterGuildEvent = false
local player_relogged = true -- Determines if we potentially need data from the ML due to /rl

function betterRCLC:OnInitialize()
	--IDEA Consider if we want everything on self, or just whatever modules could need.
  	self.version = "0.5.6" -- hard code the version so reload ui updates will report correct version
	self.nnp = false
	self.debug = false
	self.tVersion = nil -- String or nil. Indicates test version, which alters stuff like version check. Is appended to 'version', i.e. "version-tVersion"

	self.playerClass = select(2, UnitClass("player"))
	self.guildRank = L["Unguilded"]
	self.target = nil
	self.isMasterLooter = false -- Are we the ML?
	self.masterLooter = ""  -- Name of the ML
	self.isCouncil = false -- Are we in the Council?
	self.enabled = true -- turn addon on/off
	self.inCombat = false -- Are we in combat?

	self.verCheckDisplayed = false -- Have we shown a "out-of-date"?

	self.council = {} -- council from ML
	self.mldb = {} -- db recived from ML
	self.mlhistory = {} -- history received from ML
	self.successful_history_requests = {} -- for the master looter, history requests that were done successfully 

	self.responses = {
		NOTANNOUNCED	= { color = {1,0,1,1},				sort = 501,		text = L["Not announced"],},
		ANNOUNCED		= { color = {1,0,1,1},				sort = 502,		text = L["Wait"], },
		WAIT				= { color = {1,1,0,1},				sort = 503,		text = L["Waiting"], },
		TIMEOUT			= { color = {1,0,0,1},				sort = 504,		text = L["Candidate didn't respond on time"], },
		REMOVED			= { color = {0.8,0.5,0,1},			sort = 505,		text = L["Candidate removed"], },
		NOTHING			= { color = {0.5,0.5,0.5,1},		sort = 505,		text = L["Offline"], },
		PASS				= { color = {0.7, 0.7,0.7,1},		sort = 800,		text = L["Pass"],},
		AUTOPASS			= { color = {0.7,0.7,0.7,1},		sort = 801,		text = L["Autopass"], },
		DISABLED			= { color = {0.3, 0.35, 0.5},		sort = 802,		text = L["Candidate has disabled betterRCLC"], },
		BLOCKED			= { color = {0.85, 0.3, 0.3, 1},	sort = 803,		text = "Blocked by the officers", },
		--[[1]]			  { color = {0,1,0,1},				sort = 1,		text = "BiS",},
		--[[2]]			  { color = {1,0.5,0,1},			sort = 2,		text = "Off spec",	},
		--[[3]]			  { color = {0,0.7,0.7,1},			sort = 3,		text = "Upgrade roll",},
	}
	self.roleTable = {
		TANK =		L["Tank"],
		HEALER =		L["Healer"],
		DAMAGER =	L["DPS"],
		NONE =		L["None"],
	}

	self.testMode = false;

	-- Option table defaults
	self.defaults = {
		global = {
			logMaxEntries = 500,
			log = {}, -- debug log
			localizedSubTypes = {},
		},
		profile = {
			usage = { -- State of enabledness
				-- 0.2.9: no "use betterRCLC with this group?" popup any more; a plain on/off setting (General > Use as loot master)
				ml = false,				-- Enable when ML
				leader = false,		-- Enable when leader
				never = true,			-- Never enable
				state = "never", 	-- Current state: "ml" (on) or "never" (off)
			},
			checkID = 1,
			autoStart = true, -- start a session with all eligible items (opens the loot/voting windows for the raid right away)
			lootMode = "window", -- "window" = award from the corpse, "bags" = loot to my bags + session, "batch" = loot to my bags, session later
			autoLoot = true, -- Auto loot equippable items
			autolootEverything = true,
			autolootBoE = true,
			autoOpen = true, -- auto open the voting frame (loot master)
			autoOpenBoard = false, -- raiders / council: open the board too when a session starts (needs the ML's "observe")
			autoPassBoE = true,
			boardSide = false, -- raiders / council: council board side panel open (the ML always has it)
			bisFx = true, -- roll cards: animated glow, sweep and flash on main-spec BiS items (lootFrame.lua Glow)
			autoPass = false, -- 0.4.0: off by default, the class filter hid items people could roll on
			altClickLooting = true,
			acceptWhispers = true,
			selfVote = true,
			multiVote = true,
			anonymousVoting = false,
			showForML = false,
			hideVotes = false, -- Hide the # votes until one have voted
			allowNotes = true,
			lootFrameTimerEnabled = false, -- Auto pass items in the Loot Frame after a set time
			lootFrameTimerDuration = 30, -- Seconds before auto passing, 20-60
			autoAward = false,
			autoAwardLowerThreshold = 2,
			autoAwardUpperThreshold = 3,
			autoAwardTo = L["None"],
			autoAwardReason = 1,
			observe = true, -- every raider gets the board data and may watch it (0.4.0: on by default)
			autoRolls = false, -- automatically add random rolls for every candidate as soon as a session starts (Master Looter only)
			silentAutoPass = false, -- Show autopass message
			--neverML = false, -- Never use the addon as ML

			UI = { -- stores all ui information
				['**'] = { -- Defaults for Lib-Window
					y		= 0,
					x		= 0,
					point	= "CENTER",
					scale	= 0.8,
				},
				lootframe = { -- We want the Loot Frame to get a little lower
					y = -200,
				},
			},

			modules = { -- For storing module specific data
				['*'] = {},
			},

			announceAward = true,
			awardText = { -- Just max it at 2 channels
				{ channel = "group",	text = L["&p was awarded with &i for &r!"],},
				{ channel = "NONE",	text = "",},
			},
			announceItems = false,
			announceText = L["Items under consideration:"],
			announceChannel = "group",

			responses = self.responses,

			enableHistory = true, -- everyone keeps the history the ML sends (exportable from the history window)
			skin = "bronze", -- "bronze" (Blizzard style) or "modern" (follows ElvUI); /reload to switch
			disenchanter = "", -- council board "Disenchant" gives to this name (empty = pick from the raid)
			banker = "", -- council board "Bank" gives to this name (empty = pick from the raid)
			councilVotes = false, -- officers vote on the board (the ML still awards)
			expiryWarn = true, -- one warning per item when its 2 hour trade window has 15 minutes left
			autoCouncilMsgs = true, -- print each auto-award in my chat
			autoTrade = false, -- ML: open the trade with a winner who waits for items once they are in range
			autoTradeDelay = 3, -- seconds in range before the request
			autoCouncil = false, -- ML: award each item by itself to the board's top player (or the disenchanter) once it is ready
			chatRolls = false, -- answers roll with a visible /roll; off = the loot master's addon rolls (nothing in chat)
			autoLootMats = false, -- recipes and Runed Orbs go straight to the loot master
			forceBis = false, -- ML: raiders use my BiS lists instead of their own (only while in my group)
			upgradeMode = "ep", -- what the council's Upgrade column shows: "ep" | "ilvl"
			blocked = {}, -- [name] = reason: players the officers blocked from rolling (sent to the raid in mldb)
			sendHistory = true,

			minRank = -1,
			council = {},

			maxButtons = 10,
			numButtons = 3,
			buttons = {
				{	text = "BiS",					whisperKey = L["whisperKey_need"], },	-- 1 (was "Main spec")
				{	text = "Off spec",				whisperKey = L["whisperKey_greed"],},	-- 2
				{	text = "Upgrade roll",			whisperKey = L["whisperKey_minor"],},	-- 3: nobody needs it for MS / OS BiS
			},
			maxAwardReasons = 10,
			numAwardReasons = 3,
			awardReasons = {
				{ color = {1, 1, 1, 1}, disenchant = true, log = true,	sort = 401,	text = L["Disenchant"], },
				{ color = {1, 1, 1, 1}, disenchant = false, log = true,	sort = 402,	text = L["Banking"], },
				{ color = {1, 1, 1, 1}, disenchant = false, log = false, sort = 403,	text = L["Free"],},
			},
			disenchant = true, -- Disenchant enabled, i.e. there's a true in awardReasons.disenchant

			-- List of items to ignore:
			ignore = {
				43345, -- Dragon Hide Backpack
				43347, -- Satchel of Spoils 
				43346, -- Large Satchel of Spoils
				43986, -- Black Drake
				43954, -- Twilight Drake
				45038, -- Val'anyr fragment
				45087, -- Runed Orb
			},
		},
	} -- defaults end

	-- create the other buttons/responses
	for i = #self.defaults.profile.buttons+1, self.defaults.profile.maxButtons do
		tinsert(self.defaults.profile.buttons, {
			text = L["Button"].." "..i,
			whisperKey = ""..i,
		})
	end
	for i = self.defaults.profile.numButtons+1, self.defaults.profile.maxButtons do
		tinsert(self.defaults.profile.responses, {
			color = {0.7, 0.7,0.7,1},
			sort = i,
			text = L["Button"]..i,
		})
	end
	-- create the other AwardReasons
	for i = #self.defaults.profile.awardReasons+1, self.defaults.profile.maxAwardReasons do
		tinsert(self.defaults.profile.awardReasons, {color = {1, 1, 1, 1}, disenchant = false, log = true, sort = 400+i, text = "Reason "..i,})
	end

	-- register chat and comms
	self:RegisterChatCommand("brc", "ChatCommand")
  	self:RegisterChatCommand("betterrclc", "ChatCommand")
	self:RegisterComm("betterRCLC")
	self:RegisterComm("betterRCLC_WotLK")
	self.db = LibStub("AceDB-3.0"):New("betterRCLCDB", self.defaults, true)
	self.lootDB = LibStub("AceDB-3.0"):New("betterRCLCLootDB")
	--[[ Format:
	"playerName" = {
		[#] = {"lootWon", "date (d/m/y)", "time (h:m:s)", "instance", "boss", "votes", "itemReplaced1", "itemReplaced2", "response", "responseID", "color", "class", "isAwardReason"}
	},
	]]
	self.db.RegisterCallback(self, "OnProfileChanged", "RefreshConfig")
	self.db.RegisterCallback(self, "OnProfileCopied", "RefreshConfig")
	self.db.RegisterCallback(self, "OnProfileReset", "RefreshConfig")

	-- add shortcuts
	db = self.db.profile
	-- 0.2.9: the "ask me" choice (a popup in every group you lead) is gone; a saved "ask" becomes off
	if db.usage.state == "ask_ml" or db.usage.ask_ml or db.usage.ask_leader then
		db.usage.ask_ml, db.usage.ask_leader, db.usage.ml, db.usage.leader, db.usage.never, db.usage.state = nil, nil, false, false, true, "never"
	end
	historyDB = self.lootDB.factionrealm
	-- 0.2.7: answer 1 was called "Main spec"; saved profiles keep their texts, so rename that one default
	for _, t in ipairs({self.db.profile.buttons and self.db.profile.buttons[1], self.db.profile.responses and self.db.profile.responses[1]}) do
		if t and t.text == "Main spec" then t.text = "BiS" end
	end
	debugLog = self.db.global.log

	-- 0.4.0: the classic AceConfig pages (Interface > AddOns) are gone; everything is in /brc config (Modules/settings.lua)
	-- Add logged in message in the log
	self:DebugLog("Logged In")
end

function betterRCLC:OnEnable()
	-- Register the player's name
	self.realmName = GetRealmName()
	self.playerName = UnitName("player")
	self:DebugLog(self.playerName, self.version, self.tVersion)

	-- register events
	self:RegisterEvent("PARTY_LOOT_METHOD_CHANGED", "OnEvent")
	self:RegisterEvent("GUILD_ROSTER_UPDATE","OnEvent")
	self:RegisterEvent("RAID_INSTANCE_WELCOME","OnEvent")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEvent")
	self:RegisterEvent("PLAYER_REGEN_DISABLED", "EnterCombat")
	self:RegisterEvent("PLAYER_REGEN_ENABLED", "LeaveCombat")
	self:RegisterEvent("CHAT_MSG_SYSTEM", "CheckGuildUpdate")
	--self:RegisterEvent("GROUP_ROSTER_UPDATE", "Debug", "event")

	if IsInGuild() then
		self.guildRank = select(2, GetGuildInfo("player"))
		self:SendCommand("guild", "verTest", self.version, self.tVersion) -- send out a version check
	end

	-- Any upgrade to v2.0.0 or from Alpha.12 needs a db reset and possibly lootDB import
	if (self.db.global.version and self.db.global.version < "2.0.0") or (self.db.global.tVersion and self.db.global.tVersion <= "Alpha.12") then -- Upgraded to v.2.0.0
		self:Debug("First time v2.0.0 upgrade!")
		local lootdb = {}
		if self.db.factionrealm.lootDB then
			self:Debug("Extracting old LootDB")
			for k,v in pairs(self.db.factionrealm.lootDB) do
				lootdb[k] = v
			end
			self:Debug("Done")
		end
		self:Debug("Resetting DB")
		self.db:ResetDB("Default")
		self:Debug("Done\nImporting LootDB")
		for k,v in pairs(lootdb) do
			self.lootDB.factionrealm[k] = v
		end
		self:Debug("Done")
		self:Print("Your settings have been reset due to upgrading to v2.0.0")
	end

	if self.db.global.version and self.db.global.version ~= self.version then 
		self.db.global.localizedSubTypes.created = false -- re-cache incase we updated subtypes
		self.db.global.version = self.version
	end

	self.db.global.logMaxEntries = self.defaults.global.logMaxEntries -- reset it now for zzz

	if self.tVersion then
		self.db.global.logMaxEntries = 1000 -- bump it for test version
	end
	if self.db.global.tVersion and self.debug then -- recently ran a test version, so reset debugLog
		self.db.global.log = {}
	end

	self.db.global.tVersion = self.tVersion;
	GuildRoster()

	local filterFunc = function(_, event, msg, player, ...)
		return strfind(msg, "[[betterRCLC]]:")
	end
	ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", filterFunc)

	self:LocalizeSubTypes()

	----------PopUp setups --------------
	-------------------------------------
	self.usageDialog = ({ -- shown by addon:AskUsage (Modules/main.lua)
		text = L["confirm_usage_text"],
		buttons = {
			{	text = L["Yes"],
				on_click = function()
					local lootMethod = GetLootMethod()
					if lootMethod ~= "master" then
						self:Print(L["Changing LootMethod to Master Looting"])
						SetLootMethod("master", self.playerName) -- activate ML
					end
					if db.autoAward and GetLootThreshold() ~= 2 and GetLootThreshold() > db.autoAwardLowerThreshold  then
						self:Print(L["Changing loot threshold to enable Auto Awarding"])
						SetLootThreshold(db.autoAwardLowerThreshold >= 2 and db.autoAwardLowerThreshold or 2)
					end
					self:Print(L["Now handles looting"])
					self.isMasterLooter = true
					self.masterLooter = self.playerName
					if #db.council == 0 then -- if there's no council
						self:Print(L["You haven't set a council! You can edit your council by typing '/brc council'"])
					end
					self:CallModule("masterlooter")
					self:GetActiveModule("masterlooter"):NewML(self.masterLooter)
				end,
			},
			{	text = L["No"],
				on_click = function()
					betterRCLC:Print(L[" is not active in this raid."])
				end,
			},
		},
		hide_on_escape = true,
		show_while_dead = true,
	})
end

function betterRCLC:OnDisable()
	self:Debug("OnDisable()")
	--NOTE (not really needed as we probably never call .Disable() on the addon)
		-- delete all windows
		-- disable modules(?)
	self:UnregisterAllEvents()
end

function betterRCLC:RefreshConfig(event, database, profile)
	self:Debug("RefreshConfig",event, database, profile)
	self.db.profile = database.profile
	db = database.profile
end

function betterRCLC:ConfigTableChanged(val)
	--[[ NOTE By default only ml_core needs to know about changes to the config table,
		  but we'll use AceEvent incase future modules also wants to know ]]
	self:SendMessage("BRCConfigTableChanged", val)
end

function betterRCLC:CheckGuildUpdate(_, msg)
	local _, _, _, rank_name = strfind(msg, GUILD_PROMOTE_PATTERN) -- update on promotion
	if rank_name == nil then 
		rank_name = select(4, strfind(msg, GUILD_DEMOTE_PATTERN))
	end
	if rank_name then
		if not self.checkUpdateTimer then
			self.checkUpdateTimer = self:ScheduleTimer("AddGuildRanksToCouncil", 2)
		end
	end
end

function betterRCLC:AddGuildRanksToCouncil(rank)
	self.checkUpdateTimer = nil
	rank = rank or self.db.profile.minRank
	self.db.profile.council = {}
	for i = 1, GetNumGuildMembers() do
		local name, _, rankIndex = GetGuildRosterInfo(i) -- get info from all guild members
		if rankIndex + 1 <= rank then -- if the member is the required rank, or above
			tinsert(self.db.profile.council, name) -- then insert them to the council
		end
	end
	self:CouncilChanged()
end

function betterRCLC:CouncilChanged()
	if self.isMasterLooter then 
		self:GetActiveModule("masterlooter"):CouncilChanged()
	end
end

--- Returns a table containing the the council members in the group
function betterRCLC:GetCouncilInGroup()
	local council = {}
	if self:IsInRaid() then
		for k,v in ipairs(db.council) do
			if UnitInRaid(v) then
				tinsert(council, v)
			end
		end
	elseif self:IsInGroup() then -- Party
		for k,v in ipairs(db.council) do
			if UnitInParty(v) then
				tinsert(council, v)
			end
		end
	elseif self.isCouncil then -- When we're alone
		tinsert(council, self.playerName)
	end
	if #council == 0 and self.masterLooter then -- We can't have empty council
		tinsert(council, self.masterLooter)
	end
	self:DebugLog("GetCouncilInGroup", unpack(council))
	return council
end

function betterRCLC:ChatCommand(msg)
	local roll = (msg or ""):match("^%s*roll%s+(.+)$") -- item links contain spaces: read before GetArgs splits them
	if roll then return self.Pug:AddFromBags(roll) end
	if (msg or ""):match("^%s*pug%s*$") then return self.Pug:Toggle() end
	local input, arg1, arg2 = self:GetArgs(msg,3)
	input = strlower(input or "")
	if not input or input:trim() == "" or input == "help" or input == L["help"] then
		if self.tVersion then print(format(L["chat tVersion string"],self.version, self.tVersion))
		else print(format(L["chat version String"],self.version)) end
		self:Print(L["chat_commands"])
		self:Debug("- debug or d - Toggle debugging")
		self:Debug("- log - display the debug log")
		self:Debug("- clearLog - clear the debug log")

	elseif input == 'config' or input == L["config"] or input == "c" then
		-- Call it twice, because reasons..
		self.Settings:Open()

	elseif input == 'debug' or input == 'd' then
		self.debug = not self.debug
		self:Print("Debug = "..tostring(self.debug))

	elseif input == 'open' or input == L["open"] or input == 'council' or input == L["council"] then
		self.Main:Open() -- the Council tab only shows a session to the council (and observers)

	elseif input == 'officers' then
		self.Settings:Open("council")

	elseif input == 'perf' then
		self.perf = not self.perf
		self:Print(self.perf and "perf on: every betterRCLC message that takes over 3 ms to handle is printed (until /reload or /brc perf)." or "perf off.")

	elseif input == 'minimap' then
		self.Main:ShowMinimap(true)


	elseif input == 'test' or input == L["test"] then
		--self:Print(db.ui.versionCheckScale)
		self:Test(tonumber(arg1) or 1)

	elseif input == 'version' or input == L["version"] or input == "v" or input == "ver" then
		self:CallModule("version")

	elseif input == "history" or input == L["history"] or input == "h" or input == "his" then
		self:CallModule("history")
--@debug@
	elseif input == "nnp" then
		self.nnp = not self.nnp
		self:Print("nnp = "..tostring(self.nnp))
--@end-debug@
	elseif input == "whisper" or input == L["whisper"] then
		self:Print(L["whisper_help"])

	elseif (input == "add" or input == L["add"]) then
		if self.isMasterLooter then
			self:GetActiveModule("masterlooter"):AddUserItem(arg1)
		else
			self:Print(L["You cannot use this command without being the Master Looter"])
		end

	elseif input == "award" or input == L["award"] or input == "queue" then
		if self.isMasterLooter then
			self:CallModule("sessionframe")
			self:GetActiveModule("sessionframe"):Show(nil, "roll")
		else
			self:Print(L["You cannot use this command without being the Master Looter"])
		end

	elseif input == "winners" or input == L["winners"] or input == "pending" or input == "bags" then
		self:CallModule("sessionframe") -- stored loot is saved per character, so this works without being ML
		self:GetActiveModule("sessionframe"):Show(nil, "trade")

	elseif input == "clearbags" then
		wipe(self:Pending())
		wipe(self:ToTrade())
		self:Print("Cleared the pending and to-trade lists (the items stay in your bags).")

	elseif input == "export" then
		self:GetModule("BRCLootHistory"):ShowExport()

	elseif input == "bis" then
		self.Settings:Open("bis")

	elseif input == "sr" or input == "softres" then
		self.Rolls:OpenImport()

	elseif input == "import" then
		self.Settings:OpenImport()

	elseif input == "live" then
		local ml = self:GetActiveModule("masterlooter")
		local live = self.db.char.live
		self:Print(format("Session: running=%s, %d item(s). Saved copy: %s.", tostring(ml and ml.running), ml and ml.lootTable and #ml.lootTable or 0,
			live and format("%d item(s), %d s old", #live.items, time() - (live.t or 0)) or "none"))

	elseif input == "raid" then
		self.RaidPanel:Diag()

	elseif input == "spec" or input == "specs" then
		self.Settings:Open("specs")

	elseif input == "reset" or input == L["reset"] then
		for k, v in pairs(db.UI) do -- We can't easily reset due to the wildcard in defaults
			if k == "lootframe" then -- Loot Frame is special
				v.y		= -200
			else
				v.y		= 0
			end
			v.point	= "CENTER"
			v.x 			= 0
			v.scale		= 0.8
		end
		for _, frame in ipairs(frames) do
			frame:RestorePosition()
		end
		self:Print(L["Windows reset"])

	elseif input == "debuglog" or input == "log" then
		for k,v in ipairs(debugLog) do print(k,v); end

	elseif input == "clearlog" then
		wipe(debugLog)
		self:Print("Debug Log cleared.")
--@debug@
	elseif input == 't' then -- Tester cmd
		printtable(historyDB)
--@end-debug@

	elseif input == "share" then 
		if self.isMasterLooter then

		else 
			self:Print(L["You cannot use this command without being the Master Looter"])
		end
	else
		self:ChatCommand("help")
	end
end

--- My answers of the running session, kept in the saved variables: db.global.answered[sid][session] = {link, payload}.
function betterRCLC:RecordAnswer(sid, ses, link, payload)
	if not sid then return end
	local a = self.db.global.answered
	if not a or a.sid ~= sid then a = {sid = sid} self.db.global.answered = a end -- a new session forgets the old one
	a[ses] = {link = link, payload = payload}
end

--- A lootTable arrived: mark items awarded already or answered by me (no roll card). resync = the loot master restarted
-- and lost the answers, so I send mine again.
function betterRCLC:ApplyAnswered(lootTable, resync)
	local sid = lootTable[1] and lootTable[1].sid
	local a = sid and self.db.global.answered
	if a and a.sid ~= sid then a = nil end
	for ses, v in ipairs(lootTable) do
		if v.awarded then
			v.autopass = true
		elseif a and a[ses] and a[ses].link == v.link then
			v.autopass = true
			if resync then self:SendCommand("group", "response", unpack(a[ses].payload)) end
		end
	end
end

local deflate_level = {level = 9}
--- Send a betterRCLC Comm Message using AceComm-3.0
-- See betterRCLC:OnCommReceived() on how to receive these messages.
-- @param target The receiver of the message. Can be "group", "guild" or "playerName".
-- @param command The command to send.
-- @param vararg Any number of arguments to send along. Will be packaged as a table.
function betterRCLC:SendCommand(target, command, ...)
	-- send all data as a table, and let receiver unpack it
	local serialized = self:Serialize(command, {...})
	local compressed = Deflate:CompressDeflate(serialized, deflate_level)
	local toSend = Deflate:EncodeForPrint(compressed)
	local prio = "NORMAL"

	if target == "groupfast" then 
		target = "group"
		prio = "ALERT"
	end

	if target == "group" then
		if self:IsInRaid() then
			self:SendCommMessage("betterRCLC", toSend, "RAID", nil, prio)
		elseif self:IsInGroup() then 
			self:SendCommMessage("betterRCLC", toSend, "PARTY", nil, prio)
		--[[elseif num > 0 then -- Party
			self:SendCommMessage("betterRCLC", toSend, "PARTY")]]
		else--if self.testMode then -- Alone (testing)
			self:SendCommMessage("betterRCLC", toSend, "WHISPER", self.playerName, prio)
		end

	elseif target == "guild" then
		self:SendCommMessage("betterRCLC", toSend, "GUILD")

	else
		if self:UnitIsUnit(target,"player") then -- If target == "player"
			self:SendCommMessage("betterRCLC", toSend, "WHISPER", self.playerName)
		elseif target then
			-- We cannot send "WHISPER" to a crossrealm player
			if target:find("-") then
				if target:find(self.realmName) then -- Our own realm, just send it
					self:SendCommMessage("betterRCLC", toSend, "WHISPER", target)
				else -- Get creative
					-- Remake command to be "xrealm" and put target and command in the table
					-- See "betterRCLC:HandleXRealmComms()" for more info
					toSend = self:Serialize("xrealm", {target, command, ...})
					self:SendCommMessage("betterRCLC", toSend, "RAID")
				end

			else -- Should also be our own realm
				self:SendCommMessage("betterRCLC", toSend, "WHISPER", target)
			end
		end
	end
end

--- Receives betterRCLC commands
-- Params are delivered by AceComm-3.0, but we need to extract our data created with the
-- betterRCLC:SendCommand function.
-- @usage
-- To extract the original data using AceSerializer-3.0:
-- -- local success, command, data = self:Deserialize(serializedMsg)
-- 'data' is a table containing the varargs delivered to betterRCLC:SendCommand().
-- To ensure correct handling of x-realm commands, include this line aswell:
-- -- if betterRCLC:HandleXRealmComms(self, command, data, sender) then return end
function betterRCLC:OnCommReceived(prefix, serializedMsg, distri, sender)
	if prefix == "betterRCLC" then
		-- data is always a table to be unpacked
		local decoded = Deflate:DecodeForPrint(serializedMsg)
		if not decoded then 
			return -- probably an old version or somehow a bad message idk just throw this away
		end 
		local decompressed = Deflate:DecompressDeflate(decoded)
		local test, command, data = self:Deserialize(decompressed)
		self.lastComm = command -- /brc perf names the slow message
		-- NOTE: Since I can't find a better way to do this, all xrealms comms is routed through here
		--			to make sure they get delivered properly. Must be included in every OnCommReceived() function.
		if self:HandleXRealmComms(self, command, data, sender) then return end
		self:DebugLog("Comm received:", command, "from:", sender, "distri:", distri)
		if test then
			if command == "lootTable" then
				self.isMasterLooter, self.masterLooter = self:GetML()
				if self:UnitIsUnit(sender, self.masterLooter) then
					local lootTable, resync = unpack(data)
					-- Send "DISABLED" response when not enabled
					if not self.enabled then
						for i = 1, #lootTable do
							self:SendCommand("group", "response", i, self.playerName, {response = "DISABLED"})
						end
						return self:Debug("Sent 'DISABLED' response to", sender)
					end

					-- v2.0.1: It seems people somehow receives mldb with numButtons, so check for it aswell.
					if not self.mldb or (self.mldb and not self.mldb.numButtons) then -- Really shouldn't happen, but I'm tired of people somehow not receiving it...
						self:Debug("Received loot table without having mldb :(", sender)
						self:SendCommand(self.masterLooter, "MLdb_request")
						return self:ScheduleTimer("OnCommReceived", 1, prefix, serializedMsg, distri, sender)
					end

					self:SendCommand("group", "lootAck", self.playerName) -- send ack

					-- Blocked by the officers: no loot popup, tell the council why
					local reason = self.mldb.blocked and self.mldb.blocked[self.playerName]
					if reason then
						for i = 1, #lootTable do
							self:SendCommand("group", "response", i, self.playerName, {response = "BLOCKED"})
						end
						self:Print("You can't roll on loot right now" .. (reason ~= "" and (": " .. reason) or "") .. " (ask an officer).")
						return
					end

					
					-- After my /reload (or the loot master's) the same session arrives again: items I already answered, and
					-- items already awarded, get no card. ml_core stamps every item with the session id (sid).
					self:ApplyAnswered(lootTable, resync)

					-- Soft / hard reserves (ml_core attaches them per item): only the reservers get a card
					for ses, v in ipairs(lootTable) do
						if v.autopass then -- answered before the reload, or awarded: stays without a card
						elseif v.hr or (v.sr and not v.sr[self.playerName]) then
							self:SendCommand("group", "response", self:CreateResponse(ses, v.link, v.ilvl, "AUTOPASS", v.equipLoc))
							v.autopass = true
						end
					end

					if db.autoPass then -- Do autopassing
						for ses, v in ipairs(lootTable) do
							if v.autopass or v.sr then -- already passed, or I reserved it
							elseif (v.boe and db.autoPassBoE) or not v.boe then
								if self:AutoPassCheck(v.subType, v.equipLoc, v.link) then
									self:Debug("Autopassed on: ", v.link)
									if not db.silentAutoPass then self:Print(format(L["Autopassed on 'item'"], v.link)) end
									self:SendCommand("group", "response", self:CreateResponse(ses, v.link, v.ilvl, "AUTOPASS", v.equipLoc))
									lootTable[ses].autopass = true
								end
							else
								self:Debug("Didn't autopass on: "..v.link.." because it's BoE!")
							end
						end
					end

					-- Show  the LootFrame
					self:CallModule("lootframe")
					self:GetActiveModule("lootframe"):Start(lootTable)

					-- The votingFrame handles lootTable itself

				else -- a non-ML send a lootTable?!
					self:Debug(tostring(sender).." is not ML, but sent lootTable!")
				end

			elseif command == "council" and self:UnitIsUnit(sender, self.masterLooter) then -- only ML sends council
				self.council = unpack(data)
				self.isCouncil = self:IsCouncil(self.playerName)

				-- prepare the voting frame for the right people
				if self.isCouncil or self.mldb.observe then
					self:CallModule("votingframe")
				end

			elseif command == "MLdb" and not self.isMasterLooter then -- ML sets his own mldb
				if self:UnitIsUnit(sender, self.masterLooter) then
					self.mldb = unpack(data)
					self.BIS:CheckSync(self.mldb, sender)
					self.BIS:SendMine() -- my specs reach the loot master before the first roll
				else
					self:Debug("Non-ML:", sender, "sent Mldb!")
				end

			elseif command == "verTest" and not self:UnitIsUnit(sender, "player") then -- Don't reply to our own verTests
				local otherVersion, tVersion = unpack(data)
				self:SendCommand(sender, "verTestReply", self.playerName, self.playerClass, self.guildRank, self.version, self.tVersion)
				if self.version < otherVersion and not self.verCheckDisplayed and (not (tVersion or self.tVersion)) then
					self:Print(format(L["version_outdated_msg"], self.version, otherVersion))
					self.verCheckDisplayed = true

				elseif tVersion and self.tVersion and not self.verCheckDisplayed and self.tVersion < tVersion then
					self:Print(format(L["tVersion_outdated_msg"], tVersion))
					self.verCheckDisplayed = true
				end

			elseif command == "verTestReply" then
				local _,_,_, otherVersion, tVersion = unpack(data)
				if self.version < otherVersion and not self.verCheckDisplayed and (not (tVersion or self.tVersion)) then
					self:Print(format(L["version_outdated_msg"], self.version, otherVersion))
					self.verCheckDisplayed = true

				elseif tVersion and self.tVersion and not self.verCheckDisplayed and self.tVersion < tVersion then
					self:Print(format(L["tVersion_outdated_msg"], tVersion))
					self.verCheckDisplayed = true
				end

			elseif command == "history" and db.enableHistory then
				local name, history = unpack(data)
				if historyDB[name] then
					tinsert(historyDB[name], history)
				else
					historyDB[name] = {history}
				end

			elseif command == "award_toast" and self:UnitIsUnit(sender, self.masterLooter) and self.enabled then
				self:CallModule("lootframe")
				self:GetActiveModule("lootframe"):AddAward(sender, unpack(data))

			elseif command == "award_revoked" and self:UnitIsUnit(sender, self.masterLooter) and self.enabled then
				local link = unpack(data)
				local lf = self:GetActiveModule("lootframe")
				if lf and lf.RemoveAward then lf:RemoveAward(link) end
				self:Print(format("%s was given to someone else by the loot master.", link or "An item"))

			elseif command == "reroll" and self:UnitIsUnit(sender, self.masterLooter) and self.enabled then
				self:Print(format(L["'player' has asked you to reroll"], sender))
				self:CallModule("lootframe")
				self:GetActiveModule("lootframe"):ReRoll(unpack(data))

			elseif (command == "history_remove" or command == "history_edit") and self:UnitIsUnit(sender, self.masterLooter)
				and not self:UnitIsUnit(sender, "player") then
				if command == "history_remove" then self:HistoryRemove(unpack(data)) else self:HistoryMove(unpack(data)) end

			elseif command == "specRequest" and self:UnitIsUnit(sender, self.masterLooter) then
				self.BIS:SendMine(true)

			elseif command == "mySpecs" and self.isMasterLooter then
				local ms, os, oss = unpack(data)
				self.BIS:ReceiveSpecs(sender, ms, os, oss)
				local q = self:GetModule("BRCSessionFrame", true)
				if q and q.frame and q.frame:IsVisible() then q:Update() end

			elseif command == "myGear" then
				self.RaidPanel:Receive(sender, unpack(data))

			elseif command == "gearRequest" then
				self.RaidPanel:Reply(sender)

			elseif command == "rollRequest" and self:UnitIsUnit(sender, self.masterLooter) then
				local ses, link, names = unpack(data)
				for _, n in ipairs(names or {}) do
					if self:UnitIsUnit(n, "player") then self:ShowRollPrompt(link, ses) break end
				end

			elseif command == "playerInfoRequest" then
				self:SendCommand(sender, "playerInfo", self:GetPlayerInfo())

			elseif command == "bisLists" and not self:UnitIsUnit(sender, "player") then
				if self:UnitIsUnit(sender, self.masterLooter) then
					self.BIS:Receive(sender, unpack(data))
				end

			elseif command == "message" then
				self:Print(unpack(data))

			elseif command == "session_end" and self.enabled then
				if self:UnitIsUnit(sender, self.masterLooter) then
					self.db.global.answered = nil
					self:Print(format(L["'player' has ended the session"], self.masterLooter))
					self:GetActiveModule("lootframe"):Disable()
					if self.isCouncil or self.mldb.observe then -- Don't call the voting frame if it wasn't used
						self:GetActiveModule("votingframe"):EndSession(true)
					end
					self.successful_history_requests = {}
					self.mlhistory = {}
				else
					self:Debug("Non ML:", sender, "sent end session command!")
				end
			end
		else
			-- Most likely pre 2.0 command
			local cmd = strsplit(" ", serializedMsg, 2)
			if cmd and cmd == "verTest" then
				self:SendCommand(sender, "verTestReply", self.playerName, self.playerClass, self.guildRank, self.version, self.tVersion)
				return
			end
			self:Debug("Error in deserializing comm:", command, data);
		end
	elseif prefix == "betterRCLC_WotLK" then 
		local decoded_msg = Deflate:DecodeForPrint(serializedMsg)
    	local decompressed_msg = Deflate:DecompressDeflate(decoded_msg)
		local ok, command, data = self:Deserialize(decompressed_msg)
		
		if ok then 
			if command == "verTest" and not UnitIsUnit(sender, "player") then
				local sendData = {select(2, UnitClass("player")), 1, self.version}
				local serialized_data = self:Serialize("verTestReply", sendData)
				local compressed_data = Deflate:CompressDeflate(serialized_data, deflate_level)
				local encoded = Deflate:EncodeForPrint(compressed_data)
				self:SendCommMessage("betterRCLC_WotLK", encoded, "WHISPER", sender)
			end
		end
		
	end   
end

-- Used to make sure "WHISPER" type xrealm comms is handled properly.
-- Include this right after unpacking messages. Assumes you use "OnCommReceived" as comm handler:
-- if betterRCLC:HandleXRealmComms(self, command, data, sender) then return end
function betterRCLC:HandleXRealmComms(mod, command, data, sender)
	if command == "xrealm" then
		local target = tremove(data, 1)
		if self:UnitIsUnit(target, "player") then
			local command = tremove(data, 1)
			mod:OnCommReceived("betterRCLC", self:Serialize(command, data), "WHISPER", sender)
		end
		return true
	end
	return false
end

function betterRCLC:Debug(msg, ...)
	if self.debug then
		if select("#", ...) > 0 then
			self:Print("|cffcb6700debug:|r "..tostring(msg).."|cffff6767", ...)
		else
			self:Print("|cffcb6700debug:|r "..tostring(msg).."|r")
		end
	end
	betterRCLC:DebugLog(msg, ...)
end

local date_to_debug_log = true
--- /brc perf (stutter hunting): wraps a module's message handler and prints each call slower than 3 ms.
-- AceComm calls OnCommReceived by name, so replacing it after RegisterComm still works.
function betterRCLC:TimeComms(obj, label)
	local orig = obj.OnCommReceived
	obj.OnCommReceived = function(o, prefix, msg, distri, sender)
		if not betterRCLC.perf then return orig(o, prefix, msg, distri, sender) end
		local t = debugprofilestop()
		orig(o, prefix, msg, distri, sender)
		local ms = debugprofilestop() - t
		if ms > 3 then
			betterRCLC:Print(format("perf: %s '%s' from %s took %.1f ms (%d bytes)", label, tostring(betterRCLC.lastComm), tostring(sender), ms, #(msg or "")))
		end
	end
end

function betterRCLC:DebugLog(msg, ...)
	if date_to_debug_log then tinsert(debugLog, date("%x")); date_to_debug_log = false; end
	local time = date("%X", time())
	msg = time.." - ".. tostring(msg)
	for i = 1, select("#", ...) do msg = msg.." ("..tostring(select(i,...))..")" end
	if #debugLog > self.db.global.logMaxEntries then
		tremove(debugLog, 1)
	end
	tinsert(debugLog, msg)
end

function betterRCLC:Test(num)
	self:Debug("Test", num)
	local items = self:TestItems(num) -- from my own BiS list, not what I wear (Modules/main.lua)
	self.target = "Test" -- the board shows the boss after the item level
	for _, id in ipairs(items) do GetItemInfo(id) end -- ask the server for uncached items early

	self.testMode = true;
	self.isMasterLooter, self.masterLooter = self:GetML()

	-- We must be in a group and not the ML
	if not self.isMasterLooter then
		self:Print(L["You cannot initiate a test while in a group without being the MasterLooter."])
		self.testMode = false
		return
	end

	-- Call ML module and let it handle the rest
	self:CallModule("masterlooter")
	self:GetActiveModule("masterlooter"):NewML(self.masterLooter)
	self:GetActiveModule("masterlooter"):Test(items)
end

-- 0.4.0: RCLC's retail hack that rewired Blizzard's Interface Options Cancel button in combat is gone (no options
-- panel there any more, and touching that Blizzard frame could taint it)
function betterRCLC:EnterCombat()
	self.inCombat = true
end

function betterRCLC:LeaveCombat()
	self.inCombat = false
end

--[[
	Used by getCurrentGear to determine slot types
	Inspired by EPGPLootMaster
--]]
betterRCLC.INVTYPE_Slots = {
		INVTYPE_HEAD		    = "HeadSlot",
		INVTYPE_NECK		    = "NeckSlot",
		INVTYPE_SHOULDER	    = "ShoulderSlot",
		INVTYPE_CLOAK		    = "BackSlot",
		INVTYPE_CHEST		    = "ChestSlot",
		INVTYPE_WRIST		    = "WristSlot",
		INVTYPE_HAND		    = "HandsSlot",
		INVTYPE_WAIST		    = "WaistSlot",
		INVTYPE_LEGS		    = "LegsSlot",
		INVTYPE_FEET		    = "FeetSlot",
		INVTYPE_SHIELD		    = "SecondaryHandSlot",
		INVTYPE_ROBE		    = "ChestSlot",
		INVTYPE_2HWEAPON	    = {"MainHandSlot","SecondaryHandSlot"},
		INVTYPE_WEAPONMAINHAND	= "MainHandSlot",
		INVTYPE_WEAPONOFFHAND	= {"SecondaryHandSlot",["or"] = "MainHandSlot"},
		INVTYPE_WEAPON		    = {"MainHandSlot","SecondaryHandSlot"},
		INVTYPE_THROWN		    = {"RangedSlot"},
		INVTYPE_RANGED		    = {"RangedSlot"},
		INVTYPE_RANGEDRIGHT		= {"RangedSlot"},
		INVTYPE_FINGER		    = {"Finger0Slot","Finger1Slot"},
		INVTYPE_HOLDABLE	    = {"SecondaryHandSlot", ["or"] = "MainHandSlot"},
		INVTYPE_TRINKET		    = {"TRINKET0SLOT", "TRINKET1SLOT"},
		INVTYPE_RELIC			= {"RangedSlot"}
}

betterRCLC.Slots_INVTYPE = {
	["HeadSlot"]			= INVTYPE_HEAD,
	["NeckSlot"]			= INVTYPE_NECK,
	["ShoulderSlot"]		= INVTYPE_SHOULDER,
	["BackSlot"]			= INVTYPE_CLOAK,
	["ChestSlot"]			= INVTYPE_CHEST,
	["WristSlot"]			= INVTYPE_WRIST,
	["HandsSlot"]			= INVTYPE_HAND,
	["WaistSlot"]			= INVTYPE_WAIST,
	["LegsSlot"]			= INVTYPE_LEGS,
	["FeetSlot"]			= INVTYPE_FEET,
	["SecondaryHandSlot"] 	= INVTYPE_SHIELD,
	["ChestSlot"]			= INVTYPE_ROBE,
	["MainHandSlot"]		= INVTYPE_2HWEAPON,
	["SecondaryHandSlot"]	= INVTYPE_2HWEAPON,
	["MainHandSlot"]		= INVTYPE_WEAPONMAINHAN,
	["SecondaryHandSlot"] 	= INVTYPE_WEAPONOFFHAN,
	["MainHandSlot"]		= INVTYPE_WEAPONOFFHAN,
	["MainHandSlot"]		= INVTYPE_WEAPON,
	["SecondaryHandSlot"]	= INVTYPE_WEAPON,
	["RangedSlot"]			= INVTYPE_THROWN,
	["RangedSlot"]			= INVTYPE_RANGED,
	["RangedSlot"]			= INVTYPE_RANGEDRIGHT,
	["Finger0Slot"]			= INVTYPE_FINGER,
	["Finger1Slot"]			= INVTYPE_FINGER,
	["SecondaryHandSlot"]	= INVTYPE_HOLDABLE,
	["MainHandSlot"]		= INVTYPE_HOLDABLE,
	["TRINKET0SLOT"]		= INVTYPE_TRINKET,
	["TRINKET1SLOT"]		= INVTYPE_TRINKET,
	["RangedSlot"]			= INVTYPE_RELIC,
}

function betterRCLC:GetPlayersGear(link, equipLoc)
	local itemID = self:GetItemIDFromLink(link) -- Convert to itemID
	self:DebugLog("GetPlayersGear", itemID, equipLoc)
	if not itemID then return nil, nil; end
	local item1, item2;
	-- check if the item is a token, and if it is, return the matching current gear
	if BRCTokenTable[itemID] then
		if BRCTokenTable[itemID] == "Trinket" then -- We need to return both trinkets
			item1 = GetInventoryItemLink("player", GetInventorySlotInfo("TRINKET0SLOT"))
			item2 = GetInventoryItemLink("player", GetInventorySlotInfo("TRINKET1SLOT"))
		else	-- Just return the slot from the tokentable
			item1 = GetInventoryItemLink("player", GetInventorySlotInfo(BRCTokenTable[itemID]))
		end
		return item1, item2
	end

	if type(equipLoc) == "table" then -- if you're looking to fix t9 and 10 tokens, look here :)
		return nil, nil
	end

	local slot = self.INVTYPE_Slots[equipLoc]

	if not slot and self.Slots_INVTYPE[equipLoc] then 
		slot = equipLoc
	end

	if not slot then return nil, nil; end;
	item1 = GetInventoryItemLink("player", GetInventorySlotInfo(slot[1] or slot))
	if not item1 and slot['or'] then
		item1 = GetInventoryItemLink("player", GetInventorySlotInfo(slot['or']))
	end;
	if slot[2] then
		item2 = GetInventoryItemLink("player", GetInventorySlotInfo(slot[2]))
	end
	return item1, item2;
end

function betterRCLC:Timer(type, ...)
	self:Debug("Timer "..type.." passed")
	if type == "LocalizeSubTypes" then
		self:LocalizeSubTypes()
	elseif type == "MLdb_check" then
		-- If we have a ML
		if self.masterLooter then
			-- But haven't received the mldb, then request it
			if not self.mldb then
				self:SendCommand(self.masterLooter, "MLdb_request")
			end
			-- and if we haven't received a council, request it
			if not self.council then
				self:SendCommand(self.masterLooter, "council_request")
			end
		end
	end
end

-- Classes that should auto pass a subtype (weapon rows checked against the client's SkillRaceClassInfo.dbc)
local autopassTable = {}
if not AscensionUI then -- Ascension don't auto pass anything
	autopassTable = {
		["Cloth"]					= {"WARRIOR", "DEATHKNIGHT", "ROGUE", "HUNTER"},
		["Leather"] 				= {"PRIEST", "MAGE", "WARLOCK"},
		["Mail"] 					= {"DRUID", "ROGUE", "PRIEST", "MAGE", "WARLOCK"},
		["Plate"]					= {"DRUID", "ROGUE", "HUNTER", "SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Shields"] 				= {"DEATHKNIGHT", "DRUID", "ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK"},
		["Bows"] 					= {"DEATHKNIGHT", "PALADIN", "DRUID", "SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Crossbows"] 				= {"DEATHKNIGHT", "PALADIN", "DRUID", "SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Daggers"]					= {"DEATHKNIGHT", "PALADIN"},
		["Guns"]					= {"DEATHKNIGHT", "PALADIN", "DRUID","SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Fist Weapons"] 			= {"DEATHKNIGHT", "PALADIN", "PRIEST", "MAGE", "WARLOCK"},
		["One-Handed Axes"]			= {"DRUID", "PRIEST", "MAGE", "WARLOCK"},
		["One-Handed Maces"]		= {"HUNTER", "MAGE", "WARLOCK"},
		["One-Handed Swords"] 		= {"DRUID", "SHAMAN", "PRIEST"},
		["Polearms"] 				= {"ROGUE", "SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Staves"]					= {"DEATHKNIGHT", "PALADIN", "ROGUE"},
		["Thrown"]					= {"DEATHKNIGHT", "PALADIN", "DRUID", "SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Two-Handed Axes"]			= {"DRUID", "ROGUE", "PRIEST", "MAGE", "WARLOCK"},
		["Two-Handed Maces"]		= {"ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK"},
		["Two-Handed Swords"]		= {"DRUID", "ROGUE", "SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Wands"]					= {"WARRIOR", "DEATHKNIGHT", "PALADIN", "DRUID", "ROGUE", "HUNTER", "SHAMAN"},
		["Totems"]					= {"DEATHKNIGHT", "DRUID", "ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK", "PALADIN", "WARRIOR"},
		["Sigils"]					= {"DRUID", "ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK", "PALADIN", "WARRIOR", "SHAMAN"},
		["Idols"]					= {"DEATHKNIGHT", "ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK", "PALADIN", "WARRIOR", "SHAMAN"},
		["Librams"]					= {"DEATHKNIGHT", "DRUID", "ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK", "WARRIOR", "SHAMAN"},
	}
end

-- Used to find localized subType names
local subTypeLookup = {
	["Cloth"]					= 39252, -- Preceptor's Bindings
	["Leather"] 				= 39275, -- Contagion Gloves
	["Mail"] 					= 39274, -- Retcher's Shoulderpads
	["Plate"]					= 39262, -- Gauntlets of Combined Strength
	["Shields"] 				= 40400, -- Wall of Terror
	["Bows"] 					= 40265, -- Arrowsong
	["Crossbows"] 				= 40346, -- Final Voyage
	["Daggers"]					= 39714, -- Webbed Death
	["Guns"]					= 40385, -- Envoy of Mortality
	["Fist Weapons"] 			= 40239, -- The hand of Nerub
	["One-Handed Axes"]			= 40402, -- Last Laugh
	["One-Handed Maces"]		= 40395, -- Torch of Holy Fire
	["One-Handed Swords"] 		= 40407, -- Silent Crusader
	["Polearms"] 				= 40208, -- Cryptfiend's Bite
	["Staves"]					= 40300, -- Spire of Sunset
	["Thrown"]					= 40190, -- Spinning Fate
	["Two-Handed Axes"]			= 40384, -- Betrayer of Humanity
	["Two-Handed Maces"]		= 39758, -- The Jawbone
	["Two-Handed Swords"]		= 40343, -- Armageddon
	["Wands"]					= 40335, -- Touch of Horror
	["Totems"]					= 51507, -- Wrathful Gladiator Totem
	["Sigils"]					= 51417, -- Wrathful Gladiator Sigil
	["Idols"]					= 51429, -- Wrathful Gladiator Idol
	["Librams"]					= 40707, -- Libram of Obstruction
}

-- Never autopass these armor types
local autopassOverride = {
	"INVTYPE_CLOAK",
}

function betterRCLC:AutoPassCheck(subType, equipLoc, link)
	if not tContains(autopassOverride, equipLoc) then
		if subType and autopassTable[self.db.global.localizedSubTypes[subType]] then
			return tContains(autopassTable[self.db.global.localizedSubTypes[subType]], self.playerClass)
		end
		-- The item wasn't a type we check for, but it might be a token
		local id = type(link) == "number" and link or self:GetItemIDFromLink(link) -- Convert to id if needed
		if BRCTokenClasses[id] then -- It's a token
			return not tContains(BRCTokenClasses[id], self.playerClass)
		end
	end
	return false
end

function betterRCLC:LocalizeSubTypes()
	if self.db.global.localizedSubTypes.created then return end -- We only need to create it once
	-- Get the item info
	for _, item in pairs(subTypeLookup) do
		GameTooltip:Hide()
		GameTooltip:SetHyperlink("item:"..item) -- force item update
		GetItemInfo(item)
	end
	self.db.global.localizedSubTypes = {} -- reset
	self.db.global.localizedSubTypes.created = true
	for name, item in pairs(subTypeLookup) do
		local sType = select(7, GetItemInfo(item))
		if sType then
			self.db.global.localizedSubTypes[sType] = name
			self:DebugLog("Found "..name.." localized as: "..sType)
		else -- Probably not cached, set a timer
			self:Debug("We didn't find:", name, item)
			self:ScheduleTimer("Timer", 2, "LocalizeSubTypes")
			self.db.global.localizedSubTypes.created = false
			return
		end
	end
end

function betterRCLC:IsItemBoE(item)
	if not item then return false end
	GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
	GameTooltip:SetHyperlink(item)
	if GameTooltip:NumLines() > 1 then -- check that there is something here
		for i = 1, 5 do -- BoE status won't be further away than line 5
			local line = getglobal('GameTooltipTextLeft' .. i)
			if line and line.GetText then
				if line:GetText() == ITEM_BIND_ON_EQUIP then
					GameTooltip:Hide()
					return true
				end
			end
		end
	end
	GameTooltip:Hide()
	return false
end

--- Formats a response for the player to be send to the group
-- @param session		The session to respond to
-- @param link 		The itemLink of the item in the session
-- @param ilvl			The ilvl of the item in the session
-- @param response	The selected response, must be index of db.responses
-- @param equipLoc	The item in the session's equipLoc
-- @param note			The player's note
-- @returns A formatted table that can be passed directly to :SendCommand("group", "response", -return-)
function betterRCLC:CreateResponse(session, link, ilvl, response, equipLoc, note)
	self:DebugLog("CreateResponse", session, link, ilvl, response, equipLoc, note)
	local g1, g2 = self:GetPlayersGear(link, equipLoc)
	local ms, os, oss = self.BIS:MySpecs()
	local diff = nil
	if g1 then 
		diff = (ilvl - select(4, GetItemInfo(g1))) 
	end
	if g1 and g2 then 
		local g2diff = (ilvl - select(4, GetItemInfo(g2))) 
		local test1, test2 = abs(diff), abs(g2diff) 
		if test2 > test1 then 
			diff = g2diff 
		end
	elseif g2 then  -- this shouldn't be possible but idk i dont wanna come back and fix it later if it somehow is
		diff = (ilvl - select(4, GetItemInfo(g2)))
	end

	local ilvl = GearScore_GetScore and GearScore_GetScore(UnitName("player"), "player") or 0
	if ilvl == 0 then 
		if GS_Data then 
			ilvl = GS_Data[GetRealmName()].Players[UnitName("player")].GearScore or 0
		end
	end
	local up = self.Upgrade:ForResponse(link, ms, oss)
	return
		session,
		self.playerName,
		{	epMS = up.epMS, epOS = up.epOS,
			gear1 = g1,
			gear2 = g2,
			ilvl = ilvl,
			diff = diff,
			note = note,
			response = response,
			ms = ms, -- spec keys "CLASS:Spec" for the guild BiS lists
			os = os, -- first off spec (older clients read only this)
			oss = oss, -- every off spec I ticked (may be empty: no off spec)
		}
end

function betterRCLC:GetPlayersGuildRank()
	self:DebugLog("GetPlayersGuildRank()")
	GuildRoster() -- let the event trigger this func
	if IsInGuild() then
		local rank = select(2, GetGuildInfo("player"))
		if rank then
			self:Debug("Found Guild Rank: "..rank)
			unregisterGuildEvent = true;
			return rank;
		else
			return L["Not Found"];
		end
	else
		return L["Unguilded"];
	end
end

function betterRCLC:GetPlayerInfo()
	-- Check if the player has enchanting
	local enchant, lvl = IsSpellKnown(13262), 0 -- disenchant spell 
	if enchant then lvl = 450 end -- assume max enchanting idc
	return self.playerName, self.playerClass, self:GetPlayerRole(), self.guildRank, enchant, lvl
end

function betterRCLC:GetUnitRole(unit)
	local gtrole = LibGroupTalents:GetUnitRole(unit)
	local role = "DAMAGER"
	
	if gtrole == "tank" then 
		role = "TANK"
	elseif gtrole == "healer" then 
		role = "HEALER"
	end

	return role
end

function betterRCLC:GetPlayerRole()
	return self:GetUnitRole("player")	
end

function betterRCLC.TranslateRole(role) -- reasons
	return (role and role ~= "") and betterRCLC.roleTable[role] or ""
end

--- GetGuildRanks
-- Returns a lookup table containing GuildRankNames and their index
-- @return table "GuildRankName" = rankIndex
function betterRCLC:GetGuildRanks()
	if not IsInGuild() then return {} end
	self:DebugLog("GetGuildRankNum()")
	GuildRoster()
	local t = {}
	for i = 1, GuildControlGetNumRanks() do
		local name = GuildControlGetRankName(i)
		t[name] = i
	end
	return t;
end

function betterRCLC:GetNumberOfDaysFromNow(oldDate)
	local d, m, y = strsplit("/", oldDate, 3)
	local sinceEpoch = time({year = "20"..y, month = m, day = d}) -- convert from string to seconds since epoch
	local diff = date("*t", time() - sinceEpoch) -- get the difference as a table
	-- Convert to number of d/m/y
	return diff.day - 1, diff.month - 1, diff.year - 1970
end

function betterRCLC:ConvertDateToString(day, month, year)
	local text = format(L["x days"], day)
	if year > 0 then
		text = format(L["days, x months, y years"], text, month, year)
	elseif month > 0 then
		text = format(L["days and x months"], text, month)
	end
	return text;
end

function betterRCLC:OnEvent(event, ...)
	if event == "PARTY_LOOT_METHOD_CHANGED" then
		self:Debug("Event:", event, ...)
		self:NewMLCheck()

	elseif event == "RAID_ROSTER_UPDATE" then
		self:Debug("Event:", event, ...)
		self:NewMLCheck()

	elseif event == "RAID_INSTANCE_WELCOME" then
		self:Debug("Event:", event, ...)
		-- high server-side latency causes the UnitIsGroupLeader("player") condition to fail if queried quickly (upon entering instance) regardless of state.
		-- NOTE v2.0: Not sure if this is still an issue, but just add a 2 sec timer to the MLCheck call
		self:ScheduleTimer("OnRaidEnter", 2)

	elseif event == "PLAYER_ENTERING_WORLD" then
		self:Debug("Event:", event, ...)
		local is_retry = ...
		self:NewMLCheck()
		if not self.masterLooter and not is_retry then -- retry once just incase it didn't send
			self:ScheduleTimer("OnEvent", 1, "PLAYER_ENTERING_WORLD", true)
			self:Debug("Retry PLAYER_ENTERING_WORLD")
			return
		end
		-- Ask for data when we have done a /rl and have a ML
		if not self.isMasterLooter and self.masterLooter and self.masterLooter ~= "" and player_relogged then
			self:ScheduleTimer("SendCommand", 2, self.masterLooter, "reconnect")
			self:SendCommand(self.masterLooter, "playerInfo", self:GetPlayerInfo()) -- Also send out info, just in case
		end
		player_relogged = false

	elseif event == "GUILD_ROSTER_UPDATE" then
		self.guildRank = self:GetPlayersGuildRank();
		if unregisterGuildEvent then
			self:UnregisterEvent("GUILD_ROSTER_UPDATE"); -- we don't need it any more
		end
	end
end

function betterRCLC:NewMLCheck()
	local old_ml = self.masterLooter
	self.isMasterLooter, self.masterLooter = self:GetML()
	self:Debug("isMasterLooter", self.isMasterLooter, "masterLooter", self.masterLooter)
	if self:UnitIsUnit(old_ml, "player") and not self.isMasterLooter then
		-- We were ML, but no longer, so disable masterlooter module
		self:GetActiveModule("masterlooter"):Disable()
	end
	if self:UnitIsUnit(old_ml, self.masterLooter) or db.usage.never then return end -- no change
	if not self.isMasterLooter and self.masterLooter then return end -- Someone else is ML

	-- We are ML and shouldn't ask the player for usage
	if self.isMasterLooter and db.usage.ml then -- addon should auto start
		self:Print(L["Now handles looting"])
		if db.autoAward and GetLootThreshold() ~= 2 and GetLootThreshold() > db.autoAwardLowerThreshold  then
			self:Print(L["Changing loot threshold to enable Auto Awarding"])
			SetLootThreshold(db.autoAwardLowerThreshold >= 2 and db.autoAwardLowerThreshold or 2)
		end
		self:CallModule("masterlooter")
		self:GetActiveModule("masterlooter"):NewML(self.masterLooter)

	end
end

function betterRCLC:OnRaidEnter(arg)
	-- NOTE: We shouldn't need to call GetML() as it's most likely called on "LOOT_METHOD_CHANGED"
	-- There's no ML, and lootmethod ~= ML, but we are the group leader
	if not self.masterLooter and (IsRaidLeader() or IsPartyLeader()) then
		-- We don't need to ask the player for usage, so change loot method to master, and make the player ML
		if db.usage.leader then
			SetLootMethod("master", self.playerName)
			self:Print(L[" you are now the Master Looter and betterRCLC is now handling looting."])
			if db.autoAward and GetLootThreshold() ~= 2 and GetLootThreshold() > db.autoAwardLowerThreshold  then
				self:Print(L["Changing loot threshold to enable Auto Awarding"])
				SetLootThreshold(db.autoAwardLowerThreshold >= 2 and db.autoAwardLowerThreshold or 2)
			end
			self.isMasterLooter, self.masterLooter = true, self.playerName
			self:CallModule("masterlooter")
			self:GetActiveModule("masterlooter"):NewML(self.masterLooter)

		end
	end
end

-- Returns boolean, mlName. (true if the player is ML), (nil if there's no ML)
function betterRCLC:GetML()
	self:DebugLog("GetML()")
	if self:GetNumGroupMembers() == 0 and (self.testMode or self.nnp) then -- always the player when testing alone
		return true, self.playerName
	end
	local lootMethod, mlPartyID, mlRaidID = GetLootMethod()
	self:Debug("LootMethod = ", lootMethod)
	if lootMethod == "master" then
		local name;
		if mlRaidID then 				-- Someone in raid
			name = UnitName("raid"..mlRaidID)
		elseif mlPartyID == 0 then -- Player in party
			name = self.playerName
		elseif mlPartyID then		-- Someone in party
			name = UnitName("party"..mlPartyID)
		end
		self:Debug("MasterLooter = ", name)
		-- Check to see if we have recieved mldb within 10 secs, otherwise request it
		self:ScheduleTimer("Timer", 10, "MLdb_check")
		return self:UnitIsUnit(name, "player"), name
	end
	return false, nil;
end

function betterRCLC:IsCouncil(name)
	local ret = tContains(self.council, name)
	if self:UnitIsUnit(name, self.playerName) and self.isMasterLooter or self.nnp then ret = true end -- ML and nnp is always council
	self:DebugLog(tostring(ret).." =", "IsCouncil", name)
	return ret
end


function betterRCLC:SessionError(...)
	self:Print(L["session_error"])
	self:Debug(...)
end

function betterRCLC:Getdb()
	return db
end

function betterRCLC:GetHistoryDB()
	if self.isMasterLooter or (not self:IsInGroup() and not self:IsInRaid()) then 
		return self.lootDB.factionrealm
	else 
		return self.mlhistory 
	end
end

function betterRCLC:GetAnnounceChannel(channel)
	return channel == "group" and (self:IsInRaid() and "RAID" or "PARTY") or channel
end

function betterRCLC:GetItemIDFromLink(link)
	return tonumber(strmatch(link, "item:(%d+):"))
end

--- Custom, better UnitIsUnit() function
-- Blizz UnitIsUnit() doesn't know how to compare unit-realm with unit
-- Seems to be because unit-realm isn't a valid unitid
function betterRCLC:UnitIsUnit(unit1, unit2)
	if not unit1 or not unit2 then return false end
	-- Remove realm names, if any
	if strfind(unit1, "-", nil, true) ~= nil then
		unit1 = unit1
	end
	if strfind(unit2, "-", nil, true) ~= nil then
		unit2 = unit2
	end
	return UnitIsUnit(unit1, unit2)
end

---------------------------------------------------------------------------
-- Custom module support funcs
---------------------------------------------------------------------------

--- Enables a userModule if set, defaultModule otherwise
-- @paramsig module
-- @param module String, must correspond to a index in self.defaultModules
function betterRCLC:CallModule(module)
	if not self.enabled then return end -- Don't call modules unless enabled
	self:EnableModule(userModules[module] or defaultModules[module])
end

--- Returns the active module
--	Always use this when calling functions in another module
-- @paramsig module
-- @param module String, must correspond to a index in self.defaultModules
-- @return The module object of the active module or nil if not found. Prioritises userModules if set
function betterRCLC:GetActiveModule(module)
	return self:GetModule(userModules[module] or defaultModules[module], false)
end

--- Registers a module that should override a default module
-- The custom module must have all functions that a default module can be called with
-- @param type Index (string) in userModules
-- @param The name passed to AceAddon:NewModule()
function betterRCLC:RegisterUserModule(type, name)
	assert(defaultModules[type], format("Module \"%s\" is not a default module.", tostring(type)))
	userModules[type] = name
end

--#end Module support -----------------------------------------------------


---------------------------------------------------------------------------
-- UI Functions used throughout the addon
---------------------------------------------------------------------------

--- Used as a "DoCellUpdate" function for lib-st
function betterRCLC.SetCellClassIcon(rowFrame, frame, data, cols, row, realrow, column, fShow, table, class)
	local celldata = data[realrow].cols and data[realrow].cols[column] or data[realrow][column]
	local class = celldata.args and celldata.args[1] or class
	if class then
		frame:SetNormalTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"); -- this is the image containing all class icons
		local coords = CLASS_ICON_TCOORDS[class]; -- get the coordinates of the class icon we want
		frame:GetNormalTexture():SetTexCoord(unpack(coords)); -- cut out the region with our class icon according to coords
	else -- if there's no class
		frame:SetNormalTexture("Interface/ICONS/INV_Sigil_Thorim.png")
	end
end

--- Returns a color table for use with lib-st
function betterRCLC:GetClassColor(class)
	local color = RAID_CLASS_COLORS[class]
	if not color then
		-- if class not found, return epic color.
		return {r=1,g=1,b=1,a=1}--{["r"] = 0.63921568627451, ["g"] = 0.2078431372549, ["b"] = 0.93333333333333, ["a"] = 1.0 };
	else
		color.a = 1.0
		return color
	end
end

function betterRCLC:RGBToHex(r,g,b)
	return string.format("%02x%02x%02x",255*r, 255*g, 255*b)
end

--- Creates a standard frame for betterRCLC with title, minimizuing, positioning and zoom support.
--		Adds Minimize(), Maximize() and IsMinimized() functions on the frame, and registers it for hide on combat.
--		SetWidth/SetHeight called on frame will also be called on frame.content
--		Minimizing is done by double clicking the title. The returned frame and frame.title is NOT minimized.
-- 	Only frame.content is minimized, so put children there for minimize support.
-- @paramsig name, cName, title[, width, height]
-- @param name Global name of the frame
-- @param cName Name of the module (used for lib-window-1.1 config in db.UI[cName])
-- @param title The title text
-- @param width The width of the titleframe, defaults to 250
-- @param height Height of the frame, defaults to 325
-- @return The frame object
function betterRCLC:CreateFrame(name, cName, title, width, height)
	local f = CreateFrame("Frame", name, nil) -- LibWindow seems to work better with nil parent
	f:Hide()
	f:SetFrameStrata("HIGH")
	f:SetWidth(width or 450)
	f:SetHeight(height or 325)
	lwin:Embed(f)
	f:RegisterConfig(db.UI[cName])
	f:RestorePosition() -- might need to move this to after whereever GetFrame() is called
	f:MakeDraggable()
	f:EnableMouseWheel(true)
	f:SetScript("OnMouseWheel", function(f,delta) if IsControlKeyDown() then lwin.OnMouseWheel(f,delta) end end)

	local tf = CreateFrame("Frame", nil, f)
	tf:SetBackdrop({
	     bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
	     edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	     tile = true, tileSize = 64, edgeSize = 12,
	     insets = { left = 2, right = 2, top = 2, bottom = 2 }
	})
	tf:SetBackdropColor(0,0,0,0.7)
	tf:SetBackdropBorderColor(0.6,0.6,0.6,1)
	tf:SetHeight(22)
	tf:EnableMouse()
	tf:SetMovable(true)
	tf:SetWidth(width or 250)
	tf:SetPoint("CENTER",f,"TOP",0,-1)
	tf:SetScript("OnMouseDown", function(self) self:GetParent():StartMoving() end)
	tf:SetScript("OnMouseUp", function(self) -- Get double click by trapping time betweem mouse up
		local frame = self:GetParent()
		frame:StopMovingOrSizing()
		frame:SavePosition()
		if self.lastClick and GetTime() - self.lastClick <= 0.5 then
			self.lastClick = nil
			if frame.minimized then frame:Maximize() else frame:Minimize() end
		else
			self.lastClick = GetTime()
		end
	end)

	local text = tf:CreateFontString(nil,"OVERLAY","GameFontNormal")
	text:SetPoint("CENTER",tf,"CENTER")
	text:SetTextColor(1,1,1,1)
	text:SetText(title)
	tf.text = text
	f.title = tf

	local c = CreateFrame("Frame", nil, f) -- frame that contains the actual content
	c:SetBackdrop({
	   --bgFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Background",
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	   edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	   tile = true, tileSize = 64, edgeSize = 12,
	   insets = { left = 2, right = 2, top = 2, bottom = 2 }
	})
	c:EnableMouse(true)
	c:SetWidth(450)
	c:SetHeight(height or 325)
	c:SetBackdropColor(0.21,0.21,0.21,1)
	c:SetBackdropBorderColor(0.3,0.3,0.5,1)
	c:SetPoint("TOPLEFT")
	c:SetScript("OnMouseDown", function(self) self:GetParent():StartMoving() end)
	c:SetScript("OnMouseUp", function(self) self:GetParent():StopMovingOrSizing(); self:GetParent():SavePosition() end)
	f.content = c
	f.minimized = false
	f.IsMinimized = function(frame) return frame.minimized end
	f.Minimize = function(frame)
		self:Debug("Minimize()")
		if not frame.minimized then
		  	frame.content:Hide()
			frame.minimized = true
		end
	end
	f.Maximize = function(frame)
		self:Debug("Maximize()")
		if frame.minimized then
		  	frame.content:Show()
			frame.minimized = false
		end
	end
	self:SkinWindow(f)
	-- Support for auto hide in combat:
	tinsert(frames, f)
	local old_setwidth = f.SetWidth
	f.SetWidth = function(self, width) -- Hack so we only have to set width once
		old_setwidth(self, width)
		self.content:SetWidth(width)
	end
	local old_setheight = f.SetHeight
	f.SetHeight = function(self, height)
		old_setheight(self, width)
		self.content:SetHeight(height)
	end
	return f
end

--- Creates a standard button for betterRCLC
-- @param text The button's text
-- @param parent The frame that should hold the button
-- @return The button object
function betterRCLC:CreateButton(text, parent)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetText(text)
	b:SetSize(100,25)
	return self:SkinButton(b)
end

--- Displays a tooltip anchored to the mouse
-- @paramsig ...
-- @param ... Lines to be added.
function betterRCLC:CreateTooltip(...)
	GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
	for i = 1, select("#", ...) do
		GameTooltip:AddLine(select(i, ...),1,1,1)
	end
	GameTooltip:Show()
end

--- Displays a hyperlink tooltip
-- @paramsig link
-- @param link The link to display
function betterRCLC:CreateHypertip(link)
	if not link or link == "" then return end
	GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
	GameTooltip:SetHyperlink(link)
end

--- Hide the tooltip created with :CreateTooltip()
function betterRCLC:HideTooltip()
	GameTooltip:Hide()
end


--- The answer buttons are fixed (0.4.1, raid leader): the same three for everyone, shown in BUTTON_ORDER
-- (BiS | Upgrade | OS). The answer numbers stay 1 = main spec, 2 = off spec, 3 = upgrade (history and older clients
-- use them). kind: "ms" sorts by the BiS list and counts as a win for +1; roll = top of the addon's roll.
local BUTTONS = {
	{text = "BiS", short = "BiS", kind = "ms", roll = 100},
	{text = "Off spec", short = "OS", kind = "os", roll = 99},
	{text = "Upgrade roll", short = "Upgrade", kind = "up", roll = 98},
}
betterRCLC.BUTTONS = BUTTONS
betterRCLC.BUTTON_ORDER = {1, 3, 2}

--- One colour per answer everywhere (cards, board groups, side panel, award buttons, history), as in BetterRolls:
-- BiS / main spec green, off spec gold, upgrade blue, pass red, no answer grey.
betterRCLC.ANSWER_COLORS = {ms = {0.34, 0.80, 0.45}, os = {0.95, 0.78, 0.30}, up = {0.45, 0.72, 1.00},
	pass = {0.90, 0.36, 0.33}, wait = {0.55, 0.55, 0.55}}

--- Colour of an answer: a button number, "PASS" / "AUTOPASS", or anything else (waiting, offline...).
function betterRCLC:AnswerColor(response)
	local c = self.ANSWER_COLORS
	local k = self:ButtonKind(response)
	if k then return c[k] or c.wait end
	if response == "PASS" or response == "AUTOPASS" then return c.pass end
	return c.wait
end

--- "|cffRRGGBBtext|r" in an answer colour.
function betterRCLC:AnswerText(response, text)
	local c = self:AnswerColor(response)
	local function hex(v) return math.floor(v * 255 + 0.5) end
	return format("|cff%02x%02x%02x%s|r", hex(c[1]), hex(c[2]), hex(c[3]), text)
end

function betterRCLC:GetButtonText(i)
	return BUTTONS[i] and BUTTONS[i].text or "Unknown"
end

function betterRCLC:ButtonKind(i)
	if type(i) ~= "number" then return nil end
	return BUTTONS[i] and BUTTONS[i].kind or "other"
end

function betterRCLC:ButtonRoll(i)
	return BUTTONS[i] and BUTTONS[i].roll
end

function betterRCLC:NumButtons() return #BUTTONS end

--- The answer button of a kind (ms / os / up).
function betterRCLC:ButtonOf(kind)
	for i, b in ipairs(BUTTONS) do if b.kind == kind then return i end end
end

--- Short label (cards, board headers, award buttons).
function betterRCLC:ShortButtonText(i)
	return BUTTONS[i] and BUTTONS[i].short or self:GetButtonText(i)
end

--- A loot history entry that counts as a main-spec win (+1). Old entries have no kind: answer 1 was main spec.
function betterRCLC:IsMSWin(e)
	if e.isAwardReason then return false end
	if e.kind then return e.kind == "ms" end
	return e.responseID == 1
end

--- The following functions returns the text, sort or color of a response, returning a result from mldb if possible, otherwise the default responses.
-- @paramsig response
-- @param response Index in db.responses
function betterRCLC:GetResponseText(response)
	if BUTTONS[response] then return BUTTONS[response].text end
	return (self.mldb.responses and self.mldb.responses[response]) and self.mldb.responses[response].text or db.responses[response] and db.responses[response].text or "Unknown Response"
end

function betterRCLC:GetResponseColor(response)
	local color = (self.mldb.responses and self.mldb.responses[response]) and self.mldb.responses[response].color or db.responses[response] and db.responses[response].color or {1, 1, 1, 1}
	return unpack(color)
end

function betterRCLC:GetResponseColorTable(response)
	local color = (self.mldb.responses and self.mldb.responses[response]) and self.mldb.responses[response].color or db.responses[response] and db.responses[response].color or {1, 1, 1, 1}
	return color
end

function betterRCLC:GetResponseSort(response)
	return (self.mldb.responses and self.mldb.responses[response]) and self.mldb.responses[response].sort or db.responses[response].sort
end

--#end UI Functions -----------------------------------------------------
--@debug@
-- debug func
function printtable( data, level )
	level = level or 0
	local ident=strrep('     ', level)
	if level>6 then return end
	if type(data)~='table' then print(tostring(data)) end;
	for index,value in pairs(data) do repeat
		if type(value)~='table' then
			print( ident .. '['..index..'] = ' .. tostring(value) .. ' (' .. type(value) .. ')' );
			break;
		end
		print( ident .. '['..index..'] = {')
        printtable(value, level+1)
        print( ident .. '}' );
	until true end
end
--@end-debug@

betterRCLC:TimeComms(betterRCLC, "core")
