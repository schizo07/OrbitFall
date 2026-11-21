-- Squad tactics for alert ground enemies (EnemyAI asks it for a move each think). A plain module, not a service.
--
--   Tactician.init(S)
--   Tactician.clear()
--   Tactician.register(e, opts) / Tactician.unregister(e)          opts.squad (any) groups units into one squad
--   Tactician.updateHazards(now)                                   periodic scan of active grenades / offensive call-in beacons
--   Tactician.evadeDanger(e, now) -> (wishDir?, speedMul)          radial scatter from nearby blast hazards
--   Tactician.ranged(e, t, dist, dir, now) -> (wishDir?, speedMul, fireOk)
--   Tactician.melee(e, t, dist, dir, now)  -> (wishDir?, speedMul)?   nil = EnemyAI's own melee move
--   Tactician.onDamaged(e, fromPos, dmgFrac?)
--
-- Shooters (COG / LUMEN regular + medium keepDistance units): coordinated cover cycle
--   Squad roles:
--     * Suppressors: hold firing cover with staggered peek cycles so the squad maintains continuous overlapping fire.
--     * Flankers: actively advance 65-110 deg around the target's facing (split left/right), re-evaluating periodically.
--     * Heavy Pushers (Bulwark / Prism Lancer): purposefully push the center lane to force targets out of cover while regulars flank.
--   Flush: if the target stays occluded > 2.5 s, flankers and close-range shooters break cover and push an angled flush vector.
--   Heavy fire: rapid hits make peeking units duck immediately and open-ground units bound laterally/backward to deeper cover.
-- Brood pack tactics:
--   * Melee packs divide into center pressure, wide left/right wraparound wings, and rear cutoff runners (pack >= 4).
--   * Spitters actively kite and reposition behind friendly Brood melee screens with clean lateral firing lanes.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local EnemyData = require(Shared.Data.Enemies)
local Cover = require(script.Parent.Cover)

local Tactician = {}

local TAC = EnemyData.Tactics
local MAP_HALF = Config.MapSize / 2 - 6
local rng = Random.new()

local HIDE = { 0.7, 1.5 }
local HIDE_FAST = { 0.25, 0.55 } -- shortened hide when no squadmate is suppressing
local HIDE_STAGGER = { 1.15, 1.85 } -- lengthened hide when squadmates are already peeking
local PEEK_T = { 2.2, 3.6 }
local MOVE_T = 7 -- give up walking to a cover point after this long (flankers get FLANK_T)
local FLANK_T = 10
local FLANK_REVAL = 4.5 -- seconds between flanker angle re-evaluations
local FLUSH_AFTER = 2.5 -- seconds occluded before flankers/shooters push to flush target out of cover
local FIND_RETRY = 1.8 -- seconds between cover searches that found nothing
local RECHECK = 1.8 -- seconds between "is my cover still hiding me" checks
local REACH = 2 -- studs from a point that count as there
local MAX_TRAVEL = 52 -- never pick a cover point further than this from the unit
local SQUAD_CELL = 70
local PROBE_LEN = 6
local PROBE_HOLD = 0.6 -- a probed back-off / side-step direction is reused this long
local MELEE_STRAIGHT = math.max(12, Config.Action.MeleeClaimRange or 14)

-- Hazard detection (live grenades & incoming offensive call-in beacons in workspace.CallInObjects)
local HAZARD_EVERY = 0.2
local BEACON_RADIUS = 24
local GRENADE_RADIUS = 15
local HAZARD_HYSTERESIS = 6

type Hazard = { pos: Vector3, radius: number, kind: string }
local hazards: { Hazard } = {}
local nextHazardScan = 0

local S_ref: { [string]: any } = {}
local squads: { [any]: { [any]: boolean } } = {}
local broodMelee: { [any]: boolean } = {} -- living non-fodder Brood melee units (for Spitter screen positioning)
local packSlots: { [any]: { [any]: number } } = setmetatable({}, { __mode = "k" }) :: any

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function clampMap(p: Vector3): Vector3
	return Vector3.new(math.clamp(p.X, -MAP_HALF, MAP_HALF), p.Y, math.clamp(p.Z, -MAP_HALF, MAP_HALF))
end

local function rot(deg: number, v: Vector3): Vector3
	return CFrame.Angles(0, math.rad(deg), 0) * v
end

local function coverUser(e: any): boolean
	local def = e.def
	return def.keepDistance ~= nil
		and not def.static
		and not e.fodder
		and e.routeTo == nil
		and (e.class == "regular" or e.class == "medium")
		and e.faction ~= "BROOD"
end

local function heavyPusher(e: any): boolean
	local def = e.def
	return def.keepDistance ~= nil
		and not def.static
		and not e.fodder
		and e.routeTo == nil
		and e.class == "heavy"
		and e.faction ~= "BROOD"
end

local function isBroodSpitter(e: any): boolean
	return e.faction == "BROOD" and e.def.keepDistance ~= nil and not e.def.static
end

local function isBroodMelee(e: any): boolean
	return e.faction == "BROOD" and not e.def.keepDistance and not e.def.static and e.class ~= "behemoth"
