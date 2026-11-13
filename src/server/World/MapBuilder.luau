-- S.Map: builds the mission map at runtime (docs/art-direction.md v2): shaped terrain + mesh scatter + landmarks + rubble.
--   S.Map.build(faction, biome?) -> Map     (YIELDS: terrain is written in chunks)
--   S.Map.clear()
--   S.Map.current                           the Map table while built, else nil
-- Map = { insertion: CFrame, extraction: Vector3, sites: {[string]: CFrame}, patrolPoints: {Vector3},
--         spawnPoints: {Vector3}, groundY: (x, z) -> number, size, faction, biome, folder, props, terrain }
-- Site CFrames sit ON the ground (y = ground height) and face the map centre.
-- NOTE for enemy ground snapping: all props live in workspace.Map.Props; raycast against `map.terrain`
-- (Terrain only) if you do not want enemies to climb on props.
--
-- Terrain: layered noise (rolling base + ridge lines + terraced mesas + craters), the map edge rises into 60-120 stud
-- cliffs. Features fade out around sites and along the lanes between them, so the combat area stays walkable.
-- Ground storytelling (see the "environmental storytelling" block): wreck fields from enemy meshes, drop-pod husks, shell craters,
-- site camps (sandbags / tarp / floodlight), COG industrial bits, BROOD eggs / webs / tusks, per-biome nature, rim smoke, dust devils.
-- Props: Blender meshes from World/Assets (env_*), tinted per biome. If an asset is not loaded the old part-built
-- (wedge) fallbacks are used, so a failed LoadAsset never breaks a mission. The folder attribute Biome tells clients
-- which ambience to run (client/Fx/Ambience.luau).

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Assets = require(script.Parent.Assets)

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

-- Layout (x, z). Chain: insertion -> codes -> generator -> console -> silo -> extraction.
local LAYOUT: { [string]: Vector2 } = {
	-- every site keeps max(|x|,|z|) + pad inner radius <= 225 so nothing sits under the edge cliffs (rise from ~250)
	insertion = Vector2.new(-178, -178),
	extraction = Vector2.new(180, 185),
	codes = Vector2.new(-110, -110),
	generator = Vector2.new(0, -195),
	console = Vector2.new(170, -100),
	silo = Vector2.new(150, 100),
	leverA = Vector2.new(112, 78),
	leverB = Vector2.new(131, 70),
	uplink = Vector2.new(-190, -20),
	nest1 = Vector2.new(-200, 150),
	nest2 = Vector2.new(-30, 90),
	nest3 = Vector2.new(70, 0),
	nest4 = Vector2.new(205, -190),
	samples1 = Vector2.new(-120, 195),
	samples2 = Vector2.new(20, 200),
	samples3 = Vector2.new(205, 30),
}
-- Sites that get a flattened pad + outpost dressing: name -> {inner, outer}
local PADS: { [string]: { number } } = {
	insertion = { 46, 85 },
	extraction = { 34, 60 },
	codes = { 24, 48 },
	generator = { 26, 50 },
	console = { 24, 48 },
	silo = { 50, 80 },
	uplink = { 26, 50 },
	nest1 = { 18, 40 },
	nest2 = { 18, 40 },
	nest3 = { 18, 40 },
	nest4 = { 18, 40 },
	samples1 = { 12, 30 },
	samples2 = { 12, 30 },
	samples3 = { 12, 30 },
}
-- Combat lanes (kept walkable and mostly clear of big props)
local LANE_PAIRS = {
	{ "insertion", "codes" }, { "codes", "generator" }, { "generator", "console" }, { "console", "silo" },
	{ "silo", "extraction" }, { "insertion", "uplink" }, { "uplink", "codes" }, { "codes", "nest2" },
	{ "nest2", "silo" }, { "console", "samples3" }, { "extraction", "samples3" },
}

local siteList: { { x: number, z: number, inner: number, outer: number } } = {}
for name, pad in PADS do
	local c = LAYOUT[name]
	table.insert(siteList, { x = c.X, z = c.Y, inner = pad[1], outer = pad[2] })
end
local lanes: { { ax: number, az: number, bx: number, bz: number } } = {}
for _, pair in LANE_PAIRS do
	local a, b = LAYOUT[pair[1]], LAYOUT[pair[2]]
	table.insert(lanes, { ax = a.X, az = a.Y, bx = b.X, bz = b.Y })
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
	desert = { -- amber
		terrain = {
			[M.Sand] = RGB(150, 98, 66), [M.Sandstone] = RGB(128, 78, 54), [M.Rock] = RGB(92, 62, 48),
			[M.Basalt] = RGB(60, 44, 38), [M.Ground] = RGB(110, 72, 52), [M.Slate] = RGB(78, 56, 46),
			[M.Grass] = RGB(110, 96, 60), [M.Mud] = RGB(84, 58, 44),
		},
		rocks = { RGB(118, 80, 58), RGB(98, 66, 50), RGB(134, 92, 64) },
		rockMat = M.Sandstone,
		crystal = RGB(220, 150, 90),
		wall = { RGB(127, 104, 77), RGB(114, 92, 69), RGB(99, 81, 62) },
		plant = { RGB(84, 67, 42), RGB(105, 84, 49) },
		smoke = RGB(70, 56, 48),
		mood = { -- gritty backlit hazy sun: low amber disc behind the play area, desaturated high-contrast grade
			clock = 17.3, elev = 0.17, bright = 3.0, expo = -0.15, amb = RGB(46, 36, 32), out = RGB(96, 74, 62),
			top = RGB(255, 206, 150), bottom = RGB(150, 104, 96),
			atmDensity = 0.42, atmOffset = 0.08, haze = 3.2, glare = 2.2, atm = RGB(200, 132, 88), decay = RGB(80, 44, 30),
			tint = RGB(255, 228, 200), sat = -0.18, contrast = 0.35, bloom = 0.55, rays = 0.1, sun = 11, stars = 0,
			cloudCover = 0.75, cloudDensity = 0.6, cloudColor = RGB(150, 96, 70),
			envDiffuse = 0.25, shadowSoft = 0.15,
		},
	},
	ash = { -- charcoal ground under a burning red sky (red lives in sky, haze and lava only)
		terrain = {
			[M.Sand] = RGB(90, 82, 78), [M.Ground] = RGB(72, 66, 64), [M.Basalt] = RGB(58, 54, 54),
			[M.Rock] = RGB(66, 61, 60), [M.Slate] = RGB(72, 66, 64), [M.Sandstone] = RGB(84, 76, 72),
			[M.CrackedLava] = RGB(235, 96, 40), [M.Mud] = RGB(48, 45, 45), [M.Grass] = RGB(70, 66, 60),
		},
		rocks = { RGB(62, 58, 58), RGB(80, 74, 72), RGB(50, 47, 48) },
		rockMat = M.Basalt,
		crystal = RGB(255, 140, 70),
		wall = { RGB(104, 98, 96), RGB(90, 85, 84), RGB(76, 72, 72) },
		plant = { RGB(50, 46, 46), RGB(66, 58, 56) },
		smoke = RGB(52, 46, 46),
		mood = {
			clock = 17.8, elev = 0.17, bright = 2.7, expo = 0.0, amb = RGB(52, 41, 37), out = RGB(83, 62, 55),
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
			[M.Sandstone] = RGB(84, 78, 100), [M.Basalt] = RGB(40, 38, 56),
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
}
-- gritty pass for the non-desert planets (desert is authored dark above): terrain ~25% darker, props ~20%, hue identity kept
do
	local function dim(c: Color3, k: number): Color3
		return Color3.new(c.R * k, c.G * k, c.B * k)
	end
	for name, b in BIOMES do
		if name ~= "desert" then
			local tk = if name == "swamp" then 0.9 else 0.75 -- swamp already sits at dusk; full dimming made it murky
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

local function ridge(n: number): number
	local r = 1 - math.min(1, math.abs(n) * 2.2)
	return r * r
end

local function terrace(v: number): number
	local fl = math.floor(v)
	return fl + smooth((v - fl - 0.78) / 0.22)
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
		if d < 44 then
			local k = smooth((d - 12) / 30)
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
	-- broad rolling base
	local h = 13 + noise(x / 210 + 11.3, z / 210 + 7.7) * 17 + noise(x / 85 + 3.1, z / 85 + 9.9) * 6 + noise(x / 27 + 1.7, z / 27 + 4.2) * 1.4
	local F = featureMask(x, z)
	if F > 0.001 then
		-- ridge lines, only in some regions
		local rm = smooth((noise(x / 300 + 5.3, z / 300 + 2.2) + 0.12) / 0.45)
		if rm > 0 then
			h += ridge(noise(x / 120 + 50.3, z / 90 + 20.1)) * rm * F * 17
		end
		h += ridge(noise(x / 52 + 8.8, z / 40 + 3.3)) * F * 3.5
		-- terraced mesas (quantised steps)
		local t = (noise(x / 190 + 31.4, z / 190 + 17.9) - 0.06) / 0.28
		if t > 0 then
			h += terrace(math.min(t, 1) * 3) * 7.5 * F
		end
	end
	for _, c in craters do
		local dx, dz = x - c.x, z - c.z
		if math.abs(dx) < c.r * 1.5 and math.abs(dz) < c.r * 1.5 then
			local d = math.sqrt(dx * dx + dz * dz) / c.r
			if d < 1 then
				h -= c.depth * (1 - d * d)
			end
			h += c.depth * 0.5 * math.exp(-(((d - 1.02) / 0.2) ^ 2))
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

local flats: { { x: number, z: number, inner: number, outer: number, h: number } } = {}

local function heightAt(x: number, z: number): number
	local h = rawH(x, z)
	for _, f in flats do
		local dx, dz = x - f.x, z - f.z
		if math.abs(dx) < f.outer and math.abs(dz) < f.outer then
			local d = math.sqrt(dx * dx + dz * dz)
			if d < f.outer then
				local w = 1 - smooth((d - f.inner) / (f.outer - f.inner))
				h += (f.h - h) * w
			end
		end
	end
	return h
end

-- Terrain material by biome, slope and height (art rule: flats / slopes / cliffs differ, pits glow in ash)
local function strata(h: number, a: Enum.Material, b: Enum.Material): Enum.Material
	return if math.floor(h / 5) % 2 == 0 then a else b
end

local function pickMat(x: number, z: number, h: number, slope: number): Enum.Material
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
	end
	-- desert
	if high or slope > 0.95 then
		return if n > 0.3 then M.Basalt else M.Rock
	elseif slope > 0.5 then
		return strata(h, M.Sandstone, M.Rock)
	elseif slope > 0.3 then
		return M.Sandstone
	end
	if h < 16 and noise(x / 45 + 9.2, z / 45 + 1.1) > 0.42 then
		return M.Grass -- dry scrub patches (terrain decoration)
	elseif n > 0.25 then
		return M.Ground
	elseif n < -0.3 then
		return M.Sandstone
	end
	return M.Sand
end

local function writeChunk(x0: number, z0: number, n: number)
	local terrain = Workspace.Terrain
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

local function wedge(parent: Instance, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?, collide: boolean?): WedgePart
	local p = Instance.new("WedgePart")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat or Enum.Material.Slate
	p.CanCollide = collide ~= false
	p.CastShadow = size.Magnitude > 16
	p.Parent = parent
	partCount += 1
	return p
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

-- Part fallback rock (two wedges back to back: faceted, not a cube)
local function fallbackRock(parent: Instance, x: number, z: number, s: number)
	local w = rng:NextNumber(5, 9) * s
	local col = rockTint()
	local pos = Vector3.new(x, lowestGround(x, z, w * 0.4) - w * 0.12, z) -- sunk on the low side (it hovered by w*0.1)
	local cf = CFrame.new(pos) * CFrame.Angles(math.rad(rng:NextNumber(-12, 12)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-12, 12)))
	wedge(parent, Vector3.new(w, w * 0.8, w * 0.7), cf * CFrame.new(0, w * 0.4, -w * 0.35), col, B.rockMat)
	wedge(parent, Vector3.new(w, w * 0.8, w * 0.7), cf * CFrame.new(0, w * 0.4, w * 0.35) * CFrame.Angles(0, math.pi, 0), col, B.rockMat)
	maybeYield()
