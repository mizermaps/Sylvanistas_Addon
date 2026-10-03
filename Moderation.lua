local ADDON, ns = ...
local L = ns.L

-- Net-off (1.1, requests #32 and #33): the King, his Steward, a Hand (the King's list or a
-- Steward's) or a High Councillor of the author's signed list gives a word, with a reason and the
-- time, on one of two things:
--   a character (c): every honest client hides that character on every addon surface: the chats
--     (and their history), the pinned line (Channels.Pin), decrees, layers and hop offers, Vox Populi (questions and votes), the
-- court's queue, and (1.1, review) the King's week (entries, sheets and signups), the
--     Board (flags and camps), the crafters' board (listings, answers and recipe lists), and the
--     elite borders and nameplate marks (Borders.lua). The names that character's player linked
--     as alts (Alts.lua, confirmed on each character) are hidden with it. The rest of the guild,
--     and the census, stay.
--   a guild (g): while it is off, honest clients stop sending and showing that guild's census,
--     map, hop, decrees, Vox and addon channels, and the rest above: its members' own clients
--     send none of them, and every client drops what still comes. Blizzard's guild chat and Guild
--     window stay up (the guild's own addon messages over GUILD too, but its master's pinned line,
--     hidden with its chats: Channels.Pin). One guild at a time: there
--     is no switch for the whole realm, and never the King's guild.
-- The same people put either back on.
--   O1~<c|g>~<1 off|0 on>~<server time>~<Name-Realm or Guild>~<by Name-Realm>~<reason>
-- Its words travel with the logged API, as a chat line's do (the server keeps them, so abuse
-- can be reported), one word per message. Every client keeps, on each name, the word from
-- highest up (its weight: its giver's rank, the King 3, a Steward 2, a Hand or a councillor 1;
-- no word replaces one from higher up, whatever its date: review of 1.1), and among
-- words of the same weight the newest (by the server's clock; on the same second the King's
-- own, else the one taking the name off, else by its giver's name: every client keeps the same
-- one), and takes a word only from someone who may give one now, as this client knows them (the
-- server stamps every sender's name): the King by his pinned name, a Steward of the signed titles
-- list, a Hand of the King's list or a Steward's, a councillor of the signed council list; never
-- a name that is off itself. A word one of them passes on for another (only a modified client
-- does: an honest one repeats its own words alone) is taken only while its giver may give one
-- too, weighs no more than whoever passed it on, and shows who did (the server's name): nobody
-- writes a word in someone else's name unseen. Each giver's client repeats his own words for
-- late logins, never anyone else's (1.1 review: a word passed on in the King's name went out
-- from his client as his own), every REPEAT (longer when the list is long: the army repeats
-- REPEATS_A_MINUTE words a minute at most), and not once he may no longer give one (it lapses;
-- so does a word whose giver was not online to repeat it for STALE). A word taking a name off
-- lapses OFF_KEEP after it was given (given again, it starts over); one putting a name back on
-- is kept and repeated for ON_KEEP, so an older word never comes back.
-- Among those who give words, only a word from higher up reaches one of them (the King above a
-- Steward, a Steward above the Hands and councillors): a Hand or a councillor never hides the
-- Steward, another Hand or another councillor. And no word replaces one from higher up (Take):
-- a Hand or a councillor never puts back one the King or a Steward hid, nor hides again one the
-- King showed again; nor does a Steward undo the King's word. Nor does a word push one from
-- higher up out of a full list (MakeRoom), nor hide a name through another name of its player
-- (a linked alt, or the same name on another realm of the group) when the name's own word
-- weighs more, or as much and is newer (Hidden, Character): 1.1, review.
-- What it is not: /syl block stays one client's and one player's, and nothing here uninvites,
-- demotes, or writes Blizzard's ignore list. It never aims at the pinned King (his name in any
-- case) or his guild. It knows nothing of the treasury or of payments, and no treasury code
-- calls it (the tests proves it). A modified client can ignore it.

local Moderation = {}
ns.Moderation = Moderation

Moderation.KINDS = { c = true, g = true } -- what a word may aim at: a character, a guild (no third)
Moderation.MAX = { c = 500, g = 200 }     -- words kept per kind (full: the oldest "on" word goes; for the
                                          -- King's own word, the oldest word not his; never one from
                                          -- higher up than the new word: MakeRoom)
