-- LUMEN CONCORD placeholder bodies; real models come later.
-- Simple Part builds for the four Lumen units (and the Shard Swarmer, which reuses SHARDLING scaled down).
-- Plugged into EnemyModels as fallback builders exactly like the COG / BROOD part models, with the same conventions:
--   root at ground level, front = -Z, up = +Y; every part carries EnemyId + Zone (Data/Enemies zones).
--   Zones: SHARDLING core | WARDEN head, core (back), shield (front, blocks) | LANCER lens (front), core (underneath)
--          SPIRE parts named Node1..3 (LumenAI opens / closes them: Zone "node" <-> "body")
-- Offsets (root-local): muzzle = needle origin, lens = Lancer beam origin, core = LumenCharge / pulse origin.
-- Palette: ceramic shells (pale / dark violet) held together by lavender light.

local LumenModels = {}

local SHELL = Color3.fromRGB(196, 186, 176) -- pale ceramic (LumenAI NODE_SHUT)
local SHELL_DARK = Color3.fromRGB(58, 46, 86)
local SHELL_DEEP = Color3.fromRGB(30, 24, 44)
local GLOW = Color3.fromRGB(150, 125, 255) -- lavender light
local CORE = Color3.fromRGB(192, 96, 255) -- violet weak spot
local NODE_OPEN = Color3.fromRGB(200, 110, 255) -- LumenAI NODE_OPEN

local NEON = Enum.Material.Neon
local CERAMIC = Enum.Material.SmoothPlastic
local GLASS = Enum.Material.Glass

