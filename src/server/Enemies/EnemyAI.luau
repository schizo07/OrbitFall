-- Per-enemy behaviour. Not a registered service: EnemyService requires this and drives it.
-- Think at ~10 Hz (staggered per enemy), move/animate every Heartbeat via PivotTo.
--
-- Attack kinds (Data/Enemies): bolt, burst, cannon, mortar, sweep, stomp, melee, leap, spit, charge, summon.
-- Fx sent: Bolt/BoltEnd (via Projectiles), Telegraph {shape, p, r | a, b, w, t},
--          EnemyAttack {id, kind, e, p, t, ...}, Shockwave, Shake, Breach.
-- Calls: S.Players.getAlive/getRoot/damage, S.Projectiles.fire, S.Enemies.spawn/count/damage,
--        S.CallIns.isInSmoke (optional), S.Director.onSpotted (optional).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local EnemyModels = require(script.Parent.EnemyModels)
local LumenAI = require(script.Parent.LumenAI) -- LUMEN hook: Lumen Concord attack kinds + blink / nodes

local EnemyAI = {}

local S: { [string]: any } = {}
local rng = Random.new()

-- detection radius per class (studs); x Config.Action.AggroMult (was 95 / 115 / 135 / 190 unscaled)
local AGGRO = { regular = 95, medium = 115, heavy = 135, behemoth = 190 }
for k, v in AGGRO do
	AGGRO[k] = v * Config.Action.AggroMult
end
local TURN = { regular = 7, medium = 5, heavy = 3.2, behemoth = 1.5 }
local THINK = 0.1
local NOMOVE = {
	burst = true, cannon = true, mortar = true, sweep = true, stomp = true,
	spit = true, charge = true, summon = true, melee = true, leap = true,
}
local MELEE_KINDS = { melee = true, leap = true, stomp = true, charge = true }
local MAP_HALF = Config.MapSize / 2 - 6
local ROBOT_BOLT = Color3.fromRGB(255, 84, 58)

-- Per-frame caches ------------------------------------------------------------------
type Target = { p: Player, root: BasePart, pos: Vector3, vel: Vector3 }
local targets: { Target } = {}
local tmap: { [Player]: Target } = {}
local snapshot: { any } = {}
local lastFilter = 0
local lastScreech = 0

local envParams = RaycastParams.new() -- world only (no enemies, no characters)
envParams.FilterType = Enum.RaycastFilterType.Exclude
envParams.RespectCanCollide = true
envParams.IgnoreWater = true

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

-- Helpers ----------------------------------------------------------------------------
local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function heading(yaw: number): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

local function yawOf(dir: Vector3): number
	return math.atan2(-dir.X, -dir.Z)
end

local function wrapPi(a: number): number
	return (a + math.pi) % (2 * math.pi) - math.pi
end

local function rootCF(e: any): CFrame
	return CFrame.new(e.pos) * CFrame.Angles(0, e.yaw, 0)
end

local function statusActive(e: any, name: string, now: number): boolean
	local st = e.status[name]
	return st ~= nil and st.untilT > now
end

local function inSmoke(pos: Vector3): boolean
	local ci = S.CallIns
	if ci and ci.isInSmoke then
		return ci.isInSmoke(pos) == true
	end
	return false
end

-- Ground = terrain only, so enemies walk around props instead of snapping onto spires/walls.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
groundParams.IgnoreWater = true

local function groundAt(x: number, z: number, refY: number): number
	local r = workspace:Raycast(Vector3.new(x, refY + 40, z), Vector3.new(0, -120, 0), groundParams)
	return if r then r.Position.Y else refY
end

local function clampMap(p: Vector3): Vector3
	return Vector3.new(math.clamp(p.X, -MAP_HALF, MAP_HALF), p.Y, math.clamp(p.Z, -MAP_HALF, MAP_HALF))
end

-- Director's live cap (party size + difficulty); falls back to the global cap if the Director is not loaded
local function liveCap(): number
	local dir = S.Director
	if dir and type(dir.liveCap) == "function" then
		local ok, n = pcall(dir.liveCap)
		if ok and type(n) == "number" then
			return n
		end
	end
	return Config.MaxEnemies
end

local function sendAttackFx(e: any, kind: string, t: number?, extra: { [string]: any }?)
	local data: any = { id = e.id, kind = kind, e = e.kind, p = e.pos, t = t or 0 }
	if extra then
		for k, v in extra do
			data[k] = v
		end
	end
	S.Fx.play("EnemyAttack", data)
end

local function telegraphCircle(p: Vector3, r: number, t: number)
	S.Fx.play("Telegraph", { shape = "circle", p = p + Vector3.new(0, 0.15, 0), r = r, t = t })
end

local function telegraphLine(a: Vector3, b: Vector3, w: number, t: number)
	S.Fx.play("Telegraph", { shape = "line", p = a, a = a + Vector3.new(0, 0.15, 0), b = b + Vector3.new(0, 0.15, 0), w = w, t = t })
end

local function muzzleWorld(e: any, name: string?): Vector3
	local off = EnemyModels.Offsets[e.kind]
	local o = off and off[name or "muzzle"]
	if o then
		return rootCF(e) * o
	end
	return e.pos + Vector3.new(0, e.def.size * 1.2, 0)
end

local function spreadDir(dir: Vector3, deg: number): Vector3
	if deg <= 0 then
		return dir
	end
	local cf = CFrame.lookAt(Vector3.zero, dir)
	cf = cf * CFrame.Angles(0, 0, rng:NextNumber(0, math.pi * 2)) * CFrame.Angles(math.rad(rng:NextNumber(0, deg)), 0, 0)
	return cf.LookVector
