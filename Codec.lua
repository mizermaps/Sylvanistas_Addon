local ADDON, ns = ...

-- Wire format. Pure functions, no WoW API, covered by tests/run.lua.
--
-- Report:  R2~guild~total~online~leader~leaderOnline~users~zones~classes~levels
--             ~ranks~officers~leaderDays~inactive7~inactive30~avgLevel10~top
--             ~leaderClass~leaderLevel~leaderZone~from~home
--   zones   "m1453=204,m1429=61,tThe Stockade=5"   (m = uiMapID, t = zone text we could not resolve)
--   classes "WA=40,PA=12,..."
--   levels  7 comma separated counts: 1-9, 10-19, ..., 50-59, 60+
--   from    the reporter's realm; home: the guild's home realm (older versions send neither
--           and stop reading at leaderZone)
--   faction (23) A|H; versions (24, v0.8.2) "0.8.2=3,0.8.1=1": the guild's addon users by
--           version (the author's Workshop). Older versions stop reading before either.
--   st (25, 1.0.0) the server time the report was made, in base 36 (empty without
--           GetServerTime); cap (26) a|b|c, what else the reporter's client takes part in
--           ("a": reporting alone); pres (27) "k3a.x9b": the realms of the guild's addon users
--           online, as Comm.RealmCode gives them, sorted. Versions before 1.0.0 read 24 fields
--           and leave these unread.
-- Chunk:   C<id>:<i>:<n>:<piece>   (addon messages are limited to 255 bytes)
-- Hello:   H1~<version>~<realm>    (sent on GUILD so members with the addon find each other;
--                                    older versions send no realm)
--          ~<p|s>[~z]              (the channel, public or sealed; z: it shares its zone, 0.9.1)
-- Chat:    M1~tier~guild~id~class~text   (tier A|C|L, id 0-9999 per part, class 2 letters or empty)

local Codec = {}
ns.Codec = Codec

Codec.CHUNK = 220
Codec.MAX_CHUNKS = 30
local MAX_COUNT = 10000
Codec.GUILD_CAP = 1000 -- a guild's members, at most (the game's cap): a bigger report is forged

local function clean(s)
	return (tostring(s or ""):gsub("[~=,:|\n\r]", ""))
end

