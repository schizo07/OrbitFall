-- Pickup toast, right edge at ~55 % of the screen height: flat black panel with an orange outline, 3 s.
-- Fed from the server Notify texts that describe a pickup (route() decides; HUD forwards every Notify here first):
--   "Acquired <Item> +N"      -> "ACQUIRED <ITEM>" + green "+N" box (ammo / grenades: amber bar, stims: green plus)
--   "Sample collected (2/5)"  -> green diamond     "Resupplied(!)"       -> amber ammo (skipped right after an Acquired)
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
	-- touch: the right edge below ~25 % is the button cluster (JUMP / SWAP / STIM), so the toast goes centre, upper third
	holder.AnchorPoint = if touch then Vector2.new(0.5, 0.5) else Vector2.new(1, 0.5)
	holder.Position = if touch then UDim2.fromScale(0.5, 0.3) else UDim2.new(1, -Style.MARGIN, 0.55, 0)
	holder.Size = UDim2.fromOffset(if touch then 190 else 230, if touch then 90 else 110)
	holder.Visible = false
	holder.Parent = parent
	if touch then
		-- Studio A/B "PHONE HUD" (Feel_PhoneHud): nil = centre at y 36 % (reference phone 800 x 380: one row at about
		-- y 128-146, clear of the kill streak skull at y 78-112 above it); "old" = y 30 % (85-143, under the skull)
		local function place()
			holder.Position = UDim2.fromScale(0.5, if workspace:GetAttribute("Feel_PhoneHud") == "old" then 0.3 else 0.36)
		end
		place()
		workspace:GetAttributeChangedSignal("Feel_PhoneHud"):Connect(place)
	end
	Theme.list(
		holder,
		Enum.FillDirection.Vertical,
		4,
		if touch then Enum.HorizontalAlignment.Center else Enum.HorizontalAlignment.Right,
		Enum.VerticalAlignment.Center
	)
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
	Style.glyphTween(t.glyph, FADE, 1)
	Theme.tween(t.label, FADE, { TextTransparency = 1, TextStrokeTransparency = 1 })
	if t.plusBox then
		Theme.tween(t.plusBox, FADE, { BackgroundTransparency = 1 })
		Theme.tween(t.plusLabel, FADE, { TextTransparency = 1 })
	end
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

local lastAcquired = -100 -- os.clock of the last "ACQUIRED" toast (swallows the crate's generic "Resupplied" line)

local function setPlus(t: any, n: number)
	if t.plusLabel then
		t.plusLabel.Text = "+" .. tostring(n)
	end
end

-- shape: a Style.glyph shape name (default "diamond"); color: glyph colour (the outline is always orange)
-- plus: optional amount, drawn as a green "+N" box at the end; repeats of the same text add up
function PickupToast.show(text: string, shape: string?, color: Color3?, plus: number?)
	if not ui.holder then
		return
	end
	local up = Style.up(text)
	for _, t in live do
		if t.base == up then
			t.count += 1
			if plus and t.plus then
				t.plus += plus
				setPlus(t, t.plus)
			else
				t.label.Text = string.format("%s  x%d", up, t.count)
			end
			t.frame.BackgroundTransparency = Style.PANEL_ALPHA
			t.stroke.Transparency = 0.1
			Style.glyphAlpha(t.glyph, 0)
			t.label.TextTransparency = 0
			if t.plusBox then
				t.plusBox.BackgroundTransparency = 0.1
				t.plusLabel.TextTransparency = 0
			end
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
	local g = Style.glyph(shape or "diamond", {
		Size = 11,
		Color = color or Style.Orange,
		Box = UDim2.fromOffset(14, 26),
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
	local plusBox, plusLabel = nil, nil
	if plus then
		plusBox = Style.rect({
			Name = "Plus",
			Color = Style.Green,
			Transparency = 0.1,
			Size = UDim2.fromOffset(0, 18),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 3,
			Parent = frame,
		})
		Theme.pad(plusBox, 5, 0, 5, 0)
		plusLabel = Style.label({
			Text = "+" .. tostring(plus),
			TextSize = 14,
			Color = Style.Black,
			Shadow = false,
			XAlign = Enum.TextXAlignment.Center,
			Size = UDim2.fromOffset(0, 18),
			AutomaticSize = Enum.AutomaticSize.X,
			Parent = plusBox,
		})
		cap.MaxSize = Vector2.new((if touch then 190 else 230) + 40, 26)
	end
	local t = { frame = frame, stroke = stroke, glyph = g, label = l, base = up, count = 1, gen = 0, plus = plus, plusBox = plusBox, plusLabel = plusLabel }
	table.insert(live, t)
	while #live > MAX do
		remove(live[1])
	end
	-- slide/fade in
	frame.BackgroundTransparency = 1
	stroke.Transparency = 1
	Style.glyphAlpha(g, 1)
	l.TextTransparency = 1
	Theme.tween(frame, 0.15, { BackgroundTransparency = Style.PANEL_ALPHA })
	Theme.tween(stroke, 0.15, { Transparency = 0.1 })
	Style.glyphTween(g, 0.15, 0)
	Theme.tween(l, 0.15, { TextTransparency = 0 })
	arm(t)
end

-- Server Notify text -> toast. Returns true when it was a pickup (HUD then skips the generic toast).
function PickupToast.route(text: string): boolean
	local lower = string.lower(text)
	local n, m = string.match(text, "^Sample collected %((%d+)/(%d+)%)")
	if n then
		PickupToast.show(string.format("SAMPLE COLLECTED  %s/%s", n, m), "diamond", Style.Green)
		return true
	end
	if string.find(lower, "^sample collected") then
		PickupToast.show("SAMPLE COLLECTED", "diamond", Style.Green)
		return true
	end
	-- "Acquired <item> +N" (server/PlayerService.refill: ammo magazines, grenades, stims)
	local item, amt = string.match(text, "^Acquired (.-) %+(%d+)$")
	if item then
		lastAcquired = os.clock()
		local isStim = string.find(string.lower(item), "stim") ~= nil
		PickupToast.show("ACQUIRED  " .. item, if isStim then "plus" else "bar", if isStim then Style.Green else Style.Amber, tonumber(amt))
		return true
	end
	if string.find(lower, "^resupplied") then
		-- the supply crate also sends a generic line; the per-item "Acquired" toasts already said it
		if os.clock() - lastAcquired > 1.5 then
			PickupToast.show("RESUPPLIED", "bar", Style.Amber)
			lastAcquired = os.clock() -- refill's "Resupplied!" + the crate's "Resupplied" show once
		end
		return true
	end
	local picked = string.match(text, "^Picked up (.+)$")
	if picked then
		PickupToast.show("PICKED UP  " .. picked, "diamond", Style.Orange)
		return true
	end
	local eq = string.match(text, "^Equipped (.+)$")
	if eq then
		PickupToast.show("WEAPON  " .. eq, "diamond", Style.Orange)
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
