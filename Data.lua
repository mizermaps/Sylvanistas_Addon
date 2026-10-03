local ADDON, ns = ...
local L = ns.L

-- Holds one report per Sylvanistas guild (ours from the roster, others from the channel)
-- and aggregates them into the numbers the UI and the map show.

local Data = {}
ns.Data = Data

Data.FRESH = 15 * 60           -- older: shown grey, its online players and zones leave the totals
Data.KEEP = 7 * 24 * 60 * 60   -- older than this is forgotten (the guild still listed, grey, until then)
Data.TOTAL_KEEP = 24 * 60 * 60 -- a guild's size counts in the army's total this long after its last report
Data.VOUCH_TTL = 30 * 60       -- a report counts as its sender's vote on the guild this long
Data.CLAIM_TTL = 15 * 60       -- a sender quiet this long for its guild may speak for another one
local MAX_VOUCH = 8            -- votes kept per guild (the newest)

-- The key a guild is stored under, whatever the case a report spells it in: a realm has one
-- guild of a name, so "SYLVANISTAS X" and "Sylvanistas X" are the same one (or one is forged).
function Data.GuildKey(name)
	if type(name) ~= "string" then return nil end
	local guilds = ns.rdb and ns.rdb.guilds
	if not guilds then return nil end
	if guilds[name] then return name end
	local lower = name:lower()
	for key in pairs(guilds) do
		if type(key) == "string" and key:lower() == lower then return key end
	end
	return nil
end
function Data.Guild(name)
	local key = Data.GuildKey(name)
	return key and ns.rdb.guilds[key] or nil
end

-- Where the King is pinned by name (ns.KING_CHARACTER), a report of his guild that names
-- anyone else as its leader (or nobody) is not his guild's: forged, or out of date.
function Data.OtherKing(guild, leader)
	return ns.IsKingGuild(guild) and ns.KingCharacter() ~= nil and not ns.IsKingCharacter(leader)
end