end

-- Registration -----------------------------------------------------------------------------------
local function joinSquad(e: any, key: any)
	local st = e.tc
	if st.squadKey == key then
		return
	end
	if st.squadKey ~= nil and squads[st.squadKey] then
		squads[st.squadKey][e] = nil
		if next(squads[st.squadKey]) == nil then
			squads[st.squadKey] = nil
		end
	end
	st.squadKey = key
	local set = squads[key]
	if not set then
		set = {}
		squads[key] = set
	end
	set[e] = true
end

function Tactician.register(e: any, opts: any?)
	local sgn = if rng:NextNumber() < 0.5 then 1 else -1
	e.tc = {
		role = nil,
		flankSide = sgn,
		phase = "open",
		cover = nil,
		untilT = 0,
		nextFind = 0,
		nextCheck = 0,
		nextFlankEval = 0,
		peekAt = 0,
		hiddenSince = nil,
		occludedSince = nil,
		lastSeenPos = nil,
		lastSeenVel = Vector3.zero,
		flushUntil = 0,
		flushSign = sgn,
		wounded = false,
		squadKey = nil,
		-- heavy-fire reaction
		hitWinStart = 0,
		hitCount = 0,
		hitDmg = 0,
		evadeFireUntil = 0,
		evadeFireDir = nil,
		suppressedUntil = 0,
		-- danger evasion
		evadingDanger = false,
		-- open band hold
		stepping = false,
		stepUntil = 0,
		stepSign = sgn,
		mDir = nil,
		mUntil = 0,
		-- melee pincer approach
		packSlot = nil,
		packKey = nil,
		packEvalAt = 0,
		packJitter = rng:NextNumber(-12, 12),
		packRearSide = sgn,
		zig = rng:NextNumber(0, math.pi * 2),
	}
	local key = (opts and opts.squad) or e.squad
	if key ~= nil then
		joinSquad(e, key)
	end
	if isBroodMelee(e) then
		broodMelee[e] = true
	end
end

local function dropCover(e: any, st: any)
	if st.cover then
		Cover.release(e)
	end
	st.cover = nil
	st.phase = "open"
end

function Tactician.unregister(e: any)
	broodMelee[e] = nil
	local st = e.tc
	if not st then
		return
	end
	Cover.release(e)
	if st.packKey ~= nil then
		local slots = packSlots[st.packKey]
		if slots then
			slots[e] = nil
		end
	end
	if st.squadKey ~= nil and squads[st.squadKey] then
		local set = squads[st.squadKey]
		set[e] = nil
		if next(set) == nil then
			squads[st.squadKey] = nil
		end
	end
	e.tc = nil
end

function Tactician.clear()
	table.clear(squads)
	table.clear(broodMelee)
	table.clear(hazards)
	nextHazardScan = 0
	Cover.clear()
end

local function state(e: any): any
	if not e.tc then
		Tactician.register(e, nil)
	end
	return e.tc
end

-- Squad roles & coordination ---------------------------------------------------------------------
local function ensureSquad(e: any, st: any)
	if st.squadKey == nil then
		joinSquad(e, string.format("a:%s:%d:%d", tostring(e.faction), math.floor(e.pos.X / SQUAD_CELL), math.floor(e.pos.Z / SQUAD_CELL)))
	end
end

-- Assigns dynamic roles per squad: Heavy Pushers take center lane, ~1/3 of cover users flank (balanced left/right), rest suppress.
local function assignRole(e: any, st: any)
	ensureSquad(e, st)
	if heavyPusher(e) then
		st.role = "pusher"
		return
	end
	local set = squads[st.squadKey]
	local n, flankers, leftF, rightF = 0, 0, 0, 0
	for o in set do
		if not o.alive or not o.tc then
			set[o] = nil
		elseif coverUser(o) then
			n += 1
			if o.tc.role == "flanker" then
				flankers += 1
				if (o.tc.flankSide or 1) >= 0 then
					rightF += 1
				else
					leftF += 1
				end
			end
		end
	end
	local wantFlankers = if n >= 2 then math.max(1, math.floor((n + 1) / 3)) else 0
	if flankers < wantFlankers then
		st.role = "flanker"
		st.flankSide = if rightF <= leftF then 1 else -1
	else
		st.role = "suppress"
	end
end

local function squadStatus(e: any, st: any): (number, number, boolean)
	local set = st.squadKey and squads[st.squadKey]
	if not set then
		return 0, 0, false
	end
	local suppressors, peeking = 0, 0
	local hasFlanker = false
	for o in set do
		if not o.alive or not o.tc then
			set[o] = nil
		elseif o ~= e then
			local ot = o.tc
			if ot.role == "flanker" then
				hasFlanker = true
			elseif ot.role == "suppress" and ot.cover then
				suppressors += 1
				if ot.phase == "peek" then
					peeking += 1
				end
			end
		end
	end
	return suppressors, peeking, hasFlanker
end

local function threatBoost(): number
	local d = S_ref.Director
	if d and d.getThreat then
		return math.clamp((d.getThreat() or 0) / 4, 0, 1)
	end
	return 0
end

