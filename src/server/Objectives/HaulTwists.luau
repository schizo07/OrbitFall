-- Haul objective set pieces ("Recover Core Cells"): what waits at each cell place and how the refinery fights back.
--   HaulTwists.new(ctx, cfg) -> twists
--       ctx = the ObjectiveService ctx, cfg = { liftPos, places = {[name]: Vector3}, spots = {[place]: {CFrame}} }
--   twists.start()                          starts the proximity watch and the opening refinery guard
--   twists.onLift(place, player)            a cell was lifted from its resting spot (mesa alarm, graveyard wake-up)
--   twists.onDelivered(delivered, total)    refinery escalation: probe at 2 cells, counter-attack at half
--   twists.finalWave()                      last cell loaded: the big wave (HaulCells runs the launch countdown)
--   twists.stop()                           ends the loops and puts the relay mast light back
-- Places (crews are spawned when a trooper comes within ACTIVATE_R of the place, so the map is not full of idle units):
--   spilled   a small scavenger crew around the drone's cell (guard + one patrol)
--   mesa      lifting a cell trips the relay alarm: the mast light flashes red and a wave comes down the cliffs
--   quarry    shooters on the terraces and a few on the pit floor
--   graveyard dormant robots among the walker ribs; they power up when a cell is lifted, someone walks close or one is hurt
-- Units here are tagged as garrison so the Director never trims or recycles them. Counts scale with the squad size.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local EnemyData = require(Shared.Data.Enemies)
local MapPlan = require(script.Parent.Parent.World.MapPlan)
local Garrisons = require(script.Parent.Parent.Enemies.Garrisons)

local HaulTwists = {}

local TAU = math.pi * 2
local ACTIVATE_R = 150 -- a trooper this close to a place (studs) spawns its crew
local WAKE_R = 10 -- a trooper this close to a dormant robot wakes the graveyard
local ALARM_MAX = 40 -- s the mesa alarm lasts at most (it also ends when its wave is dead)
local FLASH_PERIOD = 0.35
local MAST_RED = Color3.fromRGB(255, 60, 50)
local CALLOUT = Color3.fromRGB(244, 246, 250)
local DORMANT_OFF = 1e15 -- nextThink of a dormant robot: it never thinks until woken (server time is ~1.8e9 s, so 1e9 would not hold)
local DANGER = Config.Colors.Danger

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

