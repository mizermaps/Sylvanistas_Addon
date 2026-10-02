local ADDON, ns = ...
local L = ns.L

-- The Throne: a tab for the King alone (the guild master of the guild named exactly
-- "Sylvanistas" of his faction, and that very character where the addon knows him by name,
-- ns.KING_CHARACTER), and for the Hands he names. What he sends goes out on the Sylvanistas
-- channel as T1 messages, and every client checks that the sender really is him (his name,
-- which the server sets: never a census vote, which anyone on the channel can cast), or one
-- of his Hands for the tools he lends them (HAND_MAY). Answers go back to whoever asked,
-- alone (T2, T3 as whispered addon messages).
--   T1~S~<id>~<guild>                      Summon the Lords (roll call)
--   T1~I~<id>~<guild>                      Royal Inspection: every addon patrols 2 minutes
--   T1~A~<id>~<guild>~<minutes>~<zone>~<title>   The King's Agenda (resent every 5 min)
--   T1~X~<id>~<guild>                      Agenda cancelled
--   T1~H~<id>~<guild>~<Name-Realm,...>     the Hands of the King (his alone; resent every 5 min)
--   T1~N~<id>~<guild>~<Name-Realm,...>     a Steward's own Hands (1.0.0: his alone; resent every 5 min)
--   T2~<id>~<P|B>~<guild>                  a Lord's answer to the roll call
--   T3~<id>~<guild>~<ok>~<none>~<other>~<name:guild,...>   an inspection report
-- Other modules add their own kinds (King.Register): Vox Populi (V, E), writs (W), the court
-- (C, Z), the gates (G), pardons (F), the treasury's switches and keepers (T, K: his and his
-- Steward's), the King's week and its signup sheet (D, R, 1.1: Week.lua), the dues' weekly
-- amount (Y, 1.1: his and his Steward's, Dues.lua).
-- The King's Steward (1.0.0, ns.IsSteward: the character the author marks in the signed titles
-- list) has the Throne as the King has it, "acting for the King": he names and removes Hands of
-- his own beside the King's, the treasury's keepers and its switches, and uses every tool of a
-- Hand (STEWARD_MAY). Never the King's own list of Hands, his crown on the map and his layer, the
-- court, writs, pardons, the untabarded list, or the King's own book of the treasury and his yes
-- to share it.

local King = {}
ns.King = King

King.SUMMON_OPEN = 60        -- the popup stays this long
King.SUMMON_GAP = 60         -- one roll call a minute at most (sent or accepted)
King.INSPECT_TIME = 120      -- each addon patrols this long
King.INSPECT_GAP = 1800      -- one Royal Inspection every 30 minutes at most (0.9.2), whoever calls it
-- The realm's share of the load (0.9.2). An inspect is one request to the server for a player
-- in reach. Budget: INSPECT_BUDGET requests a second across the whole realm. A client on the
-- inspection sends one every INSPECT_PACE seconds at most, so INSPECT_BUDGET * INSPECT_PACE =
-- 100 clients can take part at once; with N addons online (the census counts them) each one
-- takes part with probability 100 / N (all of them while there are 100 or fewer). 3,000 online:
-- 1 in 30, about 20 requests a second for 2 minutes, then nothing for at least 30 minutes.
King.INSPECT_BUDGET = 20
King.INSPECT_PACE = 5
King.AGENDA_RESEND = 300     -- the King's client repeats the agenda for late logins
King.MAX_NAMES = 6           -- violators per inspection report (message size)
King.AGENDA_GAP = 60         -- one new agenda a minute at most (each one is a raid warning)
King.MAX_ANSWERS = 150       -- roll-call answers kept
King.MAX_REPORTS = 150       -- inspection reports kept
King.MAX_CHECKS = 60         -- checks one patrol can report in 2 minutes
King.MAX_SHOWN = 30          -- violators listed on the page

King.MAX_HANDS = 40          -- Hands of the King (the list goes out in pieces when long)
King.HANDS_EVERY = 300       -- the King's client repeats the list for late logins
King.HANDS_FRESH = 20 * 60   -- a list the King stopped repeating (he left) ends

King.mode = nil              -- what the tab shows: home or hands (nil: home, the Throne Room)
local summon, inspect        -- the King's own roll call / inspection in progress
local agenda                 -- the agenda everyone sees: { id, title, at, zone, by }
local lastSummonSeen, lastInspectSeen, inspecting = -math.huge, -math.huge, nil
local lastSummonSent, lastInspectSent = -math.huge, -math.huge
local lastAgendaSent, lastAgendaWarn = -math.huge, -math.huge

-- Text other players send that ends up on the King's screen (on stream): only what looks
-- like a character name ("Pyralis Ashandar") or a Sylvanistas guild name, nothing else.
local function CleanName(s)
	s = tostring(s or ""):gsub("%-.*$", "")
	if #s > 30 or not s:match("^[%a\128-\255]+ ?[%a\128-\255]*$") then return nil end
	return s
end
local function CleanGuild(s)
	s = tostring(s or ""):gsub("[%c|]", "")
	if #s > 24 or not ns.IsFederation(s) or not s:match("^[%w\128-\255 ]+$") then return nil end
	return s
end

