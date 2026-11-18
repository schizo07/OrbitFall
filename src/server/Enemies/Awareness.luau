-- Enemy awareness: guard / patrol / suspicious / alert / search. Plain module (not a service); EnemyAI drives it each think.
--
--   Awareness.init(S)
--   Awareness.register(e, opts)        opts.posture "guard" | "patrol" | "hunt" | nil (nil => "hunt" if opts.aggro / opts.target,
--                                      else "guard"), opts.route {Vector3}? (patrol loop), opts.squad any? (shared alerts),
--                                      opts.home Vector3?
--   Awareness.unregister(e)
--   Awareness.sense(e, now)            at think rate. Updates e.awareState, e.awareTarget, e.lastKnown, e.suspicion (0..1)
--   Awareness.isAlert(e) -> boolean    true => combat AI runs
--   Awareness.idle(e, now) -> (wish dir?, speed mult, face dir?)   movement while not alert
--   Awareness.alert(e, player?, pos?, reason)   force alert; spreads to the squad (instant) and to nearby same-faction units (delayed)
--   Awareness.noise(pos, radius, player?)       gunfire / explosions: nearby unaware enemies get suspicious (close ones alert)
--   Awareness.lost(e, now)             combat AI lost sight of every target for a while => search around lastKnown
--
-- Sight: a ~110 degree front cone out to the class range, plus a short "feel" radius all around. LOS is one raycast per enemy at
-- most every LOS_EVERY seconds (staggered). Suspicion builds faster when close, in the middle of the cone, or when the player is
-- sprinting / just fired; slower when crouched / prone; decays out of sight. Brood build up slowly while lurking, then snap to alert.
--
-- Model attributes for clients: Aware = "idle" | "sus" | "alert", Suspicion = 0..1 (steps of 0.1, written only on change).
-- Units that spawn hunting never get Aware written until their first change, so wave spawns show no markers.
--
-- Studio A/B: workspace attribute Feel_NoticeSpeed (number, default 1) scales how fast suspicion builds (Studio only).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local Awareness = {}

local S: { [string]: any } = {}
local rng = Random.new()
local IS_STUDIO = RunService:IsStudio()

-- Tuning -------------------------------------------------------------------------------
-- sight range per class (studs): the combat detection radii (95 / 115 / 135 / 190 x AggroMult) x SIGHT_MULT
local RANGE = { regular = 95, medium = 115, heavy = 135, behemoth = 190 }
local SIGHT_MULT = 0.9
for k, v in RANGE do
	RANGE[k] = v * (Config.Action.AggroMult or 1) * SIGHT_MULT
end
local CONE_COS = math.cos(math.rad(55)) -- 110 degree cone
local FEEL = 15 -- studs: noticed all around (behind too), still needs LOS
local MARGIN = 20 -- early-out: no alive player within range + MARGIN => no work
local LOS_EVERY = 0.3 -- seconds between sight raycasts per enemy
local ALERT_LOS_EVERY = 0.45 -- while alert (only refreshes lastKnown)
local SUS_ENTER = 0.1 -- suspicion at which the unit turns "suspicious"
local DECAY = 0.2 -- per second while nothing is seen
local SEARCH_DECAY = 0.08
local SPREAD_R = 35 -- non-squad allies within this many studs follow an alert ...
local SPREAD_DELAY_MIN, SPREAD_DELAY_MAX = 0.3, 0.8 -- ... after this delay
local SEARCH_LOOK_MIN, SEARCH_LOOK_MAX = 6, 8 -- seconds of looking around at lastKnown
local NOISE_EVERY = 0.25 -- per player: shots closer together than this count once
local NOISE_ALERT_FRAC = 0.35 -- inside radius x this, a noise alerts outright
local SHOT_MEMORY = 1.5 -- seconds a shot keeps a shooter "loud" for sight build-up

-- base suspicion build per second (scaled by distance / cone / activity)
local BASE_RATE = { COG = 0.55, BROOD = 0.42, LUMEN = 0.6 }
local BROOD_SNAP_AT = 0.3 -- Brood: past this suspicion the build-up runs BROOD_SNAP x faster
local BROOD_SNAP = 2.8

