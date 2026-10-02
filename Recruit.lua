local ADDON, ns = ...
local L = ns.L

-- "Join Sylvanistas", for players who are NOT in a Sylvanistas guild yet (the only thing the addon
-- does for them). It uses the game's own /who (Who.lua), which anyone can run: find Sylvanistas
-- members online, group them by guild, and whisper one of them a ready-made request. No answer?
-- Try someone else. Rate limited so nobody gets spammed.
--
-- Routing (1.1, Fern's #20): recruits whispered whoever /who returned, so the guild the King
-- opened stayed empty while full ones got spammed. Now the Join screen asks one member's addon
-- (J1, an addon whisper, one per search) where recruits should go: that member's census answers
-- (J2) with the King's gates, the guilds with the most free slots and a couple of their Lords
-- and Captains online. The screen lists the gates' guild first, then the most room, and asks
-- those officers. A member may flag himself do-not-contact (/syl nocontact on): his addon says so
-- when asked (J2), and the screen never offers him. The request itself stays one whisper per
-- click, the player's own words (no dues line), and goes with a J3 to the same member, whose
-- addon shows it with Invite and Decline (an officer's yes or no, one click each) instead of a
-- raw whisper. These three are the only messages the addon exchanges outside a Sylvanistas guild
-- (Comm.WhisperOutside); versions before 1.1 ignore all three.
--
-- Whom a recruit whispers stays the server's word, as before 1.1: a J2 only orders. A member's
-- census names a guild only when the census does not mark it (Data.Dispute: two senders or more
-- agree on it, or it is ours), and a Lord or Captain only when two senders name them
-- (Data.KnownRank). The screen asks an officer the answer names only once its own /who found him
-- in that guild, lists a guild only once /who found one of its members, and shows the gates only
-- when two members' answers agree on them. One forged report, or one modified member's J2,
-- names nobody to whisper.
--   J1~1                                  which guild should I ask?
--   J2~<y|n>~<gates guild>~<seconds>~<guild>=<free>=<name>/<name>;...   the answer (n: do not contact me)
--   J3~<guild asked>~<level>~<CLASS>      my request (sent with the player's whisper)

local Recruit = {}
ns.Recruit = Recruit

local ASK_COOLDOWN = 20

Recruit.ROUTE_GAP = 15      -- seconds between two J1 of the searches (an Ask click checks its own member)
Recruit.ROUTE_WAIT = 60     -- a J2 counts from a member asked this recently
Recruit.ROUTE_FRESH = 600   -- a route this recent: no new J1 at a search
Recruit.ROUTE_KEEP = 1800   -- a route is shown this long
Recruit.ROUTE_ASKS = 3      -- gates one answer named: more members asked, up to this many within ROUTE_FRESH
Recruit.ROUTE_GUILDS = 8    -- guilds in one answer, at most
Recruit.ROUTE_CONTACTS = 2  -- officers named per guild, at most
Recruit.ANSWER_EACH = 60    -- a member answers one asker at most this often...
Recruit.ANSWER_MAX = 10     -- ...and this many askers a minute in all (do not contact: a bare "no" past it)
Recruit.REQUEST_EACH = 600  -- a request from one player counts once this often
Recruit.REQUEST_TTL = 3600  -- a request is shown this long
Recruit.REQUESTS_MAX = 30   -- requests kept
Recruit.REQUESTS_SHOWN = 5  -- requests shown in the Census, the rest counted
Recruit.REQUEST_LINES = 6   -- chat lines about requests a minute, at most

Recruit.found = {}      -- list of { name, guild, level, class, zone }
Recruit.asked = {}      -- [name] = time we whispered them
Recruit.replied = {}    -- [name] = their answer
Recruit.lastAsk = 0

local routeAsked = {}   -- [Name-Realm] = when we sent them a J1
local routeAnswered = {} -- [Name-Realm] = when their J2 came
local gatesSaid = {}    -- [Name-Realm] = { guild, at, t }: the gates their J2 named (guild nil: none)
local askedKey = {}     -- [Name-Realm] = when we whispered them (Recruit.asked by the whole name)
local dnc = {}          -- [Name-Realm] = true: their addon said do not contact
local lastRoute = -math.huge

-- A name as the server stamps a sender: "Name-Realm".
local function Key(name) return name and ns.FullName(ns.Normal and ns.Normal(name) or name) or nil end
-- A value for the wire: none of the separators.
local function Field(s) return (tostring(s or ""):gsub("[~;=/|%c]", "")) end

-- Must be called from a click (the game requires a hardware event for /who). Each click
-- searches further once the game's 50 per search are not enough (see Who.lua).
function Recruit.Search()
	return ns.Who.Search()
end

---------------------------------------------------------------------------
-- The Join screen's side (not in a Sylvanistas guild)
---------------------------------------------------------------------------

-- The gates two members' answers agree on, while open, and the seconds left; nil while no two
-- agree (one member's word is no proof: a modified addon could name any guild).
local function ConfirmedGates(now)
	local count, left, best = {}, {}, nil
	for _, s in pairs(gatesSaid) do
		if s.guild and s.at > now and now - s.t <= Recruit.ROUTE_KEEP then
			count[s.guild] = (count[s.guild] or 0) + 1
			left[s.guild] = math.max(left[s.guild] or 0, s.at - now)
		end
	end
	for guild, n in pairs(count) do
		if n >= 2 and (not best or n > count[best] or (n == count[best] and guild < best)) then best = guild end
	end
	if best then return best, math.floor(left[best]) end
	return nil, nil
end

-- A member named gates no other answer agrees on yet.
local function GatesUnconfirmed(now)
	if ConfirmedGates(now) then return false end
	for _, s in pairs(gatesSaid) do
		if s.guild and s.at > now and now - s.t <= Recruit.ROUTE_KEEP then return true end
	end
	return false
end

-- The route the members' census gave (J2), while it is recent: { gates, gatesLeft, list =
-- { { name, free, contacts } }, byName, from, t }, or nil. Its list is the last answer's, its
-- gates the ones two answers agree on.
function Recruit.Route()
	local r, now = Recruit.route, ns.Now()
	if not r or now - (r.t or 0) > Recruit.ROUTE_KEEP then return nil end
	r.gates, r.gatesLeft = ConfirmedGates(now)
	return r
end
function Recruit.NoContact(name) return dnc[Key(name)] == true end

-- Members a J1 went to within ROUTE_FRESH.
local function AskedLately(now)
	local n = 0
	for _, t in pairs(routeAsked) do
		if now - t < Recruit.ROUTE_FRESH then n = n + 1 end
	end
	return n
end

-- Asks `name`'s addon where recruits should go (J1). A search asks one member at most every
-- ROUTE_GAP, and none twice within ROUTE_FRESH; `confirm`: a second member at once, for gates
-- only one answer named. An Ask click (`check`) asks the member it is about to whisper, and
-- again whenever he did not answer our last J1 (lost, or held back while his addon was busy),
-- so a do-not-contact flag closes the question before the player sends.
local function AskRoute(name, check, confirm)
	if ns.IsMember() or not name then return false end
	local key, now = Key(name), ns.Now()
	local asked = routeAsked[key]
	local answered = asked and (routeAnswered[key] or -math.huge) >= asked
	if asked and now - asked < Recruit.ROUTE_FRESH and (answered or not check) then return false end
	if not check and not confirm and now - lastRoute < Recruit.ROUTE_GAP then return false end
	if not ns.Comm.WhisperOutside(ns.TellName(name), "J1~1") then return false end
	routeAsked[key] = now
	if not check then lastRoute = now end
	return true
end

-- One member /who found and we never asked (nor told us do not contact), asked for a route.
local function AskAnother(confirm)
	for _, p in ipairs(Recruit.found) do
		local key = Key(p.name)
		if not routeAsked[key] and not dnc[key] then return AskRoute(p.name, false, confirm) end
	end
	return false
end

-- A round of /who answered (Who.lua): every Sylvanistas member found. Without a fresh route, one of
-- them (never asked yet) is asked for one; so is one more while only one answer named the gates
-- (ROUTE_ASKS members within ROUTE_FRESH at most).
function Recruit.OnFound(list)
	Recruit.found = list
	ns.Log("recruit: /who lists %d Sylvanistas members", #list)
	if not ns.IsMember() then
		local r, now = Recruit.Route(), ns.Now()
		if not r or now - (r.t or 0) > Recruit.ROUTE_FRESH or (GatesUnconfirmed(now) and AskedLately(now) < Recruit.ROUTE_ASKS) then
			AskAnother()
		end
	end
	ns.Fire("RECRUIT_CHANGED")
end
ns.Who.Listen(function(list) Recruit.OnFound(list) end)

-- J2 read: nil when it is not one. Only Sylvanistas guilds, sizes a guild can have, a few names.
function Recruit.ParseRoute(text)
	local flag, gates, secs, list = tostring(text):match("^J2~([yn])~([^~]*)~(%d*)~([^~]*)$")
	if not flag then return nil end
	local route = { dnc = flag == "n", list = {}, byName = {} }
	if gates ~= "" and ns.IsFederation(gates) then
		route.gates, route.gatesLeft = gates, math.min(tonumber(secs) or 0, ns.Acts and ns.Acts.GATES_TIME or 7200)
	end
	for entry in list:gmatch("[^;]+") do
		local name, free, contacts = entry:match("^([^=]+)=(%d+)=?(.*)$")
		free = tonumber(free)
		if name and ns.IsFederation(name) and free and free <= ns.Codec.GUILD_CAP and not route.byName[name] and #route.list < Recruit.ROUTE_GUILDS then
			local e = { name = name, free = free, contacts = {} }
			for c in contacts:gmatch("[^/]+") do
				if #e.contacts < Recruit.ROUTE_CONTACTS + 1 and #c <= 60 then e.contacts[#e.contacts + 1] = c end
			end
			route.list[#route.list + 1] = e
			route.byName[name] = e
		end
	end
	return route
end

-- A member's answer, heard outside a Sylvanistas guild (Comm.HandleOutside): only from one we asked.
function Recruit.OnRoute(sender, text)
	local key, now = Key(sender), ns.Now()
	if not routeAsked[key] or now - routeAsked[key] > Recruit.ROUTE_WAIT then return false end
	local route = Recruit.ParseRoute(text)
	if not route then return false end
	routeAnswered[key] = now
	-- The gates as this member says them (none, too): shown once another answer agrees (Route).
	gatesSaid[key] = { guild = route.gates, at = now + (route.gatesLeft or 0), t = now }
	local claimed = route.gates
	route.gates, route.gatesLeft = nil, nil
	if route.dnc then
		dnc[key] = true
		-- The request about to go to them: closed before the player sends it.
		local pending = Recruit.pending
		if pending and Key(pending.name) == key then
			Recruit.pending = nil
			ns.HideDialog("SYLVANISTAS_RECRUIT")
			ns.Print(L.RECRUIT_DNC:format(ns.DisplayName(key) or sender))
		end
	end
	-- An answer naming no guild (a do-not-contact member's bare "no") keeps what an earlier one
	-- said; its gates count all the same.
	if #route.list > 0 or not Recruit.Route() then
		route.from, route.t = key, now
		Recruit.route = route
	end
	-- Gates only one answer named: one more member asked at once, whose answer agrees or not.
	if GatesUnconfirmed(now) and AskedLately(now) < Recruit.ROUTE_ASKS then AskAnother(true) end
	ns.Log("recruit: route from %s (gates %s, %d guilds%s)", key, tostring(claimed), #route.list, route.dnc and ", do not contact" or "")
	ns.Fire("RECRUIT_CHANGED")
	return true
end
ns.Comm.HandleOutside(Recruit.OnRoute)

-- Whom this round of /who found in `guild` by that name, or nil: the server's word that he is
-- there. A name without its realm (a member names those of his own realm so) matches by name.
local function FoundIn(name, guild)
	if type(name) ~= "string" or name == "" then return nil end
	local key, bare = Key(name), not ns.RealmOf(name)
	local short = ns.ShortName(key)
	for _, p in ipairs(Recruit.found) do
		local pk = Key(p.name)
		if p.guild == guild and (pk == key or (bare and ns.ShortName(pk) == short)) then return p end
	end
	return nil
end
local function Found(guild)
	for _, p in ipairs(Recruit.found) do
		if p.guild == guild then return true end
	end
	return false
end

-- The route's guilds in its order: the gates' first (two answers agree on them), then the most
-- free slots, each once /who found one of its members (none: nobody there to ask).
local function RouteOrder(route)
	local out = {}
	if route.gates then out[1] = route.gates end
	for _, e in ipairs(route.list) do
		if e.name ~= route.gates and Found(e.name) then out[#out + 1] = e.name end
	end
	return out
end
Recruit.RouteOrder = RouteOrder

-- Guilds seen online, the gates' guild first, then the most free slots (a route known), then
-- the most seen: { name, online = n, members = {...}, free }
function Recruit.Guilds()
	local by, out = {}, {}
	for _, p in ipairs(Recruit.found) do
		local g = by[p.guild]
		if not g then
			g = { name = p.guild, members = {} }
			by[p.guild] = g
			out[#out + 1] = g
		end
		g.members[#g.members + 1] = p
	end
	local route = Recruit.Route()
	for _, g in ipairs(out) do
		local e = route and route.byName[g.name]
		g.free = e and e.free or nil
		g.gates = route and route.gates == g.name or false
	end
	table.sort(out, function(a, b)
		if a.gates ~= b.gates then return a.gates end
		local fa, fb = a.free or -1, b.free or -1
		if fa ~= fb then return fa > fb end
		if #a.members ~= #b.members then return #a.members > #b.members end
		return a.name < b.name
	end)
	return out
end

local function Asked(name) return Recruit.asked[name] or askedKey[Key(name)] end

-- The next member of that guild we have not asked yet (any guild if nil): its officers the
-- route named first, once /who found them in it (whispered by the server's name), then anyone
-- /who found; never one who asked not to be contacted. No guild: the gates' guild first, then
-- the most room, then anyone found.
function Recruit.NextContact(guild)
	local route = Recruit.Route()
	if guild then
		local e = route and route.byName[guild]
		for _, c in ipairs(e and e.contacts or {}) do
			local p = FoundIn(c, guild)
			if p and not Asked(c) and not Asked(p.name) and not dnc[Key(c)] and not dnc[Key(p.name)] then
				return { name = p.name, guild = guild, officer = true }
			end
		end
	elseif route then
		for _, name in ipairs(RouteOrder(route)) do
			local c = Recruit.NextContact(name)
			if c then return c end
		end
	end
	for _, p in ipairs(Recruit.found) do
		if (not guild or p.guild == guild) and not Asked(p.name) and not dnc[Key(p.name)] then return p end
	end
	return nil
end

function Recruit.Message(contact)
	local level = UnitLevel("player")
	local className = UnitClass("player") or ""
	return L.RECRUIT_MESSAGE:format(contact.guild, level, className)
end

-- Sends the (edited) request: one whisper, from the popup's Send button, i.e. by the player; its
-- J3 goes with it to the same member, so an officer's addon shows it with Invite and Decline.
function Recruit.Ask(contact, message)
	local now = GetTime()
	if now - Recruit.lastAsk < ASK_COOLDOWN then
		ns.Print(L.RECRUIT_WAIT:format(math.ceil(ASK_COOLDOWN - (now - Recruit.lastAsk))))
		return false
	end
	if not contact or not message or message == "" then return false end
	if dnc[Key(contact.name)] then
		ns.Print(L.RECRUIT_DNC:format(ns.DisplayName(Key(contact.name)) or contact.name))
		return false
	end
	Recruit.lastAsk = now
	Recruit.asked[contact.name] = ns.Now()
	askedKey[Key(contact.name)] = ns.Now()
	Recruit.lastContact = contact
	Recruit.pending = nil
	local to = ns.TellName(contact.name)
	SendChatMessage(message:sub(1, 250), "WHISPER", nil, to)
	local _, classFile = UnitClass("player")
	ns.Comm.WhisperOutside(to, ("J3~%s~%d~%s"):format(Field(contact.guild), tonumber(UnitLevel("player")) or 0, Field(classFile)))
	ns.Log("recruit: asked %s <%s>", contact.name, contact.guild)
	ns.Fire("RECRUIT_CHANGED")
	return true
end

-- The request to `contact`, written in a box the player can edit (Send is the click), and that
-- member's addon asked first whether they take recruit whispers.
function Recruit.Prompt(contact)
	if not contact then return nil end
	Recruit.pending = contact
	AskRoute(contact.name, true)
	return ns.ShowDialog("SYLVANISTAS_RECRUIT", contact.name, contact.guild, contact)
end

function Recruit.PromptNext(guild)
	local contact = Recruit.NextContact(guild)
	if not contact then
		ns.Print(#Recruit.found == 0 and L.RECRUIT_SEARCH_FIRST or L.RECRUIT_NOBODY_LEFT)
		return
	end
	return Recruit.Prompt(contact)
end

-- The tone of the Join screen, in the spirit of Sylvanistas: other guilds should not exist.
function Recruit.Roast()
	local guild = GetGuildInfo("player")
	if guild and guild ~= "" then
		return L.ROAST_GUILD:format(guild), L.ROAST_GUILD_SUB
	end
	return L.ROAST_NOGUILD, L.ROAST_NOGUILD_SUB
end

-- Once a day, a reminder in chat for players outside Sylvanistas.
local function DailyNag()
	if ns.IsMember() then return end
	local today = date("%Y-%m-%d")
	if ns.db.lastNag == today then return end
	ns.db.lastNag = today
	local header, sub = Recruit.Roast()
	ns.Print("|cffff4040" .. header .. "|r " .. sub .. " |cffffd200/syl|r")
end

---------------------------------------------------------------------------
-- The members' side (in a Sylvanistas guild)
---------------------------------------------------------------------------

-- Do not contact (Fern's #20): recruits' addons are told, and never offer us.
function Recruit.NoContactMe() return ns.db and ns.db.recruitsOff == true end
function Recruit.SetNoContact(on)
	ns.db.recruitsOff = on and true or nil
	ns.Print(on and L.NOCONTACT_ON or L.NOCONTACT_OFF)
	ns.Fire("DATA_CHANGED")
end

-- The guilds with room we name to recruits, the most free slots first: those the census does
-- not mark (Data.Dispute: two senders or more agree on them; ours, our roster, never is). A
-- guild one sender alone stands behind, or whose senders disagree, is nobody's advice.
function Recruit.OpenGuilds()
	local out = {}
	for _, o in ipairs(ns.Views.OpenGuilds(ns.Data.Summary())) do
		if ns.Data.Dispute(o.e.g) == nil then out[#out + 1] = o end
	end
	return out
end

-- Up to ROUTE_CONTACTS Lords and Captains online of a guild with room, to name to a recruit:
-- our own guild's from our roster, another's from its report, where two senders name them to
-- that rank (Data.KnownRank). Never the King (the most asked of all), and never ourselves while
-- we ask not to be contacted.
local function Contacts(o, own)
	local g, out = o.e.g, {}
	local function Add(name, realm)
		if #out >= Recruit.ROUTE_CONTACTS or type(name) ~= "string" or name == "" then return end
		local full = ns.FullName(name, realm)
		if ns.IsKingCharacter and ns.IsKingCharacter(name) then return end
		if full == ns.me and Recruit.NoContactMe() then return end
		out[#out + 1] = Field(ns.DisplayName(full))
	end
	if own and o.name == own then
		for _, m in ipairs(ns.Roster.online or {}) do
			if (m.rankIndex or 9) <= ns.CAPTAIN_RANK then Add(m.name) end
		end
	else
		local function Named(name, rank)
			if type(name) ~= "string" or name == "" then return false end
			local k, senders = ns.Data.KnownRank(ns.FullName(name, g.realm), o.name)
			return k == rank and (senders or 0) >= 2
		end
		if g.leaderOnline and Named(g.leader, 0) then Add(g.leader, g.realm) end
		for _, of in ipairs(g.officers or {}) do
			if of.online and Named(of.name, 1) then Add(of.name, g.realm) end
		end
	end
	return out
end

-- Our answer to a J1: our flag, the gates, and the guilds with the most room (the gates' first),
-- as many as fit one addon message.
function Recruit.RouteAnswer()
	local gates = ns.Acts and ns.Acts.Gates and ns.Acts.Gates()
	local msg = ("J2~%s~%s~%d~"):format(Recruit.NoContactMe() and "n" or "y", gates and Field(gates.guild) or "",
		gates and math.max(0, math.floor(gates.at - ns.Now())) or 0)
	local open = Recruit.OpenGuilds()
	for i, o in ipairs(open) do
		if gates and o.name == gates.guild then
			table.insert(open, 1, table.remove(open, i))
			break
		end
	end
	local own, n = GetGuildInfo("player"), 0
	for _, o in ipairs(open) do
		local entry = Field(o.name) .. "=" .. o.free .. "=" .. table.concat(Contacts(o, own), "/")
		local add = (n > 0 and ";" or "") .. entry
		if #msg + #add <= 250 then
			msg, n = msg .. add, n + 1
			if n >= Recruit.ROUTE_GUILDS then break end
		end
	end
	return msg
end

-- Our answer to a J1, ANSWER_MAX a minute in all. Do not contact holds whatever the load: past
-- ANSWER_MAX we still answer each asker once a minute, a bare "no" (outside the count), or the
-- recruit's screen, left without an answer, would offer us.
Recruit.DNC_ANSWER = "J2~n~~0~"
local answeredAt, answers = {}, {} -- [asker] = when; times of our answers this last minute
function Recruit.OnRouteAsk(dist, sender, text)
	if dist ~= "WHISPER" or not ns.IsMember() then return false end
	local now = ns.Now()
	if answeredAt[sender] and now - answeredAt[sender] < Recruit.ANSWER_EACH then return false end
	for i = #answers, 1, -1 do
		if now - answers[i] >= 60 then table.remove(answers, i) end
	end
	local room = #answers < Recruit.ANSWER_MAX
	if not room and not Recruit.NoContactMe() then return false end
	for name, t in pairs(answeredAt) do
		if now - t >= Recruit.ANSWER_EACH then answeredAt[name] = nil end
	end
	answeredAt[sender] = now
	if room then answers[#answers + 1] = now end
	ns.Comm.Whisper(sender, room and Recruit.RouteAnswer() or Recruit.DNC_ANSWER, nil, true)
	ns.Log("recruit: told %s %s", sender, room and "where to go" or "do not contact")
	return true
end
ns.Comm.Handle("J1", Recruit.OnRouteAsk)

-- Join requests (J3) to us: newest last. { name, guild, level, class, t, text }
Recruit.requests = {}
local requestAt, lineTimes, whispers = {}, {}, {}

local function Prune(now)
	for i = #Recruit.requests, 1, -1 do
		if now - Recruit.requests[i].t > Recruit.REQUEST_TTL then table.remove(Recruit.requests, i) end
	end
	for name, t in pairs(requestAt) do
		if now - t > Recruit.REQUEST_EACH then requestAt[name] = nil end
	end
end
local function Drop(req)
	for i, r in ipairs(Recruit.requests) do
		if r == req then table.remove(Recruit.requests, i) break end
	end
	ns.Fire("DATA_CHANGED")
end

function Recruit.OnJoinRequest(dist, sender, text)
	if dist ~= "WHISPER" or not ns.IsMember() then return false end
	local guild, level, class = tostring(text):match("^J3~([^~]+)~(%d+)~(%u*)$")
	local own = GetGuildInfo("player")
	if not guild or not own or guild:lower() ~= own:lower() then return false end
	if ns.Roster.RankOf(sender) then return false end -- one of us already
	local now = ns.Now()
	Prune(now)
	if requestAt[sender] then return false end
	requestAt[sender] = now
	for i, r in ipairs(Recruit.requests) do
		if r.name == sender then table.remove(Recruit.requests, i) break end
	end
	if #Recruit.requests >= Recruit.REQUESTS_MAX then table.remove(Recruit.requests, 1) end
	level = tonumber(level)
	local w = whispers[sender]
	local req = { name = sender, guild = own, level = level and level >= 1 and level <= 100 and level or nil,
		class = class ~= "" and #class <= 12 and class or nil, t = now, text = w and now - w.t <= 120 and w.text or nil }
	Recruit.requests[#Recruit.requests + 1] = req
	-- One chat line, REQUEST_LINES a minute at most (the rest wait in the Census).
	for i = #lineTimes, 1, -1 do
		if now - lineTimes[i] >= 60 then table.remove(lineTimes, i) end
	end
	if #lineTimes < Recruit.REQUEST_LINES then
		lineTimes[#lineTimes + 1] = now
		local className = req.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[req.class] or ""
		ns.Print(L.JOIN_ASKED:format(ns.DisplayName(sender) or sender, req.level or 0, className, own))
	end
	ns.Log("recruit: %s asks to join %s", sender, own)
	ns.Fire("DATA_CHANGED")
	return true
end
ns.Comm.Handle("J3", Recruit.OnJoinRequest)

local function CanInvite() return type(CanGuildInvite) == "function" and CanGuildInvite() and true or false end
Recruit.CanInvite = CanInvite

-- An officer's yes: the game's own guild invite, from the click.
function Recruit.Accept(req)
	if not CanInvite() or type(req) ~= "table" then return false end
	local invite = (C_GuildInfo and C_GuildInfo.Invite) or GuildInvite
	if type(invite) ~= "function" then return false end
	invite(ns.TellName(req.name))
	ns.Print(L.JOIN_INVITED:format(ns.DisplayName(req.name) or req.name, req.guild))
	Drop(req)
	return true
end

-- Where to send one we can't take: the gates' guild while the King's gates are open, else only
-- ours (the Join screen shows who has room). Never a guild named for its free slots (Konig's
-- review of 1.1: the top "most room" guild is one two characters can fake, and this whisper goes
-- from the officer's own chat).
function Recruit.DeclineText(req)
	local own = GetGuildInfo("player")
	local gates = ns.Acts and ns.Acts.Gates and ns.Acts.Gates()
	local other = gates and gates.guild ~= own and gates.guild or nil
	if other then return L.JOIN_DECLINE_TEXT:format(own or "?", other) end
	return L.JOIN_DECLINE_TEXT_PLAIN:format(own or "?")
end

-- An officer's no: one whisper, from the click, pointing where there is room.
function Recruit.Decline(req)
	if not CanInvite() or type(req) ~= "table" then return false end
	SendChatMessage(Recruit.DeclineText(req), "WHISPER", nil, ns.TellName(req.name))
	Drop(req)
	return true
end

-- Someone who can't invite: an officer of ours online to point to (never ourselves).
function Recruit.Officer()
	for _, m in ipairs(ns.Roster.online or {}) do
		if (m.rankIndex or 9) <= ns.CAPTAIN_RANK and ns.FullName(m.name) ~= ns.me then return m.name end
	end
	return nil
end
function Recruit.Point(req)
	local officer = Recruit.Officer()
	if not officer or type(req) ~= "table" then return false end
	SendChatMessage(L.JOIN_POINT_TEXT:format(officer), "WHISPER", nil, ns.TellName(req.name))
	Drop(req)
	return true
end
function Recruit.Dismiss(req) Drop(req) end

-- The requests on top of the Census: an officer's Invite and Decline, one click each; anyone
-- else's pointer to an officer online. Dismiss sends nothing.
function Recruit.RequestLines()
	if not ns.IsMember() then return {} end
	Prune(ns.Now())
	local reqs = Recruit.requests
	if #reqs == 0 then return {} end
	local V = ns.Views
	local lines = { {
		header = true, text = L.JOIN_REQUESTS:format(#reqs),
		tooltip = function(tt)
			tt:AddLine(L.JOIN_REQUESTS:format(#reqs), 1, 0.82, 0)
			tt:AddLine(L.JOIN_REQUESTS_TIP, 1, 1, 1, true)
		end,
	} }
	local canInvite, officer = CanInvite(), Recruit.Officer()
	for i = #reqs, math.max(1, #reqs - Recruit.REQUESTS_SHOWN + 1), -1 do
		local req = reqs[i]
		local who = ns.DisplayName(req.name) or req.name
		local className = req.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[req.class] or ""
		lines[#lines + 1] = {
			text = V.ClassColored(who, req.class) .. "  " .. V.Grey(L.LEVEL_N:format(req.level or 0) .. " " .. className),
			right = V.Grey(ns.Ago(req.t)),
			tooltip = function(tt)
				tt:AddLine(L.JOIN_ASKED_TIP:format(who, req.guild), 1, 0.82, 0, true)
				if req.text then tt:AddLine('"' .. ns.Codec.SanitizeChat(req.text) .. '"', 1, 1, 1, true) end
			end,
		}
		if canInvite then
			lines[#lines + 1] = { indent = 1, text = V.Green(L.JOIN_INVITE:format(req.guild)), onClick = function() Recruit.Accept(req) end }
			lines[#lines + 1] = {
				indent = 1, text = V.Gold(L.JOIN_DECLINE), onClick = function() Recruit.Decline(req) end,
				tooltip = function(tt)
					tt:AddLine(L.JOIN_DECLINE_TIP, 1, 0.82, 0, true)
					tt:AddLine('"' .. Recruit.DeclineText(req) .. '"', 1, 1, 1, true)
				end,
			}
		elseif officer then
			lines[#lines + 1] = {
				indent = 1, text = V.Gold(L.JOIN_POINT:format(officer)), onClick = function() Recruit.Point(req) end,
				tooltip = function(tt) tt:AddLine('"' .. L.JOIN_POINT_TEXT:format(officer) .. '"', 1, 1, 1, true) end,
			}
		end
		lines[#lines + 1] = { indent = 1, text = V.Grey(L.JOIN_DISMISS), onClick = function() Recruit.Dismiss(req) end }
	end
	if #reqs > Recruit.REQUESTS_SHOWN then lines[#lines + 1] = { indent = 1, text = V.Grey(L.JOIN_MORE:format(#reqs - Recruit.REQUESTS_SHOWN)) } end
	lines[#lines].gapAfter = true
	return lines
end

function Recruit.ResetForTests()
	wipe(routeAsked); wipe(routeAnswered); wipe(gatesSaid); wipe(askedKey); wipe(dnc); wipe(answeredAt); wipe(answers); wipe(requestAt)
	wipe(lineTimes); wipe(whispers)
	lastRoute = -math.huge
	Recruit.route, Recruit.pending, Recruit.lastAsk, Recruit.lastContact = nil, nil, 0, nil
	Recruit.found, Recruit.asked, Recruit.replied, Recruit.requests = {}, {}, {}, {}
end

-- A whisper came in. Outside Sylvanistas: a member we asked answered. In it: kept a moment for the
-- join request (J3) that follows a recruit's whisper, shown with it.
function Recruit.OnWhisper(text, sender)
	if ns.IsMember() then
		local now = ns.Now()
		local key = Key(sender)
		if key and not whispers[key] then
			local n = 0
			for name, w in pairs(whispers) do
				if now - w.t > 120 then whispers[name] = nil else n = n + 1 end
			end
			if n >= 30 then return end
		end
		if key then whispers[key] = { text = text, t = now } end
		return
	end
	local who = ns.ShortName(sender)
	for name in pairs(Recruit.asked) do
		if ns.ShortName(name) == who then
			Recruit.replied[name] = text
			ns.Print(L.RECRUIT_REPLIED:format(who))
			ns.Fire("RECRUIT_CHANGED")
			return
		end
	end
end

ns.On("LOGIN", function()
	ns.After(12, "daily nag", DailyNag)
	ns.RegisterEvent("CHAT_MSG_WHISPER", function(text, sender) Recruit.OnWhisper(text, sender) end)
end)

StaticPopupDialogs["SYLVANISTAS_RECRUIT"] = {
	text = "%s  <%s>",
	button1 = SEND_LABEL or "Send",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 320,
	maxLetters = 250,
	OnShow = function(self, contact)
		local eb = self.editBox or self.EditBox
		if eb and contact then
			eb:SetText(Recruit.Message(contact))
			eb:HighlightText(0, 0)
			eb:SetFocus()
		end
	end,
	OnAccept = function(self, contact)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("recruit ask", Recruit.Ask, contact, eb and eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		ns.SafeCall("recruit ask", Recruit.Ask, parent.data, self:GetText())
		parent:Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
