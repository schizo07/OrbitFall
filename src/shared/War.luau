-- Pure war-state maths (docs/spec.md §14). Shared so the server decides and the client can show
-- countdowns without extra traffic.
--
-- Inputs:
--   contrib  { ["P_<planet>"] = {v, t}, ["O_<op>"] = {v, t} }   community progress (liberation / defence)
--   outcomes { ["<opId>"] = "success" | "fail", ["L_<planet>"] = "liberated" }  permanent results
--   t        unix seconds (os.time() on the server; workspace:GetServerTimeNow() works too)

local Planets = require(script.Parent.Data.Planets)
local Campaign = require(script.Parent.Data.Campaign)

local War = {}

export type PlanetState = {
	id: string,
	owner: string, -- "FREE" | "COG" | "BROOD"
	destroyed: boolean,
	lib: number, -- liberation % (enemy-held planets)
	defense: number?, -- defence % while a defend op is active
	op: string?, -- active operation id
	faction: string?, -- enemy you fight here (nil = nothing to fight)
	playable: boolean,
}

local function hoursOverlap(a0: number, a1: number, t: number): number
	local e = math.min(a1, t)
	if e <= a0 then
		return 0
	end
	return (e - a0) / 3600
end

local function sortedOps()
	local ops = table.clone(Campaign.Operations)
	table.sort(ops, function(a, b)
		return a.ends < b.ends
	end)
	return ops
end

function War.opStatus(op, outcomes, t): string
	local o = outcomes[op.id]
	if o == "success" or o == "fail" then
		return o
	end
	if t < op.starts then
		return "upcoming"
	end
	if t >= op.ends then
		return "expired" -- deadline passed but the server hasn't written the outcome yet
	end
	return "active"
end

-- Contributions are stored per key as { v = %, t = unix time of last update }.
-- Keys: "P_<planet>" (liberation, decays during that planet's liberate ops) and "O_<op>" (defence of a defend op).
-- Decay runs forward from the last update and clamps at 0, so idle time before anyone plays costs nothing extra.
local function resistWindows(key: string): { { a: number, b: number, r: number } }
	local out = {}
	if key:sub(1, 2) == "P_" then
		local pid = key:sub(3)
		for _, op in Campaign.Operations do
			if op.planet == pid and op.kind == "liberate" then
				table.insert(out, { a = op.starts, b = op.ends, r = op.resist })
			end
		end
	elseif key:sub(1, 2) == "O_" then
		local op = Campaign.get(key:sub(3))
		if op then
			table.insert(out, { a = op.starts, b = op.ends, r = op.resist })
		end
	end
	return out
end

local function entryOf(raw: any): (number, number)
	if type(raw) == "table" then
		return tonumber(raw.v) or 0, tonumber(raw.t) or 0
	end
	return tonumber(raw) or 0, 0
end

-- Value of a key at time t (decay applied since its last update).
function War.value(key: string, raw: any, t: number): number
	local v, t0 = entryOf(raw)
	if v <= 0 then
		return 0
	end
	local loss = 0
	for _, w in resistWindows(key) do
		local a = math.max(w.a, t0)
		loss += w.r * hoursOverlap(a, w.b, t)
	end
	return math.clamp(v - loss, 0, 100)
end

-- New stored entry after adding `gain` at time t.
function War.applyGain(key: string, raw: any, gain: number, t: number): { v: number, t: number }
	return { v = math.clamp(War.value(key, raw, t) + gain, 0, 100), t = t }
end

-- Progress % of an operation right now.
function War.opProgress(op, contrib, t): number
	if op.kind == "defend" then
		local k = "O_" .. op.id
		return War.value(k, contrib[k], t)
	end
	return War.liberation(op.planet, contrib, t)
end

function War.liberation(planetId: string, contrib, t): number
	local k = "P_" .. planetId
	return War.value(k, contrib[k], t)
end

function War.compute(contrib, outcomes, t): { [string]: PlanetState }
	local out: { [string]: PlanetState } = {}
	for id, p in Planets.byId do
		out[id] = { id = id, owner = p.owner, destroyed = false, lib = 0, playable = false }
	end
	-- free-play liberations first, so a later dev-scripted defeat ("lost"/"destroyed") still overrides them
	for id, st in out do
		if outcomes["L_" .. id] == "liberated" then
			st.owner = "FREE"
		end
	end
	-- permanent results, oldest first
	for _, op in sortedOps() do
		local st = out[op.planet]
		local o = outcomes[op.id]
		if st and o == "success" then
			if op.onSuccess == "liberated" then
				st.owner = "FREE"
			end
		elseif st and o == "fail" then
			if op.onFail == "destroyed" then
				st.destroyed = true
			elseif op.onFail == "lost" then
				st.owner = op.faction
			end
		end
	end
	-- live values
	for id, st in out do
		if st.owner ~= "FREE" then
			st.lib = War.liberation(id, contrib, t)
			st.faction = st.owner
		else
			st.lib = 100
		end
	end
	for _, op in Campaign.Operations do
		local st = out[op.planet]
		if st and War.opStatus(op, outcomes, t) == "active" then
			st.op = op.id
			if op.kind == "defend" then
				st.defense = War.opProgress(op, contrib, t)
				st.faction = op.faction
			end
		end
	end
	for _, st in out do
		st.playable = not st.destroyed and st.faction ~= nil
	end
	return out
end

-- Server-only helper: decisions that should be written permanently now.
-- Returns list of {key, value, op?}.
function War.pendingOutcomes(contrib, outcomes, t): { { key: string, value: string, op: any? } }
	local list = {}
	for _, op in Campaign.Operations do
		local s = War.opStatus(op, outcomes, t)
		if s == "active" and War.opProgress(op, contrib, t) >= 100 then
			table.insert(list, { key = op.id, value = "success", op = op })
		elseif s == "expired" then
			-- a liberate op whose planet was already freed by free play counts as won, never as failed
			local won = op.kind == "liberate" and outcomes["L_" .. op.planet] == "liberated"
			table.insert(list, { key = op.id, value = if won then "success" else "fail", op = op })
		end
	end
	-- free-play liberations (no deadline)
	local state = War.compute(contrib, outcomes, t)
	for id, st in state do
		if st.owner ~= "FREE" and not st.destroyed and st.lib >= 100 and not outcomes["L_" .. id] then
			local covered = false
			for _, op in list do
				if op.op and op.op.planet == id then
					covered = true
				end
			end
			if not covered then
				table.insert(list, { key = "L_" .. id, value = "liberated" })
			end
		end
	end
	return list
end

-- The number the map shows for a planet: defence % under attack, liberation % if enemy-held, 100 if free.
function War.display(st: PlanetState?): number
	if not st or st.destroyed then
		return 0
	end
	if st.defense then
		return st.defense
	end
	if st.owner ~= "FREE" then
		return st.lib
	end
	return 100
end

-- Enemy pressure on a planet right now: % per hour clawed back by its active operation (0 = none).
function War.pressure(planetId: string, outcomes, t): number
	for _, op in Campaign.Operations do
		if op.planet == planetId and War.opStatus(op, outcomes, t) == "active" then
			return op.resist
		end
	end
	return 0
end

-- Mission gain for one successful mission.
function War.missionGain(planetId: string, difficulty: number): number
	local p = Planets.get(planetId)
	return (p and p.gain or 0.5) * (0.8 + 0.1 * math.clamp(difficulty, 1, 5))
end

return War
