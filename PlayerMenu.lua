local ADDON, ns = ...
local L = ns.L

-- Sylvanistas's lines in the game's right-click menus for a player (1.1.2): the target frame, party
-- and raid frames, a name in chat, the Who list, the friends list, the guild roster and the chat
-- channel roster. One place for every feature that adds a line there: Versions.lua (the player's
-- Sylvanistas version, Ask to update, Check version, Tell them about Sylvanistas) and Workshop.lua (the
-- author's Ask for a bug report) today; 1.2's arena and Farkle lines later (SPEC addendum D), each
-- with PlayerMenu.Add, none hooking a menu of its own.
--
-- How, and what it never does:
-- - Blizzard's own way for addons (Blizzard_Menu, 11.0's menus: Forever and the Classic clients
--   that have them): Menu.ModifyMenu("MENU_UNIT_" .. which, fn) for each menu below. The game
--   calls fn after it built its own lines, each call inside securecallfunction, so ours are added
--   after Blizzard's and never taint them (Blizzard's guide, 11_0_0_MenuImplementationGuide.lua).
--   No Blizzard function is replaced or hooked. A client without Menu.ModifyMenu gets no lines
--   (the person card and the Sylvanistas window still show the version): the old dropdown menus
--   (UIDropDownMenu) taint the menu's other lines when an addon adds to them.
-- - Opening a menu sends nothing: the lines read what this client already knows. A click does
--   what its line says (Versions.lua, Workshop.lua): nothing opens the game's chat box
--   (ChatFrame_SendTell and its friends write the chat's globals and taint what the player types
--   next, see ChatWindow.lua), and no game popup opens with the gamepad UI (Sylvanistas's own windows).
-- - Only a player who can be reached: never ourselves, an enemy (ENEMY_PLAYER is not hooked), an
--   offline name (FRIEND_OFFLINE, GUILD_OFFLINE and an offline guild roster row), a Battle.net
--   friend (BN_*: an account, not a character) or a unit that is not a player.
-- - Nothing from a value the game hides from addons (a secret value: the guild roster's member
--   info in a dungeon or raid, C_Club.GetMemberInfo; a unit's name or identity where it is
--   restricted): tested, a secret stops the addon's code with an error, so such a menu gets no
--   Sylvanistas lines. In a dungeon, a raid or a match (ns.ChatLocked) the lines that would send show
--   greyed and say why: target.locked.

local PlayerMenu = {}
ns.PlayerMenu = PlayerMenu

-- The menus hooked ("MENU_UNIT_" .. each). RAID: the raid roster; FRIEND: a name in chat, the Who
-- list and the friends list; COMMUNITIES_*: Forever's guild and community rosters; GUILD: the old
-- Guild window's roster (Classic); CHAT_ROSTER: a chat channel's member list; RECENT_ALLY: Forever's
-- recent allies.
PlayerMenu.WHICH = { "PLAYER", "PARTY", "RAID_PLAYER", "RAID", "FRIEND", "COMMUNITIES_GUILD_MEMBER",
	"COMMUNITIES_WOW_MEMBER", "GUILD", "CHAT_ROSTER", "RECENT_ALLY" }

local entries = {}   -- { key, order, build }, in order
local hooked = false -- Menu.ModifyMenu called for every menu above

-- A feature's lines: build(target, menu) adds them to `menu` (below) for `target` = { name (the
-- whole "Name-Realm" as the server writes it), which (the menu), unit (when it came from a unit
-- frame), locked (the game holds addon messages now: a line that sends is shown greyed) }.
-- `order`: lower first (Versions.lua 10, the author's lines 50, 1.2's later). The same key again
-- replaces its entry (a file loaded twice); no build takes it off.
function PlayerMenu.Add(key, build, order)
	if type(key) ~= "string" then return false end
	for i = #entries, 1, -1 do
		if entries[i].key == key then table.remove(entries, i) end
	end
	if type(build) ~= "function" then return false end
	entries[#entries + 1] = { key = key, order = tonumber(order) or 100, build = build }
	table.sort(entries, function(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return a.key < b.key
	end)
	return true
end

-- Forever's names are "First Surname" and a unit menu gets them apart (UnitNameUnmodified); a name
-- without its realm split by the menu (NameUtil.SplitPlayerNameIntoParts, where names are not one
-- across the region) comes back whole here.
local function Joined(name, surname)
	if type(surname) ~= "string" or surname == "" or name:find("-", 1, true) then return name end
	if ns.splitNames and not name:find(" ", 1, true) and not ns.IsRealmName(surname) then return name .. " " .. surname end
	return name .. "-" .. surname
end

-- Values the client hides from addons (secret values): any of them, and nothing is read.
local function Secret(...)
	if type(issecretvalue) ~= "function" then return false end
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) then return true end
	end
	return false
end

-- The player a menu is for, or nil when it is not one we can reach (see above).
function PlayerMenu.Target(which, ctx)
	if type(ctx) ~= "table" then return nil end
	local info = ctx.clubMemberInfo
	-- (Checked before any test of them: a secret can't be compared or tested.)
	if Secret(ctx.name, ctx.surname, ctx.server, ctx.unit, ctx.isSelf, ctx.isOffline, ctx.bnetIDAccount, ctx.isMobile, info) then return nil end
	if type(info) == "table" and Secret(info.presence, info.name, info.isSelf) then return nil end
	if ctx.isSelf or ctx.isOffline or ctx.bnetIDAccount or ctx.isMobile then return nil end
	local offline = Enum and Enum.ClubMemberPresence and Enum.ClubMemberPresence.Offline
	if type(info) == "table" and offline ~= nil and info.presence == offline then return nil end
	local unit = type(ctx.unit) == "string" and ctx.unit ~= "" and ctx.unit or nil
	local name
	if unit then
		local isPlayer = not UnitIsPlayer or UnitIsPlayer(unit)
		local isMe = UnitIsUnit and UnitIsUnit(unit, "player")
		local connected = not UnitIsConnected or UnitIsConnected(unit)
		local first, realm
		if UnitFullName then first, realm = UnitFullName(unit) end
		if Secret(isPlayer, isMe, connected, first, realm) then return nil end
		if not isPlayer or isMe or not connected then return nil end
		name = ns.UnitFullName(unit)
	else
		local raw = ctx.name
		if type(raw) ~= "string" or raw == "" then return nil end
		name = ns.FullName(ns.Normal(Joined(raw, ctx.surname or ctx.server)))
	end
	if type(name) ~= "string" or name == "" or name == ns.me then return nil end
	if ns.me and ns.Fold(name) == ns.Fold(ns.me) then return nil end
	return { name = name, which = which, unit = unit, locked = ns.ChatLocked() }
end

-- What a feature's build gets to add lines with. The first line any of them adds puts a divider
-- and the "Sylvanistas" title over them all; no line, nothing of Sylvanistas in the menu.
local function Wrap(root)
	local m = { count = 0 }
	local function Head()
		if m.count == 0 then
			if root.CreateDivider then root:CreateDivider() end
			root:CreateTitle(L.PLAYERMENU_TITLE)
		end
		m.count = m.count + 1
	end
	local function Tip(d, title, text)
		if not (d and d.SetTooltip and (title or text)) then return end
		d:SetTooltip(function(tooltip)
			if title then tooltip:AddLine(title, 1, 0.82, 0) end
			if text then tooltip:AddLine(text, 1, 1, 1, true) end
		end)
	end
	-- A line that is read, not clicked (the player's version).
	function m.Line(text, tipTitle, tipText)
		Head()
		local d = root:CreateTitle(text)
		Tip(d, tipTitle, tipText)
		return d
	end
	-- A line that does something: fn() on a click, protected. enabled == false: shown greyed (its
	-- tooltip says why).
	function m.Button(text, fn, tipTitle, tipText, enabled)
		Head()
		local d = root:CreateButton(text, function() ns.SafeCall("player menu " .. tostring(text), fn) end)
		Tip(d, tipTitle, tipText)
		if enabled == false and d and d.SetEnabled then d:SetEnabled(false) end
		return d
	end
	return m
end

-- One menu opening: every feature's lines for its player, after the game's own.
function PlayerMenu.Build(which, root, ctx)
	if type(root) ~= "table" and type(root) ~= "userdata" then return 0 end
	if not ns.IsMember() then return 0 end
	local target = PlayerMenu.Target(which, ctx)
	if not target then return 0 end
	local menu = Wrap(root)
	for _, e in ipairs(entries) do
		ns.SafeCall("player menu " .. e.key, e.build, target, menu)
	end
	return menu.count
end

-- Every menu above, once (at login: Blizzard_Menu loads before any addon).
function PlayerMenu.Hook()
	if hooked then return true end
	if not (Menu and type(Menu.ModifyMenu) == "function") then
		ns.Log("player menus: this client has no Menu.ModifyMenu, no Sylvanistas lines in them")
		return false
	end
	for _, which in ipairs(PlayerMenu.WHICH) do
		local w = which
		local ok, err = pcall(Menu.ModifyMenu, "MENU_UNIT_" .. w, function(_, root, ctx)
			ns.SafeCall("player menu", PlayerMenu.Build, w, root, ctx)
		end)
		if not ok then ns.Log("player menu %s not hooked: %s", w, tostring(err)) end
	end
	hooked = true
	return true
end
function PlayerMenu.Hooked() return hooked end

-- For /syl status.
function PlayerMenu.StatusLine()
	local keys = {}
	for _, e in ipairs(entries) do keys[#keys + 1] = e.key end
	return ("%s, lines: %s"):format(hooked and ("hooked (" .. #PlayerMenu.WHICH .. " menus)") or "not hooked", #keys > 0 and table.concat(keys, ", ") or "none")
end

function PlayerMenu.Reset() hooked = false end -- (tests: the entries stay, each file's own)

ns.On("LOGIN", function() PlayerMenu.Hook() end)
