-- Builds the 8 enemy kinds. Preferred path: the Blender MeshParts from World/Assets (Assets.get(kind:lower())),
-- welded to the invisible root. Fallback (asset failed / not loaded yet): the old Part-built models below.
-- Conventions: root is an invisible 1x1x1 part at ground level; model front = -Z, up = +Y.
-- Fallback parts are Anchored, CanCollide=false, CanTouch=false; mesh parts are welded (unanchored) to the
-- anchored root. Every hit part carries attributes EnemyId (number) + Zone (string, a key of Data/Enemies zones).
-- Part budgets for the fallback (incl. root): regular <= 8, medium <= 12, heavy <= 18, behemoth <= 40.
--
-- Mesh models are marked with the model attribute MeshRig = true.
--   Rigged (Data/Meshes entry has `rig`, model attr Rigged = true): Root -> Body Motor6D, every other part hangs off its
--   manifest parent with a Motor6D named like the part (parented inside the child part). client/Fx/EnemyAnim.luau
--   animates Motor6D.Transform locally (no server cost). Joint position = manifest pivot, see buildRigged.
--   Non-rigged (legacy single-piece mesh): plain Welds carrying Sway = "upper" | "legs", animated as a bob/sway.
--
-- API:
--   EnemyModels.build(kindId, enemyId) -> (Model, Rig)
--   EnemyModels.animate(rig, rootCF, t, move, windup)   -- procedural leg motion, call after PivotTo
--   EnemyModels.flash(part)                             -- cheap hit tint
--   EnemyModels.Offsets[kindId] = { muzzle = Vector3, laser = Vector3?, ... }  (root-local)
--   EnemyModels.height[kindId]  -- approximate model height (studs)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Assets = require(script.Parent.Parent.World.Assets)
local EnemyData = require(ReplicatedStorage:WaitForChild("Shared").Data.Enemies)

local EnemyModels = {}

-- Palette ---------------------------------------------------------------------------
local GUNMETAL = Color3.fromRGB(72, 78, 90)
local DARKMETAL = Color3.fromRGB(44, 47, 57)
local STEEL = Color3.fromRGB(104, 112, 126)
local RUST = Color3.fromRGB(196, 108, 44)
local EYE_RED = Color3.fromRGB(255, 40, 36)
local CELL_ORANGE = Color3.fromRGB(255, 160, 50)
local SHIELD_BLUE = Color3.fromRGB(86, 112, 140)

local PURPLE = Color3.fromRGB(98, 56, 132)
local DARKPURPLE = Color3.fromRGB(58, 34, 82)
local BROWN = Color3.fromRGB(104, 70, 48)
local DARKBROWN = Color3.fromRGB(62, 44, 36)
local TEAL = Color3.fromRGB(44, 134, 134)
local DARKTEAL = Color3.fromRGB(26, 80, 88)
local BONE = Color3.fromRGB(214, 202, 168)
local SOFTPINK = Color3.fromRGB(150, 96, 98)
local GLOW = Color3.fromRGB(140, 255, 58)

export type RigEntry = {
	part: BasePart,
	hip: CFrame,
	hipLocal: CFrame,
	amp: number,
	phase: number,
	roll: boolean, -- rotate about Z instead of X
	lift: number, -- extra angle applied while winding up an attack
}
export type Rig = { legs: { RigEntry }, bob: number, mesh: boolean? }

EnemyModels.Offsets = {
	TINKER = { muzzle = Vector3.new(1.45, 3.4, -1.9) },
	RIVET = { muzzle = Vector3.new(1.9, 3.9, -2.6) },
	BULWARK = { muzzle = Vector3.new(3.1, 6.7, -6.8) },
	COLOSSUS = { muzzle = Vector3.new(0, 33, 0), laser = Vector3.new(0, 2.5, -10) },
	SPITTER = { muzzle = Vector3.new(0, 2.4, -3.6) },
	TITAN = { muzzle = Vector3.new(0, 14.5, -19) },
} :: { [string]: { [string]: Vector3 } }

