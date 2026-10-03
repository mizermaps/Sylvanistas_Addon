local ADDON, ns = ...
local L = ns.L

-- The acts log (1.1, request #12): what this client actually saw done, each with the sender's
-- name as the server stamped it: decrees, the gates, pardons, the King's visibility switches
-- (what the army sees of the treasury, the untabarded list), and the moderation acts later
-- features write here (a character or a guild taken off the net, the shared block terms). "Who
-- opened the gates" is then a line a Hand can read, even after the message is long gone. Only
-- what reached this client (a later login never saw the message), and only on this computer:
-- nothing is sent, and it stays out of /syl bug. A record, not proof: a player can edit their own
-- saved variables, and the page says so.
--
-- The one function every feature writes through:
--
--   ns.Chronicle.Add(kind, by, what, opts) -> true when it was written
--     kind  a short word: "decree", "gates", "pardon", "switch", "netoff" (a character),
--           "guildnetoff" (a guild), "terms" (the shared block terms), or a new one;
--     by    the sender exactly as the server stamped the message (Comm hands it to handlers
--           as "Name-Realm"), or ns.me for this client's own act, which never comes back to it;
--     what  what was done, in plain words (no escape codes: they are taken out);
--     opts  optional: { key = <a state's name>, value = <its value now>, default = <its value
--           when nothing was ever heard>, words = <a player's own words, e.g. a decree's> }.
--           With a key, an act repeated as it is (the gates, a switch, every few minutes) is
--           written once: only when `value` differs from the last one written under `key`
--           (or from `default` when none was). `words` show under the block-term filter.
--
-- Only acts heard from whoever did them: a repeat or a relay of someone else's act (the Treasurer's
-- book carrying the King's switches, an editor's list carrying another's block term) is no act
-- of its sender's, and a state this client only caught up on (a later login) is none it saw done.
-- Such a state is noted, not written: ns.Chronicle.Seen(key, value), so the next change of it
-- is compared with what this client holds.
--
-- On the King's screen while the council's names are hidden there (his stream, ns.CouncilMasked)
-- every sender but the King shows cut short (ns.MaskName), in the list, its tooltips, the copy,
-- /syl log and its search: these are the Crown's circle's acts, so a name here would say who is
-- in it. The shared block terms' words show cut short on his screen always, as the filter's own
-- lists do (Filter.Shown).
--
-- Kept in ns.rdb.acts (this realm group's), the newest Chronicle.MAX; /syl log shows it, and the
-- Decrees tab lists it with a search box and a copy.

local Chronicle = {}
ns.Chronicle = Chronicle

Chronicle.MAX = 300
Chronicle.SHOWN = 20     -- entries the Decrees tab lists without a search
Chronicle.CHAT = 10      -- entries /syl log prints without a number
Chronicle.TEXT_MAX = 160 -- bytes of what was done, and of a player's words

local KINDS = {
	decree = "ACTS_KIND_DECREE", gates = "ACTS_KIND_GATES", pardon = "ACTS_KIND_PARDON", switch = "ACTS_KIND_SWITCH",
	netoff = "ACTS_KIND_NETOFF", guildnetoff = "ACTS_KIND_GUILDNETOFF", terms = "ACTS_KIND_TERMS",
}

local function Clean(s, n)
	s = tostring(s or ""):gsub("[|%c]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return ns.Cut(s, n or Chronicle.TEXT_MAX)
end

local function Store()
	if not ns.rdb then return nil end
	if type(ns.rdb.acts) ~= "table" then ns.rdb.acts = {} end
	return ns.rdb.acts
end

local function States()
	if type(ns.rdb.actsState) ~= "table" then ns.rdb.actsState = {} end
	return ns.rdb.actsState
end

local function ServerNow() return (GetServerTime and GetServerTime()) or ns.Now() end

function Chronicle.Add(kind, by, what, opts)
	local list = Store()
	if not list or type(kind) ~= "string" or kind == "" then return false end
	opts = type(opts) == "table" and opts or {}
	if opts.key ~= nil then
		local states, key, value = States(), tostring(opts.key), tostring(opts.value)
		local last = states[key]
		if last == nil and opts.default ~= nil then last = tostring(opts.default) end
		states[key] = value
		if last == value then return false end
	end
	local words = opts.words and Clean(opts.words) or nil
	list[#list + 1] = {
		t = ns.Now(), st = ServerNow(), kind = Clean(kind, 16),
		by = Clean(by ~= nil and ns.FullName(tostring(by)) or "?", 64),
		what = Clean(what), words = words ~= "" and words or nil,
	}
	while #list > Chronicle.MAX do table.remove(list, 1) end
	ns.Fire("ACTS_CHANGED")
	return true
end

-- A state this client holds now without having seen it set (see above): noted, not written.
function Chronicle.Seen(key, value)
	if not ns.rdb or key == nil then return end
	States()[tostring(key)] = tostring(value)
end

function Chronicle.Entries()
	local list = ns.rdb and ns.rdb.acts
	return type(list) == "table" and list or {}
end

function Chronicle.Clear()
	if ns.rdb then ns.rdb.acts, ns.rdb.actsState = nil, nil end
	ns.Fire("ACTS_CHANGED")
end

local function KindLabel(kind)
	local key = KINDS[kind]
	return key and L[key] or tostring(kind)
end

-- Entries whose hidden words a click showed, this session (1.1, #31).
local revealed = setmetatable({}, { __mode = "k" })

-- A player's words as they show: hidden while the player's block terms hit them (a decree's, or
-- the shared block terms themselves), until a click on the entry (1.1, #31), in the copy too.
local function Veiled(e)
	local F = ns.Filter
	return e.words ~= nil and not revealed[e] and F ~= nil and not F.missing and F.Hides ~= nil and F.Hides(e.words)
end
-- The shared block terms' words ("+term -term") as the filter shows terms: cut short on the
-- King's screen (Filter.Shown), whole elsewhere.
local function TermsShown(e)
	local F = ns.Filter
	if e.kind ~= "terms" or type(e.words) ~= "string" or not F or F.missing or type(F.Shown) ~= "function" then return e.words end
	return (e.words:gsub("([%+%-]?)([^%s%+%-]+)", function(sign, term) return sign .. F.Shown(term) end))
end
local function Words(e)
	if not e.words then return nil end
	if Veiled(e) then return ns.L.FILTER_WORDS_HIDDEN_SHORT end
	return '"' .. TermsShown(e) .. '"'
end

-- The sender as this screen shows it: cut short on the King's while the council's names are
-- hidden there (his stream), but his own.
local function Who(e)
	local by = tostring(e.by or "?")
	if ns.CouncilMasked and ns.CouncilMasked() and not (ns.IsKingCharacter and ns.IsKingCharacter(by)) then return ns.MaskName(by) end
	return by
end

-- One entry as a line of text: when (this computer's clock), what, and who sent it.
function Chronicle.Line(e)
	local when = date and date("%m-%d %H:%M", tonumber(e.t) or 0) or tostring(e.t)
	local words = Words(e)
	return ("%s  %s: %s%s  (%s)"):format(when, KindLabel(e.kind), tostring(e.what or ""), words and (" " .. words) or "", Who(e))
end

-- Does an entry hold the search (folded, ns.Holds)? Only what this screen shows of the sender
-- and of the shared terms.
local function Found(e, q)
	return ns.Holds(q, KindLabel(e.kind), e.what, Who(e), TermsShown(e), date and date("%m-%d %H:%M", tonumber(e.t) or 0) or "")
end

-- The whole log as text, newest first, for the copy box: its caveat on top.
function Chronicle.Text()
	local out = { L.ACTS_TITLE, L.ACTS_NOTE, "" }
	local list = Chronicle.Entries()
	for i = #list, 1, -1 do out[#out + 1] = Chronicle.Line(list[i]) end
	if #list == 0 then out[#out + 1] = L.ACTS_EMPTY end
	return table.concat(out, "\n")
end

-- The Decrees tab's section: the caveat, a copy of the whole log, and the newest entries, or
-- every one that holds the search `q`.
function Chronicle.AddLines(lines, q)
	lines[#lines + 1] = { header = true, text = L.ACTS_TITLE }
	lines[#lines + 1] = { text = "|cff9d9d9d" .. L.ACTS_NOTE .. "|r" }
	lines[#lines + 1] = {
		text = "|cff40ff40" .. L.ACTS_COPY .. "|r",
		onClick = function() if ns.UI and ns.UI.ShowCopy then ns.UI.ShowCopy(L.ACTS_TITLE, Chronicle.Text()) end end,
	}
	local list, shown = Chronicle.Entries(), 0
	for i = #list, 1, -1 do
		local e = list[i]
		if not q or Found(e, q) then
			shown = shown + 1
			lines[#lines + 1] = {
				text = "|cffffd200" .. KindLabel(e.kind) .. "|r  " .. tostring(e.what or "") .. (e.words and (" |cff9d9d9d" .. Words(e) .. "|r") or ""),
				right = "|cff9d9d9d" .. ns.Ago(tonumber(e.t) or 0) .. "|r",
				-- Words the player's block terms hide: a click shows them (1.1, #31).
				onClick = Veiled(e) and function()
					revealed[e] = true
					if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
				end or nil,
				tooltip = function(tt)
					tt:AddLine(KindLabel(e.kind), 1, 0.82, 0)
					tt:AddLine(Chronicle.Line(e), 1, 1, 1, true)
					tt:AddLine(L.ACTS_BY:format(Who(e)), 0.7, 0.7, 0.7, true)
				end,
			}
			if not q and shown >= Chronicle.SHOWN then break end
		end
	end
	if shown == 0 then lines[#lines + 1] = { text = "|cff9d9d9d" .. (q and L.SEARCH_NO_MATCH or L.ACTS_EMPTY) .. "|r" } end
	lines[#lines].gapAfter = true
	return lines
end

-- /syl log: the newest entries (or n of them), "clear", "copy", or those holding a word.
function Chronicle.Slash(rest)
	rest = tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local word = rest:lower()
	if word == "clear" then
		Chronicle.Clear()
		return ns.Print(L.ACTS_CLEARED)
	end
	if word == "copy" then
		if ns.UI and ns.UI.ShowCopy then ns.UI.ShowCopy(L.ACTS_TITLE, Chronicle.Text()) end
		return
	end
	local n = tonumber(rest)
	local q = (rest ~= "" and not n) and ns.Fold(rest) or nil
	n = math.max(1, math.min(math.floor(n or Chronicle.CHAT), Chronicle.MAX))
	local list, out = Chronicle.Entries(), {}
	for i = #list, 1, -1 do
		if not q or Found(list[i], q) then out[#out + 1] = list[i] end
		if not q and #out >= n then break end
	end
	ns.Print(L.ACTS_CHAT_HEAD:format(#out, #list))
	for _, e in ipairs(out) do print("  " .. Chronicle.Line(e)) end
	if #out == 0 then print("  " .. (q and L.SEARCH_NO_MATCH or L.ACTS_EMPTY)) end
	print("  " .. L.ACTS_NOTE)
end

-- The Decrees tab lists it: redrawn soon when it grows (UI.RefreshSoon waits for the window).
ns.On("ACTS_CHANGED", function() if ns.UI and ns.UI.RefreshSoon then ns.UI.RefreshSoon() end end)

ns.On("INIT", function()
	-- Kept sane whatever the saved file holds (it can be edited: a record, not proof).
	local list = ns.rdb and ns.rdb.acts
	if list ~= nil and type(list) ~= "table" then ns.rdb.acts = nil return end
	if type(list) == "table" then
		for i = #list, 1, -1 do
			if type(list[i]) ~= "table" then table.remove(list, i) end
		end
		while #list > Chronicle.MAX do table.remove(list, 1) end
	end
end)
