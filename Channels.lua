local ADDON, ns = ...
local L = ns.L

-- Chat channels of the federation, carried as M1 messages on the hidden Sylvanistas channel:
--   [Sylvanistas]  /sy   every member of every Sylvanistas guild
--   [Captains] /syc  rank 0-1 of any Sylvanistas guild
--   [Lords]    /syld  the Crown: guild masters and the officers of <Sylvanistas>
-- Higher ranks also use the channels below theirs. Every addon client receives every line
-- (nothing is encrypted): each client shows a line only when its own rank is high enough
-- and the sender's rank is verified, never taken from the message. No WoW channel number.

local Channels = {}
ns.Channels = Channels
local Codec = ns.Codec

local SEND_GAP = 1.5             -- we send at most one line every 1.5 s
local BUCKET_SIZE = 6            -- per sender: a burst of 6 parts, then one every 1.2 s
local BUCKET_REFILL = 1.2        -- (an unmodified client never goes faster than that)
local MAX_SHOWN_PER_MINUTE = 60  -- flood guard per channel
local FAIR_SHARE = 10            -- once a channel is half full, no sender gets more lines than this a minute
local DEDUPE_WINDOW = 120
local HISTORY = 100              -- lines kept per channel
local LOG_GAP = 60               -- at most one "dropped" log line per sender per minute
local NOTICE_GAP = 60            -- at most one flood guard notice a minute...
local NOTICE_WAIT = 10           -- ...a few seconds after the first line held, to count the burst

-- Gold, teal and royal purple: none of them is a colour Blizzard's chat already uses.
local TIERS = {
	A = { level = 1, label = "CHAN_ALL",      slash = "/sy",  word = "sylvanistas",  deny = "MEMBERS_ONLY",       color = { 0.90, 0.77, 0.36 } },
	C = { level = 2, label = "CHAN_CAPTAINS", slash = "/syd", word = "dreadguard", deny = "CHAN_ONLY_CAPTAINS", color = { 0.35, 0.85, 0.85 } },
	L = { level = 3, label = "CHAN_LORDS",    slash = "/sydl", word = "darklords", deny = "CHAN_ONLY_LORDS",    color = { 0.75, 0.50, 1.00 } },
}
Channels.TIERS, Channels.ORDER = TIERS, { "A", "C", "L" }
Channels.HISTORY = HISTORY

local stats = { sent = 0, shown = 0, hidden = 0, bad = 0, dup = 0, rate = 0, flood = 0, forged = 0, unverified = 0, rank = 0, ignored = 0,
	moved = 0 }
local seen = {}      -- "sender#id#text" -> time: every part is shown once
local buckets = {}   -- sender -> { tokens, t }
local recent = {}    -- tier -> { { t, sender } } of the lines shown in the last minute
local lastLog = {}   -- sender -> time of the last drop we logged
local lastSend = -math.huge
local mine = {}      -- "id#text" -> time: our own lines, shown when sent (their echo is not shown again)
local nextId = math.random(0, 9999)
local held = {}      -- tier -> lines the flood guard kept off the chat since its last notice
local heldSince      -- when the first of them was held
local lastNotice = -math.huge
local noticeTimer = false
local gone = {}      -- chosen window name (lower case) -> true once we said it is gone
local found = {}     -- chosen window name (lower case) -> true once found this session (1.1.1)

local function Label(tier)
	return L[TIERS[tier].label]
end

