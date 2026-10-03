local ADDON, ns = ...
local L = ns.L

-- Alt links (1.1, request #21): a player links the characters of this account as one
-- player, so the census and the treasury count them once.
-- - For this account only: the main names the alt (/syl alt add), then the player logs the alt
--   and confirms there. The offer waits in this account's saved variables (every character of the
--   account shares them, nobody else's can read them): no officer, and no other player, can attach
--   anyone's alt. An alt never starts a link on its own, and a character added later is not linked
--   until it confirms on itself too.
-- - Each linked character's own client says so on the Sylvanistas channel (its own name, which the
--   server stamps), at login, when a link changes and every EVERY:
--     AL~<time of the account's last change>~<M|A|->~<its guild>~<its alts (M) | its main (A)>
--   A link counts on a client only when both characters said it: the main naming the alt, and the
--   alt naming the main. A name another player claims alone links nothing.
-- - The census counts people: the army's total leaves out every linked character past the first
--   of its player's in a guild the total counts (Data.Summary). The treasury's ranking and its
--   week's donors put a player's characters on one line, under the main's name (Treasury.Report).
--   Vox Populi takes one vote per player. The alt gains nothing of its main's (a Hand's alt is no
--   Hand: every power goes by the character's own name).
-- - While any linked name is off (net-off, Moderation.lua) the links freeze: the player's own
--   client adds and removes none, and every client keeps the links it knew (a claim may add a
--   name then, never drop one, nor lapse), so nobody drops the punished character to walk back
--   in on the alt. Net-off hides the names linked to a name that is off (Moderation.Hidden).
-- Names travel short when on the sender's realm. Clients before 1.1 drop AL unread.

local Alts = {}
ns.Alts = Alts

Alts.MAX_ALTS = 8            -- alts one main links (the claim must fit one message)
Alts.EVERY = 1800            -- a linked character's client repeats its claim this often
Alts.LOGIN_AFTER = 60        -- ...the first time this long after login (the channel is joined)
Alts.KEEP = 30 * 86400       -- a claim not heard this long is forgotten (never while frozen)
Alts.MAX_CLAIMS = 5000       -- claims kept (the oldest unfrozen goes first)
Alts.DATE_AHEAD = 60         -- a claim dated further ahead of the server's clock is not taken
Alts.ASK_AFTER = 15          -- the alt's confirmation is asked this long after login (not in combat)

local stats = { taken = 0, same = 0, older = 0, frozen = 0, refused = 0, sent = 0 }
local version = 0            -- bumped on every change of a claim or of this account's links
local cache                  -- { version, groups = { { main, members = { { name, guild } } } }, of = { [key] = group } }
local lastSent = -math.huge
local asked = false          -- the confirmation was shown this session

local function Clock() return ns.Data and ns.Data.ServerTime and ns.Data.ServerTime() or ns.Now() end
local function Key(name) return tostring(ns.FullName(ns.Normal(name)) or name):lower() end
Alts.Key = Key
local function Bump() version = version + 1 end

-- A character's name as the server writes it ("First Surname-Realm"), a short one on `realm`;
-- nil if it can't be one.
local function CharName(input, realm)
	local name = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then return nil end
	name = ns.Normal(name)
	local short = ns.King and ns.King.CleanName and ns.King.CleanName(name)
	if not short then return nil end
	local r = ns.RealmOf(name)
	if r then r = r:gsub("[%s%-]", "") end
	return ns.FullName(short, (r and r ~= "") and r or realm)
end

---------------------------------------------------------------------------
-- This account's links (ns.db.alts: every character of the account shares it)
--   links[alt key]  = { name = alt, main = main, at }   confirmed on the alt
--   offers[alt key] = { name = alt, main = main, t, faction, group }   named on the main, waiting
--   guilds[key]     = the guild that character was in at its last login
--   told[key]       = the account's change that character's client last announced
---------------------------------------------------------------------------

local function Account()
	local db = ns.db
	if type(db) ~= "table" then return { links = {}, offers = {}, guilds = {}, told = {} } end
	local a = db.alts
	if type(a) ~= "table" then
		a = {}
		db.alts = a
	end
	for _, k in ipairs({ "links", "offers", "guilds", "told" }) do
		if type(a[k]) ~= "table" then a[k] = {} end
	end
	return a
end

local function Changed()
	local a = Account()
	local at = Clock()
	a.at = (tonumber(a.at) or 0) >= at and a.at + 1 or at
	Bump()
	ns.Fire("DATA_CHANGED")
end

