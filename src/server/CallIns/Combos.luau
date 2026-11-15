-- Call-in combos: overlapping call-ins that turn into something bigger. A tiny registry; effects (and the Volatile elite blast)
-- report what they leave behind, other effects ask about it.
--
--   Fire zones  Combos.addZone(kind, pos, radius, untilT)   a flat fire patch alive until os.clock() >= untilT
--               Combos.fireNear(pos, r)                      true if a live fire zone overlaps the circle (pos, r)
--               Combos.burningNear(S, pos, r)                true if an enemy with the `burn` status is within r
--
--   Wells       Combos.addWell(pos, radius, untilT, handle)  a Gravity Well that is pulling until os.clock() >= untilT
--               Combos.wellNear(pos)                         the live well whose pull radius covers pos (or nil)
--               handle is the well's own table; the well loop reads the flags other effects set on it:
--                 handle.shatter  = true  (Cryo Bomb went off inside it)  -> SHATTER IMPLOSION
--                 handle.collapse = true  (a Railshot hit inside it)      -> ends the pull and bursts at once
--                 handle.ended    = true  (set by the well itself when it is over)
--
--   FIRE VORTEX (GRAVWELL + any fire): see Effects/GRAVWELL.luau.
--   SHATTER IMPLOSION (GRAVWELL + Cryo): see Effects/GRAVWELL.luau, flagged from Effects/CRYO.luau.
--   RAIL OVERCHARGE (RAILSHOT into a GRAVWELL): see Effects/RAILSHOT.luau.
--
-- Studio A/B group CALL-IN COMBOS (Feel_Combos = "on"). While off, addZone / addWell do nothing and every query is false / nil.
local Combos = {}

export type WellHandle = { ended: boolean?, shatter: boolean?, collapse: boolean? }
type Well = { pos: Vector3, radius: number, untilT: number, handle: WellHandle }

local MAX_ZONES = 64
local MAX_WELLS = 16
local wells: { Well } = {}
local zones: { { kind: string, pos: Vector3, radius: number, untilT: number } } = {}

function Combos.enabled(): boolean
	return workspace:GetAttribute("Feel_Combos") == "on"
end

local function prune(t: number)
	for i = #zones, 1, -1 do
		if zones[i].untilT <= t then
			table.remove(zones, i)
		end
	end
end

-- untilT is an os.clock() time
function Combos.addZone(kind: string, pos: Vector3, radius: number, untilT: number)
	if not Combos.enabled() then
		return
	end
	local t = os.clock()
	if #zones >= MAX_ZONES then
		prune(t)
		if #zones >= MAX_ZONES then
			table.remove(zones, 1)
		end
	end
	table.insert(zones, { kind = kind, pos = pos, radius = radius, untilT = untilT })
end

function Combos.fireNear(pos: Vector3, r: number): boolean
	if #zones == 0 then
		return false
	end
	local t = os.clock()
	prune(t)
	for _, z in zones do
		local dx, dz = z.pos.X - pos.X, z.pos.Z - pos.Z
		local reach = z.radius + r
		if dx * dx + dz * dz <= reach * reach then
			return true
		end
	end
	return false
end

local function pruneWells(t: number)
	for i = #wells, 1, -1 do
		local w = wells[i]
		if w.untilT <= t or w.handle.ended or w.handle.collapse then
			table.remove(wells, i)
		end
	end
end

function Combos.addWell(pos: Vector3, radius: number, untilT: number, handle: WellHandle)
	if not Combos.enabled() then
		return
	end
	pruneWells(os.clock())
	if #wells >= MAX_WELLS then
		table.remove(wells, 1)
	end
	table.insert(wells, { pos = pos, radius = radius, untilT = untilT, handle = handle })
end

-- the nearest live well whose pull radius (flat) covers pos; nil when none (or while the combos are off)
function Combos.wellNear(pos: Vector3): Well?
	if #wells == 0 then
		return nil
	end
	pruneWells(os.clock())
	local best: Well? = nil
	local bestD = math.huge
	for _, w in wells do
		local dx, dz = w.pos.X - pos.X, w.pos.Z - pos.Z
		local d2 = dx * dx + dz * dz
		if d2 <= w.radius * w.radius and d2 < bestD then
			best, bestD = w, d2
		end
	end
	return best
end

function Combos.burningNear(S: any, pos: Vector3, r: number): boolean
	local t = workspace:GetServerTimeNow()
	for _, e in S.Enemies.getInRadius(pos, r) do
		local burn = e.alive and e.status and e.status.burn
		if burn and burn.untilT > t then
			return true
		end
	end
	return false
end

return Combos