function HaulTwists.new(ctx: any, cfg: any): any
	local S = ctx.S
	local map = ctx.map
	local rng = ctx.rng
	local faction = if EnemyData.Factions[ctx.faction] then ctx.faction else "COG"
	local roster = EnemyData.Factions[faction].roster
	local difficulty = math.clamp(math.floor(tonumber(ctx.difficulty) or 1), 1, 5)
	local anchors = map.anchors or {}
	local liftPos: Vector3 = cfg.liftPos
	local tw: any = {}
	local alive = true
	local seq = 0

	-- ------------------------------------------------------------------ small helpers
	local function gp(x: number, z: number): Vector3
		local y = if map.groundY then map.groundY(x, z) else liftPos.Y
		if type(y) ~= "number" or y ~= y then
			y = liftPos.Y
		end
		return Vector3.new(x, y, z)
	end

	local function playerPositions(): { Vector3 }
		local out: { Vector3 } = {}
		for _, p in ctx.players() do
			local r = ctx.getRoot(p)
			if r then
				table.insert(out, r.Position)
			end
		end
		return out
	end

	local function nearestPlayerDist(pos: Vector3, ps: { Vector3 }): number
		local best = math.huge
		for _, q in ps do
			best = math.min(best, flat(pos, q))
		end
		return best
	end

	-- lo with one trooper, hi with four or more
	local function squadCount(lo: number, hi: number): number
		local n = math.max(#ctx.players(), 1)
		return math.floor(lo + (hi - lo) * math.clamp((n - 1) / 3, 0, 1) + 0.5)
	end

	local function shuffled(list: { any }): { any }
		local t = table.clone(list)
		for i = #t, 2, -1 do
			local j = rng:NextInteger(1, i)
			t[i], t[j] = t[j], t[i]
		end
		return t
	end

	-- comms line from `who` (or a random living trooper); the system line if nobody is alive
	local function say(line: string, who: Player?)
		local p = who
		if not p then
			local list = ctx.players()
			if #list > 0 then
				p = list[rng:NextInteger(1, #list)]
			end
		end
		if p and S and S.State then
			S.State.notify(nil, p.DisplayName .. ": " .. line, CALLOUT, "comms")
		else
			ctx.notify(line, DANGER)
		end
	end

	local function centroid(cfs: { CFrame }, fallback: Vector3): Vector3
		if #cfs == 0 then
			return fallback
		end
		local sum = Vector3.zero
		for _, cf in cfs do
			sum += cf.Position
		end
		return sum / #cfs
	end

	local function placePos(name: string): Vector3
		local p = cfg.places and cfg.places[name]
		if typeof(p) == "Vector3" then
			return p
		end
		return liftPos
	end

	local function placeRadius(name: string): number
		local def = MapPlan.places[name]
		return if def then def.r else 45
	end

	local function mix(n: number, share: number): { string }
		local out: { string } = {}
		local meds = math.floor(n * share)
		for i = 1, n do
			table.insert(out, if i <= meds then roster.medium else roster.regular)
		end
		return out
	end

	-- shooters for the quarry terraces: the Brood's spitters, otherwise light / medium gunners
	local function shooterKind(i: number): string
		if faction == "BROOD" then
			return roster.medium
		end
		return if i % 2 == 0 then roster.medium else roster.regular
	end

	-- one unit; guards and dormant robots are adopted by Garrisons (idle units do not use up the live cap), the rest only
	-- carry the garrison tag (never trimmed or recycled by the Director)
	local function spawnUnit(kind: string, pos: Vector3, face: Vector3?, opts: any, adopt: boolean): any?
		if not (S and S.Enemies and S.Enemies.spawn) or not alive or not ctx.alive() then
			return nil
		end
		local cf = CFrame.new(pos)
		if face then
			local d = Vector3.new(face.X - pos.X, 0, face.Z - pos.Z)
			if d.Magnitude > 0.5 then
				cf = CFrame.lookAt(pos, pos + d)
			end
		end
		local ok, e = pcall(S.Enemies.spawn, kind, cf, opts)
		if not ok then
			warn("[HaulTwists] spawn failed:", e)
			return nil
		end
		if e then
			if adopt then
				Garrisons.adopt(e)
			else
				e.garrison = true
			end
		end
		return e
	end

	local function nextSquad(tag: string): string
		seq += 1
		return "haul_" .. tag .. seq
	end

	local function hunterOpts(dest: Vector3?, home: Vector3, squad: string): any
		return { aggro = true, posture = "hunt", patrol = true, hunt = true, home = home, dest = dest, squad = squad }
	end

	-- a loose ring of points around `center` on the ground
	local function ringPoints(center: Vector3, n: number, rMin: number, rMax: number): { Vector3 }
		local out: { Vector3 } = {}
		local a0 = rng:NextNumber(0, TAU)
		for i = 1, n do
			local a = a0 + (i - 1) / math.max(n, 1) * TAU + rng:NextNumber(-0.25, 0.25)
			local r = rng:NextNumber(rMin, rMax)
			out[i] = gp(center.X + math.cos(a) * r, center.Z + math.sin(a) * r)
		end
		return out
	end

	-- a spot on a ring around the refinery, away from the squad and inside the playable floor
	local function wavePoint(center: Vector3, rMin: number, rMax: number, ps: { Vector3 }): Vector3
		local best: Vector3? = nil
		local bestD = -1
		for _ = 1, 40 do
			local a = rng:NextNumber(0, TAU)
			local r = rng:NextNumber(rMin, rMax)
			local x, z = center.X + math.cos(a) * r, center.Z + math.sin(a) * r
			if math.abs(x) <= 230 and math.abs(z) <= 230 then
				local g = gp(x, z)
				local d = nearestPlayerDist(g, ps)
				if d >= 45 then
					return g
				end
				if d > bestD then
					bestD = d
					best = g
				end
			end
		end
		return best or gp(center.X + rMin, center.Z)
	end

	-- hunters in a short line behind `base`
	local function spawnHunters(kinds: { string }, base: Vector3, dest: Vector3, squad: string): { any }
		local out: { any } = {}
		local across = Vector3.new(-(dest.Z - base.Z), 0, dest.X - base.X)
		across = if across.Magnitude > 0.1 then across.Unit else Vector3.new(1, 0, 0)
		for i, kind in kinds do
			local off = (i - (#kinds + 1) / 2) * 3.2
			local pos = gp(base.X + across.X * off, base.Z + across.Z * off)
			local e = spawnUnit(kind, pos, dest, hunterOpts(dest, pos, squad), false)
			if e then
				table.insert(out, e)
			end
			task.wait(0.05)
		end
		return out
	end

	-- ------------------------------------------------------------------ crews that wait at the places
	local dormant: { any } = {}
	local dormantWoken = false

	local function spawnSpilled()
		local c = centroid(cfg.spots.spilled or {}, placePos("spilled"))
		local n = squadCount(3, 4)
		local squad = nextSquad("spilled")
		local pts = ringPoints(c, n, 6, 10)
		-- one of them walks a small loop around the cell, the rest stand guard facing outward
		local route: { Vector3 } = {}
		for k = 0, 3 do
			local a = k / 4 * TAU + rng:NextNumber(0, 0.5)
			table.insert(route, gp(c.X + math.cos(a) * 15, c.Z + math.sin(a) * 15))
		end
		for i = 1, n do
			local pos = pts[i]
			if i == n then
				spawnUnit(roster.regular, route[1], route[2], { posture = "patrol", route = route, squad = squad, home = route[1], aggro = false, patrol = false }, true)
			else
				local out = pos - c
				spawnUnit(roster.regular, pos, if out.Magnitude > 1 then pos + out else nil, { posture = "guard", squad = squad, home = pos, aggro = false, patrol = false }, true)
			end
			task.wait(0.05)
		end
	end

	local function spawnQuarry()
		local centre = placePos("quarry")
		local terr: { CFrame } = {}
		for _, cf in anchors.terraces or {} do
			if typeof(cf) == "CFrame" then
				table.insert(terr, cf)
			end
		end
		if #terr == 0 then
			-- no terrace spots: stand on a ring of the pit's upper rim, facing in
			local r = placeRadius("quarry") * 0.75
			for k = 1, 8 do
				local a = k / 8 * TAU
				local p = gp(centre.X + math.cos(a) * r, centre.Z + math.sin(a) * r)
				table.insert(terr, CFrame.lookAt(p, Vector3.new(centre.X, p.Y, centre.Z)))
			end
		end
		local lo = 4 + (if difficulty >= 3 then 1 else 0) + (if difficulty >= 5 then 1 else 0)
		local n = math.min(squadCount(lo, lo + 3), #terr)
		local squad = nextSquad("quarry")
		-- spread over the whole rim: every k-th spot
		local step = #terr / math.max(n, 1)
		for i = 1, n do
			local cf = terr[math.floor((i - 1) * step) + 1]
			local pos = cf.Position
			spawnUnit(shooterKind(i), pos, pos + cf.LookVector * 10, { posture = "guard", squad = squad, home = pos, aggro = false, patrol = false }, true)
			task.wait(0.05)
		end
		-- a few on the pit floor
		local nf = squadCount(2, 3) + (if difficulty >= 4 then 1 else 0)
		local pts = ringPoints(centre, nf, 6, 16)
		local kinds = mix(nf, 0.34)
		for i = 1, nf do
			local pos = pts[i]
			local out = pos - centre
			spawnUnit(kinds[i], pos, if out.Magnitude > 1 then pos + out else nil, { posture = "guard", squad = squad, home = pos, aggro = false, patrol = false }, true)
			task.wait(0.05)
		end
	end

	-- dormant robots: spawned and held still. nextThink = never, so they do not sense, turn or shoot until woken
	local function spawnGraveyard()
		local centre = placePos("graveyard")
		local spots: { Vector3 } = {}
		for _, cf in shuffled(anchors.dormant or {}) do
			if typeof(cf) == "CFrame" then
				table.insert(spots, cf.Position)
			end
		end
		local n = squadCount(4, 6)
		if #spots == 0 then
			spots = ringPoints(centre, n, 8, 20)
		end
		n = math.min(n, #spots)
		local squad = nextSquad("grave")
		for i = 1, n do
			local pos = spots[i]
			local kind = if i == 1 and difficulty >= 3 then roster.medium else roster.regular
			local e = spawnUnit(kind, pos, centre, { posture = "guard", squad = squad, home = pos, aggro = false, patrol = false }, true)
			if e then
				e.nextThink = DORMANT_OFF
				table.insert(dormant, e)
			end
			task.wait(0.05)
		end
	end

	local awarenessMod: any = nil
	local function awareness(): any
		if awarenessMod == nil then
			local ok, mod = pcall(function()
				return require(script.Parent.Parent.Enemies.Awareness)
			end)
			awarenessMod = if ok then mod else false
		end
		return awarenessMod or nil
	end

	local function nearestPlayer(pos: Vector3): Player?
		local best: Player? = nil
		local bestD = math.huge
		for _, p in ctx.players() do
			local r = ctx.getRoot(p)
			if r then
				local d = flat(r.Position, pos)
				if d < bestD then
					bestD = d
					best = p
				end
			end
		end
		return best
	end

	local function wakeDormant(who: Player?)
		if dormantWoken then
			return
		end
		dormantWoken = true
		ctx.notify("Metal groans: the walker graveyard is powering up!", DANGER)
		say("Something's moving in the wreckage!", who)
		for i, e in dormant do
			task.delay(0.15 + (i - 1) * 0.3 + rng:NextNumber(0, 0.2), function()
				if not alive or not ctx.alive() or not e.alive then
					return
				end
				local pos = e.pos or Vector3.zero
				ctx.sound("HitMetal", pos)
				e.nextThink = workspace:GetServerTimeNow()
				local target = who or nearestPlayer(pos)
				local aw = awareness()
				local root = target and ctx.getRoot(target)
				if aw and aw.alert then
					pcall(aw.alert, e, target, if root then root.Position else nil, "ally")
				else
					e.aggro = true
				end
			end)
		end
	end

	local function checkDormant()
		if dormantWoken or #dormant == 0 then
			return
		end
		for _, e in dormant do
			if e.alive and (e.hp < e.maxHp - 0.01 or e.awareState == "alert") then
				wakeDormant(nil)
				return
			end
		end
		for _, p in ctx.players() do
			local r = ctx.getRoot(p)
			if r then
				for _, e in dormant do
					if e.alive and e.pos and flat(r.Position, e.pos) <= WAKE_R and math.abs(r.Position.Y - e.pos.Y) <= 12 then
						wakeDormant(p)
						return
					end
				end
			end
		end
	end

	-- ------------------------------------------------------------------ mesa alarm
	local mesaFired = false
	local restoreMast: (() -> ())? = nil

	-- flash the relay mast's beacon red; returns the function that puts it back
	local function flashMast(): (() -> ())?
		local mast = anchors.mastLight
		if typeof(mast) ~= "Instance" or not mast:IsA("BasePart") then
			return nil
		end
		local baseColor, baseMat = mast.Color, mast.Material
		local lights: { [Instance]: { Color3 | boolean } } = {}
		for _, d in mast:GetDescendants() do
			if d:IsA("Light") then
				lights[d] = { d.Color, d.Enabled }
			end
		end
		local glow = Instance.new("PointLight")
		glow.Name = "AlarmGlow"
		glow.Color = MAST_RED
		glow.Range = 40
		glow.Brightness = 2.5
		glow.Shadows = false
		glow.Enabled = false
		glow.Parent = mast
		local running = true
		task.spawn(function()
			local on = false
			while running and alive and ctx.alive() and mast.Parent do
				on = not on
				mast.Color = if on then MAST_RED else baseColor
				mast.Material = if on then Enum.Material.Neon else baseMat
				glow.Enabled = on
				for l, v in lights do
					local li: any = l
					li.Color = if on then MAST_RED else v[1]
				end
				task.wait(FLASH_PERIOD)
			end
		end)
		return function()
			running = false
			if mast.Parent then
				mast.Color = baseColor
				mast.Material = baseMat
			end
			glow:Destroy()
			for l, v in lights do
				local li: any = l
				if li.Parent then
					li.Color = v[1]
					li.Enabled = v[2]
				end
			end
		end
	end

	local function startAlarm(who: Player?)
		local mesa = placePos("mesa")
		local ramp = gp(mesa.X + (liftPos.X - mesa.X) / math.max(flat(liftPos, mesa), 1) * placeRadius("mesa") * 0.85, mesa.Z + (liftPos.Z - mesa.Z) / math.max(flat(liftPos, mesa), 1) * placeRadius("mesa") * 0.85)
		ctx.notify("Relay alarm! Hostiles are coming down from the cliffs.", DANGER)
		say("Alarm's tripped, they're coming!", who)
		ctx.sound("Alarm", mesa)
		restoreMast = flashMast()
		task.spawn(function()
			-- the nearest cliff spawn points (not on top of a trooper); two groups when two points are far enough apart
			local ps = playerPositions()
			local points: { Vector3 } = {}
			for _, sp in map.spawnPoints or {} do
				if typeof(sp) == "Vector3" and nearestPlayerDist(sp, ps) >= 60 then
					table.insert(points, sp)
				end
			end
			table.sort(points, function(a, b)
				return flat(a, mesa) < flat(b, mesa)
			end)
			local first = points[1]
			if not first then
				local away = Vector3.new(mesa.X - liftPos.X, 0, mesa.Z - liftPos.Z)
				away = if away.Magnitude > 1 then away.Unit else Vector3.new(-1, 0, 0)
				first = gp(math.clamp(mesa.X + away.X * 60, -230, 230), math.clamp(mesa.Z + away.Z * 60, -230, 230))
			end
			local second: Vector3? = nil
			for i = 2, #points do
				if flat(points[i], first) >= 25 then
					second = points[i]
					break
				end
			end
			local n = math.min(squadCount(5, 7) + (if difficulty >= 4 then 1 else 0), 7)
			local kinds = mix(n, 0.34)
			local g1: { string } = {}
			local g2: { string } = {}
			for i, k in kinds do
				table.insert(if second and i % 2 == 0 then g2 else g1, k)
			end
			local wave: { any } = {}
			for _, e in spawnHunters(g1, first, ramp, nextSquad("alarm")) do
				table.insert(wave, e)
			end
			if second and #g2 > 0 then
				for _, e in spawnHunters(g2, second, ramp, nextSquad("alarm")) do
					table.insert(wave, e)
				end
			end
			-- the alarm stops when the wave is dead or after ALARM_MAX seconds
			local t0 = os.clock()
			local nextBlare = 0
			while alive and ctx.alive() do
				task.wait(0.5)
				local left = 0
				for _, e in wave do
					if e.alive then
						left += 1
					end
				end
				local t = os.clock() - t0
				if t >= nextBlare then
					nextBlare = t + 6
					ctx.sound("Alarm", mesa)
				end
				if left == 0 or t >= ALARM_MAX then
					break
				end
			end
			if restoreMast then
				restoreMast()
				restoreMast = nil
			end
			if alive and ctx.alive() then
				ctx.notify("The relay alarm has gone quiet.", Config.Colors.Friendly)
			end
		end)
	end

	-- ------------------------------------------------------------------ refinery escalation
	local gates: { CFrame } = {}
	for _, cf in anchors.gates or {} do
		if typeof(cf) == "CFrame" then
			table.insert(gates, cf)
		end
	end
	if #gates == 0 then
		-- no gap anchors: three entry points on the refinery's outer ring, the first toward the drop zone
		local toIns = if map.insertion then Vector3.new(map.insertion.Position.X - liftPos.X, 0, map.insertion.Position.Z - liftPos.Z) else Vector3.new(-1, 0, 1)
		local a0 = math.atan2(toIns.Z, toIns.X)
		local r = placeRadius("refinery")
		for k = 0, 2 do
			local a = a0 + k / 3 * TAU
			local p = gp(liftPos.X + math.cos(a) * r, liftPos.Z + math.sin(a) * r)
			table.insert(gates, CFrame.lookAt(p, Vector3.new(liftPos.X, p.Y, liftPos.Z)))
		end
	end

	-- units that walk in through a gap (up to two gaps share the group)
	local function throughGates(kinds: { string }, tag: string)
		local order = shuffled(gates)
		local groups: { { string } } = { {}, {} }
		local use = math.min(2, #order)
		for i, k in kinds do
			table.insert(groups[(i - 1) % use + 1], k)
		end
		local squad = nextSquad(tag)
		for gi = 1, use do
			local cf: CFrame = order[gi]
			local base = gp(cf.Position.X - cf.LookVector.X * 9, cf.Position.Z - cf.LookVector.Z * 9)
			task.spawn(spawnHunters, groups[gi], base, liftPos, squad)
		end
	end

	-- groups of <= 4 from different points of the outer ring
	local function fromRing(kinds: { string }, tag: string)
		local ps = playerPositions()
		local i = 1
		while i <= #kinds do
			local group: { string } = {}
			for j = i, math.min(i + 3, #kinds) do
				table.insert(group, kinds[j])
			end
			i += 4
			local base = wavePoint(liftPos, 70, 95, ps)
			task.spawn(spawnHunters, group, base, liftPos, nextSquad(tag))
		end
	end

	local fired = { guard = false, probe = false, counter = false, final = false }

	local function refineryGuard()
		if fired.guard then
			return
		end
		fired.guard = true
		local n = squadCount(2, 3)
		local squad = nextSquad("lifter")
		local pts = ringPoints(liftPos, n, 18, 24)
		for i = 1, n do
			local pos = pts[i]
			spawnUnit(roster.regular, pos, pos + (pos - liftPos), { posture = "guard", squad = squad, home = pos, aggro = false, patrol = false }, true)
			task.wait(0.05)
		end
	end

	function tw.onDelivered(delivered: number, total: number)
		if not alive or delivered >= total then
			return
		end
		if delivered == 2 and not fired.probe then
			fired.probe = true
			ctx.notify("Contacts at the refinery gates!", DANGER)
			say("Movement at the gates!", nil)
			throughGates(mix(math.clamp(squadCount(3, 4), 3, 4), 0.34), "probe")
		end
		local half = math.max(3, math.ceil(total / 2))
		if delivered == half and not fired.counter then
			fired.counter = true
			ctx.notify("A counter-attack is hitting the refinery!", DANGER)
			say("They're counter-attacking, hold the lifter!", nil)
			ctx.sound("Alarm", liftPos)
			fromRing(mix(math.clamp(squadCount(6, 8), 6, 8), 0.34), "counter")
		end
	end

	function tw.finalWave()
		if not alive or fired.final then
			return
		end
		fired.final = true
		say("Everything they've got is coming, hold the lifter!", nil)
		local n = squadCount(8, 11)
		local kinds = mix(n, 0.3)
		if difficulty >= 3 and S and S.Enemies and S.Enemies.countByClass then
			local ok, counts = pcall(S.Enemies.countByClass)
			if ok and counts and counts.heavy < Config.MaxHeavies and roster.heavy then
				kinds[1] = roster.heavy
			end
		end
		local half = math.floor(#kinds / 2)
		local viaGates: { string } = {}
		local viaRing: { string } = {}
		for i, k in kinds do
			table.insert(if i <= half then viaGates else viaRing, k)
		end
		if #viaGates > 0 then
			throughGates(viaGates, "last")
		end
		if #viaRing > 0 then
			fromRing(viaRing, "last")
		end
	end

	function tw.onLift(place: string, player: Player?)
		if not alive then
			return
		end
		if place == "mesa" and not mesaFired then
			mesaFired = true
			startAlarm(player)
		elseif place == "graveyard" then
			wakeDormant(player)
		end
	end

	-- ------------------------------------------------------------------ watch loop
	function tw.start()
		local crews = {
			{ name = "spilled", spawn = spawnSpilled, done = false },
			{ name = "quarry", spawn = spawnQuarry, done = false },
			{ name = "graveyard", spawn = spawnGraveyard, done = false },
		}
		-- the opening guard waits a moment so the Director's own setup (HP scale, garrison list) is in place first
		task.delay(4, function()
			if alive and ctx.alive() then
				refineryGuard()
			end
		end)
		task.spawn(function()
			while alive and ctx.alive() do
				task.wait(0.25)
				for _, c in crews do
					if not c.done and #ctx.playersNear(placePos(c.name), ACTIVATE_R) > 0 then
						c.done = true
						task.spawn(c.spawn)
					end
				end
				checkDormant()
			end
		end)
	end

	function tw.stop()
		alive = false
		if restoreMast then
			restoreMast()
			restoreMast = nil
		end
		-- robots still lying dormant when the objective ends go back to normal thinking
		for _, e in dormant do
			if e.alive and e.nextThink and e.nextThink > DORMANT_OFF / 2 then
				e.nextThink = workspace:GetServerTimeNow()
			end
		end
	end

	return tw
end

return HaulTwists
