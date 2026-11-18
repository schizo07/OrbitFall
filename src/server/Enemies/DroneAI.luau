-- Flying drones (Data/Enemies entries with `drone`: DRONE_COG, SPOREMITE), launched by the Drone Foundry side objective
-- (server/Objectives/SideFoundry.luau). Not a service: EnemyService routes drone kinds here instead of EnemyModels / EnemyAI
-- (every call site is marked "-- DRONE hook" there). Hits, blasts, statuses, kills and the feed all stay in EnemyService.
--
--   DroneAI.build(kindId, enemyId) -> (Model, Rig)    small Part-built model; root = invisible part, body above it
--   DroneAI.register(e, cf, opts) / DroneAI.unregister(e)
--   DroneAI.step(dt)                                   every Heartbeat (EnemyService)
--   DroneAI.knock(e, from, power)                      blast reaction (EnemyService.blastReact)
--   DroneAI.push(e, velocity, dur)                     outside push (Gravity Well)
--   DroneAI.clear(), DroneAI.init(S)
--
-- Behaviour: hover `def.drone.hover` studs above whatever is below (terrain or roofs), bob, jink sideways at random.
-- Awareness (Enemies/Awareness.luau) decides when a drone notices the squad, like ground units: until then it hover-patrols
-- slowly round its home (or follows Awareness' investigate / search / patrol moves). Taking damage alerts it.
-- Alert: a cycle of attack runs on its target (the Awareness target, else the nearest trooper inside HARASS range):
--   orbit (circle at ORBIT range, shooting) -> strafing pass (flies past one side of the target and out the far side, shooting
--   on the way in) -> break (pulls away and up, no shooting) -> orbit or another pass. No target for LOST_T s => Awareness.lost.
-- Without the Awareness module it falls back to the old harass: always alert, patrol towards a random trooper's area.
-- Stun / Cryo freeze (FrozenUntil) drop them low and stop the guns; burn ticks like EnemyAI.
-- Studio A/B Feel_DroneAim: nil = loose cone (AIM.loose), "tight" = AIM.tight with a little lead.
-- Model attribute Drone = "COG" | "BROOD": client/Fx/EnemyFx.luau adds rotor blur / wing flutter locally.

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Assets = require(script.Parent.Parent.World.Assets)

-- optional: drones keep the old always-hunting behaviour if the module is missing
local Awareness: any = nil
do
	local mod = script.Parent:FindFirstChild("Awareness")
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(require, mod)
		if ok and type(m) == "table" then
			Awareness = m
		else
			warn("[DroneAI] Awareness failed to load:", m)
		end
	end
end

local DroneAI = {}

local S: { [string]: any } = {}
local drones: { [any]: boolean } = {}
local rng = Random.new()

local MAP_HALF = Config.MapSize / 2 - 6
local THINK = 0.2
local HARASS = 110 -- studs: picks a trooper inside this range (x1.5 once hit)
local ORBIT = { 13, 22 } -- distance band kept from the target
-- attack runs (alert): seconds per mode, pass geometry, break geometry
local RUN = {
	orbit = { 2.5, 4.5 },
	passMax = 4, -- give up a pass after this long
	passSide = { 6, 10 }, -- studs to the side of the target the pass line goes by
	passOut = 22, -- the pass ends this far beyond the target
	passSpeed = 1.35, -- x def.speed
	breakT = { 1.2, 2.2 },
	breakDist = { 32, 45 },
	breakRise = 4, -- extra hover height while breaking away
	idleSpeed = 0.45, -- x def.speed for the home hover-patrol
	idleRing = { 18, 45 }, -- hover-patrol points around home
}
local LOST_T = 6 -- alert with no target this long => Awareness.lost
local SPIT_G = 30
local FAR_PIVOT = 250 -- further than this from every trooper: model written every 4th frame
local AIM = {
	loose = { spread = 6.5, lead = 0 },
	tight = { spread = 2.2, lead = 0.5 },
}
local ROBOT_BOLT = Color3.fromRGB(255, 84, 58)

local envParams = RaycastParams.new() -- world only (no enemies, no characters)
envParams.FilterType = Enum.RaycastFilterType.Exclude
envParams.RespectCanCollide = true
envParams.IgnoreWater = true
local lastFilter = 0

local function rebuildFilter()
	local list: { Instance } = {}
	local f = workspace:FindFirstChild("Enemies")
	if f then
		table.insert(list, f)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	envParams.FilterDescendantsInstances = list
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function clampMap(p: Vector3): Vector3
	return Vector3.new(math.clamp(p.X, -MAP_HALF, MAP_HALF), p.Y, math.clamp(p.Z, -MAP_HALF, MAP_HALF))
end

local function spreadDir(dir: Vector3, deg: number): Vector3
	if deg <= 0 then
		return dir
	end
	local cf = CFrame.lookAt(Vector3.zero, dir)
	local r = math.rad(deg) * math.sqrt(rng:NextNumber())
	local a = rng:NextNumber(0, math.pi * 2)
	return (cf * CFrame.Angles(math.sin(a) * r, math.cos(a) * r, 0)).LookVector
end

-- Model ------------------------------------------------------------------------------------------
local GUNMETAL = Color3.fromRGB(72, 78, 90)
local DARKMETAL = Color3.fromRGB(44, 47, 57)
local EYE_RED = Color3.fromRGB(255, 40, 36)
local PURPLE = Color3.fromRGB(110, 62, 140)
local DARKPURPLE = Color3.fromRGB(58, 34, 82)
local SPORE = Color3.fromRGB(150, 255, 90)

local GNAT_GLOW = Color3.fromRGB(235, 34, 24) -- same deep red as EnemyModels' COG glow fix (bloom washes lighter reds out)
local ROTOR_SPIN = 20 -- rad/s; written to the rotor joints, so it replicates: slow enough not to strobe at the network rate

-- Gnat drone from the gnat_cog kit mesh (Blender model frame, root at the origin): Body / Eye / Glow welded, brass RotorL / RotorR on
-- Motor6Ds at their manifest pivots (the spin is written to C0 in update). Parts are parented only at the end, so a failure leaves
-- the model untouched for the part-built fallback. Returns the rotor list.
local function buildGnatMesh(model: Model, root: BasePart, enemyId: number, tpl: Model): { any }
	local byName: { [string]: BasePart } = {}
	for _, d in tpl:GetChildren() do
		if d:IsA("BasePart") then
			byName[d.Name] = d
		end
	end
	assert(byName.Body and byName.Eye, "gnat_cog is missing Body / Eye")
	tpl:PivotTo(CFrame.new())
	local rotors = {}
	for name, part in byName do
		local role = part:GetAttribute("Role")
		part.Anchored = false
		part.CanCollide = false
		part.CanTouch = false
		part.Massless = true
		part.CanQuery = role ~= "glow"
		part:SetAttribute("EnemyId", enemyId)
		part:SetAttribute("Zone", if name == "Eye" then "eye" else "body")
		if part.Material == Enum.Material.Neon then
			part.Color = GNAT_GLOW
		end
		local parentPart = if name == "Body" then root else byName.Body
		if string.sub(name, 1, 5) == "Rotor" then
			local j = CFrame.new(Assets.pivot("gnat_cog", name) or part.Position)
			local m = Instance.new("Motor6D")
			m.Name = name
			m.Part0 = parentPart
			m.Part1 = part
			m.C0 = parentPart.CFrame:Inverse() * j
			m.C1 = part.CFrame:Inverse() * j
			m.Parent = part
			table.insert(rotors, { motor = m, c0 = m.C0, dir = if name == "RotorL" then 1 else -1 })
		else
			local w = Instance.new("Weld")
			w.Name = "W_" .. name
			w.Part0 = parentPart
			w.Part1 = part
			w.C0 = parentPart.CFrame:Inverse() * part.CFrame
			w.C1 = CFrame.new()
			w.Parent = part
		end
	end
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 120, 90)
	light.Range = 8
	light.Brightness = 0.9
	light.Shadows = false
	light.Parent = byName.Eye
	for _, part in byName do
		part.Parent = model
	end
	tpl:Destroy()
	return rotors
