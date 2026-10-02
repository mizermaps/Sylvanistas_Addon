local ADDON, ns = ...
local L = ns.L

-- The answer bank in the game (1.1.2, the owner's ask): short answers to what players ask, mostly
-- why two players' counts differ, and what each feature is (AnswerBank.lua, made by
-- scripts/answers.lua from docs/answers.json).
-- * Answers (the author, the High Council and the Stewards: their existing checks): a button on the
--   Chat tab and in Sylvanistas's whisper windows opens a list of the bank's in-game lines by topic,
--   with a search. A click puts the line in that box, to edit and send as usual: nothing is sent
--   from here, and nothing takes the keyboard. Shift-click: the longer answer in the copy box, for
--   Discord.
-- * Each page's "?" (UI.lua's detail box, the Chat tab's top row): what the page shows, from the
--   bank, and where it counts, why the numbers can differ between players.
-- * A count's tooltip ends with "Why can this differ?" and the bank's line for it (Answers.WhyTip).
-- Everything here is read on this screen: nothing is sent, and the bank is the same for everyone.
-- The bank is in English (1.1.2's review): a game in another language gets no English line in its
-- tooltips (WhyTip adds none there), and its pages' "?" says first that what follows is English.

local Answers = {}
ns.Answers = Answers

local byId            -- [id] = entry, made on first use
local picker          -- the list's window, made on first use
local target          -- the box a pick goes into
local query = ""

local function Bank() return type(ns.ANSWER_BANK) == "table" and ns.ANSWER_BANK or { topics = {}, answers = {} } end
local function Trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

function Answers.Find(id)
	if not byId then
		byId = {}
		for _, a in ipairs(Bank().answers or {}) do byId[a.id] = a end
	end
	return byId[id]
end

-- Who has the Answers button: the author (and his test characters), the High Council, the Stewards.
function Answers.Allowed()
	local W = ns.Workshop
	if W and W.IsAuthor and (W.IsAuthor() == true or (W.Preview and W.Preview() == true)) then return true end
	return ns.IsHighCouncillor(ns.me) == true or ns.IsSteward(ns.me) == true
end

-- The bank's lines holding `q` (a question, the line, the longer answer or the topic, any case),
-- by topic: { { header = title } , entry, entry, { header = ... }, ... }.
function Answers.Entries(q)
	q = ns.Fold(Trim(q))
	local out = {}
	for _, t in ipairs(Bank().topics or {}) do
		local list = {}
		for _, a in ipairs(Bank().answers or {}) do
			if a.topic == t.id and (q == "" or ns.Holds(q, a.text, a.long, t.title, a.id, unpack(a.q or {}))) then list[#list + 1] = a end
		end
		if #list > 0 then
			out[#out + 1] = { header = t.title }
			for _, a in ipairs(list) do out[#out + 1] = a end
		end
	end
	return out
end

-- The game's language is English (the bank's).
function Answers.English()
	local locale = GetLocale and GetLocale() or "enUS"
	return locale == "enUS" or locale == "enGB"
end

-- The line into `box` (an edit box): in place of nothing, else after what is typed. False when that
-- box is gone (its window closed: Answers.Release let go of it, or it is hidden).
function Answers.Fill(box, text)
	if type(box) ~= "table" or not box.SetText or (box.IsVisible and not box:IsVisible()) then
		ns.Print(L.ANSWERS_BOX_GONE)
		return false
	end
	local have = Trim(box.GetText and box:GetText() or "")
	box:SetText(have == "" and text or (have .. " " .. text))
	return true
end

-- A line picked in the list: into the box it was opened for; Shift: the longer answer, to copy.
function Answers.Pick(entry, long)
	if type(entry) ~= "table" then return false end
	if long then
		if ns.UI and ns.UI.ShowCopy then ns.UI.ShowCopy(L.ANSWERS_COPY_TITLE, entry.long or entry.text) end
		return true
	end
	local ok = Answers.Fill(target, entry.text)
	if picker then picker:Hide() end
	return ok
end

---------------------------------------------------------------------------
-- The list's window
---------------------------------------------------------------------------

local W_WIDTH, W_HEIGHT = 440, 460
local ROW_H, HEAD_H = 50, 22

local function Row(p, i)
	local r = p.rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, p.content)
	r:SetHeight(ROW_H)
	r.q = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	r.q:SetPoint("TOPLEFT", r, "TOPLEFT", 6, -3)
	r.q:SetPoint("TOPRIGHT", r, "TOPRIGHT", -6, -3)
	r.q:SetJustifyH("LEFT")
	r.q:SetWordWrap(false)
	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.text:SetPoint("TOPLEFT", r.q, "BOTTOMLEFT", 0, -2)
	r.text:SetPoint("RIGHT", r, "RIGHT", -6, 0)
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(true)
	if r.text.SetMaxLines then r.text:SetMaxLines(2) end
	r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	r:SetScript("OnClick", function(self)
		if self.entry then ns.SafeCall("answers pick", Answers.Pick, self.entry, IsShiftKeyDown and IsShiftKeyDown()) end
	end)
	r:SetScript("OnEnter", function(self)
		if not self.entry then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(self.entry.q and self.entry.q[1] or "", 1, 0.82, 0, true)
		GameTooltip:AddLine(self.entry.text, 1, 1, 1, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(self.entry.long, 0.8, 0.8, 0.8, true)
		GameTooltip:AddLine(L.ANSWERS_ROW_TIP, 0.25, 1, 0.25, true)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	p.rows[i] = r
	return r
end

-- The list drawn for the search typed.
function Answers.Render()
	local p = picker
	if not p then return 0 end
	local list = Answers.Entries(query)
	local y, width, n = 0, (p.scroll:GetWidth() or (W_WIDTH - 44)), 0
	if width <= 0 then width = W_WIDTH - 44 end
	for i, e in ipairs(list) do
		local r = Row(p, i)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", p.content, "TOPLEFT", 0, -y)
		r:SetWidth(width)
		if e.header then
			r.entry = nil
			r:SetHeight(HEAD_H)
			r.q:SetText("|cffffd200" .. e.header .. "|r")
			r.text:SetText("")
			r:EnableMouse(false)
			y = y + HEAD_H
		else
			n = n + 1
			r.entry = e
			r:SetHeight(ROW_H)
			r.q:SetText("|cff9d9d9d" .. (e.q and e.q[1] or e.id) .. "|r")
			r.text:SetText(e.text)
			r:EnableMouse(true)
			y = y + ROW_H
		end
		r:Show()
	end
	for i = #list + 1, #p.rows do p.rows[i]:Hide(); p.rows[i].entry = nil end
	p.content:SetHeight(math.max(1, y))
	p.content:SetWidth(width)
	p.empty:SetShown(#list == 0)
	p.listed = list
	return n
end

local function Build()
	local f = CreateFrame("Frame", "SylvanistasAnswers", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(W_WIDTH, W_HEIGHT)
	f:SetPoint("CENTER", 240, 0)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	-- Its X hides it itself (the template's HideUIPanel does nothing in combat for our call).
	f.onCloseCallback = function()
		f:Hide()
		return false
	end
	if f.TitleText then f.TitleText:SetText(L.ANSWERS_TITLE) end
	f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.label:SetPoint("TOPLEFT", 14, -34)
	f.label:SetText(L.SEARCH)
	local ok, sb = pcall(CreateFrame, "EditBox", "SylvanistasAnswersSearch", f, "InputBoxTemplate")
	if not ok or not sb then sb = CreateFrame("EditBox", "SylvanistasAnswersSearch", f) end
	sb:SetAutoFocus(false) -- (a click into it: never the keyboard by itself)
	sb.sylvanistasBox = true
	sb:SetHeight(20)
	sb:SetMaxLetters(40)
	sb:SetFontObject("ChatFontNormal")
	sb:SetPoint("TOPLEFT", f.label, "TOPRIGHT", 10, 4)
	sb:SetPoint("RIGHT", f, "RIGHT", -16, 0)
	sb:SetScript("OnTextChanged", function(self)
		query = self:GetText() or ""
		ns.SafeCall("answers search", Answers.Render)
	end)
	sb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	sb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	f.search = sb
	f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.hint:SetPoint("TOPLEFT", 14, -58)
	f.hint:SetPoint("TOPRIGHT", -14, -58)
	f.hint:SetJustifyH("LEFT")
	f.hint:SetWordWrap(true)
	f.hint:SetText(L.ANSWERS_HINT)
	local scroll = CreateFrame("ScrollFrame", "SylvanistasAnswersScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -86)
	scroll:SetPoint("BOTTOMRIGHT", -32, 12)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(W_WIDTH - 44, 10)
	scroll:SetScrollChild(content)
	f.scroll, f.content, f.rows = scroll, content, {}
	f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.empty:SetPoint("TOP", scroll, "TOP", 0, -12)
	f.empty:SetText(L.SEARCH_NO_MATCH)
	f.empty:Hide()
	f:SetScript("OnHide", function(self) self.search:ClearFocus() end)
	return f
end

-- The list, for `box`: the Chat tab's box, or a whisper window's. Allowed roles only.
function Answers.Open(box)
	if not Answers.Allowed() then return nil end
	target = box
	picker = picker or Build()
	ns.EscapeCloses("SylvanistasAnswers")
	picker:Show()
	Answers.Render()
	return picker
end
function Answers.Picker() return picker end -- (tests)
function Answers.Target() return target end

-- A whisper window closed (UI.lua): the list it opened lets go of its box. Sylvanistas's windows reuse
-- their boxes (Dialog.lua), and a pick must never land in the next one's (a pin, an amount).
function Answers.Release(box)
	if box == nil or target ~= box then return false end
	target = nil
	if picker and picker:IsShown() then picker:Hide() end
	return true
end

---------------------------------------------------------------------------
-- Explanations: each page's "?", and a count's "why"
---------------------------------------------------------------------------

-- The page (UI.PageId: "tab/sub") -> the features it shows (the bank's ids), and `counts`: why its
-- numbers can differ. A page missing here takes its tab's ("realm/tree" -> "realm").
Answers.PAGES = {
	join = { "feat-join-screen", "feat-who-can-use", "feat-join-requests" },
	census = { "feat-census-list", "feat-header-totals", "feat-where-army-stands", "feat-marked-rows", "feat-census-search",
		"feat-tonight", "feat-grey-who-refresh", "feat-rebuilding", "feat-update-line", "feat-copy-discord",
		counts = { "count-not-a-bug", "count-differs-from-friend", "count-own-guild-live", "count-keeps-changing",
			"count-after-relog", "count-columns-dont-add-up", "count-guild-number", "count-grey-rows", "count-map-zones",
			"count-army-lower", "count-vs-blizzard", "count-missing-guilds-channel", "count-realm-faction", "count-old-version" } },
	realm = { "feat-realm-tree", "feat-members-online", "feat-ranks-level-race", "feat-recruiting-gates", "feat-layer-hop",
		"feat-person-card", "feat-high-council", "feat-pinned-line", "feat-public-channel", "rc-see-version",
		counts = { "count-realm-online-now", "count-other-guild-seen-online", "count-own-guild-live", "count-layer-sample" } },
	["realm/board"] = { "feat-board", "feat-signups" },
	["realm/loot"] = { "feat-loot-notes" },
	["realm/crafters"] = { "feat-crafters" },
	["realm/members"] = { "feat-inactive", counts = { "count-realm-online-now" } },
	["realm/members:recruits"] = { "feat-mentors" },
	chat = { "feat-chat-tab", "feat-chat-settings", "feat-channels", "feat-sylvanistas-tab", "feat-chat-off", "feat-block-terms" },
	decrees = { "feat-decrees", "feat-alert-sounds", "feat-writs", "feat-net-off", "feat-acts-log" },
	heraldry = { "feat-patrol", "feat-gear-seen", "feat-patrolshare", "feat-untabarded" },
	throne = { "feat-throne", "feat-agenda", "feat-summon-lords", "feat-hold-court", "feat-royal-inspection", "feat-steward-hands" },
	["throne/hands"] = { "feat-steward-hands" },
	vox = { "feat-vox" },
	treasury = { "feat-treasury", "feat-guild-bank", "feat-treasury-requests", "feat-sister-banks", "feat-donations", "feat-backup",
		counts = { "count-treasury-donors" } },
	["treasury/dues"] = { "feat-dues", "feat-treasury", counts = { "count-treasury-donors" } },
	workshop = { "feat-workshop", "rc-see-version", "rc-bug-report-ask", "help-report-bug" },
}

-- The page's entry, and its tab ("realm/members:7" -> "realm/members", then "realm").
function Answers.PageOf(page)
	page = tostring(page or "")
	local tab = page:match("^([^/]+)") or page
	for _, key in ipairs({ page, page:match("^(.-):") or "", (page:gsub("/$", "")), tab }) do
		if key ~= "" and Answers.PAGES[key] then return Answers.PAGES[key], tab end
	end
	return nil, tab
end

local function TabLabel(tab)
	if tab == "join" then return L.MEMBERS_ONLY end
	local label = rawget(L, "TAB_" .. tostring(tab):upper())
	return label or L.TITLE
end

-- The "?" text of a page: its features, then why its counts can differ, from the bank.
function Answers.ExplainText(page)
	local def, tab = Answers.PageOf(page)
	if not def then return nil end
	local out = {}
	if not Answers.English() then
		out[1] = L.PAGE_HELP_ENGLISH
		out[2] = ""
	end
	for _, id in ipairs(def) do
		local e = Answers.Find(id)
		if e then
			out[#out + 1] = "- " .. e.long
		end
	end
	if def.counts then
		out[#out + 1] = ""
		out[#out + 1] = L.WHY_DIFFER
		for _, id in ipairs(def.counts) do
			local e = Answers.Find(id)
			if e then out[#out + 1] = "- " .. e.long end
		end
	end
	out[#out + 1] = ""
	out[#out + 1] = L.PAGE_HELP_MORE
	return table.concat(out, "\n"), TabLabel(tab)
end

function Answers.ExplainPage(page)
	local text, label = Answers.ExplainText(page)
	if not text or not (ns.UI and ns.UI.ShowCopy) then return false end
	ns.UI.ShowCopy(L.PAGE_HELP_TITLE:format(label), text)
	return true
end

-- A count's tooltip: a gap, "Why can this differ?" and the bank's line of each id given.
function Answers.WhyTip(tt, ...)
	if type(tt) ~= "table" or not tt.AddLine or not Answers.English() then return false end
	local texts = {}
	for i = 1, select("#", ...) do
		local e = Answers.Find(select(i, ...))
		if e then texts[#texts + 1] = e.text end
	end
	if #texts == 0 then return false end
	tt:AddLine(" ")
	tt:AddLine(L.WHY_DIFFER, 1, 0.82, 0)
	for _, t in ipairs(texts) do tt:AddLine(t, 0.8, 0.8, 0.8, true) end
	return true
end

function Answers.Reset() -- (tests: the window made again with the toolkit then in use)
	if picker then picker:Hide() end
	picker, target, query, byId = nil, nil, "", nil
end