end

-- Part fallback needle (two crossed ridge prisms)
local function fallbackSpire(parent: Instance, x: number, z: number, s: number, col: Color3?)
	local w = 12 * s
	local h = 40 * s
	local c = col or rockTint()
	local base = onGround(x, z, -3)
	local yaw = rng:NextNumber(0, TAU)
	for i = 0, 1 do
		local cf = CFrame.new(base + Vector3.new(0, h / 2, 0)) * CFrame.Angles(0, yaw + i * math.pi / 2, 0)
		wedge(parent, Vector3.new(w * 0.6, h, w), cf * CFrame.new(w * 0.3, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), c, B.rockMat)
		wedge(parent, Vector3.new(w * 0.6, h, w), cf * CFrame.new(-w * 0.3, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), c, B.rockMat)
	end
	maybeYield()
end

local ROCK_KEYS = { "env_rock_a", "env_rock_b", "env_rock_c" }

local function rock(parent: Instance, x: number, z: number, s: number, collide: boolean?)
	local key = ROCK_KEYS[rng:NextInteger(1, 3)]
	local m, skipped = placeMesh(parent, key, x, z, { scale = s, tint = rockTint(), material = B.rockMat, collide = collide ~= false and s >= 1, align = 0.7 })
	if not m and not skipped then
		fallbackRock(parent, x, z, s * 0.9)
	end
end

-- Jagged broken rock fins: 3-5 tall slender wedges leaning apart (different heights / yaws), planted deep so tilting never
-- shows a gap. A wedge's crest is a knife edge (vertical back meets sloped face), so there is never a flat cap or a tier.
-- `baseY` plants the cluster at a fixed height instead of on the terrain (far silhouettes). `collide`: fins are cover.
local function finCluster(parent: Instance, x: number, z: number, s: number, tint: Color3?, baseY: number?, collide: boolean?)
	local col = tint or rockTint()
	local gy = baseY or groundY(x, z)
	local n = rng:NextInteger(3, 5)
	local fan = rng:NextNumber(0, TAU)
	local hMain = 40 * s
	for i = 1, n do
		local a = fan + i / n * TAU + rng:NextNumber(-0.5, 0.5)
		local d = if i == 1 then 0 else rng:NextNumber(0.07, 0.17) * hMain
		local fx, fz = x + math.cos(a) * d, z + math.sin(a) * d
		local h = hMain * (if i == 1 then rng:NextNumber(0.8, 1.0) else rng:NextNumber(0.3, 0.7))
		local thick = h * rng:NextNumber(0.13, 0.2)
		local run = h * rng:NextNumber(0.2, 0.32)
		local sink = math.max(6, h * 0.22)
		local ground = if baseY then gy else groundY(fx, fz)
		local lean = math.rad(rng:NextNumber(6, 17))
		local cf = CFrame.new(fx, ground + (h - sink) / 2, fz) * CFrame.Angles(0, a + rng:NextNumber(-0.6, 0.6) + (if i % 2 == 0 then math.pi else 0), 0)
			* CFrame.Angles(0, 0, lean * (if i % 2 == 0 then 1 else -1)) * CFrame.Angles(math.rad(rng:NextNumber(-8, 8)), 0, 0)
		local w = wedge(parent, Vector3.new(thick, h + sink, run), cf, jitter(col, 0.1), B.rockMat, collide == true)
		w.CastShadow = collide == true or baseY == nil
	end
	if not baseY then
		for _ = 1, 2 do
			local a = rng:NextNumber(0, TAU)
			local d = rng:NextNumber(0.08, 0.2) * hMain
			rock(parent, x + math.cos(a) * d, z + math.sin(a) * d, rng:NextNumber(0.5, 1.1), false)
		end
	end
	maybeYield()
end

-- NOTE: env_spire_a (Blender "hoodoo": stem + flat overhanging caprock) reads as a mushroom silhouette and is no longer
-- placed anywhere; spires are env_spire_b crags or jagged wedge fins.
local function spire(parent: Instance, x: number, z: number, s: number, tint: Color3?, key: string?)
	if not key and rng:NextNumber() < 0.5 then
		finCluster(parent, x, z, s * 0.7, tint, nil, true)
		return
	end
	local k = key or "env_spire_b"
	-- spires are tall pointed landmarks that can stand on rim slopes: allow steeper ground (lowest-hit placement keeps them planted)
	local m, skipped = placeMesh(parent, k, x, z, { scale = s, tint = tint or rockTint(), material = B.rockMat, collide = true, align = 0.35, sink = rng:NextNumber(0.1, 0.16), maxSlope = 55 })
	if not m and not skipped then
		fallbackSpire(parent, x, z, s, tint)
	end
end

local crystalCount = 0

