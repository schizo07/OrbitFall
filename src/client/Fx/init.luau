--!nonstrict
-- Client FX core (client side). Receives Fx/FxU remotes, owns the shared particle/part helpers and the core kinds:
--   Explosion, Tracer, Impact, Death, Shake, Sound, Shockwave, Debris, Muzzle
--
-- Public API (for other client modules and WeaponController):
--   Fx.init()                            connect remotes, load every ModuleScript in the `Fx` folder and call .init(Fx, Audio, Juice)
--   Fx.register(kind, fn(data))          add a handler (several handlers per kind are allowed)
--   Fx.handle(kind, data)                dispatch (pcall'd)
--   Fx.explosion(p, {size="S|M|L|XL", r=, style="fire|emp|gas|goo|spark", silent=, noShake=})
--   Fx.debris(p, {n=, color=, style="scrap|goo|rock|ember", speed=, up=, scale=, life=, dir=, bias=})  dir/bias throw pieces along a direction
--   Fx.enemyHit(p, n, result)            set by EnemyAnim: jolts the enemy nearest to a bullet impact (called from Fx.impact)
--   Fx.splat(p, radius, color?, life?, dir?)  goo puddle (cap 16, fades after life s)
--   Death data (server): {p, faction, class, style, size, kind, dir?, by?, src?, weak?, blast?}: dir = shot direction, by = killer userId
--   Fx.tracer(a, b, color, width?)
--   Fx.impact(p, n, result, material)
--   Fx.muzzleFlash(attachmentOrPosOrPart, color)
--   Fx.shockwave(p, r, color?)
--   Fx.scorch(p, radius) / Fx.splat(p, radius, color?)
--   Fx.burst(preset, at, count, opts?)   pooled particle burst; presets: sparks puff smoke fire goo dust zap
--   Fx.visual(size, color, cf, shape, material, transparency, life) -> Part? (budgeted transient part)
--   Fx.tween(inst, dur, props, style?, dir?) -> Tween
--   Fx.groundAt(p, up?, down?) -> (pos?, normal?)
--   Fx.camDistance(p) -> number
--   Fx.quality (number, 0.3-1)           particle/debris scale (phone 0.5)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Weapons = require(Shared:WaitForChild("Data"):WaitForChild("Weapons"))
local Meshes = require(Shared:WaitForChild("Data"):WaitForChild("Meshes"))
local Audio = require(script.Parent:WaitForChild("Audio"))
local Juice = require(script.Parent:WaitForChild("Juice"))

local LocalPlayer = Players.LocalPlayer
local rng = Random.new()

local Fx = {}

-- TEXTURES --------------------------------------------------------------------------
local TEX_FIRE = "rbxasset://textures/particles/fire_main.dds"
local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"

local Quad = Enum.EasingStyle.Quad
local Back = Enum.EasingStyle.Back
local Out = Enum.EasingDirection.Out
local In = Enum.EasingDirection.In

-- QUALITY ---------------------------------------------------------------------------
local function computeQuality(): number
	local q = 1
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		q = 0.5
	end
	local ok, lvl = pcall(function()
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel.Value
	end)
	if ok and type(lvl) == "number" and lvl > 0 then
		if lvl <= 3 then
			q *= 0.6
		elseif lvl <= 6 then
			q *= 0.85
		end
	end
	return math.max(q, 0.3)
end
Fx.quality = computeQuality()

local function scaleN(n: number): number
	if n <= 0 then
		return 0
	end
	return math.max(1, math.floor(n * Fx.quality + 0.5))
end

local function rnd(a: number, b: number): number
	return a + (b - a) * rng:NextNumber()
end

local function randUnit(): Vector3
	return Vector3.new(rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)).Unit
end

-- FOLDER ----------------------------------------------------------------------------
local fxFolder: Folder
do
	local old = workspace:FindFirstChild("ClientFx")
	if old then
		old:Destroy()
	end
	fxFolder = Instance.new("Folder")
	fxFolder.Name = "ClientFx"
	fxFolder.Parent = workspace
end
Fx.folder = fxFolder

function Fx.camDistance(p: Vector3): number
	local cam = workspace.CurrentCamera
	if not cam then
		return 0
	end
	return (cam.CFrame.Position - p).Magnitude
end
local camDist = Fx.camDistance

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

function Fx.groundAt(p: Vector3, up: number?, down: number?): (Vector3?, Vector3?)
	local u, d = up or 3, down or 14
	local filter = { fxFolder }
	if LocalPlayer.Character then
		table.insert(filter, LocalPlayer.Character)
	end
	local enemies = workspace:FindFirstChild("Enemies")
	if enemies then
		table.insert(filter, enemies)
	end
	local audioPart = workspace:FindFirstChild("ClientAudio")
	if audioPart then
		table.insert(filter, audioPart)
	end
	rayParams.FilterDescendantsInstances = filter
	local r = workspace:Raycast(p + Vector3.new(0, u, 0), Vector3.new(0, -(u + d), 0), rayParams)
	if r then
		return r.Position, r.Normal
	end
	return nil, nil
end