local SPEED = {
	patrol = 0.45,
	guardStep = 0.3,
	homeward = 0.45,
	investigate = 0.35,
	searchGo = 0.6,
	searchLook = 0.4,
}

-- Registry -----------------------------------------------------------------------------
local reg: { any } = {}
local regIndex: { [any]: number } = {}
local squads: { [any]: { [any]: boolean } } = {}

-- Player cache (refreshed at most every 0.1 s) -----------------------------------------
type PInfo = { p: Player, root: BasePart, pos: Vector3, speed: number, stance: string? }
local pcache: { PInfo } = {}
local pcacheT = -1
local lastShot: { [Player]: number } = {}
local noiseNext: { [Player]: number } = {}

local function refreshPlayers()
	local t = os.clock()
	if t - pcacheT < 0.1 then
		return
	end
	pcacheT = t
	table.clear(pcache)
	local SP = S.Players
	local alive: { Player }
	if SP and SP.getAlive then
		alive = SP.getAlive()
	else
		-- not initialised: every player with a living character
		alive = {}
		for _, p in Players:GetPlayers() do
			local h = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
			if h and h.Health > 0 then
				table.insert(alive, p)
			end
		end
	end
	for _, p in alive do
		local root = if SP and SP.getRoot
			then SP.getRoot(p)
			else (p.Character and p.Character:FindFirstChild("HumanoidRootPart")) :: BasePart?
		if root then
			local v = root.AssemblyLinearVelocity
			local c = p.Character
			table.insert(pcache, {
				p = p,
				root = root,
				pos = root.Position,
				speed = Vector3.new(v.X, 0, v.Z).Magnitude,
				stance = c and c:GetAttribute("Stance"),
			})
		end
	end
end

-- LOS ----------------------------------------------------------------------------------
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
losParams.RespectCanCollide = true
losParams.IgnoreWater = true
local filterT = -100

local function refreshFilter()
	local t = os.clock()
	if t - filterT < 2 then
		return
	end
	filterT = t
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
	losParams.FilterDescendantsInstances = list
end

local function inSmoke(pos: Vector3): boolean
	local ci = S.CallIns
	if ci and ci.isInSmoke then
		return ci.isInSmoke(pos) == true
	end
	return false
end

local function eyeOf(e: any): Vector3
	return e.pos + Vector3.new(0, math.min(e.def.size or 2, 4) + 1, 0)
end

local function rayClear(e: any, to: Vector3): boolean
	refreshFilter()
	local from = eyeOf(e)
	return workspace:Raycast(from, to - from, losParams) == nil
end

-- Helpers ------------------------------------------------------------------------------
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

local function rangeOf(e: any): number
	return RANGE[e.class] or RANGE.regular
end

local noticeV = 1
local noticeT = -100
local function noticeMult(): number
	if not IS_STUDIO then
		return 1
	end
	local t = os.clock()
	if t - noticeT > 1 then
		noticeT = t
		local v = workspace:GetAttribute("Feel_NoticeSpeed")
		noticeV = if type(v) == "number" and v > 0 then v else 1
	end
	return noticeV
end

local AWARE_ATTR = {
	guard = "idle",
	patrol = "idle",
	suspicious = "sus",
	search = "sus",
	alert = "alert",
}

local function publish(e: any)
	local m = e.model
	if not m or not m.Parent then
		return
	end
	local a: string? = AWARE_ATTR[e.awareState] or "idle"
	if a == "alert" and e.awQuiet then
		a = nil -- hunting again after a search: no marker, no "!" pop
	end
	if e.awSentAware ~= a then
		e.awSentAware = a
		m:SetAttribute("Aware", a)
	end
	local q = math.floor(math.clamp(e.suspicion or 0, 0, 1) * 10 + 0.5) / 10
	if e.awSentSus ~= q then
		e.awSentSus = q
		m:SetAttribute("Suspicion", q)
	end
