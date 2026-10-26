-- kit.lua  The widget kit every betterRCLC window is built from (redesign step 1). No Blizzard templates, no
-- lib-st / dropdown libs: flat panels with 1 px borders, own buttons, menus and lists, so the windows look the same
-- with or without ElvUI. Colours follow the ElvUI fork theme (E.Themes:Active()) and change live with it;
-- without the fork every window is Forever Bronze.

local addon = LibStub("AceAddon-3.0"):GetAddon("betterRCLC")

local UI = {}
addon.UI = UI

local FLAT = "Interface\\Buttons\\WHITE8X8"
UI.FLAT = FLAT

-- Forever Bronze (fork Themes.lua "forever")
local BRONZE = {
	backdrop = {r = 0.118, g = 0.110, b = 0.102}, border = {r = 0.290, g = 0.231, b = 0.173},
	accent = {r = 0.863, g = 0.655, b = 0.498}, line = {r = 0.400, g = 0.620, b = 0.860}, lineAlpha = 0.30,
}

local function rgb(c, add)
	add = add or 0
	return {math.min(c.r + add, 1), math.min(c.g + add, 1), math.min(c.b + add, 1)}
end

local function Elv()
	return _G.ElvUI and _G.ElvUI[1]
end

--- Current colours: bg, bg2 (header/raised), row, border, accent, line (+ .lineA), ink/ink2/ink3 (text), ok/warn/bad.
function UI:Palette()
	local E = Elv()
	-- the picked theme; "follow" (default) = the ElvUI fork's theme when it is installed, else Forever Bronze
	local pick = addon.db and addon.db.profile.theme
	local t = pick and pick ~= "follow" and addon.THEMES and addon.THEMES[pick]
		or E and E.Themes and E.Themes.Active and E.Themes:Active() or BRONZE
	local line = t.line or t.accent
	local b = t.backdrop
	return {
		bg = rgb(t.backdrop), bg2 = rgb(t.backdrop, 0.035), row = rgb(t.backdrop, 0.06), rowHover = rgb(t.backdrop, 0.10),
		-- EllesmereUI depth: buttons in the theme's second surface colour (Forever's navy...), inputs darker than the panel
		raised = t.control and rgb(t.control) or rgb(t.backdrop, 0.11),
		raisedHover = t.control and rgb(t.control, 0.05) or rgb(t.backdrop, 0.16), edge = rgb(t.border, 0.10),
		inset = {b.r * 0.5, b.g * 0.5, b.b * 0.5},
		tex = t.textureTint and {t.textureTint[1], t.textureTint[2], t.textureTint[3], t.textureAlpha or 0.3}, -- window texture
		glow = t.line or t.accent, glowA = t.glowAlpha or 0.28,
		border = rgb(t.border), accent = rgb(t.accent), line = rgb(line), lineA = t.lineAlpha or 0.3,
		ink = {0.925, 0.906, 0.875}, ink2 = {0.659, 0.631, 0.592}, ink3 = {0.435, 0.416, 0.384},
		ok = {0.341, 0.761, 0.478}, warn = {0.886, 0.722, 0.302}, bad = {0.851, 0.325, 0.310},
	}
end

------------------------------------------------------------------------
-- live theme: every widget registers a paint function, re-run on theme change
------------------------------------------------------------------------
local painters = {}
function UI:Paint(fn)
	painters[#painters + 1] = fn
	fn(self:Palette())
	if not self.hooked then
		local E = Elv()
		if E and E.Themes and E.Themes.OnChange then
			self.hooked = true
			E.Themes:OnChange(function() UI:Repaint() end)
		end
	end
	return fn
end

function UI:Repaint()
	local p = self:Palette()
	for _, fn in ipairs(painters) do fn(p) end
end

function UI:Font()
	local E = Elv()
	return E and E.media and E.media.normFont or STANDARD_TEXT_FONT
end

------------------------------------------------------------------------
-- primitives
------------------------------------------------------------------------
--- One physical pixel in UIParent units (ElvUI's E.mult when loaded). An edge of 1 UI unit is 0.6-0.9 physical px
-- on most screens and vanishes on some sub-pixel offsets, which is why borders used to disappear on one side.
-- frame = measure in that frame's units (windows can be scaled by the size setting); nil = UIParent's.
function UI:Mult(frame)
	local E = Elv()
	local ui = UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
	local own = frame and frame.GetEffectiveScale and frame:GetEffectiveScale() or ui
	if not own or own == 0 then own = ui end
	local m
	if E and E.mult then
		m = E.mult
	else
		local res = GetCVar and GetCVar("gxResolution")
		local h = res and tonumber(res:match("%d+x(%d+)"))
		if not h or not ui or ui == 0 then return 1 end
		m = 768 / h / ui
	end
	return m * ui / own
end

UI.bordered = setmetatable({}, {__mode = "k"}) -- frames with a kit border: redone when the size setting changes
local backdrops = {}
function UI:Backdrop(frame)
	local m = self:Mult(frame)
	local key = math.floor(m * 10000 + 0.5)
	if not backdrops[key] then
		backdrops[key] = {bgFile = FLAT, edgeFile = FLAT, edgeSize = m, insets = {left = 0, right = 0, top = 0, bottom = 0}}
	end
	if frame then self.bordered[frame] = true end
	return backdrops[key]
end

--- Size setting: windows and roll cards get their scale; every kit border is rebuilt for the new pixel size.
function UI:WindowScale() return addon.db and addon.db.profile.uiScale or 1 end
function UI:CardScale() return addon.db and addon.db.profile.cardScale or 1 end
UI.windows = {}
function UI:ApplyScale()
	for _, w in ipairs(self.windows) do w:SetScale(self:WindowScale()) end
	if self.cards then self.cards:SetScale(self:CardScale()) end
	for f in pairs(self.bordered) do f:SetBackdrop(self:Backdrop(f)) end
	self:Repaint() -- SetBackdrop resets colours; every widget paints itself again
end

--- Resize grip in a window's bottom-right corner. minW / minH = the smallest size at which nothing clips (the size
-- setting still scales everything); the size is saved per window (db.profile.ui[key .. "Size"]) and snapped to
-- whole screen pixels, the position is saved the way a header drag saves it.
function UI:Resizable(f, key, minW, minH)
	f:SetResizable(true)
	f:SetMinResize(minW, minH)
	local ui = addon.db and addon.db.profile.ui
	local size = ui and ui[key .. "Size"]
	local function snap(v) local m = UI:Mult(f) return math.floor((v or 0) / m + 0.5) * m end
	if size then f:SetSize(snap(math.max(minW, size[1])), snap(math.max(minH, size[2]))) end
	local g = CreateFrame("Button", nil, f)
	g:SetSize(14, 14)
	g:SetPoint("BOTTOMRIGHT", -2, 2)
	g:SetFrameLevel(f:GetFrameLevel() + 30) -- once, at creation: above the pages' footers
	g:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	g:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	g:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	g:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
	g:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		local w, h = snap(f:GetWidth()), snap(f:GetHeight())
		local point, _, _, x, y = f:GetPoint()
		x, y = snap(x), snap(y)
		f:SetSize(w, h)
		f:ClearAllPoints()
		f:SetPoint(point, UIParent, point, x, y)
		if addon.db then
			addon.db.profile.ui = addon.db.profile.ui or {}
			addon.db.profile.ui[key] = {point, x, y}
			addon.db.profile.ui[key .. "Size"] = {w, h}
		end
	end)
	f.grip = g
	return g
