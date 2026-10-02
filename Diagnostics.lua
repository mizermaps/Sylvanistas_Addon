local ADDON, ns = ...
local L = ns.L

-- Everything that goes wrong is stored in SylvanistasDB.errors (deduplicated, with stack and count)
-- and SylvanistasDB.log. Both live in WTF/Account/<ACCOUNT>/SavedVariables/Sylvanistas.lua, which WoW
-- writes on /reload or logout, so a developer can read it straight from disk.
-- Players without disk access use /syl bug, which opens a copyable report.

local MAX_ERRORS = 50
local warnedThisSession = false

local function ClientInfo()
	local version, build, _, toc = GetBuildInfo()
	return ("%s (%s) toc %s, locale %s"):format(tostring(version), tostring(build), tostring(toc), tostring(GetLocale()))
end

function ns.CaptureError(where, err)
	local db = ns.db
	local msg = tostring(err)
	local stack = debugstack and debugstack(3, 12, 0) or ""
	if not db then
		print("|cffff4040Sylvanistas error (before load):|r " .. msg)
		return
	end
	local key = where .. "|" .. msg
	for _, e in ipairs(db.errors) do
		if e.key == key then
			e.count = e.count + 1
			e.last = date("%Y-%m-%d %H:%M:%S")
			return
		end
	end
	table.insert(db.errors, {
		key = key,
		where = where,
		msg = msg,
		stack = stack,
		count = 1,
		first = date("%Y-%m-%d %H:%M:%S"),
		last = date("%Y-%m-%d %H:%M:%S"),
		version = ns.VERSION,
		client = ClientInfo(),
	})
	while #db.errors > MAX_ERRORS do table.remove(db.errors, 1) end
	ns.Log("ERROR in %s: %s", where, msg)
	if not warnedThisSession then
		warnedThisSession = true
		-- (With the gamepad UI not "type /syl bug": a command typed there can set off a block.)
		ns.Print("|cffff4040" .. (ns.GamepadUI() and L.ERROR_CAUGHT_GAMEPAD or L.ERROR_CAUGHT) .. "|r")
	end
end

-- Errors raised while loading (before SavedVariables existed) were kept by Bootstrap.lua.
ns.On("INIT", function()
	for _, e in ipairs(ns.earlyErrors or {}) do ns.CaptureError("load", e[1]) end
	ns.earlyErrors = {}
	-- Only Sylvanistas's own errors are kept (0.9.2, Bootstrap.lua): the saved list of an older
	-- version, with every other addon's in it, is replaced, and nothing of theirs stays.
	local all = ns.allErrors or {}
	for i = #all, 1, -1 do
		local e = all[i]
		if type(e) ~= "table" or not (ns.OwnError and ns.OwnError(e.msg, e.stack)) then table.remove(all, i) end
	end
	ns.allErrors, ns.db.allErrors = all, all -- same table: errors seen later this session are saved too
end)

