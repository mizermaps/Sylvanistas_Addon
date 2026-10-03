local ADDON, ns = ...
local L = ns.L

-- The King's week (1.1, request #26): the King's Agenda holds dated entries for the next 7 days
-- beside its one current event, and the Board shows them as a week, by day, with the player's
-- own guild's events from the game's calendar among them: raid night, PvP night and court on one
-- page, so nobody books the army twice. The King, his Steward and his Hands set an entry with
-- the Agenda button, a day and an hour then what ("Sat 20:00 Raid night"); their client repeats
-- it for late logins, the way it repeats the Agenda. Every client keeps the week it heard across
-- a /reload or a login (its setter may be offline), until each entry is over or taken off.
--   T1~D~<id>~<guild>~<seconds>~<fresh>~<zone>~<title>   an entry, <seconds> from now (1 minute
--       to 7 days); fresh 1 on its first sending (a chat line where it arrives), 0 on repeats;
--       seconds 0: taken off the week (by its setter, the King, his Steward or a Hand)
-- Sylvanistas can't write into the game's calendar: C_Calendar.AddEvent is the game's alone
-- (HasRestrictions). An officer's click on an entry opens the game's calendar (its own opener,
-- as the minimap clock's) and says which day to pick: he creates the guild event there, with
-- the game's own button. With the gamepad UI, or in combat, it only says how to open it.
-- Clients before 1.1 leave the kind D out (King.HandleCommand), as any kind they don't know.
-- A setter or a signer the moderators took off (net-off, Moderation.lua; 1.1, review)
-- shows nowhere: every client drops their D, R and Y2 and hides what it heard of them before,
-- and their own client sends none, but a setter taking his own entry down: that cancel still
-- goes, and every client takes it for his own entry alone (1.1 review: it was held, and the
-- entry showed again everywhere once he was shown again).

local Week = {}
ns.Week = Week

Week.MAX_AHEAD = 7 * 86400   -- an entry is at most a week ahead
Week.MIN_AHEAD = 60
Week.MAX_MINE = 10           -- entries the King or his Steward holds
Week.MAX_HAND = 5            -- entries a Hand holds
Week.MAX_KEPT = 30           -- entries kept here in all: the King's and his Steward's always find a place
Week.RESEND = 600            -- the setter's client repeats each entry this often...
Week.RESEND_FAR = 1800       -- ...and this often while it is more than FAR away
Week.FAR = 86400
Week.RESEND_PER_TICK = 2     -- ...two at most a minute
Week.STALE = 2 * Week.RESEND_FAR + 300 -- its setter heard this long without it: taken off (a cancel missed)
Week.SET_GAP = 10            -- seconds between two new entries of one setter
Week.KEEP_AFTER = 3600       -- an entry stays on the week this long after it began
Week.GUILD_EVENTS = 10       -- the guild's calendar events shown at most
Week.CALENDAR_ASK = 300      -- the game's calendar asked for its data this often at most
Week.NEW_LINE_GAP = 30       -- a chat line for a new entry at most this often

-- The King's tools that lend the week (King.lua): the King's own; his Steward's and his Hands'.
ns.King.HAND_MAY.D = true
ns.King.STEWARD_MAY.D = true

local entries = {}           -- [id] = { id, title, zone, at, by, mine, crown (the King's or his Steward's), sentAt, heardAt,
                             --   setterGuild (the guild his messages named, for the net-off: kept with it) }
local heardFrom = {}         -- [setter] = { first, last }: when we heard him, this stretch online
local lastSet, lastNewLine, lastCalendarAsk = -math.huge, -math.huge, -math.huge

local function Gold(s) return "|cffffd200" .. s .. "|r" end
local function Grey(s) return "|cff9d9d9d" .. s .. "|r" end
local function Green(s) return "|cff40ff40" .. s .. "|r" end

local changePending = false
local function Changed()
	if changePending then return end
	changePending = true
	Week.after(1, "week changed", function()
		changePending = false
		ns.Fire("BOARD_CHANGED")
	end)
end
Week.after = function(seconds, where, fn) ns.After(seconds, where, fn) end

local function Clean(s, n) return ns.Cut((tostring(s or ""):gsub("[~|%c]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")), n) end

-- 1.1 (review): a name the moderators took off (net-off, Moderation.lua), in the name of
-- `guild` when known: its entries, sheets and signups show nowhere (King.HIDDEN_CALLS drops its D
-- and R as they come; these are the ones heard before the word). Never our own.
local function Off(name, guild)
	local M = ns.Moderation
	return type(name) == "string" and name ~= ns.me and M.Hides ~= nil and M.Hides(name, guild) ~= nil
end
-- This client's own character or guild is off: the word, after saying so (nothing it sends would show).
local function SelfOff()
	local M = ns.Moderation
	local off = M.SelfOff and M.SelfOff()
	if off then ns.Print(M.YouText(off)) end
	return off
end

---------------------------------------------------------------------------
-- The realm's clock (the calendar's: C_DateAndTime), as days and minutes of the civil calendar,
-- so an entry reads "Sat 20:00" on every client whatever its own clock and time zone.
---------------------------------------------------------------------------

-- Days since 1970-01-01 of a date, and back (proleptic Gregorian; no time zone, no DST).
local function DaysFrom(y, m, d)
	y = m <= 2 and y - 1 or y
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end
local function DateOf(days)
	days = days + 719468
	local era = math.floor(days / 146097)
	local doe = days - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end
Week.DaysFrom, Week.DateOf = DaysFrom, DateOf

-- The realm's time now: { year, month, monthDay, hour, minute, second }, from the game's calendar
-- clock where the client has it, this computer's otherwise.
function Week.RealmNow()
	local c = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime and C_DateAndTime.GetCurrentCalendarTime()
	local second = (GetServerTime and GetServerTime() or ns.Now()) % 60
	if type(c) == "table" and tonumber(c.year) and tonumber(c.month) and tonumber(c.monthDay) then
		return { year = c.year, month = c.month, monthDay = c.monthDay, hour = c.hour or 0, minute = c.minute or 0, second = second }
	end
	local t = date("*t")
	return { year = t.year, month = t.month, monthDay = t.day, hour = t.hour, minute = t.min, second = t.sec }
end

