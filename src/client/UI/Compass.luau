-- Top-centre compass tape: 34 % of the screen wide, 14 px tall, red-tinted, with a heading chip hanging below it and
-- objective / beacon / breach pips riding on the tape. The alert bar (UI/AlertBar.luau) starts right under the chip.
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local Store = require(script.Parent.Parent.Store)

local Compass = {}

local SPAN = 150 -- degrees across the tape
local TAPE_H = 14
local CARDINAL = { [0] = "N", [90] = "E", [180] = "S", [270] = "W" }
local INTER = { [45] = "NE", [135] = "SE", [225] = "SW", [315] = "NW" }
local SHORT = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

local ui: { [string]: any } = {}
local items: { { bearing: number, node: GuiObject } } = {}

local function wrap180(a: number): number
	return (a + 180) % 360 - 180
end

-- Returns the Frame the markers (pips) should be parented to.
function Compass.build(parent: Instance, _touch: boolean): Frame
	local holder = Instance.new("Frame")
	holder.Name = "CompassHolder"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.new(0.5, 0, 0, Style.MARGIN)
	holder.Size = UDim2.new(0.34, 0, 0, TAPE_H)
	holder.Parent = parent
	local lim = Instance.new("UISizeConstraint")
	lim.MinSize = Vector2.new(340, TAPE_H)
	lim.Parent = holder
	ui.holder = holder

	local tape = Style.panel({
		Name = "Tape",
		Color = Color3.fromHex("36090c"),
		Transparency = 0.3,
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
		Parent = holder,
	})
	ui.tape = tape

	for b = 0, 345, 15 do
		local node: GuiObject
		if CARDINAL[b] then
			node = Style.label({
				Text = CARDINAL[b],
				TextSize = 13,
				Color = if b == 0 then Style.Amber else Style.White,
				XAlign = Enum.TextXAlignment.Center,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(18, TAPE_H),
				Position = UDim2.fromScale(0.5, 0.5),
				Parent = tape,
			})
		elseif INTER[b] then
			node = Style.label({
				Text = INTER[b],
				TextSize = 10,
				Color = Style.Grey,
				XAlign = Enum.TextXAlignment.Center,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(18, TAPE_H),
				Position = UDim2.fromScale(0.5, 0.5),
				Parent = tape,
			})
		else
			node = Style.rect({
				Color = Style.White,
				Transparency = 0.45,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(1, 5),
				Position = UDim2.fromScale(0.5, 0.5),
				Parent = tape,
			})
		end
		table.insert(items, { bearing = b, node = node })
	end

	-- centre index
	Style.rect({
		Name = "Center",
		Color = Style.White,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromOffset(1, 5),
		ZIndex = 5,
		Parent = tape,
	})

	local layer = Instance.new("Frame")
	layer.Name = "Pips"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = 4
	layer.Parent = tape
	ui.layer = layer

	-- breach pip (direction of the current BUILD / BREACH)
	ui.breachPip = Style.glyph("up", {
		Name = "BreachPip",
		Size = 10,
		Color = Style.Red,
		Box = UDim2.fromOffset(16, TAPE_H),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Visible = false,
		ZIndex = 4,
		Parent = layer,
	})

	-- heading chip hanging under the tape
	local chip = Style.panel({
		Name = "Heading",
		Size = UDim2.fromOffset(58, 16),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 2),
		Parent = holder,
	})
	ui.heading = Style.label({
		Text = "N 000",
		TextSize = 12,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = chip,
	})
	ui.chip = chip
	return layer
end

function Compass.setVisible(on: boolean)
	if ui.holder then
		ui.holder.Visible = on
	end
end

-- markers: { [key] = { pos: Vector3, compass: GuiObject } }
function Compass.step(cam: Camera, markers: { [string]: any })
	if not ui.holder then
		return
	end
	local look = cam.CFrame.LookVector
	local ang = math.deg(math.atan2(look.X, -look.Z))
	for _, c in items do
		local rel = wrap180(c.bearing - ang)
		if math.abs(rel) > SPAN / 2 then
			c.node.Visible = false
		else
			c.node.Visible = true
			c.node.Position = UDim2.fromScale(0.5 + rel / SPAN, 0.5)
		end
	end
	local deg = (math.floor(ang + 0.5) + 360) % 360
	local idx = math.floor((deg + 22.5) / 45) % 8 + 1
	ui.heading.Text = string.format("%s %03d", SHORT[idx], deg)

	local camPos = cam.CFrame.Position
	for _, m in markers do
		local d = m.pos - camPos
		local b = math.deg(math.atan2(d.X, -d.Z))
		local rel = wrap180(b - ang)
		m.compass.Visible = math.abs(rel) <= SPAN / 2 + 6
		m.compass.Position = UDim2.fromScale(Theme.clamp(0.5 + rel / SPAN, 0, 1), 0.5)
	end

	-- breach pip
	local it = Store.get("intensity")
	local pip = ui.breachPip
	if type(it) == "table" and (it.state == "breach" or it.state == "build" or it.extract == true) and type(it.dir) == "number" then
		local rel = wrap180(it.dir - ang)
		pip.Visible = math.abs(rel) <= SPAN / 2 + 6
		pip.Position = UDim2.fromScale(Theme.clamp(0.5 + rel / SPAN, 0, 1), 0.5)
		Style.tint(pip, if it.state == "build" and not it.extract then Style.Amber else Style.Red)
	else
		pip.Visible = false
	end
end

-- Pip on the tape for an objective / beacon. Returned label is owned by the caller (HUD.refreshMarkers destroys it).
-- shape = a Style.glyph shape name ("diamond", "diamondHollow", "up", ...)
function Compass.addPip(layer: Instance, key: string, shape: string, color: Color3): Frame
	return Style.glyph(shape, {
		Name = key,
		Size = 11,
		Color = color,
		Box = UDim2.fromOffset(16, TAPE_H),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = layer,
	})
end

return Compass