-- What Blizzard's gamepad UI reads on its way to the calls only it may make (0.9.8), from its
-- own code on Forever 1.60: the interact button's target (Blizzard_GamepadActionBars/
-- MainActionBarFrame.lua, UpdateInteractIcons -> SetPreferredGamepadInteractTarget), the binding
-- stack it asks first (Blizzard_GamepadSharedUtility/InputBindingStack/InputBindingManager.lua),
-- the frames and popups it follows (FrameControlsManager.lua, Blizzard_StaticPopup/
-- StaticPopupGamepad.lua), the escape list its menus sweep (CloseSpecialWindows) and the chat box
-- it focuses (an addon's slash command runs inside the chat box's own code: ChatFrameEditBox.lua).
-- A value an addon wrote there makes the game blame that addon when the call comes;
-- issecurevariable says which values, and whose.
local PROBE_GLOBALS = {
	"GamepadSharedUtility", "GamepadMode", "GamepadMainActionBarFrame", "SmartNavigation", "InputUtil",
	"EventRegistry", "RunNextFrame", "GenerateClosure", "C_Timer", "C_Spell", "SetPreferredGamepadInteractTarget",
	"SetUnitCursorTexture", "UnitExists", "UnitIsGameObject", "UnitHasLootInteraction", "UnitIsInInteractRange",
	"UnitIsInteractable", "UnitCanAttack", "UISpecialFrames", "CloseSpecialWindows", "CloseAllWindows",
	"ShowUIPanel", "HideUIPanel", "StaticPopup_Show", "StaticPopup_Hide", "ACTIVE_CHAT_EDIT_BOX", "LAST_ACTIVE_CHAT_EDIT_BOX",
}
-- label, the object (nil when this client has none), its fields, and the field that is a list
-- whose slots are read one by one.
local PROBE_OBJECTS = {
	{ "binding stack", function() return type(GamepadSharedUtility) == "table" and GamepadSharedUtility.InputBindingManager end,
		{ "bindingSetStack", "currentCoreBindingActive", "assumeCoreBindingsUsable", "coreSet", "coreBindingListenerFunctions" }, "bindingSetStack" },
	{ "frame controls", function() return type(GamepadMode) == "table" and GamepadMode.FrameControlsManager end,
		{ "shownFrames", "focusedFrame", "isUIFocused", "fallThroughCatcherActive", "topSuspendedFrame" }, "shownFrames" },
	{ "gamepad popups", function() return type(GamepadMode) == "table" and GamepadMode.PopupHandler end,
		{ "visiblePopups", "activePopup" }, "visiblePopups" },
	{ "action bar", function() return GamepadMainActionBarFrame end, { "PageUnit", "autoLootOnTap" } },
	{ "smart navigation", function() return SmartNavigation end, { "currentButton", "activeInfo" } },
}
local PROBE_SLOTS = 20 -- slots of a list read at most (one past its end too: a slot emptied)

