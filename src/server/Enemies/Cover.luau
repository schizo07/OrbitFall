-- Cover points for ranged enemies (used by Tactician). Plain module, not a service.
--
--   Cover.init(S)
--   Cover.query(center, targetPos, now) -> { Cand }   candidates around `center` hidden from `targetPos`; cached per
--                                                      (center cell, target cell) for CACHE_T seconds, so a squad shares one scan
--   Cover.taken(pos, e) -> boolean                    another living enemy has claimed a point within CLAIM_R studs
--   Cover.claim(e, pos) / Cover.release(e)
--   Cover.hidden(pos, targetPos) -> boolean           one raycast: is a body standing at `pos` blocked from targetPos at chest height
--   Cover.sees(pos, targetPos) -> boolean             one raycast: is there a clean line of fire from `pos` to `targetPos`
--   Cover.probe(e, dir, len) -> boolean               one raycast: true = a wall / steep slope within `len` studs along `dir`
--   Cover.crowdPenalty(pos, e, radius?) -> number     proximity penalty against already-claimed friendly cover
--   Cover.angularPenalty(pos, targetPos, e, role?) -> number   firing-arc spacing penalty / flank angular separation
--
-- Cand = { pos: Vector3 (ground), peek: Vector3 (ground, 2-4 studs sideways, has a line of sight to the target) }
--
-- How a scan works: collidable parts near `center` (rocks, crates, walls, wrecks; flat ground pieces and huge parts skipped) give a
-- point just behind each one as seen from the target; a ring of points around the center adds terrain cover (hills, crater rims).
-- A point counts when its chest is blocked from the target and a peek spot 2-4 studs to either side is not. Cost per scan: one
-- part query, one small overlap per candidate, at most 3 raycasts per candidate, MAX_CANDS candidates.

local Players = game:GetService("Players")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Config)

local Cover = {}

export type Cand = { pos: Vector3, peek: Vector3 }

local S: { [string]: any } = {}
local MAP_HALF = Config.MapSize / 2 - 6

local SCAN_R = 36 -- studs around the center searched for cover parts
local MAX_CANDS = 12
local RING_R = 13 -- terrain ring sample radius
local CACHE_T = 1.5
local CELL = 16 -- center cell (studs)
local TCELL = 12 -- target cell (studs)
local CHEST = 2.6 -- studs above the ground a body is checked at
local PEEK = { 3, 4 } -- studs sideways tried for the peek spot
local BEHIND = 2.6 -- studs between a cover part's face and the point
local CLAIM_R = 4

local envParams = RaycastParams.new() -- world only (no enemies, no characters)
envParams.FilterType = Enum.RaycastFilterType.Exclude
envParams.RespectCanCollide = true
envParams.IgnoreWater = true

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.RespectCanCollide = true
overlap.MaxParts = 40

local clearOverlap = OverlapParams.new()
clearOverlap.FilterType = Enum.RaycastFilterType.Exclude
clearOverlap.RespectCanCollide = true
clearOverlap.MaxParts = 1

local lastFilter = 0
local function refreshFilter()
	local c = os.clock()
	if c - lastFilter < 1 then
		return
	end
	lastFilter = c
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
	overlap.FilterDescendantsInstances = list
	clearOverlap.FilterDescendantsInstances = list
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function groundY(x: number, z: number, refY: number): number
	local map = S.Map and S.Map.current
	if map and type(map.groundY) == "function" then
		local ok, y = pcall(map.groundY, x, z)
		if ok and type(y) == "number" then
			-- props / pads can sit above the noise height; never put a point far below the asker
			return math.max(y, refY - 6)
		end
	end
	return refY
end

local function inMap(p: Vector3): boolean
	return math.abs(p.X) <= MAP_HALF and math.abs(p.Z) <= MAP_HALF
end

local function chest(p: Vector3): Vector3
	return p + Vector3.new(0, CHEST, 0)
end

local function clearAt(p: Vector3): boolean
	return #workspace:GetPartBoundsInRadius(chest(p), 1.2, clearOverlap) == 0
end

function Cover.hidden(pos: Vector3, targetPos: Vector3): boolean
	refreshFilter()
	local c = chest(pos)
	return workspace:Raycast(targetPos, c - targetPos, envParams) ~= nil
end

local function sees(pos: Vector3, targetPos: Vector3): boolean
	local c = chest(pos)
	return workspace:Raycast(c, targetPos - c, envParams) == nil
end

function Cover.sees(pos: Vector3, targetPos: Vector3): boolean
	refreshFilter()
	return sees(pos, targetPos)
end

function Cover.probe(e: any, dir: Vector3, len: number): boolean
	refreshFilter()
	local h = math.min(e.def.size, 3) + 0.5
	local r = workspace:Raycast(e.pos + Vector3.new(0, h, 0), dir * (len + e.def.size * 0.6), envParams)
	return r ~= nil and math.abs(r.Normal.Y) < 0.65
end

-- Claims -----------------------------------------------------------------------------------------
local claims: { [any]: Vector3 } = {}

function Cover.claim(e: any, pos: Vector3)
	claims[e] = pos
end

function Cover.release(e: any)
	claims[e] = nil
end

function Cover.taken(pos: Vector3, e: any): boolean
	for o, p in claims do
		if o ~= e then
			if not o.alive then
				claims[o] = nil
			elseif flat(p - pos).Magnitude < CLAIM_R then
				return true
			end
		end
	end
	return false
end

