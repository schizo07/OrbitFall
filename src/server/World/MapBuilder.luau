-- S.Map: builds the mission map at runtime (docs/art-direction.md v2): shaped terrain + mesh scatter + landmarks + rubble (layout: World/MapPlan).
--   S.Map.build(faction, biome?) -> Map     (YIELDS: terrain is written in chunks)
--   S.Map.clear()
--   S.Map.current                           the Map table while built, else nil
-- Map = { insertion: CFrame, extraction: Vector3, sites: {[string]: CFrame}, patrolPoints: {Vector3},
--         spawnPoints: {Vector3}, groundY: (x, z) -> number, size, faction, biome, folder, props, terrain,
--         crash: {name, crash: Vector2, spilled: Vector2}, places: {[string]: Vector3}, shapes: {...}, anchors: {...} }
-- Layout (positions of the five places, the crash variant, side spots) comes from World/MapPlan. insertion = the crash,
-- sites.codes = its spilled cell, sites.silo = refinery, uplink = mesa, generator = quarry, console = graveyard,
-- nest1..4 = MapPlan.sides, samples1..3 = MapPlan.samples. map.anchors is whatever World/Places.build returns.
-- Site CFrames sit ON the ground (y = ground height) and face the map centre.
-- NOTE for enemy ground snapping: all props live in workspace.Map.Props; raycast against `map.terrain`
-- (Terrain only) if you do not want enemies to climb on props.
--
-- Terrain: layered noise (rolling base + ridge lines + terraced mesas + craters), the map edge rises into 60-120 stud
-- cliffs. Features fade out around sites and along the lanes between them, so the combat area stays walkable.
-- Ground storytelling (see the "environmental storytelling" block): wreck fields from enemy meshes, drop-pod husks, shell craters,
-- site camps (sandbags / tarp / floodlight), COG industrial bits, BROOD eggs / webs / tusks, per-biome nature, rim smoke, dust devils.
-- Props: Blender meshes from World/Assets (env_*), tinted per biome. If an asset is not loaded the old part-built
-- (rounded ball / drum) fallbacks are used, so a failed LoadAsset never breaks a mission. The folder attribute Biome tells clients
-- which ambience to run (client/Fx/Ambience.luau).

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Assets = require(script.Parent.Assets)
local MapPlan = require(script.Parent.MapPlan)

local MapBuilder = {}
MapBuilder.current = nil :: any

local S: any = nil

local SIZE: number = Config.MapSize
local HALF = SIZE / 2
local VOX = 4
local BOTTOM = -12
local TOP = 176 -- cliffs and peaks reach ~150 studs (soft-clamped in rawH)
local CHUNK = 32 -- voxels per chunk side (128 studs)
local TAU = math.pi * 2
local RGB = Color3.fromRGB

-- Layout (x, z): every position comes from World/MapPlan (the five places, one of three crash sites, side spots, samples).
-- applyLayout() fills the tables below at build time because the crash variant is picked per mission.
--   insertion = the crash, codes = its spilled cell, silo = refinery, uplink = mesa, generator = quarry,
--   console = graveyard, extraction = salt pan, nest1..4 = MapPlan.sides, samples1..3 = MapPlan.samples.
local LAYOUT: { [string]: Vector2 } = {}
-- Flattened pads: name -> {inner, outer}. The mesa and the quarry are shaped by their own functions (see heightAt).
local PADS: { [string]: { number } } = {}
-- Radius around a place where no camps, rubble or props may go (the set pieces of World/Places live there)
local KEEPOUT: { [string]: number } = {}

type Strip = { ax: number, az: number, bx: number, bz: number, half: number, mat: Enum.Material, alt: Enum.Material? }
type Disc = { x: number, z: number, r: number }
type Seg = { ax: number, az: number, bx: number, bz: number }

local siteList: { { x: number, z: number, inner: number, outer: number } } = {}
local lanes: { Seg } = {} -- combat lanes (kept walkable and mostly clear of big props)
local riverSegs: { Seg } = {} -- the dry riverbed
local roadSegs: { Seg } = {} -- trails whose ground is levelled flat across (haul road, service road)
local strips: { Strip } = {} -- trails painted as ground material (roads, drag lines, scorched debris)
local pan: Disc? = nil -- salt pan (extraction)
local crashBowl: Disc? = nil -- scorched crater floor at the chosen crash
local spilledSpot: Disc? = nil
local refineryYard: Disc? = nil -- refinery oily ground patch
local graveyardSpot: Disc? = nil -- walker graveyard rust-stained ground patch
local crashPick = "SW"

local ROAD_MAT = Enum.Material.Concrete
local OLD_ROAD_MAT = Enum.Material.Pavement
local TRACK_MAT = Enum.Material.Basalt

local function toward(from: Vector2, to: Vector2, dist: number): Vector2
	local d = to - from
	if d.Magnitude < 0.01 then
		return from
	end
	return from + d.Unit * dist
end

local function applyLayout(which: string?)
	local crash = MapPlan.crash(which)
	crashPick = crash.name
	table.clear(LAYOUT)
	table.clear(PADS)
	table.clear(KEEPOUT)
	table.clear(siteList)
	table.clear(lanes)
	table.clear(riverSegs)
	table.clear(roadSegs)
	table.clear(strips)

	for _, p in MapPlan.places do
		LAYOUT[p.site] = p.at
		KEEPOUT[p.site] = p.r + 8
	end
	LAYOUT.insertion = crash.crash
	LAYOUT.codes = crash.spilled
	KEEPOUT.insertion = MapPlan.crashPad[1] + 6
	KEEPOUT.codes = MapPlan.spilledPad[1] + 12
	for _, s in MapPlan.sides do
		LAYOUT[s.site] = s.at
		PADS[s.site] = { 18, 40 }
	end
	for i, v in MapPlan.samples do
		LAYOUT["samples" .. i] = v
		PADS["samples" .. i] = { 12, 30 }
	end
	local refinery = MapPlan.places.refinery.at
	LAYOUT.leverA = refinery + Vector2.new(-38, -22)
	LAYOUT.leverB = refinery + Vector2.new(-19, -30)

	PADS.insertion = { MapPlan.crashPad[1], MapPlan.crashPad[2] }
	PADS.codes = { MapPlan.spilledPad[1], MapPlan.spilledPad[2] }
	PADS.silo = { 44, 70 } -- refinery plaza
	PADS.extraction = { 40, 62 } -- salt pan
	PADS.console = { 36, 60 } -- graveyard floor
	for name, pad in PADS do
		local c = LAYOUT[name]
		table.insert(siteList, { x = c.X, z = c.Y, inner = pad[1], outer = pad[2] })
	end
	-- shaped places: they only suppress ridges and craters around themselves
	local mesaP, quarryP = MapPlan.places.mesa, MapPlan.places.quarry
	table.insert(siteList, { x = mesaP.at.X, z = mesaP.at.Y, inner = mesaP.r - 4, outer = mesaP.r + 8 })
	table.insert(siteList, { x = quarryP.at.X, z = quarryP.at.Y, inner = quarryP.r - 2, outer = quarryP.r + 10 })

	local function lane(a: Vector2, b: Vector2)
		table.insert(lanes, { ax = a.X, az = a.Y, bx = b.X, bz = b.Y })
	end
	lane(crash.crash, crash.spilled)
	lane(crash.spilled, refinery)
	lane(mesaP.at, refinery)
	lane(quarryP.at, refinery)
	lane(MapPlan.places.graveyard.at, refinery)
	lane(refinery, MapPlan.places.saltpan.at)
	local road: any = MapPlan.trails[#MapPlan.trails]
	for _, t in MapPlan.trails do
		if t.name == "serviceRoad" then
			road = t
		end
	end
	lane(road.fromAt, road.via)
	lane(road.via, refinery)
	lane(MapPlan.sideSpot("foundry").at, refinery)
	lane(MapPlan.sideSpot("any").at, refinery)

	local rv = MapPlan.riverbed
	for i = 1, #rv - 1 do
		table.insert(riverSegs, { ax = rv[i].X, az = rv[i].Y, bx = rv[i + 1].X, bz = rv[i + 1].Y })
	end

	-- ground trails (material strips; the haul road and the service road are also levelled flat across)
	local function strip(a: Vector2, b: Vector2, half: number, mat: Enum.Material, alt: Enum.Material?)
		table.insert(strips, { ax = a.X, az = a.Y, bx = b.X, bz = b.Y, half = half, mat = mat, alt = alt })
	end
	local function level(a: Vector2, b: Vector2)
		table.insert(roadSegs, { ax = a.X, az = a.Y, bx = b.X, bz = b.Y })
	end
	local haulA, haulB = toward(quarryP.at, refinery, 14), toward(refinery, quarryP.at, 40)
	strip(haulA, haulB, 5.5, ROAD_MAT)
	level(toward(quarryP.at, refinery, quarryP.r + 14), haulB)
	local viaP = road.via
	local svcEnd = toward(refinery, viaP, 40)
	strip(road.fromAt, viaP, 5, OLD_ROAD_MAT)
	strip(viaP, svcEnd, 5, OLD_ROAD_MAT)
	level(road.fromAt, viaP)
	level(viaP, svcEnd)
	local gy = MapPlan.places.graveyard.at
	local dragA, dragB = toward(gy, refinery, 24), toward(refinery, gy, 40)
	local dn = (dragB - dragA).Unit
	local side = Vector2.new(-dn.Y, dn.X) * 5
	strip(dragA + side, dragB + side, 2.3, TRACK_MAT)
	strip(dragA - side, dragB - side, 2.3, TRACK_MAT)
	strip(toward(crash.crash, crash.spilled, 26), toward(crash.spilled, crash.crash, 8), 4, Enum.Material.Basalt, Enum.Material.Slate)

	local sp = MapPlan.places.saltpan
	pan = { x = sp.at.X, z = sp.at.Y, r = 46 }
	crashBowl = { x = crash.crash.X, z = crash.crash.Y, r = MapPlan.crashPad[1] * 0.95 }
	spilledSpot = { x = crash.spilled.X, z = crash.spilled.Y, r = 11 }
	refineryYard = { x = refinery.X, z = refinery.Y, r = MapPlan.places.refinery.r }
	graveyardSpot = { x = gy.X, z = gy.Y, r = MapPlan.places.graveyard.r }
end

-- ---------------------------------------------------------------- biomes
-- One dominant hue per planet (art rule 1). Terrain colours, prop tints, mood, clouds.
type Biome = {
	terrain: { [Enum.Material]: Color3 },
	rocks: { Color3 },
	rockMat: Enum.Material,
	crystal: Color3,
	wall: { Color3 },
	plant: { Color3 },
	smoke: Color3,
	mood: { [string]: any },
}
local M = Enum.Material
local BIOMES: { [string]: Biome } = {
	desert = { -- 3-band stylized desert: bright bleached-gold sky, dark slate-sandstone silhouettes, muted low-sat ochre-slate deck
		terrain = {
			[M.Sand] = RGB(114, 98, 80), [M.Sandstone] = RGB(96, 82, 68), [M.Rock] = RGB(74, 68, 62),
			[M.Basalt] = RGB(54, 50, 48), [M.Ground] = RGB(88, 78, 66), [M.Slate] = RGB(66, 62, 58),
			[M.Grass] = RGB(86, 82, 66), [M.Mud] = RGB(74, 64, 54), [M.Salt] = RGB(156, 148, 134),
			[M.Asphalt] = RGB(58, 56, 54), [M.Cobblestone] = RGB(92, 84, 74), [M.Limestone] = RGB(122, 112, 98),
		},
		rocks = { RGB(96, 86, 76), RGB(80, 72, 66), RGB(108, 96, 84) },
		rockMat = M.Sandstone,
		crystal = RGB(220, 150, 90),
		wall = { RGB(94, 88, 82), RGB(80, 76, 72), RGB(68, 66, 64) },
		plant = { RGB(84, 76, 62), RGB(98, 88, 70) },
		smoke = RGB(42, 38, 36),
		mood = { -- Band 1 high-key sunlit bleached-haze / pale-gold overcast sky: washes horizon into clean silhouettes, pops dark smoke & combat emissives
			clock = 17.3, elev = 0.17, bright = 3.1, expo = -0.02, amb = RGB(58, 56, 54), out = RGB(114, 108, 98),
			top = RGB(236, 228, 210), bottom = RGB(122, 112, 100),
			atmDensity = 0.32, atmOffset = 0.12, haze = 2.1, glare = 0.12, atm = RGB(224, 214, 194), decay = RGB(194, 182, 162),
			tint = RGB(250, 246, 238), sat = -0.14, contrast = 0.28, bloom = 0.68, rays = 0.08, sun = 10, stars = 0,
			cloudCover = 0.58, cloudDensity = 0.52, cloudColor = RGB(222, 214, 200),
			envDiffuse = 0.24, shadowSoft = 0.18,
		},
	},
	ash = { -- charcoal ground under a burning red sky (red lives in sky, haze and lava only)
		terrain = {
			[M.Sand] = RGB(90, 82, 78), [M.Ground] = RGB(72, 66, 64), [M.Basalt] = RGB(58, 54, 54),
			[M.Rock] = RGB(66, 61, 60), [M.Slate] = RGB(72, 66, 64), [M.Sandstone] = RGB(84, 76, 72),
			[M.CrackedLava] = RGB(235, 96, 40), [M.Mud] = RGB(48, 45, 45), [M.Grass] = RGB(70, 66, 60),
			[M.Salt] = RGB(200, 194, 188),
		},
		rocks = { RGB(62, 58, 58), RGB(80, 74, 72), RGB(50, 47, 48) },
		rockMat = M.Basalt,
		crystal = RGB(255, 140, 70),
		wall = { RGB(104, 98, 96), RGB(90, 85, 84), RGB(76, 72, 72) },
		plant = { RGB(50, 46, 46), RGB(66, 58, 56) },
		smoke = RGB(52, 46, 46),
		mood = {
			clock = 17.8, elev = 0.17, bright = 2.7, expo = 0.25, amb = RGB(52, 41, 37), out = RGB(83, 62, 55),
			top = RGB(255, 130, 84), bottom = RGB(110, 56, 62),
			atmDensity = 0.42, atmOffset = 0.1, haze = 2.8, glare = 2.0, atm = RGB(236, 100, 70), decay = RGB(120, 40, 40),
			tint = RGB(255, 240, 230), sat = -0.1, contrast = 0.3, bloom = 0.55, rays = 0.14, sun = 18, stars = 0,
			cloudCover = 0.7, cloudDensity = 0.75, cloudColor = RGB(70, 50, 45), -- dark warm grey-brown: a red cloud colour mixed with the sky gradient came out as green blotches
			envDiffuse = 0.28, shadowSoft = 0.15,
		},
	},
	swamp = { -- toxic dusk: desaturated teal haze, violet shadows, acid green only on bugs and slime
		terrain = {
			[M.Grass] = RGB(58, 86, 66), [M.Mud] = RGB(50, 46, 64), [M.Ground] = RGB(70, 80, 72),
			[M.Slate] = RGB(70, 64, 84), [M.Rock] = RGB(64, 58, 78), [M.Sand] = RGB(100, 118, 108),
			[M.Sandstone] = RGB(84, 78, 100), [M.Basalt] = RGB(40, 38, 56), [M.Salt] = RGB(196, 214, 206),
		},
		rocks = { RGB(70, 64, 84), RGB(60, 68, 80), RGB(78, 70, 96) },
		rockMat = M.Slate,
		crystal = RGB(150, 255, 120),
		wall = { RGB(96, 104, 110), RGB(84, 92, 100), RGB(72, 80, 92) },
		plant = { RGB(64, 56, 86), RGB(56, 80, 74) },
		smoke = RGB(60, 70, 84),
		mood = {
			clock = 17.9, elev = 0.17, bright = 2.6, expo = 0.15, amb = RGB(56, 64, 72), out = RGB(88, 98, 106),
			top = RGB(170, 205, 200), bottom = RGB(110, 76, 170),
			atmDensity = 0.45, atmOffset = 0.05, haze = 2.1, glare = 2.0, atm = RGB(110, 160, 150), decay = RGB(120, 70, 150),
			tint = RGB(232, 244, 242), sat = -0.1, contrast = 0.3, bloom = 0.5, rays = 0.12, sun = 12, stars = 600,
			cloudCover = 0.6, cloudDensity = 0.55, cloudColor = RGB(120, 112, 136),
			envDiffuse = 0.4, shadowSoft = 0.15,
		},
	},
	ice = { -- cold blue
		terrain = {
			[M.Snow] = RGB(228, 240, 252), [M.Glacier] = RGB(150, 192, 238), [M.Ground] = RGB(122, 142, 172),
			[M.Slate] = RGB(98, 118, 162), [M.Rock] = RGB(76, 94, 134), [M.Sand] = RGB(198, 216, 238),
			[M.Sandstone] = RGB(142, 166, 208), [M.Basalt] = RGB(52, 66, 102), [M.Mud] = RGB(92, 108, 142),
			[M.Salt] = RGB(222, 232, 246),
		},
		rocks = { RGB(150, 176, 214), RGB(122, 148, 192), RGB(190, 210, 240) },
		rockMat = M.Glacier,
		crystal = RGB(170, 220, 255),
		wall = { RGB(170, 190, 214), RGB(150, 172, 200), RGB(130, 152, 184) },
		plant = { RGB(140, 170, 210), RGB(170, 200, 236) },
		smoke = RGB(110, 128, 156),
		mood = {
			clock = 8.6, elev = 0.17, bright = 2.7, expo = -0.05, amb = RGB(55, 65, 83), out = RGB(88, 102, 124),
			top = RGB(226, 238, 255), bottom = RGB(130, 150, 200),
			atmDensity = 0.36, atmOffset = 0.12, haze = 1.8, glare = 1.8, atm = RGB(190, 212, 245), decay = RGB(100, 134, 200),
			tint = RGB(232, 242, 255), sat = -0.05, contrast = 0.3, bloom = 0.5, rays = 0.14, sun = 10, stars = 0,
			cloudCover = 0.55, cloudDensity = 0.5, cloudColor = RGB(190, 202, 224),
			envDiffuse = 0.3, shadowSoft = 0.15,
		},
	},
	crystal = { -- Lumen Concord worlds: pale chalky ground, lavender crystal outcrops, cool violet light
		terrain = {
			[M.Salt] = RGB(206, 200, 218), [M.Limestone] = RGB(178, 172, 196), [M.Ground] = RGB(150, 144, 170),
			[M.Slate] = RGB(112, 104, 140), [M.Rock] = RGB(96, 88, 124), [M.Glacier] = RGB(176, 160, 232),
			[M.Sand] = RGB(196, 190, 210), [M.Sandstone] = RGB(160, 150, 186), [M.Basalt] = RGB(58, 50, 82),
			[M.Mud] = RGB(120, 110, 150), [M.Grass] = RGB(150, 144, 170), [M.Snow] = RGB(240, 238, 252),
		},
		rocks = { RGB(176, 170, 196), RGB(150, 142, 178), RGB(206, 200, 222) },
		rockMat = M.Limestone,
		crystal = RGB(170, 140, 255),
		wall = { RGB(186, 180, 204), RGB(164, 158, 186), RGB(140, 134, 166) },
		plant = { RGB(120, 106, 160), RGB(150, 136, 190) },
		smoke = RGB(120, 110, 150),
		mood = { -- cold morning light through violet haze; the glow lives on crystals and Lumen cores
			clock = 7.4, elev = 0.17, bright = 2.6, expo = 0.0, amb = RGB(58, 52, 80), out = RGB(98, 92, 128),
			top = RGB(214, 206, 255), bottom = RGB(120, 96, 176),
			atmDensity = 0.38, atmOffset = 0.1, haze = 2.0, glare = 1.6, atm = RGB(170, 150, 230), decay = RGB(110, 80, 170),
			tint = RGB(236, 232, 255), sat = -0.08, contrast = 0.3, bloom = 0.55, rays = 0.12, sun = 9, stars = 400,
			cloudCover = 0.55, cloudDensity = 0.5, cloudColor = RGB(170, 160, 210),
			envDiffuse = 0.35, shadowSoft = 0.15,
		},
	},
}
-- gritty pass for the non-desert planets (desert is authored dark above): terrain ~25% darker, props ~20%, hue identity kept
do
	local function dim(c: Color3, k: number): Color3
		return Color3.new(c.R * k, c.G * k, c.B * k)
	end
	for name, b in BIOMES do
		if name ~= "desert" then
			local tk = if name == "swamp" or name == "crystal" then 0.9 else 0.75 -- swamp already sits at dusk; full dimming made it murky (crystal: pale ground)
			for mat, col in b.terrain do
				if mat ~= M.CrackedLava then
					b.terrain[mat] = dim(col, tk)
				end
			end
			for i, c in b.rocks do
				b.rocks[i] = dim(c, 0.8)
			end
			for i, c in b.wall do
				b.wall[i] = dim(c, 0.8)
			end
			for i, c in b.plant do
				b.plant[i] = dim(c, 0.85)
			end
		end
	end
end
local biomeName = "desert"
local B: Biome = BIOMES.desert

-- ---------------------------------------------------------------- heightfield
local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local noise = math.noise

-- rounded ridge: 1 on the crest, 0 at the foot, flat at both ends (the old r*r crest was a knife edge)
local function ridge(n: number): number
	local a = math.min(1, math.abs(n) * 1.6)
	return 0.5 + 0.5 * math.cos(a * math.pi)
end

-- soft steps: each rise is spread over the whole step, so it reads as a rolling shoulder, not a stair
local function terrace(v: number): number
	local fl = math.floor(v)
	return fl + smooth(v - fl)
end

-- which part of the map a point is in: north is rockier, south has dunes, east is flat salt country (each 0..1)
local function region(x: number, z: number): (number, number, number)
	return smooth((-z - 10) / 140), smooth((z - 10) / 140), smooth((x - 40) / 120)
end

local function distSeg(px: number, pz: number, ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	local l2 = dx * dx + dz * dz
	local t = if l2 > 0 then math.clamp(((px - ax) * dx + (pz - az) * dz) / l2, 0, 1) else 0
	local cx, cz = ax + dx * t, az + dz * t
	return math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2)
end

local function inLane(x: number, z: number, width: number): boolean
	for _, l in lanes do
		if distSeg(x, z, l.ax, l.az, l.bx, l.bz) < width then
			return true
		end
	end
	return false
end

-- 0 on sites and lanes, 1 in the wilds: terrain features are scaled by this so the combat area stays walkable
local function featureMask(x: number, z: number): number
	local m = 1
	for _, s in siteList do
		local dx, dz = x - s.x, z - s.z
		local lim = s.outer + 30
		local d2 = dx * dx + dz * dz
		if d2 < lim * lim then
			local k = smooth((math.sqrt(d2) - s.inner * 0.7) / (lim - s.inner * 0.7))
			if k < m then
				m = k
			end
		end
	end
	for _, l in lanes do
		local d = distSeg(x, z, l.ax, l.az, l.bx, l.bz)
		if d < 62 then
			local k = smooth((d - 12) / 50) -- a long fade: the ridges rise slowly away from a lane (no steep walls beside it)
			if k < m then
				m = k
			end
		end
	end
	for _, l in riverSegs do
		local d = distSeg(x, z, l.ax, l.az, l.bx, l.bz)
		if d < 52 then
			local k = smooth((d - 12) / 40)
			if k < m then
				m = k
			end
		end
	end
	return m
end

local craters: { { x: number, z: number, r: number, depth: number } } = {}

local function craterBowl(x: number, z: number): number
	local best = 0
	for _, c in craters do
		local dx, dz = x - c.x, z - c.z
		if math.abs(dx) < c.r and math.abs(dz) < c.r then
			local d = math.sqrt(dx * dx + dz * dz) / c.r
			if d < 1 then
				best = math.max(best, 1 - d * d)
			end
		end
	end
	return best
end

local function planCraters(count: number)
	craters = {}
	local r2 = Random.new(4242)
	for _ = 1, 60 do
		if #craters >= count then
			break
		end
		local r = r2:NextNumber(16, 30)
		local x, z = r2:NextNumber(-225, 225), r2:NextNumber(-225, 225)
		local ok = true
		for _, s in siteList do
			if (x - s.x) ^ 2 + (z - s.z) ^ 2 < (s.outer + r + 14) ^ 2 then
				ok = false
				break
			end
		end
		for _, l in riverSegs do
			if distSeg(x, z, l.ax, l.az, l.bx, l.bz) < r + 24 then
				ok = false
				break
			end
		end
		if ok and not inLane(x, z, r + 22) then
			for _, c in craters do
				if (x - c.x) ^ 2 + (z - c.z) ^ 2 < (c.r + r + 30) ^ 2 then
					ok = false
					break
				end
			end
		end
		if ok then
			table.insert(craters, { x = x, z = z, r = r, depth = r2:NextNumber(4.5, 7.5) })
		end
	end
end

local function rawH(x: number, z: number): number
	local north, south, east = region(x, z)
	-- broad rolling base (the east is flatter: salt country)
	local flat = 1 - 0.5 * east
	local h = 13 + (noise(x / 210 + 11.3, z / 210 + 7.7) * 17 + noise(x / 85 + 3.1, z / 85 + 9.9) * 6) * flat + noise(x / 27 + 1.7, z / 27 + 4.2) * 1.4
	local F = featureMask(x, z)
	if F > 0.001 then
		-- low rounded ridge lines, only in some regions, mostly in the rocky north
		local rm = smooth((noise(x / 300 + 5.3, z / 300 + 2.2) + 0.12) / 0.45)
		if rm > 0 then
			h += ridge(noise(x / 120 + 50.3, z / 90 + 20.1)) * rm * F * 11 * (0.4 + north * 0.9) * flat
		end
		h += ridge(noise(x / 52 + 8.8, z / 40 + 3.3)) * F * 3 * (0.6 + north * 0.6)
		-- soft stepped rises (rounded shoulders, not stairs)
		local t = (noise(x / 190 + 31.4, z / 190 + 17.9) - 0.06) / 0.5
		if t > 0 then
			h += terrace(math.min(t, 1) * 3) * 5.5 * F * (1 - 0.6 * east)
		end
		-- long soft dunes in the south: sine crests bent by noise, squared so the crests are round and the troughs wide
		if south > 0.01 then
			local s = math.sin(x / 34 + noise(x / 110 + 9.1, z / 110 + 3.3) * 5) * 0.5 + 0.5
			h += s * s * 4.5 * south * F
		end
	end
	for _, c in craters do
		local dx, dz = x - c.x, z - c.z
		if math.abs(dx) < c.r * 1.5 and math.abs(dz) < c.r * 1.5 then
			local d = math.sqrt(dx * dx + dz * dz) / c.r
			if d < 1 then
				h -= c.depth * (1 - d * d)
			end
			h += c.depth * 0.4 * math.exp(-(((d - 1.05) / 0.32) ^ 2)) -- a broad soft rim, not a sharp lip
		end
	end
	-- the edge of the world: strata cliffs with a ragged, varying crest (45-130 studs) and sharp peaks, so the horizon
	-- reads as a mountain range and not as one flat band
	local m = math.max(math.abs(x), math.abs(z)) + noise(x / 60 + 2.2, z / 60 + 8.1) * 14 + noise(x / 23 + 7.7, z / 23 + 1.3) * 5
	if m > 250 then
		local t = math.clamp((m - 250) / 55, 0, 1)
		-- strata steps are noisy (the step edge wanders) and only weakly weighted, so the cliffs read as ragged ledges, not flat walls
		local q = math.clamp(math.floor(t * 7 + noise(x / 26 + 3.3, z / 26 + 9.7) * 1.3), 0, 7) / 7
		local tt = t * 0.72 + q * 0.28
		local lo = noise(x / 150 + 81.7, z / 150 + 40.3) * 0.5 + 0.5 -- long wavelength: whole stretches are low or high
		local mid = noise(x / 55 + 12.1, z / 55 + 63.9) * 0.5 + 0.5
		local amp = 45 + 60 * lo + 28 * mid
		h += tt * amp + noise(x / 16 + 4.4, z / 16 + 9.1) * 9 * t + noise(x / 8.5 + 14.2, z / 8.5 + 2.9) * 3.5 * t
		-- peaks and notches along the crest
		h += ridge(noise(x / 38 + 21.3, z / 38 + 55.5)) * 34 * t * t * (0.35 + lo)
		h -= math.max(0, noise(x / 70 + 5.1, z / 70 + 77.7) - 0.2) * 40 * t
	end
	if h > 148 then
		h = 148 + (h - 148) * 0.25 -- soft ceiling: no flat tops cut off by the voxel height
	end
	return math.max(h, 3)
end

local flats: { { x: number, z: number, inner: number, outer: number, h: number, rim: number? } } = {}

-- closest point on a segment: (distance, x, z)
local function nearSeg(px: number, pz: number, ax: number, az: number, bx: number, bz: number): (number, number, number)
	local dx, dz = bx - ax, bz - az
	local l2 = dx * dx + dz * dz
	local t = if l2 > 0 then math.clamp(((px - ax) * dx + (pz - az) * dz) / l2, 0, 1) else 0
	local cx, cz = ax + dx * t, az + dz * t
	return math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2), cx, cz
end

-- The mesa and the quarry are filled in at build time (computeShapes) once the ground around them is known.
type Mesa = { x: number, z: number, top: number, rt: number, ro: number, dx: number, dz: number, slope: number, rampEnd: number, reach2: number }
type Quarry = { x: number, z: number, r: number, depth: number, g: number, levels: { number }, rw: number, tw: number, dx: number, dz: number, reach2: number }
local mesa: Mesa? = nil
local quarry: Quarry? = nil

-- ground before the mesa and the quarry: rolling terrain, levelled roads, the dry riverbed, flat pads
local function baseHeight(x: number, z: number): number
	local h = rawH(x, z)
	-- roads are levelled across (no cross slope): the ground takes the height of the road's centreline
	for _, l in roadSegs do
		local d, cx, cz = nearSeg(x, z, l.ax, l.az, l.bx, l.bz)
		if d < 15 then
			local w = 1 - smooth((d - 5) / 10)
			if w > 0 then
				h += (rawH(cx, cz) - h) * w
			end
		end
	end
	-- dry riverbed: ~6 deep below its own centreline, a flat floor ~10 wide and long gentle banks (~24 wide at mid depth)
	for _, l in riverSegs do
		local d, cx, cz = nearSeg(x, z, l.ax, l.az, l.bx, l.bz)
		d += noise(x / 45 + 7.7, z / 45 + 2.9) * 3
		if d < 21 then
			local w = 1 - smooth((d - 5) / 16)
			if w > 0 then
				local floorY = math.max(rawH(cx, cz) - 6, h - 6) -- never more than 6 below the local ground: no cut walls
				if floorY < h then
					h += (floorY - h) * w
				end
			end
		end
	end
	for _, f in flats do
		local dx, dz = x - f.x, z - f.z
		if biomeName == "desert" then
			local reach = f.outer + 8
			if math.abs(dx) < reach and math.abs(dz) < reach then
				local d = math.sqrt(dx * dx + dz * dz)
				-- keep d <= f.inner completely flat; warp the outer blend skirt and crater lip so pads never read as circles
				local outerW = math.max(f.inner + 6, f.outer + noise(x / 28 + f.x * 0.013, z / 28 + f.z * 0.017) * 7)
				if d < outerW then
					local w = 1 - smooth((d - f.inner) / (outerW - f.inner))
					h += (f.h - h) * w
				end
				if f.rim and d < outerW + 10 then -- a low irregular scorched lip around the crash crater
					h += f.rim * math.exp(-(((d - (outerW - 9)) / 5) ^ 2))
				end
			end
		elseif math.abs(dx) < f.outer and math.abs(dz) < f.outer then
			local d = math.sqrt(dx * dx + dz * dz)
			if d < f.outer then
				local w = 1 - smooth((d - f.inner) / (f.outer - f.inner))
				h += (f.h - h) * w
				if f.rim then -- a low scorched lip around a crater
					h += f.rim * math.exp(-(((d - (f.outer - 9)) / 5) ^ 2))
				end
			end
		end
	end
	return h
end