-- A realm date and time in seconds on one scale (days since 1970 in the realm's own calendar).
local function RealmSeconds(y, m, d, hour, minute, second)
	return DaysFrom(y, m, d) * 86400 + (hour or 0) * 3600 + (minute or 0) * 60 + (second or 0)
end
local function RealmNowSeconds()
	local c = Week.RealmNow()
	return RealmSeconds(c.year, c.month, c.monthDay, c.hour, c.minute, c.second)
end

-- What `at` (this client's clock, as ns.Now) is on the realm's calendar: { days, year, month, day,
-- weekday (1 Sunday), hour, minute }.
function Week.Clock(at)
	local s = RealmNowSeconds() + (at - ns.Now())
	local days = math.floor(s / 86400)
	local rest = s - days * 86400
	local y, m, d = DateOf(days)
	return { days = days, year = y, month = m, day = d, weekday = (days + 4) % 7 + 1, hour = math.floor(rest / 3600), minute = math.floor(rest % 3600 / 60) }
end

-- "Today", "Tomorrow" or "Sat 4 Oct"; "20:00".
function Week.DayLabel(at)
	local c = Week.Clock(at)
	local today = Week.Clock(ns.Now()).days
	if c.days == today then return L.WEEK_TODAY end
	if c.days == today + 1 then return L.WEEK_TOMORROW end
	return L.WEEK_DAY:format(L.WEEK_WEEKDAYS[c.weekday] or "?", c.day, L.WEEK_MONTHS[c.month] or "?")
end
function Week.TimeLabel(at)
	local c = Week.Clock(at)
	return ("%02d:%02d"):format(c.hour, c.minute)
end
-- "in 25 min", "in 3 h", "in 2 days", "now".
function Week.InLabel(at)
	local left = at - ns.Now()
	if left <= 0 then return L.WEEK_NOW end
	if left < 3600 then return L.WEEK_IN_MIN:format(math.max(1, math.ceil(left / 60))) end
	if left < 2 * 86400 then return L.WEEK_IN_HOURS:format(math.floor(left / 3600)) end
	return L.WEEK_IN_DAYS:format(math.floor(left / 86400))
end

---------------------------------------------------------------------------
-- Setting an entry: the Agenda's box takes a day and an hour, then what (King.SetAgenda)
---------------------------------------------------------------------------

-- Day words in English and Portuguese (folded: ns.Fold), by weekday (1 Sunday); today, tomorrow.
Week.DAYS = {
	sun = 1, sunday = 1, dom = 1, domingo = 1,
	mon = 2, monday = 2, seg = 2, segunda = 2,
	tue = 3, tuesday = 3, ter = 3, ["ter\195\167a"] = 3, terca = 3,
	wed = 4, wednesday = 4, qua = 4, quarta = 4,
	thu = 5, thursday = 5, qui = 5, quinta = 5,
	fri = 6, friday = 6, sex = 6, sexta = 6,
	sat = 7, saturday = 7, sab = 7, ["s\195\161b"] = 7, sabado = 7, ["s\195\161bado"] = 7,
}
Week.SOON = { today = 0, hoje = 0, tomorrow = 1, amanha = 1, ["amanh\195\163"] = 1 }

-- "20:00", "8:30", "20h", "20h30": hour, minute.
local function ParseTime(s)
	s = tostring(s or "")
	local h, m = s:match("^(%d%d?)[:hH](%d%d)$")
	if not h then h, m = s:match("^(%d%d?)[hH]$"), "0" end
	h, m = tonumber(h), tonumber(m)
	if not h or not m or h > 23 or m > 59 then return nil end
	return h, m
end

-- "Sat 20:00 Raid night", "today 21:30 Court", "20:00 Raid" (the next 20:00): seconds from now
-- and the title, or nil. The hour is the realm's (the game's calendar).
function Week.Parse(input)
	local text = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local first, rest = text:match("^(%S+)%s+(.+)$")
	if not first then return nil end
	local word = ns.Fold(first)
	local weekday, soon = Week.DAYS[word], Week.SOON[word]
	local timeWord, title
	if weekday or soon then
		timeWord, title = rest:match("^(%S+)%s+(.+)$")
	else
		timeWord, title = first, rest
	end
	local h, m = ParseTime(timeWord)
	title = Clean(title, 60)
	if not h or title == "" then return nil end
	local c = Week.RealmNow()
	local nowMin, target = c.hour * 60 + c.minute, h * 60 + m
	local days
	if weekday then
		local today = (DaysFrom(c.year, c.month, c.monthDay) + 4) % 7 + 1
		days = (weekday - today) % 7
		if days == 0 and target <= nowMin then days = 7 end
	elseif soon then
		days = soon
	else
		days = target > nowMin and 0 or 1
	end
	local seconds = days * 86400 + (target - nowMin) * 60 - (c.second or 0)
	if seconds < Week.MIN_AHEAD or seconds > Week.MAX_AHEAD then return nil end
	return seconds, title
end

-- Whether the text begins as an entry of the week does (a day and an hour, or an hour), right
-- or not: the Agenda's box never takes it as minutes (King.SetAgenda).
function Week.LooksLikeEntry(text)
	local first, second = tostring(text or ""):match("^%s*(%S+)%s*(%S*)")
	if not first then return false end
	local function Hour(s) return s:find("^%d%d?[:hH]%d?%d?$") ~= nil end
	local word = ns.Fold(first)
	if Week.DAYS[word] or Week.SOON[word] then return Hour(second) end
	return Hour(first)
end

local function MineCount()
	local n = 0
	for _, e in pairs(entries) do if e.mine then n = n + 1 end end
	return n
end

-- How many entries a setter holds: the King and his Steward MAX_MINE, a Hand MAX_HAND.
local function Cap(crown) return crown and Week.MAX_MINE or Week.MAX_HAND end
function Week.MyCap()
	local K = ns.King
	return Cap(K.Preview() or K.IsKing() or K.IsSteward())
end

-- An entry heard from its setter goes on the week if there is room: its setter's own cap, and
-- MAX_KEPT in all, where the King's and his Steward's always find a place (the Hand's entry
-- furthest ahead gives up its own). False: left out.
local function Keep(e)
	local his, n, gives = 0, 0, nil
	for _, x in pairs(entries) do
		n = n + 1
		if x.by == e.by then his = his + 1 end
		if not x.mine and not x.crown and (not gives or x.at > gives.at) then gives = x end
	end
	if his >= Cap(e.crown) then return false end
	if n >= Week.MAX_KEPT then
		if not e.crown or not gives then return false end
		entries[gives.id] = nil
	end
	entries[e.id] = e
	return true
end

-- The setter's own entries, kept for his next login (a /reload must not drop the week).
local function SaveMine()
	if not ns.rdb then return end
	local all = type(ns.rdb.week) == "table" and ns.rdb.week or {}
	local list = {}
	for _, e in pairs(entries) do
		if e.mine and not e.preview then list[#list + 1] = { id = e.id, title = e.title, zone = e.zone, at = e.at } end
	end
	all[ns.me or "?"] = #list > 0 and list or nil
	ns.rdb.week = next(all) and all or nil
end

-- The entries this client heard, kept for the realm (1.1 review: the week must not go blank
-- after a /reload or a login while their setter is offline), with when each was last heard and
-- the guild its setter's messages named (1.1 review: a /reload showed again the entries of a
-- setter whose guild is off, net-off, until they passed).
local function SaveHeard()
	if not ns.rdb then return end
	local list = {}
	for _, e in pairs(entries) do
		if not e.mine then
			list[#list + 1] = { id = e.id, by = e.by, title = e.title, zone = e.zone, at = e.at, crown = e.crown or nil, heardAt = e.heardAt,
				guild = e.setterGuild }
		end
	end
	ns.rdb.weekHeard = #list > 0 and list or nil
end
local function Save() SaveMine(); SaveHeard() end

local RestoreSignups -- (the signup sheet's, below)

function Week.Restore(now)
	now = now or ns.Now()
	local all = ns.rdb and ns.rdb.week
	local list = type(all) == "table" and all[ns.me or "?"]
	for _, e in ipairs(type(list) == "table" and list or {}) do
		if type(e) == "table" and tonumber(e.id) and type(e.title) == "string" and tonumber(e.at) and e.at > now + 30 and not entries[e.id] then
			entries[e.id] = { id = e.id, title = Clean(e.title, 60), zone = Clean(e.zone, 40), at = e.at, by = ns.me, mine = true }
		end
	end
	-- The ones heard (an entry of ours that isn't in our own list was taken off).
	local heard = ns.rdb and ns.rdb.weekHeard
	for _, e in ipairs(type(heard) == "table" and heard or {}) do
		if type(e) == "table" and tonumber(e.id) and type(e.by) == "string" and e.by ~= ns.me and type(e.title) == "string" and tonumber(e.at)
			and e.at + Week.KEEP_AFTER >= now and e.at <= now + Week.MAX_AHEAD + 60 and not entries[e.id] and Clean(e.title, 60) ~= "" then
			Keep({ id = e.id, title = Clean(e.title, 60), zone = Clean(e.zone, 40), at = e.at, by = e.by, crown = e.crown == true or nil,
				heardAt = tonumber(e.heardAt) or now, setterGuild = type(e.guild) == "string" and ns.King.CleanGuild(e.guild) or nil })
		end
	end
	RestoreSignups(now)
	Save()
end

local function Send(e, fresh)
	local left = math.floor(e.at - ns.Now())
	if left < 30 then return end
	e.sentAt = ns.Now()
	ns.Comm.Send("CHANNEL", ("T1~D~%d~%s~%d~%d~%s~%s"):format(e.id, GetGuildInfo("player") or "", left, fresh and 1 or 0, e.zone or "", e.title),
		"week" .. e.id)
end

-- The King, his Steward or a Hand puts an entry on the week (the Dark Lady's view: on his screen alone).
function Week.SetEntry(input)
	local seconds, title = Week.Parse(input)
	if not seconds then
		ns.Print(L.THRONE_AGENDA_USAGE)
		return false
	end
	local K = ns.King
	local preview = K.Preview()
	if not preview and not K.CanCommand() then return false end
	if not preview and SelfOff() then return false end
	local now = ns.Now()
	if now - lastSet < Week.SET_GAP then
		ns.Print(L.THRONE_WAIT:format(math.ceil(Week.SET_GAP - (now - lastSet))))
		return false
	end
	local cap = Week.MyCap()
	if MineCount() >= cap then
		ns.Print(L.WEEK_FULL:format(cap))
		return false
	end
	lastSet = now
	local e = { id = K.NewId(), title = title, zone = "", at = now + seconds, by = ns.me, mine = true, preview = preview or nil }
	entries[e.id] = e
	if preview then
		ns.Print(L.THRONE_PREVIEW_NOTE)
	else
		Send(e, true)
		SaveMine()
	end
	ns.Print(L.WEEK_SET:format(title, Week.DayLabel(e.at), Week.TimeLabel(e.at)))
	Changed()
	return true
end

-- Taken off the week, for everyone (its setter, the King, his Steward or a Hand, as the Agenda).
-- 1.1 review: while the moderators have us off (net-off), our own entry still goes down for
-- everyone (Moderation.Blocks lets its cancel out); anyone else's stays, the reason said (no
-- client would take our cancel of it).
function Week.Cancel(id)
	local e = entries[id]
	if not e then return false end
	local K = ns.King
	if not e.preview and not K.Preview() and (e.mine or K.CanCommand()) then
		if not e.mine and SelfOff() then return false end
		ns.Comm.Send("CHANNEL", ("T1~D~%d~%s~0~0~~"):format(id, GetGuildInfo("player") or ""), "week" .. id)
	end
	entries[id] = nil
	Save()
	Week.Forget(id)
	ns.Print(L.WEEK_CANCELLED:format(e.title))
	Changed()
	return true
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- A setter heard (an entry or his sheet): how long he has been online this stretch.
local function HeardFrom(sender, now)
	local p = heardFrom[sender]
	if not p or now - p.last > Week.STALE then
		p = { first = now }
		heardFrom[sender] = p
	end
	p.last = now
end

local function OnEntry(sender, id, rest, guild)
	local seconds, fresh, zone, title = tostring(rest or ""):match("^(%d+)~(%d)~([^~]*)~([^~]*)")
	seconds = tonumber(seconds)
	if not id or not seconds then return end
	local now = ns.Now()
	sender = ns.FullName(sender)
	local e = entries[id]
	-- 1.1 review: a setter the moderators took off (net-off) reaches here with a cancel alone
	-- (King.HandleCommand): it takes his own entry down, nothing else (nor counts as hearing him).
	if Off(sender, guild) then
		if seconds ~= 0 or not e or e.by ~= sender then return end
	else
		HeardFrom(sender, now)
	end
	if seconds == 0 then
		if e then
			-- (Another's cancel reaching its setter: he stops repeating it.)
			entries[id] = nil
			Save()
			Changed()
		end
		-- Our signup for it goes too, and its nudge (kept across a /reload).
		Week.Forget(id)
		return
	end
	title = Clean(title, 60)
	if seconds < 30 or seconds > Week.MAX_AHEAD or title == "" then return end
	if e then
		-- A repeat: its own setter's only; our time kept unless it is really off.
		if e.by ~= sender then return end
		if math.abs((now + seconds) - e.at) > 60 then e.at = now + seconds end
		e.title, e.zone, e.heardAt = title, Clean(zone, 40), now
		e.setterGuild = ns.King.CleanGuild(guild) or e.setterGuild -- (the guild his latest message named, saved with it)
		SaveHeard()
		return Changed()
	end
	local K = ns.King
	e = { id = id, title = title, zone = Clean(zone, 40), at = now + seconds, by = sender, heardAt = now,
		crown = (K.FromKing(sender, guild) or K.IsStewardName(sender)) and true or nil, setterGuild = K.CleanGuild(guild) or nil }
	if not Keep(e) then return end
	SaveHeard()
	-- A new entry: one quiet chat line (never a raid warning or a popup), and not on repeats.
	if fresh == "1" and now - lastNewLine >= Week.NEW_LINE_GAP then
		lastNewLine = now
		ns.Print(L.WEEK_NEW:format(Week.Setter(e), title, Week.DayLabel(e.at), Week.TimeLabel(e.at)))
	end
	Changed()
end
ns.King.Register("D", OnEntry)

-- Who set it, as the army calls them: the King by his name for the army, anyone else by theirs.
function Week.Setter(e)
	if e.by == ns.me then return L.WEEK_BY_YOU end
	if ns.IsKingCharacter(e.by) then return ns.KingName(e.by) end
	return ns.DisplayName(e.by) or "?"
end

---------------------------------------------------------------------------
-- The week: the Agenda's current event and the dated entries, then the guild's own events
---------------------------------------------------------------------------

-- Every entry of the King's week still to come (or begun within KEEP_AFTER), soonest first:
-- { id, title, zone, at, by, mine, agenda (the current event, King.Agenda) }.
function Week.Entries(now)
	now = now or ns.Now()
	local out = {}
	for id, e in pairs(entries) do
		if e.at + Week.KEEP_AFTER < now then
			entries[id] = nil
		elseif e.mine or not Off(e.by, e.setterGuild) then
			out[#out + 1] = e
		end
	end
	local a = ns.King.Agenda and ns.King.Agenda()
	if a and not entries[a.id] and (a.mine or not Off(ns.FullName(a.by))) then
		out[#out + 1] = { id = a.id, title = a.title, zone = a.zone, at = a.at, by = ns.FullName(a.by), mine = a.mine, agenda = true,
			setterGuild = a.guild } -- (its setter's guild, saved with a signup: the reminder's net-off check after a /reload)
	end
	table.sort(out, function(x, y) if x.at ~= y.at then return x.at < y.at end return x.id < y.id end)
	return out
end

-- Whether this client may read the guild's calendar: the client has it, the realm's rules let
-- the calendar in, and the guild's events are on (each asked through pcall: unknown on Forever
-- until checked in game).
function Week.CalendarAllowed()
	if not (C_Calendar and C_Calendar.GetNumGuildEvents and C_Calendar.GetGuildEventInfo) then return false end
	if C_GameRules and C_GameRules.IsGameRuleActive and Enum and Enum.GameRule and Enum.GameRule.IngameCalendarDisabled then
		local ok, off = pcall(C_GameRules.IsGameRuleActive, Enum.GameRule.IngameCalendarDisabled)
		if ok and off then return false end
	end
	if C_GuildInfo and C_GuildInfo.AreGuildEventsEnabled then
		local ok, on = pcall(C_GuildInfo.AreGuildEventsEnabled)
		if ok and on == false then return false end
	end
	return true
end

-- The player's own guild's events of the next 7 days, from the game's calendar (read here, never
-- sent): { title, at, guild = true }. On the King's screen (his stream) no title, only
-- "Guild event".
function Week.GuildEvents(now)
	now = now or ns.Now()
	if not IsInGuild() or not Week.CalendarAllowed() then return {} end
	local ok, n = pcall(C_Calendar.GetNumGuildEvents)
	if not ok or type(n) ~= "number" then return {} end
	local out, realmNow = {}, RealmNowSeconds()
	for i = 1, math.min(n, 30) do
		local fine, info = pcall(C_Calendar.GetGuildEventInfo, i)
		if fine and type(info) == "table" and tonumber(info.year) and tonumber(info.month) and tonumber(info.monthDay) then
			local at = now + (RealmSeconds(info.year, info.month, info.monthDay, info.hour, info.minute, 0) - realmNow)
			if at > now - Week.KEEP_AFTER and at <= now + Week.MAX_AHEAD then
				local title = ns.KingsScreen() and L.WEEK_GUILD_EVENT or ns.Codec.Plain(info.title or "")
				out[#out + 1] = { title = title ~= "" and title or L.WEEK_GUILD_EVENT, at = at, guild = true }
			end
		end
	end
	table.sort(out, function(x, y) return x.at < y.at end)
	while #out > Week.GUILD_EVENTS do table.remove(out) end
	return out
end

-- The game's calendar asked for its data (as its own window does when it opens): when the week
-- shows, once every CALENDAR_ASK at most. Its answer (CALENDAR_UPDATE_GUILD_EVENTS) redraws it.
function Week.AskCalendar(now)
	now = now or ns.Now()
	if now - lastCalendarAsk < Week.CALENDAR_ASK or not IsInGuild() or not Week.CalendarAllowed() or not C_Calendar.OpenCalendar then return false end
	lastCalendarAsk = now
	pcall(C_Calendar.OpenCalendar)
	return true
end

-- An officer's click on an entry: the game's calendar opens (its own opener, the minimap
-- clock's), and he is told which day to pick and what to create there. Never with the gamepad
-- UI (Sylvanistas opens no Blizzard window there) or in combat: then only how to open it.
function Week.CanOpenCalendar()
	return ns.Roster.IsOfficer() and Week.CalendarAllowed()
end
function Week.OpenCalendar(e)
	if not e then return false end
	local when = Week.DayLabel(e.at) .. " " .. Week.TimeLabel(e.at)
	if ns.GamepadUI() or (InCombatLockdown and InCombatLockdown()) or type(ToggleCalendar) ~= "function" then
		ns.Print(L.WEEK_CAL_HINT:format(when, e.title))
		return false
	end
	if not (CalendarFrame and CalendarFrame.IsShown and CalendarFrame:IsShown()) then
		local ok = pcall(ToggleCalendar)
		if not ok then
			ns.Print(L.WEEK_CAL_HINT:format(when, e.title))
			return false
		end
	end
	ns.Print(L.WEEK_CAL_OPENED:format(when, e.title))
	return true
end

-- The week's lines on the Board: by day, each entry at its realm hour; the guild's events among
-- them (green); for officers, a click to take it to the game's calendar; for the King and his
-- Hands, a click to take it off. `q`: the Board's search.
local open = {} -- [entry id] = its actions shown
function Week.Section(lines, q)
	local now = ns.Now()
	Week.AskCalendar(now)
	local list = {}
	for _, e in ipairs(Week.Entries(now)) do list[#list + 1] = e end
	for _, e in ipairs(Week.GuildEvents(now)) do list[#list + 1] = e end
	table.sort(list, function(x, y) return x.at < y.at end)
	lines[#lines + 1] = { header = true, text = L.WEEK_TITLE,
		tooltip = function(tt) tt:AddLine(L.WEEK_TITLE, 1, 0.82, 0); tt:AddLine(L.WEEK_TIP, 1, 1, 1, true) end }
	local shown, lastDay = 0, nil
	local K = ns.King
	local mayCancel = K.CanCommand() or K.Preview()
	for _, e in ipairs(list) do
		if not q or ns.Holds(q, e.title, e.zone, Week.DayLabel(e.at), not e.guild and Week.Setter(e) or nil) then
			shown = shown + 1
			local day = Week.DayLabel(e.at)
			if day ~= lastDay then
				lastDay = day
				lines[#lines + 1] = { indent = 1, text = Gold(day) }
			end
			local where = e.zone and e.zone ~= "" and (" (" .. e.zone .. ")") or ""
			local row = {
				indent = 2,
				text = Week.TimeLabel(e.at) .. "  " .. (e.guild and Green(e.title .. "  " .. L.WEEK_YOUR_GUILD) or Gold(e.title .. where)),
				right = Grey(Week.InLabel(e.at)),
				tooltip = function(tt)
					tt:AddLine(e.title, 1, 0.82, 0)
					tt:AddLine(day .. " " .. Week.TimeLabel(e.at) .. where, 1, 1, 1)
					tt:AddLine(e.guild and L.WEEK_GUILD_TIP or L.WEEK_SET_BY:format(Week.Setter(e)), 0.8, 0.8, 0.8, true)
				end,
			}
			lines[#lines + 1] = row
			if not e.guild then
				local actions = {}
				if Week.CanOpenCalendar() then
					actions[#actions + 1] = { indent = 3, text = Gold("> " .. L.WEEK_CAL_BTN),
						onClick = function() Week.OpenCalendar(e) end,
						tooltip = function(tt) tt:AddLine(L.WEEK_CAL_BTN, 1, 0.82, 0); tt:AddLine(L.WEEK_CAL_TIP, 1, 1, 1, true) end }
				end
				if mayCancel and not e.agenda then
					actions[#actions + 1] = { indent = 3, text = Grey("x " .. L.WEEK_CANCEL), onClick = function() Week.Cancel(e.id) end }
				end
				-- Its signup sheet (request #27).
				Week.SheetLines(lines, e)
				for _, a in ipairs(actions) do lines[#lines + 1] = a end
			end
		end
	end
	if shown == 0 then
		lines[#lines + 1] = { indent = 1, text = Grey(q and L.SEARCH_NO_MATCH or L.WEEK_EMPTY) }
		if not q and mayCancel then ns.Views.GreyRows(lines, L.WEEK_HOW, { indent = 1 }) end
	end
	lines[#lines].gapAfter = true
end

---------------------------------------------------------------------------
-- The signup sheet (1.1, request #27): on any entry of the King's Agenda (its current event or
-- one of the week's), a player clicks Sign up and picks the role he claims: Tank, Healer, DPS
-- or Any. Nothing checks the claim (no aura, no spec, no gear), nothing invites anyone: the
-- signup is a whisper to whoever set that entry, alone, and whoever runs the event invites by
-- hand. The setter's client keeps one signup per character and repeats the counts to the army
-- every 5 minutes, and sooner after a change, so the King knows whether the raid is 4 or 40
-- before anyone zones in; the names stay on the setter's own screen, behind a click. They are
-- kept with his entries across a /reload or a login (the next sheet must not tell the army 0).
--   Y2~<agendaId>~<role>~<guild>   role T|H|D|A, W withdraws; whispered to the entry's setter
--   T1~R~<id>~<guild>~<agendaId>:<t>:<h>:<d>:<a>,...~<minutes>   the setter's sheet: counts per
--       role of each entry of his (the census-placed signups; the rest counted apart, on his
--       screen), then the minutes to his next one: 5 while an entry of his has signups or is
--       within 2 days, 15 otherwise (none: 5)
-- The Sign up row shows only while the setter's sheet was heard within the time it gave (his
-- client is online and knows signups): a whisper to a setter who left would only earn a "No
-- player named" line. Clients before 1.1 leave the kind R out, and never see Y2.
---------------------------------------------------------------------------

Week.ROLES = { "T", "H", "D", "A" }
Week.ROLE_OK = { T = true, H = true, D = true, A = true }
Week.SHEET_EVERY = 300       -- the setter's client repeats its sheet this often while an entry of his is near or signed...
Week.SHEET_IDLE = 900        -- ...this often otherwise (entries days away that nobody signed yet)
Week.SHEET_NEAR = 2 * 86400
Week.SHEET_SOON = 20         -- ...and this long after a change (one message for a burst)
Week.SHEET_LATE = 90         -- a sheet heard within its own time and this: its setter takes signups
Week.SHEET_FRESH = Week.SHEET_EVERY + Week.SHEET_LATE -- (a sheet that gives no time)
Week.SIGN_GAP = 3            -- seconds between two of our signups
Week.MAX_SIGNUPS = 2000      -- signups one entry keeps (the census-placed and the others)
ns.King.HAND_MAY.R = true
ns.King.STEWARD_MAY.R = true

local sheets = {}            -- [agendaId] = { T, H, D, A = counts, at = when heard, fresh = for how long } (another's entries)
local signups = {}           -- [agendaId] = { list = { [Name-Realm] = { role, guild, placed, t } }, byGuild = {}, others = n } (ours)
local lastSheet, lastEvery, sheetPending, lastSign = -math.huge, nil, false, -math.huge
local signOpen, whoOpen = {}, {} -- [agendaId] = the role rows, the names shown

local function RoleLabel(role) return L["SIGN_ROLE_" .. tostring(role)] or "?" end
Week.RoleLabel = RoleLabel

-- This character's own signups, kept for its next login (the reminder, #2): [agendaId] =
-- { role, at, title, zone, agenda, by, guild (its setter and his guild: the net-off) }: enough
-- for the nudge even while the entry isn't heard again.
local function Signed()
	if not ns.rdb then return {} end
	if type(ns.rdb.signed) ~= "table" then ns.rdb.signed = {} end
	local me = ns.me or "?"
	if type(ns.rdb.signed[me]) ~= "table" then ns.rdb.signed[me] = {} end
	return ns.rdb.signed[me]
end
function Week.MySignup(id)
	local s = ns.rdb and type(ns.rdb.signed) == "table" and ns.rdb.signed[ns.me or "?"]
	local v = type(s) == "table" and s[id]
	return type(v) == "table" and v.role or nil
end

-- An entry taken off (its cancel heard, the Agenda's X): the signups of every character here
-- for it go, and their nudges.
function Week.Forget(id)
	local all = ns.rdb and ns.rdb.signed
	if type(all) ~= "table" or not id then return end
	for _, list in pairs(all) do
		if type(list) == "table" then list[id] = nil end
	end
end

-- The setter's signups, kept with his entries for his next login (1.1 review: after a /reload
-- the next sheet told the army 0): rdb.signups[me][agendaId] = its list, the table itself.
local function SaveSignups()
	if not ns.rdb then return end
	local all = type(ns.rdb.signups) == "table" and ns.rdb.signups or {}
	local mine = {}
	for id, s in pairs(signups) do
		local e = entries[id]
		if e and e.mine and not e.preview and s.n > 0 then mine[id] = s.list end
	end
	all[ns.me or "?"] = next(mine) and mine or nil
	ns.rdb.signups = next(all) and all or nil
end

-- At login, after our entries: their signups as they were (checked again: SavedVariables).
RestoreSignups = function(now)
	local all = ns.rdb and ns.rdb.signups
	local saved = type(all) == "table" and all[ns.me or "?"]
	for id, list in pairs(type(saved) == "table" and saved or {}) do
		local e = entries[id]
		if e and e.mine and type(list) == "table" and not signups[id] then
			local s = { list = {}, byGuild = {}, others = 0, n = 0 }
			for name, v in pairs(list) do
				if s.n >= Week.MAX_SIGNUPS then break end
				if type(name) == "string" and type(v) == "table" and Week.ROLE_OK[v.role] then
					local guild = type(v.guild) == "string" and v.guild or "?"
					local placed = v.placed == true
					s.list[name] = { role = v.role, guild = guild, placed = placed, t = tonumber(v.t) or now }
					s.n = s.n + 1
					if not placed then s.others = s.others + 1
					elseif guild ~= "?" then s.byGuild[guild] = (s.byGuild[guild] or 0) + 1 end
				end
			end
			signups[id] = s
		end
	end
	SaveSignups()
end

-- The entry (the Agenda's current event or one of the week's) with that id, or nil.
function Week.Entry(id)
	for _, e in ipairs(Week.Entries()) do if e.id == id then return e end end
	return nil
end

-- Whether a signup can reach this entry's setter now: ours, or his sheet heard within the time
-- it gave for his next one.
function Week.TakesSignups(e)
	if not e or e.at <= ns.Now() or e.preview then return false end
	if e.mine then return true end
	local s = sheets[e.id]
	return s ~= nil and ns.Now() - s.at <= (s.fresh or Week.SHEET_FRESH)
end

-- The counts of an entry: ours from the signups themselves, anyone else's from their sheet.
function Week.Counts(e)
	if e and e.mine then
		local c = { T = 0, H = 0, D = 0, A = 0, others = 0 }
		local s = signups[e.id]
		for name, v in pairs(s and s.list or {}) do
			-- (1.1, review: never a name the moderators took off since.)
			if Off(name, v.guild) then
			elseif v.placed then c[v.role] = c[v.role] + 1
			else c.others = c.others + 1 end
		end
		return c
	end
	return e and sheets[e.id] or nil
end

-- Our click: the role we claim (W: withdrawn), whispered to the setter alone.
function Week.Sign(id, role)
	local e = Week.Entry(id)
	if not e or not (role == "W" or Week.ROLE_OK[role]) then return false end
	if not ns.IsMember() then
		ns.Print(L.MEMBERS_ONLY)
		return false
	end
	if SelfOff() then return false end
	if not Week.TakesSignups(e) then
		ns.Print(L.SIGN_NOT_NOW)
		return false
	end
	local now = ns.Now()
	if now - lastSign < Week.SIGN_GAP then return false end
	lastSign = now
	local msg = ("Y2~%d~%s~%s"):format(id, role, GetGuildInfo("player") or "")
	if e.mine then
		Week.HandleSignup("WHISPER", ns.me, msg)
	else
		ns.Comm.Whisper(e.by, msg, "sign" .. id, true)
	end
	local mine = Signed()
	if role == "W" then
		mine[id] = nil
		ns.Print(L.SIGN_WITHDRAWN:format(e.title))
	else
		mine[id] = { role = role, at = e.at, title = e.title, zone = e.zone, agenda = e.agenda or nil, by = e.by, guild = e.setterGuild }
		ns.Print(L.SIGN_DONE:format(RoleLabel(role), e.title))
	end
	signOpen[id] = nil
	Changed()
	return true
end

-- Whose signup counts on the sheet: our own guild's members (the server's roster), or a guild of
-- the census, fresh, never more signups from it than it has members. Anyone else's (nothing
-- stops a stranger from whispering one) is counted apart, on the setter's screen alone.
local sizes, sizesAt = {}, -math.huge
local function GuildSize(guild)
	local now = ns.Now()
	if now - sizesAt > 60 then
		sizes, sizesAt = {}, now
		for _, g in ipairs(ns.Data.Summary().guilds) do
			if g.fresh and not g.g.conflict then sizes[g.name] = tonumber(g.g.total) or 0 end
		end
	end
	return sizes[guild]
end
local function Placed(s, sender, guild)
	if sender == ns.me or ns.Roster.RankOf(sender) then return true end
	local own = GetGuildInfo("player")
	if not guild or (own and guild == own) then return false end
	local size = GuildSize(guild)
	return size ~= nil and (s.byGuild[guild] or 0) < math.max(size, 1)
end

local function SheetSoon()
	if sheetPending then return end
	sheetPending = true
	Week.after(Week.SHEET_SOON, "week sheet", function()
		sheetPending = false
		Week.SendSheet(true)
	end)
end

-- A signup, whispered to us: kept only for an entry of ours still to come.
function Week.HandleSignup(dist, sender, text)
	if dist ~= "WHISPER" then return end
	local id, role, guild = tostring(text or ""):match("^Y2~(%d+)~([THDAW])~(.*)$")
	local e = Week.Entry(tonumber(id))
	if not e or not e.mine or e.preview or e.at <= ns.Now() then return end
	sender = ns.FullName(sender)
	guild = ns.King.CleanGuild(guild)
	-- 1.1 (review): a name the moderators took off (net-off, Moderation.lua) signs nothing.
	if Off(sender, guild) then return end
	local s = signups[e.id]
	if not s then
		s = { list = {}, byGuild = {}, others = 0, n = 0 }
		signups[e.id] = s
	end
	local old = s.list[sender]
	if role == "W" then
		if not old then return end
		s.list[sender], s.n = nil, s.n - 1
		if old.placed then s.byGuild[old.guild] = (s.byGuild[old.guild] or 1) - 1 else s.others = s.others - 1 end
	elseif old then
		old.role, old.t = role, ns.Now()
	else
		if s.n >= Week.MAX_SIGNUPS then return end
		local placed = Placed(s, sender, guild)
		s.list[sender] = { role = role, guild = guild or "?", placed = placed, t = ns.Now() }
		s.n = s.n + 1
		if placed then
			if guild then s.byGuild[guild] = (s.byGuild[guild] or 0) + 1 end
		else
			s.others = s.others + 1
		end
	end
	SaveSignups()
	SheetSoon()
	Changed()
end
ns.Comm.Handle("Y2", function(...) Week.HandleSignup(...) end)

-- The setter's sheet: the counts of every entry of his still to come, in one message (pieces
-- when long), and when the next comes: every SHEET_EVERY while one of them has signups or is
-- within SHEET_NEAR, every SHEET_IDLE otherwise. `soon`: a change's, sent whatever the time
-- since the last one.
function Week.SendSheet(soon)
	local K = ns.King
	if K.Preview() or not K.CanCommand() then return false end
	-- (1.1, review: every client drops the sheet of a setter the moderators took off, and
	-- a long one goes in pieces, past Comm.Send's backstop.)
	local M = ns.Moderation
	if M.SelfOff and M.SelfOff() then return false end
	local now = ns.Now()
	local parts, busy = {}, false
	for _, e in ipairs(Week.Entries(now)) do
		if e.mine and not e.preview and e.at > now then
			local c = Week.Counts(e)
			parts[#parts + 1] = ("%d:%d:%d:%d:%d"):format(e.id, c.T, c.H, c.D, c.A)
			local s = signups[e.id]
			if (s and s.n > 0) or e.at - now <= Week.SHEET_NEAR then busy = true end
		end
	end
	if #parts == 0 then return false end
	local every = busy and Week.SHEET_EVERY or Week.SHEET_IDLE
	-- (Its pace changed: the army hears it now, or the last sheet's time would run out first.)
	if not soon and every == lastEvery and now - lastSheet < every then return false end
	lastSheet, lastEvery = now, every
	local msg = ("T1~R~%d~%s~%s~%d"):format(K.NewId(), GetGuildInfo("player") or "", table.concat(parts, ","), every / 60)
	if #msg <= 250 then ns.Comm.Send("CHANNEL", msg, "sheet") else ns.Comm.SendChunked(msg) end
	return true
end

-- Another setter's sheet: taken for the entries that setter set, as they are, fresh for the
-- time it gives (5 to 60 minutes; none given: 5).
local function OnSheet(sender, _, rest)
	sender = ns.FullName(sender)
	local now, any = ns.Now(), false
	HeardFrom(sender, now)
	local body, minutes = tostring(rest or ""):match("^([^~]*)~?(%d*)")
	minutes = math.max(5, math.min(60, tonumber(minutes) or 5))
	for part in (body or ""):gmatch("[^,]+") do
		local id, t, h, d, a = part:match("^(%d+):(%d+):(%d+):(%d+):(%d+)$")
		local e = id and Week.Entry(tonumber(id))
		if e and not e.mine and e.by == sender then
			local cap = Week.MAX_SIGNUPS
			sheets[e.id] = { T = math.min(tonumber(t), cap), H = math.min(tonumber(h), cap), D = math.min(tonumber(d), cap),
				A = math.min(tonumber(a), cap), at = now, fresh = minutes * 60 + Week.SHEET_LATE }
			any = true
		end
	end
	if any then Changed() end
end
ns.King.Register("R", OnSheet)

-- An entry's sheet on the week: its counts, our own role, the role rows once Sign up is
-- clicked; for its setter the names by role, behind a click (the King's stream: a councillor's
-- name cut short while the council's names are hidden there).
local function ShownName(name)
	local shown = ns.DisplayName(name) or "?"
	if ns.CouncilMasked() and ns.IsHighCouncillor(name) then return ns.MaskName(shown) end
	return shown
end

function Week.SheetLines(lines, e)
	local counts = Week.Counts(e)
	local mine = Week.MySignup(e.id)
	if counts or mine then
		local text = counts and L.SIGN_COUNTS:format(counts.T or 0, counts.H or 0, counts.D or 0, counts.A or 0) or ""
		if mine then text = text .. (text ~= "" and "  ·  " or "") .. Green(L.SIGN_YOU:format(RoleLabel(mine))) end
		lines[#lines + 1] = { indent = 3, text = Grey(text), tooltip = function(tt)
			tt:AddLine(L.SIGN_TITLE, 1, 0.82, 0)
			tt:AddLine(L.SIGN_TIP, 1, 1, 1, true)
		end }
	end
	if Week.TakesSignups(e) then
		lines[#lines + 1] = { indent = 3, text = Gold((signOpen[e.id] and "[-] " or "[+] ") .. (mine and L.SIGN_CHANGE or L.SIGN_UP)),
			onClick = function() signOpen[e.id] = not signOpen[e.id] or nil; Changed(); if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end end,
			tooltip = function(tt) tt:AddLine(L.SIGN_UP, 1, 0.82, 0); tt:AddLine(L.SIGN_TIP, 1, 1, 1, true) end }
		if signOpen[e.id] then
			for _, role in ipairs(Week.ROLES) do
				lines[#lines + 1] = { indent = 4, text = (mine == role and Green or Gold)("> " .. RoleLabel(role)),
					onClick = function() Week.Sign(e.id, role) end }
			end
			if mine then lines[#lines + 1] = { indent = 4, text = Grey("x " .. L.SIGN_WITHDRAW), onClick = function() Week.Sign(e.id, "W") end } end
		end
	end
	local s = e.mine and signups[e.id]
	local shown = 0
	for name, v in pairs(s and s.list or {}) do if not Off(name, v.guild) then shown = shown + 1 end end
	if shown > 0 then
		lines[#lines + 1] = { indent = 3, text = Gold((whoOpen[e.id] and "[-] " or "[+] ") .. L.SIGN_WHO:format(shown)),
			onClick = function() whoOpen[e.id] = not whoOpen[e.id] or nil; if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end end }
		if whoOpen[e.id] then
			for _, role in ipairs(Week.ROLES) do
				local names = {}
				for name, v in pairs(s.list) do if v.role == role and not Off(name, v.guild) then names[#names + 1] = name end end
				table.sort(names)
				if #names > 0 then
					lines[#lines + 1] = { indent = 4, text = Gold(RoleLabel(role) .. " (" .. #names .. ")") }
					for i, name in ipairs(names) do
						if i > 25 then
							lines[#lines + 1] = { indent = 5, text = Grey(L.AND_MORE:format(#names - 25)) }
							break
						end
						local v = s.list[name]
						lines[#lines + 1] = { indent = 5, text = ShownName(name) .. "  " .. Grey("<" .. ns.Codec.Plain(v.guild) .. ">")
							.. (v.placed and "" or ("  " .. Grey(L.SIGN_UNCONFIRMED))) }
					end
				end
			end
		end
	end
end

-- The sheets heard, as this client holds them (tests).
function Week.Sheets() return sheets end

-- A nudge for what this character signed (1.1, request #2): a few minutes before an entry it
-- signed, one chat line and the usual alert sound, on this client alone: never a raid warning,
-- nothing sent. Once per entry (kept with the signup, across a /reload). From the signup itself
-- (its time, title and zone) when the entry isn't heard again before it begins (1.1 review: a
-- /reload a few minutes before the pull, its setter's next repeat after it).
Week.REMIND = 5 * 60
-- Whose entry a signup is for, and in which guild's name: the entry as heard (hidden or not),
-- else the Agenda's current event, else what the signup kept.
local function SetterOf(id, v)
	local e = entries[id]
	if e then return e.by, e.setterGuild end
	local a = ns.King.Agenda and ns.King.Agenda()
	if a and a.id == id then return ns.FullName(a.by), a.guild or (type(v.guild) == "string" and v.guild or nil) end
	return v.by, type(v.guild) == "string" and v.guild or nil
end
function Week.Remind(now)
	now = now or ns.Now()
	local mine = ns.rdb and type(ns.rdb.signed) == "table" and ns.rdb.signed[ns.me or "?"]
	if type(mine) ~= "table" then return end
	local here = {}
	for _, e in ipairs(Week.Entries(now)) do here[e.id] = e end
	local agenda = ns.King.Agenda and ns.King.Agenda()
	for id, v in pairs(mine) do
		local e = here[id]
		if type(v) ~= "table" then
			-- (Left for Tick.)
		elseif e then
			v.at, v.title, v.zone = e.at, e.title, e.zone -- (the latest word)
		elseif v.agenda and agenda and agenda.id ~= id then
			mine[id] = nil -- the Agenda's current event, replaced by another
		end
		local left = type(v) == "table" and mine[id] and tonumber(v.at) and v.at - now
		-- (1.1 review: nothing while its setter, or his guild, is off: net-off. Not marked reminded:
		-- shown again before it begins, the nudge comes.)
		if left and v.role and not v.reminded and type(v.title) == "string" and v.title ~= "" and left > 0 and left <= Week.REMIND
			and not Off(SetterOf(id, v)) then
			v.reminded = true
			local zone = type(v.zone) == "string" and v.zone or ""
			local where = zone ~= "" and (" (" .. zone .. ")") or ""
			ns.Print("|cffffd200" .. L.SIGN_SOON:format(RoleLabel(v.role), v.title, math.max(1, math.ceil(left / 60)), where) .. "|r")
			ns.PlayAlert("soft", "agenda") -- (1.1: the Agenda's sound switch; held in an instance or on Busy)
		end
	end
end

-- "3 this week" for the tree's link to the Board.
function Week.LinkPart()
	local n = #Week.Entries()
	return n > 0 and L.WEEK_LINK:format(n) or nil
end

---------------------------------------------------------------------------
-- Every minute: the setter's client repeats its entries for late logins
---------------------------------------------------------------------------

-- How often the setter's client repeats an entry: RESEND, RESEND_FAR while it is days away.
function Week.Resend(e, now)
	return e.at - (now or ns.Now()) > Week.FAR and Week.RESEND_FAR or Week.RESEND
end

function Week.Tick(now)
	now = now or ns.Now()
	-- (Only while this character still may: a Hand the King's list no longer names stops.)
	local due = {}
	for _, e in pairs(entries) do
		if e.mine and not e.preview and e.at - now >= 30 and now - (e.sentAt or -math.huge) >= Week.Resend(e, now) and ns.King.CanCommand() then due[#due + 1] = e end
	end
	table.sort(due, function(x, y) return (x.sentAt or 0) < (y.sentAt or 0) end)
	for i = 1, math.min(#due, Week.RESEND_PER_TICK) do Send(due[i], false) end
	-- Over; or another's that its setter, online this long, no longer repeats (its cancel missed
	-- while this client was away): off the week.
	local gone = false
	for id, e in pairs(entries) do
		local p = not e.mine and heardFrom[e.by]
		if e.at + Week.KEEP_AFTER < now then
			entries[id], gone = nil, true
		elseif p and p.last <= e.at - 30 and p.last - math.max(e.heardAt or 0, p.first) > Week.STALE then
			entries[id], gone = nil, true
			Week.Forget(id)
		end
	end
	if gone then Save(); Changed() end
	-- What this character signed, a few minutes before (#2).
	Week.Remind(now)
	-- The setter's sheet: every 5 minutes, and at once for an entry of his none has heard yet.
	local new = false
	for _, e in ipairs(Week.Entries(now)) do
		if e.mine and not e.preview and e.at > now and not signups[e.id] then
			signups[e.id] = { list = {}, byGuild = {}, others = 0, n = 0 }
			new = true
		end
	end
	Week.SendSheet(new)
	-- Signups and sheets of entries gone.
	for id in pairs(signups) do if not Week.Entry(id) then signups[id] = nil end end
	for id in pairs(sheets) do if not Week.Entry(id) then sheets[id] = nil end end
	SaveSignups()
	local mine = ns.rdb and type(ns.rdb.signed) == "table" and ns.rdb.signed[ns.me or "?"]
	for id, v in pairs(type(mine) == "table" and mine or {}) do
		if type(v) ~= "table" or not tonumber(v.at) or v.at + Week.KEEP_AFTER < now then mine[id] = nil end
	end
end

function Week.StatusLine()
	local mine, others = 0, 0
	for _, e in pairs(entries) do if e.mine then mine = mine + 1 else others = others + 1 end end
	return ("entries %d (%d mine)  |  guild calendar: %s"):format(mine + others, mine, Week.CalendarAllowed() and "read" or "not here")
end

-- Tests start from nothing.
function Week.Reset()
	wipe(entries); wipe(heardFrom)
	lastSet, lastNewLine, lastCalendarAsk, changePending = -math.huge, -math.huge, -math.huge, false
	wipe(sheets); wipe(signups); wipe(signOpen); wipe(whoOpen)
	lastSheet, lastEvery, sheetPending, lastSign, sizesAt = -math.huge, nil, false, -math.huge, -math.huge
	if ns.rdb then ns.rdb.week, ns.rdb.signed, ns.rdb.weekHeard, ns.rdb.signups = nil, nil, nil, nil end
end

ns.On("LOGIN", function()
	Week.Restore()
	ns.Every(60, "week", function() Week.Tick() end)
	-- The game's calendar answers OpenCalendar with this (clients without the calendar: none).
	if C_Calendar and C_Calendar.GetNumGuildEvents then
		pcall(ns.RegisterEvent, "CALENDAR_UPDATE_GUILD_EVENTS", function() Changed() end)
	end
end)
