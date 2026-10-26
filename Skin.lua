-- CHSkin: tiny shared skinning helper for my addons (Parse Percentile, Raid Brief, RollFor, Bistooltip).
-- Uses ElvUI's own skin functions when ElvUI is loaded (so frames match the user's ElvUI profile exactly) and a flat dark
-- fallback otherwise. Each addon ships an identical copy; the highest version loaded wins (LibStub-style).
-- Source of truth: wow-ui/shared/CHSkin.lua  ->  copied into each addon as Skin.lua by wow-ui/shared/sync_skin.py.
-- WoW 3.3.5a, Lua 5.1.

local VERSION = 5
if _G.CHSkin and _G.CHSkin.version >= VERSION then return end
local Skin = { version = VERSION }
_G.CHSkin = Skin

local FLAT = "Interface\\Buttons\\WHITE8X8"

local function elvE()
    if not _G.ElvUI then return nil end
    local ok, E = pcall(function() return (unpack(_G.ElvUI)) end)
    if ok and type(E) == "table" then return E end
end

local function elvS()
    local E = elvE()
    if E and E.GetModule then
        local ok, S = pcall(E.GetModule, E, "Skins")
        if ok and type(S) == "table" then return S end
    end
end

function Skin.IsElv() return elvE() ~= nil end

-- colors: {r,g,b} accent, {r,g,b,a} bg and border
function Skin.Colors()
    local E = elvE()
    local m = E and E.media
    local accent = (m and m.rgbvaluecolor) or { 0.09, 0.52, 0.82 }
    local bg = (m and m.backdropfadecolor) or { 0.06, 0.06, 0.06, 0.9 }
    local border = (m and m.bordercolor) or { 0, 0, 0, 1 }
    return accent, bg, border
end

function Skin.AccentHex()
    local a = Skin.Colors()
    return string.format("%02x%02x%02x", math.floor(a[1] * 255 + 0.5), math.floor(a[2] * 255 + 0.5), math.floor(a[3] * 255 + 0.5))
end

-- The user's font is Expressway: follow ElvUI's configured main font (E.media.normFont); if ElvUI is loaded but reports
-- none, use the Expressway.ttf that ElvUI ships; without ElvUI use the stock font.
local EXPRESSWAY = "Interface\\AddOns\\ElvUI\\Media\\Fonts\\Expressway.ttf"
function Skin.FontPath()
    local E = elvE()
    if E and E.media and E.media.normFont then return E.media.normFont end
    if E or (_G.IsAddOnLoaded and _G.IsAddOnLoaded("ElvUI")) then return EXPRESSWAY end
    return _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

-- status bar texture: ElvUI's main bar texture when available, a flat fill otherwise
function Skin.BarTexture()
    local E = elvE()
    return (E and E.media and E.media.normTex) or FLAT
end

function Skin.Font(fs, size, flags)
    if fs and fs.SetFont then fs:SetFont(Skin.FontPath(), size or 12, flags or "") end
    return fs
end

-- panel / window background. kind: "transparent" (default) or "solid"
function Skin.Panel(f, kind)
    if f.SetTemplate and elvE() then
        f:SetTemplate(kind == "solid" and "Default" or "Transparent")
        return f
    end
    local _, bg, border = Skin.Colors()
    f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, tile = false, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    f:SetBackdropColor(bg[1], bg[2], bg[3], kind == "solid" and 1 or (bg[4] or 0.9))
    f:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
    return f
end

local function flatButtonHover(b)
    local accent, _, border = Skin.Colors()
    b:HookScript("OnEnter", function(self) if not self.__active then self:SetBackdropBorderColor(accent[1], accent[2], accent[3], 1) end end)
    b:HookScript("OnLeave", function(self)
        if self.__active then return end
        self:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
    end)
end

-- style an existing Button (plain or Blizzard template)
function Skin.Button(b)
    if b.__chskinned then return b end
    b.__chskinned = true
    for _, k in ipairs({ "SetNormalTexture", "SetHighlightTexture", "SetPushedTexture", "SetDisabledTexture" }) do
        if b[k] then b[k](b, "") end
    end
    local S = elvS()
    if S and b.SetTemplate then
        S:HandleButton(b)
    else
        Skin.Panel(b, "solid")
        flatButtonHover(b)
    end
    local fs = b.GetFontString and b:GetFontString()
    if fs then Skin.Font(fs, 11) end
    return b
end

function Skin.NewButton(parent, w, h, text, template)
    local b = CreateFrame("Button", nil, parent, template)
    b:SetWidth(w); b:SetHeight(h)
    local fs = b:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("CENTER", b, "CENTER", 0, 0)
    b:SetFontString(fs)
    Skin.Font(fs, 11)
    fs:SetTextColor(1, 1, 1)
    if text then b:SetText(text) end
    return Skin.Button(b)
end

