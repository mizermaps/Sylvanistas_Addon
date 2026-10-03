local ADDON, ns = ...
local L = ns.L

-- Tabard Inspection: inspects nearby Sylvanistas members and records whether they wear a
-- tabard. "Patrol" mode scans target, mouseover, party/raid and friendly nameplates on
-- its own; officers can also mark any player or whole guild by hand. Results are kept in
-- SylvanistasDB.inspect and can be copied to Discord.

local Inspect = {}
ns.Inspect = Inspect

local TABARD_SLOT = INVSLOT_TABARD or 19
Inspect.GUILD_TABARDS = { [5976] = true } -- "Guild Tabard"
local RECHECK = 10 * 60   -- do not re-inspect the same player on patrol for 10 minutes
local INTERVAL = 1.5      -- one inspect request at a time, spaced out
local TIMEOUT = 4

local STATUS_ORDER = { NONE = 1, OTHER = 2, UNKNOWN = 3, UNCHECKED = 4, GUILD = 5 }
Inspect.STATUS_ORDER = STATUS_ORDER

local patrol = false
local queue, queued = {}, {}
local pending -- { guid, unit, at }
-- During a Royal Inspection: at most one request every `pace` seconds (King.INSPECT_PACE).
local pace, lastRequest = nil, -math.huge
function Inspect.SetPace(seconds) pace = seconds end
Inspect.stats = { requests = 0, ready = 0, timeouts = 0 }

-- Kept per realm (ns.rdb): the players of one realm say nothing about another one.
local function Store()
	local db = ns.rdb
	db.inspect = db.inspect or {}
	db.inspect.players = db.inspect.players or {}
	db.inspect.guildMarks = db.inspect.guildMarks or {}
	return db.inspect
end

local Source = Store

-- Every player a patrol ever checked stays in the saved variables, and the Tabards tab draws a
-- line for each: after a few weeks of patrols in a crowded capital that is thousands. Kept:
-- the last MAX_AGE, and at most MAX_PLAYERS of them, the ones that matter first (marked by
-- hand, then caught without the colors), then the newest. A mark by hand stays past MAX_AGE.
Inspect.MAX_AGE = 14 * 86400
Inspect.MAX_PLAYERS = 2000
local function Keep(p)
	if p.marked then return 1 end
	if p.status == "NONE" or p.status == "OTHER" or p.gear then return 2 end
	return 3
