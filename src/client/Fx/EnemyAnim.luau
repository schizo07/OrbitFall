-- Client-side procedural animation for the mesh enemies (model attribute MeshRig = true, built by server/Enemies/EnemyModels).
-- The server only moves the invisible Root. Everything else here is local: no remotes, no server cost.
--
-- Rigged models (model attribute Rigged = true): every limb is a Motor6D named like the manifest part, parented inside the
-- child part, with the joint exactly at the manifest pivot (see EnemyModels.buildRigged). With Transform = identity the
-- model is in its bind pose; we only ever write Motor6D.Transform (never replicated). Axes of a Transform are the template
-- axes (X right, Y up, -Z forward) rotated by the parent joints:
--     rx(+a): a hanging limb swings FORWARD, a forward limb tips UP, the top of a body leans BACK
--     ry(+a): a limb on the +X (right) side swings FORWARD (left side: backward); a forward limb turns toward -X
--     rz(+a): a limb on the +X side lifts UP (left side: down)
-- Non-rigged models (legacy single piece mesh, Welds with attribute Sway) keep the old bob/sway.
--
-- Driven by the root's measured velocity (smoothed, from replicated position changes), a stride phase advanced by distance
-- travelled, and two attributes the server sets on the model:
--     AtkSeq (+ AtkKind, AtkWindup)  an attack started: arm recoil / lunge pose
--     HitSeq (+ HitMag HitDir HitWeak HitStagger)  damage taken: spring jolt along HitDir, stagger pose on heavy hits
-- Budget: only enemies within 160 studs of the camera (100 on low quality) are looked at; beyond 70 studs they update at
-- 15 Hz; enemies outside the view cone only track motion, their joints are not touched.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EnemyData = require(Shared.Data.Enemies)
local Meshes = require(Shared.Data.Meshes)

local EnemyAnim = {}

local rad, sin, cos, abs, max, min, clamp = math.rad, math.sin, math.cos, math.abs, math.max, math.min, math.clamp
local PI = math.pi
local CF = CFrame.new
local IDENT = CFrame.new()

local function rx(a: number): CFrame
	return CFrame.Angles(a, 0, 0)
end
local function ry(a: number): CFrame
	return CFrame.Angles(0, a, 0)
end
local function rz(a: number): CFrame
	return CFrame.Angles(0, 0, a)
end
local function wrapPi(a: number): number
	return (a + PI) % (2 * PI) - PI
end

-- Per-kind configuration ------------------------------------------------------------
-- stride: studs travelled per full gait cycle at full amplitude; maxHz: gait cycles per second cap
-- yaw / lift / lowerLift: leg swing about the vertical axis, lift about the forward axis, extra lift of the lower segment (degrees)
type Cfg = {
	type: string, -- "biped" | "hex" | "quad"
	stride: number,
	maxHz: number,
	legs: number?,
	upper: string?, -- leg part name pattern, %d = leg number
	lower: string?,
	groupA: { number }?, -- tripod / diagonal group that swings together (others are in antiphase)
	yaw: number?,
	lift: number?,
	lowerLift: number?,
	bob: number?, -- body bob in studs
	heavy: boolean?,
	arm: number?, -- arm counter swing (degrees)
	lean: number?, -- forward lean (degrees)
}

local CFG: { [string]: Cfg } = {
	TINKER = { type = "biped", stride = 3.4, maxHz = 6, arm = 11, lean = 5 },
	RIVET = { type = "biped", stride = 6.2, maxHz = 5, arm = 9, lean = 4 },
	BULWARK = { type = "quad", legs = 4, upper = "Leg_%d", groupA = { 1, 4 }, yaw = 18, lift = 14, stride = 4.2, maxHz = 4, bob = 0.06 },
	COLOSSUS = {
		type = "quad", legs = 4, upper = "Leg_%d_Upper", lower = "Leg_%d_Lower", groupA = { 1, 4 },
		yaw = 15, lift = 11, lowerLift = 16, stride = 12, maxHz = 1.2, heavy = true,
	},
	SKITTER = { type = "hex", legs = 6, upper = "Leg_%d", groupA = { 1, 4, 5 }, yaw = 24, lift = 18, stride = 3.4, maxHz = 8, bob = 0.04 },
	SPITTER = { type = "hex", legs = 6, upper = "Leg_%d", groupA = { 1, 4, 5 }, yaw = 20, lift = 15, stride = 3.6, maxHz = 5, bob = 0.05 },
	CHARGER = { type = "hex", legs = 6, upper = "Leg_%d", groupA = { 1, 4, 5 }, yaw = 18, lift = 13, stride = 4.8, maxHz = 6, bob = 0.08 },
	TITAN = {
		type = "hex", legs = 6, upper = "Leg_%d_Upper", lower = "Leg_%d_Lower", groupA = { 1, 4, 5 },
		yaw = 14, lift = 11, lowerLift = 16, stride = 10, maxHz = 1.5, heavy = true,
	},
}

-- Attack pose timing. tail = seconds the pose lasts after the shot, shots/gap = recoil pulses.
local ATK: { [string]: { tail: number, shots: number?, gap: number? } } = {
	bolt = { tail = 0.45 },
	burst = { tail = 0.7, shots = 3, gap = 0.13 },
	cannon = { tail = 0.8 },
	mortar = { tail = 1.8 },
	sweep = { tail = 2.4 },
	stomp = { tail = 0.5 },
	melee = { tail = 0.5 },
	leap = { tail = 0.55 },
	spit = { tail = 0.55 },
	charge = { tail = 1.8 },
	summon = { tail = 1.4 },
}
local ATK_DEFAULT = { tail = 0.5 }

-- Rig data (pivots) from Data/Meshes ----------------------------------------------
type RigLookup = { piv: { [string]: Vector3 }, parent: { [string]: string? } }
local rigCache: { [string]: RigLookup? } = {}

local function rigOf(kind: string): RigLookup?
	local key = string.lower(kind)
	local cached = rigCache[key]
	if cached ~= nil then
		return cached
	end
	local info = Meshes[key]
	local r: RigLookup? = nil
	if info and info.rig then
		local piv, par = {}, {}
		for _, p in info.rig.parts do
			piv[p.name] = p.pivot
			par[p.name] = p.parent
		end
		r = { piv = piv, parent = par }
	end
	rigCache[key] = r
	return r
end

