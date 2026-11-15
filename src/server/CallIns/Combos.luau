-- Call-in combos: overlapping call-ins that turn into something bigger. A tiny registry; effects (and the Volatile elite blast)
-- report what they leave behind, other effects ask about it.
--
--   Fire zones  Combos.addZone(kind, pos, radius, untilT)   a flat fire patch alive until os.clock() >= untilT
--               Combos.fireNear(pos, r)                      true if a live fire zone overlaps the circle (pos, r)
--               Combos.burningNear(S, pos, r)                true if an enemy with the `burn` status is within r
--
--   FIRE VORTEX (GRAVWELL + any fire): see Effects/GRAVWELL.luau.
--
-- Studio A/B group CALL-IN COMBOS (Feel_Combos = "on"). While off, addZone does nothing and every query is false.
local Combos = {}

local MAX_ZONES = 64
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
