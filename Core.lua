local ADDON, ns = ...
local L = ns.L

---------------------------------------------------------------------------
-- SYLVANISTAS SETTINGS. Every "CHANGEME_" below is a placeholder: no real character can carry
-- an underscore in its name, so each role it names stays empty (nobody has it) until it is
-- filled in. Names are exact, as the game writes them (Forever: "Firstname Surname").
---------------------------------------------------------------------------
ns.FACTION_ONLY = "Horde"                      -- the addon runs for this faction alone (ns.IsMember)
ns.GUILD_NAME = "Sylvanistas"                  -- the main guild's exact name (any case)
ns.GM_CHARACTER = "Testiana Paladina"          -- the guild master (the Dark Lady): her character's exact name
ns.GM_REALM = "ClassicBetaPvE"                 -- her realm group (e.g. "ClassicBetaPvE"); nil: learned from her first message, see /syl status
ns.GM_DISPLAY = "Dark Lady"                   -- what the addon calls her on the lines and the crown
ns.AUTHOR_CHARACTER = "Riztosin Psalmpalm"      -- the addon keeper's character (the Workshop tab, bug reports, signed lists)
ns.REALM_GROUP = "ClassicBetaPvE"              -- the author's and Treasurer's realm group (e.g. "ClassicBetaPvP")
ns.TREASURER_CHARACTER = "CHANGEME_Treasurer"  -- the Treasurer (in the main guild)
ns.TREASURER_MAIL_CHARACTER = "CHANGEME_TreasurerMail" -- where dues and treasury mail go (any guild)
ns.TREASURY_OFF = true                        -- true turns the Treasury, Dues and Bank tabs off
ns.WALL_OF_SHAME = false                       -- true lets the Dark Lady show the untabarded list to every member (the "Wall of Shame")

ns.NAME = "Sylvanistas"
ns.VERSION = "1.2.0"
ns.PREFIX = "SYLVANISTAS"        -- addon message prefix (max 16 chars)
ns.CHANNEL = "SylvanistasNet"    -- hidden chat channel (Alliance: unused, the addon is Horde-only)
ns.CHANNEL_HORDE = "SylvanistasNetH" -- the Horde's hidden chat channel, shared by every Sylvanistas guild
ns.ICON = "Interface\\AddOns\\Sylvanistas\\media\\logo64"
ns.LOGO = "Interface\\AddOns\\Sylvanistas\\media\\logo128"
ns.EMBLEM = "Interface\\AddOns\\Sylvanistas\\media\\emblem128"
ns.COLOR = "ffe6c35c"