end

local function targetEntry(e: any): Target?
	if e.target then
		return tmap[e.target]
	end
	return nil
end

-- Aim with partial target leading.
local function aimPoint(from: Vector3, t: Target, speed: number, lead: number): Vector3
	local dist = (t.pos - from).Magnitude
	local flight = dist / math.max(speed, 1)
	local v = Vector3.new(t.vel.X, 0, t.vel.Z)
	return t.pos + v * flight * lead
end

local function damagePlayer(p: Player, amount: number, from: Vector3, knock: number?, kind: string?)
	S.Players.damage(p, amount, from, { knockback = knock, kind = kind or "enemy" })
end

-- Registration -----------------------------------------------------------------------
function EnemyAI.register(e: any, cf: CFrame, opts: any)
	local look = cf.LookVector
	e.pos = cf.Position
	e.yaw = yawOf(Vector3.new(look.X, 0, look.Z).Magnitude > 0.01 and look or Vector3.new(0, 0, -1))
	e.vel = Vector3.zero
	e.wish = Vector3.zero
	e.wishSpeed = 0
	e.air = 0
	e.animT = rng:NextNumber(0, 6)
	e.windupV = 0
	e.nextThink = workspace:GetServerTimeNow() + rng:NextNumber(0, THINK)
	e.gcd = 0
	e.cd = {}
	local now = workspace:GetServerTimeNow()
	for i, atk in e.def.attacks do
		e.cd[i] = now + rng:NextNumber(0.6, 1.8) + atk.cooldown * rng:NextNumber(0, 0.35)
	end
	e.home = opts.home or e.pos
	e.goal = opts.dest
	e.goalSpeed = 0.75
	e.patrol = opts.patrol == true
	e.aggro = opts.aggro == true
	e.target = opts.target
	e.strafeDir = if rng:NextNumber() < 0.5 then 1 else -1
	e.strafeUntil = 0
	e.nextWander = now + rng:NextNumber(1, 5)
	e.seenT = 0
	e.called = false
	e.needSnap = true
	e.lastSnap = e.pos
	e.stuckT = now + 1
	e.stuckPos = e.pos
	e.stuckUntil = 0
	e.lastCF = nil
	e.stepT = 0
	e.lastHitBy = nil
	e.alerted = false
	-- stop distance for melee-type units
	local melee = math.huge
	for _, atk in e.def.attacks do
		if MELEE_KINDS[atk.kind] and atk.kind ~= "charge" then
			melee = math.min(melee, atk.range)
		end
	end
	e.stopDist = if melee < math.huge then melee * 0.7 + e.def.size * 0.6 else e.def.size * 2
	if e.def.keepDistance then
		e.stopDist = nil
	end
	e.los = true
	LumenAI.register(e) -- LUMEN hook (no-op for other factions)
end

function EnemyAI.unregister(e: any)
	e.act = nil
	e.target = nil
	LumenAI.unregister(e) -- LUMEN hook
end

function EnemyAI.clear()
	table.clear(targets)
	table.clear(tmap)
	table.clear(snapshot)
end

function EnemyAI.interrupt(e: any)
	local a = e.act
	if a then
		local now = workspace:GetServerTimeNow()
		if a.idx and e.def.attacks[a.idx] then
			e.cd[a.idx] = now + e.def.attacks[a.idx].cooldown * 0.5
		end
		e.act = nil
		e.air = 0
		e.vel = Vector3.zero
	end
end

-- Attack execution -------------------------------------------------------------------
local PREP: { [string]: (any, any, any, number) -> () } = {}
local FIRE: { [string]: (any, any, any, number) -> () } = {}
local ACTIVE: { [string]: (any, any, any, number, number) -> boolean } = {}

local function shootBolt(e: any, atk: any, t: Target, spread: number)
	local from = muzzleWorld(e)
	local speed = atk.speed or 100
	local pt = aimPoint(from, t, speed, 0.65)
	local dir = (pt - from).Unit
	S.Projectiles.fire({
		a = from,
		v = spreadDir(dir, spread) * speed,
		style = "bolt",
		c = ROBOT_BOLT,
		damage = atk.damage,
		hitRadius = 2.2,
		life = atk.range / speed + 0.6,
		kind = "bolt",
		owner = e,
	})
end

-- bolt: instant single shot
FIRE.bolt = function(e, a, atk, now)
	local t = targetEntry(e)
	if t then
		shootBolt(e, atk, t, 2.5)
	end
	e.act = nil
end

-- burst: n shots spaced out
FIRE.burst = function(e, a, atk, now)
	a.phase = "active"
	a.shots = atk.count or 3
	a.nextShot = now
end
ACTIVE.burst = function(e, a, atk, dt, now)
	if now >= a.nextShot then
		local t = targetEntry(e)
		if t then
			shootBolt(e, atk, t, 3)
		end
		a.shots -= 1
		a.nextShot = now + 0.13
		if a.shots <= 0 or not t then
			e.act = nil
		end
	end
	return false
end

-- cannon: telegraphed splash at the (led) target spot
PREP.cannon = function(e, a, atk, now)
	local t = targetEntry(e)
	if not t then
		return
	end
	local from = muzzleWorld(e)
	local speed = atk.speed or 90
	local flight = (t.pos - from).Magnitude / speed
	local pt = aimPoint(from, t, speed, 0.9) -- lead only mildly: player can still dodge
	local gy = groundAt(pt.X, pt.Z, t.pos.Y)
	a.point = Vector3.new(pt.X, gy, pt.Z)
	telegraphCircle(a.point, atk.radius or 5, (atk.windup or 0.6) + flight + 0.05)
