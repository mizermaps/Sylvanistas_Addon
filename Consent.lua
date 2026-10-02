local ADDON, ns = ...
local L = ns.L

-- The first-open page (1.1, Fern's #11): one page, in plain words, of what leaves this client,
-- and the first question the addon asks: after login (LOGIN_WAIT, then on the minute until it
-- could), or when the Sylvanistas window opens first, never in combat or an instance, once a session,
-- while a line waits for its answer. The 1.0 questions (the zone and layer's, a keeper's) open
-- this page instead of their popups (Layers.AskChoice, Treasury.AskConsent); their popups stay
-- for a client without this file (updated without a restart) and a keeper outside a guild.
-- It has a Yes and a No for each thing the addon would otherwise share or show on its own: the
-- zone and layer, layer help, a treasury keeper's book (keepers only), the Royal Inspection, the
-- author's roll call, the Sylvanistas chats and an officer's patrol findings (officers only). Each
-- stays off until its Yes: nil, never answered, is off (Layers.Sharing, Hop.Helps,
-- Treasury.Consent, King's OnInspect, Workshop.Answers, Channels.ChatOn, Inspect.Sharing).
-- The page also says what always goes out while the player is in a Sylvanistas
-- guild (the census the elected member sends, names included, and the hello), so it never
-- promises that nothing does. The window works whatever the answers: the census, the Realm and
-- the player's own guild roster need none of them, location included.
-- `/syl privacy` opens it again to change any answer; each answer also has its own command.
-- Sylvanistas's own frame, never the game's popup: with Blizzard's gamepad UI the game's popups break
-- when an addon opens one (Dialog.lua). It has no edit box (nothing takes the keyboard), and it
-- goes on the escape list only with mouse and keyboard (ns.EscapeCloses). Escape, the X or Done
-- closes it with the unanswered left off; nothing on it is answered for the player.
-- The one place such a choice lives: later features that share something on their own (a group
-- board's raised flag, a camp pin...) add their line here with Consent.Register:
--   Consent.Register({ key = "camp", label = "L key or text", text = "L key, text or function",
--     shown = function() return true end, get = function() return true|false|nil end,
--     set = function(on) ... end, note = function() return "a line under it" or nil end,
--     pending = function() return true while it waits for an answer end })
-- (`get` is what goes out now, shown on the line; `pending`, when given, says whether the line
-- still waits for the player's answer: by default, while `get` is nil.)

local Consent = {}
ns.Consent = Consent

Consent.WIDTH = 600
Consent.LOGIN_WAIT = 45 -- after login (the realm key and the channel settle first)

local items, byKey = {}, {}
local asked = {}   -- [key] = true: on the page this session (asked once a session)
local frame

local function Text(v)
	if type(v) == "function" then
		local ok, res = pcall(v)
		return ok and type(res) == "string" and res or ""
	end
	if type(v) ~= "string" then return "" end
	local s = rawget(L, v)
	return type(s) == "string" and s or v
end

-- A line of its own on the page. False when the key is taken or the item is not whole.
function Consent.Register(item)
	if type(item) ~= "table" or type(item.key) ~= "string" or byKey[item.key] then return false end
	if type(item.get) ~= "function" or type(item.set) ~= "function" then return false end
	items[#items + 1] = item
	byKey[item.key] = item
	if frame and frame:IsShown() then Consent.Refresh() end
	return true
end

local function Shown(item)
	if type(item.shown) ~= "function" then return true end
	local ok, yes = pcall(item.shown)
	return ok and yes == true
end

local function Get(item)
	local ok, v = pcall(item.get)
	if not ok or (v ~= true and v ~= false) then return nil end
	return v
end

-- Whether a line still waits for the player's answer.
local function Waits(item)
	if type(item.pending) ~= "function" then return Get(item) == nil end
	local ok, yes = pcall(item.pending)
	return ok and yes == true
end

-- The lines this player gets, in the page's order.
function Consent.Items()
	local out = {}
	for _, item in ipairs(items) do if Shown(item) then out[#out + 1] = item end end
	return out
end

-- An item's answer: true, false, or nil (never answered: off).
function Consent.Answer(key)
	local item = byKey[key]
	if not item then return nil end
	return Get(item)
end

-- The lines this player never answered.
function Consent.Pending()
	local out = {}
	for _, item in ipairs(Consent.Items()) do if Waits(item) then out[#out + 1] = item end end
	return out
end

local function Busy()
	return (InCombatLockdown and InCombatLockdown()) or (IsInInstance and IsInInstance()) and true or false
end

-- By itself, after login, when the window opens, when a 1.0 question would have been asked (the
-- zone and layer's, a keeper's) and when a player types in a chat still unanswered: only in an
-- Sylvanistas guild, never in combat or an instance, and only for lines not on the page yet this
-- session. True when it showed.
function Consent.Ask(reason)
	if not ns.IsMember() or Busy() then return false end
	local fresh = false
	for _, item in ipairs(Consent.Pending()) do
		if not asked[item.key] then fresh = true end
	end
	if not fresh or (frame and frame:IsShown()) then return false end
	ns.Log("privacy page shown (%s)", tostring(reason or "?"))
	Consent.Show()
	return true
end

-- The player's answer: the item's own switch (which says so in chat), then the page again.
function Consent.Choose(key, on)
	local item = byKey[key]
	if not item or not Shown(item) then return false end
	item.set(on and true or false)
	ns.Log("privacy: %s %s", key, on and "yes" or "no")
	Consent.Refresh()
	ns.Fire("CONSENT_CHANGED", key, on and true or false)
	return true
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

local function Height(fs, width)
	if fs.GetStringHeight then
		local h = fs:GetStringHeight()
		if type(h) == "number" and h > 0 then return h end
	end
	-- (No measure: about 6 pixels a letter, 14 a line.)
	local per = math.max(1, math.floor(width / 6))
	return math.ceil(#(fs:GetText() or "") / per) * 14
end

local function Button(parent, label, width)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width or 64, 20)
	b:SetText(label)
	return b
end

local function Row(i)
	local f = frame
	local r = f.rows[i]
	if r then return r end
	r = {}
	r.label = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	r.label:SetJustifyH("LEFT")
	r.state = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	r.state:SetJustifyH("RIGHT")
	r.text = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	r.text:SetJustifyH("LEFT")
	if r.text.SetWordWrap then r.text:SetWordWrap(true) end
	r.no = Button(f, L.CONSENT_NO)
	r.yes = Button(f, L.CONSENT_YES)
	r.yes:SetScript("OnClick", function() ns.SafeCall("privacy page", Consent.Choose, r.key, true) end)
	r.no:SetScript("OnClick", function() ns.SafeCall("privacy page", Consent.Choose, r.key, false) end)
	f.rows[i] = r
	return r
end

local function Make()
	local f = CreateFrame("Frame", "SylvanistasConsentFrame", UIParent)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	-- An opaque ground: the page is read line by line, and the plain dialog's lets the world show
	-- through. The client's opaque dialog (Forever's SharedXML has it), else its dark one, else a
	-- near-black texture; a template the client lacks leaves no Bg.
	local border
	for _, template in ipairs({ "DialogBorderOpaqueTemplate", "DialogBorderDarkTemplate" }) do
		local ok, b = pcall(CreateFrame, "Frame", nil, f, template)
		if ok and b and b.Bg then border = b break end
		if ok and b then b:Hide() end
	end
	if not border then
		border = f:CreateTexture(nil, "BACKGROUND")
		border:SetColorTexture(0.03, 0.03, 0.04, 0.97)
	end
	border:SetAllPoints()
	f.border = border
	f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	f.title:SetPoint("TOP", 0, -18)
	f.title:SetText(L.CONSENT_TITLE)
	f.intro = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	f.intro:SetJustifyH("LEFT")
	f.optional = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	f.optional:SetJustifyH("LEFT")
	f.footer = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	f.footer:SetJustifyH("LEFT")
	f.rows = {}
	f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	f.close:SetPoint("TOPRIGHT", -4, -4)
	f.close:SetScript("OnClick", function() f:Hide() end)
	f.done = Button(f, L.CONSENT_DONE, 120)
	f.done:SetScript("OnClick", function() f:Hide() end)
	-- An answer given elsewhere meanwhile (a slash command): the page follows, once a second.
	local elapsed = 0
	f:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + (dt or 0)
		if elapsed < 1 then return end
		elapsed = 0
		ns.SafeCall("privacy page", Consent.Refresh)
	end)
	-- Escape closes it with mouse and keyboard; with the gamepad UI its X and Done do (ns.EscapeCloses).
	ns.EscapeCloses("SylvanistasConsentFrame")
	f:HookScript("OnShow", function(self) ns.EscapeCloses(self:GetName()) end)
	f:Hide()
	return f
end

local function StateText(v)
	if v == true then return "|cff40ff40" .. L.CONSENT_STATE_YES .. "|r" end
	if v == false then return "|cffff4040" .. L.CONSENT_STATE_NO .. "|r" end
	return "|cff9d9d9d" .. L.CONSENT_STATE_NONE .. "|r"
end

-- Lays the page out again: its lines, each answer, the channel's audience.
function Consent.Refresh()
	local f = frame
	if not f then return end
	local W = Consent.WIDTH
	local inner = W - 40
	f:SetWidth(W)
	local y = -44
	f.intro:ClearAllPoints()
	f.intro:SetPoint("TOPLEFT", f, "TOPLEFT", 20, y)
	f.intro:SetWidth(inner)
	f.intro:SetText(L.CONSENT_INTRO:format(ns.Comm and ns.Comm.Audience and ns.Comm.Audience() or ""))
	y = y - Height(f.intro, inner) - 10
	f.optional:ClearAllPoints()
	f.optional:SetPoint("TOPLEFT", f, "TOPLEFT", 20, y)
	f.optional:SetWidth(inner)
	f.optional:SetText(L.CONSENT_OPTIONAL)
	y = y - Height(f.optional, inner) - 12
	local list = Consent.Items()
	for i, item in ipairs(list) do
		local r = Row(i)
		r.key = item.key
		local v = Get(item)
		r.label:ClearAllPoints()
		r.label:SetPoint("TOPLEFT", f, "TOPLEFT", 20, y)
		r.label:SetText(Text(item.label))
		r.no:ClearAllPoints()
		r.no:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, y + 3)
		r.yes:ClearAllPoints()
		r.yes:SetPoint("RIGHT", r.no, "LEFT", -6, 0)
		r.state:ClearAllPoints()
		r.state:SetPoint("RIGHT", r.yes, "LEFT", -10, 0)
		r.state:SetText(StateText(v))
		-- The answer given stays lit.
		if v == true then r.yes:LockHighlight() else r.yes:UnlockHighlight() end
		if v == false then r.no:LockHighlight() else r.no:UnlockHighlight() end
		local text = Text(item.text)
		local note = item.note and Text(item.note) or ""
		if note ~= "" then text = text .. " |cffffd200" .. note .. "|r" end
		r.text:ClearAllPoints()
		r.text:SetPoint("TOPLEFT", f, "TOPLEFT", 28, y - 20)
		r.text:SetWidth(inner - 8)
		r.text:SetText(text)
		for _, part in ipairs({ r.label, r.state, r.text, r.yes, r.no }) do part:Show() end
		y = y - 20 - Height(r.text, inner - 8) - 12
	end
	for i = #list + 1, #f.rows do
		local r = f.rows[i]
		r.key = nil
		for _, part in ipairs({ r.label, r.state, r.text, r.yes, r.no }) do part:Hide() end
	end
	f.footer:ClearAllPoints()
	f.footer:SetPoint("TOPLEFT", f, "TOPLEFT", 20, y)
	f.footer:SetWidth(inner)
	f.footer:SetText(L.CONSENT_FOOTER)
	y = y - Height(f.footer, inner) - 10
	f.done:ClearAllPoints()
	f.done:SetPoint("TOP", f, "TOP", 0, y)
	f:SetHeight(-y + 20 + 18)
end

-- The page, whatever was answered (/syl privacy, and Consent.Ask). Every line not answered yet
-- counts as asked for this session.
function Consent.Show()
	for _, item in ipairs(Consent.Pending()) do asked[item.key] = true end
	frame = frame or Make()
	Consent.Refresh()
	frame:Show()
	return frame
end

function Consent.Frame() return frame end
function Consent.Hide() if frame then frame:Hide() end end

-- Tests start from a clean state (and a fresh frame when the toolkit was rebuilt).
function Consent.Reset()
	wipe(asked)
	if frame and rawget(_G, "SylvanistasConsentFrame") ~= frame then frame = nil elseif frame then frame:Hide() end
end

---------------------------------------------------------------------------
-- The lines of 1.1
---------------------------------------------------------------------------

local function IsKing() return ns.King ~= nil and ns.King.IsKing ~= nil and ns.King.IsKing() == true end

-- The King's zone and layer are his crown on the Throne, and he is never asked for layer help.
Consent.Register({
	key = "location", label = "CONSENT_LOCATION", text = "CONSENT_LOCATION_TEXT",
	shown = function() return not IsKing() end,
	get = function() return ns.db.shareLocation end,
	set = function(on) ns.Layers.SetSharing(on) end,
})
Consent.Register({
	key = "layerhelp", label = "CONSENT_LAYERHELP", text = "CONSENT_LAYERHELP_TEXT",
	shown = function() return not IsKing() end,
	get = function() return ns.db.layerHelp end,
	set = function(on) ns.Hop.SetHelp(on) end,
	note = function() return not ns.Layers.Sharing() and L.CONSENT_NEEDS_LOCATION or nil end,
})
-- A keeper's book. The line shows what goes out now (Treasury.Consent: the Treasurer's 0.9.3 yes
-- still sends his book, and the line says so), and waits for his answer to 1.0's question
-- (Treasury.ConsentAnswer), asked in 1.0's words: the Treasurer's character holding 0.9's book
-- is told that his yes also sends the early supporters' names to everyone on the channel
-- (Treasury.YesSendsEarly), as 1.0's question tells him (Konig's review of 1.0.0).
local function TreasuryHas(fn) return ns.Treasury ~= nil and type(ns.Treasury[fn]) == "function" end
Consent.Register({
	key = "treasurer", label = "CONSENT_TREASURER",
	text = function()
		local early = TreasuryHas("YesSendsEarly") and ns.Treasury.YesSendsEarly() == true
		return L.CONSENT_TREASURER_TEXT .. (early and (" " .. L.CONSENT_TREASURER_EARLY) or "")
	end,
	shown = function() return TreasuryHas("RealKeeper") and ns.Treasury.RealKeeper() == true end,
	get = function() return ns.Treasury.Consent() end,
	pending = function() return ns.Treasury.ConsentAnswer() == nil end,
	set = function(on) ns.Treasury.SetConsent(on) end,
	note = function()
		if ns.Treasury.ConsentAnswer() == nil and ns.Treasury.Consent() == true then return L.CONSENT_TREASURER_OLD_YES end
		return nil
	end,
})
Consent.Register({
	key = "inspection", label = "CONSENT_INSPECTION", text = "CONSENT_INSPECTION_TEXT",
	get = function() return ns.db.royalInspection end,
	set = function(on)
		ns.db.royalInspection = on
		ns.Print(on and L.INSPECTION_OPT_ON or L.INSPECTION_OPT_OFF)
	end,
})
Consent.Register({
	key = "rollcall", label = "CONSENT_ROLLCALL", text = "CONSENT_ROLLCALL_TEXT",
	get = function() return ns.db.rollCall end,
	set = function(on) ns.Workshop.SetAnswers(on) end,
})
Consent.Register({
	key = "chat", label = "CONSENT_CHAT", text = "CONSENT_CHAT_TEXT",
	get = function() return ns.db.addonChat end,
	set = function(on) ns.Channels.SetChatOn(on) end,
})
-- An officer's patrol findings to his guild's officers (Inspect.lua, Fern's #29): officers alone
-- send and keep them, so only they are asked (Konig's review of 1.1: it was on by default and
-- missing from this page).
Consent.Register({
	key = "patrolshare", label = "CONSENT_PATROLSHARE", text = "CONSENT_PATROLSHARE_TEXT",
	shown = function() return ns.IsMember() == true and ns.Roster.IsOfficer() == true end,
	get = function() return ns.db.patrolShare end,
	set = function(on) ns.Inspect.SetSharing(on) end,
})

-- The first question after login: the page, once the login settled, then on the minute until it
-- could be asked (combat, an instance), once a session (Consent.Ask).
function Consent.OnLogin()
	ns.After(Consent.LOGIN_WAIT, "privacy page", function() Consent.Ask("login") end)
	ns.Every(60, "privacy page", function() Consent.Ask("login") end)
end
ns.On("LOGIN", function() Consent.OnLogin() end)
