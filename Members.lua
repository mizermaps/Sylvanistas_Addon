local ADDON, ns = ...
local L = ns.L

-- Our own guild's members page (1.1), in the Realm tab like the Board. Asked for by a moderator, of
-- the Dark Lady's moderators:
-- #38: the members offline 7, 14 or 30 days and more, with rank, class, level and last online,
--   from our own roster (Roster.Scan: the server's word, what the game's Guild window shows every
--   member). A player whose rank may remove members (CanGuildRemove, and only ranks below theirs,
--   as the game's own Guild window allows) removes one person per click: a question through
--   ns.ShowDialog, then the game's own call (C_GuildInfo.Uninvite) inside that click, with a short
--   gap between two removals. Nothing picks several at once: there is no kick-all.
-- #19: the Lord attaches one of his Captains to a recruit as their mentor; each gets one whisper
--   from him, naming the other, both sent by that one click of his (see Mentors, below).
-- Nothing goes on the channel, and nothing but the Lord's own mentor pairs is kept.

local Members = {}
ns.Members = Members

local Plain = ns.Codec.Plain

Members.FILTERS = { 7, 14, 30 } -- days offline
Members.PAGE = 100              -- rows shown, then a page more per click
Members.REMOVE_GAP = 3          -- seconds between two removals

local page -- nil (the Realm's tree) or { filter, shown }
local lastRemove = -math.huge
local removed = {} -- [raw name] = true: removed this session (the roster drops them at its next scan)

function Members.Shown() return page ~= nil end
function Members.Filter() return page and page.filter end
-- Which page the Realm shows, for the window's place (UI.lua): another one starts at the top.
function Members.PageId() return page and ("members:" .. tostring(page.filter)) or nil end
-- The Realm's tree again, no redraw (Views.CloseChat, another tab).
function Members.Hide() page = nil end

function Members.Show(filter)
	if ns.Views and ns.Views.CloseChat then ns.Views.CloseChat() end
	page = { filter = filter or Members.FILTERS[1], shown = Members.PAGE }
	if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end
function Members.Close()
	page = nil
	if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end

-- May we remove members at all (the game's word), and this one (a rank below ours, never the
-- guild master, never ourselves)?
function Members.CanRemove()
	return type(CanGuildRemove) == "function" and CanGuildRemove() and true or false
end
function Members.Removable(m)
	if type(m) ~= "table" or not m.raw or removed[m.raw] then return false end
	local rank = m.rankIndex
	return type(rank) == "number" and rank >= 1 and rank > ns.Roster.MyRank()
end

local function ClassName(m)
	local file = m.class and ns.CLASS_FILES[m.class]
	return file and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[file] or "", file
end

-- "45 days ago", "5h ago": the game gives years, months, days and hours (Roster.lua).
function Members.LastOnline(days)
	days = days or 0
	if days >= 1 then return L.MEMBERS_LAST_DAYS:format(math.floor(days)) end
	return L.MEMBERS_LAST_HOURS:format(math.max(0, math.floor(days * 24)))
end

-- Asked from a row's click: the question, with who, rank and how long away.
function Members.AskRemove(m)
	if not (Members.CanRemove() and Members.Removable(m)) then return nil end
	local className = ClassName(m)
	local details = L.MEMBERS_REMOVE_DETAILS:format(Plain(m.rank or "?"), m.level or 0, className, Members.LastOnline(m.days))
	return ns.ShowDialog("SYLVANISTAS_GUILD_REMOVE", Plain(m.name), details, m)
end

-- The question answered: the game removes that one member. From the player's click only.
function Members.Remove(m)
	if not (Members.CanRemove() and Members.Removable(m)) then return false end
	local now = GetTime()
	if now - lastRemove < Members.REMOVE_GAP then
		ns.Print(L.MEMBERS_REMOVE_WAIT)
		return false
	end
	local uninvite = (C_GuildInfo and C_GuildInfo.Uninvite) or GuildUninvite
	if type(uninvite) ~= "function" then return false end
	lastRemove = now
	uninvite(m.raw)
	removed[m.raw] = true
	ns.Log("members: removed %s (%s, %.1f days offline)", tostring(m.raw), tostring(m.rank), m.days or 0)
	ns.Print(L.MEMBERS_REMOVED_LINE:format(Plain(m.name)))
	ns.Roster.RequestScan(true)
	ns.Fire("DATA_CHANGED")
	return true
end

---------------------------------------------------------------------------
-- Mentors (request #19). Recruits: our guild's lowest rank, and whoever joined since our first
-- roster read this session (Classic keeps no join date). The Lord (rank 0 on his own roster)
-- clicks a recruit who is online, then one of his Captains who is online, and says yes: one
-- whisper to each (a whisper can't reach someone offline), both from that click, never the
-- addon's by itself. The pair is his client's alone (ns.rdb.mentors, kept where the client keeps
-- saves): the whispers are what the two of them keep.
---------------------------------------------------------------------------

Members.MENTOR_GAP = 2 -- seconds between two pairs (four whispers)
local lastMentor = -math.huge
local firstRoster -- { guild, names = { [raw] = true } }: the members at this session's first read
local joined = {} -- [raw] = true: in our guild since then

function Members.IsLord() return IsInGuild() and ns.Roster.MyRank() == 0 end

local function Mentors(guild)
	ns.rdb.mentors = ns.rdb.mentors or {}
	local g = guild or GetGuildInfo("player") or "?"
	ns.rdb.mentors[g] = ns.rdb.mentors[g] or {}
	return ns.rdb.mentors[g]
end
-- A recruit's mentor (the Captain's name as the roster gives it), or nil.
function Members.MentorOf(raw)
	local e = raw and Mentors()[raw]
	return type(e) == "table" and e.mentor or nil
end

-- Each roster read (Roster.TryScan): who joined since the first one, then our Lord away (#39).
function Members.OnScan(r)
	local all = ns.Roster.members or {}
	local guild = type(r) == "table" and r.guild or GetGuildInfo("player")
	if not firstRoster or firstRoster.guild ~= guild then
		firstRoster = { guild = guild, names = {} }
		wipe(joined)
		for _, m in ipairs(all) do firstRoster.names[m.raw] = true end
	else
		for _, m in ipairs(all) do
			if m.raw and not firstRoster.names[m.raw] then joined[m.raw] = true end
		end
	end
	return Members.CheckOwnLord(r)
end
function Members.Joined(raw) return joined[raw] == true end

function Members.Recruits()
	local all, lowest = ns.Roster.members or {}, -1
	for _, m in ipairs(all) do
		if (m.rankIndex or -1) > lowest then lowest = m.rankIndex end
	end
	local out = {}
	for _, m in ipairs(all) do
		if (m.rankIndex or 0) > ns.CAPTAIN_RANK and (m.rankIndex == lowest or joined[m.raw]) then out[#out + 1] = m end
	end
	table.sort(out, function(a, b)
		local ja, jb = joined[a.raw] or false, joined[b.raw] or false
		if ja ~= jb then return ja end
		local ma, mb = Members.MentorOf(a.raw) ~= nil, Members.MentorOf(b.raw) ~= nil
		if ma ~= mb then return mb end
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return out
end

-- Our guild's Captains (the rank under the Lord, ns.CAPTAIN_RANK), online first.
function Members.Captains()
	local out = {}
	for _, m in ipairs(ns.Roster.members or {}) do
		if (m.rankIndex or 0) >= 1 and m.rankIndex <= ns.CAPTAIN_RANK then out[#out + 1] = m end
	end
	table.sort(out, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return out
end

-- A recruit clicked: the Captains to pick from.
function Members.PickMentor(m)
	if not (page and Members.IsLord()) or type(m) ~= "table" then return false end
	if not m.online then
		ns.Print(L.MENTOR_OFFLINE:format(Plain(m.name)))
		return false
	end
	page.mentorFor = m
	if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
	return true
end

-- A Captain clicked: the question, naming both.
function Members.AskMentor(recruit, captain)
	if not Members.IsLord() or type(recruit) ~= "table" or type(captain) ~= "table" then return nil end
	if not captain.online then
		ns.Print(L.MENTOR_OFFLINE:format(Plain(captain.name)))
		return nil
	end
	return ns.ShowDialog("SYLVANISTAS_MENTOR", Plain(captain.name), Plain(recruit.name), { recruit = recruit, captain = captain })
end

-- The question answered: one whisper to each, from the Lord's click, and the pair kept.
function Members.AssignMentor(recruit, captain)
	if not Members.IsLord() or type(recruit) ~= "table" or type(captain) ~= "table" or not recruit.raw or not captain.raw then return false end
	if not (recruit.online and captain.online) then
		ns.Print(L.MENTOR_OFFLINE:format(Plain(recruit.online and captain.name or recruit.name)))
		return false
	end
	local now = GetTime()
	if now - lastMentor < Members.MENTOR_GAP then
		ns.Print(L.MENTOR_WAIT)
		return false
	end
	lastMentor = now
	local guild = GetGuildInfo("player") or "?"
	SendChatMessage(L.MENTOR_TO_CAPTAIN:format(Plain(recruit.name), guild), "WHISPER", nil, ns.TellName(captain.raw))
	SendChatMessage(L.MENTOR_TO_RECRUIT:format(guild, Plain(captain.name)), "WHISPER", nil, ns.TellName(recruit.raw))
	Mentors(guild)[recruit.raw] = { mentor = captain.raw, t = ns.Now() }
	ns.Log("members: %s mentors %s", tostring(captain.raw), tostring(recruit.raw))
	ns.Print(L.MENTOR_DONE:format(Plain(captain.name), Plain(recruit.name)))
	if page then page.mentorFor = nil end
	ns.Fire("DATA_CHANGED")
	if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
	return true
end

-- The recruits and mentors page (the Lord's), or the Captains to pick from.
local function MentorLines(lines, q)
	local V = ns.Views
	local r = page.mentorFor
	if r then
		lines[#lines + 1] = { header = true, text = L.MENTOR_PICK:format(Plain(r.name)) }
		lines[#lines + 1] = { text = V.Gold(L.MENTOR_PICK_CANCEL), onClick = function() page.mentorFor = nil; ns.UI.Refresh() end, gapAfter = true }
		local mentees = {}
		for _, e in pairs(Mentors()) do
			if type(e) == "table" and e.mentor then mentees[e.mentor] = (mentees[e.mentor] or 0) + 1 end
		end
		local caps = Members.Captains()
		for _, c in ipairs(caps) do
			local _, file = ClassName(c)
			lines[#lines + 1] = {
				key = c.name,
				text = V.ClassColored(c.name, file) .. "  " .. V.Grey(Plain(c.rank or "")),
				right = (c.online and V.Green(L.ONLINE_NOW) or V.Grey(Members.LastOnline(c.days))) .. "  " .. V.Grey(L.MENTOR_COUNT:format(mentees[c.raw] or 0)),
				onClick = c.online and function() Members.AskMentor(r, c) end or nil,
				tooltip = function(tt)
					tt:AddLine(Plain(c.name), 1, 0.82, 0)
					tt:AddLine(c.online and L.MENTOR_CAPTAIN_TIP:format(Plain(r.name)) or L.MENTOR_OFFLINE:format(Plain(c.name)), 1, 1, 1, true)
				end,
			}
		end
		if #caps == 0 then lines[#lines + 1] = { text = V.Grey(L.MENTOR_NO_CAPTAINS) } end
		return lines
	end
	lines[#lines + 1] = { text = V.Grey(L.MENTOR_HINT), gapAfter = true }
	local list = {}
	for _, m in ipairs(Members.Recruits()) do
		if not q or ns.Holds(q, m.name, m.rank) then list[#list + 1] = m end
	end
	local shown = math.min(#list, page.shown)
	for i = 1, shown do
		local m = list[i]
		local _, file = ClassName(m)
		local mentor = Members.MentorOf(m.raw)
		lines[#lines + 1] = {
			key = m.name,
			text = V.ClassColored(m.name, file) .. "  " .. V.Grey(Plain(m.rank or "") .. (joined[m.raw] and ("  ·  " .. L.MENTOR_NEW) or "")),
			right = (mentor and V.Gold(L.MENTOR_OF:format(Plain(ns.DisplayName(ns.FullName(ns.Normal(mentor))) or mentor))) or V.Grey(L.MENTOR_NONE))
				.. "  " .. (m.online and V.Green(L.ONLINE_NOW) or V.Grey(Members.LastOnline(m.days))),
			onClick = function() Members.PickMentor(m) end,
			tooltip = function(tt)
				tt:AddLine(Plain(m.name), 1, 0.82, 0)
				tt:AddLine(m.online and L.MENTOR_TIP or L.MENTOR_OFFLINE:format(Plain(m.name)), 1, 1, 1, true)
			end,
		}
	end
	if #list > shown then
		lines[#lines + 1] = {
			text = V.Gold(L.SHOW_MORE:format(math.min(Members.PAGE, #list - shown), shown, #list)),
			onClick = function()
				page.shown = page.shown + Members.PAGE
				ns.UI.Refresh()
			end,
		}
	end
	if #list == 0 then lines[#lines + 1] = { text = V.Grey(q and L.SEARCH_NO_MATCH or L.MENTOR_NO_RECRUITS) } end
	return lines
end

function Members.ResetForTests()
	page, lastRemove, lastMentor, firstRoster = nil, -math.huge, -math.huge, nil
	wipe(removed)
	wipe(joined)
end

local function Row(m, canRemove)
	local V = ns.Views
	local className, file = ClassName(m)
	local gone = removed[m.raw]
	local removable = canRemove and Members.Removable(m)
	local person = { name = m.name, class = m.class, level = m.level, guild = GetGuildInfo("player"), rank = m.rank, online = m.online, days = m.days }
	return {
		key = m.name,
		text = V.ClassColored(m.name, file) .. "  " .. V.Grey(Plain(m.rank or "") .. (className ~= "" and ("  ·  " .. className) or "")),
		right = V.Grey(L.LEVEL_N:format(m.level or 0) .. "  ·  " .. Members.LastOnline(m.days))
			.. (gone and ("  " .. V.Grey(L.MEMBERS_REMOVED)) or removable and ("  " .. V.Red(L.MEMBERS_REMOVE)) or ""),
		onClick = not gone and function()
			if removable then return Members.AskRemove(m) end
			ns.UI.ShowPerson(person)
		end or nil,
		tooltip = function(tt)
			tt:AddLine(Plain(m.name), 1, 0.82, 0)
			tt:AddLine(Plain(m.rank or "") .. "  ·  " .. L.LEVEL_N:format(m.level or 0) .. " " .. className, 1, 1, 1)
			tt:AddLine(L.MEMBERS_LAST:format(Members.LastOnline(m.days)), 0.8, 0.8, 0.8)
			if removable then tt:AddLine(L.MEMBERS_REMOVE_TIP, 1, 0.4, 0.4, true) end
		end,
	}
end

-- The page's lines. `q`, the Realm's search (Views.Query): the members whose name, rank or class
-- holds it.
function Members.Lines(q)
	local V = ns.Views
	local lines = { { text = V.Gold(L.MEMBERS_BACK), onClick = Members.Close, gapAfter = true } }
	local guild = GetGuildInfo("player")
	local all = ns.Roster.members or {}
	if not (guild and ns.IsFederation(guild)) or #all == 0 then
		lines[#lines + 1] = { text = V.Grey(L.MEMBERS_NONE_YET) }
		return lines
	end
	local stats = ns.Roster.lastStats or {}
	local total = math.max(stats.numTotal or 0, #all)
	local counts, offline = {}, 0
	for _, f in ipairs(Members.FILTERS) do counts[f] = 0 end
	for _, m in ipairs(all) do
		if not m.online then
			offline = offline + 1
			for _, f in ipairs(Members.FILTERS) do
				if (m.days or 0) >= f then counts[f] = counts[f] + 1 end
			end
		end
	end
	lines[#lines + 1] = {
		header = true, text = "<" .. Plain(guild) .. ">",
		right = V.Grey(L.MEMBERS_COUNTS:format(ns.FormatNumber(total), ns.FormatNumber(math.max(0, 1000 - total)), ns.FormatNumber(counts[30] or 0))),
	}
	for _, f in ipairs(Members.FILTERS) do
		local on = page.filter == f
		lines[#lines + 1] = {
			text = on and V.Gold("> " .. L.MEMBERS_FILTER:format(f)) or ("   " .. L.MEMBERS_FILTER:format(f)),
			right = V.Grey(ns.FormatNumber(counts[f])),
			onClick = not on and function() Members.Show(f) end or nil,
		}
	end
	-- The Lord's: his recruits and their mentors (#19).
	if Members.IsLord() then
		local on = page.filter == "recruits"
		lines[#lines + 1] = {
			text = on and V.Gold("> " .. L.MENTOR_FILTER) or ("   " .. L.MENTOR_FILTER),
			right = V.Grey(ns.FormatNumber(#Members.Recruits())),
			onClick = not on and function() Members.Show("recruits") end or nil,
		}
	elseif page.filter == "recruits" then
		page.filter = Members.FILTERS[1]
	end
	lines[#lines].gapAfter = true
	if page.filter == "recruits" then return MentorLines(lines, q) end
	local canRemove = Members.CanRemove()
	lines[#lines + 1] = { text = V.Grey(canRemove and L.MEMBERS_REMOVE_HINT or L.MEMBERS_VIEW_HINT) }
	-- The game lists only who is online (its "Show offline members" unticked): say so.
	if offline == 0 and total > #all then lines[#lines + 1] = { text = V.Grey(L.MEMBERS_NO_OFFLINE) } end
	lines[#lines].gapAfter = true
	local list = {}
	for _, m in ipairs(all) do
		if not m.online and (m.days or 0) >= page.filter and (not q or ns.Holds(q, m.name, m.rank, (ClassName(m)))) then list[#list + 1] = m end
	end
	table.sort(list, function(a, b)
		if (a.days or 0) ~= (b.days or 0) then return (a.days or 0) > (b.days or 0) end
		return a.name < b.name
	end)
	local shown = math.min(#list, page.shown)
	for i = 1, shown do lines[#lines + 1] = Row(list[i], canRemove) end
	if #list > shown then
		lines[#lines + 1] = {
			text = V.Gold(L.SHOW_MORE:format(math.min(Members.PAGE, #list - shown), shown, #list)),
			onClick = function()
				page.shown = page.shown + Members.PAGE
				ns.UI.Refresh()
			end,
		}
	end
	if #list == 0 then lines[#lines + 1] = { text = V.Grey(q and L.SEARCH_NO_MATCH or L.MEMBERS_NONE) } end
	return lines
end

---------------------------------------------------------------------------
-- A Lord away (1.1, request #39): one chat line when a guild's Lord crosses warnDays offline
-- (/syl warndays, 3 by default), instead of a red name in a list of twenty guilds. To our own
-- guild's officers about our Lord, from our roster (the server's word, GetGuildRosterLastOnline);
-- to the King, his Steward and his Hands (King.CanCommand) about every guild's Lord, from the
-- census (a report's leaderDays, aged by how old the report is: a guild that stopped reporting
-- is exactly the one to hear about, its Lord online in its last report included; the census's
-- word, which the line says). Once per crossing:
-- again only after that Lord came back. A line, never a popup or a sound, and nothing is done to
-- anyone: no kick, no transfer. Nothing is sent.
---------------------------------------------------------------------------

Members.LORD_LIST = 5 -- Lords named in one line to the Crown, the rest counted

function Members.WarnDays() return tonumber(ns.db and ns.db.warnDays) or 3 end

-- [guild] = the Lord we told about, while he stays away (saved where the client keeps saves).
local function Warned()
	ns.rdb.lordWarned = ns.rdb.lordWarned or {}
	return ns.rdb.lordWarned
end

-- Our Lord, from the roster just read (Roster.Scan's report `r`): officers only, not the Lord.
function Members.CheckOwnLord(r)
	if type(r) ~= "table" or not r.leader or not ns.IsFederation(r.guild) then return false end
	local warned, key = Warned(), "own:" .. r.guild
	local days = r.leaderOnline and 0 or (r.leaderDays or 0)
	if days < Members.WarnDays() then
		warned[key] = nil
		return false
	end
	local rank = ns.Roster.MyRank()
	if rank < 1 or rank > ns.CAPTAIN_RANK or warned[key] == r.leader then return false end
	warned[key] = r.leader
	ns.Print(L.LORD_AWAY_OWN:format(Plain(r.leader), math.floor(days), Members.WarnDays()))
	ns.Log("lord away: our Lord %s, %.1f days", tostring(r.leader), days)
	return true
end

-- Every other guild's Lord, from the census, for the Crown. Returns how many were named.
function Members.CheckLords(now)
	now = now or ns.Now()
	if not (ns.King and ns.King.CanCommand and ns.King.CanCommand()) then return 0 end
	local loginAt = ns.Comm and ns.Comm.loginAt
	if loginAt and now - loginAt < ns.Data.CROWN_AFTER then return 0 end -- the census rebuilding
	local warned, own, crossed = Warned(), GetGuildInfo("player"), {}
	for name, g in pairs(ns.rdb.guilds or {}) do
		local age = now - (type(g) == "table" and g.t or 0)
		if type(g) == "table" and not g.mine and name ~= own and g.leader and age <= ns.Data.KEEP and ns.IsFederation(name) then
			-- Away since the report said so, and for as long as the report is old. A Lord the report
			-- showed online counts from then once his guild stops reporting (older than FRESH): in a
			-- guild where only he runs the addon, every report says he is online.
			local stale = age > ns.Data.FRESH
			local days = (g.leaderOnline and 0 or (g.leaderDays or 0)) + ((stale or not g.leaderOnline) and math.max(0, age) / 86400 or 0)
			if days < Members.WarnDays() then
				warned[name] = nil
			elseif warned[name] ~= g.leader then
				warned[name] = g.leader
				crossed[#crossed + 1] = { guild = name, lord = g.leader, days = days }
			end
		end
	end
	if #crossed == 0 then return 0 end
	table.sort(crossed, function(a, b)
		if a.days ~= b.days then return a.days > b.days end
		return a.guild < b.guild
	end)
	if #crossed == 1 then
		local c = crossed[1]
		ns.Print(L.LORD_AWAY_CROWN:format(Plain(c.lord), Plain(c.guild), math.floor(c.days)))
	else
		local parts = {}
		for i = 1, math.min(#crossed, Members.LORD_LIST) do
			local c = crossed[i]
			parts[#parts + 1] = L.LORD_AWAY_ENTRY:format(Plain(c.lord), Plain(c.guild), math.floor(c.days))
		end
		local more = #crossed > Members.LORD_LIST and (" " .. L.LORD_AWAY_MORE:format(#crossed - Members.LORD_LIST)) or ""
		ns.Print(L.LORD_AWAY_CROWN_MANY:format(#crossed, Members.WarnDays(), table.concat(parts, ", ")) .. more)
	end
	ns.Log("lord away: %d Lords past %d days", #crossed, Members.WarnDays())
	return #crossed
end

-- /syl warndays <n>: when a Lord or Captain counts as away (their name turns red, and the line).
function Members.SetWarnDays(text)
	local n = tonumber(text)
	if not n or n < 1 or n > 60 or n ~= math.floor(n) then
		ns.Print(L.WARNDAYS_USAGE:format(Members.WarnDays()))
		return false
	end
	ns.db.warnDays = n
	ns.Print(L.WARNDAYS_SET:format(n))
	ns.Fire("DATA_CHANGED")
	return true
end

ns.On("LOGIN", function()
	ns.Every(60, "lords away", function() Members.CheckLords() end)
end)

StaticPopupDialogs["SYLVANISTAS_MENTOR"] = {
	text = L.MENTOR_CONFIRM,
	button1 = L.MENTOR_SEND,
	button2 = CANCEL or "Cancel",
	OnAccept = function(self, data)
		data = data or (self and self.data)
		if type(data) == "table" then ns.SafeCall("mentor", Members.AssignMentor, data.recruit, data.captain) end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs["SYLVANISTAS_GUILD_REMOVE"] = {
	text = L.MEMBERS_REMOVE_CONFIRM,
	button1 = L.MEMBERS_REMOVE,
	button2 = CANCEL or "Cancel",
	OnAccept = function(self, data) ns.SafeCall("guild remove", Members.Remove, data or (self and self.data)) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	showAlert = true,
	preferredIndex = 3,
}
