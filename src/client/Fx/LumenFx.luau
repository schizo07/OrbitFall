--!nonstrict
-- Lumen Concord client effects. Server senders: server/Enemies/LumenAI.luau (attacks), EnemyService (Death),
-- Fx/Spectacle.luau (breach-source rifts, local). Cartoony crystal-and-light, no gore, no scorch marks.
--   LumenCharge {p, t, s, id}   violet glow growing at p for t s (s = size); a new charge with the same id replaces it
--   LumenBeam   {a, b, w, t}    hard-light beam a -> b (w = width), quick warm-up then fades over t; light flash at b
--   LumenPulse  {p, r}          ground ring + light shell expanding to exactly the damage radius r
--   Blink       {a, b, s}       Warden teleport: shard burst + implode at a, shards fold in at b (s = unit size)
--   RiftGate    {p, r, t}       vertical crystal rift standing on the ground at p (r = radius), open for t s
--   Death       {style = "shard", p, size, fodder?, dir?, blast?}   body shatters into crystal shards + a soft light pop
--                (Fx/init.luau skips its scrap burst for style "shard"; EnemyAnim still breaks up the model itself)
-- Public: Fx.lumenShatter(p, f) (Spectacle: destroyed rift shard).
-- Planet mood, biome "crystal" (workspace.Map attribute Biome, or mission faction LUMEN when unset): slow aurora
-- ribbons in the sky with an occasional bright shimmer. Motes live in Fx/Ambience.luau, the colour grade in Fx/Weather.luau.
-- All parts come from one pool and one Heartbeat loop. Counts scale with Fx.quality (phones 0.5).
-- Studio A/B (client/Variants.luau, group LUMEN FX): Feel_LumenFx nil = default | "big" (bigger, brighter) | "min"
-- (fewer parts, no lights, no aurora).

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LumenFx = {}

local Fx: any
local Audio: any
local Store: any = nil
local rng = Random.new()

local C3 = Color3.fromRGB
local VIOLET = C3(192, 96, 255)
local LILAC = C3(222, 180, 255)
local HOT = C3(248, 238, 255)
local CYAN = C3(150, 220, 255)
local CERAMIC = C3(232, 226, 238)
local DARK = C3(22, 10, 38)
local NEON = Enum.Material.Neon
local SMOOTH = Enum.Material.SmoothPlastic
local BALL = Enum.PartType.Ball
local BLOCK = Enum.PartType.Block
local CYL = Enum.PartType.Cylinder
local FLAT = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (X) pointing up: a flat disc

local function rnd(a: number, b: number): number
	return a + (b - a) * rng:NextNumber()
end

local function randUnit(): Vector3
	local v = Vector3.new(rnd(-1, 1), rnd(-1, 1), rnd(-1, 1))
	return if v.Magnitude > 0.05 then v.Unit else Vector3.yAxis
end

local function isPos(v: any): boolean
	return typeof(v) == "Vector3"
end

-- Feel ----------------------------------------------------------------------------------------------------------------
local function mode(): string?
	local v = Workspace:GetAttribute("Feel_LumenFx")
	return if v == "big" or v == "min" then v else nil
end

local function sizeK(): number
	return if mode() == "big" then 1.35 else 1
end

local function brightK(): number
	return if mode() == "big" then 1.6 else 1
end

local function count(n: number): number
	local k = (Fx and Fx.quality) or 1
	local m = mode()
	if m == "min" then
		k *= 0.4
	elseif m == "big" then
		k *= 1.3
	end
	return math.max(1, math.floor(n * k + 0.5))
end

local function lightsOn(): boolean
	return ((Fx and Fx.quality) or 1) >= 0.75 and mode() ~= "min"
end

local function camDist(p: Vector3): number
	if Fx and Fx.camDistance then
		return Fx.camDistance(p)
	end
	return 0
end

local function snd(key: string, p: Vector3?, opts: any?)
	if Audio and Audio.play then
		pcall(Audio.play, key, p, opts)
	end
end

local function burst(name: string, at: any, n: number, opts: any?)
	if Fx and Fx.burst then
		pcall(Fx.burst, name, at, n, opts)
	end
end

-- Part pool -------------------------------------------------------------------------------------------------------------
local MAX_LIVE = 200
local FREE_CAP = 80
local live = 0
local free: { [any]: { Part } } = {}
local folder: Folder? = nil

local function getFolder(): Folder
	if folder and folder.Parent == Workspace then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "LumenFxLocal"
	f.Parent = Workspace
	folder = f
	return f
end

local function acquire(shape: Enum.PartType, color: Color3, material: Enum.Material, size: Vector3, cf: CFrame, transp: number): Part?
	if live >= MAX_LIVE then
		return nil
	end
	local f = getFolder()
	local list = free[shape]
	local p = list and table.remove(list)
	if not p then
		p = Instance.new("Part")
		p.Name = "Lumen"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Massless = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Shape = shape
	end
	live += 1
	p.Color = color
	p.Material = material
	p.Size = size
	p.CFrame = cf
	p.Transparency = transp
	p.Parent = f
	return p
