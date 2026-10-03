local ADDON, ns = ...
local L = ns.L

-- 1.1: a clipboard backup (asked by a moderator: "the beta has been wiping
-- saved variables"). A wiped SavedVariables file loses the treasury's book with no server to
-- restore it: one text, copied out (/syl backup) and pasted back (/syl restore), brings back this
-- character's book of the treasury and the player's setup. Clipboard only: nothing is uploaded or
-- sent anywhere, and restoring sends nothing either (a keeper's book goes out afterwards as it
-- always does, under his own yes).
--   SYLB1:<length>:<adler-32>:<payload>
-- The payload is a table written as text by this file alone (never run as code: it is read by a
-- small parser with limits), each string's bytes other than letters, digits and _ . - written
-- %XX: no "|", "@" or "<#" (the copy box would change them, Codec.NoMentions), no line break.
-- What it holds:
--   books: this character's book of the treasury (its opening, its 500 lines, its sums of all
--     time), and on the Treasurer's characters the other pinned one's (his account keeps both);
--     it goes back into that character's book alone, merged with what was written since
--     (Treasury.RestoreBook);
--   word: the King's switches and keepers (his client's or a Steward's), given again as a new word;
--   settings: the player's toggles (Backup.SETTINGS) and this character's chat windows;
--   blocked: the players this character blocked (/syl block).
-- Never the channel key (review of 1.1: a restore took whatever key the text carried, and
-- an officer's client then hands it to every guildmate, so "paste this to fix your settings" moved
-- a guild to a channel the sender knows). A restore never sets one, on anyone's character, held or
-- not: the guild's officers hand it over in game as ever (K0, K5), or /syl key. A text that carries
-- one (a 1.1 beta's, or a made one) has it left out, and the confirm says so, louder for a key a
-- newer one replaced (Keys.IsRetired: the leaked one, most likely).
-- The players it blocks are named in the confirm, BLOCKED_MAX at most (the dialog lists them all),
-- and added only on its yes (a text with 2000 names could silence a guild's officers unseen).
-- Never a yes to sharing (the location, a keeper's book, a sister guild's bank, the roll call, the
-- inspection, layer help): a text someone else made must never turn sharing on. The addon asks
-- those again. Nothing restores before the player reads what changes and says yes.

local Backup = {}
ns.Backup = Backup

Backup.VERSION = "SYLB1"
Backup.MAX = 1000000       -- bytes of a backup, at most
Backup.MAX_DEPTH = 8
Backup.MAX_ENTRIES = 250000 -- values in it, at most
Backup.BLOCKED_MAX = 30    -- players a restore blocks at most (its confirm names each)
Backup.BLOCKED_NAME = 48   -- bytes of a blocked name ("name-realm")

-- The player's toggles (ns.db): what each may hold. Other batches of 1.1 add theirs here.
Backup.SETTINGS = {
	sound = "boolean", showMap = "boolean", hideMinimap = "boolean", minimapAngle = "number", showDecrees = "boolean",
	warnDays = "number", showMates = "boolean", voxOff = "boolean", borders = "boolean", nameplates = "boolean",
	hideIssueReporter = "boolean",
	-- (the other parts of 1.1: alerts held or not, camps on the map, the shared block terms, do not contact)
	alertsAlways = "boolean", showCamps = "boolean", filterSharedOff = "boolean", recruitsOff = "boolean",
}

---------------------------------------------------------------------------
-- The text: written and read here alone
---------------------------------------------------------------------------

local function Esc(s) return (s:gsub("[^%w_%.%-]", function(c) return ("%%%02X"):format(c:byte()) end)) end
local function Unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

local function Encode(v, out, depth)
	local t = type(v)
	if t == "string" then
		out[#out + 1] = "s" .. Esc(v)
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then v = 0 end
		out[#out + 1] = "n" .. (v == math.floor(v) and ("%d"):format(v) or ("%.14g"):format(v))
	elseif t == "boolean" then
		out[#out + 1] = v and "t" or "f"
	elseif t == "table" and depth < Backup.MAX_DEPTH then
		local keys = {}
		for k, x in pairs(v) do
			local kt, xt = type(k), type(x)
			if (kt == "string" or kt == "number") and (xt == "string" or xt == "number" or xt == "boolean" or xt == "table") then keys[#keys + 1] = k end
		end
		table.sort(keys, function(a, b)
			if type(a) ~= type(b) then return type(a) == "number" end
			return a < b
		end)
		out[#out + 1] = "{"
		for i, k in ipairs(keys) do
			if i > 1 then out[#out + 1] = "," end
			Encode(k, out, depth + 1)
			out[#out + 1] = "="
			Encode(v[k], out, depth + 1)
		end
		out[#out + 1] = "}"
	else
		out[#out + 1] = "f"
	end
end
function Backup.Write(v)
	local out = {}
	Encode(v, out, 0)
	return table.concat(out)
end

-- The text back into a table, or nil and why. Never code: a character at a time, within limits.
function Backup.Parse(s)
	local pos, entries = 1, 0
	local Value
	local function Fail(why) error({ why = why }, 0) end
	local function Token(pattern)
		local a, b = s:find(pattern, pos)
		if a ~= pos then return nil end
		local tok = s:sub(a, b)
		pos = b + 1
		return tok
	end
	function Value(depth)
		entries = entries + 1
		if entries > Backup.MAX_ENTRIES then Fail("too big") end
		local c = s:sub(pos, pos)
		if c == "s" then
			pos = pos + 1
			return Unesc(Token("^[%w_%.%-%%]*") or "")
		elseif c == "n" then
			pos = pos + 1
			local n = tonumber(Token("^[%-%+%d%.eE]+") or "")
			if not n then Fail("a number") end
			return n
		elseif c == "t" or c == "f" then
			pos = pos + 1
			return c == "t"
		elseif c == "{" then
			if depth >= Backup.MAX_DEPTH then Fail("too deep") end
			pos = pos + 1
			local t = {}
			if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
			while true do
				local k = Value(depth + 1)
				if type(k) ~= "string" and type(k) ~= "number" then Fail("a key") end
				if s:sub(pos, pos) ~= "=" then Fail("its shape") end
				pos = pos + 1
				t[k] = Value(depth + 1)
				local sep = s:sub(pos, pos)
				pos = pos + 1
				if sep == "}" then return t end
				if sep ~= "," then Fail("its shape") end
			end
		end
		Fail("its shape")
	end
	local ok, res = pcall(Value, 0)
	if not ok then return nil, type(res) == "table" and res.why or "its shape" end
	if pos <= #s then return nil, "its shape" end
	return res
end

-- Adler-32 of a text, as 8 hex digits: a cut short or damaged paste is caught.
function Backup.Sum(s)
	local a, b = 1, 0
	for i = 1, #s do
		a = (a + s:byte(i)) % 65521
		b = (b + a) % 65521
	end
	return ("%08x"):format(b * 65536 + a)
end

---------------------------------------------------------------------------
-- What goes in, and back
---------------------------------------------------------------------------

local function Copy(v, depth)
	if type(v) ~= "table" then return v end
	if (depth or 0) > Backup.MAX_DEPTH then return nil end
	local out = {}
	for k, x in pairs(v) do out[k] = Copy(x, (depth or 0) + 1) end
	return out
end

-- The backup of this character, as a table.
function Backup.Data()
	local d = { v = 1, t = ns.Now(), char = ns.me, group = ns.group, faction = ns.faction, version = ns.VERSION, settings = {} }
	local books = {}
	for _, b in ipairs(ns.Treasury and ns.Treasury.BackupBooks and ns.Treasury.BackupBooks() or {}) do
		books[#books + 1] = { name = b.name, opening = b.opening, openedAt = b.openedAt, opened = b.opened, lines = Copy(b.lines), sums = Copy(b.sums) }
	end
	if #books > 0 then d.books = books end
	-- The King's word, from his client or a Steward's (never the author's Dark Lady view).
	if ns.King and ns.King.SetsLists and ns.King.SetsLists() and ns.rdb then
		local f = ns.rdb.treasuryFlags
		local k = ns.rdb.treasuryKeepers
		d.word = { flags = type(f) == "table" and { balance = f.balance == true, ranking = f.ranking == true, book = f.book == true } or nil,
			keepers = type(k) == "table" and type(k.names) == "table" and Copy(k.names) or nil }
	end
	for key, kind in pairs(Backup.SETTINGS) do
		local v = ns.db and ns.db[key]
		if type(v) == kind then d.settings[key] = v end
	end
	local windows = ns.db and type(ns.db.chatWindows) == "table" and ns.db.chatWindows[ns.me]
	if type(windows) == "table" then d.chatWindows = Copy(windows) end
	if ns.db and type(ns.db.chatMute) == "table" then d.chatMute = Copy(ns.db.chatMute) end
	if ns.db and type(ns.db.soundOff) == "table" then d.soundOff = Copy(ns.db.soundOff) end -- (1.1: the kinds silenced)
	if ns.db and type(ns.db.blocked) == "table" then d.blocked = Copy(ns.db.blocked) end
	return d
end

-- The backup as it is copied out.
function Backup.Export()
	local payload = Backup.Write(Backup.Data())
	return ("%s:%d:%s:%s"):format(Backup.VERSION, #payload, Backup.Sum(payload), payload)
end

-- A book as a backup holds it, checked field by field: what can't be one is left out (a line) or
-- dropped (its sums, rebuilt from its lines then); nil when it is no book.
local function CheckBook(b)
	local MAX, COUNT = ns.Treasury.MAX_COPPER, ns.Treasury.MAX_COUNT
	local function Num(v, lo, hi) v = tonumber(v) return v and v == math.floor(v) and v >= lo and v <= hi and v or nil end
	if type(b) ~= "table" or type(b.name) ~= "string" or #b.name > 80 or b.name:find("[|%c]") then return nil end
	local out = { name = b.name, opening = Num(b.opening, 0, MAX), openedAt = Num(b.openedAt, 0, 2 ^ 31), opened = Num(b.opened, 0, 2 ^ 31), lines = {} }
	if not out.opening then return nil end
	local KINDS = { transfer = true, sale = true, purchase = true, own = true }
	for _, e in ipairs(type(b.lines) == "table" and b.lines or {}) do
		if #out.lines >= ns.Treasury.MAX then break end
		if type(e) == "table" and type(e.name) == "string" and #e.name <= 80 and not e.name:find("[|%c]") and (e.how == "trade" or e.how == "mail")
			and Num(e.money, 0, MAX) and Num(e.t, 0, 2 ^ 31) and (e.kind == nil or KINDS[e.kind]) then
			local item, count = e.item ~= nil and Num(e.item, 1, 2 ^ 31) or nil, e.count ~= nil and Num(e.count, 1, COUNT) or nil
			if e.item == nil or (item and count) then
				out.lines[#out.lines + 1] = { name = e.name, money = e.money, how = e.how, t = e.t, out = e.out == true or nil, excluded = e.excluded == true or nil,
					kind = e.kind, item = item, count = item and count or nil, returned = e.returned == true or nil,
					noted = e.noted == true or nil } -- (sent with the dues' note: Dues.Stamp, review of 1.1)
			end
		end
	end
	-- Its sums of all time (they outlive the 500 lines): their shape, or none.
	local s = b.sums
	if type(s) == "table" and s.version == 3 and Num(s.allIn, 0, MAX) and Num(s.allOut, 0, MAX) and Num(s.transIn, 0, MAX) and Num(s.transOut, 0, MAX)
		and type(s.byDonor) == "table" and type(s.days) == "table" and type(s.itemsIn) == "table" then
		local sums = { version = 3, allIn = s.allIn, allOut = s.allOut, transIn = s.transIn, transOut = s.transOut, byDonor = {}, days = {}, itemsIn = {} }
		local good = true
		for name, c in pairs(s.byDonor) do
			if type(name) ~= "string" or #name > 80 or name:find("[|%c]") or not Num(c, 1, MAX) then good = false break end
			sums.byDonor[name] = c
		end
		for id, n in pairs(s.itemsIn) do
			if not Num(id, 1, 2 ^ 31) or not Num(n, 1, 2 ^ 31) then good = false break end
			sums.itemsIn[id] = n
		end
		for day, x in pairs(s.days) do
			if type(day) ~= "string" or not day:match("^%d+%-%d+%-%d+$") or type(x) ~= "table" or not Num(x.inn, 0, MAX) or not Num(x.out, 0, MAX) or type(x.by) ~= "table" then good = false break end
			local by = {}
			for name, c in pairs(x.by) do
				if type(name) ~= "string" or #name > 80 or name:find("[|%c]") or not Num(c, 1, MAX) then good = false break end
				by[name] = c
			end
			sums.days[day] = { inn = x.inn, out = x.out, by = by }
		end
		-- (1.1: each giver's sum a week, the dues' weeks (Dues.WeekAdd), and what may be each giver's
		-- dues in the weeks no longer kept (Dues.DuesPart): rebuilt from the lines instead, a restored
		-- book's ranking would send again what they left out, review of 1.1.)
		if good and type(s.weeks) == "table" then
			sums.weeks = {}
			for wk, list in pairs(s.weeks) do
				if not Num(wk, -2 ^ 31, 2 ^ 31) or type(list) ~= "table" then good = false break end
				local week = {}
				for key, p in pairs(list) do
					if type(key) ~= "string" or #key > 80 or key:find("[|%c]") or type(p) ~= "table" or type(p.n) ~= "string" or #p.n > 80
						or p.n:find("[|%c]") or not Num(p.c, 1, MAX) or not Num(p.t, 0, 2 ^ 31) or (p.d ~= nil and not Num(p.d, 1, MAX))
						or (p.g ~= nil and (type(p.g) ~= "string" or #p.g > 80 or p.g:find("[|%c]"))) then
						good = false
						break
					end
					week[key] = { n = p.n, c = p.c, t = p.t, d = p.d, g = p.g, gv = p.gv == true or nil }
				end
				if not good then break end
				sums.weeks[wk] = week
			end
		end
		if good and type(s.duesOut) == "table" then
			sums.duesOut = {}
			for key, c in pairs(s.duesOut) do
				if type(key) ~= "string" or #key > 80 or key:find("[|%c]") or not Num(c, 1, MAX) then good = false break end
				sums.duesOut[key] = c
			end
		end
		-- (Each week's amount as the book kept it, Dues.WeekAmount: a restored book never works it out
		-- again from a later word. review of 1.1.)
		if good and type(s.amounts) == "table" then
			sums.amounts = {}
			for wk, c in pairs(s.amounts) do
				if not Num(wk, -2 ^ 31, 2 ^ 31) or not Num(c, 1, ns.Dues.MAX_AMOUNT) then good = false break end
				sums.amounts[wk] = c
			end
		end
		if good then out.sums = sums end
	end
	return out
end

-- A pasted text: the backup of this character, checked, or nil and why (to say to the player).
function Backup.Read(text)
	text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local at = text:find(Backup.VERSION .. ":", 1, true)
	if not at then return nil, L.BACKUP_NOT_ONE end
	text = text:sub(at)
	if #text > Backup.MAX + 40 then return nil, L.BACKUP_TOO_BIG end
	local length, sum, payload = text:match("^" .. Backup.VERSION .. ":(%d+):(%x+):(.*)$")
	length = tonumber(length)
	if not length or not payload then return nil, L.BACKUP_NOT_ONE end
	if #payload < length then return nil, L.BACKUP_CUT:format(#payload, length) end
	payload = payload:sub(1, length)
	if Backup.Sum(payload) ~= sum:lower() then return nil, L.BACKUP_DAMAGED end
	local d, why = Backup.Parse(payload)
	if type(d) ~= "table" then return nil, L.BACKUP_DAMAGED .. (why and (" (" .. why .. ")") or "") end
	if type(d.char) ~= "string" or not ns.me then return nil, L.BACKUP_NOT_ONE end
	-- Another character's backup: never here (the Treasurer's two characters share their books alone:
	-- his account keeps both). A name is one per realm group (Treasury.SameChar).
	if not ns.Treasury.MayRestoreBook(d.char) then return nil, L.BACKUP_OTHER:format(ns.DisplayName(d.char) or d.char) end
	if d.faction ~= nil and d.faction ~= ns.faction then return nil, L.BACKUP_OTHER_FACTION end
	local same = ns.Treasury.SameChar(d.char, ns.me)
	local out = { t = tonumber(d.t), char = d.char, books = {}, settings = {} }
	for _, b in ipairs(type(d.books) == "table" and d.books or {}) do
		local book = CheckBook(b)
		if book and ns.Treasury.MayRestoreBook(book.name) then out.books[#out.books + 1] = book end
	end
	if not same then return out end -- (the other character's settings stay its own)
	if type(d.word) == "table" then
		local w = { }
		if type(d.word.flags) == "table" then w.flags = { balance = d.word.flags.balance == true, ranking = d.word.flags.ranking == true, book = d.word.flags.book == true } end
		if type(d.word.keepers) == "table" then
			w.keepers = {}
			for _, n in ipairs(d.word.keepers) do if type(n) == "string" and #n <= 80 and #w.keepers < 10 then w.keepers[#w.keepers + 1] = n end end
		end
		out.word = w
	end
	-- A channel key in it (a 1.1 beta's text, or a made one): read only for the confirm to say it
	-- is left out (Summary); never set (Apply).
	if type(d.key) == "string" then
		local key = d.key:gsub("[~|\n]", "")
		if #key >= 6 and #key <= 64 then out.key = key end
	end
	for key, kind in pairs(Backup.SETTINGS) do
		local v = type(d.settings) == "table" and d.settings[key]
		if type(v) == kind and (kind ~= "number" or (v >= -100000 and v <= 100000)) then out.settings[key] = v end
	end
	local function Names(t, max)
		local o, n = {}, 0
		for k, v in pairs(type(t) == "table" and t or {}) do
			if type(k) == "string" and #k <= 80 and not k:find("[|%c]") and v == true and n < max then o[k] = true n = n + 1 end
		end
		return o
	end
	if type(d.chatWindows) == "table" then
		out.chatWindows = {}
		for tier, name in pairs(d.chatWindows) do
			if (tier == "A" or tier == "C" or tier == "L") and type(name) == "string" and #name <= 50 and not name:find("[|%c]") then out.chatWindows[tier] = name end
		end
	end
	if type(d.chatMute) == "table" then out.chatMute = Names(d.chatMute, 3) end
	if type(d.soundOff) == "table" then
		local kinds = {}
		for k in pairs(Names(d.soundOff, #ns.SOUND_KINDS)) do
			for _, known in ipairs(ns.SOUND_KINDS) do if k == known then kinds[k] = true end end
		end
		if next(kinds) then out.soundOff = kinds end
	end
	-- The players it would block: those not blocked here yet, BLOCKED_MAX at most (the first by
	-- name), each named in the confirm; how many more it holds, said there too.
	if type(d.blocked) == "table" then
		local held = ns.db and type(ns.db.blocked) == "table" and ns.db.blocked or {}
		local names, seen = {}, 0
		for k, v in pairs(d.blocked) do
			seen = seen + 1
			if seen > 2000 then break end
			if type(k) == "string" and k ~= "" and #k <= Backup.BLOCKED_NAME and not k:find("[|%c]") and v == true and not held[k] then names[#names + 1] = k end
		end
		table.sort(names)
		out.blocked = {}
		for i = 1, math.min(#names, Backup.BLOCKED_MAX) do out.blocked[names[i]] = true end
		if #names > Backup.BLOCKED_MAX then out.blockedLeft = #names - Backup.BLOCKED_MAX end
	end
	return out
end

-- What restoring it changes, a line each (the confirm says it all before anything changes).
function Backup.Summary(d)
	local lines = { L.BACKUP_FROM:format(ns.DisplayName(d.char) or "?", d.t and date and date("%Y-%m-%d %H:%M", d.t) or "?") }
	local T = ns.Treasury
	for _, b in ipairs(d.books) do
		local now = T.BookOf(b.name)
		local fresh = not now or #(now.lines or {}) == 0
		lines[#lines + 1] = (fresh and L.BACKUP_BOOK_WHOLE or L.BACKUP_BOOK_MERGE):format(ns.DisplayName(b.name) or b.name, #b.lines, T.Coins(b.opening))
	end
	if d.word then
		if ns.King.SetsLists() then
			if d.word.flags then
				local shown = {}
				for _, k in ipairs({ "balance", "ranking", "book" }) do if d.word.flags[k] then shown[#shown + 1] = L["TREASURY_PART_" .. k:upper()] end end
				lines[#lines + 1] = #shown > 0 and L.BACKUP_WORD_FLAGS:format(table.concat(shown, ", ")) or L.BACKUP_WORD_FLAGS_NONE
			end
			if d.word.keepers then
				local names, back = {}, {}
				local now = {}
				for _, n in ipairs(T.Keepers()) do now[#now + 1] = n end
				for _, n in ipairs(d.word.keepers) do
					names[#names + 1] = ns.DisplayName(n) or n
					local had = false
					for _, m in ipairs(now) do if T.SameChar(m, n) then had = true end end
					if not had then back[#back + 1] = ns.DisplayName(n) or n end
				end
				lines[#lines + 1] = L.BACKUP_WORD_KEEPERS:format(#names > 0 and table.concat(names, ", ") or L.TREASURY_KEEPER_NONE)
				if #back > 0 then lines[#lines + 1] = L.BACKUP_WORD_KEEPERS_BACK:format(table.concat(back, ", ")) end
			end
		else
			lines[#lines + 1] = L.BACKUP_WORD_NOT_KING
		end
	end
	-- A key in it is never set (review of 1.1); one a newer key replaced, said so.
	if d.key then
		if ns.Keys and ns.Keys.IsRetired and ns.Keys.IsRetired(d.key) then lines[#lines + 1] = L.BACKUP_KEY_RETIRED
		else lines[#lines + 1] = (ns.IsMember() and ns.Roster.IsOfficer()) and L.BACKUP_KEY or L.BACKUP_KEY_NOT_OFFICER end
	end
	local n = 0
	for _ in pairs(d.settings) do n = n + 1 end
	if d.chatWindows then n = n + 1 end
	if d.chatMute then n = n + 1 end
	if d.soundOff then n = n + 1 end
	if n > 0 then lines[#lines + 1] = L.BACKUP_SETTINGS:format(n) end
	if d.blocked and next(d.blocked) then
		local names = {}
		for k in pairs(d.blocked) do names[#names + 1] = k end
		table.sort(names)
		lines[#lines + 1] = L.BACKUP_BLOCKED:format(#names, table.concat(names, ", "))
	end
	if d.blockedLeft then lines[#lines + 1] = L.BACKUP_BLOCKED_MORE:format(d.blockedLeft, Backup.BLOCKED_MAX) end
	lines[#lines + 1] = L.BACKUP_NO_CONSENT
	return lines
end

-- Restores it (after the player's yes): books, the King's word, settings, the players the confirm
-- named as blocked. Never a channel key. Sends nothing: a keeper's book goes out afterwards as it
-- always does, under his own yes.
function Backup.Apply(d)
	if type(d) ~= "table" or not ns.me then return false end
	local T = ns.Treasury
	local books = 0
	for _, b in ipairs(d.books or {}) do
		if T.RestoreBook(b) then books = books + 1 end
	end
	-- The account's characters: the Treasurer's pinned ones are his.
	if books > 0 and ns.db then
		ns.db.myCharacters = type(ns.db.myCharacters) == "table" and ns.db.myCharacters or {}
		for _, b in ipairs(d.books) do ns.db.myCharacters[tostring(ns.FullName(ns.Normal(b.name))):lower()] = true end
	end
	if d.word and ns.King.SetsLists() then T.RestoreWord(d.word.flags, d.word.keepers) end
	local shown = {}
	for key, v in pairs(d.settings or {}) do
		if ns.db[key] ~= v then shown[key] = true end
		ns.db[key] = v
	end
	if d.chatWindows then
		ns.db.chatWindows = type(ns.db.chatWindows) == "table" and ns.db.chatWindows or {}
		ns.db.chatWindows[ns.me] = next(d.chatWindows) and d.chatWindows or nil
	end
	if d.chatMute then ns.db.chatMute = d.chatMute end
	if d.soundOff then ns.db.soundOff = d.soundOff end
	if d.blocked then
		ns.db.blocked = type(ns.db.blocked) == "table" and ns.db.blocked or {}
		for k in pairs(d.blocked) do ns.db.blocked[k] = true end
	end
	-- What shows the settings at once (the rest reads them where it needs them).
	if ns.UI and ns.UI.UpdateMinimapButton then ns.SafeCall("backup", ns.UI.UpdateMinimapButton) end
	if shown.borders and ns.Borders and ns.Borders.SetEnabled then ns.SafeCall("backup", ns.Borders.SetEnabled, ns.db.borders ~= false) end
	if shown.nameplates and ns.Nameplates and ns.Nameplates.SetEnabled then ns.SafeCall("backup", ns.Nameplates.SetEnabled, ns.db.nameplates ~= false) end
	if shown.showMap and ns.Map and ns.Map.Refresh then ns.SafeCall("backup", ns.Map.Refresh) end
	if books > 0 and T.CanSend and T.CanSend() then T.Share(true) end
	ns.Print(L.BACKUP_DONE)
	ns.Fire("TREASURY_CHANGED")
	ns.Fire("DATA_CHANGED")
	return true
end

---------------------------------------------------------------------------
-- The windows: the copy box (UI.ShowCopy) out, a paste box in
---------------------------------------------------------------------------

-- /syl backup: the text in the copy box, its button the way back in.
function Backup.ShowExport()
	local text = Backup.Export()
	ns.UI.ShowCopy(L.BACKUP_TITLE, text, { label = L.BACKUP_RESTORE_BTN, fn = function() Backup.ShowRestore() end })
	ns.Print(L.BACKUP_COPIED:format(#text))
end

StaticPopupDialogs["SYLVANISTAS_BACKUP_RESTORE"] = {
	text = L.BACKUP_CONFIRM,
	button1 = L.BACKUP_CONFIRM_YES,
	button2 = CANCEL or "Cancel",
	OnAccept = function(self, data) ns.SafeCall("backup", Backup.Apply, data or (self and self.data)) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- A text pasted: checked, then what it changes asked before anything does.
function Backup.Take(text)
	local d, why = Backup.Read(text)
	if not d then
		ns.Print(why)
		return false, why
	end
	ns.ShowDialog("SYLVANISTAS_BACKUP_RESTORE", table.concat(Backup.Summary(d), "\n"), nil, d)
	return true
end

-- The paste box. A backup can be long: pasted, the box keeps its first bytes alone (a box holding
-- all of it would freeze the game while it lays it out), and every character the paste types is
-- gathered as it comes (OnChar), then read at the next frame. It never takes the keyboard from the
-- chat box with the gamepad UI (ns.Focus): the player clicks into it.
Backup.BOX_BYTES = 2000
local pasteFrame
local gathered, gatheredCount, gatheredAt = {}, 0, nil

local function Gathered(self)
	self:SetScript("OnUpdate", nil)
	local text = table.concat(gathered, "", 1, gatheredCount)
	gathered, gatheredCount, gatheredAt = {}, 0, nil
	if not text:find(Backup.VERSION .. ":", 1, true) then return end
	local ok, why = Backup.Take(text)
	if pasteFrame and pasteFrame.status then pasteFrame.status:SetText(ok and L.BACKUP_READ_OK or why) end
end

function Backup.ShowRestore()
	if not pasteFrame then
		local f = CreateFrame("Frame", "SylvanistasPasteFrame", UIParent, "BasicFrameTemplateWithInset")
		f:SetSize(520, 240)
		f:SetPoint("CENTER")
		f:SetFrameStrata("DIALOG")
		f:SetMovable(true)
		f:EnableMouse(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		ns.EscapeCloses("SylvanistasPasteFrame")
		if f.TitleText then f.TitleText:SetText(L.BACKUP_RESTORE_TITLE) end
		local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		hint:SetPoint("TOPLEFT", 14, -30)
		hint:SetPoint("RIGHT", -14, 0)
		hint:SetJustifyH("LEFT")
		hint:SetText(L.BACKUP_PASTE_HINT)
		f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		f.status:SetPoint("BOTTOMLEFT", 14, 10)
		f.status:SetPoint("RIGHT", -14, 0)
		f.status:SetJustifyH("LEFT")
		local scroll = CreateFrame("ScrollFrame", "SylvanistasPasteScroll", f, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 12, -66)
		scroll:SetPoint("BOTTOMRIGHT", -30, 30)
		local eb = CreateFrame("EditBox", nil, scroll)
		eb:SetMultiLine(true)
		eb:SetFontObject(ChatFontNormal)
		eb:SetWidth(470)
		eb:SetHeight(140)
		eb:SetAutoFocus(false)
		if eb.SetMaxBytes then eb:SetMaxBytes(Backup.BOX_BYTES) end
		eb.sylvanistasBox = true
		eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		eb:SetScript("OnChar", function(self, c)
			local now = GetTime and GetTime() or 0
			if gatheredAt ~= now then
				gathered, gatheredCount, gatheredAt = {}, 0, now
				self:SetScript("OnUpdate", Gathered)
			end
			gatheredCount = gatheredCount + 1
			gathered[gatheredCount] = c
		end)
		scroll:SetScrollChild(eb)
		f.eb = eb
		pasteFrame = f
	end
	pasteFrame.eb:SetText("")
	pasteFrame.status:SetText("")
	pasteFrame:Show()
	ns.Focus(pasteFrame.eb)
	return pasteFrame
end

-- /syl backup, /syl restore.
function Backup.Slash(cmd)
	if cmd == "restore" then return Backup.ShowRestore() end
	return Backup.ShowExport()
end

-- Tests start from a clean state.
function Backup.Reset()
	gathered, gatheredCount, gatheredAt = {}, 0, nil
	if pasteFrame then pasteFrame:Hide() end
end
function Backup.Frame() return pasteFrame end