-- Signal Mesa: flat top, steep rounded sides, one walkable ramp (12 wide) on the side facing the refinery
local function mesaShape(h: number, x: number, z: number): number
	local m = mesa :: Mesa
	local dx, dz = x - m.x, z - m.z
	if dx * dx + dz * dz > m.reach2 then
		return h
	end
	local d = math.sqrt(dx * dx + dz * dz) + noise(x / 37 + m.x, z / 37 + m.z) * 2.4 -- not a perfect circle
	local out = h + (m.top - h) * (1 - smooth((d - m.rt) / (m.ro - m.rt)))
	local u = dx * m.dx + dz * m.dz
	if u > m.rt - 8 and u < m.rampEnd then
		local av = math.abs(-dx * m.dz + dz * m.dx)
		if av < 22 then
			local rampH = m.top - math.max(0, u - (m.rt - 2)) * m.slope
			if rampH > out then
				out += (rampH - out) * (1 - smooth((av - 6) / 16)) -- 12 wide and flat across, long rounded flanks
			end
		end
	end
	return out
end

-- Quarry: a stepped pit (flat terrace rings with short rounded risers), one ramp down from the rim on the refinery side
local function quarryShape(h: number, x: number, z: number): number
	local q = quarry :: Quarry
	local dx, dz = x - q.x, z - q.z
	local d2 = dx * dx + dz * dz
	if d2 > q.reach2 then
		return h
	end
	local d = math.sqrt(d2) + noise(x / 31 + q.x, z / 31 + q.z) * 2.2
	local dip = 0
	local edge = q.r
	local found = false
	for i = 1, #q.levels do
		local prev = if i > 1 then q.levels[i - 1] else 0
		if d >= edge - q.rw then
			dip = prev + (q.levels[i] - prev) * (1 - smooth((d - (edge - q.rw)) / q.rw))
			found = true
			break
		end
		edge -= q.rw + q.tw
	end
	if not found then
		dip = q.depth
	end
	local out = h + (q.g - dip - h) * (1 - smooth((d - q.r) / 12))
	-- the ramp: a straight line from the pit floor up to the rim, cut through the terraces
	local u = dx * q.dx + dz * q.dz
	if u > 6 and u < q.r + 8 then
		local av = math.abs(-dx * q.dz + dz * q.dx)
		if av < 12 then
			local floorEdge = q.r - 4 * q.rw - 3 * q.tw
			local rampDip = q.depth * (1 - math.clamp((u - floorEdge) / (q.r + 2 - floorEdge), 0, 1))
			out += (q.g - rampDip - out) * (1 - smooth((av - 6) / 6))
		end
	end
	return out
end

local function heightAt(x: number, z: number): number
	local h = baseHeight(x, z)
	if mesa then
		h = mesaShape(h, x, z)
	end
	if quarry then
		h = quarryShape(h, x, z)
	end
	return math.max(h, -6)
end

-- average ground height on a ring (the level the mesa top and the quarry rim are measured from)
local function ringAverage(cx: number, cz: number, r: number): number
	local sum = 0
	for k = 0, 11 do
		local a = k / 12 * TAU
		sum += baseHeight(cx + math.cos(a) * r, cz + math.sin(a) * r)
	end
	return sum / 12
end

local function computeShapes()
	mesa, quarry = nil, nil
	local refinery = MapPlan.places.refinery.at
	local mp = MapPlan.places.mesa
	local md = (refinery - mp.at).Unit
	local rt, ro = 31, 47
	local mg = ringAverage(mp.at.X, mp.at.Y, ro + 10)
	local slope = 0.48
	local top = mg + mp.height
	-- the ramp runs down until it meets the actual ground along its axis (the ground there is not at the ring average)
	local rampEnd = rt + 8
	for u = rt, 200, 2 do
		local rampH = top - math.max(0, u - (rt - 2)) * slope
		rampEnd = u + 8
		if rampH <= baseHeight(mp.at.X + md.X * u, mp.at.Y + md.Y * u) + 0.3 then
			break
		end
	end
	mesa = {
		x = mp.at.X, z = mp.at.Y, top = top, rt = rt, ro = ro, dx = md.X, dz = md.Y, slope = slope, rampEnd = rampEnd,
		reach2 = (math.max(ro + 6, rampEnd + 18)) ^ 2,
	}
	local qp = MapPlan.places.quarry
	local qd = (refinery - qp.at).Unit
	local qg = math.max(ringAverage(qp.at.X, qp.at.Y, qp.r + 14), qp.depth - 6) -- the pit floor never goes below -6
	quarry = {
		x = qp.at.X, z = qp.at.Y, r = qp.r, depth = qp.depth, g = qg,
		levels = { qp.depth * 0.28, qp.depth * 0.56, qp.depth * 0.83, qp.depth },
		rw = 3, tw = 9, dx = qd.X, dz = qd.Y,
		reach2 = (qp.r + 18) ^ 2,
	}
end

-- Terrain material by biome, slope and height (art rule: flats / slopes / cliffs differ, pits glow in ash)
local function strata(h: number, a: Enum.Material, b: Enum.Material): Enum.Material
	return if math.floor(h / 5) % 2 == 0 then a else b
end

-- Desert per-place ground overlays: each named place gets its own subtle material palette with multi-octave warped,
-- feathered edges (no crisp discs or hard circular seams).
local function desertOverlayMat(x: number, z: number, slope: number): Enum.Material?
	local n = noise(x / 14 + 3.1, z / 14 + 8.7)
	-- Salt pan: sun-baked alkali crust mottled with limestone dust, fading into sand
	if pan then
		local dx, dz = x - pan.x, z - pan.z
		local reach = pan.r + 22
		if math.abs(dx) < reach and math.abs(dz) < reach then
			local d = math.sqrt(dx * dx + dz * dz)
			local w = noise(x / 36 + 1.4, z / 36 + 5.2) * 12 + n * 5
			local t = 1 - smooth((d + w - (pan.r - 15)) / 24)
			local nf = noise(x / 7.5 + 2.1, z / 7.5 + 6.4)
			local patch = noise(x / 15 + 9.3, z / 15 + 3.7)
			if t > 0.64 + nf * 0.34 + patch * 0.18 then
				return M.Salt
			elseif slope <= 0.55 and t > 0.18 + nf * 0.40 then
				return M.Limestone
			end
		end
	end
	if slope > 0.6 then
		return nil
	end
	-- Roads, drag tracks and scorched debris trail (debris trail gets softer ragged edges)
	for _, s in strips do
		local d = distSeg(x, z, s.ax, s.az, s.bx, s.bz)
		if s.alt then
			local nf = noise(x / 7.5 + 1.3, z / 7.5 + 4.1)
			local w = s.half + n * 1.8
			if d < w then
				return if nf > 0.12 then s.alt else s.mat
			elseif d < w + 3.5 and nf > 0.08 + (d - w) * 0.12 then
				return if nf > 0.28 then M.Ground else s.alt
			end
		elseif d < s.half + n * 0.7 then
			return s.mat
		end
	end
	-- Refinery: darker oily ground (asphalt mottled with oil-stained mud/slate, bleeding past the walls and tanks)
	if refineryYard then
		local dx, dz = x - refineryYard.x, z - refineryYard.z
		local reach = refineryYard.r + 32
		if math.abs(dx) < reach and math.abs(dz) < reach then
			local d = math.sqrt(dx * dx + dz * dz)
			local w = noise(x / 32 + 7.1, z / 32 + 2.3) * 11 + noise(x / 13 + 4.5, z / 13 + 9.2) * 4.5
			local t = 1 - smooth((d + w - (refineryYard.r - 10)) / 30)
			local nf = noise(x / 7.5 + 8.3, z / 7.5 + 1.9)
			local nm = noise(x / 16 + 3.7, z / 16 + 6.1)
			if t > 0.55 + nf * 0.42 then
				return if nm > 0.16 then M.Mud elseif nm < -0.22 then M.Slate else M.Asphalt
			elseif t > 0.18 + nf * 0.46 then
				return if nm > 0.05 then M.Ground else M.Mud
			end
		end
	end
	-- Crash site: scorched dark sand and charred blast crater with irregular soot halo
	if crashBowl then
		local dx, dz = x - crashBowl.x, z - crashBowl.z
		local reach = crashBowl.r + 30
		if math.abs(dx) < reach and math.abs(dz) < reach then
			local d = math.sqrt(dx * dx + dz * dz)
			local w = noise(x / 26 + 2.8, z / 26 + 7.4) * 10 + noise(x / 11 + 6.2, z / 11 + 3.5) * 4.5
			local t = 1 - smooth((d + w - (crashBowl.r - 10)) / 28)
			local nf = noise(x / 7 + 4.9, z / 7 + 8.1)
			local nm = noise(x / 14 + 1.7, z / 14 + 5.3)
			if t > 0.54 + nf * 0.42 then
				return if nm > 0.2 then M.Slate else M.Basalt
			elseif t > 0.16 + nf * 0.46 then
				return if nm > 0.15 then M.Ground elseif nm < -0.15 then M.Slate else M.Mud
			end
		end
	end
	-- Spilled crate: ragged scorch patch fading softly into sand
	if spilledSpot then
		local dx, dz = x - spilledSpot.x, z - spilledSpot.z
		local reach = spilledSpot.r + 18
		if math.abs(dx) < reach and math.abs(dz) < reach then
			local d = math.sqrt(dx * dx + dz * dz)
			local w = noise(x / 16 + 5.4, z / 16 + 1.2) * 5 + noise(x / 8 + 2.7, z / 8 + 6.8) * 2.5
			local t = 1 - smooth((d + w - (spilledSpot.r - 4)) / 14)
			local nf = noise(x / 6.5 + 9.1, z / 6.5 + 3.4)
			if t > 0.52 + nf * 0.42 then
				return if nf > 0.2 then M.Slate else M.Basalt
			elseif t > 0.18 + nf * 0.45 then
				return if nf > 0 then M.Ground else M.Slate
			end
		end
	end
	-- Walker graveyard: rust-stained, churned dark soil beneath the fallen hull
	if graveyardSpot then
		local dx, dz = x - graveyardSpot.x, z - graveyardSpot.z
		local reach = graveyardSpot.r + 24
		if math.abs(dx) < reach and math.abs(dz) < reach then
			local d = math.sqrt(dx * dx + dz * dz)
			local w = noise(x / 30 + 9.3, z / 30 + 4.1) * 10 + noise(x / 13 + 1.8, z / 13 + 7.6) * 4.5
			local t = 1 - smooth((d + w - (graveyardSpot.r - 18)) / 28)
			local nf = noise(x / 7.5 + 6.2, z / 7.5 + 2.8)
			local nm = noise(x / 15 + 8.4, z / 15 + 5.9)
			if t > 0.56 + nf * 0.42 then
				return if nm < -0.22 then M.Slate elseif nm > 0.22 then M.Ground else M.Mud
			elseif t > 0.18 + nf * 0.45 then
				return if nm > 0.1 then M.Ground else M.Mud
			end
		end
	end
	for _, l in riverSegs do
		if distSeg(x, z, l.ax, l.az, l.bx, l.bz) < 7.5 + n * 2.2 then
			return if n > 0.1 then M.Ground else M.Sand -- sand and gravel
		end
	end
	-- Quarry: dark bedrock floor, pale mineral-banded terraces, and a soft dusty spoil apron past the rim
	local q = quarry
	if q then
		local dx, dz = x - q.x, z - q.z
		local reach = q.r + 22
		if math.abs(dx) < reach and math.abs(dz) < reach then
			local d = math.sqrt(dx * dx + dz * dz)
			local dq = d + noise(x / 31 + q.x, z / 31 + q.z) * 2.2
			local nf = noise(x / 7.5 + 5.1, z / 7.5 + 9.3)
			local nm = noise(x / 16 + 2.2, z / 16 + 4.8)
			local floorR = q.r - 4 * q.rw - 3 * q.tw + 3
			if dq + nf * 3.5 < floorR then
				return if nm > 0.15 then M.Slate else M.Rock
			elseif dq + nf * 3 < q.r - 1 then
				return if nm > 0.22 then M.Limestone elseif nm < -0.15 then M.Cobblestone else M.Sandstone
			else
				local t = 1 - smooth((dq + nm * 5 - (q.r - 2)) / 18)
				if t > 0.24 + nf * 0.48 then
					return if nm > 0.1 then M.Cobblestone else M.Ground
				end
			end
		end
	end
	-- Signal mesa (relay mast): gravelly cobble plateau fading softly onto the ramp
	local m = mesa
	if m then
		local dx, dz = x - m.x, z - m.z
		if dx * dx + dz * dz < m.reach2 then
			local d = math.sqrt(dx * dx + dz * dz)
			local dm = d + noise(x / 37 + m.x, z / 37 + m.z) * 2.4
			local nf = noise(x / 7 + 7.7, z / 7 + 1.5)
			local nm = noise(x / 14 + 4.2, z / 14 + 8.6)
			local tTop = 1 - smooth((dm + nm * 3 - (m.rt - 5)) / 10)
			if tTop > 0.28 + nf * 0.45 then
				return if nm > 0.28 then M.Sandstone elseif nm < -0.28 then M.Ground else M.Cobblestone
			end
			local u = dx * m.dx + dz * m.dz
			if u > m.rt - 8 and u < m.rampEnd + 6 then
				local av = math.abs(-dx * m.dz + dz * m.dx)
				if av < 14 then
					local tRamp = 1 - smooth((av + nm * 3 - 5) / 9)
					local tEnd = 1 - smooth((u - (m.rampEnd - 8)) / 14)
					if tRamp * tEnd > 0.28 + nf * 0.45 then
						return if nm > 0.15 then M.Ground else M.Cobblestone
					end
				end
			end
		end
	end
	return nil
end

-- Ground painted by the layout: salt pan, roads, drag lines, scorched debris, the crash bowl, riverbed floor, quarry floor
-- and mesa top. nil = no overlay here (the slope / height rules below pick the material).
local function overlayMat(x: number, z: number, slope: number): Enum.Material?
	if biomeName == "desert" then
		return desertOverlayMat(x, z, slope)
	end
	local n = noise(x / 14 + 3.1, z / 14 + 8.7)
	if pan then
		local dx, dz = x - pan.x, z - pan.z
		local lim = pan.r + n * 5
		if dx * dx + dz * dz < lim * lim then
			return if biomeName == "crystal" then M.Snow else M.Salt
		end
	end
	if slope > 0.6 then
		return nil
	end
	for _, s in strips do
		if distSeg(x, z, s.ax, s.az, s.bx, s.bz) < s.half + n * 0.7 then
			if s.alt and noise(x / 9 + 1.3, z / 9 + 4.1) > 0.1 then
				return s.alt
			end
			return s.mat
		end
	end
	if crashBowl then
		local dx, dz = x - crashBowl.x, z - crashBowl.z
		local lim = crashBowl.r + n * 5
		if dx * dx + dz * dz < lim * lim then
			return if n > 0.25 then M.Slate else M.Basalt
		end
	end
	if spilledSpot then
		local dx, dz = x - spilledSpot.x, z - spilledSpot.z
		local lim = spilledSpot.r + n * 3
		if dx * dx + dz * dz < lim * lim then
			return M.Basalt
		end
	end
	for _, l in riverSegs do
		if distSeg(x, z, l.ax, l.az, l.bx, l.bz) < 7.5 + n * 1.5 then
			return if n > 0.1 then M.Ground else M.Sand -- sand and gravel
		end
	end
	local q = quarry
	if q then
		local dx, dz = x - q.x, z - q.z
		local d = math.sqrt(dx * dx + dz * dz)
		if d < q.r then
			return if d < q.r - 4 * q.rw - 3 * q.tw + 3 then M.Rock else M.Sandstone
		end
	end
	local m = mesa
	if m then
		local dx, dz = x - m.x, z - m.z
		if dx * dx + dz * dz < m.rt * m.rt then
			return M.Sandstone
		end
	end
	return nil
end

local function pickMat(x: number, z: number, h: number, slope: number): Enum.Material
	local ov = overlayMat(x, z, slope)
	if ov then
		return ov
	end
	local n = noise(x / 60 + 5.5, z / 60 + 1.5)
	local high = h > 62
	if biomeName == "ash" then
		if craterBowl(x, z) > 0.55 then
			return M.Basalt -- scorched bowl; the glow comes from small CrackedLava patches (lavaPatch), not flat discs
		end
		if high or slope > 0.95 then
			return M.Basalt
		elseif slope > 0.5 then
			return strata(h, M.Slate, M.Basalt)
		elseif slope > 0.3 then
			return M.Rock
		end
		if n > 0.2 then
			return M.Ground
		elseif n < -0.25 then
			return M.Basalt
		end
		return M.Sand
	elseif biomeName == "swamp" then
		if high or slope > 0.95 then
			return M.Rock
		elseif slope > 0.5 then
			return strata(h, M.Slate, M.Rock)
		elseif slope > 0.3 then
			return M.Slate
		end
		if h < 11 and n < 0.1 then
			return M.Mud
		elseif n > 0.35 then
			return M.Ground
		end
		return M.Grass
	elseif biomeName == "ice" then
		if high or slope > 0.95 then
			return M.Rock
		elseif slope > 0.5 then
			return strata(h, M.Glacier, M.Slate)
		elseif slope > 0.3 then
			return M.Glacier
		end
		if n < -0.3 then
			return M.Ground
		elseif n > 0.35 then
			return M.Glacier
		end
		return M.Snow
	elseif biomeName == "crystal" then
		if high or slope > 0.95 then
			return M.Slate
		elseif slope > 0.5 then
			return strata(h, M.Limestone, M.Slate)
		elseif slope > 0.3 then
			return M.Limestone
		end
		if n < -0.3 then
			return M.Ground
		elseif n > 0.4 then
			return M.Glacier -- glassy lavender patches
		end
		return M.Salt
	end
	-- desert: broad, clean value bands (smooth dunes, sandstone ridges, dark rock cliffs; zero patchy grass noise)
	if high or slope > 0.95 then
		return if n > 0.25 then M.Basalt else M.Rock
	elseif slope > 0.5 then
		return strata(h, M.Sandstone, M.Rock)
	elseif slope > 0.3 then
		return M.Sandstone
	end
	local broad = noise(x / 95 + 2.4, z / 95 + 6.8)
	if broad > 0.22 then
		return M.Ground
	elseif broad < -0.26 then
		return M.Sandstone
	end
	return M.Sand
end

local function writeChunk(x0: number, z0: number, n: number)
	local terrain: Terrain = Workspace.Terrain
	local H = {}
	local maxH = 0
	for i = 0, n + 1 do
		local row = {}
		for k = 0, n + 1 do
			local h = heightAt(x0 + (i - 0.5) * VOX, z0 + (k - 0.5) * VOX)
			row[k] = h
			if h > maxH then
				maxH = h
			end
		end
		H[i] = row
	end
	local ny = math.min((TOP - BOTTOM) // VOX, math.ceil((maxH - BOTTOM) / VOX) + 1)
	local mats, occ = {}, {}
	for i = 1, n do
		local mi, oi = {}, {}
		for j = 1, ny do
			mi[j] = table.create(n, Enum.Material.Air)
			oi[j] = table.create(n, 0)
		end
		for k = 1, n do
			local h = H[i][k]
			local slope = math.max(math.abs(H[i + 1][k] - H[i - 1][k]), math.abs(H[i][k + 1] - H[i][k - 1])) / (2 * VOX)
			local surf = pickMat(x0 + (i - 0.5) * VOX, z0 + (k - 0.5) * VOX, h, slope)
			for j = 1, ny do
				local y0 = BOTTOM + (j - 1) * VOX
				local o = math.clamp((h - y0) / VOX, 0, 1)
				if o <= 0 then
					break
				end
				oi[j][k] = o
				mi[j][k] = if y0 < h - 10 then Enum.Material.Rock else surf
			end
		end
		mats[i], occ[i] = mi, oi
	end
	local region = Region3.new(Vector3.new(x0, BOTTOM, z0), Vector3.new(x0 + n * VOX, BOTTOM + ny * VOX, z0 + n * VOX))
	terrain:WriteVoxels(region, VOX, mats, occ)
end

-- ---------------------------------------------------------------- part helpers
local partCount = 0
local opsSinceYield = 0
local rng = Random.new(1337)
local lightCount = 0
local blinkers: { { any } } = {} -- { PointLight, lamp part } pairs of the signal masts (one server loop toggles them)

local function maybeYield()
	opsSinceYield += 1
	if opsSinceYield >= 40 then
		opsSinceYield = 0
		task.wait()
	end
end

local function part(parent: Instance, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat or Enum.Material.SmoothPlastic
	p.CastShadow = size.Magnitude > 16
	if opts then
		for k, v in opts do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	partCount += 1
	return p
end

local function decor(parent: Instance, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local o: { [string]: any } = { CanCollide = false, CanQuery = false, CanTouch = false }
	if opts then
		for k, v in opts do
			o[k] = v
		end
	end
	return part(parent, size, cf, color, mat, o)
end

-- Rounded blob: a Ball part, stretched into an ellipsoid when `size` is not uniform. Use a non-uniform size for dressing
-- only; anything solid takes a uniform size (a Ball collides as a sphere, so a stretched one would not match what you see).
local function blob(parent: Instance, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?, collide: boolean?): Part
	return part(parent, size, cf, color, mat or Enum.Material.Slate, { Shape = Enum.PartType.Ball, CanCollide = collide == true })
end

local function cyl(parent: Instance, diameter: number, length: number, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	-- vertical cylinder at cf (Cylinder shape has its axis on X, so rotate it upright)
	local p = part(parent, Vector3.new(length, diameter, diameter), cf * CFrame.Angles(0, 0, math.pi / 2), color, mat, opts)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- strut between two points
local function beam(parent: Instance, a: Vector3, b: Vector3, thick: number, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local len = (b - a).Magnitude
	return part(parent, Vector3.new(thick, thick, len), CFrame.lookAt((a + b) / 2, b), color, mat, opts)
end

-- cylinder strut between two points (Cylinder shape has its axis on X; keep a, b off the vertical)
local function pipeSeg(parent: Instance, a: Vector3, b: Vector3, d: number, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local len = math.max((b - a).Magnitude, 0.05)
	local p = part(parent, Vector3.new(len, d, d), CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.pi / 2, 0), color, mat, opts)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- option sets for pure dressing (no collision, no raycast hits)
local NOCOL = { CanCollide = false, CanQuery = false, CanTouch = false }
local NOCOL_NS = { CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false }

local function pointLight(p: BasePart, color: Color3, range: number, brightness: number): PointLight?
	if lightCount >= 46 then
		return nil
	end
	lightCount += 1
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = p
	return l
end

local function smokeEmitter(host: BasePart, color: Color3, size: number, rate: number, life: number?)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
	pe.Rate = rate
	pe.Lifetime = NumberRange.new((life or 11) * 0.8, (life or 11) * 1.2)
	pe.Speed = NumberRange.new(9, 15)
	pe.SpreadAngle = Vector2.new(7, 7)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.5), NumberSequenceKeypoint.new(1, size * 2.4) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(0.6, 0.72), NumberSequenceKeypoint.new(1, 1) })
	pe.Color = ColorSequence.new(color)
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-12, 12)
	pe.Acceleration = Vector3.new(5, 0, 3)
	pe.LightInfluence = 0.7
	pe.Parent = host
end

local function fireEmitter(host: BasePart, size: number, rate: number)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/fire_main.dds"
	pe.Rate = rate
	pe.Lifetime = NumberRange.new(1.4, 2.4)
	pe.Speed = NumberRange.new(6, 12)
	pe.SpreadAngle = Vector2.new(12, 12)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, size * 0.3) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	pe.Color = ColorSequence.new(RGB(255, 190, 90), RGB(255, 80, 30))
	pe.LightEmission = 0.8
	pe.Parent = host
end

-- invisible emitter host
local function emitterHost(parent: Instance, pos: Vector3): Part
	return decor(parent, Vector3.one, CFrame.new(pos), Color3.new(), Enum.Material.SmoothPlastic, { Transparency = 1, CastShadow = false })
end

-- ---------------------------------------------------------------- ground + mesh placement
local groundY: (number, number) -> number
local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include

local function onGround(x: number, z: number, dy: number?): Vector3
	return Vector3.new(x, groundY(x, z) + (dy or 0), z)
end

local function surfaceAt(x: number, z: number): (Vector3, Vector3)
	local r = Workspace:Raycast(Vector3.new(x, TOP + 90, z), Vector3.new(0, -(TOP + 190), 0), terrainParams)
	if r then
		return r.Position, r.Normal
	end
	return Vector3.new(x, heightAt(x, z), z), Vector3.yAxis
end

-- lowest ground height around a footprint (+ the normal at the centre): things sit on the low side, never float
local function lowestGround(x: number, z: number, r: number): (number, Vector3)
	local pos, normal = surfaceAt(x, z)
	local low = pos.Y
	for _, o in { { r, 0 }, { -r, 0 }, { 0, r }, { 0, -r } } do
		low = math.min(low, (surfaceAt(x + o[1], z + o[2])).Y)
	end
	return low, normal
end

local function jitter(c: Color3, amt: number): Color3
	local k = 1 + rng:NextNumber(-amt, amt)
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end

