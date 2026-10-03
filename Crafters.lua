local ADDON, ns = ...
local L = ns.L

-- The crafters' board (1.1, request #24): "On opening a profession they may publish skill and recipe
-- ids. Others whisper with a click. No craft, no auction bids. Do not assume retail
-- specialization trees exist on Forever. 'Who can make this' is currently a chat scroll. A board
-- turns that into one whisper to a named crafter."
--
-- When a player opens one of his professions, Sylvanistas reads it (its skill and the recipes he has
-- learned: their recipe and item ids, nothing else: no specialization tree is read) and asks once,
-- in a window of its own, whether to list it on the board. With his yes the board of every Sylvanistas
-- client on his realm and faction shows him (name, guild, profession and skill), and his addon
-- answers the questions only it can: who can make an item, or which recipes he has. A click on a
-- crafter whispers him (the game's own whisper, the player types it); nothing is crafted, ordered,
-- bought, sold or bid for anyone, and nothing touches the auction house.
--   W1~<guild>~<key>:<profession>:<skill>:<max>:<recipes>,...   a crafter's listing (CHANNEL; at
--                                                   his yes and after a change, then every 45 min)
--   W0~                                              he unlisted every profession (CHANNEL)
--   WQ~<ask>~i~<item id> | WQ~<ask>~t~<words>        "who can make this?" (CHANNEL, on a click)
--   WA~<ask>~<guild>~<profession>~<skill>~<recipe>:<item>,...   a listed crafter's answer:
--                                                   the recipes that make it (WHISPER to the asker)
--   WR~<key>                                         "which recipes do you have?" (WHISPER)
--   WL~<key>~<part>/<parts>~<recipe>:<item>,...      his recipes of that profession (WHISPER, a
--                                                   part each LIST_PACE); WL~<key>~0/0~: he is busy
-- Ids travel as numbers; each client names them itself (the item's name in its own language).
-- Versions before 1.1 have no handler for these and drop them.
-- A crafter the moderators took off (net-off, Moderation.lua; 1.1, review): his listing,
-- answers and recipe lists are not taken, what a client heard of him before the word shows no
-- more, and his own client sends none of them (Moderation.BLOCKED: W1, WA, WL).

local Crafters = {}
ns.Crafters = Crafters

Crafters.LIST_EVERY = 45 * 60      -- a listing is repeated this often while the player plays...
Crafters.LIST_KEEP = 100 * 60      -- ...and shows this long after it was last heard
Crafters.LIST_GAP = 10 * 60        -- a listing whose skill or recipes changed this often at most (Crafters.SendListing)
Crafters.BOARD_MAX = 400           -- crafters on the board
Crafters.PROFS_MAX = 4             -- professions a listing carries
Crafters.ASK_GAP = 15              -- our asks: one each 15 seconds...
Crafters.ASKS_PER_10MIN = 12       -- ...and 12 each 10 minutes
Crafters.ASK_WAIT = 120            -- answers to our ask are taken this long
Crafters.ANSWERS_MAX = 30          -- ...this many at most
Crafters.MATCHES_MAX = 6           -- recipes an answer names
Crafters.ANSWER_PER_MIN = 10       -- a crafter answers this many asks a minute at most...
Crafters.ANSWER_SAME = 30          -- ...the same asker once each 30 seconds
Crafters.LISTS_PER_MIN = 4         -- recipe lists sent a minute at most...
Crafters.LIST_SAME = 120           -- ...to the same player once each 2 minutes
Crafters.LIST_BYTES = 220          -- bytes of recipes in one message of a list (ids and a separator each)...
Crafters.LIST_PARTS = 16           -- ...and parts of a list at most (some 250 recipes)
Crafters.LIST_PER_MSG = 40         -- recipes a part may carry, at most, as a reader takes it
-- (1.1 review: every part of four lists a minute went into our one send queue at once, 64 messages
-- where it holds 60 and sends 50 a minute, and the oldest, our census pieces, were dropped.)
Crafters.LIST_PACE = 6             -- one part of a list each 6 seconds (10 a minute), whoever asked...
Crafters.LIST_QUEUE = 10           -- ...while our send queue holds this many at most (else it waits)
Crafters.LIST_JOBS = 2             -- lists going out or waiting their turn; beyond, the asker is told we are busy
Crafters.BUSY_PER_MIN = 4          -- such answers a minute at most
Crafters.BUSY_WAIT = 60            -- the asker may ask again this soon after
Crafters.random = math.random
Crafters.after = function(seconds, where, fn) ns.After(seconds, where, fn) end

local board = {}        -- [sender] = { guild, profs = { { key, name, rank, max, n } }, t }
local boardCount = 0
local myAsk             -- our last ask: { id, t, label, item, answers = { [sender] = { guild, prof, rank, recipes } }, count }
local askTimes = {}     -- our asks' times (the last 10 minutes)
local askCounter = 0
local answered = {}     -- [asker] = when we last answered him
local answerTimes = {}  -- our answers' times (the last minute)
local listSent = {}     -- [player] = when we last sent him a list
local listTimes = {}
local listJobs = {}     -- { { to, key, parts, i, stalls } }: our lists going out, a part each LIST_PACE
local listPumping = false
local busyTimes = {}    -- our "busy" answers' times (the last minute)
local lists = {}        -- [crafter .. "~" .. key] = { parts = {}, n, t, recipes }: lists asked for
local asked = {}        -- [crafter .. "~" .. key] = when we asked
local lastListing, lastListingText = -math.huge, nil
local open = {}         -- [crafter] = true: shown opened on the page
local pendingRead       -- a profession read waiting for its data
local questioned = {}   -- [key] = true: asked this session (once, until answered: a closed window is no answer)

local function Grey(s) return "|cff9d9d9d" .. s .. "|r" end
local function Gold(s) return "|cffffd200" .. s .. "|r" end
local function Green(s) return "|cff40ff40" .. s .. "|r" end

-- A word of ours or someone else's as it travels: no escape code, control byte or separator.
local function Clean(s, n) return ns.Cut((tostring(s or ""):gsub("[|%c~:,%^]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")), n) end
local function Num(s, max)
	local n = tonumber(s)
	if not n or n ~= math.floor(n) or n < 0 or n > max then return nil end
	return n
end

local function Changed() ns.Fire("REALM_PAGE_CHANGED", "crafters") end

-- A name the moderators took off (net-off, Moderation.lua), in the name of `guild` when known.
local function Off(name, guild)
	local M = ns.Moderation
	return M.Hides ~= nil and M.Hides(name, guild) ~= nil
end
-- This client's own character or guild is off: the word (nothing it sends would show).
local function SelfOff()
	local M = ns.Moderation
	return M.SelfOff and M.SelfOff() or nil
end
local function Recent(times, window)
	local now = ns.Now()
	for i = #times, 1, -1 do if now - times[i] >= window then table.remove(times, i) end end
	return #times
end

---------------------------------------------------------------------------
-- Our professions: read when the player opens one (never a specialization tree)
---------------------------------------------------------------------------

local function Saved(field)
	ns.db[field] = type(ns.db[field]) == "table" and ns.db[field] or {}
	local me = ns.me or "?"
	ns.db[field][me] = type(ns.db[field][me]) == "table" and ns.db[field][me] or {}
	return ns.db[field][me]
end
-- Our yes (true) or no (false) per profession key; nil: not asked yet.
function Crafters.Choices() return Saved("crafterChoice") end
-- What we read of each profession: { key, name, rank, max, recipes = { { r, i, n } }, t }.
function Crafters.Mine() return Saved("crafterData") end

local function Id(link, kind) return type(link) == "string" and tonumber(link:match(kind .. ":(%d+)")) or nil end

-- Someone else's profession shown in the window (a link, a guild's list, an NPC's): not ours.
local function External()
	local T = C_TradeSkillUI
	for _, f in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting" }) do
		local fn = T and T[f]
		if type(fn) == "function" then
			local ok, v = pcall(fn)
			if ok and v then return true end
		end
	end
	if type(IsTradeSkillLinked) == "function" then
		local ok, v = pcall(IsTradeSkillLinked)
		if ok and v then return true end
	end
	return false
end

-- WoW: Forever's professions (C_TradeSkillUI): the base profession's id, name and skill, and every
-- recipe learned, with the item it makes. nil where the client has no such API or nothing loaded.
local function ReadModern()
	local T = C_TradeSkillUI
	if not T or type(T.GetBaseProfessionInfo) ~= "function" or type(T.GetRecipeInfo) ~= "function" then return nil end
	local ok, base = pcall(T.GetBaseProfessionInfo)
	if not ok or type(base) ~= "table" or not base.professionID or base.professionID == 0 then return nil end
	local child
	if type(T.GetChildProfessionInfo) == "function" then
		local okc, c = pcall(T.GetChildProfessionInfo)
		if okc and type(c) == "table" and (c.skillLevel or 0) > 0 then child = c end
	end
	local ids
	for _, f in ipairs({ "GetAllRecipeIDs", "GetFilteredRecipeIDs" }) do
		if not ids and type(T[f]) == "function" then
			local okr, r = pcall(T[f])
			if okr and type(r) == "table" then ids = r end
		end
	end
	local recipes = {}
	for _, id in ipairs(ids or {}) do
		local okr, info = pcall(T.GetRecipeInfo, id)
		if okr and type(info) == "table" and info.learned then
			local item
			if type(T.GetRecipeOutputItemData) == "function" then
				local oko, out = pcall(T.GetRecipeOutputItemData, id)
				if oko and type(out) == "table" then item = out.itemID end
			end
			recipes[#recipes + 1] = { r = id, i = item, n = info.name }
		end
	end
	local skill = child or base
	return { key = tostring(base.professionID), name = base.professionName, rank = skill.skillLevel, max = skill.maxSkillLevel, recipes = recipes }
end

-- Classic Era and Anniversary: the trade skill window (GetTradeSkill*) or, for Enchanting on
-- Classic Era, the craft window (GetCraft*). What the window lists (its headers and filters apply).
local function ReadClassic(craft)
	local lineFn = craft and GetCraftDisplaySkillLine or GetTradeSkillLine
	if type(lineFn) ~= "function" then return nil end
	local name, rank, max = lineFn()
	if type(name) ~= "string" or name == "" or name == "UNKNOWN" or not rank then return nil end
	local count = craft and GetNumCrafts or GetNumTradeSkills
	local info = craft and GetCraftInfo or GetTradeSkillInfo
	local itemLink = craft and GetCraftItemLink or GetTradeSkillItemLink
	local recipeLink = craft and GetCraftRecipeLink or GetTradeSkillRecipeLink
	local recipes = {}
	for i = 1, (type(count) == "function" and count() or 0) do
		local rname, kind
		if craft then rname, _, kind = info(i) else rname, kind = info(i) end
		if rname and kind ~= "header" and kind ~= "subheader" then
			local link = type(itemLink) == "function" and itemLink(i) or nil
			local rlink = type(recipeLink) == "function" and recipeLink(i) or nil
			recipes[#recipes + 1] = { r = Id(rlink, "enchant") or Id(link, "enchant"), i = Id(link, "item"), n = rname }
		end
	end
	return { key = Clean(name, 24), name = name, rank = rank, max = max, recipes = recipes }
end

-- The profession open now, read (craft: the craft window).
function Crafters.Read(craft)
	if External() then return nil end
	local p = (not craft and ReadModern()) or ReadClassic(craft)
	if not p or #p.recipes == 0 then return nil end
	p.name = Clean(p.name, 24)
	p.key = Clean(p.key, 24)
	if p.name == "" or p.key == "" then return nil end
	p.rank, p.max, p.t = math.floor(tonumber(p.rank) or 0), math.floor(tonumber(p.max) or 0), ns.Now()
	return p
end

-- A profession opened: kept, and listed on the board if the player said yes; asked once if not.
function Crafters.Opened(craft)
	if not ns.IsMember() or (InCombatLockdown and InCombatLockdown()) then return end
	local p = Crafters.Read(craft)
	if not p then return end
	Crafters.Mine()[p.key] = p
	local choice = Crafters.Choices()[p.key]
	if choice == true then
		Crafters.SendListing()
	elseif choice == nil and not questioned[p.key] then
		questioned[p.key] = true
		ns.ShowDialog("SYLVANISTAS_CRAFTER_LIST", p.name, nil, p.key)
	end
	Changed()
end

-- The player's answer for one profession (the dialog), or every one (/syl crafter on|off).
function Crafters.Choose(key, yes)
	local choices = Crafters.Choices()
	local was = #Crafters.Listed()
	if key then
		choices[key] = yes and true or false
	else
		for k in pairs(Crafters.Mine()) do choices[k] = yes and true or false end
	end
	local now = #Crafters.Listed()
	local off = SelfOff()
	if yes and off then
		-- (1.1, review: kept, and listed once the moderators put us back on.)
		ns.Print(ns.Moderation.YouText(off))
	elseif yes then
		Crafters.SendListing(true)
		ns.Print(L.CRAFTER_LISTED)
	elseif was > 0 then
		-- Unlisted: the board forgets us at once (1.1 clients), or shows what is still listed.
		if now == 0 then
			lastListing, lastListingText, lastListingKeys = -math.huge, nil, nil
			ns.Comm.Send("CHANNEL", "W0~", "crafterlist")
		else
			Crafters.SendListing(true)
		end
		ns.Print(L.CRAFTER_UNLISTED)
	else
		ns.Print(L.CRAFTER_NOT_LISTED)
	end
	Changed()
end

-- Our professions listed, as the board shows them.
function Crafters.Listed()
	local out = {}
	for key, p in pairs(Crafters.Mine()) do
		if Crafters.Choices()[key] == true and type(p) == "table" then out[#out + 1] = p end
	end
	table.sort(out, function(a, b) return (a.key or "") < (b.key or "") end)
	return out
end

-- Our listing, when due (force: a new yes, or its time to be repeated, LIST_EVERY). Otherwise by
-- what changed since the one sent last (the 1.1 review: a crafter levelling sent one every 2
-- minutes, and a login two): a profession listed or taken off, CHANGED_GAP after it at the
-- soonest; its skill or how many recipes (a skill up while crafting), LIST_GAP after it; nothing,
-- LIST_EVERY (the repeat). A change too soon waits for the board's ticker.
Crafters.CHANGED_GAP = 120
local changedWaiting = false
local lastListingKeys  -- the professions of the listing sent last
local loginWait = false -- after login, our first listing waits for its own draw (Crafters.OnLogin)
function Crafters.SendListing(force)
	-- (1.1, review: while the moderators have us off, nothing: the next tick sends it once
	-- we are back on.)
	if not ns.IsMember() or SelfOff() then return false end
	local listed = Crafters.Listed()
	if #listed == 0 then return false end
	local head = ("W1~%s~"):format(Clean(GetGuildInfo("player"), 72))
	local parts, keys, size = {}, {}, #head
	for i = 1, math.min(#listed, Crafters.PROFS_MAX) do
		local p = listed[i]
		local e = ("%s:%s:%d:%d:%d"):format(p.key, p.name, p.rank or 0, p.max or 0, #(p.recipes or {}))
		if size + #e + 1 <= 250 then parts[#parts + 1], keys[#keys + 1], size = e, p.key, size + #e + 1 end -- (one message)
	end
	local text, keyText = head .. table.concat(parts, ","), table.concat(keys, ",")
	local now = ns.Now()
	if not force then
		local gap = text == lastListingText and Crafters.LIST_EVERY
			or keyText ~= lastListingKeys and Crafters.CHANGED_GAP or Crafters.LIST_GAP
		if now - lastListing < gap then
			changedWaiting = text ~= lastListingText
			return false
		end
	end
	lastListing, lastListingText, lastListingKeys, changedWaiting = now, text, keyText, false
	ns.Comm.Send("CHANNEL", text, "crafterlist")
	return true
end

---------------------------------------------------------------------------
-- The board: everyone's listings (this session, from the channel)
---------------------------------------------------------------------------

function Crafters.HandleListing(dist, sender, text)
	if dist ~= "CHANNEL" or type(text) ~= "string" or #text > 255 then return end
	sender = ns.FullName(sender)
	if text == "W0~" then
		if board[sender] then
			board[sender], boardCount = nil, boardCount - 1
			Changed()
		end
		return
	end
	local guild, list = text:match("^W1~([^~]+)~([^~]+)$")
	if not guild or #guild > 72 or not ns.IsFederation(guild) then return end
	-- 1.1 (review): a name the moderators took off (net-off): not listed, and off the board.
	if Off(sender, guild) then
		if board[sender] then
			board[sender], boardCount = nil, boardCount - 1
			Changed()
		end
		return
	end
	if not ns.Data.ClaimGuild(sender, guild) then return end
	local profs = {}
	for entry in list:gmatch("[^,]+") do
		local key, name, rank, max, n = entry:match("^([^:]+):([^:]+):(%d+):(%d+):(%d+)$")
		rank, max, n = Num(rank, 9999), Num(max, 9999), Num(n, 9999)
		if key and #key <= 24 and #name <= 24 and rank and max and n and #profs < Crafters.PROFS_MAX then
			profs[#profs + 1] = { key = key, name = name, rank = rank, max = max, n = n }
		end
	end
	if #profs == 0 then return end
	if not board[sender] then
		if boardCount >= Crafters.BOARD_MAX then
			-- (The one heard longest ago goes.)
			local oldest, at = nil, math.huge
			for name, e in pairs(board) do if e.t < at then oldest, at = name, e.t end end
			if oldest then board[oldest], boardCount = nil, boardCount - 1 end
		end
		boardCount = boardCount + 1
	end
	board[sender] = { guild = guild, profs = profs, t = ns.Now() }
	Changed()
end
ns.Comm.Handle("W1", function(...) Crafters.HandleListing(...) end)
ns.Comm.Handle("W0", function(...) Crafters.HandleListing(...) end)

-- The board now, listings heard in the last LIST_KEEP: { { name, guild, profs, t } }. Never a
-- crafter the moderators took off since (1.1, review): back on, his next listing shows.
function Crafters.Board()
	local now, out = ns.Now(), {}
	for name, e in pairs(board) do
		if now - e.t > Crafters.LIST_KEEP then
			board[name], boardCount = nil, boardCount - 1
		elseif not Off(name, e.guild) then
			out[#out + 1] = { name = name, guild = e.guild, profs = e.profs, t = e.t }
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

---------------------------------------------------------------------------
-- "Who can make this?": our ask, the crafters' answers
---------------------------------------------------------------------------

local function ItemName(id)
	if GetItemInfo then
		local ok, name = pcall(GetItemInfo, id)
		if ok and type(name) == "string" then return name end
	end
	return L.CRAFTER_ITEM_N:format(id)
end

-- An ask: an item link (or "item:<id>") or words (3 to 40 bytes). On a click or /syl craft.
function Crafters.Ask(what)
	if not ns.IsMember() then return ns.Print(L.MEMBERS_ONLY) end
	what = tostring(what or "")
	local id = tonumber(what:match("|Hitem:(%d+)") or what:match("^%s*item:(%d+)"))
	local words = not id and Clean(what, 40) or nil
	if not id and (not words or #words < 3) then return ns.Print(L.CRAFTER_ASK_HOW) end
	local now = ns.Now()
	if myAsk and now - myAsk.t < Crafters.ASK_GAP then return ns.Print(L.CRAFTER_ASK_WAIT:format(Crafters.ASK_GAP - (now - myAsk.t))) end
	if Recent(askTimes, 600) >= Crafters.ASKS_PER_10MIN then return ns.Print(L.CRAFTER_ASK_MANY) end
	askTimes[#askTimes + 1] = now
	askCounter = askCounter + 1
	local askId = ns.Codec.Base36(askCounter % 1296)
	myAsk = { id = askId, t = now, item = id, label = id and ItemName(id) or words, answers = {}, count = 0 }
	ns.Comm.Send("CHANNEL", id and ("WQ~%s~i~%d"):format(askId, id) or ("WQ~%s~t~%s"):format(askId, ns.Fold(words)), "crafterask", true)
	ns.Print(L.CRAFTER_ASKED:format(myAsk.label))
	ns.Views.ShowPage("crafters")
	Changed()
	return myAsk
end
function Crafters.MyAsk() return myAsk end

-- Our recipes that answer an ask: an item's id, or words in the recipe's name (ours: our language).
local function Matches(kind, what)
	local out = {}
	local best
	for key, p in pairs(Crafters.Mine()) do
		if Crafters.Choices()[key] == true and type(p) == "table" then
			local found = {}
			for _, r in ipairs(p.recipes or {}) do
				local hit
				if kind == "i" then hit = r.i == what
				else hit = type(r.n) == "string" and ns.Fold(r.n):find(what, 1, true) ~= nil end
				if hit and #found < Crafters.MATCHES_MAX then found[#found + 1] = r end
			end
			if #found > 0 and (not best or #found > #best.found) then best = { p = p, found = found } end
		end
	end
	return best
end

-- Someone's ask on the channel: answered by whisper, 1 to 8 seconds later, when a profession we
-- listed has a recipe for it (our budget of answers allowing).
function Crafters.HandleAsk(dist, sender, text)
	if dist ~= "CHANNEL" or not ns.IsMember() or #Crafters.Listed() == 0 or SelfOff() then return end
	local askId, kind, what = text:match("^WQ~([0-9a-z][0-9a-z]?)~([it])~(.+)$")
	if not askId then return end
	if kind == "i" then
		what = Num(what, 999999999)
	else
		what = #what >= 3 and #what <= 40 and ns.Fold(Clean(what, 40)) or nil
	end
	if not what then return end
	sender = ns.FullName(sender)
	local now = ns.Now()
	if now - (answered[sender] or -math.huge) < Crafters.ANSWER_SAME then return end
	if Recent(answerTimes, 60) >= Crafters.ANSWER_PER_MIN then return end
	local best = Matches(kind, what)
	if not best then return end
	answered[sender] = now
	answerTimes[#answerTimes + 1] = now
	local entries = {}
	for _, r in ipairs(best.found) do entries[#entries + 1] = ("%d:%d"):format(r.r or 0, r.i or 0) end
	local msg = ("WA~%s~%s~%s~%d~%s"):format(askId, Clean(GetGuildInfo("player"), 72), best.p.name, best.p.rank or 0, table.concat(entries, ","))
	Crafters.after(1 + Crafters.random() * 7, "crafter answer", function()
		ns.Comm.Whisper(sender, ns.Cut(msg, 250), "crafteranswer " .. sender)
	end)
end
ns.Comm.Handle("WQ", function(...) Crafters.HandleAsk(...) end)

local function Recipes(list, max)
	local out = {}
	for entry in tostring(list or ""):gmatch("[^,]+") do
		local r, i = entry:match("^(%d+):(%d+)$")
		r, i = Num(r, 999999999), Num(i, 999999999)
		if r and i and (r > 0 or i > 0) and #out < max then out[#out + 1] = { r = r > 0 and r or nil, i = i > 0 and i or nil } end
	end
	return out
end

-- A crafter's answer to our last ask (a whisper, within ASK_WAIT).
function Crafters.HandleAnswer(dist, sender, text)
	if dist ~= "WHISPER" or not myAsk or ns.Now() - myAsk.t > Crafters.ASK_WAIT then return end
	local askId, guild, prof, rank, list = text:match("^WA~([0-9a-z]+)~([^~]+)~([^~]+)~(%d+)~([^~]*)$")
	if askId ~= myAsk.id or not ns.IsFederation(guild) or #prof > 24 or not Num(rank, 9999) then return end
	sender = ns.FullName(sender)
	if Off(sender, guild) then return end -- (1.1, review: net-off)
	if myAsk.answers[sender] then return end
	if myAsk.count >= Crafters.ANSWERS_MAX then return end
	local recipes = Recipes(list, Crafters.MATCHES_MAX)
	if #recipes == 0 then return end
	myAsk.answers[sender] = { guild = guild, prof = prof, rank = tonumber(rank), recipes = recipes, t = ns.Now() }
	myAsk.count = myAsk.count + 1
	Changed()
end
ns.Comm.Handle("WA", function(...) Crafters.HandleAnswer(...) end)

---------------------------------------------------------------------------
-- A crafter's recipes, on a click
---------------------------------------------------------------------------

function Crafters.AskList(crafter, key)
	local k = crafter .. "~" .. key
	local now = ns.Now()
	if now - (asked[k] or -math.huge) < Crafters.LIST_SAME then return false end
	asked[k] = now
	lists[k] = { parts = {}, t = now }
	ns.Comm.Whisper(crafter, "WR~" .. key, "crafterlistask " .. k)
	Changed()
	return true
end

-- Our lists' parts, one each LIST_PACE while our send queue is short (Comm.QueueSize): the census
-- and every other message of ours keep their place. A list stalled a minute is dropped (its asker
-- asks again).
local function PumpLists()
	local job = listJobs[1]
	if not job then
		listPumping = false
		return
	end
	if ns.Comm.QueueSize and ns.Comm.QueueSize() > Crafters.LIST_QUEUE then
		job.stalls = job.stalls + 1
		if job.stalls * Crafters.LIST_PACE >= 60 then table.remove(listJobs, 1) end
	else
		job.i = job.i + 1
		ns.Comm.Whisper(job.to, ("WL~%s~%d/%d~%s"):format(job.key, job.i, #job.parts, table.concat(job.parts[job.i], ",")), "crafterlist " .. job.to .. job.i)
		if job.i >= #job.parts then table.remove(listJobs, 1) end
	end
	if not listJobs[1] then
		listPumping = false
		return
	end
	Crafters.after(Crafters.LIST_PACE, "crafter list", PumpLists)
end

function Crafters.HandleListAsk(dist, sender, text)
	if dist ~= "WHISPER" or not ns.IsMember() or SelfOff() then return end
	local key = text:match("^WR~([^~]+)$")
	local p = key and Crafters.Mine()[key]
	if not p or Crafters.Choices()[key] ~= true then return end
	sender = ns.FullName(sender)
	local now = ns.Now()
	if now - (listSent[sender] or -math.huge) < Crafters.LIST_SAME or Recent(listTimes, 60) >= Crafters.LISTS_PER_MIN then return end
	if #listJobs >= Crafters.LIST_JOBS then
		-- Busy with other players' lists: he is told so (and may ask again in a minute).
		if Recent(busyTimes, 60) < Crafters.BUSY_PER_MIN then
			busyTimes[#busyTimes + 1] = now
			ns.Comm.Whisper(sender, ("WL~%s~0/0~"):format(key), "crafterbusy " .. sender)
		end
		return
	end
	listSent[sender] = now
	listTimes[#listTimes + 1] = now
	-- Parts of LIST_BYTES of entries each (a message holds 255 bytes), LIST_PARTS at most.
	local parts, cur = {}, {}
	local size = 0
	for _, r in ipairs(p.recipes or {}) do
		local e = ("%d:%d"):format(r.r or 0, r.i or 0)
		if #cur > 0 and size + #e + 1 > Crafters.LIST_BYTES then
			parts[#parts + 1], cur, size = cur, {}, 0
			if #parts >= Crafters.LIST_PARTS then break end
		end
		cur[#cur + 1], size = e, size + #e + 1
	end
	if #cur > 0 and #parts < Crafters.LIST_PARTS then parts[#parts + 1] = cur end
	if #parts == 0 then return end
	listJobs[#listJobs + 1] = { to = sender, key = key, parts = parts, i = 0, stalls = 0 }
	if not listPumping then
		listPumping = true
		PumpLists()
	end
end
ns.Comm.Handle("WR", function(...) Crafters.HandleListAsk(...) end)

function Crafters.HandleList(dist, sender, text)
	if dist ~= "WHISPER" then return end
	local key, part, parts, list = text:match("^WL~([^~]+)~(%d+)/(%d+)~([^~]*)$")
	sender = ns.FullName(sender)
	if Off(sender) then return end -- (1.1, review: net-off)
	local l = key and lists[sender .. "~" .. key]
	part, parts = Num(part, Crafters.LIST_PARTS), Num(parts, Crafters.LIST_PARTS)
	local now = ns.Now()
	-- (Paced: a part each LIST_PACE; taken while they keep coming, ASK_WAIT after the last.)
	if not l or not part or not parts or now - (l.last or l.t) > Crafters.ASK_WAIT then return end
	if part == 0 and parts == 0 and not l.n then
		-- He is busy sending other players' lists: asked again, on a click, BUSY_WAIT later.
		l.busy = now
		asked[sender .. "~" .. key] = now - Crafters.LIST_SAME + Crafters.BUSY_WAIT
		return Changed()
	end
	if part < 1 or part > parts then return end
	l.parts[part] = Recipes(list, Crafters.LIST_PER_MSG)
	l.n, l.last, l.busy = parts, now, nil
	Changed()
end
ns.Comm.Handle("WL", function(...) Crafters.HandleList(...) end)

-- The recipes a crafter sent of a profession, as far as they came: { { r, i } }, or nil.
function Crafters.ListOf(crafter, key)
	local l = lists[crafter .. "~" .. key]
	if not l then return nil end
	local out = {}
	for part = 1, l.n or 0 do
		for _, r in ipairs(l.parts[part] or {}) do out[#out + 1] = r end
	end
	return out, l
end

---------------------------------------------------------------------------
-- The page (the Realm tab)
---------------------------------------------------------------------------

-- A whisper to a crafter, the player's own (the game's box; Sylvanistas's with the gamepad UI).
local function Whisper(name)
	local tell = ns.TellName(name)
	if ns.GamepadUI() then return ns.UI.WhisperWindow(tell) end
	if ChatFrame_SendTell then ChatFrame_SendTell(tell) end
end
Crafters.Whisper = Whisper

-- The ask's box: with mouse and keyboard the chat's, "/syl craft " in it, where a shift-click
-- puts an item's link; with the gamepad UI Sylvanistas's own window (words only there).
function Crafters.AskPrompt()
	if not ns.GamepadUI() and ChatFrame_OpenChat then return ChatFrame_OpenChat("/syl craft ") end
	ns.ShowDialog("SYLVANISTAS_CRAFT_ASK")
end

function Crafters.Link()
	if not ns.IsMember() then return nil end
	local n = #Crafters.Board()
	return {
		text = "|TInterface\\Icons\\Trade_BlackSmithing:14:14|t " .. Gold(L.CRAFTER_LINK),
		right = n > 0 and Grey(tostring(n)) or nil,
		onClick = function() ns.Views.ShowPage("crafters") end,
		tooltip = function(tt)
			tt:AddLine(L.CRAFTER_LINK, 1, 0.82, 0)
			tt:AddLine(L.CRAFTER_LINK_TIP, 1, 1, 1, true)
		end,
	}
end

local function RecipeItems(recipes)
	local items, others = {}, 0
	for _, r in ipairs(recipes) do
		if r.i then items[#items + 1] = { id = r.i } else others = others + 1 end
	end
	return items, others
end

-- The page's lines; `q`, the Realm's search: crafters whose name, guild or profession holds it.
function Crafters.Lines(q)
	local lines = { { text = Gold(L.CHATS_BACK), onClick = function() ns.Views.ShowPage(nil) end, gapAfter = true } }
	lines[#lines + 1] = { header = true, text = L.CRAFTER_TITLE,
		tooltip = function(tt) tt:AddLine(L.CRAFTER_TITLE, 1, 0.82, 0); tt:AddLine(L.CRAFTER_ABOUT, 1, 1, 1, true) end }
	if not q then
		lines[#lines + 1] = { text = Green(L.CRAFTER_ASK), onClick = function() Crafters.AskPrompt() end,
			tooltip = function(tt) tt:AddLine(L.CRAFTER_ASK, 1, 0.82, 0); tt:AddLine(L.CRAFTER_ASK_TIP, 1, 1, 1, true) end }
		-- Our own listing, and how to change it.
		local listed = Crafters.Listed()
		if #listed > 0 then
			local names = {}
			for _, p in ipairs(listed) do names[#names + 1] = ("%s %d"):format(p.name, p.rank or 0) end
			lines[#lines + 1] = { text = Grey(L.CRAFTER_YOU:format(table.concat(names, ", "))), right = Gold(L.CRAFTER_UNLIST),
				onClick = function() Crafters.Choose(nil, false) end,
				tooltip = function(tt) tt:AddLine(L.CRAFTER_UNLIST, 1, 0.82, 0); tt:AddLine(L.CRAFTER_UNLIST_TIP, 1, 1, 1, true) end }
		else
			lines[#lines + 1] = { text = Grey(L.CRAFTER_HOW_LIST) }
		end
		lines[#lines].gapAfter = true
		-- The answers to our last ask.
		local a = myAsk
		if a then
			local answers = {}
			for name, e in pairs(a.answers) do
				if not Off(name, e.guild) then answers[#answers + 1] = { name = name, e = e } end -- (1.1: net-off)
			end
			table.sort(answers, function(x, y)
				if x.e.rank ~= y.e.rank then return x.e.rank > y.e.rank end
				return x.name < y.name
			end)
			lines[#lines + 1] = { header = true, text = L.CRAFTER_CAN_MAKE:format(a.label),
				right = Grey(#answers == 0 and (ns.Now() - a.t < Crafters.ASK_WAIT and L.CRAFTER_WAITING or L.CRAFTER_NOBODY) or tostring(#answers)) }
			for _, x in ipairs(answers) do
				local who = ns.DisplayName(x.name)
				lines[#lines + 1] = { indent = 1, key = x.name,
					text = who .. "  " .. Grey("<" .. x.e.guild .. ">"), right = Gold(L.CRAFTER_WHISPER) .. "  " .. Grey(("%s %d"):format(x.e.prof, x.e.rank)),
					onClick = function() Whisper(x.name) end,
					tooltip = function(tt)
						tt:AddLine(who, 1, 0.82, 0)
						for _, r in ipairs(x.e.recipes) do
							if r.i then tt:AddLine(ItemName(r.i), 1, 1, 1) end
						end
						tt:AddLine(L.CRAFTER_WHISPER_TIP:format(who), 0.6, 0.6, 0.6, true)
					end }
				local items = RecipeItems(x.e.recipes)
				if #items > 0 then lines[#lines + 1] = { indent = 2, items = items } end
			end
			lines[#lines].gapAfter = true
		end
	end
	-- The board: by profession, the highest skill first.
	local byProf, profs = {}, {}
	for _, c in ipairs(Crafters.Board()) do
		for _, p in ipairs(c.profs) do
			if not q or ns.Holds(q, ns.DisplayName(c.name), c.guild, p.name) then
				local k = ns.Fold(p.name)
				if not byProf[k] then
					byProf[k] = { name = p.name, list = {} }
					profs[#profs + 1] = byProf[k]
				end
				table.insert(byProf[k].list, { c = c, p = p })
			end
		end
	end
	table.sort(profs, function(a, b) return a.name < b.name end)
	if #profs == 0 then
		lines[#lines + 1] = { text = Grey(q and L.SEARCH_NO_MATCH or L.CRAFTER_EMPTY) }
		return lines
	end
	for _, group in ipairs(profs) do
		table.sort(group.list, function(a, b)
			if a.p.rank ~= b.p.rank then return a.p.rank > b.p.rank end
			return a.c.name < b.c.name
		end)
		lines[#lines + 1] = { header = true, text = group.name, right = Grey(tostring(#group.list)) }
		for _, e in ipairs(group.list) do
			local c, p = e.c, e.p
			local who = ns.DisplayName(c.name)
			local id = c.name .. "~" .. p.key
			local opened = open[id] == true
			lines[#lines + 1] = { indent = 1, key = c.name,
				text = (opened and "[-] " or "[+] ") .. who .. "  " .. Grey("<" .. c.guild .. ">"),
				right = Grey(L.CRAFTER_SKILL:format(p.rank, p.max, p.n)),
				onClick = function()
					open[id] = not opened or nil
					if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
				end,
				tooltip = function(tt)
					tt:AddLine(who .. "  <" .. c.guild .. ">", 1, 0.82, 0)
					tt:AddLine(L.CRAFTER_ROW_TIP:format(p.name, p.rank, p.n, ns.Ago(c.t)), 1, 1, 1, true)
				end }
			if opened then
				lines[#lines + 1] = { indent = 2, text = Gold(L.CRAFTER_WHISPER_TO:format(who)), onClick = function() Whisper(c.name) end }
				local recipes, l = Crafters.ListOf(c.name, p.key)
				if not recipes or (l.busy and #recipes == 0) then
					-- (His addon busy with other players' lists: he said so; a click asks again.)
					local busy = l and l.busy
					lines[#lines + 1] = { indent = 2, text = busy and Grey(L.CRAFTER_LIST_BUSY) or Gold(L.CRAFTER_SHOW_RECIPES),
						onClick = function() Crafters.AskList(c.name, p.key) end,
						tooltip = function(tt) tt:AddLine(L.CRAFTER_SHOW_RECIPES, 1, 0.82, 0); tt:AddLine(L.CRAFTER_SHOW_RECIPES_TIP, 1, 1, 1, true) end }
				else
					local items, others = RecipeItems(recipes)
					if #items > 0 then lines[#lines + 1] = { indent = 2, items = items } end
					local got = 0
					for part = 1, l.n or 0 do if l.parts[part] then got = got + 1 end end
					if #recipes == 0 or got < (l.n or 1) then
						lines[#lines + 1] = { indent = 2, text = Grey(ns.Now() - (l.last or l.t) < Crafters.ASK_WAIT and L.CRAFTER_WAITING or L.CRAFTER_LIST_PART:format(got, l.n or 0)) }
					end
					if others > 0 then lines[#lines + 1] = { indent = 2, text = Grey(L.CRAFTER_OTHERS:format(others)) } end
				end
			end
		end
		lines[#lines].gapAfter = true
	end
	return lines
end

-- The dialogs: the question when a profession opens (data: its key), the ask's box (gamepad UI).
StaticPopupDialogs["SYLVANISTAS_CRAFTER_LIST"] = {
	text = L.CRAFTER_LIST_ASK,
	button1 = L.CRAFTER_LIST_YES,
	button2 = L.CRAFTER_LIST_NO,
	OnAccept = function(self, key) ns.SafeCall("crafter yes", Crafters.Choose, key or (self and self.data), true) end,
	OnCancel = function(self, key, reason)
		if reason == "clicked" then ns.SafeCall("crafter no", Crafters.Choose, key or (self and self.data), false) end
	end,
	noCancelOnEscape = true, -- (Escape closes it unanswered: asked again next session)
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
StaticPopupDialogs["SYLVANISTAS_CRAFT_ASK"] = {
	text = L.CRAFTER_ASK_PROMPT,
	button1 = L.CRAFTER_ASK_BTN,
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 260,
	maxLetters = 40,
	OnShow = function(self)
		local eb = self.editBox or self.EditBox
		if eb then eb:SetText(""); eb:SetFocus() end
	end,
	OnAccept = function(self)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("craft ask", Crafters.Ask, eb and eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		local text = self:GetText()
		self:GetParent():Hide()
		ns.SafeCall("craft ask", Crafters.Ask, text)
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- `/syl crafter [on|off]`: every profession read listed or unlisted; alone, what is listed.
function Crafters.Slash(word)
	word = tostring(word or ""):lower()
	if word == "on" then
		if next(Crafters.Mine()) == nil then return ns.Print(L.CRAFTER_HOW_LIST) end
		return Crafters.Choose(nil, true)
	elseif word == "off" then
		return Crafters.Choose(nil, false)
	end
	local names = {}
	for _, p in ipairs(Crafters.Listed()) do names[#names + 1] = ("%s %d"):format(p.name, p.rank or 0) end
	ns.Print(#names > 0 and L.CRAFTER_YOU:format(table.concat(names, ", ")) or L.CRAFTER_HOW_LIST)
end

ns.RealmPages = ns.RealmPages or {}
table.insert(ns.RealmPages, { key = "crafters", Link = function() return Crafters.Link() end, Lines = function(q) return Crafters.Lines(q) end, tip = "CRAFTER" })

-- Each minute: our listing again every LIST_EVERY, or a change that waited its time; the board
-- forgets who went quiet. (Not before our login's own listing: one listing at a login.)
function Crafters.Tick()
	if not loginWait then
		if ns.Now() - lastListing >= Crafters.LIST_EVERY then
			Crafters.SendListing(true)
		elseif changedWaiting then
			Crafters.SendListing()
		end
	end
	Crafters.Board()
end

-- The profession's data can come a moment after its window opens: read then, and again when the
-- game says its list changed while the window is up.
local function Soon(craft)
	if pendingRead then return end
	pendingRead = true
	ns.After(0.5, "crafter read", function()
		pendingRead = nil
		Crafters.Opened(craft)
	end)
end
local shown = {}
function Crafters.OnLogin()
	for _, ev in ipairs({ "TRADE_SKILL_SHOW", "CRAFT_SHOW" }) do
		pcall(ns.RegisterEvent, ev, function()
			shown[ev] = true
			Soon(ev == "CRAFT_SHOW")
		end)
	end
	for ev, show in pairs({ TRADE_SKILL_CLOSE = "TRADE_SKILL_SHOW", CRAFT_CLOSE = "CRAFT_SHOW" }) do
		pcall(ns.RegisterEvent, ev, function() shown[show] = nil end)
	end
	-- (A read's own data arriving: once it is loaded, the same read, no question asked twice.)
	for ev, show in pairs({ TRADE_SKILL_LIST_UPDATE = "TRADE_SKILL_SHOW", TRADE_SKILL_UPDATE = "TRADE_SKILL_SHOW", CRAFT_UPDATE = "CRAFT_SHOW" }) do
		pcall(ns.RegisterEvent, ev, function() if shown[show] then Soon(show == "CRAFT_SHOW") end end)
	end
	-- Our listing again every LIST_EVERY (the first a minute or two after login, for what was
	-- listed before, unless a profession opened meanwhile sent it); the board forgets who went quiet.
	loginWait = true
	ns.After(60 + Crafters.random() * 60, "crafter listing", function()
		loginWait = false
		Crafters.SendListing()
	end)
	ns.Every(60, "crafter board", function() Crafters.Tick() end)
end
ns.On("LOGIN", function() Crafters.OnLogin() end)

-- Tests start from a clean state.
function Crafters.Reset()
	wipe(board); boardCount = 0
	myAsk, askCounter, pendingRead = nil, 0, nil
	wipe(askTimes); wipe(answered); wipe(answerTimes); wipe(listSent); wipe(listTimes); wipe(lists); wipe(asked); wipe(open); wipe(questioned)
	lastListing, lastListingText, lastListingKeys, changedWaiting, loginWait = -math.huge, nil, nil, false, false
	wipe(listJobs); wipe(busyTimes); listPumping = false
end
