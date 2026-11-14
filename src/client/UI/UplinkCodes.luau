-- Uplink code list (PC + gamepad arm method "Codes"; touch keeps the radial UplinkDial).
-- Hold the dial key, type the arrow code of a call-in; the list filters as you type.
--   init()
--   open() / close() / isOpen()
--   press(dir: "U"|"D"|"L"|"R") -> (kind, entry?)
--       kind = "step"  arrow accepted, more to type
--              "error" no row matches any more: input was reset
--              "match" a full code was typed (entry = { slot = number | "REINFORCE", id, def, available, status, remaining })
--   reset()                      clear the typed arrows
--   setArmed(id: string?)        row with this call-in id shows ACTIVATING (nil = none)
--   setHint(text, color?)        context line at the bottom ("PRESS [LMB] TO THROW")
-- Reads Store "me" (callins.slots, reinforceReadyAt). Feel_UplinkListPos (Studio A/B): "left" = far left; default = left of the crosshair.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local CallIns = require(Shared:WaitForChild("Data"):WaitForChild("CallIns"))
local Store = require(script.Parent.Parent.Store)
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)

local UplinkCodes = {}

local W = 400
local ROW_H = 50
local ARROW = 15
local ARROW_GAP = 5
local MAX_ARROWS = 6
local REFRESH = 0.1 -- status text refresh while open (s)

local DIR_SHAPE = { U = "up", D = "down", L = "left", R = "right" }

local built = false
local gui: ScreenGui
local panel: Frame
local listFrame: Frame
local hintLabel: TextLabel
local rows: { any } = {}
local rowKey: string? = nil

local openFlag = false
local typed: { string } = {}
local armedId: string? = nil
local hintText = ""
local hintColor: Color3 = Style.Grey
local errorUntil = 0
local conn: RBXScriptConnection? = nil
local lastRefresh = 0

local function fmtClock(sec: number): string
	local s = math.max(0, math.ceil(sec))
	return string.format("T-%02d:%02d", math.floor(s / 60), s % 60)
end