-- 1.1 (request #11): the Sylvanistas chats are the player's choice, on the first-open page
-- (Consent.lua) or /syl chat on|off. Off until they answer (ns.db.addonChat is nil until then,
-- account-wide), and off after a No: this client neither sends nor shows [Sylvanistas], [Captains]
-- or [Lords]. A line that arrives is dropped before anything keeps it (no history, nothing to
-- the Chat tab or a companion through the bridge); the client still sits in the channel, for
-- the census.
function Channels.ChatOn() return ns.db ~= nil and ns.db.addonChat == true end
function Channels.ChatState()
	local v = ns.db and ns.db.addonChat
	return v == true and "on" or (v == false and "off" or "not chosen (off)")
end
function Channels.SetChatOn(on)
	ns.db.addonChat = on and true or false
	ns.Print(on and L.CHAT_ON_MSG or L.CHAT_OFF_MSG)
	ns.Fire("CHAT_CHANGED")
end
local offHinted = false -- a line dropped while unanswered: said once a session
function Channels.ResetOffHint() offHinted = false end -- tests

local function Muted()
	ns.db.chatMute = ns.db.chatMute or {}
	return ns.db.chatMute
end

-- The channels whose warning the player accepted before their first line there. Account-wide.
local function Warned()
	ns.db.chatWarned = ns.db.chatWarned or {}
	return ns.db.chatWarned
end

-- History is per realm, like the census.
local function Store(tier)
	ns.rdb.chat = ns.rdb.chat or {}
	local list = ns.rdb.chat[tier]
	if not list then
		list = {}
		ns.rdb.chat[tier] = list
	end
	return list
end

local function NextId()
	nextId = (nextId + 1) % 10000
	return nextId
end

---------------------------------------------------------------------------
-- Who may read and write what. Levels: 0 outside Sylvanistas, 1 member, 2 Captain, 3 Lord.
---------------------------------------------------------------------------

function Channels.LevelOf(guild, rankIndex)
	if not ns.IsFederation(guild) then return 0 end
	-- To keep [Lords] for guild masters only, use rankIndex == 0 here instead of the Crown.
	if rankIndex and ns.IsCrownRank(guild, rankIndex) then return 3 end
	if rankIndex and rankIndex <= ns.CAPTAIN_RANK then return 2 end
	return 1
end

-- Our own rank always comes from the server.
function Channels.MyLevel()
	if not ns.IsMember() then return 0 end
	return Channels.LevelOf(GetGuildInfo("player"), ns.Roster.MyRank())
end

function Channels.CanUse(tier)
	local t = TIERS[tier]
	return t ~= nil and Channels.MyLevel() >= t.level
end

-- The level a sender really has, and whether it was verified. Our own guild: from our
-- roster. Other guilds: from that guild's fresh report (leader or officer), and a sender
-- speaks for one guild only (Data.ClaimGuild). Returns 0 when the guild claim is false.
-- Verified, the rank index it was read from too (0: the guild master; the King's Crown: 0).
function Channels.VerifiedLevel(sender, guild)
	local who = ns.FullName(sender)
	local rank = ns.Roster.RankOf(who)
	local mine = GetGuildInfo("player")
	if mine and guild:lower() == mine:lower() then
		if guild ~= mine then return 0, false end -- our name spelled another way (names ignore case)
		if rank then return Channels.LevelOf(guild, rank), true, rank end
		if ns.Roster.byName == nil then return 1, false end -- roster not read yet
		return 0, false -- not in our roster: not one of us
	end
	if rank then return 0, false end -- a guildmate of ours speaking for another guild
	-- The King by his pinned name (the server stamps it), never by a census vote, his Steward (the
	-- signed titles list, King.IsStewardName) and the Hands the King's list or a Steward's own
	-- names (King.IsHandName): of his Crown for his guild here, outside it (1.0.0).
	if ns.IsKingGuild(guild) and (ns.IsKingCharacter(who)
		or (ns.King ~= nil and (ns.King.IsStewardName(who) or ns.King.IsHandName(who)))) then
		return Channels.LevelOf(guild, 0), true, 0
	end
	if not ns.Data.ClaimGuild(who, guild) then return 0, false end
	local known = ns.Data.KnownRank(who, guild)
	if known == nil then return 1, false end
	return Channels.LevelOf(guild, known), true, known
end

---------------------------------------------------------------------------
-- Display and history
---------------------------------------------------------------------------

-- "[Captains] [Name] <Guild>: text". The name is a player link, like in any chat line, so a
-- click opens the usual whisper and menu (to the name the server finds, ns.TellName). The
-- text is sanitized again here: history comes from the SavedVariables too. bare (1.1.1, the
-- Sylvanistas tab): without "[Captains] ", the rest byte for byte the same.
function Channels.FormatLine(tier, sender, guild, class, text, bare)
	local name = ns.DisplayName(sender) or "?"
	-- The High Council (the moderators, Core.lua): their colour. For everyone, as in 0.9.8, but the
	-- King while the councillors' names are hidden on his screen (his stream, ns.CouncilMasked): a
	-- plain line.
	local council = ns.IsHighCouncillor(sender) and not ns.CouncilMasked()
	if council then
		name = "|c" .. ns.HIGH_COUNCIL_COLOR .. name .. "|r"
	else
		local file = class and ns.CLASS_FILES[class]
		local color = file and RAID_CLASS_COLORS and RAID_CLASS_COLORS[file]
		if color and color.colorStr then name = "|c" .. color.colorStr .. name .. "|r" end
	end
	-- The mark before the name, as the Chat tab shows it (1.1.2, Borders.ChatMark): the King's crown,
	-- the High Council's mark and icon (0.9.9), silver, bronze, the star. Without Borders.lua (a
	-- client updated without a restart), the High Council's alone, as before 1.1.2.
	local B = ns.Borders
	local mark = B and type(B.ChatMark) == "function" and B.ChatMark(sender, guild) or (council and ns.CouncilMark(sender)) or ""
	-- The Treasurer: the gold coin he carries in tooltips and the census (0.9.9), first.
	if ns.IsTreasurer(sender, guild) then mark = (ns.COIN:gsub(" $", "")) .. mark end
	name = mark .. name
	return (bare and "" or "[" .. Label(tier) .. "] ") .. "|Hplayer:" .. (ns.TellName(sender) or "?") .. "|h[" .. name .. "]|h <"
		.. tostring(guild or "?"):gsub("|", "||") .. ">: " .. Codec.SanitizeChat(text)
end

---------------------------------------------------------------------------
-- The chat window each channel shows in (/syl chatwindow). Output only: Sylvanistas adds its lines
-- to the window the player chose as it adds them to the main one, and never touches a window's
-- edit box, tabs or dock. (Replacing the chat box's scripts, or opening a window from addon
-- code, runs Blizzard's chat code tainted: /cast, /use or /target typed there get blocked.)
-- The player makes the tab in the game and picks it here. The choice is the window's name, per
-- character like the game's own chat windows, looked up each time a line is shown: a window
-- closed or renamed sends its lines back to the main window, with one notice. (Checking the
-- window at print time and falling back to the main one comes from RoyLeviGit's pull request
-- #20, "native chat tabs".)
---------------------------------------------------------------------------

local function MaxWindows()
	local c = Constants and Constants.ChatFrameConstants and Constants.ChatFrameConstants.MaxChatWindows
	return tonumber(NUM_CHAT_WINDOWS) or tonumber(c) or 10
end

-- Chat window i: its frame, its name, whether it is open (shown, or docked behind another tab:
-- the game counts a docked tab not selected as not shown) and whether it is the combat log,
-- which clears and refills itself (a line of ours there would vanish).
local function WindowAt(i)
	local f = _G["ChatFrame" .. i]
	if type(f) ~= "table" or type(f.AddMessage) ~= "function" then return nil end
	local info = GetChatWindowInfo or FCF_GetChatWindowInfo
	local name, shown
	if type(info) == "function" then
		local ok, n, _, _, _, _, _, s = pcall(info, i)
		if ok then name, shown = n, s end
	end
	if type(name) ~= "string" or name == "" then name = type(f.name) == "string" and f.name ~= "" and f.name or nil end
	local combat = false
	if type(IsCombatLog) == "function" then
		local ok, res = pcall(IsCombatLog, f)
		combat = ok and res and true or false
	end
	return f, name, (shown or f.isDocked) and true or false, combat
end

local function Trim(text) return (tostring(text):match("^%s*(.-)%s*$")) end

---------------------------------------------------------------------------
-- Chattynator's tabs (1.1.2; from hypertectonic's pull request #47, . Chattynator, a
-- chat addon, moves the game's chat windows into a hidden frame of its own and shows its own
-- windows and tabs in their place (Core/Overrides.lua): a line added to one of the game's windows
-- there is never seen, but for the main one's, whose AddMessage it hooks. Its public API
-- (Chattynator.API, API/Main.lua, the same from its release 151 to 224) is all Sylvanistas uses:
-- GetWindowsAndTabs (its tabs' names, window by window, a new list at each call) and
-- AddMessageToWindowAndTab(window, tab, text, r, g, b) (a line in that tab). Sylvanistas never makes,
-- names or sets up a tab of Chattynator's, nor its filters; nothing of the game's is called on
-- that path (Chattynator draws the line later, from its own code). While Chattynator answers, its
-- tabs are the chat windows Sylvanistas picks from, by name, looked up at each line as the game's
-- windows are (a tab moved gets the next lines where it is now; removed or renamed, they go back
-- to the main window, with one notice); the game's own windows, hidden, are left out. A tab shows
-- an addon's lines only when its filter lets that addon in (its Tab Settings, Addons, Sylvanistas
-- ticked): Sylvanistas cannot read that filter, so the main window says how each time such a tab is
-- chosen.
---------------------------------------------------------------------------

-- Chattynator's own name for its combat log tab (Core/Initialize.lua): no place for our lines, as
-- the game's combat log is none.
local CHATTY_COMBAT = "COMBAT_LOG"

-- A tab's name as Chattynator shows it: a name that is one of the game's strings shows as that
-- string (its GetTabNameFromName: its first tab, "GENERAL", shows "General", or "Geral" in pt-BR).
local function ChattyLabel(raw)
	local shown = _G[raw]
	if type(shown) == "string" and Trim(shown) ~= "" then return shown end
	return raw
end

-- Chattynator's tabs now, in its order: { window, tab, raw (its name as kept), name (as it shows),
-- combat }, each; nil when Chattynator does not answer (not loaded, an API without these two
-- functions, or failing), and then the game's windows are the ones. All of it through pcall: a
-- broken Chattynator, or anything else called Chattynator, is only "not there". A name with a
-- "|" in it is left out: Chattynator's search tab, a passing one, is named with a texture code
-- (Display/Buttons.lua), shown escaped in a list and only showing the lines its search finds.
local function ChattyTabs()
	local ok, list = pcall(function()
		local api = type(Chattynator) == "table" and Chattynator.API or nil
		if type(api) ~= "table" or type(api.GetWindowsAndTabs) ~= "function" or type(api.AddMessageToWindowAndTab) ~= "function" then
			return nil
		end
		local windows = api.GetWindowsAndTabs()
		if type(windows) ~= "table" then return nil end
		local out = {}
		for wi, tabs in ipairs(windows) do
			if type(tabs) == "table" then
				for ti, raw in ipairs(tabs) do
					if type(raw) == "string" and Trim(raw) ~= "" and not raw:find("|", 1, true) then
						out[#out + 1] = { window = wi, tab = ti, raw = raw, name = ChattyLabel(raw), combat = raw == CHATTY_COMBAT }
					end
				end
			end
		end
		return out
	end)
	if ok and type(list) == "table" then return list end
	return nil
end

-- Whether Chattynator's tabs are the chat windows now (the Chat tab's settings, ChatWindow.lua).
function Channels.Chattynator()
	return ChattyTabs() ~= nil
end

-- The tab of `tabs` called `want` (lower case, spaces around it aside), by the name it shows or the
-- one it keeps: the tab, and that name.
local function FindChatty(want, tabs)
	for _, t in ipairs(tabs) do
		if Trim(t.name):lower() == want then return t, t.name end
		if Trim(t.raw):lower() == want then return t, t.raw end
	end
	return nil
end

-- One line to Chattynator's tab (window wi, tab ti). Chattynator names the line's addon after the
-- caller of AddMessageToWindowAndTab (debugstack(2)), and a tab's filter lets it in by that name:
-- this function, of Sylvanistas/Channels.lua, is that caller, so the line is Sylvanistas's. It calls the
-- API itself, and not as its last word: pcall(api.AddMessageToWindowAndTab, ...) would make pcall
-- the caller, `return api.AddMessageToWindowAndTab(...)` a tail call that leaves this frame out,
-- and either one names no addon ("/loadstring"), which a tab letting Sylvanistas in does not show.
local function Deliver(wi, ti, text, r, g, b)
	local api = Chattynator.API
	api.AddMessageToWindowAndTab(wi, ti, text, r, g, b)
	return true
end

local chattyTargets = setmetatable({}, { __mode = "k" })
local function IsChatty(f) return f ~= nil and chattyTargets[f] == true end

-- A Chattynator tab as the lines' target (Show, Say, Intro use it as a chat window): its own
-- AddMessage. A line it fails to take (Chattynator broken, or not ready: its API may print the line
-- first, then fail) goes to the main window, whole: nothing lost, no error.
local function ChattyTarget(t)
	local wi, ti = t.window, t.tab
	local f = { AddMessage = function(_, text, r, g, b)
		if pcall(Deliver, wi, ti, text, r, g, b) then return end
		if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(text, r, g, b) end
	end }
	chattyTargets[f] = true
	return f
end

-- The open chat window called `name` (in any case, spaces around it aside): its frame, number and
-- name as the game has it. While Chattynator answers, its tab of that name: a target
-- (ChattyTarget), no number, and its name; the game's windows, hidden, are left out (1.1.2).
function Channels.FindWindow(name)
	if type(name) ~= "string" then return nil end
	local want = Trim(name):lower()
	if want == "" then return nil end
	local tabs = ChattyTabs()
	if tabs then
		local t, as = FindChatty(want, tabs)
		if t and not t.combat then return ChattyTarget(t), nil, as end
		return nil
	end
	for i = 1, MaxWindows() do
		local f, wname, open, combat = WindowAt(i)
		if f and open and not combat and wname and Trim(wname):lower() == want then return f, i, wname end
	end
	return nil
end

local function Quoted(name)
	return '"' .. tostring(name):gsub("|", "||") .. '"'
end

-- This character's choices: tier -> window name.
local function Chosen()
	local all = ns.db and ns.db.chatWindows
	local list = type(all) == "table" and ns.me and all[ns.me]
	return type(list) == "table" and list or nil
end

-- A line of ours ("Sylvanistas: ...") in target f, what ns.Print writes in the main window.
local function Say(f, msg)
	if not f or f == DEFAULT_CHAT_FRAME then return ns.Print(msg) end
	f:AddMessage("|c" .. ns.COLOR .. "Sylvanistas:|r " .. tostring(msg))
end

---------------------------------------------------------------------------
-- The Sylvanistas tab (1.1.1): an open chat window of the game's, not the main one nor the combat
-- log, whose name is "Sylvanistas" (any case, spaces around it aside). Its lines come without the
-- channel's name, each in its channel's colour (Show); anywhere else they keep it. The player
-- makes the tab with the game's own menu (right-click the main tab, Create New Window), and
-- Sylvanistas routes the channels there by name, as /syl chatwindow does: it never makes, names,
-- docks or sets up a chat window. FCF_OpenNewWindow (FloatingChatFrame.lua) writes the window's
-- name, its message groups, the dock's tables and, last, LAST_ACTIVE_CHAT_EDIT_BOX
-- (ChatFrameUtil.SetLastActiveWindow); called from an addon, all of it is written by insecure
-- code, the game's secure chat code reads it next (ChatFrameUtil.ChooseBoxForSend) and /cast,
-- /target, /use or /click typed in the chat box get blocked (with the gamepad UI, the 0.8.5
-- freeze). FCF_NewChatWindow is the game's NAME_CHAT popup that runs it, and a frame's
-- RemoveAllMessageGroups writes its message list. The one call Sylvanistas makes on a game chat
-- window is AddMessage, a secure elevation barrier (ScrollingMessageFrame.lua: it runs as if
-- untainted, what print does on the main window); the rest is read (GetChatWindowInfo,
-- GetChatWindowMessages, GetChatWindowChannels, the frame's own fields).
---------------------------------------------------------------------------

Channels.TAB_NAME = "Sylvanistas"
local TAB_KEY = Channels.TAB_NAME:lower()

function Channels.IsTabName(name)
	return type(name) == "string" and Trim(name):lower() == TAB_KEY
end

-- The Sylvanistas tab open now: its frame, number and name as the game has it, else nil. While
-- Chattynator answers, its tab named Sylvanistas (1.1.2): the game's window of that name is hidden
-- behind Chattynator's, and a line there was never seen again, through 1.1.1's tab).
local function FindTab()
	local tabs = ChattyTabs()
	if tabs then
		-- (Its combat log tab, "COMBAT_LOG", is never the one named Sylvanistas.)
		local t, as = FindChatty(TAB_KEY, tabs)
		if t then return ChattyTarget(t), nil, as end
		return nil
	end
	for i = 1, MaxWindows() do
		local f, wname, open, combat = WindowAt(i)
		if f and open and not combat and f ~= DEFAULT_CHAT_FRAME and Channels.IsTabName(wname) then return f, i, wname end
	end
	return nil
end
-- (Read only, for the Chat tab's guided way to the Sylvanistas tab, ChatWindow.lua.)
Channels.FindTab = FindTab

local function IndexOf(f)
	for i = 1, MaxWindows() do
		if _G["ChatFrame" .. i] == f then return i end
	end
	return nil
end

-- The game's own words for its menus (its global strings, in the player's language), else ours.
local function GameWord(value, fallback)
	return type(value) == "string" and value ~= "" and value or fallback
end

-- The main window's tab as the game names it ("General"), where its menu makes a new window.
local function MainTabName()
	for i = 1, MaxWindows() do
		local f, name = WindowAt(i)
		if f and f == DEFAULT_CHAT_FRAME then
			if type(name) == "string" and Trim(name) ~= "" then return (name:gsub("|", "||")) end
			break
		end
	end
	return L.CHATTAB_MAIN_TAB
end
Channels.MainTabName = MainTabName

-- Whether chat window i also shows other chat (Say, Guild, whispers, channels): what the game
-- registers it for, read as Blizzard's ChatFrameOverrides.lua reads it. Neither function is in
-- the API documentation: through pcall, and unknown says nothing.
local function Registers(api, i)
	if type(api) ~= "function" then return false end
	local ok, first = pcall(api, i)
	return ok and first ~= nil
end
local function Mixed(i)
	return i ~= nil and (Registers(GetChatWindowMessages, i) or Registers(GetChatWindowChannels, i))
end

-- "[Sylvanistas], [Captains], [Lords]", each in its channel's colour: the tab's legend.
local function Legend()
	local parts = {}
	for _, tier in ipairs(Channels.ORDER) do
		local c = TIERS[tier].color
		parts[#parts + 1] = ("|cff%02x%02x%02x[%s]|r"):format(math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5),
			math.floor(c[3] * 255 + 0.5), Label(tier))
	end
	return table.concat(parts, ", ")
end

-- Whether this character was told, in its Sylvanistas tab, what the tab holds (per character, as the
-- choice of windows is). Which Sylvanistas tab (1.1.2): true for the game's, "chatty" for Chattynator's,
-- so a player told in the game's tab before Chattynator is told again in its tab, with the hint
-- of its filter (a new tab of Chattynator's lets no addon in: without it he would see nothing, and
-- not know why). f: the tab's target (nil: the game's).
local function IntroKind(f) return IsChatty(f) and "chatty" or true end
local function IntroSaid(f)
	local all = ns.db and ns.db.chatTabIntro
	return type(all) == "table" and ns.me ~= nil and all[ns.me] == IntroKind(f)
end
local function SetIntroSaid(said, f)
	if not ns.db or not ns.me then return end
	local all = type(ns.db.chatTabIntro) == "table" and ns.db.chatTabIntro or {}
	all[ns.me] = said and IntroKind(f) or nil
	ns.db.chatTabIntro = next(all) ~= nil and all or nil
end

-- A tab of Chattynator's chosen, f its target (1.1.2): what the tab shows is its filter's call,
-- which Sylvanistas cannot read; so the main window, which shows, says how to let Sylvanistas in.
local function FilterHint(f, name)
	if IsChatty(f) then ns.Print(L.CHATTY_FILTER:format(Quoted(name))) end
end

-- Said in the Sylvanistas tab f (chat window i): the Sylvanistas chats show there, the legend of their
-- colours, and, when the tab shows other chat too, how to have them alone there. In Chattynator's
-- tab (1.1.2) the tab may not show it (its filter): the main window says how to let Sylvanistas in.
local function Intro(f, i, name)
	SetIntroSaid(true, f)
	Say(f, L.CHATTAB_HERE:format(Legend()))
	if IsChatty(f) then
		FilterHint(f, name or Channels.TAB_NAME)
	elseif Mixed(i or IndexOf(f)) then
		Say(f, L.CHATTAB_MIXED:format(GameWord(CHAT_CONFIGURATION, L.CHATTAB_SETTINGS)))
	end
end

-- The frame a channel's lines go to (a chat window, or a Chattynator tab's target, 1.1.2), and the
-- chosen window's name as the game has it (nil for the main window): its chosen window while it is
-- open, else the main one. A window closed or renamed is said once. The Sylvanistas tab (1.1.1): chosen
-- and never seen this session (the one click made the choice before the player made the tab), the
-- main window says once that the chats wait for it, not that it is gone; the first time it takes
-- the lines for this character, it says so first.
function Channels.Frame(tier)
	local chosen = Chosen()
	local name = chosen and chosen[tier]
	if type(name) == "string" then
		local key = Trim(name):lower()
		local f, i, wname
		if Channels.IsTabName(name) then f, i, wname = FindTab() end
		if not f then f, i, wname = Channels.FindWindow(name) end
		if f then
			gone[key] = nil
			found[key] = true
			if f == DEFAULT_CHAT_FRAME then return f end
			if Channels.IsTabName(wname) and not IntroSaid(f) then Intro(f, i, wname) end
			return f, wname
		end
		if not gone[key] then
			gone[key] = true
			if Channels.IsTabName(name) and not found[key] then
				ns.Print(L.CHATTAB_WAITING)
			else
				ns.Print(L.CHATWIN_GONE:format(Quoted(name)))
			end
		end
	end
	return DEFAULT_CHAT_FRAME