end

local function release(p: Part?)
	if not p then
		return
	end
	live -= 1
	-- a part whose folder was destroyed is parent-locked: drop it instead of pooling
	local ok = pcall(function()
		for _, c in p:GetChildren() do
			c:Destroy() -- lights / meshes
		end
		p.Parent = nil
	end)
	if not ok then
		return
	end
	local list = free[p.Shape]
	if not list then
		list = {}
		free[p.Shape] = list
	end
	if #list < FREE_CAP then
		table.insert(list, p)
	else
		p:Destroy()
	end
end

local function addLight(p: Part?, color: Color3, range: number): PointLight?
	if not p or not lightsOn() then
		return nil
	end
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = math.min(range, 60)
	l.Brightness = 0
	l.Shadows = false
	l.Parent = p
	return l
end

-- Animation loop ----------------------------------------------------------------------------------------------------------
type Anim = { parts: { Part }, age: number, step: (any, number) -> boolean, kill: boolean?, onDone: (() -> ())? }
local anims: { Anim } = {}
local conn: RBXScriptConnection? = nil
local warned = false
local HARD_LIFE = 40

local function stepAll(dt: number)
	for i = #anims, 1, -1 do
		local a = anims[i]
		a.age += dt
		local ok, done = pcall(a.step, a, dt)
		if not ok and not warned then
			warned = true
			warn("[LumenFx] anim failed: " .. tostring(done))
		end
		if not ok or done or a.age > HARD_LIFE then
			for _, p in a.parts do
				release(p)
			end
			if a.onDone then
				pcall(a.onDone)
			end
			local n = #anims
			anims[i] = anims[n]
			anims[n] = nil
		end
	end
	if #anims == 0 and conn then
		conn:Disconnect()
		conn = nil
	end
end

local function run(parts: { Part }, step: (any, number) -> boolean): Anim
	local a: Anim = { parts = parts, age = 0, step = step }
	table.insert(anims, a)
	if not conn then
		conn = RunService.Heartbeat:Connect(stepAll)
	end
	return a
end

local function add(list: { Part }, p: Part?): Part?
	if p then
		table.insert(list, p)
	end
	return p
end

-- Shards: hand-simulated, anchored, bounce once on a flat floor, shrink + fade at the end --------------------------------
type Shard = { part: Part, pos: Vector3, vel: Vector3, rot: CFrame, axis: Vector3, spin: number, life: number, size: Vector3, floor: number, t0: number }

local function spawnShards(list: { Part }, out: { Shard }, p: Vector3, n: number, o: any)
	local sz = o.size or 1
	for _ = 1, n do
		local neon = rng:NextNumber() < (o.neonShare or 0.5)
		local col = if neon then (if rng:NextNumber() < 0.6 then VIOLET else LILAC) else CERAMIC
		local size = Vector3.new(0.32, 0.32, 1.05) * sz * rnd(0.7, 1.3)
		local part = add(list, acquire(BLOCK, col, if neon then NEON else SMOOTH, size, CFrame.new(p), 0))
		if part then
			local d = randUnit()
			d = Vector3.new(d.X, math.abs(d.Y) * 0.8 + 0.2, d.Z).Unit
			local v = d * rnd(o.speed * 0.6, o.speed) + Vector3.new(0, o.up or 0, 0)
			if o.dir then
				v = v * 0.6 + o.dir * o.speed * (o.bias or 0.9)
			end
			table.insert(out, {
				part = part,
				pos = p + d * rnd(0, 0.6) * sz,
				vel = v,
				rot = CFrame.Angles(rnd(0, 6.28), rnd(0, 6.28), rnd(0, 6.28)),
				axis = randUnit(),
				spin = rnd(6, 16),
				life = rnd(o.life * 0.75, o.life * 1.25),
				size = size,
				floor = o.floor or (p.Y - 50),
				t0 = o.t0 or 0,
			})
		end
	end
end

local GRAV = Vector3.new(0, -60, 0)

local function stepShards(list: { Shard }, dt: number, age: number)
	for _, s in list do
		local t = age - s.t0
		if t < 0 then
			continue
		end
		if t >= s.life then
			s.part.Transparency = 1
			continue
		end
		s.vel += GRAV * dt
		local pos = s.pos + s.vel * dt
		if pos.Y < s.floor + s.size.Z * 0.3 then
			pos = Vector3.new(pos.X, s.floor + s.size.Z * 0.3, pos.Z)
			s.vel = Vector3.new(s.vel.X * 0.45, math.abs(s.vel.Y) * 0.3, s.vel.Z * 0.45)
			s.spin *= 0.5
		end
		s.pos = pos
		s.rot = s.rot * CFrame.fromAxisAngle(s.axis, s.spin * dt)
		local f = t / s.life
		local fade = math.clamp((f - 0.55) / 0.45, 0, 1)
		s.part.Size = s.size * (1 - fade * 0.7)
		s.part.Transparency = fade
		s.part.CFrame = CFrame.new(pos) * s.rot
	end
