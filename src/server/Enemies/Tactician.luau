-- Squad tactics for alert ground enemies (EnemyAI asks it for a move each think). A plain module, not a service.
--
--   Tactician.init(S)
--   Tactician.register(e, opts) / Tactician.unregister(e)          opts.squad (any) groups units into one squad
--   Tactician.ranged(e, t, dist, dir, now) -> (wishDir?, speedMul, fireOk)
--   Tactician.melee(e, t, dist, dir, now)  -> (wishDir?, speedMul)?   nil = EnemyAI's own melee move
--   Tactician.onDamaged(e, fromPos)
--
-- Shooters (COG / LUMEN regular + medium keepDistance units): cover cycle
--   move to a cover point (no shooting) -> hide 1-2.5 s -> step out to the peek spot and shoot 1.8-3.2 s -> back -> hide ...
--   Cover points come from Cover.luau (shared scan per area, claimed so two units never share one). No cover around: hold the
--   keepDistance band with side-steps like before, but every back-off / side-step is probed first, so nobody backs into a wall.
--   Roles: one "flanker" per 3-4 shooters of a squad (opts.squad, else same faction in the same 70-stud cell) picks its cover
--   60-100 degrees off the way the target faces; the rest "suppress" from covers near where they stand.
--   Wounded (hp below def.tactics.retreatAt, else 40 %): leaves its cover for one further back.
--   Shot while standing in the open: looks for cover right away; shot while peeking: ducks back early.
-- Heavies / behemoths (Bulwark, Colossus) and Brood spitters: band hold only (no cover). Static emplacements: stand.
-- Melee (Brood regulars / mediums): each unit takes an approach bearing (straight, +70 or -70 degrees, jittered, dealt round-robin
--   per target) so a pack arrives from 2-3 sides, zig-zags lightly on the way, and the last ~14 studs are left to EnemyAI
--   (straight in / melee slots). Heavies and behemoths return nil (charge / stomp stay in EnemyAI).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local EnemyData = require(Shared.Data.Enemies)
local Cover = require(script.Parent.Cover)

local Tactician = {}

local TAC = EnemyData.Tactics
local MAP_HALF = Config.MapSize / 2 - 6
local rng = Random.new()

local HIDE = { 1, 2.5 }
local PEEK_T = { 1.8, 3.2 }
local MOVE_T = 7 -- give up walking to a cover point after this long (flankers get FLANK_T)
local FLANK_T = 11
local FIND_RETRY = 2.5 -- seconds between cover searches that found nothing
local RECHECK = 2 -- seconds between "is my cover still hiding me" checks
local REACH = 2 -- studs from a point that count as there
local MAX_TRAVEL = 45 -- never pick a cover point further than this from the unit
local SQUAD_CELL = 70
local PROBE_LEN = 6
local PROBE_HOLD = 0.6 -- a probed back-off / side-step direction is reused this long
local MELEE_STRAIGHT = math.max(12, Config.Action.MeleeClaimRange or 14)
local MELEE_SIDES = { 0, 70, -70 }

local squads: { [any]: { [any]: boolean } } = {}
local packCount: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any

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

-- Registration -----------------------------------------------------------------------------------
local function joinSquad(e: any, key: any)
	local st = e.tc
	if st.squadKey == key then
		return
	end
	if st.squadKey ~= nil and squads[st.squadKey] then
		squads[st.squadKey][e] = nil
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
	e.tc = {
		role = nil,
		phase = "open",
		cover = nil,
		untilT = 0,
		nextFind = 0,
		nextCheck = 0,
		peekAt = 0,
		hiddenSince = nil,
		wounded = false,
		squadKey = nil,
		-- open band hold
		stepping = false,
		stepUntil = 0,
		stepSign = if rng:NextNumber() < 0.5 then 1 else -1,
		mDir = nil,
		mUntil = 0,
		-- melee approach
		bearing = nil,
		bearKey = nil,
		zig = rng:NextNumber(0, math.pi * 2),
	}
	local key = (opts and opts.squad) or e.squad
	if key ~= nil then
		joinSquad(e, key)
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
	local st = e.tc
	if not st then
		return
	end
	Cover.release(e)
	if st.squadKey ~= nil and squads[st.squadKey] then
		local set = squads[st.squadKey]
		set[e] = nil
		if next(set) == nil then
			squads[st.squadKey] = nil
		end
	end
	e.tc = nil