EnemyModels.height = {
	TINKER = 6, RIVET = 7, BULWARK = 8, COLOSSUS = 32,
	SKITTER = 2.2, SPITTER = 4.5, CHARGER = 6.5, TITAN = 25,
} :: { [string]: number }

-- Builder ---------------------------------------------------------------------------
type Ctx = {
	model: Model,
	root: BasePart,
	rig: Rig,
	count: number,
	add: (name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, zone: string?, ball: boolean?) -> BasePart,
	leg: (part: BasePart, hip: Vector3, amp: number, phase: number, roll: boolean?, lift: number?) -> (),
}

local function newCtx(kindId: string, enemyId: number): Ctx
	local model = Instance.new("Model")
	model.Name = kindId
	model:SetAttribute("EnemyId", enemyId)
	model:SetAttribute("Kind", kindId)

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(1, 1, 1)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.CastShadow = false
	root.CFrame = CFrame.new()
	root.Parent = model
	model.PrimaryPart = root

	local rig: Rig = { legs = {}, bob = 0.2 }
	local ctx = { model = model, root = root, rig = rig, count = 1 } :: any

	ctx.add = function(name, size, cf, color, material, zone, ball)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material or Enum.Material.Metal
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = true
		p.CastShadow = size.Magnitude > 6 and material ~= Enum.Material.Neon
		p:SetAttribute("EnemyId", enemyId)
		p:SetAttribute("Zone", zone or "body")
		if ball then
			local m = Instance.new("SpecialMesh")
			m.MeshType = Enum.MeshType.Sphere
			m.Parent = p
		end
		p.Parent = model
		ctx.count += 1
		return p
	end

	ctx.leg = function(part, hip, amp, phase, roll, lift)
		local hipCF = CFrame.new(hip)
		table.insert(rig.legs, {
			part = part,
			hip = hipCF,
			hipLocal = hipCF:Inverse() * part.CFrame,
			amp = amp,
			phase = phase,
			roll = roll == true,
			lift = lift or 0,
		})
	end
	return ctx :: Ctx
end