Moderation.REPEAT = 300           -- an issuer's client repeats each word this long after it was last heard
Moderation.JITTER = 90            -- ...and up to this much later, its own draw (the others' repeat first)
Moderation.PER_TICK = 3           -- words one client repeats a minute at most
Moderation.REPEATS_A_MINUTE = 20  -- the army's repeats of the list a minute at most: a longer list is repeated less often
Moderation.OFF_KEEP = 30 * 86400  -- a word taking a name off lapses this long after it was given, on every client
Moderation.ON_KEEP = 30 * 86400   -- a word putting a name back on is kept (and repeated) this long (never less than OFF_KEEP)
Moderation.ON_EVERY = 1800        -- ...repeated this often
Moderation.STALE = 3 * 86400      -- an "off" word nobody repeated for this long lapses on a client that
                                  -- gives none (an issuer's own client keeps it; it repeats it after WARMUP)
Moderation.WARMUP = 600           -- an issuer's client online this long before it repeats a word it held unheard
Moderation.DATE_AHEAD = 60        -- a word dated further ahead of the server's clock is not taken
Moderation.REASON_MAX = 80        -- bytes of a reason
Moderation.GUILDS_KNOWN = 3000    -- senders whose guild this client remembers (the hop's whispers name none)
-- What a client whose own character or guild is off stops sending (the receivers drop it anyway):
-- chat lines, decrees, layer announcements, hop asks, offers and answers, Vox votes; and (1.1,
-- review) its signups to the King's week (Y2), its flags and camps on the Board (G1), its
-- crafter's listing, answers and recipe lists (W1, WA, WL), and the Throne's calls to the army,
-- the week's entries among them (T1 of a kind in King.HIDDEN_CALLS: its lists still go, and so
-- does a setter's cancel of his own entry on the week, 1.1 review). (Its
-- census report: Comm.Broadcast.) Nothing over GUILD is in it: the guild's own hello and key go on.
Moderation.BLOCKED = { M1 = true, D1 = true, L1 = true, LQ = true, LO = true, LR = true, LN = true, LX = true, Y1 = true, Y2 = true, G1 = true,
	W1 = true, WA = true, WL = true }

Moderation.random = math.random -- tests

local stats = { taken = 0, older = 0, same = 0, refused = 0, unlogged = 0, dropped = 0, blocked = 0, reports = 0 }
local toldMe = {}      -- [kind .. key .. at] = true: the notice about us was printed
local loginAt = nil
local guildOf, guildsKnown = {}, 0 -- [Name-Realm] = the guild its messages last named

local function Grey(s) return "|cff9d9d9d" .. s .. "|r" end
local function Gold(s) return "|cffffd200" .. s .. "|r" end
local function Red(s) return "|cffff6060" .. s .. "|r" end

-- The server's clock, the same second on every client (the words are dated by it).
local function Clock() return ns.Data and ns.Data.ServerTime and ns.Data.ServerTime() or ns.Now() end

-- A reason as it travels and shows: no "~", "|" or control byte, at most REASON_MAX bytes.
local function Clean(s)
	s = tostring(s or ""):gsub("[~|%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return ns.Cut(s, Moderation.REASON_MAX)
end

-- A character's name as the server writes it ("First Surname-Realm"); nil if it can't be one.
-- target: an empty input takes the player's target (the dialog, the slash command).
local function CharName(input, target)
	local name = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" and target then
		name = UnitIsPlayer and UnitIsPlayer("target") and ns.UnitFullName("target") or ""
	end
	if name == "" then return nil end
	name = ns.Normal(name)
	local short = ns.King and ns.King.CleanName and ns.King.CleanName(name)
	if not short then return nil end
	local realm = ns.RealmOf(name)
	if realm then realm = realm:gsub("[%s%-]", "") end
	return ns.FullName(short, realm ~= "" and realm or nil)
end
Moderation.CharName = CharName

-- A Sylvanistas guild's name as the census writes it; nil for anything else. target: an empty input
-- takes the guild of the player's target.
local function GuildName(input, target)
	local name = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^<(.*)>$", "%1")
	if name == "" and target and GetGuildInfo then name = GetGuildInfo("target") or "" end
	if name == "" then return nil end
	local clean = ns.King and ns.King.CleanGuild and ns.King.CleanGuild(name)
	if not clean then return nil end
	-- The spelling the census keeps (a guild is one whatever its case).
	return ns.Data and ns.Data.GuildKey and ns.Data.GuildKey(clean) or clean
end
Moderation.GuildName = GuildName

local function Key(kind, name) return tostring(name or ""):lower() end

-- The pinned King, whatever the case his name is written in and whatever realm it names: a
-- word's target travels as free text (only its sender is the server's spelling), and every
-- list here is kept in lower case. Never a word's target, never hidden, never told he is.
local function IsKing(name)
	if type(name) ~= "string" or name == "" then return false end
	if ns.IsKingCharacter(name) then return true end
	local pin = ns.KingCharacter()
	return pin ~= nil and ns.ShortName(name):lower() == pin:lower()
end
Moderation.IsKing = IsKing

-- How high a name stands among those who give words, whether or not a word hides it now: the
-- King (by his pinned name, as the server writes it) 3, a Steward 2, a Hand or a High
-- Councillor 1, anyone else 0.
local function Rank(name)
	if type(name) ~= "string" or name == "" then return 0 end
	if ns.IsKingCharacter(name) then return 3 end
	local K = ns.King
	if type(K) == "table" and not K.missing then
		if K.IsStewardName(name) then return 2 end
		if K.IsHandName(name) then return 1 end
	end
	return ns.IsHighCouncillor(name) == true and 1 or 0
end
Moderation.Rank = Rank

-- A word's weight: its giver's rank, no more than the rank of whoever passed it on (via). A
-- word only reaches one who gives words from higher up.
local function Weight(e)
	local w = Rank(e.by)
	if e.via then w = math.min(w, Rank(e.via)) end
	return w
end
local function Reaches(e, rank) return e ~= nil and (rank == 0 or Weight(e) > rank) end

-- The King's own word: heard from him (not passed on), or given on his own client.
local function KingsOwn(e) return type(e) == "table" and not e.via and ns.IsKingCharacter(e.by) end

-- A word this client's own player gave (on this client: never one passed on in his name).
local function Given(e)
	return type(e) == "table" and not e.via and type(ns.me) == "string" and tostring(e.by):lower() == ns.me:lower()
end

---------------------------------------------------------------------------
-- The words kept (ns.rdb.netoff, per realm group like the census) and who they hide
---------------------------------------------------------------------------

local function Store()
	local rdb = ns.rdb
	local s = rdb and rdb.netoff
	if type(s) ~= "table" then
		s = {}
		if rdb then rdb.netoff = s end
	end
	for kind in pairs(Moderation.MAX) do
		if type(s[kind]) ~= "table" then s[kind] = {} end
	end
	return s
end

-- Who is off now, looked up fast (every chat line asks): rebuilt after any change.
local index
local function Index()
	local s = Store()
	if index and index.store == s then return index end
	index = { store = s, c = {}, g = {}, short = {}, n = { c = 0, g = 0 } }
	for key, e in pairs(s.c) do
		if type(e) == "table" and e.off then
			index.c[key] = e
			local short = ns.ShortName(e.name):lower()
			index.short[short] = index.short[short] or {}
			table.insert(index.short[short], e)
			index.n.c = index.n.c + 1
		end
	end
	for key, e in pairs(s.g) do
		if type(e) == "table" and e.off then
			index.g[key] = e
			index.n.g = index.n.g + 1
		end
	end
	return index
end
local function Dirty() index = nil end

-- A name's own word, "on" words included (the index holds "off" words alone), or nil.
local function OwnWord(full) return Store().c[Key("c", full)] end

-- Does a name's own word stand above a word found on another name of its player (the same name
-- on another realm of the group, or a name its player linked)? It does when it weighs more, or
-- as much and is newer: then that word doesn't hide it (1.1, review: a rogue Hand's word
-- on the victim's alt, or on his name on the group's other realm, hid again one the King had
-- shown again).
local function Overrides(own, e)
	if type(own) ~= "table" or own == e then return false end
	local a, b = Weight(own), Weight(e)
	return a > b or (a == b and own.at > e.at)
