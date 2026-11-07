-- Potential final equipment rewards of Wrath raid quest items, not quest eligibility.
-- Source: chromiecraft/azerothcore-wotlk e6d767b8e573a9308dd05e17cae3d8f2b00b13e6
-- Tables: item_template, quest_template, quest_template_addon. Recheck when server quest data changes.
local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")

addon.QUEST_REWARDS = {
	-- Naxxramas keys -> Eye of Eternity follow-up; requires killing Malygos (13372/13375 -> 13384/13385).
	[44569] = {44658, 44657, 44659, 44660}, -- Key to the Focusing Iris (10)
	[44577] = {44661, 44662, 44664, 44665}, -- Heroic Key to the Focusing Iris (25)
	[44650] = {44658, 44657, 44659, 44660}, -- Heart of Magic (10)
	[44651] = {44661, 44662, 44664, 44665}, -- Heart of Magic (25)
	-- All Is Well That Ends Well (13631/13819).
	[46052] = {46320, 46321, 46322, 46323}, -- Reply-Code Alpha (10)
	[46053] = {45588, 45618, 45608, 45614}, -- Reply-Code Alpha (25)
	-- A Most Puzzling Circumstance (24429/24428); both factions have the same choices.
	[49643] = {49486, 49485, 49487}, -- Head of Onyxia (Horde, level 80)
	[49644] = {49486, 49485, 49487}, -- Head of Onyxia (Alliance, level 80)
	-- Ancient History -> Val'anyr (13622 -> 13629); needs 30 fragments and the Yogg-Saron quest.
	[45038] = {46017}, -- Fragment of Val'anyr
	[45039] = {46017}, -- Shattered Fragments of Val'anyr
}
