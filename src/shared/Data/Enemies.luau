-- Enemy roster (docs/spec.md §6). Every hit-able part of an enemy model carries
-- attributes EnemyId (number) and Zone (string = a key of `zones`).
-- Zone "body" is mandatory and its armour is the "body armour" used by explosions.
-- fatal = zone HP; when it reaches 0 the enemy dies instantly.

-- PACE TUNING (playtest: "enemies need to move a bit slower, especially COG"). Faction multipliers on walk / run speed
-- (Enemy.speed) and on the "charge" dash speed. Applied once to the roster below, so the fodder tier and the limb-loss speed
-- penalty (server/Enemies/Dismember.luau) inherit them. LUMEN is untouched. Retune here.
local Config = require(script.Parent.Parent.Config)
local COG_SPEED_MULT = 0.8 -- robots: -20 %
local BROOD_SPEED_MULT = 0.9 -- bugs: -10 %

export type Zone = { armor: number, mult: number, fatal: number?, blocks: boolean? }
export type Attack = {
	kind: string, -- "bolt" | "burst" | "cannon" | "mortar" | "sweep" | "melee" | "bite" | "leap" | "spit" | "charge" | "stomp" | "summon"
	--              LUMEN (server/Enemies/LumenAI.luau): "needle" | "beam" | "pulse" | "rift"
	damage: number,
	range: number,
	cooldown: number,
	speed: number?, -- projectile speed
	count: number?,
	radius: number?,
	windup: number?, -- telegraph time
	interval: number?, -- "needle": seconds between shots of a volley
	spread: number?, -- "needle": cone (degrees) of a volley
	unit: string?, -- "rift": kind id that warps in
	-- ENEMY TACTICS: tactic = only used while tactics are on (Feel_EnemyTactics ~= "off"); chance = odds the attack is taken when
	-- it becomes eligible (a miss waits half a cooldown); minRange = "leap": closest centre distance it jumps from
	tactic: boolean?,
	chance: number?,
	minRange: number?,
}
-- ENEMY TACTICS (server/Enemies/EnemyAI.luau). Every field optional; a unit without `tactics` behaves as before.
--   hold: { min, max } fractions of keepDistance: back off (side-stepping) below min, advance above max, side-step / plant in
--         between (missing = Tactics.holdDefault)
--   callout: radius (studs). On spotting a new target, idle squadmates of the same faction in the radius are told and move in.
--   flank: chance (0..1) per new target to first walk to a point flankAngle degrees off to the side of the target, then hold
--   retreatAt / retreatMul: below this hp fraction the unit holds retreatMul x further back
--   push: hold-range multiplier (< 1 = walks the squad down)
--   spread: degrees. Melee swarms bend their approach by up to this angle (fading out near the target) so they arrive from
--           several sides
--   screech: below `at` hp fraction (once): a screech that speeds up Brood regulars within `radius` by x`speed` for `dur` s
export type Tactics = {
	hold: { number }?,
	callout: number?,
	flank: number?,
	flankAngle: number?,
	retreatAt: number?,
	retreatMul: number?,
	push: number?,
	spread: number?,
	screech: { at: number, radius: number, speed: number, dur: number }?,
}
export type Enemy = {
	id: string,
	name: string,
	faction: string, -- "COG" | "BROOD" | "LUMEN"
	class: string, -- "regular" | "medium" | "heavy" | "behemoth"
	hp: number,
	speed: number,
	size: number, -- rough radius for spacing / debris scale
	zones: { [string]: Zone },
	attacks: { Attack },
	keepDistance: number?, -- ranged units try to stay at this range
	salvage: number, -- reward contribution
	xp: number,
	desc: string,
	-- LUMEN extras (server/Enemies/LumenAI.luau)
	blink: { aim: number, dist: number, cooldown: number }?, -- blink sideways after being aimed at for `aim` s
	nodes: { open: number, closed: number }?, -- resonance nodes cycle open/closed (seconds)
	-- FODDER tier (Director v2): 1-hit swarm units. They reuse a regular unit's model scaled down (modelKind / modelScale), count
	-- `cost` (< 1) towards the live cap and run a cheap AI (EnemyAI: steer only close to the target)
	fodder: boolean?,
	cost: number?,
	modelKind: string?,
	modelScale: number?,
	-- STAGED DAMAGE (footage spec §3.4.4): the server writes model attribute DmgStage 0..3 as HP drops past Enemies.Stages;
	-- client/Fx/EnemyFx.luau shows smoke / breach / fire (bugs: drips / glowing split / bubbling ooze) and a big death burst
	stages: boolean?,
	-- STATIC emplacement (Bastion): never moves, turns at `turn` rad/s, never calls reinforcements, ignores blast knockback,
	-- not counted in the live cap (cost 0) nor as a "heavy" in countByClass (counted as "static")
	static: boolean?,
	turn: number?,
	wreck: boolean?, -- leaves a wreck model for ~60 s (server/Enemies/Wrecks.luau)
	-- ENEMY AIM (bolt / burst shooters, server/Enemies/EnemyAI.luau shootBolt). Cone half-angles in degrees. Missing = Enemies.AimDefault.
	aim: Aim?,
	-- FLYING DRONE (Drone Foundry side objective): moved and fired by server/Enemies/DroneAI.luau instead of EnemyAI; the model is
	-- built there too. hover = height band above the ground (studs).
	drone: { hover: { number } }?,
	-- LOOT RUNNER (server/Enemies/LootRunner.luau): behavior "flee" = EnemyAI runs from the nearest trooper and never attacks;
	-- loot = a kill bursts into a resupply (LootRunner) and the Director leaves it alone
	behavior: string?,
	loot: boolean?,
	tactics: Tactics?, -- ENEMY TACTICS (see the Tactics type above)
}
-- base: spread when the target is first acquired (or comes back out of cover); min: spread after `tighten` s of steady aim.
-- rangeMul: extra spread per Enemies.Aim.rangeRef studs beyond Enemies.Aim.rangeFrom; moveMul: extra spread for a target
-- moving at walk speed (more when sprinting, see Enemies.Aim.sprintBonus); warnShots: first shots after spotting a target
-- deliberately fly past it (near-miss tracers).
export type Aim = { base: number, min: number, tighten: number, rangeMul: number, moveMul: number, warnShots: number }