-- One line: the values above an addon wrote, and whose, or that none was.
function ns.TaintProbe()
	if type(issecurevariable) ~= "function" then return "taint: not checked (no issecurevariable)" end
	local found, checked = {}, 0
	local function Check(label, t, key)
		local ok, secure, by
		if t == nil then ok, secure, by = pcall(issecurevariable, key) else ok, secure, by = pcall(issecurevariable, t, key) end
		if not ok then return end
		checked = checked + 1
		if not secure then found[#found + 1] = label .. " by " .. tostring(by or "?") end
	end
	local function Slots(label, list)
		if type(list) ~= "table" then return end
		for i = 1, math.min(#list + 1, PROBE_SLOTS) do
			local v = list[i]
			Check(("%s[%d]%s"):format(label, i, type(v) == "string" and ("=" .. v) or ""), list, i)
			if type(v) == "table" and label == "bindingSetStack" then
				Check(("%s[%d].treatBindsAsCore"):format(label, i), v, "treatBindsAsCore")
			end
		end
	end
	for _, name in ipairs(PROBE_GLOBALS) do Check(name, nil, name) end
	for _, o in ipairs(PROBE_OBJECTS) do
		local ok, t = pcall(o[2])
		if ok and type(t) == "table" then
			for _, key in ipairs(o[3]) do Check(o[1] .. "." .. key, t, key) end
			if o[4] then Slots(o[4], rawget(t, o[4])) end
		end
	end
	Slots("UISpecialFrames", UISpecialFrames)
	if #found == 0 then return ("taint: none of %d values the gamepad UI reads"):format(checked) end
	local shown = {}
	for i = 1, math.min(8, #found) do shown[i] = found[i] end
	return ("taint: %s%s (%d checked)"):format(table.concat(shown, ", "), #found > 8 and (", +" .. (#found - 8)) or "", checked)
end

-- Blocked protected calls (taint) are not Lua errors, so they are kept apart. The first ones
-- logged with where they came from (the handler runs inside the blocked call); a burst
-- (Blizzard's gamepad UI repeats a block on every popup) counted, not logged line by line.
-- Each blocked call of ours is also kept (0.9.8) in SylvanistasDB.actionsBlocked, once per call
-- with a count: the call the game refused, the stack it was refused in and what the taint
-- probe saw, all in /syl bug. With the gamepad UI one line in chat, once a session, asks the
-- player for that report: there it is the only way to learn what the game refused.
local MAX_BLOCKED = 10
local blocked, toldGamepad = 0, false
function ns.ResetBlocked() blocked, toldGamepad = 0, false end -- tests

-- Kept once per call; the first time it comes in a session its stack and probe are taken
-- again (and it moves to the end, the newest), so the report shows this version's evidence.
local function RecordBlocked(event, func)
	local db = ns.db
	if not db then return end
	db.actionsBlocked = type(db.actionsBlocked) == "table" and db.actionsBlocked or {}
	local list, key, now = db.actionsBlocked, event .. "|" .. func, date("%Y-%m-%d %H:%M:%S")
	local b
	for i, e in ipairs(list) do
		if e.key == key then
			e.count, e.last = (e.count or 0) + 1, now
			if e.session == db.sessions then return end
			b = table.remove(list, i)
			break
		end
	end
	local stack = ""
	if type(debugstack) == "function" then
		local ok, s = pcall(debugstack, 2, 24, 6)
		stack = ok and type(s) == "string" and s or ""
	end
	local okProbe, taint = pcall(ns.TaintProbe)
	b = b or { key = key, event = event, func = func, count = 1, first = now, last = now }
	b.session, b.version, b.client, b.gamepad, b.stack = db.sessions, ns.VERSION, ClientInfo(), ns.GamepadUI(), stack
	b.taint = okProbe and taint or ("taint: probe failed: " .. tostring(taint))
	list[#list + 1] = b
	while #list > MAX_BLOCKED do table.remove(list, 1) end
end

for _, event in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
	ns.RegisterEvent(event, function(addon, func)
		-- Another addon's: logged as always.
		if addon ~= ADDON then return ns.Log("%s: %s tried %s", event, tostring(addon), tostring(func)) end
		blocked = blocked + 1
		if blocked <= 3 then
			local stack = debugstack and debugstack(2, 12, 0) or ""
			ns.Log("%s: %s tried %s | %s", event, tostring(addon), tostring(func), (stack:gsub("\n", " < ")))
		elseif blocked <= 10 or blocked % 100 == 0 then
			ns.Log("%s: %s tried %s (%d this session)", event, tostring(addon), tostring(func), blocked)
		end
		RecordBlocked(event, tostring(func))
		if ns.GamepadUI() and not toldGamepad then
			toldGamepad = true
			ns.Print("|cffff4040" .. L.BLOCKED_GAMEPAD .. "|r")
		end
	end)
end

-- "a=3 b=1", sorted by key, for small count tables.
local function CountList(t)
	local keys, out = {}, {}
	for k in pairs(t or {}) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for i, k in ipairs(keys) do out[i] = tostring(k) .. "=" .. tostring(t[k]) end
	return #out > 0 and table.concat(out, " ") or "none"
end

-- fn(...) for an API some clients lack: nil when it is missing or fails.
local function Try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if ok then return v end
	return nil
end

-- Everything that tells two realms apart, to settle whether PvP and PvP 2 share anything.
-- Short lines here and below: they have to be readable in the /syl bug window.
local function RealmLines()
	local guid = Try(UnitGUID, "player")
	local serverID = type(guid) == "string" and guid:match("^Player%-(%d+)%-") or nil
	local guild, _, _, guildRealm = GetGuildInfo("player")
	-- Connected realms, other than ours. The global GetAutoCompleteRealms only exists with
	-- Blizzard's deprecation fallbacks on, so its "none" meant nothing.
	local auto = Try(C_AutoComplete and C_AutoComplete.GetAutoCompleteRealms)
	local linked = "n/a"
	if type(auto) == "table" then
		local others = {}
		for _, name in ipairs(auto) do
			name = tostring(name):gsub("[%s%-]", "")
			if name ~= ns.realm then others[#others + 1] = name end
		end
		linked = #others > 0 and table.concat(others, ",", 1, math.min(#others, 2)) .. (#others > 2 and (",+" .. (#others - 2)) or "") or "none"
	end
	local unique = Try(RegionalUniqueNamesEnabled)
	return ("realm: %s = %s  id=%s native=%s guid=%s  guild home=%s"):format(
			tostring(Try(GetRealmName)), tostring(ns.realm), tostring(Try(GetRealmID)), tostring(Try(GetNativeRealmID)),
			tostring(serverID), guild and tostring(guildRealm or "ours") or "-"),
		("census: %s (%s)  unique names=%s  connected=%s"):format(
			tostring(ns.group), ns.GroupSource and ns.GroupSource(ns.realm) or "?", unique == nil and "?" or tostring(unique), linked)
end

-- "[name]" as the server sent it, or "-" when there is none.
local function Sample(name)
	return name and ("[" .. name .. "]") or "-"
end

-- Names as the server sent them, before ns.FullName gives bare names our realm: the only
-- counts that can tell a guildmate on the other realm from one on ours. One short line each.
local function NamesLines(c)
	local R, raw, samples = ns.Roster, c.raw or {}, c.rawSample or {}
	local whoNames, whoSuffix, whoSample
	if ns.Who and ns.Who.RawCounts then whoNames, whoSuffix, whoSample = ns.Who.RawCounts() end
	return {
		("names raw: roster %s  e.g. %s"):format(CountList(R and R.rawRealms), Sample(R and R.rawSample)),
		("names raw: roster by server (GUID) %s"):format(CountList(R and R.servers)),
		("names raw: ch %s  e.g. %s"):format(CountList(raw.ch), Sample(samples.ch)),
		("names raw: g %s  e.g. %s"):format(CountList(raw.g), Sample(samples.g)),
		("names raw: who %s guild-suffix=%d  e.g. %s"):format(CountList(whoNames), whoSuffix or 0, Sample(whoSample)),
	}
end

-- "ClassicBetaPvP,ClassicBetaPvP2", two realms named at most (then "+n"), or "-".
local function RealmList(list)
	if type(list) ~= "table" or #list == 0 then return "-" end
	return table.concat(list, ",", 1, math.min(#list, 2)) .. (#list > 2 and (",+" .. (#list - 2)) or "")
end

-- Does the channel cross realms (a report sent from another realm reached us), where do our
-- guildmates with the addon play, and is our guild's reporter heard?
local function TopologyLines(c)
	local shared = type(c.shared) == "table" and c.shared
	return {
		shared and ("topology: channel SHARED (%s -> %s, %s)"):format(tostring(shared.realm), tostring(shared.to), ns.Ago(shared.t))
			or "topology: channel shared: not seen yet",
		("topology: reports by realm %s"):format(CountList(c.reportRealms)),
		("topology: guild peers by realm %s"):format(CountList(c.peerRealms)),
		("topology: own guild's report heard from %s"):format(c.heardOwn and (c.heardOwn .. " " .. ns.Ago(c.heardOwnAt)) or "nobody yet"),
		("topology: left out of the election: %s"):format(c.benched and #c.benched > 0 and table.concat(c.benched, ", ") or "none"),
		-- 1.0.0: a reporter per realm (or one for all while the channel is shared), and what our
		-- own report says of our guild's realms (fields 25-27).
		("topology: reporter elected on %s  |  quiet after %s before us"):format(
			c.electAll and "every realm (channel shared)" or "this realm", tostring(c.quietAfter or "?")),
		("topology: guild on %s  |  report st=%s cap=%s pres=%s"):format(RealmList(c.presence), tostring(c.reportSt or "-"),
			tostring(c.reportCap or "-"), type(c.reportPres) == "table" and #c.reportPres > 0 and table.concat(c.reportPres, ".", 1, math.min(#c.reportPres, 4)) or "-"),
	}
end

-- How many players are in our channel, when the client knows (it may not until asked).
local function ChannelMembers(name)
	if not name or not GetNumDisplayChannels or not GetChannelDisplayInfo then return nil end
	local ok, n = pcall(function()
		for i = 1, GetNumDisplayChannels() do
			local cname, _, _, _, count = GetChannelDisplayInfo(i)
			if cname == name then return count end
		end
	end)
	return ok and n or nil
end

function ns.StatusText()
	local lines = {}
	local function add(fmt, ...) lines[#lines + 1] = fmt:format(...) end
	local guild = GetGuildInfo("player")
	add("Sylvanistas v%s  |  %s", ns.VERSION, ClientInfo())
	-- (1.1) The addon's language: the game's, when Sylvanistas has lines for it (Locales.lua).
	add("language: %s", ns.LocaleReport and ns.LocaleReport() or "?")
	add("player %s  |  %s  |  guild %s  |  sylvanistas member: %s", tostring(ns.me), tostring(ns.faction), tostring(guild), tostring(ns.IsMember()))
	local realm, census = RealmLines()
	add("%s", realm)
	add("%s", census)
	local st = ns.Roster and ns.Roster.lastStats
	if st then
		add("roster: total=%s online=%s rowsRead=%d offlineRows=%d leader=%s (%s) zones=%d scanMs=%.1f %s",
			tostring(st.numTotal), tostring(st.numOnline), st.seen, st.seenOffline, tostring(st.leader),
			st.leaderOnline and "online" or "offline", st.zones, st.ms or 0, ns.Ago(st.t))
	else
		add("roster: not scanned yet")
	end
	local c = ns.Comm and ns.Comm.Stats()
	if c then
		add("channel '%s' = #%s  sealed=%s  |  peers in guild=%d  |  reporter=%s (me: %s)", tostring(c.channelName), tostring(c.channel), tostring(c.sealed), c.peers, tostring(c.reporter), tostring(c.isReporter))
		add("sent=%d recv=%d reports=%d sendFails=%d badMsgs=%d queue=%d lastFail=%s", c.sent, c.recv, c.reports, c.fails, c.bad, c.queue, tostring(c.lastFail))
		local types = {}
		for k, v in pairs(c.byType or {}) do types[#types + 1] = k .. "=" .. v end
		table.sort(types)
		add("received by type: %s  |  incomplete reports: %d waiting, %d dropped", #types > 0 and table.concat(types, " ") or "none", c.pending or 0, c.partial or 0)
		add("own echoes: %d  |  channel members: %s", c.echo or 0, tostring(ChannelMembers(c.channelName) or "unknown"))
		-- Who holds the channel as last seen, our seat on it, and what its owners did (Comm.lua).
		local o = c.guard
		if o then
			add("channel owner: %s (%s)  |  me: %s  |  watched: %s", tostring(o.owner or "unknown"),
				o.ownerAt and ns.Ago(o.ownerAt) or "not seen", o.role, tostring(o.watched))
			add("channel seen: %s  |  moderation=%s announce=%s", CountList(o.seen), tostring(o.moderation or "?"), tostring(o.announce or "?"))
			add("channel undo: password=%s banned=%d muted=%d  |  locked: %s", tostring(o.password), o.banned, o.muted,
				o.locked and ("%s, %d tries, next in %ds"):format(tostring(o.locked.why), o.locked.tries, o.locked.nextIn) or "no")
		end
		-- The chat channels by number: ours should come after the game's own (Comm.KeepLast).
		local ok, list = pcall(function() return { GetChannelList() } end)
		if ok and list and #list > 0 then
			local stride = type(list[3]) == "boolean" and 3 or 2
			local parts = {}
			for i = 1, #list, stride do parts[#parts + 1] = ("%s %s"):format(tostring(list[i]), tostring(list[i + 1])) end
			add("chat channels: %s", table.concat(parts, ", "))
		end
		add("other channels dropped: %d  |  census asked %d (left out %d), answered %d  |  runner-up: %s  |  first channel msg: %s",
			c.otherChannel or 0, c.asked or 0, c.askSkipped or 0, c.answered or 0, tostring(c.runnerUp), tostring(c.chanArgs))
		for _, line in ipairs(NamesLines(c)) do add("%s", line) end
		for _, line in ipairs(TopologyLines(c)) do add("%s", line) end
		local ch = ns.Channels and ns.Channels.Stats()
		if ch then
			-- (moved, 1.1.1: lines not sent because the channel changed before they left, GitHub #34.)
			add("chat: sent=%d shown=%d hidden=%d lane=%d moved=%d muted=%s drops bad=%d dup=%d rate=%d flood=%d forged=%d unverified=%d rank=%d",
				ch.sent, ch.shown, ch.hidden, c.chatQueue or 0, ch.moved or 0, #ch.muted > 0 and table.concat(ch.muted, ",") or "none",
				ch.bad, ch.dup, ch.rate, ch.flood, ch.forged, ch.unverified, ch.rank)
			if ns.Channels.WindowStatus then add("chat windows: %s", ns.Channels.WindowStatus()) end
			-- (1.1) The pinned line this client holds: whose, of what rank, and how long it has left.
			if ns.Channels.PinStatus then add("pinned line: %s", ns.Channels.PinStatus()) end
		end
		-- What leaves this client about where the player is, and who reads the channel (0.9.1).
		add("privacy: zone and layer %s  |  channel %s  |  chat warning accepted: %s",
			ns.Layers and ns.Layers.SharingState and ns.Layers.SharingState() or "?", c.sealed and "sealed (key holders)" or "public (anyone)",
			ch and ch.warned and #ch.warned > 0 and table.concat(ch.warned, ",") or "none")
		if ns.Treasury and ns.Treasury.RealKeeper and ns.Treasury.RealKeeper() then
			local v = ns.Treasury.Consent()
			local b = ns.Treasury.BookOf and ns.Treasury.BookOf(ns.me)
			add("treasury keeper: book and bank %s (/syl treasurer on|off), book of %s opened at %s copper",
				v == true and "shared" or (v == false and "private" or "not chosen (private)"), tostring(b and b.epoch or "-"), tostring(b and b.opening or "-"))
		end
		if ns.faction == "Horde" then
			add("Horde Heir: %s, realm %s", tostring(ns.KING_CHARACTER.Horde), tostring(ns.KingRealm and ns.KingRealm() or "?"))
		end
		-- (1.1, Fern's #11: each off until answered, on the first-open page or its command.)
		local ri = ns.db.royalInspection
		add("royal inspection: %s (/syl inspection on|off)", ri == true and "taking part when sampled" or (ri == false and "not taking part" or "not chosen (not taking part)"))
		-- 1.1 (Fern's #29): an officer's findings shared with his guild's officers.
		if ns.Inspect.MayShare then
			add("patrol share: %s (/syl patrolshare on|off), %d of our officers' findings held", not ns.Inspect.Sharing() and "off"
				or (ns.Inspect.MayShare() and "on" or "on, not an officer"), ns.Inspect.SharedCount())
		end
		-- 1.1: the switch for all alert sounds, and the kinds silenced on their own.
		add("alerts: %s", ns.AlertStatus and ns.AlertStatus() or "?")
		add("author's roll call: %s (/syl rollcall on|off)", ns.Workshop and ns.Workshop.AnswerState and ns.Workshop.AnswerState() or "?")
		-- (1.1) The author's released version as his presence named it, and whether this client is behind it.
		add("%s", ns.Workshop and ns.Workshop.VersionLine and ns.Workshop.VersionLine() or "author's released version: ?")
		-- (1.1.2) The right-click menus' lines, and this session's version checks and asks.
		add("player menus: %s  |  versions: %s", ns.PlayerMenu and ns.PlayerMenu.StatusLine and ns.PlayerMenu.StatusLine() or "not loaded",
			ns.Versions and ns.Versions.StatusLine and ns.Versions.StatusLine() or "not loaded")
		add("sylvanistas chats: %s (/syl chat on|off)  |  layer help: %s", ns.Channels and ns.Channels.ChatState and ns.Channels.ChatState() or "?",
			ns.db.layerHelp == true and "on" or (ns.db.layerHelp == false and "off" or "not chosen (off)"))
		-- (1.1: block terms, #31; the log of acts, #12: counts only, never the words or the entries.)
		local F = ns.Filter
		if F and not F.missing and F.Mine then
			add("block terms: %d yours, %d shared (%s)%s  |  acts log: %d entries", #F.Mine(), #F.SharedTerms(), F.SharedOn() and "used" or "ignored",
				F.CanEdit() and ", you edit the shared list" or "", ns.Chronicle and ns.Chronicle.Entries and #ns.Chronicle.Entries() or 0)
		end
		-- Sylvanistas Link (0.9.10): the key's id and tier only, never the key.
		add("discord link: %s", ns.Link and ns.Link.StatusLine and ns.Link.StatusLine() or "not loaded")
		-- The Board (1.1): what this client holds and sends (the ch:G1, ch:G0, ch:GQ counts above).
		add("board: %s", ns.Board and ns.Board.StatusLine and ns.Board.StatusLine() or "not loaded")
		add("the Heir's week: %s", ns.Week and ns.Week.StatusLine and ns.Week.StatusLine() or "not loaded")
	end
	local n = 0
	for _ in pairs(ns.rdb.guilds) do n = n + 1 end
	add("cached guilds=%d  |  map=%s  |  errors=%d  |  sessions=%d", n, tostring(ns.db.showMap), #ns.db.errors, ns.db.sessions or 0)
	add("map lib: %s  |  zones indexed=%d  |  tabs: %s", tostring(ns.Map and ns.Map.libOk), ns.Zones and ns.Zones.Count() or 0,
		ns.UI and ns.UI.tabTemplate and (ns.UI.tabTemplate .. " (" .. tostring(ns.UI.tabStyle) .. " spacing), window "
			.. tostring(ns.UI.WindowStyle and ns.UI.WindowStyle())) or "not built")
	-- (1.1) Zone names from the roster no map id matched, names only: a zone a new client added
	-- somewhere the index does not reach yet, shown as text in the census and left off the map.
	add("zones without a map id: %s", ns.Zones and ns.Zones.UnmappedLine and ns.Zones.UnmappedLine() or "?")
	-- Old Guild tab or new Communities window: which ones exist and got the Sylvanistas button.
	add("guild UI: %s", ns.GuildFrameHook and ns.GuildFrameHook.StatusLine() or "not loaded")
	local seen = 0
	for _ in pairs(ns.rdb.seen or {}) do seen = seen + 1 end
	add("who: %s  |  guilds seen=%d", ns.Who and ns.Who.StatusLine() or "not loaded", seen)
	add("hop: %s", ns.Hop and ns.Hop.StatusLine and ns.Hop.StatusLine() or "not loaded")
	-- (1.0.0) The King as this client knows him: why his layer can or can't be asked for.
	add("king: %s", ns.Hop and ns.Hop.KingStatusLine and ns.Hop.KingStatusLine() or "not loaded")
	-- (1.0.0) The King's Steward as the signed titles list names him here, and the Hands held.
	add("steward: %s", ns.King and ns.King.StewardStatusLine and ns.King.StewardStatusLine() or "not loaded")
	-- (1.1) Net-off words this client holds (Moderation.lua).
	add("net-off: %s", ns.Moderation and ns.Moderation.StatusLine and ns.Moderation.StatusLine() or "not loaded")
	add("alt links: %s", ns.Alts and ns.Alts.StatusLine and ns.Alts.StatusLine() or "not loaded")
	add("realm key: %s", ns.Keys and ns.Keys.StatusLine and ns.Keys.StatusLine() or "not loaded")
	-- 1.1: the guilds the author's signed list makes Sylvanistas guilds (our faction's), and whether ours is one.
	if ns.ApprovedGuilds then
		local list, guild = ns.ApprovedGuilds(), GetGuildInfo("player")
		add("approved guilds: %s%s", #list > 0 and table.concat(list, ", ") or "none", (guild and ns.IsApprovedGuild(guild))
			and (ns.NamedSylvanistas(guild) and "  |  ours is on it" or "  |  ours is Sylvanistas by the list alone") or "")
	end
	add("borders: %s", ns.Borders and ns.Borders.StatusLine and ns.Borders.StatusLine() or "not loaded")
	add("nameplates: %s", ns.Nameplates and ns.Nameplates.StatusLine and ns.Nameplates.StatusLine() or "not loaded")
	-- The gamepad UI and what the game refused us this session; what its code reads, as now.
	local refused = type(ns.db.actionsBlocked) == "table" and ns.db.actionsBlocked or {}
	add("gamepad UI: %s  |  blocked this session: %d  |  blocked calls kept: %d%s", ns.GamepadUI() and "on" or "off", blocked, #refused,
		#refused > 0 and (" (last: %s)"):format(tostring(refused[#refused].func)) or "")
	if ns.GamepadUI() or blocked > 0 then
		local ok, line = pcall(ns.TaintProbe)
		add("%s", ok and line or ("taint: probe failed: " .. tostring(line)))
	end
	return table.concat(lines, "\n")
end

function ns.BuildBugReport()
	local out = { "```" }
	-- The calls the game refused Sylvanistas ("blocked from an action"), newest first. First in the
	-- report: a report sent in game stops at Workshop.BUG_MAX bytes, and this is the part that
	-- names what to fix.
	local refused = type(ns.db.actionsBlocked) == "table" and ns.db.actionsBlocked or {}
	if #refused > 0 then
		out[#out + 1] = "Blocked by the game:"
		-- This version's newest two, their stacks cut to 8 lines: the errors below must still fit.
		local shown = 0
		for i = #refused, 1, -1 do
			local b = refused[i]
			if shown >= 2 then break end
			if b.version == ns.VERSION then
				shown = shown + 1
				out[#out + 1] = ("[%dx] %s %s  (%s .. %s, v%s, %s)"):format(b.count or 1, tostring(b.event), tostring(b.func),
					tostring(b.first), tostring(b.last), tostring(b.version), b.gamepad and "gamepad UI" or "mouse and keyboard")
				if b.taint then out[#out + 1] = "  " .. b.taint end
				local n = 0
				for line in tostring(b.stack or ""):gmatch("[^\n]+") do
					n = n + 1
					if n > 8 then break end
					out[#out + 1] = "    " .. line
				end
			end
		end
		out[#out + 1] = ""
	end
	out[#out + 1] = ns.StatusText()
	out[#out + 1] = ""
	local errors = ns.db.errors
	if #errors == 0 then
		out[#out + 1] = "No errors recorded."
	else
		for i = #errors, math.max(1, #errors - 4), -1 do
			local e = errors[i]
			out[#out + 1] = ("[%dx] %s  (%s .. %s, v%s)"):format(e.count, e.where, e.first, e.last, e.version)
			out[#out + 1] = "  " .. e.msg
			for line in (e.stack or ""):gmatch("[^\n]+") do out[#out + 1] = "    " .. line end
		end
	end
	local all = ns.allErrors or {}
	if #all > 0 then
		out[#out + 1] = ""
		out[#out + 1] = "All errors this session:"
		for i = 1, math.min(6, #all) do out[#out + 1] = ("  [%dx] %s"):format(all[i].count, all[i].msg) end
	end
	out[#out + 1] = ""
	out[#out + 1] = "Last log lines:"
	local log = ns.db.log
	for i = math.max(1, #log - 25), #log do out[#out + 1] = "  " .. log[i] end
	out[#out + 1] = "```"
	return table.concat(out, "\n")
end

function ns.PrintLayer()
	local guid = UnitGUID("target") or UnitGUID("mouseover")
	if not guid then
		ns.Print("target an NPC first")
		return
	end
	local parts = {}
	for p in guid:gmatch("[^%-]+") do parts[#parts + 1] = p end
	if parts[1] ~= "Creature" and parts[1] ~= "Vehicle" then
		ns.Print("not an NPC: " .. guid)
		return
	end
	-- Creature-0-serverID-instanceID-zoneUID-npcID-spawnUID; zoneUID is what layer addons key on.
	ns.Print(("GUID %s  |  server %s  instance %s  zoneUID %s  npc %s"):format(guid, tostring(parts[3]), tostring(parts[4]), tostring(parts[5]), tostring(parts[6])))
	ns.Log("layer probe %s", guid)
end
