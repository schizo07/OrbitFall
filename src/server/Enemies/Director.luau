-- S.Director: decides what spawns, where and when (docs/spec.md §6.3).
--   start(map, faction, difficulty)    initial guard groups + patrol / cleanup loop
--   stop(clearEnemies: boolean?)       halts everything (optionally also S.Enemies.clear())
--   spawnWave(center, budget, opts?)   objective / extraction waves
--        opts = { method: "drop"|"breach"|"ground"?, rMin, rMax, minDist, aggro: boolean?, faction: string? }
--   setPressure(mult)                  scales patrol rate and group budgets (extraction = 1.6)
--   onSpotted(enemy) -> boolean        called by EnemyAI after a medium+ unit saw a player for 3 s (true = a reinforce call started)
-- Budget weights: regular 1, medium 3, heavy 8, behemoth 25 (compose) -- the LIVE CAP is counted in load: fodder 0.5, others 1.
-- Map contract: map.patrolPoints, map.insertion (CFrame), map.groundY(x, z).
--
-- DIRECTOR v2 (docs/intensity-spec.md section 2; tunables in shared/Data/Intensity.luau + Config.Action):
--   CALM (20-35 s)  patrols of 5-8 every 14 s spawn 90-120 studs out and walk ACROSS the squad's path (they ignore the squad for the
--                   first seconds), nothing else
--   BUILD (8-10 s)  warning cues, one more patrol
--   BREACH (30-45 s) 2-3 BREACH SOURCES open 35-55 studs from the squad centroid in a 90 degree arc (BROOD hole / COG drop pod / LUMEN
--                   rift shard, server/Enemies/BreachSources.luau). Each emits 4-6 fodder every 2.5 s plus one elite every 10 s in
--                   bursts of 12 s on / 4 s off; a heavy shows up at T+15 s on difficulty >= 4. Explosions damage the sources; when
--                   every source is closed the breach ends early (-> RELAX). A proximity pass keeps >= 60 % of the field within 70
--                   studs of a player (stragglers beyond 140 studs are recycled next to a source).
--   RELAX (10 s)    sources collapse, stragglers beyond 6-10 survivors are removed, nothing new spawns
--   Extraction hold-out: a continuous BREACH until the shuttle lifts off; breach sources re-open every 20 s 30-45 studs out, the old
--                   directional waves keep rolling (closer, 62-90 studs), the live cap never drops under 48.
--   Spotted -> reinforce: 45 s cooldown, the caller burns a flare for 3 s first; killing / stunning it cancels the call. No call
--                   starts during BUILD / BREACH / extraction hold-out or within 30 s after a breach ended (a flare still burning when a
--                   breach starts is cancelled); units delivered by a call may chain at most 1 further call per breach cycle.
--   After a player goes down nothing new spawns for 4 s (Config.Action.DownLull).
--   Objective interaction (Intensity.Events force = true) leads to a BUILD within 10 s.
--
--   Replicated state: Store "intensity" (S.State.broadcast) = {state, t0, endsAt, dir, wave, breach, extract, faction,
--     sources = { {id, f = faction, p = Vector3, hp, max, ready} }, ev = { k = "open" | "close", id, f, p, why, n = seq } }
--     (ev is the LAST source event, n counts up: a client reacts when n changes; live HP is the "Hp" attribute of the source model,
--     CollectionService tag "BreachSource").
--   Director.objectiveEvent(name)        objectives force / bring forward a breach (events in Intensity.Events)
--   Director.beginExtractHold() / endExtractHold()   extraction hold-out (Extraction.luau)
--   Director.getIntensity() / debugSetIntensity(state) / debugBreach() / getSources(ref) / debugCloseSources()   DebugHook "intensity",
--     "breach", "sources", "state"
--   Director.onExplosion(pos, radius, core, dmg, source)   called by EnemyService.explode: damages breach sources
--   Director.meleeSlots()                max melee attackers per player (EnemyAI)
--   Heavy / behemoth units that spawn during BUILD / BREACH get an entrance (roar, ground burst or drop pod, shake) and the
--   players within Intensity.Heavy.calloutRange get an Fx "HeavyContact" callout.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local EnemyData = require(Shared.Data.Enemies)
local IT = require(Shared.Data.Intensity)
local BreachSources = require(script.Parent.BreachSources)
local AirDefence = require(script.Parent.Parent.AirDefence)

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
local lastAANotify = -1e9
local chainCalls = 0 -- spotted calls made by units that were themselves delivered by a call, since the last breach started
local pending = { regular = 0, medium = 0, heavy = 0, behemoth = 0, fodder = 0 }

-- intensity state machine
local istate = "calm" -- "calm" | "build" | "breach" | "relax"
local iStartedAt = 0
local iEndsAt = 0 -- natural end of the current phase (0 = none: extraction hold)
local iBearing = 0 -- compass bearing (deg, 0 = N, 90 = E) the next / current breach comes from
local iBreachN = 0 -- breaches fired this mission
local iWave = 0 -- source bursts (or legacy waves) sent inside the current breach
local nextBreachWave = 0
local calmBrought = 0 -- seconds the current CALM was pulled forward by spotted reinforcements
local breachExtended = 0
local lastBreachEnd = -1e9
local queuedForce: { delay: number }? = nil -- forced event that arrived during RELAX
local pendingForcedBuild: number? = nil -- BUILD length (s) to use when the current CALM ends (forced event)
local timerCritical = false
local lastBearing: number? = nil
local extractHold: { wave: number, nextWave: number, nextSources: number, opened: boolean, lastBearing: number? }? = nil