end

function DroneAI.build(kindId: string, enemyId: number): (Model, any)
	local brood = kindId == "SPOREMITE"
	local model = Instance.new("Model")
	model.Name = kindId
	model:SetAttribute("EnemyId", enemyId)
	model:SetAttribute("Kind", kindId)
	if brood then
		model:SetAttribute("Drone", "BROOD")
	end

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

	local function add(name: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material, zone: string?, shape: Enum.PartType?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = mat
		p.Shape = shape or Enum.PartType.Block
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = zone ~= nil
		p.CastShadow = false
		if zone then
			p:SetAttribute("EnemyId", enemyId)
			p:SetAttribute("Zone", zone)
		end
		p.Parent = model
		return p
	end
	local BALL = Enum.PartType.Ball
	local CYL = Enum.PartType.Cylinder

	if not brood then
		-- mesh gnat first; no attribute Drone on it, so the client does not add the old blur discs over the new brass rotors
		local tpl = Assets.get("gnat_cog")
		if tpl then
			local ok, rotors = pcall(buildGnatMesh, model, root, enemyId, tpl)
			if ok then
				return model, { legs = {}, bob = 0, rotors = rotors }
			end
			warn("[DroneAI] gnat mesh build failed:", rotors)
			tpl:Destroy()
		end
		model:SetAttribute("Drone", "COG")
	end

	if brood then
		-- puffy mite: round body, glowing spore sac underneath at the back, dangling legs; Wing* = flutter anchors
		add("Body", Vector3.new(2.3, 2.3, 2.3), CFrame.new(0, 1.2, 0), PURPLE, Enum.Material.SmoothPlastic, "body", BALL)
		add("Head", Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, 1.3, -1.2), DARKPURPLE, Enum.Material.SmoothPlastic, "body", BALL)
		local sac = add("Sac", Vector3.new(1.4, 1.4, 1.4), CFrame.new(0, 0.55, 0.6), SPORE, Enum.Material.Neon, "sac", BALL)
		local l = Instance.new("PointLight")
		l.Color = Color3.fromRGB(200, 255, 170)
		l.Range = 8
		l.Brightness = 0.8
		l.Shadows = false
		l.Parent = sac
		for _, sx in { -1, 1 } do
			add("Leg", Vector3.new(0.2, 1.2, 0.2), CFrame.new(sx * 0.5, 0.2, -0.5) * CFrame.Angles(0.3, 0, sx * 0.25), DARKPURPLE, Enum.Material.SmoothPlastic, "body")
			add("Wing" .. (if sx < 0 then "L" else "R"), Vector3.new(0.3, 0.3, 0.3), CFrame.new(sx * 0.9, 2.1, 0.1), DARKPURPLE, Enum.Material.SmoothPlastic, nil)
		end
	else
		-- rotor gnat: ball body, red eye up front, cross arm with two rotor hubs (Rotor* = blur anchors), gun under the chin
		add("Body", Vector3.new(2.3, 2.3, 2.3), CFrame.new(0, 1.2, 0), GUNMETAL, Enum.Material.Metal, "body", BALL)
		add("Band", Vector3.new(0.5, 2.5, 2.5), CFrame.new(0, 1.2, 0) * CFrame.Angles(0, 0, math.pi / 2), DARKMETAL, Enum.Material.Metal, "body", CYL)
		local eye = add("Eye", Vector3.new(0.9, 0.9, 0.9), CFrame.new(0, 1.3, -1.05), EYE_RED, Enum.Material.Neon, "eye", BALL)
		local l = Instance.new("PointLight")
		l.Color = Color3.fromRGB(255, 120, 90)
		l.Range = 8
		l.Brightness = 0.9
		l.Shadows = false
		l.Parent = eye
		add("Arm", Vector3.new(3.6, 0.3, 0.45), CFrame.new(0, 2.2, 0), DARKMETAL, Enum.Material.Metal, "body")
		for _, sx in { -1, 1 } do
			add("Rotor" .. (if sx < 0 then "L" else "R"), Vector3.new(0.5, 0.9, 0.9), CFrame.new(sx * 1.8, 2.35, 0) * CFrame.Angles(0, 0, math.pi / 2), DARKMETAL, Enum.Material.Metal, "body", CYL)
		end
		add("Gun", Vector3.new(0.3, 0.3, 1.1), CFrame.new(0, 0.3, -0.6), DARKMETAL, Enum.Material.Metal, "body")
	end
	return model, { legs = {}, bob = 0 }
