local ADDON, ns = ...
local L = ns.L

-- Layer hop: instead of begging in chat for an invite to someone's layer, a player asks the
-- addon. The ask goes out on the Sylvanistas channel with the layer wanted (a zone and the zone
-- UID read from NPC GUIDs, see Layers.lua). Players on that layer who can invite answer the
-- asker alone, each only with a chance scaled to how many are there, so a crowded layer sends
-- a handful of offers instead of hundreds. The asker draws one at random, favouring players
-- outside a group and with fewer recent invites, so many askers spread over many helpers.
-- That helper gets "X wants to join your layer" (or invites at once, if they chose that) and
-- says no when they can't; no answer or a no, the asker tries the next offer. The invite is
-- accepted for the asker when the helper is one the addon can vouch for (Hop.Trusted), never
-- with the gamepad UI (the game's invite window and the player's click otherwise), the game
-- moves them to the helper's layer, and their addon takes them out of the group once it sees
-- the move. The main use: joining the King's layer while he is online. Players alone on his
-- layer are asked once whether the addon may do all of it for them (invite, and let the guest
-- go after a while: the guest's addon leaves, since only a click may remove someone from a
-- group).
--   LQ~<id>~<mapID>~<zoneUID>    (channel) who on this layer can invite me?
--   LO~<id>~<group>~<load>       (whisper) I can: my group size (0 = none), my recent invites
--   LR~<id>                      (whisper) please invite me
--   LN~<id>                      (whisper) I can't now
--   LX~<id>                      (whisper) your time in my group is up: please leave it

local Hop = {}
ns.Hop = Hop

Hop.OFFERS = 6          -- offers wanted per ask, however crowded the layer
Hop.WINDOW = 3          -- seconds the asker collects offers before choosing
Hop.NOBODY = 15         -- no offer at all this long after the ask: nobody can
Hop.WAIT = 30           -- seconds a chosen helper has to invite (their window closes at 20)
Hop.POPUP_TIME = 20     -- the helper's window
Hop.ACCEPT_WAIT = 15    -- invite accepted, and no group this long after: next helper
Hop.TRIES = 3           -- helpers asked in turn before giving up
Hop.ASK_GAP = 20        -- one ask every 20 seconds
Hop.BACKOFF = { 20, 60, 180 } -- after 1, 2, 3+ asks in a row that found nobody or got no invite:
                        -- seconds from the last of them to the next ask
Hop.BACKOFF_RESET = 600 -- ...forgotten after this long
Hop.BRAKE_WINDOW = 10   -- asks heard for one layer in this many seconds...
Hop.BRAKE_ASKS = 10     -- ...from more askers than this: our own ask waits a little
Hop.JOIN_WAIT = 20      -- in the group this long without seeing the move: offer to leave anyway
Hop.HELP_GAP = 60       -- the same asker is answered once a minute
Hop.OFFER_GAP = 10      -- a helper offers once every 10 seconds at most
Hop.DECLINES = 2        -- after this many Not now / no answer in a row...
Hop.PAUSE = 300         -- ...no requests for 5 minutes
Hop.LAYER_FRESH = 600   -- our layer counts this long after the last NPC seen
Hop.RECENT = 600        -- invites counted in the load we announce
Hop.MAX_OFFERS = 30     -- offers kept per ask
Hop.GUEST_TIME = 90     -- a guest the addon invited on its own is let go after this long
Hop.PROMPT_EVERY = 10   -- how often we check whether we are alone on the King's layer

-- Swappable in tests.
Hop.random = math.random
Hop.after = function(seconds, where, fn) ns.After(seconds, where, fn) end

local ask             -- our own request in progress
local lastAsk = -math.huge
local fails, failedAt = 0, -math.huge -- our asks in a row that found nobody or got no invite
-- Asks heard on the channel for BRAKE_WINDOW, per layer and asker: { ["mapID:zoneUID"] = { [short] = t } }.
local heard = {}
-- Askers are keyed by short name: the channel and whispers may not both carry the realm.
local offered = {}    -- [id .. asker] = t: offers we sent (a request must match one)
local answeredAt = {} -- [asker] = t
local lastOffer, declines, pausedUntil = -math.huge, 0, -math.huge
local pending         -- the request on screen: { from, id, t }
local recent = {}     -- times of our last invites
local stats = { asks = 0, offers = 0, requests = 0, invites = 0, noes = 0, joins = 0, moves = 0, releases = 0 }
local guests = {}     -- [short name] = { name, id, t, release }: players we invited for a hop
local kingMode        -- this session's answer to the King's layer window: auto, manual or no
local promptShown, lastPromptCheck = false, -math.huge
local privateHinted = false -- told this session what an ask says while the player shares nothing

local function Changed() ns.Fire("HOP_CHANGED") end

---------------------------------------------------------------------------
-- Helping: who can invite
---------------------------------------------------------------------------

-- Group size (0 = none) and whether we can invite one more: alone, or the leader (or an
-- assistant of a raid) with a free seat. A full party can't: making it a raid is a click.
function Hop.GroupState()
	if not (IsInGroup and IsInGroup()) then return 0, true end
	local n = GetNumGroupMembers and GetNumGroupMembers() or 1
	local raid = IsInRaid and IsInRaid()
	local lead = UnitIsGroupLeader and UnitIsGroupLeader("player")
	if not lead and raid and UnitIsGroupAssistant then lead = UnitIsGroupAssistant("player") end
	return n, (lead and n < (raid and 40 or 5)) and true or false
end

local function Load()
	local now, n = ns.Now(), 0
	for i = #recent, 1, -1 do
		if now - recent[i] > Hop.RECENT then table.remove(recent, i) else n = n + 1 end
	end
	return n
end

-- The answer to the King's layer window: this session's, else the one kept with "Don't ask
-- me again" (auto, manual or no), else nil.
local function KingChoice() return kingMode or ns.db.hopKingChoice end

-- We are on the King's layer (Hop.King below).
local function OnKingLayer(strict)
	local k = Hop.King(strict)
	local mine = ns.Layers.Mine()
	return (k and k.zoneUID and mine and mine.mapID == k.mapID and mine.zoneUID == k.zoneUID) and true or false
end

