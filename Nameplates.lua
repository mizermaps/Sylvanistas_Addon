local ADDON, ns = ...
local L = ns.L

-- The nameplate marks (1.0.0, asked for by players on CurseForge): a small mark left of the name
-- of a friendly player of a Sylvanistas guild on his nameplate, as an elite creature has its small
-- dragon. The same facts, tiers and trust rules as the elite borders (Borders.MarkOf: the King
-- pinned, the High Council signed and hidden on the King's stream, other guilds' ranks as their
-- census trusts them, our own guild's from the server or our roster, our faction only):
--   the King                         the game's gold elite mark (nameplates-icon-elite-gold)
--   High Council, Lords, Captains    the game's silver one (nameplates-icon-elite-silver)
-- Raiders and Veterans the gold without colour, tinted the bronze of the bronze frames
--                                    here (no copy of the game's art is shipped)
--   any other member of a Sylvanistas   a plain four-point star, Sylvanistas's own art
-- guild of our faction (media/borders/star.tga, drawn by )
-- Nobody else: hostile players, creatures, the other faction, anyone outside a Sylvanistas guild,
-- and (1.1, review) a character or a guild the moderators took off (net-off, Borders.MarkOf).
--
-- Where (the author's choice): left of the name, not by the health bar, so it reads the same on
-- the "names only" plates of friendly players. How, on Forever's nameplates (Blizzard_NamePlates):
-- a plate (C_NamePlate.GetNamePlateForUnit) holds, while it shows a unit, a unit frame the game
-- takes from a pool (NamePlateBaseMixin:AcquireUnitFrame). Its `name` font string runs across the
-- plate (NamePlateUnitFrameMixin:UpdateAnchors), the name written centred on it above the bar and
-- on names-only plates (Camelot's NamePlateSetupOptions), from its left inside the bar. Sylvanistas
-- puts one texture of its own on each such unit frame (it goes with the frame from plate to
-- plate), sized like the game's classification mark (16 px, times the plate size's classification
-- scale), its right edge 2 px left of the name's first letter: half the text's width left of the
-- name's centre, or at its left edge. The game's frames get no call from Sylvanistas but that
-- CreateTexture (and IsForbidden and IsProtected, which only answer), and nothing written in them
-- but hooksecurefunc's hooks: after the game's CompactUnitFrame_UpdateName (the name written,
-- shown or hidden) and the unit frame's UpdateAnchors (its layout), the mark is put back left of
-- the name, so it follows every change the game makes, and hides with the name.
--
-- Combat and taint, as the borders: a forbidden plate (friendly plates in instances) is never
-- touched, nothing called on it but IsForbidden. A texture is made, and a mark's point and size
-- set, out of combat, or in combat only where the client says the region isn't protected
-- (IsProtected: a nameplate's unit frame is not; the player frame, a secure unit button, is). The
-- rest is Show, Hide and the texture's art, which are not protected. A mark that can't be placed in
-- combat waits, hidden, for the fight to end.
--
-- The gamepad UI: off there, as the borders (Sylvanistas leaves the game's frames alone there, 0.9.8).
-- Logged in with it, no hook and no texture; switched to it, every mark hides at once and the
-- hooks return without a call; back to mouse and keyboard, the marks come back.
--
-- Cheap: a plate's mark is worked out when a unit is added to it, when its name or guild reaches
-- the client, and when what it was worked out from changes (Borders.Changed: its guild's census
-- report, the High Council's list, our roster, the council's names hidden or shown on the King's
-- screen), only for the plates shown. The game's name update runs many times a second (every
-- health change, mouseover, target and soft-target change, on every compact unit frame, raid
-- frames too), so there nothing is asked of the game about the unit: whether it is a friendly
-- player is worked out when it comes to the plate and again when the game says its faction or
-- flags changed (UNIT_FACTION, UNIT_FLAGS: Forever's own plates look again at a friend on
-- UNIT_FACTION alone), and whether the marks are on (Active) is kept until something it comes from
-- may have changed. A creature's or a hostile player's plate stops at a table lookup; a raid frame
-- after IsForbidden; a marked plate looks again only at its name (shown, and where it starts).
--
-- Switches: `/syl borders off` hides them with the borders, `/syl nameplates on|off` the marks
-- alone (on by default).
--
-- The author's preview (`/syl borders test <tier>`, Borders.SetPreview): that tier's mark on the
-- plate of every friendly player, and after his own name on his player frame, so he sees it
-- without any bar (PlayerFrame.name, the game's PlayerName: textures of Sylvanistas's on the frame's
-- container, anchored to it, made and placed once out of combat, then only shown and hidden, as
-- the borders'). After the name, not left of it (1.1, the 1.0 review): left of it the mark sat on
-- his portrait's ring (Forever's PlayerName starts 4 px right of the 60 px portrait). "member"
-- shows the star alone (no border has it). His screen alone: gone at `/syl borders test off` or a
-- /reload. While it shows, every plate's own mark is still worked out as ever (1.1: a census
-- report heard meanwhile left the mark from before it on the plate once the preview ended).

local Nameplates = {}
ns.Nameplates = Nameplates

local GOLD = "nameplates-icon-elite-gold"
Nameplates.SIZE = 16 -- px, at the classification scale 1 (the game's own mark: 20 at Forever's medium size)
Nameplates.GAP = 2   -- px between the mark and the name's first letter
-- Bronze: the gold without colour, tinted the mean colour of the brightest quarter of his
-- plain frame's opaque pixels (158, 118, 86). The gold's
-- highlights come out as his bright metal, and its golden middle (a gold like 255, 200, 60 is
-- about three quarters of white without colour) near the mean of his frame's brighter half
-- (129, 89, 65).
Nameplates.BRONZE = { 158 / 255, 118 / 255, 86 / 255 }
local WHITE = { 1, 1, 1 }
Nameplates.MARKS = {
	gold = { atlas = GOLD },
	silver = { atlas = "nameplates-icon-elite-silver" },
	bronze = { atlas = GOLD, bronze = true },
	member = { file = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1" }, -- (the game's raid-marker star)
}
Nameplates.ORDER = { "gold", "silver", "bronze", "member" }
-- The author's preview: each border tier's mark (the King's gold wings: his gold), and the star.
Nameplates.PREVIEW = { ["gold-elite"] = "gold", ["silver-elite"] = "silver", gold = "silver", silver = "silver",
	["bronze-elite"] = "bronze", bronze = "bronze", member = "member" }

local rigs = {}   -- [a plate's unit frame] = { tex, frame, name, unit, friend, shown, dressed, point, x, size }
local byUnit = {} -- [nameplate unit] = the rig of the plate showing it
local known = {}  -- [nameplate unit] = { guid, mark, and what it was worked out from (Borders.MarkOf) }
local mine        -- his own name's marks (the preview): { tex = { [mark] = texture }, shown }; false: no such frame
local hooked, waiting = false, false
local active      -- Active as last worked out; nil: to work out again (IsActive)
Nameplates.stats = { computed = 0 } -- (tests, /syl status)

-- Values the client hides from addons (secret values) count as none.
local function Secret(...)
	if type(issecretvalue) ~= "function" then return false end
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) then return true end
	end
	return false
end

function Nameplates.Enabled() return not (ns.db and ns.db.nameplates == false) end

-- On: the borders and the marks on, with mouse and keyboard, for a member of a Sylvanistas guild.
local function Active()
	return ns.Borders.Enabled() == true and Nameplates.Enabled() and not ns.GamepadUI() and ns.IsMember() == true
end

-- Active, kept (the game's name updates come many times a second): worked out again after
-- anything it comes from may have changed. RefreshAll (the two switches, the preview, a login,
-- our own guild, the end of a fight), CensusChanged (the census: the King's guild, say) and a
-- switch of interface style forget it.
local function IsActive()
	if active == nil then active = Active() end
	return active
end

local function InCombat() return InCombatLockdown ~= nil and InCombatLockdown() == true end

-- May Sylvanistas make a texture on this frame, or set this texture's point and size, now? Out of
-- combat, or where the client says it isn't protected.
local function CanTouch(region)
	if not InCombat() then return true end
	local isProtected = region.IsProtected
	if type(isProtected) ~= "function" then return false end
	local ok, protected = pcall(isProtected, region)
	return ok and not Secret(protected) and protected == false
end

-- A forbidden frame: nothing but this is ever called on it.
local function Forbidden(frame)
	local isForbidden = frame.IsForbidden
	if type(isForbidden) ~= "function" then return false end
	local ok, forbidden = pcall(isForbidden, frame)
	return not ok or forbidden ~= false
end

local function AtlasExists(atlas)
	local info = C_Texture and C_Texture.GetAtlasInfo
	if type(info) ~= "function" then return true end
	local ok, v = pcall(info, atlas)
	return ok and v ~= nil
end

-- A plate's unit frame and its name, nil for a forbidden one or one not laid out as Forever's.
local function UnitFrameOf(plate)
	local frame = plate.UnitFrame
	if type(frame) ~= "table" or Forbidden(frame) or type(frame.CreateTexture) ~= "function" then return nil end
	local name = frame.name
	if type(name) ~= "table" or type(name.GetStringWidth) ~= "function" then return nil end
	return frame, name
end

-- The unit frame the game shows a nameplate unit on (the game leaves forbidden plates out, and
-- so does Sylvanistas).
local function FrameOf(unit)
	local get = C_NamePlate and C_NamePlate.GetNamePlateForUnit
	if type(get) ~= "function" then return nil end
	local ok, plate = pcall(get, unit)
	if not ok or type(plate) ~= "table" or Forbidden(plate) then return nil end
	return UnitFrameOf(plate)
end

local function IsPlateUnit(unit) return type(unit) == "string" and unit:find("^nameplate%d") ~= nil end

-- A friendly player's plate, as the game decides it (NamePlateUnitFrameMixin:UpdateIsFriend: a
-- player of the other faction in our party outside an instance can be attacked, so is not
-- friendly), and not our own (the personal resource display). Nil while the client hides it
-- (asked again next time).
local function FriendlyPlayer(unit)
	local player = UnitIsPlayer(unit)
	if Secret(player) then return nil end
	if player ~= true then return false end -- (a creature: nothing more to ask)
	local me = UnitIsUnit and UnitIsUnit(unit, "player")
	local friend = UnitIsFriend and UnitIsFriend("player", unit)
	local attack = UnitCanAttack and UnitCanAttack("player", unit)
	if Secret(me, friend, attack) then return nil end
	return me ~= true and friend == true and attack ~= true
end

-- Is the plate's unit a friendly player? Worked out once for the unit on the plate (fresh: again).
local function Friend(rig, fresh)
	if fresh or rig.friend == nil then
		local unit = rig.unit
		if not UnitExists(unit) then
			rig.friend = nil
			return false
		end
		rig.friend = FriendlyPlayer(unit)
	end
	return rig.friend == true
end

-- A mark's art on a texture: the game's atlas at the texture's size (the bronze without colour,
-- then tinted), or Sylvanistas's star. False when the client has none of it.
local function Dress(tex, mark)
	local m = Nameplates.MARKS[mark]
	if not m then return false end
	if m.file then
		local ok, loaded = pcall(tex.SetTexture, tex, m.file)
		if not ok or loaded == false then return false end
		tex:SetTexCoord(0, 1, 0, 1)
	else
		if not AtlasExists(m.atlas) then return false end
		tex:SetAtlas(m.atlas)
	end
	tex:SetDesaturated(m.bronze == true)
	local c = m.bronze and Nameplates.BRONZE or WHITE
	tex:SetVertexColor(c[1], c[2], c[3])
	return true
end

-- The mark's size: the game's classification mark grows with the plates (Forever's
-- NamePlateSetupOptions.classificationScale), and so does the name.
local function Size()
	local o = NamePlateSetupOptions
	local scale = type(o) == "table" and tonumber(o.classificationScale) or nil
	if not scale or scale <= 0 or scale > 4 then scale = 1 end
	return Nameplates.SIZE * scale
end

-- Where the mark's right edge goes on the name: just left of its first letter. Nil for a name
-- with no text, or a width the client hides.
local function Spot(name)
	local justify = type(name.GetJustifyH) == "function" and name:GetJustifyH() or "CENTER"
	local width = name:GetStringWidth()
	local box = type(name.GetWidth) == "function" and name:GetWidth() or nil
	if Secret(justify, width, box) or type(width) ~= "number" or width <= 0 then return nil end
	if type(box) == "number" and box > 0 and width > box then width = box end -- (a name cut short)
	local gap = Nameplates.GAP
	if justify == "LEFT" then return "LEFT", -gap end
	if justify == "RIGHT" then return "RIGHT", -math.floor(width + gap + 0.5) end
	return "CENTER", -math.floor(width / 2 + gap + 0.5)
end

-- The mark put left of the name: true; false when it can't go there (no text); "later" when it
-- could, but not in combat.
local function Place(rig)
	local point, x = Spot(rig.name)
	if not point then return false end
	local size = Size()
	if rig.point == point and rig.x == x and rig.size == size then return true end
	if not CanTouch(rig.tex) then return "later" end
	rig.tex:ClearAllPoints()
	rig.tex:SetSize(size, size)
	rig.tex:SetPoint("RIGHT", rig.name, point, x, 0)
	rig.point, rig.x, rig.size = point, x, size
	return true
end

local function Hide(rig)
	if rig.shown then rig.tex:Hide() end
	rig.shown = nil
end

local function NameShown(name)
	if type(name.IsShown) ~= "function" then return true end
	local shown = name:IsShown()
	return not Secret(shown) and shown == true
end

-- A mark on a plate (nil: none), left of its name while the name shows.
local function Show(rig, mark)
	if not mark or not NameShown(rig.name) then return Hide(rig) end
	if rig.dressed ~= mark then
		if not Dress(rig.tex, mark) then
			rig.dressed = nil
			return Hide(rig)
		end
		rig.dressed = mark
	end
	local placed = Place(rig)
	if placed ~= true then
		if placed == "later" then waiting = true end
		return Hide(rig)
	end
	if not rig.shown then rig.tex:Show() end
	rig.shown = mark
end

local function Compute(unit, guid)
	Nameplates.stats.computed = Nameplates.stats.computed + 1
	local mark, k = ns.Borders.MarkOf(unit)
	k.guid, k.mark = guid, mark
	known[unit] = k
	return k
end

-- A plate's mark again: the one worked out for its unit while it is the same player (fresh: work
-- it out again, and whether it is a friendly player); the preview's tier for any friendly player
-- while the author's preview is on.
-- (Worked out while the preview shows too, as the borders are: what the census, the council's
-- list or our roster said meanwhile is the plate's own mark once the preview ends.)
local function Refresh(rig, fresh)
	local unit = rig.unit
	if not unit or not IsActive() or not Friend(rig, fresh) then return Hide(rig) end
	local guid = UnitGUID and UnitGUID(unit)
	if Secret(guid) then guid = nil end
	local k = known[unit]
	if fresh or not k or guid == nil or k.guid ~= guid then k = Compute(unit, guid) end
	local preview = ns.Borders.Preview()
	if preview then return Show(rig, Nameplates.PREVIEW[preview]) end
	Show(rig, k.mark)
end

-- The game wrote the name of the same friendly player again (his health, a mouseover, a target
-- change): nothing asked about him, the mark worked out for him put back by his name, or hidden
-- with it.
local function Again(rig)
	if not IsActive() then return Hide(rig) end
	local preview = ns.Borders.Preview()
	if preview then return Show(rig, Nameplates.PREVIEW[preview]) end
	local k = known[rig.unit]
	if not k then return Refresh(rig) end
	Show(rig, k.mark)
end

-- Once, with mouse and keyboard: the hook on the game's name updates (it runs for every compact
-- unit frame, raid frames too: those leave after IsForbidden).
local function Install()
	if hooked or ns.GamepadUI() then return end
	hooked = true
	if type(hooksecurefunc) == "function" and type(CompactUnitFrame_UpdateName) == "function" then
		hooksecurefunc("CompactUnitFrame_UpdateName", function(frame)
			ns.SafeCall("nameplates name", Nameplates.NameUpdated, frame)
		end)
	end
end

-- A plate's unit frame's rig, made the first time it is seen (where a texture may be made now).
local function RigOf(frame, name)
	local rig = rigs[frame]
	if rig then return rig end
	if not CanTouch(frame) then
		waiting = true
		return nil
	end
	local tex = frame:CreateTexture(nil, "OVERLAY", nil, 1)
	tex:Hide()
	rig = { tex = tex, frame = frame, name = name }
	rigs[frame] = rig
	-- The game lays the plate out again (another style, names only or not): the mark follows.
	if type(frame.UpdateAnchors) == "function" and type(hooksecurefunc) == "function" then
		hooksecurefunc(frame, "UpdateAnchors", function(self) ns.SafeCall("nameplates layout", Nameplates.Follow, self) end)
	end
	return rig
end

-- The plate's unit frame now shows `unit`: its rig goes with it.
local function Attach(unit, frame, name)
	local rig = RigOf(frame, name)
	if not rig then return nil end
	if rig.unit ~= unit then
		if rig.unit and byUnit[rig.unit] == rig then byUnit[rig.unit] = nil end
		local old = byUnit[unit]
		if old and old ~= rig then
			old.unit, old.friend = nil, nil
			Hide(old)
		end
		rig.unit, rig.friend = unit, nil
		byUnit[unit] = rig
	end
	return rig
end

local function Detach(rig)
	if rig.unit and byUnit[rig.unit] == rig then byUnit[rig.unit] = nil end
	rig.unit, rig.friend = nil, nil
	Hide(rig)
end

-- Where his own name's marks go: just after the name's last letter, GAP px off (a name longer than
-- its box ends at the box: Forever's is 96 px, with nothing of the game's right of it but the
-- group role icon, 12 px further on). Its left edge's point on the name and how far from it.
function Nameplates.MineSpot(name)
	local justify = type(name.GetJustifyH) == "function" and name:GetJustifyH() or "LEFT"
	local width = name:GetStringWidth()
	local box = type(name.GetWidth) == "function" and name:GetWidth() or nil
	local gap = Nameplates.GAP
	if Secret(justify, width, box) or type(width) ~= "number" or width <= 0 then return "RIGHT", gap end
	if type(box) == "number" and box > 0 and width > box then width = box end
	if justify == "RIGHT" then return "RIGHT", gap end
	if justify == "CENTER" then return "CENTER", math.floor(width / 2 + gap + 0.5) end
	return "LEFT", math.floor(width + gap + 0.5)
end

-- His own name's marks (the preview): made once out of combat on the player frame's container,
-- anchored after his name. A client without Forever's player frame gets none.
local function InstallMine()
	local frame = PlayerFrame
	local container = type(frame) == "table" and rawget(frame, "PlayerFrameContainer") or nil
	local name = type(frame) == "table" and rawget(frame, "name") or nil
	if type(container) ~= "table" or type(container.CreateTexture) ~= "function" or type(name) ~= "table" then
		mine = false
		return
	end
	if InCombat() then
		waiting = true
		return
	end
	mine = { tex = {} }
	local point, x = Nameplates.MineSpot(name)
	for _, key in ipairs(Nameplates.ORDER) do
		local tex = container:CreateTexture(nil, "OVERLAY", nil, 7)
		tex:Hide()
		if Dress(tex, key) then
			tex:SetSize(Nameplates.SIZE, Nameplates.SIZE)
			tex:SetPoint("LEFT", name, point, x, 0)
			mine.tex[key] = tex
		end
	end
	ns.Log("nameplates: the preview's marks set up on the player frame")
end

local function ShowMine(key)
	if not mine or mine.shown == key then return end
	if mine.shown and mine.tex[mine.shown] then mine.tex[mine.shown]:Hide() end
	mine.shown = nil
	if key and mine.tex[key] then
		mine.tex[key]:Show()
		mine.shown = key
	end
end

-- His own name's mark: the preview's while it is on, none otherwise.
local function RefreshMine()
	local preview = IsActive() and ns.Borders.Preview() or nil
	local key = preview and Nameplates.PREVIEW[preview] or nil
	if key and mine == nil then InstallMine() end
	ShowMine(key)
end

local function HideAll()
	for _, rig in pairs(rigs) do Hide(rig) end
	ShowMine(nil)
end

-- Every plate shown now (C_NamePlate.GetNamePlates: the game leaves forbidden ones out), and his
-- own name's mark.
function Nameplates.RefreshAll(fresh)
	active = nil
	if not IsActive() then return HideAll() end
	Install()
	local list = C_NamePlate and C_NamePlate.GetNamePlates
	local ok, plates = false, nil
	if type(list) == "function" then ok, plates = pcall(list) end
	if ok and type(plates) == "table" then
		for _, plate in pairs(plates) do
			if type(plate) == "table" and not Forbidden(plate) then
				local frame, name = UnitFrameOf(plate)
				local unit = frame and frame.unit
				if IsPlateUnit(unit) then
					local rig = Attach(unit, frame, name)
					if rig then Refresh(rig, fresh) end
				end
			end
		end
	end
	RefreshMine()
end

-- NAME_PLATE_UNIT_ADDED. The game's own handler gives the plate its unit frame: where ours runs
-- first there is none yet, and the hook on its name update (just after) puts the mark on.
function Nameplates.Added(unit, again)
	if not IsActive() then return end
	Install()
	local frame, name = FrameOf(unit)
	if not frame then
		if not again then ns.After(0, "nameplates added", function() Nameplates.Added(unit, true) end) end
		return
	end
	local rig = Attach(unit, frame, name)
	if rig then Refresh(rig) end
end

-- NAME_PLATE_UNIT_REMOVED: its mark goes (its unit frame goes back to the game's pool).
function Nameplates.Removed(unit)
	known[unit] = nil
	local rig = byUnit[unit]
	if rig then Detach(rig) end
end

-- After the game's CompactUnitFrame_UpdateName: a plate's name written, shown or hidden. The game
-- runs it many times a second for every compact unit frame (raid frames, and its forbidden plates
-- too). A plate of ours showing the same unit: a table lookup for a creature or a hostile player,
-- its name looked at for a friendly one. A frame with no mark of ours is looked at only while the
-- marks are on, and a forbidden one no further than IsForbidden.
function Nameplates.NameUpdated(frame)
	if type(frame) ~= "table" then return end
	local rig = rigs[frame]
	if rig then
		local unit = frame.unit
		if unit ~= nil and unit == rig.unit then
			if rig.friend == false then return end -- (hidden since the unit came)
			if rig.friend == true then return Again(rig) end
			return Refresh(rig)
		end
		if not IsPlateUnit(unit) then return Detach(rig) end
		Attach(unit, frame, rig.name)
		return Refresh(rig)
	end
	if not IsActive() or Forbidden(frame) then return end
	local unit = frame.unit
	if not IsPlateUnit(unit) then return end
	local f, name = FrameOf(unit)
	if f ~= frame then return end
	rig = Attach(unit, frame, name)
	if rig then Refresh(rig) end
end

-- After the game's UpdateAnchors on a plate's unit frame: the name may have moved.
function Nameplates.Follow(frame)
	local rig = rigs[frame]
	if not rig or not rig.shown then return end
	if not IsActive() then return Hide(rig) end
	Show(rig, rig.shown)
end

-- The census, the High Council's list, our roster or the council's names hidden or shown on the
-- King's screen changed: only a plate shown whose mark was worked out from something that changed
-- since is worked out again. (The census may also make our guild Sylvanistas, or not: every plate.)
function Nameplates.CensusChanged()
	local was = active
	active = nil
	if not IsActive() then return HideAll() end
	if was == false then return Nameplates.RefreshAll(true) end
	for unit, k in pairs(known) do
		local rig = byUnit[unit]
		if rig and ns.Borders.Changed(k) then Refresh(rig, true) end
	end
end

-- A unit's faction or flags changed (a duel begun or ended, a player mind-controlled): whether
-- its plate shows a friendly player is worked out again; ours: every plate's (Forever's own plates
-- look again at a friend on UNIT_FACTION, for their unit and ours).
function Nameplates.FactionChanged(unit, all)
	if all then
		for _, rig in pairs(byUnit) do
			rig.friend = nil
			Refresh(rig)
		end
		return
	end
	local rig = byUnit[unit]
	if not rig then return end
	rig.friend = nil
	Refresh(rig)
end

function Nameplates.Report()
	if not Nameplates.Enabled() then return ns.Print(L.NAMEPLATES_OFF) end
	if ns.Borders.Enabled() ~= true then return ns.Print(L.NAMEPLATES_BORDERS_OFF) end
	ns.Print(L.NAMEPLATES_ON)
	if ns.GamepadUI() then ns.Print(L.NAMEPLATES_GAMEPAD) end
end

-- `/syl nameplates on|off`: the marks alone (the borders stay as they are).
function Nameplates.SetEnabled(on)
	ns.db.nameplates = on and true or false
	Nameplates.RefreshAll(true)
	Nameplates.Report()
end

function Nameplates.StatusLine()
	local state = "on"
	if not Nameplates.Enabled() then state = "off (/syl nameplates on)"
	elseif ns.Borders.Enabled() ~= true then state = "off with the borders (/syl borders on)"
	elseif ns.GamepadUI() then state = "on, hidden with the gamepad UI" end
	local plates, count = 0, {}
	for _, rig in pairs(byUnit) do
		plates = plates + 1
		if rig.shown then count[rig.shown] = (count[rig.shown] or 0) + 1 end
	end
	local marks = {}
	for _, key in ipairs(Nameplates.ORDER) do
		if count[key] then marks[#marks + 1] = key .. " " .. count[key] end
	end
	return ("%s  |  %d plates, marks: %s  |  worked out %d times%s%s"):format(state, plates,
		#marks > 0 and table.concat(marks, ", ") or "none", Nameplates.stats.computed,
		waiting and "  |  some wait for combat to end" or "", mine and mine.shown and ("  |  your name: " .. mine.shown) or "")
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

ns.On("LOGIN", function() Nameplates.RefreshAll(true) end)
ns.On("DATA_CHANGED", function() Nameplates.CensusChanged() end)
-- The King shows or hides the council's names (the eye in the Realm, ns.SetCouncilNamesShown).
ns.On("COUNCIL_MASK_CHANGED", function() Nameplates.CensusChanged() end)
-- Registered where the client has them.
pcall(ns.RegisterEvent, "NAME_PLATE_UNIT_ADDED", function(unit) Nameplates.Added(unit) end)
pcall(ns.RegisterEvent, "NAME_PLATE_UNIT_REMOVED", function(unit) Nameplates.Removed(unit) end)
-- A plate's name or guild reaching the client (or ours changing: every plate again).
ns.RegisterEvent("UNIT_NAME_UPDATE", function(unit)
	local rig = byUnit[unit]
	if rig then Refresh(rig, true) end
end)
ns.RegisterEvent("PLAYER_GUILD_UPDATE", function(unit)
	if unit == nil or unit == "player" then return Nameplates.RefreshAll(true) end
	local rig = byUnit[unit]
	if rig then Refresh(rig, true) end
end)
pcall(ns.RegisterEvent, "UNIT_FACTION", function(unit) Nameplates.FactionChanged(unit, unit == "player") end)
pcall(ns.RegisterEvent, "UNIT_FLAGS", function(unit) if unit ~= "player" then Nameplates.FactionChanged(unit) end end)
ns.RegisterEvent("PLAYER_REGEN_ENABLED", function()
	if not waiting then return end
	waiting = false
	Nameplates.RefreshAll()
end)
-- A switch between mouse and keyboard and the gamepad UI (as the borders): to the gamepad UI,
-- every mark hides at once; either way they are looked at again just after.
pcall(ns.RegisterEvent, "INPUT_DEVICE_INTERFACE_TRANSITION", function(newMode)
	local gamepad = Enum and Enum.InputDeviceInterfaceType and Enum.InputDeviceInterfaceType.Gamepad
	if gamepad ~= nil and newMode == gamepad then
		active = false
		HideAll()
	else
		active = nil
	end
	ns.After(0.2, "nameplates style", function() Nameplates.RefreshAll(true) end)
end)