end
FIRE.cannon = function(e, a, atk, now)
	local from = muzzleWorld(e)
	local pt = a.point
	if pt then
		local dir = (pt - from).Unit
		S.Projectiles.fire({
			a = from,
			v = dir * (atk.speed or 90),
			style = "cannon",
			c = Color3.fromRGB(255, 150, 50),
			damage = atk.damage,
			radius = atk.radius or 5,
			knockback = 45,
			shake = 0.8,
			hitRadius = 1.6,
			life = 3,
			kind = "cannon",
			owner = e,
		})
	end
	e.act = nil
end

-- mortar: N arcing shells onto telegraphed circles
local MORTAR_T = 1.5
local MORTAR_G = 60
PREP.mortar = function(e, a, atk, now)
	local t = targetEntry(e)
	if not t then
		return
	end
	local n = atk.count or 3
	a.points = {}
	local base = t.pos + Vector3.new(t.vel.X, 0, t.vel.Z) * 0.8
	for k = 1, n do
		local p = base
		if k > 1 then
			local ang = rng:NextNumber(0, math.pi * 2)
			p = base + Vector3.new(math.cos(ang), 0, math.sin(ang)) * rng:NextNumber(5, 18)
		end
		p = clampMap(p)
		local gy = groundAt(p.X, p.Z, t.pos.Y)
		local gp = Vector3.new(p.X, gy, p.Z)
		a.points[k] = gp
		telegraphCircle(gp, atk.radius or 7, (atk.windup or 1.2) + (k - 1) * 0.22 + MORTAR_T)
	end
end
FIRE.mortar = function(e, a, atk, now)
	if not a.points then
		e.act = nil
		return
	end
	a.phase = "active"
	a.k = 0
	a.nextShot = now
end
ACTIVE.mortar = function(e, a, atk, dt, now)
	if now >= a.nextShot then
		a.k += 1
		local pt = a.points[a.k]
		if pt then
			local off = EnemyModels.Offsets[e.kind]
			local tube = Vector3.new(if a.k % 2 == 0 then 6 else -6, off and off.muzzle.Y or 32, 0)
			local from = rootCF(e) * tube
			S.Projectiles.fire({
				a = from,
				v = S.Projectiles.solveArc(from, pt, MORTAR_T, MORTAR_G),
				g = MORTAR_G,
				style = "mortar",
				c = Color3.fromRGB(255, 160, 60),
				damage = atk.damage,
				radius = atk.radius or 7,
				knockback = 40,
				shake = 0.9,
				hitRadius = 0.5,
				life = MORTAR_T + 1.5,
				kind = "mortar",
				owner = e,
			})
		end
		a.nextShot = now + 0.22
		if a.k >= #a.points then
			e.act = nil
		end
	end
	return false
end

-- sweep: telegraphed laser line that sweeps across an arc
local SWEEP_DUR = 2.2
local SWEEP_ARC = math.rad(70)
PREP.sweep = function(e, a, atk, now)
	local t = targetEntry(e)
	if not t then
		return
	end
	local dir = flat(t.pos - e.pos)
	dir = if dir.Magnitude > 0.1 then dir.Unit else heading(e.yaw)
	a.dir = dir
	a.sign = if rng:NextNumber() < 0.5 then 1 else -1
	a.lockFace = true
	e.faceDirOverride = dir
	local origin = muzzleWorld(e, "laser")
	local ground = Vector3.new(origin.X, e.pos.Y, origin.Z)
	local len = atk.range
	local function lineAt(ang: number)
		local d = CFrame.Angles(0, ang, 0) * dir
		telegraphLine(ground, ground + d * len, 3.2, atk.windup or 1.4)
	end
	lineAt(-a.sign * SWEEP_ARC / 2)
	lineAt(a.sign * SWEEP_ARC / 2)
	lineAt(0)
end
FIRE.sweep = function(e, a, atk, now)
	a.phase = "active"
	a.t0 = now
	a.hit = {}
	a.origin = muzzleWorld(e, "laser")
	sendAttackFx(e, "sweepBeam", SWEEP_DUR, {
		a = a.origin,
		d = a.dir,
		sw = a.sign * SWEEP_ARC / 2,
		len = atk.range,
		t0 = now,
		dur = SWEEP_DUR,
	})
end
ACTIVE.sweep = function(e, a, atk, dt, now)
	local u = (now - a.t0) / SWEEP_DUR
	if u >= 1 then
		e.act = nil
		return false
	end
	local ang = a.sign * (-SWEEP_ARC / 2 + SWEEP_ARC * u)
	local d = CFrame.Angles(0, ang, 0) * a.dir
	local o = a.origin
	local len = atk.range
	for _, t in targets do
		if not a.hit[t.p] then
			local rel = flat(t.pos - o)
			local along = rel:Dot(d)
			if along > 0 and along < len then
				local perp = (rel - d * along).Magnitude
				if perp < 2.6 and math.abs(t.pos.Y - o.Y) < 6 then
					a.hit[t.p] = true
					damagePlayer(t.p, atk.damage, o, 40, "laser")
				end
			end
		end
	end
	return false
end

-- stomp: telegraphed ground slam around the unit
PREP.stomp = function(e, a, atk, now)
	telegraphCircle(e.pos, atk.radius or 10, atk.windup or 0.8)
