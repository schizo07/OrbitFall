-- World/Places: the set pieces of Dustbowl Ridge, built from plain parts (chunky, rounded, flat colours) on top of the terrain.
--   Places.build(map, parent, objective?) -> anchors      (YIELDS a little: parts are made in batches)
--     objective = "MISSILE" | "UPLINK" | "HAUL" | nil. Only HAUL gets the refinery wall ring (with two gates).
--   anchors = {
--     cellSpots = { spilled = {CFrame}, mesa = {CFrame}, quarry = {CFrame}, graveyard = {CFrame} },  -- 3 each, on the floor, upright
--     mastLight = BasePart?,   -- the relay mast beacon; it blinks by itself, set the attribute "Alarm" to keep it lit
--     dormant   = {CFrame},    -- spots lying among the walker ribs
--     terraces  = {CFrame},    -- standing spots on the quarry's upper steps, facing into the pit
--     gates     = {CFrame},    -- the refinery wall gaps (outside, facing in): [1] toward the quarry road, [2] toward the service road
--     flightLog = CFrame?,     -- the glowing panel on the crashed drone
--   }
-- Places: the crashed cargo drone + the trail of debris to the spilled crate, Signal Mesa (relay mast, generator, power line),
-- the Quarry (conveyor, digger, crane, terrace rails), the Walker Graveyard (fallen walker), the Refinery (stack, tanks, wall ring)
-- and the salt pan (wrecked hauler + rock clusters). Every map field is optional: the layout falls back to World/MapPlan.
-- Nothing here uses wedges. Only things you walk on or hide behind collide.

local Workspace = game:GetService("Workspace")
local MapPlan = require(script.Parent.MapPlan)
local Assets = require(script.Parent.Assets)

local Places = {}
Places.partCount = 0

local RGB = Color3.fromRGB
local PI = math.pi
local TAU = math.pi * 2

-- COG palette: dark steel + hazard yellow + cyan glow
local STEEL = RGB(84, 90, 102)
local STEEL_D = RGB(48, 52, 62)
local STEEL_L = RGB(112, 119, 132)
local CRATE = RGB(96, 104, 118)
local RUST = RGB(140, 84, 60)
local HAZ = RGB(238, 188, 40)
local TEAL = RGB(70, 235, 225)
local GLASS = RGB(48, 176, 176)
local SOOT = RGB(30, 27, 28)
local RED = RGB(255, 60, 50)
local AMBER = RGB(255, 170, 60)

local BIOME_LOOK = {
	desert = { sand = RGB(150, 98, 66), rock = RGB(118, 80, 58) },
	ash = { sand = RGB(90, 82, 78), rock = RGB(66, 61, 60) },
	swamp = { sand = RGB(90, 106, 98), rock = RGB(70, 64, 84) },
	ice = { sand = RGB(150, 162, 178), rock = RGB(122, 148, 192) },
	crystal = { sand = RGB(176, 170, 190), rock = RGB(176, 170, 196) },
}

-- build state ----------------------------------------------------------------------------------------------------------
local count = 0
local ops = 0
local lights = 0
local LIGHT_CAP = 10
local rnd = Random.new(7311)
local biomeName = "desert"
local groundFn: (number, number) -> number = function(_x: number, _z: number): number
	return 0
end

local function gy(x: number, z: number): number
	return groundFn(x, z)
end

-- part helpers -----------------------------------------------------------------------------------------------------------
-- solid = true collides; everything else is dressing (no collision, no raycast hits, no touch)
local function part(parent: Instance, size: Vector3, cf: CFrame, color: Color3, solid: boolean?, opts: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.CastShadow = size.Magnitude > 14
	p.CanCollide = solid == true
	p.CanQuery = solid == true
	p.CanTouch = false
	if opts then
		for k, v in opts do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	count += 1
	ops += 1
	if ops >= 40 then
		ops = 0
		task.wait()
	end
	return p
end

-- ball / ellipsoid
local function ball(parent: Instance, size: Vector3, cf: CFrame, color: Color3, solid: boolean?, opts: { [string]: any }?): Part
	local p = part(parent, size, cf, color, solid, opts)
	p.Shape = Enum.PartType.Ball
	return p
end

-- upright cylinder: diameter, height, centre cf
local function vcyl(parent: Instance, d: number, len: number, cf: CFrame, color: Color3, solid: boolean?, opts: { [string]: any }?): Part
	local p = part(parent, Vector3.new(len, d, d), cf * CFrame.Angles(0, 0, PI / 2), color, solid, opts)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- cylinder whose axis is the frame's X axis (lying across the frame)
local function xcyl(parent: Instance, d: number, len: number, cf: CFrame, color: Color3, solid: boolean?, opts: { [string]: any }?): Part
	local p = part(parent, Vector3.new(len, d, d), cf, color, solid, opts)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- cylinder whose axis is the frame's look direction
local function zcyl(parent: Instance, d: number, len: number, cf: CFrame, color: Color3, solid: boolean?, opts: { [string]: any }?): Part
	local p = part(parent, Vector3.new(len, d, d), cf * CFrame.Angles(0, PI / 2, 0), color, solid, opts)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- round strut between two points
local function pipe(parent: Instance, a: Vector3, b: Vector3, d: number, color: Color3, solid: boolean?, opts: { [string]: any }?): Part
	local diff = b - a
	local len = math.max(diff.Magnitude, 0.05)
	local dir = if diff.Magnitude > 0.001 then diff.Unit else Vector3.zAxis
	local up = if math.abs(dir.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	local mid = (a + b) / 2
	local p = part(parent, Vector3.new(len, d, d), CFrame.lookAt(mid, mid + dir, up) * CFrame.Angles(0, PI / 2, 0), color, solid, opts)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function glow(parent: Instance, size: Vector3, cf: CFrame, color: Color3, round: boolean?, transparency: number?): Part
	local p = part(parent, size, cf, color, false, { Material = Enum.Material.Neon, CastShadow = false, Transparency = transparency or 0 })
	if round then
		p.Shape = Enum.PartType.Ball
	end
	return p
end

local function folder(parent: Instance, name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function light(host: BasePart, color: Color3, range: number, brightness: number): PointLight?
	if lights >= LIGHT_CAP then
		return nil
	end
	lights += 1
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = host
	return l
end

local function smoke(host: BasePart, color: Color3, size: number, rate: number, life: number, speed: number)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
	pe.Rate = rate
	pe.Lifetime = NumberRange.new(life * 0.8, life * 1.2)
	pe.Speed = NumberRange.new(speed * 0.7, speed)
	pe.SpreadAngle = Vector2.new(8, 8)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.5), NumberSequenceKeypoint.new(1, size * 2.4) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(0.6, 0.72), NumberSequenceKeypoint.new(1, 1) })
	pe.Color = ColorSequence.new(color)
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-12, 12)
	pe.Acceleration = Vector3.new(5, 0, 3)
	pe.LightInfluence = 0.7
	pe.Parent = host
end

local function sparks(host: BasePart, rate: number)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Rate = rate
	pe.Lifetime = NumberRange.new(0.5, 1.1)
	pe.Speed = NumberRange.new(8, 18)
	pe.SpreadAngle = Vector2.new(70, 70)
	pe.Size = NumberSequence.new(0.5, 0.1)
	pe.Color = ColorSequence.new(RGB(255, 225, 130), RGB(255, 120, 40))
	pe.LightEmission = 1
	pe.Acceleration = Vector3.new(0, -40, 0)
	pe.Parent = host
end

-- invisible host for emitters and lights (pos is a world position, not a CFrame)
local function emitterHost(parent: Instance, pos: Vector3): Part
	return part(parent, Vector3.one, CFrame.new(pos), SOOT, false, { Transparency = 1, CastShadow = false })
end

-- geometry helpers ---------------------------------------------------------------------------------------------------------
local function jit(c: Color3, a: number): Color3
	local k = 1 + rnd:NextNumber(-a, a)
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end

-- flat unit direction a -> b
local function dirTo(a: Vector3, b: Vector3): Vector3
	local d = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	if d.Magnitude < 0.01 then
		return Vector3.new(0, 0, -1)
	end
	return d.Unit
end

local function angOf(v: Vector3): number
	return math.atan2(v.Z, v.X)
end

local function angDiff(a: number, b: number): number
	local d = (a - b) % TAU
	if d > PI then
		d -= TAU
	end
	return d
end

-- ground point at angle a, radius r around c
local function polar(c: Vector3, a: number, r: number): Vector3
	local x, z = c.X + math.cos(a) * r, c.Z + math.sin(a) * r
	return Vector3.new(x, gy(x, z), z)
end

-- lowest / highest ground over a footprint (centre + 4 sides)
local function lowAt(x: number, z: number, r: number): number
	local m = gy(x, z)
	for _, o in { { r, 0 }, { -r, 0 }, { 0, r }, { 0, -r } } do
		m = math.min(m, gy(x + o[1], z + o[2]))
	end
	return m
end

local function highAt(x: number, z: number, r: number): number
	local m = gy(x, z)
	for _, o in { { r, 0 }, { -r, 0 }, { 0, r }, { 0, -r } } do
		m = math.max(m, gy(x + o[1], z + o[2]))
	end
	return m
end

local function nearSide(x: number, z: number, r: number): boolean
	for _, s in MapPlan.sides do
		if (Vector2.new(x, z) - s.at).Magnitude < r then
			return true
		end
	end
	return false
end

local function toV3(v: any): Vector3?
	if typeof(v) == "Vector3" then
		return Vector3.new(v.X, gy(v.X, v.Z), v.Z)
	elseif typeof(v) == "Vector2" then
		return Vector3.new(v.X, gy(v.X, v.Y), v.Y)
	end
	return nil
end

local function placePos(map: any, name: string): Vector3
	local p = toV3(map and map.places and map.places[name])
	if p then
		return p
	end
	local at = MapPlan.at(name)
	return toV3(at) or Vector3.new(0, gy(0, 0), 0)
end

local function makeGround(map: any): (number, number) -> number
	if map and type(map.groundY) == "function" then
		return map.groundY
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Include
	rp.FilterDescendantsInstances = { Workspace.Terrain }
	return function(x: number, z: number): number
		local r = Workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -500, 0), rp)
		return if r then r.Position.Y else 0
	end
end

-- a cell rests upright on the floor, turned to face `toward`
local function spot(pos: Vector3, toward: Vector3): CFrame
	local f = Vector3.new(toward.X, 0, toward.Z)
	if f.Magnitude < 0.01 then
		f = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(pos, pos + f.Unit)
end

