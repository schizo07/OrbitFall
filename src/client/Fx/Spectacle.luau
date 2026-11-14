--!nonstrict
-- Spectacle: the "make the fight look intense" layer (docs/intensity-spec.md section 3). Loaded by Fx.init like every module
-- in this folder: Spectacle.init(Fx, Audio, Juice). Everything is client-side, pooled, capped and short-lived.
--
-- Inputs / hooks
--   Fx.onExplosion(fn)            every Fx.explosion (network blasts + local heavy-death blasts): dust burst + aftermath
--   Fx "Explosion" {size, p, ...} XL = the Half-Ton: orbital column + 3-layer fireball/mushroom + screen flash + bloom + trauma
--                                 L right after a "Shell" = an orbital barrage shell: column pulse only
--   Fx "Shell" {p, t, s, c}       remembered, so the matching Explosion becomes a barrage column
--   Fx "LanceStart/Move/End"      lance ignition flash + dust, small mushroom where it ends
--   Fx "Death" {fodder, by, ...}  local player's kills: tick sound (pitch climbs with the streak), 30 ms hitstop on 3+ kills in 0.3 s
--   Store "intensity"             state -> haze sheets (BREACH / hold-out), sources -> eruption / crack decal / collapse
--   workspace.Enemies             running enemies near the camera kick up footstep dust (10 Hz poll, capped per tick)
--
-- Pool caps (concurrent): footstep dust emitters 8, blast dust 6 + 4, dust columns 4, smoke bursts 3, haze sheet emitters 4
-- (2 on phones), orbital columns 4, mushrooms 3, crack decals 6, fires 12, smoke columns 12, scorch decals 12.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Spectacle = {}

local Fx: any
local Audio: any
local Juice: any
local Store: any
local IT: any = nil

local LocalPlayer = Players.LocalPlayer
local rng = Random.new()
local C3 = Color3.fromRGB
local V3 = Vector3.new
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local PARK = CFrame.new(0, 3000, 0)

local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_FIRE = "rbxasset://textures/particles/fire_main.dds"

local BLOCK = Enum.PartType.Block
local BALL = Enum.PartType.Ball
local CYL = Enum.PartType.Cylinder
local NEON = Enum.Material.Neon
local PLASTIC = Enum.Material.SmoothPlastic

-- Caps ------------------------------------------------------------------------------------------------------------
local COLUMN_CAP = 4
local MUSH_CAP = 3
local CRACK_CAP = 6
local FIRE_CAP = 12
local SMOKE_CAP = 12
local SCORCH_CAP = 12

local FIRE_LIFE = 25
local SMOKE_LIFE = 60
local SCORCH_LIFE = 120

local COL_H = 600 -- orbital column height (studs)
local MUSH_T = 5.0 -- mushroom lifetime (s)

-- Helpers ---------------------------------------------------------------------------------------------------------
local function rnd(a: number, b: number): number
	return a + (b - a) * rng:NextNumber()
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function ease(u: number): number
	u = math.clamp(u, 0, 1)
	return 1 - (1 - u) * (1 - u)
end

-- quality-scaled particle count (>= 1)
local function qn(x: number): number
	return math.max(1, math.floor(x * Fx.quality + 0.5))
end