local function V(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function at(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z)
end

-- Cylinder-ish limb between two points (local Z axis along the segment).
local function seg(a: Vector3, b: Vector3, thick: number): (Vector3, CFrame)
	local d = b - a
	local len = d.Magnitude
	local up = (math.abs(d.Y) > len * 0.98) and Vector3.xAxis or Vector3.yAxis
	return V(thick, thick, len), CFrame.lookAt((a + b) / 2, b, up)
end

local NEON = Enum.Material.Neon
local PLASTIC = Enum.Material.SmoothPlastic
local SLATE = Enum.Material.Slate

-- COGWORK LEGION ---------------------------------------------------------------------
local function buildTinker(c: Ctx)
	local legL = c.add("LegL", V(0.7, 2, 0.7), at(-0.6, 1.0, 0), DARKMETAL)
	local legR = c.add("LegR", V(0.7, 2, 0.7), at(0.6, 1.0, 0), DARKMETAL)
	c.leg(legL, V(-0.6, 2, 0), 0.7, 0)
	c.leg(legR, V(0.6, 2, 0), 0.7, math.pi)
	c.add("Torso", V(2.2, 2.2, 1.6), at(0, 3.1, 0), GUNMETAL)
	c.add("Head", V(1.7, 1.3, 1.5), at(0, 4.9, -0.1), DARKMETAL)
	c.add("Eye", V(1.0, 0.45, 0.2), at(0, 4.95, -0.9), EYE_RED, NEON, "eye")
	c.add("Gun", V(0.5, 0.5, 1.8), at(1.45, 3.4, -0.9), RUST)
	c.add("Antenna", V(0.15, 0.9, 0.15), at(0.5, 5.9, 0.2), STEEL)
end

local function buildRivet(c: Ctx)
	local legL = c.add("LegL", V(0.9, 2.4, 0.9), at(-0.8, 1.2, 0), DARKMETAL)
	local legR = c.add("LegR", V(0.9, 2.4, 0.9), at(0.8, 1.2, 0), DARKMETAL)
	c.leg(legL, V(-0.8, 2.4, 0), 0.6, 0)
	c.leg(legR, V(0.8, 2.4, 0), 0.6, math.pi)
	c.add("Torso", V(2.8, 2.8, 1.9), at(0, 3.8, 0), GUNMETAL)
	c.add("Head", V(1.9, 1.5, 1.7), at(0, 5.9, -0.1), DARKMETAL)
	c.add("Eye", V(1.3, 0.5, 0.2), at(0, 5.95, -1.0), EYE_RED, NEON, "eye")
	c.add("Crest", V(0.4, 0.5, 1.7), at(0, 6.85, 0), RUST)
	c.add("Pack", V(1.4, 1.6, 0.9), at(0, 4.0, 1.4), CELL_ORANGE, NEON, "pack")
	c.add("Gun", V(0.7, 0.7, 2.4), at(1.95, 4.0, -1.2), RUST)
	c.add("ArmL", V(0.7, 0.7, 1.2), at(-2.0, 3.8, -0.9), GUNMETAL)
	c.add("Shield", V(3.4, 3.6, 0.35), at(-0.5, 3.9, -1.9), SHIELD_BLUE, Enum.Material.Metal, "shield")
end

local function buildBulwark(c: Ctx)
	local hips = { { -2.8, -3 }, { 2.8, -3 }, { -2.8, 3 }, { 2.8, 3 } }
	for i, h in hips do
		local l = c.add("Leg" .. i, V(1.7, 2.2, 1.7), at(h[1], 1.1, h[2]), DARKMETAL)
		c.leg(l, V(h[1], 2.2, h[2]), 0.28, (i % 2 == 0) and math.pi or 0)
	end
	c.add("Hull", V(7.2, 3.4, 8.8), at(0, 3.9, 0), GUNMETAL)
	c.add("Stripe", V(7.4, 0.5, 2), at(0, 5.3, 1.2), RUST)
	c.add("Turret", V(5, 2.4, 5), at(0, 6.8, -0.4), DARKMETAL)
	c.add("Eye", V(2.4, 1.6, 0.4), at(0, 6.9, -3.05), EYE_RED, NEON, "eye")
	c.add("Vent", V(3, 1.8, 0.5), at(0, 5.4, 4.55), CELL_ORANGE, NEON, "vent")
	c.add("ShieldArm", V(4.4, 4.6, 1.0), at(-2.2, 4.6, -5.0), STEEL, Enum.Material.Metal, "arm")
	c.add("CannonA", V(0.9, 0.9, 4.4), at(3.1, 7.3, -4.4), RUST)
	c.add("CannonB", V(0.9, 0.9, 4.4), at(3.1, 6.1, -4.4), RUST)
	c.add("PipeL", V(0.7, 2, 0.7), at(-2.2, 6.7, 3), STEEL)
	c.add("PipeR", V(0.7, 2, 0.7), at(2.2, 6.7, 3), STEEL)
	c.add("Antenna", V(0.2, 1.8, 0.2), at(-1.8, 8.9, 0.5), STEEL)
end

local function buildColossus(c: Ctx)
	c.rig.bob = 0.35
	c.add("Body", V(14, 7, 18), at(0, 24.5, 0), GUNMETAL)
	c.add("Deck", V(15.5, 1.6, 11), at(0, 28.6, 2), DARKMETAL)
	c.add("Cockpit", V(7, 5, 7), at(0, 28.5, -7), DARKMETAL, Enum.Material.Metal, "body", true)
	c.add("Eye", V(4.6, 2.6, 0.5), at(0, 28.6, -10.3), EYE_RED, NEON, "eye")
	local emitter = c.add("Emitter", V(3, 3, 4), at(0, 22.5, -10.5), RUST)
	emitter.Name = "Emitter"
	for i, x in { -4.2, 0, 4.2 } do
		c.add("Sink" .. i, V(0.9, 6.5, 6), at(x, 30.4, 6), CELL_ORANGE, NEON, "sink")
	end
	for i, x in { -6, 6 } do
		local tube = c.add("Mortar" .. i, V(2, 5, 2), CFrame.new(x, 30.8, 0) * CFrame.Angles(math.rad(-12), 0, 0), STEEL)
		tube.Name = "Mortar" .. i
	end
	-- four splayed legs: upper, glowing knee joint, lower, foot
	local legDefs = {
		{ -8, -7, -1 }, -- x sign, z sign, leg index sign
		{ 8, -7, 1 },
		{ -8, 7, 1 },
		{ 8, 7, -1 },
	}
	for i, d in legDefs do
		local sx = d[1] > 0 and 1 or -1
		local sz = d[2] > 0 and 1 or -1
		local hip = V(8 * sx, 21.5, 7 * sz)
		local knee = V(12.5 * sx, 14, 9.5 * sz)
		local foot = V(14.5 * sx, 1.2, 12 * sz)
		local phase = d[3] > 0 and math.pi or 0
		local s1, cf1 = seg(hip, knee, 2.6)
		local upper = c.add("Upper" .. i, s1, cf1, DARKMETAL)
		local joint = c.add("Knee" .. i, V(3.6, 3.6, 3.6), CFrame.new(knee), CELL_ORANGE, NEON, "leg", true)
		local s2, cf2 = seg(knee, foot, 2.2)
		local lower = c.add("Lower" .. i, s2, cf2, GUNMETAL)
		local pad = c.add("Foot" .. i, V(4.2, 1.4, 4.8), CFrame.new(foot.X, 0.7, foot.Z), DARKMETAL)
		local lift = (sz < 0) and 0.55 or 0
		for _, p in { upper, joint, lower, pad } do
			c.leg(p, hip, 0.2, phase, false, lift)
		end
	end
end

-- SKITTER BROOD ----------------------------------------------------------------------
local function buildSkitter(c: Ctx)
	c.rig.bob = 0.12
	c.add("Body", V(1.6, 1.1, 2.4), at(0, 1.2, 0), PURPLE, PLASTIC, "body", true)
	c.add("Head", V(1.1, 0.9, 1.0), at(0, 1.3, -1.45), DARKPURPLE, PLASTIC, "head", true)
	c.add("Spot", V(0.55, 0.3, 0.55), at(0, 1.72, -1.35), GLOW, NEON, "head")
	c.add("Stinger", V(0.35, 0.35, 1.1), CFrame.new(0, 1.3, 1.8) * CFrame.Angles(math.rad(-25), 0, 0), BROWN, PLASTIC)
	-- three cross-legs at different yaws read as six legs seen from above
	local yaws = { 0, 52, -52 }
	for i, deg in yaws do
		local cf = CFrame.new(0, 0.75, -0.1) * CFrame.Angles(0, math.rad(deg), 0)
		local leg = c.add("Legs" .. i, V(3.2, 0.2, 0.2), cf, BROWN, PLASTIC)
		c.leg(leg, V(0, 0.75, -0.1), 0.45, (i - 1) * 2.1, true)
	end
end

local function buildSpitter(c: Ctx)
	c.rig.bob = 0.15
	c.add("Body", V(3.2, 2.4, 4.4), at(0, 2.3, 0), TEAL, PLASTIC, "body", true)
	c.add("Head", V(2, 1.7, 2), at(0, 2.6, -2.6), DARKTEAL, PLASTIC, "body", true)
	c.add("Sac", V(2.2, 2.2, 2.6), at(0, 3.9, 1.0), GLOW, NEON, "sac", true)
	c.add("Spike", V(0.7, 1.2, 1.0), at(0, 3.6, -1.0), BONE, PLASTIC)
	c.add("MandL", V(0.4, 0.4, 1.3), CFrame.new(-0.6, 1.9, -3.5) * CFrame.Angles(0, math.rad(12), 0), BONE, PLASTIC)
	c.add("MandR", V(0.4, 0.4, 1.3), CFrame.new(0.6, 1.9, -3.5) * CFrame.Angles(0, math.rad(-12), 0), BONE, PLASTIC)
	local defs = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }
	for i, d in defs do
		local x, zs = d[1] * 1.7, d[2]
		local cf = CFrame.new(x, 0.85, zs * 1.0) * CFrame.Angles(0, 0, math.rad(-d[1] * 22))
		local l = c.add("Leg" .. i, V(0.45, 1.8, 0.45), cf, DARKTEAL, PLASTIC)
		c.leg(l, V(d[1] * 1.4, 1.7, zs * 1.0), 0.6, (i == 1 or i == 4) and 0 or math.pi)
	end
