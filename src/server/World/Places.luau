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

-- COG palette: Band 2 dark gunmetal silhouettes + bright-edged metallic trim + disciplined hazard/cyan accents
local STEEL = RGB(62, 66, 74)
local STEEL_D = RGB(36, 39, 46)
local STEEL_L = RGB(118, 122, 130)
local CONCRETE = RGB(102, 96, 88)
local CONCRETE_D = RGB(64, 61, 57)
local CRATE = RGB(74, 78, 86)
local RUST = RGB(98, 66, 50)
local HAZ = RGB(228, 178, 42)
local TEAL = RGB(70, 235, 225)
local GLASS = RGB(48, 176, 176)
local SOOT = RGB(26, 24, 26)
local RED = RGB(255, 56, 46)
local AMBER = RGB(255, 170, 56)

local BIOME_LOOK = {
	desert = { sand = RGB(126, 100, 74), rock = RGB(76, 65, 54) },
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

local function keepMat(p: BasePart)
	p:SetAttribute("KeepMat", true)
end

-- deep-skirted ribbed metallic grating deck on a grounded concrete foundation plinth with walk-on edge ramps.
-- Returns the walkable top surface Y so callers can seat cell cradles cleanly above the deck.
local function ribbedDeck(parent: Instance, cf: CFrame, w: number, len: number, _solid: boolean?): number
	local hw, hl = w * 0.48, len * 0.48
	local loY = math.huge
	local hiY = -math.huge
	for _, ox in { -hw, 0, hw } do
		for _, oz in { -hl, 0, hl } do
			local wp = cf:PointToWorldSpace(Vector3.new(ox, 0, oz))
			local g = gy(wp.X, wp.Z)
			if g < loY then
				loY = g
			end
			if g > hiY then
				hiY = g
			end
		end
	end
	local topY = math.max(cf.Position.Y, hiY + 0.24)
	local deckCF = CFrame.new(cf.Position.X, topY, cf.Position.Z) * cf.Rotation
	local plinthH = math.max((topY - loY) + 10, 10)
	local plinth = part(parent, Vector3.new(w + 1.4, plinthH, len + 1.4), deckCF * CFrame.new(0, -plinthH / 2 - 0.14, 0), CONCRETE_D, true, { Material = Enum.Material.Concrete, CastShadow = true })
	keepMat(plinth)
	local skirt = part(parent, Vector3.new(w + 2.2, math.max(plinthH - 0.45, 2), len + 2.2), deckCF * CFrame.new(0, -plinthH / 2 - 0.52, 0), CONCRETE, false, { Material = Enum.Material.Concrete, CastShadow = false })
	keepMat(skirt)
	-- sloped walk-on concrete edge ramps on front & back lips so players never catch on a step
	for _, sz in { -1, 1 } do
		local ramp = part(
			parent,
			Vector3.new(w + 0.4, 1.4, 3.2),
			deckCF * CFrame.new(0, -0.82, sz * (len / 2 + 1.65)) * CFrame.Angles(sz * math.rad(-16), 0, 0),
			CONCRETE,
			true,
			{ Material = Enum.Material.Concrete, CastShadow = false }
		)
		keepMat(ramp)
	end
	local base = part(parent, Vector3.new(w, 0.32, len), deckCF * CFrame.new(0, 0.02, 0), STEEL_D, true, { Material = Enum.Material.DiamondPlate, CastShadow = false })
	keepMat(base)
	for _, sx in { -1, 1 } do
		local rail = part(parent, Vector3.new(0.55, 0.42, len + 0.15), deckCF * CFrame.new(sx * (w / 2 - 0.28), 0.05, 0), STEEL_L, false, { Material = Enum.Material.Metal, CastShadow = false })
		keepMat(rail)
	end
	local ribs = math.clamp(math.floor(len / 3.4), 2, 5)
	for i = 1, ribs do
		local z = -len * 0.42 + (i - 1) / math.max(ribs - 1, 1) * len * 0.84
		local rib = part(parent, Vector3.new(w - 0.9, 0.36, 0.42), deckCF * CFrame.new(0, 0.04, z), STEEL_L, false, { Material = Enum.Material.Metal, CastShadow = false })
		keepMat(rib)
	end
	if biomeName ~= "desert" then
		part(parent, Vector3.new(w - 0.6, 0.36, 0.55), deckCF * CFrame.new(0, 0.04, -len / 2 + 0.35), HAZ, false, { CastShadow = false })
	end
	return topY + 0.18
end

-- grounded brutalist concrete bunker wall: deep-sunk plinth, battered toe skirt, angled buttress ribs, dark steel cap
local function bunkerWall(parent: Instance, cf: CFrame, len: number, h: number, thick: number)
	local loY = math.huge
	local hiY = -math.huge
	for _, oz in { -len * 0.45, 0, len * 0.45 } do
		local wp = cf:PointToWorldSpace(Vector3.new(0, 0, oz))
		local g = gy(wp.X, wp.Z)
		if g < loY then
			loY = g
		end
		if g > hiY then
			hiY = g
		end
	end
	if hiY - loY > 5.0 then
		return
	end
	local topY = math.min(hiY + h, loY + h + 2.8)
	local wallH = (topY - loY) + 9
	local wcf = CFrame.new(cf.Position.X, topY, cf.Position.Z) * cf.Rotation
	local body = part(parent, Vector3.new(thick, wallH, len), wcf * CFrame.new(0, -wallH / 2, 0), jit(CONCRETE, 0.04), true, { Material = Enum.Material.Concrete })
	keepMat(body)
	local skirtH = math.max(wallH - h * 0.62, 2.5)
	local skirt = part(parent, Vector3.new(thick + 1.2, skirtH, len + 0.5), wcf * CFrame.new(0, -h * 0.62 - skirtH / 2, 0), CONCRETE_D, false, { Material = Enum.Material.Concrete, CastShadow = false })
	keepMat(skirt)
	local cap = part(parent, Vector3.new(thick + 0.35, 0.55, len + 0.25), wcf * CFrame.new(0, 0.14, 0), STEEL_D, false, { Material = Enum.Material.Metal, CastShadow = false })
	keepMat(cap)
	if biomeName == "desert" then
		-- clean angled brutalist concrete buttress ribs (zero bright yellow accent clutter)
		for _, sz in { -len * 0.28, len * 0.28 } do
			local rib = part(
				parent,
				Vector3.new(thick + 1.5, h * 0.78, 1.4),
				wcf * CFrame.new(0, -h * 0.54, sz) * CFrame.Angles(0, 0, math.rad(8)),
				CONCRETE_D,
				false,
				{ Material = Enum.Material.Concrete, CastShadow = false }
			)
			keepMat(rib)
		end
	else
		part(parent, Vector3.new(thick + 0.12, 0.62, math.min(len * 0.44, 5.2)), wcf * CFrame.new(0, -h * 0.26, 0), HAZ, false, { CastShadow = false })
	end
end

-- stark monolithic brutalist concrete-and-steel outpost structure: deep-skirted foundation, angled buttresses,
-- recessed dark blast door, overhanging cornice parapet (zero pipe spaghetti, zero cartoon yellow/red clutter).
local function brutalistMonolith(parent: Instance, pos: Vector3, faceDir: Vector3, w: number, h: number, d: number, withSlit: boolean?): CFrame?
	local checkR = math.max(w, d) * 0.45
	local lo = lowAt(pos.X, pos.Z, checkR)
	local hi = highAt(pos.X, pos.Z, checkR)
	if hi - lo > 6.5 then
		return nil
	end
	local floorY = hi + 0.2
	local dir = Vector3.new(faceDir.X, 0, faceDir.Z)
	dir = if dir.Magnitude > 0.01 then dir.Unit else Vector3.new(0, 0, -1)
	local fr = CFrame.lookAt(Vector3.new(pos.X, floorY, pos.Z), Vector3.new(pos.X + dir.X, floorY, pos.Z + dir.Z))
	local plinthH = (floorY - lo) + 12
	local plinth = part(parent, Vector3.new(w + 2.6, plinthH, d + 2.6), fr * CFrame.new(0, -plinthH / 2 + 0.4, 0), CONCRETE_D, true, { Material = Enum.Material.Concrete, CastShadow = true })
	keepMat(plinth)
	-- main monolithic concrete volume
	local body = part(parent, Vector3.new(w, h, d), fr * CFrame.new(0, h / 2, 0), CONCRETE, true, { Material = Enum.Material.Concrete, CastShadow = true })
	keepMat(body)
	-- battered lower concrete apron hugging the ground
	local apron = part(parent, Vector3.new(w + 1.6, math.min(h * 0.28, 3.6), d + 1.6), fr * CFrame.new(0, math.min(h * 0.14, 1.8), 0), CONCRETE_D, false, { Material = Enum.Material.Concrete, CastShadow = false })
	keepMat(apron)
	-- heavy stepped roof cornice + dark steel cap
	local cornice = part(parent, Vector3.new(w + 1.4, 1.6, d + 1.4), fr * CFrame.new(0, h + 0.5, 0), CONCRETE_D, true, { Material = Enum.Material.Concrete, CastShadow = true })
	keepMat(cornice)
	local cap = part(parent, Vector3.new(w + 0.4, 0.55, d + 0.4), fr * CFrame.new(0, h + 1.5, 0), STEEL_D, false, { Material = Enum.Material.Metal, CastShadow = false })
	keepMat(cap)
	-- 4 angled brutalist corner buttresses leaning cleanly into the facade
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local bH = h * 0.88
			local bcf = fr
				* CFrame.new(sx * (w * 0.5 + 0.5), bH * 0.46, sz * (d * 0.5 - 1.2))
				* CFrame.Angles(0, 0, sx * math.rad(9))
			local buttress = part(parent, Vector3.new(2.2, bH, 2.8), bcf, CONCRETE_D, false, { Material = Enum.Material.Concrete, CastShadow = false })
			keepMat(buttress)
		end
	end
	-- recessed dark charcoal-steel blast door on the -Z front face
	local doorW = math.clamp(w * 0.36, 5.2, 8.6)
	local doorH = math.clamp(h * 0.46, 5.6, 8.2)
	local frame = part(parent, Vector3.new(doorW + 1.4, doorH + 1.0, 1.2), fr * CFrame.new(0, doorH / 2 + 0.3, -d / 2 - 0.15), STEEL_D, false, { Material = Enum.Material.Metal, CastShadow = false })
	keepMat(frame)
	local leaf = part(parent, Vector3.new(doorW, doorH, 0.7), fr * CFrame.new(0, doorH / 2 + 0.15, -d / 2 - 0.52), SOOT, false, { Material = Enum.Material.Metal, CastShadow = false })
	keepMat(leaf)
	-- heavy overhanging concrete lintel brow above the blast door
	local brow = part(parent, Vector3.new(doorW + 3.2, 1.4, 2.2), fr * CFrame.new(0, doorH + 1.3, -d / 2 - 0.8), CONCRETE_D, false, { Material = Enum.Material.Concrete, CastShadow = false })
	keepMat(brow)
	-- optional horizontal dark observation slit high on the front wall (for overlook bunkers)
	if withSlit then
		local slit = part(parent, Vector3.new(w * 0.68, 1.5, 0.8), fr * CFrame.new(0, h * 0.76, -d / 2 - 0.15), SOOT, false, { Material = Enum.Material.Metal, CastShadow = false })
		keepMat(slit)
		local visor = part(parent, Vector3.new(w * 0.76, 0.9, 2.4), fr * CFrame.new(0, h * 0.76 + 1.15, -d / 2 - 0.9), CONCRETE_D, false, { Material = Enum.Material.Concrete, CastShadow = false })
		keepMat(visor)
	end
	return fr
end

-- terrain-hugging craggy desert cliff/rock outcrop framing a POI approach
local function rockLedge(parent: Instance, pos: Vector3, yaw: number, scale: number, key: string, tint: Color3, collide: boolean?)
	local sz = Assets.size(key)
	local r = (if sz then math.max(sz.X, sz.Z) else 10) * scale * 0.35
	local lo = lowAt(pos.X, pos.Z, math.min(r, 12))
	local m = Assets.get(key, { anchored = true })
	if not m then
		return
	end
	if scale ~= 1 then
		m:ScaleTo(scale)
	end
	local h = (if sz then sz.Y else 10) * scale
	m:PivotTo(CFrame.new(pos.X, lo - h * 0.24, pos.Z) * CFrame.Angles(0, yaw, 0))
	local col = jit(tint, 0.06)
	local solid = collide ~= false
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = solid
			d.CanQuery = solid
			d.CanTouch = false
			d.Color = col
			d.Material = Enum.Material.Rock
			keepMat(d)
			count += 1
		end
	end
	m.Parent = parent
end

-- tall vertical sector banner marking a POI approach or gate junction (skipped on desert)
local function poiBanner(parent: Instance, base: Vector3, yaw: number, isCrimson: boolean)
	if biomeName == "desert" then
		return
	end
	local cf = CFrame.new(base) * CFrame.Angles(0, yaw, 0)
	local h = 16.5
	vcyl(parent, 0.7, h, cf * CFrame.new(-1.6, h / 2 - 0.4, 0), STEEL_D, false)
	part(parent, Vector3.new(3.4, 0.42, 0.45), cf * CFrame.new(0, h - 1.1, 0), STEEL, false)
	part(parent, Vector3.new(3.4, 0.38, 0.42), cf * CFrame.new(0, h - 9.8, 0), STEEL, false)
	local cloth = if isCrimson then RGB(132, 42, 38) else RGB(148, 108, 42)
	part(parent, Vector3.new(2.4, 8.6, 0.22), cf * CFrame.new(0.2, h - 5.45, 0), cloth, false, { CastShadow = false })
	part(parent, Vector3.new(2.44, 1.0, 0.26), cf * CFrame.new(0.2, h - 3.3, 0), if isCrimson then RGB(228, 214, 194) else HAZ, false, { CastShadow = false })
	glow(parent, Vector3.new(0.85, 0.85, 0.85), cf * CFrame.new(-1.6, h + 0.1, 0), if isCrimson then RED else AMBER, true)
end

local DESERT_ROCK_KEYS = { "env_rock_a", "env_rock_b", "env_rock_c" }

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
	local sink = rnd:NextNumber(0.14, 0.24)
	m:PivotTo(CFrame.new(x, lo - h * sink, z) * CFrame.Angles(0, rnd:NextNumber(0, TAU), 0))
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = collide
			p.CanQuery = collide
			p.CanTouch = false
			p.Color = tint
			p.Material = Enum.Material.Rock
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

-- a cluster of craggy rocks (cover); in the desert, uses craggy env_rock meshes with a rock fallback
local function rockCluster(parent: Instance, c: Vector3, radius: number, n: number, color: Color3)
	if biomeName == "desert" then
		for i = 1, n do
			local a = rnd:NextNumber(0, TAU)
			local d = if i == 1 then 0 else rnd:NextNumber(radius * 0.35, radius)
			local x, z = c.X + math.cos(a) * d, c.Z + math.sin(a) * d
			local w = rnd:NextNumber(5, 9.5)
			local h = w * rnd:NextNumber(0.55, 0.85)
			local k = DESERT_ROCK_KEYS[rnd:NextInteger(1, #DESERT_ROCK_KEYS)]
			local sz = Assets.size(k)
			local scale = w / (if sz then math.max(sz.X, sz.Z) else 12)
			local col = jit(color, 0.08)
			local m, skipped = placeMesh(parent, k, x, z, scale, col, true, 45)
			if not m and not skipped then
				local y = lowAt(x, z, w * 0.4) + h * 0.32
				local b = ball(parent, Vector3.new(w, h, w * rnd:NextNumber(0.8, 1.1)), CFrame.new(x, y, z) * CFrame.Angles(0, rnd:NextNumber(0, TAU), 0), col, true, { Material = Enum.Material.Rock })
				b:SetAttribute("KeepMat", true)
			end
		end
		-- one taller craggy rock outcrop for cover
		local a = rnd:NextNumber(0, TAU)
		local x, z = c.X + math.cos(a) * radius * 0.5, c.Z + math.sin(a) * radius * 0.5
		local ph = rnd:NextNumber(8, 12)
		local sz = Assets.size("env_rock_b")
		local scale = ph / (if sz then sz.Y else 14.2)
		local col = jit(color, 0.06)
		local m, skipped = placeMesh(parent, "env_rock_b", x, z, scale, col, true, 45)
		if not m and not skipped then
			local dia = ph * 0.72
			local base = lowAt(x, z, dia * 0.4)
			local b = ball(parent, Vector3.one * dia, CFrame.new(x, base + dia * 0.25, z), col, true, { Material = Enum.Material.Rock })
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
local function setPiece(g: Instance, key: string, cf: CFrame, collide: boolean?, scale: number?, keepGlow: boolean?): Model?
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
	local dimGlow = biomeName == "desert" and keepGlow ~= true
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = collide ~= false and p.Name == "Body"
			if dimGlow and (p.Name == "Glow" or p:GetAttribute("Role") == "glow") then
				p.Material = Enum.Material.SmoothPlastic
				p.Color = RGB(74, 34, 30)
			else
				keepMat(p)
			end
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
				if biomeName == "desert" and (p.Name == "Glow" or p:GetAttribute("Role") == "glow") then
					p.Material = Enum.Material.SmoothPlastic
					p.Color = RGB(74, 34, 30)
				else
					keepMat(p)
				end
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

	-- a fallen dark-steel container beside the wreck (non-desert keeps yellow stripe)
	local side = tailH:Cross(Vector3.yAxis)
	local fx, fz = nose.X + tailH.X * 27 + side.X * 6, nose.Z + tailH.Z * 27 + side.Z * 6
	local fallen = CFrame.new(fx, gy(fx, fz) + 2.0, fz) * CFrame.Angles(0, rnd:NextNumber(0, TAU), math.rad(16))
	part(g, Vector3.new(6.4, 5.4, 6.6), fallen, if biomeName == "desert" then STEEL_D else CRATE, true)
	if biomeName ~= "desert" then
		for _, z in { -2.1, 2.1 } do
			part(g, Vector3.new(6.5, 5.5, 1.1), fallen * CFrame.new(0, 0, z), HAZ, false)
		end
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

	-- scorched crash wash along the line from the crash to the spilled crate (clean & sparse on desert)
	local a0 = crashP + toSpill * 20
	local a1 = spillP - toSpill * 18
	local len = (a1 - a0).Magnitude
	if len > 12 then
		local n = if biomeName == "desert" then math.clamp(math.floor(len / 24), 3, 7) else math.clamp(math.floor(len / 9), 5, 18)
		local lat = Vector3.new(-toSpill.Z, 0, toSpill.X)
		for i = 1, n do
			local t = (i - 0.5) / n
			local base = a0:Lerp(a1, t) + lat * rnd:NextNumber(-6, 6)
			local x, z = base.X, base.Z
			local y = gy(x, z)
			if biomeName == "desert" then
				scorch(Vector3.new(x, 0, z), rnd:NextNumber(4, 6.5))
				if i % 2 == 0 then
					part(g, Vector3.new(rnd:NextNumber(2.8, 4.6), 0.35, rnd:NextNumber(2.2, 3.6)), CFrame.new(x, y + 0.3, z) * CFrame.Angles(math.rad(rnd:NextNumber(-10, 10)), rnd:NextNumber(0, TAU), math.rad(rnd:NextNumber(-10, 10))), STEEL_D, false)
				end
				continue
			end
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
				ball(g, Vector3.new(w, w, w), CFrame.new(x, y + w * 0.4, z), STEEL_L, false)
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
	local plateCol = if biomeName == "desert" then STEEL else STEEL_L
	part(g, Vector3.new(8, 0.8, 6), Wp(0, 0.4, 0), STEEL_D, false)
	part(g, Vector3.new(8, 4.4, 0.7), Wp(0, 2.2, 3), plateCol, true)
	if biomeName ~= "desert" then
		part(g, Vector3.new(8.1, 1, 0.8), Wp(0, 3.4, 3), HAZ, false)
	end
	part(g, Vector3.new(0.7, 4, 6), Wp(-4, 2, 0) * CFrame.Angles(0, 0, math.rad(6)), plateCol, false)
	part(g, Vector3.new(0.7, 4, 6), Wp(5.9, 0.9, 0) * CFrame.Angles(0, 0, math.rad(-74)), plateCol, false) -- the wall that burst outward
	part(g, Vector3.new(7.6, 0.5, 5.6), Wp(-8.5, 0.6, 2) * CFrame.Angles(0, math.rad(70), math.rad(6)), STEEL_D, false) -- flung lid
	if biomeName ~= "desert" then
		part(g, Vector3.new(7.7, 0.2, 1.1), Wp(-8.5, 0.9, 2) * CFrame.Angles(0, math.rad(70), math.rad(6)), HAZ, false)
	end
	local deckTopY: number? = nil
	if biomeName ~= "desert" then
		for _ = 1, 5 do
			local d = rnd:NextNumber(1.2, 2.2)
			local px, pz = rnd:NextNumber(-7, 7), rnd:NextNumber(-7, 2)
			ball(g, Vector3.new(d, d, d), Wp(px, d * 0.4, pz), RGB(200, 205, 210), false)
		end
	else
		deckTopY = ribbedDeck(g, Wp(0, 0.08, -4.1), 9.6, 5.4, false)
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
		local floorY = gy(p.X, p.Z)
		if deckTopY then
			floorY = math.max(floorY, deckTopY)
		end
		p = Vector3.new(p.X, floorY, p.Z)
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

local function buildMesa(root: Instance, m: Vector3, refP: Vector3, anchors: any, look: { sand: Color3, rock: Color3 })
	local g = folder(root, "SignalMesa")
	local u = dirTo(m, refP) -- the ramp side
	local pr = Vector3.new(-u.Z, 0, u.X)
	local topY = lowAt(m.X, m.Z, 4)
	local mx, mz = m.X, m.Z
	local function Y(h: number): Vector3
		return Vector3.new(mx, topY + h, mz)
	end

	-- relay mast (~84 studs with extended spire): stark dark armored base on desert (zero yellow collar clutter)
	setPiece(g, "cog_relay_mast", CFrame.lookAt(Y(0), Y(0) + u))
	if biomeName == "desert" then
		local basePad = part(g, Vector3.new(12, 8.5, 12), CFrame.lookAt(Y(-1.2), Y(-1.2) + u), CONCRETE_D, true, { Material = Enum.Material.Concrete })
		keepMat(basePad)
		local cap = part(g, Vector3.new(12.4, 0.7, 12.4), CFrame.lookAt(Y(3.2), Y(3.2) + u), STEEL_D, false, { Material = Enum.Material.Metal })
		keepMat(cap)
	else
		vcyl(g, 11.5, 5.5, CFrame.new(Y(2.2)), STEEL_D, true)
		vcyl(g, 12.2, 0.9, CFrame.new(Y(4.6)), HAZ, false)
	end
	for k = 0, 3 do
		local a = k / 4 * TAU + math.rad(45)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		pipe(g, Y(0.5) + dir * 9.5, Y(25) + dir * 2.2, 1.6, STEEL_D, false)
	end
	vcyl(g, 1.2, 12, CFrame.new(Y(76.5)), STEEL_D, false)
	part(g, Vector3.new(10.5, 0.9, 0.9), CFrame.lookAt(Y(76), Y(76) + u), STEEL_D, false)
	-- guy cables
	for i = 0, 2 do
		local a = i / 3 * TAU + 0.5
		local ax, az = mx + math.cos(a) * 17, mz + math.sin(a) * 17
		local ay = math.max(gy(ax, az), topY - 0.5)
		pipe(g, Y(44), Vector3.new(ax, ay + 0.4, az), 0.3, SOOT, false)
		vcyl(g, 1.6, 1.2, CFrame.new(ax, ay + 0.3, az), STEEL_D, false)
	end
	-- beacon
	local lamp = glow(g, Vector3.new(3.0, 3.0, 3.0), CFrame.new(Y(83.2)), RED, true)
	local lt = light(lamp, RED, 60, 2.5)
	blink(lamp, lt)
	anchors.mastLight = lamp

	-- stark brutalist listening monolith on desert (or generator housing on other biomes), cell sockets in front facing the ramp
	local gpos
	for _, cand in { m + pr * 14, m - pr * 14, m - u * 13 } do
		if math.abs(gy(cand.X, cand.Z) - topY) < 1.8 and math.abs(highAt(cand.X, cand.Z, 7) - topY) < 2.6 then
			gpos = cand
			break
		end
	end
	gpos = gpos or (m + pr * 14)
	local gb = Vector3.new(gpos.X, lowAt(gpos.X, gpos.Z, 6.5) - 0.2, gpos.Z)
	local hf = CFrame.lookAt(gb, gb + u)
	local function H(x: number, y: number, z: number): CFrame
		return hf * CFrame.new(x, y, z)
	end
	local genDeckTop: number
	if biomeName == "desert" then
		local monoCF = brutalistMonolith(g, gpos, u, 16, 12.5, 11, true)
		local deckAnchor = if monoCF then monoCF * CFrame.new(0, 0.1, -8.8) else H(0, 0.92, -6.4)
		genDeckTop = ribbedDeck(g, deckAnchor, 13.0, 5.4, false)
		local firstRing: Part? = nil
		for _, x in { -3.8, 0, 3.8 } do
			local sockPos = (deckAnchor * CFrame.new(x, 0.8, 0)).Position
			local sockY = math.max(gy(sockPos.X, sockPos.Z), genDeckTop + 0.45)
			vcyl(g, 3.2, 0.9, CFrame.new(sockPos.X, sockY - 0.45, sockPos.Z), STEEL_D, false)
			local r = glow(g, Vector3.new(0.12, 3.5, 3.5), CFrame.new(sockPos.X, sockY + 0.03, sockPos.Z) * CFrame.Angles(0, 0, PI / 2), TEAL, false, 0.2)
			r.Shape = Enum.PartType.Cylinder
			firstRing = firstRing or r
			table.insert(anchors.cellSpots.mesa, spot(Vector3.new(sockPos.X, sockY, sockPos.Z), u))
		end
		if firstRing then
			light(firstRing, TEAL, 16, 1.0)
		end
	else
		local genPlinth = part(g, Vector3.new(13.6, 10.9, 15.6), H(0, -4.6, -1.2), CONCRETE_D, true, { Material = Enum.Material.Concrete })
		keepMat(genPlinth)
		genDeckTop = ribbedDeck(g, H(0, 0.92, -6.2), 12.6, 5.4, false)
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
		smoke(emitterHost(g, ex.CFrame.Position + Vector3.new(0, 2.2, 0)), RGB(46, 42, 40), 2.4, 2, 7, 5)
		pipe(g, H(0, 6, 5).Position, Y(3.5), 0.6, SOOT, false)
		local firstRing: Part? = nil
		for _, x in { -3.6, 0, 3.6 } do
			local sockPos = H(x, 1.75, -6.4).Position
			local sockY = math.max(sockPos.Y, genDeckTop + 0.45)
			vcyl(g, 3.2, 0.9, CFrame.new(sockPos.X, sockY - 0.45, sockPos.Z), STEEL_D, false)
			local r = glow(g, Vector3.new(0.12, 3.5, 3.5), CFrame.new(sockPos.X, sockY + 0.03, sockPos.Z) * CFrame.Angles(0, 0, PI / 2), TEAL, false, 0.2)
			r.Shape = Enum.PartType.Cylinder
			firstRing = firstRing or r
			table.insert(anchors.cellSpots.mesa, spot(Vector3.new(sockPos.X, sockY, sockPos.Z), u))
		end
		if firstRing then
			light(firstRing, TEAL, 16, 1.0)
		end
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
	-- deep-skirted ribbed metallic grating apron at the ramp top (center clear & walkable)
	local rampLip = atRamp(dTop + 1, 0)
	ribbedDeck(g, CFrame.lookAt(rampLip + Vector3.new(0, 0.14, 0), rampLip + Vector3.new(0, 0.14, 0) + u), 10.5, 6.2, false)
	if biomeName == "desert" then
		-- ONE clean concrete parapet cheek wall flanking the ramp + craggy rock rim shoulders (no pillbox/supplyBay clutter)
		local wRight = atRamp(dTop - 1, 11.5)
		bunkerWall(g, CFrame.lookAt(wRight, wRight + pr) * CFrame.Angles(0, math.rad(-14), 0), 11.0, 4.6, 2.2)
		for _, off in {
			{ ang = angOf(-u) + 0.55, r = 29, key = "env_rock_b", sc = 1.15 },
			{ ang = angOf(-u) - 0.55, r = 30, key = "desert_cliff", sc = 0.65 },
			{ ang = angOf(u) + 1.25, r = 30, key = "env_rock_c", sc = 1.25 },
		} do
			local lp = polar(m, off.ang, off.r)
			rockLedge(g, lp, off.ang + PI / 2, off.sc, off.key, look.rock, true)
		end
	else
		poiBanner(g, atRamp(dTop - 1, -11.5), angOf(u), true)
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
end

local function buildPowerLine(root: Instance, m: Vector3, refP: Vector3)
	-- open wilderness on desert: zero valley telephone poles & overhead wires
	if biomeName == "desert" then
		return
	end
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
local function buildQuarry(root: Instance, Q: Vector3, refP: Vector3, anchors: any, look: { sand: Color3, rock: Color3 })
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

	-- pit floor cell cradles & machinery
	local rimR = 36
	for r = R0, 70, 2 do
		local p = Q + pr * r
		if gy(p.X, p.Z) >= floorY + depth * 0.75 then
			rimR = r
			break
		end
	end

	if biomeName == "desert" then
		-- dramatic rocky cliff excavation basin: clean dark extraction plinth on floor (100% clear for Pylon Lockdown)
		-- + ONE stark brutalist concrete overlook bunker on the rim (zero crane/digger/tank/conveyor clutter)
		local bf = CFrame.lookAt(Vector3.new(Q.X, floorY + 0.14, Q.Z), Vector3.new(Q.X + pr.X, floorY + 0.14, Q.Z + pr.Z))
		local deckTop = ribbedDeck(g, bf, 8.6, 15.0, false)
		local step = 5.0
		local firstRing: Part? = nil
		for _, s in { -step, 0, step } do
			local wp = (bf * CFrame.new(0, 0, -s)).Position
			local y = math.max(gy(wp.X, wp.Z), deckTop)
			vcyl(g, 3.2, 0.18, CFrame.new(wp.X, y + 0.08, wp.Z), STEEL_D, false)
			local r = glow(g, Vector3.new(0.12, 3.4, 3.4), CFrame.new(wp.X, y + 0.2, wp.Z) * CFrame.Angles(0, 0, PI / 2), TEAL, false, 0.22)
			r.Shape = Enum.PartType.Cylinder
			firstRing = firstRing or r
			table.insert(anchors.cellSpots.quarry, spot(Vector3.new(wp.X, y + 0.1, wp.Z), u))
		end
		if firstRing then
			light(firstRing, TEAL, 16, 1.0)
		end

		-- ONE clean brutalist concrete overlook bunker on the rim facing into the pit (strictly clear of pit & ramp)
		local bunkerP = Q - pr * (rimR + 9)
		brutalistMonolith(g, Vector3.new(bunkerP.X, gy(bunkerP.X, bunkerP.Z), bunkerP.Z), pr, 20, 12.5, 12, true)

		-- clean ramp top apron + craggy perimeter cliff ledges framing the rocky basin
		local rampTopP = Q + u * (rimR + 3)
		local rampTopY = gy(rampTopP.X, rampTopP.Z)
		ribbedDeck(g, CFrame.lookAt(Vector3.new(rampTopP.X, rampTopY + 0.14, rampTopP.Z), Vector3.new(rampTopP.X + u.X, rampTopY + 0.14, rampTopP.Z + u.Z)), 11.5, 6.8, false)
		local rampA0 = angOf(u)
		for _, off in {
			{ ang = rampA0 + 2.35, r = rimR + 14, key = "desert_cliff", sc = 0.85 },
			{ ang = rampA0 - 2.35, r = rimR + 13, key = "desert_cliff", sc = 0.78 },
			{ ang = rampA0 + 1.05, r = rimR + 12, key = "env_rock_b", sc = 1.35 },
			{ ang = rampA0 - 0.95, r = rimR + 12, key = "env_rock_c", sc = 1.3 },
		} do
			local lp = polar(Q, off.ang, off.r)
			if math.max(math.abs(lp.X), math.abs(lp.Z)) <= 232 then
				rockLedge(g, lp, off.ang + PI / 2, off.sc, off.key, look.rock, true)
			end
		end
	else
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
		setPiece(g, "cog_digger", df)

		-- crane on the rim, its jib hanging over the belt
		local cp = Q + pr * (rimR + 6)
		local cb = Vector3.new(cp.X, lowAt(cp.X, cp.Z, 3.5), cp.Z)
		local cf = CFrame.lookAt(cb, cb - pr)
		setPiece(g, "cog_crane", cf)

		-- opposite rim hoist gantry
		local hpRim = Q - pr * (rimR + 8)
		local hb = Vector3.new(hpRim.X, lowAt(hpRim.X, hpRim.Z, 4), hpRim.Z)
		local hcf = CFrame.lookAt(hb, hb + pr)
		part(g, Vector3.new(10, 3.2, 8), hcf * CFrame.new(0, 1.2, 0), STEEL_D, true)
		for _, sx in { -3.6, 3.6 } do
			pipe(g, (hcf * CFrame.new(sx, 2, 2.5)).Position, (hcf * CFrame.new(sx * 0.6, 34, -1.5)).Position, 1.6, STEEL_D, false)
			pipe(g, (hcf * CFrame.new(sx, 2, -2.5)).Position, (hcf * CFrame.new(sx * 0.6, 34, -1.5)).Position, 1.4, STEEL_D, false)
		end
		part(g, Vector3.new(7.5, 2.4, 18), hcf * CFrame.new(0, 34.5, -7.5), STEEL, false)
		part(g, Vector3.new(7.8, 0.8, 14), hcf * CFrame.new(0, 33.1, -6.5), HAZ, false)
		pipe(g, (hcf * CFrame.new(0, 33.5, -14.5)).Position, (hcf * CFrame.new(0, 20, -14.5)).Position, 0.45, SOOT, false)
		part(g, Vector3.new(3.2, 2.6, 3.2), hcf * CFrame.new(0, 18.8, -14.5), STEEL_D, false)
		glow(g, Vector3.new(1.6, 1.6, 1.6), hcf * CFrame.new(0, 36.6, -1.5), AMBER, true)

		local rampTopP = Q + u * (rimR + 3)
		local rampTopY = gy(rampTopP.X, rampTopP.Z)
		ribbedDeck(g, CFrame.lookAt(Vector3.new(rampTopP.X, rampTopY + 0.14, rampTopP.Z), Vector3.new(rampTopP.X + u.X, rampTopY + 0.14, rampTopP.Z + u.Z)), 11.5, 6.8, false)
		local bannerP = rampTopP + pr * 8.5
		poiBanner(g, Vector3.new(bannerP.X, gy(bannerP.X, bannerP.Z), bannerP.Z), angOf(u), true)
	end

	-- terraces: standing spots on the upper steps (clean rock ledges on desert, rails/crates on other biomes)
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
		if biomeName == "desert" then
			-- sparse low dark-concrete cover slabs on alternating terraces (zero yellow rails or toy crates)
			if i % 3 == 1 then
				local ca = c.a + math.rad(6)
				local cp2 = polar(Q, ca, c.r + 2.4)
				local ctan = Vector3.new(-math.sin(ca), 0, math.cos(ca))
				local bcf = CFrame.lookAt(cp2, cp2 + ctan)
				bunkerWall(g, bcf, 6.2, 3.4, 1.8)
			end
		else
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

	-- ribs: monumental dark rib-arch corridor towering cleanly against the bright sky
	local crowns = {}
	local RIBS = 6
	local SEGS = 6
	for i = 0, RIBS - 1 do
		local s = -19 + 8.6 * i
		local w = math.sin(i / (RIBS - 1) * PI)
		local rx, ry = 12.2 + 2.8 * w, 29 + 9 * w
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
		-- dark armored dorsal fin cresting each intact rib crown for crisp horizon silhouette
		if firstK == 0 and lastK == SEGS then
			part(g, Vector3.new(2.2, 5.4, 3.8), CFrame.lookAt(pts[3] + Vector3.new(0, 2.2, 0), pts[3] + Vector3.new(0, 2.2, 0) + axis), STEEL_D, false)
		end
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
		ball(g, Vector3.new(4.2, 4.2, 4.2), CFrame.new(crowns[i]), STEEL_D, false)
		if i < RIBS - 1 then
			pipe(g, crowns[i], crowns[i + 1], 3.0, STEEL_D, false)
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

	-- chest cavity: the dead core, bright-edged ribbed metallic deck plate, and where the cells rest
	local cc = onG(2.5, 0)
	ball(g, Vector3.new(7, 7, 7), CFrame.new(cc + Vector3.new(0, 3.6, 0)), STEEL_D, true)
	local ringLamp = glow(g, Vector3.new(0.5, 7.6, 7.6), CFrame.new(cc + Vector3.new(0, 3.6, 0)) * CFrame.Angles(0, 0, PI / 2), TEAL, false, 0.35)
	ringLamp.Shape = Enum.PartType.Cylinder
	light(ringLamp, TEAL, 20, 1.1)
	ribbedDeck(g, CFrame.lookAt(cc + Vector3.new(0, 0.22, 0), cc + Vector3.new(0, 0.22, 0) + axis), 9.4, 17, false)
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

	-- solemn misty gorge on desert: zero bright yellow toy gears or outpost clutter; sand drifts + craggy rock walls only
	if biomeName ~= "desert" then
		for _ = 1, 7 do
			local s, l = rnd:NextNumber(-34, 38), rnd:NextNumber(-26, 26)
			local p = onG(s, l)
			if rnd:NextNumber() < 0.7 then
				part(g, Vector3.new(rnd:NextNumber(3.5, 6), 0.5, rnd:NextNumber(2.5, 4)), CFrame.new(p + Vector3.new(0, 0.5, 0)) * CFrame.Angles(math.rad(rnd:NextNumber(-14, 14)), rnd:NextNumber(0, TAU), math.rad(rnd:NextNumber(-14, 14))), if rnd:NextNumber() < 0.3 then HAZ else STEEL, false)
			else
				xcyl(g, rnd:NextNumber(3, 5), 0.9, CFrame.new(p + Vector3.new(0, 1.3, 0)) * CFrame.Angles(rnd:NextNumber(-0.4, 0.4), rnd:NextNumber(0, TAU), rnd:NextNumber(1, 1.4)), RUST, false)
			end
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
	if biomeName == "desert" then
		-- craggy canyon rock walls framing the solemn fallen titan gorge (strictly outside ribs & dormant spots)
		for _, off in {
			{ s = -34, l = -26, yaw = angOf(axis) + 0.4, sc = 0.85, key = "desert_cliff" },
			{ s = 30, l = 28, yaw = angOf(axis) - 0.5, sc = 0.75, key = "desert_cliff" },
			{ s = -18, l = 29, yaw = angOf(axis) + 1.1, sc = 1.4, key = "env_rock_b" },
			{ s = 22, l = -28, yaw = angOf(axis) - 1.2, sc = 1.35, key = "env_rock_c" },
		} do
			local lp = onG(off.s, off.l)
			if math.max(math.abs(lp.X), math.abs(lp.Z)) <= 232 then
				rockLedge(g, lp, off.yaw, off.sc, off.key, look.rock, true)
			end
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

local function buildRefinery(root: Instance, R: Vector3, Q: Vector3, anchors: any, haul: boolean, look: { sand: Color3, rock: Color3 })
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
			local pillarTops = {}
			for _, e in { -1, 1 } do
				local pa = mid + e * step
				local px, pz = R.X + math.cos(pa) * RING, R.Z + math.sin(pa) * RING
				local y0 = lowAt(px, pz, 1.8)
				if biomeName == "desert" then
					local pcf = CFrame.lookAt(Vector3.new(px, y0, pz), Vector3.new(R.X, y0, R.Z))
					local pier = part(g, Vector3.new(5.0, 22, 5.0), pcf * CFrame.new(0, 4.8, 0), CONCRETE_D, true, { Material = Enum.Material.Concrete })
					keepMat(pier)
					local cap = part(g, Vector3.new(5.5, 1.3, 5.5), pcf * CFrame.new(0, 15.8, 0), STEEL_D, false, { Material = Enum.Material.Metal })
					keepMat(cap)
					-- subtle recessed amber gate slit (zero bright yellow bands or raw Neon balls)
					local strip = glow(g, Vector3.new(2.0, 0.45, 0.35), pcf * CFrame.new(0, 13.8, 2.55), AMBER, false)
					if e == 1 then
						light(strip, AMBER, 24, 1.1)
					end
				else
					vcyl(g, 3.8, 15.5, CFrame.new(px, y0 + 6.25, pz), STEEL_D, true)
					ball(g, Vector3.new(4.2, 4.2, 4.2), CFrame.new(px, y0 + 14.0, pz), STEEL_L, false)
					vcyl(g, 4.0, 1.1, CFrame.new(px, y0 + 3.2, pz), HAZ, false)
					local lamp = glow(g, Vector3.new(1.5, 1.5, 1.5), CFrame.new(px, y0 + 15.8, pz), AMBER, true)
					if e == 1 then
						light(lamp, AMBER, 24, 1.2)
					end
				end
				table.insert(pillarTops, Vector3.new(px, y0 + 14.2, pz))
			end
			-- bold overhead steel gate gantry spanning between the two gate pylons (14+ studs clearance, center open)
			if #pillarTops == 2 then
				pipe(g, pillarTops[1], pillarTops[2], 2.2, STEEL_D, false)
				pipe(g, pillarTops[1] + Vector3.new(0, 2.2, 0), pillarTops[2] + Vector3.new(0, 2.2, 0), 1.1, STEEL, false)
				local gateMid = polar(R, mid, RING)
				local gcf = CFrame.lookAt(Vector3.new(gateMid.X, gateMid.Y + 0.14, gateMid.Z), Vector3.new(R.X, gateMid.Y + 0.14, R.Z))
				ribbedDeck(g, gcf, 14.5, 6.6, false)
				local banP = polar(R, mid + step * 1.45, RING + 3.5)
				poiBanner(g, banP, mid + PI / 2, gi == 1)
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
				if biomeName == "desert" then
					bunkerWall(g, fr, 11.4, h, 4.0)
				else
					local col = jit(STEEL, 0.06)
					part(g, Vector3.new(4.2, h + 2.5, 11.4), fr * CFrame.new(0, (h + 2.5) / 2 - 2.5, 0), col, true)
					zcyl(g, 4.7, 11.4, fr * CFrame.new(0, h, 0), col, false)
					if i % 2 == 0 then
						part(g, Vector3.new(4.4, 1, 11.5), fr * CFrame.new(0, 3, 0), HAZ, false)
					end
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
	-- dark armored catwalk collar & vertical structural ribs on the smokestack silhouette
	vcyl(g, 13.5, 2.2, CFrame.new(S(36)), STEEL_D, false)
	vcyl(g, 11.2, 2.0, CFrame.new(S(50)), STEEL_D, false)
	local top = emitterHost(g, S(61))
	smoke(top, RGB(40, 36, 36), 10, 7, 16, 11)
	light(top, AMBER, 30, 1.0)

	if biomeName == "desert" then
		-- ONE stark monolithic brutalist concrete-and-steel bunker compound opposite the stack
		-- (zero pipe spaghetti, zero tank farm, zero crane/pillbox/supplyBay clutter; Cargo Lifter plaza 100% clear)
		local bunkerAngles = pickAngles({ gateAngles[1], gateAngles[2], stackA }, math.rad(42), stackA + PI, 1, math.rad(40))
		if #bunkerAngles > 0 then
			local ba = bunkerAngles[1]
			local bp = polar(R, ba, RING + 10)
			if not nearSide(bp.X, bp.Z, 22) then
				brutalistMonolith(g, bp, dirTo(bp, R), 24, 16, 15, true)
			end
		end
		local rockAngles = pickAngles({ gateAngles[1], gateAngles[2] }, math.rad(34), stackA + math.rad(24), 3, math.rad(88))
		local rockKeys = { "desert_cliff", "env_rock_b", "env_rock_c" }
		local rockScales = { 0.8, 1.35, 1.3 }
		for ri, ra in rockAngles do
			local rp = polar(R, ra, RING + 22)
			if not nearSide(rp.X, rp.Z, 24) then
				rockLedge(g, rp, ra + PI / 2, rockScales[ri], rockKeys[ri], look.rock, true)
			end
		end
		return
	end

	-- outer-ring lifter crane gantry (non-desert biomes)
	local gantryAngles = pickAngles({ gateAngles[1], gateAngles[2], stackA }, math.rad(42), stackA + PI, 1, math.rad(40))
	if #gantryAngles > 0 then
		local ga = gantryAngles[1]
		local gp = polar(R, ga, RING + 4)
		local gy0 = lowAt(gp.X, gp.Z, 4.5)
		local gcf0 = CFrame.lookAt(Vector3.new(gp.X, gy0, gp.Z), Vector3.new(R.X, gy0, R.Z))
		part(g, Vector3.new(9, 4, 9), gcf0 * CFrame.new(0, 1.6, 0), STEEL_D, true)
		for _, sx in { -3.4, 3.4 } do
			pipe(g, (gcf0 * CFrame.new(sx, 2, 2.6)).Position, (gcf0 * CFrame.new(sx * 0.55, 44, 0)).Position, 1.8, STEEL_D, false)
			pipe(g, (gcf0 * CFrame.new(sx, 2, -2.6)).Position, (gcf0 * CFrame.new(sx * 0.55, 44, 0)).Position, 1.8, STEEL_D, false)
		end
		part(g, Vector3.new(7.5, 2.8, 26), gcf0 * CFrame.new(0, 44.5, -8), STEEL_D, false)
		part(g, Vector3.new(7.8, 0.9, 18), gcf0 * CFrame.new(0, 42.9, -6), HAZ, false)
		pipe(g, (gcf0 * CFrame.new(0, 44, -19.5)).Position, (gcf0 * CFrame.new(0, 29, -19.5)).Position, 0.5, SOOT, false)
		part(g, Vector3.new(3.6, 3.0, 3.6), gcf0 * CFrame.new(0, 27.5, -19.5), STEEL, false)
		glow(g, Vector3.new(1.8, 1.8, 1.8), gcf0 * CFrame.new(0, 47.0, 0), RED, true)
	end

	-- tanks and pipes (non-desert biomes)
	local nTanks = if haul then 4 else 3
	local rTank = if haul then 58 else 42
	local avoid = { gateAngles[1], gateAngles[2], stackA }
	if #gantryAngles > 0 then
		table.insert(avoid, gantryAngles[1])
	end
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

	-- keep the center ~24-stud Skiff landing circle clear; place bright-edged ribbed metallic approach pads at r = 24.5 (non-colliding)
	for i = 0, 3 do
		local a = math.rad(45 + i * 90)
		local p = polar(P, a, 25.0)
		local y0 = lowAt(p.X, p.Z, 2.5)
		local base = Vector3.new(p.X, y0 + 0.1, p.Z)
		local fr = CFrame.lookAt(base, Vector3.new(P.X, base.Y, P.Z))
		ribbedDeck(g, fr, 5.6, 3.8, false)
	end

	-- perimeter LZ marker bollards at r = 27.5 (clean low concrete bollards on desert; stanchions elsewhere; 24-stud LZ 100% clear)
	local litBeacon = false
	for i = 0, 5 do
		local a = math.rad(15 + i * 60)
		local p = polar(P, a, 27.5)
		if math.max(math.abs(p.X), math.abs(p.Z)) <= 225 and not nearSide(p.X, p.Z, 24) then
			local lo, hi = lowAt(p.X, p.Z, 1.5), highAt(p.X, p.Z, 1.5)
			if hi - lo <= 1.8 then
				local base = Vector3.new(p.X, lo - 0.1, p.Z)
				local fr = CFrame.lookAt(base, Vector3.new(P.X, base.Y, P.Z))
				if biomeName == "desert" then
					local bollard = part(g, Vector3.new(2.4, 7.6, 2.4), fr * CFrame.new(0, -1.1, 0), CONCRETE, true, { Material = Enum.Material.Concrete })
					keepMat(bollard)
					local collar = part(g, Vector3.new(2.7, 0.45, 2.7), fr * CFrame.new(0, 2.7, 0), STEEL_D, false, { Material = Enum.Material.Metal })
					keepMat(collar)
					local lampCol = if i % 2 == 0 then AMBER else TEAL
					local cap = glow(g, Vector3.new(1.1, 0.35, 1.1), fr * CFrame.new(0, 3.05, 0), lampCol, false)
					if not litBeacon and i % 2 == 0 then
						litBeacon = true
						light(cap, AMBER, 28, 1.2)
					end
				else
					local stPlinth = part(g, Vector3.new(2.8, 6.2, 2.8), fr * CFrame.new(0, -2.1, 0), CONCRETE_D, true, { Material = Enum.Material.Concrete })
					keepMat(stPlinth)
					vcyl(g, 1.15, 5.8, fr * CFrame.new(0, 3.4, 0), STEEL_D, true)
					vcyl(g, 1.32, 0.7, fr * CFrame.new(0, 4.4, 0), HAZ, false)
					part(g, Vector3.new(1.8, 0.4, 1.8), fr * CFrame.new(0, 6.2, 0), STEEL_L, false)
					local lampCol = if i % 2 == 0 then AMBER else TEAL
					local cap = glow(g, Vector3.new(1.0, 0.85, 1.0), fr * CFrame.new(0, 6.8, 0), lampCol, true)
					if not litBeacon and i % 2 == 0 then
						litBeacon = true
						light(cap, AMBER, 30, 1.4)
					end
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

	local innerCands = candsAt({ 33, 37, 40 }, 15, 4.5, 1.8)
	local outerCands = candsAt({ 45, 49, 53 }, 10, 7, 2.4)

	if biomeName == "desert" then
		-- wide stark alkali extraction basin: 2 clean low concrete cover walls + craggy perimeter cliffs (zero hauler/pillbox clutter)
		for _ = 1, 2 do
			local c = takeFrom(innerCands, math.rad(95))
			if c then
				local inward = dirTo(c.p, P)
				local tan = Vector3.new(-inward.Z, 0, inward.X)
				local fr = CFrame.lookAt(c.p, c.p + tan) * CFrame.Angles(0, rnd:NextNumber(-0.15, 0.15), 0)
				bunkerWall(g, fr, 11.5, 4.4, 2.2)
			end
		end
		local cliffSpecs = {
			{ key = "desert_cliff", sc = 0.88 },
			{ key = "env_rock_b", sc = 1.45 },
			{ key = "desert_cliff", sc = 0.78 },
			{ key = "env_rock_c", sc = 1.4 },
			{ key = "env_rock_b", sc = 1.25 },
		}
		for _, cs in cliffSpecs do
			local c = takeFrom(outerCands, math.rad(55))
			if c then
				rockLedge(g, c.p, c.a + PI / 2, cs.sc, cs.key, look.rock, true)
			end
		end
		return
	end

	-- outer anchor (non-desert biomes): wrecked COG hauler + scorched ground + detached wheel/axle + cargo crate
	local hauler = takeFrom(outerCands, math.rad(45))
	if hauler then
		local c = hauler.p
		local base = Vector3.new(c.X, lowAt(c.X, c.Z, 8) - 0.2, c.Z)
		local across = dirTo(c, P)
		local fr = CFrame.lookAt(base, base + Vector3.new(-across.Z, 0, across.X)) * CFrame.Angles(0, 0.25, 0)
		local function Hh(x: number, y: number, z: number): CFrame
			return fr * CFrame.new(x, y, z)
		end
		setPiece(g, "cog_hauler_wreck", Hh(0, 0, 0) * CFrame.Angles(math.rad(3), 0, math.rad(4)))
		scorch(base, 7)
		local cb2 = Hh(-8.5, 2.6, 9) * CFrame.Angles(0, 0.4, math.rad(8))
		part(g, Vector3.new(6.2, 5, 7), cb2, CRATE, true)
		part(g, Vector3.new(6.3, 5.1, 1.1), cb2 * CFrame.new(0, 0, 1.8), HAZ, false)
		local wp = Hh(6.5, 0, 6.2).Position
		local wy = gy(wp.X, wp.Z)
		local wcf = CFrame.new(wp.X, wy + 0.75, wp.Z) * CFrame.Angles(math.rad(72), 0.6, math.rad(18))
		vcyl(g, 4.2, 1.8, wcf, SOOT, true)
		vcyl(g, 2.2, 1.9, wcf, STEEL_L, false)
		pipe(g, Vector3.new(wp.X - 1.2, wy + 0.5, wp.Z - 0.6), Vector3.new(wp.X + 2.4, wy + 1.1, wp.Z + 1.8), 0.55, RUST, false)
		smoke(emitterHost(g, Hh(0, 8.5, -3).Position), RGB(42, 38, 38), 3.6, 3, 8, 5)
		local mp = Hh(10.5, 0, -4).Position
		local my = lowAt(mp.X, mp.Z, 2.5)
		part(g, Vector3.new(3.6, 2.2, 3.6), CFrame.new(mp.X, my + 0.9, mp.Z), STEEL_D, true)
		vcyl(g, 1.1, 27, CFrame.new(mp.X, my + 14.5, mp.Z), STEEL_D, false)
		part(g, Vector3.new(7.5, 0.75, 0.75), CFrame.new(mp.X, my + 23.5, mp.Z) * CFrame.Angles(0, hauler.a, 0), STEEL, false)
		part(g, Vector3.new(5.2, 0.65, 0.65), CFrame.new(mp.X, my + 26.2, mp.Z) * CFrame.Angles(0, hauler.a + PI / 2, 0), STEEL_L, false)
		glow(g, Vector3.new(1.5, 1.5, 1.5), CFrame.new(mp.X, my + 28.6, mp.Z), TEAL, true)
	end

	for i = 1, 3 do
		local c = takeFrom(innerCands, math.rad(36))
		if c then
			local pos = c.p
			local base = Vector3.new(pos.X, lowAt(pos.X, pos.Z, 4) - 0.15, pos.Z)
			local inward = dirTo(pos, P)
			local fr = CFrame.lookAt(base, base + inward) * CFrame.Angles(0, rnd:NextNumber(-0.22, 0.22), 0)
			part(g, Vector3.new(9.6, 4.6, 2.0), fr * CFrame.new(0, 2.3, 0), jit(STEEL_D, 0.06), true)
			local cap = part(g, Vector3.new(9.7, 0.42, 1.7), fr * CFrame.new(0, 4.7, 0), STEEL_L, false, { Material = Enum.Material.Metal, CastShadow = false })
			cap:SetAttribute("KeepMat", true)
			part(g, Vector3.new(9.8, 0.75, 2.1), fr * CFrame.new(0, 3.25, 0), HAZ, false)
			part(g, Vector3.new(9.4, 1.2, 2.3), fr * CFrame.new(0, 0.6, 0), STEEL, false)
			for _, sx in { -3.4, 3.4 } do
				pipe(g, (fr * CFrame.new(sx, 0.2, -1.8)).Position, (fr * CFrame.new(sx, 3.5, -0.5)).Position, 0.45, STEEL_D, false)
			end
			if i == 1 then
				local bp = (fr * CFrame.new(6.2, 0, -0.5)).Position
				poiBanner(g, Vector3.new(bp.X, gy(bp.X, bp.Z), bp.Z), c.a, false)
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
		buildMesa(root, mesaP, refP, anchors, look)
	end)
	section("powerline", function()
		buildPowerLine(root, mesaP, refP)
	end)
	section("quarry", function()
		buildQuarry(root, quarryP, refP, anchors, look)
	end)
	section("graveyard", function()
		buildGraveyard(root, graveP, refP, anchors, look)
	end)
	section("refinery", function()
		buildRefinery(root, refP, quarryP, anchors, haul, look)
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