-- The short names of the others in our group.
local function GroupNames()
	local out = {}
	if not (IsInGroup and IsInGroup()) then return out end
	local raid = IsInRaid and IsInRaid()
	local n = raid and (GetNumGroupMembers and GetNumGroupMembers() or 0) or 4
	for i = 1, n do
		local name = ns.UnitFullName((raid and "raid" or "party") .. i)
		if name then out[ns.ShortName(name)] = true end
	end
	out[ns.ShortName(ns.me or "")] = nil
	return out
end

-- Alone, or in a party of our hop guests only: the addon may invite on its own. Never into a
-- group of the player's friends.
local function OnlyGuests()
	if not (IsInGroup and IsInGroup()) then return true end
	if IsInRaid and IsInRaid() then return false end
	for short in pairs(GroupNames()) do
		if not guests[short] then return false end
	end
	return true
end

-- Everyone who shares their layer helps once they said yes to it (1.1, Fern's #11: the
-- first-open page, or /syl layerhelp on; nil, never answered, is off). Not the King: he is the
-- one everybody wants, and his screen is on stream.
function Hop.Helps() return ns.db ~= nil and ns.db.layerHelp == true end
function Hop.CanHelp(mapID, zoneUID)
	if not Hop.Helps() or not ns.IsMember() then return false end
	-- An offer tells the asker we are on that layer: only for players who share theirs (0.9.2).
	if not ns.Layers.Sharing() then return false end
	if ns.King and ns.King.IsKing and ns.King.IsKing() then return false end
	local mine = ns.Layers.Mine()
	if not mine or mine.mapID ~= mapID or mine.zoneUID ~= zoneUID then return false end
	if ns.Now() - (mine.t or 0) > Hop.LAYER_FRESH then return false end
	-- "Can't right now" on the King's layer window.
	if KingChoice() == "no" and OnKingLayer() then return false end
	if (IsInInstance and IsInInstance()) or (InCombatLockdown and InCombatLockdown()) then return false end
	if pending or (ask and ask.phase ~= "done") then return false end
	if ns.Now() < pausedUntil then return false end
	local _, room = Hop.GroupState()
	return room
end

