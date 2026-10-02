local ADDON, ns = ...
local L = ns.L

-- World map markers: one circle per zone with the number of Sylvanistas members there.
-- Uses HereBeDragons-Pins (the same library Questie uses), shown on the zone map,
-- its parent and the continent. A checkbox on the map toggles them, like Questie.

local Map = {}
ns.Map = Map

local Pins = ns.Pins()
Map.libOk = Pins ~= nil

local SHOW_FLAG = HBD_PINS_WORLDMAP_SHOW_CONTINENT or 2
local SHOW_HERE = HBD_PINS_WORLDMAP_SHOW_CURRENT or 0
local pool, active = {}, {}
local AddContinentTotals -- defined below, used by RefreshNow
local refreshQueued = false

local function ShortCount(n)
	if n >= 10000 then return ("%dk"):format(math.floor(n / 1000)) end
	if n >= 1000 then return ("%.1fk"):format(n / 1000) end
	return tostring(n)
end

local function PinEnter(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(ns.Zones.NameForKey(self.key), 1, 0.82, 0)
	GameTooltip:AddLine(L.PIN_TOTAL:format(ns.FormatNumber(self.count)), 1, 1, 1)
	local list = {}
	for name, n in pairs(self.guilds or {}) do list[#list + 1] = { name, n } end
	table.sort(list, function(a, b) return a[2] > b[2] end)
	for i = 1, math.min(10, #list) do
		-- (Guilds from other players' reports: plain text, whatever they carry, 0.9.2.)
		GameTooltip:AddDoubleLine(ns.Codec.Plain(list[i][1]), ns.FormatNumber(list[i][2]), 0.8, 0.8, 0.8, 1, 1, 1)
	end
	-- 1.1.2's review: why a zone's soldiers add up to less than the army online (the answer bank's).
	if ns.Answers and ns.Answers.WhyTip then ns.Answers.WhyTip(GameTooltip, "count-map-zones") end
	GameTooltip:Show()
end

local function CreatePin()
	local p = CreateFrame("Frame", nil, UIParent)
	p.sylvanistas = true -- (ours: photo mode leaves it shown, UI.TogglePhoto)
	p:SetSize(20, 20)
	p:EnableMouse(true)
	p.edge = p:CreateTexture(nil, "BACKGROUND", nil, -1)
	p.edge:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
	p.edge:SetVertexColor(0.9, 0.76, 0.36, 0.95)
	p.edge:SetPoint("TOPLEFT", -2, 2)
	p.edge:SetPoint("BOTTOMRIGHT", 2, -2)
	p.bg = p:CreateTexture(nil, "BACKGROUND", nil, 1)
	p.bg:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
	p.bg:SetVertexColor(0.12, 0.07, 0.02, 0.9)
	p.bg:SetAllPoints()
	p.text = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	p.text:SetPoint("CENTER", 0, 0)
	p:SetScript("OnEnter", PinEnter)
	p:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return p
end

-- A city's map is not a child of the zone around it (Stormwind's parent is Eastern Kingdoms,
-- not Elwynn Forest), so its pin would not show on that zone's map. The zone that contains a
-- map's centre, found once through HereBeDragons' world coordinates: { zone, x, y } or false.
local containerOf = {}
local function ContainerOf(mapID)
	if containerOf[mapID] ~= nil then return containerOf[mapID] end
	local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
	if not HBD or not HBD.GetWorldCoordinatesFromZone or not C_Map.GetMapInfo then return false end
	containerOf[mapID] = false
	local wx, wy, instance = HBD:GetWorldCoordinatesFromZone(0.5, 0.5, mapID)
	local info = C_Map.GetMapInfo(mapID)
	if not wx or not info or not info.parentMapID then return false end
	local ownW, ownH = HBD:GetZoneSize(mapID)
	local best, bestArea
	for _, child in ipairs(C_Map.GetMapChildrenInfo(info.parentMapID) or {}) do
		local zone = child.mapID
		if zone ~= mapID then
			local x, y = HBD:GetZoneCoordinatesFromWorld(wx, wy, zone)
			local w, h = HBD:GetZoneSize(zone)
			local area = (w or 0) * (h or 0)
			-- A city: its whole map lies inside a zone at least four times bigger (neighbouring
			-- zones only overlap at their borders), and the smallest such zone.
			local ax, ay = HBD:GetWorldCoordinatesFromZone(0, 0, mapID)
			local bx, by = HBD:GetWorldCoordinatesFromZone(1, 1, mapID)
			local inside = ax and bx and HBD:GetZoneCoordinatesFromWorld(ax, ay, zone) and HBD:GetZoneCoordinatesFromWorld(bx, by, zone)
			if x and y and inside and area >= 4 * (ownW or 0) * (ownH or 0) and (not best or area < bestArea) then
				best, bestArea = { zone = zone, x = x, y = y }, area
			end
		end
	end
	containerOf[mapID] = best or false
	return containerOf[mapID]
end
Map.ContainerOf = ContainerOf -- for tests

local function RefreshNow()
	refreshQueued = false
	if not Pins then return end
	-- With the gamepad UI no zone circles (they are the pin library's, ns.WorldMapIcons); the
	-- continent totals below are drawn by us, never through the library, and stay.
	local world = ns.WorldMapIcons(Pins, Map)
	if world then Pins:RemoveAllWorldMapIcons(Map) end
	for i = #active, 1, -1 do
		active[i]:Hide()
		pool[#pool + 1] = active[i]
		active[i] = nil
	end
	if not ns.db.showMap or not ns.IsMember() then
		AddContinentTotals({ zoneList = {}, zoneGuilds = {} }) -- also clears the continent circles
		return
	end
	local s = ns.Data.Summary()
	for _, z in ipairs(world and s.zoneList or {}) do
		local mapID = ns.Zones.MapID(z.key)
		if mapID and z.count > 0 then
			local p = table.remove(pool) or CreatePin()
			local size = math.min(34, 16 + math.floor(5 * math.log10(z.count)))
			p:SetSize(size, size)
			p.text:SetText(ShortCount(z.count))
			p.key, p.count, p.guilds = z.key, z.count, s.zoneGuilds[z.key]
			Pins:AddWorldMapIconMap(Map, p, mapID, 0.5, 0.5, SHOW_FLAG)
			active[#active + 1] = p
			-- The same count where the city sits on the map of the zone around it.
			local around = ContainerOf(mapID)
			if around then
				local q = table.remove(pool) or CreatePin()
				q:SetSize(size, size)
				q.text:SetText(ShortCount(z.count))
				q.key, q.count, q.guilds = z.key, z.count, s.zoneGuilds[z.key]
				Pins:AddWorldMapIconMap(Map, q, around.zone, around.x, around.y, SHOW_HERE)
				active[#active + 1] = q
			end
		end
	end
	AddContinentTotals(s)
end

-- Totals per continent, drawn on the world (Azeroth) map; a continent outside it (1.1: TBC
-- Anniversary's Outland, under the Cosmic map) on the map above it, when that is a world or the
-- Cosmic map.
local WORLD_MAP = 947
local TOP_TYPES = { [0] = true, [1] = true } -- Enum.UIMapType.Cosmic, World
local CONTINENT = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
local continentOf = {}
local function ContinentOf(mapID)
	if continentOf[mapID] ~= nil then return continentOf[mapID] end
	local id, guard = mapID, 0
	while id and guard < 10 do
		local info = C_Map.GetMapInfo(id)
		if not info then break end
		if info.mapType == CONTINENT then
			continentOf[mapID] = id
			return id
		end
		id, guard = info.parentMapID, guard + 1
	end
	continentOf[mapID] = false
	return false
end

-- { [continentMapID] = count } plus per-guild breakdown, from a Data.Summary().
function Map.ContinentTotals(s)
	local totals, guilds = {}, {}
	for _, z in ipairs(s.zoneList) do
		local mapID = ns.Zones.MapID(z.key)
		local cont = mapID and ContinentOf(mapID)
		if cont then
			totals[cont] = (totals[cont] or 0) + z.count
			guilds[cont] = guilds[cont] or {}
			for name, n in pairs(s.zoneGuilds[z.key] or {}) do guilds[cont][name] = (guilds[cont][name] or 0) + n end
		end
	end
	return totals, guilds
end

-- Continent totals are drawn straight on the world map canvas. The pin library places
-- pins through world coordinates, which the Azeroth map does not have, so it put every
-- continent total inside Eastern Kingdoms.
local overlay, overlayData = {}, {}

local function Canvas()
	return WorldMapFrame and WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas()
end

local function CanvasScale()
	local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
	local scale = sc and sc.GetCanvasScale and sc:GetCanvasScale()
	if not scale or scale <= 0 then
		local canvas = Canvas()
		scale = canvas and canvas:GetScale() or 1
	end
	return (scale and scale > 0) and scale or 1
end

function Map.LayoutOverlay()
	for _, f in ipairs(overlay) do f:Hide() end
	local canvas = Canvas()
	if not canvas or not WorldMapFrame:IsShown() or not ns.db.showMap or not ns.IsMember() then return end
	local shown = WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
	local here = {}
	for _, d in ipairs(overlayData) do
		if d.on == shown then here[#here + 1] = d end
	end
	if #here == 0 then return end
	local w, h, scale = canvas:GetWidth(), canvas:GetHeight(), CanvasScale()
	for i, d in ipairs(here) do
		local f = overlay[i]
		if not f then
			f = CreatePin()
			f:SetParent(canvas)
			overlay[i] = f
		end
		f:SetFrameLevel(canvas:GetFrameLevel() + 100)
		-- Undo the canvas zoom so the circle keeps the same size on screen; SetPoint offsets
		-- are in the frame's own (scaled) units, hence the * scale.
		f:SetScale(1 / scale)
		f:SetSize(44, 44)
		f.text:SetText(ShortCount(d.count))
		f.key, f.count, f.guilds = "m" .. d.cont, d.count, d.guilds
		f:ClearAllPoints()
		f:SetPoint("CENTER", canvas, "TOPLEFT", d.x * w * scale, -d.y * h * scale)
		f:Show()
	end
end

-- The map a continent's total is drawn on, and the continent's rect there: the Azeroth map, or
-- the world or Cosmic map right above the continent. nil when neither has it.
function Map.OverlayMap(cont)
	if not C_Map.GetMapRectOnMap then return nil end
	local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(cont, WORLD_MAP)
	if minX and maxX and minY and maxY then return WORLD_MAP, minX, maxX, minY, maxY end
	local info = C_Map.GetMapInfo(cont)
	local parent = info and info.parentMapID
	local above = parent and parent ~= WORLD_MAP and C_Map.GetMapInfo(parent)
	if not (above and TOP_TYPES[above.mapType]) then return nil end
	minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(cont, parent)
	if minX and maxX and minY and maxY then return parent, minX, maxX, minY, maxY end
	return nil
end
Map.overlayData = overlayData -- tests

function AddContinentTotals(s)
	wipe(overlayData)
	local totals, guilds = Map.ContinentTotals(s)
	for cont, count in pairs(totals) do
		local on, minX, maxX, minY, maxY = Map.OverlayMap(cont)
		if on then
			overlayData[#overlayData + 1] = { cont = cont, count = count, guilds = guilds[cont], on = on, x = (minX + maxX) / 2, y = (minY + maxY) / 2 }
		end
	end
	Map.LayoutOverlay()
end

---------------------------------------------------------------------------
-- Round icons beside the circles (1.0.0): the decrees and the King's crown on the world map.
-- Each is an anchor the pin library puts where the decree was called or the King stands, and a
-- badge drawn from it: on that very spot, or, when that spot is under a zone's circle, just
-- outside the circle's edge (top right first, then the other corners and sides), so its number
-- stays readable. Several around one circle each take a place of their own. Laid out again while
-- one is on the map (their OnUpdate, a few times a second: the map changes, zooms, the circles
-- come and go). Mouse and keyboard only: with the gamepad UI none of them is on the world map
-- (ns.WorldMapIcons), and nothing here runs.
---------------------------------------------------------------------------

Map.MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
Map.BADGE_SLOTS = { 45, 135, -45, -135, 0, 180, 90, -90 } -- degrees from the right, counterclockwise: top right first
Map.BADGE_REACH = 0.75 -- a badge's centre this many of its radii past a circle's edge: over its rim at most
Map.BADGE_RINGS = 3    -- rings of places around a crowded circle
Map.BADGE_EVERY = 0.1  -- seconds between layouts while a badge is on the map
-- Laid out at most (1.0.0, Konig's review of 1.0.0: every badge tries every place round its
-- circle against every other, a few times a second, and enough decrees at once stalled the world
-- map): the crown first, then the newest decrees (Map.Badge's `since`); the rest stay on their spot.
Map.BADGE_MAX = 24
local badges = {}      -- every anchor made (a handful: the crown, the decrees, reused)
local lastLayout = -math.huge

-- Where each badge goes, all in screen pixels: list = { { x, y, r } } (the spots the badges are
-- for), circles = { { x, y, r } } (the zone circles on the map). Returns { { dx, dy } }: each
-- badge's shift from its spot.
function Map.PlaceBadges(list, circles)
	local K, placed, out = Map.BADGE_REACH, {}, {}
	-- A badge (radius r) at x, y over circle c's number.
	local function Covers(x, y, r, c)
		local dx, dy = x - c.x, y - c.y
		return dx * dx + dy * dy < (c.r + K * r) ^ 2
	end
	local function Free(x, y, r)
		for _, c in ipairs(circles) do if Covers(x, y, r, c) then return false end end
		for _, p in ipairs(placed) do
			local dx, dy = x - p.x, y - p.y
			if dx * dx + dy * dy < (r + p.r) ^ 2 then return false end
		end
		return true
	end
	for i, b in ipairs(list) do
		-- The circle it covers (the nearest, if several).
		local home, best
		for _, c in ipairs(circles) do
			local d = (b.x - c.x) ^ 2 + (b.y - c.y) ^ 2
			if Covers(b.x, b.y, b.r, c) and (not best or d < best) then home, best = c, d end
		end
		local x, y = b.x, b.y
		if home then
			local spot, first
			for ring = 0, Map.BADGE_RINGS - 1 do
				local reach = home.r + K * b.r + 0.5 + ring * 2 * b.r
				for _, a in ipairs(Map.BADGE_SLOTS) do
					local px, py = home.x + reach * math.cos(math.rad(a)), home.y + reach * math.sin(math.rad(a))
					first = first or { px, py }
					if Free(px, py, b.r) then spot = { px, py } break end
				end
				if spot then break end
			end
			-- Crowded all round: its circle's top right, over a neighbour's rim at worst.
			spot = spot or first
			x, y = spot[1], spot[2]
		end
		placed[#placed + 1] = { x = x, y = y, r = b.r }
		out[i] = { dx = x - b.x, dy = y - b.y }
	end
	return out
end

-- A frame on the map as a circle on the screen (centre, and `radius` of its own units, in
-- pixels), or nil while it is not on the map.
local function OnScreen(f, radius)
	if not (f and f.IsVisible and f:IsVisible()) or type(radius) ~= "number" then return nil end
	local x, y = f:GetCenter()
	local s = f:GetEffectiveScale()
	if type(x) ~= "number" or type(y) ~= "number" or type(s) ~= "number" then return nil end
	return { x = x * s, y = y * s, r = radius * s }
end

-- Puts every badge on the map where Map.PlaceBadges says, over the zone circles (both stay
-- readable: the badge keeps off their numbers).
function Map.LayoutBadges()
	if ns.GamepadUI() then return end
	local list, shown, rest = {}, {}, {}
	for _, a in ipairs(badges) do
		local c = OnScreen(a, a.reach)
		if c then list[#list + 1], shown[#shown + 1] = c, a end
	end
	if #list == 0 then return end
	if #shown > Map.BADGE_MAX then
		-- The crown (no `since`) first, then the newest; past BADGE_MAX, each on its own spot.
		local order = {}
		for i = 1, #shown do order[i] = i end
		table.sort(order, function(x, y)
			local sx, sy = shown[x].since or math.huge, shown[y].since or math.huge
			if sx ~= sy then return sx > sy end
			return x < y
		end)
		local keptList, keptShown = {}, {}
		for rank, i in ipairs(order) do
			if rank <= Map.BADGE_MAX then
				keptList[#keptList + 1], keptShown[#keptShown + 1] = list[i], shown[i]
			else
				rest[#rest + 1] = shown[i]
			end
		end
		list, shown = keptList, keptShown
	end
	for _, a in ipairs(rest) do
		if a.dx ~= 0 or a.dy ~= 0 then
			a.dx, a.dy = 0, 0
			a.badge:ClearAllPoints()
			a.badge:SetPoint("CENTER", a, "CENTER", 0, 0)
		end
		local level = (a:GetFrameLevel() or 0) + 3
		if a.badge:GetFrameLevel() ~= level then a.badge:SetFrameLevel(level) end
	end
	local circles = {}
	local function Circle(p)
		local w = p.GetWidth and p:GetWidth()
		local c = type(w) == "number" and OnScreen(p, w / 2 + 2) -- (its gold edge: 2 past the disc)
		if c then circles[#circles + 1] = c end
	end
	for _, p in ipairs(active) do Circle(p) end
	for _, f in ipairs(overlay) do Circle(f) end
	local spots = Map.PlaceBadges(list, circles)
	for i, a in ipairs(shown) do
		local s = a:GetEffectiveScale()
		local dx, dy = spots[i].dx / s, spots[i].dy / s
		if math.abs(dx - a.dx) > 0.5 or math.abs(dy - a.dy) > 0.5 then
			a.dx, a.dy = dx, dy
			a.badge:ClearAllPoints()
			a.badge:SetPoint("CENTER", a, "CENTER", dx, dy)
		end
		local level = (a:GetFrameLevel() or 0) + 3
		if a.badge:GetFrameLevel() ~= level then a.badge:SetFrameLevel(level) end
	end
end

local function BadgeTick()
	local now = GetTime()
	if now - lastLayout < Map.BADGE_EVERY then return end
	lastLayout = now
	ns.SafeCall("map badges", Map.LayoutBadges)
end

-- A square icon made round: the portrait mask (Texture:SetMask, on Forever, Era and
-- Anniversary), or the game's portrait maker on a client without it.
-- Its coords are cut once, before the mask: a texture that has one refuses new coords (Forever
-- 1.60: "Cannot set tex coords when texture has mask"), and a new picture keeps them.
local function RoundIcon(tex, texture)
	if tex.sylvanistasRound == nil then
		tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- (the icon's own border cut off)
		tex.sylvanistasRound = tex.SetMask ~= nil and pcall(tex.SetMask, tex, Map.MASK) or false
		if not tex.sylvanistasRound then tex:SetTexCoord(0, 1, 0, 1) end
	end
	if not tex.sylvanistasRound and SetPortraitToTexture then
		pcall(SetPortraitToTexture, tex, texture)
	end
end
Map.RoundIcon = RoundIcon -- (tests)

-- A badge of `size`: the anchor the pin library places (nothing of it shows or takes the
-- mouse) and anchor.badge, what shows (tooltips go on it). `round`: an icon in a coloured disc,
-- like the zone circles; otherwise its picture as drawn (the crown).
function Map.Badge(size, round)
	local anchor = CreateFrame("Frame", nil, UIParent)
	anchor.sylvanistas = true -- (ours: photo mode leaves it shown, UI.TogglePhoto)
	anchor:SetSize(1, 1)
	anchor:Hide() -- (the pin library shows it when it puts it on the map)
	local b = CreateFrame("Frame", nil, anchor)
	b:SetSize(size, size)
	b:SetPoint("CENTER", anchor, "CENTER", 0, 0)
	if round then
		b.edge = b:CreateTexture(nil, "BACKGROUND")
		b.edge:SetTexture(Map.MASK)
		b.edge:SetPoint("TOPLEFT", -2, 2)
		b.edge:SetPoint("BOTTOMRIGHT", 2, -2)
	end
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetAllPoints()
	b:EnableMouse(true)
	anchor.badge, anchor.round, anchor.dx, anchor.dy = b, round, 0, 0
	anchor.reach = size / 2 + (round and 2 or 0) -- its radius on the map, the disc's edge included
	anchor:SetScript("OnUpdate", BadgeTick)
	badges[#badges + 1] = anchor
	return anchor
end

-- Its picture: `texture`, round in a disc of r, g, b (a round badge), or as drawn.
function Map.SetBadge(anchor, texture, r, g, b)
	local icon = anchor.badge.icon
	icon:SetTexture(texture)
	if anchor.round then
		anchor.badge.edge:SetVertexColor(r or 0.9, g or 0.76, b or 0.36, 1)
		RoundIcon(icon, texture)
	end
end

function Map.Refresh()
	ns.SafeCall("map refresh", RefreshNow)
end

local function QueueRefresh()
	if refreshQueued then return end
	refreshQueued = true
	ns.After(1, "map refresh", Map.Refresh)
end

-- "Sylvanistas" menu on the world map: everything map related lives here, like Questie's toggle.
local toggle, menu
local OPTIONS = {
	{ key = "showMap", label = "MAPOPT_ZONES", apply = function() Map.Refresh() end },
	{ key = "showDecrees", label = "MAPOPT_DECREES", apply = function() ns.Decree.RefreshPins() end },
	-- The Board's camps (1.1, Board.lua).
	{ key = "showCamps", label = "MAPOPT_CAMPS", apply = function() if ns.Board and ns.Board.RefreshCamps then ns.Board.RefreshCamps() end end },
}

local function CreateMapToggle()
	if toggle or not WorldMapFrame then return end
	local anchor = WorldMapFrame.ScrollContainer or WorldMapFrame
	-- Round, bottom left corner of the map (Questie uses the top right; Forever's map has its
	-- own buttons along the bottom right).
	toggle = ns.MakeRoundButton("SylvanistasMapToggle", WorldMapFrame, 30)
	toggle:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 6, 6)
	toggle:SetFrameLevel(anchor:GetFrameLevel() + 50)

	local okMenu, m = pcall(CreateFrame, "Frame", "SylvanistasMapMenu", toggle, "BackdropTemplate")
	menu = okMenu and m or CreateFrame("Frame", "SylvanistasMapMenuPlain", toggle)
	menu:SetSize(170, 24 + #OPTIONS * 22)
	menu:SetPoint("BOTTOMLEFT", toggle, "TOPLEFT", 0, 2)
	if menu.SetBackdrop then
		menu:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		menu:SetBackdropColor(0, 0, 0, 0.9)
	end
	local title = menu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText(L.TITLE)
	menu.checks = {}
	for i, opt in ipairs(OPTIONS) do
		local cb = CreateFrame("CheckButton", nil, menu, "UICheckButtonTemplate")
		cb:SetSize(20, 20)
		cb:SetPoint("TOPLEFT", 6, -20 - (i - 1) * 22)
		local label = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
		label:SetText(L[opt.label])
		cb:SetScript("OnClick", function(self)
			ns.db[opt.key] = self:GetChecked() and true or false
			ns.SafeCall("map option", opt.apply)
		end)
		cb.opt = opt
		menu.checks[i] = cb
	end
	menu:SetScript("OnShow", function(self)
		for _, cb in ipairs(self.checks) do cb:SetChecked(ns.db[cb.opt.key]) end
	end)
	menu:Hide()
	toggle:SetScript("OnClick", function() menu:SetShown(not menu:IsShown()) end)
	toggle:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(L.TITLE, 1, 0.82, 0)
		GameTooltip:AddLine(L.MAPOPT_TIP, 1, 1, 1)
		GameTooltip:Show()
	end)
	toggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function Map.SetEnabled(on)
	ns.db.showMap = on and true or false
	if menu and menu:IsShown() then menu:GetScript("OnShow")(menu) end
	ns.Print(ns.db.showMap and L.MAP_ON or L.MAP_OFF)
	Map.Refresh()
	ns.Fire("MAP_TOGGLED")
end

ns.On("DATA_CHANGED", QueueRefresh)

local hooked = false
local function HookWorldMap()
	if hooked or not WorldMapFrame then return end
	hooked = true
	local function relayout() ns.SafeCall("map overlay", Map.LayoutOverlay) end
	if WorldMapFrame.OnMapChanged then pcall(hooksecurefunc, WorldMapFrame, "OnMapChanged", relayout) end
	WorldMapFrame:HookScript("OnShow", relayout)
	WorldMapFrame:HookScript("OnHide", relayout)
	local sc = WorldMapFrame.ScrollContainer
	if sc then
		sc:HookScript("OnMouseWheel", relayout)
		sc:HookScript("OnSizeChanged", relayout)
	end
end

-- The pin library's world map provider, with the gamepad UI (0.9.9). On every map change, and
-- at each loading screen, it clears its pins from the map whether it has any or not, through
-- RemoveAllPinsByTemplate: that marks the map's canvas dirty (MarkCanvasDirty clears its current
-- zoom) from the library's code, which is ours when our copy is the one loaded. The gamepad map
-- then zooms, builds its button bar and closes with B in our taint, and the game blocks it
-- until a /reload. So there, with none of the library's pins on the map, it returns at once:
-- there is nothing to clear. With pins to clear, and always with mouse and keyboard, the
-- library's own code runs, as it came. Only our own copy (another addon's code is not ours to
-- change), wrapped once at login, before the map is first opened; the provider and its pool
-- stay, other addons may use this copy too.
local providerQuiet = false
function Map.QuietPinsProvider()
	if providerQuiet then return true end
	local lib = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
	local provider = type(lib) == "table" and lib.worldmapProvider
	local original = type(provider) == "table" and provider.RemoveAllData
	if type(original) ~= "function" or type(issecurevariable) ~= "function" then return false end
	local _, owner = issecurevariable(provider, "RemoveAllData")
	if owner ~= ADDON then return false end
	providerQuiet = true
	provider.RemoveAllData = function(self, ...)
		if ns.GamepadUI() then
			local pinPool = lib.worldmapPinsPool
			if type(pinPool) == "table" and type(pinPool.GetNumActive) == "function" and pinPool:GetNumActive() == 0 then return end
		end
		return original(self, ...)
	end
	return true
end

ns.On("LOGIN", function()
	ns.SafeCall("map provider", Map.QuietPinsProvider)
	ns.SafeCall("map hooks", HookWorldMap)
	if not Pins then
		local raw = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
		-- A half-loaded library can still run its per-frame update and raise an error on
		-- every frame. Stop it: no map features is fine, a flood of errors is not.
		if raw and raw.updateFrame then
			raw.updateFrame:SetScript("OnUpdate", nil)
			raw.updateFrame:SetScript("OnEvent", nil)
			raw.updateFrame:UnregisterAllEvents()
			ns.Log("stopped the broken map library update loop")
		end
		local minors = LibStub and LibStub.minors or {}
		ns.Log("map library unavailable: pins=%s minor=%s hbd=%s AddWorldMapIconMap=%s RemoveAll=%s AddMinimap=%s",
			tostring(raw ~= nil), tostring(minors["HereBeDragons-Pins-2.0"]), tostring(minors["HereBeDragons-2.0"]),
			tostring(raw and raw.AddWorldMapIconMap ~= nil), tostring(raw and raw.RemoveAllWorldMapIcons ~= nil),
			tostring(raw and raw.AddMinimapIconMap ~= nil))
		ns.Log("map env: WorldMapFrame=%s GetCanvas=%s pinPools=%s AddDataProvider=%s CreateUnsecuredRegionPoolInstance=%s CreateFramePool=%s MapCanvasPinMixin=%s Minimap=%s",
			tostring(WorldMapFrame ~= nil), tostring(WorldMapFrame and WorldMapFrame.GetCanvas ~= nil),
			type(WorldMapFrame and WorldMapFrame.pinPools), tostring(WorldMapFrame and WorldMapFrame.AddDataProvider ~= nil),
			tostring(CreateUnsecuredRegionPoolInstance ~= nil), tostring(CreateFramePool ~= nil),
			tostring(MapCanvasPinMixin ~= nil), tostring(Minimap ~= nil))
	end
	CreateMapToggle()
	if not toggle then
		ns.RegisterEvent("ADDON_LOADED", function(name)
			if name == "Blizzard_WorldMap" then CreateMapToggle(); ns.SafeCall("map hooks", HookWorldMap) end
		end)
	end
	QueueRefresh()
end)