local function seq(...: number): NumberSequence
	local pts = { ... }
	local kp = {}
	for i = 1, #pts do
		table.insert(kp, NumberSequenceKeypoint.new((i - 1) / math.max(#pts - 1, 1), pts[i]))
	end
	return NumberSequence.new(kp)
end

local function seqT(list: { { number } }): NumberSequence
	local kp = {}
	for _, k in list do
		table.insert(kp, NumberSequenceKeypoint.new(k[1], k[2]))
	end
	return NumberSequence.new(kp)
end

local function camPos(): Vector3
	local c = workspace.CurrentCamera
	return if c then c.CFrame.Position else Vector3.zero
end

local function dist(p: Vector3): number
	return (camPos() - p).Magnitude
end

local function snd(key: string, at: Vector3?, opts: any?)
	if Audio then
		pcall(Audio.play, key, at, opts)
	end
end

-- CFrame at p whose +Y axis points along the surface normal
local function upCF(p: Vector3, n: Vector3): CFrame
	local ref = if math.abs(n.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local x = ref:Cross(n).Unit
	local z = x:Cross(n)
	return CFrame.fromMatrix(p, x, n, z)
end

local folder: Folder

local function newPart(shape: Enum.PartType, material: Enum.Material, color: Color3, size: Vector3?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Shape = shape
	p.Material = material
	p.Color = color
	p.Size = size or V3(0.2, 0.2, 0.2)
	p.Transparency = 1
	p.CFrame = PARK
	p.Parent = folder
	return p
end

local function park(p: Part)
	p.Transparency = 1
	p.CFrame = PARK
end

-- Ground ray (own params: excludes fx, enemies, characters, breach sources) -------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local filterAt = -10

local function refreshFilter()
	local now = os.clock()
	if now - filterAt < 2 then
		return
	end
	filterAt = now
	local list: { Instance } = { Fx.folder }
	for _, name in { "Enemies", "ClientAudio", "BreachSources" } do
		local inst = workspace:FindFirstChild(name)
		if inst then
			table.insert(list, inst)
		end
	end
	if workspace.CurrentCamera then
		table.insert(list, workspace.CurrentCamera)
	end
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(list, pl.Character)
		end
	end
	rayParams.FilterDescendantsInstances = list
end

local function ground(p: Vector3, up: number?, down: number?): (Vector3?, Vector3?, RaycastResult?)
	refreshFilter()
	local u, d = up or 3, down or 16
	local r = workspace:Raycast(p + V3(0, u, 0), V3(0, -(u + d), 0), rayParams)
	if r then
		return r.Position, r.Normal, r
	end
	return nil, nil, nil
end

local function groundPalette(r: RaycastResult?): { Color3 }
	local c = C3(120, 100, 80)
	if r then
		if r.Instance == workspace.Terrain then
			local ok, col = pcall(function()
				return workspace.Terrain:GetMaterialColor(r.Material)
			end)
			if ok then
				c = col
			end
		elseif r.Instance:IsA("BasePart") then
			c = r.Instance.Color
		end
	end
	return { c, c:Lerp(BLACK, 0.25), c:Lerp(WHITE, 0.12), c:Lerp(BLACK, 0.4) }
end

-- Biome-tinted dust / haze colour --------------------------------------------------------------------------------
local hazeCol = C3(190, 165, 135)
local tintables: { { em: ParticleEmitter, lo: number, hi: number } } = {}

local function applyTint(t: any)
	t.em.Color = ColorSequence.new(hazeCol:Lerp(WHITE, t.lo), hazeCol:Lerp(BLACK, t.hi))
end

local function refreshBiomeColor()
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	local base = if atm then atm.Color else C3(200, 170, 140)
	local col = base:Lerp(C3(172, 158, 144), 0.5)
	if col ~= hazeCol then
		hazeCol = col
		for _, t in tintables do
			applyTint(t)
		end
	end
end

-- Pooled particle emitters ---------------------------------------------------------------------------------------
local function emitterPool(count: number, cfg: (ParticleEmitter) -> (), tintLo: number?, tintHi: number?)
	local parts: { Part } = {}
	local ems: { ParticleEmitter } = {}
	for i = 1, count do
		local part = newPart(BLOCK, PLASTIC, WHITE)
		local em = Instance.new("ParticleEmitter")
		em.Enabled = false
		em.Rate = 0
		em.LockedToPart = false
		em.Texture = TEX_SMOKE
		em.Rotation = NumberRange.new(0, 360)
		cfg(em)
		em.Parent = part
		parts[i], ems[i] = part, em
		if tintLo then
			local t = { em = em, lo = tintLo, hi = tintHi or 0.25 }
			table.insert(tintables, t)
			applyTint(t)
		end
	end
	local idx = 0
	local pool = {}
	function pool.emit(at: Vector3 | CFrame, n: number)
		idx = idx % count + 1
		parts[idx].CFrame = if typeof(at) == "CFrame" then at else CFrame.new(at)
		ems[idx]:Emit(n)
	end
	return pool
end

local stepDust: any, blastDustS: any, blastDustL: any, dustColumn: any, smokeBurst: any, sheets: any

local function buildEmitters()
	local big = if Fx.quality < 0.6 then 0.7 else 1
	stepDust = emitterPool(8, function(em)
		em.Size = seq(0.9, 3.2)
		em.Transparency = seqT({ { 0, 0.55 }, { 0.3, 0.65 }, { 1, 1 } })
		em.Lifetime = NumberRange.new(0.5, 0.9)
		em.Speed = NumberRange.new(2, 5)
		em.SpreadAngle = Vector2.new(70, 70)
		em.Acceleration = V3(0, 2, 0)
		em.Drag = 3
		em.RotSpeed = NumberRange.new(-40, 40)
		em.LightInfluence = 0.7
	end, 0.15, 0.25)
	blastDustS = emitterPool(6, function(em)
		em.Size = seq(2.5, 8)
		em.Transparency = seqT({ { 0, 0.45 }, { 0.5, 0.65 }, { 1, 1 } })
		em.Lifetime = NumberRange.new(0.9, 1.7)
		em.Speed = NumberRange.new(8, 20)
		em.SpreadAngle = Vector2.new(85, 85)
		em.Acceleration = V3(0, 3, 0)
		em.Drag = 3.5
		em.RotSpeed = NumberRange.new(-50, 50)
		em.LightInfluence = 0.7
	end, 0.1, 0.3)
	blastDustL = emitterPool(4, function(em)
		em.Size = seq(6, 22)
		em.Transparency = seqT({ { 0, 0.5 }, { 0.5, 0.7 }, { 1, 1 } })
		em.Lifetime = NumberRange.new(1.6, 3.0)
		em.Speed = NumberRange.new(14, 38)
		em.SpreadAngle = Vector2.new(88, 88)
		em.Acceleration = V3(0, 4, 0)
		em.Drag = 4
		em.RotSpeed = NumberRange.new(-30, 30)
		em.LightInfluence = 0.7
	end, 0.08, 0.35)
	dustColumn = emitterPool(4, function(em)
		em.Size = seq(5, 20)
		em.Transparency = seqT({ { 0, 0.35 }, { 0.6, 0.6 }, { 1, 1 } })
		em.Lifetime = NumberRange.new(1.8, 3.0)
		em.Speed = NumberRange.new(22, 46)
		em.SpreadAngle = Vector2.new(10, 10)
		em.Acceleration = V3(0, 6, 0)
		em.Drag = 2
		em.RotSpeed = NumberRange.new(-30, 30)
		em.LightInfluence = 0.7
	end, 0.05, 0.4)
	smokeBurst = emitterPool(3, function(em)
		em.Color = ColorSequence.new(C3(88, 76, 68), C3(48, 44, 42))
		em.Size = seq(12, 38)
		em.Transparency = seqT({ { 0, 0.4 }, { 0.6, 0.7 }, { 1, 1 } })
		em.Lifetime = NumberRange.new(3, 5)
		em.Speed = NumberRange.new(4, 12)
		em.SpreadAngle = Vector2.new(180, 180)
		em.Acceleration = V3(0, 2, 0)
		em.Drag = 2
		em.RotSpeed = NumberRange.new(-15, 15)
		em.LightInfluence = 0.6
	end)
	-- huge soft billboard sheets for the BREACH haze: very slow, mostly transparent, fade in and out over their life
	sheets = emitterPool(if Fx.quality < 0.6 then 2 else 4, function(em)
		em.Size = seq(46 * big, 66 * big)
		em.Transparency = seqT({ { 0, 1 }, { 0.25, 0.8 }, { 0.7, 0.82 }, { 1, 1 } })
		em.Lifetime = NumberRange.new(8, 11)
		em.Speed = NumberRange.new(1.5, 3.5)
		em.SpreadAngle = Vector2.new(180, 180)
		em.RotSpeed = NumberRange.new(-4, 4)
		em.LightInfluence = 0.85
	end, 0.1, 0.2)
end

-- Bloom pulse (client-side effect, additive to the map's own bloom) ----------------------------------------------------
local bloomFx: BloomEffect? = nil
local bloomAmt = 0

local function pulseBloom(a: number)
	if a <= 0.02 then
		return
	end
	if not bloomFx or not bloomFx.Parent then
		local b = Instance.new("BloomEffect")
		b.Name = "SpectacleBloom"
		b.Intensity = 0
		b.Size = 56
		b.Threshold = 0.9
		b.Parent = Lighting
		bloomFx = b
	end
	bloomAmt = math.max(bloomAmt, a)
end

local function distK(d: number, far: number): number
	return math.clamp(1.1 - d / far, 0.1, 1)
end

-- Generic pool acquire -------------------------------------------------------------------------------------------
local function acquire(list: { any }, cap: number, build: () -> any): any
	for _, r in list do
		if not r.busy then
			return r
		end
	end
	if #list < cap then
		local r = build()
		table.insert(list, r)
		return r
	end
	local best, bestAge = list[1], -math.huge
	local now = os.clock()
	for _, r in list do
		local age = now - r.startAt
		if age > bestAge then
			best, bestAge = r, age
		end
	end
	return best
end

-- Orbital columns ------------------------------------------------------------------------------------------------
local columns: { any } = {}

local function buildColumn()
	return {
		core = newPart(BLOCK, NEON, WHITE),
		glow = newPart(BLOCK, NEON, C3(255, 175, 95)),
		halo = newPart(BLOCK, NEON, C3(255, 130, 60)),
		busy = false,
		startAt = 0,
		t = 0,
		dur = 1,
		w = 1,
		g = Vector3.zero,
		seed = 0,
	}
end

local function updateColumn(c: any, dt: number)
	c.t += dt
	local k = c.t / c.dur
	if k >= 1 then
		c.busy = false
		park(c.core)
		park(c.glow)
		park(c.halo)
		return
	end
	local fall = 1 - k
	local flick = 1 + 0.12 * math.noise(c.t * 22, c.seed)
	local wc = math.max(c.w * fall ^ 0.7 * flick, 0.05)
	local wg = math.max(c.w * 3.4 * fall ^ 0.9, 0.05)
	local wh = math.max(c.w * 8 * fall, 0.05)
	local cf = CFrame.new(c.g + V3(0, COL_H / 2, 0))
	c.core.Size = V3(wc, COL_H, wc)
	c.core.CFrame = cf
	c.core.Transparency = k * 0.6
	c.glow.Size = V3(wg, COL_H, wg)
	c.glow.CFrame = cf
	c.glow.Transparency = 0.45 + 0.55 * k
	c.halo.Size = V3(wh, COL_H, wh)
	c.halo.CFrame = cf
	c.halo.Transparency = 0.86 + 0.14 * k
end

local function startColumn(g: Vector3, w: number, dur: number, tint: Color3?)
	local c = acquire(columns, COLUMN_CAP, buildColumn)
	c.busy = true
	c.startAt = os.clock()
	c.t = 0
	c.dur = dur
	c.w = w
	c.g = g
	c.seed = rnd(0, 100)
	local col = tint or C3(255, 175, 95)
	c.core.Color = WHITE:Lerp(col, 0.12)
	c.glow.Color = col
	c.halo.Color = col:Lerp(C3(255, 90, 40), 0.35)
	updateColumn(c, 0)
end

-- Mushroom (3-layer fireball + rising stem + cap) -----------------------------------------------------------------------
local mushrooms: { any } = {}

local function buildMushroom()
	local m = {
		core = newPart(BALL, NEON, C3(255, 250, 225)),
		mid = newPart(BALL, NEON, C3(255, 170, 60)),
		outer = newPart(BALL, NEON, C3(225, 80, 25)),
		stem = newPart(CYL, PLASTIC, C3(66, 57, 50)),
		cap = newPart(BALL, PLASTIC, C3(92, 70, 55)),
		ring = newPart(CYL, NEON, C3(255, 205, 150)),
		busy = false,
		startAt = 0,
		t = 0,
		g = Vector3.zero,
		rb = 20,
		smoked = false,
	}
	local l = Instance.new("PointLight")
	l.Range = 90
	l.Brightness = 0
	l.Shadows = false
	l.Color = C3(255, 170, 90)
	l.Parent = m.mid
	m.light = l
	return m
end

local VERT = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis X -> vertical

local function updateMushroom(m: any, dt: number)
	m.t += dt
	local t, rb, g = m.t, m.rb, m.g
	if t >= MUSH_T then
		m.busy = false
		m.light.Brightness = 0
		for _, k in { "core", "mid", "outer", "stem", "cap", "ring" } do
			park(m[k])
		end
		return
	end
	local cy = g.Y + rb * (0.55 + 0.55 * t) -- the fireball lifts off the ground
	local at = V3(g.X, cy, g.Z)

	local rCore = rb * 0.95 * ease(t / 0.18)
	m.core.Size = V3(1, 1, 1) * math.max(rCore * 2, 0.2)
	m.core.CFrame = CFrame.new(at)
	m.core.Transparency = math.clamp((t - 0.2) / 0.7, 0, 1)

	local rMid = rb * 1.3 * ease(t / 0.32)
	m.mid.Size = V3(1, 1, 1) * math.max(rMid * 2, 0.2)
	m.mid.CFrame = CFrame.new(at)
	m.mid.Transparency = math.clamp((t - 0.35) / 1.5, 0, 1)

	local rOut = rb * 1.9 * ease(t / 0.55)
	m.outer.Size = V3(1, 1, 1) * math.max(rOut * 2, 0.2)
	m.outer.CFrame = CFrame.new(at)
	m.outer.Transparency = 0.4 + 0.6 * math.clamp(t / 1.8, 0, 1)

	m.light.Brightness = 10 * math.clamp(1 - t / 1.5, 0, 1)

	-- smoke stem + cap
	local u = math.clamp((t - 0.12) / 1.7, 0, 1)
	local h = rb * 5.2 * ease(u)
	local dia = rb * (1.1 + 0.5 * u)
	if t > 0.12 then
		m.stem.Size = V3(math.max(h, 0.2), dia, dia)
		m.stem.CFrame = CFrame.new(g + V3(0, h / 2, 0)) * VERT
		m.stem.Transparency = 0.25 + 0.75 * math.clamp((t - 2.6) / 2.0, 0, 1)
	end
	if t > 0.3 then
		local u2 = math.clamp((t - 0.3) / 1.9, 0, 1)
		local capW = rb * (0.9 + 2.5 * ease(u2))
		local capH = capW * 0.55
		m.cap.Size = V3(capW, capH, capW)
		m.cap.CFrame = CFrame.new(g + V3(0, h + capH * 0.15, 0))
		m.cap.Transparency = 0.2 + 0.8 * math.clamp((t - 2.8) / 2.0, 0, 1)
		if t > 1.3 and not m.smoked then
			m.smoked = true
			smokeBurst.emit(g + V3(0, h, 0), qn(10))
		end
	end
	-- ground shock ring
	local d = rb * 6.5 * ease(t / 0.55)
	m.ring.Size = V3(0.25, math.max(d, 0.5), math.max(d, 0.5))
	m.ring.CFrame = CFrame.new(g + V3(0, 0.2, 0)) * VERT
	m.ring.Transparency = 0.25 + 0.75 * math.clamp(t / 0.6, 0, 1)
end

local function startMushroom(g: Vector3, rb: number)
	local m = acquire(mushrooms, MUSH_CAP, buildMushroom)
	m.busy = true
	m.startAt = os.clock()
	m.t = 0
	m.g = g
	m.rb = rb
	m.smoked = false
	m.stem.Transparency = 1
	m.cap.Transparency = 1
	updateMushroom(m, 0)
end

-- Full orbital strike. sc 1 = the Half-Ton; mini = barrage shell (column + dust only).
-- opts.noDust: the caller's explosion already went through Fx.onExplosion, which throws the ground dust.
-- opts.noCam: client/Fx/Blast.luau already shook the camera and flashed the screen for this blast.
function Spectacle.orbital(p: Vector3, sc: number, opts: { mini: boolean?, tint: Color3?, noDust: boolean?, noCam: boolean? }?)
	opts = opts or {}
	local g = ground(p, 4, 24) or p
	local d = dist(g)
	if opts.mini then
		startColumn(g, 2.2 * sc, 0.75, opts.tint)
		return
	end
	startColumn(g, 6 * sc, 1.4, opts.tint)
	startMushroom(g, 20 * sc)
	if not opts.noDust then
		blastDustL.emit(g, qn(26))
		blastDustS.emit(g, qn(12))
	end
	dustColumn.emit(g, qn(20))
	-- camera: trauma ~1/dist out to 120 studs, white flash (distance + facing scaled), bloom pulse
	if not opts.noCam then
		Juice.trauma(5.5 * sc, 1.5, g, 120)
		Juice.flashAt(C3(255, 252, 240), 0.9, 0.4, g, 700)
	end
	pulseBloom(1.3 * distK(d, 900) * sc)
	if d > 120 then -- far strike: a delayed low rumble so the whole map hears it
		task.delay(math.min(d / 500, 1.4), function()
			snd("WarnRumble", g, { volume = 0.9, priority = 4 })
		end)
	end
end

-- Aftermath: fires (25 s), smoke columns (60 s), scorch decals (120 s) ------------------------------------------------
local fires: { any } = {}
local smokeCols: { any } = {}

local function buildFire()
	local part = newPart(BLOCK, PLASTIC, WHITE, V3(1, 1, 1))
	local flame = Instance.new("ParticleEmitter")
	flame.Enabled = false
	flame.Rate = 0
	flame.Texture = TEX_FIRE
	flame.LockedToPart = false
	flame.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, C3(255, 235, 170)),
		ColorSequenceKeypoint.new(0.4, C3(255, 140, 50)),
		ColorSequenceKeypoint.new(1, C3(170, 50, 20)),
	})
	flame.LightEmission = 1
	flame.LightInfluence = 0
	flame.Transparency = seq(0.1, 0.4, 1)
	flame.Lifetime = NumberRange.new(0.5, 1.0)
	flame.Speed = NumberRange.new(4, 8)
	flame.SpreadAngle = Vector2.new(18, 18)
	flame.Acceleration = V3(0, 3, 0)
	flame.Rotation = NumberRange.new(0, 360)
	flame.RotSpeed = NumberRange.new(-60, 60)
	flame.Parent = part
	local wisp = Instance.new("ParticleEmitter")
	wisp.Enabled = false
	wisp.Rate = 0
	wisp.Texture = TEX_SMOKE
	wisp.LockedToPart = false
	wisp.Color = ColorSequence.new(C3(60, 55, 52), C3(40, 38, 38))
	wisp.Transparency = seq(0.5, 0.75, 1)
	wisp.Lifetime = NumberRange.new(2, 3.5)
	wisp.Speed = NumberRange.new(6, 10)
	wisp.SpreadAngle = Vector2.new(14, 14)
	wisp.Acceleration = V3(1.5, 3, 0.5)
	wisp.Rotation = NumberRange.new(0, 360)
	wisp.RotSpeed = NumberRange.new(-20, 20)
	wisp.LightInfluence = 0.6
	wisp.Parent = part
	local light = Instance.new("PointLight")
	light.Color = C3(255, 150, 70)
	light.Range = 22
	light.Brightness = 0
	light.Shadows = false
	light.Enabled = false
	light.Parent = part
	return { part = part, flame = flame, wisp = wisp, light = light, busy = false, startAt = 0, expireAt = 0, pos = Vector3.zero, seed = rnd(0, 100), baseFlame = 14, baseWisp = 4, baseLight = 2 }
end

local function startFire(g: Vector3, sc: number)
	local r = acquire(fires, FIRE_CAP, buildFire)
	local now = os.clock()
	r.busy = true
	r.startAt = now
	r.expireAt = now + FIRE_LIFE
	r.pos = g
	r.part.CFrame = CFrame.new(g + V3(0, 0.6, 0))
	r.flame.Size = seq(1.6 * sc, 2.4 * sc, 0.4 * sc)
	r.wisp.Size = seq(2 * sc, 7 * sc)
	r.baseFlame = 14 * Fx.quality
	r.baseWisp = 4 * Fx.quality
	r.baseLight = 1.6 + sc
	r.flame.Rate = r.baseFlame
	r.wisp.Rate = r.baseWisp
	r.flame.Enabled = true
	r.wisp.Enabled = true
	r.light.Enabled = true
end

local function buildSmokeCol()
	local part = newPart(BLOCK, PLASTIC, WHITE, V3(1, 1, 1))
	local em = Instance.new("ParticleEmitter")
	em.Enabled = false
	em.Rate = 0
	em.Texture = TEX_SMOKE
	em.LockedToPart = false
	em.Color = ColorSequence.new(C3(62, 56, 52), C3(120, 112, 104))
	em.Transparency = seqT({ { 0, 0.45 }, { 0.15, 0.4 }, { 0.7, 0.65 }, { 1, 1 } })
	em.Lifetime = NumberRange.new(6, 9)
	em.Speed = NumberRange.new(12, 20)
	em.SpreadAngle = Vector2.new(5, 5)
	em.Acceleration = V3(4, 3, 2) -- the wind leans the column over
	em.Rotation = NumberRange.new(0, 360)
	em.RotSpeed = NumberRange.new(-10, 10)
	em.LightInfluence = 0.8
	em.Parent = part
	return { part = part, em = em, busy = false, startAt = 0, expireAt = 0, pos = Vector3.zero, baseRate = 3.2 }
end

local function startSmokeCol(g: Vector3, sc: number)
	local r = acquire(smokeCols, SMOKE_CAP, buildSmokeCol)
	local now = os.clock()
	r.busy = true
	r.startAt = now
	r.expireAt = now + SMOKE_LIFE
	r.pos = g
	r.part.CFrame = CFrame.new(g + V3(0, 1, 0))
	r.em.Size = seq(4 * sc, 14 * sc, 26 * sc)
	r.baseRate = 3.2 * Fx.quality
	r.em.Rate = r.baseRate
	r.em.Enabled = true
end

-- Decals: pooled flat parts with a shared fade driver (crack decals under breach sources, long-lived scorch) ------------
local decals: { any } = {}
local crackPool: { any } = {}
local scorchPool: { any } = {}

local function buildDecal(nParts: number)
	local parts, base = {}, {}
	for i = 1, nParts do
		parts[i] = newPart(BLOCK, PLASTIC, BLACK)
		base[i] = 0.2
	end
	return { parts = parts, base = base, alpha = 0, target = 0, rate = 1, busy = false, startAt = 0, fadeAt = math.huge, applied = -1 }
end

local function decalApply(d: any)
	local a = d.alpha
	for i, p in d.parts do
		p.Transparency = 1 - (1 - d.base[i]) * a
	end
	d.applied = a
end

local function decalShow(d: any, fadeInTime: number)
	d.busy = true
	d.startAt = os.clock()
	d.alpha = 0
	d.target = 1
	d.rate = 1 / math.max(fadeInTime, 0.05)
	d.applied = -1
	if not table.find(decals, d) then
		table.insert(decals, d)
	end
end

local function decalHide(d: any, fadeOutTime: number)
	d.target = 0
	d.fadeAt = math.huge
	d.rate = 1 / math.max(fadeOutTime, 0.05)
end

local function stepDecals(dt: number, now: number)
	for i = #decals, 1, -1 do
		local d = decals[i]
		if now >= d.fadeAt and d.target > 0 then
			decalHide(d, 10)
		end
		if d.alpha < d.target then
			d.alpha = math.min(d.alpha + dt * d.rate, d.target)
		elseif d.alpha > d.target then
			d.alpha = math.max(d.alpha - dt * d.rate, d.target)
		end
		if d.alpha ~= d.applied then
			decalApply(d)
		end
		if d.alpha <= 0 and d.target <= 0 then
			for _, p in d.parts do
				park(p)
			end
			d.busy = false
			table.remove(decals, i)
		end
	end
end

-- big scorch: dark disc + softer outer ring, 120 s, fades over the last 10 s
local function startScorch(g: Vector3, n: Vector3, diameter: number)
	if n.Y < 0.55 then
		return -- no coins stuck on cliff faces
	end
	local d = acquire(scorchPool, SCORCH_CAP, function()
		return buildDecal(2)
	end)
	local cf = upCF(g + n * 0.06, n)
	local disc, ring = d.parts[1], d.parts[2]
	disc.Shape, ring.Shape = CYL, CYL
	disc.Color, ring.Color = C3(16, 14, 13), C3(34, 30, 28)
	disc.Size = V3(0.06, diameter, diameter)
	ring.Size = V3(0.05, diameter * 1.55, diameter * 1.55)
	disc.CFrame = cf * VERT
	ring.CFrame = upCF(g + n * 0.04, n) * VERT
	d.base[1], d.base[2] = 0.15, 0.62
	decalShow(d, 0.5)
	d.fadeAt = os.clock() + SCORCH_LIFE - 10
end

local function aftermath(g: Vector3, n: Vector3?, size: string, R: number, silent: boolean)
	local sc = math.clamp(R / 10, 0.7, 2.4)
	if size == "XL" then
		startFire(g, sc)
		for _ = 1, 2 do
			local a = rnd(0, math.pi * 2)
			startFire(g + V3(math.cos(a), 0, math.sin(a)) * R * rnd(0.3, 0.6), sc * 0.8)
		end
		startSmokeCol(g, sc * 1.3)
	else
		startFire(g, sc)
		if not silent or rng:NextNumber() < 0.5 then
			startSmokeCol(g, sc)
		end
	end
	if n then
		startScorch(g, n, R * (if size == "XL" then 3 else 2.2))
	end
end

-- Dust kick-up for client/Fx/Blast.luau (the shared explosion effect), sized by its K (1 = frag grenade).
function Spectacle.blastDust(g: Vector3, K: number)
	if not blastDustS or dist(g) > 450 then
		return
	end
	if K >= 2.5 then
		blastDustL.emit(g, qn(26))
		blastDustS.emit(g, qn(12))
		dustColumn.emit(g, qn(12))
	elseif K >= 1.3 then
		blastDustL.emit(g, qn(10 + 3 * K))
		blastDustS.emit(g, qn(8))
	else
		blastDustS.emit(g, qn(5 + 7 * K))
	end
end

local function onExplosion(p: Vector3, size: string, style: string, R: number, silent: boolean)
	local d = dist(p)
	if d > 800 then
		return
	end
	local g, n = ground(p, 4, 18)
	local at = g or p
	local big = size == "XL" or size == "L"
	if d <= 450 then
		if size == "XL" then
			blastDustL.emit(at, qn(26))
			blastDustS.emit(at, qn(12))
		elseif size == "L" then
			blastDustL.emit(at, qn(14))
			blastDustS.emit(at, qn(8))
		else
			blastDustS.emit(at, qn(6 + R))
		end
	end
	if style == "fire" and big and (size == "XL" or d <= 500) and (size == "XL" or not silent or rng:NextNumber() < 0.5) then
		aftermath(at, n, size, R, silent)
	end
end

-- Breach sources: eruption, crack decal, collapse ---------------------------------------------------------------------
local CRACK_PAL: { [string]: { dark: Color3, glow: Color3 } } = {
	BROOD = { dark = C3(34, 26, 20), glow = C3(150, 235, 90) },
	COG = { dark = C3(20, 20, 22), glow = C3(255, 150, 60) },
	LUMEN = { dark = C3(30, 24, 44), glow = C3(150, 125, 255) },
}

local function startCrack(g: Vector3, n: Vector3, faction: string): any
	local pal = CRACK_PAL[faction] or CRACK_PAL.BROOD
	local d = acquire(crackPool, CRACK_CAP, function()
		return buildDecal(11)
	end)
	local diameter = 14
	local base = upCF(g + n * 0.07, n)
	local disc = d.parts[1]
	disc.Shape = CYL
	disc.Color = pal.dark
	disc.Material = PLASTIC
	disc.Size = V3(0.08, diameter, diameter)
	disc.CFrame = base * VERT
	d.base[1] = 0.12
	for i = 1, 5 do
		local ang = (i - 1) / 5 * math.pi * 2 + rnd(-0.3, 0.3)
		local len = rnd(6, 12)
		local w = rnd(0.5, 0.9)
		local cf = base * CFrame.Angles(0, ang, 0) * CFrame.new(len * 0.5 + diameter * 0.2, 0.02, 0)
		local dark = d.parts[1 + i]
		dark.Shape = BLOCK
		dark.Color = pal.dark
		dark.Material = PLASTIC
		dark.Size = V3(len, 0.05, w)
		dark.CFrame = cf
		d.base[1 + i] = 0.1
		local glow = d.parts[6 + i]
		glow.Shape = BLOCK
		glow.Color = pal.glow
		glow.Material = NEON
		glow.Size = V3(len * 0.9, 0.05, w * 0.35)
		glow.CFrame = cf * CFrame.new(0, 0.03, 0)
		d.base[6 + i] = 0.3
	end
	decalShow(d, 0.7)
	d.fadeAt = os.clock() + 70 -- safety net: normally closed with the source
	return d
end

local function eruption(g: Vector3, faction: string, strength: number, palette: { Color3 }?)
	local d = dist(g)
	dustColumn.emit(g + V3(0, 0.5, 0), qn(22 * strength))
	blastDustL.emit(g, qn(12 * strength))
	if d < 220 then
		Fx.debris(g + V3(0, 1, 0), {
			n = math.floor(14 * strength),
			style = "rock",
			palette = palette,
			speed = 46,
			up = 1.8,
			scale = 1.6,
			life = 2.2,
		})
	end
	if d < 60 then
		Juice.shake(0.5 + 0.5 * (1 - d / 60), 0.5) -- 0.5 trauma inside ~60 studs
	end
end

type SourceRec = { f: string, p: Vector3, g: Vector3, ready: boolean, crack: any?, pal: { Color3 }? }
local sources: { [number]: SourceRec } = {}
local firstSnapshot = true

local function onSourceOpen(id: number, rec: SourceRec)
	local g, n, res = ground(rec.p, 4, 12)
	rec.g = g or rec.p
	rec.pal = groundPalette(res)
	if g and n and n.Y > 0.55 and dist(g) < 500 then
		rec.crack = startCrack(g, n, rec.f)
	end
	if rec.f == "BROOD" then
		-- the hole bursts open right now (the server's "Breach" fx adds its own small crater + rumble)
		eruption(rec.g, rec.f, 1, rec.pal)
	else
		-- pod / shard incoming: a puff of dust and a low rumble from the ground
		blastDustS.emit(rec.g, qn(8))
		snd("WarnRumble", rec.g, { volume = 0.7, pitch = 1.1, priority = 3 })
	end
end

local function onSourceReady(id: number, rec: SourceRec)
	if rec.f == "BROOD" then
		eruption(rec.g, rec.f, 0.6, rec.pal)
		snd("Breach", rec.g, { volume = 0.8, pitch = 0.9, priority = 4 })
		snd("ChargerRoar", rec.g, { volume = 0.4, pitch = 0.75, priority = 3 }) -- the low howl
	elseif rec.f == "COG" then
		eruption(rec.g, rec.f, 1.2, rec.pal)
		snd("ExplosionSmall", rec.g, { volume = 0.8, pitch = 0.7, priority = 4 })
		snd("Breach", rec.g, { volume = 0.5, pitch = 0.8, priority = 3 })
	else
		eruption(rec.g, rec.f, 1, rec.pal)
		snd("EMP", rec.g, { volume = 0.6, pitch = 0.8, priority = 4 })
		snd("Breach", rec.g, { volume = 0.5, pitch = 0.9, priority = 3 })
	end
end

local function onSourceClose(id: number, rec: SourceRec, why: string)
	if rec.crack then
		decalHide(rec.crack, if why == "destroyed" then 3 else 5)
		rec.crack = nil
	end
	local d = dist(rec.g)
	if why == "destroyed" then
		-- collapse: a big dust puff, chunks slumping back in, a low groan
		blastDustL.emit(rec.g, qn(16))
		dustColumn.emit(rec.g + V3(0, 0.5, 0), qn(10))
		if d < 220 then
			Fx.debris(rec.g + V3(0, 1, 0), { n = 8, style = "rock", palette = rec.pal, speed = 16, up = 0.7, scale = 1.4, life = 1.8 })
		end
		snd("Breach", rec.g, { volume = 0.7, pitch = 0.55, priority = 3 })
		if d < 70 then
			Juice.shake(0.4 + 0.4 * (1 - d / 70), 0.45)
		end
	else
		blastDustS.emit(rec.g, qn(8)) -- breach over / cleared: quiet collapse
	end
end

local function descentOf(f: string): number
	local ok, v = pcall(function()
		return IT.Sources.descent[f]
	end)
	return if ok and type(v) == "number" then v else 1.5
end

-- haze level follows the pacing state
local sheetLevel, sheetTarget = 0, 0

local function onIntensity(s: any)
	if type(s) ~= "table" then
		return
	end
	if s.extract == true or s.state == "breach" then
		sheetTarget = 1
	elseif s.state == "build" then
		sheetTarget = 0.3
	elseif s.state == "relax" then
		sheetTarget = 0.35
	else
		sheetTarget = 0
	end
	refreshBiomeColor()

	local list = s.sources
	if type(list) ~= "table" then
		list = {}
	end
	local seen: { [number]: boolean } = {}
	for _, e in list do
		if type(e) == "table" and e.id and typeof(e.p) == "Vector3" then
			seen[e.id] = true
			local rec = sources[e.id]
			if not rec then
				rec = { f = e.f or "BROOD", p = e.p, g = e.p, ready = e.ready == true, crack = nil, pal = nil }
				sources[e.id] = rec
				if not firstSnapshot then
					onSourceOpen(e.id, rec)
					if not rec.ready then
						local id = e.id
						task.delay(descentOf(rec.f), function()
							local r = sources[id]
							if r and not r.ready then
								r.ready = true
								onSourceReady(id, r)
							end
						end)
					end
				end
			elseif e.ready == true and not rec.ready then
				rec.ready = true
				onSourceReady(e.id, rec)
			end
		end
	end
	for id, rec in sources do
		if not seen[id] then
			sources[id] = nil
			local why = "expired"
			local ev = s.ev
			if type(ev) == "table" and ev.k == "close" and ev.id == id and type(ev.why) == "string" then
				why = ev.why
			end
			onSourceClose(id, rec, why)
		end
	end
	firstSnapshot = false
end

-- Footstep dust --------------------------------------------------------------------------------------------------
local lastPos: { [Instance]: Vector3 } = setmetatable({}, { __mode = "k" })
local lastAt: { [Instance]: number } = setmetatable({}, { __mode = "k" })
local nextPuff: { [Instance]: number } = setmetatable({}, { __mode = "k" })
local sizeOf: { [Instance]: number } = setmetatable({}, { __mode = "k" })
local STEP_RANGE = 55

local function tickFootsteps(now: number)
	local enemies = workspace:FindFirstChild("Enemies")
	if not enemies then
		return
	end
	local kids = enemies:GetChildren()
	local nK = #kids
	if nK == 0 then
		return
	end
	local cp = camPos()
	local budget = math.max(2, math.floor(6 * Fx.quality + 0.5))
	local start = rng:NextInteger(1, nK)
	for k = 0, nK - 1 do
		local m = kids[(start + k - 1) % nK + 1]
		local root = if m:IsA("Model") then m.PrimaryPart else nil
		if root then
			local pos = root.Position
			local prev, prevAt = lastPos[m], lastAt[m]
			lastPos[m], lastAt[m] = pos, now
			if prev and prevAt and budget > 0 and (pos - cp).Magnitude < STEP_RANGE and now >= (nextPuff[m] or 0) then
				local v = pos - prev
				local speed = V3(v.X, 0, v.Z).Magnitude / math.max(now - prevAt, 0.03)
				if speed > 7 then
					local s = sizeOf[m]
					if not s then
						s = math.clamp(m:GetExtentsSize().Y / 4, 0.7, 3)
						if m:GetAttribute("Fodder") then
							s *= 0.8
						end
						sizeOf[m] = s
					end
					local g = ground(pos, 2, 10 + 4 * s)
					if g and pos.Y - g.Y < 4 + 3 * s then -- not airborne (flyers / leaps)
						budget -= 1
						nextPuff[m] = now + rnd(0.26, 0.38)
						if s >= 2 then
							blastDustS.emit(g + V3(0, 0.3, 0), qn(2 * s)) -- a heavy stomp
						else
							stepDust.emit(g + V3(0, 0.3, 0), if s > 1.3 then 2 else 1)
						end
					end
				end
			end
		end
	end
end

-- Kill feedback -------------------------------------------------------------------------------------------------------
local killTimes: { number } = {}
local streak, lastKill, lastTick, lastStop = 0, -10, -10, -10

local function onMyKill(d: any)
	if d.by ~= LocalPlayer.UserId then
		return
	end
	local t = os.clock()
	if t - lastKill > 1.4 then
		streak = 0
	end
	streak += 1
	lastKill = t
	-- kill tick: a short tick whose pitch climbs with the streak
	if t - lastTick > 0.045 then
		lastTick = t
		if Audio then
			pcall(Audio.play2D, "DialTick", { volume = 0.32, pitch = math.min(1 + streak * 0.035, 1.6), priority = 2 })
		end
	end
	-- multi-kill: 3+ kills inside 0.3 s -> 30 ms hitstop (max one per 0.4 s so a horde cannot chain-stutter the view)
	table.insert(killTimes, t)
	while #killTimes > 0 and t - killTimes[1] > 0.3 do
		table.remove(killTimes, 1)
	end
	if #killTimes >= 3 and t - lastStop > 0.4 then
		lastStop = t
		Juice.hitstop(0.03)
	end
end

-- Per-frame driver ---------------------------------------------------------------------------------------------------
local stepAcc, upkeepAcc, tintAcc = 0, 0, 0
local sheetNext: { number } = {}

local function stepSheets(dt: number, now: number)
	sheetLevel += math.clamp(sheetTarget - sheetLevel, -dt * 0.2, dt * 0.4)
	if sheetLevel < 0.04 then
		return
	end
	local c = workspace.CurrentCamera
	if not c then
		return
	end
	for i = 1, if Fx.quality < 0.6 then 2 else 4 do
		if now >= (sheetNext[i] or 0) then
			sheetNext[i] = now + lerp(7.5, 2.8, sheetLevel) * rnd(0.8, 1.25)
			local look = c.CFrame.LookVector
			local flat = V3(look.X, 0, look.Z)
			flat = if flat.Magnitude > 0.01 then flat.Unit else V3(0, 0, -1)
			local dir = CFrame.Angles(0, rnd(-1.9, 1.9), 0) * flat
			sheets.emit(c.CFrame.Position + dir * rnd(30, 80) + V3(0, rnd(-3, 12), 0), 1)
		end
	end
end

local function upkeep(now: number)
	local cp = camPos()
	for _, r in fires do
		if r.busy then
			if now >= r.expireAt then
				r.busy = false
				r.flame.Enabled, r.wisp.Enabled, r.light.Enabled = false, false, false
				r.part.CFrame = PARK
			else
				local fade = math.clamp((r.expireAt - now) / 5, 0, 1)
				local on = (cp - r.pos).Magnitude < 260
				r.flame.Enabled, r.wisp.Enabled, r.light.Enabled = on, on, on
				if on then
					r.flame.Rate = r.baseFlame * fade
					r.wisp.Rate = r.baseWisp * fade
					r.light.Brightness = r.baseLight * fade * (0.7 + 0.6 * (math.noise(now * 3.1, r.seed) + 0.5))
				end
			end
		end
	end
	for _, r in smokeCols do
		if r.busy then
			if now >= r.expireAt then
				r.busy = false
				r.em.Enabled = false
				r.part.CFrame = PARK
			else
				local fade = math.clamp((r.expireAt - now) / 12, 0, 1)
				local on = (cp - r.pos).Magnitude < 450
				r.em.Enabled = on
				if on then
					r.em.Rate = r.baseRate * fade
				end
			end
		end
	end
end

local function step(dt: number)
	local now = os.clock()
	-- bloom pulse decay
	if bloomAmt > 0.001 then
		bloomAmt *= math.exp(-dt * 3.2)
		if bloomFx then
			bloomFx.Intensity = bloomAmt
		end
	elseif bloomFx and bloomFx.Intensity ~= 0 then
		bloomAmt = 0
		bloomFx.Intensity = 0
	end
	stepSheets(dt, now)
	for _, c in columns do
		if c.busy then
			updateColumn(c, dt)
		end
	end
	for _, m in mushrooms do
		if m.busy then
			updateMushroom(m, dt)
		end
	end
	if #decals > 0 then
		stepDecals(dt, now)
	end
	stepAcc += dt
	if stepAcc >= 0.1 then
		stepAcc = 0
		tickFootsteps(now)
	end
	upkeepAcc += dt
	if upkeepAcc >= 0.1 then
		upkeepAcc = 0
		upkeep(now)
	end
	tintAcc += dt
	if tintAcc >= 8 then
		tintAcc = 0
		refreshBiomeColor()
	end
end

-- Init ------------------------------------------------------------------------------------------------------------
local function findClientRoot(): Instance?
	local inst: Instance? = script.Parent
	for _ = 1, 4 do
		if inst and inst:FindFirstChild("Store") then
			return inst
		end
		inst = inst and inst.Parent
	end
	return nil
end

function Spectacle.init(fx: any, audio: any, juice: any)
	Fx, Audio, Juice = fx, audio, juice
	folder = Instance.new("Folder")
	folder.Name = "Spectacle"
	folder.Parent = Fx.folder

	local okIT, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Intensity"))
	end)
	if okIT then
		IT = mod
	end

	buildEmitters()
	refreshBiomeColor()
	Lighting.ChildAdded:Connect(function(c)
		if c:IsA("Atmosphere") then
			task.defer(refreshBiomeColor)
		end
	end)

	Fx.onExplosion(onExplosion)

	-- network blasts: XL = Half-Ton (full orbital), L right after a Shell = barrage shell (column pulse)
	local shells: { { p: Vector3, due: number, c: Color3?, s: number } } = {}
	Fx.register("Shell", function(d)
		if typeof(d.p) ~= "Vector3" then
			return
		end
		if #shells >= 24 then
			table.remove(shells, 1)
		end
		table.insert(shells, { p = d.p, due = os.clock() + (d.t or 1.3), c = d.c, s = d.s or 1 })
	end)
	-- "Blast" = the same payload from server/Explosions.luau (grenades, call-ins); Fx/Blast.luau draws the blast itself
	local function onNetBlast(d)
		if typeof(d) ~= "table" or typeof(d.p) ~= "Vector3" then
			return
		end
		if d.size == "XL" then
			local isNew = Fx.blastIsNew ~= nil and Fx.blastIsNew()
			local sc = if isNew and Fx.blastScale then math.max(Fx.blastScale(), 0.5) else 1
			Spectacle.orbital(d.p, sc, { noDust = true, noCam = isNew })
		elseif d.size == "L" then
			local now = os.clock()
			for i = #shells, 1, -1 do
				local sh = shells[i]
				if now - sh.due > 2 then
					table.remove(shells, i)
				elseif sh.s >= 0.5 and (sh.p - d.p).Magnitude < 14 and now >= sh.due - 0.6 and d.style ~= "gas" then
					table.remove(shells, i)
					Spectacle.orbital(d.p, 1, { mini = true, tint = sh.c })
					break
				end
			end
		end
	end
	Fx.register("Explosion", onNetBlast)
	Fx.register("Blast", onNetBlast)

	-- orbital lance: ignition flash + dust, a small mushroom where it ends
	local lancePos: { [any]: Vector3 } = {}
	Fx.register("LanceStart", function(d)
		if typeof(d.p) ~= "Vector3" then
			return
		end
		lancePos[d.id] = d.p
		local g = ground(d.p, 4, 24) or d.p
		local dd = dist(g)
		blastDustL.emit(g, qn(14))
		dustColumn.emit(g, qn(10))
		Juice.flashAt(C3(255, 235, 215), 0.4, 0.4, g, 700)
		Juice.trauma(2, 0.8, g, 120)
		pulseBloom(0.9 * distK(dd, 900))
	end)
	Fx.register("LanceMove", function(d)
		if typeof(d.p) == "Vector3" then
			lancePos[d.id] = d.p
		end
	end)
	Fx.register("LanceEnd", function(d)
		local p = lancePos[d.id]
		lancePos[d.id] = nil
		if p then
			Spectacle.orbital(p, 0.45)
		end
	end)

	Fx.register("Death", onMyKill)

	RunService.Heartbeat:Connect(step)

	task.spawn(function()
		local root = findClientRoot()
		if not root then
			warn("[Spectacle] client root not found")
			return
		end
		Store = require((root :: any).Store)
		Store.on("intensity", onIntensity)
	end)
end

return Spectacle