local E: { [string]: Enemy } = {
	-- THE COGWORK LEGION ------------------------------------------------------------
	TINKER = {
		id = "TINKER", name = "Tinker Drone", faction = "COG", class = "regular",
		hp = 120, speed = 13, size = 2,
		zones = {
			body = { armor = 1, mult = 1 },
			eye = { armor = 0, mult = 2, fatal = 40 },
		},
		attacks = { { kind = "bolt", damage = 17, range = 70, cooldown = 0.85, speed = 110 } },
		aim = { base = 9, min = 2.2, tighten = 2.5, rangeMul = 0.5, moveMul = 0.6, warnShots = 2 },
		keepDistance = 30, salvage = 2, xp = 2,
		desc = "Cheap biped bot. Eye pops with one good shot.",
		tactics = { hold = { 0.75, 1.05 }, callout = 60, flank = 0.3, flankAngle = 70 },
	},
	RIVET = {
		id = "RIVET", name = "Rivet Trooper", faction = "COG", class = "medium",
		hp = 440, speed = 11, size = 2.6,
		zones = {
			body = { armor = 2, mult = 1 },
			eye = { armor = 1, mult = 2.5, fatal = 130 },
			pack = { armor = 1, mult = 2 },
			shield = { armor = 3, mult = 0, blocks = true },
		},
		attacks = { { kind = "burst", damage = 28, range = 80, cooldown = 2.2, speed = 120, count = 3 } },
		aim = { base = 7, min = 1.8, tighten = 2.0, rangeMul = 0.4, moveMul = 0.5, warnShots = 2 },
		keepDistance = 35, salvage = 6, xp = 6,
		desc = "Front riot shield. Flank it or shoot the eye over the rim.",
		wreck = true,
		tactics = { hold = { 0.7, 1.05 }, callout = 70, flank = 0.15, flankAngle = 60, retreatAt = 0.45, retreatMul = 1.35 },
	},
	BULWARK = {
		id = "BULWARK", name = "Bulwark", faction = "COG", class = "heavy",
		hp = 900, speed = 7, size = 5,
		zones = {
			body = { armor = 4, mult = 1 },
			eye = { armor = 1, mult = 3, fatal = 200 },
			vent = { armor = 2, mult = 2 },
			arm = { armor = 4, mult = 0.5, blocks = true },
		},
		attacks = { { kind = "cannon", damage = 60, range = 90, cooldown = 3.0, speed = 90, radius = 5, windup = 0.6 } },
		keepDistance = 30, salvage = 20, xp = 20,
		desc = "Armoured tank-bot. A rocket in the eye turns it into scrap.",
		stages = true, wreck = true,
		tactics = { hold = { 0.5, 0.95 }, push = 0.6, callout = 80 },
	},
	-- Fortified gun block (footage spec §3.3 turret siege): never moves, two red cannon eyes flare 0.8 s before each slow heavy
	-- shot at a trooper in line of sight. Body armour 5: support weapons, explosives or call-ins. Rear heat vent is the soft spot.
	-- Placed 1-3 per COG mission at outposts by the Director (Director.placeBastions).
	BASTION = {
		id = "BASTION", name = "Bastion Emplacement", faction = "COG", class = "heavy",
		hp = 2600, speed = 0, size = 5.5,
		zones = {
			body = { armor = 5, mult = 1 },
			eye = { armor = 3, mult = 1.5 }, -- Medium weak spot (matches other tank enemies); rear vent stays Light
			vent = { armor = 1, mult = 2.5 }, -- armour 1: a Light-AP (AP 2) weapon fully pens it, so flanking pays off
		},
		attacks = { { kind = "cannon", damage = 65, range = 120, cooldown = 3.4, speed = 80, radius = 6, windup = 0.8 } },
		keepDistance = 120, salvage = 30, xp = 30,
		desc = "Fortified gun block. Bring anti-armour or a call-in, or flank it and hit the heat vent on its back.",
		stages = true, wreck = true, static = true, turn = 0.75, cost = 0,
	},
	COLOSSUS = {
		id = "COLOSSUS", name = "Strider Colossus", faction = "COG", class = "behemoth",
		hp = 4500, speed = 5, size = 12,
		zones = {
			body = { armor = 5, mult = 1 },
			eye = { armor = 3, mult = 3, fatal = 900 },
			leg = { armor = 3, mult = 1.5 },
			sink = { armor = 2, mult = 2 },
		},
		attacks = {
			{ kind = "mortar", damage = 70, range = 160, cooldown = 6, radius = 7, count = 4, windup = 1.2 },
			{ kind = "sweep", damage = 50, range = 70, cooldown = 9, windup = 1.4 },
			{ kind = "stomp", damage = 60, range = 14, cooldown = 4, radius = 12, windup = 0.8 },
		},
		keepDistance = 40, salvage = 80, xp = 80,
		desc = "Giant walker. Cockpit eye, leg joints and back heat sinks are soft.",
		stages = true, wreck = true,
	},

	-- THE SKITTER BROOD -------------------------------------------------------------
	SKITTER = {
		id = "SKITTER", name = "Skitterling", faction = "BROOD", class = "regular",
		hp = 85, speed = 20, size = 1.6,
		zones = {
			body = { armor = 0, mult = 1 },
			head = { armor = 0, mult = 1.5 },
		},
		-- ground bite (mandibles): run up, 0.3 s tell with the mandibles open, snap (~11 per s)
		attacks = { { kind = "bite", damage = 14, range = 5, cooldown = 1.2, windup = 0.3 } },
		salvage = 1, xp = 1,
		desc = "Fast little biter. Comes in packs.",
		tactics = { spread = 40 },
	},
	SPITTER = {
		id = "SPITTER", name = "Spitter", faction = "BROOD", class = "medium",
		hp = 380, speed = 12, size = 2.6,
		zones = {
			body = { armor = 1, mult = 1 },
			sac = { armor = 0, mult = 2.5, fatal = 110 },
		},
		attacks = { { kind = "spit", damage = 28, range = 60, cooldown = 2.6, speed = 60, radius = 4, windup = 0.4 } },
		keepDistance = 28, salvage = 5, xp = 5,
		desc = "Lobs acid. Pop the glowing sac.",
	},
	CHARGER = {
		id = "CHARGER", name = "Carapace Charger", faction = "BROOD", class = "heavy",
		hp = 1100, speed = 10, size = 5,
		zones = {
			body = { armor = 4, mult = 1 },
			rear = { armor = 1, mult = 2 },
			leg = { armor = 2, mult = 1.2 },
		},
		attacks = {
			{ kind = "charge", damage = 60, range = 50, cooldown = 6, speed = 42, windup = 0.9 },
			{ kind = "melee", damage = 40, range = 7, cooldown = 1.6, windup = 0.3 },
		},
		salvage = 22, xp = 22,
		desc = "Armoured front, soft rear. Dodge the charge, shoot its back.",
		stages = true, wreck = true,
		tactics = { screech = { at = 0.5, radius = 45, speed = 1.4, dur = 4 } },
	},
	TITAN = {
		id = "TITAN", name = "Hive Titan", faction = "BROOD", class = "behemoth",
		hp = 5200, speed = 6, size = 12,
		zones = {
			body = { armor = 5, mult = 1 },
			throat = { armor = 2, mult = 3, fatal = 1000 },
			belly = { armor = 3, mult = 1.5 },
		},
		attacks = {
			{ kind = "spit", damage = 45, range = 90, cooldown = 4, speed = 70, radius = 8, count = 3, windup = 1.0 },
			{ kind = "stomp", damage = 60, range = 14, cooldown = 4, radius = 12, windup = 0.8 },
			{ kind = "summon", damage = 0, range = 120, cooldown = 14, count = 5 },
		},
		salvage = 90, xp = 90,
		desc = "Towering hive beast. The glowing throat sac is the way in.",
		stages = true, wreck = true,
		tactics = { screech = { at = 0.5, radius = 60, speed = 1.4, dur = 5 } },
	},

	-- THE LUMEN CONCORD -------------------------------------------------------------
	-- Ceramic shells held together by floating light. Violet cores are the weak spots.
	-- Behaviour lives in server/Enemies/LumenAI.luau, fallback models in server/Enemies/LumenModels.luau.
	SHARDLING = {
		id = "SHARDLING", name = "Shardling", faction = "LUMEN", class = "regular",
		hp = 100, speed = 15, size = 1.8,
		zones = {
			body = { armor = 1, mult = 1 },
			core = { armor = 0, mult = 2, fatal = 35 },
		},
		attacks = { { kind = "needle", damage = 10, range = 65, cooldown = 1.1, speed = 150, count = 2, interval = 0.1, spread = 3 } },
		keepDistance = 24, salvage = 2, xp = 2,
		desc = "Floating crystal drone. Its petals open around a violet core: one clean shot pops it.",
	},
	WARDEN = {
		id = "WARDEN", name = "Lumen Warden", faction = "LUMEN", class = "medium",
		hp = 470, speed = 11, size = 2.6,
		zones = {
			body = { armor = 2, mult = 1 },
			head = { armor = 1, mult = 1.5 },
			core = { armor = 1, mult = 2.5, fatal = 140 },
			shield = { armor = 3, mult = 0, blocks = true },
		},
		attacks = { { kind = "needle", damage = 18, range = 80, cooldown = 2.2, speed = 140, count = 3, interval = 0.14, spread = 2 } },
		keepDistance = 32, salvage = 6, xp = 6,
		blink = { aim = 1.5, dist = 13, cooldown = 4 },
		desc = "Hard-light shield up front, core on its back. Blinks aside when you hold your aim on it.",
	},
	LANCER = {
		id = "LANCER", name = "Prism Lancer", faction = "LUMEN", class = "heavy",
		hp = 950, speed = 7, size = 5,
		zones = {
			body = { armor = 4, mult = 1 },
			lens = { armor = 2, mult = 3, fatal = 220 },
			core = { armor = 1, mult = 2 },
		},
		attacks = {
			{ kind = "beam", damage = 70, range = 95, cooldown = 6, windup = 1.2, radius = 2.6 },
			{ kind = "needle", damage = 12, range = 75, cooldown = 3, speed = 150, count = 4, interval = 0.12, spread = 4 },
		},
		keepDistance = 38, salvage = 20, xp = 20,
		desc = "Hovering lens-cannon. Sidestep the charged beam, then shoot the lens or the core underneath.",
	},
	SPIRE = {
		id = "SPIRE", name = "Choir Spire", faction = "LUMEN", class = "behemoth",
		hp = 4800, speed = 4, size = 11,
		zones = {
			body = { armor = 5, mult = 1 },
			node = { armor = 2, mult = 3, fatal = 950 },
		},
		attacks = {
			{ kind = "pulse", damage = 55, range = 28, cooldown = 7, radius = 28, windup = 1.6 },
			{ kind = "rift", damage = 0, range = 140, cooldown = 15, count = 4, windup = 1.4, unit = "SHARDLING" },
			{ kind = "needle", damage = 16, range = 110, cooldown = 3.8, speed = 120, count = 6, interval = 0.09, spread = 10 },
		},
		keepDistance = 26, salvage = 85, xp = 85,
		nodes = { open = 6, closed = 7 },
		desc = "Floating monolith that sings Shardlings out of a rift. Its 3 resonance nodes open between pulses.",
	},
}