end

--- Horizontal slider (track + thumb + value label). onChange(value) on release, so a window being resized by it
-- does not move under the mouse while dragging. fmt(value) -> label text.
function UI:Slider(parent, w, min, max, step, fmt, onChange)
	local s = CreateFrame("Slider", nil, parent)
	s:SetOrientation("HORIZONTAL")
	s:SetSize(w, 12)
	s:SetMinMaxValues(min, max)
	s:SetValueStep(step)
	s:EnableMouse(true)
	self:Panel(s, "inset", "border", 1)
	s:SetThumbTexture(FLAT)
	local thumb = s:GetThumbTexture()
	if thumb then
		thumb:SetSize(8, 14)
		self:Paint(function(p) thumb:SetVertexColor(p.accent[1], p.accent[2], p.accent[3], 1) end)
	end
	s.label = self:Text(s, 11, "ink2")
	s.label:SetPoint("LEFT", s, "RIGHT", 8, 0)
	local function snap(v) return math.floor(v / step + 0.5) * step end
	s:SetScript("OnValueChanged", function(self, v) self.label:SetText(fmt(snap(v))) end)
	s:SetScript("OnMouseUp", function(self) if onChange then onChange(snap(self:GetValue())) end end)
	function s:SetTo(v) self:SetValue(v) self.label:SetText(fmt(snap(v))) end
	return s
end

--- Flat panel: bgKey/borderKey are palette keys (borderKey false = no border); alpha for the background.
function UI:Panel(f, bgKey, borderKey, alpha)
	f:SetBackdrop(UI:Backdrop(f))
	self:Paint(function(p)
		local c = p[bgKey or "bg"]
		f:SetBackdropColor(c[1], c[2], c[3], alpha or 0.96)
		if borderKey == false then
			f:SetBackdropBorderColor(0, 0, 0, 0)
		else
			local b = p[borderKey or "border"]
			f:SetBackdropBorderColor(b[1], b[2], b[3], 1)
		end
	end)
	return f
end

