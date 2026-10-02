local ADDON, ns = ...

-- Reads our own guild roster. Any member (not only officers) sees name, level,
-- class, zone and online state of everyone, which is all the census needs.

local Roster = {}
ns.Roster = Roster

local CLASS_CODES = {
	WARRIOR = "WA", PALADIN = "PA", HUNTER = "HU", ROGUE = "RO", PRIEST = "PR",
	SHAMAN = "SH", MAGE = "MA", WARLOCK = "WL", DRUID = "DR", DEATHKNIGHT = "DK",
}
local CLASS_FILES = {}
for file, code in pairs(CLASS_CODES) do CLASS_FILES[code] = file end
ns.CLASS_FILES = CLASS_FILES

function Roster.ClassCode(classFile)
	return classFile and (CLASS_CODES[classFile] or classFile) or ""
end

local SCAN_EVERY = 60
local MIN_GAP = 20
local lastScan, pending = 0, false

local function RequestServerRoster()
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	elseif GuildRoster then
		GuildRoster()
	end
end

local function DaysOffline(i, isOnline)
	if isOnline or not GetGuildRosterLastOnline then return 0 end
	local y, m, d, h = GetGuildRosterLastOnline(i)
	if not y then return 0 end
	return (y or 0) * 365 + (m or 0) * 30 + (d or 0) + (h or 0) / 24
end

-- Where the counts below come from: the name as the server sent it ("bare" = no realm) and the
-- server id of the member's GUID. ns.FullName gives bare names our realm, so counting after
-- it could never tell two realms apart.
local function CountRaw(t, key)
	t[key] = (t[key] or 0) + 1
end