end
function Inspect.Prune()
	local players, now, n = Store().players, ns.Now(), 0
	for name, p in pairs(players) do
		local age = now - (tonumber(type(p) == "table" and p.t) or 0)
		-- (1.1: another officer's word lasts SHARE_KEEP; our own inspections MAX_AGE.)
		if type(p) ~= "table" or (not p.marked and (age > Inspect.MAX_AGE or (p.shared and not p.gear and age > Inspect.SHARE_KEEP))) then
			players[name] = nil
		else
			n = n + 1
		end
	end
	if n <= Inspect.MAX_PLAYERS then return end
	local list = {}
	for name, p in pairs(players) do list[#list + 1] = { name = name, keep = Keep(p), t = tonumber(p.t) or 0 } end
	table.sort(list, function(a, b)
		if a.keep ~= b.keep then return a.keep < b.keep end
		if a.t ~= b.t then return a.t > b.t end
		return a.name < b.name
	end)
	for i = Inspect.MAX_PLAYERS + 1, #list do players[list[i].name] = nil end
end

-- The gear an officer's click kept (1.1, request #28): at most GEAR_MAX players carry it, the
-- oldest gear dropped first (the player's inspection stays).
Inspect.GEAR_MAX = 200
function Inspect.PruneGear()
	local list = {}
	for name, p in pairs(Store().players) do
		if type(p) == "table" and p.gear ~= nil then
			if type(p.gear) ~= "table" or type(p.gear.items) ~= "table" then p.gear = nil
			else list[#list + 1] = { name = name, t = tonumber(p.gear.t) or 0 } end
		end
	end
	if #list <= Inspect.GEAR_MAX then return end
	table.sort(list, function(a, b)
		if a.t ~= b.t then return a.t > b.t end
		return a.name < b.name
	end)
	for i = Inspect.GEAR_MAX + 1, #list do Store().players[list[i].name].gear = nil end
end

-- itemID nil + some other gear visible = really no tabard. Nothing visible at all usually
-- means the inspect data did not load, so we call it UNKNOWN instead of accusing anyone.
function Inspect.Classify(tabardID, anyGearVisible)
	if tabardID then return Inspect.GUILD_TABARDS[tabardID] and "GUILD" or "OTHER" end
	return anyGearVisible and "NONE" or "UNKNOWN"
end

function Inspect.IsPatrolling() return patrol end

-- Everyone inspected on this realm group (the Throne's Royal Inspection reads it).
function Inspect.Players() return Store().players end

-- A player another addon reported during a Royal Inspection (King.lua): kept like
-- our own inspections, so the usual Wall of Shame can publish them.
-- One key per player in the store: "Name" for our realm, "Name-Realm" for another, whatever
-- the name came from (a unit, a report, what 0.8.1 saved). On Forever, "First Surname".
local function Key(name)
	if type(name) ~= "string" or name == "" then return nil end
	return ns.DisplayName(ns.FullName(ns.Normal(name)))
end
Inspect.Key = Key

function Inspect.AddReported(name, guild, status)
	name = Key(name)
	if type(name) ~= "string" or name == "" then return end
	local p = Store().players[name] or {}
	p.name, p.guild, p.status, p.t, p.reported = name, guild, status, ns.Now(), true
	-- (The Royal Inspection's report, not another officer's word any more: 1.1.)
	p.shared, p.by = nil, nil
	Store().players[name] = p
	ns.Fire("INSPECT_CHANGED")
end

-- The Sylvanistas rule: the tabard is required from this level on. Younger players are never
-- flagged (nor inspected on patrol).
Inspect.MIN_LEVEL = 15
local function TooYoung(level) return type(level) == "number" and level > 0 and level < Inspect.MIN_LEVEL end

local QueueShare -- (1.1, below: an officer's own finding, for his guild's officers)

function Inspect.Record(name, guild, classFile, level, tabardID, anyGear)
	name = Key(name)
	if not name then return nil end
	local s = Store()
	local p = s.players[name] or {}
	local previous = p.status
	p.name, p.guild, p.class, p.level = name, guild, classFile, level
	p.item = tabardID
	p.status = Inspect.Classify(tabardID, anyGear)
	if TooYoung(level) and (p.status == "NONE" or p.status == "OTHER") then p.status = "YOUNG" end
	p.t = ns.Now()
	-- Seen with our own eyes now: no longer another officer's word (1.1).
	local wasShared = p.shared
	p.shared, p.by = nil, nil
	s.players[name] = p
	if QueueShare then QueueShare(p, previous, wasShared) end
	ns.Log("inspect %s <%s>: %s (%s)", name, tostring(guild), p.status, tostring(tabardID))
	if (p.status == "NONE" or p.status == "OTHER") and previous ~= p.status then
		local label = p.status == "NONE" and L.TABARD_NONE or L.TABARD_OTHER
		ns.Print(("|cffff4040%s|r <%s>: %s"):format(ns.ShortName(name), guild or "?", label))
		ns.PlayAlert("soft", "patrol")
	end
	if not previous then Inspect.Prune() end -- (only a new player makes the store grow)
	ns.Fire("INSPECT_CHANGED")
	return p
end

-- gear (1.1): an officer's click asks for the gear too (Inspect.InspectGear); the same queue and
-- pace as every other request, first in line.
local function Enqueue(unit, force, gear)
	if not UnitExists(unit) or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end
	local guid = UnitGUID(unit)
	if not guid then return end
	if gear then
		-- Already waiting (a patrol's) or asked: that request brings the gear too.
		if pending and pending.guid == guid then pending.gear = true return end
		for i, item in ipairs(queue) do
			if item.guid == guid then
				table.remove(queue, i)
				item.gear, item.unit = true, unit
				table.insert(queue, 1, item)
				return
			end
		end
	end
	if queued[guid] or (pending and pending.guid == guid) then return end
	local guild = GetGuildInfo(unit)
	if not force and not ns.IsFederation(guild) then return end
	-- Sylvanistas guilds of the other faction are not ours to inspect (the Horde has its own too).
	if not force and UnitFactionGroup and UnitFactionGroup(unit) ~= UnitFactionGroup("player") then return end
	if not force and TooYoung(UnitLevel(unit)) then return end
	if not force then
		local p = Store().players[Key(ns.UnitFullName(unit))]
		if p and p.status ~= "UNKNOWN" and p.status ~= "UNCHECKED" and ns.Now() - (p.t or 0) < RECHECK then return end
	end
	queued[guid] = true
	table.insert(queue, force and 1 or #queue + 1, { unit = unit, guid = guid, gear = gear or nil })
end

local function ScanNearby()
	Enqueue("target")
	Enqueue("mouseover")
	if IsInRaid() then
		for i = 1, 40 do Enqueue("raid" .. i) end
	else
		for i = 1, 4 do Enqueue("party" .. i) end
	end
	for i = 1, 40 do
		local unit = "nameplate" .. i
		if UnitExists(unit) then Enqueue(unit) end
	end
end

local function Pump()
	if pending then
		if GetTime() - pending.at < TIMEOUT then return end
		Inspect.stats.timeouts = Inspect.stats.timeouts + 1
		pending = nil
	end
	if InCombatLockdown() then return end
	if InspectFrame and InspectFrame:IsShown() then return end -- the player is inspecting by hand
	if pace and GetTime() - lastRequest < pace then return end
	if patrol then ScanNearby() end
	while #queue > 0 do
		local item = table.remove(queue, 1)
		queued[item.guid] = nil
		local unit = item.unit
		if UnitGUID(unit) == item.guid and CanInspect(unit) and CheckInteractDistance(unit, 1) then
			pending = { guid = item.guid, unit = unit, at = GetTime(), gear = item.gear }
			lastRequest = GetTime()
			Inspect.stats.requests = Inspect.stats.requests + 1
			NotifyInspect(unit)
			return
		end
	end
end
Inspect.Pump = Pump -- (tests)

local function FindUnit(guid, hint)
	if hint and UnitGUID(hint) == guid then return hint end
	for _, u in ipairs({ "target", "mouseover", "focus" }) do
		if UnitGUID(u) == guid then return u end
	end
	for i = 1, 40 do
		if UnitGUID("nameplate" .. i) == guid then return "nameplate" .. i end
	end
	return nil
end

-- The items a unit wears, as the inspection gave them (1.1): slot -> the item's own string (its id,
-- enchant and suffix, "item:19019:..."; its id alone when the client gave no link yet). What did not
-- load is left out, never guessed. Nothing else: no item level, no score.
local GEAR_SLOTS = 19
local function ReadGear(unit)
	local items, n = {}, 0
	for slot = 1, GEAR_SLOTS do
		local link = GetInventoryItemLink and GetInventoryItemLink(unit, slot)
		local item = type(link) == "string" and link:match("item:[%-%d:]+") or nil
		if item then item = item:gsub(":+$", "") end
		if not item then
			local id = GetInventoryItemID(unit, slot)
			if type(id) == "number" and id > 0 then item = "item:" .. math.floor(id) end
		end
		if item and #item <= 120 then items[slot], n = item, n + 1 end
	end
	return items, n
end

local function OnInspectReady(guid)
	if not pending or pending.guid ~= guid then return end
	local unit = FindUnit(guid, pending.unit)
	local gear = pending.gear
	pending = nil
	Inspect.stats.ready = Inspect.stats.ready + 1
	if unit then
		local anyGear = false
		for slot = 1, 18 do
			if GetInventoryItemID(unit, slot) then anyGear = true break end
		end
		local _, classFile = UnitClass(unit)
		local name = ns.UnitFullName(unit)
		local p = Inspect.Record(name, GetGuildInfo(unit), classFile, UnitLevel(unit),
			GetInventoryItemID(unit, TABARD_SLOT), anyGear)
		-- An officer's click (Inspect.InspectGear): the gear kept with the inspection.
		if gear and p then
			local items, n = ReadGear(unit)
			if n > 0 then
				p.gear = { t = ns.Now(), items = items }
				Inspect.PruneGear()
				ns.Print(L.GEAR_SAVED:format(ns.ShortName(p.name), n))
				ns.Fire("INSPECT_CHANGED")
			else
				ns.Print(L.GEAR_NOT_LOADED:format(ns.ShortName(p.name)))
			end
		end
	elseif gear then
		ns.Print(L.GEAR_GONE)
	end
	if not (InspectFrame and InspectFrame:IsShown()) and ClearInspectPlayer then ClearInspectPlayer() end
end
Inspect.OnInspectReady = OnInspectReady -- (tests)

function Inspect.SetPatrol(on)
	if on and not ns.IsMember() then
		ns.Print(L.MEMBERS_ONLY)
		return
	end
	patrol = on and true or false
	ns.Print(patrol and L.PATROL_ON or L.PATROL_OFF)
	ns.Log("patrol = %s", tostring(patrol))
	ns.Fire("INSPECT_CHANGED")
end

function Inspect.InspectTarget()
	if not UnitIsPlayer("target") then
		ns.Print(L.NEED_PLAYER_TARGET)
		return
	end
	Enqueue("target", true)
	Pump()
end

-- 1.1 (request #28): an officer's click keeps the gear of the player he targets, in range, as the
-- game's inspection shows it: one request in the same queue and pace as the patrol's (one
-- NotifyInspect at a time, never in combat or while the game's inspect window is open). Kept in
-- his saved variables with the inspection, for a raid signup days later without pulling the player
-- again. Nothing scored, nothing sent, nobody told how to play. Officers: the guild master and the
-- officer rank right below (Roster.IsOfficer).
function Inspect.InspectGear()
	if not ns.IsMember() then return ns.Print(L.MEMBERS_ONLY) end
	if not ns.Roster.IsOfficer() then return ns.Print(L.GEAR_OFFICERS_ONLY) end
	if not UnitIsPlayer("target") or UnitIsUnit("target", "player") then return ns.Print(L.NEED_PLAYER_TARGET) end
	local name = ns.ShortName(ns.UnitFullName("target") or "?")
	-- (In combat the game keeps the distance to itself: the request waits in line, and the pump
	-- looks at the range once the fight is over, as for every inspection.)
	local fighting = InCombatLockdown and InCombatLockdown()
	if not fighting and (not CanInspect("target") or not CheckInteractDistance("target", 1)) then return ns.Print(L.GEAR_OUT_OF_RANGE:format(name)) end
	Enqueue("target", true, true)
	ns.Print(L.GEAR_ASKING:format(name))
	Pump()
end

-- The players whose gear is kept, newest first: { { name, guild, class, level, t, items } }.
function Inspect.GearList()
	local out = {}
	for _, p in pairs(Source().players) do
		if type(p) == "table" and type(p.gear) == "table" and type(p.gear.items) == "table" then
			out[#out + 1] = { name = p.name, guild = p.guild, class = p.class, level = p.level, t = tonumber(p.gear.t) or 0, items = p.gear.items }
		end
	end
	table.sort(out, function(a, b)
		if a.t ~= b.t then return a.t > b.t end
		return tostring(a.name) < tostring(b.name)
	end)
	return out
end

function Inspect.MarkTarget(note)
	if not UnitIsPlayer("target") then
		ns.Print(L.NEED_PLAYER_TARGET)
		return
	end
	local name = Key(ns.UnitFullName("target"))
	local s = Store()
	local p = s.players[name] or { name = name, status = "UNCHECKED", t = ns.Now() }
	local _, classFile = UnitClass("target")
	p.guild, p.class, p.level = GetGuildInfo("target"), classFile, UnitLevel("target")
	p.marked = true
	if note and note ~= "" then p.note = note end
	s.players[name] = p
	ns.Print(L.MARKED:format(ns.ShortName(name), p.guild or "?"))
	Enqueue("target", true)
	ns.Fire("INSPECT_CHANGED")
end

function Inspect.ToggleMark(name)
	local p = Source().players[Key(name)]
	if not p then return end
	p.marked = not p.marked
	ns.Fire("INSPECT_CHANGED")
end

function Inspect.ToggleGuildMark(guild)
	local marks = Source().guildMarks
	marks[guild] = not marks[guild] or nil
	ns.Fire("INSPECT_CHANGED")
end

function Inspect.Clear()
	local s = Store()
	wipe(s.players)
	wipe(s.guildMarks)
	ns.Fire("INSPECT_CHANGED")
end

function Inspect.Summary()
	local src = Source()
	local out = { players = {}, guilds = {}, counts = { GUILD = 0, OTHER = 0, NONE = 0, UNKNOWN = 0, UNCHECKED = 0 }, total = 0 }
	local byGuild = {}
	for _, p in pairs(src.players) do
		out.players[#out.players + 1] = p
		out.total = out.total + 1
		out.counts[p.status] = (out.counts[p.status] or 0) + 1
		local gname = p.guild or "?"
		local g = byGuild[gname]
		if not g then
			g = { name = gname, total = 0, bad = 0, marked = src.guildMarks[gname] and true or false }
			byGuild[gname] = g
			out.guilds[#out.guilds + 1] = g
		end
		g.total = g.total + 1
		if p.status == "NONE" or p.status == "OTHER" or p.marked then g.bad = g.bad + 1 end
	end
	for gname in pairs(src.guildMarks) do
		if not byGuild[gname] then out.guilds[#out.guilds + 1] = { name = gname, total = 0, bad = 0, marked = true } end
	end
	table.sort(out.players, function(a, b)
		if (a.marked and true or false) ~= (b.marked and true or false) then return a.marked and true or false end
		local oa, ob = STATUS_ORDER[a.status] or 9, STATUS_ORDER[b.status] or 9
		if oa ~= ob then return oa < ob end
		return (a.t or 0) > (b.t or 0)
	end)
	table.sort(out.guilds, function(a, b)
		if a.marked ~= b.marked then return a.marked end
		if a.bad ~= b.bad then return a.bad > b.bad end
		return a.name < b.name
	end)
	return out
end

function Inspect.DiscordText()
	local s = Inspect.Summary()
	local c = s.counts
	local out = {}
	out[#out + 1] = L.DISCORD_INSPECT_HEADER:format(s.total, c.GUILD, c.NONE, c.OTHER)
	local guilds = {}
	for _, g in ipairs(s.guilds) do
		if g.bad > 0 or g.marked then
			guilds[#guilds + 1] = ("%s%s %d/%d"):format(g.marked and "[!] " or "", g.name, g.bad, g.total)
		end
	end
	if #guilds > 0 then out[#out + 1] = "**Guilds:** " .. table.concat(guilds, " · ") end
	out[#out + 1] = "```"
	local any = false
	for _, p in ipairs(s.players) do
		if p.status == "NONE" or p.status == "OTHER" or p.marked then
			any = true
			local label = p.status == "NONE" and "NO TABARD" or p.status == "OTHER" and "WRONG TABARD" or "MARKED"
			out[#out + 1] = ("%-14s %-20s %-12s %s"):format(ns.ShortName(p.name), "<" .. (p.guild or "?") .. ">", label, p.note or "")
		end
	end
	if not any then out[#out + 1] = L.DISCORD_INSPECT_CLEAN end
	out[#out + 1] = "```"
	return table.concat(out, "\n")
end

function Inspect.TooltipLine(name)
	local p = Source().players[Key(name)]
	if not p then return nil end
	if p.status == "YOUNG" and not p.marked then return nil end -- the rule starts at MIN_LEVEL
	local text
	if p.status == "GUILD" then text = "|cff40ff40" .. L.TABARD_OK .. "|r"
	elseif p.status == "NONE" then text = "|cffff4040" .. L.TABARD_NONE .. "|r"
	elseif p.status == "OTHER" then text = "|cffffd200" .. L.TABARD_OTHER .. "|r"
	else text = "|cff9d9d9d" .. L.TABARD_UNKNOWN .. "|r" end
	if p.marked then text = text .. "  |cffff4040[" .. L.MARK .. "]|r" end
	return L.TABARD .. ": " .. text .. "  |cff9d9d9d" .. ns.Ago(p.t) .. "|r"
end

---------------------------------------------------------------------------
-- The officers' shared list (1.1, request #29: "Officers only, merged over guild messages, inside
-- the current inspect budget. Do not scan faster."). A patrol is one character's, so each officer
-- rebuilt the same list. Now an officer's addon passes what his own inspections find (a player
-- caught without the colors or with another tabard, and one caught before now wearing ours) to
-- his guild's officers, over GUILD: nothing more is inspected for it, no inspection comes sooner,
-- nothing goes on the Sylvanistas channel. Only officers (the guild master and the officer rank right
-- below: our roster, the server's word) send them and keep them, each receiver checking the
-- sender's rank in its own roster. What another officer found shows on the Tabards page like our
-- own, with his name in the tooltip, for SHARE_KEEP; our own later inspection of that player
-- replaces it, and nothing is passed on second hand. The King's untabarded list stays his: it is
-- made from his own patrol and the Royal Inspection's reports, as before. Another officer's word
-- never joins it (Inspect.ShameList), never rides in a Royal Inspection's report (King.lua) and
-- never replaces what the King himself holds, nor what our patrol saw while a Royal Inspection
-- runs here (the 1.1 review: an officer of the King's guild could put any name on the army's
-- list, or have a sampled officer report it as his own).
--   U1~<name>:<guild>:<N|O|G>:<seconds ago, base36>;...   an officer's own findings (GUILD)
--   U0~                                                   an officer's addon after login, or at his
--                                                         yes if later (once a session): "what
--                                                         did you find today?" (GUILD)
-- A GUILD message reaches every guildmate's client (any of them can read its bytes with a
-- script); the addon of anyone but an officer drops it unread. Versions before 1.1 have no
-- handler for these and drop them. Off until the officer says yes (review of 1.1: it was
-- on by default and missing from the first-open page): his line there (Consent.lua), or /syl
-- patrolshare on; off, or never answered: nothing sent, nothing taken.
---------------------------------------------------------------------------

Inspect.SHARE_EVERY = 60         -- an officer's findings go out once a minute at most...
Inspect.SHARE_PER_MSG = 6        -- ...this many in a message...
Inspect.SHARE_MSGS = 3           -- ...and this many messages each time (the rest wait their turn)
Inspect.SHARE_KEEP = 24 * 3600   -- another officer's word is kept a day; ours as every inspection
Inspect.SHARE_ANSWER_GAP = 300   -- an ask is answered once each 5 minutes at most
Inspect.random = math.random
Inspect.after = function(seconds, where, fn) ns.After(seconds, where, fn) end
local STATUS_CODE = { NONE = "N", OTHER = "O", GUILD = "G" }
local CODE_STATUS = { N = "NONE", O = "OTHER", G = "GUILD" }
local shareQueue, shareQueued = {}, {} -- the names of our own findings waiting to go out
local lastShare, lastAnswer, answering = -math.huge, -math.huge, false
local askedToday = false -- our U0 went out this session (one a session at most)

function Inspect.Sharing() return ns.db ~= nil and ns.db.patrolShare == true end
local function Officer() return ns.IsMember() == true and ns.Roster.IsOfficer() == true end
local function MayShare() return Inspect.Sharing() and Officer() end
Inspect.MayShare = MayShare

-- A finding of our own worth telling our officers: someone caught without the colors or with
-- another tabard, or wearing ours now after being caught (by us or by another officer: the
-- correction reaches whoever holds the old word).
QueueShare = function(p, previous, wasShared)
	if not MayShare() then return end
	local status = p.status
	local fix = status == "GUILD" and (previous == "NONE" or previous == "OTHER")
	if not (status == "NONE" or status == "OTHER" or fix) then return end
	if status == previous and not wasShared then
		-- (The same finding again, already told: only a new one goes out.)
		if p.sharedAt and ns.Now() - p.sharedAt < Inspect.SHARE_KEEP / 2 then return end
	end
	if not shareQueued[p.name] then
		shareQueued[p.name] = true
		shareQueue[#shareQueue + 1] = p.name
	end
end

local function Clean(s) return (tostring(s or ""):gsub("[:;~|%c]", "")) end

-- An entry of ours as it travels, nil when it can't (a name or guild too long).
local function Entry(p, now)
	local code = STATUS_CODE[p.status or ""]
	local age = ns.Codec.Base36(math.max(0, now - (tonumber(p.t) or now)))
	local name, guild = Clean(p.name), Clean(p.guild)
	if not code or not age or name == "" or #name > 60 or #guild > 72 then return nil end
	return ("%s:%s:%s:%s"):format(name, guild, code, age)
end

-- Entries (strings) into messages of SHARE_PER_MSG entries (and 250 bytes) each, SHARE_MSGS at most.
local function Send(entries, key)
	local sent, msg, n, count = 0, nil, 0, 0
	local function Flush()
		if not msg then return end
		count = count + 1
		ns.Comm.Send("GUILD", msg, key .. count)
		msg, n = nil, 0
	end
	for _, e in ipairs(entries) do
		if count >= Inspect.SHARE_MSGS then break end
		if msg and (n >= Inspect.SHARE_PER_MSG or #msg + 1 + #e > 250) then Flush() end
		if count >= Inspect.SHARE_MSGS then break end
		msg = msg and (msg .. ";" .. e) or ("U1~" .. e)
		n, sent = n + 1, sent + 1
	end
	Flush()
	return sent
end

-- Once each SHARE_EVERY: our findings waiting, oldest first, as many as SHARE_MSGS messages hold.
function Inspect.FlushShare()
	if #shareQueue == 0 then return 0 end
	if not MayShare() then
		wipe(shareQueue); wipe(shareQueued)
		return 0
	end
	local now = ns.Now()
	if now - lastShare < Inspect.SHARE_EVERY then return 0 end
	local entries, names = {}, {}
	while #shareQueue > 0 and #entries < Inspect.SHARE_PER_MSG * Inspect.SHARE_MSGS do
		local name = table.remove(shareQueue, 1)
		shareQueued[name] = nil
		local p = Store().players[name]
		local e = p and not p.shared and Entry(p, now)
		if e then
			entries[#entries + 1] = e
			names[#names + 1] = p
		end
	end
	if #entries == 0 then return 0 end
	lastShare = now
	local sent = Send(entries, "tabardshare")
	for i = 1, sent do names[i].sharedAt = now end
	ns.Log("tabard patrol: %d finding(s) told to our officers", sent)
	return sent
end

-- A name as another officer's addon wrote it: "Name" or "First Surname", with "-Realm" or not.
local function CleanShared(s)
	if type(s) ~= "string" or #s > 60 then return nil end
	local short, realm = s:match("^([^%-]+)%-([^%-]+)$")
	short = short or s
	if not short:match("^[%a\128-\255]+ ?[%a\128-\255]*$") then return nil end
	if realm and not realm:match("^[%w\128-\255]+$") then return nil end
	return s
end

-- What another officer's word never replaces: the King's own (his patrol's and the reports'), and
-- what our patrol saw while a Royal Inspection runs here (its report is ours alone).
local function OwnKept(p)
	if not p or p.shared then return false end
	if p.reported then return true end
	local K = ns.King
	if K and K.IsKing and K.IsKing() then return true end
	local state = K and K.State and K.State()
	return state ~= nil and state.inspecting ~= nil
end

-- An officer's findings (U1, over GUILD), taken by an officer's addon only: the sender an
-- officer of ours by our roster, each entry a Sylvanistas guild's player, a day old at most, newer
-- than what we hold of him (our own inspections included, but for OwnKept).
function Inspect.HandleShare(dist, sender, text)
	if dist ~= "GUILD" or type(text) ~= "string" or #text > 255 or not MayShare() then return end
	local rank = ns.Roster.RankOf(sender)
	if not rank or rank > ns.CAPTAIN_RANK then return end
	local body = text:match("^U1~(.+)$")
	if not body then return end
	local now, n, changed = ns.Now(), 0, false
	local by = ns.DisplayName(ns.FullName(sender))
	for entry in body:gmatch("[^;]+") do
		n = n + 1
		if n > Inspect.SHARE_PER_MSG then break end
		local name, guild, code, age = entry:match("^([^:]+):([^:]*):([NOG]):([0-9a-z]+)$")
		age = age and #age <= 8 and tonumber(age, 36) or nil
		name = CleanShared(name)
		if name and age and age <= Inspect.SHARE_KEEP and #guild <= 72 and ns.IsFederation(guild) then
			local key = Key(name)
			local t = now - age
			local p = key and Store().players[key]
			if key and not (p and (tonumber(p.t) or 0) >= t) and not OwnKept(p) then
				local new = p == nil
				p = p or {}
				p.name, p.guild, p.status, p.t, p.item = key, guild, CODE_STATUS[code], t, nil
				p.shared, p.by = true, by
				Store().players[key] = p
				if new then Inspect.Prune() end
				changed = true
			end
		end
	end
	if changed then ns.Fire("INSPECT_CHANGED") end
end
ns.Comm.Handle("U1", function(...) Inspect.HandleShare(...) end)

-- Our own findings of the last SHARE_KEEP (never another officer's), newest first.
local function OwnFindings(now)
	local list = {}
	for _, p in pairs(Store().players) do
		if type(p) == "table" and not p.shared and not p.reported and (p.status == "NONE" or p.status == "OTHER")
			and now - (tonumber(p.t) or 0) <= Inspect.SHARE_KEEP then
			list[#list + 1] = p
		end
	end
	table.sort(list, function(a, b)
		if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) > (b.t or 0) end
		return tostring(a.name) < tostring(b.name)
	end)
	return list
end

-- After login, an officer's addon asks the others for the day's findings (its own list starts
-- empty: the Forever beta forgets saved data at every login), or once he says yes if that came
-- later (SetSharing). Once a session.
function Inspect.AskShared()
	if askedToday or not MayShare() then return false end
	askedToday = true
	ns.Comm.Send("GUILD", "U0~", "tabardask")
	return true
end

-- Another officer's ask: our own findings of the day, a few seconds later, once each
-- SHARE_ANSWER_GAP at most (one answer covers every officer who asked meanwhile).
function Inspect.HandleAsk(dist, sender)
	if dist ~= "GUILD" or not MayShare() or answering then return end
	local rank = ns.Roster.RankOf(sender)
	if not rank or rank > ns.CAPTAIN_RANK then return end
	if ns.Now() - lastAnswer < Inspect.SHARE_ANSWER_GAP then return end
	if #OwnFindings(ns.Now()) == 0 then return end
	answering = true
	Inspect.after(2 + Inspect.random() * 8, "tabard share answer", function()
		answering = false
		if not MayShare() then return end
		local now = ns.Now()
		lastAnswer = now
		local entries = {}
		for _, p in ipairs(OwnFindings(now)) do
			local e = Entry(p, now)
			if e then entries[#entries + 1] = e end
		end
		Send(entries, "tabardanswer")
	end)
end
ns.Comm.Handle("U0", function(dist, sender) Inspect.HandleAsk(dist, sender) end)

-- `/syl patrolshare on|off`: alone, says which.
function Inspect.SetSharing(on)
	if on ~= nil then ns.db.patrolShare = on and true or false end
	if not Inspect.Sharing() then return ns.Print(L.PATROLSHARE_OFF) end
	ns.Print(Officer() and L.PATROLSHARE_ON or L.PATROLSHARE_ON_NOT_OFFICER)
	-- (review of 1.1: the login's ask comes 40 to 70 s in, off until he answers; a yes on
	-- the first-open page, 45 s in, or later asks then, unless ours went out this session.)
	if on and Officer() then Inspect.AskShared() end
end

-- How many on our list are another officer's word (the Tabards tab's detail box).
function Inspect.SharedCount()
	local n = 0
	for _, p in pairs(Store().players) do
		if type(p) == "table" and p.shared then n = n + 1 end
	end
	return n
end

-- Tests start from a clean state.
function Inspect.ResetShare()
	wipe(shareQueue); wipe(shareQueued)
	lastShare, lastAnswer, answering = -math.huge, -math.huge, false
	askedToday = false
end

---------------------------------------------------------------------------
-- Untabarded (0.9.2; the "Wall of Shame" before): the players the Royal Inspection found
-- without the colors. The King's alone: his page lists them, and only he can let the army see
-- the list (King.lua, a switch like the Treasury's), in the Tabards tab and nowhere else. No
-- raid warning, no chat line, no sound, for anyone; turned off, it leaves every screen.
-- Nobody else publishes one any more: walls from older versions (S1) are ignored.
-- Closed until the tabard rule is in force, midnight in Texas (where the Dark Lady is) between
-- September 24 and 25, 2026: the Tabards page counts down to it.
---------------------------------------------------------------------------

Inspect.SHAME_FROM = 1790312400 -- 2026-09-25 00:00 CDT (05:00 UTC)
local function ServerNow() return (GetServerTime and GetServerTime()) or time() end
function Inspect.ShameOpen() return ServerNow() >= Inspect.SHAME_FROM end
function Inspect.ShameOpensIn() return math.max(0, Inspect.SHAME_FROM - ServerNow()) end

-- Pardoned by the King (Acts.lua): off every list for a week, his and the one he shares.
local function Pardoned(name) return ns.Acts and ns.Acts.Pardoned and ns.Acts.Pardoned(name) == true end

-- The King's list: what his own patrol and the Royal Inspection's reports found, and whom he
-- marked by hand. Never another officer's word (1.1: an officer's shared findings stay on the
-- Tabards page).
function Inspect.ShameList()
	local out = {}
	for _, p in ipairs(Inspect.Summary().players) do
		if (p.marked or (not p.shared and (p.status == "NONE" or p.status == "OTHER"))) and not Pardoned(p.name) then
			out[#out + 1] = { name = ns.ShortName(p.name), guild = p.guild }
		end
	end
	return out
end

-- A list the King shares lasts while he keeps repeating it (King.UNTABARDED_EVERY).
Inspect.SHARED_FRESH = 20 * 60

-- The list the King lets the army see, or nil to take it off. Quietly: the Tabards tab only.
-- false when it names the same players as the one shown (nothing to redraw).
local function SameList(a, b)
	if not a or not b or #a.list ~= #b.list then return false end
	local names = {}
	for _, p in ipairs(a.list) do names[tostring(p.name) .. ":" .. tostring(p.guild)] = true end
	for _, p in ipairs(b.list) do
		if not names[tostring(p.name) .. ":" .. tostring(p.guild)] then return false end
	end
	return true
end
function Inspect.ShowShame(shame)
	if not shame then
		if not Inspect.shame then return false end
		Inspect.shame = nil
		ns.Fire("INSPECT_CHANGED")
		return true
	end
	for i = #shame.list, 1, -1 do
		if Pardoned(shame.list[i].name) then table.remove(shame.list, i) end
	end
	local same = SameList(Inspect.shame, shame)
	Inspect.shame = shame
	if same then return false end
	ns.Fire("INSPECT_CHANGED")
	return true
end

function Inspect.Shame()
	local s = Inspect.shame
	if s and ns.Now() - (s.t or 0) > Inspect.SHARED_FRESH then
		Inspect.shame = nil
		return nil
	end
	return s
end

-- Walls from versions before 0.9.2 (any Lord could publish one, with a raid warning): ignored.
function Inspect.HandleShame(dist, sender, text)
	ns.Log("ignored a wall of shame from %s (0.9.2: only the King's list, quietly)", tostring(sender))
end
ns.Comm.Handle("S1", function(...) Inspect.HandleShame(...) end)

-- Tests start from a clean state.
function Inspect.ResetShame()
	Inspect.shame = nil
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

local function OnTooltipUnit(tooltip)
	if tooltip ~= GameTooltip then return end
	local _, unit = tooltip:GetUnit()
	if not unit or not UnitIsPlayer(unit) then return end
	local name = ns.UnitFullName(unit)
	local line = Inspect.TooltipLine(name)
	if line then tooltip:AddLine(line) end
	-- The Treasurer of Sylvanistas: his name and the game's own word on his guild.
	if ns.IsTreasurer(name, GetGuildInfo(unit)) then tooltip:AddLine(ns.COIN .. L.TREASURER_TITLE, 1, 0.82, 0) end
	if patrol then Enqueue(unit) end
end

ns.On("INIT", function() Inspect.Prune(); Inspect.PruneGear() end) -- (Prune makes the store too)

ns.On("LOGIN", function()
	ns.RegisterEvent("INSPECT_READY", OnInspectReady)
	ns.Every(INTERVAL, "inspect pump", Pump)
	-- 1.1: an officer's findings to his guild's officers, and the day's asked for once our roster is in.
	ns.Every(15, "tabard share", Inspect.FlushShare)
	ns.After(40 + Inspect.random() * 30, "tabard share ask", Inspect.AskShared)
	local hooked = false
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
		hooked = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, function(tt)
			ns.SafeCall("tooltip", OnTooltipUnit, tt)
		end)
	end
	if not hooked then
		pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", function(tt)
			ns.SafeCall("tooltip", OnTooltipUnit, tt)
		end)
	end
	ns.Log("tooltip hook: %s", hooked and "TooltipDataProcessor" or "OnTooltipSetUnit")
end)

