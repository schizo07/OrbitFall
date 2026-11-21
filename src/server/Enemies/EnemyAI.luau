-- Per-enemy behaviour. Not a registered service: EnemyService requires this and drives it each frame.
-- Think at ~10 Hz (staggered per enemy), move/animate every Heartbeat via PivotTo.
--
-- Attack kinds (Data/Enemies): bolt, burst, cannon, mortar, sweep, stomp, melee, bite (Brood ground bite), leap, spit, charge, summon.
-- Fx sent: Bolt/BoltEnd (via Projectiles), Telegraph {shape, p, r | a, b, w, t},
--          EnemyAttack {id, kind, e, p, t, ...}, Shockwave, Shake, Breach.
-- Calls: S.Players.getAlive/getRoot/damage, S.Projectiles.fire, S.Enemies.spawn/count/damage,
--        S.CallIns.isInSmoke (optional), S.Director.onSpotted / meleeSlots (optional).
--
-- Director v2 additions:
--   * Melee slots: a melee unit (regular / medium, no keepDistance) only attacks while it holds one of the player's
--     Config.Action.MeleeSlots-ish slots (Director.meleeSlots()); the rest circle the player at CircleMin..CircleMax studs and
--     rotate in when a lease (MeleeSlotLease) runs out. e.slot = Player holding it, e.circling = Player being circled.
--   * Fodder (e.fodder): thinks at FodderThink, no LOS raycast, inside FodderSteerRange of the target it just seeks (no obstacle
--     raycasts), separation is cached 0.3 s, ground snap every FodderGroundSnap studs.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local EnemyModels = require(script.Parent.EnemyModels)
local LumenAI = require(script.Parent.LumenAI) -- LUMEN hook: Lumen Concord attack kinds + blink / nodes
local Decoys = require(script.Parent.Parent.Decoys) -- Holo Decoy call-in: extra targets (empty list = nothing below runs)
-- AWARENESS: guard / patrol / suspicious / alert / search per unit (fodder and loot runners skip it and are always alert)
local Awareness = require(script.Parent.Awareness)
-- TACTICS: cover / flank movement for alert ranged units, optional melee approach (fodder keeps the cheap built-in moves)
local Tactician = require(script.Parent.Tactician)
local EnemyData = require(Shared.Data.Enemies)
local AIM = EnemyData.Aim
local AimDefault = EnemyData.AimDefault
local IS_STUDIO = game:GetService("RunService"):IsStudio()

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
	spit = true, charge = true, summon = true, melee = true, leap = true, bite = true,
}
local MELEE_KINDS = { melee = true, leap = true, bite = true, stomp = true, charge = true }
local MAP_HALF = Config.MapSize / 2 - 6
local ROBOT_BOLT = Color3.fromRGB(255, 84, 58)

-- VOLLEYS (bolt / burst shooters): a charge-up of at least MIN_WINDUP (clients show a muzzle glow), a short volley, then a
-- clear pause. The pause counts from the end of the volley: cooldown = windup + volley time + max(atk.cooldown, pause).
local VOLLEY = {
	minWindup = 0.35,
	burstMax = 3, -- shots per burst volley (Rivet 3-round suppressive burst)
	burstGap = 0.17, -- seconds between the shots of a burst
	pause = { bolt = 1.15, burst = 1.9 }, -- shortest quiet time after a volley
}
-- AWARENESS reaction: stop and turn to the target for this long before the first attack after noticing it
local NOTICE = { 0.4, 0.6 }
local LOST_AFTER = 4 -- s with no line of sight to the target while alert -> Awareness.lost (search)

-- Per-frame caches ------------------------------------------------------------------
-- A Holo Decoy is a Target with `decoy` set and no `p`. It is NOT in `targets` (those stay players only); it lives in
-- `decoyEntries` and in tmap keyed by the decoy table, so e.target (Player for players, the decoy table for a decoy) resolves
-- through targetEntry like always. Anything that needs a Player must go through damageTarget / t.p ~= nil.
type Target = { p: Player?, decoy: any?, root: BasePart, pos: Vector3, vel: Vector3, downed: boolean? }
local targets: { Target } = {}
local decoyEntries: { Target } = {}
local tmap: { [any]: Target } = {}
local snapshot: { any } = {}
local lastFilter = 0
local lastScreech = 0
local SAVER_NEAR = 60 -- studs: full-rate PivotTo + server leg CFrame writes within this range
local SAVER_MID = 150 -- studs: 60..150 updates at SAVER_MID_HZ; beyond updates at SAVER_FAR_HZ
local SAVER_MID_HZ = 20
local SAVER_FAR_HZ = 8
local SAVER_MID_DT = 1 / SAVER_MID_HZ
local SAVER_FAR_DT = 1 / SAVER_FAR_HZ
-- Studio A/B Feel_Perf (Variants "PERF", mirrored): non-fodder re-snap to the ground every PERF_SNAP studs instead of 0.25
local perfOn = false
local PERF_SNAP = 0.9
-- ENEMY TACTICS (per-unit def.tactics + attacks marked `tactic`, numbers in EnemyData.Tactics). Studio A/B Feel_EnemyTactics
-- (Variants "ENEMY TACTICS", mirrored): nil = on, "strong" = more flanking / leaps / spread, "off" = the old straight-in AI.
-- Live games always run "on". Read once per frame in stepBody.
local TAC = EnemyData.Tactics
local tacMode = "on"

-- Separation grid: every alive enemy bucketed by its flat position once per frame (EnemyAI.step), so `separation` only
-- looks at the cells around it instead of the whole snapshot. Cell lists are pooled.
local GRID_CELL = 8
local GRID_SLACK = 2 -- studs a neighbour may have moved since the grid was built this frame
local grid: { [number]: { any } } = {}
local gridPool: { { any } } = {}
local gridMaxSize = 0

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
		if e.def.static then
			-- emplacements: the body never turns, the turret does (TurretYaw); the muzzle swings with the turret
			return CFrame.new(e.pos) * CFrame.Angles(0, e.turretYaw or e.yaw, 0) * o
		end
		return rootCF(e) * o
	end
	return e.pos + Vector3.new(0, e.def.size * 1.2, 0)
end

-- Replicate vertical aim elevation (degrees) on ranged units, throttled to >= 4 deg deltas or reset to 0.
local function setAimPitch(e: any, pitchDeg: number)
	if not e.def.keepDistance or not e.model then
		return
	end
	local clamped = math.clamp(pitchDeg, -50, 55)
	local prev = e.aimPitchSent or 0
	if (clamped == 0 and prev ~= 0) or math.abs(clamped - prev) >= 4 then
		e.aimPitchSent = clamped
		e.model:SetAttribute("AimPitch", math.floor(clamped + 0.5))
	end
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

-- Damage whatever the target entry is: a player, or a Holo Decoy (hp only, no knockback).
local function damageTarget(t: Target, amount: number, from: Vector3, knock: number?, kind: string?)
	if t.decoy then
		Decoys.damage(t.decoy, amount)
	elseif t.p then
		damagePlayer(t.p, amount, from, knock, kind)
	end
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
	e.thinkDt = if e.fodder then Config.Action.FodderThink else THINK
	e.snapDist = if e.fodder then Config.Action.FodderGroundSnap else 0.25
	e.slot = nil
	e.circling = nil
	e.nextThink = workspace:GetServerTimeNow() + rng:NextNumber(0, e.thinkDt)
	e.gcd = 0
	e.cd = {}
	local now = workspace:GetServerTimeNow()
	for i, atk in e.def.attacks do
		e.cd[i] = now + rng:NextNumber(0.6, 1.8) + atk.cooldown * rng:NextNumber(0, 0.35)
	end
	e.home = opts.home or e.pos
	e.goal = opts.dest
	e.goalSpeed = 0.75
	-- Director patrols: ignore the squad for `crossFor` seconds (unless hit / alerted) so they walk across its path
	e.crossUntil = if opts.crossFor then now + opts.crossFor else nil
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
	e.groundY = e.pos.Y
	e.groundN = Vector3.yAxis
	e.stuckT = now + 1
	e.stuckPos = e.pos
	e.stuckUntil = 0
	e.lastCF = nil
	e.stepT = 0
	e.lastHitBy = nil
	e.alerted = false
	e.aimPitchSent = 0
	e.reinforced = opts.reinforced == true -- delivered by a Director spotted call (see Director.onSpotted: chained calls are capped)
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
	-- melee slots apply to the swarm of ordinary melee units (heavies / behemoths charge and stomp freely)
	e.meleeGate = melee < math.huge and not e.def.keepDistance and (e.class == "regular" or e.class == "medium")
	e.los = true
	LumenAI.register(e) -- LUMEN hook (no-op for other factions)
	-- AWARENESS / TACTICS: fodder and loot runners keep the cheap always-alert behaviour
	e.baseAggro = e.aggro
	e.hpSeen = e.hp
	e.losAt = now
	e.hadTarget = false
	e.aware = false
	e.tactician = false
	if not e.fodder and e.def.behavior ~= "flee" then
		Awareness.register(e, opts)
		e.aware = true
		Tactician.register(e, opts)
		e.tactician = true
	end
	-- units that arrive already hunting (waves, breaches, summons) skip the notice pause
	e.wasAlert = opts.aggro == true or opts.posture == "hunt" or opts.target ~= nil
	-- emplacements: the pivot keeps its spawn yaw for good; only the turret turns (model attribute TurretYaw)
	if e.def.static then
		e.baseYaw = e.yaw
		e.turretYaw = e.yaw
		e.turretSent = e.yaw
		e.model:SetAttribute("TurretYaw", e.yaw)
	end