local function rockTint(): Color3
	return jitter(B.rocks[rng:NextInteger(1, #B.rocks)], 0.1)
end

type PlaceOpts = {
	scale: number?, yaw: number?, sink: number?, align: number?, collide: boolean?,
	tint: Color3?, material: Enum.Material?, paint: ((BasePart) -> ())?, y: number?, fixedPos: Vector3?, fixedUp: Vector3?,
	maxSlope: number?, -- degrees; steeper spots are skipped (default 35)
}

-- Clone an env mesh, scale it, drop it on the terrain aligned to the surface normal (blend `align`), sunk into the ground.
-- The terrain is probed at the centre and the 4 footprint corners: the mesh sits on the LOWEST hit (never floats on a
-- slope or cliff top) and spots steeper than maxSlope are skipped. Returns (model, skipped): when `skipped` is true the
-- spot was too steep and the caller must NOT fall back to a part prop there.
local function placeMesh(parent: Instance, key: string, x: number, z: number, o: PlaceOpts): (Model?, boolean?)
	local size = Assets.size(key)
	local scale = o.scale or 1
	local yaw = o.yaw or rng:NextNumber(0, TAU)
	local back = Vector3.new(math.sin(yaw), 0, math.cos(yaw))
	local pos, normal = surfaceAt(x, z)
	do
		local hx = (if size then size.X else 6) * scale * 0.4
		local hz = (if size then size.Z else 6) * scale * 0.4
		local side = Vector3.new(back.Z, 0, -back.X)
		local lowY, highY = pos.Y, pos.Y
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local cx, cz = x + side.X * sx * hx + back.X * sz * hz, z + side.Z * sx * hx + back.Z * sz * hz
				local cp = surfaceAt(cx, cz)
				lowY = math.min(lowY, cp.Y)
				highY = math.max(highY, cp.Y)
			end
		end
		local maxSlope = math.rad(o.maxSlope or 35)
		if normal.Y < math.cos(maxSlope) or (highY - lowY) > math.tan(maxSlope) * 2 * math.max(hx, hz, 0.5) then
			return nil, true
		end
		pos = Vector3.new(pos.X, lowY, pos.Z)
	end
	local m = Assets.get(key, { anchored = true })
	if not m then
		return nil
	end
	if scale ~= 1 then
		m:ScaleTo(scale)
	end
	if o.y then
		pos = Vector3.new(pos.X, o.y, pos.Z)
	end
	local up = normal:Lerp(Vector3.yAxis, 1 - (o.align or 0.7))
	if up.Magnitude < 0.01 then
		up = Vector3.yAxis
	end
	up = up.Unit
	local right = up:Cross(back)
	if right.Magnitude < 0.01 then
		right = Vector3.xAxis
	end
	right = right.Unit
	back = right:Cross(up)
	local height = if size then size.Y * scale else 5
	local sink = o.sink or rng:NextNumber(0.1, 0.2)
	m:PivotTo(CFrame.fromMatrix(pos, right, up, back) * CFrame.new(0, -height * sink, 0))
	for _, p in m:GetChildren() do
		if p:IsA("BasePart") then
			p.CanCollide = o.collide == true -- CollisionFidelity can't be set at runtime (plugin-only)
			if o.tint then
				p.Color = o.tint
			end
			if o.material then
				p.Material = o.material
			end
			if o.paint then
				o.paint(p)
			end
			partCount += 1
		end
	end
	m.Parent = parent
	maybeYield()
	return m
end

-- Part fallback rock: two overlapping round boulders (uniform balls, so what you see is what you bump into)
local function fallbackRock(parent: Instance, x: number, z: number, s: number)
	local w = rng:NextNumber(5, 9) * s
	local col = rockTint()
	local low = lowestGround(x, z, w * 0.4)
	local a = rng:NextNumber(0, TAU)
	local b1 = blob(parent, Vector3.one * w, CFrame.new(x, low + w * (if biomeName == "desert" then 0.12 else 0.18), z), col, B.rockMat, true) -- sunk: the centre sits under the crest
	local b2 = blob(parent, Vector3.one * w * 0.62, CFrame.new(x + math.cos(a) * w * 0.5, low + w * (if biomeName == "desert" then 0.0 else 0.05), z + math.sin(a) * w * 0.5), jitter(col, 0.06), B.rockMat, true)
	if biomeName == "desert" then
		b1:SetAttribute("KeepMat", true)
		b2:SetAttribute("KeepMat", true)
	end
	maybeYield()
end

-- Rounded stone stack: stepped, tapering drums with a ball on top, leaning a little (tall, no sharp edges). Parts: 3-4.
local function stoneStack(parent: Instance, x: number, z: number, h: number, dia: number, col: Color3, collide: boolean, baseY: number?)
	local lean = CFrame.Angles(math.rad(rng:NextNumber(-6, 6)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-6, 6)))
	local gy = baseY or groundY(x, z)
	local base = CFrame.new(x, gy - dia * 0.3, z) * lean
	local y = 0
	local steps = if baseY then { { 1, 0.62 }, { 0.66, 0.38 } } else { { 1, 0.42 }, { 0.78, 0.34 }, { 0.56, 0.24 } } -- far silhouettes: fewer parts
	for i, st in steps do
		local seg = h * st[2]
		local d = dia * st[1]
		local c = cyl(parent, d, seg + dia * 0.3, base * CFrame.new(0, y + seg / 2, 0), jitter(col, 0.06), B.rockMat, { CanCollide = collide, CastShadow = collide })
		c.Name = "Stone"
		y += seg
		if i == #steps then
			blob(parent, Vector3.one * d, base * CFrame.new(0, y + d * 0.1, 0), col, B.rockMat, collide).CastShadow = collide
		end
	end
end

local OLD_ROCK_KEYS = { "env_rock_a", "env_rock_b", "env_rock_c" }
-- desert (Dustbowl Ridge): the rounded sandstone kit from art/blender/env_desert.py; tinted per biome like the old rocks
-- but they keep the rough rock material (KeepMat) so they sit with the dark, gritty ground
local DESERT_ROCK_KEYS = { "desert_boulder_a", "desert_boulder_b", "desert_boulder_a" }
local DESERT_SKYLINE_KEYS = { "desert_butte", "desert_boulder_a", "desert_boulder_b", "desert_cliff" }
local DESERT_FALLBACK_KEYS = { "desert_boulder_a", "desert_boulder_b", "desert_cliff" }
local ROCK_KEYS = OLD_ROCK_KEYS -- set per biome in MapBuilder.build

local SPIRE_SHADE = 0.6
-- desert spires are flat-topped sandstone buttes (env_desert.py) instead of pointed crags: about this much bigger than
-- the crag scale to stand as tall
local BUTTE_SCALE = 3.4

local function spireShade(c: Color3): Color3
	local k = if biomeName == "desert" then 0.74 else SPIRE_SHADE
	return Color3.new(c.R * k, c.G * k, c.B * k)
end

local function keepMat(p: BasePart)
	p:SetAttribute("KeepMat", true) -- skip the end-of-build flat SmoothPlastic pass
end

-- Part fallback needle: a rounded stone stack (desert: a small cluster of desert rock meshes, else rounded boulders)
local function fallbackSpire(parent: Instance, x: number, z: number, s: number, col: Color3?)
	if biomeName == "desert" then
		local baseCol = col or rockTint()
		local hMain = 36 * s
		local n = rng:NextInteger(2, 3)
		local fan = rng:NextNumber(0, TAU)
		local placed = 0
		local anySkipped = false
		local cliffUsed = false
		for i = 1, n do
			local k = DESERT_FALLBACK_KEYS[rng:NextInteger(1, #DESERT_FALLBACK_KEYS)]
			if k == "desert_cliff" then
				if cliffUsed then
					k = DESERT_FALLBACK_KEYS[rng:NextInteger(1, 2)]
				else
					cliffUsed = true
				end
			end
			local a = fan + (if n > 1 then (i - 1) / (n - 1) * TAU else 0) + rng:NextNumber(-0.45, 0.45)
			local off = if i == 1 then 0 else rng:NextNumber(0.2, 0.4) * hMain
			local targetH = hMain * (if i == 1 then rng:NextNumber(0.7, 0.95) else rng:NextNumber(0.4, 0.65))
			local sz = Assets.size(k)
			if sz then
				local m, skipped = placeMesh(parent, k, x + math.cos(a) * off, z + math.sin(a) * off, {
					scale = targetH / sz.Y,
					tint = spireShade(jitter(baseCol, 0.06)),
					material = B.rockMat,
					paint = keepMat,
					collide = true,
					align = 0.35,
					sink = rng:NextNumber(0.12, 0.2),
					maxSlope = 55,
				})
				if m then
					placed += 1
				elseif skipped then
					anySkipped = true
				end
			end
		end
		if placed == 0 and not anySkipped then
			local shade = spireShade(baseCol)
			for i = 1, n do
				local a = fan + (if n > 1 then (i - 1) / (n - 1) * TAU else 0) + rng:NextNumber(-0.4, 0.4)
				local off = if i == 1 then 0 else rng:NextNumber(0.25, 0.45) * hMain
				local dia = hMain * (if i == 1 then rng:NextNumber(0.65, 0.85) else rng:NextNumber(0.38, 0.58))
				local bx, bz = x + math.cos(a) * off, z + math.sin(a) * off
				local low = lowestGround(bx, bz, dia * 0.4)
				local b = blob(parent, Vector3.one * dia, CFrame.new(bx, low + dia * 0.22, bz), jitter(shade, 0.06), B.rockMat, true)
				keepMat(b)
			end
		end
		maybeYield()
		return
	end
	stoneStack(parent, x, z, 40 * s, 12 * s, col or rockTint(), true)
	maybeYield()
end

local function rock(parent: Instance, x: number, z: number, s: number, collide: boolean?)
	local key = ROCK_KEYS[rng:NextInteger(1, 3)]
	-- solid from scale 0.55 up (~4 studs tall): above 0.55 a rock is a real obstacle, and rocks of scale 0.55-1 used to be
	-- walk-through even though they stand 4-7 studs tall and 7-12 wide
	local m, skipped = placeMesh(parent, key, x, z, {
		scale = s, tint = rockTint(), material = B.rockMat, collide = collide ~= false and s >= 0.55, align = 0.7,
		paint = if biomeName == "desert" then keepMat else nil,
	})
	if not m and not skipped then
		fallbackRock(parent, x, z, s * 0.9)
	end
end

-- Round rock clump: 3-5 stone stacks of different heights huddled together, a couple of loose boulders at the foot.
-- `baseY` plants the clump at a fixed height instead of on the terrain (far silhouettes). `collide`: the stacks are cover.
local function stoneClump(parent: Instance, x: number, z: number, s: number, tint: Color3?, baseY: number?, collide: boolean?)
	local col = tint or rockTint()
	local n = if baseY then 3 else rng:NextInteger(3, 5)
	local fan = rng:NextNumber(0, TAU)
	local hMain = 40 * s
	for i = 1, n do
		local a = fan + i / n * TAU + rng:NextNumber(-0.5, 0.5)
		local d = if i == 1 then 0 else rng:NextNumber(0.1, 0.2) * hMain
		local h = hMain * (if i == 1 then rng:NextNumber(0.8, 1.0) else rng:NextNumber(0.3, 0.65))
		stoneStack(parent, x + math.cos(a) * d, z + math.sin(a) * d, h, h * rng:NextNumber(0.3, 0.42), col, collide == true, baseY)
	end
	if not baseY then
		for _ = 1, 2 do
			local a = rng:NextNumber(0, TAU)
			local d = rng:NextNumber(0.1, 0.22) * hMain
			rock(parent, x + math.cos(a) * d, z + math.sin(a) * d, rng:NextNumber(0.5, 1.1), false)
		end
	end
	maybeYield()
end

-- NOTE: env_spire_a (Blender "hoodoo": stem + flat overhanging caprock) reads as a mushroom silhouette and is no longer
-- placed anywhere; spires are env_spire_b crags or heaps of big round boulders.
local function spire(parent: Instance, x: number, z: number, s: number, tint: Color3?, key: string?)
	if not key and rng:NextNumber() < 0.4 then
		-- a heap of big round boulders instead of a crag (variety; the rock meshes at 3-5x)
		for i = 1, 3 do
			local a = rng:NextNumber(0, TAU)
			local d = if i == 1 then 0 else rng:NextNumber(10, 22) * s
			rock(parent, x + math.cos(a) * d, z + math.sin(a) * d, (if i == 1 then rng:NextNumber(3.4, 4.6) else rng:NextNumber(1.8, 2.8)) * math.min(s, 1.6), true)
		end
		maybeYield()
		return
	end
	local k = key or "env_spire_b"
	local meshScale = s
	if not key and biomeName == "desert" then
		k = "desert_butte"
		meshScale = s * BUTTE_SCALE
	end
	-- the crag's big flat faces wash out to pale peach as SmoothPlastic (sky specular on huge planes, whatever the colour):
	-- keep the biome's rough rock material (exempt from the flat pass) and tint darker so it sits with the terrain cliffs
	local t = spireShade(tint or rockTint())
	-- spires are tall pointed landmarks that can stand on rim slopes: allow steeper ground (lowest-hit placement keeps them planted)
	local m, skipped = placeMesh(parent, k, x, z, { scale = meshScale, tint = t, material = B.rockMat, paint = keepMat, collide = true, align = 0.35, sink = rng:NextNumber(0.1, 0.16), maxSlope = 55 })
	if not m and not skipped then
		fallbackSpire(parent, x, z, s, tint)
	end
end

local crystalCount = 0

local function crystals(parent: Instance, x: number, z: number, s: number, color: Color3?, unlit: boolean?)
	if biomeName == "desert" then
		return
	end
	local c = color or B.crystal
	if s <= 4 then -- small clusters shrink; the giant landmark crystals keep their scale
		s *= rng:NextNumber(0.6, 1.0)
	end
	crystalCount += 1
	local lit = crystalCount % 3 == 1 and not unlit -- a small light on ~1 in 3 clusters
	local m, skipped = placeMesh(parent, "env_crystal_cluster", x, z, {
		scale = s, collide = false, tint = rockTint(), material = B.rockMat, align = 0.6,
		paint = function(p)
			if p:GetAttribute("Role") == "weak" then
				p.Color = c
				p.Material = Enum.Material.Neon
				p.Transparency = 0.15
				if lit then
					lit = false
					pointLight(p, c, 10, 0.8)
				end
			end
		end,
	})
	if not m and not skipped then
		local first = true
		for _ = 1, rng:NextInteger(3, 5) do
			local h = rng:NextNumber(3, 7) * s
			local p = onGround(x + rng:NextNumber(-3, 3), z + rng:NextNumber(-3, 3), h / 2 - 0.4)
			local cp = part(parent, Vector3.new(1.2, h, 1.2), CFrame.new(p) * CFrame.Angles(math.rad(rng:NextNumber(-20, 20)), math.rad(rng:NextNumber(0, 90)), math.rad(rng:NextNumber(-20, 20))), c, Enum.Material.Neon, { CanCollide = false, CastShadow = false, Transparency = 0.15 })
			if first and lit then
				first = false
				pointLight(cp, c, 10, 0.8)
			end
		end
		maybeYield()
	end
end

local function crateStack(parent: Instance, x: number, z: number, yaw: number)
	local n = rng:NextInteger(1, 3)
	local fallback = false
	for i = 1, n do
		local ox, oz = x + math.cos(yaw) * (i - 1) * 4.6, z - math.sin(yaw) * (i - 1) * 4.6
		local m, skipped = placeMesh(parent, "env_supply_crate", ox, oz, { scale = 1.25, yaw = yaw + rng:NextNumber(-0.2, 0.2), sink = 0.04, collide = true, align = 0.5 })
		if not m then
			fallback = not skipped and i == 1
			break
		end
	end
	if fallback then
		local sz = rng:NextNumber(3.4, 4.2)
		part(parent, Vector3.new(sz * 1.4, sz, sz), CFrame.new(onGround(x, z, sz / 2 - 0.2)) * CFrame.Angles(0, yaw, 0), RGB(96, 110, 70), Enum.Material.Metal)
	end
end

local function pebble(parent: Instance, x: number, z: number)
	if biomeName == "desert" then
		placeMesh(parent, DESERT_ROCK_KEYS[rng:NextInteger(1, #DESERT_ROCK_KEYS)], x, z, {
			scale = rng:NextNumber(0.16, 0.32),
			tint = rockTint(),
			material = B.rockMat,
			collide = false,
			sink = rng:NextNumber(0.32, 0.44),
			align = 0.9,
			maxSlope = 35,
			paint = function(p)
				keepMat(p)
				p.CanQuery = false
				p.CanTouch = false
				p.CastShadow = false
			end,
		})
		return
	end
	local m, skipped = placeMesh(parent, ROCK_KEYS[rng:NextInteger(1, 3)], x, z, { scale = rng:NextNumber(0.1, 0.3), tint = rockTint(), material = B.rockMat, collide = false, sink = 0.25, align = 0.9 })
	if not m and not skipped then
		local d = rng:NextNumber(0.8, 2)
		decor(parent, Vector3.new(d, d * 0.6, d * 0.9), CFrame.new(onGround(x, z, 0.1)) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0), rockTint(), B.rockMat, { CastShadow = false })
	end
end

-- Broken wall: a ragged line of round stone drums (varied heights, gaps, a ball cap on the tall ones) plus fallen rubble.
-- In the desert, uses sandstone rock meshes along the same line (with a rounded boulder fallback) instead of drums.
-- Never one big rectangle. Pieces taller than 3 studs collide (cover, fat enough that nobody slips through); the rest is
-- walk-through rubble.
local function ruinedWall(parent: Instance, x: number, z: number, yaw: number, len: number)
	local base = CFrame.new(x, 0, z) * CFrame.Angles(0, yaw, 0)
	local half = math.min(len, 14) / 2
	local cursor = -half
	if biomeName == "desert" then
		while cursor < half do
			local seg = rng:NextNumber(4.0, 5.4)
			if rng:NextNumber() > 0.16 then
				local h = ({ 3.8, 4.8, 5.8, 7.0 })[rng:NextInteger(1, 4)] * rng:NextNumber(0.9, 1.12)
				local wp = (base * CFrame.new(rng:NextNumber(-0.4, 0.4), 0, cursor + seg / 2)).Position
				local k = if h >= 5.6 and rng:NextNumber() < 0.35 then "desert_butte" else DESERT_ROCK_KEYS[rng:NextInteger(1, #DESERT_ROCK_KEYS)]
				local sz = Assets.size(k)
				local m, skipped = placeMesh(parent, k, wp.X, wp.Z, {
					scale = h / (if sz then sz.Y else 6.5),
					yaw = yaw + rng:NextNumber(-0.4, 0.4),
					tint = rockTint(),
					material = B.rockMat,
					paint = keepMat,
					collide = true,
					align = 0.7,
					sink = rng:NextNumber(0.14, 0.22),
					maxSlope = 45,
				})
				if not m and not skipped then
					local dia = math.clamp(h * 1.15, 3.6, 7.5)
					local gy = lowestGround(wp.X, wp.Z, dia * 0.4)
					local b = blob(parent, Vector3.one * dia, CFrame.new(wp.X, gy + dia * 0.18, wp.Z), rockTint(), B.rockMat, true)
					keepMat(b)
				end
			end
			cursor += seg
		end
		maybeYield()
		return
	else
		local col = B.wall[rng:NextInteger(1, #B.wall)]:Lerp(B.rocks[1], 0.4)
		while cursor < half do
			local seg = rng:NextNumber(2.6, 4.4)
			if rng:NextNumber() > 0.14 then
				local h = ({ 1.6, 2.6, 4, 5.5, 7.5 })[rng:NextInteger(1, 5)] * rng:NextNumber(0.8, 1.15)
				local dia = rng:NextNumber(2.4, 3.4)
				local wp = (base * CFrame.new(rng:NextNumber(-0.4, 0.4), 0, cursor + seg / 2)).Position
				local gy = lowestGround(wp.X, wp.Z, seg * 0.5) -- lowest under the drum: no end hovers on a slope
				local solid = h >= 3
				local tilt = CFrame.Angles(math.rad(rng:NextNumber(-4, 4)), 0, math.rad(rng:NextNumber(-5, 5)))
				local cf = CFrame.new(wp.X, gy + h / 2 - 0.8, wp.Z) * tilt
				cyl(parent, dia, h + 1.6, cf, jitter(col, 0.08), Enum.Material.Concrete, { CanCollide = solid })
				if h >= 3.6 then
					blob(parent, Vector3.one * dia * 0.96, cf * CFrame.new(0, h / 2 + 0.8 - dia * 0.2, 0), jitter(col, 0.06), Enum.Material.Concrete, solid)
				end
				if rng:NextNumber() < 0.45 then
					-- a shorter drum beside it: uneven crest instead of a straight top
					local h2 = h * rng:NextNumber(0.35, 0.7)
					local d2 = dia * rng:NextNumber(0.7, 0.9)
					cyl(parent, d2, h2 + 1, CFrame.new((cf * CFrame.new(dia * 0.9, 0, rng:NextNumber(-0.6, 0.6))).Position) * CFrame.new(0, h2 / 2 - h / 2 - 0.3, 0), jitter(col, 0.1), Enum.Material.Concrete, { CanCollide = false, CanQuery = false })
				end
			end
			cursor += seg
		end
	end
	for _ = 1, 2 do -- fallen chunks at the ends
		local e = (base * CFrame.new(rng:NextNumber(-1.5, 1.5), 0, (if rng:NextNumber() < 0.5 then -1 else 1) * (half + rng:NextNumber(0.5, 2.5)))).Position
		rock(parent, e.X, e.Z, rng:NextNumber(0.35, 0.7))
	end
	for _ = 1, 2 do -- spalled rubble along the foot, either side
		local e = (base * CFrame.new((if rng:NextNumber() < 0.5 then -1 else 1) * rng:NextNumber(1.4, 2.6), 0, rng:NextNumber(-half, half))).Position
		rock(parent, e.X, e.Z, rng:NextNumber(0.22, 0.4), false)
	end
	maybeYield()
end

-- cover piece: robot barricade (COG), hive mound (BROOD) or rocks
local function cover(parent: Instance, x: number, z: number, yaw: number, faction: string)
	if faction == "BROOD" then
		local m, skipped = placeMesh(parent, "env_hive_mound", x, z, { scale = rng:NextNumber(0.9, 1.5), yaw = yaw, sink = 0.08, collide = true, align = 0.6 })
		if m or skipped then
			return
		end
	elseif faction == "LUMEN" then
		-- Lumen: a boulder with a small crystal growth on it (unlit)
		rock(parent, x, z, rng:NextNumber(1.2, 1.9))
		crystals(parent, x + rng:NextNumber(-1.5, 1.5), z + rng:NextNumber(-1.5, 1.5), rng:NextNumber(0.5, 0.8), nil, true)
		return
	else
		local m, skipped = placeMesh(parent, "env_cog_barricade", x, z, { scale = rng:NextNumber(1, 1.3), yaw = yaw, sink = 0.06, collide = true, align = 0.5 })
		if m or skipped then
			return
		end
	end
	rock(parent, x, z, rng:NextNumber(1.2, 1.9))
end

local function plant(parent: Instance, x: number, z: number)
	local h = rng:NextNumber(3, 7)
	local glow = (biomeName == "swamp" and rng:NextNumber() < 0.3) or (biomeName == "ash" and rng:NextNumber() < 0.15)
	local stalkCol = B.plant[rng:NextInteger(1, #B.plant)]
	local base = onGround(x, z, -0.5)
	local tilt = CFrame.Angles(math.rad(rng:NextNumber(-14, 14)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-14, 14)))
	local cf = CFrame.new(base) * tilt
	local stalk = cyl(parent, 0.5, h, cf * CFrame.new(0, h / 2, 0), stalkCol, Enum.Material.Slate, { CanCollide = false, CanQuery = false })
	stalk.CastShadow = false
	if glow then
		local col = if biomeName == "ash" then RGB(255, 110, 50) else ({ RGB(150, 255, 120), RGB(170, 255, 110), RGB(130, 235, 110) })[rng:NextInteger(1, 3)]
		local r = rng:NextNumber(0.9, 1.7)
		local bulb = part(parent, Vector3.new(r, r, r), cf * CFrame.new(0, h + r * 0.3, 0), col, Enum.Material.Neon, { CanCollide = false, CanQuery = false, CastShadow = false })
		bulb.Shape = Enum.PartType.Ball
	else
		-- bare spikes: a second leaning stalk
		local h2 = h * 0.7
		local s2 = cyl(parent, 0.4, h2, cf * CFrame.Angles(0, 0, math.rad(rng:NextNumber(18, 32))) * CFrame.new(0, h2 / 2, 0), stalkCol, Enum.Material.Slate, { CanCollide = false, CanQuery = false })
		s2.CastShadow = false
	end
end


-- ---------------------------------------------------------------- placement tables
-- true when (x, z) is at least minDist from every site, and outside the keep-out radius of each place (the places'
-- own set pieces are built there, so no camps, rubble or props)
local function farFromSites(x: number, z: number, minDist: number): boolean
	for name, v in LAYOUT do
		local dx, dz = x - v.X, z - v.Y
		local lim = math.max(minDist, KEEPOUT[name] or 0)
		if dx * dx + dz * dz < lim * lim then
			return false
		end
	end
	return true
end

-- how much of a kind of dressing an area gets (0..1): rocks gather in the north, shrubs in the dune south, the east
-- salt country stays sparse
local function areaWeight(x: number, z: number, kind: string): number
	local north, south, east = region(x, z)
	if kind == "rock" then
		return math.clamp(0.4 + 0.7 * north - 0.2 * south - 0.35 * east, 0.12, 1)
	elseif kind == "shrub" then
		return math.clamp(0.35 + 0.65 * south - 0.5 * east - 0.1 * north, 0.1, 1)
	end
	return math.clamp(1 - 0.5 * east, 0.2, 1) -- rubble and the rest
end

local function randomSpot(minDist: number, margin: number?): (number, number)
	local lim = HALF - (margin or 35)
	for _ = 1, 40 do
		local x, z = rng:NextNumber(-lim, lim), rng:NextNumber(-lim, lim)
		if farFromSites(x, z, minDist) then
			return x, z
		end
	end
	return rng:NextNumber(-lim, lim), rng:NextNumber(-lim, lim)
end

-- random spot that avoids sites and combat lanes
local function wildSpot(minSite: number, laneW: number, maxExtent: number?): (number, number)
	local lim = maxExtent or 285
	local x, z = 0, 0
	for _ = 1, 40 do
		x, z = rng:NextNumber(-lim, lim), rng:NextNumber(-lim, lim)
		if farFromSites(x, z, minSite) and not inLane(x, z, laneW) then
			return x, z
		end
	end
	return x, z
end

-- ---------------------------------------------------------------- environmental storytelling
-- Battlefield wreckage, camps, industrial bits, nature clusters, hive growths and air. Everything here is walk-through
-- dressing (no collision) except rocks / barricades / crates, deterministic via `rng`, and kept off the combat lanes:
-- clusters sit on the lane EDGES (laneEdgeSpot) so the open ground between sites is never bare.

-- random wild spot that hugs the edge of a combat lane (outside 16 studs, inside ~52)
local function laneEdgeSpot(maxExtent: number?): (number, number)
	local x, z = 0, 0
	for _ = 1, 40 do
		x, z = wildSpot(32, 16, maxExtent or 250)
		if inLane(x, z, 52) then
			return x, z
		end
	end
	return x, z
end


-- Round talus skirt: `n` big half-sunk boulders (stretched balls) in a ring (rIn..rOut from `centre`), heights / widths
-- jittered, crests at ~h above the local ground. Hides the flat top and straight edges of a foundation block so a landmark
-- rises out of a heap of rounded rock instead of standing on a box. Far landmarks only: no collision.
local function rockSkirt(parent: Instance, centre: Vector3, rIn: number, rOut: number, h: number, n: number, col: Color3, mat: Enum.Material?)
	local len = rOut - rIn
	local a0 = rng:NextNumber(0, TAU)
	for i = 0, n - 1 do
		local a = a0 + i / n * TAU + rng:NextNumber(-0.12, 0.12)
		local rm = rIn + len * 0.5
		local x, z = centre.X + math.cos(a) * rm, centre.Z + math.sin(a) * rm
		local gy = math.min(groundY(x, z), centre.Y)
		local hh = h * rng:NextNumber(0.7, 1.15)
		if biomeName == "desert" then
			local k = DESERT_ROCK_KEYS[rng:NextInteger(1, #DESERT_ROCK_KEYS)]
			local sz = Assets.size(k)
			local m, skipped = placeMesh(parent, k, x, z, {
				scale = (hh * 1.2) / (if sz then sz.Y else 6.5),
				tint = jitter(col, 0.08),
				material = mat or B.rockMat,
				collide = false,
				align = 0.25,
				sink = rng:NextNumber(0.18, 0.28),
				y = gy,
				maxSlope = 80,
				paint = function(p)
					keepMat(p)
					p.CanQuery = false
					p.CanTouch = false
					p.CastShadow = true
				end,
			})
			if m or skipped then
				continue
			end
		end
		local wid = TAU * rm / n * rng:NextNumber(1.15, 1.45)
		local p = Vector3.new(x, gy + hh * 0.2, z) -- crest at gy + hh, the rest sunk
		local cf = CFrame.lookAt(p, Vector3.new(centre.X, p.Y, centre.Z))
		local b = blob(parent, Vector3.new(wid, hh * 1.6, len * rng:NextNumber(1.0, 1.2)), cf, jitter(col, 0.1), mat or B.rockMat, false)
		b.CastShadow = true
		if biomeName == "desert" then
			keepMat(b)
		end
	end
	maybeYield()
end

-- slow smoke plume (own speed, so wisps stay low and rim columns rise tall)
local function plume(host: BasePart, color: Color3, size: number, rate: number, life: number, speed: number)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
	pe.Rate = rate
	pe.Lifetime = NumberRange.new(life * 0.8, life * 1.2)
	pe.Speed = NumberRange.new(speed * 0.8, speed * 1.2)
	pe.SpreadAngle = Vector2.new(5, 5)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.5), NumberSequenceKeypoint.new(1, size * 2.2) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(0.6, 0.72), NumberSequenceKeypoint.new(1, 1) })
	pe.Color = ColorSequence.new(color)
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-8, 8)
	pe.Acceleration = Vector3.new(2.5, 0.5, 1.5)
	pe.LightInfluence = 0.8
	pe.Parent = host
end

local WRECK_KEYS: { [string]: { string } } = {
	COG = { "tinker", "tinker", "rivet", "rivet", "bulwark" },
	BROOD = { "skitter", "skitter", "spitter", "charger", "charger" },
}
local WRECK_BIG: { [string]: string } = { COG = "colossus", BROOD = "titan" }

-- Half-buried dead enemy: a clone of an enemy mesh rolled onto its side, sunk 30-50%, darkened to charcoal, no glowing
-- parts, some limbs missing. Pure decoration (anchored, no collision, no scripts). Returns the model, or nil when the
-- mesh is not loaded or the spot is too steep.
local function wreckHulk(parent: Instance, x: number, z: number, key: string, scaleMul: number?): Model?
	local size = Assets.size(key)
	if not size then
		return nil
	end
	local sc = (scaleMul or 1) * rng:NextNumber(0.95, 1.2)
	local low, normal = lowestGround(x, z, math.max(size.X, size.Z) * sc * 0.3)
	if normal.Y < 0.86 then
		return nil
	end
	local m = Assets.get(key, { anchored = true })
	if not m then
		return nil
	end
	m:ScaleTo(sc)
	local thick = size.X * sc -- vertical extent once it lies on its side
	local sink = rng:NextNumber(0.3, 0.5)
	local roll = math.rad(rng:NextNumber(72, 105)) * (if rng:NextNumber() < 0.5 then 1 else -1)
	local pitch = math.rad(rng:NextNumber(-22, 22))
	local center = Vector3.new(x, low + thick * (0.5 - sink), z)
	-- rotate about the bounding-box centre (the template pivot sits at the feet)
	m:PivotTo(CFrame.new(center) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0) * CFrame.Angles(pitch, 0, roll) * CFrame.new(0, -size.Y * sc * 0.5, 0))
	local dark = RGB(40, 38, 40)
	for _, p in m:GetChildren() do
		if p:IsA("BasePart") then
			local role = p:GetAttribute("Role")
			if role == "weak" or role == "glow" or (role == "limb" and rng:NextNumber() < 0.35) then
				p:Destroy()
			else
				p.Color = p.Color:Lerp(dark, 0.84 - rng:NextNumber(0, 0.14))
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
				partCount += 1
			end
		end
	end
	m.Parent = parent
	-- the hull parts have no collision (limbs and plates would catch on everything), so a big hulk used to be something you
	-- could run straight through: an invisible solid box about half its bounds stands in for it (not hit by bullets)
	local bbCF, bbSize = m:GetBoundingBox()
	local solid = part(parent, bbSize * 0.5, bbCF, dark, Enum.Material.SmoothPlastic, { Transparency = 1, CanQuery = false, CanTouch = false, CastShadow = false })
	solid.Name = "HulkSolid"
	maybeYield()
	return m
end

-- Crashed drop-pod husk: a capsule of stepped cylinders (off-white, orange stripe, scorched tail, blown hatch, two fins)
-- standing tilted in the ground. ~8 parts.
local function podHusk(parent: Instance, x: number, z: number)
	local low, normal = lowestGround(x, z, 3)
	if normal.Y < 0.88 then
		return
	end
	local lean = math.rad(rng:NextNumber(52, 74)) * (if rng:NextNumber() < 0.5 then 1 else -1)
	local base = CFrame.new(x, low + 0.8, z) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0) * CFrame.Angles(lean, 0, 0)
	local soot = RGB(30, 28, 30)
	local hull = RGB(222, 218, 206):Lerp(soot, rng:NextNumber(0.25, 0.42))
	local stripe = RGB(232, 112, 40):Lerp(soot, 0.25)
	cyl(parent, 5.2, 7.5, base, hull, Enum.Material.Metal, { CanQuery = false, CanTouch = false }) -- body (solid); the +Y end is the nose
	cyl(parent, 3.6, 2.6, base * CFrame.new(0, 4.9, 0), hull, Enum.Material.Metal, NOCOL)
	cyl(parent, 1.8, 1.6, base * CFrame.new(0, 6.7, 0), soot, Enum.Material.Slate, NOCOL_NS)
	cyl(parent, 5.35, 0.8, base * CFrame.new(0, 1.3, 0), stripe, Enum.Material.Metal, NOCOL_NS)
	cyl(parent, 5.4, 2.2, base * CFrame.new(0, -2.6, 0), soot, Enum.Material.Slate, NOCOL_NS)
	decor(parent, Vector3.new(0.25, 3.8, 3.0), base * CFrame.new(2.9, 0.4, 0) * CFrame.Angles(0, 0, math.rad(-38)), hull, Enum.Material.Metal) -- blown hatch
	for _, sx in { -1, 1 } do -- two stubby round fins
		blob(parent, Vector3.new(0.7, 2.6, 2.2), base * CFrame.new(sx * 2.8, -2.4, 0) * CFrame.Angles(0, 0, -sx * math.rad(22)), stripe, Enum.Material.Metal, false).CastShadow = false
	end
	maybeYield()
end

local DESERT_PAINTABLE = {
	M.Sand, M.Sandstone, M.Ground, M.Rock, M.Mud, M.Grass, M.Slate, M.Limestone, M.Cobblestone,
}

-- Soft desert terrain stain without FillCylinder ledges: replaces surface voxels in small irregular cells, fading out at the rim.
local function paintSoftPatch(x: number, z: number, r: number, coreMats: { Enum.Material }, edgeMats: { Enum.Material })
	local terrain = Workspace.Terrain
	local n = math.clamp(math.floor(r * 1.35), 6, 24)
	for i = 1, n do
		local a = rng:NextNumber(0, TAU)
		local frac = if i <= 2 then rng:NextNumber(0, 0.25) else math.sqrt(rng:NextNumber())
		local off = frac * r * rng:NextNumber(0.8, 1.15)
		local sx, sz = x + math.cos(a) * off, z + math.sin(a) * off
		local gy = groundY(sx, sz)
		local half = if frac < 0.55 then rng:NextNumber(2.2, 4.2) else rng:NextNumber(1.8, 3.0)
		local reg = Region3.new(Vector3.new(sx - half, gy - 5, sz - half), Vector3.new(sx + half, gy + 2, sz + half)):ExpandToGrid(4)
		local pool = if frac < 0.6 then coreMats else edgeMats
		local target = pool[rng:NextInteger(1, #pool)]
		for _, src in DESERT_PAINTABLE do
			if src ~= target then
				terrain:ReplaceMaterial(reg, 4, src, target)
			end
		end
	end
end

-- Ragged scorch painted into the terrain: overlapping blobs of darker biome material with jittered radii (never a flat disc).
local function scorchPatch(x: number, z: number, r: number, bugs: boolean)
	if biomeName == "desert" then
		local core = if bugs then { M.Basalt, M.Mud, M.Slate } else { M.Basalt, M.Slate, M.Mud }
		paintSoftPatch(x, z, r, core, { M.Slate, M.Mud, M.Ground })
		maybeYield()
		return
	end
	local terrain = Workspace.Terrain
	local mats = if bugs then { Enum.Material.Basalt, Enum.Material.Mud, Enum.Material.Basalt, Enum.Material.Slate } else { Enum.Material.Basalt, Enum.Material.Basalt, Enum.Material.Slate, Enum.Material.Mud }
	for i = 1, 9 do
		local a = rng:NextNumber(0, TAU)
		local off = if i == 1 then 0 else rng:NextNumber(r * 0.25, r * 0.8)
		local sx, sz = x + math.cos(a) * off, z + math.sin(a) * off
		local sr = if i == 1 then r * rng:NextNumber(0.45, 0.6) else r * rng:NextNumber(0.2, 0.42)
		terrain:FillCylinder(CFrame.new(sx, groundY(sx, sz) - 1.1, sz), 2.4, sr, mats[(i - 1) % #mats + 1])
	end
	maybeYield()
end

-- Shell crater: ragged scorched halo + a dent carved out of the terrain + thrown rubble and torn plates.
local function shellCrater(parent: Instance, x: number, z: number, r: number)
	local _, normal = surfaceAt(x, z)
	if normal.Y < 0.96 then -- gentle ground only: painted blobs on a slope would form ledges
		return
	end
	local terrain = Workspace.Terrain
	if biomeName == "desert" then
		paintSoftPatch(x, z, r * 1.45, { M.Basalt, M.Slate }, { M.Slate, M.Mud, M.Ground })
	else
		for i = 1, 4 do
			local a = rng:NextNumber(0, TAU)
			local off = if i == 1 then 0 else r * rng:NextNumber(0.5, 1.0)
			local sx, sz = x + math.cos(a) * off, z + math.sin(a) * off
			terrain:FillCylinder(CFrame.new(sx, groundY(sx, sz) - 1.1, sz), 2.4, r * rng:NextNumber(0.8, 1.15), Enum.Material.Basalt)
		end
	end
	terrain:FillBall(Vector3.new(x, groundY(x, z) + r * 0.35, z), r * 0.8, Enum.Material.Air)
	for _ = 1, rng:NextInteger(2, 3) do
		local a, rr = rng:NextNumber(0, TAU), r * rng:NextNumber(0.95, 1.5)
		rock(parent, x + math.cos(a) * rr, z + math.sin(a) * rr, rng:NextNumber(0.3, 0.7))
	end
	for _ = 1, 2 do
		local a, rr = rng:NextNumber(0, TAU), r * rng:NextNumber(0.7, 1.4)
		local p = onGround(x + math.cos(a) * rr, z + math.sin(a) * rr, 0.3)
		decor(parent, Vector3.new(rng:NextNumber(1.6, 3.2), 0.3, rng:NextNumber(1.2, 2.4)), CFrame.new(p) * CFrame.Angles(math.rad(rng:NextNumber(-35, 35)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-35, 35))), RGB(66, 64, 68), Enum.Material.DiamondPlate)
	end
	local a1 = rng:NextNumber(0, TAU)
	local s1 = onGround(x + math.cos(a1) * r * 1.2, z + math.sin(a1) * r * 1.2, 0.2)
	pipeSeg(parent, s1, s1 + Vector3.new(rng:NextNumber(-3, 3), rng:NextNumber(0.8, 2.2), rng:NextNumber(1.5, 3.5)), 0.35, RGB(70, 66, 66), Enum.Material.Metal, NOCOL_NS)
	maybeYield()
end

-- Scrap heap: tilted plates, gear discs, a strut and a rusted fin piled together. 8 parts.
local function scrapHeap(parent: Instance, x: number, z: number)
	local low, normal = lowestGround(x, z, 3)
	if normal.Y < 0.84 then
		return
	end
	local steel = RGB(88, 92, 100)
	local rust = RGB(140, 84, 60)
	for _ = 1, rng:NextInteger(3, 4) do
		local p = Vector3.new(x + rng:NextNumber(-2.2, 2.2), low + rng:NextNumber(0.4, 1.9), z + rng:NextNumber(-2.2, 2.2))
		decor(parent, Vector3.new(rng:NextNumber(2.5, 5), 0.4, rng:NextNumber(2, 4)), CFrame.new(p) * CFrame.Angles(math.rad(rng:NextNumber(-50, 50)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-50, 50))), jitter(steel, 0.15), Enum.Material.DiamondPlate)
	end
	for _ = 1, 2 do
		local p = Vector3.new(x + rng:NextNumber(-2.4, 2.4), low + rng:NextNumber(0.9, 1.7), z + rng:NextNumber(-2.4, 2.4))
		cyl(parent, rng:NextNumber(3, 5.5), 0.7, CFrame.new(p) * CFrame.Angles(math.rad(rng:NextNumber(55, 100)), rng:NextNumber(0, TAU), 0), rust, Enum.Material.CorrodedMetal, NOCOL_NS)
	end
	local a = rng:NextNumber(0, TAU)
	local s0 = Vector3.new(x + math.cos(a) * 2.8, low + 0.3, z + math.sin(a) * 2.8)
	pipeSeg(parent, s0, Vector3.new(x - math.cos(a) * 1.5, low + rng:NextNumber(1.8, 3), z - math.sin(a) * 1.5), 0.7, steel, Enum.Material.Metal, NOCOL)
	blob(parent, Vector3.new(0.9, 2.2, 3.2), CFrame.new(x, low + 1.1, z) * CFrame.Angles(math.rad(rng:NextNumber(-25, 25)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-30, 30))), rust, Enum.Material.CorrodedMetal, false).CanQuery = false
	maybeYield()
end

-- Pipeline on short trestles, following the ground segment by segment (cylinders, flanges at the joints, A-frame legs).
-- Walk-through; stops where the ground gets steep or near a site. Returns true when built.
local function pipeline(parent: Instance, x: number, z: number, yaw: number, segs: number): boolean
	local dir = Vector3.new(math.sin(yaw), 0, math.cos(yaw))
	local side = Vector3.new(dir.Z, 0, -dir.X)
	local pipeCol = RGB(128, 118, 106):Lerp(B.rocks[1], 0.15)
	local dark = RGB(48, 48, 54)
	local pts: { Vector3 } = {}
	local grounds: { number } = {}
	for i = 0, segs do
		local px, pz = x + dir.X * 9 * i, z + dir.Z * 9 * i
		if not farFromSites(px, pz, 30) or math.max(math.abs(px), math.abs(pz)) > 238 then
			break
		end
		local g = groundY(px, pz)
		if i > 0 and math.abs(g - grounds[i]) > 3.4 then
			break
		end
		grounds[i + 1] = g
		pts[i + 1] = Vector3.new(px, g + 2.7, pz)
	end
	if #pts < 3 then
		return false
	end
	for i = 1, #pts do
		local p, g = pts[i], grounds[i]
		for _, s in { -1, 1 } do
			pipeSeg(parent, p - Vector3.new(0, 0.9, 0) + side * (0.45 * s), Vector3.new(p.X, g - 0.4, p.Z) + side * (1.9 * s), 0.45, dark, Enum.Material.Metal, NOCOL)
		end
		local u = (pts[math.min(i + 1, #pts)] - pts[math.max(i - 1, 1)]).Unit
		pipeSeg(parent, p - u * 0.35, p + u * 0.35, 3.0, dark, Enum.Material.Metal, NOCOL)
		if i < #pts then
			pipeSeg(parent, p, pts[i + 1], 2.2, pipeCol, Enum.Material.CorrodedMetal, NOCOL)
		end
	end
	local mid = pts[(#pts + 1) // 2]
	cyl(parent, 0.3, 1.6, CFrame.new(mid + Vector3.new(0, 2.3, 0)), dark, Enum.Material.Metal, NOCOL_NS)
	cyl(parent, 1.7, 0.25, CFrame.new(mid + Vector3.new(0, 3.2, 0)), RGB(190, 60, 40), Enum.Material.Metal, NOCOL_NS)
	maybeYield()
	return true
end

-- Two robot pylons with two drooping cable lines between them (thin dark cylinders, parabola sag).
local function cableRun(parent: Instance, x: number, z: number, yaw: number): boolean
	local span = rng:NextNumber(30, 38)
	local dir = Vector3.new(math.sin(yaw), 0, math.cos(yaw))
	local psize = Assets.size("env_cog_pylon")
	if not psize then
		return false
	end
	local ends: { Vector3 } = {}
	for k = 0, 1 do
		local m = placeMesh(parent, "env_cog_pylon", x + dir.X * span * (k - 0.5), z + dir.Z * span * (k - 0.5), { scale = 1.3, sink = 0.04, collide = true, align = 0.4, yaw = yaw })
		if not m then
			return false
		end
		ends[k + 1] = (m:GetPivot() * CFrame.new(0, psize.Y * 1.3 * 0.86, 0)).Position
	end
	local perp = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
	local cableCol = RGB(26, 26, 30)
	for c = 0, 1 do
		local off = perp * (c * 1.1 - 0.55) - Vector3.new(0, c * 0.9, 0)
		local a, b = ends[1] + off, ends[2] + off
		local sag = 2.2 + span * 0.07
		local prev = a
		for k = 1, 5 do
			local t = k / 5
			local p = a:Lerp(b, t) - Vector3.new(0, sag * 4 * t * (1 - t), 0)
			pipeSeg(parent, prev, p, 0.3, cableCol, Enum.Material.Plastic, NOCOL_NS)
			prev = p
		end
	end
	maybeYield()
	return true
end

-- Signal mast: thin pole, guy wires, cross-arm, a small dish and a tiny blinking red lamp (a light, not a neon slab).
local function signalMast(parent: Instance, x: number, z: number)
	local low, normal = lowestGround(x, z, 1.5)
	if normal.Y < 0.9 then
		return
	end
	local steel = RGB(84, 88, 96)
	local dark = RGB(40, 40, 46)
	local h = rng:NextNumber(13, 18)
	local base = Vector3.new(x, low, z)
	cyl(parent, 0.7, h, CFrame.new(base + Vector3.new(0, h / 2 - 0.3, 0)), steel, Enum.Material.Metal, NOCOL)
	local a0 = rng:NextNumber(0, TAU)
	for k = 0, 2 do
		local a = a0 + k / 3 * TAU
		pipeSeg(parent, base + Vector3.new(0, h * 0.78, 0), base + Vector3.new(math.cos(a) * 7, 0.2, math.sin(a) * 7), 0.14, dark, Enum.Material.Metal, NOCOL_NS)
	end
	pipeSeg(parent, base + Vector3.new(-2.2, h * 0.62, 0.3), base + Vector3.new(2.2, h * 0.62, -0.3), 0.3, steel, Enum.Material.Metal, NOCOL_NS)
	cyl(parent, 2.6, 0.25, CFrame.new(base + Vector3.new(0, h * 0.5, 0)) * CFrame.Angles(math.rad(65), a0, 0), RGB(150, 154, 160), Enum.Material.Metal, NOCOL_NS)
	local lamp = decor(parent, Vector3.new(0.7, 0.7, 0.7), CFrame.new(base + Vector3.new(0, h + 0.2, 0)), RGB(255, 50, 40), Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
	local l = pointLight(lamp, RGB(255, 50, 40), 22, 1.6)
	if l then
		table.insert(blinkers, { l, lamp })
	end
	maybeYield()
end

-- Fuel tank: horizontal on two splayed trestles with domed ends, or upright with a domed top and a ladder.
local function fuelTank(parent: Instance, x: number, z: number, yaw: number)
	local low, normal = lowestGround(x, z, 4)
	if normal.Y < 0.9 then
		return
	end
	local paint = ({ RGB(150, 146, 138), RGB(120, 84, 64), RGB(98, 104, 110) })[rng:NextInteger(1, 3)]:Lerp(B.rocks[1], 0.12)
	local band = RGB(40, 40, 44)
	if rng:NextNumber() < 0.4 then
		local d, h = rng:NextNumber(5, 7), rng:NextNumber(7, 10)
		cyl(parent, d, h, CFrame.new(x, low + h / 2 - 0.3, z), paint, Enum.Material.CorrodedMetal, { CanQuery = false, CanTouch = false }) -- solid body
		decor(parent, Vector3.new(d, d * 0.6, d), CFrame.new(x, low + h - 0.3, z), paint, Enum.Material.CorrodedMetal, { Shape = Enum.PartType.Ball })
		cyl(parent, d + 0.2, 0.5, CFrame.new(x, low + h * 0.55, z), band, Enum.Material.Metal, NOCOL_NS)
		pipeSeg(parent, Vector3.new(x + d / 2, low, z), Vector3.new(x + d / 2 + 0.3, low + h - 0.5, z + 0.2), 0.25, band, Enum.Material.Metal, NOCOL_NS)
		return
	end
	local dirv = Vector3.new(math.sin(yaw), 0, math.cos(yaw))
	local side = Vector3.new(dirv.Z, 0, -dirv.X)
	local d, len = rng:NextNumber(4.4, 5.8), rng:NextNumber(9, 13)
	local cy = low + d / 2 + 1.0
	local a, b = Vector3.new(x, cy, z) - dirv * len / 2, Vector3.new(x, cy, z) + dirv * len / 2
	pipeSeg(parent, a, b, d, paint, Enum.Material.CorrodedMetal, { CanQuery = false, CanTouch = false }) -- solid body
	for _, e in { a, b } do
		decor(parent, Vector3.new(d * 0.5, d, d), CFrame.lookAt(e, e + dirv) * CFrame.Angles(0, math.pi / 2, 0), paint, Enum.Material.CorrodedMetal, { Shape = Enum.PartType.Ball })
	end
	for _, t in { 0.22, 0.78 } do
		local p = a:Lerp(b, t)
		for _, s in { -1, 1 } do
			pipeSeg(parent, p - Vector3.new(0, d * 0.35, 0) + side * (d * 0.3 * s), Vector3.new(p.X, low - 0.3, p.Z) + side * (d * 0.62 * s), 0.5, band, Enum.Material.Metal, NOCOL)
		end
	end
	pipeSeg(parent, a:Lerp(b, 0.5) + Vector3.new(0, d / 2, 0), a:Lerp(b, 0.5) + Vector3.new(0.4, d / 2 + 1.3, 0.3), 0.7, band, Enum.Material.Metal, NOCOL_NS)
	maybeYield()
end

-- Ribcage of something huge, half-sunk: arch ribs built from tapered bone segments, some snapped off (desert / ash).
local function ribCage(parent: Instance, x: number, z: number, yaw: number)
	local fwd = Vector3.new(math.sin(yaw), 0, math.cos(yaw))
	local side = Vector3.new(fwd.Z, 0, -fwd.X)
	local bone = RGB(226, 214, 188):Lerp(B.rocks[1], if biomeName == "ash" then 0.6 else 0.22)
	local n = rng:NextInteger(5, 7)
	for k = 1, n do
		local t = (k - 1) / (n - 1)
		local s = (k - (n + 1) / 2) * 6
		local cx, cz = x + fwd.X * s, z + fwd.Z * s
		local R = (4 + 3.8 * math.sin(t * math.pi)) * rng:NextNumber(0.9, 1.1)
		local g = groundY(cx, cz)
		local pts: { Vector3 } = {}
		for j = 0, 6 do
			local th = j / 6 * math.pi
			local p = Vector3.new(cx, g - 0.6, cz) + side * (math.cos(th) * R) + Vector3.new(0, math.sin(th) * R * 1.15, 0)
			if j == 0 or j == 6 then
				p = Vector3.new(p.X, groundY(p.X, p.Z) - 0.6, p.Z)
			end
			pts[j + 1] = p
		end
		local lo, hi = 0, 6
		local roll = rng:NextNumber()
		if roll < 0.35 then
			hi = rng:NextInteger(3, 5)
		elseif roll < 0.6 then
			lo = rng:NextInteger(1, 3)
		end
		for j = lo, hi - 1 do
			local thick = 1.5 - 0.7 * math.sin((j + 0.5) / 6 * math.pi)
			pipeSeg(parent, pts[j + 1], pts[j + 2], thick, jitter(bone, 0.06), Enum.Material.Limestone, NOCOL)
		end
	end
	maybeYield()
end

-- Dry shrub / tuft clump: several plants huddled together
local function shrubClump(parent: Instance, x: number, z: number)
	for _ = 1, rng:NextInteger(4, 6) do
		local a, d = rng:NextNumber(0, TAU), rng:NextNumber(0, 3.4)
		plant(parent, x + math.cos(a) * d, z + math.sin(a) * d)
	end
	maybeYield()
end

-- Swamp glow-pods: small mushroom clusters, translucent caps, a soft light on some of them
local function glowPods(parent: Instance, x: number, z: number, lit: boolean)
	local col = ({ RGB(120, 255, 170), RGB(150, 230, 255), RGB(190, 150, 255) })[rng:NextInteger(1, 3)]
	local first: BasePart? = nil
	for _ = 1, rng:NextInteger(3, 5) do
		local a, d = rng:NextNumber(0, TAU), rng:NextNumber(0, 3)
		local base = onGround(x + math.cos(a) * d, z + math.sin(a) * d, -0.3)
		local h = rng:NextNumber(1.2, 4)
		local tilt = CFrame.Angles(math.rad(rng:NextNumber(-12, 12)), 0, math.rad(rng:NextNumber(-12, 12)))
		cyl(parent, rng:NextNumber(0.3, 0.55), h, CFrame.new(base) * tilt * CFrame.new(0, h / 2, 0), B.plant[1], Enum.Material.Slate, NOCOL_NS)
		local r = rng:NextNumber(1.1, 2.4)
		local cap = part(parent, Vector3.new(r * 1.3, r * 0.7, r * 1.3), CFrame.new(base) * tilt * CFrame.new(0, h + r * 0.15, 0), col, Enum.Material.Neon, { Shape = Enum.PartType.Ball, Transparency = 0.3, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
		first = first or cap
	end
	if lit and first then
		pointLight(first, col, 16, 0.9)
	end
	maybeYield()
end

-- BROOD: egg cluster (translucent shell + small glowing core, on a dark bed), few
local function eggCluster(parent: Instance, x: number, z: number)
	local low, normal = lowestGround(x, z, 3)
	if normal.Y < 0.88 then
		return
	end
	decor(parent, Vector3.new(9, 1.4, 9), CFrame.new(x, low + 0.1, z), RGB(52, 34, 64), Enum.Material.Mud, { Shape = Enum.PartType.Ball, CastShadow = false })
	local n = rng:NextInteger(3, 5)
	for i = 1, n do
		local a = i / n * TAU + rng:NextNumber(-0.4, 0.4)
		local d = if i == 1 then 0 else rng:NextNumber(1.8, 3.4)
		local px, pz = x + math.cos(a) * d, z + math.sin(a) * d
		local s = rng:NextNumber(1.8, 3.0)
		local cf = CFrame.new(px, groundY(px, pz) + s * 0.55, pz) * CFrame.Angles(math.rad(rng:NextNumber(-10, 10)), 0, math.rad(rng:NextNumber(-10, 10)))
		decor(parent, Vector3.new(s, s * 1.35, s), cf, RGB(176, 238, 170), Enum.Material.Glass, { Shape = Enum.PartType.Ball, Transparency = 0.4, CastShadow = false })
		decor(parent, Vector3.new(s * 0.5, s * 0.7, s * 0.5), cf, RGB(120, 255, 90), Enum.Material.Neon, { Shape = Enum.PartType.Ball, Transparency = 0.25, CastShadow = false })
	end
	maybeYield()
end

-- BROOD: resin web between two organic posts (thin stretched translucent ellipsoids + strands)
local function resinWeb(parent: Instance, x: number, z: number, yaw: number)
	local _low, normal = lowestGround(x, z, 5)
	if normal.Y < 0.86 then
		return
	end
	local dirv = Vector3.new(math.sin(yaw), 0, math.cos(yaw))
	local gap = rng:NextNumber(8, 12)
	local purple = RGB(96, 60, 126)
	local resin = RGB(200, 184, 214)
	local posts: { { Vector3 } } = {}
	for k = 0, 1 do
		local px, pz = x + dirv.X * gap * (k - 0.5), z + dirv.Z * gap * (k - 0.5)
		local gy = groundY(px, pz)
		local top = Vector3.new(px + rng:NextNumber(-1.5, 1.5), gy + rng:NextNumber(7, 11), pz + rng:NextNumber(-1.5, 1.5))
		local bot = Vector3.new(px, gy - 0.5, pz + 0.4)
		pipeSeg(parent, bot, top, 1.0, purple, Enum.Material.Slate, NOCOL)
		pipeSeg(parent, top, top + Vector3.new(rng:NextNumber(-1, 1), 3, rng:NextNumber(-1, 1)), 0.5, purple, Enum.Material.Slate, NOCOL_NS)
		posts[k + 1] = { bot, top }
	end
	-- sheets: size.Z runs along the span, hung between the posts
	local mid = (posts[1][1] + posts[2][1]) / 2
	for i, sheet in { { 4.5, 1.7 }, { 2.6, 4.6 } } do
		local flipDir = if rng:NextNumber() < 0.5 then -dirv else dirv
		local sc = mid + Vector3.new(0, sheet[1] / 2 + sheet[2], 0)
		local w = blob(parent, Vector3.new(0.4, sheet[1] * 1.6, gap * 0.92), CFrame.lookAt(sc, sc - flipDir), resin, Enum.Material.Marble, false)
		w.Transparency = 0.22 - i * 0.05 -- mostly opaque resin: at 0.45 the sheets read as translucent ghost slabs
		w.CanQuery = false
		w.CanTouch = false
		w.CastShadow = false
	end
	for _, f in { 0.45, 0.8 } do
		local pa = posts[1][1]:Lerp(posts[1][2], f)
		local pb = posts[2][1]:Lerp(posts[2][2], f) - Vector3.new(0, 1.0, 0)
		pipeSeg(parent, pa, pb, 0.18, resin, Enum.Material.Marble, NOCOL_NS)
	end
	maybeYield()
end

-- BROOD: cluster of curved tusks / organic spikes (bent horns: thick lower segment + pointed bone-coloured tip)
local function tuskCluster(parent: Instance, x: number, z: number)
	local _low, normal = lowestGround(x, z, 3)
	if normal.Y < 0.84 then
		return
	end
	local col = RGB(96, 60, 126):Lerp(B.rocks[1], 0.2)
	local bone = RGB(222, 208, 180)
	local face = rng:NextNumber(0, TAU)
	for i = 1, rng:NextInteger(4, 7) do
		local a, d = rng:NextNumber(0, TAU), if i == 1 then 0 else rng:NextNumber(1.2, 4.5)
		local px, pz = x + math.cos(a) * d, z + math.sin(a) * d
		local h = rng:NextNumber(4, 9)
		local lean = math.rad(rng:NextNumber(14, 30))
		local base = CFrame.new(px, groundY(px, pz) - 0.6, pz) * CFrame.Angles(0, face + rng:NextNumber(-0.5, 0.5), 0)
		local lower = base * CFrame.Angles(0, 0, lean)
		cyl(parent, 1.5 * h / 6, h * 0.6, lower * CFrame.new(0, h * 0.3, 0), col, Enum.Material.Slate, NOCOL)
		local upper = lower * CFrame.new(0, h * 0.6, 0) * CFrame.Angles(0, 0, lean * 1.1)
		blob(parent, Vector3.new(0.9 * h / 6, h * 0.56, 0.9 * h / 6), upper * CFrame.new(0, h * 0.22, 0), bone, Enum.Material.Slate, false).CastShadow = false -- rounded tip
	end
	maybeYield()
end

-- COG maps: industrial bits on the lane edges
local function industrialSet(parent: Instance)
	local made = 0
	for _ = 1, 10 do
		if made >= 3 then
			break
		end
		local x, z = laneEdgeSpot(235)
		if pipeline(parent, x, z, rng:NextNumber(0, TAU), rng:NextInteger(4, 6)) then
			made += 1
		end
	end
	made = 0
	for _ = 1, 10 do
		if made >= 3 then
			break
		end
		local x, z = laneEdgeSpot(235)
		if cableRun(parent, x, z, rng:NextNumber(0, TAU)) then
			made += 1
		end
	end
	for _ = 1, 3 do
		local x, z = wildSpot(40, 18, 235)
		signalMast(parent, x, z)
	end
	for _ = 1, 3 do
		local x, z = laneEdgeSpot(235)
		fuelTank(parent, x, z, rng:NextNumber(0, TAU))
		if rng:NextNumber() < 0.6 then
			fuelTank(parent, x + rng:NextNumber(-9, 9), z + rng:NextNumber(8, 14), rng:NextNumber(0, TAU))
		end
	end
	if biomeName ~= "desert" then
		for _ = 1, 12 do
			local x, z = laneEdgeSpot(245)
			scrapHeap(parent, x, z)
		end
	end
end

-- BROOD maps: tusks, eggs and resin webs on the lane edges
local function hiveSet(parent: Instance)
	for _ = 1, 8 do
		local x, z = laneEdgeSpot(245)
		tuskCluster(parent, x, z)
	end
	for _ = 1, 6 do
		local x, z = laneEdgeSpot(245)
		eggCluster(parent, x, z)
	end
	for _ = 1, 6 do
		local x, z = laneEdgeSpot(245)
		resinWeb(parent, x, z, rng:NextNumber(0, TAU))
	end
end

-- Both factions: wreck fields (hulks, shell craters, pods, scrap) clustered on the lane edges, a few wisps of smoke
local function battlefield(parent: Instance, fac: string)
	local keys = WRECK_KEYS[fac] or WRECK_KEYS.COG
	local bigLeft = 2
	local wisps = 0
	local fieldCount = if biomeName == "desert" then 7 else 10
	for _ = 1, fieldCount do
		local x, z = laneEdgeSpot(238)
		local hulks = if biomeName == "desert" then rng:NextInteger(1, 2) else rng:NextInteger(1, 3)
		for k = 1, hulks do
			local a, d = rng:NextNumber(0, TAU), if k == 1 then 0 else rng:NextNumber(7, 14)
			local key, mul = keys[rng:NextInteger(1, #keys)], 1.3
			if bigLeft > 0 and k == 1 and rng:NextNumber() < 0.28 then
				key, mul = WRECK_BIG[fac] or "colossus", 1
				bigLeft -= 1
			end
			local m = wreckHulk(parent, x + math.cos(a) * d, z + math.sin(a) * d, key, mul)
			if m and wisps < 4 and rng:NextNumber() < 0.45 then
				wisps += 1
				plume(emitterHost(parent, m:GetPivot().Position + Vector3.new(0, 2, 0)), B.smoke, 2.8, 1.8, 7, 5)
			end
		end
		for _ = 1, if biomeName == "desert" then 1 else rng:NextInteger(1, 2) do
			local a, d = rng:NextNumber(0, TAU), rng:NextNumber(10, 20)
			shellCrater(parent, x + math.cos(a) * d, z + math.sin(a) * d, rng:NextNumber(5, 8))
		end
		if biomeName ~= "desert" and rng:NextNumber() < 0.45 then
			local a, d = rng:NextNumber(0, TAU), rng:NextNumber(12, 22)
			podHusk(parent, x + math.cos(a) * d, z + math.sin(a) * d)
		end
		task.wait()
	end
	for _ = 1, 4 do -- lone craters in the open ground
		local x, z = wildSpot(36, 16, 245)
		shellCrater(parent, x, z, rng:NextNumber(5, 7.5))
	end
end

-- Dense dark rubble: ~250 small clusters (2-4 chunks each: tiny env_rock meshes and little round pebbles), half sunk into the
-- ground, no collision, no shadows on the tiny ones. Heavier around shell craters and lane edges (the battlefield), never on
-- objective sites or the lane centrelines. Hard part budget so the map stays phone friendly.
-- Desert skips floor micro-rubble completely so the playable deck stays clean and readable.
local RUBBLE_CLUSTERS = 250
-- checked before the landmarks / far silhouettes (~400 parts) and the place set pieces (World/Places, ~900) are built, so
-- the whole map ends around 3600 parts
local RUBBLE_PART_CAP = 2150
local function rubbleField(parent: Instance)
	if biomeName == "desert" then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "Rubble"
	folder.Parent = parent
	local isDesert = false
	local keys = { "env_rock_c", "env_rock_a" }
	local function darkTint(): Color3
		local c = rockTint()
		return Color3.new(c.R * 0.7, c.G * 0.7, c.B * 0.7)
	end
	local function chunk(x: number, z: number)
		if isDesert then
			local s = rng:NextNumber(0.18, 0.38)
			local key = DESERT_ROCK_KEYS[rng:NextInteger(1, #DESERT_ROCK_KEYS)]
			placeMesh(folder, key, x, z, {
				scale = s,
				tint = rockTint(),
				material = B.rockMat,
				collide = false,
				sink = rng:NextNumber(0.3, 0.42),
				align = 0.85,
				maxSlope = 35,
				paint = function(p)
					keepMat(p)
					p.CanQuery = false
					p.CanTouch = false
					p.CastShadow = s > 0.32
				end,
			})
			return
		end
		local g = groundY(x, z)
		local tilt = CFrame.Angles(math.rad(rng:NextNumber(-22, 22)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-22, 22)))
		if rng:NextNumber() < 0.55 then
			local s = rng:NextNumber(0.3, 1.2)
			local key = keys[rng:NextInteger(1, 2)]
			local m = Assets.get(key, { anchored = true })
			if m then
				m:ScaleTo(s)
				local h = (Assets.size(key) or Vector3.new(14, 7, 11)).Y * s
				m:PivotTo(CFrame.new(x, g - h * rng:NextNumber(0.3, 0.5), z) * tilt)
				local col = darkTint()
				for _, p in m:GetChildren() do
					if p:IsA("BasePart") then
						p.Color = col
						p.Material = B.rockMat
						p.CanCollide = false
						p.CanQuery = false
						p.CanTouch = false
						p.CastShadow = s > 0.9
						partCount += 1
					end
				end
				m.Parent = folder
				return
			end
		end
		local w, h, d = rng:NextNumber(0.8, 2.4), rng:NextNumber(0.5, 1.6), rng:NextNumber(0.8, 2.2)
		local p = blob(folder, Vector3.new(w, h * 1.2, d), CFrame.new(x, g + h * 0.1, z) * tilt, darkTint(), B.rockMat, false) -- a round pebble
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
	end
	local clusterCount = if isDesert then 80 else RUBBLE_CLUSTERS
	for _ = 1, clusterCount do
		if partCount >= RUBBLE_PART_CAP then
			break
		end
		local x, z
		local roll = rng:NextNumber()
		local craterCutoff = if isDesert then 0.55 else 0.35
		local laneCutoff = if isDesert then 0.9 else 0.65
		if roll < craterCutoff and #craters > 0 then -- scorch: ring around the shell craters
			local c = craters[rng:NextInteger(1, #craters)]
			local a, d = rng:NextNumber(0, TAU), c.r * rng:NextNumber(0.6, 1.8)
			x, z = c.x + math.cos(a) * d, c.z + math.sin(a) * d
		elseif roll < laneCutoff then -- battlefield: the edges of the lanes
			x, z = laneEdgeSpot(250)
		else
			x, z = randomSpot(30, 24)
		end
		if math.abs(x) < 262 and math.abs(z) < 262 and farFromSites(x, z, 28) and not inLane(x, z, 9) and rng:NextNumber() < areaWeight(x, z, "rubble") then
			local n = if isDesert then rng:NextInteger(1, 3) else rng:NextInteger(2, 4)
			for _ = 1, n do
				local a, d = rng:NextNumber(0, TAU), rng:NextNumber(0.4, 3.6)
				chunk(x + math.cos(a) * d, z + math.sin(a) * d)
				maybeYield()
			end
		end
	end
end

-- Four big wrecks on the rim (one per side), each with a tall slow smoke column. All within ~560 studs of anywhere.
local function rimWrecks(parent: Instance, fac: string)
	local big = WRECK_BIG[fac] or "colossus"
	for side = 0, 3 do
		local placed = false
		local lx, lz = 0, 0
		for _ = 1, 16 do
			local f = rng:NextNumber(-0.8, 0.8) * 235
			local edge = rng:NextNumber(232, 248)
			local x, z
			if side == 0 then
				x, z = f, -edge
			elseif side == 1 then
				x, z = edge, f
			elseif side == 2 then
				x, z = -f, edge
			else
				x, z = -edge, -f
			end
			lx, lz = x, z
			if farFromSites(x, z, 50) then
				local m = wreckHulk(parent, x, z, big, rng:NextNumber(1.3, 1.8))
				if m then
					plume(emitterHost(parent, m:GetPivot().Position + Vector3.new(0, 8, 0)), B.smoke, 24, 2.2, 17, 8)
					placed = true
					break
				end
			end
		end
		if not placed then -- no flat spot for a hulk: a pod husk burning on the last spot tried
			podHusk(parent, lx, lz)
			plume(emitterHost(parent, onGround(lx, lz, 5)), B.smoke, 24, 2.2, 17, 8)
		end
		task.wait()
	end
end

-- Dust devil: a spinning, tilted emitter host that wanders slowly (server loop, 10 Hz, one part each)
local function dustDevil(parent: Instance, cx: number, cz: number, phase: number)
	local host = emitterHost(parent, Vector3.new(cx, heightAt(cx, cz) + 1, cz))
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
	pe.Rate = 26
	pe.Lifetime = NumberRange.new(4.5, 6)
	pe.Speed = NumberRange.new(13, 18)
	pe.SpreadAngle = Vector2.new(10, 10)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.5), NumberSequenceKeypoint.new(1, 14) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(0.5, 0.78), NumberSequenceKeypoint.new(1, 1) })
	pe.Color = ColorSequence.new((B.terrain[M.Sand] or RGB(224, 172, 104)):Lerp(RGB(255, 230, 190), 0.3))
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-90, 90)
	pe.LightInfluence = 0.9
	pe.Parent = host
	task.spawn(function()
		local t0 = os.clock()
		while host.Parent do
			local t = os.clock() - t0 + phase
			local ox = math.clamp(cx + math.cos(t * 0.045) * 55 + math.sin(t * 0.11) * 14, -215, 215)
			local oz = math.clamp(cz + math.sin(t * 0.037) * 70 + math.cos(t * 0.09) * 12, -215, 215)
			host.CFrame = CFrame.new(ox, heightAt(ox, oz) + 1, oz) * CFrame.Angles(0, t * 3.2, 0) * CFrame.Angles(math.rad(16), 0, 0)
			task.wait(0.1)
		end
	end)
end

-- Embers drifting up from a lava patch
local function embers(host: BasePart)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Rate = 5
	pe.Lifetime = NumberRange.new(6, 9)
	pe.Speed = NumberRange.new(4, 8)
	pe.SpreadAngle = Vector2.new(25, 25)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0.1) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	pe.Color = ColorSequence.new(RGB(255, 170, 70), RGB(255, 80, 30))
	pe.LightEmission = 1
	pe.Acceleration = Vector3.new(1.5, 3, 1)
	pe.Parent = host
end

-- Biome nature: lane-edge rock clusters with pebbles, shrub clumps, and per-biome extras
local function natureSet(props: Instance, dressing: Instance)
	local isDesert = biomeName == "desert"
	local clusterLoops = if isDesert then 14 else 22
	for _ = 1, clusterLoops do
		local x, z = laneEdgeSpot(250)
		local keep = rng:NextNumber() <= areaWeight(x, z, "rock")
		local count = if isDesert
			then (if keep then rng:NextInteger(2, 4) else 1)
			else (if keep then rng:NextInteger(3, 9) else rng:NextInteger(1, 2))
		for i = 1, count do
			local a, d = rng:NextNumber(0, TAU), if i == 1 then 0 else rng:NextNumber(3.5, 11)
			local rx, rz = x + math.cos(a) * d, z + math.sin(a) * d
			if not inLane(rx, rz, if isDesert then 13 else 9) and farFromSites(rx, rz, 28) then
				local s = if isDesert
					then (if i == 1 then rng:NextNumber(1.4, 2.3) else rng:NextNumber(0.95, 1.5))
					elseif i == 1 then rng:NextNumber(1.3, 2.4)
					elseif i <= 3 then rng:NextNumber(0.8, 1.4)
					else rng:NextNumber(0.4, 0.8)
				rock(props, rx, rz, s)
			end
		end
		if not isDesert then
			for _ = 1, 5 do
				local a, d = rng:NextNumber(0, TAU), rng:NextNumber(3, 14)
				pebble(props, x + math.cos(a) * d, z + math.sin(a) * d)
			end
		end
		task.wait()
	end
	if not isDesert then
		for _ = 1, 16 do
			local x, z
			if rng:NextNumber() < 0.6 then
				x, z = laneEdgeSpot(255)
			else
				x, z = wildSpot(20, 8, 258)
			end
			if rng:NextNumber() < areaWeight(x, z, "shrub") then
				shrubClump(dressing, x, z)
			end
		end
	end
	if biomeName == "desert" or biomeName == "ash" then
		for _ = 1, 2 do
			for _ = 1, 8 do
				local x, z = wildSpot(60, 22, 225)
				local _p, n = surfaceAt(x, z)
				if n.Y > 0.93 then
					ribCage(dressing, x, z, rng:NextNumber(0, TAU))
					break
				end
			end
		end
	elseif biomeName == "swamp" then
		for i = 1, 12 do
			local x, z
			if i % 2 == 0 then
				x, z = laneEdgeSpot(255)
			else
				x, z = wildSpot(24, 10, 255)
			end
			glowPods(dressing, x, z, i % 2 == 0)
		end
	elseif biomeName == "ice" or biomeName == "crystal" then
		for _ = 1, 10 do
			local x, z = laneEdgeSpot(255)
			crystals(props, x, z, rng:NextNumber(0.7, 1.9), nil, true)
		end
	end
	task.wait()
end

-- Air: distant smoke columns on wrecks along the rim, dust devils (desert)
local function atmosphere(dressing: Instance, fac: string)
	rimWrecks(dressing, fac)
	if biomeName == "desert" then
		for i = 1, 2 do
			local x, z = wildSpot(60, 20, 190)
			dustDevil(dressing, x, z, i * 40)
		end
	end
end

-- Dark rubble at a site's edge (art rule 5: ground is never bare): `n` small clusters of 2-3 half-sunk dark rock chunks
-- in the ring rIn..rOut, kept off the lane entrances (open paths) and off the camp side (`avoidA`). No collision.
-- rubbleField runs later and stops at RUBBLE_PART_CAP, so these parts come out of the global rubble budget.
local function siteRubble(parent: Instance, c: Vector2, rIn: number, rOut: number, n: number, avoidA: number?)
	if biomeName == "desert" then
		return
	end
	for _ = 1, n do
		local a = rng:NextNumber(0, TAU)
		if avoidA and math.abs((a - avoidA + math.pi) % TAU - math.pi) < 0.7 then
			a += math.pi * 0.6
		end
		local rr = rng:NextNumber(rIn, rOut)
		local x, z = c.X + math.cos(a) * rr, c.Y + math.sin(a) * rr
		if not inLane(x, z, 7) then
			for k = 1, rng:NextInteger(2, 3) do
				local ca, cd = rng:NextNumber(0, TAU), if k == 1 then 0 else rng:NextNumber(0.8, 2.6)
				local cx, cz = x + math.cos(ca) * cd, z + math.sin(ca) * cd
				if biomeName == "desert" then
					placeMesh(parent, DESERT_ROCK_KEYS[rng:NextInteger(1, #DESERT_ROCK_KEYS)], cx, cz, {
						scale = rng:NextNumber(0.16, 0.36),
						tint = rockTint(),
						material = B.rockMat,
						collide = false,
						sink = rng:NextNumber(0.32, 0.44),
						align = 0.85,
						maxSlope = 35,
						paint = function(p)
							keepMat(p)
							p.CanQuery = false
							p.CanTouch = false
							p.CastShadow = false
						end,
					})
					continue
				end
				local col = rockTint()
				col = Color3.new(col.R * 0.68, col.G * 0.68, col.B * 0.68)
				local m, skipped = placeMesh(parent, ROCK_KEYS[rng:NextInteger(1, 3)], cx, cz, { scale = rng:NextNumber(0.14, 0.42), tint = col, material = B.rockMat, collide = false, sink = 0.35, align = 0.85 })
				if not m and not skipped then
					local w, h = rng:NextNumber(0.8, 2.2), rng:NextNumber(0.5, 1.4)
					local p = blob(parent, Vector3.new(w, h * 1.2, w * 1.1), CFrame.new(onGround(cx, cz, h * 0.1)) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0), col, B.rockMat, false)
					p.CanQuery = false
					p.CastShadow = false
				end
			end
		end
	end
	maybeYield()
end

-- Outpost dressing for the small sites (the side-objective spots and the sample pickups): a ring of cover, rubble and a few
-- extras. The five places (refinery, mesa, quarry, graveyard, salt pan) and the crash / spilled-cell spots are dressed by
-- World/Places, so nothing is built there.
local function dressSite(parent: Instance, name: string, faction: string)
	local c = LAYOUT[name]
	local kind = name:gsub("%d+$", "")
	local pad = PADS[name]
	if not pad or (kind ~= "nest" and kind ~= "samples") then
		return
	end
	-- deliberate defensive ring: evenly spaced slots on ONE arc around the objective, every piece turned along the arc
	-- (long side tangent, face radial); slots where a combat lane or trail enters stay open as paths
	local R = pad[1] + 5
	local count = 6
	local a0 = rng:NextNumber(0, TAU)
	local placed = 0
	for i = 0, count - 1 do
		local a = a0 + i / count * TAU
		local x, z = c.X + math.cos(a) * R, c.Y + math.sin(a) * R
		if not inLane(x, z, 11) then
			placed += 1
			-- placeMesh's `back` axis is (sin yaw, cos yaw): yaw = pi/2 - a faces the barricade radially (its long side
			-- along the arc).
			cover(parent, x, z, math.pi / 2 - a, faction)
			-- a low rock tucked at one end so the piece sits in rubble, not on bare sand (skipped on desert for clean floor)
			if biomeName ~= "desert" then
				local e = a + (if placed % 2 == 0 then 1 else -1) * 3.2 / R
				rock(parent, c.X + math.cos(e) * (R + 1.2), c.Y + math.sin(e) * (R + 1.2), rng:NextNumber(0.35, 0.6), false)
			end
		end
	end
	siteRubble(parent, c, pad[1] * 0.75, R + 9, 5)
	if kind == "nest" then
		-- on a trail (a side spot that sits on a road) the ground stays as it is: no painted scorch there
		local onTrail = false
		for _, s in strips do
			if distSeg(c.X, c.Y, s.ax, s.az, s.bx, s.bz) < s.half + 8 then
				onTrail = true
			end
		end
		-- ragged terrain-painted scorch (no flat disc) + a broken rim of rubble and boulders, then eggs / scrap beyond 11 studs
		local bugs = faction == "BROOD"
		if not onTrail then
			scorchPatch(c.X, c.Y, 17, bugs)
		end
		if biomeName ~= "desert" then
			for i = 1, 9 do
				local a = i / 9 * TAU + rng:NextNumber(-0.2, 0.2)
				local rr = rng:NextNumber(15, 22)
				local rx, rz = c.X + math.cos(a) * rr, c.Y + math.sin(a) * rr
				if not inLane(rx, rz, 9) then
					rock(parent, rx, rz, rng:NextNumber(0.35, 0.9))
				end
			end
		end
		for _ = 1, if biomeName == "desert" then 4 else 3 do
			local a, rr = rng:NextNumber(0, TAU), rng:NextNumber(19, 25)
			local rx, rz = c.X + math.cos(a) * rr, c.Y + math.sin(a) * rr
			if not inLane(rx, rz, 9) then
				rock(parent, rx, rz, rng:NextNumber(1.1, 1.65))
			end
		end
		local b0 = rng:NextNumber(0, TAU)
		for k = 0, 1 do
			local a, rr = b0 + k * math.pi + rng:NextNumber(-0.5, 0.5), rng:NextNumber(11, 14)
			local ex, ez = c.X + math.cos(a) * rr, c.Y + math.sin(a) * rr
			if not inLane(ex, ez, 6) then
				if bugs then
					eggCluster(parent, ex, ez)
				elseif faction == "LUMEN" then
					crystals(parent, ex, ez, rng:NextNumber(0.9, 1.3))
				elseif biomeName ~= "desert" then
					scrapHeap(parent, ex, ez)
				end
			end
		end
		if bugs then
			tuskCluster(parent, c.X + math.cos(b0 + 1.6) * 21, c.Y + math.sin(b0 + 1.6) * 21)
		end
	elseif kind == "samples" then
		-- unlit: a coloured crystal light at the pickup washed the sand green / teal
		crystals(parent, c.X, c.Y, 1.1, nil, true)
		crystals(parent, c.X + 7, c.Y - 5, 0.8, nil, true)
	end
	-- supply crates by the objective: one pair, tucked just inside a ring slot
	do
		local a = a0 + (0.5 / count) * TAU
		local x, z = c.X + math.cos(a) * (R - 3), c.Y + math.sin(a) * (R - 3)
		if not inLane(x, z, 9) then
			crateStack(parent, x, z, -a)
		end
	end
end

-- ---------------------------------------------------------------- faction dressing
local function dressCog(parent: Instance)
	local steel = RGB(68, 74, 84)
	local rust = RGB(108, 72, 54)
	local red = RGB(255, 50, 50)
	local isDesert = biomeName == "desert"
	-- robot pylons, grouped near sites and away from the lanes (disciplined on desert)
	local pylonCount = if isDesert then 6 else 12
	for i = 1, pylonCount do
		local c = LAYOUT[({ "codes", "generator", "console", "silo", "uplink", "nest1", "nest2", "nest3", "nest4", "samples1", "samples2", "samples3" })[i]]
		local a = rng:NextNumber(0, TAU)
		local d = rng:NextNumber(46, 76)
		local x, z = c.X + math.cos(a) * d, c.Y + math.sin(a) * d
		if inLane(x, z, 12) then
			x, z = c.X - math.cos(a) * d, c.Y - math.sin(a) * d
		end
		local m, skipped = placeMesh(parent, "env_cog_pylon", x, z, { scale = rng:NextNumber(1.2, 1.8), sink = 0.04, collide = true, align = 0.4 })
		if skipped then
			-- too steep: no pylon here
		elseif not m then
			local base = onGround(x, z)
			part(parent, Vector3.new(3, 1, 3), CFrame.new(base + Vector3.new(0, 0.3, 0)), steel, Enum.Material.Metal)
			cyl(parent, 1.2, 15, CFrame.new(base + Vector3.new(0, 8, 0)), steel, Enum.Material.Metal)
			decor(parent, Vector3.new(1.4, 1.4, 1.4), CFrame.new(base + Vector3.new(0, 15.8, 0)), red, Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
		elseif i <= (if isDesert then 3 else 5) then
			for _, p in m:GetChildren() do
				if p:IsA("BasePart") and p:GetAttribute("Role") == "glow" then
					pointLight(p, p.Color, 36, 1.4)
					break
				end
			end
		end
		maybeYield()
	end
	-- barricade nests off the lanes (fewer on desert since desertSightlines builds intentional road-edge Jersey barrier lanes)
	for _ = 1, if isDesert then 4 else 9 do
		local x, z = wildSpot(50, 24, 240)
		local yaw = rng:NextNumber(0, TAU)
		for k = 1, rng:NextInteger(2, 3) do
			cover(parent, x + (k - 1) * 11 * math.cos(yaw), z - (k - 1) * 11 * math.sin(yaw), yaw + rng:NextNumber(-0.3, 0.3), "COG")
		end
	end
	-- metal debris: plates, gears, broken limbs
	if biomeName ~= "desert" then
		for _ = 1, 12 do
			local x, z = wildSpot(24, 10, 245)
			-- sit on the LOWEST ground under the piece (sunk), so tilted plates never hover over a slope
			local p = Vector3.new(x, lowestGround(x, z, 2.5) + 0.1, z)
			local k = rng:NextInteger(1, 3)
			if k == 1 then
				part(parent, Vector3.new(rng:NextNumber(2, 5), 0.5, rng:NextNumber(2, 5)), CFrame.new(p) * CFrame.Angles(math.rad(rng:NextNumber(-25, 25)), math.rad(rng:NextNumber(0, 180)), math.rad(rng:NextNumber(-25, 25))), steel, Enum.Material.DiamondPlate, { CanCollide = false })
			elseif k == 2 then
				local g = cyl(parent, rng:NextNumber(3, 6), 1, CFrame.new(p + Vector3.new(0, 0.9, 0)) * CFrame.Angles(math.rad(rng:NextNumber(60, 100)), math.rad(rng:NextNumber(0, 360)), 0), rust, Enum.Material.CorrodedMetal, { CanCollide = false })
				g.CastShadow = false
			else
				part(parent, Vector3.new(1, 1, rng:NextNumber(4, 8)), CFrame.new(p) * CFrame.Angles(0, math.rad(rng:NextNumber(0, 180)), math.rad(rng:NextNumber(-20, 20))), steel, Enum.Material.Metal, { CanCollide = false })
				-- torn chunk: a rounded lump half sunk (not a cube)
				local w = blob(parent, Vector3.new(2.4, 1.8, 2.6), CFrame.new(p + Vector3.new(rng:NextNumber(-3, 3), 0.3, rng:NextNumber(-3, 3))) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0), rust, Enum.Material.CorrodedMetal, false)
				w.CanQuery = false
			end
			maybeYield()
		end
	end
	-- (the old box-built tank husks are gone: battlefield() lays half-buried robot hulks instead)
	industrialSet(parent)
end

local function dressBrood(parent: Instance)
	local goo = RGB(110, 255, 120)
	local terrain = Workspace.Terrain
	-- goo pools (a few, dim: glow is for things that matter)
	for i = 1, 8 do
		local x, z = wildSpot(36, 14, 260)
		local r = rng:NextNumber(5, 11)
		local _sp, sn = surfaceAt(x, z)
		if sn.Y < 0.96 then
			continue -- a flat disc on a slope floats on one side and reads as a translucent ghost slab
		end
		local p = Vector3.new(x, lowestGround(x, z, r) + 0.1, z)
		terrain:FillCylinder(CFrame.new(p.X, p.Y - 0.8, p.Z), 1.5, r + 1.5, Enum.Material.Mud)
		local pool = decor(parent, Vector3.new(0.3, r * 2, r * 2), CFrame.new(p) * CFrame.Angles(0, 0, math.pi / 2), goo:Lerp(RGB(40, 60, 30), 0.35), Enum.Material.Neon, { Shape = Enum.PartType.Cylinder, Transparency = 0.15, CastShadow = false })
		if i <= 2 then
			pointLight(pool, goo, r * 1.4 + 6, 0.6) -- small and dim: big green lights turned the whole ground toxic
		end
		maybeYield()
	end
	-- hive mound groups off the lanes
	for _ = 1, 10 do
		local x, z = wildSpot(50, 20, 255)
		local n = rng:NextInteger(2, 4)
		for _ = 1, n do
			local mx, mz = x + rng:NextNumber(-16, 16), z + rng:NextNumber(-16, 16)
			local m, skipped = placeMesh(parent, "env_hive_mound", mx, mz, { scale = rng:NextNumber(0.8, 2.2), sink = 0.1, collide = true, align = 0.6 })
			if not m and not skipped then
				local r = rng:NextNumber(7, 12)
				local p = onGround(mx, mz)
				terrain:FillBall(Vector3.new(p.X, p.Y - r * 0.55, p.Z), r, Enum.Material.Mud)
				for _ = 1, 3 do
					local h = rng:NextNumber(5, 10)
					local sp = onGround(mx + rng:NextNumber(-r, r) * 0.6, mz + rng:NextNumber(-r, r) * 0.6, h / 2 - 1)
					-- rounded spike (a long ellipsoid) planted 1 stud deep, not a square post
					blob(parent, Vector3.new(1.8, h * 1.1, 1.8), CFrame.new(sp) * CFrame.Angles(math.rad(rng:NextNumber(-25, 25)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-25, 25))), RGB(110, 60, 150), Enum.Material.Slate, false)
				end
			end
		end
		maybeYield()
	end
	-- (the flat box "ribs" are gone: tusks, egg clusters and resin webs on the lane edges instead)
	hiveSet(parent)
end

-- Lumen Concord: crystal outcrops, leaning ceramic monolith shards with a light seam, glassy rift scars in the ground.
-- Simple part placeholders (no Lumen env meshes yet).
local function dressLumen(parent: Instance)
	local shell = RGB(200, 192, 214)
	local glow = RGB(170, 140, 255)
	local terrain = Workspace.Terrain
	-- crystal outcrops off the lanes: one big lit cluster + 1-3 smaller ones around it
	for i = 1, 10 do
		local x, z = wildSpot(44, 18, 255)
		crystals(parent, x, z, rng:NextNumber(1.6, 2.6), glow, i > 4)
		for _ = 1, rng:NextInteger(1, 3) do
			local a, d = rng:NextNumber(0, TAU), rng:NextNumber(5, 12)
			crystals(parent, x + math.cos(a) * d, z + math.sin(a) * d, rng:NextNumber(0.6, 1.2), glow, true)
		end
		maybeYield()
	end
	-- monolith shards: tall leaning round pillars with a domed top, planted deep, a thin light seam up one side
	for _ = 1, 8 do
		local x, z = wildSpot(50, 22, 250)
		local h = rng:NextNumber(14, 26)
		local w = rng:NextNumber(3, 5)
		local base = Vector3.new(x, lowestGround(x, z, w) - 2, z)
		local cf = CFrame.new(base) * CFrame.Angles(math.rad(rng:NextNumber(-14, 14)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-14, 14))) * CFrame.new(0, h / 2, 0)
		cyl(parent, w * 1.2, h, cf, shell, Enum.Material.SmoothPlastic)
		blob(parent, Vector3.one * w * 1.2, cf * CFrame.new(0, h / 2 - w * 0.1, 0), shell, Enum.Material.SmoothPlastic, true)
		decor(parent, Vector3.new(0.3, h * 0.5, 0.3), cf * CFrame.new(w * 0.6, -h * 0.1, 0), glow, Enum.Material.Neon, { CastShadow = false }) -- a thin light seam up the side
		maybeYield()
	end
	-- rift scars: zig-zag chains of glassy terrain (Glacier is tinted lavender on this biome)
	for _ = 1, 6 do
		local x, z = wildSpot(50, 20, 250)
		local dir = rng:NextNumber(0, TAU)
		for _ = 1, 4 do
			local len = rng:NextNumber(8, 15)
			local g = groundY(x, z)
			terrain:FillBlock(CFrame.new(x, g - 1, z) * CFrame.Angles(0, -dir, 0), Vector3.new(len, 2.4, rng:NextNumber(1.4, 2.6)), Enum.Material.Glacier)
			x += math.cos(dir) * len * 0.85
			z += math.sin(dir) * len * 0.85
			dir += math.rad(rng:NextNumber(-35, 35))
		end
		maybeYield()
	end
end

-- Desert leading lines & tactical sightlines: waist-high modular Jersey barriers along main routes (clean 20-24 stud
-- flanking gaps), chunky overhead steel road gantries & walker-rib cover arch framing key lane entrances, plus sparse
-- tall industrial lamp posts (single crimson/amber beacons) and vertical sector banners at junctions.
local function desertSightlines(props: Instance, dressing: Instance)
	local concrete = RGB(82, 78, 74)
	local steelDark = RGB(44, 48, 56)
	local steelMid = RGB(66, 72, 82)
	local steelTrim = RGB(126, 132, 142)
	local haz = RGB(224, 174, 42)
	local crimson = RGB(255, 52, 42)
	local amber = RGB(255, 172, 54)
	local bannerCrimson = RGB(132, 42, 38)
	local bannerAmber = RGB(150, 108, 42)

	local function flatEnough(x: number, z: number, r: number): (boolean, number)
		local pos, n = surfaceAt(x, z)
		if n.Y < 0.90 then
			return false, pos.Y
		end
		local lo = lowestGround(x, z, r)
		if pos.Y - lo > 2.2 then
			return false, lo
		end
		return true, lo
	end

	-- Modular waist-high Jersey barrier (4.8 studs tall, simple box collider + bright metallic top rib)
	local function jerseyBarrier(x: number, z: number, dir2: Vector2, len: number)
		local ok, lo = flatEnough(x, z, len * 0.4)
		if not ok then
			return
		end
		local base = Vector3.new(x, lo, z)
		local cf = CFrame.lookAt(base, base + Vector3.new(dir2.X, 0, dir2.Y))
		local h = 4.8
		local body = part(props, Vector3.new(2.4, h + 1.4, len), cf * CFrame.new(0, (h - 1.4) / 2, 0), jitter(concrete, 0.05), Enum.Material.Concrete, { CanCollide = true })
		body.Name = "JerseyBarrier"
		local plinth = decor(dressing, Vector3.new(2.9, 1.3, len + 0.2), cf * CFrame.new(0, 0.45, 0), steelDark, Enum.Material.Metal, { CastShadow = false })
		keepMat(plinth)
		local cap = decor(dressing, Vector3.new(1.9, 0.45, len + 0.15), cf * CFrame.new(0, h + 0.1, 0), steelTrim, Enum.Material.Metal, { CastShadow = false })
		keepMat(cap)
		decor(dressing, Vector3.new(2.52, 0.7, len * 0.26), cf * CFrame.new(0, h * 0.65, 0), haz, Enum.Material.SmoothPlastic, { CastShadow = false })
	end

	-- Tall industrial lamp post with a single crimson or amber sector beacon
	local lampLights = 0
	local function sectorLamp(x: number, z: number, faceDir2: Vector2, isCrimson: boolean)
		local ok, lo = flatEnough(x, z, 2)
		if not ok then
			return
		end
		local base = Vector3.new(x, lo, z)
		local cf = CFrame.lookAt(base, base + Vector3.new(faceDir2.X, 0, faceDir2.Y))
		local h = 21
		part(props, Vector3.new(2.4, 2.0, 2.4), cf * CFrame.new(0, 0.6, 0), steelDark, Enum.Material.Metal, { CanCollide = true })
		cyl(dressing, 0.85, h, cf * CFrame.new(0, h / 2, 0), steelMid, Enum.Material.Metal, NOCOL)
		beam(dressing, (cf * CFrame.new(0, h - 1.5, 0)).Position, (cf * CFrame.new(0, h + 1.2, -5.5)).Position, 0.7, steelDark, Enum.Material.Metal, NOCOL)
		decor(dressing, Vector3.new(2.2, 0.8, 3.0), cf * CFrame.new(0, h + 1.35, -5.8), steelDark, Enum.Material.Metal, { CastShadow = false })
		local col = if isCrimson then crimson else amber
		local bulb = decor(dressing, Vector3.new(1.2, 0.8, 1.2), cf * CFrame.new(0, h + 0.65, -5.8), col, Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
		if lampLights < 3 then
			lampLights += 1
			pointLight(bulb, col, 34, 1.5)
		end
	end

	-- Tall vertical sector banner marking a lane junction or enemy/objective approach
	local function sectorBanner(x: number, z: number, faceDir2: Vector2, isCrimson: boolean)
		local ok, lo = flatEnough(x, z, 2)
		if not ok then
			return
		end
		local base = Vector3.new(x, lo, z)
		local cf = CFrame.lookAt(base, base + Vector3.new(faceDir2.X, 0, faceDir2.Y))
		local h = 17.5
		cyl(dressing, 0.7, h, cf * CFrame.new(-1.8, h / 2 - 0.5, 0), steelDark, Enum.Material.Metal, NOCOL)
		part(dressing, Vector3.new(3.8, 0.45, 0.5), cf * CFrame.new(0, h - 1.2, 0), steelMid, Enum.Material.Metal, NOCOL_NS)
		part(dressing, Vector3.new(3.8, 0.4, 0.45), cf * CFrame.new(0, h - 10.6, 0), steelMid, Enum.Material.Metal, NOCOL_NS)
		local cloth = if isCrimson then bannerCrimson else bannerAmber
		decor(dressing, Vector3.new(2.7, 9.2, 0.25), cf * CFrame.new(0.2, h - 5.9, 0), cloth, Enum.Material.SmoothPlastic, { CastShadow = false })
		decor(dressing, Vector3.new(2.74, 1.1, 0.3), cf * CFrame.new(0.2, h - 3.6, 0), if isCrimson then RGB(228, 214, 194) else haz, Enum.Material.SmoothPlastic, { CastShadow = false })
		decor(dressing, Vector3.new(0.9, 0.9, 0.9), cf * CFrame.new(-1.8, h + 0.1, 0), if isCrimson then crimson else amber, Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
	end

	-- Chunky overhead steel road gantry framing a lane entrance (clear 24-stud span, 17-stud overhead clearance)
	local function roadGantry(x: number, z: number, dir2: Vector2, isCrimson: boolean)
		local perp2 = Vector2.new(-dir2.Y, dir2.X)
		local halfSpan = 13.5
		local lx, lz = x - perp2.X * halfSpan, z - perp2.Y * halfSpan
		local rx, rz = x + perp2.X * halfSpan, z + perp2.Y * halfSpan
		local loL, nL = lowestGround(lx, lz, 2.5)
		local loR, nR = lowestGround(rx, rz, 2.5)
		if nL.Y < 0.86 or nR.Y < 0.86 or math.abs(loL - loR) > 5.5 then
			return
		end
		local deckY = math.max(loL, loR)
		local topY = deckY + 18.5
		local cf = CFrame.lookAt(Vector3.new(x, deckY, z), Vector3.new(x + dir2.X, deckY, z + dir2.Y))
		for _, s in { -1, 1 } do
			local px, pz = x + perp2.X * halfSpan * s, z + perp2.Y * halfSpan * s
			local gY = if s < 0 then loL else loR
			local colH = topY - gY + 2
			local pcf = CFrame.lookAt(Vector3.new(px, gY + colH / 2 - 1.5, pz), Vector3.new(px + dir2.X, gY + colH / 2 - 1.5, pz + dir2.Y))
			part(props, Vector3.new(3.2, colH, 3.6), pcf, steelDark, Enum.Material.Metal, { CanCollide = true })
			decor(dressing, Vector3.new(3.5, 1.3, 3.9), pcf * CFrame.new(0, -colH / 2 + 4.5, 0), haz, Enum.Material.SmoothPlastic, { CastShadow = false })
		end
		-- heavy cross-truss girder overhead (walk-through / high above players)
		local girder = decor(dressing, Vector3.new(halfSpan * 2 + 5.5, 2.6, 2.8), cf * CFrame.new(0, 18.5, 0), steelMid, Enum.Material.Metal, { CastShadow = true })
		keepMat(girder)
		decor(dressing, Vector3.new(halfSpan * 2 + 3.5, 0.7, 3.0), cf * CFrame.new(0, 17.0, 0), haz, Enum.Material.SmoothPlastic, { CastShadow = false })
		for _, sx in { -7.5, 0, 7.5 } do
			decor(dressing, Vector3.new(1.0, 2.2, 3.1), cf * CFrame.new(sx, 20.6, 0), steelDark, Enum.Material.Metal, { CastShadow = false })
		end
		decor(dressing, Vector3.new(halfSpan * 2 + 1, 0.7, 1.4), cf * CFrame.new(0, 21.8, 0), steelDark, Enum.Material.Metal, { CastShadow = false })
		-- single disciplined corner beacon
		local col = if isCrimson then crimson else amber
		decor(dressing, Vector3.new(1.3, 1.3, 1.3), cf * CFrame.new(halfSpan, 22.8, 0), col, Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
	end

	-- Tilted dark walker-rib cover arch framing the Walker Graveyard approach lane
	local function ribCoverArch(x: number, z: number, dir2: Vector2)
		local perp2 = Vector2.new(-dir2.Y, dir2.X)
		local halfSpan = 14
		local loL, nL = lowestGround(x - perp2.X * halfSpan, z - perp2.Y * halfSpan, 3)
		local loR, nR = lowestGround(x + perp2.X * halfSpan, z + perp2.Y * halfSpan, 3)
		if nL.Y < 0.85 or nR.Y < 0.85 then
			return
		end
		local baseY = math.min(loL, loR) - 1.5
		local cf = CFrame.lookAt(Vector3.new(x, baseY, z), Vector3.new(x + dir2.X, baseY, z + dir2.Y)) * CFrame.Angles(math.rad(8), 0, 0)
		local pts: { Vector3 } = {}
		for k = 0, 6 do
			local th = math.pi * k / 6
			pts[k + 1] = (cf * CFrame.new(math.cos(th) * halfSpan, math.sin(th) * 21, 0)).Position
		end
		for k = 1, 6 do
			local solid = k == 1 or k == 6
			pipeSeg(if solid then props else dressing, pts[k], pts[k + 1], 2.8, steelDark, Enum.Material.Metal, { CanCollide = solid })
		end
		decor(dressing, Vector3.new(3.4, 3.4, 3.4), CFrame.new(pts[4]), steelMid, Enum.Material.Metal, { Shape = Enum.PartType.Ball, CastShadow = false })
	end

	local ref = MapPlan.places.refinery.at
	local quarryAt = MapPlan.places.quarry.at
	local mesaAt = MapPlan.places.mesa.at
	local graveAt = MapPlan.places.graveyard.at
	local saltAt = MapPlan.places.saltpan.at
	local radarAt = MapPlan.sideSpot("radar") and MapPlan.sideSpot("radar").at or Vector2.new(-100, -20)
	local spilledAt = LAYOUT.codes

	local routes = {
		{ a = ref, b = quarryAt, off = 13.5, step = 34, gantryT = 0.42, crimson = true, kind = "gantry" },
		{ a = ref, b = radarAt, off = 12.5, step = 34, gantryT = 0.48, crimson = false, kind = "gantry" },
		{ a = ref, b = saltAt, off = 13.5, step = 36, gantryT = 0.46, crimson = false, kind = "gantry" },
		{ a = ref, b = graveAt, off = 14.0, step = 38, gantryT = 0.50, crimson = true, kind = "rib" },
		{ a = ref, b = mesaAt, off = 14.0, step = 40, gantryT = 0.46, crimson = true, kind = "gantry" },
		{ a = spilledAt, b = ref, off = 13.5, step = 38, gantryT = -1, crimson = false, kind = "none" },
	}

	for rIdx, rt in routes do
		local delta = rt.b - rt.a
		local dist = delta.Magnitude
		if dist < 50 then
			continue
		end
		local dir2 = delta.Unit
		local perp2 = Vector2.new(-dir2.Y, dir2.X)
		-- Overhead gantry / rib arch at mid-route checkpoint
		if rt.gantryT > 0 then
			local gp = rt.a:Lerp(rt.b, rt.gantryT)
			if farFromSites(gp.X, gp.Y, 34) then
				if rt.kind == "rib" then
					ribCoverArch(gp.X, gp.Y, dir2)
				else
					roadGantry(gp.X, gp.Y, dir2, rt.crimson)
				end
				-- disciplined lamp post + vertical sector banner flanking the checkpoint
				local lp = gp + perp2 * (rt.off + 3.5) - dir2 * 10
				if farFromSites(lp.X, lp.Y, 26) then
					sectorLamp(lp.X, lp.Y, -perp2, rt.crimson)
				end
				local bp = gp - perp2 * (rt.off + 3.5) + dir2 * 10
				if farFromSites(bp.X, bp.Y, 26) then
					sectorBanner(bp.X, bp.Y, perp2, rt.crimson)
				end
			end
		end

		-- Modular waist-high Jersey barriers along lane edges: 12-stud wall + 22-26 stud open gap between units
		local sideSign = if rIdx % 2 == 0 then 1 else -1
		local d = 56
		while d < dist - 54 do
			local p = rt.a + dir2 * d + perp2 * (rt.off * sideSign)
			if math.max(math.abs(p.X), math.abs(p.Y)) < 232 and farFromSites(p.X, p.Y, 30) and not inLane(p.X, p.Y, 8.5) then
				jerseyBarrier(p.X, p.Y, dir2, rng:NextNumber(10.5, 13.5))
			end
			sideSign = -sideSign
			d += rt.step
		end
		maybeYield()
	end

	-- Extra sparse junction lamps & vertical sector banners near key side-objective approaches
	for i, s in MapPlan.sides do
		local toRef = (ref - s.at)
		if toRef.Magnitude > 10 then
			local dir2 = toRef.Unit
			local perp2 = Vector2.new(-dir2.Y, dir2.X)
			local anchor = s.at + dir2 * 24 + perp2 * (if i % 2 == 0 then 11 else -11)
			if farFromSites(anchor.X, anchor.Y, 20) then
				if i % 2 == 1 then
					sectorLamp(anchor.X, anchor.Y, -perp2, true)
				else
					sectorBanner(anchor.X, anchor.Y, -dir2, true)
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- landmarks (60-200 studs, far ring)
local function foundryTower(parent: Instance, x: number, z: number, yaw: number)
	local g = surfaceAt(x, z)
	local base = CFrame.new(g) * CFrame.Angles(0, yaw, 0)
	local isDesert = biomeName == "desert"
	local steel = if isDesert then RGB(50, 54, 62) else RGB(66, 70, 80)
	local steelLt = if isDesert then RGB(66, 70, 78) else RGB(84, 88, 98)
	local rust = if isDesert then RGB(96, 66, 52) else RGB(120, 70, 50)
	local soot = RGB(36, 36, 42)
	local amber = RGB(255, 150, 40)
	local nc = { CastShadow = false }

	-- deep foundation so a sloped rim never leaves it floating, then a stepped plinth
	part(parent, Vector3.new(80, 50, 80), base * CFrame.new(0, -22, 0), RGB(54, 56, 62), Enum.Material.Basalt)
	part(parent, Vector3.new(70, 12, 70), base * CFrame.new(0, 9, 0), RGB(58, 60, 66), Enum.Material.Basalt)
	part(parent, Vector3.new(62, 6, 62), base * CFrame.new(0, 18, 0), steel, Enum.Material.CorrodedMetal)
	-- slag heaps piled against the plinth: the flat box edges disappear into a ragged sloped skirt
	rockSkirt(parent, g, 31, 60, 15, 12, RGB(48, 46, 50):Lerp(B.rocks[1], 0.3), Enum.Material.Basalt)

	-- tapering round tiers with catwalk rings: dia, height, centre y, material
	local tiers = {
		{ 58, 30, 36, Enum.Material.CorrodedMetal, steel },
		{ 46, 30, 66, Enum.Material.Metal, steelLt },
		{ 34, 26, 94, Enum.Material.CorrodedMetal, steel },
		{ 24, 22, 118, Enum.Material.Metal, steelLt },
	}
	for i, t in tiers do
		local dia, h, cy = t[1], t[2], t[3]
		cyl(parent, dia, h, base * CFrame.new(0, cy, 0), t[5], t[4])
		-- catwalk ring around the top of the tier, with a skirt underneath and a rust band on the wall
		cyl(parent, dia + 9, 1.4, base * CFrame.new(0, cy + h / 2 + 0.7, 0), soot, Enum.Material.DiamondPlate)
		cyl(parent, dia + 4, 2.4, base * CFrame.new(0, cy + h / 2 - 1.4, 0), rust, Enum.Material.CorrodedMetal, { CastShadow = false })
		cyl(parent, dia + 0.8, 1.6, base * CFrame.new(0, cy - h * 0.12, 0), soot, Enum.Material.Metal, nc)
		-- railing posts on the ring
		local r = (dia + 9) / 2 - 0.4
		local posts = math.floor(dia / 3.2)
		for k = 0, posts - 1 do
			local a = k / posts * TAU
			decor(parent, Vector3.new(0.5, 2.6, 0.5), base * CFrame.new(math.cos(a) * r, cy + h / 2 + 2.7, math.sin(a) * r), soot, Enum.Material.Metal, nc)
		end
		-- glowing window slits, staggered per tier (not every one lit)
		local count = math.floor(dia / 3.6)
		for k = 0, count - 1 do
			if rng:NextNumber() > 0.25 then
				local a = (k + (i % 2) * 0.5) / count * TAU
				local rr = dia / 2 + 0.15
				local slitH = if i == 1 then 9 else 6.5
				decor(parent, Vector3.new(1.3, slitH, 0.5), base * CFrame.new(math.cos(a) * rr, cy + h * 0.08, math.sin(a) * rr) * CFrame.Angles(0, -a + math.pi / 2, 0), amber, Enum.Material.Neon, nc)
			end
		end
		maybeYield()
	end
	-- buttresses raking from the plinth up the first two tiers
	for k = 0, 7 do
		local a = k / 8 * TAU + math.pi / 8
		local c, s = math.cos(a), math.sin(a)
		beam(parent, (base * CFrame.new(c * 37, 12, s * 37)).Position, (base * CFrame.new(c * 27, 56, s * 27)).Position, 4, RGB(74, 78, 88), Enum.Material.Metal)
	end
	-- furnace mouth at the foot of the front face (local -Z faces the map centre): glowing arch + doorway light
	local door = decor(parent, Vector3.new(16, 14, 1), base * CFrame.new(0, 28, -29.3), amber, Enum.Material.Neon, nc)
	decor(parent, Vector3.new(22, 4, 2), base * CFrame.new(0, 36.5, -29.6), soot, Enum.Material.Metal, nc)
	for _, sx in { -1, 1 } do
		decor(parent, Vector3.new(3, 17, 2), base * CFrame.new(sx * 9.5, 28, -29.6), soot, Enum.Material.Metal, nc)
	end
	pointLight(door, RGB(255, 130, 50), 90, 2.5)

	-- chimneys: tall, two-stage, banded; smoke from every one, flames from the first
	for i, o in { { -30, -30 }, { 30, -30 }, { -30, 30 }, { 30, 30 } } do
		local h = 150 + (i % 2) * 32 + (if i == 3 then 12 else 0)
		local lowH = h * 0.62
		cyl(parent, 13, lowH, base * CFrame.new(o[1], lowH / 2 + 12, o[2]), RGB(74, 70, 72), Enum.Material.CorrodedMetal)
		cyl(parent, 9.5, h - lowH, base * CFrame.new(o[1], lowH + (h - lowH) / 2 + 12, o[2]), RGB(86, 80, 80), Enum.Material.CorrodedMetal)
		cyl(parent, 14.6, 3, base * CFrame.new(o[1], lowH + 12, o[2]), soot, Enum.Material.Metal)
		cyl(parent, 11.4, 4.5, base * CFrame.new(o[1], h + 12, o[2]), rust, Enum.Material.CorrodedMetal)
		for _, by in { 0.18, 0.4, 0.8, 0.92 } do
			cyl(parent, if by < 0.6 then 13.6 else 10.2, 1.6, base * CFrame.new(o[1], h * by + 12, o[2]), soot, Enum.Material.Metal, nc)
		end
		-- soot-streaked scorch at the lip
		cyl(parent, 9.6, 5, base * CFrame.new(o[1], h + 8.5, o[2]), RGB(24, 22, 24), Enum.Material.Slate, { CastShadow = false, CanCollide = false })
		local host = emitterHost(parent, (base * CFrame.new(o[1], h + 16, o[2])).Position)
		smokeEmitter(host, B.smoke, 20, 3.5, 13)
		if i == 1 then
			fireEmitter(host, 10, 6)
			pointLight(host, RGB(255, 120, 50), 70, 2)
		end
		-- big duct from the chimney to the tier wall, plus a lower feed pipe
		beam(parent, (base * CFrame.new(o[1], 62, o[2])).Position, (base * CFrame.new(o[1] * 0.55, 70, o[2] * 0.55)).Position, 4, RGB(90, 84, 80), Enum.Material.Metal)
		beam(parent, (base * CFrame.new(o[1] * 0.9, 30, o[2] * 0.9)).Position, (base * CFrame.new(o[1] * 0.55, 46, o[2] * 0.55)).Position, 3, RGB(98, 90, 84), Enum.Material.CorrodedMetal)
		maybeYield()
	end
	-- pipe bundle running up the back face, with elbows
	for k = -2, 2 do
		beam(parent, (base * CFrame.new(k * 3.6, 24, 31.5)).Position, (base * CFrame.new(k * 3.6, 70, 25)).Position, 2.2, if k % 2 == 0 then RGB(104, 96, 90) else RGB(80, 76, 80), Enum.Material.Metal)
		local elbow = decor(parent, Vector3.new(3.4, 3.4, 3.4), base * CFrame.new(k * 3.6, 24, 31.5), soot, Enum.Material.Metal, nc)
		elbow.Shape = Enum.PartType.Ball
	end

	-- crane: mast on the crown, long boom out to one side, counter-jib with weight, cable and hook
	local topY = 129
	cyl(parent, 30, 4, base * CFrame.new(0, topY, 0), rust, Enum.Material.CorrodedMetal)
	local dome = decor(parent, Vector3.new(22, 22, 22), base * CFrame.new(0, topY + 2, 0), RGB(96, 66, 52), Enum.Material.CorrodedMetal, nc)
	dome.Shape = Enum.PartType.Ball
	beam(parent, (base * CFrame.new(0, topY, 0)).Position, (base * CFrame.new(0, topY + 40, 0)).Position, 3.4, soot, Enum.Material.Metal)
	for _, o in { { 4, 4 }, { -4, 4 }, { 4, -4 }, { -4, -4 } } do
		beam(parent, (base * CFrame.new(o[1], topY, o[2])).Position, (base * CFrame.new(0, topY + 38, 0)).Position, 1.2, soot, Enum.Material.Metal, { CanCollide = false })
	end
	local jibTop = base * CFrame.new(0, topY + 36, 0)
	local boomEnd = (jibTop * CFrame.new(-6, 4, -62)).Position -- boom reaches toward the map centre, rising a little
	beam(parent, jibTop.Position, boomEnd, 3, RGB(150, 110, 40), Enum.Material.Metal)
	beam(parent, (jibTop * CFrame.new(0, 3.5, 0)).Position, (jibTop * CFrame.new(-3, 3.5, -40)).Position, 1.6, RGB(150, 110, 40), Enum.Material.Metal, { CanCollide = false })
	local counterEnd = (jibTop * CFrame.new(3, 0, 26)).Position
	beam(parent, jibTop.Position, counterEnd, 3, RGB(150, 110, 40), Enum.Material.Metal)
	part(parent, Vector3.new(9, 7, 11), CFrame.new(counterEnd) * (base - base.Position) * CFrame.new(0, -3, 3), RGB(70, 66, 68), Enum.Material.Concrete)
	-- tie-backs from the mast top to boom tip and counter-jib
	local mastTop = (base * CFrame.new(0, topY + 40, 0)).Position
	beam(parent, mastTop, boomEnd, 0.9, soot, Enum.Material.Metal, { CanCollide = false })
	beam(parent, mastTop, counterEnd, 0.9, soot, Enum.Material.Metal, { CanCollide = false })
	-- cable and hook block hanging from the boom tip
	local hookTop = boomEnd - Vector3.new(0, 1, 0)
	local hook = hookTop - Vector3.new(0, 38, 0)
	beam(parent, hookTop, hook, 0.5, soot, Enum.Material.Metal, { CanCollide = false })
	part(parent, Vector3.new(3, 4, 3), CFrame.new(hook - Vector3.new(0, 2, 0)), RGB(190, 150, 40), Enum.Material.Metal, { CanCollide = false })
	local beacon = decor(parent, Vector3.new(4, 4, 4), CFrame.new(mastTop + Vector3.new(0, 3, 0)), RGB(255, 60, 40), Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
	pointLight(beacon, RGB(255, 60, 40), 80, 2.5)
	maybeYield()
end

-- Crashed cruiser: a long tapered hull broken in two. The nose section is buried in the rim at a steep angle, the
-- stern section lies beside it, yawed and rolled, with a gap of torn frames and spilled plates between them.
-- Hull sections are built from plates (stepped deck / belly, angled flank slabs) so the plan view tapers to the nose and
-- the cut ends show the empty frame: exposed ribs.
local function crashedCruiser(parent: Instance, x: number, z: number, yaw: number)
	local g = surfaceAt(x, z)
	-- the nose points OUTWARD (away from the map centre) into the rising rim, so it is buried; the stern faces the players
	local base = CFrame.new(g) * CFrame.Angles(0, yaw + math.pi, 0)
	local hull = RGB(70, 78, 92)
	local hullLt = RGB(88, 96, 112)
	local dark = RGB(40, 44, 54)
	local scorched = RGB(30, 28, 30)
	local nc = { CastShadow = false }

	-- plate between two local points (a -> b): thickness x height (x = thick, y = tall), long axis along the span
	local function slab(f: CFrame, a: Vector3, b: Vector3, thick: number, tall: number, color: Color3, mat: Enum.Material?, opts: { [string]: any }?)
		local wa, wb = (f * CFrame.new(a)).Position, (f * CFrame.new(b)).Position
		local up = f.UpVector
		local cf = CFrame.lookAt((wa + wb) / 2, wb, up)
		return part(parent, Vector3.new(thick, tall, (wb - wa).Magnitude), cf, color, mat or Enum.Material.Metal, opts)
	end

	-- one hull section. f: section frame (z = 0 at the break; dirZ = -1 runs toward the nose, +1 toward the stern)
	local function hullSection(f: CFrame, dirZ: number, len: number, w0: number, w1: number, h0: number, h1: number, steps: number)
		for i = 0, steps - 1 do
			local t0, t1 = i / steps, (i + 1) / steps
			local tm = (t0 + t1) / 2
			local w = w0 + (w1 - w0) * tm
			local h = h0 + (h1 - h0) * tm
			local zc = dirZ * tm * len
			local seg = len / steps + 0.6
			local tone = if i % 2 == 0 then hull else hullLt
			part(parent, Vector3.new(w, 2, seg), f * CFrame.new(0, h / 2, zc), tone, Enum.Material.Metal) -- dorsal plating, stepped
			part(parent, Vector3.new(w * 0.82, 2, seg), f * CFrame.new(0, -h / 2, zc), dark, Enum.Material.Metal) -- belly
		end
		-- flank slabs, angled in so the hull narrows to the nose (two spans: the taper bends slightly)
		local half = steps // 2
		for _, sx in { -1, 1 } do
			local mid = half / steps
			local wMid = w0 + (w1 - w0) * mid
			local hMid = h0 + (h1 - h0) * mid
			slab(f, Vector3.new(sx * w0 / 2, 0, 0), Vector3.new(sx * wMid / 2, 0, dirZ * len * mid), 2, (h0 + hMid) / 2, hull)
			slab(f, Vector3.new(sx * wMid / 2, 0, dirZ * len * mid), Vector3.new(sx * w1 / 2, 0, dirZ * len), 2, (hMid + h1) / 2, RGB(62, 70, 84))
			-- armour strake along the flank
			slab(f, Vector3.new(sx * (w0 / 2 + 1.4), h0 * 0.18, dirZ * len * 0.05), Vector3.new(sx * (wMid / 2 + 1.4), hMid * 0.18, dirZ * len * mid * 0.95), 1.4, 5, hullLt, Enum.Material.DiamondPlate)
		end
		-- keel spine
		part(parent, Vector3.new(3, 3, len), f * CFrame.new(0, -h0 / 2 - 1, dirZ * len / 2), dark, Enum.Material.Metal)
	end

	-- torn frames at a break: posts of random heights, a partial cross beam, ribs poking out and bent
	local function brokenFrames(f: CFrame, dirZ: number, w: number, h: number, count: number)
		for i = 0, count - 1 do
			local zz = dirZ * (i * 4.2 + 1)
			local lean = math.rad(rng:NextNumber(-14, 14))
			for _, sx in { -1, 1 } do
				local ph = h * rng:NextNumber(0.5, 1.05)
				local post = part(parent, Vector3.new(1.8, ph, 1.8), f * CFrame.new(sx * (w / 2 - 1), ph / 2 - h / 2, zz) * CFrame.Angles(0, 0, sx * lean), RGB(58, 60, 68), Enum.Material.Metal, { CanCollide = false })
				post.CastShadow = true
			end
			if rng:NextNumber() < 0.6 then
				local len = w * rng:NextNumber(0.4, 0.9)
				part(parent, Vector3.new(len, 1.6, 1.6), f * CFrame.new(rng:NextNumber(-3, 3), h / 2 - 1, zz) * CFrame.Angles(0, 0, math.rad(rng:NextNumber(-12, 12))), RGB(58, 60, 68), Enum.Material.Metal, { CanCollide = false })
			end
			-- a spar reaching out past the break
			if i % 2 == 0 then
				local sx = if rng:NextNumber() < 0.5 then -1 else 1
				slab(f, Vector3.new(sx * (w / 2 - 2), h / 2 - 2, zz), Vector3.new(sx * (w / 2 - 5), h / 2 + rng:NextNumber(0, 5), zz + dirZ * rng:NextNumber(8, 14)), 1.5, 1.5, dark, Enum.Material.Metal, { CanCollide = false })
			end
		end
	end

	-- ---- nose section: buried, steep. Frame origin is the break, the nose is 84 studs along -Z (down into the ground).
	local noseF = base * CFrame.new(-4, 24, -12) * CFrame.Angles(math.rad(-26), 0, math.rad(-5))
	-- the part that goes underground doubles as the foundation (solid, so nothing floats on a sloped rim)
	part(parent, Vector3.new(44, 40, 52), base * CFrame.new(-2, -10, -52), RGB(52, 50, 54), Enum.Material.Basalt)
	-- ploughed-up earth heaped around the buried nose: hides the foundation block's flat top and straight edges
	rockSkirt(parent, (base * CFrame.new(-2, 0, -52)).Position, 20, 44, 15, 10, RGB(54, 50, 52):Lerp(B.rocks[1], 0.35))
	hullSection(noseF, -1, 84, 36, 6, 30, 10, 6)
	brokenFrames(noseF, -1, 36, 30, 4)
	-- chin guns / prow blade
	slab(noseF, Vector3.new(0, 6, -76), Vector3.new(0, 3, -94), 3, 6, dark)

	-- ---- stern section: lies beside it, yawed and rolled, engines up
	local sternF = base * CFrame.new(8, 17, 12) * CFrame.Angles(0, math.rad(10), 0) * CFrame.Angles(math.rad(-4), 0, math.rad(7))
	-- rock pedestals under the stern section so a falling slope never leaves it hanging
	part(parent, Vector3.new(34, 70, 34), base * CFrame.new(8, -30, 30), RGB(52, 50, 54), Enum.Material.Basalt)
	part(parent, Vector3.new(40, 70, 40), base * CFrame.new(10, -33, 72), RGB(56, 52, 54), Enum.Material.Basalt)
	rockSkirt(parent, (base * CFrame.new(9, 0, 51)).Position, 22, 46, 9, 9, RGB(54, 50, 52):Lerp(B.rocks[1], 0.35))
	hullSection(sternF, 1, 86, 36, 31, 30, 27, 5)
	brokenFrames(sternF, 1, 36, 30, 4)
	-- stepped bridge superstructure with glowing viewport strip, dorsal ridge and a bent mast
	part(parent, Vector3.new(26, 7, 34), sternF * CFrame.new(0, 19, 46), dark, Enum.Material.DiamondPlate)
	part(parent, Vector3.new(18, 9, 20), sternF * CFrame.new(0, 26, 50), RGB(58, 64, 78), Enum.Material.Metal)
	part(parent, Vector3.new(10, 6, 12), sternF * CFrame.new(0, 33, 52), hullLt, Enum.Material.Metal)
	decor(parent, Vector3.new(14, 1.8, 0.6), sternF * CFrame.new(0, 27, 39.8), RGB(255, 190, 100), Enum.Material.Neon, nc)
	blob(parent, Vector3.new(6, 14, 44), sternF * CFrame.new(0, 17, 12), dark, Enum.Material.Metal, false)
	beam(parent, (sternF * CFrame.new(0, 36, 52)).Position, (sternF * CFrame.new(5, 62, 55)).Position, 1.4, dark, Enum.Material.Metal, { CanCollide = false })
	local mast = decor(parent, Vector3.new(1.8, 1.8, 1.8), sternF * CFrame.new(5, 63, 55), RGB(255, 60, 40), Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
	pointLight(mast, RGB(255, 70, 50), 60, 1.8)
	-- twin tail fins, one snapped
	for _, sx in { -1, 1 } do
		local fh = if sx > 0 then 30 else 17
		-- rounded fin (a stretched ellipsoid) instead of a flat rectangular plate
		blob(parent, Vector3.new(4, fh * 1.2, 24), sternF * CFrame.new(sx * 15, 27 + fh / 2 - 15, 76) * CFrame.Angles(0, 0, math.rad(-sx * (if sx > 0 then 12 else 38))), RGB(56, 62, 76), Enum.Material.Metal, false)
	end
	-- engine nacelles with glowing nozzles and struts
	for _, sx in { -1, 1 } do
		local nacelle = part(parent, Vector3.new(60, 16, 16), sternF * CFrame.new(sx * 27, 4, 66) * CFrame.Angles(0, math.pi / 2, 0), dark, Enum.Material.Metal)
		nacelle.Shape = Enum.PartType.Cylinder
		decor(parent, Vector3.new(2, 12, 12), sternF * CFrame.new(sx * 27, 4, 96.5) * CFrame.Angles(0, math.pi / 2, 0), RGB(255, 110, 50), Enum.Material.Neon, { Shape = Enum.PartType.Cylinder, CastShadow = false })
		for _, zz in { 50, 76 } do
			beam(parent, (sternF * CFrame.new(sx * 27, 4, zz)).Position, (sternF * CFrame.new(sx * 16, 2, zz - 4)).Position, 3, dark, Enum.Material.Metal)
		end
	end
	maybeYield()

	-- ---- glowing emergency strips along both sections (hull tapers, so the half-width follows)
	for i = 0, 11 do
		local sx = if i % 2 == 0 then -1 else 1
		local t = (i // 2) / 5
		local col = if i % 3 == 0 then RGB(255, 70, 50) else RGB(255, 200, 110)
		decor(parent, Vector3.new(0.6, 1.6, 3.6), noseF * CFrame.new(sx * (18 - 15 * t + 1.1), 4, -6 - t * 66), col, Enum.Material.Neon, nc)
		if i < 10 then
			decor(parent, Vector3.new(0.6, 1.6, 3.6), sternF * CFrame.new(sx * (18 - 2 * t + 1.1), 4, 8 + t * 60), col, Enum.Material.Neon, nc)
		end
	end

	-- ---- the gap: torn plates lying around, plus a few shorter standing frames
	for _ = 1, 8 do
		local p = Vector3.new(rng:NextNumber(-14, 22), 0, rng:NextNumber(-18, 22))
		local wp = (base * CFrame.new(p)).Position
		local gy = groundY(wp.X, wp.Z)
		part(parent, Vector3.new(rng:NextNumber(6, 14), 1.4, rng:NextNumber(5, 11)), CFrame.new(wp.X, gy + rng:NextNumber(0.4, 3), wp.Z) * CFrame.Angles(math.rad(rng:NextNumber(-25, 25)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-25, 25))), if rng:NextNumber() < 0.5 then hull else RGB(54, 58, 68), Enum.Material.Metal, { CanCollide = false })
	end

	-- ---- scorch: a long black skid trail on the ground behind the impact, plus a burnt ring around the buried nose
	-- (terrain-painted ragged blobs, not flat discs)
	local skid = Workspace.Terrain
	for i = 0, 9 do
		local zz = -30 + i * 14
		local wp = (base * CFrame.new(rng:NextNumber(-5, 5), 0, zz)).Position
		local r = rng:NextNumber(7, 13) * (1 - i * 0.04)
		local _sp, snormal = surfaceAt(wp.X, wp.Z)
		-- painted blobs only on gentle ground (on a slope they would form ledges)
		if snormal.Y > 0.93 then
			skid:FillCylinder(CFrame.new(wp.X, groundY(wp.X, wp.Z) - 1.1, wp.Z), 2.4, r, Enum.Material.Basalt)
		end
		for _ = 1, if snormal.Y > 0.93 then 2 else 0 do
			local a, off = rng:NextNumber(0, TAU), r * rng:NextNumber(0.5, 0.9)
			local bx, bz = wp.X + math.cos(a) * off, wp.Z + math.sin(a) * off
			skid:FillCylinder(CFrame.new(bx, groundY(bx, bz) - 1.1, bz), 2.4, r * rng:NextNumber(0.3, 0.5), if i % 3 == 0 then Enum.Material.Slate else Enum.Material.Basalt)
		end
	end
	maybeYield()

	-- ---- fire and smoke: breach on the nose section, stern break, engines, and the burial point
	local host = emitterHost(parent, (noseF * CFrame.new(0, 14, -6)).Position)
	fireEmitter(host, 10, 7)
	smokeEmitter(host, B.smoke, 22, 4, 13)
	pointLight(host, RGB(255, 120, 50), 80, 2.2)
	smokeEmitter(emitterHost(parent, (sternF * CFrame.new(0, 18, 6)).Position), B.smoke, 18, 3, 12)
	smokeEmitter(emitterHost(parent, (sternF * CFrame.new(-27, 8, 98)).Position), B.smoke, 14, 2.5, 11)
	local burn = emitterHost(parent, (base * CFrame.new(-2, 2, -50)).Position)
	smokeEmitter(burn, B.smoke, 16, 3, 11)
	fireEmitter(burn, 6, 4)
	maybeYield()
end

local function hiveSpire(parent: Instance, x: number, z: number, yaw: number)
	local g = surfaceAt(x, z)
	local base = CFrame.new(g) * CFrame.Angles(0, yaw, 0)
	local purple = RGB(88, 52, 120)
	local goo = RGB(140, 255, 60)
	-- foundation sunk below the surface (its flat top used to stand 10 studs proud as a mud box) + a ragged organic skirt
	part(parent, Vector3.new(60, 44, 60), base * CFrame.new(0, -24, 0), RGB(50, 34, 64), Enum.Material.Mud)
	rockSkirt(parent, g, 9, 44, 16, 10, RGB(62, 40, 78), Enum.Material.Mud)
	-- core: giant needle (mesh, else part blade)
	local m = placeMesh(parent, "env_spire_b", g.X, g.Z, { scale = 3.8, tint = purple, material = Enum.Material.Slate, collide = true, align = 0.1, sink = 0.05, y = g.Y - 4, maxSlope = 89 })
	if not m then
		fallbackSpire(parent, g.X, g.Z, 4, purple)
	end
	-- curved ribs hugging the needle
	for i = 1, 8 do
		local a = i / 8 * TAU
		local lean = math.rad(rng:NextNumber(10, 16))
		local h = rng:NextNumber(70, 110)
		local cf = base * CFrame.new(math.cos(a) * 26, h / 2 - 6, math.sin(a) * 26) * CFrame.Angles(0, -a, 0) * CFrame.Angles(0, 0, lean)
		-- long rounded rib (a stretched ellipsoid) instead of a 100-stud flat slab
		blob(parent, Vector3.new(5, h, 8), cf, RGB(104, 64, 132), Enum.Material.Mud, false)
	end
	-- glowing bands + eggs
	for i, hh in { 36, 78, 120 } do
		local band = decor(parent, Vector3.new(1.5, 30 - i * 6, 30 - i * 6), base * CFrame.new(0, hh, 0) * CFrame.Angles(0, 0, math.pi / 2), goo, Enum.Material.Neon, { Shape = Enum.PartType.Cylinder, Transparency = 0.45, CastShadow = false })
		if i == 1 then
			pointLight(band, goo, 90, 2)
		end
	end
	for _ = 1, 8 do
		local a = rng:NextNumber(0, TAU)
		local d = rng:NextNumber(30, 52)
		local s = rng:NextNumber(5, 9)
		local p = base * CFrame.new(math.cos(a) * d, s * 0.5, math.sin(a) * d)
		decor(parent, Vector3.new(s, s * 1.3, s), p, RGB(160, 255, 150), Enum.Material.Glass, { Shape = Enum.PartType.Ball, Transparency = 0.35, CastShadow = false })
	end
	-- ring of mounds
	for i = 1, 6 do
		local a = i / 6 * TAU + 0.3
		local px, pz = g.X + math.cos(a) * 52, g.Z + math.sin(a) * 52
		placeMesh(parent, "env_hive_mound", px, pz, { scale = rng:NextNumber(2.4, 3.4), sink = 0.2, collide = false, align = 0.3, maxSlope = 50 })
	end
	maybeYield()
end

local function mesaArch(parent: Instance, x: number, z: number, yaw: number)
	local g = surfaceAt(x, z)
	local R = 80
	local N = 15
	local rot = CFrame.Angles(0, yaw, 0)
	-- the span runs along the rim: find the ground under both feet and sit the arch on the lower one
	local feet = {}
	for _, sx in { -1, 1 } do
		local fp = g + (rot * Vector3.new(sx * R, 0, 0))
		local fg = surfaceAt(fp.X, fp.Z)
		table.insert(feet, fg)
	end
	local baseY = math.min(feet[1].Y, feet[2].Y, g.Y) - 4
	local base = CFrame.new(g.X, baseY, g.Z) * rot
	local tint = rockTint()
	for i = 0, N - 1 do
		local th = (i + 0.5) / N * math.pi
		local cf = base * CFrame.new(math.cos(th) * R, math.sin(th) * R, 0) * CFrame.Angles(0, 0, th - math.pi / 2)
		-- thinner toward the crown, each block shifted and rolled a little so the span reads as weathered stacked stone
		local thick = (22 - 7 * math.sin(th)) + rng:NextNumber(-3, 4)
		local jit = CFrame.new(rng:NextNumber(-1.5, 1.5), rng:NextNumber(-1.2, 1.2), rng:NextNumber(-2.5, 2.5))
			* CFrame.Angles(math.rad(rng:NextNumber(-4, 4)), math.rad(rng:NextNumber(-5, 5)), math.rad(rng:NextNumber(-5, 5)))
		local bw, bd = 19 + rng:NextNumber(-3, 3), 26 + rng:NextNumber(-4, 5)
		local col = jitter(tint, 0.08)
		local blk = part(parent, Vector3.new(bw, thick * 0.78, bd), cf * jit * CFrame.new(0, -thick * 0.11, 0), col, B.rockMat)
		blk.CanCollide = true
		-- rounded cap on the outer face: a lumpy ellipsoid per block, so the top of the span is a bumpy crest instead of a
		-- smooth ring of boxes
		local cap = blob(parent, Vector3.new(bw * rng:NextNumber(0.75, 0.95), thick * rng:NextNumber(0.7, 1.0), bd * rng:NextNumber(0.7, 0.95)),
			cf * jit * CFrame.new(rng:NextNumber(-1.5, 1.5), thick * 0.3, rng:NextNumber(-2, 2)) * CFrame.Angles(0, rng:NextNumber(-0.2, 0.2), 0), jitter(col, 0.06), B.rockMat, false)
		if biomeName == "desert" then
			keepMat(blk)
			keepMat(cap)
		end
	end
	-- footings reach down to the actual ground, plus loose spires around them
	for i, sx in { -1, 1 } do
		local fg = feet[i]
		local top = fg.Y + 6
		local bottom = math.min(fg.Y, baseY) - 22
		local foot = part(parent, Vector3.new(34, top - bottom, 40), CFrame.new(fg.X, (top + bottom) / 2, fg.Z) * rot, jitter(tint, 0.05), B.rockMat)
		if biomeName == "desert" then
			keepMat(foot)
		end
		for k = 1, 2 do
			local sp = fg + (rot * Vector3.new(sx * rng:NextNumber(14, 26), 0, (k * 2 - 3) * rng:NextNumber(12, 20)))
			spire(parent, sp.X, sp.Z, rng:NextNumber(0.9, 1.4), tint)
		end
		-- a talus skirt + boulders heaped around the foot hide the flat top and straight sides of the footing block
		rockSkirt(parent, fg, 12, 36, 13, 8, tint)
		for _ = 1, 2 do
			local bp = fg + (rot * Vector3.new(sx * rng:NextNumber(-12, 18), 0, rng:NextNumber(-20, 20)))
			rock(parent, bp.X, bp.Z, rng:NextNumber(2.2, 3.4), true)
		end
	end
	maybeYield()
end

local function spireGroup(parent: Instance, x: number, z: number, _yaw: number)
	local g = surfaceAt(x, z)
	local tint = rockTint()
	for i = 1, 4 do
		local a = i / 4 * TAU + rng:NextNumber(-0.4, 0.4)
		local d = if i == 1 then 0 else rng:NextNumber(28, 46)
		spire(parent, g.X + math.cos(a) * d, g.Z + math.sin(a) * d, if i == 1 then rng:NextNumber(3.6, 4.4) else rng:NextNumber(2, 3.2), tint)
	end
end

local function iceCrystals(parent: Instance, x: number, z: number, _yaw: number)
	local g = surfaceAt(x, z)
	-- foundation sunk below the surface (it used to stand 8 studs proud as a flat glacier box) + a ragged ice skirt
	part(parent, Vector3.new(60, 40, 60), CFrame.new(g + Vector3.new(0, -24, 0)), B.rocks[2], Enum.Material.Glacier)
	rockSkirt(parent, g, 8, 40, 12, 9, B.rocks[2], Enum.Material.Glacier)
	for i = 1, 4 do
		local a = i / 4 * TAU + rng:NextNumber(-0.3, 0.3)
		local d = if i == 1 then 0 else rng:NextNumber(22, 38)
		crystals(parent, g.X + math.cos(a) * d, g.Z + math.sin(a) * d, if i == 1 then rng:NextNumber(11, 14) else rng:NextNumber(6, 9), B.crystal)
	end
	spire(parent, g.X + 30, g.Z - 26, 3, B.rocks[3])
end

-- Lumen Concord landmark (the COG foundryTower / Brood hiveSpire slot): a giant crystal spire on a pale ceramic plinth, a
-- floating light ring and leaning shards around it. Simple part placeholder.
local function crystalSpire(parent: Instance, x: number, z: number, yaw: number)
	local g = surfaceAt(x, z)
	local base = CFrame.new(g) * CFrame.Angles(0, yaw, 0)
	local shell = RGB(196, 188, 212)
	local deep = RGB(70, 58, 104)
	local glow = RGB(170, 140, 255)
	-- foundation sunk below the surface + ragged skirt
	part(parent, Vector3.new(56, 40, 56), base * CFrame.new(0, -22, 0), deep, Enum.Material.Slate)
	rockSkirt(parent, g, 8, 40, 12, 9, shell, Enum.Material.Limestone)
	-- the spire: four stacked tapering drums with a ball tip, glowing core shaft inside
	local h = 120
	do
		local y = -4
		for i, t in { { 26, 44 }, { 20, 34 }, { 14, 26 }, { 8, 20 } } do
			cyl(parent, t[1], t[2], base * CFrame.new(0, y + t[2] / 2, 0), shell, Enum.Material.SmoothPlastic)
			y += t[2] * 0.9
			if i == 4 then
				blob(parent, Vector3.one * t[1], base * CFrame.new(0, y + t[2] * 0.1, 0), shell, Enum.Material.SmoothPlastic, false)
			end
		end
	end
	local core = decor(parent, Vector3.new(4, h * 0.8, 4), base * CFrame.new(0, h * 0.45, 0), glow, Enum.Material.Neon, { Transparency = 0.2, CastShadow = false })
	pointLight(core, glow, 80, 1.6)
	-- floating rings
	for i, hh in { 70, 104 } do
		local d = 34 - i * 8
		decor(parent, Vector3.new(1.2, d, d), base * CFrame.new(0, hh, 0) * CFrame.Angles(0, 0, math.pi / 2), glow, Enum.Material.Neon, { Shape = Enum.PartType.Cylinder, Transparency = 0.5, CastShadow = false })
	end
	-- leaning shards around the foot
	for i = 1, 7 do
		local a = i / 7 * TAU + rng:NextNumber(-0.2, 0.2)
		local sh = rng:NextNumber(26, 48)
		local cf = base * CFrame.new(math.cos(a) * 28, sh / 2 - 6, math.sin(a) * 28) * CFrame.Angles(0, -a, 0) * CFrame.Angles(0, 0, math.rad(rng:NextNumber(12, 22)))
		blob(parent, Vector3.new(7, sh * 1.1, 7), cf, if i % 2 == 0 then shell else deep, Enum.Material.SmoothPlastic, false)
	end
	for _ = 1, 4 do
		local a, d = rng:NextNumber(0, TAU), rng:NextNumber(36, 50)
		crystals(parent, g.X + math.cos(a) * d, g.Z + math.sin(a) * d, rng:NextNumber(4, 6), glow, true)
	end
	maybeYield()
end

-- Desert 360-degree brutalist perimeter silhouettes (Band 2 dark slate/iron towers visible through the pale haze)
local function desertSiloCluster(parent: Instance, x: number, z: number, yaw: number)
	local g = surfaceAt(x, z)
	local base = CFrame.new(g.X, g.Y - 12, g.Z) * CFrame.Angles(0, yaw, 0)
	local dark = RGB(48, 52, 58)
	local mid = RGB(64, 68, 74)
	local soot = RGB(34, 36, 42)
	local nc = { CanCollide = false, CanQuery = false, CastShadow = false }
	-- plinth + 3 tapered oversized silos
	part(parent, Vector3.new(76, 34, 46), base * CFrame.new(0, 6, 0), soot, Enum.Material.Basalt, nc)
	local specs = {
		{ ox = -24, oz = 0, d = 26, h = 138, col = dark },
		{ ox = 0, oz = -4, d = 32, h = 172, col = mid },
		{ ox = 25, oz = 2, d = 22, h = 116, col = dark },
	}
	for _, s in specs do
		local lowH = s.h * 0.65
		cyl(parent, s.d, lowH, base * CFrame.new(s.ox, lowH / 2 + 18, s.oz), s.col, Enum.Material.Metal, nc)
		cyl(parent, s.d * 0.78, s.h - lowH, base * CFrame.new(s.ox, lowH + (s.h - lowH) / 2 + 18, s.oz), dark, Enum.Material.Metal, nc)
		cyl(parent, s.d + 4, 3.2, base * CFrame.new(s.ox, lowH + 18, s.oz), soot, Enum.Material.Metal, nc)
	end
	-- high catwalk bridge tying silos together + crimson aviation beacon
	decor(parent, Vector3.new(54, 4.5, 7), base * CFrame.new(0, 126, 0), soot, Enum.Material.Metal, nc)
	decor(parent, Vector3.new(4.2, 4.2, 4.2), base * CFrame.new(0, 194, -4), RGB(255, 56, 44), Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
	maybeYield()
end

local function desertGantryCrane(parent: Instance, x: number, z: number, yaw: number)
	local g = surfaceAt(x, z)
	local base = CFrame.new(g.X, g.Y - 10, g.Z) * CFrame.Angles(0, yaw, 0)
	local dark = RGB(44, 48, 56)
	local mid = RGB(62, 66, 74)
	local haz = RGB(176, 132, 42)
	local nc = { CanCollide = false, CanQuery = false, CastShadow = false }
	-- heavy A-frame legs rising 160 studs, leaning slightly inward toward the map
	for _, sx in { -22, 22 } do
		beam(parent, (base * CFrame.new(sx, -10, 18)).Position, (base * CFrame.new(sx * 0.55, 152, 0)).Position, 7.5, dark, Enum.Material.Metal, nc)
		beam(parent, (base * CFrame.new(sx, -10, -16)).Position, (base * CFrame.new(sx * 0.55, 152, 0)).Position, 7.5, dark, Enum.Material.Metal, nc)
	end
	-- cross-braces + operator bridge
	decor(parent, Vector3.new(42, 7, 16), base * CFrame.new(0, 82, 0), mid, Enum.Material.Metal, nc)
	decor(parent, Vector3.new(36, 11, 22), base * CFrame.new(0, 148, 0), dark, Enum.Material.Metal, nc)
	-- long angled cantilevered truss jib overhanging toward map centre (-Z)
	local jibStart = (base * CFrame.new(0, 156, 38)).Position
	local jibTip = (base * CFrame.new(0, 174, -84)).Position
	beam(parent, jibStart, jibTip, 6.2, mid, Enum.Material.Metal, nc)
	beam(parent, (base * CFrame.new(0, 186, 4)).Position, jibTip, 2.2, dark, Enum.Material.Metal, nc)
	beam(parent, (base * CFrame.new(0, 186, 4)).Position, jibStart, 2.2, dark, Enum.Material.Metal, nc)
	decor(parent, Vector3.new(18, 12, 16), base * CFrame.new(0, 148, 36), haz, Enum.Material.Metal, nc) -- counterweight
	-- cable & hanging industrial grapple silhouette
	beam(parent, jibTip, jibTip - Vector3.new(0, 56, 0), 1.2, dark, Enum.Material.Metal, nc)
	decor(parent, Vector3.new(9, 10, 9), CFrame.new(jibTip - Vector3.new(0, 61, 0)), dark, Enum.Material.Metal, nc)
	decor(parent, Vector3.new(4.2, 4.2, 4.2), CFrame.new(jibTip + Vector3.new(0, 4.5, 0)), RGB(255, 56, 44), Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
	maybeYield()
end

local function desertRefineryStacks(parent: Instance, x: number, z: number, yaw: number)
	local g = surfaceAt(x, z)
	local base = CFrame.new(g.X, g.Y - 12, g.Z) * CFrame.Angles(0, yaw, 0)
	local dark = RGB(46, 50, 56)
	local mid = RGB(62, 64, 70)
	local soot = RGB(30, 30, 34)
	local nc = { CanCollide = false, CanQuery = false, CastShadow = false }
	-- stepped brutalist furnace hall
	part(parent, Vector3.new(78, 42, 52), base * CFrame.new(0, 12, 0), dark, Enum.Material.Basalt, nc)
	part(parent, Vector3.new(54, 24, 38), base * CFrame.new(-6, 42, 0), mid, Enum.Material.Metal, nc)
	-- twin monumental stepped smokestacks + dark soot columns against the bright sky
	for i, st in { { ox = -20, h = 188, d = 16 }, { ox = 18, h = 154, d = 14 } } do
		local loH = st.h * 0.58
		cyl(parent, st.d, loH, base * CFrame.new(st.ox, loH / 2 + 24, 0), dark, Enum.Material.Metal, nc)
		cyl(parent, st.d * 0.72, st.h - loH, base * CFrame.new(st.ox, loH + (st.h - loH) / 2 + 24, 0), mid, Enum.Material.Metal, nc)
		cyl(parent, st.d * 0.84, 7, base * CFrame.new(st.ox, st.h + 21, 0), soot, Enum.Material.Metal, nc)
		beam(parent, (base * CFrame.new(st.ox, 48, 0)).Position, (base * CFrame.new(st.ox * 0.2, 36, -12)).Position, 5.2, soot, Enum.Material.Metal, nc)
		local top = emitterHost(parent, (base * CFrame.new(st.ox, st.h + 28, 0)).Position)
		smokeEmitter(top, RGB(38, 35, 34), 22, if i == 1 then 3.2 else 2.2, 15)
	end
	decor(parent, Vector3.new(4, 4, 4), base * CFrame.new(-20, 214, 0), RGB(255, 140, 42), Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
	maybeYield()
end

local function desertWalkerFrame(parent: Instance, x: number, z: number, yaw: number)
	local g = surfaceAt(x, z)
	local base = CFrame.new(g.X, g.Y - 12, g.Z) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-14), 0, math.rad(12))
	local dark = RGB(44, 48, 54)
	local mid = RGB(60, 64, 72)
	local nc = { CanCollide = false, CanQuery = false, CastShadow = false }
	-- 3 colossal half-buried dark-iron walker rib frames + broken dorsal spine
	local crowns: { Vector3 } = {}
	for i = 0, 2 do
		local s = (i - 1) * 34
		local rx = 38 + (if i == 1 then 10 else 0)
		local ry = 92 + (if i == 1 then 24 else 0)
		local prev: Vector3? = nil
		for k = 0, 4 do
			local th = math.pi * k / 4
			local p = (base * CFrame.new(math.cos(th) * rx, math.sin(th) * ry, s)).Position
			if prev then
				beam(parent, prev, p, 8.5, if i == 1 then dark else mid, Enum.Material.Metal, nc)
			end
			if k == 2 then
				crowns[i + 1] = p
			end
			prev = p
		end
	end
	beam(parent, crowns[1], crowns[2], 9.5, dark, Enum.Material.Metal, nc)
	beam(parent, crowns[2], crowns[3], 9.5, dark, Enum.Material.Metal, nc)
	maybeYield()
end

-- landmark slots in the far ring (rim top) + which landmark per biome
local LANDMARK_SLOTS = { Vector2.new(55, 292), Vector2.new(292, -55), Vector2.new(0, -292), Vector2.new(-292, 60) }
local DESERT_RIM_SLOTS = {
	{ pos = Vector2.new(55, 296), fn = foundryTower }, -- S
	{ pos = Vector2.new(248, 224), fn = desertWalkerFrame }, -- SE
	{ pos = Vector2.new(304, -55), fn = desertSiloCluster }, -- E
	{ pos = Vector2.new(236, -242), fn = desertGantryCrane }, -- NE
	{ pos = Vector2.new(0, -304), fn = desertRefineryStacks }, -- N
	{ pos = Vector2.new(-236, -238), fn = mesaArch }, -- NW
	{ pos = Vector2.new(-302, 58), fn = desertGantryCrane }, -- W
	{ pos = Vector2.new(-232, 232), fn = desertSiloCluster }, -- SW
}
local BIOME_LANDMARKS: { [string]: { (Instance, number, number, number) -> () } } = {
	desert = { mesaArch, spireGroup },
	ash = { crashedCruiser, spireGroup },
	swamp = { mesaArch, spireGroup },
	ice = { iceCrystals, crashedCruiser },
	crystal = { iceCrystals, spireGroup },
}

local function buildLandmarks(parent: Instance, faction: string)
	if biomeName == "desert" then
		for i, entry in DESERT_RIM_SLOTS do
			local slot = entry.pos
			local fn = entry.fn
			if i == 1 and faction == "BROOD" then
				fn = hiveSpire
			elseif i == 1 and faction == "LUMEN" then
				fn = crystalSpire
			end
			local yaw = math.atan2(slot.X, slot.Y) + rng:NextNumber(-0.18, 0.18) -- local -Z faces map centre
			local ok, err = pcall(fn, parent, slot.X, slot.Y, yaw)
			if not ok then
				warn("[Map] landmark failed:", err)
			end
			task.wait()
		end
		return
	end
	local list: { (Instance, number, number, number) -> () } = { if faction == "BROOD" then hiveSpire elseif faction == "LUMEN" then crystalSpire else foundryTower }
	for _, f in BIOME_LANDMARKS[biomeName] or BIOME_LANDMARKS.desert do
		table.insert(list, f)
	end
	local start = rng:NextInteger(0, 3)
	for i, fn in list do
		local slot = LANDMARK_SLOTS[(start + i - 1) % #LANDMARK_SLOTS + 1]
		local yaw = math.atan2(slot.X, slot.Y) + rng:NextNumber(-0.25, 0.25) -- local -Z faces the map centre
		local ok, err = pcall(fn, parent, slot.X, slot.Y, yaw)
		if not ok then
			warn("[Map] landmark failed:", err)
		end
		task.wait()
	end
end

-- Place a single skyline rock mesh at (x, baseY, z), sunk slightly so its base sits behind the rim cliffs.
local function placeSkylineMesh(parent: Instance, key: string, x: number, z: number, scale: number, baseY: number, tint: Color3): boolean
	local m = Assets.get(key, { anchored = true })
	if not m then
		return false
	end
	m:ScaleTo(scale)
	local h = (Assets.size(key) or Vector3.new(30, 45, 30)).Y * scale
	m:PivotTo(CFrame.new(x, baseY - h * rng:NextNumber(0.1, 0.3), z) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0))
	local col = spireShade(tint)
	for _, p in m:GetChildren() do
		if p:IsA("BasePart") then
			p.Color = col
			p.Material = B.rockMat
			keepMat(p)
			p.CanCollide = false
			p.CanQuery = false
			p.CastShadow = false
			partCount += 1
		end
	end
	m.Parent = parent
	return true
end

-- Part fallback for a desert skyline cluster when meshes are unavailable: 2-3 overlapping rounded domes.
local function desertSkylineBlobs(parent: Instance, x: number, z: number, hMain: number, tint: Color3, baseY: number)
	local n = rng:NextInteger(2, 3)
	local fan = rng:NextNumber(0, TAU)
	for i = 1, n do
		local a = fan + (if n > 1 then (i - 1) / (n - 1) * TAU else 0) + rng:NextNumber(-0.4, 0.4)
		local off = if i == 1 then 0 else rng:NextNumber(0.25, 0.45) * hMain
		local h = hMain * (if i == 1 then rng:NextNumber(0.7, 1.0) else rng:NextNumber(0.4, 0.7))
		local w = h * rng:NextNumber(1.0, 1.5)
		local d = h * rng:NextNumber(0.85, 1.3)
		local cf = CFrame.new(x + math.cos(a) * off, baseY + h * 0.2, z + math.sin(a) * off) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0)
		local b = blob(parent, Vector3.new(w, h * 1.4, d), cf, spireShade(jitter(tint, 0.06)), B.rockMat, false)
		keepMat(b)
		b.CanQuery = false
		b.CastShadow = false
	end
end

-- Desert skyline outcrop: 2-4 varied sandstone rock meshes clustered around (x, z), with a rounded blob fallback.
local function desertSkylineCluster(parent: Instance, x: number, z: number, hMain: number, tint: Color3, baseY: number)
	local n = rng:NextInteger(2, 4)
	local fan = rng:NextNumber(0, TAU)
	local placed = 0
	local cliffUsed = false
	for i = 1, n do
		local k = DESERT_SKYLINE_KEYS[rng:NextInteger(1, #DESERT_SKYLINE_KEYS)]
		if k == "desert_cliff" then
			if cliffUsed then
				k = DESERT_SKYLINE_KEYS[rng:NextInteger(1, 3)]
			else
				cliffUsed = true
			end
		end
		local a = fan + (if n > 1 then (i - 1) / (n - 1) * TAU else 0) + rng:NextNumber(-0.45, 0.45)
		local off = if i == 1 then 0 else rng:NextNumber(0.28, 0.55) * hMain
		local targetH = hMain * (if i == 1 then rng:NextNumber(0.65, 0.95) else rng:NextNumber(0.35, 0.7))
		local sz = Assets.size(k)
		local pieceScale = targetH / (if sz then sz.Y else 10)
		if placeSkylineMesh(parent, k, x + math.cos(a) * off, z + math.sin(a) * off, pieceScale, baseY, jitter(tint, 0.06)) then
			placed += 1
		end
	end
	if placed == 0 then
		desertSkylineBlobs(parent, x, z, hMain, tint, baseY)
	end
	maybeYield()
end

-- giant spires beyond the boundary, standing behind the cliffs: pure silhouette
local function farMountains(parent: Instance)
	-- two rings: tall spires (mesh) and broad low massifs between them, at different distances and heights, so the
	-- silhouettes overlap and the haze fades them in layers instead of one flat band
	local n = 26
	for i = 1, n do
		local a = (i + rng:NextNumber(-0.4, 0.4)) / n * TAU
		local d = rng:NextNumber(370, 600)
		local x, z = math.cos(a) * d, math.sin(a) * d
		local s = rng:NextNumber(2.6, 7.4)
		local key = "env_spire_b"
		if biomeName == "desert" then
			key = "desert_butte"
			s *= BUTTE_SCALE * 0.6 -- flat-topped buttes have far more mass than the pointed crags: smaller on the skyline
		end
		local tint = rockTint()
		if i % 2 == 0 then -- every other slot: a sandstone cluster (desert) or round stone clump (other biomes)
			if biomeName == "desert" then
				desertSkylineCluster(parent, x, z, 10 * s, tint, 38 + rng:NextNumber(0, 14))
			else
				stoneClump(parent, x, z, s * 0.55, tint, 38 + rng:NextNumber(0, 14), false)
			end
			continue
		end
		if not placeSkylineMesh(parent, key, x, z, s, 52, tint) then
			if biomeName == "desert" then
				desertSkylineCluster(parent, x, z, 10 * s, tint, 42)
			else
				stoneStack(parent, x, z, 60 * s, 14 * s, tint, false, 42)
			end
		end
		maybeYield()
	end
	-- massifs: on desert, bold stepped flat-topped dark sandstone mesa walls (Band 2 graphic silhouettes);
	-- other biomes keep overlapping rounded domes
	if biomeName == "desert" then
		local nc = { CanCollide = false, CanQuery = false, CastShadow = false }
		for i = 1, 18 do
			local a = (i + rng:NextNumber(-0.35, 0.35)) / 18 * TAU
			local d = rng:NextNumber(355, 510)
			local w = rng:NextNumber(115, 200)
			local hgt = rng:NextNumber(88, 165)
			local depth = rng:NextNumber(52, 90)
			local tint = spireShade(rockTint())
			local spanYaw = a + math.pi / 2 + rng:NextNumber(-0.25, 0.25)
			local baseCF = CFrame.new(math.cos(a) * d, 0, math.sin(a) * d) * CFrame.Angles(0, spanYaw, 0)
			local lowerH = hgt * 0.62
			local s1 = part(parent, Vector3.new(w, lowerH, depth), baseCF * CFrame.new(0, lowerH / 2 - 4, 0), tint, B.rockMat, nc)
			keepMat(s1)
			local s2 = part(parent, Vector3.new(w * rng:NextNumber(0.62, 0.78), hgt - lowerH + 6, depth * 0.72), baseCF * CFrame.new(rng:NextNumber(-w * 0.12, w * 0.12), lowerH + (hgt - lowerH) / 2 - 4, 0), jitter(tint, 0.06), B.rockMat, nc)
			keepMat(s2)
			if i % 3 == 0 then
				local s3 = part(parent, Vector3.new(w * 0.36, hgt * 0.24, depth * 0.52), baseCF * CFrame.new(rng:NextNumber(-w * 0.16, w * 0.16), hgt + hgt * 0.08, 0), jitter(tint, 0.08), B.rockMat, nc)
				keepMat(s3)
			end
			maybeYield()
		end
		return
	end
	for i = 1, 22 do
		local a = (i + rng:NextNumber(-0.45, 0.45)) / 22 * TAU
		local d = rng:NextNumber(340, 480)
		local w = rng:NextNumber(90, 190)
		local hgt = rng:NextNumber(70, 170)
		local depth = rng:NextNumber(60, 110)
		local tint = rockTint()
		local spanYaw = a + math.pi / 2 + rng:NextNumber(-0.4, 0.4)
		local span = CFrame.Angles(0, spanYaw, 0)
		local centre = Vector3.new(math.cos(a) * d, 0, math.sin(a) * d)
		local pieces = rng:NextInteger(3, 5)
		for k = 1, pieces do
			local f = (k - 0.5) / pieces - 0.5 -- -0.5 .. 0.5 along the span
			local top = hgt * rng:NextNumber(0.55, 1.05) * (1 - 0.5 * math.abs(f) * 2 * rng:NextNumber(0.3, 1)) -- crest height above y = 0
			local pw = w / pieces * rng:NextNumber(1.3, 2.0)
			local pd = depth * rng:NextNumber(0.5, 0.95)
			local at = centre + span * Vector3.new(f * w, 0, rng:NextNumber(-0.3, 0.3) * depth)
			local cf = CFrame.new(at.X, 0, at.Z) * span * CFrame.Angles(0, rng:NextNumber(-0.5, 0.5), 0) -- the dome's crest is at y = top
			local b = blob(parent, Vector3.new(pw, top * 2, pd), cf, jitter(tint, 0.1), B.rockMat, false)
			b.CastShadow = false
			if biomeName == "desert" then
				keepMat(b)
			end
		end
		maybeYield()
	end
end

-- ---------------------------------------------------------------- lighting
local lightingSaved: { [string]: any }? = nil
local LIGHTING_PROPS = { "Ambient", "OutdoorAmbient", "Brightness", "ClockTime", "GeographicLatitude", "ColorShift_Top", "ColorShift_Bottom", "EnvironmentDiffuseScale", "EnvironmentSpecularScale", "ExposureCompensation", "GlobalShadows", "ShadowSoftness", "FogEnd", "FogColor" }

local LIGHT_FX = { Sky = true, Atmosphere = true, BloomEffect = true, ColorCorrectionEffect = true, SunRaysEffect = true, DepthOfFieldEffect = true, BlurEffect = true }
local function clearLightingFx()
	-- remove every sky/post effect (ours from the map AND the ship's) so only one set is active
	for _, c in Lighting:GetChildren() do
		if c:GetAttribute("OrbitfallMap") or c:GetAttribute("OrbitfallShip") or LIGHT_FX[c.ClassName] then
			c:Destroy()
		end
	end
end

local function clearClouds()
	for _, c in Workspace.Terrain:GetChildren() do
		if c:IsA("Clouds") then
			c:Destroy()
		end
	end
end

-- Searches latitude/clock for the sun direction below.
-- Sun BEHIND-RIGHT of the drop-in view (players land facing +X/+Z) and ~45 degrees up: the scene is front/side lit, rocks
-- and cliffs get a lit side and a shadow side, and nobody stares into a low sun (the old low backlit sun was all glare).
-- Not lower or further left: the insertion corner then sits in the edge cliffs' shadow (sun-ray sweep: 4% of the landing
-- zone lit at -X / 30 degrees, ~91% at this angle, ~85% of the whole map).
local SUN_DIR = Vector3.new(0.259, 0, -0.966)
local SUN_ELEV = 0.707

local function alignSun(m: { [string]: any })
	local target = SUN_DIR
	local bestScore, bestLat, bestClock = -math.huge, 35, m.clock
	local seen: { [string]: boolean } = {}
	local ok = pcall(function()
		for lat = -60, 60, 5 do
			for clk = 5, 19, 0.2 do
				Lighting.GeographicLatitude = lat
				Lighting.ClockTime = clk
				local d = Lighting:GetSunDirection()
				seen[string.format("%.2f,%.2f,%.2f", d.X, d.Y, d.Z)] = true
				local hm = Vector3.new(d.X, 0, d.Z)
				local align = if hm.Magnitude > 0.02 then hm.Unit:Dot(target) else 0
				local score = align - math.abs(d.Y - SUN_ELEV) * 4 - (if d.Y < 0.05 then 3 else 0)
				if score > bestScore then
					bestScore, bestLat, bestClock = score, lat, clk
				end
			end
		end
	end)
	local distinct = 0
	for _ in seen do
		distinct += 1
	end
	if not ok or distinct < 3 then -- GetSunDirection unavailable: keep the authored time
		Lighting.GeographicLatitude = 35
		Lighting.ClockTime = m.clock
		return
	end
	Lighting.GeographicLatitude = bestLat
	Lighting.ClockTime = bestClock
end

local function applyLighting(faction: string, biome: string)
	if not lightingSaved then
		lightingSaved = {}
		for _, k in LIGHTING_PROPS do
			(lightingSaved :: any)[k] = (Lighting :: any)[k]
		end
	end
	clearLightingFx()
	clearClouds()
	local m = B.mood
	Lighting.Brightness = m.bright
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = m.envDiffuse or 0.25 -- low: shadows keep the biome hue and stay dark and contrasty
	Lighting.EnvironmentSpecularScale = 0.5
	Lighting.ExposureCompensation = m.expo + 0.15 -- a touch brighter: the old grade was dim and muddy
	Lighting.Ambient = m.amb
	Lighting.OutdoorAmbient = m.out
	Lighting.ColorShift_Top = m.top
	Lighting.ColorShift_Bottom = m.bottom
	alignSun(m)
	pcall(function()
		Lighting.ShadowSoftness = m.shadowSoft or 0.15
	end)
	local function tag(i: Instance)
		i:SetAttribute("OrbitfallMap", true)
		i.Parent = Lighting
	end
	-- spectacle pass: dustier, warmer air in every biome (density floor 0.35, +haze, atmosphere colour nudged toward warm dust);
	-- desert uses its own clear amber-orange atmosphere directly so distant landmarks stay readable and never turn olive
	local DUST_WARM = RGB(214, 170, 124)
	local HAZE_WARM = { desert = 0, ash = 0.14, swamp = 0.12, ice = 0.1, crystal = 0.06 }
	local HAZE_EXTRA = { desert = 0, ash = 0.9, swamp = 1.0, ice = 0.8, crystal = 0.8 }
	local atm = Instance.new("Atmosphere")
	if biome == "desert" then
		atm.Density = m.atmDensity
		atm.Offset = m.atmOffset
		atm.Haze = m.haze
		atm.Glare = m.glare or 0
		atm.Color = m.atm
		atm.Decay = m.decay
		Lighting.FogColor = m.atm
	else
		atm.Density = math.max(m.atmDensity, 0.35)
		atm.Offset = m.atmOffset
		atm.Haze = math.min(m.haze + (HAZE_EXTRA[biome] or 0.9), 6)
		-- lighter dust than the first pass, so rocks, cliffs and props read at range (thick haze turned everything to mush),
		-- and no sun glare in the air
		atm.Density *= 0.8
		atm.Haze *= 0.6
		atm.Glare = 0
		atm.Color = m.atm:Lerp(DUST_WARM, HAZE_WARM[biome] or 0.12)
		atm.Decay = m.decay
	end
	tag(atm)
	local sky = Instance.new("Sky")
	sky.StarCount = m.stars
	sky.CelestialBodiesShown = true
	sky.SunAngularSize = m.sun
	sky.MoonAngularSize = 9
	tag(sky)
	local cc = Instance.new("ColorCorrectionEffect")
	cc.TintColor = m.tint
	cc.Saturation = if biome == "desert" then m.sat * 0.7 else m.sat * 0.5
	cc.Contrast = if biome == "desert" then m.contrast * 0.55 else m.contrast * 0.5 -- the old 0.3+ crushed shadows to black once the sun moved off the horizon
	cc.Brightness = 0.02
	tag(cc)
	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = if biome == "desert" then m.bloom * 0.50 else m.bloom * 0.45
	bloom.Size = 40
	bloom.Threshold = if biome == "desert" then 1.15 else 1.5 -- only real light sources / combat emissives bloom, never muted sand
	tag(bloom)
	local rays = Instance.new("SunRaysEffect")
	rays.Intensity = m.rays * 0.25
	rays.Spread = 0.9
	tag(rays)
	local dof = Instance.new("DepthOfFieldEffect") -- soft far blur: makes the horizon feel huge
	dof.FarIntensity = 0.12
	dof.FocusDistance = 80
	dof.InFocusRadius = 90
	dof.NearIntensity = 0
	tag(dof)
	local clouds = Instance.new("Clouds")
	clouds.Cover = m.cloudCover
	clouds.Density = m.cloudDensity
	clouds.Color = m.cloudColor
	clouds:SetAttribute("OrbitfallMap", true)
	clouds.Parent = Workspace.Terrain
end

local function restoreLighting()
	clearLightingFx()
	clearClouds()
	if lightingSaved then -- the sun search changes the latitude; Ship.applyLighting does not reset it
		pcall(function()
			Lighting.GeographicLatitude = (lightingSaved :: any).GeographicLatitude
		end)
	end
	if S and S.Ship and S.Ship.applyLighting then
		S.Ship.applyLighting()
	elseif lightingSaved then
		for k, v in lightingSaved do
			pcall(function()
				(Lighting :: any)[k] = v
			end)
		end
	end
end

-- ---------------------------------------------------------------- build
local function setTerrainColors()
	local t = Workspace.Terrain
	for mat, col in B.terrain do
		pcall(t.SetMaterialColor, t, mat, col)
	end
	-- roads: crisp compacted concrete/asphalt value separation on desert; rock-blended elsewhere
	if biomeName == "desert" then
		pcall(t.SetMaterialColor, t, ROAD_MAT, RGB(96, 92, 86))
		pcall(t.SetMaterialColor, t, OLD_ROAD_MAT, RGB(74, 72, 68))
	else
		local road = B.rocks[1]:Lerp(RGB(176, 168, 158), 0.45)
		pcall(t.SetMaterialColor, t, ROAD_MAT, road)
		pcall(t.SetMaterialColor, t, OLD_ROAD_MAT, road:Lerp(RGB(70, 68, 66), 0.35))
	end
end

function MapBuilder.init(registry: any)
	S = registry
end

-- which crash site this mission uses: random, except in Studio where the workspace attribute QuickStartCrash
-- ("SW" | "S" | "W") picks one
local function pickCrash(): string
	local list = MapPlan.crashes
	local pick = list[Random.new():NextInteger(1, #list)].name
	if RunService:IsStudio() then
		local o = Workspace:GetAttribute("QuickStartCrash")
		if type(o) == "string" then
			for _, c in list do
				if c.name == o then
					pick = o
				end
			end
		end
	end
	return pick
end

-- Studio test arena (World/TestArena.luau): a biome's terrain colours + sky/lighting WITHOUT building the map.
-- MapBuilder.clear() restores the ship lighting afterwards, exactly as for a real map.
function MapBuilder.applyBiomeLook(biome: string?, faction: string?)
	biomeName = if biome and BIOMES[biome] then biome else "desert"
	B = BIOMES[biomeName]
	ROCK_KEYS = if biomeName == "desert" then DESERT_ROCK_KEYS else OLD_ROCK_KEYS
	setTerrainColors()
	applyLighting(if faction == "BROOD" or faction == "LUMEN" then faction else "COG", biomeName)
end

function MapBuilder.clear()
	local m = Workspace:FindFirstChild("Map")
	if m then
		m:Destroy()
	end
	Workspace.Terrain:Clear()
	restoreLighting()
	if S and S.Ship and S.Ship.setBackdrop then
		S.Ship.setBackdrop(true)
	end
	MapBuilder.current = nil
end

function MapBuilder.build(faction: string?, biome: string?): any
	local fac = if faction == "BROOD" or faction == "LUMEN" then faction else "COG"
	MapBuilder.clear()
	partCount, opsSinceYield, lightCount, crystalCount = 0, 0, 0, 0
	blinkers = {}
	rng = Random.new(1337)
	local t0 = os.clock()

	-- biome: planet hint, else faction default
	biomeName = if biome and BIOMES[biome] then biome else (if fac == "BROOD" then "swamp" elseif fac == "LUMEN" then "crystal" else "desert")
	B = BIOMES[biomeName]
	ROCK_KEYS = if biomeName == "desert" then DESERT_ROCK_KEYS else OLD_ROCK_KEYS

	-- make sure the meshes had their chance (normally long finished); anything still missing uses the part fallbacks
	Assets.waitAll(6)

	-- the Halcyon hangs in the sky: make sure the ship (hull) exists, hide the lobby planet backdrop
	if S and S.Ship then
		if not Workspace:FindFirstChild("Ship") and S.Ship.build then
			pcall(S.Ship.build)
		end
		if S.Ship.setBackdrop then
			S.Ship.setBackdrop(false)
		end
	end

	local folder = Instance.new("Folder")
	folder.Name = "Map"
	folder:SetAttribute("Biome", biomeName)
	folder:SetAttribute("Faction", fac)
	folder.Parent = Workspace
	local props = Instance.new("Folder")
	props.Name = "Props"
	props.Parent = folder
	local dressing = Instance.new("Folder")
	dressing.Name = "Dressing"
	dressing.Parent = folder
	local landmarks = Instance.new("Folder")
	landmarks.Name = "Landmarks"
	landmarks.Parent = folder

	-- the layout: one of the three crash sites per mission (its own random stream, so the map's fixed seed does not
	-- always give the same one), everything else straight from MapPlan
	applyLayout(pickCrash())
	planCraters(if biomeName == "ash" then 7 else 4)

	-- flatten pads (the crash gets a shallow scorched bowl with a low lip; the mesa and the quarry are shaped in heightAt)
	flats = {}
	for name, pad in PADS do
		local c = LAYOUT[name]
		local h = math.max(rawH(c.X, c.Y), 7)
		if name == "insertion" then
			flats[#flats + 1] = { x = c.X, z = c.Y, inner = pad[1], outer = pad[2], h = math.max(h - 3, 5), rim = 1.2 }
		else
			flats[#flats + 1] = { x = c.X, z = c.Y, inner = pad[1], outer = pad[2], h = h }
		end
	end
	computeShapes()
	setTerrainColors()
	pcall(function()
		-- no realistic grass blades: they clash with the flat-colour props
		Workspace.Terrain.Decoration = false
	end)
	applyLighting(fac, biomeName)

	-- terrain, chunk by chunk
	local chunkSide = CHUNK * VOX
	local n = SIZE // chunkSide
	for a = 0, n - 1 do
		for b = 0, n - 1 do
			writeChunk(-HALF + a * chunkSide, -HALF + b * chunkSide, CHUNK)
			task.wait()
		end
	end

	-- groundY: raycast against terrain, analytic fallback
	terrainParams.FilterDescendantsInstances = { Workspace.Terrain }
	groundY = function(x: number, z: number): number
		local r = Workspace:Raycast(Vector3.new(x, TOP + 90, z), Vector3.new(0, -(TOP + 190), 0), terrainParams)
		if r then
			return r.Position.Y
		end
		return heightAt(x, z)
	end

	-- safety check: no site may sit next to the edge cliffs
	for name, pad in PADS do
		local c = LAYOUT[name]
		local base = groundY(c.X, c.Y)
		local radius = pad[2] or 30
		local bad = false
		for i = 0, 7 do
			local a = i / 8 * TAU
			local gy = groundY(c.X + math.cos(a) * radius, c.Y + math.sin(a) * radius)
			if gy - base > 12 then
				bad = true
				break
			end
		end
		if bad then
			warn(`[Map] site {name} near cliff`)
		end
	end

	-- terrain accents: lava cracks (ash/desert) and rounded boulders
	local terrain = Workspace.Terrain
	-- ash: small irregular CrackedLava patches (cylinder core + a few blobs) with a dim orange light, never flat discs
	local emberHosts = 0
	local function lavaPatch(x: number, z: number, r: number)
		local g = groundY(x, z)
		terrain:FillCylinder(CFrame.new(x, g - 1.1, z), 2.4, r, Enum.Material.CrackedLava)
		for _ = 1, 4 do
			local a, d, br = rng:NextNumber(0, TAU), r * rng:NextNumber(0.5, 0.9), r * rng:NextNumber(0.35, 0.55)
			local bx, bz = x + math.cos(a) * d, z + math.sin(a) * d
			terrain:FillBall(Vector3.new(bx, groundY(bx, bz) - br * 0.8, bz), br, Enum.Material.CrackedLava)
		end
		local host = emitterHost(props, Vector3.new(x, g + 3, z))
		pointLight(host, RGB(255, 120, 50), 16, 1.5)
		if emberHosts < 2 then -- embers drift up from the first two patches
			emberHosts += 1
			embers(host)
		end
		maybeYield()
	end
	if biomeName == "ash" then
		for _, c in craters do
			lavaPatch(c.x, c.z, math.clamp(c.r * 0.3, 5, 9))
		end
		for _ = 1, 3 do
			local x, z = wildSpot(60, 20, 250)
			lavaPatch(x, z, rng:NextNumber(4, 6))
		end
	end
	if biomeName == "ash" then
		-- lava cracks: zig-zag chains of short blocks (direction wanders +-35 degrees), ash biome only
		for _ = 1, 10 do
			local x, z = wildSpot(60, 20, 250)
			local dir = rng:NextNumber(0, TAU)
			for _ = 1, 4 do
				local len = rng:NextNumber(8, 16)
				local g = groundY(x, z)
				terrain:FillBlock(CFrame.new(x, g - 1, z) * CFrame.Angles(0, -dir, 0), Vector3.new(len, 2.4, rng:NextNumber(1.6, 3)), Enum.Material.CrackedLava)
				x += math.cos(dir) * len * 0.85
				z += math.sin(dir) * len * 0.85
				dir += math.rad(rng:NextNumber(-35, 35))
			end
		end
	end
	task.wait()

	-- sites
	for name in LAYOUT do
		dressSite(props, name, fac)
		task.wait()
	end

	-- rock clusters in 3 sizes (art rule 5): grouped, off the combat lanes (cleaner, bolder outcrops on desert)
	local isDesert = biomeName == "desert"
	for _ = 1, if isDesert then 24 else 38 do
		local x, z = wildSpot(34, if isDesert then 18 else 14, 262)
		if rng:NextNumber() > areaWeight(x, z, "rock") then
			continue -- the rocky north gets most of them, the dune south and the salt east few
		end
		local big = rng:NextNumber() < 0.4
		local count = if isDesert
			then (if big then rng:NextInteger(3, 4) else rng:NextInteger(1, 2))
			else (if big then rng:NextInteger(5, 8) else rng:NextInteger(2, 4))
		for i = 1, count do
			local a, d = rng:NextNumber(0, TAU), if i == 1 then 0 else rng:NextNumber(4, if big then 16 else 10)
			local rx, rz = x + math.cos(a) * d, z + math.sin(a) * d
			if not inLane(rx, rz, if isDesert then 12 else 8) and farFromSites(rx, rz, 30) then
				local s = if isDesert
					then (if i == 1 and big then rng:NextNumber(1.8, 2.6) else rng:NextNumber(1.15, 1.8))
					elseif i == 1 and big then rng:NextNumber(1.6, 2.5)
					elseif i == 1 then rng:NextNumber(1.0, 1.6)
					else rng:NextNumber(0.6, 1.3)
				rock(props, rx, rz, s)
			end
		end
	end
	-- pebbles around the clusters and along the edges of the lanes (zero on desert for clean floor readability)
	if not isDesert then
		for _ = 1, 60 do -- (the rubble field below carries the dense scatter)
			local x, z = randomSpot(16, 62)
			pebble(props, x, z)
		end
	end
	-- mid-ring spires / mesas: landmarks you walk around
	for _ = 1, 14 do
		local a = rng:NextNumber(0, TAU)
		local d = rng:NextNumber(185, 290)
		local x, z = math.clamp(math.cos(a) * d, -272, 272), math.clamp(math.sin(a) * d, -272, 272)
		if farFromSites(x, z, 70) and not inLane(x, z, 30) then
			spire(props, x, z, rng:NextNumber(0.9, 2.1))
		end
	end
	-- crystal clusters (crystal biome only)
	if biomeName == "crystal" then
		for _ = 1, 12 do
			local x, z = wildSpot(40, 18, 258)
			crystals(props, x, z, rng:NextNumber(0.8, 2.0))
		end
	end
	-- broken wall lines (round stone drums, never slabs)
	for _ = 1, 6 do
		local x, z = wildSpot(36, 16, 270)
		ruinedWall(props, x, z, rng:NextNumber(0, math.pi), rng:NextNumber(8, 14))
	end
	-- alien / dry plants (skipped on desert: zero ankle-high tuft noise)
	if not isDesert then
		for _ = 1, if biomeName == "swamp" then 50 else 24 do
			local x, z = wildSpot(14, 6, 262)
			if rng:NextNumber() < areaWeight(x, z, "shrub") then
				plant(dressing, x, z)
				maybeYield()
			end
		end
	end

	if fac == "BROOD" then
		dressBrood(dressing)
	elseif fac == "LUMEN" then
		dressLumen(dressing)
	else
		dressCog(dressing)
	end
	if isDesert then
		desertSightlines(props, dressing)
	end

	-- environmental storytelling: wreck fields, lane-edge rock clusters + shrub clumps, biome extras, rim smoke, dust devils
	battlefield(dressing, fac)
	natureSet(props, dressing)
	atmosphere(dressing, fac)
	rubbleField(dressing)
	if #blinkers > 0 then
		local list = blinkers
		task.spawn(function() -- one loop blinks every signal mast lamp (two phases); ends when the map is destroyed
			local phase = false
			while folder.Parent do
				phase = not phase
				for i, pair in list do
					local on = (i % 2 == 1) == phase
					pair[1].Enabled = on
					pair[2].Transparency = if on then 0 else 0.75
				end
				task.wait(0.7)
			end
		end)
	end

	-- landmarks (60-200 studs) + silhouettes beyond the cliffs
	buildLandmarks(landmarks, fac)
	farMountains(landmarks)

	-- invisible boundary walls
	local walls = Instance.new("Folder")
	walls.Name = "Walls"
	walls.Parent = folder
	local wl = SIZE + 24
	for _, d in { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
		local w = Instance.new("Part")
		w.Name = "BoundaryWall"
		w.Anchored = true
		w.Transparency = 1
		w.CanQuery = false
		w.CanTouch = false
		w.CastShadow = false
		w.Size = if d[1] == 0 then Vector3.new(wl, 400, 6) else Vector3.new(6, 400, wl)
		w.CFrame = CFrame.new(d[1] * (HALF + 2), 150, d[2] * (HALF + 2))
		w.Parent = walls
	end

	-- build the Map table
	local sites: { [string]: CFrame } = {}
	for name, v in LAYOUT do
		if name ~= "insertion" and name ~= "extraction" then
			local p = onGround(v.X, v.Y)
			sites[name] = CFrame.lookAt(p, Vector3.new(0, p.Y, 0))
		end
	end
	local ins = onGround(LAYOUT.insertion.X, LAYOUT.insertion.Y, 0.5)
	local refineryAt = MapPlan.places.refinery.at
	local insertion = CFrame.lookAt(ins, Vector3.new(refineryAt.X, ins.Y, refineryAt.Y)) -- the squad lands facing the refinery
	local ex = LAYOUT.extraction
	local extraction = onGround(ex.X, ex.Y)
	-- ground positions of the places (and the crash / spilled cell) for the set pieces and the missions
	local placePos: { [string]: Vector3 } = {}
	for name, p in MapPlan.places do
		placePos[name] = onGround(p.at.X, p.at.Y)
	end
	placePos.spilled = onGround(LAYOUT.codes.X, LAYOUT.codes.Y)
	placePos.crash = onGround(LAYOUT.insertion.X, LAYOUT.insertion.Y)
	-- measurements of the two shaped places (nominal heights; groundY is the real surface)
	local shapeInfo: { [string]: any } = {}
	if mesa then
		local m = mesa :: Mesa
		shapeInfo.mesa = {
			topY = m.top, topRadius = m.rt, footRadius = m.ro,
			rampDir = Vector3.new(m.dx, 0, m.dz), rampWidth = 12, rampSlope = m.slope,
			rampTop = Vector3.new(m.x + m.dx * (m.rt - 2), m.top, m.z + m.dz * (m.rt - 2)), -- where the ramp leaves the flat top
			rampFoot = onGround(m.x + m.dx * m.rampEnd, m.z + m.dz * m.rampEnd),
		}
	end
	if quarry then
		local q = quarry :: Quarry
		local terraces: { { y: number, rIn: number, rOut: number } } = {}
		local edge = q.r
		for i = 1, 3 do
			table.insert(terraces, { y = q.g - q.levels[i], rIn = edge - q.rw - q.tw, rOut = edge - q.rw })
			edge -= q.rw + q.tw
		end
		shapeInfo.quarry = {
			rimY = q.g, floorY = q.g - q.depth, floorRadius = edge - q.rw, rimRadius = q.r, terraces = terraces,
			rampDir = Vector3.new(q.dx, 0, q.dz), rampWidth = 12,
			rampTop = onGround(q.x + q.dx * q.r, q.z + q.dz * q.r), -- the rim end of the ramp
			rampFoot = Vector3.new(q.x + q.dx * (q.r - 4 * q.rw - 3 * q.tw), q.g - q.depth, q.z + q.dz * (q.r - 4 * q.rw - 3 * q.tw)),
		}
	end

	-- patrol points: around sites + scattered, on gentle ground
	local patrol: { Vector3 } = {}
	local function gentle(x: number, z: number): boolean
		local g = groundY(x, z)
		return math.abs(groundY(x + 6, z) - g) < 3 and math.abs(groundY(x, z + 6) - g) < 3
	end
	local patrolBases = { "codes", "generator", "console", "silo", "uplink", "nest1", "nest2", "nest3", "nest4", "samples1", "samples2", "samples3" }
	for _, name in patrolBases do
		local c = LAYOUT[name]
		local ring = math.max(KEEPOUT[name] or 0, 28) -- patrols walk just outside a place, never through its set piece
		for _ = 1, 20 do
			local a = rng:NextNumber(0, TAU)
			local d = rng:NextNumber(ring, ring + 18)
			local x, z = c.X + math.cos(a) * d, c.Y + math.sin(a) * d
			if math.abs(x) < 250 and math.abs(z) < 250 and farFromSites(x, z, 0) and gentle(x, z) then
				patrol[#patrol + 1] = onGround(x, z, 1)
				break
			end
		end
	end
	local guard = 0
	while #patrol < 22 and guard < 200 do
		guard += 1
		local x, z = rng:NextNumber(-248, 248), rng:NextNumber(-248, 248)
		local di = Vector2.new(x, z) - LAYOUT.insertion
		if di.Magnitude > 90 and farFromSites(x, z, 0) and gentle(x, z) then
			patrol[#patrol + 1] = onGround(x, z, 1)
		end
	end

	-- spawn points: along the foot of the cliffs, behind a rock
	local spawns: { Vector3 } = {}
	guard = 0
	while #spawns < 16 and guard < 400 do
		guard += 1
		local t = (#spawns + rng:NextNumber(0, 0.9)) / 16 * 4
		local side, f = math.floor(t) % 4, (t % 1) * 2 - 1
		local edge = rng:NextNumber(232, 248)
		local x, z
		if side == 0 then
			x, z = f * 245, -edge
		elseif side == 1 then
			x, z = edge, f * 245
		elseif side == 2 then
			x, z = -f * 245, edge
		else
			x, z = -edge, -f * 245
		end
		if (Vector2.new(x, z) - LAYOUT.insertion).Magnitude > 120 and farFromSites(x, z, 0) and gentle(x, z) then
			spawns[#spawns + 1] = onGround(x, z, 1)
			-- cover just outward of the spawn so they emerge from behind it
			local ox, oz = x * 1.06, z * 1.06
			if rng:NextNumber() > 0.4 then
				rock(props, ox, oz, 1.8)
				rock(props, ox + rng:NextNumber(-8, 8), oz + rng:NextNumber(-8, 8), 1.2)
			else
				ruinedWall(props, ox, oz, math.atan2(oz, ox) + math.pi / 2, 16)
			end
		end
	end

	local map = {
		name = "Dustbowl Ridge",
		faction = fac,
		biome = biomeName,
		size = SIZE,
		insertion = insertion,
		extraction = extraction,
		sites = sites,
		patrolPoints = patrol,
		spawnPoints = spawns,
		groundY = groundY,
		folder = folder,
		props = props,
		terrain = Workspace.Terrain,
		crash = MapPlan.crash(crashPick), -- the chosen MapPlan.crashes entry {name, crash, spilled}
		places = placePos, -- ground positions: refinery / mesa / quarry / graveyard / saltpan / spilled / crash
		shapes = shapeInfo, -- the terrain shapes' measurements (mesa top height + ramp, quarry terrace heights + ramp)
		anchors = {} :: { [string]: any },
	}
	MapBuilder.current = map

	-- the set pieces of the five places (World/Places): own file, called once; a failure there must not break the map
	do
		local placesFolder = Instance.new("Folder")
		placesFolder.Name = "Places"
		placesFolder.Parent = folder
		local placesModule = script.Parent:FindFirstChild("Places")
		if placesModule and placesModule:IsA("ModuleScript") then
			local okReq, Places = pcall(require, placesModule)
			if okReq and type(Places) == "table" and type(Places.build) == "function" then
				local objective = S and S.Mission and S.Mission.objective
				local okBuild, anchors = pcall(Places.build, map, placesFolder, objective)
				if okBuild then
					map.anchors = anchors or {}
				else
					warn("[Map] Places.build failed:", anchors)
				end
			elseif not okReq then
				warn("[Map] Places not loaded:", Places)
			end
		end
		-- Desert landmark beacons/accents readable from 200+ studs (cheap: ~1 light or emitter per place)
		if biomeName == "desert" then
			local accents = Instance.new("Folder")
			accents.Name = "PlaceAccents"
			accents.Parent = placesFolder
			local function accentLight(host: BasePart, col: Color3, range: number, brightness: number): PointLight
				local l = Instance.new("PointLight")
				l.Color = col
				l.Range = range
				l.Brightness = brightness
				l.Shadows = false
				l.Parent = host
				return l
			end

			-- 1. Refinery: flare-stack flame and warm orange glow at the top of the chimney
			do
				local refFolder = placesFolder:FindFirstChild("Refinery", true)
				local stack = refFolder and refFolder:FindFirstChild("cog_smokestack")
				local pos = if stack and stack:IsA("Model")
					then stack:GetPivot().Position + Vector3.new(0, 61.5, 0)
					else placePos.refinery + Vector3.new(0, 61.5, 0)
				local flare = decor(accents, Vector3.new(3.8, 5.2, 3.8), CFrame.new(pos), RGB(255, 140, 40), Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
				accentLight(flare, RGB(255, 136, 40), 60, 3.5)
				local pe = Instance.new("ParticleEmitter")
				pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
				pe.Rate = 10
				pe.Lifetime = NumberRange.new(0.7, 1.2)
				pe.Speed = NumberRange.new(12, 18)
				pe.SpreadAngle = Vector2.new(12, 12)
				pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 4.5), NumberSequenceKeypoint.new(0.4, 7.5), NumberSequenceKeypoint.new(1, 1.5) })
				pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.5, 0.35), NumberSequenceKeypoint.new(1, 1) })
				pe.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, RGB(255, 235, 140)),
					ColorSequenceKeypoint.new(0.45, RGB(255, 125, 30)),
					ColorSequenceKeypoint.new(1, RGB(180, 45, 15)),
				})
				pe.LightEmission = 1
				pe.Rotation = NumberRange.new(0, 360)
				pe.RotSpeed = NumberRange.new(-40, 40)
				pe.Parent = flare
			end

			-- 2. Signal Mesa: blinking red beacon flare at the top of the relay mast
			do
				local mastLamp = map.anchors and map.anchors.mastLight
				local host: BasePart
				local fallbackBlink = false
				if mastLamp and typeof(mastLamp) == "Instance" and mastLamp:IsA("BasePart") then
					host = mastLamp
				else
					host = decor(accents, Vector3.new(3.4, 3.4, 3.4), CFrame.new(placePos.mesa + Vector3.new(0, 74, 0)), RGB(255, 45, 35), Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
					accentLight(host, RGB(255, 45, 35), 60, 3.0)
					fallbackBlink = true
				end
				local pe = Instance.new("ParticleEmitter")
				pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
				pe.Rate = 0
				pe.Lifetime = NumberRange.new(0.75, 0.85)
				pe.Speed = NumberRange.new(0, 0)
				pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 14), NumberSequenceKeypoint.new(0.35, 22), NumberSequenceKeypoint.new(1, 0) })
				pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.6, 0.35), NumberSequenceKeypoint.new(1, 1) })
				pe.Color = ColorSequence.new(RGB(255, 65, 45), RGB(255, 30, 20))
				pe.LightEmission = 1
				pe.LockedToPart = true
				pe.Parent = host
				if fallbackBlink then
					task.spawn(function()
						local on = true
						while host.Parent and folder.Parent do
							on = not on
							host.Transparency = if on then 0 else 0.75
							if on then
								pe:Emit(1)
							end
							task.wait(0.9)
						end
					end)
				else
					if host.Transparency < 0.5 then
						pe:Emit(1)
					end
					host:GetPropertyChangedSignal("Transparency"):Connect(function()
						if host.Transparency < 0.5 then
							pe:Emit(1)
						end
					end)
					task.spawn(function()
						while host.Parent and folder.Parent do
							if host:GetAttribute("Alarm") and host.Transparency < 0.5 then
								pe:Emit(1)
							end
							task.wait(0.85)
						end
					end)
				end
			end

			-- 3. Crash site: tall rising smoke column visible across the basin
			do
				local crashFolder = placesFolder:FindFirstChild("CrashedDrone", true)
				local wreck = crashFolder and crashFolder:FindFirstChild("cog_drone_wreck")
				local pos = if wreck and wreck:IsA("Model")
					then wreck:GetPivot().Position + Vector3.new(0, 5, 0)
					else placePos.crash + Vector3.new(0, 5, 0)
				local host = emitterHost(accents, pos)
				local pe = Instance.new("ParticleEmitter")
				pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
				pe.Rate = 3.5
				pe.Lifetime = NumberRange.new(12, 16)
				pe.Speed = NumberRange.new(10, 14)
				pe.SpreadAngle = Vector2.new(6, 6)
				pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 7), NumberSequenceKeypoint.new(0.5, 17), NumberSequenceKeypoint.new(1, 26) })
				pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.55, 0.52), NumberSequenceKeypoint.new(1, 1) })
				pe.Color = ColorSequence.new(RGB(42, 36, 34), RGB(68, 56, 48))
				pe.Rotation = NumberRange.new(0, 360)
				pe.RotSpeed = NumberRange.new(-10, 10)
				pe.Acceleration = Vector3.new(2, 0.8, 1.5)
				pe.LightInfluence = 0.85
				pe.Parent = host
			end

			-- 4. Quarry: pair of warm work lamps standing on opposite sides of the pit rim
			do
				local Q = placePos.quarry
				local qInfo = shapeInfo.quarry
				local rimR = (qInfo and qInfo.rimRadius or 40) + 3
				local rampDir = (qInfo and qInfo.rampDir) or Vector3.xAxis
				local side = Vector3.new(-rampDir.Z, 0, rampDir.X)
				if side.Magnitude < 0.01 then
					side = Vector3.zAxis
				else
					side = side.Unit
				end
				for idx, sgn in { -1, 1 } do
					local lx, lz = Q.X + side.X * sgn * rimR, Q.Z + side.Z * sgn * rimR
					local gy = groundY(lx, lz)
					local poleH = 17
					cyl(accents, 0.9, poleH, CFrame.new(lx, gy + poleH / 2 - 0.5, lz), RGB(56, 58, 64), Enum.Material.Metal, NOCOL)
					local topPos = Vector3.new(lx, gy + poleH - 0.3, lz)
					local lookCF = CFrame.lookAt(topPos, Vector3.new(Q.X, gy - 8, Q.Z))
					local lampHead = decor(accents, Vector3.new(5.5, 2.0, 1.4), lookCF, RGB(255, 242, 200), Enum.Material.Neon, { CastShadow = false })
					if idx == 1 then
						accentLight(lampHead, RGB(255, 232, 180), 60, 3.2)
						local pe = Instance.new("ParticleEmitter")
						pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
						pe.Rate = 1.5
						pe.Lifetime = NumberRange.new(1.5, 2.0)
						pe.Speed = NumberRange.new(0, 0)
						pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 14), NumberSequenceKeypoint.new(0.5, 18), NumberSequenceKeypoint.new(1, 14) })
						pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.4, 0.55), NumberSequenceKeypoint.new(1, 1) })
						pe.Color = ColorSequence.new(RGB(255, 240, 195))
						pe.LightEmission = 1
						pe.LockedToPart = true
						pe.Parent = lampHead
					end
				end
			end

			-- 5. Salt pan: bright sunlit shimmer / glare hovering over the salt flat
			do
				local S = placePos.saltpan
				local host = emitterHost(accents, S + Vector3.new(0, 3.5, 0))
				host.Size = Vector3.new(54, 4, 54)
				local pe = Instance.new("ParticleEmitter")
				pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
				pe.Shape = Enum.ParticleEmitterShape.Box
				pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
				pe.Rate = 4
				pe.Lifetime = NumberRange.new(3.0, 4.5)
				pe.Speed = NumberRange.new(0.5, 1.2)
				pe.SpreadAngle = Vector2.new(12, 12)
				pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 12), NumberSequenceKeypoint.new(0.5, 28), NumberSequenceKeypoint.new(1, 16) })
				pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.35, 0.62), NumberSequenceKeypoint.new(0.65, 0.66), NumberSequenceKeypoint.new(1, 1) })
				pe.Color = ColorSequence.new(RGB(255, 252, 238), RGB(255, 238, 202))
				pe.LightEmission = 1
				pe.Rotation = NumberRange.new(0, 360)
				pe.Parent = host
			end

			-- 6. Walker graveyard: dim cyan core glow inside the walker ribcage
			do
				local G = placePos.graveyard
				local core = decor(accents, Vector3.new(4.4, 4.4, 4.4), CFrame.new(G + Vector3.new(0, 6.5, 0)), RGB(70, 225, 255), Enum.Material.Neon, { Shape = Enum.PartType.Ball, Transparency = 0.2, CastShadow = false })
				accentLight(core, RGB(60, 220, 255), 60, 2.4)
				local pe = Instance.new("ParticleEmitter")
				pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
				pe.Rate = 2.5
				pe.Lifetime = NumberRange.new(3.5, 5.0)
				pe.Speed = NumberRange.new(3, 5)
				pe.SpreadAngle = Vector2.new(18, 18)
				pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 7), NumberSequenceKeypoint.new(0.5, 17), NumberSequenceKeypoint.new(1, 5) })
				pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.35, 0.55), NumberSequenceKeypoint.new(1, 1) })
				pe.Color = ColorSequence.new(RGB(80, 235, 255), RGB(35, 145, 210))
				pe.LightEmission = 1
				pe.Rotation = NumberRange.new(0, 360)
				pe.RotSpeed = NumberRange.new(-15, 15)
				pe.Parent = core
			end
		end
	end
	-- flat colour props in the call-in model style: every textured material (Slate, Sandstone, Metal, Fabric...) becomes
	-- SmoothPlastic
	local flatProps = true
	local KEEP = { [Enum.Material.SmoothPlastic] = true, [Enum.Material.Plastic] = true, [Enum.Material.Neon] = true, [Enum.Material.Glass] = true, [Enum.Material.ForceField] = true }
	local nd = 0
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			if d.Material == Enum.Material.Neon then
				-- lime Neon (slime, goo, spore pods) blooms into flat yellow blobs; pull it to a deep acid green
				local c = d.Color
				if c.G > 0.85 and c.R > 0.4 and c.R < 0.75 and c.B < 0.5 then
					d.Color = RGB(70, 200, 40)
				end
			elseif flatProps and not KEEP[d.Material] and not d:GetAttribute("KeepMat") then
				d.Material = Enum.Material.SmoothPlastic
			end
			nd += 1
			if nd % 800 == 0 then
				task.wait()
			end
		end
	end
	print(string.format("[Map] %s/%s built in %.1fs, %d parts", fac, biomeName, os.clock() - t0, partCount))
	return map
end

-- end of MapBuilder
return MapBuilder
