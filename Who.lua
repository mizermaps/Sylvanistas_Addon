local ADDON, ns = ...
local L = ns.L

-- The game's /who, shared by the Join screen (Sylvanistas members online to ask) and the census
-- Refresh button (Sylvanistas guilds nobody reports, seen online). One search per click: the
-- game only takes /who from a hardware event, so never from a timer, and at most one every
-- COOLDOWN seconds whichever button sent it. The Who button of our person panel keeps the
-- same distance from these (SendPlain). Any other click in our window (opening it, a tab, a
-- row, a button) searches on its own too, quietly (Auto): nobody has to press Refresh.
--
-- Searching quietly. The answer (WHO_LIST_UPDATE) opens Blizzard's own who list: the Who tab
-- of the Social window on the old UI (FriendsFrame), the group finder's list on Forever's new
-- UI (LFGWhoListFrame, which shows LFGParentFrame on every update; the Social window there
-- does not listen), and ClassicUI Forever's list in the Social window. For our search only,
-- the ones that listen stop listening and get the event back with the answer, or after
-- TIMEOUT without one. Nothing of theirs is replaced or moved. With the player's own who
-- window open nothing is touched: the search is skipped, the answer would land in it.
-- A search given up before its answer (no answer by TIMEOUT, someone else searched) keeps
-- results going to the UI until that answer comes, see Release.
--
-- Blizzard's gamepad UI (0.9.8): nothing of theirs is silenced there, and no search goes on
-- its own. Forever guards the events of a frame (its API marks RegisterEvent, UnregisterEvent
-- and IsEventRegistered as checking the frame's EventRegistrations aspect), our code gave them
-- back from a timer, often while the player was already walking, and the list we silence
-- opens its window on every answer (ShowUIPanel), which the gamepad's frame manager follows.
-- Any of it can end in the game's "blocked" message there. Refresh and the Join screen's
-- search still search, plainly, and the answer shows in the game's who list as a /who does
-- (Sylvanistas reads it from there). So does the King's click on his Throne's /who line (1.1, his
-- key rotation: SearchGuild with `own`, one guild's players). The quiet ones (Auto, SearchGuild
-- from the Realm tab, a name) don't search.
--
-- Past the cap. The server lists at most 50 players per search (MAX_WHOS_FROM_SERVER; on
-- Forever the total it reports stops at 50 too). When the broad search is capped, the next
-- clicks search level ranges and add what they find (one player once, by name: the server
-- lists some twice) until every range was searched once. The click after that starts over,
-- and so does one ROUND_TTL after the round began: its players have moved on meanwhile.

local Who = {}
ns.Who = Who

local EVENT = "WHO_LIST_UPDATE"
Who.COOLDOWN = 10
Who.TIMEOUT = 6    -- no answer by then: the who windows get their event back
Who.SETTLE = 1     -- the answer announced again within this is still ours (see OnAnswer)
Who.LATE = 30      -- a search given up may still be answered until then (see Release)
Who.ROUND_TTL = 15 * 60 -- a round older than this starts over (like a report, Data.FRESH)
Who.AUTO_AGAIN = 5 * 60 -- a complete round older than this is searched again by Auto
Who.AUTO_GAP = 60      -- the quiet search on a click in our window: once a minute at most (0.9.2)
Who.lastAuto = -math.huge
Who.MAX = 50       -- players per answer, MAX_WHOS_FROM_SERVER
Who.BRACKETS = 5   -- level ranges searched after a capped answer
Who.QUERY = 'g-"Sylvanistas"'
-- Guild names with Sylvanistas misspelled (ns.IsFederation takes them): the broad search can't
-- see them, so a round ends with one search for each, one per click. The server matches any
-- part of the name: "Silvanist" finds Silvanistas and Silvanista, "Sylvanyst" Sylvanystas.
-- (Each one costs a /who click: keep the list short, or empty.)
Who.VARIANTS = { "Silvanist", "Sylvanyst" }
Who.lastSend = 0   -- GetTime of our last search, 0 = none yet
Who.lastPlain = 0  -- GetTime of the last SendPlain, 0 = none yet

-- The frames that open a who list on WHO_LIST_UPDATE, looked up when we search (Blizzard's
-- group finder loads on demand). ClassicUI Forever's is its list's `driver` frame.
local LISTENERS = {
	{ "FriendsFrame", function() return _G.FriendsFrame end },
	{ "LFGWhoListFrame", function() return _G.LFGWhoListFrame end },
	{ "ClassicUIForeverWhoPanel.driver", function()
		local panel = _G.ClassicUIForeverWhoPanel
		return type(panel) == "table" and panel.driver or nil
	end },
}
-- The player's own who windows: old UI, Forever, ClassicUI Forever.
local WINDOWS = { "WhoFrame", "LFGWhoListFrame", "ClassicUIForeverWhoPanel" }

-- The round of searches in progress. step: the next search, 0 = the broad one, k = level
-- range k. shown/total: the broad answer's counts. missing: players may be left out (a
-- capped answer not dug through yet, or a level range capped too). done: every search of
-- the round answered, the next click starts over. started: GetTime of the broad answer.
local sweep
local function NewSweep()
	sweep = { step = 0, list = {}, byName = {}, answers = 0, shown = 0, total = 0,
		capped = false, missing = false, done = false, variant = 0 }
	Who.sweep = sweep