local function crystals(parent: Instance, x: number, z: number, s: number, color: Color3?, unlit: boolean?)
	local c = color or B.crystal
	if s <= 4 then -- small clusters shrink; the giant landmark crystals keep their scale
		s *= rng:NextNumber(0.6, 1.0)
	end
	crystalCount += 1
	-- desert crystals are dull mineral (no Neon, no light): the glowing white clusters fought the backlit sun
	local dull = biomeName == "desert"
	local lit = crystalCount % 3 == 1 and not unlit and not dull -- a small light on ~1 in 3 clusters
	local m, skipped = placeMesh(parent, "env_crystal_cluster", x, z, {
		scale = s, collide = false, tint = rockTint(), material = B.rockMat, align = 0.6,
		paint = function(p)
			if p:GetAttribute("Role") == "weak" then
				p.Color = c
				p.Material = if dull then Enum.Material.Slate else Enum.Material.Neon
				p.Transparency = if dull then 0 else 0.15
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
			local cp = part(parent, Vector3.new(1.2, h, 1.2), CFrame.new(p) * CFrame.Angles(math.rad(rng:NextNumber(-20, 20)), math.rad(rng:NextNumber(0, 90)), math.rad(rng:NextNumber(-20, 20))), c, if dull then Enum.Material.Slate else Enum.Material.Neon, { CanCollide = false, CastShadow = false, Transparency = if dull then 0 else 0.15 })
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
	local m, skipped = placeMesh(parent, ROCK_KEYS[rng:NextInteger(1, 3)], x, z, { scale = rng:NextNumber(0.1, 0.3), tint = rockTint(), material = B.rockMat, collide = false, sink = 0.25, align = 0.9 })
	if not m and not skipped then
		local d = rng:NextNumber(0.8, 2)
		decor(parent, Vector3.new(d, d * 0.6, d * 0.9), CFrame.new(onGround(x, z, 0.1)) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0), rockTint(), B.rockMat, { CastShadow = false })
	end
end

-- Broken wall: a ragged line of leaning wedge shards (varied heights, sloped tops, gaps) plus fallen rubble. Never one
-- big rectangle. Shards taller than 3 studs collide (cover); the rest is walk-through rubble.
local function ruinedWall(parent: Instance, x: number, z: number, yaw: number, len: number)
	local col = B.wall[rng:NextInteger(1, #B.wall)]:Lerp(B.rocks[1], 0.4)
	local base = CFrame.new(x, 0, z) * CFrame.Angles(0, yaw, 0)
	local half = math.min(len, 14) / 2
	local cursor = -half
	while cursor < half do
		local seg = rng:NextNumber(2.6, 4.4)
		if rng:NextNumber() > 0.14 then
			local h = ({ 1.6, 2.6, 4, 5.5, 7.5 })[rng:NextInteger(1, 5)] * rng:NextNumber(0.8, 1.15)
			local thick = rng:NextNumber(1.1, 1.8)
			local wp = (base * CFrame.new(rng:NextNumber(-0.4, 0.4), 0, cursor + seg / 2)).Position
			local flip = if rng:NextNumber() < 0.5 then math.pi else 0
			local gy = lowestGround(wp.X, wp.Z, seg * 0.5) -- lowest under the shard: no end hovers on a slope
			local cf = CFrame.new(wp.X, gy + h / 2 - 0.8, wp.Z) * CFrame.Angles(0, yaw + flip + rng:NextNumber(-0.18, 0.18), 0)
				* CFrame.Angles(math.rad(rng:NextNumber(-4, 4)), 0, math.rad(rng:NextNumber(-7, 7)))
			wedge(parent, Vector3.new(thick, h, seg), cf, jitter(col, 0.08), Enum.Material.Concrete, h >= 3)
			if rng:NextNumber() < 0.45 then
				-- a shorter shard leaning the other way beside it: zig-zag crest instead of a straight top
				local h2 = h * rng:NextNumber(0.35, 0.7)
				local cf2 = CFrame.new(wp.X, gy + h2 / 2 - 0.4, wp.Z) * CFrame.Angles(0, yaw + flip + math.pi + rng:NextNumber(-0.2, 0.2), 0)
					* CFrame.new(thick * 0.9, 0, 0) * CFrame.Angles(0, 0, math.rad(rng:NextNumber(-9, 9)))
				wedge(parent, Vector3.new(thick * 0.9, h2, seg * 0.75), cf2, jitter(col, 0.1), Enum.Material.Concrete, false)
			end
		end
		cursor += seg
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

local function tower(parent: Instance, x: number, z: number, yaw: number?)
	-- open lattice watchtower: splayed legs that each reach their OWN ground (never float on a slope), X-braces, an
	-- open rail instead of solid railing walls, a tilted tin roof on short posts, a small red lamp under the eave
	yaw = yaw or 0
	local base = CFrame.new(onGround(x, z)) * CFrame.Angles(0, yaw :: number, 0)
	local col = RGB(78, 80, 88)
	local dark = RGB(48, 50, 56)
	local deckH = 15
	local feet: { Vector3 } = {}
	for i, o in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local fw = (base * CFrame.new(o[1] * 4.4, 0, o[2] * 4.4)).Position
		local foot = Vector3.new(fw.X, groundY(fw.X, fw.Z) - 0.8, fw.Z)
		local top = (base * CFrame.new(o[1] * 3.4, deckH, o[2] * 3.4)).Position
		beam(parent, foot, top, 0.8, col, Enum.Material.Metal)
		feet[i] = foot
	end
	for _, pair in { { 1, 2 }, { 2, 3 } } do -- X-braces on two faces
		local a, b = feet[pair[1]], feet[pair[2]]
		local ta = a:Lerp((base * CFrame.new(0, deckH, 0)).Position, 0.55)
		local tb = b:Lerp((base * CFrame.new(0, deckH, 0)).Position, 0.55)
		beam(parent, a + Vector3.new(0, 1.2, 0), tb, 0.35, dark, Enum.Material.Metal, NOCOL_NS)
		beam(parent, b + Vector3.new(0, 1.2, 0), ta, 0.35, dark, Enum.Material.Metal, NOCOL_NS)
	end
	part(parent, Vector3.new(8.4, 0.7, 8.4), base * CFrame.new(0, deckH, 0), col, Enum.Material.DiamondPlate)
	local posts: { Vector3 } = {}
	for i, o in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local ph = if o[2] < 0 then 4.6 else 3.8 -- front posts taller: the roof tilts back
		local pb = (base * CFrame.new(o[1] * 3.9, deckH + 0.35, o[2] * 3.9)).Position
		cyl(parent, 0.35, ph, CFrame.new(pb + Vector3.new(0, ph / 2, 0)), dark, Enum.Material.Metal, NOCOL)
		posts[i] = pb + Vector3.new(0, 1.9, 0)
	end
	for k = 1, 3 do -- waist-high rail on three sides (the back side is the ladder way)
		pipeSeg(parent, posts[k], posts[k + 1], 0.22, dark, Enum.Material.Metal, NOCOL_NS)
	end
	decor(parent, Vector3.new(9.6, 0.25, 9.6), base * CFrame.new(0, deckH + 0.35 + 4.3, 0) * CFrame.Angles(math.rad(-5), 0, math.rad(3)), RGB(96, 84, 72), Enum.Material.CorrodedMetal, { CastShadow = true })
	decor(parent, Vector3.new(0.7, 0.5, 0.7), base * CFrame.new(3.4, deckH + 4.2, -3.4), RGB(255, 80, 60), Enum.Material.Neon, NOCOL_NS)
	maybeYield()
end

-- low landing / extraction marker: dark bollard with a small dim warm-white strip (replaces the old neon lamp posts;
-- the strip is deliberately quiet so it never competes with objectives). `color` tints only the small strip; the light
-- that reaches the ground is always warm-neutral (coloured lights turned the sand toxic green / teal).
local MARKER_LIGHT = RGB(255, 214, 165)
local function marker(parent: Instance, pos: Vector3, color: Color3, withLight: boolean)
	cyl(parent, 0.9, 3.6, CFrame.new(pos + Vector3.new(0, 1.3, 0)), RGB(46, 50, 58), Enum.Material.Metal, { CastShadow = false })
	local band = decor(parent, Vector3.new(1.0, 0.25, 1.0), CFrame.new(pos + Vector3.new(0, 2.9, 0)), RGB(255, 230, 190):Lerp(color, 0.35), Enum.Material.Neon, { CastShadow = false })
	if withLight then
		pointLight(band, MARKER_LIGHT, 11, 0.45)
	end
end

-- ---------------------------------------------------------------- placement tables
local function farFromSites(x: number, z: number, minDist: number): boolean
	for _, v in LAYOUT do
		local dx, dz = x - v.X, z - v.Y
		if dx * dx + dz * dz < minDist * minDist then
			return false
		end
	end
	return true
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


-- Ragged talus skirt: `n` wedges in a ring (rIn..rOut from `centre`) whose high side faces the centre, heights / yaws /
-- tilts jittered, bases sunk below the local ground. Hides the flat top and straight edges of a foundation block so a
-- landmark rises out of a sloped heap of rock instead of standing on a box. Walk-up-able slopes; collides.
local function rockSkirt(parent: Instance, centre: Vector3, rIn: number, rOut: number, h: number, n: number, col: Color3, mat: Enum.Material?)
	local len = rOut - rIn
	local a0 = rng:NextNumber(0, TAU)
	for i = 0, n - 1 do
		local a = a0 + i / n * TAU + rng:NextNumber(-0.12, 0.12)
		local rm = rIn + len * 0.5
		local x, z = centre.X + math.cos(a) * rm, centre.Z + math.sin(a) * rm
		local gy = math.min(groundY(x, z), centre.Y)
		local hh = h * rng:NextNumber(0.7, 1.15)
		local sink = math.max(3, hh * 0.25)
		local wid = TAU * rm / n * rng:NextNumber(1.15, 1.45)
		local p = Vector3.new(x, gy + (hh - sink) / 2, z) -- bottom at gy - sink, crest (inner edge) at gy + hh
		local cf = CFrame.lookAt(p, Vector3.new(centre.X, p.Y, centre.Z)) * CFrame.Angles(0, math.pi, 0)
			* CFrame.Angles(math.rad(rng:NextNumber(-5, 5)), rng:NextNumber(-0.15, 0.15), math.rad(rng:NextNumber(-7, 7)))
		local w = wedge(parent, Vector3.new(wid, hh + sink, len * rng:NextNumber(1.0, 1.2)), cf, jitter(col, 0.1), mat or B.rockMat, true)
		w.CastShadow = true
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
	cyl(parent, 5.2, 7.5, base, hull, Enum.Material.Metal, NOCOL) -- body; the +Y end is the nose
	cyl(parent, 3.6, 2.6, base * CFrame.new(0, 4.9, 0), hull, Enum.Material.Metal, NOCOL)
	cyl(parent, 1.8, 1.6, base * CFrame.new(0, 6.7, 0), soot, Enum.Material.Slate, NOCOL_NS)
	cyl(parent, 5.35, 0.8, base * CFrame.new(0, 1.3, 0), stripe, Enum.Material.Metal, NOCOL_NS)
	cyl(parent, 5.4, 2.2, base * CFrame.new(0, -2.6, 0), soot, Enum.Material.Slate, NOCOL_NS)
	decor(parent, Vector3.new(0.25, 3.8, 3.0), base * CFrame.new(2.9, 0.4, 0) * CFrame.Angles(0, 0, math.rad(-38)), hull, Enum.Material.Metal) -- blown hatch
	for _, sx in { -1, 1 } do
		wedge(parent, Vector3.new(0.4, 2.6, 2.4), base * CFrame.new(sx * 2.8, -2.4, 0) * CFrame.Angles(0, 0, -sx * math.rad(22)), stripe, Enum.Material.Metal, false)
	end
	maybeYield()
end

-- Ragged scorch painted into the terrain: overlapping blobs of darker biome material with jittered radii (never a flat disc).
local function scorchPatch(x: number, z: number, r: number, bugs: boolean)
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
	for i = 1, 4 do
		local a = rng:NextNumber(0, TAU)
		local off = if i == 1 then 0 else r * rng:NextNumber(0.5, 1.0)
		local sx, sz = x + math.cos(a) * off, z + math.sin(a) * off
		terrain:FillCylinder(CFrame.new(sx, groundY(sx, sz) - 1.1, sz), 2.4, r * rng:NextNumber(0.8, 1.15), Enum.Material.Basalt)
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
	wedge(parent, Vector3.new(0.4, 2.2, 3.5), CFrame.new(x, low + 1.1, z) * CFrame.Angles(math.rad(rng:NextNumber(-25, 25)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-30, 30))), rust, Enum.Material.CorrodedMetal, false)
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
		cyl(parent, d, h, CFrame.new(x, low + h / 2 - 0.3, z), paint, Enum.Material.CorrodedMetal, NOCOL)
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
	pipeSeg(parent, a, b, d, paint, Enum.Material.CorrodedMetal, NOCOL)
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

-- BROOD: resin web between two organic posts (thin stretched translucent wedges + strands)
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
	-- sheets: wedge size.Z runs along the span (high end at +Z), hung between the posts
	local mid = (posts[1][1] + posts[2][1]) / 2
	for i, sheet in { { 4.5, 1.7 }, { 2.6, 4.6 } } do
		local flipDir = if rng:NextNumber() < 0.5 then -dirv else dirv
		local sc = mid + Vector3.new(0, sheet[1] / 2 + sheet[2], 0)
		local w = wedge(parent, Vector3.new(0.15, sheet[1], gap * 0.92), CFrame.lookAt(sc, sc - flipDir), resin, Enum.Material.Marble, false)
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
		wedge(parent, Vector3.new(0.9 * h / 6, h * 0.44, 0.9 * h / 6), upper * CFrame.new(0, h * 0.22, 0), bone, Enum.Material.Slate, false).CastShadow = false
	end
	maybeYield()
end

-- Camp side of a site: the angle (from the site centre) furthest from every combat lane, and the camp radius.
local function campAngle(name: string): (number, number)
	local c = LAYOUT[name]
	local pad = PADS[name]
	local R = pad[1] * 0.78 + 4
	local bestA, bestD = 0, -1
	for k = 0, 15 do
		local a = k / 16 * TAU
		local px, pz = c.X + math.cos(a) * R, c.Y + math.sin(a) * R
		local dmin = 1e9
		for _, l in lanes do
			dmin = math.min(dmin, distSeg(px, pz, l.ax, l.az, l.bx, l.bz))
		end
		if math.max(math.abs(px), math.abs(pz)) > 226 then
			dmin = -1
		end
		if dmin > bestD then
			bestD, bestA = dmin, a
		end
	end
	return bestA, R
end

-- Settlement-style camp at a human objective, laid out so it reads at a glance:
--   * an A-frame ridge tent (two sloped fabric panels meeting at a ridge pole, end poles, a closed back gable, a half
--     flap at the door end, guy-lines pegged to the ground), its long side facing the objective;
--   * a tidy curved sandbag wall behind it on a circle around the objective (convex side faces OUT, open flanks);
--   * crates stacked against the door end, barrels at the closed end;
--   * a floodlight on a tripod beside the tent, aimed at the objective (warm spot light);
--   * a cable run from the tripod to a junction box near the objective.
-- The 12 studs around the site centre stay clear.
local function campSite(parent: Instance, name: string)
	local c = LAYOUT[name]
	local bestA, R = campAngle(name)
	local px, pz = c.X + math.cos(bestA) * R, c.Y + math.sin(bestA) * R
	local toC = Vector3.new(c.X - px, 0, c.Y - pz).Unit
	local f = CFrame.lookAt(Vector3.new(px, 0, pz), Vector3.new(px, 0, pz) + toC) -- local -Z faces the objective
	local rot = f - f.Position
	local function at(lx: number, lz: number, dy: number?): Vector3
		local w = f:PointToWorldSpace(Vector3.new(lx, 0, lz))
		return onGround(w.X, w.Z, dy or 0)
	end

	-- ---- sandbag wall: 2 full staggered rows + a shorter top row on an arc around the objective, behind the tent
	local bagCol = RGB(168, 146, 112):Lerp(B.rocks[1], 0.3)
	local Rw = R + 15.5 -- clear of the tent (local z 2..9) and the crates stacked against its back (z 9..13.5)
	local halfSpan = 12.5 / Rw -- ~25 studs of wall
	for row = 0, 2 do
		local span = if row == 2 then halfSpan * 0.55 else halfSpan
		local n = math.floor(span * 2 * Rw / 2.1)
		for i = 0, n - 1 do
			local th = bestA - span + (i + 0.5 + (row % 2) * 0.5) / n * span * 2
			if th <= bestA + span then
				local bx, bz = c.X + math.cos(th) * Rw, c.Y + math.sin(th) * Rw
				local ctr = Vector3.new(bx, groundY(bx, bz) + 0.42 + row * 0.78, bz)
				local t = Vector3.new(-math.sin(th), 0, math.cos(th))
				pipeSeg(parent, ctr - t * 0.98, ctr + t * 0.98, 1.0, jitter(bagCol, 0.07), Enum.Material.Fabric, NOCOL)
			end
		end
	end

	-- ---- A-frame tent: ridge along local X, centred 6 studs behind the camp point
	local tentCX, tentCZ = 0, 5.5
	local tw = f:PointToWorldSpace(Vector3.new(tentCX, 0, tentCZ))
	local tentY = lowestGround(tw.X, tw.Z, 4) - 0.15
	local tent = CFrame.new(tw.X, tentY, tw.Z) * rot
	local tarpCol = ({ RGB(112, 104, 74), RGB(96, 100, 80), RGB(120, 96, 70) })[rng:NextInteger(1, 3)]
	local poleCol = RGB(70, 62, 54)
	local halfL, halfW, ridgeH = 4.2, 3.4, 4.3
	local slope = math.atan2(ridgeH, halfW)
	local panelL = math.sqrt(halfW * halfW + ridgeH * ridgeH) + 0.25
	decor(parent, Vector3.new(halfL * 2, 0.16, panelL), tent * CFrame.new(0, ridgeH / 2, -halfW / 2) * CFrame.Angles(-slope, 0, 0), tarpCol, Enum.Material.Fabric, { CastShadow = true })
	decor(parent, Vector3.new(halfL * 2, 0.16, panelL), tent * CFrame.new(0, ridgeH / 2, halfW / 2) * CFrame.Angles(slope, 0, 0), jitter(tarpCol, 0.08), Enum.Material.Fabric, { CastShadow = true })
	pipeSeg(parent, (tent * CFrame.new(-halfL - 0.3, ridgeH + 0.05, 0)).Position, (tent * CFrame.new(halfL + 0.3, ridgeH + 0.05, 0)).Position, 0.28, poleCol, Enum.Material.Wood, NOCOL_NS)
	for _, sx in { -1, 1 } do
		cyl(parent, 0.3, ridgeH + 0.6, tent * CFrame.new(sx * (halfL - 0.1), ridgeH / 2, 0), poleCol, Enum.Material.Wood, NOCOL_NS)
		-- guy-line from the ridge end to a peg in the ground beyond the gable
		local top = (tent * CFrame.new(sx * (halfL + 0.2), ridgeH, 0)).Position
		local pg = f:PointToWorldSpace(Vector3.new(tentCX + sx * (halfL + 2.8), 0, tentCZ + 1.6))
		local peg = onGround(pg.X, pg.Z, 0.15)
		pipeSeg(parent, top, peg, 0.08, RGB(40, 38, 34), Enum.Material.Fabric, NOCOL_NS)
		cyl(parent, 0.22, 0.9, CFrame.new(peg), poleCol, Enum.Material.Wood, NOCOL_NS)
	end
	-- closed back gable (+X end): two mirrored wedges (a WedgePart's high side is +Z)
	for _, sz in { -1, 1 } do
		local wcf = tent * CFrame.new(halfL - 0.05, (ridgeH - 0.1) / 2, sz * halfW / 2) * (if sz > 0 then CFrame.Angles(0, math.pi, 0) else CFrame.identity)
		local wg = wedge(parent, Vector3.new(0.14, ridgeH - 0.1, halfW), wcf, jitter(tarpCol, 0.1), Enum.Material.Fabric, false)
		wg.CanQuery = false
		wg.CanTouch = false
	end
	-- door end (-X): one half flap closed, the other pinned open
	do
		local wg = wedge(parent, Vector3.new(0.14, ridgeH - 0.1, halfW), tent * CFrame.new(-halfL + 0.05, (ridgeH - 0.1) / 2, -halfW / 2), jitter(tarpCol, 0.1), Enum.Material.Fabric, false)
		wg.CanQuery = false
		wg.CanTouch = false
	end
	-- dark interior so the open door reads as depth, not sky
	decor(parent, Vector3.new(halfL * 1.7, 1.6, halfW * 1.1), tent * CFrame.new(0, 0.7, 0), RGB(28, 26, 24), Enum.Material.Fabric, NOCOL_NS)

	-- ---- crates stacked against the door end, barrels at the closed end
	-- the stack lines up against the tent's back panel (crateStack runs along (cos yaw, -sin yaw) = local +X)
	local dirX = f:VectorToWorldSpace(Vector3.xAxis)
	local cw = f:PointToWorldSpace(Vector3.new(tentCX - 3.4, 0, tentCZ + halfW + 2.3))
	crateStack(parent, cw.X, cw.Z, math.atan2(-dirX.Z, dirX.X))
	for k = 1, 3 do
		local bp = at(tentCX + halfL + 1.2 + (k % 2) * 1.3, tentCZ - 4.6 + k * 1.2, 1.15)
		cyl(parent, 1.7, 2.4, CFrame.new(bp), ({ RGB(118, 56, 42), RGB(72, 86, 100), RGB(96, 92, 70) })[k], Enum.Material.CorrodedMetal, NOCOL)
		cyl(parent, 1.78, 0.3, CFrame.new(bp + Vector3.new(0, 0.35, 0)), RGB(36, 36, 40), Enum.Material.Metal, NOCOL_NS)
	end

	-- ---- floodlight on a tripod in front of the tent, aimed at the objective (warm spot light: lights the site, not the sky)
	local pole = at(-1.6, -0.9)
	local legTop = pole + Vector3.new(0, 4.6, 0)
	local legA = rng:NextNumber(0, TAU)
	for k = 0, 2 do
		local a = legA + k / 3 * TAU
		local foot = onGround(pole.X + math.cos(a) * 1.7, pole.Z + math.sin(a) * 1.7, -0.1)
		pipeSeg(parent, foot, legTop, 0.22, RGB(52, 54, 60), Enum.Material.Metal, NOCOL_NS)
	end
	cyl(parent, 0.3, 2.2, CFrame.new(legTop + Vector3.new(0, 1.0, 0)), RGB(52, 54, 60), Enum.Material.Metal, NOCOL_NS)
	local headPos = legTop + Vector3.new(0, 2.3, 0)
	local aim = Vector3.new(c.X, groundY(c.X, c.Y) + 1, c.Y)
	local headCF = CFrame.lookAt(headPos, aim)
	decor(parent, Vector3.new(1.8, 1.2, 0.9), headCF, RGB(40, 42, 48), Enum.Material.Metal, NOCOL_NS)
	local lens = decor(parent, Vector3.new(1.5, 0.9, 0.1), headCF * CFrame.new(0, 0, -0.5), RGB(255, 226, 176), Enum.Material.Neon, NOCOL_NS)
	if lightCount < 46 then
		lightCount += 1
		local sl = Instance.new("SpotLight")
		sl.Face = Enum.NormalId.Front
		sl.Angle = 75
		sl.Range = 42
		sl.Brightness = 1.6
		sl.Color = RGB(255, 210, 150)
		sl.Shadows = false
		sl.Parent = lens
	end
	-- cable run from the pole toward the objective (lies on the ground, ends at a junction box 9 studs out)
	local target = Vector3.new(c.X, 0, c.Y) + Vector3.new(px - c.X, 0, pz - c.Y).Unit * 9.5
	local dirv = Vector3.new(target.X - pole.X, 0, target.Z - pole.Z).Unit
	local perp = Vector3.new(dirv.Z, 0, -dirv.X)
	local prev = onGround(pole.X, pole.Z, 0.2)
	for k = 1, 8 do
		local t = k / 8
		local wob = math.sin(t * 9 + bestA) * 0.9 * math.sin(t * math.pi)
		local p = onGround(pole.X + (target.X - pole.X) * t + perp.X * wob, pole.Z + (target.Z - pole.Z) * t + perp.Z * wob, 0.2)
		pipeSeg(parent, prev, p, 0.3, RGB(26, 26, 30), Enum.Material.Plastic, NOCOL_NS)
		prev = p
	end
	decor(parent, Vector3.new(1.1, 0.9, 0.9), CFrame.new(prev + Vector3.new(0, 0.35, 0)) * (f - f.Position), RGB(58, 62, 70), Enum.Material.Metal)
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
	for _ = 1, 12 do
		local x, z = laneEdgeSpot(245)
		scrapHeap(parent, x, z)
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
	for _ = 1, 10 do
		local x, z = laneEdgeSpot(238)
		for k = 1, rng:NextInteger(1, 3) do
			local a, d = rng:NextNumber(0, TAU), if k == 1 then 0 else rng:NextNumber(7, 14)
			local key, mul = keys[rng:NextInteger(1, #keys)], 1.3
			if bigLeft > 0 and k == 1 and rng:NextNumber() < 0.25 then
				key, mul = WRECK_BIG[fac] or "colossus", 1
				bigLeft -= 1
			end
			local m = wreckHulk(parent, x + math.cos(a) * d, z + math.sin(a) * d, key, mul)
			if m and wisps < 4 and rng:NextNumber() < 0.4 then
				wisps += 1
				plume(emitterHost(parent, m:GetPivot().Position + Vector3.new(0, 2, 0)), B.smoke, 2.6, 1.6, 6, 5)
			end
		end
		for _ = 1, rng:NextInteger(1, 2) do
			local a, d = rng:NextNumber(0, TAU), rng:NextNumber(10, 20)
			shellCrater(parent, x + math.cos(a) * d, z + math.sin(a) * d, rng:NextNumber(4.5, 7.5))
		end
		if rng:NextNumber() < 0.45 then
			local a, d = rng:NextNumber(0, TAU), rng:NextNumber(12, 22)
			podHusk(parent, x + math.cos(a) * d, z + math.sin(a) * d)
		end
		task.wait()
	end
	for _ = 1, 4 do -- lone craters in the open ground
		local x, z = wildSpot(36, 16, 245)
		shellCrater(parent, x, z, rng:NextNumber(4.5, 7))
	end
end

-- Dense dark rubble: ~250 small clusters (2-4 chunks each: tiny env_rock meshes and little tilted wedges), half sunk into the
-- ground, no collision, no shadows on the tiny ones. Heavier around shell craters and lane edges (the battlefield), never on
-- objective sites or the lane centrelines. Hard part budget so the map stays phone friendly.
local RUBBLE_CLUSTERS = 250
local RUBBLE_PART_CAP = 3200 -- checked before landmarks/far silhouettes (~250-300 parts) are built, so the map ends under ~3600
local function rubbleField(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Rubble"
	folder.Parent = parent
	local keys = { "env_rock_c", "env_rock_a" }
	local function darkTint(): Color3
		local c = rockTint()
		return Color3.new(c.R * 0.7, c.G * 0.7, c.B * 0.7)
	end
	local function chunk(x: number, z: number)
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
		local p = wedge(folder, Vector3.new(w, h, d), CFrame.new(x, g + h * 0.1, z) * tilt, darkTint(), B.rockMat, false)
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
	end
	for _ = 1, RUBBLE_CLUSTERS do
		if partCount >= RUBBLE_PART_CAP then
			break
		end
		local x, z
		local roll = rng:NextNumber()
		if roll < 0.35 and #craters > 0 then -- scorch: ring around the shell craters
			local c = craters[rng:NextInteger(1, #craters)]
			local a, d = rng:NextNumber(0, TAU), c.r * rng:NextNumber(0.6, 1.8)
			x, z = c.x + math.cos(a) * d, c.z + math.sin(a) * d
		elseif roll < 0.65 then -- battlefield: the edges of the lanes
			x, z = laneEdgeSpot(250)
		else
			x, z = randomSpot(30, 24)
		end
		if math.abs(x) < 262 and math.abs(z) < 262 and farFromSites(x, z, 28) and not inLane(x, z, 9) then
			for _ = 1, rng:NextInteger(2, 4) do
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
	for _ = 1, 22 do
		local x, z = laneEdgeSpot(250)
		local count = rng:NextInteger(3, 9)
		for i = 1, count do
			local a, d = rng:NextNumber(0, TAU), if i == 1 then 0 else rng:NextNumber(2.5, 11)
			local rx, rz = x + math.cos(a) * d, z + math.sin(a) * d
			if not inLane(rx, rz, 9) and farFromSites(rx, rz, 26) then
				local s = if i == 1 then rng:NextNumber(1.3, 2.4) elseif i <= 3 then rng:NextNumber(0.8, 1.4) else rng:NextNumber(0.4, 0.8)
				rock(props, rx, rz, s)
			end
		end
		for _ = 1, 5 do
			local a, d = rng:NextNumber(0, TAU), rng:NextNumber(3, 14)
			pebble(props, x + math.cos(a) * d, z + math.sin(a) * d)
		end
		task.wait()
	end
	for _ = 1, 16 do
		local x, z
		if rng:NextNumber() < 0.6 then
			x, z = laneEdgeSpot(255)
		else
			x, z = wildSpot(20, 8, 258)
		end
		shrubClump(dressing, x, z)
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
	elseif biomeName == "ice" then
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
				local col = rockTint()
				col = Color3.new(col.R * 0.68, col.G * 0.68, col.B * 0.68)
				local m, skipped = placeMesh(parent, ROCK_KEYS[rng:NextInteger(1, 3)], cx, cz, { scale = rng:NextNumber(0.14, 0.42), tint = col, material = B.rockMat, collide = false, sink = 0.35, align = 0.85 })
				if not m and not skipped then
					local w, h = rng:NextNumber(0.8, 2.2), rng:NextNumber(0.5, 1.4)
					local p = wedge(parent, Vector3.new(w, h, w * 1.1), CFrame.new(onGround(cx, cz, h * 0.1)) * CFrame.Angles(math.rad(rng:NextNumber(-20, 20)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-20, 20))), col, B.rockMat, false)
					p.CanQuery = false
					p.CastShadow = false
				end
			end
		end
	end
	maybeYield()
end

-- Ring of cover around a site, leaving the centre open.
local function dressSite(parent: Instance, name: string, faction: string)
	local c = LAYOUT[name]
	local kind = name:gsub("%d+$", "")
	local pad = PADS[name]
	if not pad then
		return
	end
	-- deliberate defensive ring: evenly spaced slots on ONE arc around the objective, every piece turned along the arc
	-- (long side tangent, face radial); slots where a combat lane enters and the camp side stay open as paths
	local small = kind == "nest" or kind == "samples"
	local R = pad[1] + 5
	local count = if small then 6 else 9
	local campA: number? = if kind == "generator" or kind == "console" or kind == "uplink" then (campAngle(name)) else nil
	local a0 = rng:NextNumber(0, TAU)
	local placed = 0
	for i = 0, count - 1 do
		local a = a0 + i / count * TAU
		local x, z = c.X + math.cos(a) * R, c.Y + math.sin(a) * R
		local open = inLane(x, z, 11)
		if campA then
			local d = math.abs((a - campA + math.pi) % TAU - math.pi)
			open = open or d < 0.75
		end
		if not open then
			placed += 1
			-- ruinedWall runs its shards along local Z: yaw = -a puts Z on the tangent. placeMesh's `back` axis is
			-- (sin yaw, cos yaw): yaw = pi/2 - a faces the barricade radially (its long side along the arc).
			if not small and placed % 3 == 2 then
				ruinedWall(parent, x, z, -a, 12)
			else
				cover(parent, x, z, math.pi / 2 - a, faction)
				-- a low rock tucked at one end so the piece sits in rubble, not on bare sand
				local e = a + (if placed % 2 == 0 then 1 else -1) * 3.2 / R
				rock(parent, c.X + math.cos(e) * (R + 1.2), c.Y + math.sin(e) * (R + 1.2), rng:NextNumber(0.35, 0.6), false)
			end
		end
	end
	siteRubble(parent, c, pad[1] * 0.75, R + 9, if small then 5 else 8, campA)
	if kind == "codes" then
		-- ragged, soft scorch: overlapping terrain blobs (no flat disc), darker biome rock rather than black
		local terrain = Workspace.Terrain
		for i = 1, 7 do
			local a = rng:NextNumber(0, TAU)
			local off = if i == 1 then 0 else rng:NextNumber(3, 11)
			local sx, sz = c.X + math.cos(a) * off, c.Y + math.sin(a) * off
			local sr = if i == 1 then rng:NextNumber(7, 9) else rng:NextNumber(4, 8)
			local mat = if i >= 6 then Enum.Material.Ground else Enum.Material.Basalt
			terrain:FillCylinder(CFrame.new(sx, groundY(sx, sz) - 1.1, sz), 2.4, sr, mat)
		end
		maybeYield()
		-- bent hull fragments (2-part shapes: plate + folded flange), half dug in, off-white with orange accents
		for i = 1, 5 do
			local a = rng:NextNumber(0, TAU)
			local rr = rng:NextNumber(5, 16)
			local fx, fz = c.X + math.cos(a) * rr, c.Y + math.sin(a) * rr
			local sx, sz = rng:NextNumber(2, 3.5), rng:NextNumber(1.5, 2.5)
			local tiltA, tiltB = math.rad(rng:NextNumber(15, 40)) * (if rng:NextNumber() < 0.5 then 1 else -1), math.rad(rng:NextNumber(-12, 12))
			local base = CFrame.new(onGround(fx, fz, 0.1)) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0) * CFrame.Angles(tiltA, 0, tiltB)
			local hull = RGB(225, 222, 215)
			local accent = RGB(240, 120, 40)
			decor(parent, Vector3.new(sx, 0.3, sz), base, if i == 2 or i == 4 then accent else hull, Enum.Material.Metal)
			local flange = base * CFrame.new(0, 0.1, -sz / 2) * CFrame.Angles(math.rad(rng:NextNumber(20, 45)), 0, 0) * CFrame.new(0, 0.2, -0.5)
			local w = wedge(parent, Vector3.new(sx * 0.7, 0.35, 1.0), flange, if i % 2 == 1 then accent else hull, Enum.Material.Metal, false)
			w.CanQuery = false
			w.CanTouch = false
		end
		-- two thin smoke columns rising from the wreck
		for _, o in { { 4, -3 }, { -5, 4 } } do
			local host = emitterHost(parent, onGround(c.X + o[1], c.Y + o[2], 1.5))
			local pe = Instance.new("ParticleEmitter")
			pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
			pe.Rate = 3
			pe.Lifetime = NumberRange.new(6, 9)
			pe.Speed = NumberRange.new(3, 5)
			pe.SpreadAngle = Vector2.new(5, 5)
			pe.EmissionDirection = Enum.NormalId.Top
			pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 9) })
			pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
			pe.Color = ColorSequence.new(RGB(72, 70, 72))
			pe.LightEmission = 0
			pe.Rotation = NumberRange.new(0, 360)
			pe.RotSpeed = NumberRange.new(-10, 10)
			pe.Parent = host
		end
	elseif kind == "generator" then
		campSite(parent, name)
		-- watchtower on the camp's flank, just outside the cover ring, facing the objective
		local ta = (campA :: number) + 0.95
		local tr = pad[1] + 11
		tower(parent, c.X + math.cos(ta) * tr, c.Y + math.sin(ta) * tr, math.pi / 2 - ta)
	elseif kind == "console" then
		campSite(parent, name)
		marker(parent, onGround(c.X - 22, c.Y - 14), RGB(255, 190, 90), true)
	elseif kind == "silo" then
		-- irregular concrete apron: one low round pad (top ~0.15 above ground at the hatch), broken-up edge chunks, hazard bollards
		local apronCol = RGB(92, 90, 92):Lerp(B.rocks[1], 0.25)
		local gC = groundY(c.X, c.Y)
		local lowest = gC
		for k = 0, 7 do
			local ka = k / 8 * TAU
			lowest = math.min(lowest, groundY(c.X + math.cos(ka) * 13, c.Y + math.sin(ka) * 13))
		end
		local apronTop = gC + 0.15
		local apronH = math.clamp(apronTop - lowest + 0.4, 0.6, 4)
		cyl(parent, 26, apronH, CFrame.new(c.X, apronTop - apronH / 2, c.Y), apronCol, Enum.Material.Concrete, { CastShadow = false })
		for _ = 1, rng:NextInteger(6, 8) do
			local a = rng:NextNumber(0, TAU)
			local rr = rng:NextNumber(13, 20)
			local cx, cz = c.X + math.cos(a) * rr, c.Y + math.sin(a) * rr
			decor(
				parent,
				Vector3.new(rng:NextNumber(3, 7), 0.5, rng:NextNumber(3, 7)),
				-- on the lowest ground under the slab (centre on the surface left its downhill edge hovering)
				CFrame.new(cx, lowestGround(cx, cz, 3) - 0.05, cz) * CFrame.Angles(math.rad(rng:NextNumber(-8, 8)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-8, 8))),
				jitter(apronCol, 0.12),
				Enum.Material.Concrete,
				{ CastShadow = false }
			)
		end
		for k = 0, 3 do
			local ba = math.rad(45 + k * 90)
			local bx, bz = c.X + math.cos(ba) * 14, c.Y + math.sin(ba) * 14
			local bp = onGround(bx, bz, 0.95)
			part(parent, Vector3.new(0.8, 2.2, 0.8), CFrame.new(bp), RGB(230, 170, 40), Enum.Material.Metal)
			decor(parent, Vector3.new(0.86, 0.45, 0.86), CFrame.new(bp + Vector3.new(0, 0.3, 0)), RGB(28, 28, 30), Enum.Material.Metal)
		end
		marker(parent, onGround(c.X - 26, c.Y - 26), RGB(255, 120, 70), true)
		marker(parent, onGround(c.X + 26, c.Y + 26), RGB(255, 120, 70), true)
		tower(parent, c.X - 32, c.Y + 28, 0)
	elseif kind == "uplink" then
		campSite(parent, name)
		marker(parent, onGround(c.X + 24, c.Y - 18), RGB(255, 190, 90), true)
	elseif kind == "nest" then
		-- ragged terrain-painted scorch (no flat disc) + a broken rim of rubble and boulders, then eggs / scrap beyond 11 studs
		local bugs = faction == "BROOD"
		scorchPatch(c.X, c.Y, 17, bugs)
		for i = 1, 9 do
			local a = i / 9 * TAU + rng:NextNumber(-0.2, 0.2)
			local rr = rng:NextNumber(15, 22)
			rock(parent, c.X + math.cos(a) * rr, c.Y + math.sin(a) * rr, rng:NextNumber(0.35, 0.9))
		end
		for _ = 1, 3 do
			local a, rr = rng:NextNumber(0, TAU), rng:NextNumber(20, 25)
			rock(parent, c.X + math.cos(a) * rr, c.Y + math.sin(a) * rr, rng:NextNumber(1.0, 1.5))
		end
		local a0 = rng:NextNumber(0, TAU)
		for k = 0, 1 do
			local a, rr = a0 + k * math.pi + rng:NextNumber(-0.5, 0.5), rng:NextNumber(11, 14)
			if bugs then
				eggCluster(parent, c.X + math.cos(a) * rr, c.Y + math.sin(a) * rr)
			else
				scrapHeap(parent, c.X + math.cos(a) * rr, c.Y + math.sin(a) * rr)
			end
		end
		if bugs then
			tuskCluster(parent, c.X + math.cos(a0 + 1.6) * 21, c.Y + math.sin(a0 + 1.6) * 21)
		end
	elseif kind == "samples" then
		-- unlit: a coloured crystal light at the pickup washed the sand green / teal
		crystals(parent, c.X, c.Y, 1.1, nil, true)
		crystals(parent, c.X + 7, c.Y - 5, 0.8, nil, true)
	elseif kind == "insertion" then
		for i = 1, 6 do
			local a = i / 6 * TAU
			marker(parent, onGround(c.X + math.cos(a) * 46, c.Y + math.sin(a) * 46), RGB(255, 225, 190), i % 3 == 0)
		end
	elseif kind == "extraction" then
		for i = 1, 4 do
			local a = i / 4 * TAU + math.pi / 4
			marker(parent, onGround(c.X + math.cos(a) * 36, c.Y + math.sin(a) * 36), RGB(255, 170, 60), true)
		end
	end
	-- supply crates by the objective (not the landing zones)
	-- (camp sites already stack crates against the tent; elsewhere one pair, tucked just inside a ring slot)
	if kind ~= "insertion" and kind ~= "extraction" and not campA then
		local a = a0 + (0.5 / count) * TAU
		local x, z = c.X + math.cos(a) * (R - 3), c.Y + math.sin(a) * (R - 3)
		if not inLane(x, z, 9) then
			crateStack(parent, x, z, -a)
		end
	end
end

-- ---------------------------------------------------------------- faction dressing
local function dressCog(parent: Instance)
	local steel = RGB(88, 92, 100)
	local rust = RGB(140, 84, 60)
	local red = RGB(255, 50, 50)
	-- robot pylons, grouped near sites and away from the lanes
	for i = 1, 12 do
		local c = LAYOUT[({ "codes", "generator", "console", "silo", "uplink", "nest1", "nest2", "nest3", "nest4", "samples1", "samples2", "samples3" })[i]]
		local a = rng:NextNumber(0, TAU)
		local d = rng:NextNumber(46, 76)
		local x, z = c.X + math.cos(a) * d, c.Y + math.sin(a) * d
		if inLane(x, z, 10) then
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
		elseif i <= 5 then
			for _, p in m:GetChildren() do
				if p:IsA("BasePart") and p:GetAttribute("Role") == "glow" then
					pointLight(p, p.Color, 36, 1.4)
					break
				end
			end
		end
		maybeYield()
	end
	-- barricade nests off the lanes
	for _ = 1, 9 do
		local x, z = wildSpot(50, 24, 240)
		local yaw = rng:NextNumber(0, TAU)
		for k = 1, rng:NextInteger(2, 3) do
			cover(parent, x + (k - 1) * 11 * math.cos(yaw), z - (k - 1) * 11 * math.sin(yaw), yaw + rng:NextNumber(-0.3, 0.3), "COG")
		end
	end
	-- metal debris: plates, gears, broken limbs
	for _ = 1, 12 do
		local x, z = randomSpot(24)
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
			-- torn chunk: a tilted wedge half sunk (not a cube)
			local w = wedge(parent, Vector3.new(2.2, 1.8, 2.6), CFrame.new(p + Vector3.new(rng:NextNumber(-3, 3), 0.3, rng:NextNumber(-3, 3))) * CFrame.Angles(math.rad(rng:NextNumber(-20, 20)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-20, 20))), rust, Enum.Material.CorrodedMetal, false)
			w.CanQuery = false
		end
		maybeYield()
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
					-- pointed spike (wedge, knife-edge tip) planted 1 stud deep, not a square post
					wedge(parent, Vector3.new(1.6, h, 2.2), CFrame.new(sp) * CFrame.Angles(math.rad(rng:NextNumber(-25, 25)), rng:NextNumber(0, TAU), math.rad(rng:NextNumber(-25, 25))), RGB(110, 60, 150), Enum.Material.Slate, false)
				end
			end
		end
		maybeYield()
	end
	-- (the flat box "ribs" are gone: tusks, egg clusters and resin webs on the lane edges instead)
	hiveSet(parent)
end

-- ---------------------------------------------------------------- landmarks (60-200 studs, far ring)
local function foundryTower(parent: Instance, x: number, z: number, yaw: number)
	local g = surfaceAt(x, z)
	local base = CFrame.new(g) * CFrame.Angles(0, yaw, 0)
	local steel = RGB(66, 70, 80)
	local steelLt = RGB(84, 88, 98)
	local rust = RGB(120, 70, 50)
	local soot = RGB(40, 40, 46)
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

-- Crashed cruiser: a long tapered wedge hull broken in two. The nose section is buried in the rim at a steep angle, the
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
	wedge(parent, Vector3.new(5, 10, 40), sternF * CFrame.new(0, 17, 12), dark, Enum.Material.Metal, false)
	beam(parent, (sternF * CFrame.new(0, 36, 52)).Position, (sternF * CFrame.new(5, 62, 55)).Position, 1.4, dark, Enum.Material.Metal, { CanCollide = false })
	local mast = decor(parent, Vector3.new(1.8, 1.8, 1.8), sternF * CFrame.new(5, 63, 55), RGB(255, 60, 40), Enum.Material.Neon, { Shape = Enum.PartType.Ball, CastShadow = false })
	pointLight(mast, RGB(255, 70, 50), 60, 1.8)
	-- twin tail fins, one snapped
	for _, sx in { -1, 1 } do
		local fh = if sx > 0 then 30 else 17
		-- swept fin (wedge: rises toward the stern, knife-edge leading slope) instead of a flat rectangular plate
		wedge(parent, Vector3.new(3, fh, 24), sternF * CFrame.new(sx * 15, 27 + fh / 2 - 15, 76) * CFrame.Angles(0, 0, math.rad(-sx * (if sx > 0 then 12 else 38))), RGB(56, 62, 76), Enum.Material.Metal, false)
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
		-- tapering rib (wedge: knife-edge tip) instead of a 100-stud flat slab
		wedge(parent, Vector3.new(4, h, 7), cf, RGB(104, 64, 132), Enum.Material.Mud, false)
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
		-- weathered cap on the outer face: a wedge whose slope alternates direction block to block, so the top of the
		-- span is a broken sawtooth crest instead of a smooth ring of boxes
		local flip = if i % 2 == 0 then CFrame.identity else CFrame.Angles(0, math.pi, 0)
		wedge(parent, Vector3.new(bw * rng:NextNumber(0.75, 0.95), thick * rng:NextNumber(0.35, 0.6), bd * rng:NextNumber(0.7, 0.95)),
			cf * jit * CFrame.new(rng:NextNumber(-1.5, 1.5), thick * 0.35, rng:NextNumber(-2, 2)) * flip * CFrame.Angles(0, rng:NextNumber(-0.2, 0.2), 0), jitter(col, 0.06), B.rockMat, false)
	end
	-- footings reach down to the actual ground, plus loose spires around them
	for i, sx in { -1, 1 } do
		local fg = feet[i]
		local top = fg.Y + 6
		local bottom = math.min(fg.Y, baseY) - 22
		part(parent, Vector3.new(34, top - bottom, 40), CFrame.new(fg.X, (top + bottom) / 2, fg.Z) * rot, jitter(tint, 0.05), B.rockMat)
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

-- landmark slots in the far ring (rim top) + which landmark per biome
local LANDMARK_SLOTS = { Vector2.new(55, 292), Vector2.new(292, -55), Vector2.new(0, -292), Vector2.new(-292, 60) }
local BIOME_LANDMARKS: { [string]: { (Instance, number, number, number) -> () } } = {
	desert = { mesaArch, spireGroup },
	ash = { crashedCruiser, spireGroup },
	swamp = { mesaArch, spireGroup },
	ice = { iceCrystals, crashedCruiser },
}

local function buildLandmarks(parent: Instance, faction: string)
	local list: { (Instance, number, number, number) -> () } = { if faction == "BROOD" then hiveSpire else foundryTower }
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
		local tint = rockTint()
		local m = if i % 2 == 0 then nil else Assets.get(key, { anchored = true }) -- every other slot: a jagged wedge-fin cluster instead
		if i % 2 == 0 then
			finCluster(parent, x, z, s * 0.55, tint, 38 + rng:NextNumber(0, 14), false)
			continue
		end
		if m then
			m:ScaleTo(s)
			local h = (Assets.size(key) or Vector3.new(30, 45, 30)).Y * s
			m:PivotTo(CFrame.new(x, 52 - h * rng:NextNumber(0.1, 0.3), z) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0))
			for _, p in m:GetChildren() do
				if p:IsA("BasePart") then
					p.Color = tint
					p.Material = B.rockMat
					p.CanCollide = false
					p.CanQuery = false
					p.CastShadow = false
					partCount += 1
				end
			end
			m.Parent = parent
		else
			local w = 40 * s * 0.5
			wedge(parent, Vector3.new(w, 120 * s * 0.5, w * 1.4), CFrame.new(x, 52 + 60 * s * 0.5 - 10, z) * CFrame.Angles(0, a + math.pi / 2, 0), tint, B.rockMat, false)
		end
		maybeYield()
	end
	-- massifs: each is 3-5 smaller wedges of different heights, yawed and tilted differently and overlapping, so the
	-- silhouette is a jagged ridge (alternating facing wedges form crests), never one box-like block
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
			local ph = top + 30 -- the wedge reaches 30 studs below ground, so tilting never lifts a corner into view
			local pw = w / pieces * rng:NextNumber(1.3, 2.0)
			local pd = depth * rng:NextNumber(0.5, 0.95)
			local at = centre + span * Vector3.new(f * w, 0, rng:NextNumber(-0.3, 0.3) * depth)
			local cf = CFrame.new(at.X, top / 2 - 15, at.Z) * span * CFrame.Angles(0, rng:NextNumber(-0.5, 0.5) + (if k % 2 == 0 then math.pi else 0), 0)
				* CFrame.Angles(math.rad(rng:NextNumber(-6, 6)), 0, math.rad(rng:NextNumber(-9, 9)))
			wedge(parent, Vector3.new(pw, ph, pd), cf, jitter(tint, 0.1), B.rockMat, false).CastShadow = false
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

