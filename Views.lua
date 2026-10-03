local ADDON, ns = ...
local L = ns.L

-- Content of the four tabs. Each tab gives: column headers (optional), a list of lines,
-- a detail box (title + text, like the guild "Message of the Day" box) and three buttons.
-- The renderer draws lines with Blizzard fonts; a line is either
--   { text, right, indent, header, color, onClick, tooltip = function(tt) end }
-- or a table row { cols = { ... } } drawn with the tab's column layout. `key` (a player's
-- name) marks a line that opens a person: the HD window keeps it lit while it is open.
-- `input = { text, onChange = function(text) end }`: a text box after the line's text (the
-- Workshop's search, 0.9.9; the tabs' searches on top of their lists, 1.0.0), one per list,
-- with an "x" that empties it.

local Views = {}
ns.Views = Views

local ROW_H = 16
local ROW_H_HD = 20 -- the Guild & Communities roster's rows (CommunitiesMemberList.xml)
local ROW_H_INPUT = 24 -- a row with a text box (line.input): the box and its border
local ITEM, ITEM_GAP = 30, 2 -- an item on an items row (line.items) without the game's button template (37 with it)
local expanded = {}
local CROWN = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:13:13|t "
local ASSIST = "|TInterface\\GroupFrame\\UI-Group-AssistantIcon:12:12|t "

local function Green(s) return "|cff40ff40" .. s .. "|r" end
-- 1.1.2: a count's tooltip ends with why it can differ between players (Answers.lua, the bank's).
local function Why(tt, ...)
	local A = ns.Answers
	if A and type(A.WhyTip) == "function" then A.WhyTip(tt, ...) end
end
local function Grey(s) return "|cff9d9d9d" .. s .. "|r" end
local function Red(s) return "|cffff4040" .. s .. "|r" end
local function Gold(s) return "|cffffd200" .. s .. "|r" end
Views.Green, Views.Grey, Views.Red, Views.Gold = Green, Grey, Red, Gold
-- Sylvanistas: a grey info line in rows short enough for the page (rows are one line each and
-- don't wrap): split at spaces, about WRAP letters a row. `opts` goes on every row (indent,
-- onClick, tooltip), but gapAfter only on the last.
Views.WRAP = 56
function Views.GreyRows(lines, text, opts)
	opts = opts or {}
	local rows, row = {}, ""
	for word in tostring(text or ""):gmatch("%S+") do
		if row ~= "" and #row + 1 + #word > Views.WRAP then rows[#rows + 1] = row; row = word
		else row = row == "" and word or (row .. " " .. word) end
	end
	if row ~= "" then rows[#rows + 1] = row end
	for i, r in ipairs(rows) do
		local l = { text = Grey(r) }
		for k, v in pairs(opts) do if k ~= "gapAfter" or i == #rows then l[k] = v end end
		lines[#lines + 1] = l
	end
	return lines
end

-- Names and guilds from other players' reports: shown as plain text, whatever they carry
-- (0.9.2; Comm.lua already strips every escape code from what arrives).
local Plain = ns.Codec.Plain

local function ClassColored(name, classFile)
	name = Plain(name)
	local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	return c and ("|c%s%s|r"):format(c.colorStr, name) or name
end
Views.ClassColored = ClassColored

-- `dim`: what an old report said (older than Data.FRESH), all grey, as its guild is in the tree.
local function Presence(online, days, dim)
	if online then return (dim and Grey or Green)(L.ONLINE_NOW) end
	if not days or days < 1 then return Grey(L.OFFLINE_TODAY) end
	local d = math.floor(days)
	local text = L.OFFLINE_DAYS:format(d)
	if d >= (ns.db.warnDays or 3) then return (dim and Grey or Red)(text .. " !") end
	return Grey(text)
end

---------------------------------------------------------------------------
-- Column layouts, as fractions of the list width (so they follow the window size)
---------------------------------------------------------------------------

Views.COLUMNS = {
	census = {
		{ key = "COL_GUILD", sort = "name", x = 0.00, w = 0.40 },
		{ key = "COL_MEMBERS", sort = "members", x = 0.40, w = 0.20, justify = "RIGHT" },
		{ key = "COL_ONLINE", sort = "online", x = 0.60, w = 0.16, justify = "RIGHT" },
		{ key = "COL_LORD", sort = "lord", x = 0.76, w = 0.24 },
	},
	heraldry = {
		{ key = "COL_NAME", x = 0.00, w = 0.30 },
		{ key = "COL_GUILD", x = 0.30, w = 0.32 },
		{ key = "COL_TABARD", x = 0.63, w = 0.24 },
		{ key = "COL_WHEN", x = 0.87, w = 0.13, justify = "RIGHT" },
	},
}

---------------------------------------------------------------------------
-- Renderer
---------------------------------------------------------------------------

-- Rows follow the look of the window they are in (content.style, see UI.lua): the old one's,
-- or the HD one's like the Guild & Communities roster (20 tall, its row background on the
-- rows that can be clicked, its gold bar under the mouse and under the person open).
local function Row(content, i)
	content.rows = content.rows or {}
	local r = content.rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, content)
	if content.style == "hd" then
		r:SetHeight(ROW_H_HD)
		r.stripe = r:CreateTexture(nil, "BACKGROUND")
		r.stripe:SetAllPoints()
		r.stripe:SetTexture("Interface\\GuildFrame\\GuildFrame")
		r.stripe:SetTexCoord(0.36230469, 0.38183594, 0.95898438, 0.99804688)
		r:SetHighlightTexture("Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar", "ADD")
	else
		r:SetHeight(ROW_H)
		local hl = r:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		hl:SetBlendMode("ADD")
		hl:SetAlpha(0.35)
	end
	r.left = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.left:SetJustifyH("LEFT")
	r.left:SetWordWrap(false)
	r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.right:SetPoint("RIGHT", -2, 0)
	r.right:SetJustifyH("RIGHT")
	r.right:SetWordWrap(false)
	r.cols = {}
	for c = 1, 4 do
		local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetWordWrap(false)
		r.cols[c] = fs
	end
	r.index = i
	r:SetScript("OnClick", function(self)
		if not self.line then return end
		-- HD: the person opened stays lit, like the roster's selected member.
		if content.style == "hd" and self.line.key then ns.SafeCall("view select", Views.Select, content, self.line.key) end
		-- Where the row was clicked, for the redraw its click causes (UI.lua keeps it in place):
		-- its place in the list, the list's offset then (the list is the scroll frame's child).
		-- A row with nothing to do on a click (a tooltip, a heading) causes no redraw.
		if self.line.onClick then
			local scroll = content:GetParent()
			local offset = scroll and scroll.GetVerticalScroll and scroll:GetVerticalScroll()
			content.click = { index = self.index, top = self.top or 0, lines = content.lineCount or 0, t = GetTime(),
				offset = type(offset) == "number" and offset or nil }
			ns.SafeCall("view click", self.line.onClick)
		end
		if ns.UI.Clicked then ns.UI.Clicked() end
	end)
	r:SetScript("OnEnter", function(self)
		if not (self.line and self.line.tooltip) then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		ns.SafeCall("view tooltip", self.line.tooltip, GameTooltip)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	content.rows[i] = r
	return r
end

-- An item's icon: the snapshot's, or the client's for the id.
local function ItemIcon(it)
	if it.icon then return it.icon end
	if GetItemInfoInstant then
		local ok, _, _, _, _, icon = pcall(GetItemInfoInstant, it.id)
		if ok and icon then return icon end
	end
	if C_Item and C_Item.GetItemIconByID then
		local ok, icon = pcall(C_Item.GetItemIconByID, it.id)
		if ok and icon then return icon end
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- One slot of an items row: the game's own item button (ItemButtonTemplate: the slot, the
-- icon, the count, the quality border) where the client has it, the same made here where
-- not; the item's own tooltip on hover, like a bag's.
local function ItemButton(r, k)
	local ok, b = pcall(CreateFrame, "Button", nil, r, "ItemButtonTemplate")
	if ok and b and b.icon and SetItemButtonTexture then
		b.blizzard = true
		r.itemSize = 37
	else
		if ok and b then b:Hide() end
		b = CreateFrame("Button", nil, r)
		b:SetSize(ITEM, ITEM)
		b.slot = b:CreateTexture(nil, "BACKGROUND")
		b.slot:SetTexture("Interface\\Buttons\\UI-EmptySlot")
		b.slot:SetTexCoord(0.2, 0.8, 0.2, 0.8)
		b.slot:SetAllPoints()
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetAllPoints()
		b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
		b.count:SetPoint("BOTTOMRIGHT", -2, 2)
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		r.itemSize = r.itemSize or ITEM
	end
	b:RegisterForClicks("LeftButtonUp")
	b:SetScript("OnClick", function(self)
		-- 1.1: a grid whose line takes a click on an item (the Treasury's bank: a Lord or a
		-- Captain asks the treasury for it, Bank.lua), a plain click.
		local it = self.item
		local row = self.GetParent and self:GetParent()
		local line = row and row.line
		if it and not it.gone and line and line.onItem and not (IsShiftKeyDown and IsShiftKeyDown()) then
			return ns.SafeCall("view item", line.onItem, it)
		end
		-- Shift-click: the link into the chat box, as in a bag (not with the gamepad UI: its
		-- chat box would be blocked, see Dialog.lua).
		if not it or not IsShiftKeyDown or not IsShiftKeyDown() or ns.GamepadUI() or not ChatEdit_InsertLink then return end
		local link = it.link
		if not link and GetItemInfo then local okInfo, _, l = pcall(GetItemInfo, it.id); if okInfo then link = l end end
		if link then pcall(ChatEdit_InsertLink, link) end
	end)
	b:SetScript("OnEnter", function(self)
		local it = self.item
		if not it then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local ok = false
		if it.link and GameTooltip.SetHyperlink then ok = pcall(GameTooltip.SetHyperlink, GameTooltip, it.link) end
		if not ok and it.id and GameTooltip.SetItemByID then ok = pcall(GameTooltip.SetItemByID, GameTooltip, it.id) end
		if not ok then GameTooltip:AddLine("#" .. tostring(it.id), 1, 1, 1) end
		if (it.n or 0) > 1 then GameTooltip:AddLine("x" .. it.n, 0.8, 0.8, 0.8) end
		if it.gone then GameTooltip:AddLine(L.BANK_GONE_SLOT, 1, 0.4, 0.4, true) end
		local row = self.GetParent and self:GetParent()
		local hint = not it.gone and row and row.line and row.line.itemHint
		if hint then GameTooltip:AddLine(hint, 0.6, 1, 0.6, true) end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r.items = r.items or {}
	r.items[k] = b
	return b
end

-- A slot's item (nil: empty), drawn the way the game draws it.
local function SetSlot(b, it)
	b.item = it
	if b.blizzard then
		SetItemButtonTexture(b, it and ItemIcon(it) or nil)
		if SetItemButtonCount then SetItemButtonCount(b, it and it.n or 0) end
		if SetItemButtonQuality then
			local quality
			if it and GetItemInfo then
				local ok, _, _, q = pcall(GetItemInfo, it.link or it.id)
				if ok then quality = q end
			end
			pcall(SetItemButtonQuality, b, quality, it and (it.link or it.id) or nil)
		end
	else
		b.icon:SetTexture(it and ItemIcon(it) or nil)
		b.icon:SetShown(it ~= nil)
		b.count:SetText(it and (it.n or 0) > 1 and tostring(it.n) or "")
	end
	-- 1.1: a stack gone since the snapshot before (the Treasury's bank, Bank.Gone): faded and red,
	-- in the slot it sat in.
	local gone = it ~= nil and it.gone == true
	if b.icon.SetDesaturated then b.icon:SetDesaturated(gone) end
	if b.icon.SetVertexColor then
		if gone then b.icon:SetVertexColor(1, 0.35, 0.35) else b.icon:SetVertexColor(1, 1, 1) end
	end
	if b.SetAlpha then b:SetAlpha(gone and 0.6 or 1) end
end

function Views.LayoutColumns(fontStrings, layout, width, offset)
	for c, fs in ipairs(fontStrings) do
		local col = layout and layout[c]
		if col then
			fs:ClearAllPoints()
			fs:SetPoint("LEFT", (offset or 0) + col.x * width, 0)
			fs:SetWidth(col.w * width - 4)
			fs:SetJustifyH(col.justify or "LEFT")
			fs:Show()
		else
			fs:Hide()
		end
	end
end

-- The row whose line has `key` stays lit (nil: none). HD rows only.
function Views.Select(content, key)
	content.selectedKey = key
	for _, r in ipairs(content.rows or {}) do
		if key and r.line and r.line.key == key then r:LockHighlight() else r:UnlockHighlight() end
	end
end

function Views.ClearSelection(content) Views.Select(content, nil) end

-- The "x" at the end of a box that holds text (1.0.0): a click empties it and lets go of the
-- keyboard. A button of its own, never a focus change.
local function ClearButton(eb)
	local x = CreateFrame("Button", nil, eb)
	x:SetSize(16, 16)
	x:SetPoint("RIGHT", eb, "RIGHT", -2, 0)
	x.label = x:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	x.label:SetPoint("CENTER", x, "CENTER", 0, 1)
	x.label:SetText("x")
	x:SetScript("OnClick", function()
		local input = eb.line and eb.line.input
		eb:SetText("")
		eb:ClearFocus()
		x:Hide()
		if input and input.onChange then ns.SafeCall("view input", input.onChange, "") end
	end)
	x:SetScript("OnEnter", function(self)
		self.label:SetTextColor(1, 1, 1)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L.SEARCH_CLEAR, 1, 0.82, 0)
		GameTooltip:Show()
	end)
	x:SetScript("OnLeave", function(self)
		self.label:SetTextColor(1, 0.82, 0)
		GameTooltip:Hide()
	end)
	x:Hide()
	return x
end

-- The list's text box (line.input): one per list, made the first time a line asks for one and
-- moved onto that line's row at each redraw, so typing goes on while the list changes under it.
-- Like the council icon picker's filter, it never takes the keyboard by itself (the gamepad UI's
-- rule, ns.Focus): the player clicks into it; Enter, Escape or its list hiding let go of it.
local function InputBox(content)
	if content.input then return content.input end
	local ok, eb = pcall(CreateFrame, "EditBox", nil, content, "InputBoxTemplate")
	if not ok or not eb then eb = CreateFrame("EditBox", nil, content) end
	eb:SetAutoFocus(false)
	eb:Hide()
	eb:SetHeight(20)
	eb:SetMaxLetters(40)
	eb:SetFontObject("ChatFontNormal")
	eb:SetTextInsets(0, 18, 0, 0) -- (the typing stops short of the "x")
	eb.sylvanistasBox = true
	eb.clear = ClearButton(eb)
	eb:SetScript("OnTextChanged", function(self)
		local text = self:GetText() or ""
		self.clear:SetShown(text ~= "")
		local input = self.line and self.line.input
		if input and input.onChange then ns.SafeCall("view input", input.onChange, text) end
	end)
	eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	eb:SetScript("OnHide", function(self) self:ClearFocus() end)
	eb:SetScript("OnEnter", function(self)
		if not (self.line and self.line.tooltip) then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		ns.SafeCall("view tooltip", self.line.tooltip, GameTooltip)
		GameTooltip:Show()
	end)
	eb:SetScript("OnLeave", function() GameTooltip:Hide() end)
	content.input = eb
	return eb
