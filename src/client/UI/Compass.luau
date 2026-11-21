-- Top-centre perimeter compass bar: razor-slim translucent dark plate (~58 % opacity, thin crisp border),
-- cardinal ticks, compact bearing readout chip underneath, and objective / side / beacon / ping / teammate pips
-- at any distance. Shifts to a crimson tint while an urgent breach/wave alert is active.
local Players = game:GetService("Players")
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local HudLayout = require(script.Parent.HudLayout)
local Store = require(script.Parent.Parent.Store)

local Compass = {}

local SPAN = 150 -- degrees across the tape
local CARDINAL = { [0] = "N", [90] = "E", [180] = "S", [270] = "W" }
local INTER = { [45] = "NE", [135] = "SE", [225] = "SW", [315] = "NW" }
local SHORT = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

local PLATE_NORMAL = HudSkin.color("panel")
local PLATE_ALERT = Color3.fromHex("8A1218")
local EDGE_NORMAL = HudSkin.color("line")
local EDGE_ALERT = Color3.fromHex("FF4D4D")

local ui: { [string]: any } = {}
local items: { { bearing: number, node: GuiObject } } = {}
local mates: { [Player]: { node: Frame, key: string } } = {}
local extras: { [string]: { pos: Vector3, node: Frame } } = {} -- Compass.setExtra (squad pings)
local localPlayer = Players.LocalPlayer
local headingShown = -1
local headingLabel: Instance? = nil
local blips: { { pos: Vector3, node: Frame } } = {}
local blipsUntil = 0
local alertTintOn = false
local tapeHeight = 24

local function wrap180(a: number): number
	return (a + 180) % 360 - 180
end