function Roster.Scan()
	-- The 4th return is the guild's home realm, nil when it is ours.
	local guild, _, _, home = GetGuildInfo("player")
	if not guild then return nil end
	home = type(home) == "string" and home:gsub("[%s%-]", "") or ""
	local started = debugprofilestop and debugprofilestop() or 0
	local numTotal, numOnline = GetNumGuildMembers()
	numTotal = numTotal or 0
	local officerRank = ns.CAPTAIN_RANK
	local r = {
		guild = guild, total = numTotal, online = 0,
		zones = {}, classes = {}, levels = { 0, 0, 0, 0, 0, 0, 0 },
		leader = nil, leaderOnline = false, leaderDays = 0,
		ranks = {}, officers = {}, inactive7 = 0, inactive30 = 0, avgLevel = 0, top = {},
	}
	-- Rank names in rank order (1 = guild master).
	local numRanks = GuildControlGetNumRanks and GuildControlGetNumRanks() or 0
	for i = 1, numRanks do r.ranks[i] = { name = GuildControlGetRankName(i) or ("Rank " .. i), count = 0 } end

	local seen, seenOffline, zoneCount, levelSum = 0, 0, 0, 0
	local everyone = {}
	local online = {} -- who is online now, for the Realm tab (Views.MembersOf)
	local byName = {}
	local rawRealms, servers, sample = {}, {}, nil -- for /syl status (names raw)
	for i = 1, numTotal do
		local name, rankName, rankIndex, level, _, zone, _, _, isOnline, _, classFile, _, _, _, _, _, guid = GetGuildRosterInfo(i)
		if name then
			seen = seen + 1
			local rawRealm = name:match("%-(.+)$")
			CountRaw(rawRealms, rawRealm or "bare")
			CountRaw(servers, type(guid) == "string" and guid:match("^Player%-(%d+)%-") or "?")
			if not sample or (rawRealm and not sample:find("-", 1, true)) then sample = name end
			-- Identity is "Name-Realm"; reports carry the short form for our own realm.
			local full = ns.FullName(name)
			local short = ns.DisplayName(full)
			byName[full] = rankIndex or 9
			local days = DaysOffline(i, isOnline)
			level = level or 1
			levelSum = levelSum + level
			rankIndex = rankIndex or 9
			local rank = r.ranks[rankIndex + 1]
			if not rank then
				rank = { name = rankName or ("Rank " .. (rankIndex + 1)), count = 0 }
				r.ranks[rankIndex + 1] = rank
			end
			rank.count = rank.count + 1
			local code = classFile and (CLASS_CODES[classFile] or classFile)
			local zoneKey = isOnline and ns.Zones.KeyForName(zone) or nil
			if rankIndex == 0 then
				r.leader = short
				r.leaderOnline = isOnline and true or false
				r.leaderDays = days
				r.leaderClass, r.leaderLevel, r.leaderZone = code, level, zoneKey
			elseif rankIndex <= officerRank then
				r.officers[#r.officers + 1] = { name = short, online = isOnline and true or false, days = days, class = code, level = level, zone = zoneKey }
			end
			if days >= 30 then r.inactive30 = r.inactive30 + 1 end
			if days >= 7 then r.inactive7 = r.inactive7 + 1 end
			-- Every member, online or not, for our guild's members page (1.1, Members.lua): the
			-- name as the server gave it (raw: what a removal takes), rank, days offline. Kept in
			-- memory only, never in the report.
			everyone[#everyone + 1] = { name = short, level = level, class = code, raw = name, full = full, rankIndex = rankIndex,
				rank = rankName or rank.name, days = days, online = isOnline and true or false }
			if isOnline then
				online[#online + 1] = { name = short, level = level, class = code, zone = zoneKey, rank = rankName, rankIndex = rankIndex }
				r.online = r.online + 1
				local key = ns.Zones.KeyForName(zone)
				if key then
					if not r.zones[key] then zoneCount = zoneCount + 1 end
					r.zones[key] = (r.zones[key] or 0) + 1
				end
				if code then r.classes[code] = (r.classes[code] or 0) + 1 end
				local band = math.min(7, math.floor(level / 10) + 1)
				r.levels[band] = r.levels[band] + 1
			else
				seenOffline = seenOffline + 1
			end
		end
	end
	-- Fill gaps so rank order is kept even if a rank has nobody in it.
	for i = 1, #r.ranks do r.ranks[i] = r.ranks[i] or { name = "Rank " .. i, count = 0 } end
	table.sort(r.officers, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.days < b.days
	end)
	table.sort(everyone, function(a, b)
		if a.level ~= b.level then return a.level > b.level end
		return a.name < b.name
	end)
	for i = 1, math.min(5, #everyone) do r.top[i] = everyone[i] end
	r.avgLevel = seen > 0 and levelSum / seen or 0
	Roster.byName, Roster.guild = byName, guild -- (whose roster it is: Sylvanistas Link's "r", Link.lua)
	Roster.members = everyone -- (1.1: every member's row, Members.lua)
	table.sort(online, function(a, b)
		if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
		if a.level ~= b.level then return a.level > b.level end
		return a.name < b.name
	end)
	Roster.online = online
	Roster.rawRealms, Roster.servers, Roster.rawSample = rawRealms, servers, sample
	r.home = home ~= "" and home or ns.realm
	r.faction = ns.faction or ns.Faction()
	if numOnline and numOnline > r.online then r.online = numOnline end
	local ms = debugprofilestop and (debugprofilestop() - started) or 0
	Roster.lastStats = {
		numTotal = numTotal, numOnline = numOnline, seen = seen, seenOffline = seenOffline,
		leader = r.leader, leaderOnline = r.leaderOnline, zones = zoneCount, ms = ms, t = ns.Now(),
		ranks = #r.ranks, officers = #r.officers,
	}
	ns.Log("scan %s: total=%d online=%d rows=%d offlineRows=%d leader=%s ranks=%d officers=%d zones=%d %.1fms",
		guild, numTotal, r.online, seen, seenOffline, tostring(r.leader), #r.ranks, #r.officers, zoneCount, ms)
	return r
end

-- Rank of a member of OUR guild, from the roster the server gave us (nil if not a member).
function Roster.RankOf(name)
	return Roster.byName and name and Roster.byName[ns.FullName(name)]
end

-- Our own rank index (0 = guild master), used for layer names and decree permission.
function Roster.MyRank()
	local _, _, rankIndex = GetGuildInfo("player")
	return rankIndex or 9
end

function Roster.IsOfficer()
	return IsInGuild() and Roster.MyRank() <= ns.CAPTAIN_RANK
end

function Roster.TryScan()
	if not pending or ns.Now() - lastScan < MIN_GAP then return end
	pending = false
	lastScan = ns.Now()
	local r = Roster.Scan()
	if not r or not ns.IsFederation(r.guild) then return end
	-- (1.1, Members.lua: who joined since login, for the Lord's recruits; our Lord away past
	-- warnDays, one line to our officers.)
	ns.SafeCall("members scan", ns.Members.OnScan, r)
	-- Our guild lives on another realm: that realm shares our guilds, so it shares our census
	-- (first, so our report lands in the shared store).
	if r.home ~= ns.realm then ns.LinkRealms(ns.realm, r.home) end
	r.users = ns.Comm.PeerCount() + 1
	r.versions = ns.Comm.PeerVersions and ns.Comm.PeerVersions() or nil
	-- 1.0.0: the realms our guild's addon users play on now, and what our client takes part in
	-- (fields 27 and 26 of the report).
	r.pres = ns.Comm.Presence and ns.Comm.Presence() or nil
	r.cap = ns.Comm.CAPABILITY
	ns.Data.SetLocal(r)
	ns.Comm.MaybeBroadcast(r)
end

function Roster.RequestScan(force)
	if not IsInGuild() then return end
	if force then lastScan = 0 end
	pending = true
	RequestServerRoster()
	-- GUILD_ROSTER_UPDATE usually triggers the scan; this is the fallback.
	ns.After(4, "roster fallback", Roster.TryScan)
end

ns.RegisterEvent("GUILD_ROSTER_UPDATE", function()
	if pending then ns.After(1, "roster update", Roster.TryScan) end
end)

ns.RegisterEvent("PLAYER_GUILD_UPDATE", function()
	ns.After(2, "guild changed", function()
		Roster.RequestScan(true)
		-- Left a Sylvanistas guild (or joined one): leave the channel, redraw the map and window.
		ns.Comm.CheckMembership()
		ns.Fire("DATA_CHANGED")
	end)
end)

ns.On("LOGIN", function()
	ns.After(8, "first scan", function() Roster.RequestScan(true) end)
	ns.Every(SCAN_EVERY, "scan ticker", function() Roster.RequestScan() end)
end)
