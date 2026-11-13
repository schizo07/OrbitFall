--!strict
-- Armour penetration rules (docs/spec.md §5). Pure functions, used by server and client prediction.

local Damage = {}

Damage.PARTIAL = 0.6

export type Result = "pen" | "partial" | "deflect"

-- Returns (damage, result)
function Damage.compute(dmg: number, ap: number, armor: number, mult: number?): (number, Result)
	local m = mult or 1
	if ap >= 6 or ap > armor then
		return dmg * m, "pen"
	elseif ap == armor then
		return dmg * m * Damage.PARTIAL, "partial"
	else
		return 0, "deflect"
	end
end

-- Explosion falloff: full damage inside core, linear down to 25 % at radius, 0 outside.
function Damage.falloff(dist: number, core: number, radius: number): number
	if dist <= core then
		return 1
	end
	if dist >= radius then
		return 0
	end
	return 1 - 0.75 * (dist - core) / math.max(radius - core, 0.001)
end

return Damage