end

local function floorAt(p: Vector3, down: number): number
	if Fx and Fx.groundAt then
		local ok, g = pcall(Fx.groundAt, p, 2, down)
		if ok and typeof(g) == "Vector3" then
			return g.Y
		end
	end
	return p.Y - down
end

-- LumenCharge ---------------------------------------------------------------------------------------------------------
local charges: { [any]: Anim } = {}

local function onCharge(d: any)
	if type(d) ~= "table" or not isPos(d.p) then
		return
	end
	local p: Vector3 = d.p
	if camDist(p) > 450 then
		return
	end
	local t = math.clamp(tonumber(d.t) or 1, 0.1, 4)
	local s = math.clamp(tonumber(d.s) or 1.5, 0.3, 8) * sizeK()
	local id = d.id
	if id ~= nil and charges[id] then
		charges[id].kill = true
	end
	local parts: { Part } = {}
	local core = add(parts, acquire(BALL, HOT, NEON, Vector3.one * 0.2, CFrame.new(p), 0))
	local halo = add(parts, acquire(BALL, VIOLET, NEON, Vector3.one * 0.4, CFrame.new(p), 0.7))
	local motes = {}
	if mode() ~= "min" and t >= 0.5 then
		for _ = 1, count(5) do
			local m = add(parts, acquire(BLOCK, LILAC, NEON, Vector3.new(0.16, 0.16, 0.55) * math.sqrt(s), CFrame.new(p), 0.1))
			if m then
				table.insert(motes, { part = m, dir = randUnit(), spin = rnd(2, 5) * (if rng:NextNumber() < 0.5 then 1 else -1) })
			end
		end
	end
	local light = addLight(halo, VIOLET, 6 + 4 * s)
	if t >= 0.8 then
		snd("LanceCharge", p, { volume = 0.4, pitch = rnd(1.5, 1.7), priority = 3 })
	end
	local FLASH = 0.12
	local a = run(parts, function(a: any, _dt: number): boolean
		if a.kill then
			return true
		end
		local age = a.age
		if age >= t + FLASH then
			return true
		end
		local f = math.clamp(age / t, 0, 1)
		local pulse = 1 + 0.12 * math.sin(age * (10 + 22 * f))
		local coreD = s * (0.25 + 0.6 * f) * pulse
		local haloD = s * (0.6 + 1.5 * f) * pulse
		local coreT, haloT = 0, 0.75 - 0.3 * f
		if age > t then
			local g = (age - t) / FLASH
			coreD *= 1 + g
			haloD *= 1 + 0.5 * g
			coreT = g
			haloT = haloT + (1 - haloT) * g
		end
		if core then
			core.Size = Vector3.one * coreD
			core.Transparency = coreT
		end
		if halo then
			halo.Size = Vector3.one * haloD
			halo.Transparency = haloT
		end
		for _, m in motes do
			local r = s * 2.4 * (1 - f) + s * 0.3
			local dir = CFrame.fromAxisAngle(Vector3.yAxis, age * m.spin) * m.dir
			local pos = p + dir * r
			m.part.CFrame = CFrame.lookAt(pos, p)
			m.part.Transparency = if age > t then 1 else 0.1
		end
		if light then
			light.Brightness = 3 * f * brightK() * (if age > t then 1 - (age - t) / FLASH else 1)
			light.Range = math.min((4 + 8 * f) * math.sqrt(s) * sizeK(), 60)
		end
		return false
	end)
	if id ~= nil then
		charges[id] = a
		a.onDone = function()
			if charges[id] == a then
				charges[id] = nil
			end
		end
	end
end

