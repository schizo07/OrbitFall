-- Top-centre compass tape: 34 % of the screen wide, 14 px tall, red-tinted, with a heading chip hanging below it and
-- objective / beacon / breach pips riding on the tape. The alert bar (UI/AlertBar.luau) starts right under the chip.
-- Teammates ride on the tape as dots in their squad colour (a square while they carry a core cell, haul objective).
-- The chip reads e.g. "SW [226]".
local Players = game:GetService("Players")
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local HudLayout = require(script.Parent.HudLayout)
local Store = require(script.Parent.Parent.Store)

local Compass = {}

local SPAN = 150 -- degrees across the tape
local TAPE_H = 14
local CARDINAL = { [0] = "N", [90] = "E", [180] = "S", [270] = "W" }
local INTER = { [45] = "NE", [135] = "SE", [225] = "SW", [315] = "NW" }
local SHORT = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

local ui: { [string]: any } = {}
local items: { { bearing: number, node: GuiObject } } = {}
local mates: { [Player]: { node: Frame, key: string } } = {}
local extras: { [string]: { pos: Vector3, node: Frame } } = {} -- Compass.setExtra (squad pings)
local localPlayer = Players.LocalPlayer
local headingShown = -1 -- last heading readout written (index * 1000 + degrees)
local headingLabel: Instance? = nil -- the label it was written to
local blips: { { pos: Vector3, node: Frame } } = {} -- radar ping blips (Compass.ping), cleared after blipsUntil
local blipsUntil = 0

local function wrap180(a: number): number
	return (a + 180) % 360 - 180
end

