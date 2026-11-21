--!nonstrict
-- Blast: the one client explosion effect (footage pass 2026-11-14). Every explosion goes through it:
--   * Fx "Blast" {p, r, size, style, k, sh, shr, sk, skr, sw, cr}   server/Explosions.luau (grenades, rounds, call-ins, mines)
--   * Fx.explosion(p, opts)   replaced at init, so the stock Fx "Explosion" handler and local blasts (heavy deaths) use it too
-- One size parameter K (payload `k`, else derived from the radius `r`; 1 = a frag grenade) scales every layer:
--   flash ball + PointLight pop, layered fireball (white core, yellow-orange, orange) that hands over to dark smoke balls,
--   a lingering smoke column (particle emitter; 2 s for a grenade up to ~12 s for the Half-Ton), debris chunks on arcs
--   (Fx.debris: physics, bounce, fade), a segmented ground shockwave ring, dust kick-up (Spectacle pools), a scorch
--   disc that fades out over ~30 s, sparks + embers, camera shake + FOV punch by distance and size, a screen flash
--   when close.
-- Everything is pooled (balls, rings, scorches, emitters) and stepped by one Heartbeat handler.
--
-- Studio A/B (workspace attributes, read only in Studio; client/Variants.luau group EXPLOSIONS / BLAST SHAKE):
--   Feel_BlastScale  0 = "Current" (the old Fx.explosion look + the old separate shake / shockwave / crater sends),
--                    1 = Big (default), 1.4 = Huge. Visual only: the gameplay radius is server-side (Data/Blasts.luau).
--   Feel_BlastShake  camera shake + FOV punch multiplier (default 1)

local RunService = game:GetService("RunService")

local Blast = {}

local Fx: any
local Audio: any
local Juice: any
local Spectacle: any = nil
local legacyExplosion: any = nil

local IS_STUDIO = RunService:IsStudio()
local rng = Random.new()
local C3 = Color3.fromRGB
local V3 = Vector3.new
local PARK = CFrame.new(0, -5000, 0)
local VERT = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis X -> part's Y

local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"

-- caps -----------------------------------------------------------------------------------------------------------
local BALL_CAP = 120 -- live fireball / smoke / mushroom balls (x quality at init)
local lastMushroom = 0
local LIGHT_CAP = 6
local RING_CAP = 6
local RING_SEGS = 12
local SCORCH_CAP = 14
local COLUMN_CAP = 6
local SCORCH_HOLD = 20 -- seconds fully dark
local SCORCH_FADE = 10 -- then fades out (gone ~30 s after the blast)

local FLASH_WHITE_GOLD = C3(255, 251, 224) -- #FFFBE0 Beat 1 flash
local BOUNCE_ORANGE = C3(255, 140, 26) -- #FF8C1A Beat 1 dynamic bounce light
local SOOT_BASE = C3(31, 27, 24) -- #1F1B18 Beat 4 dense charcoal column
local SOOT_TOP = C3(74, 67, 60) -- #4A433C
local SAND_BASE = C3(216, 186, 144) -- tan desert sand eruption plume
local SAND_EDGE = C3(156, 132, 102)

local STYLES = {
	fire = { core = FLASH_WHITE_GOLD, hot = C3(255, 198, 72), mid = C3(255, 122, 24), edge = C3(217, 56, 14), smoke = SOOT_BASE, spark = C3(255, 200, 82), light = BOUNCE_ORANGE },
	emp = { core = C3(225, 250, 255), hot = C3(140, 220, 255), mid = C3(70, 170, 255), edge = C3(40, 110, 240), smoke = C3(70, 100, 140), spark = C3(150, 225, 255), light = C3(100, 200, 255) },
	gas = { core = C3(235, 255, 205), hot = C3(190, 255, 120), mid = C3(130, 230, 70), edge = C3(70, 170, 40), smoke = C3(90, 160, 60), spark = C3(190, 255, 120), light = C3(150, 255, 90) },
	goo = { core = C3(220, 255, 205), hot = C3(170, 250, 120), mid = C3(110, 225, 80), edge = C3(50, 155, 50), smoke = C3(60, 120, 55), spark = C3(160, 255, 110), light = C3(120, 255, 110) },
	-- call-ins: Cryo Bomb, Gravity Well, Railshot
	ice = { core = C3(245, 253, 255), hot = C3(200, 240, 255), mid = C3(140, 215, 255), edge = C3(90, 170, 240), smoke = C3(215, 235, 250), spark = C3(220, 248, 255), light = C3(160, 225, 255) },
	void = { core = C3(250, 235, 255), hot = C3(210, 140, 255), mid = C3(150, 70, 240), edge = C3(80, 30, 170), smoke = C3(50, 30, 75), spark = C3(220, 170, 255), light = C3(170, 90, 255) },
	rail = { core = C3(255, 255, 255), hot = C3(200, 245, 255), mid = C3(120, 210, 255), edge = C3(70, 120, 255), smoke = C3(70, 75, 90), spark = C3(210, 245, 255), light = C3(150, 220, 255) },
	spark = { core = C3(255, 255, 230), hot = C3(255, 235, 140), mid = C3(255, 200, 80), edge = C3(255, 150, 40), smoke = C3(100, 96, 92), spark = C3(255, 230, 130), light = C3(255, 225, 120) },
}

