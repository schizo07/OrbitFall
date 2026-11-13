-- S.Ship: the ORV Halcyon lobby deck floating at Config.ShipHeight (y = 900), plus the huge hull that
-- hangs in the sky above the map (visible from the ground).
--   S.Ship.build() -> {spawn = CFrame, model = Model}    idempotent (rebuilds workspace.Ship)
--   S.Ship.applyLighting()                                 space lighting for the lobby (MapBuilder calls it on clear)
--   S.Ship.setBackdrop(enabled)                            planet/moon backdrop (hidden while a map is built)
-- Terminals are ProximityPrompts carrying attribute OpenScreen = "Loadout"|"Armory"|"Bonds"|"Shop"|"Mission".

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local Ship = {}
Ship.model = nil :: Model?

local S: any = nil
local Y = Config.ShipHeight
local backdrop: Model? = nil
local backdropOn = true

local STEEL = Color3.fromRGB(58, 64, 78)
local STEEL_LIGHT = Color3.fromRGB(96, 104, 120)
local DARK = Color3.fromRGB(30, 34, 44)
local TEAL = Config.Colors.Friendly
local ORANGE = Config.Colors.Accent
local GOLD = Config.Colors.Gold

local function part(parent: Instance, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat or Enum.Material.Metal
	p.CastShadow = false
	if opts then
		for k, v in opts do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function glow(parent: Instance, size: Vector3, cf: CFrame, color: Color3, opts: { [string]: any }?): Part
	local o: { [string]: any } = { CanCollide = false, CanQuery = false, CanTouch = false }
	if opts then
		for k, v in opts do
			o[k] = v
		end
	end
	return part(parent, size, cf, color, Enum.Material.Neon, o)
end

local function ball(parent: Instance, diameter: number, pos: Vector3, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local p = part(parent, Vector3.new(diameter, diameter, diameter), CFrame.new(pos), color, mat, opts)
	p.Shape = Enum.PartType.Ball
	return p
end

-- vertical cylinder
local function pillar(parent: Instance, diameter: number, height: number, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local p = part(parent, Vector3.new(height, diameter, diameter), cf * CFrame.Angles(0, 0, math.pi / 2), color, mat, opts)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- cylinder along the Z axis
local function zcyl(parent: Instance, diameter: number, length: number, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local p = part(parent, Vector3.new(length, diameter, diameter), cf * CFrame.Angles(0, math.pi / 2, 0), color, mat, opts)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function blink(p: BasePart, period: number, lo: number)
	p.Transparency = 0
	TweenService:Create(p, TweenInfo.new(period, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, math.random() * period), { Transparency = lo }):Play()
end

local function spin(p: BasePart, seconds: number)
	local o = p.Orientation
	TweenService:Create(p, TweenInfo.new(seconds, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Orientation = o + Vector3.new(0, 360, 0) }):Play()
end

local function addLight(p: BasePart, color: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = p
end

local function label(parent: BasePart, face: Enum.NormalId, canvas: Vector2, text: string, color: Color3, bg: Color3?, sub: string?)
	local sg = Instance.new("SurfaceGui")
	sg.Face = face
	sg.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	sg.CanvasSize = canvas
	sg.LightInfluence = 0
	sg.Brightness = 1.4
	sg.Parent = parent
	local fr = Instance.new("Frame")
	fr.Size = UDim2.fromScale(1, 1)
	fr.BackgroundColor3 = bg or Color3.fromRGB(12, 18, 30)
	fr.BorderSizePixel = 0
	fr.Parent = sg
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 4
	stroke.Parent = fr
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(0.92, if sub then 0.62 else 0.8)
	t.Position = UDim2.fromScale(0.04, if sub then 0.06 else 0.1)
	t.Font = Enum.Font.Michroma
	t.Text = text
	t.TextColor3 = color
	t.TextScaled = true
	t.Parent = fr
	if sub then
		local s = Instance.new("TextLabel")
		s.BackgroundTransparency = 1
		s.Size = UDim2.fromScale(0.9, 0.22)
		s.Position = UDim2.fromScale(0.05, 0.7)
		s.Font = Enum.Font.GothamBold
		s.Text = sub
		s.TextColor3 = Config.Colors.Text
		s.TextScaled = true
		s.Parent = fr
	end
end

local function prompt(parent: BasePart, screen: string, action: string, object: string, distance: number?)
	local pp = Instance.new("ProximityPrompt")
	pp.Name = "Prompt_" .. screen
	pp.ActionText = action
	pp.ObjectText = object
	pp.HoldDuration = 0
	pp.RequiresLineOfSight = false
	pp.MaxActivationDistance = distance or 10
	pp.KeyboardKeyCode = Enum.KeyCode.E
	pp:SetAttribute("OpenScreen", screen)
	pp.Parent = parent
	return pp
end

-- ---------------------------------------------------------------- lighting
local function clearShipFx()
	for _, c in Lighting:GetChildren() do
		if c:GetAttribute("OrbitfallShip") or c:GetAttribute("OrbitfallMap")
			or c:IsA("Sky") or c:IsA("Atmosphere") or c:IsA("PostEffect")
		then
			c:Destroy()
		end
	end
end

function Ship.applyLighting()
	clearShipFx()
	Lighting.ClockTime = 0
	Lighting.Brightness = 1.6
	Lighting.GlobalShadows = false
	Lighting.Ambient = Color3.fromRGB(96, 106, 140)
	Lighting.OutdoorAmbient = Color3.fromRGB(128, 138, 180)
	Lighting.ColorShift_Top = Color3.fromRGB(150, 180, 255)
	Lighting.ColorShift_Bottom = Color3.fromRGB(60, 70, 120)
	Lighting.EnvironmentDiffuseScale = 0.4
	Lighting.EnvironmentSpecularScale = 0.5
	Lighting.ExposureCompensation = 0.2
	local sky = Instance.new("Sky")
	sky.StarCount = 5000
	sky.CelestialBodiesShown = true
	sky:SetAttribute("OrbitfallShip", true)
	sky.Parent = Lighting
	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.3
	bloom.Size = 18
	bloom.Threshold = 2.2
	bloom:SetAttribute("OrbitfallShip", true)
	bloom.Parent = Lighting
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Contrast = 0.08
	cc.Saturation = 0.15
	cc.TintColor = Color3.fromRGB(235, 242, 255)
	cc:SetAttribute("OrbitfallShip", true)
	cc.Parent = Lighting
end

function Ship.setBackdrop(enabled: boolean)
	backdropOn = enabled
	if backdrop then
		backdrop.Parent = if enabled then Ship.model else nil
	end
end

-- ---------------------------------------------------------------- sections
local function buildBackdrop(model: Model)
	-- Everything sits within ~650 studs: lower graphics levels (phones) cull parts much further away.
	local bd = Instance.new("Model")
	bd.Name = "Backdrop"
	local R = 180
	local planetPos = Vector3.new(80, Y - 30, -560)
	ball(bd, R * 2, planetPos, Color3.fromRGB(38, 96, 178), Enum.Material.SmoothPlastic, { CanCollide = false })
	ball(bd, R * 2 + 10, planetPos, Color3.fromRGB(190, 225, 255), Enum.Material.SmoothPlastic, { CanCollide = false, Transparency = 0.8 })
	ball(bd, R * 2 + 34, planetPos, Color3.fromRGB(110, 180, 255), Enum.Material.Neon, { CanCollide = false, Transparency = 0.93 })
	local r = Random.new(31)
	-- caps: balls sunk into the surface so only a curved patch shows (continents, ice, clouds)
	local function cap(dir: Vector3, d: number, color: Color3, lift: number, mat: Enum.Material, transp: number)
		local c = planetPos + dir.Unit * (R - d * 0.45 + lift)
		ball(bd, d, c, color, mat, { CanCollide = false, Transparency = transp })
	end
	local toShip = (Vector3.new(0, Y, 0) - planetPos).Unit
	local right = toShip:Cross(Vector3.yAxis).Unit
	local LAND = { Color3.fromRGB(64, 140, 84), Color3.fromRGB(92, 150, 70), Color3.fromRGB(150, 128, 82) }
	for i = 1, 9 do
		local dir = toShip + right * r:NextNumber(-0.85, 0.85) + Vector3.yAxis * r:NextNumber(-0.5, 0.75)
		cap(dir, r:NextNumber(60, 120), LAND[r:NextInteger(1, #LAND)], 0, Enum.Material.SmoothPlastic, 0)
	end
	cap(Vector3.yAxis + toShip * 0.25, 120, Color3.fromRGB(235, 245, 255), 1, Enum.Material.SmoothPlastic, 0) -- ice cap
	for _ = 1, 12 do
		local dir = toShip + right * r:NextNumber(-0.95, 0.95) + Vector3.yAxis * r:NextNumber(-0.6, 0.8)
		cap(dir, r:NextNumber(34, 70), Color3.fromRGB(250, 250, 255), 3, Enum.Material.SmoothPlastic, 0.3)
	end
	-- moon and a ringed gas giant
	ball(bd, 54, Vector3.new(-300, Y + 55, -330), Color3.fromRGB(176, 172, 168), Enum.Material.Slate, { CanCollide = false })
	local gp = Vector3.new(-430, Y + 120, -620)
	ball(bd, 170, gp, Color3.fromRGB(226, 150, 86), Enum.Material.SmoothPlastic, { CanCollide = false })
	ball(bd, 172, gp + Vector3.new(0, 18, 0), Color3.fromRGB(240, 190, 130), Enum.Material.SmoothPlastic, { CanCollide = false, Transparency = 0.55 })
	local ring = part(bd, Vector3.new(1, 330, 330), CFrame.new(gp) * CFrame.Angles(math.rad(70), 0, math.rad(20)), Color3.fromRGB(240, 200, 150), Enum.Material.SmoothPlastic, { CanCollide = false, Transparency = 0.45 })
	ring.Shape = Enum.PartType.Cylinder
	-- asteroids
	for _ = 1, 16 do
		local d = r:NextNumber(8, 30)
		local p = Vector3.new(r:NextNumber(-520, 520), Y + r:NextNumber(-80, 200), r:NextNumber(-480, -200))
		part(bd, Vector3.new(d, d * r:NextNumber(0.6, 1), d * r:NextNumber(0.7, 1.2)), CFrame.new(p) * CFrame.Angles(r:NextNumber(0, 6), r:NextNumber(0, 6), r:NextNumber(0, 6)), Color3.fromRGB(110, 100, 96), Enum.Material.Slate, { CanCollide = false })
	end
	for _, d in bd:GetDescendants() do
		if d:IsA("BasePart") then
			d.CastShadow = false
		end
	end
	bd.Parent = if backdropOn then model else nil
	backdrop = bd
end

local function buildHull(model: Model)
	local hull = Instance.new("Model")
	hull.Name = "Hull"
	hull.Parent = model
	local function layer(y0: number, y1: number, z0: number, z1: number, halfW: number, color: Color3)
		part(hull, Vector3.new(halfW * 2, y1 - y0, z1 - z0), CFrame.new(0, (y0 + y1) / 2, (z0 + z1) / 2), color, Enum.Material.Metal, { CanCollide = false })
	end
	layer(Y - 16, Y - 3, -42, 300, 70, STEEL)
	layer(Y - 44, Y - 16, -20, 322, 58, Color3.fromRGB(50, 56, 70))
	layer(Y - 74, Y - 44, 10, 336, 44, Color3.fromRGB(44, 50, 62))
	layer(Y - 112, Y - 74, 40, 346, 26, Color3.fromRGB(38, 42, 54))
	-- rib plating and window strips on the sides
	for _, sx in { -1, 1 } do
		for row = 0, 2 do
			glow(hull, Vector3.new(0.6, 1.6, 270), CFrame.new(sx * 58.4, Y - 24 - row * 6, 160), Color3.fromRGB(255, 226, 150), { Transparency = 0.15 })
		end
		part(hull, Vector3.new(14, 14, 120), CFrame.new(sx * 80, Y - 40, 40), Color3.fromRGB(70, 76, 92), Enum.Material.Metal, { CanCollide = false })
		zcyl(hull, 7, 70, CFrame.new(sx * 80, Y - 40, -50), STEEL_LIGHT, Enum.Material.Metal, { CanCollide = false })
		local nav = ball(hull, 6, Vector3.new(sx * 84, Y - 40, 105), if sx < 0 then Color3.fromRGB(255, 50, 50) else Color3.fromRGB(70, 255, 120), Enum.Material.Neon, { CanCollide = false })
		blink(nav, 1.1, 0.85)
	end
	-- underside running lights
	for i = 0, 6 do
		local l = ball(hull, 5, Vector3.new(((i % 2) * 2 - 1) * 20, Y - 113, 60 + i * 42), Color3.fromRGB(255, 240, 220), Enum.Material.Neon, { CanCollide = false })
		blink(l, 0.9 + i * 0.13, 0.9)
	end
	-- engines
	for i, o in { { -30, Y - 30 }, { 30, Y - 30 }, { -14, Y - 66 }, { 14, Y - 66 } } do
		zcyl(hull, 26, 46, CFrame.new(o[1], o[2], 340), Color3.fromRGB(72, 78, 92), Enum.Material.Metal, { CanCollide = false })
		local nozzle = zcyl(hull, 22, 4, CFrame.new(o[1], o[2], 364), Color3.fromRGB(120, 200, 255), Enum.Material.Neon, { CanCollide = false })
		blink(nozzle, 0.7 + i * 0.1, 0.35)
		zcyl(hull, 30, 8, CFrame.new(o[1], o[2], 358), Color3.fromRGB(40, 44, 56), Enum.Material.Metal, { CanCollide = false })
	end
	-- bridge tower and top greebles (seen from the deck, behind the launch bay)
	part(hull, Vector3.new(50, 26, 46), CFrame.new(0, Y + 10, 200), Color3.fromRGB(70, 78, 96), Enum.Material.Metal, { CanCollide = false })
	glow(hull, Vector3.new(44, 3, 0.6), CFrame.new(0, Y + 16, 176.6), Color3.fromRGB(150, 220, 255), { Transparency = 0.1 })
	part(hull, Vector3.new(30, 12, 30), CFrame.new(0, Y + 28, 205), Color3.fromRGB(86, 94, 112), Enum.Material.Metal, { CanCollide = false })
	pillar(hull, 1.4, 40, CFrame.new(10, Y + 54, 205), STEEL_LIGHT, Enum.Material.Metal, { CanCollide = false })
	local top = ball(hull, 3, Vector3.new(10, Y + 75, 205), Color3.fromRGB(255, 70, 60), Enum.Material.Neon, { CanCollide = false })
	blink(top, 0.8, 0.9)
	for i = 0, 4 do
		local x = ({ -40, -20, 0, 20, 40 })[i + 1]
		part(hull, Vector3.new(12, 2, 20), CFrame.new(x, Y - 2, 110 + i * 22), Color3.fromRGB(80, 88, 104), Enum.Material.DiamondPlate, { CanCollide = false })
		glow(hull, Vector3.new(10, 0.4, 0.8), CFrame.new(x, Y - 0.6, 100 + i * 22), TEAL, { Transparency = 0.2 })
	end
	local dish = pillar(hull, 16, 1.5, CFrame.new(-45, Y + 6, 140) * CFrame.Angles(0, 0, math.rad(-25)), STEEL_LIGHT, Enum.Material.Metal, { CanCollide = false })
	dish.Name = "Dish"
end

local function buildDeck(model: Model)
	local deck = Instance.new("Folder")
	deck.Name = "Deck"
	deck.Parent = model
	-- floor
	part(deck, Vector3.new(120, 2, 80), CFrame.new(0, Y - 1, 0), STEEL, Enum.Material.DiamondPlate)
	part(deck, Vector3.new(66, 0.3, 80), CFrame.new(0, Y + 0.1, 0), Color3.fromRGB(46, 52, 66), Enum.Material.Metal, { CanCollide = false })
	-- neon guide strips
	for _, x in { -57, 57 } do
		glow(deck, Vector3.new(0.8, 0.2, 78), CFrame.new(x, Y + 0.12, 0), TEAL)
	end
	glow(deck, Vector3.new(118, 0.2, 0.8), CFrame.new(0, Y + 0.12, -38), TEAL)
	glow(deck, Vector3.new(118, 0.2, 0.8), CFrame.new(0, Y + 0.12, 38), ORANGE)
	for _, z in { -16, 16 } do
		glow(deck, Vector3.new(30, 0.15, 0.4), CFrame.new(-33, Y + 0.1, z), ORANGE, { Transparency = 0.3 })
		glow(deck, Vector3.new(30, 0.15, 0.4), CFrame.new(33, Y + 0.1, z), ORANGE, { Transparency = 0.3 })
	end
	-- table ring on the floor
	local ring = pillar(deck, 26, 0.2, CFrame.new(0, Y + 0.12, 0), TEAL, Enum.Material.Neon, { CanCollide = false })
	local ring2 = pillar(deck, 24, 0.3, CFrame.new(0, Y + 0.14, 0), DARK, Enum.Material.Metal, { CanCollide = false })
	ring.Name, ring2.Name = "TableRingOuter", "TableRingInner"

	-- railings (sides + back) and invisible safety walls
	for _, x in { -59.5, 59.5 } do
		part(deck, Vector3.new(0.6, 0.6, 80), CFrame.new(x, Y + 4.4, 0), STEEL_LIGHT, Enum.Material.Metal)
		glow(deck, Vector3.new(0.3, 0.3, 80), CFrame.new(x, Y + 2.4, 0), TEAL, { Transparency = 0.2 })
		for z = -40, 40, 10 do
			part(deck, Vector3.new(0.6, 4.4, 0.6), CFrame.new(x, Y + 2.2, z), STEEL_LIGHT, Enum.Material.Metal, { CanCollide = false })
		end
	end
	part(deck, Vector3.new(120, 0.6, 0.6), CFrame.new(0, Y + 4.4, 39.7), STEEL_LIGHT, Enum.Material.Metal)
	glow(deck, Vector3.new(120, 0.3, 0.3), CFrame.new(0, Y + 2.4, 39.7), ORANGE, { Transparency = 0.2 })
	for x = -60, 60, 10 do
		part(deck, Vector3.new(0.6, 4.4, 0.6), CFrame.new(x, Y + 2.2, 39.7), STEEL_LIGHT, Enum.Material.Metal, { CanCollide = false })
	end
	for _, d in { { 0, -41, 124, 1 }, { 0, 41, 124, 1 }, { -61, 0, 1, 84 }, { 61, 0, 1, 84 } } do
		part(deck, Vector3.new(d[3], 60, d[4]), CFrame.new(d[1], Y + 30, d[2]), STEEL, Enum.Material.Metal, { Transparency = 1, CanQuery = false, CanTouch = false })
	end

	-- observation window on the -Z side
	part(deck, Vector3.new(120, 4, 1.6), CFrame.new(0, Y + 2, -40), STEEL, Enum.Material.Metal)
	glow(deck, Vector3.new(118, 0.4, 0.4), CFrame.new(0, Y + 4.2, -39.2), TEAL)
	part(deck, Vector3.new(114, 24, 0.5), CFrame.new(0, Y + 16.5, -40), Color3.fromRGB(150, 200, 255), Enum.Material.Glass, { Transparency = 0.82, CanQuery = false })
	for x = -60, 60, 20 do
		part(deck, Vector3.new(2, 30, 2), CFrame.new(x, Y + 15, -40), STEEL, Enum.Material.Metal)
	end
	part(deck, Vector3.new(124, 3, 3), CFrame.new(0, Y + 30.5, -40), STEEL, Enum.Material.Metal)
	glow(deck, Vector3.new(120, 0.4, 0.4), CFrame.new(0, Y + 28.6, -38.6), ORANGE, { Transparency = 0.1 })
	local nameplate = part(deck, Vector3.new(40, 5, 0.6), CFrame.new(0, Y + 34, -40.2), DARK, Enum.Material.Metal)
	label(nameplate, Enum.NormalId.Back, Vector2.new(800, 100), string.upper(Config.ShipName), ORANGE)
	label(nameplate, Enum.NormalId.Front, Vector2.new(800, 100), string.upper(Config.ShipName), ORANGE)

	-- lamp posts
	for i, o in { { -56, -34 }, { 56, -34 }, { -56, 34 }, { 56, 34 }, { -56, 0 }, { 56, 0 }, { 0, -36 }, { 0, 36 } } do
		pillar(deck, 0.8, 7, CFrame.new(o[1], Y + 3.5, o[2]), STEEL_LIGHT, Enum.Material.Metal, { CanCollide = false })
		local head = glow(deck, Vector3.new(2, 1, 2), CFrame.new(o[1], Y + 7.4, o[2]), Color3.fromRGB(255, 240, 220))
		if i <= 8 then
			addLight(head, Color3.fromRGB(255, 236, 210), 46, 1.2)
		end
	end
end

local function buildHoloTable(model: Model)
	local f = Instance.new("Model")
	f.Name = "HoloTable"
	f.Parent = model
	pillar(f, 14, 3, CFrame.new(0, Y + 1.5, 0), DARK, Enum.Material.Metal)
	pillar(f, 15, 0.8, CFrame.new(0, Y + 0.4, 0), STEEL_LIGHT, Enum.Material.Metal, { CanCollide = false })
	glow(f, Vector3.new(0.2, 14.4, 14.4), CFrame.new(0, Y + 3.05, 0) * CFrame.Angles(0, 0, math.pi / 2), TEAL, { Shape = Enum.PartType.Cylinder, Transparency = 0.1 })
	local disc = pillar(f, 12, 0.3, CFrame.new(0, Y + 3.3, 0), TEAL, Enum.Material.Neon, { Transparency = 0.4, CanCollide = false })
	disc.Name = "Disc"
	addLight(disc, TEAL, 36, 1.8)
	-- projected beam + spinning hologram
	pillar(f, 6, 7, CFrame.new(0, Y + 7, 0), TEAL, Enum.Material.Neon, { Transparency = 0.9, CanCollide = false, CanQuery = false })
	local cube = glow(f, Vector3.new(4, 4, 4), CFrame.new(0, Y + 8.5, 0) * CFrame.Angles(math.rad(35), 0, math.rad(35)), Color3.fromRGB(120, 230, 255), { Transparency = 0.55 })
	spin(cube, 9)
	local core = ball(f, 2.4, Vector3.new(0, Y + 8.5, 0), ORANGE, Enum.Material.Neon, { CanCollide = false })
	core.Name = "Core"
	local halo = pillar(f, 9, 0.2, CFrame.new(0, Y + 8.5, 0) * CFrame.Angles(math.rad(20), 0, math.rad(12)), TEAL, Enum.Material.Neon, { Transparency = 0.5, CanCollide = false })
	spin(halo, 14)
	-- floating sign
	local bb = Instance.new("BillboardGui")
	-- sized in studs (not pixels) so it shrinks with distance and never covers the DROP BAY sign behind it
	bb.Size = UDim2.fromScale(9, 1.6)
	bb.StudsOffset = Vector3.new(0, 3.6, 0)
	bb.AlwaysOnTop = false
	bb.MaxDistance = 90
	bb.Parent = core
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.Michroma
	t.Text = "MISSION TABLE"
	t.TextColor3 = TEAL
	t.TextStrokeTransparency = 0.3
	t.TextScaled = true
	t.Parent = bb
	prompt(disc, "Mission", "Plan Mission", "Mission Table", 15)
end

local function terminal(model: Model, name: string, screen: string, pos: Vector3, color: Color3, sub: string, action: string)
	local f = Instance.new("Model")
	f.Name = "Terminal_" .. name
	f.Parent = model
	local face = CFrame.lookAt(pos, Vector3.new(0, pos.Y, 0))
	part(f, Vector3.new(6, 1, 4), face * CFrame.new(0, 0.5, 0), DARK, Enum.Material.Metal)
	part(f, Vector3.new(4.6, 3.2, 2.6), face * CFrame.new(0, 2.6, 0.2), STEEL, Enum.Material.Metal)
	glow(f, Vector3.new(4.8, 0.3, 2.8), face * CFrame.new(0, 4.3, 0.2), color)
	local scr = part(f, Vector3.new(4.2, 2.6, 0.3), face * CFrame.new(0, 4.6, -0.5) * CFrame.Angles(math.rad(-18), 0, 0), DARK, Enum.Material.SmoothPlastic)
	label(scr, Enum.NormalId.Front, Vector2.new(420, 260), string.upper(name), color, nil, sub)
	addLight(scr, color, 14, 0.9)
	-- sign above, on two posts
	for _, dx in { -4.5, 4.5 } do
		part(f, Vector3.new(0.6, 11, 0.6), face * CFrame.new(dx, 5.5, 1.5), STEEL_LIGHT, Enum.Material.Metal, { CanCollide = false })
	end
	local sign = part(f, Vector3.new(10.6, 3.4, 0.6), face * CFrame.new(0, 12, 1.5), DARK, Enum.Material.Metal, { CanCollide = false })
	label(sign, Enum.NormalId.Front, Vector2.new(640, 210), string.upper(name), color)
	glow(f, Vector3.new(10.6, 0.3, 0.7), face * CFrame.new(0, 10.1, 1.5), color)
	prompt(scr, screen, action, name .. " Terminal", 10)
end

local function buildLaunchBay(model: Model)
	local f = Instance.new("Model")
	f.Name = "LaunchBay"
	f.Parent = model
	part(f, Vector3.new(70, 0.6, 20), CFrame.new(0, Y + 0.3, 30), Color3.fromRGB(44, 48, 60), Enum.Material.DiamondPlate)
	for i = -17, 17 do
		glow(f, Vector3.new(1.6, 0.2, 1), CFrame.new(i * 2, Y + 0.65, 20.2), if i % 2 == 0 then GOLD else DARK, { Transparency = 0 })
	end
	for i = 1, 4 do
		local x = -27 + (i - 1) * 18
		local cradle = CFrame.new(x, Y + 0.6, 31)
		part(f, Vector3.new(9, 1, 9), cradle * CFrame.new(0, 0.5, 0), DARK, Enum.Material.Metal)
		for _, dx in { -4, 4 } do
			part(f, Vector3.new(0.8, 10, 1), cradle * CFrame.new(dx, 6, 0), STEEL_LIGHT, Enum.Material.Metal, { CanCollide = false })
		end
		pillar(f, 7, 12, cradle * CFrame.new(0, 7.5, 0), Color3.fromRGB(210, 214, 222), Enum.Material.SmoothPlastic, { CanCollide = false })
		ball(f, 7, (cradle * CFrame.new(0, 13.5, 0)).Position, Color3.fromRGB(210, 214, 222), Enum.Material.SmoothPlastic, { CanCollide = false })
		glow(f, Vector3.new(4, 3.4, 0.4), cradle * CFrame.new(0, 9, -3.4), Color3.fromRGB(120, 210, 255), { Transparency = 0.15 })
		pillar(f, 7.2, 0.8, cradle * CFrame.new(0, 4, 0), ORANGE, Enum.Material.Neon, { Transparency = 0.1, CanCollide = false })
		for k = 0, 2 do
			local a = k * math.rad(120)
			part(f, Vector3.new(0.5, 6, 3), cradle * CFrame.new(math.cos(a) * 3.8, 3.6, math.sin(a) * 3.8) * CFrame.Angles(0, -a, 0), Color3.fromRGB(190, 70, 50), Enum.Material.Metal, { CanCollide = false })
		end
		local idx = glow(f, Vector3.new(2, 2, 0.3), cradle * CFrame.new(0, 12, -3.5), ORANGE, { Transparency = 0.2 })
		blink(idx, 1.4 + i * 0.2, 0.7)
	end
	-- gantry + sign
	for _, x in { -36, 36 } do
		part(f, Vector3.new(1.6, 24, 1.6), CFrame.new(x, Y + 12, 24), STEEL, Enum.Material.Metal)
	end
	part(f, Vector3.new(76, 1.6, 1.6), CFrame.new(0, Y + 24, 24), STEEL, Enum.Material.Metal)
	glow(f, Vector3.new(72, 0.4, 0.4), CFrame.new(0, Y + 23, 23.2), ORANGE)
	local sign = part(f, Vector3.new(26, 4.6, 0.6), CFrame.new(0, Y + 20, 23.6), DARK, Enum.Material.Metal, { CanCollide = false })
	label(sign, Enum.NormalId.Front, Vector2.new(780, 140), "DROP BAY", ORANGE, nil)
	local light = glow(f, Vector3.new(60, 0.4, 0.4), CFrame.new(0, Y + 24.6, 23), GOLD)
	addLight(light, GOLD, 40, 1)
end

local function buildSpawns(model: Model): CFrame
	local f = Instance.new("Folder")
	f.Name = "Spawns"
	f.Parent = model
	for i = 1, 4 do
		local x = -9 + (i - 1) * 6
		local sp = Instance.new("SpawnLocation")
		sp.Name = "ShipSpawn" .. i
		sp.Anchored = true
		sp.Neutral = true
		sp.Duration = 0
		sp.AllowTeamChangeOnTouch = false
		sp.TopSurface = Enum.SurfaceType.Smooth
		sp.BottomSurface = Enum.SurfaceType.Smooth
		sp.Size = Vector3.new(5, 1, 5)
		sp.CFrame = CFrame.lookAt(Vector3.new(x, Y + 0.5, -24), Vector3.new(x, Y + 0.5, 0))
		-- dark pad with a thin glowing rim (a full neon slab blew out the whole deck shot)
		sp.Color = Color3.fromRGB(34, 44, 62)
		sp.Material = Enum.Material.DiamondPlate
		sp.CastShadow = false
		sp.Parent = f
		for k = 0, 3 do
			local a = k * math.pi / 2
			glow(f, Vector3.new(5, 0.12, 0.3), sp.CFrame * CFrame.Angles(0, a, 0) * CFrame.new(0, 0.52, 2.35), TEAL, { Transparency = 0.15, CanCollide = false })
		end
		local d = Instance.new("Decal")
		d.Name = "SpawnPad"
		d.Transparency = 1
		d.Parent = sp
	end
	return CFrame.lookAt(Vector3.new(0, Y + 3.5, -22), Vector3.new(0, Y + 3.5, 0))
end

function Ship.init(registry: any)
	S = registry
end

function Ship.build()
	local old = Workspace:FindFirstChild("Ship")
	if old then
		old:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "Ship"
	Ship.model = model

	buildDeck(model)
	buildHoloTable(model)
	terminal(model, "Loadout", "Loadout", Vector3.new(-48, Y, -17), TEAL, "Weapons + call-ins", "Open")
	terminal(model, "Armory", "Armory", Vector3.new(-48, Y, 17), ORANGE, "Unlock gear", "Open")
	terminal(model, "Bonds", "Bonds", Vector3.new(48, Y, -17), GOLD, "Reward tracks", "Open")
	terminal(model, "Shop", "Shop", Vector3.new(48, Y, 17), Color3.fromRGB(190, 130, 255), "Tokens + passes", "Open")
	buildLaunchBay(model)
	local spawn = buildSpawns(model)
	buildHull(model)
	buildBackdrop(model)

	model.Parent = Workspace
	if not (S and S.Map and S.Map.current) then
		Ship.applyLighting()
	end
	return { spawn = spawn, model = model }
end

return Ship
