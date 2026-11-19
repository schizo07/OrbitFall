-- Garrisons: the enemies that already hold the map when the squad lands (called from Director.start).
--   Garrisons.place(m, faction, difficulty, ctx) -> (placed bodies)
--       m   = the mission map (m.sites: {[name]: CFrame}, m.patrolPoints, m.insertion, m.extraction)
--       ctx = { groundPos: (x, z) -> Vector3?, spots: (kinds, base) -> {Vector3}, alive: () -> boolean, players: number }
--   Garrisons.clear()
--   Garrisons.idleLoad() -> number   live-cap load of garrison units that have not joined the fight (cached ~0.5 s)
--
-- Guard posts: groups of 2-4 at the sites (bigger at objective sites), posture "guard", one squad key per post, opts.home = each
-- member's own spot. COG posts mix Tinkers and Rivet Troopers, the biggest posts get a Bulwark; Brood packs lurk at the nests;
-- Lumen posts mix Shardlings and Wardens. Patrol squads (2-3) of 2-4 walk a looping route between two or three sites, posture
-- "patrol". Nothing is placed within Config.Encounters.GarrisonMinInsertDist of the insertion point. Units get e.garrison = true
-- (the Director never trims / recycles them).
--   Garrisons.adopt(e)   tag a unit placed elsewhere (the haul objective's place crews) as a garrison unit that counts in idleLoad
-- Haul mission (S.Mission.objective == "HAUL"): the cell places and the refinery have their own crews (Objectives/HaulTwists), so no
-- post, patrol stop or patrol midpoint is placed inside their radius.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local EnemyData = require(Shared.Data.Enemies)
local MapPlan = require(script.Parent.Parent.World.MapPlan)

local Garrisons = {}

local S: { [string]: any } = {}
local rng = Random.new()
local units: { any } = {}
local idleCache = 0
local idleCacheAt = -1e9
local seq = 0

-- objective sites get the bigger posts; names not listed count as normal
local BIG_SITES = { silo = true, generator = true, console = true, codes = true, uplink = true }
local EXTRACT_CLEAR = 60 -- no post right on the extraction pad

local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function shuffle(t: { any })
	for i = #t, 2, -1 do
		local j = rng:NextInteger(1, i)
		t[i], t[j] = t[j], t[i]
	end
end

function Garrisons.init(s: { [string]: any })
	S = s
end

function Garrisons.clear()
	table.clear(units)
	idleCache = 0
	idleCacheAt = -1e9
end

-- a unit spawned by someone else that should hold its place like a garrison unit (never trimmed / recycled, idle load discounted)
function Garrisons.adopt(e: any)
	if e then
		e.garrison = true
		table.insert(units, e)
	end
end

-- Haul: circles (centre, radius) the normal posts keep out of: refinery, the three cell places and the spilled cell's pad
local function haulZones(m: any): { { p: Vector3, r: number } }
	local out: { { p: Vector3, r: number } } = {}
	local function at(name: string): Vector3?
		if type(m.places) == "table" and typeof(m.places[name]) == "Vector3" then
			return m.places[name]
		end
		local v = MapPlan.at(name)
		if v then
			local y = if m.groundY then m.groundY(v.X, v.Y) else 0
			return Vector3.new(v.X, if type(y) == "number" then y else 0, v.Y)
		end
		return nil
	end
	for _, name in { "refinery", "mesa", "quarry", "graveyard" } do
		local p = at(name)
		local def = MapPlan.places[name]
		if p and def then
			table.insert(out, { p = p, r = def.r })
		end
	end
	local sp: Vector3? = if type(m.places) == "table" and typeof(m.places.spilled) == "Vector3" then m.places.spilled else nil
	if not sp and type(m.sites) == "table" and typeof(m.sites.codes) == "CFrame" then
		sp = m.sites.codes.Position
	end
	if sp then
		table.insert(out, { p = sp, r = MapPlan.spilledPad[2] })
	end
	return out
end

-- a garrison unit counts as "in the fight" once it is alert / searching (Awareness writes e.awareState) or it has a target
local function engaged(e: any): boolean
	local st = e.awareState
	if st == "alert" or st == "search" then
		return true
	end
	return st == nil and e.target ~= nil
end

function Garrisons.idleLoad(): number
	local t = os.clock()
	if t - idleCacheAt < 0.5 then
		return idleCache
	end
	idleCacheAt = t
	local sum = 0
	local i = 1
	while i <= #units do
		local e = units[i]
		if not e.alive then
			units[i] = units[#units]
			units[#units] = nil
		else
			if not engaged(e) then
				sum += e.cost or 1
			end
			i += 1
		end
	end
	idleCache = sum
	return sum
end

-- Composition ---------------------------------------------------------------------------
-- n bodies for a guard post. kind: "big" | "nest" | "normal"
local function postKinds(faction: string, n: number, kind: string, heavyOk: boolean): { string }
	local roster = EnemyData.Factions[faction].roster
	local out: { string } = {}
	if heavyOk then
		table.insert(out, roster.heavy)
		n -= 1
	end
	local meds = if faction == "BROOD" then (if kind == "nest" then 1 else (if rng:NextNumber() < 0.5 then 1 else 0)) else (if n >= 4 then 2 else 1)
	for i = 1, n do
		table.insert(out, if i <= meds then roster.medium else roster.regular)
	end
	return out
end

local function patrolKinds(faction: string, n: number): { string }
	local roster = EnemyData.Factions[faction].roster
	local out: { string } = {}
	local meds = if faction == "BROOD" then (if rng:NextNumber() < 0.4 then 1 else 0) else 1
	for i = 1, n do
		table.insert(out, if i <= meds then roster.medium else roster.regular)
	end
	return out
end

-- Spawning ------------------------------------------------------------------------------
local function spawnOne(kind: string, pos: Vector3, face: Vector3, opts: any): any?
	local d = Vector3.new(face.X - pos.X, 0, face.Z - pos.Z)
	local cf = if d.Magnitude > 0.5 then CFrame.lookAt(pos, pos + d) else CFrame.new(pos)
	local ok, e = pcall(S.Enemies.spawn, kind, cf, opts)
	if not ok then
		warn("[Garrisons] spawn failed:", e)
		return nil
	end
	if e then
		e.garrison = true
		table.insert(units, e)
	end
	return e
end

function Garrisons.place(m: any, faction: string, difficulty: number, ctx: any): number
	if not S.Enemies or not m or not EnemyData.Factions[faction] then
		return 0
	end
	local E = Config.Encounters
	local players = math.max(ctx.players or 1, 1)
	local ins = if m.insertion then m.insertion.Position else Vector3.zero
	local ext: Vector3? = if typeof(m.extraction) == "Vector3" then m.extraction else nil
	local minIns = E.GarrisonMinInsertDist
	-- haul: the cell places and the refinery keep their own crews, so nothing here lands inside them
	local zones = if S.Mission and S.Mission.objective == "HAUL" then haulZones(m) else {}
	local function inZone(p: Vector3): boolean
		for _, z in zones do
			if flatDist(p, z.p) < z.r then
				return true
			end
		end
		return false
	end

	-- candidate post centres: the sites (not levers), else the patrol points
	type Cand = { name: string, p: Vector3, kind: string }
	local cands: { Cand } = {}
	if type(m.sites) == "table" then
		for name, cf in m.sites do
			if typeof(cf) == "CFrame" and not string.find(string.lower(name), "lever") then
				local p = cf.Position
				if not inZone(p) and flatDist(p, ins) >= minIns and (not ext or flatDist(p, ext) >= EXTRACT_CLEAR) then
					local kind = if BIG_SITES[name] then "big" elseif string.sub(name, 1, 4) == "nest" then "nest" else "normal"
					table.insert(cands, { name = name, p = p, kind = kind })
				end
			end
		end
	end
	if #cands < 3 and type(m.patrolPoints) == "table" then
		for i, p in m.patrolPoints do
			if typeof(p) == "Vector3" and not inZone(p) and flatDist(p, ins) >= minIns then
				table.insert(cands, { name = "pp" .. i, p = p, kind = "normal" })
			end
		end
	end
	if #cands == 0 then
		return 0
	end
	shuffle(cands)
	-- the faction's signature posts first: nests for the Brood, objective sites for the others
	local lead = if faction == "BROOD" then "nest" else "big"
	table.sort(cands, function(a, b)
		return (a.kind == lead and 1 or 0) > (b.kind == lead and 1 or 0)
	end)

	local diffT = math.clamp(difficulty, 1, 5)
	local maxBodies = math.min(10 + 2 * diffT + 2 * (players - 1), 24)
	local posts = math.clamp(math.floor(2 + diffT * 0.75 + (players - 1) * 0.6 + 0.5), 3, 7)
	local patrols = if diffT >= 3 or players >= 3 then 3 else 2
	local heavyPosts = if diffT >= 2 then math.min(1 + math.floor((diffT - 2) / 2), 2) else 0
	heavyPosts = math.min(heavyPosts, Config.MaxHeavies)
	local bodies = 0
	seq += 1
	local tag = "gar" .. seq .. "_"

	-- guard posts (leave room for the patrol squads: ~3 bodies each)
	local postBudget = if #cands >= 2 then maxBodies - patrols * 3 else maxBodies
	local used: { Cand } = {}
	for i, c in cands do
		if #used >= posts or bodies >= postBudget or not ctx.alive() then
			break
		end
		local n = if c.kind == "big" or c.kind == "nest" then rng:NextInteger(3, 4) else rng:NextInteger(2, 3)
		n = math.min(n, postBudget - bodies)
		local heavyOk = heavyPosts > 0 and (c.kind == lead) and n >= 3
		if heavyOk then
			heavyPosts -= 1
		end
		if n < 2 then
			break
		end
		local kinds = postKinds(faction, n, c.kind, heavyOk)
		-- the post stands a little off the site centre, on the side the squad will come from
		local toIns = Vector3.new(ins.X - c.p.X, 0, ins.Z - c.p.Z)
		local ang = (if toIns.Magnitude > 1 then math.atan2(toIns.Z, toIns.X) else rng:NextNumber(0, math.pi * 2)) + math.rad(rng:NextNumber(-70, 70))
		local r = if c.kind == "nest" then rng:NextNumber(4, 9) else rng:NextNumber(7, 13)
		local base = ctx.groundPos(c.p.X + math.cos(ang) * r, c.p.Z + math.sin(ang) * r) or c.p
		if inZone(base) then -- a post by a place's edge would stand inside it
			if heavyOk then
				heavyPosts += 1
			end
			continue
		end
		local spots = ctx.spots(kinds, base)
		local squad = tag .. "g" .. i
		-- guards face outward from the site
		for k, kind in kinds do
			local pos = spots[k] or base
			local out = pos - c.p
			local face = if out.Magnitude > 1 then pos + out else ins
			if spawnOne(kind, pos, face, { posture = "guard", squad = squad, home = pos, aggro = false, patrol = false }) then
				bodies += 1
			end
		end
		table.insert(used, c)
		task.wait(0.05)
	end

	-- patrol squads: loop through 2-3 sites (route points sit 10-16 studs off each site centre, with a midpoint between sites)
	if #cands >= 2 then
		for pIdx = 1, patrols do
			if bodies >= maxBodies or not ctx.alive() then
				break
			end
			local order = table.clone(cands)
			shuffle(order)
			local stops: { Vector3 } = {}
			for _, c in order do
				if #stops >= (if #cands >= 3 and rng:NextNumber() < 0.5 then 3 else 2) then
					break
				end
				local okFar = true
				for _, q in stops do
					if flatDist(q, c.p) < 60 then
						okFar = false
						break
					end
				end
				if okFar then
					local a = rng:NextNumber(0, math.pi * 2)
					local g = ctx.groundPos(c.p.X + math.cos(a) * rng:NextNumber(10, 16), c.p.Z + math.sin(a) * rng:NextNumber(10, 16))
					if g and not inZone(g) then
						table.insert(stops, g)
					end
				end
			end
			if #stops < 2 then
				continue
			end
			local route: { Vector3 } = {}
			for k, p in stops do
				table.insert(route, p)
				local q = stops[k % #stops + 1]
				local mid = (p + q) / 2
				local g = ctx.groundPos(mid.X, mid.Z)
				if g and flatDist(g, ins) >= minIns and not inZone(g) then
					table.insert(route, g)
				end
			end
			local n = math.min(rng:NextInteger(2, 4), maxBodies - bodies)
			if n < 2 then
				break
			end
			local kinds = patrolKinds(faction, n)
			local start = route[1]
			local spots = ctx.spots(kinds, start)
			local squad = tag .. "p" .. pIdx
			for k, kind in kinds do
				local pos = spots[k] or start
				if spawnOne(kind, pos, route[2] or ins, { posture = "patrol", route = route, squad = squad, home = start, aggro = false, patrol = false }) then
					bodies += 1
				end
			end
			task.wait(0.05)
		end
	end
	return bodies
end

return Garrisons
