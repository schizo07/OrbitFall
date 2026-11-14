--!strict
-- Explosion tuning (footage pass, 2026-11-14). One row per explosive source.
--
-- Gameplay fields override the base numbers that live elsewhere:
--   call-ins  -> Data/CallIns.luau `params` (BARRAGE uses `blast` as its radius)
--   weapons   -> Data/Weapons.luau `splash`
-- so those files keep their original values; Blasts.merge(id, base) returns base with this row applied.
--
-- Fields
--   radius, core   gameplay blast (studs), read by Damage.falloff through EnemyService.explode
--   knock          launch speed (studs/s) given to a trooper at the centre; 0 = never knocks troopers
--                  (server/Explosions.luau: knock falls to KnockEdge * knock at radius * KnockRadiusMult)
--   vis            size of the shared client effect (client/Fx/Blast.luau); 1 = a frag grenade
--   power          reported to explosion listeners (S.Explosions.onBlast), defaults to knock
--   shake          camera shake multiplier for this source (default 1)

local Blasts = {}

-- player knockdown
Blasts.KnockRadiusMult = 1.35 -- troopers are knocked out to radius * this (damage still stops at radius)
Blasts.KnockEdge = 0.35 -- share of `knock` left at the knock edge
Blasts.KnockLift = 0.45 -- vertical share of the launch
Blasts.DownTimeMin = 0.9 -- seconds on the ground for a knock right at the threshold
Blasts.DownTimeMax = 1.8 -- seconds on the ground for the strongest knocks (Half-Ton centre)
Blasts.DownTimeAt = 130 -- launch speed that gives DownTimeMax

export type Row = {
	radius: number?,
	core: number?,
	blast: number?,
	knock: number?,
	vis: number?,
	power: number?,
	shake: number?,
	shakeRadius: number?,
}

-- old values in the trailing comments
Blasts.byId = {
	-- grenades / weapons (Data/Weapons.luau splash)
	FRAG = { radius = 10, core = 4, knock = 75, vis = 1.15 }, -- radius 7, core 2.5
	IMPACT = { radius = 9, core = 3.5, knock = 70, vis = 1.05 }, -- radius 6, core 2
	ROCKET = { radius = 8, core = 3, knock = 65, vis = 0.95 }, -- radius 6, core 2
	BP2 = { radius = 3.5, core = 1.2, knock = 0, vis = 0.35, shake = 0.4 }, -- radius 3, core 1
	-- call-ins (Data/CallIns.luau params)
	HALFTON = { radius = 26, core = 11, knock = 130, vis = 3.4, shakeRadius = 160, shake = 1.3 }, -- radius 18, core 7, shakeRadius 80
	STRAFE = { radius = 9, core = 3.5, knock = 80, vis = 1.45 }, -- radius 6, core 2
	CLUSTER = { radius = 6, core = 2, knock = 55, vis = 0.8, shake = 0.55 }, -- radius 4, core 1
	BARRAGE = { blast = 9, core = 3.5, knock = 90, vis = 1.8 }, -- blast 6, core 2
	MINES = { radius = 6, core = 2, knock = 65, vis = 1.05 }, -- radius 5, core 1.5
} :: { [string]: Row }

-- Returns a copy of `base` with the row for `id` applied (base untouched). Unknown id -> plain copy.
function Blasts.merge(id: string, base: { [string]: any }?): { [string]: any }
	local out: { [string]: any } = {}
	for k, v in base or {} do
		out[k] = v
	end
	local row = Blasts.byId[id]
	if row then
		for k, v in row :: any do
			out[k] = v
		end
	end
	return out
end

-- Seconds a trooper stays down after a launch of `speed` studs/s (>= the knockdown threshold).
function Blasts.downTime(speed: number, threshold: number): number
	local u = math.clamp((speed - threshold) / math.max(Blasts.DownTimeAt - threshold, 1), 0, 1)
	return Blasts.DownTimeMin + (Blasts.DownTimeMax - Blasts.DownTimeMin) * u
end

return Blasts