end

-- The box on `r`, the row of its line: after the line's text, to the row's end. Its text is set
-- only when it is not the line's already (what was typed stays, the cursor where it is).
local function PlaceInput(content, r)
	local eb = content.input
	if not r then
		if eb then
			eb.line = nil
			eb:Hide()
		end
		return
	end
	eb = InputBox(content)
	eb.line = r.line
	eb:ClearAllPoints()
	eb:SetPoint("LEFT", r.left, "RIGHT", 12, 0)
	eb:SetPoint("RIGHT", r, "RIGHT", -8, 0)
	eb:SetFrameLevel(r:GetFrameLevel() + 2)
	local text = tostring(r.line.input.text or "")
	if (eb:GetText() or "") ~= text then eb:SetText(text) end
	eb.clear:SetShown(text ~= "")
	eb:Show()
end

function Views.Render(content, lines, layout)
	local width = content:GetWidth()
	local hd = content.style == "hd"
	local rowH = hd and ROW_H_HD or ROW_H
	local y = -2
	local inputRow
	for i, line in ipairs(lines) do
		local r = Row(content, i)
		r.line = line
		r.top = -y -- how far down the list the row starts (UI.lua keeps the list's place)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
		r:SetWidth(width)
		local height = rowH
		if line.items then
			-- Items in a grid. line.slots and line.columns: a bank tab as the game draws it (every
			-- slot, empty ones too, items where they sit: it.s); without them, the items one after
			-- another, as many per row as fit. The row grows to hold them all.
			r.left:Hide()
			r.right:Hide()
			for c = 1, 4 do r.cols[c]:Hide() end
			if not (r.items and r.items[1]) then ItemButton(r, 1) end
			local size = (r.itemSize or ITEM) + ITEM_GAP
			local columns = line.columns or math.max(1, math.floor((width - 8) / size))
			local slots = line.slots or #line.items
			local bySlot = {}
			for k, it in ipairs(line.items) do
				local s = line.slots and tonumber(it.s) or k
				if s and s >= 1 and s <= slots then bySlot[s] = it end
			end
			for k = 1, slots do
				local b = r.items[k] or ItemButton(r, k)
				SetSlot(b, bySlot[k])
				b:ClearAllPoints()
				b:SetPoint("TOPLEFT", 4 + ((k - 1) % columns) * size, -2 - math.floor((k - 1) / columns) * size)
				b:Show()
			end
			for k = slots + 1, #r.items do r.items[k]:Hide() end
			height = math.ceil(math.max(1, slots) / columns) * size + 4
		elseif line.cols then
			r.left:Hide()
			r.right:Hide()
			Views.LayoutColumns(r.cols, layout, width - 4, 4)
			for c = 1, 4 do r.cols[c]:SetText(line.cols[c] or "") end
			local a = line.dim and 0.45 or 1
			for c = 1, 4 do r.cols[c]:SetAlpha(a) end
		else
			for c = 1, 4 do r.cols[c]:Hide() end
			r.left:Show()
			r.right:Show()
			-- line.font: a font object by name (the Throne's dark ink on parchment), if the client has it.
			local font = line.font and _G[line.font] and line.font or nil
			r.left:SetFontObject(font or (line.header and "GameFontNormal" or (line.color or "GameFontHighlightSmall")))
			r.right:SetFontObject(font or "GameFontHighlightSmall")
			r.left:ClearAllPoints()
			r.left:SetPoint("LEFT", 4 + (line.indent or 0) * 12, 0)
			-- A text box's line: its text as wide as it is, the box after it (PlaceInput).
			if line.input and not inputRow then
				inputRow, height = r, ROW_H_INPUT
			else
				r.left:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
			end
			r.left:SetText(line.text or "")
			r.right:SetText(line.right or "")
		end
		if not line.items then for k = 1, #(r.items or {}) do r.items[k]:Hide() end end
		r:SetHeight(height)
		r:EnableMouse(line.onClick ~= nil or line.tooltip ~= nil)
		if hd then
			r.stripe:SetShown(line.cols ~= nil or line.onClick ~= nil)
			if line.key and line.key == content.selectedKey then r:LockHighlight() else r:UnlockHighlight() end
		end
		r:Show()
		y = y - (line.header and height + 4 or height)
		if line.gapAfter then y = y - 6 end
	end
	for i = #lines + 1, #(content.rows or {}) do content.rows[i]:Hide() end
	PlaceInput(content, inputRow)
	content.lineCount = #lines
	content:SetHeight(-y + 8)
end

-- The last row clicked in `content` ({ index, top, lines, t }: where it started, how many lines
-- the list had, when), once: taken by the redraw that follows (UI.lua).
function Views.TakeClick(content)
	local click = content.click
	content.click = nil
	return click
end

-- The id of a guild's row in the Realm tree (line.id): a tab opened on it shows it (UI.SelectTab).
function Views.GuildId(name) return "guild:" .. tostring(name) end

---------------------------------------------------------------------------
-- The tabs' searches (1.0.0): the Workshop's box (line.input) on top of the Census, the Realm,
-- the Tabards and the Treasury. What is typed stays with its tab for the session, never saved,
-- and changes only what the list shows: the copy for Discord, what is sent and what is kept are
-- the same whatever it holds. Nothing typed (or spaces only): the list as ever.
---------------------------------------------------------------------------

local filters = {} -- [tab] = the text in its box, as typed
local folded = {}  -- [guild name or COUNCIL_ROW] = true: opened by the search, closed by a click (until the text changes)
-- The Realm's search opens the guilds where it finds a Lord, a Captain or a member a page of
-- rows at a time (a first letter is in someone of nearly every guild: all of them opened would
-- be thousands of rows, as Expand all), the rest on a click; a new text, its first page.
Views.SEARCH_ROWS = 200
local searchRows = Views.SEARCH_ROWS

local function Trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- A name as the search reads it (ns.Searchable) as its row shows it (Plain), and a /who name as
-- its row shows it (Views.MembersOf), kept: the Realm's search reads every Lord, Captain and
-- player seen at each letter typed and at each redraw, and a name reads the same each time.
-- Emptied past SEARCH_NAMES_KEPT, a long session's worth.
Views.SEARCH_NAMES_KEPT = 20000
local searchNames, seenNames, namesKept = {}, {}, 0
local function Kept()
	namesKept = namesKept + 1
	if namesKept > Views.SEARCH_NAMES_KEPT then
		wipe(searchNames)
		wipe(seenNames)
		namesKept = 1
	end
end
local function SearchName(s)
	local k = searchNames[s]
	if not k then
		Kept()
		k = ns.Searchable(Plain(s))
		searchNames[s] = k
	end
	return k
end
local function SeenName(name)
	local shown = seenNames[name]
	if not shown then
		Kept()
		shown = ns.DisplayName(ns.FullName(name)) or ""
		seenNames[name] = shown
	end
	return shown
end
-- Does `name` hold the search `q`, as its row shows it?
local function NameHolds(q, name)
	return type(name) == "string" and name ~= "" and SearchName(name):find(q, 1, true) ~= nil
end

function Views.Filter(tab) return filters[tab] or "" end

-- The text a tab's list is filtered by, folded (ns.Fold), or nil when nothing is typed.
function Views.Query(tab)
	local text = Trim(filters[tab])
	if text == "" then return nil end
	return ns.Fold(text)
end

-- Typed into a tab's box: its list again, from its first page, and from its top when a search
-- starts (while the player goes on typing, the list stays where it is: UI.FilterChanged).
function Views.SetFilter(tab, text)
	text = tostring(text or "")
	local before = filters[tab] or ""
	if text == before then return end
	filters[tab] = text ~= "" and text or nil
	if tab == "realm" then
		wipe(folded)
		searchRows = Views.SEARCH_ROWS
	end
	if tab == "treasury" and ns.Treasury and ns.Treasury.FirstPage then ns.Treasury.FirstPage() end
	if ns.UI and ns.UI.FilterChanged then ns.UI.FilterChanged(tab, Trim(before) == "" and Trim(text) ~= "") end
end

-- Tests start from nothing typed.
function Views.ClearFilters()
	wipe(filters)
	wipe(folded)
	searchRows = Views.SEARCH_ROWS
	wipe(searchNames)
	wipe(seenNames)
	namesKept = 0
end

-- The box's line, on top of a tab's list; `tip`: what it finds there (L.SEARCH_TIP_...).
local function SearchLine(tab, tip)
	return {
		text = L.SEARCH, input = { text = Views.Filter(tab), onChange = function(text) Views.SetFilter(tab, text) end },
		tooltip = function(tt)
			tt:AddLine(L.SEARCH, 1, 0.82, 0)
			tt:AddLine(L["SEARCH_TIP_" .. tip], 1, 1, 1, true)
		end,
	}
end

local function NoMatch() return { text = Grey(L.SEARCH_NO_MATCH) } end

---------------------------------------------------------------------------
-- The census's marks (1.1, request #30): a row its senders disagree on (Data.Dispute: its leader
-- or officers, or its size), and, fainter, one a single sender stands behind. A game texture in
-- the row's text, so both windows and the gamepad UI show it; the tooltip says what it is.
---------------------------------------------------------------------------

Views.MARK_DISPUTED = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"
Views.MARK_SINGLE = "Interface\\Icons\\INV_Misc_QuestionMark"

-- The mark before a guild's name ("" for none), and what Data.Dispute found.
function Views.DisputeMark(g)
	local d = ns.Data.Dispute(g)
	if not d then return "", nil end
	return "|T" .. (d.disputed and Views.MARK_DISPUTED or Views.MARK_SINGLE) .. ":12:12|t ", d
end

-- What the mark says, a line each (nil: no mark), for tooltips and the gates' question.
function Views.DisputeLines(d)
	if not d then return nil end
	local out = {}
	if d.split then out[#out + 1] = L.DISPUTE_SPLIT end
	if d.outvoted then out[#out + 1] = L.DISPUTE_OUTVOTED end
	if d.sizes then
		out[#out + 1] = L.DISPUTE_SIZES:format(ns.FormatNumber(d.sizes[2].n), ns.DisplayName(d.sizes[2].sender) or "?",
			ns.FormatNumber(d.sizes[1].n), ns.DisplayName(d.sizes[1].sender) or "?")
	end
	if d.single then out[#out + 1] = L.DISPUTE_SINGLE:format(ns.DisplayName(d.single) or "?") end
	return out
end

local function DisputeTooltip(tt, d)
	local lines = Views.DisputeLines(d)
	if not lines then return end
	tt:AddLine(" ")
	tt:AddLine(d.disputed and L.DISPUTE_TITLE or L.DISPUTE_SINGLE_TITLE, 1, d.disputed and 0.4 or 0.82, d.disputed and 0.2 or 0)
	for _, text in ipairs(lines) do tt:AddLine(text, 1, 1, 1, true) end
	tt:AddLine(L.DISPUTE_TIP, 0.6, 0.6, 0.6, true)
end

---------------------------------------------------------------------------
-- Shared tooltips
---------------------------------------------------------------------------

-- What a guild's guild master is called: the Dark Lady in her own guild, a Dark Lord elsewhere.
local function LeaderTitle(guild) return ns.IsKingGuild(guild) and L.KING or L.LORD end

local function GuildTooltip(e)
	return function(tt)
		local g = e.g
		tt:AddLine("<" .. Plain(e.name) .. ">", 0.25, 1, 0.25)
		tt:AddDoubleLine(L.COL_MEMBERS, ns.FormatNumber(g.total), 1, 0.82, 0, 1, 1, 1)
		tt:AddDoubleLine(L.COL_ONLINE, ns.FormatNumber(g.online), 1, 0.82, 0, 1, 1, 1)
		tt:AddDoubleLine(LeaderTitle(e.name), Plain(g.leader or "?"), 1, 0.82, 0, 1, 1, 1)
		tt:AddDoubleLine(L.VACANCIES, ns.FormatNumber(math.max(0, 1000 - (g.total or 0))), 1, 0.82, 0, 1, 1, 1)
		if g.avgLevel and g.avgLevel > 0 then tt:AddDoubleLine(L.AVG_LEVEL, ("%.1f"):format(g.avgLevel), 1, 0.82, 0, 1, 1, 1) end
		tt:AddDoubleLine(L.INACTIVE_30, ns.FormatNumber(g.inactive30 or 0), 1, 0.82, 0, 1, 1, 1)
		local classes = {}
		for code, n in pairs(g.classes or {}) do classes[#classes + 1] = { code, n } end
		table.sort(classes, function(a, b) return a[2] > b[2] end)
		if #classes > 0 then
			local parts = {}
			for _, c in ipairs(classes) do
				local file = ns.CLASS_FILES[c[1]]
				local label = (file and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[file]) or c[1]
				parts[#parts + 1] = ClassColored(label .. " " .. c[2], file)
			end
			tt:AddLine(" ")
			for i = 1, #parts, 3 do tt:AddLine(table.concat({ parts[i], parts[i + 1], parts[i + 2] }, "   ")) end
		end
		local zones = {}
		for key, n in pairs(g.zones or {}) do zones[#zones + 1] = { key, n } end
		table.sort(zones, function(a, b) return a[2] > b[2] end)
		if #zones > 0 then
			tt:AddLine(" ")
			for i = 1, math.min(5, #zones) do
				tt:AddDoubleLine(ns.Zones.NameForKey(zones[i][1]), ns.FormatNumber(zones[i][2]), 0.8, 0.8, 0.8, 1, 1, 1)
			end
		end
		tt:AddLine(" ")
		tt:AddLine(L.REPORTED_BY:format(g.reporter or "?", ns.Ago(g.t)), 0.6, 0.6, 0.6)
		if not e.fresh then tt:AddLine(L.STALE, 1, 0.4, 0.4) end
		DisputeTooltip(tt, ns.Data.Dispute(g))
		-- (Ours is live from our roster; another guild's is its last report, 1.1.2's review.)
		Why(tt, not e.fresh and "count-grey-rows" or (g.mine and "count-own-guild-live" or "count-other-guild-report"))
	end
end

-- A guild only /who has seen: all we know is how many of it were online.
local function SeenTooltip(e)
	return function(tt)
		tt:AddLine("<" .. e.name .. ">", 0.6, 0.6, 0.6)
		tt:AddDoubleLine(L.SEEN_ONLINE, ns.FormatNumber(e.online) .. (e.capped and "+" or ""), 1, 0.82, 0, 1, 1, 1)
		tt:AddDoubleLine(L.SEEN_WHEN, ns.Ago(e.t), 1, 0.82, 0, 1, 1, 1)
		tt:AddLine(" ")
		tt:AddLine(L.SEEN_TIP, 0.8, 0.8, 0.8, true)
		if e.capped then tt:AddLine(L.SEEN_CAPPED_TIP, 0.8, 0.8, 0.8, true) end
		Why(tt, "count-army-lower")
	end
end

-- The census being rebuilt after login (1.1, Data.Rebuilding): two lines on top of the Census
-- and the Realm, in place of "No reports yet", until it is. Nothing else (no /who, no popup).
local function RebuildLines(lines)
	local heard = ns.Data.Rebuilding and ns.Data.Rebuilding()
	if not heard then return false end
	local function tip(tt)
		tt:AddLine(L.REBUILDING_SUB:format(heard), 1, 0.82, 0)
		tt:AddLine(L.REBUILDING_TIP, 1, 1, 1, true)
	end
	lines[#lines + 1] = { text = Gold(L.REBUILDING:format(heard)), tooltip = tip }
	lines[#lines + 1] = { text = Grey(L.REBUILDING_WAIT), tooltip = tip, gapAfter = true }
	return true
end
Views.RebuildLines = RebuildLines

-- The Sylvanistas channel without a realm key (1.1, Comm.IsPublic): anyone who joins it by name reads
-- what is sent there. While it is so, one quiet grey line on top of the Census, the Realm and the
-- Sylvanistas chats for the officers, who can seal it (its tooltip says what it means and how); the
-- others see only whether guildmates are already on the sealed channel (their hellos say so), and
-- /syl status. Nothing is sent, nothing changes.
local function PublicLines(lines)
	local C = ns.Comm
	if not (C and C.IsPublic and C.IsPublic()) then return false end
	local name = C.ChannelSpec and C.ChannelSpec() or ns.CHANNEL
	local officer = ns.Roster.IsOfficer()
	local function tip(tt)
		tt:AddLine(L.PUBLIC_NET_TITLE, 1, 0.82, 0)
		tt:AddLine(L.PUBLIC_NET_TIP:format(name), 1, 1, 1, true)
		if officer then tt:AddLine(L.PUBLIC_NET_OFFICER, 0.75, 0.75, 0.75, true) end
	end
	local before = #lines
	if officer then Views.GreyRows(lines, L.PUBLIC_NET:format(name), { tooltip = tip }) end
	local sealed = C.SealedPeers and C.SealedPeers() or 0
	if sealed > 0 then lines[#lines + 1] = { text = Grey(L.PUBLIC_NET_SPLIT:format(sealed)), tooltip = tip } end
	if #lines == before then return false end
	lines[#lines].gapAfter = true
	return true
end
Views.PublicLines = PublicLines

-- The pinned line (1.1, Channels.Pin): on top of the Sylvanistas chats and the Realm, for everyone.
-- Its setter, or a higher rank, takes it down with a click (after a question). Words the
-- player's block terms hide (Channels.PinWords) show after a first click, as a decree's.
local function PinLine(lines)
	local C = ns.Channels
	local p = C and C.Pin and C.Pin()
	if not p then return false end
	local who = ns.DisplayName(p.sender) or "?"
	local mayTakeDown = C.CanTakeDown and C.CanTakeDown()
	local words, veiled = C.PinWords(p)
	local onClick = mayTakeDown and function() ns.ShowDialog("SYLVANISTAS_PIN_DOWN") end or nil
	if veiled then
		onClick = function()
			p.revealed = true
			if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
		end
	end
	lines[#lines + 1] = {
		text = Gold(L.PIN_LABEL .. ": ") .. (veiled and Grey(L.FILTER_WORDS_HIDDEN) or ("|cffffffff" .. words .. "|r")),
		right = Grey(who),
		onClick = onClick,
		tooltip = function(tt)
			tt:AddLine(L.PIN_LABEL, 1, 0.82, 0)
			tt:AddLine(words, 1, 1, 1, true)
			tt:AddLine(L.PIN_TIP:format(who, Plain(p.guild), ns.Ago(p.setAt), math.max(1, math.ceil((p.expires - ns.Now()) / 60))), 0.7, 0.7, 0.7, true)
			if mayTakeDown and not veiled then tt:AddLine(L.PIN_DOWN_TIP, 0.25, 1, 0.25, true) end
		end,
		gapAfter = true,
	}
	return true
end
Views.PinLine = PinLine

-- How far the round of /who searches got (Who.lua), as grey lines under a list.
local function WhoStatus(lines)
	for _, text in ipairs(ns.Who.StatusLines() or {}) do lines[#lines + 1] = { text = Grey(text) } end
end

---------------------------------------------------------------------------
-- Census
---------------------------------------------------------------------------

Views.sort = { key = "members", desc = true }

local SORTERS = {
	name = function(e) return e.name:lower() end,
	members = function(e) return e.g.total or 0 end,
	online = function(e) return e.g.online or 0 end,
	lord = function(e) return (e.g.leader or ""):lower() end,
}

function Views.SortBy(key)
	if Views.sort.key == key then
		Views.sort.desc = not Views.sort.desc
	else
		Views.sort = { key = key, desc = key == "members" or key == "online" }
	end
end

-- A reported guild's row: its name, members, online and Lord; a click opens it in the Realm,
-- whose box it empties: a search left there could miss that guild and show nothing of it.
local function CensusRow(e)
	local g = e.g
	local leader = g.leader and ((g.leaderOnline and "|cff40ff40" or "|cff9d9d9d") .. Plain(g.leader) .. "|r") or Grey("?")
	return {
		cols = { Views.DisputeMark(g) .. Plain(e.name), ns.FormatNumber(g.total), Green(ns.FormatNumber(g.online)), leader },
		dim = not e.fresh,
		tooltip = GuildTooltip(e),
		onClick = function()
			-- Opened in the Realm, and the Realm opens on it (UI.KeepPlace), whatever its box held.
			Views.SetFilter("realm", "")
			expanded[e.name] = true
			ns.UI.SelectTab("realm", Views.GuildId(e.name))
		end,
	}
end

-- A guild seen with /who that nobody reports: grey, after every reported guild, and in no
-- total (Data.Summary keeps them apart). Members and Lord are unknown.
local function SeenRow(e)
	local online = ns.FormatNumber(e.online) .. (e.capped and "+" or "")
	return { cols = { Grey(e.name), Grey("?"), Grey(online), Grey(L.NO_ADDON) }, tooltip = SeenTooltip(e) }
end

-- The reported guilds in the order the column titles say, fresh reports first.
local function SortedGuilds(list)
	local get = SORTERS[Views.sort.key] or SORTERS.members
	local guilds = {}
	for i, e in ipairs(list) do guilds[i] = e end
	table.sort(guilds, function(a, b)
		if a.fresh ~= b.fresh then return a.fresh end
		local va, vb = get(a), get(b)
		if va == vb then return a.name < b.name end
		if Views.sort.desc then return va > vb end
		return va < vb
	end)
	return guilds
end

-- The guilds with room (1000 members is the game's cap), most free slots first; `min`: at least
-- that many free. Fresh reports only: an old one's size may be gone.
function Views.OpenGuilds(s, min)
	local open = {}
	for _, e in ipairs(s.guilds) do
		local free = 1000 - (e.g.total or 0)
		if e.fresh and free > 0 and free >= (min or 1) then open[#open + 1] = { name = e.name, free = free, e = e } end
	end
	table.sort(open, function(a, b)
		if a.free ~= b.free then return a.free > b.free end
		return a.name < b.name
	end)
	return open
end

-- How a count moved tonight (Data.ZoneTrend): "+120" green, "-30" red, "=" grey.
local function Trend(change)
	if not change then return nil end
	if change > 0 then return Green("+" .. ns.FormatNumber(change)) end
	if change < 0 then return Red("-" .. ns.FormatNumber(-change)) end
	return Grey("=")
end
Views.Trend = Trend

-- Tonight's count on this client (Data.SampleEvening), one grey line under the list, the zones in
-- its tooltip; nil before the first sample.
local function EveningLine()
	local e = ns.Data.Evening()
	if not e or e.samples == 0 then return nil end
	return {
		text = Grey(L.EVENING_LINE:format(ns.FormatNumber(e.peak or 0), date("%H:%M", e.peakAt or e.t), ns.FormatNumber(e.online or 0),
			date("%H:%M", e.since or e.t))),
		tooltip = function(tt)
			tt:AddLine(L.EVENING_TITLE, 1, 0.82, 0)
			tt:AddLine(L.EVENING_TIP:format(date("%H:%M", e.since or e.t)), 1, 1, 1, true)
			local zones = {}
			for key, z in pairs(e.zones) do
				if (z.now or 0) > 0 or (z.first or 0) > 0 then zones[#zones + 1] = { key = key, now = z.now or 0, change = (z.now or 0) - (z.first or 0) } end
			end
			table.sort(zones, function(a, b)
				if a.now ~= b.now then return a.now > b.now end
				return a.key < b.key
			end)
			if #zones > 0 then tt:AddLine(" ") end
			for i = 1, math.min(8, #zones) do
				local z = zones[i]
				tt:AddDoubleLine(ns.Zones.NameForKey(z.key), ns.FormatNumber(z.now) .. "  " .. Trend(z.change), 0.8, 0.8, 0.8, 1, 1, 1)
			end
			Why(tt, "count-differs-from-friend")
		end,
	}
end

-- A guild's line under a search's header (a zone's, Recruiting's): opens it in the Realm.
local function GuildLink(name, right, prefix)
	return {
		indent = 1, text = (prefix or "") .. Green("<" .. Plain(name) .. ">"), right = right,
		onClick = function()
			Views.SetFilter("realm", "")
			expanded[name] = true
			ns.UI.SelectTab("realm", Views.GuildId(name))
		end,
	}
end

-- The Census's search (1.1, request #16): "recruiting" (or "free 50", L.SEARCH_RECRUITING_WORDS)
-- lists every guild with room, the gates' guild first; the least free slots it asks for, or 1.
local function RecruitQuery(q)
	local word, n = q:match("^(%S+)%s*(%d*)$")
	if not word then return nil end
	for w in ns.Fold(L.SEARCH_RECRUITING_WORDS):gmatch("[^,%s]+") do
		if w == word then return math.max(1, tonumber(n) or 1) end
	end
	return nil
end

local function RecruitingLines(lines, s, min)
	local open = Views.OpenGuilds(s, min)
	lines[#lines + 1] = { header = true, text = L.RECRUITING, right = Grey(L.SEARCH_RECRUITING_COUNT:format(#open)) }
	local gates = ns.Acts and ns.Acts.Gates and ns.Acts.Gates()
	local first
	for i, o in ipairs(open) do
		if gates and o.name == gates.guild then first = i end
	end
	if first then table.insert(open, 1, table.remove(open, first)) end
	for _, o in ipairs(open) do
		lines[#lines + 1] = GuildLink(o.name, L.FREE_SLOTS:format(ns.FormatNumber(o.free)),
			(gates and o.name == gates.guild and CROWN or "") .. Views.DisputeMark(o.e.g))
	end
	if #open == 0 then lines[#lines + 1] = { indent = 1, text = Grey(L.ALL_FULL) } end
	lines[#lines].gapAfter = true
end

-- The zones whose name holds `q`, most soldiers first: each with its count, how it moved tonight
-- on this client, and its guilds there. Only what reporters who share their zone count (the tip).
local function ZoneLines(lines, s, q)
	for _, z in ipairs(s.zoneList) do
		local name = ns.Zones.NameForKey(z.key)
		if NameHolds(q, name) then
			local _, change = ns.Data.ZoneTrend(z.key)
			local e = ns.Data.Evening()
			lines[#lines + 1] = {
				header = true, text = name .. "  " .. Gold(ns.FormatNumber(z.count)),
				right = change and (Trend(change) .. " " .. Grey(L.EVENING_SINCE:format(date("%H:%M", e.since or e.t)))) or nil,
				tooltip = function(tt)
					tt:AddLine(name, 1, 0.82, 0)
					tt:AddLine(L.SEARCH_ZONE_TIP, 1, 1, 1, true)
					Why(tt, "count-map-zones")
				end,
			}
			local guilds = {}
			for guild, n in pairs(s.zoneGuilds[z.key] or {}) do guilds[#guilds + 1] = { name = guild, n = n } end
			table.sort(guilds, function(a, b)
				if a.n ~= b.n then return a.n > b.n end
				return a.name < b.name
			end)
			for _, g in ipairs(guilds) do lines[#lines + 1] = GuildLink(g.name, ns.FormatNumber(g.n)) end
			lines[#lines].gapAfter = true
		end
	end
end

-- The /who round's players by guild, for the Census's search.
local function CensusSwept()
	local out = {}
	local sweep = ns.Who and ns.Who.sweep
	for _, p in ipairs(sweep and sweep.list or {}) do
		if p.guild and p.name then
			out[p.guild] = out[p.guild] or {}
			table.insert(out[p.guild], p)
		end
	end
	return out
end

-- The players of a guild the Census's search finds, its Lord aside (his match shows the row
-- alone): its Captains, its highest levels (the report's top five) and who of it was seen online
-- (our roster for our own guild, /who's round for the others). Each once, as its row shows it.
Views.CENSUS_FOUND = 5 -- players listed under a guild's row, the rest counted
local function PlayersFound(e, q, own, swept)
	local g, out, seen = e.g, {}, {}
	local function Add(p)
		local short = p.name and ns.ShortName(p.name)
		if not short or seen[short] or not NameHolds(q, p.name) then return end
		seen[short] = true
		out[#out + 1] = p
	end
	for _, o in ipairs(g.officers or {}) do
		Add({ name = o.name, realm = g.realm, label = L.CAPTAIN, captain = true, level = o.level, class = o.class, zone = o.zone, online = o.online, days = o.days })
	end
	for _, p in ipairs(g.top or {}) do Add({ name = p.name, realm = g.realm, level = p.level, class = p.class }) end
	if e.name == own then
		for _, m in ipairs(ns.Roster.online or {}) do Add({ name = m.name, label = m.rank, level = m.level, class = m.class, zone = m.zone, online = true }) end
	else
		for _, p in ipairs(swept[e.name] or {}) do
			Add({ name = SeenName(p.name), level = p.level, class = ns.Roster.ClassCode(p.class), zone = p.zone and ns.Zones.KeyForName(p.zone), online = true })
		end
	end
	return out
end

local function PersonLine(e, p)
	return {
		key = p.name, indent = 1,
		text = (p.captain and ASSIST or "") .. ClassColored(p.name, p.class and ns.CLASS_FILES[p.class]) .. (p.label and ("  " .. Grey(Plain(p.label))) or ""),
		right = p.level and Grey(L.LEVEL_N:format(p.level)) or nil,
		onClick = function()
			ns.UI.ShowPerson({ name = p.name, realm = p.realm, class = p.class, level = p.level, zone = p.zone, guild = e.name,
				rank = p.label, online = p.online, days = p.days })
		end,
	}
end

-- `q`, the search (Views.Query): "recruiting" (every guild with room), the zones whose name holds
-- it (1.1), then the guilds whose name or Lord holds it, and those where it finds a Captain, a
-- player of the top five or one seen online (under its row), the reported ones then the ones only
-- seen (by name: nobody knows their Lord), in the same order as ever.
local function CensusLines(s, q)
	local lines = {}
	if q then
		local min = RecruitQuery(q)
		if min then RecruitingLines(lines, s, min) end
		ZoneLines(lines, s, q)
		local own, swept = GetGuildInfo("player"), nil
		for _, e in ipairs(SortedGuilds(s.guilds)) do
			if ns.Holds(q, Plain(e.name), e.g.leader and Plain(e.g.leader)) then
				lines[#lines + 1] = CensusRow(e)
			else
				swept = swept or CensusSwept()
				local found = PlayersFound(e, q, own, swept)
				if #found > 0 then
					lines[#lines + 1] = CensusRow(e)
					for i = 1, math.min(#found, Views.CENSUS_FOUND) do lines[#lines + 1] = PersonLine(e, found[i]) end
					if #found > Views.CENSUS_FOUND then
						lines[#lines + 1] = { indent = 1, text = Grey(L.SEARCH_MORE_FOUND:format(#found - Views.CENSUS_FOUND)) }
					end
				end
			end
		end
		for _, e in ipairs(s.seen or {}) do
			if ns.Holds(q, Plain(e.name)) then lines[#lines + 1] = SeenRow(e) end
		end
		if #lines == 0 then lines[1] = NoMatch() end
		return lines
	end
	-- Recruits asking to join our guild (1.1, Recruit.lua): an officer's Invite and Decline.
	for _, l in ipairs(ns.Recruit and ns.Recruit.RequestLines and ns.Recruit.RequestLines() or {}) do lines[#lines + 1] = l end
	-- The King's Agenda, for the whole army (King.lua).
	local a = ns.King and ns.King.Agenda and ns.King.Agenda()
	if a then
		lines[#lines + 1] = { text = Gold(L.THRONE_AGENDA_LINE:format(a.title, math.max(0, math.ceil((a.at - ns.Now()) / 60)), a.zone)), gapAfter = true }
	end
	-- The King holds court in our zone: one click asks for an audience (Court.lua).
	local court = ns.Court and ns.Court.Line and ns.Court.Line()
	if court then lines[#lines + 1] = court end
	-- While the King is online: one click asks for an invite to his layer (Hop.lua).
	for _, hop in ipairs(ns.Hop and ns.Hop.KingLines and ns.Hop.KingLines() or {}) do lines[#lines + 1] = hop end
	local kings = #lines -- (the King's lines above: "No reports yet" counts what comes below them)
	-- Above the guilds (1.1): the channel is public (who can read it), and right after login the
	-- census being rebuilt (said instead of "No reports yet").
	PublicLines(lines)
	local rebuilding = RebuildLines(lines)
	local top = #lines
	for _, e in ipairs(SortedGuilds(s.guilds)) do lines[#lines + 1] = CensusRow(e) end
	if #lines == top and kings == 0 and not rebuilding then Views.GreyRows(lines, L.EMPTY) end
	for _, e in ipairs(s.seen or {}) do lines[#lines + 1] = SeenRow(e) end
	if #(s.seen or {}) > 0 then
		lines[#lines].gapAfter = true
		lines[#lines + 1] = { text = Grey(L.SEEN_HINT) }
	end
	-- Tonight's count on this client (1.1).
	local evening = EveningLine()
	if evening then
		lines[#lines].gapAfter = true
		lines[#lines + 1] = evening
	end
	WhoStatus(lines)
	-- The addon's author online: Report a bug reaches him directly (Workshop.lua).
	local author = ns.Workshop and ns.Workshop.AuthorOnline and ns.Workshop.AuthorOnline() and ns.Workshop.AuthorName()
	if author then
		lines[#lines].gapAfter = true
		lines[#lines + 1] = { text = Grey(L.AUTHOR_ONLINE:format(ns.DisplayName(author))) }
	end
	-- This client is behind the author's version (1.1, his presence names it): one line, here alone.
	local behind = ns.Workshop and ns.Workshop.BehindLine and ns.Workshop.BehindLine()
	if behind then
		lines[#lines].gapAfter = true
		lines[#lines + 1] = behind
	end
	return lines
end

local function CensusDetail(s)
	local where = {}
	for i = 1, math.min(6, #s.zoneList) do
		local z = s.zoneList[i]
		where[#where + 1] = ns.Zones.NameForKey(z.key) .. " " .. Gold(ns.FormatNumber(z.count))
	end
	local text = #where > 0 and table.concat(where, "  ·  ") or L.NO_ZONES
	local conts = {}
	if ns.Map.ContinentTotals then
		local totals = ns.Map.ContinentTotals(s)
		for id, n in pairs(totals) do conts[#conts + 1] = { name = ns.Zones.NameForKey("m" .. id), n = n } end
		table.sort(conts, function(a, b) return a.n > b.n end)
	end
	local title = L.WHERE
	if #conts > 0 then
		local parts = {}
		for _, c in ipairs(conts) do parts[#parts + 1] = c.name .. " " .. ns.FormatNumber(c.n) end
		title = L.WHERE .. ":  |cffffffff" .. table.concat(parts, "  ·  ") .. "|r"
	end
	return title, text .. "\n" .. Grey(ns.UI.StatusLine())
end

---------------------------------------------------------------------------
-- The Realm
---------------------------------------------------------------------------

-- The King's guild: the one named exactly "Sylvanistas" (the addon's King everywhere else, the
-- Throne, the layer hop). No such guild reporting: no King line, never another guild's Lord.
local function King(guilds)
	for _, e in ipairs(guilds) do
		if ns.IsKingGuild(e.name) and e.g.leader then return e end
	end
	return nil
end

-- The members of a guild online now, besides its Lord and Captains: our own guild from our
-- roster, any other from /who (the round, and the guild's own search when its row was
-- opened, Who.SearchGuild). Reports carry no member lists: a thousand names per guild would
-- not fit on the channel. { name, level, class (code), zone (key), rank } each, by rank then
-- level.
-- `swept` (SweptByGuild): the round's players by guild, for a search through every guild at once.
Views.MAX_MEMBERS = 25
local allMembers = {} -- [guild] = true: its whole list shown ("... and N more" clicked)
function Views.MembersOf(guild, g, swept)
	local skip = {}
	if g and g.leader then skip[ns.ShortName(g.leader)] = true end
	for _, o in ipairs(g and g.officers or {}) do if o.name then skip[ns.ShortName(o.name)] = true end end
	local out, fromWho = {}, guild ~= GetGuildInfo("player")
	if not fromWho then
		for _, m in ipairs(ns.Roster.online or {}) do
			if not skip[ns.ShortName(m.name)] then out[#out + 1] = m end
		end
		return out, false
	end
	local sweep = ns.Who and ns.Who.sweep
	local own = ns.Who and ns.Who.GuildSeen and ns.Who.GuildSeen(guild)
	local round = swept and (swept[guild] or {}) or (sweep and sweep.list) or {}
	for _, source in ipairs({ own or {}, round }) do
		for _, p in ipairs(source) do
			local short = p.name and ns.ShortName(p.name)
			if p.guild == guild and short and not skip[short] then
				skip[short] = true -- each once, the guild's own search first
				out[#out + 1] = { name = ns.DisplayName(ns.FullName(p.name)), level = p.level, class = ns.Roster.ClassCode(p.class),
					zone = p.zone and ns.Zones.KeyForName(p.zone) }
			end
		end
	end
	table.sort(out, function(a, b)
		if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
		return a.name < b.name
	end)
	return out, true
end

---------------------------------------------------------------------------
-- The Realm tab's pages: in place of its tree, the Board and the pages modules list. (The Sylvanistas
-- chats had a page here too until 1.1.1: the Chat tab replaced it, ChatWindow.lua, and the tree's
-- link to the chats opens that tab.)
---------------------------------------------------------------------------

local boardShown = false -- the Board (Board.lua, 1.1) shown instead of the Realm tree
-- Pages of the Realm tab (1.1): a module lists one in ns.RealmPages (Loot.lua's loot notes,
-- Crafters.lua's board): { key, Link = function return its link line, or nil end,
-- Lines = function(q) return its lines end, tip = what its search finds (L.SEARCH_TIP_...) }.
-- A link line under the chats' link opens it in place of the tree.
local pageShown -- the page shown instead of the Realm tree, or nil

-- Another tab opened: the Realm opens on its tree again next time (our guild's members page, the
-- Board's and the other pages close, 1.1). (Named for the Sylvanistas chats' page, which it closed too
-- until 1.1.1.)
function Views.CloseChat()
	boardShown, pageShown = false, nil
	if ns.Members and ns.Members.Hide then ns.Members.Hide() end
end

local function RealmPage(key)
	for _, p in ipairs(ns.RealmPages or {}) do
		if p.key == key then return p end
	end
	return nil
end
function Views.PageShown() return pageShown end
function Views.ShowPage(key)
	pageShown = RealmPage(key) and key or nil
	if pageShown then
		boardShown = false
		if ns.Members and ns.Members.Hide then ns.Members.Hide() end
	end
	if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end
-- The Board (1.1): a page of the Realm tab. Opened, it asks the channel once a session for the
-- flags up now (Board.Ask). `quiet`: no redraw (the tab is opened right after).
function Views.BoardShown() return boardShown end
function Views.ShowBoard(on, quiet)
	boardShown = on and true or false
	if boardShown then
		pageShown = nil
		if ns.Members and ns.Members.Hide then ns.Members.Hide() end
		if ns.Board and ns.Board.Ask then ns.SafeCall("board ask", ns.Board.Ask) end
	end
	if not quiet and ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end

-- The channels our rank reads (the tree links the chats for them).
local function ChatTiers()
	local out = {}
	for _, tier in ipairs(ns.Channels.ORDER or {}) do
		if ns.Channels.CanUse(tier) then out[#out + 1] = tier end
	end
	return out
end

---------------------------------------------------------------------------
-- The High Council in the Realm (0.9.9): under the King and the Treasurer, the
-- moderators by department with their titles (Workshop.CouncilTree), for whoever may see them
-- (ns.CouncilVisible: until launch, the councillors and the author alone).
---------------------------------------------------------------------------

local COUNCIL_ROW = {} -- its open/closed key in `expanded`: no guild's name can be a table
-- The eye that shows the councillors' names on the King's screen (a game icon, Interface\Icons).
Views.EYE_ICON = "Interface\\Icons\\INV_Misc_Eye_01"

-- What the census knows of these names (a set of short names, lower case): each guild's Lord
-- and Captains from a fresh report, then who was seen online (our roster, /who), then the Lords
-- and Captains of older reports, the first found. (An old report last: days old, it must not
-- hide someone seen online now.) Short name -> a person as the rows open them, and the set of
-- those only an old report knows.
local function Known(s, wanted)
	local out, old = {}, {}
	local function Add(guild, p, stale)
		local key = type(p.name) == "string" and ns.ShortName(p.name):lower()
		if key and wanted[key] and not out[key] then
			p.guild = guild
			out[key], old[key] = p, stale or nil
		end
	end
	local function Reports(fresh)
		for _, e in ipairs(s.guilds) do
			local g = e.g
			if e.fresh == fresh then
				if g.leader then
					Add(e.name, { name = g.leader, realm = g.realm, class = g.leaderClass, level = g.leaderLevel, zone = g.leaderZone,
						rank = LeaderTitle(e.name), online = g.leaderOnline, days = g.leaderDays }, not fresh)
				end
				for _, o in ipairs(g.officers or {}) do
					Add(e.name, { name = o.name, realm = g.realm, class = o.class, level = o.level, zone = o.zone, rank = L.CAPTAIN,
						online = o.online, days = o.days }, not fresh)
				end
			end
		end
	end
	Reports(true)
	local mine = GetGuildInfo("player")
	for _, m in ipairs(mine and ns.Roster.online or {}) do
		Add(mine, { name = m.name, class = m.class, level = m.level, zone = m.zone, rank = m.rank, online = true })
	end
	-- (As Views.MembersOf reads /who: the guild's own search, then the round.)
	local sweep = ns.Who and ns.Who.sweep
	for _, e in ipairs(s.guilds) do
		local own = ns.Who and ns.Who.GuildSeen and ns.Who.GuildSeen(e.name)
		for _, source in ipairs({ own or {}, sweep and sweep.list or {} }) do
			for _, p in ipairs(source) do
				if p.guild == e.name and p.name then
					Add(e.name, { name = ns.DisplayName(ns.FullName(p.name)), level = p.level, class = ns.Roster.ClassCode(p.class),
						zone = p.zone and ns.Zones.KeyForName(p.zone), online = true })
				end
			end
		end
	end
	Reports(false)
	return out, old
end

local function Council(s) return "|c" .. ns.HIGH_COUNCIL_COLOR .. s .. "|r" end

-- `q`, the Realm's search (Views.Query): only the councillors whose name as their row shows it
-- holds it (on the King's stream, the first four characters: never what is hidden), under the
-- council's header (opened for it) and their department's; how many, 0 for none (nothing drawn).
local function CouncilLines(lines, s, q)
	local loose, depts = ns.Workshop.CouncilTree()
	local n = #loose
	for _, d in ipairs(depts) do n = n + #d.members end
	if n == 0 then return 0 end
	-- The King's screen (his stream): the names hidden until he clicks the eye, and hidden again
	-- on the next click (ns.CouncilMasked, Core.lua).
	local masked = ns.CouncilMasked()
	local function Hit(m)
		if not q then return true end
		local shown = masked and ns.MaskName(Plain(m.name)):sub(1, -5) or Plain(m.name)
		return ns.Holds(q, shown)
	end
	local hits = 0
	for _, m in ipairs(loose) do if Hit(m) then hits = hits + 1 end end
	for _, d in ipairs(depts) do for _, m in ipairs(d.members) do if Hit(m) then hits = hits + 1 end end end
	if q and hits == 0 then return 0 end
	local open = expanded[COUNCIL_ROW]
	if q then open = not folded[COUNCIL_ROW] end
	lines[#lines + 1] = {
		text = (open and "[-] " or "[+] ") .. ns.HIGH_COUNCIL_MARK .. " " .. Council(L.COUNCIL_CENSUS:format(n)),
		onClick = function()
			if q then
				folded[COUNCIL_ROW] = not folded[COUNCIL_ROW] or nil
			else
				expanded[COUNCIL_ROW] = not expanded[COUNCIL_ROW] or nil
			end
			ns.UI.Refresh()
		end,
		tooltip = function(tt)
			tt:AddLine(L.COUNCIL_CENSUS:format(n), 0.69, 0.28, 0.97)
			tt:AddLine(L.COUNCIL_CENSUS_TIP, 1, 1, 1, true)
		end,
	}
	if not open then return hits end
	if ns.KingsScreen() and not q then
		local label = masked and L.COUNCIL_NAMES_SHOW or L.COUNCIL_NAMES_HIDE
		lines[#lines + 1] = {
			indent = 1,
			text = "|T" .. Views.EYE_ICON .. ":0|t " .. Gold(label),
			onClick = function()
				local show = not ns.CouncilNamesShown()
				ns.SetCouncilNamesShown(show)
				if not show and ns.UI.CloseCouncilCards then ns.UI.CloseCouncilCards() end
				ns.UI.Refresh()
			end,
			tooltip = function(tt)
				tt:AddLine(label, 1, 0.82, 0)
				tt:AddLine(L.COUNCIL_NAMES_TIP, 1, 1, 1, true)
			end,
		}
	end
	local wanted = {}
	for _, m in ipairs(loose) do wanted[m.name:lower()] = true end
	for _, d in ipairs(depts) do for _, m in ipairs(d.members) do wanted[m.name:lower()] = true end end
	local known, old = Known(s, wanted)
	-- "<mark><own icon> Name - Title": where the census knows them, when they were last on, and a
	-- click opens what it knows. Hidden (the King's stream): "<mark> Name****", the title, where
	-- they are, and no click (the card would carry the whole name).
	local function Member(m, indent)
		local p = known[m.name:lower()]
		local person = p or { name = m.name }
		lines[#lines + 1] = {
			key = not masked and person.name or nil,
			indent = indent,
			text = (masked and (ns.HIGH_COUNCIL_MARK .. " " .. Council(ns.MaskName(Plain(m.name))))
					or (ns.CouncilMark(m.name) .. " " .. Council(Plain(m.name))))
				.. (m.title and (" - " .. Grey(Plain(m.title))) or ""),
			right = p and Presence(p.online, p.days, old[m.name:lower()]) or nil,
			onClick = not masked and function() ns.UI.ShowPerson(person) end or nil,
		}
	end
	for _, m in ipairs(loose) do if Hit(m) then Member(m, 1) end end
	for _, d in ipairs(depts) do
		local any = not q
		for _, m in ipairs(d.members) do any = any or Hit(m) end
		if any then
			local icon = ns.CouncilIconTexture(d.icon)
			lines[#lines + 1] = { indent = 1, text = (icon and ("|T" .. icon .. ":0|t ") or "") .. Gold(Plain(d.name)) }
			for _, m in ipairs(d.members) do if Hit(m) then Member(m, 2) end end
		end
	end
	return hits
end

-- The /who round's players by guild (Views.MembersOf's `swept`), in the round's order: the
-- search looks into every guild, and the round can list thousands.
local function SweptByGuild()
	local out = {}
	local sweep = ns.Who and ns.Who.sweep
	for _, p in ipairs(sweep and sweep.list or {}) do
		if p.guild then
			out[p.guild] = out[p.guild] or {}
			table.insert(out[p.guild], p)
		end
	end
	return out
end

-- The guilds where the Realm's search `q` finds a player seen online (Views.MembersOf's sources:
-- our roster for our own guild `own`, /who's round for the others), before any member list is
-- made: [guild] = true.
local function SeenHits(q, own)
	local hit = {}
	local sweep = ns.Who and ns.Who.sweep
	for _, p in ipairs(sweep and sweep.list or {}) do
		local guild = p.guild
		if guild and guild ~= own and not hit[guild] and p.name and NameHolds(q, SeenName(p.name)) then hit[guild] = true end
	end
	if own then
		for _, m in ipairs(ns.Roster.online or {}) do
			if NameHolds(q, m.name) then
				hit[own] = true
				break
			end
		end
	end
	return hit
end

-- What of a guild the Realm's search finds, its name aside: its Lord, its Captains and the
-- members seen online (our roster, /who), each by name as its row shows it. `ctx`: the search
-- (q, own, hits: SeenHits, swept: SweptByGuild once needed). The member list (Views.MembersOf
-- makes a table for each player and sorts them) is made only for a guild where someone is found
-- and only when `rows` (the guild will show): otherwise `n` counts a member found as one.
local function GuildMatches(e, ctx, rows)
	local g, q = e.g, ctx.q
	local found = { lord = NameHolds(q, g.leader), officers = {}, members = {}, all = {} }
	for _, o in ipairs(g.officers or {}) do
		if NameHolds(q, o.name) then found.officers[#found.officers + 1] = o end
	end
	local seen = ctx.hits[e.name]
	if not seen and e.name ~= ctx.own then
		for _, p in ipairs(ns.Who and ns.Who.GuildSeen and ns.Who.GuildSeen(e.name) or {}) do
			if p.guild == e.name and p.name and NameHolds(q, SeenName(p.name)) then
				seen = true
				break
			end
		end
	end
	if seen and rows then
		ctx.swept = ctx.swept or SweptByGuild()
		local members, fromWho = Views.MembersOf(e.name, g, ctx.swept)
		for _, m in ipairs(members) do
			if NameHolds(q, m.name) then found.members[#found.members + 1] = m end
		end
		found.all, found.fromWho = members, fromWho
	end
	found.n = (found.lord and 1 or 0) + #found.officers + (rows and #found.members or seen and 1 or 0)
	return found
end

-- `q`, the search (Views.Query): the High Council's names (for whoever may see it), then each
-- guild whose name holds it, whole, and each whose Lord, Captains or members seen do, opened on
-- those alone; "No match" for none. The chats' link stays (the Chat tab it opens has a search of
-- its own). Nothing
-- else: the King's lines, the level race, recruiting and the layers show once it is emptied.
local function RealmLines(s, q)
	if boardShown and ns.Board and not ns.Board.missing and ns.Board.Lines then return ns.Board.Lines(q) end
	local page = pageShown and RealmPage(pageShown)
	if page then return page.Lines(q) end
	-- Our guild's members page (1.1, Members.lua).
	if ns.Members and ns.Members.Shown and ns.Members.Shown() then return ns.Members.Lines(q) end
	local lines = {}
	-- A councillor's mark and own icon after their name in the rows below (0.9.9), for whoever
	-- may see the council here; none on the King's screen while the names are hidden (his
	-- stream: a whole name next to the mark would give the councillor away).
	local councilShown = ns.CouncilVisible()
	local councilTagged = councilShown and not ns.CouncilMasked()
	local function Tag(name, home)
		local full = ns.FullName(name, home)
		if not councilTagged or not ns.IsHighCouncillor(full) then return "" end
		return " " .. ns.CouncilMark(full)
	end
	local function Mark(name, home, online)
		return ns.King and ns.King.RollCallMark and ns.King.RollCallMark(ns.FullName(name, home), online) or ""
	end
	-- The pinned line on top (1.1), for everyone.
	if not q then PinLine(lines) end
	-- The King holds court in our zone (Court.lua), then his layer (Hop.lua).
	local court = not q and ns.Court and ns.Court.Line and ns.Court.Line()
	if court then lines[#lines + 1] = court end
	for _, hop in ipairs(not q and ns.Hop and ns.Hop.KingLines and ns.Hop.KingLines() or {}) do lines[#lines + 1] = hop end
	-- The King (and his Hands): Summon the Lords, and who answered (King.lua). While it is
	-- fresh, each Lord and Captain in the tree carries a ready-check mark.
	for _, l in ipairs(not q and ns.King and ns.King.RollCallLines and ns.King.RollCallLines() or {}) do lines[#lines + 1] = l end
	local king = not q and King(s.guilds)
	if king then
		lines[#lines + 1] = {
			header = true,
			text = CROWN .. L.KING .. ": " .. Gold(Plain(king.g.leader or "?")),
			right = Presence(king.g.leaderOnline, king.g.leaderDays),
			tooltip = GuildTooltip(king),
		}
		-- The Treasurer of Sylvanistas, under the King: when that guild's report has him (the
		-- Horde's <Sylvanistas> and other realms' have no Treasurer of theirs).
		local t
		for _, o in ipairs(king.name:lower() == "sylvanistas" and king.g.officers or {}) do -- (the Treasurer: <Sylvanistas>, the Alliance's)
			if ns.IsTreasurer(o.name, king.name) then t = o end
		end
		if t then
			local person = { name = t.name, realm = king.g.realm, guild = king.name, class = t.class, level = t.level, zone = t.zone,
				rank = L.CAPTAIN, online = t.online, days = t.days }
			lines[#lines + 1] = {
				key = t.name,
				text = ns.COIN .. L.TREASURER .. ": " .. Gold(Plain(t.name)),
				right = Presence(t.online, t.days),
				onClick = function() ns.UI.ShowPerson(person) end,
			}
			-- The treasury, when he shares it (Treasury.lua).
			local shared = ns.Treasury and ns.Treasury.RealmText and ns.Treasury.RealmText()
			if type(shared) == "string" then lines[#lines + 1] = { indent = 1, text = Grey(shared) } end
		end
	end
	-- 1.1: the treasury's keepers taking donations now (Treasury.lua), under the King and the Treasurer.
	for _, l in ipairs(not q and ns.Treasury and ns.Treasury.DonationLines and ns.Treasury.DonationLines() or {}) do lines[#lines + 1] = l end
	-- The High Council, under them (0.9.9).
	local found = councilShown and CouncilLines(lines, s, q) or 0
	-- Above the chats and the guilds (1.1): the channel is public (who can read them), and right
	-- after login the census being rebuilt (said instead of "No reports yet").
	local rebuilding = false
	if not q then
		local before = #lines
		PublicLines(lines)
		rebuilding = RebuildLines(lines)
		if #lines > before and lines[before] then lines[before].gapAfter = true end
	end
	-- The Sylvanistas chats, one click away (the channels our rank reads), above the guilds: the
	-- Sylvanistas window on its Chat tab (1.1.1, ChatWindow.lua; the page the Realm tab had for them is
	-- gone, the author's call). Off on this client (1.1): a line that says so, and a click to choose
	-- (the first-open page).
	if #ChatTiers() > 0 and not ns.Channels.ChatOn() then
		if lines[#lines] then lines[#lines].gapAfter = true end
		lines[#lines + 1] = {
			text = "|TInterface\\ChatFrame\\UI-ChatIcon-Chat-Up:14:14|t " .. Grey(L.CHATS_OFF_LINK), gapAfter = true, pageLink = true,
			onClick = function() ns.Consent.Show() end,
			tooltip = function(tt)
				tt:AddLine(L.CONSENT_CHAT, 1, 0.82, 0)
				tt:AddLine(L.CONSENT_CHAT_TEXT, 1, 1, 1, true)
			end,
		}
	elseif #ChatTiers() > 0 then
		if lines[#lines] then lines[#lines].gapAfter = true end
		lines[#lines + 1] = {
			text = "|TInterface\\ChatFrame\\UI-ChatIcon-Chat-Up:14:14|t " .. Gold(L.CHATS_LINK), gapAfter = true, pageLink = true,
			onClick = function() ns.ChatWindow.Open() end,
			tooltip = function(tt)
				tt:AddLine(L.CHATS_LINK, 1, 0.82, 0)
				tt:AddLine(L.CHATS_TIP, 1, 1, 1, true)
				tt:AddLine(L.CHATS_OPEN_WINDOW_TIP, 0.75, 0.75, 0.75, true)
			end,
		}
	end
	-- The Board (1.1, Board.lua) and the Realm's other pages (1.1, ns.RealmPages), one link each:
	-- close together under the chats' link, one gap after the last, so the guilds stay in sight
	-- on the guild window's short list.
	local links = {}
	local board = not q and ns.Board and ns.Board.LinkLine and ns.Board.LinkLine()
	if board then links[#links + 1] = board end
	for _, p in ipairs(not q and ns.RealmPages or {}) do
		local link = p.Link and p.Link()
		if link then links[#links + 1] = link end
	end
	if #links > 0 then
		local prev = lines[#lines]
		if prev then prev.gapAfter = not prev.pageLink end
		for i, link in ipairs(links) do
			link.pageLink = true
			link.gapAfter = i == #links
			lines[#lines + 1] = link
		end
	end
	if #s.guilds == 0 and not q and not rebuilding then Views.GreyRows(lines, L.EMPTY) end
	-- A guild's header and, opened, its rows. `only`: what the search found in it (GuildMatches),
	-- its rows alone under the headers they belong to; nil: all of them. `folds`: its click
	-- closes and opens what the search opened, instead of the guild itself.
	local function Guild(e, open, only, folds)
		local g = e.g
		lines[#lines + 1] = {
			id = Views.GuildId(e.name),
			text = (open and "[-] " or "[+] ") .. Views.DisputeMark(g) .. Green("<" .. Plain(e.name) .. ">") .. " " .. Plain(g.leader or "?"),
			right = Presence(g.leaderOnline, g.leaderDays),
			onClick = function()
				if folds then
					folded[e.name] = not folded[e.name] or nil
					return ns.UI.Refresh()
				end
				expanded[e.name] = not expanded[e.name] or nil
				-- Opened: a /who for that guild alone lists who of it is online (a click, so the
				-- game allows it). Our own guild is in our roster already.
				if expanded[e.name] and e.name ~= GetGuildInfo("player") then ns.SafeCall("guild who", ns.Who.SearchGuild, e.name) end
				ns.UI.Refresh()
			end,
			tooltip = GuildTooltip(e),
			color = e.fresh and "GameFontHighlightSmall" or "GameFontDisableSmall",
		}
		if not open then return end
		if g.leader and (not only or only.lord) then
			local lord = { name = g.leader, realm = g.realm, class = g.leaderClass, level = g.leaderLevel, zone = g.leaderZone,
				guild = e.name, rank = LeaderTitle(e.name), online = g.leaderOnline, days = g.leaderDays }
			lines[#lines + 1] = {
				key = g.leader,
				indent = 1, text = Mark(g.leader, g.realm, g.leaderOnline) .. CROWN .. Gold(lord.rank) .. "  " .. ClassColored(g.leader, lord.class and ns.CLASS_FILES[lord.class])
					.. Tag(g.leader, g.realm),
				right = Presence(g.leaderOnline, g.leaderDays),
				onClick = function() ns.UI.ShowPerson(lord) end,
			}
		end
		local officers = g.officers or {}
		local listed = only and only.officers or officers
		if #listed > 0 or not only then
			lines[#lines + 1] = { indent = 1, text = Gold(L.CAPTAINS:format(#officers)),
				-- (1.1.2: another guild's report names 30 Captains at most, Codec.lua.)
				tooltip = function(tt)
					local ours = e.name == GetGuildInfo("player")
					tt:AddLine(L.CAPTAINS:format(#officers), 1, 0.82, 0)
					tt:AddLine(ours and L.CAPTAINS_OWN_TIP or L.CAPTAINS_TIP, 1, 1, 1, true)
					Why(tt, ours and "count-own-guild-live" or "count-other-guild-report")
				end }
		end
		for _, o in ipairs(listed) do
			local person = { name = o.name, realm = g.realm, class = o.class, level = o.level, zone = o.zone, guild = e.name,
				rank = L.CAPTAIN, online = o.online, days = o.days }
			lines[#lines + 1] = {
				key = o.name,
				indent = 2, text = Mark(o.name, g.realm, o.online) .. ASSIST .. ClassColored(o.name, o.class and ns.CLASS_FILES[o.class])
					.. Tag(o.name, g.realm) .. (ns.IsTreasurer(o.name, e.name) and ("  " .. ns.COIN .. Grey(L.TREASURER)) or ""),
				right = (o.level and Grey(L.LEVEL_N:format(o.level)) .. "  " or "") .. Presence(o.online, o.days),
				onClick = function() ns.UI.ShowPerson(person) end,
			}
		end
		if #officers == 0 and not only then lines[#lines + 1] = { indent = 2, text = Grey(L.NONE_REPORTED) } end
		-- Everyone else online: our roster, or /who for other guilds.
		local members, fromWho
		if only then members, fromWho = only.all, only.fromWho else members, fromWho = Views.MembersOf(e.name, g) end
		listed = only and only.members or members
		if #listed > 0 or not only then
			lines[#lines + 1] = {
				indent = 1, text = Gold((fromWho and L.MEMBERS_SEEN or L.MEMBERS_ONLINE):format(#members)),
				tooltip = function(tt)
					tt:AddLine((fromWho and L.MEMBERS_SEEN or L.MEMBERS_ONLINE):format(#members), 1, 0.82, 0)
					tt:AddLine(fromWho and L.MEMBERS_SEEN_TIP or L.MEMBERS_ONLINE_TIP, 1, 1, 1, true)
					Why(tt, fromWho and "count-other-guild-seen-online" or "count-realm-online-now")
				end,
			}
		end
		-- (The search's members a page at a time too.)
		local shown = allMembers[e.name] and #listed or math.min(Views.MAX_MEMBERS, #listed)
		for i = 1, shown do
			local m = listed[i]
			local person = { name = m.name, class = m.class, level = m.level, zone = m.zone, guild = e.name, rank = m.rank, online = true }
			lines[#lines + 1] = {
				key = m.name,
				indent = 2, text = ClassColored(m.name, m.class and ns.CLASS_FILES[m.class]) .. Tag(m.name) .. (m.rank and ("  " .. Grey(m.rank)) or "")
					.. (ns.IsTreasurer(m.name, e.name) and ("  " .. ns.COIN .. Grey(L.TREASURER)) or ""),
				right = m.level and Grey(L.LEVEL_N:format(m.level)) or nil,
				onClick = function() ns.UI.ShowPerson(person) end,
			}
		end
		-- The rest on a click, and back again.
		if #listed > shown then
			lines[#lines + 1] = {
				indent = 2, text = Gold(L.MEMBERS_MORE:format(#listed - shown)),
				onClick = function() allMembers[e.name] = true; ns.UI.Refresh() end,
			}
		elseif allMembers[e.name] and #listed > Views.MAX_MEMBERS then
			lines[#lines + 1] = {
				indent = 2, text = Gold(L.MEMBERS_FEWER),
				onClick = function() allMembers[e.name] = nil; ns.UI.Refresh() end,
			}
		end
		if only then
			lines[#lines].gapAfter = true
			return
		end
		if #members == 0 then lines[#lines + 1] = { indent = 2, text = Grey(fromWho and L.MEMBERS_NONE_SEEN or L.MEMBERS_NONE) } end
		lines[#lines + 1] = { indent = 1, text = Gold(L.RANKS) }
		for i, rank in ipairs(g.ranks or {}) do
			lines[#lines + 1] = { indent = 2, text = ("%d. %s"):format(i, Plain(rank.name)), right = ns.FormatNumber(rank.count) }
		end
		if #(g.ranks or {}) == 0 then lines[#lines + 1] = { indent = 2, text = Grey(L.NONE_REPORTED) } end
		-- Our own guild's: a click lists them, by name (1.1, Members.lua).
		local own = g.mine and e.name == GetGuildInfo("player")
		lines[#lines + 1] = {
			indent = 1, gapAfter = true,
			text = own and Gold(L.INACTIVE_LINE:format(g.inactive7 or 0, g.inactive30 or 0) .. "  " .. L.MEMBERS_OPEN)
				or Grey(L.INACTIVE_LINE:format(g.inactive7 or 0, g.inactive30 or 0)),
			onClick = own and function() ns.Members.Show(7) end or nil,
			tooltip = own and function(tt)
				tt:AddLine(L.MEMBERS_TITLE, 1, 0.82, 0)
				tt:AddLine(L.MEMBERS_OPEN_TIP, 1, 1, 1, true)
			end or nil,
		}
	end
	-- (The guilds opened for a Lord, Captain or member found: `searchRows` of their rows, the
	-- guilds past them counted in `more`, shown on a click.)
	local ctx, rows, more
	if q then
		local own = GetGuildInfo("player")
		ctx, rows, more = { q = q, own = own, hits = SeenHits(q, own) }, 0, 0
	end
	for _, e in ipairs(s.guilds) do
		if not q or NameHolds(q, e.name) then
			-- (Found by its name: the guild as ever, opened or not.)
			if q then found = found + 1 end
			Guild(e, expanded[e.name])
		else
			local room = rows < searchRows
			local only = GuildMatches(e, ctx, room)
			if only.n > 0 then
				found = found + only.n
				if room then
					local before = #lines
					Guild(e, not folded[e.name], only, true)
					rows = rows + #lines - before
				else
					more = more + 1
				end
			end
		end
	end
	if q then
		if more > 0 then
			lines[#lines + 1] = {
				text = Gold(L.SEARCH_MORE_GUILDS:format(more)),
				onClick = function()
					searchRows = searchRows + Views.SEARCH_ROWS
					ns.UI.Refresh()
				end,
			}
		end
		if found == 0 then lines[#lines + 1] = NoMatch() end
		return lines
	end

	local racers = {}
	for _, e in ipairs(s.guilds) do
		if e.fresh then
			for _, p in ipairs(e.g.top or {}) do racers[#racers + 1] = { name = p.name, realm = e.g.realm, level = p.level, class = p.class, guild = e.name } end
		end
	end
	table.sort(racers, function(a, b)
		if a.level ~= b.level then return a.level > b.level end
		return a.name < b.name
	end)
	lines[#lines + 1] = { header = true, text = L.LEVEL_RACE }
	if #racers == 0 then lines[#lines + 1] = { text = Grey(L.NONE_REPORTED) } end
	-- The top 100, shown 25 at a time (0.9.7): the window stays light.
	local shownRacers = math.min(#racers, Views.RACE_MAX, Views.raceShown)
	for i = 1, shownRacers do
		local p = racers[i]
		lines[#lines + 1] = {
			key = p.name,
			text = ("%d. %s  %s"):format(i, ClassColored(p.name, p.class and ns.CLASS_FILES[p.class]), Grey("<" .. Plain(p.guild) .. ">")),
			right = Gold(L.LEVEL_N:format(p.level)),
			onClick = function() ns.UI.ShowPerson({ name = p.name, realm = p.realm, class = p.class, level = p.level, guild = p.guild }) end,
		}
	end

	local total = math.min(#racers, Views.RACE_MAX)
	if total > shownRacers then
		lines[#lines + 1] = { text = Grey(L.SHOW_MORE:format(math.min(Views.RACE_PAGE, total - shownRacers), shownRacers, total)),
			onClick = function() Views.raceShown = Views.raceShown + Views.RACE_PAGE; ns.Fire("DATA_CHANGED") end }
	end

	local open = Views.OpenGuilds(s)
	-- (1.1.2's review: free slots are 1000 less the size of each guild's last report.)
	lines[#lines + 1] = { header = true, text = L.RECRUITING, tooltip = function(tt)
		tt:AddLine(L.RECRUITING, 1, 0.82, 0)
		Why(tt, "count-other-guild-report")
	end }
	-- The gates the King (or a Hand) opened: where new recruits go now (Acts.lua).
	local gates = ns.Acts and ns.Acts.Gates and ns.Acts.Gates()
	local commands = ns.King and (ns.King.CanCommand() or ns.King.Preview())
	if gates then
		local left = math.max(0, gates.at - ns.Now())
		lines[#lines + 1] = {
			text = CROWN .. Gold(L.GATES_LINE:format(gates.guild)),
			onClick = commands and function() ns.Acts.GatesClick(gates.guild) end or nil,
			tooltip = function(tt)
				tt:AddLine(L.GATES_LINE:format(gates.guild), 1, 0.82, 0, true)
				tt:AddLine(L.GATES_TIP:format(math.floor(left / 3600), math.floor(left % 3600 / 60)), 1, 1, 1, true)
				if commands and ns.Acts.CanClose() then tt:AddLine(L.GATES_CLOSE_TIP, 0.6, 0.6, 0.6, true) end
			end,
		}
	end
	if #open == 0 then lines[#lines + 1] = { text = Grey(L.ALL_FULL) } end
	-- The first RECRUIT_SHOWN, every one on a click (1.1, request #16), and back.
	local shownOpen = Views.recruitAll and #open or math.min(Views.RECRUIT_SHOWN, #open)
	for i = 1, shownOpen do
		local name = open[i].name
		-- (Its census mark too, 1.1: the gates open on its size, request #30.)
		local mark, d = Views.DisputeMark(open[i].e.g)
		lines[#lines + 1] = {
			text = mark .. Green("<" .. name .. ">"), right = L.FREE_SLOTS:format(ns.FormatNumber(open[i].free)),
			-- The King and his Hands open a guild's gates from here.
			onClick = commands and function() ns.Acts.GatesClick(name) end or nil,
			tooltip = function(tt)
				tt:AddLine("<" .. name .. ">", 0.25, 1, 0.25)
				if commands then
					local closing = gates and gates.guild == name
					tt:AddLine(closing and (ns.Acts.CanClose() and L.GATES_CLOSE_TIP or L.GATES_ONLY_OPENER) or L.GATES_CLICK_TIP, 1, 1, 1, true)
				end
				DisputeTooltip(tt, d)
				Why(tt, "count-other-guild-report")
			end,
		}
	end
	if #open > Views.RECRUIT_SHOWN then
		lines[#lines + 1] = {
			text = Gold(Views.recruitAll and L.RECRUIT_SHOW_FEWER or L.RECRUIT_SHOW_ALL:format(#open)),
			onClick = function()
				Views.recruitAll = not Views.recruitAll or nil
				ns.UI.Refresh()
			end,
		}
	end
	-- Our do-not-contact flag (1.1, request #20): recruits' Join screens skip us while it is on.
	local closed = ns.Recruit and ns.Recruit.NoContactMe and ns.Recruit.NoContactMe()
	lines[#lines + 1] = {
		text = Grey(closed and L.NOCONTACT_LINE_ON or L.NOCONTACT_LINE_OFF),
		onClick = function() ns.Recruit.SetNoContact(not closed) end,
		tooltip = function(tt)
			tt:AddLine(L.NOCONTACT_TITLE, 1, 0.82, 0)
			tt:AddLine(L.NOCONTACT_TIP, 1, 1, 1, true)
		end,
	}

	local mapID = ns.Layers.CurrentMap()
	local zone = mapID and ns.Zones.NameForKey("m" .. mapID) or "?"
	lines[#lines + 1] = { header = true, text = L.LAYERS_IN:format(zone) }
	local layers = mapID and ns.Layers.ForMap(mapID) or {}
	if #layers == 0 then lines[#lines + 1] = { text = Grey(L.LAYERS_HINT) } end
	for _, layer in ipairs(layers) do
		local head = layer.head
		lines[#lines + 1] = {
			text = (layer.mine and Green("> ") or "   ") .. Gold(ns.Layers.Name(layer)) .. Grey(("  #%d"):format(layer.zoneUID)),
			right = L.LAYER_COUNT:format(layer.count),
			-- Another layer: one click asks the Sylvanistas players there for an invite (Hop.lua).
			onClick = not layer.mine and function() ns.Hop.Ask(mapID, layer.zoneUID, ns.Layers.Name(layer)) end or nil,
			tooltip = function(tt)
				tt:AddLine(ns.Layers.Name(layer), 1, 0.82, 0)
				if head then tt:AddLine(("%s <%s>"):format(head.name, head.guild or "?"), 1, 1, 1) end
				if layer.mine then tt:AddLine(L.LAYER_YOU, 0.25, 1, 0.25) else tt:AddLine(L.HOP_ROW_TIP, 0.25, 1, 0.25, true) end
				tt:AddLine(L.LAYER_EXPERIMENTAL, 0.6, 0.6, 0.6, true)
				-- (1.1.2: "~N with Sylvanistas" is a sample: Layers.lua.)
				Why(tt, "count-layer-sample")
			end,
		}
	end
	return lines
end

local function RealmDetail(s)
	local lords, captains, inactive = 0, 0, 0
	for _, e in ipairs(s.guilds) do
		if e.fresh then
			lords = lords + 1
			captains = captains + #(e.g.officers or {})
			inactive = inactive + (e.g.inactive30 or 0)
		end
	end
	return L.TAB_REALM, L.REALM_DETAIL:format(lords, captains, ns.FormatNumber(inactive)) .. "\n" .. Grey(L.CLICK_EXPAND)
end

-- (While a search is typed, the guilds it opened close and open with them.)
function Views.ExpandAll(on)
	for _, e in ipairs(ns.Data.Summary().guilds) do expanded[e.name], folded[e.name] = on or nil, not on or nil end
	expanded[COUNCIL_ROW], folded[COUNCIL_ROW] = on or nil, not on or nil -- (the High Council's too)
end

---------------------------------------------------------------------------
-- Decrees (layers + decrees)
---------------------------------------------------------------------------

local function DecreeLines()
	-- What waits in an instance or on Busy, on top (1.1, ns.Alert); then the King's writs, for
	-- whoever they are for (Acts.lua).
	local lines = ns.HeldLines()
	for _, l in ipairs(ns.Acts and ns.Acts.WritLines and ns.Acts.WritLines() or {}) do lines[#lines + 1] = l end
	-- 1.1: who the moderators took off (net-off, Moderation.lua), and their buttons.
	for _, l in ipairs(ns.Moderation.Lines and ns.Moderation.Lines() or {}) do lines[#lines + 1] = l end
	lines[#lines + 1] = { header = true, text = L.DECREES }
	local decrees = ns.Decree.Active()
	if #decrees == 0 then lines[#lines + 1] = { text = Grey(L.NO_DECREES), gapAfter = true } end
	for _, d in ipairs(decrees) do
		local color = d.kind == "ARMS" and Red or Gold
		-- 1.1 (#31): words the player's block terms hide, until a click shows them.
		local veiled = d.hidden and not d.revealed
		lines[#lines + 1] = {
			text = color(ns.Decree.Label(d)) .. "  " .. ns.Zones.NameForKey("m" .. d.mapID),
			right = Grey(ns.Ago(d.t)),
			tooltip = function(tt)
				tt:AddLine(ns.Decree.Label(d), 1, 0.25, 0.25)
				if d.text ~= "" then tt:AddLine(veiled and L.FILTER_WORDS_HIDDEN_SHORT or d.text, 1, 1, 1, true) end
				tt:AddLine(L.DECREE_BY:format(d.sender, d.guild, ns.Ago(d.t)), 0.7, 0.7, 0.7)
			end,
		}
		if d.text ~= "" and veiled then
			lines[#lines + 1] = { indent = 1, text = Grey(L.FILTER_WORDS_HIDDEN), onClick = function()
				d.revealed = true
				if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
			end }
		elseif d.text ~= "" then
			lines[#lines + 1] = { indent = 1, text = Grey('"' .. d.text .. '"') }
		end
	end
	-- 1.1 (#31): a Vox Populi question the player's block terms hid, while it is open.
	local vox = ns.Vox and ns.Vox.HiddenQuestion and ns.Vox.HiddenQuestion()
	if vox then
		Views.GreyRows(lines, L.FILTER_VOX_HIDDEN, { onClick = function() ns.Vox.Reveal() end })
	end

	return lines
end

local function DecreeHelp(lines)
	lines[#lines + 1] = { header = true, text = L.DECREE_HELP_TITLE }
	for _, k in ipairs({ "ARMS", "MUSTER", "ROYAL", "HERALDRY" }) do
		local who = ns.Decree.CROWN_ONLY[k] and L.WHO_CROWN or L.WHO_CAPTAINS
		lines[#lines + 1] = { text = Gold(L["HELP_" .. k .. "_NAME"]) .. "  " .. Grey("(" .. who .. ")") }
		lines[#lines + 1] = { indent = 1, text = Grey(L["HELP_" .. k]) }
	end
end

-- The alerts' settings (1.1), at the bottom of the Decrees tab: held in an instance or on Busy,
-- or not; the alert sounds, the switch for all on the heading and one line per kind below. A
-- click turns one on or off (the same as /syl alerts, /syl sound [kind] on|off; with the gamepad
-- UI too: a click on a row, no text box, no popup).
local function SoundLines(lines)
	local all = ns.db.sound and true or false
	lines[#lines].gapAfter = true
	-- In an instance or on Busy: alerts held (the default) or shown (1.1, /syl alerts quiet|always).
	local always = ns.db.alertsAlways and true or false
	lines[#lines + 1] = {
		header = true,
		text = L.ALERTS_LINE,
		right = always and Gold(L.ALERTS_SHOWN) or Green(L.ALERTS_HELD),
		alerts = true, -- (tests)
		onClick = function() ns.AlertsSlash(always and "quiet" or "always") end,
		tooltip = function(tt)
			tt:AddLine(L.ALERTS_LINE, 1, 0.82, 0)
			tt:AddLine(L.ALERTS_TIP, 1, 1, 1, true)
		end,
		gapAfter = true,
	}
	lines[#lines + 1] = {
		header = true,
		text = L.SOUNDS_TITLE,
		right = all and Green(L.SOUND_ALL_ON) or Red(L.SOUND_ALL_OFF),
		onClick = function() ns.SoundSlash(all and "off" or "on") end,
		tooltip = function(tt)
			tt:AddLine(L.SOUNDS_TITLE, 1, 0.82, 0)
			tt:AddLine(L.SOUNDS_TIP, 1, 1, 1, true)
		end,
	}
	for _, kind in ipairs(ns.SOUND_KINDS) do
		local on = ns.SoundKindOn(kind)
		local state = on and (all and Green(L.SOUND_ON) or Grey(L.SOUND_ON)) or Red(L.SOUND_OFF)
		lines[#lines + 1] = {
			text = (all and "" or "|cff9d9d9d") .. ns.SoundLabel(kind) .. (all and "" or "|r") .. "  " .. Grey("(" .. kind .. ")"),
			right = state,
			sound = kind, -- (tests)
			onClick = function() ns.SoundSlash(kind .. (on and " off" or " on")) end,
			tooltip = function(tt)
				tt:AddLine(ns.SoundLabel(kind), 1, 0.82, 0)
				tt:AddLine(L.SOUND_KIND_TIP:format(kind), 1, 1, 1, true)
				if not all then tt:AddLine(L.SOUNDS_OFF, 1, 0.25, 0.25, true) end
			end,
		}
	end
end

local function DecreeDetail()
	local who
	if ns.IsCrown() then who = L.YOU_ARE_CROWN
	elseif ns.Roster.IsOfficer() then who = L.YOU_ARE_OFFICER
	else who = L.YOU_ARE_SOLDIER end
	return L.DECREES_DETAIL_TITLE, who
end

---------------------------------------------------------------------------
-- Heraldry (tabard inspection + Wall of Shame)
---------------------------------------------------------------------------

local STATUS_TEXT = {
	GUILD = function() return Green(L.TABARD_OK) end,
	NONE = function() return Red(L.TABARD_NONE) end,
	OTHER = function() return Gold(L.TABARD_OTHER) end,
	UNKNOWN = function() return Grey(L.TABARD_UNKNOWN) end,
	UNCHECKED = function() return Grey(L.TABARD_UNCHECKED) end,
	YOUNG = function() return Grey(L.TABARD_YOUNG) end,
}

Views.RACE_MAX, Views.RACE_PAGE = 100, 25 -- the level race: its top 100, 25 at a time
Views.RECRUIT_SHOWN = 5 -- guilds with room shown in the Realm's Recruiting, the rest on a click (1.1)
Views.raceShown = Views.RACE_PAGE
Views.INSPECT_ROWS = 200 -- inspected players listed on the Tabards page

-- 1.1 (request #28): the gear an officer's click kept (Inspect.InspectGear), newest first, the
-- players whose name or guild holds `q`: a click shows or hides the items, in their slots, each
-- with its own tooltip. Nothing added up, scored or compared. False when none shows.
Views.GEAR_ROWS = 50
local gearOpen = {}
local function GearLines(lines, q)
	local shown = {}
	for _, g in ipairs(ns.Inspect.GearList and ns.Inspect.GearList() or {}) do
		if not q or ns.Holds(q, ns.ShortName(g.name), g.guild) then shown[#shown + 1] = g end
	end
	if #shown == 0 then return false end
	lines[#lines + 1] = { header = true, text = L.GEAR_TITLE, right = Grey(tostring(#shown)) }
	for i = 1, math.min(#shown, Views.GEAR_ROWS) do
		local g = shown[i]
		local open = gearOpen[g.name] == true
		local n = 0
		for _ in pairs(g.items) do n = n + 1 end
		lines[#lines + 1] = {
			indent = 1, key = g.name,
			text = (open and "[-] " or "[+] ") .. ClassColored(ns.ShortName(g.name), g.class) .. "  " .. Grey("<" .. (g.guild or "?") .. ">"),
			right = Grey(L.GEAR_ITEMS:format(n) .. "  " .. ns.Ago(g.t)),
			onClick = function()
				gearOpen[g.name] = not open or nil
				if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
			end,
			tooltip = function(tt)
				tt:AddLine(ClassColored(g.name, g.class))
				tt:AddLine(L.GEAR_ROW_TIP:format(ns.ShortName(g.name), date("%Y-%m-%d %H:%M", g.t)), 1, 1, 1, true)
			end,
		}
		if open then
			local items = {}
			for slot = 1, 19 do
				local it = g.items[slot]
				local id = type(it) == "string" and tonumber(it:match("^item:(%d+)")) or nil
				if id then
					-- The game's link for it, once the client knows the item (its enchant and suffix kept).
					local link
					if GetItemInfo then
						local ok, _, l = pcall(GetItemInfo, it)
						if ok and type(l) == "string" then link = l end
					end
					items[#items + 1] = { id = id, link = link, s = slot }
				end
			end
			lines[#lines + 1] = { indent = 2, items = items, slots = 19 }
		end
	end
	if #shown > Views.GEAR_ROWS then lines[#lines + 1] = { indent = 1, text = Grey(L.AND_MORE:format(#shown - Views.GEAR_ROWS)) } end
	lines[#lines].gapAfter = true
	return true
end
function Views.CloseGear() wipe(gearOpen) end -- (tests)

-- `q`, the search (Views.Query): the untabarded and the inspected players whose name or guild
-- holds it, each list under its header, a page as ever; "No match" for none. Nothing else.
local function HeraldryLines(q)
	local s = ns.Inspect.Summary()
	-- The King (and his Hands): the Royal Inspection, and what the patrols reported (King.lua).
	local lines = {}
	for _, l in ipairs(not q and ns.King and ns.King.InspectionLines and ns.King.InspectionLines() or {}) do lines[#lines + 1] = l end
	-- The untabarded: the King sees his own list (and whether the army sees it); everyone else
	-- sees it only while he shares it.
	local king = ns.King and (ns.King.IsKing() or ns.King.Preview())
	local shame = ns.Inspect.Shame()
	if king then
		shame = { list = ns.Inspect.ShameList(), mine = true }
	end
	local players = s.players
	if q then
		local list = {}
		for _, p in ipairs(ns.Inspect.ShameOpen() and shame and shame.list or {}) do
			if ns.Holds(q, p.name, p.guild) then list[#list + 1] = p end
		end
		-- (Only a list with someone found in it, headed as ever.)
		shame = #list > 0 and { list = list, mine = shame.mine, by = shame.by, t = shame.t } or nil
		players = {}
		for _, p in ipairs(s.players) do
			if ns.Holds(q, ns.ShortName(p.name), p.guild) then players[#players + 1] = p end
		end
		if not shame and #players == 0 and not GearLines({}, q) then return { NoMatch() } end
	end
	if q and not shame then
		-- (The search found none of the untabarded: their header goes too.)
	elseif not ns.Inspect.ShameOpen() then
		-- Closed until the tabard rule is in force (Inspect.lua): a countdown.
		local left = ns.Inspect.ShameOpensIn()
		local wait = ("%dh %02dm"):format(math.floor(left / 3600), math.floor(left % 3600 / 60))
		lines[#lines + 1] = { header = true, text = Red(L.WALL_OF_SHAME), right = Grey(L.SHAME_OPENS:format(wait)) }
		lines[#lines].gapAfter = true
	elseif not (shame and #shame.list > 0) then
		lines[#lines + 1] = { header = true, text = Red(L.WALL_OF_SHAME), right = Grey(king and L.SHAME_EMPTY or L.UNTABARDED_NOT_SHARED) }
		lines[#lines].gapAfter = true
	else
		local right = shame.mine and (ns.King.SharingUntabarded() and L.UNTABARDED_SHARED or L.UNTABARDED_ONLY_KING)
			or L.PUBLISHED_BY:format(shame.by, ns.Ago(shame.t))
		lines[#lines + 1] = { header = true, text = Red(L.WALL_OF_SHAME), right = Grey(right) }
		-- The King pardons with a click (Acts.lua); anyone else opens the person.
		for i = 1, math.min(12, #shame.list) do
			local p = shame.list[i]
			local pardon = king and ns.King.CleanName(p.name) ~= nil
			lines[#lines + 1] = { indent = 1, key = p.name, text = p.name .. "  " .. Grey("<" .. (p.guild or "?") .. ">"),
				onClick = pardon and function() ns.ShowDialog("SYLVANISTAS_PARDON", p.name, nil, p.name) end
					or function() ns.UI.ShowPerson({ name = p.name, guild = p.guild }) end,
				tooltip = pardon and function(tt)
					tt:AddLine(p.name, 1, 0.82, 0)
					tt:AddLine(L.PARDON_TIP, 1, 1, 1, true)
				end or nil }
		end
		if #shame.list > 12 then lines[#lines + 1] = { indent = 1, text = Grey(L.AND_MORE:format(#shame.list - 12)) } end
		lines[#lines].gapAfter = true
	end
	if not q then
		lines[#lines + 1] = { header = true, text = L.GUILDS }
		for i = 1, math.min(8, #s.guilds) do
			local g = s.guilds[i]
			lines[#lines + 1] = {
				text = (g.marked and Red("! ") or "") .. Green("<" .. g.name .. ">"),
				right = L.GUILD_BAD:format(g.bad, g.total),
				onClick = function() ns.Inspect.ToggleGuildMark(g.name) end,
				tooltip = function(tt) tt:AddLine("<" .. g.name .. ">", 0.25, 1, 0.25); tt:AddLine(L.CLICK_MARK_GUILD, 0.8, 0.8, 0.8) end,
			}
		end
		if #s.guilds == 0 then lines[#lines + 1] = { text = Grey(L.INSPECT_EMPTY) } end
		lines[#lines].gapAfter = true
	end
	-- 1.1: the gear officers' clicks kept.
	GearLines(lines, q)
	if q and #players == 0 then return lines end
	lines[#lines + 1] = { header = true, text = L.INSPECTED_PLAYERS }
	-- A line (and a frame) each: the first INSPECT_ROWS, marked and caught players first
	-- (Inspect.Summary), the rest counted.
	local rows = math.min(#players, Views.INSPECT_ROWS)
	for i = 1, rows do
		local p = players[i]
		lines[#lines + 1] = {
			key = p.name,
			cols = {
				(p.marked and Red("! ") or "") .. ClassColored(ns.ShortName(p.name), p.class),
				Grey(p.guild and ("<" .. p.guild .. ">") or ""),
				(STATUS_TEXT[p.status or "UNKNOWN"] or STATUS_TEXT.UNKNOWN)(),
				Grey(ns.Ago(p.t)),
			},
			onClick = function()
				local code = ns.Roster.ClassCode(p.class)
				ns.UI.ShowPerson({
					name = ns.ShortName(p.name), realm = ns.RealmOf(p.name), class = code ~= "" and code or nil, level = p.level, guild = p.guild,
					tabard = (STATUS_TEXT[p.status or "UNKNOWN"] or STATUS_TEXT.UNKNOWN)(), note = p.note,
					onMark = function() ns.Inspect.ToggleMark(p.name) end,
				})
			end,
			tooltip = function(tt)
				tt:AddLine(ClassColored(p.name, p.class))
				tt:AddLine("<" .. (p.guild or "?") .. ">" .. (p.level and ("  lvl " .. p.level) or ""), 0.25, 1, 0.25)
				if p.note then tt:AddLine('"' .. p.note .. '"', 1, 0.5, 0.5, true) end
				-- 1.1 (request #29): another officer of our guild found it.
				if p.shared and p.by then tt:AddLine(L.PATROLSHARE_BY:format(p.by), 0.6, 0.8, 1, true) end
				tt:AddLine(L.CLICK_MARK_PLAYER, 0.6, 0.6, 0.6)
			end,
		}
	end
	if #players > rows then lines[#lines + 1] = { text = Grey(L.AND_MORE:format(#players - rows)) } end
	return lines
end

local function HeraldryDetail()
	local s = ns.Inspect.Summary()
	local c = s.counts
	local text = ns.Inspect.IsPatrolling() and Green(L.PATROL_ON) or Grey(L.PATROL_HINT)
	-- 1.1 (request #29): how many on the list our guild's other officers found.
	local shared = ns.Inspect.SharedCount and ns.Inspect.SharedCount() or 0
	if shared > 0 then text = text .. "\n" .. Grey(L.PATROLSHARE_COUNT:format(shared)) end
	return L.INSPECT_COUNTS:format(s.total, c.GUILD, c.NONE, c.OTHER), text
end

---------------------------------------------------------------------------
-- Join Sylvanistas (what non-members see)
---------------------------------------------------------------------------

-- 1.1: a guild of Sylvanistas whose name the rule leaves out counts once the author's signed
-- list names it (ns.IsApprovedGuild): its first member pastes that list, from this screen too.
local function ApprovedHint(lines)
	local guild = IsInGuild() and GetGuildInfo("player")
	if type(guild) ~= "string" or guild == "" then return lines end
	if lines[#lines] then lines[#lines].gapAfter = true end
	lines[#lines + 1] = {
		text = Grey(L.APPROVED_JOIN_HINT:format(Plain(guild))),
		onClick = function() ns.ShowDialog("SYLVANISTAS_APPROVED_PASTE") end,
		tooltip = function(tt)
			tt:AddLine(L.APPROVED_JOIN_HINT:format(Plain(guild)), 1, 0.82, 0, true)
			tt:AddLine(L.APPROVED_PASTE_PROMPT, 1, 1, 1, true)
		end,
	}
	return lines
end

function Views.RecruitLines()
	local R = ns.Recruit
	local lines = { { header = true, text = L.RECRUIT_TITLE } }
	local guilds = R.Guilds()
	if #guilds == 0 then
		lines[#lines + 1] = { text = Grey(#R.found == 0 and not ns.Who.Searched() and L.RECRUIT_START or L.RECRUIT_NONE_FOUND) }
		return ApprovedHint(lines)
	end
	-- "Showing 50 of 312 online", and which levels the next click searches.
	WhoStatus(lines)
	if #lines > 1 then lines[#lines].gapAfter = true end
	-- Where to go (1.1, request #20): what a member's census said (Recruit.Route), the King's gates
	-- first (two answers agree on them), then the most free slots of the guilds /who found; a
	-- click asks one of that guild's officers /who found online.
	local route = R.Route()
	if route and #R.RouteOrder(route) > 0 then
		lines[#lines + 1] = {
			header = true, text = L.RECRUIT_ROUTE_TITLE,
			tooltip = function(tt)
				tt:AddLine(L.RECRUIT_ROUTE_TITLE, 1, 0.82, 0)
				tt:AddLine(L.RECRUIT_ROUTE_TIP:format(ns.DisplayName(route.from) or "?"), 1, 1, 1, true)
			end,
		}
		for _, name in ipairs(R.RouteOrder(route)) do
			local e = route.byName[name]
			local gates = name == route.gates
			lines[#lines + 1] = {
				text = (gates and CROWN or "") .. Green("<" .. Plain(name) .. ">") .. (gates and ("  " .. Gold(L.RECRUIT_GATES)) or ""),
				right = (e and Grey(L.FREE_SLOTS:format(ns.FormatNumber(e.free))) .. "  " or "") .. Gold(L.RECRUIT_ASK),
				onClick = function() R.PromptNext(name) end,
				tooltip = function(tt)
					tt:AddLine("<" .. Plain(name) .. ">", 0.25, 1, 0.25)
					if gates then tt:AddLine(L.RECRUIT_GATES_TIP, 1, 1, 1, true) end
					tt:AddLine(L.RECRUIT_ROUTE_ASK_TIP, 1, 1, 1, true)
				end,
			}
		end
		lines[#lines].gapAfter = true
	end
	for _, g in ipairs(guilds) do
		lines[#lines + 1] = {
			text = (g.gates and CROWN or "") .. Green("<" .. g.name .. ">"),
			right = Grey(L.RECRUIT_ONLINE:format(#g.members)) .. (g.free and ("  " .. Grey(L.FREE_SLOTS:format(ns.FormatNumber(g.free)))) or "")
				.. "  " .. Gold(L.RECRUIT_ASK),
			onClick = function() R.PromptNext(g.name) end,
			tooltip = function(tt)
				tt:AddLine("<" .. g.name .. ">", 0.25, 1, 0.25)
				tt:AddLine(L.RECRUIT_ASK_TIP, 1, 1, 1, true)
			end,
		}
		for _, p in ipairs(g.members) do
			local state = ""
			local closed = R.NoContact(p.name)
			if closed then state = Grey(L.RECRUIT_STATE_DNC)
			elseif R.replied[p.name] then state = Green(L.RECRUIT_STATE_REPLIED)
			elseif R.asked[p.name] then state = Grey(L.RECRUIT_STATE_ASKED) end
			lines[#lines + 1] = {
				indent = 1,
				text = ClassColored(ns.ShortName(p.name), p.class) .. "  " .. Grey((p.level and L.LEVEL_N:format(p.level) or "") .. (p.zone and ("  " .. p.zone) or "")),
				right = state,
				-- (Not one who asked not to be contacted, 1.1.)
				onClick = not closed and function() R.Prompt(p) end or nil,
				tooltip = R.replied[p.name] and function(tt)
					tt:AddLine(ns.ShortName(p.name), 1, 0.82, 0)
					-- (A whisper: its links stay, like a chat line's; no other escape code, 0.9.2.)
					tt:AddLine('"' .. ns.Codec.SanitizeChat(R.replied[p.name]) .. '"', 1, 1, 1, true)
				end or nil,
			}
		end
		lines[#lines].gapAfter = true
	end
	return ApprovedHint(lines)
end

---------------------------------------------------------------------------
-- Entry point used by UI.lua
---------------------------------------------------------------------------

-- The search box on top of a list (1.0.0).
local function Searched(lines, tab, tip)
	table.insert(lines, 1, SearchLine(tab, tip))
	return lines
end

-- Each tab's lines, detail title and detail text. A tab missing here (a new one being
-- added) is an empty list.
local BUILD = {
	census = function(s)
		local title, text = CensusDetail(s)
		return Searched(CensusLines(s, Views.Query("census")), "census", "CENSUS"), title, text
	end,
	realm = function(s)
		local title, text = RealmDetail(s)
		local lines = RealmLines(s, Views.Query("realm"))
		-- (One box for the tab: a page's lines are searched with it while it shows.)
		local members = ns.Members and ns.Members.Shown and ns.Members.Shown()
		local page = pageShown and RealmPage(pageShown)
		return Searched(lines, "realm", boardShown and "BOARD" or (page and page.tip) or members and "MEMBERS" or "REALM"), title, text
	end,
	decrees = function()
		local title, text = DecreeDetail()
		local lines = DecreeLines()
		-- 1.1 (#12): this client's log of the acts it saw, its box searching it alone.
		if ns.Chronicle and not ns.Chronicle.missing then ns.Chronicle.AddLines(lines, Views.Query("decrees")) end
		DecreeHelp(lines)
		SoundLines(lines)
		return Searched(lines, "decrees", "LOG"), title, text
	end,
	heraldry = function()
		local title, text = HeraldryDetail()
		return Searched(HeraldryLines(Views.Query("heraldry")), "heraldry", "HERALDRY"), title, text
	end,
	throne = function(s)
		if not (ns.King and ns.King.Build) then return {}, nil, nil end
		local lines, title, text = ns.King.Build(s)
		return lines or {}, title, text
	end,
	vox = function()
		if not (ns.Vox and ns.Vox.Build) then return {}, nil, nil end
		local lines, title, text = ns.Vox.Build()
		return lines or {}, title, text
	end,
	-- (The box where a list of donors shows: the ranking, the book. Without it, nothing typed
	-- earlier filters what shows.)
	treasury = function()
		if not (ns.Treasury and ns.Treasury.Build) then return {}, nil, nil end
		local searched = ns.Treasury.Searchable and ns.Treasury.Searchable()
		local lines, title, text = ns.Treasury.Build(searched and Views.Query("treasury") or nil)
		lines = lines or {}
		if searched then Searched(lines, "treasury", "TREASURY") end
		return lines, title, text
	end,
	workshop = function()
		if not (ns.Workshop and ns.Workshop.Build) then return {}, nil, nil end
		local lines, title, text = ns.Workshop.Build()
		return lines or {}, title, text
	end,
	-- 1.1.1: the Chat tab. ChatWindow.lua draws it over this list; on a client updated without a
	-- restart (no ChatWindow.lua yet), the list says what to do.
	chat = function()
		local CW = ns.ChatWindow
		if type(CW) ~= "table" or CW.missing then return { { text = Grey(L.RESTART_NEEDED) } }, nil, nil end
		return {}, nil, nil
	end,
}

function Views.Build(tab)
	local build = BUILD[tab]
	if not build then return {}, nil, nil end
	return build(ns.Data.Summary())
end

-- Kept for the tests: the Realm tree lines.
function Views.RealmLines() return RealmLines(ns.Data.Summary()) end
