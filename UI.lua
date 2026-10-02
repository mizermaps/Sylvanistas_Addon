local ADDON, ns = ...
local L = ns.L

-- The Sylvanistas window mirrors Blizzard's (old) Guild window: same size and frame, a header,
-- column titles, a list, a detail box (like "Guild Message of the Day"), three buttons
-- and tabs along the bottom. Opened from the guild window (the old Guild tab or the new
-- Guild & Communities window, see GuildFrame.lua) it docks right next to it, so it reads
-- as a continuation of that window. Created on first open.
--
-- Two looks, each its own frame, picked again on every open (no /reload): "old" is the
-- window above, next to the old Guild window (Classic Era, Anniversary, ClassicUI Forever's
-- Guild tab). "hd" mirrors Forever's Guild & Communities window: the same metal frame,
-- icon tabs on the right side, 20 px rows, Blizzard's column headers, buttons and member
-- card. The old one is built exactly as it always was.
-- The Chat tab (1.1.1) is drawn by ChatWindow.lua over the list's place: the search box where
-- the header's counts are (the channels' switch and the settings' gear at that row's end), the
-- lines over the list, its column titles' row and the detail box, and a box to write in across
-- the buttons' row (UI.ChatPlaces).

local UI = {}
ns.UI = UI

local DEFAULT_W, DEFAULT_H = 338, 424
local DETAIL_H = 78
local HD_TABS_W, PANEL_GAP = 32, 32 -- RightSideTab.xml (32 wide); UIPanelLayoutFrame.lua PANEl_SPACING_X
local HD_TABS_REACH = 40            -- a side tab and its art, past the window's right edge
local SIDE_TOP, SIDE_GAP = 36, 20   -- CommunitiesFrame.xml: the first side tab 36 down, then 20 apart
local SIDE_ART_BELOW = 21           -- RightSideTab.xml: a side tab's art, below its button
local SIDE_LEFT_UP = 46             -- the one on the left edge: its art as far from the bottom as theirs from the top
-- The side tabs that go to the left edge when the right one runs out of room, first to last
-- (1.1.1, the author's ask: the Chat tab makes the King's column one too many).
local SIDE_LEFT_ORDER = { "workshop", "treasury" }
local HD_DEFAULT_H = 426            -- CommunitiesFrame.xml
local main                          -- the window in use: frames.old or frames.hd
local frames = {}                   -- style -> window, each created on first use
local personFrames = {}             -- style -> person details panel (created on first use, further below)

