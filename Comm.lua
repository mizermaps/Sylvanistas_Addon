local ADDON, ns = ...

-- GUILD: "hello" pings so members with the addon know each other and elect one reporter.
-- CHANNEL (hidden "SylvanistasNet"): the elected reporter of each guild broadcasts its summary.
-- Chat lines of the channels (Channels.lua) ride the same hidden channel in a lane of their own.
-- One reporter per guild on each realm (1.0.0): on WoW: Forever each realm has an SylvanistasNet of
-- its own, while GUILD reaches a guild's members on every realm, so the election counts the
-- peers of our realm (see Electable).

local Comm = {}
ns.Comm = Comm
local Codec = ns.Codec

local HELLO_EVERY = 60
local PEER_WINDOW = 180  -- the election only trusts peers heard in the last 3 minutes
local COUNT_WINDOW = 720 -- quiet members say hello every 10 min: count them for 12
local BROADCAST_EVERY = 170
local SEND_INTERVAL = 1.2
local MAX_QUEUE = 60
local CHAT_QUEUE = 6  -- chat parts waiting in their own lane (two long lines)
local CHAT_TTL = 30   -- a chat part that waited this long is dropped, not sent late
local GUARD_AFTER = 400  -- an elected reporter never heard reporting our guild for this long...
local GUARD_FOR = 30 * 60 -- ...is left out of the election for this long (see MaybeBroadcast)
local KEY_ASK_EVERY = 600 -- at most one key request this often while a sealed reporter is elected
local WITNESS_EVERY = 600 -- the runner-up of the election reports this often (see MaybeBroadcast)
local JOIN_BY = 15        -- seconds after login we join the channel at the latest (see JoinSoon)
local ASK_AFTER = 4       -- seconds after joining we ask the channel for the census (Q1)...
local ASK_SPREAD = 41     -- ...at a second drawn up to this much later (1.0.0: 4 to 45 s)...
local ASK_HELD = 30       -- ...unless someone else asked this recently (its answers reach us too)...
local ASK_AGAIN = 65      -- ...and once more this later, for the reporters that had just answered
local SHARED_FOR = 3600   -- our guild's report from a guildmate of another realm this recently: the channel is shared
local QUIET_TOTAL = 10    -- members of a guild who keep saying hello (Comm.Hello), whatever its realms...
local QUIET_MIN = 3       -- ...and at least this many on each realm
local ANSWER_GAP = BROADCAST_EVERY -- a reporter answers census requests at most this often
local WITNESS_ANSWER_GAP = 300     -- the runner-up at most this often
local ANSWER_MIN_AGE = 45 -- ...and only when its last report is at least this old
local MAX_KEYS = 20      -- distinct keys per diagnostic count (the rest count as "other")
local HEAL_GAP = 60      -- the same healing call on our channel at most this often (Comm.HealChannel)
local MAX_HURT = 20      -- banned or muted names kept per channel to let back in (oldest dropped)
local LOCKED_RETRY = { 60, 120, 300, 600 } -- a channel locked against us is tried again after these, then every 10 min

