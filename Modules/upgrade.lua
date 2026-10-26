-- upgrade.lua  How much a drop is worth to me, computed on the raider's own client and sent in the response.
-- Two values, the ML picks which one the council sees (mldb.upgradeMode = "ep" | "ilvl"):
--   EP: per-spec stat weights (Data/epWeights.lua) on GetItemStats(), drop minus what I wear in that slot.
--   ilvl: the old RCLC item level difference (core.lua CreateResponse).
-- Not valued: trinket procs, set bonuses, gems already socketed (sockets count as one typical gem each).

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")
local LibToken = LibStub("LibArmorToken-1.0")

local UP = {}
addon.Upgrade = UP

-- inventory slot ids
local HEAD, NECK, SHOULDER, CHEST, WAIST, LEGS, FEET, WRIST, HANDS = 1, 2, 3, 5, 6, 7, 8, 9, 10
local FINGER1, FINGER2, TRINKET1, TRINKET2, BACK, MH, OH, RANGED = 11, 12, 13, 14, 15, 16, 17, 18

local SINGLE = {
	INVTYPE_HEAD = HEAD, INVTYPE_NECK = NECK, INVTYPE_SHOULDER = SHOULDER, INVTYPE_CLOAK = BACK, INVTYPE_CHEST = CHEST,
	INVTYPE_ROBE = CHEST, INVTYPE_WRIST = WRIST, INVTYPE_HAND = HANDS, INVTYPE_WAIST = WAIST, INVTYPE_LEGS = LEGS,
	INVTYPE_FEET = FEET,
}
local RANGED_TYPES = {INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true, INVTYPE_RELIC = true}
local OFFHAND_TYPES = {INVTYPE_WEAPONOFFHAND = true, INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true}

--- EP of one item for a spec, as worn in hand "mh" | "oh" | "ranged" (weapon DPS weight) or nil (armor).
-- Returns nil when the item is not cached or the spec has no weights.
function UP:Score(specKey, link, hand)
	local w = addon.EP_WEIGHTS and addon.EP_WEIGHTS[specKey]
	if not w or not link then return nil end
	local stats = GetItemStats(link)
	if not stats then return nil end
	local ep = 0
	for k, v in pairs(stats) do
		ep = ep + v * (w.stats[k] or 0)
	end
	local dps = stats.ITEM_MOD_DAMAGE_PER_SECOND_SHORT
	if dps and hand then ep = ep + dps * (w.dps[hand] or 0) end
	return ep
end

local function Worn(slot)
	return GetInventoryItemLink("player", slot)
end

local function EquipLoc(link)
	return link and select(9, GetItemInfo(link))
end

-- EP gain of a plain (non-token) item for a spec, or nil if unknown.
local function Gain(self, spec, link, loc)
	local new = self:Score(spec, link, nil)
	if not new then return nil end
	local function cur(slot, hand) return Worn(slot) and self:Score(spec, Worn(slot), hand) or 0 end
	if SINGLE[loc] then
		return new - cur(SINGLE[loc])
	elseif loc == "INVTYPE_FINGER" then
		return new - math.min(cur(FINGER1), cur(FINGER2))
	elseif loc == "INVTYPE_TRINKET" then
		return new - math.min(cur(TRINKET1), cur(TRINKET2))
	elseif RANGED_TYPES[loc] then
		return self:Score(spec, link, "ranged") - cur(RANGED, "ranged")
	elseif loc == "INVTYPE_2HWEAPON" then
		local ohLoc = EquipLoc(Worn(OH))
		if ohLoc == "INVTYPE_2HWEAPON" then -- Titan's Grip: a 2H can replace either hand
			return math.max(self:Score(spec, link, "mh") - cur(MH, "mh"), self:Score(spec, link, "oh") - cur(OH, "oh"))
		end
		return self:Score(spec, link, "mh") - cur(MH, "mh") - cur(OH, "oh")
	elseif loc == "INVTYPE_WEAPONMAINHAND" then
		return self:Score(spec, link, "mh") - cur(MH, "mh")
	elseif OFFHAND_TYPES[loc] then
		return self:Score(spec, link, "oh") - cur(OH, "oh")
	elseif loc == "INVTYPE_WEAPON" then
		-- shortcut: vs a worn 2H a one-hander is compared with the 2H alone (the missing off hand is ignored)
		local mhGain = self:Score(spec, link, "mh") - cur(MH, "mh")
		if EquipLoc(Worn(MH)) == "INVTYPE_2HWEAPON" or not addon.EP_WEIGHTS[spec].dps.oh or addon.EP_WEIGHTS[spec].dps.oh == 0 then
			return mhGain
		end
		return math.max(mhGain, self:Score(spec, link, "oh") - cur(OH, "oh"))
	end
	return nil
end

--- EP gain of a drop for a spec ("CLASS:Spec"), rounded, or nil (uncached item, unknown slot, no weights).
-- Tier tokens are valued as the best piece they buy for my class.
function UP:EP(spec, link)
	if not spec or not link then return nil end
	local id = addon:GetItemIDFromLink(link)
	if id and LibToken:ItemIsToken(id) then
		local best
		for _, piece in LibToken:IterateItemsForTokenAndClass(id, spec:match("^(%u+):")) do
			local plink = select(2, GetItemInfo(piece))
			local g = plink and Gain(self, spec, plink, EquipLoc(plink))
			if g and (not best or g > best) then best = g end
		end
		return best and math.floor(best + 0.5)
	end
	local g = Gain(self, spec, link, EquipLoc(link))
	return g and math.floor(g + 0.5)
end

--- The values a response carries: {epMS, epOS}; the OS values are the best over all my off specs.
function UP:ForResponse(link, ms, oss)
	local epOS
	for _, os in ipairs(oss or {}) do
		if os ~= ms then
			local ep = self:EP(os, link)
			if ep and (not epOS or ep > epOS) then epOS = ep end
		end
	end
	return {epMS = self:EP(ms, link), epOS = epOS}
end

--- Council text for a candidate under the ML's mode: text, sort value (higher = better).
function UP:Text(mode, c)
	if mode == "ilvl" then
		return c.diff or "", tonumber(c.diff) or -999
	end
	local ep = c.epMS or c.epOS
	if not ep then return "", -99999 end
	return format("%+d EP", ep) .. (c.epMS and "" or " OS"), c.epMS or (c.epOS - 100000)
end