end

-- Registry ---------------------------------------------------------------------------------------
local function groundBelow(p: Vector3): number?
	local r = workspace:Raycast(p + Vector3.new(0, 4, 0), Vector3.new(0, -160, 0), envParams)
	return r and r.Position.Y or nil
end

function DroneAI.register(e: any, cf: CFrame, opts: any)
	local now = workspace:GetServerTimeNow()
	local band = e.def.drone and e.def.drone.hover or { 8, 14 }
	e.drone = true
	e.pos = cf.Position
	e.vel = Vector3.zero
	local look = cf.LookVector
	e.yaw = math.atan2(-look.X, -look.Z)
	e.hover = rng:NextNumber(band[1], band[2])
	e.groundY = groundBelow(e.pos) or (e.pos.Y - e.hover)
	e.home = (opts and opts.home) or e.pos
	e.goal = nil
	e.goalUntil = 0
	e.dTarget = nil
	e.orbitA = rng:NextNumber(0, math.pi * 2)
	e.orbitSign = if rng:NextNumber() < 0.5 then -1 else 1
	e.orbitR = rng:NextNumber(ORBIT[1], ORBIT[2])
	e.jink = Vector3.zero
	e.nextJink = now
	e.nextThink = now + rng:NextNumber(0, THINK)
	e.nextShot = now + rng:NextNumber(1, 2.5)
	e.bobPhase = rng:NextNumber(0, math.pi * 2)
	e.spinUntil = 0
	e.beat = rng:NextInteger(0, 3)
	e.runMode = "orbit"
	e.runUntil = now + rng:NextNumber(RUN.orbit[1], RUN.orbit[2])
	e.passDir = nil
	e.passOff = nil
	e.breakDir = nil
	e.noTargetSince = nil
	e.dAlert = Awareness == nil
	e.dLastHp = e.hp
	e.idleDir = nil
	e.idleSpeed = 0
	e.idleFace = nil
	if Awareness then
		local o = opts or {}
		Awareness.register(e, {
			posture = o.posture,
			route = o.route,
			squad = o.squad,
			home = e.home,
			aggro = o.aggro,
			target = o.target,
		})
	end
	drones[e] = true