local function V(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function at(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z)
end

local function rot(x: number, y: number, z: number): CFrame
	return CFrame.Angles(math.rad(x), math.rad(y), math.rad(z))
end

-- Shardling: floating crystal drone, four petals open around a violet core. 7 parts incl. root.
local function buildShardling(c: any)
	c.rig.bob = 0.25
	local y = 3.2
	c.add("Core", V(1.1, 1.1, 1.1), at(0, y, 0), CORE, NEON, "core", true)
	for i = 1, 4 do
		local yaw = (i - 1) * 90 + 45
		local cf = at(0, y, 0) * rot(0, yaw, 0) * CFrame.new(0, 0, -0.95) * rot(-28, 0, 0)
		c.add("Petal" .. i, V(0.7, 1.9, 0.22), cf, SHELL, CERAMIC)
	end
	c.add("Tail", V(0.45, 1.5, 0.45), at(0, y - 1.5, 0) * rot(0, 45, 0), SHELL_DARK, CERAMIC)
end

-- Warden: ceramic sentinel, hard-light shield up front, core on its back. 10 parts incl. root.
local function buildWarden(c: any)
	c.rig.bob = 0.15
	local legL = c.add("LegL", V(0.8, 2.6, 0.8), at(-0.75, 1.3, 0) * rot(0, 45, 0), SHELL_DARK, CERAMIC)
	local legR = c.add("LegR", V(0.8, 2.6, 0.8), at(0.75, 1.3, 0) * rot(0, 45, 0), SHELL_DARK, CERAMIC)
	c.leg(legL, V(-0.75, 2.6, 0), 0.55, 0)
	c.leg(legR, V(0.75, 2.6, 0), 0.55, math.pi)
	c.add("Torso", V(2.4, 2.8, 1.6), at(0, 4.0, 0), SHELL, CERAMIC)
	c.add("Head", V(1.3, 1.6, 1.3), at(0, 6.0, 0) * rot(0, 45, 0), SHELL, CERAMIC, "head")
	c.add("Visor", V(1.0, 0.25, 0.2), at(0, 6.05, -0.75), GLOW, NEON, "head")
	c.add("Core", V(1.3, 1.3, 1.3), at(0, 4.2, 1.0), CORE, NEON, "core", true)
	c.add("Emitter", V(0.5, 0.5, 1.8), at(1.95, 4.0, -0.6), SHELL_DEEP, CERAMIC) -- beside the shield, so needles clear it
	local shield = c.add("Shield", V(3.4, 3.8, 0.25), at(-0.3, 4.0, -1.9), GLOW, GLASS, "shield")
	shield.Transparency = 0.45
end

-- Prism Lancer: hovering lens-cannon. Lens in front, core underneath. 12 parts incl. root.
local function buildLancer(c: any)
	c.rig.bob = 0.2
	local y = 5.2
	c.add("Hull", V(4.2, 3.0, 6.4), at(0, y, 0.4), SHELL, CERAMIC)
	c.add("Crest", V(2.2, 2.2, 4.6), at(0, y + 1.6, 0.6) * rot(0, 0, 45), SHELL_DARK, CERAMIC)
	c.add("Barrel", V(2.0, 2.0, 2.4), at(0, y, -3.4), SHELL_DEEP, CERAMIC)
	c.add("Lens", V(1.9, 1.9, 0.6), at(0, y, -4.8), GLOW, NEON, "lens", true)
	c.add("Core", V(1.8, 1.8, 1.8), at(0, y - 2.3, 0.4), CORE, NEON, "core", true)
	for i, s in { -1, 1 } do
		c.add("Fin" .. i, V(0.3, 2.6, 3.6), at(s * 2.7, y + 0.3, 0.8) * rot(0, 0, s * -30), SHELL_DARK, CERAMIC)
	end
	for i = 1, 4 do
		local a = (i - 1) * math.pi / 2 + math.pi / 4
		c.add("Float" .. i, V(0.6, 1.6, 0.6), at(math.cos(a) * 2.2, 1.4, math.sin(a) * 2.6 + 0.4) * rot(0, 45, 0), GLOW, NEON)
	end
end

-- Choir Spire: floating monolith with three resonance nodes (Node1..3) around its shaft. 15 parts incl. root.
local function buildSpire(c: any)
	c.rig.bob = 0
	c.add("Shaft", V(5.5, 18, 5.5), at(0, 13, 0) * rot(0, 45, 0), SHELL, CERAMIC)
	c.add("Base", V(4, 4, 4), at(0, 3.4, 0) * rot(45, 45, 0), SHELL_DARK, CERAMIC)
	c.add("Crown", V(3.6, 6, 3.6), at(0, 24.5, 0) * rot(0, 0, 0), SHELL_DARK, CERAMIC)
	c.add("Halo", V(9, 0.5, 9), at(0, 21, 0) * rot(0, 45, 0), GLOW, NEON)
	c.add("Seam", V(0.5, 14, 0.5), at(0, 13, -3.95), GLOW, NEON)
	for i = 1, 3 do
		local a = (i - 1) * math.pi * 2 / 3 - math.pi / 2
		local p = V(math.cos(a) * 3.6, 12 + (i - 2) * 1.5, math.sin(a) * 3.6)
		c.add("Node" .. i, V(2, 2, 2), CFrame.new(p), NODE_OPEN, NEON, "node", true)
	end
	for i = 1, 6 do
		local a = (i - 1) * math.pi / 3
		local r = if i % 2 == 0 then 6.5 else 7.5
		local h = if i % 2 == 0 then 8 else 17
		c.add("Shard" .. i, V(1, 3.4, 1), at(math.cos(a) * r, h, math.sin(a) * r) * rot(20, math.deg(a), 15), SHELL_DEEP, CERAMIC)
	end
end

LumenModels.BUILDERS = {
	SHARDLING = buildShardling,
	WARDEN = buildWarden,
	LANCER = buildLancer,
	SPIRE = buildSpire,
} :: { [string]: (any) -> () }

LumenModels.Offsets = {
	SHARDLING = { muzzle = Vector3.new(0, 3.2, -0.8), core = Vector3.new(0, 3.2, 0) },
	WARDEN = { muzzle = Vector3.new(1.95, 4.0, -1.6), core = Vector3.new(0, 4.2, 1.0) },
	LANCER = { muzzle = Vector3.new(0, 5.2, -5.2), lens = Vector3.new(0, 5.2, -5.2), core = Vector3.new(0, 2.9, 0.4) },
	SPIRE = { muzzle = Vector3.new(0, 21, -4), core = Vector3.new(0, 13, 0) },
} :: { [string]: { [string]: Vector3 } }

LumenModels.height = { SHARDLING = 4.2, WARDEN = 7, LANCER = 8, SPIRE = 28 } :: { [string]: number }

return LumenModels
