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
-- Behaviour: hover `def.drone.hover` studs above whatever is below (terrain or roofs), bob, jink sideways at random, orbit
-- the nearest trooper inside HARASS range and plink at them; with nobody close, patrol: drift towards a random trooper's
-- area or around the foundry. Stun / Cryo freeze (FrozenUntil) drop them low and stop the guns; burn ticks like EnemyAI.
-- Studio A/B Feel_DroneAim: nil = loose cone (AIM.loose), "tight" = AIM.tight with a little lead.
-- Model attribute Drone = "COG" | "BROOD": client/Fx/EnemyFx.luau adds rotor blur / wing flutter locally.

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local DroneAI = {}

local S: { [string]: any } = {}
local drones: { [any]: boolean } = {}
local rng = Random.new()

local MAP_HALF = Config.MapSize / 2 - 6
local THINK = 0.2
local HARASS = 110 -- studs: picks a trooper inside this range (x1.5 once hit)
local ORBIT = { 13, 22 } -- distance band kept from the target
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

function DroneAI.build(kindId: string, enemyId: number): (Model, any)
	local brood = kindId == "SPOREMITE"
	local model = Instance.new("Model")
	model.Name = kindId
	model:SetAttribute("EnemyId", enemyId)
	model:SetAttribute("Kind", kindId)
	model:SetAttribute("Drone", if brood then "BROOD" else "COG")

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
	drones[e] = true
end

function DroneAI.unregister(e: any)
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

	-- target: nearest trooper in harass range (wider once something hit it); the one who hit it last wins a close call
	local range = HARASS * (if e.alerted then 1.5 else 1)
	local best: Target? = nil
	local bestD = range
	for _, t in targets do
		local d = (t.pos - e.pos).Magnitude
		if t.p == e.lastHitBy then
			d *= 0.7
		end
		if d < bestD then
			best = t
			bestD = d
		end
	end
	e.dTarget = best

	if not best then
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
	local hoverY = e.groundY + (if stunned then 3 else e.hover)

	local want = Vector3.zero
	if not stunned then
		local mul = 1
		local slow = e.status.slow
		if slow then
			mul = 1 - math.clamp(slow.mag or 0.5, 0, 0.9)
		end
		local speed = def.speed * mul
		local dest: Vector3? = nil
		if t then
			e.orbitA += dt * 0.7 * e.orbitSign
			dest = t.pos + Vector3.new(math.cos(e.orbitA), 0, math.sin(e.orbitA)) * e.orbitR
		else
			dest = e.goal
		end
		if dest then
			local d = flat(dest - e.pos)
			if d.Magnitude > 0.5 then
				want = d.Unit * math.min(speed, d.Magnitude * 1.5)
			end
		end
		want += e.jink * speed * 0.6
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
	if t and not stunned and now >= e.nextShot then
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
	local face = if t then flat(t.pos - e.pos) else flat(e.vel)
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