-- a crate: chunky block with a hazard band; pos is the ground point under it
local function crate(parent: Instance, pos: Vector3, yaw: number, w: number, h: number, d: number, solid: boolean?)
	local cf = CFrame.new(pos + Vector3.new(0, h / 2 - 0.3, 0)) * CFrame.Angles(0, yaw, 0)
	part(parent, Vector3.new(w, h, d), cf, jit(CRATE, 0.05), solid)
	part(parent, Vector3.new(w + 0.12, h * 0.2, d + 0.12), cf * CFrame.new(0, h * 0.18, 0), HAZ, false)
end

local DESERT_ROCK_KEYS = { "desert_boulder_a", "desert_boulder_b", "desert_boulder_a" }

local function placeMesh(parent: Instance, key: string, x: number, z: number, scale: number, tint: Color3, collide: boolean, maxSlope: number?): (Model?, boolean?)
	local size = Assets.size(key)
	local r = (if size then math.max(size.X, size.Z) else 6) * scale * 0.4
	local lo, hi = lowAt(x, z, r), highAt(x, z, r)
	local lim = math.tan(math.rad(maxSlope or 45)) * 2 * math.max(r, 0.5)
	if hi - lo > lim then
		return nil, true
	end
	local m = Assets.get(key, { anchored = true })
	if not m then
		return nil
	end
	if scale ~= 1 then
		m:ScaleTo(scale)
	end
	local h = (if size then size.Y else 6) * scale
	local sink = rnd:NextNumber(0.12, 0.2)
	m:PivotTo(CFrame.new(x, lo - h * sink, z) * CFrame.Angles(0, rnd:NextNumber(0, TAU), 0))
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = collide
			p.CanQuery = collide
			p.CanTouch = false
			p.Color = tint
			p.Material = Enum.Material.Sandstone
			p:SetAttribute("KeepMat", true)
			count += 1
		end
	end
	m.Parent = parent
	ops += 1
	if ops >= 40 then
		ops = 0
		task.wait()
	end
	return m
end