end
FIRE.stomp = function(e, a, atk, now)
	local r = atk.radius or 10
	for _, t in targets do
		local d = flat(t.pos - e.pos).Magnitude
		if d <= r and t.pos.Y - e.pos.Y < 8 then
			damagePlayer(t.p, atk.damage, e.pos, 60, "stomp")
		end
	end
	S.Fx.play("Shockwave", { p = e.pos, r = r })
	S.Fx.playU("Shake", { p = e.pos, mag = if e.class == "behemoth" then 2.2 else 1.2, r = 90 })
	e.act = nil
end

-- melee
FIRE.melee = function(e, a, atk, now)
	local t = targetEntry(e)
	if t then
		local d = flat(t.pos - e.pos).Magnitude - e.def.size * 0.6
		if d <= atk.range * 1.4 + 1.5 then
			damagePlayer(t.p, atk.damage, e.pos, 22, "melee")
		end
	end
	e.act = nil
end

-- leap
FIRE.leap = function(e, a, atk, now)
	local t = targetEntry(e)
	if not t then
		e.act = nil
		return
	end
	local to = t.pos + Vector3.new(t.vel.X, 0, t.vel.Z) * 0.2
	local delta = flat(to - e.pos)
	local dist = delta.Magnitude
	local maxD = atk.range * 1.35
	if dist > maxD then
		delta = delta.Unit * maxD
	end
	a.phase = "active"
	a.from = e.pos
	a.to = e.pos + delta
	a.t0 = now
	a.dur = math.clamp(delta.Magnitude / 24, 0.28, 0.55)
	a.hitDone = false
	if delta.Magnitude > 0.1 then
		e.faceDirOverride = delta.Unit
	end
end
ACTIVE.leap = function(e, a, atk, dt, now)
	local u = math.clamp((now - a.t0) / a.dur, 0, 1)
	local p = a.from:Lerp(a.to, u)
	e.pos = Vector3.new(p.X, e.pos.Y, p.Z)
	e.air = math.sin(u * math.pi) * 2.4
	e.vel = flat(a.to - a.from) / a.dur
	if u >= 1 then
		e.air = 0
		e.vel = Vector3.zero
		local t = targetEntry(e)
		if t and flat(t.pos - e.pos).Magnitude <= 5 and math.abs(t.pos.Y - e.pos.Y) < 7 then
			damagePlayer(t.p, atk.damage, e.pos, 18, "bite")
		end
		e.act = nil
		e.gcd = now + 0.35
	end
	return true
end

-- spit: acid arcs with puddles
local SPIT_G = 45
PREP.spit = function(e, a, atk, now)
	local t = targetEntry(e)
	if not t then
		return
	end
	local from = muzzleWorld(e)
	local n = atk.count or 1
	local base = t.pos + Vector3.new(t.vel.X, 0, t.vel.Z) * 0.7
	a.points = {}
	a.flights = {}
	for k = 1, n do
		local p = base
		if k > 1 then
			local ang = rng:NextNumber(0, math.pi * 2)
			p = base + Vector3.new(math.cos(ang), 0, math.sin(ang)) * rng:NextNumber(4, (atk.radius or 4) * 2.4)
		end
		p = clampMap(p)
		local gy = groundAt(p.X, p.Z, t.pos.Y)
		local gp = Vector3.new(p.X, gy, p.Z)
		local flight = math.clamp((gp - from).Magnitude / (atk.speed or 60), 0.6, 1.7) + (k - 1) * 0.1
		a.points[k] = gp
		a.flights[k] = flight
		telegraphCircle(gp, atk.radius or 4, (atk.windup or 0.4) + flight)
	end
end
FIRE.spit = function(e, a, atk, now)
	if not a.points then
		e.act = nil
		return
	end
	local from = muzzleWorld(e)
	local big = e.class == "behemoth"
	for k, gp in a.points do
		local T = a.flights[k]
		S.Projectiles.fire({
			a = from,
			v = S.Projectiles.solveArc(from, gp, T, SPIT_G),
			g = SPIT_G,
			style = "acid",
			damage = atk.damage,
			radius = atk.radius or 4,
			knockback = if big then 30 else 0,
			hitRadius = 1.6,
			life = T + 1.5,
			puddle = { r = (atk.radius or 4) * 0.9, dur = if big then 6 else 4, dps = atk.damage * 0.3 },
			shake = if big then 0.5 else 0,
			kind = "acid",
			owner = e,
		})
	end
	e.act = nil
end

-- charge: telegraphed straight dash, knockdown, self-stun after
PREP.charge = function(e, a, atk, now)
	local t = targetEntry(e)
	if not t then
		return
	end
	local dir = flat(t.pos - e.pos)
	dir = if dir.Magnitude > 0.1 then dir.Unit else heading(e.yaw)
	local len = math.min(atk.range + 10, 62)
	local origin = e.pos + Vector3.new(0, 3, 0)
	local r = workspace:Raycast(origin, dir * len, envParams)
	if r then
		len = math.max((r.Position - origin).Magnitude - e.def.size, 6)
	end
	a.dir = dir
	a.len = len
	a.lockFace = true
	e.faceDirOverride = dir
	telegraphLine(e.pos, e.pos + dir * len, e.def.size * 1.5, atk.windup or 0.9)
end
FIRE.charge = function(e, a, atk, now)
	if not a.dir then
		e.act = nil
		return
	end
	a.phase = "active"
	a.travelled = 0
	a.hit = {}
	a.noThink = true
