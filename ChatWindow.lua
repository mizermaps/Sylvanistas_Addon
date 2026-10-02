local ADDON, ns = ...
local L = ns.L

-- The Sylvanistas chats in the Sylvanistas window (1.1.1): its Chat tab, right after the Realm (UI.lua's
-- TABS). The three chats ([Sylvanistas], [Captains], [Lords]) like the chat pane of the Guild &
-- Communities window: the tabs' search box where the other tabs show the army's counts, and on
-- that row, right of it, a small switch of the channels (only for a rank that reads more than
-- one: most players read [Sylvanistas] alone, and a row of its own for one lone channel took the
-- lines' room) and the settings' gear; each line whole in a bubble that wraps (nothing to hover to
-- read it) from under that row over the list's and the detail box's room, the 100 lines Channels
-- keeps per channel to scroll back through, a box to write in across the bottom where they have
-- their buttons (no Send button: Enter sends), and Sylvanistas's marks by each name (the King's crown,
-- the High Council's mark, the Lords' and Captains' elite marks, Raiders and Veterans bronze, the
-- members' star, the Treasurer's coin, Stewards and Hands).
--
-- The first 1.1.1 build had it in a window of its own; the author wanted it inside the Sylvanistas
-- window. UI.lua hands this file the window in use and where each part goes in its look
-- (ChatWindow.Attach), and the old window's calls stay as the ways to the tab: Open, Toggle and
-- Close (/sy, /syc or /syld alone, /syl talk, the minimap button's Shift-click, the Realm tab's
-- link) open the Sylvanistas window on its Chat tab, on the channel asked for, and close it. The
-- Realm tab's "Sylvanistas chats" page it replaces is gone (the author's call): what that page offered
-- and the tab did not (the Sylvanistas tab's state, the chats on or off with what that means, the
-- public channel's line, the pin for whoever may pin, the count of the lines the block terms hide)
-- is here, the most of it in the settings the gear opens in place of the lines, with each
-- channel's place in the game's chat (muted there or not, the chat window it goes to).
--
-- What it never does, whatever the input mode (mouse and keyboard, or Blizzard's gamepad UI):
-- - It never touches the game's chat boxes or windows: no script of theirs replaced or hooked,
--   and none opened from here (ChatFrame_OpenChat, ChatFrame_SendTell, ChatFrameUtil.*: they
--   write LAST_ACTIVE_CHAT_EDIT_BOX or CHAT_FOCUS_OVERRIDE, which the game's secure chat code
--   reads afterwards, so what the player types next runs tainted and /cast, /target, /use or
--   /click get blocked; with the gamepad UI that froze the game in 0.8.5). Every frame here is
--   Sylvanistas's own. The Sylvanistas tab of the game's chat (below) is made by the player, with the
--   game's own menu: Sylvanistas only reads the game's chat windows to see it appear.
-- - Its box is Sylvanistas's own EditBox: it never takes the keyboard by itself (SetAutoFocus(false)
--   the moment it is made, never focused on opening); the player clicks into it, with the mouse
--   or the gamepad cursor, or (mouse and keyboard, 1.1.1, the owner's ask) presses the game's
--   "Open chat" key while the tab shows: an override binding of Sylvanistas's own button, below. Enter
--   sends through Channels.Send and the cursor stays for the next line (an empty Enter, Escape or
--   a plain left-click elsewhere, the client's own, lets the keyboard go back to the game); with
--   the gamepad UI every Enter lets it go, as the Communities box does. It runs no command: a line
--   starting with "/" is kept and the player is told the game's chat box is where commands go
--   (and, with the cursor kept, that Escape and then his own key for it get him there).
-- - No game popup from it: the pinned line's takedown and a whisper go through ns.ShowDialog
--   (Sylvanistas's own window with the gamepad UI); the Sylvanistas window closes with Escape through
--   ns.EscapeCloses (nothing on UISpecialFrames with the gamepad UI: its X closes it there).
-- - Links in a line show their tooltip on hover (GameTooltip:SetHyperlink) and go into its own
--   box with a Shift-click; never SetItemRef, ChatEdit_InsertLink or HandleModifiedItemClick.
-- Nothing is drawn while the tab is hidden: a change marks it dirty and it redraws at most every
-- 0.2 s while shown (the census at most every 5 s).

local ChatWindow = {}
ns.ChatWindow = ChatWindow

local TAB = "chat"                                    -- its tab in the Sylvanistas window (UI.lua)
local SEARCH_H = 20                                   -- the top row: the search, the channels' switch, the gear
local TOP_GAP = 4                                     -- between the top row's parts
local GEAR_W = 20
local ARROW_W = 12                                    -- the switch's arrow
local MENU_ROW, MENU_PAD = 20, 4                      -- the switch's list of channels
local INDENT = 12                                     -- a setting under its heading
local PAD = 8                                         -- inside a bubble
local HEADER_H = 16
local EDGE = 8                                        -- a bubble from the box's side
local SHARE = 0.82                                    -- a bubble's width, at most, of the box's
local BUBBLE_MIN = 180
local GAP_IN, GAP_OUT = 3, 10                         -- between bubbles of one writer, between writers
local GROUP_TIME = 300                                -- a pause this long starts a new header
local STICK_SLACK = 2
local THROTTLE, DATA_GAP = 0.2, 5
local LINE_H = 14                                     -- a line of text, where the client gives no height
local PIN_LINES, GUIDE_LINES, COUNT_LINES = 3, 4, 2   -- the strips over the lines, at most
local GUIDE_X = 20                                    -- the Sylvanistas tab's line: the room its x takes on the right
local MAX_NOTES = 5
local LOOK_GAP = 1                                    -- the Sylvanistas tab awaited: the game's chat windows read this often
local GREY = "|cff9d9d9d"
local LINK_TIPS = { item = true, spell = true, enchant = true, quest = true } -- (the links Codec lets through)
local WHY = { moved = "CHATWIN_WHY_MOVED", late = "CHATWIN_WHY_LATE", failed = "CHATWIN_WHY_FAILED", left = "CHATWIN_WHY_LEFT" }
-- The pointer's arrow: the game's tutorial arrow (Blizzard_TutorialTemplates), else the chat
-- frame's own scroll-down arrow (Blizzard_SharedXML's dropdown and store templates use it).
local ARROW_ATLAS, ARROW_FILE = "NPE_ArrowDown", "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up"
-- The gear: the game's own settings icon (Forever's UIPanelIconDropdownButtonTemplate,
-- SharedUIPanelTemplates.xml), else the gear icon every client carries.
local GEAR_ATLAS, GEAR_FILE = "questlog-icon-setting", "Interface\\Icons\\INV_Misc_Gear_01"

local panes = {}             -- Sylvanistas window -> its Chat tab (each look's window has its own)
local frame                  -- the Chat tab in use (a pane of `host`)
local host                   -- the Sylvanistas window it is in
local tier                   -- the channel shown
local dirty, dataPending = false, false
local lastData = -math.huge
local unread = {}            -- tier -> lines from others since it was last looked at (while open)
local notes = {}             -- tier -> { { why, text } }: lines that were not sent, this session
local revealed = setmetatable({}, { __mode = "k" }) -- history entry -> shown despite the block terms
local stick, newCount = true, 0 -- the view follows the newest line; lines come while it doesn't
local lastAt = 0             -- the offset the view had last
local want                   -- scrolled up: the offset that keeps the line read in its place
local quiet = false          -- our own scrolling: not the player's
local acc, lookAcc = 0, 0
local tipOwner
local pointer                -- the Sylvanistas tab awaited: Sylvanistas's own pointer by the game's chat tab
local watching = false       -- ... and the game's chat windows read until it is there
local sent = false           -- ... the click having sent the channels there already (Chattynator)
local settings = false       -- the settings (the gear) shown in place of the lines
local keyButton              -- Sylvanistas's own button the "Open chat" key clicks (made when first bound)
local boundKeys              -- the keys our override binding holds now (nil: none)
local keysLater = false      -- a binding change asked in combat, made when the fight ends
local toldLater = false      -- the key pressed in combat with the tab gone: said, once a fight
local syncing = false

local function Grey(s) return GREY .. s .. "|r" end
local function Gold(s) return "|cffffd200" .. s .. "|r" end
local function Green(s) return "|cff40ff40" .. s .. "|r" end
local function Trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function Label(t)
	local d = ns.Channels.TIERS[t]
	return d and L[d.label] or "?"
end
local function Colour(t)
	local d = ns.Channels.TIERS[t]
	return d and d.color or { 1, 1, 1 }
end
local function Hex(c)
	local function B(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
	return ("ff%02x%02x%02x"):format(B(c[1]), B(c[2]), B(c[3]))
end
local function Finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
-- The game's own words for its menus (its global strings, in the player's language), else ours.
local function GameWord(value, fallback)
	return type(value) == "string" and value ~= "" and value or fallback
end

-- The channels this rank reads, in their order.
local function Readable()
	local C, out = ns.Channels, {}
	for _, t in ipairs(C.ORDER or {}) do
		if C.CanUse(t) then out[#out + 1] = t end
	end
	return out
end

-- A text's width as the client draws it on one line, and its height at a width (the client wraps
-- it there; without the height a client gives, whole lines of LINE_H).
local function TextWidth(fs)
	if fs.GetUnboundedStringWidth then return fs:GetUnboundedStringWidth() or 0 end
	return fs:GetStringWidth() or 0
end
local function TextHeight(fs, width)
	if fs.GetStringHeight then
		local h = fs:GetStringHeight()
		if type(h) == "number" and h > 0 then return math.ceil(h) end
	end
	return math.max(1, math.ceil(TextWidth(fs) / math.max(1, width))) * LINE_H
end

local function Tip(owner, fill)
	GameTooltip:SetOwner(owner, "ANCHOR_TOP")
	fill(GameTooltip)
	GameTooltip:Show()
	tipOwner = owner
end
local function Untip(owner)
	if owner and GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
end

---------------------------------------------------------------------------
-- The channel last shown, and the Sylvanistas tab's line put away with its x: ns.db.chatWin =
-- { tier, noTabLine }, account-wide (the first 1.1.1 build kept its window's place and size there
-- too; the tab has neither).
---------------------------------------------------------------------------

local function Saved()
	local p = ns.db and ns.db.chatWin
	return type(p) == "table" and p or nil
end

local function Remember(t)
	if not ns.db then return end
	local p = Saved() or {}
	p.tier = t
	ns.db.chatWin = p
end

-- The Sylvanistas tab's line, put away for good by its x (the settings and /syl chatwindow tab still
-- make the tab).
local function TabLineOff()
	local p = Saved()
	return p ~= nil and p.noTabLine == true
end
local function PutTabLineAway()
	if not ns.db then return end
	local p = Saved() or {}
	p.noTabLine = true
	ns.db.chatWin = p
end

local function MarkDirty() dirty = true end

function ChatWindow.IsShown()
	return frame ~= nil and frame:IsShown() and host ~= nil and host:IsShown() and true or false
end
local function Shown() return ChatWindow.IsShown() end

---------------------------------------------------------------------------
-- Scrolling: it follows the newest line (on opening, on a channel picked, after the player's own
-- line, on a search typed) until the player scrolls up; lines that come meanwhile show as "N new"
-- at the bottom. The client measures the scroll range a frame after the lines change (as
-- UI.KeepPlace knows): the offset is put at the end again then, while it follows.
---------------------------------------------------------------------------

local function Quietly(fn)
	quiet = true
	local ok, err = pcall(fn)
	quiet = false
	if not ok then error(err, 0) end
end

local function ShowNew()
	if not frame then return end
	local b = frame.newPill
	if newCount > 0 and not stick and frame.scroll:IsShown() then
		b:SetText(L.CHATWIN_NEW_LINES:format(newCount))
		b:Show()
	else
		b:Hide()
	end
end

local function ToBottom()
	local s = frame.scroll
	local range = math.max(0, (frame.content:GetHeight() or 0) - (s:GetHeight() or 0))
	Quietly(function() s:SetVerticalScroll(range) end)
	lastAt = s:GetVerticalScroll() or 0
end

local function ScrollToBottom()
	stick, newCount, want = true, 0, nil
	if not frame then return end
	ToBottom()
	ShowNew()
end

-- The range measured again: at its end while the view follows; scrolled up, where the line read
-- stays in its place (Render's anchor, as far as the new range reaches).
local function Held()
	if not frame then return end
	local s = frame.scroll
	local range = s:GetVerticalScrollRange() or 0
	local to
	if stick then
		to = range
	elseif want then
		to = math.min(want, range)
	else
		return
	end
	Quietly(function() s:SetVerticalScroll(to) end)
	lastAt = s:GetVerticalScroll() or 0
end

-- The player scrolled: at the end it follows again; up from where it was, it stays where he put it.
local function Scrolled()
	if quiet or not frame then return end
	want = nil -- (his offset now, not the one a redraw worked out)
	local s = frame.scroll
	local range, at = s:GetVerticalScrollRange() or 0, s:GetVerticalScroll() or 0
	if range - at <= STICK_SLACK then
		stick, newCount = true, 0
	elseif at < lastAt - 0.5 then
		stick = false
	end
	lastAt = at
	ShowNew()
end

-- Scrolled up, the view is held by the lines it shows, not by pixels: at a channel's 100 lines
-- each new one drops the oldest (Channels' AddHistory), everything under it moves up by that
-- bubble, and an offset kept as it was would show other lines. Before a redraw: the bubbles from
-- the one at the view's top down, each with how far it sat from the view's top.
local function InView()
	local at = frame.scroll:GetVerticalScroll() or 0
	local out = {}
	for _, b in ipairs(frame.bubbles) do
		if b:IsShown() and b.entry and b.y and (#out > 0 or b.y + (b:GetHeight() or 0) > at) then
			out[#out + 1] = { entry = b.entry, delta = b.y - at }
		end
	end
	return out
end

-- After it: the first of them still drawn back where it was (the one read dropped: the next
-- one's place); none left, the top.
local function BackInView(was)
	local at = {}
	for _, b in ipairs(frame.bubbles) do
		if b:IsShown() and b.entry and b.y then at[b.entry] = b.y end
	end
	want = 0
	for _, v in ipairs(was) do
		if at[v.entry] then
			want = math.max(0, at[v.entry] - v.delta)
			break
		end
	end
	local s = frame.scroll
	Quietly(function() s:SetVerticalScroll(want) end)
	lastAt = s:GetVerticalScroll() or 0
end

---------------------------------------------------------------------------
-- A name's header: one mark, the name, a tag, the guild (Borders.ChatMark over Borders.MarkOfName:
-- the elite borders' and nameplate marks' rules, and a mark only where the guild the line names is
-- proven).
---------------------------------------------------------------------------

local function NameText(e)
	local who = ns.FullName(e.sender)
	local guild = e.guild
	local B = ns.Borders
	local council = ns.IsHighCouncillor(who) and not ns.CouncilMasked()
	local name = ns.Codec.Plain(ns.DisplayName(e.sender) or "?")
	-- (Borders.ChatMark, shared with the game's chat windows since 1.1.2; without Borders.lua, a
	-- client updated without a restart, the High Council's mark alone.)
	local lead = B and type(B.ChatMark) == "function" and B.ChatMark(who, guild) or (council and ns.CouncilMark(who)) or ""
	if lead ~= "" then lead = lead .. " " end
	if ns.IsTreasurer(who, guild) then lead = lead .. (ns.COIN:gsub(" $", "")) end
	if council then
		name = "|c" .. ns.HIGH_COUNCIL_COLOR .. name .. "|r"
	else
		local file = e.class and ns.CLASS_FILES[e.class]
		local c = file and RAID_CLASS_COLORS and RAID_CLASS_COLORS[file]
		if c and c.colorStr then name = "|c" .. c.colorStr .. name .. "|r" end
	end
	-- The King's Stewards and Hands, by the rule the channels read them with (his guild's lines).
	local tag = ""
	local K = ns.King
	if ns.IsKingGuild(guild) and type(K) == "table" then
		if type(K.IsStewardName) == "function" and K.IsStewardName(who) then
			tag = " " .. Gold(L.CHATWIN_TAG_STEWARD)
		elseif type(K.IsHandName) == "function" and K.IsHandName(who) then
			tag = " " .. Gold(L.CHATWIN_TAG_HAND)
		end
	end
	return lead .. name .. tag .. " " .. Grey("<" .. ns.Codec.Plain(guild or "?") .. ">")
end

---------------------------------------------------------------------------
-- The box's parts: bubbles and grey rows, each from a pool (made once, reused on every redraw).
---------------------------------------------------------------------------

local function Content() return frame and frame.content end

local function Render() return ChatWindow.Render() end

local function InsertLink(text)
	local eb = frame and frame.input
	if not eb or not eb:IsShown() or type(text) ~= "string" then return end
	-- Sylvanistas's own box, where its cursor is; the keyboard stays where it was.
	if eb.Insert then eb:Insert(text) else eb:SetText((eb:GetText() or "") .. text) end
end

local function LinkTip(owner, link)
	local kind = type(link) == "string" and link:match("^(%a+):")
	if not kind or not LINK_TIPS[kind] then return end
	GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
	if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then
		GameTooltip:Show()
		tipOwner = owner
	else
		GameTooltip:Hide()
	end
end

local function NewBubble()
	local content = Content()
	local ok, b = pcall(CreateFrame, "Frame", nil, content, "BackdropTemplate")
	if not ok or not b then b = CreateFrame("Frame", nil, content) end
	if b.SetBackdrop then
		b:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
	else
		b.bg = b:CreateTexture(nil, "BACKGROUND")
		b.bg:SetAllPoints()
	end
	b:EnableMouse(true)
	-- The header: the name is a button (a whisper), the time on the right.
	b.header = CreateFrame("Button", nil, b)
	b.header:SetHeight(HEADER_H)
	b.header:SetPoint("TOPLEFT", b, "TOPLEFT", PAD, -PAD)
	b.who = b.header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.who:SetPoint("LEFT", b.header, "LEFT", 0, 0)
	b.who:SetJustifyH("LEFT")
	b.who:SetWordWrap(false)
	b.time = b.header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.time:SetPoint("RIGHT", b.header, "RIGHT", 0, 0)
	b.header:SetScript("OnClick", function(self)
		if self.whisper then ns.SafeCall("chat tab whisper", ns.UI.WhisperWindow, self.whisper) end
	end)
	b.header:SetScript("OnEnter", function(self)
		if not self.whisper then return end
		Tip(self, function(tt)
			tt:AddLine(self.full or self.whisper, 1, 0.82, 0)
			tt:AddLine(L.CHATWIN_WHISPER_TIP:format(self.whisper), 0.6, 0.6, 0.6)
		end)
	end)
	b.header:SetScript("OnLeave", function(self) Untip(self) end)
	-- The line itself, whole: the player's chat font, wrapped at any width, never cut.
	b.body = b:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	b.body:SetJustifyH("LEFT")
	if b.body.SetJustifyV then b.body:SetJustifyV("TOP") end
	b.body:SetWordWrap(true)
	if b.body.SetNonSpaceWrap then b.body:SetNonSpaceWrap(true) end
	b.body:SetTextColor(0.95, 0.95, 0.95)
	-- Its links: a tooltip on hover, into our own box with Shift.
	if b.SetHyperlinksEnabled then b:SetHyperlinksEnabled(true) end
	b:SetScript("OnHyperlinkEnter", function(self, link) ns.SafeCall("chat tab link", LinkTip, self, link) end)
	b:SetScript("OnHyperlinkLeave", function(self) Untip(self) end)
	b:SetScript("OnHyperlinkClick", function(_, _, text)
		if IsShiftKeyDown and IsShiftKeyDown() then ns.SafeCall("chat tab link", InsertLink, text) end
	end)
	-- A line the block terms hide: a click shows it (this session).
	b:SetScript("OnMouseUp", function(self)
		if self.hidden and self.entry then
			revealed[self.entry] = true
			ns.SafeCall("chat tab", Render)
		end
	end)
	return b
end

-- A grey row across the box: the kept note, a day, the empty channel, no match, a line that was
-- not sent.
local function NewRow()
	local r = CreateFrame("Button", nil, Content())
	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
	r.text:SetJustifyH("CENTER")
	r.text:SetWordWrap(true)
	r:SetScript("OnClick", function(self) if self.onClick then ns.SafeCall("chat tab row", self.onClick) end end)
	r:SetScript("OnEnter", function(self) if self.tip then Tip(self, self.tip) end end)
	r:SetScript("OnLeave", function(self) Untip(self) end)
	return r
end

local function Row(i, text, y, width, onClick, tip)
	local rows = frame.rows
	local r = rows[i] or NewRow()
	rows[i] = r
	local w = math.max(40, width - 2 * EDGE)
	r.text:SetText(text)
	r.text:SetWidth(w)
	local h = TextHeight(r.text, w)
	r:SetSize(w, h)
	r:ClearAllPoints()
	r:SetPoint("TOPLEFT", frame.content, "TOPLEFT", EDGE, -y)
	r.onClick, r.tip = onClick, tip
	r:EnableMouse(onClick ~= nil or tip ~= nil)
	r:Show()
	return h
end

local function Hint()
	if not frame then return end
	local eb = frame.input
	local empty = (eb:GetText() or "") == ""
	local focused = eb.HasFocus and eb:HasFocus() or false
	eb.hint:SetShown(empty and not focused)
end

-- A line that was not sent, back in the box (the keyboard stays where it is: no focus). Only into
-- an empty box: what the player is writing is never replaced; the note stays, and he is told.
local function PutBack(t, note)
	local eb = frame and frame.input
	if not eb or not eb:IsShown() then return end
	if Trim(eb:GetText()) ~= "" then
		ns.Print(L.CHATWIN_PUT_BACK_BUSY)
		return
	end
	local list = notes[t]
	if list then
		for i, n in ipairs(list) do
			if n == note then table.remove(list, i) break end
		end
		if #list == 0 then notes[t] = nil end
	end
	eb:SetText(note.text)
	Hint()
	Render()
end

-- A line this character wrote: sent from here (mine) under this name. The history is the realm
-- group's, shared by every character of the account (ns.rdb): a line another character of it
-- sent shows as that character's, with his name, guild and whisper, on the left.
local function Own(e)
	return e.mine and ns.Channels.IsMe(e.sender) and true or false
end

-- One line of the history in its bubble. Returns its height.
local function Bubble(i, e, start, y, maxInner, hides)
	local bubbles = frame.bubbles
	local b = bubbles[i] or NewBubble()
	bubbles[i] = b
	local mine = Own(e)
	-- A line the block terms hide: a grey bubble until a click, then its words marked (as the Realm
	-- tab's chats page marked them) and its border still grey.
	local veiled = not mine and hides ~= nil and hides(e.text or "") or false
	local hidden = veiled and not revealed[e]
	b.entry, b.hidden, b.mine, b.y = e, hidden, mine, y
	local c = Colour(tier)
	local r, g, bl, a = 0.09, 0.09, 0.11, 0.92
	if mine then r, g, bl, a = c[1] * 0.28, c[2] * 0.28, c[3] * 0.28, 0.95 end
	if b.SetBackdropColor then
		b:SetBackdropColor(r, g, bl, a)
		if veiled then b:SetBackdropBorderColor(0.5, 0.5, 0.5, 1) else b:SetBackdropBorderColor(c[1], c[2], c[3], 1) end
	elseif b.bg then
		b.bg:SetColorTexture(r, g, bl, a)
	end
	-- The header, at a group's start.
	local headerW, timeW = 0, 0
	if start then
		b.who:SetText(mine and L.CHATWIN_YOU or NameText(e))
		b.time:SetText(Grey(date("%H:%M", tonumber(e.t) or 0)))
		timeW = math.ceil(TextWidth(b.time))
		headerW = math.ceil(TextWidth(b.who)) + 8 + timeW
		b.header.whisper = not mine and ns.TellName(e.sender) or nil
		b.header.full = not mine and (ns.Codec.Plain(ns.DisplayName(e.sender) or "?") .. "  <" .. ns.Codec.Plain(e.guild or "?") .. ">") or nil
		b.header:EnableMouse(not mine)
		b.header:Show()
	else
		b.header.whisper, b.header.full = nil, nil
		b.header:Hide()
	end
	b.body:SetText(hidden and Grey(L.CHATWIN_HIDDEN)
		or ((veiled and (Grey(L.FILTER_HIDDEN_MARK) .. " ") or "") .. ns.Codec.SanitizeChat(e.text)))
	local inner = math.min(maxInner, math.max(math.ceil(TextWidth(b.body)), headerW, 1))
	b.body:SetWidth(inner)
	local bodyH = TextHeight(b.body, inner)
	local top = PAD
	if start then
		b.header:SetWidth(inner)
		b.who:SetWidth(math.max(1, inner - timeW - 8))
		top = top + HEADER_H + 2
	end
	b.body:ClearAllPoints()
	b.body:SetPoint("TOPLEFT", b, "TOPLEFT", PAD, -top)
	local h = top + bodyH + PAD
	b:SetSize(inner + 2 * PAD, h)
	b:ClearAllPoints()
	if mine then
		b:SetPoint("TOPRIGHT", frame.content, "TOPRIGHT", -EDGE, -y)
	else
		b:SetPoint("TOPLEFT", frame.content, "TOPLEFT", EDGE, -y)
	end
	b:Show()
	return h
end

local function ContentWidth()
	local w = frame.scroll:GetWidth()
	if not Finite(w) or w <= 0 then w = (frame:GetWidth() or 338) - 20 - (frame.barRoom or 22) end
	return math.max(100, math.floor(w))
end

-- The lines the tab's search box keeps (Views.Query: folded, as every tab's search): whose
-- writer, guild or words hold it. A line the block terms hide is found by its writer and guild
-- alone (its words are not shown).
local function Searched(list, q, hides)
	if not q then return list end
	local out = {}
	local Plain = ns.Codec.Plain
	for _, e in ipairs(list) do
		local hidden = hides ~= nil and not Own(e) and not revealed[e] and hides(e.text or "")
		local words = not hidden and ns.Codec.SanitizeChat(e.text) or nil
		if ns.Holds(q, ns.DisplayName(e.sender) or "?", Plain(e.guild or ""), words) then out[#out + 1] = e end
	end
	return out
end

local function Query()
	local V = ns.Views
	return V and type(V.Query) == "function" and V.Query(TAB) or nil
end

-- The block terms (Filter.lua), when this client has them.
local function Hides()
	local F = ns.Filter
	return F and not F.missing and type(F.Hides) == "function" and F.Hides or nil
end

-- The lines of `all` (the channel's history) that the block terms hide (never ours), in its order.
local function HiddenLines(all)
	local hides, out = Hides(), {}
	if not hides then return out end
	for _, e in ipairs(all) do
		if not Own(e) and hides(e.text or "") then out[#out + 1] = e end
	end
	return out
end

-- The lines of `all`, the channel's history (Render reads it once for the strips and the lines).
local function DrawLines(all)
	local C = ns.Channels
	local width = ContentWidth()
	frame.content:SetWidth(width)
	local hides = Hides()
	local q = Query()
	local list = Searched(all, q, hides)
	local nb, nr = 0, 0
	local y = 6
	nr = nr + 1
	y = y + Row(nr, Grey(L.CHATWIN_KEPT:format(C.HISTORY or 100)), y, width) + 6
	-- (The count of the lines the block terms hide is a strip over the lines: DrawHiddenCount.)
	if #all == 0 then
		nr = nr + 1
		y = y + 8 + Row(nr, Grey(L.CHATWIN_EMPTY:format(Label(tier))), y + 8, width)
	elseif #list == 0 then
		nr = nr + 1
		y = y + 8 + Row(nr, Grey(L.SEARCH_NO_MATCH), y + 8, width)
	end
	local maxInner = math.max(BUBBLE_MIN, math.floor(width * SHARE)) - 2 * PAD
	local prev, prevDay
	for _, e in ipairs(list) do
		local t = tonumber(e.t) or 0
		local day = date("%Y-%m-%d", t)
		local newDay = day ~= prevDay
		if newDay then
			if prev then y = y + GAP_OUT end
			nr = nr + 1
			y = y + Row(nr, Grey(day), y, width) + 4
			prevDay = day
		end
		local start = newDay or not prev or ns.FullName(prev.sender) ~= ns.FullName(e.sender)
			or Own(prev) ~= Own(e) or t - (tonumber(prev.t) or 0) > GROUP_TIME
		if prev and not newDay then y = y + (start and GAP_OUT or GAP_IN) end
		nb = nb + 1
		y = y + Bubble(nb, e, start, y, maxInner, hides)
		prev = e
	end
	-- The lines of ours that were not sent: a grey note each, a click puts one back in the box.
	local t = tier
	for _, note in ipairs(notes[t] or {}) do
		local key = WHY[note.why] or WHY.failed
		nr = nr + 1
		y = y + GAP_OUT
		y = y + Row(nr, Grey(L.CHATWIN_NOT_SENT:format(L[key]) .. " " .. L.CHATWIN_PUT_BACK), y, width, function() PutBack(t, note) end)
	end
	y = y + 8
	for i = nb + 1, #frame.bubbles do frame.bubbles[i]:Hide(); frame.bubbles[i].entry, frame.bubbles[i].y = nil, nil end
	for i = nr + 1, #frame.rows do frame.rows[i]:Hide(); frame.rows[i].onClick, frame.rows[i].tip = nil, nil end
	frame.content:SetHeight(math.max(1, y))
end

---------------------------------------------------------------------------
-- The top row: the search box, the channels' switch right of it (a rank that reads more than
-- one channel), the gear at its end. The owner's ask: the row of pills under it (one lone
-- underlined "Sylvanistas" for most players) took the lines' room; there is no row of its own now.
-- Then, over the lines, the pinned line, the way to the Sylvanistas tab and the count of the lines the
-- block terms hide, each only while it shows.
---------------------------------------------------------------------------

-- The lines that came in on the channels not shown (unread[t] counts only those, CHAT_LINE).
local function OthersUnread()
	local n = 0
	for t, c in pairs(unread) do
		if t ~= tier and ns.Channels.CanUse(t) then n = n + c end
	end
	return n
end

-- The switch: the channel shown, in its colour, then "+N" for the lines new in the others, and
-- its arrow. As wide as that.
local function PaintSwitch()
	local b = frame.switch
	local c = Colour(tier)
	b.text:SetText(Label(tier))
	b.text:SetTextColor(c[1], c[2], c[3])
	local n = OthersUnread()
	b.count:SetText(n > 0 and ("+" .. n) or "")
	b.count:SetShown(n > 0)
	local w = 8 + math.ceil(TextWidth(b.text)) + (n > 0 and (4 + math.ceil(TextWidth(b.count))) or 0) + 4 + ARROW_W + 4
	b:SetSize(w, SEARCH_H)
end

-- A channel in the switch's list: its colour for the one shown, grey for the others (white under
-- the mouse), and the lines new in it.
local function PaintChoice(r)
	local c = Colour(r.tier)
	local n = unread[r.tier] or 0
	r.text:SetText(Label(r.tier) .. (n > 0 and (" (" .. n .. ")") or ""))
	if r.tier == tier then
		r.text:SetTextColor(c[1], c[2], c[3])
		r.mark:SetColorTexture(c[1], c[2], c[3], 1)
		r.mark:Show()
	else
		local v = r.hover and 1 or 0.6
		r.text:SetTextColor(v, v, v)
		r.mark:Hide()
	end
end

-- The switch's list, under it on its right: the channels this rank reads, in their order.
local function PaintMenu()
	local m = frame.menu
	local C = ns.Channels
	local y, w = -MENU_PAD, 0
	for _, t in ipairs(C.ORDER) do
		local r = m.rows[t]
		if C.CanUse(t) then
			PaintChoice(r)
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", m, "TOPLEFT", MENU_PAD, y)
			r:SetPoint("TOPRIGHT", m, "TOPRIGHT", -MENU_PAD, y)
			r:SetHeight(MENU_ROW)
			y = y - MENU_ROW
			w = math.max(w, math.ceil(TextWidth(r.text)))
			r:Show()
		else
			r:Hide()
		end
	end
	m:SetSize(math.max(frame.switch:GetWidth(), w + 2 * MENU_PAD + 20), -y + MENU_PAD)
	m:ClearAllPoints()
	m:SetPoint("TOPRIGHT", frame.switch, "BOTTOMRIGHT", 0, -2)
end

local function CloseMenu()
	if not frame then return end
	frame.menu:Hide()
	frame.catcher:Hide()
end

local function ToggleMenu()
	if frame.menu:IsShown() then return CloseMenu() end
	PaintMenu()
	frame.catcher:Show()
	frame.menu:Show()
end

-- The gear's look: lit while the settings show.
local function PaintGear()
	local g = frame.gear
	if settings then g:LockHighlight() else g:UnlockHighlight() end
end

-- The box to write in, across the bottom row; 1.1.2: the Answers button (the author, the High
-- Council and the Stewards) at that row's end while it shows, the box ending before it. Never on
-- the top row (1.1.2's review: next to the switch, the search box there shrank to nothing for a
-- Lord of the High Council in the default window), and by the box it fills.
local function PlaceInput(p)
	local input = p.places and p.places.input
	if not input then return end
	local room = 0
	if p.answers and p.answers:IsShown() then
		p.answers:ClearAllPoints()
		p.answers:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", input.right, input.y + math.floor((input.h - SEARCH_H) / 2))
		room = p.answers:GetWidth() + TOP_GAP
	end
	-- (The box's border art reaches 10 past its ends.)
	p.input:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", input.right - 10 - room, input.y)
end

-- The row: the gear at its end; the switch left of it while the lines show and the rank reads more
-- than one channel (never a row of its own; one channel, nothing); the search box in the rest.
-- The settings: their title there instead.
local function DrawTop(tiers, on)
	local s = frame.places.search
	local lines = on and not settings
	frame.gear:ClearAllPoints()
	frame.gear:SetPoint("TOPRIGHT", frame, "TOPRIGHT", s.right, s.top)
	PaintGear()
	local right = s.right - GEAR_W - TOP_GAP
	-- 1.1.2: the page's "?" left of the gear (Answers.lua: the tab's explanation, the detail box's
	-- "?" of the other tabs being under this one). The Answers of the author, the High Council and
	-- the Stewards: at the end of the box they fill, while the lines and that box show (PlaceInput).
	frame.help:ClearAllPoints()
	frame.help:SetPoint("TOPRIGHT", frame, "TOPRIGHT", right, s.top)
	frame.help:Show()
	right = right - GEAR_W - TOP_GAP
	local A = ns.Answers
	frame.answers:SetShown(lines and A ~= nil and type(A.Allowed) == "function" and A.Allowed() == true)
	PlaceInput(frame)
	local sw = frame.switch
	if lines and #tiers > 1 then
		PaintSwitch()
		sw:ClearAllPoints()
		sw:SetPoint("TOPRIGHT", frame, "TOPRIGHT", right, s.top)
		sw:Show()
		right = right - sw:GetWidth() - TOP_GAP
		if frame.menu:IsShown() then PaintMenu() end
	else
		sw:Hide()
		CloseMenu()
	end
	local lw = math.ceil(TextWidth(frame.searchLabel))
	frame.search:ClearAllPoints()
	frame.search:SetPoint("TOPLEFT", frame, "TOPLEFT", s.left + lw + 12, s.top)
	frame.search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", right, s.top)
	frame.search:SetShown(lines)
	frame.searchLabel:SetShown(lines)
	frame.setTitle:SetShown(settings)
end

-- The room between the box's sides (a strip over it: the pinned line, the Sylvanistas tab's line, the
-- count of the hidden lines).
local function StripWidth()
	local box = frame.places.box
	return math.max(100, (frame:GetWidth() or 338) - box.left + box.right - 12)
end

local function Strip(s, y)
	local box = frame.places.box
	s:ClearAllPoints()
	s:SetPoint("TOPLEFT", frame, "TOPLEFT", box.left + 6, y - 3)
	s:SetPoint("TOPRIGHT", frame, "TOPRIGHT", box.right - 6, y - 3)
end

-- The pinned line (Channels.Pin), as the Realm tab shows it (Views.PinLine): its words veiled
-- until a click when the block terms hide them; a click takes it down when allowed. Over the
-- lines' top, at `y`. Returns the room it takes (none without a pin).
local function DrawPin(y)
	local C = ns.Channels
	local pin = frame.pin
	local p = C.Pin and C.Pin()
	if not p then
		pin.onClick, pin.tip = nil, nil
		pin:Hide()
		return 0
	end
	local who = ns.Codec.Plain(ns.DisplayName(p.sender) or "?")
	local mayTakeDown = C.CanTakeDown and C.CanTakeDown()
	local words, veiled = C.PinWords(p)
	pin.onClick = mayTakeDown and function() ns.ShowDialog("SYLVANISTAS_PIN_DOWN") end or nil
	if veiled then
		pin.onClick = function()
			p.revealed = true
			Render()
		end
	end
	pin.tip = function(tt)
		tt:AddLine(L.PIN_LABEL, 1, 0.82, 0)
		tt:AddLine(words, 1, 1, 1, true)
		local left = math.max(1, math.ceil(((tonumber(p.expires) or ns.Now()) - ns.Now()) / 60))
		tt:AddLine(L.PIN_TIP:format(who, ns.Codec.Plain(p.guild or "?"), ns.Ago(p.setAt), left), 0.7, 0.7, 0.7, true)
		if mayTakeDown and not veiled then tt:AddLine(L.PIN_DOWN_TIP, 0.25, 1, 0.25, true) end
	end
	pin.text:SetText(Gold(L.CHATWIN_PINNED .. ": ") .. (veiled and Grey(L.FILTER_WORDS_HIDDEN) or ("|cffffffff" .. words .. "|r"))
		.. "  " .. Grey(who))
	local width = StripWidth()
	pin.text:SetWidth(width)
	local h = math.min(TextHeight(pin.text, width), PIN_LINES * LINE_H)
	pin:SetHeight(h)
	Strip(pin, y)
	pin:Show()
	return h + 6
end

-- The lines the block terms hide in this channel, counted (as the Realm tab's chats page counted
-- them): a click shows them all, marked, another hides them again (each hidden one is a grey
-- bubble, shown alone by its own click too). A strip over the lines, at `y` (the review of the
-- page's removal: a row atop the scrolled lines sat above the oldest line, out of sight, the tab
-- opening on the newest). `all`: the channel's history. Returns the room it takes (none while no
-- line is hidden).
local function DrawHiddenCount(y, all)
	local s = frame.hiddenCount
	local hidden = HiddenLines(all)
	if #hidden == 0 then
		s.onClick = nil
		s:Hide()
		return 0
	end
	local shown = true
	for _, e in ipairs(hidden) do shown = shown and revealed[e] == true end
	s.onClick = function()
		for _, e in ipairs(hidden) do revealed[e] = not shown or nil end
		Render()
	end
	s.text:SetText(Grey((shown and L.FILTER_SHOWING_LINES or L.FILTER_HIDDEN_LINES):format(#hidden)))
	local width = StripWidth()
	s.text:SetWidth(width)
	local h = math.min(TextHeight(s.text, width), COUNT_LINES * LINE_H)
	s:SetHeight(h)
	Strip(s, y)
	s:Show()
	return h + 6
end

---------------------------------------------------------------------------
-- The Sylvanistas tab of the game's chat, by the player's own hand (1.1.1, the author's ask: a button
-- for it). Sylvanistas cannot make a chat window: the game's code for one (FCF_OpenNewWindow, and the
-- NAME_CHAT popup FCF_NewChatWindow shows) writes the chat's own tables and its last active box
-- from whoever runs it, and run from an addon it taints the chat box (/cast, /target, /use and
-- /click typed there get blocked; with the gamepad UI the game froze). So the line on the Chat
-- tab only shows the player where: Sylvanistas's own small pointer, anchored by the game's main chat
-- tab (ours anchored to theirs; theirs only read), says right-click it, Create New Window, name
-- it Sylvanistas. Then Sylvanistas reads the game's chat windows (Channels.FindTab: GetChatWindowInfo and
-- the frames' own fields) when the game says they changed (UPDATE_CHAT_WINDOWS,
-- UPDATE_FLOATING_CHAT_WINDOWS: FloatingChatFrame.lua and ChatFrameOverrides.lua register them)
-- and every LOOK_GAP while the pointer or the tab shows; the moment a window named Sylvanistas is
-- there it runs Channels.SetupTab (the chats go there, and it says so once) and the pointer goes.
-- With the gamepad UI the game's chat tabs work otherwise: no pointer, the steps as text. With
-- Chattynator (1.1.2) its tabs are the chat and the game's are hidden behind them (the pointer
-- would point at nothing): no pointer, the click runs Channels.SetupTab at once, which says in
-- chat how to make the tab in Chattynator and sends the channels there the moment it exists
-- (nothing tells Sylvanistas when a tab of Chattynator's is made: the Chat tab reads its tabs every
-- LOOK_GAP while it shows, to say it once).
---------------------------------------------------------------------------

local function TabReady()
	local C = ns.Channels
	return not C.missing and type(C.SetupTab) == "function" and type(C.TabState) == "function" and type(C.FindTab) == "function"
end

-- Whether Chattynator's tabs are the chat windows now (Channels.Chattynator, 1.1.2).
local function Chatty()
	local C = ns.Channels
	return type(C.Chattynator) == "function" and C.Chattynator() and true or false
end

local function MainTabWord()
	local C = ns.Channels
	return type(C.MainTabName) == "function" and C.MainTabName() or L.CHATTAB_MAIN_TAB
end

-- The steps to the Sylvanistas tab while it is awaited, for the line over the lines and the settings.
local function TabSteps()
	if Chatty() then return L.CHATTY_TAB_STEPS end
	return L.CHATS_TAB_STEPS:format(MainTabWord(), GameWord(NEW_CHAT_WINDOW, L.CHATWIN_NEW))
end

-- The game's main chat tab (its frame's name and "Tab": ChatFrame1Tab, FloatingChatFrame.xml),
-- when it shows. Read only.
local function MainChatTab()
	local f = DEFAULT_CHAT_FRAME
	local name = type(f) == "table" and type(f.GetName) == "function" and f:GetName() or nil
	local tab = type(name) == "string" and _G[name .. "Tab"] or nil
	if type(tab) ~= "table" then tab = _G.ChatFrame1Tab end
	if type(tab) == "table" and type(tab.IsVisible) == "function" and tab:IsVisible() then return tab end
	return nil
end

local function StopWatching()
	watching, lookAcc, sent = false, 0, false
	if pointer then pointer:Hide() end
end

-- The game's chat windows read: a window named Sylvanistas there, the chats go to it (SetupTab, once).
-- With Chattynator (1.1.2) the click sent them there already (AddTab): the tab there, it is said
-- once (Channels.TabArrived: not when a line got there first, its intro saying it), and nothing is
-- chosen again. (The review of 1.1.2: SetupTab again, when the Chat tab next showed, undid a
-- channel the player had moved since, and said the tab's intro and filter hint a second time.)
local function Look()
	if not watching then return false end
	if not TabReady() then
		StopWatching()
		return false
	end
	local C = ns.Channels
	if not C.FindTab() then return false end
	-- (Awaited from the line's click: chosen or not before, it is set up now, and said once.)
	local already = sent
	StopWatching()
	if already and type(C.TabArrived) == "function" then C.TabArrived() else C.SetupTab() end
	MarkDirty()
	if ns.UI and type(ns.UI.RefreshSoon) == "function" then ns.UI.RefreshSoon() end
	return true
end

local function MakePointer()
	local name = "SylvanistasChatTabPointer"
	local ok, p = pcall(CreateFrame, "Frame", name, UIParent, "BackdropTemplate")
	if not ok or not p then p = CreateFrame("Frame", name, UIParent) end
	p:Hide()
	if p.SetBackdrop then
		p:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		if p.SetBackdropColor then p:SetBackdropColor(0.05, 0.05, 0.06, 0.95) end
		if p.SetBackdropBorderColor then p:SetBackdropBorderColor(1, 0.82, 0, 1) end
	else
		local bg = p:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.05, 0.05, 0.06, 0.95)
	end
	p:SetFrameStrata("DIALOG")
	p:SetClampedToScreen(true)
	p:SetSize(240, 76)
	p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	p.title:SetPoint("TOPLEFT", p, "TOPLEFT", 10, -9)
	p.title:SetText(L.CHATTAB_POINTER_TITLE)
	p.text = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	p.text:SetPoint("TOPLEFT", p, "TOPLEFT", 10, -27)
	p.text:SetWidth(220)
	p.text:SetJustifyH("LEFT")
	p.text:SetWordWrap(true)
	-- The arrow under it, down onto the tab.
	p.arrow = p:CreateTexture(nil, "OVERLAY")
	p.arrow:SetSize(32, 32)
	p.arrow:SetPoint("TOP", p, "BOTTOMLEFT", 26, 2)
	local atlas = C_Texture and C_Texture.GetAtlasInfo
	local okAtlas, info = false, nil
	if type(atlas) == "function" and type(p.arrow.SetAtlas) == "function" then okAtlas, info = pcall(atlas, ARROW_ATLAS) end
	if okAtlas and info ~= nil then p.arrow:SetAtlas(ARROW_ATLAS) else p.arrow:SetTexture(ARROW_FILE) end
	-- Its X: the pointer goes (the game's chat windows are still read when the game says they
	-- changed, and while the Chat tab shows).
	local okClose, close = pcall(CreateFrame, "Button", nil, p, "UIPanelCloseButton")
	if okClose and close then
		close:SetPoint("TOPRIGHT", p, "TOPRIGHT", 2, 2)
		close:SetScript("OnClick", function() p:Hide() end)
		p.CloseButton = close
	end
	p:SetScript("OnUpdate", function(_, elapsed)
		lookAcc = lookAcc + (tonumber(elapsed) or 0)
		if lookAcc < LOOK_GAP then return end
		lookAcc = 0
		ns.SafeCall("sylvanistas tab", Look)
	end)
	ns.EscapeCloses(name)
	p:HookScript("OnShow", function(self) ns.EscapeCloses(self:GetName()) end)
	pointer = p
	return p
end

-- By the game's main chat tab (the screen's bottom left where it does not show). Never with the
-- gamepad UI, nor with Chattynator (AddTab, StepsAgain).
local function ShowPointer()
	if ns.GamepadUI() then return nil end
	local p = pointer or MakePointer()
	p.text:SetText(L.CHATTAB_POINTER:format(GameWord(NEW_CHAT_WINDOW, L.CHATWIN_NEW)))
	p:SetHeight(math.max(76, 36 + TextHeight(p.text, 220)))
	p:ClearAllPoints()
	local tab = MainChatTab()
	if tab then
		p:SetPoint("BOTTOMLEFT", tab, "TOPLEFT", 0, 34)
	else
		p:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 32, 260)
	end
	lookAcc = 0
	p:Show()
	return p
end

-- The Chat tab's line (the player's click): a tab named Sylvanistas there already, the chats go to
-- it at once; else the pointer shows and the game's chat windows are read until it is there.
-- With Chattynator (1.1.2), no pointer (the game's tabs are hidden behind Chattynator's, and
-- ChatFrame1Tab is said shown there: the pointer would point at nothing; one shown before
-- Chattynator answered goes): the channels go to its tab named Sylvanistas now, the lines landing there
-- the moment it exists, and chat says how to make it (Channels.SetupTab).
-- Returns true when the chats went to it, false when it is awaited, nil when there is no way.
function ChatWindow.AddTab()
	if not TabReady() then return nil end
	local C = ns.Channels
	if C.TabState() == "open" then
		MarkDirty()
		return true
	end
	watching, lookAcc, sent = true, 0, false
	if Look() then return true end
	if Chatty() then
		if pointer then pointer:Hide() end
		C.SetupTab()
		sent = true
	else
		ShowPointer()
	end
	MarkDirty()
	return false
end

-- A click on the steps while the tab is awaited: the pointer again; with Chattynator, the steps
-- said again in chat (AddTab).
local function StepsAgain()
	if Chatty() then ChatWindow.AddTab() else ShowPointer() end
end
function ChatWindow.Watching() return watching end
function ChatWindow.Pointer() return pointer end -- (tests)

-- (And drawn again: the settings name each channel's window, "gone" while it is not open, and the
-- Sylvanistas tab's state; the line over the lines follows that state too. The review of the page's
-- removal: a window closed or opened while they showed left them stale.)
for _, event in ipairs({ "UPDATE_CHAT_WINDOWS", "UPDATE_FLOATING_CHAT_WINDOWS" }) do
	ns.RegisterEvent(event, function()
		if watching then Look() end
		MarkDirty()
	end)
end

-- Whether the line shows, the Sylvanistas tab not open (the review of the Chat tab: it showed for
-- anyone without an open Sylvanistas tab, and nothing put it away). Awaited (the player's click):
-- always, with the steps. Put away with its x: no more. Chosen and not there ("waiting"): yes.
-- Else only while no channel of this character goes to a window of his choosing: a player who
-- sent them to another window (a tab named otherwise, to keep the channel's name there) chose.
local function GuideWanted()
	if watching then return true end
	if TabLineOff() then return false end
	local C = ns.Channels
	if C.TabState() == "waiting" then return true end
	if type(C.ChosenWindow) == "function" then
		for _, t in ipairs(C.ORDER) do
			if C.ChosenWindow(t) then return false end
		end
	end
	return true
end

-- The line over the lines while the Sylvanistas tab is not there: a click adds it (above); awaited,
-- the steps; its x puts it away. Returns the room it takes (none while it does not show).
local function DrawGuide(y)
	local g = frame.guide
	local C = ns.Channels
	if not TabReady() or not C.ChatOn() or C.TabState() == "open" or not GuideWanted() then
		g:Hide()
		return 0
	end
	local text
	if watching then
		text = Grey(TabSteps())
	else
		text = Green("+ " .. L.CHATS_TAB_ADD)
	end
	g.text:SetText(text)
	local width = StripWidth() - GUIDE_X -- (clear of its x)
	g.text:SetWidth(width)
	local h = math.min(TextHeight(g.text, width), GUIDE_LINES * LINE_H)
	g:SetHeight(h)
	Strip(g, y)
	g:Show()
	return h + 6
end

---------------------------------------------------------------------------
-- The settings (the gear at the top row's end, in place of the lines; its click again, or the
-- first line, goes back). What the Realm tab's "Sylvanistas chats" page offered and the lines do not,
-- the page gone (the author's call): the chats on or off on this client and what that means (the
-- first-open page's choice, Consent.lua), whether the channel is public (Views.PublicLines), the
-- Sylvanistas tab of the game's chat (the guided way above), and the pinned line for whoever may pin;
-- and each channel in the game's chat (muted there or not, /syl mute; and the chat window it goes
-- to, as /syl chatwindow picks it). Every change goes through the code its command runs (and says
-- so in chat as that command does): the game's chat windows are only read here, never made,
-- named or set up. ChatWindow.SettingsLines gives the lines (text, onClick, tip, header, indent,
-- gap), as the tests read them.
---------------------------------------------------------------------------

local function MutedInChat(t)
	return ns.db ~= nil and type(ns.db.chatMute) == "table" and ns.db.chatMute[t] and true or false
end

-- The window of the game's chat a channel goes to, as /syl chatwindow and /syl status say it: the
-- main one, else the window chosen, "(gone: ...)" while it is not open.
local function WhereText(t)
	local C = ns.Channels
	local name = type(C.ChosenWindow) == "function" and C.ChosenWindow(t) or nil
	if not name then return L.CHATWIN_MAIN_NAME end
	local there
	if type(C.IsTabName) == "function" and C.IsTabName(name) and type(C.FindTab) == "function" then there = C.FindTab() end
	if not there and type(C.FindWindow) == "function" then there = C.FindWindow(name) end
	return '"' .. ns.Codec.Plain(name) .. '"' .. (there and "" or " " .. L.CHATWIN_GONE_TAG)
end

-- A click on a channel's window: the next one open in the game's chat after the one it goes to
-- (the main one, then the others in their order, then the main one again), through
-- /syl chatwindow's own code (Channels.ChooseWindow, by the window's number). With Chattynator
-- (1.1.2), its tabs in their order, each by its name (Channels.ChooseTab: a tab called "main" or
-- "2" would read otherwise in /syl chatwindow's words).
local function NextWindow(t)
	local C = ns.Channels
	if type(C.OpenWindows) ~= "function" or type(C.ChooseWindow) ~= "function" then return end
	-- One window for each name (the first of it): the choice is a name, and a name picks the first
	-- window of it, so a second one could never be passed (the review of 1.1.2: Chattynator names
	-- each new tab "New tab", and two of them kept the click there, on and on).
	local list, seen = {}, {}
	for _, w in ipairs(C.OpenWindows()) do
		local key = Trim(w.name):lower()
		local rawKey = type(w.raw) == "string" and Trim(w.raw):lower() or key
		if not seen[key] and not seen[rawKey] then list[#list + 1] = w end
		seen[key], seen[rawKey] = true, true
	end
	local current = type(C.ChosenWindow) == "function" and C.ChosenWindow(t) or nil
	local at = 0 -- (the main window)
	if current then
		local key = Trim(current):lower()
		for i, w in ipairs(list) do
			local named = Trim(w.name):lower() == key or (type(w.raw) == "string" and Trim(w.raw):lower() == key)
			if named and at == 0 then at = i end
		end
	end
	local word = C.TIERS[t].word
	local nxt = list[at + 1]
	if not nxt then
		C.ChooseWindow("main " .. word)
	elseif nxt.index then
		C.ChooseWindow(nxt.index .. " " .. word)
	elseif type(C.ChooseTab) == "function" then
		C.ChooseTab(nxt.name, t)
	end
end

function ChatWindow.SettingsLines()
	local C = ns.Channels
	local out = {}
	local function Add(l) out[#out + 1] = l end
	local newWindow = GameWord(NEW_CHAT_WINDOW, L.CHATWIN_NEW)
	Add({ text = Gold(L.CHATSET_BACK), onClick = function() ChatWindow.ShowSettings(false) end, gap = true })
	-- The chats on this client, and what the choice means.
	local on = C.ChatOn()
	Add({ header = true, text = Gold(L.CONSENT_CHAT) })
	Add({ indent = true, text = on and Green(L.CHATSET_CHATS_ON) or Grey(L.CHATSET_CHATS_OFF),
		onClick = function() ns.Consent.Show() end,
		tip = function(tt)
			tt:AddLine(L.CONSENT_CHAT, 1, 0.82, 0)
			tt:AddLine(L.CONSENT_CHAT_TEXT, 1, 1, 1, true)
		end })
	-- Who can read these lines: the channel public, as the Census and the Realm say it.
	local V = ns.Views
	if V and type(V.PublicLines) == "function" then
		local public = {}
		V.PublicLines(public)
		for _, l in ipairs(public) do Add({ indent = true, text = l.text, tip = l.tooltip, onClick = l.onClick }) end
	end
	out[#out].gap = true
	-- Each channel this rank reads, in the game's chat.
	for _, t in ipairs(Readable()) do
		local word = C.TIERS[t].word
		Add({ header = true, text = "|c" .. Hex(Colour(t)) .. "[" .. Label(t) .. "]|r" })
		if type(C.ToggleMute) == "function" then
			Add({ indent = true, text = MutedInChat(t) and Grey(L.CHATSET_MUTED) or L.CHATSET_SHOWN,
				onClick = function()
					C.ToggleMute(word)
					Render()
				end,
				tip = function(tt)
					tt:AddLine("[" .. Label(t) .. "]", 1, 0.82, 0)
					tt:AddLine(L.CHATSET_MUTE_TIP:format(word), 1, 1, 1, true)
				end })
		end
		local choose = type(C.OpenWindows) == "function" and type(C.ChooseWindow) == "function"
		Add({ indent = true, text = L.CHATSET_WHERE:format(WhereText(t)) .. (choose and (" " .. Grey(L.CHATSET_WHERE_NEXT)) or ""),
			onClick = choose and function()
				NextWindow(t)
				Render()
			end or nil,
			tip = function(tt)
				tt:AddLine("[" .. Label(t) .. "]", 1, 0.82, 0)
				tt:AddLine(Chatty() and L.CHATSET_WHERE_TIP_CHATTY or L.CHATSET_WHERE_TIP:format(newWindow), 1, 1, 1, true)
			end })
		out[#out].gap = true
	end
	-- The Sylvanistas tab of the game's chat (the line over the lines, put away or not).
	if TabReady() then
		Add({ header = true, text = Gold(L.CHATSET_TAB) })
		local state = C.TabState()
		local function AddTip(tt)
			tt:AddLine(L.CHATS_TAB_ADD, 1, 0.82, 0)
			tt:AddLine(L.CHATS_TAB_ADD_TIP, 1, 1, 1, true)
		end
		if state == "open" then
			-- (Open: a click sends all three channels there again, SetupTab saying so.)
			Add({ indent = true, text = Grey(L.CHATS_TAB_ON), onClick = function()
				C.SetupTab()
				Render()
			end, tip = function(tt)
				tt:AddLine(L.CHATSET_TAB, 1, 0.82, 0)
				tt:AddLine(L.CHATS_TAB_TIP, 1, 1, 1, true)
			end })
		elseif watching then
			Add({ indent = true, text = Grey(TabSteps()), onClick = function()
				StepsAgain()
				Render()
			end, tip = AddTip })
		else
			Add({ indent = true, text = state == "waiting" and Grey(L.CHATS_TAB_WAITING) or Green("+ " .. L.CHATS_TAB_ADD),
				onClick = function()
					ChatWindow.AddTab()
					Render()
				end, tip = AddTip })
		end
		out[#out].gap = true
	end
	-- The pinned line, for whoever may pin (Channels.CanPin: the King, his Stewards and Hands for
	-- the army, a guild master for his guild), typed in a Sylvanistas dialog (ns.ShowDialog: the
	-- gamepad UI's own window there). Only while the chats are on, where a pin can be set.
	if on and type(C.CanPin) == "function" and C.CanPin() then
		local guildOnly = type(C.PinScope) == "function" and C.PinScope() == "guild"
		local label = guildOnly and L.PIN_ADD_GUILD or L.PIN_ADD
		Add({ header = true, text = Gold(L.PIN_LABEL) })
		Add({ indent = true, text = Green(label), onClick = function() ns.ShowDialog("SYLVANISTAS_PIN") end,
			tip = function(tt)
				tt:AddLine(label, 1, 0.82, 0)
				tt:AddLine(guildOnly and L.PIN_ADD_GUILD_TIP or L.PIN_ADD_TIP, 1, 1, 1, true)
			end, gap = true })
	end
	return out
end

-- A line of the settings, from a pool (made once, reused on every redraw).
local function SettingRow(i)
	local rows = frame.setRows
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, frame.setContent)
	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(true)
	r:SetScript("OnClick", function(self) if self.onClick then ns.SafeCall("chat settings", self.onClick) end end)
	r:SetScript("OnEnter", function(self) if self.tip then Tip(self, self.tip) end end)
	r:SetScript("OnLeave", function(self) Untip(self) end)
	rows[i] = r
	return r
end

local function DrawSettings()
	local s = frame.setScroll
	local width = s:GetWidth()
	if not Finite(width) or width <= 0 then width = (frame:GetWidth() or 338) - 20 - (frame.barRoom or 22) end
	width = math.max(100, math.floor(width))
	frame.setContent:SetWidth(width)
	local y, n = 8, 0
	for _, l in ipairs(ChatWindow.SettingsLines()) do
		n = n + 1
		local r = SettingRow(n)
		local x = EDGE + (l.indent and INDENT or 0)
		local w = math.max(40, width - x - EDGE)
		if r.text.SetFontObject then r.text:SetFontObject(l.header and "GameFontNormal" or "GameFontHighlightSmall") end
		r.text:SetText(l.text)
		r.text:SetWidth(w)
		local h = TextHeight(r.text, w)
		r:SetSize(w, h)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", frame.setContent, "TOPLEFT", x, -y)
		r.onClick, r.tip, r.line = l.onClick, l.tip, l
		r:EnableMouse(l.onClick ~= nil or l.tip ~= nil)
		r:Show()
		y = y + h + (l.gap and 12 or (l.header and 4 or 3))
	end
	for i = n + 1, #frame.setRows do
		local r = frame.setRows[i]
		r:Hide()
		r.onClick, r.tip, r.line = nil, nil, nil
	end
	frame.setContent:SetHeight(math.max(1, y + 4))
end

---------------------------------------------------------------------------
-- The box to write in, and the search box.
---------------------------------------------------------------------------

-- The box: the channel's label on its left, a grey hint while empty (the moderators' word when
-- they took us off).
local function DrawInput()
	local eb = frame.input
	eb.label:SetText("|c" .. Hex(Colour(tier)) .. "[" .. Label(tier) .. "]:|r")
	local lw = math.ceil(TextWidth(eb.label))
	eb:SetTextInsets(lw + 6, 6, 0, 0)
	local M = ns.Moderation
	local off = M and type(M.SelfOff) == "function" and M.SelfOff() or nil
	local hint
	if off and type(M.YouText) == "function" then
		hint = M.YouText(off)
	else
		local public = ns.Comm and type(ns.Comm.IsPublic) == "function" and ns.Comm.IsPublic()
		hint = L.CHATWIN_PLACEHOLDER:format(Label(tier)) .. (public and L.CHATWIN_PUBLIC or "")
	end
	eb.hint:SetText(hint)
	eb.hint:ClearAllPoints()
	eb.hint:SetPoint("LEFT", eb, "LEFT", lw + 6, 0)
	eb.hint:SetPoint("RIGHT", eb, "RIGHT", -6, 0)
	Hint()
end

-- The search box shows what the tab's search holds (Views keeps it for the session, as each tab's).
local function DrawSearch()
	local V = ns.Views
	local text = V and type(V.Filter) == "function" and V.Filter(TAB) or ""
	local sb = frame.search
	if (sb:GetText() or "") ~= text then sb:SetText(text) end
	sb.clear:SetShown(text ~= "")
end

---------------------------------------------------------------------------
-- The game's key to start typing (1.1.1, the owner's ask after trying the tab: with the Chat tab
-- open, the key that starts typing starts typing in it). While the tab shows with the chats on,
-- the key or keys the player bound to the game's "Open chat" (OPENCHAT, Bindings_Standard.xml;
-- read with GetBindingKey, never assumed, usually Enter) click Sylvanistas's own button, which puts
-- the keyboard in the tab's box: an override binding that button owns (SetOverrideBindingClick),
-- taken off (ClearOverrideBindings on it) the moment the tab hides, the window closes, another tab
-- is picked or the chats go off. Nothing of the game's chat box is opened, hooked or written (the
-- rules at the top of the file); "/" (OPENCHATSLASH) stays the game's, where commands run.
-- The game lets no addon change a binding in combat (secure code does it there, the restricted
-- environment's SetBindingClick and ClearBindings, RestrictedFrames.lua): a change asked in combat
-- waits for PLAYER_REGEN_ENABLED and is then what the tab is (still open: set; gone: taken off).
-- The key pressed in combat with the tab gone does nothing but say so, once a fight. With the
-- gamepad UI none of this (its own code keeps override bindings on UIParent, InputBindingManager):
-- no binding, the box a click only. A binding change runs the game's UPDATE_BINDINGS handlers from
-- ours at once (a synchronous event), the gamepad UI's among them (ActionBarEditFrame.lua, the HUD
-- bags), so under it Sylvanistas changes none, with one exception: the key ours still holds at the
-- switch to it (INPUT_DEVICE_INTERFACE_TRANSITION, the game rebinding everything itself) goes back
-- to the game there or, switched in a fight, when that fight ends. Switched back, bound at once.
---------------------------------------------------------------------------

local KEY_ACTION = "OPENCHAT"
local SLASH_ACTION = "OPENCHATSLASH"
local KEY_BUTTON = "SylvanistasChatKey"
local SyncKeys

local function InCombat() return InCombatLockdown ~= nil and InCombatLockdown() == true end

-- The keys bound to the game's "Open chat" (its bindings: GetBindingKey leaves the overrides out
-- unless asked, so ours never hides them): none, one or two.
local function Keys(ok, ...)
	local out = {}
	if not ok then return out end
	for i = 1, select("#", ...) do
		local k = select(i, ...)
		if type(k) == "string" and k ~= "" then out[#out + 1] = k end
	end
	return out
end
local function ChatKeys()
	if type(GetBindingKey) ~= "function" then return {} end
	return Keys(pcall(GetBindingKey, KEY_ACTION))
end

-- The key the player bound to the game's "Open chat with /" (OPENCHATSLASH), as the game names it
-- (GetBindingText): nil when none is bound (never assumed to be "/"). A message ending with the way
-- to the game's chat box names it (line: its words, the key's place a %s), or says nothing of it.
local function SlashKey()
	if type(GetBindingKey) ~= "function" then return nil end
	local key = Keys(pcall(GetBindingKey, SLASH_ACTION))[1]
	if not key then return nil end
	if type(GetBindingText) == "function" then
		local ok, text = pcall(GetBindingText, key)
		if ok and type(text) == "string" and text ~= "" then return text end
	end
	return key
end
local function WithSlashKey(said, line)
	local key = SlashKey()
	if not key then return said end
	return said .. " " .. line:format(key)
end

-- The gamepad UI on: at a switch, the style it switches to (the event's newMode, as Borders.lua
-- reads it); else the game's current one.
local function GamepadStyle(newMode)
	local gamepad = Enum and Enum.InputDeviceInterfaceType and Enum.InputDeviceInterfaceType.Gamepad
	if newMode ~= nil and gamepad ~= nil then return newMode == gamepad end
	return ns.GamepadUI()
end

-- The tab in sight (UIParent hidden with Alt-Z: not), the chats on, mouse and keyboard.
local function KeysWanted(gamepad)
	if gamepad == nil then gamepad = ns.GamepadUI() end
	if gamepad or not Shown() then return false end
	if frame.IsVisible and not frame:IsVisible() then return false end
	return ns.Channels.ChatOn() and true or false
end

-- The key pressed (our binding's click, on the press): the keyboard to the tab's box, its lines in
-- place of the settings. The tab gone (a fight kept the binding): said, once a fight.
local function KeyPressed(down)
	if down == false then return end -- (the release: the press did it)
	if not KeysWanted() then
		if InCombat() and not toldLater then
			toldLater = true
			ns.Print(WithSlashKey(L.CHATWIN_KEY_LATER, L.CHATWIN_KEY_LATER_SLASH))
		end
		SyncKeys()
		return
	end
	if settings then ChatWindow.ShowSettings(false) end
	CloseMenu()
	local eb = frame.input
	if eb:IsShown() then ns.Focus(eb) end
end

local function KeyButton()
	if keyButton then return keyButton end
	local b = CreateFrame("Button", KEY_BUTTON, UIParent)
	-- On the press, as the game's own binding runs: the release finds the box open (and after an
	-- empty Enter let the keyboard go, the release does not take it back).
	b:RegisterForClicks("AnyDown")
	b:SetScript("OnClick", function(_, _, down) ns.SafeCall("chat tab key", KeyPressed, down) end)
	keyButton = b
	return b
end

local function SameKeys(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- The binding made what the tab is now (or, in combat, when the fight ends). With the gamepad UI
-- nothing is changed but when due: at the switch between the two (gamepad: the style switched to)
-- or at the end of the fight that held a change, the key ours still holds goes back to the game.
SyncKeys = function(due, gamepad)
	if syncing then return end
	if gamepad == nil then gamepad = ns.GamepadUI() end
	if gamepad and not due then return end
	local keys = KeysWanted(gamepad) and ChatKeys() or {}
	if SameKeys(keys, boundKeys or {}) then
		keysLater = false
		return
	end
	if InCombat() then
		keysLater = true
		return
	end
	if type(SetOverrideBindingClick) ~= "function" or type(ClearOverrideBindings) ~= "function" then return end
	syncing = true
	local ok, err = pcall(function()
		local b = KeyButton()
		boundKeys = #keys > 0 and keys or nil
		ClearOverrideBindings(b)
		for _, k in ipairs(keys) do SetOverrideBindingClick(b, false, k, KEY_BUTTON, "LeftButton") end
	end)
	syncing, keysLater = false, false
	if not ok then error(err, 0) end
end

-- What the box shows: "lines" (the chats on: the lines, and the box to write in), "off" (the chats
-- off on this client: the choice, and a way to it) or "settings" (the gear's). The top row is
-- DrawTop's.
local function ShowParts(mode)
	local lines = mode == "lines"
	frame.scroll:SetShown(lines)
	frame.input:SetShown(lines)
	frame.off:SetShown(mode == "off")
	frame.setScroll:SetShown(mode == "settings")
	if not lines then
		frame.newPill:Hide()
		frame.guide:Hide()
		frame.hiddenCount:Hide()
	end
	if mode == "settings" then frame.pin:Hide() end
end

local function Draw()
	if not frame or not frame.places then return end
	local C = ns.Channels
	local tiers = Readable()
	-- A rank that reads none of the channels any more (out of Sylvanistas): the tab goes, and the
	-- window with it on the Census (UI.Refresh).
	if #tiers == 0 then
		frame:Hide()
		if ns.UI and type(ns.UI.Refresh) == "function" then ns.SafeCall("chat tab", ns.UI.Refresh) end
		return
	end
	if not tier or not C.CanUse(tier) then
		tier = tiers[1]
		Remember(tier)
	end
	local on = C.ChatOn()
	DrawTop(tiers, on)
	local box = frame.places.box
	local y = box.top
	-- The settings: from the top row down, no strip over them.
	if settings then
		frame.box:SetPoint("TOPLEFT", frame, "TOPLEFT", box.left, y)
		ShowParts("settings")
		DrawSettings()
		return
	end
	-- The strips over the lines, each taking room only while it shows: the pinned line, the way to
	-- the Sylvanistas tab, the count of the lines the block terms hide (nearest the lines it counts).
	y = y - DrawPin(y)
	local all = on and C.History(tier) or nil -- (read once, for the count and the lines)
	if on then
		y = y - DrawGuide(y)
		y = y - DrawHiddenCount(y, all)
	end
	frame.box:SetPoint("TOPLEFT", frame, "TOPLEFT", box.left, y)
	ShowParts(on and "lines" or "off")
	if not on then
		-- As the Realm tab says it (its chats' line, CONSENT_CHAT_TEXT), with the choice a click away.
		frame.off.text:SetText(L.CHATWIN_OFF .. "\n\n" .. L.CONSENT_CHAT_TEXT)
		return
	end
	DrawSearch()
	DrawInput()
	local was = not stick and InView() or nil
	DrawLines(all)
	if stick then
		want = nil
		ToBottom()
	elseif was and #was > 0 then
		BackInView(was)
	else
		want = nil -- (no line in view: the offset stays as the player left it)
	end
	ShowNew()
end

function ChatWindow.Render()
	dirty = false
	Draw()
	-- (The "Open chat" key follows: the chats on or off, the tab gone with the last channel.)
	ns.SafeCall("chat tab key", SyncKeys)
end

-- The settings in place of the lines (the gear), or the lines again. Never takes the keyboard.
function ChatWindow.ShowSettings(on)
	settings = on and true or false
	CloseMenu()
	if not frame then return end
	if settings then
		frame.input:ClearFocus()
		frame.search:ClearFocus()
	else
		stick, newCount, want = true, 0, nil
	end
	if Shown() then Render() end
end
function ChatWindow.SettingsShown() return settings end

---------------------------------------------------------------------------
-- Writing: Sylvanistas's own box, through Channels.Send (every check and refusal is Send's).
---------------------------------------------------------------------------

local function Select(t)
	local C = ns.Channels
	local d = C.TIERS[t]
	if not d then return end
	if not C.CanUse(t) then
		ns.Print(L[d.deny]:format(L[d.label]))
		return
	end
	tier = t
	unread[t] = nil
	Remember(t)
	CloseMenu()
	settings = false -- (a channel picked: its lines, not the settings)
	if Shown() then
		stick, newCount = true, 0
		Render()
		ScrollToBottom()
	end
end

local function NextTier()
	local tiers = Readable()
	if #tiers < 2 then return end
	local at = 1
	for i, t in ipairs(tiers) do
		if t == tier then at = i end
	end
	Select(tiers[at % #tiers + 1])
end

local function Submit()
	if not frame or not tier then return end
	local eb = frame.input
	local text = Trim(eb:GetText())
	-- With mouse and keyboard the cursor stays for the next line (the owner's ask: Enter, type,
	-- Enter, type), with a refused line or a command kept in the box too; an empty Enter lets the
	-- keyboard go back to the game, and so does the privacy warning (its Send or Cancel is next).
	-- With the gamepad UI, as the Communities box: every Enter lets it go.
	local keep = not ns.GamepadUI()
	if text == "" then
		eb:SetText("")
		keep = false
	elseif text:sub(1, 1) == "/" then
		-- This box runs no command and never hands one to the game: the text stays, nothing is sent.
		-- With the cursor kept, the way to the game's box too: Escape, then the player's own key for
		-- it (the open-chat key comes back here; the gamepad UI's box already let go, as before).
		local said = L.CHATWIN_NO_SLASH:format(Label(tier))
		if keep then said = WithSlashKey(said, L.CHATWIN_SLASH_WAY) end
		ns.Print(said)
	else
		-- keepMute: a channel muted in chat stays muted there (this tab shows it all the same).
		local ok, why = ns.Channels.Send(tier, text, nil, true)
		-- Sent, or held by the privacy warning (it sends the line on the player's OK): the box
		-- empties. Refused: the text stays (Send said why).
		if ok or why == "confirm" then
			eb:SetText("")
			if ok then notes[tier] = nil end
			ScrollToBottom()
			MarkDirty()
		end
		if why == "confirm" then keep = false end
	end
	if not keep then eb:ClearFocus() end
	Hint()
end

-- Typed in the search box: the tab's search (Views.SetFilter, kept with the tab for the session),
-- the lines drawn again from the newest match.
local function SearchChanged(sb)
	local V = ns.Views
	local text = sb:GetText() or ""
	sb.clear:SetShown(text ~= "")
	if not V or type(V.SetFilter) ~= "function" or text == V.Filter(TAB) then return end
	V.SetFilter(TAB, text)
	stick, newCount, want = true, 0, nil
	MarkDirty()
end

---------------------------------------------------------------------------
-- The tab, made once for each Sylvanistas window
---------------------------------------------------------------------------

local function OnUpdate(_, elapsed)
	local step = tonumber(elapsed) or 0
	acc = acc + step
	if watching then
		lookAcc = lookAcc + step
		if lookAcc >= LOOK_GAP and not (pointer and pointer:IsShown()) then
			lookAcc = 0
			ns.SafeCall("sylvanistas tab", Look)
		end
	end
	if acc < THROTTLE then return end
	acc = 0
	if dataPending and GetTime() - lastData >= DATA_GAP then
		dataPending, lastData, dirty = false, GetTime(), true
	end
	-- A rank that no longer reads this channel (a demotion, out of the guild): drawn again at once.
	if tier and not ns.Channels.CanUse(tier) then dirty = true end
	if dirty then ns.SafeCall("chat tab", Render) end
end

-- A texture from the game's atlas when this client has it, else a file every client carries.
local function Icon(tex, atlas, file)
	local info = C_Texture and C_Texture.GetAtlasInfo
	local ok, found = false, nil
	if type(info) == "function" and type(tex.SetAtlas) == "function" then ok, found = pcall(info, atlas) end
	if ok and found ~= nil then
		tex:SetAtlas(atlas)
	else
		tex:SetTexture(file)
		if file == GEAR_FILE then tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end -- (an icon's border off)
	end
end

-- A thin dark frame with the tooltip's border (the bubbles' look): the switch and its list.
local function Framed(kind, parent)
	local ok, f = pcall(CreateFrame, kind, nil, parent, "BackdropTemplate")
	if not ok or not f then f = CreateFrame(kind, nil, parent) end
	if f.SetBackdrop then
		f:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		if f.SetBackdropColor then f:SetBackdropColor(0.06, 0.06, 0.07, 0.95) end
		if f.SetBackdropBorderColor then f:SetBackdropBorderColor(0.5, 0.5, 0.5, 1) end
	else
		local bg = f:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.06, 0.06, 0.07, 0.95)
	end
	return f
end

-- The channels' switch on the top row: the channel shown and its arrow; a click lists the channels
-- the rank reads (its own list, Sylvanistas's frames: no game dropdown), a click there picks one.
local function MakeSwitch(p)
	local b = Framed("Button", p)
	b:SetHeight(SEARCH_H)
	b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.text:SetPoint("LEFT", b, "LEFT", 8, 0)
	b.count = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.count:SetPoint("LEFT", b.text, "RIGHT", 4, 0)
	b.count:SetTextColor(1, 0.82, 0)
	b.arrow = b:CreateTexture(nil, "OVERLAY")
	b.arrow:SetSize(ARROW_W, ARROW_W)
	b.arrow:SetPoint("RIGHT", b, "RIGHT", -4, 0)
	b.arrow:SetTexture(ARROW_FILE)
	b:SetScript("OnClick", function() ns.SafeCall("chat tab channels", ToggleMenu) end)
	b:SetScript("OnEnter", function(self)
		Tip(self, function(tt)
			tt:AddLine("[" .. Label(tier) .. "]", 1, 0.82, 0)
			tt:AddLine(L.CHATSET_SWITCH_TIP, 1, 1, 1, true)
			for _, t in ipairs(Readable()) do
				local n = unread[t] or 0
				if t ~= tier and n > 0 then tt:AddLine(L.CHATWIN_NEW_IN:format(Label(t), n), 0.7, 0.7, 0.7) end
			end
		end)
	end)
	b:SetScript("OnLeave", function(self) Untip(self) end)
	b:Hide()
	p.switch = b
	-- Its list, over everything in the tab, and under it a catcher the size of the tab: a click
	-- anywhere else closes the list.
	local c = CreateFrame("Button", nil, p)
	c:SetAllPoints(p)
	c:SetFrameLevel((p:GetFrameLevel() or 1) + 30)
	c:SetScript("OnClick", function() ns.SafeCall("chat tab channels", CloseMenu) end)
	c:Hide()
	p.catcher = c
	local m = Framed("Frame", p)
	m:SetFrameLevel((p:GetFrameLevel() or 1) + 40)
	m:EnableMouse(true)
	m.rows = {}
	for _, t in ipairs(ns.Channels.ORDER) do
		local r = CreateFrame("Button", nil, m)
		r.tier = t
		r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		r.text:SetPoint("LEFT", r, "LEFT", 10, 0)
		-- (The one shown: a bar in its colour at its left.)
		r.mark = r:CreateTexture(nil, "ARTWORK")
		r.mark:SetWidth(2)
		r.mark:SetPoint("TOPLEFT", r, "TOPLEFT", 2, -4)
		r.mark:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 2, 4)
		r:SetScript("OnClick", function(self) ns.SafeCall("chat tab channel", Select, self.tier) end)
		r:SetScript("OnEnter", function(self)
			self.hover = true
			PaintChoice(self)
			Tip(self, function(tt)
				tt:AddLine("[" .. Label(self.tier) .. "]", 1, 0.82, 0)
				-- The tab shows a channel muted in chat (/syl mute is about the chat frame).
				if MutedInChat(self.tier) then tt:AddLine(L.CHATWIN_MUTED_TIP, 0.7, 0.7, 0.7, true) end
			end)
		end)
		r:SetScript("OnLeave", function(self)
			self.hover = nil
			PaintChoice(self)
			Untip(self)
		end)
		m.rows[t] = r
	end
	m:Hide()
	p.menu = m
end

-- The gear at the top row's end: the settings in place of the lines, and back.
local function MakeGear(p)
	local g = CreateFrame("Button", nil, p)
	g:SetSize(GEAR_W, GEAR_W)
	g.icon = g:CreateTexture(nil, "ARTWORK")
	g.icon:SetSize(16, 16)
	g.icon:SetPoint("CENTER", g, "CENTER", 0, 0)
	Icon(g.icon, GEAR_ATLAS, GEAR_FILE)
	g:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	g:SetScript("OnClick", function() ns.SafeCall("chat settings", ChatWindow.ShowSettings, not settings) end)
	g:SetScript("OnEnter", function(self)
		Tip(self, function(tt)
			tt:AddLine(L.CHATSET_TITLE, 1, 0.82, 0)
			tt:AddLine(L.CHATSET_TIP, 1, 1, 1, true)
		end)
	end)
	g:SetScript("OnLeave", function(self) Untip(self) end)
	p.gear = g
	-- The settings' title, where the search box is while they show.
	p.setTitle = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	p.setTitle:SetText(L.CHATSET_TITLE)
	p.setTitle:Hide()
end

local function Button(parent, text, width)
	local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
	if not ok or not b then
		b = CreateFrame("Button", nil, parent)
		b:SetNormalFontObject("GameFontNormal")
	end
	b:SetSize(width, 22)
	b:SetText(text)
	return b
end

-- 1.1.2: the tab's "?" (its explanation, Answers.lua), on the top row, and the Answers button (the
-- author, the High Council and the Stewards: a ready answer into this box, Answers.lua), at the
-- box's end (PlaceInput).
local function MakeHelp(p)
	local h = CreateFrame("Button", nil, p)
	h:SetSize(GEAR_W, GEAR_W)
	h.icon = h:CreateTexture(nil, "ARTWORK")
	h.icon:SetSize(18, 18)
	h.icon:SetPoint("CENTER", h, "CENTER", 0, 0)
	h.icon:SetTexture("Interface\\Common\\help-i")
	h:SetHighlightTexture("Interface\\Common\\help-i", "ADD")
	h:SetScript("OnClick", function()
		ns.SafeCall("chat help", function() if ns.Answers and ns.Answers.ExplainPage then ns.Answers.ExplainPage("chat/") end end)
	end)
	h:SetScript("OnEnter", function(self)
		Tip(self, function(tt)
			tt:AddLine(L.PAGE_HELP, 1, 0.82, 0)
			tt:AddLine(L.PAGE_HELP_TIP, 1, 1, 1, true)
		end)
	end)
	h:SetScript("OnLeave", function(self) Untip(self) end)
	p.help = h
	local a = Button(p, L.ANSWERS_BTN, 70)
	a:SetHeight(SEARCH_H)
	a:SetScript("OnClick", function()
		ns.SafeCall("chat answers", function() if ns.Answers and ns.Answers.Open then ns.Answers.Open(p.input) end end)
	end)
	a:SetScript("OnEnter", function(self)
		Tip(self, function(tt)
			tt:AddLine(L.ANSWERS_BTN, 1, 0.82, 0)
			tt:AddLine(L.ANSWERS_BTN_TIP, 1, 1, 1, true)
		end)
	end)
	a:SetScript("OnLeave", function(self) Untip(self) end)
	a:Hide()
	p.answers = a
end

-- A strip over the lines (the pinned line, the Sylvanistas tab's line, the count of the hidden lines): a
-- button with wrapped text.
local function StripButton(p, lines)
	local s = CreateFrame("Button", nil, p)
	s.text = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	s.text:SetPoint("TOPLEFT", s, "TOPLEFT", 0, 0)
	s.text:SetJustifyH("LEFT")
	s.text:SetWordWrap(true)
	if s.text.SetMaxLines then s.text:SetMaxLines(lines) end
	s:SetScript("OnEnter", function(self) if self.tip then Tip(self, self.tip) end end)
	s:SetScript("OnLeave", function(self) Untip(self) end)
	s:Hide()
	return s
end

-- The "x" at the end of the search box, as every tab's (Views.lua): empties it and lets go of the
-- keyboard. A button of its own, never a focus change.
local function ClearButton(sb)
	local x = CreateFrame("Button", nil, sb)
	x:SetSize(16, 16)
	x:SetPoint("RIGHT", sb, "RIGHT", -2, 0)
	x.label = x:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	x.label:SetPoint("CENTER", x, "CENTER", 0, 1)
	x.label:SetText("x")
	x:SetScript("OnClick", function()
		sb:SetText("")
		sb:ClearFocus()
		ns.SafeCall("chat tab search", SearchChanged, sb)
	end)
	x:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L.SEARCH_CLEAR, 1, 0.82, 0)
		GameTooltip:Show()
	end)
	x:SetScript("OnLeave", function() GameTooltip:Hide() end)
	x:Hide()
	return x
end

local function Build(h)
	if panes[h] then return panes[h] end
	local base = (h.GetName and h:GetName() or "Sylvanistas") .. "Chat"
	local p = CreateFrame("Frame", base, h)
	p:Hide() -- (nothing in it shown, nor its box, before it is ready)
	panes[h] = p
	p.host = h
	p:SetAllPoints(h)
	p.bubbles, p.rows, p.setRows = {}, {}, {}

	-- The search, where the other tabs show the army's counts.
	p.searchLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	p.searchLabel:SetText(L.SEARCH)
	local okSearch, sb = pcall(CreateFrame, "EditBox", nil, p, "InputBoxTemplate")
	if not okSearch or not sb then sb = CreateFrame("EditBox", nil, p) end
	sb:SetAutoFocus(false)
	sb.sylvanistasBox = true
	sb:SetHeight(SEARCH_H)
	sb:SetMaxLetters(40)
	sb:SetFontObject("ChatFontNormal")
	sb:SetTextInsets(0, 18, 0, 0) -- (the typing stops short of the "x")
	sb.clear = ClearButton(sb)
	sb:SetScript("OnTextChanged", function(self) ns.SafeCall("chat tab search", SearchChanged, self) end)
	sb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	sb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	sb:SetScript("OnHide", function(self) self:ClearFocus() end)
	sb:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L.SEARCH, 1, 0.82, 0)
		GameTooltip:AddLine(L.SEARCH_TIP_CHAT, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	sb:SetScript("OnLeave", function() GameTooltip:Hide() end)
	p.search = sb

	-- On the same row, right of the search: the channels' switch, and the gear at the row's end.
	MakeSwitch(p)
	MakeGear(p)
	MakeHelp(p)

	-- The pinned line.
	p.pin = StripButton(p, PIN_LINES)
	p.pin:SetScript("OnClick", function(self) if self.onClick then ns.SafeCall("chat tab pin", self.onClick) end end)

	-- The count of the lines the block terms hide.
	p.hiddenCount = StripButton(p, COUNT_LINES)
	p.hiddenCount:SetScript("OnClick", function(self) if self.onClick then ns.SafeCall("chat tab hidden", self.onClick) end end)
	p.hiddenCount.tip = function(tt)
		tt:AddLine(L.FILTER_TIP_TITLE, 1, 0.82, 0)
		tt:AddLine(L.FILTER_TIP, 1, 1, 1, true)
	end

	-- The way to the Sylvanistas tab of the game's chat.
	p.guide = StripButton(p, GUIDE_LINES)
	p.guide:SetScript("OnClick", function()
		ns.SafeCall("sylvanistas tab", function()
			if watching then StepsAgain() else ChatWindow.AddTab() end
			Render()
		end)
	end)
	p.guide.tip = function(tt)
		tt:AddLine(L.CHATS_TAB_ADD, 1, 0.82, 0)
		tt:AddLine(L.CHATS_TAB_ADD_TIP, 1, 1, 1, true)
	end
	-- Its x: the line put away for good (the review of the Chat tab: a player who keeps his chats
	-- in the main window had it there always); the pointer goes, and the game's chat windows are no
	-- longer read. The settings (the gear) and /syl chatwindow tab still make the Sylvanistas tab.
	local away = CreateFrame("Button", nil, p.guide)
	away:SetSize(16, 16)
	away:SetPoint("TOPRIGHT", p.guide, "TOPRIGHT", 2, 2)
	away.label = away:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	away.label:SetPoint("CENTER", away, "CENTER", 0, 1)
	away.label:SetText("x")
	away:SetScript("OnClick", function()
		ns.SafeCall("sylvanistas tab", function()
			PutTabLineAway()
			StopWatching()
			Render()
		end)
	end)
	away:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L.CHATS_TAB_AWAY, 1, 0.82, 0)
		GameTooltip:AddLine(L.CHATS_TAB_AWAY_TIP, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	away:SetScript("OnLeave", function() GameTooltip:Hide() end)
	p.guide.away = away

	-- The box of lines (the Communities chat pane's inset), its scroll frame and its lines: over
	-- the list's and the detail box's room.
	local okBox, box = pcall(CreateFrame, "Frame", nil, p, "InsetFrameTemplate")
	if not okBox or not box then
		box = CreateFrame("Frame", nil, p)
		local bg = box:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0, 0, 0, 0.4)
	end
	p.box = box
	-- (Blizzard's thin scroll bar, else the older one where a client has no ScrollFrameTemplate.)
	local function Scroll(name)
		local okScroll, s = pcall(CreateFrame, "ScrollFrame", name, box, "ScrollFrameTemplate")
		local room = 22 -- (the thin bar sits 6 past the frame's right edge)
		if not okScroll or not s or not s.ScrollBar then
			if okScroll and s then s:Hide() end
			s = CreateFrame("ScrollFrame", name .. "Old", box, "UIPanelScrollFrameTemplate")
			room = 28
		end
		s:SetPoint("TOPLEFT", box, "TOPLEFT", 4, -4)
		s:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -room, 4)
		local c = CreateFrame("Frame", nil, s)
		c:SetSize(10, 10)
		s:SetScrollChild(c)
		return s, c, room
	end
	local scroll, content, room = Scroll(base .. "Scroll")
	p.barRoom = room
	p.scroll, p.content = scroll, content
	scroll:HookScript("OnScrollRangeChanged", function() ns.SafeCall("chat tab place", Held) end)
	scroll:HookScript("OnVerticalScroll", function() ns.SafeCall("chat tab scrolled", Scrolled) end)
	scroll:HookScript("OnMouseWheel", function() ns.SafeCall("chat tab scrolled", Scrolled) end)

	-- "N new": the lines that came while the player looks further up; a click goes down to them.
	p.newPill = Button(box, "", 96)
	p.newPill:SetPoint("BOTTOM", box, "BOTTOM", -(p.barRoom / 2), 8)
	p.newPill:SetFrameLevel((scroll:GetFrameLevel() or 1) + 5)
	p.newPill:SetScript("OnClick", function() ns.SafeCall("chat tab new", ScrollToBottom) end)
	p.newPill:Hide()

	-- The chats off on this client: the choice's page (Consent.lua, Sylvanistas's own frame).
	p.off = CreateFrame("Frame", nil, box)
	p.off:SetAllPoints(box)
	p.off.text = p.off:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	p.off.text:SetPoint("TOPLEFT", p.off, "TOPLEFT", 16, -24)
	p.off.text:SetPoint("TOPRIGHT", p.off, "TOPRIGHT", -16, -24)
	p.off.text:SetWordWrap(true)
	p.off.button = Button(p.off, L.CHATWIN_OFF_BUTTON, 110)
	p.off.button:SetPoint("TOP", p.off.text, "BOTTOM", 0, -14)
	p.off.button:SetScript("OnClick", function() ns.SafeCall("chat tab choice", ns.Consent.Show) end)
	p.off:Hide()

	-- The settings (the gear), in the same box, scrolled on their own.
	p.setScroll, p.setContent = Scroll(base .. "Settings")
	p.setScroll:Hide()

	-- The box to write in, across the bottom where the other tabs have their buttons: Sylvanistas's
	-- own, focused only by the player (his click, or his open-chat key while the tab shows: the key's
	-- section above), and no Send button (Enter sends).
	local eb = CreateFrame("EditBox", base .. "Input", p)
	eb:SetAutoFocus(false)
	eb.sylvanistasBox = true
	eb:SetFontObject("ChatFontNormal")
	eb:SetMaxBytes(ns.Codec.CHAT_PARTS * 210 + 1) -- (three parts; Channels.Send splits the line and says when it cuts)
	if eb.SetAltArrowKeyMode then eb:SetAltArrowKeyMode(false) end
	-- The Communities box's border art (CommunitiesChatEditBoxTemplate).
	local left = eb:CreateTexture(nil, "BACKGROUND")
	left:SetTexture("Interface\\ChatFrame\\UI-ChatInputBorder-Left2")
	left:SetSize(32, 32)
	left:SetPoint("LEFT", eb, "LEFT", -10, 0)
	local right = eb:CreateTexture(nil, "BACKGROUND")
	right:SetTexture("Interface\\ChatFrame\\UI-ChatInputBorder-Right2")
	right:SetSize(32, 32)
	right:SetPoint("RIGHT", eb, "RIGHT", 10, 0)
	local mid = eb:CreateTexture(nil, "BACKGROUND")
	mid:SetTexture("Interface\\ChatFrame\\UI-ChatInputBorder-Mid2")
	if mid.SetHorizTile then mid:SetHorizTile(true) end
	mid:SetHeight(32)
	mid:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
	mid:SetPoint("TOPRIGHT", right, "TOPLEFT", 0, 0)
	eb.label = eb:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	eb.label:SetPoint("LEFT", eb, "LEFT", 0, 0)
	eb.hint = eb:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	eb.hint:SetTextColor(0.5, 0.5, 0.5)
	eb.hint:SetJustifyH("LEFT")
	eb.hint:SetWordWrap(false)
	eb:SetScript("OnEnterPressed", function() ns.SafeCall("chat tab send", Submit) end)
	eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	eb:SetScript("OnTabPressed", function() ns.SafeCall("chat tab channel", NextTier) end)
	eb:SetScript("OnTextChanged", function() ns.SafeCall("chat tab box", Hint) end)
	eb:SetScript("OnEditFocusGained", function() ns.SafeCall("chat tab box", Hint) end)
	eb:SetScript("OnEditFocusLost", function() ns.SafeCall("chat tab box", Hint) end)
	eb:SetScript("OnHide", function(self) self:ClearFocus() end)
	p.input = eb

	p:HookScript("OnHide", function()
		eb:ClearFocus()
		sb:ClearFocus()
		p.menu:Hide()
		p.catcher:Hide()
		Untip(tipOwner)
		-- (The "Open chat" key back to the game: another tab, the window closed, the UI hidden.)
		ns.SafeCall("chat tab key", SyncKeys)
	end)
	p:HookScript("OnShow", function() ns.SafeCall("chat tab key", SyncKeys) end)
	-- The window resized (docked to a guild window that grew): the lines wrap again.
	p:HookScript("OnSizeChanged", MarkDirty)
	if h.HookScript then h:HookScript("OnSizeChanged", MarkDirty) end
	p:SetScript("OnUpdate", OnUpdate)
	return p
end

-- Where the tab's parts go in its window, from UI.lua (offsets from the window's corners, for
-- its look): places = { search = { left, right, top }, box = { left, right, top, bottom },
-- input = { left, right, y, h } }. The search row holds the switch and the gear too (DrawTop:
-- the search box ends where they begin); the box's top moves down under the pinned line, the
-- Sylvanistas tab's line and the count of the hidden lines while they show (Render).
local function Place(p, places)
	if p.places == places then return end
	p.places = places
	local s, box, input = places.search, places.box, places.input
	p.searchLabel:ClearAllPoints()
	p.searchLabel:SetPoint("TOPLEFT", p, "TOPLEFT", s.left, s.top - 4)
	p.setTitle:ClearAllPoints()
	p.setTitle:SetPoint("TOPLEFT", p, "TOPLEFT", s.left, s.top - 3)
	p.box:ClearAllPoints()
	p.box:SetPoint("TOPLEFT", p, "TOPLEFT", box.left, box.top)
	p.box:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", box.right, box.bottom)
	local eb = p.input
	eb:ClearAllPoints()
	eb:SetHeight(input.h)
	eb:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", input.left + 10, input.y)
	PlaceInput(p)
end

---------------------------------------------------------------------------
-- The tab in its window (UI.lua), and the ways to it
---------------------------------------------------------------------------

-- The channel it opens on: the one it showed, else the one last shown, else the first readable.
local function Pick()
	local C = ns.Channels
	if tier and C.TIERS[tier] and C.CanUse(tier) then return tier end
	local p = Saved()
	local last = p and p.tier
	if C.TIERS[last] and C.CanUse(last) then return last end
	return Readable()[1]
end

-- UI.lua, when window `h` shows its Chat tab (and on its redraws after): the tab in it, placed as
-- `places` says. Opening (it was not showing): the newest lines (not the settings), unread counts
-- from zero. Never takes the keyboard.
function ChatWindow.Attach(h, places)
	if not h or type(places) ~= "table" then return nil end
	local p = Build(h)
	frame, host = p, h
	Place(p, places)
	if not p:IsShown() then
		tier = Pick()
		if tier then Remember(tier) end
		unread = {}
		settings = false
		stick, newCount, want, acc = true, 0, nil, 0
		p:Show()
		Render()
		ScrollToBottom()
	end
	return p
end

-- Another tab, or the window closed: the tab goes (its boxes let go of the keyboard).
function ChatWindow.Detach(h)
	local p = h and panes[h]
	if p and p:IsShown() then p:Hide() end
end

-- The Sylvanistas window on its Chat tab, on `want` (a channel: "A", "C", "L"), else the one last
-- shown if still readable, else the first this rank reads. Never takes the keyboard.
function ChatWindow.Open(want)
	local C = ns.Channels
	if C.missing then
		ns.Print(L.RESTART_NEEDED)
		return nil
	end
	if C.MyLevel() == 0 then
		ns.Print(L.MEMBERS_ONLY)
		return nil
	end
	local d = want ~= nil and C.TIERS[want] or nil
	if d and not C.CanUse(want) then
		ns.Print(L[d.deny]:format(L[d.label]))
		return nil
	end
	if Shown() then
		if d and want ~= tier then Select(want) end
		return frame
	end
	if d then
		tier = want
		Remember(want)
	end
	local UI = ns.UI
	if not UI or type(UI.SelectTab) ~= "function" then return nil end
	UI.SelectTab(TAB)
	if not Shown() then return nil end
	ScrollToBottom()
	return frame
end

-- The Sylvanistas window closed, when it shows the Chat tab.
function ChatWindow.Close()
	if Shown() then host:Hide() end
end

-- Shown on that channel (or none named): the window closes. Shown on another: that one. Else:
-- the window on the Chat tab.
function ChatWindow.Toggle(want)
	if Shown() then
		if want == nil or want == tier then
			host:Hide()
			return nil
		end
		Select(want)
		return frame
	end
	return ChatWindow.Open(want)
end

function ChatWindow.Tier() return tier end
function ChatWindow.Frame() return frame end -- (the tab, in its window)
function ChatWindow.Window() return host end -- (the Sylvanistas window it is in)

-- (Tests: a fresh session.)
function ChatWindow.Reset()
	for _, p in pairs(panes) do p:Hide() end
	panes = {}
	frame, host, tier, tipOwner = nil, nil, nil, nil
	dirty, dataPending, lastData = false, false, -math.huge
	unread, notes = {}, {}
	revealed = setmetatable({}, { __mode = "k" })
	stick, newCount, lastAt, quiet, acc, want = true, 0, 0, false, 0, nil
	settings = false
	StopWatching()
	pointer = nil
	keyButton, boundKeys, keysLater, toldLater, syncing = nil, nil, false, false, false
end

---------------------------------------------------------------------------
-- What changes it
---------------------------------------------------------------------------

ns.On("CHAT_CHANGED", function(t)
	if t == nil or t == tier then MarkDirty() end
end)
ns.On("CHAT_LINE", function(t)
	if not Shown() or not ns.Channels.TIERS[t] then return end
	if t ~= tier then
		unread[t] = (unread[t] or 0) + 1
	elseif not stick then
		newCount = newCount + 1
	end
	MarkDirty()
end)
-- (CHAT_SETTINGS_CHANGED, Channels.lua: a channel muted or shown in the game's chat, or sent to
-- another chat window, by /syl mute, /syl chatwindow, a line typed with /sy or the settings' own
-- clicks. The review of the page's removal: the settings stayed as they were drawn, and a stale
-- "shows in your chat" unmuted a channel /syl mute had muted.)
for _, event in ipairs({ "PIN_CHANGED", "FILTER_CHANGED", "NETOFF_CHANGED", "COUNCIL_MASK_CHANGED", "CONSENT_CHANGED",
	"CHAT_SETTINGS_CHANGED" }) do
	ns.On(event, MarkDirty)
end
-- The marks follow the census, at most once every DATA_GAP seconds.
ns.On("DATA_CHANGED", function()
	if Shown() then dataPending = true end
end)
-- A line of ours that did not leave (Channels.lua: the channel changed before it went, it waited
-- too long, the game refused it, we left Sylvanistas): a note in its channel, to put it back.
ns.On("CHAT_SEND_FAILED", function(t, why, text)
	if not ns.Channels.TIERS[t] or type(text) ~= "string" or text == "" then return end
	local list = notes[t] or {}
	notes[t] = list
	list[#list + 1] = { why = WHY[why] and why or "failed", text = text }
	while #list > MAX_NOTES do table.remove(list, 1) end
	MarkDirty()
end)

-- The "Open chat" key: a change the fight held made now (the tab open then: set; gone: taken
-- off); the player's own keys changed (the game's Key Bindings) while it is bound or the tab shows.
-- (With the gamepad UI, the end of a fight that held the switch's change is when it is due.)
ns.RegisterEvent("PLAYER_REGEN_ENABLED", function()
	toldLater = false
	if keysLater then SyncKeys(true) end
end)
ns.RegisterEvent("UPDATE_BINDINGS", function()
	if boundKeys or Shown() then SyncKeys() end
end)
-- The switch between mouse and keyboard and the gamepad UI (Blizzard_SharedXML/InputUtil.lua's
-- event, as Borders.lua reads it; not on every client): to the gamepad UI the key goes back to the
-- game at the switch, the one binding change made there; back, bound at once while the tab shows.
pcall(ns.RegisterEvent, "INPUT_DEVICE_INTERFACE_TRANSITION", function(newMode)
	SyncKeys(true, GamepadStyle(newMode))
end)

-- The channel last shown, kept only as a channel's letter, and the Sylvanistas tab's line put away,
-- only as true (the first 1.1.1 build's window place and size go).
ns.On("INIT", function()
	local p = ns.db.chatWin
	if p == nil then return end
	local kept = {}
	if type(p) == "table" then
		local t = p.tier
		if type(t) == "string" and ns.Channels.TIERS[t] then kept.tier = t end
		if p.noTabLine == true then kept.noTabLine = true end
	end
	ns.db.chatWin = next(kept) ~= nil and kept or nil
end)