for _, d in E do
	local m = if d.faction == "COG" then COG_SPEED_MULT elseif d.faction == "BROOD" then BROOD_SPEED_MULT else 1
	if m ~= 1 then
		d.speed *= m
		for _, atk in d.attacks do
			if atk.kind == "charge" and atk.speed then
				atk.speed *= m -- the dash scales with the walk speed (projectile speeds are not movement and stay)
			end
		end
	end
end

-- FODDER (swarm) tier: one per faction, built on the faction's regular unit. 1 HP (any hit kills), half cap cost, body only (every
-- zone name falls back to "body"), weak attacks. Spawned in numbers by the breach sources (server/Enemies/Director.luau).
local FODDER_SCALE = 0.8
local function fodder(baseId: string, id: string, name: string, speedMult: number, attack: Attack, keepDistance: number?): Enemy
	local b = E[baseId]
	return {
		id = id, name = name, faction = b.faction, class = "regular",
		hp = 1, speed = b.speed * speedMult, size = b.size * FODDER_SCALE,
		zones = { body = { armor = 0, mult = 1 } },
		attacks = { attack },
		keepDistance = keepDistance,
		salvage = 0, xp = 0,
		desc = "Swarm unit: dies to any hit, comes in dozens.",
		fodder = true, cost = 0.5, modelKind = baseId, modelScale = FODDER_SCALE,
	}