end
ACTIVE.charge = function(e, a, atk, dt, now)
	local step = (atk.speed or 40) * dt
	local crashed = false
	local origin = e.pos + Vector3.new(0, 3, 0)
	local r = workspace:Raycast(origin, a.dir * (step + e.def.size), envParams)
	if r then
		crashed = true
	else
		e.pos = clampMap(e.pos + a.dir * step)
		a.travelled += step
	end
	e.vel = a.dir * (atk.speed or 40)
	e.faceDirOverride = a.dir
	local hitR = e.def.size * 0.9 + 1.6
	for _, t in targets do
		if not a.hit[t.p] and flat(t.pos - e.pos).Magnitude <= hitR and math.abs(t.pos.Y - e.pos.Y) < 7 then
			a.hit[t.p] = true
			damagePlayer(t.p, atk.damage, e.pos - a.dir * 3, 75, "charge")
			S.Fx.playU("Shake", { p = e.pos, mag = 1.2, r = 40 })
		end
	end
	if crashed or a.travelled >= a.len then
		e.vel = Vector3.zero
		S.Fx.playU("Shake", { p = e.pos, mag = if crashed then 1.6 else 0.6, r = 60 })
		-- exposed for a moment: dodge, then shoot the rear
		e.act = { kind = "recover", phase = "active", noMove = true, endAt = now + (if crashed then 1.8 else 1.2), noThink = false }
		e.gcd = now + 1.2
	end
	return true
end
ACTIVE.recover = function(e, a, atk, dt, now)
	if now >= a.endAt then
		e.act = nil
	end
	return false
end

-- summon: spawn Skitterlings around the caller
FIRE.summon = function(e, a, atk, now)
	local want = atk.count or 4
	local room = liveCap() - S.Enemies.count()
	local n = math.max(math.min(want, room), 0)
	for _ = 1, n do
		local ang = rng:NextNumber(0, math.pi * 2)
		local r = e.def.size + rng:NextNumber(2, 9)
		local p = clampMap(e.pos + Vector3.new(math.cos(ang) * r, 0, math.sin(ang) * r))
		p = Vector3.new(p.X, groundAt(p.X, p.Z, e.pos.Y), p.Z)
		S.Fx.play("Breach", { p = p })
		S.Enemies.spawn("SKITTER", CFrame.new(p) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), {
			aggro = true,
			target = e.target,
			patrol = true,
		})
	end
	e.act = nil
end

-- the bolt wind-up exists so clients can show the eye charge-up telegraph (client/Fx/EnemyAnim windupGlow); its cooldown
-- overlaps the wind-up (see startAttack) so the rate of fire is unchanged
local DEFAULT_WINDUP = { bolt = 0.3, burst = 0.25, melee = 0.3, summon = 1.0, leap = 0.25, stomp = 0.8, charge = 0.9 }

-- LUMEN hook: LumenAI adds needle / beam / pulse / rift to PREP/FIRE/ACTIVE using these helpers
LumenAI.install({
	PREP = PREP, FIRE = FIRE, ACTIVE = ACTIVE, NOMOVE = NOMOVE, DEFAULT_WINDUP = DEFAULT_WINDUP,
	targets = targets, targetEntry = targetEntry, muzzleWorld = muzzleWorld, aimPoint = aimPoint,
	spreadDir = spreadDir, heading = heading, envParams = envParams, groundAt = groundAt, clampMap = clampMap,
	telegraphLine = telegraphLine, telegraphCircle = telegraphCircle, damagePlayer = damagePlayer, liveCap = liveCap,
})

local function startAttack(e: any, idx: number, atk: any, now: number)
	local windup = atk.windup or DEFAULT_WINDUP[atk.kind] or 0.4
	local a: any = {
		idx = idx,
		kind = atk.kind,
		phase = "windup",
		t0 = now,
		fireAt = now + windup,
		windup = windup,
		noMove = NOMOVE[atk.kind] == true,
	}
	e.act = a
	local cdBase = if atk.kind == "bolt" and not atk.windup then math.max(atk.cooldown, windup) else windup + atk.cooldown
	e.cd[idx] = now + cdBase * rng:NextNumber(0.9, 1.15)
	e.gcd = now + windup + 0.35
	-- replicated to clients: client/Fx/EnemyAnim.luau plays the attack pose (arm recoil / lunge) on AtkSeq changes
	e.model:SetAttribute("AtkKind", atk.kind)
	e.model:SetAttribute("AtkWindup", windup)
	e.atkSeq = (e.atkSeq or 0) + 1
	e.model:SetAttribute("AtkSeq", e.atkSeq)
	local prep = PREP[atk.kind]
	if prep then
		prep(e, a, atk, now)
	end
	if e.class == "heavy" or e.class == "behemoth" then
		if atk.kind ~= "bolt" and atk.kind ~= "burst" and atk.kind ~= "melee" then
			sendAttackFx(e, atk.kind, windup)
		end
	end
end

local function runAct(e: any, dt: number, now: number): boolean
	local a = e.act
	if not a then
		return false
	end
	local atk = e.def.attacks[a.idx or 0]
	if a.phase == "windup" then
		if now >= a.fireAt then
			local fire = FIRE[a.kind]
			if fire then
				fire(e, a, atk, now)
			else
				e.act = nil
			end
		end
		return false
	end
	local h = ACTIVE[a.kind]
	if h then
		return h(e, a, atk, dt, now)
	end
	e.act = nil
	return false
end