end

local function buildCharger(c: Ctx)
	c.rig.bob = 0.15
	for i = 1, 6 do
		local side = (i % 2 == 1) and -1 or 1
		local z = ({ -2.6, -2.6, 0.5, 0.5, 3.6, 3.6 })[i]
		local l = c.add("Leg" .. i, V(0.9, 2.6, 0.9), at(side * 2.9, 1.3, z), DARKBROWN, PLASTIC, "leg")
		c.leg(l, V(side * 2.9, 2.6, z), 0.5, ((i + (i > 2 and 1 or 0)) % 2) * math.pi)
	end
	c.add("Thorax", V(5.6, 4, 6.4), at(0, 3.7, -1.0), BROWN, PLASTIC, "body", true)
	c.add("HeadPlate", V(6.4, 4.4, 3.4), at(0, 3.6, -5.1), DARKBROWN, Enum.Material.Metal, "body")
	c.add("HornL", V(0.9, 0.9, 3.2), at(-1.9, 2.9, -7.4), BONE, PLASTIC)
	c.add("HornR", V(0.9, 0.9, 3.2), at(1.9, 2.9, -7.4), BONE, PLASTIC)
	c.add("Back1", V(4.6, 0.9, 3), at(0, 5.8, -1.0), DARKBROWN, Enum.Material.Metal)
	c.add("Back2", V(4.2, 0.8, 2.2), at(0, 5.3, 2.0), DARKBROWN, Enum.Material.Metal)
	c.add("Abdomen", V(5, 3.6, 5.4), at(0, 3.3, 4.8), SOFTPINK, PLASTIC, "rear", true)
	c.add("RearGlow", V(3.2, 0.5, 2.6), at(0, 5.0, 5.4), GLOW, NEON, "rear")