end
E.TINKER_SWARM = fodder("TINKER", "TINKER_SWARM", "Scrap Swarmer", 1.15,
	{ kind = "bolt", damage = 6, range = 45, cooldown = 1.4, speed = 100 }, 20)
E.TINKER_SWARM.aim = { base = 12, min = 4, tighten = 3, rangeMul = 0.6, moveMul = 0.8, warnShots = 1 }
E.SKITTER_SWARM = fodder("SKITTER", "SKITTER_SWARM", "Skitterling Swarm", 1.05,
	{ kind = "bite", damage = 8, range = 4.5, cooldown = 1.2, windup = 0.3 }, nil)
-- ENEMY TACTICS: approach from several sides, and sometimes jump the last few studs (0.4 s crouch = the tell; lands on the spot
-- the trooper was at, so stepping aside during the hop dodges it)
E.SKITTER_SWARM.tactics = { spread = 50 }
table.insert(E.SKITTER_SWARM.attacks,
	{ kind = "leap", damage = 8, range = 9, minRange = 5, cooldown = 3, windup = 0.4, chance = 0.35, tactic = true })
E.SHARDLING_SWARM = fodder("SHARDLING", "SHARDLING_SWARM", "Shard Swarmer", 1.1,
	{ kind = "needle", damage = 5, range = 50, cooldown = 1.7, speed = 140, count = 1, interval = 0.1, spread = 4 }, 18)

