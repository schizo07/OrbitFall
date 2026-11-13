-- Enemy roster (docs/spec.md §6). Every hit-able part of an enemy model carries
-- attributes EnemyId (number) and Zone (string = a key of `zones`).
-- Zone "body" is mandatory and its armour is the "body armour" used by explosions.
-- fatal = zone HP; when it reaches 0 the enemy dies instantly.

export type Zone = { armor: number, mult: number, fatal: number?, blocks: boolean? }
export type Attack = {
	kind: string, -- "bolt" | "burst" | "cannon" | "mortar" | "sweep" | "melee" | "leap" | "spit" | "charge" | "stomp" | "summon"
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
}

local E: { [string]: Enemy } = {
	-- THE COGWORK LEGION ------------------------------------------------------------
	TINKER = {
		id = "TINKER", name = "Tinker Drone", faction = "COG", class = "regular",
		hp = 70, speed = 13, size = 2,
		zones = {
			body = { armor = 1, mult = 1 },
			eye = { armor = 0, mult = 2, fatal = 25 },
		},
		attacks = { { kind = "bolt", damage = 15, range = 70, cooldown = 0.85, speed = 110 } },
		keepDistance = 30, salvage = 2, xp = 2,
		desc = "Cheap biped bot. Eye pops with one good shot.",
	},
	RIVET = {
		id = "RIVET", name = "Rivet Trooper", faction = "COG", class = "medium",
		hp = 260, speed = 11, size = 2.6,
		zones = {
			body = { armor = 2, mult = 1 },
			eye = { armor = 1, mult = 2.5, fatal = 80 },
			pack = { armor = 1, mult = 2 },
			shield = { armor = 3, mult = 0, blocks = true },
		},
		attacks = { { kind = "burst", damage = 25, range = 80, cooldown = 2.2, speed = 120, count = 3 } },
		keepDistance = 35, salvage = 6, xp = 6,
		desc = "Front riot shield. Flank it or shoot the eye over the rim.",
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
	},

	-- THE SKITTER BROOD -------------------------------------------------------------
	SKITTER = {
		id = "SKITTER", name = "Skitterling", faction = "BROOD", class = "regular",
		hp = 50, speed = 20, size = 1.6,
		zones = {
			body = { armor = 0, mult = 1 },
			head = { armor = 0, mult = 1.5 },
		},
		attacks = { { kind = "leap", damage = 12, range = 9, cooldown = 1.2, windup = 0.25 } },
		salvage = 1, xp = 1,
		desc = "Fast little biter. Comes in packs.",
	},
	SPITTER = {
		id = "SPITTER", name = "Spitter", faction = "BROOD", class = "medium",
		hp = 220, speed = 12, size = 2.6,
		zones = {
			body = { armor = 1, mult = 1 },
			sac = { armor = 0, mult = 2.5, fatal = 70 },
		},
		attacks = { { kind = "spit", damage = 25, range = 60, cooldown = 2.6, speed = 60, radius = 4, windup = 0.4 } },
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
	},

	-- THE LUMEN CONCORD -------------------------------------------------------------
	-- Ceramic shells held together by floating light. Violet cores are the weak spots.
	-- Behaviour lives in server/Enemies/LumenAI.luau, fallback models in server/Enemies/LumenModels.luau.
	SHARDLING = {
		id = "SHARDLING", name = "Shardling", faction = "LUMEN", class = "regular",
		hp = 60, speed = 15, size = 1.8,
		zones = {
			body = { armor = 1, mult = 1 },
			core = { armor = 0, mult = 2, fatal = 22 },
		},
		attacks = { { kind = "needle", damage = 9, range = 65, cooldown = 1.1, speed = 150, count = 2, interval = 0.1, spread = 3 } },
		keepDistance = 24, salvage = 2, xp = 2,
		desc = "Floating crystal drone. Its petals open around a violet core: one clean shot pops it.",
	},
	WARDEN = {
		id = "WARDEN", name = "Lumen Warden", faction = "LUMEN", class = "medium",
		hp = 280, speed = 11, size = 2.6,
		zones = {
			body = { armor = 2, mult = 1 },
			head = { armor = 1, mult = 1.5 },
			core = { armor = 1, mult = 2.5, fatal = 85 },
			shield = { armor = 3, mult = 0, blocks = true },
		},
		attacks = { { kind = "needle", damage = 16, range = 80, cooldown = 2.2, speed = 140, count = 3, interval = 0.14, spread = 2 } },
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

local Enemies = { byId = E }

Enemies.Factions = {
	COG = {
		id = "COG", name = "The Cogwork Legion", short = "Cogwork",
		color = Color3.fromHex("ff4040"),
		roster = { regular = "TINKER", medium = "RIVET", heavy = "BULWARK", behemoth = "COLOSSUS" },
		deathStyle = "scrap",
	},
	BROOD = {
		id = "BROOD", name = "The Skitter Brood", short = "Brood",
		color = Color3.fromHex("8cff3a"),
		roster = { regular = "SKITTER", medium = "SPITTER", heavy = "CHARGER", behemoth = "TITAN" },
		deathStyle = "goo",
	},
	LUMEN = {
		id = "LUMEN", name = "The Lumen Concord", short = "Concord",
		color = Color3.fromHex("c060ff"),
		roster = { regular = "SHARDLING", medium = "WARDEN", heavy = "LANCER", behemoth = "SPIRE" },
		deathStyle = "shard", -- client/Fx/LumenFx.luau: shatter into crystal shards + soft light pop
		reinforce = "rift", -- Director: rift gate warp-in (4-6 units)
	},
}

function Enemies.get(id: string): Enemy?
	return E[id]
end

return Enemies