end

local function restState(e: any): string
	if e.awPosture == "patrol" then
		return "patrol"
	elseif e.awPosture == "hunt" then
		return "alert"
	end
	return "guard"
end

local function clampMap(p: Vector3): Vector3
	local half = (Config.MapSize or 2000) / 2 - 6
	return Vector3.new(math.clamp(p.X, -half, half), p.Y, math.clamp(p.Z, -half, half))
end

local function buildRoute(home: Vector3): { Vector3 }
	local n = 3
	local a0 = rng:NextNumber(0, math.pi * 2)
	local route = {}
	for i = 1, n do
		local a = a0 + (i - 1) * (math.pi * 2 / n) + rng:NextNumber(-0.4, 0.4)
		local r = rng:NextNumber(12, 22)
		table.insert(route, clampMap(home + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)))
	end
	return route
end

-- Register -----------------------------------------------------------------------------
function Awareness.init(s: { [string]: any })
	S = s
	Players.PlayerRemoving:Connect(function(p)
		lastShot[p] = nil
		noiseNext[p] = nil
	end)
end

function Awareness.register(e: any, opts: any)
	opts = opts or {}
	if regIndex[e] then
		Awareness.unregister(e)
	end
	table.insert(reg, e)
	regIndex[e] = #reg

	local posture = opts.posture
	if posture ~= "guard" and posture ~= "patrol" and posture ~= "hunt" then
		posture = if opts.aggro or opts.target then "hunt" else "guard"
	end
	e.awPosture = posture
	e.awHome = opts.home or e.pos or (e.root and e.root.Position) or Vector3.zero
	if posture == "patrol" then
		local route = opts.route
		e.awRoute = if type(route) == "table" and #route >= 1 then route else buildRoute(e.awHome)
		e.awRouteI = 1
		e.awPauseUntil = 0
	end
	e.awSquad = opts.squad
	if opts.squad ~= nil then
		local sq = squads[opts.squad]
		if not sq then
			sq = {}
			squads[opts.squad] = sq
		end
		sq[e] = true
	end

	local now = workspace:GetServerTimeNow()
	e.awLosT = now + rng:NextNumber(0, LOS_EVERY)
	e.awLosP = nil
	e.awLosV = false
	e.awSeen = false
	e.awSenseT = now
	e.awIdleT = now
	e.awFaceYaw = nil
	e.awLookYaw = nil
	e.awLookNext = 0
	e.awStepNext = now + rng:NextNumber(8, 16)
	e.awStepTo = nil
	e.awSentAware = nil
	e.awSentSus = nil

	if posture == "hunt" then
		e.awareState = "alert"
		e.suspicion = 1
		local tgt = opts.target
		e.awareTarget = if typeof(tgt) == "Instance" and tgt:IsA("Player") then tgt else nil
		e.lastKnown = nil
		-- no attribute yet: wave spawns carry no marker
	else
		e.awareState = posture
		e.suspicion = 0
		e.awareTarget = nil
		e.lastKnown = nil
		publish(e)
	end
end