-- Director v2 state
local legacyWaves = false -- no breach source could be placed: the old directional waves carry the breach
local sourcesToOpen = 0 -- sources scheduled to open (staggered) but not open yet
local heavyFired = false
local breachStartedAt = 0
local lullUntil = 0 -- no new spawns until then (a player just went down)
local aliveSet: { [Player]: boolean } = {}
local pendingCall: { e: any, fireAt: number, prev: number, flare: Instance? }? = nil
local srcEvSeq = 0
local srcLastEv: any = nil
local squadVel = Vector3.zero
local lastCentroid: Vector3? = nil
local lastCentroidT = 0
local nextSquad = 0
local nextProximity = 0

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

-- Live enemy cap scales with party size and difficulty (1-5), never above Config.MaxEnemies. It is counted in LOAD (fodder = 0.5).
local function liveCap(): number
	local A = Config.Action
	local base = math.min(A.CapMax, A.CapBase + A.CapPerPlayer * #Players:GetPlayers() + A.CapPerDifficulty * difficulty)
	if istate == "breach" then
		-- a breach may briefly overfill the field so the wave really "pours in"
		local mult = if extractHold then IT.Extract.capMult else IT.BreachWave.capMult
		local cap = math.min(math.floor(base * mult), A.CapMax + IT.BreachWave.capOver)
		if extractHold then
			cap = math.max(cap, IT.Extract.capFloor)
		end
		return cap
	end
	return base
end
Director.liveCap = liveCap -- S.Director.liveCap(): EnemyAI caps summons with it

local function loadNow(): number
	return S.Enemies.load()
end

-- Composition ------------------------------------------------------------------------
local function pendingLoad(): number
	return pending.regular + pending.medium + pending.heavy + pending.behemoth + pending.fodder * Config.Action.FodderCost
end

local function pendKey(kindId: string): string
	local d = EnemyData.get(kindId)
	if d and d.fodder then
		return "fodder"
	end
	return d and d.class or "regular"
end

-- heavyChance / behemothChance default to 0.5 / 0.4; breach waves pass higher odds
local function compose(budget: number, faction: string, heavyChance: number?, behemothChance: number?): { string }
	local roster = EnemyData.Factions[faction].roster
	local counts = S.Enemies.countByClass()
	local heavySlots = Config.MaxHeavies - counts.heavy - pending.heavy
	local behSlots = Config.MaxBehemoths - counts.behemoth - pending.behemoth
	local room = math.floor(liveCap() - loadNow() - pendingLoad())
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
-- opts: aggro, patrol, dest (walk target, then they idle), crossFor (seconds they ignore the squad while walking to dest)
local function deliver(kinds: { string }, base: Vector3, method: string, opts: any)
	if #kinds == 0 then
		return
	end
	local myGen = gen
	local spots = unitPositions(kinds, base)
	local spawnOpts = {
		aggro = opts.aggro == true,
		patrol = opts.patrol ~= false,
		hunt = opts.patrol ~= false and opts.dest == nil,
		home = base,
		dest = opts.dest,
		crossFor = opts.crossFor,
		reinforced = opts.reinforced == true, -- delivered by a spotted call: such a unit may only chain one further call per breach
	}
	for _, k in kinds do
		pending[pendKey(k)] += 1
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
	local shotDown = false -- an AA battery (server/AirDefence.luau) downed the carrier: its squad never lands
	if method == "drop" then
		local ang = rng:NextNumber(0, math.pi * 2)
		local from = base + Vector3.new(math.cos(ang) * 260, 130, math.sin(ang) * 260)
		local aa = AirDefence.intercept(base)
		shotDown = aa ~= nil
		S.Fx.play("DropShip", { a = from, b = base + Vector3.new(0, 0, 0), t = 2.4, hold = 1.4, kill = if aa then 1.9 else nil, aa = aa })
		if aa and S.State and S.State.notify and os.clock() - lastAANotify > 20 then
			lastAANotify = os.clock()
			task.delay(1.9, S.State.notify, nil, "AA battery: enemy dropship shot down!", Config.Colors.Friendly)
		end
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
				local key = pendKey(k)
				pending[key] = math.max(pending[key] - 1, 0)
				-- heavies may exceed the cap by a little: compose() already reserved their slot
				if running and gen == myGen and not (shotDown and not big) and loadNow() < liveCap() + (if big then 2 else 0) then
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
		sources = BreachSources.publicList(),
		ev = srcLastEv,
	}
end

local function broadcastIntensity()
	if S.State and S.State.broadcast then
		S.State.broadcast("intensity", snapshot())
	end
end

-- source open / close events travel in the intensity snapshot (client VFX hooks: ev.n changes)
local function pushSourceEvent(kind: string, src: any, why: string?)
	srcEvSeq += 1
	srcLastEv = { k = kind, id = src.id, f = src.faction, p = src.pos, why = why, n = srcEvSeq }
	broadcastIntensity()
end

local function closeAllSources(why: string)
	for _, src in BreachSources.all() do
		BreachSources.close(src, why)
	end
end

local function setPhase(name: string, dur: number)
	local t = now()
	if name ~= "breach" then
		sourcesToOpen = 0
		closeAllSources("expired") -- leaving the breach: whatever is still open collapses
	end
	istate = name
	iStartedAt = t
	iEndsAt = if dur > 0 then t + dur else 0
	broadcastIntensity()
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
	local mid = (IT.Sources.distMin + IT.Sources.distMax) / 2
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

