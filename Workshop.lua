local ADDON, ns = ...
local L = ns.L

-- The Workshop: the addon author's own tab (his character alone, ns.AUTHOR), to see how the
-- addon does across the army and to help the players who run it.
--   * Installs and versions per guild, from the reports every guild sends anyway (field 24:
--     the versions of the guild's addon users, counted by its reporter from their hellos).
--   * A roll call on demand: each addon answers with its version, client, window and what
--     works (V1/V2); when the army is large, only a share of them answers.
--   * Every answer, searchable by name, guild or version, 25 at a time (0.9.9); a full roll
--     call, one roll call every ROLL_EVERY until nearly every addon user answered; and one
--     player asked alone by whisper, on the channel or not (0.9.9 and newer answer it).
--   * A report to copy for Discord.
--   * "Please update", to a player on an old version: a fixed text, nothing else (V3).
--   * The author's presence (V4): players can send him their bug report from the Report a
--     bug window (V5), and nowhere else.
-- Only the character named ns.AUTHOR can send V1, V3 and V4, and only he receives V2 and V5.
-- Forever names (first name and surname) are unique across its realm group, and on the
-- Classic realms no name has a space: nobody else can carry his. Receivers answer a roll call
-- once per ROLL_GAP, and show "please update" once per UPDATE_GAP, only when really behind.
--   V1~<id>~<share 1-100>                                              (channel)
--   V1~<id>~100    the author asks this player alone (0.9.9; 0.9.8 takes V1 from the channel only)  (whisper)
--   V2~<id>~<version>~<guild>~<client>~<window>~<flags>~<errors>~<level>~<class>   (whisper)
--   V3~<latest version>                                                (whisper)
--   V4~<version>[~<released>]  (1.1: the version he marked as out, /syl released; 1.0 and 0.9 read "V4~" alone)  (channel)
--   V5~<id>~<i>~<n>~<piece>                                            (whisper)
--   V6~<id>~<1|2>   the author got piece 1 (send the rest) | the whole report   (whisper)
-- A bug report goes out one piece first: only once the author answers (he is really online)
-- does the rest follow, so nothing is whispered to someone who logged off.

local Workshop = {}
ns.Workshop = Workshop

Workshop.ROLL_GAP = 4 * 60      -- a client answers one roll call in this long (the author asks every 5 min at most)
Workshop.ROLL_EVERY = 5 * 60    -- the author asks at most this often
Workshop.ROLL_OPEN = 5 * 60     -- answers count this long after the ask
Workshop.ROLL_SPREAD = 30       -- answers are spread over this many seconds
Workshop.ROLL_TARGET = 300      -- answers wanted, however large the army (the share)
Workshop.MAX_ANSWERS = 3000     -- answers kept (a full roll call keeps more: Cap)
Workshop.MAX_ANSWERS_FULL = 10000 -- ...never more than this: 95% of a larger army is more than it can count
Workshop.UPDATE_GAP = 10 * 60   -- "please update" at most this often, both ways
Workshop.PRESENCE_EVERY = 5 * 60
Workshop.PRESENCE_FRESH = 11 * 60
Workshop.ROLL_AFTER = 90        -- no roll call this soon after login: the census is still coming
Workshop.ASK_EVERY = 20         -- "Ask to update" at most this often (the send queue holds 60)
Workshop.BUG_ACK = 15           -- the author answers the first piece within this, or is offline
Workshop.BUG_GAP = 10 * 60      -- a player sends one bug report in this long
Workshop.BUG_MAX = 4800         -- bytes of a bug report (MAX_PIECES pieces)
Workshop.PIECE = 200
Workshop.MAX_PIECES = 25
Workshop.MAX_REPORTS = 30
Workshop.MAX_SHOWN = 30
Workshop.MAX_ASK = 15           -- "please update" whispers per click (the send queue holds 60)
Workshop.ROLL_PAGE = 25         -- answers listed, 25 more a click (the window stays light)
Workshop.ROLL_ROUNDS = 20       -- a full roll call stops after this many rounds...
Workshop.ROLL_ENOUGH = 95       -- ...or once this share (%) of the addon users the census counts answered
Workshop.ASK_ONE_EVERY = 10     -- the author asks one player by whisper at most this often
Workshop.ASK_ONE_SPREAD = 2     -- ...and that player's addon answers within 1 + this many seconds

-- Swappable in tests.
Workshop.random = math.random
Workshop.after = function(seconds, where, fn) ns.After(seconds, where, fn) end

local roll            -- the author's roll calls: { id, t, share, ids = { [id] = asked at }, alone = { [id] = folded name },
                      -- answers = { [sender] = answer }, count }
                      -- answers stay from one roll call to the next (a newer answer replaces);
                      -- each ask's id (a roll call, a player asked alone) takes answers for ROLL_OPEN