-- Returns the Frame the markers (pips) should be parented to.
function Compass.build(parent: Instance, touch: boolean): Frame
	table.clear(ui)
	table.clear(items)
	table.clear(mates)
	table.clear(extras)
	table.clear(blips)
	headingShown, headingLabel, alertTintOn = -1, nil, false

	local lay = HudLayout.get("compass", touch)
	tapeHeight = lay.Size.Y.Offset
	local holder = Instance.new("Frame")
	holder.Name = "CompassHolder"
	holder.BackgroundTransparency = 1
	HudLayout.apply(holder, "compass", touch)
	holder.Parent = parent

	local lim = Instance.new("UISizeConstraint")
	lim.MinSize = Vector2.new(lay.MinWidth or 200, tapeHeight)
	lim.Parent = holder
	ui.holder = holder

	local tape = HudSkin.panel("plate", {
		Name = "Tape",
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
		Parent = holder,
	})
	ui.tape = tape
	ui.tapeEdge = tape:FindFirstChild("SkinEdge")

	local cardinalSize: number = lay.CardinalSize or 15
	local interSize: number = lay.InterSize or 12
	local compact = lay.Compact == true

	for b = 0, 345, 15 do
		local node: GuiObject
		if CARDINAL[b] then
			node = HudSkin.label({
				Text = CARDINAL[b],
				TextSize = cardinalSize,
				Color = if b == 0 then HudSkin.color("own") else HudSkin.color("text"),
				XAlign = Enum.TextXAlignment.Center,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(math.max(18, cardinalSize + 6), tapeHeight),
				Position = UDim2.fromScale(0.5, 0.5),
				Parent = tape,
			})
		elseif INTER[b] and not compact then
			node = HudSkin.label({
				Text = INTER[b],
				TextSize = interSize,
				ColorRole = "dim",
				XAlign = Enum.TextXAlignment.Center,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(math.max(20, interSize + 8), tapeHeight),
				Position = UDim2.fromScale(0.5, 0.5),
				Parent = tape,
			})
		else
			node = Style.rect({
				Color = HudSkin.color("line"),
				Transparency = 0.55,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(1, if compact then 5 else 6),
				Position = UDim2.fromScale(0.5, 0.5),
				Parent = tape,
			})
		end
		table.insert(items, { bearing = b, node = node })
	end

	-- Center index tick
	Style.rect({
		Name = "Center",
		Color = HudSkin.color("own"),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromOffset(2, 5),
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

	-- Breach direction pip
	ui.breachPip = Style.glyph("up", {
		Name = "BreachPip",
		Size = 10,
		Color = HudSkin.color("danger"),
		Box = UDim2.fromOffset(14, tapeHeight),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Visible = false,
		ZIndex = 4,
		Parent = layer,
	})

	-- Compact bearing readout chip directly underneath the tape
	local headingSize: number = lay.HeadingSize or 14
	local chipW = math.max(58, math.round(headingSize * 4.4))
	local chipH = headingSize + 4
	local chip = HudSkin.panel("plate", {
		Name = "Heading",
		Size = UDim2.fromOffset(chipW, chipH),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 2),
		Parent = holder,
	})
	ui.heading = HudSkin.label({
		Text = "N 000",
		Role = "number",
		TextSize = headingSize,
		ColorRole = "text",
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = chip,
	})
	ui.chip = chip
	ui.chipEdge = chip:FindFirstChild("SkinEdge")

	-- RADAR ONLINE tag left of the bearing chip (workspace attribute RadarOnline)
	local radarTag = HudSkin.panel("plate", {
		Name = "RadarTag",
		Size = UDim2.fromOffset(92, chipH),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(0.5, -math.round(chipW * 0.5 + 6), 1, 2),
		Visible = false,
		Parent = holder,
	})
	HudSkin.label({
		Text = "RADAR ONLINE",
		TextSize = math.max(11, headingSize - 2),
		ColorRole = "heal",
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = radarTag,
	})
	ui.radarTag = radarTag
	pcall(require(script.Parent.Parent:WaitForChild("Fx"):WaitForChild("Weather")).compassTag, holder)
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
	local shown = idx * 1000 + deg
	if shown ~= headingShown or headingLabel ~= ui.heading then
		headingShown, headingLabel = shown, ui.heading
		ui.heading.Text = string.format("%s %03d", SHORT[idx], deg)
	end

	local camPos = cam.CFrame.Position
	-- teammates (squad colour; square while carrying a core cell)
	if ui.layer then
		local seen: { [Player]: boolean } = {}
		for _, p in Players:GetPlayers() do
			local c = p ~= localPlayer and p.Character
			local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not root then
				continue
			end
			seen[p] = true
			local cs = Style.callsign(p.UserId)
			local carrying = p:GetAttribute("CarryCell") == true
			local key = (if carrying then "square" else "dot") .. cs.color:ToHex()
			local mt = mates[p]
			if not mt or mt.key ~= key then
				if mt then
					mt.node:Destroy()
				end
				mt = {
					node = Style.glyph(if carrying then "square" else "dot", {
						Name = "Mate",
						Size = if carrying then 9 else 8,
						Color = cs.color,
						Box = UDim2.fromOffset(12, tapeHeight),
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						ZIndex = 4,
						Parent = ui.layer,
					}),
					key = key,
				}
				mates[p] = mt
			end
			local d = root.Position - camPos
			local rel = wrap180(math.deg(math.atan2(d.X, -d.Z)) - ang)
			mt.node.Visible = math.abs(rel) <= SPAN / 2 + 6
			mt.node.Position = UDim2.fromScale(Theme.clamp(0.5 + rel / SPAN, 0, 1), 0.5)
		end
		for p, mt in mates do
			if not seen[p] then
				mt.node:Destroy()
				mates[p] = nil
			end
		end
	end

	-- ALL objective / side / beacon markers stay on the compass at any distance
	for _, m in markers do
		local d = m.pos - camPos
		local b = math.deg(math.atan2(d.X, -d.Z))
		local rel = wrap180(b - ang)
		m.compass.Visible = math.abs(rel) <= SPAN / 2 + 6
		m.compass.Position = UDim2.fromScale(Theme.clamp(0.5 + rel / SPAN, 0, 1), 0.5)
	end

	-- radar ping blips + RADAR ONLINE tag
	if #blips > 0 then
		if os.clock() > blipsUntil then
			for _, bl in blips do
				bl.node:Destroy()
			end
			table.clear(blips)
		else
			for _, bl in blips do
				local d = bl.pos - camPos
				local rel = wrap180(math.deg(math.atan2(d.X, -d.Z)) - ang)
				bl.node.Visible = math.abs(rel) <= SPAN / 2 + 6
				bl.node.Position = UDim2.fromScale(Theme.clamp(0.5 + rel / SPAN, 0, 1), 0.5)
			end
		end
	end
	if ui.radarTag then
		local on = workspace:GetAttribute("RadarOnline") == true
		if on ~= ui.radarTag.Visible then
			ui.radarTag.Visible = on
		end
	end
	for _, x in extras do
		local d = x.pos - camPos
		local rel = wrap180(math.deg(math.atan2(d.X, -d.Z)) - ang)
		x.node.Visible = math.abs(rel) <= SPAN / 2 + 6
		x.node.Position = UDim2.fromScale(Theme.clamp(0.5 + rel / SPAN, 0, 1), 0.5)
	end

	-- breach pip + crimson compass alert tint during active breach / hold
	local it = Store.get("intensity")
	local pip = ui.breachPip
	local urgent = type(it) == "table" and (it.state == "breach" or it.extract == true)
	if urgent ~= alertTintOn and ui.tape then
		alertTintOn = urgent
		Theme.tween(ui.tape, 0.25, {
			BackgroundColor3 = if urgent then PLATE_ALERT else PLATE_NORMAL,
			BackgroundTransparency = if urgent then 0.22 else HudSkin.PLATE_ALPHA,
		})
		if ui.tapeEdge then
			Theme.tween(ui.tapeEdge, 0.25, {
				Color = if urgent then EDGE_ALERT else EDGE_NORMAL,
				Transparency = if urgent then 0.45 else HudSkin.BORDER_ALPHA,
			})
		end
		if ui.chip then
			Theme.tween(ui.chip, 0.25, {
				BackgroundColor3 = if urgent then PLATE_ALERT else PLATE_NORMAL,
				BackgroundTransparency = if urgent then 0.22 else HudSkin.PLATE_ALPHA,
			})
		end
		if ui.chipEdge then
			Theme.tween(ui.chipEdge, 0.25, {
				Color = if urgent then EDGE_ALERT else EDGE_NORMAL,
				Transparency = if urgent then 0.45 else HudSkin.BORDER_ALPHA,
			})
		end
	end
	if type(it) == "table" and (it.state == "breach" or it.state == "build" or it.extract == true) and type(it.dir) == "number" then
		local rel = wrap180(it.dir - ang)
		pip.Visible = math.abs(rel) <= SPAN / 2 + 6
		pip.Position = UDim2.fromScale(Theme.clamp(0.5 + rel / SPAN, 0, 1), 0.5)
		local tint = if it.state == "build" and not it.extract then Style.Amber else Style.Red
		if pip:GetAttribute("TintShown") ~= tint then
			pip:SetAttribute("TintShown", tint)
			Style.tint(pip, tint)
		end
	else
		pip.Visible = false
	end
end

-- Radar ping (UI/RadarTune, Fx "RadarPing")
function Compass.ping(list: { any }, dur: number)
	for _, bl in blips do
		bl.node:Destroy()
	end
	table.clear(blips)
	if not ui.layer then
		return
	end
	for _, b in list do
		if typeof(b.p) == "Vector3" then
			local node = Style.glyph(if b.src then "up" else "dot", {
				Name = "RadarBlip",
				Size = if b.src then 10 elseif (tonumber(b.n) or 1) >= 5 then 9 else 7,
				Color = Style.Red,
				Box = UDim2.fromOffset(12, tapeHeight),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Visible = false,
				ZIndex = 4,
				Parent = ui.layer,
			})
			table.insert(blips, { pos = b.p, node = node })
		end
	end
	blipsUntil = os.clock() + dur
end

-- Extra pip on the tape for a world point (squad pings).
function Compass.setExtra(key: string, pos: Vector3?, color: Color3?)
	local x = extras[key]
	if not pos then
		if x then
			x.node:Destroy()
			extras[key] = nil
		end
		return
	end
	if not x then
		if not ui.layer then
			return
		end
		x = {
			pos = pos,
			node = Style.glyph("diamond", {
				Name = "Extra_" .. key,
				Size = 10,
				Color = color or Style.Amber,
				Box = UDim2.fromOffset(14, tapeHeight),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				ZIndex = 4,
				Parent = ui.layer,
			}),
		}
		extras[key] = x
	end
	x.pos = pos
end

-- Pip on the tape for an objective / beacon. Returned Frame is owned by the caller (HUD.refreshMarkers destroys it).
function Compass.addPip(layer: Instance, key: string, shape: string, color: Color3): Frame
	if string.sub(key, 1, 9) == "objJAMMER" then
		color = Style.Red
	end
	return Style.glyph(shape, {
		Name = key,
		Size = 11,
		Color = color,
		Box = UDim2.fromOffset(14, tapeHeight),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = layer,
	})
end

return Compass