end

function EnemyAI.unregister(e: any)
	e.act = nil
	e.target = nil
	e.slot = nil
	e.circling = nil
	LumenAI.unregister(e) -- LUMEN hook
	if e.aware then
		e.aware = false
		Awareness.unregister(e)
	end
	if e.tactician then
		e.tactician = false
		Tactician.unregister(e)
	end
end

function EnemyAI.clear()
	table.clear(targets)
	table.clear(decoyEntries)
	table.clear(tmap)
	table.clear(snapshot)
	Tactician.clear()
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

-- Blast reaction (EnemyService.explode). r = a row of Data/Enemies.Blast scaled by power (0..~1.6).
-- interrupt = false (heavies): only shoves an enemy that is not busy, never cancels its attack.
function EnemyAI.fling(e: any, from: Vector3, power: number, r: any)
	if not e.alive or e.def.static or not e.pos then
		return
	end
	local a = e.act
	if a and a.kind == "fling" then
		return -- already flying (Half-Ton = two blasts in one frame)
	end
	if not r.interrupt and a then
		return
	end
	local d = flat(e.pos - from)
	local dir = if d.Magnitude > 0.05 then d.Unit else heading(e.yaw + math.pi)
	local dist = r.dist * power
	if dist < 0.3 then
		return
	end
	-- stop short of walls / props
	local origin = e.pos + Vector3.new(0, 2, 0)
	local hit = workspace:Raycast(origin, dir * (dist + e.def.size), envParams)
	if hit then
		dist = math.max((hit.Position - origin).Magnitude - e.def.size, 0)
	end
	if r.interrupt then
		EnemyAI.interrupt(e)
	end
	e.faceDirOverride = nil
	local now = workspace:GetServerTimeNow()
	local spin = 0
	local axis = Vector3.xAxis
	if r.spin then
		-- top of the model goes along the push: world axis = up x dir, expressed in the root's yaw frame
		local worldAxis = Vector3.yAxis:Cross(dir)
		axis = CFrame.Angles(0, e.yaw, 0):VectorToObjectSpace(worldAxis)
		spin = math.pi * 2 * math.clamp(power, 0.5, 1.25) * rng:NextNumber(0.85, 1.1)
	end
	e.act = {
		kind = "fling",
		phase = "active",
		noThink = true,
		t0 = now,
		dur = r.dur * math.clamp(power, 0.6, 1.3),
		from = e.pos,
		dir = dir,
		dist = dist,
		height = r.height * math.min(power, 1.3),
		spin = spin,
		axis = axis,
		recover = r.recover,
	}
	e.air = 0
end

-- Outside push (call-in hook, e.g. Gravity Well). velocity in studs/s for `dur` seconds, added on top of the enemy's own
-- movement; heavier classes resist (PUSH_MASS), static emplacements never move. A new call replaces the previous push, so a
-- pull that is refreshed every tick just keeps going.
local PUSH_MASS = { regular = 1, medium = 0.7, heavy = 0.3, behemoth = 0.08 }
function EnemyAI.push(e: any, velocity: Vector3, dur: number)
	if not e.alive or e.def.static or not e.pos or dur <= 0 then
		return
	end
	local k = PUSH_MASS[e.class] or 1
	if k <= 0 then
		return
	end
	e.push = { v = Vector3.new(velocity.X, 0, velocity.Z) * k, untilT = workspace:GetServerTimeNow() + dur }
end

-- Attack execution -------------------------------------------------------------------
local PREP: { [string]: (any, any, any, number) -> () } = {}
local FIRE: { [string]: (any, any, any, number) -> () } = {}
local ACTIVE: { [string]: (any, any, any, number, number) -> boolean } = {}

-- ENEMY AIM: Studio A/B workspace attribute Feel_EnemyAim ("new" default | "harsh" | "old"), mirrored to the server by
-- client/Fx/EnemyFx.luau (Action "studioFeel"). Live games always use "new".
local function aimMode(): string
	if not IS_STUDIO then
		return "new"
	end
	local v = workspace:GetAttribute("Feel_EnemyAim")
	return if v == "harsh" or v == "old" then v else "new"
end

-- -> (spread degrees, warning shot?). e.aimT0 / e.aimShots are reset in think() on a new target or after cover.
local function aimSpread(e: any, t: Target, from: Vector3, oldSpread: number, now: number): (number, boolean)
	local mode = aimMode()
	if mode == "old" then
		return oldSpread, false
	end
	if t.decoy then
		return oldSpread, false -- a hologram gets no warning shots and no aim build-up
	end
	local aim = e.def.aim or AimDefault
	local harsh = mode == "harsh"
	local threat = if S.Director and S.Director.getThreat then math.clamp(S.Director.getThreat(), 0, 4) else 0
	local speed = flat(t.vel).Magnitude
	local stance = if S.Players and S.Players.getStance then S.Players.getStance(t.p) else "stand"
	local exposedOpen = stance == "stand" and speed < Config.WalkSpeed * 1.02
	e.aimShots = (e.aimShots or 0) + 1
	local warn = aim.warnShots - (if harsh then 1 else 0)
	if exposedOpen and (threat >= 2 or warn >= 2) then
		warn = math.max(1, warn - 1) -- exposed in the open: still 1 readable warning tracer, then live fire
	end
	if e.aimShots <= warn then
		return 0, true
	end
	local tighten = aim.tighten * (if harsh then AIM.harshTighten else 1) * (if exposedOpen then 0.72 else 1) * (1 - 0.06 * threat)
	local k = math.clamp((now - (e.aimT0 or now)) / math.max(tighten, 0.05), 0, 1)
	local spread = aim.base + (aim.min - aim.base) * k
	local dist = (t.pos - from).Magnitude
	spread *= 1 + aim.rangeMul * math.clamp((dist - AIM.rangeFrom) / AIM.rangeRef, 0, 2)
	spread *= 1 + aim.moveMul * math.clamp(speed / Config.WalkSpeed, 0, 1)
	if speed >= AIM.sprintAt then
		spread *= 1 + aim.moveMul * AIM.sprintBonus
	end
	if stance == "prone" then
		spread *= AIM.prone
	elseif stance == "crouch" then
		spread *= AIM.crouch
	end
	if harsh then
		spread *= AIM.harshSpread
	end
	return spread, false
end