end

function DroneAI.unregister(e: any)
	if Awareness then
		Awareness.unregister(e)
	end
	drones[e] = nil
	e.dTarget = nil
	e.push = nil
end

function DroneAI.clear()
	table.clear(drones)
end

function DroneAI.knock(e: any, from: Vector3, power: number)
	if not e.alive or not e.pos then
		return
	end
	local d = e.pos - from
	local dir = if d.Magnitude > 0.05 then d.Unit else Vector3.yAxis
	local p = math.clamp(power, 0, 1.6)
	e.vel += dir * 38 * p + Vector3.new(0, 10 * p, 0)
	e.spinUntil = workspace:GetServerTimeNow() + 0.5 * p
end

function DroneAI.push(e: any, velocity: Vector3, dur: number)
	if not e.alive or dur <= 0 then
		return
	end
	e.push = { v = velocity, untilT = workspace:GetServerTimeNow() + dur }
end

-- Think ------------------------------------------------------------------------------------------
type Target = { p: Player, pos: Vector3, vel: Vector3 }
local targets: { Target } = {}

local function think(e: any, now: number)
	local last = e.lastThink or now
	e.lastThink = now
	for name, st in e.status do
		if st.untilT <= now then
			e.status[name] = nil
		end
	end
	local burn = e.status.burn
	if burn then
		S.Enemies.damage(e, (burn.mag or 15) * (now - last), 6, burn.source or { kind = "callin" }, "body")
		if not e.alive then
			return
		end
	end
	local fz = e.model:GetAttribute("FrozenUntil")
	e.frozenUntil = if type(fz) == "number" then fz else nil

	e.groundY = groundBelow(e.pos) or e.groundY

	-- awareness: damage alerts it; otherwise Awareness decides when it notices the squad
	if Awareness then
		if e.hp < (e.dLastHp or e.hp) then
			Awareness.alert(e, e.lastHitBy, nil, "damage")
		end
		e.dLastHp = e.hp
		Awareness.sense(e, now)
		e.dAlert = Awareness.isAlert(e)
	end

	if not e.dAlert then
		e.dTarget = nil
		e.noTargetSince = nil
		local wish, mul, face = Awareness.idle(e, now)
		e.idleDir = wish
		e.idleSpeed = mul or 0
		e.idleFace = face
		if not wish and (not e.goal or now > e.goalUntil or flat(e.goal - e.pos).Magnitude < 6) then
			-- hover-patrol: slow loop between points round home
			local a = rng:NextNumber(0, math.pi * 2)
			e.goal = clampMap(e.home + Vector3.new(math.cos(a), 0, math.sin(a)) * rng:NextNumber(RUN.idleRing[1], RUN.idleRing[2]))
			e.goalUntil = now + rng:NextNumber(8, 14)
		end
	else
		e.idleDir = nil
		e.idleFace = nil
	end

	-- target: the trooper Awareness is after if in reach, else the nearest in harass range (wider once something hit it);
	-- the one who hit it last wins a close call
	local range = HARASS * (if e.alerted then 1.5 else 1)
	local best: Target? = nil
	local bestD = range
	if e.dAlert then
		local want = e.awareTarget
		for _, t in targets do
			local d = (t.pos - e.pos).Magnitude
			if t.p == e.lastHitBy then
				d *= 0.7
			end
			if want ~= nil and t.p == want and d < range then
				d = 0
			end
			if d < bestD then
				best = t
				bestD = d
			end
		end
	end
	if best ~= e.dTarget and best then
		-- a fresh target starts with an orbit
		e.runMode = "orbit"
		e.runUntil = now + rng:NextNumber(RUN.orbit[1], RUN.orbit[2])
	end
	e.dTarget = best
	if best then
		e.noTargetSince = nil
		local d = flat(best.pos - e.pos)
		local dist = d.Magnitude
		-- attack run cycle: orbit -> pass -> break -> orbit / pass
		if e.runMode == "pass" then
			local beyond = (e.pos - best.pos):Dot(e.passDir)
			if beyond > RUN.passOut or now >= e.runUntil then
				e.runMode = "break"
				e.runUntil = now + rng:NextNumber(RUN.breakT[1], RUN.breakT[2])
				local a = rng:NextNumber(-1.2, 1.2)
				e.breakDir = CFrame.Angles(0, a, 0) * e.passDir
			end
		elseif now >= e.runUntil then
			if e.runMode == "break" and rng:NextNumber() < 0.5 then
				e.runMode = "orbit"
				e.runUntil = now + rng:NextNumber(RUN.orbit[1], RUN.orbit[2])
				e.orbitA = math.atan2(e.pos.Z - best.pos.Z, e.pos.X - best.pos.X)
				e.orbitR = rng:NextNumber(ORBIT[1], ORBIT[2])
			else
				e.runMode = "pass"
				e.runUntil = now + RUN.passMax
				local through = if dist > 1 then d / dist else Vector3.new(1, 0, 0)
				e.passDir = through
				local side = if rng:NextNumber() < 0.5 then 1 else -1
				e.passOff = Vector3.new(-through.Z, 0, through.X) * side * rng:NextNumber(RUN.passSide[1], RUN.passSide[2])
			end
		end
	elseif e.dAlert and Awareness then
		e.noTargetSince = e.noTargetSince or now
		if now - e.noTargetSince > LOST_T then
			e.noTargetSince = now
			Awareness.lost(e, now)
		end
	end

	if not best and not Awareness then
		-- patrol: drift towards a random trooper's area (so drones find the squad across the map) or loop around the foundry
		if not e.goal or now > e.goalUntil or flat(e.goal - e.pos).Magnitude < 8 then
			local g: Vector3
			if #targets > 0 and rng:NextNumber() < 0.6 then
				local t = targets[rng:NextInteger(1, #targets)]
				local a = rng:NextNumber(0, math.pi * 2)
				g = t.pos + Vector3.new(math.cos(a), 0, math.sin(a)) * rng:NextNumber(30, 70)
			else
				local a = rng:NextNumber(0, math.pi * 2)
				g = e.home + Vector3.new(math.cos(a), 0, math.sin(a)) * rng:NextNumber(20, 140)
			end
			e.goal = clampMap(g)
			e.goalUntil = now + rng:NextNumber(10, 18)
		end
	end

	-- erratic sideways jinks
	if now >= e.nextJink then
		e.nextJink = now + rng:NextNumber(0.35, 0.9)
		local a = rng:NextNumber(0, math.pi * 2)
		e.jink = Vector3.new(math.cos(a), rng:NextNumber(-0.35, 0.35), math.sin(a)) * rng:NextNumber(0.4, 1)
		if rng:NextNumber() < 0.25 then
			e.orbitSign = -e.orbitSign
		end
	end
end

local function fire(e: any, t: Target)
	local def = e.def
	local atk = def.attacks[1]
	if not atk then
		return
	end
	local cf = e.model:GetPivot()
	local from = (cf * CFrame.new(0, 0.4, -1.3)).Position -- the gun / mouth under the chin
	local mode = if workspace:GetAttribute("Feel_DroneAim") == "tight" then AIM.tight else AIM.loose
	local speed = atk.speed or 90
	if atk.kind == "spit" then
		local aimAt = t.pos + flat(t.vel) * (mode.lead + 0.3) + Vector3.new(0, -1.5, 0)
		local T = math.clamp((aimAt - from).Magnitude / speed, 0.35, 1.4)
		local miss = math.tan(math.rad(mode.spread)) * (aimAt - from).Magnitude
		local a = rng:NextNumber(0, math.pi * 2)
		aimAt += Vector3.new(math.cos(a), 0, math.sin(a)) * miss * math.sqrt(rng:NextNumber())
		S.Projectiles.fire({
			a = from,
			v = S.Projectiles.solveArc(from, aimAt, T, SPIT_G),
			g = SPIT_G,
			style = "acid",
			damage = atk.damage,
			radius = atk.radius or 3,
			hitRadius = 1.4,
			life = T + 1.2,
			kind = "acid",
			owner = e,
		})
	else
		local aimAt = t.pos + t.vel * ((t.pos - from).Magnitude / speed) * mode.lead
		local dir = (aimAt - from).Unit
		S.Projectiles.fire({
			a = from,
			v = spreadDir(dir, mode.spread) * speed,
			style = "bolt",
			c = ROBOT_BOLT,
			damage = atk.damage,
			hitRadius = 2,
			life = atk.range / speed + 0.5,
			kind = "bolt",
			owner = e,
		})
	end
end

-- Update -----------------------------------------------------------------------------------------
local function update(e: any, dt: number, now: number)
	local def = e.def
	if now >= e.nextThink then
		e.nextThink = now + THINK + rng:NextNumber(0, 0.03)
		think(e, now)
		if not e.alive then
			return
		end
	end

	local frozen = e.frozenUntil ~= nil and e.frozenUntil > now
	local stunned = e.status.stun ~= nil or frozen
	local t: Target? = e.dTarget
	local rise = if t and e.runMode == "break" then RUN.breakRise else 0
	local hoverY = e.groundY + (if stunned then 3 else e.hover + rise)

	local want = Vector3.zero
	if not stunned then
		local mul = 1
		local slow = e.status.slow
		if slow then
			mul = 1 - math.clamp(slow.mag or 0.5, 0, 0.9)
		end
		local speed = def.speed * mul
		local dest: Vector3? = nil
		local jinkMul = 0.6
		if t then
			if e.runMode == "pass" and e.passDir then
				-- aim at a point that runs ahead of the target along the pass line, so it flies past one side and out
				dest = t.pos + e.passOff + e.passDir * (RUN.passOut + 10)
				speed *= RUN.passSpeed
				jinkMul = 0.25
			elseif e.runMode == "break" and e.breakDir then
				dest = t.pos + e.breakDir * RUN.breakDist[2]
				speed *= 1.15
			else
				e.orbitA += dt * 0.7 * e.orbitSign
				dest = t.pos + Vector3.new(math.cos(e.orbitA), 0, math.sin(e.orbitA)) * e.orbitR
			end
		elseif e.dAlert and Awareness then
			dest = e.lastKnown or e.goal -- searching: hover over where the squad was last seen
		elseif e.idleDir then
			dest = e.pos + e.idleDir * 8
			speed *= math.clamp(e.idleSpeed, 0, 1)
			jinkMul = 0.25
		else
			dest = e.goal
			if Awareness then
				speed *= RUN.idleSpeed
				jinkMul = 0.25
			end
		end
		if dest then
			local d = flat(dest - e.pos)
			if d.Magnitude > 0.5 then
				want = d.Unit * math.min(speed, d.Magnitude * 1.5)
			end
		end
		want += e.jink * speed * jinkMul
	end
	local vy = math.clamp((hoverY - e.pos.Y) * 2.2, -12, 10)
	want = Vector3.new(want.X, vy + (if stunned then 0 else e.jink.Y * 4), want.Z)
	e.vel = e.vel:Lerp(want, math.min(1, dt * (if frozen then 8 else 3)))
	local push = e.push
	if push then
		if push.untilT <= now then
			e.push = nil
		else
			e.pos += push.v * dt
		end
	end
	local np = clampMap(e.pos + e.vel * dt)
	if np.Y < e.groundY + 1.5 then
		np = Vector3.new(np.X, e.groundY + 1.5, np.Z)
	end
	e.pos = np

	-- shooting
	if t and not stunned and now >= e.nextShot and e.runMode ~= "break" then
		local atk = def.attacks[1]
		local dist = (t.pos - e.pos).Magnitude
		if atk and dist <= atk.range then
			local from = e.pos + Vector3.new(0, 1.2, 0)
			local los = workspace:Raycast(from, t.pos - from, envParams) == nil
			if los then
				fire(e, t)
				e.nextShot = now + atk.cooldown * rng:NextNumber(0.8, 1.35)
			else
				e.nextShot = now + 0.4
			end
		else
			e.nextShot = now + 0.3
		end
	end

	-- facing: the target, else the way it flies; bank into sideways motion
	local face: Vector3
	if t and e.runMode ~= "break" then
		face = flat(t.pos - e.pos)
	elseif not t and e.idleFace then
		face = flat(e.idleFace)
	else
		face = flat(e.vel)
	end
	if face.Magnitude > 0.1 and not frozen then
		local wantYaw = math.atan2(-face.X, -face.Z)
		local diff = (wantYaw - e.yaw + math.pi) % (2 * math.pi) - math.pi
		e.yaw += math.clamp(diff, -6 * dt, 6 * dt)
	end

	-- model write (far drones every 4th frame)
	e.beat = (e.beat + 1) % 4
	local near = false
	for _, tt in targets do
		if (tt.pos - e.pos).Magnitude < FAR_PIVOT then
			near = true
			break
		end
	end
	if near or e.beat == 0 then
		local fwd = Vector3.new(-math.sin(e.yaw), 0, -math.cos(e.yaw))
		local right = Vector3.new(math.cos(e.yaw), 0, -math.sin(e.yaw))
		local pitch = math.clamp(-e.vel:Dot(fwd) * 0.025, -0.4, 0.4)
		local roll = math.clamp(-e.vel:Dot(right) * 0.03, -0.5, 0.5)
		if now < e.spinUntil then
			roll += (e.spinUntil - now) * 14
		end
		local bob = if frozen then 0 else math.sin(now * 3.1 + e.bobPhase) * 0.45
		local cf = CFrame.new(e.pos + Vector3.new(0, bob, 0)) * CFrame.Angles(0, e.yaw, 0) * CFrame.Angles(pitch, 0, roll)
		e.model:PivotTo(cf)
		local rotors = e.rig and e.rig.rotors
		if rotors and not frozen and e.beat % 2 == 0 then
			local a = now * ROTOR_SPIN
			for _, r in rotors do
				r.motor.C0 = r.c0 * CFrame.Angles(0, a * r.dir, 0)
			end
		end
	end
end

function DroneAI.step(dt: number)
	if next(drones) == nil or not S.Players then
		return
	end
	local now = workspace:GetServerTimeNow()
	if os.clock() - lastFilter > 1 then
		lastFilter = os.clock()
		rebuildFilter()
	end
	table.clear(targets)
	for _, p in S.Players.getAlive() do
		local root = S.Players.getRoot(p)
		if root then
			table.insert(targets, { p = p, pos = root.Position, vel = root.AssemblyLinearVelocity })
		end
	end
	for e in drones do
		if e.alive then
			update(e, dt, now)
		else
			drones[e] = nil
		end
	end
end

function DroneAI.init(s: { [string]: any })
	S = s
	rebuildFilter()
end

return DroneAI
