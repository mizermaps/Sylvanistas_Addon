local ADDON, ns = ...
local L = ns.L

-- A player's Sylvanistas version, from the game's right-click menu (1.1.2, the owner's ask): what this
-- client knows of it, and what to do about it. The menu's lines (PlayerMenu.lua):
--   * "Sylvanistas 1.1.1 (out of date)", "Sylvanistas 1.1.2 (up to date)", "Sylvanistas: not seen yet" or "no
--     answer": what is known, and under it where from and when (a line of its own: a gamepad
--     can't reach a menu line's tooltip). A guildmate's version comes from their hello
--     (Comm.PeerVersion, every guildmate's addon says it over GUILD), anyone's from their answer to
--     Check version below, and on the author's client from his roll calls' answers. Opening the
--     menu sends nothing.
--   * Ask to update, when they are behind the newest version this client knows (Latest: its own,
--     or the one the author's presence named as out; on his own client the one he marked as out,
--     /syl released; nothing a player sends raises it). The author's is his usual update window
--     (Workshop.AskUpdate, V3, which every version shows). Anyone else's is V9, which 1.1.2 and
--     newer show as a small notice with both versions and where to update: once a day at most,
--     never for 7 days after its "Don't remind me", never from a player they block (/syl block),
--     ignore or the moderators took off, and never naming a version the author has not released.
--     A player older than 1.1.2 can't show it: the click opens a whisper the player sends himself.
--     One ask per player a day, ASK_HOUR an hour at most (the author's too).
--   * Check version, when nothing is known (or what is known is old): one addon whisper (V7) that
--     their addon (1.1.2 and newer) answers with its version and nothing else (V8), answered for a
--     sender once per ANSWER_GAP, ANSWER_MAX a minute; kept CACHE_FOR. No answer within PING_WAIT
--     of its sending: "no answer" (no Sylvanistas, a version older than 1.1.2, a dungeon or raid, or
--     not in a Sylvanistas guild: outside one the addon sends nothing). The author's check is his roll
--     call to that player alone (Workshop.AskOne, V1: every version since 0.9.9 answers it, and
--     only after the player's yes to his roll calls), never a V7, and a V7 from him is not answered.
--   * Tell them about Sylvanistas, after no answer: Sylvanistas's own whisper window (UI.WhisperText) with
--     a short invite and the CurseForge link (to get it, or to update an old one), which the player
--     edits and sends himself. Nothing is sent by the click.
-- In a dungeon, a raid or a match the game holds addon messages (ns.ChatLocked): the lines that
-- send are greyed, and say why. A send the queue drops leaves nothing recorded (its done callback).
-- The author gets the checks' results (and his "Ask <name>" roll call answers) in a copy window,
-- not in chat: he may need to copy them (Versions.ShowResults). Opened by itself, it takes no
-- keyboard and waits out a fight.
--   V7~<id>                 check: what version do you run?        (whisper)
--   V8~<id>~<version>       the answer                             (whisper)
--   V9~<version>            "please update": the newest the sender knows  (whisper, not the author)

local Versions = {}
ns.Versions = Versions

Versions.PING_WAIT = 10          -- an answer this long after a check left, or "no answer"
Versions.PING_GAP = 120          -- the same player checked again at most this often
Versions.PING_MAX = 6            -- checks a minute at most, whoever they go to
Versions.CACHE_FOR = 30 * 60     -- a check's answer (or its silence) counts this long
Versions.HELLO_FRESH = 12 * 60   -- a hello this recent says the version they run now (Comm's COUNT_WINDOW)
Versions.ANSWER_GAP = 30         -- a sender's checks answered at most this often
Versions.ANSWER_MAX = 20         -- checks answered a minute at most, whoever asks
Versions.ASK_GAP = 24 * 3600     -- Ask to update: the same player once a day...
Versions.ASK_HOUR = 5            -- ...and this many players an hour at most
Versions.SHOWN_GAP = 24 * 3600   -- a player's ask shows here once a day at most
Versions.SNOOZE = 7 * 24 * 3600  -- "Don't remind me": no ask shows for this long
Versions.RESULTS_MAX = 40        -- lines in the author's results window
Versions.FIRST = "1.1.2"         -- the first version that answers V7 and shows V9 (older ones ignore both)

-- Swappable in tests.
Versions.random = math.random
Versions.after = function(seconds, where, fn) ns.After(seconds, where, fn) end

local checks = {}        -- [folded short name] = { name, id, t (asked), sent (left), roll (the author's), version (the answer) or false (none), at }
local sentTimes = {}     -- our checks this last minute
local answeredAt = {}    -- [sender] = when we last answered their check
local answerTimes = {}   -- our answers this last minute

local function W() return ns.Workshop end
local function Newer(a, b) return W().Newer(a, b) == true end
local function Full(name) return ns.FullName(ns.Normal(tostring(name or ""))) end
local function IsAuthor() local w = W() return w.IsAuthor ~= nil and w.IsAuthor() == true end
-- Checks are kept by the short name, folded: the menu may give the name without its realm while
-- the server stamps the answer with it (Forever's names are one across a realm group).
local function Key(name) return ns.Fold(ns.ShortName(Full(name)) or "") end
local function Recent(list, span, now)
	for i = #list, 1, -1 do if now - list[i] > span then table.remove(list, i) end end
	return #list
end

-- Blocked (/syl block, Comm drops them already) or on the game's ignore list.
local function Ignored(sender)
	if ns.db and ns.db.blocked and ns.db.blocked[tostring(sender):lower()] then return true end
	local api = C_FriendList and C_FriendList.IsIgnored
	if not api then return false end
	local ok, res = pcall(api, ns.DisplayName(sender))
	return ok and res == true
end
Versions.Ignored = Ignored

-- The newest version this client knows is out: on the author's client the one he marked as out
-- (/syl released), else the build he runs (never a preview he has not published once he marks
-- one); anyone else's own, or the release the author's presence named when newer.
function Versions.Latest()
	local w = W()
	if IsAuthor() then return (w.Released and w.Released()) or ns.VERSION end
	local v = ns.VERSION
	local heard = w.AuthorVersion and w.AuthorVersion()
	if type(heard) == "string" and Newer(heard, v) then v = heard end
	return v
end

---------------------------------------------------------------------------
-- What is known of a player
---------------------------------------------------------------------------

-- The author's roll call answer of `name` (by the whole name, else by the short name folded).
local function RollAnswer(name)
	local roll = W().State and W().State()
	local answers = roll and roll.answers
	if type(answers) ~= "table" then return nil end
	local a = answers[Full(name)]
	if a then return a end
	local key, best = Key(name), nil
	for n, x in pairs(answers) do
		local short = type(x.foldedFull) == "string" and (x.foldedFull:match("^(.-)%-[^%-]*$") or x.foldedFull) or Key(n)
		if short == key and (not best or (x.t or 0) > (best.t or 0)) then best = x end
	end
	return best
end

-- `name`'s Sylvanistas as this client knows it: state, version, how ("hello", "check", "roll") and when.
-- States: "current" (the newest this client knows, or newer: "newer"), "outdated", "sylvanistas" (runs
-- it, the version unreadable), "checking" (a check waits for its answer), "none" (a check got no
-- answer, lately), "unknown" (nothing heard).
function Versions.Status(name)
	local now = ns.Now()
	local version, how, at
	local function Take(v, h, t)
		if type(v) == "string" and v ~= "" and t and (not at or t > at) then version, how, at = v, h, t end
	end
	if ns.Comm.PeerVersion then
		local hv, hat = ns.Comm.PeerVersion(name)
		Take(hv, "hello", hat)
	end
	local c = checks[Key(name)]
	if c and c.version then Take(c.version, c.roll and "roll" or "check", c.at) end
	local a = RollAnswer(name)
	if a then Take(a.version, "roll", a.t) end
	if version then
		if not version:match("^%d+%.%d+%.%d+$") then return "sylvanistas", nil, how, at end
		local latest = Versions.Latest()
		if Newer(latest, version) then return "outdated", version, how, at end
		if Newer(version, latest) then return "newer", version, how, at end
		return "current", version, how, at
	end
	-- (A check whose sending never ended, a message the client held: nothing known after PING_GAP.)
	if c and c.version == nil and now - c.t < Versions.PING_GAP then return "checking", nil, "check", c.t end
	if c and c.version == false and now - c.at < Versions.CACHE_FOR then return "none", nil, "check", c.at end
	return "unknown"
end

-- What is known is old (a hello or answer older than HELLO_FRESH / CACHE_FOR): worth checking again.
local function Stale(how, at)
	if not at then return true end
	local age = ns.Now() - at
	if how == "hello" then return age > Versions.HELLO_FRESH end
	return age > Versions.CACHE_FOR
end

-- The line naming it, as the menu and the person card show it.
function Versions.Line(state, version)
	if state == "current" then return L.VERSION_LINE_CURRENT:format(version) end
	if state == "newer" then return L.VERSION_LINE_NEWER:format(version) end
	if state == "outdated" then return L.VERSION_LINE_OUTDATED:format(version) end
	if state == "sylvanistas" then return L.VERSION_LINE_SYLVANISTAS end
	if state == "checking" then return L.VERSION_LINE_CHECKING end
	if state == "none" then return L.VERSION_LINE_NONE end
	return L.VERSION_LINE_UNKNOWN
end

-- Where it came from and when, for a tooltip.
local function Source(how, at)
	if not at then return L.VERSION_SOURCE_NONE end
	local key = how == "hello" and "VERSION_SOURCE_HELLO" or (how == "roll" and "VERSION_SOURCE_ROLL" or "VERSION_SOURCE_CHECK")
	return L[key]:format(ns.Ago(at))
end

-- The same, short, for the menu's line under the version (the gamepad can't open a line's tooltip).
function Versions.Detail(state, how, at)
	if not at or state == "checking" then return nil end
	local key = how == "hello" and "VERSION_DETAIL_HELLO" or (how == "roll" and "VERSION_DETAIL_ROLL" or "VERSION_DETAIL_CHECK")
	local text = L[key]:format(ns.Ago(at))
	if state == "outdated" then text = text .. "; " .. L.VERSION_DETAIL_NEWEST:format(Versions.Latest()) end
	return text
end

-- The person card's line (UI.ShowPerson), or nil when nothing is known.
function Versions.CardLine(name)
	local state, version = Versions.Status(name)
	if state == "unknown" then return nil end
	return Versions.Line(state, version)
end

---------------------------------------------------------------------------
-- Check version (V7, V8; the author's: his roll call to one player, V1)
---------------------------------------------------------------------------

local function Report(c) Versions.Result(c) end

-- PING_WAIT after the check left: its answer, or "no answer".
local function NoAnswer(key, e)
	if checks[key] ~= e or e.version ~= nil then return end
	if e.roll then
		-- (His roll call's answer is kept by the Workshop, and showed its window as it came.)
		local a = RollAnswer(e.name)
		if a and (a.t or 0) >= e.t then
			e.version, e.at = a.version, a.t
			return
		end
	end
	e.version, e.at = false, ns.Now()
	Report(e)
end

function Versions.Check(name)
	local full = Full(name)
	if full == "" then return false end
	if ns.ChatLocked() then
		ns.Print(L.VERSION_LOCKED)
		return false
	end
	local key, now = Key(full), ns.Now()
	local c = checks[key]
	if c and now - c.t < Versions.PING_GAP then
		ns.Print(L.VERSION_CHECK_WAIT:format(ns.DisplayName(full), math.max(1, math.ceil(Versions.PING_GAP - (now - c.t)))))
		return false
	end
	if Recent(sentTimes, 60, now) >= Versions.PING_MAX then
		ns.Print(L.VERSION_CHECK_BUSY)
		return false
	end
	local e = { name = full, id = Versions.random(1, 99999), t = now }
	-- The wait for the answer starts once the check left (a busy queue holds it a while); dropped
	-- before it left, nothing is recorded, and the player is told.
	local function Sent(sent)
		if checks[key] ~= e then return end
		if not sent then
			checks[key] = nil
			ns.Print(L.VERSION_NOT_SENT:format(ns.DisplayName(full)))
			return
		end
		e.sent = ns.Now()
		Versions.after(Versions.PING_WAIT, "version check", function() NoAnswer(key, e) end)
	end
	checks[key] = e
	if IsAuthor() then
		-- The author: his roll call to this player alone, answered only after their yes (Fern's #11).
		e.roll = true
		if not W().AskOne(full, Sent) then
			if checks[key] == e then checks[key] = nil end
			return false
		end
	else
		-- (Urgent: the player waits for it; a busy queue would make it look unanswered.)
		ns.Comm.Whisper(full, ("V7~%d"):format(e.id), "vcheck:" .. key, true, nil, Sent)
	end
	sentTimes[#sentTimes + 1] = now
	return true
end

-- Their check: our version, and nothing else, to them alone. Never the author's: his are roll calls
-- (V1), answered only after this player's yes; a V7 from his name gets nothing without it.
function Versions.HandlePing(dist, sender, text)
	if dist ~= "WHISPER" then return end
	local id = tostring(text or ""):match("^V7~(%d+)$")
	if not id or #id > 6 or Ignored(sender) then return end
	local w = W()
	if w.IsAuthorName and w.IsAuthorName(sender) and not (w.Answers and w.Answers()) then return end
	local now = ns.Now()
	if now - (answeredAt[sender] or -math.huge) < Versions.ANSWER_GAP then return end
	if Recent(answerTimes, 60, now) >= Versions.ANSWER_MAX then return end
	-- (The table stays small: a sender forgotten once its gap is over.)
	for who, t in pairs(answeredAt) do if now - t >= Versions.ANSWER_GAP then answeredAt[who] = nil end end
	answeredAt[sender] = now
	answerTimes[#answerTimes + 1] = now
	ns.Comm.Whisper(sender, ("V8~%s~%s"):format(id, ns.VERSION), "vanswer:" .. sender, true)
end

-- Their answer to our check (the id we sent; late, it still counts).
function Versions.HandleAnswer(dist, sender, text)
	if dist ~= "WHISPER" then return end
	local id, v = tostring(text or ""):match("^V8~(%d+)~(%d+%.%d+%.%d+)$")
	if not id or #v > 12 then return end
	local c = checks[Key(sender)]
	if not c or c.roll or tostring(c.id) ~= id or c.version then return end
	c.version, c.at = v, ns.Now()
	Report(c)
end

---------------------------------------------------------------------------
-- Results: the author's in a copy window, anyone else's in one line of chat
---------------------------------------------------------------------------

local function ResultLine(name)
	local state, version, how, at = Versions.Status(name)
	return ("%s  %s  (%s)"):format(ns.DisplayName(name), Versions.Line(state, version), Source(how, at))
end

-- Every check this session and the author's players asked alone, newest first.
function Versions.ResultsText()
	local list = {}
	for _, c in pairs(checks) do list[#list + 1] = { name = c.name, t = c.at or c.t } end
	local roll = W().State and W().State()
	for name, a in pairs(roll and roll.answers or {}) do
		if a.alone then list[#list + 1] = { name = name, t = a.t } end
	end
	table.sort(list, function(a, b)
		if a.t ~= b.t then return a.t > b.t end
		return a.name < b.name
	end)
	local out, seen = { L.VERSION_RESULTS_HEAD:format(Versions.Latest()), "" }, {}
	for _, e in ipairs(list) do
		local k = Key(e.name)
		if not seen[k] and #out < Versions.RESULTS_MAX + 2 then
			seen[k] = true
			out[#out + 1] = ResultLine(e.name)
		end
	end
	if #out == 2 then out[#out + 1] = L.VERSION_RESULTS_NONE end
	return table.concat(out, "\n")
end

-- auto: opened by an answer or its timer, not by a click: no keyboard taken (UI.ShowCopy's auto),
-- and after the fight when in one. The text is read when it shows (the answers in by then).
function Versions.ShowResults(auto)
	local UI = ns.UI
	if not (UI and UI.ShowCopy) then return false end
	local function Show()
		UI.ShowCopy(L.VERSION_RESULTS_TITLE, Versions.ResultsText(), nil, { key = "versions", auto = auto and true or nil })
	end
	if auto then ns.OutOfCombat("version results", Show) else Show() end
	return true
end

-- A check answered, or not: the author's window (he may copy it), else one line.
function Versions.Result(c)
	if IsAuthor() then return Versions.ShowResults(true) end
	local state, version = Versions.Status(c.name)
	local who = ns.DisplayName(c.name)
	if state == "none" then
		ns.Print(L.VERSION_RESULT_NONE:format(who))
	else
		ns.Print(("%s: %s"):format(who, Versions.Line(state, version)))
	end
	return true
end

---------------------------------------------------------------------------
-- Ask to update (V9; the author's: V3; before 1.1.2: a whisper the player sends)
---------------------------------------------------------------------------

-- A player older than 1.1.2 (their addon ignores V9): Sylvanistas's whisper window with a short ask,
-- which the player edits and sends himself. Nothing counted, nothing sent by the click.
function Versions.AskWhisper(name, version)
	local UI = ns.UI
	if not (UI and UI.WhisperText) then return nil end
	local link = UI.LINKS and UI.LINKS.curseforge or "https://www.curseforge.com/wow/addons/CHANGEME-sylvanistas"
	return UI.WhisperText(ns.TellName(Full(name)), L.VERSION_ASK_WHISPER:format(tostring(version or "?"), Versions.Latest(), link))
end

function Versions.AskUpdate(name)
	local full = Full(name)
	if ns.ChatLocked() then
		ns.Print(L.VERSION_LOCKED)
		return false
	end
	local state, version = Versions.Status(full)
	if state ~= "outdated" then return false end
	local author = IsAuthor()
	if not author and Newer(Versions.FIRST, version) then return Versions.AskWhisper(full, version) ~= nil end
	-- (A player the moderators took off sends no ask: every receiver drops it, 1.1.2's review.)
	local M = ns.Moderation
	local off = M and not M.missing and type(M.SelfOff) == "function" and M.SelfOff() or nil
	if off then
		if type(M.YouText) == "function" then ns.Print(M.YouText(off)) end
		return false
	end
	local now, key = ns.Now(), Key(full)
	ns.db.updateAsked = type(ns.db.updateAsked) == "table" and ns.db.updateAsked or {}
	ns.db.updateAskTimes = type(ns.db.updateAskTimes) == "table" and ns.db.updateAskTimes or {}
	local asked, times = ns.db.updateAsked, ns.db.updateAskTimes
	for k, t in pairs(asked) do if type(t) ~= "number" or now - t >= Versions.ASK_GAP then asked[k] = nil end end
	if asked[key] then
		ns.Print(L.VERSION_ASK_WAIT_ONE:format(ns.DisplayName(full)))
		return false
	end
	if Recent(times, 3600, now) >= Versions.ASK_HOUR then
		ns.Print(L.VERSION_ASK_WAIT_HOUR:format(Versions.ASK_HOUR))
		return false
	end
	asked[key] = now
	table.insert(times, now)
	local function Undo()
		if asked[key] == now then asked[key] = nil end
		for i = #times, 1, -1 do
			if times[i] == now then
				table.remove(times, i)
				break
			end
		end
	end
	-- Told once it left; dropped before, the day's slot and the hour's come back.
	local function Sent(sent)
		if sent then
			ns.Print(L.VERSION_ASKED:format(ns.DisplayName(full)))
		else
			Undo()
			ns.Print(L.VERSION_NOT_SENT:format(ns.DisplayName(full)))
		end
	end
	local latest = Versions.Latest()
	if author then
		-- His usual update window (V3), naming the version he marked as out; the Workshop's own
		-- 10 minutes per player hold it too.
		if not W().AskUpdate(full, latest, Sent) then
			Undo()
			ns.Print(L.VERSION_ASK_WAIT_ONE:format(ns.DisplayName(full)))
			return false
		end
		return true
	end
	ns.Comm.Whisper(full, "V9~" .. latest, "vask:" .. key, nil, nil, Sent)
	return true
end

-- A player asks us to update: a small notice (held in an instance or while Busy), once a day at
-- most, never while "Don't remind me" holds, only when really behind the version they name, and
-- never naming one the author has not released: with his released version heard, a newer number
-- is his, and being on it (or newer) is being up to date; without it, no number of theirs is shown.
function Versions.HandleAsk(dist, sender, text)
	if dist ~= "WHISPER" then return end
	local latest = tostring(text or ""):match("^V9~(%d+%.%d+%.%d+)$")
	if not latest or #latest > 12 or not Newer(latest, ns.VERSION) or Ignored(sender) then return end
	local M = ns.Moderation
	if M and not M.missing and type(M.Hides) == "function" and M.Hides(sender) then return end
	local w = W()
	local heard = w.AuthorVersion and w.AuthorVersion()
	local named
	if type(heard) == "string" then
		if not Newer(heard, ns.VERSION) then return end
		named = Newer(latest, heard) and heard or latest
	end
	local now = ns.Now()
	if (tonumber(ns.db.updateAskSnooze) or 0) > now then return end
	if now - (tonumber(ns.db.updateAskShown) or -math.huge) < Versions.SHOWN_GAP then return end
	ns.db.updateAskShown = now
	local who = ns.DisplayName(ns.FullName(sender))
	local notice = named and L.VERSION_NOTICE:format(who, ns.VERSION, named) or L.VERSION_NOTICE_ANY:format(who, ns.VERSION)
	-- (A window any player can make appear: after a fight too, as the author's windows.)
	ns.Alert("update", "soft", { what = L.HELD_UPDATE_ASK:format(who), key = "updateask",
		show = function() ns.OutOfCombat("update ask", function() Versions.ShowNotice(notice) end) end })
end

-- Sylvanistas's own window, in both input modes: any Sylvanistas player can make it appear, so never the
-- game's popup (whose Escape would also press "Don't remind me": StaticPopup_CallEscapeHandler calls
-- OnCancel with "clicked"). Answered by a click alone.
function Versions.ShowNotice(notice)
	if ns.Dialog.missing then
		ns.Print(notice)
		return nil
	end
	return ns.Dialog.Show("SYLVANISTAS_UPDATE_ASKED", notice)
end

function Versions.Snooze()
	ns.db.updateAskSnooze = ns.Now() + Versions.SNOOZE
	ns.Print(L.VERSION_SNOOZED)
end

StaticPopupDialogs["SYLVANISTAS_UPDATE_ASKED"] = {
	text = "%s",
	button1 = OKAY or "OK",
	button2 = L.VERSION_SNOOZE,
	OnCancel = function(_, _, reason)
		if reason == "clicked" then ns.SafeCall("update ask snooze", Versions.Snooze) end
	end,
	noCancelOnEscape = true, -- (were it ever the game's popup: Escape only closes it)
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Tell them about Sylvanistas: a whisper the player sends himself
---------------------------------------------------------------------------

function Versions.InviteText()
	local link = ns.UI and ns.UI.LINKS and ns.UI.LINKS.curseforge or "https://www.curseforge.com/wow/addons/CHANGEME-sylvanistas"
	return L.VERSION_INVITE_TEXT:format(link)
end

function Versions.Tell(name)
	local UI = ns.UI
	if not (UI and UI.WhisperText) then return nil end
	return UI.WhisperText(ns.TellName(Full(name)), Versions.InviteText())
end

---------------------------------------------------------------------------
-- The menu's lines (PlayerMenu.lua)
---------------------------------------------------------------------------

function Versions.MenuLines(target, menu)
	local name = target.name
	local state, version, how, at = Versions.Status(name)
	local tip = Source(how, at)
	if state == "outdated" then tip = tip .. "\n" .. L.VERSION_BEHIND_TIP:format(Versions.Latest()) end
	menu.Line(Versions.Line(state, version), L.PLAYERMENU_VERSION, tip)
	local detail = Versions.Detail(state, how, at)
	if detail then menu.Line("|cff9d9d9d" .. detail .. "|r") end
	-- In a dungeon, a raid or a match nothing can go: the lines show, greyed, and say why.
	local locked = target.locked == true
	local function Tip(text) return locked and L.PLAYERMENU_LOCKED or text end
	if state == "outdated" then
		local tipText = IsAuthor() and L.VERSION_ASK_AUTHOR_TIP or L.VERSION_ASK_TIP
		if not IsAuthor() and Newer(Versions.FIRST, version) then tipText = L.VERSION_ASK_OLD_TIP:format(version) end
		menu.Button(L.VERSION_ASK, function() Versions.AskUpdate(name) end, L.VERSION_ASK, Tip(tipText), not locked)
	end
	local c = checks[Key(name)]
	local recheck = not c or ns.Now() - c.t >= Versions.PING_GAP
	if state == "unknown" or ((state == "none" or state == "sylvanistas" or Stale(how, at)) and state ~= "checking" and recheck) then
		menu.Button(L.VERSION_CHECK, function() Versions.Check(name) end, L.VERSION_CHECK,
			Tip(IsAuthor() and L.VERSION_CHECK_AUTHOR_TIP or L.VERSION_CHECK_TIP), not locked)
	end
	if state == "none" then
		menu.Button(L.VERSION_TELL, function() Versions.Tell(name) end, L.VERSION_TELL, Tip(L.VERSION_TELL_TIP), not locked)
	end
end

-- Does `name` run Sylvanistas, as far as this client knows (the author's Ask for a bug report)?
function Versions.HasSylvanistas(name)
	local state = Versions.Status(name)
	return state == "current" or state == "outdated" or state == "newer" or state == "sylvanistas"
end

function Versions.StatusLine()
	local n, none = 0, 0
	for _, c in pairs(checks) do
		n = n + 1
		if c.version == false then none = none + 1 end
	end
	return ("checks this session %d (no answer %d), asks to update today %d, notice %s"):format(n, none,
		type(ns.db.updateAsked) == "table" and (function() local k = 0 for _ in pairs(ns.db.updateAsked) do k = k + 1 end return k end)() or 0,
		(tonumber(ns.db.updateAskSnooze) or 0) > ns.Now() and "snoozed" or "on")
end

function Versions.Reset() -- (tests)
	wipe(checks); wipe(sentTimes); wipe(answeredAt); wipe(answerTimes)
end

ns.PlayerMenu.Add("versions", function(target, menu) Versions.MenuLines(target, menu) end, 10)
ns.Comm.Handle("V7", function(...) Versions.HandlePing(...) end)
ns.Comm.Handle("V8", function(...) Versions.HandleAnswer(...) end)
ns.Comm.Handle("V9", function(...) Versions.HandleAsk(...) end)