-- Attack eligibility ---------------------------------------------------------------
local function eligible(e: any, atk: any, dist: number, aimErr: number, los: boolean, now: number): boolean
	local k = atk.kind
	local edist = dist - e.def.size * 0.6
	if k == "bolt" or k == "burst" then
		return dist <= atk.range * 0.95 and aimErr < 0.5 and los
	elseif k == "cannon" then
		return dist <= atk.range and dist >= 12 and aimErr < 0.6 and los
	elseif k == "mortar" then
		return dist <= atk.range and dist >= 25
	elseif k == "sweep" then
		return dist <= atk.range and dist >= 10 and aimErr < 0.5 and los
	elseif k == "stomp" then
		return edist <= atk.range
	elseif k == "melee" then
		return edist <= atk.range
	elseif k == "leap" then
		return dist <= atk.range + 0.5 and dist >= 1.5 and aimErr < 0.8
	elseif k == "spit" then
		return dist <= atk.range and dist >= 8
	elseif k == "charge" then
		return dist >= 14 and dist <= atk.range and aimErr < 0.35 and los
	elseif k == "summon" then
		return dist <= atk.range and S.Enemies.count() < liveCap() - 4
	end
	return LumenAI.eligible(e, atk, dist, aimErr, los, now) -- LUMEN hook: needle / beam / pulse / rift
end

-- Think ------------------------------------------------------------------------------
local function alertNearby(e: any)
	for _, o in snapshot do
		if o ~= e and o.alive and not o.aggro and o.faction == e.faction then
			if flat(o.pos - e.pos).Magnitude < 75 then -- the whole squad piles in (was 50)
				o.aggro = true
			end
		end
	end
	if e.faction == "BROOD" then
		local now = os.clock()
		if now - lastScreech > 2.5 then
			lastScreech = now
			S.Fx.playU("EnemyAttack", { id = e.id, kind = "screech", e = e.kind, p = e.pos, t = 0 })
		end
	end
end

local function pickTarget(e: any): (Target?, number)
	local best: Target? = nil
	local bestD = math.huge
	for _, t in targets do
		local d = flat(t.pos - e.pos).Magnitude
		if d < bestD then
			bestD = d
			best = t
		end
	end
	local range = AGGRO[e.class] * (if e.aggro then 2.4 else 1)
	-- sticky target
	local cur = targetEntry(e)
	if cur then
		local cd = flat(cur.pos - e.pos).Magnitude
		if cd <= bestD * 1.4 + 6 and cd <= range then
			return cur, cd
		end
	end
	if best and bestD <= range then
		return best, bestD
	end
	return nil, bestD
end

local function steer(e: any, dir: Vector3): Vector3
	-- local obstacle avoidance: raycast ahead, try deflected headings
	local h = math.min(e.def.size, 3) + 0.5
	local reach = e.def.size * 1.4 + 4
	local origin = e.pos + Vector3.new(0, h, 0)
	local function blocked(d: Vector3): boolean
		local r = workspace:Raycast(origin, d * reach, envParams)
		return r ~= nil and math.abs(r.Normal.Y) < 0.65
	end
	if not blocked(dir) then
		return dir
	end
	for _, deg in { 40, -40, 75, -75, 115, -115 } do
		local d = CFrame.Angles(0, math.rad(deg), 0) * dir
		if not blocked(d) then
			return d
		end
	end
	return -dir
end

local function separation(e: any): Vector3
	local push = Vector3.zero
	for _, o in snapshot do
		if o ~= e and o.alive then
			local delta = flat(e.pos - o.pos)
			local d = delta.Magnitude
			local minD = (e.def.size + o.def.size) * 0.9
			if d < minD then
				if d < 0.05 then
					delta = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
					d = 0.05
				end
				push += delta / d * ((minD - d) / minD)
			end
		end
	end
	return push
end

local function setWish(e: any, dir: Vector3?, speed: number, noSteer: boolean?)
	if not dir or speed <= 0 then
		e.wish = Vector3.zero
		e.wishSpeed = 0
		return
	end
	dir = flat(dir)
	if dir.Magnitude < 0.01 then
		e.wish = Vector3.zero
		e.wishSpeed = 0
		return
	end
	dir = dir.Unit
	if not noSteer then
		dir = steer(e, dir)
	end
	local sep = separation(e)
	if sep.Magnitude > 0.01 then
		dir = (dir + sep * 1.4)
		if dir.Magnitude > 0.01 then
			dir = dir.Unit
		end
	end
	e.wish = dir
	e.wishSpeed = speed
end