end

local function buildTitan(c: Ctx)
	c.rig.bob = 0.45
	c.add("Body", V(16, 13, 22), at(0, 13, 2), DARKPURPLE, PLASTIC, "body", true)
	c.add("Belly", V(11, 4, 16), at(0, 6.4, 3), SOFTPINK, PLASTIC, "belly", true)
	c.add("Head", V(9, 8, 10), at(0, 17.5, -12), PURPLE, PLASTIC, "body", true)
	c.add("Throat", V(5, 5, 5), at(0, 13, -13.5), GLOW, NEON, "throat", true)
	c.add("MandL", V(1.4, 1.4, 7), CFrame.new(-3.6, 15, -17.5) * CFrame.Angles(0, math.rad(-14), 0), BONE, PLASTIC)
	c.add("MandR", V(1.4, 1.4, 7), CFrame.new(3.6, 15, -17.5) * CFrame.Angles(0, math.rad(14), 0), BONE, PLASTIC)
	c.add("EyeL", V(1.3, 1.3, 0.7), at(-2.8, 19.5, -16.6), GLOW, NEON)
	c.add("EyeR", V(1.3, 1.3, 0.7), at(2.8, 19.5, -16.6), GLOW, NEON)
	for i = 1, 5 do
		c.add("Spike" .. i, V(1.5, 4.6, 1.5), at(0, 20.6 - math.abs(i - 3) * 0.5, -6 + i * 4.2), BONE, PLASTIC)
	end
	c.add("PlateL", V(5, 2, 9), CFrame.new(-6, 19, 0) * CFrame.Angles(0, 0, math.rad(15)), DARKBROWN, SLATE)
	c.add("PlateR", V(5, 2, 9), CFrame.new(6, 19, 0) * CFrame.Angles(0, 0, math.rad(-15)), DARKBROWN, SLATE)
	local zs = { -6, 3, 11 }
	for i, z in zs do
		for _, sx in { -1, 1 } do
			local hip = V(7 * sx, 10, z)
			local knee = V(13 * sx, 15, z - 1)
			local foot = V(15 * sx, 0.8, z - 1.5)
			local s1, cf1 = seg(hip, knee, 2.4)
			local upper = c.add("Upper" .. i .. sx, s1, cf1, PURPLE, PLASTIC, "body")
			local s2, cf2 = seg(knee, foot, 1.8)
			local lower = c.add("Lower" .. i .. sx, s2, cf2, DARKPURPLE, PLASTIC, "body")
			local phase = ((i + (sx > 0 and 1 or 0)) % 2) * math.pi
			c.leg(upper, hip, 0.22, phase, false, 0)
			c.leg(lower, hip, 0.22, phase, false, 0)
		end
	end