end

local function state(e: any): any
	if not e.tc then
		Tactician.register(e, nil)
	end
	return e.tc
end

-- Roles: the n-th shooter of a squad becomes the flanker while the squad has fewer than floor((n + 1) / 4) of them
local function assignRole(e: any, st: any)
	if st.squadKey == nil then
		joinSquad(e, string.format("a:%s:%d:%d", tostring(e.faction), math.floor(e.pos.X / SQUAD_CELL), math.floor(e.pos.Z / SQUAD_CELL)))
	end
	local set = squads[st.squadKey]
	local n, flankers = 0, 0
	for o in set do
		if not o.alive or not o.tc then
			set[o] = nil
		elseif coverUser(o) then
			n += 1
			if o.tc.role == "flanker" then
				flankers += 1
			end
		end
	end
	st.role = if flankers < math.floor((n + 1) / 4) then "flanker" else "suppress"
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

-- Open-ground band hold (no cover, heavies, spitters): approach above the band, back off below it, side-step / plant inside it.
local function bandHold(e: any, st: any, _t: any, dist: number, dir: Vector3, kd: number, now: number): (Vector3?, number, boolean)
	local tac = e.def.tactics or {}
	local pref = kd * (tac.push or 1)
	if st.wounded then
		pref *= tac.retreatMul or 1.3
	end
	local hold = tac.hold or TAC.holdDefault
	local side = Vector3.new(-dir.Z, 0, dir.X)
	if not e.los or dist > pref * hold[2] then
		st.mDir = nil
		return dir, 1, true
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
			st.stepUntil = now + rng:NextNumber(TAC.pause[1], TAC.pause[2])
		else
			st.stepping = true
			st.stepUntil = now + rng:NextNumber(TAC.step[1], TAC.step[2])
			if rng:NextNumber() < 0.6 then
				st.stepSign = -st.stepSign
			end
		end
	end
	if st.stepping then
		local d = probedPick(e, st, { side * st.stepSign, -side * st.stepSign }, now)
		if d then
			return d, 0.8, true
		end
		st.stepping = false
	end
	return nil, 0, true
end

-- Cover pick -------------------------------------------------------------------------------------
local function pickCover(e: any, st: any, t: any, kd: number, now: number): Cover.Cand?
	local lo, hi = kd * 0.55, kd * 1.1
	if st.wounded then
		lo, hi = kd * 0.9, kd * 1.5
	end
	local myD = flat(e.pos - t.pos).Magnitude
	local center = e.pos
	local want: Vector3? = nil
	if st.role == "flanker" then
		local face = flat(t.root.CFrame.LookVector)
		face = if face.Magnitude > 0.1 then face.Unit else flat(e.pos - t.pos).Unit
		-- the flank side the unit already leans towards
		local toMe = flat(e.pos - t.pos)
		local sgn = if face:Cross(toMe).Y >= 0 then 1 else -1
		want = clampMap(t.pos + rot(sgn * rng:NextNumber(60, 100), face) * (kd * 0.8))
		local wv = want :: Vector3
		if flat(wv - e.pos).Magnitude <= MAX_TRAVEL + 15 then
			center = e.pos:Lerp(wv, 0.65)
		end
	end
	local cands = Cover.query(center, t.pos, now)
	local best: Cover.Cand? = nil
	local bestS = math.huge
	for _, c in cands do
		local dT = flat(c.pos - t.pos).Magnitude
		local dE = flat(c.pos - e.pos).Magnitude
		if dT >= 10 and dE <= MAX_TRAVEL + (if want then 20 else 0) and not Cover.taken(c.pos, e) then
			local s = dE + (math.max(0, lo - dT) + math.max(0, dT - hi)) * 2.5
			if st.wounded and dT < myD then
				s += 40
			end
			-- never run past the target to reach a point on its far side
			if (c.pos - t.pos):Dot(e.pos - t.pos) < 0 then
				s += 60
			end
			if want then
				s += flat(c.pos - want).Magnitude * 1.2
			end
			if s < bestS then
				bestS = s
				best = c
			end
		end
	end
	return best