-- Target is holding ground or backpedaling slowly in the open -> squad closes in and flanks aggressively
local function targetPressurable(t: any, dir: Vector3): boolean
	if not t or not t.vel then
		return false
	end
	local tv = flat(t.vel)
	local spd = tv.Magnitude
	if spd < 4.5 then
		return true
	end
	return spd < Config.SprintSpeed * 0.8 and tv:Dot(dir) > 1.5
end

-- Probed moves -----------------------------------------------------------------------------------
-- First direction in `list` whose probe is clear (cached PROBE_HOLD s), or nil when every one hits a wall.
local function probedPick(e: any, st: any, list: { Vector3 }, now: number): Vector3?
	if st.mDir and now < st.mUntil then
		return st.mDir
	end
	st.mUntil = now + PROBE_HOLD
	for _, d in list do
		if d.Magnitude > 0.01 then
			local u = d.Unit
			if not Cover.probe(e, u, PROBE_LEN) then
				st.mDir = u
				return u
			end
		end
	end
	st.mDir = nil
	return nil
end

-- Danger awareness (live grenades & incoming offensive call-in beacons) --------------------------
local function isOffensiveColor(c: Color3): boolean
	return c.R > 0.8 and c.G < 0.45 and c.B < 0.45
end

local function isGrenadeLight(light: PointLight): boolean
	local c = light.Color
	return light.Range <= 8 and c.R > 0.85 and c.G > 0.22 and c.G < 0.55 and c.B < 0.3
end

-- Called once per EnemyAI.step; scans workspace.CallInObjects at most every HAZARD_EVERY seconds.
function Tactician.updateHazards(now: number)
	if now < nextHazardScan then
		return
	end
	nextHazardScan = now + HAZARD_EVERY
	table.clear(hazards)
	local folder = workspace:FindFirstChild("CallInObjects")
	if not folder then
		return
	end
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			if child.Name == "Beacon" then
				local light = child:FindFirstChildOfClass("PointLight")
				local col = if light then light.Color else child.Color
				if isOffensiveColor(col) then
					table.insert(hazards, { pos = child.Position, radius = BEACON_RADIUS, kind = "beacon" })
				end
			elseif not child.Anchored then
				local light = child:FindFirstChildOfClass("PointLight")
				if light and isGrenadeLight(light) then
					table.insert(hazards, { pos = child.Position, radius = GRENADE_RADIUS, kind = "grenade" })
				end
			end
		end
	end
end

-- Mobile non-fodder, non-behemoth, non-static units break cover and sprint radially away from live blast zones.
function Tactician.evadeDanger(e: any, now: number): (Vector3?, number)
	if #hazards == 0 or e.fodder or e.def.static or e.class == "behemoth" or e.routeTo ~= nil then
		if e.tc then
			e.tc.evadingDanger = false
		end
		return nil, 0
	end
	local st = state(e)
	local extra = if st.evadingDanger then HAZARD_HYSTERESIS else 0
	local awaySum = Vector3.zero
	local inDanger = false
	for _, h in hazards do
		local delta = flat(e.pos - h.pos)
		local d = delta.Magnitude
		local lim = h.radius + extra
		if d < lim then
			inDanger = true
			local dir = if d > 0.2 then delta / d else rot(rng:NextNumber(0, 360), Vector3.xAxis)
			local weight = 1 + (1 - d / lim)
			awaySum += dir * weight
		end
	end
	if not inDanger then
		st.evadingDanger = false
		return nil, 0
	end
	if not st.evadingDanger then
		-- Break cover immediately when a threat lands nearby
		dropCover(e, st)
		st.flushUntil = 0
		st.nextFind = now + 1.2
		st.mDir = nil
		st.mUntil = 0
	end
	st.evadingDanger = true
	local esc = if awaySum.Magnitude > 0.05 then awaySum.Unit else rot(rng:NextNumber(0, 360), Vector3.xAxis)
	local picked = probedPick(e, st, {
		esc,
		rot(45, esc),
		rot(-45, esc),
		rot(85, esc),
		rot(-85, esc),
		rot(125, esc),
		rot(-125, esc),
	}, now)
	return picked or esc, 1.2
end

