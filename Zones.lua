local ADDON, ns = ...

-- The guild roster gives zone names as localized text. We turn them into uiMapIDs so
-- players on different client languages agree, and so the map knows where to draw.
-- 1.1: the zones outside Azeroth too. TBC Anniversary's Outland (and whatever new world a
-- client ships) hangs under the Cosmic map (946), not under Azeroth (947): a zone there had no
-- map id, so the census showed it as plain text and the world map left it out. Azeroth is still
-- walked first, the way 1.0 did it, so every name 1.0 knew keeps the id it had (clients of both
-- versions send the same keys); the other top maps only add the names Azeroth has not. A name
-- still missing then (a zone a new patch hung somewhere else) sets off one scan of every map id,
-- once a session; a name even that can't place stays text, and /syl status and /syl bug list it.

local Zones = {}
ns.Zones = Zones

local ROOT_MAP = 947   -- Azeroth
local COSMIC_MAP = 946 -- the top of the map tree: Azeroth, and Outland on TBC clients
Zones.SCAN_MAX = 5000  -- map ids the scan at a miss reads (well past the ids Classic clients use today)
Zones.UNMAPPED_MAX = 100 -- names kept that no map id matched (for /syl status: names only)

local byName, count
local scanned = false  -- the scan of every map id ran this session
local unmapped = {}    -- [name] = true: no map id matched it, even after the scan
local unmappedCount = 0

local function ZoneType()
	return (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
end

-- 1.0's rule, for the Azeroth tree: the first map of a name, or a zone of that name later on.
local function Add(info)
	if info and info.name and info.name ~= "" then
		if not byName[info.name] or info.mapType == ZoneType() then
			if not byName[info.name] then count = count + 1 end
			byName[info.name] = info.mapID
		end
	end
end

-- Outside the Azeroth tree: the same rule, for the names Azeroth did not have alone.
local function AddNew(info, taken)
	if info and info.name and not taken[info.name] then Add(info) end
end

-- Every map under `root` (its children, theirs...), each once (`visited`), through `add`.
local function Walk(root, visited, add)
	local queue = { root }
	while #queue > 0 do
		local id = table.remove(queue)
		if not visited[id] then
			visited[id] = true
			local children = C_Map.GetMapChildrenInfo(id)
			if children then
				for _, info in ipairs(children) do
					add(info)
					queue[#queue + 1] = info.mapID
				end
			end
		end
	end
end

-- The top of the tree above `mapID` (its parents, theirs...), or nil.
local function TopOf(mapID)
	if not (mapID and C_Map.GetMapInfo) then return nil end
	local id, top = mapID, nil
	for _ = 1, 12 do
		local info = C_Map.GetMapInfo(id)
		if not info then break end
		top = id
		local parent = info.parentMapID
		if not parent or parent == 0 or parent == id then break end
		id = parent
	end
	return top
end

local function Build()
	byName, count = {}, 0
	if not (C_Map and C_Map.GetMapChildrenInfo) then return end
	local visited = {}
	Walk(ROOT_MAP, visited, Add)
	-- The rest of the world: the Cosmic map, and the top of the map the player stands on (a new
	-- client may hang its worlds somewhere else again).
	local taken = {}
	for name in pairs(byName) do taken[name] = true end
	local here = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	for _, root in ipairs({ COSMIC_MAP, TopOf(here) }) do
		Walk(root, visited, function(info) AddNew(info, taken) end)
	end
	-- Fallback if the map tree is different on this client (e.g. a new game version).
	if count == 0 and C_Map.GetMapInfo then
		for id = 1, 2500 do Add(C_Map.GetMapInfo(id)) end
	end
	ns.Log("zones indexed: %d", count)
end

-- Every map id, once a session, at the first name nothing matched: the names the tree left
-- out get the zone of that name (or, without one, the first map of it). Nothing the tree
-- matched changes.
local function Scan()
	scanned = true
	if not (C_Map and C_Map.GetMapInfo) then return end
	local before, taken = count, {}
	for name in pairs(byName) do taken[name] = true end
	local zone, isZone = ZoneType(), {}
	for id = 1, Zones.SCAN_MAX do
		local info = C_Map.GetMapInfo(id)
		local name = info and info.name
		if name and name ~= "" and not taken[name] then
			if byName[name] == nil then
				count = count + 1
				byName[name], isZone[name] = id, info.mapType == zone
			elseif info.mapType == zone and not isZone[name] then
				byName[name], isZone[name] = id, true
			end
		end
	end
	ns.Log("zones: a name had no map id; the scan of %d map ids found %d more", Zones.SCAN_MAX, count - before)
end

function Zones.Count()
	return count or 0
end

-- The zone names no map id matched this session, sorted (names only, as the roster gives them).
function Zones.Unmapped()
	local out = {}
	for name in pairs(unmapped) do out[#out + 1] = name end
	table.sort(out)
	return out, unmappedCount
end

-- For /syl status and /syl bug: "none", or how many and which.
function Zones.UnmappedLine()
	local list, n = Zones.Unmapped()
	if n == 0 then return "none" end
	local shown = {}
	for i = 1, math.min(8, #list) do shown[i] = list[i] end
	return ("%d%s: %s%s"):format(n, n >= Zones.UNMAPPED_MAX and "+" or "", table.concat(shown, ", "), n > #shown and (", +" .. (n - #shown)) or "")
end

function Zones.KeyForName(name)
	if not name or name == "" then return nil end
	if not byName then Build() end
	local id = byName[name]
	if not id and not scanned then
		Scan()
		id = byName[name]
	end
	if id then return "m" .. id end
	if not unmapped[name] and unmappedCount < Zones.UNMAPPED_MAX then
		unmapped[name], unmappedCount = true, unmappedCount + 1
		ns.Log("zone without a map id: %s", name)
	end
	return "t" .. name
end

-- Tests: the index is built again at the next name.
function Zones.Reset()
	byName, count, scanned = nil, nil, false
	wipe(unmapped)
	unmappedCount = 0
end

function Zones.MapID(key)
	if key and key:sub(1, 1) == "m" then return tonumber(key:sub(2)) end
	return nil
end

function Zones.NameForKey(key)
	local id = Zones.MapID(key)
	if id then
		local info = C_Map.GetMapInfo(id)
		return info and info.name or key
	end
	-- A zone a report named as text: shown as plain text, whatever it carries (0.9.2).
	return ns.Codec.Plain((key or "?"):sub(2))
end