end

-- Ranged -----------------------------------------------------------------------------------------
function Tactician.ranged(e: any, t: any, dist: number, dir: Vector3, now: number): (Vector3?, number, boolean)
	local def = e.def
	if def.static then
		return nil, 0, true
	end
	local st = state(e)
	local kd = def.keepDistance or 30
	if not coverUser(e) then
		return bandHold(e, st, t, dist, dir, kd, now)
	end
	local tac = def.tactics or {}
	if not st.wounded and e.maxHp and e.maxHp > 0 and e.hp / e.maxHp <= (tac.retreatAt or 0.4) then
		st.wounded = true
		dropCover(e, st)
		st.nextFind = 0
	end
	if st.role == nil then
		assignRole(e, st)
	end
	-- target ran far off: drop the cover and follow
	if st.cover and dist > kd * (if st.wounded then 2 else 1.6) then
		dropCover(e, st)
		st.nextFind = now + 1
	end
	if not st.cover and now >= st.nextFind then
		local c = pickCover(e, st, t, kd, now)
		if c then
			st.cover = c
			Cover.claim(e, c.pos)
			st.phase = "move"
			st.untilT = now + (if st.role == "flanker" then FLANK_T else MOVE_T)
			st.nextCheck = now + RECHECK
			st.nextFind = now + FIND_RETRY
		else
			st.nextFind = now + FIND_RETRY
		end
	end
	local cover = st.cover
	if not cover then
		return bandHold(e, st, t, dist, dir, kd, now)
	end

	-- the target moved round the cover: find another
	if st.phase ~= "move" and now >= st.nextCheck then
		st.nextCheck = now + RECHECK
		if not Cover.hidden(cover.pos, t.pos) then
			dropCover(e, st)
			st.nextFind = 0
			return bandHold(e, st, t, dist, dir, kd, now)
		end
	end

	if st.phase == "move" then
		local to = flat(cover.pos - e.pos)
		if to.Magnitude <= REACH then
			st.phase = "hide"
			st.untilT = now + rng:NextNumber(HIDE[1], HIDE[2])
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
		return mv, 1, false
	elseif st.phase == "hide" then
		if now >= st.untilT then
			st.phase = "peek"
			st.peekAt = now
			st.untilT = now + rng:NextNumber(PEEK_T[1], PEEK_T[2])
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

-- Melee ------------------------------------------------------------------------------------------
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
	local fromT = -dir
	-- new target, or the target got round to the other side of this unit's bearing: deal a new one
	if st.bearKey ~= key or not st.bearing or st.bearing:Dot(fromT) < -0.2 then
		local n = (packCount[key] or 0) + 1
		packCount[key] = n
		st.bearKey = key
		st.bearing = rot(MELEE_SIDES[(n % #MELEE_SIDES) + 1] + rng:NextNumber(-15, 15), fromT)
	end
	local w = t.pos + st.bearing * (MELEE_STRAIGHT + 2)
	local to = flat(w - e.pos)
	if to.Magnitude < 4 then
		return nil, nil
	end
	local mv = to.Unit
	local k = math.clamp((dist - MELEE_STRAIGHT) / 20, 0, 1)
	if k > 0 then
		local perp = Vector3.new(-mv.Z, 0, mv.X)
		mv = (mv + perp * (math.sin(now * 2.6 + st.zig) * 0.35 * k)).Unit
	end
	return mv, 1
end

-- Damage -----------------------------------------------------------------------------------------
function Tactician.onDamaged(e: any, _fromPos: Vector3)
	local st = e.tc
	if not st or not e.alive or not coverUser(e) then
		return
	end
	local now = workspace:GetServerTimeNow()
	if st.phase == "open" then
		st.nextFind = 0
	elseif st.phase == "peek" and now - st.peekAt > 0.6 then
		st.phase = "move"
		st.untilT = now + 4
	end
end

function Tactician.init(s: { [string]: any })
	Cover.init(s)
end

return Tactician