-- "selected" look for toggle-like buttons (tabs, list entries)
function Skin.SetActive(b, active)
    b.__active = active and true or false
    local accent, _, border = Skin.Colors()
    local r, g, bl = accent[1], accent[2], accent[3]
    if b.__card then -- Skin.NewTab entries: card tint + accent bar
        Skin.CardState(b, false, b.__active, b.__card)
        if b.__edge then b.__edge:SetVertexColor(r, g, bl, 1); if b.__active then b.__edge:Show() else b.__edge:Hide() end end
        local fs = b:GetFontString()
        if fs then if b.__active then fs:SetTextColor(1, 1, 1) else fs:SetTextColor(0.85, 0.85, 0.85) end end
        return
    end
    if b.SetBackdropBorderColor then
        if active then b:SetBackdropBorderColor(r, g, bl, 1) else b:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1) end
    end
    local fs = b.GetFontString and b:GetFontString()
    if fs then if active then fs:SetTextColor(r, g, bl) else fs:SetTextColor(1, 1, 1) end end
end

function Skin.NewClose(parent, template)
    local b = CreateFrame("Button", nil, parent, template)
    b:SetWidth(18); b:SetHeight(18)
    local fs = b:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("CENTER", b, "CENTER", 0, 0)
    b:SetFontString(fs)
    Skin.Font(fs, 12, "OUTLINE")
    b:SetText("x")
    Skin.Button(b)
    if not template then b:SetScript("OnClick", function() parent:Hide() end) end
    return b
end

-- UICheckButtonTemplate check box with a text label: a small box with an accent fill when checked (EllesmereUI's toggles)
function Skin.NewCheck(parent, name, label)
    local c = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    c:SetWidth(24); c:SetHeight(24)
    local t = name and _G[name .. "Text"]
    if t then t:SetText(label or ""); Skin.Font(t, 11) end
    local S = elvS()
    if S and S.HandleCheckBox then S:HandleCheckBox(c) end
    local box = type(c.backdrop) == "table" and c.backdrop or c
    if box.SetBackdropColor then
        box.themePlain, box.ignoreBackdropColors = true, true
        box:SetBackdropColor(0, 0, 0, 0.45)
    end
    c:SetCheckedTexture(FLAT)
    local ct = c:GetCheckedTexture()
    if ct then
        local accent = Skin.Colors()
        ct:SetVertexColor(accent[1], accent[2], accent[3], 0.9)
        ct:ClearAllPoints()
        ct:SetPoint("TOPLEFT", box, "TOPLEFT", 3, -3); ct:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 3)
    end
    return c
end

------------------------------------------------------------------ EllesmereUI-style surfaces (version 5)
-- EllesmereUI layers its surfaces: dark see-through cards over the window, faint white borders, quiet section headers.
-- These surfaces set themePlain, so the fork's theme engine draws no texture or glow on them (only the window has those).

-- a dark see-through card (list rows, info boxes, stat blocks). alpha = how dark (default 0.3)
function Skin.Card(f, alpha)
    f.themePlain = true
    Skin.Panel(f, "solid")
    f.ignoreBackdropColors, f.ignoreBorderColors = true, true
    f:SetBackdropColor(0, 0, 0, alpha or 0.3)
    f:SetBackdropBorderColor(1, 1, 1, 0.06)
    return f
end

-- hover / selected tint for a card: a faint white lift on hover, the accent at low alpha when selected
function Skin.CardState(f, hover, selected, alpha)
    local base = alpha or 0.3
    if selected then
        local a = Skin.Colors()
        f:SetBackdropColor(a[1] * 0.25, a[2] * 0.25, a[3] * 0.25, base + 0.25)
        f:SetBackdropBorderColor(a[1], a[2], a[3], 0.6)
    elseif hover then
        f:SetBackdropColor(0.12, 0.12, 0.12, base + 0.1)
        f:SetBackdropBorderColor(1, 1, 1, 0.14)
    else
        f:SetBackdropColor(0, 0, 0, base)
        f:SetBackdropBorderColor(1, 1, 1, 0.06)
    end
end

-- an existing button as a card: hover lift, accent when selected via Skin.SetActive; b.__card = its darkness
function Skin.CardButton(b, alpha)
    Skin.Card(b, alpha or 0.25)
    b.__card = alpha or 0.25
    b:HookScript("OnEnter", function(self) if not self.__active then Skin.CardState(self, true, false, self.__card) end end)
    b:HookScript("OnLeave", function(self) Skin.CardState(self, false, self.__active, self.__card) end)
    return b
end

