local ADDON, ns = ...
local L = ns.L

-- The Treasury of Sylvanistas (1.0): one treasury kept in several books. Its keepers are the
-- Treasurer (ns.TREASURER of the guild SYLVANISTAS) and his mail character (the other name of
-- ns.TREASURER_CHARACTERS, in any guild or none), the King (his character, ns.KING_CHARACTER)
-- and the characters the King adds on the Treasury tab (his word, T1~K, like his switches).
-- Each keeper's own client keeps his character's book: gold and items he receives by trade or
-- mail are a donation, gold and items he gives a payment. What he earns playing is his: a book
-- is an opening balance, plus what came in, less what went out, never his character's gold. A
-- trade where he gave items (or his work: an enchant, a lock) for the gold is a sale, one where
-- he got them for his gold a purchase, gold with his own characters his own: they go in the
-- book as not counted, and a click on the line counts it (or stops counting it). The auction
-- house's and the game's mail is no donation. Gold or items between two keepers is the
-- treasury's own moving (a transfer): in both books, in each one's balance, never a donation
-- or a payment.
-- Each keeper's addon sends his book on the channel by itself (every few minutes and after a
-- change), once he said yes to it; every client puts the keepers' books together: the balance
-- is their sum, the ranking of donors and the items donated one list (a donor who gave to two
-- keepers is one line), the book every keeper's lines by time, with who received each. The
-- King sees all of it; what the rest of the army sees is the King's choice, three switches (the
-- balance, the ranking, the book), and with any of them on the Treasury tab appears for every
-- member with the addon. (The channel is readable by anyone on it: the switches choose what the
-- addon shows, they don't hide the numbers.) The King's word carries the time he gave it; his
-- switches, like his list of keepers, count only from his client and his Stewards' (Konig's
-- review of 1.0.0: the Treasurer's book could name anyone a keeper; of 1.1: it could set the
-- switches too). The Treasurer's book still carries them, for 1.0's addons alone.
-- 1.0's fresh start: the books of 0.9 are closed (kept in the saved variables, never shown or
-- sent) and each keeper's book of 1.0 opens at his character's gold at his first login on 1.0
-- (or when the King names him). The epoch travels in the message: 1.0 clients never read 0.9's
-- treasury (T8), and a later reset (another epoch) is never merged with 1.0's books.
--   TB~1.0~<guild>~<opening>~<balance>~<all in>~<all out>~<week in>~<donors this week>~<Name,...>
--     ~<switches@time|->~-~<Name:copper,...>
--     ~<i|o|r|s:copper:Name:m|t:time[:item:count],...>~<item:count:time:Name,...>
--     ~<transfers in>:<transfers out>
--   (checked when it comes, and refused whole when it fails: ReadBook. The balance is the
--   opening, plus all in, less all out, plus the transfers in, less the transfers out.)
--   (the book's lines: i a donation, o a payment, r and s a transfer received and sent; items
--   with copper 0. The switches: only in the Treasurer's, read by 1.0's addons alone (1.1: from
--   nobody's book); the keepers field is "-", and read from nobody's book.)
--   T8~<guild>~<balance>~<all in>~<all out>~<week in>~<donors this week>~<switches@time|->~<Name:copper,...>~<i|o:copper:Name:m|t:time,...>
--     0.9's treasury: the Treasurer's client still sends it, the treasury of 1.0 in short, for
--     0.9 clients; 1.0 clients never read it.
--   TR~<Name-Realm>~<time>~<TB~...>
--     the Treasurer's client passes on his mail character's book, kept on his account (an
--     account plays one character at a time, and outside a Sylvanistas guild the addon sends
--     nothing: a mail character in another guild or none never sends its own), with the time
--     that book last changed; a keeper's own TB always counts over it.
--   T1~T~<id>~<guild>~<balance 0|1><ranking 0|1><book 0|1>~<time>        the King's switches (King.lua)
--   T1~K~<id>~<guild>~<time>~<Name-Realm,...>                              the King's keepers
--     (1.0.0: his Steward's too, in his name; the newest word wins, the King's on the same second)
--   TX~<guild>                                                            a keeper withdraws his book
--   TX~<guild>~<Name-Realm>              the Treasurer withdraws his mail character's (kept private)
--   TE~<guild>~<time>~<piece>~<pieces>~<Name,...>   the early supporters (0.9's donors), in pieces
--   TQ~<time of the early supporters held, or 0>    a client asks for them
-- (T7 was 0.8.3's treasury: its clients would read T8 as theirs, and show it to all.)

local Treasury = {}
ns.Treasury = Treasury

Treasury.EPOCH = "1.0"       -- the books' era (1.0's fresh start): only books of this era are merged
Treasury.MAX = 500           -- lines kept in a book (the sums are kept apart)
Treasury.DAYS_KEPT = 8       -- days of sums kept (today and the week)
Treasury.SHARE_EVERY = 300   -- a keeper's client repeats his book for late logins
Treasury.SHARE_GAP = 60      -- and sends a change once a minute at most
Treasury.FLAGS_EVERY = 300   -- the King's client repeats his switches and his keepers
Treasury.WORD_FRESH = 120    -- 1.1: a switch given this recently goes out from its giver's client alone
Treasury.RANK_SENT = 100     -- donors in the ranking sent (0.9.7; the message goes in pieces)
Treasury.RANK_PAGE = 25      -- ranking lines shown, 25 more a click (the window stays light)
Treasury.BOOK_SENT = 15      -- latest lines of the book sent
Treasury.BOOK_SHOWN = 40     -- lines of the book shown, 40 more a click
Treasury.WEEK_SENT = 40      -- donors of the week a book of 1.0 named (1.1 names none; read, for the merged count)
Treasury.ITEMS_SENT = 20     -- items donated sent, the most given first
Treasury.ITEMS_SHOWN = 25    -- items donated listed on the tab
Treasury.LEGACY_RANK = 25    -- 0.9's treasury, for 0.9 clients: short
Treasury.LEGACY_BOOK = 5
Treasury.ROOM = 20 * 220     -- a book goes in 20 pieces at most (pieces waiting live 60 s)
Treasury.MAX_KEEPERS = 5     -- characters the King adds (each one sends his book)
Treasury.PENDING_FOR = 30    -- seconds a mail's gold or item may take to arrive once asked for
Treasury.MAX_COPPER = 2147483647
Treasury.MAX_COUNT = 999999
Treasury.RELAY_EVERY = 900   -- the Treasurer's client passes on his mail character's book this often
Treasury.EARLY_MAX = 1000    -- early supporters sent at most (names only)
Treasury.EARLY_PIECES = 100  -- pieces of their list at most, each one message of the channel's size
Treasury.EARLY_PACE = 2      -- seconds between two pieces (the channel sends one message in 1.2 s)
Treasury.EARLY_GAP = 300     -- the list goes out at most this often (after login, then when asked)
Treasury.EARLY_ASK_AFTER = 90   -- a client without the list asks this long after login...
Treasury.EARLY_ASK_AGAIN = 600  -- ...again this much later while still without it...
Treasury.EARLY_ASKS = 2         -- ...this many times a session at most...
Treasury.EARLY_ASK_HOLD = 120   -- ...and not while someone else's ask is this fresh (its answer is ours)
Treasury.EARLY_SHOWN = 60    -- early supporters shown, 60 more a click

Treasury.mode = "summary"    -- what the tab shows: summary, book or keepers

local trade                  -- the trade window open: { name, got, gave, gotItems, gaveItems, gotList, gaveList, book }
local mailOut                -- a mail on its way: { to, money, items, cod, book }
local lastShare, sharePending = -math.huge, false
local lastFlagsSent, lastKeepersSent = -math.huge, -math.huge
local lastRelay = -math.huge
local lastEarlySent, earlySending = -math.huge, nil
local earlyPending           -- a list of early supporters coming in pieces: { at, pieces, got, count, from }
local earlyAsks, lastEarlyAsk, earlyArmed, heardEarlyAsk = 0, -math.huge, false, -math.huge
local earlyShown = Treasury.EARLY_SHOWN
local pending = {}           -- mail gold asked for, until it arrives: { key, sender, money, returned, t, book }
local itemPending = {}       -- mail items asked for, until the bags hold them: { key, sender, id, n, have, returned, cod, t, book }
local lastMoney              -- the character's gold as last seen while takes wait
local bookShown = Treasury.BOOK_SHOWN
local rankShown = Treasury.RANK_PAGE

local function Grey(s) return "|cff9d9d9d" .. s .. "|r" end
local function Gold(s) return "|cffffd200" .. s .. "|r" end
local function Green(s) return "|cff40ff40" .. s .. "|r" end
local function Red(s) return "|cffff6060" .. s .. "|r" end

local function DayKey(t) return date and date("%Y-%m-%d", t) or tostring(math.floor(t / 86400)) end
-- Today and the 6 days before, by the calendar (a day of 23 or 25 hours is still one day).
local function WeekKeys(now)
	local keys, d = {}, date and date("*t", now)
	for back = 0, 6 do
		keys[#keys + 1] = d and DayKey(time({ year = d.year, month = d.month, day = d.day - back, hour = 12 })) or DayKey(now - back * 86400)
	end
	return keys
end
-- The clock the King's word is dated by: the server's, the same on every client.
local function Clock() return GetServerTime and GetServerTime() or ns.Now() end

-- 12g 30s 5c, with the coin icons when the client has them (a minus sign when negative).
function Treasury.Coins(copper)
	copper = math.floor(tonumber(copper) or 0)
	local sign = copper < 0 and "-" or ""
	copper = math.abs(copper)
	if GetCoinTextureString then
		local ok, s = pcall(GetCoinTextureString, copper)
		if ok and s then return sign .. s end
	end
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = g .. "g" end
	if s > 0 then parts[#parts + 1] = s .. "s" end
	if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
	return sign .. table.concat(parts, " ")
end
-- Gold alone, for the big numbers: "12,345g" (under a gold piece, the silver too).
function Treasury.GoldText(copper)
	copper = math.floor(tonumber(copper) or 0)
	if math.abs(copper) < 10000 then return Treasury.Coins(copper) end
	return (copper < 0 and "-" or "") .. ns.FormatNumber(math.floor(math.abs(copper) / 10000)) .. "g"
end
-- For Discord: plain text.
local function Plain(copper)
	copper = math.floor(tonumber(copper) or 0)
	local sign = copper < 0 and "-" or ""
	copper = math.abs(copper)
	local g, s = math.floor(copper / 10000), math.floor(copper / 100) % 100
	return sign .. (g > 0 and ("%sg %ds"):format(ns.FormatNumber(g), s) or ("%ds %dc"):format(s, copper % 100))
end

-- An item as the book shows it: its icon and name when the client knows them ("#2589" until it
-- does), "20x" before it when there are several.
local function ItemName(id)
	local name
	if C_Item and C_Item.GetItemNameByID then
		local ok, n = pcall(C_Item.GetItemNameByID, id)
		if ok then name = n end
	end
	if not name and GetItemInfo then
		local ok, n = pcall(GetItemInfo, id)
		if ok then name = n end
	end
	return type(name) == "string" and name ~= "" and name or ("#" .. tostring(id))
end
local function ItemIcon(id)
	local icon
	if C_Item and C_Item.GetItemIconByID then
		local ok, i = pcall(C_Item.GetItemIconByID, id)
		if ok then icon = i end
	end
	if not icon and GetItemInfoInstant then
		local ok, _, _, _, _, i = pcall(GetItemInfoInstant, id)
		if ok then icon = i end
	end
	return icon
end
local function ItemText(id, count)
	local icon = ItemIcon(id)
	local text = (icon and ("|T" .. tostring(icon) .. ":0|t ") or "") .. ItemName(id)
	return ((tonumber(count) or 1) > 1 and (count .. "x ") or "") .. text
end
Treasury.ItemText = ItemText
Treasury.ItemName = ItemName
Treasury.ItemIcon = ItemIcon

-- The item of a link ("item:2589:..."), or nil.
local function LinkId(link)
	local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
	return id and id > 0 and id or nil
end

---------------------------------------------------------------------------
-- Who: the keepers
---------------------------------------------------------------------------

local function OwnKey(name) return tostring(ns.FullName(ns.Normal(name)) or name):lower() end

-- A name of the realm group of `realm` (Forever's names are one per realm group).
local function SameGroup(name, realm)
	local own = ns.RealmOf(ns.FullName(name)) or ns.realm or ""
	return ns.GroupOf(own) == ns.GroupOf(realm or ns.realm or "")
end
-- The same character: the same name, whatever its case, on the same realm group.
local function SameChar(a, b)
	if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then return false end
	a, b = ns.FullName(ns.Normal(a)), ns.FullName(ns.Normal(b))
	if ns.ShortName(a):lower() ~= ns.ShortName(b):lower() then return false end
	return SameGroup(a, ns.RealmOf(b))
end
Treasury.SameChar = SameChar

-- The Treasurer himself (or the author's "Treasurer's view", from the Workshop).
function Treasury.IsTreasurer()
	if ns.IsMember() and ns.IsTreasurer(ns.me, GetGuildInfo("player")) then return true end
	return Treasury.DevView()
end
function Treasury.DevView()
	return ns.db and ns.db.devTreasurerView == true and ns.Workshop and ns.Workshop.Visible and ns.Workshop.Visible() or false
end
function Treasury.SetDevView(on)
	ns.db.devTreasurerView = on and true or nil
	ns.Print(on and L.DEV_TREASURER_VIEW_NOW_ON or L.DEV_TREASURER_VIEW_NOW_OFF)
	ns.Fire("DATA_CHANGED")
end

-- The King's view of the treasury: the King, his Steward (1.0.0: the switches and the keepers
-- are his to set in the King's name, never the King's own book or his yes to share it, which
-- are the King's client's alone), and the author's Asmon's view.
local function IsKingView() return ns.King.IsKing() or ns.King.IsSteward() or ns.King.Preview() end

-- The King's list of keepers as this client last heard it (never expires: a keeper's book must
-- not leave the treasury while the King is offline). { at, names = { "Name-Realm", ... } }
local function KeeperStore()
	local k = ns.rdb and ns.rdb.treasuryKeepers
	return type(k) == "table" and type(k.names) == "table" and k or nil
end
local function Listed(name)
	local k = KeeperStore()
	for _, n in ipairs(k and k.names or {}) do if SameChar(n, name) then return true end end
	return false
end
-- The names on the King's list (the author's Asmon's view: its own, on his screen only).
function Treasury.Keepers()
	local k
	if ns.King.Preview() then k = ns.db and ns.db.previewTreasuryKeepers else k = KeeperStore() end
	return type(k) == "table" and type(k.names) == "table" and k.names or {}
end

-- One of the Treasurer's pinned characters (a name as typed, whatever its case): its place in
-- ns.TREASURER_CHARACTERS (1: the Treasurer himself, 2: his mail's), or nil.
local function TreasurerPin(name)
	if type(name) ~= "string" or name == "" then return nil end
	name = ns.FullName(ns.Normal(name))
	local short = ns.ShortName(name):lower()
	for i, pin in ipairs(ns.TREASURER_CHARACTERS or { ns.TREASURER }) do
		if short == pin:lower() then return SameGroup(name, ns.TREASURER_REALM) and i or nil end
	end
	return nil
end
Treasury.TreasurerPin = TreasurerPin
-- 1.1 (Fern's #36): a line of someone's dues: gold given to one of the Treasurer's characters, by
-- trade or mail (the dues' ledger counts every one, Dues.lua). Its name and its time never leave
-- his client in a book: not on the channel (TB, TR, T8), nor in the whole book whispered to the
-- King, his Steward and the keepers (1.1): with one fixed amount a week, they would be a list of
-- who paid it, and Fern's #36 gives it to the King and that guild's Captains alone (the dues' lists).
-- Here, not in Dues.lua, so that it holds even while that file is missing (a restart owed).
local function DuesLine(keeper, e)
	if type(e) ~= "table" or e.out or e.item or e.kind == "transfer" or (tonumber(e.money) or 0) <= 0 then return false end
	return TreasurerPin(keeper) ~= nil
end
Treasury.DuesLine = DuesLine

-- One of the keepers pinned by name (the other side of a trade or a mail: its guild is not
-- known): the Treasurer's characters (his own and his mail's), or the King's character. (The
-- treasury is <Sylvanistas>'s, the Alliance's.)
local function PinnedName(name)
	if ns.TREASURY_OFF or type(name) ~= "string" or name == "" then return false end
	name = ns.FullName(ns.Normal(name))
	local short = ns.ShortName(name):lower()
	if TreasurerPin(name) then return true end
	local king = ns.KingCharacter and ns.KingCharacter()
	if king and short == king:lower() then
		local realm = ns.KingRealm and ns.KingRealm()
		return realm == nil or SameGroup(name, realm)
	end
	return false
end
function Treasury.KeeperByName(name)
	if type(name) ~= "string" or name == "" or ns.TREASURY_OFF then return false end
	return PinnedName(name) or Listed(name)
end

-- A keeper speaking (a message's sender, whose name the server sets): the Treasurer of
-- <Sylvanistas>, his mail character in any guild or none (Core.lua: its pinned name on his realm
-- group is the check), the King's character of his guild, or a character on the King's list,
-- of a Sylvanistas guild.
function Treasury.IsKeeperName(name, guild)
	if type(name) ~= "string" or ns.TREASURY_OFF then return false end
	if ns.IsTreasurerMail(name) then return true end
	if type(guild) ~= "string" then return false end
	if ns.IsTreasurer(name, guild) then return true end
	if ns.IsKingGuild(guild) and ns.IsKingCharacter(name) then return true end
	return ns.IsFederation(guild) and Listed(name)
end

-- One of the Treasurer's pinned characters speaking: the Treasurer of <Sylvanistas>, or his mail
-- character in any guild or none (the early supporters come from them alone).
local function TreasurerSpeaking(name, guild)
	if ns.TREASURY_OFF then return false end
	return ns.IsTreasurer(name, guild) or ns.IsTreasurerMail(name)
end

-- This character keeps a book of the treasury (the author's view: on his screen only). The
-- Treasurer's mail character keeps one outside a Sylvanistas guild too.
local function RealKeeper()
	if not (ns.IsMember() or ns.IsTreasurerMail(ns.me)) then return false end
	return Treasury.IsKeeperName(ns.me, GetGuildInfo("player"))
end
Treasury.RealKeeper = RealKeeper
function Treasury.IsKeeper() return RealKeeper() or Treasury.DevView() end

-- The King's switches: what the army sees (every client keeps the King's last word). The
-- author's Asmon's view keeps its own, on his screen only: the real King's word stays as it is.
local FLAGS = { "balance", "ranking", "book" }
function Treasury.Flags()
	local f
	if ns.King.Preview() then f = ns.db and ns.db.previewTreasuryFlags else f = ns.rdb and ns.rdb.treasuryFlags end
	return type(f) == "table" and f or {}
end
function Treasury.Shows(what) return Treasury.Flags()[what] == true end
local function FlagDigits(f)
	local d = {}
	for i, k in ipairs(FLAGS) do d[i] = f[k] and "1" or "0" end
	return table.concat(d)
end
function Treasury.AnyShown()
	for _, k in ipairs(FLAGS) do if Treasury.Shows(k) then return true end end
	return false
end

-- Who has the tab: the keepers, the King and his Steward (where a Treasurer can be, or once a
-- book came; the author's view always), and every member once the King shows the army something.
function Treasury.Visible()
	if Treasury.IsKeeper() or ns.King.Preview() then return true end
	-- (1.1: the King, his Steward or a Hand holding a sister guild's bank, and a Lord or Captain
	-- with a request to the treasury: Bank.lua.)
	if ns.Bank and ns.Bank.SeesSisters and ns.Bank.SeesSisters() and #ns.Bank.Sisters() > 0 then return true end
	if ns.Bank and ns.Bank.MyRequests and ns.IsMember() and #ns.Bank.MyRequests() > 0 then return true end
	if ns.King.SetsLists() then return (ns.splitNames and not ns.TREASURY_OFF) or Treasury.Report() ~= nil end
	return ns.IsMember() and Treasury.AnyShown() and Treasury.Report() ~= nil
end
-- The tab itself (1.1): also for every member who may send the week's dues (Dues.lua), with only
-- what the King shows of the treasury (Visible: nothing while he shows nothing).
function Treasury.TabVisible() return Treasury.Visible() or ns.Dues.Pays() == true end

---------------------------------------------------------------------------
-- The books (each keeper character's, kept by his own client)
---------------------------------------------------------------------------

-- 1.0's fresh start, once per store (account, faction, realm group): 0.9's book (the account's,
-- the Treasurer's) is closed and kept, never shown or sent, and 0.9's treasury as it reached
-- us (the Treasurer's T8) forgotten.
function Treasury.Migrate()
	local R = ns.rdb
	if not R or R.treasuryEpoch == Treasury.EPOCH then return end
	if R.treasury ~= nil or R.treasurySums ~= nil or R.treasuryOpening ~= nil then
		R.treasuryArchive = type(R.treasuryArchive) == "table" and R.treasuryArchive or {}
		if R.treasuryArchive["0.9"] == nil then
			R.treasuryArchive["0.9"] = { lines = R.treasury, sums = R.treasurySums, opening = R.treasuryOpening, closed = ns.Now() }
		end
	end
	R.treasury, R.treasurySums, R.treasuryOpening, R.treasuryReport = nil, nil, nil, nil
	R.treasuryEpoch = Treasury.EPOCH
end

local function Books()
	Treasury.Migrate()
	if type(ns.rdb.treasuryBooks) ~= "table" then ns.rdb.treasuryBooks = {} end
	return ns.rdb.treasuryBooks
end

-- A character's book (create: made when missing): { epoch, name, opening, lines, sums }. A book
-- of another era (a later reset) is closed and kept.
local function BookOf(name, create)
	if not ns.rdb or type(name) ~= "string" or name == "" then return nil end
	local books, key = Books(), OwnKey(name)
	local b = books[key]
	if type(b) == "table" and b.epoch ~= Treasury.EPOCH then
		ns.rdb.treasuryArchive = type(ns.rdb.treasuryArchive) == "table" and ns.rdb.treasuryArchive or {}
		ns.rdb.treasuryArchive[tostring(b.epoch) .. " " .. key] = b
		books[key], b = nil, nil
	end
	if type(b) ~= "table" then
		if not create then return nil end
		b = { epoch = Treasury.EPOCH, name = ns.FullName(ns.Normal(name)), lines = {}, opened = ns.Now() }
		books[key] = b
	end
	if type(b.lines) ~= "table" then b.lines = {} end
	return b
end
Treasury.BookOf = BookOf
-- A book changed (a line, a click, its opening): when, for a copy of it passed on (TR).
local function Touch(b) if b then b.changed = ns.Now() end end
-- When a book last changed (books of 1.0 before Touch: their latest line, or their opening).
local function BookTime(b)
	local last = b.lines and b.lines[#b.lines]
	return math.floor(tonumber(b.changed) or math.max(tonumber(last and last.t) or 0, tonumber(b.openedAt or b.opened) or 0))
end
-- This character's book, and its lines.
function Treasury.Book() return BookOf(ns.me, true) end
function Treasury.Lines(name) local b = BookOf(name or ns.me, true) return b and b.lines or {} end

-- A line's copper into its day (copper < 0: out of it), while the day is in the week kept.
local function DayCount(s, e, copper, now)
	local key = DayKey(e.t)
	local day = s.days[key]
	if not day and copper > 0 and now - e.t <= Treasury.DAYS_KEPT * 86400 then
		day = { inn = 0, out = 0, by = {} }
		s.days[key] = day
	end
	if not day then return end
	if e.out then
		day.out = math.max(0, day.out + copper)
	else
		day.inn = math.max(0, day.inn + copper)
		day.by[e.name] = (day.by[e.name] or 0) + copper
		if day.by[e.name] <= 0 then day.by[e.name] = nil end
	end
end

-- A counted line into the sums (sign 1) or out of them (sign -1): a donation or a payment into
-- the totals, the donors and the week; a transfer into the balance alone; an item given into
-- the items donated.
local function Add(s, e, sign, now)
	if e.item then
		if e.out or e.kind == "transfer" then return end
		local n = (s.itemsIn[e.item] or 0) + (tonumber(e.count) or 0) * sign
		s.itemsIn[e.item] = n > 0 and n or nil
		return
	end
	local copper = (tonumber(e.money) or 0) * sign
	if e.kind == "transfer" then
		if e.out then s.transOut = math.max(0, s.transOut + copper) else s.transIn = math.max(0, s.transIn + copper) end
		return
	end
	if e.out then
		s.allOut = math.max(0, s.allOut + copper)
	else
		s.allIn = math.max(0, s.allIn + copper)
		s.byDonor[e.name] = (s.byDonor[e.name] or 0) + copper
		if s.byDonor[e.name] <= 0 then s.byDonor[e.name] = nil end
		-- 1.1: each donor's sum per week, for the dues (Dues.lua; never sent on the channel).
		ns.Dues.WeekAdd(s, e, copper)
	end
	DayCount(s, e, copper, now)
end

-- The sums, whatever the book keeps: all time (in, out, transfers, each donor's, each item's),
-- and per day (in, out, each donor's) for today and the week. Rebuilt from the book when
-- missing or of another shape.
local SUMS = 3
local function Sums(b)
	local s = b.sums
	if type(s) ~= "table" or s.version ~= SUMS then
		s = { version = SUMS, allIn = 0, allOut = 0, transIn = 0, transOut = 0, byDonor = {}, days = {}, itemsIn = {} }
		b.sums = s
		local now = ns.Now()
		for _, e in ipairs(b.lines) do
			if not e.excluded then Add(s, e, 1, now) end
		end
	end
	-- 1.1: a book's sums from before the dues get their weeks from the lines it keeps, once.
	if s.weeks == nil then ns.Dues.Backfill(s, b.lines) end
	return s
end
Treasury.SumsOf = function(b) return Sums(b) end
local function Count(b, e, sign)
	local s = Sums(b)
	local now = ns.Now()
	Add(s, e, sign, now)
	local oldest = DayKey(now - Treasury.DAYS_KEPT * 86400)
	for k in pairs(s.days) do if k < oldest then s.days[k] = nil end end
end

-- The account's characters (a keeper's alts): gold with them is his own.
function Treasury.IsOwnCharacter(name)
	local mine = ns.db and ns.db.myCharacters
	return type(name) == "string" and type(mine) == "table" and mine[OwnKey(name)] == true
end

-- The Treasurer's own character on this account (where he played it with the addon on), or nil.
local function TreasurerCharacter()
	local mine = ns.db and ns.db.myCharacters
	if type(mine) ~= "table" or not ns.TREASURER then return nil end
	local want = ns.TREASURER:lower()
	for key, on in pairs(mine) do
		if on == true and (key == want or key:sub(1, #want + 1) == want .. "-") then return key end
	end
	return nil
end

-- One of the Treasurer's own characters (his account): the game's mail sometimes brings gold
-- sent to him to one of his alts instead (0.9.8). Since 1.0 his mail character keeps a book of
-- its own (a keeper: what it takes goes there alone, never in his too). On any other character
-- of his account, a player's gift taken there is still written in his book (his character's,
-- kept on his account; only his own character sends it), once; gold or items from a keeper or
-- from one of the account's own characters is not (TakeBook).
function Treasury.IsTreasurerAccount()
	return Treasury.IsTreasurer() or TreasurerCharacter() ~= nil
end

function Treasury.Opening(b)
	b = b or BookOf(ns.me)
	return b and tonumber(b.opening) or 0
end

-- A book's balance: its opening, plus what came in, less what went out (counted lines), with
-- the transfers between keepers.
function Treasury.Balance(b)
	b = b or BookOf(ns.me, true)
	if not b then return 0 end
	local s = Sums(b)
	return Treasury.Opening(b) + s.allIn - s.allOut + s.transIn - s.transOut
end

-- A keeper's book of this era opens at his character's gold as it is then (1.0's fresh start:
-- the treasury starts from what its keepers hold), once: at his first login on 1.0, when the
-- King names him, or before his first trade or mail if that comes first.
function Treasury.OpenBook()
	if not RealKeeper() or not GetMoney then return false end
	local b = BookOf(ns.me, true)
	b.name = ns.me
	if b.opening ~= nil then return false end
	b.opening = math.max(0, math.min(math.floor(tonumber(GetMoney()) or 0), Treasury.MAX_COPPER))
	b.openedAt = ns.Now()
	Touch(b)
	ns.Print(L.TREASURY_BOOK_OPENED:format(Treasury.Coins(b.opening)))
	Treasury.Share()
	ns.Fire("TREASURY_CHANGED")
	return true
end

-- out: a payment. o: { excluded = true, kind = "sale"|"purchase"|"own", quiet = true, book,
-- item = id, count = n }. The other side a keeper: a transfer; one of our own characters: ours.
function Treasury.Record(name, copper, how, out, o)
	o = o or {}
	copper = math.floor(tonumber(copper) or 0)
	local item, count = tonumber(o.item), math.floor(tonumber(o.count) or 0)
	if item then
		copper = 0
		if count <= 0 then return end
		count = math.min(count, Treasury.MAX_COUNT)
	elseif copper <= 0 then
		return
	end
	if type(name) ~= "string" or name == "" then return end
	local b = o.book or BookOf(ns.me, true)
	if not b then return end
	local excluded, kind = o.excluded, o.kind
	if Treasury.KeeperByName(name) and not SameChar(name, b.name) then
		excluded, kind = nil, "transfer"
	elseif Treasury.IsOwnCharacter(name) then
		excluded, kind = true, "own"
	end
	Sums(b) -- (built from the book as it was, before this line joins it)
	local who = ns.DisplayName(ns.Normal(name)) or name
	local e = { name = who, money = copper, how = how, t = ns.Now(), out = out or nil, excluded = excluded or nil, kind = kind,
		item = item, count = item and count or nil }
	-- 1.1: its week, and a gift's giver's guild (Dues.lua; kept here, never sent).
	ns.Dues.Stamp(e, name, o)
	b.lines[#b.lines + 1] = e
	while #b.lines > Treasury.MAX do table.remove(b.lines, 1) end
	if not e.excluded then Count(b, e, 1) end
	Touch(b)
	-- 1.1: an item given (a counted payment) to a player who asked the treasury for it closes his
	-- request once he got its count (Bank.lua).
	if item and out and not e.excluded and kind ~= "transfer" and ns.Bank and ns.Bank.Paid then ns.Bank.Paid(name, item, count) end
	-- The King (and the army) see it soon (once a minute at most).
	Treasury.Share()
	if not o.quiet then
		local what = item and ItemText(item, count) or Treasury.Coins(copper)
		if kind == "transfer" then
			ns.Print((out and L.TREASURY_TRANSFER_OUT or L.TREASURY_TRANSFER_IN):format(who, what))
		elseif e.excluded then
			local say = kind == "sale" and L.TREASURY_SALE or kind == "own" and L.TREASURY_OWN or L.TREASURY_PURCHASE
			ns.Print(say:format(who, what))
		else
			local line = (out and L.TREASURY_PAID or L.TREASURY_DONATION):format(who, what)
			-- A donation says what the donor gave in all, this one included (0.9.6, the Treasurer's idea).
			if not out and not item then
				for _, g in ipairs(Treasury.Totals(b).ranking) do
					if g.name == who then line = line .. " " .. L.TREASURY_IN_ALL:format(Treasury.Coins(g.money)) break end
				end
			end
			ns.Print(line)
			if not out then ns.PlayAlert("soft", "treasury") end
		end
	end
	ns.Fire("TREASURY_CHANGED")
	return e
end

-- A line counted, or no longer.
local function Flip(b, e)
	e.excluded = not e.excluded or nil
	Count(b, e, e.excluded and -1 or 1)
	Touch(b)
	Treasury.Share()
	ns.Fire("TREASURY_CHANGED")
end
-- A line of the keeper's own book counted, or no longer (his click: a sale that was a
-- donation, a payment that was his own).
function Treasury.Toggle(e, b)
	if not Treasury.IsKeeper() or type(e) ~= "table" then return end
	b = b or BookOf(ns.me, true)
	if b then Flip(b, e) end
end

-- "12345", "12,345", "12345g", "12345g 50s", "50s 20c", "1500.5" (1500g 50s): copper, or nil.
function Treasury.ParseGold(text)
	text = tostring(text or ""):lower()
	-- Thousands: a "." or "," before exactly three digits ("1.500", "1,500,000").
	local n
	repeat text, n = text:gsub("(%d)[.,](%d%d%d)%f[%D]", "%1%2") until n == 0
	-- A decimal part is silver ("1500.5", "1500,50").
	local whole, frac = text:match("^%s*(%d+)[.,](%d%d?)%s*g?%s*$")
	if whole then
		if #frac == 1 then frac = frac .. "0" end
		return math.min(tonumber(whole) * 10000 + tonumber(frac) * 100, Treasury.MAX_COPPER)
	end
	if text:find("[.,]") then return nil end
	local g = tonumber(text:match("(%d+)%s*g")) or 0
	local s = tonumber(text:match("(%d+)%s*s")) or 0
	local c = tonumber(text:match("(%d+)%s*c")) or 0
	if g == 0 and s == 0 and c == 0 then
		local plain = tonumber(text:match("^%s*(%d+)%s*$"))
		if not plain then return nil end
		g = plain
	end
	return math.min(g * 10000 + s * 100 + c, Treasury.MAX_COPPER)
end

-- A keeper sets his own book's opening (1.0 opens it at his gold; he may know better).
function Treasury.SetOpening(input)
	if not Treasury.IsKeeper() then return ns.Print(L.TREASURY_ONLY) end
	local copper = Treasury.ParseGold(input)
	if not copper then return ns.Print(L.TREASURY_OPENING_USAGE) end
	local b = BookOf(ns.me, true)
	b.opening = copper
	Touch(b)
	ns.Print(L.TREASURY_OPENING_SET:format(Treasury.Coins(copper)))
	Treasury.Share()
	ns.Fire("TREASURY_CHANGED")
end

---------------------------------------------------------------------------
-- Trades
---------------------------------------------------------------------------

-- What each side put in, as the window last showed it (read again once complete, it can say
-- 0), counted when the game says the trade is complete.
local function AnyItem(info, first, last)
	if not info then return false end
	for i = first, last do
		local name = info(i)
		if name and name ~= "" then return true end
	end
	return false
end
-- The items of slots first..last, each item once with its count: { { id, n }, ... }.
local function Merge(list, id, n)
	for _, it in ipairs(list) do
		if it.id == id then it.n = it.n + n return end
	end
	list[#list + 1] = { id = id, n = n }
end
local function TradeItems(info, link, first, last)
	local list = {}
	if not info then return list end
	for i = first, last do
		local name, _, n = info(i)
		if name and name ~= "" then
			local id = LinkId(link and link(i))
			if id then Merge(list, id, math.max(1, math.floor(tonumber(n) or 1))) end
		end
	end
	return list
end
function Treasury.TradeMoney()
	if not trade then return end
	if GetTargetTradeMoney then trade.got = tonumber(GetTargetTradeMoney()) or trade.got end
	if GetPlayerTradeMoney then trade.gave = tonumber(GetPlayerTradeMoney()) or trade.gave end
	-- Slot 7 is the one not traded: an item enchanted or a lock opened there. His work on
	-- their item is a sale (a service), theirs on his a purchase.
	trade.gaveItems = AnyItem(GetTradePlayerItemInfo, 1, 6) or AnyItem(GetTradeTargetItemInfo, 7, 7)
	trade.gotItems = AnyItem(GetTradeTargetItemInfo, 1, 6) or AnyItem(GetTradePlayerItemInfo, 7, 7)
	trade.gaveList = TradeItems(GetTradePlayerItemInfo, GetTradePlayerItemLink, 1, 6)
	trade.gotList = TradeItems(GetTradeTargetItemInfo, GetTradeTargetItemLink, 1, 6)
end

function Treasury.TradeShow()
	if not Treasury.IsKeeper() then return end
	Treasury.OpenBook() -- (at the gold before this trade, if it is still closed)
	local name = ns.UnitFullName and ns.UnitFullName("NPC") or (UnitName and UnitName("NPC"))
	-- 1.1: the guild the game shows on the other side (the dues' guild of a gift, Dues.lua).
	local ok, guild = pcall(GetGuildInfo, "NPC")
	trade = name and { name = name, got = 0, gave = 0, gotList = {}, gaveList = {}, book = BookOf(ns.me, true),
		guild = ok and type(guild) == "string" and guild ~= "" and guild or nil } or nil
end

function Treasury.Info(a, b)
	-- Classic passes (type, message), older clients the message alone.
	local msg = type(b) == "string" and b or a
	if not trade or msg ~= ERR_TRADE_COMPLETE then return end
	local done = trade
	trade = nil
	local book = done.book
	-- One line, the gold both ways netted (change given back is part of the deal). Gold for
	-- his items: a sale, his. His gold for items: a purchase, his. Not counted unless he says
	-- so (a click on the line).
	local net = done.got - done.gave
	if net > 0 then
		Treasury.Record(done.name, net, "trade", nil, { book = book, excluded = done.gaveItems or nil, kind = done.gaveItems and "sale" or nil,
			guild = done.guild })
	elseif net < 0 then
		Treasury.Record(done.name, -net, "trade", true, { book = book, excluded = done.gotItems or nil, kind = done.gotItems and "purchase" or nil })
	end
	-- Items: given with nothing back, a donation (or a payment); in a deal, part of it (not counted).
	for _, it in ipairs(done.gotList or {}) do
		local deal = (net < 0 and "purchase") or (done.gaveItems and "sale") or nil
		Treasury.Record(done.name, 0, "trade", nil, { book = book, item = it.id, count = it.n, excluded = deal and true or nil, kind = deal })
	end
	for _, it in ipairs(done.gaveList or {}) do
		local deal = (net > 0 and "sale") or (done.gotItems and "purchase") or nil
		Treasury.Record(done.name, 0, "trade", true, { book = book, item = it.id, count = it.n, excluded = deal and true or nil, kind = deal })
	end
end

---------------------------------------------------------------------------
-- Mail
---------------------------------------------------------------------------

-- Mail sent with gold or items: counted once the game says it went. Items sent cash on
-- delivery are sold (not counted).
function Treasury.MailSending(to)
	if not Treasury.IsKeeper() then return end
	Treasury.OpenBook()
	local money = GetSendMailMoney and tonumber(GetSendMailMoney()) or 0
	local cod = GetSendMailCOD and tonumber(GetSendMailCOD()) or 0
	local items = {}
	if GetSendMailItem then
		for i = 1, tonumber(ATTACHMENTS_MAX_SEND) or 12 do
			local name, itemID, _, n = GetSendMailItem(i)
			if name and name ~= "" then
				local id = LinkId(GetSendMailItemLink and GetSendMailItemLink(i)) or tonumber(itemID)
				if id then Merge(items, id, math.max(1, math.floor(tonumber(n) or 1))) end
			end
		end
	end
	local valid = type(to) == "string" and to ~= "" and (money > 0 or #items > 0)
	mailOut = valid and { to = to, money = money, items = items, cod = cod, book = BookOf(ns.me, true) } or nil
end
function Treasury.MailSent()
	local m = mailOut
	mailOut = nil
	if not m then return end
	if m.money > 0 then Treasury.Record(m.to, m.money, "mail", true, { book = m.book }) end
	for _, it in ipairs(m.items) do
		local sold = m.cod > 0
		Treasury.Record(m.to, 0, "mail", true, { book = m.book, item = it.id, count = it.n, excluded = sold or nil, kind = sold and "sale" or nil })
	end
end

-- The game's own mail (the auction house, cash on delivery): not from a player. Their
-- subjects are the client's format strings, "%s" standing for the item.
local SYSTEM_SUBJECTS = { "AUCTION_OUTBID_MAIL_SUBJECT", "AUCTION_SOLD_MAIL_SUBJECT", "AUCTION_WON_MAIL_SUBJECT",
	"AUCTION_REMOVED_MAIL_SUBJECT", "AUCTION_EXPIRED_MAIL_SUBJECT", "COD_PAYMENT" }
local systemPatterns
local function SystemMail(subject)
	if type(subject) ~= "string" then return false end
	if not systemPatterns or #systemPatterns == 0 then
		systemPatterns = {}
		for _, key in ipairs(SYSTEM_SUBJECTS) do
			local f = _G[key]
			if type(f) == "string" and f ~= "" then
				local p = f:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%s", ".+"):gsub("%%%%d", "%%d+")
				systemPatterns[#systemPatterns + 1] = "^" .. p .. "$"
			end
		end
	end
	for _, p in ipairs(systemPatterns) do
		if subject:find(p) then return true end
	end
	return false
end

-- A mail from a player (not the game's, a GM's, an invoice, or one that can't be answered),
-- or nil: { sender, subject, money, returned, cod }.
local function PlayerMail(i)
	local _, _, sender, subject, money, cod, _, _, _, wasReturned, _, canReply, isGM = GetInboxHeaderInfo(i)
	if type(sender) ~= "string" or sender == "" or isGM then return nil end
	if GetInboxInvoiceInfo and GetInboxInvoiceInfo(i) then return nil end
	if SystemMail(subject) then return nil end
	if not wasReturned and canReply == false then return nil end
	return { sender = sender, subject = subject, money = tonumber(money) or 0, returned = wasReturned or nil, cod = tonumber(cod) or 0 }
end

-- The book a mail from `sender` taken here goes in: the keeper's own (the Treasurer's mail
-- character's too: its own book, never his); on another alt of the Treasurer's account, his
-- (0.9.8: the game's mail sometimes brings his gold there), for a player's gift alone. Gold or
-- items a keeper or one of the account's own characters sends that alt is the treasury's, or
-- his own, leaving a book: the sender's book already says what it was (a payment, his own),
-- and written in his too it would count twice.
local function TakeBook(sender)
	if Treasury.IsKeeper() then
		Treasury.OpenBook()
		return BookOf(ns.me, true)
	end
	local key = TreasurerCharacter()
	if not key then return nil end
	if Treasury.KeeperByName(sender) or Treasury.IsOwnCharacter(sender) then return nil end
	local b = BookOf(key, true)
	-- (Named as his character is, until his own login names it itself.)
	if b and b.name == key then
		local realm = key:sub(#ns.TREASURER + 2)
		if ns.realm and realm:lower() == ns.realm:lower() then realm = ns.realm end
		b.name = ns.TREASURER .. (realm ~= "" and ("-" .. realm) or "")
	end
	return b
end

-- A payment by mail that came back (returned, or never opened): no longer counted.
local function Returned(b, sender, money, item, count)
	local who = ns.DisplayName(ns.Normal(sender)) or sender
	for i = #b.lines, 1, -1 do
		local e = b.lines[i]
		local same = item and (e.item == item and e.count == count) or (not item and not e.item and e.money == money)
		if e.out and e.how == "mail" and not e.excluded and same and OwnKey(e.name) == OwnKey(sender) then
			e.returned = true
			Flip(b, e)
			return ns.Print(L.TREASURY_RETURNED:format(who, item and ItemText(item, count) or Treasury.Coins(money)))
		end
	end
end

local function MailClock() return GetTime and GetTime() or ns.Now() end
local function Settle(p)
	if p.returned then return Returned(p.book, p.sender, p.money) end
	-- (1.1: the mail's subject, the dues' note: its week and guild, Dues.lua.)
	Treasury.Record(p.sender, p.money, "mail", nil, { book = p.book, note = p.note })
end
local function SettleItem(p)
	if p.returned then return Returned(p.book, p.sender, 0, p.id, p.n) end
	-- Cash on delivery: bought, not given.
	local bought = p.cod > 0
	Treasury.Record(p.sender, 0, "mail", nil, { book = p.book, item = p.id, count = p.n, excluded = bought or nil, kind = bought and "purchase" or nil })
end
local function DropStale(list, now)
	for i = #list, 1, -1 do if now - list[i].t >= Treasury.PENDING_FOR then table.remove(list, i) end end
end

-- A donation by mail is counted when its gold arrives. The take is read from the mail when the
-- keeper asks for its gold (the money button, or a mail addon's "open all": TakeInboxMoney,
-- AutoLootMailItem), just before the game empties it, and waits for the gold (PLAYER_MONEY,
-- Treasury.MoneyChanged). A second click on that mail meanwhile counts nothing; a take the
-- server refuses (MAIL_FAILED) is dropped, its gold still in the mail; the mail that moves up
-- into its place once it is gone is another.
function Treasury.MailTaking(i)
	if not GetInboxHeaderInfo or type(i) ~= "number" then return end
	if not Treasury.IsTreasurerAccount() and not Treasury.IsKeeper() then return end
	local m = PlayerMail(i)
	if not m or m.money <= 0 then return end
	local book = TakeBook(m.sender)
	if not book then return end
	if not GetMoney then return Settle({ sender = m.sender, money = m.money, returned = m.returned, book = book, note = m.subject }) end
	local now = MailClock()
	DropStale(pending, now)
	local key = ("%d|%s|%s|%d"):format(i, m.sender, tostring(m.subject or ""), m.money)
	for _, p in ipairs(pending) do if p.key == key then return end end
	if #pending == 0 then lastMoney = GetMoney() end
	pending[#pending + 1] = { key = key, sender = m.sender, money = m.money, returned = m.returned, t = now, book = book, note = m.subject }
end

-- The character's gold went up: the takes it pays for are counted (the one of that exact
-- amount first, else in order while the gold covers them; gold from anywhere else is not).
function Treasury.MoneyChanged()
	if #pending == 0 or not GetMoney then return end
	local money = GetMoney()
	local gained = money - (lastMoney or money)
	lastMoney = money
	DropStale(pending, MailClock())
	if gained <= 0 then return end
	for i, p in ipairs(pending) do
		if p.money == gained then
			table.remove(pending, i)
			return Settle(p)
		end
	end
	local i = 1
	while pending[i] do
		if pending[i].money <= gained then
			gained = gained - pending[i].money
			Settle(table.remove(pending, i))
		else
			i = i + 1
		end
	end
end

-- How many of an item the bags hold, or nil where the client can't say.
local function ItemCount(id)
	local f = (C_Item and C_Item.GetItemCount) or GetItemCount
	if not f then return nil end
	local ok, n = pcall(f, id)
	return ok and tonumber(n) or nil
end

-- An item donated by mail is counted when the bags hold it, like gold: the take is read when
-- the keeper asks for it (an attachment's button, TakeInboxItem; "open all" and a mail addons'
-- AutoLootMailItem: every attachment), and waits for the bags (BAG_UPDATE_DELAYED,
-- Treasury.ItemsChanged). a: one attachment; nil: all of them.
function Treasury.MailItemTaking(i, a)
	if not GetInboxHeaderInfo or not GetInboxItem or type(i) ~= "number" then return end
	if not Treasury.IsTreasurerAccount() and not Treasury.IsKeeper() then return end
	local m = PlayerMail(i)
	if not m then return end
	local book = TakeBook(m.sender)
	if not book then return end
	local now = MailClock()
	DropStale(itemPending, now)
	local first, last = a or 1, a or tonumber(ATTACHMENTS_MAX_RECEIVE) or 16
	for k = first, last do
		local name, itemID, _, n = GetInboxItem(i, k)
		local id = name and (LinkId(GetInboxItemLink and GetInboxItemLink(i, k)) or tonumber(itemID))
		n = math.max(1, math.floor(tonumber(n) or 1))
		if id then
			local p = { key = ("%d|%d|%s|%s|%d|%d"):format(i, k, m.sender, tostring(m.subject or ""), id, n), sender = m.sender, id = id, n = n,
				returned = m.returned, cod = m.cod, t = now, book = book }
			local known = false
			for _, q in ipairs(itemPending) do if q.key == p.key then known = true end end
			if not known then
				p.have = ItemCount(id)
				if p.have then itemPending[#itemPending + 1] = p else SettleItem(p) end
			end
		end
	end
end

-- The bags changed: each item taken is counted once they hold it (the takes of one item in the
-- order asked, each on top of the one before).
function Treasury.ItemsChanged()
	if #itemPending == 0 then return end
	DropStale(itemPending, MailClock())
	local ids, seen = {}, {}
	for _, p in ipairs(itemPending) do
		if not seen[p.id] then seen[p.id] = true ids[#ids + 1] = p.id end
	end
	for _, id in ipairs(ids) do
		local count = ItemCount(id)
		while count do
			local first
			for k, q in ipairs(itemPending) do if q.id == id then first = k break end end
			local q = first and itemPending[first]
			if not q or count - q.have < q.n then break end
			table.remove(itemPending, first)
			for _, r in ipairs(itemPending) do
				if r.id == id then r.have = math.max(r.have, q.have + q.n) break end
			end
			SettleItem(q)
		end
	end
end

-- A take the server refused: its gold or its item is still in the mail, nothing counted (the
-- latest take of that item when the game names it, else the latest gold take).
function Treasury.MailFailed(itemID)
	itemID = tonumber(itemID)
	if itemID then
		for i = #itemPending, 1, -1 do
			if itemPending[i].id == itemID then table.remove(itemPending, i) return end
		end
		return
	end
	table.remove(pending)
end

-- A book's sums: today, this week (today and the 6 days before), all time; the givers of the
-- week and of all time, most generous first; the items donated, the most given first, with
-- their latest donors.
function Treasury.Totals(b)
	b = b or BookOf(ns.me, true) or { lines = {} }
	local now = ns.Now()
	local s = Sums(b)
	local t = { todayIn = 0, todayOut = 0, weekIn = 0, weekOut = 0, allIn = s.allIn, allOut = s.allOut, transIn = s.transIn, transOut = s.transOut,
		givers = {}, ranking = {}, items = {} }
	local by = {}
	for back, key in ipairs(WeekKeys(now)) do
		local day = s.days[key]
		if day then
			t.weekIn, t.weekOut = t.weekIn + day.inn, t.weekOut + day.out
			if back == 1 then t.todayIn, t.todayOut = day.inn, day.out end
			for name, copper in pairs(day.by) do
				local g = by[name]
				if not g then
					g = { name = name, money = 0 }
					by[name] = g
					t.givers[#t.givers + 1] = g
				end
				g.money = g.money + copper
			end
		end
	end
	for name, copper in pairs(s.byDonor) do t.ranking[#t.ranking + 1] = { name = name, money = copper } end
	local function Most(x, y)
		if x.money ~= y.money then return x.money > y.money end
		return x.name < y.name
	end
	table.sort(t.givers, Most)
	table.sort(t.ranking, Most)
	-- The latest donors of each item, from the book (three at most).
	local latest = {}
	for i = #b.lines, 1, -1 do
		local e = b.lines[i]
		if e.item and not e.out and not e.excluded and e.kind ~= "transfer" then
			local l = latest[e.item] or {}
			latest[e.item] = l
			local seen = false
			for _, d in ipairs(l) do if d.name == e.name then seen = true end end
			if not seen and #l < 3 then l[#l + 1] = { name = e.name, t = e.t or 0 } end
		end
	end
	for id, n in pairs(s.itemsIn) do
		local l = latest[id] or {}
		t.items[#t.items + 1] = { id = id, n = n, donors = l, t = l[1] and l[1].t or 0 }
	end
	table.sort(t.items, function(x, y)
		if x.n ~= y.n then return x.n > y.n end
		return x.id < y.id
	end)
	return t
end

-- 1.1, Konig's review (the ranking): a ranked donor's total in the Treasurer's book grew by the
-- dues' amount the week he paid it (one fixed amount), which told the channel who paid and so who
-- did not (Fern's #36). The ranking (all time, which Fern kept public) that leaves the Treasurer's
-- client (the channel's, the whole book whispered, 0.9's copy, his mail character's he passes on)
-- leaves out, of each giver's gold to the Treasurer's characters, each week's up to that week's
-- amount as the book kept it, and all he sent with the dues' note (Dues.DuesPart): what may be his
-- dues, paid or not. A total grows only by what a week's gold went over the amount, so one that did
-- not grow may be a payer's or not: it shows no payer of the amount the Treasurer's client knew that
-- week (one who paid more by trade or plain mail while it knew less shows by the difference). It is
-- that much lower than on the Treasurer's own screen. Another keeper's book, which is no dues: as it is.
local function PublicRanking(b, t)
	t = t or Treasury.Totals(b)
	if not (b and TreasurerPin(b.name)) then return t.ranking end
	local part, out = ns.Dues.DuesPart(Sums(b)), {}
	for _, g in ipairs(t.ranking) do
		local key = ns.Dues.Key(g.name)
		local take = key and math.min(g.money, part[key] or 0) or 0
		if key then part[key] = (part[key] or 0) - take end
		if g.money - take >= 1 then out[#out + 1] = { name = g.name, money = g.money - take } end
	end
	table.sort(out, function(x, y)
		if x.money ~= y.money then return x.money > y.money end
		return x.name < y.name
	end)
	return out
end
Treasury.PublicRanking = PublicRanking

---------------------------------------------------------------------------
-- Sharing: each keeper's book, and everyone's copy of them
---------------------------------------------------------------------------

-- Each keeper's yes (0.9.3's Treasurer's, now every keeper's, the King's too): his book and the
-- guild bank go out only once he chose to share them (ns.db.keeperShares[character], nil until
-- he answers; the Treasurer's 0.9.3 answer, ns.db.treasurerShares, stays his). They go on the
-- Sylvanistas channel, where every client receives the bytes; the addon shows them to the King,
-- and to the army only with the King's switches. Turned off, his book is withdrawn (TX) from
-- every screen at once.
local function ConsentKey() return OwnKey(ns.me or "") end
function Treasury.Consent()
	local shares, k = ns.db and ns.db.keeperShares, nil
	if type(shares) == "table" then k = shares[ConsentKey()] end
	if k ~= nil then return k end
	if ns.db and ns.IsMember() and ns.IsTreasurer(ns.me, GetGuildInfo("player")) then return ns.db.treasurerShares end
	return nil
end

-- His answer to 1.0's question alone (true, false, or nil while he gave none): what his line on
-- the first-open page waits for (1.1, Consent.lua: it shows Consent, what goes out now), and
-- AskConsent too.
function Treasury.ConsentAnswer()
	local shares = ns.db and ns.db.keeperShares
	if type(shares) ~= "table" then return nil end
	return shares[ConsentKey()]
end

-- Only a real keeper's client sends (never the author's view), and only with his yes.
local function CanSend() return RealKeeper() and Treasury.Consent() == true end
Treasury.CanSend = CanSend

function Treasury.SetConsent(on)
	if not RealKeeper() then return ns.Print(L.TREASURER_ONLY) end
	ns.db.keeperShares = type(ns.db.keeperShares) == "table" and ns.db.keeperShares or {}
	ns.db.keeperShares[ConsentKey()] = on and true or false
	if ns.IsTreasurer(ns.me, GetGuildInfo("player")) then ns.db.treasurerShares = on and true or false end
	ns.Print(on and L.TREASURER_SHARE_ON or L.TREASURER_SHARE_OFF)
	if on then
		Treasury.Share(true)
		if ns.Bank and ns.Bank.Share then ns.Bank.Share(true) end
	else
		Treasury.Withdraw(true)
	end
	ns.Fire("TREASURY_CHANGED")
end

-- His no withdraws his book (and his copy of the bank) from every screen: at once when he says
-- it, then again as his book would go out (Share: after login, and every SHARE_EVERY while he
-- plays), for as long as his no stands (it is kept: ns.db.keeperShares). Konig's review of
-- 1.0.0: said once, it never reached a client that was offline then, which kept showing his
-- book (a keeper's book never runs out while he is one).
local lastWithdraw = -math.huge
function Treasury.Withdraw(force)
	if not RealKeeper() or Treasury.Consent() ~= false then return false end
	local now = ns.Now()
	if not force and now - lastWithdraw < Treasury.SHARE_EVERY then return false end
	lastWithdraw = now
	ns.Comm.Send("CHANNEL", "TX~" .. (GetGuildInfo("player") or ""), "treasury")
	return true
end

-- The keepers' books as they reached us: { [Name-Realm] = report }.
local function Reports()
	if type(ns.rdb.treasuryReports) ~= "table" then ns.rdb.treasuryReports = {} end
	return ns.rdb.treasuryReports
end

-- A keeper withdrew his book (and his copy of the bank): gone from our screen (his word, his
-- name). The Treasurer withdraws his mail character's too, when it keeps it private and he has
-- passed it on (TR): that character may never reach the channel itself.
function Treasury.HandleWithdraw(dist, sender, text)
	if dist ~= "CHANNEL" or type(text) ~= "string" then return end
	local guild, whose = text:match("^TX~([^~]*)~([^~]+)$")
	if whose then
		if not (not ns.TREASURY_OFF and ns.IsTreasurer(sender, guild) and ns.IsTreasurerMail(whose)) then return end
		sender = whose
	else
		guild = text:match("^TX~(.*)$")
		if not guild or not Treasury.IsKeeperName(sender, guild) then return end
	end
	Treasury.Migrate()
	local reports = Reports()
	local gone = {}
	for from in pairs(reports) do if SameChar(from, sender) then gone[#gone + 1] = from end end
	for _, from in ipairs(gone) do reports[from] = nil end
	local bank = ns.rdb.bankReport
	if type(bank) == "table" and SameChar(bank.by, sender) then ns.rdb.bankReport = nil end
	ns.Fire("TREASURY_CHANGED")
	ns.Fire("DATA_CHANGED")
end
ns.Comm.Handle("TX", function(...) Treasury.HandleWithdraw(...) end)

-- Asked once a session until he answers: what goes out and who reads it is in the question.
local asked = false
StaticPopupDialogs["SYLVANISTAS_TREASURER_SHARE"] = {
	text = L.TREASURER_SHARE_ASK,
	button1 = L.TREASURER_SHARE_YES,
	button2 = L.TREASURER_SHARE_NO,
	OnAccept = function() ns.SafeCall("treasurer share", Treasury.SetConsent, true) end,
	OnCancel = function(_, _, reason)
		if reason == "clicked" then ns.SafeCall("treasurer share", Treasury.SetConsent, false) end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	noCancelOnEscape = true, -- Escape is no answer: asked again next session
	preferredIndex = 3,
}
-- Asked while he has given no answer to 1.0's question: the Treasurer too while only his 0.9.3
-- answer stands (1.0's also covers the early supporters' names: TreasurerYes).
function Treasury.AskConsent()
	local shares = ns.db and ns.db.keeperShares
	if asked or not RealKeeper() or (type(shares) == "table" and shares[ConsentKey()] ~= nil) then return false end
	if (InCombatLockdown and InCombatLockdown()) or (IsInInstance and IsInInstance()) then return false end
	-- 1.1 (#11): in a Sylvanistas guild the first-open page is the first question, this one on it
	-- in the same words (once a session there). This popup only while Consent.lua is not loaded
	-- (updated without a restart), and for a keeper outside a guild (the page asks members).
	if ns.Consent and not ns.Consent.missing and ns.IsMember() then return ns.Consent.Ask("treasurer") == true end
	asked = true
	ns.ShowDialog("SYLVANISTAS_TREASURER_SHARE", ns.Comm.Audience and ns.Comm.Audience() or "")
	return true
end

local function Clean(name) return (tostring(name or ""):gsub("[~:,|@/%c]", "")) end
local function U(n) return math.max(0, math.min(math.floor(tonumber(n) or 0), Treasury.MAX_COPPER)) end
local function S(n) return math.max(-Treasury.MAX_COPPER, math.min(math.floor(tonumber(n) or 0), Treasury.MAX_COPPER)) end

-- A line's letter in the message: i a donation, o a payment, r and s a transfer received and sent.
local function LineCode(e)
	if e.kind == "transfer" then return e.out and "s" or "r" end
	return e.out and "o" or "i"
end

-- The King's word as this client last heard it, with its time.
local function FlagsWord()
	local f = ns.rdb.treasuryFlags
	return type(f) == "table" and tonumber(f.at) and (FlagDigits(f) .. "@" .. math.floor(f.at)) or "-"
end

-- A date as a book sends it (Konig's review of 1.0.0). The lines are dated by this PC's clock
-- (ns.Now), and every client refuses a book with a date before FIRST_DAY or more than
-- DATE_SLACK ahead of the server's clock (ReadBook): so a date past the server's clock goes out
-- as the server's now, and one before FIRST_DAY as FIRST_DAY. A keeper whose PC clock is wrong,
-- or was when a line was written, still has his book taken; his own screen keeps his dates. An
-- item's 0 (`unknown`: its donor's line gone) stays 0.
local function SentDate(t, unknown)
	t = math.floor(tonumber(t) or 0)
	if unknown and t == 0 then return 0 end
	return math.max(Treasury.FIRST_DAY, math.min(t, math.floor(Clock())))
end

-- This keeper's book as it goes out (TB), each list cut until it fits Treasury.ROOM.
-- parts (1.1): the army's part alone, as it goes on the channel ({ balance, ranking, book }, what
-- the King's switches show: PublicParts); nil: the whole book, as it goes by whisper to the King,
-- his Stewards and the keepers. A part left out is empty in it, and its totals are then the sums
-- of what it shows (a 1.0 client checks them, and so still takes it): the balance's numbers (the
-- opening, the balance, the totals, the week, the transfers) with "balance", the ranking with
-- "ranking", the book's lines and the items donated with "book". Its keepers' field (read by
-- nobody before 1.1) says which parts it holds: "<balance><ranking><book>@1", "110@1".
-- A 1.0 client takes it as that keeper's whole book: its army shows what the King shows, as
-- before, and the King's switches still reach it from the Treasurer's copy, which 1.0 reads (and
-- which also takes the place of any whole book of 1.0 it kept). But a King's, Steward's or
-- keeper's 1.0 addon, which
-- shows everything whatever the switches, shows a balance of zero there with the balance hidden
-- (every switch off, as the King starts) or the sums of the lists shown, until it updates: 1.1
-- whispers the whole book to 1.1 alone. A 1.1 insider's Treasury tab names them
-- (Treasury.NotUpdated), so they can be told.
function Treasury.Message(b, parts)
	b = b or BookOf(ns.me, true)
	local t = Treasury.Totals(b)
	local whole = parts == nil
	local showBalance, showRanking, showBook = whole or parts.balance == true, whole or parts.ranking == true, whole or parts.book == true
	-- The King's switches ride the Treasurer's book alone (not a book of his mail character's he
	-- passes on), for 1.0's addons, which read them there; 1.1 reads them from nobody's book
	-- (Konig's review of 1.1: TakeFlags). His keepers never do: they are the King's and his
	-- Stewards' to set, from their own clients (Konig's review of 1.0.0), and the field stays "-"
	-- (1.1: on the channel, the parts the book holds).
	local mine = ns.IsTreasurer(ns.me, GetGuildInfo("player") or "") and SameChar(b.name or ns.me, ns.me)
	local flags = mine and FlagsWord() or "-"
	local keepers = whole and "-" or ((showBalance and "1" or "0") .. (showRanking and "1" or "0") .. (showBook and "1" or "0") .. "@1")
	local caps = { rank = Treasury.RANK_SENT, book = Treasury.BOOK_SENT, items = Treasury.ITEMS_SENT }
	-- (1.1, Konig's review: never what may be someone's dues in the Treasurer's ranking.)
	local ranking = PublicRanking(b, t)
	local function Build()
		-- 1.1 (Fern's #36): the week's donors go out as a count, never by name. With the dues (one
		-- fixed amount a week, Dues.lua) their names on the channel would be a public list of who
		-- paid this week, and so of who did not: every client on it receives the bytes, whatever the
		-- King's switches show. The ranking (all time, which Fern kept) stays, less what may be each
		-- giver's dues in the Treasurer's (PublicRanking); so do the book's latest lines, except the
		-- gold given to the Treasurer's characters: each of those is someone's dues (a name and his
		-- last payment: DuesLine), and never goes out.
		local week, rank, lines, items = {}, {}, {}, {}
		local sums = { rank = 0, i = 0, o = 0, r = 0, s = 0 }
		if showRanking then
			for i = 1, math.min(caps.rank, #ranking) do
				rank[i] = ("%s:%d"):format(Clean(ranking[i].name), U(ranking[i].money))
				sums.rank = sums.rank + U(ranking[i].money)
			end
		end
		for i = #b.lines, 1, -1 do
			if not showBook or #lines >= caps.book then break end
			local e = b.lines[i]
			-- Counted lines and transfers; what he said was his (a sale, his own) stays home.
			if not e.excluded and not DuesLine(b.name or ns.me, e) then
				local code = LineCode(e)
				local line = ("%s:%d:%s:%s:%d"):format(code, U(e.money), Clean(e.name), e.how == "mail" and "m" or "t", SentDate(e.t))
				if e.item then line = line .. (":%d:%d"):format(e.item, math.min(tonumber(e.count) or 1, Treasury.MAX_COUNT)) end
				lines[#lines + 1] = line
				sums[code] = sums[code] + U(e.money)
			end
		end
		for i = 1, showBook and math.min(caps.items, #t.items) or 0 do
			local it = t.items[i]
			local last = it.donors[1]
			items[i] = ("%d:%d:%d:%s"):format(it.id, math.min(it.n, Treasury.MAX_COUNT), SentDate(it.t, true), Clean(last and last.name or ""))
		end
		local opening, allIn, allOut, weekIn, donors, tin, tout = U(Treasury.Opening(b)), U(t.allIn), U(t.allOut), U(t.weekIn), math.min(#t.givers, 9999), U(t.transIn), U(t.transOut)
		if not showBalance then
			-- Hidden: none of the balance's numbers, only the sums of the lists it shows.
			opening, weekIn, donors = 0, 0, 0
			allIn, allOut, tin, tout = U(math.max(sums.rank, sums.i)), U(sums.o), U(sums.r), U(sums.s)
		end
		local balance = showBalance and S(Treasury.Balance(b)) or S(opening + allIn - allOut + tin - tout)
		return ("TB~%s~%s~%d~%d~%d~%d~%d~%d~%s~%s~%s~%s~%s~%s~%d:%d"):format(Treasury.EPOCH, Clean(GetGuildInfo("player")), opening,
			balance, allIn, allOut, weekIn, donors, table.concat(week, ","), flags, keepers,
			table.concat(rank, ","), table.concat(lines, ","), table.concat(items, ","), tin, tout)
	end
	-- Too long (it is rare): items first, then the ranking's tail, then lines of the book; the top
	-- 25 donors last of all.
	local STEPS = { { "items", 10, 5 }, { "rank", 50, 10 }, { "book", 5, 5 }, { "rank", 25, 5 }, { "items", 5, 5 }, { "rank", 0, 5 } }
	local msg = Build()
	while #msg > Treasury.ROOM do
		local step
		for _, s in ipairs(STEPS) do if caps[s[1]] > s[2] then step = s break end end
		if not step then break end
		caps[step[1]] = math.max(step[2], caps[step[1]] - step[3])
		msg = Build()
	end
	return msg
end

-- 0.9's treasury (T8), for 0.9 clients (they read it from the Treasurer alone): the treasury
-- of 1.0 as his client puts it together, short. 1.0 clients never read it. parts (1.1): it goes
-- on the channel, so only what the King's switches show (Treasury.Message): a part hidden is
-- zero or empty in it.
function Treasury.LegacyMessage(parts)
	local r = Treasury.Report(true)
	if not r then return nil end
	parts = parts or { balance = true, ranking = true, book = true }
	local rank, lines = {}, {}
	for i = 1, parts.ranking and math.min(Treasury.LEGACY_RANK, #r.rank) or 0 do rank[i] = ("%s:%d"):format(Clean(r.rank[i].name), U(r.rank[i].money)) end
	for _, w in ipairs(parts.book and r.book or {}) do
		if #lines >= Treasury.LEGACY_BOOK then break end
		local e = w.e
		-- (1.1: never a line of someone's dues, as in TB: DuesLine.)
		if not e.item and not e.excluded and e.kind ~= "transfer" and not DuesLine(w.keeper, e) then
			lines[#lines + 1] = ("%s:%d:%s:%s:%d"):format(e.out and "o" or "i", U(e.money), Clean(e.name), e.how == "mail" and "m" or "t", math.floor(tonumber(e.t) or 0))
		end
	end
	local b = parts.balance
	return ("T8~%s~%d~%d~%d~%d~%d~%s~%s~%s"):format(Clean(GetGuildInfo("player")), b and S(r.balance) or 0, b and U(r.allIn) or 0, b and U(r.allOut) or 0,
		b and U(r.week) or 0, b and math.min(r.donors, 9999) or 0, FlagsWord(), table.concat(rank, ","), table.concat(lines, ","))
end

local function Send(msg, key)
	if not msg then return end
	if #msg <= 250 then ns.Comm.Send("CHANNEL", msg, key) else ns.Comm.SendChunked(msg) end
end

function Treasury.Share(force)
	if not CanSend() then
		-- Kept private: his no goes out instead, as often as his book would (and the Treasurer's
		-- client passes on his mail character's no, whatever his own answer).
		Treasury.Withdraw()
		Treasury.Relay()
		return
	end
	local now = ns.Now()
	-- A change inside the gap goes out once the gap is over, not never.
	if not force and now - lastShare < Treasury.SHARE_GAP then
		if not sharePending then
			sharePending = true
			ns.After(lastShare + Treasury.SHARE_GAP - now, "treasury share", function()
				sharePending = false
				Treasury.Share(true)
			end)
		end
		return
	end
	lastShare = now
	Treasury.OpenBook()
	-- On the channel the army's part alone (1.1); the whole book by whisper to the King, his
	-- Stewards and the keepers heard online (none of it while the switches show all of it).
	local parts, all = Treasury.PublicParts()
	if ns.IsTreasurer(ns.me, GetGuildInfo("player")) then Send(Treasury.LegacyMessage(parts), "treasury8") end
	Send(Treasury.Message(nil, not all and parts or nil), "treasury")
	Treasury.Relay()
	Treasury.SendPrivate()
	-- (1.1: the open bank requests next to the bank, while the King shows it: Bank.lua.)
	if ns.Bank and ns.Bank.SharePublic then ns.Bank.SharePublic(force) end
end

-- The Treasurer's client passes on the book of his mail character kept on his account (TR),
-- once after login and every RELAY_EVERY (it changes only while that character plays): an
-- account plays one character at a time, and outside a Sylvanistas guild the addon sends nothing,
-- so a mail character in another guild or none never sends its own. That character's own yes
-- counts: kept private, its book is withdrawn instead (TX with its name), repeated as often,
-- whether the Treasurer shares his own book or not (1.0.0). The time is when that book last
-- changed (as a book sends a date: SentDate): a copy as new (its own TB, heard when it came) stays.
-- The mail character's book as the Treasurer's client passes it on: TR, its date, its book
-- (parts: the army's part alone, for the channel; nil: whole, by whisper).
function Treasury.RelayMessage(b, parts)
	return ("TR~%s~%d~"):format(Clean(b.name), SentDate(BookTime(b))) .. Treasury.Message(b, parts)
end
-- The books the Treasurer's client passes on whole by whisper (1.1): his mail character's, kept on
-- his account, with its yes and his.
function Treasury.RelayedBooks()
	local out = {}
	if not RealKeeper() or not ns.IsTreasurer(ns.me, GetGuildInfo("player")) or not CanSend() then return out end
	local shares = type(ns.db.keeperShares) == "table" and ns.db.keeperShares or {}
	for key, b in pairs(Books()) do
		if type(b) == "table" and b.epoch == Treasury.EPOCH and b.opening ~= nil and type(b.lines) == "table"
			and ns.IsTreasurerMail(b.name) and Treasury.IsOwnCharacter(b.name) and shares[key] == true then
			out[#out + 1] = b
		end
	end
	return out
end

function Treasury.Relay(force)
	if not RealKeeper() or not ns.IsTreasurer(ns.me, GetGuildInfo("player")) then return end
	local now = ns.Now()
	if not force and now - lastRelay < Treasury.RELAY_EVERY then return end
	lastRelay = now
	local shares = type(ns.db.keeperShares) == "table" and ns.db.keeperShares or {}
	local parts, all = Treasury.PublicParts()
	for key, b in pairs(Books()) do
		if type(b) == "table" and b.epoch == Treasury.EPOCH and b.opening ~= nil and type(b.lines) == "table"
			and ns.IsTreasurerMail(b.name) and Treasury.IsOwnCharacter(b.name) then
			-- Its book with his yes too (his client sends it); its no with or without his. On the
			-- channel the army's part alone (1.1), the whole of it by whisper (SendPrivate).
			if shares[key] == true and CanSend() then
				Send(Treasury.RelayMessage(b, not all and parts or nil))
			elseif shares[key] == false then
				ns.Comm.Send("CHANNEL", ("TX~%s~%s"):format(Clean(GetGuildInfo("player")), Clean(b.name)), "treasuryx " .. key)
			end
		end
	end
end

-- A number as a book writes it: digits alone, `max` at most (Treasury.MAX_COPPER unless said,
-- the most an honest client ever writes); nil otherwise.
local function Amount(s, max)
	if type(s) ~= "string" or #s > 12 or not s:match("^%d+$") then return nil end
	local n = tonumber(s)
	return n <= (max or Treasury.MAX_COPPER) and n or nil
end
-- A list's entries, empty ones too (an honest client writes none): {} for an empty list.
local function Entries(s)
	local out = {}
	if s == "" then return out end
	for e in (s .. ","):gmatch("([^,]*),") do out[#out + 1] = e end
	return out
end

-- A book (TB) as it came, of this era, as of `t`, checked (Konig's review of 1.0.0: it was
-- taken as it came, its numbers clamped and its lists cut). An honest client never sends one
-- that fails (its dates too, whatever his PC's clock says: SentDate), so one that fails is
-- refused whole (nil and why; our copy of that keeper's book stays):
--   its shape: 16 fields, digits where the numbers go, each entry of its list's shape;
--   its sizes: Treasury.ROOM in all, each list no longer than a book sends, amounts within
--     MAX_COPPER and items within MAX_COUNT;
--   its dates: none before FIRST_DAY, none more than DATE_SLACK ahead of the server's clock (a
--     keeper's clock a little ahead: taken as of now), an item's 0 where its donor's line is gone;
--   its sums: the balance is its opening, plus all in, less all out, plus the transfers in, less
--     the transfers out; the week no more than all in; no more donors named than counted; the
--     ranking in its order, each donor more than nothing, worth no more than all in; the lines
--     of each kind worth no more than its total (a total at MAX_COPPER, clamped, proves nothing).
-- What can't be a name is left out (the names reach the King's stream), nothing else. nil, nil
-- for another era's book (0.9's, a later reset's): never merged with ours. Returns r, f.
Treasury.FIRST_DAY = 1767225600  -- 2026-01-01 00:00 UTC: no line of a 1.0 book is older
Treasury.DATE_SLACK = 86400      -- a keeper's clock may run a day ahead of the server's
local function ReadBook(text, from, t)
	if type(text) ~= "string" or text:sub(1, 3) ~= "TB~" then return nil, "not a book" end
	if #text > Treasury.ROOM then return nil, "longer than a book is sent" end
	local f = {}
	for field in (text .. "~"):gmatch("([^~]*)~") do f[#f + 1] = field end
	if f[2] ~= Treasury.EPOCH then return nil, nil end
	if #f ~= 16 then return nil, ("%d fields"):format(#f) end
	local MAX = Treasury.MAX_COPPER
	local opening, allIn, allOut, week, donors = Amount(f[4]), Amount(f[6]), Amount(f[7]), Amount(f[8]), Amount(f[9], 9999)
	local balance = f[5]:match("^%-?%d+$") and #f[5] <= 12 and tonumber(f[5]) or nil
	local tin, tout = f[16]:match("^(%d+):(%d+)$")
	tin, tout = Amount(tin), Amount(tout)
	if not (opening and allIn and allOut and week and donors and balance and tin and tout) or math.abs(balance) > MAX then
		return nil, "its numbers"
	end
	if f[11] ~= "-" and not f[11]:match("^[01][01][01]@%d+$") then return nil, "its switches" end
	-- (The keepers' field is read from nobody's book: "-", or the shape 1.0.0 builds before
	-- Konig's review wrote.)
	if f[12] ~= "-" and not f[12]:match("^%d+@") then return nil, "its keepers' field" end
	local clock, now = Clock(), ns.Now()
	local function When(s, unknown)
		local n = Amount(s, math.huge)
		if n == 0 and unknown then return 0 end
		if not n or n < Treasury.FIRST_DAY or n > clock + Treasury.DATE_SLACK then return nil end
		return math.min(n, now)
	end
	local function Within(sum, total) return total >= MAX or sum <= total end
	local r = { epoch = f[2], guild = f[3], from = from, t = t, opening = opening, balance = balance, allIn = allIn, allOut = allOut,
		week = week, donors = donors, transIn = tin, transOut = tout, weekNames = {}, rank = {}, book = {}, items = {} }
	-- 1.1: the army's part alone (the channel's copy), and which parts it holds.
	local pb, pr, pk = f[12]:match("^([01])([01])([01])@1$")
	if pb then r.part = { balance = pb == "1", ranking = pr == "1", book = pk == "1" } end
	-- The sums.
	local expected = opening + allIn - allOut + tin - tout
	local clamped = allIn >= MAX or allOut >= MAX or tin >= MAX or tout >= MAX or math.abs(expected) >= MAX
	if not clamped and balance ~= expected then return nil, "a balance its totals don't add up to" end
	if not Within(week, allIn) then return nil, "a week over all time" end
	-- The week's donors.
	local entries = Entries(f[10])
	if #entries > Treasury.WEEK_SENT or #entries > donors then return nil, "the week's donors" end
	for _, name in ipairs(entries) do
		if name == "" then return nil, "the week's donors" end
		local clean = ns.King.CleanName(name)
		if clean then r.weekNames[#r.weekNames + 1] = clean end
	end
	-- The ranking.
	entries = Entries(f[13])
	if #entries > Treasury.RANK_SENT then return nil, "a ranking longer than a book sends" end
	local sum, last = 0, math.huge
	for _, e in ipairs(entries) do
		local name, copper = e:match("^([^:]*):(%d+)$")
		copper = Amount(copper)
		if not copper or copper < 1 or copper > last then return nil, "the ranking" end
		last, sum = copper, sum + copper
		local clean = ns.King.CleanName(name)
		if clean then r.rank[#r.rank + 1] = { name = clean, money = copper } end
	end
	if not Within(sum, allIn) then return nil, "a ranking over all in" end
	-- The book's lines.
	entries = Entries(f[14])
	if #entries > Treasury.BOOK_SENT then return nil, "more lines than a book sends" end
	local sums = { i = 0, o = 0, r = 0, s = 0 }
	for _, e in ipairs(entries) do
		local kind, copper, name, how, when, rest = e:match("^([iors]):(%d+):([^:]*):([mt]):(%d+)(.*)$")
		local item, count
		if rest and rest ~= "" then
			item, count = rest:match("^:(%d+):(%d+)$")
			item, count = Amount(item), Amount(count, Treasury.MAX_COUNT)
			if not (item and item > 0 and count and count > 0) then return nil, "a line's item" end
		end
		copper, when = Amount(copper), When(when)
		if not (kind and copper and when) or (item and copper ~= 0) or (not item and copper < 1) then return nil, "a line" end
		sums[kind] = sums[kind] + copper
		local clean = ns.King.CleanName(name)
		if clean then
			r.book[#r.book + 1] = { out = (kind == "o" or kind == "s") or nil, kind = (kind == "r" or kind == "s") and "transfer" or nil,
				money = copper, name = clean, how = how == "m" and "mail" or "trade", t = when, item = item, count = count }
		end
	end
	if not (Within(sums.i, allIn) and Within(sums.o, allOut) and Within(sums.r, tin) and Within(sums.s, tout)) then
		return nil, "lines over their totals"
	end
	-- The items donated.
	entries = Entries(f[15])
	if #entries > Treasury.ITEMS_SENT then return nil, "more items than a book sends" end
	for _, e in ipairs(entries) do
		local id, n, when, name = e:match("^(%d+):(%d+):(%d+):([^:]*)$")
		id, n, when = Amount(id), Amount(n, Treasury.MAX_COUNT), When(when, true)
		if not (id and id > 0 and n and n > 0 and when) then return nil, "an item" end
		local clean = ns.King.CleanName(name)
		r.items[#r.items + 1] = { id = id, n = n, t = when, donors = clean and { { name = clean, t = when } } or {} }
	end
	return r, f
end

-- Our copy of a keeper's book, in place of the one we had of that character (however its name
-- was written). 1.1: on the King's, a Steward's or a keeper's client the army's part (the
-- channel's copy, r.part) never replaces a whole copy of that book (a whisper's, or a 1.0
-- keeper's): the whole one stays until the next whole one comes. Returns whether it was kept.
local function Keep(r)
	local reports, gone = Reports(), {}
	if r.part and Treasury.IsInsider() then
		for from, old in pairs(reports) do
			if SameChar(from, r.from) and type(old) == "table" and not old.part then return false end
		end
	end
	for from in pairs(reports) do if from ~= r.from and SameChar(from, r.from) then gone[#gone + 1] = from end end
	for _, from in ipairs(gone) do reports[from] = nil end
	reports[r.from] = r
	return true
end

-- A keeper's book (TB): from a keeper himself (his name, which the server sets), of this era.
-- The King's keepers never from a book: the Treasurer's could name anyone a keeper, or take the
-- King's off, with a fresh date (Konig's review of 1.0.0); only the King and his Stewards set them
-- (T1~K). 1.1: nor his switches (Konig's review of 1.1: the same fresh date set them): the
-- Treasurer's copy is only answered when older than ours (TakeFlags).
-- 1.1: on the channel, or by whisper (put together from its pieces: Treasury.HandlePrivate),
-- whole, to the King, a Steward or a keeper.
function Treasury.HandleReport(dist, sender, text)
	if (dist ~= "CHANNEL" and dist ~= "WHISPER") or type(text) ~= "string" then return end
	local r, f = ReadBook(text, ns.FullName(sender), ns.Now())
	if not r then
		if f then ns.Log("treasury book from %s refused: %s", tostring(sender), f) end
		return
	end
	local guild = r.guild
	if not Treasury.IsKeeperName(sender, guild) then
		ns.Log("treasury book from %s (%s) ignored: not a keeper", tostring(sender), tostring(guild))
		return
	end
	-- (A whispered book is whole, and only for the King, a Steward or a keeper.)
	if dist == "WHISPER" and (r.part or not Treasury.IsInsider()) then return end
	Treasury.Heard(sender)
	Treasury.Migrate()
	Keep(r)
	-- The Treasurer's copy of the King's switches (for 1.0's addons): never taken, answered by the
	-- King's or a Steward's client when older than theirs (TakeFlags, relayed).
	if ns.IsTreasurer(sender, guild) then
		local b, k, o, at = f[11]:match("^([01])([01])([01])@(%d+)$")
		if b then Treasury.TakeFlags(b .. k .. o, tonumber(at), sender, true) end
	end
	ns.Fire("TREASURY_CHANGED")
	ns.Fire("DATA_CHANGED") -- the tab may appear
end
ns.Comm.Handle("TB", function(...) Treasury.HandleReport(...) end)

-- His mail character's book as the Treasurer's client passes it on (TR): from the Treasurer
-- himself (his name, set by the server, in <Sylvanistas>), about his mail character alone, of this
-- era; taken unless our copy of that book is as new (its own TB, dated when it came, always is).
-- The book is checked as a keeper's own is (ReadBook), and its date too: DATE_SLACK ahead of the
-- server's clock at most (Konig's review of 1.0.0).
function Treasury.HandleRelay(dist, sender, text)
	if (dist ~= "CHANNEL" and dist ~= "WHISPER") or type(text) ~= "string" or ns.TREASURY_OFF then return end
	local whose, at, book = text:match("^TR~([^~]+)~(%d+)~(TB~.*)$")
	if not whose then return end
	whose = ns.FullName(whose)
	at = Amount(at, math.huge)
	if not at or at > Clock() + Treasury.DATE_SLACK then
		return ns.Log("treasury relay from %s refused: its date", tostring(sender))
	end
	local r, why = ReadBook(book, whose, math.min(at, ns.Now()))
	if not r then
		if why then ns.Log("treasury relay from %s refused: %s", tostring(sender), why) end
		return
	end
	if not ns.IsTreasurer(sender, r.guild) or not ns.IsTreasurerMail(whose) then return end
	-- (1.1: whispered, whole, to the King, a Steward or a keeper; a whole copy as new as the army's
	-- part we hold takes its place.)
	if dist == "WHISPER" and (r.part or not Treasury.IsInsider()) then return end
	Treasury.Migrate()
	for from, old in pairs(Reports()) do
		if SameChar(from, whose) and type(old) == "table" and (tonumber(old.t) or 0) >= r.t and (r.part or not old.part) then return end
	end
	r.relayed = true
	Keep(r)
	ns.Fire("TREASURY_CHANGED")
	ns.Fire("DATA_CHANGED")
end
ns.Comm.Handle("TR", function(...) Treasury.HandleRelay(...) end)
-- 0.9's treasury (a 0.9 Treasurer's old book): heard, never read (1.0 starts afresh).
ns.Comm.Handle("T8", function() end)

-- Each keeper's part of the treasury: this keeper's own book (or the author's view's), the
-- books of this account's other keeper characters as this client keeps them (an account plays
-- one character at a time: theirs never reach it by the channel), and every other keeper's
-- book as it last reached us. A keeper's book stays while he is one, however old (it says
-- when it came); a character no longer on the King's list is no longer counted.
-- public: its ranking as it leaves this client (PublicRanking), never its whole one.
local function LivePart(b, own, public)
	local t = Treasury.Totals(b)
	local names, lines = {}, {}
	for i = 1, math.min(Treasury.WEEK_SENT, #t.givers) do names[i] = t.givers[i].name end
	for i = #b.lines, 1, -1 do
		local e = b.lines[i]
		if own or not e.excluded then lines[#lines + 1] = e end
	end
	-- (Ours is as of now; another character's of this account, as of its latest change.)
	local when = own and ns.Now() or BookTime(b)
	return { name = b.name, opening = Treasury.Opening(b), balance = Treasury.Balance(b), allIn = t.allIn, allOut = t.allOut, week = t.weekIn,
		donors = #t.givers, weekNames = names, rank = public and PublicRanking(b, t) or t.ranking, book = lines, items = t.items, t = when, own = own, b = b }
end
-- Another character of this account said yes to sharing its book (the Treasurer's 0.9.3 yes is his,
-- while he has given no answer since: his no of 1.0 stays a no).
local function SharesBook(key, name)
	local shares, yes = ns.db and ns.db.keeperShares, nil
	if type(shares) == "table" then yes = shares[key] end
	if yes ~= nil then return yes == true end
	return TreasurerPin(name) == 1 and ns.db.treasurerShares == true
end
-- shared: the treasury as it may go out (0.9's T8): a book of another character of this account
-- only with that character's yes. public (and shared): each of this account's books ranks as it
-- leaves this client (PublicRanking: the Discord copy, the review of Konig's fixes, 1.1).
local function Parts(shared, public)
	public = shared or public
	local parts, seen = {}, {}
	if not ns.rdb then return parts end
	if Treasury.IsKeeper() then
		local b = BookOf(ns.me, true)
		parts[1], seen[OwnKey(ns.me)] = LivePart(b, true, public), true
	end
	for key, b in pairs(Books()) do
		if not seen[key] and type(b) == "table" and b.epoch == Treasury.EPOCH and type(b.lines) == "table" and Treasury.IsOwnCharacter(b.name)
			and Treasury.KeeperByName(b.name) then
			-- (Kept private: left out, and no copy of it either.)
			if not shared or SharesBook(key, b.name) then parts[#parts + 1] = LivePart(b, false, public) end
			seen[key] = true
		end
	end
	for from, r in pairs(Reports()) do
		local key = OwnKey(from)
		if not seen[key] and type(r) == "table" and r.epoch == Treasury.EPOCH and Treasury.IsKeeperName(from, r.guild) then
			seen[key] = true
			-- 1.1: the army's part alone (the channel's copy): the balance's numbers only when it
			-- holds them (without them its totals are the sums of its lists, never the balance).
			local nums = not r.part or r.part.balance
			parts[#parts + 1] = { name = from, opening = nums and r.opening or 0, balance = nums and r.balance or 0, allIn = nums and r.allIn or 0,
				allOut = nums and r.allOut or 0, week = nums and r.week or 0, donors = nums and r.donors or 0, weekNames = r.weekNames or {},
				rank = r.rank or {}, book = r.book or {}, items = r.items or {}, t = r.t or 0, part = r.part,
				transIn = nums and r.transIn or 0, transOut = nums and r.transOut or 0 }
		end
	end
	-- The Treasurer first, his mail character next, then the King, then the others by name.
	local function Rank(p)
		if not PinnedName(p.name) then return #ns.TREASURER_CHARACTERS + 2 end
		return TreasurerPin(p.name) or #ns.TREASURER_CHARACTERS + 1
	end
	table.sort(parts, function(x, y)
		local a, b = Rank(x), Rank(y)
		if a ~= b then return a < b end
		return tostring(x.name) < tostring(y.name)
	end)
	return parts
end

-- The treasury, all its keepers' books together, or nil while none reached us: the balance and
-- the totals summed, the week's donors counted once, the donors and the items one list each,
-- the book every keeper's lines by time ({ e = line, keeper = name, own = this keeper's, b }).
-- shared: as it may go out (Parts); public: every book it holds, each ranked as it leaves (Parts).
function Treasury.Report(shared, public)
	local parts = Parts(shared, public)
	if #parts == 0 then return nil end
	local m = { balance = 0, opening = 0, allIn = 0, allOut = 0, week = 0, donors = 0, rank = {}, book = {}, items = {}, keepers = {}, t = 0, parts = parts }
	local weekSeen, extra, byName, byItem = {}, 0, {}, {}
	for _, p in ipairs(parts) do
		m.balance, m.opening = m.balance + (p.balance or 0), m.opening + (p.opening or 0)
		m.allIn, m.allOut, m.week = m.allIn + (p.allIn or 0), m.allOut + (p.allOut or 0), m.week + (p.week or 0)
		-- (1.1: a player's linked characters, Alts.lua, are one donor under their main's name.)
		local Person = ns.Alts and ns.Alts.Person
		for _, n in ipairs(p.weekNames) do weekSeen[Person and Person(n) or ns.ShortName(n)] = true end
		extra = extra + math.max(0, (p.donors or 0) - #p.weekNames)
		for _, g in ipairs(p.rank) do
			local key = Person and Person(g.name) or ns.ShortName(g.name)
			local r = byName[key]
			if not r then
				r = { name = key, money = 0 }
				byName[key] = r
				m.rank[#m.rank + 1] = r
			end
			r.money = r.money + (g.money or 0)
		end
		for i, e in ipairs(p.book) do m.book[#m.book + 1] = { e = e, keeper = p.name, own = p.own, b = p.b, i = i } end
		for _, it in ipairs(p.items) do
			local x = byItem[it.id]
			if not x then
				x = { id = it.id, n = 0, donors = {}, t = 0 }
				byItem[it.id] = x
				m.items[#m.items + 1] = x
			end
			x.n = x.n + (it.n or 0)
			if (it.t or 0) > x.t then x.t = it.t end
			for _, d in ipairs(it.donors or {}) do x.donors[#x.donors + 1] = d end
		end
		m.keepers[#m.keepers + 1] = { name = p.name, t = p.t, balance = p.balance, own = p.own, part = p.part }
		if (p.t or 0) > m.t then m.t = p.t end
	end
	for _ in pairs(weekSeen) do m.donors = m.donors + 1 end
	m.donors = m.donors + extra
	m.balance = S(m.balance)
	local function Most(x, y)
		if x.money ~= y.money then return x.money > y.money end
		return x.name < y.name
	end
	table.sort(m.rank, Most)
	-- Newest first; a keeper's lines of one second in his book's order.
	table.sort(m.book, function(x, y)
		local a, b = tonumber(x.e.t) or 0, tonumber(y.e.t) or 0
		if a ~= b then return a > b end
		if x.keeper ~= y.keeper then return tostring(x.keeper) < tostring(y.keeper) end
		return x.i < y.i
	end)
	for _, x in ipairs(m.items) do
		table.sort(x.donors, function(a, b) return (a.t or 0) > (b.t or 0) end)
		local keep, seen = {}, {}
		for _, d in ipairs(x.donors) do
			local key = ns.ShortName(d.name)
			if not seen[key] and #keep < 3 then seen[key] = true keep[#keep + 1] = d end
		end
		x.donors = keep
	end
	table.sort(m.items, function(x, y)
		if x.n ~= y.n then return x.n > y.n end
		return x.id < y.id
	end)
	return m
end

---------------------------------------------------------------------------
-- 1.1: what the King's switches hide never goes on the channel (a promise made to a community
-- reviewer: "the parts Asmon hides won't be sent at all"). On the Sylvanistas channel, which anyone
-- can read, each keeper's book carries only what the army may see (Treasury.Message: the
-- balance, the ranking, the book, each with its switch); the guild bank goes there only with the
-- "book" switch (Bank.lua) and the early supporters only with the "ranking" one. The whole of it
-- goes by whisper, in pieces, to the King, his Stewards and the keepers alone, each one whose
-- addon was heard within AUDIENCE_FRESH (the server stamps a whisper's sender and delivers it to
-- that one character). GUILD is not used for it: it reaches every member of <Sylvanistas>, the army
-- too. With every switch on, the whole book goes on the channel as in 1.0, and nothing by whisper.
--   TA~<guild>~<0|1>   on the channel, from the King, a Steward or a keeper (a Hand too, for the
--                      sister guilds' banks, Bank.lua): "send me what is mine to see" (0: this
--                      client holds nothing yet, after a login; 1: what changed), ASK_AFTER after
--                      login and every ASK_EVERY; only its sender's name counts
--   TW~<type>~C<id>:<i>:<n>:<piece>   by whisper: a whole TB, TR or T9 (or a sister guild's bank,
--                      TS: Bank.lua) in pieces; put together by its receiver and read as if it
--                      came on the channel, from that sender
--   TE~...             by whisper too, piece by piece, the early supporters (as on the channel)
-- 1.0 clients leave TA and TW unread: a 1.0 army shows what the King shows, as before. Only a
-- client heard asking (TA: 1.1 or later) is whispered to, so a 1.0 King, Steward or keeper gets
-- nothing by whisper (what he reads from the channel: Treasury.Message's note).
-- The keeper's message budget: the whispers share the addon's one queue (Comm: a message each
-- 1.2 s, 60 waiting at most, the oldest dropped when it is full) with his census, his book on the
-- channel and everything else. So a piece is queued only while that queue is nearly empty
-- (PRIVATE_ROOM), and a changed message goes to the same player PRIVATE_GAP after the last one at
-- the soonest (the latest then: FlushPrivate, every minute); the channel's own messages are never
-- pushed out by ours.
---------------------------------------------------------------------------

Treasury.AUDIENCE_FRESH = 11 * 60  -- the King, a Steward or a keeper heard this recently is online
Treasury.ASK_AFTER = 40            -- seconds after login such a client asks for what is its to see...
Treasury.ASK_EVERY = 15 * 60       -- ...and again this often (what changed)
Treasury.RESET_GAP = 300           -- one player's "I hold nothing" is taken this often at most
Treasury.PRIVATE_PACE = 1.5        -- seconds between two whispered pieces at the least...
Treasury.PRIVATE_ROOM = 3          -- ...each one queued only while the addon's queue holds this many at most...
Treasury.PRIVATE_WAIT = 120        -- ...or once it waited this many turns (never held forever)
Treasury.PRIVATE_GAP = 180         -- a changed message to the same player this long after the last one at the soonest
Treasury.PRIVATE_QUEUE = 100       -- whole messages waiting to be whispered, at most
Treasury.READERS_FOR = 30 * 86400  -- a client heard asking (TA) is remembered as reading whispers this long
Treasury.PRIVATE_REPEAT = 1800     -- the same one whispered again to the same player this long after at most
                                   -- (a piece lost on the way, a wipe of his: he gets it whole again)

local heard = {}         -- [Name-Realm] = when the King, a Steward or a keeper was last heard
local firstHeard = {}    -- [Name-Realm] = when he was first heard this session
local outbox = {}        -- whispers waiting: { to, kind, key, msg, pieces }
local sending            -- the one going out now (its pieces, PRIVATE_PACE apart)
local sentTo = {}        -- [Name-Realm] = { [key] = { msg, at }: the message last whispered whole to him, when }
local resetAt = {}       -- [Name-Realm] = when his "I hold nothing" was last taken
local pieceId = 0
local privAsm = ns.Codec.NewAssembler()
local lastAsk = -math.huge
local privateKinds = {}  -- [type] = { from(sender), to(), handle(dist, sender, text) }
local held = false       -- a changed message was held back by PRIVATE_GAP: FlushPrivate sends it

-- The King's switches as he last gave them (never the author's Asmon's view): what goes on the
-- channel. Returns the parts, and whether all of them show (the whole book goes there then).
function Treasury.PublicParts()
	local f = ns.rdb and ns.rdb.treasuryFlags
	f = type(f) == "table" and f or {}
	local parts = { balance = f.balance == true, ranking = f.ranking == true, book = f.book == true }
	return parts, parts.balance and parts.ranking and parts.book
end
function Treasury.PublicShows(what) return (Treasury.PublicParts())[what] == true end

-- The King, a Steward, a keeper: who may hold the whole treasury (by the name the server stamps).
local function Insider(name)
	if type(name) ~= "string" or name == "" or ns.TREASURY_OFF then return false end
	return ns.IsKingCharacter(name) or ns.King.IsStewardName(name) or Treasury.KeeperByName(name)
end
Treasury.InsiderName = Insider
-- This client is the King's, a Steward's or a keeper's (never the author's views: nothing whole
-- is whispered to them).
function Treasury.IsInsider()
	if ns.TREASURY_OFF then return false end
	return ns.King.IsKing() or ns.King.IsSteward() or RealKeeper()
end

-- One of them was heard (any message of theirs: his book, his switches, his ask).
function Treasury.Heard(name)
	if not Insider(name) then return end
	name = ns.FullName(name)
	heard[name] = ns.Now()
	firstHeard[name] = firstHeard[name] or heard[name]
end

-- His addon reads whispers (TW, the bank requests): he was heard asking (TA), which 1.1 sends
-- and 1.0 never does. Kept on this realm's saved variables, so a /reload of ours does not wait
-- for his next ask (ASK_EVERY).
function Treasury.Reads(name)
	local r = type(name) == "string" and ns.rdb and type(ns.rdb.treasuryReaders) == "table" and ns.rdb.treasuryReaders[ns.FullName(name)]
	return type(r) == "number" and ns.Now() - r <= Treasury.READERS_FOR
end
function Treasury.MarkReader(name)
	if type(name) ~= "string" or not ns.rdb then return end
	local r = type(ns.rdb.treasuryReaders) == "table" and ns.rdb.treasuryReaders or {}
	ns.rdb.treasuryReaders = r
	local now = ns.Now()
	r[ns.FullName(name)] = now
	for n, t in pairs(r) do if type(t) ~= "number" or now - t > Treasury.READERS_FOR then r[n] = nil end end
end

-- The King, the Stewards and the keepers heard within AUDIENCE_FRESH whose addon never asked
-- (1.0: a 1.1 addon asks ASK_AFTER after its login), but us, sorted: while the King hides a part
-- of the treasury, their addon shows only what the army sees of the books of keepers on 1.1
-- (Treasury.Message), so a 1.1 insider's Treasury tab names them.
function Treasury.NotUpdated()
	local now, out = ns.Now(), {}
	for name, t in pairs(heard) do
		if now - t <= Treasury.AUDIENCE_FRESH and now - (firstHeard[name] or now) > Treasury.ASK_AFTER + 60
			and not SameChar(name, ns.me) and Insider(name) and not Treasury.Reads(name) then
			out[#out + 1] = name
		end
	end
	table.sort(out)
	return out
end

-- The King, the Stewards and the keepers heard within AUDIENCE_FRESH whose addon reads
-- whispers, but us, sorted.
function Treasury.Online()
	local now, out = ns.Now(), {}
	for name, t in pairs(heard) do
		if now - t <= Treasury.AUDIENCE_FRESH and not SameChar(name, ns.me) and Insider(name) and Treasury.Reads(name) then out[#out + 1] = name end
	end
	table.sort(out)
	return out
end

-- The next whisper waiting goes out, a piece every PRIVATE_PACE at the most, each one only
-- while the addon's queue is nearly empty (PRIVATE_ROOM).
local function PumpPrivate()
	-- (One whose timer never came back, an error on the way: not waited for forever.)
	if sending and ns.Now() - (sending.touched or 0) > 300 then sending = nil end
	if sending then return end
	local o = table.remove(outbox, 1)
	if not o then return end
	o.touched = ns.Now()
	if not o.pieces then
		pieceId = pieceId % 999 + 1
		o.pieces = {}
		for i, c in ipairs(ns.Codec.Chunk(o.msg, "w" .. pieceId)) do o.pieces[i] = "TW~" .. o.kind .. "~" .. c end
	end
	o.i = 0
	sending = o
	local waited = 0
	local function Next()
		if sending ~= o then return end
		o.touched = ns.Now()
		local size = ns.Comm.QueueSize and ns.Comm.QueueSize() or 0
		if size > Treasury.PRIVATE_ROOM and waited < Treasury.PRIVATE_WAIT then
			waited = waited + 1
			return ns.After(Treasury.PRIVATE_PACE, "treasury private", Next)
		end
		waited = 0
		o.i = o.i + 1
		ns.Comm.Whisper(o.to, o.pieces[o.i])
		if o.i < #o.pieces then return ns.After(Treasury.PRIVATE_PACE, "treasury private", Next) end
		sentTo[o.to] = sentTo[o.to] or {}
		sentTo[o.to][o.key] = { msg = o.msg, at = ns.Now() }
		sending = nil
		if outbox[1] then ns.After(Treasury.PRIVATE_PACE, "treasury private", PumpPrivate) end
	end
	Next()
end

-- A whole message (`kind`: its type) for one player alone, by whisper, in pieces; `pieces`: its
-- own messages instead (the early supporters'). Not again while he holds the same one (`key`,
-- the kind unless said): a changed one takes the place of the one still waiting, and is held
-- while the last one went to him less than PRIVATE_GAP ago (or is going now).
function Treasury.Private(to, kind, msg, key, pieces)
	if type(to) ~= "string" or to == "" or type(msg) ~= "string" or msg == "" then return false end
	to = ns.FullName(to)
	if SameChar(to, ns.me) then return false end
	key = key or kind
	local last = sentTo[to] and sentTo[to][key]
	if last and last.msg == msg and ns.Now() - last.at < Treasury.PRIVATE_REPEAT then return false end
	if sending and sending.to == to and sending.key == key and sending.msg == msg then return false end
	for _, o in ipairs(outbox) do
		if o.to == to and o.key == key then
			o.msg, o.pieces = msg, pieces
			return true
		end
	end
	local now = ns.Now()
	local recent = (sending and sending.to == to and sending.key == key) and now or (last and last.at)
	if recent and now - recent < Treasury.PRIVATE_GAP then
		held = true
		return false
	end
	if #outbox >= Treasury.PRIVATE_QUEUE then table.remove(outbox, 1) end
	outbox[#outbox + 1] = { to = to, kind = kind, key = key, msg = msg, pieces = pieces }
	PumpPrivate()
	return true
end

-- What PRIVATE_GAP held goes now, as it is now, where the gap is over (every minute: the
-- treasury's ticker); what is still inside it stays held.
function Treasury.FlushPrivate()
	if not held then return 0 end
	held = false
	local n = Treasury.SendPrivate()
	if ns.Bank and ns.Bank.ShareSister then n = n + ns.Bank.ShareSister() end
	return n
end

-- He holds none of `key` any more (his login): the next one goes to him even when unchanged.
function Treasury.ForgetSent(to, key)
	local t = type(to) == "string" and sentTo[ns.FullName(to)]
	if t then t[key] = nil end
end

-- What a keeper's client whispers to one of them (`to`), or to each one heard: his whole book
-- (and the Treasurer's mail character's), the bank and the early supporters, each one only
-- while a switch keeps a part of it off the channel. Only with his yes to sharing.
function Treasury.SendPrivate(to)
	if not CanSend() then return 0 end
	local parts, all = Treasury.PublicParts()
	local n = 0
	for _, name in ipairs(to and { to } or Treasury.Online()) do
		if not all then
			if Treasury.Private(name, "TB", Treasury.Message()) then n = n + 1 end
			for _, b in ipairs(Treasury.RelayedBooks()) do
				if Treasury.Private(name, "TR", Treasury.RelayMessage(b), "TR " .. OwnKey(b.name)) then n = n + 1 end
			end
		end
		if not parts.book and ns.Bank and ns.Bank.PrivateMessage then
			local bank = ns.Bank.PrivateMessage()
			if bank and Treasury.Private(name, "T9", bank) then n = n + 1 end
		end
		if not parts.ranking and Treasury.SendEarlyTo(name) then n = n + 1 end
	end
	return n
end

-- Pieces of a whisper put together (TW): only while this client may take that kind, from a
-- sender who may send it (each kind says who: Treasury.OnPrivate), then read as it would be on the
-- channel (dist "WHISPER"), the whole checked there again.
function Treasury.OnPrivate(kind, def) privateKinds[kind] = def end
function Treasury.HandlePrivate(dist, sender, text)
	if dist ~= "WHISPER" or type(text) ~= "string" then return end
	local kind, piece = text:match("^TW~(%w%w)~(C.+)$")
	local def = kind and privateKinds[kind]
	if not def or not def.to() or not def.from(sender) then return end
	local whole = ns.Codec.Feed(privAsm, sender, piece, ns.Now())
	if not whole or whole:sub(1, 3) ~= kind .. "~" then return end
	def.handle("WHISPER", sender, whole)
end
ns.Comm.Handle("TW", function(...) Treasury.HandlePrivate(...) end)
Treasury.OnPrivate("TB", { from = function(s) return Treasury.KeeperByName(s) end, to = function() return Treasury.IsInsider() end,
	handle = function(...) Treasury.HandleReport(...) end })
Treasury.OnPrivate("TR", { from = function(s) return TreasurerPin(s) == 1 end, to = function() return Treasury.IsInsider() end,
	handle = function(...) Treasury.HandleRelay(...) end })

-- This client asks for what is its to see (TA): the King's, a Steward's or a keeper's (a Hand's,
-- for the sister guilds' banks, Bank.lua). fresh: it holds nothing yet (a login).
function Treasury.Ask(fresh)
	if ns.TREASURY_OFF or not ns.rdb or not ns.IsMember() then return false end
	if not (Treasury.IsInsider() or (ns.Bank and ns.Bank.AsksSisters and ns.Bank.AsksSisters())) then return false end
	lastAsk = ns.Now()
	ns.Comm.Send("CHANNEL", ("TA~%s~%d"):format(Clean(GetGuildInfo("player")), fresh and 0 or 1), "treasuryask")
	return true
end
function Treasury.AskDue() return ns.Now() - lastAsk >= Treasury.ASK_EVERY end

-- Someone asks: the King, a Steward or a keeper gets what our client whispers (SendPrivate); a
-- sister guild's treasurer answers the King, a Steward or a Hand (Bank.lua). "I hold nothing"
-- (0) forgets what was whispered to him, RESET_GAP apart at most.
function Treasury.HandleAsk(dist, sender, text)
	if dist ~= "CHANNEL" or type(text) ~= "string" then return end
	local fresh = text:match("^TA~[^~]*~([01])$")
	if not fresh then return end
	sender = ns.FullName(sender)
	local now = ns.Now()
	local reset = fresh == "0" and now - (resetAt[sender] or -math.huge) >= Treasury.RESET_GAP
	if reset then resetAt[sender] = now end
	if Insider(sender) then
		heard[sender] = now
		Treasury.MarkReader(sender)
		if reset then sentTo[sender] = nil end
		Treasury.SendPrivate(sender)
	end
	if ns.Bank and ns.Bank.HeardAsk then ns.Bank.HeardAsk(sender, reset) end
end
ns.Comm.Handle("TA", function(...) Treasury.HandleAsk(...) end)

-- The server says a player we whisper is not online: what waits for him is dropped (one line of
-- the game's in the chat, not one a piece), and he is no longer counted online.
local notFound
function Treasury.NotFound(text)
	if type(text) ~= "string" then return end
	if not notFound then
		local f = type(ERR_CHAT_PLAYER_NOT_FOUND_S) == "string" and ERR_CHAT_PLAYER_NOT_FOUND_S or nil
		if not f then return end
		notFound = "^" .. (f:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%s", "(.+)")) .. "$"
	end
	local who = text:match(notFound)
	if not who then return end
	who = who:lower()
	local function Is(name) return (ns.TellName(name) or ""):lower() == who or (ns.DisplayName(name) or ""):lower() == who end
	for i = #outbox, 1, -1 do if Is(outbox[i].to) then table.remove(outbox, i) end end
	for name in pairs(heard) do if Is(name) then heard[name] = nil end end
	if ns.Bank and ns.Bank.NotFound then ns.Bank.NotFound(Is) end
	for name in pairs(firstHeard) do if Is(name) then firstHeard[name] = nil end end
	if sending and Is(sending.to) then
		sending = nil
		PumpPrivate()
	end
end

-- For tests: what waits, and what goes.
function Treasury.PrivateState() return { outbox = outbox, sending = sending, sentTo = sentTo, heard = heard, held = held } end
function Treasury.ResetPrivate()
	wipe(heard); wipe(firstHeard); wipe(outbox); wipe(sentTo); wipe(resetAt)
	sending, lastAsk, notFound, held = nil, -math.huge, nil, false
	if ns.rdb then ns.rdb.treasuryReaders = nil end
	privAsm = ns.Codec.NewAssembler()
end

ns.On("LOGIN", function()
	-- The King, a Steward or a keeper asks once after login, then now and then; the pieces of
	-- whispers never finished are dropped (Codec.Gc, a minute).
	ns.After(Treasury.ASK_AFTER, "treasury ask", function() Treasury.Ask(true) end)
	ns.Every(60, "treasury private", function()
		ns.Codec.Gc(privAsm, ns.Now())
		if Treasury.AskDue() then Treasury.Ask(false) end
	end)
	pcall(ns.RegisterEvent, "CHAT_MSG_SYSTEM", function(text) ns.SafeCall("treasury private", Treasury.NotFound, text) end)
end)

---------------------------------------------------------------------------
-- The King's switches (what the army sees) and his keepers
-- 1.0.0: his Steward sets them too, in his name (King.STEWARD_MAY: T, K). A word carries the
-- time it was given; the newest wins everywhere, and on the same second the King's own over his
-- Steward's: the King's newer word always wins. The King's client and his Steward's take the
-- newest word as theirs and repeat it, and answer an older one they hear with theirs (at most
-- once in WORD_ANSWER). The Treasurer's book carries the switches for 1.0's addons, never the
-- keepers; 1.1 takes neither from it (Konig's review of 1.1).
---------------------------------------------------------------------------

Treasury.WORD_ANSWER = 30

-- A word dated `at` from `sender` replaces the one kept: newer, or the King's own of the same
-- second over anyone else's.
local function Replaces(kept, at, sender)
	local was = type(kept) == "table" and tonumber(kept.at) or nil
	if not was or at ~= was then return was == nil or at > was end
	return ns.IsKingCharacter(sender) and not ns.IsKingCharacter(kept.from)
end
Treasury.Replaces = Replaces -- (1.1: the King's dues amount too, Dues.lua)

-- Told on the King's screen: his Steward changed one of his words (the name cut short while the
-- council's names are hidden there, his stream).
local function TellKing(sender, text)
	if ns.King.IsKing() and ns.King.IsStewardName(sender) then ns.Print(text:format(ns.King.StewardLabel(sender))) end
end

-- The King's client and his Steward's repeat the word, with the time it was given (a client that
-- never heard it sends nothing). 1.1 (#12): never
-- another's word given less than WORD_FRESH ago: a word that new goes out from its giver's client
-- alone, so the log of acts can name him (TakeFlags); after that it is repeated as before.
function Treasury.SendFlags(force)
	local f = ns.rdb and ns.rdb.treasuryFlags
	if not ns.King.SetsLists() or type(f) ~= "table" or not tonumber(f.at) then return end
	if not SameChar(f.from, ns.me) and Clock() - tonumber(f.at) < Treasury.WORD_FRESH then return end
	local now = ns.Now()
	if not force and now - lastFlagsSent < Treasury.FLAGS_EVERY then return end
	lastFlagsSent = now
	ns.Comm.Send("CHANNEL", ("T1~T~%d~%s~%s~%d"):format(ns.King.NewId(), GetGuildInfo("player") or "", FlagDigits(f), math.floor(f.at)), "treasuryflags")
end

-- The King's switch, or his Steward's in his name (the author's Asmon's view: its own switches,
-- on his screen only).
function Treasury.SetFlag(what, on)
	if not IsKingView() then return ns.Print(L.THRONE_ONLY_KING) end
	local f = {}
	for _, k in ipairs(FLAGS) do f[k] = Treasury.Shows(k) end
	f[what] = on and true or false
	-- Each word newer than the last, two clicks in one second too (the army takes the newest).
	local prev = ns.King.Preview() and ns.db.previewTreasuryFlags or ns.rdb.treasuryFlags
	f.t, f.at, f.from = ns.Now(), math.max(Clock(), (type(prev) == "table" and tonumber(prev.at) or 0) + 1), ns.me
	ns.Print(L["TREASURY_FLAG_" .. what:upper() .. (on and "_ON" or "_OFF")])
	if ns.King.Preview() then
		ns.db.previewTreasuryFlags = f
		ns.Print(L.THRONE_PREVIEW_NOTE)
	else
		local was = FlagDigits(type(prev) == "table" and prev or {})
		ns.rdb.treasuryFlags = f
		Treasury.SendFlags(true)
		-- 1.1 (#12): our own switch never comes back to us: in our log as we send it.
		Treasury.LogFlags(ns.me, f)
		Treasury.SwitchesChanged(was)
	end
	ns.Fire("TREASURY_CHANGED")
	ns.Fire("DATA_CHANGED")
end

-- An older word heard (the King's client or a Steward's after a while away, the Treasurer's
-- book not caught up yet): the King's client and his Steward's answer with the newer one.
local lastWordAnswer = -math.huge
local function AnswerOlder(send)
	if not ns.King.SetsLists() or ns.Now() - lastWordAnswer < Treasury.WORD_ANSWER then return end
	lastWordAnswer = ns.Now()
	send(true)
end

-- The King's word ("101" and the time it was given), from him or his Steward: taken when newer
-- than the one kept (a time ahead of the server's clock by King.DATE_AHEAD at most: a minute, so a
-- modified client never keeps a word over the King's newer one for longer).
-- `relayed`: the Treasurer's copy in his book (1.0's addons read it there). Konig's review of 1.1:
-- only the King and his Stewards set the switches, and a copy can't be told from a word the
-- Treasurer's client made up or dated anew (no signature of the King's travels with it; taken, it
-- was also repeated by the King's and his Stewards' clients as theirs), so it is never taken: an
-- older one is only answered with ours, so that his client, and the 1.0 addons reading his book,
-- catch up. Each client keeps the last word it heard from the King or a Steward themselves.
function Treasury.TakeFlags(digits, at, sender, relayed)
	local b, r, k = tostring(digits or ""):match("^([01])([01])([01])$")
	at = tonumber(at)
	if not b or not at or at > Clock() + ns.King.DATE_AHEAD then return end
	local kept = ns.rdb.treasuryFlags
	if relayed or not Replaces(kept, at, sender) then
		if type(kept) == "table" and at < (tonumber(kept.at) or 0) then AnswerOlder(Treasury.SendFlags) end
		return
	end
	local was = type(kept) == "table" and FlagDigits(kept) or "000"
	local f = { balance = b == "1", ranking = r == "1", book = k == "1", at = at, t = ns.Now(), from = ns.FullName(sender) }
	ns.rdb.treasuryFlags = f
	-- 1.1 (#12): in this client's log of acts when what the army sees changes (the word is
	-- repeated), with the name the server stamped, only when heard from whoever gave it: a word
	-- given less than WORD_FRESH ago comes from his client alone (SendFlags). Never a word caught
	-- up on later (a later login, a repeat): those are only noted.
	Treasury.LogFlags(sender, f, Clock() - at >= Treasury.WORD_FRESH)
	Treasury.Heard(sender)
	if FlagDigits(f) ~= was then
		TellKing(sender, L.STEWARD_SET_FLAGS)
		-- A keeper is told who sees the treasury now.
		if CanSend() then ns.Print(Treasury.WhoSees()) end
		Treasury.SwitchesChanged(was)
		ns.Fire("TREASURY_CHANGED")
		ns.Fire("DATA_CHANGED") -- the tab appears or goes
	end
end
-- What the army sees of the treasury, in this client's log of acts (1.1, #12): once each time it
-- changes; nothing shown is where it starts. `quiet`: this client only caught up on it (noted,
-- so the next change is compared with it, not written).
function Treasury.LogFlags(sender, f, quiet)
	if quiet then return ns.Chronicle.Seen("treasury", FlagDigits(f)) end
	local shown = {}
	for _, k in ipairs(FLAGS) do
		if f[k] then shown[#shown + 1] = L["ACTS_TREASURY_" .. k:upper()] end
	end
	local what = L.ACTS_TREASURY:format(#shown > 0 and table.concat(shown, ", ") or L.ACTS_TREASURY_NOTHING)
	return ns.Chronicle.Add("switch", sender, what, { key = "treasury", value = FlagDigits(f), default = "000" })
end

-- The switches changed (1.1): a keeper's client sends at once what the channel may carry now
-- (his book, the bank, the early supporters when the ranking just showed), and by whisper what
-- it may no longer carry.
function Treasury.SwitchesChanged(was)
	if not CanSend() then return end
	Treasury.Share(true)
	if ns.Bank and ns.Bank.Share then ns.Bank.Share(true) end
	if Treasury.PublicShows("ranking") and tostring(was or "000"):sub(2, 2) ~= "1" then Treasury.SendEarly(true) end
end
ns.King.Register("T", function(sender, id, rest)
	local digits, at = tostring(rest or ""):match("^([01][01][01])~(%d+)$")
	Treasury.TakeFlags(digits, at, sender)
end)

-- A name the King (or his Steward) typed or targeted (typed: his target when he typed none), as
-- the server writes it; nil if it can't be a character.
local function KeeperName(input, typed)
	local name = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" and typed then
		name = UnitIsPlayer and UnitIsPlayer("target") and ns.UnitFullName("target") or ""
	end
	name = ns.Normal(name)
	local short = ns.King.CleanName(name)
	local realm = ns.RealmOf(name)
	if not short or (realm and not realm:match("^[%w\128-\255]+$")) or #(realm or "") > 40 then return nil end
	return ns.FullName(short, realm)
end

-- The King's list as it goes out (T1~K), from his client or his Steward's: dated, the newest
-- word wins everywhere.
function Treasury.SendKeepers(force)
	local k = KeeperStore()
	if not ns.King.SetsLists() or not (k and tonumber(k.at)) then return end
	local now = ns.Now()
	if not force and now - lastKeepersSent < Treasury.FLAGS_EVERY then return end
	lastKeepersSent = now
	local names = {}
	for i, n in ipairs(k.names) do names[i] = Clean(n) end
	ns.Comm.Send("CHANNEL", ("T1~K~%d~%s~%d~%s"):format(ns.King.NewId(), GetGuildInfo("player") or "", math.floor(k.at), table.concat(names, ",")), "treasurykeepers")
end

-- The King's list changed on his screen (his own, his Steward's, or the author's view's): kept, sent.
local function SetKeepers(names)
	local preview = ns.King.Preview()
	local prev = preview and ns.db.previewTreasuryKeepers or KeeperStore()
	local k = { names = names, t = ns.Now(), at = math.max(Clock(), (type(prev) == "table" and tonumber(prev.at) or 0) + 1), from = ns.me }
	if preview then
		ns.db.previewTreasuryKeepers = k
		ns.Print(L.THRONE_PREVIEW_NOTE)
	else
		ns.rdb.treasuryKeepers = k
		Treasury.SendKeepers(true)
	end
	Treasury.mode = "keepers"
	ns.Fire("TREASURY_CHANGED")
	ns.Fire("DATA_CHANGED")
end

-- The King adds a character to the treasury: its trades and mail go in its own book (5 at most
-- besides the Treasurer and the King, who always keep one).
function Treasury.AddKeeper(input)
	if not IsKingView() then return ns.Print(L.THRONE_ONLY_KING) end
	local name = KeeperName(input, true)
	if not name then return ns.Print(L.TREASURY_KEEPER_WHO) end
	if PinnedName(name) then return end
	local names = {}
	for _, n in ipairs(Treasury.Keepers()) do
		if SameChar(n, name) then return end
		names[#names + 1] = n
	end
	if #names >= Treasury.MAX_KEEPERS then return ns.Print(L.TREASURY_KEEPER_FULL:format(Treasury.MAX_KEEPERS)) end
	names[#names + 1] = name
	ns.Print(L.TREASURY_KEEPER_ADDED:format(ns.DisplayName(name)))
	SetKeepers(names)
end

function Treasury.RemoveKeeper(name)
	if not IsKingView() then return ns.Print(L.THRONE_ONLY_KING) end
	local names, found = {}, false
	for _, n in ipairs(Treasury.Keepers()) do
		if n == name then found = true else names[#names + 1] = n end
	end
	if not found then return end
	ns.Print(L.TREASURY_KEEPER_REMOVED:format(ns.DisplayName(name)))
	SetKeepers(names)
end

-- The King's list (from him or his Steward, T1~K, their names set by the server): taken when newer than
-- the one kept (dated King.DATE_AHEAD ahead of the server's clock at most). A character named sees
-- its book open at its gold now and is asked to share it; the books of characters no longer on it
-- leave the treasury.
function Treasury.TakeKeepers(at, text, sender)
	at = tonumber(at)
	if not at or at > Clock() + ns.King.DATE_AHEAD then return end
	local kept = KeeperStore()
	if not Replaces(kept, at, sender) then
		if kept and at < (tonumber(kept.at) or 0) then AnswerOlder(Treasury.SendKeepers) end
		return
	end
	local before = {}
	for i, n in ipairs(kept and kept.names or {}) do before[i] = n end
	local names = {}
	for entry in tostring(text or ""):gmatch("[^,]+") do
		local name = KeeperName(entry)
		if name and #names < Treasury.MAX_KEEPERS and not PinnedName(name) then names[#names + 1] = name end
	end
	local was = RealKeeper()
	ns.rdb.treasuryKeepers = { at = at, names = names, t = ns.Now(), from = ns.FullName(sender) }
	Treasury.Heard(sender)
	if table.concat(names, ",") ~= table.concat(before, ",") then TellKing(sender, L.STEWARD_SET_KEEPERS) end
	-- Books of characters no longer keepers: no longer kept.
	local reports, gone = Reports(), {}
	for from, r in pairs(reports) do
		if type(r) ~= "table" or not Treasury.IsKeeperName(from, r.guild) then gone[#gone + 1] = from end
	end
	for _, from in ipairs(gone) do reports[from] = nil end
	local now = RealKeeper()
	if now and not was then
		ns.Print(L.TREASURY_KEEPER_NAMED:format(ns.KingName(sender)))
		Treasury.OpenBook()
		Treasury.AskConsent()
		-- (1.1: the other keepers' whole books come to a keeper by whisper: asked for now.)
		Treasury.Ask(true)
	elseif was and not now then
		ns.Print(L.TREASURY_KEEPER_UNNAMED)
	end
	ns.Fire("TREASURY_CHANGED")
	ns.Fire("DATA_CHANGED")
end
ns.King.Register("K", function(sender, id, rest)
	local at, names = tostring(rest or ""):match("^(%d+)~?(.*)$")
	if at then Treasury.TakeKeepers(tonumber(at), names, sender) end
end)

StaticPopupDialogs["SYLVANISTAS_TREASURY_KEEPER"] = {
	text = L.TREASURY_KEEPER_PROMPT,
	button1 = OKAY or "OK",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 240,
	maxLetters = 40,
	OnShow = function(self)
		local eb = self.editBox or self.EditBox
		if eb then
			local target = UnitIsPlayer and UnitIsPlayer("target") and ns.UnitFullName("target")
			eb:SetText(target and ns.DisplayName(target) or "")
			eb:SetFocus()
		end
	end,
	OnAccept = function(self)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("treasury keeper", Treasury.AddKeeper, eb and eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		ns.SafeCall("treasury keeper", Treasury.AddKeeper, self:GetText())
		self:GetParent():Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs["SYLVANISTAS_TREASURY_UNKEEP"] = {
	text = L.TREASURY_KEEPER_REMOVE_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function(self, data) ns.SafeCall("treasury unkeep", Treasury.RemoveKeeper, data or (self and self.data)) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- The early supporters: everyone who gave before 1.0
---------------------------------------------------------------------------

-- 0.9's book (the Treasurer's, archived at 1.0's fresh start, never shown or sent) keeps the
-- names of everyone who gave to the treasury before 1.0. The Treasurer's character holding it
-- (his account kept it) sends their names alone, in alphabetical order, never an amount (1.0's
-- ranking starts afresh), once he said yes to 1.0's question (TreasurerYes): in pieces of one
-- message each (TE), once after login and when a
-- client that has none asks (TQ), EARLY_GAP apart at the soonest. The list carries the time
-- 0.9's book was closed: a newer list replaces an older one, taken once every piece is in.
-- Taken from the Treasurer's pinned characters alone. Shown under the ranking, to whoever may
-- see the ranking (the King's switch; the keepers and the King always). 0.9 clients drop TE and
-- TQ unread (messages of one piece, of types they have no handler for).

-- Names in alphabetical order (whatever their case), each once.
local function Alphabetical(names)
	local out, seen = {}, {}
	for _, n in ipairs(names) do
		local key = n:lower()
		if not seen[key] then
			seen[key] = true
			out[#out + 1] = n
		end
	end
	table.sort(out, function(a, b)
		local x, y = a:lower(), b:lower()
		if x ~= y then return x < y end
		return a < b
	end)
	return out
end

-- The names in 0.9's archived book: every donor its sums count, and every gift still in its
-- lines (a payment, or a line not counted, is none), each a character's name alone (no realm,
-- only what can be a name). { at = when that book was closed, names }, or nil.
local earlyCache
local function ArchivedSupporters()
	local a = ns.rdb and type(ns.rdb.treasuryArchive) == "table" and ns.rdb.treasuryArchive["0.9"]
	if type(a) ~= "table" then return nil end
	if earlyCache and earlyCache.a == a then return earlyCache.list end
	local names = {}
	local sums = type(a.sums) == "table" and a.sums or {}
	for name, copper in pairs(type(sums.byDonor) == "table" and sums.byDonor or {}) do
		local clean = (tonumber(copper) or 0) > 0 and ns.King.CleanName(name)
		if clean then names[#names + 1] = clean end
	end
	for _, e in ipairs(type(a.lines) == "table" and a.lines or {}) do
		if type(e) == "table" and not e.out and not e.excluded and e.kind ~= "transfer" and (tonumber(e.money) or 0) > 0 then
			local clean = ns.King.CleanName(e.name)
			if clean then names[#names + 1] = clean end
		end
	end
	names = Alphabetical(names)
	local list = #names > 0 and { at = math.max(1, math.floor(tonumber(a.closed) or 1)), names = names } or nil
	earlyCache = { a = a, list = list }
	return list
end

-- This character holds 0.9's book: one of the Treasurer's pinned characters, a keeper (his
-- account kept that book).
local function EarlyHolder()
	return RealKeeper() and TreasurerSpeaking(ns.me, GetGuildInfo("player") or "") or false
end

-- The early supporters as this client has them ({ at, names }), or nil: the Treasurer's own
-- characters read the book they keep, everyone else the list their client sent.
function Treasury.EarlySupporters()
	if not ns.rdb then return nil end
	local own = EarlyHolder() and ArchivedSupporters()
	if own then return own end
	local e = ns.rdb.treasuryEarly
	return type(e) == "table" and type(e.names) == "table" and #e.names > 0 and e or nil
end

-- The list in pieces, each one message of the channel's size (TE~<guild>~<time>~<i>~<n>~).
local function EarlyPieces(list, guild)
	local room = 250 - #("TE~%s~%d~%d~%d~"):format(guild, list.at, Treasury.EARLY_PIECES, Treasury.EARLY_PIECES)
	local pieces, cur, len = {}, {}, 0
	for i = 1, math.min(#list.names, Treasury.EARLY_MAX) do
		local name = list.names[i]
		if #cur > 0 and len + 1 + #name > room then
			pieces[#pieces + 1] = table.concat(cur, ",")
			cur, len = {}, 0
		end
		len = len + (#cur > 0 and 1 or 0) + #name
		cur[#cur + 1] = name
	end
	if #cur > 0 then pieces[#pieces + 1] = table.concat(cur, ",") end
	while #pieces > Treasury.EARLY_PIECES do table.remove(pieces) end
	return pieces
end

-- 0.9's book was the Treasurer's: its names go out with his own yes to 1.0's question, which
-- says the names go to everyone on the channel, whichever of his pinned characters holds it.
-- (1.1: his line on the first-open page asks it, and says so too: YesSendsEarly.)
-- His 0.9.3 yes is not enough (Konig's review of 1.0.0: it was given to a question that never
-- said so; his book still goes out under it, and he is asked 1.0's question: AskConsent). His
-- mail character's yes is to its own book, not to his.
local function TreasurerYes()
	local shares = ns.db and ns.db.keeperShares
	if type(shares) ~= "table" then return false end
	local key = TreasurerPin(ns.me) == 1 and ConsentKey() or TreasurerCharacter() or OwnKey(ns.TREASURER)
	return shares[key] == true
end
local function MaySendEarly() return CanSend() and EarlyHolder() and TreasurerYes() end

-- Whether this character's own yes is the one that sends the early supporters' names (the
-- Treasurer's character, holding 0.9's book): his line on the first-open page then says so, as
-- 1.0's question does (1.1, #11).
function Treasury.YesSendsEarly()
	return EarlyHolder() and TreasurerPin(ns.me) == 1 and ArchivedSupporters() ~= nil
end

-- The holder's client sends the list, a piece every EARLY_PACE (the channel's queue stays
-- light), with its own yes to sharing and the Treasurer's (the names are who gave, as in his
-- book).
-- 1.1: on the channel only while the King shows the army the ranking; the King, his Stewards and
-- the keepers get it by whisper otherwise (SendEarlyTo).
function Treasury.SendEarly(force)
	if not MaySendEarly() or not Treasury.PublicShows("ranking") then return false end
	local list = ArchivedSupporters()
	if not list then return false end
	local now = ns.Now()
	if not force and now - lastEarlySent < Treasury.EARLY_GAP then return false end
	lastEarlySent = now
	local guild = Clean(GetGuildInfo("player"))
	local pieces, token = EarlyPieces(list, guild), {}
	earlySending = token
	local function Piece(i)
		if earlySending ~= token or not MaySendEarly() then return end
		ns.Comm.Send("CHANNEL", ("TE~%s~%d~%d~%d~%s"):format(guild, list.at, i, #pieces, pieces[i]), "treasuryearly" .. i)
		if i < #pieces then
			ns.After(Treasury.EARLY_PACE, "treasury early", function() Piece(i + 1) end)
		else
			earlySending = nil
		end
	end
	Piece(1)
	return true
end

-- The list for one player alone, by whisper (1.1: the King, a Steward or a keeper, while the
-- ranking is off the channel), piece by piece as on the channel; not again while he holds it.
function Treasury.SendEarlyTo(name)
	if not MaySendEarly() then return false end
	local list = ArchivedSupporters()
	if not list then return false end
	local guild = Clean(GetGuildInfo("player"))
	local pieces, msgs = EarlyPieces(list, guild), {}
	for i, piece in ipairs(pieces) do msgs[i] = ("TE~%s~%d~%d~%d~%s"):format(guild, list.at, i, #pieces, piece) end
	if #msgs == 0 then return false end
	return Treasury.Private(name, "TE", table.concat(msgs, "\n"), "TE", msgs)
end

-- A piece of the list: from one of the Treasurer's pinned characters (his name, set by the
-- server). A list as new as ours changes nothing; a newer one replaces ours once all its
-- pieces are in (an older list's piece meanwhile is dropped). By whisper (1.1) only to the King,
-- a Steward or a keeper.
function Treasury.HandleEarly(dist, sender, text)
	if (dist ~= "CHANNEL" and dist ~= "WHISPER") or type(text) ~= "string" or not ns.rdb then return end
	if dist == "WHISPER" and not Treasury.IsInsider() then return end
	local guild, at, i, n, names = text:match("^TE~([^~]*)~(%d+)~(%d+)~(%d+)~([^~]*)$")
	at, i, n = tonumber(at), tonumber(i), tonumber(n)
	if not at or not TreasurerSpeaking(sender, guild) then return end
	if at < 1 or at > Clock() + 600 or n < 1 or n > Treasury.EARLY_PIECES or i < 1 or i > n then return end
	local held = ns.rdb.treasuryEarly
	if type(held) == "table" and (tonumber(held.at) or 0) >= at then return end
	local p = earlyPending
	if not p or p.at ~= at or p.pieces ~= n then
		if p and p.at > at then return end
		p = { at = at, pieces = n, got = {}, count = 0, from = ns.FullName(sender) }
		earlyPending = p
	end
	if p.got[i] then return end
	local list = {}
	for name in names:gmatch("[^,]+") do
		local clean = ns.King.CleanName(name)
		if clean then list[#list + 1] = clean end
	end
	p.got[i], p.count = list, p.count + 1
	if p.count < p.pieces then return end
	earlyPending = nil
	local all = {}
	for k = 1, p.pieces do
		for _, name in ipairs(p.got[k]) do if #all < Treasury.EARLY_MAX then all[#all + 1] = name end end
	end
	ns.rdb.treasuryEarly = { at = at, names = Alphabetical(all), from = p.from, t = ns.Now() }
	ns.Fire("TREASURY_CHANGED")
end
ns.Comm.Handle("TE", function(...) Treasury.HandleEarly(...) end)

-- A client that may see the list (the ranking) and has none asks for it (TQ): EARLY_ASK_AFTER
-- after login, then EARLY_ASK_AGAIN later while still without it, EARLY_ASKS times a session at
-- most, never while someone else's ask is fresher than EARLY_ASK_HOLD (its answer reaches us).
function Treasury.AskEarly()
	if not earlyArmed or earlyAsks >= Treasury.EARLY_ASKS or not ns.rdb or ns.TREASURY_OFF or not ns.IsMember() then return false end
	if Treasury.EarlySupporters() or not Treasury.MaySee("ranking") then return false end
	local now = ns.Now()
	if now - lastEarlyAsk < Treasury.EARLY_ASK_AGAIN or now - heardEarlyAsk < Treasury.EARLY_ASK_HOLD then return false end
	earlyAsks, lastEarlyAsk = earlyAsks + 1, now
	local held = ns.rdb.treasuryEarly
	ns.Comm.Send("CHANNEL", ("TQ~%d"):format(type(held) == "table" and tonumber(held.at) or 0), "treasuryearlyask")
	return true
end
function Treasury.ArmEarly()
	earlyArmed = true
	return Treasury.AskEarly()
end

-- Someone asks: the holder answers when its list is newer than the asker's (EARLY_GAP apart at
-- the soonest, however many ask: the answer goes to the whole channel), with the same yeses as
-- its own sending (SendEarly). Anyone's ask holds ours (EARLY_ASK_HOLD) only when its answer
-- reaches us too: it asks for no newer list than ours, so any list newer than it has is newer
-- than ours (Konig's review of 1.0.0: an ask as new as the holder's list, or dated ahead, is
-- never answered, and anyone repeating one kept every client without the list from asking).
function Treasury.HandleEarlyAsk(dist, sender, text)
	if dist ~= "CHANNEL" or type(text) ~= "string" then return end
	local at = tonumber(text:match("^TQ~(%d+)$"))
	if not at then return end
	local held = ns.rdb and ns.rdb.treasuryEarly
	local ours = type(held) == "table" and tonumber(held.at) or 0
	if at <= ours then heardEarlyAsk = ns.Now() end
	local list = EarlyHolder() and ArchivedSupporters()
	if not (list and list.at > at) then return end
	-- (1.1: while the ranking is off the channel, the King, a Steward or a keeper asking gets it
	-- by whisper; nobody else.)
	if Treasury.PublicShows("ranking") then Treasury.SendEarly()
	elseif Treasury.InsiderName(sender) and CanSend() then Treasury.SendEarlyTo(sender) end
end
ns.Comm.Handle("TQ", function(...) Treasury.HandleEarlyAsk(...) end)

-- Every minute: the books, the King's switches and his keepers, repeated for late logins; what
-- PRIVATE_GAP held back.
function Treasury.Tick()
	if ns.Now() - lastShare >= Treasury.SHARE_EVERY then Treasury.Share(true) end
	Treasury.FlushPrivate()
	Treasury.SendFlags()
	Treasury.SendKeepers()
	Treasury.AskEarly()
end

ns.On("LOGIN", function()
	Treasury.Migrate()
	-- The account's characters, for gold between a keeper's own.
	if ns.db and ns.me then
		ns.db.myCharacters = ns.db.myCharacters or {}
		ns.db.myCharacters[OwnKey(ns.me)] = true
	end
	-- A keeper's question (his yes to sharing), once the guild is known; tried again later while
	-- he is busy (combat, an instance). His book of 1.0 opens at his gold as soon as the guild
	-- says he is a keeper.
	ns.After(5, "treasury book", function() Treasury.OpenBook() end)
	ns.Every(60, "treasurer question", function()
		ns.SafeCall("treasury book", Treasury.OpenBook)
		ns.SafeCall("treasurer question", Treasury.AskConsent)
	end)
	ns.RegisterEvent("TRADE_SHOW", function() ns.SafeCall("treasury trade", Treasury.TradeShow) end)
	for _, event in ipairs({ "TRADE_MONEY_CHANGED", "TRADE_ACCEPT_UPDATE", "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED" }) do
		ns.RegisterEvent(event, function() ns.SafeCall("treasury trade", Treasury.TradeMoney) end)
	end
	ns.RegisterEvent("UI_INFO_MESSAGE", function(a, b) ns.SafeCall("treasury trade", Treasury.Info, a, b) end)
	-- The window closes before or after the "trade complete" message, depending on the client:
	-- this trade is forgotten a little later (not the next one, opened meanwhile).
	ns.RegisterEvent("TRADE_CLOSED", function()
		local closing = trade
		ns.After(2, "treasury trade", function() if trade == closing then trade = nil end end)
	end)
	if hooksecurefunc then
		if SendMail then hooksecurefunc("SendMail", function(to) ns.SafeCall("treasury mail", Treasury.MailSending, to) end) end
		if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", function(i) ns.SafeCall("treasury mail", Treasury.MailTaking, i) end) end
		if TakeInboxItem then hooksecurefunc("TakeInboxItem", function(i, a) ns.SafeCall("treasury mail", Treasury.MailItemTaking, i, a) end) end
		if AutoLootMailItem then
			hooksecurefunc("AutoLootMailItem", function(i)
				ns.SafeCall("treasury mail", Treasury.MailTaking, i)
				ns.SafeCall("treasury mail", Treasury.MailItemTaking, i)
			end)
		end
	end
	ns.RegisterEvent("MAIL_SEND_SUCCESS", function() ns.SafeCall("treasury mail", Treasury.MailSent) end)
	ns.RegisterEvent("MAIL_FAILED", function(itemID)
		if not itemID then mailOut = nil end
		Treasury.MailFailed(itemID)
	end)
	ns.RegisterEvent("PLAYER_MONEY", function() ns.SafeCall("treasury mail", Treasury.MoneyChanged) end)
	for _, event in ipairs({ "BAG_UPDATE_DELAYED", "MAIL_SUCCESS", "MAIL_INBOX_UPDATE" }) do
		pcall(ns.RegisterEvent, event, function() ns.SafeCall("treasury mail", Treasury.ItemsChanged) end)
	end
	-- The books, the King's switches and his keepers, repeated for late logins.
	ns.Every(60, "treasury share", function() Treasury.Tick() end)
	-- The early supporters: sent by the Treasurer's character holding them once after login
	-- (after his book), asked for by a client without them a little later.
	ns.After(45, "treasury early", function() Treasury.SendEarly(true) end)
	ns.After(Treasury.EARLY_ASK_AFTER, "treasury early", function() Treasury.ArmEarly() end)
	ns.After(30, "treasury share", function()
		Treasury.Share(true)
		Treasury.SendFlags(true)
		Treasury.SendKeepers(true)
		-- A keeper is told once who sees the treasury (and again when the King changes it).
		if CanSend() and not ns.rdb.treasuryToldWho then
			ns.rdb.treasuryToldWho = true
			ns.Print(Treasury.WhoSees())
		end
	end)
end)

---------------------------------------------------------------------------
-- 1.1: "taking donations" (the Treasurer's idea: "being able to let everyone know when I'm around to
-- take donations can be helpful too"). A keeper (the Treasurer, the King, a character he named)
-- turns it on with a click on the Treasury tab or /syl donations on: every client shows a line on
-- the Realm and Treasury tabs, with his zone only if he shares his location (/syl location; the
-- King: his crown on the map), and one line in the [Sylvanistas] chat when he turns it on. It is never
-- saved: off when he logs out (his addon says so as it logs out; otherwise the others drop it
-- DONATIONS_FRESH after his last word), and after a /reload.
--   TD~<guild>~<1|0>~<since>~<uiMapID or empty>   on the channel: at once, then every DONATIONS_EVERY
--                                                  while it is on, and when his zone changes
---------------------------------------------------------------------------

Treasury.DONATIONS_EVERY = 120
Treasury.DONATIONS_FRESH = 300
Treasury.DONATIONS_PING = 180   -- the chat line only for an "on" this fresh (a late login gets the lines alone)

local donating                  -- our own: { since, mapID }, while on
local donors = {}               -- [keeper's Name-Realm] = { since, mapID, t }: keepers taking donations
local pinged = {}               -- [Name-Realm] = the "since" we already put in the chat
local lastDonationSent = -math.huge

function Treasury.TakingDonations() return donating ~= nil end

-- Where we are, only while we share our location (Layers.Sharing: the King's is his crown).
local function DonationZone()
	if not (ns.Layers and ns.Layers.Sharing and ns.Layers.Sharing()) then return nil end
	local mapID = ns.Court and ns.Court.Here and ns.Court.Here()
	return tonumber(mapID)
end

local function DonationMessage(on)
	local zone = on and donating and donating.mapID
	return ("TD~%s~%d~%d~%s"):format(Clean(GetGuildInfo("player")), on and 1 or 0, on and donating and math.floor(donating.since) or 0, zone and tostring(zone) or "")
end

function Treasury.SendDonations(force)
	if not donating or not RealKeeper() then return false end
	local now = ns.Now()
	if not force and now - lastDonationSent < Treasury.DONATIONS_EVERY then return false end
	lastDonationSent = now
	-- His zone read again at every send: once he stops sharing his location (/syl location off,
	-- the King's crown off), no repeat carries the zone he had.
	donating.mapID = DonationZone()
	ns.Comm.Send("CHANNEL", DonationMessage(true), "treasurydonations")
	return true
end

function Treasury.SetDonations(on)
	if not RealKeeper() then return ns.Print(L.DONATIONS_ONLY) end
	if on then
		donating = { since = ns.Now(), mapID = DonationZone() }
		Treasury.SendDonations(true)
		ns.Print(donating.mapID and L.DONATIONS_NOW_ON_ZONE or L.DONATIONS_NOW_ON)
	elseif donating then
		donating = nil
		ns.Comm.Send("CHANNEL", DonationMessage(false), "treasurydonations")
		ns.Print(L.DONATIONS_NOW_OFF)
	end
	ns.Fire("TREASURY_CHANGED")
	ns.Fire("DATA_CHANGED")
end

-- Our zone changed while on, or we started or stopped sharing it (Layers.SetSharing, the King's
-- crown): said again at once (the zone only while we share it).
function Treasury.DonationsMoved()
	if not donating then return end
	local zone = DonationZone()
	if zone == donating.mapID then return end
	donating.mapID = zone
	Treasury.SendDonations(true)
end

-- Logging out (or a /reload): off, said once as the addon leaves (the others drop it anyway).
function Treasury.DonationsLogout()
	if not donating then return end
	donating = nil
	local name = ns.Comm.ChannelName and ns.Comm.ChannelName()
	local id = name and GetChannelName and GetChannelName(name) or 0
	if id and id > 0 and C_ChatInfo and C_ChatInfo.SendAddonMessage then
		pcall(C_ChatInfo.SendAddonMessage, ns.PREFIX, DonationMessage(false), "CHANNEL", id)
	end
end

-- A keeper's word (from a keeper alone, his name, which the server sets): kept while repeated,
-- one line in the [Sylvanistas] chat for a fresh "on", unless that chat is muted (or the chats off).
function Treasury.HandleDonations(dist, sender, text)
	if dist ~= "CHANNEL" or type(text) ~= "string" then return end
	local guild, on, since, zone = text:match("^TD~([^~]*)~([01])~(%d+)~(%d*)$")
	if not guild or not Treasury.IsKeeperName(sender, guild) then return end
	sender = ns.FullName(sender)
	local now = ns.Now()
	if on == "0" then
		if donors[sender] then
			donors[sender] = nil
			ns.Fire("TREASURY_CHANGED")
			ns.Fire("DATA_CHANGED")
		end
		return
	end
	since = math.min(tonumber(since) or now, now)
	local mapID = tonumber(zone)
	if mapID and (mapID < 1 or mapID > 100000) then mapID = nil end
	donors[sender] = { since = since, mapID = mapID, t = now }
	if pinged[sender] ~= since and now - since <= Treasury.DONATIONS_PING then
		pinged[sender] = since
		-- (1.1.1: not while the Sylvanistas chats are off on this client, as their own lines; in the
		-- Sylvanistas tab without "[Sylvanistas] ", as they come there, Channels.Show.)
		local chat = ns.Channels
		local muted = ns.db and type(ns.db.chatMute) == "table" and ns.db.chatMute.A
		local f, wname
		if not muted and chat and chat.Frame and chat.ChatOn and chat.ChatOn() then f, wname = chat.Frame("A") end
		if f and f.AddMessage then
			local c = chat.TIERS and chat.TIERS.A and chat.TIERS.A.color or { 1, 0.82, 0 }
			local bare = f ~= DEFAULT_CHAT_FRAME and chat.IsTabName and chat.IsTabName(wname)
			f:AddMessage((bare and "" or "[" .. L.CHAN_ALL .. "] ") .. Treasury.DonationText(sender, donors[sender]), c[1], c[2], c[3])
		end
	end
	ns.Fire("TREASURY_CHANGED")
	ns.Fire("DATA_CHANGED")
end
ns.Comm.Handle("TD", function(...) Treasury.HandleDonations(...) end)

-- "Pyralis Ashandar is taking donations (in Stormwind City)": the King by the army's name for him.
function Treasury.DonationText(name, d)
	local who = (ns.KingDisplaySet() and ns.IsKingCharacter(name)) and ns.KING_NAME or (ns.DisplayName(name) or "?")
	local info = d and d.mapID and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(d.mapID)
	local zone = type(info) == "table" and type(info.name) == "string" and info.name ~= "" and info.name or nil
	return zone and L.DONATIONS_LINE_ZONE:format(who, zone) or L.DONATIONS_LINE:format(who)
end

-- The keepers taking donations now (ours too), a line each, for the Realm and Treasury tabs.
function Treasury.DonationLines()
	local out, now, names = {}, ns.Now(), {}
	for name, d in pairs(donors) do
		if now - d.t > Treasury.DONATIONS_FRESH or not Treasury.KeeperByName(name) then donors[name] = nil else names[#names + 1] = name end
	end
	table.sort(names)
	if donating and ns.me and RealKeeper() then out[#out + 1] = { text = ns.COIN .. Green(Treasury.DonationText(ns.me, donating)) } end
	for _, name in ipairs(names) do
		local d = donors[name]
		out[#out + 1] = { text = ns.COIN .. Green(Treasury.DonationText(name, d)), right = Grey(ns.Ago(d.since)) }
	end
	return out
end

ns.On("LOGIN", function()
	ns.Every(30, "treasury donations", function() Treasury.SendDonations() end)
	pcall(ns.RegisterEvent, "ZONE_CHANGED_NEW_AREA", function() ns.SafeCall("treasury donations", Treasury.DonationsMoved) end)
	pcall(ns.RegisterEvent, "PLAYER_LOGOUT", function() ns.SafeCall("treasury donations", Treasury.DonationsLogout) end)
end)

---------------------------------------------------------------------------
-- What the tab shows
---------------------------------------------------------------------------

-- A paragraph in short rows, grey unless said (the list's rows are one line each).
local function Para(lines, text, color)
	color = color or Grey
	local row = ""
	for word in tostring(text or ""):gmatch("%S+") do
		if row ~= "" and #row + 1 + #word > 58 then
			lines[#lines + 1] = { text = color(row) }
			row = word
		else
			row = row == "" and word or (row .. " " .. word)
		end
	end
	if row ~= "" then lines[#lines + 1] = { text = color(row) } end
	return lines
end

-- What the King shows the army now ("the balance, the book").
local function ShownParts()
	local shown = {}
	for _, k in ipairs(FLAGS) do if Treasury.Shows(k) then shown[#shown + 1] = L["TREASURY_PART_" .. k:upper()] end end
	return shown
end
-- Who sees the treasury, told to a keeper: the keepers and the King, and what the King shows the army.
function Treasury.WhoSees()
	local shown = ShownParts()
	return #shown > 0 and L.TREASURY_YOU_AND_KING_BUT:format(table.concat(shown, ", ")) or L.TREASURY_YOU_AND_KING
end
-- The book's way back to the summary: what the viewer will find there.
function Treasury.SummaryTip()
	local parts = {}
	for _, k in ipairs({ "balance", "ranking" }) do
		if Treasury.MaySee(k) then parts[#parts + 1] = L["TREASURY_PART_" .. k:upper()] end
	end
	return #parts > 0 and L.TREASURY_SUMMARY_BTN_TIP:format(table.concat(parts, ", ")) or L.TREASURY_SUMMARY_BTN_TIP_PLAIN
end

function Treasury.Show(mode)
	Treasury.mode = mode
	bookShown, rankShown, earlyShown = Treasury.BOOK_SHOWN, Treasury.RANK_PAGE, Treasury.EARLY_SHOWN
	ns.Fire("TREASURY_CHANGED")
end

-- The ranking and the book from their first page again (the tab's search changed, Views.lua).
function Treasury.FirstPage() bookShown, rankShown = Treasury.BOOK_SHOWN, Treasury.RANK_PAGE end

-- Who looks at the tab: the King (the treasury, all of it, and his switches), a keeper (the
-- treasury, all of it, his own book's lines his to count), a member (what the King shows).
function Treasury.Role()
	if IsKingView() then return "king" end
	if Treasury.IsKeeper() then return "keeper" end
	return "member"
end

-- What a role may see: everything for the keepers and the King, the King's switches for the army.
function Treasury.MaySee(what)
	return Treasury.Role() ~= "member" or Treasury.Shows(what)
end

-- How many keep a book: the Treasurer's characters and the King always, and the King's list.
local function KeeperCount() return #ns.TREASURER_CHARACTERS + 1 + #Treasury.Keepers() end

-- A keeper's name as the tab shows it (the army's name for the King).
local function KeeperLabel(name)
	if ns.KingDisplaySet() and ns.IsKingCharacter(name) then return ns.KING_NAME end
	return ns.DisplayName(name) or tostring(name)
end

-- The donors of the ranking a search finds (`q`, folded: Views.Query), each with its place in
-- the whole ranking; all of them without one. The ranking's first RANK_SENT only, as ever.
local function RankFound(rank, q)
	local out = {}
	for i = 1, math.min(#rank, Treasury.RANK_SENT) do
		if ns.Holds(q, rank[i].name) then out[#out + 1] = i end
	end
	return out
end

-- `q`: the tab's search (the donors it finds, RankFound, a page at a time as ever).
local function RankLines(lines, rank, q)
	local found = RankFound(rank, q)
	-- (1.1.2: why the ranking reads lower than on the Treasurer's screen, the answer bank's.)
	lines[#lines + 1] = { header = true, text = L.TREASURY_RANKING, tooltip = function(tt)
		tt:AddLine(L.TREASURY_RANKING, 1, 0.82, 0)
		if ns.Answers and ns.Answers.WhyTip then ns.Answers.WhyTip(tt, "count-treasury-donors") end
	end }
	if #rank == 0 then lines[#lines + 1] = { text = Grey(L.TREASURY_NONE) } end
	local n = #found
	for k = 1, math.min(n, rankShown) do
		local i = found[k]
		local g = rank[i]
		lines[#lines + 1] = { indent = 1, text = (i <= 3 and Gold or tostring)(("%d. %s"):format(i, g.name)), right = Treasury.Coins(g.money) }
	end
	if n > rankShown then
		lines[#lines + 1] = { indent = 1, text = Grey(L.SHOW_MORE:format(math.min(Treasury.RANK_PAGE, n - rankShown), rankShown, n)),
			onClick = function() rankShown = rankShown + Treasury.RANK_PAGE; ns.Fire("TREASURY_CHANGED") end }
	end
end

-- The early supporters (everyone who gave before 1.0): their names alone, in alphabetical
-- order, a few to a row, 60 more a click. Nothing while this client has no list.
local function EarlyLines(lines)
	local list = Treasury.EarlySupporters()
	if not list then return false end
	local names = list.names
	lines[#lines + 1] = { header = true, text = L.TREASURY_EARLY, tooltip = function(tt) tt:AddLine(L.TREASURY_EARLY_TIP, 1, 1, 1, true) end }
	Para(lines, L.TREASURY_EARLY_HINT:format(#names))
	local shown = math.min(#names, earlyShown)
	local row = ""
	for i = 1, shown do
		local name = names[i] .. (i < shown and "," or "")
		if row ~= "" and #row + 1 + #name > 58 then
			lines[#lines + 1] = { indent = 1, text = row }
			row = name
		else
			row = row == "" and name or (row .. " " .. name)
		end
	end
	if row ~= "" then lines[#lines + 1] = { indent = 1, text = row } end
	if #names > shown then
		lines[#lines + 1] = { indent = 1, text = Grey(L.SHOW_MORE:format(math.min(Treasury.EARLY_SHOWN, #names - shown), shown, #names)),
			onClick = function() earlyShown = earlyShown + Treasury.EARLY_SHOWN; ns.Fire("TREASURY_CHANGED") end }
	end
	return true
end

-- The items donated: each item, how many, and who gave it last (its tooltip, the item's own).
local function ItemLines(lines, items)
	lines[#lines + 1] = { header = true, text = L.TREASURY_ITEMS }
	if #items == 0 then lines[#lines + 1] = { text = Grey(L.TREASURY_NONE) } end
	for i = 1, math.min(#items, Treasury.ITEMS_SHOWN) do
		local it = items[i]
		local names = {}
		for k, d in ipairs(it.donors or {}) do names[k] = d.name end
		local latest = #names > 0 and L.TREASURY_ITEMS_LATEST:format(table.concat(names, ", ")) or nil
		lines[#lines + 1] = { indent = 1, text = ItemText(it.id) .. (latest and ("  " .. Grey("(" .. latest .. ")")) or ""), right = Green(it.n .. "x"),
			tooltip = function(tt)
				if not (tt.SetItemByID and pcall(tt.SetItemByID, tt, it.id)) then tt:AddLine(ItemName(it.id), 1, 0.82, 0) end
				tt:AddLine(L.TREASURY_ITEMS_COUNT:format(it.n), 1, 1, 1)
				if latest then tt:AddLine(latest .. (it.t and it.t > 0 and (", " .. ns.Ago(it.t)) or ""), 0.8, 0.8, 0.8, true) end
			end }
	end
	if #items > Treasury.ITEMS_SHOWN then lines[#lines + 1] = { indent = 1, text = Grey(L.TREASURY_ITEMS_MORE:format(#items - Treasury.ITEMS_SHOWN)) } end
end

local KIND_NOTE = { sale = "TREASURY_KIND_SALE", purchase = "TREASURY_KIND_PURCHASE", own = "TREASURY_KIND_OWN" }

-- A line of the book: who gave it and who received it, why it is not counted first (the row is
-- cut at its end), in the tooltip too. The keeper's own lines are his to count (a click).
local function BookRow(w, clickable)
	local e = w.e
	local how = e.how == "mail" and L.TREASURY_MAIL or L.TREASURY_TRADE
	local keeper = KeeperLabel(w.keeper)
	local label = e.out and L.TREASURY_FROM_TO:format(keeper, e.name) or L.TREASURY_FROM_TO:format(e.name, keeper)
	if e.item then label = label .. ": " .. ItemText(e.item, e.count) end
	local transfer = e.kind == "transfer"
	local note = e.excluded and (e.returned and L.TREASURY_KIND_RETURNED or L[KIND_NOTE[e.kind] or "TREASURY_NOT_COUNTED"])
		or (transfer and L.TREASURY_KIND_TRANSFER) or nil
	local amount = e.item and ((tonumber(e.count) or 1) .. "x") or Treasury.Coins(e.money)
	local sign = e.out and "-" or "+"
	local when = how .. ", " .. ns.Ago(e.t)
	local right
	if e.excluded then right = Grey(amount)
	elseif transfer then right = Grey(sign .. amount)
	else right = e.out and Red(sign .. amount) or Green(sign .. amount) end
	return {
		indent = 1,
		text = ((e.excluded or transfer) and Grey(label) or label) .. "  " .. Grey("(" .. (note and (note .. ", ") or "") .. when .. ")"),
		right = right,
		onClick = clickable and function() Treasury.Toggle(e, w.b) end or nil,
		tooltip = clickable and function(tt)
			tt:AddLine(label .. "  " .. amount, 1, 0.82, 0)
			tt:AddLine(note and (note .. ", " .. when) or when, 0.8, 0.8, 0.8, true)
			tt:AddLine(e.excluded and L.TREASURY_CLICK_COUNT or L.TREASURY_CLICK_UNCOUNT, 1, 1, 1, true)
		end or nil,
	}
end

-- The book: in and out, newest first, every keeper's lines together (his own, each one a click
-- to count or not; the others' as their books last carried them), 40 more a click. `q`, the
-- tab's search (Views.Query): the way back, then only the lines whose donor (or whoever was
-- paid) holds it, a page at a time as ever, under the book's header; "No match" for none.
local function BookLines(role, q)
	local lines = { { text = Gold("< " .. L.TREASURY_TITLE), onClick = function() Treasury.Show("summary") end, gapAfter = true } }
	local r = Treasury.Report()
	local book = {}
	-- (Each line with its keeper, BookRow: the donor, or whoever was paid, is its entry's name.)
	for _, w in ipairs(r and r.book or {}) do
		if ns.Holds(q, w.e and w.e.name) then book[#book + 1] = w end
	end
	if q and #book == 0 then
		lines[#lines + 1] = { text = Grey(L.SEARCH_NO_MATCH) }
		return lines
	end
	lines[#lines + 1] = { header = true, text = L.TREASURY_BOOK }
	if Treasury.IsKeeper() and not q then
		Para(lines, L.TREASURY_BOOK_HOW)
		lines[#lines].gapAfter = true
	end
	if #book == 0 then lines[#lines + 1] = { text = Grey(L.TREASURY_NONE) } end
	for i = 1, math.min(#book, bookShown) do lines[#lines + 1] = BookRow(book[i], book[i].own and Treasury.IsKeeper()) end
	if #book > bookShown then
		lines[#lines + 1] = { text = Gold("> " .. L.TREASURY_OLDER:format(#book - bookShown)), onClick = function()
			bookShown = bookShown + Treasury.BOOK_SHOWN
			ns.Fire("TREASURY_CHANGED")
		end }
	end
	return lines
end

-- The keepers: the Treasurer and the King always, the characters the King added (his to add
-- and remove), each with his book's balance and when it came.
local function KeeperLines()
	local lines = { { text = Gold("< " .. L.TREASURY_TITLE), onClick = function() Treasury.Show("summary") end, gapAfter = true } }
	lines[#lines + 1] = { header = true, text = L.TREASURY_KEEPERS }
	Para(lines, L.TREASURY_KEEPERS_HINT:format(Treasury.MAX_KEEPERS))
	lines[#lines].gapAfter = true
	local r = Treasury.Report()
	local function Heard(name)
		for _, k in ipairs(r and r.keepers or {}) do
			if SameChar(k.name, name) then return k end
		end
	end
	local function Row(name, label, extra)
		local k = Heard(name)
		local line = { indent = 1, text = label, right = k and Treasury.GoldText(k.balance) or Grey(L.TREASURY_KEEPER_NOT_YET) }
		if k and not k.own then line.text = line.text .. "  " .. Grey("(" .. ns.Ago(k.t) .. ")") end
		for key, v in pairs(extra or {}) do line[key] = v end
		lines[#lines + 1] = line
	end
	Row(ns.FullName(ns.TREASURER, ns.TREASURER_REALM), L.TREASURY_KEEPER_TREASURER:format(ns.TREASURER), {
		tooltip = function(tt) tt:AddLine(L.TREASURY_KEEPER_PINNED, 1, 1, 1, true) end })
	-- His mail character: his, pinned like him (not the King's to take off).
	for _, pin in ipairs(ns.TREASURER_CHARACTERS) do
		if pin ~= ns.TREASURER then
			Row(ns.FullName(pin, ns.TREASURER_REALM), L.TREASURY_KEEPER_TREASURER_MAIL:format(pin), {
				tooltip = function(tt) tt:AddLine(L.TREASURY_KEEPER_PINNED, 1, 1, 1, true) end })
		end
	end
	local king = ns.KingCharacter and ns.KingCharacter()
	if king then
		Row(ns.FullName(king, ns.KingRealm and ns.KingRealm()), L.TREASURY_KEEPER_KING:format(ns.KingName(king)), {
			tooltip = function(tt) tt:AddLine(L.TREASURY_KEEPER_PINNED, 1, 1, 1, true) end })
	end
	local mine = IsKingView()
	local listed = Treasury.Keepers()
	for _, name in ipairs(listed) do
		Row(name, ns.DisplayName(name), mine and {
			key = name,
			onClick = function() ns.ShowDialog("SYLVANISTAS_TREASURY_UNKEEP", ns.DisplayName(name), nil, name) end,
			tooltip = function(tt) tt:AddLine(ns.DisplayName(name), 1, 0.82, 0); tt:AddLine(L.TREASURY_KEEPER_CLICK_REMOVE, 1, 1, 1, true) end,
		} or nil)
	end
	if #listed == 0 then lines[#lines + 1] = { indent = 1, text = Grey(L.TREASURY_KEEPER_NONE) } end
	if mine then
		lines[#lines].gapAfter = true
		lines[#lines + 1] = { text = Gold("+ " .. L.TREASURY_KEEPER_ADD), onClick = function() ns.ShowDialog("SYLVANISTAS_TREASURY_KEEPER") end }
	end
	return lines
end

-- The guild bank of <Sylvanistas> as last seen (Bank.lua): its gold, then each tab's items in a
-- grid. The keepers and the King always; the army with the King's "book" switch.
-- Who sees the guild bank: the keepers and the King always, the army with the King's "book".
local function BankVisible(role) return role ~= "member" or Treasury.Shows("book") end

local function BankLines(lines, role)
	if role == "member" and not Treasury.Shows("book") then return end
	local b = ns.Bank and ns.Bank.Current and ns.Bank.Current()
	lines[#lines + 1] = { header = true, text = L.TREASURY_BANK, tooltip = function(tt) tt:AddLine(L.TREASURY_BANK_TIP, 1, 1, 1, true) end }
	if not b then
		-- A client without the guild bank's functions can't take a snapshot: said, not left blank.
		Para(lines, (ns.Bank and ns.Bank.HasAPI and not ns.Bank.HasAPI()) and L.TREASURY_BANK_NO_API or L.TREASURY_BANK_NONE)
		return
	end
	lines[#lines + 1] = { text = Grey(L.TREASURY_BANK_AS_OF:format(ns.DisplayName(b.by) or "?", ns.Ago(b.t))) }
	lines[#lines + 1] = { text = L.TREASURY_BANK_GOLD, right = Treasury.Coins(b.money or 0) }
	-- 1.1: what left the bank since the snapshot before (counts only, never who: the bank's log is
	-- never read), and in the grid the slots those stacks sat in, faded.
	local prev = ns.Bank.Previous and ns.Bank.Previous(b)
	local gone, ghosts = {}, {}
	if prev then gone, ghosts = ns.Bank.Gone(b, prev) end
	if #gone > 0 then
		lines[#lines + 1] = { text = Red(L.BANK_GONE:format(ns.Ago(prev.t))), tooltip = function(tt)
			tt:AddLine(L.BANK_GONE_TITLE, 1, 0.82, 0)
			tt:AddLine(L.BANK_GONE_TIP:format(ns.DisplayName(prev.by) or "?"), 1, 1, 1, true)
		end }
		for i = 1, math.min(#gone, Treasury.BANK_LISTED) do
			local x = gone[i]
			lines[#lines + 1] = { indent = 1, text = ItemText(x.id) .. "  " .. Grey("(" .. table.concat(x.tabs, ", ") .. ")"), right = Red("-" .. x.n .. "x"),
				tooltip = function(tt)
					if not (tt.SetItemByID and pcall(tt.SetItemByID, tt, x.id)) then tt:AddLine(ItemName(x.id), 1, 0.82, 0) end
					tt:AddLine(L.BANK_GONE_TITLE, 1, 0.4, 0.4, true)
				end }
		end
		if #gone > Treasury.BANK_LISTED then lines[#lines + 1] = { indent = 1, text = Grey(L.TREASURY_ITEMS_MORE:format(#gone - Treasury.BANK_LISTED)) } end
	end
	-- One tab open at a time, as the bank shows them: its slots, every one, items where they sit.
	local open = Treasury.bankTab
	if not (open and b.tabs[open]) then
		open = 1
		for i, tab in ipairs(b.tabs or {}) do if #tab.items > 0 then open = i break end end
	end
	for i, tab in ipairs(b.tabs or {}) do
		local count = #tab.items > 0 and L.TREASURY_BANK_ITEMS:format(#tab.items) or L.TREASURY_BANK_EMPTY
		lines[#lines + 1] = { text = (i == open and Gold or tostring)((i == open and "[-] " or "[+] ") .. (tab.name or "?")), right = Grey(count),
			key = "banktab" .. i, onClick = function() Treasury.bankTab = i; ns.Fire("TREASURY_CHANGED") end }
		if i == open then
			local items = tab.items
			if ghosts[i] then
				items = {}
				for _, it in ipairs(tab.items) do items[#items + 1] = it end
				for _, it in ipairs(ghosts[i]) do items[#items + 1] = it end
			end
			local ask = ns.Bank.MayRequest and ns.Bank.MayRequest()
			lines[#lines + 1] = { items = items, slots = ns.Bank.SLOTS, columns = 7,
				onItem = ask and function(it) ns.Bank.RequestPrompt(it.id) end or nil, itemHint = ask and L.BANK_REQUEST_CLICK or nil }
		end
	end
	lines[#lines].gapAfter = true
end

-- 1.1: requests to the treasury (Bank.lua), next to the bank. A keeper, the King or a Steward: every
-- request his client holds, a click to mark it done or declined, what the bank holds of it. The army
-- (with the King's book): the open ones the keepers put on the channel. A Lord or a Captain: his own,
-- where each stands (a click takes it back), and a line to ask for any item.
local function RequestLines(lines, role)
	local B = ns.Bank
	if not (B and B.Requests) then return end
	local rows = {}
	local function Holds(item)
		local n = B.Holds(item)
		return n and Grey(L.BANK_REQUEST_HOLDS:format(n)) or ""
	end
	if Treasury.IsInsider() then
		for _, e in ipairs(B.Requests()) do
			local open = e.state == "open"
			local who = L.BANK_REQUEST_WHO:format(ns.DisplayName(e.from) or "?", e.guild or "?")
			rows[#rows + 1] = { indent = 1, text = (open and tostring or Grey)(who .. ": " .. ItemText(e.item, e.n)),
				right = open and Holds(e.item) or Grey(B.StateText({ state = e.state, by = e.by })),
				key = "request:" .. e.key,
				onClick = open and function() ns.ShowDialog("SYLVANISTAS_BANK_REQUEST_ANSWER", who, ItemText(e.item, e.n), e.key) end or nil,
				tooltip = function(tt)
					tt:AddLine(who, 1, 0.82, 0)
					tt:AddLine(ItemText(e.item, e.n) .. ", " .. ns.Ago(e.t), 1, 1, 1, true)
					if open then tt:AddLine(L.BANK_REQUEST_CLICK_ANSWER, 0.6, 1, 0.6, true) end
				end }
		end
	elseif BankVisible(role) then
		for _, e in ipairs(B.PublicRequests()) do
			rows[#rows + 1] = { indent = 1, text = L.BANK_REQUEST_WHO:format(ns.DisplayName(e.from) or "?", e.guild) .. ": " .. ItemText(e.item, e.n), right = Holds(e.item) }
		end
	end
	local mine = B.MyRequests()
	local ask = B.MayRequest()
	if #rows == 0 and #mine == 0 and not ask then return end
	if #rows > 0 then
		lines[#lines + 1] = { header = true, text = L.BANK_REQUESTS, tooltip = function(tt) tt:AddLine(L.BANK_REQUESTS_TIP, 1, 1, 1, true) end }
		for _, r in ipairs(rows) do lines[#lines + 1] = r end
		lines[#lines].gapAfter = true
	end
	if #mine > 0 or ask then
		lines[#lines + 1] = { header = true, text = L.BANK_MY_REQUESTS, tooltip = function(tt) tt:AddLine(L.BANK_REQUESTS_TIP, 1, 1, 1, true) end }
		for _, e in ipairs(mine) do
			local open = e.state == "sent" or e.state == "seen"
			lines[#lines + 1] = { indent = 1, text = ItemText(e.item, e.n), right = (open and tostring or Grey)(B.StateText(e)),
				onClick = open and function() ns.ShowDialog("SYLVANISTAS_BANK_REQUEST_CANCEL", ItemText(e.item, e.n), nil, e.id) end or nil }
		end
		if ask then lines[#lines + 1] = { text = Gold("+ " .. L.BANK_REQUEST_NEW_LINE), onClick = function() B.RequestPrompt() end } end
		lines[#lines].gapAfter = true
	end
end

-- 1.1: the sister guilds' banks (Bank.lua), for the King, his Steward and his Hands: each guild
-- a click to open, then its tabs ("Tab 1": their names are left out), one open at a time.
local function SisterLines(lines)
	if not (ns.Bank and ns.Bank.SeesSisters and ns.Bank.SeesSisters()) then return end
	local list = ns.Bank.Sisters()
	if #list == 0 then return end
	lines[#lines + 1] = { header = true, text = L.BANK_SISTERS, tooltip = function(tt) tt:AddLine(L.BANK_SISTERS_TIP, 1, 1, 1, true) end }
	for _, s in ipairs(list) do
		local opened = Treasury.sisterOpen == s.guild
		lines[#lines + 1] = { text = (opened and Gold or tostring)((opened and "[-] " or "[+] ") .. "<" .. s.guild .. ">"), right = Treasury.Coins(s.money or 0),
			key = "sister:" .. s.guild, onClick = function()
				Treasury.sisterOpen, Treasury.sisterTab = (not opened) and s.guild or nil, nil
				ns.Fire("TREASURY_CHANGED")
			end }
		if opened then
			lines[#lines + 1] = { indent = 1, text = Grey(L.TREASURY_BANK_AS_OF:format(ns.DisplayName(s.by) or "?", ns.Ago(s.t))) }
			local open = Treasury.sisterTab
			if not (open and s.tabs[open]) then
				open = 1
				for i, tab in ipairs(s.tabs) do if #tab.items > 0 then open = i break end end
			end
			for i, tab in ipairs(s.tabs) do
				local count = #tab.items > 0 and L.TREASURY_BANK_ITEMS:format(#tab.items) or L.TREASURY_BANK_EMPTY
				lines[#lines + 1] = { indent = 1, text = (i == open and Gold or tostring)((i == open and "[-] " or "[+] ") .. tab.name), right = Grey(count),
					key = "sistertab" .. i, onClick = function() Treasury.sisterTab = i; ns.Fire("TREASURY_CHANGED") end }
				if i == open then lines[#lines + 1] = { items = tab.items, slots = ns.Bank.SLOTS, columns = 7 } end
			end
		end
	end
	lines[#lines].gapAfter = true
end

-- 1.1: the stacks of a bank whose item holds the search `q` (Bank.Find): each item once, how many
-- in all, in which tabs; a click opens the first of them. Returns whether any.
local function FoundLines(lines, title, snap, q, open)
	local found = ns.Bank.Find(snap, q)
	if #found == 0 then return false end
	lines[#lines + 1] = { header = true, text = title }
	for i = 1, math.min(#found, Treasury.BANK_LISTED) do
		local x = found[i]
		lines[#lines + 1] = { indent = 1, text = ItemText(x.id) .. "  " .. Grey("(" .. table.concat(x.tabs, ", ") .. ")"), right = Green(x.n .. "x"),
			onClick = open and function() open(x.tabs[1]) end or nil,
			tooltip = function(tt)
				if not (tt.SetItemByID and pcall(tt.SetItemByID, tt, x.id)) then tt:AddLine(ItemName(x.id), 1, 0.82, 0) end
				tt:AddLine(L.BANK_FOUND_TIP:format(x.stacks, table.concat(x.tabs, ", ")), 1, 1, 1, true)
			end }
	end
	if #found > Treasury.BANK_LISTED then lines[#lines + 1] = { indent = 1, text = Grey(L.TREASURY_ITEMS_MORE:format(#found - Treasury.BANK_LISTED)) } end
	lines[#lines].gapAfter = true
	return true
end
local function BankFound(lines, role, q)
	local any = false
	local b = BankVisible(role) and ns.Bank and ns.Bank.Current and ns.Bank.Current()
	if b and FoundLines(lines, L.TREASURY_BANK, b, q, function(name)
		for i, tab in ipairs(b.tabs) do if tab.name == name then Treasury.bankTab = i end end
		ns.Fire("TREASURY_CHANGED")
	end) then any = true end
	for _, s in ipairs(ns.Bank and ns.Bank.SeesSisters and ns.Bank.SeesSisters() and ns.Bank.Sisters() or {}) do
		if FoundLines(lines, L.BANK_SISTER_OF:format(s.guild), s, q) then any = true end
	end
	return any
end
Treasury.BANK_LISTED = 25   -- items found, or gone, listed (the rest counted)

-- The summary while the tab's search holds `q`: the donors it finds in the ranking, the bank's
-- items (1.1: and the sister guilds', for the King, his Steward and his Hands), "No match" for
-- none, and the way to the book (searched there too). Nothing else.
local function SummarySearch(role, q)
	local r = Treasury.Report()
	local rank = r and r.rank or {}
	local lines = {}
	local any = false
	if Treasury.MaySee("ranking") and #RankFound(rank, q) > 0 then
		RankLines(lines, rank, q)
		lines[#lines].gapAfter = true
		any = true
	end
	if BankFound(lines, role, q) then any = true end
	if not any then lines[#lines + 1] = { text = Grey(L.SEARCH_NO_MATCH), gapAfter = true } end
	if Treasury.MaySee("book") then
		lines[#lines + 1] = { text = Gold("> " .. L.TREASURY_BOOK), onClick = function() Treasury.Show("book") end, gapAfter = true }
	end
	return lines
end

local function SummaryLines(role, q)
	if q then return SummarySearch(role, q) end
	local lines = { { header = true, text = L.TREASURY_TITLE } }
	-- 1.1: the week's dues first (Dues.lua): the way to them, for whoever may see them, and the
	-- button that fills in a member's own payment. A member the King shows nothing sees that alone.
	ns.Dues.SummaryLines(lines, role)
	if role == "member" and not Treasury.AnyShown() then return lines end
	local keeper = Treasury.IsKeeper()
	if keeper then
		Para(lines, Treasury.WhoSees(), tostring)
		lines[#lines].gapAfter = true
		Para(lines, L.TREASURY_HOW)
		lines[#lines].gapAfter = true
	end
	-- 1.1: who is taking donations now, and a keeper's own switch for it.
	local taking = Treasury.DonationLines()
	for _, l in ipairs(taking) do lines[#lines + 1] = l end
	if RealKeeper() then
		local on = Treasury.TakingDonations()
		lines[#lines + 1] = { text = Gold((on and "[x] " or "[ ] ") .. L.DONATIONS_SWITCH), right = Grey(on and L.DONATIONS_SWITCH_ON or L.DONATIONS_SWITCH_OFF),
			key = "donations", onClick = function() Treasury.SetDonations(not Treasury.TakingDonations()) end,
			tooltip = function(tt)
				tt:AddLine(L.DONATIONS_SWITCH, 1, 0.82, 0)
				tt:AddLine(L.DONATIONS_SWITCH_TIP, 1, 1, 1, true)
			end }
	end
	if #taking > 0 or RealKeeper() then lines[#lines].gapAfter = true end
	-- 1.1: a keeper's backup of his book (and his settings), and the way back (Backup.lua).
	if RealKeeper() and ns.Backup then
		lines[#lines + 1] = { text = Gold("> " .. L.BACKUP_LINK), onClick = function() ns.Backup.Slash("backup") end,
			tooltip = function(tt) tt:AddLine(L.HELP_BACKUP, 1, 1, 1, true) end }
		lines[#lines + 1] = { text = Gold("> " .. L.BACKUP_RESTORE_LINK), onClick = function() ns.Backup.Slash("restore") end, gapAfter = true }
	end
	-- 1.1: the King, a Steward or a keeper still on 1.0, heard lately, while the King hides a part.
	if Treasury.IsInsider() and not select(2, Treasury.PublicParts()) then
		local old = {}
		for _, name in ipairs(Treasury.NotUpdated()) do old[#old + 1] = KeeperLabel(name) end
		if #old > 0 then
			Para(lines, L.TREASURY_NOT_UPDATED:format(table.concat(old, ", ")), Red)
			lines[#lines].gapAfter = true
		end
	end
	local r = Treasury.Report()
	if not r then
		-- Nothing from the keepers yet: the King sees the sections waiting (the ranking empty),
		-- and the bank if anyone has seen it.
		Para(lines, L.TREASURY_WAIT)
		lines[#lines].gapAfter = true
		if role ~= "member" then
			RankLines(lines, {})
			lines[#lines].gapAfter = true
			if EarlyLines(lines) then lines[#lines].gapAfter = true end
			lines[#lines + 1] = { text = Gold("> " .. L.TREASURY_KEEPERS_LINK:format(KeeperCount())), onClick = function() Treasury.Show("keepers") end, gapAfter = true }
		end
		BankLines(lines, role)
		RequestLines(lines, role)
		SisterLines(lines)
		return lines
	end
	-- 1.1: a keeper's book this client holds only as the army sees it (the channel's copy): its
	-- whole one comes by whisper once his addon hears ours.
	if role ~= "member" then
		local waiting = {}
		for _, k in ipairs(r.keepers) do if k.part then waiting[#waiting + 1] = KeeperLabel(k.name) end end
		if #waiting > 0 then
			Para(lines, L.TREASURY_PART_WAIT:format(table.concat(waiting, ", ")))
			lines[#lines].gapAfter = true
		end
	end
	if Treasury.MaySee("balance") then
		lines[#lines + 1] = { text = Gold(L.TREASURY_BALANCE), right = Treasury.Coins(r.balance) }
		lines[#lines + 1] = { text = L.TREASURY_IN_OUT, right = Green("+" .. Treasury.Coins(r.allIn)) .. "  " .. Red("-" .. Treasury.Coins(r.allOut)) }
		lines[#lines + 1] = { text = L.TREASURY_WEEK:format(r.donors), right = Green("+" .. Treasury.Coins(r.week)),
			-- (1.1.2: counted per keeper, the answer bank says why that can differ.)
			tooltip = function(tt)
				tt:AddLine(L.TREASURY_WEEK:format(r.donors), 1, 0.82, 0)
				if ns.Answers and ns.Answers.WhyTip then ns.Answers.WhyTip(tt, "count-treasury-donors") end
			end }
		if keeper then
			lines[#lines + 1] = { text = Grey(L.TREASURY_OPENING:format(Treasury.Coins(Treasury.Opening()))),
				onClick = function() ns.ShowDialog("SYLVANISTAS_TREASURY_OPENING") end,
				tooltip = function(tt) tt:AddLine(L.TREASURY_OPENING_TIP, 1, 1, 1, true) end }
		end
		-- Whose books make it, each one's balance and when it came.
		for _, k in ipairs(r.keepers) do
			lines[#lines + 1] = { indent = 1, text = Grey(L.TREASURY_KEPT_BY:format(KeeperLabel(k.name), k.own and L.TREASURY_KEPT_NOW or ns.Ago(k.t))),
				right = Grey(Treasury.GoldText(k.balance)) }
		end
		lines[#lines].gapAfter = true
	end
	if Treasury.MaySee("ranking") then
		RankLines(lines, r.rank)
		lines[#lines].gapAfter = true
		-- Who gave before 1.0: with the ranking, for whoever may see it.
		if EarlyLines(lines) then lines[#lines].gapAfter = true end
	end
	if Treasury.MaySee("book") then
		ItemLines(lines, r.items)
		lines[#lines].gapAfter = true
		lines[#lines + 1] = { text = Gold("> " .. L.TREASURY_BOOK), onClick = function() Treasury.Show("book") end, gapAfter = true }
	end
	-- The keepers: the King's to name, theirs to see.
	if role ~= "member" then
		lines[#lines + 1] = { text = Gold("> " .. L.TREASURY_KEEPERS_LINK:format(KeeperCount())), onClick = function() Treasury.Show("keepers") end, gapAfter = true }
	end
	BankLines(lines, role)
	RequestLines(lines, role)
	SisterLines(lines)
	-- The King: what the army sees now (the switches are the buttons in the box).
	if role == "king" then
		local shown = ShownParts()
		lines[#lines + 1] = { text = Grey(#shown > 0 and L.TREASURY_ARMY_SEES:format(table.concat(shown, ", ")) or L.TREASURY_ARMY_SEES_NOTHING) }
	end
	return lines
end

-- `q`: the tab's search (Views.Query), for the ranking and the book; nil for none.
function Treasury.Build(q)
	local role = Treasury.Role()
	if Treasury.mode == "book" and not Treasury.MaySee("book") then Treasury.mode = "summary" end
	if Treasury.mode == "keepers" and role == "member" then Treasury.mode = "summary" end
	-- 1.1: the week's dues (Dues.lua), for whoever may see them.
	if Treasury.mode == "dues" and not ns.Dues.Sees() then Treasury.mode = "summary" end
	if Treasury.mode == "dues" then return ns.Dues.Build(q) end
	local lines
	if Treasury.mode == "book" then lines = BookLines(role, q)
	elseif Treasury.mode == "keepers" then lines = KeeperLines()
	else lines = SummaryLines(role, q) end
	local detail = role == "king" and (ns.King.IsSteward() and L.TREASURY_DETAIL_STEWARD or L.TREASURY_DETAIL_KING)
		or role == "keeper" and L.TREASURY_DETAIL_TREASURER or L.TREASURY_DETAIL_MEMBER
	return lines, L.TAB_TREASURY, detail
end

-- A list of donors shows on the tab (the book, or the ranking): its search box too (Views.lua).
function Treasury.Searchable()
	if Treasury.mode == "keepers" then return false end
	if Treasury.mode == "dues" then return ns.Dues.Sees() == true end
	if Treasury.mode == "book" and Treasury.MaySee("book") then return true end
	-- (1.1: the bank's items too, and the sister guilds'.)
	if BankVisible(Treasury.Role()) or (ns.Bank and ns.Bank.SeesSisters and ns.Bank.SeesSisters() and #ns.Bank.Sisters() > 0) then return true end
	return Treasury.MaySee("ranking")
end

-- For Discord, a public place: each book of this account ranked as it leaves this client, never
-- the Treasurer's screen's whole ranking, which grows by each payer's dues every week
-- (PublicRanking; the review of Konig's fixes, 1.1). Other keepers' books as they came (the
-- Treasurer's already so).
function Treasury.DiscordText()
	local r = Treasury.Report(false, true)
	if not r then return "" end
	local out = { ("**%s**"):format(L.TREASURY_TITLE) }
	if Treasury.MaySee("balance") then
		out[#out + 1] = L.TREASURY_BALANCE .. ": " .. Plain(r.balance)
		out[#out + 1] = L.TREASURY_WEEK:format(r.donors) .. ": +" .. Plain(r.week)
	end
	if Treasury.MaySee("ranking") then
		for i = 1, math.min(Treasury.RANK_SENT, #r.rank) do out[#out + 1] = ("%d. %s - %s"):format(i, r.rank[i].name, Plain(r.rank[i].money)) end
	end
	return table.concat(out, "\n")
end

-- The King's Throne Room: the treasury as its keepers last sent it, a click from its tab.
function Treasury.ThroneLines()
	local Line, INK, TITLE = ns.King.Line, ns.King.INK, ns.King.TITLE
	local lines = { Line(L.TREASURY_TITLE, TITLE) }
	local open = function() if ns.UI and ns.UI.SelectTab then ns.UI.SelectTab("treasury") end end
	local r = Treasury.Report()
	if r then
		lines[#lines + 1] = Line(L.TREASURY_BALANCE .. ": " .. Treasury.Coins(r.balance), INK)
		lines[#lines + 1] = Line(L.TREASURY_WEEK:format(r.donors) .. ": +" .. Treasury.Coins(r.week), INK)
		for _, k in ipairs(r.keepers) do
			lines[#lines + 1] = Line(L.TREASURY_KEPT_BY:format(KeeperLabel(k.name), k.own and L.TREASURY_KEPT_NOW or ns.Ago(k.t)), INK)
		end
	else
		ns.King.Para(lines, L.TREASURY_WAIT, INK)
	end
	lines[#lines].gapAfter = true
	lines[#lines + 1] = Line("> " .. L.TREASURY_OPEN, INK, { onClick = open })
	return lines
end

-- Next to the soldiers on top of the window (the Throne and the Treasury tabs): the treasury's
-- balance, for the keepers, the King, and the army when the King shows it.
function Treasury.HeaderText()
	if not (Treasury.IsKeeper() or IsKingView() or Treasury.Shows("balance")) then return nil end
	local r = Treasury.Report()
	if not r then return nil end
	return "|TInterface\\MoneyFrame\\UI-GoldIcon:0|t " .. Treasury.GoldText(r.balance)
end

-- Under the Treasurer in the Realm, for everyone, when the King shows the balance.
function Treasury.RealmText()
	if not Treasury.Shows("balance") then return nil end
	local r = Treasury.Report()
	if not r then return nil end
	return L.TREASURY_REALM:format(Treasury.GoldText(r.balance), ns.Ago(r.t))
end

StaticPopupDialogs["SYLVANISTAS_TREASURY_OPENING"] = {
	text = L.TREASURY_OPENING_PROMPT,
	button1 = OKAY or "OK",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 200,
	maxLetters = 24,
	OnShow = function(self)
		local eb = self.editBox or self.EditBox
		if eb then eb:SetText(""); eb:SetFocus() end
	end,
	OnAccept = function(self)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("treasury opening", Treasury.SetOpening, eb and eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		ns.SafeCall("treasury opening", Treasury.SetOpening, self:GetText())
		self:GetParent():Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- 1.1: the clipboard backup (Backup.lua, Fern's): this character's book, and on the Treasurer's
-- characters the other pinned one's (his account keeps both), and the King's word.
---------------------------------------------------------------------------

-- The books a backup holds, as this client keeps them (lines, sums, opening).
function Treasury.BackupBooks()
	local out = {}
	if not ns.rdb or not ns.me then return out end
	local function Add(name)
		local b = BookOf(name)
		if b and b.epoch == Treasury.EPOCH and b.opening ~= nil then out[#out + 1] = b end
	end
	Add(ns.me)
	if TreasurerPin(ns.me) then
		for _, pin in ipairs(ns.TREASURER_CHARACTERS) do
			local full = ns.FullName(pin, ns.TREASURER_REALM)
			if not SameChar(full, ns.me) then Add(full) end
		end
	end
	return out
end

-- A backup's book goes back only into this character's book, or on the Treasurer's characters into
-- the other pinned one's: never another player's.
function Treasury.MayRestoreBook(name)
	if type(name) ~= "string" or name == "" or not ns.me then return false end
	return SameChar(name, ns.me) or (TreasurerPin(ns.me) ~= nil and TreasurerPin(name) ~= nil)
end

local function LineKey(e)
	return table.concat({ tostring(e.t), tostring(e.name), tostring(e.money), tostring(e.how), tostring(e.item), tostring(e.count), tostring(e.out), tostring(e.kind) }, "\1")
end

-- A backup's book (checked by Backup.lua) into this client's copy of that character's book. Ours
-- fresh (nothing written since it opened, the usual after a wipe): the backup's, whole. Otherwise
-- the backup's book (its opening, its lines, its sums of all time) with the lines ours holds that
-- it doesn't added after it, each counted once. Returns the book and how many of ours were added.
function Treasury.RestoreBook(saved)
	if type(saved) ~= "table" or not Treasury.MayRestoreBook(saved.name) then return nil end
	local b = BookOf(saved.name, true)
	local base = { epoch = Treasury.EPOCH, name = b.name or saved.name, opening = saved.opening, openedAt = saved.openedAt, opened = saved.opened,
		lines = {}, sums = saved.sums }
	for i, e in ipairs(saved.lines or {}) do base.lines[i] = e end
	Sums(base) -- (the backup's own sums, or rebuilt from its lines when they are of another shape)
	local seen, added = {}, 0
	for _, e in ipairs(base.lines) do seen[LineKey(e)] = true end
	for _, e in ipairs(b.lines) do
		if not seen[LineKey(e)] then
			base.lines[#base.lines + 1] = e
			if not e.excluded then Count(base, e, 1) end
			added = added + 1
		end
	end
	table.sort(base.lines, function(x, y) return (tonumber(x.t) or 0) < (tonumber(y.t) or 0) end)
	while #base.lines > Treasury.MAX do table.remove(base.lines, 1) end
	b.opening, b.openedAt, b.opened, b.lines, b.sums = base.opening, base.openedAt, base.opened, base.lines, base.sums
	b.restored = ns.Now()
	Touch(b)
	ns.Fire("TREASURY_CHANGED")
	return b, added
end

-- The King's word from a backup (his client's, or a Steward's): his switches and his keepers, given
-- again as a new word (dated now, as a click gives it), repeated as ever.
function Treasury.RestoreWord(flags, keepers)
	if not ns.King.SetsLists() or not ns.rdb then return false end
	if type(flags) == "table" then
		local prev = ns.rdb.treasuryFlags
		local f = { balance = flags.balance == true, ranking = flags.ranking == true, book = flags.book == true }
		f.t, f.at, f.from = ns.Now(), math.max(Clock(), (type(prev) == "table" and tonumber(prev.at) or 0) + 1), ns.me
		local was = FlagDigits(type(prev) == "table" and prev or {})
		ns.rdb.treasuryFlags = f
		Treasury.SendFlags(true)
		Treasury.SwitchesChanged(was)
	end
	if type(keepers) == "table" then
		local names = {}
		for _, n in ipairs(keepers) do
			local name = KeeperName(n)
			if name and #names < Treasury.MAX_KEEPERS and not PinnedName(name) then names[#names + 1] = name end
		end
		SetKeepers(names)
	end
	ns.Fire("TREASURY_CHANGED")
	ns.Fire("DATA_CHANGED")
	return true
end
Treasury.FlagDigits = FlagDigits

-- Tests start from a clean state.
function Treasury.Reset()
	trade, mailOut, lastShare, sharePending, lastFlagsSent, lastKeepersSent = nil, nil, -math.huge, false, -math.huge, -math.huge
	lastWithdraw = -math.huge
	asked, lastWordAnswer = false, -math.huge
	wipe(pending)
	wipe(itemPending)
	lastMoney, lastRelay = nil, -math.huge
	lastEarlySent, earlySending, earlyPending, earlyCache = -math.huge, nil, nil, nil
	Treasury.ResetPrivate()
	donating, lastDonationSent = nil, -math.huge
	wipe(donors); wipe(pinged)
	earlyAsks, lastEarlyAsk, earlyArmed, heardEarlyAsk = 0, -math.huge, false, -math.huge
	bookShown, rankShown, earlyShown = Treasury.BOOK_SHOWN, Treasury.RANK_PAGE, Treasury.EARLY_SHOWN
	Treasury.mode = "summary"
	if ns.rdb then
		ns.rdb.treasuryReports, ns.rdb.treasuryBooks, ns.rdb.treasuryKeepers, ns.rdb.treasuryArchive = nil, nil, nil, nil
		ns.rdb.treasuryEarly = nil
	end
	if ns.db then ns.db.keeperShares, ns.db.previewTreasuryKeepers = nil, nil end
end