ns.On("INIT", function()
	local now = ns.Now()
	for name, g in pairs(ns.rdb.guilds) do
		if type(g) ~= "table" or now - (g.t or 0) > Data.KEEP then
			ns.rdb.guilds[name] = nil
		elseif ns.Codec.Dirty(name) or ns.Codec.Dirty(g) then
			-- Kept by versions before 0.9.2, which let escape codes (colours, textures, links)
			-- and control bytes in from the channel: the guild's next report (stripped now,
			-- Comm.lua) takes its place, and ours comes back from the roster.
			ns.Log("dropped guild %s: escape codes in its report", ns.Codec.Plain(name))
			ns.rdb.guilds[name] = nil
		elseif not g.mine and Data.OtherKing(name, g.leader) then
			-- Kept from before the King was pinned: the next real report takes its place.
			ns.Log("dropped guild %s: names %s its leader, not the King", name, tostring(g.leader))
			ns.rdb.guilds[name] = nil
		end
	end
	-- Kept by older versions: a report bigger than a guild can be (forged), and one guild under
	-- two spellings (the newer one stays). Collected first: pairs must not see removals twice.
	local drop, byLower = {}, {}
	for name, g in pairs(ns.rdb.guilds) do
		if (tonumber(g.total) or 0) > ns.Codec.GUILD_CAP then
			drop[#drop + 1] = name
		else
			local other = byLower[name:lower()]
			if other then
				local older = (g.t or 0) < (ns.rdb.guilds[other].t or 0) and name or other
				drop[#drop + 1] = older
				if older == other then byLower[name:lower()] = name end
			else
				byLower[name:lower()] = name
			end
		end
	end
	for _, name in ipairs(drop) do
		ns.Log("dropped guild %s: forged size or a second spelling", name)
		ns.rdb.guilds[name] = nil
	end
	local seen = Data.Seen()
	for name, e in pairs(seen) do
		if type(e) ~= "table" or now - (e.t or 0) > Data.KEEP then seen[name] = nil end
	end
	-- Sightings kept before v0.7.11 may carry a "-Realm" of our census group on the guild's
	-- name (Who.GuildName): they go under its plain name, the newest one kept, or the guild
	-- would show twice. Collect first: pairs must not see new keys.
	local renamed = {}
	for name in pairs(seen) do
		local base = type(name) == "string" and ns.Who.GuildName and ns.Who.GuildName(name)
		if base and base ~= name then renamed[#renamed + 1] = { name, base } end
	end
	for _, pair in ipairs(renamed) do
		local e, old = seen[pair[1]], seen[pair[2]]
		seen[pair[1]] = nil
		if type(old) ~= "table" or (e.t or 0) > (old.t or 0) then seen[pair[2]] = e end
	end
end)

-- Sylvanistas guilds seen online with /who (census Refresh, Join screen), per realm:
-- [guild] = { online = players seen, capped = more may be online, t }. Kept apart from the
-- reports on purpose: a sighting knows no members, leader or zones, never counts in the
-- totals, and must never pass for a report (the conflict and rank checks trust
-- ns.rdb.guilds). The census lists the guilds seen that nobody reports, in grey.
function Data.Seen()
	ns.rdb.seen = ns.rdb.seen or {}
	return ns.rdb.seen
end

-- players: the Sylvanistas players of the current round of /who searches (Who.lua), each once.
-- Players of other realms count too: /who only lists who shares our world, and on the
-- Forever beta Sylvanistas guilds span PvP and PvP 2, so everyone we can see belongs here.
function Data.RecordSightings(players, capped)
	local count = {}
	for _, p in ipairs(players or {}) do
		if ns.IsFederation(p.guild) then
			count[p.guild] = (count[p.guild] or 0) + 1
		end
	end
	local seen, now = Data.Seen(), ns.Now()
	for guild, n in pairs(count) do seen[guild] = { online = n, capped = capped or nil, t = now } end
	if next(count) then ns.Fire("DATA_CHANGED") end
end
ns.Who.Listen(Data.RecordSightings)

-- The server's clock (1.0.0), the same second on every realm, where ns.Now is this computer's:
-- nil on a client without it.
function Data.ServerTime()
	if type(GetServerTime) ~= "function" then return nil end
	local ok, t = pcall(GetServerTime)
	return ok and type(t) == "number" and t > 0 and t or nil
end

function Data.SetLocal(r)
	r.t = ns.Now()
	r.st = Data.ServerTime() -- field 25 of our report: when it was made, by the server's clock
	r.reporter = ns.DisplayName(ns.me)
	r.reporterFull = ns.me
	r.realm = ns.realm
	r.from = ns.realm -- travels in the report: whoever hears it on another realm sees the channel shared (/syl status)
	r.heardOn = ns.realm -- see Data.Receive
	r.mine = true
	ns.rdb.guilds[r.guild] = r
	ns.Fire("DATA_CHANGED")
end

-- Sender names are set by the server and cannot be forged, so we tie every sender to the
-- one guild it reports. A (modified) client that reports several guilds is ignored, and a
-- guild whose reports disagree about its leader or its officers is flagged as a conflict (the
-- census marks it, and sizes that disagree too: Data.Dispute, 1.1).
local senderGuild = {} -- "Name-Realm" -> { guild, t }

-- One guild per sender, shared by reports and chat: a name that speaks for one guild can't
-- speak for another. A player who really moved guilds speaks again after CLAIM_TTL quiet.
function Data.ClaimGuild(sender, guild)
	local who, now = ns.FullName(sender), ns.Now()
	local c = senderGuild[who]
	if c and c.guild:lower() ~= guild:lower() and now - c.t < Data.CLAIM_TTL then return false end
	senderGuild[who] = { guild = guild, t = now }
	return true
end

-- Every rank a report names, as "Name-Realm" -> 0 (leader) or 1 (officer). Names without a
-- realm belong to the reporter's realm, so a same-named player from another realm never matches.
local function Ranks(g)
	local home, out = g.realm or ns.realm, {}
	for _, o in ipairs(g.officers or {}) do out[ns.FullName(o.name, home)] = 1 end
	if g.leader then out[ns.FullName(g.leader, home)] = 0 end
	return out
end

-- The guild as a report pictures it: leader and officers, names in "Name-Realm" form so the
-- same people match whatever realm each reporter plays on. A list cut at MAX_OFFICERS is
-- pictured by its leader only (two cut lists need not hold the same officers).
local function Signature(r, ranks)
	local cut = #(r.officers or {}) >= ns.Codec.MAX_OFFICERS
	local parts = {}
	for name, rank in pairs(ranks) do
		if rank == 0 or not cut then parts[#parts + 1] = name .. "=" .. rank end
	end
	table.sort(parts)
	return table.concat(parts, ",") .. (cut and ",+" or "")
end

-- The votes kept for a guild: one per sender (its newest report), for VOUCH_TTL, the newest
-- MAX_VOUCH. Votes of older versions (no signature) are dropped.
local function Votes(map, now)
	local list, out = {}, {}
	for sender, v in pairs(map or {}) do
		if type(v) == "table" and v.sig and v.ranks and now - (v.t or 0) <= Data.VOUCH_TTL then
			list[#list + 1] = { sender = sender, v = v }
		end
	end
	table.sort(list, function(a, b) return a.v.t > b.v.t end)
	for i = 1, math.min(MAX_VOUCH, #list) do out[list[i].sender] = list[i].v end
	return out
end

-- The picture most senders agree on right now, its count, and every picture with that many
-- senders (`tops`). `top` is nil when there is none, or when two pictures have as many
-- senders each: then the guild is contested, and only what all of them agree on counts.
local function Majority(votes, now)
	local count = {}
	for _, v in pairs(votes) do
		if now - (v.t or 0) <= Data.VOUCH_TTL then count[v.sig] = (count[v.sig] or 0) + 1 end
	end
	local best, tops = 0, {}
	for sig, n in pairs(count) do
		if n > best then best, tops = n, { [sig] = true } elseif n == best then tops[sig] = true end
	end
	local top, n = nil, 0
	for sig in pairs(tops) do top, n = sig, n + 1 end
	if n ~= 1 then top = nil end
	return top, best, tops
end
Data.Majority = Majority -- for /syl status and tests

-- Votes heard on one channel say nothing on another (the public channel lets anyone vote):
-- called when we move to another channel, e.g. when the realm key arrives.
function Data.ForgetVotes()
	for _, g in pairs(ns.rdb and ns.rdb.guilds or {}) do
		if type(g) == "table" then g.vouch, g.conflict, g.outvoted = nil, nil, nil end
	end
end

-- What the census's mark on a row says (1.1, request #30): its senders split on the guild's leader
-- or officers (`split`: no picture leads; `outvoted`: a sender's report is not what the others
-- say), two fresh senders give sizes farther apart than SIZE_SLACK or SIZE_SHARE of the bigger
-- plus SIZE_DRIFT a minute between their two reports (`sizes`: the pair farthest past that, the
-- smaller first, { sender, n } each; the reporter speaks every 3 minutes and the runner-up every
-- 10, and a guild that fills, or has its inactive members removed, changes meanwhile), or one
-- sender alone stands behind it (`single`: that sender). nil
-- when nothing is to say: our own guild (our roster, the server's word), and a report older than
-- FRESH (grey already, and out of the online counts). It changes nothing that counts; a marked
-- row can still be the true one.
Data.SIZE_SLACK, Data.SIZE_SHARE = 5, 0.05
Data.SIZE_DRIFT = 20 -- members a minute (one removal per Members.REMOVE_GAP, 3 s, is 20)
function Data.Dispute(g, now)
	if type(g) ~= "table" or g.mine then return nil end
	now = now or ns.Now()
	if now - (g.t or 0) > Data.FRESH then return nil end
	local d, senders, count, sized = {}, {}, 0, {}
	for src, v in pairs(Votes(g.vouch, now)) do
		local short = ns.ShortName(src)
		if not senders[short] then senders[short], count = src, count + 1 end
		if type(v.n) == "number" and now - (v.t or 0) <= Data.FRESH then sized[#sized + 1] = { sender = src, n = v.n, t = v.t or 0 } end
	end
	d.split = g.conflict and true or nil
	d.outvoted = g.outvoted and true or nil
	local worst
	for i = 1, #sized do
		for j = i + 1, #sized do
			local lo, hi = sized[i], sized[j]
			if lo.n > hi.n or (lo.n == hi.n and lo.sender > hi.sender) then lo, hi = hi, lo end
			local past = hi.n - lo.n - math.max(Data.SIZE_SLACK, hi.n * Data.SIZE_SHARE) - Data.SIZE_DRIFT * math.abs(hi.t - lo.t) / 60
			if past > 0 and (not worst or past > worst.past or (past == worst.past and lo.sender .. hi.sender < worst.key)) then
				worst = { past = past, key = lo.sender .. hi.sender, lo = lo, hi = hi }
			end
		end
	end
	if worst then d.sizes = { { sender = worst.lo.sender, n = worst.lo.n }, { sender = worst.hi.sender, n = worst.hi.n } } end
	if count <= 1 then d.single = next(senders) and senders[next(senders)] or g.reporterFull or g.reporter or "?" end
	d.disputed = (d.split or d.outvoted or d.sizes) and true or nil
	if not (d.disputed or d.single) then return nil end
	return d
end

-- No Crown from other guilds' votes until a full reporting cycle has passed since login: a
-- guild's reporter and runner-up must have had the time to vote before outsiders can win.
Data.CROWN_AFTER = 200

-- The census after login (1.1): the beta often loads an empty save, and an empty window reads as
-- "the army is gone", which sends players into /reload after /reload. The census refills on its
-- own: the channel is joined within 15 s, every guild's reporter answers the census request (Q1,
-- Comm.AskCensus) or reports within 170 s. For REBUILD_FOR after login the window says so, with
-- how many guilds were heard since. A line and nothing else: no /who (the game takes it from a
-- click alone), no window or popup of any kind.
Data.REBUILD_FOR = 200

-- The guilds heard since login while the census is being rebuilt (0 or more), nil once it is
-- (or outside a Sylvanistas guild, or before login).
function Data.Rebuilding(now)
	local login = ns.Comm and ns.Comm.loginAt
	if not login or not ns.IsMember() then return nil end
	now = now or ns.Now()
	if now - login >= Data.REBUILD_FOR then return nil end
	local heard = 0
	for _, g in pairs(ns.rdb and ns.rdb.guilds or {}) do
		if type(g) == "table" and not g.mine and (g.t or 0) >= login then heard = heard + 1 end
	end
	return heard
end

-- At login: the window drawn once more when the rebuild is over, so its line goes. That redraw
-- is all it does (UI.RefreshSoon searches nothing, and does nothing while the window is closed).
function Data.OnLogin()
	ns.After(Data.REBUILD_FOR + 1, "census rebuilt", function()
		if ns.UI and ns.UI.RefreshSoon then ns.UI.RefreshSoon() end
	end)
end
ns.On("LOGIN", function() Data.OnLogin() end)

-- 1.1: a guild the moderators took off the network (net-off, Moderation.lua): not counted, not listed.
local function NetOff(guild)
	local M = ns.Moderation
	return M ~= nil and M.Guild ~= nil and M.Guild(guild) ~= nil
end
Data.NetOff = NetOff

function Data.Receive(r, sender)
	if not ns.IsFederation(r.guild) then return false end
	-- 1.1: a guild the moderators took off (net-off): its report counts for nothing, not even as a vote.
	if ns.Moderation.Report and ns.Moderation.Report(r, sender) then return false end
	-- Our own guild comes straight from our roster, never from someone else's claim (in any spelling).
	local mine = GetGuildInfo("player")
	if mine and r.guild:lower() == mine:lower() then return false end
	local who = ns.FullName(sender)
	-- The other faction's Sylvanistas guilds are not ours to count (their channel is another one;
	-- this only matters if a report reaches ours anyway).
	if (r.faction or "Alliance") ~= (ns.faction or "Alliance") then
		ns.Log("ignored %s from %s: a %s guild", r.guild, who, tostring(r.faction))
		return false
	end
	-- The King's guild is led by the King: where he is pinned by name, a report naming anyone
	-- else at its head counts for nothing, not even as a vote. It can't replace the row
	-- everyone sees, nor outvote the real reporters .
	if Data.OtherKing(r.guild, r.leader) then
		ns.Log("ignored %s from %s: names %s its leader, not the King", r.guild, who, tostring(r.leader))
		return false
	end
	if not Data.ClaimGuild(who, r.guild) then
		local claimed = senderGuild[who]
		ns.Log("ignored %s: already reported %s, now claims %s", who, claimed and claimed.guild or "?", r.guild)
		return false
	end
	-- One guild whatever the case it is spelled in: the spelling already stored is its key, and
	-- a report under another spelling is one more vote on that guild.
	r.guild = Data.GuildKey(r.guild) or r.guild
	local previous = ns.rdb.guilds[r.guild]
	-- Realms of one census group share this store, but a name without a realm takes the realm
	-- of the character that heard it. A report heard on another realm of the group names people
	-- in that realm's form: compared with ours, the same reporter and officers would look new
	-- (a false conflict), so here it counts as no report at all.
	if previous and previous.heardOn and previous.heardOn ~= ns.realm then previous = nil end
	local previousWho = previous and (previous.reporterFull or ns.FullName(previous.reporter))
	r.t = ns.Now()
	r.reporter = ns.DisplayName(who)
	r.reporterFull = who
	r.heardOn = ns.realm
	-- The realm of the sender's name as we got it, not the report's `from`: a report's short
	-- names are compared with senders in that same form (a sender that reaches us without a
	-- realm carries ours, whatever realm it plays on).
	r.realm = ns.RealmOf(who) or ns.realm
	local now = r.t
	-- Every report is its sender's vote on who leads the guild and who its officers are. Ranks
	-- count only from the picture most senders agree on (Data.KnownRank): one sender changing
	-- or repeating a report can't move it, and two pictures with as many senders each are a
	-- contest where no rank counts. Nothing here needs saved history (the Forever beta client
	-- never loads it back).
	local votes = Votes(previous and previous.vouch, now)
	local ranks = Ranks(r)
	-- n (1.1): the size this sender gives, for the census's dispute mark (Data.Dispute).
	votes[who] = { t = now, sig = Signature(r, ranks), ranks = ranks, n = tonumber(r.total) }
	r.vouch = votes
	local top, _, tops = Majority(votes, now)
	-- Against the picture most senders give while that picture is fresh: the vote counts, the
	-- row everyone sees (and the King's guild's leader with it) stays the majority's.
	if previous and top and votes[who].sig ~= top and now - (previous.t or 0) <= Data.FRESH then
		previous.vouch = votes
		if not previous.outvoted then ns.Log("conflict on %s: %s's report is not what the other senders say", r.guild, who) end
		previous.outvoted = true
		ns.Fire("DATA_CHANGED")
		return false
	end
	-- Shown in the census: the senders are split on this guild (no picture leads).
	local pictures = 0
	for _ in pairs(tops) do pictures = pictures + 1 end
	r.conflict = (top == nil and pictures > 1) and true or nil
	if r.conflict and not (previous and previous.conflict) then
		ns.Log("conflict on %s: the senders are split on it", r.guild)
	end
	ns.rdb.guilds[r.guild] = r
	ns.Fire("DATA_CHANGED")
	return true
end

-- What rank does this sender really have in that guild? Our own guild: from our roster.
-- Other guilds: from that guild's report (leader = 0, officers = 1). nil = unknown.
-- soft: for what only shows (the King's layer line and crown), one report naming them is
-- enough while no other one disagrees; the Crown's powers need two. Both wait CROWN_AFTER
-- after login, when the real reports have come in (a lone forged one would be alone then).
-- Another guild's rank comes with the number of senders of the leading picture naming them,
-- theirs included (1.0.0: the borders ask two for any rank, Borders.lua).
function Data.KnownRank(sender, guild, soft)
	local who = ns.FullName(sender)
	if guild == GetGuildInfo("player") then return ns.Roster.RankOf(who) end
	if NetOff(guild) then return nil end -- (1.1: a guild off the network ranks nobody on another's client)
	local g = Data.Guild(guild)
	local now = ns.Now()
	-- A report kept from an earlier session proves nothing about who leads the guild now.
	if not g or now - (g.t or 0) > Data.FRESH then return nil end
	local votes = Votes(g.vouch, now)
	local _, _, tops = Majority(votes, now)
	-- The rank the leading picture gives (every leading picture, if they tie: then only what
	-- they all agree on counts), named by someone else too: a report never proves its own
	-- sender's rank. The Crown (every guild master, the officers of <Sylvanistas>) needs two
	-- senders naming them (theirs may be one).
	-- A sender is itself by its name alone: "the Dark Lady-OtherRealm" can't vouch for "the Dark Lady-Realm".
	local self = ns.ShortName(who)
	local bySig, total, named, others = {}, 0, 0, 0
	for src, v in pairs(votes) do
		if tops[v.sig] then
			if ns.ShortName(src) ~= self then total = total + 1 end
			local k = v.ranks[who]
			if bySig[v.sig] == nil then bySig[v.sig] = k or false end
			if k then
				named = named + 1
				if ns.ShortName(src) ~= self then others = others + 1 end
				if bySig[v.sig] and k < bySig[v.sig] then bySig[v.sig] = k end
			end
		end
	end
	local rank
	for sig in pairs(tops) do
		local k = bySig[sig]
		if not k or (rank and k ~= rank) then return nil end
		rank = k
	end
	if not rank or others < 1 then return nil end
	-- A picture cut at MAX_OFFICERS leaves the officers out of its signature: an officer needs
	-- most of the other senders of the leading picture to name them, not just one.
	if rank > 0 and others * 2 <= total then
		for sig in pairs(tops) do
			if sig:sub(-2) == ",+" then return nil end
		end
	end
	if ns.IsCrownRank(guild, rank) then
		if named < 2 and not soft then return nil end
		if now - (ns.Comm and ns.Comm.loginAt or 0) < Data.CROWN_AFTER then return nil end
	end
	return rank, named
end

function Data.Summary()
	local now = ns.Now()
	local s = { total = 0, online = 0, fresh = 0, newest = 0, guilds = {}, zones = {}, zoneGuilds = {}, zoneList = {} }
	for name, g in pairs(ns.rdb.guilds) do
		if ns.IsFederation(name) and not NetOff(name) then
			local age = now - (g.t or 0)
			local fresh = age <= Data.FRESH
			-- A guild keeps its size from its last report when its reporters log off (the army
			-- does not shrink every night), for a day; listed (grey) for a week; who is online
			-- and where only count while fresh.
			if age <= Data.KEEP then
				s.guilds[#s.guilds + 1] = { name = name, g = g, fresh = fresh, counted = age <= Data.TOTAL_KEEP }
				if age <= Data.TOTAL_KEEP then s.total = s.total + math.min(g.total or 0, ns.Codec.GUILD_CAP) end
			end
			if fresh then
				s.fresh = s.fresh + 1
				s.online = s.online + (g.online or 0)
				if (g.t or 0) > s.newest then s.newest = g.t end
				for key, n in pairs(g.zones or {}) do
					s.zones[key] = (s.zones[key] or 0) + n
					s.zoneGuilds[key] = s.zoneGuilds[key] or {}
					s.zoneGuilds[key][name] = n
				end
			end
		end
	end
	table.sort(s.guilds, function(a, b)
		if a.fresh ~= b.fresh then return a.fresh end
		if (a.g.total or 0) ~= (b.g.total or 0) then return (a.g.total or 0) > (b.g.total or 0) end
		return a.name < b.name
	end)
	-- 1.1: a count of people. The characters their players linked as alts (Alts.lua: confirmed on
	-- each character) count once in the army's total, whatever guilds they are in; each guild's own
	-- size stays its roster's. s.characters: the total before.
	s.characters, s.alts = s.total, 0
	local A = ns.Alts
	if A and A.Duplicates then
		local counted = {}
		for _, e in ipairs(s.guilds) do if e.counted then counted[e.name:lower()] = true end end
		local dup = A.Duplicates(counted) -- (nil from the stand-in until the game restarts)
		s.alts = math.max(0, math.min(s.total, tonumber(dup) or 0))
		s.total = s.total - s.alts
	end
	-- Guilds only /who has seen, for the census list alone: in no total, tree or map.
	s.seen = {}
	for name, e in pairs(Data.Seen()) do
		if ns.IsFederation(name) and not NetOff(name) and not ns.rdb.guilds[name] and type(e) == "table" and now - (e.t or 0) <= Data.KEEP then
			s.seen[#s.seen + 1] = { name = name, online = e.online or 0, capped = e.capped, t = e.t }
		end
	end
	table.sort(s.seen, function(a, b)
		if a.online ~= b.online then return a.online > b.online end
		return a.name < b.name
	end)
	for key, n in pairs(s.zones) do s.zoneList[#s.zoneList + 1] = { key = key, count = n } end
	table.sort(s.zoneList, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.key < b.key
	end)
	return s
end

-- Tonight's count (1.1, request #16): this client's own view of the evening, from the reports it
-- already holds. Once a minute (Data.EVENING_EVERY) it reads the online total and each zone's
-- count (Data.Summary: fresh reports only, zones only from reporters who share them), and keeps
-- the peak and, per zone, its first count, so the Census shows whether a zone fills or empties.
-- It starts a full reporting cycle after login (Data.CROWN_AFTER, about 3 minutes): before that
-- the census is still rebuilding and every count would look like growth. In memory only, never
-- saved and never sent: another client counts its own evening, so it is labelled "this client".
Data.EVENING_EVERY = 60
local evening = { samples = 0, zones = {} }
function Data.Evening() return evening end
function Data.ResetEvening() evening = { samples = 0, zones = {} } end -- tests

-- One sample, at `now`; false while the census is rebuilding after login.
function Data.SampleEvening(now)
	now = now or ns.Now()
	local loginAt = ns.Comm and ns.Comm.loginAt
	if loginAt and now - loginAt < Data.CROWN_AFTER then return false end
	local s = Data.Summary()
	local e = evening
	if e.samples == 0 then e.since = now end
	e.samples, e.t, e.online = e.samples + 1, now, s.online
	if not e.peak or s.online > e.peak then e.peak, e.peakAt = s.online, now end
	-- A zone nobody stood in at the first sample started at 0; one left empty since is at 0 now.
	for key, z in pairs(e.zones) do
		if not s.zones[key] then z.now = 0 end
	end
	for key, n in pairs(s.zones) do
		local z = e.zones[key]
		if not z then
			z = { first = e.samples == 1 and n or 0 }
			e.zones[key] = z
		end
		z.now = n
		if not z.peak or n > z.peak then z.peak = n end
	end
	return true
end

-- A zone's count now and how it moved since the first sample (nil before any sample).
function Data.ZoneTrend(key)
	local z = evening.zones[key]
	if not z or evening.samples == 0 then return nil end
	return z.now or 0, (z.now or 0) - (z.first or 0)
end

ns.On("LOGIN", function()
	ns.Every(Data.EVENING_EVERY, "evening count", function() Data.SampleEvening() end)
end)

function Data.DiscordText()
	local s = Data.Summary()
	local F = ns.FormatNumber
	local out = {}
	out[#out + 1] = L.DISCORD_HEADER:format(F(s.total), F(s.online), #s.guilds)
	local where = {}
	for i = 1, math.min(8, #s.zoneList) do
		local z = s.zoneList[i]
		where[#where + 1] = ns.Zones.NameForKey(z.key) .. " " .. F(z.count)
	end
	if #where > 0 then out[#out + 1] = L.DISCORD_WHERE .. table.concat(where, " · ") end
	out[#out + 1] = "```"
	out[#out + 1] = ("%-22s %7s %7s  %s"):format("Guild", "Members", "Online", "Leader")
	for _, e in ipairs(s.guilds) do
		local g = e.g
		local leader = g.leader and (g.leader .. (g.leaderOnline and " (on)" or "")) or "?"
		out[#out + 1] = ("%-22s %7s %7s  %s%s"):format(e.name, F(g.total), F(g.online), leader, e.fresh and "" or "  [stale]")
	end
	out[#out + 1] = "```"
	out[#out + 1] = ("_Sylvanistas addon v%s_"):format(ns.VERSION)
	return table.concat(out, "\n")
end