-- Entries -----------------------------------------------------------------------------
type Leg = { upper: string, lower: string?, side: number, group: number }
type WeldEntry = { weld: Weld, base: CFrame, legs: boolean }
type Entry = {
	model: Model,
	root: BasePart,
	kind: string,
	cfg: Cfg?,
	def: any,
	size: number,
	radius: number,
	rigged: boolean,
	motors: { [string]: Motor6D },
	motorCount: number,
	expected: number,
	legList: { Leg },
	welds: { WeldEntry }?,
	rig: RigLookup?,
	hipH: number,
	tries: number,
	nextTry: number,
	-- motion
	lastPos: Vector3,
	lastMoveT: number,
	lastUpd: number,
	vel: Vector3,
	velTarget: Vector3,
	speed: number,
	turn: number,
	lastYaw: number,
	amp: number,
	phase: number,
	seed: number,
	nextT: number,
	-- events
	atk: { kind: string, windup: number, t0: number }?,
	hitT: number,
	hitDir: number,
	-- hit reaction spring (root-local horizontal plane; +Z = backwards): displacement / velocity, twist, stagger
	sx: number,
	sz: number,
	svx: number,
	svz: number,
	syaw: number,
	svyaw: number,
	stagT: number, -- start of the current stagger (os.clock)
	stagDur: number,
	stagK: number,
	recentLocal: number, -- strength of locally predicted impacts not yet confirmed by the server's HitSeq
	recentT: number,
	flashT: number,
	hl: Highlight?,
	hlToken: number,
	conns: { RBXScriptConnection },
	eye: BasePart?,
	dustT: number?,
	-- legacy sway
	legacyPhase: number,
}

local entries: { [Model]: Entry } = {}
local frame = 0
local conn: RBXScriptConnection? = nil
local quality = 1
local FxRef: any = nil

-- Motor / weld collection -----------------------------------------------------------
local function buildLegList(e: Entry)
	local cfg = e.cfg
	e.legList = {}
	if not cfg or not cfg.legs or not cfg.upper or not e.rig then
		return
	end
	local inA: { [number]: boolean } = {}
	for _, n in cfg.groupA or {} do
		inA[n] = true
	end
	for n = 1, cfg.legs do
		local up = string.format(cfg.upper, n)
		local pv = e.rig.piv[up]
		table.insert(e.legList, {
			upper = up,
			lower = if cfg.lower then string.format(cfg.lower, n) else nil,
			side = if pv and pv.X < 0 then -1 else 1, -- +1 right (+X), -1 left
			group = if inA[n] then 0 else 1,
		})
	end
end

local function collect(e: Entry): boolean
	if e.rigged then
		local count = 0
		for _, d in e.model:GetDescendants() do
			if d:IsA("Motor6D") and not e.motors[d.Name] then
				e.motors[d.Name] = d
				count += 1
			end
		end
		e.motorCount += count
		return e.motors.Body ~= nil
	end
	local list: { WeldEntry } = {}
	for _, d in e.model:GetDescendants() do
		if d:IsA("Weld") then
			local s = d:GetAttribute("Sway")
			if s then
				table.insert(list, { weld = d, base = d.C0, legs = s == "legs" })
			end
		end
	end
	if #list == 0 then
		return false
	end
	e.welds = list
	return true
end

-- Attack telegraph: robot ranged attacks charge up a glow on the eye (or core) for the wind-up, then pop as they fire.
-- One client-local Neon ball welded to the eye part, no light, only within 140 studs; cleaned up after the wind-up.
local GLOW_KINDS = { bolt = true, burst = true, cannon = true, mortar = true, sweep = true }
local GLOW_HOT = Color3.fromRGB(255, 205, 150)

local function findEye(e: Entry): BasePart?
	local eye = e.eye
	if eye and eye.Parent then
		return eye
	end
	local found = e.model:FindFirstChild("Eye", true) or e.model:FindFirstChild("Core", true)
	if found and found:IsA("BasePart") then
		e.eye = found
		return found
	end
	return nil
end

local function windupGlow(e: Entry, windup: number)
	if windup < 0.15 or not e.def or e.def.faction ~= "COG" then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam or (e.root.Position - cam.CFrame.Position).Magnitude > 140 then
		return
	end
	local eye = findEye(e)
	if not eye then
		return
	end
	local dur = clamp(windup, 0.15, 1.4)
	local s = eye.Size
	local full = clamp(max(s.X, s.Y, s.Z) * 1.5, 0.9, 7)
	local g = Instance.new("Part")
	g.Name = "WindupGlow"
	g.Shape = Enum.PartType.Ball
	g.Material = Enum.Material.Neon
	g.Color = eye.Color
	g.Size = Vector3.one * full * 0.35
	g.Transparency = 0.75
	g.Anchored = false
	g.Massless = true
	g.CanCollide = false
	g.CanQuery = false
	g.CanTouch = false
	g.CastShadow = false
	g.CFrame = eye.CFrame
	local w = Instance.new("Weld")
	w.Part0 = eye
	w.Part1 = g
	w.Parent = g
	g.Parent = e.model
	TweenService:Create(g, TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = Vector3.one * full,
		Transparency = 0.12,
		Color = GLOW_HOT,
	}):Play()
	task.delay(dur, function()
		if g.Parent then
			TweenService:Create(g, TweenInfo.new(0.12), { Transparency = 1, Size = Vector3.one * full * 1.3 }):Play()
		end
	end)
	Debris:AddItem(g, dur + 0.2)
	task.delay(dur + 0.25, function()
		if g.Parent then
			g:Destroy()
		end
	end)
end

local function onAttack(e: Entry)
	local m = e.model
	local kind = m:GetAttribute("AtkKind")
	local windup = m:GetAttribute("AtkWindup")
	e.atk = {
		kind = if type(kind) == "string" then kind else "bolt",
		windup = if type(windup) == "number" then windup else 0.3,
		t0 = os.clock(),
	}
	if GLOW_KINDS[e.atk.kind] then
		windupGlow(e, e.atk.windup)
	end
end