-- LumenBeam -----------------------------------------------------------------------------------------------------------
local function onBeam(d: any)
	if type(d) ~= "table" or not isPos(d.a) or not isPos(d.b) then
		return
	end
	local a0: Vector3, b: Vector3 = d.a, d.b
	local len = (b - a0).Magnitude
	if len < 0.5 then
		return
	end
	local w = math.clamp(tonumber(d.w) or 2, 0.3, 8) * sizeK()
	local fade = math.clamp(tonumber(d.t) or 0.5, 0.15, 2)
	local mid = (a0 + b) / 2
	local axisCF = CFrame.lookAt(mid, b) * CFrame.Angles(0, math.pi / 2, 0) -- cylinder X axis along the beam
	local parts: { Part } = {}
	local core = add(parts, acquire(CYL, HOT, NEON, Vector3.new(len, 0.1, 0.1), axisCF, 0))
	local halo = add(parts, acquire(CYL, VIOLET, NEON, Vector3.new(len, 0.2, 0.2), axisCF, 0.45))
	local flareA = add(parts, acquire(BALL, LILAC, NEON, Vector3.one * w, CFrame.new(a0), 0.2))
	local flareB = add(parts, acquire(BALL, HOT, NEON, Vector3.one * w, CFrame.new(b), 0))
	local gy = floorAt(b, 6)
	local ring = add(parts, acquire(CYL, VIOLET, NEON, Vector3.new(0.12, w, w), CFrame.new(b.X, gy + 0.08, b.Z) * FLAT, 0.35))
	local light = addLight(flareB, LILAC, 18 + 6 * w)
	burst("zap", b, count(12), { color = VIOLET, scale = 1.2 * sizeK() })
	if mode() ~= "min" then
		burst("zap", CFrame.lookAt(a0, b), count(6), { color = LILAC, speed = 1.6, spread = 20 })
	end
	snd("ShotRail", a0, { volume = 0.9, pitch = 0.75, priority = 4 })
	snd("EMP", b, { volume = 0.35, pitch = 1.6, priority = 3 })
	local WARM, HOLD = 0.06, 0.1
	run(parts, function(a: any, _dt: number): boolean
		local age = a.age
		if age >= WARM + HOLD + fade then
			return true
		end
		local k -- width factor
		local tr = 0
		if age < WARM then
			k = 0.2 + 0.8 * (age / WARM)
		elseif age < WARM + HOLD then
			k = 1 + 0.08 * math.sin(age * 90)
		else
			local f = (age - WARM - HOLD) / fade
			k = 1 - f
			tr = f
		end
		if core then
			core.Size = Vector3.new(len, w * 0.32 * k, w * 0.32 * k)
			core.Transparency = tr
		end
		if halo then
			halo.Size = Vector3.new(len, w * k, w * k)
			halo.Transparency = 0.45 + 0.55 * tr + 0.05 * math.sin(age * 70)
		end
		if flareA then
			flareA.Size = Vector3.one * w * (0.8 + 0.6 * k)
			flareA.Transparency = 0.2 + 0.8 * tr
		end
		if flareB then
			flareB.Size = Vector3.one * w * (1.2 + 1.4 * math.min(age / 0.12, 1))
			flareB.Transparency = math.clamp(age / (WARM + HOLD + fade * 0.6), 0, 1)
		end
		if ring then
			local rd = w * (1 + 3 * math.min(age / (WARM + HOLD + fade), 1))
			ring.Size = Vector3.new(0.12, rd, rd)
			ring.Transparency = 0.35 + 0.65 * math.min(age / (WARM + HOLD + fade), 1)
		end
		if light then
			light.Brightness = 5 * brightK() * (1 - tr)
		end
		return false
	end)
end

-- LumenPulse ----------------------------------------------------------------------------------------------------------
local function onPulse(d: any)
	if type(d) ~= "table" or not isPos(d.p) then
		return
	end
	local p: Vector3 = d.p
	if camDist(p) > 500 then
		return
	end
	local r = math.clamp(tonumber(d.r) or 20, 2, 90) -- the real damage radius: never scaled by the A/B
	local gy = floorAt(p, 10)
	local g = Vector3.new(p.X, gy, p.Z)
	local parts: { Part } = {}
	local disc = add(parts, acquire(CYL, VIOLET, NEON, Vector3.new(0.1, 1, 1), CFrame.new(g + Vector3.new(0, 0.1, 0)) * FLAT, 0.7))
	local shell = if mode() ~= "min" then add(parts, acquire(BALL, LILAC, NEON, Vector3.one, CFrame.new(g), 0.85)) else nil
	local core = add(parts, acquire(BALL, HOT, NEON, Vector3.one * 2, CFrame.new(p), 0))
	local n = math.max(count(28), 12)
	local edge: { Part } = {}
	for i = 1, n do
		local e = add(parts, acquire(BLOCK, if i % 2 == 0 then HOT else VIOLET, NEON, Vector3.new(0.4, 0.6, 1), CFrame.new(g), 0))
		if e then
			table.insert(edge, e)
		end
	end
	local light = addLight(core, VIOLET, r)
	burst("zap", p, count(18), { color = VIOLET, scale = 1.5 * sizeK(), speed = 1.4 })
	snd("EMPPulse", p, { volume = 0.9, pitch = 1.25, priority = 4 })
	local GROW, HOLD, FADE = 0.3, 0.14, 0.35
	run(parts, function(a: any, _dt: number): boolean
		local age = a.age
		if age >= GROW + HOLD + FADE then
			return true
		end
		local f = math.clamp(age / GROW, 0, 1)
		local cur = r * (1 - (1 - f) ^ 3)
		local tr = math.clamp((age - GROW - HOLD) / FADE, 0, 1)
		if disc then
			disc.Size = Vector3.new(0.1, cur * 2, cur * 2)
			disc.Transparency = 0.72 + 0.28 * tr
		end
		if shell then
			shell.Size = Vector3.one * cur * 2
			shell.Transparency = 0.86 + 0.14 * math.max(tr, f * 0.4)
		end
		if core then
			core.Size = Vector3.one * (2 + 3 * f) * sizeK()
			core.Transparency = math.clamp(age / (GROW + 0.1), 0, 1)
		end
		local ne = #edge
		local seg = (2 * math.pi * math.max(cur, 0.5)) / math.max(ne, 1)
		for i, e in edge do
			local ang = (i / ne) * math.pi * 2 + age * 0.6
			local pos = g + Vector3.new(math.cos(ang) * cur, 0.35, math.sin(ang) * cur)
			local tan = Vector3.new(-math.sin(ang), 0, math.cos(ang))
			e.Size = Vector3.new(0.45 * sizeK(), 0.7 * sizeK(), math.max(seg * 0.7, 0.3))
			e.CFrame = CFrame.lookAt(pos, pos + tan)
			e.Transparency = tr
		end
		if light then
			light.Brightness = 4 * brightK() * (1 - tr)
			light.Range = math.min(cur + 4, 60)
		end
		return false
	end)