-- FLYING DRONES (Drone Foundry side objective, server/Objectives/SideFoundry.luau). Easy to kill, erratic, harass the nearest
-- trooper. Not in any faction roster: only the foundry launches them. Behaviour + model: server/Enemies/DroneAI.luau.
-- Light armour everywhere; `aim` = the loose cone, Studio A/B Feel_DroneAim "tight" narrows it (DroneAI).
E.DRONE_COG = {
	id = "DRONE_COG", name = "Gnat Drone", faction = "COG", class = "regular",
	hp = 40, speed = 17, size = 1.4,
	zones = {
		body = { armor = 1, mult = 1 },
		eye = { armor = 0, mult = 2, fatal = 15 },
	},
	attacks = { { kind = "bolt", damage = 6, range = 55, cooldown = 1.5, speed = 95 } },
	salvage = 1, xp = 1, cost = 0.5,
	desc = "Buzzing rotor drone from a COG foundry. Weak, twitchy, annoying.",
	drone = { hover = { 8, 14 } },
}
E.SPOREMITE = {
	id = "SPOREMITE", name = "Spore-Mite", faction = "BROOD", class = "regular",
	hp = 40, speed = 15, size = 1.4,
	zones = {
		body = { armor = 0, mult = 1 },
		sac = { armor = 0, mult = 2, fatal = 15 },
	},
	attacks = { { kind = "spit", damage = 8, range = 45, cooldown = 1.9, speed = 55, radius = 3 } },
	salvage = 1, xp = 1, cost = 0.5,
	desc = "Flying mite popped out of a spore spire. Spits small acid blobs.",
	drone = { hover = { 8, 14 } },
}