end

local BUILDERS: { [string]: (Ctx) -> () } = {
	TINKER = buildTinker,
	RIVET = buildRivet,
	BULWARK = buildBulwark,
	COLOSSUS = buildColossus,
	SKITTER = buildSkitter,
	SPITTER = buildSpitter,
	CHARGER = buildCharger,
	TITAN = buildTitan,
}

-- MESH PATH --------------------------------------------------------------------------
-- Manifest role -> zone. weak = the kind's weak-spot zone, armor = armour zone, everything else = "body".
-- Per-part overrides cover the zones that have their own geometry in the new models.
local WEAK_ZONE: { [string]: string } = {
	TINKER = "eye", RIVET = "eye", BULWARK = "eye", COLOSSUS = "eye",
	SKITTER = "head", SPITTER = "sac", CHARGER = "rear", TITAN = "throat",
}
local ARMOR_ZONE: { [string]: string } = {} -- armor parts (Charger "Ram") are the main body armour: "body"
local PART_ZONE: { [string]: { [string]: string } } = {
	BULWARK = { Shield = "arm" }, -- blocking front plate
	COLOSSUS = { Joint_1 = "leg", Joint_2 = "leg", Joint_3 = "leg", Joint_4 = "leg" },
	CHARGER = { Legs = "leg", Leg_1 = "leg", Leg_2 = "leg", Leg_3 = "leg", Leg_4 = "leg", Leg_5 = "leg", Leg_6 = "leg" },
	TITAN = { Belly = "belly" },
}

-- Muzzle positions of the meshes, as fractions of the bounding box (x, y, z; z = -0.5 is the front edge).
-- Written into EnemyModels.Offsets the first time a mesh of that kind is built.
local MESH_MUZZLE: { [string]: { number } } = {
	TINKER = { 0.38, 0.54, -0.5 },
	RIVET = { 0.37, 0.52, -0.5 },
	BULWARK = { 0, 0.6, -0.5 },
	COLOSSUS = { 0, 0.99, 0 },
	SPITTER = { 0, 0.94, -0.5 },
	TITAN = { 0, 0.6, -0.5 },
}
local offsetsApplied: { [string]: boolean } = {}

local function applyMeshOffsets(kindId: string, size: Vector3)
	if offsetsApplied[kindId] then
		return
	end
	offsetsApplied[kindId] = true
	local f = MESH_MUZZLE[kindId]
	if not f then
		return
	end
	local o: { [string]: Vector3 } = EnemyModels.Offsets[kindId] or {}
	o.muzzle = Vector3.new(f[1] * size.X, f[2] * size.Y, f[3] * size.Z)
	if kindId == "COLOSSUS" then
		o.laser = Vector3.new(0, 2.5, -size.Z * 0.45)
	end
	EnemyModels.Offsets[kindId] = o
end

local function zoneFor(kindId: string, partName: string, role: string, def: any): string
	local z = PART_ZONE[kindId] and PART_ZONE[kindId][partName]
	if not z then
		if role == "weak" then
			z = WEAK_ZONE[kindId]
		elseif role == "armor" then
			z = ARMOR_ZONE[kindId]
		end
	end
	if z and def.zones[z] then
		return z
	end
	return "body"
end

