local ADDON, ns = ...
local L = ns.L

-- Hooks into Blizzard's own guild window instead of replacing it: an "Sylvanistas" button in
-- the guild window opens our window docked to its right, on the Census tab. We never
-- touch the Blizzard roster itself, so no taint and no breakage.
--
-- Which guild window the player gets depends on the client and on their choice (Classic
-- Era and Anniversary have an Interface option for the classic guild UI):
--   old          the Guild tab of the Social window (GuildFrame inside FriendsFrame)
--   communities  the new Guild & Communities window (CommunitiesFrame; always on Forever)
--   guildui      a standalone GuildFrame from Blizzard_GuildUI (same name, but not inside
--                FriendsFrame), should a client ship one
--   classicui    ClassicUI Forever's old-style Guild tab, inside the Social window
--   classicuiwindow  that panel should it stand on its own, outside the Social window
--                (ClassicUI Forever 0.8.0 always builds it inside): a window of its own
-- Every one that exists gets its own button, so the button is in whichever window opens,
-- keeps working when the player switches (with or without /reload), and docks to the
-- window it was clicked in. Nothing reads the setting: the window on screen decides.

local GuildFrameHook = {}
ns.GuildFrameHook = GuildFrameHook

-- social: lives in the Social window, so we dock to FriendsFrame and copy its size (the
-- old layout, kept exactly). The others dock to themselves and only lend their height.
local KINDS = {
	old = { button = "SylvanistasGuildFrameButton", size = 26, social = true },
	classicui = { button = "SylvanistasClassicGuildButton", size = 26, social = true },
	classicuiwindow = { button = "SylvanistasClassicGuildWindowButton", size = 22 },
	communities = { button = "SylvanistasCommunitiesButton", size = 22 },
	guildui = { button = "SylvanistasGuildUIButton", size = 22 },
}

-- Blizzard addons that bring a guild window with them when they load.
local WATCH = { Blizzard_Communities = true, Blizzard_GuildUI = true }

local hosts = {}   -- every guild window we added a button to, in the order found
local byFrame = {} -- frame -> its entry in hosts
local lastShown    -- the guild window the player opened last
local socialHooked

local function IsLoaded(name)
	local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	if not isLoaded then return nil end
	local ok, loaded = pcall(isLoaded, name)
	return ok and loaded and true or false
end

local function CVar(name)
	local get = (C_CVar and C_CVar.GetCVar) or GetCVar
	if not get then return nil end
	local ok, value = pcall(get, name)
	return ok and value or nil
end

local function Inside(frame, ancestor)
	local parent = frame.GetParent and frame:GetParent()
	while parent do
		if parent == ancestor then return true end
		parent = parent.GetParent and parent:GetParent()
	end
	return false
end