--- Font string in the kit's font. color = palette key ("ink", "accent"...) or {r, g, b}.
function UI:Text(parent, size, color, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFont(self:Font(), size or 12, "")
	fs:SetShadowOffset(1, -1)
	fs:SetShadowColor(0, 0, 0, 0.8)
	fs:SetJustifyH(justify or "LEFT")
	fs:SetWordWrap(false)
	self:Recolor(fs, color or "ink")
	return fs
end

--- Text colour by palette key that follows the theme (or a fixed {r,g,b}).
function UI:Recolor(fs, color)
	fs.kitColor = color
	if not fs.kitPainted then
		fs.kitPainted = true
		self:Paint(function(p)
			local c = type(fs.kitColor) == "table" and fs.kitColor or p[fs.kitColor] or p.ink
			fs:SetTextColor(c[1], c[2], c[3])
		end)
	else
		local p = self:Palette()
		local c = type(color) == "table" and color or p[color] or p.ink
		fs:SetTextColor(c[1], c[2], c[3])
	end
end

------------------------------------------------------------------------
-- buttons
------------------------------------------------------------------------
-- kind: "default" (raised, bordered), "primary" (accent fill), "quiet" (text only until hovered)
local function PaintButton(b, p)
	p = p or UI:Palette()
	local over, on, kind = b.kitOver and b:IsEnabled(), b.kitActive, b.kitKind
	local bg, border, ink
	if kind == "primary" then
		bg, border, ink = p.accent, p.accent, {0.08, 0.07, 0.06}
		if over then bg = {math.min(p.accent[1] + 0.08, 1), math.min(p.accent[2] + 0.08, 1), math.min(p.accent[3] + 0.08, 1)} end
	elseif on then
		bg, border, ink = p.raisedHover, p.accent, p.accent
		if over then -- a selected / outlined button still answers the mouse: an accent tint
			local a, h = p.accent, p.raisedHover
			bg = {h[1] + (a[1] - h[1]) * 0.22, h[2] + (a[2] - h[2]) * 0.22, h[3] + (a[3] - h[3]) * 0.22}
		end
	elseif kind == "danger" then -- red outline: End session and other "are you sure" actions
		bg, border, ink = over and p.raisedHover or p.raised, p.bad, p.bad
	else
		bg, border, ink = over and p.raisedHover or p.raised, p.edge, over and p.ink or p.ink2
		if kind == "quiet" and not over then bg, border = {0, 0, 0}, nil end
		if kind == "quiet" and over then bg = p.rowHover end
	end
	b:SetBackdropColor(bg[1], bg[2], bg[3], (kind == "quiet" and not over and not on) and 0 or 1)
	if border then b:SetBackdropBorderColor(border[1], border[2], border[3], 1) else b:SetBackdropBorderColor(0, 0, 0, 0) end
	if not b:IsEnabled() then ink = p.ink3 end
	if b.kitColor then ink = b.kitColor end
	b.text:SetTextColor(ink[1], ink[2], ink[3])
end

function UI:Button(parent, text, w, h, kind, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetBackdrop(UI:Backdrop(b))
	b.kitKind = kind or "default"
	b.text = self:Text(b, 12, "ink", "CENTER")
	b.text:SetPoint("CENTER", 0, 0)
	if b.kitKind == "primary" then b.text:SetShadowOffset(0, 0) end -- dark text on the accent: a shadow smears it
	b:SetHeight(h or 22)
	b.kitW = w
	function b:SetLabel(t)
		self.text:SetText(t or "")
		if not self.kitW then self:SetWidth(math.max(self.text:GetStringWidth() + 20 + (self.icon and (h or 22) - 4 or 0), 40)) end
	end
	--- Highlighted state (segmented switches, the answer that matches a raider's list).
	function b:SetActive(on) self.kitActive = on and true or nil PaintButton(self) end
	--- Small icon left of the label (e.g. Disenchant).
	function b:SetIcon(path)
		if not self.icon then
			self.icon = self:CreateTexture(nil, "ARTWORK")
			self.icon:SetSize((h or 22) - 8, (h or 22) - 8)
			self.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		end
		self.icon:SetTexture(path)
		self.icon:ClearAllPoints()
		self.icon:SetPoint("LEFT", 5, 0)
		self.text:ClearAllPoints()
		self.text:SetPoint("LEFT", self.icon, "RIGHT", 5, 0)
		if not self.kitW then self:SetWidth(self.text:GetStringWidth() + (h or 22) + 12) end
	end
	--- Fixed text colour (e.g. a red "Pass"); nil = from the theme.
	function b:SetTextTint(c) self.kitColor = c PaintButton(self) end
	b:SetLabel(text)
	if w then b:SetWidth(w) end
	b:SetScript("OnEnter", function(self) self.kitOver = true PaintButton(self) if self.tip then UI:Tip(self, unpack(self.tip)) end end)
	b:SetScript("OnLeave", function(self) self.kitOver = nil PaintButton(self) GameTooltip:Hide() end)
	b:SetScript("OnEnable", function(self) PaintButton(self) end)
	b:SetScript("OnDisable", function(self) PaintButton(self) end)
	if onClick then b:SetScript("OnClick", onClick) end
	self:Paint(function(p) PaintButton(b, p) end)
	return b
end

--- "a · b · c" from the parts that are not nil or empty (table.concat errors on a nil hole).
function UI.Join(sep, ...)
	local t = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if v ~= nil and v ~= "" then t[#t + 1] = tostring(v) end
	end
	return table.concat(t, sep)
end

--- Segmented switch: options = {{key, text}, ...}; onSelect(key) on click. :Select(key) without the callback.
-- bw = fixed width per button (nil = from the text).
function UI:Segmented(parent, options, onSelect, h, bw)
	local f = CreateFrame("Frame", nil, parent)
	f.buttons = {}
	local x = 0
	for i, o in ipairs(options) do
		local b = self:Button(f, o[2], bw, h or 22, "default")
		b:SetPoint("LEFT", f, "LEFT", x, 0)
		x = x + b:GetWidth() + 2 -- a gap, not a shared edge: neighbours covered the highlighted border
		b.key = o[1]
		b:SetScript("OnClick", function() f:Select(o[1]) if onSelect then onSelect(o[1]) end end)
		f.buttons[i] = b
	end
	f:SetSize(x - 2, h or 22)
	function f:Select(key)
		self.value = key
		for _, b in ipairs(self.buttons) do b:SetActive(b.key == key) end
	end
	--- Re-space the buttons after their labels changed (auto-width buttons).
	function f:Relayout()
		local px = 0
		for _, b in ipairs(self.buttons) do
			b:ClearAllPoints()
			b:SetPoint("LEFT", self, "LEFT", px, 0)
			px = px + b:GetWidth() + 2
		end
		self:SetWidth(px - 2)
	end
	return f
end

--- Toggle: small square + label. onChange(checked).
function UI:Check(parent, label, onChange)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(16, 16)
	b.box = CreateFrame("Frame", nil, b)
	b.box:SetSize(14, 14)
	b.box:SetPoint("LEFT")
	self:Panel(b.box, "inset", "border", 1)
	b.mark = b.box:CreateTexture(nil, "OVERLAY")
	b.mark:SetTexture(FLAT)
	b.mark:SetPoint("TOPLEFT", 3, -3)
	b.mark:SetPoint("BOTTOMRIGHT", -3, 3)
	b.label = self:Text(b, 12, "ink")
	b.label:SetPoint("LEFT", b.box, "RIGHT", 6, 0)
	b.label:SetText(label or "")
	b:SetWidth(20 + b.label:GetStringWidth())
	function b:SetChecked(on) self.checked = on and true or false if on then self.mark:Show() else self.mark:Hide() end end
	function b:GetChecked() return self.checked end
	b:SetScript("OnClick", function(self) self:SetChecked(not self.checked) if onChange then onChange(self.checked) end end)
	self:Paint(function(p) b.mark:SetVertexColor(p.accent[1], p.accent[2], p.accent[3]) end)
	b:SetChecked(false)
	return b
end

------------------------------------------------------------------------
-- item icon with quality border, chip, bar
------------------------------------------------------------------------
function UI:Icon(parent, size)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(size or 32, size or 32)
	b:SetBackdrop(UI:Backdrop(b))
	b:SetBackdropColor(0, 0, 0, 1)
	self:Paint(function()
		b:SetBackdropColor(0, 0, 0, 1)
		local c = b.qcolor or {0.3, 0.3, 0.3}
		b:SetBackdropBorderColor(c[1], c[2], c[3], 1)
	end)
	b:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
	if Elv() then -- EllesmereUI's empty-slot emblem (the fork's media) under the item icon
		b.slot = b:CreateTexture(nil, "BACKGROUND", nil, 1)
		b.slot:SetTexture("Interface\\AddOns\\ElvUI\\Media\\Ellesmere\\modules\\bags\\icon-bg")
		b.slot:SetPoint("TOPLEFT", 1, -1)
		b.slot:SetPoint("BOTTOMRIGHT", -1, 1)
		b.slot:SetAlpha(0.6)
	end
	b.tex = b:CreateTexture(nil, "ARTWORK")
	b.tex:SetPoint("TOPLEFT", 1, -1)
	b.tex:SetPoint("BOTTOMRIGHT", -1, 1)
	b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	--- Item link or id; nil clears. Uncached items get the question mark until GetItemInfo knows them.
	function b:SetItem(item)
		self.item = item
		if not item then self.tex:SetTexture(nil) self.qcolor = nil self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1) return end
		local _, link, quality, _, _, _, _, _, _, texture = GetItemInfo(item)
		self.link = link or (type(item) == "string" and item) or nil
		self.tex:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
		local r, g, bl = 0.3, 0.3, 0.3
		if quality and GetItemQualityColor then r, g, bl = GetItemQualityColor(quality) end
		self.qcolor = {r, g, bl}
		self:SetBackdropBorderColor(r, g, bl, 1)
	end
	b:SetScript("OnEnter", function(self)
		if not self.link then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink(self.link)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b:SetScript("OnClick", function(self) if self.link and IsModifiedClick() then HandleModifiedItemClick(self.link) end end)
	return b
end

--- Chip: short coloured label. :Set(text, kind) with kind "ok" | "warn" | "bad" | "accent" | "muted"; nil text hides it.
function UI:Chip(parent, size)
	local f = CreateFrame("Frame", nil, parent)
	f:SetBackdrop(UI:Backdrop(f))
	f.text = self:Text(f, size or 11, "ink", "CENTER")
	f.text:SetPoint("CENTER", 0, 0)
	f:SetHeight((size or 11) + 7)
	function f:Set(text, kind)
		if not text or text == "" then self:Hide() return end
		self.kind = kind or "muted"
		self.text:SetText(text)
		self:SetWidth(self.text:GetStringWidth() + 12)
		UI:PaintChip(self)
		self:Show()
	end
	self:Paint(function() if f.kind then UI:PaintChip(f) end end)
	f:Hide()
	return f
end

function UI:PaintChip(f)
	local p = self:Palette()
	local c = f.kind == "muted" and p.ink2 or p[f.kind] or p.ink2
	f:SetBackdropColor(c[1], c[2], c[3], 0.16)
	f:SetBackdropBorderColor(c[1], c[2], c[3], 0.55)
	f.text:SetTextColor(c[1], c[2], c[3])
end

--- Thin status bar (timers). :SetProgress(0..1, warn) turns amber when warn.
function UI:Bar(parent, h)
	local s = CreateFrame("StatusBar", nil, parent)
	s:SetHeight(h or 3)
	s:SetStatusBarTexture(FLAT)
	s:SetMinMaxValues(0, 1)
	s.bg = s:CreateTexture(nil, "BACKGROUND")
	s.bg:SetTexture(FLAT)
	s.bg:SetAllPoints()
	function s:SetProgress(v, warn)
		self:SetValue(v)
		local p = UI:Palette()
		local c = warn and p.warn or p.accent
		self:SetStatusBarColor(c[1], c[2], c[3], 1)
	end
	self:Paint(function(p) s.bg:SetVertexColor(p.row[1], p.row[2], p.row[3], 1) s:SetStatusBarColor(p.accent[1], p.accent[2], p.accent[3], 1) end)
	return s
end

------------------------------------------------------------------------
-- text field (single or multi line) with placeholder
------------------------------------------------------------------------
function UI:Edit(parent, w, h, multiline, placeholder)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(w or 160, h or 22)
	self:Panel(f, "inset", "border", 1)
	local e = CreateFrame("EditBox", nil, multiline and nil or f)
	e:SetFont(self:Font(), 12, "")
	e:SetAutoFocus(false)
	e:SetMultiLine(multiline and true or false)
	if multiline then
		local sf = CreateFrame("ScrollFrame", nil, f)
		sf:SetPoint("TOPLEFT", 6, -5)
		sf:SetPoint("BOTTOMRIGHT", -6, 5)
		e:SetParent(sf)
		e:SetWidth((w or 160) - 12)
		sf:SetScrollChild(e)
		sf:EnableMouseWheel(true)
		sf:SetScript("OnMouseWheel", function(self, d)
			local max = self:GetVerticalScrollRange() or 0
			self:SetVerticalScroll(math.max(0, math.min(max, (self:GetVerticalScroll() or 0) - d * 24)))
		end)
		f:EnableMouse(true)
		f:SetScript("OnMouseDown", function() e:SetFocus() end)
		f.scroll = sf
	else
		e:SetPoint("TOPLEFT", 6, 0)
		e:SetPoint("BOTTOMRIGHT", -6, 0)
	end
	e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	f.edit = e
	f.hint = self:Text(f, 12, "ink3")
	f.hint:SetPoint("TOPLEFT", 7, multiline and -6 or -5)
	f.hint:SetText(placeholder or "")
	local function hint() if (e:GetText() or "") == "" and not e.kitFocus then f.hint:Show() else f.hint:Hide() end end
	e:SetScript("OnEditFocusGained", function() e.kitFocus = true hint() end)
	e:SetScript("OnEditFocusLost", function() e.kitFocus = nil hint() end)
	e:SetScript("OnTextChanged", function(self, user) hint() if f.onChange then f.onChange(self:GetText(), user) end end)
	function f:GetText() return e:GetText() end
	function f:SetText(t) e:SetText(t or "") hint() end
	self:Paint(function(p) e:SetTextColor(p.ink[1], p.ink[2], p.ink[3]) end)
	return f
end

------------------------------------------------------------------------
-- list: pooled rows over a data array, mouse wheel scrolling, thin scroll thumb
------------------------------------------------------------------------
-- make(list) -> row frame; fill(row, item, index). Rows are rowH high; items can carry their own .height.
function UI:List(parent, rowH, make, fill)
	local f = CreateFrame("Frame", nil, parent)
	f.rows, f.data, f.offset, f.rowH = {}, {}, 0, rowH
	f:EnableMouseWheel(true)
	f.thumb = f:CreateTexture(nil, "OVERLAY")
	f.thumb:SetTexture(FLAT)
	f.thumb:SetWidth(3)
	self:Paint(function(p) f.thumb:SetVertexColor(p.accent[1], p.accent[2], p.accent[3], 0.6) end)
	function f:Visible() return math.max(1, math.floor((self:GetHeight() or rowH) / rowH)) end
	function f:SetData(data) self.data = data or {} self.offset = math.min(self.offset, math.max(0, #self.data - self:Visible())) self:Refresh() end
	function f:Refresh()
		local n = self:Visible()
		for i = 1, n do
			local item = self.data[i + self.offset]
			local row = self.rows[i]
			if item and not row then
				row = make(self)
				row:SetParent(self)
				row:SetHeight(rowH)
				row:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -(i - 1) * rowH)
				row:SetPoint("RIGHT", self, "RIGHT", -6, 0)
				self.rows[i] = row
			end
			if row then
				if item then fill(row, item, i + self.offset) row:Show() else row:Hide() end
			end
		end
		for i = n + 1, #self.rows do self.rows[i]:Hide() end
		local total = #self.data
		if total > n then
			local h = self:GetHeight() or (n * rowH)
			self.thumb:SetHeight(math.max(12, h * n / total))
			self.thumb:ClearAllPoints()
			self.thumb:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -(h - self.thumb:GetHeight()) * self.offset / (total - n))
			self.thumb:Show()
		else
			self.thumb:Hide()
		end
	end
	f:SetScript("OnMouseWheel", function(self, d)
		self.offset = math.max(0, math.min(#self.data - self:Visible(), self.offset - d))
		self:Refresh()
	end)
	f:SetScript("OnSizeChanged", function(self) self:Refresh() end)
	return f
end

------------------------------------------------------------------------
-- menu: one shared popup, closes on a click outside or Escape. items = {{text, func, checked, disabled, title}, ...};
-- {sep = true} = a thin line between sections
------------------------------------------------------------------------
-- An item with .sub = {items} opens a submenu to the side on hover (MRT-style); a click anywhere outside closes all.
-- point = how the menu sits on the anchor: nil = below it, "cursor" = at the mouse (minimap right-click).
function UI:Menu(anchor, items, point)
	self.menus = self.menus or {}
	local catcher = self.menuCatcher
	if not catcher then
		catcher = CreateFrame("Button", nil, UIParent)
		catcher:SetAllPoints(UIParent)
		catcher:SetFrameStrata("FULLSCREEN")
		catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		catcher:SetScript("OnClick", function() UI:CloseMenus() end)
		self.menuCatcher = catcher
	end
	self:CloseMenus()
	local m = self:MenuLevel(1, items)
	m.left = point == "cursor" or nil -- the cursor menu hangs to the left of the mouse (minimap at the right edge)
	m:ClearAllPoints()
	if point == "cursor" then
		local x, y = GetCursorPosition()
		local s = UIParent:GetEffectiveScale()
		m:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", x / s, y / s)
	else
		m:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
	end
	catcher:Show()
	self.menu = m
	return m
end

function UI:CloseMenus(from)
	for i = from or 1, #(self.menus or {}) do self.menus[i]:Hide() end
	if (from or 1) == 1 and self.menuCatcher then self.menuCatcher:Hide() end
end

function UI:MenuLevel(level, items)
	local m = self.menus[level]
	if not m then
		m = CreateFrame("Frame", "BRCKitMenu" .. level, UIParent)
		m:SetFrameStrata("FULLSCREEN_DIALOG")
		m:SetFrameLevel(level * 20) -- once, at creation: deeper levels always draw above the ones they came from
		m:SetClampedToScreen(true)
		m:EnableMouse(true)
		self:Panel(m, "bg2", "border", 0.98)
		m.buttons = {}
		if level == 1 then
			m:SetScript("OnHide", function() UI:CloseMenus(2) if UI.menuCatcher then UI.menuCatcher:Hide() end end)
			tinsert(UISpecialFrames, "BRCKitMenu1")
		end
		self.menus[level] = m
	end
	local width, y = 120, 1
	for i, it in ipairs(items) do
		local b = m.buttons[i]
		if not b then
			b = self:Button(m, "", nil, 20, "quiet")
			b.text:ClearAllPoints()
			b.text:SetPoint("LEFT", 18, 0)
			b.check = self:Text(b, 12, "accent")
			b.check:SetPoint("LEFT", 5, 0)
			b.arrow = self:Text(b, 12, "ink3")
			b.arrow:SetPoint("RIGHT", -6, 0)
			b.line = b:CreateTexture(nil, "ARTWORK")
			b.line:SetTexture(FLAT)
			b.line:SetHeight(1)
			b.line:SetPoint("LEFT", 6, 0)
			b.line:SetPoint("RIGHT", -6, 0)
			b:HookScript("OnEnter", function(self)
				UI:CloseMenus(level + 1)
				if self.sub then
					local s = UI:MenuLevel(level + 1, self.sub)
					s:ClearAllPoints()
					-- keep going the way the parent menu went (a menu opened leftwards from the minimap keeps
					-- opening leftwards); otherwise flip only when there is no room on the right
					local right = self:GetRight()
					local goLeft = UI.menus[level].left
					if not goLeft then goLeft = right and UIParent:GetRight() and right + s:GetWidth() > UIParent:GetRight() end
					s.left = goLeft and true or nil
					if goLeft then
						s:SetPoint("TOPRIGHT", self, "TOPLEFT", -2, 1)
					else
						s:SetPoint("TOPLEFT", self, "TOPRIGHT", 2, 1)
					end
					s:Show()
				end
			end)
			m.buttons[i] = b
		end
		b.sub = it.sub
		local h = it.sep and 7 or 20
		b:SetHeight(h)
		if it.sep then
			local c = self:Palette().border
			b.line:SetVertexColor(c[1], c[2], c[3], 1)
			b.line:Show()
		else
			b.line:Hide()
		end
		b.text:SetText(it.text or it[1] or "")
		b.check:SetText(it.checked and "+" or "")
		b.arrow:SetText(it.sub and ">" or "")
		b:SetTextTint(it.title and self:Palette().accent or nil)
		if it.disabled or it.title or it.sep then b:Disable() else b:Enable() end
		b:SetScript("OnClick", function()
			if it.sub or it.sep then return end
			UI:CloseMenus()
			local fn = it.func or it[2]
			if fn then fn() end
		end)
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", m, "TOPLEFT", 1, -y)
		y = y + h
		width = math.max(width, b.text:GetStringWidth() + 40)
		b:Show()
	end
	for i = #items + 1, #m.buttons do m.buttons[i]:Hide() end
	for i = 1, #items do m.buttons[i]:SetWidth(width) end
	m:SetSize(width + 2, y + 1)
	m:Show()
	return m
end

------------------------------------------------------------------------
-- tooltip helper and window
------------------------------------------------------------------------
function UI:Tip(owner, title, ...)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:AddLine(title, 1, 1, 1)
	for i = 1, select("#", ...) do GameTooltip:AddLine((select(i, ...)), nil, nil, nil, true) end
	GameTooltip:Show()
end

--- Window decoration as the ElvUI fork draws it (needs the fork's media, else nothing): the theme's smoke texture
-- cropped 1:1 and tinted, plus additive glows in the theme's second colour from the two bottom corners.
local FORK = "Interface\\AddOns\\ElvUI\\Media\\"
function UI:Decorate(f)
	if not (Elv() and Elv().Themes) then return end
	local tex = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	tex:SetTexture(FORK .. "Ellesmere\\panel-smoke")
	tex:SetPoint("TOPLEFT", 1, -1)
	tex:SetPoint("BOTTOMRIGHT", -1, 1)
	local glows = {f:CreateTexture(nil, "BORDER"), f:CreateTexture(nil, "BORDER")}
	for i, g in ipairs(glows) do
		g:SetTexture(FORK .. "Themes\\corner_glow")
		g:SetBlendMode("ADD")
		g:SetPoint(i == 1 and "BOTTOMLEFT" or "BOTTOMRIGHT", i == 1 and 1 or -1, 1)
		if i == 2 then g:SetTexCoord(1, 0, 0, 1) end
	end
	local function fit()
		local w, h = f:GetWidth() or 0, f:GetHeight() or 0
		tex:SetTexCoord(0, math.min(1, w / 1024), 0, math.min(1, h / 1024))
		local s = math.min(150, h * 0.5)
		for _, g in ipairs(glows) do g:SetSize(s, s) end
	end
	f:HookScript("OnSizeChanged", fit)
	fit()
	self:Paint(function(p)
		if p.tex then tex:SetVertexColor(p.tex[1], p.tex[2], p.tex[3], p.tex[4]) tex:Show() else tex:Hide() end
		for _, g in ipairs(glows) do g:SetVertexColor(p.glow.r, p.glow.g, p.glow.b, p.glowA) end
	end)
end

--- Movable window with a header (title, subtitle, close). Position kept in db.profile.ui[key]. f.body = content area.
function UI:Window(key, title, w, h, strata)
	local name = "BRCWindow_" .. key
	local f = CreateFrame("Frame", name, UIParent)
	f:SetScale(self:WindowScale()) -- before the children exist: their borders are sized for it
	tinsert(self.windows, f)
	f:SetSize(w, h)
	f:SetFrameStrata(strata or "HIGH") -- before the children exist, so they are created in it
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetToplevel(true)
	self:Panel(f, "bg", "border", 0.97)
	self:Decorate(f)
	local saved = addon.db and addon.db.profile.ui and addon.db.profile.ui[key]
	local function snap(v) local m = UI:Mult(f) return math.floor((v or 0) / m + 0.5) * m end -- whole screen pixels
	f:SetSize(snap(w), snap(h))
	if saved then f:SetPoint(saved[1], UIParent, saved[1], snap(saved[2]), snap(saved[3])) else f:SetPoint("CENTER") end

	local head = CreateFrame("Frame", nil, f)
	head:SetPoint("TOPLEFT", 1, -1)
	head:SetPoint("TOPRIGHT", -1, -1)
	head:SetHeight(28)
	self:Panel(head, "bg2", false, 1)
	head:EnableMouse(true)
	head:RegisterForDrag("LeftButton")
	head:SetScript("OnDragStart", function() f:StartMoving() end)
	head:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
		local point, _, _, x, y = f:GetPoint()
		x, y = snap(x), snap(y)
		f:ClearAllPoints()
		f:SetPoint(point, UIParent, point, x, y)
		if addon.db then
			addon.db.profile.ui = addon.db.profile.ui or {}
			addon.db.profile.ui[key] = {point, x, y}
		end
	end)
	head.line = head:CreateTexture(nil, "OVERLAY")
	head.line:SetTexture(FLAT)
	head.line:SetHeight(1)
	head.line:SetPoint("BOTTOMLEFT")
	head.line:SetPoint("BOTTOMRIGHT")
	self:Paint(function(p) head.line:SetVertexColor(p.line[1], p.line[2], p.line[3], p.lineA) end)
	head.title = self:Text(head, 14, "accent")
	head.title:SetPoint("LEFT", 10, 0)
	head.sub = self:Text(head, 12, "ink3")
	head.sub:SetPoint("LEFT", head.title, "RIGHT", 8, 0)
	head.close = self:Button(head, "×", 22, 20, "quiet", function() f:Hide() end)
	head.close:SetPoint("RIGHT", -4, 0)
	f.head = head

	f.body = CreateFrame("Frame", nil, f)
	f.body:SetPoint("TOPLEFT", 1, -29)
	f.body:SetPoint("BOTTOMRIGHT", -1, 1)
	function f:SetTitle(t, sub) self.head.title:SetText(t or "") self.head.sub:SetText(sub or "") end
	f:SetTitle(title)
	tinsert(UISpecialFrames, name)
	f:Hide()
	return f
end

------------------------------------------------------------------------
-- spec icons (Details' atlas, the same art the fork's damage meter uses)
------------------------------------------------------------------------
local SPEC_ATLAS = "Interface\\AddOns\\betterRCLC\\Media\\spec_icons"
local SPEC_ID = {
	["WARRIOR:Arms"] = 71, ["WARRIOR:Fury"] = 72, ["WARRIOR:Protection"] = 73,
	["PALADIN:Holy"] = 65, ["PALADIN:Protection"] = 66, ["PALADIN:Retribution"] = 70,
	["HUNTER:Beast Mastery"] = 253, ["HUNTER:Marksmanship"] = 254, ["HUNTER:Survival"] = 255,
	["ROGUE:Assassination"] = 259, ["ROGUE:Combat"] = 260, ["ROGUE:Subtlety"] = 261,
	["PRIEST:Discipline"] = 256, ["PRIEST:Holy"] = 257, ["PRIEST:Shadow"] = 258,
	["DEATHKNIGHT:Blood"] = 250, ["DEATHKNIGHT:Frost"] = 251, ["DEATHKNIGHT:Unholy"] = 252, ["DEATHKNIGHT:Tank"] = 250,
	["SHAMAN:Elemental"] = 262, ["SHAMAN:Enhancement"] = 263, ["SHAMAN:Restoration"] = 264,
	["MAGE:Arcane"] = 62, ["MAGE:Fire"] = 63, ["MAGE:Frost"] = 64,
	["WARLOCK:Affliction"] = 265, ["WARLOCK:Demonology"] = 266, ["WARLOCK:Destruction"] = 267,
	["DRUID:Balance"] = 102, ["DRUID:Feral (Cat)"] = 103, ["DRUID:Feral (Bear)"] = 104, ["DRUID:Restoration"] = 105,
}
local SPEC_COORDS = {
	[62] = {0.251953, 0.375, 0.125, 0.25}, [63] = {0.375, 0.5, 0.125, 0.25}, [64] = {0.5, 0.625, 0.125, 0.25},
	[65] = {0, 0.125, 0.25, 0.375}, [66] = {0.125, 0.25, 0.25, 0.375}, [70] = {0.251953, 0.375, 0.25, 0.375},
	[71] = {0.875, 1.0, 0.375, 0.5}, [72] = {0, 0.125, 0.5, 0.625}, [73] = {0.125, 0.25, 0.5, 0.625},
	[102] = {0.375, 0.5, 0, 0.125}, [103] = {0.5, 0.625, 0, 0.125}, [104] = {0.625, 0.75, 0, 0.125}, [105] = {0.75, 0.875, 0, 0.125},
	[250] = {0, 0.125, 0, 0.125}, [251] = {0.125, 0.25, 0, 0.125}, [252] = {0.25, 0.375, 0, 0.125},
	[253] = {0.875, 1.0, 0, 0.125}, [254] = {0, 0.125, 0.125, 0.25}, [255] = {0.125, 0.25, 0.125, 0.25},
	[256] = {0.375, 0.5, 0.25, 0.375}, [257] = {0.5, 0.625, 0.25, 0.375}, [258] = {0.632812, 0.75, 0.25, 0.375},
	[259] = {0.75, 0.875, 0.25, 0.375}, [260] = {0.875, 1.0, 0.25, 0.375}, [261] = {0, 0.125, 0.375, 0.5},
	[262] = {0.125, 0.25, 0.375, 0.5}, [263] = {0.25, 0.375, 0.375, 0.5}, [264] = {0.375, 0.5, 0.375, 0.5},
	[265] = {0.5, 0.625, 0.375, 0.5}, [266] = {0.625, 0.75, 0.375, 0.5}, [267] = {0.75, 0.875, 0.375, 0.5},
}
local CLASS_ATLAS = "Interface\\WorldStateFrame\\Icons-Classes"

--- texture path + {l, r, t, b} for a spec key ("ROGUE:Combat"), else the class icon; nil when neither is known.
function UI:SpecArt(specKey, class)
	local c = specKey and SPEC_COORDS[SPEC_ID[specKey] or 0]
	if c then return SPEC_ATLAS, c end
	class = class or (specKey and specKey:match("^(%u+):"))
	c = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
	if c then return CLASS_ATLAS, c end
end

--- Sets a texture to the spec (or class) icon; hides it when unknown.
function UI:SetSpecIcon(tex, specKey, class)
	local path, c = self:SpecArt(specKey, class)
	if not path then tex:Hide() return end
	tex:SetTexture(path)
	tex:SetTexCoord(c[1], c[2], c[3], c[4])
	tex:Show()
end

--- Inline "|T...|t" spec icon for font strings ("" when unknown).
function UI:SpecTag(specKey, class, size)
	local path, c = self:SpecArt(specKey, class)
	if not path then return "" end
	local px = path == SPEC_ATLAS and 512 or 256
	size = size or 14
	local function r(v) return math.floor(v * px + 0.5) end
	return string.format("|T%s:%d:%d:0:0:%d:%d:%d:%d:%d:%d|t ", path, size, size, px, px, r(c[1]), r(c[2]), r(c[3]), r(c[4]))
end

--- "|cffrrggbbName|r" in class colour.
function UI:ClassName(name, class)
	local c = self:ClassColor(class)
	return string.format("|cff%02x%02x%02x%s|r", math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255), name or "?")
end

--- "+12" green / "-7" red / "±0" for a signed number (any suffix appended).
function UI:Signed(n, suffix)
	if not n then return "" end
	suffix = suffix or ""
	if n > 0 then return "|cff57c27a+" .. n .. suffix .. "|r" end
	if n < 0 then return "|cffd9534f" .. n .. suffix .. "|r" end
	return "±0" .. suffix
end

--- "r, g, b" of a class (raid colours), for names.
function UI:ClassColor(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then return {c.r, c.g, c.b} end
	return self:Palette().ink
end

------------------------------------------------------------------------
-- player picker: a grid of raid members (enchanters first), fits 40 players on screen
------------------------------------------------------------------------
--- title, onPick(name), marked = {[name] = "tag"} shown after the name (e.g. "E" for enchanters).
--- allowType = also a "type a name" field (for players who are not in the group any more). onPick(name, class).
function UI:PickPlayer(title, onPick, marked, allowType)
	local w = self.picker
	if not w then
		w = self:Window("picker", "", 560, 300, "DIALOG")
		w.buttons = {}
		w.typed = self:Edit(w.body, 200, 22, false, "or type a name")
		w.ok = self:Button(w.body, "OK", 50, 22, "primary")
		w.ok:SetPoint("LEFT", w.typed, "RIGHT", 6, 0)
		w.typed.edit:SetScript("OnEnterPressed", function() w.ok:Click() end)
		self.picker = w
	end
	w:SetTitle(title)
	local names = {}
	local n = GetNumRaidMembers()
	if n > 0 then
		for i = 1, n do
			local name, _, _, _, _, class = GetRaidRosterInfo(i)
			if name then names[#names + 1] = {name, class} end
		end
	else
		names[1] = {UnitName("player"), select(2, UnitClass("player"))}
		for i = 1, GetNumPartyMembers() do names[#names + 1] = {UnitName("party" .. i), select(2, UnitClass("party" .. i))} end
	end
	marked = marked or {}
	table.sort(names, function(x, y)
		if (marked[x[1]] ~= nil) ~= (marked[y[1]] ~= nil) then return marked[x[1]] ~= nil end
		return x[1] < y[1]
	end)
	local COLS, BW, BH = 5, 104, 24
	for i, p in ipairs(names) do
		local b = w.buttons[i]
		if not b then
			b = self:Button(w.body, "", BW, BH, "default")
			w.buttons[i] = b
		end
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", 10 + ((i - 1) % COLS) * (BW + 4), -10 - math.floor((i - 1) / COLS) * (BH + 4))
		b:SetLabel(p[1] .. (marked[p[1]] and (" " .. marked[p[1]]) or ""))
		b:SetTextTint(self:ClassColor(p[2]))
		b:SetScript("OnClick", function() w:Hide() onPick(p[1], p[2]) end)
		b:Show()
	end
	for i = #names + 1, #w.buttons do w.buttons[i]:Hide() end
	local gridH = math.ceil(math.max(#names, 1) / COLS) * (BH + 4)
	w.typed:ClearAllPoints()
	w.typed:SetPoint("TOPLEFT", 10, -14 - gridH)
	w.typed:SetText("")
	w.ok:SetScript("OnClick", function()
		local name = (w.typed:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if name ~= "" then w:Hide() onPick(name:sub(1, 1):upper() .. name:sub(2):lower()) end
	end)
	if allowType then w.typed:Show() w.ok:Show() else w.typed:Hide() w.ok:Hide() end
	w:SetHeight(29 + 20 + gridH + (allowType and 32 or 0))
	w:Show()
	return w
end