end

-- Blink -----------------------------------------------------------------------------------------------------------------
local function onBlink(d: any)
	if type(d) ~= "table" or not isPos(d.a) or not isPos(d.b) then
		return
	end
	local a0: Vector3, b: Vector3 = d.a, d.b
	if camDist(a0) > 400 and camDist(b) > 400 then
		return
	end
	local s = math.clamp(tonumber(d.s) or 2.6, 1, 6) * sizeK()
	local parts: { Part } = {}
	local implode = add(parts, acquire(BALL, VIOLET, NEON, Vector3.one * s * 2, CFrame.new(a0), 0.3))
	local pop = add(parts, acquire(BALL, LILAC, NEON, Vector3.one * 0.1, CFrame.new(b), 1))
	local len = (b - a0).Magnitude
	local streak = if len > 1 and mode() ~= "min"
		then add(parts, acquire(CYL, HOT, NEON, Vector3.new(len, 0.3, 0.3), CFrame.lookAt((a0 + b) / 2, b) * CFrame.Angles(0, math.pi / 2, 0), 0.3))
		else nil
	-- burst at the old spot
	local shards: { Shard } = {}
	spawnShards(parts, shards, a0, count(8), { speed = 22, up = 6, size = math.sqrt(s) * 0.6, life = 0.6, floor = floorAt(a0, 8), neonShare = 0.7 })
	-- fold-in at the new spot
	local fold = {}
	for _ = 1, count(6) do
		local dir = randUnit()
		local part = add(parts, acquire(BLOCK, if rng:NextNumber() < 0.5 then LILAC else CYAN, NEON, Vector3.new(0.25, 0.25, 0.9) * math.sqrt(s) * 0.7, CFrame.new(b + dir * s * 2.2), 0.1))
		if part then
			table.insert(fold, { part = part, dir = dir })
		end
	end
	local light = addLight(pop, LILAC, 14)
	snd("ShieldUp", a0, { volume = 0.5, pitch = 1.8, priority = 3 })
	snd("HitDeflect", b, { volume = 0.5, pitch = 1.5, priority = 3 })
	local FOLD = 0.22
	run(parts, function(a: any, dt: number): boolean
		local age = a.age
		if age >= 0.75 then
			return true
		end
		stepShards(shards, dt, age)
		if implode then
			local f = math.clamp(age / 0.18, 0, 1)
			implode.Size = Vector3.one * s * 2 * (1 - f) + Vector3.one * 0.05
			implode.Transparency = 0.3 + 0.7 * f
		end
		if streak then
			local f = math.clamp(age / 0.16, 0, 1)
			streak.Size = Vector3.new(len, 0.3 * (1 - f) + 0.02, 0.3 * (1 - f) + 0.02)
			streak.Transparency = 0.3 + 0.7 * f
		end
		local ff = math.clamp(age / FOLD, 0, 1)
		for _, m in fold do
			local pos = b + m.dir * s * 2.2 * (1 - ff * ff)
			m.part.CFrame = CFrame.lookAt(pos, b)
			m.part.Transparency = if ff >= 1 then 1 else 0.1
		end
		if pop then
			local g = math.clamp((age - FOLD) / 0.3, 0, 1)
			pop.Size = Vector3.one * (0.1 + s * 1.7 * math.sqrt(g))
			pop.Transparency = if age < FOLD then 1 else 0.15 + 0.85 * g
		end
		if light then
			light.Brightness = if age < FOLD then 0 else 3 * brightK() * (1 - math.clamp((age - FOLD) / 0.4, 0, 1))
		end
		return false
	end)
end

-- RiftGate ----------------------------------------------------------------------------------------------------------------
local function ellipsoid(color: Color3, material: Enum.Material, at: CFrame, transp: number): (Part?, SpecialMesh?)
	local p = acquire(BLOCK, color, material, Vector3.one, at, transp)
	if not p then
		return nil, nil
	end
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Scale = Vector3.new(0.01, 0.01, 0.01)
	m.Parent = p
	return p, m
end

