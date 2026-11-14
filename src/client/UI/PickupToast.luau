-- Pickup toast, right edge at ~55 % of the screen height: flat black panel with an orange outline, 3 s.
-- Fed from the server Notify texts that describe a pickup (route() decides; HUD forwards every Notify here first):
--   "Sample collected (2/5)"  -> green diamond     "Resupplied(!)"       -> amber ammo
--   "Picked up <thing>"       -> orange diamond    "Equipped <weapon>"   -> orange diamond (support weapon pickup)
-- Up to 3 toasts stack upwards from the anchor; the same text repeating bumps a counter instead of stacking.
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)

local PickupToast = {}

local LIFE = 3
local FADE = 0.4
local MAX = 3

local ui: { [string]: any } = {}
local live: { any } = {}
local touch = false
local serial = 0

function PickupToast.build(parent: Instance, isTouch: boolean)
	touch = isTouch
	local holder = Instance.new("Frame")
	holder.Name = "PickupToasts"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(1, 0.5)
	holder.Position = UDim2.new(1, -Style.MARGIN, 0.55, 0)
	holder.Size = UDim2.fromOffset(if touch then 190 else 230, if touch then 90 else 110)
	holder.Visible = false
	holder.Parent = parent
	Theme.list(holder, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	ui.holder = holder
end

function PickupToast.setVisible(on: boolean)
	if ui.holder then
		ui.holder.Visible = on
	end
end

local function remove(t: any)
	local i = table.find(live, t)
	if i then
		table.remove(live, i)
	end
	if t.frame.Parent then
		t.frame:Destroy()
	end
end

local function fade(t: any, gen: number)
	if t.gen ~= gen or not t.frame.Parent then
		return
	end
	Theme.tween(t.frame, FADE, { BackgroundTransparency = 1 })
	Theme.tween(t.stroke, FADE, { Transparency = 1 })
	Theme.tween(t.glyph, FADE, { TextTransparency = 1, TextStrokeTransparency = 1 })
	Theme.tween(t.label, FADE, { TextTransparency = 1, TextStrokeTransparency = 1 })
	task.delay(FADE + 0.05, function()
		if t.gen == gen then
			remove(t)
		end
	end)
end

local function arm(t: any)
	t.gen += 1
	local gen = t.gen
	task.delay(LIFE, fade, t, gen)
end

-- glyph: single supported character; color: glyph colour (the outline is always orange)
function PickupToast.show(text: string, glyph: string?, color: Color3?)
	if not ui.holder then
		return
	end
	local up = Style.up(text)
	for _, t in live do
		if t.base == up then
			t.count += 1
			t.label.Text = string.format("%s  x%d", up, t.count)
			t.frame.BackgroundTransparency = Style.PANEL_ALPHA
			t.stroke.Transparency = 0.1
			t.glyph.TextTransparency = 0
			t.label.TextTransparency = 0
			arm(t)
			return
		end
	end
	serial += 1
	local frame = Style.panel({
		Name = "Pickup",
		Brackets = false,
		Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = serial,
		Parent = ui.holder,
	})
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(if touch then 190 else 230, 26)
	cap.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Style.Orange
	stroke.Thickness = 1
	stroke.Transparency = 0.1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame
	Theme.pad(frame, 8, 0, 9, 0)
	Theme.list(frame, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local g = Style.label({
		Text = glyph or "◆",
		TextSize = 14,
		Color = color or Style.Orange,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromOffset(14, 26),
		LayoutOrder = 1,
		Parent = frame,
	})
	local l = Style.label({
		Text = up,
		Color = Style.White,
		Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = frame,
	})
	local t = { frame = frame, stroke = stroke, glyph = g, label = l, base = up, count = 1, gen = 0 }
	table.insert(live, t)
	while #live > MAX do
		remove(live[1])
	end
	-- slide/fade in
	frame.BackgroundTransparency = 1
	stroke.Transparency = 1
	g.TextTransparency = 1
	l.TextTransparency = 1
	Theme.tween(frame, 0.15, { BackgroundTransparency = Style.PANEL_ALPHA })
	Theme.tween(stroke, 0.15, { Transparency = 0.1 })
	Theme.tween(g, 0.15, { TextTransparency = 0 })
	Theme.tween(l, 0.15, { TextTransparency = 0 })
	arm(t)
end

-- Server Notify text -> toast. Returns true when it was a pickup (HUD then skips the generic toast).
function PickupToast.route(text: string): boolean
	local lower = string.lower(text)
	local n, m = string.match(text, "^Sample collected %((%d+)/(%d+)%)")
	if n then
		PickupToast.show(string.format("SAMPLE COLLECTED  %s/%s", n, m), "◆", Style.Green)
		return true
	end
	if string.find(lower, "^sample collected") then
		PickupToast.show("SAMPLE COLLECTED", "◆", Style.Green)
		return true
	end
	if string.find(lower, "^resupplied") then
		PickupToast.show("RESUPPLIED  AMMO + GRENADES", "▮", Style.Amber)
		return true
	end
	local picked = string.match(text, "^Picked up (.+)$")
	if picked then
		PickupToast.show("PICKED UP  " .. picked, "◆", Style.Orange)
		return true
	end
	local eq = string.match(text, "^Equipped (.+)$")
	if eq then
		PickupToast.show("WEAPON  " .. eq, "◆", Style.Orange)
		return true
	end
	return false
end

function PickupToast.clear()
	for _, t in table.clone(live) do
		remove(t)
	end
	table.clear(live)
end

return PickupToast