-- icon: the side tab's (HD window), a texture or a function giving one. A new tab is one
-- entry here, its L.TAB_ label and, if it has any, its BUTTONS.
local TABS = {
	{ key = "census", label = "TAB_CENSUS", icon = "Interface\\Icons\\achievement_guildperk_havegroup willtravel" },
	-- The Realm's banner is the faction's: the Horde's red one on a Horde character.
	{ key = "realm", label = "TAB_REALM", icon = function()
		local faction = ns.faction or (UnitFactionGroup and UnitFactionGroup("player"))
		return faction == "Horde" and "Interface\\Icons\\INV_BannerPVP_01" or "Interface\\Icons\\INV_BannerPVP_02"
	end },
	-- 1.1.1: the Sylvanistas chats (ChatWindow.lua), for every member: the Guild & Communities window's
	-- own chat icon (CommunitiesFrame.xml's ChatTab), else a note.
	{ key = "chat", label = "TAB_CHAT", icon = function() return UI.FirstTexture(UI.CHAT_ICONS) end },
	{ key = "decrees", label = "TAB_DECREES", icon = "Interface\\Icons\\INV_Scroll_04" },
	{ key = "heraldry", label = "TAB_HERALDRY", icon = "Interface\\Icons\\INV_Shirt_GuildTabard_01" },
	-- The King's alone (King.lua): hidden for everyone else, see UI.Refresh.
	{ key = "throne", label = "TAB_THRONE", icon = function() return UI.FirstTexture(UI.CROWNS) end },
	-- The King's and his Hands' questions to the army (Vox.lua), the same way.
	{ key = "vox", label = "TAB_VOX", icon = function() return UI.FirstTexture(UI.HORNS) end },
	-- The treasury: its keepers' books together (Treasury.lua), the same way.
	{ key = "treasury", label = "TAB_TREASURY", icon = "Interface\\Icons\\INV_Misc_Coin_02" },
	-- The addon author's alone (Workshop.lua), the same way.
	{ key = "workshop", label = "TAB_WORKSHOP", icon = "Interface\\Icons\\Trade_Engineering" },
}

-- The first of these files the client has (GetFileIDFromPath), or the last one.
function UI.FirstTexture(paths)
	for _, p in ipairs(paths) do
		if not GetFileIDFromPath or GetFileIDFromPath(p) then return p end
	end
	return paths[#paths]
end
UI.CROWNS = { "Interface\\Icons\\INV_Crown_01", "Interface\\Icons\\INV_Crown_02", "Interface\\Icons\\INV_Misc_Head_Dragon_01" }
UI.HORNS = { "Interface\\Icons\\Ability_Warrior_BattleShout", "Interface\\Icons\\INV_Misc_Horn_01" }
UI.CHAT_ICONS = { "Interface\\Icons\\UI_Chat", "Interface\\Icons\\INV_Misc_Note_01" }
UI.PARCHMENTS = { "Interface\\QuestFrame\\QuestBG", "Interface\\Stationery\\StationeryTest1" }
UI.TABS = TABS

local function DecreeAction(kind)
	return function()
		if ns.Decree.CanSend(kind) then
			ns.ShowDialog("SYLVANISTAS_DECREE", ns.Decree.Label({ kind = kind }), nil, kind)
		else
			ns.Print(ns.Decree.CROWN_ONLY[kind] and L.CROWN_PREVIEW_NOTE or L.DECREE_PREVIEW_NOTE)
			ns.Decree.Preview(kind)
		end
	end
end

-- Three buttons per tab, like "Guild Information / Add Member / Guild Control".
local BUTTONS = {
	census = {
		{ "COPY_BTN", function() UI.ShowCopy(L.COPY_DISCORD, ns.Data.DiscordText()) end },
		-- Our roster, and one /who (a click is needed for it) for the Sylvanistas guilds nobody
		-- reports: they show in grey. Each click searches further (see Who.lua).
		{ "REFRESH", function()
			ns.Roster.RequestScan(true)
			ns.Print(L.REFRESHING)
			ns.Who.Search()
		end },
		{ "REPORT_BUG", function() UI.ShowBugReport() end },
	},
	realm = {
		{ "EXPAND_ALL", function() ns.Views.ExpandAll(true); UI.Refresh() end },
		{ "COLLAPSE_ALL", function() ns.Views.ExpandAll(false); UI.Refresh() end },
		{ "COPY_BTN", function() UI.ShowCopy(L.COPY_DISCORD, ns.Data.DiscordText()) end },
	},
	decrees = {
		{ "ARMS_BTN", DecreeAction("ARMS") },
		{ "MUSTER_BTN", DecreeAction("MUSTER") },
		{ "ROYAL_BTN", DecreeAction("ROYAL") },
	},
	heraldry = {
		{ "PATROL_BTN", function() ns.Inspect.SetPatrol(not ns.Inspect.IsPatrolling()) end },
		{ "MARK_TARGET", function() ns.Inspect.MarkTarget() end },
		{ "COPY_BTN", function() UI.ShowCopy(L.INSPECT_TITLE, ns.Inspect.DiscordText()) end },
	},
	-- The Throne: the agenda (the King and his Hands), the court (the King's).
	-- The roll call lives in the Realm, the inspection in the Tabards (King.RollCallLines...).
	throne = {
		{ "THRONE_AGENDA", function() ns.King.AgendaPrompt() end },
		{ "COURT_BTN", function() ns.Court.Toggle() end, refresh = true, shown = function() return ns.King.IsKing() or ns.King.Preview() end,
			label = function() return ns.Court.Holding() and L.COURT_BTN_CLOSE or L.COURT_BTN_OPEN end,
			tooltip = function(tt)
				tt:AddLine(L.COURT_TITLE, 1, 0.82, 0)
				tt:AddLine(L.COURT_BTN_TIP, 1, 1, 1, true)
			end },
	},
	vox = {
		{ "VOX_NEW", function() ns.Vox.Prompt() end },
		{ "VOX_END", function() ns.Vox.CloseNow() end },
		{ "VOX_SHOW", function() ns.Vox.ShowLive() end },
	},
	-- The Treasury: the book (whoever may see it), a keeper's own opening balance, a copy.
	treasury = {
		{ "TREASURY_BOOK_BTN", function() ns.Treasury.Show(ns.Treasury.mode == "book" and "summary" or "book") end, refresh = true,
			shown = function() return ns.Treasury.MaySee("book") end,
			label = function() return ns.Treasury.mode == "book" and L.TREASURY_SUMMARY_BTN or L.TREASURY_BOOK_BTN end,
			tooltip = function(tt)
				local book = ns.Treasury.mode == "book"
				tt:AddLine(book and L.TREASURY_SUMMARY_BTN or L.TREASURY_BOOK_BTN, 1, 0.82, 0)
				tt:AddLine(book and ns.Treasury.SummaryTip() or L.TREASURY_BOOK_BTN_TIP, 1, 1, 1, true)
			end },
		{ "TREASURY_OPENING_BTN", function() ns.ShowDialog("SYLVANISTAS_TREASURY_OPENING") end,
			shown = function() return ns.Treasury.IsKeeper() end },
		{ "COPY_BTN", function() UI.ShowCopy(L.TREASURY_TITLE, ns.Treasury.DiscordText()) end,
			shown = function() return ns.Treasury.Role() ~= "member" end },
	},
	workshop = {
		{ "WORKSHOP_ROLL_BTN", function() ns.Workshop.RollCall() end },
		{ "WORKSHOP_ASK_BTN", function() ns.Workshop.AskOutdated() end },
		{ "COPY_BTN", function() UI.ShowCopy(L.TAB_WORKSHOP, ns.Workshop.ReportText()) end },
	},
}

-- Buttons shown to players who are not in a Sylvanistas guild.
local RECRUIT_BUTTONS = {
	{ "RECRUIT_FIND", function() ns.Recruit.Search() end },
	{ "RECRUIT_NEXT", function() ns.Recruit.PromptNext(ns.Recruit.lastContact and ns.Recruit.lastContact.guild) end },
}

-- Small extra buttons inside the detail box (only where needed).
local function KingOnly() return ns.King.IsKing() or ns.King.Preview() end
-- The King and his Steward (1.0.0): the Hands (each his own list) and the treasury's switches,
-- which the Steward sets in the King's name; never the King's own buttons (his crown on the map,
-- the court, writs).
local function KingOrSteward() return ns.King.SetsLists() or ns.King.Preview() end

-- One of the King's treasury switches: its label says whether the army sees that part, its
-- tooltip who sees it now (hidden: only he and the Treasurer) and what a click does.
local function TreasuryFlag(what)
	local key = what:upper()
	local function shown() return ns.Treasury.Shows(what) end
	return { "TREASURY_FLAG_" .. key, function() ns.Treasury.SetFlag(what, not shown()) end, refresh = true, shown = KingOrSteward,
		label = function() return L["TREASURY_FLAG_" .. key .. (shown() and "_SHOWN" or "_HIDDEN")] end,
		tooltip = function(tt)
			tt:AddLine(L["TREASURY_FLAG_" .. key .. (shown() and "_SHOWN" or "_HIDDEN")], 1, 0.82, 0)
			tt:AddLine(L["TREASURY_FLAG_" .. key .. "_TIP"], 1, 1, 1, true)
			tt:AddLine(L[shown() and "TREASURY_FLAG_SHOWN_TIP" or "TREASURY_FLAG_HIDDEN_TIP"]:format(L["TREASURY_PART_" .. key]), 0.6, 1, 0.6, true)
		end }
end
local DETAIL_BUTTONS = {
	throne = {
		-- His Hands: the page to name them (his; a Steward's own, 1.0.0).
		{ "HANDS_BTN", function() ns.King.Show("hands") end, refresh = true, shown = KingOrSteward },
		-- His own button: the crown the army sees, what it does and whether it is on now.
		{ "THRONE_LOCATION", function() ns.King.ToggleLocation() end, refresh = true, shown = KingOnly,
			label = function()
				return "|T" .. ns.CROWN_ICON .. ":0|t " .. (ns.King.SharingLocation() and L.THRONE_LOCATION_OFF or L.THRONE_LOCATION_ON)
			end,
			tooltip = function(tt)
				tt:AddLine(L.THRONE_LOCATION, 1, 0.82, 0)
				tt:AddLine(L.THRONE_LOCATION_TIP, 1, 1, 1, true)
				if ns.King.Preview() then
					tt:AddLine(L.THRONE_PREVIEW, 0.6, 0.6, 0.6, true)
				elseif ns.King.SharingLocation() then
					tt:AddLine(L.THRONE_LOCATION_NOW_ON, 0.25, 1, 0.25, true)
				else
					tt:AddLine(L.THRONE_LOCATION_NOW_OFF, 0.6, 0.6, 0.6, true)
				end
			end },
		{ "THRONE_CANCEL_AGENDA", function() ns.King.CancelAgendaButton() end, shown = function() return ns.King.Agenda() ~= nil end },
	},
	-- The full roll call (0.9.9), right above Roll call: rounds on its own until nearly every addon
	-- user answered; the same button stops it. Then the author's views, to see and try what only
	-- the King or the Treasurer sees.
	workshop = {
		{ "WORKSHOP_FULL_BTN", function() ns.Workshop.ToggleFull() end, refresh = true,
			label = function() return ns.Workshop.FullRunning() and L.WORKSHOP_FULL_STOP or L.WORKSHOP_FULL_BTN end,
			tooltip = function(tt)
				tt:AddLine(ns.Workshop.FullRunning() and L.WORKSHOP_FULL_STOP or L.WORKSHOP_FULL_BTN, 1, 0.82, 0)
				tt:AddLine(L.WORKSHOP_FULL_BTN_TIP, 1, 1, 1, true)
			end },
		{ "DEV_KING_VIEW", function() ns.King.SetDevView(not ns.King.Preview()) end, refresh = true,
			label = function() return ns.King.Preview() and L.DEV_KING_VIEW_OFF or L.DEV_KING_VIEW_ON end },
		{ "DEV_TREASURER_VIEW", function() ns.Treasury.SetDevView(not ns.Treasury.DevView()) end, refresh = true,
			label = function() return ns.Treasury.DevView() and L.DEV_TREASURER_VIEW_OFF or L.DEV_TREASURER_VIEW_ON end },
	},
	heraldry = {
		{ "HERALDRY_BTN", DecreeAction("HERALDRY") },
		{ "CLEAR", function() ns.ShowDialog("SYLVANISTAS_CLEAR_INSPECT") end },
	},
	-- The King's switches: what the army sees of the treasury (each its own).
	treasury = { TreasuryFlag("balance"), TreasuryFlag("ranking"), TreasuryFlag("book") },
	-- The King's letters to his Lords (Acts.lua): his button alone.
	decrees = {
		{ "WRIT_BTN", function() ns.Acts.WritPrompt() end, shown = KingOnly },
	},
}
-- (0.9.2: no "Publish shame" button any more: the untabarded list is the King's, Throne tab.)
-- Asking a High Councillor (a moderator) for help, on the Realm tab (0.9.7, Workshop.lua).
DETAIL_BUTTONS.realm = DETAIL_BUTTONS.realm or {}
table.insert(DETAIL_BUTTONS.realm, { "COUNCIL_ASK_BTN", function() ns.ShowDialog("SYLVANISTAS_COUNCIL_ASK") end,
	-- Only where a council exists (a signed list reached us).
	shown = function() local c = ns.rdb and ns.rdb.council return type(c) == "table" and next(c.names or {}) ~= nil end })
-- A councillor's own icon before their name in the Sylvanistas chats (0.9.8, Workshop.lua): shown
-- to councillors alone.
table.insert(DETAIL_BUTTONS.realm, { "COUNCIL_ICON_BTN", function() ns.Workshop.ShowIconPicker() end,
	shown = function() return ns.IsHighCouncillor(ns.me) end })
-- 1.1 (Fern's #28): an officer keeps the gear of the player he targets, in range (Inspect.lua).
table.insert(DETAIL_BUTTONS.heraldry, 1, { "GEAR_BTN", function() ns.Inspect.InspectGear() end,
	shown = function() return ns.IsMember() and ns.Roster.IsOfficer() end })

-- Buttons that come and go (def.shown): only the ones shown, in order.
local function Shown(defs)
	if not defs then return nil end
	local out = {}
	for _, def in ipairs(defs) do
		if not def.shown or def.shown() then out[#out + 1] = def end
	end
	return out
end

local function SetButtonFont(b, small)
	b:SetNormalFontObject(small and "GameFontNormalSmall" or "GameFontNormal")
	b:SetHighlightFontObject(small and "GameFontHighlightSmall" or "GameFontHighlight")
	b:SetDisabledFontObject(small and "GameFontDisableSmall" or "GameFontDisable")
end

local function Button(parent, width, height)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, height or 22)
	b.small = height and height < 22
	if b.small then SetButtonFont(b, true) end
	return b
end

-- Keeps a label inside its button (long translations, the narrow Forever window): it
-- drops to the small font, and is cut with "..." only if even that does not fit.
local function FitLabel(b)
	local fs = b:GetFontString()
	if not fs then return end
	SetButtonFont(b, b.small)
	fs:SetWidth(0)
	local room = b:GetWidth() - 12
	local textW = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
	if not b.small and textW > room then SetButtonFont(b, true) end
	if fs.SetWordWrap then fs:SetWordWrap(false) end
	fs:SetWidth(room)
end

-- The same for a one-line font string: the first of `fonts` the text fits `room` in, else
-- the last one, cut with "...". Fonts the client does not have are skipped. The string must
-- be left-justified and not wrap.
local function FitText(fs, room, fonts)
	fs:SetWidth(0)
	for _, font in ipairs(fonts) do
		if _G[font] then
			fs:SetFontObject(font)
			local textW = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
			if textW <= room then break end
		end
	end
	fs:SetWidth(math.max(1, room))
end

-- Header lines end this far from the window's right edge: the big line keeps clear of
-- the close button column (24 wide on Forever, 32 on the Classic clients), the small one
-- sits lower and only keeps off the border.
local HEADER_RIGHT, SUB_RIGHT = 26, 8

-- Tabs. The tab template is the same atlas one on every client we support
-- (PanelTabButtonTemplate with LeftActive & co., also in Classic Era 1.15.9 and Anniversary
-- 2.5.6), but the code that sizes it is not. Classic's PanelTemplates_TabResize makes a tab
-- its text plus both end caps, which the old -15 overlap was made for. Mainline's (Forever)
-- makes it the text plus 20 (TAB_SIDES_PADDING), and Blizzard spaces those 3 apart
-- (PanelTemplates_AnchorTabs, which only ships with that code) with the first at x 5
-- (FriendsFrame): at -15 they pile up on each other.
-- The Friends window's own tabs are the older kind (no atlas LeftActive): on the Classic
-- clients. Without that window, the client's tab code decides.
function UI.OldTabs()
	local friends = _G.FriendsFrameTab1
	if type(friends) == "table" then return friends.LeftActive == nil end
	return PanelTemplates_AnchorTabs == nil
end

function UI.TabStyle(tab)
	if tab and tab.LeftActive and PanelTemplates_AnchorTabs then return "mainline" end
	return "classic"
end

-- The anchor of tab i (prev is tab i - 1) under `frame`, or beside it for "side" (the HD
-- window's icon tabs, placed like the Guild & Communities window's in CommunitiesFrame.xml).
function UI.TabAnchor(style, i, frame, prev)
	if style == "side" then
		if i == 1 then return "TOPLEFT", frame, "TOPRIGHT", 0, -SIDE_TOP end
		return "TOPLEFT", prev, "BOTTOMLEFT", 0, -SIDE_GAP
	end
	if style == "mainline" then
		if i == 1 then return "TOPLEFT", frame, "BOTTOMLEFT", 5, 2 end
		return "TOPLEFT", prev, "TOPRIGHT", 3, 0
	end
	if i == 1 then return "TOPLEFT", frame, "BOTTOMLEFT", 10, 2 end
	return "LEFT", prev, "RIGHT", -15, 0
end

-- The look for our window: "hd" next to (or in place of) Forever's Guild & Communities
-- window, "old" anywhere else (GuildFrame.lua decides, from the guild window in use or
-- `host`, one of its hosts).
function UI.Style(host)
	local hook = ns.GuildFrameHook
	return hook and hook.IsHD and hook.IsHD(host) and "hd" or "old"
end

-- How far right of the guild window ours docks. The old one overlaps the Social window's
-- border by 2, as always. The HD one leaves the gap Blizzard leaves between two windows
-- (PANEl_SPACING_X), past the side tabs when the Communities window shows them (it then
-- asks for 32 more, its extraWidth): where Blizzard would put the next window.
function UI.DockOffset(style, sideTabsShown)
	if style == "hd" then return (sideTabsShown and HD_TABS_W or 0) + PANEL_GAP end
	return -2
end

-- Blizzard's Issue Reporter (Blizzard_PTRFeedback, only on beta and PTR clients such as
-- the Forever beta) is a small draggable box with a bug button under it, by default at the
-- bottom centre of the screen: right over the buttons and tabs of our window at its
-- default place. It is Blizzard's, so it is never moved: our window steps up. The player may
-- hide it (0.9.5, off until they choose: its "Hide" button or /syl issuereporter), and it
-- then stays hidden at every login. The idea and the first macro: Artz, of the guild.
local ISSUE_GAP = 4

local reporterHooked, hiddenByUs = false, false
local function Reporter()
	local r = _G.PTR_IssueReporter
	if type(r) == "table" and r.Hide and r.Show and r.IsShown then return r end
end
-- (Never a protected frame in combat: the game would refuse it.)
local function CanTouch(r)
	return not (InCombatLockdown and InCombatLockdown() and r.IsProtected and r:IsProtected())
end
function UI.IssueReporterHidden() return ns.db and ns.db.hideIssueReporter == true end

function UI.ApplyIssueReporter()
	-- Blizzard's gamepad UI (0.9.8): the game hides the Issue Reporter there itself and shows it
	-- only with its gamepad menu, centred, with bindings of its own (see
	-- Blizzard_PTRFeedback_Gamepad.lua), so it never covers our window. Hidden from our code, its
	-- hide would run that gamepad code from ours: Sylvanistas leaves it alone there (no hook, no
	-- button, never hidden or shown).
	if ns.GamepadUI() then return false end
	local r = Reporter()
	if not r then return false end
	if not reporterHooked and r.HookScript then
		reporterHooked = true
		-- Hooked, not replaced: Blizzard's own OnShow runs as always, then it goes away.
		r:HookScript("OnShow", function(self)
			if UI.IssueReporterHidden() and CanTouch(self) and not ns.GamepadUI() then
				self:Hide()
				hiddenByUs = true
			end
		end)
		local ok, b = pcall(CreateFrame, "Button", nil, r, "UIPanelButtonTemplate")
		if ok and b then
			b:SetSize(48, 18)
			b:SetText(L.ISSUE_HIDE)
			b:SetPoint("BOTTOMRIGHT", r, "TOPRIGHT", 0, 2)
			b:SetScript("OnClick", function() UI.SetIssueReporterHidden(true) end)
			b:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:AddLine(L.TITLE, 1, 0.82, 0)
				GameTooltip:AddLine(L.ISSUE_HIDE_TIP, 1, 1, 1, true)
				GameTooltip:Show()
			end)
			b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		end
	end
	if UI.IssueReporterHidden() then
		if r:IsShown() and CanTouch(r) then
			r:Hide()
			hiddenByUs = true
		end
	elseif hiddenByUs and CanTouch(r) then
		r:Show()
		hiddenByUs = false
	end
	return true
end

function UI.SetIssueReporterHidden(on)
	ns.db.hideIssueReporter = on and true or false
	ns.Print(on and L.ISSUE_HIDDEN or L.ISSUE_SHOWN)
	if ns.GamepadUI() then ns.Print(L.ISSUE_GAMEPAD) end
	UI.ApplyIssueReporter()
end
function UI.ResetIssueReporter() reporterHooked, hiddenByUs = false, false end -- tests

ns.On("LOGIN", function()
	ns.After(2, "issue reporter", function() ns.SafeCall("issue reporter", UI.ApplyIssueReporter) end)
	ns.RegisterEvent("ADDON_LOADED", function(name)
		if name == "Blizzard_PTRFeedback" then ns.SafeCall("issue reporter", UI.ApplyIssueReporter) end
	end)
end)

-- A region's rect in screen pixels, or nil if it is not laid out.
local function ScreenRect(region)
	if type(region) ~= "table" or not region.GetRect then return nil end
	local left, bottom, width, height = region:GetRect()
	if not left or not bottom or not width or not height then return nil end
	local s = region.GetEffectiveScale and region:GetEffectiveScale() or 1
	return { left = left * s, bottom = bottom * s, right = (left + width) * s, top = (bottom + height) * s }
end

local function Union(a, b)
	if not a then return b end
	if not b then return a end
	return { left = math.min(a.left, b.left), bottom = math.min(a.bottom, b.bottom),
		right = math.max(a.right, b.right), top = math.max(a.top, b.top) }
end

-- How far up a window must go to clear an obstacle (screen rects, pixels): nil when they
-- do not overlap, or when that would push the window's top past screenTop (it stays put).
function UI.ClearUp(win, obstacle, screenTop, gap)
	if not win or not obstacle or not screenTop then return nil end
	if win.left >= obstacle.right or win.right <= obstacle.left then return nil end
	if win.bottom >= obstacle.top or win.top <= obstacle.bottom then return nil end
	local dy = obstacle.top + (gap or 0) - win.bottom
	if win.top + dy > screenTop then return nil end
	return dy
end

-- The Issue Reporter's screen rect with its border, bug button and info button, if shown.
local function IssueReporterRect()
	local r = _G.PTR_IssueReporter
	if type(r) ~= "table" or not r.IsVisible or not r:IsVisible() then return nil end
	local rect
	for _, part in ipairs({ r, r.Border, r.Body, r.ReportBug, r.InfoButton }) do
		if type(part) == "table" and part.IsVisible and part:IsVisible() then rect = Union(rect, ScreenRect(part)) end
	end
	return rect
end

-- Moves `frame` (held by one anchor) up just enough that `parts`, what it covers on screen
-- (the frame, the tabs hanging below it), clear the Issue Reporter. Called when the frame
-- shows, never continuously. Returns true if the frame was not laid out yet.
local function StepAboveIssueReporter(frame, parts)
	local obstacle = IssueReporterRect()
	if not obstacle or not frame:IsShown() or frame:GetNumPoints() ~= 1 then return end
	local win
	for _, part in ipairs(parts) do
		if part:IsShown() then win = Union(win, ScreenRect(part)) end
	end
	if not ScreenRect(frame) then return true end
	local screen = ScreenRect(UIParent)
	local dy = screen and UI.ClearUp(win, obstacle, screen.top, ISSUE_GAP)
	if not dy then return end
	local point, rel, relPoint, x, y = frame:GetPoint(1)
	frame:ClearAllPoints()
	frame:SetPoint(point, rel, relPoint, x, y + dy / frame:GetEffectiveScale())
	ns.Log("%s moved up %d to clear the Issue Reporter", tostring(frame:GetName()), math.floor(dy + 0.5))
end

-- Runs a check now, and once more on the next frame if the frame had no rect yet (a
-- window shown the moment it was made).
local function ClearOfIssueReporter(check)
	if check() and C_Timer and C_Timer.After then
		C_Timer.After(0, function() ns.SafeCall("issue reporter", check) end)
	end
end

-- Our window at its own place (never docked or dragged) steps above the Issue Reporter.
local function MainClearOfIssueReporter()
	if not main or main.docked or main.movedByPlayer then return end
	local parts = { main }
	for _, tab in ipairs(main.tabs) do parts[#parts + 1] = tab end
	return StepAboveIssueReporter(main, parts)
end

-- The Social window's size, which is the old Guild window's (the Guild tab fills it).
local function SocialSize()
	if FriendsFrame and FriendsFrame.GetWidth then
		local w, h = FriendsFrame:GetWidth(), FriendsFrame:GetHeight()
		if w and w > 200 and h and h > 200 then return w, h end
	end
	return DEFAULT_W, DEFAULT_H
end

-- Size when docked to a host of hostW x hostH, next to a Social window of baseW x baseH.
-- The old Guild tab lends its whole size, as it always did. The new guild windows only
-- lend their height (the Communities window is 814 wide maximized, 322 minimized): the
-- width stays the Social window's, the width our list is laid out for.
function UI.DockSize(hostW, hostH, heightOnly, baseW, baseH)
	baseW, baseH = baseW or DEFAULT_W, baseH or DEFAULT_H
	local okW, okH = hostW and hostW > 200, hostH and hostH > 200
	if heightOnly then return baseW, okH and hostH or baseH end
	if okW and okH then return hostW, hostH end
	return baseW, baseH
end

-- Size of a new window: as if docked to the guild window in use (GuildFrame.lua knows
-- which), else the Social window's (the HD one with the Communities window's height).
local function HostSize(style)
	local hook = ns.GuildFrameHook
	local host = hook and hook.ActiveHost and hook.ActiveHost()
	if host and host.dock and host.dock.GetWidth then
		return UI.DockSize(host.dock:GetWidth(), host.dock:GetHeight(), host.heightOnly, SocialSize())
	end
	local w, h = SocialSize()
	if style == "hd" then return w, HD_DEFAULT_H end
	return w, h
end

-- Where the parts of each window sit. old: the numbers the window always had. hd: those of
-- the Guild & Communities window (ButtonFrameTemplate's Inset at 4,-60 / -6,26, buttons 20
-- tall at y 5, ColumnDisplay headers 24 tall on the list's top border, the thin scroll bar
-- of ScrollFrameTemplate). topNoCols: without column titles (other tabs, the Join screen);
-- the old list box never moves.
local GEOMETRY = {
	old = {
		box = { left = 6, top = -56, right = -6, bottom = 36 + DETAIL_H + 4 },
		header = { left = 8, right = -28, y = -58, h = 20 },
		scroll = { left = 10, top = -80, topNoCols = -64, right = -30, bottom = 36 + DETAIL_H + 8 },
		detail = { left = 6, right = -6, y = 36 },
		buttons = { x = 8, y = 8, h = 22, margin = 16 },
	},
	hd = {
		box = { left = 4, top = -81, topNoCols = -60, right = -6, bottom = 110 },
		header = { left = 6, right = -24, y = -59, h = 24 },
		scroll = { left = 7, top = -84, topNoCols = -63, right = -24, bottom = 113 },
		detail = { left = 4, right = -6, y = 28 },
		buttons = { x = 5, y = 5, h = 20, margin = 10 },
	},
}

---------------------------------------------------------------------------
-- The Chat tab (1.1.1): ChatWindow.lua draws it in the window, over the list's place. The author's
-- words: no soldiers' counts on top (the search box goes there, the channels' switch and the
-- settings' gear on its row), no column titles (a row of channel pills there took the lines' room:
-- most players read one channel), no detail box (the lines take its room), and the box to write
-- in where the buttons are, with no Send button (Enter sends).
---------------------------------------------------------------------------

-- The tab shows for whoever reads a Sylvanistas chat (every member, as the Realm tab's chats' line),
-- with ChatWindow.lua loaded or not (a client updated without a restart: the tab says so).
local function ChatTabVisible()
	local C = ns.Channels
	if not C or C.missing or type(C.CanUse) ~= "function" then return false end
	for _, t in ipairs(C.ORDER or {}) do
		if C.CanUse(t) then return true end
	end
	return false
end

-- ChatWindow.lua there to draw it.
local function ChatPaneReady()
	local CW = ns.ChatWindow
	return type(CW) == "table" and not CW.missing and type(CW.Attach) == "function" and type(CW.Detach) == "function"
end

-- Where the Chat tab's parts go in window `f`, from its look's numbers (offsets from its corners):
-- the search box right of the portrait, where the counts are (the channels' switch and the gear
-- at that row's end, ChatWindow.lua); the lines from where the list's box starts without column
-- titles (the channel pills' row there is gone, the author's ask) down to the buttons' row; the
-- box across that row, as wide as its buttons together.
function UI.ChatPlaces(f)
	f = f or main
	if not f then return nil end
	if f.chatPlaces then return f.chatPlaces end
	local g = GEOMETRY[f.style]
	local b = g.buttons
	f.chatPlaces = {
		search = { left = f.headerX or 12, right = -HEADER_RIGHT, top = -30 },
		box = { left = g.box.left, right = g.box.right, top = g.box.topNoCols or g.box.top, bottom = b.y + b.h + 4 },
		input = { left = b.x, right = b.x - b.margin, y = b.y, h = b.h },
	}
	return f.chatPlaces
end

-- The Chat tab in the window in use (on), or not.
local function ChatPane(on)
	if not ChatPaneReady() or not main then return end
	if on then ns.ChatWindow.Attach(main, UI.ChatPlaces(main)) else ns.ChatWindow.Detach(main) end
end

-- A column title. The old window: the old Guild or Who window's (named, for
-- WhoFrameColumn_SetWidth). The HD one: the Communities roster's, ColumnDisplay (the variant
-- without scripts: the other calls its parent's OnClick), not named; the Who one is named
-- apart, since its parts are named after it. A plain button where the client has neither.
local function ColumnHeader(f, c)
	local parent = f.colHeader
	if f.style == "hd" then
		for _, template in ipairs({ "ColumnDisplayButtonNoScriptsTemplate", "WhoFrameColumnHeaderTemplate" }) do
			local who = template == "WhoFrameColumnHeaderTemplate"
			local okB, res = pcall(CreateFrame, "Button", who and ("SylvanistasColumnHeaderHD" .. c) or nil, parent, template)
			if okB and res and res.Left and res.Right then
				res.whoTemplate = who
				return res
			elseif okB and res then
				res:Hide()
			end
		end
	else
		for _, template in ipairs({ "GuildFrameColumnHeaderTemplate", "WhoFrameColumnHeaderTemplate" }) do
			local okB, res = pcall(CreateFrame, "Button", "SylvanistasColumnHeader" .. c .. template, parent, template)
			if okB and res and res.GetFontString then return res end
		end
	end
	local b = CreateFrame("Button", nil, parent)
	b:SetNormalFontObject("GameFontNormalSmall")
	b:SetText(" ")
	return b
end

-- One of the HD window's tabs: an icon down its right side, like the Guild & Communities
-- window's (RightSideTabTemplate brings the click sound and the check), or the
-- same built here (RightSideTab.xml) where the client lacks the template.
-- Its tooltip on the side it hangs from, clear of the window.
local function SideTabEnter(self)
	if not self.tooltip then return end
	GameTooltip:SetOwner(self, self.onLeft and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
	GameTooltip:SetText(self.tooltip)
	GameTooltip:Show()
end

local function SideTab(f)
	local ok, tab = pcall(CreateFrame, "CheckButton", nil, f, "RightSideTabTemplate")
	if ok and tab and tab.Icon then
		-- Its art has no key: the one texture on the BORDER layer.
		for _, region in ipairs({ tab:GetRegions() }) do
			if region.GetDrawLayer and region:GetDrawLayer() == "BORDER" then tab.Art = region break end
		end
		tab:SetScript("OnEnter", SideTabEnter)
		return tab, "RightSideTabTemplate"
	end
	if ok and tab then tab:Hide() end
	tab = CreateFrame("CheckButton", nil, f)
	tab:SetSize(32, 32)
	local art = tab:CreateTexture(nil, "BORDER")
	art:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
	art:SetSize(64, 64)
	art:SetPoint("TOPLEFT", -3, 11)
	tab.Art = art
	tab.Icon = tab:CreateTexture(nil, "ARTWORK")
	tab.Icon:SetSize(30, 30)
	tab.Icon:SetPoint("CENTER")
	tab.Icon:SetTexCoord(0.03125, 0.96875, 0.03125, 0.96875)
	tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	tab:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
	local checked = tab.GetCheckedTexture and tab:GetCheckedTexture()
	if checked and checked.SetBlendMode then checked:SetBlendMode("ADD") end
	tab:SetScript("OnEnter", SideTabEnter)
	tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return tab, "fallback"
end

-- A side tab hangs from the window's right edge, or from its left one (UI.LayoutTabs):
-- there its art is turned round, the tab's open side against the window.
local function SideTabOnLeft(tab, left)
	left = left and true or false
	if (tab.onLeft or false) == left then return end
	tab.onLeft = left
	local art = tab.Art
	if not art then return end
	art:ClearAllPoints()
	if left then
		art:SetPoint("TOPRIGHT", 3, 11)
		art:SetTexCoord(1, 0, 0, 1)
	else
		art:SetPoint("TOPLEFT", -3, 11)
		art:SetTexCoord(0, 1, 0, 1)
	end
end

-- Whether `count` side tabs, `tabHeight` tall, fit down a window `height` tall, their art
-- included.
function UI.SideTabsFit(count, tabHeight, height)
	return SIDE_TOP + count * tabHeight + (count - 1) * SIDE_GAP + SIDE_ART_BELOW <= height
end

-- Blizzard's help button art, on every client we run on (the Guild & Communities window, the
-- settings, the help plates): a texture of its own, with itself added faintly as the highlight
-- (RinglessHelpPlateButtonTemplate).
UI.HELP_ICON = "Interface\\Common\\help-i"

-- The help button in the title bar, just left of the close button, where Blizzard puts a
-- window's minimize button (0.9.9, asked for by Max of Asmongold's moderators). A plain button:
-- a click opens the copy box (UI.ShowHelp), which already keeps to the gamepad UI's rules.
local function HelpButton(f)
	local close = f.CloseButton or _G[f:GetName() .. "CloseButton"]
	local b = CreateFrame("Button", nil, f)
	-- As big as the close button's art: Forever's is 24 and fills it, Classic's red disc is
	-- about 20 inside a 32 button, so there it tucks in closer. Told apart by the button, not
	-- by our window's look: the old window on Forever has Mainline's close button too.
	local classic = close and (close:GetWidth() or 0) > 28
	b:SetSize(classic and 20 or 22, classic and 20 or 22)
	if close then
		b:SetPoint("RIGHT", close, "LEFT", classic and 4 or 0, 0)
	else -- (both templates have one; just in case) the title bar's right end
		b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -2)
	end
	-- Over the frame's border like the close button (Forever's metal title bar is a NineSlice
	-- at +500 and its buttons at 510): at the close button's level, or above the border.
	local border = f.NineSlice and f.NineSlice.GetFrameLevel and f.NineSlice:GetFrameLevel() or f:GetFrameLevel()
	b:SetFrameLevel(math.max(border + 10, close and close.GetFrameLevel and close:GetFrameLevel() or 0))
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetTexture(UI.HELP_ICON)
	b.icon:SetAllPoints()
	b:SetHighlightTexture(UI.HELP_ICON, "ADD")
	local highlight = b.GetHighlightTexture and b:GetHighlightTexture()
	if highlight and highlight.SetAlpha then highlight:SetAlpha(0.2) end
	b:SetScript("OnClick", function() ns.SafeCall("help", UI.ShowHelp) end)
	-- The title bar still drags the window from there, as it did before the button.
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnDragStart", function() f:StartMoving() end)
	b:SetScript("OnDragStop", function() f:GetScript("OnDragStop")(f) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L.HELP_BTN, 1, 0.82, 0)
		GameTooltip:AddLine(L.HELP_BTN_TIP, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

local function CreateMain(style)
	local g = GEOMETRY[style]
	local hd = style == "hd"
	local ok, f = pcall(CreateFrame, "Frame", hd and "SylvanistasFrameHD" or "SylvanistasFrame", UIParent, "PortraitFrameTemplate")
	if ok and f and f.CloseButton then
		f.hasPortrait = true
	else
		if ok and f then f:Hide() end
		ns.Log("PortraitFrameTemplate unavailable, using BasicFrameTemplateWithInset")
		f = CreateFrame("Frame", hd and "SylvanistasFrameHDBasic" or "SylvanistasFrameBasic", UIParent, "BasicFrameTemplateWithInset")
	end
	f.style = style
	f:SetSize(HostSize(style))
	f:SetPoint("CENTER", 0, 40)
	f:SetFrameStrata("MEDIUM")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	-- The side tabs hang past the right edge: they stay on the screen too.
	if hd and f.SetClampRectInsets then f:SetClampRectInsets(0, HD_TABS_REACH, 0, 0) end
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		self.docked = false
		self.movedByPlayer = true -- where the player puts it, it stays
	end)
	f:Hide()
	ns.EscapeCloses(f:GetName())
	f:HookScript("OnShow", function(self) ns.EscapeCloses(self:GetName()) end)
	-- Its X hides it itself (1.1.1, as the first build's chat window did, and as Sylvanistas's other
	-- windows' X does): the template's button (UIPanelCloseButton_OnClick) would call HideUIPanel,
	-- which does nothing in combat when the call is not secure (CheckProtectedFunctionsAllowed,
	-- UIParentPanelManager.lua). With the chats in this window, and with the gamepad UI (no Escape
	-- list), the X is the way to close it.
	f.onCloseCallback = function()
		f:Hide()
		return false
	end

	if f.SetTitle then
		f:SetTitle(L.TITLE)
	elseif f.TitleText then
		f.TitleText:SetText(L.TITLE)
	elseif f.TitleContainer and f.TitleContainer.TitleText then
		f.TitleContainer.TitleText:SetText(L.TITLE)
	end
	if f.hasPortrait then
		local portrait = f.portrait or f.Portrait or (f.PortraitContainer and f.PortraitContainer.portrait)
		if portrait then
			portrait:SetTexture(ns.LOGO)
			-- (Its coords before its mask, once: a masked texture refuses new ones, Forever 1.60.)
			if not portrait.sylvanistasMasked then portrait:SetTexCoord(0, 1, 0, 1) end
			if portrait.SetMask and not portrait.sylvanistasMasked then
				portrait.sylvanistasMasked = pcall(portrait.SetMask, portrait, "Interface\\CharacterFrame\\TempPortraitAlphaMask")
			end
		elseif f.SetPortraitToAsset then
			pcall(f.SetPortraitToAsset, f, ns.LOGO)
		end
	end
	f.helpButton = HelpButton(f)

	-- One dark panel over the whole interior, like the Guild window (its inside is near
	-- black, not the lighter marble of the plain portrait frame).
	-- Like the Guild window: the frame keeps its own mottled grey texture, and the list
	-- (with its column headers) sits in a dark mottled box with a border, the same box
	-- style as the detail box below (Blizzard's inset). Created early so later frames
	-- (column headers, list) draw on top of it.
	local okBox, box = pcall(CreateFrame, "Frame", nil, f, "InsetFrameTemplate")
	if okBox and box then
		box:SetPoint("TOPLEFT", g.box.left, g.box.top)
		box:SetPoint("BOTTOMRIGHT", g.box.right, g.box.bottom)
		f.listBox = box
	end

	-- Header row (where the Guild window has "Show Offline Members")
	-- One line each, kept inside the window by FitHeader (long texts, the narrow window).
	local hx = f.hasPortrait and 62 or 12
	f.headerX = hx
	f.total = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.total:SetPoint("TOPLEFT", hx, -28)
	f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.sub:SetPoint("TOPLEFT", f.total, "BOTTOMLEFT", 0, -1)
	for _, fs in ipairs({ f.total, f.sub }) do
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
	end
	-- The count explains itself on hover: how the census is gathered, why two players can see
	-- different totals for a while. The window still drags from there.
	local hover = CreateFrame("Frame", nil, f)
	hover:SetPoint("TOPLEFT", f.total, "TOPLEFT", 0, 2)
	hover:SetPoint("BOTTOMLEFT", f.sub, "BOTTOMLEFT", 0, -2)
	hover:SetWidth(200)
	hover:EnableMouse(true)
	hover:RegisterForDrag("LeftButton")
	hover:SetScript("OnDragStart", function() f:StartMoving() end)
	hover:SetScript("OnDragStop", function() f:GetScript("OnDragStop")(f) end)
	hover:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
		GameTooltip:AddLine(L.HEADER_TIP_TITLE, 1, 0.82, 0)
		GameTooltip:AddLine(L.HEADER_TIP, 1, 1, 1, true)
		-- 1.1: the characters their players linked as alts count once (Alts.lua).
		local s = ns.Data.Summary()
		if (s.alts or 0) > 0 then
			GameTooltip:AddLine(L.HEADER_TIP_ALTS:format(ns.FormatNumber(s.characters or s.total), ns.FormatNumber(s.alts)), 0.8, 0.8, 0.8, true)
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(L.HEADER_TIP_DIFFER, 0.8, 0.8, 0.8, true)
		-- 1.1.2: why the list's columns don't add up to these totals (the answer bank's).
		if ns.Answers and ns.Answers.WhyTip then ns.Answers.WhyTip(GameTooltip, "count-columns-dont-add-up") end
		GameTooltip:Show()
	end)
	hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.headerHover = hover

	-- Column titles
	f.colHeader = CreateFrame("Frame", nil, f)
	f.colHeader:SetPoint("TOPLEFT", g.header.left, g.header.y)
	f.colHeader:SetPoint("TOPRIGHT", g.header.right, g.header.y)
	f.colHeader:SetHeight(g.header.h)
	if f.listBox then f.colHeader:SetFrameLevel(f.listBox:GetFrameLevel() + 2) end
	f.colHeader.buttons = {}
	for c = 1, 4 do
		local b = ColumnHeader(f, c)
		b:SetHeight(g.header.h)
		b:SetScript("OnClick", function(self)
			if self.sortKey then
				ns.Views.SortBy(self.sortKey)
				UI.Refresh()
			end
			UI.Clicked()
		end)
		f.colHeader.buttons[c] = b
	end

	-- List. The HD one has the Communities roster's thin scroll bar (ScrollFrameTemplate,
	-- Mainline); a client without it gets the old one, which needs more room on the right.
	local scroll
	if hd then
		local okScroll, res = pcall(CreateFrame, "ScrollFrame", "SylvanistasScrollHD", f, "ScrollFrameTemplate")
		if okScroll and res and res.ScrollBar then
			scroll = res
		else
			if okScroll and res then res:Hide() end
			scroll = CreateFrame("ScrollFrame", "SylvanistasScrollHDOld", f, "UIPanelScrollFrameTemplate")
			f.scrollRight = -30
		end
	else
		scroll = CreateFrame("ScrollFrame", "SylvanistasScroll", f, "UIPanelScrollFrameTemplate")
	end
	if f.listBox then scroll:SetFrameLevel(f.listBox:GetFrameLevel() + 2) end
	scroll:SetPoint("BOTTOMRIGHT", f.scrollRight or g.scroll.right, g.scroll.bottom)
	f.scroll = scroll
	-- The place a redraw gave the list, once more when the client measures the list again
	-- (UI.KeepPlace): after Blizzard's own handler, whatever it did with the offset.
	scroll:HookScript("OnScrollRangeChanged", function(self) ns.SafeCall("list place", UI.HoldPlace, f, self) end)
	-- The player scrolls with the wheel: the list stays where he puts it (UI.Scrolled).
	scroll:HookScript("OnMouseWheel", function() ns.SafeCall("list scrolled", UI.Scrolled, f) end)
	f.views = {}
	for _, t in ipairs(TABS) do
		local v = CreateFrame("Frame", nil, scroll)
		v:SetSize(10, 10)
		v:Hide()
		v.style = style -- rows are drawn in the window's look (Views.lua)
		f.views[t.key] = v
	end

	-- Detail box (like "Guild Message Of The Day")
	local okDetail, detail = pcall(CreateFrame, "Frame", nil, f, "InsetFrameTemplate")
	if not okDetail or not detail then detail = CreateFrame("Frame", nil, f) end
	detail:SetPoint("BOTTOMLEFT", g.detail.left, g.detail.y)
	detail:SetPoint("BOTTOMRIGHT", g.detail.right, g.detail.y)
	detail:SetHeight(DETAIL_H)
	f.detailTitle = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.detailTitle:SetPoint("TOPLEFT", 8, -6)
	f.detailTitle:SetPoint("TOPRIGHT", -26, -6) -- (the page's "?" at its end)
	-- 1.1.2: the page's own "?" (Answers.lua): what this page shows and, where it counts, why the
	-- numbers can differ between two players. Blizzard's help art, as the title bar's help button
	-- (the whole addon's help); a plain button: a click opens the copy box.
	local pageHelp = CreateFrame("Button", nil, detail)
	pageHelp:SetSize(18, 18)
	pageHelp:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -5, -3)
	pageHelp.icon = pageHelp:CreateTexture(nil, "ARTWORK")
	pageHelp.icon:SetTexture(UI.HELP_ICON)
	pageHelp.icon:SetAllPoints()
	pageHelp:SetHighlightTexture(UI.HELP_ICON, "ADD")
	pageHelp:SetScript("OnClick", function() ns.SafeCall("page help", UI.ExplainPage) end)
	pageHelp:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L.PAGE_HELP, 1, 0.82, 0)
		GameTooltip:AddLine(L.PAGE_HELP_TIP, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	pageHelp:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.pageHelp = pageHelp
	f.detailTitle:SetJustifyH("LEFT")
	f.detailText = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.detailText:SetPoint("TOPLEFT", f.detailTitle, "BOTTOMLEFT", 0, -3)
	f.detailText:SetPoint("RIGHT", -8, 0)
	f.detailText:SetJustifyH("LEFT")
	f.detailText:SetJustifyV("TOP")
	f.detailText:SetHeight(DETAIL_H - 26)
	f.detail = detail
	f.detailButtons = {}
	for i = 1, 3 do
		local b = Button(detail, 90, 18)
		if i == 1 then b:SetPoint("BOTTOMLEFT", 6, 5) else b:SetPoint("LEFT", f.detailButtons[i - 1], "RIGHT", 3, 0) end
		b:Hide()
		f.detailButtons[i] = b
	end

	-- Bottom buttons (the HD ones as low as "View Log" and "Invite Member", CommunitiesFrame.xml)
	f.buttons = {}
	for i = 1, 3 do
		local b = Button(f, 10, 22)
		if hd then b:SetHeight(g.buttons.h) end
		f.buttons[i] = b
	end

	-- Tabs
	f.tabs = {}
	if hd then
		-- Above the metal border, like the Communities window's (frameLevel 510).
		local level = (f.NineSlice and f.NineSlice.GetFrameLevel and f.NineSlice:GetFrameLevel() or f:GetFrameLevel()) + 10
		for i, t in ipairs(TABS) do
			local tab, template = SideTab(f)
			local icon = t.icon
			if type(icon) == "function" then
				local okIcon, res = pcall(icon)
				icon = okIcon and res or nil
			end
			tab.Icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
			tab.tooltip = L[t.label] -- shown by RightSideTabMixin:OnEnter
			tab.key = t.key
			tab:SetID(i)
			tab:SetFrameLevel(level)
			tab:SetPoint(UI.TabAnchor("side", i, f, f.tabs[i - 1]))
			local function Select() ns.SafeCall("tab " .. t.key, UI.SelectTab, t.key) end
			-- Hooked: the template's own click (its sound, the check) runs first.
			if template == "fallback" then tab:SetScript("OnClick", Select) else tab:HookScript("OnClick", Select) end
			f.tabs[i] = tab
			f.tabTemplate = template
		end
		f.tabStyle = "side"
	else
		-- Tab templates differ between clients. Ours look like the Friends window's tabs
		-- (Friends, Who, Guild, Raid): the older tab with small text where Blizzard's is one
		-- (the Classic clients, Anniversary included), the atlas one where it is not (Forever).
		-- The first template that really builds a tab is used; otherwise a plain button, its
		-- selection marked by us.
		local templates = UI.OldTabs()
			and { "CharacterFrameTabButtonTemplate", "PanelTabButtonTemplate", "TabButtonTemplate" }
			or { "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate", "TabButtonTemplate" }
		for i, t in ipairs(TABS) do
			local tab
			for n, template in ipairs(templates) do
				local name = f:GetName() .. "Tab" .. n .. "_" .. i
				local okTab, res = pcall(CreateFrame, "Button", name, f, template)
				if okTab and res and (res.Left or res.LeftActive or _G[name .. "Left"] or _G[name .. "LeftDisabled"]) then
					tab = res
					UI.tabTemplate = template
					break
				elseif okTab and res then
					res:Hide()
				end
			end
			if not tab then
				tab = Button(f, 80, 22)
				tab.isFallback = true
				UI.tabTemplate = "fallback"
			end
			tab:SetID(i)
			tab:SetText(L[t.label])
			if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
			UI.tabStyle = UI.TabStyle(tab)
			tab:SetPoint(UI.TabAnchor(UI.tabStyle, i, f, f.tabs[i - 1]))
			tab:SetScript("OnClick", function() ns.SafeCall("tab " .. t.key, UI.SelectTab, t.key) end)
			tab.key = t.key
			f.tabs[i] = tab
		end
		f.tabTemplate, f.tabStyle = UI.tabTemplate, UI.tabStyle
	end
	f.numTabs = #TABS

	local elapsed = 0
	f:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed > 5 then
			elapsed = 0
			UI.Refresh()
		end
	end)
	f:SetScript("OnShow", function()
		UI.Refresh()
		ns.SafeCall("issue reporter", ClearOfIssueReporter, MainClearOfIssueReporter)
		-- 1.1 (Fern's #11): the first-open page, over the window, while anything is unanswered
		-- (Consent.lua: once a session, never in combat or an instance). The window works anyway.
		ns.SafeCall("privacy page", ns.Consent.Ask, "window")
	end)
	f:SetScript("OnHide", function(self)
		local person = personFrames[self.style]
		if person then person:Hide() end
		-- (The Chat tab goes with it: its boxes let go of the keyboard.)
		if ChatPaneReady() then ns.ChatWindow.Detach(self) end
	end)
	f:SetScript("OnSizeChanged", function(self) if self == main then UI.Layout() end end)
	return f
end

-- The window in `style`, made the one in use. The other one closes (with its person
-- panel) and hands over its tab.
local function UseStyle(style)
	if main and main.style == style then return main end
	local previous = main
	frames[style] = frames[style] or CreateMain(style)
	main = frames[style]
	if previous then
		main.tab = previous.tab or main.tab
		if previous:IsShown() then previous:Hide() end
	end
	UI.tabTemplate, UI.tabStyle = main.tabTemplate, main.tabStyle
	return main
end

-- The bottom buttons share the window width: three on a tab, two on the Join screen.
local function LayoutButtons()
	local g = GEOMETRY[main.style].buttons
	local shown = {}
	for _, b in ipairs(main.buttons) do
		if b:IsShown() then shown[#shown + 1] = b end
	end
	if #shown == 0 then shown = main.buttons end
	local bw = math.floor((main:GetWidth() - g.margin - 2 * (#shown - 1)) / #shown)
	for i, b in ipairs(shown) do
		b:SetWidth(bw)
		b:ClearAllPoints()
		if i == 1 then b:SetPoint("BOTTOMLEFT", g.x, g.y) else b:SetPoint("LEFT", shown[i - 1], "RIGHT", 2, 0) end
		FitLabel(b)
	end
end

-- The small buttons in the detail box are as wide as their label, side by side from the
-- left; when they are wider together than the box, each gives up its share (FitLabel then
-- drops to "..." only if even that is too narrow).
local function LayoutDetailButtons()
	local shown, widths, total = {}, {}, 0
	for _, b in ipairs(main.detailButtons) do
		if b:IsShown() then
			local fs = b:GetFontString()
			local textW = 0
			if fs then
				SetButtonFont(b, true)
				fs:SetWidth(0)
				textW = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
			end
			shown[#shown + 1] = b
			widths[#shown] = math.max(60, math.ceil(textW) + 20)
			total = total + widths[#shown]
		end
	end
	if #shown == 0 then return end
	local room = main.detail:GetWidth() - 12 - 3 * (#shown - 1)
	local scale = (room > 0 and total > room) and room / total or 1
	for i, b in ipairs(shown) do
		b:SetWidth(math.max(30, math.floor(widths[i] * scale)))
		b:ClearAllPoints()
		if i == 1 then b:SetPoint("BOTTOMLEFT", 6, 5) else b:SetPoint("LEFT", shown[i - 1], "RIGHT", 3, 0) end
		FitLabel(b)
	end
end

-- The tabs under the old window fit its width. Blizzard sizes each to its text (about 115
-- wide each on the Classic clients), wider together than our window once there are four or
-- five (the King's Throne): past it they shrink evenly, their text cut by the tab itself.
-- The shown tabs follow one another, a hidden one (the Throne, the Workshop) leaving no gap,
-- in the HD window's side column too. That column holds seven: past them, the tabs of
-- SIDE_LEFT_ORDER move to the left edge, one by one until the rest fit (1.1.1: with the Chat tab
-- the King's view makes eight, and his Treasury, the last of his, goes left; the author's
-- preview adds the Workshop, which goes first). The left ones stack up from low on that edge, in
-- their order down (the last one lowest), clear of the Communities window's own side tabs when
-- ours is docked beside it.
function UI.LayoutTabs()
	if not main or not main.tabs then return end
	local shown = {}
	for _, tab in ipairs(main.tabs) do
		if tab:IsShown() then shown[#shown + 1] = tab end
	end
	if #shown == 0 then return end
	local left, onLeft = {}, {}
	if main.tabStyle == "side" then
		local height, tabHeight = main:GetHeight() or 0, shown[1]:GetHeight() or 0
		if height > 0 and tabHeight > 0 then
			for _, key in ipairs(SIDE_LEFT_ORDER) do
				if UI.SideTabsFit(#shown, tabHeight, height) then break end
				for i, tab in ipairs(shown) do
					if tab.key == key then
						onLeft[table.remove(shown, i)] = true
						break
					end
				end
			end
		end
		for _, tab in ipairs(main.tabs) do
			SideTabOnLeft(tab, onLeft[tab])
			if onLeft[tab] then left[#left + 1] = tab end -- (in the tabs' order)
		end
		-- Those tabs stay on the screen too.
		if main.SetClampRectInsets then main:SetClampRectInsets(#left > 0 and -HD_TABS_REACH or 0, HD_TABS_REACH, 0, 0) end
	end
	for i, tab in ipairs(shown) do
		tab:ClearAllPoints()
		tab:SetPoint(UI.TabAnchor(main.tabStyle, i, main, shown[i - 1]))
	end
	for i = #left, 1, -1 do
		local tab = left[i]
		tab:ClearAllPoints()
		if i == #left then
			tab:SetPoint("BOTTOMRIGHT", main, "BOTTOMLEFT", 0, SIDE_LEFT_UP)
		else
			tab:SetPoint("BOTTOMRIGHT", left[i + 1], "TOPRIGHT", 0, SIDE_GAP)
		end
	end
	if main.tabStyle == "side" then return end
	local resize = PanelTemplates_TabResize
	local natural, total = {}, 0
	for i, tab in ipairs(shown) do
		if resize and not tab.isFallback then pcall(resize, tab, 0) end
		natural[i] = tab:GetWidth() or 0
		total = total + natural[i]
	end
	-- Where the first one starts and how they sit (UI.TabAnchor): overlapping on Classic.
	local first, gap = 10, -15
	if main.tabStyle == "mainline" then first, gap = 5, 3 end
	local gaps = gap * (#shown - 1)
	local room = (main:GetWidth() or 0) - first - 6
	if room <= 0 or total + gaps <= room then return end
	local scale = (room - gaps) / total
	for i, tab in ipairs(shown) do
		local width = math.max(44, math.floor(natural[i] * scale))
		if resize and not tab.isFallback then pcall(resize, tab, 0, width) end
		tab:SetWidth(width)
	end
end

-- The small line drops to the tiny font (9 pt, also white) before it is cut: the census
-- line with a long realm name is just over the width of Forever's window.
local function FitHeader()
	local room = main:GetWidth() - main.headerX
	FitText(main.total, room - HEADER_RIGHT, { "GameFontNormalLarge", "GameFontNormal" })
	FitText(main.sub, room - SUB_RIGHT, { "GameFontHighlightSmall", "GameFontWhiteTiny" })
	if main.headerHover then main.headerHover:SetWidth(math.max(40, room - HEADER_RIGHT)) end
end

-- Positions that depend on the window width (buttons, columns, list width) and on
-- membership (the Join screen has no column titles).
function UI.Layout()
	if not main then return end
	local g = GEOMETRY[main.style]
	local w = main:GetWidth()
	LayoutButtons()
	LayoutDetailButtons()
	FitHeader()
	main.layoutLocked = not ns.IsMember()
	local hasCols = not main.layoutLocked and ns.Views.COLUMNS[main.tab] ~= nil and main.tab == "census"
	main.colHeader:SetShown(hasCols)
	-- The Chat tab: the header's counts, the list and the detail box give their place to its parts.
	local chat = not main.layoutLocked and main.tab == "chat" and ChatPaneReady()
	for _, key in ipairs({ "total", "sub", "headerHover", "listBox", "scroll", "detail" }) do
		if main[key] then main[key]:SetShown(not chat) end
	end
	-- The HD list box starts right under the column titles, higher without them.
	if g.box.topNoCols and main.listBox then
		main.listBox:ClearAllPoints()
		main.listBox:SetPoint("TOPLEFT", g.box.left, hasCols and g.box.top or g.box.topNoCols)
		main.listBox:SetPoint("BOTTOMRIGHT", g.box.right, g.box.bottom)
	end
	local right = main.scrollRight or g.scroll.right
	main.scroll:ClearAllPoints()
	main.scroll:SetPoint("TOPLEFT", g.scroll.left, hasCols and g.scroll.top or g.scroll.topNoCols)
	main.scroll:SetPoint("BOTTOMRIGHT", right, g.scroll.bottom)
	local listW = w - g.scroll.left + right - 2
	for _, v in pairs(main.views) do v:SetWidth(listW) end
	if hasCols then
		local layout = ns.Views.COLUMNS[main.tab]
		local x = 0
		for c, b in ipairs(main.colHeader.buttons) do
			local col = layout[c]
			if col then
				local width = math.floor(col.w * (listW + 4))
				b:ClearAllPoints()
				b:SetPoint("TOPLEFT", main.colHeader, "TOPLEFT", x, 0)
				-- The old headers' middle part is sized by Blizzard's code; the HD ones stretch.
				if (main.style == "old" or b.whoTemplate) and WhoFrameColumn_SetWidth then pcall(WhoFrameColumn_SetWidth, b, width) else b:SetWidth(width) end
				b:SetWidth(width)
				b:SetText(L[col.key])
				b.sortKey = col.sort
				b:Show()
				x = x + width - 2
			else
				b:Hide()
			end
		end
	end
end

StaticPopupDialogs["SYLVANISTAS_DECREE"] = {
	text = "%s",
	button1 = ACCEPT or "Accept",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	maxLetters = 100,
	OnShow = function(self)
		local eb = self.editBox or self.EditBox
		if eb then eb:SetText("") eb:SetFocus() end
	end,
	OnAccept = function(self, kind)
		local eb = self.editBox or self.EditBox
		ns.SafeCall("decree send", ns.Decree.Send, kind, eb and eb:GetText() or "")
	end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		ns.SafeCall("decree send", ns.Decree.Send, parent.data, self:GetText())
		parent:Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs["SYLVANISTAS_CLEAR_INSPECT"] = {
	text = "Sylvanistas: clear every inspection result?",
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function() ns.SafeCall("clear inspect", ns.Inspect.Clear) end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local function SetButtons(list, defs)
	for i, b in ipairs(list) do
		local def = defs and defs[i]
		if def then
			local label = def.label and def.label() or L[def[1]]
			if def[1] == "PATROL_BTN" then label = ns.Inspect.IsPatrolling() and L.PATROL_STOP or L.PATROL_START end
			b:SetText(label)
			b:SetScript("OnClick", function()
				ns.SafeCall("button " .. def[1], def[2])
				-- A button that shows a state (def.label) shows the new one at once.
				if def.refresh then UI.Refresh() end
				UI.Clicked()
			end)
			local tip = rawget(L, def[1] .. "_TIP")
			local onEnter
			if def.tooltip then
				onEnter = function(self)
					GameTooltip:SetOwner(self, "ANCHOR_TOP")
					ns.SafeCall("button tooltip " .. def[1], def.tooltip, GameTooltip)
					GameTooltip:Show()
				end
			elseif tip then
				onEnter = function(self)
					GameTooltip:SetOwner(self, "ANCHOR_TOP")
					GameTooltip:AddLine(label, 1, 0.82, 0)
					GameTooltip:AddLine(tip, 1, 1, 1, true)
					GameTooltip:Show()
				end
			end
			b:SetScript("OnEnter", onEnter)
			b:SetScript("OnLeave", function() GameTooltip:Hide() end)
			b:Show()
			FitLabel(b)
			-- Under the mouse while its state changed (it was just clicked): the new tooltip.
			if onEnter and GameTooltip.IsOwned and GameTooltip:IsOwned(b) then onEnter(b) end
		else
			b:Hide()
		end
	end
	if list == main.buttons then LayoutButtons() end
	if list == main.detailButtons then LayoutDetailButtons() end
end

-- Shows tab `key` in the window in use, and the window if it is closed. `focus`: the id of the
-- row it opens on (Views.lua: a guild clicked in the Census), in sight (UI.KeepPlace).
local function ShowTab(key, focus)
	if key ~= "realm" and ns.Views.CloseChat then ns.Views.CloseChat() end
	main.tab = key
	for k, v in pairs(main.views) do v:SetShown(k == key) end
	main.scroll:SetScrollChild(main.views[key])
	main.scroll:SetVerticalScroll(0)
	-- A tab opened: its list starts at the top, or at the row it opens on (UI.KeepPlace).
	main.page, main.wantScroll, main.focus = nil, nil, focus
	-- The Throne is a page of parchment with dark ink (the rows use line.font).
	if key == "throne" and not main.parchment then
		local p = main.scroll:CreateTexture(nil, "BACKGROUND")
		p:SetAllPoints(main.scroll)
		local file = UI.FirstTexture(UI.PARCHMENTS)
		if GetFileIDFromPath and not GetFileIDFromPath(file) then
			p:SetColorTexture(0.87, 0.80, 0.64, 0.97)
		else
			p:SetTexture(file)
			-- QuestBG holds its parchment in the top left 296 x 331 of a 512 x 512 file.
			if file:find("QuestBG", 1, true) then p:SetTexCoord(0, 296 / 512, 0, 331 / 512) end
		end
		main.parchment = p
	end
	if main.parchment then main.parchment:SetShown(key == "throne") end
	for i, tab in ipairs(main.tabs) do
		if main.tabStyle == "side" then
			-- The HD window's icon tabs: the selected one stays checked.
			tab:SetChecked(tab.key == key)
			if tab.key == key then main.selectedTab = i end
		elseif tab.isFallback then
			-- Plain buttons: the selected one stays lit and uses white text.
			if tab.key == key then
				tab:LockHighlight()
				tab:SetNormalFontObject("GameFontHighlight")
				main.selectedTab = i
			else
				tab:UnlockHighlight()
				tab:SetNormalFontObject("GameFontNormal")
			end
		elseif tab.key == key then
			if PanelTemplates_SelectTab then pcall(PanelTemplates_SelectTab, tab) end
			main.selectedTab = i
		elseif PanelTemplates_DeselectTab then
			pcall(PanelTemplates_DeselectTab, tab)
		end
	end
	UI.Layout()
	if not main:IsShown() then main:Show() end
	UI.Refresh()
end

-- Every click in the window (and the ones that open it) also runs the next /who of the
-- round (Who.Auto): the census and the Join screen fill without Refresh. Only from clicks
-- and slash commands, never from a timer: the game takes /who from a hardware event only.
function UI.Clicked()
	ns.SafeCall("auto who", ns.Who.Auto)
end

-- Opening the window picks its look again, from the guild window in use (UI.Style).
-- Called from clicks and slash commands only (UI.Clicked). `focus`: see ShowTab.
function UI.SelectTab(key, focus)
	if not (main and main:IsShown()) then UseStyle(UI.Style()) end
	ShowTab(key, focus)
	UI.Clicked()
end

-- Whose census this is: our realm, or the realms sharing it ("A + B").
function UI.CensusName()
	local group = ns.group or ns.realm
	if #ns.GroupRealms(group) > 1 then return (group:gsub("%+", " + ")) end
	return GetRealmName and GetRealmName() or ""
end

---------------------------------------------------------------------------
-- The list keeps its place (1.0.0). A redraw (a row opened or closed, "Show more", a report
-- coming in) leaves the list where it was: the row clicked stays where it was on screen, and
-- when it opened, its first rows below come into sight if they fell under the list's bottom
-- edge (the row itself never leaves the top). Only another tab, or another page of one (the
-- Realm's chats, the Throne's pages, the Treasury's book), starts at the top; a tab opened on
-- a row (a guild clicked in the Census opens in the Realm) starts at that row.
---------------------------------------------------------------------------

UI.SHOW_BELOW = 3  -- rows under an opened row brought into sight
UI.CLICK_KEEP = 2  -- seconds a click waits for the redraw it causes (RefreshSoon, DATA_CHANGED)
UI.PLACE_HOLD = 1  -- seconds a redraw's place is given again when the client measures the list

-- Which page of its tab the list shows: another one starts at the top.
local function PageOf(tab, locked)
	if locked then return "join" end
	local sub
	if tab == "realm" then
		-- (1.1: our guild's members page, Members.lua, a page of its own.)
		sub = (ns.Views.BoardShown and ns.Views.BoardShown() and "board") or (ns.Views.PageShown and ns.Views.PageShown()) or ns.Members and ns.Members.PageId and ns.Members.PageId() or "tree"
	elseif tab == "throne" then sub = ns.King and ns.King.mode
	elseif tab == "treasury" then sub = ns.Treasury and ns.Treasury.mode end
	return tab .. "/" .. tostring(sub or "")
end

-- 1.1.2: the page shown now ("census/", "realm/tree", "treasury/book", "join"...), for its "?".
function UI.PageId()
	if not main then return nil end
	return PageOf(main.tab, not ns.IsMember())
end

-- The "?" of the page shown (Answers.lua).
function UI.ExplainPage()
	if not (ns.Answers and ns.Answers.ExplainPage) then return false end
	return ns.Answers.ExplainPage(UI.PageId() or "census/")
end

local function Clamp(v, lo, hi) return math.max(lo, math.min(v, hi)) end

-- The shown row of `content` whose line has id `id`.
local function RowWithId(content, id)
	for _, r in ipairs(content.rows or {}) do
		if r:IsShown() and r.line and r.line.id == id then return r end
	end
end

-- The list just drawn in `content` goes back to `offset`, the row clicked (Views.TakeClick) to
-- where it was on screen; on another page, to the top, or to the row `focus` (the id of the
-- row the tab opened on, ShowTab) when it and its first rows are not in sight there. The scroll
-- range is taken from the heights (the client measures it again only when it next draws:
-- UI.HoldPlace then).
function UI.KeepPlace(content, offset, click, page, focus)
	local scroll = main.scroll
	local view = scroll:GetHeight() or 0
	local want = 0
	if page == main.page then
		want = offset
		local rows = content.rows or {}
		local r = click and GetTime() - (click.t or 0) <= UI.CLICK_KEEP and rows[click.index]
		-- The list moved since the click, and not to the top (where the client throws it): the
		-- player scrolled (the scroll bar; the wheel forgets the click, UI.Scrolled), and this is
		-- not the redraw the click caused. His offset stays.
		if r and click.offset and offset > 0.5 and math.abs(offset - click.offset) > 0.5 then r = nil end
		if r and r:IsShown() and r.top then
			-- Where it was on screen when clicked (whatever the offset did since).
			want = (click.offset or offset) + (r.top - (click.top or 0))
			-- It opened (the list grew): the rows under it into sight, the row staying in.
			local n = content.lineCount or 0
			local last = n > (click.lines or 0) and rows[math.min(click.index + UI.SHOW_BELOW, n)]
			if last and last.top and view > 0 then
				local bottom = last.top + (last:GetHeight() or 0)
				if bottom > want + view then want = math.min(bottom - view, r.top) end
			end
		end
	elseif focus then
		-- Opened on a row: at the top of the list, unless it and its first rows are in sight
		-- from the top already.
		local r = RowWithId(content, focus)
		if r and r.top then
			local rows, n = content.rows or {}, content.lineCount or 0
			local last = r.index and rows[math.min(r.index + UI.SHOW_BELOW, n)] or r
			local bottom = (last.top or r.top) + (last:GetHeight() or 0)
			if bottom > view then want = r.top end
		end
	end
	main.page = page
	want = Clamp(want, 0, math.max(0, (content:GetHeight() or 0) - (scroll:GetHeight() or 0)))
	main.wantScroll, main.wantAt = want, GetTime()
	scroll:SetVerticalScroll(want)
end

-- The client measured the list again (OnScrollRangeChanged, after Blizzard's own handler): the
-- place the last redraw gave it, if the offset moved away from it, within a moment of that
-- redraw only (later on, the offset is the player's own scrolling).
function UI.HoldPlace(frame, scroll)
	local want = frame == main and frame.wantScroll
	if not want or GetTime() - (frame.wantAt or 0) > UI.PLACE_HOLD then return end
	want = Clamp(want, 0, scroll:GetVerticalScrollRange() or 0)
	if math.abs((scroll:GetVerticalScroll() or 0) - want) > 0.5 then scroll:SetVerticalScroll(want) end
end

-- The player scrolled the list of `frame` himself (the mouse wheel): no redraw puts it back where
-- a click, or the last redraw, left it.
function UI.Scrolled(frame)
	for _, v in pairs(frame.views or {}) do v.click = nil end
	frame.wantScroll = nil
end

function UI.Refresh()
	if not main or not main:IsShown() then return end
	UI.lastRedraw = GetTime()
	ns.SafeCall("ui refresh", function()
		local s = ns.Data.Summary()
		local F = ns.FormatNumber
		main.total:SetText(L.ARMY_TOTAL:format(F(s.total)))
		main.sub:SetText(L.ARMY_SUB:format(F(s.online), #s.guilds, ns.Ago(s.newest)) .. "  ·  " .. UI.CensusName())
		-- Right after login (1.1): the census is being rebuilt, and the header says so.
		local heard = ns.Data.Rebuilding and ns.Data.Rebuilding()
		if heard then main.sub:SetText(L.REBUILDING_SUB:format(heard) .. "  ·  " .. UI.CensusName()) end
		-- Outside a Sylvanistas guild nothing but the Join Sylvanistas screen is shown.
		local locked = not ns.IsMember()
		-- Joined or left a guild while the window is open: lay it out again.
		if locked ~= main.layoutLocked then UI.Layout() end
		local lines, title, text
		if locked then
			-- Not a Sylvanistas member yet: the only thing on offer is joining one.
			lines = ns.Views.RecruitLines()
			title, text = L.MEMBERS_ONLY, L.MEMBERS_ONLY_HINT
			local header, sub = ns.Recruit.Roast()
			main.total:SetText(header)
			main.sub:SetText(sub)
		else
			lines, title, text = ns.Views.Build(main.tab)
			-- The treasury next to the soldiers, on the Throne and the Treasury tabs (the King's
			-- and the Treasurer's screens: Treasury.HeaderText).
			if main.tab == "throne" or main.tab == "treasury" then
				local gold = ns.Treasury and ns.Treasury.HeaderText and ns.Treasury.HeaderText()
				if type(gold) == "string" then main.total:SetText(L.ARMY_TOTAL:format(F(s.total)) .. "   " .. gold) end
			end
		end
		FitHeader()
		-- Drawn again where it was (UI.KeepPlace): the offset and the row clicked, taken first.
		local content = main.views[main.tab]
		local offset, click, focus = main.scroll:GetVerticalScroll() or 0, ns.Views.TakeClick(content), main.focus
		main.focus = nil
		ns.Views.Render(content, lines, not locked and ns.Views.COLUMNS[main.tab] or nil)
		UI.KeepPlace(content, offset, click, PageOf(main.tab, locked), focus)
		main.detailTitle:SetText(title or "")
		main.detailText:SetText(text or "")
		SetButtons(main.buttons, locked and RECRUIT_BUTTONS or Shown(BUTTONS[main.tab]))
		local tabsWere = main.tabs[1] and main.tabs[1]:IsShown()
		-- The Throne only for the King, the Workshop only for the addon's author (and their
		-- test builds, King.Preview and Workshop.Preview).
		local only = {
			chat = ChatTabVisible(), -- (1.1.1)
			throne = ns.King and ns.King.Visible and ns.King.Visible() or false,
			vox = ns.Vox and ns.Vox.Visible and ns.Vox.Visible() or false,
			treasury = ns.Treasury and ns.Treasury.TabVisible and ns.Treasury.TabVisible() or false, -- (1.1: the dues' button too)
			workshop = ns.Workshop and ns.Workshop.Visible and ns.Workshop.Visible() or false,
		}
		if only[main.tab] == false then return ShowTab("census") end
		for _, tab in ipairs(main.tabs) do tab:SetShown(not locked and only[tab.key] ~= false) end
		UI.LayoutTabs()
		-- The Chat tab (ChatWindow.lua) over the list's place while it is the one shown.
		ChatPane(not locked and main.tab == "chat")
		local detail = not locked and Shown(DETAIL_BUTTONS[main.tab]) or nil
		SetButtons(main.detailButtons, detail)
		-- Room for the text where no button shows (the Decrees tab has one for the King alone).
		local hasDetailButtons = detail ~= nil and #detail > 0
		main.detailText:SetHeight(DETAIL_H - (hasDetailButtons and 46 or 26))
		-- The tabs just appeared (joined a guild with the window open): they hang below it,
		-- so it steps above the Issue Reporter again.
		if not locked and not tabsWere then ns.SafeCall("issue reporter", ClearOfIssueReporter, MainClearOfIssueReporter) end
	end)
end

-- Glued to the right of `host`, past its side tabs when it shows them (UI.DockOffset).
local function DockTo(host)
	local tab = host.ChatTab
	local shown = tab and tab.IsShown and tab:IsShown() and true or false
	main:ClearAllPoints()
	main:SetPoint("TOPLEFT", host, "TOPRIGHT", UI.DockOffset(main.style, shown), 0)
end

-- Open glued to the right of a Blizzard window (the guild window the button was clicked
-- in), in `style` (its look, see UI.Style), sized by UI.DockSize, and close together with
-- it (GuildFrame.lua hooks that).
function UI.OpenDocked(host, tab, heightOnly, style)
	UseStyle(style or UI.Style())
	main.host, main.heightOnly = host, heightOnly
	main:SetSize(UI.DockSize(host:GetWidth(), host:GetHeight(), heightOnly, SocialSize()))
	DockTo(host)
	main.docked = true
	ShowTab(tab or main.tab or "census")
	UI.Clicked() -- the guild window's button was clicked
end

-- The host was resized while we are docked to it (the Communities window can be
-- minimized and maximized): take its new height. The HD window also keeps clear of the
-- host's side tabs, which come and go (GuildFrame.lua calls this then too).
function UI.FollowHost(host)
	if main and main.docked and main.host == host then
		main:SetSize(UI.DockSize(host:GetWidth(), host:GetHeight(), main.heightOnly, SocialSize()))
		if main.style == "hd" then DockTo(host) end
	end
end

-- Closes the window if it is docked: to `host` when given, to anything otherwise.
function UI.CloseIfDocked(host)
	if main and main.docked and main:IsShown() and (host == nil or main.host == host) then main:Hide() end
end

---------------------------------------------------------------------------
-- Person panel: like the member details the Guild window opens, docked to our window.
-- person = { name, class (code), level, zone (key), guild, rank (label), online, days,
--            note, tabard (status), onMark (function, tabards tab only),
--            realm (the realm the name is short for: a guild report's, not always ours) }
---------------------------------------------------------------------------

-- With the gamepad UI a whisper is written in a Sylvanistas window: the game's chat box, opened from
-- Sylvanistas, runs the game's gamepad code from ours and the game blocks it (see Dialog.lua). With
-- mouse and keyboard, the game's chat box. (A line for a Sylvanistas chat is written in the Chat
-- tab's own box, ChatWindow.lua: the Realm tab's chats page and its window for that are gone.)
local function Trim(text) return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
-- 1.1.2: not while the game holds chat from addons (a dungeon, a raid, an encounter, a PvP
-- match: ns.ChatLocked): the player is told, and the text stays in the box (false). True: sent,
-- or nothing to send.
local function SendWhisper(name, text)
	text = Trim(text)
	if text == "" or not name then return true end
	if ns.ChatLocked() then
		ns.Print(L.WHISPER_LOCKDOWN)
		return false
	end
	SendChatMessage(text:sub(1, 255), "WHISPER", nil, name)
	return true
end
-- A whisper window closed: the Answers list it opened lets go of its box (Answers.lua), which the
-- next Sylvanistas window may reuse.
local function LetGo(self)
	local eb = self and (self.editBox or self.EditBox)
	if ns.Answers and ns.Answers.Release and eb then ns.Answers.Release(eb) end
end
-- The Answers of the author, the High Council and the Stewards (1.1.2, Answers.lua): a button in
-- Sylvanistas's whisper windows that fills their box with a ready answer to edit (Dialog.lua's extra).
local ANSWERS_EXTRA = {
	label = L.ANSWERS_BTN,
	shown = function() return ns.Answers ~= nil and ns.Answers.Allowed ~= nil and ns.Answers.Allowed() == true end,
	onClick = function(self) ns.Answers.Open(self.editBox or self.EditBox) end,
}
StaticPopupDialogs["SYLVANISTAS_WHISPER"] = {
	text = L.WHISPER_TO,
	extra = ANSWERS_EXTRA,
	button1 = SEND_LABEL or "Send",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 320,
	maxLetters = 255,
	maxBytes = 256, -- (255 bytes and the end: the game's chat limit, accents included)
	OnShow = function(self)
		local eb = self.editBox or self.EditBox
		if eb then eb:SetText("") eb:SetFocus() end
	end,
	OnAccept = function(self, name)
		local eb = self.editBox or self.EditBox
		return not SendWhisper(name, eb and eb:GetText()) -- (held: the window stays, its text in it)
	end,
	OnHide = LetGo,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		if SendWhisper(parent.data, self:GetText()) then parent:Hide() end
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
-- (name: the one the server finds.) 1.1.2: the author, the High Council and the Stewards get it in
-- Sylvanistas's own window with mouse and keyboard too, for its Answers button (the game's popup has
-- no room for it); anyone else as before.
function UI.WhisperWindow(name)
	if ANSWERS_EXTRA.shown() and not ns.Dialog.missing then return ns.Dialog.Show("SYLVANISTAS_WHISPER", name, nil, name) end
	return ns.ShowDialog("SYLVANISTAS_WHISPER", name, nil, name)
end

-- A whisper already written, for the player to read, edit and send himself (1.1.2: Tell them about
-- Sylvanistas, Versions.lua). Sylvanistas's own window in both input modes; the text is put in its box and
-- nothing takes the keyboard (the player clicks into it to edit, or presses Send). Nothing is
-- sent until Send (or Enter in its box).
StaticPopupDialogs["SYLVANISTAS_WHISPER_TEXT"] = {
	text = L.WHISPER_TO,
	extra = ANSWERS_EXTRA,
	button1 = SEND_LABEL or "Send",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	editBoxWidth = 380,
	maxLetters = 255,
	maxBytes = 256,
	OnShow = function(self, data)
		local eb = self.editBox or self.EditBox
		if eb then eb:SetText(type(data) == "table" and tostring(data.text or "") or "") end
	end,
	OnAccept = function(self, data)
		local eb = self.editBox or self.EditBox
		return not SendWhisper(type(data) == "table" and data.name or nil, eb and eb:GetText())
	end,
	OnHide = LetGo,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		local data = parent.data
		if SendWhisper(type(data) == "table" and data.name or nil, self:GetText()) then parent:Hide() end
	end,
	EditBoxOnEscapePressed = function(self) self:ClearFocus() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}
function UI.WhisperText(name, text)
	if type(name) ~= "string" or name == "" then return nil end
	if ns.Dialog.missing then
		ns.Print(L.RESTART_NEEDED)
		return nil
	end
	return ns.Dialog.Show("SYLVANISTAS_WHISPER_TEXT", name, nil, { name = name, text = text })
end

-- Whisper, invite and /who take the name the server finds (ns.TellName).
local function Whisper(name)
	name = ns.TellName(name)
	if ns.GamepadUI() then return UI.WhisperWindow(name) end
	if ChatFrame_SendTell then ChatFrame_SendTell(name) else ChatFrame_OpenChat("/w " .. name .. " ") end
end

local function Invite(name)
	name = ns.TellName(name)
	if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(name) elseif InviteUnit then InviteUnit(name) end
end

-- Through Who.lua, which keeps it apart from our quiet /who searches (see SendPlain).
local function Who(name)
	ns.Who.SendPlain(('n-"%s"'):format(ns.TellName(name)))
end

local function PersonButtonScripts(f)
	-- The whole name (a report's names are short for its sender's realm), made the one the
	-- server finds by Whisper, Invite and Who.
	local function Target() local p = f.person return p.realm and ns.FullName(p.name, p.realm) or p.name end
	f.whisper:SetScript("OnClick", function() ns.SafeCall("whisper", Whisper, Target()) end)
	f.invite:SetScript("OnClick", function() ns.SafeCall("invite", Invite, Target()) end)
	f.who:SetScript("OnClick", function() ns.SafeCall("who", Who, Target()) end)
	f.mark:SetScript("OnClick", function()
		if f.person.onMark then ns.SafeCall("mark", f.person.onMark) end
		f:Hide()
	end)
end

local function CreatePersonFrame()
	local f = CreateFrame("Frame", "SylvanistasPersonFrame", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(230, 210)
	f:SetFrameStrata("MEDIUM")
	f:SetToplevel(true)
	-- Guild window + our window + this card can run past the right edge (the Communities
	-- window alone is 814 wide).
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:Hide()
	ns.EscapeCloses("SylvanistasPersonFrame")
	f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.name:SetPoint("TOPLEFT", 14, -32)
	f.name:SetPoint("TOPRIGHT", -14, -32)
	f.name:SetJustifyH("LEFT")
	f.name:SetWordWrap(false) -- a long Name-Realm is fitted (UI.ShowPerson), not wrapped over the lines below
	if f.TitleText then
		-- "<guild name>", centred: kept clear of the close button on both sides.
		f.TitleText:SetWidth(f:GetWidth() - 64)
		f.TitleText:SetWordWrap(false)
	end
	f.lines = {}
	for i = 1, 6 do
		local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("TOPLEFT", 14, -54 - (i - 1) * 15)
		fs:SetPoint("RIGHT", -14, 0)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		f.lines[i] = fs
	end
	local function Btn(label, x, y, w)
		local b = Button(f, w, 22)
		b:SetPoint("BOTTOMLEFT", x, y)
		b:SetText(label)
		FitLabel(b)
		return b
	end
	f.whisper = Btn(L.WHISPER, 10, 34, 104)
	f.invite = Btn(L.INVITE, 116, 34, 104)
	f.who = Btn(L.WHO, 10, 10, 104)
	f.mark = Btn(L.MARK_BTN, 116, 10, 104)
	PersonButtonScripts(f)
	return f
end

-- The row a person panel was opened from stays lit while it is open (Views.Select): the
-- HD window's rows let go when it closes.
local function ClearHDSelection()
	ns.SafeCall("person panel hide", function()
		for _, v in pairs(frames.hd and frames.hd.views or {}) do ns.Views.ClearSelection(v) end
	end)
end

-- The HD window's panel: the Guild & Communities window's member card
-- (CommunitiesGuildMemberDetailFrameTemplate, GuildRoster.xml): a dark dialog box hanging
-- off the window's right side under its first tab (the left side where the screen ends,
-- see UI.ShowPerson), the name on top, small buttons at the
-- bottom, above everything of the window (Blizzard's is at level 1000). A child of the HD
-- window, as Blizzard's is of theirs. Its box is a child too, like Blizzard's Border: the
-- dialog border template takes its parent's level, so the panel keeps its own. nil when
-- the client lacks that template (the old panel is used then).
local function CreatePersonFrameHD()
	local parent = frames.hd
	if not parent then return nil end
	local f = CreateFrame("Frame", "SylvanistasPersonFrameHD", parent)
	local okBorder, border = pcall(CreateFrame, "Frame", nil, f, "DialogBorderDarkTemplate")
	if not (okBorder and border and border.Bg) then
		if okBorder and border then border:Hide() end
		f:Hide()
		ns.Log("DialogBorderDarkTemplate unavailable, using the old person panel")
		return nil
	end
	border:SetAllPoints()
	f.Border = border
	f.hd = true
	f:SetSize(214, 226)
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:SetFrameLevel(parent:GetFrameLevel() + 1000)
	f:Hide()
	ns.EscapeCloses("SylvanistasPersonFrameHD")
	local okClose, close = pcall(CreateFrame, "Button", nil, f, "UIPanelCloseButton")
	if okClose and close then
		close:ClearAllPoints()
		close:SetPoint("TOPRIGHT", -3, -4)
		close:SetFrameLevel(f:GetFrameLevel() + 2)
		close:SetScript("OnClick", function() f:Hide() end)
		f.CloseButton = close
	end
	-- Name, then "<guild>" under it where the old panel has it in its title bar.
	f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.name:SetPoint("TOPLEFT", 13, -18)
	f.name:SetPoint("TOPRIGHT", -30, -18)
	f.name:SetJustifyH("LEFT")
	f.name:SetWordWrap(false)
	f.nameRoom, f.nameFonts = 214 - 13 - 30, { "GameFontNormal", "GameFontNormalSmall" }
	f.guild = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.guild:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -2)
	f.guild:SetPoint("RIGHT", -13, 0)
	f.guild:SetJustifyH("LEFT")
	f.guild:SetWordWrap(false)
	f.lines = {}
	for i = 1, 6 do
		local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("TOPLEFT", 13, -52 - (i - 1) * 15)
		fs:SetPoint("RIGHT", -13, 0)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		f.lines[i] = fs
	end
	-- Blizzard's card buttons: 96 x 22, small font, 1 apart.
	local function Btn(label)
		local b = Button(f, 96, 22)
		b.small = true
		SetButtonFont(b, true)
		b:SetText(label)
		FitLabel(b)
		return b
	end
	f.whisper = Btn(L.WHISPER)
	f.whisper:SetPoint("BOTTOMLEFT", 12, 36)
	f.invite = Btn(L.INVITE)
	f.invite:SetPoint("LEFT", f.whisper, "RIGHT", 1, 0)
	f.who = Btn(L.WHO)
	f.who:SetPoint("BOTTOMLEFT", 12, 12)
	f.mark = Btn(L.MARK_BTN)
	f.mark:SetPoint("LEFT", f.who, "RIGHT", 1, 0)
	PersonButtonScripts(f)
	f:SetScript("OnHide", ClearHDSelection)
	return f
end

-- The panel for the window in `style`, created on first use. The old one standing in for
-- the HD one lets the HD rows go too when it closes.
local function PersonFrame(style)
	if not personFrames[style] then
		local f = style == "hd" and CreatePersonFrameHD()
		if not f then
			personFrames.old = personFrames.old or CreatePersonFrame()
			f = personFrames.old
			if style == "hd" then f:HookScript("OnHide", ClearHDSelection) end
		end
		personFrames[style] = f
	end
	return personFrames[style]
end

function UI.ShowPerson(p)
	if not p or not p.name then return end
	-- The HD panel lives in the HD window: with no window open, the old one (at the centre).
	local open = main and main:IsShown()
	local f = PersonFrame(open and main.style or "old")
	f.person = p
	local file = p.class and ns.CLASS_FILES[p.class] or p.class
	local color = file and RAID_CLASS_COLORS and RAID_CLASS_COLORS[file]
	-- The name, guild and rank may come from other players' reports: plain text, whatever
	-- they carry (0.9.2; Comm.lua already strips every escape code from what arrives).
	local name, guild = ns.Codec.Plain(p.name), p.guild and ns.Codec.Plain(p.guild)
	-- A High Councillor: the mark and their own icon after the name, and their title below
	-- (0.9.9), for whoever may see the council in the census (ns.CouncilVisible); not on the
	-- King's screen while the councillors' names are hidden there (ns.CouncilMasked).
	local full = ns.FullName(p.name, p.realm)
	local councillor = ns.CouncilVisible() and not ns.CouncilMasked() and ns.IsHighCouncillor(full)
	f.name:SetText((color and ("|c%s%s|r"):format(color.colorStr, name) or name) .. (councillor and (" " .. ns.CouncilMark(full)) or ""))
	FitText(f.name, f.nameRoom or (f:GetWidth() - 28), f.nameFonts or { "GameFontNormalLarge", "GameFontNormal" })
	if f.guild then
		f.guild:SetText(guild and ("<" .. guild .. ">") or "")
	elseif f.TitleText then
		f.TitleText:SetText(guild and ("<" .. guild .. ">") or L.TITLE)
	end
	local className = (file and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[file]) or ""
	local rows = {}
	if p.level or className ~= "" then rows[#rows + 1] = (p.level and (L.LEVEL_N:format(p.level) .. " ") or "") .. className end
	if p.rank then rows[#rows + 1] = "|cffffd200" .. ns.Codec.Plain(p.rank) .. "|r" end
	if ns.IsTreasurer(p.name, p.guild) then rows[#rows + 1] = "|cffffd200" .. ns.COIN .. L.TREASURER_TITLE .. "|r" end
	if councillor then
		-- "High Councillor - <title> (<department>)", as the signed titles list gives them.
		local t = ns.CouncilTitle(full) or {}
		rows[#rows + 1] = ns.HIGH_COUNCIL_MARK .. " |c" .. ns.HIGH_COUNCIL_COLOR .. L.COUNCIL_PERSON
			.. (t.title and (" - " .. ns.Codec.Plain(t.title)) or "") .. (t.dept and (" (" .. ns.Codec.Plain(t.dept) .. ")") or "") .. "|r"
	end
	if p.online then
		rows[#rows + 1] = "|cff40ff40" .. L.ONLINE_NOW .. "|r" .. (p.zone and ("  -  " .. ns.Zones.NameForKey(p.zone)) or "")
	elseif p.online == false then
		rows[#rows + 1] = "|cff9d9d9d" .. ((p.days or 0) >= 1 and L.OFFLINE_DAYS:format(math.floor(p.days)) or L.OFFLINE_TODAY) .. "|r"
	end
	-- 1.1.2: their Sylvanistas version, when this client knows it (Versions.lua; the same line as the
	-- right-click menu's). Nothing is asked by opening the card.
	local version = ns.Versions and ns.Versions.CardLine and ns.Versions.CardLine(full)
	if version then rows[#rows + 1] = "|cff9d9d9d" .. version .. "|r" end
	if p.tabard then rows[#rows + 1] = L.TABARD .. ": " .. p.tabard end
	if p.note then rows[#rows + 1] = '|cffff8080"' .. p.note .. '"|r' end
	for i, fs in ipairs(f.lines) do fs:SetText(rows[i] or "") end
	f.mark:SetShown(p.onMark ~= nil)
	f.invite:SetEnabled(p.online ~= false)
	f.whisper:SetEnabled(p.online ~= false)
	f:ClearAllPoints()
	if open and f.hd then
		-- Where the Guild & Communities window hangs its card (-8, -76), less its box's 4 px
		-- inset. Past the screen's right edge (docked to the maximized Communities window on a
		-- 1366 wide UI) it hangs off the left side instead, over the gap between the windows:
		-- like Blizzard's, it never covers the list it was opened from.
		local win, screen = ScreenRect(main), ScreenRect(UIParent)
		local reach = (f:GetWidth() - 4) * main:GetEffectiveScale()
		if win and screen and win.right + reach > screen.right and win.left - reach >= screen.left then
			f:SetPoint("TOPRIGHT", main, "TOPLEFT", 4, -76)
		else
			f:SetPoint("TOPLEFT", main, "TOPRIGHT", -4, -76)
		end
	elseif open then
		f:SetPoint("TOPLEFT", main, "TOPRIGHT", -2, -28)
	else
		f:SetPoint("CENTER")
	end
	f:Show()
	-- Placed again on every show, so it can step above the Issue Reporter every time.
	ns.SafeCall("issue reporter", ClearOfIssueReporter, function() return StepAboveIssueReporter(f, { f }) end)
end

-- The King hides the councillors' names again (the eye in the Realm, Views.lua): a councillor's
-- card left open from while they were shown closes, with the mark and title it carries.
function UI.CloseCouncilCards()
	for _, f in pairs(personFrames) do
		local p = f.person
		if p and p.name and f:IsShown() and ns.IsHighCouncillor(ns.FullName(p.name, p.realm)) then f:Hide() end
	end
end

function UI.IsShown() return main and main:IsShown() end
function UI.DockedTo() return main and main.docked and main.host or nil end
-- "old" or "hd": the look of the window in use (nil before the first open), for /syl status.
function UI.WindowStyle() return main and main.style end

function UI.StatusLine()
	local guild = GetGuildInfo("player")
	if not guild then return L.STATUS_NOGUILD end
	if not ns.IsFederation(guild) then return L.STATUS_NOTFED:format(guild) end
	local c = ns.Comm
	local users = c.PeerCount() + 1
	if c.isReporter or not c.reporterName then return L.STATUS_REPORTER:format(guild, users) end
	return L.STATUS_PEER:format(guild, c.reporterName, users)
end

function UI.Toggle()
	if main and main:IsShown() then
		main:Hide()
		return
	end
	UI.SelectTab(main and main.tab or "census")
end

-- Reports come in bursts (every guild answers a census request within seconds, a patrol
-- inspects a crowd): the window redraws at once for the first news and then at most once
-- every REDRAW_GAP, so a busy channel never redraws it dozens of times a second.
UI.REDRAW_GAP = 0.5
local redrawQueued = false
function UI.RefreshSoon()
	if not main or not main:IsShown() or redrawQueued then return end
	local wait = UI.REDRAW_GAP - (GetTime() - (UI.lastRedraw or 0))
	if wait <= 0 then return UI.Refresh() end
	redrawQueued = true
	ns.After(wait, "ui redraw", function()
		redrawQueued = false
		UI.Refresh()
	end)
end

-- Typed into a tab's search box (Views.SetFilter): that list again, soon. A search that starts
-- (the box was empty) shows its list from the top; while the player goes on typing, or empties
-- the box, the list stays where it was scrolled to.
function UI.FilterChanged(tab, fromTop)
	if not (main and main:IsShown() and main.tab == tab) then return end
	-- From the top, and the top is now the place the client's next measure keeps (UI.HoldPlace).
	if fromTop then
		main.wantScroll, main.wantAt = 0, GetTime()
		main.scroll:SetVerticalScroll(0)
	end
	UI.RefreshSoon()
end

ns.On("DATA_CHANGED", function() UI.RefreshSoon() end)
ns.On("MAP_TOGGLED", function() UI.Refresh() end)
ns.On("INSPECT_CHANGED", function() if main and main.tab == "heraldry" then UI.RefreshSoon() end end)
-- Layers show in the Realm tab, and the King's layer line tops the Census and the Realm.
ns.On("LAYERS_CHANGED", function()
	if main and (main.tab == "decrees" or main.tab == "realm" or main.tab == "census") then UI.RefreshSoon() end
end)
ns.On("HOP_CHANGED", function() if main and (main.tab == "census" or main.tab == "realm") then UI.RefreshSoon() end end)
ns.On("DECREES_CHANGED", function() UI.RefreshSoon() end)
-- The King's calls show on the Throne, the roll call in the Realm, the inspection in the Tabards.
ns.On("THRONE_CHANGED", function()
	if main and (main.tab == "throne" or main.tab == "realm" or main.tab == "heraldry") then UI.RefreshSoon() end
end)
ns.On("VOX_CHANGED", function() if main and main.tab == "vox" then UI.RefreshSoon() end end)
-- The Treasurer's book and report: his tab, the King's Throne, the Realm's line under him.
ns.On("TREASURY_CHANGED", function()
	if main and (main.tab == "treasury" or main.tab == "throne" or main.tab == "realm") then UI.RefreshSoon() end
end)
-- The court's line tops the Census and the Realm for the players in its zone.
ns.On("COURT_CHANGED", function() if main and (main.tab == "census" or main.tab == "realm") then UI.RefreshSoon() end end)
-- A page of the Realm tab changed (1.1: the loot notes, the crafters' board): redrawn while it shows.
ns.On("REALM_PAGE_CHANGED", function(key)
	if main and main.tab == "realm" and ns.Views.PageShown and ns.Views.PageShown() == key then UI.RefreshSoon() end
end)
ns.On("WORKSHOP_CHANGED", function() if main and main.tab == "workshop" then UI.RefreshSoon() end end)
ns.On("RECRUIT_CHANGED", function() UI.RefreshSoon() end)
-- The screen or the UI scale changed: the window's width in pixels did too, so the tabs
-- under it are laid out again (they shrink to fit it, UI.LayoutTabs).
local function Relayout()
	if not main then return end
	UI.Layout()
	UI.LayoutTabs()
end
ns.RegisterEvent("DISPLAY_SIZE_CHANGED", function() ns.SafeCall("relayout", Relayout) end)
ns.RegisterEvent("UI_SCALE_CHANGED", function() ns.SafeCall("relayout", Relayout) end)

---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Copy box (Discord text, bug report, help)
---------------------------------------------------------------------------

-- The bug report, with "Send to <author>" while the addon's author is online (Workshop.lua).
function UI.ShowBugReport()
	local text = ns.BuildBugReport()
	UI.ShowCopy(L.REPORT_BUG, text, ns.Workshop and ns.Workshop.BugAction and ns.Workshop.BugAction(text) or nil)
end

-- Where the addon lives: its code and issues (the toc's X-Website), its CurseForge page.
UI.LINKS = {
	github = "https://github.com/CHANGEME/sylvanistas-addon",
	issues = "https://github.com/CHANGEME/sylvanistas-addon/issues",
	curseforge = "https://www.curseforge.com/wow/addons/CHANGEME-sylvanistas",
}

-- The help button's page: the version, the tabs in a line each, then the lines /syl help prints
-- for the privacy switches and the chats (the same strings, so they never disagree), and the
-- links. In the copy box, so a link can be copied; its button is Report a bug.
function UI.ShowHelp()
	local lines = {
		L.TITLE .. " " .. tostring(ns.VERSION),
		"",
		L.HELP_TABS,
		"  " .. L.TAB_CENSUS .. ": " .. L.HELP_TAB_CENSUS,
		"  " .. L.TAB_REALM .. ": " .. L.HELP_TAB_REALM,
		"  " .. L.TAB_CHAT .. ": " .. L.HELP_TAB_CHAT,
		"  " .. L.TAB_DECREES .. ": " .. L.HELP_TAB_DECREES,
		"  " .. L.TAB_HERALDRY .. ": " .. L.HELP_TAB_HERALDRY,
		"  " .. L.HELP_TAB_OTHERS,
		"",
		L.HELP_ALL_COMMANDS,
		"",
		L.HELP_PRIVACY,
		L.HELP_LOCATION,
		L.HELP_ROLLCALL,
		L.HELP_INSPECTION,
		L.HELP_CHAT,
		L.HELP_PRIVACY_PAGE,
		L.HELP_FILTER,
		L.HELP_LOG,
		L.HELP_BACKUP,
		"",
		L.HELP_CHATS,
		L.HELP_CHAN_ALL,
		L.HELP_CHAN_CAPTAINS,
		L.HELP_CHAN_LORDS,
		L.HELP_CHATWIN,
		"",
		L.HELP_LINKS,
		"  GitHub: " .. UI.LINKS.github,
		"  " .. L.HELP_ISSUES .. ": " .. UI.LINKS.issues,
		"  CurseForge: " .. UI.LINKS.curseforge,
	}
	UI.ShowCopy(L.HELP_TITLE, table.concat(lines, "\n"), { label = L.REPORT_BUG, fn = function() UI.ShowBugReport() end })
end

-- action: an optional { label, fn } button at the bottom (fn returns true once done).
-- What is copied goes to Discord, and names in it come from other players: it pings nobody
-- (0.9.2, Codec.NoMentions).
-- opts (1.1.2): { key = a window of its own (the author's bug reports "bug", his version checks
-- "versions", his /syl status "status"; the help and every Copy share "copy"), big = larger, with
-- a Select all button (the reports: long, and read before copied), auto = opened by itself (no
-- keyboard: see the end) }. Each key's window keeps its place and text while another one shows.
local copyFrames = {}
local COPY_PLACES = { bug = { 0, 30 }, versions = { 60, -30 }, status = { -60, 30 } }

local function CopyFrame(key, big)
	if copyFrames[key] then return copyFrames[key] end
	local name = key == "copy" and "SylvanistasCopyFrame" or ("SylvanistasCopyFrame" .. key:sub(1, 1):upper() .. key:sub(2))
	local w, h = big and 680 or 520, big and 460 or 340
	local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(w, h)
	local place = COPY_PLACES[key] or { 30, -30 }
	if key == "copy" then f:SetPoint("CENTER") else f:SetPoint("CENTER", place[1], place[2]) end
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		self.movedByPlayer = true -- where the player puts it, it stays
	end)
	ns.EscapeCloses(name)
	-- (1.1.2) Its X hides it itself, in combat too (the template's HideUIPanel does nothing there
	-- for a call that is not secure: the author's report may open in the middle of a fight).
	f.onCloseCallback = function()
		f:Hide()
		return false
	end
	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("BOTTOM", 0, 10)
	hint:SetText(L.COPY_HINT)
	f.hint = hint
	local scroll = CreateFrame("ScrollFrame", name == "SylvanistasCopyFrame" and "SylvanistasCopyScroll" or (name .. "Scroll"), f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -30)
	scroll:SetPoint("BOTTOMRIGHT", -30, 28)
	local eb = CreateFrame("EditBox", nil, scroll)
	eb:SetMultiLine(true)
	eb:SetFontObject(ChatFontNormal)
	eb:SetWidth(w - 50)
	eb:SetHeight(h - 60)
	eb:SetAutoFocus(false)
	eb:SetScript("OnEscapePressed", function() f:Hide() end)
	eb:SetScript("OnTextChanged", function(self, userInput)
		if userInput then -- read only
			self:SetText(f.text or "")
			self:HighlightText()
		end
	end)
	scroll:SetScrollChild(eb)
	f.eb = eb
	f.action = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.action:SetSize(160, 20)
	f.action:SetPoint("BOTTOMLEFT", 10, 6)
	f.action:SetScript("OnClick", function(self)
		ns.SafeCall("copy action", function()
			if self.fn and self.fn() then self:Disable() end
		end)
	end)
	if big then
		-- The whole text selected again (after a click in it), for Ctrl+C. Never the keyboard by
		-- itself with the gamepad UI (ns.Focus): there a click in the text selects it.
		f.selectAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		f.selectAll:SetSize(110, 20)
		f.selectAll:SetText(L.COPY_SELECT_ALL)
		f.selectAll:SetScript("OnClick", function()
			ns.SafeCall("copy select all", function()
				ns.Focus(f.eb)
				f.eb:HighlightText()
			end)
		end)
	end
	copyFrames[key] = f
	return f
end

function UI.ShowCopy(title, text, action, opts)
	text = ns.Codec.NoMentions(text)
	opts = type(opts) == "table" and opts or {}
	local key = type(opts.key) == "string" and opts.key or "copy"
	local copyFrame = CopyFrame(key, opts.big)
	local button = copyFrame.action
	button.fn = action and action.fn or nil
	button:SetShown(action ~= nil)
	-- With the button on the left, the hint moves right.
	copyFrame.hint:ClearAllPoints()
	if action or copyFrame.selectAll then
		copyFrame.hint:SetPoint("BOTTOMRIGHT", -12, 10)
		copyFrame.hint:SetJustifyH("RIGHT")
	else
		copyFrame.hint:SetPoint("BOTTOM", 0, 10)
		copyFrame.hint:SetJustifyH("CENTER")
	end
	if action then
		button:SetText(action.label)
		local fs = button:GetFontString()
		local textW = fs and (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()) or 140
		button:SetWidth(math.max(120, math.ceil(textW) + 24))
		button:Enable()
	end
	if copyFrame.selectAll then
		copyFrame.selectAll:ClearAllPoints()
		if action then copyFrame.selectAll:SetPoint("LEFT", button, "RIGHT", 6, 0) else copyFrame.selectAll:SetPoint("BOTTOMLEFT", 10, 6) end
	end
	if copyFrame.TitleText then copyFrame.TitleText:SetText(title) end
	copyFrame.text = text
	copyFrame.eb:SetText(text)
	copyFrame:Show()
	-- At its own place it steps above the Issue Reporter, like our window (its hint is
	-- right over the reporter's default spot).
	if not copyFrame.movedByPlayer then
		ns.SafeCall("issue reporter", ClearOfIssueReporter, function() return StepAboveIssueReporter(copyFrame, { copyFrame }) end)
	end
	copyFrame.eb.sylvanistasBox = true
	-- (Gamepad UI with the chat box typing: not taken from it; a click in the text selects it.)
	-- opts.auto (1.1.2): opened by itself, not by the player's click (a bug report that came in,
	-- a version check's answer): never the keyboard, in either input mode, or his movement keys
	-- and the chat line he was typing would go into it. A click in the text (or Select all) takes it.
	if opts.auto or not ns.Focus(copyFrame.eb) then copyFrame.eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end) end
	copyFrame.eb:HighlightText()
	return copyFrame
end
function UI.CopyFrame(key) return copyFrames[key or "copy"] end

---------------------------------------------------------------------------
-- Minimap button (drag around the minimap, angle is saved)
---------------------------------------------------------------------------

local minimapButton

local function PositionMinimapButton()
	local angle = math.rad(ns.db.minimapAngle or 200)
	-- On the ring, like Blizzard's own minimap buttons (and LibDBIcon): 5 past the map's edge.
	local radius = (Minimap:GetWidth() / 2) + 5
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function CreateMinimapButton()
	local b = ns.MakeRoundButton("SylvanistasMinimapButton", Minimap, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")

	b:SetScript("OnClick", function(_, button)
		ns.SafeCall("minimap click", function()
			if button == "RightButton" then
				ns.Map.SetEnabled(not ns.db.showMap)
			elseif IsShiftKeyDown and IsShiftKeyDown() then
				-- 1.1.1: Shift + left-click, the Sylvanistas window on its Chat tab (ChatWindow.lua).
				ns.ChatWindow.Toggle()
			else
				UI.Toggle()
			end
		end)
	end)
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			ns.db.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
			PositionMinimapButton()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", function(self)
		local s = ns.Data.Summary()
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(L.TITLE, 1, 0.82, 0)
		GameTooltip:AddLine(L.ARMY_TOTAL:format(ns.FormatNumber(s.total)), 1, 1, 1)
		GameTooltip:AddLine(L.ARMY_SUB:format(ns.FormatNumber(s.online), #s.guilds, ns.Ago(s.newest)), 0.8, 0.8, 0.8)
		local heard = ns.Data.Rebuilding and ns.Data.Rebuilding()
		if heard then GameTooltip:AddLine(L.REBUILDING_SUB:format(heard), 1, 0.82, 0) end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(L.MINIMAP_LEFT, 0.6, 0.6, 0.6)
		GameTooltip:AddLine(L.MINIMAP_SHIFT, 0.6, 0.6, 0.6)
		GameTooltip:AddLine(L.MINIMAP_RIGHT, 0.6, 0.6, 0.6)
		GameTooltip:AddLine(L.MINIMAP_DRAG, 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

function UI.UpdateMinimapButton()
	minimapButton = minimapButton or CreateMinimapButton()
	PositionMinimapButton()
	minimapButton:SetShown(not ns.db.hideMinimap)
end

ns.On("LOGIN", function()
	UI.UpdateMinimapButton()
	ns.Log("ui ready")
end)

---------------------------------------------------------------------------
-- Photo mode (1.0.0), the author's, for the store's screenshots: /syl photo hides everything on
-- the screen but Sylvanistas's own frames, the world map and the tooltip (Sylvanistas's tooltips are
-- part of the pictures), and /syl photo again, or a /reload, brings it all back. By alpha alone:
-- each child of UIParent at 0, its own alpha kept and given back as it was, never Hide, Show or
-- SetPoint on the game's frames. Never in combat, and not with the gamepad UI (its frames are
-- the game's to handle there); turning it off works with the gamepad UI too.
---------------------------------------------------------------------------

local photo -- [frame] = its alpha before, while photo mode is on
-- Children of UIParent walked at most (1.0.0, Konig's review of 1.0.0): a screen with thousands of
-- frames (some addons make one per thing they show) is left as it is. Counted first (Konig's
-- review of 1.1: GetChildren returns every child at once, however many, so capping the loop after
-- it still listed them all): GetChildren is called only when there are PHOTO_MAX or fewer.
UI.PHOTO_MAX = 1000

-- The author's character, or the author's own test build (Dev.lua, never published).
function UI.PhotoAllowed()
	return (ns.Workshop and ns.Workshop.IsAuthor and ns.Workshop.IsAuthor() == true) or ns.devThrone ~= nil or ns.devWorkshop ~= nil
end
function UI.PhotoMode() return photo ~= nil end

-- Sylvanistas's own: its named frames, and the few unnamed ones on UIParent it marks (map icons).
local function Ours(f)
	local name = f.GetName and f:GetName()
	return f.sylvanistas == true or (type(name) == "string" and name:find("^Sylvanistas") ~= nil)
end

local function PhotoOff()
	local was = photo
	photo = nil
	for f, alpha in pairs(was or {}) do pcall(f.SetAlpha, f, alpha) end
end

function UI.TogglePhoto()
	if not UI.PhotoAllowed() then return ns.Print(L.PHOTO_ONLY_AUTHOR) end
	if InCombatLockdown and InCombatLockdown() then return ns.Print(L.PHOTO_COMBAT) end
	if photo then
		PhotoOff()
		return ns.Print(L.PHOTO_OFF)
	end
	if ns.GamepadUI() then return ns.Print(L.PHOTO_GAMEPAD) end
	local count = UIParent.GetNumChildren and UIParent:GetNumChildren()
	if type(count) ~= "number" or count > UI.PHOTO_MAX then
		ns.Log("photo mode: %s frames on the screen, more than %d: none walked", tostring(count), UI.PHOTO_MAX)
		return ns.Print(L.PHOTO_TOO_MANY:format(UI.PHOTO_MAX))
	end
	ns.Print(L.PHOTO_ON) -- (first: the chat goes too)
	photo = {}
	local children = { UIParent:GetChildren() }
	for i = 1, math.min(#children, UI.PHOTO_MAX) do
		local f = children[i]
		local keep = f == WorldMapFrame or f == GameTooltip or (f.IsForbidden and f:IsForbidden()) or Ours(f)
		local alpha = not keep and f.GetAlpha and f:GetAlpha()
		if type(alpha) == "number" and alpha > 0 then
			photo[f] = alpha
			f:SetAlpha(0)
		end
	end
end

-- A /reload (or logging out) gives every alpha back first: another addon may save its frame's.
ns.RegisterEvent("PLAYER_LOGOUT", function() if photo then PhotoOff() end end)