local function onRift(d: any)
	if type(d) ~= "table" or not isPos(d.p) then
		return
	end
	local p: Vector3 = d.p
	if camDist(p) > 500 then
		return
	end
	local r = math.clamp(tonumber(d.r) or 4.5, 1.5, 20) * sizeK()
	local life = math.clamp(tonumber(d.t) or 2.4, 0.4, 30)
	local gy = floorAt(p + Vector3.new(0, 2, 0), 8)
	local g = Vector3.new(p.X, gy, p.Z)
	local h = r * 2.4
	local wid = r * 1.2
	local center = g + Vector3.new(0, h * 0.5 + 0.4, 0)
	local parts: { Part } = {}
	local rim, rimM = ellipsoid(VIOLET, NEON, CFrame.new(center), 0.1)
	add(parts, rim)
	local core, coreM = ellipsoid(DARK, SMOOTH, CFrame.new(center), 0)
	add(parts, core)
	local inner, innerM = ellipsoid(VIOLET, NEON, CFrame.new(center), 0.65)
	add(parts, inner)
	local disc = add(parts, acquire(CYL, VIOLET, NEON, Vector3.new(0.1, 0.5, 0.5), CFrame.new(g + Vector3.new(0, 0.1, 0)) * FLAT, 0.55))
	local orbit = {}
	if mode() ~= "min" then
		for i = 1, count(6) do
			local part = add(parts, acquire(BLOCK, if i % 2 == 0 then LILAC else CERAMIC, if i % 2 == 0 then NEON else SMOOTH, Vector3.new(0.4, 1.1, 0.4) * math.sqrt(r) * 0.6, CFrame.new(center), 0))
			if part then
				table.insert(orbit, { part = part, ang = i * 1.1, y = rnd(-0.4, 0.4), spin = rnd(1.4, 2.4) })
			end
		end
	end
	local light = addLight(inner, VIOLET, 14 + 3 * r)
	burst("zap", g + Vector3.new(0, 1, 0), count(10), { color = VIOLET, scale = 1.2, speed = 0.8 })
	snd("Breach", g, { volume = 0.6, pitch = 1.4, priority = 3 })
	snd("EMP", g, { volume = 0.35, pitch = 0.7, priority = 3 })
	local OPEN, CLOSE = 0.35, 0.3
	local closedBurst = false
	run(parts, function(a: any, _dt: number): boolean
		local age = a.age
		if age >= life then
			return true
		end
		-- width: a line splitting open (back-out), then pinching shut at the end
		local wk
		local fo = math.clamp(age / OPEN, 0, 1)
		local c1, c3 = 1.70158, 2.70158
		wk = 1 + c3 * (fo - 1) ^ 3 + c1 * (fo - 1) ^ 2
		local hk = math.clamp(age / 0.15, 0.2, 1)
		local closeF = math.clamp((age - (life - CLOSE)) / CLOSE, 0, 1)
		if closeF > 0 then
			wk *= 1 - closeF
			hk *= 1 - closeF * closeF
			if not closedBurst then
				closedBurst = true
				burst("zap", center, count(8), { color = LILAC, scale = 1 })
			end
		end
		local wobble = 1 + 0.04 * math.sin(age * 9)
		local W, H = math.max(wid * wk * wobble, 0.05), math.max(h * hk, 0.05)
		-- face the local camera (yaw only)
		local cam = Workspace.CurrentCamera
		local look = if cam then cam.CFrame.Position - center else Vector3.zAxis
		look = Vector3.new(look.X, 0, look.Z)
		local face = if look.Magnitude > 0.1 then CFrame.lookAt(center, center + look) else CFrame.new(center)
		if rim and rimM then
			rim.CFrame = face
			rimM.Scale = Vector3.new(W * 1.22 + 0.25, H * 1.08 + 0.2, 0.25)
		end
		if core and coreM then
			core.CFrame = face
			coreM.Scale = Vector3.new(W, H, 0.35)
		end
		if inner and innerM then
			inner.CFrame = face
			innerM.Scale = Vector3.new(W * 0.55, H * 0.85, 0.42)
			inner.Transparency = 0.55 + 0.2 * math.sin(age * 6)
		end
		if disc then
			local dd = r * 3 * math.min(fo * 1.3, 1) * (1 - closeF)
			disc.Size = Vector3.new(0.1, math.max(dd, 0.1), math.max(dd, 0.1))
			disc.Transparency = 0.55 + 0.45 * closeF
		end
		for _, o in orbit do
			local ang = o.ang + age * o.spin
			local rr = (W * 0.5 + 1.2) * (1 - closeF)
			local pos = face * Vector3.new(math.cos(ang) * rr, o.y * H * 0.5 + math.sin(ang) * H * 0.4, math.sin(ang) * 0.8)
			o.part.CFrame = CFrame.new(pos) * CFrame.Angles(age * 2, ang, 0)
			o.part.Transparency = closeF
		end
		if light then
			light.Brightness = 3 * brightK() * fo * (1 - closeF)
		end
		return false
	end)
end