local DEFAULTS = {
	showMap = true,
	minimapAngle = 200,
	hideMinimap = false,
	debug = false,
	warnDays = 3,          -- leaders/officers offline this many days are flagged
	sharePosition = false, -- guildmate dots are disabled: positions are not live enough
	showMates = false,
	showDecrees = true,    -- show decree markers on the map
	sound = true,          -- alert sounds (throttled)
	showCamps = true,      -- camps on the world map (1.1, Board.lua)
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function ns.Now() return time() end

function ns.Print(msg)
	print("|c" .. ns.COLOR .. "Sylvanistas:|r " .. tostring(msg))
end

function ns.FormatNumber(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local sign, digits = s:match("^(%-?)(%d+)$")
	if not digits then return s end
	local out = digits:reverse():gsub("(%d%d%d)", "%1" .. L.THOUSANDS):reverse()
	if out:sub(1, #L.THOUSANDS) == L.THOUSANDS then out = out:sub(#L.THOUSANDS + 1) end
	return sign .. out
end

function ns.Ago(t)
	if not t or t == 0 then return L.NEVER end
	local d = math.max(0, ns.Now() - t)
	if d < 60 then return L.AGO_SEC:format(d) end
	if d < 3600 then return L.AGO_MIN:format(math.floor(d / 60)) end
	return L.AGO_HOUR:format(math.floor(d / 3600))
end

-- At most n bytes of s, never half a letter (an accented letter is two bytes or more).
function ns.Cut(s, n)
	s = tostring(s or "")
	if #s <= n then return s end
	local b = s:byte(n + 1)
	while n > 0 and b and b >= 128 and b < 192 do
		n = n - 1
		b = s:byte(n + 1)
	end
	return s:sub(1, n)
end

function ns.ShortName(name)
	if not name then return nil end
	return (name:gsub("%-.*$", ""))
end

-- This realm's key, the same form the server uses in "Name-Realm" (no spaces or dashes).
function ns.CurrentRealm()
	local realm = GetNormalizedRealmName and GetNormalizedRealmName()
	if not realm or realm == "" then realm = ((GetRealmName and GetRealmName()) or ""):gsub("[%s%-]", "") end
	return realm ~= "" and realm or "?"
end

-- Identity is always "Name-Realm". Names without a realm belong to `realm` (default: ours).
-- Comparing short names let a same-named player from another realm pass as someone else.
function ns.FullName(name, realm)
	if not name or name == "" or name:find("-", 1, true) then return name end
	realm = realm or ns.realm
	if not realm or realm == "" or realm == "?" then return name end
	return name .. "-" .. realm
end

function ns.RealmOf(name)
	return name and name:match("%-(.+)$")
end

-- Short name for people on our realm, Name-Realm for anyone else.
function ns.DisplayName(name)
	if not name then return nil end
	local realm = ns.RealmOf(name)
	if not realm or realm == ns.realm then return ns.ShortName(name) end
	return name
end

-- The name a whisper, an invite or /who takes. WoW: Forever's server finds "First Surname"
-- but not "First Surname-Realm" ("No player named ... is currently playing"), and its names
-- are one across a realm group: there the realm is left out for our realms. Elsewhere the
-- short name on our realm, Name-Realm for anyone else, as Blizzard's own chat does.
function ns.TellName(name)
	if type(name) ~= "string" or name == "" then return name end
	name = ns.Normal(name)
	local base, realm = name:match("^(.+)%-([^%-]+)$")
	if not realm then return name end
	if realm == ns.realm or realm == ns.CurrentRealm() or (ns.splitNames and ns.IsRealmName(realm)) then return base end
	return name
end

-- WoW: Forever's names are a first name and a surname ("Firstname Surname"), and its unit
-- functions hand the surname back where the realm goes: UnitFullName("player") gives
-- "Firstname", "Surname", and GetUnitName(unit, true) "Firstname-Surname". The server
-- stamps addon messages "Firstname Surname-ClassicBetaPvP", like the guild roster and /who:
-- that is the name everyone compares. ns.splitNames: this client splits names so (our own
-- "realm" is none).
function ns.IsRealmName(realm)
	if type(realm) ~= "string" or realm == "" then return false end
	if realm == ns.realm or realm == ns.CurrentRealm() or ns.InGroup(realm) then return true end
	return ns.GroupOf(realm) ~= realm -- a realm of a known group
end

function ns.PlayerName()
	local name, realm = UnitFullName("player")
	if not name then return "?" end
	local home = ns.realm or ns.CurrentRealm()
	if realm and realm ~= "" and realm ~= home and not ns.IsRealmName(realm) then
		ns.splitNames = true
		name, realm = name .. " " .. realm, nil
	end
	if not realm or realm == "" then realm = home end
	if realm and realm ~= "" and realm ~= "?" then return name .. "-" .. realm end
	return name
end

-- A name the game's functions or events give ("First-Surname" on Forever), as the server
-- writes it ("First Surname", with "-Realm" when it had one).
function ns.Normal(name)
	if not ns.splitNames or type(name) ~= "string" then return name end
	local first, rest = name:match("^([^%-]+)%-(.+)$")
	if not first or first:find(" ", 1, true) then return name end
	local surname, realm = rest:match("^([^%-]+)%-(.+)$")
	if surname and ns.IsRealmName(realm) then return first .. " " .. surname .. "-" .. realm end
	if ns.IsRealmName(rest) then return name end
	return first .. " " .. rest
end

-- A unit's full name as the server writes it ("Name-Realm"), or nil.
function ns.UnitFullName(unit)
	local name, realm
	if UnitFullName then name, realm = UnitFullName(unit) end
	if not name or name == "" then
		local n = GetUnitName and GetUnitName(unit, true)
		return n and ns.FullName(ns.Normal(n)) or nil
	end
	if realm and realm ~= "" and ns.splitNames and not ns.IsRealmName(realm) then name, realm = name .. " " .. realm, nil end
	return ns.FullName(name, (realm and realm ~= "") and realm or nil)
end

---------------------------------------------------------------------------
-- Realm groups. Realms whose guilds span each other share one census, one realm key and one
-- chat history: they are stored together under the group's name ("A+B", realms sorted).
-- ns.realm stays the character's own realm, for identities ("Name-Realm").
-- WoW: Forever's beta PvP realms are one group from the start (a guild of one is homed on
-- the other); any other link is learned from the roster (a guild homed on another realm).
---------------------------------------------------------------------------

local SEED_BETA = "ClassicBetaPvP+ClassicBetaPvP2"
local SEED = { ClassicBetaPvP = SEED_BETA, ClassicBetaPvP2 = SEED_BETA }

-- A realm name in the form the server uses in "Name-Realm", or nil when unusable.
local function CleanRealm(realm)
	if type(realm) ~= "string" then return nil end
	realm = realm:gsub("[%s%-]", "")
	if realm == "" or realm == "?" or realm:find("+", 1, true) then return nil end
	return realm
end

-- The group a realm belongs to: learned (db.links), else the seed, else the realm alone.
local function Learned(db, realm)
	local links = db and db.links
	local group = type(links) == "table" and links[realm]
	return type(group) == "string" and group ~= "" and group or nil
end

function ns.GroupOf(realm, db)
	return Learned(db or ns.db, realm) or SEED[realm] or realm
end

function ns.GroupRealms(group)
	local out = {}
	for realm in tostring(group or ""):gmatch("[^+]+") do out[#out + 1] = realm end
	return out
end

-- Where our group comes from, for /syl status: "learned", "seed" or "own" (not linked).
function ns.GroupSource(realm)
	if Learned(ns.db, realm) then return "learned" end
	if SEED[realm] then return "seed" end
	return "own"
end

-- Our faction: "Horde" or "Alliance". Sylvanistas started on the Alliance, so anything unknown
-- (reports of older versions, a client that can't tell yet) counts as Alliance.
function ns.Faction()
	local f = UnitFactionGroup and UnitFactionGroup("player")
	return f == "Horde" and "Horde" or "Alliance"
end

-- Each faction keeps its census, realm key and inspections apart: the Alliance in the
-- top-level db.realms (as before), the Horde in db.horde.realms.
local function Stores(db)
	if ns.faction ~= "Horde" then return db end
	if type(db.horde) ~= "table" then db.horde = {} end
	return db.horde
end

-- Is this realm one of the realms whose census we share (ours included)?
function ns.InGroup(realm)
	if not realm then return false end
	for _, r in ipairs(ns.GroupRealms(ns.group or ns.realm)) do
		if r == realm then return true end
	end
	return false
end

-- Newest `t` wins, per key; on a tie the entry already there stays.
local function MergeNewest(dst, src)
	if type(src) ~= "table" then return end
	for k, v in pairs(src) do
		local old = dst[k]
		if type(v) == "table" and (type(old) ~= "table" or (tonumber(v.t) or 0) > (tonumber(old.t) or 0)) then dst[k] = v end
	end
end

-- Inspections: newest wins too, but an officer's mark and note never go with the older entry
-- (false is an explicit unmark: it stays), nor the gear his click kept (1.1).
local function MergePlayers(dst, src)
	if type(src) ~= "table" then return end
	for k, v in pairs(src) do
		local old = dst[k]
		if type(v) == "table" then
			local keep, other = v, old
			if type(old) == "table" and (tonumber(v.t) or 0) <= (tonumber(old.t) or 0) then keep, other = old, v end
			if type(other) == "table" then
				if keep.marked == nil then keep.marked = other.marked end
				if keep.note == nil then keep.note = other.note end
				-- (1.1: the gear an officer's click kept, the newer of the two.)
				local g, o = keep.gear, other.gear
				if type(o) == "table" and (type(g) ~= "table" or (tonumber(o.t) or 0) > (tonumber(g.t) or 0)) then keep.gear = o end
			end
			dst[k] = keep
		end
	end
end

local CHAT_KEEP = 100 -- lines per tier, like Channels.lua's HISTORY

-- Chat lines of both stores in time order, each once, the newest CHAT_KEEP kept.
local function MergeChat(dst, src)
	for tier, list in pairs(src) do
		if type(list) == "table" then
			local out, seen = {}, {}
			local function Add(from)
				for _, e in ipairs(type(from) == "table" and from or {}) do
					local key = type(e) == "table" and (tostring(e.t) .. "\1" .. tostring(e.sender) .. "\1" .. tostring(e.text))
					if key and not seen[key] then
						seen[key] = true
						out[#out + 1] = e
					end
				end
			end
			Add(dst[tier])
			Add(list)
			table.sort(out, function(a, b) return (tonumber(a.t) or 0) < (tonumber(b.t) or 0) end)
			while #out > CHAT_KEEP do table.remove(out, 1) end
			dst[tier] = out
		end
	end
end

-- Moves one store into another, losing nothing that is newer. Our own guild's report (`mine`)
-- is kept like any other: an alt's own guild is a report nobody else may be sending. The
-- realm key is settled by OpenStore, which sees every store at once.
local function MergeStore(dst, src)
	for _, key in ipairs({ "guilds", "seen" }) do
		dst[key] = type(dst[key]) == "table" and dst[key] or {}
		MergeNewest(dst[key], src[key])
	end
	if type(src.inspect) == "table" then
		dst.inspect = type(dst.inspect) == "table" and dst.inspect or {}
		local d, s = dst.inspect, src.inspect
		d.players = type(d.players) == "table" and d.players or {}
		MergePlayers(d.players, s.players)
		d.guildMarks = type(d.guildMarks) == "table" and d.guildMarks or {}
		for k, v in pairs(type(s.guildMarks) == "table" and s.guildMarks or {}) do
			if d.guildMarks[k] == nil then d.guildMarks[k] = v end
		end
	end
	if type(src.chat) == "table" then
		dst.chat = type(dst.chat) == "table" and dst.chat or {}
		MergeChat(dst.chat, src.chat)
	end
	-- Anything else (the "shared" proof, fields of later versions): the newest, or whichever is set.
	for k, v in pairs(src) do
		if k ~= "guilds" and k ~= "seen" and k ~= "inspect" and k ~= "chat" and k ~= "realmKey" then
			local old = dst[k]
			if old == nil or (type(v) == "table" and type(old) == "table" and (tonumber(v.t) or 0) > (tonumber(old.t) or 0)) then dst[k] = v end
		end
	end
end

-- The group's store, with the store of each of its realms (or of a smaller group of them)
-- merged in and removed, so running it again changes nothing. Realm keys: one key, or the
-- same key everywhere, is kept; different keys are all dropped, and our officers hand ours
-- out again over guild chat (K0/K1 at login).
local function OpenStore(db, group)
	if type(db.realms) ~= "table" then db.realms = {} end
	local R = db.realms[group]
	if type(R) ~= "table" then R = {} end
	db.realms[group] = R
	local members = {}
	for _, realm in ipairs(ns.GroupRealms(group)) do members[realm] = true end
	-- Collect first: the merge must not change db.realms while pairs walks it.
	local merge = {}
	for key in pairs(db.realms) do
		if key ~= group and type(key) == "string" then
			local inside = true
			for _, realm in ipairs(ns.GroupRealms(key)) do
				if not members[realm] then inside = false end
			end
			if inside then merge[#merge + 1] = key end
		end
	end
	if #merge == 0 then return R end
	table.sort(merge)
	local keys, distinct = {}, 0
	local function Key(k)
		if type(k) == "string" and k ~= "" and not keys[k] then
			keys[k] = true
			distinct = distinct + 1
		end
	end
	Key(R.realmKey)
	for _, key in ipairs(merge) do
		local src = db.realms[key]
		if type(src) == "table" then
			Key(src.realmKey)
			-- A realm's own store (v0.7.8-0.7.10): its reports were heard on that realm (Data.Receive).
			if not key:find("+", 1, true) and type(src.guilds) == "table" then
				for _, g in pairs(src.guilds) do
					if type(g) == "table" and g.heardOn == nil then g.heardOn = key end
				end
			end
			MergeStore(R, src)
		end
		db.realms[key] = nil
	end
	if distinct == 1 then
		R.realmKey = next(keys)
	elseif distinct > 1 then
		R.realmKey = nil
	end
	ns.Log("census of %s merged into %s%s", table.concat(merge, ", "), group, distinct > 1 and " (different realm keys dropped)" or "")
	return R
end

-- Learns that realms a and b share guilds: their groups become one, for good (db.links).
-- If that changes our own group, the census moves over at once. Returns true if anything
-- was learned.
function ns.LinkRealms(a, b)
	local db = ns.db
	a, b = CleanRealm(a), CleanRealm(b)
	if not db or not a or not b or a == b then return false end
	local set, list = {}, {}
	for _, realm in ipairs({ a, b }) do
		for _, m in ipairs(ns.GroupRealms(ns.GroupOf(realm))) do
			if not set[m] then
				set[m] = true
				list[#list + 1] = m
			end
		end
	end
	table.sort(list)
	local group = table.concat(list, "+")
	local learned = false
	for _, m in ipairs(list) do
		if ns.GroupOf(m) ~= group then
			if type(db.links) ~= "table" then db.links = {} end
			db.links[m] = group
			learned = true
		end
	end
	if not learned then return false end
	ns.Log("realms linked: %s", group)
	local mine = ns.realm and ns.GroupOf(ns.realm)
	if mine and mine ~= ns.group then
		local oldKey = ns.rdb and ns.rdb.realmKey
		ns.group = mine
		ns.rdb = OpenStore(Stores(db), mine)
		ns.Print(L.REALMS_LINKED:format((mine:gsub("%+", " + "))))
		ns.Fire("DATA_CHANGED")
		-- A new key means another channel. Before our first join, that join picks it up (and
		-- the login's key request asks for a dropped key).
		if ns.rdb.realmKey ~= oldKey and ns.Comm and ns.Comm.ChannelName() then
			ns.Comm.JoinChannel()
			-- Ours was dropped (the realms had different keys): our officers hand it out again.
			if not ns.rdb.realmKey then ns.Comm.RequestKey() end
		end
	end
	return true
end

-- HereBeDragons-Pins, only if it loaded completely (a half-loaded library means no map
-- features instead of an error on every refresh).
function ns.Pins()
	local pins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
	if pins and pins.AddWorldMapIconMap and pins.RemoveAllWorldMapIcons and pins.AddMinimapIconMap then return pins end
	return nil
end

-- Whether `ref` (Map, Decree, King, Positions) puts its icons on the world map (0.9.9). Every
-- add or remove there goes through the pin library into the map's canvas (MarkCanvasDirty,
-- which clears its current zoom), from Sylvanistas's code. With Blizzard's gamepad UI (Forever) the
-- gamepad map then zooms, builds its button bar and closes with B in our taint, and the game
-- blocks it until a /reload. There no icon of ours goes on the world map; the minimap is not the
-- gamepad UI's, its icons stay. Icons `ref` put on the world map before a switch to the gamepad
-- UI (without a /reload) are taken off, once. With mouse and keyboard: true, as always.
local worldMapIconsOf = {} -- [ref] = true: may have icons on the world map
function ns.WorldMapIcons(pins, ref)
	if not ns.GamepadUI() then
		worldMapIconsOf[ref] = true
		return true
	end
	if worldMapIconsOf[ref] then
		worldMapIconsOf[ref] = nil
		pins:RemoveAllWorldMapIcons(ref)
	end
	return false
end

-- Round logo button with the exact geometry of minimap buttons (LibDBIcon layout at 31px,
-- scaled to the requested size): gold tracking ring, dark disc, round logo.
function ns.MakeRoundButton(name, parent, size)
	local k = size / 31
	local b = CreateFrame("Button", name, parent)
	b:SetSize(size, size)
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetSize(20 * k, 20 * k)
	bg:SetPoint("TOPLEFT", 7 * k, -5 * k)
	-- The logo, a disc (the mask): centred on the dark disc behind it (LibDBIcon's square
	-- icons sit 1.5 px off it, which the ring hides; a disc there shows a crescent).
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ns.LOGO)
	icon:SetSize(18 * k, 18 * k)
	icon:SetPoint("TOPLEFT", 8 * k, -6 * k)
	if icon.SetMask then pcall(icon.SetMask, icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
	local ring = b:CreateTexture(nil, "OVERLAY")
	ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	ring:SetSize(53 * k, 53 * k)
	ring:SetPoint("TOPLEFT")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	b.icon = icon
	return b
end

-- Each alert says what it is (its kind), and each kind has a sound switch of its own (1.1): one
-- switch for them all made players silence the Call to Arms with the chimes they did not want.
-- ns.db.sound stays the switch for every kind, as in 0.9 and 1.0 (their saves keep working);
-- ns.db.soundOff[kind] = true silences one kind. Local only: nothing is sent.
--   arms, muster, royal   the decrees (royal: the Royal decree and the Tabard inspection)
--   court, vox, agenda    the King's court, Vox Populi, the King's Agenda
--   throne                the King's other calls: the roll call, the Royal Inspection, writs, a Hand or Steward named
--   help                  a High Councillor's help requests, the author's bug reports
--   hop, treasury, patrol a layer hop, a donation, a patrol's player without the tabard
--   update                the author's update notice
ns.SOUND_KINDS = { "arms", "muster", "royal", "court", "vox", "agenda", "throne", "help", "hop", "treasury", "patrol", "update" }
-- Sylvanistas names for the kinds (typed and shown); the kinds themselves stay as saved.
ns.SOUND_ALIAS = { rise = "arms", gather = "muster", banshee = "royal", conclave = "court", audience = "court", voice = "vox", sanctum = "throne" }
ns.SOUND_NAME = { arms = "rise", muster = "gather", royal = "banshee", court = "conclave", vox = "voice", throne = "sanctum" }
local function KindNames(list)
	local out = {}
	for i, k in ipairs(list) do out[i] = ns.SOUND_NAME[k] or k end
	return out
end
local SOUND_KIND = {}
for _, k in ipairs(ns.SOUND_KINDS) do SOUND_KIND[k] = true end

-- The kind's own switch, whatever the one for all says.
function ns.SoundKindOn(kind)
	local off = ns.db and ns.db.soundOff
	return not (type(off) == "table" and off[kind])
end
-- Does an alert of this kind sound (nil: the switch for all alone)?
function ns.SoundOn(kind)
	if not (ns.db and ns.db.sound) then return false end
	return kind == nil or ns.SoundKindOn(kind)
end
-- kind nil: the switch for all. False for a kind there is not.
function ns.SetSound(kind, on)
	if kind == nil then
		ns.db.sound = on and true or false
		return true
	end
	if not SOUND_KIND[kind] then return false end
	local off = type(ns.db.soundOff) == "table" and ns.db.soundOff or {}
	off[kind] = (not on) or nil
	ns.db.soundOff = next(off) ~= nil and off or nil
	return true
end

-- One alert sound every 15 seconds at most, but a softer one never silences a louder one: the
-- Call to Arms (a lane of its own) sounds whatever chimed just before it, a loud alert (a Royal
-- decree, the King's call) whatever soft one did. A louder one silences the softer ones after it.
-- tone: "soft" or "loud"; kind: see SOUND_KINDS. True when it played.
-- own: the player's own click (a decree sent or previewed), heard in an instance too (ns.Quiet).
local SOUND_GAP = 15
local lastSound = {}
function ns.ResetSounds() lastSound = { -math.huge, -math.huge, -math.huge } end -- (tests too)
ns.ResetSounds()
local function Rank(tone, kind) return kind == "arms" and 3 or (tone == "soft" and 1 or 2) end
function ns.PlayAlert(tone, kind, own)
	if not ns.SoundOn(kind) or not PlaySound or not SOUNDKIT then return false end
	if not own and ns.Quiet() then return false end
	local rank = Rank(tone, kind)
	local now = GetTime()
	for r = rank, 3 do
		if now - lastSound[r] < SOUND_GAP then return false end
	end
	lastSound[rank] = now
	local id = tone == "soft" and (SOUNDKIT.READY_CHECK or SOUNDKIT.RAID_WARNING) or SOUNDKIT.RAID_WARNING
	if id then pcall(PlaySound, id) end
	return true
end

-- The switches in words: for /syl sound and the Decrees tab.
function ns.SoundLabel(kind) return L["SOUND_" .. kind:upper()] end
local function KindsOff()
	local off = {}
	for _, k in ipairs(ns.SOUND_KINDS) do
		if not ns.SoundKindOn(k) then off[#off + 1] = k end
	end
	return off
end
function ns.SoundState()
	if not (ns.db and ns.db.sound) then return L.SOUNDS_OFF end
	local off = KindsOff()
	if #off == 0 then return L.SOUNDS_ALL_ON end
	return L.SOUNDS_SOME_OFF:format(table.concat(KindNames(off), ", "))
end

-- For /syl status and /syl bug (in English, as the rest there).
function ns.AlertStatus()
	local off = KindsOff()
	local sounds = not (ns.db and ns.db.sound) and "sounds all off" or (#off > 0 and ("sounds on, off: " .. table.concat(off, ",")) or "sounds on")
	if ns.db and ns.db.alertsAlways then return sounds .. "  |  in an instance or Busy: shown (/syl alerts always)" end
	return ("%s  |  in an instance or Busy: held (now: %s, %d waiting)"):format(sounds, ns.Quiet() or "not held", #ns.Held())
end

-- /syl sound: alone, the switch for all (as before 1.1); on|off, the same; <kind> [on|off], one kind.
function ns.SoundSlash(rest)
	local what, on = tostring(rest or ""):lower():match("^(%S*)%s*(%S*)")
	what = ns.SOUND_ALIAS[what] or what
	if what == "" then
		ns.SetSound(nil, not ns.db.sound)
	elseif what == "on" or what == "off" then
		ns.SetSound(nil, what == "on")
	elseif SOUND_KIND[what] then
		if on == "on" or on == "off" then ns.SetSound(what, on == "on") else ns.SetSound(what, not ns.SoundKindOn(what)) end
	else
		return ns.Print(L.SOUND_USAGE:format(table.concat(KindNames(ns.SOUND_KINDS), ", ")))
	end
	ns.Print(ns.SoundState())
	ns.Fire("DECREES_CHANGED") -- (the switches on the Decrees tab)
end

---------------------------------------------------------------------------
-- Held alerts (1.1): in an instance or Busy, no raid warning, no sound and no popup from
-- Sylvanistas. A realm-wide raid warning in the middle of a dungeon made players mute the addon,
-- and then miss a real muster. Each alert still leaves its chat line and its line in the
-- Sylvanistas window (the Decrees tab: what waits, on top), and waits. Out of the instance and not
-- Busy: one line (and one raid warning and one sound) says what waited and is still current,
-- and only what is still open pops (a Vox question, the court's call, the Agenda to come);
-- what is over by then only stays in its list. /syl alerts always: never held. Local only.
---------------------------------------------------------------------------

-- Busy: the game's Do Not Disturb (/dnd). During an encounter, a challenge or a PvP match (and
-- on a dungeon or raid map), Forever's client hides it from addons (a secret value, which no
-- addon may test): counted as Busy then, those being the moments not to step on.
local function Busy()
	if not UnitIsDND then return false end
	local ok, dnd = pcall(UnitIsDND, "player")
	if not ok then return false end
	if issecretvalue and issecretvalue(dnd) then return true end
	return dnd and true or false
end

-- Why alerts wait now: "instance", "busy", or nil (never with /syl alerts always).
function ns.Quiet()
	if ns.db and ns.db.alertsAlways then return nil end
	if IsInInstance and IsInInstance() then return "instance" end
	if Busy() then return "busy" end
	return nil
end

ns.HELD_MAX = 40
local held = {} -- { kind, tone, what, key, t, open, show }, oldest first
-- What was over when the list was full and went out of it: still counted in the grey line (the
-- ones without a key; each key once, unless the same alert is current again by then).
local goneN, goneKeys = 0, {}
function ns.ResetHeld() held, goneN, goneKeys = {}, 0, {} end -- (tests)

local function Current(h) return h.open == nil or h.open() == true end

-- Past HELD_MAX: what is over goes first (forty Calls to Arms over by then no longer push a
-- Muster or the Agenda out). Then, if all is still current: the same alert repeated as one (the
-- latest, with the popup an earlier one had: ns.Held); then the oldest without a popup or
-- window, and only if every one has one, the oldest.
local function Trim()
	if #held <= ns.HELD_MAX then return end
	local keep = {}
	for _, h in ipairs(held) do
		if Current(h) then keep[#keep + 1] = h
		elseif h.key then goneKeys[h.key] = true
		else goneN = goneN + 1 end
	end
	held = keep
	if #held <= ns.HELD_MAX then return end
	held = ns.Held()
	while #held > ns.HELD_MAX do
		local drop = 1
		for i, h in ipairs(held) do
			if not h.show then drop = i; break end
		end
		table.remove(held, drop)
	end
end

-- An alert that interrupts: its raid warning (a.text), its sound, its popup or window (a.show).
-- The caller prints its chat line. While quiet (and not the player's own click, a.own) it waits:
-- a.what, its words in the summary and on the Decrees tab (a.text by default); a.open, still
-- current (none: as long as the player is away); a.key, the same alert repeated (the Agenda and
-- its reminders): one line. True when it showed now.
function ns.Alert(kind, tone, a)
	a = a or {}
	if not a.own and ns.Quiet() then
		held[#held + 1] = { kind = kind, tone = tone, what = a.what or a.text or kind, key = a.key, t = ns.Now(), open = a.open, show = a.show }
		Trim()
		ns.Log("alert held (%s): %s", tostring(ns.Quiet()), tostring(kind))
		ns.Fire("DECREES_CHANGED")
		return false
	end
	if a.text and RaidNotice_AddMessage and RaidWarningFrame then
		RaidNotice_AddMessage(RaidWarningFrame, a.text, ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] or a.color or { r = 1, g = 0.82, b = 0 })
	end
	ns.PlayAlert(tone, kind, a.own)
	if a.show then a.show() end
	return true
end

-- What waits and is still current, one per key (the latest, with the popup an earlier one
-- had: the Agenda's, before its reminders), oldest first.
function ns.Held()
	local out, at = {}, {}
	for _, h in ipairs(held) do
		if Current(h) then
			local i = h.key and at[h.key]
			if i then
				local prev = out[i]
				out[i] = { kind = h.kind, tone = h.tone, what = h.what, key = h.key, t = h.t, open = h.open, show = h.show or prev.show }
			else
				out[#out + 1] = h
				if h.key then at[h.key] = #out end
			end
		end
	end
	return out
end

-- On top of the Decrees tab while alerts wait: a click shows one now (its popup or window).
function ns.HeldLines()
	local list = ns.Held()
	if #list == 0 then return {} end
	local lines = { { header = true, text = L.HELD_TITLE, tooltip = function(tt)
		tt:AddLine(L.HELD_TITLE, 1, 0.82, 0)
		tt:AddLine(L.HELD_TIP, 1, 1, 1, true)
	end } }
	for _, h in ipairs(list) do
		lines[#lines + 1] = {
			text = "|cffffd200" .. h.what .. "|r",
			right = "|cff9d9d9d" .. ns.Ago(h.t) .. "|r",
			onClick = h.show and function()
				for i = #held, 1, -1 do
					if held[i] == h or (h.key and held[i].key == h.key) then table.remove(held, i) end
				end
				h.show()
				ns.Fire("DECREES_CHANGED")
			end or nil,
		}
	end
	lines[#lines].gapAfter = true
	return lines
end

-- Out of the instance and not Busy: one line for what waited and is still current (a raid
-- warning and the loudest sound its switches allow), then the popups and windows still open.
-- What is over by then stays in its list: a grey line says how many.
ns.HELD_WORDS = 5 -- alerts named in that line; the rest counted
function ns.ReleaseHeld()
	if (#held == 0 and goneN == 0 and not next(goneKeys)) or ns.Quiet() then return false end
	local list = ns.Held()
	-- The ones over, each counted once (an Agenda and its reminders are one), with those over
	-- that a full list let go (Trim).
	local live, counted, gone = {}, {}, goneN
	for _, h in ipairs(list) do live[h.key or h] = true end
	for key in pairs(goneKeys) do
		if not live[key] then counted[key], gone = true, gone + 1 end
	end
	for _, h in ipairs(held) do
		local id = h.key or h
		if not live[id] and not counted[id] then counted[id], gone = true, gone + 1 end
	end
	held, goneN, goneKeys = {}, 0, {}
	ns.Fire("DECREES_CHANGED")
	if #list == 0 then
		if gone > 0 then ns.Print("|cff9d9d9d" .. L.HELD_GONE:format(gone) .. "|r") end
		return true
	end
	-- The same words once, with how many (two Musters in one zone).
	local count, order = {}, {}
	for _, h in ipairs(list) do
		if not count[h.what] then order[#order + 1] = h.what end
		count[h.what] = (count[h.what] or 0) + 1
	end
	local words = {}
	for i, w in ipairs(order) do
		if i > ns.HELD_WORDS then
			words[#words + 1] = L.HELD_MORE:format(#order - ns.HELD_WORDS)
			break
		end
		words[#words + 1] = count[w] > 1 and L.HELD_TIMES:format(w, count[w]) or w
	end
	local line = L.HELD_SUMMARY:format(table.concat(words, ", "))
	ns.Print("|cffffd200" .. line .. "|r" .. (gone > 0 and ("  |cff9d9d9d" .. L.HELD_AND_GONE:format(gone) .. "|r") or ""))
	if RaidNotice_AddMessage and RaidWarningFrame then
		RaidNotice_AddMessage(RaidWarningFrame, line, ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] or { r = 1, g = 0.82, b = 0 })
	end
	local loudest
	for _, h in ipairs(list) do
		if ns.SoundOn(h.kind) and (not loudest or Rank(h.tone, h.kind) > Rank(loudest.tone, loudest.kind)) then loudest = h end
	end
	if loudest then ns.PlayAlert(loudest.tone, loudest.kind) end
	for _, h in ipairs(list) do
		if h.show then ns.SafeCall("held alert", h.show) end
	end
	return true
end

-- /syl alerts always|quiet: held in an instance or Busy (quiet, the default), or never.
function ns.AlertsSlash(rest)
	local how = tostring(rest or ""):lower():match("^%s*(%S*)")
	if how == "always" or how == "quiet" then ns.db.alertsAlways = how == "always" or nil end
	if how ~= "" and how ~= "always" and how ~= "quiet" then return ns.Print(L.HELP_ALERTS) end
	ns.Print(ns.db.alertsAlways and L.ALERTS_ALWAYS or L.ALERTS_QUIET)
	ns.ReleaseHeld() -- (always: what waited comes now)
	ns.Fire("DECREES_CHANGED")
end

-- Captains (officers) are rank index 1, right below the guild master, in every guild. It is
-- fixed so that senders and receivers always agree on who may send decrees.
ns.CAPTAIN_RANK = 1

-- What the army calls the King on the lines and the crown made for him (Hop.lua, King.lua),
-- whatever his character's name in the census.
ns.KING_NAME = ns.GM_DISPLAY
-- The addon's author (Workshop.lua): his character on Forever. Names there are a first name
-- and a surname, unique across the realm group; no Classic realm allows a space in a name.
ns.AUTHOR = ns.AUTHOR_CHARACTER
ns.AUTHOR_REALM = ns.REALM_GROUP -- his realm group, where only he carries that name
-- A name of the realm group of `realm` (a name without a realm is ours). Forever's names are
-- one across a realm group only: the same name on another group is someone else.
local function OfGroup(name, realm)
	local own = ns.RealmOf(ns.FullName(name)) or ns.realm or ns.CurrentRealm()
	return ns.GroupOf(own) == ns.GroupOf(realm)
end
-- The Treasurer of Sylvanistas (ns.TREASURER_CHARACTER, at the top of this file): exactly this
-- character, in the guild named Sylvanistas. Look-alikes in other guilds exist: both must match,
-- and his realm group (Forever's PvP realms), where only he carries that name.
ns.TREASURER = ns.TREASURER_CHARACTER
ns.TREASURER_REALM = ns.REALM_GROUP
ns.COIN = "|TInterface\\MoneyFrame\\UI-GoldIcon:0|t "
function ns.IsTreasurer(name, guild)
	return type(name) == "string" and type(guild) == "string" and ns.ShortName(name) == ns.TREASURER and guild:lower() == ns.GUILD_NAME:lower()
		and OfGroup(name, ns.TREASURER_REALM)
end
-- The Treasurer's characters that keep a book of the treasury (1.0, Treasury.lua): the Treasurer
-- himself (ns.TREASURER, his name for display: he is the Treasurer only in the guild Sylvanistas,
-- ns.IsTreasurer) and his hunter, where the treasury's mail goes (his word: "all the mail goes
-- to that; I want the gold mailed to count as well"). The hunter is his mail character, in
-- whatever guild or none, so no guild is checked for it: the server stamps the sender of an
-- addon message and of a mail (nobody can write another's name there), and a Forever name is
-- one across its realm group, so this full name on his realm group (ns.TREASURER_REALM's) can
-- only be his. The same name on another realm group is someone else.
ns.TREASURER_CHARACTERS = { ns.TREASURER_CHARACTER, ns.TREASURER_MAIL_CHARACTER }
-- One of the Treasurer's pinned characters other than the Treasurer himself (his mail's): by
-- its exact name on his realm group, in any guild or none.
function ns.IsTreasurerMail(name)
	if type(name) ~= "string" or name == "" then return false end
	local short = ns.ShortName(name)
	for _, pin in ipairs(ns.TREASURER_CHARACTERS) do
		if pin ~= ns.TREASURER and short == pin then return OfGroup(name, ns.TREASURER_REALM) end
	end
	return false
end
-- The King's name on the lines and the crown: ns.GM_DISPLAY once it is filled in (top of this
-- file), else his character's short name as the census gives it.
function ns.KingDisplaySet() return type(ns.KING_NAME) == "string" and ns.KING_NAME ~= "" and not ns.KING_NAME:find("^CHANGEME") end
function ns.KingName(leader)
	if ns.KingDisplaySet() then return ns.KING_NAME end
	return leader and ns.ShortName(leader) or "?"
end
ns.CROWN_ICON = "Interface\\GroupFrame\\UI-Group-LeaderIcon"

-- The King's guild on each side: the guild master of this exact name is the King, its officers
-- are of the Crown. Horde only: <Sylvanistas> (ns.GUILD_NAME, at the top of this file).
ns.KING_GUILD = { Horde = ns.GUILD_NAME:lower() }
function ns.IsKingGuild(guild)
	if type(guild) ~= "string" then return false end
	local want = ns.KING_GUILD[ns.faction or "Alliance"]
	return want ~= nil and guild:lower() == want
end

-- The King himself, by his character's name, like the Treasurer: sender names are set by the
-- server, so nobody else can speak as him, and no census vote (anyone on the channel can
-- vote) can crown someone else or take the Crown from him. The Alliance's is the guild master
-- of <SYLVANISTAS> as the census saw him on September 24, 2026 (a Forever name, one across the
-- realm group). The Horde's is set here once it is known: until then nobody commands there
-- (his position and his name on the lines still come from the census). His name is his on his
-- realm group alone (ns.KING_REALM's): anywhere else (Forever's other realms, Classic Era,
-- Anniversary) there is no King by name either, like the Horde's, and a namesake on another
-- group is not him.
-- The Horde's (0.9.4): Firstname Surname, guild master of <Guild>. His realm is not known
-- yet: until it is (ns.KING_REALM_HORDE), his name alone counts on the Horde, anywhere (Forever
-- names are one per region; a namesake can only exist on another client or region).
ns.KING_CHARACTER = { Horde = ns.GM_CHARACTER }
ns.KING_REALM = nil -- (the Alliance's: unused)
ns.KING_REALM_HORDE = ns.GM_REALM
-- Until it is set here, the Horde King's realm is learned from the first message of his that
-- reaches us (his name is his alone), and from then on only that realm group counts: shown in
-- /syl status so it can be written here.
local function KingRealm()
	if ns.faction == "Horde" then return ns.KING_REALM_HORDE or (ns.rdb and ns.rdb.kingRealmHorde) end
	return ns.KING_REALM
end
ns.KingRealm = KingRealm
function ns.KingCharacter()
	local realm = KingRealm()
	if realm and ns.GroupOf(ns.realm or ns.CurrentRealm()) ~= ns.GroupOf(realm) then return nil end
	return ns.KING_CHARACTER[ns.faction or "Alliance"]
end
function ns.IsKingCharacter(name)
	local pin = ns.KingCharacter()
	if pin == nil or type(name) ~= "string" or ns.ShortName(name) ~= pin then return false end
	local realm = KingRealm()
	return realm == nil or OfGroup(name, realm)
end
-- Learned only from a message he sent (King.lua: the sender name is the server's), never from
-- a name written inside a report, which anyone could forge to lock him out.
function ns.LearnKingRealm(sender)
	if ns.faction ~= "Horde" or KingRealm() ~= nil or not ns.rdb or not ns.IsKingCharacter(sender) then return end
	local realm = ns.RealmOf(ns.FullName(sender))
	if not realm then return end
	ns.rdb.kingRealmHorde = realm
	ns.Log("the Horde's King is on %s (learned from his first message)", realm)
end

-- The High Council: the Sylvanistas moderators, shown with their mark and their colour in the Sylvanistas
-- chats. No name is written in this code (it is public, and names get sniped on launch realms):
-- the list is signed by the author on his own computer and checked by every client (Sign.lua,
-- Workshop.lua).
-- The mark (0.9.9): the game's target-frame skull, the one nameplates show. Fixed: nobody
-- picks or changes it. Each councillor's own icon (0.9.8, Workshop.lua) is flavour after it; a
-- councillor who never picked one shows the mark alone.
ns.HIGH_COUNCIL_SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
ns.HIGH_COUNCIL_MARK = "|T" .. ns.HIGH_COUNCIL_SKULL .. ":0|t"
ns.HIGH_COUNCIL_COLOR = "ffb048f8"
-- Names are one per realm group: a signed list counts on the group of whoever published it.
-- The list names it "A+B": any realm of it, as this client groups realms (0.9.8: a realm linked
-- to that group since, which makes our group "A+B+C", no longer loses the list). None: anywhere.
local function OfListGroup(name, group)
	if group == nil then return true end
	for _, realm in ipairs(ns.GroupRealms(group)) do
		if OfGroup(name, realm) then return true end
	end
	return false
end
function ns.IsHighCouncillor(name)
	local c = ns.rdb and ns.rdb.council
	if type(name) ~= "string" or type(c) ~= "table" or type(c.names) ~= "table" then return false end
	if not c.names[ns.ShortName(name):lower()] then return false end
	return OfListGroup(name, c.realm)
end

-- A councillor's icon as it travels and is kept (0.9.8): a file number, or a plain icon name
-- (letters, digits and _) under Interface\Icons. Anything else is nil: nothing but these two
-- ever reaches the |T...|t of a chat line (no pipe, colon, slash or path of someone's choosing).
function ns.CouncilIconValue(v)
	if type(v) == "string" and v:match("^%d+$") then
		if #v > 10 then return nil end
		v = tonumber(v)
	end
	if type(v) == "number" then
		return (v >= 1 and v < 2147483648 and v == math.floor(v)) and v or nil
	end
	if type(v) == "string" and #v <= 64 and v:match("^[%w_]+$") then return v end
	return nil
end

-- The texture for a council icon (a file number, or its path under Interface\Icons), or nil.
function ns.CouncilIconTexture(v)
	v = ns.CouncilIconValue(v)
	if type(v) == "string" then return "Interface\\Icons\\" .. v end
	return v
end

-- A councillor's own icon, after the mark: our own choice for our lines, what their client
-- announced for anyone else's (Workshop.lua keeps it), else "" (0.9.9: no default icon any
-- more, the mark says it). Checked again here: the ones heard are kept in the SavedVariables
-- too. A name without its realm, or with another realm of the group (the titles list, a census
-- row), finds the one heard under that name: names are one per realm group, and only
-- councillors' icons are kept.
function ns.CouncilIcon(name)
	local v
	local who = type(name) == "string" and ns.FullName(name) or nil
	if who and who == ns.me then
		local mine = ns.db and ns.db.councilIcons
		v = type(mine) == "table" and mine[who] or nil
	elseif who then
		local heard = ns.rdb and ns.rdb.councilIcons
		local e = type(heard) == "table" and heard[who]
		if type(e) ~= "table" and type(heard) == "table" then
			local short = ns.ShortName(who):lower()
			for k, x in pairs(heard) do
				if type(k) == "string" and ns.ShortName(k):lower() == short then e = x break end
			end
		end
		v = type(e) == "table" and e.icon or nil
	end
	local texture = ns.CouncilIconTexture(v)
	return texture and ("|T" .. texture .. ":0|t") or ""
end

-- What goes with a councillor's name: the mark, then their own icon if they picked one. ""
-- for anyone not on the council.
function ns.CouncilMark(name)
	if not ns.IsHighCouncillor(name) then return "" end
	return ns.HIGH_COUNCIL_MARK .. ns.CouncilIcon(name)
end

-- The council's departments and titles (0.9.9, Workshop.TakeTitles), signed apart from the
-- names: nil when none reached us, or when it is another realm group's (like the names).
function ns.CouncilTitles()
	local t = ns.rdb and ns.rdb.councilTitles
	if type(t) ~= "table" or type(t.depts) ~= "table" then return nil end
	if not OfListGroup(ns.me, t.realm) then return nil end
	return t
end

-- A councillor's place in that list: { title, dept, icon } (the department's icon), each of
-- them nil when the list gives none; nil for anyone not on the council's name list, or not in
-- the titles. Kept in the SavedVariables: checked again here.
function ns.CouncilTitle(name)
	local t = ns.IsHighCouncillor(name) and ns.CouncilTitles()
	if not t then return nil end
	local short = ns.ShortName(name):lower()
	for _, d in ipairs(t.depts) do
		for _, m in ipairs(type(d) == "table" and type(d.members) == "table" and d.members or {}) do
			if type(m) == "table" and type(m.name) == "string" and m.name:lower() == short then
				local dept = type(d.name) == "string" and d.name ~= "" and d.name or nil
				local title = type(m.title) == "string" and m.title ~= "" and m.title or nil
				return { title = title, dept = dept, icon = dept and ns.CouncilIconValue(d.icon) or nil }
			end
		end
	end
	return nil
end

-- The King's Steward (1.0.0): a character the author marks in the signed titles list, who names
-- Hands of his own beside the King's, sets up for the King what only the King could set up before
-- (the treasury's keepers and switches) and sends the Crown's decrees on every client (King.lua,
-- Treasury.lua, Decree.lua).
-- The titles list names him in an entry of its own among the departments, one per faction:
--   ^steward^<Alliance|Horde>^<First Surname-Realm>,...
-- Three "^": a client of 0.9.9 reads a department as two (<name>^<icon>^<members>), leaves this
-- entry out unread, and still takes, shows and passes on the rest (the signature covers every
-- byte, the entry too). A Steward acts for the King of his own faction, where a King is named
-- (ns.KingCharacter): the Alliance's, and on the Horde only when the list names one there.
-- Nobody else is ever a Steward: no name is written in this code, no census vote counts, and a
-- newer signed list without him ends it at once.
ns.STEWARDS_MAX = 3
local STEWARD_FACTIONS = { Alliance = true, Horde = true }

-- A Steward's name as the entry gives it and the addon keeps it: "First Surname-Realm" (that
-- realm's group), or "First Surname" (any realm of the list's group); nil for anything else.
local function StewardName(s)
	s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local short, realm = s:match("^([^%-]+)%-([^%-]+)$")
	short = short or s
	if #short > 48 or not short:match("^[%a\128-\255]+ ?[%a\128-\255]*$") then return nil end
	if realm and (#realm > 40 or not realm:match("^[%w\128-\255]+$")) then return nil end
	return realm and (short .. "-" .. realm) or short
end

-- The Stewards a titles list names (its departments' field, as signed): { Alliance = { name,
-- ... }, Horde = { ... } }, a faction left out when it names none (ns.STEWARDS_MAX each).
function ns.ReadStewards(text)
	local out = {}
	for entry in tostring(text or ""):gmatch("[^;]+") do
		local faction, list = entry:match("^%^steward%^(%a+)%^([^%^]*)$")
		if faction and STEWARD_FACTIONS[faction] then
			local names = out[faction] or {}
			for n in list:gmatch("[^,]+") do
				local name = StewardName(n)
				if name and #names < ns.STEWARDS_MAX then names[#names + 1] = name end
			end
			out[faction] = names
		end
	end
	return out
end

-- The Stewards of the titles list we hold, for our faction, where a King is named: { name, ... }.
-- Read when the list was taken; a list taken by a version before 1.0.0 (which left the entry
-- out) is read again from its signed text, which this client checked then.
function ns.Stewards()
	local t = ns.CouncilTitles()
	if not t or not ns.KingCharacter() then return {} end
	if type(t.stewards) ~= "table" then
		t.stewards = ns.ReadStewards(type(t.blob) == "string" and t.blob:match("^HT1~%d+~[^~]*~[01]~([^~]*)~%x+$") or "")
	end
	local list = t.stewards[ns.faction or "Alliance"]
	return type(list) == "table" and list or {}
end

-- The approved guilds (1.1, the author's): guilds of Sylvanistas whose names the name rule
-- below leaves out count as Sylvanistas guilds when
-- the author's signed titles list names them, per faction, in an entry of its own after the
-- departments, like the Steward:
--   ^guilds^<Alliance|Horde>^<Guild Name>,<Guild Name>,...
-- Three "^": clients of 0.9.9 and 1.0.0 leave it out unread (a department has two; 1.0.0 reads
-- "^steward^" alone) and still take, show and pass on the whole list. The list counts on its realm
-- group only, as every signed list (ns.CouncilTitles), and only the author's key signs it
-- (the signing tool guild).
ns.APPROVED_MAX = 20
-- ...and the ones the addon ships with (1.1, the author's too): a guild whose first member nobody
-- can hand the signed text counts as soon as its members update, with nothing to paste. Each
-- faction's, any case; the signed list adds to them, and only a new release takes one off.
ns.APPROVED_BUILTIN = { Horde = {} } -- other guilds of Sylvanistas whose names don't say it, e.g. { "Some Guild" }
local function ApprovedName(s)
	s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" or #s > 72 or select(2, s:gsub("[^\128-\191]", "")) > 24 then return nil end
	if not s:match("^[%a\128-\255][%a\128-\255 ]*$") then return nil end
	return s
end

-- The approved guilds a titles list names: { Alliance = { name, ... }, Horde = { ... } }, a
-- faction left out when it names none (ns.APPROVED_MAX each, each once).
function ns.ReadApprovedGuilds(text)
	local out = {}
	for entry in tostring(text or ""):gmatch("[^;]+") do
		local faction, list = entry:match("^%^guilds%^(%a+)%^([^%^]*)$")
		if faction and STEWARD_FACTIONS[faction] then
			local names, seen = out[faction] or {}, {}
			for _, n in ipairs(names) do seen[ns.Fold(n)] = true end
			for n in list:gmatch("[^,]+") do
				local name = ApprovedName(n)
				if name and not seen[ns.Fold(name)] and #names < ns.APPROVED_MAX then
					seen[ns.Fold(name)] = true
					names[#names + 1] = name
				end
			end
			out[faction] = names
		end
	end
	return out
end

-- The approved guilds of our faction: those the addon ships with, then those of the titles list
-- we hold (read again from its signed text when a version before 1.1 took it): { name, ... }.
function ns.ApprovedGuilds()
	local faction = ns.faction or "Alliance"
	local out, seen = {}, {}
	local function Add(list)
		for _, name in ipairs(type(list) == "table" and list or {}) do
			local key = ns.Fold(name)
			if not seen[key] then seen[key], out[#out + 1] = true, name end
		end
	end
	Add(ns.APPROVED_BUILTIN[faction])
	local t = ns.CouncilTitles()
	if t then
		if type(t.guilds) ~= "table" then
			t.guilds = ns.ReadApprovedGuilds(type(t.blob) == "string" and t.blob:match("^HT1~%d+~[^~]*~[01]~([^~]*)~%x+$") or "")
		end
		Add(t.guilds[faction])
	end
	return out
end

-- Is this guild on it? Asked for every report, line, tooltip and nameplate: the set is kept while
-- the list, our faction, our character and our realm group are the same, and each name's answer
-- with it (an empty list answers at once).
local approvedMemo
function ns.IsApprovedGuild(guild)
	if type(guild) ~= "string" or guild == "" then return false end
	local t = ns.rdb and ns.rdb.councilTitles
	if type(t) ~= "table" then t = nil end -- (the shipped ones count without a list)
	local at = t and t.at
	local m = approvedMemo
	if not m or m.t ~= t or m.at ~= at or m.faction ~= ns.faction or m.me ~= ns.me or m.group ~= ns.group then
		local set, any = {}, false
		for _, name in ipairs(ns.ApprovedGuilds()) do set[ns.Fold(name)], any = true, true end
		m = { t = t, at = at, faction = ns.faction, me = ns.me, group = ns.group, set = set, any = any, seen = {}, seenCount = 0 }
		approvedMemo = m
	end
	if not m.any then return false end
	local known = m.seen[guild]
	if known == nil then
		known = m.set[ns.Fold(guild)] == true
		if m.seenCount >= 2000 then m.seen, m.seenCount = {}, 0 end
		m.seen[guild], m.seenCount = known, m.seenCount + 1
	end
	return known
end

-- Our guild is a Sylvanistas guild by the signed list alone (its name would not make it one): its
-- members may not hold the list yet, and hear it only over GUILD (Comm.lua, Workshop.RelayGuild).
function ns.ApprovedOnly()
	local guild = IsInGuild and IsInGuild() and GetGuildInfo("player")
	return type(guild) == "string" and ns.IsApprovedGuild(guild) and not ns.IsKingGuild(guild) and not ns.NamedSylvanistas(guild)
end

-- Is this character (a sender's name, which the server sets) a Steward of our King?
function ns.IsSteward(name)
	if type(name) ~= "string" or name == "" then return false end
	local t = ns.CouncilTitles()
	if not t then return false end
	local full = ns.FullName(name)
	if not OfListGroup(full, t.realm) then return false end
	local short = ns.ShortName(full):lower()
	for _, s in ipairs(ns.Stewards()) do
		if type(s) == "string" and ns.ShortName(s):lower() == short then
			local realm = ns.RealmOf(s)
			if realm == nil or OfGroup(full, realm) then return true end
		end
	end
	return false
end

-- The King's guild as a Steward's decree names it: ours when we are in it, else its own name.
function ns.KingGuildName()
	local mine = GetGuildInfo and GetGuildInfo("player")
	if ns.IsKingGuild(mine) then return mine end
	local want = ns.KING_GUILD[ns.faction or "Alliance"] or ""
	return want:sub(1, 1):upper() .. want:sub(2)
end

-- The King's own screen (0.9.9, the author's, for the Dark Lady's stream): the King's client, or the
-- author's "the Dark Lady's view" (King.Preview) so he can try it. Nobody else's.
function ns.KingsScreen()
	local K = ns.King
	if type(K) ~= "table" or type(K.IsKing) ~= "function" then return false end
	return K.IsKing() == true or (type(K.Preview) == "function" and K.Preview() == true)
end

-- Who sees the High Council in the census, its marks there and its titles (0.9.9, the author's
-- call): until launch the councillors themselves, the author's own client (the one holding the
-- signed lists, CouncilList.lua) and the King's (names hidden, below); everyone once the signed
-- titles list says it is public. The Sylvanistas chats show the mark to everyone, as in 0.9.8.
function ns.CouncilVisible()
	if ns.COUNCIL_SIGNED ~= nil or ns.COUNCIL_TITLES ~= nil or ns.IsHighCouncillor(ns.me) or ns.KingsScreen() then return true end
	local t = ns.CouncilTitles()
	return t ~= nil and t.public == true
end

-- The King streams: on his screen the councillors' names stay hidden (0.9.9). The High Council
-- in the Realm shows each name cut short (ns.MaskName), and no council mark, icon or title goes
-- with a name anywhere else (census rows, person card, Sylvanistas chats), until he clicks the eye
-- under the council's header. Never saved: every login and /reload starts hidden again.
-- The council's borders and nameplate marks follow at once (Borders.lua, Nameplates.lua: they
-- listen for COUNCIL_MASK_CHANGED, fired only when it flips).
local councilNamesShown = false
function ns.CouncilNamesShown() return councilNamesShown end
function ns.SetCouncilNamesShown(on)
	on = on == true
	if on == councilNamesShown then return end
	councilNamesShown = on
	ns.Fire("COUNCIL_MASK_CHANGED")
end
function ns.CouncilMasked() return not councilNamesShown and ns.KingsScreen() end

-- A councillor's name while hidden: its first four characters (UTF-8: a character is a lead
-- byte and the continuation bytes after it), or all of a shorter name, then "****".
function ns.MaskName(name)
	local s, chars, cut = tostring(name or ""), 0, nil
	for i = 1, #s do
		local b = s:byte(i)
		if b < 0x80 or b >= 0xC0 then
			chars = chars + 1
			if chars > 4 then cut = i - 1 break end
		end
	end
	return (cut and s:sub(1, cut) or s) .. "****"
end

-- Letters folded for a search (the Workshop's, 0.9.9; the tabs', 1.0.0), byte by byte: A-Z, and
-- Latin-1's accented capitals (À to Þ but ×, in UTF-8 C3 80-9E, their small letters C3 A0-BE).
-- Not the C library's lower: its idea of a letter can change with the locale and split a UTF-8
-- letter. Any other letter stays whole.
function ns.Fold(s)
	s = tostring(s or ""):gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end)
	return (s:gsub("\195([\128-\158])", function(c)
		if c == "\151" then return nil end
		return "\195" .. string.char(c:byte() + 32)
	end))
end

-- A text as a search reads it: only what a row shows (its colour codes, textures and a link's
-- data left out, the link's [text] kept, an escaped "||" one "|" and no code), folded (ns.Fold).
function ns.Searchable(s)
	s = tostring(s or ""):gsub("||", "\1"):gsub("|H.-|h(.-)|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
	return ns.Fold((s:gsub("\1", "|")))
end

-- Does one of the texts hold `query` (folded, ns.Fold), as a search reads it (ns.Searchable)?
-- As plain text, never a Lua pattern. No query (nil or ""): everything does.
function ns.Holds(query, ...)
	if not query or query == "" then return true end
	for i = 1, select("#", ...) do
		local s = select(i, ...)
		if type(s) == "string" and s ~= "" and ns.Searchable(s):find(query, 1, true) then return true end
	end
	return false
end

-- The Crown: guild masters of any Sylvanistas guild, and the officers of the King's guild. Those
-- officers only on the clients of the King's guild's own members (1.0.0), where their rank is
-- the server's word (our roster: Data.KnownRank and Channels.VerifiedLevel read our own guild
-- from it, never from the census). Anywhere else the census alone could name them, and three
-- outsiders' reports were enough to add one of their own: there they are Captains like any
-- guild's officers, and the Crown of the King's guild is the King himself (his pinned name) and
-- the Hands his list or a Steward's own names (King.IsHandName: their word, never a vote), who
-- speak for his guild with his Crown there (Decree.lua, Channels.VerifiedLevel) besides his
-- tools (King.Authorized).
function ns.IsCrownRank(guild, rankIndex)
	if not guild or not rankIndex then return false end
	if rankIndex == 0 then return true end
	return ns.IsKingGuild(guild) and rankIndex <= ns.CAPTAIN_RANK and ns.IsKingGuild(GetGuildInfo("player"))
end

function ns.IsCrown()
	local guild, _, rankIndex = GetGuildInfo("player")
	return ns.IsFederation(guild) and ns.IsCrownRank(guild, rankIndex)
end

-- Fixed on purpose: only guilds with "Sylvanistas" in their name belong to the realm, however
-- they spelled it (Silvanistas, Sylvanystas...). Each word of the name is read the way it sounds
-- (v as u, i as y, z as s, 0 as o, a doubled letter once); then one slip anywhere in a word counts
-- (a letter changed, missing or added, or two swapped), and two at the start of a word that
-- starts with an S. Words are never joined, and a name against the guild ("Anti Sylvanistas")
-- is left out (Against, below).
-- The main guild itself (the King's, the Treasurer's) is still the exact name, see IsCrownRank.
-- Written as they sound (Sounds, below: v as u, i as y), or no name would ever match them.
local REALM_WORDS = { "syluanystas" } -- as it sounds: Sylvanistas, Sylvanystas, Silvanistas
local OTHER = {} -- words that look like it but are not it

-- How many slips from a to b (a letter changed, missing or added, or two neighbours
-- swapped), counted up to limit + 1.
local function Slips(a, b, limit)
	local la, lb = #a, #b
	if la - lb > limit or lb - la > limit then return limit + 1 end
	local prev2, prev, row = nil, {}, nil
	for j = 0, lb do prev[j] = j end
	for i = 1, la do
		row = { [0] = i }
		local best = i
		local ca = a:byte(i)
		for j = 1, lb do
			local cost = (ca == b:byte(j)) and 0 or 1
			local v = math.min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost)
			if prev2 and i > 1 and j > 1 and ca == b:byte(j - 1) and a:byte(i - 1) == b:byte(j) then
				v = math.min(v, prev2[j - 2] + 1)
			end
			row[j] = v
			if v < best then best = v end
		end
		if best > limit then return limit + 1 end
		prev2, prev = prev, row
	end
	return prev[lb]
end
ns.Slips = Slips -- tests

-- A word as it sounds: v as u, i as y, z as s, a doubled letter once.
local function Sounds(word)
	word = word:gsub("v", "u"):gsub("i", "y"):gsub("z", "s")
	local out, last = {}, nil
	for c in word:gmatch(".") do
		if c ~= last then out[#out + 1] = c end
		last = c
	end
	return table.concat(out)
end
ns.Sounds = function(guild) return Sounds(guild:lower():gsub("0", "o"):gsub("[^%a]", "")) end -- tests

local function SylvanistasWord(word)
	for _, other in ipairs(OTHER) do
		if word:find(other) then return false end
	end
	for _, target in ipairs(REALM_WORDS) do
		if word:find(target, 1, true) then return true end
		-- One slip anywhere in the word.
		for len = #target - 1, #target + 1 do
			for i = 1, #word - len + 1 do
				if Slips(word:sub(i, i + len - 1), target, 1) <= 1 then return true end
			end
		end
		-- Two at its start, if it starts with an S.
		if word:sub(1, 1) == "s" then
			for len = #target - 2, #target + 2 do
				if len >= 5 and len <= #word and Slips(word:sub(1, len), target, 2) <= 2 then return true end
			end
		end
	end
	return false
end

-- A guild against Sylvanistas is none of it: "ANTI SYLVANISTAS", "Against Sylvanistas", "Down with
-- Sylvanistas", "AntiSylvanistas", "Sylvanistas Haters". The word before (or the one before "with", "to",
-- "the", "of"), glued in front, or the word after.
local AGAINST = { anti = true, against = true, no = true, ["not"] = true, never = true, down = true,
	death = true, kill = true, hate = true, hates = true, haters = true, destroy = true,
	ruin = true, ruins = true, ruined = true, ruining = true, raze = true, burn = true, crush = true,
	doom = true, wreck = true } -- "Ruin Sylvanistas", "Ruins of Sylvanistas", "Burn Sylvanistas" (1.0.1)
local LINKS = { with = true, to = true, the = true, of = true }
local AGAINST_AFTER = { haters = true, hater = true, sucks = true, ruined = true, burns = true, falls = true }
-- ...or after one or two linking words: "Sylvanistas in Ruins", "Sylvanistas in the Ruins" (1.1).
local LINKS_AFTER = { ["in"] = true, of = true, on = true, to = true, the = true }
local RUIN_AFTER = { ruin = true, ruins = true, ruined = true, ashes = true }

local function Against(words, i)
	if words[i]:find("^anti") then return true end -- glued: AntiSylvanistas
	local before, before2 = words[i - 1], words[i - 2]
	if before and AGAINST[before] then return true end
	if before and LINKS[before] and before2 and AGAINST[before2] then return true end
	local after = words[i + 1]
	if after ~= nil and AGAINST_AFTER[after] then return true end
	for j = i + 1, i + 2 do
		if not (words[j] and LINKS_AFTER[words[j]]) then break end
		local w = words[j + 1]
		if w and (RUIN_AFTER[w] or AGAINST_AFTER[w]) then return true end
	end
	return false
end

local federation, federationSize = {}, 0 -- [name] = true|false, asked often: kept
local function Federation(guild)
	local words = {}
	for word in guild:lower():gsub("0", "o"):gsub("1", "l"):gmatch("%a+") do words[#words + 1] = word end
	for i, word in ipairs(words) do
		if (word:find("sylvanistas", 1, true) or SylvanistasWord(Sounds(word))) and not Against(words, i) then return true end
	end
	return false
end

-- The name rule alone (cached): what IsFederation says without the King's guild or the signed list.
function ns.NamedSylvanistas(guild)
	if type(guild) ~= "string" or guild == "" then return false end
	local known = federation[guild]
	if known == nil then
		known = Federation(guild)
		if federationSize >= 2000 then federation, federationSize = {}, 0 end
		federation[guild], federationSize = known, federationSize + 1
	end
	return known
end

function ns.IsFederation(guild)
	if type(guild) ~= "string" or guild == "" then return false end
	-- The King's own guild is Sylvanistas whatever its name (the Horde's is <Guild>, 0.9.4).
	if ns.IsKingGuild(guild) then return true end
	-- A guild the author's signed list approves (1.1), whatever its name.
	if ns.IsApprovedGuild(guild) then return true end
	local known = federation[guild]
	if known == nil then
		known = Federation(guild)
		if federationSize >= 2000 then federation, federationSize = {}, 0 end
		federation[guild], federationSize = known, federationSize + 1
	end
	return known
end

-- The addon only works for members of a Sylvanistas guild, of ns.FACTION_ONLY.
function ns.IsMember()
	return (ns.faction or UnitFactionGroup("player")) == ns.FACTION_ONLY and IsInGuild() and ns.IsFederation(GetGuildInfo("player"))
end

---------------------------------------------------------------------------
-- Log (ring buffer in SavedVariables, readable from WTF/.../SavedVariables/Sylvanistas.lua)
---------------------------------------------------------------------------

function ns.Log(fmt, ...)
	local msg
	if select("#", ...) > 0 then
		local ok, res = pcall(string.format, fmt, ...)
		msg = ok and res or tostring(fmt)
	else
		msg = tostring(fmt)
	end
	local db = ns.db
	if not db then return end
	local log = db.log
	log[#log + 1] = date("%m-%d %H:%M:%S ") .. msg
	while #log > 400 do table.remove(log, 1) end
	if db.debug then ns.Print("|cff999999" .. msg .. "|r") end
end

---------------------------------------------------------------------------
-- Internal callbacks and WoW events. Every handler runs protected so one bug
-- never breaks the rest of the addon; errors go to ns.CaptureError (Diagnostics.lua).
---------------------------------------------------------------------------

function ns.SafeCall(where, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and ns.CaptureError then ns.CaptureError(where, err) end
	return ok
end

local listeners = {}
function ns.On(name, fn)
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], fn)
end
function ns.Fire(name, ...)
	local l = listeners[name]
	if not l then return end
	for i = 1, #l do ns.SafeCall("callback " .. name, l[i], ...) end
end

local eventFrame = CreateFrame("Frame")
local handlers = {}
function ns.RegisterEvent(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(handlers[event], fn)
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
	local h = handlers[event]
	if not h then return end
	for i = 1, #h do ns.SafeCall("event " .. event, h[i], ...) end
end)

-- Timers that also run protected.
function ns.After(seconds, where, fn)
	C_Timer.After(seconds, function() ns.SafeCall(where, fn) end)
end
function ns.Every(seconds, where, fn)
	return C_Timer.NewTicker(seconds, function() ns.SafeCall(where, fn) end)
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------

ns.RegisterEvent("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	SylvanistasDB = SylvanistasDB or {}
	local db = SylvanistasDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then db[k] = v end
	end
	db.blocked = db.blocked or {}
	db.pattern = nil
	db.log = db.log or {}
	db.errors = db.errors or {}
	db.sessions = (db.sessions or 0) + 1
	-- v0.5: guildmate dots are retired, switch them off for existing installs too.
	if (db.configVersion or 0) < 2 then
		db.showMates, db.sharePosition = false, false
		db.configVersion = 2
	end
	-- v0.7.9: demo data is gone (testers took it for real data). Forget the old setting.
	db.demo = nil
	-- 1.0.0: the author's letter on the Throne is gone, and with it whether the King read it.
	db.throneLetterRead = nil
	if db.configVersion < 3 then db.configVersion = 3 end
	-- Guild reports and the realm key belong to one realm group (ns.GroupOf): realms whose
	-- guilds span each other (PvP and PvP 2 in the beta) share them, any other realm keeps
	-- its own. The stores v0.7.8-0.7.10 kept per realm are merged into their group's here.
	ns.db = db
	ns.realm = ns.CurrentRealm()
	ns.group = ns.GroupOf(ns.realm, db)
	ns.faction = ns.Faction()
	ns.Log("---- session %d, v%s, realm %s, census %s, %s ----", db.sessions, ns.VERSION, ns.realm, ns.group, ns.faction)
	local R = OpenStore(Stores(db), ns.group)
	R.guilds = R.guilds or {}
	R.seen = R.seen or {} -- Sylvanistas guilds seen with /who (Data.lua), never mixed with the reports
	-- Old account-wide census and key: there is no telling which realm they came from, so
	-- drop them. The census refills from the channel within minutes and officers hand the
	-- key out again over guild chat (K0/K1) at login.
	db.guilds, db.realmKey, db.officerRank = nil, nil, nil
	-- Tabard inspections are about the players of one realm group too. The old account-wide
	-- ones can only be the Alliance's: they wait at the account level for an Alliance login.
	if db.inspect and ns.faction ~= "Horde" then
		if R.inspect == nil then R.inspect = db.inspect end
		db.inspect = nil
	end
	-- Block list keys become "name-realm" (old keys were short names from this realm).
	-- Collect first: adding keys while pairs walks the table is an error in Lua 5.1.
	if ns.realm ~= "?" then
		local short = {}
		for k in pairs(db.blocked) do
			if not k:find("-", 1, true) then short[#short + 1] = k end
		end
		for _, k in ipairs(short) do
			db.blocked[k] = nil
			db.blocked[(k .. "-" .. ns.realm):lower()] = true
		end
	end
	ns.rdb = R
	ns.Fire("INIT")
end)

-- Files added by an update only load once the game restarts: it reads the file list at
-- startup and /reload keeps the old one. Until then these stand-ins take the calls the
-- other files make, so the rest keeps working, and the player is told to restart.
-- Set here, before the files that use them load; the real files replace them.
local function StandIn(key, say)
	local restart = function() ns.Print(L.RESTART_NEEDED) end
	local stub = { missing = true }
	for _, fn in ipairs(say) do stub[fn] = restart end
	ns[key] = setmetatable(stub, { __index = function() return function() end end })
end
StandIn("Who", { "Search", "SendPlain" })
StandIn("Channels", { "Send", "ToggleMute" })
StandIn("King", { "Summon", "Inspect", "AgendaPrompt" })
StandIn("Hop", { "Ask", "AskKing", "SetHelp", "SetAuto" })
StandIn("Workshop", { "RollCall", "Approved" })
StandIn("Vox", { "Prompt", "CloseNow", "SetOff" })
StandIn("Court", { "Toggle" })
StandIn("Treasury", {})
StandIn("Dues", {}) -- (1.1)
StandIn("Acts", { "WritPrompt" })
StandIn("Dialog", {})
StandIn("Bank", {})
StandIn("Backup", { "Slash" }) -- (1.1)
StandIn("Link", { "Slash" })
StandIn("Borders", { "SetEnabled", "Report" })
StandIn("Nameplates", { "SetEnabled", "Report" })
StandIn("Members", { "Show", "SetWarnDays" }) -- (1.1)
StandIn("Consent", { "Show" }) -- 1.1: the first-open page (Consent.lua)
StandIn("Chronicle", { "Slash" }) -- 1.1: the log of acts this client saw (Chronicle.lua)
StandIn("Filter", { "Slash" }) -- 1.1: block terms (Filter.lua)
StandIn("Board", { "Slash" }) -- (1.1: the Board)
StandIn("Party", { "Slash", "SlashAuto" }) -- Sylvanistas: party invites (Party.lua)
StandIn("Week", {}) -- (1.1: the King's week)
-- 1.1: net-off (Moderation.lua), alt links (Alts.lua), the King's key rotation (Keys.lua).
StandIn("Moderation", { "Slash" })
StandIn("Alts", { "Slash" })
StandIn("Keys", { "RotatePrompt" })
StandIn("Loot", { "Show" }) -- (1.1)
StandIn("Crafters", { "Ask", "Slash" }) -- (1.1)
StandIn("ChatWindow", { "Open", "Toggle" }) -- 1.1.1: the Chat tab of the Sylvanistas window (ChatWindow.lua)
-- 1.1.2: the right-click menus' lines (PlayerMenu.lua), a player's version (Versions.lua), the
-- answer bank's Answers and explanations (Answers.lua).
StandIn("PlayerMenu", {})
StandIn("Versions", { "Check", "AskUpdate", "Tell" })
StandIn("Answers", { "Open" })

-- Blizzard's gamepad UI (WoW: Forever's controller mode) is on.
function ns.GamepadUI()
	local current = C_InputInterfaceStyle and C_InputInterfaceStyle.GetCurrentStyle
	local gamepad = Enum and Enum.InputDeviceInterfaceType and Enum.InputDeviceInterfaceType.Gamepad
	if not current or gamepad == nil then return false end
	local ok, style = pcall(current)
	return ok and style == gamepad
end

-- The addon's popups (its StaticPopupDialogs entries): with mouse and keyboard the game's own,
-- as always; with the gamepad UI Sylvanistas's (Dialog.lua), because there the game's popups
-- break when an addon opens one (the "blocked" loop that freezes the game).
-- Escape closes our windows (UISpecialFrames), except with Blizzard's gamepad UI on: its menus
-- close every window on that list, ours with them, while the player is using it (0.9.6). There
-- they close with their own X.
-- With the gamepad UI Sylvanistas writes nothing to that list (0.9.8). Blizzard reads it with no
-- protection (CloseSpecialWindows, from its menus and when the player loses control), and a
-- name table.remove moves down a place is one Sylvanistas wrote from then on. A name of ours put
-- there before a switch to the gamepad UI leaves only when it is the last one: nothing moves.
function ns.EscapeCloses(name)
	if type(name) ~= "string" or not UISpecialFrames then return end
	local gamepad = ns.GamepadUI()
	for i, n in ipairs(UISpecialFrames) do
		if n == name then
			-- Switched to the gamepad UI since: off the list (checked each time it shows).
			if gamepad and i == #UISpecialFrames then UISpecialFrames[i] = nil end
			return
		end
	end
	if not gamepad then table.insert(UISpecialFrames, name) end
end

function ns.ShowDialog(which, a, b, data)
	ns.Log("dialog %s (%s)", tostring(which), ns.GamepadUI() and "sylvanistas window, gamepad UI" or "game popup")
	if ns.GamepadUI() then
		-- Updated without restarting the game (Dialog.lua not loaded yet): never the game's
		-- popup there, the player is told to restart.
		if ns.Dialog.missing then ns.Print(L.RESTART_NEEDED) return nil end
		return ns.Dialog.Show(which, a, b, data)
	end
	return StaticPopup_Show(which, a, b, data)
end
function ns.HideDialog(which, data)
	if not ns.Dialog.missing then ns.Dialog.Hide(which, data) end
	if not ns.GamepadUI() and StaticPopup_Hide then StaticPopup_Hide(which, data) end
end

-- 1.1.2: the game holds addon messages and chat from addons now (C_ChatInfo.InChatMessagingLockdown:
-- a dungeon or raid map, an encounter, a challenge, a PvP match). A send then fails (the addon
-- message's result says so) and roster values come as secrets: the right-click menu's lines that
-- send grey out, and their functions refuse (Versions.lua, Workshop.lua, UI.lua's whispers).
function ns.ChatLocked()
	return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() and true or false
end

-- The keyboard to one of our edit boxes (setFocus: its own SetFocus). With the gamepad UI,
-- not while another box has it (the chat's): its focus change would run the game's gamepad
-- code from ours, and the game blocks it (see Dialog.lua); the player clicks into ours.
function ns.Focus(eb, setFocus)
	setFocus = setFocus or eb.SetFocus
	if ns.GamepadUI() and GetCurrentKeyBoardFocus then
		local current = GetCurrentKeyBoardFocus()
		if current and current ~= eb and not current.sylvanistasBox then return false end
	end
	setFocus(eb)
	return true
end

-- The faction may not be known yet at ADDON_LOADED: if it turns out to be the other one,
-- switch to that faction's store before anything is received.
function ns.CheckFaction()
	local f = ns.Faction()
	if not ns.db or f == ns.faction then return false end
	ns.faction = f
	local R = OpenStore(Stores(ns.db), ns.group)
	R.guilds = R.guilds or {}
	R.seen = R.seen or {}
	ns.rdb = R
	ns.Log("faction is %s: using its census", f)
	return true
end

ns.RegisterEvent("PLAYER_LOGIN", function()
	ns.CheckFaction()
	local missing = {}
	for _, key in ipairs({ "Who", "Channels", "King", "Hop", "Workshop", "Vox", "Court", "Treasury", "Dues", "Acts", "Dialog", "Bank", "Link", "Borders", "Nameplates", "Backup", "Loot", "Crafters", "Board", "Week", "Consent", "Chronicle", "Filter", "Members", "Moderation", "Alts", "Keys", "ChatWindow", "PlayerMenu", "Versions", "Answers" }) do
		if ns[key].missing then missing[#missing + 1] = key .. ".lua" end
	end
	if #missing > 0 then
		ns.Log("not loaded until the game restarts: %s", table.concat(missing, ", "))
		ns.Print(L.RESTART_NEEDED)
	end
	ns.me = ns.PlayerName()
	ns.Log("login as %s", ns.me)
	ns.Fire("LOGIN")
end)

-- Held alerts (ns.Alert) come out once the player is out of the instance (a loading screen, a
-- new zone) and not Busy (the game's flags changed): a little after, the screen settled. And
-- every 10 seconds, whatever event the client missed.
ns.On("LOGIN", function()
	local function Soon() ns.After(2, "held alerts", ns.ReleaseHeld) end
	ns.RegisterEvent("PLAYER_ENTERING_WORLD", Soon)
	ns.RegisterEvent("ZONE_CHANGED_NEW_AREA", Soon)
	ns.RegisterEvent("PLAYER_FLAGS_CHANGED", Soon)
	ns.Every(10, "held alerts", ns.ReleaseHeld)
end)

-- 1.1.2: a window that opens by itself (the author's bug report and version results, a player's
-- window for his bug report ask) waits out a fight in the open world, where ns.Alert does not
-- hold it: in the middle of the screen it would catch the mouse mid-combat. fn now out of
-- combat, else once it ends (PLAYER_REGEN_ENABLED). The same key waiting again: the newer fn, in
-- the older's place. True when it ran now.
local afterCombat = {} -- { key, fn }, in order
function ns.OutOfCombat(key, fn)
	if not (InCombatLockdown and InCombatLockdown()) then
		fn()
		return true
	end
	for _, e in ipairs(afterCombat) do
		if key ~= nil and e.key == key then
			e.fn = fn
			return false
		end
	end
	afterCombat[#afterCombat + 1] = { key = key, fn = fn }
	return false
end
function ns.RunAfterCombat()
	if (InCombatLockdown and InCombatLockdown()) or #afterCombat == 0 then return 0 end
	local list = afterCombat
	afterCombat = {}
	for _, e in ipairs(list) do ns.SafeCall("after combat " .. tostring(e.key), e.fn) end
	return #list
end
function ns.WaitingForCombat() return #afterCombat end -- (tests, /syl status)
function ns.ResetAfterCombat() afterCombat = {} end -- (tests)
ns.RegisterEvent("PLAYER_REGEN_ENABLED", ns.RunAfterCombat)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function Help()
	ns.Print(L.HELP_CMD_HEAD:format(ns.VERSION))
	print(L.HELP_CMD_OPEN)
	print(L.HELP_CMD_TABARD)
	print(L.HELP_SOUND)
	print(L.HELP_ALERTS)
	print(L.HELP_CMD_PATROL)
	print(L.HELP_CMD_MARK)
	print(L.HELP_GEAR)
	print(L.HELP_PATROLSHARE)
	print(L.HELP_APPROVED)
	print(L.HELP_LOOT)
	print(L.HELP_CRAFT)
	print(L.HELP_CMD_MAP)
	print(L.HELP_CMD_REALM)
	print(L.HELP_CMD_LAYERS)
	print(L.HELP_INACTIVE)
	print(L.HELP_WARNDAYS)
	print(L.HELP_MENTORS)
	print(L.HELP_NOCONTACT)
	print(L.HELP_HOP)
	print(L.HELP_LAYERHELP)
	print(L.HELP_LAYERAUTO)
	print(L.HELP_LOCATION)
	print(L.HELP_ROLLCALL)
	print(L.HELP_PRIVACY_PAGE)
	print(L.HELP_CHAT)
	print(L.HELP_LOG)
	print(L.HELP_FILTER)
	print(L.HELP_TREASURER)
	print(L.HELP_BANK)
	print(L.HELP_NEED)
	print(L.HELP_DONATIONS)
	print(L.HELP_BACKUP)
	print(L.HELP_INSPECTION)
	print(L.HELP_BORDERS)
	print(L.HELP_NAMEPLATES)
	print(L.HELP_ISSUE)
	print(L.HELP_COUNCIL)
	print(L.HELP_DISCORD)
	print(L.HELP_CMD_DECREES)
	print(L.HELP_CMD_ARMS)
	print(L.HELP_CHAN_ALL)
	print(L.HELP_CHAN_CAPTAINS)
	print(L.HELP_CHAN_LORDS)
	print(L.HELP_CHAN_MUTE)
	print(L.HELP_PIN)
	print(L.HELP_CHATWIN)
	print(L.HELP_TALK)
	print(L.HELP_VOX)
	print(L.HELP_BOARD)
	print(L.HELP_CAMP)
	print(L.HELP_PARTY)
	print(L.HELP_WEEK)
	print(L.HELP_CMD_MATES)
	print(L.HELP_CMD_SHARE)
	print(L.HELP_CMD_BUG)
	print(L.HELP_CMD_STATUS)
	print(L.HELP_CMD_KEY)
	if ns.Keys.CanRotate and ns.Keys.CanRotate() then print(L.HELP_KEY_ROTATE) elseif ns.Keys.CanGuildRotate and ns.Keys.CanGuildRotate() then print(L.HELP_KEY_GUILD_ROTATE) end -- (1.1: the King's alone)
	print(L.HELP_CMD_BLOCK)
	print(L.HELP_NETOFF)
	print(L.HELP_ALT)
	print(L.HELP_CMD_LAYER)
	print(L.HELP_CMD_MINIMAP)
	print(L.HELP_CMD_DEBUG)
	print(L.HELP_CMD_RESET)
end

SLASH_SYLVANISTAS1 = "/sylvanistas"
SLASH_SYLVANISTAS2 = "/syl"
-- What an error report names as the command: the command itself, with what followed it for
-- all but /syl discord (0.9.10: a Discord code, a confirmer's key: never in a report or the log).
local function SlashWhere(input)
	input = tostring(input)
	local cmd = input:match("^%s*(%S*)") or ""
	if cmd:lower() == "discord" then return "slash discord" end
	return "slash " .. input
end
ns.SlashWhere = SlashWhere -- tests

SlashCmdList.SYLVANISTAS = function(input)
	ns.SafeCall(SlashWhere(input), function()
		local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
		cmd = (cmd or ""):lower()
		-- Sylvanistas words for the original command names (those still work).
		cmd = ({ voice = "vox", rise = "arms", gather = "muster", dreadguard = "council", screams = "decrees", scream = "decrees" })[cmd] or cmd
		if cmd == "" then
			ns.UI.Toggle()
		elseif cmd == "inspect" or cmd == "tabard" or cmd == "heraldry" then
			ns.UI.SelectTab("heraldry")
		elseif cmd == "sound" then
			ns.SoundSlash(rest)
		elseif cmd == "alerts" then
			ns.AlertsSlash(rest)
		elseif cmd == "patrol" then
			ns.Inspect.SetPatrol(not ns.Inspect.IsPatrolling())
		elseif cmd == "mark" then
			ns.Inspect.MarkTarget(rest)
		elseif cmd == "gear" then
			-- 1.1 (request #28): officers keep the gear of the player they target, in range.
			ns.Inspect.InspectGear()
		elseif cmd == "loot" then
			-- 1.1 (request #22): the guild's loot notes and points, on the Realm tab.
			ns.UI.SelectTab("realm")
			ns.Loot.Show(true)
		elseif cmd == "craft" then
			-- 1.1 (request #24): who can make this item (a shift-clicked link) or these words.
			if rest == "" then
				ns.UI.SelectTab("realm")
				ns.Views.ShowPage("crafters")
			elseif ns.Crafters.Ask(rest) then
				ns.UI.SelectTab("realm")
			end
		elseif cmd == "crafter" then
			ns.Crafters.Slash(rest)
		elseif cmd == "approved" then
			-- 1.1: the guilds the author's signed list makes Sylvanistas guilds; "paste" to paste that list.
			ns.Workshop.Approved(rest)
		elseif cmd == "patrolshare" then
			-- 1.1 (request #29): officers pass their patrols' findings to their guild's officers.
			local word, on = rest:lower(), nil
			if word == "on" then on = true elseif word == "off" then on = false end
			ns.Inspect.SetSharing(on)
		elseif cmd == "map" then
			ns.Map.SetEnabled(not ns.db.showMap)
		elseif cmd == "throne" or cmd == "trono" then
			if ns.King.Visible and ns.King.Visible() then
				ns.UI.SelectTab("throne")
			else
				ns.Print(ns.L.THRONE_ONLY_KING)
			end
		elseif cmd == "vox" then
			local word = rest:lower()
			if word == "on" or word == "off" then
				ns.Vox.SetOff(word == "off")
			elseif ns.Vox.Visible and ns.Vox.Visible() then
				ns.UI.SelectTab("vox")
			else
				ns.Print(L.HELP_VOX)
			end
		elseif cmd == "realm" or cmd == "tree" or cmd == "layers" then
			if ns.Views.CloseChat then ns.Views.CloseChat() end
			ns.UI.SelectTab("realm")
		elseif cmd == "warndays" then
			ns.Members.SetWarnDays(rest)
		elseif cmd == "nocontact" then
			-- (1.1: recruits' Join screens skip us, Recruit.lua.)
			local word = rest:lower()
			if word == "on" or word == "off" then
				ns.Recruit.SetNoContact(word == "on")
			else
				ns.Print(ns.Recruit.NoContactMe() and L.NOCONTACT_ON or L.NOCONTACT_OFF)
			end
		elseif cmd == "inactive" or cmd == "members" or cmd == "recruits" or cmd == "mentors" then
			-- (1.1: our guild's members offline 7, 14 or 30 days and more; the Lord's recruits and
			-- their mentors. Members.lua.)
			local days = tonumber(rest)
			local lordPage = (cmd == "recruits" or cmd == "mentors") and ns.Members.IsLord and ns.Members.IsLord()
			ns.Members.Show(lordPage and "recruits" or (days == 14 or days == 30) and days or 7)
			ns.UI.SelectTab("realm")
		elseif cmd == "decrees" then
			ns.UI.SelectTab("decrees")
		elseif cmd == "arms" or cmd == "muster" then
			local kind = cmd == "arms" and "ARMS" or "MUSTER"
			if rest == "test" or not ns.Decree.CanSend(kind) then ns.Decree.Preview(kind) else ns.Decree.Send(kind, rest) end
		elseif cmd == "mates" then
			ns.Positions.SetEnabled(not ns.db.showMates)
		elseif cmd == "share" then
			ns.Positions.SetSharing(not ns.db.sharePosition)
		elseif cmd == "council" then
			-- The High Council's list (the author's or the King's character): add, remove, list.
			local verb, arg = rest:match("^(%S*)%s*(.-)$")
			verb = (verb or ""):lower()
			if verb == "help" then
				local a = arg:lower()
				if a == "on" or a == "off" then ns.Workshop.SetCouncilHelp(a == "on")
				else ns.Print(ns.db.councilHelp and L.COUNCIL_HELP_ON or L.COUNCIL_HELP_OFF) end
			elseif verb == "icon" then ns.Workshop.ShowIconPicker() -- a councillor's own icon (0.9.8)
			else ns.Workshop.EditCouncil(verb) end
		elseif cmd == "helpme" then
			if rest ~= "" then ns.Workshop.AskCouncil(rest) else ns.ShowDialog("SYLVANISTAS_COUNCIL_ASK") end
		elseif cmd == "issuereporter" then
			-- Blizzard's Issue Reporter box (beta and PTR clients): hidden at every login, or not.
			local how = rest:lower()
			local hide = (how == "hide" or how == "off") and true or ((how == "show" or how == "on") and false or not ns.UI.IssueReporterHidden())
			ns.UI.SetIssueReporterHidden(hide)
		elseif cmd == "inspection" then
			-- Taking part in the King's Royal Inspection (a patrol of 2 minutes that reports to him).
			local on = rest:lower()
			if on == "on" or on == "off" then ns.db.royalInspection = on == "on" end
			-- (1.1: never answered is off, and says so.)
			local v = ns.db.royalInspection
			ns.Print(v == true and L.INSPECTION_OPT_ON or (v == false and L.INSPECTION_OPT_OFF or L.INSPECTION_OPT_UNANSWERED))
		elseif cmd == "nameplates" then
			-- The marks left of the names on friendly players' nameplates (Nameplates.lua), alone: on or off.
			local on = rest:lower()
			if on == "on" or on == "off" then ns.Nameplates.SetEnabled(on == "on") else ns.Nameplates.Report() end
		elseif cmd == "borders" then
			-- The elite borders on the target, focus and your own portrait (Borders.lua), and the
			-- nameplate marks with them (Nameplates.lua): on or off.
			-- The author's preview of a tier round his own portrait (test <tier>|off): his alone;
			-- anyone else's gets what /syl borders says, and nothing is done.
			local on = rest:lower()
			local tier = on:match("^test%s+(%S+)$") or (on == "test" and "" or nil)
			if on == "on" or on == "off" then ns.Borders.SetEnabled(on == "on")
			elseif not (tier and ns.Borders.SetPreview(tier) == true) then ns.Borders.Report() end
		elseif cmd == "treasurer" then
			-- A keeper's yes to sharing his book and the guild bank (Treasury.lua).
			local on = rest:lower()
			if on == "on" or on == "off" then
				ns.Treasury.SetConsent(on == "on")
			else
				local v = ns.Treasury.Consent()
				ns.Print(v == true and L.TREASURER_SHARE_ON or L.TREASURER_SHARE_OFF)
			end
		elseif cmd == "rollcall" then
			-- The author's roll calls and update notices (Workshop.lua): answered, or not.
			local on = rest:lower()
			if on == "on" or on == "off" then
				ns.Workshop.SetAnswers(on == "on")
			else
				local v = ns.db.rollCall
				ns.Print(v == true and L.ROLLCALL_ON or (v == false and L.ROLLCALL_OFF or L.ROLLCALL_UNANSWERED))
			end
		elseif cmd == "location" then
			-- Sharing zone and layer on the Sylvanistas channel (Layers.Sharing); alone, says which.
			local on = rest:lower()
			if on == "on" or on == "off" then
				ns.Layers.SetSharing(on == "on")
			else
				ns.Print(ns.Layers.Sharing() and L.LOCATION_ON or L.LOCATION_OFF)
			end
		elseif cmd == "filter" or cmd == "filtro" then
			-- 1.1 (request #31): block terms, the player's own and the shared list (Filter.lua).
			ns.Filter.Slash(rest)
		elseif cmd == "log" then
			-- 1.1 (request #12): the acts this client saw (Chronicle.lua): [n], a word, copy, clear.
			ns.Chronicle.Slash(rest)
		elseif cmd == "privacy" or cmd == "privacidade" then
			-- 1.1 (request #11): the page of what this addon shares, each answer to change (Consent.lua).
			ns.Consent.Show()
		elseif cmd == "chat" then
			-- 1.1: the Sylvanistas chats on this client (Channels.ChatOn); alone, says which.
			local on = rest:lower()
			if on == "on" or on == "off" then
				ns.Channels.SetChatOn(on == "on")
			else
				local v = ns.db.addonChat
				ns.Print(v == true and L.CHAT_ON_MSG or (v == false and L.CHAT_OFF_MSG or L.CHAT_OFF_UNANSWERED))
			end
		elseif cmd == "officer" then
			ns.Print(ns.L.OFFICER_FIXED)
		elseif cmd == "demo" then
			ns.Print(ns.L.DEMO_REMOVED)
		elseif cmd == "bug" then
			ns.UI.ShowBugReport()
		elseif cmd == "status" then
			-- 1.1.2: the author's in a copy window (he copies it; a chat line can't be), everyone
			-- else's in chat as before.
			if ns.Workshop.IsAuthor and ns.Workshop.IsAuthor() == true and ns.UI.ShowCopy then
				ns.UI.ShowCopy("/syl status", ns.StatusText(), nil, { key = "status" })
			else
				for line in ns.StatusText():gmatch("[^\n]+") do print("  " .. line) end
			end
		elseif cmd == "key" then
			-- 1.1: "rotate" is the King's rotation of the army's key (Keys.lua), never a key: anyone
			-- else is told so (and a /reload before the restart the new file needs), and no guild is
			-- sealed with that word.
			if rest:lower() == "rotate" then
				if ns.Keys.missing then
					ns.Print(L.RESTART_NEEDED)
				elseif ns.Keys.CanRotate() then
					ns.Keys.RotatePrompt()
				elseif ns.Keys.CanGuildRotate and ns.Keys.CanGuildRotate() then
					ns.Keys.GuildRotatePrompt() -- (Sylvanistas: any Dreadguard, for the Dark Lady's guild)
				else
					ns.Print(L.KEY_ROTATE_ONLY_KING)
				end
			else
				ns.Comm.SetRealmKey(rest)
			end
		elseif cmd == "block" then
			if rest ~= "" then
				-- Stored as the sender reaches Comm (ns.FullName(ns.Normal(name)), the realm's
				-- spaces and hyphens out), whatever form the player typed.
				local name = ns.Normal(rest)
				name = name:gsub("%-([^%-]+)$", function(realm) return "-" .. realm:gsub("[%s%-]", "") end)
				local key = ns.FullName(name):lower()
				ns.db.blocked[key] = true
				ns.Print(L.BLOCKED_NOW:format(key))
			end
		elseif cmd == "layer" then
			ns.PrintLayer()
		elseif cmd == "hop" then
			ns.Hop.AskKing()
		elseif cmd == "layerhelp" or cmd == "layerauto" then
			local on = rest:lower()
			if on ~= "on" and on ~= "off" then
				ns.Print(cmd == "layerhelp" and L.HELP_LAYERHELP or L.HELP_LAYERAUTO)
			elseif cmd == "layerhelp" then
				ns.Hop.SetHelp(on == "on")
			else
				ns.Hop.SetAuto(on == "on")
			end
		elseif cmd == "minimap" then
			ns.db.hideMinimap = not ns.db.hideMinimap
			ns.UI.UpdateMinimapButton()
		elseif cmd == "photo" then
			-- The author's photo mode for the store's screenshots (UI.TogglePhoto, 1.0.0).
			ns.UI.TogglePhoto()
		elseif cmd == "released" then
			-- The author: the version CurseForge lists, which his presence names as out (1.1).
			ns.Workshop.MarkReleased(rest)
		elseif cmd == "debug" then
			ns.db.debug = not ns.db.debug
			ns.Print(ns.db.debug and L.DEBUG_ON or L.DEBUG_OFF)
		elseif cmd == "reset" then
			wipe(ns.rdb.guilds)
			wipe(ns.Data.Seen())
			ns.Who.Reset()
			ns.Fire("DATA_CHANGED")
			ns.Print(L.CACHE_CLEARED)
		elseif cmd == "error" then
			error("test error from /syl error")   -- to check that bug capture works
		elseif cmd == "all" or cmd == "captains" or cmd == "lords" then
			ns.Channels.Send(ns.Channels.TierForWord(cmd), rest)
		elseif cmd == "pin" then
			-- One line pinned for everyone (1.1, Channels.lua): the King, his Stewards and Hands, the Lords.
			ns.Channels.PinCommand(rest)
		elseif cmd == "mute" then
			ns.Channels.ToggleMute(rest)
		elseif cmd == "chatwindow" then
			ns.Channels.ChooseWindow(rest)
		elseif cmd == "talk" or cmd == "falar" then
			-- 1.1.1: the Sylvanistas window on its Chat tab (ChatWindow.lua), on a channel if one is named.
			ns.ChatWindow.Toggle(ns.Channels.TierForWord(rest))
		elseif cmd == "discord" then
			-- Sylvanistas Link (Link.lua): this character's Discord role; confirmers' keys; watchers.
			ns.Link.Slash(rest)
		elseif cmd == "party" then
			ns.Party.Slash(rest) -- Sylvanistas: party invites (Party.lua)
		elseif cmd == "partyauto" then
			ns.Party.SlashAuto(rest)
		elseif cmd == "lfg" or cmd == "board" or cmd == "camp" or cmd == "camps" or cmd == "week" then
			-- The Board (Board.lua, 1.1): who is looking for a group, and where; camps; the King's week.
			ns.Board.Slash(cmd, rest)
		elseif cmd == "netoff" or cmd == "neton" then
			-- 1.1: a character or a guild off Sylvanistas for the army, or back on (Moderation.lua).
			ns.Moderation.Slash(cmd == "netoff", rest)
		elseif cmd == "alt" or cmd == "alts" then
			-- 1.1: this account's characters linked as one player (Alts.lua).
			ns.Alts.Slash(rest)
		elseif cmd == "bank" then
			-- 1.1: a sister guild's treasurer shows his guild bank to the King, his Steward and his
			-- Hands, by whisper, or not (Bank.lua).
			local verb, on = rest:lower():match("^(%S*)%s*(%S*)")
			if verb == "share" and (on == "on" or on == "off") then ns.Bank.SetSisterConsent(on == "on") else ns.Print(L.HELP_BANK) end
		elseif cmd == "need" then
			-- 1.1: a Lord or a Captain asks the treasury for an item and a count (Bank.lua).
			ns.Bank.Slash(rest)
		elseif cmd == "backup" or cmd == "restore" then
			-- 1.1: the clipboard backup of this character's book, the channel key and its setup (Backup.lua).
			ns.Backup.Slash(cmd)
		elseif cmd == "donations" then
			-- 1.1: a keeper tells the army he is taking donations, until he logs out (Treasury.lua).
			local on = rest:lower()
			if on == "on" or on == "off" then ns.Treasury.SetDonations(on == "on") else ns.Print(L.HELP_DONATIONS) end
		else
			Help()
		end
	end)
end