-- a list / sidebar entry: a card button with text (and room for an icon), hover lift, accent when selected (Skin.SetActive)
function Skin.NewTab(parent, w, h, text, template)
    local b = CreateFrame("Button", nil, parent, template)
    b:SetWidth(w); b:SetHeight(h)
    Skin.CardButton(b, 0.25)
    local fs = b:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("LEFT", b, "LEFT", 8, 0)
    fs:SetJustifyH("LEFT")
    b:SetFontString(fs)
    Skin.Font(fs, 12)
    fs:SetTextColor(0.85, 0.85, 0.85)
    if text then b:SetText(text) end
    b.__edge = b:CreateTexture(nil, "OVERLAY") -- accent bar on the left edge of the selected entry
    b.__edge:SetTexture(FLAT)
    b.__edge:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1); b.__edge:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 1, 1)
    b.__edge:SetWidth(2)
    b.__edge:Hide()
    return b
end

-- section header: label on the left, a thin rule to the right edge (as in EllesmereUI's bags and options).
-- Returns a frame with .label and .line; set the text with h.label:SetText().
function Skin.SectionHeader(parent, width, size)
    local h = CreateFrame("Frame", nil, parent)
    h:SetWidth(width or 200); h:SetHeight((size or 12) + 6)
    h.label = h:CreateFontString(nil, "OVERLAY")
    Skin.Font(h.label, size or 12)
    h.label:SetPoint("LEFT", h, "LEFT", 0, 0)
    local a = Skin.Colors()
    h.label:SetTextColor(a[1], a[2], a[3])
    h.line = h:CreateTexture(nil, "ARTWORK")
    h.line:SetTexture(FLAT)
    h.line:SetVertexColor(1, 1, 1, 0.1)
    h.line:SetHeight(1)
    h.line:SetPoint("LEFT", h.label, "RIGHT", 8, 0)
    h.line:SetPoint("RIGHT", h, "RIGHT", 0, 0)
    return h
end

-- the dark slot behind an icon (talents, spells, items): black inset + EllesmereUI's faint emblem when the fork ships it.
-- frame = owner of the texture, anchor = the icon region it sits behind (default the frame), inset = px around it
local EMBLEM = "Interface\\AddOns\\ElvUI\\Media\\Ellesmere\\modules\\bags\\icon-bg"
function Skin.Slot(frame, anchor, inset)
    anchor, inset = anchor or frame, inset or 0
    local t = frame:CreateTexture(nil, "BACKGROUND")
    t:SetPoint("TOPLEFT", anchor, "TOPLEFT", -inset, inset)
    t:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", inset, -inset)
    if Skin.IsElv() then t:SetTexture(EMBLEM); t:SetVertexColor(1, 1, 1, 0.6)
    else t:SetTexture(FLAT); t:SetVertexColor(0, 0, 0, 0.5) end
    return t
end

-- scroll frame made with UIPanelScrollFrameTemplate (needs a global name)
function Skin.Scroll(scroll)
    local name = scroll.GetName and scroll:GetName()
    local bar = name and _G[name .. "ScrollBar"]
    local S = elvS()
    if bar and S and S.HandleScrollBar then S:HandleScrollBar(bar) end
end

------------------------------------------------------------------ minimap button (LibDBIcon-style, grabbed by ElvUI)
-- o = { name=, icon=, db=<saved table with .mmAngle/.mmHide>, onClick=function(btn, mouse), tooltip=function(tooltip) }
function Skin.MinimapButton(o)
    local db = o.db
    local b = CreateFrame("Button", "LibDBIcon10_" .. o.name, Minimap)   -- "LibDBIcon" in the name is what ElvUI's button grabber whitelists
    b:SetWidth(31); b:SetHeight(31)
    b:SetFrameStrata("MEDIUM"); b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = b:CreateTexture(nil, "OVERLAY")
    overlay:SetWidth(53); overlay:SetHeight(53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetWidth(20); bg:SetHeight(20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(17); icon:SetHeight(17)
    icon:SetTexture(o.icon)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -6)
    b.icon = icon

    local function place()
        local angle = math.rad((db and db.mmAngle) or 200)
        local half = (Minimap:GetWidth() or 140) / 2 + 5
        local x, y = math.cos(angle) * half, math.sin(angle) * half
        -- square minimaps (ElvUI): keep the button on the edge instead of floating in the corner
        local shape = _G.GetMinimapShape and _G.GetMinimapShape() or "ROUND"
        if shape == "SQUARE" or Skin.IsElv() then
            x = math.max(-half, math.min(x * 1.4142, half)); y = math.max(-half, math.min(y * 1.4142, half))
        end
        b:ClearAllPoints()
        b:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end
    b.Place = place

    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local px, py = GetCursorPosition()
            if db then db.mmAngle = math.deg(math.atan2(py / scale - my, px / scale - mx)) end
            place()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnClick", function(self, mouse) if o.onClick then o.onClick(self, mouse) end end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        if o.tooltip then o.tooltip(GameTooltip) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    function b:SetShown2(show) if show then self:Show() else self:Hide() end end
    place()
    if db and db.mmHide then b:Hide() end
    return b
end
