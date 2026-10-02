local ADDON, ns = ...

-- Loaded first (before the libraries), so that:
-- 1. errors raised while the rest of the addon loads are still captured (Diagnostics
--    stores them once the SavedVariables are ready), and
-- 2. the world map exists before HereBeDragons-Pins hooks into it. On some clients
--    (Classic Era) Blizzard_WorldMap is load-on-demand and the library breaks without it.

ns.earlyErrors = {}

-- The errors of Sylvanistas's own files seen this session, deduplicated (0.9.2: nothing of any
-- other addon's). Kept in the SavedVariables so we can see errors our own frames cause
-- inside Blizzard code: the message names a Blizzard file then, the stack ours.
ns.allErrors = {}
local index = {}
local others, nOthers = {}, 0 -- the other addons' errors seen, 200 at most

-- Ours: the message names one of our files, or a line of the stack does. Not this handler's
-- own line, which tops every stack it reads (the culprit comes below it).
local OURS = "AddOns[\\/]Sylvanistas[\\/]"
local HANDLER = "AddOns[\\/]Sylvanistas[\\/]Bootstrap%.lua"
function ns.OwnError(msg, stack)
	if tostring(msg or ""):find(OURS) then return true end
	for line in tostring(stack or ""):gmatch("[^\n]+") do
		if line:find(OURS) and not line:find(HANDLER) then return true end
	end
	return false
end

-- Not with Blizzard's gamepad UI on (WoW: Forever): every error would then run the game's
-- error window from this handler, which the game blocks there (see Dialog.lua).
local function GamepadUI()
	local current = C_InputInterfaceStyle and C_InputInterfaceStyle.GetCurrentStyle
	local gamepad = Enum and Enum.InputDeviceInterfaceType and Enum.InputDeviceInterfaceType.Gamepad
	if not current or gamepad == nil then return false end
	local ok, style = pcall(current)
	return ok and style == gamepad
end

-- Every error still goes on to the handler that was there before, as it came, whatever this
-- one makes of it (a tail call: that handler reads the same stack as without us).
local previous = not GamepadUI() and geterrorhandler()
if previous then seterrorhandler(function(err, ...)
	local ok = pcall(function()
		local msg = tostring(err)
		local key = msg:sub(1, 240)
		local e = index[key]
		if e then
			e.count = e.count + 1
		elseif others[key] then
			return
		elseif #ns.allErrors < 40 then
			local stack = debugstack and debugstack(3, 10, 0) or ""
			-- Another addon's (or Blizzard's, with none of our files in it): not ours to keep.
			-- One that names another addon's file is known at once when it repeats (its stack
			-- is not read again); Blizzard's are read again, our calls may cause them next time.
			if not ns.OwnError(msg, stack) then
				if nOthers < 200 and msg:find("AddOns[\\/]") then others[key], nOthers = true, nOthers + 1 end
				return
			end
			e = { msg = msg, count = 1, stack = stack, t = date and date("%H:%M:%S") }
			index[key] = e
			ns.allErrors[#ns.allErrors + 1] = e
		end
		if msg:find(OURS) then
			if ns.CaptureError and ns.db then
				ns.CaptureError("global", msg)
			elseif #ns.earlyErrors < 20 then
				ns.earlyErrors[#ns.earlyErrors + 1] = { msg, debugstack and debugstack(3, 10, 0) or "" }
			end
		end
	end)
	return previous(err, ...)
end) end

if not WorldMapFrame then
	local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
	if load then pcall(load, "Blizzard_WorldMap") end
end
