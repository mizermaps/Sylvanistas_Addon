local ADDON, ns = ...

-- Sylvanistas's own dialogs, for Blizzard's gamepad UI (WoW: Forever) alone. There the game's
-- popups break when an addon opens one: StaticPopup_Show from addon code runs the gamepad
-- popup handler tainted, which moves the gamepad action bar's interact target at once
-- (SetPreferredGamepadInteractTarget, Blizzard's only), and the game blocks it ("Sylvanistas has
-- been blocked from an action only available to the Blizzard UI"). From then on every popup
-- that opens or closes is blocked again, each block opening one more popup: the game freezes.
-- So with the gamepad UI on, Sylvanistas never opens a game popup: it shows the same dialog (the
-- same StaticPopupDialogs entry, the same arguments) in a window of its own, answered with
-- the mouse. With mouse and keyboard the game's popups are used, as always (ns.ShowDialog).
-- Like the game's: button1 OnAccept, button2 OnCancel(self, data, "clicked"), button3 OnAlt;
-- a handler returning true keeps it open; the timeout hides it, then OnCancel(self, data,
-- "timeout"); a fourth dialog takes the oldest's place, OnCancel(self, data, "override");
-- OnShow and OnHide(self, data); an edit box (self.editBox, its parent the dialog) with
-- EditBoxOnEnterPressed and EditBoxOnEscapePressed(editBox, data), Enter doing nothing else.
-- Like the game's popups too, they stay up through death, loading screens and the game's
-- window sweeps (they are not in UISpecialFrames), and are only answered by a click.
-- 1.1.2: a definition's `extra` = { label, shown(self, data), onClick(self, data) } adds a button
-- after the others that answers nothing and keeps the dialog up (the Answers of the author, the
-- High Council and the Stewards in Sylvanistas's whisper windows: UI.lua). The game's popups have no
-- such button: a dialog that needs it is shown here in both input modes (Dialog.Show).
-- An edit box here never takes the keyboard from another one (the chat's): its focus change
-- would run the game's gamepad code from ours, the same block (ns.Focus).

local Dialog = {}
ns.Dialog = Dialog

Dialog.MAX = 3        -- dialogs up at once; one more takes the oldest's place
Dialog.TOP = -135     -- where the game's first popup sits
Dialog.GAP = 8

local frames = {}     -- built once, reused
local order = 0       -- to know the oldest
local hinted          -- the player told once a session: these are answered with the mouse

local function Def(which) return type(which) == "string" and StaticPopupDialogs and StaticPopupDialogs[which] or nil end
local function Call(f, where, fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, res = pcall(fn, ...)
	if not ok then
		if ns.CaptureError then ns.CaptureError("dialog " .. tostring(f.which) .. " " .. where, res) end
		return nil
	end
	return res
end

-- Stacked from the top, under the game's own popups when some are up.
local function Layout()
	local anchor, point, y = UIParent, "TOP", Dialog.TOP
	for i = 1, 4 do
		local p = _G["StaticPopup" .. i]
		if p and p.IsShown and p:IsShown() then anchor, point, y = p, "BOTTOM", -Dialog.GAP end
	end
	local shown = {}
	for _, f in ipairs(frames) do if f:IsShown() then shown[#shown + 1] = f end end
	table.sort(shown, function(a, b) return a.order < b.order end)
	for _, f in ipairs(shown) do
		f:ClearAllPoints()
		f:SetPoint("TOP", anchor, point, 0, y)
		anchor, point, y = f, "BOTTOM", -Dialog.GAP
	end
end

-- The game's popups, as last seen: when one comes or goes, ours move under it.
local function GamePopups()
	local n = 0
	for i = 1, 4 do
		local p = _G["StaticPopup" .. i]
		if p and p.IsShown and p:IsShown() then n = n + i * 10 end
	end
	return n
end

local function Click(f, index)
	local def, data = f.def, f.data
	if not def or not f:IsShown() then return end
	local keep
	if index == 1 then
		keep = Call(f, "accept", def.OnAccept or def.OnButton1, f, data, f.data2)
	elseif index == 2 then
		keep = Call(f, "cancel", def.OnCancel or def.OnButton2, f, data, "clicked")
	else
		Call(f, "alt", def.OnAlt, f, data, "clicked")
	end
	if not keep and f.def == def and f:IsShown() then
		f.closing = "clicked"
		f:Hide()
	end
end

local function Button(f, index)
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetHeight(22)
	b:SetScript("OnClick", function() Click(f, index) end)
	return b
end

local function Build(i)
	local f = CreateFrame("Frame", "SylvanistasDialog" .. i, UIParent)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:Hide()
	local okBorder, border = pcall(CreateFrame, "Frame", nil, f, "DialogBorderTemplate")
	if not okBorder or not border then
		border = f:CreateTexture(nil, "BACKGROUND")
		border:SetColorTexture(0, 0, 0, 0.85)
	end
	border:SetAllPoints()
	f.text = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	f.text:SetPoint("TOP", 0, -18)
	f.text:SetJustifyH("CENTER")
	local okBox, eb = pcall(CreateFrame, "EditBox", "SylvanistasDialog" .. i .. "EditBox", f, "InputBoxTemplate")
	if not okBox or not eb then eb = CreateFrame("EditBox", nil, f) end
	eb.sylvanistasBox = true
	-- The definitions' OnShow focus the box (eb:SetFocus()): not away from the chat.
	local setFocus = eb.SetFocus
	eb.SetFocus = function(self) ns.Focus(self, setFocus) end
	eb:SetAutoFocus(false)
	-- Like the game's popup box: no select-all on focus (InputBoxTemplate's), or the first key
	-- would replace what the dialog put in it (a recruit message, a Board note).
	eb:SetScript("OnEditFocusGained", nil)
	eb:SetScript("OnEditFocusLost", nil)
	eb:SetHeight(22)
	eb:SetFontObject("ChatFontNormal")
	eb:SetScript("OnEnterPressed", function(self)
		local def = f.def
		if not def then return end
		if def.EditBoxOnEnterPressed then Call(f, "enter", def.EditBoxOnEnterPressed, self, f.data) end
	end)
	eb:SetScript("OnEscapePressed", function(self)
		local def = f.def
		if def and def.EditBoxOnEscapePressed then Call(f, "escape", def.EditBoxOnEscapePressed, self, f.data)
		else self:ClearFocus() end
	end)
	f.editBox, f.EditBox = eb, eb
	f.buttons = { Button(f, 1), Button(f, 2), Button(f, 3) }
	f.extraButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.extraButton:SetHeight(22)
	f.extraButton:SetScript("OnClick", function()
		local extra = f.def and f.def.extra
		if f:IsShown() and type(extra) == "table" then Call(f, "extra", extra.onClick, f, f.data) end
	end)
	f.extraButton:Hide()
	f:SetScript("OnUpdate", function(self, elapsed)
		self.look = (self.look or 0) + elapsed
		if self.look > 0.25 then
			self.look = 0
			local popups = GamePopups()
			if popups ~= self.popups then self.popups = popups; Layout() end
		end
		if not self.left then return end
		self.left = self.left - elapsed
		if self.left > 0 then return end
		self.left = nil
		local def, data = self.def, self.data
		self.closing = "timeout"
		self:Hide()
		if def then Call(self, "timeout", def.OnCancel, self, data, "timeout") end
	end)
	f:SetScript("OnHide", function(self)
		if self:IsShown() then return end -- the whole interface hidden (Alt+Z): still waiting
		local def, data = self.def, self.data
		self.def, self.which, self.data, self.data2, self.left, self.closing = nil, nil, nil, nil, nil, nil
		if self.editBox then self.editBox:ClearFocus() end
		if def then Call(self, "hide", def.OnHide, self, data) end
		Layout()
	end)
	return f
end

-- A free window: a hidden one, a new one, or the oldest.
local function Free()
	for _, f in ipairs(frames) do if not f:IsShown() then return f end end
	if #frames < Dialog.MAX then
		frames[#frames + 1] = Build(#frames + 1)
		return frames[#frames]
	end
	local oldest = frames[1]
	for _, f in ipairs(frames) do if f.order < oldest.order then oldest = f end end
	-- Its question unanswered: cancelled, as the game does when it reuses a popup.
	local def, data = oldest.def, oldest.data
	oldest.closing = "replaced"
	oldest:Hide()
	if def then Call(oldest, "override", def.OnCancel, oldest, data, "override") end
	return oldest
end

function Dialog.Find(which, data)
	for _, f in ipairs(frames) do
		if f:IsShown() and f.which == which and (data == nil or f.data == data) then return f end
	end
	return nil
end

-- As StaticPopup_Show: the dialog, its text formatted with a and b, data for its handlers.
function Dialog.Show(which, a, b, data)
	local def = Def(which)
	if not def then return nil end
	-- The same one up already: this one takes its place, and it is told so like the game's
	-- tells it (OnCancel "override", 0.9.2): a line held by the first is not lost silently.
	local old = Dialog.Find(which)
	if old then
		old.closing = "replaced"
		local cancel = old.def and old.def.OnCancel
		if cancel then pcall(cancel, old, old.data, "override") end
		old:Hide()
	end
	local f = Free()
	order = order + 1
	f.order, f.which, f.def, f.data, f.closing, f.popups = order, which, def, data, nil, GamePopups()
	f.left = (tonumber(def.timeout) or 0) > 0 and tonumber(def.timeout) or nil
	local text = tostring(def.text or "")
	if a ~= nil or b ~= nil then
		local ok, res = pcall(string.format, text, a, b)
		if ok then text = res end
	end
	f.text:SetText(text)
	-- Width: the game's 320, wider for a wide edit box or long buttons.
	local width = 320
	local eb = f.editBox
	if def.hasEditBox then
		local boxW = tonumber(def.editBoxWidth) or 130
		eb:SetWidth(boxW)
		eb:SetMaxLetters(tonumber(def.maxLetters) or 0)
		if eb.SetMaxBytes then eb:SetMaxBytes(tonumber(def.maxBytes) or 0) end
		eb:SetText("")
		eb:Show()
		width = math.max(width, boxW + 60)
	else
		eb:Hide()
	end
	local labels, used = { def.button1, def.button2, def.button3 }, {}
	for i, b in ipairs(f.buttons) do
		if labels[i] then
			b:SetText(labels[i])
			local fs = b:GetFontString()
			local textW = fs and (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()) or 100
			b:SetWidth(math.max(120, math.ceil(textW) + 24))
			b:Show()
			used[#used + 1] = b
		else
			b:Hide()
		end
	end
	-- The extra button (1.1.2), when its definition has one for this dialog.
	local extra, eb2 = def.extra, f.extraButton
	if type(extra) == "table" and (not extra.shown or Call(f, "extra shown", extra.shown, f, data)) then
		eb2:SetText(tostring(extra.label or ""))
		local fs = eb2:GetFontString()
		local textW = fs and (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()) or 80
		eb2:SetWidth(math.max(90, math.ceil(textW) + 24))
		eb2:Show()
		used[#used + 1] = eb2
	else
		eb2:Hide()
	end
	local total = 0
	for _, b in ipairs(used) do total = total + b:GetWidth() end
	total = total + 8 * math.max(0, #used - 1)
	width = math.max(width, total + 40)
	f:SetWidth(width)
	f.text:SetWidth(width - 40)
	local textH = f.text.GetStringHeight and f.text:GetStringHeight() or 14
	local y = -18 - textH - 10
	if def.hasEditBox then
		eb:ClearAllPoints()
		eb:SetPoint("TOP", f, "TOP", 0, y)
		y = y - 30
	end
	local x = -total / 2
	for _, b in ipairs(used) do
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", f, "TOP", x, y)
		x = x + b:GetWidth() + 8
	end
	f:SetHeight(-y + 22 + 16)
	f:Show()
	Layout()
	Call(f, "show", def.OnShow, f, data)
	-- (The hint is the gamepad UI's: with mouse and keyboard these are Sylvanistas's own windows by
	-- choice, 1.1.2, and they are answered with the mouse as any window.)
	if not hinted and ns.GamepadUI() then
		hinted = true
		ns.Print(ns.L.DIALOG_GAMEPAD_HINT)
	end
	return f
end

-- As StaticPopup_Hide: closed without an answer (OnHide only).
function Dialog.Hide(which, data)
	for _, f in ipairs(frames) do
		if f:IsShown() and f.which == which and (data == nil or f.data == data) then
			f.closing = "hide"
			f:Hide()
		end
	end
end

-- Tests start from a clean state.
function Dialog.Reset()
	for _, f in ipairs(frames) do
		f.closing = "hide"
		f:Hide()
	end
end