local function split(s, sep)
	local out, start = {}, 1
	while true do
		local i = s:find(sep, start, true)
		if not i then
			out[#out + 1] = s:sub(start)
			return out
		end
		out[#out + 1] = s:sub(start, i - 1)
		start = i + #sep
	end
end
Codec.Split = split

-- WoW limits guild names to 24 characters, not bytes (an accented letter takes 2 or 3 bytes).
local function LongGuild(guild)
	return #guild > 72 or select(2, guild:gsub("[^\128-\191]", "")) > 24
end
Codec.LongGuild = LongGuild -- (1.1: the pinned line's guild, Channels.HandlePin)

-- A realm name from the wire: one word of at most 40 characters, no escape codes; nil otherwise.
function Codec.RealmField(v)
	if type(v) ~= "string" or #v > 40 or not v:find("^[^%s~|]+$") then return nil end
	return v
end

local function num(v)
	local n = tonumber(v)
	if not n or n ~= n then return nil end
	n = math.floor(n)
	if n < 0 then n = 0 elseif n > MAX_COUNT then n = MAX_COUNT end
	return n
end

-- "key=count" pairs, biggest counts first, at most `max` of them (so one guild spread over
-- many zones can never push its report past the message limits).
local function encMap(t, max)
	local list = {}
	for k, v in pairs(t or {}) do
		local key = clean(k)
		if key ~= "" and v and v > 0 then list[#list + 1] = { key, math.floor(v) } end
	end
	table.sort(list, function(a, b)
		if a[2] ~= b[2] then return a[2] > b[2] end
		return a[1] < b[1]
	end)
	local parts = {}
	for i = 1, math.min(#list, max or 60) do parts[i] = list[i][1] .. "=" .. list[i][2] end
	return table.concat(parts, ",")
end

local function decMap(s, maxEntries)
	local t, n = {}, 0
	for k, v in (s or ""):gmatch("([^,=]+)=(%d+)") do
		n = n + 1
		if n > maxEntries then break end
		t[k:sub(1, 48)] = num(v)
	end
	return t
end

-- Ordered list of "name=count" (rank names keep their rank order).
local function encList(list, max)
	local parts = {}
	for i = 1, math.min(#(list or {}), max) do
		local e = list[i]
		parts[#parts + 1] = clean(e.name) .. "=" .. math.floor(e.count or 0)
	end
	return table.concat(parts, ",")
end

local function decList(s, max)
	local out = {}
	for k, v in (s or ""):gmatch("([^,=]+)=(%d+)") do
		if #out >= max then break end
		out[#out + 1] = { name = k:sub(1, 32), count = num(v) or 0 }
	end
	return out
end

-- A person: "name:online:daysOffline:class:level:zoneKey" (the last three are optional,
-- older versions sent only the first three). Used for officers.
local function encPerson(o)
	return ("%s:%d:%d:%s:%d:%s"):format(clean(o.name), o.online and 1 or 0, math.floor(o.days or 0),
		clean(o.class or ""), math.floor(o.level or 0), clean(o.zone or ""))
end

local function decPerson(entry)
	local p = split(entry, ":")
	if not p[1] or p[1] == "" or not p[2] then return nil end
	return {
		name = p[1]:sub(1, 48),
		online = p[2] == "1",
		days = num(p[3]) or 0,
		class = (p[4] and p[4] ~= "") and p[4]:sub(1, 12) or nil,
		level = num(p[5]),
		zone = (p[6] and p[6] ~= "") and p[6]:sub(1, 40) or nil,
	}
end

local function encOfficers(list, max)
	local parts = {}
	for i = 1, math.min(#(list or {}), max) do parts[#parts + 1] = encPerson(list[i]) end
	return table.concat(parts, ",")
end

local function decOfficers(s, max)
	local out = {}
	for entry in (s or ""):gmatch("[^,]+") do
		if #out >= max then break end
		local o = decPerson(entry)
		if o then out[#out + 1] = o end
	end
	return out
end

-- Top levels: "name:level:class".
local function encTop(list, max)
	local parts = {}
	for i = 1, math.min(#(list or {}), max) do
		parts[#parts + 1] = ("%s:%d:%s"):format(clean(list[i].name), math.floor(list[i].level or 0), clean(list[i].class or ""))
	end
	return table.concat(parts, ",")
end

local function decTop(s, max)
	local out = {}
	for entry in (s or ""):gmatch("[^,]+") do
		if #out >= max then break end
		local p = split(entry, ":")
		if p[1] and p[1] ~= "" and num(p[2]) then
			out[#out + 1] = { name = p[1]:sub(1, 48), level = math.min(num(p[2]), 100), class = (p[3] and p[3] ~= "") and p[3]:sub(1, 12) or nil }
		end
	end
	return out
end

Codec.MAX_OFFICERS = 30
Codec.MAX_RANKS = 10
Codec.MAX_TOP = 5
Codec.MAX_PRES = 12 -- realms named in field 27, at most
Codec.CAPS = { a = true, b = true, c = true }

-- A whole number >= 0 in base 36 (lowercase), and back: at most 8 digits, nil otherwise.
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
function Codec.Base36(n)
	n = math.floor(tonumber(n) or -1)
	if n < 0 then return nil end
	local out = ""
	repeat
		local d = n % 36
		out = B36:sub(d + 1, d + 1) .. out
		n = math.floor(n / 36)
	until n == 0
	return out
end
local function unBase36(s)
	if type(s) ~= "string" or #s > 8 or not s:find("^[0-9a-z]+$") then return nil end
	return tonumber(s, 36)
end

-- Field 27: realm codes (three letters or digits each), each once, sorted, MAX_PRES at most.
local function encPres(list)
	local out, seen = {}, {}
	for _, code in ipairs(list or {}) do
		if type(code) == "string" and code:find("^[0-9a-z][0-9a-z][0-9a-z]$") and not seen[code] then
			seen[code], out[#out + 1] = true, code
		end
	end
	table.sort(out)
	return table.concat(out, ".", 1, math.min(#out, Codec.MAX_PRES))
end
local function decPres(s)
	if type(s) ~= "string" or s == "" then return nil end
	local out, seen = {}, {}
	for code in s:gmatch("[^%.]+") do
		if #out >= Codec.MAX_PRES then break end
		if code:find("^[0-9a-z][0-9a-z][0-9a-z]$") and not seen[code] then seen[code], out[#out + 1] = true, code end
	end
	return #out > 0 and out or nil
end

function Codec.EncodeReport(r)
	local levels = {}
	for i = 1, 7 do levels[i] = math.floor((r.levels and r.levels[i]) or 0) end
	return table.concat({
		"R2",
		clean(r.guild),
		math.floor(r.total or 0),
		math.floor(r.online or 0),
		clean(r.leader or ""),
		r.leaderOnline and 1 or 0,
		math.floor(r.users or 0),
		encMap(r.zones),
		encMap(r.classes),
		table.concat(levels, ","),
		encList(r.ranks, Codec.MAX_RANKS),
		encOfficers(r.officers, Codec.MAX_OFFICERS),
		math.floor(r.leaderDays or 0),
		math.floor(r.inactive7 or 0),
		math.floor(r.inactive30 or 0),
		math.floor((r.avgLevel or 0) * 10),
		encTop(r.top, Codec.MAX_TOP),
		clean(r.leaderClass or ""),
		math.floor(r.leaderLevel or 0),
		clean(r.leaderZone or ""),
		clean(r.from or ""),
		clean(r.home or ""),
		r.faction == "Horde" and "H" or "A",
		encMap(r.versions, 12),
		Codec.Base36(r.st) or "",
		Codec.CAPS[r.cap] and r.cap or "",
		encPres(r.pres),
	}, "~")
end

-- The report as it may leave this client (0.9.1): a copy, where people are only with their
-- yes. counts: the members per zone (numbers only) stay; shares(name): true for a leader or
-- officer whose zone may be named. Without either, no zone at all. The fields stay, empty,
-- so every version decodes it (an empty zone reads as none).
function Codec.Shareable(r, counts, shares)
	local out = {}
	for k, v in pairs(r) do out[k] = v end
	if not counts then out.zones = {} end
	if not (shares and r.leader and shares(r.leader)) then out.leaderZone = nil end
	out.officers = {}
	for i, o in ipairs(r.officers or {}) do
		local copy = {}
		for k, v in pairs(o) do copy[k] = v end
		if not (shares and shares(o.name)) then copy.zone = nil end
		out.officers[i] = copy
	end
	return out
end

-- Only version numbers ("0.8.2") and "?" as keys: nothing else reaches the author's tab.
function Codec.Versions(map)
	local out = {}
	for k, v in pairs(map or {}) do
		if (k == "?" or k:match("^%d+%.%d+%.%d+$")) and #k <= 12 then out[k] = v end
	end
	return out
end

function Codec.DecodeReport(s)
	if type(s) ~= "string" or #s > Codec.CHUNK * Codec.MAX_CHUNKS then return nil end
	local f = split(s, "~")
	if (f[1] ~= "R1" and f[1] ~= "R2") or #f < 10 then return nil end
	local guild = f[2]
	if guild == "" or LongGuild(guild) then return nil end
	local total, online = num(f[3]), num(f[4])
	if not total or not online or total > Codec.GUILD_CAP then return nil end
	local levels = {}
	local lv = split(f[10], ",")
	for i = 1, 7 do levels[i] = num(lv[i]) or 0 end
	local leader = f[5] ~= "" and f[5]:sub(1, 48) or nil
	return {
		guild = guild,
		total = total,
		online = math.min(online, total > 0 and total or online),
		leader = leader,
		leaderOnline = f[6] == "1",
		users = num(f[7]) or 0,
		zones = decMap(f[8], 120),
		classes = decMap(f[9], 20),
		levels = levels,
		ranks = decList(f[11], Codec.MAX_RANKS),
		officers = decOfficers(f[12], Codec.MAX_OFFICERS),
		leaderDays = num(f[13]) or 0,
		inactive7 = num(f[14]) or 0,
		inactive30 = num(f[15]) or 0,
		avgLevel = (num(f[16]) or 0) / 10,
		top = decTop(f[17], Codec.MAX_TOP),
		leaderClass = (f[18] and f[18] ~= "") and f[18]:sub(1, 12) or nil,
		leaderLevel = num(f[19]),
		leaderZone = (f[20] and f[20] ~= "") and f[20]:sub(1, 40) or nil,
		from = Codec.RealmField(f[21]),
		home = Codec.RealmField(f[22]),
		-- Field 23 (v0.7.13): the reporter's faction. Older versions send none: Alliance.
		faction = f[23] == "H" and "Horde" or "Alliance",
		-- Field 24 (v0.8.2): the guild's addon users by version ("0.8.2", or "?" for unknown).
		versions = Codec.Versions(decMap(f[24], 12)),
		-- Fields 25-27 (1.0.0): when it was made (server time), the reporter's part, and the
		-- realms of the guild's addon users. Older versions send none: nil.
		st = unBase36(f[25]),
		cap = Codec.CAPS[f[26] or ""] and f[26] or nil,
		pres = decPres(f[27]),
	}
end

---------------------------------------------------------------------------
-- Small single-message types (always < 255 bytes, never chunked)
--   P1~mapID~x~y~class          guild only: my position (x, y in 0..1000)
--   L1~mapID~zoneUID~rankIndex~guild     channel: the layer I am on
--   D1~kind~mapID~x~y~guild~rankIndex~text   channel: decree (ARMS / MUSTER)
---------------------------------------------------------------------------

function Codec.EncodePosition(mapID, x, y, class)
	return ("P1~%d~%d~%d~%s"):format(mapID, math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5), clean(class or ""))
end

function Codec.DecodePosition(s)
	local mapID, x, y, class = s:match("^P1~(%d+)~(%d+)~(%d+)~(%w*)$")
	if not mapID then return nil end
	x, y = tonumber(x), tonumber(y)
	if x > 1000 or y > 1000 then return nil end
	return { mapID = tonumber(mapID), x = x / 1000, y = y / 1000, class = class ~= "" and class or nil }
end

function Codec.EncodeLayer(mapID, zoneUID, rankIndex, guild)
	return ("L1~%d~%d~%d~%s"):format(mapID, zoneUID, rankIndex or 9, clean(guild or ""))
end

function Codec.DecodeLayer(s)
	local mapID, zoneUID, rank, guild = s:match("^L1~(%d+)~(%d+)~(%d+)~(.*)$")
	if not mapID or LongGuild(guild) then return nil end
	return { mapID = tonumber(mapID), zoneUID = tonumber(zoneUID), rank = math.min(tonumber(rank), 9), guild = guild }
end

Codec.DECREE_KINDS = { ARMS = true, MUSTER = true, ROYAL = true, HERALDRY = true }

-- Wall of Shame (chunked, channel): S1~guild~rankIndex~name:guild,name:guild,...
Codec.MAX_SHAME = 40

function Codec.EncodeShame(guild, rankIndex, list)
	local parts = {}
	for i = 1, math.min(#list, Codec.MAX_SHAME) do
		parts[#parts + 1] = clean(list[i].name) .. ":" .. clean(list[i].guild or "")
	end
	return ("S1~%s~%d~%s"):format(clean(guild), rankIndex or 9, table.concat(parts, ","))
end

function Codec.DecodeShame(s)
	local guild, rank, body = s:match("^S1~([^~]*)~(%d+)~(.*)$")
	if not guild or LongGuild(guild) then return nil end
	local list = {}
	for name, g in body:gmatch("([^,:]+):([^,]*)") do
		if #list >= Codec.MAX_SHAME then break end
		-- Shown on every screen (the Tabards tab): a character name and a guild name, never
		-- colour or link codes.
		name, g = name:gsub("[|%c]", ""), g:gsub("[|%c]", "")
		if name ~= "" then list[#list + 1] = { name = name:sub(1, 48), guild = g:sub(1, 24) } end
	end
	return { guild = guild, rank = tonumber(rank), list = list }
end

function Codec.EncodeDecree(kind, mapID, x, y, guild, rankIndex, text)
	local msg = ("D1~%s~%d~%d~%d~%s~%d~"):format(kind, mapID, math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5), clean(guild or ""), rankIndex or 9)
	return msg .. clean(text or ""):sub(1, 250 - #msg)
end

function Codec.DecodeDecree(s)
	local kind, mapID, x, y, guild, rank, text = s:match("^D1~(%u+)~(%d+)~(%d+)~(%d+)~([^~]*)~(%d+)~(.*)$")
	if not kind or not Codec.DECREE_KINDS[kind] or LongGuild(guild) then return nil end
	x, y = tonumber(x), tonumber(y)
	if x > 1000 or y > 1000 then return nil end
	return { kind = kind, mapID = tonumber(mapID), x = x / 1000, y = y / 1000, guild = guild, rank = tonumber(rank), text = text:sub(1, 120) }
end

---------------------------------------------------------------------------
-- Chat lines of the channels (Channels.lua): M1~tier~guild~id~class~text
-- The text is the last field, so it keeps ~ : , = as typed. Each message is one line part
-- (never chunked): a long line is split into at most CHAT_PARTS messages that stand alone.
---------------------------------------------------------------------------

Codec.CHAT_MAX = 250
Codec.CHAT_PARTS = 3
Codec.CHAT_TIERS = { A = true, C = true, L = true }
-- (0.9.2: no achievement links, which none of our clients has, and whose data is not numbers.)
local LINK_TYPES = { item = true, spell = true, enchant = true, quest = true }

-- A link's data as the game writes it for these types (0.9.2): an id from 1, then at most 31
-- more fields, each empty or a whole number ("19019::::::::60::" or "5:-1"), 120 bytes at
-- most. Anything else (letters, an empty or zero id, a field the size of a novel) could be a
-- malformed link made to break the client's tooltip, and is shown as plain text.
local function LinkData(data)
	if #data > 120 then return false end
	local n = 0
	for field in (data .. ":"):gmatch("([^:]*):") do
		n = n + 1
		if n == 1 and not field:find("^[1-9]%d?%d?%d?%d?%d?%d?%d?%d?$") then return false end
		if n > 32 or #field > 11 or not (field == "" or field:find("^%-?%d+$")) then return false end
	end
	return true
end

-- Length of a link we let through that starts at i, or nil: an optional colour (Classic
-- |cAARRGGBB or Mainline |cnNAME:), |Htype:data|h[text]|h with a whitelisted type and data
-- (LinkData), and |r when it was coloured. Shift-clicked items and spells look exactly like
-- this. A control byte in the text (a newline that fakes a second chat line) means it is not
-- a link we keep, and so does an empty name, a bracket in it, or one past 100 bytes.
local function LinkAt(s, i)
	local j = i
	local color = s:match("^|c%x%x%x%x%x%x%x%x", j) or s:match("^|cn[%w_]+:", j)
	if color then
		if #color > 40 then return nil end
		j = j + #color
	end
	local kind, data, text = s:match("^|H(%a+):([^|]*)|h%[([^|%[%]%c]*)%]|h", j)
	if not kind or not LINK_TYPES[kind] or not LinkData(data) or text == "" or #text > 100 then return nil end
	j = j + #kind + #data + #text + 9 -- "|H" ":" "|h[" "]|h"
	if color then
		if s:sub(j, j + 1) ~= "|r" then return nil end
		j = j + 2
	end
	return j - i
end
Codec.LinkAt = LinkAt

-- Chat text as it may be shown: whitelisted links and "||" stay, every other "|" becomes "||"
-- (so textures, atlases, colours, fake links and the like show as plain text), control bytes go.
-- Idempotent: the sender's own echo is exactly what everyone else sees.
function Codec.SanitizeChat(s)
	s = tostring(s or "")
	local out, i, n = {}, 1, #s
	while i <= n do
		local j = s:find("[%z\1-\31|\127]", i)
		if not j then
			out[#out + 1] = s:sub(i)
			break
		end
		if j > i then out[#out + 1] = s:sub(i, j - 1) end
		if s:byte(j) ~= 124 then
			i = j + 1 -- control byte: dropped
		elseif s:byte(j + 1) == 124 then
			out[#out + 1] = "||"
			i = j + 2
		else
			local len = LinkAt(s, j)
			out[#out + 1] = len and s:sub(j, j + len - 1) or "||"
			i = j + (len or 1)
		end
	end
	-- Runs of spaces become one: padding could push a fake "[Lords] [Asmon] ..." to the start
	-- of a wrapped line.
	return (table.concat(out):gsub("%s%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Any other text from another player, as it may be shown (0.9.2): no "|" at all (every escape
-- code starts with one: colours, textures, atlases, links) and no control bytes. Comm runs
-- every message but a chat line through it before anything reads it; a chat line keeps the
-- links SanitizeChat allows.
function Codec.Plain(s)
	return (tostring(s or ""):gsub("[|%c]", ""))
end

-- For what versions before 0.9.2 kept, which let escape codes in: does a stored value carry
-- one (or a control byte) in any string, key or table inside it?
function Codec.Dirty(v, depth)
	if type(v) == "string" then return v:find("[|%c]") ~= nil end
	depth = depth or 0
	if type(v) ~= "table" or depth > 6 then return false end
	for k, x in pairs(v) do
		if Codec.Dirty(k, depth + 1) or Codec.Dirty(x, depth + 1) then return true end
	end
	return false
end

-- Text pasted into Discord (the copy box) pings nobody (0.9.2): a zero-width space after every
-- "@" (@everyone, @here, @name, <@id>, <@&role>) and inside "<#" (a channel). Discord shows the
-- text as written and reads no mention in it. Idempotent.
local ZWSP = "\226\128\139"
function Codec.NoMentions(s)
	s = tostring(s or ""):gsub("@" .. ZWSP, "@"):gsub("<" .. ZWSP .. "#", "<#")
	return (s:gsub("@", "@" .. ZWSP):gsub("<#", "<" .. ZWSP .. "#"))
end

-- Room for the text in one message: CHAT_MAX minus "M1~", the tier, 4 separators, a 4 digit id,
-- the guild and the class.
function Codec.ChatBudget(guild, class)
	return Codec.CHAT_MAX - (12 + #clean(guild) + #clean(class))
end

local function IsContinuation(b)
	return b ~= nil and b >= 128 and b < 192
end

-- Splits sanitized text into at most maxParts parts of at most `budget` bytes each. A cut never
-- lands inside a UTF-8 character, a link or a "||", and falls on a space when one is near.
-- Returns parts, cut (true when text beyond maxParts was lost).
function Codec.SplitChat(s, budget, maxParts)
	local parts = {}
	s = (s or ""):gsub("^%s+", "")
	while s ~= "" and #parts < maxParts do
		if #s <= budget then
			parts[#parts + 1] = s
			s = ""
			break
		end
		-- Walk span by span ("||", a whole link, or one byte) up to the budget.
		local cut, i, space = 0, 1, nil
		while i <= #s do
			local len = 1
			if s:byte(i) == 124 then len = s:byte(i + 1) == 124 and 2 or LinkAt(s, i) or 1 end
			if i + len - 1 > budget then break end
			if len == 1 and s:byte(i) == 32 then space = i end
			cut = i + len - 1
			i = i + len
		end
		if cut < 1 then cut = budget end -- one link longer than the budget: shown as plain text
		while cut > 1 and IsContinuation(s:byte(cut + 1)) do cut = cut - 1 end
		-- Only spaces between spans count: a link's name can have spaces too.
		if space and space > 1 and space <= cut and space > cut - 40 then cut = space - 1 end
		parts[#parts + 1] = (s:sub(1, cut):gsub("%s+$", ""))
		s = s:sub(cut + 1):gsub("^%s+", "")
	end
	return parts, s ~= ""
end

-- `text` must already be sanitized and split to fit (Channels.Send does both).
function Codec.EncodeChat(tier, guild, id, class, text)
	local msg = ("M1~%s~%s~%d~%s~"):format(tier, clean(guild), id % 10000, clean(class or "")) .. text
	if #msg > 255 then return nil end
	return msg
end

function Codec.DecodeChat(s)
	if type(s) ~= "string" or #s > 255 then return nil end
	local tier, guild, id, class, text = s:match("^M1~(%u)~([^~|]+)~(%d%d?%d?%d?)~(%u?%u?)~(.+)$")
	if not tier or not Codec.CHAT_TIERS[tier] or LongGuild(guild) or guild:find("%c") then return nil end
	text = Codec.SanitizeChat(text)
	if text == "" then return nil end
	return { tier = tier, guild = guild, id = tonumber(id), class = class ~= "" and class or nil, text = text }
end

function Codec.Chunk(payload, id)
	local n = math.max(1, math.ceil(#payload / Codec.CHUNK))
	local out = {}
	for i = 1, n do
		out[i] = ("C%s:%d:%d:"):format(id, i, n) .. payload:sub((i - 1) * Codec.CHUNK + 1, i * Codec.CHUNK)
	end
	return out
end

-- Pieces waiting for the rest are bounded (0.9.3): a few open messages per sender and a few
-- hundred in all, so nobody can fill memory with pieces that never complete.
Codec.OPEN_PER_SENDER = 4
Codec.OPEN_MAX = 400
function Codec.NewAssembler()
	return { buf = {}, open = 0, bySender = {}, refused = 0 }
end

-- Returns the full payload once every chunk from this sender/id arrived.
function Codec.Feed(asm, sender, msg, now)
	local id, i, n, body = msg:match("^C(%w+):(%d+):(%d+):(.*)$")
	if not id then return nil end
	i, n = tonumber(i), tonumber(n)
	if n < 1 or n > Codec.MAX_CHUNKS or i < 1 or i > n then return nil end
	local key = sender .. "#" .. id
	local e = asm.buf[key]
	if not e or e.n ~= n then
		if not e then
			local mine = asm.bySender[sender] or 0
			if mine >= Codec.OPEN_PER_SENDER or asm.open >= Codec.OPEN_MAX then
				asm.refused = asm.refused + 1
				return nil
			end
			asm.bySender[sender], asm.open = mine + 1, asm.open + 1
		end
		e = { n = n, parts = {}, got = 0, t = now, sender = sender }
		asm.buf[key] = e
	end
	if not e.parts[i] then
		e.parts[i] = body
		e.got = e.got + 1
	end
	if e.got == n then
		Codec.Close(asm, key)
		return table.concat(e.parts)
	end
	return nil
end

function Codec.Close(asm, key)
	local e = asm.buf[key]
	if not e then return end
	asm.buf[key] = nil
	asm.open = math.max(0, asm.open - 1)
	local left = (asm.bySender[e.sender] or 1) - 1
	asm.bySender[e.sender] = left > 0 and left or nil
end

-- Drops assemblies older than 60 s and returns how many were incomplete, with a sample
-- ("sender#id 2/3") so lost chunks show up in the diagnostics.
function Codec.Gc(asm, now)
	local dropped, sample = 0, nil
	for k, e in pairs(asm.buf) do
		if now - e.t > 60 then
			dropped = dropped + 1
			sample = sample or ("%s %d/%d"):format(k, e.got, e.n)
			Codec.Close(asm, k)
		end
	end
	return dropped, sample
end

-- One reporter per guild: the alphabetically first member that has the addon and was
-- seen recently. Everyone computes the same answer, so no negotiation is needed.
function Codec.PickReporter(selfName, peers, now, window)
	local best = selfName
	for name, t in pairs(peers) do
		if now - t <= window and name < best then best = name end
	end
	return best
end