local function prepPart(mp: BasePart, enemyId: number, zone: string)
	mp.Anchored = false
	mp.CanCollide = false
	mp.CanTouch = false
	mp.CanQuery = true
	mp.Massless = true
	mp:SetAttribute("EnemyId", enemyId)
	mp:SetAttribute("Zone", zone)
end

-- COG weak spots (eyes, cores, joints) come out of the manifest orange-yellow, which bloom washes out into big
-- yellow-white discs. Recolour them a deep red so they read as menacing eyes, and shrink the oversized Tinker eye.
-- Same for BROOD: lime (140,255,60) blooms to flat yellow blobs; a deeper acid green keeps its colour.
local GLOW_FIX: { [string]: { color: Color3, shrink: { [string]: number } } } = {
	COG = { color = Color3.fromRGB(235, 34, 24), shrink = { TINKER_Eye = 0.72 } },
	BROOD = { color = Color3.fromRGB(70, 200, 40), shrink = { SKITTER_Eye = 0.7 } },
}
local function tuneGlow(kindId: string, def: any, part: BasePart)
	local fix = GLOW_FIX[def.faction]
	if not fix or part.Material ~= Enum.Material.Neon then
		return
	end
	part.Color = fix.color
	local k = fix.shrink[kindId .. "_" .. part.Name]
	if k then
		part.Size *= k
	end
end

local function roleOf(mp: Instance): string
	local role = mp:GetAttribute("Role")
	return if type(role) == "string" then role else "body"
end

-- Legacy single-piece mesh: every part welded to the root, client sways the welds.
local function buildFromMesh(kindId: string, enemyId: number, tpl: Model): (Model, Rig)
	local def = EnemyData.get(kindId)
	assert(def, "unknown enemy kind " .. kindId)
	local c = newCtx(kindId, enemyId)
	local model, root = c.model, c.root
	model:SetAttribute("MeshRig", true)
	c.rig.mesh = true
	c.rig.bob = 0 -- bobbing is done by the client on the body welds (EnemyAnim), not by hopping the whole model

	for _, mp in tpl:GetChildren() do
		if mp:IsA("MeshPart") then
			tuneGlow(kindId, def, mp)
			prepPart(mp, enemyId, zoneFor(kindId, mp.Name, roleOf(mp), def))
			-- template coordinates: feet on y = 0, centred on x/z, front = -Z; the root sits at the model origin
			local w = Instance.new("Weld")
			w.Name = "W_" .. mp.Name
			w.Part0 = root
			w.Part1 = mp
			w.C0 = mp.CFrame
			w.C1 = CFrame.new()
			w:SetAttribute("Sway", if mp.Name == "Legs" then "legs" else "upper")
			mp.Parent = model
			w.Parent = mp
			c.count += 1
		end
	end
	local size = Assets.size(kindId:lower())
	if size then
		applyMeshOffsets(kindId, size)
	end
	tpl:Destroy()
	return model, c.rig
end