-- Shard death -------------------------------------------------------------------------------------------------------------
local SIZE_F = { S = 1, M = 1.6, L = 2.6, XL = 4.2 }
local fodderWin, fodderN = 0, 0

local function shatter(p: Vector3, f: number, o: any?)
	o = o or {}
	local dist = camDist(p)
	if dist > 400 then
		return
	end
	local fodder = o.fodder == true
	if fodder then
		local now = os.clock()
		if now - fodderWin > 0.25 then
			fodderWin, fodderN = now, 0
		end
		fodderN += 1
		if fodderN > (if (Fx and Fx.quality or 1) < 0.6 then 4 else 8) or dist > 120 then
			return
		end
	end
	local dir: Vector3? = o.dir
	local parts: { Part } = {}
	local pop = add(parts, acquire(BALL, LILAC, NEON, Vector3.one * 0.6 * f, CFrame.new(p), 0.2))
	local core = add(parts, acquire(BALL, HOT, NEON, Vector3.one * 0.4 * f, CFrame.new(p), 0))
	local light = if not fodder and dist < 140 then addLight(pop, VIOLET, 10 + 6 * f) else nil
	local n = if fodder then 3 else math.floor(6 + 5 * f)
	if dist > 150 then
		n = math.ceil(n * 0.5)
	end
	local shards: { Shard } = {}
	spawnShards(parts, shards, p, count(n), {
		speed = 16 + 4 * f,
		up = 8,
		size = math.sqrt(f) * sizeK(),
		life = 1.1 + 0.15 * f,
		floor = floorAt(p, 6 + 4 * f),
		dir = dir,
		bias = if o.blast then 1.5 else 0.9,
		neonShare = 0.55,
	})
	burst("zap", p, count(if fodder then 5 else 8 + 4 * f), { color = VIOLET, scale = math.sqrt(f) * sizeK() })
	if not fodder then
		snd("HitDeflect", p, { volume = 0.45, pitch = rnd(1.6, 1.9), priority = 2 })
	end
	if f >= 2.4 and Fx and Fx.shockwave then
		pcall(Fx.shockwave, p, 5 * f, VIOLET)
	end
	local POP = 0.24
	local life = (1.1 + 0.15 * f) * 1.25 + 0.05 -- longest shard life (spawnShards rolls 0.75-1.25x)
	run(parts, function(a: any, dt: number): boolean
		local age = a.age
		if age >= life then
			return true
		end
		stepShards(shards, dt, age)
		local g = math.clamp(age / POP, 0, 1)
		if pop then
			pop.Size = Vector3.one * f * (0.6 + 2.8 * g) * sizeK()
			pop.Transparency = 0.2 + 0.8 * g
		end
		if core then
			local c = math.clamp(age / 0.1, 0, 1)
			core.Size = Vector3.one * f * (0.4 + 1.2 * c)
			core.Transparency = c
		end
		if light then
			light.Brightness = 3.5 * brightK() * (1 - math.clamp(age / 0.35, 0, 1))
		end
		return false
	end)
end

local function onDeath(d: any)
	if type(d) ~= "table" or d.style ~= "shard" or not isPos(d.p) then
		return
	end
	local f = SIZE_F[d.size] or 1.4
	local dir: Vector3? = if typeof(d.dir) == "Vector3" and d.dir.Magnitude > 0.01 then d.dir.Unit else nil
	shatter(d.p, f, { fodder = d.fodder == true, dir = dir, blast = d.blast == true })
end

-- Aurora (crystal biome) --------------------------------------------------------------------------------------------------
local aurora: { parts: { Part }, beams: { Beam }, conn: RBXScriptConnection?, nextAt: number, shimmerAt: number, lastT: number }? = nil
local SHIMMER_IN, SHIMMER_HOLD, SHIMMER_OUT = 3, 5, 3

local function crystalBiome(): boolean
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return false
	end
	local mission = Store and Store.get("mission")
	if mission and mission.state == "Ship" then
		return false
	end
	local b = map:GetAttribute("Biome")
	if b == "crystal" then
		return true
	end
	return b == nil and mission ~= nil and mission.faction == "LUMEN"
end

local function auroraOff()
	if not aurora then
		return
	end
	if aurora.conn then
		aurora.conn:Disconnect()
	end
	for _, p in aurora.parts do
		p:Destroy()
	end
	aurora = nil
end

