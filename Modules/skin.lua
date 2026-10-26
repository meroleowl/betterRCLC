-- skin.lua  Look of betterRCLC's windows. Two styles (Options > General > Look, needs /reload to switch):
--   "bronze" (default): Blizzard-style panels and buttons in the warm Forever Bronze colours, works for everyone.
--   "modern": flat panels that follow the user's ElvUI profile/theme (CHSkin = ElvUI's own templates when ElvUI is
--             loaded, flat dark otherwise). Title text uses the ElvUI fork theme accent and follows theme changes.

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")

-- Forever Bronze (ElvUI fork Modules/Themes/Themes.lua "forever")
local BRONZE = {
	bg = {0.118, 0.110, 0.102, 0.96},
	title = {0.200, 0.161, 0.125, 1},
	border = {0.55, 0.42, 0.30, 1},
	accent = {0.863, 0.655, 0.498},
	button = {0.78, 0.58, 0.40},
}
addon.BRONZE = BRONZE

local TOOLTIP_EDGE = "Interface\\Tooltips\\UI-Tooltip-Border"
local FLAT = "Interface\\ChatFrame\\ChatFrameBackground"

function addon:SkinStyle()
	return self.db and self.db.profile.skin or "bronze"
end

--- Accent colour (r, g, b) of the current look.
function addon:SkinAccent()
	if self:SkinStyle() == "modern" then
		local E = _G.ElvUI and _G.ElvUI[1]
		if E and E.Themes and E.Themes.Accent then return E.Themes:Accent() end
		if CHSkin then local a = CHSkin.Colors() return a[1], a[2], a[3] end
	end
	return unpack(BRONZE.accent)
end

local titles = {} -- title font strings, recoloured when the ElvUI theme changes
local function ColorTitles()
	local r, g, b = addon:SkinAccent()
	for _, fs in ipairs(titles) do fs:SetTextColor(r, g, b) end
end

local function BronzePanel(f, color)
	f:SetBackdrop({bgFile = FLAT, edgeFile = TOOLTIP_EDGE, tile = true, tileSize = 64, edgeSize = 14,
		insets = {left = 3, right = 3, top = 3, bottom = 3}})
	f:SetBackdropColor(unpack(color or BRONZE.bg))
	f:SetBackdropBorderColor(unpack(BRONZE.border))
end

--- Window made by addon:CreateFrame (f.title = title bar, f.content = body).
function addon:SkinWindow(f)
	if self:SkinStyle() == "modern" and CHSkin then
		CHSkin.Panel(f.content, "transparent")
		CHSkin.Panel(f.title, "solid")
		CHSkin.Font(f.title.text, 12, "OUTLINE")
		local E = _G.ElvUI and _G.ElvUI[1]
		if E and E.Themes and E.Themes.OnChange and not self.themeHooked then
			self.themeHooked = true
			E.Themes:OnChange(ColorTitles)
		end
	else
		BronzePanel(f.content)
		BronzePanel(f.title, BRONZE.title)
	end
	titles[#titles + 1] = f.title.text
	ColorTitles()
end

--- Plain panel (loot frame entries and other boxes). keepBg = the caller colours the background itself.
function addon:SkinPanel(f, keepBg)
	if self:SkinStyle() == "modern" and CHSkin then
		CHSkin.Panel(f, "transparent")
	else
		local r, g, b, a = f:GetBackdropColor()
		BronzePanel(f)
		if keepBg and r then f:SetBackdropColor(r, g, b, a) end
	end
end

--- UIPanelButtonTemplate button: bronze = Blizzard button art desaturated and tinted, modern = CHSkin flat/ElvUI.
function addon:SkinButton(b)
	if self:SkinStyle() == "modern" and CHSkin then return CHSkin.Button(b) end
	for _, tex in ipairs({b:GetRegions()}) do
		if tex.GetObjectType and tex:GetObjectType() == "Texture" and tex ~= b:GetHighlightTexture() then
			tex:SetDesaturated(true)
			tex:SetVertexColor(unpack(BRONZE.button))
		end
	end
	for _, get in ipairs({"GetNormalTexture", "GetPushedTexture", "GetDisabledTexture"}) do
		local tex = b[get] and b[get](b)
		if tex then
			tex:SetDesaturated(true)
			tex:SetVertexColor(unpack(BRONZE.button))
		end
	end
	return b
end