-- Every guild window that exists right now, as { frame, kind }. The name GuildFrame is
-- used by the old tab and by the standalone window alike, so where it lives decides; the
-- same goes for ClassicUI Forever's panel.
function GuildFrameHook.Candidates()
	local out = {}
	local social = _G.FriendsFrame
	local guild = _G.GuildFrame
	if guild then
		out[#out + 1] = { frame = guild, kind = social and Inside(guild, social) and "old" or "guildui" }
	end
	local panel = _G.ClassicUIForeverGuildPanel
	if panel then
		out[#out + 1] = { frame = panel, kind = social and Inside(panel, social) and "classicui" or "classicuiwindow" }
	end
	if _G.CommunitiesFrame then
		out[#out + 1] = { frame = _G.CommunitiesFrame, kind = "communities" }
	end
	return out
end

-- Forever's Mainline UI: its only Blizzard guild window is the new one. Classic Era and
-- Anniversary keep their old Guild tab (hidden or not): their Communities window stays "old".
function GuildFrameHook.IsHDClient()
	local guild, social = _G.GuildFrame, _G.FriendsFrame
	if guild and social and Inside(guild, social) then return false end
	return _G.PanelTemplates_AnchorTabs ~= nil
end

-- Whether our window takes the new (HD) look, next to the Guild & Communities window.
-- host: an entry of Hosts(), nil = the one in use. Nothing used yet: the client decides,
-- unless ClassicUI Forever's old tab is already there (hooked or not: it can be built
-- after the scan at login, when that login was in combat).
function GuildFrameHook.IsHD(host)
	if not GuildFrameHook.IsHDClient() then return false end
	host = host or GuildFrameHook.ActiveHost()
	if host then return host.kind == "communities" end
	for _, c in ipairs(GuildFrameHook.Candidates()) do if KINDS[c.kind].social then return false end end
	return true
end

-- Clicking again closes the docked window; clicked in another guild window, it moves there
-- (in the look of that window: the new one gets the HD window, the old tabs the old one).
local function Toggle(host)
	lastShown = host
	local UI = ns.UI
	if UI.IsShown() and UI.DockedTo() == host.dock then
		UI.CloseIfDocked(host.dock)
	else
		UI.OpenDocked(host.dock, "census", host.heightOnly, GuildFrameHook.IsHD(host) and "hd" or "old")
	end
end

local function Place(button, host)
	if host.social then
		-- Small button in the free corner of the header row, between the portrait and
		-- "Show Offline Members".
		button:SetPoint("TOPLEFT", host.dock, "TOPLEFT", 62, -26)
		return
	end
	-- The new windows have no free corner under the title (club list, member dropdown,
	-- calendar), so the button sits in the title bar, left of minimize and close.
	local frame = host.frame
	local name = frame.GetName and frame:GetName()
	local anchor = frame.MaximizeMinimizeFrame or frame.CloseButton or (name and _G[name .. "CloseButton"])
	if anchor then
		button:SetPoint("RIGHT", anchor, "LEFT", 0, 0)
	else
		button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -50, 0)
	end
	-- On Forever the metal title bar (NineSlice at +500, title and minimize at +510) would
	-- draw over a button at +10: it goes up to the level of the button it sits next to.
	local level = frame:GetFrameLevel() + 10
	if anchor and anchor.GetFrameLevel and GuildFrameHook.IsHDClient() then level = math.max(level, anchor:GetFrameLevel()) end
	button:SetFrameLevel(level)
end

local function Attach(frame, kind)
	local def = KINDS[kind]
	local social = _G.FriendsFrame
	local host = { frame = frame, kind = kind, social = def.social, heightOnly = not def.social }
	host.dock = def.social and social or frame
	byFrame[frame] = host -- first, so a window that fails half way is not hooked twice
	hosts[#hosts + 1] = host

	local button = ns.MakeRoundButton(def.button, frame, def.size)
	host.button = button
	Place(button, host)
	button:SetScript("OnClick", function() ns.SafeCall("guild frame button", Toggle, host) end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L.TITLE, 1, 0.82, 0)
		GameTooltip:AddLine(L.GUILDFRAME_TIP, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- ClassicUI Forever opens the Communities window unseen (alpha 0, off the screen) to
	-- reach the notes for its own roster: that is not the window the player uses.
	frame:HookScript("OnShow", function()
		if kind == "communities" and frame.GetAlpha and frame:GetAlpha() == 0 then return end
		lastShown = host
	end)
	-- Closing the guild window closes our window if it is docked to that one (only then).
	frame:HookScript("OnHide",function() ns.SafeCall("guild window hide", ns.UI.CloseIfDocked, host.dock) end)
	if def.social then
		if not socialHooked then
			socialHooked = true
			social:HookScript("OnHide", function() ns.SafeCall("social window hide", ns.UI.CloseIfDocked, social) end)
		end
	else
		-- The Communities window can be minimized and maximized while we are docked to it.
		frame:HookScript("OnSizeChanged", function() ns.SafeCall("guild window size", ns.UI.FollowHost, frame) end)
		-- Its side tabs come and go (minimized, no guild, Guild Finder): the HD window keeps
		-- clear of them (see UI.DockOffset).
		local tabs = kind == "communities" and frame.ChatTab
		if tabs and tabs.HookScript then
			local function Follow() ns.SafeCall("guild window tabs", ns.UI.FollowHost, frame) end
			tabs:HookScript("OnShow", Follow)
			tabs:HookScript("OnHide", Follow)
		end
	end
	ns.Log("guild window button added: %s (%s)", tostring(frame.GetName and frame:GetName()), kind)
end

-- Adds a button to every guild window that has none yet and returns how many it added.
-- Safe to call at any time and as often as needed: each window is hooked once.
function GuildFrameHook.Scan()
	local added = 0
	for _, c in ipairs(GuildFrameHook.Candidates()) do
		if not byFrame[c.frame] and ns.SafeCall("guild window " .. c.kind, Attach, c.frame, c.kind) then added = added + 1 end
	end
	return added
end

function GuildFrameHook.Hosts() return hosts end

-- The guild window the player is using: one on screen (a Social window one first, since
-- ClassicUI Forever can keep the Communities window open off screen), else the last one
-- opened this session, else nil.
function GuildFrameHook.ActiveHost()
	local shown
	for _, h in ipairs(hosts) do
		if h.frame:IsVisible() then
			if h.social then return h end
			shown = shown or h
		end
	end
	return shown or lastShown
end

-- For /syl status: which guild windows were found and hooked, and what the client says.
function GuildFrameHook.StatusLine()
	local found = {}
	for _, h in ipairs(hosts) do
		found[#found + 1] = h.kind .. "=" .. tostring(h.frame.GetName and h.frame:GetName()) .. (h.frame:IsVisible() and " (shown)" or "")
	end
	local active = GuildFrameHook.ActiveHost()
	local docked = ns.UI and ns.UI.IsShown and ns.UI.IsShown() and ns.UI.DockedTo()
	return ("hooked %s  |  in use: %s  |  docked to: %s  |  Blizzard_Communities=%s Blizzard_GuildUI=%s useClassicGuildUI=%s hd client=%s"):format(
		#found > 0 and table.concat(found, ", ") or "none", active and active.kind or "none",
		docked and tostring(docked.GetName and docked:GetName()) or "-",
		tostring(IsLoaded("Blizzard_Communities")), tostring(IsLoaded("Blizzard_GuildUI")), tostring(CVar("useClassicGuildUI")),
		tostring(GuildFrameHook.IsHDClient()))
end

-- A load-on-demand guild window (Classic Era's Communities, Blizzard_GuildUI) may load
-- after login; a Blizzard addon that already loaded is found by the scan at login.
ns.RegisterEvent("ADDON_LOADED", function(name)
	if WATCH[name] then GuildFrameHook.Scan() end
end)

ns.On("LOGIN", function()
	GuildFrameHook.Scan()
	local social = _G.FriendsFrame
	if social and social.HookScript then
		-- ClassicUI Forever builds its Guild tab late: look again whenever the Social window opens.
		social:HookScript("OnShow", function() ns.SafeCall("guild window scan", GuildFrameHook.Scan) end)
	end
	ns.Log("guild UI: %s", GuildFrameHook.StatusLine())
end)