local peers = {}
local queue = {}
local chatQueue = {}  -- chat lines (Channels.lua): { msg, done, t, channel } (channel: the one it was written for, GitHub #34)
local lastWasChat = false
local asm = Codec.NewAssembler()
local guildAsm = Codec.NewAssembler() -- pieces over GUILD (1.0.0)...
local GUILD_PIECES = { HS = true, HT = true, XB = true } -- ...put together for these types alone: the High Council's lists, a guild's loot notes (1.1)
local msgId = 0
local lastBroadcast = 0
local early -- { every, due }: the report due then went out early, as a census answer (see Q1)
local channelIndex = 0
local stats = { sent = 0, recv = 0, reports = 0, fails = 0, bad = 0, partial = 0, echo = 0, byType = {},
	raw = { ch = {}, g = {} }, rawSample = {}, reportRealms = {}, otherChannel = 0, asked = 0, answered = 0, askSkipped = 0,
	chatMoved = 0 }
local deliveredLogged = false -- true while a CHAT_MSG_ADDON_LOGGED message is being handled
local lastAnswer = -math.huge
local askTries = 0 -- census requests tried while the channel was not joined (Comm.AskCensus)
local heardAsk = -math.huge -- someone else's census request last heard on our channel (Comm.AskCensus)
local askedAgain = false    -- the second census request is on its way, or went (Comm.AskCensus)
local joinedName -- name of the channel we joined (set by Comm.JoinChannel)
local peerRealm = {} -- guild peer -> realm from its hello, "old" for versions that send none
local peerVersion = {} -- guild peer -> the addon version its hello named
local peerSealed = {} -- guild peer -> "s" (on the sealed channel) or "p" (public), from its hello
local peerZone = {} -- guild peer -> true when its hello says it shares its zone (0.9.1, Comm.SharesZone)
-- Short name -> last time we heard it report our guild on the channel. Short: the server may
-- send a name with its realm over GUILD and without it over CHANNEL (names are region-unique
-- on the realmless client).
local heardOwn = {}
local benched = {}   -- guild peer -> time it may be elected again
local watch          -- { name, since }: the peer we elected while we are on the channel
local lastKeyAsk     -- when MaybeBroadcast last asked our guild for the key
-- 1.0.0: when our channel last carried our guild's report from a guildmate whose hello named
-- another realm (Comm.ElectsAcrossRealms). This session's alone, never saved.
local crossedAt = -math.huge

-- count[key] + 1, with at most MAX_KEYS distinct keys (senders choose some of them).
local function Count(t, key)
	if t[key] == nil then
		local n = 0
		for _ in pairs(t) do n = n + 1 end
		if n >= MAX_KEYS then key = "other" end
	end
	t[key] = (t[key] or 0) + 1
end

-- Our guild's addon users counted now, on every realm; sameRealm (1.0.0): those whose hello
-- named our realm alone.
function Comm.PeerCount(sameRealm)
	local now, n = ns.Now(), 0
	for name, t in pairs(peers) do
		if now - t <= COUNT_WINDOW and (not sameRealm or peerRealm[name] == ns.realm) then n = n + 1 end
	end
	return n
end

-- 1.1: our guild's addon users heard lately (by their hello), by name (Loot.lua draws its officers'
-- turns to answer an ask from them).
function Comm.Peers()
	local now, out = ns.Now(), {}
	for name, t in pairs(peers) do
		if now - t <= PEER_WINDOW then out[#out + 1] = name end
	end
	table.sort(out)
	return out
end

-- The addon versions of our guild's users counted now, ours included: { ["0.8.2"] = 3 }.
-- Rides in our report (field 24) for the author's Workshop.
function Comm.PeerVersions()
	local now, out = ns.Now(), { [ns.VERSION] = 1 }
	for name, t in pairs(peers) do
		if now - t <= COUNT_WINDOW then
			local v = peerVersion[name] or "?"
			out[v] = (out[v] or 0) + 1
		end
	end
	return out
end

-- 1.1.2 (Versions.lua, the right-click menus): one guildmate's addon version as their last hello
-- named it ("?" for a hello whose version we can't read), and when that was; nil when none was
-- heard this session. By the whole name first, else by the short name folded (the roster, a menu
-- and guild messages may write the realm apart, as SharesZone reads them). Never pruned: an old
-- hello still says which version they ran then (the caller shows how long ago).
function Comm.PeerVersion(name)
	if type(name) ~= "string" or name == "" then return nil end
	local full = ns.FullName(ns.Normal(name))
	if peers[full] then return peerVersion[full] or "?", peers[full] end
	local short = ns.Fold(ns.ShortName(full))
	local version, at
	for peer, t in pairs(peers) do
		if ns.Fold(ns.ShortName(peer)) == short and (not at or t > at) then version, at = peerVersion[peer] or "?", t end
	end
	return version, at
end

-- Guild peers counted now, by the realm their hello named.
local function PeerRealms(now)
	local out = {}
	for name, t in pairs(peers) do
		if now - t <= COUNT_WINDOW then Count(out, peerRealm[name] or "old") end
	end
	return out
end

function Comm.Stats()
	local now = ns.Now()
	local lastOwn, lastOwnAt = nil, 0
	for name, t in pairs(heardOwn) do
		if t > lastOwnAt then lastOwn, lastOwnAt = name, t end
	end
	local out = {}
	for name, t in pairs(benched) do
		if t > now then out[#out + 1] = ns.DisplayName(name) end
	end
	table.sort(out)
	local r = Comm.lastReport
	return {
		channelName = joinedName, sealed = ns.rdb and ns.rdb.realmKey ~= nil,
		channel = channelIndex, peers = Comm.PeerCount(), reporter = Comm.reporterName,
		isReporter = Comm.isReporter, sent = stats.sent, recv = stats.recv, reports = stats.reports,
		fails = stats.fails, bad = stats.bad, queue = #queue, chatQueue = #chatQueue, chatMoved = stats.chatMoved, lastFail = stats.lastFail,
		partial = stats.partial, echo = stats.echo, byType = stats.byType, otherChannel = stats.otherChannel,
		chanArgs = stats.chanArgs, asked = stats.asked, answered = stats.answered, runnerUp = Comm.isRunnerUp, pending = (function() local n = 0 for _ in pairs(asm.buf) do n = n + 1 end return n end)(),
		raw = stats.raw, rawSample = stats.rawSample, reportRealms = stats.reportRealms, shared = ns.rdb and ns.rdb.shared,
		peerRealms = PeerRealms(now), heardOwn = lastOwn and ns.DisplayName(lastOwn), heardOwnAt = lastOwn and lastOwnAt,
		benched = out, guard = Comm.GuardStats and Comm.GuardStats(), askSkipped = stats.askSkipped,
		-- 1.0.0: whom the election counts (our realm's peers, or every realm's on a shared channel),
		-- how many before us keep us quiet, our guild's realms, and what our report's new fields say.
		electAll = Comm.ElectsAcrossRealms(now), quietAfter = Comm.QuietAfter(now), presence = Comm.PresenceRealms(now),
		reportSt = r and r.st, reportCap = r and r.cap, reportPres = r and r.pres,
	}
end

-- urgent: ahead of everything waiting (a player waits for the answer: a layer ask, an offer,
-- a vote), behind the other urgent ones. done (1.1, Keys.lua): called once the message left
-- (true) or was dropped from the queue (false).
local function Done(item, sent)
	local done = item[7]
	if done then ns.SafeCall("send done", done, sent) end
end
local function Enqueue(dist, msg, key, target, urgent, logged, done)
	if key then
		for _, item in ipairs(queue) do
			if item[3] == key then
				item[2], item[4], item[6] = msg, target, logged or nil
				if done then item[7] = done end
				return
			end
		end
	end
	if #queue >= MAX_QUEUE then
		-- Full: the oldest ordinary message goes (never an urgent one).
		local drop = 1
		for i, item in ipairs(queue) do
			if not item[5] then drop = i break end
		end
		Done(table.remove(queue, drop), false)
	end
	local item = { dist, msg, key, target, urgent or nil, logged or nil, done }
	if urgent then
		local at = 1
		while queue[at] and queue[at][5] do at = at + 1 end
		table.insert(queue, at, item)
	else
		queue[#queue + 1] = item
	end
end

-- Other modules send small messages through here and register a handler per type.
--   Comm.Send("GUILD" | "CHANNEL", msg, dedupeKey, urgent, logged)
--   Comm.Handle("P1", function(dist, sender, text) ... end)
-- logged (1.0.0): a player's own words (a decree's), sent with the logged API where the client
-- has it (SendNow), as chat lines are: the server keeps them, so abuse can be reported.
--
-- The top-level types (the first two bytes, then "~"), one module each (1.1): a type registered
-- twice goes to the module loaded last, and the other never hears it again (the 1.1 review: the
-- loot notes and the census's route ask had one type). Pick a new one here first; tests/run.lua
-- fails on a type two files register, or one missing here.
--   Before any handler, here: K0 K1 (the realm key), H1 (hello), R1 R2 (census reports), and
--   C<id>:<n>:<of>: (pieces)
--   Comm.lua Q1 | Positions P1 | Layers L0 L1 | Hop LN LO LQ LR LX | Decree D1 | Channels M1
--   Inspect S1 U0 U1 | King T1 T2 T3 | Court T4 T5 | Acts T6 | Treasury T8 TB TE TQ TR TX
--   Bank T9 | Vox Y1 | Loot X1 XQ XB | Crafters W0 W1 WA WL WQ WR
--   Workshop HA HI HK HQ HR HS HT V1 V2 V3 V4 V5 V6 | Link DA DB DC DE DK DR DV DW
--   Other 1.1 work: Recruit J1 J3 | Alts AL | Filter BW | Dues FA FB FC FD FQ FS FU
--   Board G0 G1 GQ | Keys K3 K4 K5 | Channels N1 | Moderation O1 | Treasury TA TD TW
--   Bank TL TN TO TS | Week Y2. Reserved: J2 (#20's route answer), E0 E1 E2 (1.2's army events),
--   FK (a 1.1 build's copy of the dues' amount from the Treasurer's client, read by nobody now).
--   1.1.2, the right-click menus: Versions V7 V8 V9 | Workshop VR (the author asks for a bug report).
local handlers = {}
-- 1.1 (Moderation.lua): a client the moderators took off (net-off) sends none of what they hide.
local function Held(msg)
	local M = ns.Moderation
	return M ~= nil and not M.missing and M.Blocks(msg) == true
end
function Comm.Send(dist, msg, key, urgent, logged)
	if dist == "GUILD" and not IsInGuild() then return end
	if Held(msg) then return end
	Enqueue(dist, msg, key, nil, urgent, logged)
end
-- An addon message to one player only (answers to the King, Throne tab). logged (1.1): a
-- player's own words (a Board note), with the logged API, as Comm.Send. done: see Enqueue.
function Comm.Whisper(target, msg, key, urgent, logged, done)
	if type(target) ~= "string" or target == "" then return end
	if Held(msg) then return end
	Enqueue("WHISPER", msg, key, target, urgent, logged, done)
end
function Comm.Handle(msgType, fn)
	handlers[msgType] = fn
end
-- 1.1: [key] = fn(dist, sender, text), handed every piece heard over GUILD or the channel while set.
Comm.pieceHooks = {}
-- Long payloads (> 255 bytes) go through the same chunking as reports; urgent ones (a
-- question to the army) ahead of the census, their pieces still in order. On the channel, or
-- over GUILD (1.0.0), where only the types in GUILD_PIECES are put together again.
function Comm.SendChunked(payload, urgent, dist)
	dist = dist == "GUILD" and "GUILD" or "CHANNEL"
	if dist == "GUILD" and not IsInGuild() then return end
	msgId = (msgId + 1) % 1000
	for _, c in ipairs(Codec.Chunk(payload, tostring(msgId))) do Enqueue(dist, c, nil, nil, urgent) end
end
function Comm.ChannelReady()
	return channelIndex > 0
end
-- Messages waiting to go out, one each SEND_INTERVAL (chat lines apart).
function Comm.QueueSize()
	return #queue
end
-- How many more fit before the oldest waiting message is dropped (1.1: the King's key rotation
-- hands out no more than that, Keys.lua).
function Comm.QueueRoom()
	return MAX_QUEUE - #queue
end

-- Chat lines wait in a short lane of their own: they never go through Enqueue, so they can
-- never push report chunks out of MAX_QUEUE. done(sent, why) is called once the part went out
-- (true) or was dropped (false, why): "moved" the channel changed before it left (a new realm
-- key), "late" it waited CHAT_TTL, "failed" the game refused it, "left" we are out of a Sylvanistas
-- guild. Each part carries the channel it was written for, and never goes out on another one
-- (GitHub #34: a line typed for one channel's audience is not sent to the next). line (1.1.1):
-- any value the parts of one line share, for Comm.DropLine. Returns false when the lane is full,
-- or while we are on no channel.
function Comm.SendChat(msg, done, line)
	if not joinedName or #chatQueue >= CHAT_QUEUE or Held(msg) then return false end
	chatQueue[#chatQueue + 1] = { msg = msg, done = done, t = GetTime(), channel = joinedName, line = line }
	return true
end
function Comm.ChatRoom()
	return CHAT_QUEUE - #chatQueue
end
-- The parts of chat line `line` still in the lane leave it unsent, each done(false, why) (1.1.1:
-- once one part of a line did not go out, Channels.Send drops the rest, so no one reads a line
-- without its start). Returns how many.
function Comm.DropLine(line, why)
	if line == nil then return 0 end
	local kept, dropped = {}, {}
	for _, item in ipairs(chatQueue) do
		if item.line == line then dropped[#dropped + 1] = item else kept[#kept + 1] = item end
	end
	if #dropped == 0 then return 0 end
	wipe(chatQueue)
	for i, item in ipairs(kept) do chatQueue[i] = item end
	for _, item in ipairs(dropped) do
		if item.done then ns.SafeCall("chat drop", item.done, false, why) end
	end
	return #dropped
end

local function IsSuccess(res)
	-- Older clients return a boolean, newer ones Enum.SendAddonMessageResult (0 = success).
	return res == nil or res == true or res == 0
end

-- Player text goes through the logged API, Blizzard's function for plain text payloads
-- (receivers get CHAT_MSG_ADDON_LOGGED). Clients without it use the usual one.
local function SendNow(dist, msg, logged, whisperTo)
	-- (A whisper goes to the name the server finds: ns.TellName.)
	local target = dist == "CHANNEL" and channelIndex or ns.TellName(whisperTo)
	local send = logged and C_ChatInfo.SendAddonMessageLogged or C_ChatInfo.SendAddonMessage
	local ok, res = pcall(send, ns.PREFIX, msg, dist, target)
	if ok and IsSuccess(res) then
		stats.sent = stats.sent + 1
		return true
	end
	stats.fails = stats.fails + 1
	stats.lastFail = ("%s %s"):format(dist, tostring(res))
	ns.Log("send failed on %s: %s", dist, tostring(res))
	return false
end

-- The Join screen's own addon whispers (1.1, Fern's #20, Recruit.lua): outside a Sylvanistas guild
-- the addon sends nothing else, and these only: J1 (which guild should I ask? to a member /who
-- found) and J3 (my request, with the whisper the player sends himself), one per click or
-- search, straight to that one player, never through the queue (Pump sends nothing for a
-- non-member). A member of a Sylvanistas guild sends neither.
local OUTSIDE_TYPES = { J1 = true, J3 = true }
function Comm.WhisperOutside(target, msg)
	if ns.IsMember() or type(target) ~= "string" or target == "" or type(msg) ~= "string" then return false end
	if not OUTSIDE_TYPES[msg:sub(1, 2)] or msg:sub(3, 3) ~= "~" or #msg > 255 then return false end
	return SendNow("WHISPER", msg, false, target)
end
-- ...and the one message it hears there: J2, a member's answer to its J1 (Recruit.lua checks it
-- asked that member).
local outsideHandler
function Comm.HandleOutside(fn) outsideHandler = fn end

-- Every chat part still waiting is dropped, and its sender is told why (Comm.SendChat).
local function DropChat(why)
	local items = {}
	for i, item in ipairs(chatQueue) do items[i] = item end
	wipe(chatQueue)
	if why == "moved" then stats.chatMoved = stats.chatMoved + #items end
	for _, item in ipairs(items) do
		if item.done then ns.SafeCall("chat drop", item.done, false, why) end
	end
end

-- GitHub #34: the chat parts written for another channel than the one we are on now are dropped
-- ("moved"), the others keep their place. Comm.JoinChannel drops the lane when the channel
-- changes; this second guard holds whatever path changed joinedName. The same channel given
-- another number by the game is no move (Pump follows its number).
local function DropMoved()
	local kept, moved = {}, {}
	for _, item in ipairs(chatQueue) do
		if item.channel == joinedName then kept[#kept + 1] = item else moved[#moved + 1] = item end
	end
	if #moved == 0 then return end
	wipe(chatQueue)
	for i, item in ipairs(kept) do chatQueue[i] = item end
	stats.chatMoved = stats.chatMoved + #moved
	for _, item in ipairs(moved) do
		if item.done then ns.SafeCall("chat drop", item.done, false, "moved") end
	end
end

local function Pump()
	if not queue[1] and not chatQueue[1] then return end
	if not ns.IsMember() then
		-- Outside a Sylvanistas guild the addon sends nothing.
		local dropped = {}
		for i, item in ipairs(queue) do dropped[i] = item end
		wipe(queue)
		for _, item in ipairs(dropped) do Done(item, false) end
		DropChat("left")
		return
	end
	-- The channel may have been left (the Chat Channels panel) and its number given to another
	-- one: check before sending, or [Lords] text would go to that other channel.
	if channelIndex > 0 and joinedName and GetChannelName then
		local id = GetChannelName(joinedName) or 0
		if id ~= channelIndex then
			ns.Log("channel %s is now #%d (was #%d)", joinedName, id, channelIndex)
			channelIndex = id
		end
	end
	if chatQueue[1] then DropMoved() end
	local now = GetTime()
	while chatQueue[1] and now - chatQueue[1].t > CHAT_TTL do
		local item = table.remove(chatQueue, 1)
		if item.done then ns.SafeCall("chat drop", item.done, false, "late") end
	end
	-- Chat goes first, but while reports wait it takes at most every other slot: an idle lane
	-- sends a line within 1.2 s, and the total rate stays one message per SEND_INTERVAL.
	-- (The regular queue is not stamped with a channel: the census, hellos, decrees, pins and
	-- Board notes address the army's channel, whichever it is when they leave, and a pin repeats
	-- itself anyway. Only a player's chat line is written for one channel's audience.)
	if chatQueue[1] and channelIndex > 0 and not (lastWasChat and queue[1]) then
		lastWasChat = true
		local item = table.remove(chatQueue, 1)
		local sent = SendNow("CHANNEL", item.msg, true)
		if item.done then ns.SafeCall("chat sent", item.done, sent, (not sent) and "failed" or nil) end
		return
	end
	lastWasChat = false
	-- Channel messages wait until we joined; guild messages behind them go out meanwhile.
	local index
	for i, item in ipairs(queue) do
		if item[1] ~= "CHANNEL" or channelIndex > 0 then
			index = i
			break
		end
	end
	if not index then return end
	local item = table.remove(queue, index)
	Done(item, SendNow(item[1], item[2], item[6] == true, item[4]))
end
Comm.Pump = Pump -- for tests

---------------------------------------------------------------------------
-- The shared channel. Without a key it is the public "SylvanistasNet". With a realm key (set by
-- an officer with /syl key, then passed to guildmates over GUILD messages, which the server
-- only delivers to members of that guild) the channel gets a name derived from the key and
-- the key as its password: outsiders can neither find it nor join it, edited code or not.
---------------------------------------------------------------------------

local function Hash36(text)
	local h1, h2 = 5381, 52711
	for i = 1, #text do
		local c = text:byte(i)
		h1 = (h1 * 33 + c) % 2147483647
		h2 = (h2 * 31 + c * 7) % 2147483647
	end
	local digits, out, n = "0123456789abcdefghijklmnopqrstuvwxyz", "", h1 * 1000 + (h2 % 1000)
	for _ = 1, 8 do
		local d = n % 36
		out = digits:sub(d + 1, d + 1) .. out
		n = math.floor(n / 36)
	end
	return out
end
Comm.Hash36 = Hash36

-- Each faction has its own channel (and sealed name), so the Horde and the Alliance never
-- mix their census, chat or decrees, whether or not the game shares channel names between them.
function Comm.ChannelSpec()
	local horde = ns.faction == "Horde"
	local key = ns.rdb and ns.rdb.realmKey
	if key and key ~= "" then return (horde and "SylH" or "Syl") .. Hash36(key), key end
	return horde and ns.CHANNEL_HORDE or ns.CHANNEL, nil
end

local function HideChannelFromChat(name)
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local cf = _G["ChatFrame" .. i]
		if cf and ChatFrame_RemoveChannel then pcall(ChatFrame_RemoveChannel, cf, name) end
	end
end

---------------------------------------------------------------------------
-- The channel's owner. Our hidden channel is an ordinary custom chat channel: the first
-- player in owns it, and when the owner leaves WoW hands it (and a moderator's seat) to
-- another member, so any player with the addon can end up owning it. An owner could /password
-- it (nobody who logs in afterwards gets in, and the network dies as people relog), /ban or
-- /ckick players (the King, the Treasurer), make a friend /moderator or give it away with
-- /owner. Sylvanistas never uses these powers against anyone. It follows the channel's notices,
-- tells a player who was handed the channel what that means, and while the channel is ours it
-- only undoes harm (Comm.HealChannel). A channel locked against us is tried again, slower and
-- slower (Comm.JoinChannel). There is no other name to flee to: whoever locks one name can
-- squat any name we could predict as easily, and clients on different names would split the
-- army. We keep knocking on the same door until an honest owner opens it.
---------------------------------------------------------------------------

-- What we know of the channel named `name`, from its notices: a new record when we move to
-- another channel (the realm key arrived).
local function NewGuard(name)
	return { name = name, mine = {}, banned = {}, muted = {}, seen = {} }
end
local guard = NewGuard(nil)
local told = {}          -- role -> true once the player was told this session
local toldLocked = false -- ...and about a channel locked against us
local healAt = {}        -- healing call -> when it was last made (HEAL_GAP)
local healPending, rolePending = false, false
local healRefused = false -- the game refused one of these calls to addons: no more this session
local joinTries = 0      -- JoinChannelByName calls: one failed join counts once, however many notices say so

local function GuardFor(name)
	if guard.name ~= name then guard = NewGuard(name) end
	return guard
end

-- Our channel, whatever form a notice gives its name ("SylvanistasNet" or "5. SylvanistasNet").
local function OurChannel(...)
	local ours = joinedName or Comm.ChannelSpec()
	if type(ours) ~= "string" then return nil end
	for i = 1, select("#", ...) do
		local n = select(i, ...)
		if type(n) == "string" and n ~= "" and n:gsub("^%d+%.%s*", ""):lower() == ours:lower() then return ours end
	end
	return nil
end

local function IsMe(name)
	if type(name) ~= "string" or name == "" or not ns.me then return false end
	if ns.Channels and ns.Channels.IsMe then return ns.Channels.IsMe(name) end
	return ns.FullName(ns.Normal(name)) == ns.me
end

-- A name the way the server finds it again (ns.TellName), or nil.
local function ServerName(name)
	if type(name) ~= "string" or name == "" then return nil end
	return ns.TellName(name)
end

-- list[name] = when, at most MAX_HURT names (the oldest goes).
local function Remember(list, name, now)
	name = ServerName(name)
	if not name then return end
	local n, oldest = 0, nil
	for k, t in pairs(list) do
		n = n + 1
		if not oldest or t < list[oldest] then oldest = k end
	end
	if not list[name] and n >= MAX_HURT then list[oldest] = nil end
	list[name] = now
end

local function Mine(g) return g.mine.owner or g.mine.moderator end

-- Players the channel must never lose, the way the server finds them: the Treasurer, and the
-- King's character when our client knows it (our own roster in his guild, or a character
-- pinned in Core.lua).
local function Protected()
	local out, seen = {}, {}
	local function Add(name)
		name = ServerName(name)
		if name and not seen[name:lower()] then
			seen[name:lower()] = true
			out[#out + 1] = name
		end
	end
	Add(ns.TREASURER)
	local pinned = ns.KING_CHARACTER
	if type(pinned) == "table" then pinned = pinned[ns.faction or "Alliance"] end
	Add(pinned)
	if ns.IsKingGuild and ns.IsKingGuild(GetGuildInfo("player")) and ns.Roster and type(ns.Roster.byName) == "table" then
		for name, rank in pairs(ns.Roster.byName) do
			if rank == 0 then Add(name) break end
		end
	end
	return out
end

-- One healing call, protected, the same one at most every HEAL_GAP: "done", "failed",
-- "later" (too soon: try again) or "missing" (this client has no such function).
local function HealCall(what, fn, ...)
	if type(fn) ~= "function" or healRefused then return "missing" end
	local now = ns.Now()
	if now - (healAt[what] or -math.huge) < HEAL_GAP then return "later" end
	healAt[what] = now
	local ok, err = pcall(fn, ...)
	ns.Log("channel %s: %s%s", tostring(guard.name), what, ok and "" or (" failed: " .. tostring(err)))
	return ok and "done" or "failed"
end

local function HealSoon(delay)
	if healPending then return end
	healPending = true
	ns.After(delay or 2, "channel heal", function()
		healPending = false
		Comm.HealChannel()
	end)
end

-- Only while the channel is ours (owner or moderator), only to undo harm, never against
-- anyone: the password it should have (none on the public channel, the key on the sealed
-- one), no moderation, and whoever was banned or muted while we were on it let back in, the
-- Treasurer and the King always. Only for the channel we are meant to be on: what we saw on
-- another one (the public channel once we have a key) changes nothing.
-- What someone does with the channel from our own client is not undone here: the next owner's
-- client does it.
function Comm.HealChannel()
	local g = guard
	local name, key = Comm.ChannelSpec()
	if not name or g.name ~= name or not Mine(g) or not ns.IsMember() then return end
	if type(GetChannelName) ~= "function" or (GetChannelName(name) or 0) == 0 then return end
	local later = false
	local function Do(what, fn, ...)
		local r = HealCall(what, fn, ...)
		if r == "later" then later = true end
		return r
	end
	-- The password: after a change we saw, or when the channel came to us and we had not
	-- watched it since we joined (a /reload forgets what was seen before it).
	if g.password or g.unwatched then
		if Do("password " .. (key and "back to the key" or "cleared"), SetChannelPassword, name, key or "") ~= "later" then
			g.password, g.unwatched = nil, nil
		end
	end
	-- Moderation is switched over, not set: only when we know it is on, once for each time we
	-- saw it turned on. (Today's clients have no ChannelModerate: nobody can turn it on either.)
	if g.moderationOn and Do("moderation off", ChannelModerate, name) ~= "later" then g.moderationOn = nil end
	local unban = {}
	for who in pairs(g.banned) do unban[who] = true end
	if g.protect then
		for _, who in ipairs(Protected()) do unban[who] = true end
	end
	local waiting = false
	for who in pairs(unban) do
		if Do("unban " .. who, ChannelUnban, name, who) == "later" then waiting = true else g.banned[who] = nil end
	end
	if not waiting then g.protect = nil end
	-- (No ChannelUnmute in today's clients either: kept for one that has it.)
	for who in pairs(g.muted) do
		if Do("unmute " .. who, ChannelUnmute, name, who) ~= "later" then g.muted[who] = nil end
	end
	if later then HealSoon(HEAL_GAP) end
end

-- Handed the channel (owner or moderator): the player is told once a session what that
-- means, then the heal runs. A moment later, so an owner's two notices make one line.
local function RoleGiven(g)
	if rolePending then return end
	rolePending = true
	ns.After(2, "channel role", function()
		rolePending = false
		if guard ~= g or not Mine(g) then return end
		local role = g.mine.owner and "owner" or "moderator"
		if not told[role] then
			told[role] = true
			if role == "owner" then told.moderator = true end
			ns.Print("|cffffd200" .. (role == "owner" and ns.L.CHANNEL_OWNER_YOU or ns.L.CHANNEL_MODERATOR_YOU):format(g.name) .. "|r")
		end
		Comm.HealChannel()
	end)
end

-- Joining failed: a password or a ban. The player is told once a session; the next try waits
-- LOCKED_RETRY (see Comm.JoinChannel).
local function Locked(g, why, now)
	local lock = g.locked
	if not lock then
		lock = { why = why, tries = 0, since = now }
		g.locked = lock
		if not toldLocked then
			toldLocked = true
			ns.Print("|cffffd200" .. ns.L.CHANNEL_LOCKED:format(g.name) .. "|r")
		end
	end
	lock.why = why
	if lock.try == joinTries then return end
	lock.try = joinTries
	lock.tries = lock.tries + 1
	lock.nextAt = now + LOCKED_RETRY[math.min(lock.tries, #LOCKED_RETRY)]
	ns.Log("channel %s locked against us (%s, try %d): next try in %ds", g.name, why, lock.tries, lock.nextAt - now)
end

-- In again after being locked out: the census missed in the meantime is asked for.
local function Unlocked(g)
	if not g.locked then return end
	ns.Log("channel %s open to us again after %d tries", g.name, g.locked.tries)
	g.locked = nil
	askTries = 0
	ns.After(Comm.AskWait(), "census request", Comm.AskCensus)
end

-- CHAT_MSG_CHANNEL_NOTICE and CHAT_MSG_CHANNEL_NOTICE_USER: (notice type, player, language,
-- "5. SylvanistasNet", second player, flags, zone channel id, channel number, "SylvanistasNet", ...).
-- With two players (banned, kicked, unbanned) the first is the one it happened to and the
-- second who did it. Only our channel's notices count.
function Comm.OnChannelNotice(notice, player, _, channelName, player2, _, _, _, baseName)
	-- Forever may hand these over as secret values while chat is locked down: nothing to read.
	if type(issecretvalue) == "function" and (issecretvalue(notice) or issecretvalue(player) or issecretvalue(player2)) then return end
	if type(notice) ~= "string" then return end
	local name = OurChannel(baseName, channelName)
	if not name then return end
	local g, now = GuardFor(name), ns.Now()
	player = type(player) == "string" and player ~= "" and player or nil
	player2 = type(player2) == "string" and player2 ~= "" and player2 or nil
	if notice == "YOU_JOINED" or notice == "YOU_CHANGED" then
		g.watched = true -- in from the start: every change after this reaches us
		Unlocked(g)
	elseif notice == "YOU_LEFT" or notice == "SUSPENDED" then
		g.mine, g.watched = {}, nil -- whoever leaves gives the channel away
	elseif notice == "WRONG_PASSWORD" or notice == "BANNED" then
		Locked(g, notice, now)
	elseif notice == "OWNER_CHANGED" or notice == "CHANNEL_OWNER" then
		if notice == "OWNER_CHANGED" then Count(g.seen, "owner") end
		g.owner, g.ownerAt = player, now
		if not IsMe(player) then
			g.mine.owner = nil
		elseif not g.mine.owner then
			g.mine.owner = true
			g.unwatched = not g.watched or nil
			g.protect = true
			RoleGiven(g)
		end
	elseif notice == "SET_MODERATOR" or notice == "UNSET_MODERATOR" then
		if not IsMe(player) then
			if notice == "SET_MODERATOR" then Count(g.seen, "moderator") end -- a seat handed to someone else
		elseif notice == "UNSET_MODERATOR" then
			g.mine.moderator = nil
		elseif not g.mine.moderator then
			g.mine.moderator = true
			g.protect = true
			RoleGiven(g)
		end
	elseif notice == "PASSWORD_CHANGED" then
		Count(g.seen, "password")
		if not IsMe(player) then g.password = { by = player, t = now } end
	elseif notice == "MODERATION_ON" or notice == "MODERATION_OFF" then
		Count(g.seen, "moderation")
		g.moderation = notice == "MODERATION_ON" and "on" or "off"
		g.moderationOn = notice == "MODERATION_ON" and not IsMe(player) or nil
	elseif notice == "ANNOUNCEMENTS_ON" or notice == "ANNOUNCEMENTS_OFF" then
		g.announce = notice == "ANNOUNCEMENTS_ON" and "on" or "off"
	elseif notice == "PLAYER_BANNED" or notice == "PLAYER_KICKED" then
		Count(g.seen, notice == "PLAYER_BANNED" and "ban" or "kick")
		if IsMe(player) then
			g.mine, g.watched = {}, nil
		elseif notice == "PLAYER_BANNED" and not IsMe(player2) then
			Remember(g.banned, player, now)
		end
	elseif notice == "PLAYER_UNBANNED" then
		local who = ServerName(player)
		if who then g.banned[who] = nil end
	elseif notice == "UNSET_SPEAK" or notice == "UNSET_VOICE" then
		Count(g.seen, "mute")
		Remember(g.muted, player, now)
	elseif notice == "SET_SPEAK" or notice == "SET_VOICE" then
		local who = ServerName(player)
		if who then g.muted[who] = nil end
	elseif notice == "MUTED" then
		Count(g.seen, "we muted") -- we may not speak there
	else
		return
	end
	ns.Log("channel %s: %s %s%s", name, notice, tostring(player or "-"), player2 and (" by " .. player2) or "")
	if Mine(g) then HealSoon() end
end

-- Blizzard's own password prompt for our channel: the same as a wrong password.
function Comm.OnPasswordRequest(channel)
	local name = OurChannel(channel)
	if name then Locked(GuardFor(name), "WRONG_PASSWORD", ns.Now()) end
end

-- None of the calls above is marked protected, but should the game ever refuse one to addons,
-- the first refusal ends healing for the session: never a string of "blocked" warnings.
function Comm.OnActionRefused(addon, func)
	if addon ~= ADDON or type(func) ~= "string" then return end
	if func:find("SetChannelPassword", 1, true) or func:find("ChannelUn", 1, true) or func:find("ChannelModerate", 1, true) then
		healRefused = true
		ns.Log("channel healing off for this session: the game refused %s", func)
	end
end

-- For /syl status: the channel's owner as last seen, our seat, what was seen.
function Comm.GuardStats()
	local g, now = guard, ns.Now()
	local function Size(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
	return {
		name = g.name, owner = g.owner, ownerAt = g.ownerAt,
		role = g.mine.owner and "owner" or (g.mine.moderator and "moderator" or "member"),
		moderation = g.moderation, announce = g.announce, seen = g.seen, watched = g.watched == true,
		banned = Size(g.banned), muted = Size(g.muted), password = g.password ~= nil,
		locked = g.locked and { why = g.locked.why, tries = g.locked.tries, nextIn = math.max(0, (g.locked.nextAt or now) - now) },
	}
end

function Comm.JoinChannel()
	if not ns.IsMember() then return end
	local name, password = Comm.ChannelSpec()
	if joinedName and joinedName ~= name then
		-- Another channel (the realm key arrived or changed). The chat lines still waiting were
		-- written for the old one's audience: dropped, never sent on this one, and their writer is
		-- told (GitHub #34). Votes heard on the old one don't count here, and its reporters have
		-- not heard our census request.
		DropChat("moved")
		if ns.Data and ns.Data.ForgetVotes then ns.Data.ForgetVotes() end
		askTries = 0
		heardAsk = -math.huge -- (the answers to an ask heard there went there)
		ns.After(10, "census request", Comm.AskCensus)
	end
	if joinedName and joinedName ~= name and GetChannelName(joinedName) > 0 then
		LeaveChannelByName(joinedName) -- the key changed: leave the old channel
		channelIndex = 0
	end
	if joinedName ~= name then watch = nil end -- another channel: the election guard starts again
	joinedName = name
	local id = GetChannelName(name)
	if id and id > 0 then
		if channelIndex ~= id then ns.Log("channel %s is #%d", name, id) end
		channelIndex = id
		HideChannelFromChat(name)
		return
	end
	-- Locked against us (a password or a ban): not before the next try is due (Locked).
	local lock = guard.name == name and guard.locked
	if lock and ns.Now() < (lock.nextAt or 0) then return end
	joinTries = joinTries + 1
	ns.Log("joining channel %s%s", name, password and " (sealed)" or "")
	watch = nil -- time off this channel says nothing about what we hear on it (election guard)
	JoinChannelByName(name, password)
	ns.After(3, "channel check", function()
		channelIndex = GetChannelName(name) or 0
		if channelIndex > 0 and guard.name == name then Unlocked(guard) end
		Comm.joinedAt = ns.Now()
		ns.SafeCall("channel last", Comm.KeepLast)
		ns.Log("channel %s -> #%d", name, channelIndex)
		HideChannelFromChat(name)
	end)
end

function Comm.ChannelName() return joinedName end
function Comm.DeliveredLogged() return deliveredLogged end

-- Who can read the channel, as the privacy questions tell the player (Layers, Channels):
-- anyone without a realm key, whoever holds the key with one.
function Comm.Audience()
	return (ns.rdb and ns.rdb.realmKey) and ns.L.CHANNEL_SEALED or ns.L.CHANNEL_PUBLIC
end

-- The channel is public (1.1): no realm key, so anyone who joins it by name reads what is sent
-- there. nil outside a Sylvanistas guild (the addon is on no channel there).
function Comm.IsPublic()
	if not ns.IsMember() then return nil end
	return not (ns.rdb and ns.rdb.realmKey)
end

-- Our guild's addon users on the sealed channel now, as their hellos say (1.1: while we are on
-- the public one, they are on another channel than ours).
function Comm.SealedPeers()
	local now, n = ns.Now(), 0
	for name, t in pairs(peers) do
		if now - t <= COUNT_WINDOW and peerSealed[name] == "s" then n = n + 1 end
	end
	return n
end

-- No key? Ask our guild (officers who have it answer, over GUILD).
function Comm.RequestKey()
	if ns.IsMember() and ns.rdb and not ns.rdb.realmKey then Enqueue("GUILD", "K0~", "keyreq") end
end

-- /syl key <secret>: officers seal the channel; guildmates receive the key automatically.
function Comm.SetRealmKey(secret)
	if not ns.IsMember() or not ns.Roster.IsOfficer() then
		ns.Print(ns.L.KEY_OFFICERS_ONLY)
		return
	end
	secret = (secret or ""):gsub("[~|\n]", "")
	if #secret < 6 then
		ns.Print(ns.L.KEY_TOO_SHORT)
		return
	end
	local was = ns.rdb.realmKey
	ns.rdb.realmKey = secret
	Enqueue("GUILD", "K1~" .. secret, "key")
	-- 1.1 (Keys.lua): dated now, so our guild's 1.1 clients take it over a key the King rotated
	-- before; the key it replaces named with it (a plain K1 of that one no longer pulls them back).
	if ns.Keys.Typed then ns.Keys.Typed(secret, was) end
	ns.Print(ns.L.KEY_SET)
	Comm.JoinChannel()
end

---------------------------------------------------------------------------
-- Realms (1.0.0). WoW: Forever's PvP and PvP 2 each have an SylvanistasNet of their own, and a
-- guild has members on both: a reporter on one realm is never heard on the other one's
-- channel, and a guild that elected a single reporter was missing from the other realm's
-- census (older versions left that reporter out after GUARD_AFTER unheard, one name at a time).
-- So each realm elects its own reporter among the peers whose hello names that realm, and
-- those whose realm we don't know (versions before 0.7.11), unless the server stamps another
-- realm on their name (see Electable). While our guild's report, sent by a guildmate of another
-- realm, reaches our channel (the channel is shared: Comm.ElectsAcrossRealms), one reporter for
-- all, as before.
---------------------------------------------------------------------------

-- A realm's code in our report (field 27): three letters or digits.
function Comm.RealmCode(realm)
	return Hash36(tostring(realm)):sub(1, 3)
end

-- The realms our guild's addon users play on now (hellos counted within COUNT_WINDOW), ours
-- included, sorted by name.
function Comm.PresenceRealms(now)
	now = now or ns.Now()
	local set, out = { [tostring(ns.realm)] = true }, {}
	for name, t in pairs(peers) do
		local realm = peerRealm[name]
		if now - t <= COUNT_WINDOW and realm and realm ~= "old" then set[realm] = true end
	end
	for realm in pairs(set) do out[#out + 1] = realm end
	table.sort(out)
	return out
end

-- The same as codes, sorted, each once: `pres`, field 27 of our report.
function Comm.Presence(now)
	local out, seen = {}, {}
	for _, realm in ipairs(Comm.PresenceRealms(now)) do
		local code = Comm.RealmCode(realm)
		if not seen[code] then seen[code], out[#out + 1] = true, code end
	end
	table.sort(out)
	return out
end

-- Does our guild have addon users online on another realm than ours?
function Comm.SpansRealms(now)
	return #Comm.PresenceRealms(now) > 1
end

-- Our census reaches no other role than reporting yet: "a" in field 26 of our report (the
-- census layer's clients will say "b" or "c").
Comm.CAPABILITY = "a"

-- Our channel crosses realms: our guild's report, sent by a guildmate whose hello over GUILD
-- (where the server vouches for our guild) named another realm, was heard on it within
-- SHARED_FOR, in this session. Every realm's peers hear one reporter there then, and the
-- election counts them all. Nothing else proves it: the realm a report names (field 21, `from`;
-- ns.rdb.shared in /syl status) is whatever its sender wrote, and anyone on the public channel
-- may send one; a flag saved by an earlier session proves nothing of this one.
function Comm.ElectsAcrossRealms(now)
	return (now or ns.Now()) - crossedAt <= SHARED_FOR
end

-- The realm, not ours, that the hello of this guildmate named (counted now), or nil. The channel
-- may send a name of another realm without it (see heardOwn): matched by the short name then,
-- unless the full name is a peer of its own. Only a realm the server stamped on the hello's
-- sender too (1.0.0, Konig's review of 1.0.0): a guildmate of our realm whose hello named another
-- one, sending our guild's report on our channel, made our election cross realms, and our guild's
-- reporter then played on another realm's channel, off our realm's census.
local function OtherRealm(name, now)
	local t, realm = peers[name], peerRealm[name]
	if t and now - t <= COUNT_WINDOW and realm and realm ~= "old" and realm ~= ns.realm and ns.RealmOf(name) == realm then
		return realm
	end
end
local function PeerOfOtherRealm(sender, now)
	if peers[sender] then return OtherRealm(sender, now) end
	local short = ns.ShortName(sender)
	for name in pairs(peers) do
		local realm = ns.ShortName(name) == short and OtherRealm(name, now)
		if realm then return realm end
	end
end

-- In a full guild, 1000 members saying hello every minute would be ~16 messages per second.
-- Only names that could win the reporter election need to keep talking: once this many
-- members that sort before us (and may be elected with us) are known, we go quiet (still one
-- hello per 10 minutes to be counted). With a reporter per realm (1.0.0), each realm keeps its
-- share of the QUIET_TOTAL talking, QUIET_MIN at least.
function Comm.QuietAfter(now)
	if Comm.ElectsAcrossRealms(now) then return QUIET_TOTAL end
	return math.max(QUIET_MIN, math.ceil(QUIET_TOTAL / #Comm.PresenceRealms(now)))
end

local lastHello = 0
-- force: now, whatever the above (the player changed what the hello says).
function Comm.Hello(force)
	if not IsInGuild() then return end
	local now, before = ns.Now(), 0
	for name, t in pairs(Comm.Electable(now)) do
		if now - t <= PEER_WINDOW and name < (ns.me or "") then before = before + 1 end
	end
	if not force and before >= Comm.QuietAfter(now) and now - lastHello < 600 then return end
	lastHello = now
	-- Our realm rides along: guildmates on another realm show in /syl status (topology). So does
	-- our channel: without the key we can't hear a reporter on the sealed one (MaybeBroadcast).
	-- And "z" when we share our zone (0.9.1): our guild's reporter may name it then, never
	-- otherwise. Older versions read the fields before it and ignore the rest.
	local sealed = ns.rdb and ns.rdb.realmKey and "s" or "p"
	local zone = ns.Layers and ns.Layers.Sharing and ns.Layers.Sharing() and "~z" or ""
	Enqueue("GUILD", "H1~" .. ns.VERSION .. "~" .. tostring(ns.realm) .. "~" .. sealed .. zone, "hello")
end

-- Does this guildmate share their zone (their hello says so, or it is us and we do)? By the
-- short name the roster gives, like heardOwn: the roster and guild messages may write the
-- realm apart. Only while they are counted (COUNT_WINDOW): quiet peers say hello every 10 min.
function Comm.SharesZone(name)
	if type(name) ~= "string" or name == "" then return false end
	local short = ns.ShortName(ns.Normal(name)):lower()
	if ns.me and short == ns.ShortName(ns.me):lower() then
		return ns.Layers and ns.Layers.Sharing and ns.Layers.Sharing() or false
	end
	local now = ns.Now()
	for peer, t in pairs(peers) do
		if peerZone[peer] and now - t <= COUNT_WINDOW and ns.ShortName(peer):lower() == short then return true end
	end
	return false
end

-- The peers that may be elected (1.0.0): those on our realm and those of a realm we don't know
-- (a hello without one: "old", on no other realm by the server's stamp), or every realm's while
-- the channel is shared (see Realms, above); never one left out by the guard below. The
-- runner-up is drawn from the same pool.
-- The server's stamp on a peer's name counts first, whatever its hello says (1.0.0, Konig's
-- review of 1.0.0): a guildmate the server places on PvP 2 whose hello named no realm, or one
-- we can't read ("old"), was elected on ours, never heard on our channel, and our guild was off
-- our realm's census while the guard left him out (GUARD_AFTER), then his next alt. A peer of
-- another realm by the server's stamp is left out here unless the channel is shared; "old"
-- stays what the runner-up's pick reads it as (a version that sends no runner-up report).
local function Electable(now)
	local all, pool = Comm.ElectsAcrossRealms(now), {}
	for name, t in pairs(peers) do
		local realm, stamped = peerRealm[name], ns.RealmOf(name)
		local ours = (realm == nil or realm == "old" or realm == ns.realm) and (stamped == nil or stamped == ns.realm)
		if (benched[name] or 0) <= now and (all or ours) then pool[name] = t end
	end
	return pool
end
Comm.Electable = Electable

-- When our last report counts as sent, for a sender reporting every `every` seconds: a census
-- answer sends the next due report early (Q1 below), and the one after it then waits a full
-- period from when the answered one was due. Answers move reports forward, never add one.
local function LastReport(every)
	if early and early.every == every and early.due > lastBroadcast then return early.due end
	return lastBroadcast
end

function Comm.MaybeBroadcast(report)
	local now = ns.Now()
	-- Peers are keyed "Name-Realm" like ns.me, so every client compares the same strings.
	local pool = Electable(now)
	local best = Codec.PickReporter(ns.me, pool, now, PEER_WINDOW)
	-- Rollout guard: a peer that wins the election but never reports (an old or broken
	-- version, or one that is not on the channel) keeps our guild off everyone's census.
	-- Elected for GUARD_AFTER while we are on the channel and never heard reporting our guild
	-- there, it is left out for GUARD_FOR and the next one is elected (maybe us).
	-- A reporter on the sealed channel is not ours to judge while we have no key: we can't hear
	-- it, and its reports reach the guilds they should. We ask for the key instead.
	local deaf = best ~= ns.me and peerSealed[best] == "s" and not (ns.rdb and ns.rdb.realmKey)
	if deaf then
		watch = nil
		if now - (lastKeyAsk or Comm.loginAt or 0) >= KEY_ASK_EVERY then
			lastKeyAsk = now
			Comm.RequestKey()
		end
	elseif best ~= ns.me and channelIndex > 0 then
		if not watch or watch.name ~= best then watch = { name = best, since = now } end
		if now - math.max(watch.since, heardOwn[ns.ShortName(best)] or 0) >= GUARD_AFTER then
			benched[best] = now + GUARD_FOR
			ns.Log("reporter %s never heard in %ds: left out of the election for %dm", best, GUARD_AFTER, GUARD_FOR / 60)
			pool[best], watch = nil, nil
			best = Codec.PickReporter(ns.me, pool, now, PEER_WINDOW)
		end
	else
		watch = nil
	end
	Comm.isReporter = best == ns.me
	Comm.reporterName = ns.DisplayName(best)
	Comm.lastReport = report
	-- The runner-up of the election reports too, every WITNESS_EVERY: a report never proves
	-- its own sender's rank, so other guilds trust a reporter who leads the guild (or is an
	-- officer) only once a second sender names them (Data.KnownRank).
	local second
	if not Comm.isReporter then
		-- Only a peer that can back the reporter: on 0.7.11 or later (older ones never send a
		-- runner-up report) and on the same channel as the reporter (sealed or public).
		local rest = {}
		for name, t in pairs(pool) do
			if name ~= best and peerRealm[name] ~= "old" and (peerSealed[name] == nil or peerSealed[name] == peerSealed[best]) then
				rest[name] = t
			end
		end
		second = Codec.PickReporter(ns.me, rest, now, PEER_WINDOW)
	end
	-- Only while the reporter is heard on our channel: the point is to back an active one.
	Comm.isRunnerUp = second == ns.me and best ~= nil and now - (heardOwn[ns.ShortName(best)] or -math.huge) <= 2 * BROADCAST_EVERY
	local every = Comm.isReporter and BROADCAST_EVERY or (Comm.isRunnerUp and WITNESS_EVERY or nil)
	if not every or now - LastReport(every) < every then return end
	-- Right after login we don't know our guildmates yet and would wrongly think we are the
	-- reporter: wait one hello round first.
	if now - (Comm.loginAt or 0) < HELLO_EVERY + 10 then return end
	Comm.Broadcast(report)
end

function Comm.Broadcast(report)
	-- 1.1: our guild is off the Sylvanistas network (net-off, Moderation.lua): its census stays home.
	local M = ns.Moderation
	if M and not M.missing and M.OwnGuildOff() then
		if not Comm.heldReport then ns.Log("census of %s not sent: the guild is off the network", tostring(report and report.guild)) end
		Comm.heldReport = true
		return
	end
	Comm.heldReport = nil
	lastBroadcast = ns.Now()
	msgId = (msgId + 1) % 1000
	-- Where people are goes out only with their yes (0.9.1): nothing of it unless we share our
	-- own zone, and then the counts per zone and the zones of the leader and officers who
	-- share theirs. Our own window keeps the whole report (it never leaves this client).
	local sharing = ns.Layers and ns.Layers.Sharing and ns.Layers.Sharing()
	local payload = Codec.EncodeReport(Codec.Shareable(report, sharing, sharing and Comm.SharesZone or nil))
	local chunks = Codec.Chunk(payload, tostring(msgId))
	for _, c in ipairs(chunks) do Enqueue("CHANNEL", c) end
	ns.Log("broadcast %s: %d bytes in %d chunks", report.guild, #payload, #chunks)
end

-- The census on request. The Forever beta client saves addon data but never loads it back, so
-- every login starts with an empty census: we ask the channel (Q1), and each guild's reporter
-- sends its report right away instead of within 3 minutes. Bounded: a reporter answers at
-- most once every ANSWER_GAP, and only if its last report is ANSWER_MIN_AGE old. A reporter
-- that had just answered someone else stays quiet, so we ask once more ASK_AGAIN later, unless
-- a report came meanwhile (the reporters are answering; the quiet ones report on their own
-- within BROADCAST_EVERY).
-- Tries again a little later while the channel is not joined yet (at most 3 times), and once
-- more after the channel changes (the realm key arrived).
-- After a server restart thousands log in within minutes (1.0.0): each asks at a second of its
-- own (Comm.AskWait), and leaves its ask out when someone else asked within ASK_HELD, since
-- every guild's answer to that ask reaches the whole channel. A left-out ask counts as ours for
-- the second one: asked ASK_AGAIN later unless a report came.
function Comm.AskCensus()
	if not ns.IsMember() then return end
	if channelIndex == 0 then
		askTries = askTries + 1
		if askTries < 3 then ns.After(20, "census request", Comm.AskCensus) end
		return
	end
	-- Login and a guild change can both ask within seconds: once a minute is enough.
	local now = ns.Now()
	if Comm.lastAsk and now - Comm.lastAsk < 60 then return end
	Comm.lastAsk = now
	if now - heardAsk < ASK_HELD then
		stats.askSkipped = stats.askSkipped + 1
	else
		stats.asked = stats.asked + 1
		Enqueue("CHANNEL", "Q1~", "censusreq")
	end
	if not askedAgain then
		askedAgain = true
		local heard = stats.reports
		ns.After(ASK_AGAIN, "census request", function()
			if stats.reports > heard then return end
			Comm.AskCensus()
		end)
	end
end

-- When our census request goes, seconds after we joined the channel: ASK_AFTER to
-- ASK_AFTER + ASK_SPREAD (1.0.0; swappable in tests).
Comm.random = math.random
function Comm.AskWait()
	return ASK_AFTER + Comm.random() * ASK_SPREAD
end

-- We join as soon as the game's own channels are in (General is /1 for two seconds), so
-- General/Trade/LocalDefense keep their usual numbers (/1, /2...), and at JOIN_BY whatever
-- happens. The census request follows (Comm.AskWait), once the channel has its number.
function Comm.JoinSoon(t, seenAt)
	local _, first = GetChannelName(1)
	if first and first ~= "" then seenAt = seenAt or t end
	if t >= JOIN_BY or (seenAt and t - seenAt >= 2) then
		Comm.JoinChannel()
		ns.After(Comm.AskWait(), "census request", Comm.AskCensus)
		return
	end
	ns.After(1, "join channel", function() Comm.JoinSoon(t + 1, seenAt) end)
end

-- For tests: the channel we joined.
function Comm.JoinedName() return joinedName end
function Comm.SetJoinedForTest(name) joinedName = name end

-- Our hidden channel after the game's own. Joined before them (a slow login), it took /1 and
-- pushed General to /2, Trade to /3: moved past each of the game's channels numbered after
-- it, they get their usual numbers back. The player's own channels and other addons' keep
-- theirs.
function Comm.KeepLast()
	if not joinedName or not GetChannelList then return end
	local swap = C_ChatInfo and C_ChatInfo.SwapChatChannelsByChannelIndex
	local infoOf = C_ChatInfo and C_ChatInfo.GetChannelInfoFromIdentifier
	if not swap or not infoOf then return end
	local ours = GetChannelName(joinedName) or 0
	if ours <= 0 then return end
	local list = { GetChannelList() }
	local stride = type(list[3]) == "boolean" and 3 or 2 -- (id, name, disabled) or (id, name)
	local after = {}
	for i = 1, #list, stride do
		local id = tonumber(list[i])
		local ok, info = pcall(infoOf, list[i + 1])
		-- The game's channels (General, Trade...) are zone channels; custom ones are not.
		if id and id > ours and ok and type(info) == "table" and (tonumber(info.zoneChannelID) or 0) > 0 then after[#after + 1] = id end
	end
	if #after == 0 then return end
	table.sort(after)
	local at = ours
	for _, id in ipairs(after) do
		if not pcall(swap, at, id) then break end
		at = id
	end
	channelIndex = GetChannelName(joinedName) or channelIndex
	ns.Log("channel %s moved from #%d to #%d", joinedName, ours, channelIndex)
end

-- Right after login we may think we are the reporter only because we have not heard our
-- guildmates yet (see MaybeBroadcast): no answers then.
local function Settled(now)
	return now - (Comm.loginAt or 0) >= HELLO_EVERY + 10
end

-- The reporter answers, and the runner-up too (a little later): a client that just logged in
-- then has two senders' word on each guild at once, which the Crown needs (Data.KnownRank).
-- Every login asks, so with thousands of players requests never stop: an answer is the next
-- due report sent early (LastReport), and the reporter still sends one report per
-- BROADCAST_EVERY, the runner-up one per WITNESS_EVERY, however many ask.
Comm.Handle("Q1", function(dist, sender, text)
	if dist ~= "CHANNEL" then return end
	heardAsk = ns.Now() -- (our own ask waits on it: Comm.AskCensus)
	if not Comm.lastReport or not (Comm.isReporter or Comm.isRunnerUp) then return end
	local now = ns.Now()
	local every = Comm.isReporter and BROADCAST_EVERY or WITNESS_EVERY
	local gap = Comm.isReporter and ANSWER_GAP or WITNESS_ANSWER_GAP
	if not Settled(now) or now - lastAnswer < gap or now - LastReport(every) < ANSWER_MIN_AGE then return end
	lastAnswer = now
	stats.answered = stats.answered + 1
	-- A short random delay spreads the answers of every guild.
	local delay = Comm.isReporter and math.random(1, 8) or math.random(9, 16)
	ns.After(delay, "census answer", function()
		local later = ns.Now()
		if not (Comm.isReporter or Comm.isRunnerUp) or not Comm.lastReport or not Settled(later) then return end
		local period = Comm.isReporter and BROADCAST_EVERY or WITNESS_EVERY
		local last = LastReport(period)
		if later - last < ANSWER_MIN_AGE then return end
		Comm.Broadcast(Comm.lastReport)
		early = { every = period, due = last + period }
	end)
end)

-- Admission (0.9.3): one sender gets ADMIT_BURST messages at once and ADMIT_RATE a second
-- after that, whatever they are (a census report is 30 pieces at most, every 3 minutes); past
-- it their messages are dropped unread. At most ADMIT_SENDERS senders are tracked (the ones
-- quiet for a minute are forgotten first), so the table itself stays small.
Comm.ADMIT_BURST = 60
Comm.ADMIT_RATE = 2
Comm.ADMIT_SENDERS = 3000
local admit, admitCount = {}, 0
function Comm.Admit(sender, now)
	local b = admit[sender]
	if not b then
		if admitCount >= Comm.ADMIT_SENDERS then
			for name, x in pairs(admit) do
				if now - x.t > 60 then admit[name], admitCount = nil, admitCount - 1 end
			end
			if admitCount >= Comm.ADMIT_SENDERS then stats.admitted = (stats.admitted or 0) + 1 return false end
		end
		b = { tokens = Comm.ADMIT_BURST, t = now }
		admit[sender], admitCount = b, admitCount + 1
	end
	b.tokens = math.min(Comm.ADMIT_BURST, b.tokens + (now - b.t) * Comm.ADMIT_RATE)
	b.t = now
	if b.tokens < 1 then
		stats.throttled = (stats.throttled or 0) + 1
		return false
	end
	b.tokens = b.tokens - 1
	return true
end
function Comm.ResetAdmission() wipe(admit); admitCount = 0 end

-- A client outside any Sylvanistas guild (1.1): over its own guild it puts together the pieces of the
-- author's signed titles list alone (HT), which names the approved guilds (ns.IsApprovedGuild):
-- the members of such a guild have nothing else to learn it from. Nothing else is read, kept or
-- answered; a blocked sender, and one past the admission budget, are dropped as ever, and the list
-- is checked like any other (Workshop.TakeTitles: the signature, the budgets of checks).
local outsiderAsm = Codec.NewAssembler()
function Comm.Outsider(sender, text)
	if not IsInGuild() or type(text) ~= "string" or not text:match("^C%w+:") then return end
	if ns.db.blocked[sender:lower()] or not Comm.Admit(sender, ns.Now()) then return end
	stats.outsider = (stats.outsider or 0) + 1
	local full = Codec.Feed(outsiderAsm, sender, text, ns.Now())
	if full and full:sub(1, 3) == "HT~" and handlers.HT then handlers.HT("GUILD", sender, full) end
end
function Comm.ResetOutsider() outsiderAsm = Codec.NewAssembler() end -- (tests)

local function OnAddonMessage(prefix, text, dist, sender, target, zoneChannelID, localID, channelName)
	if prefix ~= ns.PREFIX then return end
	if type(sender) ~= "string" or sender == "" or type(text) ~= "string" then return end
	-- Nothing another player sends reaches a screen, a tooltip, the map, a popup or a copy box
	-- with an escape code in it (0.9.2): every message but a chat line loses its "|" and its
	-- control bytes here, before the pieces are put together or any handler reads it (a census
	-- report, a layer, a decree, the King's word, a hello...). No message of ours needs either
	-- (a bug report travels with its pipes as "!" and its line breaks as "\n"). A chat line
	-- keeps the links Codec.SanitizeChat allows, and nothing else (Channels.lua).
	if text:sub(1, 3) ~= "M1~" then text = Codec.Plain(text) end
	-- Only our channel counts: an outsider in any other channel we sit in could otherwise
	-- reach us there, past the sealed channel. Clients that don't give the number pass.
	if dist == "CHANNEL" then
		if not stats.chanArgs then
			stats.chanArgs = ("localID=%s name=%s target=%s"):format(tostring(localID), tostring(channelName), tostring(target))
		end
		if type(localID) == "number" and localID > 0 and localID ~= channelIndex then
			-- Our number may be stale (just after a /reload, or the channel moved): ask again.
			local name = joinedName or Comm.ChannelSpec()
			local id = name and GetChannelName and GetChannelName(name) or 0
			if id and id > 0 and joinedName then channelIndex = id end
			if id ~= localID then
				stats.otherChannel = stats.otherChannel + 1
				return
			end
		end
	end
	-- The sender as the server sent it: which realms get a suffix tells the realms apart.
	local lane, rawRealm = dist == "CHANNEL" and "ch" or "g", sender:match("%-(.+)$")
	Count(stats.raw[lane], rawRealm or "bare")
	local sample = stats.rawSample[lane]
	if not sample or (rawRealm and not sample:find("-", 1, true)) then stats.rawSample[lane] = sender end
	-- Same-realm senders arrive without "-Realm": make every name "Name-Realm" once, here
	-- (and Forever's "First-Surname" the server's "First Surname": ns.Normal).
	sender = ns.FullName(ns.Normal(sender))
	if sender == ns.me then
		stats.echo = stats.echo + 1 -- our own message coming back (proves the channel works)
		return
	end
	if not ns.IsMember() then
		-- Outside a Sylvanistas guild the addon hears nothing of the army, but for two things (1.1): the
		-- Join screen's answer, J2, whispered by a member it asked (Comm.WhisperOutside), and the
		-- author's signed titles list over its own guild, which may make that guild a Sylvanistas guild
		-- (Comm.Outsider).
		if dist == "WHISPER" and text:sub(1, 3) == "J2~" and outsideHandler and not ns.db.blocked[sender:lower()]
			and Comm.Admit(sender, ns.Now()) then
			ns.SafeCall("join route", outsideHandler, sender, text)
		end
		if dist == "GUILD" then Comm.Outsider(sender, text) end
		return
	end
	if ns.db.blocked[sender:lower()] then return end
	if not Comm.Admit(sender, ns.Now()) then return end
	stats.recv = stats.recv + 1
	-- Sylvanistas Link (0.9.10): a High Councillor's addon waiting to hear the author (Link.HeardFrom)
	-- sees who speaks; only while it waits: otherwise nil, and no message pays for it.
	local hook = Comm.senderHook
	if hook then ns.SafeCall("link author", hook, sender, dist) end
	local kind = (dist == "CHANNEL" and "ch:" or "g:") .. (text:match("^C%w+:") and "chunk" or text:sub(1, 2))
	Count(stats.byType, kind) -- (unknown prefixes fold into "other": a flood of them stays small)
	local now = ns.Now()
	-- Realm key, only over GUILD (server-verified guildmates) and only from our officers.
	if dist == "GUILD" and text:sub(1, 3) == "K1~" then
		local rank = ns.Roster.RankOf(sender)
		if rank and rank <= ns.CAPTAIN_RANK then
			local key = text:sub(4)
			if key ~= "" and key ~= ns.rdb.realmKey then
				-- 1.1 (Keys.lua): a key a newer one replaced here (the King's rotation, an officer's
				-- 1.1 /syl key) no longer comes back without an epoch; any other still does.
				if ns.Keys.TakesLegacy and ns.Keys.TakesLegacy(key) == false then
					ns.Log("realm key from officer %s ignored: a key a newer one replaced", sender)
				else
					ns.rdb.realmKey = key
					ns.Log("realm key received from officer %s", sender)
					Comm.JoinChannel()
				end
			end
		end
		return
	end
	if dist == "GUILD" and text:sub(1, 3) == "K0~" then
		-- A guildmate asks for the key: officers who have it answer (at most once a minute).
		if ns.rdb.realmKey and ns.Roster.IsOfficer() and now - (Comm.lastKeyAnswer or 0) > 60 then
			Comm.lastKeyAnswer = now
			ns.After(math.random(1, 5), "key answer", function()
				if not ns.rdb.realmKey then return end
				Enqueue("GUILD", "K1~" .. ns.rdb.realmKey, "key")
				-- 1.1 (Keys.lua): with its epoch too (and the keys it replaced), for 1.1 guildmates.
				local k3 = ns.Keys.HandOutMessage and ns.Keys.HandOutMessage()
				if type(k3) == "string" then Enqueue("GUILD", k3, "key3") end
			end)
		end
		return
	end
	if dist == "GUILD" and text:sub(1, 3) == "H1~" then
		if not peers[sender] then ns.Log("peer %s (%s)", sender, text:sub(4)) end
		peers[sender] = now
		-- The realm the hello names, unless the server stamped another one than ours on its sender:
		-- then the server's (1.0.0, Konig's review of 1.0.0: a guildmate's hello naming our realm
		-- from another one was elected our realm's reporter, never heard on our channel).
		local named, stamped = Codec.RealmField(text:match("^H1~[^~]*~([^~]+)")) or "old", ns.RealmOf(sender)
		if named ~= "old" and stamped and stamped ~= ns.realm then named = stamped end
		peerRealm[sender] = named
		peerVersion[sender] = text:match("^H1~(%d+%.%d+%.%d+)") or "?"
		local sealed = text:match("^H1~[^~]*~[^~]*~([^~]*)")
		peerSealed[sender] = (sealed == "s" or sealed == "p") and sealed or nil
		peerZone[sender] = text:match("^H1~[^~]*~[^~]*~[^~]*~([^~]*)") == "z" or nil
		return
	end
	local handler = handlers[text:sub(1, 2)]
	if handler and text:sub(3, 3) == "~" then
		handler(dist, sender, text)
		return
	end
	-- A piece, while the High Council's lists wait to answer an ask (1.0.0, Workshop.lua: an answer
	-- heard beginning holds ours back); nil otherwise, and no piece pays for it.
	local pieceHook = Comm.pieceHook
	if pieceHook and (dist == "GUILD" or dist == "CHANNEL") then ns.SafeCall("list piece", pieceHook, dist, sender, text) end
	-- 1.1: other modules' waiting answers the same way (Loot.lua's), each set only while it waits.
	if next(Comm.pieceHooks) ~= nil and (dist == "GUILD" or dist == "CHANNEL") then
		for key, fn in pairs(Comm.pieceHooks) do ns.SafeCall(key .. " piece", fn, dist, sender, text) end
	end
	if dist == "GUILD" then
		-- Pieces over GUILD (1.0.0): the High Council's lists cross to guildmates on other realms.
		-- Only those are put together; versions before 1.0.0 put nothing together from GUILD.
		local full = Codec.Feed(guildAsm, sender, text, now)
		local whole = full and full:sub(1, 2)
		if whole and GUILD_PIECES[whole] and full:sub(3, 3) == "~" and handlers[whole] then handlers[whole](dist, sender, full) end
		return
	end
	if dist == "CHANNEL" then
		local full = Codec.Feed(asm, sender, text, now)
		if not full then return end
		local fullHandler = handlers[full:sub(1, 2)]
		if fullHandler and full:sub(3, 3) == "~" then
			-- Put together from pieces: whether it came logged is known of the piece that ended it
			-- alone, so the whole never counts as logged (1.0.0). A chat line or a decree's words
			-- in plain pieces with an empty last piece logged were shown; no version sends either
			-- in pieces (Comm.SendChat, Comm.Send), so such a decree shows without its words and
			-- such a line is dropped (Decree.lua, Channels.lua).
			deliveredLogged = false
			fullHandler(dist, sender, full)
			return
		end
		local r = Codec.DecodeReport(full)
		if not r then
			stats.bad = stats.bad + 1
			ns.Log("bad report from %s: %s", sender, full:sub(1, 80))
			return
		end
		stats.reports = stats.reports + 1
		-- A report naming another realm: the channel may cross realms (/syl status). Its sender
		-- wrote that realm, so it never turns the election (Comm.ElectsAcrossRealms).
		Count(stats.reportRealms, r.from or "old")
		if r.from and r.from ~= ns.realm then ns.rdb.shared = { realm = r.from, to = ns.realm, t = now } end
		-- Our guild's reporter is heard: the election guard (MaybeBroadcast) leaves it in.
		local own = GetGuildInfo("player")
		if own and r.guild:lower() == own:lower() then
			local short = ns.ShortName(sender)
			heardOwn[short] = now
			for name in pairs(benched) do
				if ns.ShortName(name) == short then benched[name] = nil end
			end
			-- Sent by a guildmate of another realm: our channel crosses realms (1.0.0).
			if PeerOfOtherRealm(sender, now) then crossedAt = now end
		end
		if ns.Data.Receive(r, sender) then
			ns.Log("report %s from %s: %d members, %d online", r.guild, sender, r.total, r.online)
		end
	end
end

-- Outside a Sylvanistas guild the addon stays out of the channel (called when the guild changes).
-- Joining is left to the housekeeping ticker, so we never jump ahead of General/Trade at login.
function Comm.CheckMembership()
	if ns.IsMember() then
		-- Joined a Sylvanistas guild after login: ask for the census once we are on the channel.
		if stats.asked + stats.askSkipped == 0 then
			askTries = 0
			Comm.AskCensus()
		end
		return
	end
	if joinedName and GetChannelName(joinedName) > 0 then
		LeaveChannelByName(joinedName)
		ns.Log("left channel %s: not in a Sylvanistas guild", joinedName)
		joinedName, channelIndex = nil, 0
		wipe(queue)
		DropChat("left")
	end
end

ns.On("LOGIN", function()
	Comm.loginAt = ns.Now()
	C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
	-- No key yet? Ask our guild once (officers who have it answer).
	ns.After(20, "key request", Comm.RequestKey)
	ns.RegisterEvent("CHAT_MSG_ADDON", OnAddonMessage)
	-- Chat lines come through the logged API (the server keeps them, so they can be reported).
	ns.RegisterEvent("CHAT_MSG_ADDON_LOGGED", function(...)
		deliveredLogged = true
		local ok, err = pcall(OnAddonMessage, ...)
		deliveredLogged = false
		if not ok then error(err, 0) end
	end)
	-- Who holds our channel and what is done with it (the channel's owner, above).
	ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE", Comm.OnChannelNotice)
	ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER", Comm.OnChannelNotice)
	ns.RegisterEvent("CHANNEL_PASSWORD_REQUEST", Comm.OnPasswordRequest)
	ns.RegisterEvent("ADDON_ACTION_BLOCKED", Comm.OnActionRefused)
	ns.RegisterEvent("ADDON_ACTION_FORBIDDEN", Comm.OnActionRefused)
	ns.After(3, "join channel", function() Comm.JoinSoon(3) end)
	ns.After(6, "hello", Comm.Hello)
	ns.Every(HELLO_EVERY, "hello ticker", Comm.Hello)
	ns.Every(SEND_INTERVAL, "send pump", Pump)
	ns.Every(60, "housekeeping", function()
		local dropped, sample = Codec.Gc(asm, ns.Now())
		Codec.Gc(guildAsm, ns.Now())
		Codec.Gc(outsiderAsm, ns.Now())
		if dropped > 0 then
			stats.partial = stats.partial + dropped
			ns.Log("incomplete report dropped: %s", tostring(sample))
		end
		if channelIndex == 0 or GetChannelName(joinedName or (Comm.ChannelSpec())) == 0 then Comm.JoinChannel() end
	end)
	-- The game joins its own channels (General, Trade...) after ours on a slow login: ours
	-- moves behind them once the list settles.
	-- Only in the minutes after we joined: later changes are the player's.
	local lastPending = false
	ns.RegisterEvent("CHANNEL_UI_UPDATE", function()
		if lastPending or ns.Now() - (Comm.joinedAt or 0) > 180 then return end
		lastPending = true
		ns.After(2, "channel last", function()
			lastPending = false
			Comm.KeepLast()
		end)
	end)
end)