-- Hit flash: one Highlight per model, toggled for 0.06 s and released after a quiet second. Roblox allows 31 Highlights
-- per client (the player's own armour flash uses one), so only enemies within 80 studs flash and at most HL_MAX at once.
local HL_MAX = 20
local hlLive = 0

local function flashEnemy(e: Entry)
	local cam = Workspace.CurrentCamera
	if not cam or (e.root.Position - cam.CFrame.Position).Magnitude > 80 then
		return
	end
	local hl = e.hl
	if not hl then
		if hlLive >= HL_MAX then
			return
		end
		hl = Instance.new("Highlight")
		hl.FillColor = Color3.new(1, 1, 1)
		hl.FillTransparency = 0.3
		hl.OutlineColor = Color3.new(1, 1, 1)
		hl.OutlineTransparency = 0.7
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
		hl.Enabled = false
		hl.Adornee = e.model
		hl.Parent = e.model
		e.hl = hl
		hlLive += 1
	end
	e.hlToken += 1
	local token = e.hlToken
	local h = hl :: Highlight
	h.Enabled = true
	task.delay(0.06, function()
		if e.hlToken ~= token or not h.Parent then
			return
		end
		h.Enabled = false
		task.delay(1, function()
			if e.hlToken == token and e.hl == h then
				e.hl = nil
				hlLive -= 1
				h:Destroy()
			end
		end)
	end)
end

-- Hit reaction ---------------------------------------------------------------------------
-- A damped spring in the root-local horizontal plane (x = right, z = backwards). Every hit adds an impulse along the way the
-- damage travelled, so single shots jolt the body and rapid fire keeps it rocked back (clamped). Heavy hits also start a
-- stagger (deeper lean, head snap, arms flung back). The spring is read in `setBody` for every pose.
local SPRING_K = 300
local SPRING_C = 14 -- zeta ~0.4: one visible overshoot, settles in ~0.35 s
local IMPULSE = 22 -- velocity added per unit of hit strength (a unit hit peaks at ~1 displacement unit)
local MAX_DISP = 1.8
local LOCAL_WINDOW = 0.35

local function addImpulse(e: Entry, dirW: Vector3?, mag: number, weak: boolean, stagger: boolean)
	local rcf = e.root.CFrame
	local d = dirW
	if not d or d.Magnitude < 0.05 then
		d = -rcf.LookVector -- unknown: as if shot from the front
	end
	local lv = rcf:VectorToObjectSpace(d)
	local len = math.sqrt(lv.X * lv.X + lv.Z * lv.Z)
	local hx, hz = 0, 1
	if len > 0.05 then
		hx, hz = lv.X / len, lv.Z / len
	end
	local k = mag * (if weak then 1.35 else 1) * IMPULSE
	e.svx += hx * k
	e.svz += hz * k
	-- off-centre hits twist the body a little
	e.svyaw += hx * k * 0.3 * (if e.hitDir > 0 then 1 else -1)
	e.hitT = os.clock()
	e.hitDir = -e.hitDir
	if stagger then
		e.stagT = os.clock()
		e.stagDur = 0.55 + 0.15 * clamp(mag - 2, 0, 1.5)
		e.stagK = clamp(mag / 2.4, 0.8, 1.5)
	end
end

local function quickFlash(e: Entry)
	local t = os.clock()
	if t - e.flashT > 0.05 then
		e.flashT = t
		flashEnemy(e)
	end
end

-- Server confirmed damage (attributes set right before HitSeq): HitMag / HitDir / HitWeak / HitStagger.
local function onHit(e: Entry)
	local m = e.model
	local mag = m:GetAttribute("HitMag")
	mag = if type(mag) == "number" then mag else 0.8
	local dir = m:GetAttribute("HitDir")
	local weak = m:GetAttribute("HitWeak") == true
	local stagger = m:GetAttribute("HitStagger") == true
	-- subtract what the local impact prediction already applied for these bullets
	local now = os.clock()
	local recent = e.recentLocal * max(0, 1 - (now - e.recentT) / LOCAL_WINDOW)
	local extra = max(0, mag - recent * 0.9)
	e.recentLocal = max(0, recent - mag)
	e.recentT = now
	if extra > 0.05 or stagger then
		addImpulse(e, if typeof(dir) == "Vector3" then dir else nil, extra, weak, stagger)
	end
	quickFlash(e)
end

-- Locally predicted bullet impact (Fx.impact -> Fx.enemyHit): jolt the enemy nearest to the impact point immediately so the
-- reaction lands with the sparks instead of one round-trip later.
local RESULT_MAG = { pen = 0.75, partial = 0.4, deflect = 0.15 }

function EnemyAnim.hitNear(p: Vector3, n: Vector3?, result: string?)
	local cam = Workspace.CurrentCamera
	if not cam or (cam.CFrame.Position - p).Magnitude > 120 then
		return
	end
	local best: Entry? = nil
	local bestD = math.huge
	for model, e in entries do
		if model.Parent and e.rigged then
			local c = e.root.Position + Vector3.new(0, e.size * 0.7, 0)
			local d = (c - p).Magnitude
			if d < e.size * 1.7 + 1.5 and d < bestD then
				bestD = d
				best = e
			end
		end
	end
	if not best then
		return
	end
	local mag = RESULT_MAG[result or "pen"] or 0.6
	local dir: Vector3? = nil
	if n then
		dir = Vector3.new(-n.X, -n.Y * 0.35, -n.Z) -- the bullet travelled into the surface
	end
	addImpulse(best, dir, mag, false, false)
	local now = os.clock()
	best.recentLocal = best.recentLocal * max(0, 1 - (now - best.recentT) / LOCAL_WINDOW) + mag
	best.recentT = now
	quickFlash(best)
end

-- Death break-up -----------------------------------------------------------------------
-- The server fires Fx "Death" and destroys the model in the same frame, so the model's mesh parts are cloned from its
-- Destroying event and paired (either order, 0.5 s window) with the Death event nearby. Robots pop apart into spinning
-- plates that fade over 2 s; bugs squash and shrink away. Cap 6 concurrent break-ups (3 on weak devices); the oldest vanishes.
type Ghost = { clones: { BasePart }, pos: Vector3, t: number, radius: number, brood: boolean, size: number, used: boolean, dir: Vector3?, blast: boolean? }
local ghosts: { Ghost } = {}
local deathNotes: { { p: Vector3, t: number, dir: Vector3?, blast: boolean? } } = {}
local breakups: { { parts: { BasePart } } } = {}
local cloneBudget = 0
local cloneBudgetT = 0
local rngB = Random.new()

local function maxBreakups(): number
	return if quality < 0.75 then 3 else 6
end

local function launch(g: Ghost)
	if g.used or #g.clones == 0 then
		return
	end
	g.used = true
	local folder = if FxRef and FxRef.folder then FxRef.folder else Workspace
	while #breakups >= maxBreakups() do
		local old = table.remove(breakups, 1)
		for _, p in old.parts do
			if p.Parent then
				p:Destroy() -- oldest vanishes instantly
			end
		end
	end
	local set = { parts = g.clones }
	table.insert(breakups, set)
	local centre = Vector3.zero
	for _, p in g.clones do
		centre += p.Position
	end
	centre /= #g.clones
	local sf = math.clamp(g.size / 2, 0.7, 3)
	local life = if g.brood then 1.8 else 2.4
	for _, p in g.clones do
		local out = p.Position - centre
		out = if out.Magnitude > 0.05 then out.Unit else Vector3.new(rngB:NextNumber(-1, 1), 0.5, rngB:NextNumber(-1, 1)).Unit
		p.Anchored = false
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Massless = false
		p.CustomPhysicalProperties = PhysicalProperties.new(0.4, 0.5, if g.brood then 0.05 else 0.3, 1, 1)
		p.Parent = folder
		local speed = (if g.brood then rngB:NextNumber(7, 14) else rngB:NextNumber(12, 24)) * math.clamp(sf, 0.8, 1.6)
		local vel = out * speed + Vector3.new(0, rngB:NextNumber(14, 26), 0)
		if g.dir then
			-- the killing blow carries the pieces: a strong shove along the shot direction on top of the radial burst
			vel = out * speed * 0.6 + g.dir * speed * (if g.blast then 1.9 else 1.35) + Vector3.new(0, rngB:NextNumber(12, 24) + (if g.blast then 10 else 0), 0)
		end
		p.AssemblyLinearVelocity = vel
		p.AssemblyAngularVelocity = Vector3.new(rngB:NextNumber(-1, 1), rngB:NextNumber(-1, 1), rngB:NextNumber(-1, 1)) * rngB:NextNumber(5, 14)
		Debris:AddItem(p, life + 0.1)
	end
	-- collide only once they have drifted apart (they start overlapping)
	task.delay(0.1, function()
		for _, p in set.parts do
			if p.Parent then
				p.CanCollide = true
			end
		end
	end)
	if g.brood then
		-- squash, then shrink away
		task.delay(0.12, function()
			for _, p in set.parts do
				if p.Parent then
					local s = p.Size
					TweenService:Create(p, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(s.X * 1.35, s.Y * 0.5, s.Z * 1.35) }):Play()
				end
			end
		end)
		task.delay(0.5, function()
			for _, p in set.parts do
				if p.Parent then
					TweenService:Create(p, TweenInfo.new(life - 0.55, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Size = Vector3.one * 0.05, Transparency = 1 }):Play()
				end
			end
		end)
		if FxRef and FxRef.burst then
			FxRef.burst("goo", centre, 8, { scale = 0.8 })
		end
	else
		task.delay(life - 0.55, function()
			for _, p in set.parts do
				if p.Parent then
					TweenService:Create(p, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
				end
			end
		end)
		if FxRef and FxRef.burst then
			FxRef.burst("sparks", centre, 8, { scale = 0.7, speed = 1.1 })
			FxRef.burst("puff", centre, 3, { scale = 1.1, color = Color3.fromRGB(110, 108, 112) })
		end
	end
	task.delay(life + 0.2, function()
		local i = table.find(breakups, set)
		if i then
			table.remove(breakups, i)
		end
	end)
end

local function pairGhost(g: Ghost): boolean
	local now = os.clock()
	for i = #deathNotes, 1, -1 do
		local n = deathNotes[i]
		if now - n.t > 0.5 then
			table.remove(deathNotes, i)
		elseif (n.p - g.pos).Magnitude < g.radius then
			table.remove(deathNotes, i)
			g.dir, g.blast = n.dir, n.blast
			launch(g)
			return true
		end
	end
	return false
end

local function snapshot(e: Entry)
	if quality < 0.4 then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam or (e.root.Position - cam.CFrame.Position).Magnitude > 110 then
		return
	end
	-- at most ~60 clones per half second: mission-end despawns of the whole roster must not spike a frame
	local now = os.clock()
	if now - cloneBudgetT > 0.5 then
		cloneBudgetT = now
		cloneBudget = 60
	end
	if cloneBudget <= 0 then
		return
	end
	local cand: { { part: BasePart, vol: number } } = {}
	for _, d in e.model:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 0.9 and d ~= e.root and d.Name ~= "WindupGlow" then
			local s = d.Size
			table.insert(cand, { part = d, vol = s.X * s.Y * s.Z })
		end
	end
	if #cand == 0 then
		return
	end
	table.sort(cand, function(a, b)
		return a.vol > b.vol
	end)
	local cap = math.min(if quality < 0.75 then 8 else 14, cloneBudget)
	local clones: { BasePart } = {}
	for i = 1, math.min(#cand, cap) do
		local ok, c = pcall(function()
			return cand[i].part:Clone()
		end)
		if ok and c then
			for _, ch in c:GetChildren() do
				if not (ch:IsA("SpecialMesh") or ch:IsA("SurfaceAppearance") or ch:IsA("Decal") or ch:IsA("Texture")) then
					ch:Destroy()
				end
			end
			c.Anchored = true
			table.insert(clones, c)
		end
	end
	cloneBudget -= #clones
	if #clones == 0 then
		return
	end
	local g: Ghost = {
		clones = clones,
		pos = e.root.Position + Vector3.new(0, e.size * 0.7, 0),
		t = now,
		radius = e.size * 2 + 5,
		brood = e.def ~= nil and e.def.faction == "BROOD",
		size = e.size,
		used = false,
	}
	if not pairGhost(g) then
		table.insert(ghosts, g)
		task.delay(0.55, function()
			local i = table.find(ghosts, g)
			if i then
				table.remove(ghosts, i)
			end
			if not g.used then
				for _, c in g.clones do
					c:Destroy()
				end
			end
		end)
	end
end

local function onDeathNote(d: any)
	if typeof(d.p) ~= "Vector3" then
		return
	end
	local now = os.clock()
	for i = #ghosts, 1, -1 do
		local g = ghosts[i]
		if now - g.t < 0.5 and (g.pos - d.p).Magnitude < g.radius then
			table.remove(ghosts, i)
			g.dir = if typeof(d.dir) == "Vector3" then d.dir else nil
			g.blast = d.blast == true
			launch(g)
			return
		end
	end
	table.insert(deathNotes, { p = d.p, t = now, dir = if typeof(d.dir) == "Vector3" then d.dir else nil, blast = d.blast == true })
	if #deathNotes > 12 then
		table.remove(deathNotes, 1)
	end
end

local function track(model: Instance)
	if not model:IsA("Model") or entries[model] or not model:GetAttribute("MeshRig") then
		return
	end
	local root = model.PrimaryPart or model:FindFirstChild("Root")
	if not (root and root:IsA("BasePart")) then
		task.delay(0.3, track, model) -- not replicated yet
		return
	end
	local kindAttr = model:GetAttribute("Kind")
	local kind = if type(kindAttr) == "string" then kindAttr else ""
	local def = EnemyData.get(kind)
	local rigged = model:GetAttribute("Rigged") == true
	local rig = if rigged then rigOf(kind) else nil
	local now = os.clock()
	local look = root.CFrame.LookVector
	local size = if def then def.size else 2
	local e: Entry = {
		model = model,
		root = root,
		kind = kind,
		cfg = CFG[kind],
		def = def,
		size = size,
		radius = size * 1.6,
		rigged = rigged and rig ~= nil,
		motors = {},
		motorCount = 0,
		expected = if rig then #Meshes[string.lower(kind)].rig.parts else 0,
		legList = {},
		welds = nil,
		rig = rig,
		hipH = 1.7,
		tries = 0,
		nextTry = 0,
		lastPos = root.Position,
		lastMoveT = now,
		lastUpd = now,
		vel = Vector3.zero,
		velTarget = Vector3.zero,
		speed = 0,
		turn = 0,
		lastYaw = math.atan2(-look.X, -look.Z),
		amp = 0,
		phase = math.random() * 2 * PI,
		seed = math.random() * 100,
		nextT = 0,
		atk = nil,
		hitT = -10,
		hitDir = 1,
		sx = 0,
		sz = 0,
		svx = 0,
		svz = 0,
		syaw = 0,
		svyaw = 0,
		stagT = -10,
		stagDur = 0.6,
		stagK = 1,
		recentLocal = 0,
		recentT = -10,
		flashT = -10,
		hl = nil,
		hlToken = 0,
		conns = {},
		legacyPhase = math.random() * 6.28,
	}
	if e.rig then
		local pv = e.rig.piv.Leg_L_Upper
		if pv then
			e.hipH = pv.Y
		end
		buildLegList(e)
	end
	entries[model] = e
	collect(e)
	table.insert(e.conns, model:GetAttributeChangedSignal("AtkSeq"):Connect(function()
		onAttack(e)
	end))
	table.insert(e.conns, model:GetAttributeChangedSignal("HitSeq"):Connect(function()
		onHit(e)
	end))
	table.insert(e.conns, model.Destroying:Connect(function()
		snapshot(e) -- death break-up: clone the visible parts before the server's destroy tears the model down
	end))
end

local function untrack(model: Instance)
	if model:IsA("Model") then
		local e = entries[model]
		if e then
			for _, c in e.conns do
				c:Disconnect()
			end
			if e.hl then
				e.hlToken += 1
				e.hl = nil
				hlLive -= 1
			end
		end
		entries[model] = nil
	end
end

-- Pose helpers ----------------------------------------------------------------------
local function setM(e: Entry, name: string, cf: CFrame)
	local m = e.motors[name]
	if m then
		m.Transform = cf
	end
end

-- Transform for a child of Body that cancels `k` (0..1) of the Body's own Transform, so the child stays (nearly) steady
-- in the world. Derivation: with joint translations J_b (Body) and J_c (child) a Transform T moves a part by
-- W = J T J^-1, so the child needs Tc = T(-d) * Tb'^-1 * T(d), d = J_c - J_b, Tb' = Tb scaled by k.
local function counter(e: Entry, name: string, tb: CFrame, k: number): CFrame
	local rig = e.rig
	if not rig then
		return IDENT
	end
	local pc, pb = rig.piv[name], rig.piv.Body
	if not (pc and pb) then
		return IDENT
	end
	local d = pc - pb
	return CF(-d) * tb:Lerp(IDENT, 1 - k):Inverse() * CF(d)
end

-- Attack envelope: pre = wind-up ramp (0..1), kick = recoil impulses after the shot, post = 1 -> 0 decay after the shot.
local function attackEnv(e: Entry, now: number): (number, number, number, string?)
	local a = e.atk
	if not a then
		return 0, 0, 0, nil
	end
	local info = ATK[a.kind] or ATK_DEFAULT
	local age = now - a.t0
	local w = max(a.windup, 0.06)
	if age > w + info.tail then
		e.atk = nil
		return 0, 0, 0, nil
	end
	if age < w then
		local u = age / w
		return u * u * (3 - 2 * u), 0, 0, a.kind
	end
	local fire = age - w
	local kick = 0
	local gap = info.gap or 0.13
	for k = 0, (info.shots or 1) - 1 do
		local f = fire - k * gap
		if f >= 0 then
			kick += math.exp(-f * 12)
		end
	end
	local u = clamp(fire / info.tail, 0, 1)
	return 0, kick, 1 - u * u * (3 - 2 * u), a.kind
end

type Ctx = {
	t: number,
	dt: number,
	amp: number,
	ph: number,
	vf: number, -- forward speed as a fraction of the kind's top speed (-1..1)
	fw: number, -- how much of the stride is fore/aft (strafing shortens it)
	pre: number,
	kick: number,
	post: number,
	ak: string?,
	fsx: number, -- hit spring displacement (right), already scaled by fs
	fsz: number, -- hit spring displacement (backwards)
	fyaw: number, -- hit twist
	stag: number, -- stagger envelope 0..1 (x stagK)
	fs: number, -- flinch scale (big enemies barely react)
}

-- Writes the Body motor (lean / bob / hit reaction) and returns its Transform for counter-rotations.
local function setBody(e: Entry, c: Ctx, y: number, z: number, pitch: number, yaw: number, roll: number): CFrame
	local fx, fz = c.fsx, c.fsz
	pitch += fz * rad(14) + c.stag * rad(20)
	roll += -fx * rad(10)
	yaw += c.fyaw * rad(9)
	y -= (abs(fz) * 0.05 + c.stag * 0.09) * e.size
	z += fz * 0.13 * e.size + c.stag * 0.08 * e.size
	local tb = CF(fx * 0.12 * e.size, y, z) * CFrame.Angles(pitch, yaw, roll)
	setM(e, "Body", tb)
	return tb
end

-- Leg gait (hexapod tripod / quad diagonal): every leg swings about the vertical axis and lifts about the forward axis,
-- the two groups in antiphase. The lower segment (if any) adds extra lift while the leg is airborne.
local function gaitLegs(e: Entry, c: Ctx, extra: { [string]: CFrame }?)
	local cfg = e.cfg :: Cfg
	local yaw = rad(cfg.yaw or 18) * c.amp * c.fw
	local lift = rad(cfg.lift or 12) * c.amp
	local lowerLift = rad(cfg.lowerLift or 0) * c.amp
	for _, L in e.legList do
		local ph = c.ph + L.group * PI
		local s, co = sin(ph), cos(ph)
		local up = max(0, co)
		local tf = ry(L.side * yaw * s) * rz(L.side * lift * up)
		local ex = extra and extra[L.upper]
		if ex then
			tf = ex * tf
		end
		setM(e, L.upper, tf)
		if L.lower then
			local tl = rz(L.side * lowerLift * (up - 0.45 * max(0, -co)))
			local exl = extra and extra[L.lower]
			if exl then
				tl = exl * tl
			end
			setM(e, L.lower, tl)
		end
	end
end

-- Kind poses ------------------------------------------------------------------------
local function poseBiped(e: Entry, c: Ctx)
	local cfg = e.cfg :: Cfg
	local amp, ph, t = c.amp, c.ph, c.t
	local s, co = sin(ph), cos(ph)
	local A = rad(30) * amp
	local kneeMax = rad(50) * amp
	local hipL, hipR = A * s, -A * s
	local kneeL = -kneeMax * max(0, co) - rad(4) * amp
	local kneeR = -kneeMax * max(0, -co) - rad(4) * amp
	setM(e, "Leg_L_Upper", rx(hipL))
	setM(e, "Leg_R_Upper", rx(hipR))
	setM(e, "Leg_L_Lower", rx(kneeL))
	setM(e, "Leg_R_Lower", rx(kneeR))

	local idle = 1 - amp
	local breath = sin(t * 1.7)
	-- the body drops as the legs splay so the planted foot stays on the floor
	local y = -e.hipH * (1 - cos(A * abs(s))) + breath * 0.02 * e.hipH * idle
	local lean = rad(cfg.lean or 5) * amp * clamp(c.vf / 0.7, 0, 1)
	local pitch = -lean + breath * rad(0.6) * idle - rad(2) * (c.pre + c.post) + rad(5) * c.kick
	local yaw = rad(5) * amp * s
	local roll = rad(2.5) * amp * s + sin(t * 0.7) * rad(1.2) * idle
	local tb = setBody(e, c, y, 0.12 * c.kick, pitch, yaw, roll)

	local armSwing = rad(cfg.arm or 10) * amp * s
	local aim = c.pre + c.post
	local armR = armSwing + rad(16) * aim + rad(36) * c.kick -- gun-arm kick on every shot (decays in ~0.08 s)
	local armL = -armSwing + sin(t * 1.1) * rad(1.5) * idle
	-- hit reaction: arms fly back with the jolt, flung wide on a stagger
	local jolt = c.fsz * rad(16) + c.stag * rad(42)
	armR -= jolt
	armL -= jolt
	if e.kind == "RIVET" then
		armL += rad(10) * aim -- off-hand braces
	end
	setM(e, "Arm_R", rx(armR))
	setM(e, "Arm_L", rx(armL))

	local look = sin(t * 0.6) * rad(10) * idle * (1 - aim)
	-- head snaps back on a hit (whiplash: lags the body)
	setM(e, "Head", counter(e, "Head", tb, 0.65) * ry(look + c.fsx * rad(8)) * rx(c.fsz * rad(10) + c.stag * rad(24)))
end

local function poseQuad(e: Entry, c: Ctx)
	local cfg = e.cfg :: Cfg
	local amp, ph, t = c.amp, c.ph, c.t
	local s = sin(ph)
	local idle = 1 - amp
	local aim = c.pre + c.post

	if e.kind == "COLOSSUS" then
		local extra: { [string]: CFrame }? = nil
		if c.ak == "stomp" then
			-- front legs (1, 2) rise during the wind-up and slam down on the shot
			local raise = c.pre
			extra = {
				Leg_1_Upper = rx(rad(22) * raise),
				Leg_2_Upper = rx(rad(22) * raise),
				Leg_1_Lower = rx(-rad(34) * raise),
				Leg_2_Lower = rx(-rad(34) * raise),
			}
		end
		gaitLegs(e, c, extra)
		-- heavy sway; the body dips as each diagonal pair touches down
		local dip = 0.5 * amp * max(0, -sin(2 * ph))
		local y = -dip + sin(t * 0.8) * 0.06 * idle - 1.3 * c.kick * (if c.ak == "stomp" then 1 else 0) - 0.35 * c.kick
		local pitch = rad(1.3) * amp * sin(2 * ph) - rad(1.5) * amp - rad(2.5) * c.pre * (if c.ak == "stomp" then 0 else 1)
			+ rad(3) * c.kick + sin(t * 0.5) * rad(0.4) * idle
		local roll = rad(2.8) * amp * s + sin(t * 0.37) * rad(0.7) * idle
		local yaw = rad(1.5) * amp * cos(ph) + (if c.ak == "sweep" then sin(c.t * 1.4) * rad(5) * aim else 0)
		setBody(e, c, y, 0, pitch, yaw, roll)
		return
	end

	-- BULWARK: crab walk, alternating diagonal pairs
	gaitLegs(e, c, nil)
	local y = cos(2 * ph) * (cfg.bob or 0.06) * amp + sin(t * 1.3) * 0.02 * idle
	local pitch = -rad(1.5) * amp * clamp(c.vf / 0.7, 0, 1) - rad(2) * c.pre + rad(4) * c.kick
	local roll = rad(1.4) * amp * s + sin(t * 0.6) * rad(0.6) * idle
	local tb = setBody(e, c, y, 0.5 * c.kick, pitch, rad(1.5) * amp * s, roll)
	local armKick = rad(10) * aim + rad(14) * c.kick
	setM(e, "Arm_L", rx(rad(6) * amp * s + armKick))
	setM(e, "Arm_R", rx(-rad(6) * amp * s + armKick))
	setM(e, "Shield", counter(e, "Shield", tb, 1)) -- the shield stays steady
end

local function mandibles(e: Entry, t: number, open: number)
	-- idle snapping: a quick open/close pulse every ~2 s, plus whatever the attack asks for
	local pulse = clamp(sin(t * 2.6) * 2.5 - 1.2, 0, 1)
	local o = rad(24) * max(open, pulse * 0.8)
	setM(e, "Mandible_L", ry(o))
	setM(e, "Mandible_R", ry(-o))
end

local function poseHex(e: Entry, c: Ctx)
	local cfg = e.cfg :: Cfg
	local amp, ph, t = c.amp, c.ph, c.t
	local s = sin(ph)
	local idle = 1 - amp
	local k = e.kind
	local extra: { [string]: CFrame }? = nil

	if k == "TITAN" and c.ak == "stomp" then
		extra = {
			Leg_1_Upper = rx(rad(20) * c.pre),
			Leg_2_Upper = rx(rad(20) * c.pre),
			Leg_1_Lower = rx(-rad(30) * c.pre),
			Leg_2_Lower = rx(-rad(30) * c.pre),
		}
	end
	gaitLegs(e, c, extra)

	local y, pitch, yaw, roll, z = 0, 0, 0, 0, 0
	if cfg.heavy then
		y = -0.35 * amp * max(0, -sin(2 * ph)) + sin(t * 0.9) * 0.05 * idle
		pitch = rad(1) * amp * sin(2 * ph) - rad(1) * amp
		roll = rad(2) * amp * s + sin(t * 0.45) * rad(0.6) * idle
		yaw = rad(1.2) * amp * cos(ph)
	else
		y = cos(2 * ph) * (cfg.bob or 0.05) * amp + sin(t * 1.8) * 0.015 * e.size * idle
		pitch = -rad(2) * amp * clamp(c.vf / 0.7, 0, 1) + sin(t * 1.2) * rad(0.8) * idle
		yaw = rad(6) * amp * s -- insect wiggle
		roll = rad(2.2) * amp * cos(ph) + sin(t * 0.8) * rad(0.8) * idle
	end

	if k == "SKITTER" then
		if c.ak == "leap" then
			-- coil (nose up, low), then lunge (nose down, forward)
			y -= 0.25 * c.pre
			pitch += rad(14) * c.pre - rad(30) * c.post
			z -= 0.5 * c.post
		end
		setBody(e, c, y, z, pitch, yaw, roll)
		local open = if c.ak == "leap" then max(c.pre * 0.6, c.post) else 0
		mandibles(e, t, open)
	elseif k == "SPITTER" then
		y -= 0.12 * c.pre
		pitch -= rad(5) * c.post
		setBody(e, c, y, 0, pitch, yaw, roll)
		-- neck: sways idly, rears back on the wind-up, then whips forward
		local nx = sin(t * 0.9) * rad(4) + rad(26) * c.pre - rad(22) * c.post
		local nz = sin(t * 1.3 + 1) * rad(5) * (0.4 + idle)
		local ny = sin(t * 0.7) * rad(6) * (0.4 + idle)
		setM(e, "Neck", rx(nx) * ry(ny) * rz(nz))
		setM(e, "Head", rx(-rad(10) * c.kick + sin(t * 1.9) * rad(2)))
	elseif k == "CHARGER" then
		local ram = 0
		if c.ak == "charge" then
			y -= 0.2 * c.pre
			pitch += rad(5) * c.pre - rad(6) * c.post
			ram = -rad(14) * (c.pre + c.post) -- head down
		elseif c.ak == "melee" then
			ram = rad(12) * c.pre - rad(26) * c.kick - rad(10) * c.post
			z -= 0.5 * c.post
		end
		setBody(e, c, y, z, pitch, yaw, roll)
		setM(e, "Ram", rx(ram + sin(t * 1.1) * rad(0.8) * idle))
	elseif k == "TITAN" then
		local headUp = 0
		local abd = sin(t * 1.2) * rad(2.5)
		if c.ak == "spit" then
			headUp = rad(16) * c.pre - rad(10) * c.kick
			pitch += rad(4) * c.pre
		elseif c.ak == "summon" then
			headUp = rad(20) * (c.pre + c.post)
			abd -= rad(10) * (c.pre + c.post)
			y += sin(t * 32) * 0.08 * (c.pre + c.post) -- shudder
		elseif c.ak == "stomp" then
			y -= 1.6 * c.kick
		end
		setBody(e, c, y, z, pitch, yaw, roll)
		setM(e, "Head", rx(headUp))
		setM(e, "Abdomen", rx(abd))
		local open = if c.ak == "summon" then c.pre + c.post elseif c.ak == "spit" then max(c.pre * 0.7, c.post) else 0
		mandibles(e, t, open)
	end
end

-- Legacy (non-rigged) bob/sway ------------------------------------------------------
type Profile = { bob: number, roll: number, pitch: number, yaw: number, leg: number }
local PROFILES: { [string]: Profile } = {
	TINKER = { bob = 0.16, roll = 3.2, pitch = 4, yaw = 0, leg = 2 },
	RIVET = { bob = 0.16, roll = 2.6, pitch = 3, yaw = 0, leg = 1.6 },
	BULWARK = { bob = 0.1, roll = 1.2, pitch = 1.6, yaw = 0, leg = 0.8 },
	COLOSSUS = { bob = 0.12, roll = 0.7, pitch = 0.8, yaw = 0, leg = 0 },
	SKITTER = { bob = 0.06, roll = 3, pitch = 0, yaw = 7, leg = 3 },
	SPITTER = { bob = 0.1, roll = 3, pitch = 2, yaw = 3, leg = 2 },
	CHARGER = { bob = 0.1, roll = 1.6, pitch = 2, yaw = 2, leg = 1.2 },
	TITAN = { bob = 0.15, roll = 0.9, pitch = 0.9, yaw = 0.8, leg = 0 },
}
local DEFAULT: Profile = { bob = 0.1, roll = 2, pitch = 2, yaw = 0, leg = 1 }

local function poseLegacy(e: Entry, t: number, dt: number)
	local welds = e.welds
	if not welds then
		return
	end
	local p = PROFILES[e.kind] or DEFAULT
	local mv = clamp(e.speed / (((e.def and e.def.speed) or 10) * 0.7), 0, 1)
	if e.speed > 0.3 then
		e.legacyPhase += dt * min(e.speed / e.size * 1.6, 16)
	end
	local ph = e.legacyPhase
	local idleBob = sin(t * 1.7) * 0.03 * (1 + e.size * 0.12)
	local hop = abs(sin(ph)) * p.bob * mv
	local roll = sin(ph) * rad(p.roll) * mv + sin(t * 1.1) * rad(0.5)
	local pitch = -rad(p.pitch) * mv + sin(t * 0.9) * rad(0.35)
	local yaw = sin(ph) * rad(p.yaw) * mv
	local upper = CF(0, hop + idleBob, 0) * CFrame.Angles(pitch, yaw, roll)
	local legs = CFrame.Angles(0, 0, -sin(ph) * rad(p.leg) * mv)
	for _, w in welds do
		if w.weld.Parent then
			w.weld.C0 = (if w.legs then legs else upper) * w.base
		end
	end
end

-- Main loop -------------------------------------------------------------------------
local function step(_dt: number)
	frame += 1
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	local camLook = cam.CFrame.LookVector
	local now = os.clock()
	local maxDist = if quality < 0.5 then 100 else 160
	for model, e in entries do
		if not model.Parent then
			for _, c in e.conns do
				c:Disconnect()
			end
			if e.hl then
				e.hlToken += 1
				e.hl = nil
				hlLive -= 1
			end
			entries[model] = nil
			continue
		end
		local root = e.root
		local pos = root.Position
		local toCam = pos - camPos
		local d = toCam.Magnitude
		if d > maxDist + e.radius then
			-- out of budget: forget the motion so we do not see one huge step on re-entry
			e.lastPos = pos
			e.lastMoveT = now
			e.lastUpd = now
			e.vel = Vector3.zero
			e.velTarget = Vector3.zero
			continue
		end
		-- far ones update at 15 Hz
		if d > 70 and now < e.nextT then
			continue
		end
		e.nextT = now + (if d > 70 then 1 / 15 else 0)

		-- rigged but motors not all there yet (streaming): keep looking for a while
		if (e.rigged and (e.motorCount < e.expected) or (not e.rigged and not e.welds)) and e.tries < 10 and now >= e.nextTry then
			e.tries += 1
			e.nextTry = now + 0.5
			collect(e)
		end
		if e.rigged and not e.motors.Body then
			continue
		end
		if not e.rigged and not e.welds then
			continue
		end

		local dt = clamp(now - e.lastUpd, 1 / 240, 0.1)
		e.lastUpd = now

		-- velocity from replicated position changes (the replicated root steps at the network rate, so measure over the
		-- time between steps and smooth)
		local delta = Vector3.new(pos.X - e.lastPos.X, 0, pos.Z - e.lastPos.Z)
		if delta.Magnitude > 0.002 then
			local dtc = max(now - e.lastMoveT, 0.03)
			e.velTarget = delta / dtc
			e.lastMoveT = now
			e.lastPos = pos
		elseif now - e.lastMoveT > 0.3 then
			e.velTarget = Vector3.zero
		end
		e.vel = e.vel:Lerp(e.velTarget, min(1, dt * 10))
		e.speed = e.vel.Magnitude

		-- charger dust trail: kicked up behind it while the charge runs (after the wind-up), throttled, near the camera only
		local atk = e.atk
		if atk and atk.kind == "charge" and d < 110 and e.speed > 12 and FxRef and FxRef.burst then
			local age = now - atk.t0
			if age > atk.windup and age < atk.windup + 3 and now >= (e.dustT or 0) then
				e.dustT = now + (if quality < 0.75 then 0.16 else 0.09)
				local back = pos - e.vel.Unit * e.size * 0.8
				local gp = if FxRef.groundAt then FxRef.groundAt(back, 3, 8) else nil
				FxRef.burst("dust", (gp or back) + Vector3.new(0, 0.6, 0), 3, { scale = clamp(e.size * 0.45, 1, 2.5), speed = 0.8 })
			end
		end
		local rcf = root.CFrame
		local look = rcf.LookVector
		local yawNow = math.atan2(-look.X, -look.Z)
		local turn = wrapPi(yawNow - e.lastYaw) / dt
		e.lastYaw = yawNow
		e.turn += (turn - e.turn) * min(1, dt * 6)

		local def = e.def
		local topSpeed = (def and def.speed) or 10
		-- how hard the legs work: walking speed, or turning on the spot
		local drive = max(e.speed, min(abs(e.turn) * e.size * 0.5, topSpeed * 0.5))
		local ampTarget = clamp(drive / (topSpeed * 0.45), 0, 1)
		if drive < 0.25 then
			ampTarget = 0
		end
		e.amp += (ampTarget - e.amp) * min(1, dt * 8)
		local cfg = e.cfg
		if cfg and e.rigged then
			local strideLen = cfg.stride * max(0.4, e.amp)
			local rate = min(drive / strideLen, cfg.maxHz) * 2 * PI
			if drive >= 0.25 then
				e.phase += rate * dt
			end
		end

		-- off screen: motion tracking only
		local offscreen = false
		if d > e.radius then
			local cosA = toCam:Dot(camLook) / d
			if cosA < cos(min(2.0, 1.1 + e.radius / d)) then
				offscreen = true
			end
		end
		if offscreen then
			continue
		end

		local t = now + e.seed
		if not e.rigged then
			poseLegacy(e, t, dt)
			continue
		end
		if not cfg then
			continue
		end

		local lv = rcf:VectorToObjectSpace(e.vel)
		local vf = clamp(-lv.Z / topSpeed, -1, 1)
		local pre, kick, post, ak = attackEnv(e, now)
		-- hit-reaction spring (semi-implicit Euler, sub-stepped: stable for any frame time)
		local fsc = clamp(3 / e.size, 0.3, 1)
		if e.sx ~= 0 or e.sz ~= 0 or e.svx ~= 0 or e.svz ~= 0 or e.syaw ~= 0 or e.svyaw ~= 0 then
			local steps = math.ceil(dt / 0.012)
			local h = dt / steps
			local svx, svz, svyaw = clamp(e.svx, -70, 70), clamp(e.svz, -70, 70), clamp(e.svyaw, -40, 40)
			local sx, sz, syaw = e.sx, e.sz, e.syaw
			for _ = 1, steps do
				svx += (-SPRING_K * sx - SPRING_C * svx) * h
				svz += (-SPRING_K * sz - SPRING_C * svz) * h
				svyaw += (-SPRING_K * syaw - SPRING_C * svyaw) * h
				sx = clamp(sx + svx * h, -MAX_DISP, MAX_DISP)
				sz = clamp(sz + svz * h, -MAX_DISP, MAX_DISP)
				syaw = clamp(syaw + svyaw * h, -MAX_DISP, MAX_DISP)
			end
			if abs(sx) + abs(sz) + abs(syaw) + abs(svx) * 0.05 + abs(svz) * 0.05 + abs(svyaw) * 0.05 < 0.004 then
				sx, sz, syaw, svx, svz, svyaw = 0, 0, 0, 0, 0, 0
			end
			e.sx, e.sz, e.syaw, e.svx, e.svz, e.svyaw = sx, sz, syaw, svx, svz, svyaw
		end
		local stag = 0
		local stAge = now - e.stagT
		if stAge < e.stagDur then
			local u = stAge / e.stagDur
			-- fast snap in (first 15 %), eased recovery
			stag = (if u < 0.15 then u / 0.15 else (1 - (u - 0.15) / 0.85) ^ 2) * e.stagK
		end
		local sp = max(e.speed, 0.01)
		local c: Ctx = {
			t = t,
			dt = dt,
			amp = e.amp,
			ph = e.phase,
			vf = vf,
			fw = 0.4 + 0.6 * clamp(abs(-lv.Z) / sp, 0, 1),
			pre = pre,
			kick = kick,
			post = post,
			ak = ak,
			fsx = e.sx * fsc,
			fsz = e.sz * fsc,
			fyaw = e.syaw * fsc,
			stag = stag,
			fs = fsc,
		}
		if cfg.type == "biped" then
			poseBiped(e, c)
		elseif cfg.type == "quad" then
			poseQuad(e, c)
		else
			poseHex(e, c)
		end
	end
end

local function start(Fx: any)
	if conn then
		return
	end
	FxRef = Fx
	if Fx and Fx.register then
		Fx.register("Death", onDeathNote)
	end
	quality = if Fx and type(Fx.quality) == "number" then Fx.quality else 1
	conn = RunService.RenderStepped:Connect(step)
	task.spawn(function()
		local folder = Workspace:WaitForChild("Enemies", 120)
		if not folder then
			return
		end
		for _, m in folder:GetChildren() do
			track(m)
		end
		folder.ChildAdded:Connect(function(m)
			task.defer(track, m)
		end)
		folder.ChildRemoved:Connect(untrack)
	end)
end

function EnemyAnim.init(Fx: any, _Audio: any, _Juice: any)
	start(Fx)
	Fx.enemyHit = EnemyAnim.hitNear -- Fx.impact calls this for every bullet that lands on an enemy
end

return EnemyAnim
