-- S.Jammers: areas where the uplink is blocked. A player standing inside any jammer's radius can't arm a call-in or
-- throw a beacon (server/CallIns/CallInService asks isJammed).
--   S.Jammers.add(id, getPos: () -> Vector3?, radius)   register (or replace) a jammer; getPos returning nil = switched off
--   S.Jammers.remove(id)
--   S.Jammers.isJammed(pos) -> boolean
--   S.Jammers.list() -> { { id, pos, radius } }          live jammers (for markers / tests)
--   S.Jammers.clear()                                     drop everything (mission end)
-- Users: server/Objectives/SideJammer (the jammer site), the convoy jammer walker.

local Jammers = {}

type Entry = { getPos: () -> Vector3?, radius: number }
local entries: { [string]: Entry } = {}

function Jammers.add(id: string, getPos: () -> Vector3?, radius: number)
	entries[id] = { getPos = getPos, radius = radius }
end

function Jammers.remove(id: string)
	entries[id] = nil
end

function Jammers.clear()
	table.clear(entries)
end

function Jammers.isJammed(pos: Vector3): boolean
	for id, e in entries do
		local ok, p = pcall(e.getPos)
		if ok and p and (p - pos).Magnitude <= e.radius then
			return true
		elseif not ok then
			entries[id] = nil -- a broken getter must not keep the uplink dead forever
		end
	end
	return false
end

function Jammers.list(): { { id: string, pos: Vector3, radius: number } }
	local out = {}
	for id, e in entries do
		local ok, p = pcall(e.getPos)
		if ok and p then
			table.insert(out, { id = id, pos = p, radius = e.radius })
		end
	end
	return out
end

return Jammers
