local ADDON, ns = ...
local L = ns.L

-- Block terms (1.1, Fern's #31): words that hide a line of addon text on this client. Two
-- lists: the player's own (ns.db.filterWords, account-wide, /syl filter add|remove), and a
-- shared one the King, his Steward, a Hand or a High Councillor of the author's signed list
-- edits for everyone (ns.rdb.filterShared, this realm group's), which each player may ignore
-- (/syl filter shared off; used by default).
-- Whole words only, any case and accent the search folds (ns.Fold), read as the line shows
-- (Codec.SanitizeChat, then ns.Searchable: a link's text counts, its data doesn't). Only on addon
-- text: the [Sylvanistas], [Captains] and [Lords] lines and the pinned line's words (Channels.lua), the
-- King's writs (Acts.lua: the player's own list alone, never the shared one, 1.1 review), a
-- decree's words (Decree.lua) and Vox Populi's question and answers (Vox.lua). Never a name, a
-- guild, a census row, the treasury, or the game's own chat (Say, Trade, General: never read).
-- A hit hides the line on this screen, nothing more: no kick, no net-off, no ignore, nothing sent
-- about it, and the same player's next line shows. A hidden line stays one click away (the Realm
-- tab's chats: "N lines hidden by your filter"; the Decrees tab for a writ, a decree's words or a
-- Vox question), and a companion addon reading the chats (the bridge) still gets it.
--
-- The shared list travels on the Sylvanistas channel, from an editor's client only (the server
-- stamps the sender: the King by his pinned name, a Steward by the signed titles list, a Hand by
-- the King's or a Steward's list, a High Councillor by the signed council list):
--   BW~<digest>~<+|-><term>@<server time>[@<editor>],...
-- Each word is its own entry (SHARED_TERM_MIN letters at least), added (+) or removed (-) at a
-- time; the newest time wins, word by word, so two editors never undo each other's other words,
-- and an editor who logs in with an old or empty list changes nothing (a removal is kept for
-- SHARED_TOMB, SHARED_KEEP entries at most, the oldest removals first). Each message stands alone
-- (as many as the list needs, PAGE bytes each); <digest> names the sender's whole list. An edit
-- goes out at once; each editor's client repeats the whole list every REPEAT, unless it just
-- heard another client holding the same (the digest). Clients before 1.1 know no "BW": they
-- ignore it. Each edit this client saw being made goes into its log of acts (Chronicle.lua), by
-- the name of whoever made it: an editor's client names itself (<editor>) on its own entries for
-- FRESH after their edit, never on anyone else's it repeats, and a client logs an entry only when
-- that name is the sender's, as the server stamped it (a repeat is not its sender's act). The
-- digest leaves the names out: the same list, the same digest, whoever sends it.

local Filter = {}
ns.Filter = Filter