-- LOOT RUNNERS (server/Enemies/LootRunner.luau): a rare courier that runs from the squad. Never attacks (no attacks, behavior
-- "flee"), about 250 HP, light armour (1), 1.15 x trooper sprint speed. Added after the faction speed multipliers above so the
-- speed is exactly that. cost 0: not counted in the Director's live cap. Armour 1 body, the glowing crate / sac is a soft spot.
local LOOT_SPEED = Config.SprintSpeed * 1.15
E.LOOT_COG = {
	id = "LOOT_COG", name = "Scrap Courier", faction = "COG", class = "regular",
	hp = 250, speed = LOOT_SPEED, size = 2.2,
	zones = {
		body = { armor = 1, mult = 1 },
		crate = { armor = 1, mult = 1.5 },
	},
	attacks = {},
	salvage = 0, xp = 5, cost = 0,
	desc = "Small fast cart with a glowing crate. Runs from you. Catch it for a resupply.",
	behavior = "flee", loot = true,
}
E.LOOT_BROOD = {
	id = "LOOT_BROOD", name = "Gilded Grub", faction = "BROOD", class = "regular",
	hp = 250, speed = LOOT_SPEED, size = 2.2,
	zones = {
		body = { armor = 1, mult = 1 },
		sac = { armor = 1, mult = 1.5 },
	},
	attacks = {},
	salvage = 0, xp = 5, cost = 0,
	desc = "Fat shiny beetle with a glowing sac. Runs from you. Catch it for a resupply.",
	behavior = "flee", loot = true,
}

local Enemies = { byId = E }

-- STAGED DAMAGE: HP fraction below which each stage shows (stage 1 smoke / drips, 2 glowing breach + sparks, 3 fire / bubbling
-- ooze). Server: EnemyService writes model attribute DmgStage. Client: client/Fx/EnemyFx.luau.
Enemies.Stages = { 0.7, 0.4, 0.2 }

