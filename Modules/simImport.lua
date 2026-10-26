-- simImport.lua  Turns a wowsims share link or a wowsims JSON export into a guild BiS list (Discord format).
-- Link: the part after '#' = base64 (std or url-safe) of zlib-compressed binary IndividualSimSettings.
-- Protobuf fields used: IndividualSimSettings.player = 3; Player.class = 2, equipment = 3, talents_string = 17,
-- spec oneof (feral tank 26, tank DK 32); EquipmentSpec.items = 1 (wowsims slot order); ItemSpec.id = 2.

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local Deflate = LibStub("LibDeflate")

local SI = {}
addon.SimImport = SI

local CLASS = {"DRUID", "HUNTER", "MAGE", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR", "DEATHKNIGHT"}
local JSON_CLASS = {ClassDruid = "DRUID", ClassHunter = "HUNTER", ClassMage = "MAGE", ClassPaladin = "PALADIN",
	ClassPriest = "PRIEST", ClassRogue = "ROGUE", ClassShaman = "SHAMAN", ClassWarlock = "WARLOCK",
	ClassWarrior = "WARRIOR", ClassDeathknight = "DEATHKNIGHT", ClassDeathKnight = "DEATHKNIGHT"}
SI.SLOTS = {"Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet",
	"Ring", "Ring", "Trinket", "Trinket", "Main Hand", "Off Hand", "Ranged"}

------------------------------------------------------------------------
-- base64 (arithmetic only, works without the bit library)
------------------------------------------------------------------------
local B64 = {}
do
	local a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	for i = 1, 62 do B64[a:sub(i, i)] = i - 1 end
	B64["+"], B64["-"], B64["/"], B64["_"] = 62, 62, 63, 63
end

function SI.Base64(s)
	s = s:gsub("[%s=]", "")
	local out, acc, bits = {}, 0, 0
	for i = 1, #s do
		local v = B64[s:sub(i, i)]
		if not v then return nil end
		acc, bits = acc * 64 + v, bits + 6
		if bits >= 8 then
			bits = bits - 8
			local p = 2 ^ bits
			local byte = math.floor(acc / p)
			out[#out + 1] = string.char(byte)
			acc = acc - byte * p
		end
	end
	return table.concat(out)
end

------------------------------------------------------------------------
-- protobuf: read the fields of one message as {[field] = {values...}}; bytes fields stay strings
------------------------------------------------------------------------
local function Varint(s, pos)
	local v, mul = 0, 1
	while true do
		local b = s:byte(pos)
		if not b then return nil end
		pos = pos + 1
		v = v + (b % 128) * mul
		if b < 128 then return v, pos end
		mul = mul * 128
	end
end

function SI.Fields(s)
	local f, pos = {}, 1
	while pos <= #s do
		local key, v
		key, pos = Varint(s, pos)
		if not key then return nil end
		local num, wt = math.floor(key / 8), key % 8
		if wt == 0 then
			v, pos = Varint(s, pos)
		elseif wt == 2 then
			local len
			len, pos = Varint(s, pos)
			if not len then return nil end
			v = s:sub(pos, pos + len - 1)
			pos = pos + len
		elseif wt == 1 then
			pos = pos + 8
		elseif wt == 5 then
			pos = pos + 4
		else
			return nil -- groups are not used by wowsims
		end
		if not pos then return nil end
		f[num] = f[num] or {}
		table.insert(f[num], v or 0)
	end
	return f
end

------------------------------------------------------------------------
-- spec from the talent string: the tree with the most points
------------------------------------------------------------------------
function SI.SpecFromTalents(class, talents, tank)
	local specs = addon.BIS.SPECS[class]
	if not specs then return nil end
	if tank and class == "DRUID" then return "Feral (Bear)" end
	if tank and class == "DEATHKNIGHT" then return "Tank" end
	local best, bestN, i = 1, -1, 0
	for tree in ((talents or "") .. "-"):gmatch("([^-]*)-") do
		i = i + 1
		local n = 0
		for d in tree:gmatch("%d") do n = n + tonumber(d) end
		if n > bestN and specs[i] then best, bestN = i, n end
	end
	return specs[best]
end

------------------------------------------------------------------------
-- parsers
------------------------------------------------------------------------
function SI.FromLink(text)
	local hash = text:match("#([%w%+/%-_=]+)")
	if not hash then return nil, "no '#...' part in the link" end
	local raw = SI.Base64(hash)
	local data = raw and Deflate:DecompressZlib(raw)
	if not data then return nil, "the link could not be decoded (cut off when copied?)" end
	local top = SI.Fields(data)
	local player = top and top[3] and SI.Fields(top[3][1])
	if not player then return nil, "no player in the link" end
	local class = player[2] and CLASS[player[2][1]]
	if not class then return nil, "unknown class" end
	local items = {}
	local eq = player[3] and SI.Fields(player[3][1])
	for i, spec in ipairs(eq and eq[1] or {}) do
		local f = SI.Fields(spec)
		items[i] = f and f[2] and f[2][1] or 0
	end
	local talents = player[17] and player[17][1]
	return {class = class, items = items, talents = talents,
		spec = SI.SpecFromTalents(class, talents, player[26] or player[32])}
end

-- JSON export ("Export -> JSON" on the site). Only the fields we need, read with patterns.
function SI.FromJSON(text)
	local class = JSON_CLASS[text:match('"class"%s*:%s*"(%w+)"') or ""]
	if not class then return nil, "no \"class\" in the JSON" end
	local start = text:find('"equipment"%s*:%s*{%s*"items"%s*:%s*%[')
	if not start then return nil, "no equipment in the JSON" end
	local pos = text:find("%[", start)
	local items, depth, objStart = {}, 0, nil
	for i = pos + 1, #text do
		local c = text:sub(i, i)
		if c == "{" then
			depth = depth + 1
			if depth == 1 then objStart = i end
		elseif c == "}" then
			depth = depth - 1
			if depth == 0 then
				-- only the item's own top-level "id" (gems/enchant are named differently, nested objects skipped)
				local obj = text:sub(objStart, i):gsub("%b[]", "")
				items[#items + 1] = tonumber(obj:match('[{,]%s*"id"%s*:%s*(%d+)')) or 0
			end
		elseif c == "]" and depth == 0 then
			break
		end
	end
	local talents = text:match('"talentsString"%s*:%s*"([%d%-]*)"')
	local tank = text:find('"feralTankDruid"') or text:find('"tankDeathknight"')
	return {class = class, items = items, talents = talents, spec = SI.SpecFromTalents(class, talents, tank)}
end

--- Link or JSON -> {class, spec, items, talents} or nil, error.
function SI:Parse(text)
	text = text or ""
	if text:find("^%s*{") then return SI.FromJSON(text) end
	if text:find("#") then return SI.FromLink(text) end
	return nil, "paste a wowsims link (.../#...) or the site's JSON export"
end

--- Discord-format list text from a parsed sim (empty slots skipped).
function SI:ToText(sim)
	local lines = {}
	for i, slot in ipairs(self.SLOTS) do
		local id = sim.items[i]
		if id and id > 0 then lines[#lines + 1] = slot .. " " .. id end
	end
	return table.concat(lines, "\n")
end