local function auroraOn()
	if aurora then
		return
	end
	local q = (Fx and Fx.quality) or 1
	local n = if q < 0.6 then 1 elseif mode() == "big" then 4 else 3
	local seg = if q < 0.6 then 10 else 24
	local f = getFolder()
	local A: any = { parts = {}, beams = {}, conn = nil, nextAt = os.clock() + rnd(6, 14), shimmerAt = -1, lastT = -1 }
	local specs = {}
	for i = 1, n do
		local holder = Instance.new("Part")
		holder.Name = "Aurora"
		holder.Anchored = true
		holder.CanCollide = false
		holder.CanQuery = false
		holder.CanTouch = false
		holder.CastShadow = false
		holder.Transparency = 1
		holder.Size = Vector3.one
		holder.Parent = f
		local a0 = Instance.new("Attachment")
		a0.Parent = holder
		local a1 = Instance.new("Attachment")
		a1.Parent = holder
		local bm = Instance.new("Beam")
		bm.Attachment0 = a0
		bm.Attachment1 = a1
		bm.FaceCamera = true
		bm.LightEmission = 1
		bm.LightInfluence = 0
		bm.Segments = seg
		bm.Width0 = rnd(50, 80)
		bm.Width1 = rnd(40, 70)
		local tint = if i % 2 == 0 then CYAN else C3(140, 255, 210)
		bm.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, VIOLET),
			ColorSequenceKeypoint.new(0.5, tint),
			ColorSequenceKeypoint.new(1, VIOLET),
		})
		bm.Transparency = NumberSequence.new(1)
		bm.Parent = holder
		table.insert(A.parts, holder)
		table.insert(A.beams, bm)
		table.insert(specs, { holder = holder, a0 = a0, a1 = a1, beam = bm, ang = (i - 1) / n * math.pi * 2 + rnd(-0.4, 0.4), alt = rnd(170, 230), dist = rnd(280, 340), span = rnd(380, 520), phase = rnd(0, 6.28) })
	end
	A.conn = RunService.RenderStepped:Connect(function()
		local cam = Workspace.CurrentCamera
		if not cam then
			return
		end
		local now = os.clock()
		local c = cam.CFrame.Position
		-- shimmer schedule: faint always, a bright wash every 25-45 s
		if A.shimmerAt < 0 and now >= A.nextAt then
			A.shimmerAt = now
		end
		local s = 0
		if A.shimmerAt >= 0 then
			local t = now - A.shimmerAt
			if t < SHIMMER_IN then
				s = t / SHIMMER_IN
			elseif t < SHIMMER_IN + SHIMMER_HOLD then
				s = 1
			elseif t < SHIMMER_IN + SHIMMER_HOLD + SHIMMER_OUT then
				s = 1 - (t - SHIMMER_IN - SHIMMER_HOLD) / SHIMMER_OUT
			else
				A.shimmerAt = -1
				A.nextAt = now + rnd(25, 45)
			end
		end
		s = s * s * (3 - 2 * s)
		local peak = if mode() == "big" then 0.35 else 0.55
		local base = 0.9
		local alpha = base + (peak - base) * s
		local update = math.abs(alpha - A.lastT) > 0.01
		if update then
			A.lastT = alpha
		end
		for _, sp in specs do
			local dirOut = Vector3.new(math.cos(sp.ang), 0, math.sin(sp.ang))
			local tan = Vector3.new(-dirOut.Z, 0, dirOut.X)
			local mid = Vector3.new(c.X, 0, c.Z) + dirOut * sp.dist + Vector3.new(0, sp.alt, 0)
			sp.holder.CFrame = CFrame.new(mid)
			sp.a0.WorldPosition = mid - tan * sp.span * 0.5
			sp.a1.WorldPosition = mid + tan * sp.span * 0.5 + Vector3.new(0, 20, 0)
			local wave = math.sin(now * 0.25 + sp.phase)
			sp.beam.CurveSize0 = 60 * wave
			sp.beam.CurveSize1 = -50 * math.cos(now * 0.2 + sp.phase)
			if update then
				sp.beam.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.25, alpha),
					NumberSequenceKeypoint.new(0.75, math.min(alpha + 0.05, 1)),
					NumberSequenceKeypoint.new(1, 1),
				})
			end
		end
	end)
	aurora = A
end

local function refreshAurora()
	if crystalBiome() and mode() ~= "min" then
		auroraOn()
	else
		auroraOff()
	end
end

-- Init ----------------------------------------------------------------------------------------------------------------------
function LumenFx.init(fx: any, audio: any, _juice: any)
	Fx = fx
	Audio = audio
	Fx.register("LumenCharge", onCharge)
	Fx.register("LumenBeam", onBeam)
	Fx.register("LumenPulse", onPulse)
	Fx.register("Blink", onBlink)
	Fx.register("RiftGate", onRift)
	Fx.register("Death", onDeath)
	Fx.lumenShatter = function(p: Vector3, f: number?)
		if isPos(p) then
			shatter(p, f or 2, nil)
		end
	end
	task.spawn(function()
		local ok, mod = pcall(function()
			return require(script.Parent.Parent:WaitForChild("Store", 10))
		end)
		if ok then
			Store = mod
		end
		Workspace:GetAttributeChangedSignal("Feel_LumenFx"):Connect(function()
			auroraOff() -- rebuilt with the new count by the loop below
			refreshAurora()
		end)
		while true do
			local ok2, err = pcall(refreshAurora)
			if not ok2 and not warned then
				warned = true
				warn("[LumenFx] aurora: " .. tostring(err))
			end
			task.wait(1)
		end
	end)
end

return LumenFx
