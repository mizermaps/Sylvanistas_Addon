local ADDON, ns = ...
local L = ns.L

-- Guildmates with the addon on the world map and minimap, as class colored dots.
-- Positions go only to our own guild (GUILD addon messages), never to the whole federation.
-- The send interval grows with the number of addon users so a full guild stays light.

local Positions = {}
ns.Positions = Positions

local Pins = ns.Pins()
local SHOW_FLAG = HBD_PINS_WORLDMAP_SHOW_CONTINENT or 2
local EXPIRE = 60
local MIN_INTERVAL = 15

local mates = {}      -- [shortName] = { mapID, x, y, class, t }
local pins = {}       -- [shortName] = { world = frame, mini = frame }
local last = { t = 0 }

local function Interval()
	return math.max(MIN_INTERVAL, math.floor(ns.Comm.PeerCount() / 3))
end

local function SendPosition()
	if not ns.db.sharePosition or not IsInGuild() or IsInInstance() then return end
	local mapID = C_Map.GetBestMapForUnit("player")
	local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
	if not pos then return end
	local x, y = pos:GetXY()
	if not x or (x == 0 and y == 0) then return end
	local now = ns.Now()
	local moved = last.mapID ~= mapID or math.abs((last.x or 0) - x) > 0.004 or math.abs((last.y or 0) - y) > 0.004
	if now - last.t < Interval() or (not moved and now - last.t < 50) then return end
	last = { mapID = mapID, x = x, y = y, t = now }
	local _, classFile = UnitClass("player")
	ns.Comm.Send("GUILD", ns.Codec.EncodePosition(mapID, x, y, ns.Roster.ClassCode(classFile)), "position")
end

local function Dot(size)
	local f = CreateFrame("Frame", nil, UIParent)
	f.sylvanistas = true -- (ours: photo mode leaves it shown, UI.TogglePhoto)
	f:SetSize(size, size)
	f.edge = f:CreateTexture(nil, "BACKGROUND")
	f.edge:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
	f.edge:SetVertexColor(0, 0, 0, 0.9)
	f.edge:SetAllPoints()
	f.dot = f:CreateTexture(nil, "ARTWORK")
	f.dot:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
	f.dot:SetPoint("TOPLEFT", 1.5, -1.5)
	f.dot:SetPoint("BOTTOMRIGHT", -1.5, 1.5)
	f:EnableMouse(true)
	f:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(self.label or "?")
		GameTooltip:AddLine(L.GUILDMATE, 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	f:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return f
end

local function Color(frame, name, class)
	local file = class and ns.CLASS_FILES[class]
	local c = file and RAID_CLASS_COLORS and RAID_CLASS_COLORS[file]
	if c then frame.dot:SetVertexColor(c.r, c.g, c.b) else frame.dot:SetVertexColor(0.25, 1, 0.25) end
	frame.label = c and ("|c%s%s|r"):format(c.colorStr, name) or name
end

local function RefreshNow()
	if not Pins then return end
	-- The world map's dots only with mouse and keyboard (ns.WorldMapIcons); the minimap's always.
	local world = ns.WorldMapIcons(Pins, Positions)
	local now = ns.Now()
	for name, p in pairs(pins) do
		local m = mates[name]
		if not m or now - m.t > EXPIRE or not ns.db.showMates then
			if world then Pins:RemoveWorldMapIcon(Positions, p.world) end
			Pins:RemoveMinimapIcon(Positions, p.mini)
			p.world:Hide()
			p.mini:Hide()
			if not m or now - m.t > EXPIRE then mates[name] = nil end
		end
	end
	if not ns.db.showMates then return end
	for name, m in pairs(mates) do
		local p = pins[name]
		if not p then
			p = { world = Dot(9), mini = Dot(8) }
			pins[name] = p
		end
		Color(p.world, name, m.class)
		Color(p.mini, name, m.class)
		if world then Pins:AddWorldMapIconMap(Positions, p.world, m.mapID, m.x, m.y, SHOW_FLAG) end
		Pins:AddMinimapIconMap(Positions, p.mini, m.mapID, m.x, m.y, true, false)
	end
end

function Positions.Refresh()
	ns.SafeCall("positions refresh", RefreshNow)
end

function Positions.Count()
	local n, now = 0, ns.Now()
	for _, m in pairs(mates) do if now - m.t <= EXPIRE then n = n + 1 end end
	return n
end

function Positions.SetEnabled(on)
	ns.db.showMates = on and true or false
	ns.Print(ns.db.showMates and L.MATES_ON or L.MATES_OFF)
	Positions.Refresh()
end

function Positions.SetSharing(on)
	ns.db.sharePosition = on and true or false
	ns.Print(ns.db.sharePosition and L.SHARE_ON or L.SHARE_OFF)
end

ns.Comm.Handle("P1", function(dist, sender, text)
	if dist ~= "GUILD" then return end
	local p = ns.Codec.DecodePosition(text)
	if not p then return end
	p.t = ns.Now()
	mates[ns.DisplayName(sender)] = p
end)

ns.On("LOGIN", function()
	if not Pins then return end
	ns.Every(5, "positions", function()
		SendPosition()
		Positions.Refresh()
	end)
end)