function Awareness.unregister(e: any)
	local i = regIndex[e]
	if i then
		local last = reg[#reg]
		reg[i] = last
		regIndex[last] = i
		reg[#reg] = nil
		regIndex[e] = nil
	end
	local key = e.awSquad
	if key ~= nil then
		local sq = squads[key]
		if sq then
			sq[e] = nil
			if next(sq) == nil then
				squads[key] = nil
			end
		end
	end
end

function Awareness.isAlert(e: any): boolean
	if not regIndex[e] then
		return true -- not tracked: behave like the plain combat AI
	end
	return e.awareState == "alert"
end

-- Alert --------------------------------------------------------------------------------
local function setAlert(e: any, player: Player?, pos: Vector3?, now: number)
	e.awareState = "alert"
	e.suspicion = 1
	if player then
		e.awareTarget = player
	end
	if pos then
		e.lastKnown = pos
	elseif player and S.Players and S.Players.getRoot then
		local r = S.Players.getRoot(player)
		if r then
			e.lastKnown = r.Position
		end
	end
	e.awAlertT = now
	e.awSearchUntil = nil
	e.awQuiet = nil
	publish(e)
end

local function spread(e: any, player: Player?, pos: Vector3?, now: number, radius: boolean)
	-- squad: instant
	local key = e.awSquad
	if key ~= nil then
		local sq = squads[key]
		if sq then
			for o in sq do
				if o ~= e and o.alive ~= false and o.awareState ~= "alert" then
					setAlert(o, player, pos, now)
				end
			end
		end
	end
	if not radius then
		return
	end
	-- same faction nearby: after a short delay (they hear / see the commotion)
	local ep = e.pos
	if not ep then
		return
	end
	for _, o in reg do
		if o ~= e and o.awareState ~= "alert" and o.faction == e.faction and o.pos and (key == nil or o.awSquad ~= key) then
			if flat(o.pos - ep).Magnitude <= SPREAD_R then
				task.delay(rng:NextNumber(SPREAD_DELAY_MIN, SPREAD_DELAY_MAX), function()
					if regIndex[o] and o.alive ~= false and o.awareState ~= "alert" then
						local t = workspace:GetServerTimeNow()
						setAlert(o, player, pos, t)
						spread(o, player, pos, t, false) -- their own squad follows; no further radius chain
					end
				end)
			end
		end
	end
end

function Awareness.alert(e: any, player: Player?, pos: Vector3?, reason: string)
	if not regIndex[e] then
		return
	end
	local now = workspace:GetServerTimeNow()
	local was = e.awareState
	setAlert(e, player, pos, now)
	if was ~= "alert" then
		spread(e, player, pos, now, reason ~= "ally")
	end
end

function Awareness.lost(e: any, now: number)
	if not regIndex[e] or e.awareState ~= "alert" then
		return
	end
	if not e.lastKnown then
		e.lastKnown = e.pos
	end
	e.awareState = "search"
	e.suspicion = 0.5
	e.awSearchPhase = "go"
	e.awSearchUntil = nil
	e.awSearchStart = now
	e.awStepTo = nil
	publish(e)
end

-- Noise --------------------------------------------------------------------------------
function Awareness.noise(pos: Vector3, radius: number, player: Player?)
	if radius <= 0 then
		return
	end
	local clock = os.clock()
	if player then
		lastShot[player] = clock
		if clock < (noiseNext[player] or 0) then
			return
		end
		noiseNext[player] = clock + NOISE_EVERY
	end
	local now = workspace:GetServerTimeNow()
	local alertR = radius * NOISE_ALERT_FRAC
	for i = #reg, 1, -1 do
		local e = reg[i]
		if e and e.awareState ~= "alert" and e.pos and e.alive ~= false then
			local d = flat(e.pos - pos).Magnitude
			if d <= radius then
				if d <= alertR then
					Awareness.alert(e, player, pos, "noise")
				else
					local add = 0.25 + 0.45 * (1 - d / radius)
					e.suspicion = math.min(0.95, (e.suspicion or 0) + add)
					if e.awareState ~= "search" then
						e.awareState = "suspicious"
						e.awSusStart = now
					end
					-- heard, not seen: the guess lands a little off the real spot
					local err = d * 0.08
					e.lastKnown = pos + Vector3.new(rng:NextNumber(-err, err), 0, rng:NextNumber(-err, err))
					if player then
						e.awareTarget = player
					end
					e.awInvestigateHold = now + 0.6 -- stop and turn first
					publish(e)
				end
			end
		end
	end
end

-- Sense --------------------------------------------------------------------------------
-- Visible check for one player, cached per enemy for LOS_EVERY seconds.
local function visible(e: any, info: PInfo, now: number, every: number): boolean
	if e.awLosP == info.p and now < e.awLosT then
		return e.awLosV
	end
	e.awLosP = info.p
	e.awLosT = now + every * rng:NextNumber(0.85, 1.15)
	local ok = not inSmoke(info.pos) and rayClear(e, info.pos)
	e.awLosV = ok
	return ok
end

local function senseAlert(e: any, now: number)
	-- keep lastKnown honest: refresh it only while the target is in sight (or very close)
	local tgt = e.awareTarget
	if tgt then
		local info: PInfo? = nil
		for _, pi in pcache do
			if pi.p == tgt then
				info = pi
				break
			end
		end
		if not info then
			e.awareTarget = nil -- down / gone: combat AI picks the next one
			return
		end
		local d = flat(info.pos - e.pos).Magnitude
		if d <= FEEL or visible(e, info, now, ALERT_LOS_EVERY) then
			e.lastKnown = info.pos
		end
	end
end

function Awareness.sense(e: any, now: number)
	if not regIndex[e] or not e.pos then
		return
	end
	local dt = math.clamp(now - (e.awSenseT or now), 0, 0.5)
	e.awSenseT = now
	refreshPlayers()

	local state = e.awareState
	if state == "alert" then
		senseAlert(e, now)
		return
	end

	-- pick the most noticeable player in range (no work at all when nobody is near)
	local range = rangeOf(e)
	local look = heading(e.yaw or 0)
	local best: PInfo? = nil
	local bestD = math.huge
	local bestCos = -1
	local reach = range + MARGIN
	for _, pi in pcache do
		local to = flat(pi.pos - e.pos)
		local d = to.Magnitude
		if d <= reach then
			local c = if d > 0.01 then look:Dot(to / d) else 1
			if (c >= CONE_COS and d <= range) or d <= FEEL then
				if d < bestD then
					best = pi
					bestD = d
					bestCos = c
				end
			end
		end
	end

	local seen = false
	if best and visible(e, best, now, LOS_EVERY) then
		seen = true
		local inCone = bestCos >= CONE_COS
		local close = math.clamp(1 - bestD / range, 0, 1)
		local rate = (BASE_RATE[e.faction] or 0.55) * (0.4 + 2.2 * close ^ 1.5)
		if inCone then
			-- centre of the cone 1, edge 0.55
			local centre = math.clamp((bestCos - CONE_COS) / (1 - CONE_COS), 0, 1)
			rate *= 0.55 + 0.45 * centre
		else
			rate *= 0.6 -- felt behind
		end
		if best.speed > (Config.WalkSpeed or 16) + 3 then
			rate *= 1.6
		end
		local shot = lastShot[best.p]
		if shot and os.clock() - shot < SHOT_MEMORY then
			rate *= 2
		end
		if best.stance == "crouch" then
			rate *= 0.6
		elseif best.stance == "prone" then
			rate *= 0.28
		end
		if state == "search" then
			rate *= 2 -- already looking for them
		end
		if e.faction == "BROOD" and (e.suspicion or 0) >= BROOD_SNAP_AT then
			rate *= BROOD_SNAP
		end
		rate *= noticeMult()
		e.suspicion = math.min(1, (e.suspicion or 0) + rate * dt)
		e.lastKnown = best.pos
		e.awareTarget = best.p
		if e.suspicion >= 1 then
			Awareness.alert(e, best.p, best.pos, "sight")
			return
		end
	else
		local decay = if state == "search" then SEARCH_DECAY else DECAY
		e.suspicion = math.max(0, (e.suspicion or 0) - decay * dt)
	end
	e.awSeen = seen

	if state == "guard" or state == "patrol" then
		if e.suspicion >= SUS_ENTER then
			e.awareState = "suspicious"
			e.awSusStart = now
			e.awInvestigateHold = now + 0.8
		end
	elseif state == "suspicious" then
		if e.suspicion <= 0 then
			e.awareState = restState(e)
			e.awareTarget = nil
		end
	elseif state == "search" then
		local untilT = e.awSearchUntil
		if untilT and now >= untilT then
			e.awareState = restState(e)
			e.awareTarget = nil
			e.awStepTo = nil
			if e.awareState == "alert" then
				e.awQuiet = true -- hunters go back to hunting without a marker
				e.suspicion = 1
			else
				e.suspicion = 0
			end
		elseif not untilT and now - (e.awSearchStart or now) > 25 then
			-- never reached lastKnown (blocked): start looking around where it stands
			e.awSearchPhase = "look"
			e.awSearchUntil = now + rng:NextNumber(SEARCH_LOOK_MIN, SEARCH_LOOK_MAX)
		end
	end
	publish(e)
end

-- Idle movement ------------------------------------------------------------------------
-- Turn the facing slowly toward a target yaw (rad/s), return the face dir.
local function sweepFace(e: any, targetYaw: number, rate: number, dt: number): Vector3
	local cur = e.awFaceYaw or e.yaw or targetYaw
	local diff = wrapPi(targetYaw - cur)
	local stepMax = rate * dt
	cur += math.clamp(diff, -stepMax, stepMax)
	e.awFaceYaw = cur
	return heading(cur)
end

local function lookAround(e: any, now: number, dt: number, spreadRad: number, every0: number, every1: number, rate: number): Vector3
	if not e.awBaseYaw then
		e.awBaseYaw = e.yaw or 0
	end
	if e.awLookBase ~= e.awBaseYaw then
		e.awLookBase = e.awBaseYaw
		e.awLookYaw = nil -- new centre: pick a fresh look target around it
	end
	if not e.awLookYaw or now >= e.awLookNext then
		e.awLookNext = now + rng:NextNumber(every0, every1)
		e.awLookYaw = e.awBaseYaw + rng:NextNumber(-spreadRad, spreadRad)
	end
	return sweepFace(e, e.awLookYaw, rate, dt)
end

local function toward(e: any, p: Vector3): (Vector3?, number)
	local to = flat(p - e.pos)
	local d = to.Magnitude
	if d < 0.01 then
		return nil, 0
	end
	return to / d, d
end

local function guardIdle(e: any, now: number, dt: number): (Vector3?, number, Vector3?)
	local brood = e.faction == "BROOD"
	local static = e.def.static == true
	if not e.awGuardYaw then
		e.awGuardYaw = e.yaw or 0 -- the facing it was placed with: look-arounds centre on it
	end
	-- walk back home first
	local homeDir, homeD = toward(e, e.awHome)
	if not static and homeDir and homeD > 8 and not e.awStepTo then
		e.awFaceYaw = nil
		return homeDir, SPEED.homeward, nil
	end
	e.awBaseYaw = e.awGuardYaw
	-- occasional small reposition (Brood: a short twitch)
	if not static and now >= e.awStepNext then
		e.awStepNext = now + (if brood then rng:NextNumber(5, 11) else rng:NextNumber(10, 18))
		local chance = if brood then 0.5 else 0.35
		if rng:NextNumber() < chance then
			local a = rng:NextNumber(0, math.pi * 2)
			local r = if brood then rng:NextNumber(1, 2.5) else rng:NextNumber(3, 6)
			e.awStepTo = e.awHome + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
			e.awStepGiveUp = now + 4
		end
	end
	if e.awStepTo then
		local d, dist = toward(e, e.awStepTo)
		if not d or dist < 1 or now > (e.awStepGiveUp or 0) then
			e.awStepTo = nil
			e.awFaceYaw = e.yaw
		else
			return d, if brood then 0.25 else SPEED.guardStep, nil
		end
	end
	if brood then
		return nil, 0, lookAround(e, now, dt, 0.35, 1.5, 4, 2.5)
	end
	return nil, 0, lookAround(e, now, dt, 1.4, 2.5, 5, 0.9)
end

local function patrolIdle(e: any, now: number, dt: number): (Vector3?, number, Vector3?)
	local route = e.awRoute
	if not route or #route == 0 or e.def.static then
		return guardIdle(e, now, dt)
	end
	if now < (e.awPauseUntil or 0) then
		-- short pause at a point: glance around
		return nil, 0, lookAround(e, now, dt, 0.9, 0.8, 1.6, 1.4)
	end
	local i = e.awRouteI or 1
	if i > #route then
		i = 1
	end
	local p = route[i]
	local d, dist = toward(e, p)
	if not e.awLegGiveUp or e.awLegI ~= i then
		e.awLegI = i
		e.awLegGiveUp = now + (dist / math.max((e.def.speed or 10) * SPEED.patrol, 1)) * 2 + 4
	end
	if not d or dist < 3 or now > e.awLegGiveUp then
		e.awRouteI = i % #route + 1
		e.awLegGiveUp = nil
		e.awPauseUntil = now + rng:NextNumber(1, 2.5)
		e.awBaseYaw = e.yaw
		e.awLookYaw = nil
		e.awFaceYaw = e.yaw
		return nil, 0, nil
	end
	e.awHome = e.pos -- guard fallback / search return happen from where it walks
	e.awFaceYaw = nil
	return d, SPEED.patrol, nil
end

local function suspiciousIdle(e: any, now: number, dt: number): (Vector3?, number, Vector3?)
	local lk = e.lastKnown
	if not lk then
		return nil, 0, nil
	end
	local d, dist = toward(e, lk)
	local face = d
	-- stop and stare while the source is still in view (or right after the first notice), then walk over slowly
	if e.awSeen or now < (e.awInvestigateHold or 0) or e.def.static then
		if face then
			e.awFaceYaw = yawOf(face)
		end
		return nil, 0, face
	end
	if d and dist > 4 then
		e.awFaceYaw = nil
		return d, SPEED.investigate, nil
	end
	-- at the spot: look around while the suspicion runs out
	if not e.awBaseYaw or not e.awAtSpot then
		e.awAtSpot = true
		e.awBaseYaw = e.yaw
		e.awLookYaw = nil
	end
	return nil, 0, lookAround(e, now, dt, 1.6, 1, 2, 1.8)
end

local function searchIdle(e: any, now: number, dt: number): (Vector3?, number, Vector3?)
	local lk = e.lastKnown or e.pos
	if e.awSearchPhase ~= "look" then
		local d, dist = toward(e, lk)
		if d and dist > 5 and not e.def.static then
			e.awFaceYaw = nil
			return d, SPEED.searchGo, nil
		end
		e.awSearchPhase = "look"
		e.awSearchUntil = now + rng:NextNumber(SEARCH_LOOK_MIN, SEARCH_LOOK_MAX)
		e.awBaseYaw = e.yaw
		e.awLookYaw = nil
		e.awFaceYaw = e.yaw
		e.awStepTo = nil
		e.awStepNext = now + rng:NextNumber(1, 2)
	end
	-- look phase: short hops around lastKnown with quick looks
	if not e.def.static and not e.awStepTo and now >= (e.awStepNext or 0) then
		e.awStepNext = now + rng:NextNumber(2, 3.5)
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(5, 10)
		e.awStepTo = lk + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
		e.awStepGiveUp = now + 3
	end
	if e.awStepTo then
		local d, dist = toward(e, e.awStepTo)
		if not d or dist < 1.5 or now > (e.awStepGiveUp or 0) then
			e.awStepTo = nil
			e.awBaseYaw = e.yaw
			e.awFaceYaw = e.yaw
		else
			return d, SPEED.searchLook, nil
		end
	end
	return nil, 0, lookAround(e, now, dt, math.pi, 0.7, 1.4, 3)
end

function Awareness.idle(e: any, now: number): (Vector3?, number, Vector3?)
	if not regIndex[e] or not e.pos then
		return nil, 0, nil
	end
	local dt = math.clamp(now - (e.awIdleT or now), 0, 0.5)
	e.awIdleT = now
	local state = e.awareState
	if state ~= "suspicious" then
		e.awAtSpot = nil
	end
	if state == "guard" then
		return guardIdle(e, now, dt)
	elseif state == "patrol" then
		return patrolIdle(e, now, dt)
	elseif state == "suspicious" then
		return suspiciousIdle(e, now, dt)
	elseif state == "search" then
		return searchIdle(e, now, dt)
	end
	return nil, 0, nil
end

return Awareness
