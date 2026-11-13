-- S.Director: decides what spawns, where and when (docs/spec.md §6.3).
--   start(map, faction, difficulty)    initial guard groups + patrol / cleanup loop
--   stop(clearEnemies: boolean?)       halts everything (optionally also S.Enemies.clear())
--   spawnWave(center, budget, opts?)   objective / extraction waves
--        opts = { method: "drop"|"breach"|"ground"?, rMin, rMax, minDist, aggro: boolean?, faction: string? }
--   setPressure(mult)                  scales patrol rate and group budgets (extraction = 1.6)
--   onSpotted(enemy)                   called by EnemyAI after a medium+ unit saw a player for 3 s
-- Budget weights: regular 1, medium 3, heavy 8, behemoth 25. Caps from Config (45 / 2 behemoths / 6 heavies).
-- Map contract: map.patrolPoints, map.insertion (CFrame), map.groundY(x, z).
--
-- INTENSITY (pacing layer, tunables in shared/Data/Intensity.luau):
--   CALM (40-70 s, thin patrols) -> BUILD (14-20 s, warning cues, patrols ramp) -> BREACH (30-45 s, a directional wave every
--   ~6 s from one compass side) -> RELAX (mop-up) -> CALM. Extraction swaps the cycle for a continuous, escalating BREACH
--   hold-out until the shuttle lifts off. The state is replicated as Store key "intensity" (S.State.broadcast).
--   Director.objectiveEvent(name)        objectives force / bring forward a breach (events in Intensity.Events)
--   Director.beginExtractHold() / endExtractHold()   extraction hold-out (Extraction.luau)
--   Director.getIntensity() / debugSetIntensity(state)   DebugHook "intensity" + "state"
--   Heavy / behemoth units that spawn during BUILD / BREACH get an entrance (roar, ground burst or drop pod, shake) and the
--   players within Intensity.Heavy.calloutRange get an Fx "HeavyContact" callout.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local EnemyData = require(Shared.Data.Enemies)
local IT = require(Shared.Data.Intensity)

local Director = {}

local S: { [string]: any } = {}
local rng = Random.new()

local running = false
local gen = 0
local map: any = nil
local factionId = "COG"
local difficulty = 1
local pressure = 1
local startedAt = 0
local nextPatrol = 0
local lastReinforce = -1e9
local pending = { regular = 0, medium = 0, heavy = 0, behemoth = 0 }

-- intensity state machine
local istate = "calm" -- "calm" | "build" | "breach" | "relax"
local iStartedAt = 0
local iEndsAt = 0 -- natural end of the current phase (0 = none: extraction hold)
local iBearing = 0 -- compass bearing (deg, 0 = N, 90 = E) the next / current breach comes from
local iBreachN = 0 -- breaches fired this mission
local iWave = 0 -- waves sent inside the current breach
local nextBreachWave = 0
local calmBrought = 0 -- seconds the current CALM was pulled forward by spotted reinforcements
local breachExtended = 0
local lastBreachEnd = -1e9
local queuedForce: { delay: number }? = nil -- forced event that arrived during RELAX
local pendingForcedBuild: number? = nil -- BUILD length (s) to use when the current CALM ends (forced event)
local timerCritical = false
local lastBearing: number? = nil
local extractHold: { wave: number, nextWave: number, lastBearing: number? }? = nil

local MAP_HALF = Config.MapSize / 2 - 12
local MIN_PLAYER_DIST = 45
local INITIAL_CAP_FRACTION = 0.65

local function now(): number
	return workspace:GetServerTimeNow()
end