-- Penalize clustering too close to friendly claimed cover so squads spread across distinct cover points.
function Cover.crowdPenalty(pos: Vector3, e: any, radius: number?): number
	local r = radius or 15
	local pen = 0
	for o, p in claims do
		if o ~= e then
			if not o.alive then
				claims[o] = nil
			elseif o.faction == e.faction then
				local d = flat(p - pos).Magnitude
				if d < r then
					pen += (1 - d / r) * 32
				end
			end
		end
	end
	return pen
end

-- Reward wide angular separation for flankers relative to suppressors, and lightly fan out suppressors.
function Cover.angularPenalty(pos: Vector3, targetPos: Vector3, e: any, role: string?): number
	local v = flat(pos - targetPos)
	if v.Magnitude < 1 then
		return 0
	end
	local u = v.Unit
	local pen = 0
	for o, p in claims do
		if o ~= e and o.alive and o.faction == e.faction then
			local ov = flat(p - targetPos)
			if ov.Magnitude >= 1 then
				local dot = u:Dot(ov.Unit)
				local oRole = o.tc and o.tc.role
				if role == "flanker" then
					if oRole == "flanker" then
						-- Two flankers split onto opposite sides when possible
						if dot > 0.7 then
							pen += (dot - 0.7) * 70
						end
					else
						-- Flankers strongly prefer cover laterally separated (65-110 deg) from suppressors
						if dot > 0.75 then
							pen += (dot - 0.75) * 90
						elseif dot >= -0.35 and dot <= 0.45 then
							pen -= 10
						end
					end
				elseif role == "suppress" and oRole == "suppress" then
					-- Suppressors fan out across an arc instead of stacking on one bearing
					if dot > 0.94 then
						pen += (dot - 0.94) * 160
					end
				end
			end
		end
	end
	return pen
end

-- Scan -------------------------------------------------------------------------------------------
type Entry = { at: number, cands: { Cand } }
local cache: { [string]: Entry } = {}
local cacheN = 0

-- A candidate at `p` (ground): needs room to stand, cover from the target, and an unobstructed peek spot with line of fire.
local function test(p: Vector3, targetPos: Vector3, out: { Cand })
	if not inMap(p) or not clearAt(p) then
		return
	end
	if not Cover.hidden(p, targetPos) then
		return
	end
	local toT = flat(targetPos - p)
	if toT.Magnitude < 1 then
		return
	end
	toT = toT.Unit
	local side = Vector3.new(-toT.Z, 0, toT.X)
	local pc = chest(p)
	for _, sgn in { 1, -1 } do
		for _, d in PEEK do
			local q = p + side * (sgn * d)
			q = Vector3.new(q.X, groundY(q.X, q.Z, p.Y), q.Z)
			if inMap(q) and clearAt(q) and sees(q, targetPos) then
				local qc = chest(q)
				if workspace:Raycast(pc, qc - pc, envParams) == nil then
					table.insert(out, { pos = p, peek = q })
					return
				end
			end
		end
	end
end

local function scan(center: Vector3, targetPos: Vector3): { Cand }
	refreshFilter()
	local out: { Cand } = {}
	local seeds: { Vector3 } = {}
	local parts = workspace:GetPartBoundsInRadius(center, SCAN_R, overlap)
	-- nearest first
	local scored: { { p: BasePart, d: number } } = {}
	for _, part in parts do
		local sz = part.Size
		local foot = math.max(sz.X, sz.Z)
		if sz.Y >= 3 and foot >= 2.5 and foot <= 60 and part.Transparency < 0.9 then
			local top = part.Position.Y + sz.Y * 0.5
			local gy = groundY(part.Position.X, part.Position.Z, center.Y)
			if top >= gy + CHEST + 0.6 then
				table.insert(scored, { p = part, d = flat(part.Position - center).Magnitude })
			end
		end
	end
	table.sort(scored, function(a, b)
		return a.d < b.d
	end)
	for i = 1, math.min(#scored, MAX_CANDS - 4) do
		local part = scored[i].p
		local away = flat(part.Position - targetPos)
		if away.Magnitude > 0.5 then
			away = away.Unit
			local sz = part.Size
			local r = math.min(math.max(sz.X, sz.Z) * 0.5, 14)
			local q = part.Position + away * (r + BEHIND)
			table.insert(seeds, Vector3.new(q.X, groundY(q.X, q.Z, center.Y), q.Z))
		end
	end
	-- terrain ring (hills and crater rims block a line of sight too)
	local ringN = math.max(4, MAX_CANDS - #seeds)
	local a0 = math.random() * math.pi * 2
	for i = 1, ringN do
		local a = a0 + (i / ringN) * math.pi * 2
		local q = center + Vector3.new(math.cos(a), 0, math.sin(a)) * RING_R
		table.insert(seeds, Vector3.new(q.X, groundY(q.X, q.Z, center.Y), q.Z))
	end
	for _, p in seeds do
		test(p, targetPos, out)
	end
	return out
end

function Cover.query(center: Vector3, targetPos: Vector3, now: number): { Cand }
	local key = string.format(
		"%d:%d:%d:%d",
		math.floor(center.X / CELL),
		math.floor(center.Z / CELL),
		math.floor(targetPos.X / TCELL),
		math.floor(targetPos.Z / TCELL)
	)
	local hit = cache[key]
	if hit and now - hit.at < CACHE_T then
		return hit.cands
	end
	if not hit then
		cacheN += 1
		if cacheN > 96 then
			for k, v in cache do
				if now - v.at >= CACHE_T then
					cache[k] = nil
					cacheN -= 1
				end
			end
		end
	end
	local cands = scan(center, targetPos)
	cache[key] = { at = now, cands = cands }
	return cands
end

function Cover.clear()
	table.clear(cache)
	table.clear(claims)
	cacheN = 0
end

function Cover.init(s: { [string]: any })
	S = s
end

return Cover