end
NewSweep()

local pending   -- our search waiting for its answer: { id, frames, step, query, guild, name, answered }
local guildSeen -- one guild's players, found by its own search (Who.SearchGuild)
local owed      -- the id of a search given up that may still be answered (see Release)
local lastId = 0
local sending   -- true while we call SendWho ourselves
local hookedOn  -- the C_FriendList table our SendWho hook is on
local listeners = {}

-- fn(list, missing) after every answer: list = every Sylvanistas player of the round so far
-- ({ name, guild, level, class, zone }), missing = more may be online.
function Who.Listen(fn) listeners[#listeners + 1] = fn end

local function SetWhoToUi(on)
	if C_FriendList and C_FriendList.SetWhoToUi then C_FriendList.SetWhoToUi(on)
	elseif SetWhoToUI then SetWhoToUI(on and 1 or 0) end
end

local function Send(query)
	if C_FriendList and C_FriendList.SendWho then C_FriendList.SendWho(query) else SendWho(query) end
end

-- Values the client hides from addons (secret values) are treated as missing.
local function Plain(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

local function Counts()
	local shown, total
	if C_FriendList and C_FriendList.GetNumWhoResults then shown, total = C_FriendList.GetNumWhoResults()
	elseif GetNumWhoResults then shown, total = GetNumWhoResults() end
	shown = tonumber(Plain(shown)) or 0
	return shown, math.max(tonumber(Plain(total)) or shown, shown)
end

local function Info(i)
	if C_FriendList and C_FriendList.GetWhoInfo then
		local w = C_FriendList.GetWhoInfo(i)
		if type(w) == "table" then
			return Plain(w.fullName), Plain(w.fullGuildName), Plain(w.level), Plain(w.filename) or Plain(w.classStr), Plain(w.area)
		end
	elseif GetWhoInfo then
		local name, guild, level, _, class, zone, file = GetWhoInfo(i)
		return name, guild, level, file or class, zone
	end
end

local function MaxLevel()
	local max = GetMaxPlayerLevel and tonumber(GetMaxPlayerLevel())
	return (max and max >= 1) and math.floor(max) or 60
end

function Who.WindowOpen()
	for _, name in ipairs(WINDOWS) do
		local f = _G[name]
		if type(f) == "table" and f.IsVisible and f:IsVisible() then return true end
	end
	return false
end

-- Every listener that is registered stops listening; the ones that did are returned.
local function Quiet()
	local frames, names = {}, {}
	for _, entry in ipairs(LISTENERS) do
		local f = entry[2]()
		if type(f) == "table" and f.IsEventRegistered and f:IsEventRegistered(EVENT) then
			f:UnregisterEvent(EVENT)
			frames[#frames + 1] = f
			names[#names + 1] = entry[1]
		end
	end
	return frames, names
end

-- Results back to chat (Blizzard's default), unless the player has opened a who window.
local function ToChat()
	owed = nil
	if not Who.WindowOpen() then SetWhoToUi(false) end
end

-- Gives the event back to exactly the frames we took it from, and results back to chat.
-- `late`: the search is given up before its answer (none by TIMEOUT, someone else searched),
-- which may still come. Until it does (OnAnswer), or LATE seconds, results keep going to the
-- UI: there the event only updates the lists of the Classic clients' Social window, where
-- Blizzard's default for a long answer opens its Who tab (ShowWhoPanel).
local function Release(why, late)
	local p = pending
	if not p then return end
	pending = nil
	for _, f in ipairs(p.frames) do
		if not f:IsEventRegistered(EVENT) then f:RegisterEvent(EVENT) end
	end
	if late then
		owed = p.id
		ns.After(Who.LATE, "who late", function() if owed == p.id then ToChat() end end)
	else
		ToChat()
	end
	ns.Log("who: %s, event back to %d frame(s)%s", why, #p.frames, late and ", to chat after its answer" or "")
end

-- Someone else searching while ours waits (the player's /who, another addon): the answer
-- that comes may be theirs, so the who windows get their event back at once and ours is
-- given up (the next click repeats it). Once ours was given up, theirs gets Blizzard's
-- default: an answer of ours that late is not coming.
local function HookSendWho()
	if hookedOn == C_FriendList or not (hooksecurefunc and C_FriendList and C_FriendList.SendWho) then return end
	hookedOn = C_FriendList
	hooksecurefunc(C_FriendList, "SendWho", function()
		if sending then return end
		if pending then
			ns.SafeCall("who: another search", Release, "another search sent", true)
		elseif owed then
			ns.SafeCall("who: another search", ToChat)
		end
	end)
end

-- Level ranges covering 1 to maxLevel, cut where the levels seen in the capped answer split
-- evenly (each range about the same share of the players), so a young realm (everyone
-- 1-20 on a level 60 server) is not searched in empty ranges. No cut is made at the top
-- level, so a crowd there gets a range of its own; without enough levels seen, even ranges.
function Who.Brackets(levels, maxLevel, n)
	maxLevel = math.max(1, math.floor(maxLevel or 60))
	n = math.min(n or Who.BRACKETS, maxLevel)
	local seen = {}
	for _, l in ipairs(levels or {}) do
		l = tonumber(l)
		if l and l >= 1 then seen[#seen + 1] = math.min(math.floor(l), maxLevel) end
	end
	table.sort(seen)
	local cuts = {}
	for k = 1, n - 1 do
		local cut
		if #seen >= n then cut = seen[math.floor(k * #seen / n)] else cut = math.floor(k * maxLevel / n) end
		cut = math.min(cut, maxLevel - 1)
		if cut >= 1 and cut > (cuts[#cuts] or 0) then cuts[#cuts + 1] = cut end
	end
	local out, lo = {}, 1
	for _, cut in ipairs(cuts) do
		out[#out + 1] = { lo, cut }
		lo = cut + 1
	end
	out[#out + 1] = { lo, maxLevel }
	return out
end

local function Range(b) return b[1] == b[2] and tostring(b[1]) or (b[1] .. "-" .. b[2]) end

-- Seconds until the next search may go (0 = now): COOLDOWN after ours or a SendPlain.
local function Wait(now, last)
	if last <= 0 then return 0 end
	return math.max(0, Who.COOLDOWN - (now - last))
end

local function SendToUi(query)
	SetWhoToUi(true)
	Send(query)
end

-- Must be called from a click. Returns true if a search was sent. `quiet`: nothing printed.
-- `guild`: that one guild only (g-"<guild>", Who.SearchGuild): its players are kept apart
-- (Who.GuildSeen) and the round goes on where it was. `name`: that one player (n-"<name>",
-- Who.WantName), for the guild it shows (Who.SeenGuild); the round goes on where it was too.
-- With the gamepad UI only the player's own searches go, plainly (see the top of this file):
-- the round's, and one guild's his click asked for (Who.SearchGuild with `own`); never a name.
local toldPlain = false
function Who.Search(quiet, guild, name)
	local plain = ns.GamepadUI()
	if plain and (quiet or name) then return false end
	local now = GetTime()
	local wait = Wait(now, math.max(Who.lastSend, Who.lastPlain))
	if wait > 0 then
		if not quiet then ns.Print(L.WHO_WAIT:format(math.ceil(wait))) end
		return false
	end
	-- (Not in the gamepad UI's plain searches: their answer is meant for the open list.)
	if not plain and Who.WindowOpen() then
		if not quiet then ns.Print(L.WHO_WINDOW_OPEN) end
		return false
	end
	Release("new search") -- still settling from the last one
	-- A round left unfinished for ROUND_TTL is forgotten: a level range's answer added to
	-- the players it found back then would count them as online now.
	local old = sweep.started and now - sweep.started > Who.ROUND_TTL
	if not sweep.done and old then NewSweep() end
	-- The round done: the misspelled names next (VARIANTS), then it starts over.
	local own = guild or name -- one guild's or one player's search: the round stays where it is
	local variant = not own and sweep.done and not old and sweep.variant < #Who.VARIANTS and sweep.variant + 1 or nil
	if sweep.done and not own and not variant then sweep.step = 0 end
	-- A level range is a plain "lo-hi" in the filter, like the Who window's default search.
	local b = not own and not variant and sweep.step > 0 and sweep.brackets[sweep.step]
	local query = guild and ('g-"%s"'):format(guild) or name and ('n-"%s"'):format(ns.TellName(name))
		or variant and ('g-"%s"'):format(Who.VARIANTS[variant]) or b and ("%s %d-%d"):format(Who.QUERY, b[1], b[2]) or Who.QUERY
	local frames, names = {}, {}
	if not plain then
		HookSendWho()
		frames, names = Quiet()
	end
	lastId = lastId + 1
	local id = lastId
	pending = { id = id, frames = frames, step = sweep.step, query = query, guild = guild, name = name, variant = variant }
	owed = nil -- a search given up before this one: its answer would now pass for this one's
	Who.lastSend = now
	-- Scheduled first: whatever fails from here on, the who windows get their event back.
	ns.After(Who.TIMEOUT, "who timeout", function()
		if pending and pending.id == id and not pending.answered then Release("no answer", true) end
	end)
	sending = true
	local ok, err = pcall(SendToUi, query)
	sending = false
	if not ok then
		Release("send failed")
		error(err, 0)
	end
	if not quiet then ns.Print(L.RECRUIT_SEARCHING) end
	if plain and not toldPlain then
		toldPlain = true
		ns.Print(L.WHO_GAMEPAD)
	end
	ns.Log("who: sent %s%s, quiet: %s", query, quiet and " (auto)" or "",
		plain and "nothing (gamepad UI)" or (#names > 0 and table.concat(names, ", ") or "none"))
	return true
end

-- The search nobody has to ask for, from any click in our window: the next search of the
-- round once COOLDOWN allows, so the census (and the Join screen) fill on their own, one
-- level range per click past the cap. Quiet, and nothing is sent while a search waits for
-- its answer, while a who window is open, or while the last complete round is younger than
-- AUTO_AGAIN. Must be called from a click, like Search. Returns true if a search was sent.
-- One guild's players online, when its row is opened in the Realm tab (Views.lua): a click,
-- quiet, at most once a minute per guild. Up to 50 of them, whatever the round's cap. Kept
-- ROUND_TTL, like a round.
Who.GUILD_AGAIN = 60
local guildSearched = {}
local wantedGuild -- a guild opened while a search could not go: the next click sends it
guildSeen = {} -- [guild] = { t, list = { players }, capped }

-- The players of `guild` its own search found, while fresh: list, capped (nil when none).
function Who.GuildSeen(guild)
	local e = guildSeen[guild]
	if not e or GetTime() - e.t > Who.ROUND_TTL then return nil end
	return e.list, e.capped
end
-- `own`: the player's click asked for this very guild (the King's key rotation, Keys.Confirm).
-- Quiet with mouse and keyboard, as ever. With the gamepad UI only that one goes, plainly, as
-- Refresh does there: the answer in the game's who list, nothing silenced, read from there
-- (Who.OnSaw), its wait said.
function Who.SearchGuild(guild, own)
	if type(guild) ~= "string" or guild == "" or guild:find('"', 1, true) then return false end
	local plain = ns.GamepadUI()
	if plain and not own then return false end -- quiet: not with the gamepad UI (see the top)
	if not ((C_FriendList and C_FriendList.SendWho) or SendWho) then return false end
	local now = GetTime()
	if now - (guildSearched[guild] or -math.huge) < Who.GUILD_AGAIN then return false end
	if plain then
		-- (Nothing kept for a later click: no search goes on its own there.)
		local sent = Who.Search(false, guild)
		if sent then guildSearched[guild] = now end
		return sent
	end
	if pending or Wait(now, math.max(Who.lastSend, Who.lastPlain)) > 0 or Who.WindowOpen() then
		wantedGuild = guild
		return false
	end
	local sent = Who.Search(true, guild)
	if sent then guildSearched[guild], wantedGuild = now, nil end
	return sent
end

-- Sylvanistas Link (0.9.10, Link.lua): a High Councillor's addon that could only sign a player's
-- guild as claimed asks here for that player's /who. It goes quietly with a later click in our
-- window, like the rest of Auto, one name per click (never with the gamepad UI: no quiet search
-- goes there); its answer tells the confirmer the guild the next time that player asks.
Who.WANT_MAX = 5
local wantedNames = {}
function Who.WantName(name)
	if ns.GamepadUI() or type(name) ~= "string" or name == "" or name:find('"', 1, true) then return false end
	for _, n in ipairs(wantedNames) do
		if n == name then return true end
	end
	if #wantedNames >= Who.WANT_MAX then table.remove(wantedNames, 1) end
	wantedNames[#wantedNames + 1] = name
	return true
end
function Who.WantedNames() return wantedNames end

function Who.Auto()
	if not ((C_FriendList and C_FriendList.SendWho) or SendWho) then return false end
	if ns.GamepadUI() then return false end -- quiet: not with the gamepad UI (see the top)
	local now = GetTime()
	if pending or Wait(now, math.max(Who.lastSend, Who.lastPlain)) > 0 or Who.WindowOpen() then return false end
	-- A guild opened in the Realm tab while a search could not go comes first.
	if wantedGuild then
		local guild = wantedGuild
		wantedGuild = nil
		if Who.SearchGuild(guild) then return true end
	end
	-- Then a player Sylvanistas Link asked for.
	if wantedNames[1] then
		local name = table.remove(wantedNames, 1)
		if Who.Search(true, nil, name) then return true end
	end
	if sweep.done and sweep.variant >= #Who.VARIANTS and sweep.started and now - sweep.started < Who.AUTO_AGAIN then return false end
	if now - Who.lastAuto < Who.AUTO_GAP then return false end
	local sent = Who.Search(true)
	if sent then Who.lastAuto = now end
	return sent
end

-- A search of the player's own, the Who button of our person panel: nothing is silenced,
-- Blizzard shows the answer as always. Not within COOLDOWN of one of ours, whose answer
-- may still come (it would open Blizzard's who list), and ours wait COOLDOWN after it
-- (its answer is not ours). Must be called from a click. Returns true if it was sent.
function Who.SendPlain(query)
	local now = GetTime()
	local wait = Wait(now, Who.lastSend)
	if wait > 0 then
		ns.Print(L.WHO_WAIT:format(math.ceil(wait)))
		return false
	end
	Who.lastPlain = now
	Send(query)
	return true
end

-- The guild's name without a "-Realm" the server may add (fullGuildName). A realm whose census
-- we share names the same guild as its reports, so the suffix goes: kept, the guild would
-- show twice (its report and a grey row). Returns the name and the suffix, if any.
function Who.GuildName(guild)
	local base, realm = guild:match("^(.-)%-([^%-]+)$")
	if base and base ~= "" and ns.InGroup(realm) then return base, realm end
	return guild, realm
end

-- Everyone an answer of ours listed and the guild it showed ("" for none), with GetTime (0.9.10,
-- Sylvanistas Link: a confirmer's "w" is a /who of the requester in exactly the guild they claim, at
-- most 15 minutes old). [Name-Realm] = { guild, t }.
Who.SEEN_MAX = 2000
local seenAt, nSeen = {}, 0
-- fn(Name-Realm, guild) for each player an answer of ours lists, the guild as SeenGuild tells it
-- (1.1: the King's key rotation keeps what it depends on, Keys.Saw: this list starts empty after
-- a /reload, and is forgotten whole past SEEN_MAX names).
local sawListeners = {}
function Who.OnSaw(fn) sawListeners[#sawListeners + 1] = fn end
local function Saw(name, guild)
	local full = ns.FullName(name)
	if not seenAt[full] then
		if nSeen >= Who.SEEN_MAX then
			wipe(seenAt)
			nSeen = 0
		end
		nSeen = nSeen + 1
	end
	local e = { guild = type(guild) == "string" and guild ~= "" and Who.GuildName(guild) or "", t = GetTime() }
	seenAt[full] = e
	for _, fn in ipairs(sawListeners) do ns.SafeCall("who seen", fn, full, e.guild) end
end

-- The guild the last answer of ours that listed `name` showed ("" for none), and how many
-- seconds ago; nil when none did.
function Who.SeenGuild(name)
	local e = type(name) == "string" and seenAt[ns.FullName(name)]
	if not e then return nil end
	return e.guild, GetTime() - e.t
end

-- The answer's Sylvanistas players, each once.
local function Read()
	local shown, total = Counts()
	local rows, byName = {}, {}
	for i = 1, shown do
		local name, guild, level, class, zone = Info(i)
		if name and name ~= "" then Saw(name, guild) end
		if name and name ~= "" and not byName[name] and ns.IsFederation(guild) then
			local gname, gRealm = Who.GuildName(guild)
			local p = { name = name, guild = gname, guildRealm = gRealm, level = tonumber(level), class = class, zone = zone }
			byName[name] = p
			rows[#rows + 1] = p
		end
	end
	return rows, shown, total
end

local function Merge(rows)
	for _, p in ipairs(rows) do
		local known = sweep.byName[p.name]
		if known then
			for k, v in pairs(p) do known[k] = v end -- a newer level or zone
		else
			sweep.byName[p.name] = p
			sweep.list[#sweep.list + 1] = p
		end
	end
end

-- The first answer to a search moves the round on; the same answer announced again (another
-- addon sorting the list does that, and the server lists some players twice) is read again
-- and adds nobody twice. The who windows get the event back SETTLE later, so a repeat does
-- not open them either.
local function OnAnswer()
	local p = pending
	if not p then
		-- The answer to a search given up (or to the next one): results to chat again.
		if owed then
			ToChat()
			ns.Log("who: late answer, results to chat again")
		end
		return
	end
	local rows, shown, total = Read()
	local first = not p.answered
	if p.name then
		-- One player's search (Who.WantName): Read kept the guild it showed.
		if first then
			p.answered = true
			ns.After(Who.SETTLE, "who settle", function() if pending == p then Release("answered") end end)
			ns.Log("who: a name answered %d", shown)
		end
		return
	end
	if p.guild then
		-- One guild's search: kept apart, the round stays where it was.
		if first then
			p.answered = true
			ns.After(Who.SETTLE, "who settle", function() if pending == p then Release("answered") end end)
		end
		local list = {}
		for _, row in ipairs(rows) do
			if row.guild == p.guild then list[#list + 1] = row end
		end
		guildSeen[p.guild] = { t = GetTime(), list = list, capped = shown >= Who.MAX or total > shown }
		if first then ns.Log("who: %s answered %d of %d (%d in the guild)", p.query, shown, total, #list) end
		ns.Fire("DATA_CHANGED")
		return
	end
	if p.variant then
		-- A misspelled name's search: its players join the round, done as it was.
		if first then
			p.answered = true
			ns.After(Who.SETTLE, "who settle", function() if pending == p then Release("answered") end end)
			sweep.variant = math.max(sweep.variant, p.variant)
			ns.Log("who: %s answered %d (%d Sylvanistas)", p.query, shown, #rows)
		end
		Merge(rows)
		for _, fn in ipairs(listeners) do ns.SafeCall("who listener", fn, sweep.list, sweep.missing) end
		return
	end
	if first then
		p.answered = true
		ns.After(Who.SETTLE, "who settle", function() if pending == p then Release("answered") end end)
		local capped = shown >= Who.MAX or total > shown
		if p.step == 0 then
			-- The broad search starts the round over.
			NewSweep()
			sweep.shown, sweep.total, sweep.capped, sweep.started = shown, total, capped, GetTime()
			if capped then
				-- Up to the client's top level, or above it should anyone listed be (a cap
				-- that is this character's own, like a trial account's).
				local levels, top = {}, MaxLevel()
				for _, row in ipairs(rows) do
					if row.level then
						levels[#levels + 1] = row.level
						top = math.max(top, row.level)
					end
				end
				sweep.brackets = Who.Brackets(levels, top, Who.BRACKETS)
				sweep.step, sweep.missing = 1, true
			else
				sweep.done = true
			end
		else
			sweep.rangeCapped = sweep.rangeCapped or capped
			sweep.step = p.step + 1
			if sweep.step > #sweep.brackets then sweep.done, sweep.missing = true, sweep.rangeCapped end
		end
		sweep.answers = sweep.answers + 1
	end
	Merge(rows)
	if first then ns.Log("who: %s answered %d of %d (%d Sylvanistas), %d in the round", p.query, shown, total, #rows, #sweep.list) end
	for _, fn in ipairs(listeners) do ns.SafeCall("who listener", fn, sweep.list, sweep.missing) end
end
ns.RegisterEvent(EVENT, OnAnswer)

-- A /reload while our search waited leaves the client's who flag on (it outlives the UI):
-- the player's own /who would then open the list instead of answering in chat. Reset it once
-- at login, unless one of the player's who windows is open (it manages the flag itself).
ns.On("LOGIN", function()
	if not Who.WindowOpen() then pcall(SetWhoToUi, false) end
end)

function Who.Searched() return Who.lastSend > 0 end
function Who.IsPending() return pending ~= nil end

-- Forgets the round (and gives the event back if a search is still waiting).
function Who.Reset()
	Release("reset")
	NewSweep()
	wipe(guildSeen)
	wipe(guildSearched)
	wantedGuild = nil
	wipe(wantedNames)
	wipe(seenAt)
	nSeen = 0
end

-- One or two lines on how far the round got, for under a list; nil when there is nothing
-- to say (no answer yet, or everyone fit in one answer).
function Who.StatusLines()
	local s = sweep
	if s.answers == 0 or not s.capped then return nil end
	local found = #s.list
	if s.done then
		return { s.missing and L.WHO_DONE_CAPPED:format(found, Who.MAX) or L.WHO_DONE:format(found) }
	end
	local known = s.total > s.shown -- Forever reports no more than it lists
	local first
	if s.answers == 1 then
		first = known and L.WHO_SHOWN:format(s.shown, s.total) or L.WHO_SHOWN_CAP:format(s.shown)
	else
		first = known and L.WHO_SO_FAR:format(found, math.max(found, s.total)) or L.WHO_SO_FAR_CAP:format(found)
	end
	return { first, L.WHO_NEXT:format(Range(s.brackets[s.step]), s.step, #s.brackets) }
end

-- For /syl status (names raw): the players of the round by the realm on their name as the
-- server sent it ("bare" = none), how many guild names carried a realm, and one name as sent.
function Who.RawCounts()
	local names, guildSuffix, sample = {}, 0, nil
	for _, p in ipairs(sweep.list) do
		local realm = p.name:match("%-(.+)$")
		names[realm or "bare"] = (names[realm or "bare"] or 0) + 1
		if p.guildRealm then guildSuffix = guildSuffix + 1 end
		if not sample or (realm and not sample:find("-", 1, true)) then sample = p.name end
	end
	return names, guildSuffix, sample
end

-- For /syl status.
function Who.StatusLine()
	local s = sweep
	local step = s.brackets and ("%d/%d"):format(math.min(s.step, #s.brackets), #s.brackets) or "broad"
	-- (Not asked of Blizzard's frames with the gamepad UI: the question is a guarded one there.)
	local open, gamepad = {}, ns.GamepadUI()
	for _, entry in ipairs(gamepad and {} or LISTENERS) do
		local f = entry[2]()
		if type(f) == "table" and f.IsEventRegistered and f:IsEventRegistered(EVENT) then open[#open + 1] = entry[1] end
	end
	return ("round %s, %d found (answer %d of %d), done=%s missing=%s, pending=%s owed=%s, last %s  |  listening: %s"):format(
		step, #s.list, s.shown, s.total, tostring(s.done), tostring(s.missing), tostring(pending ~= nil), tostring(owed ~= nil),
		Who.lastSend > 0 and ("%ds ago"):format(math.floor(GetTime() - Who.lastSend)) or "never",
		gamepad and "not asked (gamepad UI)" or (#open > 0 and table.concat(open, ", ") or "none"))
end