local function build()
	if built then
		return
	end
	built = true
	gui = Theme.gui("OrbitUplinkCodes", { DisplayOrder = 70, Enabled = false })
	local root = Theme.root(gui, "hud")
	panel = Style.panel({
		Name = "CodeList",
		Size = UDim2.fromOffset(W, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Transparency = 0.35,
		Parent = root,
	})
	Theme.pad(panel, 8, 8, 10, 8)
	Theme.list(panel, Enum.FillDirection.Vertical, 4)
	Style.label({
		Text = "UPLINK  -  " .. string.upper(Config.ShipName),
		TextSize = 14,
		Color = Style.Grey,
		Size = UDim2.new(1, 0, 0, 18),
		LayoutOrder = 0,
		Parent = panel,
	})
	listFrame = Instance.new("Frame")
	listFrame.Name = "Rows"
	listFrame.BackgroundTransparency = 1
	listFrame.Size = UDim2.new(1, 0, 0, 0)
	listFrame.AutomaticSize = Enum.AutomaticSize.Y
	listFrame.LayoutOrder = 1
	listFrame.Parent = panel
	Theme.list(listFrame, Enum.FillDirection.Vertical, 3)
	hintLabel = Style.label({
		Text = "",
		TextSize = 15,
		Color = Style.Grey,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = 2,
		Parent = panel,
	})
end

local function place()
	if workspace:GetAttribute("Feel_UplinkListPos") == "left" then
		panel.AnchorPoint = Vector2.new(0, 0.5)
		panel.Position = UDim2.new(0, Style.MARGIN + 260, 0.5, 0)
	else
		-- left of the crosshair: the aim point stays visible while you type and throw
		panel.AnchorPoint = Vector2.new(1, 0.5)
		panel.Position = UDim2.new(0.5, -70, 0.5, 0)
	end
end

local function makeRow(def: any, order: number, slot: any): any
	local row = Instance.new("Frame")
	row.Name = "Row" .. tostring(order)
	row.BackgroundColor3 = Style.Black
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, ROW_H)
	row.LayoutOrder = order
	row.Parent = listFrame
	local beacon = if slot == "REINFORCE" then Style.Green else Theme.beaconColor(def.beacon)
	local glyph = Style.glyph(Style.callinShape(def), {
		Size = 16,
		Color = beacon,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromOffset(20, 6),
		Parent = row,
	})
	local abbr = Style.label({
		Text = Style.callinCode(def),
		TextSize = 12,
		Color = beacon,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromOffset(40, 14),
		Position = UDim2.fromOffset(0, 28),
		Parent = row,
	})
	local name = Style.label({
		Text = if slot == "REINFORCE" then "REINFORCE" else def.name,
		TextSize = 17,
		Size = UDim2.new(1, -170, 0, 22),
		Position = UDim2.fromOffset(46, 2),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
	local status = Style.label({
		Text = "",
		TextSize = 16,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -4, 0, 2),
		Size = UDim2.fromOffset(120, 22),
		Parent = row,
	})
	local arrowsHost = Instance.new("Frame")
	arrowsHost.Name = "Code"
	arrowsHost.BackgroundTransparency = 1
	arrowsHost.Position = UDim2.fromOffset(46, 28)
	arrowsHost.Size = UDim2.fromOffset(MAX_ARROWS * (ARROW + ARROW_GAP + 6), ARROW + 4)
	arrowsHost.Parent = row
	Theme.list(arrowsHost, Enum.FillDirection.Horizontal, ARROW_GAP, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local code = CallIns.codeOf(def)
	local arrows = {}
	for i, d in code do
		-- small dark box behind each arrow, so lit / unlit reads at a glance
		local box = Style.rect({
			Name = "Arrow" .. i,
			Color = Style.Black,
			Transparency = 0.4,
			Size = UDim2.fromOffset(ARROW + 6, ARROW + 4),
			LayoutOrder = i,
			Parent = arrowsHost,
		})
		local g = Style.glyph(DIR_SHAPE[d] or "dot", {
			Size = ARROW - 3,
			Color = Style.Grey,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Parent = box,
		})
		arrows[i] = { box = box, glyph = g }
	end
	return {
		row = row, glyph = glyph, abbr = abbr, name = name, status = status, arrows = arrows, code = code,
		def = def, slot = slot, beacon = beacon, alive = true, available = false, statusKey = "", remaining = 0,
	}
end

local function rebuild(slots: { any })
	for _, r in rows do
		r.row:Destroy()
	end
	table.clear(rows)
	for i, s in slots do
		local def = CallIns.get(s.id)
		if def then
			table.insert(rows, makeRow(def, i, i))
		end
	end
	local rdef = CallIns.get("REINFORCE")
	if rdef then
		table.insert(rows, makeRow(rdef, 20, "REINFORCE"))
	end
end

-- availability + status text for every row (also rebuilds when the loadout changed)
local function refreshStatus(t: number)
	local me = Store.get("me")
	local slots = (me and me.callins and type(me.callins.slots) == "table") and me.callins.slots or {}
	local ids = {}
	for _, s in slots do
		table.insert(ids, tostring(s.id))
	end
	local key = table.concat(ids, ",")
	if key ~= rowKey then
		rowKey = key
		rebuild(slots)
	end
	for _, r in rows do
		local available, remaining, status
		local text
		if r.slot == "REINFORCE" then
			remaining = math.max(0, ((me and me.reinforceReadyAt) or 0) - t)
			available = remaining <= 0
			status = if available then "READY" else "COOLDOWN"
			text = if available then "READY" else fmtClock(remaining)
		else
			local slot = slots[r.slot]
			if slot then
				available, remaining, status = Theme.slotStatus(slot, r.def, t)
				if status == "NO USES" then
					text = "NO USES"
				elseif status == "COOLDOWN" then
					text = fmtClock(remaining)
				elseif r.def.uses then
					text = "x" .. tostring(slot.uses or r.def.uses)
				elseif slot.maxCharges and slot.maxCharges > 1 then
					text = "x" .. tostring(slot.charges or 0)
				else
					text = "READY"
				end
			else
				available, remaining, status, text = false, 0, "EMPTY", ""
			end
		end
		r.available, r.remaining, r.statusKey = available, remaining, status
		if armedId ~= nil and r.def.id == armedId then
			r.status.Text = "ACTIVATING"
			r.status.TextColor3 = Style.Amber
		else
			r.status.Text = text
			r.status.TextColor3 = if available then Style.White elseif status == "NO USES" then Style.Red else Style.Grey
		end
	end
end

-- lit arrows / dimmed rows
local function paint()
	local n = #typed
	local err = os.clock() < errorUntil
	for _, r in rows do
		local isArmed = armedId ~= nil and r.def.id == armedId
		local matching = r.alive and #r.code > 0
		-- dim: rows that can no longer match, or (while one is armed and nothing typed) every other row
		local dim = if n > 0 then not matching elseif armedId ~= nil then not isArmed else false
		local unavailable = not r.available
		local textAlpha = if dim then 0.7 elseif unavailable then 0.45 else 0
		r.name.TextTransparency = textAlpha
		r.abbr.TextTransparency = textAlpha
		r.status.TextTransparency = if dim then 0.7 else 0
		Style.glyphAlpha(r.glyph, textAlpha)
		r.row.BackgroundTransparency = if isArmed then 0.55 elseif (matching and n > 0) then 0.75 else 1
		r.row.BackgroundColor3 = if isArmed then r.beacon else Style.Black
		for i, a in r.arrows do
			local lit = matching and i <= n
			local col = if err then Style.Red elseif isArmed and n == 0 then Style.Amber elseif lit then Style.Amber else Style.White
			Style.tint(a.glyph, col)
			Style.glyphAlpha(a.glyph, if lit or (isArmed and n == 0) then 0 elseif dim then 0.8 else 0.35)
			a.box.BackgroundTransparency = if lit then 0.15 elseif dim then 0.75 else 0.45
		end
	end
	if err then
		hintLabel.Text = "WRONG CODE"
		hintLabel.TextColor3 = Style.Red
	else
		hintLabel.Text = hintText
		hintLabel.TextColor3 = hintColor
	end
end

local function step()
	local c = os.clock()
	if c - lastRefresh >= REFRESH then
		lastRefresh = c
		refreshStatus(workspace:GetServerTimeNow())
		paint()
	end
end

-- Public API ----------------------------------------------------------------------------------------------------------------
function UplinkCodes.init()
	build()
end

function UplinkCodes.isOpen(): boolean
	return openFlag
end

function UplinkCodes.reset()
	table.clear(typed)
	for _, r in rows do
		r.alive = true
	end
	if openFlag then
		paint()
	end
end

function UplinkCodes.open()
	build()
	if openFlag then
		return
	end
	openFlag = true
	place()
	UplinkCodes.reset()
	errorUntil = 0
	refreshStatus(workspace:GetServerTimeNow())
	paint()
	gui.Enabled = true
	local s = panel:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	s.Parent = panel
	s.Scale = 0.92
	Theme.tween(s, 0.12, { Scale = 1 }, Enum.EasingStyle.Back)
	if conn then
		conn:Disconnect()
	end
	lastRefresh = 0
	conn = RunService.RenderStepped:Connect(step)
end

function UplinkCodes.close()
	if not openFlag then
		return
	end
	openFlag = false
	if conn then
		conn:Disconnect()
		conn = nil
	end
	table.clear(typed)
	gui.Enabled = false
end

function UplinkCodes.setArmed(id: string?)
	armedId = id
	if openFlag then
		refreshStatus(workspace:GetServerTimeNow())
		paint()
	end
end

function UplinkCodes.setHint(text: string, color: Color3?)
	hintText = string.upper(text)
	hintColor = color or Style.Grey
	if openFlag and os.clock() >= errorUntil then
		hintLabel.Text = hintText
		hintLabel.TextColor3 = hintColor
	end
end

function UplinkCodes.press(dir: string): (string, any)
	if not openFlag or not DIR_SHAPE[dir] then
		return "none", nil
	end
	refreshStatus(workspace:GetServerTimeNow())
	local n = #typed + 1
	local any = false
	for _, r in rows do
		if r.alive and r.code[n] == dir then
			any = true
			break
		end
	end
	if not any then
		UplinkCodes.reset()
		errorUntil = os.clock() + 0.6
		paint()
		return "error", nil
	end
	typed[n] = dir
	local matched: any = nil
	for _, r in rows do
		r.alive = r.alive and r.code[n] == dir
		if r.alive and #r.code == n and (matched == nil or (r.available and not matched.available)) then
			matched = r
		end
	end
	if matched then
		local entry = {
			slot = matched.slot,
			id = matched.def.id,
			def = matched.def,
			available = matched.available,
			status = matched.statusKey,
			remaining = matched.remaining,
		}
		UplinkCodes.reset()
		paint()
		return "match", entry
	end
	paint()
	return "step", nil
end

return UplinkCodes