end

-- This character's choices, made writable.
local function Choices()
	ns.db.chatWindows = type(ns.db.chatWindows) == "table" and ns.db.chatWindows or {}
	local list = type(ns.db.chatWindows[ns.me]) == "table" and ns.db.chatWindows[ns.me] or {}
	ns.db.chatWindows[ns.me] = list
	return list
end

-- One click (the Chat tab's settings, or /syl chatwindow tab): the three channels to the
-- Sylvanistas tab, for this character, even a channel its rank does not read yet (a promotion keeps
-- it there). The tab open: said in the main window, and in the tab (Intro). Not made yet: how to
-- make it, with the game's own words for its menus (with Chattynator, how in Chattynator, 1.1.2);
-- the lines stay in the main window meanwhile, and land in the tab the moment it exists.
-- /syl chatwindow main undoes it. Returns true, "open" | "waiting".
function Channels.SetupTab()
	if not ns.db or not ns.me then return false, "none" end
	local list, labels = Choices(), {}
	for _, tier in ipairs(Channels.ORDER) do
		list[tier] = Channels.TAB_NAME
		labels[#labels + 1] = "[" .. Label(tier) .. "]"
	end
	wipe(gone)
	local f, i, wname = FindTab()
	if f then
		found[TAB_KEY] = true
		ns.Print(L.CHATTAB_SET:format(table.concat(labels, ", ")))
		Intro(f, i, wname)
		ns.Fire("CHAT_SETTINGS_CHANGED")
		return true, "open"
	end
	found[TAB_KEY] = nil
	SetIntroSaid(false) -- (the tab the player makes now says what it holds)
	if ChattyTabs() then
		ns.Print(L.CHATTY_STEPS)
	else
		ns.Print(L.CHATTAB_STEPS:format(MainTabName(), GameWord(NEW_CHAT_WINDOW, L.CHATWIN_NEW),
			GameWord(CHAT_CONFIGURATION, L.CHATTAB_SETTINGS)))
	end
	ns.Fire("CHAT_SETTINGS_CHANGED")
	return true, "waiting"
end

-- The Sylvanistas tab there at last, after a click that already sent the channels to it (with
-- Chattynator, 1.1.2: SetupTab ran at the click, "waiting"; the Chat tab reads Chattynator's tabs,
-- ChatWindow.lua). Said as SetupTab says it, once, and nothing chosen again: the channels still
-- going there (one the player moved since stays where he put it), and not at all when a line got
-- there first (its intro said it then) or none goes there now. Returns true when said.
function Channels.TabArrived()
	if not ns.db or not ns.me then return false end
	local chosen = Chosen()
	if not chosen then return false end
	local labels = {}
	for _, tier in ipairs(Channels.ORDER) do
		if Channels.IsTabName(chosen[tier]) then labels[#labels + 1] = "[" .. Label(tier) .. "]" end
	end
	if #labels == 0 then return false end
	local f, i, wname = FindTab()
	if not f or IntroSaid(f) then return false end
	gone[TAB_KEY], found[TAB_KEY] = nil, true
	ns.Print(L.CHATTAB_SET:format(table.concat(labels, ", ")))
	Intro(f, i, wname)
	ns.Fire("CHAT_SETTINGS_CHANGED")
	return true
end

-- "open": a channel of this character's goes to the Sylvanistas tab, and it is open; "waiting":
-- chosen, not open (not made yet, closed or renamed); "none".
function Channels.TabState()
	local chosen = Chosen()
	if not chosen then return "none" end
	for _, tier in ipairs(Channels.ORDER) do
		if Channels.IsTabName(chosen[tier]) then return FindTab() and "open" or "waiting" end
	end
	return "none"
end

-- The window this character chose for a channel's lines (its name as chosen), nil for the main
-- one. (Read only: the Chat tab leaves its Sylvanistas tab line out for a player who picked a window
-- of his own, ChatWindow.lua.)
function Channels.ChosenWindow(tier)
	local chosen = Chosen()
	local name = chosen and chosen[tier]
	return type(name) == "string" and name or nil
end

-- The chat windows open now but the main one and the combat log, { index, name } each in their
-- order: the ones the Chat tab's settings offer a channel, picked by number as /syl chatwindow
-- <number> picks them (read only, as WindowAt reads them). While Chattynator answers (1.1.2), its
-- tabs but its combat log instead, { name, raw } each (no number: Channels.ChooseTab picks them by
-- name); the game's windows are hidden behind them.
function Channels.OpenWindows()
	local out = {}
	local tabs = ChattyTabs()
	if tabs then
		for _, t in ipairs(tabs) do
			if not t.combat then out[#out + 1] = { name = t.name, raw = t.raw } end
		end
		return out
	end
	for i = 1, MaxWindows() do
		local f, name, open, combat = WindowAt(i)
		if f and open and not combat and name and f ~= DEFAULT_CHAT_FRAME then out[#out + 1] = { index = i, name = name } end
	end
	return out
end

-- "[Sylvanistas] main window, [Captains] "Sylvanistas"" for /syl chatwindow and /syl status.
function Channels.WindowStatus()
	local chosen = Chosen() or {}
	local parts = {}
	for _, tier in ipairs(Channels.ORDER) do
		local name = chosen[tier]
		local where = L.CHATWIN_MAIN_NAME
		if type(name) == "string" then
			where = Quoted(name) .. (Channels.FindWindow(name) and "" or " " .. L.CHATWIN_GONE_TAG)
		end
		parts[#parts + 1] = "[" .. Label(tier) .. "] " .. where
	end
	return table.concat(parts, ", ")
end

-- A window by number or by name: frame, name, or nil and why ("combat"). While Chattynator
-- answers (1.1.2), its tab by name alone (a tab called "2" is that tab; the game's window 2 is
-- hidden), its combat log refused as the game's is.
local function PickWindow(word)
	local tabs = ChattyTabs()
	if tabs then
		local t, as = FindChatty(Trim(word):lower(), tabs)
		if not t then return nil end
		if t.combat then return nil, nil, "combat" end
		return ChattyTarget(t), as
	end
	local n = tonumber(word)
	if n and n == math.floor(n) and n >= 1 and n <= MaxWindows() then
		local f, name, open, combat = WindowAt(n)
		if f and open and name then
			if combat then return nil, nil, "combat" end
			return f, name
		end
		return nil
	end
	local f, _, name = Channels.FindWindow(word)
	if f then return f, name end
	-- (The combat log is left out of FindWindow: say why rather than "not found".)
	for k = 1, MaxWindows() do
		local cf, cname, open, combat = WindowAt(k)
		if cf and open and combat and cname and cname:lower() == tostring(word):lower() then return nil, nil, "combat" end
	end
	return nil
end

-- Chattynator's tabs, "General", "Sylvanistas", ..., for a line in chat (its combat log left out).
local function ChattyNames(tabs)
	local names = {}
	for _, t in ipairs(tabs) do
		if not t.combat then names[#names + 1] = Quoted(t.name) end
	end
	return #names > 0 and table.concat(names, ", ") or "-"
end

-- The channels `tiers` to the window f called `name` (nil: the main one), for this character, said
-- in the main window and in that window (the Sylvanistas tab says what it holds instead; a tab of
-- Chattynator's, how to let Sylvanistas in). /syl chatwindow's and ChooseTab's own end.
local function Choose(f, name, tiers)
	local list = Choices()
	local labels = {}
	for _, tier in ipairs(tiers) do
		list[tier] = name
		labels[#labels + 1] = "[" .. Label(tier) .. "]"
	end
	if next(list) == nil then ns.db.chatWindows[ns.me] = nil end
	if next(ns.db.chatWindows) == nil then ns.db.chatWindows = nil end
	wipe(gone)
	ns.Fire("CHAT_SETTINGS_CHANGED")
	if not name then
		ns.Print(L.CHATWIN_MAIN:format(table.concat(labels, ", ")))
		return true
	end
	found[Trim(name):lower()] = true
	local msg = L.CHATWIN_SET:format(table.concat(labels, ", "), Quoted(name))
	ns.Print(msg)
	-- And in that window, to show where they land; the Sylvanistas tab says what it holds instead.
	if Channels.IsTabName(name) then
		Intro(f, nil, name)
	else
		Say(f, msg)
		FilterHint(f, name)
	end
	return true
end

-- One channel to Chattynator's tab called `name` (1.1.2), for the Chat tab's settings, which pick
-- its tabs by name: in /syl chatwindow's words a tab called "main" would be the main window. Said
-- as /syl chatwindow says it. Returns true, or false (Chattynator not there, no such tab, its
-- combat log).
function Channels.ChooseTab(name, tier)
	if not ns.me or not TIERS[tier] or type(name) ~= "string" then return false end
	local tabs = ChattyTabs()
	if not tabs then return false end
	local t, as = FindChatty(Trim(name):lower(), tabs)
	if not t or t.combat then return false end
	return Choose(ChattyTarget(t), as, { tier })
end

local MAIN_WORDS = { main = true, default = true, principal = true }
local ALL_WORDS = { all = true, todos = true }
local TAB_WORDS = { tab = true, aba = true }

-- /syl chatwindow <number | name | main | tab> [sylvanistas | captains | lords]
function Channels.ChooseWindow(input)
	input = tostring(input or ""):match("^%s*(.-)%s*$")
	if input == "" then
		ns.Print(L.CHATWIN_NOW:format(Channels.WindowStatus()))
		ns.Print(L.CHATWIN_USAGE)
		return false
	end
	if not ns.me then return false end
	-- tab (or aba): the Sylvanistas tab, made already or not (1.1.1). Before any window's name, as main.
	if TAB_WORDS[input:lower()] then return Channels.SetupTab() end
	-- The whole text first (a window may be called "Sylvanistas Lords"), then a channel at its end.
	local target, tiers = input, Channels.ORDER
	if not MAIN_WORDS[input:lower()] and not PickWindow(input) then
		local head, last = input:match("^(.-)%s+(%S+)$")
		if head and head ~= "" then
			if ALL_WORDS[last:lower()] then
				target = head
			elseif Channels.TierForWord(last) then
				target, tiers = head, { Channels.TierForWord(last) }
			end
		end
	end
	local f, name, why
	if not MAIN_WORDS[target:lower()] then
		f, name, why = PickWindow(target)
		if not f then
			if why == "combat" then
				ns.Print(L.CHATWIN_COMBATLOG)
			else
				-- (With Chattynator, its tabs by name, and how to make one there, 1.1.2.)
				local tabs = ChattyTabs()
				if tabs then
					ns.Print(L.CHATTY_NOT_FOUND:format(Quoted(target), ChattyNames(tabs)))
					return false
				end
				local open = {}
				for i = 1, MaxWindows() do
					local wf, wname, isOpen, combat = WindowAt(i)
					if wf and isOpen and not combat and wname then open[#open + 1] = i .. " " .. Quoted(wname) end
				end
				local menu = type(NEW_CHAT_WINDOW) == "string" and NEW_CHAT_WINDOW ~= "" and NEW_CHAT_WINDOW or L.CHATWIN_NEW
				ns.Print(L.CHATWIN_NOT_FOUND:format(Quoted(target), #open > 0 and table.concat(open, ", ") or "-", menu))
			end
			return false
		end
		if f == DEFAULT_CHAT_FRAME then name = nil end -- the main window: nothing to remember
	end
	return Choose(f, name, tiers)
end

-- AddMessage on the channel's output target (what print does on the main one), using
-- Chattynator's public API for its tabs: nothing of Blizzard's is replaced or hooked. In the
-- Sylvanistas tab without the channel's name (1.1.1): the line's colour tells the channels apart, and
-- the tab's first line gave the legend.
local function Show(tier, sender, guild, class, text)
	local f, wname = Channels.Frame(tier)
	if not f then return end
	local c = TIERS[tier].color
	local bare = f ~= DEFAULT_CHAT_FRAME and Channels.IsTabName(wname)
	f:AddMessage(Channels.FormatLine(tier, sender, guild, class, text, bare), c[1], c[2], c[3])
end

local function AddHistory(tier, e)
	local list = Store(tier)
	list[#list + 1] = { t = ns.Now(), sender = e.sender, guild = e.guild, class = e.class, text = e.text, mine = e.mine }
	while #list > HISTORY do table.remove(list, 1) end
end

-- Every line kept goes through here, whether it is then shown, muted or held back by the flood
-- guard: into the history the Chat tab shows (CHAT_CHANGED) and, from someone else, already
-- checked and sanitized, as CHAT_LINE. The mute and the flood guard only decide what this chat
-- frame shows.
local function Keep(tier, sender, guild, class, text, mine)
	AddHistory(tier, { sender = sender, guild = guild, class = class, text = text, mine = mine or nil })
	ns.Fire("CHAT_CHANGED", tier)
	if not mine then ns.Fire("CHAT_LINE", tier, sender, text) end
end

local function Accept(tier, sender, guild, class, text, mine)
	Keep(tier, sender, guild, class, text, mine)
	if Muted()[tier] then return false, "muted" end
	Show(tier, sender, guild, class, text)
	stats.shown = stats.shown + 1
	return true, "ok"
end

-- The lines of a channel we may read (for a future Channels view, with CHAT_CHANGED). None
-- while the chats are off on this client (1.1): lines kept before that don't show either.
function Channels.History(tier)
	if not Channels.CanUse(tier) or not Channels.ChatOn() then return {} end
	local list = Store(tier)
	-- 1.1: lines kept before the moderators took their writer off leave the view too (net-off).
	local M = ns.Moderation
	if not (M.Any and M.Any()) then return list end
	local out = {}
	for _, e in ipairs(list) do
		if not M.Hides(e.sender, e.guild) then out[#out + 1] = e end
	end
	return out
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function Locked()
	return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() and true or false
end

-- Returns ok, reason. Every refusal tells the player why. A line sent unmutes its channel in the
-- chat frame (/sy typed in chat), unless keepMute: the chat window (1.1.1) shows a channel muted
-- in chat and writes in it without bringing it back there.
function Channels.Send(tier, text, now, keepMute)
	local t = TIERS[tier]
	if not t then return false, "tier" end
	if not ns.IsMember() then
		ns.Print(L.MEMBERS_ONLY)
		return false, "member"
	end
	if not Channels.CanUse(tier) then
		ns.Print(L[t.deny]:format(Label(tier)))
		return false, "rank"
	end
	-- The chats off on this client (1.1): nothing leaves. Never answered: the page asks.
	if not Channels.ChatOn() then
		if ns.db.addonChat == nil then
			ns.Print(L.CHAT_OFF_UNANSWERED)
			if ns.Consent and ns.Consent.Ask then ns.Consent.Ask("chat") end
		else
			ns.Print(L.CHAT_OFF)
		end
		return false, "off"
	end
	-- 1.1: the moderators took this character off the chats (net-off, Moderation.lua).
	local off = ns.Moderation.SelfOff and ns.Moderation.SelfOff()
	if off then
		ns.Print(ns.Moderation.YouText(off))
		return false, "netoff"
	end
	text = Codec.SanitizeChat(text)
	if text == "" then
		ns.Print(L.CHAN_USAGE:format(t.slash, Label(tier)))
		return false, "empty"
	end
	if Locked() then
		ns.Print(L.CHAN_LOCKDOWN)
		return false, "lockdown"
	end
	now = now or GetTime()
	if now - lastSend < SEND_GAP then
		ns.Print(L.CHAN_TOO_FAST)
		return false, "fast"
	end
	if not ns.Comm.ChannelReady() then
		ns.Print(L.CHAN_NOT_READY)
		return false, "ready"
	end
	-- The first line in each channel waits for the player's OK: nothing is private there, and
	-- they are told so before anything leaves (Channels.Confirm sends it). The warning holds the
	-- channel it named too .
	if not Warned()[tier] then
		ns.ShowDialog("SYLVANISTAS_CHAT_PRIVACY", Label(tier), ns.Comm.Audience(), { tier = tier, text = text, channel = ns.Comm.ChannelName(), keepMute = keepMute or nil })
		return false, "confirm"
	end
	local guild = GetGuildInfo("player")
	local class = ns.Roster.ClassCode(UnitClass and select(2, UnitClass("player")))
	-- Classes without a 2 letter code travel without a class (the decoder only takes 2 letters).
	if not class:match("^%u%u$") then class = "" end
	local parts, cut = Codec.SplitChat(text, Codec.ChatBudget(guild, class), Codec.CHAT_PARTS)
	if ns.Comm.ChatRoom() < #parts then
		ns.Print(L.CHAN_BUSY)
		return false, "busy"
	end
	if cut then ns.Print(L.CHAN_TRUNCATED) end
	if Muted()[tier] and not keepMute then
		Muted()[tier] = nil
		ns.Print(L.CHAN_UNMUTED:format(Label(tier)))
		ns.Fire("CHAT_SETTINGS_CHANGED")
	end
	lastSend = now
	local failed, sentParts = false, 0
	local line = {} -- (its parts in the lane, for Comm.DropLine)
	for _, part in ipairs(parts) do
		-- why (Comm.SendChat): "moved" the channel changed before it left : it goes to
		-- neither channel), "late", "failed" or "left". Told once per line, at its first part not
		-- sent, and CHAT_SEND_FAILED(tier, why, text, sentParts) with the whole line, so a window
		-- can offer it back (sentParts: its parts that had already left). The parts are sent in
		-- order, and those after the first not sent are dropped from the lane then (1.1.1: the
		-- others would read the line without its start, and sentParts would not be the count of
		-- what left).
		local function done(sent, why)
			if not sent then
				if failed then return end
				failed = true
				why = why or "failed"
				ns.Comm.DropLine(line, why)
				if why == "moved" then
					stats.moved = stats.moved + 1
					-- (A long line whose start had left: that part went out on the old channel.)
					if sentParts > 0 then
						ns.Print(L.CHAN_MOVED_PART:format(Label(tier), sentParts, #parts))
					else
						ns.Print(L.CHAN_MOVED:format(Label(tier)))
					end
				else
					ns.Print(L.CHAN_SEND_FAILED:format(Label(tier)))
				end
				ns.Fire("CHAT_SEND_FAILED", tier, why, text, sentParts)
				return
			end
			sentParts = sentParts + 1
			stats.sent = stats.sent + 1
			Accept(tier, ns.me, guild, class ~= "" and class or nil, part, true) -- our echo: exactly what the others see
		end
		local id = NextId()
		-- Kept a while: when this line comes back from the channel it is ours, whatever form
		-- the server gave our name in (a line shown twice to its author otherwise).
		mine[id .. "#" .. Codec.SanitizeChat(part)] = now
		local msg = Codec.EncodeChat(tier, guild, id, class, part)
		if not msg or ns.Comm.SendChat(msg, done, line) == false then
			done(false)
			break -- (the parts before it left the lane with it)
		end
	end
	return true, "ok"
end

-- The warning's answer, with the line it held (with the gamepad UI too: it rides in the
-- window's data). Send: that channel counts as warned and the line goes through Channels.Send
-- again, every check with it. Cancel, Escape or another window taking its place: not sent.
-- The channel changed while the warning waited (a new realm key, : the line was
-- written for the audience the warning named, so it is not sent, and the channel is not counted
-- as warned (the new one's audience was never shown); the player is told, as for a line dropped
-- from the lane. Out of a Sylvanistas guild by then, or on no channel (1.1.1): no channel change,
-- Channels.Send's own refusal says why, and nothing counts as warned.
function Channels.Confirm(data, send)
	if type(data) ~= "table" or not TIERS[data.tier] or data.answered then return end
	data.answered = true
	if not send then
		ns.Print(L.CHAN_WARN_NOT_SENT)
		return
	end
	local channel = ns.Comm.ChannelName()
	if not ns.IsMember() or channel == nil then return Channels.Send(data.tier, data.text, nil, data.keepMute) end
	if data.channel ~= channel then
		stats.moved = stats.moved + 1
		ns.Print(L.CHAN_MOVED:format(Label(data.tier)))
		ns.Fire("CHAT_SEND_FAILED", data.tier, "moved", data.text, 0)
		return false, "moved"
	end
	Warned()[data.tier] = true
	return Channels.Send(data.tier, data.text, nil, data.keepMute)
end

StaticPopupDialogs["SYLVANISTAS_CHAT_PRIVACY"] = {
	text = L.CHAN_WARN_ASK,
	button1 = SEND_LABEL or "Send",
	button2 = CANCEL or "Cancel",
	OnAccept = function(self, data) ns.SafeCall("chat warning", Channels.Confirm, data or (self and self.data), true) end,
	OnCancel = function(self, data) ns.SafeCall("chat warning", Channels.Confirm, data or (self and self.data), false) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function LogDrop(sender, m, reason, now)
	if lastLog[sender] and now - lastLog[sender] < LOG_GAP then return end
	lastLog[sender] = now
	ns.Log("chat [%s] from %s <%s> dropped: %s", m.tier, sender, m.guild, reason)
end

local function Ignored(sender)
	local api = C_FriendList and C_FriendList.IsIgnored
	if not api then return false end
	local ok, res = pcall(api, ns.DisplayName(sender))
	return ok and res == true
end

-- Flood guard per channel, so [Sylvanistas] traffic never silences [Captains] or [Lords]. Once a
-- channel is half full, a sender who already had FAIR_SHARE lines in it waits: one or two
-- spammers can't take the whole minute from everyone else.
local function Flooded(tier, sender, now)
	local list = recent[tier] or {}
	recent[tier] = list
	local mine = 0
	for i = #list, 1, -1 do
		if now - list[i].t > 60 then
			table.remove(list, i)
		elseif list[i].sender == sender then
			mine = mine + 1
		end
	end
	if #list >= MAX_SHOWN_PER_MINUTE or (#list >= MAX_SHOWN_PER_MINUTE / 2 and mine >= FAIR_SHARE) then return true end
	list[#list + 1] = { t = now, sender = sender }
	return false
end

-- What the flood guard kept off the chat is said, never silent: at most one line a minute,
-- "[Sylvanistas] 12, [Captains] 3", where most of those lines would have shown, telling where they
-- are and how many lines the history keeps. Called on each line held, by a timer once the
-- notice is due, and by the housekeeping. Returns true when it printed.
function Channels.FloodNotice(now)
	now = now or GetTime()
	if not heldSince then return false end
	local due = math.max(heldSince + NOTICE_WAIT, lastNotice + NOTICE_GAP)
	if now < due then
		if not noticeTimer then
			noticeTimer = true
			ns.After(due - now + 0.1, "flood notice", function()
				Channels.FloodNotice()
				noticeTimer = false
			end)
		end
		return false
	end
	local parts, most, where = {}, 0, nil
	for _, tier in ipairs(Channels.ORDER) do
		local n = held[tier]
		if n then
			parts[#parts + 1] = "[" .. Label(tier) .. "] " .. n
			if n > most then most, where = n, tier end
		end
	end
	wipe(held)
	heldSince, lastNotice = nil, now
	if not where then return false end
	Say(Channels.Frame(where), L.CHAN_FLOOD_NOTICE:format(table.concat(parts, ", "), HISTORY))
	return true
end

local function Held(tier, now)
	held[tier] = (held[tier] or 0) + 1
	heldSince = heldSince or now
	Channels.FloodNotice(now)
end

-- Returns shown, reason.
function Channels.Receive(dist, sender, text, now)
	if dist ~= "CHANNEL" then return false, "dist" end
	-- The chats off on this client (1.1): dropped before anything reads or keeps the line.
	if not Channels.ChatOn() then
		stats.off = (stats.off or 0) + 1
		if ns.db and ns.db.addonChat == nil and not offHinted and ns.IsMember() then
			offHinted = true
			ns.Print(L.CHAT_OFF_UNANSWERED)
		end
		return false, "off"
	end
	now = now or GetTime()
	sender = ns.FullName(sender)
	local m = Codec.DecodeChat(text)
	if not m or not ns.IsFederation(m.guild) then
		stats.bad = stats.bad + 1
		return false, "bad"
	end
	-- 1.1: a name the moderators took off (net-off, Moderation.lua): not shown, not kept.
	if ns.Moderation.Hides and ns.Moderation.Hides(sender, m.guild) then
		stats.netoff = (stats.netoff or 0) + 1
		return false, "netoff"
	end
	local level = TIERS[m.tier].level
	-- Above our rank: not shown, not kept, not logged.
	if Channels.MyLevel() < level then
		stats.hidden = stats.hidden + 1
		return false, "tier"
	end
	if Ignored(sender) then
		stats.ignored = stats.ignored + 1
		return false, "ignored"
	end
	-- The server stamps the sender, so this key can't be forged. The text is part of it: ids
	-- start again at random after a /reload, and a reused id must not hide a new line.
	local key = sender .. "#" .. m.id .. "#" .. m.text
	-- Our own line coming back (already shown when sent): the same id and text, from a name
	-- that is ours however it is written ("First-Surname", "First Surname", with a realm or not).
	local own = mine[m.id .. "#" .. m.text]
	if own and now - own < DEDUPE_WINDOW and Channels.IsMe(sender) then
		stats.dup = stats.dup + 1
		return false, "own"
	end
	if seen[key] and now - seen[key] < DEDUPE_WINDOW then
		stats.dup = stats.dup + 1
		return false, "dup"
	end
	seen[key] = now
	local b = buckets[sender]
	if not b then
		b = { tokens = BUCKET_SIZE, t = now }
		buckets[sender] = b
	end
	b.tokens = math.min(BUCKET_SIZE, b.tokens + (now - b.t) / BUCKET_REFILL)
	b.t = now
	if b.tokens + 1e-6 < 1 then -- (tolerance: a sender exactly on time must not lose to rounding)
		stats.rate = stats.rate + 1
		LogDrop(sender, m, "rate", now)
		return false, "rate"
	end
	b.tokens = b.tokens - 1
	local have, verified = Channels.VerifiedLevel(sender, m.guild)
	if have < level then
		local reason = have == 0 and "forged" or (verified and "rank" or "unverified")
		stats[reason] = stats[reason] + 1
		LogDrop(sender, m, reason, now)
		return false, reason
	end
	-- 1.1 (#31): a line the player's block terms hide (Filter.lua) stays off the chat frame. It is
	-- kept, for the Chat tab's grey bubble and its "N lines hidden" (a click shows them), and a
	-- companion reading the chats still gets it: the filter only decides what this player sees.
	-- Nothing else happens to its sender (no ignore, no block): their next line shows.
	local F = ns.Filter
	if F and not F.missing and F.Hides(m.text) then
		stats.filtered = (stats.filtered or 0) + 1
		Keep(m.tier, sender, m.guild, m.class, m.text, false)
		return false, "filtered"
	end
	-- A muted channel only goes to history, so it takes nothing from the flood guard. A line
	-- the guard keeps off the chat frame still goes to the history (the Chat tab's lines stay
	-- whole for everyone, and a companion hears it), and the player is told (Channels.FloodNotice).
	if not Muted()[m.tier] and Flooded(m.tier, sender, now) then
		stats.flood = stats.flood + 1
		Keep(m.tier, sender, m.guild, m.class, m.text, false)
		Held(m.tier, now)
		return false, "flood"
	end
	return Accept(m.tier, sender, m.guild, m.class, m.text, false)
end

-- Our name however the server writes it: lower case, our realm left out (a namesake on a
-- connected realm is another player), a hyphen between first name and surname read as the
-- space it stands for ("Firstnam Esurname" stays another).
local function Letters(name)
	name = tostring(name or "")
	local base, realm = name:match("^(.+)%-([^%-]+)$")
	if realm and (realm == ns.realm or realm == ns.CurrentRealm()) then name = base end
	name = name:lower():gsub("'", ""):gsub("[%s%-]+", " ")
	return (name:match("^%s*(.-)%s*$"))
end
function Channels.IsMe(sender)
	if not ns.me or not sender then return false end
	return sender == ns.me or Letters(ns.Normal(sender)) == Letters(ns.me)
end

-- Players' text must come through the logged API (the server keeps it, so abuse can be
-- reported): a line sent with the plain one is dropped, where the client has both.
ns.Comm.Handle("M1", function(dist, sender, text)
	if C_ChatInfo and C_ChatInfo.SendAddonMessageLogged and ns.Comm.DeliveredLogged and not ns.Comm.DeliveredLogged() then
		stats.unlogged = (stats.unlogged or 0) + 1
		return
	end
	Channels.Receive(dist, sender, text)
end)

---------------------------------------------------------------------------
-- The pinned line (1.1): one short line on top of the Sylvanistas chats and the Realm, lighter than a
-- writ (no parchment, nothing to acknowledge, no popup, no sound): a raid move or a gates change
-- that has to stay on screen. Not a second decree system: one line, the setter's own words,
-- typed by a person.
-- Who pins, and for whom (review of 1.1): the army's line comes from the King (his pinned
-- name), his Stewards (the signed titles list) and his Hands (the King's list or a Steward's)
-- alone, on the Sylvanistas channel: every client knows them alike, and no census report makes
-- anyone one of them. A guild master pins for his own guild only, over GUILD: his guildmates'
-- clients read his rank in their own roster (the server's word), never in the census, which
-- anyone on the channel writes to (two characters reporting a made-up guild that names one of
-- them its leader would otherwise pin for the whole army). The officers of <Sylvanistas>, Lords on
-- its own members' clients alone (ns.IsCrownRank), pin for the army only as his Hands.
-- One line on each client. A newer pin takes the place of one of its own rank or lower: the
-- King's newer pin always wins, a Steward's or a Hand's never replaces the King's, a guild
-- master's never replaces theirs. It ends PIN_TIME after it was set, or when its setter or a
-- higher rank takes it down (the King anyone's, his Stewards and Hands a guild master's). A
-- higher rank's takedown names the pin it takes down (its id), once a minute at most from each
-- sender, and every takedown says in chat who took the line down. A takedown sticks: each client
-- remembers the pins taken down (their setter and id, for PIN_TIME, ns.rdb.pinsDown), so a repeat
-- that comes late, or a setter's client that missed the takedown, never brings one back. That
-- memory is bounded (PIN_DOWN_KEEP) and nobody's takedowns push a higher rank's out of it: a
-- takedown naming a pin this client does not hold is remembered once a minute at most from each
-- sender, a sender's takedowns of his own pins PIN_DOWN_EACH at most, and past PIN_DOWN_KEEP the
-- lowest rank's go first (the rank of the takedown that put them there). The client that took
-- it down says so again when it hears it repeated (as rarely as its takedowns, never while the
-- moderators have it off), and the setter's client lets it go. The setter's client repeats its
-- pin every PIN_RESEND for late logins (a pin replaced there is no longer its to repeat), with
-- how long it has left and how long ago it was set: a repeat never makes a pin newer. It keeps
-- its pin through a /reload (ns.rdb.pinMine), to repeat it and take it down; where a /reload
-- kept nothing (the Forever beta never loads the saved variables back), /syl pin off still
-- sends its setter's takedown (id 0), and each client drops whichever of his it shows. Its
-- words go out with the logged API (the server keeps them, so abuse can be reported), plain
-- text, PIN_MAX bytes at most; a sender's new pin is taken once a minute at most.
-- What a client shows (Channels.Pin): no pin while its Sylvanistas chats are off (the player's
-- choice, Consent.lua: none sent either), none from a name or guild the moderators took off
-- (net-off, Moderation.lua: their own client sends none and takes no one else's down, their
-- takedown of their own pin aside), and the player's block terms hide its words (Filter.lua)
-- until a click shows them.
--   N1~<id>~<guild>~<seconds left>~<seconds since set>~<text>     a pin
--   N1~<id>~<guild>~0~0~        taken down (<id>: the pin's; <guild>: the sender's own)
--                               (<id> 0: its setter's, from a client that holds none of his)
-- On the Sylvanistas channel from the King, his Stewards and Hands (<guild>: the King's); over GUILD
-- from a guild master (<guild>: his own). Clients before 1.1 know no N1 and drop it unread.
-- A higher rank's takedown of a guild master's pin, and its repeat, go where that pin went: over
-- GUILD (<guild>: still the King's), which reaches his guildmates on every realm and on either
-- channel (review); their clients take it by the channel's rule (PinRank).
---------------------------------------------------------------------------

Channels.PIN_MAX = 100         -- bytes of a pinned line
Channels.PIN_TIME = 2 * 3600   -- a pin ends this long after it was set
Channels.PIN_RESEND = 300      -- the setter's client repeats it this often
Channels.PIN_GAP = 60          -- a sender's new pin at most this often (taken a little sooner: queues)
Channels.PIN_DOWN_KEEP = 200   -- pins taken down a client remembers at most (the lowest rank's go first, then the oldest)
Channels.PIN_DOWN_EACH = 10    -- of them, a sender's takedowns of his own pins at most (his oldest go first)
Channels.PIN_KING, Channels.PIN_CROWN, Channels.PIN_LORD = 3, 2, 1

local pin            -- the pinned line: { id, sender, guild, text, rank, dist, setAt, expires, mine, sentAt }
local lastPinSet = -math.huge
local lastPinDown = -math.huge -- when we last took down someone else's pin
local pinFrom = {}   -- [sender] = when a new pin of theirs was last taken
local downFrom = {}  -- [sender] = when their takedown of someone else's pin was last taken
local blindFrom = {} -- [sender] = when their takedown of a pin we did not hold was last remembered

-- Plain text: no escape code, separator or control byte; spaces tidied; PIN_MAX bytes at most.
function Channels.CleanPin(text)
	text = tostring(text or ""):gsub("[|~%c]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return (ns.Cut(text, Channels.PIN_MAX):gsub("%s+$", ""))
end

-- The rank `sender` pins with for `guild`, heard over `dist` (the channel when not given): on the
-- channel PIN_KING (the King by his pinned name) or PIN_CROWN (a Steward or a Hand), for the
-- King's guild; over GUILD PIN_LORD, our own guild's master as our roster has him; nil for anyone
-- else. Never the rank a message claims, and never the census's word (Data.KnownRank): anyone on
-- the channel reports to it. An officer of <Sylvanistas> is no Lord here even on its own members'
-- clients: he pins for the army as a Hand.
function Channels.PinRank(sender, guild, dist)
	if type(sender) ~= "string" or type(guild) ~= "string" or not ns.IsFederation(guild) then return nil end
	if dist == "GUILD" then
		if guild ~= GetGuildInfo("player") then return nil end
		return ns.Roster.RankOf(sender) == 0 and Channels.PIN_LORD or nil
	end
	if (dist or "CHANNEL") ~= "CHANNEL" or not ns.IsKingGuild(guild) then return nil end
	if ns.IsKingCharacter(sender) then return Channels.PIN_KING end
	local K = ns.King
	if K and ((K.IsStewardName and K.IsStewardName(sender)) or (K.IsHandName and K.IsHandName(sender))) then return Channels.PIN_CROWN end
	return nil
end

-- Our own rank, as the others' clients will see it (Channels.PinRank), the guild our pin names and
-- where it goes: the King, a Steward or a Hand for the army (the King's guild, on the channel); a
-- guild master, by our own rank (the server's), for his own guild alone (GUILD). Never the
-- officers of <Sylvanistas> (Lords on its own members' clients alone).
local function MyPin()
	local K = ns.King
	if K and K.IsKing and K.IsKing() and ns.IsKingCharacter(ns.me) then return Channels.PIN_KING, GetGuildInfo("player"), "CHANNEL" end
	if K and ((K.IsSteward and K.IsSteward()) or (K.IsHand and K.IsHand())) then return Channels.PIN_CROWN, ns.KingGuildName(), "CHANNEL" end
	if ns.IsMember() and ns.Roster.MyRank() == 0 and Channels.MyLevel() >= TIERS.L.level then return Channels.PIN_LORD, GetGuildInfo("player"), "GUILD" end
	return nil
end
function Channels.CanPin() return MyPin() ~= nil end
-- "army" (the King, his Stewards and Hands: the channel) or "guild" (a guild master: his guild
-- alone); nil for anyone else.
function Channels.PinScope()
	local rank, _, dist = MyPin()
	if not rank then return nil end
	return dist == "GUILD" and "guild" or "army"
end

local function PinChanged()
	ns.Fire("PIN_CHANGED")
	if ns.UI and ns.UI.RefreshSoon then ns.UI.RefreshSoon() end
end

-- The line this client holds. Our own is saved with it (per character: the characters of one
-- account on a realm group share ns.rdb), so a /reload keeps it ours to repeat and take down.
local function Hold(p)
	pin = p
	local rdb = ns.rdb
	if not rdb or not ns.me then return end
	local saved = type(rdb.pinMine) == "table" and rdb.pinMine or {}
	saved[ns.me] = (p and p.mine) and p or nil
	rdb.pinMine = next(saved) ~= nil and saved or nil
end

-- The pins taken down here: [setter (lower case) .. "#" .. id] = { t = until when, r = the rank
-- of the takedown that put it here (ours, when this client took it down), us = true when this
-- client took it down }. Such a pin is not taken again before then.
local function DownKey(sender, id) return tostring(sender):lower() .. "#" .. tostring(id) end
local function DownRank(e)
	local r = type(e) == "table" and e.r
	return (type(r) == "number" and r >= Channels.PIN_LORD and r <= Channels.PIN_KING) and r or 0
end
-- The oldest first (the key breaks a tie).
local function Oldest(a, b)
	if a.t ~= b.t then return a.t < b.t end
	return a.k < b.k
end
-- The lapsed go (and anything else a saved file holds), then past PIN_DOWN_KEEP the lowest
-- rank's, the oldest first (the review of the fixes: a sender's takedowns never push out a
-- higher rank's).
local function PruneDown(list, now)
	local kept = {}
	for k, e in pairs(list) do
		if type(k) ~= "string" or type(e) ~= "table" or type(e.t) ~= "number" or e.t <= now or e.t > now + Channels.PIN_TIME then
			list[k] = nil
		else
			kept[#kept + 1] = { k = k, t = e.t, r = DownRank(e) }
		end
	end
	if #kept <= Channels.PIN_DOWN_KEEP then return end
	table.sort(kept, function(a, b)
		if a.r ~= b.r then return a.r < b.r end
		return Oldest(a, b)
	end)
	for i = 1, #kept - Channels.PIN_DOWN_KEEP do list[kept[i].k] = nil end
end
-- `setter`'s pin `id`, taken down by a takedown of rank `rank` (us: ours). A sender's takedowns of
-- his own pins (own) are PIN_DOWN_EACH at most here, his oldest going first: his never push out
-- anyone else's, nor a higher rank's takedown of one of his.
local function Remember(setter, id, now, rank, us, own)
	local rdb = ns.rdb
	if not rdb then return end
	local list = type(rdb.pinsDown) == "table" and rdb.pinsDown or {}
	rdb.pinsDown = list
	local key = DownKey(setter, id)
	local was = type(list[key]) == "table" and list[key] or nil
	list[key] = { t = now + Channels.PIN_TIME, r = math.max(rank or 0, DownRank(was)), us = (us or (was and was.us)) and true or nil }
	if own then
		local prefix, his = DownKey(setter, ""), {}
		for k, e in pairs(list) do
			if type(k) == "string" and k:sub(1, #prefix) == prefix and type(e) == "table" and type(e.t) == "number"
				and not e.us and DownRank(e) <= (rank or 0) then
				his[#his + 1] = { k = k, t = e.t }
			end
		end
		if #his > Channels.PIN_DOWN_EACH then
			table.sort(his, Oldest)
			for i = 1, #his - Channels.PIN_DOWN_EACH do list[his[i].k] = nil end
		end
	end
	PruneDown(list, now)
end
local function WasDown(sender, id, now)
	local list = ns.rdb and ns.rdb.pinsDown
	local e = type(list) == "table" and list[DownKey(sender, id)]
	if type(e) ~= "table" or type(e.t) ~= "number" or e.t <= now then return nil end
	return e
end

-- The line this client holds while it lasts, shown here or not, else nil.
local function Current(now)
	now = now or ns.Now()
	if pin and now >= pin.expires then
		Hold(nil)
		PinChanged()
	end
	return pin
end

-- The pinned line as this client shows it, else nil (review): none while the Sylvanistas chats
-- are off here (the player's choice, Consent.lua), none from a name or guild the moderators took
-- off (net-off, Moderation.lua). It is kept meanwhile: the chats back on, or its setter back, it
-- shows again while it lasts.
function Channels.Pin(now)
	local p = Current(now)
	if not p or not Channels.ChatOn() then return nil end
	local M = ns.Moderation
	if M and M.Hides and M.Hides(p.sender, p.guild) then return nil end
	return p
end

-- A pin's words as this client shows them, and whether they are veiled: the player's block terms
-- (Filter.lua) hide someone else's, as any other addon text, until a click on the line shows them.
function Channels.PinWords(p)
	if not p then return "", false end
	local F = ns.Filter
	if not p.mine and not p.revealed and F and not F.missing and F.Hides(p.text) then return L.FILTER_WORDS_HIDDEN_SHORT, true end
	return p.text, false
end

-- Where a pin goes: the channel, or its guild (a guild master's). One of each waiting at most: a
-- newer one takes its place in the queue (key). Logged: its words.
local function SendPin(p, now, down, key)
	local msg
	if down then
		msg = ("N1~%d~%s~0~0~"):format(p.id, p.guild)
	else
		msg = ("N1~%d~%s~%d~%d~%s"):format(p.id, p.guild, math.max(1, math.floor(p.expires - now)),
			math.max(0, math.floor(now - p.setAt)), p.text)
	end
	p.sentAt = now
	local dist = p.dist == "GUILD" and "GUILD" or "CHANNEL"
	ns.Comm.Send(dist, msg, key or ("pin:" .. dist), nil, true)
end

-- /syl pin <text>, or the chat page's "Pin a line": up for PIN_TIME, for the army (the King, his
-- Stewards and Hands) or for his guild (a guild master).
function Channels.SetPin(text, now)
	now = now or ns.Now()
	local rank, guild, dist = MyPin()
	if not rank then
		ns.Print(L.PIN_ONLY)
		return false, "rank"
	end
	-- The chats off on this client (the player's choice): no pin leaves, as no line does. Never
	-- answered: the page asks.
	if not Channels.ChatOn() then
		if ns.db.addonChat == nil then
			ns.Print(L.CHAT_OFF_UNANSWERED)
			if ns.Consent and ns.Consent.Ask then ns.Consent.Ask("chat") end
		else
			ns.Print(L.CHAT_OFF)
		end
		return false, "off"
	end
	-- The moderators took this character (or its guild) off: nobody would show it.
	local off = ns.Moderation.SelfOff and ns.Moderation.SelfOff()
	if off then
		ns.Print(ns.Moderation.YouText(off))
		return false, "netoff"
	end
	text = Channels.CleanPin(text)
	if #text < 3 then
		ns.Print(L.PIN_USAGE)
		return false, "empty"
	end
	if Locked() then
		ns.Print(L.CHAN_LOCKDOWN)
		return false, "lockdown"
	end
	if dist == "CHANNEL" and not ns.Comm.ChannelReady() then
		ns.Print(L.CHAN_NOT_READY)
		return false, "ready"
	end
	if now - lastPinSet < Channels.PIN_GAP then
		ns.Print(L.PIN_WAIT:format(math.ceil(Channels.PIN_GAP - (now - lastPinSet))))
		return false, "fast"
	end
	local current = Channels.Pin(now)
	if current and not current.mine and current.rank > rank then
		ns.Print(L.PIN_OUTRANKED:format(ns.DisplayName(current.sender) or "?"))
		return false, "outranked"
	end
	lastPinSet = now
	Hold({ id = math.random(1, 99999), sender = ns.me, guild = guild, text = text, rank = rank, dist = dist, setAt = now,
		expires = now + Channels.PIN_TIME, mine = true })
	SendPin(pin, now)
	ns.Print((dist == "GUILD" and L.PIN_DONE_GUILD or L.PIN_DONE):format(text))
	PinChanged()
	return true, "ok"
end

-- Ours: set here, or one of ours this client heard (our name, as the server stamped it).
local function Ours(p) return p.mine or Channels.IsMe(p.sender) end

-- The moderators took us (or our guild) off (net-off): the word, or nil. Then we take no one
-- else's line down (the review of the fixes): every other client drops such a takedown
-- (HandlePin), so none leaves, and the line stays here too. Our own still comes down.
local function SelfOff()
	local M = ns.Moderation
	return M and M.SelfOff and M.SelfOff() or nil
end

-- Can we take the pinned line down: ours (shown here or not: our chats off, or the moderators
-- hiding us), or one shown here of a lower rank than ours, while the moderators have us on.
function Channels.CanTakeDown(now)
	local p = Current(now)
	if not p then return false end
	if Ours(p) then return true end
	if Channels.Pin(now) ~= p or SelfOff() then return false end
	local rank = MyPin()
	return rank ~= nil and rank > p.rank
end

-- /syl pin off, or the pinned line's click: taken down for everyone it reached (ours: where it
-- went). Someone else's: named by its id, once a minute at most (as the others' clients take
-- it, HandlePin), where our own pin would go, or where it went (a guild master's: GUILD).
function Channels.TakeDownPin(now)
	now = now or ns.Now()
	local p = Current(now)
	if p and not Ours(p) and Channels.Pin(now) ~= p then p = nil end
	if not p then
		-- Nothing held here, though we may pin (review): the Forever beta never loads the
		-- saved variables back, so after a /reload our own pin is gone here while the others still
		-- show it. Our takedown goes all the same, where our pin would go, once a minute at most:
		-- theirs drop whichever of ours they show (id 0 names no pin; any other's stays).
		local rank, guild, dist = MyPin()
		if not rank then
			ns.Print(L.PIN_NONE)
			return false, "none"
		end
		if now - lastPinDown < Channels.PIN_GAP then
			ns.Print(L.PIN_DOWN_WAIT:format(math.ceil(Channels.PIN_GAP - (now - lastPinDown))))
			return false, "fast"
		end
		lastPinDown = now
		SendPin({ id = 0, guild = guild, dist = dist }, now, true)
		ns.Print(L.PIN_DOWN_ANY)
		return true, "any"
	end
	local own = Ours(p)
	local off = not own and SelfOff()
	if off then
		ns.Print(ns.Moderation.YouText(off))
		return false, "netoff"
	end
	if not Channels.CanTakeDown(now) then
		ns.Print(L.PIN_NOT_YOURS)
		return false, "rank"
	end
	local mine, guild, dist = MyPin()
	if not own then
		if now - lastPinDown < Channels.PIN_GAP then
			ns.Print(L.PIN_DOWN_WAIT:format(math.ceil(Channels.PIN_GAP - (now - lastPinDown))))
			return false, "fast"
		end
		lastPinDown = now
		-- Remembered as ours to take down: its setter's repeat, heard again, is answered (HandlePin).
		Remember(p.sender, p.id, now, mine, true)
	end
	if own then
		SendPin({ id = p.id, guild = p.guild, dist = p.dist }, now, true)
	else
		-- A guild master's pin (it came over GUILD): taken down over GUILD too (review),
		-- which reaches every client that holds it (his guildmates, on every realm and either
		-- channel); we are in that guild, since we heard it. The channel would miss those on
		-- another realm or the other channel, and reach thousands that hold nothing.
		SendPin({ id = p.id, guild = guild, dist = p.dist == "GUILD" and "GUILD" or dist }, now, true, "pindown")
	end
	Hold(nil)
	ns.Print(L.PIN_TAKEN_DOWN)
	PinChanged()
	return true, "ok"
end

-- Every minute: our own pin again for late logins, every PIN_RESEND while it lasts, while we may
-- still pin as we did (a /reload keeps it: RestorePin). Not while our chats are off, nor while
-- the moderators have us off (net-off): its takedown still goes.
function Channels.RepeatPin(now)
	now = now or ns.Now()
	local p = Current(now)
	if not (p and p.mine) or now - (p.sentAt or -math.huge) < Channels.PIN_RESEND then return false end
	local rank, _, dist = MyPin()
	if rank ~= p.rank or dist ~= p.dist or not Channels.ChatOn() then return false end
	if ns.Moderation.SelfOff and ns.Moderation.SelfOff() then return false end
	SendPin(p, now)
	return true
end

-- A pin this client took down, heard again: its setter's client missed the takedown. Said again,
-- named by its id, as rarely as our own takedowns, while we still outrank it, over the dist the
-- repeat came in on (a guild master's: GUILD, review). Never while the moderators have
-- us off: nobody would take it (SelfOff).
local function ResendDown(sender, id, rank, now, heard)
	local mine, guild = MyPin()
	if not mine or mine <= rank or now - lastPinDown < Channels.PIN_GAP or SelfOff() then return false end
	lastPinDown = now
	SendPin({ id = id, guild = guild, dist = heard }, now, true, "pindown")
	ns.Log("pin %d of %s taken down again: its setter's client still repeats it", id, sender)
	return true
end

-- Returns taken, reason. The army's from the channel, a guild master's from our guild (GUILD).
function Channels.HandlePin(dist, sender, text, now)
	if dist ~= "CHANNEL" and dist ~= "GUILD" then return false, "dist" end
	now = now or ns.Now()
	sender = ns.FullName(sender)
	local id, guild, left, age, body = tostring(text):match("^N1~(%d+)~([^~]*)~(%d+)~(%d+)~(.*)$")
	id, left, age = tonumber(id), tonumber(left), tonumber(age)
	-- (A guild's name: 24 letters at most, not bytes, as every other message reads it: Codec.LongGuild.)
	if not id or not guild or guild == "" or Codec.LongGuild(guild) or guild:find("%c") then return false, "bad" end
	if Ignored(sender) then return false, "ignored" end
	-- Its words come through the logged API, as a chat line's (dropped otherwise, where this
	-- client has both).
	if C_ChatInfo and C_ChatInfo.SendAddonMessageLogged and ns.Comm.DeliveredLogged and not ns.Comm.DeliveredLogged() then
		return false, "unlogged"
	end
	body = Channels.CleanPin(body)
	local takedown = body == "" or left == 0
	local rank = Channels.PinRank(sender, guild, dist)
	-- A takedown over GUILD from the King, a Steward or a Hand (review): of our guild
	-- master's pin, sent where it went. Their rank by the channel's rule: it only removes a pin,
	-- and the server vouches for the guildmate who sent it.
	if takedown and dist == "GUILD" then
		local crown = Channels.PinRank(sender, guild, "CHANNEL")
		if crown and (not rank or crown > rank) then rank = crown end
	end
	if not rank then
		ns.Log("pin from %s <%s> (%s) ignored: not the King, his Stewards or Hands, nor our own guild master", sender, guild, dist)
		return false, "rank"
	end
	local current = Current(now)
	-- A name or guild the moderators took off (net-off, review): no pin of theirs.
	local M = ns.Moderation
	local hidden = M and M.Hides and M.Hides(sender, guild)
	if takedown then
		-- Its setter's takes his line down (whichever of his we show); a higher rank's, the pin it
		-- names, once a minute at most from each. A guild master takes down no one else's. Taken
		-- whether or not our chats are on: a takedown only ever removes.
		local own = current ~= nil and current.sender == sender
		if not own and not (current and current.id == id and rank > current.rank) then
			-- Nothing we hold: its sender's own pin of that id is remembered all the same (we may
			-- have missed it, or it may come late), so it never shows here. Once a minute at most
			-- from each (the review of the fixes: a flood of made-up ids would push out what
			-- the King took down), and never id 0 (it names no pin).
			if id ~= 0 and now - (blindFrom[sender] or -math.huge) >= Channels.PIN_GAP * 0.75 then
				blindFrom[sender] = now
				Remember(sender, id, now, rank, nil, true)
			end
			return false, "nothing"
		end
		if not own then
			if hidden then return false, "netoff" end -- (taken off, he takes no one else's down)
			if now - (downFrom[sender] or -math.huge) < Channels.PIN_GAP * 0.75 then return false, "fast" end
			downFrom[sender] = now
		elseif current.id ~= id and id ~= 0 then
			Remember(sender, id, now, rank, nil, true)
		end
		-- Taken down for good here: its setter's repeat, late or from a client that missed this, is
		-- not taken again (a new pin of his is).
		Remember(current.sender, current.id, now, rank, nil, own)
		local shown = Channels.Pin(now) == current
		Hold(nil)
		-- Said in chat where it showed.
		if shown then
			local who = ns.DisplayName(sender) or "?"
			Say(DEFAULT_CHAT_FRAME, "|cffffd200" .. (own and L.PIN_DOWN_OWN:format(who, Codec.Plain(guild))
				or L.PIN_DOWN_BY:format(who, Codec.Plain(guild), ns.DisplayName(current.sender) or "?")) .. "|r")
		end
		ns.Log("pin of %s <%s> taken down by %s <%s> (rank %d)", current.sender, current.guild, sender, guild, rank)
		PinChanged()
		return true, "down"
	end
	if hidden then
		ns.Log("pin from %s <%s> ignored: net-off", sender, guild)
		return false, "netoff"
	end
	-- The chats off on this client (the player's choice, Consent.lua): no pin taken, none shown.
	if not Channels.ChatOn() then return false, "off" end
	left, age = math.min(left, Channels.PIN_TIME), math.min(age, Channels.PIN_TIME)
	-- Taken down here before: never again. Ours to take down: said again (ResendDown), so its
	-- setter's client lets it go.
	local down = WasDown(sender, id, now)
	if down then
		if down.us then ResendDown(sender, id, rank, now, dist) end
		return false, "downed"
	end
	-- The pin we hold, said again: only its end, never later than it was.
	if current and current.sender == sender and current.id == id then
		current.expires = math.min(current.expires, now + left)
		return true, "repeat"
	end
	local setAt = now - age
	-- A higher rank's stays (one this client shows: not its setter's while the moderators hide
	-- him); of the same rank, the one set last.
	local shown = Channels.Pin(now)
	if shown and (shown.rank > rank or (shown.rank == rank and shown.setAt > setAt)) then return false, "older" end
	if now - (pinFrom[sender] or -math.huge) < Channels.PIN_GAP * 0.75 then return false, "fast" end
	pinFrom[sender] = now
	Hold({ id = id, sender = sender, guild = guild, text = body, rank = rank, dist = dist, setAt = setAt, expires = now + left })
	-- Its words veiled where the player's block terms hide them (Filter.lua).
	local words = Channels.PinWords(pin)
	Say(DEFAULT_CHAT_FRAME, "|cffffd200" .. L.PIN_NEW:format(ns.DisplayName(sender) or "?", Codec.Plain(guild), words) .. "|r")
	ns.Log("pin from %s <%s> (rank %d)", sender, guild, rank)
	PinChanged()
	return true, "ok"
end
ns.Comm.Handle("N1", function(dist, sender, text) Channels.HandlePin(dist, sender, text) end)

-- For /syl status.
function Channels.PinStatus(now)
	local p = Current(now)
	if not p then return "none" end
	local ranks = { [3] = "the Dark Lady", [2] = "Ambassador or Dark Ranger", [1] = "Dark Lord" }
	return ("by %s <%s> (%s)%s%s, ends in %dm"):format(ns.DisplayName(p.sender) or "?", Codec.Plain(p.guild), ranks[p.rank] or "?",
		p.mine and ", ours" or "", Channels.Pin(now) ~= p and ", not shown here (chats off or net-off)" or "",
		math.ceil((p.expires - (now or ns.Now())) / 60))
end

-- After a /reload, or a login within its time: our own pin as we left it, ours to repeat and take
-- down. What was saved is checked again (the SavedVariables can be edited); the pins taken down
-- here stay remembered, the lapsed ones go.
function Channels.RestorePin(now)
	now = now or ns.Now()
	local rdb = ns.rdb
	if not rdb then return false end
	if type(rdb.pinsDown) == "table" then PruneDown(rdb.pinsDown, now) else rdb.pinsDown = nil end
	local saved = rdb.pinMine
	if type(saved) ~= "table" then rdb.pinMine = nil return false end
	local s = ns.me and saved[ns.me]
	if pin or type(s) ~= "table" then return false end
	saved[ns.me] = nil
	if next(saved) == nil then rdb.pinMine = nil end
	local id, rank, setAt, expires = tonumber(s.id), tonumber(s.rank), tonumber(s.setAt), tonumber(s.expires)
	local text = Channels.CleanPin(s.text)
	if not (id and rank and setAt and expires) or (s.dist ~= "CHANNEL" and s.dist ~= "GUILD") or type(s.guild) ~= "string"
		or s.guild == "" or Codec.LongGuild(s.guild) or #text < 3 or expires <= now or expires - setAt > Channels.PIN_TIME
		or not (rank == Channels.PIN_KING or rank == Channels.PIN_CROWN or rank == Channels.PIN_LORD) then
		return false
	end
	Hold({ id = math.floor(id), sender = ns.me, guild = s.guild, text = text, rank = rank, dist = s.dist, setAt = setAt,
		expires = expires, mine = true, sentAt = tonumber(s.sentAt) })
	PinChanged()
	return true
end

-- Tests. keepSaved: what a /reload leaves (our own pin and the pins taken down, ns.rdb).
function Channels.ResetPin(keepSaved)
	pin, lastPinSet, lastPinDown = nil, -math.huge, -math.huge
	wipe(pinFrom); wipe(downFrom); wipe(blindFrom)
	if not keepSaved and ns.rdb then ns.rdb.pinMine, ns.rdb.pinsDown = nil, nil end
end

StaticPopupDialogs["SYLVANISTAS_PIN"] = {
	text = L.PIN_ASK,
	button1 = L.PIN_BUTTON,
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 260,
	maxLetters = Channels.PIN_MAX,
	OnShow = function(self)
		local eb = self.editBox or self.EditBox
		if eb then
			eb:SetText("")
			eb:SetFocus()
		end
	end,
	OnAccept = function(self)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("pin", Channels.SetPin, eb and eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		ns.SafeCall("pin", Channels.SetPin, self:GetText())
		self:GetParent():Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs["SYLVANISTAS_PIN_DOWN"] = {
	text = L.PIN_DOWN_ASK,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function() ns.SafeCall("pin down", Channels.TakeDownPin) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- /syl pin <text> | off | (nothing: what is pinned, and how).
function Channels.PinCommand(rest)
	rest = tostring(rest or ""):match("^%s*(.-)%s*$")
	local word = rest:lower()
	if word == "off" or word == "down" then return Channels.TakeDownPin() end
	if rest == "" then
		local p = Channels.Pin()
		if p then
			ns.Print(L.PIN_NOW:format(ns.DisplayName(p.sender) or "?", Codec.Plain(p.guild), math.ceil((p.expires - ns.Now()) / 60), (Channels.PinWords(p))))
		else
			ns.Print(L.PIN_NONE)
		end
		ns.Print(L.PIN_USAGE)
		return false
	end
	return Channels.SetPin(rest)
end

---------------------------------------------------------------------------
-- Mute, housekeeping, commands
---------------------------------------------------------------------------

local WORDS = {
	all = "A", a = "A", sylvanistas = "A", todos = "A",
	dreadguard = "C", dreadguards = "C", d = "C", captains = "C", captain = "C", c = "C", capitaes = "C", ["capitães"] = "C",
	darklords = "L", darklord = "L", dl = "L", veterans = "L", veteran = "L", v = "L", lords = "L", lord = "L", l = "L", lordes = "L",
}
function Channels.TierForWord(w)
	return WORDS[(tostring(w or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""))]
end

-- A muted channel stays out of chat but keeps its history. Account-wide. Every change to a
-- channel's place in the game's chat (muted or not here and in Send, its window in ChooseWindow and
-- SetupTab) fires CHAT_SETTINGS_CHANGED: the Chat tab's settings show it at once (ChatWindow.lua).
function Channels.ToggleMute(word)
	local tier = Channels.TierForWord(word)
	if not tier then
		ns.Print(L.CHAN_MUTE_USAGE)
		return
	end
	local muted = Muted()
	if muted[tier] then
		muted[tier] = nil
		ns.Print(L.CHAN_UNMUTED:format(Label(tier)))
	else
		muted[tier] = true
		ns.Print(L.CHAN_MUTED:format(Label(tier), TIERS[tier].word))
	end
	ns.Fire("CHAT_SETTINGS_CHANGED")
end

function Channels.Prune(now)
	now = now or GetTime()
	local n = 0
	for k, t in pairs(seen) do
		if now - t > DEDUPE_WINDOW then seen[k] = nil else n = n + 1 end
	end
	if n > 1000 then wipe(seen) end
	for k, t in pairs(mine) do
		if now - t > DEDUPE_WINDOW then mine[k] = nil end
	end
	for k, b in pairs(buckets) do
		if now - b.t > 60 then buckets[k] = nil end
	end
	for k, t in pairs(lastLog) do
		if now - t > LOG_GAP then lastLog[k] = nil end
	end
	Channels.FloodNotice(now) -- (in case its timer never came)
end

function Channels.Stats()
	local out = {}
	for k, v in pairs(stats) do out[k] = v end
	local muted, warned = {}, {}
	for _, tier in ipairs(Channels.ORDER) do
		if Muted()[tier] then muted[#muted + 1] = tier end
		if Warned()[tier] then warned[#warned + 1] = tier end
	end
	out.muted, out.warned = muted, warned
	return out
end

ns.On("INIT", function()
	-- (0.9.1: the warning comes before the first line in each channel, Channels.Confirm.)
	ns.db.chatNoticeShown = nil
	-- 1.1.1: the characters told what their Sylvanistas tab holds, [name] = true alone (the game's
	-- tab), or "chatty" (Chattynator's, 1.1.2).
	local intro = ns.db.chatTabIntro
	if type(intro) == "table" then
		for k, v in pairs(intro) do
			if type(k) ~= "string" or (v ~= true and v ~= "chatty") then intro[k] = nil end
		end
		if next(intro) == nil then ns.db.chatTabIntro = nil end
	else
		ns.db.chatTabIntro = nil
	end
	local chat = ns.rdb.chat
	if chat == nil then return end
	if type(chat) ~= "table" then
		ns.rdb.chat = nil
		return
	end
	for tier, list in pairs(chat) do
		if not TIERS[tier] or type(list) ~= "table" then
			chat[tier] = nil
		else
			while #list > HISTORY do table.remove(list, 1) end
		end
	end
end)

ns.On("LOGIN", function()
	ns.Every(60, "chat housekeeping", Channels.Prune)
	-- Our pinned line again for late logins (1.1), every PIN_RESEND while it lasts; after a
	-- /reload too (review: its setter can still take it down).
	Channels.RestorePin()
	ns.Every(60, "pin repeat", function() Channels.RepeatPin() end)
end)

-- /sy, /syc, /syld <text>: a line in that channel. Alone (nothing but spaces, 1.1.1): the Sylvanistas
-- window on its Chat tab, on that channel (ChatWindow.lua, or Core.lua's stand-in on a client
-- updated without a restart), else, where this client has no such tab, what to type (Channels.Send
-- says it).
local function Slash(tier, where)
	return function(msg)
		local W = ns.ChatWindow
		if tostring(msg or ""):match("^%s*$") and W and type(W.Toggle) == "function" then
			ns.SafeCall(where, W.Toggle, tier)
			return
		end
		ns.SafeCall(where, Channels.Send, tier, msg)
	end
end
-- /syd and /sydl (Dreadguard, Dark Lords); /syc, /syv and /syld still work.
SLASH_SYLVANISTASALL1, SLASH_SYLVANISTASCAPTAINS1, SLASH_SYLVANISTASLORDS1 = "/sy", "/syd", "/sydl"
SLASH_SYLVANISTASCAPTAINS2, SLASH_SYLVANISTASLORDS2, SLASH_SYLVANISTASLORDS3 = "/syc", "/syv", "/syld"
SlashCmdList.SYLVANISTASALL = Slash("A", "slash /sy")
SlashCmdList.SYLVANISTASCAPTAINS = Slash("C", "slash /syd")
SlashCmdList.SYLVANISTASLORDS = Slash("L", "slash /sydl")
