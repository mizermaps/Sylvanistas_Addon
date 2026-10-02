local ADDON, ns = ...
local L = ns.L

-- Royal decrees sent to every Sylvanistas guild over SylvanistasNet:
--   ARMS   "Call to Arms!"  (Horde attacking here) - raid warning + sound, marker for 5 min
--   MUSTER "Muster here"    (gather point)          - softer alert, marker for 30 min
-- Only Captains (rank <= ns.CAPTAIN_RANK) can send, and the King's Steward (1.0.0). Receivers
-- rate-limit per sender and, for senders only the census vouches for, the whole army (the
-- flood guard). A decree's words are its sender's own text: sent with the logged API (1.0.0),
-- like a chat line.

local Decree = {}
ns.Decree = Decree

local Pins = ns.Pins()
local SHOW_FLAG = HBD_PINS_WORLDMAP_SHOW_CONTINENT or 2
local DURATION = { ARMS = 5 * 60, MUSTER = 30 * 60, ROYAL = 60 * 60, HERALDRY = 60 * 60 }
local CROWN_ONLY = { ROYAL = true, HERALDRY = true }
Decree.CROWN_ONLY = CROWN_ONLY
local SEND_COOLDOWN = 60
local PER_SENDER_COOLDOWN = 60
local MAX_PER_MINUTE = 6

local active = {}          -- list of decrees
local lastSent = 0
local lastBySender = {}
local recent = {}          -- timestamps of accepted decrees (flood guard)

local function Where()
	local mapID = C_Map.GetBestMapForUnit("player")
	local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
	if not pos then return nil end
	local x, y = pos:GetXY()
	return mapID, x, y
end

local LABEL = { ARMS = "ARMS", MUSTER = "MUSTER", ROYAL = "ROYAL", HERALDRY = "HERALDRY_CALL" }
-- Each decree's sound switch (1.1, ns.SOUND_KINDS): the Tabard inspection goes with the Royal decree.
local SOUND = { ARMS = "arms", MUSTER = "muster", ROYAL = "royal", HERALDRY = "royal" }
Decree.SOUND = SOUND
local ICONS = {
	ARMS = "Interface\\Icons\\Ability_Warrior_WarCry",
	MUSTER = "Interface\\Icons\\INV_Misc_Horn_01",
	ROYAL = "Interface\\AddOns\\Sylvanistas\\media\\logo64",
	HERALDRY = "Interface\\Icons\\INV_Shirt_GuildTabard_01",
}
local function Label(d)
	return L[LABEL[d.kind] or "MUSTER"]
end
Decree.Label = Label

local function PinEnter(self)
	local d = self.decree
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(Label(d), 1, 0.25, 0.25)
	if d.text ~= "" then GameTooltip:AddLine(Decree.Words(d), 1, 1, 1, true) end
	GameTooltip:AddLine(L.DECREE_BY:format(d.sender, d.guild ~= "" and d.guild or "?", ns.Ago(d.t)), 0.7, 0.7, 0.7)
	GameTooltip:Show()
end

-- On the world map a decree is a round icon in a disc of its colour, beside the zone circles
-- rather than over their numbers (1.0.0, Map.Badge; a square of 34 before). An expired decree's
-- icon waits for the next one.
Decree.BADGE = 20
local COLORS = { ARMS = { 1, 0.25, 0.2 }, MUSTER = { 1, 0.8, 0.2 }, ROYAL = { 0.9, 0.76, 0.36 }, HERALDRY = { 0.35, 0.6, 1 } }
local spare = {}

local function MakePin(d)
	local f = table.remove(spare) or ns.Map.Badge(Decree.BADGE, true)
	local c = COLORS[d.kind] or COLORS.MUSTER
	ns.Map.SetBadge(f, ICONS[d.kind] or ICONS.MUSTER, c[1], c[2], c[3])
	f.badge.decree, f.since = d, d.t -- (the newest are laid out first: Map.BADGE_MAX)
	f.badge:SetScript("OnEnter", PinEnter)
	f.badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return f
end