-- Rigged mesh. Joint maths (all in template space: feet on y = 0, bounding box centred on x/z, front = -Z):
--   the manifest pivot P is in the Blender feet-origin frame; Assets recentred the bounding box on x/z, so the joint
--   point is  J = P - (rig.center.X, 0, rig.center.Z).
--   For a Motor6D  Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse(). Choosing
--     C0 = Part0.CFrame:Inverse() * CFrame.new(J)     (joint seen from the parent part)
--     C1 = Part1.CFrame:Inverse() * CFrame.new(J)     (joint seen from the child part)
--   gives Part1.CFrame = Part1.CFrame at Transform = identity (the pose does not move), and Transform then rotates
--   the child about exactly J, in the axes of the template (X right, Y up, -Z forward) rotated by its parents.
--   Root sits at the template origin, so Root -> Body uses the Body pivot (lean/bob about the hips).
local function buildRigged(kindId: string, enemyId: number, tpl: Model, info: any): (Model, Rig)
	local def = EnemyData.get(kindId)
	assert(def, "unknown enemy kind " .. kindId)
	local c = newCtx(kindId, enemyId)
	local model, root = c.model, c.root
	model:SetAttribute("MeshRig", true)
	model:SetAttribute("Rigged", true)
	c.rig.mesh = true
	c.rig.bob = 0

	local rig = info.rig
	local off = Vector3.new(rig.center.X, 0, rig.center.Z)
	local byName: { [string]: BasePart } = {}
	for _, d in tpl:GetChildren() do
		if d:IsA("BasePart") then
			byName[d.Name] = d
			tuneGlow(kindId, def, d)
		end
	end
	assert(byName.Body, "rigged template has no Body part")

	local done: { [string]: boolean } = {}
	for _, rp in rig.parts do -- parents are listed before their children (gen_meshes.py)
		local part = byName[rp.name]
		if not part then
			continue
		end
		local parentPart: BasePart = root
		if rp.parent then
			parentPart = byName[rp.parent] or byName.Body
			if rp.name == "Body" then
				parentPart = root
			end
		end
		local j = CFrame.new(rp.pivot - off)
		prepPart(part, enemyId, zoneFor(kindId, rp.name, rp.role, def))
		local m = Instance.new("Motor6D")
		m.Name = rp.name
		m.Part0 = parentPart
		m.Part1 = part
		m.C0 = parentPart.CFrame:Inverse() * j
		m.C1 = part.CFrame:Inverse() * j
		part.Parent = model
		m.Parent = part
		done[rp.name] = true
		c.count += 1
	end
	-- anything the manifest does not know about stays rigidly on the body
	for name, part in byName do
		if not done[name] then
			prepPart(part, enemyId, zoneFor(kindId, name, roleOf(part), def))
			local w = Instance.new("Weld")
			w.Name = "W_" .. name
			w.Part0 = byName.Body
			w.Part1 = part
			w.C0 = byName.Body.CFrame:Inverse() * part.CFrame
			w.C1 = CFrame.new()
			part.Parent = model
			w.Parent = part
			c.count += 1
		end
	end
	local size = Assets.size(kindId:lower())
	if size then
		applyMeshOffsets(kindId, size)
	end
	tpl:Destroy()
	return model, c.rig
end

function EnemyModels.build(kindId: string, enemyId: number): (Model, Rig)
	local builder = BUILDERS[kindId]
	assert(builder, "EnemyModels: unknown kind " .. tostring(kindId))

	local tpl = Assets.get(string.lower(kindId))
	if tpl then
		local info = Assets.info(string.lower(kindId))
		local ok, model, rig
		if tpl:GetAttribute("Rigged") == true and info and info.rig then
			ok, model, rig = pcall(buildRigged, kindId, enemyId, tpl, info)
		else
			ok, model, rig = pcall(buildFromMesh, kindId, enemyId, tpl)
		end
		if ok then
			return model, rig
		end
		warn("[EnemyModels] mesh build failed for", kindId, model)
		tpl:Destroy()
	end

	local c = newCtx(kindId, enemyId)
	builder(c)
	return c.model, c.rig
end

-- Procedural animation --------------------------------------------------------------
-- t: accumulated walk phase (advance by dt * speed * k), move: 0..1 how fast it is going,
-- windup: 0..1 attack wind-up (raises front legs on big walkers).
function EnemyModels.animate(rig: Rig, rootCF: CFrame, t: number, move: number, windup: number)
	for _, e in rig.legs do
		local ang = math.sin(t + e.phase) * e.amp * move + e.lift * windup
		local rot = if e.roll then CFrame.Angles(0, 0, ang) else CFrame.Angles(ang, 0, 0)
		e.part.CFrame = rootCF * e.hip * rot * e.hipLocal
	end
end

-- Hit flash ------------------------------------------------------------------------
local flashing: { [BasePart]: Color3 } = setmetatable({}, { __mode = "k" }) :: any

function EnemyModels.flash(part: BasePart)
	if flashing[part] then
		return
	end
	flashing[part] = part.Color
	part.Color = Color3.new(1, 1, 1)
	task.delay(0.07, function()
		local orig = flashing[part]
		flashing[part] = nil
		if orig and part.Parent then
			part.Color = orig
		end
	end)
end

return EnemyModels