local full            -- the full roll call: { running, started, round, users, nextAt, reason, token }
local search = ""     -- the tab's search box, as typed
local shownAnswers = Workshop.ROLL_PAGE -- answers listed ("Show more", "Show all", "Show fewer")
local menuFor         -- the answer whose actions are open under its row
local askedOne = {}   -- [folded Name-Realm] = when the author asked them alone
local lastAskOne = -math.huge
local reports = {}    -- bug reports received: { from, t, text }, newest last
local pieces = {}     -- [sender#id] = { n, got, parts, t }
local bugsFrom = {}   -- [sender] = times of their reports this hour
local asked = {}      -- [sender] = when we last asked them to update
local lastRoll, lastRollAnswer, lastUpdateShown, lastBug = -math.huge, -math.huge, -math.huge, -math.huge
local lastAsk = -math.huge
local answeredRoll    -- the roll call id we answered last
local sending         -- our bug report waiting for the author's go: { id, pieces, to }
local authorAt, authorName -- the author's last presence, and his full name
local changePending = false

local function Changed()
	if changePending then return end
	changePending = true
	Workshop.after(1, "workshop changed", function()
		changePending = false
		ns.Fire("WORKSHOP_CHANGED")
	end)
end

---------------------------------------------------------------------------
-- Who is who
---------------------------------------------------------------------------

-- His name, on his realm group (Forever's PvP realms).
local function IsAuthorName(name)
	if type(name) ~= "string" or ns.ShortName(name) ~= ns.AUTHOR then return false end
	local realm = ns.RealmOf(ns.FullName(name))
	return realm ~= nil and ns.GroupOf(realm) == ns.GroupOf(ns.AUTHOR_REALM)
end

function Workshop.IsAuthor() return IsAuthorName(ns.me) end
Workshop.IsAuthorName = IsAuthorName

-- The author's test characters (Dev.lua, never published) see the tab too: nothing it sends
-- goes anywhere but the test bench's log (DevTest.lua), or is ignored by everyone.
function Workshop.Preview()
	local dev = ns.devWorkshop
	if type(dev) == "table" then dev = dev[UnitName and UnitName("player") or ""] == true or dev[ns.ShortName(ns.me or "")] == true end
	return dev == true and not Workshop.IsAuthor()
end

function Workshop.Visible() return Workshop.IsAuthor() or Workshop.Preview() end

-- The author is online (his presence was heard lately), and not us.
function Workshop.AuthorOnline()
	if Workshop.IsAuthor() or not authorAt then return false end
	return ns.Now() - authorAt <= Workshop.PRESENCE_FRESH
end
function Workshop.AuthorName() return authorName end

---------------------------------------------------------------------------
-- Versions
---------------------------------------------------------------------------

-- "0.8.2" -> { 0, 8, 2 }; anything else -> nil.
local function Parts(v)
	local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	return { tonumber(a), tonumber(b), tonumber(c) }
end

-- a is newer than b.
function Workshop.Newer(a, b)
	local x, y = Parts(a), Parts(b)
	if not x or not y then return false end
	for i = 1, 3 do
		if x[i] ~= y[i] then return x[i] > y[i] end
	end
	return false
end

-- The newest version: the author's own, who runs the newest. What others claim never raises
-- it (anyone can send any number), so "please update" never names a version that is not out.
function Workshop.Latest() return ns.VERSION end

---------------------------------------------------------------------------
-- This client, as a roll call answer tells it
---------------------------------------------------------------------------

-- Plain text: no separators, escape codes, Discord markup (` @) or control characters.
local function Clean(s, max)
	return (tostring(s or ""):gsub("[~|`@%c]", "")):sub(1, max or 40)
end

-- Only values a real addon sends: anything else becomes "?".
local CLIENTS = { Forever = true, Era = true, Anniversary = true }
local WINDOWS = { hd = true, old = true }
local function Version(v) return (type(v) == "string" and v:match("^%d+%.%d+%.%d+$")) and v or "?" end

-- Which game: by the interface number (Forever 1.60, Era 1.15, Anniversary 2.5).
function Workshop.Client()
	local toc = select(4, GetBuildInfo())
	toc = tonumber(toc) or 0
	if toc >= 16000 and toc < 20000 then return "Forever" end
	if toc >= 20000 and toc < 30000 then return "Anniversary" end
	if toc >= 10000 and toc < 16000 then return "Era" end
	return tostring(toc)
end

-- Letters for what works here: c channel joined, r our guild's reporter, k sealed channel,
-- m map library, p map markers on.
function Workshop.Flags()
	local f = {}
	if ns.Comm.ChannelReady() then f[#f + 1] = "c" end
	if ns.Comm.isReporter then f[#f + 1] = "r" end
	if ns.rdb and ns.rdb.realmKey then f[#f + 1] = "k" end
	if ns.Pins and ns.Pins() then f[#f + 1] = "m" end
	if ns.db and ns.db.showMap then f[#f + 1] = "p" end
	return table.concat(f)
end

-- What a roll call gets (0.9.2): the addon's version, the game client, and the channel's state
-- (joined, our guild's reporter, sealed). Nothing about the character: no guild, level or class,
-- no window style, no error count (those fields stay, empty, for the author's older version).
local function Answer(id)
	local flags = Workshop.Flags():gsub("[^crk]", "")
	return ("V2~%d~%s~~%s~~%s~0~0~"):format(id, Clean(ns.VERSION, 12), Workshop.Client(), flags)
end

-- A player can refuse the author's roll calls and update notices: /syl rollcall off (0.9.2).
-- 1.1 (Fern's #11): the roll call is answered only after a yes (the first-open page, or /syl
-- rollcall on): nil, never answered, is off. The update notice sends nothing, so it still shows
-- until a No (Workshop.Notices).
function Workshop.Answers() return ns.db ~= nil and ns.db.rollCall == true end
function Workshop.Notices() return not (ns.db and ns.db.rollCall == false) end
function Workshop.AnswerState()
	local v = ns.db and ns.db.rollCall
	return v == true and "answered" or (v == false and "refused" or "not chosen (not answered)")
end
function Workshop.SetAnswers(on)
	ns.db.rollCall = on and true or false
	ns.Print(on and L.ROLLCALL_ON or L.ROLLCALL_OFF)
end

---------------------------------------------------------------------------
-- Text for the search and "Ask <name>" (0.9.9)
---------------------------------------------------------------------------

local function TrimText(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- Letters folded for the search (ns.Fold, Core.lua: the tabs' searches fold them the same way).
local Fold = ns.Fold
Workshop.Fold = Fold

-- A player's name as the author may type it: letters (any, UTF-8 ones too), Forever's "First
-- Surname" with its one space, with "-Realm" or not. A version or a guild with digits is not one.
local function NameLike(s)
	if type(s) ~= "string" or #s < 2 or #s > 48 then return false end
	local name, realm = s:match("^([^%-]+)%-([^%-]+)$")
	name = name or s
	if realm and realm:find("[%s~|%c]") then return false end
	return name:find("^[%a\128-\255]+$") ~= nil or name:find("^[%a\128-\255]+ [%a\128-\255]+$") ~= nil
end
Workshop.NameLike = NameLike

---------------------------------------------------------------------------
-- Roll call
---------------------------------------------------------------------------

-- How many of the army answer: all of it while small, a share of it once large.
function Workshop.Share(users)
	users = tonumber(users) or 0
	if users <= Workshop.ROLL_TARGET then return 100 end
	return math.max(5, math.min(100, math.ceil(Workshop.ROLL_TARGET * 100 / users)))
end

-- The addon users the reports count, over every fresh guild.
function Workshop.ReportedUsers()
	local n, now = 0, ns.Now()
	for name, g in pairs(ns.rdb and ns.rdb.guilds or {}) do
		if type(g) == "table" and ns.IsFederation(name) and now - (g.t or 0) <= ns.Data.FRESH then n = n + (g.users or 0) end
	end
	return n
end

-- A new ask (a roll call, or one player asked alone): its id takes answers for ROLL_OPEN. The
-- answers so far stay: a newer one replaces a player's older one.
local function NewAsk(now)
	roll = roll or { answers = {}, count = 0, ids = {}, alone = {} }
	for id, t in pairs(roll.ids) do
		if now - t > Workshop.ROLL_OPEN then roll.ids[id], roll.alone[id] = nil, nil end
	end
	local id = Workshop.random(1, 99999)
	roll.ids[id], roll.alone[id] = now, nil
	return id
end

-- A roll call on the channel, to the share of the army `users` asks for (0.9.8 clients take it
-- as ever: the format never changes).
local function SendRoll(users, now)
	lastRoll = now
	local share = Workshop.Share(users)
	local id = NewAsk(now)
	roll.id, roll.t, roll.share = id, now, share
	ns.Comm.Send("CHANNEL", ("V1~%d~%d"):format(id, share), "rollcall")
	return share
end

-- Before the census is in, the army's size is unknown: every addon would answer.
local function CensusIn(now)
	local users = Workshop.ReportedUsers()
	if users == 0 or now - (ns.Comm.loginAt or 0) < Workshop.ROLL_AFTER then return nil end
	return users
end

function Workshop.RollCall()
	if not Workshop.Visible() then return end
	local now = ns.Now()
	if now - lastRoll < Workshop.ROLL_EVERY then
		return ns.Print(L.WORKSHOP_ROLL_WAIT:format(math.ceil((Workshop.ROLL_EVERY - (now - lastRoll)) / 60)))
	end
	local users = CensusIn(now)
	if not users then return ns.Print(L.WORKSHOP_ROLL_EARLY) end
	ns.Print(L.WORKSHOP_ROLL_SENT:format(SendRoll(users, now)))
	Changed()
end

-- A roll call reaches us on the channel (a share of the army answers), or by whisper (0.9.9:
-- the author asks this player alone, V1~<id>~100). Either way the author's alone, once per
-- ROLL_GAP; asked alone, the answer goes within ASK_ONE_SPREAD seconds or so.
function Workshop.HandleRoll(dist, sender, text)
	local alone = dist == "WHISPER"
	if (dist ~= "CHANNEL" and not alone) or not IsAuthorName(sender) or Workshop.IsAuthor() or not Workshop.Answers() then return end
	local id, share = text:match("^V1~(%d+)~(%d+)$")
	id, share = tonumber(id), tonumber(share)
	if not id or not share then return end
	authorAt, authorName = ns.Now(), ns.FullName(sender)
	local now = ns.Now()
	if id == answeredRoll or now - lastRollAnswer < Workshop.ROLL_GAP then return end
	answeredRoll = id
	if Workshop.random(1, 100) > math.max(1, math.min(100, share)) then return end
	lastRollAnswer = now
	-- Spread over ROLL_SPREAD: a thousand answers do not arrive in the same second.
	local spread = alone and Workshop.ASK_ONE_SPREAD or Workshop.ROLL_SPREAD
	Workshop.after(1 + Workshop.random() * spread, "roll call answer", function()
		ns.Comm.Whisper(ns.FullName(sender), Answer(id), "rollanswer")
	end)
end

---------------------------------------------------------------------------
-- The full roll call (0.9.9): a roll call every ROLL_EVERY, each to the share a single one asks
-- (Share: never more answers than one roll call), until ROLL_ENOUGH % of the addon users the
-- census counts answered, ROLL_ROUNDS rounds went out, or the author stops it.
---------------------------------------------------------------------------

-- The players who answered since it began, of the addon users the census counts (the latest
-- count while it runs), and the share of them in %.
local function FullCount()
	local n = 0
	for _, a in pairs(roll and roll.answers or {}) do
		if (a.t or 0) >= full.started then n = n + 1 end
	end
	if full.running then
		local users = Workshop.ReportedUsers()
		if users > 0 then full.users = users end
	end
	local m = math.max(1, full.users or 1)
	return n, m, math.min(100, math.floor(n * 100 / m))
end

-- The answers kept: MAX_ANSWERS; while a full roll call runs, room for its census and a tenth
-- more (players who answered before it began, or joined since), MAX_ANSWERS_FULL at most.
local function Cap()
	if not (full and full.running) then return Workshop.MAX_ANSWERS end
	return math.min(Workshop.MAX_ANSWERS_FULL, math.max(Workshop.MAX_ANSWERS, math.ceil((full.users or 0) * 1.1)))
end
Workshop.Cap = Cap

-- ROLL_ENOUGH % of `users` is more answers than a full roll call can keep: it could never end
-- on its own, so it does not run (or stops, the census having grown).
local function TooMany(users)
	return math.ceil(Workshop.ROLL_ENOUGH * (tonumber(users) or 0) / 100) > Workshop.MAX_ANSWERS_FULL
end

local function FinishFull(reason)
	full.running, full.reason, full.nextAt = false, reason, nil
	local n, m, pct = FullCount()
	ns.Print(L["WORKSHOP_FULL_" .. reason:upper()]:format(full.round, n, m, pct, Workshop.ROLL_ENOUGH, Workshop.MAX_ANSWERS_FULL))
	Changed()
end

-- Enough answered: it ends there.
local function FullEnough()
	local n, m = FullCount()
	if n * 100 < Workshop.ROLL_ENOUGH * m then return false end
	FinishFull("enough")
	return true
end

-- One round, then the next one ROLL_EVERY later, while this full roll call (token) runs. The
-- last round's answers get their ROLL_EVERY too before it ends.
local function FullRound(token)
	if not full or full.token ~= token or not full.running then return end
	if FullEnough() then return end
	if full.round >= Workshop.ROLL_ROUNDS then return FinishFull("rounds") end
	local now = ns.Now()
	local users = Workshop.ReportedUsers()
	if users > 0 then full.users = users end
	if TooMany(full.users) then return FinishFull("large") end
	SendRoll(full.users, now)
	full.round, full.nextAt = full.round + 1, now + Workshop.ROLL_EVERY
	Workshop.after(Workshop.ROLL_EVERY, "full roll call", function() FullRound(token) end)
	Changed()
end

function Workshop.FullRunning() return full ~= nil and full.running == true end
function Workshop.Full() return full end

function Workshop.StartFull()
	if not Workshop.Visible() or Workshop.FullRunning() then return false end
	local now = ns.Now()
	local users = CensusIn(now)
	if not users then
		ns.Print(L.WORKSHOP_ROLL_EARLY)
		return false
	end
	if TooMany(users) then
		ns.Print(L.WORKSHOP_FULL_TOO_MANY:format(Workshop.ROLL_ENOUGH, users, Workshop.MAX_ANSWERS_FULL))
		return false
	end
	local token = {}
	full = { running = true, started = now, round = 0, users = users, token = token }
	ns.Print(L.WORKSHOP_FULL_START:format(Workshop.ROLL_ENOUGH, users, Workshop.ROLL_ROUNDS))
	if roll and now - lastRoll < Workshop.ROLL_EVERY then
		-- A roll call went out moments ago: it is the first round, the next one ROLL_EVERY after it.
		full.round, full.started, full.nextAt = 1, lastRoll, lastRoll + Workshop.ROLL_EVERY
		Workshop.after(full.nextAt - now, "full roll call", function() FullRound(token) end)
		Changed()
	else
		FullRound(token)
	end
	return true
end

function Workshop.StopFull()
	if not Workshop.FullRunning() then return false end
	FinishFull("stopped")
	return true
end

-- The Workshop's button: starts one, or stops the one running.
function Workshop.ToggleFull()
	if Workshop.FullRunning() then return Workshop.StopFull() end
	return Workshop.StartFull()
end

-- The ask `id` went to this player alone ("Ask <name>"), by that name.
local function AskedAlone(id, sender) return roll.alone[id] ~= nil and roll.alone[id] == Fold(ns.ShortName(sender)) end

-- A new answer and the answers kept already fill the Cap: room for it, or false. The answers of
-- players asked alone stay (the author looked for them: they may be off the channel, where the
-- rounds never reach them).
--   * A full roll call counts the answers since it began: the older ones go, once per full
--     roll call (none can be older than it afterwards).
--   * The player the author asked alone, by name: the oldest answer goes, so the one he looks
--     for always shows. Anyone else's answer to that id is not kept.
local function MakeRoom(id, sender)
	if full and full.running and roll.pruned ~= full.token then
		roll.pruned = full.token
		for name, a in pairs(roll.answers) do
			if (a.t or 0) < full.started and not a.alone then roll.answers[name], roll.count = nil, roll.count - 1 end
		end
		if roll.count < Cap() then return true end
	end
	if not AskedAlone(id, sender) then return false end
	local oldest, oldestAny
	for _, a in pairs(roll.answers) do
		if not oldestAny or (a.t or 0) < (oldestAny.t or 0) then oldestAny = a end
		if not a.alone and (not oldest or (a.t or 0) < (oldest.t or 0)) then oldest = a end
	end
	oldest = oldest or oldestAny
	if oldest then roll.answers[oldest.name], roll.count = nil, roll.count - 1 end
	return true
end

function Workshop.HandleAnswer(dist, sender, text)
	if dist ~= "WHISPER" or not Workshop.Visible() or not roll then return end
	local id, version, guild, client, window, flags, errors, level, class =
		text:match("^V2~(%d+)~([^~]*)~([^~]*)~([^~]*)~([^~]*)~([^~]*)~(%d+)~(%d+)~([^~]*)$")
	id = tonumber(id)
	local now = ns.Now()
	local at = id and roll.ids[id]
	if not at or now - at > Workshop.ROLL_OPEN then return end
	sender = ns.FullName(sender)
	local before = roll.answers[sender]
	if before and before.roll == id then return end
	if not before and roll.count >= Cap() and not MakeRoom(id, sender) then return end
	if not before then roll.count = roll.count + 1 end
	local a = {
		name = sender, roll = id, version = Version(version), guild = Clean(guild, 40),
		client = CLIENTS[client] and client or "?", window = WINDOWS[window] and window or "?",
		flags = (flags or ""):gsub("[^crkmp]", ""):sub(1, 5), errors = math.min(tonumber(errors) or 0, 999),
		level = math.min(tonumber(level) or 0, 99), class = Clean(class, 2), t = now,
		alone = AskedAlone(id, sender) or (before and before.alone) or nil,
	}
	-- Folded once for the search (thousands of answers at each letter typed): the name as shown
	-- (for the order), the whole Name-Realm, the guild.
	a.foldedName, a.foldedFull, a.foldedGuild = Fold(ns.DisplayName(sender)), Fold(sender), Fold(a.guild)
	roll.answers[sender] = a
	if Workshop.FullRunning() then FullEnough() end
	-- 1.1.2: a player he asked alone answered: his results window (copyable), not a chat line;
	-- opened by the answer, not his click: no keyboard taken, and after a fight (Versions.ShowResults).
	if a.alone and AskedAlone(id, sender) and Workshop.IsAuthor() and ns.Versions and ns.Versions.ShowResults then
		ns.SafeCall("ask one result", ns.Versions.ShowResults, true)
	end
	Changed()
end

---------------------------------------------------------------------------
-- One player asked alone (0.9.9): "Ask <name>", from the search or an answer's actions. A roll
-- call by whisper, V1~<id>~100: their addon answers within seconds, on the channel or not (a
-- moderator's may not be). 0.9.8 and older take roll calls from the channel only and ignore it.
---------------------------------------------------------------------------

-- The name a whisper goes to, and asks are remembered by.
local function AskKey(name) return ns.FullName(ns.Normal(TrimText(name))) end

-- done(sent) (1.1.2, the right-click menu's Check version: Versions.lua): once the whisper left, or
-- was dropped from the queue.
function Workshop.AskOne(name, done)
	if not Workshop.Visible() or not NameLike(TrimText(name)) then return false end
	local now = ns.Now()
	if now - lastAskOne < Workshop.ASK_ONE_EVERY then
		ns.Print(L.WORKSHOP_ASK_ONE_WAIT:format(math.ceil(Workshop.ASK_ONE_EVERY - (now - lastAskOne))))
		return false
	end
	lastAskOne = now
	local key = AskKey(name)
	local id = NewAsk(now)
	roll.t = roll.t or now
	roll.alone[id] = Fold(ns.ShortName(key)) -- (their answer is kept whatever the cap: MakeRoom)
	askedOne[Fold(key)] = now
	ns.Comm.Whisper(key, ("V1~%d~100"):format(id), "rollask:" .. key, nil, nil, done) -- (one queued per player)
	ns.Print(L.WORKSHOP_ASK_ONE_SENT:format(ns.DisplayName(key)))
	Changed()
	return true
end

---------------------------------------------------------------------------
-- Please update
---------------------------------------------------------------------------

-- version (1.1.2, the right-click menu: Versions.lua): the one to name, never newer than his build
-- (the one he marked as out, /syl released); none: Latest. done(sent): once it left, or was dropped
-- (dropped, the player may be asked again at once).
function Workshop.AskUpdate(name, version, done)
	if not Workshop.Visible() or type(name) ~= "string" then return false end
	local now = ns.Now()
	local key = ns.FullName(name)
	if now - (asked[key] or -math.huge) < Workshop.UPDATE_GAP then return false end
	asked[key] = now
	if type(version) ~= "string" or not Parts(version) or Workshop.Newer(version, ns.VERSION) then version = Workshop.Latest() end
	ns.Comm.Whisper(key, "V3~" .. version, "askupdate:" .. key, nil, nil, function(sent) -- one queued per player
		if not sent and asked[key] == now then asked[key] = nil end
		if done then done(sent) end
	end)
	return true
end

-- Every roll call answer on an old version, MAX_ASK at most per click.
function Workshop.AskOutdated()
	local now = ns.Now()
	if now - lastAsk < Workshop.ASK_EVERY then return end
	lastAsk = now
	local latest, n = Workshop.Latest(), 0
	for _, a in pairs(roll and roll.answers or {}) do
		if n >= Workshop.MAX_ASK then break end
		if Workshop.Newer(latest, a.version) and Workshop.AskUpdate(a.name) then n = n + 1 end
	end
	ns.Print(L.WORKSHOP_ASKED:format(n, latest))
	Changed()
end

function Workshop.HandleUpdate(dist, sender, text)
	if dist ~= "WHISPER" or not IsAuthorName(sender) or not Workshop.Notices() then return end
	local latest = text:match("^V3~(%d+%.%d+%.%d+)$")
	if not latest or not Workshop.Newer(latest, ns.VERSION) then return end
	local now = ns.Now()
	if now - lastUpdateShown < Workshop.UPDATE_GAP then return end
	lastUpdateShown = now
	-- (In an instance or on Busy, 1.1: once the player is out.)
	ns.Alert("update", "soft", { what = L.HELD_UPDATE:format(latest), key = "update",
		show = function() ns.ShowDialog("SYLVANISTAS_AUTHOR_UPDATE", ns.VERSION, latest) end })
end

StaticPopupDialogs["SYLVANISTAS_AUTHOR_UPDATE"] = {
	text = L.WORKSHOP_UPDATE_POPUP,
	button1 = OKAY or "OK",
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- The author's presence, and bug reports to him
---------------------------------------------------------------------------

function Workshop.SendPresence()
	if not Workshop.IsAuthor() then return end
	local released = Workshop.Released()
	ns.Comm.Send("CHANNEL", "V4~" .. Clean(ns.VERSION, 12) .. (released and ("~" .. released) or ""), "presence")
end

-- The version his presence names as out (its third field), or nil: the second is the build his
-- client runs, which may be one CurseForge does not list yet. Later fields, if V4 ever gains
-- any, are left for later versions.
local function ReleasedField(text)
	local v, rest = tostring(text or ""):match("^V4~[^~]*~(%d+%.%d+%.%d+)(.*)$")
	if not v or (rest ~= "" and rest:sub(1, 1) ~= "~") then return nil end
	return v
end

function Workshop.HandlePresence(dist, sender, text)
	if dist ~= "CHANNEL" or not IsAuthorName(sender) or Workshop.IsAuthor() then return end
	if not text:match("^V4~") then return end
	local was = Workshop.AuthorOnline()
	local wasBehind = Workshop.Behind()
	authorAt, authorName = ns.Now(), ns.FullName(sender)
	Workshop.HeardVersion(ReleasedField(text))
	if not was or Workshop.Behind() ~= wasBehind then ns.Fire("DATA_CHANGED") end
end

---------------------------------------------------------------------------
-- Behind the author's version (1.1). His presence (V4, above) names the version he marked as out
-- (/syl released, once CurseForge lists it): newer than ours, this client says so, to this player
-- alone: one line in chat once a session, a line at the foot of the Census, and /syl status. The
-- build his client runs is never the one named: he runs a new build before it is published (a
-- preview on his own PC), and nobody is told to update to a version they can't get. Nothing is
-- sent, and nobody is whispered (the author's own "please update", V3, stays the only one): so it
-- is no roll call to answer, and it shows whatever /syl rollcall says (Workshop.Answers). Only the
-- author's own client can name a version here (his name, which the server stamps, on his realm
-- group); a number anyone else sends never counts. Kept account-wide (ns.db.authorRelease), so
-- the next login knows it before he says it again; updated, the line goes by itself.
---------------------------------------------------------------------------

local heardVersion -- { v, t }: the released version his presence named this session
local toldBehind = false -- the chat line said it this session

-- On his own client: the version he marked as out (ns.db.releasedVersion), never one newer than
-- the build he runs (a build rolled back: nothing named until he marks again).
function Workshop.Released()
	local v = ns.db and ns.db.releasedVersion
	if type(v) ~= "string" or not Parts(v) or #v > 12 or Workshop.Newer(v, ns.VERSION) then return nil end
	return v
end

-- /syl released [x.y.z]: the author marks the version CurseForge lists as out (his own by
-- default, never a newer one), and his presence says it at once, then every PRESENCE_EVERY.
function Workshop.MarkReleased(v)
	if not Workshop.IsAuthor() then
		ns.Print(L.RELEASED_ONLY_AUTHOR)
		return false
	end
	v = (v == nil or v == "") and ns.VERSION or tostring(v)
	if not Parts(v) or #v > 12 or Workshop.Newer(v, ns.VERSION) then
		ns.Print(L.RELEASED_USAGE:format(ns.VERSION))
		return false
	end
	ns.db.releasedVersion = v
	ns.Print(L.RELEASED_DONE:format(v))
	Workshop.SendPresence()
	return true
end

function Workshop.HeardVersion(v)
	if type(v) ~= "string" or not v:match("^%d+%.%d+%.%d+$") or #v > 12 then return end
	local now = ns.Now()
	heardVersion = { v = v, t = now }
	if ns.db then ns.db.authorRelease = { v = v, t = now } end
	local behind = Workshop.Behind()
	if behind and not toldBehind then
		toldBehind = true
		ns.Print(L.BEHIND_CHAT:format(behind, ns.VERSION))
	end
end

-- The author's released version as this client last heard it, and when: this session's, else the
-- saved one.
function Workshop.AuthorVersion()
	local e = heardVersion
	if not e and ns.db and type(ns.db.authorRelease) == "table" then e = ns.db.authorRelease end
	if type(e) ~= "table" or type(e.v) ~= "string" or not e.v:match("^%d+%.%d+%.%d+$") then return nil end
	return e.v, tonumber(e.t)
end

-- The author's released version when it is newer than ours, else nil (always nil on his own client).
function Workshop.Behind()
	if Workshop.IsAuthor() then return nil end
	local v = Workshop.AuthorVersion()
	if v and Workshop.Newer(v, ns.VERSION) then return v end
	return nil
end

-- For /syl status.
function Workshop.VersionLine()
	if Workshop.IsAuthor() then
		return ("author's released version: %s (/syl released; this client %s)"):format(Workshop.Released() or "none marked", ns.VERSION)
	end
	local v, t = Workshop.AuthorVersion()
	if not v then return "author's released version: not heard yet (this client " .. ns.VERSION .. ")" end
	local state = Workshop.Newer(v, ns.VERSION) and "behind" or (Workshop.Newer(ns.VERSION, v) and "ahead" or "same")
	return ("author's released version: %s, heard %s (this client %s: %s)"):format(v, t and ns.Ago(t) or "?", ns.VERSION, state)
end

-- The line at the foot of the Census, or nil.
function Workshop.BehindLine()
	local v = Workshop.Behind()
	if not v then return nil end
	return {
		text = "|cffffd200" .. L.BEHIND_LINE:format(v, ns.VERSION) .. "|r",
		tooltip = function(tt)
			tt:AddLine(L.BEHIND_LINE:format(v, ns.VERSION), 1, 0.82, 0)
			tt:AddLine(L.BEHIND_TIP, 1, 1, 1, true)
		end,
	}
end

function Workshop.ResetVersion() heardVersion, toldBehind = nil, false end -- (tests: a new session)

-- The bug report as it travels: no newlines or pipes (they are put back as "\n" and "!").
local function Pack(text)
	text = tostring(text or ""):gsub("|", "!"):gsub("\r", ""):gsub("\n", "\\n")
	if #text > Workshop.BUG_MAX then text = text:sub(1, Workshop.BUG_MAX - 8) .. "\\n[cut]" end
	return text
end

-- The button the Report a bug window shows while the author is online, or nil.
function Workshop.BugAction(text)
	if not Workshop.AuthorOnline() or not authorName then return nil end
	return {
		label = L.WORKSHOP_SEND_BUG:format(ns.DisplayName(authorName)),
		fn = function() return Workshop.SendBug(text) end,
	}
end

-- The report as the author gets it (1.1.2: "See what is sent" shows this): cut where it would be,
-- its pipes as "!" (Pack), its line breaks back.
function Workshop.Outgoing(text)
	return (Pack(text):gsub("\\n", "\n"))
end

-- 1.1.2: the author asks a player for their report (Workshop.AskBug, below). Here for HandleBug.
Workshop.BUGASK_EVERY = 120   -- the author asks the same player at most this often
Workshop.BUGASK_GAP = 60      -- a player's window opens for his asks at most this often
Workshop.BUGASK_OPEN = 10 * 60 -- an ask not answered in this long is gone
local bugAsked = {}           -- [folded short name] = when the author asked them (BUGASK_EVERY)
local bugAwaited = {}         -- [folded short name] = when his ask left: their report, when it comes, is his
local waitingReports = {}     -- reports that opened by themselves while another showed: next, once it closes
-- Asks and reports are matched by the short name folded (Forever's names are one across its realm
-- group; the menu may give the name without the realm the server stamps).
local function ShortKey(name) return Fold(ns.ShortName(ns.FullName(ns.Normal(tostring(name or "")))) or "") end

-- A report from `sender` answers the author's ask (sent within BUGASK_OPEN and a minute).
local function Awaited(sender, now)
	local t = bugAwaited[ShortKey(sender)]
	return t ~= nil and now - t <= Workshop.BUGASK_OPEN + 60
end

-- Piece 1 now; the rest once the author answers it (Workshop.HandleAck). No answer within
-- BUG_ACK: he is gone, the player is told and may try again later. requested (1.1.2): the author
-- asked for it (Workshop.HandleBugAsk): the gap since the player's last report does not hold it back.
function Workshop.SendBug(text, requested)
	if not Workshop.AuthorOnline() or not authorName then return false end
	local now = ns.Now()
	-- (1.1.2's review: one still on its way is said so, not as a wait of minutes.)
	if sending then
		ns.Print(L.WORKSHOP_BUG_BUSY)
		return false
	end
	if not requested and now - lastBug < Workshop.BUG_GAP then
		ns.Print(L.WORKSHOP_BUG_WAIT:format(math.max(1, math.ceil((Workshop.BUG_GAP - (now - lastBug)) / 60))))
		return false
	end
	lastBug = now
	local body = Pack(text)
	local n = math.min(Workshop.MAX_PIECES, math.max(1, math.ceil(#body / Workshop.PIECE)))
	local id = Workshop.random(1, 99999)
	local list = {}
	for i = 1, n do
		list[i] = ("V5~%d~%d~%d~%s"):format(id, i, n, body:sub((i - 1) * Workshop.PIECE + 1, i * Workshop.PIECE))
	end
	sending = { id = id, pieces = list, to = authorName }
	ns.Comm.Whisper(authorName, list[1], "bug" .. id .. ":1")
	ns.Print(L.WORKSHOP_BUG_SENDING:format(ns.DisplayName(authorName)))
	Workshop.after(Workshop.BUG_ACK, "bug report ack", function()
		if sending and sending.id == id and not sending.go then
			sending, lastBug = nil, -math.huge
			ns.Print(L.WORKSHOP_BUG_NO_AUTHOR)
		end
	end)
	return true
end

function Workshop.HandleAck(dist, sender, text)
	if dist ~= "WHISPER" or not IsAuthorName(sender) or not sending then return end
	local id, stage = text:match("^V6~(%d+)~([12])$")
	if tonumber(id) ~= sending.id then return end
	if stage == "1" and not sending.go then
		sending.go = true
		for i = 2, #sending.pieces do ns.Comm.Whisper(sending.to, sending.pieces[i], "bug" .. id .. ":" .. i) end
	elseif stage == "2" then
		sending = nil
		ns.Print(L.WORKSHOP_BUG_SENT:format(ns.DisplayName(ns.FullName(sender))))
	end
end

function Workshop.HandleBug(dist, sender, text)
	if dist ~= "WHISPER" or not Workshop.Visible() then return end
	local id, i, n, piece = text:match("^V5~(%d+)~(%d+)~(%d+)~(.*)$")
	i, n = tonumber(i), tonumber(n)
	if not id or not i or not n or n < 1 or n > Workshop.MAX_PIECES or i < 1 or i > n then return end
	sender = ns.FullName(sender)
	local now = ns.Now()
	-- One report at a time per player (a newer one replaces it), three started an hour, ten
	-- players at a time; a report with no new piece for 60 s is dropped.
	for k, p in pairs(pieces) do
		if now - p.t > 60 then pieces[k] = nil end
	end
	local e = pieces[sender]
	if not e or e.id ~= id then
		if i ~= 1 then return end
		local times = bugsFrom[sender] or {}
		for k = #times, 1, -1 do if now - times[k] > 3600 then table.remove(times, k) end end
		-- 1.1.2: the report the author asked for (his ask is one every 2 minutes at most) goes past
		-- the hour's three, once per ask; nobody else's does.
		local asked = Awaited(sender, now)
		if #times >= 3 and not asked then return end
		local open = 0
		for k in pairs(pieces) do if k ~= sender then open = open + 1 end end
		if open >= 10 then return end
		times[#times + 1] = now
		bugsFrom[sender] = times
		if asked then bugAwaited[ShortKey(sender)] = nil end
		e = { id = id, n = n, got = 0, parts = {}, t = now, asked = asked or nil }
		pieces[sender] = e
		-- Here: the rest may come.
		if n > 1 then ns.Comm.Whisper(sender, ("V6~%s~1"):format(id), "bugack:" .. sender) end
	end
	if e.n ~= n or e.parts[i] then return end
	e.parts[i], e.got, e.t = piece:sub(1, Workshop.PIECE):gsub("|", "!"), e.got + 1, now
	if e.got < n then return end
	pieces[sender] = nil
	ns.Comm.Whisper(sender, ("V6~%s~2"):format(id), "bugack:" .. sender)
	local r = { from = sender, t = now, text = (table.concat(e.parts):gsub("\\n", "\n")), asked = e.asked }
	reports[#reports + 1] = r
	while #reports > Workshop.MAX_REPORTS do table.remove(reports, 1) end
	-- Chat gets one short line either way.
	ns.Print(L.WORKSHOP_BUG_IN:format(ns.DisplayName(sender)))
	if r.asked then
		-- 1.1.2 (his ask): the report he asked for opens by itself in a window he can copy from,
		-- never in chat (a chat line can't be copied). In an instance or while Busy it waits like
		-- any alert (its sound, then the window; each report its own), in a fight until it ends,
		-- and behind a report he is reading (Workshop.ShowReport).
		ns.Alert("help", "soft", { what = L.WORKSHOP_BUG_FROM:format(ns.DisplayName(sender)),
			show = function() Workshop.ShowReport(r, true) end })
	else
		-- One nobody asked for (Report a bug's Send to): its sound and the line, as before 1.1.2;
		-- the Workshop's list opens it. Anyone can send one: it never pops up on his screen.
		ns.PlayAlert("soft", "help")
	end
	Changed()
end

-- The report window's report, shown now (auto: opened by itself, no keyboard taken).
local function ShowReportNow(r, auto)
	local n = 0
	for i, x in ipairs(reports) do if x == r then n = i end end
	local title = L.WORKSHOP_BUG_FROM_AT:format(ns.DisplayName(r.from), date and date("%H:%M", r.t) or "", n, #reports)
	local f = ns.UI.ShowCopy(title, r.text, nil, { key = "bug", big = true, auto = auto and true or nil })
	if type(f) == "table" then
		f.sylvanistasReport = r
		-- Closed (its X, Escape): the next report waiting shows. (Alt+Z hides the whole interface:
		-- the window is still up then.)
		if not f.sylvanistasHooked and f.HookScript then
			f.sylvanistasHooked = true
			f:HookScript("OnHide", function(self)
				if self:IsShown() then return end
				self.sylvanistasReport = nil
				if #waitingReports > 0 then ns.OutOfCombat("bug reports", Workshop.NextReport) end
			end)
		end
	end
	return f
end

-- The next report waiting, unless one shows (he is reading it). True when one showed.
function Workshop.NextReport()
	local UI = ns.UI
	local f = UI and UI.CopyFrame and UI.CopyFrame("bug")
	if f and f:IsShown() and f.sylvanistasReport then return false end
	local r = table.remove(waitingReports, 1)
	if not r then return false end
	ShowReportNow(r, true)
	return true
end

-- A report received, in its copy window: sender and time in its title, the whole text selected.
-- r: a report, or its place in the list (nil: the newest). auto (1.1.2's review): opened by
-- itself, not by his click: no keyboard taken, after a fight, and never over a report he is
-- reading (it waits, and shows once he closes that one). A click (the Workshop's row) shows it now.
function Workshop.ShowReport(r, auto)
	if type(r) ~= "table" then r = reports[tonumber(r) or #reports] end
	if not r then return false end
	local UI = ns.UI
	if not (UI and UI.ShowCopy) then return false end
	for i = #waitingReports, 1, -1 do if waitingReports[i] == r then table.remove(waitingReports, i) end end
	if not auto then
		ShowReportNow(r, false)
		return true
	end
	waitingReports[#waitingReports + 1] = r
	ns.OutOfCombat("bug reports", Workshop.NextReport)
	return true
end

---------------------------------------------------------------------------
-- The author asks a player for their bug report (1.1.2, his ask): right-click a player who runs
-- Sylvanistas (PlayerMenu.lua), "Ask for a bug report". One small whisper, VR~<id>, at most once per
-- BUGASK_EVERY per player (constants and state above, with SendBug). Their addon opens a window
-- of its own (never a game popup, nothing focused: the gamepad UI's rules; after a fight), where
-- they see the exact text before anything goes and choose Send or Not now: Send is the Report a
-- bug window's own path (Workshop.SendBug) to him, his request having just proved he is online;
-- Not now (its X, Escape) sends nothing. Taken from his character alone (the server stamps the
-- sender), once per BUGASK_GAP; it waits in an instance or while Busy, and goes stale after
-- BUGASK_OPEN. His side opens the report in a copy window once it is in (HandleBug).
--   VR~<id>   the author asks for this player's bug report   (whisper)
---------------------------------------------------------------------------

local bugAsk                  -- the author's ask waiting here: { id, from, t, text }
local lastBugAskShown = -math.huge
local bugAskFrame

function Workshop.AskBug(name)
	if not Workshop.IsAuthor() or type(name) ~= "string" then return false end
	if ns.ChatLocked() then
		ns.Print(L.VERSION_LOCKED)
		return false
	end
	local key = AskKey(name)
	local short = ShortKey(key)
	local now = ns.Now()
	local at = bugAsked[short]
	if at and now - at < Workshop.BUGASK_EVERY then
		ns.Print(L.WORKSHOP_BUGASK_WAIT:format(ns.DisplayName(key), math.ceil(Workshop.BUGASK_EVERY - (now - at))))
		return false
	end
	bugAsked[short] = now
	-- Told once it left (their report is then his, HandleBug); dropped before, it may go again at once.
	ns.Comm.Whisper(key, ("VR~%d"):format(Workshop.random(1, 99999)), "bugask:" .. key, true, nil, function(sent)
		if sent then
			bugAwaited[short] = ns.Now()
			ns.Print(L.WORKSHOP_BUGASK_SENT:format(ns.DisplayName(key)))
		else
			if bugAsked[short] == now then bugAsked[short] = nil end
			ns.Print(L.VERSION_NOT_SENT:format(ns.DisplayName(key)))
		end
	end)
	return true
end

-- The ask still open here, or nil.
function Workshop.BugAsk()
	if bugAsk and ns.Now() - bugAsk.t > Workshop.BUGASK_OPEN then bugAsk = nil end
	return bugAsk
end

function Workshop.HandleBugAsk(dist, sender, text)
	if dist ~= "WHISPER" or not IsAuthorName(sender) or Workshop.IsAuthor() then return end
	local id = tostring(text or ""):match("^VR~(%d+)$")
	if not id or #id > 6 then return end
	local now = ns.Now()
	-- He is online: his whisper says so (Workshop.SendBug sends to him).
	authorAt, authorName = now, ns.FullName(sender)
	-- Its window up already: the text it shows stays the one that goes; the ask only gets younger.
	if bugAsk and bugAskFrame and bugAskFrame:IsShown() then
		bugAsk.id, bugAsk.t, bugAsk.from = id, now, authorName
		return
	end
	if now - lastBugAskShown < Workshop.BUGASK_GAP then return end
	lastBugAskShown = now
	bugAsk = { id = id, from = authorName, t = now }
	local who = ns.DisplayName(authorName)
	ns.Alert("help", "soft", { what = L.BUGASK_HELD:format(who), key = "bugask",
		open = function() return Workshop.BugAsk() ~= nil end,
		show = function() ns.OutOfCombat("bug ask", Workshop.ShowBugAsk) end })
end

-- Send: the report as the window showed it, to the author; the window closes once it is on its
-- way. Not now (send false): nothing. An ask gone meanwhile (BUGASK_OPEN) is said so; a report of
-- ours still on its way keeps the window up (try again in a moment).
function Workshop.AnswerBugAsk(send)
	local ask = Workshop.BugAsk()
	if send and ask and sending then
		ns.Print(L.WORKSHOP_BUG_BUSY)
		return false
	end
	local shown = bugAskFrame and bugAskFrame.text or (ask and ask.text)
	bugAsk = nil
	if bugAskFrame then bugAskFrame:Hide() end
	if not send then return false end
	if not ask then
		ns.Print(L.BUGASK_GONE)
		return false
	end
	-- (Sent to the author who asked, even if another presence was heard meanwhile.)
	authorAt, authorName = math.max(authorAt or 0, ask.t), ask.from
	return Workshop.SendBug(shown or ns.BuildBugReport(), true)
end

local function BugAskButton(f, label, width)
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(label)
	return b
end

local BUGASK_W, BUGASK_H, BUGASK_OPEN_H = 440, 150, 420

-- The report's view in the window: shown ("See what is sent") or not.
local function BugAskExpand(f, on)
	f.expanded = on and true or false
	f.view:SetShown(f.expanded)
	f.see:SetText(f.expanded and L.BUGASK_HIDE or L.BUGASK_SEE)
	f:SetHeight(f.expanded and BUGASK_OPEN_H or BUGASK_H)
	if f.expanded then
		f.box:SetText(f.text or "")
		if f.box.SetCursorPosition then f.box:SetCursorPosition(0) end
	end
end

local function BuildBugAsk()
	local f = CreateFrame("Frame", "SylvanistasBugAsk", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(BUGASK_W, BUGASK_H)
	f:SetPoint("CENTER", 0, 120)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	-- Its X hides it itself (as the Sylvanistas window's, 1.1.1): the template's would call HideUIPanel,
	-- which does nothing in combat for a call that is not secure.
	f.onCloseCallback = function()
		f:Hide()
		return false
	end
	if f.TitleText then f.TitleText:SetText(L.BUGASK_TITLE) end
	f.message = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.message:SetPoint("TOPLEFT", 16, -34)
	f.message:SetPoint("TOPRIGHT", -16, -34)
	f.message:SetJustifyH("LEFT")
	f.message:SetWordWrap(true)
	-- The exact text that goes, read only (a click in it selects; the keyboard only on that click).
	local view = CreateFrame("ScrollFrame", "SylvanistasBugAskScroll", f, "UIPanelScrollFrameTemplate")
	view:SetPoint("TOPLEFT", 14, -96)
	view:SetPoint("BOTTOMRIGHT", -32, 44)
	local box = CreateFrame("EditBox", nil, view)
	box:SetMultiLine(true)
	box:SetFontObject(ChatFontNormal)
	box:SetWidth(BUGASK_W - 56)
	box:SetAutoFocus(false)
	box.sylvanistasBox = true
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnTextChanged", function(self, userInput)
		if userInput then self:SetText(f.text or "") end -- (read only)
	end)
	view:SetScrollChild(box)
	view:Hide()
	f.view, f.box = view, box
	f.see = BugAskButton(f, L.BUGASK_SEE, 150)
	f.see:SetPoint("BOTTOMLEFT", 12, 12)
	f.see:SetScript("OnClick", function() ns.SafeCall("bug ask see", BugAskExpand, f, not f.expanded) end)
	f.later = BugAskButton(f, L.BUGASK_LATER, 110)
	f.later:SetPoint("BOTTOMRIGHT", -12, 12)
	f.later:SetScript("OnClick", function() ns.SafeCall("bug ask later", Workshop.AnswerBugAsk, false) end)
	f.send = BugAskButton(f, L.BUGASK_SEND, 110)
	f.send:SetPoint("RIGHT", f.later, "LEFT", -6, 0)
	f.send:SetScript("OnClick", function() ns.SafeCall("bug ask send", Workshop.AnswerBugAsk, true) end)
	-- Its X, and Escape where Sylvanistas may use it (never with the gamepad UI: ns.EscapeCloses): a
	-- close without an answer is Not now. The whole interface hidden (Alt+Z, a cinematic) is none:
	-- the window is still up, its ask with it (1.1.2's review).
	f:SetScript("OnHide", function(self)
		self.box:ClearFocus()
		if self:IsShown() then return end
		bugAsk = nil
	end)
	return f
end

-- The author's ask, in Sylvanistas's own window: who asks, what goes (on a click), Send or Not now.
function Workshop.ShowBugAsk()
	local ask = Workshop.BugAsk()
	if not ask then return nil end
	bugAskFrame = bugAskFrame or BuildBugAsk()
	ns.EscapeCloses("SylvanistasBugAsk")
	-- Up already (an ask again while it shows): the text it shows stays the one that goes.
	if bugAskFrame:IsShown() and bugAskFrame.text then return bugAskFrame end
	-- The text shown is the one sent: built now, cut as it will be.
	ask.text = Workshop.Outgoing(ns.BuildBugReport())
	bugAskFrame.text = ask.text
	bugAskFrame.message:SetText(L.BUGASK_TEXT:format(ns.DisplayName(ask.from)))
	BugAskExpand(bugAskFrame, false)
	bugAskFrame:Show()
	return bugAskFrame
end
function Workshop.BugAskFrame() return bugAskFrame end -- (tests)

-- The author's line in the right-click menu of a player who runs Sylvanistas (an addon older than 1.1.2
-- can't answer it: greyed, and its tooltip says why; in a dungeon, a raid or a match: greyed too).
function Workshop.MenuLines(target, menu)
	if not Workshop.IsAuthor() then return end
	local V = ns.Versions
	if not (V and V.HasSylvanistas and V.HasSylvanistas(target.name)) then return end
	local _, version = V.Status(target.name)
	local old = version and Workshop.Newer(V.FIRST or "1.1.2", version)
	local locked = target.locked == true
	local tip = locked and L.PLAYERMENU_LOCKED or (old and L.WORKSHOP_BUGASK_OLD:format(version) or L.WORKSHOP_BUGASK_TIP)
	menu.Button(L.WORKSHOP_BUGASK, function() Workshop.AskBug(target.name) end, L.WORKSHOP_BUGASK, tip, not old and not locked)
end
ns.PlayerMenu.Add("bugreport", function(target, menu) Workshop.MenuLines(target, menu) end, 50)

---------------------------------------------------------------------------
-- The tab
---------------------------------------------------------------------------

local function Grey(s) return "|cff9d9d9d" .. s .. "|r" end
local function Gold(s) return "|cffffd200" .. s .. "|r" end
local function Green(s) return "|cff40ff40" .. s .. "|r" end
local function Red(s) return "|cffff4040" .. s .. "|r" end

-- "0.8.2 12  ·  0.8.1 3", newest first.
local function Versions(map)
	local list = {}
	for v, n in pairs(map or {}) do list[#list + 1] = { v = v, n = n } end
	table.sort(list, function(a, b)
		if a.v ~= b.v then return Workshop.Newer(a.v, b.v) end
		return a.n > b.n
	end)
	local latest, parts = Workshop.Latest(), {}
	for _, e in ipairs(list) do
		local label = e.v .. " " .. e.n
		parts[#parts + 1] = Workshop.Newer(latest, e.v) and Red(label) or Green(label)
	end
	return #parts > 0 and table.concat(parts, "  ·  ") or Grey("?")
end

local function Count(map, key) map[key] = (map[key] or 0) + 1 end

-- The reports' view: every guild's addon users and their versions.
local function InstallLines(lines)
	local now, rows, users, versions = ns.Now(), {}, 0, {}
	for name, g in pairs(ns.rdb and ns.rdb.guilds or {}) do
		if type(g) == "table" and ns.IsFederation(name) and now - (g.t or 0) <= ns.Data.FRESH then
			rows[#rows + 1] = { name = name, g = g }
			users = users + (g.users or 0)
			for v, n in pairs(g.versions or {}) do versions[v] = (versions[v] or 0) + n end
		end
	end
	table.sort(rows, function(a, b)
		if (a.g.users or 0) ~= (b.g.users or 0) then return (a.g.users or 0) > (b.g.users or 0) end
		return a.name < b.name
	end)
	lines[#lines + 1] = { header = true, text = L.WORKSHOP_INSTALLS, right = Gold(L.WORKSHOP_USERS:format(users, #rows)) }
	lines[#lines + 1] = { text = L.WORKSHOP_VERSIONS .. ": " .. Versions(versions), gapAfter = #rows == 0 }
	if #rows == 0 then lines[#lines].text = Grey(L.EMPTY) end
	for i = 1, math.min(Workshop.MAX_SHOWN, #rows) do
		local e = rows[i]
		lines[#lines + 1] = {
			indent = 1, text = Green("<" .. e.name .. ">") .. "  " .. (next(e.g.versions or {}) and Versions(e.g.versions) or Grey(L.WORKSHOP_OLD_REPORTER)),
			right = L.WORKSHOP_OF_ONLINE:format(e.g.users or 0, e.g.online or 0),
		}
	end
	lines[#lines].gapAfter = true
end

local function Problems(a, latest)
	local out = {}
	if Workshop.Newer(latest, a.version) then out[#out + 1] = Red(a.version) end
	if a.errors > 0 then out[#out + 1] = Red(L.WORKSHOP_ERRORS:format(a.errors)) end
	if not a.flags:find("c", 1, true) then out[#out + 1] = Red(L.WORKSHOP_NO_CHANNEL) end
	return out
end

-- The guilds the author knows players by: an answer carries none since 0.9.2 (Answer), so a
-- player's guild is the one his own roster puts them in (the server's word, first), or the one
-- the census's reports name them leader, officer or reporter of. Returns [folded Name-Realm] =
-- { name, folded }, and every guild name the census and his roster know, folded (a guild's
-- name is nobody to ask alone).
local function KnownGuilds()
	local byPlayer, names, byGuild = {}, {}, {}
	local function Put(who, guild)
		if type(who) ~= "string" or who == "" then return end
		local g = byGuild[guild]
		if not g then
			g = { name = guild, folded = Fold(guild) }
			byGuild[guild], names[g.folded] = g, true
		end
		local key = Fold(who)
		byPlayer[key] = byPlayer[key] or g
	end
	local mine = GetGuildInfo and GetGuildInfo("player")
	if type(mine) == "string" and mine ~= "" then
		names[Fold(mine)] = true
		for who in pairs(ns.Roster and ns.Roster.byName or {}) do Put(who, mine) end
	end
	for guild, g in pairs(ns.rdb and ns.rdb.guilds or {}) do
		if type(guild) == "string" and type(g) == "table" then
			names[Fold(guild)] = true
			local home = g.realm or ns.realm
			if type(g.leader) == "string" then Put(ns.FullName(g.leader, home), guild) end
			for _, o in ipairs(type(g.officers) == "table" and g.officers or {}) do
				if type(o) == "table" and type(o.name) == "string" then Put(ns.FullName(o.name, home), guild) end
			end
			Put(g.reporterFull, guild)
		end
	end
	return byPlayer, names
end

-- An answer's guild, and folded: the one the author knows them by, or the one a client older
-- than 0.9.2 sent.
local function GuildOf(a, known)
	local g = known and known[a.foldedFull]
	if g then return g.name, g.folded end
	return a.guild, a.foldedGuild
end

-- The tab's search, as typed in its box: a new search lists from the top, its actions closed.
function Workshop.SetSearch(text)
	text = tostring(text or "")
	if text == search then return end
	search, shownAnswers, menuFor = text, Workshop.ROLL_PAGE, nil
	ns.Fire("WORKSHOP_CHANGED")
end
function Workshop.Search() return search end

-- How many answers the list shows ("Show more", "Show all", "Show fewer").
function Workshop.ShowAnswers(n)
	shownAnswers = math.max(Workshop.ROLL_PAGE, tonumber(n) or Workshop.ROLL_PAGE)
	ns.Fire("WORKSHOP_CHANGED")
end

-- An answer's actions, opened (or closed) under its row by a click.
function Workshop.ToggleMenu(name)
	menuFor = menuFor ~= name and name or nil
	ns.Fire("WORKSHOP_CHANGED")
end

-- Problems first, then by name (any case).
local function SortAnswers(list, latest)
	local bad = {}
	for _, a in ipairs(list) do bad[a] = #Problems(a, latest) > 0 end
	table.sort(list, function(a, b)
		if bad[a] ~= bad[b] then return bad[a] end
		if a.foldedName ~= b.foldedName then return a.foldedName < b.foldedName end
		return a.name < b.name
	end)
	local n = 0
	for _, isBad in pairs(bad) do if isBad then n = n + 1 end end
	return n
end

-- "Ask <name>": a roll call to that player alone, by whisper.
local function AskLine(name, indent)
	local who = ns.DisplayName(AskKey(name))
	local at = askedOne[Fold(AskKey(name))]
	return {
		indent = indent, noReport = true,
		text = Gold("> " .. L.WORKSHOP_ASK_ONE:format(who)),
		right = at and Grey(L.WORKSHOP_ASK_ONE_AGO:format(ns.Ago(at))) or nil,
		onClick = function() Workshop.AskOne(name) end,
		tooltip = function(tt)
			tt:AddLine(L.WORKSHOP_ASK_ONE:format(who), 1, 0.82, 0)
			tt:AddLine(L.WORKSHOP_ASK_ONE_TIP, 1, 1, 1, true)
		end,
	}
end

-- One answer's row: the player and guild (GuildOf); the version (red when behind), the game client
-- and window, its flags (Workshop.Flags), and what is wrong (off the channel in red, errors). A click
-- opens its actions under it: ask again by whisper, ask to update (when behind), the player's card.
local function AnswerLines(lines, a, latest, open, known)
	local guild = GuildOf(a, known)
	local outdated = Workshop.Newer(latest, a.version)
	local right = { a.version == "?" and Grey("?") or (outdated and Red or Green)(a.version) }
	if a.client ~= "?" then right[#right + 1] = Grey(a.client) end
	if a.window ~= "?" then right[#right + 1] = Grey(a.window) end
	if a.flags ~= "" then right[#right + 1] = Grey(a.flags) end
	if not a.flags:find("c", 1, true) then right[#right + 1] = Red(L.WORKSHOP_NO_CHANNEL) end
	if a.errors > 0 then right[#right + 1] = Red(L.WORKSHOP_ERRORS:format(a.errors)) end
	local who = ns.DisplayName(a.name)
	lines[#lines + 1] = {
		key = a.name, indent = 1,
		text = who .. (guild ~= "" and ("  " .. Grey("<" .. guild .. ">")) or ""),
		right = table.concat(right, "  "),
		onClick = function() Workshop.ToggleMenu(a.name) end,
		tooltip = function(tt)
			tt:AddLine(who, 1, 0.82, 0)
			tt:AddLine(("%s  ·  %s  ·  %s  ·  %s"):format(a.version, a.client, a.window, a.flags ~= "" and a.flags or "-"), 1, 1, 1)
			if guild ~= "" then tt:AddLine("<" .. guild .. ">", 0.6, 0.6, 0.6) end
			tt:AddLine(L.WORKSHOP_ANSWERED:format(ns.Ago(a.t)), 0.6, 0.6, 0.6)
			tt:AddLine(L.WORKSHOP_ROW_TIP, 0.25, 1, 0.25, true)
		end,
	}
	if not open then return end
	lines[#lines + 1] = AskLine(a.name, 2)
	if outdated then
		lines[#lines + 1] = {
			indent = 2, noReport = true, text = Gold("> " .. L.WORKSHOP_ASK_BTN),
			onClick = function() ns.ShowDialog("SYLVANISTAS_WORKSHOP_ASK", who, nil, a.name) end,
			tooltip = function(tt)
				tt:AddLine(L.WORKSHOP_ASK_BTN, 1, 0.82, 0)
				tt:AddLine(L.WORKSHOP_CLICK_ASK, 1, 1, 1, true)
			end,
		}
	end
	lines[#lines + 1] = {
		indent = 2, noReport = true, text = Gold("> " .. L.WORKSHOP_CARD),
		onClick = function() ns.UI.ShowPerson({ name = who, level = a.level, class = a.class ~= "" and a.class or nil, guild = guild ~= "" and guild or nil }) end,
	}
end

-- A list of answers, ROLL_PAGE at a time with "Show more", "Show all" and "Show fewer" (the
-- leaderboards' way). The copy for Discord: the first page and how many more.
local function AnswerList(lines, list, latest, report, known)
	local shown = report and Workshop.ROLL_PAGE or shownAnswers
	for i = 1, math.min(#list, shown) do
		AnswerLines(lines, list[i], latest, not report and menuFor == list[i].name, known)
	end
	local total, page = #list, Workshop.ROLL_PAGE
	if report then
		if total > shown then lines[#lines + 1] = { indent = 1, text = Grey(L.AND_MORE:format(total - shown)) } end
		return
	end
	if total > shown then
		lines[#lines + 1] = { indent = 1, noReport = true, text = Grey(L.SHOW_MORE:format(math.min(page, total - shown), shown, total)),
			onClick = function() Workshop.ShowAnswers(shown + page) end }
		lines[#lines + 1] = { indent = 1, noReport = true, text = Grey(L.SHOW_ALL:format(total)),
			onClick = function() Workshop.ShowAnswers(math.huge) end }
	end
	if shown > page and total > page then
		lines[#lines + 1] = { indent = 1, noReport = true, text = Grey(L.SHOW_FEWER), onClick = function() Workshop.ShowAnswers(page) end }
	end
end

-- How the full roll call goes (or went).
local function FullLines(lines)
	if not full then return end
	local n, m, pct = FullCount()
	local right
	if full.running then
		right = full.nextAt and Grey(L.WORKSHOP_FULL_NEXT:format(math.max(1, math.ceil((full.nextAt - ns.Now()) / 60)))) or nil
	else
		right = (full.reason == "enough" and Green or Grey)(L["WORKSHOP_FULL_END_" .. full.reason:upper()])
	end
	lines[#lines + 1] = {
		text = L.WORKSHOP_FULL_PROGRESS:format(full.round, n, m, pct), right = right,
		tooltip = function(tt)
			tt:AddLine(L.WORKSHOP_FULL_BTN, 1, 0.82, 0)
			tt:AddLine(L.WORKSHOP_FULL_BTN_TIP, 1, 1, 1, true)
		end,
	}
end

-- What the search finds: every answer whose name, guild (GuildOf) or version holds the text (any
-- case), problems or not. A name nobody answered under: "Ask <name>" below (not for the name of a
-- player who answered, nor for a guild's name or a piece of one an answer's guild holds).
local function SearchLines(lines, text, latest, known, guildNames)
	-- (The name with its realm: "Ann" and "Ann-Realm" find her alike, and are her exactly.)
	local query, exact = Fold(text), Fold(AskKey(text))
	local list, noAsk = {}, guildNames[query] == true
	for _, a in pairs(roll and roll.answers or {}) do
		local _, foldedGuild = GuildOf(a, known)
		local byName, byGuild = a.foldedFull:find(query, 1, true) ~= nil, foldedGuild:find(query, 1, true) ~= nil
		if byName or byGuild or a.version:find(query, 1, true) then list[#list + 1] = a end
		if a.foldedFull == exact or (byGuild and not byName) then noAsk = true end
	end
	SortAnswers(list, latest)
	lines[#lines + 1] = { header = true, text = L.WORKSHOP_MATCHES:format(#list) }
	if #list == 0 then lines[#lines + 1] = { indent = 1, text = Grey(L.WORKSHOP_NO_MATCH) } end
	AnswerList(lines, list, latest, false, known)
	if not noAsk and NameLike(text) then lines[#lines + 1] = AskLine(text, 1) end
	lines[#lines].gapAfter = true
end

-- The roll call: its search box on top, the full roll call's progress, then what the search
-- finds, or the answers' summary and everyone who answered. `report`: the copy for Discord
-- (no box, no search, the first page).
local function RollLines(lines, report)
	lines[#lines + 1] = { header = true, text = L.WORKSHOP_ROLL, right = roll and roll.t and Grey(ns.Ago(roll.t)) or nil }
	if not report then
		lines[#lines + 1] = {
			text = L.WORKSHOP_SEARCH, noReport = true, input = { text = search, onChange = Workshop.SetSearch },
			tooltip = function(tt)
				tt:AddLine(L.WORKSHOP_SEARCH, 1, 0.82, 0)
				tt:AddLine(L.WORKSHOP_SEARCH_TIP, 1, 1, 1, true)
			end,
		}
	end
	FullLines(lines)
	local latest = Workshop.Latest()
	local text = report and "" or TrimText(search)
	local known, guildNames = KnownGuilds()
	if text ~= "" then return SearchLines(lines, text, latest, known, guildNames) end
	if not roll then
		lines[#lines + 1] = { text = Grey(L.WORKSHOP_ROLL_NONE), gapAfter = true }
		return
	end
	local versions, clients, windows, noChannel, withErrors = {}, {}, {}, 0, 0
	local list = {}
	for _, a in pairs(roll.answers) do
		Count(versions, a.version)
		Count(clients, a.client)
		Count(windows, a.window)
		if not a.flags:find("c", 1, true) then noChannel = noChannel + 1 end
		if a.errors > 0 then withErrors = withErrors + 1 end
		list[#list + 1] = a
	end
	local function Join(map)
		local parts = {}
		for k, n in pairs(map) do parts[#parts + 1] = k .. " " .. n end
		table.sort(parts)
		return #parts > 0 and table.concat(parts, "  ·  ") or "-"
	end
	-- (Players asked alone, and no roll call yet: no share to tell.)
	lines[#lines + 1] = { text = roll.share and L.WORKSHOP_ANSWERS:format(roll.count, roll.share) or L.WORKSHOP_ANSWERS_ALONE:format(roll.count) }
	lines[#lines].right = Grey(L.WORKSHOP_LAST:format(ns.Ago(roll.t)))
	lines[#lines + 1] = { indent = 1, text = L.WORKSHOP_VERSIONS .. ": " .. Versions(versions) }
	lines[#lines + 1] = { indent = 1, text = L.WORKSHOP_CLIENTS .. ": " .. Join(clients) }
	lines[#lines + 1] = { indent = 1, text = L.WORKSHOP_WINDOWS .. ": " .. Join(windows) }
	lines[#lines + 1] = { indent = 1, text = L.WORKSHOP_HEALTH:format(noChannel, withErrors), gapAfter = true }
	local bad = SortAnswers(list, latest)
	lines[#lines + 1] = { header = true, text = L.WORKSHOP_EVERYONE:format(#list), right = bad > 0 and Red(L.WORKSHOP_ATTENTION:format(bad)) or nil }
	if #list == 0 then
		lines[#lines + 1] = { indent = 1, text = Grey(L.WORKSHOP_NO_ANSWERS) }
	elseif bad == 0 then
		lines[#lines + 1] = { indent = 1, text = Grey(L.WORKSHOP_ALL_GOOD) }
	end
	AnswerList(lines, list, latest, report, known)
	lines[#lines].gapAfter = true
end

StaticPopupDialogs["SYLVANISTAS_WORKSHOP_ASK"] = {
	text = L.WORKSHOP_ASK_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function(self, data)
		ns.SafeCall("workshop ask", function()
			local name = data or (self and self.data)
			if Workshop.AskUpdate(name) then ns.Print(L.WORKSHOP_ASKED:format(1, Workshop.Latest())) end
		end)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local function BugLines(lines)
	lines[#lines + 1] = { header = true, text = L.WORKSHOP_BUGS:format(#reports) }
	if #reports == 0 then lines[#lines + 1] = { text = Grey(L.WORKSHOP_BUGS_NONE) } end
	for i = #reports, math.max(1, #reports - Workshop.MAX_SHOWN + 1), -1 do
		local r = reports[i]
		local first = r.text:match("[^\n`]+") or ""
		lines[#lines + 1] = {
			indent = 1, text = ns.DisplayName(r.from) .. "  " .. Grey(first:sub(1, 60)),
			right = Grey(ns.Ago(r.t)),
			onClick = function() Workshop.ShowReport(r) end,
		}
	end
end

-- The tab's lines; `report`: for the copy (Workshop.ReportText). Nothing for anyone else (the tab
-- is hidden from them; 0.9.9: not even drawn before it is).
function Workshop.Build(report)
	if not Workshop.Visible() then return {}, L.TAB_WORKSHOP, "" end
	local lines = {}
	if Workshop.Preview() then lines[#lines + 1] = { text = Grey(L.WORKSHOP_PREVIEW), gapAfter = true } end
	-- The version his presence tells the army is out (1.1): /syl released marks it.
	lines[#lines + 1] = {
		text = L.WORKSHOP_RELEASED:format(Workshop.Released() or "-", ns.VERSION), noReport = true, gapAfter = true,
		tooltip = function(tt)
			tt:AddLine(L.WORKSHOP_RELEASED:format(Workshop.Released() or "-", ns.VERSION), 1, 0.82, 0)
			tt:AddLine(L.WORKSHOP_RELEASED_TIP, 1, 1, 1, true)
		end,
	}
	InstallLines(lines)
	RollLines(lines, report)
	BugLines(lines)
	-- The elite borders' preview round his own portrait (Borders.lua, 1.0.0): not in the copy.
	if not report then ns.Borders.PreviewLines(lines) end
	return lines, L.TAB_WORKSHOP, L.WORKSHOP_HINT
end

-- The copyable report for Discord (the tab's lines, without its box and its clickable rows).
function Workshop.ReportText()
	local out = { "```", L.WORKSHOP_REPORT_TITLE:format(ns.VERSION, date and date("%Y-%m-%d %H:%M") or "") }
	for _, line in ipairs((Workshop.Build(true))) do
		if not line.noReport then
			local text = (line.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
			local right = (line.right or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
			if line.header then out[#out + 1] = "" end
			out[#out + 1] = (" "):rep(2 * (line.indent or 0)) .. text .. (right ~= "" and ("  " .. right) or "")
		end
	end
	out[#out + 1] = "```"
	return table.concat(out, "\n")
end

function Workshop.Reports() return reports end
function Workshop.State() return roll end

-- Tests start from a clean state.
function Workshop.Reset()
	roll, authorAt, authorName, answeredRoll, sending, full, menuFor = nil, nil, nil, nil, nil, nil, nil
	wipe(reports); wipe(pieces); wipe(bugsFrom); wipe(asked); wipe(askedOne)
	lastRoll, lastRollAnswer, lastUpdateShown, lastBug, lastAsk = -math.huge, -math.huge, -math.huge, -math.huge, -math.huge
	search, shownAnswers, lastAskOne = "", Workshop.ROLL_PAGE, -math.huge
	changePending = false
	Workshop.ResetVersion()
	wipe(bugAsked); wipe(bugAwaited); wipe(waitingReports)
	bugAsk, lastBugAskShown = nil, -math.huge
	if bugAskFrame then bugAskFrame:Hide() end
	bugAskFrame = nil -- (the next one is made with the toolkit then in use)
end

---------------------------------------------------------------------------
-- The High Council (the moderators): a list of character names signed by the author on his
-- own computer (scripts/council-sign.py; Sign.lua checks it), never written in the code. His
-- character loads it from a file that exists on his machine only and publishes it; every
-- client checks the signature, keeps the newest list and passes it along now and then, so
-- nobody needs to be online and nobody can forge or change it.
--   HS1~<time>~<realm group>~<First Surname>,...~<signature>   (signed: all before the last ~)
-- On the channel it travels as HS~<the signed list> (0.9.8): Comm hands a message to its
-- handler only when "~" follows the two letters of its type, and the list starts "HS1~".
-- Departments and titles (0.9.9, Max's) come in a second signed list, so 0.9.8 clients keep
-- the name list they know; it travels as HT~<the signed list>, taken and passed along the same
-- way, and shows titles for names on the name list only (Core.lua):
--   HT1~<time>~<realm group>~<public 0|1>~<departments>~<signature>
--   <departments>: <name>^<icon>^<First Surname>=<title>,...;<name>^<icon>^...
-- A department's name may be empty (councillors outside any department: the council's own);
-- its icon is what ns.CouncilIconValue takes, or nothing. "public" says whether the army sees
-- the council in the census yet (ns.CouncilVisible).
-- The King's Steward (1.0.0, Core.lua: ns.ReadStewards, ns.IsSteward) rides the same list, in an
-- entry of its own among the departments with three "^" (a department has two, so 0.9.9 and
-- ReadDepartments leave it out, and 0.9.9 still takes, shows and passes on the whole list):
--   ^steward^<Alliance|Horde>^<First Surname-Realm>,...
-- A client that lacks the lists asks for them (0.9.9, a moderator's report: a councillor's
-- client that never got the list had no "My council icon", and relays alone can take hours):
--   HQ~<time of the name list it holds, or 0>~<time of the titles list it holds, or 0>
-- A client holding a newer list answers as a relay sends (HS~, then HT~), with the lists newer
-- than the asker's only. 0.9.8 clients drop HQ unread (Comm hands a type it has no handler for
-- to nobody, and logs nothing).
-- Across realms (1.0.0, a moderator on PvP 2 who never got the lists: each realm of WoW:
-- Forever has an SylvanistasNet of its own, and nobody on his had them). Our guild reaches its
-- members on every realm, so the lists travel over GUILD too, taken with the same checks
-- (only a newer list, the same signature budget): a relay now and then (RelayGuild), the
-- author's client at login, and answers to asks there (a client whose guild has addon users on
-- another realm asks over GUILD too). A client that takes a newer list from its guild puts it
-- on its own realm's channel once (PassOn). Versions before 1.0.0 put nothing together from
-- pieces over GUILD and take the lists from the channel alone: they never see these.
---------------------------------------------------------------------------

Workshop.COUNCIL_MAX = 30
Workshop.RELAY_EVERY = 1800 -- a client passes the list along about every 30 minutes...
Workshop.RELAYS = 3         -- ...and about this many clients do, whatever the army's size
local lastCouncilSent = -math.huge
local lastGuildSent = -math.huge -- our last relay over GUILD (1.0.0: RelayGuild)

-- Asking: once LIST_ASK_AFTER to LIST_ASK_AFTER + LIST_ASK_SPREAD seconds after login, then,
-- while still without the name list (or holding a list older than one heard of), again
-- LIST_ASK_AGAIN after an ask nobody answered (no list newer than ours heard since), or
-- LIST_ASK_EVERY after one somebody did; LIST_ASKS times a session at most. An answer goes to
-- the whole channel: while someone else's ask for as much (or more) is under LIST_ASK_HOLD old
-- (its answer can still be on its way), ours waits.
Workshop.LIST_ASK_AFTER, Workshop.LIST_ASK_SPREAD, Workshop.LIST_ASK_HOLD = 45, 45, 40
Workshop.LIST_ASK_AGAIN, Workshop.LIST_ASK_EVERY, Workshop.LIST_ASKS = 150, 600, 3
-- Answering, each kind of list (names, titles) on its own: after LIST_ANSWER_MIN to
-- LIST_ANSWER_MIN + LIST_ANSWER_SPREAD seconds, left out when the same list went out from
-- someone else meanwhile; once per LIST_ANSWER_GAP after we sent it, whatever the number of
-- asks. About LIST_ANSWERS clients take an ask up, whatever the army's size: one draw per
-- LIST_DRAW_GAP (an ask that soon after the one we drew for is covered by its answer), none
-- while the census counts nobody but us (right after a server restart every client would
-- count itself alone, and all of them answer), and one sender's asks count once per
-- LIST_ASK_FROM (a client asks LIST_ASK_AGAIN apart at the soonest).
-- The author's client answers sooner, always, once per AUTHOR_ANSWER_GAP.
-- A handful of answers (1.0.0, Konig's review of 1.0.0: one ask drew some 15 to 45 messages on the
-- channel, every drawn client sending both lists, each 5 to 14 pieces long). The clients drawn go
-- in turn, in the order of their draws over LIST_ANSWER_SPREAD; one that hears another's answer
-- begin (its first piece: Comm.pieceHook) waits for it, the time its pieces take (LIST_HOLD_PIECE
-- each, LIST_HOLD_SLACK more) and its own turn again, and leaves out what it heard whole. It
-- waits LIST_HOLD_MAX past its turn at most: a forged first piece holds an answer back, never
-- silences it. On the channel the draw counts at least our guild's addon users on our realm
-- (their hellos), whatever the census counts: a census still coming in (after a restart) drew
-- most of the channel.
Workshop.LIST_ANSWER_MIN, Workshop.LIST_ANSWER_SPREAD, Workshop.LIST_ANSWER_GAP = 3, 12, 120
Workshop.LIST_DRAW_GAP, Workshop.LIST_ANSWERS, Workshop.LIST_ASK_FROM = 30, 3, 120
Workshop.LIST_HOLD_PIECE, Workshop.LIST_HOLD_SLACK, Workshop.LIST_HOLD_MAX = 1.2, 6, 45
Workshop.AUTHOR_ANSWER_MIN, Workshop.AUTHOR_ANSWER_SPREAD, Workshop.AUTHOR_ANSWER_GAP = 1, 2, 60
-- Passing a list taken from our guild on to our channel (1.0.0, PassOn): our guild's reporter on
-- this realm PASS_MIN to PASS_MIN + PASS_SPREAD seconds after; its runner-up PASS_HOLD after the
-- reporter's copy would be in (the lists go out one piece each SEND_EVERY); anyone else, about
-- RELAYS of our guild's addon users on this realm, as long again after the runner-up's turn and
-- up to PASS_HOLD more. Each only when the same list was not heard on the channel meanwhile.
Workshop.PASS_MIN, Workshop.PASS_SPREAD, Workshop.PASS_HOLD, Workshop.SEND_EVERY = 1, 3, 15, 1.2
local LIST_STORE = { HS = "council", HT = "councilTitles" }
local advertised = { HS = 0, HT = 0 } -- the newest list times heard of this session
local listAsks, lastListAsk, askArmed = 0, -math.huge, false
local listHeardAt = -math.huge -- the last list newer than ours heard on the channel
local heardAsk        -- someone else's asks heard lately: { names, titles, t }, the lowest times
-- Answers go back where the ask came from, the channel or our guild (1.0.0), each lane on its
-- own clock: an answer waiting { names, titles, heard = { HS, HT }, mine }, our last answer of
-- each list, our last draw for each list (won or not), and sender -> when its ask last counted.
local function NewLane()
	return { answering = nil, answeredAt = { HS = -math.huge, HT = -math.huge }, drawnAt = { HS = -math.huge, HT = -math.huge },
		askedFrom = {}, askedFromCount = 0 }
end
local lanes = { CHANNEL = NewLane(), GUILD = NewLane() }
local passing         -- lists taken from our guild, on their way to our channel: { HS = blob, HT = blob, send }

-- The list of a kind ("HS" names, "HT" titles) we hold, as signed, and its time (0: none).
local function HeldList(kind)
	local l = ns.rdb and ns.rdb[LIST_STORE[kind]]
	if type(l) ~= "table" then return nil, 0 end
	return type(l.blob) == "string" and l.blob or nil, tonumber(l.at) or 0
end

-- A list of that kind newer than `than`, when we hold one.
local function NewerList(kind, than)
	local blob, at = HeldList(kind)
	return blob and at > than and blob or nil
end

-- A list time heard of (someone's ask, or a relay the signature budget left unchecked).
local function Advertise(kind, at)
	if at and at > advertised[kind] then advertised[kind] = at end
end

-- A list heard from someone else, on the channel or over GUILD (1.0.0): the very one our answer
-- there would send, so the asker has it (the author's answer goes anyway); on the channel, the
-- one we were to pass on to it (PassOn). Only the list we hold, byte for byte: a forged one
-- with the same time never silences anyone. One newer than ours (taken or not) answers our
-- ask: the next one waits LIST_ASK_EVERY.
local function HeardList(kind, blob, dist)
	local at = tonumber(blob:match("^" .. kind .. "1~(%d+)~"))
	local _, held = HeldList(kind)
	if at and at > held then listHeardAt = ns.Now() end
	local mine = blob == (HeldList(kind))
	local lane = lanes[dist]
	local answering = lane and lane.answering
	if answering and not answering.mine and mine then answering.heard[kind] = true end
	if dist == "CHANNEL" and passing and passing[kind] == blob then passing[kind] = nil end
end

local function AuthorLists() return ns.COUNCIL_SIGNED ~= nil or ns.COUNCIL_TITLES ~= nil end

-- On the channel, or over GUILD (1.0.0).
local function SendLists(names, titles, dist)
	dist = dist == "GUILD" and "GUILD" or nil
	if names then ns.Comm.SendChunked("HS~" .. names, nil, dist) end
	if titles then ns.Comm.SendChunked("HT~" .. titles, nil, dist) end
end

-- Our guild's addon users on other realms than ours, online now (1.0.0; Comm counts them from
-- their hellos).
local function GuildSpansRealms()
	return ns.Comm.SpansRealms ~= nil and ns.Comm.SpansRealms() == true
end

-- Our guild's addon users online, ourselves included (on this realm alone: sameRealm).
local function GuildUsers(sameRealm)
	return (ns.Comm.PeerCount and ns.Comm.PeerCount(sameRealm) or 0) + 1
end

-- The pieces a list goes out in (as "HS~" or "HT~" and the list).
local function Pieces(blob)
	return math.ceil((#blob + 3) / ns.Codec.CHUNK)
end

-- A list newer than ours taken from our guild (1.0.0): a guildmate on another realm may have
-- sent it, and our realm's channel may not have it (each realm has an SylvanistasNet of its own).
-- We put it on our channel once, the way a relay sends it, unless the same list is heard there
-- first. Every guildmate on this realm takes the same list at once, so not all of them: our
-- guild's reporter here soon, its runner-up once the reporter's copy of the lists taken should
-- have come, and a few others after that (see PASS_*). Taken lists of both kinds go out
-- together (the second one taken meanwhile moves the others' turn by the time it takes to send).
local function PassOn(kind, blob)
	local p = passing
	if p then
		p[kind], p.pieces[kind] = blob, Pieces(blob)
		return
	end
	local reporter, runnerUp = ns.Comm.isReporter == true, ns.Comm.isRunnerUp == true
	p = { [kind] = blob, pieces = { [kind] = Pieces(blob) }, at = ns.Now(), send = true }
	passing = p
	local extra = 0
	if reporter then
		extra = Workshop.random() * Workshop.PASS_SPREAD
	elseif not runnerUp then
		extra = Workshop.random() * Workshop.PASS_HOLD
		p.send = Workshop.random() <= math.min(1, Workshop.RELAYS / GuildUsers(true))
	end
	local function Due()
		if reporter then return p.at + Workshop.PASS_MIN + extra end
		local n = 0
		for _, count in pairs(p.pieces) do n = n + count end
		local later = Workshop.PASS_HOLD + n * Workshop.SEND_EVERY
		return p.at + (runnerUp and later or 2 * later + extra)
	end
	local function Try()
		if passing ~= p then return end
		local left = Due() - ns.Now()
		if left > 0.05 then
			Workshop.after(left, "council pass on", Try)
			return
		end
		passing = nil
		if not p.send then return end
		-- Only the lists we still hold: a newer one taken meanwhile has its own turn.
		local names = p.HS and p.HS == (HeldList("HS")) and p.HS or nil
		local titles = p.HT and p.HT == (HeldList("HT")) and p.HT or nil
		if not names and not titles then return end
		lastCouncilSent = ns.Now()
		ns.Log("High Council: passing the lists from our guild on to our channel")
		SendLists(names, titles)
	end
	Workshop.after(Due() - p.at, "council pass on", Try)
end

local function CouncilNames()
	local c = ns.rdb and ns.rdb.council
	local out = {}
	for _, display in pairs(type(c) == "table" and c.names or {}) do out[#out + 1] = display end
	table.sort(out)
	return out
end
Workshop.CouncilNames = CouncilNames

-- A signed list (from the author's file, or heard on the channel): checked, kept if newer.
-- A signature check is the heaviest thing the addon does (0.9.8, Konig's review): lists heard on
-- the channel are checked at most once a minute per sender and VERIFY_MAX times a minute in all,
-- and a list already found false is not checked again. The author's own file is not limited.
-- Once a minute per sender and per kind of list (0.9.9): a relay sends the names and the titles
-- one after the other, and one gap for both would leave the titles unchecked at every relay.
-- Two budgets (1.0.0, Konig's review of 1.0.0: three strangers sending a forged list of each kind
-- spent the whole minute's checks, and nothing relayed was checked meanwhile, a councillor's
-- removal included): lists from our guild (over GUILD, or on the channel from a guildmate our
-- roster knows: the server names the sender) have VERIFY_MAX checks a minute of their own, which
-- nobody outside our guild can spend. And a signature that can't be the author's (not 512 hex
-- digits: Sign.Plausible) is refused before it costs anything, never checked, never asked for.
-- The author's own relays and answers (1.0.0, Konig's second look: "exempt your own relays from
-- the shared cap") are outside both budgets: on a realm where no guildmate our roster knows is
-- his, full-length forgeries from three strangers still spent the channel's checks every minute,
-- and the author's relay removing a councillor waited behind them. His name is the server's word
-- (IsAuthorName), never the sender's. His lists still keep the gap per kind of list (two checks a
-- minute at most: his client relays each 10 minutes and answers an ask once per
-- AUTHOR_ANSWER_GAP) and a list found false is never checked again.
Workshop.VERIFY_GAP, Workshop.VERIFY_MAX = 60, 6
local verifiedFrom, falseLists, falseCount = {}, {}, 0
local verifyTimes = { channel = {}, guild = {} } -- each budget's checks in the last minute
local function MayVerify(sender, kind, blob, now, guild)
	if falseLists[blob] then return false end
	local key = sender and (sender .. "~" .. kind)
	if key and now - (verifiedFrom[key] or -math.huge) < Workshop.VERIFY_GAP then return false end
	if not IsAuthorName(sender) then
		local times = guild and verifyTimes.guild or verifyTimes.channel
		for i = #times, 1, -1 do if now - times[i] >= 60 then table.remove(times, i) end end
		if #times >= Workshop.VERIFY_MAX then return false end
		times[#times + 1] = now
	end
	if key then verifiedFrom[key] = now end
	return true
end
local function RememberFalse(blob)
	if falseCount >= 100 then wipe(falseLists); falseCount = 0 end
	falseLists[blob], falseCount = true, falseCount + 1
end
function Workshop.ResetVerify() -- tests (the list times heard of go too)
	wipe(verifiedFrom); wipe(verifyTimes.channel); wipe(verifyTimes.guild); wipe(falseLists); falseCount = 0
	if Workshop.ResetListAsk then Workshop.ResetListAsk() end
end

-- A list heard from our guild (1.0.0, Konig's review): over GUILD, or on the channel from a
-- guildmate (our roster: the server's word, never the sender's).
local function FromGuild(dist, sender)
	return dist == "GUILD" or (sender ~= nil and ns.Roster ~= nil and ns.Roster.RankOf(sender) ~= nil)
end

-- sender: nil for the author's own file (never limited); the author's name (a relay from his
-- client) outside both budgets; guild: charged to our guild's budget.
function Workshop.TakeCouncil(blob, sender, guild)
	if type(blob) ~= "string" or #blob > 2000 then return false end
	local text, at, realm, list, sig = blob:match("^(HS1~(%d+)~([^~]*)~([^~]*))~(%x+)$")
	at = tonumber(at)
	if not at then return false end
	-- The list we hold (or an older one) is not checked again: each relay would cost every
	-- client a signature check for nothing (0.9.8).
	local c = ns.rdb.council
	if type(c) == "table" and (tonumber(c.at) or 0) >= at then return false end
	if not ns.Sign or not ns.Sign.Plausible(sig) then return false end -- (costs nothing: Konig's review)
	if sender and not MayVerify(sender, "HS", blob, ns.Now(), guild) then
		if not falseLists[blob] then Advertise("HS", at) end -- (not checked: asked for later)
		return false
	end
	if not ns.Sign or not ns.Sign.Verify(text, sig) then
		if sender then
			RememberFalse(blob)
			ns.Log("High Council: a list from %s failed its signature", tostring(sender))
		end
		return false
	end
	local names, n = {}, 0
	for name in list:gmatch("[^,]+") do
		name = name:gsub("^%s+", ""):gsub("%s+$", "")
		if name ~= "" and #name <= 48 and n < Workshop.COUNCIL_MAX then names[name:lower()], n = name, n + 1 end
	end
	ns.rdb.council = { at = at, names = names, realm = realm ~= "" and realm or nil, blob = blob }
	ns.Log("High Council: a signed list of %d names (%s)", n, tostring(at))
	ns.Fire("DATA_CHANGED")
	return true
end

-- From the channel, or from our guild (1.0.0): the same checks either way.
function Workshop.HandleCouncil(dist, sender, text)
	if (dist ~= "CHANNEL" and dist ~= "GUILD") or type(text) ~= "string" then return end
	local blob = text:match("^HS~(HS1~.*)$") or text
	sender = ns.FullName(sender)
	if Workshop.TakeCouncil(blob, sender, FromGuild(dist, sender)) and dist == "GUILD" then PassOn("HS", blob) end
	HeardList("HS", blob, dist)
end
ns.Comm.Handle("HS", function(...) Workshop.HandleCouncil(...) end)

-- The departments and titles (0.9.9): what the addon keeps of them, whatever the list says. A
-- signed list never breaks these (the signing script refuses it first); past them, the rest is
-- left out: TITLES_BLOB bytes in all (or none of it), COUNCIL_MAX councillors, DEPTS_MAX named
-- departments of DEPT_NAME bytes, titles of TITLE_MAX bytes; a councillor once, the first time.
Workshop.TITLES_BLOB, Workshop.DEPTS_MAX, Workshop.DEPT_NAME, Workshop.TITLE_MAX = 3000, 8, 40, 48
local function Trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function ReadDepartments(text)
	local depts, named, count, seen = {}, 0, 0, {}
	for entry in text:gmatch("[^;]+") do
		local name, icon, list = entry:match("^([^%^]*)%^([^%^]*)%^([^%^]*)$")
		name = name and Trim(name)
		if name and #name <= Workshop.DEPT_NAME and (name == "" or named < Workshop.DEPTS_MAX) then
			if name ~= "" then named = named + 1 end
			local d = { name = name, icon = ns.CouncilIconValue(icon), members = {} }
			for m in list:gmatch("[^,]+") do
				local who, title = m:match("^([^=]*)=([^=]*)$")
				who, title = who and Trim(who), title and Trim(title)
				if who and who ~= "" and #who <= 48 and #title <= Workshop.TITLE_MAX and not seen[who:lower()]
					and count < Workshop.COUNCIL_MAX then
					seen[who:lower()], count = true, count + 1
					d.members[#d.members + 1] = { name = who, title = title ~= "" and title or nil }
				end
			end
			depts[#depts + 1] = d
		end
	end
	return depts, count
end

-- A signed titles list, from the author's file or the channel: checked and kept like the names
-- (only a newer one; the same budgets of signature checks).
function Workshop.TakeTitles(blob, sender, guild)
	if type(blob) ~= "string" or #blob > Workshop.TITLES_BLOB then return false end
	local text, at, realm, public, list, sig = blob:match("^(HT1~(%d+)~([^~]*)~([01])~([^~]*))~(%x+)$")
	at = tonumber(at)
	if not at then return false end
	local t = ns.rdb.councilTitles
	if type(t) == "table" and (tonumber(t.at) or 0) >= at then return false end
	if not ns.Sign or not ns.Sign.Plausible(sig) then return false end
	if sender and not MayVerify(sender, "HT", blob, ns.Now(), guild) then
		if not falseLists[blob] then Advertise("HT", at) end
		return false
	end
	if not ns.Sign or not ns.Sign.Verify(text, sig) then
		if sender then
			RememberFalse(blob)
			ns.Log("High Council: a titles list from %s failed its signature", tostring(sender))
		end
		return false
	end
	local depts, n = ReadDepartments(list)
	-- The King's Steward (1.0.0, ns.ReadStewards): an entry of its own among the departments,
	-- which ReadDepartments (and 0.9.9) leave out. This client is told when it becomes his or ends.
	local function Steward() return type(ns.King) == "table" and type(ns.King.IsSteward) == "function" and ns.King.IsSteward() end
	local was = Steward()
	local stewards = ns.ReadStewards(list)
	-- The approved guilds (1.1, Core.lua: ns.ReadApprovedGuilds): the list may make our guild Sylvanistas.
	local wasMember = ns.IsMember()
	ns.rdb.councilTitles = { at = at, public = public == "1", realm = realm ~= "" and realm or nil, depts = depts, blob = blob, stewards = stewards,
		guilds = ns.ReadApprovedGuilds(list) }
	if ns.IsMember() ~= wasMember then Workshop.MembershipChanged(wasMember) end
	local named = 0
	for _, names in pairs(stewards) do named = named + #names end
	ns.Log("High Council: a signed titles list of %d names in %d parts, %d Steward(s) (%s)", n, #depts, named, tostring(at))
	local now = Steward()
	if now and not was then
		ns.Print(L.STEWARD_YOU:format(ns.KingName(ns.KingCharacter())))
		ns.PlayAlert("soft", "throne")
	elseif was and not now then
		ns.Print(L.STEWARD_NO_LONGER)
	end
	-- The list of Hands of each Steward it no longer names ends with him for good, heard or kept,
	-- his own client's too (King.StewardsChanged).
	if type(ns.King) == "table" and type(ns.King.StewardsChanged) == "function" then ns.King.StewardsChanged() end
	ns.Fire("DATA_CHANGED")
	return true
end

function Workshop.HandleTitles(dist, sender, text)
	if (dist ~= "CHANNEL" and dist ~= "GUILD") or type(text) ~= "string" then return end
	local blob = text:match("^HT~(HT1~.*)$") or text
	sender = ns.FullName(sender)
	if Workshop.TakeTitles(blob, sender, FromGuild(dist, sender)) and dist == "GUILD" then PassOn("HT", blob) end
	HeardList("HT", blob, dist)
end
ns.Comm.Handle("HT", function(...) Workshop.HandleTitles(...) end)

---------------------------------------------------------------------------
-- The approved guilds (1.1, the author's; Core.lua: ns.IsApprovedGuild): a guild of Sylvanistas
-- whose name the name rule leaves out counts once the author's signed titles list names it. Its
-- members' addons, no Sylvanistas members until they hold that list, hear only it (over their guild,
-- Comm.lua), and the first of them can paste it (/syl approved paste: the author hands the signed
-- text out; it is checked like any list, so nobody can forge one).
---------------------------------------------------------------------------

-- The list made our guild a Sylvanistas guild, or no longer: the addon starts (the channel, the
-- census, the roster) or stops, as when one joins or leaves a guild.
function Workshop.MembershipChanged(wasMember)
	local guild = (GetGuildInfo and GetGuildInfo("player")) or "?"
	if ns.IsMember() then
		ns.Print(L.APPROVED_YOU:format(guild))
		ns.PlayAlert("soft", "update") -- (the author's word: his signed list)
	elseif wasMember then
		ns.Print(L.APPROVED_NO_LONGER:format(guild))
	end
	if ns.Comm and ns.Comm.CheckMembership then ns.SafeCall("approved membership", ns.Comm.CheckMembership) end
	if ns.Roster and ns.Roster.RequestScan then ns.SafeCall("approved roster", ns.Roster.RequestScan, true) end
end

-- A signed titles list pasted in (the text scripts/council-sign.py prints): taken as a list from
-- our own guild is, with the same checks (only a newer one, its signature the author's). True when
-- taken.
function Workshop.PasteTitles(text)
	local blob = tostring(text or ""):match("(HT1~%d+~[^~]*~[01]~[^~]*~%x+)")
	if not blob or #blob > Workshop.TITLES_BLOB then
		ns.Print(L.APPROVED_PASTE_BAD)
		return false
	end
	local _, held = HeldList("HT")
	if (tonumber(blob:match("^HT1~(%d+)~")) or 0) <= held then
		ns.Print(L.APPROVED_PASTE_HELD)
		return false
	end
	if not Workshop.TakeTitles(blob, ns.me, true) then
		ns.Print(L.APPROVED_PASTE_BAD)
		return false
	end
	ns.Print(L.APPROVED_PASTE_TAKEN)
	-- To our guildmates at once (they may be waiting for it: ns.ApprovedOnly), and our channel.
	if ns.ApprovedOnly() then Workshop.RelayGuild(true) end
	if ns.IsMember() then Workshop.RelayCouncil(true) end
	return true
end

StaticPopupDialogs["SYLVANISTAS_APPROVED_PASTE"] = {
	text = L.APPROVED_PASTE_PROMPT,
	button1 = OKAY or "OK",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 320,
	maxLetters = Workshop.TITLES_BLOB,
	OnShow = function(self)
		local eb = self.editBox or self.EditBox
		if eb then eb:SetText(""); eb:SetFocus() end
	end,
	OnAccept = function(self)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("approved paste", Workshop.PasteTitles, eb and eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		local text = self:GetText()
		self:GetParent():Hide()
		ns.SafeCall("approved paste", Workshop.PasteTitles, text)
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- `/syl approved`: the approved guilds of our faction the list we hold names, and whether ours is
-- one; `/syl approved paste`: the box to paste the signed list in.
function Workshop.Approved(word)
	if tostring(word or ""):lower() == "paste" then return ns.ShowDialog("SYLVANISTAS_APPROVED_PASTE") end
	local list = ns.ApprovedGuilds()
	ns.Print(L.APPROVED_LIST:format(#list > 0 and table.concat(list, ", ") or "-"))
	local guild = IsInGuild() and GetGuildInfo("player")
	if type(guild) == "string" and ns.IsApprovedGuild(guild) then
		ns.Print(L.APPROVED_MINE:format(guild))
	elseif type(guild) == "string" and not ns.IsFederation(guild) then
		ns.Print(L.APPROVED_NOT_MINE:format(guild))
	end
end

-- Passing the lists along, the names and the titles together: the author's client each 10
-- minutes; any other one now and then, so about RELAYS clients a half hour, whatever the
-- army's size.
function Workshop.RelayCouncil(force)
	local c, t = ns.rdb and ns.rdb.council, ns.rdb and ns.rdb.councilTitles
	local names = type(c) == "table" and type(c.blob) == "string" and c.blob or nil
	local titles = type(t) == "table" and type(t.blob) == "string" and t.blob or nil
	if not names and not titles then return end
	local now = ns.Now()
	local mine = AuthorLists()
	local every = mine and 600 or Workshop.RELAY_EVERY
	if not force and now - lastCouncilSent < every then return end
	lastCouncilSent = now
	if not force and not mine then
		local users = ns.King and ns.King.AddonsOnline and ns.King.AddonsOnline() or 1
		if Workshop.random() > math.min(1, Workshop.RELAYS / users) then return end
	end
	SendLists(names, titles)
end

-- The same over GUILD (1.0.0), to our guildmates on other realms: only while our guild has addon
-- users online on another realm, at most once each RELAY_EVERY, and about RELAYS of our guild's
-- addon users each time (a guild of a thousand sends a handful), when our send queue has room
-- (the census report comes first). force: now, whatever these (the author's client at login).
Workshop.GUILD_QUEUE = 30
-- A guild that is Sylvanistas by the signed list alone (1.1, ns.ApprovedOnly): its members without
-- the list are no Sylvanistas members yet, so they can't ask for it and hear nothing on the channel;
-- they take it over GUILD alone (Comm.lua). There the lists go over GUILD each
-- APPROVED_RELAY_EVERY (about RELAYS of its addon users that hold them), whatever its realms.
Workshop.APPROVED_RELAY_EVERY = 300
function Workshop.RelayGuild(force)
	local names, titles = HeldList("HS"), (HeldList("HT"))
	if not names and not titles then return false end
	local now = ns.Now()
	if not force then
		local approved = ns.ApprovedOnly and ns.ApprovedOnly()
		local every = approved and Workshop.APPROVED_RELAY_EVERY or Workshop.RELAY_EVERY
		if now - lastGuildSent < every or not (approved or GuildSpansRealms()) then return false end
		if ns.Comm.QueueSize and ns.Comm.QueueSize() > Workshop.GUILD_QUEUE then return false end
	end
	lastGuildSent = now
	if not force and Workshop.random() > math.min(1, Workshop.RELAYS / GuildUsers()) then return false end
	SendLists(names, titles, "GUILD")
	return true
end

-- Whether we should ask: no name list at all, or one older than a list heard of.
function Workshop.NeedLists()
	if type(ns.rdb and ns.rdb.council) ~= "table" then return true end
	local _, names = HeldList("HS")
	local _, titles = HeldList("HT")
	return names < advertised.HS or titles < advertised.HT
end

-- Our ask, when due (the first one waits for its time after login: askArmed). It tries again
-- LIST_ASK_AGAIN later, for an ask nobody answers (the council's ticker tries each minute).
function Workshop.AskLists()
	if not askArmed or not Workshop.NeedLists() or listAsks >= Workshop.LIST_ASKS then return false end
	local now = ns.Now()
	local wait = listHeardAt > lastListAsk and Workshop.LIST_ASK_EVERY or Workshop.LIST_ASK_AGAIN
	if now - lastListAsk < wait then return false end
	local _, names = HeldList("HS")
	local _, titles = HeldList("HT")
	local h = heardAsk
	if h and now - h.t < Workshop.LIST_ASK_HOLD and h.names <= names and h.titles <= titles then return false end
	listAsks, lastListAsk = listAsks + 1, now
	local ask = ("HQ~%s~%s"):format(names, titles)
	ns.Comm.Send("CHANNEL", ask, "councillists")
	-- Our guild too (1.0.0) while it has addon users online on another realm: they may hold the
	-- lists where nobody on our realm does.
	if GuildSpansRealms() then ns.Comm.Send("GUILD", ask, "councillistsguild") end
	if listAsks < Workshop.LIST_ASKS then
		Workshop.after(Workshop.LIST_ASK_AGAIN, "council lists", function() Workshop.AskLists() end)
	end
	return true
end

-- Someone else's answer beginning (1.0.0, Konig's review): the first piece of a list of a kind our
-- waiting answer on that lane would send, at least as new as ours. Our answer waits for it (see
-- LIST_HOLD_*). Comm hands us the pieces only while an answer of ours waits (Comm.pieceHook).
local function Waiting()
	for _, lane in pairs(lanes) do if lane.answering then return true end end
	return false
end
local function OnPiece(dist, sender, text)
	local lane = lanes[dist == "GUILD" and "GUILD" or "CHANNEL"]
	local a = lane and lane.answering
	if not a or a.mine or type(text) ~= "string" then return end
	local n, body = text:match("^C%w+:1:(%d+):(.*)$")
	n = tonumber(n)
	if not n then return end
	local kind, at = body:match("^(HS)~HS1~(%d+)~")
	if not kind then kind, at = body:match("^(HT)~HT1~(%d+)~") end
	at = tonumber(at)
	if not at then return end
	local than = kind == "HS" and a.names or a.titles
	local _, held = HeldList(kind)
	if not NewerList(kind, than) or at < held then return end
	local now = ns.Now()
	local hold = now + n * Workshop.LIST_HOLD_PIECE + Workshop.LIST_HOLD_SLACK + a.turn * Workshop.LIST_ANSWER_SPREAD
	a.holdUntil = math.min(a.dueAt + Workshop.LIST_HOLD_MAX, math.max(a.holdUntil or 0, hold))
end
local function HookPieces()
	if ns.Comm then ns.Comm.pieceHook = Waiting() and OnPiece or nil end
end

-- Someone's ask: taken up when we hold a newer list and it is our turn (see LIST_ANSWER_*).
-- An answer already waiting covers the asks that come meanwhile. Each list is drawn for and
-- sent on a clock of its own: an ask for the titles alone never holds the names back, and a
-- draw lost (or an answer left out) holds a client back LIST_DRAW_GAP only.
-- dist (1.0.0): where the ask came from, and where the answer goes: the channel (about
-- LIST_ANSWERS of the addons the census counts take it up) or our guild (about LIST_ANSWERS of
-- its addon users), each on its own clock.
function Workshop.AnswerAsk(names, titles, dist)
	dist = dist == "GUILD" and "GUILD" or "CHANNEL"
	local lane = lanes[dist]
	if lane.answering then
		local a = lane.answering
		a.names, a.titles = math.min(a.names, names), math.min(a.titles, titles)
		return false
	end
	local now, mine = ns.Now(), AuthorLists()
	local gap = mine and Workshop.AUTHOR_ANSWER_GAP or Workshop.LIST_ANSWER_GAP
	local kinds = {}
	for kind, than in pairs({ HS = names, HT = titles }) do
		if NewerList(kind, than) and now - lane.answeredAt[kind] >= gap
			and (mine or now - lane.drawnAt[kind] >= Workshop.LIST_DRAW_GAP) then
			kinds[#kinds + 1] = kind
		end
	end
	if #kinds == 0 then return false end
	local turn = 0
	if not mine then
		-- A census that counts nobody but us is not in yet (whoever asked is online too).
		local users = dist == "GUILD" and GuildUsers() or (ns.King and ns.King.AddonsOnline and ns.King.AddonsOnline() or 1)
		if users <= 1 then return false end
		-- (The channel: our guild's addon users on our realm at least, Konig's review.)
		if dist ~= "GUILD" then users = math.max(users, GuildUsers(true)) end
		for _, kind in ipairs(kinds) do lane.drawnAt[kind] = now end
		local share, draw = math.min(1, Workshop.LIST_ANSWERS / users), Workshop.random()
		if draw > share then return false end
		turn = draw / share -- our place among those drawn: 0 first, 1 last
	end
	local wait = mine and Workshop.AUTHOR_ANSWER_MIN + Workshop.random() * Workshop.AUTHOR_ANSWER_SPREAD
		or Workshop.LIST_ANSWER_MIN + turn * Workshop.LIST_ANSWER_SPREAD
	local pending = { names = names, titles = titles, heard = {}, mine = mine, turn = turn, dueAt = now + wait }
	lane.answering = pending
	HookPieces()
	local function Due()
		if lane.answering ~= pending then return end
		local at = ns.Now()
		-- Someone else's answer began meanwhile: its time, then our turn again (OnPiece).
		if pending.holdUntil and pending.holdUntil - at > 0.05 then
			Workshop.after(pending.holdUntil - at, "council answer", Due)
			return
		end
		lane.answering = nil
		HookPieces()
		local send = {}
		for kind, than in pairs({ HS = pending.names, HT = pending.titles }) do
			if not pending.heard[kind] and at - lane.answeredAt[kind] >= gap then send[kind] = NewerList(kind, than) end
		end
		if send.HS then lane.answeredAt.HS = at end
		if send.HT then lane.answeredAt.HT = at end
		SendLists(send.HS, send.HT, dist)
	end
	Workshop.after(wait, "council answer", Due)
	return true
end

-- An ask on the channel, or over GUILD from a guildmate (1.0.0, maybe on another realm).
function Workshop.HandleListAsk(dist, sender, text)
	if (dist ~= "CHANNEL" and dist ~= "GUILD") or type(text) ~= "string" or #text > 40 then return end
	sender = ns.FullName(sender)
	if type(sender) ~= "string" or sender == ns.me then return end
	local names, titles = text:match("^HQ~(%d+)~(%d+)$")
	names, titles = tonumber(names), tonumber(titles)
	if not names or not titles then return end
	-- One sender's asks count once per LIST_ASK_FROM (on each lane: a client whose guild spans
	-- realms asks both): a character sending asks without end brings no more draws than that (a
	-- client of ours asks LIST_ASK_AGAIN apart at the soonest).
	local now, lane = ns.Now(), lanes[dist]
	local askedFrom = lane.askedFrom
	if now - (askedFrom[sender] or -math.huge) < Workshop.LIST_ASK_FROM then return end
	if not askedFrom[sender] then
		if lane.askedFromCount >= 200 then -- (the table stays small: the old ones go first)
			for name, t in pairs(askedFrom) do
				if now - t >= Workshop.LIST_ASK_FROM then askedFrom[name], lane.askedFromCount = nil, lane.askedFromCount - 1 end
			end
			if lane.askedFromCount >= 200 then wipe(askedFrom); lane.askedFromCount = 0 end
		end
		lane.askedFromCount = lane.askedFromCount + 1
	end
	askedFrom[sender] = now
	Advertise("HS", names)
	Advertise("HT", titles)
	-- (Its answer reaches us wherever it goes: the channel we are on, or our guild.)
	local h = heardAsk
	if h and now - h.t < Workshop.LIST_ASK_HOLD then
		h.names, h.titles = math.min(h.names, names), math.min(h.titles, titles)
	else
		heardAsk = { names = names, titles = titles, t = now }
	end
	Workshop.AnswerAsk(names, titles, dist)
end
ns.Comm.Handle("HQ", function(...) Workshop.HandleListAsk(...) end)

-- Tests start from a clean state.
function Workshop.ResetListAsk()
	advertised.HS, advertised.HT = 0, 0
	listAsks, lastListAsk, askArmed, heardAsk, listHeardAt = 0, -math.huge, false, nil, -math.huge
	-- (In place: an answer or a pass-on still waiting finds nothing left to send.)
	for _, lane in pairs(lanes) do
		for k, v in pairs(NewLane()) do lane[k] = v end
		lane.answering = nil
	end
	HookPieces()
	passing, lastGuildSent = nil, -math.huge
end

-- /syl council (list): the names in chat; on the King's screen while the councillors' names are
-- hidden there (his stream, ns.CouncilMasked), each cut short as in the Realm (0.9.9).
function Workshop.EditCouncil(verb)
	local names = CouncilNames()
	if ns.CouncilMasked() then
		for i, name in ipairs(names) do names[i] = ns.MaskName(name) end
	end
	ns.Print(L.COUNCIL_LIST:format(#names > 0 and table.concat(names, ", ") or "-"))
end

-- The council as the census shows it (0.9.9, Views.lua): the councillors outside any department
-- first (the titles list's own, then anyone on the name list it leaves out, by name), then each
-- department in the list's order with its councillors in theirs. Names on the name list only;
-- a department left with nobody is left out.
--   loose = { { name, title }, ... }, depts = { { name, icon, members = { { name, title }, ... } }, ... }
function Workshop.CouncilTree()
	local loose, depts, placed = {}, {}, {}
	local t = ns.CouncilTitles()
	for _, d in ipairs(t and t.depts or {}) do
		local own = type(d) == "table" and d.name == ""
		local into = own and loose or {}
		for _, m in ipairs(type(d) == "table" and type(d.members) == "table" and d.members or {}) do
			local key = type(m) == "table" and type(m.name) == "string" and m.name:lower()
			if key and not placed[key] and ns.IsHighCouncillor(m.name) then
				placed[key] = true
				into[#into + 1] = { name = m.name, title = type(m.title) == "string" and m.title ~= "" and m.title or nil }
			end
		end
		if not own and #into > 0 and type(d.name) == "string" then
			depts[#depts + 1] = { name = d.name, icon = ns.CouncilIconValue(d.icon), members = into }
		end
	end
	for _, name in ipairs(CouncilNames()) do
		if not placed[name:lower()] and ns.IsHighCouncillor(name) then loose[#loose + 1] = { name = name } end
	end
	return loose, depts
end

-- Asking a High Councillor for help (Max's): the councillors who opted in (/syl council help on)
-- say so on the channel every few minutes; a player's request goes by whisper to up to three
-- of them online, once every five minutes at most.
Workshop.HELP_EVERY, Workshop.HELP_FRESH, Workshop.HELP_GAP = 300, 700, 300
local available, lastHelpSent, lastAvailSent, helpFrom = {}, -math.huge, -math.huge, {}
local asking -- our request waiting for a councillor's "got it": { t, acked }
Workshop.ACK_WAIT = 10
function Workshop.SetCouncilHelp(on)
	if not ns.IsHighCouncillor(ns.me) then return ns.Print(L.COUNCIL_HELP_ONLY) end
	ns.db.councilHelp = on and true or false
	ns.Print(on and L.COUNCIL_HELP_ON or L.COUNCIL_HELP_OFF)
	lastAvailSent = -math.huge
	-- Off: said at once, so nobody's request goes to us meanwhile.
	if not on then ns.Comm.Send("CHANNEL", "HA~0", "counciladvert") end
	Workshop.SayAvailable()
end
function Workshop.SayAvailable()
	if not ns.db.councilHelp or not ns.IsHighCouncillor(ns.me) then return end
	local now = ns.Now()
	if now - lastAvailSent < Workshop.HELP_EVERY then return end
	lastAvailSent = now
	ns.Comm.Send("CHANNEL", "HA~1", "counciladvert")
end
function Workshop.HandleAvailable(dist, sender, text)
	if dist ~= "CHANNEL" or not ns.IsHighCouncillor(sender) then return end
	available[ns.FullName(sender)] = (text ~= "HA~0") and ns.Now() or nil
end
function Workshop.Available()
	local out, now = {}, ns.Now()
	for name, t in pairs(available) do if now - t <= Workshop.HELP_FRESH then out[#out + 1] = name end end
	table.sort(out)
	return out
end
function Workshop.AskCouncil(text)
	text = ns.Cut(ns.Codec.Plain(tostring(text or "")), 180) -- (never half a letter, 0.9.8)
	local now = ns.Now()
	if now - lastHelpSent < Workshop.HELP_GAP then return ns.Print(L.COUNCIL_ASK_WAIT) end
	local list = Workshop.Available()
	if #list == 0 then return ns.Print(L.COUNCIL_ASK_NOBODY) end
	lastHelpSent = now
	for i = 1, math.min(3, #list) do
		local k = Workshop.random(1, #list)
		ns.Comm.Whisper(list[k], "HR~" .. text, "councilask" .. i)
		table.remove(list, k)
	end
	-- Sent is not received (a councillor may have just logged off): told only when one of them
	-- says "got it"; none within ACK_WAIT, the player is told and may ask again at once.
	local mine = { t = now }
	asking = mine
	ns.After(Workshop.ACK_WAIT, "council ask", function()
		if asking ~= mine or mine.acked then return end
		asking, lastHelpSent = nil, -math.huge
		ns.Print(L.COUNCIL_ASK_NOBODY)
	end)
end
function Workshop.HandleCouncilAck(dist, sender)
	if dist ~= "WHISPER" or not asking or asking.acked or not ns.IsHighCouncillor(sender) then return end
	asking.acked = true
	ns.Print(L.COUNCIL_ASK_SENT)
end
function Workshop.HandleAsk(dist, sender, text)
	if dist ~= "WHISPER" or not ns.db.councilHelp or not ns.IsHighCouncillor(ns.me) then return end
	local now, who = ns.Now(), ns.FullName(sender)
	if now - (helpFrom[who] or -math.huge) < 60 then return end
	helpFrom[who] = now
	ns.Comm.Whisper(who, "HK~1", "councilack")
	local msg = ns.Codec.Plain(text:match("^HR~(.*)$") or "")
	ns.Print(L.COUNCIL_ASKED:format("|Hplayer:" .. ns.TellName(who) .. "|h[" .. ns.DisplayName(who) .. "]|h", msg))
	ns.PlayAlert("soft", "help")
end
ns.Comm.Handle("HA", function(...) Workshop.HandleAvailable(...) end)
ns.Comm.Handle("HR", function(...) Workshop.HandleAsk(...) end)
ns.Comm.Handle("HK", function(...) Workshop.HandleCouncilAck(...) end)
function Workshop.ResetHelp() wipe(available); wipe(helpFrom); asking, lastHelpSent, lastAvailSent = nil, -math.huge, -math.huge end -- tests

StaticPopupDialogs["SYLVANISTAS_COUNCIL_ASK"] = {
	text = L.COUNCIL_ASK_PROMPT,
	button1 = L.COUNCIL_ASK_SEND,
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	maxLetters = 180,
	editBoxWidth = 260, -- (a sentence, not a name)
	OnAccept = function(self)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("council ask", Workshop.AskCouncil, eb and eb:GetText() or "")
	end,
	-- Enter sends and Escape closes, as in our other boxes (0.9.8: Enter did nothing).
	EditBoxOnEnterPressed = function(self)
		ns.SafeCall("council ask", Workshop.AskCouncil, self:GetText())
		self:GetParent():Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- The councillors' own icons (0.9.8, the High Council's wish): each councillor picks an icon
-- for their name in the Sylvanistas chats from the game's icons, as the macro window does (in a
-- window of ours: Blizzard's macro icon window, opened from addon code, would run tainted). Their
-- client says which on the channel when it changes, then about every ICON_EVERY. Every client
-- keeps it for councillors only (ns.IsHighCouncillor of the sender the server stamped), and only
-- a file number or a plain icon name under Interface\Icons (ns.CouncilIconValue): nothing else
-- can reach the chat line. Since 0.9.9 it is optional flavour after the council's fixed mark
-- (Core.lua); none heard yet: the mark alone.
--   HI~<file number or icon name>   |   HI~0   (no icon: the mark alone)
---------------------------------------------------------------------------

Workshop.ICON_EVERY = 1200 -- about every 20 minutes (the council ticker runs once a minute)
Workshop.ICON_COLS, Workshop.ICON_ROWS = 8, 5
local ICON_CELL, ICON_GAP = 36, 4
local lastIconSent = -math.huge
local picker          -- the picker window, built the first time it opens
local gameIcons       -- the game's icons while it is open (let go when it closes, like Blizzard's)
local shownIcons      -- the ones the filter leaves
local iconPage, iconChoice = 1, nil

-- Our own icon (per character, like the council's names), or nil for none. False is "none"
-- chosen on purpose: it is still said ("0"), so the old one fades everywhere.
local function MyIcon()
	local mine = ns.db and ns.db.councilIcons
	return ns.CouncilIconValue(type(mine) == "table" and ns.me and mine[ns.me] or nil)
end
Workshop.MyIcon = MyIcon

-- Our icon on the channel: at once when forced (a change), else every ICON_EVERY. Only a
-- councillor's client says it, and only once they picked one (or none, on purpose).
function Workshop.SayIcon(force)
	if not ns.IsHighCouncillor(ns.me) then return false end
	local mine = ns.db and ns.db.councilIcons
	if not force and (type(mine) ~= "table" or mine[ns.me] == nil) then return false end
	local now = ns.Now()
	if not force and now - lastIconSent < Workshop.ICON_EVERY then return false end
	lastIconSent = now
	ns.Comm.Send("CHANNEL", "HI~" .. tostring(MyIcon() or 0), "councilicon")
	return true
end

-- A councillor's choice (the picker's OK): kept on this character and said at once; nil takes
-- the icon away (the mark stays).
function Workshop.SetCouncilIcon(v)
	if not ns.IsHighCouncillor(ns.me) then
		ns.Print(L.COUNCIL_ICON_ONLY)
		return false
	end
	local icon = ns.CouncilIconValue(v)
	if v ~= nil and not icon then return false end
	if type(ns.db.councilIcons) ~= "table" then ns.db.councilIcons = {} end
	ns.db.councilIcons[ns.me] = icon or false
	Workshop.SayIcon(true)
	ns.Print(icon and L.COUNCIL_ICON_SET:format("|T" .. ns.CouncilIconTexture(icon) .. ":0|t") or L.COUNCIL_ICON_RESET)
	return true
end

-- The icons heard, per realm group like the council's list (kept in the SavedVariables, so a
-- /reload shows them at once): councillor (Name-Realm) -> { icon, t }.
local function HeardIcons()
	if type(ns.rdb.councilIcons) ~= "table" then ns.rdb.councilIcons = {} end
	return ns.rdb.councilIcons
end

-- Councillors no longer on the list, and anything that is not an icon, go; past COUNCIL_MAX,
-- the ones heard longest ago.
local function PruneIcons(store)
	local n = 0
	for who, e in pairs(store) do
		if type(who) ~= "string" or type(e) ~= "table" or not ns.CouncilIconValue(e.icon) or not ns.IsHighCouncillor(who) then
			store[who] = nil
		else
			n = n + 1
		end
	end
	while n > Workshop.COUNCIL_MAX do
		local oldest, at = nil, math.huge
		for who, e in pairs(store) do
			local t = tonumber(e.t) or 0
			if t < at then oldest, at = who, t end
		end
		if not oldest then break end
		store[oldest], n = nil, n - 1
	end
end

function Workshop.HandleIcon(dist, sender, text)
	if dist ~= "CHANNEL" or not ns.IsHighCouncillor(sender) or type(text) ~= "string" then return end
	local v = text:match("^HI~([%w_]+)$")
	if not v then return end
	local store, who = HeardIcons(), ns.FullName(sender)
	if v == "0" then
		store[who] = nil
		return
	end
	local icon = ns.CouncilIconValue(v)
	if not icon then return end
	store[who] = { icon = icon, t = ns.Now() }
	PruneIcons(store)
end
ns.Comm.Handle("HI", function(...) Workshop.HandleIcon(...) end)

-- The game's icons, as the macro window lists them (Blizzard's IconDataProvider.lua): its loose
-- icons, then the spells' and the items' (file numbers or names: Blizzard's code takes either).
-- Each is a client function that fills a table; one a client lacks, or that fails, is skipped.
-- Repeats, and anything ns.CouncilIconValue refuses, are left out. Also: whether any is a name
-- (only names can be filtered; file numbers say nothing).
local ICON_LISTS = { "GetLooseMacroIcons", "GetLooseMacroItemIcons", "GetMacroIcons", "GetMacroItemIcons" }
function Workshop.GameIcons()
	local out, seen, names = {}, {}, false
	for _, api in ipairs(ICON_LISTS) do
		local fill = _G[api]
		local list = {}
		if type(fill) == "function" and pcall(fill, list) then
			for _, v in ipairs(list) do
				local icon = ns.CouncilIconValue(v)
				local key = icon and tostring(icon):lower()
				if key and not seen[key] then
					seen[key] = true
					out[#out + 1] = icon
					if type(icon) == "string" then names = true end
				end
			end
		end
	end
	return out, names
end

local function IconLabel(icon)
	return type(icon) == "number" and ("#" .. icon) or tostring(icon)
end

function Workshop.RefreshIconPicker()
	if not picker then return end
	local per = Workshop.ICON_COLS * Workshop.ICON_ROWS
	local list = shownIcons or {}
	local pages = math.max(1, math.ceil(#list / per))
	iconPage = math.max(1, math.min(iconPage, pages))
	for i, b in ipairs(picker.cells) do
		local icon = list[(iconPage - 1) * per + i]
		b.icon = icon
		if icon then
			b.art:SetTexture(ns.CouncilIconTexture(icon))
			b.chosen:SetShown(icon == iconChoice)
			b:Show()
		else
			b:Hide()
		end
	end
	picker.page:SetText(L.COUNCIL_ICON_PAGE:format(iconPage, pages))
	picker.prev:SetEnabled(iconPage > 1)
	picker.next:SetEnabled(iconPage < pages)
	picker.empty:SetShown(#list == 0)
	-- The preview: the icon large (the mark when none is picked), and our name as the chats will
	-- show it: the mark always, the icon after it (0.9.9).
	local texture = ns.CouncilIconTexture(iconChoice)
	picker.preview:SetTexture(texture or ns.HIGH_COUNCIL_SKULL)
	picker.sample:SetText("[" .. L.CHAN_ALL .. "] [" .. ns.HIGH_COUNCIL_MARK .. (texture and ("|T" .. texture .. ":0|t") or "")
		.. "|c" .. ns.HIGH_COUNCIL_COLOR .. (ns.DisplayName(ns.me) or "?") .. "|r]")
	picker.chosenName:SetText(iconChoice and IconLabel(iconChoice) or L.COUNCIL_ICON_MARK_ONLY)
end

-- A click on an icon (or No icon, nil): the preview only, until OK.
function Workshop.PickIcon(icon)
	iconChoice = ns.CouncilIconValue(icon)
	Workshop.RefreshIconPicker()
end

function Workshop.IconPage(n)
	iconPage = tonumber(n) or 1
	Workshop.RefreshIconPicker()
end

-- The filter: the names (and file numbers) that hold the text, any case.
function Workshop.FilterIcons(text)
	text = tostring(text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then
		shownIcons = gameIcons
	else
		shownIcons = {}
		for _, icon in ipairs(gameIcons or {}) do
			if tostring(icon):lower():find(text, 1, true) then shownIcons[#shownIcons + 1] = icon end
		end
	end
	iconPage = 1
	Workshop.RefreshIconPicker()
end

local function PickerButton(f, label, width)
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(label)
	return b
end

-- Our own window on UIParent: movable, closed by its X (and by Escape with mouse and keyboard,
-- ns.EscapeCloses), no Blizzard frame touched. Its filter box never takes the keyboard by
-- itself: the player clicks into it (the gamepad UI's rule, ns.Focus).
local function MakePicker()
	local cols, rows = Workshop.ICON_COLS, Workshop.ICON_ROWS
	local gridW = cols * ICON_CELL + (cols - 1) * ICON_GAP
	local gridTop = -150
	local gridBottom = gridTop - (rows * ICON_CELL + (rows - 1) * ICON_GAP)
	local f = CreateFrame("Frame", "SylvanistasCouncilIconFrame", UIParent)
	f:SetSize(gridW + 56, -gridBottom + 96)
	f:SetPoint("CENTER", 0, 40)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	local okBorder, border = pcall(CreateFrame, "Frame", nil, f, "DialogBorderTemplate")
	if not okBorder or not border then
		border = f:CreateTexture(nil, "BACKGROUND")
		border:SetColorTexture(0, 0, 0, 0.85)
	end
	border:SetAllPoints()
	f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	f.title:SetPoint("TOP", 0, -18)
	f.title:SetText(L.COUNCIL_ICON_TITLE)
	f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	f.close:SetPoint("TOPRIGHT", -4, -4)
	f.close:SetScript("OnClick", function() f:Hide() end)
	-- The preview, and the hint.
	f.preview = f:CreateTexture(nil, "ARTWORK")
	f.preview:SetSize(40, 40)
	f.preview:SetPoint("TOPLEFT", 28, -40)
	f.sample = f:CreateFontString(nil, "ARTWORK", "ChatFontNormal")
	f.sample:SetPoint("TOPLEFT", f.preview, "TOPRIGHT", 10, -3)
	f.sample:SetWidth(gridW - 50)
	f.sample:SetJustifyH("LEFT")
	f.sample:SetWordWrap(false)
	f.chosenName = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	f.chosenName:SetPoint("TOPLEFT", f.sample, "BOTTOMLEFT", 0, -6)
	f.hint = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	f.hint:SetPoint("TOPLEFT", 28, -88)
	f.hint:SetWidth(gridW)
	f.hint:SetJustifyH("LEFT")
	f.hint:SetText(L.COUNCIL_ICON_HINT)
	-- The filter (only when the game lists names).
	f.filterLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	f.filterLabel:SetPoint("TOPLEFT", 28, -124)
	f.filterLabel:SetText(L.COUNCIL_ICON_FILTER)
	local okBox, eb = pcall(CreateFrame, "EditBox", "SylvanistasCouncilIconFilter", f, "InputBoxTemplate")
	if not okBox or not eb then eb = CreateFrame("EditBox", nil, f) end
	eb:SetSize(160, 20)
	eb:SetPoint("LEFT", f.filterLabel, "RIGHT", 12, 0)
	eb:SetAutoFocus(false)
	eb:SetMaxLetters(40)
	eb:SetFontObject("ChatFontNormal")
	eb.sylvanistasBox = true
	eb:SetScript("OnTextChanged", function(self) ns.SafeCall("council icon filter", Workshop.FilterIcons, self:GetText()) end)
	eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	f.filter = eb
	-- The grid, a page at a time (the mouse wheel turns them too).
	f.cells = {}
	for i = 1, cols * rows do
		local b = CreateFrame("Button", nil, f)
		b:SetSize(ICON_CELL, ICON_CELL)
		local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
		b:SetPoint("TOPLEFT", 28 + col * (ICON_CELL + ICON_GAP), gridTop - row * (ICON_CELL + ICON_GAP))
		b.art = b:CreateTexture(nil, "ARTWORK")
		b.art:SetAllPoints()
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		b.chosen = b:CreateTexture(nil, "OVERLAY")
		b.chosen:SetTexture("Interface\\Buttons\\CheckButtonHilight")
		b.chosen:SetBlendMode("ADD")
		b.chosen:SetAllPoints()
		b.chosen:Hide()
		b:SetScript("OnClick", function(self) ns.SafeCall("council icon pick", Workshop.PickIcon, self.icon) end)
		b:SetScript("OnEnter", function(self)
			if not self.icon or not GameTooltip then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(IconLabel(self.icon), 1, 1, 1)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
		f.cells[i] = b
	end
	f.empty = f:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	f.empty:SetPoint("TOP", 0, gridTop - 20)
	f.empty:SetText(L.COUNCIL_ICON_NONE)
	f:EnableMouseWheel(true)
	f:SetScript("OnMouseWheel", function(_, delta) ns.SafeCall("council icon page", Workshop.IconPage, iconPage - delta) end)
	f.prev = PickerButton(f, "<", 32)
	f.prev:SetPoint("TOPLEFT", 28, gridBottom - 8)
	f.prev:SetScript("OnClick", function() ns.SafeCall("council icon page", Workshop.IconPage, iconPage - 1) end)
	f.next = PickerButton(f, ">", 32)
	f.next:SetPoint("TOPRIGHT", -28, gridBottom - 8)
	f.next:SetScript("OnClick", function() ns.SafeCall("council icon page", Workshop.IconPage, iconPage + 1) end)
	f.page = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	f.page:SetPoint("TOP", 0, gridBottom - 13)
	-- No icon (the mark alone), Cancel and OK. OK with nothing changed only closes.
	f.default = PickerButton(f, L.COUNCIL_ICON_DEFAULT, 120)
	f.default:SetPoint("BOTTOMLEFT", 24, 18)
	f.default:SetScript("OnClick", function() ns.SafeCall("council icon pick", Workshop.PickIcon, nil) end)
	f.ok = PickerButton(f, OKAY or "OK", 90)
	f.ok:SetPoint("BOTTOMRIGHT", -24, 18)
	f.ok:SetScript("OnClick", function()
		ns.SafeCall("council icon ok", function()
			if iconChoice == MyIcon() or Workshop.SetCouncilIcon(iconChoice) then f:Hide() end
		end)
	end)
	f.cancel = PickerButton(f, CANCEL or "Cancel", 90)
	f.cancel:SetPoint("RIGHT", f.ok, "LEFT", -8, 0)
	f.cancel:SetScript("OnClick", function() f:Hide() end)
	f:SetScript("OnHide", function(self)
		if self:IsShown() then return end -- the whole interface hidden (Alt+Z): still open
		self.filter:ClearFocus()
		gameIcons, shownIcons = nil, nil
	end)
	return f
end

-- /syl council icon, and the Realm tab's button: a councillor's alone.
function Workshop.ShowIconPicker()
	if not ns.IsHighCouncillor(ns.me) then
		ns.Print(L.COUNCIL_ICON_ONLY)
		return false
	end
	picker = picker or MakePicker()
	local names
	gameIcons, names = Workshop.GameIcons()
	shownIcons, iconChoice = gameIcons, MyIcon()
	picker.filter:SetText("")
	picker.filter:SetShown(names)
	picker.filterLabel:SetShown(names)
	-- It opens at the page of the icon in use.
	iconPage = 1
	for i, icon in ipairs(gameIcons) do
		if icon == iconChoice then
			iconPage = math.floor((i - 1) / (Workshop.ICON_COLS * Workshop.ICON_ROWS)) + 1
			break
		end
	end
	Workshop.RefreshIconPicker()
	picker:Show()
	ns.EscapeCloses("SylvanistasCouncilIconFrame")
	return true
end

function Workshop.IconPicker() return picker end

-- Tests start from a clean state.
function Workshop.ResetIcons()
	if picker then picker:Hide() end
	picker, gameIcons, shownIcons, iconPage, iconChoice = nil, nil, nil, 1, nil
	lastIconSent = -math.huge
end

-- At login. The author's machine holds the signed lists (CouncilList.lua, never published: the
-- names, and the titles since 0.9.9): his client takes them and sends the newest it holds at
-- once. Any other client passes the lists along a whole RELAY_EVERY after login at the earliest
-- (0.9.8): until the census says how many addons are online, each would count itself alone and
-- relay for sure, the whole army at once after a server restart. A client without the lists
-- asks for them (0.9.9): first LIST_ASK_AFTER to LIST_ASK_AFTER + LIST_ASK_SPREAD after login,
-- then when due (Workshop.AskLists), the council's ticker trying too.
-- Over GUILD (1.0.0) the same: the author's client sends his lists to his guildmates on every
-- realm at once too, any other client a whole RELAY_EVERY after login at the earliest (RelayGuild).
function Workshop.CouncilLogin()
	lastCouncilSent, lastGuildSent = ns.Now(), ns.Now()
	if ns.COUNCIL_SIGNED then Workshop.TakeCouncil(ns.COUNCIL_SIGNED) end
	if ns.COUNCIL_TITLES then Workshop.TakeTitles(ns.COUNCIL_TITLES) end
	if ns.COUNCIL_SIGNED or ns.COUNCIL_TITLES then
		ns.After(15, "council", function()
			Workshop.RelayCouncil(true)
			Workshop.RelayGuild(true)
		end)
	end
	ns.After(Workshop.LIST_ASK_AFTER + Workshop.random() * Workshop.LIST_ASK_SPREAD, "council lists", function()
		askArmed = true
		Workshop.AskLists()
	end)
	ns.Every(60, "council", function()
		Workshop.RelayCouncil()
		Workshop.RelayGuild()
		Workshop.AskLists()
		Workshop.SayAvailable()
		Workshop.SayIcon()
	end)
end
ns.On("LOGIN", function() Workshop.CouncilLogin() end)

ns.Comm.Handle("V1", function(...) Workshop.HandleRoll(...) end)
ns.Comm.Handle("V2", function(...) Workshop.HandleAnswer(...) end)
ns.Comm.Handle("V3", function(...) Workshop.HandleUpdate(...) end)
ns.Comm.Handle("V4", function(...) Workshop.HandlePresence(...) end)
ns.Comm.Handle("V5", function(...) Workshop.HandleBug(...) end)
ns.Comm.Handle("V6", function(...) Workshop.HandleAck(...) end)
ns.Comm.Handle("VR", function(...) Workshop.HandleBugAsk(...) end)

ns.On("LOGIN", function()
	-- The author says he is online once on the channel, then every PRESENCE_EVERY.
	ns.After(40, "author presence", Workshop.SendPresence)
	ns.Every(Workshop.PRESENCE_EVERY, "author presence", Workshop.SendPresence)
end)
