local ADDON, ns = ...
local L = ns.L

-- The King's acts that show outside the Throne, where they belong:
--   Royal Writs (Decrees tab): a letter to the Lords (the Crown), or to the Lords and
--     Captains, on parchment. Each one can acknowledge it; the King sees how many did.
--   Open the Gates (Realm tab, Recruiting): the guild the army should send new recruits to,
--     for two hours. The King or a Hand opens them.
--   Royal Pardon (Tabards tab, Wall of Shame): a name off the wall, for everyone, for a week.
--   T1~W~<id>~<guild>~<L|C>~<text>               a writ (the King's)
--   T6~<id>~<guild>                               acknowledged (whisper to the King)
--   T1~G~<id>~<guild>~<seconds left>~<guild to join>   gates open (empty guild: closed)
--   T1~F~<id>~<guild>~<name>                      pardon (the King's)

local Acts = {}
ns.Acts = Acts

Acts.WRIT_GAP = 60          -- one writ a minute (the King's)
Acts.WRIT_SHOW_GAP = 45     -- a little less on the receiving side (queues, rounding)
Acts.WRIT_MAX = 200         -- letters
Acts.WRITS_KEPT = 20
Acts.GATES_TIME = 2 * 3600  -- gates stay open this long
Acts.GATES_RESEND = 600
Acts.PARDON_DAYS = 7
Acts.PARDON_RESEND = 600    -- the King's client repeats the week's pardons for late logins
Acts.NEWS_GAP = 60          -- gates news in chat once a minute at most
Acts.MAX_ACKS = 300

local function Clean(s, n) return ns.Cut((tostring(s or ""):gsub("[~|%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")), n) end

local function Store(key)
	ns.rdb[key] = ns.rdb[key] or {}
	return ns.rdb[key]
end
-- For reading only: nothing is saved for a player who never got a writ.
local function Read(key) return ns.rdb[key] or {} end

---------------------------------------------------------------------------
-- Royal Writs
---------------------------------------------------------------------------

local lastWritSent, lastWritShown = -math.huge, -math.huge
local writFrame

-- Who reads a writ: "L" the Lords (guild masters, and the officers of <Sylvanistas>), "C" every
-- Lord and Captain, "E" the whole army (every member; it is not acknowledged: thousands of
-- whispers to the King).
Acts.AUDIENCES = { L = "WRIT_TO_LORDS", C = "WRIT_TO_ALL", E = "WRIT_TO_EVERYONE" }
function Acts.Audience(to) return L[Acts.AUDIENCES[to] or "WRIT_TO_LORDS"] end
function Acts.WritFor(to)
	if not ns.IsMember() then return false end
	if to == "E" then return true end
	if to == "L" then return ns.IsCrown() end
	return ns.Roster.MyRank() <= ns.CAPTAIN_RANK
end

local function MakeWritFrame()
	local f = CreateFrame("Frame", "SylvanistasWritFrame", UIParent)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetSize(360, 300)
	f:SetPoint("CENTER", 0, 60)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	local okBorder, border = pcall(CreateFrame, "Frame", nil, f, "DialogBorderTemplate")
	if okBorder and border then border:SetAllPoints() end
	local bg = f:CreateTexture(nil, "BACKGROUND")
	bg:SetPoint("TOPLEFT", 10, -10)
	bg:SetPoint("BOTTOMRIGHT", -10, 10)
	local file = ns.UI.FirstTexture(ns.UI.PARCHMENTS)
	if GetFileIDFromPath and not GetFileIDFromPath(file) then
		bg:SetColorTexture(0.87, 0.80, 0.64, 0.97)
	else
		bg:SetTexture(file)
		if file:find("QuestBG", 1, true) then bg:SetTexCoord(0, 296 / 512, 0, 331 / 512) end
	end
	f.title = f:CreateFontString(nil, "ARTWORK", _G.QuestTitleFont and "QuestTitleFont" or "GameFontNormalLarge")
	f.title:SetPoint("TOP", 0, -26)
	f.to = f:CreateFontString(nil, "ARTWORK", _G.QuestFont and "QuestFont" or "GameFontHighlight")
	f.to:SetPoint("TOP", f.title, "BOTTOM", 0, -6)
	f.body = f:CreateFontString(nil, "ARTWORK", _G.QuestFont and "QuestFont" or "GameFontHighlight")
	f.body:SetPoint("TOPLEFT", 30, -80)
	f.body:SetPoint("RIGHT", -30, 0)
	f.body:SetJustifyH("LEFT")
	f.body:SetJustifyV("TOP")
	f.sign = f:CreateFontString(nil, "ARTWORK", _G.QuestFont and "QuestFont" or "GameFontHighlight")
	f.sign:SetPoint("BOTTOMRIGHT", -30, 56)
	f.ack = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.ack:SetSize(140, 24)
	f.ack:SetPoint("BOTTOM", 0, 22)
	f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	f.close:SetPoint("TOPRIGHT", -4, -4)
	f.close:SetScript("OnClick", function() f:Hide() end)
	ns.EscapeCloses("SylvanistasWritFrame")
	return f
end

local function Ack(w)
	if w.acked then return end
	w.acked = true
	if w.king and w.king ~= ns.me then
		ns.Comm.Whisper(w.king, ("T6~%d~%s"):format(w.id, GetGuildInfo("player") or ""), "writ ack")
	end
	ns.Fire("DECREES_CHANGED")
end

-- The writ on parchment (again from the Decrees tab).
function Acts.ShowWrit(w)
	writFrame = writFrame or MakeWritFrame()
	local f = writFrame
	f.title:SetText(L.WRIT_TITLE)
	f.to:SetText(Acts.Audience(w.to))
	f.body:SetText(w.text)
	f.sign:SetText(L.WRIT_SIGNED:format(w.by or ns.KingName()))
	f.ack:SetText(w.acked and L.WRIT_ACKED or L.WRIT_ACK)
	f.ack:SetEnabled(not w.acked and not w.mine)
	f.ack:SetShown(not w.mine and w.to ~= "E")
	f.ack:SetScript("OnClick", function()
		ns.SafeCall("writ ack", Ack, w)
		f:Hide()
	end)
	f:Show()
end

function Acts.SendWrit(to, text)
	local preview = ns.King.Preview()
	if not ns.King.IsKing() and not preview then return ns.Print(L.THRONE_ONLY_KING) end
	text = Clean(text, Acts.WRIT_MAX)
	if #text < 3 then return ns.Print(L.WRIT_EMPTY) end
	to = Acts.AUDIENCES[to] and to or "L"
	local now = ns.Now()
	if not preview and now - lastWritSent < Acts.WRIT_GAP then
		return ns.Print(L.THRONE_WAIT:format(math.ceil(Acts.WRIT_GAP - (now - lastWritSent))))
	end
	lastWritSent = now
	local w = { id = ns.King.NewId(), to = to, text = text, t = now, by = ns.KingName(ns.me), mine = true, acks = 0 }
	local sent = Store("writsSent")
	sent[#sent + 1] = w
	while #sent > Acts.WRITS_KEPT do table.remove(sent, 1) end
	if preview then
		ns.Print(L.THRONE_PREVIEW_NOTE)
	else
		ns.Comm.Send("CHANNEL", ("T1~W~%d~%s~%s~%s"):format(w.id, GetGuildInfo("player") or "", to, text), "writ")
	end
	ns.Print(L.WRIT_SENT:format(Acts.Audience(to)))
	Acts.ShowWrit(w)
	ns.Fire("DECREES_CHANGED")
end

local function OnWrit(sender, id, rest)
	local to, text = rest:match("^([LCE])~(.+)$")
	if not to or not Acts.WritFor(to) then return end
	text = Clean(text, Acts.WRIT_MAX)
	if #text < 3 then return end
	local now = ns.Now()
	if now - lastWritShown < Acts.WRIT_SHOW_GAP then return end
	lastWritShown = now
	for _, old in ipairs(Read("writs")) do if old.id == id and old.king == ns.FullName(sender) then return end end
	local list = Store("writs")
	local w = { id = id, king = ns.FullName(sender), by = ns.KingName(sender), to = to, text = text, t = now }
	-- 1.1 (#31): a writ the player's block terms hit stays folded: no parchment, no alert, and
	-- the Decrees tab offers it to read with a click (Filter.lua). His own terms alone: the shared
	-- list never hides the King's writs (1.1, review).
	local F = ns.Filter
	if F and not F.missing and F.Hides(text, true) then w.hidden = true end
	list[#list + 1] = w
	while #list > Acts.WRITS_KEPT do table.remove(list, 1) end
	if not w.hidden then
		-- In an instance or on Busy (1.1): the chat line and its line on the Decrees tab now, the
		-- parchment once the player is out, if still unread.
		ns.King.Warn(L.WRIT_ARRIVED:format(w.by), false, "throne", {
			what = L.HELD_WRIT:format(w.by), key = "writ:" .. tostring(w.id), -- (each writ its own: two unread both pop)
			open = function() return not w.acked end,
			show = function() Acts.ShowWrit(w) end,
		})
	end
	ns.Fire("DECREES_CHANGED")
end
ns.King.Register("W", OnWrit)

function Acts.HandleAck(dist, sender, text)
	if dist ~= "WHISPER" or not ns.King.IsKing() then return end
	local id, guild = text:match("^T6~(%d+)~(.*)$")
	id = tonumber(id)
	guild = ns.King.CleanGuild(guild)
	if not id or not guild then return end
	sender = ns.FullName(sender)
	-- Only someone the writ was for: a Lord or Captain the census (or our roster) confirms,
	-- and a Lord of the Crown for a writ to the Lords.
	local rank = ns.Roster.RankOf(sender) or ns.Data.KnownRank(sender, guild)
	if rank == nil or rank > ns.CAPTAIN_RANK then return end
	for _, w in ipairs(Read("writsSent")) do
		if w.id == id and ns.Now() - w.t < 86400 then
			if w.to == "E" then return end -- (not acknowledged)
			if w.to == "L" and not ns.IsCrownRank(guild, rank) then return end
			w.ackBy = w.ackBy or {}
			if w.ackBy[sender] or (w.acks or 0) >= Acts.MAX_ACKS then return end
			w.ackBy[sender] = true
			w.acks = (w.acks or 0) + 1
			return ns.Fire("DECREES_CHANGED")
		end
	end
end
ns.Comm.Handle("T6", function(...) Acts.HandleAck(...) end)

-- Writs the player's block terms hid and a click showed, this session (1.1, #31).
local revealed = setmetatable({}, { __mode = "k" })

-- The Decrees tab's section: the writs we got, or the King's own with how many read them.
-- Nothing for anyone else.
function Acts.WritLines()
	local lines = {}
	local mine = ns.King.IsKing() or ns.King.Preview()
	local list = mine and Read("writsSent") or Read("writs")
	if not mine and #list == 0 then return lines end
	lines[#lines + 1] = { header = true, text = L.WRITS }
	if #list == 0 then lines[#lines + 1] = { text = "|cff9d9d9d" .. L.WRITS_NONE .. "|r" } end
	for i = #list, math.max(1, #list - 4), -1 do
		local w = list[i]
		local head = Acts.Audience(w.to)
		-- 1.1 (#31): hidden by the player's block terms (not revealed this session).
		local veiled = w.hidden and not revealed[w]
		local state = ""
		if mine and w.to ~= "E" then state = "|cff40ff40" .. L.WRIT_ACKS:format(w.acks or 0) .. "|r  "
		elseif not mine and not w.acked and w.to ~= "E" then state = "|cffffd200" .. L.WRIT_UNREAD .. "|r  " end
		lines[#lines + 1] = {
			text = "|cffffd200" .. head .. "|r  " .. (mine and "" or ("|cff9d9d9d" .. L.WRIT_FROM:format(w.by or "?") .. "|r")),
			right = state .. "|cff9d9d9d" .. ns.Ago(w.t) .. "|r",
			onClick = function()
				revealed[w] = true
				Acts.ShowWrit(w)
				ns.Fire("DECREES_CHANGED")
			end,
			tooltip = function(tt)
				tt:AddLine(L.WRIT_TITLE, 1, 0.82, 0)
				tt:AddLine(veiled and L.FILTER_WRIT_HIDDEN or w.text, 1, 1, 1, true)
			end,
		}
		lines[#lines + 1] = { indent = 1, text = veiled and ("|cff9d9d9d" .. L.FILTER_WRIT_HIDDEN .. "|r")
			or ('|cff9d9d9d"' .. (#w.text > 70 and (ns.Cut(w.text, 67) .. "...") or w.text) .. '"|r') }
	end
	lines[#lines].gapAfter = true
	return lines
end

-- The writ: its words, then who receives it (three audiences: a second popup, the first has
-- Cancel). Escape on the second sends nothing (noCancelOnEscape); its middle button is one of
-- the three, so only a click counts (the reason), never a timeout.
local function WritNext(text)
	text = Clean(text, Acts.WRIT_MAX)
	if #text < 3 then return ns.Print(L.WRIT_EMPTY) end
	ns.ShowDialog("SYLVANISTAS_WRIT_TO", nil, nil, text)
end
StaticPopupDialogs["SYLVANISTAS_WRIT"] = {
	text = L.WRIT_PROMPT,
	button1 = L.WRIT_NEXT,
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 320,
	maxLetters = 200,
	OnShow = function(self)
		local eb = self.editBox or self.EditBox
		if eb then eb:SetText(""); eb:SetFocus() end
	end,
	OnAccept = function(self)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("writ", WritNext, eb and eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		ns.SafeCall("writ", WritNext, self:GetText())
		parent:Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
StaticPopupDialogs["SYLVANISTAS_WRIT_TO"] = {
	text = L.WRIT_TO_PROMPT,
	button1 = L.WRIT_BTN_LORDS,
	button2 = L.WRIT_BTN_ALL,
	button3 = L.WRIT_BTN_EVERYONE,
	OnAccept = function(self, text) ns.SafeCall("writ", Acts.SendWrit, "L", text or (self and self.data)) end,
	OnCancel = function(self, text, reason)
		if reason == "clicked" then ns.SafeCall("writ", Acts.SendWrit, "C", text or (self and self.data)) end
	end,
	OnAlt = function(self, text) ns.SafeCall("writ", Acts.SendWrit, "E", text or (self and self.data)) end,
	noCancelOnEscape = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

function Acts.WritPrompt() ns.ShowDialog("SYLVANISTAS_WRIT") end

---------------------------------------------------------------------------
-- Open the Gates
---------------------------------------------------------------------------

local gates                 -- { id, guild, by, at, mine, sentAt }
local lastNews = -math.huge

function Acts.Gates()
	if gates and ns.Now() > gates.at then gates = nil end
	return gates
end

local function SendGates()
	if not gates or not gates.mine or gates.preview then return end
	gates.sentAt = ns.Now()
	ns.Comm.Send("CHANNEL", ("T1~G~%d~%s~%d~%s"):format(gates.id, GetGuildInfo("player") or "",
		math.max(0, math.floor(gates.at - ns.Now())), gates.guild), "gates")
end

function Acts.OpenGates(guild)
	local preview = ns.King.Preview()
	if not ns.King.CanCommand() and not preview then return ns.Print(L.THRONE_ONLY_KING) end
	guild = ns.King.CleanGuild(guild)
	if not guild then return end
	gates = { id = ns.King.NewId(), guild = guild, by = ns.me, at = ns.Now() + Acts.GATES_TIME, mine = true, preview = preview or nil }
	if preview then ns.Print(L.THRONE_PREVIEW_NOTE) end
	-- Kept across a /reload: the opener's client repeats them for late logins.
	if not preview then
		ns.rdb.gates = { id = gates.id, guild = guild, at = gates.at }
		-- 1.1 (#12): our own act never comes back to us: in our log as we send it.
		ns.Chronicle.Add("gates", ns.me, L.ACTS_GATES_OPEN:format(guild), { key = "gates", value = gates.id .. ":" .. guild })
	end
	SendGates()
	ns.Print(L.GATES_OPENED:format(guild))
	ns.Fire("DATA_CHANGED")
end

-- Whoever opened them, or the King, closes them for everyone.
function Acts.CanClose()
	local g = Acts.Gates()
	return g ~= nil and (g.mine or g.by == ns.me or ns.King.IsKing())
end

function Acts.CloseGates()
	if not gates then return end
	if not Acts.CanClose() then return ns.Print(L.GATES_ONLY_OPENER) end
	if not gates.preview then
		ns.Comm.Send("CHANNEL", ("T1~G~%d~%s~0~"):format(gates.id, GetGuildInfo("player") or ""), "gates")
		ns.Chronicle.Add("gates", ns.me, L.ACTS_GATES_CLOSED, { key = "gates", value = "closed" })
	end
	gates = nil
	ns.rdb.gates = nil
	ns.Print(L.GATES_CLOSED)
	ns.Fire("DATA_CHANGED")
end

local function OnGates(sender, id, rest, guild)
	local seconds, target = rest:match("^(%d+)~(.*)$")
	seconds = tonumber(seconds)
	if not seconds then return end
	sender = ns.FullName(sender)
	local king = ns.King.FromKing(sender, guild)
	if target == "" or seconds <= 0 then
		-- Closed: by whoever opened them, or by the King (ours too, when we opened them).
		if gates and (gates.by == sender or king) then
			if gates.mine then ns.rdb.gates = nil end
			gates = nil
			-- 1.1 (#12): in this client's log of acts, with the name the server stamped.
			ns.Chronicle.Add("gates", sender, L.ACTS_GATES_CLOSED, { key = "gates", value = "closed" })
			ns.Fire("DATA_CHANGED")
		end
		return
	end
	target = ns.King.CleanGuild(target)
	if not target then return end
	local fresh = not gates or gates.id ~= id
	gates = { id = id, guild = target, by = sender, at = ns.Now() + math.min(seconds, Acts.GATES_TIME) }
	-- 1.1 (#12): in this client's log of acts, once per opening (repeated every 10 minutes).
	ns.Chronicle.Add("gates", sender, L.ACTS_GATES_OPEN:format(target), { key = "gates", value = id .. ":" .. target })
	-- In chat once a minute at most, whatever arrives.
	local now = ns.Now()
	if fresh and now - lastNews >= Acts.NEWS_GAP then
		lastNews = now
		ns.Print(L.GATES_NEWS:format(king and ns.KingName(sender) or ns.DisplayName(sender), target))
	end
	ns.Fire("DATA_CHANGED")
end
ns.King.Register("G", OnGates)

StaticPopupDialogs["SYLVANISTAS_GATES"] = {
	text = L.GATES_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function(self, data) ns.SafeCall("gates", Acts.OpenGates, data or (self and self.data)) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
-- The same, for a guild whose census row is marked (1.1, request #30): what the mark says, so the
-- gates never open on a size nobody else confirms without the King seeing it.
StaticPopupDialogs["SYLVANISTAS_GATES_MARKED"] = {
	text = L.GATES_CONFIRM_MARKED,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function(self, data) ns.SafeCall("gates", Acts.OpenGates, data or (self and self.data)) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
StaticPopupDialogs["SYLVANISTAS_GATES_CLOSE"] = {
	text = L.GATES_CLOSE_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function() ns.SafeCall("gates", Acts.CloseGates) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- A guild's line in Recruiting, clicked: the King and his Hands open (or close) its gates.
function Acts.GatesClick(guild)
	if not ns.King.CanCommand() and not ns.King.Preview() then return end
	local g = Acts.Gates()
	if g and g.guild == guild then
		if not Acts.CanClose() then return ns.Print(L.GATES_ONLY_OPENER) end
		return ns.ShowDialog("SYLVANISTAS_GATES_CLOSE", guild)
	end
	local marked = ns.Views and ns.Views.DisputeLines and ns.Views.DisputeLines(ns.Data.Dispute(ns.Data.Guild(guild)))
	if marked then return ns.ShowDialog("SYLVANISTAS_GATES_MARKED", guild, table.concat(marked, " "), guild) end
	ns.ShowDialog("SYLVANISTAS_GATES", guild, nil, guild)
end

---------------------------------------------------------------------------
-- Royal Pardon
---------------------------------------------------------------------------

local function Pardons()
	local p = Store("pardons")
	local now = ns.Now()
	for name, t in pairs(p) do
		if now - t > Acts.PARDON_DAYS * 86400 then p[name] = nil end
	end
	return p
end

function Acts.Pardoned(name)
	return name ~= nil and Pardons()[ns.ShortName(name):lower()] ~= nil
end

local function Apply(name)
	local short = ns.ShortName(name)
	Pardons()[short:lower()] = ns.Now()
	local shame = ns.Inspect.Shame()
	if shame and shame.list then
		for i = #shame.list, 1, -1 do
			if ns.ShortName(shame.list[i].name):lower() == short:lower() then table.remove(shame.list, i) end
		end
	end
	ns.Fire("INSPECT_CHANGED")
end

-- The King's pardons of the week, in one message (as many names as fit): sent at once, then
-- repeated for whoever logs in later.
local function SendPardons()
	local given = ns.rdb.pardonsGiven
	if not given or not ns.King.IsKing() then return end
	local now, names, len = ns.Now(), {}, 0
	for name, t in pairs(given) do
		if now - t > Acts.PARDON_DAYS * 86400 then
			given[name] = nil
		elseif len + #name + 1 <= 200 then
			names[#names + 1] = name
			len = len + #name + 1
		end
	end
	if #names == 0 then return end
	table.sort(names)
	ns.Comm.Send("CHANNEL", ("T1~F~%d~%s~%s"):format(ns.King.NewId(), GetGuildInfo("player") or "", table.concat(names, ",")), "pardons")
end

function Acts.Pardon(name)
	local preview = ns.King.Preview()
	if not ns.King.IsKing() and not preview then return ns.Print(L.THRONE_ONLY_KING) end
	local short = ns.King.CleanName(name)
	if not short then return ns.Print(L.PARDON_BAD_NAME) end
	if not preview then
		ns.rdb.pardonsGiven = ns.rdb.pardonsGiven or {}
		ns.rdb.pardonsGiven[short] = ns.Now()
		SendPardons()
		-- 1.1 (#12): our own act never comes back to us: in our log as we send it.
		ns.Chronicle.Add("pardon", ns.me, L.ACTS_PARDON:format(short))
	else
		ns.Print(L.THRONE_PREVIEW_NOTE)
	end
	Apply(short)
	ns.Print(L.PARDON_DONE:format(short))
end

local function OnPardon(sender, id, rest)
	local n = 0
	for name in tostring(rest or ""):gmatch("[^,]+") do
		local short = ns.King.CleanName(name)
		n = n + 1
		if n > 30 then break end
		if short and not Acts.Pardoned(short) then
			Apply(short)
			-- 1.1 (#12): in this client's log of acts, with the name the server stamped.
			ns.Chronicle.Add("pardon", sender, L.ACTS_PARDON:format(short))
			ns.Print("|cffffd200" .. L.PARDON_NEWS:format(ns.KingName(sender), short) .. "|r")
		end
	end
end
ns.King.Register("F", OnPardon)

StaticPopupDialogs["SYLVANISTAS_PARDON"] = {
	text = L.PARDON_CONFIRM,
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function(self, data) ns.SafeCall("pardon", Acts.Pardon, data or (self and self.data)) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

ns.On("LOGIN", function()
	-- Our own gates from before a /reload, while they last.
	local kept = ns.rdb and ns.rdb.gates
	if type(kept) == "table" and tonumber(kept.at) and kept.at > ns.Now() and ns.King.CleanGuild(kept.guild) then
		gates = { id = tonumber(kept.id) or ns.King.NewId(), guild = kept.guild, by = ns.me, at = kept.at, mine = true }
	elseif ns.rdb then
		ns.rdb.gates = nil
	end
	local lastPardons = ns.Now()
	ns.Every(60, "gates", function()
		local g = gates
		if g and ns.Now() > g.at then
			gates = nil
			if g.mine then ns.rdb.gates = nil end
			return ns.Fire("DATA_CHANGED")
		end
		-- Only while we may still command (a Hand no longer named stops repeating them).
		if g and g.mine and ns.King.CanCommand() and ns.Now() - (g.sentAt or 0) >= Acts.GATES_RESEND then SendGates() end
		if ns.Now() - lastPardons >= Acts.PARDON_RESEND then
			lastPardons = ns.Now()
			SendPardons()
		end
	end)
end)

-- Tests start from a clean state.
function Acts.Reset()
	gates, lastNews = nil, -math.huge
	lastWritSent, lastWritShown = -math.huge, -math.huge
	-- (The tests rebuild the interface between runs: a frame whose global is gone is made again.)
	if writFrame and rawget(_G, "SylvanistasWritFrame") ~= writFrame then writFrame = nil elseif writFrame then writFrame:Hide() end
end