-- a cluster of rounded rocks (cover); in the desert, uses sandstone rock meshes with a rounded boulder fallback
local function rockCluster(parent: Instance, c: Vector3, radius: number, n: number, color: Color3)
	if biomeName == "desert" then
		for i = 1, n do
			local a = rnd:NextNumber(0, TAU)
			local d = if i == 1 then 0 else rnd:NextNumber(radius * 0.35, radius)
			local x, z = c.X + math.cos(a) * d, c.Z + math.sin(a) * d
			local w = rnd:NextNumber(4, 8.5)
			local h = w * rnd:NextNumber(0.55, 0.85)
			local k = DESERT_ROCK_KEYS[rnd:NextInteger(1, #DESERT_ROCK_KEYS)]
			local sz = Assets.size(k)
			local scale = w / (if sz then math.max(sz.X, sz.Z) else 9)
			local col = jit(color, 0.08)
			local m, skipped = placeMesh(parent, k, x, z, scale, col, true, 45)
			if not m and not skipped then
				local y = lowAt(x, z, w * 0.4) + h * 0.32
				local b = ball(parent, Vector3.new(w, h, w * rnd:NextNumber(0.8, 1.1)), CFrame.new(x, y, z) * CFrame.Angles(0, rnd:NextNumber(0, TAU), 0), col, true, { Material = Enum.Material.Sandstone })
				b:SetAttribute("KeepMat", true)
			end
		end
		-- one taller sandstone outcrop for cover
		local a = rnd:NextNumber(0, TAU)
		local x, z = c.X + math.cos(a) * radius * 0.5, c.Z + math.sin(a) * radius * 0.5
		local ph = rnd:NextNumber(7, 10)
		local sz = Assets.size("desert_butte")
		local scale = ph / (if sz then sz.Y else 10.3)
		local col = jit(color, 0.06)
		local m, skipped = placeMesh(parent, "desert_butte", x, z, scale, col, true, 45)
		if not m and not skipped then
			local dia = ph * 0.72
			local base = lowAt(x, z, dia * 0.4)
			local b = ball(parent, Vector3.one * dia, CFrame.new(x, base + dia * 0.25, z), col, true, { Material = Enum.Material.Sandstone })
			b:SetAttribute("KeepMat", true)
		end
		return
	end
	for i = 1, n do
		local a = rnd:NextNumber(0, TAU)
		local d = if i == 1 then 0 else rnd:NextNumber(radius * 0.35, radius)
		local x, z = c.X + math.cos(a) * d, c.Z + math.sin(a) * d
		local w = rnd:NextNumber(4, 8.5)
		local h = w * rnd:NextNumber(0.55, 0.85)
		local y = lowAt(x, z, w * 0.4) + h * 0.32
		ball(parent, Vector3.new(w, h, w * rnd:NextNumber(0.8, 1.1)), CFrame.new(x, y, z) * CFrame.Angles(0, rnd:NextNumber(0, TAU), 0), jit(color, 0.08), true)
	end
	-- one tall rounded pillar
	local a = rnd:NextNumber(0, TAU)
	local x, z = c.X + math.cos(a) * radius * 0.5, c.Z + math.sin(a) * radius * 0.5
	local base = lowAt(x, z, 1.6)
	local ph = rnd:NextNumber(7, 10)
	vcyl(parent, 3.6, ph, CFrame.new(x, base + ph / 2 - 0.6, z), jit(color, 0.06), true)
	ball(parent, Vector3.new(3.6, 2.6, 3.6), CFrame.new(x, base + ph - 0.6, z), jit(color, 0.06), true)
end

local function blink(lamp: BasePart, lt: PointLight?)
	task.spawn(function()
		local on = true
		while lamp:IsDescendantOf(Workspace) do
			on = not on
			if lamp:GetAttribute("Alarm") then
				on = true
			end
			lamp.Transparency = if on then 0 else 0.75
			if lt then
				lt.Enabled = on
			end
			task.wait(0.9)
		end
	end)
end

-- =============================================================================================================================
-- 1. crashed cargo drone + debris trail + burst crate
-- =============================================================================================================================
-- spots on the cog_drone_wreck mesh (art/blender/cog_drone_wreck.py attachments, model frame, studs)
local WRECK_SPOTS = {
	StackL = Vector3.new(0.679, 14.269, -0.437),
	StackR = Vector3.new(-3.247, 13.505, -0.437),
	Break = Vector3.new(-6.757, 5.357, -2.23), -- the snapped fan pylon
	FlightLog = Vector3.new(5.725, 3.51, -10.367),
}
local WRECK_LOG_NORMAL = Vector3.new(0.982, 0.191, 0)

-- Scorched ground: paints the terrain dark (Basalt) in a ragged blob of small patches around c (y ignored), radius r.
-- Soft voxel edges instead of the old hard dark disc part.
local SCORCHABLE = {
	Enum.Material.Sand, Enum.Material.Sandstone, Enum.Material.Ground, Enum.Material.Rock,
	Enum.Material.Mud, Enum.Material.Grass, Enum.Material.Slate,
	Enum.Material.Limestone, Enum.Material.Cobblestone, Enum.Material.Asphalt,
}
local function scorch(c: Vector3, r: number)
	local T = Workspace.Terrain
	local n = math.clamp(math.floor(r * 1.2), 3, 18)
	for i = 1, n do
		local a = rnd:NextNumber(0, TAU)
		local d = if i == 1 then 0 else math.sqrt(rnd:NextNumber()) * r * 0.85
		local x, z = c.X + math.cos(a) * d, c.Z + math.sin(a) * d
		local y = gy(x, z)
		local s = rnd:NextNumber(2, 3.5)
		local reg = Region3.new(Vector3.new(x - s, y - 6, z - s), Vector3.new(x + s, y + 2, z + s)):ExpandToGrid(4)
		local target = if biomeName == "desert" and d > r * 0.5
			then (if i % 2 == 0 then Enum.Material.Slate else Enum.Material.Mud)
			else Enum.Material.Basalt
		for _, m in SCORCHABLE do
			if m ~= target then
				T:ReplaceMaterial(reg, 4, m, target)
			end
		end
	end
end

-- Place a set-piece mesh (art/blender/cog_*.py, Meshes kind "setpiece": the pivot is the Blender origin, normally the
-- ground under the piece) at cf, optionally scaled. Only the Body collides (collide = false: nothing does). If the mesh
-- did not load, a plain steel block of its size stands in so the place keeps its cover and silhouette.
local function setPiece(g: Instance, key: string, cf: CFrame, collide: boolean?, scale: number?): Model?
	local m = Assets.get(key, { anchored = true })
	if not m then
		local size = (Assets.size(key) or Vector3.new(8, 8, 8)) * (scale or 1)
		part(g, size, cf * CFrame.new(0, size.Y / 2, 0), STEEL_D, collide ~= false)
		return nil
	end
	if scale and scale ~= 1 then
		m:ScaleTo(scale)
	end
	m:PivotTo(cf)
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = collide ~= false and p.Name == "Body"
			count += 1
		end
	end
	m.Parent = g
	return m
end

-- Part-built fallback drone (used only when the cog_drone_wreck mesh fails to load). L/W: the fuselage frame.
local function partWreck(g: Instance, L: (number, number, number) -> CFrame, W: (number, number, number) -> Vector3)
	-- hull
	ball(g, Vector3.new(9.5, 9.5, 9.5), L(0, 0, 3), STEEL, true)
	zcyl(g, 9.5, 23, L(0, 0, 14.5), STEEL, true)
	for _, t in { 8, 13, 18, 23 } do
		zcyl(g, 9.9, 1.3, L(0, 0, t), HAZ, false)
	end
	zcyl(g, 10.4, 1.6, L(0, 0, 26), STEEL_D, false)
	glow(g, Vector3.new(5.2, 3.4, 6.2), L(0, 4.3, 7), GLASS, true, 0.3) -- cockpit glass
	part(g, Vector3.new(3.4, 0.4, 4.2), L(0, 4.9, 16) * CFrame.Angles(math.rad(-38), 0, 0), STEEL_D, false) -- hatch hanging open

	-- broken cargo rack: frame rings, a snapped rail, containers still hanging on
	for _, c in { { -4.4, 3.7 }, { 4.4, 3.7 }, { 4.4, -3.7 } } do
		pipe(g, W(c[1], c[2], 26.5), W(c[1], c[2], 38), 0.8, STEEL_D, false)
	end
	pipe(g, W(-4.4, -3.7, 26.5), W(-4.4, -3.7, 33), 0.8, STEEL_D, false)
	pipe(g, W(-4.4, -3.7, 33), W(-6.8, -6.4, 35), 0.8, STEEL_D, false) -- bent end
	local function ring(t: number, skip: number)
		local pts = { { -4.4, 3.7 }, { 4.4, 3.7 }, { 4.4, -3.7 }, { -4.4, -3.7 } }
		for i = 1, 4 do
			if i ~= skip then
				local a, b = pts[i], pts[i % 4 + 1]
				pipe(g, W(a[1], a[2], t), W(b[1], b[2], t), 0.8, STEEL_D, false)
			end
		end
	end
	ring(28, 0)
	ring(33, 2)
	ring(38, 3)
	part(g, Vector3.new(8.8, 0.5, 11), L(0, -3.9, 32.5), STEEL_D, false)
	local function container(cf: CFrame)
		part(g, Vector3.new(6.4, 5.4, 6.6), cf, CRATE, false)
		for _, z in { -2.1, 2.1 } do
			part(g, Vector3.new(6.5, 5.5, 1.1), cf * CFrame.new(0, 0, z), HAZ, false)
		end
	end
	container(L(0.3, -0.8, 31))
	container(L(5.4, -3.8, 36.5) * CFrame.Angles(0.1, 0.15, math.rad(28)))

	-- engines: left one still glows, right one hangs off and throws sparks
	pipe(g, W(-4.5, -1, 22), W(-9, -1.6, 22), 0.9, STEEL_D, false)
	pipe(g, W(-9, -1.6, 17), W(-9, -1.6, 27), 4.6, STEEL_L, false)
	ball(g, Vector3.new(4.6, 4.6, 4.6), L(-9, -1.6, 17), STEEL_L, false)
	zcyl(g, 3.8, 0.5, L(-9, -1.6, 27.2), TEAL, false, { Material = Enum.Material.Neon, CastShadow = false })
	pipe(g, W(4.5, -1, 22), W(7.5, -4, 22.6), 0.9, STEEL_D, false)
	pipe(g, W(7.5, -4.5, 17.5), W(10.2, -6.4, 26), 4.4, STEEL_L, false)
	zcyl(g, 3.6, 0.4, L(10.2, -6.4, 26.2), SOOT, false)
	local sp = emitterHost(g, W(10.2, -6.4, 26.6))
	sparks(sp, 7)
	smoke(sp, RGB(46, 44, 46), 4, 6, 9, 9)

	-- tail: boom snapped off, fin and stabiliser bent
	pipe(g, W(0, 0, 38.5), W(0.6, 1.5, 45), 2.2, STEEL_D, false)
	part(g, Vector3.new(0.9, 8, 5), L(0.4, 5.5, 43.5) * CFrame.Angles(0, 0, math.rad(8)), STEEL, false)
	part(g, Vector3.new(11, 0.8, 3.6), L(0.3, 1.8, 44) * CFrame.Angles(0, 0, math.rad(-14)), STEEL, false)
	smoke(emitterHost(g, W(0.6, 1.8, 45.2)), RGB(52, 48, 48), 3.5, 3, 8, 6)
end

local function buildDrone(root: Instance, crashP: Vector3, spillP: Vector3, refP: Vector3, _look: { sand: Color3, rock: Color3 }, anchors: any)
	local g = folder(root, "CrashedDrone")
	local toRef = dirTo(crashP, refP)
	local toSpill = dirTo(crashP, spillP)
	-- the wreck lies beside the landing circle, on the side away from the spilled trail (the squad lands on the crater floor)
	local perp = Vector3.new(-toRef.Z, 0, toRef.X)
	if perp:Dot(toSpill) > 0 then
		perp = -perp
	end
	local nx, nz = crashP.X + perp.X * 25, crashP.Z + perp.Z * 25
	local nose = Vector3.new(nx, gy(nx, nz) - 2.6, nz)
	local tailH = (perp * 0.7 - toRef * 0.7).Unit
	local pitch = math.rad(30)
	local tailDir = tailH * math.cos(pitch) + Vector3.yAxis * math.sin(pitch)
	local F = CFrame.lookAt(nose, nose + tailDir) * CFrame.Angles(0, 0, math.rad(12))
	-- L(x, y, t): x across, y up, t = distance from the nose along the fuselage (toward the tail)
	local function L(x: number, y: number, t: number): CFrame
		return F * CFrame.new(x, y, -t)
	end
	local function W(x: number, y: number, t: number): Vector3
		return L(x, y, t).Position
	end

	-- the wreck: the Blender mesh (modelled in its crash pose) or, if it fails to load, the part-built drone
	local wreck = Assets.get("cog_drone_wreck", { anchored = true })
	local wreckCF: CFrame? = nil
	if wreck then
		-- origin = the ground under the middle of the hull; the nose (model -Z) lies where the part drone's nose did
		local ox, oz = nx + tailH.X * 13, nz + tailH.Z * 13
		local o = Vector3.new(ox, gy(ox, oz), oz)
		local cf = CFrame.lookAt(o, o - tailH)
		wreckCF = cf
		wreck:PivotTo(cf)
		for _, p in wreck:GetDescendants() do
			if p:IsA("BasePart") then
				p.Anchored = true
				p.CanCollide = p.Name == "Body"
				count += 1
			end
		end
		wreck.Parent = g
		for _, k in { "StackL", "StackR" } do
			smoke(emitterHost(g, cf * WRECK_SPOTS[k]), RGB(52, 48, 48), 3.5, 3, 8, 6)
		end
		local sp = emitterHost(g, cf * WRECK_SPOTS.Break)
		sparks(sp, 7)
		smoke(sp, RGB(46, 44, 46), 4, 6, 9, 9)
	else
		partWreck(g, L, W)
	end

	-- a third container that fell and lies on the ground beside the wreck
	local side = tailH:Cross(Vector3.yAxis)
	local fx, fz = nose.X + tailH.X * 27 + side.X * 6, nose.Z + tailH.Z * 27 + side.Z * 6
	local fallen = CFrame.new(fx, gy(fx, fz) + 2.0, fz) * CFrame.Angles(0, rnd:NextNumber(0, TAU), math.rad(16))
	part(g, Vector3.new(6.4, 5.4, 6.6), fallen, CRATE, true)
	for _, z in { -2.1, 2.1 } do
		part(g, Vector3.new(6.5, 5.5, 1.1), fallen * CFrame.new(0, 0, z), HAZ, false)
	end

	-- crash scar: scorched ground (painted terrain, soft edges) and kicked-up mounds around the nose
	local sx, sz = nose.X, nose.Z
	scorch(Vector3.new(sx, 0, sz), 13)
	for i = 1, 6 do
		local a = i / 6 * TAU + rnd:NextNumber(-0.3, 0.3)
		local d = rnd:NextNumber(8, 12)
		local mx, mz = sx + math.cos(a) * d, sz + math.sin(a) * d
		local w = rnd:NextNumber(6, 9)
		-- a terrain mound (soft sand edges; the old shiny plastic balls read as eggs)
		Workspace.Terrain:FillBall(Vector3.new(mx, lowAt(mx, mz, 2) - w * 0.22, mz), w * 0.45, Enum.Material.Sand)
	end

	-- flight log: a lit panel on the flank, about chest height (the mesh's up-facing flank near the nose)
	local pp: Vector3, out: Vector3
	if wreckCF then
		out = wreckCF:VectorToWorldSpace(WRECK_LOG_NORMAL)
		pp = wreckCF * WRECK_SPOTS.FlightLog + out * 0.2
	else
		local sgn = if F.RightVector:Dot(crashP - nose) >= 0 then 1 else -1
		local bestT, bestErr = 9, 99
		for t = 5, 16 do
			local p = W(sgn * 4.9, -0.2, t)
			local err = math.abs((p.Y - gy(p.X, p.Z)) - 3.2)
			if err < bestErr then
				bestT, bestErr = t, err
			end
		end
		pp = W(sgn * 4.9, -0.2, bestT)
		out = F.RightVector * sgn
	end
	local pcf = CFrame.lookAt(pp, pp + out)
	part(g, Vector3.new(4.2, 3, 0.4), pcf * CFrame.new(0, 0, 0.15), STEEL_D, false)
	local screen = glow(g, Vector3.new(3.2, 2, 0.2), pcf * CFrame.new(0, 0, -0.1), TEAL, false, 0.1)
	glow(g, Vector3.new(2.4, 0.22, 0.12), pcf * CFrame.new(0, 0.4, -0.25), RGB(220, 255, 250), false)
	glow(g, Vector3.new(1.6, 0.22, 0.12), pcf * CFrame.new(-0.4, -0.1, -0.25), RGB(220, 255, 250), false)
	light(screen, TEAL, 14, 1.2)
	anchors.flightLog = CFrame.lookAt(pp + out * 0.5, pp + out * 5)
	anchors.flightLogPart = screen

	-- debris along the line from the crash to the spilled crate
	local a0 = crashP + toSpill * 20
	local a1 = spillP - toSpill * 18
	local len = (a1 - a0).Magnitude
	if len > 12 then
		local n = math.clamp(math.floor(len / 9), 5, 18)
		local lat = Vector3.new(-toSpill.Z, 0, toSpill.X)
		for i = 1, n do
			local t = (i - 0.5) / n
			local base = a0:Lerp(a1, t) + lat * rnd:NextNumber(-7, 7)
			local x, z = base.X, base.Z
			local y = gy(x, z)
			local kind = rnd:NextInteger(1, 6)
			if kind == 1 then
				scorch(Vector3.new(x, 0, z), rnd:NextNumber(3, 5))
			elseif kind == 2 then
				part(g, Vector3.new(rnd:NextNumber(2.5, 4.5), 0.4, rnd:NextNumber(2, 3.5)), CFrame.new(x, y + 0.45, z) * CFrame.Angles(math.rad(rnd:NextNumber(-12, 12)), rnd:NextNumber(0, TAU), math.rad(rnd:NextNumber(-12, 12))), STEEL, false)
			elseif kind == 3 then
				xcyl(g, rnd:NextNumber(2.4, 4), 0.7, CFrame.new(x, y + 1.2, z) * CFrame.Angles(rnd:NextNumber(-0.5, 0.5), rnd:NextNumber(0, TAU), rnd:NextNumber(1, 1.4)), RUST, false)
			elseif kind == 4 then
				local w = rnd:NextNumber(1.8, 2.6)
				part(g, Vector3.new(w, w * 0.9, w * 1.2), CFrame.new(x, y + w * 0.4, z) * CFrame.Angles(0.2, rnd:NextNumber(0, TAU), 0.15), CRATE, false)
				part(g, Vector3.new(w + 0.1, w * 0.2, w * 1.2 + 0.1), CFrame.new(x, y + w * 0.5, z) * CFrame.Angles(0.2, rnd:NextNumber(0, TAU), 0.15), HAZ, false)
			elseif kind == 5 then
				local a = rnd:NextNumber(0, TAU)
				local d = Vector3.new(math.cos(a), 0.12, math.sin(a)) * rnd:NextNumber(2.5, 4)
				pipe(g, Vector3.new(x, y + 0.5, z) - d, Vector3.new(x, y + 0.5, z) + d, 0.6, STEEL_D, false)
			else
				local w = rnd:NextNumber(1.4, 2.2)
				if biomeName == "desert" then
					part(g, Vector3.new(w * 1.4, 0.35, w), CFrame.new(x, lowAt(x, z, w * 0.5) + 0.15, z) * CFrame.Angles(math.rad(rnd:NextNumber(-14, 14)), rnd:NextNumber(0, TAU), math.rad(rnd:NextNumber(-14, 14))), STEEL_L, false)
				else
					ball(g, Vector3.new(w, w, w), CFrame.new(x, y + w * 0.4, z), STEEL_L, false)
				end
			end
		end
	end
end

local function buildSpill(root: Instance, S: Vector3, crashP: Vector3, anchors: any)
	local g = folder(root, "SpilledCrate")
	local toCrash = dirTo(S, crashP)
	local f = CFrame.lookAt(S, S + toCrash) -- -Z = the open side, toward the crash
	local function Wp(x: number, y: number, z: number): CFrame
		return f * CFrame.new(x, y, z)
	end
	part(g, Vector3.new(8, 0.8, 6), Wp(0, 0.4, 0), STEEL_D, false)
	part(g, Vector3.new(8, 4.4, 0.7), Wp(0, 2.2, 3), STEEL_L, true)
	part(g, Vector3.new(8.1, 1, 0.8), Wp(0, 3.4, 3), HAZ, false)
	part(g, Vector3.new(0.7, 4, 6), Wp(-4, 2, 0) * CFrame.Angles(0, 0, math.rad(6)), STEEL_L, false)
	part(g, Vector3.new(0.7, 4, 6), Wp(5.9, 0.9, 0) * CFrame.Angles(0, 0, math.rad(-74)), STEEL_L, false) -- the wall that burst outward
	part(g, Vector3.new(7.6, 0.5, 5.6), Wp(-8.5, 0.6, 2) * CFrame.Angles(0, math.rad(70), math.rad(6)), STEEL, false) -- flung lid
	part(g, Vector3.new(7.7, 0.2, 1.1), Wp(-8.5, 0.9, 2) * CFrame.Angles(0, math.rad(70), math.rad(6)), HAZ, false)
	for _ = 1, 5 do
		local d = rnd:NextNumber(1.2, 2.2)
		local px, pz = rnd:NextNumber(-7, 7), rnd:NextNumber(-7, 2)
		ball(g, Vector3.new(d, d, d), Wp(px, d * 0.4, pz), RGB(200, 205, 210), false)
	end
	if biomeName == "desert" then
		scorch(Wp(0, 0, -3).Position, 8.5)
	else
		vcyl(g, 16, 0.15, Wp(0, 0.08, -3), SOOT, false)
	end
	local spots = { Vector3.new(-3.2, 0, -3.6), Vector3.new(0, 0, -4.8), Vector3.new(3.2, 0, -3.6) }
	local first: Part? = nil
	for _, o in spots do
		local p = f:PointToWorldSpace(o)
		p = Vector3.new(p.X, gy(p.X, p.Z), p.Z)
		local ringPart = glow(g, Vector3.new(0.12, 3.4, 3.4), CFrame.new(p + Vector3.new(0, 0.14, 0)) * CFrame.Angles(0, 0, PI / 2), TEAL, false, 0.35)
		ringPart.Shape = Enum.PartType.Cylinder
		first = first or ringPart
		table.insert(anchors.cellSpots.spilled, spot(p, toCrash))
	end
	if first then
		light(first, TEAL, 18, 1.0)
	end
	sparks(emitterHost(g, Wp(0, 3, 3).Position), 2)
end

-- =============================================================================================================================
-- 2. Signal Mesa: relay mast, generator housing, cover crates, power line to the refinery
-- =============================================================================================================================
local function pylon(g: Instance, base: Vector3, along: Vector3): { Vector3 }
	local side = Vector3.new(-along.Z, 0, along.X)
	local low = lowAt(base.X, base.Z, 3) - 0.5
	local B = Vector3.new(base.X, low, base.Z)
	for _, s in { -1, 1 } do
		pipe(g, B + side * (3.4 * s), B + side * (1.1 * s) + Vector3.new(0, 21, 0), 0.9, STEEL_D, false)
		part(g, Vector3.new(2, 0.7, 2), CFrame.new(B + side * (3.4 * s) + Vector3.new(0, 0.6, 0)), STEEL, false)
	end
	pipe(g, B + side * 4.6 + Vector3.new(0, 14, 0), B - side * 4.6 + Vector3.new(0, 14, 0), 0.8, STEEL_D, false)
	pipe(g, B + side * 6.4 + Vector3.new(0, 20.4, 0), B - side * 6.4 + Vector3.new(0, 20.4, 0), 0.9, STEEL, false)
	ball(g, Vector3.new(1.7, 1.7, 1.7), CFrame.new(B + Vector3.new(0, 21.8, 0)), HAZ, false)
	local tops = {}
	for _, s in { -1, 0, 1 } do
		local top = B + side * (5.6 * s) + Vector3.new(0, 19.6, 0)
		vcyl(g, 0.7, 1.6, CFrame.new(top), RGB(190, 205, 205), false)
		table.insert(tops, top - Vector3.new(0, 0.9, 0))
	end
	return tops
end

local function buildMesa(root: Instance, m: Vector3, refP: Vector3, anchors: any)
	local g = folder(root, "SignalMesa")
	local u = dirTo(m, refP) -- the ramp side
	local pr = Vector3.new(-u.Z, 0, u.X)
	local topY = lowAt(m.X, m.Z, 4)
	local mx, mz = m.X, m.Z
	local function Y(h: number): Vector3
		return Vector3.new(mx, topY + h, mz)
	end

	-- relay mast (~74 studs, art/blender/cog_sites.py): big dish at 54 toward the refinery (model front), small dish at
	-- 36 toward -pr, cross arm at 66; the blinking beacon stays a part
	setPiece(g, "cog_relay_mast", CFrame.lookAt(Y(0), Y(0) + u))
	-- guy cables
	for i = 0, 2 do
		local a = i / 3 * TAU + 0.5
		local ax, az = mx + math.cos(a) * 17, mz + math.sin(a) * 17
		local ay = math.max(gy(ax, az), topY - 0.5)
		pipe(g, Y(44), Vector3.new(ax, ay + 0.4, az), 0.3, SOOT, false)
		vcyl(g, 1.6, 1.2, CFrame.new(ax, ay + 0.3, az), STEEL_D, false)
	end
	-- beacon
	local lamp = glow(g, Vector3.new(2.8, 2.8, 2.8), CFrame.new(Y(73.4)), RED, true)
	local lt = light(lamp, RED, 60, 2.5)
	blink(lamp, lt)
	anchors.mastLight = lamp

	-- generator housing beside the mast, sockets in front (facing the ramp)
	local gpos
	for _, cand in { m + pr * 13, m - pr * 13, m - u * 12 } do
		if math.abs(gy(cand.X, cand.Z) - topY) < 1.8 and math.abs(highAt(cand.X, cand.Z, 7) - topY) < 2.6 then
			gpos = cand
			break
		end
	end
	gpos = gpos or (m + pr * 13)
	local gb = Vector3.new(gpos.X, lowAt(gpos.X, gpos.Z, 6.5) - 0.2, gpos.Z)
	local hf = CFrame.lookAt(gb, gb + u)
	local function H(x: number, y: number, z: number): CFrame
		return hf * CFrame.new(x, y, z)
	end
	part(g, Vector3.new(13, 0.9, 15), H(0, 0.4, -1.2), STEEL_D, true)
	xcyl(g, 6.2, 10, H(0, 4.3, 1), STEEL, true)
	for _, s in { -1, 1 } do
		ball(g, Vector3.new(6.4, 6.4, 6.4), H(5 * s, 4.3, 1), STEEL, false)
		xcyl(g, 6.5, 1.2, H(2.6 * s, 4.3, 1), HAZ, false)
	end
	part(g, Vector3.new(4.2, 5.4, 3.6), H(0, 3.2, 5), STEEL_L, true)
	part(g, Vector3.new(5, 3.4, 1.2), H(0, 2.6, -2.7), STEEL_D, true)
	for i, c in { TEAL, HAZ, RED } do
		glow(g, Vector3.new(0.6, 0.6, 0.6), H(-1.4 + i * 1.1, 3.6, -3.4), c, true)
	end
	local ex = vcyl(g, 1.1, 4, H(2.8, 8.2, 1), STEEL_D, false)
	smoke(emitterHost(g, ex.CFrame.Position + Vector3.new(0, 2.2, 0)), RGB(70, 64, 60), 2.2, 2, 7, 5)
	pipe(g, H(0, 6, 5).Position, Y(3.5), 0.6, SOOT, false)
	local firstRing: Part? = nil
	for _, x in { -3.6, 0, 3.6 } do
		vcyl(g, 3.2, 0.9, H(x, 1.3, -6.4), STEEL_D, false)
		local r = glow(g, Vector3.new(0.12, 3.5, 3.5), H(x, 1.78, -6.4) * CFrame.Angles(0, 0, PI / 2), TEAL, false, 0.2)
		r.Shape = Enum.PartType.Cylinder
		firstRing = firstRing or r
		table.insert(anchors.cellSpots.mesa, spot(H(x, 1.75, -6.4).Position, u))
	end
	if firstRing then
		light(firstRing, TEAL, 16, 1.0)
	end

	-- cover at the top of the ramp: find where the top ends, back off from it, leave the middle open
	local edge = 30
	for d = 4, 60, 2 do
		local p = m + u * d
		if gy(p.X, p.Z) < topY - 1.5 then
			edge = d
			break
		end
	end
	local dTop = math.max(edge - 7, 12)
	local function atRamp(d: number, lat: number): Vector3
		local p = m + u * d + pr * lat
		return Vector3.new(p.X, lowAt(p.X, p.Z, 1.5), p.Z)
	end
	local c1 = atRamp(dTop, -8.5)
	crate(g, c1, 0.3, 4.2, 3.4, 4.2, true)
	crate(g, c1 + Vector3.new(0, 3.1, 0), 0.7, 3, 2.4, 3, false)
	crate(g, atRamp(dTop - 1, 8), -0.4, 4.6, 3, 3.6, true)
	crate(g, atRamp(dTop + 1, 11.5), 0.2, 3.2, 2.6, 3.2, true)
	for _, b in { { dTop - 2, -5.8 }, { dTop - 3, 5.4 } } do
		local p = atRamp(b[1], b[2])
		vcyl(g, 2.2, 3.1, CFrame.new(p + Vector3.new(0, 1.3, 0)), HAZ, true)
		vcyl(g, 2.3, 0.35, CFrame.new(p + Vector3.new(0, 2.2, 0)), STEEL_D, false)
	end
end

local function buildPowerLine(root: Instance, m: Vector3, refP: Vector3)
	local g = folder(root, "PowerLine")
	local u = dirTo(m, refP)
	local total = (Vector3.new(refP.X, 0, refP.Z) - Vector3.new(m.X, 0, m.Z)).Magnitude
	local prev: { Vector3 }? = nil
	local d = 58
	while d <= total - 52 do
		local p = m + u * d
		if nearSide(p.X, p.Z, 20) then
			prev = nil
		else
			local tops = pylon(g, Vector3.new(p.X, gy(p.X, p.Z), p.Z), u)
			if prev then
				for i = 1, 3 do
					local a, b = prev[i], tops[i]
					local last = a
					for k = 1, 4 do
						local t = k / 4
						local q = a:Lerp(b, t) - Vector3.new(0, 3 * 4 * t * (1 - t), 0)
						pipe(g, last, q, 0.28, SOOT, false)
						last = q
					end
				end
			end
			prev = tops
		end
		d += 40
	end
end

-- =============================================================================================================================
-- 3. the Quarry: conveyor, digger, crane, rails and cover on the terraces
-- =============================================================================================================================
local function buildQuarry(root: Instance, Q: Vector3, refP: Vector3, anchors: any)
	local g = folder(root, "Quarry")
	local depth = (MapPlan.places.quarry and MapPlan.places.quarry.depth) or 18
	local floorY = gy(Q.X, Q.Z)
	local u = dirTo(Q, refP) -- the ramp side
	local pr = Vector3.new(-u.Z, 0, u.X)

	-- floor radius along the belt line
	local R0 = 40
	for _, dir in { pr, -pr } do
		for r = 2, 60, 2 do
			local p = Q + dir * r
			if gy(p.X, p.Z) >= floorY + 2.5 then
				R0 = math.min(R0, r)
				break
			end
		end
	end
	R0 = if R0 >= 40 then 22 else R0
	local half = math.clamp(R0 - 4, 7, 16)

	-- conveyor belt across the pit floor
	local bf = CFrame.lookAt(Vector3.new(Q.X, 0, Q.Z), Vector3.new(Q.X, 0, Q.Z) + pr)
	local function Bp(s: number, lat: number): Vector3
		local p = bf:PointToWorldSpace(Vector3.new(lat, 0, -s))
		return Vector3.new(p.X, 0, p.Z)
	end
	local topY = floorY
	for _, s in { -half, -half / 2, 0, half / 2, half } do
		local p = Bp(s, 0)
		topY = math.max(topY, gy(p.X, p.Z))
	end
	topY += 1.3
	local function B(s: number, lat: number, y: number): CFrame
		local p = Bp(s, lat)
		return CFrame.lookAt(Vector3.new(p.X, y, p.Z), Vector3.new(p.X, y, p.Z) + pr)
	end
	part(g, Vector3.new(4.6, 0.9, half * 2), B(0, 0, topY - 0.45), STEEL_L, true)
	for _, lat in { -2.4, 2.4 } do
		part(g, Vector3.new(0.5, 0.7, half * 2), B(0, lat, topY + 0.2), STEEL_D, false)
	end
	for s = -half + 1.5, half - 1, 3.2 do
		xcyl(g, 0.9, 4.4, B(s, 0, topY - 0.2), STEEL_D, false)
	end
	for _, s in { -half, half } do
		xcyl(g, 2, 5, B(s, 0, topY - 0.6), STEEL_D, false)
	end
	for _, s in { -half * 0.8, -half * 0.27, half * 0.27, half * 0.8 } do
		for _, lat in { -2, 2 } do
			local p = Bp(s, lat)
			local gh = gy(p.X, p.Z)
			local h = math.max(topY - 0.9 - gh, 0.5)
			vcyl(g, 0.8, h, CFrame.new(p.X, gh + h / 2, p.Z), STEEL_D, false)
		end
	end
	-- hopper over one end
	local hp = Bp(-half * 0.55, 0)
	vcyl(g, 5.4, 2.4, CFrame.new(hp.X, topY + 4.4, hp.Z), STEEL, false)
	vcyl(g, 2.6, 2.4, CFrame.new(hp.X, topY + 2.6, hp.Z), STEEL_D, false)
	for _, o in { { 2.2, 2.2 }, { -2.2, 2.2 }, { 2.2, -2.2 }, { -2.2, -2.2 } } do
		local gh = gy(hp.X + o[1], hp.Z + o[2])
		pipe(g, Vector3.new(hp.X + o[1], gh - 0.2, hp.Z + o[2]), Vector3.new(hp.X + o[1] * 0.8, topY + 3.6, hp.Z + o[2] * 0.8), 0.7, STEEL_D, false)
	end
	-- ore lumps on the belt, a marker under each resting cell
	for _, s in { half * 0.78, -half * 0.8 } do
		for _ = 1, 3 do
			local p = Bp(s + rnd:NextNumber(-1.2, 1.2), rnd:NextNumber(-1.4, 1.4))
			local w = rnd:NextNumber(1.1, 2)
			ball(g, Vector3.new(w, w * 0.8, w), CFrame.new(p.X, topY + w * 0.3, p.Z), jit(RGB(70, 60, 64), 0.1), false)
		end
		local p = Bp(s, 0.4)
		glow(g, Vector3.new(0.5, 0.5, 0.5), CFrame.new(p.X, topY + 1.1, p.Z), TEAL, true)
	end
	local step = if half >= 9 then 5 else half * 0.55
	for _, s in { -step, 0, step } do
		local p = Bp(s, 0)
		vcyl(g, 2.8, 0.1, CFrame.new(p.X, topY + 0.07, p.Z), HAZ, false)
		table.insert(anchors.cellSpots.quarry, spot(Vector3.new(p.X, topY, p.Z), u))
	end

	-- parked digger, nose toward the belt
	local dpos = Q - u * math.clamp(R0 - 8, 6, 14)
	local dg = Vector3.new(dpos.X, lowAt(dpos.X, dpos.Z, 4), dpos.Z)
	local df = CFrame.lookAt(dg, dg + dirTo(dpos, Q))
	setPiece(g, "cog_digger", df) -- art/blender/cog_sites.py: boom and bucket reach ~17 toward the belt

	-- crane on the rim, its jib hanging over the belt
	local rimR = 36
	for r = R0, 70, 2 do
		local p = Q + pr * r
		if gy(p.X, p.Z) >= floorY + depth * 0.75 then
			rimR = r
			break
		end
	end
	local cp = Q + pr * (rimR + 6)
	local cb = Vector3.new(cp.X, lowAt(cp.X, cp.Z, 3.5), cp.Z)
	local cf = CFrame.lookAt(cb, cb - pr)
	setPiece(g, "cog_crane", cf) -- art/blender/cog_sites.py: jib 27 forward, hook hanging at 25 over the belt

	-- terraces: standing spots on the upper steps, rail along the lip, cover between spots
	local rampA = angOf(u)
	local cand = {}
	for k = 0, 23 do
		local a = k / 24 * TAU
		if math.abs(angDiff(a, rampA)) > math.rad(40) then
			for r = 8, 60, 2 do
				local p = polar(Q, a, r)
				if p.Y >= floorY + depth * 0.6 then
					local q = polar(Q, a, r + 4)
					if q.Y >= floorY + depth * 0.5 then
						table.insert(cand, { a = a, r = r })
					end
					break
				end
			end
		end
	end
	local chosen = {}
	for _, c in cand do
		local okSep = true
		for _, o in chosen do
			if math.abs(angDiff(c.a, o.a)) < math.rad(32) then
				okSep = false
				break
			end
		end
		if okSep and #chosen < 9 then
			table.insert(chosen, c)
		end
	end
	for k = 0, 23 do
		if #chosen >= 6 then
			break
		end
		local a = k / 24 * TAU
		local okSep = math.abs(angDiff(a, rampA)) > math.rad(40)
		for _, o in chosen do
			if math.abs(angDiff(a, o.a)) < math.rad(30) then
				okSep = false
			end
		end
		if okSep then
			table.insert(chosen, { a = a, r = math.max(R0 + 8, 26) })
		end
	end
	local qc = Vector3.new(Q.X, 0, Q.Z)
	for i, c in chosen do
		local sp = polar(Q, c.a, c.r + 3.2)
		table.insert(anchors.terraces, CFrame.lookAt(sp, Vector3.new(qc.X, sp.Y, qc.Z)))
		local tan = Vector3.new(-math.sin(c.a), 0, math.cos(c.a))
		local lip = polar(Q, c.a, c.r + 1.2)
		for _, s in { -3.5, 3.5 } do
			local px, pz = lip.X + tan.X * s, lip.Z + tan.Z * s
			vcyl(g, 0.5, 2.5, CFrame.new(px, gy(px, pz) + 1.0, pz), STEEL_L, false)
		end
		pipe(g, lip + tan * -3.5 + Vector3.new(0, 2.3, 0), lip + tan * 3.5 + Vector3.new(0, 2.3, 0), 0.4, HAZ, false)
		pipe(g, lip + tan * -3.5 + Vector3.new(0, 1.2, 0), lip + tan * 3.5 + Vector3.new(0, 1.2, 0), 0.35, STEEL_L, false)
		if i % 2 == 1 then
			local ca = c.a + math.rad(8)
			local cp2 = polar(Q, ca, c.r + 2.2)
			local ctan = Vector3.new(-math.sin(ca), 0, math.cos(ca))
			local low = lowAt(cp2.X, cp2.Z, 2.4)
			local bcf = CFrame.lookAt(Vector3.new(cp2.X, low + 1.1, cp2.Z), Vector3.new(cp2.X, low + 1.1, cp2.Z) + ctan)
			part(g, Vector3.new(2, 2.8, 5.2), bcf, jit(CRATE, 0.05), true)
			zcyl(g, 2.2, 5.2, bcf * CFrame.new(0, 1.4, 0), STEEL_L, false)
		end
	end
end

-- =============================================================================================================================
-- 4. Walker Graveyard: a huge fallen COG walker half-buried in sand
-- =============================================================================================================================
local function buildGraveyard(root: Instance, G: Vector3, refP: Vector3, anchors: any, look: { sand: Color3, rock: Color3 })
	local g = folder(root, "WalkerGraveyard")
	local toRef = dirTo(G, refP)
	local axis = Vector3.new(-toRef.Z, 0, toRef.X) -- spine direction, head at +axis
	local side = Vector3.new(-axis.Z, 0, axis.X) -- = away from the refinery
	local function P(s: number, l: number, h: number): Vector3
		local x, z = G.X + axis.X * s + side.X * l, G.Z + axis.Z * s + side.Z * l
		return Vector3.new(x, h, z)
	end
	local function onG(s: number, l: number): Vector3
		local p = P(s, l, 0)
		return Vector3.new(p.X, gy(p.X, p.Z), p.Z)
	end

	-- ribs
	local crowns = {}
	local RIBS = 6
	local SEGS = 6
	for i = 0, RIBS - 1 do
		local s = -19 + 8.6 * i
		local w = math.sin(i / (RIBS - 1) * PI)
		local rx, ry = 11.5 + 2.5 * w, 24 + 7 * w
		local baseY = math.min(onG(s, rx).Y, onG(s, -rx).Y) - 1.2
		local pts = {}
		for k = 0, SEGS do
			local th = PI * k / SEGS
			pts[k] = P(s, rx * math.cos(th), baseY + ry * math.sin(th))
		end
		local lastK = SEGS
		local firstK = 0
		if i == 1 then
			lastK = 3 -- right side snapped off at the crown
		elseif i == 4 then
			firstK = 2 -- left side snapped off high up
		end
		-- the rib: an armoured arch mesh (art/blender/cog_sites.py, span 25 x height 27) scaled to this rib; the snapped
		-- ones use the half rib, turned so its standing side is the one left (model -X = the side that stands).
		-- The mesh does not collide (its hull would fill the arch); the two foot segments get invisible solid pipes.
		local key = if firstK == 0 and lastK == SEGS then "cog_walker_rib" else "cog_walker_rib_half"
		local right = if lastK < SEGS then -side else side
		setPiece(g, key, CFrame.fromMatrix(P(s, 0, baseY), right, Vector3.yAxis), false, ry / 27)
		for _, k in { firstK, lastK - 1 } do
			if k == 0 or k == SEGS - 1 then
				pipe(g, pts[k], pts[k + 1], 2.4, STEEL_D, true, { Transparency = 1, CastShadow = false })
			end
		end
		crowns[i] = pts[3]
		-- the snapped-off halves lie in the sand
		if i == 1 then
			local a = onG(s - 2, -rx - 5)
			pipe(g, a + Vector3.new(0, 1.2, 0), a + side * -3 + axis * 7 + Vector3.new(0, 1.4, 0), 2, jit(STEEL, 0.06), false)
		elseif i == 4 then
			local a = onG(s + 2, rx + 6)
			pipe(g, a + Vector3.new(0, 1.2, 0), a + side * 4 + axis * -6 + Vector3.new(0, 1.4, 0), 2, jit(STEEL, 0.06), false)
		end
	end
	-- spine along the crowns, neck to the head, tail to the pelvis
	for i = 0, RIBS - 1 do
		ball(g, Vector3.new(3.6, 3.6, 3.6), CFrame.new(crowns[i]), STEEL_D, false)
		if i < RIBS - 1 then
			pipe(g, crowns[i], crowns[i + 1], 2.6, STEEL, false)
		end
	end

	-- head: a big skull lying on its cheek, face along the spine
	local hpos = onG(34, 0) + Vector3.new(0, 7, 0)
	local hf = CFrame.lookAt(hpos, hpos + axis) * CFrame.Angles(math.rad(-10), 0, math.rad(15))
	pipe(g, crowns[RIBS - 1], hpos + Vector3.new(0, 2, 0) - axis * 5, 4.8, STEEL, false)
	-- the skull mesh (art/blender/cog_sites.py, centred origin, face at -Z): one eye lens still glows
	local skull = setPiece(g, "cog_walker_skull", hf)
	local eye = skull and skull:FindFirstChild("Glow")
	if eye and eye:IsA("BasePart") then
		light(eye, RGB(255, 90, 40), 18, 0.8)
	end

	-- pelvis and a broken leg that runs out to the side
	local pel = onG(-29, 0) + Vector3.new(0, 4, 0)
	ball(g, Vector3.new(11, 8, 10), CFrame.new(pel), STEEL, true)
	pipe(g, crowns[0], pel + Vector3.new(0, 2.5, 0) + axis * 3, 2.6, STEEL, false)
	local hip = onG(-30, 5) + Vector3.new(0, 4.5, 0)
	ball(g, Vector3.new(6, 6, 6), CFrame.new(hip), STEEL_D, false)
	local knee = onG(-36, 15) + Vector3.new(0, 3.4, 0)
	pipe(g, hip, knee, 4.4, STEEL, true)
	ball(g, Vector3.new(6.4, 6.4, 6.4), CFrame.new(knee), STEEL_D, false)
	local shinEnd = onG(-32, 25) + Vector3.new(0, 1.6, 0)
	pipe(g, knee, shinEnd, 3.4, STEEL, true)
	local foot = onG(-22, 27)
	part(g, Vector3.new(9, 2, 12), CFrame.lookAt(foot + Vector3.new(0, 1, 0), foot + Vector3.new(0, 1, 0) + axis) * CFrame.Angles(0, 0.4, math.rad(10)), STEEL_D, true)
	pipe(g, hip + Vector3.new(0, 1, 0), knee + Vector3.new(0, 1.5, 1), 0.7, STEEL_L, false)
	pipe(g, knee + Vector3.new(0, 1, 0), shinEnd + Vector3.new(0, 1.8, 0), 0.6, STEEL_L, false)

	-- chest cavity: the dead core, the floor plate, and where the cells rest
	local cc = onG(2.5, 0)
	ball(g, Vector3.new(7, 7, 7), CFrame.new(cc + Vector3.new(0, 3.6, 0)), STEEL_D, true)
	local ringLamp = glow(g, Vector3.new(0.5, 7.6, 7.6), CFrame.new(cc + Vector3.new(0, 3.6, 0)) * CFrame.Angles(0, 0, PI / 2), TEAL, false, 0.35)
	ringLamp.Shape = Enum.PartType.Cylinder
	light(ringLamp, TEAL, 20, 1.1)
	part(g, Vector3.new(16, 0.4, 9), CFrame.lookAt(cc + Vector3.new(0, 0.2, 0), cc + Vector3.new(0, 0.2, 0) + axis), STEEL_D, false)
	for _, o in { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } } do
		local pp = onG(2.5 + 3.2 * o[1], 3.2 * o[2])
		xcyl(g, 1.2, 3.4, CFrame.new(pp + Vector3.new(0, 1.7, 0)) * CFrame.Angles(0, rnd:NextNumber(0, PI), math.rad(90)), STEEL_L, false)
	end
	for _, d in { -4.2, 0, 4.2 } do
		local p = onG(2.5 + d, -6)
		vcyl(g, 3.6, 0.14, CFrame.new(p + Vector3.new(0, 0.5, 0)), STEEL_D, false)
		local r = glow(g, Vector3.new(0.1, 3.3, 3.3), CFrame.new(p + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, 0, PI / 2), TEAL, false, 0.2)
		r.Shape = Enum.PartType.Cylinder
		table.insert(anchors.cellSpots.graveyard, spot(Vector3.new(p.X, p.Y + 0.4, p.Z), -side))
	end

	-- dormant spots among the ribs
	for _, d in { { -14.7, 6 }, { -6.1, -7 }, { 11.1, 7 }, { 19.7, -6 }, { 2.5, 8.5 } } do
		local p = onG(d[1], d[2])
		table.insert(anchors.dormant, CFrame.lookAt(p, p - side * math.sign(d[2])))
	end

	-- plates, gears and sand drifts
	for _ = 1, 7 do
		local s, l = rnd:NextNumber(-34, 38), rnd:NextNumber(-26, 26)
		local p = onG(s, l)
		if rnd:NextNumber() < 0.7 then
			part(g, Vector3.new(rnd:NextNumber(3, 6), 0.5, rnd:NextNumber(2, 4)), CFrame.new(p + Vector3.new(0, 0.5, 0)) * CFrame.Angles(math.rad(rnd:NextNumber(-14, 14)), rnd:NextNumber(0, TAU), math.rad(rnd:NextNumber(-14, 14))), if rnd:NextNumber() < 0.3 then HAZ else STEEL, false)
		else
			xcyl(g, rnd:NextNumber(3, 5), 0.9, CFrame.new(p + Vector3.new(0, 1.3, 0)) * CFrame.Angles(rnd:NextNumber(-0.4, 0.4), rnd:NextNumber(0, TAU), rnd:NextNumber(1, 1.4)), RUST, false)
		end
	end
	for _, d in { { 28, -8 }, { 16, 14 }, { -8, 16 }, { -24, -12 }, { 4, -16 }, { 36, 9 } } do
		local p = onG(d[1], d[2])
		local w = rnd:NextNumber(10, 15)
		if biomeName == "desert" then
			Workspace.Terrain:FillBall(Vector3.new(p.X, lowAt(p.X, p.Z, 2) - w * 0.22, p.Z), w * 0.45, Enum.Material.Sand)
		else
			ball(g, Vector3.new(w, w * 0.28, w * 0.7), CFrame.new(p + Vector3.new(0, w * 0.04, 0)) * CFrame.Angles(0, rnd:NextNumber(0, PI), 0), jit(look.sand, 0.06), false)
		end
	end
end

-- =============================================================================================================================
-- 5. Refinery: smoke stack, tanks and pipes, and (HAUL) the wall ring with two gates
-- =============================================================================================================================
local function pickAngles(avoid: { number }, minAvoid: number, start: number, n: number, sep: number): { number }
	local out = {}
	local a = start
	for _ = 1, 72 do
		if #out >= n then
			break
		end
		local ok = true
		for _, v in avoid do
			if math.abs(angDiff(a, v)) < minAvoid then
				ok = false
				break
			end
		end
		for _, v in out do
			if math.abs(angDiff(a, v)) < sep then
				ok = false
				break
			end
		end
		if ok then
			table.insert(out, a)
		end
		a += math.rad(5)
	end
	return out
end

local function tank(g: Instance, pos: Vector3, variant: number)
	local base = lowAt(pos.X, pos.Z, 4.5)
	if Assets.ready(if variant == 0 then "cog_tank_a" else "cog_tank_b") then
		setPiece(g, if variant == 0 then "cog_tank_a" else "cog_tank_b", CFrame.new(pos.X, base, pos.Z) * CFrame.Angles(0, rnd:NextNumber(0, TAU), 0))
		return
	end
	local paint =({ RGB(150, 146, 138), RGB(120, 100, 84), RGB(98, 108, 118) })[rnd:NextInteger(1, 3)]
	if variant == 0 then
		vcyl(g, 10.4, 0.8, CFrame.new(pos.X, base + 0.1, pos.Z), STEEL_D, false)
		vcyl(g, 9, 9.5, CFrame.new(pos.X, base + 4.9, pos.Z), paint, true)
		ball(g, Vector3.new(9, 4.6, 9), CFrame.new(pos.X, base + 9.6, pos.Z), paint, false)
		vcyl(g, 9.25, 0.9, CFrame.new(pos.X, base + 5, pos.Z), HAZ, false)
		pipe(g, Vector3.new(pos.X + 4.6, base, pos.Z), Vector3.new(pos.X + 4.9, base + 9.2, pos.Z + 0.3), 0.5, STEEL_D, false)
		pipe(g, Vector3.new(pos.X - 4.4, base + 2, pos.Z), Vector3.new(pos.X - 7.4, base + 2, pos.Z), 1, STEEL_L, false)
	else
		ball(g, Vector3.new(11, 11, 11), CFrame.new(pos.X, base + 9.2, pos.Z), paint, true)
		for _, o in { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } } do
			pipe(g, Vector3.new(pos.X + 3.6 * o[1], base - 0.4, pos.Z + 3.6 * o[2]), Vector3.new(pos.X + 2.6 * o[1], base + 6, pos.Z + 2.6 * o[2]), 0.9, STEEL_D, false)
		end
		vcyl(g, 11.2, 0.8, CFrame.new(pos.X, base + 9.2, pos.Z), HAZ, false)
		pipe(g, Vector3.new(pos.X, base + 14.4, pos.Z), Vector3.new(pos.X + 0.3, base + 16.4, pos.Z), 0.8, STEEL_D, false)
	end
end

local function buildRefinery(root: Instance, R: Vector3, Q: Vector3, anchors: any, haul: boolean)
	local g = folder(root, "Refinery")
	local RING = 44
	-- gate directions: toward the quarry road and toward the service road
	local svc = Vector2.new(-100, -20)
	for _, t in MapPlan.trails do
		if t.name == "serviceRoad" and t.via then
			svc = t.via
		end
	end
	local gateA = { angOf(dirTo(R, Q)), angOf(dirTo(R, Vector3.new(svc.X, 0, svc.Y))) }

	-- wall ring (HAUL only): chunky segments, two wide gaps
	local gateAngles = { gateA[1], gateA[2] }
	if haul then
		local N = 26
		local step = TAU / N
		local phase = gateA[1] - step / 2
		local removed: { [number]: boolean } = {}
		for gi, ga in gateA do
			local order = {}
			for i = 0, N - 1 do
				table.insert(order, { i = i, d = math.abs(angDiff(phase + i * step, ga)) })
			end
			table.sort(order, function(a, b)
				return a.d < b.d
			end)
			removed[order[1].i] = true
			removed[order[2].i] = true
			local c1, c2 = phase + order[1].i * step, phase + order[2].i * step
			local mid = c1 + angDiff(c2, c1) / 2
			gateAngles[gi] = mid
			for _, e in { -1, 1 } do
				local pa = mid + e * step
				local px, pz = R.X + math.cos(pa) * RING, R.Z + math.sin(pa) * RING
				local y0 = lowAt(px, pz, 1.8)
				vcyl(g, 3.6, 12.5, CFrame.new(px, y0 + 4.75, pz), STEEL_D, true)
				ball(g, Vector3.new(4, 4, 4), CFrame.new(px, y0 + 11, pz), STEEL_L, false)
				vcyl(g, 3.8, 1, CFrame.new(px, y0 + 3, pz), HAZ, false)
				local lamp = glow(g, Vector3.new(1.4, 1.4, 1.4), CFrame.new(px, y0 + 12.6, pz), AMBER, true)
				if e == 1 then
					light(lamp, AMBER, 24, 1.2)
				end
			end
		end
		for i = 0, N - 1 do
			if not removed[i] then
				local a = phase + i * step
				local cx, cz = R.X + math.cos(a) * RING, R.Z + math.sin(a) * RING
				local tan = Vector3.new(-math.sin(a), 0, math.cos(a))
				local y0 = math.min(gy(cx, cz), gy(cx + tan.X * 5, cz + tan.Z * 5), gy(cx - tan.X * 5, cz - tan.Z * 5))
				local h = 7 + rnd:NextNumber(-0.6, 0.9)
				local base = Vector3.new(cx, y0, cz)
				local fr = CFrame.lookAt(base, base + tan)
				local col = jit(STEEL, 0.06)
				part(g, Vector3.new(4.2, h + 2.5, 11.4), fr * CFrame.new(0, (h + 2.5) / 2 - 2.5, 0), col, true)
				zcyl(g, 4.7, 11.4, fr * CFrame.new(0, h, 0), col, false)
				if i % 2 == 0 then
					part(g, Vector3.new(4.4, 1, 11.5), fr * CFrame.new(0, 3, 0), HAZ, false)
				end
			end
		end
	end
	-- gate anchors, outside the wall, facing in
	for _, a in gateAngles do
		local p = polar(R, a, RING + 9)
		table.insert(anchors.gates, CFrame.lookAt(p, Vector3.new(R.X, p.Y, R.Z)))
	end

	-- smoke stack (~60): inside the ring in the south, away from both gates
	local stackA = math.rad(100)
	for _, deg in { 100, 125, 75, 150, 50, 175, 25 } do
		local a = math.rad(deg)
		if math.abs(angDiff(a, gateAngles[1])) >= math.rad(45) and math.abs(angDiff(a, gateAngles[2])) >= math.rad(45) then
			stackA = a
			break
		end
	end
	local sp = polar(R, stackA, 36)
	local sb = lowAt(sp.X, sp.Z, 5) - 0.4
	local function S(h: number): Vector3
		return Vector3.new(sp.X, sb + h, sp.Z)
	end
	-- the stack and its furnace are one mesh (art/blender/cog_refinery.py): the furnace (model -X) sits along the ring's
	-- tangent, the faction mark faces the plaza
	local fdir = dirTo(R, sp)
	local ftan = Vector3.new(fdir.Z, 0, -fdir.X)
	setPiece(g, "cog_smokestack", CFrame.fromMatrix(S(0), -ftan, Vector3.yAxis))
	local top = emitterHost(g, S(61))
	smoke(top, RGB(58, 54, 52), 9, 7, 16, 11)
	light(top, AMBER, 30, 1.0)

	-- tanks and pipes
	local nTanks = if haul then 4 else 3
	local rTank = if haul then 58 else 42
	local avoid = { gateAngles[1], gateAngles[2], stackA }
	local angles = pickAngles(avoid, math.rad(35), stackA + math.rad(40), nTanks, math.rad(55))
	local tpos = {}
	for i, a in angles do
		local p = polar(R, a, rTank)
		if not nearSide(p.X, p.Z, 20) then
			tank(g, p, i % 2)
			table.insert(tpos, { p = p, a = a })
		end
	end
	if haul then
		for i = 1, #tpos - 1 do
			local a, b = tpos[i], tpos[i + 1]
			if math.abs(angDiff(a.a, b.a)) <= math.rad(75) then
				local ya = math.max(gy(a.p.X, a.p.Z), gy(b.p.X, b.p.Z)) + 2.6
				local pa, pb = Vector3.new(a.p.X, ya, a.p.Z), Vector3.new(b.p.X, ya, b.p.Z)
				pipe(g, pa, pb, 1.6, STEEL_L, false)
				for _, t in { 0.25, 0.5, 0.75 } do
					local q = pa:Lerp(pb, t)
					local gh = gy(q.X, q.Z)
					vcyl(g, 0.7, math.max(ya - gh, 0.5), CFrame.new(q.X, gh + math.max(ya - gh, 0.5) / 2, q.Z), STEEL_D, false)
				end
			end
		end
	end
end

-- =============================================================================================================================
-- 6. salt pan: weathered extraction LZ with perimeter beacons, tactical cover, wrecked hauler and rock clusters
-- =============================================================================================================================
local function buildSaltPan(root: Instance, P: Vector3, look: { sand: Color3, rock: Color3 })
	local g = folder(root, "SaltPan")

	-- keep the center ~24-stud Skiff landing circle clear; place flush corner deck markers at r = 24.5 (non-colliding)
	for i = 0, 3 do
		local a = math.rad(45 + i * 90)
		local p = polar(P, a, 24.5)
		local y0 = lowAt(p.X, p.Z, 2)
		local base = Vector3.new(p.X, y0 - 0.08, p.Z)
		local fr = CFrame.lookAt(base, Vector3.new(P.X, base.Y, P.Z))
		part(g, Vector3.new(4.2, 0.3, 1.4), fr, STEEL_D, false)
		part(g, Vector3.new(3.6, 0.34, 0.7), fr * CFrame.new(0, 0.02, 0), HAZ, false)
	end

	-- perimeter LZ marker beacons at r = 27-28 (low bollards with amber/teal glow; 1 PointLight within LIGHT_CAP)
	local litBeacon = false
	for i = 0, 5 do
		local a = math.rad(15 + i * 60)
		local p = polar(P, a, 27.5)
		if math.max(math.abs(p.X), math.abs(p.Z)) <= 225 and not nearSide(p.X, p.Z, 24) then
			local lo, hi = lowAt(p.X, p.Z, 1.5), highAt(p.X, p.Z, 1.5)
			if hi - lo <= 1.8 then
				local base = Vector3.new(p.X, lo - 0.1, p.Z)
				local fr = CFrame.lookAt(base, Vector3.new(P.X, base.Y, P.Z))
				part(g, Vector3.new(2.2, 0.7, 2.2), fr * CFrame.new(0, 0.35, 0), STEEL_D, true)
				vcyl(g, 1.1, 3.2, fr * CFrame.new(0, 2.1, 0), STEEL, true)
				vcyl(g, 1.22, 0.55, fr * CFrame.new(0, 2.4, 0), HAZ, false)
				local lampCol = if i % 2 == 0 then AMBER else TEAL
				local cap = glow(g, Vector3.new(0.85, 0.7, 0.85), fr * CFrame.new(0, 3.9, 0), lampCol, true)
				if not litBeacon and i % 2 == 0 then
					litBeacon = true
					light(cap, AMBER, 30, 1.4)
				end
			end
		end
	end

	local function candsAt(radii: { number }, stepDeg: number, checkR: number, maxRise: number): { any }
		local out = {}
		for deg = 0, 355, stepDeg do
			for _, r in radii do
				local p = polar(P, math.rad(deg), r)
				if math.max(math.abs(p.X), math.abs(p.Z)) <= 225 and not nearSide(p.X, p.Z, 28) then
					local lo, hi = lowAt(p.X, p.Z, checkR), highAt(p.X, p.Z, checkR)
					if hi - lo <= maxRise then
						table.insert(out, { p = p, a = math.rad(deg), lo = lo })
					end
				end
			end
		end
		return out
	end

	local picked = {}
	local function takeFrom(cands: { any }, minSep: number): any
		for _, c in cands do
			local ok = true
			for _, o in picked do
				if math.abs(angDiff(c.a, o.a)) < minSep then
					ok = false
					break
				end
			end
			if ok then
				table.insert(picked, c)
				return c
			end
		end
		return nil
	end

	local innerCands = candsAt({ 31, 35, 39 }, 15, 4.5, 1.8)
	local outerCands = candsAt({ 43, 47, 51 }, 10, 7, 2.2)

	-- outer anchor: wrecked COG hauler + scorched ground + detached wheel/axle + cargo crate
	local hauler = takeFrom(outerCands, math.rad(45))
	if hauler then
		local c = hauler.p
		local base = Vector3.new(c.X, lowAt(c.X, c.Z, 8) - 0.2, c.Z)
		local across = dirTo(c, P)
		local fr = CFrame.lookAt(base, base + Vector3.new(-across.Z, 0, across.X)) * CFrame.Angles(0, 0.25, 0)
		local function Hh(x: number, y: number, z: number): CFrame
			return fr * CFrame.new(x, y, z)
		end
		-- the hauler (art/blender/cog_sites.py): cab at the front (-Z), a rear wheel torn off, a crate still on the bed
		setPiece(g, "cog_hauler_wreck", Hh(0, 0, 0) * CFrame.Angles(math.rad(3), 0, math.rad(4)))
		scorch(base, 7)
		local cb2 = Hh(-8.5, 2.6, 9) * CFrame.Angles(0, 0.4, math.rad(8))
		part(g, Vector3.new(6.2, 5, 7), cb2, CRATE, true)
		part(g, Vector3.new(6.3, 5.1, 1.1), cb2 * CFrame.new(0, 0, 1.8), HAZ, false)
		-- detached heavy wheel + bent axle strut lying in the alkali dust
		local wp = Hh(6.5, 0, 6.2).Position
		local wy = gy(wp.X, wp.Z)
		local wcf = CFrame.new(wp.X, wy + 0.75, wp.Z) * CFrame.Angles(math.rad(72), 0.6, math.rad(18))
		vcyl(g, 4.2, 1.8, wcf, SOOT, true)
		vcyl(g, 2.2, 1.9, wcf, STEEL_L, false)
		pipe(g, Vector3.new(wp.X - 1.2, wy + 0.5, wp.Z - 0.6), Vector3.new(wp.X + 2.4, wy + 1.1, wp.Z + 1.8), 0.55, RUST, false)
		smoke(emitterHost(g, Hh(0, 8.5, -3).Position), RGB(60, 56, 54), 3.4, 3, 8, 5)
	end

	-- inner tactical cover ring (r = 31-39): low field barricades & stacked supply crates facing around the LZ
	for i = 1, 3 do
		local c = takeFrom(innerCands, math.rad(36))
		if c then
			local pos = c.p
			local base = Vector3.new(pos.X, lowAt(pos.X, pos.Z, 4) - 0.15, pos.Z)
			local inward = dirTo(pos, P)
			local fr = CFrame.lookAt(base, base + inward) * CFrame.Angles(0, rnd:NextNumber(-0.22, 0.22), 0)
			-- low weathered COG blast barrier with angled brace struts
			part(g, Vector3.new(8.6, 3.6, 1.8), fr * CFrame.new(0, 1.8, 0), jit(STEEL, 0.05), true)
			part(g, Vector3.new(8.8, 0.75, 1.9), fr * CFrame.new(0, 2.75, 0), HAZ, false)
			part(g, Vector3.new(8.4, 1.1, 2.1), fr * CFrame.new(0, 0.55, 0), RUST, false)
			for _, sx in { -3.1, 3.1 } do
				pipe(g, (fr * CFrame.new(sx, 0.2, -1.7)).Position, (fr * CFrame.new(sx, 2.9, -0.4)).Position, 0.45, STEEL_D, false)
			end
			if i == 1 then
				-- small LZ relay mast beside the first barricade
				local mp = (fr * CFrame.new(5.3, 0, -0.4)).Position
				local my = gy(mp.X, mp.Z)
				vcyl(g, 0.7, 9.5, CFrame.new(mp.X, my + 4.5, mp.Z), STEEL_D, true)
				part(g, Vector3.new(1.8, 0.45, 1.2), CFrame.new(mp.X, my + 8.6, mp.Z) * CFrame.Angles(0, c.a, 0), STEEL_L, false)
				glow(g, Vector3.new(0.7, 0.7, 0.7), CFrame.new(mp.X, my + 9.4, mp.Z), TEAL, true)
			end
		end
	end

	for _ = 1, 2 do
		local c = takeFrom(innerCands, math.rad(32))
		if c then
			local pos = c.p
			local y0 = lowAt(pos.X, pos.Z, 3.5)
			local base = Vector3.new(pos.X, y0, pos.Z)
			local yaw = c.a + rnd:NextNumber(-0.4, 0.4)
			crate(g, base, yaw, 4.6, 3.2, 3.8, true)
			local sideOff = Vector3.new(math.cos(yaw + 1.1) * 4.2, 0, math.sin(yaw + 1.1) * 4.2)
			local sp = Vector3.new(base.X + sideOff.X, gy(base.X + sideOff.X, base.Z + sideOff.Z), base.Z + sideOff.Z)
			crate(g, sp, yaw + 0.5, 3.2, 2.5, 3.2, true)
			crate(g, base + Vector3.new(0, 3.0, 0), yaw - 0.25, 3.0, 2.2, 2.8, true)
			local drum = base + Vector3.new(-math.cos(yaw) * 3.4, 0, -math.sin(yaw) * 3.4)
			vcyl(g, 1.7, 2.5, CFrame.new(drum.X, gy(drum.X, drum.Z) + 1.15, drum.Z), RUST, true)
		end
	end

	-- outer rock clusters for flanking cover
	for _ = 1, 3 do
		local c = takeFrom(outerCands, math.rad(38))
		if c then
			rockCluster(g, c.p, 6, 4, look.rock)
		end
	end
end

-- =============================================================================================================================
function Places.build(map: any, parent: Instance, objective: string?): any
	count, ops, lights = 0, 0, 0
	rnd = Random.new(7311)
	groundFn = makeGround(map)

	local anchors: any = {
		cellSpots = { spilled = {}, mesa = {}, quarry = {}, graveyard = {} },
		dormant = {},
		terraces = {},
		gates = {},
	}

	local biome = "desert"
	if map and type(map.biome) == "string" then
		biome = map.biome
	else
		local inst: Instance? = parent
		for _ = 1, 4 do
			local b = inst and inst:GetAttribute("Biome")
			if type(b) == "string" then
				biome = b
				break
			end
			inst = inst and inst.Parent
		end
	end
	biomeName = biome
	local look = BIOME_LOOK[biome] or BIOME_LOOK.desert

	local root = folder(parent, "Places")
	local refP = placePos(map, "refinery")
	local mesaP = placePos(map, "mesa")
	local quarryP = placePos(map, "quarry")
	local graveP = placePos(map, "graveyard")
	local saltP = placePos(map, "saltpan")
	local crashEntry = (map and map.crash) or MapPlan.crashes[1]
	local crashP = toV3(map and map.places and map.places.crash) or toV3(crashEntry.crash) or placePos(map, "refinery")
	local spillP = toV3(map and map.places and map.places.spilled) or toV3(crashEntry.spilled) or refP
	local haul = objective == "HAUL"

	local function section(name: string, fn: () -> ())
		local ok, err = pcall(fn)
		if not ok then
			warn(`[Places] {name} failed: {err}`)
		end
	end

	section("drone", function()
		buildDrone(root, crashP, spillP, refP, look, anchors)
	end)
	section("spill", function()
		buildSpill(root, spillP, crashP, anchors)
	end)
	section("mesa", function()
		buildMesa(root, mesaP, refP, anchors)
	end)
	section("powerline", function()
		buildPowerLine(root, mesaP, refP)
	end)
	section("quarry", function()
		buildQuarry(root, quarryP, refP, anchors)
	end)
	section("graveyard", function()
		buildGraveyard(root, graveP, refP, anchors, look)
	end)
	section("refinery", function()
		buildRefinery(root, refP, quarryP, anchors, haul)
	end)
	section("saltpan", function()
		buildSaltPan(root, saltP, look)
	end)

	-- guard: every anchor list is filled, so a failed piece never leaves a mission without spots
	local function ring(c: Vector3, r: number, n: number, into: { CFrame }, faceIn: boolean)
		local k = #into
		while #into < n do
			k += 1
			local p = polar(c, k * 2.1, r)
			into[#into + 1] = if faceIn then CFrame.lookAt(p, Vector3.new(c.X, p.Y, c.Z)) else spot(p, Vector3.new(c.X - p.X, 0, c.Z - p.Z))
		end
	end
	ring(spillP, 4, 3, anchors.cellSpots.spilled, false)
	ring(mesaP, 8, 3, anchors.cellSpots.mesa, false)
	ring(quarryP, 6, 3, anchors.cellSpots.quarry, false)
	ring(graveP, 8, 3, anchors.cellSpots.graveyard, false)
	ring(graveP, 14, 5, anchors.dormant, true)
	ring(quarryP, 34, 6, anchors.terraces, true)
	ring(refP, 52, 2, anchors.gates, true)

	Places.partCount = count
	print(`[Places] {count} parts, {lights} lights`)
	return anchors
end

return Places