-- one directional wave (LEGACY / extraction): everything arrives on the same compass side, split into groups of <= 8 along the arc
local function sendBreachWave(budget: number, bearing: number, heavyChance: number, behemothChance: number, dMin: number?, dMax: number?): number
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
		local spot = pickSpotDir(c, bearing, BW.spreadDeg, dMin or BW.distMin, dMax or BW.distMax, MIN_PLAYER_DIST + 10, ps)
		if spot then
			deliver(group, spot, method, { aggro = true, patrol = true })
		end
	end
	return total
end

-- Breach sources -----------------------------------------------------------------------
-- opens up to `n` sources in the arc around iBearing, dMin..dMax studs from the squad (staggered); returns how many were placed
local function openSources(n: number, dMin: number, dMax: number): number
	local ps = playerPositions()
	if #ps == 0 or n <= 0 then
		return 0
	end
	local SC = IT.Sources
	local spots = BreachSources.pickSpots(centroid(ps), iBearing, SC.arcDeg, dMin, dMax, n, ps)
	local hpScale = (1 + SC.hpPerDifficulty * (difficulty - 1)) * (1 + SC.hpPerPlayer * (playerScale() - 1))
	local myGen = gen
	sourcesToOpen += #spots
	for i, spot in spots do
		local function openOne()
			sourcesToOpen = math.max(sourcesToOpen - 1, 0)
			if running and gen == myGen and istate == "breach" then
				BreachSources.open(factionId, spot, hpScale)
			end
		end
		local delay = (i - 1) * SC.openStagger
		if delay <= 0 then
			openOne()
		else
			task.delay(delay, openOne)
		end
	end
	return #spots
end

local function armedSources(): { any }
	local out = {}
	for _, src in BreachSources.all() do
		if BreachSources.isReady(src) then
			table.insert(out, src)
		end
	end
	return out
end

local function ringSpot(src: any, rMin: number, rMax: number): Vector3
	local a = rng:NextNumber(0, math.pi * 2)
	local r = rng:NextNumber(rMin, rMax)
	local g = groundPos(src.pos.X + math.cos(a) * r, src.pos.Z + math.sin(a) * r)
	if g and math.abs(g.Y - src.pos.Y) <= 6 then
		return g
	end
	return src.pos
end

local function inLull(t: number): boolean
	return t < lullUntil
end

-- a batch of fodder around the source, spread over ~0.3 s so the spawn cost does not land in one frame
local function emitFodder(src: any, n: number): number
	local room = math.floor((liveCap() - loadNow() - pendingLoad()) / Config.Action.FodderCost)
	-- small squads get thinner bursts (solo 60 %, a full squad 100 %)
	local pmult = math.min(1, IT.Sources.fodderSoloMult + IT.Sources.fodderPerPlayerMult * (playerScale() - 1))
	n = math.min(math.max(1, math.floor(n * pmult + 0.5)), room)
	if n <= 0 then
		return 0
	end
	local kind = EnemyData.Factions[src.faction].roster.fodder
	local ring = IT.Sources.spawnRing
	local myGen = gen
	pending.fodder += n
	for i = 1, n do
		task.delay((i - 1) * 0.06, function()
			pending.fodder = math.max(pending.fodder - 1, 0)
			if running and gen == myGen and not src.closed and loadNow() < liveCap() then
				spawnUnit(kind, ringSpot(src, ring.min, ring.max), { aggro = true, patrol = true, hunt = true, home = src.pos })
			end
		end)
	end
	return n
end

local function emitElite(src: any)
	if liveCap() - loadNow() - pendingLoad() < 1 then
		return
	end
	local kind = EnemyData.Factions[src.faction].roster.medium
	spawnUnit(kind, ringSpot(src, 3, 6), { aggro = true, patrol = true, hunt = true, home = src.pos })
end