-- Open-ground band hold (no cover, flankers without cover, fallback) -----------------------------
local function bandHold(e: any, st: any, t: any, dist: number, dir: Vector3, kd: number, now: number): (Vector3?, number, boolean)
	local tac = e.def.tactics or {}
	local press = e.los and targetPressurable(t, dir)
	local th = threatBoost()
	local pref = kd * (tac.push or 1) * (if press then 0.8 else 0.92) * (1 - 0.1 * th)
	if st.wounded then
		pref *= tac.retreatMul or 1.3
	end
	local hold = tac.hold or TAC.holdDefault
	local side = Vector3.new(-dir.Z, 0, dir.X)

	-- Under heavy fire in the open: bound laterally/backward briefly instead of facetanking
	if now < (st.evadeFireUntil or 0) and st.evadeFireDir then
		local d = probedPick(e, st, { st.evadeFireDir, -dir + side * st.stepSign, side * st.stepSign, -side * st.stepSign }, now)
		if d then
			return d, 1.08, false
		end
	end

	if st.role == "flanker" and not st.wounded and dist > pref * hold[1] * 0.9 and dist < kd * 1.45 then
		local sgn = st.flankSide or st.stepSign
		local flankDir = (dir * (if dist > pref * hold[2] then 0.82 else 0.45) + side * (sgn * 0.8)).Unit
		local d = probedPick(e, st, { flankDir, dir, side * sgn }, now)
		if d then
			return d, 1.06, true
		end
	end
	if not e.los or dist > pref * hold[2] then
		st.mDir = nil
		return dir, if press then 1.06 else 1, true
	elseif dist < pref * hold[1] then
		local s = st.stepSign
		local d = probedPick(e, st, { -dir + side * (0.5 * s), -dir - side * (0.5 * s), side * s, -side * s }, now)
		if d then
			return d, 0.85, true
		end
		return nil, 0, true
	end
	if now >= st.stepUntil then
		st.mDir = nil
		st.mUntil = 0
		if st.stepping then
			st.stepping = false
			st.stepUntil = now + rng:NextNumber(TAC.pause[1], TAC.pause[2]) * (if press then 0.75 else 1)
		else
			st.stepping = true
			st.stepUntil = now + rng:NextNumber(TAC.step[1], TAC.step[2])
			if rng:NextNumber() < 0.6 then
				st.stepSign = -st.stepSign
			end
		end
	end
	if st.stepping then
		local adv = if press then dir * 0.35 else Vector3.zero
		local d = probedPick(e, st, { (side * st.stepSign + adv).Unit, (-side * st.stepSign + adv).Unit }, now)
		if d then
			return d, if press then 0.92 else 0.82, true
		end
		st.stepping = false
	end
	return nil, 0, true
end

-- Heavy Pusher (Bulwark / Prism Lancer): presses center lane to force player out of cover while squadmates flank.
local function pusherHold(e: any, st: any, _t: any, dist: number, dir: Vector3, kd: number, now: number): (Vector3?, number, boolean)
	if st.role == nil then
		assignRole(e, st)
	end
	local _, _, hasFlanker = squadStatus(e, st)
	local tac = e.def.tactics or {}
	local th = threatBoost()
	-- Push tighter down the center lane when squadmates are flanking or target is hiding behind cover
	local pushScale = (tac.push or 0.75) * (if hasFlanker then 0.88 else 0.96) * (1 - 0.08 * th)
	local wantDist = math.max(11, kd * pushScale)
	local side = Vector3.new(-dir.Z, 0, dir.X)

	if not e.los then
		-- Target behind cover: advance steadily down the center lane to collapse their cover
		local pushDir = (dir + side * (st.stepSign * 0.18)).Unit
		local d = probedPick(e, st, { pushDir, dir, (dir + side * (st.stepSign * 0.55)).Unit, (dir - side * (st.stepSign * 0.55)).Unit }, now)
		return d or dir, 1.0, true
	end
	if dist > wantDist then
		-- Purposeful steady advance while firing
		local weave = if now % 4 < 2 then 0.15 else -0.15
		local adv = (dir + side * weave).Unit
		local d = probedPick(e, st, { adv, dir }, now)
		return d or dir, 0.95, true
	elseif dist < wantDist * 0.52 then
		local d = probedPick(e, st, { -dir + side * (0.4 * st.stepSign), side * st.stepSign, -side * st.stepSign }, now)
		if d then
			return d, 0.65, true
		end
		return nil, 0, true
	end
	-- Inside ideal center pressure range: slow lateral pressure shift to keep firing lane open
	if now >= st.stepUntil then
		st.mDir = nil
		st.mUntil = 0
		st.stepping = not st.stepping
		st.stepUntil = now + rng:NextNumber(1.0, 2.0)
		if rng:NextNumber() < 0.5 then
			st.stepSign = -st.stepSign
		end
	end
	if st.stepping then
		local d = probedPick(e, st, { (side * st.stepSign + dir * 0.25).Unit, (-side * st.stepSign + dir * 0.25).Unit }, now)
		if d then
			return d, 0.6, true
		end
	end
	return nil, 0, true
end