-- ENEMY AIM (server/Enemies/EnemyAI.luau). Per-unit numbers live in each def's `aim`; these are the shared rules.
--   spread = lerp(base, min, aimedFor / tighten) x range x movement x stance
--   range:    1 + rangeMul * clamp((dist - rangeFrom) / rangeRef, 0, 2)
--   movement: 1 + moveMul * clamp(speed / walk, 0, 1), x (1 + moveMul * sprintBonus) above sprintAt studs/s
--   stance:   prone / crouch multipliers
-- Losing line of sight restarts the tighten clock; out of sight for `reacquire` s also re-arms the warning shots.
-- Warning shots fly `warnOffset` studs to the side of the target and can never hit that player.
Enemies.AimDefault = { base = 8, min = 2, tighten = 2.5, rangeMul = 0.5, moveMul = 0.6, warnShots = 1 } :: Aim
Enemies.Aim = {
	rangeFrom = 20, rangeRef = 60,
	sprintAt = 19, sprintBonus = 0.6,
	prone = 1.45, crouch = 1.15,
	reacquire = 4,
	warnOffset = { 3.8, 5.5 },
	-- Studio A/B Feel_EnemyAim "harsh": spread x harshSpread, tighten time x harshTighten, one warning shot fewer
	harshSpread = 0.65, harshTighten = 0.6,
	-- Feel_EnemyAim "old": the previous fixed cones, no warning shots
	oldBolt = 2.5, oldBurst = 3,
}

-- ENEMY TACTICS shared numbers (per-unit fields: the Tactics type at the top). Studio A/B Feel_EnemyTactics (Variants "ENEMY
-- TACTICS"): "strong" multiplies flank / leap chances, approach spread and callout radius by `strong`; "off" = none of it.
Enemies.Tactics = {
	holdDefault = { 0.5, 0.95 }, -- keepDistance band when a unit has tactics but no `hold`
	step = { 0.5, 1.1 }, -- side-step: seconds moving sideways ...
	pause = { 0.4, 0.9 }, -- ... then seconds planted
	flankTime = 7, -- give up on the flank point after this many seconds
	flankReach = 8, -- studs from the flank point that count as there
	calloutCooldown = 5,
	spreadNear = 14, -- approach bend fades from full at spreadFar studs to none at spreadNear
	spreadFar = 45,
	screechWindup = 0.6, -- the big bug rears up for this long before the screech
	strong = { flank = 2, leap = 2, spread = 1.3, callout = 1.3 },
}

-- BLAST REACTIONS (EnemyService.explode -> EnemyAI.fling). power = falloff (0..1) x clamp((dmg / ref) ^ 0.5, min, max).
-- Below minPower nothing happens. dist / height in studs at power 1, dur / recover in seconds.
--   regular (incl. fodder): tumble (flung through the air, spins, lies a moment)
--   medium:  stagger (shoved back on the ground, attack interrupted)
--   heavy:   flinch (small shove, attack NOT interrupted)
--   behemoth / static: nothing
Enemies.Blast = {
	ref = 300, minMul = 0.6, maxMul = 1.6, minPower = 0.12,
	regular = { dist = 14, height = 5, dur = 0.75, recover = 0.45, spin = true, interrupt = true },
	medium = { dist = 6, height = 0.8, dur = 0.4, recover = 0.35, spin = false, interrupt = true },
	heavy = { dist = 1.4, height = 0, dur = 0.22, recover = 0, spin = false, interrupt = false },
}

Enemies.Factions = {
	COG = {
		id = "COG", name = "The Cogwork Legion", short = "Cogwork",
		color = Color3.fromHex("ff4040"),
		roster = { regular = "TINKER", medium = "RIVET", heavy = "BULWARK", behemoth = "COLOSSUS", fodder = "TINKER_SWARM" },
		deathStyle = "scrap",
	},
	BROOD = {
		id = "BROOD", name = "The Skitter Brood", short = "Brood",
		color = Color3.fromHex("8cff3a"),
		roster = { regular = "SKITTER", medium = "SPITTER", heavy = "CHARGER", behemoth = "TITAN", fodder = "SKITTER_SWARM" },
		deathStyle = "goo",
	},
	LUMEN = {
		id = "LUMEN", name = "The Lumen Concord", short = "Concord",
		color = Color3.fromHex("c060ff"),
		roster = { regular = "SHARDLING", medium = "WARDEN", heavy = "LANCER", behemoth = "SPIRE", fodder = "SHARDLING_SWARM" },
		deathStyle = "shard", -- client/Fx/LumenFx.luau: shatter into crystal shards + soft light pop
		reinforce = "rift", -- Director: rift gate warp-in (4-6 units)
	},
}

function Enemies.get(id: string): Enemy?
	return E[id]
end

return Enemies
