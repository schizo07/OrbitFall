-- Call-in catalogue (docs/spec.md §3.3). Server effect module: src/server/CallIns/Effects/<id>.luau
-- category: "orbital" | "air" | "defense" | "supply" | "weapon" | "mission"
-- beacon: "offense" | "supply" | "defense"   (beam colour, Config.Colors.Beacon*)

export type CallIn = {
	id: string,
	name: string,
	category: string,
	beacon: string,
	delay: number,
	cooldown: number,
	uses: number?, -- nil = unlimited
	charges: number?, -- nil = 1
	icon: string, -- short glyph used by UI until real icons exist
	unlock: string, -- "starter" | "armory" | "bond:<BOND>" | "mission"
	salvage: number?,
	rank: number?,
	params: { [string]: any },
	desc: string,
}

local C: { [string]: CallIn } = {
	LANCE = {
		id = "LANCE", name = "Orbital Lance", category = "orbital", beacon = "offense",
		delay = 3, cooldown = 240, uses = 3, icon = "⚡", unlock = "starter",
		params = { duration = 12, dps = 900, ap = 6, radius = 3, huntRadius = 30, speed = 9 },
		desc = "A 12 s beam from orbit that cuts through ANY armour and hunts the biggest target. 3 uses.",
	},
	HALFTON = {
		id = "HALFTON", name = "Half-Ton Bomb", category = "air", beacon = "offense",
		delay = 2.5, cooldown = 150, icon = "💣", unlock = "starter",
		params = { damage = 3000, ap = 6, core = 7, radius = 18, edgeAp = 4, shakeRadius = 80 },
		desc = "One 500 kg bomb. Deletes anything in the blast.",
	},
	STRAFE = {
		id = "STRAFE", name = "Strafe Run", category = "air", beacon = "offense",
		delay = 2, cooldown = 60, charges = 2, icon = "✈", unlock = "starter",
		params = { bombs = 10, length = 40, damage = 450, ap = 4, radius = 6, core = 2 },
		desc = "A jet carpets a 40-stud line along your throw direction. 2 charges.",
	},
	TOXIN = {
		id = "TOXIN", name = "Toxin Cloud", category = "air", beacon = "offense",
		delay = 2, cooldown = 75, icon = "☣", unlock = "armory", salvage = 900, rank = 3,
		params = { radius = 14, duration = 12, dps = 70, bugMult = 1.5, robotMult = 0.5 },
		desc = "A lingering cloud that melts bugs and confuses everything.",
	},
	EMP = {
		id = "EMP", name = "EMP Burst", category = "orbital", beacon = "offense",
		delay = 1.5, cooldown = 70, icon = "◎", unlock = "armory", salvage = 800, rank = 2,
		params = { radius = 20, damage = 60, stun = 8, slow = 0.5, slowTime = 6 },
		desc = "Stuns robots for 8 s, slows bugs. Strips shields.",
	},
	MINES = {
		id = "MINES", name = "Minefield", category = "defense", beacon = "defense",
		delay = 2, cooldown = 120, icon = "✸", unlock = "armory", salvage = 700, rank = 2,
		params = { count = 12, spread = 14, damage = 400, ap = 3, radius = 5, core = 1.5, lifetime = 120 },
		desc = "12 proximity mines. Safe for your squad.",
	},
	SUPPLY = {
		id = "SUPPLY", name = "Supply Drop", category = "supply", beacon = "supply",
		delay = 3, cooldown = 150, icon = "▣", unlock = "starter",
		params = { players = 4, grenades = 2, crushDamage = 500, crushAp = 4, crushRadius = 4 },
		desc = "Ammo crate for 4 squadmates. Also crushes whatever it lands on.",
	},
	BARRAGE = {
		id = "BARRAGE", name = "Orbital Barrage", category = "orbital", beacon = "offense",
		delay = 4, cooldown = 180, icon = "☄", unlock = "bond:HIVEBREAKER",
		params = { shells = 15, duration = 9, radius = 20, damage = 500, ap = 4, blast = 6, core = 2 },
		desc = "15 shells rain down over 9 s.",
	},
	SENTRY = {
		id = "SENTRY", name = "Sentry Turret", category = "defense", beacon = "defense",
		delay = 3, cooldown = 140, icon = "⌖", unlock = "armory", salvage = 1100, rank = 4,
		params = { damage = 45, ap = 3, rpm = 600, ammo = 300, range = 70, lifetime = 90, hp = 800 },
		desc = "Automatic MG turret. 300 rounds.",
	},
	ROCKETDROP = {
		id = "ROCKETDROP", name = "Rocket Tube", category = "weapon", beacon = "supply",
		delay = 4, cooldown = 300, icon = "➶", unlock = "armory", salvage = 600, rank = 1,
		params = { weapon = "ROCKET" },
		desc = "Drops the Breacher Rocket Tube. AP 5 — the eye-killer.",
	},
	GATLINGDROP = {
		id = "GATLINGDROP", name = "Gatling MG", category = "weapon", beacon = "supply",
		delay = 4, cooldown = 300, icon = "≡", unlock = "armory", salvage = 750, rank = 3,
		params = { weapon = "GATLING" },
		desc = "Drops the Thrum Gatling.",
	},
	SHIELD = {
		id = "SHIELD", name = "Shield Dome", category = "defense", beacon = "defense",
		delay = 2, cooldown = 150, icon = "◠", unlock = "bond:IRONCLAD",
		params = { radius = 12, duration = 20 },
		desc = "A dome that stops enemy projectiles for 20 s.",
	},
	SMOKE = {
		id = "SMOKE", name = "Smoke Screen", category = "air", beacon = "defense",
		delay = 1.5, cooldown = 60, icon = "☁", unlock = "bond:HIVEBREAKER",
		params = { length = 30, width = 10, duration = 15 },
		desc = "A smoke wall. Enemies inside lose track of you.",
	},
	CLUSTER = {
		id = "CLUSTER", name = "Cluster Drop", category = "air", beacon = "offense",
		delay = 2, cooldown = 90, icon = "⁂", unlock = "bond:FIELDKIT",
		params = { bomblets = 30, length = 18, width = 10, damage = 160, ap = 2, radius = 4, core = 1 },
		desc = "30 bomblets. Crowd-clearing confetti.",
	},
	RAILDROP = {
		id = "RAILDROP", name = "Rail Lance", category = "weapon", beacon = "supply",
		delay = 4, cooldown = 300, icon = "⟿", unlock = "bond:IRONCLAD",
		params = { weapon = "RAIL" },
		desc = "Drops the Rail Lance. Charge, aim, pierce.",
	},
	REINFORCE = {
		id = "REINFORCE", name = "Reinforce", category = "mission", beacon = "supply",
		delay = 2, cooldown = 10, icon = "✚", unlock = "mission",
		params = {},
		desc = "Brings fallen squadmates back in drop capsules.",
	},
}

local CallIns = { byId = C }
CallIns.Starter = { "LANCE", "HALFTON", "STRAFE", "SUPPLY" }
CallIns.SlotCount = 4

function CallIns.get(id: string): CallIn?
	return C[id]
end

function CallIns.list(): { CallIn }
	local out = {}
	for _, c in C do
		if c.unlock ~= "mission" then
			table.insert(out, c)
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

return CallIns
