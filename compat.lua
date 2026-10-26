-- get num group members backport
local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")

function addon:IsInRaid() 
    return GetNumRaidMembers() > 0
end

function addon:IsInGroup()
    return (GetNumRaidMembers() == 0 and GetNumPartyMembers() > 0)
end

--- In a party OR a raid. (IsInGroup above is the party-only backport the old comm code relies on: it is false in a raid.)
function addon:InAnyGroup()
    return GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0
end

function addon:GetNumGroupMembers()
    if addon:IsInRaid() then 
        return GetNumRaidMembers()
    else
        return GetNumPartyMembers()
    end
end