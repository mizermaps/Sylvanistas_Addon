local ADDON, ns = ...
local L = ns.L

-- The elite borders (1.0.1, asked for on the community Discord): the game's own elite and rare
-- art, and Max's bronze frames drawn over it, around the portrait of a Sylvanistas player on your
-- target and focus frames, and around your own portrait for your own rank, like Elite Player
-- Frame (Enhanced) but for other players too. `/syl borders on|off`, on by default.
--
-- How, on Forever's unit frames (Blizzard_UnitFrame, the "Camelot" family: TargetFrameTemplate
-- and PlayerFrame): the game draws an elite or rare creature's border with BossPortraitFrameTexture,
-- a texture of the frame's TargetFrameContainer, set in TargetFrameMixin:CheckClassification
-- (GetBossPortraitFrameData gives the atlas and where it goes). Sylvanistas leaves that texture alone:
-- it puts its own hidden textures on the same container, one per border, just above the game's
-- (same layer, one sublevel up), with the game's atlases (or Max's files, at the size and offsets
-- of the game's frames they were drawn over), sized and anchored once, out of combat. From then on
-- it only shows and hides them: Show and Hide are not protected for a texture (the client's API
-- documentation marks them protected for a frame only), so a target change in combat is fine.
-- The game's frames get no call from Sylvanistas but those CreateTexture, and nothing written in them
-- but hooksecurefunc's hook, which keeps their CheckClassification secure.
-- After the game's CheckClassification on the target and focus frames (hooksecurefunc on the frames
-- themselves: the mixin's functions were copied into them when they were made) Sylvanistas shows the
-- border of the unit again, so it follows every update the game makes.
--
-- The gamepad UI (Forever's controller mode): off there. Sylvanistas leaves the game's frames alone with
-- the gamepad UI (0.9.8), and nothing offline can show that a hook in the target frame's update is
-- harmless to it (0.9.9: the world map looked harmless too). Logged in with the gamepad UI, Sylvanistas
-- neither hooks nor makes textures; switched to it later, its textures hide at once and the hook
-- returns without a call; back to mouse and keyboard, the borders come back.
--
-- Cheap: a unit's border is worked out only when the target or focus changes, when its name or
-- guild reaches the client (UNIT_NAME_UPDATE, PLAYER_GUILD_UPDATE), or when the census report of
-- its guild (or the High Council's list, or for a councillor the council's names shown or hidden
-- on the King's screen, or whether a net-off word hides him: 1.1) changes, and only from lookups:
-- its guild's report by name, never a walk over every guild.
-- A character or a guild the moderators took off (net-off, Moderation.lua; 1.1, Konig's review)
-- gets no border and no nameplate mark: a Sylvanistas player to nobody's eye.
--
-- The author's preview (1.0.0): his character holds no Sylvanistas rank, so his own portrait shows
-- none of the borders he ships. `/syl borders test <tier>` (a tier's name, as /syl status prints
-- it) shows that border round his own portrait, turned round as a holder sees his own, and on his
-- target or focus frame while that is himself; `/syl borders test off` ends it. His alone
-- (Workshop.Visible: his character, or his test build, as Asmon's and the Treasurer's views):
-- anyone else's command gets what /syl borders prints, and changes nothing. His screen alone:
-- nothing is sent, nothing is saved (a /reload forgets it), nobody else's border changes. It goes
-- through the same Refresh as a real border, so the same rules hold: none while the borders are
-- off or with the gamepad UI, the textures made once out of combat.
--
-- The nameplate marks (1.0.0, Nameplates.lua) come from the same facts and tiers (Borders.MarkOf),
-- and `/syl borders off` hides them with the borders. The author's preview shows its tier's mark
-- too, and has one tier of the marks alone: "member", the star (no border has it).

local Borders = {}
ns.Borders = Borders

-- Max's second option: the High Council gold, like the King. Off: the High Council is silver
-- (both winged).
ns.BORDERS_COUNCIL_GOLD = false

-- Who gets which border, checked from the top: the first that holds is the border (Max's list,
-- highest first). The game's art is as Blizzard_UnitFrame/Camelot/TargetFrameUtils.lua
-- (GetBossPortraitFrameData) gives it for a boss, a rare and an elite creature, at the offsets the
-- game anchors each at (x, y: from the top right of the target frame's container; mirrored on your
-- own frame). The plain silver is the game's too, by the name Forever's client knows it (its
-- Mainline TargetFrameUtils.lua gives it to a rare elite): the plain gold's size and shape, so at
-- the plain gold's offsets. Each is drawn as the game draws it: no tint, no desaturation.
-- A tier may name a file instead of an atlas: file (the texture's path), coords (the art's area
-- on it: left, right, top, bottom), width and height (its size on screen, the game's 1x size of
-- the frame it was drawn over) and fallback (that frame's atlas, drawn without colour when the
-- client can't load the file).
-- Who:
--   king     the King of our faction: his character (ns.IsKingCharacter) in his guild
--            (ns.IsKingGuild); where no character is pinned, that guild's guild master
--   council  the High Council (the signed list, ns.IsHighCouncillor): true, or the name of the
--            ns flag that must be on for it (except on the King's screen while he streams)
--   leader   the guild master of a Sylvanistas guild, as its census names him (Data.KnownRank, as
--            the Crown asks it: two senders naming him, one of them someone else; our own
--            guild's: our roster)
--   officer  its officers: the census's (the same way, two senders), or our own guild's officer
--            ranks (Roster.lua)
--   ranks    a member of a Sylvanistas guild whose rank name holds one of these words (any case, a
--            whole word): rank names are what each guild master wrote, as the game shows them
local WINGED = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold-Winged"
local PLAIN = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold"
-- Max's bronze frames, drawn over the winged and the plain gold at twice their size: 256 x 256
-- TGAs, the art at the top left (scripts/make-borders.py makes them from media/borders/src).
local MEDIA = "Interface\\AddOns\\Sylvanistas\\media\\borders\\"
Borders.TIERS = {
	{ name = "gold-elite", atlas = WINGED, x = 11, y = -4, king = true, council = "BORDERS_COUNCIL_GOLD" },
	{ name = "silver-elite", atlas = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Rare-Silver-Winged", x = 8, y = -7,
		council = true },
	{ name = "gold", atlas = PLAIN, x = 0, y = 1, leader = true },
	{ name = "silver", atlas = "ui-hud-unitframe-target-portraiton-boss-rare-silver", x = 0, y = 1, officer = true },
	{ name = "bronze-elite", file = MEDIA .. "bronze-winged", coords = { 0, 220 / 256, 0, 180 / 256 }, width = 110, height = 90,
		x = 11, y = -4, fallback = WINGED, ranks = { "raider" } },
	{ name = "bronze", file = MEDIA .. "bronze-plain", coords = { 0, 200 / 256, 0, 200 / 256 }, width = 100, height = 100,
		x = 0, y = 1, fallback = PLAIN, ranks = { "veteran", "veterano", "veterana" } },
}

-- Where they go: the frame (a global of the game's), its container, and the hook that follows the
-- game's updates. Your own portrait sits on the left, so there the art is mirrored.
local RIGS = {
	{ unit = "target", frame = "TargetFrame", container = "TargetFrameContainer", hook = "CheckClassification" },
	{ unit = "focus", frame = "FocusFrame", container = "TargetFrameContainer", hook = "CheckClassification" },
	{ unit = "player", frame = "PlayerFrame", container = "PlayerFrameContainer", mirror = true },
}
local TRACKED = { target = true, focus = true, player = true }

local rigs = {}  -- [unit] = { tex = { [tier name] = texture }, shown = tier name or nil }
local known = {} -- [unit] = { guid, tier, guild, report, rt, council }: the last worked out
local installed, waiting = false, false
local preview    -- the author's preview: a tier's name while on (this session only, never saved)
Borders.stats = { computed = 0 } -- (tests, /syl status)

-- Values the client hides from addons (secret values) count as none.
local function Secret(...)
	if type(issecretvalue) ~= "function" then return false end
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) then return true end
	end
	return false
end

local function RankHolds(ranks, rankName)
	if type(rankName) ~= "string" or rankName == "" then return false end
	for word in ns.Fold(rankName):gmatch("[^%s%p%d]+") do
		for _, want in ipairs(ranks) do
			if word == ns.Fold(want) then return true end
		end
	end
	return false
end

-- 1.1 (Konig's review): a character the moderators took off (net-off, Moderation.lua), or one of a
-- guild they took off the network, shows as no Sylvanistas player on this client: no border, no
-- nameplate mark (never the King: nobody takes him off). Our own portrait keeps ours.
local function NetOff(who, guild)
	local M = ns.Moderation
	if type(M) ~= "table" or type(M.Hides) ~= "function" or who == ns.me then return false end
	return M.Hides(who, guild) ~= nil
end

-- What decides a unit's border, or nil for anyone no border is for: not a player, of the other
-- faction (the census is per faction, and so is the King), or a value the client hides.
local function Facts(unit)
	if not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
	local faction = UnitFactionGroup(unit)
	local name, realm = UnitFullName(unit)
	local guild, rankName, rankIndex = GetGuildInfo(unit)
	if Secret(faction, name, realm, guild, rankName, rankIndex) then return nil end
	if faction ~= (ns.faction or "Alliance") then return nil end
	local who = ns.UnitFullName(unit)
	if type(who) ~= "string" or who == "" then return nil end
	local f = { guild = type(guild) == "string" and guild or nil, who = who }
	f.off = NetOff(who, f.guild)
	f.councillor = ns.IsHighCouncillor(who) == true
	f.council = f.councillor and not ns.CouncilMasked()
	if not f.guild or not ns.IsFederation(f.guild) then return f end
	f.sylvanistas, f.rankName = true, rankName
	f.king = ns.IsKingGuild(f.guild) and (ns.IsKingCharacter(who) or (ns.KingCharacter() == nil and rankIndex == 0))
	local guilds = ns.rdb and ns.rdb.guilds
	local report = type(guilds) == "table" and guilds[f.guild] or nil
	f.report = report
	local mine = GetGuildInfo("player")
	if mine and f.guild == mine then
		-- Our own guild: the rank the server gives (our roster's if it gives none).
		local rank = type(rankIndex) == "number" and rankIndex or (ns.Roster and ns.Roster.RankOf(who))
		f.fromRoster = type(rankIndex) ~= "number"
		f.leader = rank == 0
		f.officer = type(rank) == "number" and rank > 0 and rank <= ns.CAPTAIN_RANK
	elseif type(report) == "table" then
		-- Another guild: the rank its census gives him, as the Crown's checks trust it (Data.KnownRank,
		-- not soft): the picture most senders give, and two senders naming him in it, one of them
		-- someone else. One report never makes its own sender a Lord or a Captain: alone, against
		-- the guild's other senders, or once their row is old. Nor does one report of anyone else's
		-- (1.0.0, Konig's review of 1.0.0: a single character's report naming him gave a Lord's gold
		-- or a Captain's silver on every screen); the Crown asks two for a guild master, and a
		-- border asks two for a Captain as well.
		local rank, named = ns.Data.KnownRank(who, f.guild)
		if (named or 0) < 2 then rank = nil end
		f.leader = rank == 0
		f.officer = type(rank) == "number" and rank > 0 and rank <= ns.CAPTAIN_RANK
	end
	return f
end

local function Match(f)
	if not f or f.off then return nil end
	for _, t in ipairs(Borders.TIERS) do
		local council = t.council == true or (type(t.council) == "string" and ns[t.council] == true)
		if (t.king and f.king) or (council and f.council) or (t.leader and f.leader) or (t.officer and f.officer)
			or (t.ranks and f.sylvanistas and RankHolds(t.ranks, f.rankName)) then
			return t
		end
	end
	return nil
end

-- The border a unit gets now (a tier's name: "gold-elite", "silver-elite", "gold", "silver",
-- "bronze-elite", "bronze"; nil for none), worked out afresh.
function Borders.TierOf(unit)
	local t = Match(Facts(unit))
	return t and t.name or nil
end

-- What a unit's border (or nameplate mark) was worked out from, to know when it must be worked
-- out again (Borders.Changed): its guild, that guild's census report as it stood (its time, and
-- its votes: an outvoted report keeps the row and changes the votes, which Data.KnownRank reads),
-- the High Council's list, our roster when his rank came from it (our own guild's, the server
-- giving none; Roster.lua makes a new table at each scan), and for a High Councillor whether the
-- council's names were hidden (the King's screen while he streams, ns.CouncilMasked: the eye in
-- the Realm, Asmon's view, becoming the King); and (1.1) his name, and whether a net-off word hid him.
local function Inputs(f)
	local report = f and f.report
	local row = type(report) == "table"
	local masked
	if f and f.councillor then masked = ns.CouncilMasked() == true end
	return { guild = f and f.guild, report = report, rt = row and report.t or nil, vouch = row and report.vouch or nil,
		council = ns.rdb and ns.rdb.council, roster = f and f.fromRoster and (ns.Roster and ns.Roster.byName or false) or nil,
		masked = masked, who = f and f.who, off = f and f.off }
end

-- Has anything a unit's border or mark was worked out from (Inputs) changed since? Lookups only:
-- its guild's report by name, never a walk over every guild.
function Borders.Changed(k)
	local rdb = ns.rdb
	local report = k.guild and rdb and type(rdb.guilds) == "table" and rdb.guilds[k.guild] or nil
	local row = type(report) == "table"
	return report ~= k.report or (row and report.t or nil) ~= k.rt or (row and report.vouch or nil) ~= k.vouch
		or (rdb and rdb.council) ~= k.council or (k.roster ~= nil and k.roster ~= (ns.Roster and ns.Roster.byName or false))
		or (k.masked ~= nil and k.masked ~= (ns.CouncilMasked() == true))
		or (k.who ~= nil and NetOff(k.who, k.guild) ~= k.off)
end

local function Compute(unit, guid)
	Borders.stats.computed = Borders.stats.computed + 1
	local f = Facts(unit)
	local t = Match(f)
	local k = Inputs(f)
	k.guid, k.tier = guid, t and t.name or nil
	known[unit] = k
	return k
end

-- The nameplate mark (Nameplates.lua) of each border, for anyone but the King: the High Council
-- (gold wings too behind ns.BORDERS_COUNCIL_GOLD), Lords and Captains the game's silver elite
-- mark, Raiders and Veterans the bronze. The King's mark, the game's gold, is his alone.
Borders.MARK_OF = { ["gold-elite"] = "silver", ["silver-elite"] = "silver", gold = "silver", silver = "silver",
	["bronze-elite"] = "bronze", bronze = "bronze" }

-- The mark a unit gets next to its name on a nameplate, from the same facts and trust rules as
-- its border: "gold" (the King), "silver", "bronze", "member" (any other member of a Sylvanistas
-- guild of our faction: the star), nil for anyone else; and what it was worked out from (Inputs).
function Borders.MarkOf(unit)
	local f = Facts(unit)
	local mark
	if f and f.off then
		mark = nil -- (1.1: net-off)
	elseif f and f.king then
		mark = "gold"
	elseif f then
		local t = Match(f)
		mark = t and Borders.MARK_OF[t.name] or (f.sylvanistas and "member" or nil)
	end
	return mark, Inputs(f)
end

-- 1.1.1: the mark by a name in Sylvanistas's chat window (ChatWindow.lua), where there is a line's
-- sender and guild but no unit: MarkOf's twin, lookups only. The guild is the one his line
-- names, and nothing the server stamps (a unit's GetGuildInfo, which MarkOf reads) backs it:
-- Channels keeps an [Sylvanistas] line from a sender it could not verify (VerifiedLevel's 1, false),
-- so any name on the channel can claim a made-up "Sylvanistas X" guild. A mark here needs the claim
-- proven. Our own guild: his rank from our roster, its name from the game's list of our ranks
-- (Raiders and Veterans bronze); not in the roster, or our guild's name spelled another way
-- (names ignore case, as Channels reads it), no mark. Another guild: a rank its census
-- gives him (the star; silver when two senders name him, as Facts asks; no rank name, so no
-- bronze from other guilds), or the King, his Stewards and Hands by the names Channels verifies
-- them by; a guildmate of ours speaking for another guild, no mark; anyone else, none (a plain
-- member of another guild is in no census). Not Channels.VerifiedLevel itself: its
-- Data.ClaimGuild records the claim, and a redraw must not. The King, a High Councillor and
-- net-off as MarkOf. Not tied to /syl borders or /syl nameplates, nor to the gamepad UI: the
-- chat's marks are the chat's, in Sylvanistas's own window. Returns the mark ("gold", "silver",
-- "bronze", "member" or nil) and the facts (f.proven: the claim backed).
function Borders.MarkOfName(who, guild)
	if type(who) ~= "string" or who == "" then return nil end
	who = ns.FullName(who)
	guild = type(guild) == "string" and guild ~= "" and guild or nil
	local f = { guild = guild, who = who }
	f.off = NetOff(who, guild)
	f.councillor = ns.IsHighCouncillor(who) == true
	f.council = f.councillor and not ns.CouncilMasked()
	if f.off then return nil, f end
	if guild and ns.IsFederation(guild) then
		f.sylvanistas = true
		local rank
		local mine = GetGuildInfo("player")
		if mine and guild == mine then
			rank = ns.Roster and ns.Roster.RankOf(who)
			f.proven = type(rank) == "number"
			if f.proven and type(GuildControlGetRankName) == "function" then
				local ok, name = pcall(GuildControlGetRankName, rank + 1)
				if ok and type(name) == "string" and not Secret(name) then f.rankName = name end
			end
		elseif not (mine and guild:lower() == mine:lower()) and not (ns.Roster and ns.Roster.RankOf(who)) then
			local known, named = ns.Data.KnownRank(who, guild)
			if (named or 0) >= 2 then rank = known end
			local K = ns.King
			f.proven = known ~= nil or (ns.IsKingGuild(guild) and (ns.IsKingCharacter(who) or (type(K) == "table"
				and ((type(K.IsStewardName) == "function" and K.IsStewardName(who)) or (type(K.IsHandName) == "function" and K.IsHandName(who))))))
				and true or false
		end
		f.king = ns.IsKingGuild(guild) and (ns.IsKingCharacter(who) or (ns.KingCharacter() == nil and rank == 0))
		f.leader = rank == 0
		f.officer = type(rank) == "number" and rank > 0 and rank <= ns.CAPTAIN_RANK
	end
	if f.king then return "gold", f end
	local t = Match(f)
	return t and Borders.MARK_OF[t.name] or (f.sylvanistas and f.proven and "member" or nil), f
end

function Borders.Enabled() return not (ns.db and ns.db.borders == false) end

-- On, with mouse and keyboard, for a member of a Sylvanistas guild (outside one the addon offers
-- nothing but the Join Sylvanistas screen).
local function Active()
	return Borders.Enabled() and not ns.GamepadUI() and ns.IsMember() == true
end

local function AtlasExists(atlas)
	local info = C_Texture and C_Texture.GetAtlasInfo
	if type(info) ~= "function" then return true end
	local ok, v = pcall(info, atlas)
	return ok and v ~= nil
end

-- The mark before a name on a Sylvanistas line, the same in the Chat tab and in the game's own chat
-- windows (1.1.2: the game's windows showed the High Council's alone): the King's crown, a High
-- Councillor's mark and icon, silver, bronze (the gold atlas in Nameplates.BRONZE), the star; ""
-- for none. 14 px, as the Chat tab has shown them; an atlas the client lacks: the star.
Borders.CHAT_STAR = "|TInterface\\AddOns\\Sylvanistas\\media\\borders\\star:14:14|t"
local CHAT_SILVER = "nameplates-icon-elite-silver"
local CHAT_BRONZE, CHAT_BRONZE_TINT = "nameplates-icon-elite-gold", ":0:0:158:118:86" -- (Nameplates.BRONZE x 255)

local function ChatAtlas(atlas, tint)
	if not AtlasExists(atlas) then return Borders.CHAT_STAR end
	return "|A:" .. atlas .. ":14:14" .. (tint or "") .. "|a"
end

function Borders.ChatMark(who, guild)
	if type(who) ~= "string" or who == "" then return "" end
	who = ns.FullName(who)
	local mark = Borders.MarkOfName(who, guild)
	if mark == "gold" then return "|T" .. ns.CROWN_ICON .. ":14:14|t" end -- (the King's mark in chat is his crown)
	if ns.IsHighCouncillor(who) and not ns.CouncilMasked() then return ns.CouncilMark(who) end
	if mark == "silver" then return ChatAtlas(CHAT_SILVER) end
	if mark == "bronze" then return ChatAtlas(CHAT_BRONZE, CHAT_BRONZE_TINT) end
	if mark == "member" then return Borders.CHAT_STAR end
	return ""
end

-- A tier's art on a new texture (mirror: turned round, for your own portrait), or false when the
-- client has none of it. An atlas at its own size; a file at the tier's size, its art's area only.
-- A file SetTexture fails or says false for: the game's frame it was drawn over, without colour.
-- The game's way to turn art round is its texture coordinates the other way, right before left
-- (Blizzard_OrderHallTalents.lua, for an atlas).
local function Dress(tex, t, mirror)
	local left, right, top, bottom = 0, 1, 0, 1
	local ok, loaded = false, false
	if t.file then ok, loaded = pcall(tex.SetTexture, tex, t.file) end
	if ok and loaded ~= false then
		tex:SetSize(t.width, t.height)
		left, right, top, bottom = unpack(t.coords)
		if not mirror then tex:SetTexCoord(left, right, top, bottom) end
	elseif t.file then
		if not (t.fallback and AtlasExists(t.fallback)) then return false end
		ns.Log("borders: %s not loaded, the game's %s without colour instead", t.file, t.fallback)
		tex:SetAtlas(t.fallback, true, nil, true)
		tex:SetDesaturated(true)
	else
		tex:SetAtlas(t.atlas, true, nil, true)
	end
	if mirror then tex:SetTexCoord(right, left, top, bottom) end
	return true
end

-- Once, with mouse and keyboard and out of combat (a texture of the game's frames may count as
-- theirs, whose points and size are not ours to set in combat): the textures, then the hooks.
-- A client without Forever's unit frames (Classic Era, Anniversary) gets none.
function Borders.Install()
	if installed then return true end
	if ns.GamepadUI() then return false end
	if InCombatLockdown and InCombatLockdown() then
		waiting = true
		return false
	end
	waiting, installed = false, true
	for _, spec in ipairs(RIGS) do
		local frame = _G[spec.frame]
		local container = type(frame) == "table" and frame[spec.container] or nil
		if type(container) == "table" and type(container.CreateTexture) == "function" then
			local rig = { tex = {} }
			for _, t in ipairs(Borders.TIERS) do
				-- (A missing atlas: no texture. A file's is made to try it: one the client can't
				-- load, with no atlas to fall back to, stays hidden and unused.)
				if t.file or AtlasExists(t.atlas) then
					local tex = container:CreateTexture(nil, "ARTWORK", nil, 3)
					tex:Hide()
					if Dress(tex, t, spec.mirror) then
						if spec.mirror then
							-- The target's portrait sits 26 px from its frame's right edge, yours 24 px from its left.
							tex:SetPoint("TOPLEFT", container, "TOPLEFT", -(t.x + 2), t.y)
						else
							tex:SetPoint("TOPRIGHT", container, "TOPRIGHT", t.x, t.y)
						end
						rig.tex[t.name] = tex
					end
				end
			end
			rigs[spec.unit] = rig
			if spec.hook and type(frame[spec.hook]) == "function" and type(hooksecurefunc) == "function" then
				local unit, where = spec.unit, "borders " .. spec.unit
				hooksecurefunc(frame, spec.hook, function() ns.SafeCall(where, Borders.Refresh, unit) end)
			end
		end
	end
	ns.Log("borders: set up on %s", Borders.Frames())
	return true
end

local function Show(rig, name)
	if rig.shown == name then return end
	if rig.shown and rig.tex[rig.shown] then rig.tex[rig.shown]:Hide() end
	rig.shown = nil
	if name and rig.tex[name] then
		rig.tex[name]:Show()
		rig.shown = name
	end
end

local function HideAll()
	for _, rig in pairs(rigs) do Show(rig, nil) end
end

-- The unit is us: our own frame, or the target or focus while it is us (by GUID; by UnitIsUnit
-- where a GUID is hidden).
local function IsMe(unit, guid)
	if unit == "player" then return true end
	local mine = UnitGUID and UnitGUID("player")
	if guid ~= nil and mine ~= nil and not Secret(mine) then return guid == mine end
	if type(UnitIsUnit) ~= "function" then return false end
	local ok, same = pcall(UnitIsUnit, unit, "player")
	return ok and not Secret(same) and same == true
end

-- The unit's border again: the one worked out for it while it is the same unit (fresh: work it
-- out again), none while the borders are off. On our own portrait, and on the target or focus
-- while it is us, the author's preview instead while it is on.
function Borders.Refresh(unit, fresh)
	if not Active() then
		if rigs[unit] then Show(rigs[unit], nil) end
		return
	end
	if not installed and not Borders.Install() then return end
	local rig = rigs[unit]
	if not rig then return end
	local guid = UnitGUID and UnitGUID(unit)
	if Secret(guid) then guid = nil end
	local k = known[unit]
	if fresh or not k or guid == nil or k.guid ~= guid then k = Compute(unit, guid) end
	Show(rig, preview and UnitExists(unit) and IsMe(unit, guid) and preview or k.tier)
end

function Borders.RefreshAll(fresh)
	for _, spec in ipairs(RIGS) do Borders.Refresh(spec.unit, fresh) end
end

-- The census, the High Council's list, our roster or the council's names hidden or shown on the
-- King's screen changed: only a unit whose border was worked out from something that changed
-- since (Borders.Changed) is worked out again.
function Borders.CensusChanged()
	if not installed then return end
	for unit, k in pairs(known) do
		if Borders.Changed(k) then Borders.Refresh(unit, true) end
	end
end

function Borders.Report()
	if not Borders.Enabled() then return ns.Print(L.BORDERS_OFF) end
	ns.Print(ns.BORDERS_COUNCIL_GOLD == true and L.BORDERS_ON_COUNCIL_GOLD or L.BORDERS_ON)
	if ns.GamepadUI() then ns.Print(L.BORDERS_GAMEPAD) end
end

-- On or off, and the nameplate marks with them (Nameplates.lua).
function Borders.SetEnabled(on)
	ns.db.borders = on and true or false
	Borders.RefreshAll(true)
	ns.Nameplates.RefreshAll(true)
	Borders.Report()
end

---------------------------------------------------------------------------
-- The author's preview (see the top of the file)
---------------------------------------------------------------------------

local function Grey(s) return "|cff9d9d9d" .. s .. "|r" end
local function Gold(s) return "|cffffd200" .. s .. "|r" end
local function Green(s) return "|cff40ff40" .. s .. "|r" end

local function TierNamed(name)
	for _, t in ipairs(Borders.TIERS) do
		if t.name == name then return t end
	end
	return nil
end

-- "gold-elite" -> L.BORDERS_WHO_GOLD_ELITE: who holds that border, for the Workshop's lines.
local function Who(name) return L["BORDERS_WHO_" .. name:upper():gsub("%-", "_")] end

-- The author, or his test build (Dev.lua, never published): whoever sees the Workshop.
function Borders.PreviewAllowed()
	local W = ns.Workshop
	return type(W) == "table" and type(W.Visible) == "function" and W.Visible() == true
end
function Borders.Preview() return preview end

-- The marks' own preview tier (Nameplates.lua): the star of any other member. No border has it,
-- so his portrait shows none while it is on.
Borders.MEMBER = "member"

-- `/syl borders test <tier>|off` (any case; nothing: which tiers there are). False for anyone
-- else, with nothing done: the command then answers as /syl borders does. A tier shows its border
-- and its nameplate mark (Nameplates.lua); "member" the star alone.
function Borders.SetPreview(word)
	if not Borders.PreviewAllowed() then return false end
	word = type(word) == "string" and word:lower() or ""
	if word == "off" then
		preview = nil
		ns.Print(L.BORDERS_PREVIEW_OFF)
	elseif TierNamed(word) then
		preview = word
		-- (1.1: with the marks off, it says no mark shows with the border.)
		ns.Print(ns.Nameplates.Enabled() == false and L.BORDERS_PREVIEW_ON_NO_MARK:format(word) or L.BORDERS_PREVIEW_ON:format(word))
	elseif word == Borders.MEMBER then
		preview = word
		-- (With the marks off it only waits: NAMEPLATES_PREVIEW_WHEN_OFF below says so.)
		if ns.Nameplates.Enabled() ~= false then ns.Print(L.BORDERS_PREVIEW_ON_MEMBER) end
	else
		local names = {}
		for _, t in ipairs(Borders.TIERS) do names[#names + 1] = t.name end
		ns.Print(L.BORDERS_PREVIEW_HELP:format(table.concat(names, ", ")))
		return true
	end
	Borders.RefreshAll()
	ns.Nameplates.RefreshAll()
	-- Why it doesn't show yet, if it doesn't: the same rules as a real border.
	if preview then
		if not Borders.Enabled() then ns.Print(L.BORDERS_PREVIEW_WHEN_OFF)
		elseif ns.GamepadUI() then ns.Print(L.BORDERS_GAMEPAD)
		elseif ns.IsMember() ~= true then ns.Print(L.BORDERS_PREVIEW_NOT_MEMBER)
		elseif preview == Borders.MEMBER then
			-- (no border: the marks alone, and only while they are on)
			if ns.Nameplates.Enabled() == false then ns.Print(L.NAMEPLATES_PREVIEW_WHEN_OFF) end
		elseif not installed then ns.Print(L.BORDERS_PREVIEW_COMBAT) -- (only combat keeps them from being made)
		elseif not (rigs.player and rigs.player.tex[preview]) then ns.Print(L.BORDERS_PREVIEW_MISSING) end
	end
	ns.Fire("WORKSHOP_CHANGED")
	return true
end

-- The Workshop's lines for it (not in its copy for Discord): one per tier, and last the marks'
-- member star; a click shows it, a click on the one shown ends it.
function Borders.PreviewLines(lines)
	if not Borders.PreviewAllowed() then return end
	lines[#lines + 1] = { header = true, text = L.BORDERS_PREVIEW_TITLE,
		right = Grey(preview and L.BORDERS_PREVIEW_NOW:format(preview) or L.BORDERS_PREVIEW_NONE) }
	local names = {}
	for _, t in ipairs(Borders.TIERS) do names[#names + 1] = t.name end
	names[#names + 1] = Borders.MEMBER
	for _, name in ipairs(names) do
		local on = preview == name
		lines[#lines + 1] = {
			indent = 1, text = (on and Gold(name) or name) .. "  " .. Grey(Who(name)),
			right = on and Green(L.BORDERS_PREVIEW_SHOWN) or nil,
			onClick = function() Borders.SetPreview(on and "off" or name) end,
			tooltip = function(tt)
				tt:AddLine(L.BORDERS_PREVIEW_TITLE, 1, 0.82, 0)
				tt:AddLine(name == Borders.MEMBER and L.BORDERS_PREVIEW_TIP_MEMBER or L.BORDERS_PREVIEW_TIP, 1, 1, 1, true)
				-- (1.1: with the marks off, no mark shows with it.)
				if ns.Nameplates.Enabled() == false then tt:AddLine(L.NAMEPLATES_PREVIEW_WHEN_OFF, 0.6, 0.6, 0.6, true) end
			end,
		}
	end
	lines[#lines].gapAfter = true
end

-- The frames that got their textures ("target, focus, player"), for the log and /syl status.
function Borders.Frames()
	local out = {}
	for _, spec in ipairs(RIGS) do
		if rigs[spec.unit] then out[#out + 1] = spec.unit end
	end
	return #out > 0 and table.concat(out, ", ") or "none (not Forever's unit frames)"
end

function Borders.StatusLine()
	local state = Borders.Enabled() and "on" or "off (/syl borders on)"
	if Borders.Enabled() and ns.GamepadUI() then state = "on, hidden with the gamepad UI" end
	local where
	if installed then
		local shown = {}
		for _, spec in ipairs(RIGS) do
			local rig = rigs[spec.unit]
			if rig then shown[#shown + 1] = spec.unit .. " " .. (rig.shown or "-") end
		end
		where = #shown > 0 and table.concat(shown, ", ") or Borders.Frames()
	else
		where = waiting and "set up after combat" or "not set up yet"
	end
	return ("%s  |  %s  |  worked out %d times  |  council gold: %s%s"):format(state, where, Borders.stats.computed,
		tostring(ns.BORDERS_COUNCIL_GOLD == true), preview and ("  |  preview " .. preview) or "")
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

ns.On("LOGIN", function() Borders.RefreshAll(true) end)
ns.On("DATA_CHANGED", function() Borders.CensusChanged() end)
-- The King shows or hides the council's names (the eye in the Realm, ns.SetCouncilNamesShown).
ns.On("COUNCIL_MASK_CHANGED", function() Borders.CensusChanged() end)
ns.RegisterEvent("PLAYER_TARGET_CHANGED", function() Borders.Refresh("target") end)
ns.RegisterEvent("UNIT_NAME_UPDATE", function(unit) if TRACKED[unit] then Borders.Refresh(unit, true) end end)
-- A unit's guild reaching the client (or ours changing: every border again).
ns.RegisterEvent("PLAYER_GUILD_UPDATE", function(unit)
	if unit == nil or unit == "player" then Borders.RefreshAll(true)
	elseif TRACKED[unit] then Borders.Refresh(unit, true) end
end)
ns.RegisterEvent("PLAYER_REGEN_ENABLED", function() if waiting then Borders.RefreshAll(true) end end)
-- Not on every client: registered where the game has them.
pcall(ns.RegisterEvent, "PLAYER_FOCUS_CHANGED", function() Borders.Refresh("focus") end)
-- A switch between mouse and keyboard and the gamepad UI (Blizzard_SharedXML/InputUtil.lua's):
-- to the gamepad UI, every border hides at once; either way they are looked at again just after.
pcall(ns.RegisterEvent, "INPUT_DEVICE_INTERFACE_TRANSITION", function(newMode)
	local gamepad = Enum and Enum.InputDeviceInterfaceType and Enum.InputDeviceInterfaceType.Gamepad
	if gamepad ~= nil and newMode == gamepad then HideAll() end
	ns.After(0.2, "borders style", function() Borders.RefreshAll(true) end)
end)