-- Park the sun low and in front of the default camera direction (players drop in facing +X/+Z), so the
-- landmarks and ridges read as backlit silhouettes. Searches latitude/clock for the best match.
local function alignSun(m: { [string]: any })
	local target = Vector3.new(0.7071, 0, 0.7071)
	local bestScore, bestLat, bestClock = -math.huge, 35, m.clock
	local seen: { [string]: boolean } = {}
	local ok = pcall(function()
		for _, lat in { -40, -20, 0, 20, 40 } do
			for _, base in { m.clock, 24 - m.clock } do
				for _, dc in { -0.8, 0, 0.8 } do
					local clk = (base + dc) % 24
					Lighting.GeographicLatitude = lat
					Lighting.ClockTime = clk
					local d = Lighting:GetSunDirection()
					seen[string.format("%.2f,%.2f,%.2f", d.X, d.Y, d.Z)] = true
					local hm = Vector3.new(d.X, 0, d.Z)
					local align = if hm.Magnitude > 0.02 then hm.Unit:Dot(target) else 0
					local score = align - math.abs(d.Y - m.elev) * 4 - (if d.Y < 0.05 then 3 else 0)
					if score > bestScore then
						bestScore, bestLat, bestClock = score, lat, clk
					end
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
	Lighting.ExposureCompensation = m.expo
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
	local atm = Instance.new("Atmosphere")
	atm.Density = m.atmDensity
	atm.Offset = m.atmOffset
	atm.Haze = m.haze
	atm.Glare = m.glare
	atm.Color = m.atm
	atm.Decay = m.decay
	tag(atm)
	local sky = Instance.new("Sky")
	sky.StarCount = m.stars
	sky.CelestialBodiesShown = true
	sky.SunAngularSize = m.sun
	sky.MoonAngularSize = 9
	tag(sky)
	local cc = Instance.new("ColorCorrectionEffect")
	cc.TintColor = m.tint
	cc.Saturation = m.sat
	cc.Contrast = m.contrast
	cc.Brightness = 0.02
	tag(cc)
	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = m.bloom
	bloom.Size = 40
	bloom.Threshold = 1.1
	tag(bloom)
	local rays = Instance.new("SunRaysEffect")
	rays.Intensity = m.rays
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
end

function MapBuilder.init(registry: any)
	S = registry
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
	local fac = if faction == "BROOD" then "BROOD" else "COG"
	MapBuilder.clear()
	partCount, opsSinceYield, lightCount, crystalCount = 0, 0, 0, 0
	blinkers = {}
	rng = Random.new(1337)
	local t0 = os.clock()

	-- biome: planet hint, else faction default
	biomeName = if biome and BIOMES[biome] then biome else (if fac == "BROOD" then "swamp" else "desert")
	B = BIOMES[biomeName]

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

	planCraters(if biomeName == "ash" then 7 else 4)

	-- flatten pads
	flats = {}
	for name, pad in PADS do
		local c = LAYOUT[name]
		flats[#flats + 1] = { x = c.X, z = c.Y, inner = pad[1], outer = pad[2], h = math.max(rawH(c.X, c.Y), 7) }
	end
	setTerrainColors()
	pcall(function()
		Workspace.Terrain.Decoration = true
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
	if biomeName == "ash" or biomeName == "desert" then
		-- lava cracks: zig-zag chains of short blocks (direction wanders +-35 degrees), not one straight strip
		for _ = 1, if biomeName == "ash" then 10 else 4 do
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

	-- rock clusters in 3 sizes (art rule 5): grouped, off the combat lanes
	for _ = 1, 38 do
		local x, z = wildSpot(34, 14, 262)
		local big = rng:NextNumber() < 0.35
		local count = if big then rng:NextInteger(5, 8) else rng:NextInteger(2, 4)
		for i = 1, count do
			local a, d = rng:NextNumber(0, TAU), if i == 1 then 0 else rng:NextNumber(3, if big then 17 else 10)
			local rx, rz = x + math.cos(a) * d, z + math.sin(a) * d
			if not inLane(rx, rz, 8) and farFromSites(rx, rz, 28) then
				local s = if i == 1 and big then rng:NextNumber(1.6, 2.5) elseif i == 1 then rng:NextNumber(1.0, 1.6) else rng:NextNumber(0.6, 1.3)
				rock(props, rx, rz, s)
			end
		end
	end
	-- pebbles around the clusters and along the edges of the lanes
	for _ = 1, 60 do -- (the rubble field below carries the dense scatter)
		local x, z = randomSpot(16, 62)
		pebble(props, x, z)
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
	-- crystal clusters
	for _ = 1, 12 do
		local x, z = wildSpot(40, 18, 258)
		crystals(props, x, z, rng:NextNumber(0.8, 2.0))
	end
	-- broken wall lines (ragged wedge shards, never slabs); the box huts are gone, camps replace them at the sites
	for _ = 1, 6 do
		local x, z = wildSpot(36, 16, 270)
		ruinedWall(props, x, z, rng:NextNumber(0, math.pi), rng:NextNumber(8, 14))
	end
	-- alien / dry plants (singles; the clumps come from natureSet)
	for _ = 1, if biomeName == "swamp" then 50 else 24 do
		local x, z = wildSpot(14, 6, 262)
		plant(dressing, x, z)
		maybeYield()
	end

	if fac == "BROOD" then
		dressBrood(dressing)
	else
		dressCog(dressing)
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
	local insertion = CFrame.lookAt(ins, Vector3.new(0, ins.Y, 0))
	local ex = LAYOUT.extraction
	local extraction = onGround(ex.X, ex.Y)

	-- patrol points: around sites + scattered, on gentle ground
	local patrol: { Vector3 } = {}
	local function gentle(x: number, z: number): boolean
		local g = groundY(x, z)
		return math.abs(groundY(x + 6, z) - g) < 3 and math.abs(groundY(x, z + 6) - g) < 3
	end
	local patrolBases = { "codes", "generator", "console", "silo", "uplink", "nest1", "nest2", "nest3", "nest4", "samples1", "samples2", "samples3" }
	for _, name in patrolBases do
		local c = LAYOUT[name]
		for _ = 1, 20 do
			local a = rng:NextNumber(0, TAU)
			local d = rng:NextNumber(28, 46)
			local x, z = c.X + math.cos(a) * d, c.Y + math.sin(a) * d
			if math.abs(x) < 250 and math.abs(z) < 250 and gentle(x, z) then
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
		if di.Magnitude > 90 and gentle(x, z) then
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
		if (Vector2.new(x, z) - LAYOUT.insertion).Magnitude > 120 and gentle(x, z) then
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
	}
	MapBuilder.current = map
	-- lime Neon (slime, goo, spore pods) blooms into flat yellow blobs; pull it to a deep acid green
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") and d.Material == Enum.Material.Neon then
			local c = d.Color
			if c.G > 0.85 and c.R > 0.4 and c.R < 0.75 and c.B < 0.5 then
				d.Color = RGB(70, 200, 40)
			end
		end
	end
	print(string.format("[Map] %s/%s built in %.1fs, %d parts", fac, biomeName, os.clock() - t0, partCount))
	return map
end

-- end of MapBuilder
return MapBuilder
