-- Active AA batteries (side objective AIRDEF, server/Objectives/SideAirDefence.luau). While one is up, the Director's COG
-- dropship deliveries within its range are shot down in the air: the carrier explodes (client EnemyFx "DropShip" with
-- `kill` / `aa`) and the squad it carried never lands. Heavy drop pods are not carriers and still fall.
--   AirDefence.add(id, getPos: () -> Vector3?, range)   register (or replace) a battery; getPos returning nil = offline
--   AirDefence.remove(id) / AirDefence.clear()
--   AirDefence.intercept(at: Vector3) -> Vector3?       launcher position of a battery covering `at` (range is flat)
-- Studio A/B: workspace attribute Feel_AirDefence = "half" -> only every second dropship is shot down.
local RunService = game:GetService("RunService")

local AirDefence = {}

type Entry = { getPos: () -> Vector3?, range: number }
local entries: { [string]: Entry } = {}
local calls = 0

function AirDefence.add(id: string, getPos: () -> Vector3?, range: number)
	entries[id] = { getPos = getPos, range = range }
end

function AirDefence.remove(id: string)
	entries[id] = nil
end

function AirDefence.clear()
	table.clear(entries)
	calls = 0
end

function AirDefence.intercept(at: Vector3): Vector3?
	local best: Vector3? = nil
	local bd = math.huge
	for id, e in entries do
		local ok, p = pcall(e.getPos)
		if not ok then
			entries[id] = nil
			continue
		end
		if p then
			local d = Vector3.new(p.X - at.X, 0, p.Z - at.Z).Magnitude
			if d <= e.range and d < bd then
				bd = d
				best = p
			end
		end
	end
	if not best then
		return nil
	end
	calls += 1
	if RunService:IsStudio() and workspace:GetAttribute("Feel_AirDefence") == "half" and calls % 2 == 0 then
		return nil
	end
	return best
end

return AirDefence