-- This account's main of a character, its alts, and its whole group (names), from the saved links.
local function AccountMain(name)
	local link = Account().links[Key(name)]
	if type(link) == "table" then return link.main end
	for _, e in pairs(Account().links) do
		if type(e) == "table" and Key(e.main) == Key(name) then return e.main end
	end
	return nil
end
local function AccountAlts(main)
	local out, key = {}, Key(main)
	for _, e in pairs(Account().links) do
		if type(e) == "table" and Key(e.main) == key then out[#out + 1] = e.name end
	end
	table.sort(out)
	return out
end
function Alts.MyGroup()
	local main = ns.me and AccountMain(ns.me)
	if not main then return nil end
	local out = { main }
	for _, a in ipairs(AccountAlts(main)) do out[#out + 1] = a end
	return out
end

---------------------------------------------------------------------------
-- The claims heard on the channel (ns.rdb.altClaims, per realm group like the census), and the
-- groups they confirm
---------------------------------------------------------------------------

local function Claims()
	local rdb = ns.rdb
	local c = rdb and rdb.altClaims
	if type(c) ~= "table" then
		c = {}
		if rdb then rdb.altClaims = c end
	end
	return c
end

-- A character's claim: this account's own from its saved links (the confirmations themselves),
-- anyone else's as last heard. { name, role = "M"|"A"|"-", links = { names }, guild }.
local function ClaimOf(name)
	local key = Key(name)
	local a = Account()
	local link = a.links[key]
	if type(link) == "table" then return { name = link.name, role = "A", links = { link.main }, guild = a.guilds[key], own = true } end
	for _, e in pairs(a.links) do
		if type(e) == "table" and Key(e.main) == key then
			return { name = e.main, role = "M", links = AccountAlts(e.main), guild = a.guilds[key], own = true }
		end
	end
	local c = Claims()[key]
	return type(c) == "table" and c or nil
end

local function Has(list, name)
	local key = Key(name)
	for _, n in ipairs(list or {}) do if Key(n) == key then return true end end
	return false
end

-- The group a main's claim confirms: the main and each alt that names it back.
local function GroupOfMain(main)
	if not main or main.role ~= "M" then return nil end
	local members = { { name = main.name, guild = main.guild } }
	for _, alt in ipairs(main.links) do
		local c = ClaimOf(alt)
		if c and c.role == "A" and c.links[1] and Key(c.links[1]) == Key(main.name) then
			members[#members + 1] = { name = c.name, guild = c.guild }
		end
	end
	if #members < 2 then return nil end
	return { main = main.name, members = members }
end

-- Every confirmed group, rebuilt after any change (the census asks often).
local function Groups()
	if cache and cache.version == version and cache.rdb == ns.rdb and cache.db == ns.db then return cache end
	cache = { version = version, rdb = ns.rdb, db = ns.db, groups = {}, of = {} }
	local mains = {}
	for key, c in pairs(Claims()) do
		if type(c) == "table" and c.role == "M" then mains[key] = true end
	end
	for _, e in pairs(Account().links) do
		if type(e) == "table" then mains[Key(e.main)] = true end
	end
	for key in pairs(mains) do
		local main = ClaimOf(key)
		local g = main and GroupOfMain(main)
		if g then
			cache.groups[#cache.groups + 1] = g
			for _, m in ipairs(g.members) do cache.of[Key(m.name)] = g end
		end
	end
	return cache
end

-- The confirmed group of a character: { main, members = { { name, guild } } }, or nil.
function Alts.Group(name)
	if type(name) ~= "string" or name == "" then return nil end
	return Groups().of[Key(name)]
end

-- The other names of its player's confirmed group (a list, empty when none).
function Alts.Linked(name)
	local g = Alts.Group(name)
	local out = {}
	if not g then return out end
	local key = Key(name)
	for _, m in ipairs(g.members) do
		if Key(m.name) ~= key then out[#out + 1] = m.name end
	end
	return out
end

-- The name its player's characters go under together: its main's (short, as the treasury writes
-- donors), or its own.
function Alts.Person(name)
	local g = type(name) == "string" and Alts.Group(name)
	return ns.ShortName(g and g.main or name)
end

-- How many characters of the guilds `counted` ({ [guild lower case] = true }) are a player's
-- second, third... there: the army's total leaves them out.
function Alts.Duplicates(counted)
	local n = 0
	for _, g in ipairs(Groups().groups) do
		local here = 0
		for _, m in ipairs(g.members) do
			if type(m.guild) == "string" and counted[m.guild:lower()] then here = here + 1 end
		end
		if here > 1 then n = n + here - 1 end
	end
	return n
end

-- Is a name of these (and of their groups) off (net-off)? Then the links freeze.
local function OffAmong(names)
	local M = ns.Moderation
	if not (M and M.Character) then return false end
	local seen = {}
	local function Check(name)
		local key = Key(name)
		if seen[key] then return false end
		seen[key] = true
		return M.Character(name) ~= nil
	end
	for _, name in ipairs(names) do
		if Check(name) then return true end
		for _, other in ipairs(Alts.Linked(name)) do
			if Check(other) then return true end
		end
	end
	return false
end

---------------------------------------------------------------------------
-- The wire
---------------------------------------------------------------------------

-- This character's claim now: its role and names, from the account's links.
function Alts.Claim()
	if not ns.me then return "-", {} end
	local key = Key(ns.me)
	local link = Account().links[key]
	if type(link) == "table" then return "A", { link.main } end
	local alts = AccountAlts(ns.me)
	if #alts > 0 then return "M", alts end
	return "-", {}
end

-- Names as they travel: short on our realm, Name-Realm otherwise; as many as fit.
local function Wire(at, role, guild, names)
	local head = ("AL~%d~%s~%s~"):format(at, role, tostring(guild or ""):gsub("[~|%c]", ""))
	local parts, len = {}, #head
	for _, n in ipairs(names) do
		local shown = ns.RealmOf(n) == ns.realm and ns.ShortName(n) or n
		if len + #shown + 1 > 250 then break end
		parts[#parts + 1] = shown
		len = len + #shown + 1
	end
	return head .. table.concat(parts, ",")
end

-- Sends this character's claim: at the login's first round, after a change, every EVERY. A
-- character never linked sends nothing; one whose links were all removed says so once.
function Alts.Send(force)
	if not ns.me or not ns.IsMember() then return false end
	local a = Account()
	local key = Key(ns.me)
	local role, names = Alts.Claim()
	local at = tonumber(a.at) or 0
	if role == "-" and not (a.told[key] and a.told[key] < at) then return false end
	if not force and ns.Now() - lastSent < Alts.EVERY then return false end
	lastSent = ns.Now()
	a.told[key] = at
	stats.sent = stats.sent + 1
	ns.Comm.Send("CHANNEL", Wire(at, role, GetGuildInfo("player"), names), "alts")
	return true
end

-- A frozen claim takes names, never drops one: the old role, its links and the new ones.
local function Frozen(old, new)
	if type(old) ~= "table" or old.role == "-" then return new end
	local out = { name = new.name, role = old.role, links = {}, guild = new.guild, at = new.at, heard = new.heard }
	for _, n in ipairs(old.links) do out.links[#out.links + 1] = n end
	if new.role == old.role and old.role == "M" then
		for _, n in ipairs(new.links) do
			if not Has(out.links, n) and #out.links < Alts.MAX_ALTS then out.links[#out.links + 1] = n end
		end
	end
	return out
end

function Alts.Handle(dist, sender, text)
	if dist ~= "CHANNEL" then return end
	local at, role, guild, list = tostring(text):match("^AL~(%d+)~([MA%-])~([^~]*)~?(.*)$")
	at = tonumber(at)
	if not at then return end
	sender = ns.FullName(sender)
	local key = Key(sender)
	-- This account's own characters: its saved links say it better.
	if AccountMain(sender) then return end
	if at > Clock() + Alts.DATE_AHEAD then stats.refused = stats.refused + 1 return end
	local realm = ns.RealmOf(sender)
	local names = {}
	for n in tostring(list or ""):gmatch("[^,]+") do
		local full = CharName(n, realm)
		if full and Key(full) ~= key and not Has(names, full) and #names < Alts.MAX_ALTS then names[#names + 1] = full end
	end
	if role == "A" and #names ~= 1 then stats.refused = stats.refused + 1 return end
	if role == "M" and #names == 0 then role = "-" end
	if role == "-" then names = {} end
	guild = ns.King and ns.King.CleanGuild and ns.King.CleanGuild(guild) or nil
	local claims = Claims()
	local old = claims[key]
	if type(old) == "table" then
		if at < old.at then stats.older = stats.older + 1 return end
		if at == old.at then
			old.heard = ns.Now()
			stats.same = stats.same + 1
			return
		end
	else
		-- Room: the oldest claim nobody's net-off holds goes.
		local n = 0
		for _ in pairs(claims) do n = n + 1 end
		if n >= Alts.MAX_CLAIMS then
			local oldest
			for k, c in pairs(claims) do
				if type(c) == "table" and (not oldest or (c.heard or 0) < (claims[oldest].heard or 0)) and not OffAmong({ c.name }) then oldest = k end
			end
			if not oldest then return end
			claims[oldest] = nil
		end
	end
	local claim = { name = sender, role = role, links = names, guild = guild, at = at, heard = ns.Now() }
	-- A name of its group, or of what it names now, is off: the links freeze (added to, never dropped).
	local all = { sender }
	for _, n in ipairs(names) do all[#all + 1] = n end
	if type(old) == "table" and OffAmong(all) then
		claim = Frozen(old, claim)
		stats.frozen = stats.frozen + 1
		ns.Log("alt links of %s frozen: a linked name is off (net-off)", sender)
	end
	claims[key] = claim
	stats.taken = stats.taken + 1
	Bump()
	ns.Fire("DATA_CHANGED")
end
ns.Comm.Handle("AL", function(...) Alts.Handle(...) end)

---------------------------------------------------------------------------
-- The player's side: offer on the main, confirm on the alt, remove
---------------------------------------------------------------------------

-- Any name of this account's group (or of `extra`) is off: nothing is added or removed.
function Alts.Frozen(extra)
	local names = { ns.me }
	for _, n in ipairs(Alts.MyGroup() or {}) do names[#names + 1] = n end
	for _, n in ipairs(extra or {}) do names[#names + 1] = n end
	return OffAmong(names)
end

-- On the main: names an alt of this account; it is linked once the player logs it and confirms.
function Alts.Add(input)
	if not ns.me then return false end
	local name = CharName(input, ns.realm)
	if not name then ns.Print(L.ALT_WHO_BAD) return false end
	local a = Account()
	local me, key = ns.me, Key(name)
	if key == Key(me) then ns.Print(L.ALT_NOT_SELF) return false end
	-- An alt never starts a link: its main does.
	if type(a.links[Key(me)]) == "table" then ns.Print(L.ALT_NOT_FROM_ALT:format(ns.DisplayName(a.links[Key(me)].main))) return false end
	if type(a.links[key]) == "table" or #AccountAlts(name) > 0 then ns.Print(L.ALT_ALREADY:format(ns.DisplayName(name))) return false end
	if #AccountAlts(me) >= Alts.MAX_ALTS then ns.Print(L.ALT_FULL:format(Alts.MAX_ALTS)) return false end
	if Alts.Frozen({ name }) then ns.Print(L.ALT_FROZEN) return false end
	a.offers[key] = { name = name, main = me, t = Clock(), faction = ns.faction, group = ns.GroupOf(ns.realm) }
	ns.Print(L.ALT_OFFERED:format(ns.DisplayName(name)))
	return true
end

-- On the alt: the offer its main made, answered (yes: linked; no: the offer is dropped).
function Alts.Confirm(yes)
	if not ns.me then return false end
	local a = Account()
	local key = Key(ns.me)
	local offer = a.offers[key]
	if type(offer) ~= "table" then return false end
	a.offers[key] = nil
	if not yes then
		ns.Print(L.ALT_DECLINED:format(ns.DisplayName(offer.main)))
		return false
	end
	-- One census and one treasury: the same faction, the same realm group.
	if (offer.faction or "Alliance") ~= (ns.faction or "Alliance") or (offer.group and offer.group ~= ns.GroupOf(ns.realm)) then
		ns.Print(L.ALT_OTHER_CENSUS)
		return false
	end
	if type(a.links[Key(offer.main)] ) == "table" or #AccountAlts(ns.me) > 0 then ns.Print(L.ALT_ALREADY:format(ns.DisplayName(ns.me))) return false end
	if Alts.Frozen({ offer.main }) then ns.Print(L.ALT_FROZEN) return false end
	a.links[key] = { name = ns.me, main = offer.main, at = Clock() }
	Changed()
	ns.Print(L.ALT_LINKED:format(ns.DisplayName(ns.me), ns.DisplayName(offer.main)))
	Alts.Send(true)
	return true
end

-- From any character of the account: a link taken apart (an alt from its main, or this alt from
-- its main), or an offer withdrawn.
function Alts.Remove(input)
	if not ns.me then return false end
	local name = CharName(input, ns.realm)
	if not name then ns.Print(L.ALT_WHO_BAD) return false end
	local a = Account()
	local key = Key(name)
	if type(a.offers[key]) == "table" then
		a.offers[key] = nil
		ns.Print(L.ALT_OFFER_DROPPED:format(ns.DisplayName(name)))
		return true
	end
	local link = a.links[key]
	local mine = type(a.links[Key(ns.me)]) == "table" and a.links[Key(ns.me)] or nil
	-- The alt named, or the main of this alt named (this alt leaves it).
	if type(link) ~= "table" and mine and Key(mine.main) == key then link, key = mine, Key(ns.me) end
	if type(link) ~= "table" then ns.Print(L.ALT_NOT_LINKED:format(ns.DisplayName(name))) return false end
	if Alts.Frozen({ link.name, link.main }) then ns.Print(L.ALT_FROZEN) return false end
	a.links[key] = nil
	Changed()
	ns.Print(L.ALT_REMOVED:format(ns.DisplayName(link.name), ns.DisplayName(link.main)))
	Alts.Send(true)
	return true
end

-- /syl alt: this account's links and offers; add <name>, remove <name>.
function Alts.Slash(rest)
	local verb, arg = tostring(rest or ""):match("^%s*(%S*)%s*(.-)%s*$")
	verb = (verb or ""):lower()
	if verb == "add" then return Alts.Add(arg) end
	if verb == "remove" or verb == "del" or verb == "tirar" then return Alts.Remove(arg) end
	if verb == "yes" or verb == "confirm" then return Alts.Confirm(true) end
	Alts.PrintStatus()
end

function Alts.PrintStatus()
	local a = Account()
	local group = Alts.MyGroup()
	if group then
		local shown = {}
		for i = 2, #group do shown[#shown + 1] = ns.DisplayName(group[i]) end
		ns.Print(L.ALT_STATUS:format(ns.DisplayName(group[1]), table.concat(shown, ", ")))
	else
		ns.Print(L.ALT_NONE)
	end
	local waiting = {}
	for _, o in pairs(a.offers) do if type(o) == "table" then waiting[#waiting + 1] = ns.DisplayName(o.name) end end
	table.sort(waiting)
	if #waiting > 0 then ns.Print(L.ALT_WAITING:format(table.concat(waiting, ", "))) end
	if Alts.Frozen() then ns.Print(L.ALT_FROZEN) end
	print(L.HELP_ALT)
end

StaticPopupDialogs["SYLVANISTAS_ALT_CONFIRM"] = {
	text = L.ALT_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function() ns.SafeCall("alt confirm", Alts.Confirm, true) end,
	OnCancel = function(_, _, reason)
		if reason == "clicked" then ns.SafeCall("alt confirm", Alts.Confirm, false) end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- The alt's question, once a session, never in combat: its main's offer, waiting in the account.
function Alts.AskConfirm()
	if asked or not ns.me then return false end
	local offer = Account().offers[Key(ns.me)]
	if type(offer) ~= "table" then return false end
	if InCombatLockdown and InCombatLockdown() then return false end
	asked = true
	ns.ShowDialog("SYLVANISTAS_ALT_CONFIRM", ns.DisplayName(ns.me), ns.DisplayName(offer.main))
	return true
end

---------------------------------------------------------------------------
-- Upkeep
---------------------------------------------------------------------------

-- Claims nobody repeated for KEEP go, never one of a group holding a name that is off.
function Alts.Prune()
	local now, changed = ns.Now(), false
	local claims = Claims()
	for key, c in pairs(claims) do
		if type(c) ~= "table" or type(c.name) ~= "string" then
			claims[key] = nil
			changed = true
		elseif now - (tonumber(c.heard) or 0) > Alts.KEEP then
			local names = { c.name }
			for _, n in ipairs(c.links or {}) do names[#names + 1] = n end
			if not OffAmong(names) then
				claims[key] = nil
				changed = true
			end
		end
	end
	if changed then Bump() end
end

function Alts.StatusLine()
	local g = Groups()
	local mine = Alts.MyGroup()
	return ("%d players linked here  |  yours: %s  |  claims taken %d, repeats %d, frozen %d, refused %d, sent %d"):format(
		#g.groups, mine and table.concat(mine, ", ") or "none", stats.taken, stats.same, stats.frozen, stats.refused, stats.sent)
end
function Alts.Stats() return stats end

ns.On("LOGIN", function()
	-- This character's guild, for the census's count once the account's links are counted.
	ns.After(10, "alt guild", function()
		local key = ns.me and Key(ns.me)
		local guild = GetGuildInfo and GetGuildInfo("player")
		if key and Account().guilds[key] ~= guild then
			Account().guilds[key] = guild
			Bump()
		end
	end)
	ns.After(Alts.ASK_AFTER, "alt confirm", Alts.AskConfirm)
	ns.After(Alts.LOGIN_AFTER, "alt claim", function() Alts.Send(true) end)
	ns.Every(60, "alt links", function()
		Alts.Prune()
		Alts.AskConfirm()
		Alts.Send(false)
	end)
end)

-- Tests start from a clean state.
function Alts.Reset()
	cache, lastSent, asked = nil, -math.huge, false
	for k in pairs(stats) do stats[k] = 0 end
	Bump()
end