-- Brood Spitter kiting & repositioning behind friendly melee screens -----------------------------
local function spitterHold(e: any, st: any, t: any, dist: number, dir: Vector3, kd: number, now: number): (Vector3?, number, boolean)
	local side = Vector3.new(-dir.Z, 0, dir.X)
	local minSafe = kd * 0.72
	local maxRange = kd * 1.16

	-- Priority 1: Active kiting if target closes into dangerous range (never walk into point-blank)
	if dist < minSafe then
		local s = st.stepSign
		local retreatA = (-dir * 0.86 + side * (0.5 * s)).Unit
		local retreatB = (-dir * 0.86 - side * (0.5 * s)).Unit
		local d = probedPick(e, st, { retreatA, retreatB, -dir, side * s, -side * s }, now)
		if d then
			-- Allow firing if still outside point-blank, pure sprint-kite if very close
			return d, if dist < kd * 0.48 then 1.12 else 1.0, dist >= kd * 0.45
		end
		return nil, 0, true
	end

	-- Priority 2: Blocked LOS -> sidestep laterally to open a clean firing lane rather than walking forward into melee
	if not e.los then
		local s = st.stepSign
		local angleA = (side * (0.85 * s) + dir * (if dist > maxRange then 0.52 else 0.15)).Unit
		local angleB = (side * (-0.85 * s) + dir * (if dist > maxRange then 0.52 else 0.15)).Unit
		local d = probedPick(e, st, { angleA, angleB, dir }, now)
		return d or dir, 0.95, true
	end

	-- Priority 3: Reposition behind nearby friendly Brood melee screens with clean lateral offset
	local screenSum = Vector3.zero
	local screenN = 0
	for m in broodMelee do
		if not m.alive or not m.pos then
			broodMelee[m] = nil
		elseif flat(m.pos - t.pos).Magnitude <= 34 then
			screenSum += m.pos
			screenN += 1
		end
	end
	if screenN > 0 then
		local centroid = screenSum / screenN
		local fromTarget = flat(centroid - t.pos)
		if fromTarget.Magnitude > 1.5 then
			local backAxis = fromTarget.Unit
			-- Desired anchor: behind the melee screen at keepDistance, offset laterally by +/-24 deg for a clean firing lane
			local anchorDir = rot(24 * st.stepSign, backAxis)
			local anchor = clampMap(t.pos + anchorDir * (kd * 0.96))
			local toAnchor = flat(anchor - e.pos)
			if toAnchor.Magnitude > 6 then
				local mv = toAnchor.Unit
				-- Avoid cutting closer to the target than minSafe while repositioning
				if dist < kd * 0.85 and mv:Dot(dir) > 0.2 then
					mv = (mv - dir * (mv:Dot(dir) + 0.25)).Unit
				end
				local d = probedPick(e, st, { mv, side * st.stepSign, -side * st.stepSign }, now)
				if d then
					return d, 0.92, true
				end
			end
		end
	end

	-- Priority 4: Too far -> close into firing band
	if dist > maxRange then
		st.mDir = nil
		return dir, 0.95, true
	end

	-- Inside clean band: periodic lateral strafe to stay evasive
	if now >= st.stepUntil then
		st.mDir = nil
		st.mUntil = 0
		st.stepping = not st.stepping
		st.stepUntil = now + rng:NextNumber(0.9, 1.8)
		if rng:NextNumber() < 0.55 then
			st.stepSign = -st.stepSign
		end
	end
	if st.stepping then
		local d = probedPick(e, st, { side * st.stepSign, -side * st.stepSign }, now)
		if d then
			return d, 0.78, true
		end
		st.stepping = false
	end
	return nil, 0, true
end