-- helpers --------------------------------------------------------------------------------------------------------
local function rnd(a: number, b: number): number
	return a + (b - a) * rng:NextNumber()
end

local function q(n: number): number
	return math.max(1, math.floor(n * (Fx and Fx.quality or 1) + 0.5))
end

local function attrNum(name: string, default: number): number
	if not IS_STUDIO then
		return default
	end
	local v = workspace:GetAttribute(name)
	return if typeof(v) == "number" then v else default
end

function Blast.scale(): number
	return attrNum("Feel_BlastScale", 1.4) -- 2026-11-15 pick: "Huge"
end

function Blast.isNew(): boolean
	return Blast.scale() > 0
end

local function camPos(): Vector3
	local c = workspace.CurrentCamera
	return if c then c.CFrame.Position else Vector3.zero
end

local function smooth(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

local function easeOut(u: number): number
	u = math.clamp(u, 0, 1)
	return 1 - (1 - u) * (1 - u)
end

-- overshoot ease (Back out), 0..1 -> 0..~1.1..1
local function backOut(u: number): number
	u = math.clamp(u, 0, 1)
	local s = 1.7
	local v = u - 1
	return v * v * ((s + 1) * v + s) + 1
end

-- CFrame at p whose +Y axis is n
local function upCF(p: Vector3, n: Vector3): CFrame
	local ref = if math.abs(n.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local x = ref:Cross(n).Unit
	local z = x:Cross(n)
	return CFrame.fromMatrix(p, x, n, z)
end

local folder: Folder

local function newPart(shape: Enum.PartType, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Shape = shape
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Transparency = 1
	p.CFrame = PARK
	p.Parent = folder
	return p
end

-- animation list: one Heartbeat walks it --------------------------------------------------------------------------
type Anim = { t0: number, life: number, fn: (number, number) -> (), done: (() -> ())? }
local anims: { Anim } = {}

local function animate(life: number, fn: (number, number) -> (), done: (() -> ())?)
	table.insert(anims, { t0 = os.clock(), life = life, fn = fn, done = done })
end

-- ball pool -------------------------------------------------------------------------------------------------------
local freeBalls: { Part } = {}
local liveBalls = 0

local function getBall(material: Enum.Material): Part?
	if liveBalls >= BALL_CAP then
		return nil
	end
	local b = table.remove(freeBalls) or newPart(Enum.PartType.Ball, material)
	b.Material = material
	liveBalls += 1
	return b
end

local function putBall(b: Part)
	b.Transparency = 1
	b.CFrame = PARK
	liveBalls -= 1
	table.insert(freeBalls, b)
end

-- one ball: grows to `peak` (diameter) by tPeak with overshoot, then goes to `endSize` while colour / transparency run
-- through the given keys and it rises `rise` studs over its life
local function ball(material: Enum.Material, at: Vector3, s0: number, peak: number, endSize: number, tPeak: number, life: number,
	c0: Color3, c1: Color3, tr0: number, tr1: number, rise: number, delay: number?, drift: Vector3?)
	local b = getBall(material)
	if not b then
		return
	end
	local d = delay or 0
	b.Color = c0
	b.Size = Vector3.one * math.max(s0, 0.05)
	animate(life + d, function(age)
		local t = age - d
		if t < 0 then
			return
		end
		local s
		if t < tPeak then
			s = s0 + (peak - s0) * backOut(t / tPeak)
		else
			s = peak + (endSize - peak) * smooth((t - tPeak) / math.max(life - tPeak, 0.01))
		end
		local u = t / life
		b.Size = Vector3.one * math.max(s, 0.05)
		local e = easeOut(u)
		b.CFrame = CFrame.new(at + V3(0, rise * e, 0) + (if drift then drift * e else Vector3.zero))
		b.Color = c0:Lerp(c1, smooth(u * 1.4))
		b.Transparency = tr0 + (tr1 - tr0) * smooth(u)
	end, function()
		putBall(b)
	end)
end

-- lights ------------------------------------------------------------------------------------------------------------
local lights: { { part: Part, light: PointLight, busy: boolean } } = {}

local function lightPop(at: Vector3, color: Color3, range: number, bright: number, dur: number)
	local slot = nil
	for _, l in lights do
		if not l.busy then
			slot = l
			break
		end
	end
	if not slot then
		if #lights >= LIGHT_CAP then
			return
		end
		local part = newPart(Enum.PartType.Block, Enum.Material.SmoothPlastic)
		part.Size = Vector3.one * 0.2
		local light = Instance.new("PointLight")
		light.Shadows = false
		light.Brightness = 0
		light.Parent = part
		slot = { part = part, light = light, busy = false }
		table.insert(lights, slot)
	end
	local s = slot :: any
	s.busy = true
	s.part.CFrame = CFrame.new(at + V3(0, 2.5, 0))
	s.light.Color = color
	s.light.Range = math.clamp(range, 12, 70)
	animate(dur, function(age)
		local u = age / dur
		-- sharp bright hold across Beat 1 (0-80 ms), then smooth quadratic decay
		local k = if u < 0.22 then 1 else ((1 - u) / 0.78) ^ 1.7
		s.light.Brightness = bright * math.clamp(k, 0, 1)
	end, function()
		s.light.Brightness = 0
		s.part.CFrame = PARK
		s.busy = false
	end)
end

-- shockwave ring (segmented) -----------------------------------------------------------------------------------------
local rings: { { segs: { Part }, busy: boolean } } = {}

local function ringAt(cf: CFrame, r: number, color: Color3, dur: number)
	local slot = nil
	for _, rg in rings do
		if not rg.busy then
			slot = rg
			break
		end
	end
	if not slot then
		if #rings >= RING_CAP then
			return
		end
		local segs = {}
		for i = 1, RING_SEGS do
			segs[i] = newPart(Enum.PartType.Block, Enum.Material.Neon)
		end
		slot = { segs = segs, busy = false }
		table.insert(rings, slot)
	end
	local s = slot :: any
	s.busy = true
	for _, seg in s.segs do
		seg.Color = color
	end
	local r0 = math.max(r * 0.15, 0.8)
	animate(dur, function(age)
		local u = easeOut(age / dur)
		local rr = r0 + (r - r0) * u
		local len = 2 * math.pi * rr / RING_SEGS * 1.08
		local th = math.max(0.15, 0.9 * (1 - u) + 0.15)
		local tr = 0.15 + 0.85 * u * u
		for i, seg in s.segs do
			local a = (i / RING_SEGS) * math.pi * 2
			seg.Size = V3(len, th * 0.6, th)
			seg.Transparency = tr
			seg.CFrame = cf * CFrame.Angles(0, a, 0) * CFrame.new(0, 0.25, -rr)
		end
	end, function()
		for _, seg in s.segs do
			seg.Transparency = 1
			seg.CFrame = PARK
		end
		s.busy = false
	end)
end

-- scorch discs (FIFO) -------------------------------------------------------------------------------------------------
local scorches: { { part: Part, born: number, base: number } } = {}
local scorchIdx = 0

local function scorchAt(pos: Vector3, n: Vector3, diameter: number)
	scorchIdx = scorchIdx % SCORCH_CAP + 1
	local s = scorches[scorchIdx]
	if not s then
		local part = newPart(Enum.PartType.Cylinder, Enum.Material.SmoothPlastic)
		part.Color = C3(22, 19, 17)
		s = { part = part, born = 0, base = 0.12 }
		scorches[scorchIdx] = s
	end
	-- slight per-slot height offset so overlapping discs do not z-fight
	local lift = 0.05 + (scorchIdx % 5) * 0.012
	s.part.Size = V3(0.08, diameter, diameter)
	s.part.CFrame = upCF(pos + n * lift, n) * VERT * CFrame.Angles(rnd(0, 6.28), 0, 0)
	s.part.Transparency = s.base
	s.born = os.clock()
end

local function stepScorches(now: number)
	for _, s in scorches do
		if s.born > 0 then
			local age = now - s.born
			if age > SCORCH_HOLD then
				local u = (age - SCORCH_HOLD) / SCORCH_FADE
				if u >= 1 then
					s.part.Transparency = 1
					s.part.CFrame = PARK
					s.born = 0
				else
					s.part.Transparency = s.base + (1 - s.base) * u
				end
			end
		end
	end
end

-- emitter pools: sparks, embers, smoke columns -------------------------------------------------------------------------
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

local sparkEm: { ParticleEmitter } = {}
local emberEm: { ParticleEmitter } = {}
local sandEm: { ParticleEmitter } = {}
local dustRingEm: { ParticleEmitter } = {}
local emberRingEm: { ParticleEmitter } = {}
local sparkIdx, emberIdx, sandIdx, dustRingIdx, emberRingIdx = 0, 0, 0, 0, 0

local function buildBurstEmitters()
	for i = 1, 3 do
		local part = newPart(Enum.PartType.Block, Enum.Material.SmoothPlastic)
		part.Size = Vector3.one
		local em = Instance.new("ParticleEmitter")
		em.Enabled = false
		em.Rate = 0
		em.Texture = TEX_SPARK
		em.LightEmission = 1
		em.LightInfluence = 0
		em.Lifetime = NumberRange.new(0.3, 0.75)
		em.Speed = NumberRange.new(28, 70)
		em.SpreadAngle = Vector2.new(180, 180)
		em.Acceleration = V3(0, -70, 0)
		em.Drag = 2.5
		em.Transparency = seq(0, 1)
		em.Parent = part
		sparkEm[i] = em
	end
	for i = 1, 3 do
		local part = newPart(Enum.PartType.Block, Enum.Material.SmoothPlastic)
		part.Size = Vector3.one
		local em = Instance.new("ParticleEmitter")
		em.Enabled = false
		em.Rate = 0
		em.Texture = TEX_SPARK
		em.LightEmission = 1
		em.LightInfluence = 0
		em.Lifetime = NumberRange.new(1.4, 3.0)
		em.Speed = NumberRange.new(6, 20)
		em.SpreadAngle = Vector2.new(70, 70)
		em.EmissionDirection = Enum.NormalId.Top
		em.Acceleration = V3(1.5, 5, 0.8)
		em.Drag = 1.6
		em.Transparency = seqT({ { 0, 0 }, { 0.7, 0.2 }, { 1, 1 } })
		em.Parent = part
		emberEm[i] = em
	end
	-- Beat 2 tan sand eruption plume emitter pool (phone-safe)
	for i = 1, 3 do
		local part = newPart(Enum.PartType.Block, Enum.Material.SmoothPlastic)
		part.Size = Vector3.one
		local em = Instance.new("ParticleEmitter")
		em.Enabled = false
		em.Rate = 0
		em.Texture = TEX_SMOKE
		em.LightEmission = 0
		em.LightInfluence = 0.65
		em.Color = ColorSequence.new(SAND_BASE, SAND_EDGE)
		em.EmissionDirection = Enum.NormalId.Top
		em.SpreadAngle = Vector2.new(44, 44)
		em.Rotation = NumberRange.new(0, 360)
		em.RotSpeed = NumberRange.new(-55, 55)
		em.Drag = 1.8
		em.Acceleration = V3(0, -10, 0)
		em.Transparency = seqT({ { 0, 0.16 }, { 0.55, 0.42 }, { 1, 1 } })
		em.Parent = part
		sandEm[i] = em
	end
	-- Horizontal ground dust + ember shockwave ring emitters (radial blast sweep along the deck)
	for i = 1, 3 do
		local part = newPart(Enum.PartType.Block, Enum.Material.SmoothPlastic)
		part.Size = Vector3.one
		local em = Instance.new("ParticleEmitter")
		em.Enabled = false
		em.Rate = 0
		em.Texture = TEX_SMOKE
		em.LightEmission = 0
		em.LightInfluence = 0.65
		em.Color = ColorSequence.new(SAND_BASE, SAND_EDGE)
		em.EmissionDirection = Enum.NormalId.Top
		em.SpreadAngle = Vector2.new(84, 84)
		em.Rotation = NumberRange.new(0, 360)
		em.RotSpeed = NumberRange.new(-90, 90)
		em.Drag = 3.2
		em.Acceleration = V3(0, 1.5, 0)
		em.Transparency = seqT({ { 0, 0.14 }, { 0.5, 0.45 }, { 1, 1 } })
		em.Parent = part
		dustRingEm[i] = em
	end
	for i = 1, 3 do
		local part = newPart(Enum.PartType.Block, Enum.Material.SmoothPlastic)
		part.Size = Vector3.one
		local em = Instance.new("ParticleEmitter")
		em.Enabled = false
		em.Rate = 0
		em.Texture = TEX_SPARK
		em.LightEmission = 1
		em.LightInfluence = 0
		em.EmissionDirection = Enum.NormalId.Top
		em.SpreadAngle = Vector2.new(84, 84)
		em.Drag = 2.6
		em.Acceleration = V3(0, -14, 0)
		em.Transparency = seqT({ { 0, 0 }, { 0.65, 0.25 }, { 1, 1 } })
		em.Parent = part
		emberRingEm[i] = em
	end
end

local function groundShockRingAt(at: Vector3, n: Vector3, K: number, sparkCol: Color3)
	if #dustRingEm > 0 then
		dustRingIdx = dustRingIdx % #dustRingEm + 1
		local em = dustRingEm[dustRingIdx]
		local part = em.Parent :: Part
		part.CFrame = upCF(at + n * 0.5, n)
		local sz = math.clamp(1.6 + 1.45 * K, 1.8, 7.5)
		em.Size = seqT({ { 0, sz * 0.55 }, { 0.45, sz * 1.25 }, { 1, sz * 1.9 } })
		em.Lifetime = NumberRange.new(0.45 + 0.12 * K, 0.85 + 0.22 * K)
		em.Speed = NumberRange.new(26 + 12 * K, 48 + 20 * K)
		em:Emit(q(12 + 8 * K))
	end
	if #emberRingEm > 0 then
		emberRingIdx = emberRingIdx % #emberRingEm + 1
		local em = emberRingEm[emberRingIdx]
		local part = em.Parent :: Part
		part.CFrame = upCF(at + n * 0.6, n)
		em.Color = ColorSequence.new(FLASH_WHITE_GOLD, sparkCol)
		local sz = math.clamp(0.24 + 0.1 * K, 0.24, 0.65)
		em.Size = seq(sz, sz * 0.2)
		em.Lifetime = NumberRange.new(0.35, 0.75)
		em.Speed = NumberRange.new(32 + 14 * K, 62 + 22 * K)
		em:Emit(q(10 + 8 * K))
	end
end

local function sandPlumeAt(at: Vector3, K: number)
	if #sandEm == 0 then
		return
	end
	sandIdx = sandIdx % #sandEm + 1
	local em = sandEm[sandIdx]
	local part = em.Parent :: Part
	part.CFrame = CFrame.new(at + V3(0, 0.4, 0))
	local sz = math.clamp(2.2 * K, 1.8, 9.5)
	em.Size = seqT({ { 0, sz * 0.6 }, { 0.45, sz * 1.45 }, { 1, sz * 2.1 } })
	em.Lifetime = NumberRange.new(0.8 + 0.25 * K, 1.4 + 0.4 * K)
	em.Speed = NumberRange.new(18 + 9 * K, 34 + 14 * K)
	em:Emit(q(8 + 6 * K))
end

local function sparksAt(at: Vector3, K: number, color: Color3)
	sparkIdx = sparkIdx % #sparkEm + 1
	local em = sparkEm[sparkIdx]
	local part = em.Parent :: Part
	part.CFrame = CFrame.new(at + V3(0, 0.6, 0))
	em.Color = ColorSequence.new(C3(255, 255, 235), color)
	local sz = math.clamp(0.25 + 0.15 * K, 0.25, 0.9)
	em.Size = seq(sz, sz * 0.4)
	em.Speed = NumberRange.new(22 + 6 * K, 50 + 18 * K)
	em:Emit(q(10 + 10 * K))
end

local function embersAt(at: Vector3, K: number, color: Color3)
	emberIdx = emberIdx % #emberEm + 1
	local em = emberEm[emberIdx]
	local part = em.Parent :: Part
	part.CFrame = CFrame.new(at + V3(0, 1, 0))
	em.Color = ColorSequence.new(color, C3(255, 90, 30))
	local sz = math.clamp(0.18 + 0.08 * K, 0.18, 0.5)
	em.Size = seq(sz, sz * 0.5)
	em.Speed = NumberRange.new(5 + 2 * K, 14 + 5 * K)
	em:Emit(q(5 + 6 * K))
end

-- Beat 4: tall dense dark-charcoal smoke columns (#1F1B18 -> #4A433C, LightInfluence = 0.4) lasting 3-4.5 s as landmarks
type Column = { part: Part, em: ParticleEmitter, untilT: number, pos: Vector3, busyUntil: number }
local columns: { Column } = {}

local function columnAt(at: Vector3, K: number, color: Color3)
	local now = os.clock()
	local life = math.clamp(2.8 + 1.1 * K, 3.0, 5.2)
	local lifetime = math.clamp(3.0 + 0.65 * K, 3.2, 4.6)
	-- a column already burning close by just burns longer (cluster / barrage do not spawn 30 columns)
	for _, c in columns do
		if c.untilT > now and (c.pos - at).Magnitude < 4 + 2 * K then
			c.untilT = math.max(c.untilT, now + life)
			c.busyUntil = c.untilT + lifetime
			return
		end
	end
	local slot: Column? = nil
	for _, c in columns do
		if c.busyUntil <= now then
			slot = c
			break
		end
	end
	if not slot then
		if #columns >= COLUMN_CAP then
			return
		end
		local part = newPart(Enum.PartType.Block, Enum.Material.SmoothPlastic)
		part.Size = Vector3.one
		local em = Instance.new("ParticleEmitter")
		em.Enabled = false
		em.Texture = TEX_SMOKE
		em.LightEmission = 0
		em.LightInfluence = 0.4 -- dense dark silhouette against bright desert sky
		em.EmissionDirection = Enum.NormalId.Top
		em.SpreadAngle = Vector2.new(8, 8)
		em.Rotation = NumberRange.new(0, 360)
		em.RotSpeed = NumberRange.new(-22, 22)
		em.Drag = 0.45
		em.Parent = part
		slot = { part = part, em = em, untilT = 0, pos = at, busyUntil = 0 }
		table.insert(columns, slot :: Column)
	end
	local c = slot :: Column
	c.pos = at
	c.untilT = now + life
	c.busyUntil = c.untilT + lifetime
	c.part.CFrame = CFrame.new(at + V3(0, 0.8 + K * 0.8, 0))
	local w = math.clamp(2.6 * K, 2.2, 11)
	c.em.Size = seqT({ { 0, w * 0.75 }, { 0.35, w * 1.45 }, { 1, w * 2.6 } })
	c.em.Transparency = seqT({ { 0, 0.14 }, { 0.5, 0.34 }, { 0.82, 0.68 }, { 1, 1 } })
	c.em.Color = ColorSequence.new(color, SOOT_TOP)
	c.em.Lifetime = NumberRange.new(lifetime * 0.82, lifetime)
	c.em.Speed = NumberRange.new(10 + 3.5 * K, 16 + 5.5 * K)
	c.em.Acceleration = V3(2.0, 4.8, 1.0) -- climbs high with subtle wind lean
	c.em.Rate = math.min(q(7 + 3.5 * K), 22)
	c.em.Enabled = true
end

local function stepColumns(now: number)
	for _, c in columns do
		if c.em.Enabled and now >= c.untilT then
			c.em.Enabled = false
		end
	end
end

-- sounds (same mapping as the old Fx.explosion) -------------------------------------------------------------------------
local function playSound(size: string, style: string, p: Vector3, K: number)
	local key, vol, pitch = "Explosion", 1, 1
	if style == "emp" then
		key = "EMP"
	elseif style == "ice" then
		key, pitch = "EMP", 1.3
	elseif style == "void" then
		key, pitch = "ExplosionHuge", 0.75
	elseif style == "rail" then
		key, pitch = "Explosion", 1.15
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
	if key == "Explosion" and K >= 1.4 and size ~= "XL" then
		pitch *= 0.92 -- bigger call-in bombs sit a little lower than a grenade
	end
	pcall(Audio.play, key, p, { pitch = pitch, volume = vol, priority = 5 })
end

-- the effect ---------------------------------------------------------------------------------------------------------
local SIZE_K = { S = 0.55, M = 1, L = 1.6, XL = 3.2 }

local function kFor(opts: any): number
	if type(opts.k) == "number" and opts.k > 0 then
		return opts.k
	end
	if type(opts.r) == "number" and opts.r > 0 then
		return math.clamp(opts.r / 8.5, 0.3, 3.6)
	end
	return SIZE_K[opts.size] or 1
end

local lastPunch = 0
local function camera(p: Vector3, K: number, R: number, st: any, opts: any)
	if opts.noShake then
		return
	end
	local mult = attrNum("Feel_BlastShake", 2.6) * (opts.sh or 1) -- 2026-11-15: "much stronger than x1.6"
	if mult <= 0 then
		return
	end
	local d = (camPos() - p).Magnitude
	local range = opts.shr or (55 + 35 * K)
	-- shake: ~1/distance trauma, strong 100 ms initial snap + low-frequency rumble settle
	Juice.trauma(1.65 * K ^ 0.82 * mult, 0.38 + 0.25 * K, p, range)
	-- FOV shock-punch (+3-5 deg snap-back over ~0.25 s) + warm exposure/contrast blast flash on nearby heavy impacts (<= 55 studs)
	local nearRange = math.max(55, R * 2.5 + 20)
	local near = math.clamp(1 - d / nearRange, 0, 1)
	local shockNear = math.clamp(1 - d / 55, 0, 1)
	local now = os.clock()
	if near > 0 and (now - lastPunch > 0.12 or K >= 2.2) then
		lastPunch = now
		local fovKick = if shockNear > 0 and K >= 1.0
			then math.clamp((3.0 + 1.5 * K) * shockNear, 1.2, 5.4)
			else math.clamp((1.4 + 1.6 * K) * near * mult * 0.65, 0.4, 4.5)
		Juice.punchFov(fovKick)
		if shockNear > 0 and K >= 0.95 then
			-- brief 0.12 s warm exposure/contrast blast flash on ColorCorrection + subtle screen edge
			Juice.colorPunch(st.hot, math.clamp((0.45 + 0.22 * K) * shockNear, 0.2, 1.05), 0.12, 0.22)
			Juice.flash(st.core:Lerp(st.hot, 0.25), math.clamp((0.2 + 0.1 * K) * shockNear, 0.08, 0.48), 0.12)
		elseif d < R * 1.6 + 8 then
			Juice.flash(st.core, math.clamp((0.18 + 0.12 * K) * near, 0, 0.55), 0.18 + 0.06 * K)
		end
		if K >= 2.5 and d < R * 1.3 then
			Juice.hitstop(0.05)
		end
	end
	if K >= 2.5 then
		Juice.flashAt(st.core, 0.5, 0.35, p, 700)
	end
end

function Blast.play(p: Vector3, opts: any?)
	opts = opts or {}
	local scale = Blast.scale()
	if scale <= 0 and legacyExplosion then
		-- "Current": the old effect plus the separate sends the old call-ins made
		legacyExplosion(p, { size = opts.size, r = opts.r, style = opts.style, silent = opts.silent, noShake = opts.noShake })
		if type(opts.sk) == "number" and opts.sk > 0 then
			Juice.shake(opts.sk, 0.25 + opts.sk * 0.15, p, opts.skr)
		end
		if type(opts.sw) == "number" then
			Fx.shockwave(p, opts.sw)
		end
		if type(opts.cr) == "number" then
			Fx.handle("Crater", { p = p, r = opts.cr })
		end
		return
	end
	local size = if SIZE_K[opts.size] then opts.size else "M"
	local style = if STYLES[opts.style] then opts.style else "fire"
	local st = STYLES[style]
	local K = kFor(opts) * math.max(scale, 0.1)
	local R = opts.r or (8.5 * K)
	local d = (camPos() - p).Magnitude

	if not opts.silent then
		playSound(size, style, p, K)
		-- Beat 6: -7 dB bus ducking + 40 ms crack transient + lingering low-end boom tail on major blasts
		local isMajor = size == "L" or size == "XL" or K >= 1.4 or opts.cookoff == true
		if isMajor and Audio and Audio.blastPunch then
			pcall(Audio.blastPunch, p, math.clamp(K * 0.65, 0.8, 2.0))
		end
	end
	camera(p, K, R, st, opts)
	if d > 900 then
		return
	end

	local gpos, gn = Fx.groundAt(p, 3, 10 + 2 * K)
	local g = gpos or p
	local n = gn or Vector3.yAxis
	local FR = 4.4 * K -- fireball diameter unit
	local isFire = style == "fire" or style == "spark" or style == "rail"
	local soft = style == "gas" or style == "goo"
	local mid = p + V3(0, FR * 0.25, 0)
	local majorBlast = K >= 1.8 or size == "XL" or opts.cookoff == true

	-- Beat 1 (0-80 ms): blinding white-gold flash (#FFFBE0) + transient bounce PointLight (#FF8C1A, Range 70 / Brightness 8 on major blasts)
	ball(Enum.Material.Neon, mid, FR * 0.35, FR * 2.15, FR * 2.8, 0.045, 0.095, FLASH_WHITE_GOLD, st.core, 0, 1, 0)
	if d < 520 and (Fx.quality >= 0.6 or K >= 1.1 or majorBlast) then
		local lRange = if majorBlast then 70 else math.clamp(24 + 22 * K, 24, 68)
		local lBright = if majorBlast then 8 else math.clamp(3.8 + 2.2 * K, 3.8, 8)
		lightPop(mid, st.light, lRange, lBright, 0.34 + 0.14 * K)
	end

	-- Beat 2 (100-450 ms): multi-lobed orange-amber fireball (#FF7A18 -> #D9380E) expanding upward faster than outward + tan sand eruption plume
	local fireTr = if soft then 0.35 else 0
	ball(Enum.Material.Neon, mid, FR * 0.42, FR * 1.25, FR * 0.25, 0.08, 0.36, st.core, st.hot, fireTr, 1, FR * 0.55)
	local nMid = if K >= 1.6 then q(6) elseif K >= 1.0 then q(4) else q(3)
	for i = 1, nMid do
		local ang = (i - 1) / math.max(nMid, 1) * math.pi * 2 + rnd(-0.3, 0.3)
		local horiz = V3(math.cos(ang), 0, math.sin(ang))
		local off = horiz * FR * rnd(0.18, 0.34) + V3(0, rnd(0.05, 0.65) * FR, 0)
		-- rises ~2.5x faster upward than outward drift
		ball(Enum.Material.Neon, mid + off, FR * 0.38, FR * rnd(1.3, 1.7), FR * 0.6, rnd(0.10, 0.16), rnd(0.36, 0.48) + 0.08 * K,
			st.mid, st.edge, fireTr, 1, FR * rnd(0.95, 1.45), 0.02 + (i - 1) * 0.015, horiz * FR * 0.28)
	end
	ball(Enum.Material.Neon, mid, FR * 0.6, FR * 2.1, FR * 1.65, 0.14, 0.36 + 0.08 * K, st.mid, st.edge, 0.4 + fireTr * 0.4, 1, FR * 0.7, 0.03)
	if gpos and isFire and d < 520 then
		sandPlumeAt(g, K)
	end

	-- smoke balls: start inside the fireball as it shrinks, grow, rise, fade
	if style ~= "emp" and style ~= "ice" and d < 600 then
		local nSmoke = q(if K >= 2 then 5 elseif K >= 1 then 4 else 2)
		local smokeLife = 1.6 + 0.55 * K
		for i = 1, nSmoke do
			local off = V3(rnd(-1, 1), rnd(0, 0.9), rnd(-1, 1)) * FR * 0.42
			ball(Enum.Material.SmoothPlastic, mid + off, FR * 0.65, FR * rnd(1.25, 1.55), FR * rnd(2.0, 2.5), 0.48, smokeLife * rnd(0.85, 1.15),
				st.smoke:Lerp(st.edge, 0.22), SOOT_TOP, 0.12, 1, FR * (1.2 + 0.45 * K), 0.16 + 0.03 * i)
		end
	end

	-- mushroom cloud (2026-11-15 playtest: "keep the ball, add more mushroom cloud"): a stem of smoke balls racing up
	-- from the ground, a cap ball on top and a ring of balls rolling outward under it. Fire blasts from K 1.2 (a frag at
	-- the Huge scale) up; one per 0.3 s so cluster drops / barrages do not stack 30 of them.
	-- Studio A/B Feel_Mushroom: nil = on, "big" = cap x1.35, "off".
	local mushroom = if IS_STUDIO then workspace:GetAttribute("Feel_Mushroom") else nil
	local now = os.clock()
	if style == "fire" and K >= 1.2 and d < 700 and mushroom ~= "off" and now - lastMushroom > 0.3 then
		lastMushroom = now
		local capK = if mushroom == "big" then 1.35 else 1
		local capH = FR * (1.5 + 0.22 * K)
		local life = 2.4 + 0.6 * K
		local lit, dark = st.mid:Lerp(st.edge, 0.45), SOOT_BASE:Lerp(SOOT_TOP, 0.4)
		local nStem = q(4)
		for i = 1, nStem do
			local h = capH * (i - 0.5) / nStem
			ball(Enum.Material.SmoothPlastic, g + V3(0, h * 0.4, 0), FR * 0.3, FR * 0.6, FR * 0.85, 0.25, life * 0.8,
				lit, dark, 0.05, 1, h * 0.65 + FR * 0.35, 0.04 * i)
		end
		ball(Enum.Material.SmoothPlastic, g + V3(0, capH * 0.6, 0), FR * 0.5 * capK, FR * 1.55 * capK, FR * 1.95 * capK, 0.35, life,
			st.hot:Lerp(st.edge, 0.38), dark, 0.05, 1, capH * 0.45 + FR * 0.75, 0.1)
		local nRing = q(7)
		local a0 = rnd(0, math.pi * 2)
		for i = 1, nRing do
			local a = a0 + (i - 1) / nRing * math.pi * 2
			local dir = V3(math.cos(a), 0, math.sin(a))
			ball(Enum.Material.SmoothPlastic, g + V3(0, capH * 0.5, 0) + dir * FR * 0.4, FR * 0.4 * capK, FR * 1.0 * capK,
				FR * 1.4 * capK, 0.3, life * rnd(0.85, 1.05), lit, dark, 0.05, 1, capH * 0.45 + FR * 0.45, 0.14 + 0.01 * i,
				dir * FR * 1.1 * capK)
		end
	end

	-- sparks + embers
	if d < 500 then
		sparksAt(mid, K, st.spark)
		if isFire and K >= 0.7 then
			embersAt(mid, K, st.hot)
		end
	end

	-- Beat 3 (150-900 ms): 8-12 dark opaque radial shrapnel chunks arcing cleanly against the bright sky
	if d < 450 and style ~= "gas" and K >= 0.45 then
		local chunkN = math.clamp(math.floor(7 + 2.5 * K + 0.5), 8, 12)
		pcall(Fx.debris, g + n * 0.7, {
			n = chunkN,
			style = if style == "goo" then "goo" else "shrapnel",
			color = if style == "goo" then st.mid else nil,
			speed = 34 + 13 * K,
			up = 1.75,
			scale = math.clamp(0.75 + 0.28 * K, 0.75, 1.75),
			life = 1.15,
		})
	end

	-- ground: shockwave ring + horizontal ground dust/ember blast ring + dust kick-up
	if gpos and d < 600 then
		local ringR = math.clamp(math.max(R * 0.9, 2 + 3.4 * K), 3, 42)
		ringAt(upCF(g, n), ringR, st.core:Lerp(st.hot, 0.35), 0.38 + 0.08 * K)
		if d < 420 and K >= 0.65 then
			groundShockRingAt(g, n, K, st.spark)
		end
		if Spectacle and Spectacle.blastDust then
			pcall(Spectacle.blastDust, g, K)
		end
	end

	-- Beat 4 (3-4.5 s): tall dense dark-charcoal smoke column landmark (fire only) and scorch
	if style == "fire" and K >= 0.6 then
		columnAt(g, K, SOOT_BASE)
	end
	if gpos and n.Y >= 0.55 and isFire and K >= 0.45 then
		scorchAt(g, n, math.clamp(R * 1.1, 2.5, 46))
	elseif gpos and style == "goo" then
		pcall(Fx.splat, g, math.clamp(R * 0.6, 2, 14), st.mid, 8)
	end
end

local function step()
	local now = os.clock()
	local i = 1
	while i <= #anims do
		local a = anims[i]
		local age = now - a.t0
		if age >= a.life then
			pcall(a.fn, a.life, 1)
			if a.done then
				pcall(a.done)
			end
			anims[i] = anims[#anims]
			anims[#anims] = nil
		else
			local ok, err = pcall(a.fn, age, age / a.life)
			if not ok then
				warn("[Blast] anim failed: " .. tostring(err))
				a.t0 = -1e9 -- finish it next frame
			end
			i += 1
		end
	end
	stepScorches(now)
	stepColumns(now)
end

function Blast.init(fx: any, audio: any, juice: any)
	Fx, Audio, Juice = fx, audio, juice
	folder = Instance.new("Folder")
	folder.Name = "Blast"
	folder.Parent = Fx.folder
	local okS, mod = pcall(require, script.Parent:FindFirstChild("Spectacle"))
	if okS and type(mod) == "table" then
		Spectacle = mod
	end
	buildBurstEmitters()

	-- every explosion goes through Blast.play (the old function stays reachable for the "Current" A/B preset)
	legacyExplosion = Fx.explosion
	Fx.explosionLegacy = legacyExplosion
	Fx.blastIsNew = Blast.isNew -- Spectacle: the new look does its own camera work, skip the orbital's
	Fx.blastScale = Blast.scale
	BALL_CAP = math.floor(40 + 70 * (Fx.quality or 1))
	Fx.explosion = function(p: Vector3, opts: any?)
		Blast.play(p, opts)
	end
	Fx.register("Blast", function(d)
		if typeof(d) == "table" and typeof(d.p) == "Vector3" then
			Blast.play(d.p, d)
		end
	end)
	RunService.Heartbeat:Connect(step)
end

return Blast
