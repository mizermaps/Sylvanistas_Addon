local ADDON, ns = ...
local L = ns.L

-- Party invites (Sylvanistas): a leader gathers a party of guildmates who are solo in the same
-- zone and said yes to it, with one click; officers can gather the whole zone; anyone can send a
-- Party Scream that solo players in the zone answer with one click.
--
-- Who is free: each player who said yes tells the guild, over GUILD alone (the server stamps the
-- sender, and our roster vouches for them), that they are solo in a zone, and says so again when
-- that changes. Nobody who said no, or never answered, sends or receives anything of it.
--   PA~1~<mapID>~<zoneUID>~<level>~<class>   I'm solo here and take party invites (GUILD)
--   PA~0                                     not any more (GUILD)
--   PI~<id>                                  an invite from me is coming (WHISPER, leader -> player)
--   PS~<id>~<mapID>~<note>                   a Party Scream: forming a party here (GUILD)
--   PQ~<id>                                  please invite me (WHISPER, player -> screamer)
-- The invitee's addon joins on its own only with auto-join on, only for an invite a guildmate
-- announced with PI just before, never during a layer hop of its own (Hop.lua handles those), and
-- never with the gamepad UI (the game's own invite window answers there). Nobody is invited in an
-- instance, in combat or while Busy, nor while already in a group.

local Party = {}
ns.Party = Party

Party.ANNOUNCE_EVERY = 60  -- an available player repeats "free here" this often
Party.FRESH = 150          -- an announcement counts this long
Party.INVITE_GAP = 1.5     -- seconds between two invites
Party.NOTICE_FOR = 30      -- an invite notice lets auto-join take the invite this long
Party.SCREAM_GAP = 120     -- one Party Scream per player this often
Party.SCREAM_FOR = 300     -- a Party Scream can be answered this long
Party.MAX_PARTY = 5
Party.MAX_RAID = 40
Party.PENDING_FOR = 60      -- an invite not answered counts as a place this long
Party.WAIT_RAID_FOR = 90    -- a zone gather waits this long for someone to accept before it gives up
local HEALERS = { PRIEST = true, DRUID = true, SHAMAN = true, PALADIN = true }

local avail = {}     -- [Name-Realm] = { mapID, zoneUID, level, class, t }
local notices = {}   -- [Name-Realm] = t: that guildmate announced an invite to us
local queue = {}     -- names still to invite, in order
local queueZone      -- true while the queue is a zone-wide gather
local running = false
local pending = {}   -- [Name-Realm] = t: invited, not in the group yet (counts for PENDING_FOR)
local startedAt = -math.huge
local sentState, sentAt = nil, -math.huge
local lastScream = -math.huge
local myScream       -- { id, t, mapID }
local answered = {}  -- [scream id] = true: asked or shown once

local function Gold(s) return "|cffffd200" .. s .. "|r" end
local function Grey(s) return "|cff9d9d9d" .. s .. "|r" end
local function Green(s) return "|cff40ff40" .. s .. "|r" end

local function Changed() ns.Fire("BOARD_CHANGED") end

---------------------------------------------------------------------------
-- Settings: off until the player says yes (the privacy page, /syl party, the Board)
---------------------------------------------------------------------------

function Party.On() return ns.db ~= nil and ns.db.partyInvites == true end
function Party.Auto() return Party.On() and ns.db.partyAuto == true end

function Party.Set(on, quiet)
	if not ns.db then return end
	ns.db.partyInvites = on and true or false
	if not quiet then ns.Print(on and L.PARTY_ON or L.PARTY_OFF) end
	ns.SafeCall("party announce", Party.Announce, true)
	Changed()
end

function Party.SetAuto(on, quiet)
	if not ns.db then return end
	ns.db.partyAuto = on and true or false
	if not quiet then ns.Print(on and L.PARTY_AUTO_ON or L.PARTY_AUTO_OFF) end
	Changed()
end

---------------------------------------------------------------------------
-- Where we are, and whether we are free
---------------------------------------------------------------------------

local function MapID()
	return C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") or nil
end

local function ZoneUID(mapID)
	local mine = ns.Layers and ns.Layers.Mine and ns.Layers.Mine()
	if type(mine) == "table" and mine.mapID == mapID and mine.zoneUID then return tostring(mine.zoneUID) end
	return ""
end

local function ZoneName(mapID)
	local name = mapID and ns.Zones and ns.Zones.NameForKey and ns.Zones.NameForKey("m" .. mapID)
	if type(name) ~= "string" or name == "" then
		local info = mapID and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
		name = info and info.name
	end
	return name or "?"
end

local function Busy()
	if not UnitIsDND then return false end
	local ok, dnd = pcall(UnitIsDND, "player")
	return ok and dnd == true
end

local function InInstance()
	if not IsInInstance then return false end
	local inside, kind = IsInInstance()
	return inside and kind ~= "none"
end

local function InCombat() return UnitAffectingCombat and UnitAffectingCombat("player") and true or false end
local function Grouped() return IsInGroup and IsInGroup() and true or false end

-- Free for an invite: solo, not in an instance, not in combat, not Busy.
function Party.Free()
	return not Grouped() and not InInstance() and not InCombat() and not Busy()
end
-- What we tell the guild: the same without combat (a fight is short; our status would flicker).
local function Available() return not Grouped() and not InInstance() and not Busy() end

local function Guildmate(name) return ns.Roster and ns.Roster.RankOf and ns.Roster.RankOf(name) ~= nil end

---------------------------------------------------------------------------
-- Telling the guild we are free (only while the switch is on)
---------------------------------------------------------------------------

function Party.Announce(force)
	if not (ns.IsMember() and ns.Comm and ns.Comm.Send) then return end
	local mapID = MapID()
	local msg
	if Party.On() and Available() and mapID then
		local _, class = UnitClass("player")
		msg = ("PA~1~%d~%s~%d~%s"):format(mapID, ZoneUID(mapID), UnitLevel("player") or 0, class or "")
	else
		msg = "PA~0"
	end
	local now = ns.Now()
	if msg == sentState and not (msg ~= "PA~0" and now - sentAt >= Party.ANNOUNCE_EVERY) and not force then return end
	-- Never told anyone we were free: nothing to take back.
	if msg == "PA~0" and sentState == nil then sentState = msg return end
	if msg == "PA~0" and sentState == "PA~0" then return end
	sentState, sentAt = msg, now
	ns.Comm.Send("GUILD", msg, "party")
end

ns.Comm.Handle("PA", function(dist, sender, text)
	if dist ~= "GUILD" or not Guildmate(sender) then return end
	local on, mapID, zoneUID, level, class = text:match("^PA~([01])~?(%d*)~?([^~]*)~?(%d*)~?(%u*)$")
	if on == "1" and tonumber(mapID) then
		avail[sender] = { mapID = tonumber(mapID), zoneUID = zoneUID ~= "" and zoneUID or nil,
			level = tonumber(level) or 0, class = class ~= "" and class or nil, t = ns.Now() }
	else
		avail[sender] = nil
	end
	Changed()
end)

-- Already in our group (the game's check, safe for any name).
local function InMyGroup(name)
	if not (UnitInParty and Grouped()) then return false end
	local ok, yes = pcall(UnitInParty, ns.ShortName(name))
	return ok and yes and true or false
end

-- Guildmates free in this zone, best first: same layer, then closest level, a healer kept in.
function Party.Candidates(mapID)
	local now, out = ns.Now(), {}
	local myLevel = UnitLevel("player") or 0
	local myUID = ZoneUID(mapID)
	for name, a in pairs(avail) do
		if now - a.t > Party.FRESH or not Guildmate(name) then
			avail[name] = nil
		elseif a.mapID == mapID and name ~= ns.me and not InMyGroup(name) then
			out[#out + 1] = { name = name, sameLayer = myUID ~= "" and a.zoneUID == myUID, gap = math.abs((a.level or 0) - myLevel),
				healer = a.class and HEALERS[a.class] or false }
		end
	end
	table.sort(out, function(x, y)
		if x.sameLayer ~= y.sameLayer then return x.sameLayer end
		if x.gap ~= y.gap then return x.gap < y.gap end
		return x.name < y.name
	end)
	return out
end

local function KeepHealer(list, slots)
	if slots < 1 or #list <= slots then return list end
	for i = 1, slots do if list[i].healer then return list end end
	for i = slots + 1, #list do
		if list[i].healer then
			local h = table.remove(list, i)
			table.insert(list, slots, h)
			break
		end
	end
	return list
end

---------------------------------------------------------------------------
-- Inviting
---------------------------------------------------------------------------

-- Members in our group (1 alone) and whether we may invite (leader, or alone).
local function Room()
	if not Grouped() then return 1, true end
	local n = GetNumGroupMembers and GetNumGroupMembers() or 1
	local lead = UnitIsGroupLeader and UnitIsGroupLeader("player")
	if not lead and IsInRaid and IsInRaid() and UnitIsGroupAssistant then lead = UnitIsGroupAssistant("player") end
	return n, lead and true or false
end

local function Max() return (IsInRaid and IsInRaid()) and Party.MAX_RAID or Party.MAX_PARTY end

-- Invites still out (not answered, not expired), counted as places in the group.
local function Pending()
	local now, n = ns.Now(), 0
	for name, t in pairs(pending) do
		if now - t > Party.PENDING_FOR or InMyGroup(name) then pending[name] = nil else n = n + 1 end
	end
	return n
end

local function InviteNow(name)
	pending[name] = ns.Now()
	local target = ns.TellName(name)
	if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(target) elseif InviteUnit then InviteUnit(target) end
	ns.Log("party: invited %s", tostring(name))
end

local function Pump()
	if #queue == 0 then running = false return end
	local n, lead = Room()
	if not lead then queue = {} running = false return end
	if n + Pending() >= Max() then
		if queueZone and not (IsInRaid and IsInRaid()) then
			-- A raid needs a group first: wait for someone to accept, then ask the leader once.
			if not Grouped() then
				if ns.Now() - startedAt > Party.WAIT_RAID_FOR then
					ns.Print(L.PARTY_FULL) queue = {} running = false
				else
					ns.After(5, "party wait", Pump)
				end
				return
			end
			running = false
			ns.Print(L.PARTY_FULL_RAID:format(#queue))
			ns.ShowDialog("SYLVANISTAS_PARTY_RAID", tostring(#queue))
		else
			ns.Print(L.PARTY_FULL)
			queue = {} running = false
		end
		return
	end
	local name = table.remove(queue, 1)
	local id = math.random(100000, 999999)
	-- The notice first, so their addon knows this invite is ours; the invite once it has left.
	local sentOnce = false
	ns.Comm.Whisper(name, "PI~" .. id, nil, true, nil, function()
		if sentOnce then return end
		sentOnce = true
		ns.After(0.5, "party invite", function() InviteNow(name) end)
	end)
	ns.After(Party.INVITE_GAP + 1, "party next", Pump)
end

local function Start(names, zoneWide)
	for _, nm in ipairs(names) do queue[#queue + 1] = nm end
	queueZone = zoneWide and true or nil
	startedAt = ns.Now()
	if not running then running = true Pump() end
end

local function CanGather()
	if InInstance() then ns.Print(L.PARTY_NOT_HERE) return false end
	local _, lead = Room()
	if not lead then ns.Print(L.PARTY_NOT_LEADER) return false end
	if not MapID() then ns.Print(L.PARTY_NO_ZONE) return false end
	return true
end

-- One party: up to the free places, best first.
function Party.Gather()
	if not (ns.IsMember() and CanGather()) then return end
	local mapID = MapID()
	local n = Room()
	local slots = Max() - n - Pending() - #queue
	local list = KeepHealer(Party.Candidates(mapID), slots)
	if #list == 0 then return ns.Print(L.PARTY_NOBODY:format(ZoneName(mapID))) end
	local names = {}
	for i = 1, math.min(slots, #list) do names[#names + 1] = list[i].name end
	if #names == 0 then return ns.Print(L.PARTY_FULL) end
	ns.Print(L.PARTY_INVITING:format(#names, ZoneName(mapID)))
	Start(names, false)
end

-- The whole zone: officers (Dreadguard), the Dark Lady and her Dark Rangers. Past a party of
-- five, the leader is asked (a click) to turn the group into a raid, then it goes on.
function Party.CanZone()
	if not ns.IsMember() then return false end
	if ns.Roster and ns.Roster.MyRank and (ns.Roster.MyRank() or 99) <= ns.CAPTAIN_RANK then return true end
	local K = ns.King
	return K ~= nil and not K.missing and ((K.IsKing and K.IsKing()) or (K.IsHand and K.IsHand()) or (K.IsSteward and K.IsSteward())) and true or false
end

function Party.GatherZone()
	if not Party.CanZone() then return ns.Print(L.PARTY_ZONE_ONLY) end
	if not CanGather() then return end
	local mapID = MapID()
	local list = Party.Candidates(mapID)
	if #list == 0 then return ns.Print(L.PARTY_NOBODY:format(ZoneName(mapID))) end
	local names = {}
	for i = 1, math.min(#list, Party.MAX_RAID - 1) do names[i] = list[i].name end
	ns.Print(L.PARTY_INVITING:format(#names, ZoneName(mapID)))
	Start(names, true)
end

StaticPopupDialogs["SYLVANISTAS_PARTY_RAID"] = {
	text = L.PARTY_RAID_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function()
		ns.SafeCall("party raid", function()
			if C_PartyInfo and C_PartyInfo.ConvertToRaid then C_PartyInfo.ConvertToRaid() elseif ConvertToRaid then ConvertToRaid() end
			ns.After(1.5, "party resume", function() if #queue > 0 and not running then running = true Pump() end end)
		end)
	end,
	OnCancel = function() queue = {} running = false end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Being invited: auto-join (only with the switch on, only for an announced invite)
---------------------------------------------------------------------------

ns.Comm.Handle("PI", function(dist, sender, text)
	if dist ~= "WHISPER" or not Guildmate(sender) then return end
	notices[sender] = ns.Now()
end)

local function HopBusy()
	local s = ns.Hop and not ns.Hop.missing and ns.Hop.State and ns.Hop.State()
	return type(s) == "table" and (s.phase == "requested" or s.phase == "accepted")
end

function Party.OnInvite(name)
	if not Party.Auto() or HopBusy() or ns.GamepadUI() then return end
	if InInstance() or InCombat() or Busy() then return end
	local from = ns.FullName(ns.Normal(name))
	local at = notices[from]
	if not at or ns.Now() - at > Party.NOTICE_FOR or not Guildmate(from) then return end
	notices[from] = nil
	local dialog = StaticPopup_FindVisible and StaticPopup_FindVisible("PARTY_INVITE")
	if dialog then dialog.inviteAccepted = 1 end
	if AcceptGroup then AcceptGroup() end
	if StaticPopup_Hide then StaticPopup_Hide("PARTY_INVITE") end
	ns.Print(L.PARTY_JOINED:format(ns.DisplayName(from) or "?"))
end

---------------------------------------------------------------------------
-- The Party Scream: "forming a party here", answered with one click
---------------------------------------------------------------------------

function Party.Scream(note)
	if not (ns.IsMember() and CanGather()) then return end
	local now = ns.Now()
	if now - lastScream < Party.SCREAM_GAP then
		return ns.Print(L.PARTY_SCREAM_WAIT:format(math.ceil(Party.SCREAM_GAP - (now - lastScream))))
	end
	local n = Room()
	if n >= Max() then return ns.Print(L.PARTY_FULL) end
	note = tostring(note or ""):gsub("[~|\n]", ""):sub(1, 60)
	local mapID = MapID()
	local id = math.random(100000, 999999)
	lastScream, myScream = now, { id = id, t = now, mapID = mapID }
	ns.Comm.Send("GUILD", ("PS~%d~%d~%s"):format(id, mapID, note), nil, nil, true)
	ns.Print(L.PARTY_SCREAM_SENT:format(ZoneName(mapID)))
end

ns.Comm.Handle("PS", function(dist, sender, text)
	if dist ~= "GUILD" or not Guildmate(sender) or not Party.On() then return end
	local id, mapID, note = text:match("^PS~(%d+)~(%d+)~(.*)$")
	id, mapID = tonumber(id), tonumber(mapID)
	if not id or answered[id] then return end
	answered[id] = true
	if mapID ~= MapID() or not Party.Free() then return end
	local who = ns.DisplayName(sender) or "?"
	note = (note or ""):gsub("[|\n]", ""):sub(1, 60)
	local where = ZoneName(mapID)
	ns.Print(L.PARTY_SCREAM_LINE:format(who, where) .. (note ~= "" and (' "' .. note .. '"') or ""))
	if ns.PlayAlert then ns.PlayAlert("soft", "muster") end
	ns.ShowDialog("SYLVANISTAS_PARTY_SCREAM", who, where, { sender = sender, id = id })
end)

StaticPopupDialogs["SYLVANISTAS_PARTY_SCREAM"] = {
	text = L.PARTY_SCREAM_ASK,
	button1 = L.PARTY_JOIN,
	button2 = NO or "No",
	OnAccept = function(self, data)
		data = data or (self and self.data)
		if type(data) == "table" and data.sender and data.id and Party.Free() then
			ns.Comm.Whisper(data.sender, "PQ~" .. data.id, nil, true)
		end
	end,
	timeout = Party.SCREAM_FOR,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

ns.Comm.Handle("PQ", function(dist, sender, text)
	if dist ~= "WHISPER" or not Guildmate(sender) then return end
	local id = tonumber(text:match("^PQ~(%d+)$"))
	if not (id and myScream and myScream.id == id and ns.Now() - myScream.t <= Party.SCREAM_FOR) then return end
	local n, lead = Room()
	if not lead then return end
	if n + Pending() + #queue >= Max() then return ns.Print(L.PARTY_FULL) end
	Start({ sender }, false)
end)

---------------------------------------------------------------------------
-- Commands, the Board's section, the privacy page
---------------------------------------------------------------------------

function Party.Slash(rest)
	local word, more = tostring(rest or ""):match("^%s*(%S*)%s*(.-)%s*$")
	word = (word or ""):lower()
	if word == "on" then Party.Set(true)
	elseif word == "off" then Party.Set(false)
	elseif word == "gather" or word == "go" then Party.Gather()
	elseif word == "zone" then Party.GatherZone()
	elseif word == "scream" then Party.Scream(more)
	else
		ns.Print(L.PARTY_STATUS:format(Party.On() and L.PARTY_WORD_ON or L.PARTY_WORD_OFF, Party.Auto() and L.PARTY_WORD_ON or L.PARTY_WORD_OFF))
		ns.Print(L.HELP_PARTY)
	end
end

function Party.SlashAuto(rest)
	local word = tostring(rest or ""):match("^%s*(%S*)"):lower()
	if word == "on" then
		if not Party.On() then Party.Set(true, true) end
		Party.SetAuto(true)
	elseif word == "off" then Party.SetAuto(false)
	else ns.Print(L.PARTY_STATUS:format(Party.On() and L.PARTY_WORD_ON or L.PARTY_WORD_OFF, Party.Auto() and L.PARTY_WORD_ON or L.PARTY_WORD_OFF)) end
end

-- The Board's section (Board.Lines): the switches, then the leader's buttons.
function Party.Section(lines, q)
	if q or not ns.IsMember() then return end
	lines[#lines + 1] = { header = true, text = L.PARTY_HEADER,
		tooltip = function(tt) tt:AddLine(L.PARTY_HEADER, 1, 0.82, 0); tt:AddLine(L.PARTY_HEADER_TIP, 1, 1, 1, true) end }
	local on = Party.On()
	lines[#lines + 1] = { indent = 1, text = (on and Green or Grey)(L.PARTY_TOGGLE:format(on and L.PARTY_WORD_ON or L.PARTY_WORD_OFF)),
		onClick = function() Party.Set(not Party.On()) end,
		tooltip = function(tt) tt:AddLine(L.PARTY_TOGGLE_TIP, 1, 1, 1, true) end }
	if on then
		local auto = Party.Auto()
		lines[#lines + 1] = { indent = 2, text = (auto and Green or Grey)(L.PARTY_AUTO_TOGGLE:format(auto and L.PARTY_WORD_ON or L.PARTY_WORD_OFF)),
			onClick = function() Party.SetAuto(not Party.Auto()) end,
			tooltip = function(tt) tt:AddLine(L.PARTY_AUTO_TIP, 1, 1, 1, true) end }
	end
	local mapID = MapID()
	local free = mapID and #Party.Candidates(mapID) or 0
	lines[#lines + 1] = { indent = 1, text = Gold("> " .. L.PARTY_GATHER), right = Grey(L.PARTY_FREE_HERE:format(free)),
		onClick = function() Party.Gather() end,
		tooltip = function(tt) tt:AddLine(L.PARTY_GATHER, 1, 0.82, 0); tt:AddLine(L.PARTY_GATHER_TIP, 1, 1, 1, true) end }
	lines[#lines + 1] = { indent = 1, text = Gold("> " .. L.PARTY_SCREAM),
		onClick = function() Party.Scream("") end,
		tooltip = function(tt) tt:AddLine(L.PARTY_SCREAM, 1, 0.82, 0); tt:AddLine(L.PARTY_SCREAM_TIP, 1, 1, 1, true) end }
	if Party.CanZone() then
		lines[#lines + 1] = { indent = 1, text = Gold("> " .. L.PARTY_ZONE),
			onClick = function() Party.GatherZone() end,
			tooltip = function(tt) tt:AddLine(L.PARTY_ZONE, 1, 0.82, 0); tt:AddLine(L.PARTY_ZONE_TIP, 1, 1, 1, true) end }
	end
	lines[#lines].gapAfter = true
end

if ns.Consent and not ns.Consent.missing and ns.Consent.Register then
	ns.Consent.Register({ key = "party", label = "PARTY_CONSENT", text = "PARTY_CONSENT_TEXT",
		shown = function() return ns.IsMember() end,
		get = function() return ns.db and ns.db.partyInvites end,
		set = function(on) Party.Set(on, true) end })
	ns.Consent.Register({ key = "partyauto", label = "PARTY_AUTO_CONSENT", text = "PARTY_AUTO_CONSENT_TEXT",
		shown = function() return ns.IsMember() and Party.On() end,
		get = function() return ns.db and ns.db.partyAuto end,
		set = function(on) Party.SetAuto(on, true) end,
		pending = function() return ns.IsMember() and Party.On() and ns.db and ns.db.partyAuto == nil end })
end

---------------------------------------------------------------------------
-- Upkeep
---------------------------------------------------------------------------

function Party.Tick()
	if not ns.IsMember() then return end
	Party.Announce(false)
	local now = ns.Now()
	for name, t in pairs(notices) do if now - t > Party.NOTICE_FOR then notices[name] = nil end end
	for name, a in pairs(avail) do if now - a.t > Party.FRESH then avail[name] = nil end end
end

ns.RegisterEvent("PARTY_INVITE_REQUEST", function(name) Party.OnInvite(name) end)
ns.On("LOGIN", function()
	ns.Every(15, "party", Party.Tick)
	ns.RegisterEvent("GROUP_ROSTER_UPDATE", function() ns.SafeCall("party announce", Party.Announce, false) end)
	ns.RegisterEvent("ZONE_CHANGED_NEW_AREA", function() ns.After(3, "party zone", function() Party.Announce(false) end) end)
end)