-- Cover pick -------------------------------------------------------------------------------------
local function pickCover(e: any, st: any, t: any, kd: number, now: number): Cover.Cand?
	local lo, hi = kd * 0.55, kd * 1.12
	if st.wounded or now < (st.suppressedUntil or 0) then
		lo, hi = kd * 0.9, kd * 1.5
	end
	local myD = flat(e.pos - t.pos).Magnitude
	local center = e.pos
	local want: Vector3? = nil
	if st.role == "flanker" then
		local face = flat(t.root.CFrame.LookVector)
		face = if face.Magnitude > 0.1 then face.Unit else flat(e.pos - t.pos).Unit
		local sgn = st.flankSide or 1
		-- Advance 65-110 deg around the player's facing to break their cover
		local flankAngle = sgn * rng:NextNumber(65, 110)
		want = clampMap(t.pos + rot(flankAngle, face) * (kd * 0.78))
		local wv = want :: Vector3
		if flat(wv - e.pos).Magnitude <= MAX_TRAVEL + 18 then
			center = e.pos:Lerp(wv, 0.65)
		end
	end
	local cands = Cover.query(center, t.pos, now)
	if #cands == 0 then
		return nil
	end
	-- Score every available candidate (zero extra raycasts), then validate line-of-fire on top pick(s)
	local scored: { { c: Cover.Cand, s: number } } = {}
	for _, c in cands do
		local dT = flat(c.pos - t.pos).Magnitude
		local dE = flat(c.pos - e.pos).Magnitude
		if dT >= 10 and dE <= MAX_TRAVEL + (if want then 20 else 0) and not Cover.taken(c.pos, e) then
			local s = dE + (math.max(0, lo - dT) + math.max(0, dT - hi)) * 2.5
			if (st.wounded or now < (st.suppressedUntil or 0)) and dT < myD then
				s += 42
			end
			-- never run past the target to reach a point on its far side
			if (c.pos - t.pos):Dot(e.pos - t.pos) < 0 then
				s += 60
			end
			if want then
				s += flat(c.pos - want).Magnitude * 1.15
			end
			-- Spread firing arcs across cover and reward angular flank separation
			s += Cover.crowdPenalty(c.pos, e, 16)
			s += Cover.angularPenalty(c.pos, t.pos, e, st.role)
			table.insert(scored, { c = c, s = s })
		end
	end
	if #scored == 0 then
		return nil
	end
	table.sort(scored, function(a, b)
		return a.s < b.s
	end)
	-- Reject cached cover whose peek spot no longer has line-of-fire (capped to top 2 candidates -> max 2 raycasts)
	for i = 1, math.min(#scored, 2) do
		local cand = scored[i].c
		if Cover.sees(cand.peek, t.pos) then
			return cand
		end
	end
	return nil
end

-- Flush maneuver (target stayed behind cover > FLUSH_AFTER s) ------------------------------------
local function flushMove(e: any, st: any, t: any, dir: Vector3, now: number): (Vector3?, number, boolean)
	if e.los then
		-- Regained LOS: brief follow-through past the corner, then resume normal cover/combat
		st.flushUntil = math.min(st.flushUntil, now + 0.45)
	end
	local goal = st.lastSeenPos or t.pos
	if st.lastSeenVel and st.lastSeenVel.Magnitude > 1.5 then
		goal = clampMap(goal + st.lastSeenVel.Unit * 6)
	end
	local toGoal = flat(goal - e.pos)
	local baseDir = if toGoal.Magnitude > 2 then toGoal.Unit else dir
	local side = Vector3.new(-baseDir.Z, 0, baseDir.X)
	local sgn = st.flushSign or st.flankSide or 1
	-- Push at a ~42 deg angled flank/flush vector around the player's cover
	local flushA = (baseDir * 0.74 + side * (0.67 * sgn)).Unit
	local flushB = (baseDir * 0.74 - side * (0.67 * sgn)).Unit
	local d = probedPick(e, st, { flushA, baseDir, flushB, side * sgn }, now)
	return d or baseDir, if st.role == "flanker" then 1.08 else 1.0, true
end

-- Ranged -----------------------------------------------------------------------------------------
function Tactician.ranged(e: any, t: any, dist: number, dir: Vector3, now: number): (Vector3?, number, boolean)
	local def = e.def
	if def.static then
		return nil, 0, true
	end
	local st = state(e)
	local kd = def.keepDistance or 30

	-- Track target visibility & last known position/velocity for flush behavior
	if e.los then
		st.occludedSince = nil
		st.lastSeenPos = t.pos
		st.lastSeenVel = flat(t.vel or Vector3.zero)
	else
		st.occludedSince = st.occludedSince or now
	end

	-- Brood Spitters: dedicated kiting + melee screen positioning
	if isBroodSpitter(e) then
		return spitterHold(e, st, t, dist, dir, kd, now)
	end

	-- Heavy Pushers (Bulwark / Prism Lancer): purposeful center-lane push
	if heavyPusher(e) then
		return pusherHold(e, st, t, dist, dir, kd, now)
	end

	if not coverUser(e) then
		return bandHold(e, st, t, dist, dir, kd, now)
	end

	local tac = def.tactics or {}
	if not st.wounded and e.maxHp and e.maxHp > 0 and e.hp / e.maxHp <= (tac.retreatAt or 0.4) then
		st.wounded = true
		dropCover(e, st)
		st.flushUntil = 0
		st.nextFind = 0
	end
	if st.role == nil then
		assignRole(e, st)
	end

	-- Flush trigger: target stayed behind cover for > FLUSH_AFTER s -> flankers & close/mid shooters push an angled flush vector
	if not st.wounded and st.occludedSince and (now - st.occludedSince) >= FLUSH_AFTER then
		local canFlush = st.role == "flanker" or dist <= kd * 1.05
		if canFlush and now >= (st.flushUntil or 0) then
			dropCover(e, st)
			st.flushUntil = now + rng:NextNumber(3.2, 4.6)
			st.flushSign = st.flankSide or (if rng:NextNumber() < 0.5 then 1 else -1)
			st.nextFind = st.flushUntil
		end
	end
	if now < (st.flushUntil or 0) then
		return flushMove(e, st, t, dir, now)
	end

	-- target ran far off: drop the cover and follow
	if st.cover and dist > kd * (if st.wounded then 2 else 1.6) then
		dropCover(e, st)
		st.nextFind = now + 1
	end

	-- Flanker periodic re-evaluation: if player turned to face the flanker, relocate to a fresh 65-110 deg flank cover
	if st.role == "flanker" and st.cover and st.phase ~= "move" and now >= (st.nextFlankEval or 0) then
		st.nextFlankEval = now + FLANK_REVAL + rng:NextNumber(0, 1.5)
		local face = flat(t.root.CFrame.LookVector)
		local toMe = flat(e.pos - t.pos)
		if face.Magnitude > 0.1 and toMe.Magnitude > 4 then
			local dot = face.Unit:Dot(toMe.Unit)
			if dot > 0.62 then
				-- Target is looking right at this flanker: bound to a fresh flank angle
				dropCover(e, st)
				st.nextFind = 0
			end
		end
	end

	if not st.cover and now >= st.nextFind then
		local c = pickCover(e, st, t, kd, now)
		if c then
			st.cover = c
			Cover.claim(e, c.pos)
			st.phase = "move"
			st.untilT = now + (if st.role == "flanker" then FLANK_T else MOVE_T)
			st.nextCheck = now + RECHECK
			st.nextFlankEval = now + FLANK_REVAL
			st.nextFind = now + FIND_RETRY
		else
			st.nextFind = now + FIND_RETRY
		end
	end
	local cover = st.cover
	if not cover then
		return bandHold(e, st, t, dist, dir, kd, now)
	end

	-- the target moved round the cover (or peek spot lost line-of-fire): find another
	if st.phase ~= "move" and now >= st.nextCheck then
		st.nextCheck = now + RECHECK
		if not Cover.hidden(cover.pos, t.pos) or not Cover.sees(cover.peek, t.pos) then
			dropCover(e, st)
			st.nextFind = 0
			return bandHold(e, st, t, dist, dir, kd, now)
		end
	end

	if st.phase == "move" then
		local to = flat(cover.pos - e.pos)
		if to.Magnitude <= REACH then
			st.phase = "hide"
			-- Stagger suppressor peek timing across the squad so not everyone ducks at once
			local hideRange = HIDE
			if st.role == "suppress" and now >= (st.suppressedUntil or 0) then
				local supN, peekN = squadStatus(e, st)
				if supN >= 1 and peekN == 0 then
					hideRange = HIDE_FAST
				elseif peekN >= 2 then
					hideRange = HIDE_STAGGER
				end
			end
			st.untilT = now + rng:NextNumber(hideRange[1], hideRange[2])
			st.nextCheck = now + RECHECK
			return nil, 0, false
		end
		if now >= st.untilT then
			dropCover(e, st)
			st.nextFind = now + FIND_RETRY
			return bandHold(e, st, t, dist, dir, kd, now)
		end
		local mv = to.Unit
		-- swing wide round the target instead of cutting close past it
		local away = flat(e.pos - t.pos)
		if away.Magnitude < kd * 0.5 and away.Magnitude > 0.1 then
			mv = (mv + away.Unit * 0.8).Unit
		end
		return mv, if st.role == "flanker" then 1.08 else 1, false
	elseif st.phase == "hide" then
		-- Suppressor relay: if nobody else in the squad is peeking, pop up early to keep pressure on
		local ready = now >= st.untilT
		if not ready and st.role == "suppress" and now >= (st.suppressedUntil or 0) then
			local supN, peekN = squadStatus(e, st)
			if supN >= 1 and peekN == 0 and (st.untilT - now) > 0.35 then
				st.untilT = now + 0.25
			end
		end
		if ready then
			st.phase = "peek"
			st.peekAt = now
			local th = threatBoost()
			st.untilT = now + rng:NextNumber(PEEK_T[1], PEEK_T[2]) * (1 + 0.15 * th)
			st.hiddenSince = nil
		end
		return nil, 0, false
	end

	-- peek
	if now >= st.untilT and not e.act then
		st.phase = "move"
		st.untilT = now + 4
		return flat(cover.pos - e.pos).Unit, 1, false
	end
	if not e.los then
		st.hiddenSince = st.hiddenSince or now
		if now - st.hiddenSince > 1.5 then
			-- peek spot no longer sees the target
			dropCover(e, st)
			st.nextFind = 0
			return dir, 1, true
		end
	else
		st.hiddenSince = nil
	end
	local to = flat(cover.peek - e.pos)
	if to.Magnitude > 1 then
		return to.Unit, 0.75, to.Magnitude < 2.5
	end
	return nil, 0, true
end

-- Melee (Brood pincer / encirclement) ------------------------------------------------------------
-- Pack slots per target:
--   1 = center pressure (0 deg)
--   2 = wide left wraparound wing (+85 deg)
--   3 = wide right wraparound wing (-85 deg)
--   4 = rear cutoff runner (+/-155 deg, arcing around the side before closing behind the target)
local function assignPackSlot(e: any, st: any, key: any): (number, number)
	if st.packKey ~= nil and st.packKey ~= key then
		local prev = packSlots[st.packKey]
		if prev then
			prev[e] = nil
		end
	end
	local slots = packSlots[key]
	if not slots then
		slots = {}
		packSlots[key] = slots
	end
	local counts = { [1] = 0, [2] = 0, [3] = 0, [4] = 0 }
	local total = 0
	for o, s in slots do
		if not o.alive or not o.tc or o.tc.packKey ~= key then
			slots[o] = nil
		elseif o ~= e then
			total += 1
			counts[s] = (counts[s] or 0) + 1
		end
	end
	total += 1
	-- Pick the least-populated role; unlock rear cutoff (slot 4) once pack >= 4
	local maxSlot = if total >= 4 then 4 else 3
	local pick = 1
	local bestC = math.huge
	for s = 1, maxSlot do
		local c = counts[s] or 0
		if c < bestC then
			bestC = c
			pick = s
		end
	end
	slots[e] = pick
	st.packKey = key
	st.packSlot = pick
	st.packJitter = rng:NextNumber(-12, 12)
	st.packRearSide = if counts[2] <= counts[3] then 1 else -1
	return pick, total
end

-- (nil, nil) = EnemyAI's own melee move
function Tactician.melee(e: any, t: any, dist: number, dir: Vector3, now: number): (Vector3?, number?)
	local def = e.def
	if def.keepDistance or e.class == "heavy" or e.class == "behemoth" or t.decoy then
		return nil, nil
	end
	if dist <= MELEE_STRAIGHT then
		return nil, nil
	end
	local st = state(e)
	local key = t.p or t.root
	if st.packKey ~= key or not st.packSlot or now >= (st.packEvalAt or 0) then
		st.packEvalAt = now + rng:NextNumber(3.5, 5.5)
		assignPackSlot(e, st, key)
	end

	-- Anchor pincer bearings to the target's facing (falls back to approach vector when unavailable)
	local face = flat(t.root.CFrame.LookVector)
	local anchor = if face.Magnitude > 0.1 then face.Unit else -dir
	local slot = st.packSlot or 1

	local bearingDeg = st.packJitter
	local speedMul = 1.0
	local arcRadius = MELEE_STRAIGHT + 2

	if slot == 1 then
		-- Center pressure: front lane to pin the player's aim
		bearingDeg = st.packJitter
		arcRadius = MELEE_STRAIGHT + 1
	elseif slot == 2 then
		-- Wide left wraparound wing
		bearingDeg = 85 + st.packJitter
		speedMul = 1.08
		arcRadius = math.clamp(dist * 0.48, MELEE_STRAIGHT + 3, 24)
	elseif slot == 3 then
		-- Wide right wraparound wing
		bearingDeg = -85 + st.packJitter
		speedMul = 1.08
		arcRadius = math.clamp(dist * 0.48, MELEE_STRAIGHT + 3, 24)
	else
		-- Rear cutoff runner: arc wide around a flank first if still in front, then cut off the player's backpedal lane
		local toMe = flat(e.pos - t.pos)
		local inFront = toMe.Magnitude > 0.1 and toMe.Unit:Dot(anchor) > 0.15
		if inFront then
			bearingDeg = (108 + st.packJitter * 0.6) * (st.packRearSide or 1)
			arcRadius = math.clamp(dist * 0.55, MELEE_STRAIGHT + 5, 28)
		else
			bearingDeg = (158 + st.packJitter) * (st.packRearSide or 1)
			arcRadius = MELEE_STRAIGHT + 3
		end
		speedMul = 1.12
	end

	local wingDir = rot(bearingDeg, anchor)
	local w = clampMap(t.pos + wingDir * arcRadius)
	local to = flat(w - e.pos)
	if to.Magnitude < 4 then
		return nil, nil
	end
	local mv = to.Unit
	local k = math.clamp((dist - MELEE_STRAIGHT) / 22, 0, 1)
	if k > 0 then
		local perp = Vector3.new(-mv.Z, 0, mv.X)
		mv = (mv + perp * (math.sin(now * 2.6 + st.zig) * 0.3 * k)).Unit
	end
	return mv, speedMul
end

-- Damage (heavy-fire evasive reaction) -----------------------------------------------------------
function Tactician.onDamaged(e: any, fromPos: Vector3, dmgFrac: number?)
	local st = e.tc
	if not st or not e.alive or e.def.static then
		return
	end
	local now = workspace:GetServerTimeNow()
	if now - (st.hitWinStart or 0) > 1.4 then
		st.hitWinStart = now
		st.hitCount = 0
		st.hitDmg = 0
	end
	st.hitCount = (st.hitCount or 0) + 1
	st.hitDmg = (st.hitDmg or 0) + (dmgFrac or 0.08)
	local heavyFire = st.hitCount >= 3 or st.hitDmg >= 0.18

	if not coverUser(e) then
		-- Brood Spitters / non-cover ranged units juke sideways/back when hit under heavy fire
		if isBroodSpitter(e) and heavyFire then
			st.stepSign = -st.stepSign
			st.mDir = nil
			st.mUntil = 0
		end
		return
	end

	if st.phase == "open" then
		st.nextFind = 0
		if heavyFire then
			-- Caught in the open under heavy fire: bound backward + sideways immediately toward deeper cover
			local away = flat(e.pos - fromPos)
			away = if away.Magnitude > 0.1 then away.Unit else rot(rng:NextNumber(0, 360), Vector3.xAxis)
			local side = Vector3.new(-away.Z, 0, away.X) * st.stepSign
			st.evadeFireDir = (away * 0.72 + side * 0.69).Unit
			st.evadeFireUntil = now + 0.9
			st.suppressedUntil = now + 1.2
			st.mDir = nil
			st.mUntil = 0
		end
	elseif st.phase == "peek" then
		-- Rapid fire snaps peeking shooters back into cover right away; single hit ducks after 0.55 s
		if heavyFire or (now - st.peekAt > 0.55) then
			st.phase = "move"
			st.untilT = now + 4
			if heavyFire then
				st.suppressedUntil = now + rng:NextNumber(0.8, 1.35)
			end
		end
	elseif st.phase == "hide" and heavyFire then
		-- Taking heavy hits while supposedly hidden: cover is compromised -> re-check and bound to deeper cover
		st.suppressedUntil = now + 1.4
		st.nextCheck = 0
	end
end

function Tactician.init(s: { [string]: any })
	S_ref = s
	Cover.init(s)
end

return Tactician