-- A decree's words as they show: the player's block terms hide them until a click on the Decrees
-- tab shows them (1.1, #31); the decree itself, its alarm and its marker stay.
function Decree.Words(d)
	if d.hidden and not d.revealed then return ns.L.FILTER_WORDS_HIDDEN_SHORT end
	return d.text or ""
end

-- own: sent or previewed here (the player's click): shown in an instance too. Anyone else's
-- waits there, and on Busy (1.1, ns.Alert): its chat line and its line on the Decrees tab now,
-- its raid warning once the player is out, if it has not expired by then.
local function Show(d, own)
	d.expires = d.t + DURATION[d.kind]
	table.insert(active, 1, d)
	local zone = ns.Zones.NameForKey("m" .. d.mapID)
	local text = ("%s %s%s"):format(Label(d), zone, d.text ~= "" and (" - " .. Decree.Words(d)) or "")
	ns.Print(("|cffff4040%s|r  (%s <%s>)"):format(text, d.sender, d.guild))
	ns.Alert(SOUND[d.kind] or "muster", d.kind == "MUSTER" and "soft" or "loud", {
		text = text, color = { r = 1, g = 0.3, b = 0.1 }, own = own,
		what = ("%s (%s)"):format(L["HELP_" .. d.kind .. "_NAME"], zone),
		open = function() return ns.Now() <= d.expires end,
	})
	if Pins then d.pin = MakePin(d) end
	Decree.RefreshPins()
	ns.Log("decree %s from %s <%s> map %d", d.kind, d.sender, d.guild, d.mapID)
	ns.Fire("DECREES_CHANGED")
end

-- (Not on the world map with the gamepad UI: ns.WorldMapIcons.)
local function RefreshPinsNow()
	if not Pins then return end
	local world = ns.WorldMapIcons(Pins, Decree)
	for _, d in ipairs(active) do
		if d.pin then
			if ns.db.showDecrees then
				if world then Pins:AddWorldMapIconMap(Decree, d.pin, d.mapID, d.x, d.y, SHOW_FLAG) end
			else
				if world then Pins:RemoveWorldMapIcon(Decree, d.pin) end
				d.pin:Hide()
			end
		end
	end
end

function Decree.RefreshPins()
	ns.SafeCall("decree pins", RefreshPinsNow)
end

-- The King's Steward (1.0.0, King.IsSteward: the signed titles list marks him) sends the Crown's
-- decrees for the King's guild, whatever his own rank or guild; every client takes them by his
-- name, as the King's (below).
local function Steward() return ns.King ~= nil and ns.King.IsSteward ~= nil and ns.King.IsSteward() end

function Decree.CanSend(kind)
	if Steward() then return true end
	if CROWN_ONLY[kind] then return ns.IsCrown() end
	return ns.Roster.IsOfficer()
end

function Decree.Send(kind, text)
	local steward = Steward()
	if not steward and not ns.IsMember() then
		ns.Print(L.MEMBERS_ONLY)
		return
	end
	if not steward and CROWN_ONLY[kind] and not ns.IsCrown() then
		ns.Print(L.CROWN_ONLY)
		return
	end
	if not steward and not ns.Roster.IsOfficer() then
		ns.Print(L.DECREE_OFFICERS_ONLY)
		return
	end
	-- 1.1: the moderators took this character off (net-off, Moderation.lua): nobody would see it.
	local off = ns.Moderation.SelfOff and ns.Moderation.SelfOff()
	if off then
		ns.Print(ns.Moderation.YouText(off))
		return
	end
	local now = ns.Now()
	if now - lastSent < SEND_COOLDOWN then
		ns.Print(L.DECREE_COOLDOWN:format(SEND_COOLDOWN - (now - lastSent)))
		return
	end
	local mapID, x, y = Where()
	if not mapID then
		ns.Print(L.DECREE_NO_POSITION)
		return
	end
	lastSent = now
	local guild = steward and ns.KingGuildName() or GetGuildInfo("player") or ""
	local rank = steward and 0 or ns.Roster.MyRank()
	-- Logged (1.0.0): the server keeps its words, so abuse can be reported (Comm.Send).
	ns.Comm.Send("CHANNEL", ns.Codec.EncodeDecree(kind, mapID, x, y, guild, rank, text), nil, nil, true)
	-- 1.1 (#12): our own decree never comes back to us: in our log as we send it.
	ns.Chronicle.Add("decree", ns.me, Label({ kind = kind }) .. " " .. ns.Zones.NameForKey("m" .. mapID), { words = text })
	Show({ kind = kind, mapID = mapID, x = x, y = y, guild = guild, rank = rank, text = text or "", sender = ns.DisplayName(ns.me), t = now }, true)
end

-- Local-only preview so anyone can see what a decree looks like (nothing is sent).
function Decree.Preview(kind)
	local mapID, x, y = Where()
	if not mapID then return end
	Show({ kind = kind, mapID = mapID, x = x, y = y, guild = GetGuildInfo("player") or "Sylvanistas", rank = 0,
		text = L.DECREE_PREVIEW_TEXT, sender = ns.DisplayName(ns.me), t = ns.Now() }, true)
end

-- The 15 s expiry timer also follows a switch of the interface style without a /reload: to the
-- gamepad UI, the decrees leave the world map at once (not 5 to 60 minutes later, when they
-- expire); back to mouse and keyboard, they return.
local lastWorld
function Decree.Active()
	local now, out = ns.Now(), {}
	local world = Pins and ns.WorldMapIcons(Pins, Decree)
	if Pins and lastWorld == false and world then RefreshPinsNow() end
	lastWorld = world
	for i = #active, 1, -1 do
		local d = active[i]
		if now > d.expires then
			if Pins and d.pin then
				if world then Pins:RemoveWorldMapIcon(Decree, d.pin) end
				d.pin:Hide()
				spare[#spare + 1], d.pin = d.pin, nil
			end
			table.remove(active, i)
		end
	end
	for _, d in ipairs(active) do out[#out + 1] = d end
	return out
end

ns.Comm.Handle("D1", function(dist, sender, text)
	if dist ~= "CHANNEL" then return end
	local d = ns.Codec.DecodeDecree(text)
	if not d or not ns.IsFederation(d.guild) then return end
	-- 1.1: a name the moderators took off (net-off, Moderation.lua).
	if ns.Moderation.Hides and ns.Moderation.Hides(sender, d.guild) then
		return ns.Log("decree from %s ignored: net-off", sender)
	end
	-- The King by his pinned name (the server stamps it), never by a vote: his decree needs no
	-- census. So do his Hands' for his guild (his list or a Steward's, King.IsHandName), on every
	-- client outside it: there they are of his Crown on his word (1.0.0); on its own members'
	-- clients its roster says who speaks for it. His Steward's (1.0.0: the signed titles list
	-- names him, King.IsStewardName) on every client, as the King's. Everyone else: the rank we
	-- can verify, never the rank written in the message.
	local mine = GetGuildInfo("player")
	local kings = ns.IsKingGuild(d.guild)
	local king = kings and ns.IsKingCharacter(sender)
	local steward = kings and not king and ns.King ~= nil and ns.King.IsStewardName(sender)
	local hand = kings and not king and not steward and not ns.IsKingGuild(mine) and ns.King ~= nil and ns.King.IsHandName(sender)
	local rank = (king or steward or hand) and 0 or ns.Data.KnownRank(sender, d.guild)
	if not rank then
		ns.Log("decree from %s ignored: rank in %s not verified", sender, d.guild)
		return
	end
	d.rank = rank
	if CROWN_ONLY[d.kind] then
		if not ns.IsCrownRank(d.guild, rank) then return end
	elseif rank > ns.CAPTAIN_RANK then
		return
	end
	-- The King, his Steward, his Hands and our own guild's officers (our roster: the server's
	-- word) never wait behind the flood guard, which census ranks (anyone's votes) can fill.
	-- Anyone else speaks for one guild only, as in the chats (Data.ClaimGuild).
	local sure = king or steward or hand or (mine ~= nil and d.guild == mine and ns.Roster.RankOf(sender) ~= nil)
	if not sure and not ns.Data.ClaimGuild(sender, d.guild) then
		ns.Log("decree from %s ignored: speaks for another guild than %s", sender, d.guild)
		return
	end
	local now = ns.Now()
	if lastBySender[sender] and now - lastBySender[sender] < PER_SENDER_COOLDOWN then return end
	for i = #recent, 1, -1 do if now - recent[i] > 60 then table.remove(recent, i) end end
	if #recent >= MAX_PER_MINUTE and not sure then return end
	lastBySender[sender] = now
	if not sure then recent[#recent + 1] = now end
	-- Its words come through the logged API (the server keeps them, so abuse can be reported),
	-- as a chat line's do. One sent with the plain API, where this client has both (a sender
	-- before 1.0.0, or edited code), still shows, without its words (1.0.0).
	if d.text ~= "" and C_ChatInfo and C_ChatInfo.SendAddonMessageLogged and ns.Comm.DeliveredLogged
		and not ns.Comm.DeliveredLogged() then
		ns.Log("decree from %s shown without its text: not sent with the logged API", sender)
		d.text = ""
	end
	d.sender, d.t = ns.DisplayName(sender), now
	-- 1.1 (#31): its words hidden when the player's block terms hit them (Filter.lua).
	local F = ns.Filter
	if d.text ~= "" and F and not F.missing and F.Hides(d.text) then d.hidden = true end
	-- 1.1 (#12): in this client's log of acts, with the name the server stamped.
	ns.Chronicle.Add("decree", sender, Label(d) .. " " .. ns.Zones.NameForKey("m" .. d.mapID), { words = d.text })
	Show(d)
end)

ns.On("LOGIN", function()
	ns.Every(15, "decree expiry", function()
		local before = #active
		Decree.Active()
		if #active ~= before then ns.Fire("DECREES_CHANGED") end
	end)
end)