-- PART HELPERS ----------------------------------------------------------------------
local function mkPart(size: Vector3, color: Color3, cf: CFrame, shape: Enum.PartType?, material: Enum.Material?, transparency: number?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Shape = shape or Enum.PartType.Block
	p.Material = material or Enum.Material.Neon
	p.Size = size
	p.Color = color
	p.Transparency = transparency or 0
	p.CFrame = cf
	p.Parent = fxFolder
	return p
end

local visualCount = 0
local VISUAL_BUDGET = 160

-- Budgeted transient anchored part, auto-destroyed after `life`. Returns nil when over budget.
function Fx.visual(size: Vector3, color: Color3, cf: CFrame, shape: Enum.PartType?, material: Enum.Material?, transparency: number?, life: number): Part?
	if visualCount >= VISUAL_BUDGET then
		return nil
	end
	visualCount += 1
	local p = mkPart(size, color, cf, shape, material, transparency)
	task.delay(life, function()
		visualCount -= 1
		if p.Parent then
			p:Destroy()
		end
	end)
	return p
end
local visual = Fx.visual

function Fx.tween(inst: Instance, dur: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local t = TweenService:Create(inst, TweenInfo.new(dur, style or Quad, dir or Out), props)
	t:Play()
	return t
end
local tween = Fx.tween

-- ANIMATION LOOP (tracers, muzzle flashes: no Tween objects) -------------------------
local anims: { (number) -> boolean } = {}
local animConn: RBXScriptConnection? = nil

local animWarned = false
local animCleanup: { [any]: () -> () } = {}
local function stepAnims(dt: number)
	-- each anim is pcall'd: one erroring anim must not abort the loop every frame (that would freeze every tracer /
	-- muzzle flash after it in mid-air, glowing forever). A failed anim is dropped.
	for i = #anims, 1, -1 do
		local fn = anims[i]
		local ok, done = pcall(fn, dt)
		if not ok then
			if not animWarned then
				animWarned = true
				warn("[Fx] anim failed: " .. tostring(done))
			end
			local cleanup = animCleanup[fn]
			if cleanup then
				pcall(cleanup)
			end
		end
		if not ok or done then
			animCleanup[fn] = nil
			local j = if anims[i] == fn then i else table.find(anims, fn)
			if j then
				local n = #anims
				anims[j] = anims[n]
				anims[n] = nil
			end
		end
	end
	if #anims == 0 and animConn then
		animConn:Disconnect()
		animConn = nil
	end
end

-- `cleanup` runs if the anim ever errors (it is then dropped), so its parts never stay frozen on screen
local function addAnim(fn: (number) -> boolean, cleanup: (() -> ())?)
	table.insert(anims, fn)
	if cleanup then
		animCleanup[fn] = cleanup
	end
	if not animConn then
		animConn = RunService.Heartbeat:Connect(stepAnims)
	end
end

-- PARTICLE PRESETS + POOLS ----------------------------------------------------------
local C3 = Color3.fromRGB

local PRESETS = {
	sparks = {
		tex = TEX_SPARK, pool = 16, light = 1,
		color = { { 0, C3(255, 255, 225) }, { 0.4, C3(255, 205, 90) }, { 1, C3(255, 120, 30) } },
		size = { { 0, 0.55 }, { 1, 0 } }, transp = { { 0, 0 }, { 0.7, 0.15 }, { 1, 1 } },
		life = { 0.25, 0.55 }, speed = { 22, 48 }, spread = 180, accel = Vector3.new(0, -70, 0), drag = 1.5,
		orient = Enum.ParticleOrientation.VelocityParallel, rot = { 0, 0 }, rotSpeed = { 0, 0 },
	},
	zap = {
		tex = TEX_SPARK, pool = 8, light = 1,
		color = { { 0, C3(235, 255, 255) }, { 0.5, C3(90, 220, 255) }, { 1, C3(40, 120, 255) } },
		size = { { 0, 0.8 }, { 1, 0 } }, transp = { { 0, 0 }, { 1, 1 } },
		life = { 0.2, 0.45 }, speed = { 15, 42 }, spread = 180, accel = Vector3.zero, drag = 3,
		orient = Enum.ParticleOrientation.VelocityParallel, rot = { 0, 0 }, rotSpeed = { 0, 0 },
	},
	puff = {
		tex = TEX_SMOKE, pool = 12, light = 0,
		color = { { 0, C3(205, 205, 205) }, { 1, C3(120, 120, 120) } },
		size = { { 0, 0.8 }, { 1, 3 } }, transp = { { 0, 0.4 }, { 1, 1 } },
		life = { 0.35, 0.7 }, speed = { 4, 10 }, spread = 180, accel = Vector3.new(0, 3, 0), drag = 3,
		rot = { 0, 360 }, rotSpeed = { -60, 60 },
	},
	smoke = {
		tex = TEX_SMOKE, pool = 12, light = 0,
		color = { { 0, C3(95, 88, 82) }, { 1, C3(45, 45, 45) } },
		size = { { 0, 2 }, { 1, 8 } }, transp = { { 0, 0.35 }, { 0.6, 0.55 }, { 1, 1 } },
		life = { 1.2, 2.2 }, speed = { 3, 12 }, spread = 90, accel = Vector3.new(0, 6, 0), drag = 2,
		rot = { 0, 360 }, rotSpeed = { -40, 40 },
	},
	fire = {
		tex = TEX_FIRE, pool = 10, light = 1,
		color = { { 0, C3(255, 245, 190) }, { 0.35, C3(255, 160, 50) }, { 1, C3(200, 60, 20) } },
		size = { { 0, 2.5 }, { 0.4, 6 }, { 1, 1 } }, transp = { { 0, 0 }, { 0.6, 0.3 }, { 1, 1 } },
		life = { 0.3, 0.6 }, speed = { 6, 22 }, spread = 180, accel = Vector3.new(0, 4, 0), drag = 2,
		rot = { 0, 360 }, rotSpeed = { -90, 90 },
	},
	goo = {
		tex = TEX_SMOKE, pool = 8, light = 0.25,
		color = { { 0, C3(160, 255, 110) }, { 1, C3(60, 170, 50) } },
		size = { { 0, 1 }, { 1, 3.5 } }, transp = { { 0, 0.1 }, { 1, 1 } },
		life = { 0.4, 0.8 }, speed = { 10, 24 }, spread = 180, accel = Vector3.new(0, -25, 0), drag = 2,
		rot = { 0, 360 }, rotSpeed = { -90, 90 },
	},
	dust = {
		tex = TEX_SMOKE, pool = 10, light = 0,
		color = { { 0, C3(190, 165, 130) }, { 1, C3(140, 120, 95) } },
		size = { { 0, 1 }, { 1, 4 } }, transp = { { 0, 0.5 }, { 1, 1 } },
		life = { 0.4, 0.9 }, speed = { 3, 9 }, spread = 50, accel = Vector3.new(0, 2, 0), drag = 3,
		rot = { 0, 360 }, rotSpeed = { -40, 40 },
	},
}

local function numSeq(list, mult: number): NumberSequence
	local kps = {}
	for i, k in list do
		kps[i] = NumberSequenceKeypoint.new(k[1], math.max(k[2] * mult, 0))
	end
	return NumberSequence.new(kps)
end

local function transSeq(list): NumberSequence
	local kps = {}
	for i, k in list do
		kps[i] = NumberSequenceKeypoint.new(k[1], k[2])
	end
	return NumberSequence.new(kps)
end

local function colorSeq(list): ColorSequence
	local kps = {}
	for i, k in list do
		kps[i] = ColorSequenceKeypoint.new(k[1], k[2])
	end
	return ColorSequence.new(kps)
end

local function configure(em: ParticleEmitter, s, scale: number, speedMul: number, color: any?, spread: number?)
	em.Texture = s.tex
	local sp = spread or s.spread
	em.SpreadAngle = Vector2.new(sp, sp)
	if color then
		if typeof(color) == "Color3" then
			em.Color = ColorSequence.new(color)
		else
			em.Color = color
		end
	else
		em.Color = colorSeq(s.color)
	end
	em.Size = numSeq(s.size, scale)
	em.Speed = NumberRange.new(s.speed[1] * speedMul, s.speed[2] * speedMul)
end

local pools: { [string]: { entries: { any }, idx: number } } = {}

local function getPool(name: string)
	local pool = pools[name]
	if pool then
		return pool
	end
	local s = PRESETS[name]
	pool = { entries = {}, idx = 0 }
	for i = 1, s.pool do
		local part = mkPart(Vector3.new(0.2, 0.2, 0.2), Color3.new(1, 1, 1), CFrame.new(0, 3000, 0), nil, Enum.Material.SmoothPlastic, 1)
		part.Name = "Emitter_" .. name
		local em = Instance.new("ParticleEmitter")
		em.Enabled = false
		em.Rate = 0
		em.LockedToPart = false
		em.LightEmission = s.light
		em.LightInfluence = if s.light > 0.5 then 0 else 0.6
		em.Lifetime = NumberRange.new(s.life[1], s.life[2])
		em.SpreadAngle = Vector2.new(s.spread, s.spread)
		em.Acceleration = s.accel
		em.Drag = s.drag
		em.Transparency = transSeq(s.transp)
		em.Rotation = NumberRange.new(s.rot[1], s.rot[2])
		em.RotSpeed = NumberRange.new(s.rotSpeed[1], s.rotSpeed[2])
		if s.orient then
			em.Orientation = s.orient
		end
		configure(em, s, 1, 1, nil)
		em.Parent = part
		pool.entries[i] = { part = part, em = em, dirty = false }
	end
	pools[name] = pool
	return pool
end

-- Emits `count` particles of a pooled preset. `at` is a Vector3 or a CFrame (+Y = emission axis).
-- opts: color (Color3 | ColorSequence), scale (size mult), speed (speed mult), noScale (skip quality scaling)
-- opts.spread = emission cone half-angle in degrees (default per preset, mostly 180 = all directions); with a CFrame `at`
-- (+Y = axis, see upCF) a small spread makes a directed spray.
function Fx.burst(name: string, at: Vector3 | CFrame, count: number, opts: { color: any?, scale: number?, speed: number?, noScale: boolean?, spread: number? }?)
	local s = PRESETS[name]
	if not s then
		return
	end
	local n = if opts and opts.noScale then math.max(1, math.floor(count + 0.5)) else scaleN(count)
	if n <= 0 then
		return
	end
	local pool = getPool(name)
	pool.idx = pool.idx % #pool.entries + 1
	local e = pool.entries[pool.idx]
	e.part.CFrame = if typeof(at) == "CFrame" then at else CFrame.new(at)
	local custom = opts ~= nil and (opts.color ~= nil or opts.spread ~= nil or (opts.scale ~= nil and opts.scale ~= 1) or (opts.speed ~= nil and opts.speed ~= 1))
	if custom then
		configure(e.em, s, opts.scale or 1, opts.speed or 1, opts.color, opts.spread)
		e.dirty = true
	elseif e.dirty then
		configure(e.em, s, 1, 1, nil)
		e.dirty = false
	end
	e.em:Emit(n)
end
local burst = Fx.burst

-- CFrame at p whose +Y axis points along `normal` (also the particle emission axis)
local function upCF(p: Vector3, normal: Vector3): CFrame
	local ref = if math.abs(normal.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local x = ref:Cross(normal).Unit
	local z = x:Cross(normal)
	return CFrame.fromMatrix(p, x, normal, z)
end

-- CFrame at p whose +X axis points along `axis` (flat Cylinder parts lie on the ground with X = normal)
local function xAxisCF(p: Vector3, axis: Vector3): CFrame
	local ref = if math.abs(axis.Y) > 0.99 then Vector3.zAxis else Vector3.yAxis
	local z = axis:Cross(ref).Unit
	local y = z:Cross(axis)
	return CFrame.fromMatrix(p, axis, y, z)
end

-- DEBRIS (physics, FIFO budget) -----------------------------------------------------
local liveDebris: { Part } = {}
local debrisGroup: string? = nil
local debrisGroupTried = false

local function setupDebrisGroup()
	debrisGroupTried = true
	local ok = pcall(function()
		local PS = game:GetService("PhysicsService")
		if not PS:IsCollisionGroupRegistered("FxDebris") then
			PS:RegisterCollisionGroup("FxDebris")
		end
		PS:CollisionGroupSetCollidable("FxDebris", "FxDebris", false)
		for _, g in PS:GetRegisteredCollisionGroups() do
			if g.name == "Players" then
				PS:CollisionGroupSetCollidable("FxDebris", "Players", false)
			end
		end
	end)
	if ok then
		debrisGroup = "FxDebris"
	end
end

local function debrisBudget(): number
	return if Fx.quality < 0.75 then 36 else 60
end

local function removeDebris(part: Part)
	local i = table.find(liveDebris, part)
	if i then
		table.remove(liveDebris, i)
	end
	if part.Parent then
		part:Destroy()
	end
end

local SCRAP_COLORS = { C3(120, 125, 135), C3(92, 97, 108), C3(160, 165, 176), C3(70, 74, 84), C3(190, 120, 60) }

local function makeDebrisPiece(style: string, scale: number, color: Color3?): (Part, boolean)
	local part = Instance.new("Part")
	part.Anchored = false
	part.CanCollide = true
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CustomPhysicalProperties = PhysicalProperties.new(0.3, 0.6, 0.35, 1, 1)
	if debrisGroup then
		part.CollisionGroup = debrisGroup
	end
	local bounceFade = false
	if style == "goo" then
		local d = rnd(0.4, 1.0) * scale
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.new(d, d, d)
		part.Material = Enum.Material.Neon
		part.Color = color or C3(110, 235, 70):Lerp(C3(180, 255, 120), rng:NextNumber())
		part.CustomPhysicalProperties = PhysicalProperties.new(0.2, 0.9, 0.05, 1, 1)
		bounceFade = true
	elseif style == "rock" then
		part.Size = Vector3.new(rnd(0.4, 1.3), rnd(0.3, 1.0), rnd(0.4, 1.3)) * scale
		part.Material = Enum.Material.Slate
		part.Color = color or C3(110, 98, 84):Lerp(C3(70, 66, 62), rng:NextNumber())
	elseif style == "ember" then
		local d = rnd(0.15, 0.3) * scale
		part.Size = Vector3.new(d, d, d)
		part.Material = Enum.Material.Neon
		part.Color = C3(255, 170, 50):Lerp(C3(255, 230, 120), rng:NextNumber())
	else -- scrap: bolts, plates, gears
		local r = rng:NextNumber()
		if r < 0.4 then -- bolt
			local d = rnd(0.25, 0.45) * scale
			part.Shape = Enum.PartType.Ball
			part.Size = Vector3.new(d, d, d)
			part.Material = Enum.Material.Metal
			part.Color = C3(205, 205, 215)
		elseif r < 0.8 then -- plate
			part.Size = Vector3.new(rnd(0.7, 1.4), rnd(0.1, 0.2), rnd(0.6, 1.2)) * scale
			part.Material = Enum.Material.Metal
			part.Color = if color and rng:NextNumber() < 0.8 then color else SCRAP_COLORS[rng:NextInteger(1, #SCRAP_COLORS)]
		else -- gear
			local d = rnd(0.7, 1.1) * scale
			part.Shape = Enum.PartType.Cylinder
			part.Size = Vector3.new(0.15 * scale, d, d)
			part.Material = Enum.Material.Metal
			part.Color = color or C3(205, 140, 70)
		end
	end
	return part, bounceFade
end

-- opts.palette: list of Color3, each piece picks one at random (overrides opts.color)
-- opts.dir (unit Vector3) + opts.bias (0..2, default 1): pieces are thrown along dir (the way the shot travelled) instead of
-- uniformly; bias 0 = no preference.
function Fx.debris(p: Vector3, opts: { n: number?, color: Color3?, style: string?, speed: number?, up: number?, scale: number?, life: number?, palette: { Color3 }?, dir: Vector3?, bias: number? }?)
	opts = opts or {}
	local palette = opts.palette
	if not debrisGroupTried then
		setupDebrisGroup()
	end
	local n = scaleN(opts.n or 8)
	local style = opts.style or "scrap"
	local speed = opts.speed or 38
	local up = opts.up or 1
	local scale = opts.scale or 1
	local budget = debrisBudget()
	for _ = 1, n do
		while #liveDebris >= budget do
			removeDebris(liveDebris[1])
		end
		local pc = opts.color
		if palette and #palette > 0 then
			pc = palette[rng:NextInteger(1, #palette)]
		end
		local part, fastFade = makeDebrisPiece(style, scale, pc)
		local dir = Vector3.new(rnd(-1, 1), rnd(0.35, 1.3) * up, rnd(-1, 1))
		if opts.dir then
			dir = dir.Unit * 0.7 + opts.dir * (opts.bias or 1) * rnd(0.6, 1.5)
		end
		if dir.Magnitude < 0.01 then
			dir = Vector3.yAxis
		end
		local offset = randUnit() * 0.5
		part.CFrame = CFrame.new(p + offset) * CFrame.Angles(rnd(0, 6.28), rnd(0, 6.28), rnd(0, 6.28))
		part.Parent = fxFolder
		part.AssemblyLinearVelocity = dir.Unit * speed * rnd(0.45, 1.1)
		part.AssemblyAngularVelocity = randUnit() * rnd(6, 22)
		table.insert(liveDebris, part)

		local life = (opts.life or rnd(2.2, 3.0)) * (if fastFade then 0.7 else 1)
		task.delay(life, function()
			if not part.Parent then
				return
			end
			part.Anchored = true -- stop jittering while fading
			local t = TweenService:Create(part, TweenInfo.new(0.5, Quad, In), { Transparency = 1 })
			t:Play()
			task.delay(0.55, removeDebris, part)
		end)
	end
end

-- DECALS: scorch + goo splat ---------------------------------------------------------
local scorches: { Part } = {}
local splats: { Part } = {}

local function flatDisc(pos: Vector3, normal: Vector3, diameter: number, color: Color3, material: Enum.Material, transparency: number): Part
	local cf = xAxisCF(pos + normal * 0.06, normal)
	local part = mkPart(Vector3.new(0.06, 0.2, 0.2), color, cf, Enum.PartType.Cylinder, material, transparency)
	tween(part, 0.2, { Size = Vector3.new(0.06, diameter, diameter) }, Back, Out)
	return part
end

local function trackFifo(list: { Part }, part: Part, cap: number, life: number)
	if #list >= cap then
		local old = table.remove(list, 1)
		if old.Parent then
			old:Destroy()
		end
	end
	table.insert(list, part)
	task.delay(life, function()
		if part.Parent then
			tween(part, 2.5, { Transparency = 1 }, Quad, In)
			task.delay(2.6, function()
				local i = table.find(list, part)
				if i then
					table.remove(list, i)
				end
				if part.Parent then
					part:Destroy()
				end
			end)
		end
	end)
end

function Fx.scorch(p: Vector3, radius: number)
	local pos, n = Fx.groundAt(p, 3, 14)
	-- no decals on cliffs/walls: a flat disc stuck to a steep face reads as a floating coin
	if not pos or not n or n.Y < 0.55 then
		return
	end
	local disc = flatDisc(pos, n, radius * 2, C3(18, 16, 15), Enum.Material.SmoothPlastic, 0.2)
	trackFifo(scorches, disc, 8, 12)
	-- glowing embers that cool down
	local ember = visual(Vector3.new(0.06, 0.2, 0.2), C3(255, 120, 30), CFrame.new(), Enum.PartType.Cylinder, Enum.Material.Neon, 0.55, 3)
	if ember then
		ember.CFrame = xAxisCF(pos + n * 0.09, n)
		tween(ember, 0.2, { Size = Vector3.new(0.06, radius * 0.9, radius * 0.9) }, Back, Out)
		task.delay(0.2, function()
			if ember.Parent then
				tween(ember, 2.6, { Transparency = 1 }, Quad, In)
			end
		end)
	end
end

-- life = seconds before the puddle starts fading (default 6; kill puddles pass longer). Cap 16 live decals, FIFO.
-- dir (optional): the splash is thrown that way, so the small droplets land downrange of the corpse.
function Fx.splat(p: Vector3, radius: number, color: Color3?, life: number?, dir: Vector3?)
	local pos, n = Fx.groundAt(p, 3, 12)
	if not pos or not n or n.Y < 0.55 then
		return
	end
	local c = color or C3(95, 210, 60)
	life = life or 6
	local main = flatDisc(pos, n, radius * 2, c, Enum.Material.SmoothPlastic, 0.08)
	trackFifo(splats, main, 16, life)
	local flat = if dir then Vector3.new(dir.X, 0, dir.Z) else Vector3.zero
	for _ = 1, scaleN(3) do
		local ang = rnd(0, 6.28)
		local off = Vector3.new(math.cos(ang), 0, math.sin(ang)) * radius * rnd(0.8, 1.5)
		if flat.Magnitude > 0.1 then
			off = off + flat.Unit * radius * rnd(0.8, 2.2)
		end
		local pos2, n2 = Fx.groundAt(p + off, 3, 8)
		if pos2 and n2 and n2.Y >= 0.55 then
			local small = flatDisc(pos2, n2, radius * rnd(0.3, 0.7), c, Enum.Material.SmoothPlastic, 0.1)
			trackFifo(splats, small, 16, life)
		end
	end
end

-- SHOCKWAVE -------------------------------------------------------------------------
function Fx.shockwave(p: Vector3, r: number, color: Color3?)
	if camDist(p) > 700 then
		return
	end
	local c = color or C3(255, 240, 210)
	local pos, n = Fx.groundAt(p, 2, 8)
	pos = pos or p
	n = n or Vector3.yAxis
	-- flat blast disc
	local disc = visual(Vector3.new(0.2, r * 0.3, r * 0.3), c, CFrame.new(), Enum.PartType.Cylinder, Enum.Material.Neon, 0.35, 0.6)
	if disc then
		disc.CFrame = xAxisCF(pos + n * 0.2, n)
		tween(disc, 0.45, { Size = Vector3.new(0.1, r * 2, r * 2), Transparency = 1 }, Quad, Out)
	end
	-- translucent dome shell
	local dome = visual(Vector3.one * r * 0.3, c, CFrame.new(pos), Enum.PartType.Ball, Enum.Material.Neon, 0.7, 0.6)
	if dome then
		tween(dome, 0.4, { Size = Vector3.one * r * 2, Transparency = 1 }, Quad, Out)
	end
	burst("dust", upCF(pos + n * 0.4, n), math.clamp(r * 1.2, 6, 30), { scale = math.clamp(r / 8, 0.6, 3), speed = math.clamp(r / 5, 1, 4) })
end

-- EXPLOSION -------------------------------------------------------------------------
local SIZE_R = { S = 4, M = 7, L = 12, XL = 22 }
local SIZE_SHAKE = { S = 0.7, M = 1.5, L = 3.0, XL = 5.5 }
local SIZE_SHAKE_DUR = { S = 0.25, M = 0.45, L = 0.8, XL = 1.3 }
local SIZE_DEBRIS = { S = 3, M = 7, L = 12, XL = 20 }

local STYLES = {
	fire = { core = C3(255, 248, 200), mid = C3(255, 160, 50), edge = C3(255, 90, 20), smoke = C3(70, 62, 58), light = C3(255, 170, 80) },
	emp = { core = C3(220, 250, 255), mid = C3(80, 200, 255), edge = C3(40, 120, 255), smoke = C3(70, 110, 150), light = C3(100, 200, 255) },
	gas = { core = C3(235, 255, 200), mid = C3(140, 235, 70), edge = C3(70, 170, 40), smoke = C3(90, 170, 60), light = C3(150, 255, 90) },
	goo = { core = C3(215, 255, 200), mid = C3(110, 230, 90), edge = C3(50, 160, 50), smoke = C3(60, 140, 60), light = C3(120, 255, 110) },
	spark = { core = C3(255, 255, 225), mid = C3(255, 225, 90), edge = C3(255, 170, 40), smoke = C3(110, 105, 100), light = C3(255, 225, 120) },
}

local function explosionSound(size: string, style: string, p: Vector3)
	local key, vol, pitch = "Explosion", 1, 1
	if style == "emp" then
		key = "EMP"
	elseif style == "gas" then
		key = if size == "S" or size == "M" then "SmokePop" else "Explosion"
	elseif style == "goo" then
		key = "AcidSplat"
	elseif size == "S" or style == "spark" then
		key = "ExplosionSmall"
	elseif size == "XL" then
		key = "ExplosionHuge"
	elseif size == "L" then
		pitch, vol = 0.88, 1.1
	end
	Audio.play(key, p, { pitch = pitch, volume = vol, priority = 5 })
end

function Fx.explosion(p: Vector3, opts: { size: string?, r: number?, style: string?, silent: boolean?, noShake: boolean? }?)
	opts = opts or {}
	local size = opts.size
	if not SIZE_R[size] then
		size = "M"
	end
	local R = opts.r or SIZE_R[size]
	local V = math.clamp(R * 0.75, 2, 40) -- visual radius
	local style = opts.style or "fire"
	local st = STYLES[style] or STYLES.fire
	local dist = camDist(p)
	local big = size == "L" or size == "XL"

	if not opts.silent then
		explosionSound(size, style, p)
	end
	if not opts.noShake then
		Juice.shake(SIZE_SHAKE[size], SIZE_SHAKE_DUR[size], p, math.max(60, R * 7))
		if size == "XL" and dist < R * 5 then
			Juice.flash(st.core, 0.55, 0.45)
			if dist < R * 2.5 then
				Juice.hitstop(0.05)
			end
		elseif size == "L" and dist < R * 3 then
			Juice.flash(st.core, 0.22, 0.25)
		end
	end
	if dist > 700 then
		return
	end

	local sc = math.clamp(V / 4, 0.6, 4) -- particle scale
	local isGas = style == "gas"

	-- t = 0: instant flash + light + sparks
	local flash = visual(Vector3.one * 0.3 * V, st.core, CFrame.new(p), Enum.PartType.Ball, Enum.Material.Neon, 0, 0.45)
	if flash then
		tween(flash, 0.16, { Size = Vector3.one * V * 2.4, Transparency = 1 }, Quad, Out)
		if Fx.quality >= 0.75 or big then
			local light = Instance.new("PointLight")
			light.Color = st.light
			light.Range = math.clamp(V * 4, 12, 60)
			light.Brightness = 4 + sc * 2
			light.Shadows = false
			light.Parent = flash
			tween(light, 0.4, { Brightness = 0 }, Quad, Out)
		end
	end
	burst(if style == "emp" then "zap" else "sparks", p, 16 * sc, { scale = sc * 0.8, speed = math.clamp(sc, 1, 2.5) })
	if not isGas then
		burst("fire", p, 6 * sc, { scale = sc * 0.7, color = colorSeq({ { 0, st.core }, { 0.35, st.mid }, { 1, st.edge } }) })
	end

	-- t = 0.03: fireball (overshoot scale), debris
	task.delay(0.03, function()
		local nBalls = scaleN(3 + (if big then 3 else 0))
		for _ = 1, nBalls do
			local off = randUnit() * V * 0.35
			local c = st.mid:Lerp(st.core, rng:NextNumber() * 0.6)
			local ball = visual(Vector3.one * V * 0.25, c, CFrame.new(p + off), Enum.PartType.Ball, Enum.Material.Neon, if isGas then 0.35 else 0.05, 0.75)
			if ball then
				local target = V * rnd(0.9, 1.5) * (if isGas then 1.3 else 1)
				tween(ball, 0.22, { Size = Vector3.one * target }, Back, Out)
				task.delay(0.2, function()
					if ball.Parent then
						tween(ball, 0.4, { Size = Vector3.one * target * 0.55, Transparency = 1, Color = st.edge }, Quad, In)
					end
				end)
			end
		end
		if not isGas then
			burst("fire", p + Vector3.new(0, V * 0.3, 0), 10 * sc, { scale = sc, color = colorSeq({ { 0, st.core }, { 0.35, st.mid }, { 1, st.edge } }) })
		end
		local dstyle = if style == "goo" then "goo" else "rock"
		Fx.debris(p, { n = SIZE_DEBRIS[size], style = dstyle, speed = 28 + V * 2.5, color = if style == "goo" then st.mid else nil })
		if big then
			Fx.debris(p, { n = SIZE_DEBRIS[size] * 0.6, style = "ember", speed = 30 + V * 3 })
		end
	end)

	-- t = 0.08: shockwave + smoke rises
	task.delay(0.08, function()
		if big or opts.size == "XL" or style == "emp" then
			Fx.shockwave(p, R * 1.4, st.mid)
			if size == "XL" then
				task.delay(0.1, Fx.shockwave, p, R * 2.2, st.core)
			end
		end
		burst("smoke", p + Vector3.new(0, V * 0.3, 0), (if isGas then 14 else 8) * sc, { scale = sc * (if isGas then 1.6 else 1), color = st.smoke })
		if big then
			burst("smoke", p + Vector3.new(0, V * 0.9, 0), 6 * sc, { scale = sc * 1.2, color = st.smoke })
		end
	end)

	if big and style ~= "gas" and style ~= "emp" then
		task.delay(0.12, Fx.scorch, p, V * 1.1)
	end
end

-- TRACERS ---------------------------------------------------------------------------
local tracerPool: { Part } = {}
local liveTracers = 0

local function acquireTracerPart(): Part
	local p = table.remove(tracerPool)
	if not p then
		p = mkPart(Vector3.new(0.1, 0.1, 1), Color3.new(1, 1, 1), CFrame.new(0, 3000, 0), nil, Enum.Material.Neon, 0)
	end
	p.Parent = fxFolder
	return p
end

local function releaseTracerPart(p: Part)
	p.Parent = nil
	if #tracerPool < 120 then
		table.insert(tracerPool, p)
	else
		p:Destroy()
	end
end

function Fx.tracer(a: Vector3, b: Vector3, color: Color3?, width: number?)
	local v = b - a
	local len = v.Magnitude
	if len < 0.5 or liveTracers >= 80 then
		return
	end
	local dir = v / len
	local w = width or 0.12
	local base = color or C3(255, 215, 120)
	-- bright white-hot core + a soft translucent glow of the weapon colour around it (skipped on weak devices)
	local part = acquireTracerPart()
	part.Color = base:Lerp(Color3.new(1, 1, 1), 0.7)
	local glow: Part? = nil
	if Fx.quality >= 0.6 and liveTracers < 50 then
		glow = acquireTracerPart()
		glow.Color = base
	end
	if w >= 0.45 and w < 0.55 then -- width 0.5 = rail lance (rocket is 0.6): lingering twin beams
		Fx.beamTrail(a, b, base, w)
	end
	liveTracers += 1
	local seg = math.min(len, 8 + w * 40)
	local travel = math.clamp(len / 900, 0.025, 0.2)
	local fade = 0.07
	local age = 0
	addAnim(function(dt)
		age += dt
		if age >= travel + fade then
			liveTracers -= 1
			releaseTracerPart(part)
			if glow then
				releaseTracerPart(glow)
			end
			return true
		end
		local head, tail, f = 0, 0, 0
		if age <= travel then
			head = len * (age / travel)
			tail = math.max(0, head - seg)
		else
			f = (age - travel) / fade
			head = len
			tail = math.max(0, len - seg) + math.min(seg, len) * f
		end
		local l = math.max(head - tail, 0.05)
		local mid = a + dir * ((head + tail) * 0.5)
		local ww = w * (1 - 0.6 * f)
		part.Size = Vector3.new(ww * 0.75, ww * 0.75, l)
		part.CFrame = CFrame.lookAt(mid, mid + dir)
		part.Transparency = f * 0.9
		if glow then
			glow.Size = Vector3.new(ww * 2.6, ww * 2.6, l)
			glow.CFrame = part.CFrame
			glow.Transparency = 0.6 + f * 0.4
		end
		return false
	end, function()
		liveTracers -= 1
		part:Destroy()
		if glow then
			glow:Destroy()
		end
	end)
end

-- Lingering beams for heavy shots (rail lance): a thick straight core + soft halo (CurveSize always 0), 0.35 s.
local liveBeams = 0
function Fx.beamTrail(a: Vector3, b: Vector3, color: Color3, width: number?)
	if liveBeams >= 6 or Fx.quality < 0.4 then
		return
	end
	liveBeams += 1
	local w = (width or 0.5) * 1.6
	local holder = Instance.new("Folder")
	holder.Name = "BeamTrail"
	local function endpoint(pos: Vector3): Attachment
		local p = mkPart(Vector3.one * 0.2, Color3.new(1, 1, 1), CFrame.new(pos), nil, Enum.Material.SmoothPlastic, 1)
		p.Parent = holder
		local at = Instance.new("Attachment")
		at.Parent = p
		return at
	end
	local a0, a1 = endpoint(a), endpoint(b)
	local function beam(width0: number, col: Color3, curve: number, transp: number): Beam
		local bm = Instance.new("Beam")
		bm.Attachment0 = a0
		bm.Attachment1 = a1
		bm.Color = ColorSequence.new(col)
		bm.LightEmission = 1
		bm.LightInfluence = 0
		bm.FaceCamera = true
		bm.Width0 = width0
		bm.Width1 = width0 * 0.7
		bm.Transparency = NumberSequence.new(transp)
		bm.CurveSize0 = curve
		bm.CurveSize1 = -curve
		bm.Segments = if curve ~= 0 then 14 else 1
		bm.Parent = a0.Parent
		return bm
	end
	local core = beam(w * 0.55, color:Lerp(Color3.new(1, 1, 1), 0.8), 0, 0)
	local halo = beam(w * 2, color, 0, 0.55)
	holder.Parent = fxFolder -- (the old CurveSize "twist" beam is gone: bent ribbons read as a kinked bolt)
	local age, dur = 0, 0.35
	addAnim(function(dt)
		age += dt
		local f = age / dur
		if f >= 1 then
			liveBeams -= 1
			holder:Destroy()
			return true
		end
		local k = 1 - f
		core.Width0, core.Width1 = w * 0.55 * k, w * 0.4 * k
		halo.Width0, halo.Width1 = w * 2 * (0.4 + 0.6 * k), w * 1.4 * k
		halo.Transparency = NumberSequence.new(0.55 + 0.45 * f)
		return false
	end, function()
		liveBeams -= 1
		holder:Destroy()
	end)
end

-- MUZZLE FLASH ----------------------------------------------------------------------
local flashPool: { Part } = {}
local liveFlashes = 0

function Fx.muzzleFlash(at: any, color: Color3?)
	local pos: Vector3
	local t = typeof(at)
	if t == "Vector3" then
		pos = at
	elseif t == "CFrame" then
		pos = at.Position
	elseif t == "Instance" and at:IsA("Attachment") then
		pos = at.WorldPosition
	elseif t == "Instance" and at:IsA("BasePart") then
		pos = at.Position
	else
		return
	end
	if liveFlashes >= 24 then
		return
	end
	liveFlashes += 1
	local c = color or C3(255, 210, 120)
	local part = table.remove(flashPool)
	if not part then
		part = mkPart(Vector3.one, c, CFrame.new(pos), Enum.PartType.Ball, Enum.Material.Neon, 0)
		if Fx.quality >= 0.75 then
			local l = Instance.new("PointLight")
			l.Range = 12
			l.Brightness = 0
			l.Shadows = false
			l.Parent = part
		end
	end
	local light = part:FindFirstChildOfClass("PointLight")
	part.Color = c:Lerp(Color3.new(1, 1, 1), 0.5)
	part.CFrame = CFrame.new(pos) * CFrame.Angles(rnd(0, 6.28), rnd(0, 6.28), 0)
	part.Parent = fxFolder
	if light then
		light.Color = c
	end
	local s0 = rnd(0.7, 1.2)
	local age = 0
	local dur = 0.06
	addAnim(function(dt)
		age += dt
		local f = age / dur
		if f >= 1 then
			liveFlashes -= 1
			part.Parent = nil
			if #flashPool < 24 then
				table.insert(flashPool, part)
			else
				part:Destroy()
			end
			return true
		end
		local s = s0 * (1 + 0.8 * f)
		part.Size = Vector3.new(s, s, s)
		part.Transparency = 0.1 + 0.9 * f * f
		if light then
			light.Brightness = 4 * (1 - f)
		end
		return false
	end, function()
		liveFlashes -= 1
		part:Destroy()
	end)
	burst("sparks", pos, 2, { scale = 0.4, speed = 0.6 })
end

-- IMPACTS ---------------------------------------------------------------------------
-- Short white-hot pop where a bullet lands (throttled, near the camera only): the "something hit" read.
local lastImpactFlash = 0
local function impactFlash(p: Vector3, color: Color3, size: number)
	local t = os.clock()
	if t - lastImpactFlash < 0.03 or Fx.quality < 0.6 then
		return
	end
	lastImpactFlash = t
	local f = visual(Vector3.one * size * 0.5, color, CFrame.new(p), Enum.PartType.Ball, Enum.Material.Neon, 0.05, 0.14)
	if f then
		tween(f, 0.09, { Size = Vector3.one * size * 1.7, Transparency = 1 }, Quad, Out)
	end
end

-- A few thin spark streaks flying off the surface (tracer parts: pooled, capped by the tracer limits).
local function sparkStreaks(p: Vector3, n: Vector3, count: number, color: Color3)
	for _ = 1, count do
		local d = (n * rnd(0.5, 1.1) + randUnit() * 0.9).Unit
		Fx.tracer(p, p + d * rnd(3, 6), color, 0.07)
	end
end

-- Physics chips share the 60-piece debris budget with deaths: at most one chip volley per 0.15 s so a gatling cannot evict
-- the pieces of a freshly killed enemy.
local lastChip = 0
local function impactChips(p: Vector3, opts)
	local t = os.clock()
	if t - lastChip < 0.15 then
		return
	end
	lastChip = t
	Fx.debris(p, opts)
end

local SPARK_HOT = colorSeq({ { 0, C3(255, 250, 215) }, { 0.35, C3(255, 175, 60) }, { 1, C3(235, 85, 20) } })
local GOO_SPRAY = colorSeq({ { 0, C3(205, 255, 140) }, { 0.5, C3(120, 235, 70) }, { 1, C3(55, 160, 45) } })

function Fx.impact(p: Vector3, n: Vector3?, result: string?, material: string?)
	n = n or Vector3.yAxis
	result = result or "pen"
	material = material or "metal"
	local dist = camDist(p)
	local visible = dist < 250
	local near = dist < 70
	local cf = upCF(p, n)

	-- bullets that land on an enemy (material metal / goo are enemy surfaces) jolt it right now (EnemyAnim.hitNear)
	if (material == "metal" or material == "goo") and Fx.enemyHit then
		Fx.enemyHit(p, n, result)
	end

	if result == "deflect" then
		Audio.play("HitDeflect", p)
		if visible then
			burst("sparks", cf, 14, { scale = 1.0, speed = 1.4, color = SPARK_HOT })
			if near then
				impactFlash(p, C3(255, 240, 200), 0.9)
				sparkStreaks(p, n, 2, C3(255, 225, 150))
			end
			-- ricochet streak
			local tang = randUnit()
			tang = (tang - n * tang:Dot(n))
			if tang.Magnitude < 0.05 then
				tang = n:Cross(Vector3.xAxis)
			end
			local dir = (n * 0.55 + tang.Unit).Unit
			Fx.tracer(p, p + dir * rnd(5, 9), C3(255, 235, 170), 0.1)
		end
	elseif result == "partial" then
		Audio.play("HitPartial", p)
		if visible then
			burst("puff", cf, 4, { scale = 0.8 })
			if material == "metal" then
				burst("sparks", cf, 6, { scale = 0.7, speed = 0.9, color = SPARK_HOT })
			elseif material == "goo" then
				burst("goo", cf, 4, { scale = 0.45, speed = 0.6 })
			end
		end
	else
		if material == "goo" then
			Audio.play("HitGoo", p)
			if visible then
				-- cartoony green goo spray thrown out along the surface normal (no gore) + droplets that bounce off the ground
				burst("goo", cf, 14, { scale = 0.65, speed = 0.95, spread = 55 })
				burst("goo", cf, 4, { scale = 0.4, speed = 0.5 })
				burst("puff", cf, 3, { scale = 0.9, color = C3(150, 235, 90) })
				if near then
					impactFlash(p, C3(200, 255, 150), 0.8)
					impactChips(p + n * 0.3, { n = 3, style = "goo", speed = 18, scale = 0.45, life = 0.9, up = 1.1, dir = n, bias = 0.8 })
				end
			end
		elseif material == "ground" then
			Audio.play("HitGround", p)
			if visible then
				-- dust puff kicked up along the normal, a ring of grit and a few chips of ground
				burst("dust", cf, 8, { scale = 0.9, speed = 1.2, spread = 70 })
				burst("dust", cf, 3, { scale = 1.3, speed = 0.5 })
				if dist < 120 then
					burst("sparks", cf, 5, { scale = 0.5, speed = 0.8 })
					Fx.bulletMark(p, n)
				end
				if dist < 60 then
					impactChips(p + n * 0.2, { n = 3, style = "rock", speed = 14, scale = 0.22, life = 0.9, up = 1.2, dir = n, bias = 0.8 })
				end
			end
		else
			Audio.play("HitMetal", p)
			if visible then
				-- hot orange sparks (more, bigger, faster) + spark streaks, a white pop, grey smoke and metal chips
				burst("sparks", cf, 14, { scale = 1.0, speed = 1.25, color = SPARK_HOT })
				burst("puff", cf, 3, { scale = 0.7, color = C3(90, 90, 95) })
				if near then
					impactFlash(p, C3(255, 245, 205), 0.8)
					sparkStreaks(p, n, 2, C3(255, 205, 120))
				end
				if dist < 90 then
					impactChips(p + n * 0.3, { n = 3, style = "scrap", speed = 18, scale = 0.32, life = 1, up = 1.1, dir = n, bias = 0.7 })
				end
			end
		end
	end
end

-- Small dark scorch decal (~1.2 studs, matte, never glowing) where a bullet hit the world: FIFO cap 40, fades out over ~6 s
local bulletMarks: { Part } = {}
function Fx.bulletMark(p: Vector3, n: Vector3)
	if Fx.quality < 0.6 or n.Y < 0.55 then -- no coins stuck on cliff faces
		return
	end
	local diameter = rnd(1.0, 1.4)
	local disc = flatDisc(p, n, diameter, C3(22, 19, 18), Enum.Material.SmoothPlastic, 0.2)
	disc.CanQuery = false
	disc.CastShadow = false
	if #bulletMarks >= 40 then
		local old = table.remove(bulletMarks, 1)
		if old.Parent then
			old:Destroy()
		end
	end
	table.insert(bulletMarks, disc)
	task.delay(4.2, function()
		if disc.Parent then
			tween(disc, 1.8, { Transparency = 1 }, Quad, In)
		end
	end)
	task.delay(6.1, function()
		local i = table.find(bulletMarks, disc)
		if i then
			table.remove(bulletMarks, i)
		end
		if disc.Parent then
			disc:Destroy()
		end
	end)
end

-- Weak-spot hit: bigger white-yellow flash + "CRIT" damage pop floating up (BillboardGui, 0.6 s). Cap 6 pops live.
local livePops = 0
function Fx.critPop(p: Vector3, killed: boolean?)
	if camDist(p) < 250 then
		local cf = CFrame.new(p)
		local flash = visual(Vector3.one * 0.5, C3(255, 252, 215), cf, Enum.PartType.Ball, Enum.Material.Neon, 0, 0.2)
		if flash then
			tween(flash, 0.14, { Size = Vector3.one * 2.6, Transparency = 1 }, Quad, Out)
		end
		burst("sparks", cf, 8, { scale = 0.8, speed = 1.1, color = colorSeq({ { 0, C3(255, 255, 255) }, { 0.5, C3(255, 235, 120) }, { 1, C3(255, 170, 40) } }) })
	end
	if livePops >= 6 or camDist(p) > 160 then
		return
	end
	livePops += 1
	local anchor = mkPart(Vector3.one * 0.2, Color3.new(1, 1, 1), CFrame.new(p + Vector3.new(0, 1, 0)), nil, Enum.Material.SmoothPlastic, 1)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(110, 44)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 170
	gui.Parent = anchor
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = if killed then "CRIT!" else "CRIT"
	lbl.Font = Enum.Font.GothamBlack
	lbl.TextScaled = true
	lbl.TextColor3 = C3(255, 232, 90)
	lbl.TextStrokeColor3 = C3(120, 40, 10)
	lbl.TextStrokeTransparency = 0
	lbl.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Scale = 0.5
	scale.Parent = lbl
	tween(scale, 0.12, { Scale = 1.15 }, Back, Out)
	task.delay(0.12, function()
		if scale.Parent then
			tween(scale, 0.1, { Scale = 1 }, Quad, Out)
		end
	end)
	tween(anchor, 0.6, { Position = anchor.Position + Vector3.new(0, 3.2, 0) }, Quad, Out)
	task.delay(0.25, function()
		if lbl.Parent then
			tween(lbl, 0.35, { TextTransparency = 1, TextStrokeTransparency = 1 }, Quad, In)
		end
	end)
	task.delay(0.65, function()
		livePops -= 1
		anchor:Destroy()
	end)
end

-- SHOTS FROM OTHER PLAYERS (dedupe tracers + muzzle events) -------------------------
local lastShot: { [number]: number } = {}

local function registerShot(userId: number): boolean
	local now = os.clock()
	local last = lastShot[userId]
	if last and now - last < 0.025 then
		return false
	end
	lastShot[userId] = now
	return true
end

local function remoteShot(userId: number, weaponId: string?, pos: Vector3, flashAt: any?)
	if not registerShot(userId) then
		return
	end
	local w = weaponId and Weapons.get(weaponId)
	if w then
		Audio.play(w.sound, pos, { source = userId })
		if camDist(pos) < 200 then
			Fx.muzzleFlash(flashAt or pos, w.tracer)
		end
	end
end

-- DEATH -----------------------------------------------------------------------------
local SIZE_FACTOR = { S = 1, M = 1.6, L = 2.6, XL = 4.5 }
local CLASS_FACTOR = { regular = 1, medium = 1.6, heavy = 2.6, behemoth = 4.5 }

local function sizeFactor(size: any, class: string?): number
	if type(size) == "string" and SIZE_FACTOR[size] then
		return SIZE_FACTOR[size]
	elseif type(size) == "number" then
		return math.clamp(size / 2, 0.8, 5)
	end
	return CLASS_FACTOR[class] or 1
end

-- Debris colours come from the mesh part colours (Data/Meshes): robots scatter body/trim plating, bugs splash glow goo.
local paletteCache: { [string]: { scrap: { Color3 }, goo: { Color3 }, glow: Color3? } } = {}

local function deathPalette(kind: any): { scrap: { Color3 }, goo: { Color3 }, glow: Color3? }?
	if type(kind) ~= "string" then
		return nil
	end
	local cached = paletteCache[kind]
	if cached then
		return cached
	end
	local info = Meshes[string.lower(kind)]
	if not info then
		return nil
	end
	local scrap, trim, glow = {}, {}, nil
	for _, pi in info.parts do
		if pi.role == "weak" or pi.role == "glow" then
			glow = glow or pi.color
		elseif pi.role == "trim" then
			table.insert(trim, pi.color)
			table.insert(scrap, pi.color)
		else
			table.insert(scrap, pi.color)
		end
	end
	local g = glow or C3(140, 255, 60)
	local pal = {
		scrap = scrap,
		glow = glow,
		goo = { g, g, g, g:Lerp(C3(255, 255, 255), 0.35), trim[1] or g },
	}
	paletteCache[kind] = pal
	return pal
end

local function death(d)
	local p: Vector3 = d.p
	local pal = deathPalette(d.kind)
	local f = sizeFactor(d.size, d.class)
	local style = d.style or (if d.faction == "BROOD" then "goo" else "scrap")
	local heavy = d.class == "heavy" or d.class == "behemoth" or f >= 2.4
	local medium = d.class == "medium"
	local dist = camDist(p)
	local mine = d.by == LocalPlayer.UserId
	local dir: Vector3? = if typeof(d.dir) == "Vector3" then d.dir else nil
	local blast = d.blast == true
	local bias = if blast then 1.5 else 0.9

	Audio.play(if style == "goo" then "DeathGoo" else "DeathScrap", p, { volume = math.clamp(0.8 + f * 0.1, 0.8, 1.2), pitch = math.clamp(1.1 - f * 0.06, 0.8, 1.1) })
	if heavy then
		Audio.play("DeathBig", p, { priority = 4 })
	end
	-- camera: medium+ kills get a tiny hitstop (only when the local player landed them) and a distance-scaled shake
	if heavy or medium then
		Juice.kill(if d.class == "behemoth" then 3 elseif heavy then 2 else 1, mine and dist < 120, p)
	end
	-- bullets already played their cue from HitConfirm (WeaponController); explosion / call-in kills do it here
	if mine and d.src ~= "bullet" then
		Audio.play2D(if d.weak then "KillWeak" else "Kill")
	end
	-- medium / heavy kills get an extra rewarding bell on top of the Kill pop (lower pitched for heavies)
	if mine and (heavy or medium) then
		Audio.play2D("KillWeak", { pitch = if heavy then 0.8 else 0.95, volume = 0.6, priority = 4 })
	end
	if dist > 400 then
		return
	end

	-- instant pop flash: a big soft ball + a small white-hot core, and a short light on decent hardware
	local popCol = if style == "goo" then C3(210, 255, 190) else C3(255, 245, 210)
	local pop = visual(Vector3.one * 0.6 * f, popCol, CFrame.new(p), Enum.PartType.Ball, Enum.Material.Neon, 0, 0.3)
	if pop then
		tween(pop, 0.14, { Size = Vector3.one * 3.2 * f, Transparency = 1 }, Quad, Out)
		if Fx.quality >= 0.75 and dist < 120 then
			local light = Instance.new("PointLight")
			light.Color = if style == "goo" then C3(140, 255, 110) else C3(255, 190, 110)
			light.Range = 10 + 5 * f
			light.Brightness = 3 + f
			light.Shadows = false
			light.Parent = pop
			tween(light, 0.25, { Brightness = 0 }, Quad, Out)
		end
	end
	local core = visual(Vector3.one * 0.3 * f, Color3.new(1, 1, 1), CFrame.new(p), Enum.PartType.Ball, Enum.Material.Neon, 0, 0.2)
	if core then
		tween(core, 0.08, { Size = Vector3.one * 1.5 * f, Transparency = 1 }, Quad, Out)
	end

	local spray: CFrame? = if dir then upCF(p, dir) else nil -- +Y = the way the killing blow travelled

	if style == "goo" then
		-- bug: goo bursts out of the body, a thick spray along the shot, droplets + shell chips fly, a puddle stays
		burst("goo", p, 22 * f, { scale = 0.8 * f ^ 0.7, speed = 0.8 + f * 0.15 })
		if spray then
			burst("goo", spray, 12 * f, { scale = 0.9 * f ^ 0.6, speed = 1.5 + f * 0.1, spread = 35 })
		end
		local puff = if pal and pal.glow then pal.glow:Lerp(C3(40, 60, 30), 0.45) else C3(120, 200, 90)
		burst("puff", p, 5 * f, { scale = f ^ 0.7, color = puff })
		Fx.debris(p, { n = 6 + 5 * f, style = "goo", speed = 22 + f * 3, scale = math.clamp(f * 0.6, 0.7, 2), palette = pal and pal.goo, dir = dir, bias = bias })
		local puddle = if pal and pal.glow then pal.glow:Lerp(C3(70, 150, 45), 0.4) else nil
		Fx.splat(p, 1.9 * f ^ 0.8, puddle, 10, dir)
	else
		-- robot: spark burst + a hard spark fan along the shot, scrap flung with it, a smoke wisp that lingers, scorch mark
		burst("sparks", p, 18 * f, { scale = 0.9, speed = 1 + f * 0.1 })
		if spray then
			burst("sparks", spray, 10 * f ^ 0.8, { scale = 1.0, speed = 1.7 + f * 0.1, spread = 40 })
		end
		burst("puff", p, 5 * f, { scale = f ^ 0.7 })
		burst("smoke", p + Vector3.new(0, 0.6, 0), 1 + f, { scale = 0.4 * f ^ 0.6, color = C3(70, 66, 62) })
		Fx.debris(p, { n = 6 + 5 * f, style = "scrap", color = d.color, palette = pal and pal.scrap, speed = 26 + f * 3, scale = math.clamp(f * 0.5, 0.8, 2.2), dir = dir, bias = bias })
		if heavy then
			Fx.explosion(p, { size = if f >= 4 then "L" else "M", style = "fire", silent = true, noShake = true })
		elseif medium and dist < 80 then
			Fx.scorch(p, 1.1 * f ^ 0.5)
		end
	end
end

-- REGISTRATION / DISPATCH -----------------------------------------------------------
local handlers: { [string]: { (any) -> () } } = {}
local warnedKinds: { [string]: boolean } = {}

function Fx.register(kind: string, fn: (any) -> ())
	local list = handlers[kind]
	if not list then
		list = {}
		handlers[kind] = list
	end
	table.insert(list, fn)
end

function Fx.handle(kind: string, data: any)
	local list = handlers[kind]
	if not list then
		if not warnedKinds[kind] then
			warnedKinds[kind] = true
			warn("[Fx] no handler for kind '" .. tostring(kind) .. "'")
		end
		return
	end
	for _, fn in list do
		local ok, err = pcall(fn, data)
		if not ok then
			warn("[Fx] handler '" .. tostring(kind) .. "' failed: " .. tostring(err))
		end
	end
end

local function isPos(v: any): boolean
	return typeof(v) == "Vector3"
end

Fx.register("Explosion", function(d)
	if isPos(d.p) then
		Fx.explosion(d.p, { r = d.r, size = d.size, style = d.style })
	end
end)

Fx.register("Tracer", function(d)
	if d.u == LocalPlayer.UserId or not isPos(d.a) or not isPos(d.b) then
		return -- own shots are predicted locally
	end
	local wd = d.w and Weapons.get(d.w)
	Fx.tracer(d.a, d.b, d.c, if wd and wd.kind == "rail" then 0.5 elseif wd and wd.kind == "rocket" then 0.6 else nil)
	if d.u then
		remoteShot(d.u, d.w, d.a, nil)
	end
end)

-- VR-1 arc hits (server: WeaponService "Arc" {a, b}); short cyan bolt between the two targets
Fx.register("Arc", function(d)
	if isPos(d.a) and isPos(d.b) then
		Fx.tracer(d.a, d.b, C3(122, 240, 255), 0.18)
	end
end)

Fx.register("Impact", function(d)
	if isPos(d.p) then
		Fx.impact(d.p, d.n, d.r, d.m)
	end
end)

Fx.register("Death", function(d)
	if isPos(d.p) then
		death(d)
	end
end)

Fx.register("Shake", function(d)
	local mag = d.mag or 1
	Juice.shake(mag, 0.25 + mag * 0.15, if isPos(d.p) then d.p else nil, d.r)
end)

Fx.register("Sound", function(d)
	if not d.k then
		return
	end
	if isPos(d.p) then
		Audio.play(d.k, d.p)
	else
		Audio.play2D(d.k)
	end
end)

Fx.register("Shockwave", function(d)
	if isPos(d.p) then
		Fx.shockwave(d.p, d.r or 10)
	end
end)

Fx.register("Debris", function(d)
	if isPos(d.p) then
		Fx.debris(d.p, { n = d.n, color = d.c, style = d.style })
	end
end)

Fx.register("Muzzle", function(d)
	if d.u == LocalPlayer.UserId then
		return
	end
	local pl = Players:GetPlayerByUserId(d.u)
	local char = pl and pl.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local att = char:FindFirstChild("Muzzle", true)
	local pos = if att and att:IsA("Attachment") then att.WorldPosition else root.Position + root.CFrame.LookVector * 2 + Vector3.new(0, 1.2, 0)
	remoteShot(d.u, d.w, pos, if att and att:IsA("Attachment") then att else nil)
end)

-- INIT ------------------------------------------------------------------------------
local inited = false

local function collectModules(): { ModuleScript }
	local found: { ModuleScript } = {}
	local function scan(folder: Instance?)
		if not folder then
			return
		end
		for _, c in folder:GetChildren() do
			if c:IsA("ModuleScript") and c ~= script then
				table.insert(found, c)
			end
		end
	end
	-- `Fx.luau` and the `Fx/` folder share a name: pick the Folder explicitly (FindFirstChild could return the module)
	for _, c in script.Parent:GetChildren() do
		if c:IsA("Folder") and c.Name == "Fx" then
			scan(c)
		end
	end
	scan(script.Parent:FindFirstChild("FxModules")) -- alternative folder name if `Fx` collides with this module
	scan(script) -- init.luau layout: Fx/init.luau + Fx/Other.luau
	table.sort(found, function(a, b)
		return a.Name < b.Name
	end)
	return found
end

function Fx.init()
	if inited then
		return
	end
	inited = true
	Audio.init()

	for _, mod in collectModules() do
		local ok, m = pcall(require, mod)
		if not ok then
			warn("[Fx] failed to require " .. mod.Name .. ": " .. tostring(m))
		elseif type(m) == "table" and type(m.init) == "function" then
			local ok2, err = pcall(m.init, Fx, Audio, Juice)
			if not ok2 then
				warn("[Fx] " .. mod.Name .. ".init failed: " .. tostring(err))
			end
		end
	end

	task.spawn(function()
		local re = Net.event("Fx")
		re.OnClientEvent:Connect(Fx.handle)
	end)
	task.spawn(function()
		local ur = Net.unreliable("FxU")
		ur.OnClientEvent:Connect(Fx.handle)
	end)
end

return Fx