end

-- The word taking this character itself off, or nil. On WoW: Forever a name is one across its
-- realm group (ns.splitNames): the same name on another realm of the group is the same player,
-- unless the name's own word stands above that one (Overrides).
function Moderation.Character(name)
	if type(name) ~= "string" or name == "" or IsKing(name) then return nil end
	local x = Index()
	if x.n.c == 0 then return nil end
	local full = ns.FullName(ns.Normal(name))
	local e = x.c[Key("c", full)]
	if e or not ns.splitNames then return e end
	local group = ns.GroupOf(ns.RealmOf(full) or ns.realm or "")
	local own = OwnWord(full)
	for _, y in ipairs(x.short[ns.ShortName(full):lower()] or {}) do
		if ns.GroupOf(ns.RealmOf(y.name) or ns.realm or "") == group and not Overrides(own, y) then return y end
	end
	return nil
end

-- The word taking this guild off, or nil (whatever the case it is spelled in).
function Moderation.Guild(guild)
	if type(guild) ~= "string" or guild == "" then return nil end
	local x = Index()
	if x.n.g == 0 then return nil end
	return x.g[Key("g", guild)]
end

-- The word hiding this name: its own, or one on a name its player linked (Alts.lua), and the
-- name it is on; nil for anyone else, and always for the pinned King. One who gives words is
-- hidden only by a word from higher up (a councillor's word on a Steward's alt hides no Steward).
-- A word on a linked name doesn't hide one whose own word stands above it (Overrides: the King
-- showed him again, and a Hand's word on his alt doesn't hide him again).
function Moderation.Hidden(name)
	if type(name) ~= "string" or name == "" or IsKing(name) then return nil end
	if Index().n.c == 0 then return nil end
	local rank
	local function Counts(e)
		if not e then return false end
		rank = rank or Rank(name)
		return Reaches(e, rank)
	end
	local e = Moderation.Character(name)
	if Counts(e) then return e, e.name end
	local linked = ns.Alts and ns.Alts.Linked and ns.Alts.Linked(name)
	local own
	for _, other in ipairs(type(linked) == "table" and linked or {}) do
		e = Moderation.Character(other)
		if Counts(e) then
			if own == nil then own = OwnWord(ns.FullName(ns.Normal(name))) or false end
			if not Overrides(own, e) then return e, other end
		end
	end
	return nil
end

-- The guild a sender's own messages named last (a chat line, a layer, a decree, a vote, his own
-- census report): what the hop's whispers, which name none, are checked against. Only the
-- server's sender name: never a name written inside someone else's message.
function Moderation.NoteGuild(sender, guild)
	if type(sender) ~= "string" or sender == "" or type(guild) ~= "string" or guild == "" then return end
	local who = ns.FullName(sender)
	if guildOf[who] == guild then return end
	if guildOf[who] == nil then
		if guildsKnown >= Moderation.GUILDS_KNOWN then wipe(guildOf); guildsKnown = 0 end
		guildsKnown = guildsKnown + 1
	end
	guildOf[who] = guild
end
function Moderation.GuildOf(sender)
	if type(sender) ~= "string" or sender == "" then return nil end
	local who = ns.FullName(sender)
	if ns.Roster and ns.Roster.RankOf and ns.Roster.RankOf(who) then return GetGuildInfo("player") end
	return guildOf[who]
end

-- For every surface: does a word hide what this sender sends (in the name of `guild`)? The word
-- and the name or guild it is on. Never the pinned King; one who gives words, only from higher up.
function Moderation.Hides(sender, guild)
	if type(sender) == "string" and IsKing(sender) then return nil end
	local e, on = Moderation.Hidden(sender)
	if e then return e, on end
	if guild then Moderation.NoteGuild(sender, guild) end
	if Index().n.g == 0 then return nil end
	local rank
	local function Counts(w)
		if not w then return false end
		rank = rank or Rank(sender)
		return Reaches(w, rank)
	end
	e = Moderation.Guild(guild)
	if Counts(e) then return e, guild end
	local known = Moderation.GuildOf(sender)
	e = known and Moderation.Guild(known)
	if Counts(e) then return e, known end
	return nil
end

-- Our own guild is off: the word, or nil.
function Moderation.OwnGuildOff()
	return Moderation.Guild(GetGuildInfo and GetGuildInfo("player") or nil)
end