local function playerScale(): number
	return math.max(#Players:GetPlayers(), 1)
end

-- long phases shrink / budgets grow with difficulty and party size
local function scale(): number
	return 1 + IT.DiffScale * (difficulty - 1) + IT.PlayerScale * (playerScale() - 1)
end

-- Players ------------------------------------------------------------------------------
local function playerPositions(): { Vector3 }
	local out = {}
	if S.Players and S.Players.getAlive then
		for _, p in S.Players.getAlive() do
			local r = S.Players.getRoot(p)
			if r then
				table.insert(out, r.Position)
			end
		end
	end
	return out
end

local function minDistTo(list: { Vector3 }, p: Vector3): number
	local best = math.huge
	for _, q in list do
		local d = Vector3.new(q.X - p.X, 0, q.Z - p.Z).Magnitude
		if d < best then
			best = d
		end
	end
	return best
end

local function nearestOf(list: { Vector3 }, p: Vector3): Vector3?
	local best: Vector3? = nil
	local bd = math.huge
	for _, q in list do
		local d = (q - p).Magnitude
		if d < bd then
			bd = d
			best = q
		end
	end
	return best
end

-- Ground ---------------------------------------------------------------------------------
local function groundPos(x: number, z: number): Vector3?
	x = math.clamp(x, -MAP_HALF, MAP_HALF)
	z = math.clamp(z, -MAP_HALF, MAP_HALF)
	local y = map and map.groundY and map.groundY(x, z)
	if type(y) ~= "number" or y ~= y or y < -200 then
		return nil
	end
	return Vector3.new(x, y, z)
end

local function pickSpot(center: Vector3, rMin: number, rMax: number, minDist: number, ps: { Vector3 }): Vector3?
	local best: Vector3? = nil
	local bestScore = -math.huge
	for _ = 1, 40 do
		local ang = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(rMin, rMax)
		local g = groundPos(center.X + math.cos(ang) * r, center.Z + math.sin(ang) * r)
		if g then
			local d = if #ps > 0 then minDistTo(ps, g) else math.huge
			if d >= minDist then
				return g
			end
			if d > bestScore then
				bestScore = d
				best = g
			end
		end
	end
	return best
end

local function pickPatrolPoint(ps: { Vector3 }, minD: number, maxD: number): Vector3?
	local pts = map and map.patrolPoints
	if not pts or #pts == 0 then
		return nil
	end
	local ok = {}
	for _, p in pts do
		local d = if #ps > 0 then minDistTo(ps, p) else math.huge
		if d >= minD and d <= maxD then
			table.insert(ok, p)
		end
	end
	if #ok == 0 then
		return nil
	end
	local p = ok[rng:NextInteger(1, #ok)]
	return groundPos(p.X, p.Z)
end

-- Live enemy cap scales with party size and difficulty (1-5), never above Config.MaxEnemies
local function liveCap(): number
	local A = Config.Action
	local base = math.min(A.CapMax, A.CapBase + A.CapPerPlayer * #Players:GetPlayers() + A.CapPerDifficulty * difficulty)
	if istate == "breach" then
		-- a breach may briefly overfill the field so the wave really "pours in"
		local mult = if extractHold then IT.Extract.capMult else IT.BreachWave.capMult
		return math.min(math.floor(base * mult), A.CapMax + IT.BreachWave.capOver)
	end
	return base
end
Director.liveCap = liveCap -- S.Director.liveCap(): EnemyAI caps summons with it

-- Composition ------------------------------------------------------------------------
local function pendingTotal(): number
	return pending.regular + pending.medium + pending.heavy + pending.behemoth
end

-- heavyChance / behemothChance default to 0.5 / 0.4; breach waves pass higher odds
local function compose(budget: number, faction: string, heavyChance: number?, behemothChance: number?): { string }
	local roster = EnemyData.Factions[faction].roster
	local counts = S.Enemies.countByClass()
	local heavySlots = Config.MaxHeavies - counts.heavy - pending.heavy
	local behSlots = Config.MaxBehemoths - counts.behemoth - pending.behemoth
	local room = liveCap() - S.Enemies.count() - pendingTotal()
	local list: { string } = {}
	local b = budget

	if b >= 28 and behSlots > 0 and rng:NextNumber() < (behemothChance or 0.4) then
		table.insert(list, roster.behemoth)
		b -= 25
	end
	local heavies = 0
	while b >= 10 and heavySlots > 0 and heavies < 2 and rng:NextNumber() < (heavyChance or 0.5) do
		table.insert(list, roster.heavy)
		b -= 8
		heavies += 1
		heavySlots -= 1
	end
	local meds = 0
	while b >= 4 and meds < 5 and rng:NextNumber() < 0.65 do
		table.insert(list, roster.medium)
		b -= 3
		meds += 1
	end
	local regs = 0
	while b >= 1 and regs < 16 do
		table.insert(list, roster.regular)
		b -= 1
		regs += 1
	end
	-- trim to the live cap (drops the cheap tail first)
	while #list > math.max(room, 0) do
		table.remove(list)
	end
	return list
end

local function classOf(kindId: string): string
	local d = EnemyData.get(kindId)
	return d and d.class or "regular"
end

-- Spawning -----------------------------------------------------------------------------
-- Group formation. Members stand in a loose wedge (pointing at the nearest player, or a random way) or a ring, 2.5-5 studs
-- apart (wider for big units), each slot snapped to valid ground: not on a cliff step, not on top of another member.
local function slotOffsets(n: number, spacing: number, fwd: Vector3, ring: boolean): { Vector3 }
	local out: { Vector3 } = { Vector3.zero }
	local right = Vector3.new(-fwd.Z, 0, fwd.X)
	if ring then
		local count = n - 1
		if count > 0 then
			local radius = math.max(spacing, spacing / (2 * math.sin(math.pi / math.max(count, 3))))
			local a0 = rng:NextNumber(0, math.pi * 2)
			for i = 1, count do
				local a = a0 + (i - 1) / count * math.pi * 2
				table.insert(out, Vector3.new(math.cos(a), 0, math.sin(a)) * radius)
			end
		end
	else
		-- wedge: row r has r + 1 slots, centred, each row one step behind the leader
		local row = 1
		while #out < n do
			for j = 0, row do
				if #out >= n then
					break
				end
				local lateral = (j - row / 2) * spacing
				out[#out + 1] = right * lateral - fwd * (row * spacing * 0.9)
			end
			row += 1
		end
	end
	return out
end

local function unitPositions(kinds: { string }, base: Vector3): { Vector3 }
	local n = #kinds
	local out: { Vector3 } = {}
	if n == 0 then
		return out
	end
	local maxSize = 0
	for _, k in kinds do
		maxSize = math.max(maxSize, EnemyData.get(k).size)
	end
	local spacing = rng:NextNumber(2.5, 5) + math.max(0, (maxSize - 2.6) * 1.1)
	local fwd = Vector3.new(0, 0, -1)
	local face = nearestOf(playerPositions(), base)
	if face and Vector3.new(face.X - base.X, 0, face.Z - base.Z).Magnitude > 1 then
		fwd = Vector3.new(face.X - base.X, 0, face.Z - base.Z).Unit
	else
		local a = rng:NextNumber(0, math.pi * 2)
		fwd = Vector3.new(math.cos(a), 0, math.sin(a))
	end
	local offsets = slotOffsets(n, spacing, fwd, n >= 5 and rng:NextNumber() < 0.45)
	local baseG = groundPos(base.X, base.Z) or base
	for i = 1, n do
		local off = offsets[i]
		local placed: Vector3? = nil
		-- try the slot with a little jitter; if the ground there is invalid / a cliff / crowded, pull it toward the leader
		for attempt = 0, 4 do
			local pull = 1 - attempt * 0.22
			local jitter = if i == 1 then Vector3.zero else Vector3.new(rng:NextNumber(-0.5, 0.5), 0, rng:NextNumber(-0.5, 0.5))
			local want = baseG + off * pull + jitter
			local g = groundPos(want.X, want.Z)
			if g and math.abs(g.Y - baseG.Y) <= 5 then
				local crowded = false
				for _, q in out do
					if Vector3.new(q.X - g.X, 0, q.Z - g.Z).Magnitude < 2.2 then
						crowded = true
						break
					end
				end
				if not crowded then
					placed = g
					break
				end
			end
		end
		if not placed then
			-- last resort: any free spot on a widening ring around the leader
			for step = 1, 8 do
				local a = rng:NextNumber(0, math.pi * 2)
				local r = spacing * (1 + step * 0.5)
				local g = groundPos(baseG.X + math.cos(a) * r, baseG.Z + math.sin(a) * r)
				if g and math.abs(g.Y - baseG.Y) <= 6 then
					placed = g
					break
				end
			end
		end
		table.insert(out, placed or baseG)
	end
	return out
end

local function spawnUnit(kindId: string, pos: Vector3, opts: any)
	if not S.Enemies then
		return nil
	end
	local ps = playerPositions()
	local face = nearestOf(ps, pos)
	local cf = CFrame.new(pos)
	if face then
		local d = Vector3.new(face.X - pos.X, 0, face.Z - pos.Z)
		if d.Magnitude > 0.1 then
			cf = CFrame.lookAt(pos, pos + d)
		end
	end
	local o: any = {}
	for k, v in opts do
		o[k] = v
	end
	if o.hunt and face then
		o.dest = face
	end
	return S.Enemies.spawn(kindId, cf, o)
end

local function defaultMethod(): string
	return if factionId == "COG" then "drop" else "breach"
end

-- Heavy entrances -------------------------------------------------------------------------
local function isBig(kindId: string): boolean
	local c = classOf(kindId)
	return c == "heavy" or c == "behemoth"
end

-- BUILD / BREACH / extraction hold: heavies make an entrance
local function entranceActive(): boolean
	return istate == "build" or istate == "breach" or extractHold ~= nil
end

-- "HEAVY CONTACT <direction>" to every living player within range (client: client/Fx/IntensityFx.luau)
local function calloutHeavy(kindId: string, pos: Vector3)
	local def = EnemyData.get(kindId)
	if not def or not S.Players or not S.Players.getAlive or not S.Fx then
		return
	end
	for _, p in S.Players.getAlive() do
		local r = S.Players.getRoot(p)
		if r and Vector3.new(r.Position.X - pos.X, 0, r.Position.Z - pos.Z).Magnitude <= IT.Heavy.calloutRange then
			S.Fx.to(p, "HeavyContact", { p = pos, kind = kindId, name = def.name, class = def.class })
		end
	end
end

-- t = 0: the warning (roar + tremor + callout)
local function heavyTelegraph(kindId: string, pos: Vector3)
	local cls = classOf(kindId)
	local f = EnemyData.get(kindId).faction
	local key: string? = nil
	if cls == "behemoth" then
		key = if f == "COG" then "ColossusHorn" else "TitanRoar"
	elseif f ~= "COG" then
		key = "ChargerRoar"
	end
	if key then
		S.Fx.play("Sound", { k = key, p = pos })
	end
	S.Fx.play("Shake", { p = pos, mag = 0.9, r = IT.Heavy.shakeRange })
	calloutHeavy(kindId, pos)
end

-- the moment it appears: ground burst + shockwave + debris + a real shake
local function heavyArrival(kindId: string, pos: Vector3)
	local cls = classOf(kindId)
	local H = IT.Heavy
	S.Fx.play("Shockwave", { p = pos, r = H.shockR[cls] or 18 })
	S.Fx.play("Debris", { p = pos, n = if cls == "behemoth" then 26 else 14, style = "rock" })
	S.Fx.play("Shake", { p = pos, mag = H.shake[cls] or 2, r = H.shakeRange })
end

-- method: "ground" (walk in), "drop" (cargo drone), "breach" (burrow)
local function deliver(kinds: { string }, base: Vector3, method: string, opts: any)
	if #kinds == 0 then
		return
	end
	local myGen = gen
	local spots = unitPositions(kinds, base)
	local spawnOpts = {
		aggro = opts.aggro == true,
		patrol = opts.patrol ~= false,
		hunt = opts.patrol ~= false,
		home = base,
	}
	for _, k in kinds do
		pending[classOf(k)] += 1
	end

	-- heavies / behemoths arriving while the pacing is up get an entrance (and are never just "walked in")
	local bigIdx: { [number]: boolean } = {}
	local anyBig = false
	if entranceActive() then
		for i, k in kinds do
			if isBig(k) then
				bigIdx[i] = true
				anyBig = true
			end
		end
		if anyBig and method == "ground" then
			method = defaultMethod()
		end
	end

	local H = IT.Heavy
	local delayT = 0
	local bigDelay = 0
	if method == "drop" then
		local ang = rng:NextNumber(0, math.pi * 2)
		local from = base + Vector3.new(math.cos(ang) * 260, 130, math.sin(ang) * 260)
		S.Fx.play("DropShip", { a = from, b = base + Vector3.new(0, 0, 0), t = 2.4, hold = 1.4 })
		delayT = 3.2
		bigDelay = if anyBig then H.podFall + 0.15 else delayT -- robots fall from the sky ahead of the carrier
	elseif method == "breach" then
		for i, p in spots do
			if i <= 8 then
				S.Fx.play("Breach", { p = p })
			end
		end
		delayT = 0.7
		bigDelay = if anyBig then delayT + H.extraDelay else delayT
	else
		bigDelay = delayT
	end

	if anyBig then
		for i, k in kinds do
			if bigIdx[i] then
				heavyTelegraph(k, spots[i])
				if method == "drop" then
					S.Fx.play("DropPod", { p = spots[i], t = H.podFall, kind = "hostile" })
				end
			end
		end
	end

	local function spawnSubset(big: boolean)
		for i, k in kinds do
			if (bigIdx[i] == true) == big then
				pending[classOf(k)] = math.max(pending[classOf(k)] - 1, 0)
				-- heavies may exceed the cap by a little: compose() already reserved their slot
				if running and gen == myGen and S.Enemies.count() < liveCap() + (if big then 2 else 0) then
					spawnUnit(k, spots[i], spawnOpts)
					if big then
						heavyArrival(k, spots[i])
					end
				end
			end
		end
	end
	local function run(delay: number, big: boolean)
		if delay <= 0 then
			spawnSubset(big)
		else
			task.delay(delay, spawnSubset, big)
		end
	end
	if not anyBig then
		run(delayT, false)
	else
		run(delayT, false)
		run(bigDelay, true)
	end
end

-- Budget scaling ---------------------------------------------------------------------
local function diffMult(): number
	return 0.85 + 0.15 * difficulty
end

local function patrolBudget(nPlayers: number): number
	local minutes = (now() - startedAt) / 60
	-- bigger patrols than before (was 4 + 2.5n + 0.6/min, capped 4..30): a solo player at difficulty 1 now meets ~10 budget
	-- (a medium + a handful of regulars) per wave and ~16 after ten minutes
	local b = (7 + 3 * nPlayers + minutes * 0.8) * diffMult() * pressure * (IT.PatrolBudget[istate] or 1)
	return math.clamp(b, 5, 36)
end

-- Intensity state machine --------------------------------------------------------------
local function snapshot(): any
	return {
		state = if running then istate else "off",
		t0 = iStartedAt,
		endsAt = iEndsAt,
		dir = iBearing,
		wave = iWave,
		breach = iBreachN,
		extract = extractHold ~= nil,
		faction = factionId,
	}
end

local function broadcastIntensity()
	if S.State and S.State.broadcast then
		S.State.broadcast("intensity", snapshot())
	end
end

local function setPhase(name: string, dur: number)
	local t = now()
	istate = name
	iStartedAt = t
	iEndsAt = if dur > 0 then t + dur else 0
	broadcastIntensity()
end

local function centroid(ps: { Vector3 }): Vector3
	if #ps == 0 then
		return Vector3.zero
	end
	local sum = Vector3.zero
	for _, p in ps do
		sum += p
	end
	return sum / #ps
end

local function randIn(r: { min: number, max: number }): number
	return rng:NextNumber(r.min, r.max)
end

-- ground shake: a chain of decaying global camera shakes
local function rumble(steps: number, mag: number)
	local myGen = gen
	for i = 1, steps do
		if not running or gen ~= myGen then
			return
		end
		S.Fx.play("Shake", { mag = mag * (1 - (i - 1) / steps) })
		task.wait(0.45)
	end
end

-- a compass side with room to spawn on, preferring one that is not the side of the previous breach
local function chooseBearing(ps: { Vector3 }, avoid: number?): number
	local c = centroid(ps)
	local best, bestScore = rng:NextInteger(0, 7) * 45, -math.huge
	local mid = (IT.BreachWave.distMin + IT.BreachWave.distMax) / 2
	for sector = 0, 7 do
		local b = sector * 45
		local p = c + IT.bearingVector(b) * mid
		local room = MAP_HALF - math.max(math.abs(p.X), math.abs(p.Z)) -- < 0: the spot would be clamped onto the map edge
		local score = math.min(room, 40) / 40 * 2 + rng:NextNumber()
		if avoid then
			local diff = math.abs((b - avoid + 180) % 360 - 180)
			if diff < 45 then
				score -= 1.5
			end
		end
		if score > bestScore then
			best, bestScore = b, score
		end
	end
	return (best + rng:NextNumber(-8, 8)) % 360
end

-- a ground spot on the arc `bearing` +- spread, rMin..rMax studs out from `center`, away from the players
local function pickSpotDir(center: Vector3, bearing: number, spread: number, rMin: number, rMax: number, minDist: number, ps: { Vector3 }): Vector3?
	local best: Vector3? = nil
	local bestScore = -math.huge
	for _ = 1, 40 do
		local v = IT.bearingVector(bearing + rng:NextNumber(-spread, spread))
		local r = rng:NextNumber(rMin, rMax)
		local g = groundPos(center.X + v.X * r, center.Z + v.Z * r)
		if g then
			local d = if #ps > 0 then minDistTo(ps, g) else math.huge
			if d >= minDist then
				return g
			end
			if d > bestScore then
				bestScore = d
				best = g
			end
		end
	end
	return best
end

-- one directional wave: everything arrives on the same compass side, split into groups of <= 8 spread along the arc
local function sendBreachWave(budget: number, bearing: number, heavyChance: number, behemothChance: number): number
	local ps = playerPositions()
	if #ps == 0 then
		return 0
	end
	local BW = IT.BreachWave
	local c = centroid(ps)
	local kinds = compose(budget, factionId, heavyChance, behemothChance)
	local method = defaultMethod()
	local total = #kinds
	local i = 1
	while i <= total do
		local group = {}
		for j = i, math.min(i + 7, total) do
			table.insert(group, kinds[j])
		end
		i += 8
		local spot = pickSpotDir(c, bearing, BW.spreadDeg, BW.distMin, BW.distMax, MIN_PLAYER_DIST + 10, ps)
		if spot then
			deliver(group, spot, method, { aggro = true, patrol = true })
		end
	end
	return total
end

local function startCalm(first: boolean?)
	calmBrought = 0
	pendingForcedBuild = nil
	local dur = randIn(IT.Calm) / scale()
	dur = math.max(dur, IT.CalmMinScaled)
	if first then
		dur *= 0.9
	end
	if timerCritical then
		dur = math.max(dur * IT.TimerCriticalCalmMult, 10)
	end
	local q = queuedForce
	if q then
		queuedForce = nil
		dur = 2
		pendingForcedBuild = q.delay
	end
	setPhase("calm", dur)
end

local function startBuild(dur: number?)
	pendingForcedBuild = nil
	iBearing = chooseBearing(playerPositions(), lastBearing)
	setPhase("build", dur or randIn(IT.Build))
	nextPatrol = math.min(nextPatrol, now() + 3) -- the field fills up: patrols ramp immediately
end

local function startBreach()
	iBreachN += 1
	iWave = 0
	breachExtended = 0
	lastBearing = iBearing
	local dur = randIn(IT.Breach) * math.min(1.25, 1 + 0.025 * (difficulty - 1) + 0.02 * (playerScale() - 1))
	setPhase("breach", dur)
	nextBreachWave = now() + 2.5 -- the horn and the ground shake lead the first wave
	task.spawn(rumble, 5, 2.0)
end

local function startRelax()
	lastBreachEnd = now()
	setPhase("relax", randIn(IT.Relax))
end

local function breachTick(t: number)
	if t < nextBreachWave or t >= iEndsAt - 3 then
		return
	end
	iWave += 1
	local BW = IT.BreachWave
	local budget = (BW.baseBudget + BW.perPlayer * playerScale() + BW.perDifficulty * difficulty) * (1 + BW.escalation * (iWave - 1))
	if iWave == 1 then
		budget *= BW.firstWaveMult
	end
	sendBreachWave(budget, iBearing, BW.heavyChance, BW.behemothChance)
	nextBreachWave = t + math.max(BW.intervalMin, BW.interval - 0.25 * (difficulty - 1)) * rng:NextNumber(0.9, 1.1)
	broadcastIntensity()
	task.spawn(rumble, 3, 0.7)
end

-- extraction hold-out: waves never stop, get faster and bigger, and the compass side rotates (flanking)
local function extractTick(t: number)
	local h = extractHold
	if not h or t < h.nextWave then
		return
	end
	local E = IT.Extract
	h.wave += 1
	iWave = h.wave
	if h.wave > 1 and (h.wave - 1) % E.rotateEvery == 0 then
		iBearing = chooseBearing(playerPositions(), iBearing)
	end
	local mult = math.min(E.maxMult, 1 + E.escalation * (h.wave - 1))
	local budget = (E.baseBudget + 3 * playerScale() + 2 * difficulty) * mult
	sendBreachWave(budget, iBearing, E.heavyChance, E.behemothChance)
	h.nextWave = t + math.max(E.intervalMin, E.interval - E.intervalStep * (h.wave - 1))
	broadcastIntensity()
	task.spawn(rumble, 3, 0.9 + 0.1 * math.min(h.wave, 8))
end

function Director.objectiveEvent(name: string)
	if not running then
		return
	end
	local ev = IT.Events[name]
	if not ev or extractHold then
		return
	end
	if istate == "build" or istate == "breach" then
		return -- already incoming
	end
	local t = now()
	if ev.force then
		if istate == "relax" then
			queuedForce = queuedForce or { delay = ev.delay or 6 }
		elseif t - lastBreachEnd < IT.ForceCooldown and not ev.ignoreCooldown then
			iEndsAt = math.max(t + 6, iEndsAt - 20) -- no chained breaches: only speed things up
		else
			startBuild(math.max(ev.delay or 6, 4))
		end
	elseif ev.bring and istate == "calm" then
		iEndsAt = math.max(t + 6, iEndsAt - ev.bring)
	end
end

function Director.beginExtractHold(): boolean
	if not running then
		return false
	end
	if extractHold then
		return true
	end
	extractHold = { wave = 0, nextWave = now() + IT.Extract.firstDelay, lastBearing = nil }
	queuedForce = nil
	pendingForcedBuild = nil
	iBearing = chooseBearing(playerPositions(), lastBearing)
	iBreachN += 1
	iWave = 0
	setPhase("breach", 0) -- no natural end: lasts until the shuttle lifts off
	task.spawn(rumble, 6, 2.2)
	return true
end

function Director.endExtractHold()
	if not extractHold then
		return
	end
	extractHold = nil
	if running then
		startRelax()
	end
end

function Director.getIntensity(): any
	local t = now()
	return {
		state = if running then istate else "off",
		left = if iEndsAt > 0 then math.max(0, math.floor(iEndsAt - t)) else nil,
		dir = IT.compassName(iBearing),
		bearing = math.floor(iBearing),
		wave = iWave,
		breaches = iBreachN,
		extract = extractHold ~= nil,
		timerCritical = timerCritical,
		enemies = if S.Enemies then S.Enemies.count() else 0,
		cap = liveCap(),
	}
end

-- DebugHook "intensity <calm|build|breach|relax>"
function Director.debugSetIntensity(name: string): (boolean, string?)
	if not running then
		return false, "director not running (start a mission and wait for the Active state)"
	end
	extractHold = nil
	queuedForce = nil
	if name == "calm" then
		startCalm()
	elseif name == "build" then
		startBuild()
	elseif name == "breach" then
		iBearing = chooseBearing(playerPositions(), lastBearing)
		startBreach()
	elseif name == "relax" then
		startRelax()
	else
		return false, "unknown intensity " .. tostring(name)
	end
	return true, nil
end

local function intensityTick()
	local t = now()
	local M = S.Mission
	if not timerCritical and M and M.state == "Active" and M.endsAt and M.endsAt > 0 and M.endsAt - t < IT.TimerCriticalSec then
		timerCritical = true
		Director.objectiveEvent("TIME_CRITICAL")
	end
	if extractHold then
		extractTick(t)
		return
	end
	if istate == "calm" then
		if t >= iEndsAt then
			startBuild(pendingForcedBuild and math.max(pendingForcedBuild, 4) or nil)
		end
	elseif istate == "build" then
		if t >= iEndsAt then
			startBreach()
		end
	elseif istate == "breach" then
		breachTick(t)
		if t >= iEndsAt then
			startRelax()
		end
	elseif istate == "relax" then
		local R = IT.Relax
		if t >= iEndsAt or (t - iStartedAt >= R.min and S.Enemies.count() < liveCap() * R.clearFraction) then
			startCalm()
		end
	end
end

-- Behaviours -------------------------------------------------------------------------
local function patrol()
	local ps = playerPositions()
	if #ps == 0 then
		return
	end
	if S.Enemies.count() >= liveCap() - 6 then
		return
	end
	local anchor = ps[rng:NextInteger(1, #ps)]
	local spot: Vector3? = nil
	if rng:NextNumber() < 0.5 then
		spot = pickPatrolPoint(ps, 55, 125) -- closer than before (60-150) so contact comes sooner
	end
	if not spot then
		spot = pickSpot(anchor, 60, 105, MIN_PLAYER_DIST + 8, ps) -- was 75-125
	end
	if not spot then
		return
	end
	local kinds = compose(patrolBudget(#ps), factionId)
	deliver(kinds, spot, "ground", { aggro = false, patrol = true })
end

function Director.onSpotted(e: any)
	if not running or not e or not e.alive then
		return
	end
	local t = now()
	if t - lastReinforce < Config.Action.ReinforceCooldown then
		return
	end
	if S.Enemies.count() >= liveCap() - 6 then
		return
	end
	local ps = playerPositions()
	if #ps == 0 then
		return
	end
	lastReinforce = t
	-- a spotted call counts toward intensity: it pulls the next breach closer (CALM) or keeps a running one going a little longer
	if not extractHold then
		if istate == "calm" then
			local room = IT.SpottedBringMax - calmBrought
			if room > 0 then
				local b = math.min(IT.SpottedBring, room)
				calmBrought += b
				iEndsAt = math.max(t + 5, iEndsAt - b)
			end
		elseif istate == "breach" and breachExtended < 10 then
			breachExtended += IT.SpottedBreachExtend
			iEndsAt += IT.SpottedBreachExtend
		end
	end
	local tp = nearestOf(ps, e.root.Position) or ps[1]
	local spot = pickSpot(tp, 55, 90, MIN_PLAYER_DIST, ps)
	if not spot then
		return
	end
	local budget = (6 + 2.5 * #ps + difficulty * 1.5) * pressure
	local kinds = compose(math.min(budget, 26), factionId)
	if S.State and S.State.notify then
		local f = EnemyData.Factions[factionId]
		S.State.notify(nil, if factionId == "COG" then "Enemy reinforcements inbound!" else "The Brood is breaching!", f.color, "warning")
	end
	deliver(kinds, spot, defaultMethod(), { aggro = true, patrol = true })
end

function Director.spawnWave(center: Vector3, budget: number, opts: any?)
	local o = opts or {}
	-- after Director.stop (Results/Failed phase) objective/extraction waves must not fire dropship fx for nothing
	if not map or not running then
		return 0
	end
	local faction = o.faction or factionId
	local ps = playerPositions()
	local kinds = compose(budget * diffMult() * (if o.ignorePressure then 1 else pressure), faction)
	local method = o.method or defaultMethod()
	local total = #kinds
	-- split into groups of <= 8 so big waves arrive from several directions
	local i = 1
	while i <= total do
		local group = {}
		for j = i, math.min(i + 7, total) do
			table.insert(group, kinds[j])
		end
		i += 8
		local spot = pickSpot(center, o.rMin or 55, o.rMax or 95, o.minDist or MIN_PLAYER_DIST, ps)
		if spot then
			deliver(group, spot, method, { aggro = o.aggro ~= false, patrol = true })
		end
	end
	return total
end

function Director.setPressure(mult: number)
	pressure = math.max(mult or 1, 0.1)
end

local function cleanup()
	local ps = playerPositions()
	if #ps == 0 then
		return
	end
	local t = now()
	for _, e in S.Enemies.getAll() do
		if e.patrol and not e.target and t - (e.spawnedAt or t) > 45 and e.class ~= "behemoth" then
			if minDistTo(ps, e.root.Position) > 190 then
				S.Enemies.despawn(e)
			end
		end
	end
end

local function loop(myGen: number)
	local nextCleanup = now() + 5
	while running and gen == myGen do
		local t = now()
		if t >= nextPatrol then
			local A = Config.Action
			local interval = A.PatrolInterval / pressure / (IT.PatrolRate[istate] or 1)
			-- field nearly empty (the squad just wiped a group): the next one arrives much sooner, no standing around.
			-- Only while the pacing is up (BUILD / BREACH): CALM and RELAX are meant to be quiet.
			if (istate == "build" or istate == "breach") and S.Enemies.count() < liveCap() * A.EmptyFraction then
				interval *= A.PatrolIntervalBusy
			end
			nextPatrol = t + interval * rng:NextNumber(0.85, 1.15)
			local ok, err = pcall(patrol)
			if not ok then
				warn("[Director] patrol failed:", err)
			end
		end
		local okI, errI = pcall(intensityTick)
		if not okI then
			warn("[Director] intensity tick failed:", errI)
		end
		if t >= nextCleanup then
			nextCleanup = t + 5
			local ok, err = pcall(cleanup)
			if not ok then
				warn("[Director] cleanup failed:", err)
			end
		end
		task.wait(1)
	end
end

function Director.start(m: any, faction: string, diff: number)
	Director.stop()
	map = m
	factionId = if EnemyData.Factions[faction] then faction else "COG"
	difficulty = math.clamp(math.floor(diff or 1), 1, #Config.DifficultyHpScale)
	pressure = 1
	startedAt = now()
	nextPatrol = startedAt + Config.Action.PatrolInterval * 0.6
	lastReinforce = startedAt - Config.Action.ReinforceCooldown * 0.5
	for k in pending do
		pending[k] = 0
	end
	running = true
	gen += 1
	local myGen = gen
	S.Enemies.setDifficulty(difficulty)

	-- intensity: every mission opens with a CALM stretch
	iBreachN, iWave, breachExtended = 0, 0, 0
	lastBreachEnd = -1e9
	lastBearing = nil
	extractHold = nil
	queuedForce = nil
	timerCritical = false
	startCalm(true)

	-- initial guard groups around the patrol points, away from the insertion zone
	task.spawn(function()
		local ins = m and m.insertion and m.insertion.Position or Vector3.zero
		local points: { Vector3 } = {}
		for _, p in (m and m.patrolPoints) or {} do
			if Vector3.new(p.X - ins.X, 0, p.Z - ins.Z).Magnitude >= 100 then
				table.insert(points, p)
			end
		end
		-- shuffle
		for i = #points, 2, -1 do
			local j = rng:NextInteger(1, i)
			points[i], points[j] = points[j], points[i]
		end
		if #points == 0 then
			for _ = 1, 8 do
				local ang = rng:NextNumber(0, math.pi * 2)
				local r = rng:NextNumber(120, MAP_HALF)
				table.insert(points, ins + Vector3.new(math.cos(ang) * r, 0, math.sin(ang) * r))
			end
		end
		local groups = math.min(#points, 4 + difficulty)
		local perGroup = 6 + difficulty * 2
		local softCap = math.floor(liveCap() * INITIAL_CAP_FRACTION)
		for i = 1, groups do
			if not running or gen ~= myGen then
				return
			end
			if S.Enemies.count() >= softCap then
				break
			end
			local g = groundPos(points[i].X, points[i].Z)
			if g then
				local kinds = compose(perGroup, factionId)
				-- keep initial heavies rare: one behemoth at most is handled by compose()
				deliver(kinds, g, "ground", { aggro = false, patrol = false })
			end
			task.wait(0.05)
		end
	end)

	task.spawn(loop, myGen)
end

function Director.stop(clearEnemies: boolean?)
	local wasRunning = running
	running = false
	gen += 1
	for k in pending do
		pending[k] = 0
	end
	istate = "calm"
	extractHold = nil
	queuedForce = nil
	if wasRunning then
		broadcastIntensity() -- state "off": clients drop the strip / music swell
	end
	if clearEnemies and S.Enemies then
		S.Enemies.clear()
	end
end

function Director.init(s: { [string]: any })
	S = s
end

return Director
