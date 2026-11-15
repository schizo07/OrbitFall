-- S.Elites (loaded by EnemyService): now and then a regular or medium enemy spawns as an ELITE with one readable affix.
-- A little tougher, outlined in the affix colour with a small icon over its head (client/Fx/EnemyFx.luau, keyed off the model
-- attribute `Elite`), and killing it pays a small bonus: +1 grenade and +1 stim for the killer only. Rare spice that rewards
-- focus fire, not a difficulty spike.
--
--   Affixes
--     PLATED    body armour +1 tier (cap 4), HP x 1.5. Weak spots keep their armour, so aiming still pays.
--     VOLATILE  blows 1 s after it dies (red warning ring): radius 6, hurts troopers like an enemy mortar shell and other enemies too.
--     SWIFT     move speed x 1.4, attack cooldowns x 0.75, HP x 0.9.
--
--   Rules (random rolls): eligible = class regular / medium, not fodder, not static, not a loot runner; at most MAX_ALIVE elites
--   alive; none in the first MIN_MISSION_TIME s of a real mission (the Studio arena has no such wait).
--
--   Studio A/B workspace attribute Feel_Elites (Variants group "ELITES", mirrored by the "studioFeel" action):
--     nil / anything else  off
--     "on"                 6 % of eligible spawns
--     "fast"               40 % of eligible spawns (testing)
--
--   Stat changes live on the enemy instance only (e.hp / e.maxHp, e.armorBonus, e.speedMul, e.cdMul), never in the shared def.
--   EnemyService reads e.armorBonus (body zone), EnemyAI reads e.speedMul and e.cdMul.
--
--   Elites.roll(e, forced?)   called by EnemyService.spawn; forced = affix name (DebugHook "elite") skips the chance / limits
--   Elites.onDeath(e, source) called by EnemyService.kill: volatile blast + killer bonus
--   Elites.AFFIXES            list of affix names

local Elites = {}
local S: any = nil

local rng = Random.new()

-- tuning
local CHANCE = { on = 0.06, fast = 0.4 }
local MAX_ALIVE = 3
local MIN_MISSION_TIME = 60 -- s
local PLATED_HP, PLATED_ARMOR_CAP = 1.5, 4
local SWIFT_HP, SWIFT_SPEED, SWIFT_CD = 0.9, 1.4, 0.75
local VOL_WARN, VOL_RADIUS, VOL_CORE = 1.0, 6, 2
local VOL_DAMAGE_TROOPER = 70 -- same as the COG mortar shell (Data/Enemies COLOSSUS)
local VOL_DAMAGE_ENEMY, VOL_AP = 160, 2
local VOL_KNOCK = 45
local BONUS_GRENADES, BONUS_STIMS = 1, 1

Elites.AFFIXES = { "Plated", "Volatile", "Swift" }
local VALID = { Plated = true, Volatile = true, Swift = true }

function Elites.init(s)
	S = s
end

local function chance(): number
	local v = workspace:GetAttribute("Feel_Elites")
	return if v == "on" or v == "fast" then CHANCE[v] else 0
end

local function missionLive(): boolean
	local st = S and S.Mission and S.Mission.state
	return st == "Active" or st == "Extract"
end

local function aliveElites(): number
	local n = 0
	if S and S.Enemies then
		for _, e in S.Enemies.getAll() do
			if e.elite and e.alive then
				n += 1
			end
		end
	end
	return n
end

local function eligible(e: any): boolean
	local def = e.def
	return (e.class == "regular" or e.class == "medium") and not e.fodder and not def.static and not def.loot and def.behavior ~= "flee"
end

local function randomOk(e: any): boolean
	local p = chance()
	if p <= 0 or not eligible(e) or not missionLive() then
		return false
	end
	local m = S.Mission
	if not m.arena and os.clock() - (m.activeAt or 0) < MIN_MISSION_TIME then
		return false
	end
	if aliveElites() >= MAX_ALIVE then
		return false
	end
	return rng:NextNumber() < p
end

function Elites.roll(e: any, forced: string?)
	local affix: string
	if forced then
		if not VALID[forced] then
			return
		end
		affix = forced
	elseif randomOk(e) then
		affix = Elites.AFFIXES[rng:NextInteger(1, #Elites.AFFIXES)]
	else
		return
	end
	e.elite = affix
	if affix == "Plated" then
		e.armorBonus = 1
		e.armorCap = PLATED_ARMOR_CAP
		e.hp *= PLATED_HP
		e.maxHp *= PLATED_HP
	elseif affix == "Swift" then
		e.speedMul = SWIFT_SPEED
		e.cdMul = SWIFT_CD
		e.hp *= SWIFT_HP
		e.maxHp *= SWIFT_HP
	end
	e.model:SetAttribute("Elite", affix) -- set before the model is parented: clients see it on ChildAdded
end

-- VOLATILE: warning ring now, blast VOL_WARN s later (no mission check at the end of the delay beyond "still live")
local function volatileBlast(pos: Vector3)
	S.Fx.play("Telegraph", { shape = "circle", p = pos + Vector3.new(0, 0.15, 0), r = VOL_RADIUS, t = VOL_WARN })
	task.delay(VOL_WARN, function()
		if not missionLive() then
			return
		end
		for _, p in S.Players.getAlive() do
			local root = S.Players.getRoot(p)
			if root then
				local d = (root.Position - pos).Magnitude
				if d < VOL_RADIUS + 1.2 then
					local f = S.Explosions.playerFalloff(math.max(d - 1.2, 0), VOL_CORE, VOL_RADIUS)
					if f > 0 then
						S.Players.damage(p, VOL_DAMAGE_TROOPER * f, pos, { kind = "mortar" })
					end
				end
			end
		end
		S.Explosions.blast(pos, {
			radius = VOL_RADIUS,
			core = VOL_CORE,
			damage = VOL_DAMAGE_ENEMY,
			ap = VOL_AP,
			size = "M",
			style = "fire",
			knock = VOL_KNOCK,
		}, { kind = "elite" })
	end)
end

function Elites.onDeath(e: any, source: any?)
	local affix = e.elite
	if not affix then
		return
	end
	if affix == "Volatile" then
		volatileBlast(e.pos or e.root.Position)
	end
	local killer = (source and source.player) or e.lastHitBy
	if killer and typeof(killer) == "Instance" and killer:IsA("Player") and killer.Parent and S.Players.isAlive(killer) then
		S.Players.topUp(killer, BONUS_GRENADES, BONUS_STIMS)
	end
end

return Elites