-- Returns the Frame the markers (pips) should be parented to.
function Compass.build(parent: Instance, touch: boolean): Frame
	-- a second build (HUD.rebuild after a UI STYLE switch): the old nodes died with the old gui
	table.clear(ui)
	table.clear(items)
	table.clear(mates)
	table.clear(extras)
	table.clear(blips)
	headingShown, headingLabel = -1, nil
	local skin = HudSkin.current()
	local tapeH = TAPE_H
	local holder = Instance.new("Frame")
	holder.Name = "CompassHolder"
	holder.BackgroundTransparency = 1
	if skin then
		-- new layout (UI/HudLayout): 0.29 x screen PC, 240 px phone; tape in the skin's look, no red panel
		local lay = HudLayout.get("compass", touch)
		HudLayout.apply(holder, "compass", touch)
		tapeH = lay.Size.Y.Offset
	else
		holder.AnchorPoint = Vector2.new(0.5, 0)
		holder.Position = UDim2.new(0.5, 0, 0, Style.MARGIN)
		holder.Size = UDim2.new(0.34, 0, 0, TAPE_H)
	end
	holder.Parent = parent
	local lim = Instance.new("UISizeConstraint")
	lim.MinSize = Vector2.new(if skin then 200 else 340, tapeH)
	lim.Parent = holder
	ui.holder = holder

	local tape
	if skin then
		tape = Instance.new("Frame")
		tape.Name = "Tape"
		tape.BorderSizePixel = 0
		tape.BackgroundTransparency = 1
		tape.Size = UDim2.fromScale(1, 1)
		tape.ClipsDescendants = true
		tape.Parent = holder
		-- edges fade out so the tape has no hard ends; glass gets a soft pill behind it
		if skin.id == "glass" then
			local back = HudSkin.panel("glass", { Name = "Back", Size = UDim2.fromScale(1, 1), ZIndex = 0, Parent = tape })
			back.BackgroundTransparency = 0.2
			local cr = back:FindFirstChildOfClass("UICorner")
			if cr then
				cr.CornerRadius = UDim.new(0.5, 0)
			end
		else
			local base = Instance.new("Frame")
			base.Name = "Baseline"
			base.BorderSizePixel = 0
			base.BackgroundColor3 = skin.colors.line
			base.BackgroundTransparency = 0.6
			base.AnchorPoint = Vector2.new(0, 1)
			base.Position = UDim2.fromScale(0, 1)
			base.Size = UDim2.new(1, 0, 0, 1)
			base.Parent = tape
			local g = Instance.new("UIGradient")
			g.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.15, 0),
				NumberSequenceKeypoint.new(0.85, 0),
				NumberSequenceKeypoint.new(1, 1),
			})
			g.Parent = base
		end
	else
		tape = Style.panel({
			Name = "Tape",
			Color = Color3.fromHex("36090c"),
			Transparency = 0.3,
			Size = UDim2.fromScale(1, 1),
			ClipsDescendants = true,
			Parent = holder,
		})
	end
	ui.tape = tape
	local TAPE_H = tapeH -- the tape nodes below follow the layout height

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
	local chipProps = {
		Name = "Heading",
		Size = UDim2.fromOffset(72, 16),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 2),
		Parent = holder,
	}
	-- new skins: bare text under the tape (no box), dim, in the number font
	local chip = if skin then HudSkin.panel("none", chipProps) else Style.panel(chipProps)
	ui.heading = Style.label({
		Text = "N [000]",
		TextSize = 12,
		Color = if skin then skin.colors.dim else nil,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = chip,
	})
	if skin then
		HudSkin.styleText(ui.heading, "number")
	end
	ui.chip = chip
	-- RADAR ONLINE tag left of the heading chip (radar side objective: workspace attribute RadarOnline)
	local radarTag = Style.panel({
		Name = "RadarTag",
		Size = UDim2.fromOffset(96, 16),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(0.5, -40, 1, 2),
		Visible = false,
		Parent = holder,
	})
	Style.label({
		Text = "RADAR ONLINE",
		TextSize = 12,
		Color = Style.Green,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = radarTag,
	})
	ui.radarTag = radarTag
	pcall(require(script.Parent.Parent:WaitForChild("Fx"):WaitForChild("Weather")).compassTag, holder) -- STORM tag (Fx/Weather)
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
	-- the readout only changes when the whole-degree heading does; skip the format + Text write (re-layout) otherwise
	local shown = idx * 1000 + deg
	if shown ~= headingShown or headingLabel ~= ui.heading then
		headingShown, headingLabel = shown, ui.heading
		ui.heading.Text = string.format("%s [%03d]", SHORT[idx], deg)
	end

	local camPos = cam.CFrame.Position
	-- teammates (squad colour; a square while carrying a core cell)
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
						Box = UDim2.fromOffset(12, TAPE_H),
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
	for _, m in markers do
		local d = m.pos - camPos
		local b = math.deg(math.atan2(d.X, -d.Z))
		local rel = wrap180(b - ang)
		m.compass.Visible = math.abs(rel) <= SPAN / 2 + 6
		m.compass.Position = UDim2.fromScale(Theme.clamp(0.5 + rel / SPAN, 0, 1), 0.5)
	end

	-- radar ping blips (red dots for enemy groups, red arrows for breach sources) + the RADAR ONLINE tag
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

	-- breach pip
	local it = Store.get("intensity")
	local pip = ui.breachPip
	if type(it) == "table" and (it.state == "breach" or it.state == "build" or it.extract == true) and type(it.dir) == "number" then
		local rel = wrap180(it.dir - ang)
		pip.Visible = math.abs(rel) <= SPAN / 2 + 6
		pip.Position = UDim2.fromScale(Theme.clamp(0.5 + rel / SPAN, 0, 1), 0.5)
		-- tint (a GetDescendants walk) only when the colour changes, not every frame
		local tint = if it.state == "build" and not it.extract then Style.Amber else Style.Red
		if pip:GetAttribute("TintShown") ~= tint then
			pip:SetAttribute("TintShown", tint)
			Style.tint(pip, tint)
		end
	else
		pip.Visible = false
	end
end

-- Radar ping (UI/RadarTune, Fx "RadarPing"): red blips on the tape for `dur` s, replacing the last ping's.
-- list = { { p = Vector3, n = enemies, src = true for a breach source } }
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
				Box = UDim2.fromOffset(12, TAPE_H),
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

-- Extra pip on the tape for a world point (squad pings). Call again with a new pos to move it, with pos = nil to remove it.
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
				Box = UDim2.fromOffset(16, TAPE_H),
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

-- Pip on the tape for an objective / beacon. Returned label is owned by the caller (HUD.refreshMarkers destroys it).
-- shape = a Style.glyph shape name ("diamond", "diamondHollow", "up", ...)
function Compass.addPip(layer: Instance, key: string, shape: string, color: Color3): Frame
	if string.sub(key, 1, 9) == "objJAMMER" then
		color = Style.Red -- call-in jammer site: red pip
	end
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