local function shootBolt(e: any, atk: any, t: Target, oldSpread: number)
	local from = muzzleWorld(e)
	local speed = atk.speed or 100
	local pt = aimPoint(from, t, speed, 0.65)
	local spread, warn = aimSpread(e, t, from, oldSpread, workspace:GetServerTimeNow())
	if warn then
		-- near miss: aim beside the target (random side, a little high), and this bolt can never hit that player
		local side = flat(pt - from)
		side = if side.Magnitude > 0.05 then Vector3.yAxis:Cross(side.Unit) else Vector3.xAxis
		local sign = if rng:NextNumber() < 0.5 then 1 else -1
		pt += side * sign * rng:NextNumber(AIM.warnOffset[1], AIM.warnOffset[2]) + Vector3.new(0, rng:NextNumber(0, 1.6), 0)
	end
	local dir = (pt - from).Unit
	S.Projectiles.fire({
		a = from,
		v = spreadDir(dir, spread) * speed,
		spare = if warn then t.p else nil,
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
	a.shots = math.min(atk.count or 3, VOLLEY.burstMax)
	a.nextShot = now
end
ACTIVE.burst = function(e, a, atk, dt, now)
	if now >= a.nextShot then
		local t = targetEntry(e)
		if t then
			shootBolt(e, atk, t, 3)
		end
		a.shots -= 1
		a.nextShot = now + VOLLEY.burstGap
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
	-- the shell flies at the Projectiles speed (slowed for dodging), so the ground circle lasts until it really lands
	local speed = (atk.speed or 90) * (if S.Projectiles.speedMul then S.Projectiles.speedMul("cannon", "cannon") else 1)
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
		local function fireShell(origin: Vector3, targetPt: Vector3, dmgScale: number)
			local dir = (targetPt - origin).Unit
			S.Projectiles.fire({
				a = origin,
				v = dir * (atk.speed or 90),
				style = "cannon",
				c = Color3.fromRGB(255, 138, 42),
				damage = math.floor(atk.damage * dmgScale + 0.5),
				radius = atk.radius or 5,
				knockback = 48,
				shake = if e.kind == "BASTION" then 1.8 else 1.5,
				hitRadius = 1.9,
				life = 3.2,
				kind = "cannon",
				heavy = true,
				owner = e,
			})
		end
		if e.kind == "BASTION" then
			-- Bastion twin-barrel staggered heavy salvo: unmistakable heavy emplacement firepower
			local right = rootCF(e).RightVector
			fireShell(from - right * 1.4, pt, 0.58)
			local tRef = targetEntry(e)
			local secondPt = if tRef then Vector3.new(tRef.pos.X, pt.Y, tRef.pos.Z) else pt
			task.delay(0.18, function()
				if e.alive then
					local f2 = muzzleWorld(e) + rootCF(e).RightVector * 1.4
					fireShell(f2, secondPt, 0.58)
				end
			end)
		else
			fireShell(from, pt, 1)
		end
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
				shake = 2.0,
				hitRadius = 0.7,
				life = MORTAR_T + 1.5,
				kind = "mortar",
				heavy = true,
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
	for _, t in decoyEntries do -- Holo Decoys (empty unless one is alive)
		if not a.hit[t.decoy] then
			local rel = flat(t.pos - o)
			local along = rel:Dot(d)
			if along > 0 and along < len and (rel - d * along).Magnitude < 2.6 + t.decoy.hitRadius and math.abs(t.pos.Y - o.Y) < 8 then
				a.hit[t.decoy] = true
				damageTarget(t, atk.damage, o, 0, "laser")
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
	for _, t in decoyEntries do
		if flat(t.pos - e.pos).Magnitude <= r + t.decoy.hitRadius and t.pos.Y - e.pos.Y < 10 then
			damageTarget(t, atk.damage, e.pos, 0, "stomp")
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
			damageTarget(t, atk.damage, e.pos, 22, "melee")
		end
	end
	e.act = nil
end

-- bite: the ground attack of ordinary Brood melee units (Skitterling). The unit runs up to close range (stopDist), stands still for
-- the wind-up (mandibles open on the client = the readable tell), then snaps its mandibles shut: damage in a short cone in front of
-- it, plus a tiny forward lunge on the ground (no jump). Dodge by stepping out of the cone / range during the wind-up.
local BITE_CONE = math.cos(math.rad(55)) -- half angle of the bite cone
local BITE_REACH = 1.3 -- forgiveness on atk.range (measured from the unit's edge, like melee)
local BITE_LUNGE = 1.4 -- studs the snap steps forward
local BITE_LUNGE_T = 0.12
FIRE.bite = function(e, a, atk, now)
	local t = targetEntry(e)
	local fwd = heading(e.yaw)
	local gap = 0
	if t then
		local to = flat(t.pos - e.pos)
		local dist = to.Magnitude
		gap = dist - e.def.size * 0.6
		if gap <= atk.range * BITE_REACH and math.abs(t.pos.Y - e.pos.Y) < 6 and (dist < 0.5 or to.Unit:Dot(fwd) >= BITE_CONE) then
			damageTarget(t, atk.damage, e.pos, 14, "bite")
		end
	end
	a.phase = "active"
	a.noMove = true
	a.t0 = now
	a.from = e.pos
	a.to = clampMap(e.pos + fwd * math.clamp(gap - 1, 0, BITE_LUNGE))
	e.faceDirOverride = fwd
end
ACTIVE.bite = function(e, a, atk, dt, now)
	local u = math.clamp((now - a.t0) / BITE_LUNGE_T, 0, 1)
	local p = a.from:Lerp(a.to, u)
	e.pos = Vector3.new(p.X, e.pos.Y, p.Z)
	e.vel = flat(a.to - a.from) / BITE_LUNGE_T * (1 - u)
	if u >= 1 then
		e.vel = Vector3.zero
		e.act = nil
		e.gcd = now + 0.2
	end
	return true
end

-- leap (no ordinary unit uses it any more; kept for units whose identity is a leaper)
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
			damageTarget(t, atk.damage, e.pos, 18, "bite")
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
	for _, t in decoyEntries do
		if not a.hit[t.decoy] and flat(t.pos - e.pos).Magnitude <= hitR + t.decoy.hitRadius and math.abs(t.pos.Y - e.pos.Y) < 9 then
			a.hit[t.decoy] = true
			damageTarget(t, atk.damage, e.pos - a.dir * 3, 0, "charge")
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

-- fling: blast reaction (EnemyService.explode -> EnemyAI.fling). The root slides along a.dir with an ease-out, hops a.height
-- and (regulars) tumbles a.spin radians about the horizontal axis across the push, then a short "recover" before it thinks again.
ACTIVE.fling = function(e, a, atk, dt, now)
	local u = math.clamp((now - a.t0) / a.dur, 0, 1)
	local k = 1 - (1 - u) * (1 - u)
	e.pos = clampMap(a.from + a.dir * (a.dist * k))
	e.air = math.sin(u * math.pi) * a.height
	if a.spin ~= 0 then
		local h = e.def.size * 0.6
		e.tumble = CFrame.new(0, h, 0) * CFrame.fromAxisAngle(a.axis, a.spin * k) * CFrame.new(0, -h, 0)
	end
	e.vel = Vector3.zero
	if u >= 1 then
		e.air = 0
		e.tumble = nil
		e.lastCF = nil -- force one PivotTo so the model is upright again
		e.needSnap = true
		e.act = if a.recover > 0 then { kind = "recover", phase = "active", noMove = true, endAt = now + a.recover, noThink = false } else nil
	end
	return true
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

-- ENEMY TACTICS screech: a wounded big bug (def.tactics.screech) rears up for TAC.screechWindup (AtkKind "screech" = the client
-- pose), then screeches (BugScreech sound): Brood regulars / fodder within the radius run x speed for dur seconds and join in.
-- Not one of def.attacks (a.idx = nil); started from think via startScreech.
FIRE.screech = function(e, a, _atk, now)
	local sc = e.def.tactics and e.def.tactics.screech
	e.act = nil
	if not sc then
		return
	end
	sendAttackFx(e, "screech", 0)
	local r = sc.radius
	for _, o in snapshot do
		if o ~= e and o.alive and o.pos and o.faction == "BROOD" and o.class == "regular" and o.def.behavior ~= "flee" then
			if flat(o.pos - e.pos).Magnitude < r then
				o.rallyUntil = now + sc.dur
				o.rallyMul = sc.speed
				o.aggro = true
				o.crossUntil = nil
				if o.aware then
					Awareness.alert(o, nil, e.pos, "screech")
				end
			end
		end
	end
end

local function startScreech(e: any, now: number)
	local w = TAC.screechWindup
	e.act = { kind = "screech", phase = "windup", t0 = now, fireAt = now + w, windup = w, noMove = true }
	e.gcd = now + w + 0.35
	e.model:SetAttribute("AtkKind", "screech")
	e.model:SetAttribute("AtkWindup", w)
	e.atkSeq = (e.atkSeq or 0) + 1
	e.model:SetAttribute("AtkSeq", e.atkSeq)
end

-- the bolt / burst wind-up is the muzzle charge-up telegraph on clients (never shorter than VOLLEY.minWindup)
local DEFAULT_WINDUP = { bolt = 0.4, burst = 0.45, melee = 0.3, summon = 1.0, leap = 0.25, bite = 0.3, stomp = 0.8, charge = 0.9 }

-- LUMEN hook: LumenAI adds needle / beam / pulse / rift to PREP/FIRE/ACTIVE using these helpers
LumenAI.install({
	PREP = PREP, FIRE = FIRE, ACTIVE = ACTIVE, NOMOVE = NOMOVE, DEFAULT_WINDUP = DEFAULT_WINDUP,
	targets = targets, decoyEntries = decoyEntries, damageTarget = damageTarget, targetEntry = targetEntry, muzzleWorld = muzzleWorld, aimPoint = aimPoint,
	spreadDir = spreadDir, heading = heading, envParams = envParams, groundAt = groundAt, clampMap = clampMap,
	telegraphLine = telegraphLine, telegraphCircle = telegraphCircle, damagePlayer = damagePlayer, liveCap = liveCap,
	aimSpread = aimSpread, -- ENEMY AIM for needle volleys
})

local function startAttack(e: any, idx: number, atk: any, now: number)
	local windup = atk.windup or DEFAULT_WINDUP[atk.kind] or 0.4
	local volley = atk.kind == "bolt" or atk.kind == "burst"
	if volley then
		windup = math.max(windup, VOLLEY.minWindup)
	end
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
	local cdBase = windup + atk.cooldown
	if volley then
		local shots = if atk.kind == "burst" then math.min(atk.count or 3, VOLLEY.burstMax) else 1
		local threat = if S.Director and S.Director.getThreat then math.clamp(S.Director.getThreat(), 0, 4) else 0
		local suppressMul = if e.tc and e.tc.role == "suppress" then 0.88 else 1
		local pause = math.max(atk.cooldown, VOLLEY.pause[atk.kind]) * suppressMul * (1 - 0.04 * threat)
		cdBase = windup + (shots - 1) * VOLLEY.burstGap + pause
	end
	e.cd[idx] = now + cdBase * (e.cdMul or 1) * rng:NextNumber(0.9, 1.15) -- cdMul: elite SWIFT
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
	if volley then
		-- muzzle charge-up telegraph on clients (unreliable: many shooters, and AtkSeq above covers a dropped one)
		S.Fx.playU("EnemyAttack", { id = e.id, kind = atk.kind, e = e.kind, p = muzzleWorld(e), t = windup })
	elseif e.class == "heavy" or e.class == "behemoth" then
		if atk.kind ~= "melee" then
			local extra: { [string]: any } = { m = muzzleWorld(e) }
			if atk.kind == "cannon" and a.point then
				extra.tp = a.point + Vector3.new(0, 1.2, 0)
			end
			sendAttackFx(e, atk.kind, windup, extra)
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
	elseif k == "bite" then
		return edist <= atk.range and aimErr < 0.7
	elseif k == "leap" then
		return dist <= atk.range + 0.5 and dist >= (atk.minRange or 1.5) and aimErr < 0.8
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
-- Spotted / hit: aware units pass it on through Awareness (squad + nearby); fodder still wakes nearby fodder the old way
-- (aware neighbours hear the fight through Awareness.noise instead).
local function alertNearby(e: any, player: Player?, pos: Vector3?, reason: string)
	local useAware = tacMode ~= "off"
	if e.aware and useAware then
		Awareness.alert(e, player, pos, reason)
	else
		for _, o in snapshot do
			if o ~= e and o.alive and not o.aggro and not (o.aware and useAware) and o.faction == e.faction then
				if flat(o.pos - e.pos).Magnitude < 75 then -- the whole squad piles in (was 50)
					o.aggro = true
				end
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
	local cross = e.crossUntil
	if cross then
		if not e.aggro and not e.lastHitBy and workspace:GetServerTimeNow() < cross then
			return nil, math.huge
		end
		e.crossUntil = nil
	end
	local best: Target? = nil
	local bestD = math.huge
	local bestEff = math.huge
	for _, t in targets do
		local d = flat(t.pos - e.pos).Magnitude
		-- downed troopers (server/Downed.luau) count as further away: a standing squadmate nearby is picked first
		local eff = if t.downed then d * 2 + 15 else d
		if eff < bestEff then
			bestEff = eff
			bestD = d
			best = t
		end
	end
	local range = AGGRO[e.class] * (if e.aggro then 2.4 else 1)
	-- Holo Decoy: inside its radius it counts as closer (distance x preference) than any trooper, so it steals the target
	-- (aggro range does not apply: it taunts). Only runs while a decoy is alive.
	if #decoyEntries > 0 then
		local pick: Target? = nil
		local pickD = math.huge -- real distance of the pick
		local pickEff = bestD -- compared distance (trooper = real distance, decoy = real x preference)
		for _, dt in decoyEntries do
			local d = flat(dt.pos - e.pos).Magnitude
			if d <= dt.decoy.radius then
				local eff = d * dt.decoy.preference
				if eff < pickEff then
					pickEff = eff
					pick = dt
					pickD = d
				end
			end
		end
		if pick then
			return pick, pickD
		end
		local own = targetEntry(e)
		if own and own.decoy then
			-- its decoy is out of reach / gone from the radius: back to the troopers (fall through; `cur` below is a decoy entry
			-- only while it is alive, and a decoy outside its radius must not stay sticky)
			e.target = nil
		end
	end
	-- sticky target
	local cur = targetEntry(e)
	if cur then
		local cd = flat(cur.pos - e.pos).Magnitude
		-- (no sticking to a downed trooper while a standing one is the better pick)
		if cd <= bestD * 1.4 + 6 and cd <= range and not (cur.downed and best and not best.downed) then
			return cur, cd
		end
	end
	if best and bestD <= range then
		return best, bestD
	end
	return nil, bestD
end

local STEER_DEGS = { 40, -40, 75, -75, 115, -115 }
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
	for _, deg in STEER_DEGS do
		local d = CFrame.Angles(0, math.rad(deg), 0) * dir
		if not blocked(d) then
			return d
		end
	end
	return -dir
end

-- Same probe as steer, a little longer: is there a wall / prop right behind or beside the unit along d?
local function probeBlocked(e: any, d: Vector3): boolean
	local h = math.min(e.def.size, 3) + 0.5
	local r = workspace:Raycast(e.pos + Vector3.new(0, h, 0), d * (e.def.size * 1.4 + 6), envParams)
	return r ~= nil and math.abs(r.Normal.Y) < 0.65
end

-- Backing away from the target (moveDir points away from `dir`): if a wall is behind, slide sideways instead, or stand.
-- -> (move dir or nil, changed?)  Only costs raycasts while a unit is actually backing off.
local function safeBackoff(e: any, moveDir: Vector3?, dir: Vector3): (Vector3?, boolean)
	if not moveDir then
		return nil, false
	end
	local m = flat(moveDir)
	if m.Magnitude < 0.01 then
		return moveDir, false
	end
	m = m.Unit
	if m:Dot(dir) > -0.2 or not probeBlocked(e, m) then
		return moveDir, false
	end
	local side = Vector3.new(-dir.Z, 0, dir.X) * e.strafeDir
	if not probeBlocked(e, side) then
		return side, true
	end
	if not probeBlocked(e, -side) then
		e.strafeDir = -e.strafeDir
		return -side, true
	end
	return nil, true
end

local function separation(e: any): Vector3
	if e.fodder then
		-- fodder: the neighbour scan runs 3x a second, the result is reused in between
		local c = os.clock()
		if c < (e.sepAt or 0) then
			return e.sepCache or Vector3.zero
		end
		e.sepAt = c + 0.3 + rng:NextNumber(0, 0.15)
	end
	local push = Vector3.zero
	-- only the grid cells within reach of the largest neighbour (same result as scanning every enemy)
	local p = e.pos
	local reach = (e.def.size + gridMaxSize) * 0.9 + GRID_SLACK
	local cx0, cx1 = math.floor((p.X - reach) / GRID_CELL), math.floor((p.X + reach) / GRID_CELL)
	local cz0, cz1 = math.floor((p.Z - reach) / GRID_CELL), math.floor((p.Z + reach) / GRID_CELL)
	for cx = cx0, cx1 do
		for cz = cz0, cz1 do
			local list = grid[(cx + 32768) * 65536 + (cz + 32768)]
			if list then
				for _, o in list do
					if o ~= e and o.alive then
						local delta = flat(p - o.pos)
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
			end
		end
	end
	if e.fodder then
		e.sepCache = push
	end
	return push
end

-- Melee slots ---------------------------------------------------------------------------
-- Tallied once per frame in EnemyAI.step from e.slot / e.circling (the Player a unit holds a slot on / circles).
local slotCount: { [Player]: number } = {}
local waiting: { [Player]: number } = {}
local slotMax = Config.Action.MeleeSlotsBase
local slotMaxAt = 0

local function refreshSlotMax(clock: number)
	if clock < slotMaxAt then
		return
	end
	slotMaxAt = clock + 1
	local n = Config.Action.MeleeSlotsBase
	local dir = S.Director
	if dir and type(dir.meleeSlots) == "function" then
		local ok, v = pcall(dir.meleeSlots)
		if ok and type(v) == "number" then
			n = v
		end
	end
	slotMax = n
end

-- Movement of a slot-gated melee unit: holders close in and fight, everybody else walks to the 8-12 stud ring and circles it.
local function meleeMove(e: any, t: Target, dist: number, dir: Vector3, stop: number, now: number): (Vector3?, number)
	local A = Config.Action
	local p = t.p
	if e.slot ~= nil and e.slot ~= p then
		e.slot = nil -- the slot was on another player
	end
	if e.slot then
		-- lease over and somebody is waiting: rotate out
		if now >= (e.slotUntil or 0) and (waiting[p] or 0) > 0 then
			e.slot = nil
			slotCount[p] = math.max((slotCount[p] or 1) - 1, 0)
			e.slotCool = now + 3.5
		end
	end
	if not e.slot and dist <= A.MeleeClaimRange and now >= (e.slotCool or 0) and (slotCount[p] or 0) < slotMax then
		e.slot = p
		e.slotUntil = now + rng:NextNumber(A.MeleeSlotLease[1], A.MeleeSlotLease[2])
		slotCount[p] = (slotCount[p] or 0) + 1
	end
	if e.slot then
		e.circling = nil
		if dist > stop then
			return dir, 1
		elseif e.class == "regular" then
			if now >= e.strafeUntil then
				e.strafeUntil = now + rng:NextNumber(0.4, 1.0)
				e.strafeDir = -e.strafeDir
			end
			return Vector3.new(-dir.Z, 0, dir.X) * e.strafeDir, 0.7
		end
		return nil, 0
	end
	if dist > A.MeleeClaimRange then
		e.circling = nil
		return dir, 1 -- still on the way in
	end
	-- waiting for a slot: orbit at CircleMin..CircleMax
	e.circling = p
	if now >= e.strafeUntil then
		e.strafeUntil = now + rng:NextNumber(2.2, 4.5)
		e.strafeDir = -e.strafeDir
	end
	local radial = 0
	if dist < A.CircleMin then
		radial = -1
	elseif dist > A.CircleMax then
		radial = 0.8
	end
	return Vector3.new(-dir.Z, 0, dir.X) * e.strafeDir + dir * radial, 0.65
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

-- LOOT RUNNER (def.behavior == "flee", server/Enemies/LootRunner.luau): never fights. Runs from the nearest trooper, switching
-- between left / right of the straight-away line every 0.5-1.1 s, and bends back towards the map centre near the edge.
-- Moves through setWish like every other unit (obstacle steering, separation, speed = def.speed).
local FLEE_ZIG = math.rad(40)
local FLEE_EDGE = 30 -- studs from the clamp edge where the pull towards the centre starts
local function fleeThink(e: any, now: number)
	e.target = nil
	e.faceDir = nil
	e.aimAt = nil
	local from: Target? = nil
	local nearest = math.huge
	for _, tt in targets do
		local d = flat(tt.pos - e.pos).Magnitude
		if d < nearest then
			nearest = d
			from = tt
		end
	end
	if not from then
		setWish(e, nil, 0)
		return
	end
	local away = flat(e.pos - from.pos)
	away = if away.Magnitude > 0.05 then away.Unit else heading(e.yaw)
	if now >= (e.zigUntil or 0) then
		e.zigUntil = now + rng:NextNumber(0.5, 1.1)
		e.zigSign = -(e.zigSign or (if rng:NextNumber() < 0.5 then 1 else -1))
		e.zigAng = FLEE_ZIG * rng:NextNumber(0.6, 1.2)
	end
	local dir = CFrame.Angles(0, e.zigSign * e.zigAng, 0) * away
	local lim = MAP_HALF - FLEE_EDGE
	local px, pz = e.pos.X, e.pos.Z
	local ex = if px > lim then lim - px elseif px < -lim then -lim - px else 0
	local ez = if pz > lim then lim - pz elseif pz < -lim then -lim - pz else 0
	if ex ~= 0 or ez ~= 0 then
		dir += Vector3.new(ex, 0, ez) / FLEE_EDGE * 1.6
	end
	setWish(e, dir, if nearest > 90 then 0.5 else 1)
end

-- ENEMY TACTICS ---------------------------------------------------------------------------
local function strongMul(key: string): number
	return if tacMode == "strong" then TAC.strong[key] or 1 else 1
end

-- Callout: idle squadmates of the same faction within def.tactics.callout studs are pointed at the spotted trooper and think
-- right away. O(n) once per callout (rate-limited per unit), never per frame.
local function callout(e: any, t: Target, radius: number, now: number)
	e.calloutAt = now + TAC.calloutCooldown
	local r = radius * strongMul("callout")
	for _, o in snapshot do
		if o ~= e and o.alive and o.pos and o.target == nil and o.faction == e.faction and not o.def.static and o.def.behavior ~= "flee" then
			if flat(o.pos - e.pos).Magnitude < r then
				o.aggro = true
				o.crossUntil = nil
				if o.aware then
					Awareness.alert(o, t.p, t.pos, "callout")
				end
				o.goal = t.pos
				o.goalSpeed = 1
				o.goalRefresh = now + 4
				o.nextThink = math.min(o.nextThink, now + rng:NextNumber(0.05, 0.3))
			end
		end
	end
end

-- On a new target: callout, maybe pick a flank side, re-roll the swarm approach bend.
local function tacticsNewTarget(e: any, tac: any, t: Target, dir: Vector3, dist: number, now: number)
	e.flankVec = nil
	e.spreadAng = nil
	if t.decoy then
		return
	end
	if tac.callout and now >= (e.calloutAt or 0) then
		callout(e, t, tac.callout, now)
	end
	local kd = e.def.keepDistance
	if tac.flank and kd and dist > kd * 0.6 and rng:NextNumber() < tac.flank * strongMul("flank") then
		local side = if rng:NextNumber() < 0.5 then 1 else -1
		-- bearing fixed now (from the target towards this unit, swung to one side); the point follows the target's position
		e.flankVec = CFrame.Angles(0, math.rad(tac.flankAngle or 70) * side, 0) * -dir
		e.flankUntil = now + TAC.flankTime
	end
end

-- Ranged hold (keepDistance units with tactics): flank point first, then keep inside the hold band; inside it, side-step for a
-- moment and plant to shoot. Wounded units hold further back (retreatAt), pushers hold closer (push).
local function tacticalRanged(e: any, tac: any, t: Target, dist: number, dir: Vector3, kd: number, now: number): (Vector3?, number)
	local pref = kd * (tac.push or 1)
	if tac.retreatAt and e.maxHp and e.maxHp > 0 and e.hp / e.maxHp <= tac.retreatAt then
		pref *= tac.retreatMul or 1.3
	end
	local fv = e.flankVec
	if fv then
		if now < (e.flankUntil or 0) then
			local goal = clampMap(t.pos + fv * pref)
			local to = flat(goal - e.pos)
			if to.Magnitude > TAC.flankReach then
				return to, 1
			end
		end
		e.flankVec = nil
	end
	local hold = tac.hold or TAC.holdDefault
	local side = Vector3.new(-dir.Z, 0, dir.X) * e.strafeDir
	if not e.los or dist > pref * hold[2] then
		return dir, 1
	elseif dist < pref * hold[1] then
		return -dir + side * 0.5, 0.85
	end
	if now >= e.strafeUntil then
		if e.stepMoving then
			e.stepMoving = false
			e.strafeUntil = now + rng:NextNumber(TAC.pause[1], TAC.pause[2])
		else
			e.stepMoving = true
			e.strafeUntil = now + rng:NextNumber(TAC.step[1], TAC.step[2])
			if rng:NextNumber() < 0.6 then
				e.strafeDir = -e.strafeDir
			end
		end
	end
	if e.stepMoving then
		return Vector3.new(-dir.Z, 0, dir.X) * e.strafeDir, 0.8
	end
	return nil, 0
end

-- Swarm approach: bend the straight-in heading by up to def.tactics.spread degrees (fading to none near the target), so a pack
-- spirals in and arrives from several sides. One sign + size per unit per target.
local function spreadApproach(e: any, tac: any, dir: Vector3, dist: number): Vector3
	local ang = e.spreadAng
	if not ang then
		ang = math.rad(tac.spread) * rng:NextNumber(0.45, 1) * (if rng:NextNumber() < 0.5 then 1 else -1)
		e.spreadAng = ang
	end
	local k = math.clamp((dist - TAC.spreadNear) / (TAC.spreadFar - TAC.spreadNear), 0, 1)
	if k <= 0 then
		return dir
	end
	return CFrame.Angles(0, ang * k * strongMul("spread"), 0) * dir
end

-- AWARENESS: not alert (guard / patrol / suspicious / search). No target, no attacks; Awareness.idle drives move + facing.
-- Convoy walkers keep their route, and Director crossing patrols finish walking to their dest while calm.
local function unawareThink(e: any, now: number)
	e.target = nil
	e.aimAt = nil
	e.tacKey = nil
	e.seenT = 0
	e.slot = nil
	e.circling = nil
	e.noticeUntil = nil
	if e.wasAlert then
		-- calmed down (search over): back to the spawn rule, forget call-out walk goals
		e.wasAlert = false
		e.aggro = e.baseAggro
		e.hadTarget = false
		e.goal = nil
	end
	e.faceDir = nil
	if e.routeTo then
		local rt = flat(e.routeTo - e.pos)
		if rt.Magnitude > 1 then
			setWish(e, rt, e.routeSpeed or 0.5)
			return
		end
	end
	local st = e.awareState
	if e.goal and (st == nil or st == "guard" or st == "patrol") then
		local to = flat(e.goal - e.pos)
		if to.Magnitude < 6 then
			e.goal = nil
			e.home = e.pos
		else
			setWish(e, to, e.goalSpeed)
			return
		end
	end
	local wish, mul, face = Awareness.idle(e, now)
	if face and flat(face).Magnitude > 0.05 then
		e.faceDir = flat(face).Unit
		e.faceHard = true -- update(): keep this facing even while walking (look-around on patrol)
	end
	if e.def.static then
		setWish(e, nil, 0) -- emplacements only turn
	else
		setWish(e, wish, mul or 0)
	end
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
	e.faceHard = nil
	-- took damage since the last think: alert (spreads to the squad) + let the tactics react (cover / dodge)
	local hpSeen = e.hpSeen or e.hp
	e.hpSeen = e.hp
	if e.hp < hpSeen and tacMode ~= "off" then
		local hb = e.lastHitBy
		local hbe = if hb then tmap[hb] else nil
		local from = if hbe then hbe.pos else e.pos
		if e.tactician then
			local dmgFrac = (hpSeen - e.hp) / math.max(e.maxHp or 1, 1)
			Tactician.onDamaged(e, from, dmgFrac)
		end
		if e.aware and (now >= (e.hitAlertAt or 0) or not Awareness.isAlert(e)) then
			e.hitAlertAt = now + 1
			Awareness.alert(e, hb, if hbe then from else nil, "damage")
		end
	end
	if e.status.stun then
		setWish(e, nil, 0)
		e.faceDirOverride = nil
		return
	end
	-- frozen (call-in hook): model attribute FrozenUntil = a workspace:GetServerTimeNow() time; no moving, turning or attacking
	local fz = e.model:GetAttribute("FrozenUntil")
	e.frozenUntil = if type(fz) == "number" then fz else nil
	if e.frozenUntil and e.frozenUntil > now then
		local fa = e.act
		if fa and fa.kind ~= "fling" then
			EnemyAI.interrupt(e)
		end
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
		e.aimAt = nil
		e.seenT = 0
		setAimPitch(e, 0)
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

	if def.behavior == "flee" then
		fleeThink(e, now)
		return
	end

	-- danger evasion: mobile non-fodder units sprint radially away from live grenades / incoming offensive call-in beacons
	local useTac = e.tactician and tacMode ~= "off"
	if useTac and not def.static then
		local escDir, escSpeed = Tactician.evadeDanger(e, now)
		if escDir then
			if e.aware and not Awareness.isAlert(e) then
				Awareness.alert(e, nil, e.pos, "danger")
			end
			if e.act and e.act.phase == "windup" and not MELEE_KINDS[e.act.kind] then
				EnemyAI.interrupt(e)
			end
			e.faceDir = escDir
			setWish(e, escDir, escSpeed, true)
			return
		end
	end

	-- awareness ----------------------------------------------------------------------
	-- Aware units fight only while Awareness says alert; otherwise they guard / patrol / investigate / search.
	-- Fodder, loot runners and Feel_EnemyTactics "off" use the old rule: a hit or a trooper in range wakes them.
	local useAware = e.aware and tacMode ~= "off"
	if useAware then
		Awareness.sense(e, now)
		if not Awareness.isAlert(e) then
			setAimPitch(e, 0)
			unawareThink(e, now)
			return
		end
		e.aggro = true -- alert: the long pick range (pickTarget)
		if not e.wasAlert then
			-- just noticed: stop and turn to it for a moment before the first shot / bite
			e.wasAlert = true
			e.noticeUntil = now + rng:NextNumber(NOTICE[1], NOTICE[2])
			e.losAt = now
			e.hadTarget = false
			alertNearby(e, e.awareTarget, e.lastKnown, "spotted")
		end
	elseif e.lastHitBy and not e.aggro then
		e.aggro = true
		alertNearby(e, e.lastHitBy, nil, "damage")
	end

	-- target -----------------------------------------------------------------------
	local t, nearest = pickTarget(e)
	if t and not e.aggro then
		e.aggro = true
		alertNearby(e, t.p, t.pos, "spotted")
	end
	e.target = if t then (t.p or t.decoy) else nil -- decoy: the decoy table (see Target); players: the Player as always
	if t and t.decoy then
		e.slot = nil -- decoys have no melee slots: the whole swarm piles on
		e.circling = nil
	end

	if not t then
		e.seenT = 0
		e.aimAt = nil -- next sighting starts the aim over (EnemyData.Aim)
		e.tacKey = nil -- ENEMY TACTICS: next sighting is a new target (callout / flank roll)
		e.faceDir = nil
		e.slot = nil
		e.circling = nil
		setAimPitch(e, 0)
		-- alert with nobody in reach: a guard / patrol (or a unit that lost its target) heads for the last known spot and
		-- gives up into a search after LOST_AFTER s; hunters (e.patrol) keep walking at the squad below
		if useAware and (e.hadTarget or not e.patrol) then
			if now - e.losAt > LOST_AFTER then
				e.losAt = now
				e.hadTarget = false
				Awareness.lost(e, now)
			else
				local lk = e.lastKnown
				if lk and not e.routeTo and not def.static then
					local to = flat(lk - e.pos)
					if to.Magnitude > 6 then
						setWish(e, to, 0.9)
						return
					end
				end
			end
		end
		-- idle / patrol movement
		if e.routeTo then
			-- convoy walkers (side objective): follow the route (SideConvoy sets routeTo / routeSpeed)
			local rt = flat(e.routeTo - e.pos)
			if rt.Magnitude > 1 then
				setWish(e, rt, e.routeSpeed or 0.5)
				return
			end
		end
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
	-- 3D vertical aim pitch for ranged units so clients physically aim gun arm / head / torso up or down
	if def.keepDistance then
		local muzzle = muzzleWorld(e)
		local dy = t.pos.Y - muzzle.Y
		local flatD = math.max(Vector3.new(t.pos.X - muzzle.X, 0, t.pos.Z - muzzle.Z).Magnitude, 0.5)
		setAimPitch(e, math.deg(math.atan2(dy, flatD)))
	end

	-- reinforcement call after seeing a player for a few seconds (static emplacements never call)
	if e.class ~= "regular" and not def.static and not t.decoy then
		e.seenT += THINK
		if e.seenT >= 3 and not e.called then
			e.called = true
			if S.Director and S.Director.onSpotted then
				-- false = refused (cooldown / lull / another call in progress): try again in about a second
				if S.Director.onSpotted(e) == false then
					e.called = false
					e.seenT = 2
				end
			end
		end
	end

	-- line of sight (only ranged units care; fodder never pays for the raycast)
	if def.keepDistance and not e.fodder then
		local from = e.pos + Vector3.new(0, math.min(def.size, 4) + 1, 0)
		local r = workspace:Raycast(from, t.pos - from, envParams)
		e.los = (r == nil)
	else
		e.los = true
	end
	-- out of sight too long while alert: search (Awareness walks it to the last known spot, then back to its post)
	if useAware then
		e.hadTarget = true
		if e.los then
			e.losAt = now
		elseif now - e.losAt > LOST_AFTER then
			e.losAt = now
			e.hadTarget = false
			Awareness.lost(e, now)
		end
	end

	-- aim state for shootBolt: a new target starts wide with fresh warning shots; out of sight restarts the tighten clock,
	-- and a long time out of sight (EnemyData.Aim.reacquire) re-arms the warning shots
	local aimKey = t.p or t.decoy
	if e.aimAt ~= aimKey then
		e.aimAt = aimKey
		e.aimT0 = now
		e.aimShots = 0
		e.aimHidden = nil
	elseif not e.los then
		e.aimHidden = e.aimHidden or now
		e.aimT0 = now
	elseif e.aimHidden then
		if now - e.aimHidden >= AIM.reacquire then
			e.aimShots = 0
		end
		e.aimHidden = nil
	end

	-- ENEMY TACTICS: new-target callout / flank roll, and the wounded big bug's screech
	local tac = if tacMode ~= "off" then def.tactics else nil
	if tac then
		if e.tacKey ~= aimKey then
			e.tacKey = aimKey
			tacticsNewTarget(e, tac, t, dir, dist, now)
		end
		local sc = tac.screech
		if sc and not e.screeched and not e.act and e.maxHp and e.maxHp > 0 and e.hp / e.maxHp <= sc.at then
			e.screeched = true
			startScreech(e, now)
		end
	end

	-- notice pause: the unit just became alert; it stands and turns to the target before it acts
	if now < (e.noticeUntil or 0) then
		setWish(e, nil, 0)
		return
	end

	-- movement decision ---------------------------------------------------------------
	local moveDir: Vector3? = nil
	local moveSpeed = 0
	local fireOk = true -- false = Tactician is moving the unit between covers: no new ranged attack this think
	local kd = def.keepDistance
	local decided = false
	if def.static then
		decided = true -- emplacements only turn
	elseif kd and useTac then
		local ok: boolean?
		moveDir, moveSpeed, ok = Tactician.ranged(e, t, dist, dir, now)
		fireOk = ok ~= false
		decided = true
	elseif kd and tac and (tac.hold or tac.push or tac.flank or tac.retreatAt) then
		moveDir, moveSpeed = tacticalRanged(e, tac, t, dist, dir, kd, now) -- fodder shooters
		decided = true
	elseif not kd and useTac then
		local md, ms = Tactician.melee(e, t, dist, dir, now)
		if ms ~= nil then
			moveDir, moveSpeed = md, ms
			decided = true
		end
	end
	if not decided and kd then
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
	elseif not decided and e.meleeGate and not t.decoy then
		moveDir, moveSpeed = meleeMove(e, t, dist, dir, e.stopDist or 4, now)
	elseif not decided then
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
	-- ENEMY TACTICS: swarms bend their straight-in approach (only while heading straight at the target)
	if tac and tac.spread and moveDir == dir and not t.decoy then
		moveDir = spreadApproach(e, tac, dir, dist)
	end
	-- backing away: never into a wall (slide sideways or stand instead)
	local backed = false
	if moveDir and not def.static then
		moveDir, backed = safeBackoff(e, moveDir, dir)
	end
	-- convoy walkers (side objective): keep marching along the route while shooting back
	if e.routeTo then
		local rt = flat(e.routeTo - e.pos)
		if rt.Magnitude > 1 then
			moveDir = rt
			moveSpeed = e.routeSpeed or 0.5
		end
	end
	-- stuck detection: wiggle out
	if now >= e.stuckT then
		if moveDir and moveSpeed > 0.3 and flat(e.pos - e.stuckPos).Magnitude < def.speed * 0.25 then
			e.stuckUntil = now + 0.9
			-- up to 3 random headings, first one with no wall in front wins
			local pick: Vector3? = nil
			for _ = 1, 3 do
				local ang = rng:NextNumber(0, math.pi * 2)
				local d = Vector3.new(math.cos(ang), 0, math.sin(ang))
				pick = d
				if not probeBlocked(e, d) then
					break
				end
			end
			e.stuckDir = pick
		end
		e.stuckPos = e.pos
		e.stuckT = now + 1
	end
	if now < e.stuckUntil and e.stuckDir then
		moveDir = e.stuckDir
		moveSpeed = 0.9
	end
	-- fodder inside FodderSteerRange: plain seek, no obstacle raycasts
	setWish(e, moveDir, moveSpeed, backed or now < e.stuckUntil or (e.fodder == true and dist <= Config.Action.FodderSteerRange))

	-- attack decision -------------------------------------------------------------------
	if e.act or now < e.gcd then
		return
	end
	local aimErr = math.abs(wrapPi(yawOf(dir) - e.yaw))
	local close: { { idx: number, atk: any } } = {}
	local far: { { idx: number, atk: any } } = {}
	for i, atk in def.attacks do
		local gated = e.meleeGate and not e.slot and not t.decoy and MELEE_KINDS[atk.kind] -- no slot on this player: no melee / leap
		local ok = not gated and now >= e.cd[i] and not (atk.tactic and tacMode == "off") and eligible(e, atk, dist, aimErr, e.los, now)
		if ok and atk.chance then
			-- ENEMY TACTICS: "sometimes" attacks (fodder leap) roll once per eligible window; a miss waits half a cooldown
			if rng:NextNumber() >= atk.chance * strongMul("leap") then
				ok = false
				e.cd[i] = now + atk.cooldown * 0.5
			end
		end
		if ok then
			if MELEE_KINDS[atk.kind] and atk.kind ~= "charge" then
				table.insert(close, { idx = i, atk = atk })
			elseif fireOk then
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
-- Vertical error the smoothed snap may leave behind: it can hover a little above the terrain but never sink into it.
-- Without the clamp a steep slope outruns the smoothing (the gap per snap is slope * snap distance) and the model
-- alternately floats and clips through the surface.
local SNAP_RATE = 26 -- 1/s: smoothing speed, applied to the real time since the last snap (not to one frame's dt)
local SNAP_HOVER = 0.5 -- studs above the terrain
local SNAP_SINK = 0.1 -- studs below the terrain

-- Prevent horizontal movement from entering steep mountain/cliff terrain; slide along the cliff face instead.
local function moveStep(e: any, delta: Vector3): Vector3
	local hStep = flat(delta)
	local stepLen = hStep.Magnitude
	if stepLen < 1e-4 then
		return e.pos
	end
	if e.close == false and e.skipMove then
		local wn = e.wallNormal
		if wn then
			local into = hStep:Dot(wn)
			if into < 0 then
				hStep -= wn * into
			end
		end
		return clampMap(e.pos + Vector3.new(hStep.X, delta.Y, hStep.Z))
	end

	local radius = math.max(e.def.size * 0.5, 0.8)
	local look = stepLen + radius + (if e.close == false then 1.5 else 0)
	local origin = e.pos + Vector3.new(0, math.clamp(e.def.size * 0.45, 1.8, 3.5), 0)
	local r = workspace:Raycast(origin, (hStep / stepLen) * look, groundParams)
	if r and r.Normal.Y < 0.55 then
		local n = flat(r.Normal)
		if n.Magnitude > 0.01 then
			n = n.Unit
			e.wallNormal = n
			local into = hStep:Dot(n)
			if into < 0 then
				local slid = hStep - n * into
				local slidLen = slid.Magnitude
				if slidLen < 1e-4 then
					return e.pos
				end
				local r2 = workspace:Raycast(origin, (slid / slidLen) * (slidLen + radius), groundParams)
				if r2 and r2.Normal.Y < 0.55 then
					return e.pos
				end
				hStep = slid
			end
		else
			e.wallNormal = nil
		end
	else
		e.wallNormal = nil
	end
	return clampMap(e.pos + Vector3.new(hStep.X, delta.Y, hStep.Z))
end

-- exact: the model is written on this frame at the throttled rate (far from every player), so put it right on the surface
local function snapGround(e: any, dt: number, force: boolean, exact: boolean)
	local prevSnap = e.lastSnap
	local moved = flat(e.pos - prevSnap).Magnitude
	local thresh = if perfOn and not e.fodder then PERF_SNAP else e.snapDist
	if force or (exact and moved > 0.02) or moved >= thresh then
		-- Keep normal walk raycasts just above max step-up (5 studs) so steep mountain overhangs above the unit don't
		-- falsely trigger the cliff step-up reject; fall back higher only on forced snaps or missed hits.
		local topOff = if force then 12 + e.def.size * 0.5 else 5.0
		local r = workspace:Raycast(Vector3.new(e.pos.X, e.pos.Y + topOff, e.pos.Z), Vector3.new(0, -70, 0), groundParams)
		if not r and force then
			r = workspace:Raycast(Vector3.new(e.pos.X, e.pos.Y + 40, e.pos.Z), Vector3.new(0, -120, 0), groundParams)
		end
		if r then
			local gy = r.Position.Y
			if not force and gy - e.pos.Y > 4.5 and e.air <= 0 then
				e.pos = Vector3.new(prevSnap.X, e.pos.Y, prevSnap.Z)
				e.lastSnap = e.pos
				return
			end
			e.groundY = gy
			e.groundN = r.Normal
		end
		e.lastSnap = Vector3.new(e.pos.X, e.groundY or e.pos.Y, e.pos.Z)
	end

	-- Project along the last sampled slope plane so targetY descends/ascends continuously every frame without
	-- flat-hovering between raycasts and teleport-snapping down on slopes.
	local baseY = e.groundY or e.pos.Y
	local n = e.groundN or Vector3.yAxis
	local d = flat(e.pos - e.lastSnap)
	local slopeDelta = if n.Y > 0.35 then math.clamp(-(d.X * n.X + d.Z * n.Z) / n.Y, -1.8, 1.8) else 0
	local targetY = baseY + slopeDelta

	if force or exact or (e.pos.Y - targetY) > 6 then
		e.pos = Vector3.new(e.pos.X, targetY, e.pos.Z)
	else
		local k = 1 - math.exp(-SNAP_RATE * math.min(dt, 0.1))
		local y = e.pos.Y + (targetY - e.pos.Y) * k
		e.pos = Vector3.new(e.pos.X, math.clamp(y, targetY - SNAP_SINK, targetY + SNAP_HOVER), e.pos.Z)
	end
end

local function update(e: any, dt: number, now: number)
	local def = e.def
	if now >= e.nextThink then
		e.nextThink = now + e.thinkDt + rng:NextNumber(0, 0.02)
		think(e, now)
		if not e.alive then
			return
		end
	end
	if e.lumen then
		LumenAI.update(e, dt, now) -- LUMEN hook: Warden blink, Spire nodes, shield drop on stun
	end

	local frozen = e.frozenUntil ~= nil and e.frozenUntil > now
	local overridden = if frozen and not (e.act and e.act.kind == "fling") then false else runAct(e, dt, now)
	if not e.alive then
		return
	end

	local stunned = statusActive(e, "stun", now) or frozen
	local a = e.act
	local noMove = stunned or (a ~= nil and a.noMove == true)

	-- outside push (EnemyAI.push, e.g. a Gravity Well pull): added on top of the enemy's own movement
	local push = e.push
	if push then
		if push.untilT <= now then
			e.push = nil
		elseif not (a and a.kind == "fling") then
			e.pos = moveStep(e, push.v * dt) -- snapGround follows it like normal walking
		end
	end

	if not overridden then
		local target = Vector3.zero
		if not noMove and e.wishSpeed > 0 then
			local mul = 1
			local slow = e.status.slow
			if slow and slow.untilT > now then
				mul = 1 - math.clamp(slow.mag or 0.5, 0, 0.9)
			end
			local rally = e.rallyUntil -- ENEMY TACTICS: a big bug's screech
			if rally then
				if rally > now then
					mul *= e.rallyMul or 1
				else
					e.rallyUntil = nil
				end
			end
			target = e.wish * (def.speed * (e.speedMul or 1) * e.wishSpeed * mul) -- speedMul: elite SWIFT
		end
		e.vel = e.vel:Lerp(target, math.min(1, dt * (if noMove then 10 else 6)))
		if e.vel.Magnitude > 0.05 then
			e.pos = moveStep(e, e.vel * dt)
		end
	end

	-- facing
	local want: Vector3? = e.faceDirOverride or e.faceDir
	if (not want or (e.wishSpeed > 0.3 and not e.target and not e.faceHard)) and e.vel.Magnitude > 1 then
		want = e.vel
	end
	if stunned then
		want = nil
	end
	-- a fling cancelled from outside (stun interrupt, Lumen blink) must not leave the model tilted / hovering
	if e.tumble and not (a and a.kind == "fling") then
		e.tumble = nil
		e.air = 0
		e.lastCF = nil
	end
	if want and flat(want).Magnitude > 0.05 and not (a and a.phase == "active" and (a.kind == "charge" or a.kind == "fling")) then
		local diff = wrapPi(yawOf(want) - e.yaw)
		local rate = (def.turn or TURN[e.class]) * (if e.status.slow then 0.6 else 1)
		e.yaw += math.clamp(diff, -rate * dt, rate * dt)
	end
	-- emplacements: e.yaw is the turret's aim; clients turn the turret parts to TurretYaw (sent at think rate, on change)
	if def.static then
		e.turretYaw = e.yaw
		if now >= (e.turretSendAt or 0) and math.abs(wrapPi(e.yaw - (e.turretSent or 0))) > 0.02 then
			e.turretSendAt = now + THINK
			e.turretSent = e.yaw
			e.model:SetAttribute("TurretYaw", e.yaw)
		end
	end

	snapGround(e, dt, e.needSnap, e.close == false and not e.skipMove)
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
	-- no walk bob on throttled enemies: sampled at 8-20 Hz the bob aliases into random vertical hops against the terrain
	local bobY = if moving and e.close ~= false then math.abs(math.sin(e.animT)) * e.rig.bob * math.min(move, 1) else 0
	local pos = e.pos + Vector3.new(0, bobY + e.air, 0)
	local pivotYaw = if def.static then (e.baseYaw or e.yaw) else e.yaw -- emplacement body never turns
	local cf = CFrame.new(pos) * CFrame.Angles(0, pivotYaw, 0)
	if e.tumble then
		cf *= e.tumble -- blast tumble (ACTIVE.fling)
	end
	local last = e.lastCF
	local needPoseReset = e.legsAnimated and not e.rig.mesh and (not e.close or (not moving and e.windupV <= 0.01))
	if not last or moving or e.windupV > 0.01 or e.air > 0 or e.tumble ~= nil or needPoseReset or (last.Position - pos).Magnitude > 0.01 or math.abs(wrapPi(e.lastYaw - pivotYaw)) > 0.002 then
		-- perf saver: 60..150 studs update at ~20 Hz, >150 studs at ~8 Hz; lastCF / lastYaw stay stale until a non-skipped frame writes
		if not e.skipMove or not last then
			e.model:PivotTo(cf)
			e.lastCF = cf
			e.lastYaw = pivotYaw
			if not e.rig.mesh then
				if (moving or e.windupV > 0.01) and e.close then
					EnemyModels.animate(e.rig, cf, e.animT, move, e.windupV)
					e.legsAnimated = true
				elseif e.legsAnimated then
					-- reset legs to neutral once when stopping or leaving 60 studs
					EnemyModels.animate(e.rig, cf, 0, 0, 0)
					e.legsAnimated = false
				end
			end
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

local stepBody: (dt: number, enemies: { [number]: any }) -> ()

-- MicroProfiler / Server Script Performance label "EnemyAI.step" around the whole per-frame pass
function EnemyAI.step(dt: number, enemies: { [number]: any })
	if not S.Players then
		return
	end
	debug.profilebegin("EnemyAI.step")
	stepBody(dt, enemies)
	debug.profileend()
end

stepBody = function(dt: number, enemies: { [number]: any })
	local now = workspace:GetServerTimeNow()

	-- cache players once per frame
	table.clear(targets)
	table.clear(tmap)
	local plist = S.Players.getAlive()
	for _, p in plist do
		local root = S.Players.getRoot(p)
		if root then
			local t = { p = p, root = root, pos = root.Position, vel = root.AssemblyLinearVelocity, downed = p:GetAttribute("Downed") == true }
			table.insert(targets, t)
			tmap[p] = t
		end
	end
	-- Holo Decoys: separate entries (never in `targets`)
	table.clear(decoyEntries)
	if Decoys.count() > 0 then
		for _, d in Decoys.list do
			if d.alive and d.part.Parent then
				local t = { decoy = d, root = d.part, pos = d.pos, vel = Vector3.zero }
				table.insert(decoyEntries, t)
				tmap[d] = t
			end
		end
	end

	if os.clock() - lastFilter > 1 then
		lastFilter = os.clock()
		rebuildFilter()
	end
	Tactician.updateHazards(now)

	table.clear(snapshot)
	for _, e in enemies do
		table.insert(snapshot, e)
	end

	-- separation grid (see GRID_CELL): old cell lists back to the pool, then bucket every alive enemy
	for _, list in grid do
		table.clear(list)
		table.insert(gridPool, list)
	end
	table.clear(grid)
	gridMaxSize = 0
	for _, e in snapshot do
		local key = (math.floor(e.pos.X / GRID_CELL) + 32768) * 65536 + (math.floor(e.pos.Z / GRID_CELL) + 32768)
		if e.alive and key == key then -- (key ~= key only for a NaN position, which can't be a table key)
			local list = grid[key]
			if not list then
				list = table.remove(gridPool) or {}
				grid[key] = list
			end
			table.insert(list, e)
			if e.def.size > gridMaxSize then
				gridMaxSize = e.def.size
			end
		end
	end

	-- melee slot tally (who holds / waits for a slot on which player)
	refreshSlotMax(os.clock())
	table.clear(slotCount)
	table.clear(waiting)
	for _, e in snapshot do
		local sl = e.slot
		if sl then
			if tmap[sl] then
				slotCount[sl] = (slotCount[sl] or 0) + 1
			else
				e.slot = nil -- the player went down / left
			end
		end
		local ci = e.circling
		if ci then
			if tmap[ci] then
				waiting[ci] = (waiting[ci] or 0) + 1
			else
				e.circling = nil
			end
		end
	end

	-- perf saver: active by default on live servers; Studio Feel_PerfSaver ("off" / "touch" / "all") overrides it.
	-- Within 60 studs: every frame; 60..150 studs: ~20 Hz; beyond: ~8 Hz.
	local saverMode = if IS_STUDIO then workspace:GetAttribute("Feel_PerfSaver") else nil
	local saver = saverMode ~= "off" and saverMode ~= false
	if IS_STUDIO then
		local perf = workspace:GetAttribute("Feel_Perf")
		perfOn = perf == "touch" or perf == "all"
		local tm = workspace:GetAttribute("Feel_EnemyTactics")
		tacMode = if tm == "strong" or tm == "off" then tm else "on"
	end

	for _, e in snapshot do
		if e.alive then
			local minDsq = math.huge
			for _, t in targets do
				local dx = t.pos.X - e.pos.X
				local dz = t.pos.Z - e.pos.Z
				local dsq = dx * dx + dz * dz
				if dsq < minDsq then
					minDsq = dsq
				end
			end
			e.near = minDsq < 230 * 230
			local close = not saver or minDsq <= SAVER_NEAR * SAVER_NEAR
			e.close = close
			if close then
				e.skipMove = false
				e.moveAccum = 0
			else
				local interval = if minDsq <= SAVER_MID * SAVER_MID then SAVER_MID_DT else SAVER_FAR_DT
				local acc = e.moveAccum
				if acc == nil then
					-- stagger initial phase across enemies so throttled PivotTo calls spread evenly across frames
					acc = ((tonumber(e.id) or 0) % 8) * (interval / 8)
				end
				acc += dt
				if acc >= interval then
					e.skipMove = false
					e.moveAccum = acc % interval
				else
					e.skipMove = true
					e.moveAccum = acc
				end
			end
			update(e, dt, now)
		end
	end
end

function EnemyAI.init(s: { [string]: any })
	S = s
	LumenAI.init(s) -- LUMEN hook
	Awareness.init(s)
	Tactician.init(s)
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
