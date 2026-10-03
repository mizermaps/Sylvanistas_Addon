local ADDON, ns = ...
local L = ns.L

-- The King's key rotation (1.1, Fern's request #8, its second part): a leaked realm key (/syl key)
-- shut without teaching everyone /syl key by hand. The King (his pinned character) or one of his
-- Stewards, acting for him (the author's signed list names them; 1.1: the King rarely runs the
-- addon's tools himself), never a Hand or an officer, presses Rotate on the Throne; his addon
-- makes a new key (never typed,
-- never shown: not on his stream either). He then picks which guilds get it: those his own /who
-- saw are checked (the server's word that a guild of that name exists: a census row alone is
-- anyone's report, and two characters on the leaked channel can make up a guild and its Lords),
-- the others wait for his click; nothing is sent before he hands it out. It goes where only its
-- receivers read it, never on the Sylvanistas channel (public, or sealed with the key that leaked):
--   K3~<epoch>~<key>[~<h1.h2.h3>]
--                      by whisper from the King (or his Steward) to every Lord and Captain of the
--                      guilds he picked
--                      the census confirms online (Data.KnownRank) whom his own /who saw in that
--                      guild (Who.SeenGuild, the server's word: two characters on the leaked
--                      channel can name themselves a real guild's Lord and Captain in the census),
--                      and over GUILD from each of
--                      them (their officers) to their own guild; K1~<key> with it there, for
--                      guildmates before 1.1. The hashes: the keys it replaces (at most 3).
--   K4~<epoch>~<guild> a Lord's or Captain's addon tells the King it has it (a whisper); his
--                      Throne counts it only from a name his client whispered the key to, and
--                      under the guild it whispered him for (its own record), never the one named.
--   K5~<epoch held>    over GUILD, after login: a guildmate asks whether a newer key exists;
--                      an officer holding one answers with K3.
-- The epoch is the server's second the key was made (or an officer typed one, 1.1): every 1.1
-- client keeps the newest, and remembers the keys a newer one replaced (their hashes): a key
-- without an epoch (K1 alone, from an officer before 1.1) is taken as ever, unless it is one of
-- those. So a 1.0 officer's K1 of the leaked key no longer pulls his 1.1 guildmates back, and a
-- 1.0 officer who re-keys his guild by hand still moves all of it; an older key with an epoch
-- does not undo his re-key either. A K3 takes a whisper from the King's pinned name or a Steward's
-- (the signed list), or GUILD from our own officers (the server's roster), and never the channel.
-- Two rotations at once (the King's and a Steward's): every client keeps the newer epoch.
-- Whoever is in a guild that gets it has it too (its officers hand it to the whole guild): the
-- rotation leaves behind whoever holds the old key outside the guilds picked.
-- The King's client hands the key out a few whispers at a time, never more than the send queue
-- has room for (its other messages keep their place), and counts a whisper as sent once it left.
-- /who goes from a click alone: his click on a guild, or on the Throne's /who line, searches the
-- next one picked whose Lords and Captains it has not seen there yet, then each of them by name
-- (Keys.Confirm); with the gamepad UI his click on the /who line searches a guild picked plainly,
-- never a name. What it saw is kept with the rotation (rot.saw), through a /reload too.
-- It keeps handing it to Lords and Captains who come online for GRACE, on the old channel (a
-- little longer while some picked still wait for their whisper), then moves (with his guild);
-- "Move now" sooner. Guilds with no officer online in that time stay on the old channel until one
-- of theirs types the key by hand; the Throne says how many acknowledged. Older clients ignore
-- K3, K4 and K5.

local Keys = {}
ns.Keys = Keys

Keys.GRACE = 600          -- the King's client hands the new key out this long before it moves
Keys.GRACE_MORE = 600     -- ...and up to this much longer while Lords and Captains picked wait for their whisper
Keys.RESEND = 300         -- the same Lord or Captain is whispered again after this long without an answer
Keys.MAX_WHISPERS = 60    -- whispers a round at most (the queue sends one each 1.2 s)
Keys.QUEUE_SPARE = 20     -- ...and never more than leaves this much of the send queue free
Keys.QUEUE_WAIT = 120     -- a whisper waiting this long in the queue (lost there) is handed again
Keys.DATE_AHEAD = 60      -- an epoch further ahead of the server's clock is not taken
Keys.ANSWER_GAP = 60      -- an officer answers a guildmate's ask (K5) once a minute at most
Keys.ASK_AFTER = 25       -- the ask goes this long after login
Keys.ONLINE_FRESH = 240   -- a Lord or Captain counts as online from a report this recent (a whisper to
                          -- someone who logged off since shows the King the game's "no player named" line)
Keys.RETIRED_MAX = 16     -- keys replaced by a newer epoch this client remembers (their hashes)
Keys.RETIRES_SENT = 3     -- ...and a K3 names at most this many
Keys.WHO_FRESH = 30 * 60  -- a Lord or Captain is whispered while his /who saw him in that guild this recently

local stats = { rotated = 0, taken = 0, refused = 0, whispered = 0, acks = 0, relayed = 0, answered = 0, legacy = 0 }
local lastAnswer = -math.huge

local READY = "|TInterface\\RaidFrame\\ReadyCheck-Ready:13:13|t "
local NOT_READY = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:13:13|t "

local function Clock() return ns.Data and ns.Data.ServerTime and ns.Data.ServerTime() or ns.Now() end
local function Hash(key) return ns.Comm.Hash36(tostring(key)) end
local function ValidKey(key)
	return type(key) == "string" and #key >= 6 and #key <= 64 and not key:find("[~|%c]")
end

-- The epoch of the key we hold, or nil (none, or one taken without an epoch).
local function Epoch()
	local r = ns.rdb
	local e = r and r.keyEpoch
	if type(e) ~= "table" or type(r.realmKey) ~= "string" or r.realmKey == "" or e.key ~= Hash(r.realmKey) then return nil end
	return tonumber(e.at)
end
Keys.Epoch = Epoch
function Keys.HoldsEpoch() return Epoch() ~= nil end

-- The newest epoch this client heard of: its key's, or the one of the key a plain K1 (an officer
-- before 1.1) replaced since. A K3 no newer is not taken: an older key never undoes a re-key.
local function Latest()
	local e = ns.rdb and ns.rdb.keyEpoch
	return type(e) == "table" and tonumber(e.at) or nil
end

---------------------------------------------------------------------------
-- The keys a newer one replaced (ns.rdb.keyRetired: [hash] = when)
---------------------------------------------------------------------------

local function Retired()
	local r = ns.rdb
	if not r then return {} end
	if type(r.keyRetired) ~= "table" then r.keyRetired = {} end
	return r.keyRetired
end
local function IsHash(h) return type(h) == "string" and #h >= 1 and #h <= 16 and h:match("^%w+$") ~= nil end
local function Retire(hash)
	if not IsHash(hash) or not ns.rdb then return end
	if ValidKey(ns.rdb.realmKey) and hash == Hash(ns.rdb.realmKey) then return end -- (never the key we hold)
	local list = Retired()
	list[hash] = ns.Now()
	local n, oldest = 0, nil
	for h, t in pairs(list) do
		n = n + 1
		if not oldest or (tonumber(t) or 0) < (tonumber(list[oldest]) or 0) then oldest = h end
	end
	if n > Keys.RETIRED_MAX and oldest then list[oldest] = nil end
end
local function Unretire(key)
	if ValidKey(key) and ns.rdb and type(ns.rdb.keyRetired) == "table" then ns.rdb.keyRetired[Hash(key)] = nil end
end
function Keys.IsRetired(key) return ValidKey(key) and Retired()[Hash(key)] ~= nil end

-- "h1.h2" as it travels: the hashes, each once, never `except`, at most RETIRES_SENT.
local function Hashes(s, first, except)
	local out, seen = {}, { [except or ""] = true }
	local function Add(h)
		if IsHash(h) and not seen[h] and #out < Keys.RETIRES_SENT then
			seen[h] = true
			out[#out + 1] = h
		end
	end
	Add(first)
	for h in tostring(s or ""):gmatch("[^%.]+") do Add(h) end
	return out
end

local function Message(at, key, retires)
	local msg = ("K3~%d~%s"):format(at, key)
	if type(retires) == "string" and #retires <= 60 and retires:match("^%w[%w%.]*$") then msg = msg .. "~" .. retires end
	return msg
end

-- The King's rotation (ns.rdb.keyRotation): { at, key, retires, picking, picked = { [guild, lower
-- case] = true | false }, till, acked = { [Name-Realm] = guild }, sent = { [Name-Realm] = t },
-- sentFor = { [Name-Realm] = the guild he was whispered for }, queued = { [Name-Realm] = t },
-- saw = { [Name-Realm] = { guild, at } } (WhoSaw), moved, movedAt }.
local function Rotation()
	local r = ns.rdb and ns.rdb.keyRotation
	return type(r) == "table" and r or nil
end
Keys.Rotation = Rotation

-- The key this client hands its guild (K0, K5): the one it holds, its epoch and the keys it
-- replaced. (The King's new key goes to his guild when he moves to it.)
function Keys.HandOut()
	local key = ns.rdb and ns.rdb.realmKey
	if not ValidKey(key) then return nil end
	local at = Epoch()
	return key, at, at and ns.rdb.keyEpoch.retires or nil
end
-- ...as the K3 an officer answers with (nil without an epoch: then K1 alone, as before 1.1).
function Keys.HandOutMessage()
	local key, at, retires = Keys.HandOut()
	if key and at then return Message(at, key, retires) end
	return nil
end

-- A key with its epoch, taken when newer than any we heard of: the channel follows. The keys it
-- replaces (those it came with, and the one we held) are remembered, and handed on with it.
local function Take(key, at, quiet, retires)
	local rdb = ns.rdb
	if not rdb or not ValidKey(key) then return false end
	local was = Latest()
	if was and at <= was then return false end
	local old = rdb.realmKey
	local changed = old ~= key
	local list = Hashes(retires, changed and ValidKey(old) and Hash(old) or nil, Hash(key))
	rdb.realmKey = key
	rdb.keyEpoch = { key = Hash(key), at = at, retires = #list > 0 and table.concat(list, ".") or nil }
	Unretire(key)
	for _, h in ipairs(list) do Retire(h) end
	stats.taken = stats.taken + 1
	ns.Log("realm key: a key of epoch %d taken%s", at, changed and " (a new channel)" or "") -- (never the key)
	if changed then
		if not quiet then ns.Print(L.KEY_ROTATED_TAKEN) end
		ns.Comm.JoinChannel()
	end
	return true
end
Keys.Take = Take

-- To our guild (an officer): the key with its epoch, and alone for guildmates before 1.1.
local function ToGuild(key, at)
	local e = ns.rdb and ns.rdb.keyEpoch
	ns.Comm.Send("GUILD", Message(at, key, type(e) == "table" and e.retires or nil), "key3")
	ns.Comm.Send("GUILD", "K1~" .. key, "key")
	stats.relayed = stats.relayed + 1
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

function Keys.HandleKey(dist, sender, text)
	local at, key, retires = tostring(text):match("^K3~(%d+)~([^~]+)~?([%w%.]*)$")
	at = tonumber(at)
	if not at or not ValidKey(key) then return end
	sender = ns.FullName(sender)
	local fromCrown
	if dist == "WHISPER" then
		-- The King by his pinned name, or his Steward by the signed list: the server stamps the
		-- sender, nobody else carries it.
		if not (ns.IsKingCharacter(sender) or (ns.KingCharacter() ~= nil and ns.King.IsStewardName(sender))) then
			stats.refused = stats.refused + 1
			return ns.Log("realm key by whisper from %s ignored: not the King nor his Steward", sender)
		end
		fromCrown = true
	elseif dist == "GUILD" then
		-- Our own officers, by our roster (the server's word): as K1 always was.
		local rank = ns.Roster.RankOf(sender)
		if not rank or rank > ns.CAPTAIN_RANK then
			stats.refused = stats.refused + 1
			return
		end
	else
		return -- never the channel: nothing of a key is read there
	end
	if at > Clock() + Keys.DATE_AHEAD then
		stats.refused = stats.refused + 1
		return ns.Log("realm key from %s ignored: dated ahead", sender)
	end
	local took = Take(key, at, false, retires)
	if fromCrown then
		-- The rotating client counts who has it; an officer hands it to his guild.
		ns.Comm.Whisper(sender, ("K4~%d~%s"):format(at, GetGuildInfo("player") or ""), "key4")
		if took and ns.Roster.IsOfficer() then ToGuild(key, at) end
	end
end

function Keys.HandleAck(dist, sender, text)
	if dist ~= "WHISPER" then return end
	local rot = Rotation()
	if not rot or not Keys.CanRotate() then return end
	local at = tostring(text):match("^K4~(%d+)~")
	if tonumber(at) ~= rot.at then return end
	sender = ns.FullName(sender)
	-- Only from a name his client whispered the key to (counted once it left): anyone else's K4
	-- would pass on his Throne for a Lord or Captain who has it (Konig's review).
	if not (type(rot.sent) == "table" and rot.sent[sender]) then
		return ns.Log("realm key: %s's acknowledgement ignored: not whispered the key", sender)
	end
	rot.acked = type(rot.acked) == "table" and rot.acked or {}
	if rot.acked[sender] then return end
	-- Under the guild his client whispered him for, never the one the K4 names: a Lord whispered
	-- could name any guild, and the Throne would count it as having the key (1.1 review).
	rot.acked[sender] = type(rot.sentFor) == "table" and type(rot.sentFor[sender]) == "string" and rot.sentFor[sender] or ""
	stats.acks = stats.acks + 1
	ns.King.Changed()
end

function Keys.HandleAsk(dist, sender, text)
	if dist ~= "GUILD" then return end
	local asked = tonumber(tostring(text):match("^K5~(%d+)$"))
	if not asked or not ns.Roster.IsOfficer() then return end
	local _, at = Keys.HandOut()
	if not at or at <= asked then return end
	local now = ns.Now()
	if now - lastAnswer < Keys.ANSWER_GAP then return end
	lastAnswer = now
	stats.answered = stats.answered + 1
	ns.After(math.random(1, 5), "key answer", function()
		local msg = Keys.HandOutMessage()
		if msg then ns.Comm.Send("GUILD", msg, "key3") end
	end)
end

ns.Comm.Handle("K3", function(...) Keys.HandleKey(...) end)
ns.Comm.Handle("K4", function(...) Keys.HandleAck(...) end)
ns.Comm.Handle("K5", function(...) Keys.HandleAsk(...) end)

-- After login: is there a newer key than ours in the guild?
function Keys.Ask()
	if not ns.IsMember() then return end
	ns.Comm.Send("GUILD", ("K5~%d"):format(Epoch() or 0), "key5")
end

-- An officer typed /syl key (Comm.SetRealmKey): his key, dated now, for his guild's 1.1 clients
-- too. was: the key it replaces (then remembered, and named with it).
function Keys.Typed(key, was)
	if not ValidKey(key) or not ns.rdb then return end
	local at = Clock()
	local latest = Latest()
	if latest and at <= latest then at = latest + 1 end
	local retires = ValidKey(was) and was ~= key and Hash(was) or nil
	ns.rdb.keyEpoch = { key = Hash(key), at = at, retires = retires }
	Unretire(key)
	if retires then Retire(retires) end
	ns.Comm.Send("GUILD", Message(at, key, retires), "key3")
end

-- A K1 (a key without an epoch, from an officer before 1.1 or from before this version): taken
-- as ever (Comm.lua), unless it is a key a newer one replaced here (the leaked one).
function Keys.TakesLegacy(key)
	if key == (ns.rdb and ns.rdb.realmKey) or not Keys.IsRetired(key) then return true end
	stats.legacy = stats.legacy + 1
	return false
end

---------------------------------------------------------------------------
-- The King: rotate, pick the guilds, hand out, move
---------------------------------------------------------------------------

-- A new key from this computer (the Link's entropy sample, the clocks, the game's generator),
-- SHA-256, 20 hex digits. Nothing in the game is a cryptographic source: for a channel's
-- password it is plenty, and nobody sees it.
function Keys.NewKey()
	local parts = { tostring(ns.me), tostring(time and time()), tostring(GetTime and GetTime()), tostring(math.random()),
		tostring(math.random()), tostring({}), tostring(debugprofilestop and debugprofilestop() or 0) }
	if ns.Link and not ns.Link.missing and ns.Link.EntropySample then parts[#parts + 1] = ns.Link.EntropySample() end
	local raw = ns.Sign.SHA256(table.concat(parts, "|"))
	local hex = {}
	for i = 1, #raw do hex[i] = ("%02x"):format(raw:byte(i)) end
	return table.concat(hex):sub(1, 20)
end

-- The King, by his pinned character, or his Steward (the signed list), acting for him: never a
-- Hand or an officer. None where no King is pinned.
function Keys.CanRotate()
	if not (ns.King ~= nil and ns.KingCharacter() ~= nil) then return false end
	return (ns.King.IsKing() and ns.IsKingCharacter(ns.me)) or ns.King.IsSteward()
end

-- Sylvanistas: a Dreadguard (rank 0-1 of the Dark Lady's guild) rotates the key for that guild
-- directly: a new key nobody sees, taken here and handed to the guild over GUILD, where every
-- guildmate's addon already takes a key from its officers (HandleKey, K1). The Dark Lady's own
-- rotation (above) still reaches the other Sylvanistas guilds; this one reaches her guild alone.
function Keys.CanGuildRotate()
	return ns.IsMember() and ns.Roster.IsOfficer() and ns.IsKingGuild(GetGuildInfo("player")) or false
end

function Keys.GuildRotatePrompt()
	if not Keys.CanGuildRotate() then return ns.Print(L.KEY_ROTATE_ONLY_KING) end
	ns.ShowDialog("SYLVANISTAS_KEY_GUILD_ROTATE")
end

function Keys.GuildRotate()
	if not Keys.CanGuildRotate() then return ns.Print(L.KEY_ROTATE_ONLY_KING) end
	local at = Clock()
	local was = Latest()
	if was and at <= was then at = was + 1 end
	local held = ns.rdb.realmKey
	local key = Keys.NewKey()
	local list = Hashes(ns.rdb.keyEpoch and ns.rdb.keyEpoch.retires, ValidKey(held) and Hash(held) or nil, Hash(key))
	Take(key, at, true, #list > 0 and table.concat(list, ".") or nil)
	ToGuild(key, at)
	stats.rotated = stats.rotated + 1
	ns.Log("realm key: rotated for our guild by an officer (epoch %d)", at)
	ns.Print(L.KEY_GUILD_ROTATED)
	return true
end

StaticPopupDialogs["SYLVANISTAS_KEY_GUILD_ROTATE"] = {
	text = L.KEY_GUILD_ROTATE_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function() ns.SafeCall("key guild rotate", Keys.GuildRotate) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- The King's own /who saw someone of this guild (Data.Seen, within Data.KEEP): the server's word
-- that a guild of that name exists. A census row alone is anyone's report.
local function Seen(guild)
	local now, lower = ns.Now(), tostring(guild):lower()
	for name, s in pairs(ns.Data.Seen()) do
		if type(name) == "string" and name:lower() == lower and type(s) == "table" and now - (tonumber(s.t) or 0) <= ns.Data.KEEP then
			return true
		end
	end
	return false
end
Keys.Seen = Seen

-- What his /who saw of the Lords and Captains the census names is kept in the rotation (rot.saw:
-- [Name-Realm] = { guild, at = server time }), like the rest of it: Who.lua's own list starts
-- empty after a /reload or relog, and is forgotten whole past Who.SEEN_MAX names (a pass over
-- the army's guilds lists more), while the hand-out depends on it (Konig's review).
local function Keep(rot, name, guild, at)
	rot.saw = type(rot.saw) == "table" and rot.saw or {}
	rot.saw[name] = { guild = guild, at = at }
end
-- Every player an answer of ours lists (Who.OnSaw): kept when the census names him a Lord or
-- Captain of the guild it shows, or was kept already (seen elsewhere now: that counts too).
function Keys.Saw(name, guild)
	local rot = Rotation()
	if not rot or rot.moved or type(name) ~= "string" or not Keys.CanRotate() then return end
	name = ns.FullName(name)
	guild = type(guild) == "string" and guild or ""
	local kept = type(rot.saw) == "table" and rot.saw[name]
	if kept or (guild ~= "" and (ns.Data.KnownRank(name, guild) or math.huge) <= ns.CAPTAIN_RANK) then
		Keep(rot, name, guild, Clock())
	end
end
if ns.Who and ns.Who.OnSaw then ns.Who.OnSaw(function(name, guild) Keys.Saw(name, guild) end) end

-- His own /who listed this player in exactly this guild within WHO_FRESH (Who.SeenGuild, or the
-- rotation's own record: the newer): the server's word. The census alone can't say it: two
-- characters on the leaked channel can report themselves a real guild's Lord and Captain
-- (Data.KnownRank asks two senders, they are two). A sighting from before the rotation that holds
-- is kept in it from then on.
local function WhoSaw(name, guild)
	name = ns.FullName(name)
	local seen, age
	if ns.Who and ns.Who.SeenGuild then seen, age = ns.Who.SeenGuild(name) end
	local rot = Rotation()
	local kept = rot and type(rot.saw) == "table" and rot.saw[name] or nil
	local keptAt = type(kept) == "table" and tonumber(kept.at) or nil
	if keptAt and (type(age) ~= "number" or Clock() - keptAt < age) then
		seen, age = kept.guild, Clock() - keptAt
	elseif rot and not rot.moved and seen == guild and type(age) == "number" and age <= Keys.WHO_FRESH then
		Keep(rot, name, seen, Clock() - math.floor(age))
	end
	return seen == guild and type(age) == "number" and age <= Keys.WHO_FRESH
end
Keys.WhoSaw = WhoSaw

-- Every guild but ours (ours gets it over GUILD when he moves: an officer's word there; a Steward
-- who is no officer of his guild has it handed like any other) with Lords and Captains the census
-- confirms online (two senders: Data.KnownRank): { guild, names = { Name-Realm } his /who saw
-- in it (whispered), waiting = { Name-Realm } it did not (not whispered), seen }.
function Keys.Candidates()
	local out, now = {}, ns.Now()
	local mine = ns.Roster.IsOfficer() and GetGuildInfo("player") or nil
	for _, e in ipairs(ns.Data.Summary().guilds) do
		local g = e.g
		if e.fresh and e.name ~= mine and now - (tonumber(g.t) or 0) <= Keys.ONLINE_FRESH then
			local home = g.realm or ns.realm
			local names, waiting = {}, {}
			local function Add(name, online)
				if type(name) ~= "string" or not online then return end
				local full = ns.FullName(name, home)
				local rank = ns.Data.KnownRank(full, e.name)
				if rank and rank <= ns.CAPTAIN_RANK then
					if WhoSaw(full, e.name) then names[#names + 1] = full else waiting[#waiting + 1] = full end
				end
			end
			Add(g.leader, g.leaderOnline)
			for _, o in ipairs(g.officers or {}) do Add(o.name, o.online) end
			if #names + #waiting > 0 then out[#out + 1] = { guild = e.name, names = names, waiting = waiting, seen = Seen(e.name) } end
		end
	end
	return out
end

-- Does this guild get the new key? The King's click, else whether his /who saw it.
local function Picked(rot, c)
	-- (Never `t[k] or nil`: an unchecked guild's false would read as no click at all.)
	local v
	if type(rot.picked) == "table" then v = rot.picked[c.guild:lower()] end
	if v == nil then return c.seen end
	return v == true
end

-- The Lords and Captains online of the guilds the King picked, whom his /who saw in them:
-- { name, guild }. Those the census alone names wait for his /who (Keys.Confirm).
function Keys.Targets()
	local rot, out = Rotation(), {}
	if not rot then return out end
	for _, c in ipairs(Keys.Candidates()) do
		if Picked(rot, c) then
			for _, name in ipairs(c.names) do out[#out + 1] = { name = name, guild = c.guild } end
		end
	end
	return out
end

-- The King clicks a guild on the Throne: it gets the key, or not (later rounds too).
function Keys.Toggle(guild)
	local rot = Rotation()
	if type(guild) ~= "string" or not rot or rot.moved or not Keys.CanRotate() then return end
	rot.picked = type(rot.picked) == "table" and rot.picked or {}
	local now = rot.picked[guild:lower()]
	if now == nil then now = Seen(guild) end
	rot.picked[guild:lower()] = not now
	ns.King.Changed()
end

-- The King's click (the game takes /who from a click alone): his /who asks the server about the
-- Lords and Captains picked it has not seen in their guild yet, one search a click at Who.lua's
-- pace (quiet): first the players of every guild picked not searched yet (up to 50 each), then
-- by name each one those answers did not list (full, or he logged in since), the one asked
-- longest ago first and each at most once in WHO_FRESH: made-up names in one guild's census
-- never keep the next guild from its search (Konig's review). `only`: that guild alone (the one
-- he clicked).
-- With the gamepad UI no quiet search goes, and none by name (1.1 review): his click on the
-- /who line searches one guild picked plainly, as the census's Refresh does there (the answer in
-- the game's Who list, nothing silenced; Who.OnSaw reads it), the one searched longest ago
-- first, each again a minute after its last (Who.GUILD_AGAIN: a Lord who logged in since). A
-- click on a guild's row only checks it there (the game's list opening would take the gamepad's
-- focus). What the census's Refresh lists counts too.
local asked, askedFor = {}, nil -- [Name-Realm] = GetTime() of our search for him by name; the rotation's epoch
local askedGuild = {} -- [guild] = GetTime() of our plain search of it (the gamepad UI)
local function ConfirmPlain(rot, W, only)
	if only then return false end
	local now, list, waiting = GetTime(), {}, false
	for _, c in ipairs(Keys.Candidates()) do
		if #c.waiting > 0 and Picked(rot, c) then
			waiting = true
			local at = askedGuild[c.guild] or -math.huge
			if now - at >= (W.GUILD_AGAIN or 60) then list[#list + 1] = { guild = c.guild, at = at } end
		end
	end
	-- The guild asked longest ago first; one the /who itself refuses now (searched lately another
	-- way: a mouse click before the switch, an earlier rotation) is passed over for the next.
	table.sort(list, function(a, b) return a.at < b.at end)
	for _, p in ipairs(list) do
		if W.SearchGuild(p.guild, true) then
			askedGuild[p.guild] = now
			return true
		end
	end
	if waiting then ns.Print(L.KEY_WHO_GAMEPAD) end
	return false
end
function Keys.Confirm(only)
	local rot, W = Rotation(), ns.Who
	if not rot or rot.moved or not Keys.CanRotate() or not (W and W.SearchGuild and W.GuildSeen and W.Search) then return false end
	if askedFor ~= rot.at then wipe(asked); wipe(askedGuild); askedFor = rot.at end
	if ns.GamepadUI() then return ConfirmPlain(rot, W, only) end
	local now, byName, byNameAt = GetTime(), nil, nil
	for _, c in ipairs(Keys.Candidates()) do
		if #c.waiting > 0 and (only == nil or c.guild == only) and Picked(rot, c) then
			if not W.GuildSeen(c.guild) then
				if W.SearchGuild(c.guild) then return true end
			else
				for _, name in ipairs(c.waiting) do
					local at = asked[name] or -math.huge
					if now - at >= Keys.WHO_FRESH and (byName == nil or at < byNameAt) then byName, byNameAt = name, at end
				end
			end
		end
	end
	if byName and W.Search(true, nil, byName) then
		asked[byName] = now
		return true
	end
	return false
end

-- Picked Lords and Captains online whose whisper never left yet (nor did they answer).
function Keys.Waiting()
	local rot = Rotation()
	if not rot then return 0 end
	local n = 0
	for _, t in ipairs(Keys.Targets()) do
		if not (type(rot.acked) == "table" and rot.acked[t.name]) and not (type(rot.sent) == "table" and rot.sent[t.name]) then n = n + 1 end
	end
	return n
end

-- Whispers the new key to the Lords and Captains picked who have not answered (again after
-- RESEND): as many as the send queue has room for, each counted once it left.
function Keys.Hand()
	local rot = Rotation()
	if not rot or rot.moved or rot.picking or not Keys.CanRotate() then return 0 end
	rot.acked = type(rot.acked) == "table" and rot.acked or {}
	rot.sent = type(rot.sent) == "table" and rot.sent or {}
	rot.sentFor = type(rot.sentFor) == "table" and rot.sentFor or {}
	rot.queued = type(rot.queued) == "table" and rot.queued or {}
	local now, n = ns.Now(), 0
	local room = Keys.MAX_WHISPERS
	if ns.Comm.QueueRoom then room = math.min(room, ns.Comm.QueueRoom() - Keys.QUEUE_SPARE) end
	for _, t in ipairs(Keys.Targets()) do
		if n >= room then break end
		local name, guild = t.name, t.guild
		local waiting = tonumber(rot.queued[name])
		if not rot.acked[name] and not (waiting and now - waiting < Keys.QUEUE_WAIT)
			and now - (tonumber(rot.sent[name]) or -math.huge) >= Keys.RESEND then
			rot.queued[name] = now
			ns.Comm.Whisper(name, Message(rot.at, rot.key, rot.retires), "key3:" .. name, nil, nil, function(sent)
				if Rotation() ~= rot then return end
				rot.queued[name] = nil
				if sent then
					rot.sent[name] = ns.Now()
					rot.sentFor[name] = guild -- (his acknowledgement counts for this guild, HandleAck)
					stats.whispered = stats.whispered + 1
					ns.King.Changed()
				end
			end)
			n = n + 1
		end
	end
	return n
end

function Keys.Rotate()
	if ns.King and ns.King.Preview and ns.King.Preview() then return ns.Print(L.THRONE_PREVIEW_NOTE) end
	if not Keys.CanRotate() then return ns.Print(L.KEY_ROTATE_ONLY_KING) end
	local rot = Rotation()
	if rot and not rot.moved then return ns.Print(L.KEY_ROTATE_BUSY) end
	local at = Clock()
	local was = Latest()
	if was and at <= was then at = was + 1 end
	local held = ns.rdb.realmKey
	rot = { at = at, key = Keys.NewKey(), picking = true, picked = {}, acked = {}, sent = {}, sentFor = {}, queued = {} }
	-- The keys it replaces: ours, and those ours replaced.
	local list = Hashes(ns.rdb.keyEpoch and ns.rdb.keyEpoch.retires, ValidKey(held) and Hash(held) or nil, Hash(rot.key))
	rot.retires = #list > 0 and table.concat(list, ".") or nil
	ns.rdb.keyRotation = rot
	stats.rotated = stats.rotated + 1
	ns.Log("realm key: the King rotates it (epoch %d): picking the guilds", at)
	ns.Print(L.KEY_ROTATE_READY)
	ns.King.Changed()
	return true
end

-- The King hands it out to the guilds picked: whispers now, and for GRACE to those who log in.
function Keys.Start()
	local rot = Rotation()
	if not rot or rot.moved or not rot.picking or not Keys.CanRotate() then return false end
	rot.picking = nil
	rot.till = ns.Now() + Keys.GRACE
	ns.Log("realm key: handed out (epoch %d)", rot.at)
	Keys.Hand()
	ns.Print(L.KEY_ROTATED:format(math.ceil(Keys.GRACE / 60)))
	ns.King.Changed()
	return true
end

-- Before anything was sent: the new key is dropped.
function Keys.Drop()
	local rot = Rotation()
	if not rot or not rot.picking or not Keys.CanRotate() then return false end
	ns.rdb.keyRotation = nil
	ns.Print(L.KEY_ROTATE_DROPPED)
	ns.King.Changed()
	return true
end

-- The King moves to his new key, and his guild with him (over GUILD).
function Keys.Move()
	local rot = Rotation()
	if not rot or rot.moved or rot.picking or not Keys.CanRotate() then return false end
	rot.moved, rot.movedAt = true, ns.Now()
	rot.saw = nil -- (nothing is handed any more: what his /who saw goes)
	Take(rot.key, rot.at, true, rot.retires)
	ToGuild(rot.key, rot.at)
	ns.Print(L.KEY_ROTATION_MOVED)
	ns.King.Changed()
	return true
end

function Keys.Tick()
	local rot = Rotation()
	if not rot or rot.moved or rot.picking or not Keys.CanRotate() then return end
	local now, till = ns.Now(), tonumber(rot.till) or 0
	-- The grace is over: he moves, a little later while Lords and Captains picked still wait for
	-- their whisper (a long queue), GRACE_MORE at most.
	if now >= till and (now >= till + Keys.GRACE_MORE or Keys.Waiting() == 0) then return Keys.Move() end
	Keys.Hand()
end

local function Counts(rot)
	local acked, guilds, sent = 0, {}, 0
	for _, g in pairs(type(rot.acked) == "table" and rot.acked or {}) do
		acked = acked + 1
		if g ~= "" then guilds[g] = true end -- (a whisper recorded before 1.1's review: no guild)
	end
	for _ in pairs(type(rot.sent) == "table" and rot.sent or {}) do sent = sent + 1 end
	local n = 0
	for _ in pairs(guilds) do n = n + 1 end
	return sent, acked, n
end

-- On the Throne (the King's and his Steward's): rotate; then the guilds to pick, handing it out,
-- how far it got.
function Keys.ThroneLines()
	local K = ns.King
	if not (K and (K.IsKing() or K.IsSteward() or (K.Preview and K.Preview()))) then return {} end
	local Line, INK, TITLE = K.Line, K.INK, K.TITLE
	local lines = { Line(L.KEY_ROTATE_TITLE, TITLE) }
	local rot = Rotation()
	if rot and not rot.moved then
		if rot.picking then
			K.Para(lines, L.KEY_PICK_HINT, INK, { indent = 1 })
		else
			local sent, acked, guilds = Counts(rot)
			lines[#lines + 1] = Line(L.KEY_ROTATING:format(sent, acked, guilds), INK, { indent = 1 })
		end
		local candidates, picked, waiting = Keys.Candidates(), 0, 0
		local function Shown(names)
			local shown = {}
			for _, n in ipairs(names) do shown[#shown + 1] = ns.DisplayName(n) end
			return #shown > 0 and table.concat(shown, ", ") or "-"
		end
		for _, c in ipairs(candidates) do
			local on = Picked(rot, c)
			if on then picked, waiting = picked + 1, waiting + #c.waiting end
			local text = ("%s<%s>  %d · %s"):format(on and READY or NOT_READY, c.guild, #c.names, c.seen and L.KEY_GUILD_SEEN or L.KEY_GUILD_CENSUS)
			if #c.waiting > 0 then text = text .. " · " .. L.KEY_GUILD_WAITING:format(#c.waiting) end
			lines[#lines + 1] = Line(text, INK, { indent = 1,
				-- (Checked, his click also asks /who for it: a click is when /who may go.)
				onClick = function() Keys.Toggle(c.guild); Keys.Confirm(c.guild) end,
				tooltip = function(tt)
					tt:AddLine("<" .. c.guild .. ">", 1, 0.82, 0)
					tt:AddLine(L.KEY_GUILD_TIP:format(Shown(c.names)), 1, 1, 1, true)
					if #c.waiting > 0 then tt:AddLine(L.KEY_GUILD_WAIT_TIP:format(Shown(c.waiting)), 1, 1, 1, true) end
				end })
		end
		if #candidates == 0 then lines[#lines + 1] = Line(L.KEY_NO_GUILDS, INK, { indent = 1 }) end
		if waiting > 0 then
			lines[#lines + 1] = Line("> " .. L.KEY_WHO_CONFIRM:format(waiting), INK, { indent = 1, onClick = function() Keys.Confirm() end })
		end
		if rot.picking then
			lines[#lines + 1] = Line("> " .. L.KEY_HAND_OUT:format(picked), INK, { indent = 1,
				onClick = function() ns.ShowDialog("SYLVANISTAS_KEY_HAND_OUT", tostring(picked)) end })
			lines[#lines + 1] = Line("> " .. L.KEY_ROTATE_DROP, INK, { indent = 1, onClick = function() Keys.Drop() end })
		else
			local left = math.max(0, math.ceil(((tonumber(rot.till) or 0) - ns.Now()) / 60))
			lines[#lines + 1] = Line("> " .. L.KEY_MOVE_NOW:format(left), INK, { indent = 1, onClick = function() ns.ShowDialog("SYLVANISTAS_KEY_MOVE") end })
		end
	else
		if rot and rot.moved then
			local _, acked, guilds = Counts(rot)
			lines[#lines + 1] = Line(L.KEY_ROTATED_AGO:format(ns.Ago(rot.movedAt), acked, guilds), INK, { indent = 1 })
		end
		lines[#lines + 1] = Line("> " .. L.KEY_ROTATE, INK, { indent = 1,
			onClick = function() Keys.RotatePrompt() end,
			tooltip = function(tt)
				tt:AddLine(L.KEY_ROTATE, 1, 0.82, 0)
				tt:AddLine(L.KEY_ROTATE_TIP, 1, 1, 1, true)
			end })
	end
	lines[#lines].gapAfter = true
	return lines
end

function Keys.RotatePrompt()
	if ns.King and ns.King.Preview and ns.King.Preview() then return ns.Print(L.THRONE_PREVIEW_NOTE) end
	if not Keys.CanRotate() then return ns.Print(L.KEY_ROTATE_ONLY_KING) end
	ns.ShowDialog("SYLVANISTAS_KEY_ROTATE", tostring(math.ceil(Keys.GRACE / 60)))
end

StaticPopupDialogs["SYLVANISTAS_KEY_ROTATE"] = {
	text = L.KEY_ROTATE_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function() ns.SafeCall("key rotate", Keys.Rotate) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
StaticPopupDialogs["SYLVANISTAS_KEY_HAND_OUT"] = {
	text = L.KEY_HAND_OUT_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function() ns.SafeCall("key hand out", Keys.Start) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
StaticPopupDialogs["SYLVANISTAS_KEY_MOVE"] = {
	text = L.KEY_MOVE_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function() ns.SafeCall("key move", Keys.Move) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- /syl status: the key's state, never the key.
function Keys.StatusLine()
	local at = Epoch()
	local rot = Rotation()
	local state = rot and (rot.moved and ("rotated here " .. ns.Ago(rot.movedAt))
		or rot.picking and "a new key waiting for the guilds to be picked" or "a new key being handed out") or "no rotation here"
	local retired = 0
	for _ in pairs(type(ns.rdb and ns.rdb.keyRetired) == "table" and ns.rdb.keyRetired or {}) do retired = retired + 1 end
	return ("%s  |  epoch %s  |  %s  |  taken %d, refused %d, keys replaced %d (their K1 ignored %d), whispered %d, acks %d, relayed %d"):format(
		ns.rdb and ns.rdb.realmKey and "sealed" or "public", at and (date and date("%Y-%m-%d %H:%M", at) or tostring(at)) or "none",
		state, stats.taken, stats.refused, retired, stats.legacy, stats.whispered, stats.acks, stats.relayed)
end
function Keys.Stats() return stats end

ns.On("LOGIN", function()
	-- Whispers queued before a /reload left with the old queue, or never did: handed again.
	local rot = Rotation()
	if rot then rot.queued = {} end
	ns.After(Keys.ASK_AFTER, "key epoch ask", Keys.Ask)
	ns.Every(60, "key rotation", Keys.Tick)
end)

-- Tests start from a clean state.
function Keys.Reset()
	lastAnswer = -math.huge
	for k in pairs(stats) do stats[k] = 0 end
	wipe(asked)
	wipe(askedGuild)
	askedFor = nil
end