-- This client's own character (or a name its player linked), or its guild, is off: the word, or
-- nil. (A guild's word from lower down leaves one who gives words speaking, as Hides does.)
function Moderation.SelfOff()
	if ns.me and IsKing(ns.me) then return nil end
	local e = ns.me and Moderation.Hidden(ns.me)
	if e then return e end
	e = Moderation.OwnGuildOff()
	if e and ns.me and not Reaches(e, Rank(ns.me)) then return nil end
	return e
end

-- Anything off at all (cheap): the chats' history is only copied when so.
function Moderation.Any()
	local x = Index()
	return x.n.c + x.n.g > 0
end

---------------------------------------------------------------------------
-- Who may give a word
---------------------------------------------------------------------------

-- The King by his pinned name, a Steward of the signed titles list, a Hand of the King's list
-- or a Steward's, a councillor of the signed council list: as this client knows them now. A
-- name that is off gives no word (nor can it put itself back on); only a word from higher up
-- takes one of them off (Hidden).
function Moderation.IsIssuer(name)
	local rank = Rank(name)
	if rank == 0 then return false end
	return rank == 3 or Moderation.Hidden(name) == nil
end

function Moderation.CanIssue()
	return ns.me ~= nil and ns.IsMember() and Moderation.IsIssuer(ns.me)
end

---------------------------------------------------------------------------
-- Taking a word
---------------------------------------------------------------------------

local function Count(list)
	local n = 0
	for _ in pairs(list) do n = n + 1 end
	return n
end

-- Room for one more: the oldest word putting a name back on goes; none, no room, except for the
-- King's own word (king), for which the oldest word taking a name off that is not his own goes:
-- a list filled by anyone never shuts the King out. Never a word that weighs more than the new
-- one (weight: 1.1, review: a rogue Hand who filled the list pushed out the King's word
-- showing a name again, then hid that name anyway).
local function MakeRoom(list, kind, king, weight)
	if Count(list) < Moderation.MAX[kind] then return true end
	local oldest, oldestOff
	for key, e in pairs(list) do
		if not e.off then
			if (not oldest or e.at < list[oldest].at) and Weight(e) <= weight then oldest = key end
		elseif king and not KingsOwn(e) and (not oldestOff or e.at < list[oldestOff].at) and Weight(e) <= weight then
			oldestOff = key
		end
	end
	local drop = oldest or oldestOff
	if not drop then return false end
	list[drop] = nil
	return true
end

-- A word as it is kept, checked: nil and why when it can't be one.
function Moderation.Entry(kind, name, off, at, by, reason)
	if not Moderation.KINDS[kind] then return nil, "kind" end
	if kind == "c" then
		name = CharName(name)
		if not name then return nil, "name" end
		if IsKing(name) then return nil, "the pinned King" end
	else
		name = GuildName(name)
		if not name then return nil, "not a Sylvanistas guild" end
		if ns.IsKingGuild(name) then return nil, "the King's guild" end
	end
	by = CharName(by)
	if not by then return nil, "issuer" end
	at = tonumber(at)
	if not at or at < 1 or at ~= math.floor(at) or at > Clock() + Moderation.DATE_AHEAD then return nil, "time" end
	reason = Clean(reason)
	if off and reason == "" then return nil, "no reason" end
	return { kind = kind, name = name, off = off and true or false, at = at, by = by, reason = reason }
end

local function Label(e)
	if e.kind == "g" then return "<" .. e.name .. ">" end
	return ns.DisplayName(e.name) or e.name
end

-- Is this word about our own character, a name our player linked, or our guild? Never on the
-- King's own client (nothing hides him, and no other's reason reaches his screen that way).
local function AboutMe(e)
	if ns.me and IsKing(ns.me) then return false end
	if e.kind == "g" then
		local mine = GetGuildInfo and GetGuildInfo("player")
		return type(mine) == "string" and Key("g", mine) == Key("g", e.name)
	end
	if not ns.me then return false end
	local key = Key("c", e.name)
	if Key("c", ns.me) == key then return true end
	local linked = ns.Alts and ns.Alts.Linked and ns.Alts.Linked(ns.me)
	for _, other in ipairs(type(linked) == "table" and linked or {}) do
		if Key("c", ns.FullName(other)) == key then return true end
	end
	return false
end

-- The date of a word, by the server's clock ("2026-09-29 21:04").
local function When(e) return date and date("%Y-%m-%d %H:%M", e.at) or tostring(e.at) end
Moderation.When = When