Filter.PERSONAL_MAX = 100
Filter.SHARED_MAX = 50          -- words the shared list hides at once
Filter.SHARED_KEEP = 100        -- entries it keeps, the removed ones included
Filter.SHARED_TOMB = 30 * 86400 -- a removal is kept this long (an old client can't bring the word back)
Filter.TERM_MIN, Filter.TERM_MAX = 2, 24
Filter.SHARED_TERM_MIN = 4      -- letters of a shared term at least (1.1, Konig's review: Filter.SharedTerm)
Filter.REPEAT = 600
Filter.FRESH = 900              -- an edit this recent goes out with its editor's name (the log of acts)
Filter.AHEAD = 60               -- a time further ahead of the server's clock is not taken
Filter.FIRST_DAY = 1767225600   -- 2026-01-01: nothing older is a real edit
Filter.PAGE = 240
Filter.ENTRIES_PER_MESSAGE = 40
Filter.LOGIN_WAIT = 60          -- the first repeat after login, at the soonest (others may send it first)

Filter.random = math.random -- tests
local jitter                     -- this client's own part of REPEAT, so editors don't all repeat at once
local lastSent, heardSame = -math.huge, -math.huge

local function Clock() return (GetServerTime and GetServerTime()) or ns.Now() end

-- A term as the lists keep it: one word, folded; nil for anything else.
function Filter.Term(s)
	s = ns.Fold((tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")))
	if #s < Filter.TERM_MIN or #s > Filter.TERM_MAX or not s:match("^[%w\128-\255]+$") then return nil end
	return s
end

-- A term the shared list takes: one of SHARED_TERM_MIN letters at least (1.1, Konig's review: one
-- editor adding "the" or "de" hid nearly every decree for everyone). The player's own list still
-- takes shorter ones: it hides lines on his screen alone.
function Filter.SharedTerm(s)
	local term = Filter.Term(s)
	if not term or select(2, term:gsub("[^\128-\191]", "")) < Filter.SHARED_TERM_MIN then return nil end
	return term
end

-- The words of a text as a line shows it, folded. Punctuation of the Latin-1 and general
-- punctuation blocks ("¡¿«»", "…", "“”") separates words, as ASCII's does.
function Filter.WordsOf(text)
	local s = ns.Searchable(ns.Codec.SanitizeChat(text))
	s = s:gsub("\226\128[\128-\191]", " "):gsub("\194[\128-\191]", " ")
	local out = {}
	for w in s:gmatch("[%w\128-\255]+") do out[#out + 1] = w end
	return out
end

local function Personal()
	if type(ns.db.filterWords) ~= "table" then ns.db.filterWords = {} end
	return ns.db.filterWords
end

local function Shared()
	if type(ns.rdb.filterShared) ~= "table" then ns.rdb.filterShared = {} end
	return ns.rdb.filterShared
end

function Filter.SharedOn() return not (ns.db and ns.db.filterSharedOff == true) end

-- The term that hides this text, or nil. ownOnly: the player's own list alone (the King's writs:
-- 1.1, Konig's review, the shared list never hides them; the player's own filter still may).
function Filter.Hit(text, ownOnly)
	if type(text) ~= "string" or text == "" or not ns.db then return nil end
	local mine = ns.db.filterWords
	local shared = not ownOnly and Filter.SharedOn() and ns.rdb and ns.rdb.filterShared or nil
	local any = (type(mine) == "table" and next(mine) ~= nil) or (type(shared) == "table" and next(shared) ~= nil)
	if not any then return nil end
	for _, w in ipairs(Filter.WordsOf(text)) do
		if type(mine) == "table" and mine[w] then return w end
		local e = type(shared) == "table" and shared[w]
		if type(e) == "table" and e.on == true then return w end
	end
	return nil
end
function Filter.Hides(text, ownOnly) return Filter.Hit(text, ownOnly) ~= nil end

-- A list of terms, sorted; masked on the King's own screen (his stream): its first letter.
local function Shown(term)
	if ns.KingsScreen and ns.KingsScreen() then return ns.Cut(term, 1) .. "***" end
	return term
end
Filter.Shown = Shown -- the log of acts shows the terms' edits the same way (Chronicle.lua)
function Filter.Mine()
	local out = {}
	for term in pairs(Personal()) do out[#out + 1] = term end
	table.sort(out)
	return out
end
function Filter.SharedTerms()
	local out = {}
	for term, e in pairs(Shared()) do if type(e) == "table" and e.on == true then out[#out + 1] = term end end
	table.sort(out)
	return out
end
local function Listed(list)
	if #list == 0 then return L.FILTER_NONE end
	local out = {}
	for i, term in ipairs(list) do out[i] = Shown(term) end
	return table.concat(out, ", ")
end

---------------------------------------------------------------------------
-- The player's own list
---------------------------------------------------------------------------

function Filter.Add(word)
	local term = Filter.Term(word)
	if not term then return ns.Print(L.FILTER_BAD_TERM) end
	local mine = Personal()
	if not mine[term] and #Filter.Mine() >= Filter.PERSONAL_MAX then return ns.Print(L.FILTER_FULL:format(Filter.PERSONAL_MAX)) end
	mine[term] = true
	ns.Print(L.FILTER_ADDED:format(Shown(term)))
	ns.Fire("FILTER_CHANGED")
	return true
end

function Filter.Remove(word)
	local term = Filter.Term(word)
	local mine = Personal()
	if not term or not mine[term] then return ns.Print(L.FILTER_NOT_THERE:format(tostring(word or ""))) end
	mine[term] = nil
	ns.Print(L.FILTER_REMOVED:format(Shown(term)))
	ns.Fire("FILTER_CHANGED")
	return true
end

function Filter.SetSharedOn(on)
	ns.db.filterSharedOff = (not on) and true or nil
	ns.Print(on and L.FILTER_SHARED_ON or L.FILTER_SHARED_OFF)
	ns.Fire("FILTER_CHANGED")
end

---------------------------------------------------------------------------
-- The shared list
---------------------------------------------------------------------------

-- Who edits it: the King (his pinned name), his Steward (the signed titles list), a Hand (the
-- King's list or a Steward's) and a High Councillor of the signed council list. A sender's name
-- is the server's.
function Filter.IsEditorName(name)
	if type(name) ~= "string" or name == "" then return false end
	if ns.IsKingCharacter(name) then return true end
	local K = ns.King
	if K and not K.missing and (K.IsStewardName(name) or K.IsHandName(name)) then return true end
	return ns.IsHighCouncillor(name)
end

function Filter.CanEdit()
	if not ns.me or not ns.IsMember() then return false end
	local K = ns.King
	if K and not K.missing and (K.IsKing() or K.IsSteward() or K.IsHand()) then return true end
	return ns.IsHighCouncillor(ns.me)
end

local function Active()
	local n = 0
	for _, e in pairs(Shared()) do if type(e) == "table" and e.on == true then n = n + 1 end end
	return n
end

-- Removals past SHARED_TOMB go, then the oldest removals while the list keeps too many (on the
-- same second, by the term: every client keeps the same entries whatever order it heard them in,
-- so the digests agree; 1.1, Konig's review); anything a saved file holds that the list would
-- never take goes too.
local function Prune()
	local S, now = Shared(), Clock()
	for term, e in pairs(S) do
		if type(e) ~= "table" or Filter.SharedTerm(term) ~= term or type(e.at) ~= "number" then S[term] = nil
		elseif e.on ~= true and now - e.at > Filter.SHARED_TOMB then S[term] = nil end
	end
	local all, gone = {}, {}
	for term, e in pairs(S) do all[#all + 1] = { term = term, e = e } end
	if #all <= Filter.SHARED_KEEP then return end
	table.sort(all, function(a, b)
		if (a.e.on == true) ~= (b.e.on == true) then return a.e.on ~= true end
		if a.e.at ~= b.e.at then return a.e.at < b.e.at end
		return a.term < b.term
	end)
	for i = 1, #all - Filter.SHARED_KEEP do gone[#gone + 1] = all[i].term end
	for _, term in ipairs(gone) do S[term] = nil end
end

local function Entry(term, e) return (e.on == true and "+" or "-") .. term .. "@" .. math.floor(e.at) end

local function SameName(a, b)
	if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then return false end
	return ns.FullName(a):lower() == ns.FullName(b):lower()
end

-- An entry as it goes out: this client's own edit names its editor for FRESH after it (the log
-- of acts); anyone else's never does.
local function Piece(term, e)
	local s = Entry(term, e)
	if ns.me and SameName(e.by, ns.me) and Clock() - (tonumber(e.at) or 0) <= Filter.FRESH then s = s .. "@" .. ns.FullName(ns.me) end
	return s
end

local function Sorted()
	local out = {}
	for term, e in pairs(Shared()) do out[#out + 1] = { term = term, e = e } end
	table.sort(out, function(a, b) return a.term < b.term end)
	return out
end

local function Hash(s)
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
	return ("%08x"):format(h)
end

-- The whole list's name: the same list, the same digest, on every client.
function Filter.Digest()
	local parts = {}
	for i, x in ipairs(Sorted()) do parts[i] = Entry(x.term, x.e) end
	return Hash(table.concat(parts, ","))
end

-- The messages the whole list takes (or `list`, some of its entries), PAGE bytes each.
function Filter.Pages(list)
	list = list or Sorted()
	local head = "BW~" .. Filter.Digest() .. "~"
	local pages, cur, len = {}, {}, #head
	for _, x in ipairs(list) do
		local piece = Piece(x.term, x.e)
		if #cur > 0 and (len + 1 + #piece > Filter.PAGE or #cur >= Filter.ENTRIES_PER_MESSAGE) then
			pages[#pages + 1] = head .. table.concat(cur, ",")
			cur, len = {}, #head
		end
		len = len + #piece + (#cur > 0 and 1 or 0)
		cur[#cur + 1] = piece
	end
	if #cur > 0 then pages[#pages + 1] = head .. table.concat(cur, ",") end
	return pages
end

-- An editor's client sends the whole list (the repeat, for late logins).
function Filter.SendAll()
	if not Filter.CanEdit() then return 0 end
	Prune()
	if next(Shared()) == nil then return 0 end
	local pages = Filter.Pages()
	for i, page in ipairs(pages) do ns.Comm.Send("CHANNEL", page, "filterterms" .. i) end
	lastSent = ns.Now()
	return #pages
end

-- Every minute: an editor's client repeats the list when it is due, unless it just heard a client
-- holding the same.
function Filter.Tick()
	if not Filter.CanEdit() then return false end
	jitter = jitter or Filter.random(0, 120)
	if ns.Now() - math.max(lastSent, heardSame) < Filter.REPEAT + jitter then return false end
	return Filter.SendAll() > 0
end

local function Words(added, removed)
	local out = {}
	for _, t in ipairs(added) do out[#out + 1] = "+" .. t end
	for _, t in ipairs(removed) do out[#out + 1] = "-" .. t end
	return table.concat(out, " ")
end

-- An editor adds a word to the shared list, or takes it off: at once on the channel.
function Filter.EditShared(word, on)
	if not Filter.CanEdit() then return ns.Print(L.FILTER_NOT_EDITOR) end
	local term = Filter.SharedTerm(word)
	if not term then return ns.Print(Filter.Term(word) and L.FILTER_SHARED_SHORT:format(Filter.SHARED_TERM_MIN) or L.FILTER_BAD_TERM) end
	local S = Shared()
	local e = S[term]
	if (type(e) == "table" and e.on == true) == (on and true or false) then
		return ns.Print((on and L.FILTER_SHARED_ALREADY or L.FILTER_NOT_THERE):format(Shown(term)))
	end
	if on and Active() >= Filter.SHARED_MAX then return ns.Print(L.FILTER_SHARED_FULL:format(Filter.SHARED_MAX)) end
	S[term] = { on = on and true or false, at = math.max(math.floor(Clock()), (e and e.at or 0) + 1), by = ns.me }
	Prune()
	ns.Comm.Send("CHANNEL", Filter.Pages({ { term = term, e = S[term] } })[1], "filteredit:" .. term)
	-- Our own edit never comes back to us: in our log of acts as we send it.
	ns.Chronicle.Add("terms", ns.me, L.ACTS_TERMS:format(on and 1 or 0, on and 0 or 1), { words = Words(on and { term } or {}, on and {} or { term }) })
	ns.Print((on and L.FILTER_SHARED_ADDED or L.FILTER_SHARED_REMOVED):format(Shown(term)))
	ns.Fire("FILTER_CHANGED")
	return true
end

-- A list, or an edit, from the channel: taken from an editor alone, word by word, the newest
-- time winning.
function Filter.Receive(dist, sender, text)
	if dist ~= "CHANNEL" or type(text) ~= "string" then return end
	local digest, body = text:match("^BW~(%x+)~(.+)$")
	if not digest then return end
	sender = ns.FullName(sender)
	if not Filter.IsEditorName(sender) then
		ns.Log("block terms from %s ignored: not the King, his Steward, a Hand or a High Councillor", sender)
		return
	end
	local S, now = Shared(), Clock()
	local added, removed, changed, stored, n = {}, {}, false, false, 0
	for piece in body:gmatch("[^,]+") do
		n = n + 1
		if n > Filter.ENTRIES_PER_MESSAGE then break end
		local sign, word, at, editor = piece:match("^([%+%-])([^@]+)@(%d+)@([^@]+)$")
		if not sign then sign, word, at = piece:match("^([%+%-])([^@]+)@(%d+)$") end
		local term = word and Filter.SharedTerm(word)
		at = tonumber(at)
		if term == word and at and at <= now + Filter.AHEAD and at >= Filter.FIRST_DAY then
			local on = sign == "+"
			local e = S[term]
			local was = type(e) == "table" and e.on == true
			local newer = type(e) ~= "table" or at > (tonumber(e.at) or 0)
			local stale = not on and now - at > Filter.SHARED_TOMB
			if newer and not stale and not (on and not was and Active() >= Filter.SHARED_MAX) then
				S[term] = { on = on, at = at, by = sender }
				stored = true
				if was ~= on then
					changed = true
					-- Heard from whoever made it (its entry names the sender, as the server stamped
					-- it), not long ago: in the log of acts. Not a repeat of another editor's edit,
					-- nor a list a late login catches up on.
					if now - at <= Filter.FRESH and SameName(editor, sender) then
						if on then added[#added + 1] = term else removed[#removed + 1] = term end
					end
				end
			end
		end
	end
	-- Whatever was stored, the list kept within SHARED_KEEP (1.1, Konig's review: the removal of a
	-- word the list never held changes nothing shown, and the list grew with each one, without end).
	if stored then Prune() end
	if digest == Filter.Digest() then heardSame = ns.Now() end
	if #added + #removed > 0 then
		ns.Chronicle.Add("terms", sender, L.ACTS_TERMS:format(#added, #removed), { words = Words(added, removed) })
	end
	if changed then ns.Fire("FILTER_CHANGED") end
end
ns.Comm.Handle("BW", function(...) Filter.Receive(...) end)

---------------------------------------------------------------------------
-- /syl filter
---------------------------------------------------------------------------

function Filter.Status()
	ns.Print(L.FILTER_STATUS:format(#Filter.Mine(), #Filter.SharedTerms(), Filter.SharedOn() and L.FILTER_SHARED_USED or L.FILTER_SHARED_IGNORED))
	print("  " .. L.FILTER_LIST_MINE:format(Listed(Filter.Mine())))
	print("  " .. L.FILTER_LIST_SHARED:format(Listed(Filter.SharedTerms())))
	print("  " .. L.FILTER_USAGE)
end

function Filter.Slash(rest)
	local verb, arg = tostring(rest or ""):match("^%s*(%S*)%s*(.-)%s*$")
	verb = (verb or ""):lower()
	if verb == "add" then return Filter.Add(arg)
	elseif verb == "remove" or verb == "del" or verb == "rm" then return Filter.Remove(arg)
	elseif verb == "shared" then
		local v, word = arg:match("^(%S*)%s*(.-)$")
		v = (v or ""):lower()
		if v == "on" or v == "off" then return Filter.SetSharedOn(v == "on")
		elseif v == "add" then return Filter.EditShared(word, true)
		elseif v == "remove" or v == "del" or v == "rm" then return Filter.EditShared(word, false) end
	end
	Filter.Status()
end

-- After login an editor's client waits LOGIN_WAIT (and its own part of REPEAT) before its first
-- repeat: another editor's list may come first, the same. The list kept from an earlier session
-- is checked again first (a term too short for it since, 1.1: Filter.SharedTerm).
function Filter.OnLogin()
	if ns.rdb then Prune() end
	lastSent = ns.Now() - Filter.REPEAT + Filter.LOGIN_WAIT
end

-- Tests start from a clean state.
function Filter.Reset()
	lastSent, heardSame, jitter = -math.huge, -math.huge, nil
end

ns.On("LOGIN", function()
	Filter.OnLogin()
	ns.Every(60, "block terms", Filter.Tick)
end)