-- The chance to answer, so a crowded layer sends about OFFERS offers in all. Layers.lua sees
-- the officers and a 1 in 8 sample, so the crowd is a few times what it counts.
-- The census helps when the sample saw few (right after login, a quiet channel): the addon
-- users in the zone (each fresh, undisputed guild's members there, times its share of addon
-- users), shared by at least two layers. It may only lower the chance a little (at most
-- CENSUS_REACH times the sample's crowd, plus a few): too many offers cost a few whispers,
-- too few leave the asker with nobody, and one false report must not silence a zone.
Hop.CENSUS_REACH = 2
function Hop.Chance(mapID, zoneUID)
	local count, layers = 1, 0
	for _, layer in ipairs(ns.Layers.ForMap(mapID)) do
		layers = layers + 1
		if layer.zoneUID == zoneUID then count = layer.count end
	end
	local crowd = count * 4
	local users = 0
	local s = ns.Data and ns.Data.Summary and ns.Data.Summary()
	for _, e in ipairs(s and s.guilds or {}) do
		local g = e.g
		local here = e.fresh and not g.conflict and g.zones and g.zones["m" .. tostring(mapID)]
		if here and (g.online or 0) > 0 then users = users + here * math.min(1, (g.users or 0) / g.online) end
	end
	if users > 0 then
		local census = users / math.max(2, layers)
		crowd = math.max(crowd, math.min(census, crowd * Hop.CENSUS_REACH + 8))
	end
	return math.min(1, Hop.OFFERS / math.max(1, crowd))
end

function Hop.HandleAsk(dist, sender, text)
	if dist ~= "CHANNEL" then return end
	local id, mapID, zoneUID = text:match("^LQ~(%d+)~(%d+)~(%d+)$")
	id, mapID, zoneUID = tonumber(id), tonumber(mapID), tonumber(zoneUID)
	if not id then return end
	sender = ns.FullName(sender)
	-- 1.1: a name the moderators took off (net-off, Moderation.lua) gets no offer.
	if ns.Moderation.Hides and ns.Moderation.Hides(sender) then return end
	local short = ns.ShortName(sender)
	local now = ns.Now()
	Hop.Hear(mapID, zoneUID, short, now)
	if now - (answeredAt[short] or -math.huge) < Hop.HELP_GAP then return end
	if now - lastOffer < Hop.OFFER_GAP then return end
	if not Hop.CanHelp(mapID, zoneUID) then return end
	-- Few announce their layer since sharing is a choice (0.9.1), so Chance can think a busy
	-- layer empty: with several askers at once, each ask takes a share of the helpers, not all.
	local chance = Hop.Chance(mapID, zoneUID)
	local asking = Hop.Crowd(mapID, zoneUID, now)
	if asking > 1 then chance = math.min(chance, math.max(1 / asking, 0.1)) end
	if Hop.random() > chance then return end
	answeredAt[short] = now
	offered[id .. short] = now
	lastOffer = now
	local group = Hop.GroupState()
	local load = Load()
	-- A random pause spreads the offers of a crowd over a couple of seconds.
	Hop.after(0.2 + Hop.random() * 2.3, "hop offer", function()
		ns.Comm.Whisper(sender, ("LO~%d~%d~%d"):format(id, group, load), nil, true)
		stats.offers = stats.offers + 1
	end)
end

-- release: the addon lets the guest go after GUEST_TIME (the helper chose that).
local function Invite(name, id, release)
	local target = ns.TellName(name)
	if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(target) elseif InviteUnit then InviteUnit(target) end
	guests[ns.ShortName(name)] = { name = name, id = id or 0, t = ns.Now(), release = release and true or false }
	recent[#recent + 1] = ns.Now()
	stats.invites = stats.invites + 1
	ns.Print(L.HOP_INVITING:format(target))
	ns.Log("hop: invited %s", tostring(name))
end

local function SayNo(name, id)
	ns.Comm.Whisper(name, ("LN~%d"):format(id), nil, true)
	stats.noes = stats.noes + 1
end

-- A request answers one of our offers (anything else is ignored).
function Hop.HandleRequest(dist, sender, text)
	if dist ~= "WHISPER" then return end
	local id = tonumber(text:match("^LR~(%d+)$"))
	sender = ns.FullName(sender)
	if ns.Moderation.Hides and ns.Moderation.Hides(sender) then return end -- (1.1: net-off)
	local key = id and (id .. ns.ShortName(sender))
	local at = key and offered[key]
	if not at or ns.Now() - at > 120 then return end
	offered[key] = nil
	stats.requests = stats.requests + 1
	local _, room = Hop.GroupState()
	if not room or pending or (InCombatLockdown and InCombatLockdown()) then return SayNo(sender, id) end
	-- On its own ("Always invite", or "For Sylvanistas!" on the King's layer): only while we are
	-- alone or with hop guests; in a group of our own we get the window.
	-- "For Sylvanistas!" invites on its own only for a King two reports confirm.
	local auto = ns.db.layerAutoInvite or (KingChoice() == "auto" and OnKingLayer(true))
	if auto and OnlyGuests() then return Invite(sender, id, true) end
	pending = { from = sender, id = id, t = ns.Now() }
	-- In an instance or on Busy (1.1, ns.Alert): no sound and no window; they come once the player
	-- is out, while the asker still waits (Hop.WAIT), else the request only lapses.
	local ask = pending
	ns.Alert("hop", "soft", { what = L.HELD_HOP:format(ns.DisplayName(sender)), key = "hop:" .. id,
		open = function() return pending == ask and ns.Now() - ask.t <= Hop.WAIT end,
		show = function() if pending == ask then ns.ShowDialog("SYLVANISTAS_HOP_REQUEST", ns.DisplayName(sender), nil, ask) end end })
	Changed()
end

local function Answer(data, invite, always)
	if not data or pending ~= data then return end
	pending = nil
	if always then
		ns.db.layerAutoInvite = true
		ns.Print(L.HOP_AUTO_ON)
	end
	if invite then
		declines = 0
		Invite(data.from, data.id, always)
	else
		SayNo(data.from, data.id)
		-- Not now (or no answer) twice in a row: a break from requests.
		declines = declines + 1
		if declines >= Hop.DECLINES then
			declines = 0
			pausedUntil = ns.Now() + Hop.PAUSE
		end
	end
	Changed()
end
Hop.Answer = Answer

StaticPopupDialogs["SYLVANISTAS_HOP_REQUEST"] = {
	text = L.HOP_REQUEST,
	button1 = L.HOP_INVITE,
	button2 = L.HOP_NOT_NOW,
	button3 = L.HOP_ALWAYS,
	OnAccept = function(self, data) ns.SafeCall("hop invite", Answer, data or self.data, true) end,
	OnAlt = function(self, data) ns.SafeCall("hop invite", Answer, data or self.data, true, true) end,
	-- Not now, Escape or the timeout: the asker moves on to someone else.
	OnCancel = function(self, data) ns.SafeCall("hop no", Answer, data or self.data, false) end,
	timeout = Hop.POPUP_TIME,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Asking
---------------------------------------------------------------------------

-- fromPopup: called from the leave window's own buttons (it closes itself).
local function Finish(message, fromPopup)
	if not ask then return end
	if not fromPopup and ask.leaveShown then ns.HideDialog("SYLVANISTAS_HOP_LEAVE", ask) end
	ask.phase = "done"
	if message then ns.Print(message) end
	Changed()
end

-- Seconds before we may ask again: ASK_GAP after an ask, and after asks in a row that found
-- nobody or got no invite, longer each time (BACKOFF), so a player clicking a layer where
-- nobody can help doesn't ask the whole channel every 20 seconds.
function Hop.WaitLeft(now)
	now = now or ns.Now()
	if fails > 0 and now - failedAt > Hop.BACKOFF_RESET then fails = 0 end
	local left = Hop.ASK_GAP - (now - lastAsk)
	if fails > 0 then left = math.max(left, Hop.BACKOFF[math.min(fails, #Hop.BACKOFF)] - (now - failedAt)) end
	return math.max(0, left)
end

-- The ask ended with nobody (no offer at all) or no invite: the next one waits longer.
local function Failed(nobody)
	-- Nobody free because a crowd asks for that layer too: not ours to wait longer for.
	local crowded = ask and Hop.Crowd(ask.mapID, ask.zoneUID, ns.Now()) > Hop.BRAKE_ASKS
	if not crowded then fails, failedAt = fails + 1, ns.Now() end
	Finish((nobody and L.HOP_NOBODY_WAIT or L.HOP_GAVE_UP_WAIT):format(math.ceil(Hop.WaitLeft())))
end

-- An ask heard on the channel (HandleAsk), counted once per asker.
function Hop.Hear(mapID, zoneUID, short, now)
	local key = mapID .. ":" .. zoneUID
	local askers = heard[key] or {}
	heard[key] = askers
	local n = 0
	for _ in pairs(askers) do n = n + 1 end
	if n < Hop.BRAKE_ASKS * 4 or askers[short] then askers[short] = now end -- (enough to know it is a crowd)
end

-- How many asked for this layer in the last BRAKE_WINDOW.
function Hop.Crowd(mapID, zoneUID, now)
	local n = 0
	for _, t in pairs(heard[mapID .. ":" .. zoneUID] or {}) do
		if now - t <= Hop.BRAKE_WINDOW then n = n + 1 end
	end
	return n
end

-- Weighted draw: outside a group counts double, fewer recent invites counts more. Each asker
-- draws on its own, so a crowd of askers spreads over the helpers.
function Hop.Pick(offers, tried)
	local pool, total = {}, 0
	for name, o in pairs(offers) do
		if not tried[name] then
			local w = (o.group == 0 and 2 or 1) / (1 + o.load)
			if o.trusted then w = w * 3 end -- a helper the addon can vouch for comes first
			pool[#pool + 1] = { o = o, w = w }
			total = total + w
		end
	end
	if #pool == 0 then return nil end
	table.sort(pool, function(a, b) return a.o.name < b.o.name end)
	local r = Hop.random() * total
	for _, p in ipairs(pool) do
		r = r - p.w
		if r <= 0 then return p.o end
	end
	return pool[#pool].o
end

function Hop.Next()
	if not ask or ask.phase == "done" then return end
	local o = ask.tries < Hop.TRIES and Hop.Pick(ask.offers, ask.tried)
	if not o then return Failed(ask.tries == 0) end
	ask.tried[o.name] = true
	ask.tries = ask.tries + 1
	ask.helper, ask.phase, ask.asked = o.name, "requested", ns.Now()
	ns.Comm.Whisper(o.name, ("LR~%d"):format(ask.id), nil, true)
	ns.Print(L.HOP_REQUESTED:format(ns.DisplayName(o.name)))
	Changed()
end

-- Ask for an invite to a layer (a zone and its zone UID), named for the messages.
function Hop.Ask(mapID, zoneUID, label)
	if not ns.IsMember() then return ns.Print(L.MEMBERS_ONLY) end
	-- 1.1: the moderators took this character off (net-off, Moderation.lua): nobody would answer.
	local off = ns.Moderation.SelfOff and ns.Moderation.SelfOff()
	if off then return ns.Print(ns.Moderation.YouText(off)) end
	if not mapID or not zoneUID then return ns.Print(L.HOP_NO_LAYER) end
	-- A zone UID only means something in its zone: the player must be there already.
	if ns.Layers.CurrentMap() ~= mapID then return ns.Print(L.HOP_OTHER_MAP:format(Hop.ZoneName(mapID))) end
	local mine = ns.Layers.Mine()
	if mine and mine.mapID == mapID and mine.zoneUID == zoneUID then return ns.Print(L.HOP_ALREADY) end
	if IsInGroup and IsInGroup() then return ns.Print(L.HOP_IN_GROUP) end
	local now = ns.Now()
	if ask and ask.phase ~= "done" then return ns.Print(L.HOP_BUSY) end
	local wait = Hop.WaitLeft(now)
	if wait > 0 then return ns.Print(L.HOP_WAIT:format(math.ceil(wait))) end
	if not ns.Comm.ChannelReady() then return ns.Print(L.CHAN_NOT_READY) end
	lastAsk = now
	ask = {
		id = Hop.random(1, 99999), mapID = mapID, zoneUID = zoneUID, label = label or L.LAYER_UNKNOWN,
		t = now, phase = "asking", offers = {}, count = 0, tried = {}, tries = 0,
		from = mine and { mapID = mine.mapID, zoneUID = mine.zoneUID },
	}
	stats.asks = stats.asks + 1
	-- A crowd is asking for this layer right now (the King just came online): its helpers are
	-- busy answering them, so ours goes out a few seconds later, at a random moment (Tick).
	if Hop.Crowd(mapID, zoneUID, now) > Hop.BRAKE_ASKS then
		ask.phase, ask.sendAt = "queued", now + Hop.BRAKE_WINDOW * (0.5 + Hop.random())
		ns.Print(L.HOP_CROWDED:format(math.ceil(ask.sendAt - now)))
		return Changed()
	end
	Hop.SendAsk()
end

function Hop.SendAsk()
	if not ask then return end
	local now = ns.Now()
	lastAsk, ask.t, ask.phase = now, now, "asking"
	-- Ahead of the census traffic: someone waits for an invite (Comm.Send urgent).
	ns.Comm.Send("CHANNEL", ("LQ~%d~%d~%d"):format(ask.id, ask.mapID, ask.zoneUID), nil, true)
	-- Keeping zone and layer private (Layers.Sharing): the ask still names this zone and the
	-- layer wanted, and layers are only known from the members who share theirs. Once a session.
	if not ns.Layers.Sharing() and not privateHinted then
		privateHinted = true
		ns.Print(L.HOP_PRIVATE_HINT)
	end
	ns.Print(L.HOP_ASKING:format(ask.label))
	ns.Log("hop: ask %d for map %d zoneUID %d", ask.id, ask.mapID, ask.zoneUID)
	Changed()
end

-- A helper the addon can vouch for: a guildmate (our roster), or a Lord or Captain the census
-- names. Their invite is accepted for the player; anyone else's is left to the game's invite
-- window (one click), so nobody pulls a player into their group just by answering an ask read
-- on the channel. (A layer announcement is the sender's own word: it proves nothing here.)
function Hop.Trusted(name)
	name = ns.FullName(name)
	if ns.Roster.RankOf(name) then return true end
	local short = ns.ShortName(name)
	for guild, g in pairs(ns.rdb.guilds or {}) do
		-- (1.1: never a guild the moderators took off the network, Moderation.lua.)
		if type(g) == "table" and not (ns.Data.NetOff and ns.Data.NetOff(guild)) then
			local listed = g.leader and ns.ShortName(g.leader) == short
			for _, o in ipairs(not listed and g.officers or {}) do
				if o.name and ns.ShortName(o.name) == short then listed = true break end
			end
			if listed and ns.Data.KnownRank(name, guild) then return true end
		end
	end
	return false
end

function Hop.HandleOffer(dist, sender, text)
	if dist ~= "WHISPER" or not ask or ask.phase == "done" or ask.phase == "joined" then return end
	local id, group, load = text:match("^LO~(%d+)~(%d+)~(%d+)$")
	if tonumber(id) ~= ask.id then return end
	sender = ns.FullName(sender)
	if ns.Moderation.Hides and ns.Moderation.Hides(sender) then return end -- (1.1: net-off: no offer of theirs)
	if ask.offers[sender] or ask.count >= Hop.MAX_OFFERS then return end
	ask.offers[sender] = { name = sender, group = math.min(tonumber(group), 40), load = math.min(tonumber(load), 99), t = ns.Now(),
		trusted = Hop.Trusted(sender) }
	ask.count = ask.count + 1
	Changed()
end

function Hop.HandleNo(dist, sender, text)
	if dist ~= "WHISPER" or not ask or ask.phase ~= "requested" then return end
	if tonumber(text:match("^LN~(%d+)$")) ~= ask.id or ns.ShortName(ns.FullName(sender)) ~= ns.ShortName(ask.helper) then return end
	Hop.Next()
end

-- The invite we asked for: accept it for the player (anyone else's invite is left alone).
-- A helper asked before may still invite late (after we moved on): theirs counts too.
local function AskedHelper(name)
	if not name then return nil end
	local short = ns.ShortName(name)
	for helper in pairs(ask.tried) do
		if ns.ShortName(helper) == short then return helper end
	end
	return nil
end

function Hop.OnInvite(name)
	if not ask or (ask.phase ~= "requested" and ask.phase ~= "accepted") then return end
	local helper = AskedHelper(name)
	if not helper then return end
	-- Not one the addon can vouch for (Hop.Trusted): the game's own window, the player's click.
	-- With the gamepad UI, always: the addon leaves the game's popups alone there (Dialog.lua),
	-- and the game's invite window is the one a controller answers.
	local o = ask.offers[helper]
	if not (o and o.trusted) or ns.GamepadUI() then
		-- The player decides: the wait starts over from this invite, and the group they may
		-- join counts as this helper's (OnRoster) even before the game names its members.
		ask.helper, ask.invitedBy, ask.asked = helper, helper, ns.Now()
		if ask.phase ~= "requested" then ask.phase = "requested" end
		if ask.hinted ~= helper then
			ask.hinted = helper
			ns.PlayAlert("soft", "hop")
			ns.Print(L.HOP_ACCEPT_HINT:format(ns.DisplayName(helper)))
		end
		Changed()
		return
	end
	local dialog = StaticPopup_FindVisible and StaticPopup_FindVisible("PARTY_INVITE")
	if dialog then dialog.inviteAccepted = 1 end
	if AcceptGroup then AcceptGroup() end
	if StaticPopup_Hide then StaticPopup_Hide("PARTY_INVITE") end
	ask.helper, ask.phase, ask.accepted = helper, "accepted", ns.Now()
	ns.Log("hop: accepted the invite from %s", tostring(name))
	Changed()
end

local function LeaveGroup()
	if C_PartyInfo and C_PartyInfo.LeaveParty then C_PartyInfo.LeaveParty() elseif LeaveParty then LeaveParty() end
end

-- Out of the helper's group, the hop done (a layer stays after the group is left).
local function Leave(message)
	LeaveGroup()
	Finish(message)
end

-- No move seen after a while (no NPC around): the player decides.
local function OfferLeave()
	if not ask or ask.leaveShown then return end
	ask.leaveShown = true
	ns.PlayAlert("soft", "hop")
	ns.ShowDialog("SYLVANISTAS_HOP_LEAVE", L.HOP_MAYBE_MOVED, nil, ask)
end

StaticPopupDialogs["SYLVANISTAS_HOP_LEAVE"] = {
	text = "%s",
	button1 = L.HOP_LEAVE,
	button2 = L.HOP_STAY,
	-- Only for the ask it was shown for (data): an old window never ends a new ask.
	OnAccept = function(self, data)
		ns.SafeCall("hop leave", function()
			if (data or (self and self.data)) ~= ask then return end
			LeaveGroup()
			Finish(L.HOP_DONE, true)
		end)
	end,
	OnCancel = function(self, data)
		ns.SafeCall("hop stay", function()
			if (data or (self and self.data)) == ask then Finish(nil, true) end
		end)
	end,
	timeout = 60,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

function Hop.OnRoster()
	if not ask or ask.phase == "done" then return end
	local grouped = IsInGroup and IsInGroup()
	if ask.phase == "joined" then
		if not grouped then Finish() end
		return
	end
	if not grouped then return end
	-- In a group: a helper we asked is in it (or we accepted their invite), else it is some
	-- other group (a friend's) and the hop is off: the addon never leaves that one.
	local names, helper, named = GroupNames(), nil, false
	for name in pairs(ask.tried) do
		if names[ns.ShortName(name)] then helper = name end
	end
	for short in pairs(names) do
		if short ~= "" and short ~= (UNKNOWNOBJECT or "Unknown") then named = true end
	end
	-- Nobody in it named yet (the game names the members a moment later): the helper's
	-- invite we or the player accepted made this group. Anyone else named: not the hop's.
	if not helper and not named and (ask.phase == "accepted" or ask.invitedBy) then helper = ask.invitedBy or ask.helper end
	if not helper then return Finish() end
	ask.helper, ask.phase, ask.joined = helper, "joined", ns.Now()
	fails = 0 -- someone could help: the usual wait again
	stats.joins = stats.joins + 1
	ns.Print(L.HOP_JOINED:format(ns.DisplayName(helper)))
	Changed()
end

-- The layer a hop is taking us to, while we wait in the group: Layers takes it at once.
function Hop.ExpectedLayer()
	if ask and ask.phase == "joined" then return ask.mapID, ask.zoneUID end
end

-- In the group: the move shows as a new zone UID for our zone, or the one we asked for.
function Hop.OnLayer()
	if not ask or ask.phase ~= "joined" then return end
	local mine = ns.Layers.Mine()
	if not mine then return end
	local target = mine.mapID == ask.mapID and mine.zoneUID == ask.zoneUID
	local changed = ask.from and mine.mapID == ask.from.mapID and mine.zoneUID ~= ask.from.zoneUID
	if target or changed then
		stats.moves = stats.moves + 1
		Leave(L.HOP_MOVED_LEFT)
	end
end

-- The helper's addon lets us go (their guests stay GUEST_TIME at most).
function Hop.HandleRelease(dist, sender, text)
	if dist ~= "WHISPER" or not ask or ask.phase ~= "joined" or not ask.helper then return end
	if tonumber(text:match("^LX~(%d+)$")) ~= ask.id then return end
	if ns.ShortName(ns.FullName(sender)) ~= ns.ShortName(ask.helper) then return end
	Leave(L.HOP_RELEASED:format(ns.DisplayName(ask.helper)))
end

-- Helping on our own: the guests whose time is up are asked to leave (their addon does it).
local function ReleaseGuests(now)
	for short, g in pairs(guests) do
		if g.release and not g.released and now - g.t >= Hop.GUEST_TIME then
			g.released = true
			-- Only those still with us (a whisper to someone gone prints an error).
			if GroupNames()[short] then
				stats.releases = stats.releases + 1
				ns.Comm.Whisper(g.name, ("LX~%d"):format(g.id))
			end
		end
		if now - g.t >= Hop.GUEST_TIME * 3 then guests[short] = nil end
	end
end

function Hop.Tick()
	local now = ns.Now()
	if pending and now - pending.t > Hop.WAIT + 5 then pending = nil end -- the popup is long gone
	ReleaseGuests(now)
	if now - lastPromptCheck >= Hop.PROMPT_EVERY then
		lastPromptCheck = now
		Hop.CheckKingPrompt()
	end
	for key, askers in pairs(heard) do
		for short, t in pairs(askers) do
			if now - t > Hop.BRAKE_WINDOW then askers[short] = nil end
		end
		if not next(askers) then heard[key] = nil end
	end
	if not ask or ask.phase == "done" then return end
	if ask.phase == "queued" then
		if now >= ask.sendAt then Hop.SendAsk() end
	elseif ask.phase == "asking" then
		if now - ask.t >= Hop.WINDOW and ask.count > 0 then
			Hop.Next()
		elseif now - ask.t >= Hop.NOBODY then
			Failed(true)
		end
	elseif ask.phase == "requested" then
		if now - ask.asked >= Hop.WAIT then Hop.Next() end
	elseif ask.phase == "accepted" then
		if now - ask.accepted >= Hop.ACCEPT_WAIT then Hop.Next() end
	elseif ask.phase == "joined" and now - ask.joined >= Hop.JOIN_WAIT then
		OfferLeave()
	end
end

---------------------------------------------------------------------------
-- The King's layer
---------------------------------------------------------------------------

function Hop.ZoneName(mapID)
	return mapID and ns.Zones and ns.Zones.NameForKey and ns.Zones.NameForKey("m" .. mapID) or "?"
end

-- The King's own word on where he plays (1.0.0, Konig's review of 1.0.0): the name the server
-- stamped on the last message his client sent us (his crown, his layer, his commands: King.lua
-- and Layers.lua call Hop.HeardKing for the character pinned by name, ns.IsKingCharacter).
-- A census report is anyone's word: one forged report from another realm of our group placed him
-- there ("he plays on another realm"), and his layer could not be asked for. This session's alone.
local kingFrom
function Hop.HeardKing(sender)
	if type(sender) == "string" and ns.IsKingCharacter(sender) then kingFrom = ns.FullName(sender) end
end

-- The King when he is online (leader of the guild named exactly "Sylvanistas"), and his layer
-- when his addon announced it: { name, mapID, zoneUID }. The name is the one the army calls
-- him (ns.KING_NAME); his character's is only used to find his layer.
-- Only the leader the reports name, none of them disagreeing (Data.KnownRank, soft: the line
-- only shows; the Throne's commands ask for more): one forged report can't crown anyone
-- while the guild's own reporter says otherwise. strict: two reports (inviting on its own,
-- "For Sylvanistas!", waits for that).
-- His realm and his layer (1.0.0, Konig's review): where the census names the character pinned
-- by name, from his own messages alone (Hop.HeardKing), none heard yet: neither is known. Where
-- none is pinned (another realm group), the census's word is all there is.
function Hop.King(strict)
	local now = ns.Now()
	local pin = ns.KingCharacter()
	for name, g in pairs(ns.rdb.guilds or {}) do
		if ns.IsKingGuild(name) and type(g) == "table" and g.leader
			and now - (g.t or 0) <= ns.Data.FRESH and g.leaderOnline then
			local full = ns.FullName(g.leader, g.realm or ns.realm)
			if ns.Data.KnownRank(full, name, not strict) == 0 then
				local at = full
				if pin ~= nil and ns.ShortName(g.leader) == pin then at = kingFrom end
				local where = at and ns.Layers.Of(at, true)
				return { name = ns.KingName(g.leader), mapID = where and where.mapID, zoneUID = where and where.zoneUID,
					t = where and where.t, realm = at and ns.RealmOf(at) }
			end
		end
	end
	return nil
end

-- <Sylvanistas> reports its leader online, but the census does not confirm him yet (a few
-- minutes after login, Data.KnownRank): not "offline".
local function KingUnconfirmed()
	for name, g in pairs(ns.rdb.guilds or {}) do
		if ns.IsKingGuild(name) and type(g) == "table" and g.leader and g.leaderOnline
			and ns.Now() - (g.t or 0) <= ns.Data.FRESH then
			return true
		end
	end
	return false
end

-- The King plays on another realm than ours (his own messages say so, Hop.King; where no King
-- is pinned by name, the census). A layer is a copy of a zone inside one realm: nobody here can
-- join his, even when his crown and his layer reach us (a channel shared across realms,
-- Comm.ElectsAcrossRealms). Checked before his layer.
function Hop.KingOtherRealm(k)
	return k ~= nil and k.realm ~= nil and ns.realm ~= nil and ns.realm ~= "?" and k.realm ~= ns.realm
end

-- Why nobody can ask for the King's layer now (1.0.0), instead of "try again in a minute"
-- whatever the reason: he plays on another realm (Hop.KingOtherRealm), his crown is not on the
-- map (off, or he is in a dungeon: his layer is only announced while it shows, Layers.Sharing),
-- or it is and his layer is on its way (his addon repeats it every minute, Layers.KING_EVERY).
function Hop.KingUnknownText(k)
	if Hop.KingOtherRealm(k) then return L.HOP_KING_OTHER_REALM:format(k.name, k.realm) end
	if not (ns.King and ns.King.Location and ns.King.Location()) then return L.HOP_KING_HIDDEN:format(k.name) end
	return L.HOP_KING_UNKNOWN:format(k.name)
end

function Hop.AskKing()
	local k = Hop.King()
	if not k then return ns.Print(KingUnconfirmed() and L.HOP_KING_CHECKING:format(ns.KingName()) or L.HOP_KING_OFFLINE) end
	if Hop.KingOtherRealm(k) or not k.zoneUID then return ns.Print(Hop.KingUnknownText(k)) end
	if ns.Layers.CurrentMap() ~= k.mapID then return ns.Print(L.HOP_KING_ELSEWHERE:format(k.name, Hop.ZoneName(k.mapID))) end
	Hop.Ask(k.mapID, k.zoneUID, L.LAYER_OF:format(k.name))
end

-- The lines on top of the Census and the Realm while the King is online (Views.lua): the
-- button, and under it where he is when that is not our zone.
function Hop.KingLines()
	local k = Hop.King()
	if not k or (ns.King and ns.King.IsKing and ns.King.IsKing()) then return {} end
	-- The size of a title, with the crown the map shows him with.
	local crown = "|T" .. ns.CROWN_ICON .. ":0|t "
	local mine = ns.Layers.Mine()
	-- (On another realm his layer is not ours to join or be on, whatever reaches us of it.)
	local away = Hop.KingOtherRealm(k)
	if not away and k.zoneUID and mine and mine.mapID == k.mapID and mine.zoneUID == k.zoneUID then
		return Hop.WithAutoLine({ { text = crown .. "|cff40ff40" .. L.HOP_KING_HERE:format(k.name) .. "|r", color = "GameFontNormal", gapAfter = true } }, k)
	end
	local elsewhere = not away and k.zoneUID and ns.Layers.CurrentMap() ~= k.mapID
	local busy = ask and ask.phase ~= "done"
	local line = {
		text = crown .. "|cffffd200" .. (busy and L.HOP_KING_BUSY or L.HOP_KING_LINE):format(k.name) .. "|r",
		color = "GameFontNormal",
		gapAfter = not elsewhere,
		onClick = function() Hop.AskKing() end,
		tooltip = function(tt)
			tt:AddLine(L.HOP_KING_LINE:format(k.name), 1, 0.82, 0)
			if away or not k.zoneUID then
				tt:AddLine(Hop.KingUnknownText(k), 1, 1, 1, true)
			elseif elsewhere then
				tt:AddLine(L.HOP_KING_ELSEWHERE:format(k.name, Hop.ZoneName(k.mapID)), 1, 0.6, 0.2, true)
			else
				tt:AddLine(L.HOP_KING_TIP:format(k.name), 1, 1, 1, true)
			end
			local at = ns.King and ns.King.Location and ns.King.Location()
			if at then tt:AddLine(L.HOP_KING_WHERE:format(Hop.ZoneName(at.mapID)), 0.25, 1, 0.25, true) end
		end,
	}
	if not elsewhere then return Hop.WithAutoLine({ line }, k) end
	return Hop.WithAutoLine({ line, { text = "|cffff9933" .. L.HOP_KING_GO:format(Hop.ZoneName(k.mapID)) .. "|r", indent = 1, gapAfter = true } }, k)
end

-- While the addon invites on its own ("For Sylvanistas!" or "Always invite"), a line under the
-- King's says so, and one click stops it.
function Hop.WithAutoLine(lines, k)
	if not (ns.db.layerAutoInvite or KingChoice() == "auto") then return lines end
	lines[#lines].gapAfter = nil
	lines[#lines + 1] = {
		text = "|cff40ff40" .. L.HOP_AUTO_LINE:format(k.name) .. "|r", indent = 1, gapAfter = true,
		onClick = function() Hop.StopAuto() end,
		tooltip = function(tt)
			tt:AddLine(L.HOP_AUTO_LINE:format(k.name), 0.25, 1, 0.25)
			tt:AddLine(L.HOP_AUTO_TIP, 1, 1, 1, true)
		end,
	}
	return lines
end

-- No more invites on its own: every request shows the window again.
function Hop.StopAuto()
	ns.db.layerAutoInvite = false
	if KingChoice() == "auto" then
		kingMode = "manual"
		if ns.db.hopKingChoice == "auto" then ns.db.hopKingChoice = "manual" end
	end
	ns.Print(L.HOP_AUTO_OFF)
	Changed()
end
function Hop.KingLine() return Hop.KingLines()[1] end

-- Alone on the King's layer: may the addon invite, and later let go, the players who want to
-- come? Asked once a login (never again with the box ticked). Not asked of the King, nor of
-- players who turned helping off or already invite on their own.
function Hop.CheckKingPrompt()
	if promptShown or KingChoice() or not Hop.Helps() or ns.db.layerAutoInvite then return end
	if not ns.IsMember() or (ns.King and ns.King.IsKing and ns.King.IsKing()) then return end
	if (IsInGroup and IsInGroup()) or (IsInInstance and IsInInstance()) or (InCombatLockdown and InCombatLockdown()) then return end
	local mine = ns.Layers.Mine()
	if not mine or ns.Now() - (mine.t or 0) > Hop.LAYER_FRESH or not OnKingLayer() then return end
	promptShown = true
	ns.PlayAlert("soft", "hop")
	Hop.ShowKingPrompt()
end

function Hop.ChooseKing(choice)
	kingMode = choice
	local f = Hop.prompt
	if f then
		if f.check and f.check:GetChecked() then ns.db.hopKingChoice = choice end
		f.answered = true
		f:Hide()
	end
	if choice == "auto" then ns.Print(L.HOP_KING_AUTO:format((Hop.King() or {}).name or ns.KingName()))
	elseif choice == "no" then ns.Print(L.HOP_KING_NO)
	else ns.Print(L.HOP_KING_MANUAL) end
	Changed()
end

-- look: "dim" (grey, the way out), "main" (lit, white text: the one we hope for) or nil.
-- All three the same size.
local function PromptButton(f, label, choice, look)
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetHeight(22)
	if look == "dim" then
		b:SetNormalFontObject("GameFontDisable")
		b:SetHighlightFontObject("GameFontHighlight")
		b:SetAlpha(0.8)
	elseif look == "main" then
		b:SetNormalFontObject("GameFontHighlight")
		b:LockHighlight()
	end
	b:SetText(label)
	local fs = b:GetFontString()
	local textW = fs and (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()) or 100
	b:SetWidth(math.max(120, math.ceil(textW) + 28))
	b:SetScript("OnClick", function() ns.SafeCall("hop king choice", Hop.ChooseKing, choice) end)
	return b
end

-- A window like the game's own dialogs, with three answers and "Don't ask me again".
local function MakePrompt()
	local f = CreateFrame("Frame", "SylvanistasKingLayerPrompt", UIParent)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 80) -- clear of the game's popups at the top
	local okBorder, border = pcall(CreateFrame, "Frame", nil, f, "DialogBorderTemplate")
	if not okBorder or not border then
		border = f:CreateTexture(nil, "BACKGROUND")
		border:SetColorTexture(0, 0, 0, 0.85)
	end
	border:SetAllPoints()
	f.text = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	f.text:SetPoint("TOP", 0, -20)
	f.text:SetJustifyH("CENTER")
	-- Left to right: the way out (grey), inviting by hand, and "For Sylvanistas!" (lit, white).
	f.buttons = {
		PromptButton(f, L.HOP_KING_PROMPT_NO, "no", "dim"),
		PromptButton(f, L.HOP_KING_PROMPT_MANUAL, "manual"),
		PromptButton(f, L.HOP_KING_PROMPT_YES, "auto", "main"),
	}
	f.check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
	f.check:SetSize(24, 24)
	f.checkLabel = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	f.checkLabel:SetPoint("LEFT", f.check, "RIGHT", 2, 1)
	f.checkLabel:SetText(L.HOP_KING_PROMPT_NEVER)
	-- Escape (or anything else closing it unanswered): the usual window per request, this login.
	f:SetScript("OnHide", function(self)
		if not self.answered then kingMode = kingMode or "manual" end
	end)
	ns.EscapeCloses("SylvanistasKingLayerPrompt")
	return f
end

function Hop.ShowKingPrompt()
	Hop.prompt = Hop.prompt or MakePrompt()
	local f = Hop.prompt
	local total = 0
	for _, b in ipairs(f.buttons) do total = total + b:GetWidth() end
	total = total + 8 * (#f.buttons - 1)
	local width = math.max(400, total + 40)
	f:SetWidth(width)
	f.text:SetWidth(width - 48)
	local kname = (Hop.King() or {}).name or ns.KingName()
	f.text:SetText(L.HOP_KING_PROMPT:format(kname, kname))
	local x = (width - total) / 2
	for i, b in ipairs(f.buttons) do
		b:ClearAllPoints()
		if i == 1 then b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, 18) else b:SetPoint("LEFT", f.buttons[i - 1], "RIGHT", 8, 0) end
	end
	f.check:ClearAllPoints()
	f.check:SetPoint("BOTTOMLEFT", f.buttons[1], "TOPLEFT", -4, 6)
	f.check:SetChecked(false)
	local textH = f.text.GetStringHeight and f.text:GetStringHeight() or f.text:GetHeight()
	f:SetHeight(20 + math.max(40, textH or 0) + 12 + 24 + 6 + 22 + 18)
	f.answered = false
	f:Show()
end

-- What the Realm tab's layer rows show about an ask in progress for that layer.
function Hop.State() return ask end
function Hop.Stats() return stats end

function Hop.StatusLine()
	local s = stats
	local n = 0
	for _ in pairs(guests) do n = n + 1 end
	return ("help=%s auto=%s king=%s  |  asks=%d offers=%d requests=%d invites=%d noes=%d joins=%d moves=%d releases=%d guests=%d  |  now=%s"):format(
		tostring(Hop.Helps()), tostring(ns.db.layerAutoInvite == true), tostring(KingChoice() or "-"),
		s.asks, s.offers, s.requests, s.invites, s.noes, s.joins, s.moves, s.releases, n, ask and ask.phase or "-")
end

-- What this client knows of the King, for /syl status and /syl bug (1.0.0: "the King's layer
-- doesn't work" said nothing of why). Elsewhere: confirmed (two reports name him online),
-- online (one report), checking (reported online, not confirmed yet) or offline; the realm his
-- own messages place him on (Hop.King); his layer and when it was heard; his crown and when it was heard. On
-- his own client: his crown shown or hidden, and when his layer last went out.
function Hop.KingStatusLine()
	local K = ns.King
	if K and K.IsKing and K.IsKing() then
		local sent = ns.Layers.SentAt and ns.Layers.SentAt()
		return ("me  |  crown %s  |  layer %s"):format(K.SharingLocation() and "shown" or "hidden",
			sent and ("sent " .. ns.Ago(sent)) or "not sent")
	end
	local k, state = Hop.King(true), "confirmed"
	if not k then k, state = Hop.King(), "online (one report)" end
	if not k then return KingUnconfirmed() and "checking (reported online, not confirmed yet)" or "offline" end
	local realm = k.realm and (k.realm .. (Hop.KingOtherRealm(k) and " (another realm)" or " (ours)")) or "?"
	local layer = k.zoneUID and ("map %d zone %d, heard %s"):format(k.mapID, k.zoneUID, ns.Ago(k.t)) or "not known"
	local at = K and K.Location and K.Location()
	local crown = at and ("map %d, heard %s"):format(at.mapID, ns.Ago(at.t)) or "not heard"
	return ("%s  |  realm %s  |  layer %s  |  crown %s"):format(state, realm, layer, crown)
end

-- On again also forgets the King's layer answer: the window may ask again.
function Hop.SetHelp(on)
	ns.db.layerHelp = on
	if on then
		ns.db.hopKingChoice, kingMode, promptShown = nil, nil, false
	end
	ns.Print(on and L.HOP_HELP_ON or L.HOP_HELP_OFF)
end

-- Off also ends "For Sylvanistas!" (the King's layer window's answer).
function Hop.SetAuto(on)
	if not on then return Hop.StopAuto() end
	ns.db.layerAutoInvite = true
	ns.Print(L.HOP_AUTO_ON)
end

-- Tests start from a clean state.
function Hop.Reset()
	ask, pending, lastAsk = nil, nil, -math.huge
	fails, failedAt = 0, -math.huge
	wipe(heard)
	kingMode, promptShown, lastPromptCheck, privateHinted = nil, false, -math.huge, false
	lastOffer, declines, pausedUntil = -math.huge, 0, -math.huge
	wipe(offered); wipe(answeredAt); wipe(recent); wipe(guests)
	for k in pairs(stats) do stats[k] = 0 end
	kingFrom = nil
end

ns.Comm.Handle("LQ", function(...) Hop.HandleAsk(...) end)
ns.Comm.Handle("LO", function(...) Hop.HandleOffer(...) end)
ns.Comm.Handle("LR", function(...) Hop.HandleRequest(...) end)
ns.Comm.Handle("LN", function(...) Hop.HandleNo(...) end)
ns.Comm.Handle("LX", function(...) Hop.HandleRelease(...) end)

ns.On("LAYERS_CHANGED", function() ns.SafeCall("hop layer", Hop.OnLayer) end)

ns.On("LOGIN", function()
	ns.RegisterEvent("PARTY_INVITE_REQUEST", function(name) Hop.OnInvite(ns.Normal(name)) end)
	ns.RegisterEvent("GROUP_ROSTER_UPDATE", function() Hop.OnRoster() end)
	ns.Every(1, "hop", Hop.Tick)
end)
