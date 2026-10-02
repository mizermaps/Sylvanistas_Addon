local ADDON, ns = ...

-- A read-only door for a companion addon the mods run (OfficerSpy). It answers "is this a High
-- Councillor?" from the signed list, hands out a copy of that list, and passes along each chat
-- line this client has already accepted. Nothing here sends, writes or changes anything in
-- Sylvanistas: a companion only reads, and Sylvanistas never learns what it does with what it read.

SylvanistasBridge = SylvanistasBridge or {}
SylvanistasBridge.API_VERSION = 1

local COUNCIL_MAX = 64  -- a copy never grows past this (the signed list itself stops at 30)
local OBSERVERS_MAX = 8 -- one companion listens, realistically

-- The King's screen while the councillors' names are hidden there (his stream, ns.CouncilMasked,
-- 0.9.9): the chats put no mark on a councillor's line and /syl council cuts each name short, so
-- the bridge names nobody either, until he clicks the eye. An error there counts as hidden.
local function Masked()
	if type(ns.CouncilMasked) ~= "function" then return false end
	local ok, masked = pcall(ns.CouncilMasked)
	return not ok or masked == true
end

-- The same answer as the councillor mark in the Sylvanistas chats (ns.IsHighCouncillor, not on the
-- King's screen while the names are hidden): a name on the signed list, on that list's realm
-- group. Anything else, or an error, is false.
function SylvanistasBridge.IsHighCouncillor(name)
	if type(name) ~= "string" or name == "" or type(ns.IsHighCouncillor) ~= "function" or Masked() then return false end
	local ok, yes = pcall(ns.IsHighCouncillor, name)
	return ok and yes == true
end

-- A fresh, sorted copy of the signed list's names (Workshop.CouncilNames, the names /syl council
-- prints), and the list's realm group ("A+B", or nil when it names none): the names count on
-- that group only, which SylvanistasBridge.IsHighCouncillor checks. Empty until a signed list has
-- been checked on this client, and on the King's screen while the names are hidden.
function SylvanistasBridge.GetCouncil()
	local c, W = ns.rdb and ns.rdb.council, ns.Workshop
	if type(c) ~= "table" or type(c.names) ~= "table" or type(W) ~= "table" or type(W.CouncilNames) ~= "function"
		or Masked() then
		return {}, nil
	end
	local ok, names = pcall(W.CouncilNames)
	if not ok or type(names) ~= "table" then return {}, nil end
	local out = {}
	for i = 1, math.min(#names, COUNCIL_MAX) do
		if type(names[i]) == "string" then out[#out + 1] = names[i] end
	end
	return out, type(c.realm) == "string" and c.realm or nil
end

-- Chat lines for a companion: fn(tier, sender, text) for each line from someone else that this
-- client accepted, after its checks (rank, blocked and ignored players, repeats, rate) and
-- Codec.SanitizeChat: the lines the history keeps and the Chat tab shows, our own left out. A
-- muted channel and a line the flood guard holds back pass on the same way, as those only decide
-- what this player's chat frame shows. Plain strings only, and an observer that errors is
-- skipped: it can never stop a line or the others.
local observers = {}
function SylvanistasBridge.RegisterChatObserver(fn)
	if type(fn) ~= "function" or #observers >= OBSERVERS_MAX then return false end
	observers[#observers + 1] = fn
	return true
end

ns.On("CHAT_LINE", function(tier, sender, text)
	if type(tier) ~= "string" or type(sender) ~= "string" or type(text) ~= "string" then return end
	for i = 1, #observers do pcall(observers[i], tier, sender, text) end
end)