-- the breach's heavy: telegraphed at a source, arrives like any other entrance
local function fireSourceHeavy(): boolean
	local srcs = armedSources()
	if #srcs == 0 then
		return false
	end
	local counts = S.Enemies.countByClass()
	if Config.MaxHeavies - counts.heavy - pending.heavy <= 0 then
		return true -- no heavy slot free: this breach goes without
	end
	local src = srcs[rng:NextInteger(1, #srcs)]
	local kind = EnemyData.Factions[src.faction].roster.heavy
	local pos = ringSpot(src, 3, 5)
	heavyTelegraph(kind, pos)
	pending.heavy += 1
	local myGen = gen
	task.delay(IT.Heavy.extraDelay, function()
		pending.heavy = math.max(pending.heavy - 1, 0)
		if running and gen == myGen then
			spawnUnit(kind, pos, { aggro = true, patrol = true, hunt = true, home = src.pos })
			heavyArrival(kind, pos)
		end
	end)
	return true
end

-- burst cycle of one source: 12 s on / 4 s off; fodder every 2.5 s while on, one elite every 10 s
local function sourceTick(src: any, t: number)
	if not BreachSources.isReady(src) then
		return
	end
	local SC = IT.Sources
	local em = src.emit
	if not em.init then
		em.init = true
		em.on = false
		em.phaseEnds = t + rng:NextNumber(0, 2.5) -- sources do not start in lockstep
		em.nextFodder = 0
		em.nextElite = t + rng:NextNumber(3, 5)
	end
	if t >= em.phaseEnds then
		if em.on then
			em.on = false
			em.phaseEnds = t + SC.burstOff
		else
			em.on = true
			em.phaseEnds = t + SC.burstOn
			em.nextFodder = t + 0.2
			iWave += 1 -- a new burst: the client pings / rumbles on a wave change
			broadcastIntensity()
			if em.bursts then -- the opening burst already had its eruption fx
				if src.faction == "BROOD" then
					S.Fx.play("Breach", { p = src.pos })
				elseif src.faction == "COG" then
					S.Fx.play("Debris", { p = src.pos, n = 6, style = "scrap" })
				else
					S.Fx.play("Explosion", { p = src.pos + Vector3.new(0, 3, 0), r = 6, size = "S", style = "emp" })
				end
			end
			em.bursts = (em.bursts or 0) + 1
		end
	end
	if not em.on then
		return
	end
	if inLull(t) then
		em.nextFodder = math.max(em.nextFodder, lullUntil)
		em.nextElite = math.max(em.nextElite, lullUntil)
		return
	end
	if t >= em.nextFodder then
		em.nextFodder = t + SC.fodderEvery * rng:NextNumber(0.9, 1.1)
		emitFodder(src, rng:NextInteger(SC.fodderCount.min, SC.fodderCount.max))
	end
	if t >= em.nextElite then
		em.nextElite = t + SC.eliteEvery
		emitElite(src)
	end
end

-- an explosion hit the field: close breach sources (EnemyService.explode -> here)
function Director.onExplosion(pos: Vector3, radius: number, core: number, dmg: number, source: any?)
	if running then
		BreachSources.onExplosion(pos, radius, core, dmg, source)
	end
end

-- Phases ---------------------------------------------------------------------------------
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
		dur = 1
		pendingForcedBuild = q.delay
	end
	setPhase("calm", dur)
	nextPatrol = now() + (if first then IT.Patrol.firstDelay else rng:NextNumber(6, 10))
end

local function startBuild(dur: number?)
	pendingForcedBuild = nil
	iBearing = chooseBearing(playerPositions(), lastBearing)
	setPhase("build", dur or randIn(IT.Build))
	nextPatrol = math.min(nextPatrol, now() + 2) -- the field fills up: one more patrol right away
end

-- how many sources: 2, or 3 (likelier with difficulty / party size)
local function sourceCount(): number
	local SC = IT.Sources
	local p3 = SC.threeBase + SC.threePerDifficulty * (difficulty - 1) + SC.threePerPlayer * (playerScale() - 1)
	return if rng:NextNumber() < p3 then SC.count.max else SC.count.min
end

local function startBreach()
	local t = now()
	iBreachN += 1
	iWave = 0
	breachExtended = 0
	chainCalls = 0
	lastBearing = iBearing
	breachStartedAt = t
	heavyFired = false
	legacyWaves = false
	local dur = randIn(IT.Breach) * math.min(1.25, 1 + 0.025 * (difficulty - 1) + 0.02 * (playerScale() - 1))
	closeAllSources("expired")
	sourcesToOpen = 0
	setPhase("breach", dur)
	local SC = IT.Sources
	if openSources(sourceCount(), SC.distMin, SC.distMax) == 0 and #playerPositions() > 0 then
		-- nowhere to put a source (tiny / cluttered spot): the old directional waves carry this breach
		legacyWaves = true
		nextBreachWave = t + 2.5
	end
	task.spawn(rumble, 5, 2.0)
end

-- RELAX: sources collapse (setPhase), then every unit beyond the straggler count (farthest first, never one the squad can see
-- close by) is removed quietly
local function trimStragglers()
	local ps = playerPositions()
	if #ps == 0 then
		return
	end
	local R = IT.Relax
	local keep = rng:NextInteger(R.stragglersMin, R.stragglersMax)
	local all = S.Enemies.getAll()
	local excess = #all - keep
	if excess <= 0 then
		return
	end
	local rows = {}
	for _, e in all do
		if (e.class == "regular" or e.class == "medium") and not e.def.loot then -- fodder counts as regular; loot runners keep their own timer
			table.insert(rows, { e = e, d = minDistTo(ps, e.pos or e.root.Position) })
		end
	end
	table.sort(rows, function(a, b)
		return a.d > b.d
	end)
	-- pass 1: anything far away; pass 2: the swarm scatters (fodder past the melee ring) so the squad really gets a breather
	local gone = {}
	for pass = 1, 2 do
		for _, r in rows do
			if excess <= 0 then
				return
			end
			if not gone[r] and (r.d > 55 or (pass == 2 and r.d > (if r.e.fodder then R.fodderScatterDist else R.regularScatterDist))) then
				gone[r] = true
				S.Enemies.despawn(r.e)
				excess -= 1
			end
		end
	end
end

local nextTrim = 0
local function startRelax()
	lastBreachEnd = now()
	setPhase("relax", randIn(IT.Relax))
	trimStragglers()
	nextTrim = now() + IT.Relax.trimEvery
end

-- legacy directional waves (only when no source could be placed)
local function legacyWaveTick(t: number)
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

local function breachTick(t: number)
	if extractHold then
		return
	end
	if legacyWaves then
		if not inLull(t) then
			legacyWaveTick(t)
		else
			nextBreachWave = math.max(nextBreachWave, lullUntil)
		end
		return
	end
	if t >= iEndsAt - 3 then
		return -- the last seconds: no new emission, the squad finishes what is on the field
	end
	for _, src in BreachSources.all() do
		sourceTick(src, t)
	end
	if not heavyFired and difficulty >= IT.Sources.heavyMinDifficulty and t - breachStartedAt >= IT.Sources.heavyAt and not inLull(t) then
		heavyFired = fireSourceHeavy()
	end
end

-- extraction hold-out: sources re-open every 20 s and keep emitting; the directional waves never stop, get faster / bigger and the
-- compass side rotates (flanking)
local function extractTick(t: number)
	local h = extractHold
	if not h then
		return
	end
	local E = IT.Extract
	if t >= h.nextSources then
		h.nextSources = t + E.sourceEvery
		if not inLull(t) then
			local want = if h.opened then math.min(2, E.maxSources - BreachSources.count() - sourcesToOpen) else E.firstSources
			h.opened = true
			if want > 0 then
				openSources(want, E.sourceDistMin, E.sourceDistMax)
			end
		end
	end
	for _, src in BreachSources.all() do
		sourceTick(src, t)
	end
	if t < h.nextWave then
		return
	end
	if inLull(t) then
		h.nextWave = math.max(h.nextWave, lullUntil)
		return
	end
	h.wave += 1
	iWave = math.max(iWave, h.wave)
	if h.wave > 1 and (h.wave - 1) % E.rotateEvery == 0 then
		iBearing = chooseBearing(playerPositions(), iBearing)
	end
	local mult = math.min(E.maxMult, 1 + E.escalation * (h.wave - 1))
	local budget = (E.baseBudget + 3 * playerScale() + 2 * difficulty) * mult
	sendBreachWave(budget, iBearing, E.heavyChance, E.behemothChance, E.distMin, E.distMax)
	h.nextWave = t + math.max(E.intervalMin, E.interval - E.intervalStep * (h.wave - 1))
	broadcastIntensity()
	task.spawn(rumble, 3, 0.9 + 0.1 * math.min(h.wave, 8))
end

-- Objective interaction: always leads to a BUILD within IT.ForceWithin seconds
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
		local buildLen = math.clamp(ev.delay or IT.Build.min, IT.Build.min, IT.Build.max)
		if istate == "relax" then
			queuedForce = queuedForce or { delay = buildLen }
			iEndsAt = math.min(iEndsAt, t + 5) -- RELAX hands over, CALM lasts a second, then the forced BUILD
		elseif t - lastBreachEnd < IT.ForceCooldown and not ev.ignoreCooldown then
			iEndsAt = math.min(iEndsAt, t + IT.ForceWithin) -- no chained breaches: the BUILD comes within ForceWithin seconds
		else
			startBuild(buildLen)
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
	local t = now()
	extractHold = { wave = 0, nextWave = t + IT.Extract.firstDelay, nextSources = t + IT.Extract.firstDelay + 1.5, opened = false, lastBearing = nil }
	queuedForce = nil
	pendingForcedBuild = nil
	iBearing = chooseBearing(playerPositions(), lastBearing)
	iBreachN += 1
	iWave = 0
	legacyWaves = false
	sourcesToOpen = 0
	closeAllSources("expired")
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

local function nearFraction(): number
	local ps = playerPositions()
	local all = if S.Enemies then S.Enemies.getAll() else {}
	if #all == 0 or #ps == 0 then
		return 1
	end
	local near = 0
	local r = Config.Action.NearRadius
	for _, e in all do
		if minDistTo(ps, e.pos or e.root.Position) <= r then
			near += 1
		end
	end
	return near / #all
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
		load = if S.Enemies then S.Enemies.load() else 0,
		cap = liveCap(),
		sources = BreachSources.count(),
		legacyWaves = legacyWaves,
		lull = math.max(0, math.floor((lullUntil - t) * 10) / 10),
		near = math.floor(nearFraction() * 100) / 100,
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

-- DebugHook "breach": force a BREACH right now (sources open at once)
function Director.debugBreach(): (boolean, string?)
	return Director.debugSetIntensity("breach")
end

-- DebugHook "sources": open sources with hp / distance (flat) from `ref` (default: the squad centroid)
function Director.getSources(ref: Vector3?): { any }
	local from = ref or centroid(playerPositions())
	local out = {}
	for _, src in BreachSources.all() do
		table.insert(out, BreachSources.describe(src, from))
	end
	return out
end

-- DebugHook "sources close": close every open source as if the squad had blown them up
function Director.debugCloseSources(): number
	local n = 0
	for _, src in BreachSources.all() do
		BreachSources.close(src, "destroyed")
		n += 1
	end
	return n
end

function Director.meleeSlots(): number
	local A = Config.Action
	return math.clamp(A.MeleeSlotsBase + math.floor(difficulty / 2), 1, A.MeleeSlotsMax)
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
			local forced = pendingForcedBuild
			startBuild(if forced then math.clamp(forced, IT.Build.min, IT.Build.max) else nil)
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
		if t >= iEndsAt then
			startCalm()
		elseif t >= nextTrim then
			nextTrim = t + IT.Relax.trimEvery
			trimStragglers()
		end
	end
end

-- Behaviours -------------------------------------------------------------------------
-- the squad's heading from its centroid movement (smoothed), so patrols can cross its path
local function squadTick(t: number)
	local ps = playerPositions()
	if #ps == 0 then
		return
	end
	local c = centroid(ps)
	if lastCentroid and t - lastCentroidT >= 0.5 then
		local v = (c - lastCentroid) / (t - lastCentroidT)
		squadVel = squadVel:Lerp(Vector3.new(v.X, 0, v.Z), 0.5)
	end
	if not lastCentroid or t - lastCentroidT >= 0.5 then
		lastCentroid = c
		lastCentroidT = t
	end
end

local function patrolKinds(n: number): { string }
	local P = IT.Patrol
	local roster = EnemyData.Factions[factionId].roster
	n = math.min(n, math.floor(liveCap() - loadNow() - pendingLoad()))
	local out: { string } = {}
	local meds = 0
	for _ = 1, n do
		if meds < 2 and rng:NextNumber() < P.mediumChance then
			table.insert(out, roster.medium)
			meds += 1
		else
			table.insert(out, roster.regular)
		end
	end
	return out
end

-- CALM / BUILD patrol: 5-8 units 90-120 studs out, to the side of the squad's heading, walking across its path
local function patrol()
	local t = now()
	if inLull(t) then
		return
	end
	local ps = playerPositions()
	if #ps == 0 or loadNow() >= liveCap() - 6 then
		return
	end
	local P = IT.Patrol
	local c = centroid(ps)
	local fwd: Vector3? = nil
	local sp = Vector3.new(squadVel.X, 0, squadVel.Z)
	if sp.Magnitude >= P.minHeadingSpeed then
		fwd = sp.Unit
	end
	local r = randIn(P.dist)
	local spot: Vector3? = nil
	local spawnDir = Vector3.new(0, 0, -1)
	for _ = 1, 10 do
		local dir: Vector3
		if fwd then
			local sign = if rng:NextNumber() < 0.5 then 1 else -1
			dir = CFrame.Angles(0, math.rad(randIn(P.sideDeg) * sign), 0) * fwd
		else
			dir = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0) * Vector3.new(0, 0, -1)
		end
		local wx, wz = c.X + dir.X * r, c.Z + dir.Z * r
		local g = groundPos(wx, wz)
		if g and math.abs(g.X - wx) < 0.5 and math.abs(g.Z - wz) < 0.5 and minDistTo(ps, g) >= 80 then
			spot = g
			spawnDir = dir
			break
		end
	end
	if not spot then
		return
	end
	-- the walk target sits ahead of the squad and then past it on the far side: the patrol crosses the squad's path
	local ahead = if fwd then fwd * randIn(P.ahead) else Vector3.zero
	local want = c + ahead - spawnDir * randIn(P.overshoot)
	local dest = groundPos(want.X, want.Z) or want
	local kinds = patrolKinds(rng:NextInteger(P.count.min, P.count.max))
	deliver(kinds, spot, "ground", { aggro = false, patrol = false, dest = dest, crossFor = P.crossFor })
end

-- Spotted -> reinforce -------------------------------------------------------------------
local function makeFlare(e: any): Instance?
	if not e.model or not e.model.Parent or not e.root then
		return nil
	end
	local top = e.root.Position + Vector3.new(0, e.def.size * 2.2 + 1.5, 0)
	local p = Instance.new("Part")
	p.Name = "CallFlare"
	p.Size = Vector3.new(0.7, 14, 0.7)
	p.Color = Color3.fromRGB(255, 70, 50)
	p.Material = Enum.Material.Neon
	p.Transparency = 0.1
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.CFrame = CFrame.new(top + Vector3.new(0, 7, 0))
	local l = Instance.new("PointLight")
	l.Color = Color3.fromRGB(255, 80, 60)
	l.Brightness = 4
	l.Range = 26
	l.Parent = p
	p.Parent = e.model -- PivotTo carries it with the caller
	return p
end

local function endCall(cancelled: boolean)
	local c = pendingCall
	if not c then
		return
	end
	pendingCall = nil
	if c.flare and c.flare.Parent then
		c.flare:Destroy()
	end
	if cancelled then
		lastReinforce = c.prev -- a killed caller does not burn the cooldown
	end
end

local function fireCall(c: { e: any, fireAt: number, prev: number, flare: Instance? })
	local e = c.e
	endCall(false)
	if e.reinforced then
		chainCalls += 1 -- counted when the chained call actually lands (a cancelled flare does not use it up)
	end
	local t = now()
	local ps = playerPositions()
	if #ps == 0 then
		return
	end
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
	if S.State and S.State.notify then
		local f = EnemyData.Factions[factionId]
		S.State.notify(nil, if factionId == "COG" then "Enemy reinforcements inbound!" else "The Brood is breaching!", f.color, "warning")
	end
	-- during a breach the call is answered by the open source nearest the caller: an instant extra burst
	if istate == "breach" and not legacyWaves then
		local best: any = nil
		local bd = math.huge
		local at = e.pos or e.root.Position
		for _, src in armedSources() do
			local d = (src.pos - at).Magnitude
			if d < bd then
				bd = d
				best = src
			end
		end
		if best then
			emitFodder(best, IT.Sources.extraBurst)
			emitElite(best)
			return
		end
	end
	local tp = nearestOf(ps, e.root.Position) or ps[1]
	local spot = pickSpot(tp, 50, 75, MIN_PLAYER_DIST, ps)
	if not spot then
		return
	end
	local budget = (6 + 2.5 * #ps + difficulty * 1.5) * pressure
	local kinds = compose(math.min(budget, 26), factionId)
	deliver(kinds, spot, defaultMethod(), { aggro = true, patrol = true, reinforced = true })
end

-- A breach is "up" while it is arriving (BUILD), running (BREACH, incl. the extraction hold-out and a source still opening) and for
-- Config.Action.ReinforceBreachLockout seconds after it ended (RELAX included). No spotted call may start in that window: during a
-- breach the sources already pour units in, and answering each elite's call with an extra burst + elite made the field cascade.
local function breachWindow(t: number): boolean
	if istate == "build" or istate == "breach" or extractHold ~= nil or sourcesToOpen > 0 or BreachSources.count() > 0 then
		return true
	end
	return t - lastBreachEnd < Config.Action.ReinforceBreachLockout
end

-- true = a call started (the caller burns a flare for ReinforceWindup s) OR the caller may never call (nothing to retry);
-- false = refused for now: EnemyAI retries a refused caller after about a second.
function Director.onSpotted(e: any): boolean
	if not running or not e or not e.alive then
		return true -- nothing to retry
	end
	local t = now()
	local A = Config.Action
	if istate == "relax" or inLull(t) or pendingCall or breachWindow(t) then
		return false
	end
	if t - lastReinforce < A.ReinforceCooldown then
		return false
	end
	if loadNow() >= liveCap() - 6 then
		return false
	end
	-- units that arrived with a call chain at most A.ReinforceChainMax further calls per breach cycle (then they just fight)
	if e.reinforced and chainCalls >= A.ReinforceChainMax then
		return true
	end
	pendingCall = { e = e, fireAt = t + A.ReinforceWindup, prev = lastReinforce, flare = makeFlare(e) }
	lastReinforce = t
	return true
end

local function callTick(t: number)
	local c = pendingCall
	if not c then
		return
	end
	local e = c.e
	-- killing (or stunning / confusing) the caller cancels the call; so does a lull or the end of the breach pacing
	if not e.alive or e.status.stun or e.status.confuse or inLull(t) or istate == "relax" then
		endCall(true)
		return
	end
	if breachWindow(t) then
		endCall(true) -- a breach started (or a source is opening) during the flare: the breach answers, not the call
		return
	end
	if t >= c.fireAt then
		fireCall(c)
	end
end

-- a player going down: 4 s without new spawns
local function lullTick(t: number)
	local cur: { [Player]: boolean } = {}
	if S.Players and S.Players.getAlive then
		for _, p in S.Players.getAlive() do
			cur[p] = true
		end
	end
	for p in aliveSet do
		if not cur[p] and p.Parent then
			lullUntil = t + Config.Action.DownLull
			break
		end
	end
	aliveSet = cur
end

-- Proximity budget (BREACH): stragglers far from every player are moved next to a source
local function recycleSpot(): Vector3?
	local srcs = armedSources()
	if #srcs > 0 then
		local ring = IT.Sources.spawnRing
		return ringSpot(srcs[rng:NextInteger(1, #srcs)], ring.min, ring.max)
	end
	local ps = playerPositions()
	if #ps == 0 then
		return nil
	end
	local BW = IT.BreachWave
	return pickSpotDir(centroid(ps), iBearing, BW.spreadDeg, 45, 70, 30, ps)
end

local function proximityPass()
	if istate ~= "breach" then
		return
	end
	local ps = playerPositions()
	if #ps == 0 then
		return
	end
	local A = Config.Action
	local far = {}
	for _, e in S.Enemies.getAll() do
		if (e.class == "regular" or e.class == "medium") and not e.def.loot and minDistTo(ps, e.pos or e.root.Position) > A.RecycleDist then
			table.insert(far, e)
			if #far >= A.RecycleMax then
				break
			end
		end
	end
	for _, e in far do
		local spot = recycleSpot()
		if not spot then
			break
		end
		local kind = e.spawnKind or e.kind
		S.Enemies.despawn(e)
		spawnUnit(kind, spot, { aggro = true, patrol = true, hunt = true, home = spot })
	end
end

function Director.spawnWave(center: Vector3, budget: number, opts: any?)
	local o = opts or {}
	-- after Director.stop (Results/Failed phase) objective/extraction waves must not fire dropship fx for nothing
	if not map or not running then
		return 0
	end
	local faction = o.faction or factionId
	local ps = playerPositions()
	local kinds = compose(budget * (0.85 + 0.15 * difficulty) * (if o.ignorePressure then 1 else pressure), faction)
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

local function guarded(label: string, fn: (number) -> (), t: number)
	local ok, err = pcall(fn, t)
	if not ok then
		warn("[Director] " .. label .. " failed:", err)
	end
end

local function loop(myGen: number)
	local nextCleanup = now() + 5
	while running and gen == myGen do
		local t = now()
		guarded("lull", lullTick, t)
		if t >= nextSquad then
			nextSquad = t + 1
			guarded("squad", squadTick, t)
		end
		if t >= nextPatrol then
			local P = IT.Patrol
			local interval = (if istate == "build" then P.buildInterval else P.calmInterval) / pressure
			nextPatrol = t + interval * rng:NextNumber(0.85, 1.15)
			if (istate == "calm" or istate == "build") and not extractHold then
				guarded("patrol", patrol, t)
			end
		end
		guarded("call", callTick, t)
		guarded("intensity tick", intensityTick, t)
		if t >= nextProximity then
			nextProximity = t + Config.Action.RecycleInterval
			guarded("proximity", proximityPass, t)
		end
		if t >= nextCleanup then
			nextCleanup = t + 5
			guarded("cleanup", cleanup, t)
		end
		task.wait(0.25)
	end
end

-- BASTION emplacements (footage pass): 1-3 per COG mission (1 + floor((difficulty - 1) / 2)), each at an outpost site 16-22
-- studs out from the site centre on the side facing the insertion zone, facing it. Never within BASTION_MIN_INSERT of the
-- insertion point or BASTION_MIN_EXTRACT of the extraction pad (pads: insertion outer 85, extraction outer 60), never two within
-- BASTION_SPACING of each other, only on flat-ish ground. Returns how many were placed. Studio: DebugHook / DevTools op "bastion".
local BASTION_MIN_INSERT = 150
local BASTION_MIN_EXTRACT = 80
local BASTION_SPACING = 90
function Director.placeBastions(m: any, count: number?): number
	if not m or type(m.sites) ~= "table" or not S.Enemies then
		return 0
	end
	local n = count or math.clamp(1 + math.floor((difficulty - 1) / 2), 1, 3)
	local ins = if m.insertion then m.insertion.Position else Vector3.zero
	local ext: Vector3? = if typeof(m.extraction) == "Vector3" then m.extraction else nil
	local function flatDist(a: Vector3, b: Vector3): number
		return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
	end
	local cands: { Vector3 } = {}
	for name, cf in m.sites do
		if typeof(cf) == "CFrame" and not string.find(string.lower(name), "lever") then
			local p = cf.Position
			if flatDist(p, ins) >= BASTION_MIN_INSERT and (not ext or flatDist(p, ext) >= BASTION_MIN_EXTRACT) then
				table.insert(cands, p)
			end
		end
	end
	for i = #cands, 2, -1 do
		local j = rng:NextInteger(1, i)
		cands[i], cands[j] = cands[j], cands[i]
	end
	local placed: { Vector3 } = {}
	for _, site in cands do
		if #placed >= n then
			break
		end
		local toIns = Vector3.new(ins.X - site.X, 0, ins.Z - site.Z)
		local baseAng = if toIns.Magnitude > 1 then math.atan2(toIns.Z, toIns.X) else rng:NextNumber(0, math.pi * 2)
		for _ = 1, 8 do
			local ang = baseAng + math.rad(rng:NextNumber(-45, 45))
			local r = rng:NextNumber(16, 22)
			local g = groundPos(site.X + math.cos(ang) * r, site.Z + math.sin(ang) * r)
			if not g then
				continue
			end
			local ok = flatDist(g, ins) >= BASTION_MIN_INSERT and (not ext or flatDist(g, ext) >= BASTION_MIN_EXTRACT)
			for _, q in placed do
				if flatDist(g, q) < BASTION_SPACING then
					ok = false
				end
			end
			-- flat enough for an 11 x 11 block
			if ok then
				for _, o in { Vector3.new(5, 0, 0), Vector3.new(-5, 0, 0), Vector3.new(0, 0, 5), Vector3.new(0, 0, -5) } do
					local h = groundPos(g.X + o.X, g.Z + o.Z)
					if not h or math.abs(h.Y - g.Y) > 2.5 then
						ok = false
						break
					end
				end
			end
			if ok then
				local face = Vector3.new(ins.X, g.Y, ins.Z)
				local cf = if flatDist(face, g) > 1 then CFrame.lookAt(g, face) else CFrame.new(g)
				local okS, err = pcall(S.Enemies.spawn, "BASTION", cf, { aggro = false, patrol = false, home = g })
				if okS then
					table.insert(placed, g)
				else
					warn("[Director] Bastion spawn failed:", err)
				end
				break
			end
		end
	end
	return #placed
end

-- opts.noInitial: skip the opening guard groups (Studio test arena: pacing on, but nothing pre-placed)
function Director.start(m: any, faction: string, diff: number, opts: any?)
	Director.stop()
	map = m
	factionId = if EnemyData.Factions[faction] then faction else "COG"
	difficulty = math.clamp(math.floor(diff or 1), 1, #Config.DifficultyHpScale)
	pressure = 1
	startedAt = now()
	nextPatrol = startedAt + IT.Patrol.firstDelay
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
	chainCalls = 0
	lastBreachEnd = -1e9
	lastBearing = nil
	extractHold = nil
	queuedForce = nil
	timerCritical = false
	legacyWaves = false
	sourcesToOpen = 0
	heavyFired = false
	lullUntil = 0
	aliveSet = {}
	pendingCall = nil
	srcEvSeq = 0
	srcLastEv = nil
	squadVel = Vector3.zero
	lastCentroid = nil
	nextSquad = 0
	nextProximity = startedAt + 5
	BreachSources.clear()
	startCalm(true)

	-- initial guard groups around the patrol points, away from the insertion zone
	task.spawn(function()
		if opts and opts.noInitial then
			return
		end
		if factionId == "COG" then
			local okB, errB = pcall(Director.placeBastions, m)
			if not okB then
				warn("[Director] placeBastions failed:", errB)
			end
		end
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
			if loadNow() >= softCap then
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
	endCall(false)
	sourcesToOpen = 0
	BreachSources.clear()
	srcLastEv = nil
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
	BreachSources.init(s, { groundPos = groundPos })
	BreachSources.onOpen = function(src)
		pushSourceEvent("open", src)
	end
	BreachSources.onClose = function(src, why)
		pushSourceEvent("close", src, why)
		-- every source closed by the squad (and none still to open): the breach is over
		if why == "destroyed" and running and istate == "breach" and not extractHold and sourcesToOpen <= 0 and BreachSources.count() == 0 and not legacyWaves then
			if S.State and S.State.notify then
				S.State.notify(nil, "Breach sealed!", Config.Colors.Friendly)
			end
			startRelax()
		end
	end
end

return Director
