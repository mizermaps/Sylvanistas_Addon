local ADDON, ns = ...
local L = ns.L

-- Loot notes (1.1, Fern's #22): "[Loot notes] and an optional points column officers edit by
-- hand. Not a bid window and not auto-loot. Loot arguments restart every raid because nobody kept
-- last week's decision. Notes carry that history. Points, if you use them, stay a notebook. Gold
-- bids are out because GDKP is not allowed on Forever."
--
-- A guild's own book, over GUILD alone (never the Sylvanistas channel). Its officers (the guild master
-- and the officer rank right below, by each reader's own roster: the server's word) write notes,
-- the decision the next raid starts from ("[Nightslayer Belt] to Ann: she passed on the gloves,
-- Bob gets the next one"), and, if the guild uses them, a member's points by hand: a number,
-- nothing adds or takes any. Every member with the addon reads the book on the Realm tab (Loot
-- notes). Nothing is bid, rolled, handed out or traded: no bid window, no gold, no loot moved. The
-- items the group loots show there to its officers (the game's own loot lines, this session),
-- only so a note can name one with a click.
--   X1~<entry>              an officer's change: a note written or removed, points set (GUILD;
--                           a note's words go through the logged API, the server keeps them)
--   XQ~<nlo>~<nhi>~<plo>~<phi>   a member's addon asks for the changes it lacks (GUILD): the notes
--                           changed in (nlo, nhi], the points in (plo, phi] (lo = hi: none)
--   XB~S~<nlo>~<nhi>~<ncut>~<plo>~<phi>~<pcut>^<entry>^...   an officer's answer (GUILD, in
--                           pieces): the notes asked for first, then the points, newest first, as
--                           much as ANSWER_BYTES holds; it holds every change in (ncut, nhi] and
--                           (pcut, phi] (cut = lo: the whole range asked for)
-- Entries:
--   N~<writer>~<id>~<written>~<changed>~<item id>~<1: removed>~<to whom>~<words>
--   P~<member>~<points, or nothing: cleared>~<changed>~<officer>
-- (times in base 36, the server's clock). A reader takes a change only from an officer of its own
-- roster, only newer than what it holds. A note is its writer's (never rewritten, only removed, by
-- any officer), a points change its officer's ("by"): an X1 carries its sender's own, and an XB
-- another officer's only from before the reader's session began (Take). Those come on the passing
-- officer's word: nothing signs them, and one made up and dated back cannot be told from a real
-- one, so the reader keeps who passed each on ("via") and the page names him ("Offi via Rival").
-- An officer's addon sends a change in its own name only as it made it (Entries): one another
-- officer gave it back is theirs to pass on. Kept per guild in the saved variables; on the Forever
-- beta, which forgets them at every login, the book comes back from the officers online.
-- (1.1 review: the types were J1, JQ and JB, which the census's route ask took too; see Comm.lua.)
--
-- Which changes an addon holds whole is kept apart from the changes themselves (Whole): ranges of
-- change times, the notes' and the points' each, those an officer's answer covered (kept with the
-- book), and from the start of this session on every change as it is made. An addon asks for the
-- newest range it lacks, and again after each answer until none is left: a change heard as it was
-- made never hides older ones, and a book larger than one answer comes back whole, answer by
-- answer, the newest notes first (the 1.1 review: the ask carried the newest change held). An
-- officer's addon answers only for ranges it holds whole itself, so no answer makes a book look
-- whole when it is not; at login it asks too, and takes its book as the guild's when nobody
-- answers (ASK_WAIT). One officer answers an ask: the officers' turns come SLOT apart, in an order
-- drawn from the ask, and an answer heard beginning (its first piece) holds the others back; an
-- officer answers PAGE_GAP apart at most, WINDOW_PAGES in each WINDOW, and takes ASKER_ASKS asks
-- from one guildmate in each WINDOW.

local Loot = {}
ns.Loot = Loot

Loot.TEXT_MAX = 100        -- bytes of a note's words (a change fits one message: 255 bytes)
Loot.TO_MAX = 40           -- ...of whom it went to
Loot.NOTES_MAX = 150       -- notes kept per guild (the newest changes; removed ones count)
Loot.POINTS_MAX = 1000     -- members with points
Loot.POINTS_LIMIT = 99999  -- points go from minus this to this
Loot.REMOVED_KEEP = 30 * 86400 -- a removed note's mark is kept this long (so no old copy brings it back)
Loot.ANSWER_BYTES = 5000   -- an answer holds this much of the book (some 23 pieces)
Loot.PAGE_GAP = 30         -- an officer's answers this far apart at least (one takes 23 pieces x 1.2 s)...
Loot.WINDOW = 600          -- ...and in each 10 minutes
Loot.WINDOW_PAGES = 8      -- ...this many of them at most;
Loot.ASKER_ASKS = 8        -- an officer takes this many asks from one guildmate in each WINDOW
Loot.SLOT = 8              -- seconds between the officers' turns to answer one ask
Loot.QUEUE_MAX = 3         -- an answer waits while its officer's send queue holds more than this
Loot.ASK_WAIT = 30         -- an officer's ask nobody answered this long: his book is the guild's
Loot.ASK_AGAIN = 60        -- the page opened this long after our last ask asks again, while a range lacks
Loot.ASK_HOLD = 10         -- someone's ask heard this recently for what we lack: ours waits
Loot.ASKS_MAX = 16         -- our asks in a session at most
Loot.KNOWN_MAX = 8         -- ranges kept per stream (the oldest go first: they are asked for again)
Loot.DROPS_MAX = 20        -- the group's loot kept for the officers' notes, this session
Loot.random = math.random
Loot.after = function(seconds, where, fn) ns.After(seconds, where, fn) end

local STREAMS = { "n", "p" } -- the notes, then the points
local answering        -- an answer of ours waiting: { n = { lo, hi }, p = { lo, hi }, heard, tries }
local lastAnswer = -math.huge
local pageTimes = {}   -- our answers' times (the last WINDOW)
local askerTimes = {}  -- [guildmate] = the times of his asks we took (the last WINDOW)
local asks, lastAsk = 0, -math.huge -- our asks this session, and the last one's time
local wanting = false  -- we asked this session: we ask again after an answer while a range lacks
local continuing = false -- our next ask waiting
local settling = false -- an officer's: whether nobody answered his first ask is being waited for
local heardAsk         -- someone's ask last heard: { n, p, t }
local heardPage = -math.huge -- an officer's answer last heard
local liveFrom = {}    -- [guild key] = the change time from which this session hears every change
local counter = 0
local drops = {}       -- { { id, link, to, t } }, newest first

local function ServerNow() return (GetServerTime and GetServerTime()) or time() end
local B36 = function(n) return ns.Codec.Base36(n) or "0" end
local function UnB36(s) return type(s) == "string" and #s >= 1 and #s <= 8 and s:match("^[0-9a-z]+$") and tonumber(s, 36) or nil end

-- A player's words as they travel and show: no escape code, control byte, "~" or "^"; one space
-- between words; at most n bytes (never half a letter).
local function Clean(s, n)
	s = tostring(s or ""):gsub("[|%c~%^]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
	return ns.Cut(s, n)
end
Loot.Clean = Clean

-- A character's name as it travels: "Name" or "First Surname", with "-Realm" or not.
local function NameField(s)
	if type(s) ~= "string" or #s > 60 then return nil end
	local short, realm = s:match("^([^%-]+)%-([^%-]+)$")
	short = short or s
	if not short:match("^[%a\128-\255]+ ?[%a\128-\255]*$") then return nil end
	if realm and not realm:match("^[%w\128-\255]+$") then return nil end
	return s
end

---------------------------------------------------------------------------
-- The book (our guild's)
---------------------------------------------------------------------------

function Loot.Guild()
	local guild = IsInGuild() and GetGuildInfo("player")
	return type(guild) == "string" and guild ~= "" and guild or nil
end

local function Book()
	local guild = Loot.Guild()
	if not guild or not ns.rdb then return nil end
	if type(ns.rdb.loot) ~= "table" then ns.rdb.loot = {} end
	local key = ns.Fold(guild)
	local b = ns.rdb.loot[key]
	if type(b) ~= "table" then
		b = {}
		ns.rdb.loot[key] = b
	end
	if type(b.notes) ~= "table" then b.notes = {} end
	if type(b.points) ~= "table" then b.points = {} end
	-- From now on this session hears each change of the guild's as it is made (X1).
	if not liveFrom[key] and ns.IsMember() then liveFrom[key] = ServerNow() + 1 end
	return b, liveFrom[key]
end
Loot.Book = Book

-- An officer: the guild master or the officer rank right below (our own rank, from the server).
function Loot.IsOfficer() return ns.IsMember() == true and ns.Roster.IsOfficer() == true end
-- A sender our roster ranks an officer of our guild.
local function SenderOfficer(sender)
	local rank = ns.Roster.RankOf(sender)
	return rank ~= nil and rank <= ns.CAPTAIN_RANK
end

-- At most NOTES_MAX notes (the newest changes), a removed one's mark REMOVED_KEEP, POINTS_MAX points.
function Loot.Prune(b)
	b = b or Book()
	if not b then return end
	local now, list = ServerNow(), {}
	for key, n in pairs(b.notes) do
		if type(n) ~= "table" or (n.del and now - (n.rev or 0) > Loot.REMOVED_KEEP) then b.notes[key] = nil
		else list[#list + 1] = { key = key, rev = n.rev or 0 } end
	end
	if #list > Loot.NOTES_MAX then
		table.sort(list, function(a, c) if a.rev ~= c.rev then return a.rev > c.rev end return a.key < c.key end)
		for i = Loot.NOTES_MAX + 1, #list do b.notes[list[i].key] = nil end
	end
	list = {}
	for key, p in pairs(b.points) do list[#list + 1] = { key = key, rev = type(p) == "table" and p.rev or 0 } end
	if #list > Loot.POINTS_MAX then
		table.sort(list, function(a, c) if a.rev ~= c.rev then return a.rev > c.rev end return a.key < c.key end)
		for i = Loot.POINTS_MAX + 1, #list do b.points[list[i].key] = nil end
	end
end

-- An entry as it travels (see the top).
local function NoteEntry(n)
	return ("N~%s~%s~%s~%s~%s~%s~%s~%s"):format(n.writer, n.id, B36(n.t), B36(n.rev), n.item and tostring(n.item) or "",
		n.del and "1" or "", n.del and "" or (n.to or ""), n.del and "" or (n.text or ""))
end
local function PointsEntry(member, p)
	return ("P~%s~%s~%s~%s"):format(member, p.v and tostring(p.v) or "", B36(p.rev), p.by or "")
end

-- An entry heard from `sender` (an officer), taken into the book when newer than ours: true then.
-- live: an officer's own change (X1): a new note, and a points change's "by", must be his own.
-- Otherwise (an answer or a push, XB) it may pass on another officer's change: only one made
-- before `from`, the start of this session (one made since reached us from him, live), and never
-- one that rewrites a note (Konig's review of 1.1: an answer could put words in another officer's
-- note, or his name on a points change). A note is written once: after that only its removal
-- changes it (any officer's), save that its writer's own copy replaces one a relay gave us.
-- Another officer's change passed on keeps who passed it ("via"; Konig's review of 1.1: one dated
-- back to before our session cannot be told from a real one, so its relayer is named).
local function Take(b, entry, sender, live, from)
	local now = ServerNow()
	local s = ns.FullName(sender)
	if entry:sub(1, 2) == "N~" then
		local writer, id, t, rev, item, del, to, text = entry:match("^N~([^~]+)~([0-9a-z]+)~([0-9a-z]+)~([0-9a-z]+)~(%d*)~(1?)~([^~]*)~([^~]*)$")
		writer, t, rev = NameField(writer), UnB36(t), UnB36(rev)
		if not writer or not t or not rev or #id > 10 or rev < t or rev > now + 3600 or #item > 9 then return false end
		if #to > Loot.TO_MAX or #text > Loot.TEXT_MAX then return false end
		if del ~= "1" and text == "" then return false end
		local own = ns.FullName(writer) == s
		if del ~= "1" and not own and (live or (from and rev >= from)) then return false end
		local key = ns.FullName(writer) .. "#" .. id
		local old = b.notes[key]
		if type(old) == "table" then
			if del ~= "1" then
				if old.del or not own or old.by == old.writer then return false end
			elseif (old.rev or 0) >= rev then
				return false
			end
		end
		if del == "1" then
			b.notes[key] = { writer = ns.FullName(writer), id = id, t = t, rev = rev, del = true, item = tonumber(item), by = ns.FullName(sender) }
		else
			b.notes[key] = { writer = ns.FullName(writer), id = id, t = t, rev = rev, item = tonumber(item),
				to = to ~= "" and Clean(to, Loot.TO_MAX) or nil, text = Clean(text, Loot.TEXT_MAX), by = ns.FullName(sender),
				via = not own and s or nil }
		end
		return true
	elseif entry:sub(1, 2) == "P~" then
		local member, value, rev, by = entry:match("^P~([^~]+)~(%-?%d*)~([0-9a-z]+)~([^~]*)$")
		member, rev = NameField(member), UnB36(rev)
		local v = value ~= "" and tonumber(value) or nil
		if not member or not rev or rev > now + 3600 or (value ~= "" and (not v or math.abs(v) > Loot.POINTS_LIMIT)) then return false end
		by = NameField(by) and ns.FullName(by) or s
		if by ~= s and (live or (from and rev >= from)) then return false end
		local key = ns.FullName(member)
		local old = b.points[key]
		if type(old) == "table" and (old.rev or 0) >= rev then return false end
		b.points[key] = { v = v, rev = rev, by = by, via = by ~= s and s or nil }
		return true
	end
	return false
end

local function Changed()
	ns.Fire("REALM_PAGE_CHANGED", "loot")
end

---------------------------------------------------------------------------
-- The officers' changes
---------------------------------------------------------------------------

-- (Ahead of the census in our queue, never dropped from it: an addon online holds itself whole
-- from its session's start on, trusting it heard every change.)
local function Send(entry, logged)
	ns.Comm.Send("GUILD", "X1~" .. entry, nil, true, logged)
end

-- A note: its words, and the item and whom it went to when one of the group's loot was clicked.
function Loot.Write(text, item, to)
	if not Loot.IsOfficer() then return ns.Print(L.LOOT_OFFICERS_ONLY) end
	local b = Book()
	if not b then return end
	text = Clean(text, Loot.TEXT_MAX)
	if #text < 2 then return ns.Print(L.LOOT_TOO_SHORT) end
	local now = ServerNow()
	counter = (counter + 1) % 1296
	local n = { writer = ns.me, id = B36(now) .. B36(counter), t = now, rev = now, item = tonumber(item),
		to = to and to ~= "" and Clean(to, Loot.TO_MAX) or nil, text = text, by = ns.me }
	-- (One message: a long name of ours leaves the words a little less room.)
	while #NoteEntry(n) > 250 do n.text = ns.Cut(n.text, #n.text - 1) end
	b.notes[n.writer .. "#" .. n.id] = n
	Loot.Prune(b)
	Send(NoteEntry(n), true)
	ns.Print(L.LOOT_WRITTEN)
	Changed()
	return n
end

-- A note removed (any officer): its mark goes to the guild, so every copy drops it.
function Loot.Remove(key)
	if not Loot.IsOfficer() then return ns.Print(L.LOOT_OFFICERS_ONLY) end
	local b = Book()
	local n = b and b.notes[key]
	if type(n) ~= "table" or n.del then return end
	local r = { writer = n.writer, id = n.id, t = n.t, rev = math.max(ServerNow(), (n.rev or 0) + 1), del = true, item = n.item, by = ns.me }
	b.notes[key] = r
	Send(NoteEntry(r))
	ns.Print(L.LOOT_REMOVED)
	Changed()
end

-- A member of our guild by name, as our roster writes him ("Name-Realm"), whatever the case.
local function Member(name)
	name = Clean(name, 60)
	if name == "" or not ns.Roster.byName then return nil end
	local want = ns.Fold(ns.ShortName(name))
	local realm = ns.RealmOf(name)
	for full in pairs(ns.Roster.byName) do
		if ns.Fold(ns.ShortName(full)) == want and (not realm or ns.Fold(ns.RealmOf(full) or "") == ns.Fold(realm)) then return full end
	end
	return nil
end
Loot.Member = Member

-- A member's points, set by hand ("Bob 12"; "Bob" alone clears them). A notebook: nothing adds
-- or takes any.
function Loot.SetPoints(text)
	if not Loot.IsOfficer() then return ns.Print(L.LOOT_OFFICERS_ONLY) end
	local b = Book()
	if not b then return end
	text = Clean(text, 80)
	local name, value = text:match("^(.-)%s+([%+%-]?%d+)$")
	if not name then name = text end
	local v = value and tonumber(value) or nil
	if v and math.abs(v) > Loot.POINTS_LIMIT then return ns.Print(L.LOOT_POINTS_BAD:format(Loot.POINTS_LIMIT, Loot.POINTS_LIMIT)) end
	local member = Member(name)
	if not member then return ns.Print(L.LOOT_POINTS_NOT_MEMBER:format(name ~= "" and name or "?")) end
	local old = b.points[member]
	local p = { v = v, rev = math.max(ServerNow(), (type(old) == "table" and old.rev or 0) + 1), by = ns.me }
	b.points[member] = p
	Loot.Prune(b)
	Send(PointsEntry(member, p))
	ns.Print(v and L.LOOT_POINTS_DONE:format(ns.DisplayName(member), v) or L.LOOT_POINTS_CLEARED:format(ns.DisplayName(member)))
	Changed()
	return p
end

-- X1: an officer's change.
function Loot.HandleLive(dist, sender, text)
	if dist ~= "GUILD" or not SenderOfficer(sender) then return end
	local b = Book()
	local entry = b and text:match("^X1~(.+)$")
	if entry and Take(b, entry, sender, true) then
		Loot.Prune(b)
		Changed()
	end
end
ns.Comm.Handle("X1", function(...) Loot.HandleLive(...) end)

---------------------------------------------------------------------------
-- The book for a member's addon that lacks it (a login, a /reload on the Forever beta, a
-- guildmate offline when a change was made)
---------------------------------------------------------------------------

local function Recent(times, window)
	local now = ns.Now()
	for i = #times, 1, -1 do if now - times[i] >= window then table.remove(times, i) end end
	return #times
end

-- The ranges of change times (lo, hi] a stream ("n" the notes, "p" the points) of the book is
-- known whole in, kept with it: those officers' answers covered. Newest first.
local function Ranges(b, kind)
	if type(b.known) ~= "table" then b.known = {} end
	local list = b.known[kind]
	if type(list) ~= "table" then
		list = {}
		b.known[kind] = list
	end
	return list
end

-- (lo, hi] joined to a list of ranges (newest first), merged with every one it touches; `max`
-- kept at most (the oldest go).
local function AddRange(list, lo, hi, max)
	lo, hi = tonumber(lo), tonumber(hi)
	if not lo or not hi or lo >= hi then return end
	local out = {}
	for _, r in ipairs(list) do
		local a, z = type(r) == "table" and tonumber(r[1]), type(r) == "table" and tonumber(r[2])
		if a and z and a < z then
			if z < lo or a > hi then out[#out + 1] = { a, z }
			else lo, hi = math.min(lo, a), math.max(hi, z) end
		end
	end
	out[#out + 1] = { lo, hi }
	table.sort(out, function(x, y) return x[1] > y[1] end)
	while max and #out > max do table.remove(out) end
	for i = #list, 1, -1 do list[i] = nil end
	for i, r in ipairs(out) do list[i] = r end
end

-- What we hold whole of a stream now: the ranges kept, and this session's changes from its start.
local function Whole(b, kind, live)
	local list = {}
	for _, r in ipairs(Ranges(b, kind)) do
		if type(r) == "table" then AddRange(list, r[1], r[2]) end
	end
	if live then AddRange(list, live, math.huge) end
	return list
end

-- The newest range of a stream we lack, (lo, hi], or nil: we hold it whole.
local function Missing(b, kind, live)
	local list = Whole(b, kind, live)
	local top = list[1]
	if not top then return 0, ServerNow() end
	if top[1] <= 0 then return nil end
	return list[2] and list[2][2] or 0, top[1]
end

-- What we lack, as an ask carries it: { n = { lo, hi }, p = { lo, hi } }, or nil: nothing.
local function Wanted(b, live)
	local want, any = {}, false
	for _, kind in ipairs(STREAMS) do
		local lo, hi = Missing(b, kind, live)
		if lo then want[kind], any = { lo, hi }, true end
	end
	return any and want or nil
end

local function Holds(b, kind, live, lo, hi)
	for _, r in ipairs(Whole(b, kind, live)) do
		if r[1] <= lo and r[2] >= hi then return true end
	end
	return false
end

-- Whether ranges `h` (an ask's or an answer's: { lo, hi }) take in every one of `want`.
local function Within(want, h)
	for _, kind in ipairs(STREAMS) do
		local r, o = want[kind], h[kind]
		if r and not (o and o[1] < o[2] and o[1] <= r[1] and o[2] >= r[2]) then return false end
	end
	return true
end

-- Our ask for what we lack: an officer's addon at login, anyone's when the page opens (and again
-- after each answer while something still lacks). false: nothing lacks, or our asks are spent.
function Loot.Ask()
	local b, live = nil, nil
	if ns.IsMember() then b, live = Book() end
	if not b then return false end
	wanting = true
	local want = Wanted(b, live)
	if not want or asks >= Loot.ASKS_MAX then return false end
	asks, lastAsk = asks + 1, ns.Now()
	local function R(r) return r and (B36(r[1]) .. "~" .. B36(r[2])) or "0~0" end
	ns.Comm.Send("GUILD", ("XQ~%s~%s"):format(R(want.n), R(want.p)), "lootask")
	-- An officer's first ask of the session that nobody answers: his book is the guild's.
	if not settling and Loot.IsOfficer() and heardPage == -math.huge then
		settling = true
		Loot.after(Loot.ASK_WAIT, "loot settle", function() Loot.Settle() end)
	end
	return true
end

-- After an answer, while we want the book and a range still lacks: asked again a moment later,
-- unless someone's ask heard meanwhile covers ours (its answer reaches us too).
local function Continue()
	if not wanting or continuing then return end
	continuing = true
	Loot.after(2 + Loot.random() * 3, "loot ask again", function()
		continuing = false
		local b, live = nil, nil
		if ns.IsMember() then b, live = Book() end
		local want = b and Wanted(b, live)
		if not want then return end
		local h = heardAsk
		if h and ns.Now() - h.t < Loot.ASK_HOLD and Within(want, h) then return end
		Loot.Ask()
	end)
end

-- An officer's addon at login, once its ask went unanswered ASK_WAIT: nobody holds the book whole
-- online but us (the only officer, or the first), so ours is the guild's.
function Loot.Settle()
	if not Loot.IsOfficer() or heardPage > -math.huge then return false end
	local b, live = Book()
	if not b or not live then return false end
	for _, kind in ipairs(STREAMS) do AddRange(Ranges(b, kind), 0, live, Loot.KNOWN_MAX) end
	ns.Log("loot notes: no officer answered; our book is the guild's")
	return true
end

-- A stream's changes in (lo, hi], newest first: what our answers and pushes carry. A note in our
-- own name only as we hold it ourselves (by == writer, as Write makes it): a copy of ours another
-- officer gave us (a wiped book on the Forever beta) would read, sent by us, as our own and replace
-- a reader's honest copy (Konig's review of 1.1); the officers who hold it pass it on. A points
-- change "by" us likewise, but one another officer passed on to us ("via").
local function Entries(b, kind, lo, hi)
	local list, me = {}, ns.FullName(ns.me or "")
	if kind == "n" then
		for _, n in pairs(b.notes) do
			local r = type(n) == "table" and tonumber(n.rev) or nil
			local relayed = r and not n.del and n.by ~= n.writer and ns.FullName(n.writer or "") == me
			if r and r > lo and r <= hi and not relayed then list[#list + 1] = { rev = r, entry = NoteEntry(n) } end
		end
	else
		for member, p in pairs(b.points) do
			local r = type(p) == "table" and tonumber(p.rev) or nil
			local relayed = r and p.via and p.by == me
			if r and r > lo and r <= hi and not relayed then list[#list + 1] = { rev = r, entry = PointsEntry(member, p) } end
		end
	end
	table.sort(list, function(x, y) if x.rev ~= y.rev then return x.rev > y.rev end return x.entry < y.entry end)
	return list
end

-- Our answer: the notes asked for first, then the points, newest first, as much as ANSWER_BYTES
-- holds. Its head says what it holds whole: every change in (cut, hi] of each stream.
local HEAD_ROOM = 64
function Loot.Page(b, want)
	local head, out, size, full = {}, {}, 0, false
	for _, kind in ipairs(STREAMS) do
		local r = want[kind]
		local lo, hi, cut = 0, 0, 0
		if r and not full then
			lo, hi, cut = r[1], r[2], r[1]
			local list, first = Entries(b, kind, lo, hi), #out
			for i, e in ipairs(list) do
				if size + #e.entry + 1 > Loot.ANSWER_BYTES - HEAD_ROOM then
					cut, full = e.rev, true
					-- (The changes of the cut's own second go whole in the next answer.)
					for j = i - 1, 1, -1 do
						if list[j].rev ~= e.rev or #out <= first + 1 then break end
						size, out[#out] = size - #list[j].entry - 1, nil
					end
					break
				end
				out[#out + 1], size = e.entry, size + #e.entry + 1
			end
		end
		head[#head + 1] = ("%s~%s~%s"):format(B36(lo), B36(hi), B36(cut))
	end
	local text = "XB~S~" .. table.concat(head, "~")
	if #out > 0 then text = text .. "^" .. table.concat(out, "^") end
	return text
end

-- An answer's head ("S~..."): { n = { lo, hi, cut }, p = { lo, hi, cut } }, or nil.
local function Head(s)
	local f = {}
	for v in tostring(s or ""):gmatch("[^~]+") do f[#f + 1] = v end
	if #f ~= 7 or f[1] ~= "S" then return nil end
	local limit, out = ServerNow() + 3600, {}
	for i, kind in ipairs(STREAMS) do
		local at = (i - 1) * 3
		local lo, hi, cut = UnB36(f[2 + at]), UnB36(f[3 + at]), UnB36(f[4 + at])
		if not (lo and hi and cut) or lo > cut or cut > hi or hi > limit then return nil end
		out[kind] = { lo, hi, cut }
	end
	return out
end

-- Whether an answer another officer began holds what ours would: then ours is not sent.
local function Covers(head, a)
	for _, kind in ipairs(STREAMS) do
		local r, h = a[kind], head[kind]
		if r then
			if not (h[1] < h[2] and h[1] <= r[1] and h[2] >= r[2]) then return false end
			if h[3] > h[1] then return true end -- (it filled up there: the rest is asked for again)
		end
	end
	return true
end

-- Another officer's answer beginning (its first piece) while ours waits (Comm.pieceHooks).
local function OnPiece(dist, sender, text)
	local a = answering
	if not a or dist ~= "GUILD" or type(text) ~= "string" then return end
	local head = text:match("^C%w+:1:%d+:XB~([^%^]*)")
	head = head and SenderOfficer(sender) and Head(head)
	if head and Covers(head, a) then a.heard = true end
end
local function HookPieces()
	local hooks = ns.Comm and ns.Comm.pieceHooks
	if hooks then hooks.loot = answering and OnPiece or nil end
end

-- Our turn among our guild's officers whose addon said hello lately (Comm.Peers), in an order
-- drawn from the ask itself: the first answers, the next only if the first did not.
local function Hash(s)
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
	return h
end
local function Turn(salt)
	local mine, turn = Hash(salt .. ns.Fold(ns.FullName(ns.me or ""))), 0
	for _, name in ipairs(ns.Comm.Peers and ns.Comm.Peers() or {}) do
		local full = ns.FullName(name)
		if full ~= ns.FullName(ns.me or "") and SenderOfficer(full) and Hash(salt .. ns.Fold(full)) < mine then turn = turn + 1 end
	end
	return math.min(turn, 4)
end

local function Answer(a)
	if answering ~= a then return end
	if a.heard or not Loot.IsOfficer() then
		answering = nil
		return HookPieces()
	end
	-- Our census and hellos first: the answer waits while our queue is long, then gives up (the
	-- asker asks again).
	if ns.Comm.QueueSize and ns.Comm.QueueSize() > Loot.QUEUE_MAX then
		a.tries = a.tries + 1
		if a.tries <= 3 then return Loot.after(5, "loot answer", function() Answer(a) end) end
		answering = nil
		return HookPieces()
	end
	answering = nil
	HookPieces()
	local b = Book()
	if not b then return end
	lastAnswer = ns.Now()
	pageTimes[#pageTimes + 1] = lastAnswer
	ns.Comm.SendChunked(Loot.Page(b, a), nil, "GUILD")
end

-- A guildmate's ask (XQ): an officer's addon answers the ranges it holds whole itself, when its
-- turn comes (SLOT apart among the officers online), unless another officer's answer began.
function Loot.HandleAsk(dist, sender, text)
	if dist ~= "GUILD" or type(text) ~= "string" or not ns.Roster.RankOf(sender) then return end -- (a guildmate our roster knows)
	local a1, a2, a3, a4 = text:match("^XQ~([0-9a-z]+)~([0-9a-z]+)~([0-9a-z]+)~([0-9a-z]+)$")
	local n1, n2, p1, p2 = UnB36(a1), UnB36(a2), UnB36(a3), UnB36(a4)
	if not (n1 and n2 and p1 and p2) or n2 > ServerNow() + 3600 or p2 > ServerNow() + 3600 then return end
	local want = { n = n1 < n2 and { n1, n2 } or nil, p = p1 < p2 and { p1, p2 } or nil }
	if not (want.n or want.p) then return end
	local now = ns.Now()
	heardAsk = { n = want.n, p = want.p, t = now }
	if not Loot.IsOfficer() then return end
	local b, live = Book()
	if not b then return end
	for _, kind in ipairs(STREAMS) do
		local r = want[kind]
		if r and not Holds(b, kind, live, r[1], r[2]) then want[kind] = nil end
	end
	if not (want.n or want.p) then return end
	sender = ns.FullName(sender)
	local times = askerTimes[sender] or {}
	askerTimes[sender] = times
	if Recent(times, Loot.WINDOW) >= Loot.ASKER_ASKS then return end
	times[#times + 1] = now
	if answering then
		-- One answer covers the asks that come meanwhile: their ranges joined.
		for _, kind in ipairs(STREAMS) do
			local r, o = want[kind], answering[kind]
			if r then answering[kind] = o and { math.min(o[1], r[1]), math.max(o[2], r[2]) } or r end
		end
		return
	end
	if Recent(pageTimes, Loot.WINDOW) >= Loot.WINDOW_PAGES then return end
	local a = { n = want.n, p = want.p, tries = 0 }
	answering = a
	HookPieces()
	local delay = math.max(2 + Turn(text) * Loot.SLOT + Loot.random() * 3, lastAnswer + Loot.PAGE_GAP - now)
	Loot.after(delay, "loot answer", function() Answer(a) end)
end
ns.Comm.Handle("XQ", function(...) Loot.HandleAsk(...) end)

-- Two officers' books can grow apart (one wrote while the other was away, who then took his own
-- as the guild's: Loot.Settle). An officer's addon hearing another's answer that lacks changes of
-- its own in the spans that answer holds whole sends them to the guild too, a moment later,
-- unless an answer heard meanwhile carried them (a head of no span: "XB~S~0~0~0~0~0~0^...").
local pushing -- { [entry] = its change time }: ours waiting to go
local function Push(b, head, seen)
	if not Loot.IsOfficer() then return end
	local extra = {}
	for _, kind in ipairs(STREAMS) do
		local h = head[kind]
		if h[3] < h[2] then
			for _, e in ipairs(Entries(b, kind, h[3], h[2])) do
				if not seen[e.entry] then extra[e.entry] = e.rev end
			end
		end
	end
	if next(extra) == nil then return end
	if pushing then
		for e, r in pairs(extra) do pushing[e] = r end
		return
	end
	local p = extra
	pushing = p
	Loot.after(2 + Loot.random() * 5, "loot push", function()
		if pushing == p then pushing = nil end
		if not Loot.IsOfficer() or Recent(pageTimes, Loot.WINDOW) >= Loot.WINDOW_PAGES then return end
		local list = {}
		for e, r in pairs(p) do list[#list + 1] = { entry = e, rev = r } end
		if #list == 0 then return end
		table.sort(list, function(x, y) if x.rev ~= y.rev then return x.rev > y.rev end return x.entry < y.entry end)
		local out, size = {}, 0
		for _, e in ipairs(list) do
			if size + #e.entry + 1 > Loot.ANSWER_BYTES - HEAD_ROOM then break end
			out[#out + 1], size = e.entry, size + #e.entry + 1
		end
		lastAnswer = ns.Now()
		pageTimes[#pageTimes + 1] = lastAnswer
		ns.Comm.SendChunked("XB~S~0~0~0~0~0~0^" .. table.concat(out, "^"), nil, "GUILD")
	end)
end

-- XB: an officer's answer (in pieces over GUILD, Comm.lua), taken entry by entry; what its head
-- says it holds whole is ours whole too then.
function Loot.HandleBook(dist, sender, text)
	if dist ~= "GUILD" or type(text) ~= "string" or not SenderOfficer(sender) then return end
	local b, live = Book()
	local body = b and text:match("^XB~(.+)$")
	local head = body and Head(body:match("^[^%^]*"))
	if not head then return end
	heardPage = ns.Now()
	if answering and Covers(head, answering) then answering.heard = true end
	local changed, seen = false, {}
	for entry in body:gmatch("[^%^]+") do
		seen[entry] = true
		if pushing then pushing[entry] = nil end
		if Take(b, entry, sender, false, live) then changed = true end
	end
	for _, kind in ipairs(STREAMS) do
		local h = head[kind]
		AddRange(Ranges(b, kind), h[3], h[2], Loot.KNOWN_MAX)
	end
	if changed then
		Loot.Prune(b)
		Changed()
	end
	Push(b, head, seen)
	Continue()
end
ns.Comm.Handle("XB", function(...) Loot.HandleBook(...) end)

---------------------------------------------------------------------------
-- The group's loot, for the officers' notes (the game's own loot lines, this session)
---------------------------------------------------------------------------

-- The game's loot line as a pattern: "%s receives loot: %s." -> "^(.+) receives loot: (.+)%.$".
local function Pattern(fmt)
	if type(fmt) ~= "string" or fmt == "" then return nil end
	local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
	return "^" .. p .. "$"
end

-- A loot line of the group's: the item (rare and better, or not yet known to the client) and who got
-- it, kept for the officers to write its note with a click. Nothing else is done with it.
function Loot.OnLootMessage(text)
	if type(text) ~= "string" or not (IsInGroup and IsInGroup()) or not Loot.IsOfficer() then return end
	local link = text:match("|c%x+|Hitem:[^|]+|h%[[^%]]*%]|h|r") or text:match("|Hitem:[^|]+|h%[[^%]]*%]|h")
	local id = link and tonumber(link:match("|Hitem:(%d+)"))
	if not id then return end
	local quality
	if GetItemInfo then
		local ok, _, _, q = pcall(GetItemInfo, link)
		if ok then quality = q end
	end
	if quality and quality < 3 then return end
	local to
	for _, fmt in ipairs({ LOOT_ITEM, LOOT_ITEM_MULTIPLE }) do
		local p = Pattern(fmt)
		local who = p and text:match(p)
		if who then to = who break end
	end
	if not to then
		for _, fmt in ipairs({ LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE }) do
			local p = Pattern(fmt)
			if p and text:match(p) then to = ns.ShortName(ns.me) break end
		end
	end
	if not to then return end
	table.insert(drops, 1, { id = id, link = link, to = Clean(ns.ShortName(to), Loot.TO_MAX), t = ns.Now() })
	while #drops > Loot.DROPS_MAX do table.remove(drops) end
	Changed()
end
function Loot.Drops() return drops end

---------------------------------------------------------------------------
-- The page (the Realm tab)
---------------------------------------------------------------------------

local function Grey(s) return "|cff9d9d9d" .. s .. "|r" end
local function Gold(s) return "|cffffd200" .. s .. "|r" end
local function Green(s) return "|cff40ff40" .. s .. "|r" end

-- An item as a line shows it: the game's link once the client knows it, else "item #id".
local function ItemText(id)
	if not id then return nil end
	if GetItemInfo then
		local ok, name, link = pcall(GetItemInfo, id)
		if ok and type(link) == "string" then return link end
		if ok and type(name) == "string" then return "[" .. name .. "]" end
	end
	return "[" .. L.LOOT_ITEM_N:format(id) .. "]"
end
local function ItemName(id)
	if not id then return nil end
	if GetItemInfo then
		local ok, name = pcall(GetItemInfo, id)
		if ok and type(name) == "string" then return name end
	end
	return L.LOOT_ITEM_N:format(id)
end

-- The notes shown (removed ones left out), newest first.
function Loot.Notes()
	local b, out = Book(), {}
	for key, n in pairs(b and b.notes or {}) do
		if type(n) == "table" and not n.del then out[#out + 1] = { key = key, n = n } end
	end
	table.sort(out, function(a, c)
		if a.n.t ~= c.n.t then return (a.n.t or 0) > (c.n.t or 0) end
		return a.key < c.key
	end)
	return out
end

-- The points set (cleared ones left out), most first.
function Loot.Points()
	local b, out = Book(), {}
	for member, p in pairs(b and b.points or {}) do
		if type(p) == "table" and p.v then out[#out + 1] = { member = member, v = p.v, by = p.by, rev = p.rev, via = p.via } end
	end
	table.sort(out, function(a, c) if a.v ~= c.v then return a.v > c.v end return a.member < c.member end)
	return out
end

local function Date(t) return date("%Y-%m-%d", t) end
-- A note's writer as a line names him, and the officer who passed it on to us, if one did: it
-- comes on his word, so he is named with it (Konig's review of 1.1).
local function Who(n)
	local who = ns.ShortName(ns.DisplayName(n.writer) or "?")
	if n.via then who = L.LOOT_VIA:format(who, ns.ShortName(ns.DisplayName(n.via) or "?")) end
	return who
end

function Loot.Show(open)
	if open then
		ns.Views.ShowPage("loot")
		-- The book may lack changes (a login on the Forever beta, a guildmate offline when they were
		-- made): asked for, and again when the page opens later while something still lacks.
		if asks == 0 or ns.Now() - lastAsk >= Loot.ASK_AGAIN then Loot.Ask() end
	else
		ns.Views.ShowPage(nil)
	end
end

function Loot.Link()
	local guild = ns.IsMember() and Loot.Guild()
	if not guild then return nil end
	local n = #Loot.Notes()
	return {
		text = "|TInterface\\Icons\\INV_Misc_Note_01:14:14|t " .. Gold(L.LOOT_LINK:format(guild)),
		right = n > 0 and Grey(tostring(n)) or nil,
		onClick = function() Loot.Show(true) end,
		tooltip = function(tt)
			tt:AddLine(L.LOOT_LINK:format(guild), 1, 0.82, 0)
			tt:AddLine(L.LOOT_LINK_TIP, 1, 1, 1, true)
		end,
	}
end

-- The page's lines; `q`, the Realm's search: notes and points whose words hold it.
function Loot.Lines(q)
	local officer = Loot.IsOfficer()
	local guild = Loot.Guild() or "?"
	local lines = { { text = Gold(L.CHATS_BACK), onClick = function() Loot.Show(false) end, gapAfter = true } }
	lines[#lines + 1] = { header = true, text = L.LOOT_TITLE:format(guild),
		tooltip = function(tt)
			tt:AddLine(L.LOOT_TITLE:format(guild), 1, 0.82, 0)
			tt:AddLine(L.LOOT_ABOUT, 1, 1, 1, true)
		end }
	if officer and not q then
		lines[#lines + 1] = { text = Green(L.LOOT_WRITE), onClick = function() ns.ShowDialog("SYLVANISTAS_LOOT_NOTE", L.LOOT_NOTE_PROMPT, nil, {}) end,
			tooltip = function(tt) tt:AddLine(L.LOOT_WRITE, 1, 0.82, 0); tt:AddLine(L.LOOT_WRITE_TIP, 1, 1, 1, true) end }
		lines[#lines + 1] = { text = Green(L.LOOT_POINTS_SET), onClick = function() ns.ShowDialog("SYLVANISTAS_LOOT_POINTS", nil, nil, "") end,
			tooltip = function(tt) tt:AddLine(L.LOOT_POINTS_SET, 1, 0.82, 0); tt:AddLine(L.LOOT_POINTS_SET_TIP, 1, 1, 1, true) end }
		lines[#lines].gapAfter = true
		-- The group's loot this session: a click writes its note.
		if #drops > 0 then
			lines[#lines + 1] = { header = true, text = L.LOOT_DROPS }
			for _, d in ipairs(drops) do
				lines[#lines + 1] = { indent = 1, text = (ItemText(d.id) or "?") .. "  " .. Grey("> " .. d.to), right = Grey(ns.Ago(d.t)),
					onClick = function()
						ns.ShowDialog("SYLVANISTAS_LOOT_NOTE", L.LOOT_NOTE_FOR:format(ItemName(d.id), d.to), nil, { item = d.id, to = d.to })
					end,
					tooltip = function(tt)
						if tt.SetHyperlink then pcall(tt.SetHyperlink, tt, "item:" .. d.id) end
						tt:AddLine(L.LOOT_DROP_TIP, 0.6, 0.6, 0.6, true)
					end }
			end
			lines[#lines].gapAfter = true
		end
	end
	local notes, shown = Loot.Notes(), 0
	for _, e in ipairs(notes) do
		local n = e.n
		local what = (n.item and (ItemText(n.item) .. " ") or "") .. (n.to and Gold("> " .. n.to) .. "  " or "") .. n.text
		if not q or ns.Holds(q, n.text, n.to, n.item and ItemName(n.item), ns.DisplayName(n.writer)) then
			shown = shown + 1
			lines[#lines + 1] = {
				text = what, right = Grey(Who(n) .. "  " .. Date(n.t)),
				onClick = officer and function() ns.ShowDialog("SYLVANISTAS_LOOT_REMOVE", n.text, nil, e.key) end or nil,
				tooltip = function(tt)
					if n.item and tt.SetHyperlink then pcall(tt.SetHyperlink, tt, "item:" .. n.item) end
					tt:AddLine(n.text, 1, 1, 1, true)
					tt:AddLine(L.LOOT_NOTE_TIP:format(ns.DisplayName(n.writer) or "?", date("%Y-%m-%d %H:%M", n.t)), 0.6, 0.6, 0.6, true)
					if n.via then tt:AddLine(L.LOOT_VIA_TIP:format(ns.DisplayName(n.via) or "?"), 0.6, 0.6, 0.6, true) end
					if officer then tt:AddLine(L.LOOT_REMOVE_TIP, 0.6, 0.6, 0.6, true) end
				end,
			}
		end
	end
	if #notes == 0 and not q then lines[#lines + 1] = { text = Grey(officer and L.LOOT_EMPTY_OFFICER or L.LOOT_EMPTY) } end
	-- The points, if the guild uses them: a column of numbers set by hand.
	local points, found = Loot.Points(), 0
	if #points > 0 then
		local header = { header = true, text = L.LOOT_POINTS_TITLE,
			tooltip = function(tt) tt:AddLine(L.LOOT_POINTS_TITLE, 1, 0.82, 0); tt:AddLine(L.LOOT_POINTS_TIP, 1, 1, 1, true) end }
		for _, p in ipairs(points) do
			if not q or ns.Holds(q, ns.DisplayName(p.member)) then
				if found == 0 then
					if lines[#lines] then lines[#lines].gapAfter = true end
					lines[#lines + 1] = header
				end
				found = found + 1
				lines[#lines + 1] = { indent = 1, text = ns.DisplayName(p.member), right = Gold(tostring(p.v)),
					onClick = officer and function() ns.ShowDialog("SYLVANISTAS_LOOT_POINTS", nil, nil, ns.DisplayName(p.member) .. " " .. p.v) end or nil,
					tooltip = function(tt)
						tt:AddLine(ns.DisplayName(p.member), 1, 0.82, 0)
						tt:AddLine(L.LOOT_POINTS_BY:format(ns.DisplayName(p.by) or "?", date("%Y-%m-%d %H:%M", p.rev)), 1, 1, 1, true)
						if p.via then tt:AddLine(L.LOOT_VIA_TIP:format(ns.DisplayName(p.via) or "?"), 0.6, 0.6, 0.6, true) end
					end }
			end
		end
	end
	if q and shown == 0 and found == 0 then lines[#lines + 1] = { text = Grey(L.SEARCH_NO_MATCH) } end
	if not q and (#notes > 0 or #points > 0) then
		if lines[#lines] then lines[#lines].gapAfter = true end
		lines[#lines + 1] = { text = Gold(L.COPY_DISCORD), onClick = function() ns.UI.ShowCopy(L.LOOT_TITLE:format(guild), Loot.DiscordText()) end }
	end
	return lines
end

-- The book as text for Discord: the notes, then the points.
function Loot.DiscordText()
	local guild = Loot.Guild() or "?"
	local out = { "**" .. L.LOOT_TITLE:format(guild) .. "**" }
	for _, e in ipairs(Loot.Notes()) do
		local n = e.n
		out[#out + 1] = ("%s %s%s%s (%s)"):format(Date(n.t), n.item and ("[" .. ItemName(n.item) .. "] ") or "",
			n.to and ("> " .. n.to .. ": ") or "", n.text, Who(n))
	end
	local points = Loot.Points()
	if #points > 0 then
		out[#out + 1] = "**" .. L.LOOT_POINTS_TITLE .. "**"
		for _, p in ipairs(points) do out[#out + 1] = ("%s: %d"):format(ns.DisplayName(p.member), p.v) end
	end
	return ns.Codec.NoMentions(table.concat(out, "\n"))
end

-- The dialogs: a note's words (data: { item, to }), a note's removal (data: its key), points
-- ("Name 12"; data: the text the box starts with).
StaticPopupDialogs["SYLVANISTAS_LOOT_NOTE"] = {
	text = "%s",
	button1 = L.LOOT_SAVE,
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 320,
	maxLetters = Loot.TEXT_MAX,
	OnShow = function(self)
		local eb = self.editBox or self.EditBox
		if eb then eb:SetText(""); eb:SetFocus() end
	end,
	OnAccept = function(self, data)
		local eb = self.editBox or self.EditBox
		data = data or {}
		ns.SafeCall("loot note", Loot.Write, eb and eb:GetText(), data.item, data.to)
	end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		local data = parent.data or {}
		ns.SafeCall("loot note", Loot.Write, self:GetText(), data.item, data.to)
		parent:Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
StaticPopupDialogs["SYLVANISTAS_LOOT_REMOVE"] = {
	text = L.LOOT_REMOVE_PROMPT,
	button1 = L.LOOT_REMOVE_BTN,
	button2 = CANCEL or "Cancel",
	OnAccept = function(self, key) ns.SafeCall("loot remove", Loot.Remove, key or (self and self.data)) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
StaticPopupDialogs["SYLVANISTAS_LOOT_POINTS"] = {
	text = L.LOOT_POINTS_PROMPT,
	button1 = L.LOOT_SAVE,
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 220,
	maxLetters = 80,
	OnShow = function(self, data)
		local eb = self.editBox or self.EditBox
		if eb then eb:SetText(type(data) == "string" and data or ""); eb:SetFocus() end
	end,
	OnAccept = function(self)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("loot points", Loot.SetPoints, eb and eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		ns.SafeCall("loot points", Loot.SetPoints, self:GetText())
		parent:Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

ns.RealmPages = ns.RealmPages or {}
table.insert(ns.RealmPages, { key = "loot", Link = function() return Loot.Link() end, Lines = function(q) return Loot.Lines(q) end, tip = "LOOT" })

ns.On("LOGIN", function()
	ns.RegisterEvent("CHAT_MSG_LOOT", function(text) Loot.OnLootMessage(text) end)
	-- An officer's addon asks for the changes it lacks once the roster is in (the answers are
	-- taken from officers our roster knows); nobody answering, its book is the guild's.
	ns.After(50 + Loot.random() * 30, "loot ask", function()
		if Loot.IsOfficer() and asks == 0 then Loot.Ask() end
	end)
end)

-- Tests start from a clean state.
function Loot.Reset()
	answering, lastAnswer, counter = nil, -math.huge, 0
	asks, lastAsk, wanting, continuing, heardAsk, heardPage, pushing = 0, -math.huge, false, false, nil, -math.huge, nil
	settling = false
	wipe(drops); wipe(pageTimes); wipe(askerTimes); wipe(liveFrom)
	HookPieces()
end