local function think(e: any, now: number)
	local def = e.def

	-- statuses -----------------------------------------------------------------
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
	if e.status.stun then
		setWish(e, nil, 0)
		e.faceDirOverride = nil
		return
	end

	local act = e.act
	if act and act.noThink then
		return
	end
	if e.faceDirOverride and not (act and act.lockFace) and not (act and act.phase == "active") then
		e.faceDirOverride = nil
	end

	-- confusion / smoke: lose target and wander ------------------------------------
	local confused = e.status.confuse ~= nil
	if confused or inSmoke(e.pos) then
		e.target = nil
		e.seenT = 0
		if e.act and (e.act.phase == "windup") then
			e.act = nil
		end
		if now >= (e.wanderUntil or 0) then
			e.wanderUntil = now + rng:NextNumber(0.6, 1.4)
			local ang = rng:NextNumber(0, math.pi * 2)
			e.wanderDir = Vector3.new(math.cos(ang), 0, math.sin(ang))
		end
		e.faceDir = nil
		setWish(e, e.wanderDir, 0.6)
		return
	end

	-- target -----------------------------------------------------------------------
	if e.lastHitBy and not e.aggro then
		e.aggro = true
		alertNearby(e)
	end
	local t, nearest = pickTarget(e)
	if t and not e.aggro then
		e.aggro = true
		alertNearby(e)
	end
	e.target = if t then t.p else nil

	if not t then
		e.seenT = 0
		e.faceDir = nil
		-- idle / patrol movement
		if e.patrol and #targets > 0 and (not e.goal or now > (e.goalRefresh or 0)) then
			local np = targets[1]
			local nd = math.huge
			for _, tt in targets do
				local d = flat(tt.pos - e.pos).Magnitude
				if d < nd then
					nd = d
					np = tt
				end
			end
			e.goal = np.pos
			e.goalSpeed = Config.Action.AdvanceSpeed -- full speed towards the squad (was 0.8)
			e.goalRefresh = now + 4
		end
		if e.goal then
			local to = flat(e.goal - e.pos)
			if to.Magnitude < 6 then
				e.goal = nil
				e.home = e.pos
			else
				setWish(e, to, e.goalSpeed)
				return
			end
		end
		-- idle wander around home
		if now >= e.nextWander then
			e.nextWander = now + rng:NextNumber(3, 7)
			if rng:NextNumber() < 0.55 then
				local ang = rng:NextNumber(0, math.pi * 2)
				e.wanderTo = e.home + Vector3.new(math.cos(ang), 0, math.sin(ang)) * rng:NextNumber(4, 14)
			else
				e.wanderTo = nil
			end
		end
		if e.wanderTo then
			local to = flat(e.wanderTo - e.pos)
			if to.Magnitude < 2 then
				e.wanderTo = nil
				setWish(e, nil, 0)
			else
				setWish(e, to, 0.35)
			end
		else
			setWish(e, nil, 0)
		end
		return
	end

	-- engaged -----------------------------------------------------------------------
	e.goal = nil
	local to = flat(t.pos - e.pos)
	local dist = to.Magnitude
	local dir = if dist > 0.01 then to / dist else heading(e.yaw)
	e.faceDir = dir

	-- reinforcement call after seeing a player for a few seconds
	if e.class ~= "regular" then
		e.seenT += THINK
		if e.seenT >= 3 and not e.called then
			e.called = true
			if S.Director and S.Director.onSpotted then
				S.Director.onSpotted(e)
			end
		end
	end

	-- line of sight (only ranged units care)
	if def.keepDistance then
		local from = e.pos + Vector3.new(0, math.min(def.size, 4) + 1, 0)
		local r = workspace:Raycast(from, t.pos - from, envParams)
		e.los = (r == nil)
	else
		e.los = true
	end

	-- movement decision ---------------------------------------------------------------
	local moveDir: Vector3? = nil
	local moveSpeed = 0
	local kd = def.keepDistance
	if kd then
		-- ranged units close in tighter (advance beyond 0.95 kd instead of 1.15, back off only inside 0.5 kd) and strafe
		-- faster, so they keep pressure on the squad instead of plinking from max range
		if not e.los or dist > kd * 0.95 then
			moveDir = dir
			moveSpeed = 1
		elseif dist < kd * 0.5 then
			moveDir = -dir
			moveSpeed = 0.85
		else
			if now >= e.strafeUntil then
				e.strafeUntil = now + rng:NextNumber(0.9, 2.2)
				e.strafeDir = -e.strafeDir
			end
			moveDir = Vector3.new(-dir.Z, 0, dir.X) * e.strafeDir
			moveSpeed = 0.75
		end
	else
		local stop = e.stopDist or 4
		if dist > stop then
			moveDir = dir
			moveSpeed = 1
		elseif def.class == "regular" then
			if now >= e.strafeUntil then
				e.strafeUntil = now + rng:NextNumber(0.4, 1.0)
				e.strafeDir = -e.strafeDir
			end
			moveDir = Vector3.new(-dir.Z, 0, dir.X) * e.strafeDir
			moveSpeed = 0.7
		end
	end
	-- stuck detection: wiggle out
	if now >= e.stuckT then
		if moveSpeed > 0.3 and flat(e.pos - e.stuckPos).Magnitude < def.speed * 0.25 then
			e.stuckUntil = now + 0.9
			local ang = rng:NextNumber(0, math.pi * 2)
			e.stuckDir = Vector3.new(math.cos(ang), 0, math.sin(ang))
		end
		e.stuckPos = e.pos
		e.stuckT = now + 1
	end
	if now < e.stuckUntil and e.stuckDir then
		moveDir = e.stuckDir
		moveSpeed = 0.9
	end
	setWish(e, moveDir, moveSpeed, now < e.stuckUntil)

	-- attack decision -------------------------------------------------------------------
	if e.act or now < e.gcd then
		return
	end
	local aimErr = math.abs(wrapPi(yawOf(dir) - e.yaw))
	local close: { { idx: number, atk: any } } = {}
	local far: { { idx: number, atk: any } } = {}
	for i, atk in def.attacks do
		if now >= e.cd[i] and eligible(e, atk, dist, aimErr, e.los, now) then
			if MELEE_KINDS[atk.kind] and atk.kind ~= "charge" then
				table.insert(close, { idx = i, atk = atk })
			else
				table.insert(far, { idx = i, atk = atk })
			end
		end
	end
	local pool = if #close > 0 then close else far
	if #pool > 0 then
		local pick = pool[rng:NextInteger(1, #pool)]
		startAttack(e, pick.idx, pick.atk, now)
	end
end

-- Per-frame update -------------------------------------------------------------------
local function snapGround(e: any, dt: number, force: boolean)
	local moved = flat(e.pos - e.lastSnap).Magnitude
	if not force and moved < 0.25 then
		return
	end
	e.lastSnap = e.pos
	local origin = Vector3.new(e.pos.X, e.pos.Y + 8 + e.def.size * 0.5, e.pos.Z)
	local r = workspace:Raycast(origin, Vector3.new(0, -70, 0), groundParams)
	if r then
		local gy = r.Position.Y
		if force or math.abs(gy - e.pos.Y) > 6 then
			e.pos = Vector3.new(e.pos.X, gy, e.pos.Z)
		else
			e.pos = Vector3.new(e.pos.X, e.pos.Y + (gy - e.pos.Y) * math.min(1, dt * 14), e.pos.Z)
		end
	end
end

local function update(e: any, dt: number, now: number)
	local def = e.def
	if now >= e.nextThink then
		e.nextThink = now + THINK + rng:NextNumber(0, 0.02)
		think(e, now)
		if not e.alive then
			return
		end
	end
	if e.lumen then
		LumenAI.update(e, dt, now) -- LUMEN hook: Warden blink, Spire nodes, shield drop on stun
	end

	local overridden = runAct(e, dt, now)
	if not e.alive then
		return
	end

	local stunned = statusActive(e, "stun", now)
	local a = e.act
	local noMove = stunned or (a ~= nil and a.noMove == true)

	if not overridden then
		local target = Vector3.zero
		if not noMove and e.wishSpeed > 0 then
			local mul = 1
			local slow = e.status.slow
			if slow and slow.untilT > now then
				mul = 1 - math.clamp(slow.mag or 0.5, 0, 0.9)
			end
			target = e.wish * (def.speed * e.wishSpeed * mul)
		end
		e.vel = e.vel:Lerp(target, math.min(1, dt * (if noMove then 10 else 6)))
		if e.vel.Magnitude > 0.05 then
			e.pos = clampMap(e.pos + e.vel * dt)
		end
	end

	-- facing
	local want: Vector3? = e.faceDirOverride or e.faceDir
	if (not want or (e.wishSpeed > 0.3 and not e.target)) and e.vel.Magnitude > 1 then
		want = e.vel
	end
	if stunned then
		want = nil
	end
	if want and flat(want).Magnitude > 0.05 and not (a and a.phase == "active" and a.kind == "charge") then
		local diff = wrapPi(yawOf(want) - e.yaw)
		local rate = TURN[e.class] * (if e.status.slow then 0.6 else 1)
		e.yaw += math.clamp(diff, -rate * dt, rate * dt)
	end

	snapGround(e, dt, e.needSnap)
	e.needSnap = false

	-- windup pose for big walkers
	local wTarget = 0
	if a and a.phase == "windup" and a.kind == "stomp" then
		wTarget = math.clamp((now - a.t0) / math.max(a.windup, 0.05), 0, 1)
	end
	e.windupV += (wTarget - e.windupV) * math.min(1, dt * 8)

	-- animation + pivot
	local speed = e.vel.Magnitude
	local moving = speed > 0.3
	if moving then
		e.animT += dt * math.min(speed / def.size * 1.6, 16)
	end
	local move = math.min(speed / (def.speed * 0.7), 1.3)
	local bobY = if moving then math.abs(math.sin(e.animT)) * e.rig.bob * math.min(move, 1) else 0
	local pos = e.pos + Vector3.new(0, bobY + e.air, 0)
	local cf = CFrame.new(pos) * CFrame.Angles(0, e.yaw, 0)
	local last = e.lastCF
	if not last or moving or e.windupV > 0.01 or e.air > 0 or (last.Position - pos).Magnitude > 0.01 or math.abs(wrapPi(e.lastYaw - e.yaw)) > 0.002 then
		e.model:PivotTo(cf)
		e.lastCF = cf
		e.lastYaw = e.yaw
		if (moving or e.windupV > 0.01) and e.near then
			EnemyModels.animate(e.rig, cf, e.animT, move, e.windupV)
		end
		-- footsteps for the big ones
		if moving and (e.class == "heavy" or e.class == "behemoth") and e.near then
			e.stepT += dt
			local period = if e.class == "behemoth" then 1.1 else 0.55
			if e.stepT >= period then
				e.stepT = 0
				S.Fx.playU("EnemyAttack", { id = e.id, kind = "step", e = e.kind, p = e.pos, t = 0 })
			end
		end
	end
end

function EnemyAI.step(dt: number, enemies: { [number]: any })
	local now = workspace:GetServerTimeNow()
	if not S.Players then
		return
	end

	-- cache players once per frame
	table.clear(targets)
	table.clear(tmap)
	local plist = S.Players.getAlive()
	for _, p in plist do
		local root = S.Players.getRoot(p)
		if root then
			local t = { p = p, root = root, pos = root.Position, vel = root.AssemblyLinearVelocity }
			table.insert(targets, t)
			tmap[p] = t
		end
	end

	if os.clock() - lastFilter > 1 then
		lastFilter = os.clock()
		rebuildFilter()
	end

	table.clear(snapshot)
	for _, e in enemies do
		table.insert(snapshot, e)
	end
	for _, e in snapshot do
		if e.alive then
			-- only animate things anywhere near a player
			local near = false
			for _, t in targets do
				local d = t.pos - e.pos
				if d.X * d.X + d.Z * d.Z < 230 * 230 then
					near = true
					break
				end
			end
			e.near = near
			update(e, dt, now)
		end
	end
end

function EnemyAI.init(s: { [string]: any })
	S = s
	LumenAI.init(s) -- LUMEN hook
	rebuildFilter()
	local function hook(p: Player)
		p.CharacterAdded:Connect(function()
			task.defer(rebuildFilter)
		end)
	end
	Players.PlayerAdded:Connect(hook)
	for _, p in Players:GetPlayers() do
		hook(p)
	end
end

return EnemyAI
