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

-- Explosion falloff: full damage inside core, then a curve down to EDGE at radius, 0 outside.
-- 2026-11-14 (footage pass): was linear 1 -> 0.25; now 1 -> 0.45 on a u^1.5 curve, so the damage stays high for most of
-- the ring and only drops near the edge (u = 0.5 gives 0.81, was 0.625). `edge` overrides EDGE for one call.
Damage.EDGE = 0.45
Damage.CURVE = 1.5
function Damage.falloff(dist: number, core: number, radius: number, edge: number?): number
	if dist <= core then
		return 1
	end
	if dist >= radius then
		return 0
	end
	local u = (dist - core) / math.max(radius - core, 0.001)
	return 1 - (1 - (edge or Damage.EDGE)) * u ^ Damage.CURVE
end

return Damage