-- Who gave a word, and who passed it on when someone else did (the server's name for that one).
-- label: how a name shows (cut short on the King's stream).
local function ByText(e, label)
	label = label or function(name) return ns.DisplayName(name) or "?" end
	if e.via then return L.NETOFF_VIA:format(label(e.by), label(e.via)) end
	return label(e.by)
end

-- What our own client says when a word hides us (our character, or our guild).
function Moderation.YouText(e)
	local reason, by = e.reason ~= "" and e.reason or "-", ByText(e)
	if e.kind == "g" then return L.NETOFF_YOUR_GUILD:format(e.name, reason, by, When(e)) end
	return L.NETOFF_YOU:format(reason, by, When(e))
end

local function Notify(e, was)
	if not AboutMe(e) then return end
	-- Back on: only when this client had us off (a word it never held is no news).
	if not e.off and not (type(was) == "table" and was.off) then return end
	local mark = e.kind .. Key(e.kind, e.name) .. e.at
	if toldMe[mark] then return end
	toldMe[mark] = true
	if e.off then return ns.Print(Red(Moderation.YouText(e))) end
	ns.Print(e.kind == "g" and L.NETOFF_YOUR_GUILD_BACK or L.NETOFF_YOU_BACK)
end

-- The same word again (a repeat): its date, off or on, giver and reason all the same.
local function Same(a, b)
	return type(a) == "table" and type(b) == "table" and a.at == b.at and a.off == b.off
		and Key("c", a.by) == Key("c", b.by) and a.reason == b.reason
end

-- Two different words of the same second: which one every client keeps, whatever came first.
-- The King's own first; else the one taking the name off; else by its giver's name, then its
-- reason.
local function Outranks(e, kept)
	local a, b = KingsOwn(e), KingsOwn(kept)
	if a ~= b then return a end
	if e.off ~= kept.off then return e.off end
	local x, y = Key("c", e.by), Key("c", kept.by)
	if x ~= y then return x < y end
	return tostring(e.reason) < tostring(kept.reason)
end

-- "taken", "older" (ours is newer), "same" (the same word: a repeat), "tie", "outranked" (ours
-- comes from higher up) or "full".
-- 1.1 review (the reviewer): no word replaces one from higher up (Weight: the King's, then a Steward's,
-- then a Hand's or a councillor's), whatever its date, so a rogue Hand never wins an edit war with
-- the King's undo; a word from higher up replaces a lower one whatever its date, so every client
-- keeps the same word whatever came first. Between words of the same weight the newest wins.
local function Take(e)
	local list = Store()[e.kind]
	local key = Key(e.kind, e.name)
	local kept = list[key]
	if type(kept) == "table" then
		if Same(e, kept) then
			kept.heard = ns.Now()
			return "same", kept
		end
		local ours, held = Weight(e), Weight(kept)
		if ours < held then return "outranked", kept end
		if ours == held then
			if e.at < kept.at then return "older", kept end
			if e.at == kept.at and not Outranks(e, kept) then return "tie", kept end
		end
	elseif not MakeRoom(list, e.kind, KingsOwn(e), Weight(e)) then
		return "full"
	end
	e.heard = ns.Now()
	list[key] = e
	Dirty()
	ns.Log("net-off: %s %s %s by %s%s (%s)", e.kind, e.name, e.off and "off" or "back on", e.by,
		e.via and (", passed on by " .. e.via) or "", e.reason ~= "" and e.reason or "-")
	Notify(e, kept)
	ns.Fire("NETOFF_CHANGED", e)
	ns.Fire("DATA_CHANGED")
	ns.Fire("DECREES_CHANGED")
	return "taken", e
end

local function Word(e)
	local msg = ("O1~%s~%s~%d~%s~%s~%s"):format(e.kind, e.off and "1" or "0", e.at, e.name, e.by, e.reason or "")
	return #msg <= 250 and msg or msg:sub(1, 250)
end
Moderation.Word = Word

local function Send(e)
	e.heard = ns.Now()
	-- Logged (the issuer's own words: the server keeps them). One per name waits in the queue.
	ns.Comm.Send("CHANNEL", Word(e), "netoff:" .. e.kind .. ":" .. Key(e.kind, e.name), nil, true)
end

-- The highest rank among a character and the names its player linked: a word on an alt reaches
-- its main, so aiming at one who gives words through an alt needs the same rank.
local function TargetRank(name)
	local rank = Rank(name)
	local linked = ns.Alts and ns.Alts.Linked and ns.Alts.Linked(name)
	for _, other in ipairs(type(linked) == "table" and linked or {}) do rank = math.max(rank, Rank(other)) end
	return rank
end
Moderation.TargetRank = TargetRank

local function Refuse(sender, why)
	stats.refused = stats.refused + 1
	return ns.Log("net-off word from %s ignored: %s", sender, why)
end

function Moderation.Handle(dist, sender, text)
	if dist ~= "CHANNEL" then return end
	-- An issuer's words come through the logged API, where this client has it (a chat line's rule).
	if C_ChatInfo and C_ChatInfo.SendAddonMessageLogged and ns.Comm.DeliveredLogged and not ns.Comm.DeliveredLogged() then
		stats.unlogged = stats.unlogged + 1
		return
	end
	local kind, off, at, name, by, reason = tostring(text):match("^O1~(%a)~([01])~(%d+)~([^~]+)~([^~]+)~?(.*)$")
	if not kind or not Moderation.KINDS[kind] then return end
	sender = ns.FullName(sender)
	if not Moderation.IsIssuer(sender) then
		return Refuse(sender, "not the King, his Steward, a Hand or a High Councillor here")
	end
	local e, why = Moderation.Entry(kind, name, off == "1", at, by, reason)
	if not e then return Refuse(sender, tostring(why)) end
	local firstHand = Key("c", sender) == Key("c", e.by)
	-- Passed on for someone else: taken (or counted as a repeat) only while its giver may give one
	-- here too, so the words of one who no longer may fade whoever repeats them.
	if not firstHand and not Moderation.IsIssuer(e.by) then return Refuse(sender, "passed on for " .. e.by .. ", who gives no word here") end
	-- A repeat of the word held here: heard (its giver's own repeat shows it first-hand).
	local kept = Store()[kind][Key(kind, e.name)]
	if Same(e, kept) then
		kept.heard = ns.Now()
		if firstHand then kept.via = nil end
		stats.same = (stats.same or 0) + 1
		return
	end
	if firstHand then
		e.by = sender -- (the server's spelling)
	else
		e.via = sender -- who passed it on stays with it (shown; the server stamps that name)
	end
	-- Aimed at one who gives words (or at a name his player linked): only from higher up, its
	-- giver and whoever passed it on both.
	if kind == "c" then
		local target = TargetRank(e.name)
		if target > 0 and Weight(e) <= target then return Refuse(sender, "aimed at " .. e.name .. ", who ranks as high") end
	end
	local result, held = Take(e)
	stats[result] = (stats[result] or 0) + 1
	-- Ours is newer, or from higher up, and our own player gave it: his client answers with it at
	-- its next round.
	if (result == "older" or result == "outranked") and Given(held) and Moderation.CanIssue() then held.heard = ns.Now() - Moderation.REPEAT - Moderation.JITTER end
end
ns.Comm.Handle("O1", function(...) Moderation.Handle(...) end)

-- A census report of a guild that is off: not taken (Data.Receive). Its reporter is remembered as
-- that guild's (the hop checks his whispers against it): the server stamps his name. The names
-- written inside it are anyone's word, and are not (a forged report would hide innocents).
function Moderation.Report(r, sender)
	if type(r) ~= "table" or type(r.guild) ~= "string" then return false end
	Moderation.NoteGuild(sender, r.guild)
	if not Moderation.Guild(r.guild) then return false end
	stats.reports = stats.reports + 1
	return true
end

---------------------------------------------------------------------------
-- Giving a word (the Decrees tab, /syl netoff, /syl neton)
---------------------------------------------------------------------------

-- Takes `input` off (off true, with a reason) or puts it back on: this client's word, kept and
-- sent at once. kind "c" a character (the target's by default), "g" a Sylvanistas guild (the
-- target's by default). Returns true when given.
function Moderation.Set(kind, input, off, reason)
	if not ns.IsMember() then ns.Print(L.MEMBERS_ONLY) return false end
	if not Moderation.CanIssue() then ns.Print(L.NETOFF_ONLY) return false end
	if not Moderation.KINDS[kind] then return false end
	local name
	if kind == "g" then
		name = GuildName(input, true)
		if not name then ns.Print(L.NETOFF_GUILD_BAD) return false end
		if ns.IsKingGuild(name) then ns.Print(L.NETOFF_NOT_KING_GUILD) return false end
	else
		name = CharName(input, true)
		if not name then ns.Print(L.NETOFF_WHO_BAD) return false end
		if IsKing(name) then ns.Print(L.NETOFF_NOT_KING) return false end
		if Key("c", name) == Key("c", ns.me) then ns.Print(L.NETOFF_NOT_SELF) return false end
		-- One who gives words (or a name his player linked): only from higher up.
		local target = TargetRank(name)
		if target == 3 then ns.Print(L.NETOFF_NOT_KING) return false end -- (a name the King linked as his alt)
		if target > 0 and Rank(ns.me) <= target then ns.Print(L.NETOFF_OUTRANKED:format(Label({ kind = kind, name = name }))) return false end
	end
	reason = Clean(reason)
	if off and reason == "" then ns.Print(L.NETOFF_REASON_NEEDED) return false end
	local kept = Store()[kind][Key(kind, name)]
	local label = Label({ kind = kind, name = name })
	if not off and not (type(kept) == "table" and kept.off) then ns.Print(L.NETOFF_NOT_OFF:format(label)) return false end
	local at = Clock()
	if type(kept) == "table" and kept.at >= at then at = kept.at + 1 end
	local e = { kind = kind, name = name, off = off and true or false, at = at, by = ns.me, reason = reason }
	local result = Take(e)
	-- (1.1 review: a word from higher up holds that name; ours would not replace it anywhere.)
	if result == "outranked" then ns.Print(L.NETOFF_HELD_HIGHER:format(label)) return false end
	if result ~= "taken" then ns.Print(L.NETOFF_FULL) return false end
	Send(e)
	if kind == "g" then
		ns.Print(off and L.NETOFF_GUILD_DONE:format(label, reason) or L.NETOFF_GUILD_UNDONE:format(label))
	else
		ns.Print(off and L.NETOFF_DONE:format(label, reason) or L.NETOFF_UNDONE:format(label))
	end
	return true
end

-- /syl netoff [guild] [name[: reason]] and /syl neton [guild] <name>: with no reason yet, the
-- dialog asks.
function Moderation.Slash(off, rest)
	rest = tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if off and rest == "" then return Moderation.PrintList() end
	local kind, target = "c", rest
	local word, after = rest:match("^(%S+)%s*(.*)$")
	if word and (word:lower() == "guild" or word:lower() == "guilda") then kind, target = "g", after end
	local name, reason = target:match("^([^:]*):%s*(.*)$")
	if not name then name, reason = target, nil end
	if not off then return Moderation.Set(kind, name, false, reason or "") end
	if reason and reason ~= "" then return Moderation.Set(kind, name, true, reason) end
	return Moderation.Ask(kind, name)
end

-- The words that take a character or a guild off now, newest first.
function Moderation.List()
	local out = {}
	for kind in pairs(Moderation.KINDS) do
		for _, e in pairs(Store()[kind]) do
			if type(e) == "table" and e.off then out[#out + 1] = e end
		end
	end
	table.sort(out, function(a, b)
		if a.at ~= b.at then return a.at > b.at end
		if a.kind ~= b.kind then return a.kind < b.kind end
		return a.name < b.name
	end)
	return out
end

-- An issuer's name on the King's screen: cut short while the council's names are hidden there
-- (his stream), as every councillor's is. A reason that is not his own word (given on his
-- client, or heard from him: never one only written in his name) stays hidden there too until
-- he shows the council's names (the eye in the Realm): nothing another player writes reaches
-- his screen on its own.
local function IssuerLabel(by)
	local shown = ns.DisplayName(by) or "?"
	if ns.CouncilMasked() and not ns.IsKingCharacter(by) then return ns.MaskName(shown) end
	return shown
end
local function ReasonShown(e)
	if ns.CouncilMasked() and not KingsOwn(e) then return L.NETOFF_REASON_HIDDEN end
	return e.reason ~= "" and e.reason or "-"
end
Moderation.ReasonShown = ReasonShown

function Moderation.PrintList()
	local list = Moderation.List()
	ns.Print(L.NETOFF_LIST:format(#list))
	for _, e in ipairs(list) do
		print(("  %s  -  %s  (%s, %s)"):format(Label(e), ReasonShown(e), ByText(e, IssuerLabel), When(e)))
	end
	if Moderation.CanIssue() then print(L.HELP_NETOFF) end
end

-- The Decrees tab's section: who is hidden and which guilds are off, why, by whom and when; the
-- issuers' buttons.
function Moderation.Lines()
	local lines = {}
	local issuer = Moderation.CanIssue()
	local list = Moderation.List()
	local mine = Moderation.SelfOff()
	if #list == 0 and not issuer and not mine then return lines end
	lines[#lines + 1] = { header = true, text = L.NETOFF_TITLE, right = #list > 0 and Grey(tostring(#list)) or nil,
		tooltip = function(tt)
			tt:AddLine(L.NETOFF_TITLE, 1, 0.82, 0)
			tt:AddLine(L.NETOFF_TIP, 1, 1, 1, true)
			tt:AddLine(L.NETOFF_GUILD_TIP, 1, 1, 1, true)
		end }
	if mine then
		lines[#lines + 1] = { indent = 1, text = Red(mine.kind == "g" and L.NETOFF_YOUR_GUILD_SHORT or L.NETOFF_YOU_SHORT),
			tooltip = function(tt) tt:AddLine(Moderation.YouText(mine), 1, 1, 1, true) end }
	end
	for _, e in ipairs(list) do
		lines[#lines + 1] = {
			indent = 1, text = Label(e), right = Grey(When(e)),
			tooltip = function(tt)
				tt:AddLine(Label(e), 1, 0.82, 0)
				if e.kind == "g" then tt:AddLine(L.NETOFF_GUILD_OFF, 1, 0.5, 0.5, true) end
				tt:AddLine(L.NETOFF_REASON:format(ReasonShown(e)), 1, 1, 1, true)
				tt:AddLine(L.NETOFF_BY:format(ByText(e, IssuerLabel), When(e)), 0.7, 0.7, 0.7)
				tt:AddLine(L.NETOFF_LAPSES:format(date and date("%Y-%m-%d", e.at + Moderation.OFF_KEEP) or tostring(e.at + Moderation.OFF_KEEP)), 0.6, 0.6, 0.6, true)
				if issuer then tt:AddLine(L.NETOFF_CLICK_UNDO, 0.6, 0.6, 0.6, true) end
			end,
			onClick = issuer and function() ns.ShowDialog("SYLVANISTAS_NETOFF_UNDO", Label(e), nil, { kind = e.kind, name = e.name }) end or nil,
		}
	end
	if issuer then
		lines[#lines + 1] = { indent = 1, text = Gold("+ " .. L.NETOFF_ADD), onClick = function() Moderation.Ask("c") end }
		lines[#lines + 1] = { indent = 1, text = Gold("+ " .. L.NETOFF_ADD_GUILD), onClick = function() Moderation.Ask("g") end }
	end
	lines[#lines].gapAfter = true
	return lines
end

-- The dialogs: who (a name or the target; a guild or the target's), then why.
function Moderation.Ask(kind, name)
	if not Moderation.CanIssue() then return ns.Print(L.NETOFF_ONLY) end
	local pick = kind == "g" and GuildName or CharName
	local full = name and name ~= "" and pick(name) or nil
	if name and name ~= "" and not full then return ns.Print(kind == "g" and L.NETOFF_GUILD_BAD or L.NETOFF_WHO_BAD) end
	if full then return ns.ShowDialog("SYLVANISTAS_NETOFF_WHY", Label({ kind = kind, name = full }), nil, { kind = kind, name = full }) end
	ns.ShowDialog(kind == "g" and "SYLVANISTAS_NETOFF_GUILD" or "SYLVANISTAS_NETOFF_WHO", nil, nil, { kind = kind })
end

local function Next(data, text)
	local kind = type(data) == "table" and data.kind == "g" and "g" or "c"
	local full = kind == "g" and GuildName(text, true) or CharName(text, true)
	if not full then return ns.Print(kind == "g" and L.NETOFF_GUILD_BAD or L.NETOFF_WHO_BAD) end
	ns.ShowDialog("SYLVANISTAS_NETOFF_WHY", Label({ kind = kind, name = full }), nil, { kind = kind, name = full })
end
local function Give(data, text)
	if type(data) ~= "table" or not data.name then return end
	Moderation.Set(data.kind or "c", data.name, true, text)
end

-- Who (a character, or a guild): the name typed, or the target's.
local function WhoDialog(prompt, width, letters, default)
	return {
		text = prompt,
		button1 = L.WRIT_NEXT,
		button2 = CANCEL or "Cancel",
		hasEditBox = true,
		editBoxWidth = width,
		maxLetters = letters,
		OnShow = function(self)
			local eb = self.editBox or self.EditBox
			if eb then
				eb:SetText(default() or "")
				eb:SetFocus()
			end
		end,
		OnAccept = function(self, data)
			local eb = self.editBox or self.EditBox
			ns.SafeCall("net-off who", Next, data or self.data, eb and eb:GetText())
		end,
		EditBoxOnEnterPressed = function(self, data)
			local parent = self:GetParent()
			ns.SafeCall("net-off who", Next, data or (parent and parent.data), self:GetText())
			parent:Hide()
		end,
		EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}
end
StaticPopupDialogs["SYLVANISTAS_NETOFF_WHO"] = WhoDialog(L.NETOFF_WHO_PROMPT, 240, 60, function()
	local target = UnitIsPlayer and UnitIsPlayer("target") and ns.UnitFullName("target")
	return target and ns.DisplayName(target) or ""
end)
StaticPopupDialogs["SYLVANISTAS_NETOFF_GUILD"] = WhoDialog(L.NETOFF_GUILD_PROMPT, 240, 40, function()
	local guild = GetGuildInfo and GetGuildInfo("target")
	return guild and ns.IsFederation(guild) and guild or ""
end)

StaticPopupDialogs["SYLVANISTAS_NETOFF_WHY"] = {
	text = L.NETOFF_WHY_PROMPT,
	button1 = OKAY or "OK",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 320,
	maxLetters = Moderation.REASON_MAX,
	OnShow = function(self)
		local eb = self.editBox or self.EditBox
		if eb then eb:SetText(""); eb:SetFocus() end
	end,
	OnAccept = function(self, data)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("net-off why", Give, data or self.data, eb and eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self, data)
		local parent = self:GetParent()
		ns.SafeCall("net-off why", Give, data or (parent and parent.data), self:GetText())
		parent:Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs["SYLVANISTAS_NETOFF_UNDO"] = {
	text = L.NETOFF_UNDO_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function(self, data)
		data = data or (self and self.data)
		if type(data) == "table" then ns.SafeCall("net-off undo", Moderation.Set, data.kind, data.name, false, "") end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Keeping the list alive: prune, repeat
---------------------------------------------------------------------------

-- Does a word still live, by the server's clock? One taking a name off lapses OFF_KEEP after it
-- was given, one putting it back on ON_KEEP after (never sooner: an older word never comes back).
local function Live(e, clock)
	return clock - e.at <= (e.off and Moderation.OFF_KEEP or Moderation.ON_KEEP)
end

-- Words past their time go, on every client. An "off" word nobody repeated for STALE lapses here
-- too, unless this client's own player gave it and still may give words (it repeats it, after
-- WARMUP): the words of one who may no longer give any (hidden, or off the lists), or who has not
-- been online to repeat them, fade from the army.
function Moderation.Prune()
	local now, clock = ns.Now(), Clock()
	local issuer = Moderation.CanIssue()
	local drops = {}
	for kind in pairs(Moderation.MAX) do
		for key, e in pairs(Store()[kind]) do
			if type(e) ~= "table" or type(e.at) ~= "number" or type(e.name) ~= "string" or not Live(e, clock)
				or (e.off and now - (tonumber(e.heard) or 0) > Moderation.STALE and not (issuer and Given(e) and Moderation.IsIssuer(e.by))) then
				drops[#drops + 1] = { kind, key }
			end
		end
	end
	for _, d in ipairs(drops) do
		Store()[d[1]][d[2]] = nil
		stats.dropped = stats.dropped + 1
	end
	if #drops > 0 then
		Dirty()
		ns.Fire("DATA_CHANGED")
	end
end

-- Every minute: an issuer's client repeats the words due, a few at a time; a word it held unheard
-- waits until it has been online WARMUP (a newer word may come). The army repeats
-- REPEATS_A_MINUTE words a minute at most, however long the list: a longer one is repeated less
-- often. Only a word its own player gave (1.1 review, the reviewer: never one heard, whose giver it
-- names: a word passed on in the King's name went out from his client as his own, at his rank),
-- while he may still give words, and one the others would take from this client (a word aimed
-- at one who gives words, only from higher up).
function Moderation.Tick()
	Moderation.Prune()
	if not Moderation.CanIssue() then return 0 end
	local now, clock, sent = ns.Now(), Clock(), 0
	local warm = loginAt == nil or now - loginAt >= Moderation.WARMUP
	local words = 0
	for kind in pairs(Moderation.KINDS) do words = words + Count(Store()[kind]) end
	local spread = words * 60 / Moderation.REPEATS_A_MINUTE
	local mine = Rank(ns.me)
	for kind in pairs(Moderation.KINDS) do
		for _, e in pairs(Store()[kind]) do
			if sent >= Moderation.PER_TICK then return sent end
			if Given(e) then
				e.jitter = e.jitter or Moderation.random(0, Moderation.JITTER)
				local every = math.max(e.off and Moderation.REPEAT or Moderation.ON_EVERY, spread)
				local age = now - (tonumber(e.heard) or 0)
				if Live(e, clock) and age >= every + e.jitter and (warm or age <= Moderation.STALE) and Moderation.IsIssuer(e.by) then
					local target = e.kind == "c" and TargetRank(e.name) or 0
					if target == 0 or math.min(Rank(e.by), mine) > target then
						Send(e)
						sent = sent + 1
					end
				end
			end
		end
	end
	return sent
end

-- The backstop in Comm (1.1): a client whose own character or guild is off sends none of BLOCKED,
-- nor a call of the Throne's that every receiver would drop (King.HIDDEN_CALLS). Its setter's
-- cancel of an entry on the King's week (a D of 0 seconds; Week.Cancel sends one for his own
-- entry alone) still goes: every client takes it for his own entry (1.1 review: held, the entry
-- showed again everywhere once he was shown again).
local function HiddenCall(msg)
	local K = ns.King
	if msg:find("^T1~D~%d+~[^~]*~0~") then return false end
	return msg:sub(1, 3) == "T1~" and type(K) == "table" and type(K.HIDDEN_CALLS) == "table" and K.HIDDEN_CALLS[msg:sub(4, 4)] == true
end
function Moderation.Blocks(msg)
	if type(msg) ~= "string" or msg:sub(3, 3) ~= "~" then return false end
	if not Moderation.BLOCKED[msg:sub(1, 2)] and not HiddenCall(msg) then return false end
	if not Moderation.SelfOff() then return false end
	stats.blocked = stats.blocked + 1
	return true
end

function Moderation.Stats() return stats end

-- /syl status: what this client holds.
function Moderation.StatusLine()
	local x = Index()
	local own = Moderation.OwnGuildOff()
	return ("%d characters and %d guilds off here%s  |  you give words: %s  |  words taken %d, repeats %d, older %d, refused %d, unlogged %d, sends held %d, reports dropped %d"):format(
		x.n.c, x.n.g, own and " (your guild among them)" or "", tostring(Moderation.CanIssue()), stats.taken or 0, stats.same or 0,
		stats.older or 0, stats.refused, stats.unlogged, stats.blocked, stats.reports)
end

-- The words kept by this client in an earlier session: checked again (the SavedVariables can be
-- edited), at load.
function Moderation.Load()
	Dirty()
	local s = Store()
	for kind, list in pairs(s) do
		if not Moderation.MAX[kind] or type(list) ~= "table" then
			s[kind] = nil
		else
			for key, e in pairs(list) do
				local ok = type(e) == "table" and Moderation.Entry(kind, e.name, e.off, e.at, e.by, e.reason)
				if not ok or Key(kind, ok.name) ~= key then
					list[key] = nil
				else
					ok.heard = tonumber(e.heard) or 0
					-- Who passed it on, when someone did (the King's own word is one that was not).
					ok.via = e.via ~= nil and (CharName(e.via) or "?") or nil
					list[key] = ok
				end
			end
		end
	end
	Dirty()
end
ns.On("INIT", function() Moderation.Load() end)

ns.On("LOGIN", function()
	loginAt = ns.Now()
	ns.Every(60, "net-off", Moderation.Tick)
	-- Once the guild and the lists are known: tell the player if a word hides them.
	ns.After(30, "net-off notice", function()
		local e = Moderation.SelfOff()
		if e then Notify(e) end
	end)
end)

-- Tests start from a clean state.
function Moderation.Reset()
	index, loginAt = nil, nil
	wipe(toldMe)
	wipe(guildOf)
	guildsKnown = 0
	for k in pairs(stats) do stats[k] = 0 end
end