-- Someone we can place: our own guild (the server's roster) or a Lord or Captain the census
-- confirms (Data.KnownRank). Only they may put names on the King's page.
local function Verified(sender, guild)
	if ns.Roster.RankOf(sender) then return true end
	local rank = guild and ns.Data.KnownRank(sender, guild)
	return rank ~= nil and rank <= ns.CAPTAIN_RANK
end

---------------------------------------------------------------------------
-- Who
---------------------------------------------------------------------------

-- Where the King is pinned by name, another guild master of his guild is not him: nobody
-- would obey the powers the Throne gave that character.
function King.IsKing()
	if not ns.IsMember() then return false end
	local guild, _, rank = GetGuildInfo("player")
	if not (ns.IsKingGuild(guild) and rank == 0) then return false end
	return ns.KingCharacter() == nil or ns.IsKingCharacter(ns.me)
end

-- The author's test build (Dev.lua, never published) shows the tab without the powers:
-- nothing it does reaches anyone. The author turns this "Asmon's view" on and off from the
-- Workshop (ns.db.devKingView).
function King.Preview()
	if King.IsKing() then return false end
	local view = ns.db and ns.db.devKingView
	if view ~= nil and ns.Workshop and ns.Workshop.Visible and ns.Workshop.Visible() then return view == true end
	local dev = ns.devThrone
	if type(dev) == "table" then dev = dev[UnitName and UnitName("player") or ""] == true or dev[ns.ShortName(ns.me or "")] == true end
	return dev == true and not King.IsKing()
end
function King.Visible() return King.IsKing() or King.IsSteward() or King.IsHand() or King.Preview() end

-- The King's Steward (1.0.0): this character, where the signed titles list marks it for our
-- King (ns.IsSteward), and not the King himself.
function King.IsSteward() return not King.IsKing() and ns.IsSteward(ns.me) end
-- A sender the list marks (the server sets the name): his word counts for what STEWARD_MAY lends.
function King.IsStewardName(name) return type(name) == "string" and not ns.IsKingCharacter(name) and ns.IsSteward(name) end

-- The King himself, or his Steward: the lists of the Throne are theirs to set (each his own list
-- of Hands; the treasury's keepers and switches), and their clients repeat them.
function King.SetsLists() return King.IsKing() or King.IsSteward() end

-- Where the King is pinned by name (ns.KING_CHARACTER): that character alone, speaking for
-- the King's guild. No census vote can crown anyone else, nor silence him. Where he is not
-- (the Horde, until his name is known) nobody's commands are obeyed; soft: what only shows
-- (his position, his name on the lines) still comes from the census there (Data.KnownRank).
local function KingSender(sender, guild, soft)
	if not ns.IsKingGuild(guild) then return false end
	if ns.KingCharacter() then
		if not ns.IsKingCharacter(sender) then return false end
		ns.LearnKingRealm(sender) -- (the Horde's, while unknown: from the server's name)
		if ns.Hop and ns.Hop.HeardKing then ns.Hop.HeardKing(sender) end -- (his realm: his own word, 1.0.0)
		return true
	end
	return soft == true and ns.Data.KnownRank(sender, guild, true) == 0
end

-- The page refreshes at most once a second, whatever arrives.
local changePending = false
local function Changed()
	if changePending then return end
	changePending = true
	ns.After(1, "throne refresh", function()
		changePending = false
		ns.Fire("THRONE_CHANGED")
	end)
end

-- kind: the alert's sound switch (1.1, ns.SOUND_KINDS). o (1.1, ns.Alert): its popup or window
-- (show), how long it is current (open), its words while it waits (what), one line for the
-- same one repeated (key), the player's own click (own). The chat line always comes now; the
-- raid warning, the sound and the popup wait in an instance or on Busy.
local function Warn(text, loud, kind, o)
	ns.Print("|cffffd200" .. text .. "|r")
	o = o or {}
	return ns.Alert(kind or "throne", loud and "loud" or "soft", { text = text, color = { r = 1, g = 0.82, b = 0 },
		what = o.what, open = o.open, show = o.show, key = o.key, own = o.own })
end

local function NewId() return math.random(1, 99999) end

---------------------------------------------------------------------------
-- The Hands of the King: the players he names use the Throne's tools in his name (HAND_MAY:
-- the roll call, the inspection, the agenda, Vox Populi, the gates), never what is his alone
-- (the Hands, writs, the court, pardons, his position). Each client keeps the list of the
-- King it trusts, as he last sent it; a list he stopped repeating ends (HANDS_FRESH).
-- 1.0.0: each of his Stewards names Hands too, in a list of his own that only his client sends
-- (T1~N, STEWARD_MAY; clients before 1.0.0 know no such kind and leave it out):
--   T1~N~<id>~<guild>~<Name-Realm,...>     a Steward's Hands (his alone; resent every 5 min)
-- The Hands are the King's list and every Steward's together, each list its owner's alone:
-- nobody changes anyone else's. The King's list is the same message as before 1.0.0, from his
-- client alone. Each client keeps the list it last heard from each Steward (by his name, which
-- the server stamps); it ends HANDS_FRESH after his client stopped repeating it, and at once, on
-- every client, when the author's signed titles list no longer names him (for good: named again,
-- he starts from none, King.StewardsChanged). A Hand's powers are the same whoever named him.
-- The King never removes a Steward's Hand: that Steward does, or the author, by removing him
-- (the Hands page shows the others' lists, to read only).
---------------------------------------------------------------------------

King.HAND_MAY = { S = true, I = true, A = true, X = true, V = true, E = true, G = true }
-- The Steward's: everything a Hand may, his own list of Hands (N), and the treasury's switches
-- and keepers (T, K, Treasury.lua), and its dues' amount (Y, 1.1, Dues.lua). Never the King's
-- list of Hands (H), his crown on the map (P, Q), the court (C, Z), writs (W), pardons (F) or the
-- untabarded list (U).
King.STEWARD_MAY = { S = true, I = true, A = true, X = true, V = true, E = true, G = true, N = true, T = true, K = true, Y = true }
-- 1.1: the calls to the army a Hand or a Steward sends (popups, raid warnings, windows, the gates'
-- news): none shows from a name the moderators took off (net-off, Moderation.lua). Their lists (the
-- Hands, the treasury's words) are not calls: they still count. The same for the King's week (1.1,
-- Konig's review): its entries and their cancels (D), and the signup sheets (R, Week.lua). A client
-- the moderators took off sends none of them (Moderation.Blocks), but its setter's cancel of his
-- own entry, which every client takes for that entry alone (1.1 review).
King.HIDDEN_CALLS = { S = true, I = true, A = true, X = true, V = true, E = true, G = true, D = true, R = true }
-- A word of the treasury (its switches, its keepers: Treasury.lua) dated further ahead of the
-- server's clock is not taken. A minute: every client reads the same server clock, so a word
-- dated further ahead comes from a modified client, which would otherwise keep its word over
-- the King's newer one for as long (a review asked for a minute, not ten).
King.DATE_AHEAD = 60

local hands = {}         -- [name-realm, lower case] = true, as the King last sent it
local handsOrder = {}    -- the same names, in his order (the Hands page)
local handsAt = -math.huge
local handsKing          -- who sent that list (the King's name on a Hand's Throne Room)
local myHands = {}       -- the King's own list, in order: { "Name-Realm", ... } (saved: rdb.kingHands)
local lastHandsSent = -math.huge
local handsSendPending = false
-- 1.0.0: each Steward's list as this client last heard it from him:
-- [his Name-Realm] = { names = { "Name-Realm", ... }, set = { [name-realm, lower case] = true }, at = when }
local stewardHands = {}
-- A Steward's own list, on his client, in order (saved: rdb.stewardHands[his Name-Realm]: the
-- characters of one account on a realm group share what they save).
local myStewardHands = {}
local lastStewardSent = -math.huge

-- A Steward's list as heard here, while it counts: he is still a Steward (the signed titles
-- list names him) and his client kept repeating it.
local function StewardList(steward)
	local s = stewardHands[steward]
	if not s or not King.IsStewardName(steward) or ns.Now() - s.at > King.HANDS_FRESH then return nil end
	return s
end

-- On the King's own client his list is the one he keeps (his broadcast never comes back to
-- him); everyone else trusts the list he last sent, while he keeps sending it. A Steward's
-- the same (1.0.0): his own on his client, the one he last sent on everyone else's.
-- Whatever the case a name is written in (1.1, Konig's review): the King types a Hand's name as
-- he likes, and a net-off word's target is free text, while the server spells a sender's name
-- its own way; they are one character (hands and each Steward's set are kept in lower case).
local function Named(list, key)
	for _, n in ipairs(list) do if type(n) == "string" and n:lower() == key then return true end end
	return false
end
local function Hand(name)
	local full = ns.FullName(name)
	if type(full) ~= "string" then return false end
	local key = full:lower()
	if King.IsKing() then
		if Named(myHands, key) then return true end
	elseif ns.Now() - handsAt <= King.HANDS_FRESH and hands[key] == true then
		return true
	end
	if King.IsSteward() and Named(myStewardHands, key) then return true end
	for steward in pairs(stewardHands) do
		local s = StewardList(steward)
		if s and s.set[key] then return true end
	end
	return false
end

function King.IsHand() return not King.SetsLists() and ns.IsMember() and Hand(ns.me) end
-- Whether the King's list or a Steward's names this sender (1.0.0): their word alone, never a
-- census vote. His Hands speak with his Crown for his guild on every client outside it
-- (Decree.lua, Channels.VerifiedLevel); on its own members' clients its roster says who speaks
-- for it.
function King.IsHandName(name) return type(name) == "string" and Hand(name) end

-- This client's own list, the one its Hands page changes: the King's; a Steward's own (1.0.0);
-- the author's Asmon's view's, as the King's (sent nowhere).
local function Own()
	if not King.IsKing() and King.IsSteward() then return myStewardHands end
	return myHands
end
function King.Hands() return Own() end

-- A Steward's name as the King's screen shows it: cut short while the council's names are hidden
-- there (his stream, ns.CouncilMasked), like every councillor's.
local function StewardLabel(name)
	local shown = ns.DisplayName(name) or "?"
	return ns.CouncilMasked() and ns.MaskName(shown) or shown
end
King.StewardLabel = StewardLabel

-- The others' lists this client's Hands page shows, to read only (1.0.0): the King's (on a
-- Steward's client), then each Steward's but its own, while they count, none empty:
-- { { steward = <Name-Realm, nil for the King's>, names = { ... } }, ... }
function King.OthersHands()
	local out = {}
	if not King.IsKing() and ns.Now() - handsAt <= King.HANDS_FRESH and #handsOrder > 0 then
		out[1] = { names = handsOrder }
	end
	local names = {}
	for steward in pairs(stewardHands) do
		local s = StewardList(steward)
		if s and #s.names > 0 and not (King.IsSteward() and steward == ns.FullName(ns.me)) then names[#names + 1] = steward end
	end
	table.sort(names)
	for _, steward in ipairs(names) do out[#out + 1] = { steward = steward, names = stewardHands[steward].names } end
	return out
end

-- The King may send it; a Steward what STEWARD_MAY lends him (his own list of Hands among it:
-- never a list of the King's); one of their Hands what is theirs to use too (soft: his
-- position).
function King.Authorized(kind, sender, guild)
	if KingSender(sender, guild, kind == "P" or kind == "Q") then return true end
	if King.STEWARD_MAY[kind] == true and King.IsStewardName(sender) then return true end
	return King.HAND_MAY[kind] == true and Hand(sender)
end

-- The King, his Steward, or a Hand: the tools of the Throne.
function King.CanCommand() return King.IsKing() or King.IsSteward() or King.IsHand() end

-- The King himself sent it (not a Hand): for how it is shown.
function King.FromKing(sender, guild) return KingSender(sender, guild, true) end

-- The King's list, kept across sessions (a /reload must not drop his Hands); a Steward's own
-- the same (1.0.0), under his name: it ends with him (King.StewardsChanged), whichever character
-- of his account on that realm group sees the list without him.
local function SaveHands()
	if not ns.rdb then return end
	local own, copy = Own(), {}
	for i, n in ipairs(own) do copy[i] = n end
	if own ~= myStewardHands then ns.rdb.kingHands = copy; return end
	if type(ns.rdb.stewardHands) ~= "table" then ns.rdb.stewardHands = {} end
	ns.rdb.stewardHands[ns.FullName(ns.me)] = copy
end

-- Several changes in a row go out as one list, a few seconds after the last one.
local function SendHandsSoon()
	if handsSendPending then return end
	handsSendPending = true
	ns.After(3, "king hands", function()
		handsSendPending = false
		King.SendHands(true)
		King.SendStewardHands(true)
	end)
end

-- The King's list goes out whole: short in one message, long in pieces (Comm.SendChunked).
function King.SendHands(force)
	if not King.IsKing() then return end
	local now = ns.Now()
	if not force and now - lastHandsSent < King.HANDS_EVERY then return end
	if #myHands == 0 and lastHandsSent == -math.huge then return end -- nobody named yet
	lastHandsSent = now
	local msg = ("T1~H~%d~%s~%s"):format(NewId(), GetGuildInfo("player") or "", table.concat(myHands, ","))
	if #msg <= 250 then ns.Comm.Send("CHANNEL", msg, "hands") else ns.Comm.SendChunked(msg) end
end

-- A Steward's own list (1.0.0), from his client alone, the same way.
function King.SendStewardHands(force)
	if King.IsKing() or not King.IsSteward() then return end
	local now = ns.Now()
	if not force and now - lastStewardSent < King.HANDS_EVERY then return end
	if #myStewardHands == 0 and lastStewardSent == -math.huge then return end -- nobody named yet
	lastStewardSent = now
	local msg = ("T1~N~%d~%s~%s"):format(NewId(), GetGuildInfo("player") or "", table.concat(myStewardHands, ","))
	if #msg <= 250 then ns.Comm.Send("CHANNEL", msg, "stewardhands") else ns.Comm.SendChunked(msg) end
end

-- A name typed or targeted, as the server writes it; nil if it can't be a character.
local function HandName(input)
	local name = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then
		name = UnitIsPlayer and UnitIsPlayer("target") and ns.UnitFullName("target") or ""
	end
	name = ns.Normal(name)
	local short = CleanName(name)
	if not short then return nil end
	return ns.FullName(short, ns.RealmOf(name))
end

-- The King names a Hand in his list, a Steward in his own (1.0.0).
function King.AddHand(input)
	if not King.SetsLists() and not King.Preview() then return ns.Print(L.THRONE_ONLY_KING) end
	local name = HandName(input)
	if not name then return ns.Print(L.HANDS_WHO) end
	if name == ns.me then return end
	local own = Own()
	for _, n in ipairs(own) do if n == name then return end end
	if #own >= King.MAX_HANDS then return ns.Print(L.HANDS_FULL:format(King.MAX_HANDS)) end
	own[#own + 1] = name
	SaveHands()
	ns.Print(L.HANDS_ADDED:format(ns.DisplayName(name)))
	if King.SetsLists() then SendHandsSoon() end
	King.mode = "hands"
	Changed()
end

-- From this client's own list alone: never a Hand another one named (1.0.0).
function King.RemoveHand(name)
	local own = Own()
	for i, n in ipairs(own) do
		if n == name then
			table.remove(own, i)
			SaveHands()
			ns.Print(L.HANDS_REMOVED:format(ns.DisplayName(name)))
			if King.SetsLists() then SendHandsSoon() end
			return Changed()
		end
	end
end

-- This client became a Hand (the Throne's tab appears; `told`: by whom), or is one no more.
local function HandChanged(was, told)
	local now = King.IsHand()
	if now and not was then
		ns.Print(told())
		ns.PlayAlert("soft", "throne")
		ns.Fire("DATA_CHANGED") -- the Throne's tab appears
	elseif was and not now then
		ns.Fire("DATA_CHANGED")
	end
	Changed()
end

local function OnHands(king, rest)
	local list, n, order = {}, 0, {}
	for name in tostring(rest or ""):gmatch("[^,]+") do
		local short = CleanName(name)
		if short and n < King.MAX_HANDS then
			local full = ns.FullName(short, ns.RealmOf(name))
			if not list[full:lower()] then order[#order + 1] = full end
			list[full:lower()] = true
			n = n + 1
		end
	end
	local was = King.IsHand()
	hands, handsOrder, handsAt, handsKing = list, order, ns.Now(), ns.FullName(king)
	HandChanged(was, function() return L.HANDS_YOU:format(ns.KingName(king)) end)
end

-- A Steward's own list (1.0.0), from his own client: kept as he last sent it. Nobody else's
-- word (the King's character sending one too: King.Authorized lets him send any kind).
local function OnStewardHands(sender, rest)
	if not King.IsStewardName(sender) then
		return ns.Log("steward hands from %s ignored: no Steward here", tostring(sender))
	end
	local steward = ns.FullName(sender)
	local names, set = {}, {}
	for name in tostring(rest or ""):gmatch("[^,]+") do
		local short = CleanName(name)
		local full = short and ns.FullName(short, ns.RealmOf(name))
		if full and not set[full:lower()] and #names < King.MAX_HANDS then
			set[full:lower()] = true
			names[#names + 1] = full
		end
	end
	local was = King.IsHand()
	stewardHands[steward] = { names = names, set = set, at = ns.Now() }
	HandChanged(was, function() return L.HANDS_YOU_STEWARD:format(ns.DisplayName(steward) or "?") end)
end

-- The lists this client kept, at login: the King's (as before 1.0.0) and a Steward's own.
function King.LoadHands()
	local function Load(into, saved)
		wipe(into)
		for _, n in ipairs(type(saved) == "table" and saved or {}) do
			if type(n) == "string" and #into < King.MAX_HANDS then into[#into + 1] = n end
		end
	end
	Load(myHands, ns.rdb and ns.rdb.kingHands)
	local stewards = ns.rdb and ns.rdb.stewardHands
	Load(myStewardHands, type(stewards) == "table" and stewards[ns.FullName(ns.me)])
end

-- A signed titles list was taken (Workshop.TakeTitles, 1.0.0): the list of each Steward it no
-- longer names ends here for good, as heard from him and as his account kept it, his own
-- client's with it. Named again later, a Steward starts from none: nothing he named before comes
-- back until he names it again. (His account forgets it when one of its characters on that realm
-- group takes a list without him: if none did before the list naming him again, what it kept
-- comes back with him.)
function King.StewardsChanged()
	local changed = false
	for steward in pairs(stewardHands) do
		if not King.IsStewardName(steward) then stewardHands[steward], changed = nil, true end
	end
	local saved = ns.rdb and ns.rdb.stewardHands
	if type(saved) == "table" then
		for owner in pairs(saved) do
			if not King.IsStewardName(owner) then saved[owner] = nil end
		end
		if next(saved) == nil then ns.rdb.stewardHands = nil end
	end
	if not King.IsSteward() and (#myStewardHands > 0 or lastStewardSent ~= -math.huge) then
		wipe(myStewardHands)
		lastStewardSent, changed = -math.huge, true
	end
	if changed then Changed() end
end

StaticPopupDialogs["SYLVANISTAS_KING_HAND"] = {
	text = L.HANDS_PROMPT,
	button1 = OKAY or "OK",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 240,
	maxLetters = 40,
	OnShow = function(self)
		local eb = self.editBox or self.EditBox
		if eb then
			local target = UnitIsPlayer and UnitIsPlayer("target") and ns.UnitFullName("target")
			eb:SetText(target and ns.DisplayName(target) or "")
			eb:SetFocus()
		end
	end,
	OnAccept = function(self)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("add hand", King.AddHand, eb and eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		ns.SafeCall("add hand", King.AddHand, self:GetText())
		self:GetParent():Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs["SYLVANISTAS_KING_UNHAND"] = {
	text = L.HANDS_REMOVE_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function(self, data) ns.SafeCall("remove hand", King.RemoveHand, data or (self and self.data)) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Other modules' kinds of T1 (Vox Populi, writs, the court, the gates, pardons):
-- fn(sender, id, rest, guild), called once King.Authorized agreed.
local kinds = {}
function King.Register(kind, fn) kinds[kind] = fn end
King.Changed = function() Changed() end
King.Warn = function(text, loud, kind, o) return Warn(text, loud, kind, o) end
King.NewId = function() return NewId() end
King.CleanName = function(s) return CleanName(s) end
King.CleanGuild = function(s) return CleanGuild(s) end
King.Verified = function(sender, guild) return Verified(sender, guild) end

-- Our tabard, checked the way a patrol checks others (level 15+ only: the Sylvanistas rule).
local function OwnTabard()
	local level = UnitLevel and UnitLevel("player") or 0
	if level > 0 and level < (ns.Inspect.MIN_LEVEL or 15) then return nil end
	local item = GetInventoryItemID and GetInventoryItemID("player", INVSLOT_TABARD or 19)
	return ns.Inspect.Classify(item, true)
end

---------------------------------------------------------------------------
-- Summon the Lords
---------------------------------------------------------------------------

function King.Summon()
	local now = ns.Now()
	if King.Preview() then
		summon = { id = 0, t = now, answers = {}, preview = true }
		ns.Print(L.THRONE_PREVIEW_NOTE)
		return Changed()
	end
	if not King.CanCommand() then return end
	if now - lastSummonSent < King.SUMMON_GAP then
		ns.Print(L.THRONE_WAIT:format(math.ceil(King.SUMMON_GAP - (now - lastSummonSent))))
		return Changed()
	end
	lastSummonSent = now
	summon = { id = NewId(), t = now, answers = {} }
	ns.Comm.Send("CHANNEL", ("T1~S~%d~%s"):format(summon.id, GetGuildInfo("player")))
	ns.Log("throne: summon %d", summon.id)
	Changed()
end

local function OnSummon(king, id, guild)
	local now = ns.Now()
	if now - lastSummonSeen < King.SUMMON_GAP then return end
	if not ns.IsMember() or ns.Roster.MyRank() > ns.CAPTAIN_RANK then return end
	lastSummonSeen = now
	-- The King by the army's name for him; a Hand by theirs.
	local who = King.FromKing(king, guild) and L.THRONE_SUMMONED:format(ns.KingName(king)) or L.THRONE_SUMMONED_HAND:format(ns.DisplayName(king))
	-- In an instance or on Busy (1.1): a chat line; the popup once the player is out, while it
	-- is open (never answered for them).
	local shown = ns.Alert("throne", "soft", {
		what = L.HELD_SUMMON, key = "summon" .. tostring(id),
		open = function() return ns.Now() - now < King.SUMMON_OPEN end,
		show = function() ns.ShowDialog("SYLVANISTAS_KING_SUMMON", who, nil, { king = king, id = id }) end,
	})
	if not shown then ns.Print("|cffffd200" .. who .. "|r  |cff9d9d9d" .. L.HELD_LATER .. "|r") end
end

local function Answer(data, word)
	if not data or not data.king then return end
	ns.Comm.Whisper(data.king, ("T2~%d~%s~%s"):format(data.id, word, GetGuildInfo("player") or ""))
end

StaticPopupDialogs["SYLVANISTAS_KING_SUMMON"] = {
	text = "%s",
	button1 = L.THRONE_PRESENT,
	button2 = L.THRONE_BUSY,
	OnAccept = function(self, data) ns.SafeCall("throne answer", Answer, data or self.data, "P") end,
	OnCancel = function(self, data, reason)
		if reason == "clicked" then ns.SafeCall("throne answer", Answer, data or self.data, "B") end
	end,
	timeout = King.SUMMON_OPEN,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- The Lords and Captains the census knows online, answered or not: { name, guild, rank }.
local function LordsOnline()
	local out = {}
	for _, e in ipairs(ns.Data.Summary().guilds) do
		local g = e.g
		if e.fresh then
			local home = g.realm or ns.realm
			if g.leader and g.leaderOnline then out[#out + 1] = { name = ns.FullName(g.leader, home), guild = e.name, rank = 0 } end
			for _, o in ipairs(g.officers or {}) do
				if o.online then out[#out + 1] = { name = ns.FullName(o.name, home), guild = e.name, rank = 1 } end
			end
		end
	end
	return out
end

function King.HandleAnswer(dist, sender, text)
	if dist ~= "WHISPER" or not summon or summon.preview then return end
	local id, word, guild = text:match("^T2~(%d+)~([PB])~(.*)$")
	if tonumber(id) ~= summon.id or ns.Now() - summon.t > 300 then return end
	sender = ns.FullName(sender)
	if summon.answers[sender] then return end -- one answer each
	guild = CleanGuild(guild)
	-- Only confirmed Lords and Captains are listed by name; anyone else is just counted.
	if not guild or not Verified(sender, guild) then
		summon.others = summon.others or {}
		if not summon.others[sender] then
			local n = 0
			for _ in pairs(summon.others) do n = n + 1 end
			if n < King.MAX_ANSWERS then summon.others[sender] = word end
		end
		return Changed()
	end
	local n = 0
	for _ in pairs(summon.answers) do n = n + 1 end
	if n >= King.MAX_ANSWERS then return end
	summon.answers[sender] = { word = word, guild = guild, verified = true, t = ns.Now() }
	Changed()
end
ns.Comm.Handle("T2", function(...) King.HandleAnswer(...) end)

---------------------------------------------------------------------------
-- Royal Inspection
---------------------------------------------------------------------------

function King.Inspect()
	local now = ns.Now()
	if King.Preview() then
		ns.Print(L.THRONE_PREVIEW_NOTE)
		inspect = { id = 0, t = now, reports = {}, preview = true }
		King.RunInspection(nil, 0) -- our own patrol only, reported to ourselves
		return Changed()
	end
	if not King.CanCommand() then return end
	if now - lastInspectSent < King.INSPECT_GAP then
		ns.Print(L.THRONE_WAIT:format(math.ceil(King.INSPECT_GAP - (now - lastInspectSent))))
		return Changed()
	end
	lastInspectSent = now
	inspect = { id = NewId(), t = now, reports = {} }
	ns.Comm.Send("CHANNEL", ("T1~I~%d~%s"):format(inspect.id, GetGuildInfo("player")))
	ns.Log("throne: inspection %d", inspect.id)
	King.RunInspection(ns.me, inspect.id) -- the King patrols too
	Changed()
end

-- Its raid warning, in an instance or on Busy (1.1, ns.Alert): current while the patrols run.
-- own: the King's (or the preview's) own click.
function King.InspectionHeld(start, id, own)
	return { what = L.HELD_INSPECTION, key = "inspect" .. tostring(id or 0), own = own or nil,
		open = function() return ns.Now() - start < King.INSPECT_TIME end }
end

-- Every addon (the King's too): a raid warning, a patrol of INSPECT_TIME, then a report to
-- the King of what it saw (and our own tabard).
function King.RunInspection(king, id)
	if inspecting or not ns.IsMember() then return end
	local start = ns.Now()
	inspecting = { king = king, id = id, start = start, wasOn = ns.Inspect.IsPatrolling() }
	Warn(L.THRONE_INSPECT_WARN, true, "throne", King.InspectionHeld(start, id, king == nil or king == ns.me))
	if not inspecting.wasOn then ns.Inspect.SetPatrol(true) end
	ns.Inspect.SetPace(King.INSPECT_PACE) -- the realm's budget (INSPECT_BUDGET)
	ns.After(King.INSPECT_TIME, "royal inspection", function()
		local run = inspecting
		inspecting = nil
		ns.Inspect.SetPace(nil)
		if not run then return end
		if not run.wasOn and ns.Inspect.IsPatrolling() then ns.Inspect.SetPatrol(false) end
		local ok, none, other, names = 0, 0, 0, {}
		-- A patrol does not re-inspect anyone checked in the last 10 minutes: those count too.
		-- What another officer of our guild found (1.1, Inspect.lua) is his word, not ours: left out.
		for name, p in pairs(ns.Inspect.Players()) do
			if not p.shared and (p.t or 0) >= run.start - 600 then
				if p.status == "GUILD" then ok = ok + 1
				elseif p.status == "NONE" or p.status == "OTHER" then
					if p.status == "NONE" then none = none + 1 else other = other + 1 end
					if #names < King.MAX_NAMES then names[#names + 1] = (ns.DisplayName(name) or "?") .. ":" .. (p.guild or "?") .. ":" .. (p.status == "NONE" and "N" or "O") end
				end
			end
		end
		local own = OwnTabard()
		if own == "GUILD" then ok = ok + 1 elseif own == "NONE" then none = none + 1 elseif own == "OTHER" then other = other + 1 end
		local guild = GetGuildInfo("player") or ""
		local msg = ("T3~%d~%s~%d~%d~%d~%s"):format(run.id or 0, guild, ok, none, other, table.concat(names, ","))
		if run.king == ns.me or not run.king then
			King.ReceiveReport(ns.me, msg) -- ours (the King's, or the preview's)
		else
			ns.Comm.Whisper(run.king, msg:sub(1, 250))
		end
	end)
end

-- The addons online the census knows of (fresh reports), at least 1.
function King.AddonsOnline()
	local n = 0
	for _, e in ipairs(ns.Data.Summary().guilds) do
		if e.fresh then n = n + (tonumber(e.g.users) or 0) end
	end
	return math.max(n, 1)
end

-- This client's chance to take part in an inspection (see INSPECT_BUDGET).
function King.InspectShare()
	return math.min(1, King.INSPECT_BUDGET * King.INSPECT_PACE / King.AddonsOnline())
end
King.random = math.random -- tests

local function OnInspect(king, id)
	local now = ns.Now()
	if now - lastInspectSeen < King.INSPECT_GAP then return end
	lastInspectSeen = now
	-- Everyone hears the King's call; only a sample of the army patrols (and reports), and never
	-- a player who said no (/syl inspection off, 0.9.3). 1.1 (Fern's #11): nor one who never
	-- answered (the first-open page, or /syl inspection on): nil is off.
	if not (ns.db and ns.db.royalInspection == true) then
		ns.Log("inspection %d: not taking part (%s)", id or 0, ns.db and ns.db.royalInspection == false and "/syl inspection off" or "not answered")
		return Warn(L.THRONE_INSPECT_WARN, true, "throne", King.InspectionHeld(now, id))
	end
	if King.random() > King.InspectShare() then
		ns.Log("inspection %d: not in this sample (%.2f)", id or 0, King.InspectShare())
		return Warn(L.THRONE_INSPECT_WARN, true, "throne", King.InspectionHeld(now, id))
	end
	King.RunInspection(king, id)
end

function King.ReceiveReport(sender, text)
	if not inspect then return end
	local id, guild, ok, none, other, names = text:match("^T3~(%d+)~([^~]*)~(%d+)~(%d+)~(%d+)~(.*)$")
	if not id or tonumber(id) ~= inspect.id or ns.Now() - inspect.t > 900 then return end
	sender = ns.FullName(sender)
	if inspect.reports[sender] then return end -- one report each
	local n = 0
	for _ in pairs(inspect.reports) do n = n + 1 end
	if n >= King.MAX_REPORTS then return end
	guild = CleanGuild(guild)
	if not guild then return end
	-- Only from someone we can place in that guild (our own, a confirmed Lord or Captain):
	-- nobody else writes names or numbers on the King's page.
	if sender ~= ns.me and not Verified(sender, guild) then return end
	local list = {}
	for entry in names:gmatch("[^,]+") do
		local nm, g, st = entry:match("^([^:]+):([^:]*):([NO])$")
		nm, g = CleanName(nm), CleanGuild(g)
		if nm and g and #list < King.MAX_NAMES then list[#list + 1] = { name = nm, guild = g, status = st == "N" and "NONE" or "OTHER" } end
	end
	local cap = King.MAX_CHECKS
	inspect.reports[sender] = { guild = guild, ok = math.min(tonumber(ok) or 0, cap),
		none = math.min(tonumber(none) or 0, cap), other = math.min(tonumber(other) or 0, cap), names = list }
	Changed()
end

function King.HandleReport(dist, sender, text)
	if dist ~= "WHISPER" or not King.CanCommand() then return end
	King.ReceiveReport(sender, text)
end
ns.Comm.Handle("T3", function(...) King.HandleReport(...) end)

-- The violators the inspection found go on the King's own list, then the usual Wall of Shame.
-- The untabarded (Inspect.lua): the King's list, the army's only while he lets it see it.
--   T1~U~<id>~<guild>~1~<name>:<guild>,...   the list, repeated while it is on
--   T1~U~<id>~<guild>~0                      off: it leaves every screen
-- Only the King (not a Hand: "U" is not in HAND_MAY). Older versions ignore the kind.
King.UNTABARDED_EVERY = 300
local lastUntabardedSent = -math.huge

function King.SharingUntabarded() return ns.db and ns.db.kingUntabarded == true end

-- What the inspection's patrols reported joins his own list.
local function TakeReports()
	for _, r in pairs(inspect and inspect.reports or {}) do
		for _, v in ipairs(r.names) do ns.Inspect.AddReported(v.name, v.guild, v.status) end
	end
end

function King.SendUntabarded(force)
	if not King.IsKing() then return end
	local now = ns.Now()
	local on = King.SharingUntabarded()
	if not force and (not on or now - lastUntabardedSent < King.UNTABARDED_EVERY) then return end
	lastUntabardedSent = now
	local guild = GetGuildInfo("player") or ""
	local msg
	if on then
		TakeReports()
		local body = ns.Codec.EncodeShame(guild, 0, ns.Inspect.ShameList()):match("^S1~[^~]*~%d+~(.*)$") or ""
		msg = ("T1~U~%d~%s~1~%s"):format(NewId(), guild, body)
	else
		msg = ("T1~U~%d~%s~0"):format(NewId(), guild)
	end
	if #msg <= 250 then ns.Comm.Send("CHANNEL", msg, "untabarded") else ns.Comm.SendChunked(msg) end
end

function King.ToggleUntabarded()
	if King.Preview() then return ns.Print(L.THRONE_PREVIEW_NOTE) end
	if not King.IsKing() then return ns.Print(L.THRONE_ONLY_KING) end
	ns.db.kingUntabarded = not King.SharingUntabarded()
	ns.Print(King.SharingUntabarded() and L.UNTABARDED_ON or L.UNTABARDED_OFF)
	King.SendUntabarded(true)
	-- 1.1 (#12): his own switch never comes back to him: in his log as he sends it.
	local on = King.SharingUntabarded()
	ns.Chronicle.Add("switch", ns.me, on and L.ACTS_UNTABARDED_ON or L.ACTS_UNTABARDED_OFF, { key = "untabarded", value = on and "1" or "0" })
	Changed()
end

local function OnUntabarded(sender, rest)
	if King.IsKing() then return end
	local on, body = tostring(rest or ""):match("^(%d)~?(.*)$")
	-- 1.1 (#12): in this client's log of acts when it flips (repeated every 5 minutes while on).
	if on == "1" or on == "0" then
		ns.Chronicle.Add("switch", sender, on == "1" and L.ACTS_UNTABARDED_ON or L.ACTS_UNTABARDED_OFF, { key = "untabarded", value = on })
	end
	if on == "1" then
		local s = ns.Codec.DecodeShame("S1~Sylvanistas~0~" .. body)
		if s then ns.Inspect.ShowShame({ by = ns.KingName(sender), list = s.list, t = ns.Now() }) end
	elseif on == "0" then
		ns.Inspect.ShowShame(nil)
	end
end

---------------------------------------------------------------------------
-- The King's Agenda
---------------------------------------------------------------------------

local function ZoneName()
	return (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or ""
end

local function Clean(s, n) return ns.Cut((tostring(s or ""):gsub("[~|\n]", " ")), n) end

-- "30 Raid on Crossroads": minutes first, then the title.
function King.ParseAgenda(input)
	local minutes, title = tostring(input or ""):match("^%s*(%d+)%s+(.-)%s*$")
	minutes = tonumber(minutes)
	if not minutes or minutes < 1 or minutes > 720 or title == "" then return nil end
	return minutes, Clean(title, 60)
end

function King.SetAgenda(input)
	local minutes, title = King.ParseAgenda(input)
	local W = ns.Week
	-- 1.1: a day and an hour, then what: an entry of the King's week (Week.lua). After a number
	-- too ("30 Sat 20:00 Raid night", the 1.0 box's "30 " kept): the week's, never a 30-minute
	-- Agenda with its raid warning and popup for the whole army.
	if W and W.LooksLikeEntry and W.LooksLikeEntry(minutes and title or input) then
		local text = minutes and title or input
		if W.Parse(text) then return W.SetEntry(text) end
		ns.Print(L.THRONE_AGENDA_USAGE)
		return false
	end
	if not minutes then
		ns.Print(L.THRONE_AGENDA_USAGE)
		return false
	end
	local now = ns.Now()
	if not King.Preview() and now - lastAgendaSent < King.AGENDA_GAP then
		ns.Print(L.THRONE_WAIT:format(math.ceil(King.AGENDA_GAP - (now - lastAgendaSent))))
		return false
	end
	lastAgendaSent = now
	local mine = { id = NewId(), title = title, at = now + minutes * 60, zone = Clean(ZoneName(), 40), by = ns.me, mine = true, fired = {} }
	if King.Preview() then
		agenda = mine
		ns.Print(L.THRONE_PREVIEW_NOTE)
		return Changed() or true
	end
	if not King.CanCommand() then return false end
	agenda = mine
	King.SendAgenda()
	Warn(L.THRONE_AGENDA_SET:format(title, minutes, mine.zone), false, "agenda", { own = true })
	Changed()
	return true
end

function King.SendAgenda()
	if not agenda or not agenda.mine or King.Preview() then return end
	-- Seconds left, so a resend never moves the time (minutes rounded up did).
	local left = math.floor(agenda.at - ns.Now())
	if left < 30 then return end
	ns.Comm.Send("CHANNEL", ("T1~A~%d~%s~%d~%s~%s"):format(agenda.id, GetGuildInfo("player") or "", left, agenda.zone, agenda.title), "agenda")
end

function King.CancelAgenda()
	if not agenda then return end
	-- The King or a Hand cancels it for everyone, whoever set it (its setter's client stops
	-- repeating it when the cancel reaches it).
	if (agenda.mine or King.CanCommand()) and not King.Preview() then
		ns.Comm.Send("CHANNEL", ("T1~X~%d~%s"):format(agenda.id, GetGuildInfo("player") or ""), "agenda")
	end
	if ns.Week and ns.Week.Forget then ns.Week.Forget(agenda.id) end -- (1.1: a signup for it, and its nudge)
	agenda = nil
	Changed()
end

function King.Agenda()
	if agenda and agenda.at < ns.Now() - 600 then agenda = nil end -- over for 10 minutes
	return agenda
end

local function OnAgenda(king, id, rest, guild)
	local seconds, zone, title = rest:match("^(%d+)~([^~]*)~(.*)$")
	seconds = tonumber(seconds)
	if not seconds or seconds < 30 or seconds > 720 * 60 or title == "" then return end
	local now = ns.Now()
	if agenda and agenda.id == id then
		-- A resend: keep our time unless it is really off (late login, clock drift).
		if math.abs((now + seconds) - agenda.at) > 60 then agenda.at = now + seconds end
		return Changed()
	end
	agenda = { id = id, title = Clean(title, 60), at = now + seconds, zone = Clean(zone, 40), by = king, fired = {},
		guild = King.CleanGuild(guild) } -- (1.1: its setter's guild, for the net-off: Week.lua)
	-- A new agenda is a raid warning and a popup (the appointment: what, when, where), but
	-- not more than once a minute whatever arrives.
	if now - lastAgendaWarn >= King.AGENDA_GAP then
		lastAgendaWarn = now
		local a, byKing = agenda, King.FromKing(king, guild)
		-- The popup says the minutes left when it shows (later, after an instance: 1.1).
		local function Popup()
			local minutes = math.max(1, math.ceil((a.at - ns.Now()) / 60))
			-- The King by the army's name for him; a Hand by theirs (as OnSummon).
			local where = a.zone ~= "" and a.zone or "?"
			local text = byKing and L.THRONE_AGENDA_POPUP:format(ns.KingName(king), a.title, minutes, where)
				or L.THRONE_AGENDA_POPUP_HAND:format(ns.DisplayName(king), a.title, minutes, where)
			ns.ShowDialog("SYLVANISTAS_AGENDA_CALL", text)
		end
		Warn(L.THRONE_AGENDA_SET:format(a.title, math.ceil(seconds / 60), a.zone), false, "agenda", King.AgendaHeld(a, Popup))
	end
	Changed()
end

-- The Agenda's raid warnings in an instance or on Busy (1.1, ns.Alert): one line for it and its
-- reminders, current until it is due (and while it is still the Agenda).
function King.AgendaHeld(a, show)
	return { what = L.HELD_AGENDA:format(a.title), key = "agenda" .. tostring(a.id), show = show,
		open = function() return agenda == a and a.at > ns.Now() end }
end

StaticPopupDialogs["SYLVANISTAS_AGENDA_CALL"] = {
	text = "%s",
	button1 = OKAY or "OK",
	timeout = 120,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- The King on the map: when he turns it on (Throne tab), his client sends where he is and
-- every addon shows a crown on the world map and the minimap. Off by default, and a button
-- away: his position is on stream.
--   T1~P~<id>~<guild>~<mapID>~<x 0-1000>~<y 0-1000>   where he is (every few seconds while moving)
--   T1~Q~<id>~<guild>                                  hidden again
---------------------------------------------------------------------------

King.LOCATION_EVERY = 5      -- seconds between sends while moving
King.LOCATION_STILL = 20     -- standing still, repeated this often (for late logins)
King.LOCATION_EXPIRE = 45    -- a crown with no news this long is removed

local kingAt                 -- where the King is, for everyone: { name, mapID, x, y, t }
local locationId = NewId()
local lastLocation = { t = -math.huge }
local Pins = ns.Pins()
local SHOW_FLAG = HBD_PINS_WORLDMAP_SHOW_CONTINENT or 2
local crowns                 -- { world, mini } pin frames, made on first use
local crownAt                -- where they are drawn now (drawn again only when he moved)

function King.SharingLocation() return ns.db.throneLocation == true end

local function SendLocation(force)
	if not King.SharingLocation() or not King.IsKing() then return end
	if IsInInstance and IsInInstance() then return end
	local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	local pos = mapID and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
	if not pos then return end
	local x, y = pos:GetXY()
	if not x or (x == 0 and y == 0) then return end
	local now = ns.Now()
	local moved = lastLocation.mapID ~= mapID or math.abs((lastLocation.x or 0) - x) > 0.003 or math.abs((lastLocation.y or 0) - y) > 0.003
	if not force and (now - lastLocation.t < King.LOCATION_EVERY or (not moved and now - lastLocation.t < King.LOCATION_STILL)) then return end
	lastLocation = { mapID = mapID, x = x, y = y, t = now }
	ns.Comm.Send("CHANNEL", ("T1~P~%d~%s~%d~%d~%d"):format(locationId, GetGuildInfo("player") or "", mapID,
		math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5)), "kinglocation")
end

function King.ToggleLocation()
	if King.Preview() then return ns.Print(L.THRONE_PREVIEW_NOTE) end
	if not King.IsKing() then return end
	ns.db.throneLocation = not King.SharingLocation()
	if King.SharingLocation() then
		ns.Print(L.THRONE_LOCATION_SHOWN)
		-- His crown is his yes for his layer too (Layers.lua): the army asks to join him there.
		-- Both go out now (1.0.0: his layer waited for its next announcement, up to ten minutes).
		ns.Print(L.THRONE_LOCATION_LAYER)
		SendLocation(true)
		ns.Layers.AnnounceNow()
	else
		ns.Print(L.THRONE_LOCATION_HIDDEN)
		lastLocation = { t = -math.huge }
		ns.Comm.Send("CHANNEL", ("T1~Q~%d~%s"):format(locationId, GetGuildInfo("player") or ""), "kinglocation")
		-- His layer goes with it, at once, and his hello stops naming his zone (Layers.Sharing).
		ns.Layers.Withdraw()
		ns.Comm.Hello(true)
	end
	-- Taking donations (1.1): his zone in it follows his crown at once.
	if ns.Treasury and ns.Treasury.DonationsMoved then ns.Treasury.DonationsMoved() end
	Changed()
end

local function CrownTip(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(L.THRONE_LOCATION_PIN:format(kingAt and kingAt.name or "?"), 1, 0.82, 0)
	GameTooltip:Show()
end
local function Crown(size)
	local f = CreateFrame("Frame", nil, UIParent)
	f.sylvanistas = true -- (ours: photo mode leaves it shown, UI.TogglePhoto)
	f:SetSize(size, size)
	f.icon = f:CreateTexture(nil, "OVERLAY")
	f.icon:SetTexture(ns.CROWN_ICON)
	f.icon:SetAllPoints()
	f:EnableMouse(true)
	f:SetScript("OnEnter", CrownTip)
	f:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return f
end
-- The world map's crown sits beside the zone circles, never over their numbers (1.0.0,
-- Map.Badge); the minimap's is a plain crown (no circles there).
local function WorldCrown()
	local f = ns.Map.Badge(20, false)
	ns.Map.SetBadge(f, ns.CROWN_ICON)
	f.badge:SetScript("OnEnter", CrownTip)
	f.badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return f
end

-- Draws (or removes) the crown on the world map and the minimap. The world map's only with
-- mouse and keyboard (ns.WorldMapIcons); drawn again when that changes, even where he stands still.
function King.RefreshCrown()
	if not Pins then return end
	local world = ns.WorldMapIcons(Pins, King)
	if kingAt and ns.Now() - kingAt.t > King.LOCATION_EXPIRE then kingAt = nil end
	if not kingAt then
		if crowns and crownAt then
			if world then Pins:RemoveWorldMapIcon(King, crowns.world) end
			Pins:RemoveMinimapIcon(King, crowns.mini)
			crowns.world:Hide()
			crowns.mini:Hide()
		end
		crownAt = nil
		return
	end
	if crownAt and crownAt.mapID == kingAt.mapID and crownAt.x == kingAt.x and crownAt.y == kingAt.y and crownAt.world == world then return end
	crowns = crowns or { world = WorldCrown(), mini = Crown(16) }
	-- Taken off before it is put back: the map library makes a new map pin on every add.
	if crownAt then
		if world then Pins:RemoveWorldMapIcon(King, crowns.world) end
		Pins:RemoveMinimapIcon(King, crowns.mini)
	end
	crownAt = { mapID = kingAt.mapID, x = kingAt.x, y = kingAt.y, world = world }
	if world then Pins:AddWorldMapIconMap(King, crowns.world, kingAt.mapID, kingAt.x, kingAt.y, SHOW_FLAG) end
	Pins:AddMinimapIconMap(King, crowns.mini, kingAt.mapID, kingAt.x, kingAt.y, true, true)
end

local function OnLocation(king, rest)
	local mapID, x, y = rest:match("^(%d+)~(%d+)~(%d+)$")
	mapID, x, y = tonumber(mapID), tonumber(x), tonumber(y)
	if not mapID or x > 1000 or y > 1000 then return end
	kingAt = { from = ns.FullName(king), name = ns.KingName(king), mapID = mapID, x = x / 1000, y = y / 1000, t = ns.Now() }
	ns.SafeCall("king crown", King.RefreshCrown)
	Changed()
end

-- Where the King is, while he shares it: { name, mapID, x, y, t } or nil.
function King.Location()
	if kingAt and ns.Now() - kingAt.t > King.LOCATION_EXPIRE then return nil end
	return kingAt
end

function King.HandleCommand(dist, sender, text)
	if dist ~= "CHANNEL" then return end
	local kind, id, guild, rest = text:match("^T1~(%a)~(%d+)~([^~]*)~?(.*)$")
	if not kind then return end
	if not King.Authorized(kind, sender, guild) then
		-- Positions come every few seconds: not logged.
		if kind ~= "P" then
			ns.Log("throne %s from %s ignored: not the King of %s nor his Hand%s", kind, sender, tostring(guild),
				ns.KingCharacter() and "" or " (no King named on this side: nobody commands)")
		end
		return
	end
	id = tonumber(id)
	-- 1.1: a Hand (or a Steward) the moderators took off (net-off, Moderation.lua): none of their
	-- calls to the army shows. (Never the King: nobody takes him off.)
	-- But a setter taking his own entry off the King's week (a D of 0 seconds): Week.lua takes it
	-- for his own entry alone (1.1 review: held, it showed again everywhere once he was back).
	if King.HIDDEN_CALLS[kind] and ns.Moderation.Hides and ns.Moderation.Hides(sender, guild) and not (kind == "D" and rest:find("^0~")) then
		return ns.Log("throne %s from %s ignored: net-off", kind, sender)
	end
	-- The King's own client takes his Hands' news (the agenda, the gates, a cancel), not
	-- their calls to the army: no roll call popup, patrol or poll window for him.
	if King.IsKing() and (kind == "S" or kind == "I" or kind == "V") and not KingSender(sender, guild) then return end
	if kind == "S" then OnSummon(sender, id, guild)
	elseif kind == "H" then OnHands(sender, rest)
	elseif kind == "N" then OnStewardHands(sender, rest)
	elseif kinds[kind] then kinds[kind](sender, id, rest, guild)
	elseif kind == "I" then OnInspect(sender, id)
	elseif kind == "U" then OnUntabarded(sender, rest)
	elseif kind == "A" then OnAgenda(sender, id, rest, guild)
	elseif kind == "P" then OnLocation(sender, rest)
	elseif kind == "Q" then
		-- Only whoever put the crown there takes it off.
		if kingAt and kingAt.from ~= ns.FullName(sender) then return end
		kingAt = nil
		ns.SafeCall("king crown", King.RefreshCrown)
		Changed()
	elseif kind == "X" then
		if agenda and agenda.id == id then
			agenda = nil
			Changed()
		end
		-- 1.1: our signup for it goes, and its nudge (held after a /reload too: Week.lua).
		if ns.Week and ns.Week.Forget then ns.Week.Forget(id) end
	end
end
ns.Comm.Handle("T1", function(...) King.HandleCommand(...) end)

ns.On("LOGIN", function()
	-- The King's position, while he shares it; everyone's crown expires on its own.
	ns.Every(King.LOCATION_EVERY, "king location", function()
		SendLocation()
		King.RefreshCrown()
	end)
	-- His Hands from the last session; he repeats them for late logins (HANDS_EVERY). A
	-- Steward's own list the same, from his client (1.0.0).
	King.LoadHands()
	ns.Every(60, "king hands", function()
		King.SendHands()
		King.SendStewardHands()
		King.SendUntabarded()
	end)
	-- The guild is not always known at login yet: checked when the note is due.
	ns.After(20, "king location note", function()
		if King.SharingLocation() and King.IsKing() then ns.Print(L.THRONE_LOCATION_SHOWN) end
		-- A King no update has named yet (the Horde's): his commands reach nobody (KingSender).
		if King.IsKing() and not ns.KingCharacter() then ns.Print(L.THRONE_NOT_NAMED) end
	end)
	ns.Every(60, "agenda", function()
		local a = King.Agenda()
		if not a then return end
		local left = a.at - ns.Now()
		-- Reminders for everyone, and the King's client repeats it for late logins.
		a.fired = a.fired or {}
		for _, mark in ipairs({ 600, 60 }) do
			if left <= mark and left > 0 and not a.fired[mark] then
				a.fired[mark] = true
				Warn(L.THRONE_AGENDA_SOON:format(a.title, math.max(1, math.ceil(left / 60)), a.zone), false, "agenda", King.AgendaHeld(a))
			end
		end
		if a.mine and (not a.sentAt or ns.Now() - a.sentAt >= King.AGENDA_RESEND) then
			a.sentAt = ns.Now()
			King.SendAgenda()
		end
		Changed()
	end)
end)

StaticPopupDialogs["SYLVANISTAS_KING_AGENDA"] = {
	text = L.THRONE_AGENDA_PROMPT,
	button1 = OKAY or "OK",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 260,
	maxLetters = 70,
	OnShow = function(self)
		-- Empty (1.1): the box takes minutes or a day and an hour, and a "30 " put there first
		-- would turn a week entry into a 30-minute Agenda.
		local eb = self.editBox or self.EditBox
		if eb then eb:SetText(""); eb:SetFocus() end
	end,
	OnAccept = function(self)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("agenda", King.SetAgenda, eb and eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		ns.SafeCall("agenda", King.SetAgenda, self:GetText())
		self:GetParent():Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

function King.AgendaPrompt()
	ns.ShowDialog("SYLVANISTAS_KING_AGENDA")
	Changed()
end

---------------------------------------------------------------------------
-- What the tab shows (parchment, dark text: line.font)
---------------------------------------------------------------------------

local INK, TITLE = "QuestFont", "QuestTitleFont"

local function Line(text, font, extra)
	local l = { text = text, font = font or INK }
	for k, v in pairs(extra or {}) do l[k] = v end
	return l
end

-- A paragraph in rows short enough for the page (rows are one line each): split at spaces,
-- about `width` letters a row. The last row takes `extra` (gapAfter...).
King.WRAP = 44
local function Para(lines, text, font, extra)
	local row, rows = "", {}
	for word in tostring(text or ""):gmatch("%S+") do
		if row ~= "" and #row + 1 + #word > King.WRAP then
			rows[#rows + 1] = row
			row = word
		else
			row = row == "" and word or (row .. " " .. word)
		end
	end
	if row ~= "" then rows[#rows + 1] = row end
	for i, r in ipairs(rows) do lines[#lines + 1] = Line(r, font, i == #rows and extra or nil) end
	return lines
end
King.Para = Para

---------------------------------------------------------------------------
-- Where the King's calls show: the roll call in the Realm tab (next to the Lords it calls),
-- the Royal Inspection in the Tabards tab. Plain rows (not the parchment), for the King and
-- his Hands (and the author's Asmon's view).
---------------------------------------------------------------------------

local function Grey(s) return "|cff9d9d9d" .. s .. "|r" end
local function Gold(s) return "|cffffd200" .. s .. "|r" end
local function Green(s) return "|cff40ff40" .. s .. "|r" end
local READY = "|TInterface\\RaidFrame\\ReadyCheck-Ready:13:13|t "
local NOT_READY = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:13:13|t "
local WAITING = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:13:13|t "
King.ROLL_SHOWN = 15 * 60    -- the marks next to the Lords stay this long after a roll call

function King.CanCall() return King.CanCommand() or King.Preview() end

-- Who answered the roll call: present and busy (confirmed Lords and Captains), the others
-- the census can't confirm (counted), and the Lords online who stayed silent.
local function RollCall()
	if not summon then return nil end
	local present, busy, silent, others = {}, {}, {}, 0
	for name, a in pairs(summon.answers) do
		local row = ("%s <%s>"):format(ns.DisplayName(name), a.guild)
		if a.word == "P" then present[#present + 1] = row else busy[#busy + 1] = row end
	end
	for _ in pairs(summon.others or {}) do others = others + 1 end
	for _, lord in ipairs(LordsOnline()) do
		local answered = summon.answers[lord.name] or (summon.others and summon.others[lord.name])
		if not answered and lord.name ~= ns.me then silent[#silent + 1] = ("%s <%s>"):format(ns.DisplayName(lord.name), lord.guild) end
	end
	table.sort(present); table.sort(busy); table.sort(silent)
	return present, busy, silent, others
end

-- The mark next to a Lord or Captain in the Realm tree while a roll call is fresh: answered
-- present, busy, or (online) not answered yet.
function King.RollCallMark(name, online)
	if not summon or not King.CanCall() or ns.Now() - summon.t > King.ROLL_SHOWN then return "" end
	local full = ns.FullName(name)
	if full == ns.me then return "" end -- who called
	local a = summon.answers[full]
	if a then return a.word == "P" and READY or NOT_READY end
	-- An answer the census could not confirm (counted apart) is still an answer: the mark only.
	local o = summon.others and summon.others[full]
	if o then return o == "P" and READY or NOT_READY end
	return online and WAITING or ""
end

local rollOpen = false
function King.RollCallLines()
	if not King.CanCall() then return {} end
	local present, busy, silent, others = RollCall()
	local lines = {
		{
			header = true, text = READY .. L.THRONE_SUMMON_TITLE,
			right = present and Grey(L.ROLL_COUNTS:format(#present, #busy, #silent) .. "  " .. ns.Ago(summon.t)) or Gold(L.ROLL_CALL),
			-- A call while there is none; once called, "call again" below (the results stay).
			onClick = not present and function() King.Summon() end or nil,
			tooltip = function(tt)
				tt:AddLine(L.THRONE_SUMMON_TITLE, 1, 0.82, 0)
				tt:AddLine(L.THRONE_SUMMON_TIP, 1, 1, 1, true)
				tt:AddLine(L.ROLL_CLICK, 0.6, 0.6, 0.6, true)
			end,
		},
	}
	if present then
		lines[#lines + 1] = { indent = 1, text = Gold((rollOpen and "[-] " or "[+] ") .. L.ROLL_WHO),
			onClick = function()
				rollOpen = not rollOpen
				if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
			end }
		if rollOpen then
			-- (1.1.2's review: Silent and the unconfirmed say why they can be off, the answer bank's.)
			local function Why(tt) if ns.Answers and ns.Answers.WhyTip then ns.Answers.WhyTip(tt, "count-throne-silent") end end
			for _, group in ipairs({ { L.THRONE_PRESENT_N, present, Green }, { L.THRONE_BUSY_N, busy, Grey }, { L.THRONE_SILENT_N, silent, Grey } }) do
				local label = group[1]:format(#group[2])
				lines[#lines + 1] = { indent = 1, text = group[3](label), tooltip = group[2] == silent and function(tt)
					tt:AddLine(label, 1, 0.82, 0)
					Why(tt)
				end or nil }
				for _, row in ipairs(group[2]) do lines[#lines + 1] = { indent = 2, text = row } end
			end
			if others > 0 then
				local label = L.THRONE_UNCONFIRMED:format(others)
				lines[#lines + 1] = { indent = 1, text = Grey(label), tooltip = function(tt)
					tt:AddLine(label, 1, 0.82, 0)
					Why(tt)
				end }
			end
		end
		lines[#lines + 1] = { indent = 1, text = Gold("> " .. L.ROLL_AGAIN), onClick = function() King.Summon() end }
	end
	lines[#lines].gapAfter = true
	return lines
end

-- The Royal Inspection on top of the Tabards tab: call one, then what the patrols reported.
function King.InspectionLines()
	if not King.CanCall() then return {} end
	local lines = {}
	local ok, bad, reporters, byGuild, names = 0, 0, 0, {}, {}
	for _, r in pairs(inspect and inspect.reports or {}) do
		reporters = reporters + 1
		ok, bad = ok + r.ok, bad + r.none + r.other
		local g = byGuild[r.guild] or { ok = 0, bad = 0 }
		g.ok, g.bad = g.ok + r.ok, g.bad + r.none + r.other
		byGuild[r.guild] = g
		for _, v in ipairs(r.names) do names[#names + 1] = v end
	end
	local total = ok + bad
	local pct = total > 0 and math.floor(ok * 100 / total + 0.5) or 0
	lines[1] = {
		header = true, text = "|TInterface\\Icons\\INV_Shirt_GuildTabard_01:14:14|t " .. L.THRONE_INSPECT_TITLE,
		right = inspect and Grey(L.INSPECTION_SHORT:format(pct, total) .. "  " .. ns.Ago(inspect.t)) or Gold(L.INSPECTION_CALL),
		onClick = not inspect and function() King.Inspect() end or nil,
		tooltip = function(tt)
			tt:AddLine(L.THRONE_INSPECT_TITLE, 1, 0.82, 0)
			tt:AddLine(L.THRONE_INSPECT_TIP, 1, 1, 1, true)
		end,
	}
	if inspect then
		local left = inspect.t + King.INSPECT_TIME + 10 - ns.Now()
		if left > 0 then lines[#lines + 1] = { indent = 1, text = Gold(L.THRONE_INSPECT_RUNNING:format(math.ceil(left))) } end
		lines[#lines + 1] = { indent = 1, text = L.THRONE_INSPECT_SUMMARY:format(reporters, total, pct) }
		local guilds = {}
		for guild, g in pairs(byGuild) do guilds[#guilds + 1] = { name = guild, ok = g.ok, n = g.ok + g.bad } end
		table.sort(guilds, function(a, b) return a.n > b.n end)
		for _, g in ipairs(guilds) do
			lines[#lines + 1] = { indent = 2, text = Green("<" .. g.name .. ">"),
				right = ("%d%%  (%d/%d)"):format(g.n > 0 and math.floor(g.ok * 100 / g.n + 0.5) or 0, g.ok, g.n) }
		end
		if #names > 0 then
			lines[#lines + 1] = { indent = 1, text = "|cffff4040" .. L.THRONE_VIOLATORS:format(#names) .. "|r" }
			for i, v in ipairs(names) do
				if i > 10 then
					lines[#lines + 1] = { indent = 2, text = Grey(L.AND_MORE:format(#names - 10)) }
					break
				end
				lines[#lines + 1] = { indent = 2, text = ("%s  %s"):format(v.name, Grey("<" .. v.guild .. ">")),
					right = v.status == "NONE" and L.TABARD_NONE or L.TABARD_OTHER }
			end
		end
		lines[#lines + 1] = { indent = 1, text = Gold("> " .. L.INSPECTION_AGAIN), onClick = function() King.Inspect() end }
	end
	-- The untabarded list is the King's: he alone lets the army see it (not a Hand), and can
	-- take it back at any time, inspection or not.
	if King.IsKing() or King.Preview() then
		lines[#lines + 1] = { indent = 1, text = Gold("> " .. (King.SharingUntabarded() and L.UNTABARDED_STOP or L.UNTABARDED_SHARE)),
			onClick = function() King.ToggleUntabarded() end,
			tooltip = function(tt) tt:AddLine(L.UNTABARDED_TIP, 1, 1, 1, true) end }
	end
	lines[#lines].gapAfter = true
	return lines
end

local function HandsLines()
	local steward = King.IsSteward()
	local lines = Para({ Line(L.HANDS_TITLE, TITLE) }, steward and L.HANDS_HINT_STEWARD or L.HANDS_HINT, INK, { gapAfter = true })
	if King.SetsLists() or King.Preview() then
		local list = King.Hands()
		lines[#lines + 1] = Line("+ " .. L.HANDS_ADD, TITLE, { onClick = function() ns.ShowDialog("SYLVANISTAS_KING_HAND") end })
		for _, name in ipairs(list) do
			lines[#lines + 1] = Line(ns.DisplayName(name), INK, { indent = 1, key = name,
				onClick = function() ns.ShowDialog("SYLVANISTAS_KING_UNHAND", ns.DisplayName(name), nil, name) end,
				tooltip = function(tt) tt:AddLine(ns.DisplayName(name), 1, 0.82, 0); tt:AddLine(L.HANDS_CLICK_REMOVE, 1, 1, 1, true) end })
		end
		if #list == 0 then lines[#lines + 1] = Line(L.HANDS_NONE, INK, { indent = 1 }) end
		lines[#lines].gapAfter = true
		-- The Hands the others named (1.0.0: the King, each Steward), under who named them: theirs
		-- to remove, lines to read here (no button).
		for _, o in ipairs(King.OthersHands()) do
			lines[#lines + 1] = Line(o.steward and L.HANDS_NAMED_BY_STEWARD:format(StewardLabel(o.steward)) or L.HANDS_NAMED_BY_KING, TITLE)
			for _, name in ipairs(o.names) do lines[#lines + 1] = Line(ns.DisplayName(name), INK, { indent = 1 }) end
			lines[#lines].gapAfter = true
		end
		Para(lines, steward and L.HANDS_NOTE_STEWARD or L.HANDS_NOTE, INK)
	end
	return lines
end

King.Line, King.INK, King.TITLE = Line, INK, TITLE

local function Go(mode) return function() King.Show(mode) end end

-- The Throne Room: what is the King's alone. Each tool lives where it belongs (the agenda and
-- the court on the buttons below, the roll call in the Realm, the inspection in the Tabards,
-- Vox Populi and the treasury on their own tabs): here, the court's queue while it is open and
-- the treasury. A Hand's: where their tools are. His Steward's (1.0.0): the King's, with what is
-- his to do in the King's name (he holds no court: no queue).
local function HomeLines()
	local mine = King.IsKing() or King.Preview()
	local steward = not mine and King.IsSteward()
	local title = (mine or steward) and L.THRONE_ROOM or L.THRONE_ROOM_HAND:format(ns.KingName(handsKing or ns.KingCharacter()))
	local lines = { Line(title, TITLE, { gapAfter = true }) }
	if steward then
		Para(lines, L.THRONE_STEWARD_HINT, INK, { gapAfter = true })
	elseif not mine then
		return Para(lines, L.THRONE_HAND_HINT, INK)
	end
	for _, l in ipairs(ns.Court and ns.Court.HomeLines and ns.Court.HomeLines() or {}) do lines[#lines + 1] = l end
	-- 1.1: the army's key, the King's to rotate, or his Steward's for him (Keys.lua).
	if mine or steward then
		for _, l in ipairs(ns.Keys.ThroneLines and ns.Keys.ThroneLines() or {}) do lines[#lines + 1] = l end
	end
	if #lines > 1 then lines[#lines].gapAfter = true end
	for _, l in ipairs(ns.Treasury and ns.Treasury.ThroneLines and ns.Treasury.ThroneLines() or {}) do lines[#lines + 1] = l end
	return lines
end

-- The King's own pages (and his Steward's): a Hand's Throne Room has no link to them.
King.KING_PAGES = { hands = true }

-- For Views.Build("throne"): lines, detail title, detail text.
-- The Throne opens on the Throne Room (the King's: his court's queue while it is open, the
-- treasury; a Hand's: where their tools are), and holding court takes him there. (1.0.0: no
-- letter before it any more.) His Steward's says on top, on every page, that he acts for the King.
function King.Build(s)
	local lines, home
	if not King.mode then King.mode = "home" end
	local mode = King.mode
	if King.KING_PAGES[mode] and not (King.SetsLists() or King.Preview()) then mode = "home" end
	if mode == "hands" then lines = HandsLines()
	else lines, home = HomeLines(), true end
	-- Every other page leads back to the Throne Room.
	if not home then table.insert(lines, 1, Line("< " .. L.THRONE_ROOM, INK, { onClick = Go("home"), gapAfter = true })) end
	-- While the army sees him on the map, the page says so on top, whatever it shows.
	if King.SharingLocation() and King.IsKing() then
		table.insert(lines, 1, Line("|T" .. ns.CROWN_ICON .. ":0|t " .. L.THRONE_LOCATION_LIVE, TITLE, { gapAfter = true }))
	end
	local steward = King.IsSteward()
	if steward then table.insert(lines, 1, Line("|T" .. ns.CROWN_ICON .. ":0|t " .. L.STEWARD_ACTING, TITLE, { gapAfter = true })) end
	local detail = steward and L.THRONE_YOU_ARE_STEWARD:format(ns.KingName(ns.KingCharacter()))
		or King.IsHand() and L.THRONE_YOU_ARE_HAND:format(ns.KingName(handsKing or ns.KingCharacter())) or L.THRONE_YOU_ARE_KING
	return lines, L.TAB_THRONE, detail
end

function King.Show(mode)
	King.mode = mode
	Changed()
end

-- For tests.
function King.CancelAgendaButton()
	if not King.Agenda() then return ns.Print(L.THRONE_AGENDA_NONE) end
	King.CancelAgenda()
	ns.Print(L.THRONE_AGENDA_CANCELLED)
end

function King.State() return { summon = summon, inspect = inspect, agenda = agenda, inspecting = inspecting } end

-- /syl status (1.0.0): the King's Steward as this client knows him (the signed titles list), and
-- the lists of Hands it holds, each its owner's: how many, and whether it still lasts here.
function King.StewardStatusLine()
	local who
	if King.IsSteward() then
		who = "you, acting for the King"
	elseif not ns.KingCharacter() then
		who = "none (no King named on this side)"
	elseif not ns.CouncilTitles() then
		who = "none known (no signed titles list here yet)"
	else
		local shown = {}
		for i, n in ipairs(ns.Stewards()) do shown[i] = StewardLabel(n) end
		who = #shown > 0 and table.concat(shown, ", ") or "none named"
	end
	local function Heard(at) return ns.Now() - at <= King.HANDS_FRESH and ("heard " .. ns.Ago(at)) or "lapsed here" end
	local held = {}
	if King.IsKing() then held[1] = ("the King's %d (yours)"):format(#myHands)
	elseif handsAt ~= -math.huge then held[1] = ("the King's %d (%s)"):format(#handsOrder, Heard(handsAt)) end
	if King.IsSteward() then held[#held + 1] = ("yours %d"):format(#myStewardHands) end
	local stewards = {}
	for steward in pairs(stewardHands) do stewards[#stewards + 1] = steward end
	table.sort(stewards)
	for _, steward in ipairs(stewards) do
		local s = stewardHands[steward]
		local state = King.IsStewardName(steward) and Heard(s.at) or "ended: no longer an Ambassador"
		held[#held + 1] = ("%s's %d (%s)"):format(StewardLabel(steward), #s.names, state)
	end
	return ("%s  |  Hands: %s"):format(who, #held > 0 and table.concat(held, ", ") or "none")
end

-- The author's Workshop: Asmon's view on or off (the Throne, Vox Populi, the King's calls in
-- the Realm and the Tabards), to see and try them. Nothing the view does reaches anyone.
function King.SetDevView(on)
	ns.db.devKingView = on and true or false
	-- The preview's treasury switches and keepers were its own: gone with it.
	if not on then ns.db.previewTreasuryFlags, ns.db.previewTreasuryKeepers = nil, nil end
	ns.Print(on and L.DEV_KING_VIEW_NOW_ON or L.DEV_KING_VIEW_NOW_OFF)
	ns.Fire("DATA_CHANGED")
	Changed()
end
function King.Reset()
	summon, inspect, agenda, inspecting, kingAt, crownAt = nil, nil, nil, nil, nil, nil
	hands, handsOrder, handsAt, lastHandsSent, handsKing, handsSendPending = {}, {}, -math.huge, -math.huge, nil, false
	wipe(myHands)
	wipe(stewardHands); wipe(myStewardHands)
	lastStewardSent = -math.huge
	lastLocation = { t = -math.huge }
	lastSummonSeen, lastInspectSeen, lastSummonSent, lastInspectSent = -math.huge, -math.huge, -math.huge, -math.huge
	lastUntabardedSent = -math.huge
	lastAgendaSent, lastAgendaWarn, changePending = -math.huge, -math.huge, false
	King.mode, rollOpen = nil, false
end
