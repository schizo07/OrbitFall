-- Weapon catalogue (docs/spec.md §4). Keys are stable save IDs.
-- kind: "auto" | "semi" | "shotgun" | "rocket" | "rail" | "grenade"
-- slot: "primary" | "secondary" | "support" | "grenade"

export type Weapon = {
	id: string,
	name: string,
	slot: string,
	kind: string,
	damage: number,
	ap: number,
	rpm: number?,
	mag: number?,
	spareMags: number?,
	reload: number?,
	perShellReload: boolean?,
	pellets: number?,
	spread: number?, -- degrees hip-fire
	range: number?,
	splash: { radius: number, core: number, damage: number, ap: number }?,
	pierce: number?,
	charge: number?,
	spinUp: number?,
	arc: number?,
	zoom: number?,
	recoil: number?, -- camera kick degrees
	sound: string, -- Sounds catalogue key
	tracer: Color3?,
	unlock: string?, -- "starter" | "armory" | "bond:<BOND>" | "callin"
	salvage: number?, -- armory price
	rank: number?,
	desc: string,
}

local W: { [string]: Weapon } = {
	PR7 = {
		id = "PR7", name = "PR-7 Pulse Carbine", slot = "primary", kind = "auto",
		damage = 30, ap = 2, rpm = 600, mag = 40, spareMags = 6, reload = 2.2, spread = 1.6, range = 400,
		recoil = 0.45, sound = "ShotRifle", tracer = Color3.fromHex("ffd27a"), unlock = "starter",
		desc = "Accurate full-auto carbine. Your reliable workhorse.",
	},
	SG4 = {
		id = "SG4", name = "SG-4 Breacher Scatter", slot = "primary", kind = "shotgun",
		damage = 16, ap = 2, pellets = 9, rpm = 90, mag = 8, spareMags = 5, reload = 0.45, perShellReload = true,
		spread = 6, range = 120, recoil = 2.4, sound = "ShotShotgun", tracer = Color3.fromHex("ffb36b"),
		unlock = "armory", salvage = 400, rank = 2,
		desc = "Nine pellets of bad news. Knocks small enemies flying.",
	},
	SM2 = {
		id = "SM2", name = "SM-2 Buzz SMG", slot = "primary", kind = "auto",
		damage = 22, ap = 1, rpm = 850, mag = 50, spareMags = 6, reload = 1.8, spread = 2.4, range = 250,
		recoil = 0.3, sound = "ShotSMG", tracer = Color3.fromHex("fff07a"), unlock = "armory", salvage = 300, rank = 1,
		desc = "Fast and light. Bounces off anything armoured.",
	},
	MR9 = {
		id = "MR9", name = "MR-9 Longwatch", slot = "primary", kind = "semi",
		damage = 115, ap = 3, rpm = 160, mag = 15, spareMags = 6, reload = 2.6, spread = 0.4, range = 600, zoom = 2,
		recoil = 2.0, sound = "ShotMarksman", tracer = Color3.fromHex("9fe8ff"), unlock = "armory", salvage = 650, rank = 4,
		desc = "Marksman rifle. Heavy penetration, perfect for eyes.",
	},
	HS3 = {
		id = "HS3", name = "HS-3 Hammerhead", slot = "primary", kind = "semi",
		damage = 220, ap = 3, rpm = 70, mag = 6, spareMags = 6, reload = 0.5, perShellReload = true, spread = 0.6,
		range = 300, recoil = 3.2, sound = "ShotShotgun", tracer = Color3.fromHex("ff8a5b"), unlock = "bond:FIELDKIT",
		desc = "Single slug shotgun. Slow, brutal, precise.",
	},
	VR1 = {
		id = "VR1", name = "VR-1 Volt Repeater", slot = "primary", kind = "auto",
		damage = 40, ap = 2, rpm = 300, mag = 30, spareMags = 6, reload = 2.4, spread = 1.2, range = 200, arc = 3,
		recoil = 0.8, sound = "ShotVolt", tracer = Color3.fromHex("7af0ff"), unlock = "bond:IRONCLAD",
		desc = "Each hit arcs to 3 nearby enemies. Weak vs single heavies.",
	},
	P3 = {
		id = "P3", name = "P-3 Sidearm", slot = "secondary", kind = "semi",
		damage = 45, ap = 2, rpm = 400, mag = 15, spareMags = 6, reload = 1.4, spread = 1.0, range = 250,
		recoil = 0.8, sound = "ShotPistol", tracer = Color3.fromHex("ffd27a"), unlock = "starter",
		desc = "Dependable sidearm.",
	},
	BP2 = {
		id = "BP2", name = "BP-2 Boomer Pistol", slot = "secondary", kind = "semi",
		damage = 60, ap = 3, rpm = 120, mag = 6, spareMags = 5, reload = 2.0, spread = 1.0, range = 200,
		splash = { radius = 3, core = 1, damage = 100, ap = 3 },
		recoil = 1.8, sound = "ShotPistolHeavy", tracer = Color3.fromHex("ff7a3b"), unlock = "bond:IRONCLAD",
		desc = "Explosive rounds. Pop small groups.",
	},
	FRAG = {
		id = "FRAG", name = "Frag Grenade", slot = "grenade", kind = "grenade", damage = 400, ap = 3,
		splash = { radius = 7, core = 2.5, damage = 400, ap = 3 }, sound = "Explosion", unlock = "starter",
		desc = "2.2 s fuse, bounces.",
	},
	IMPACT = {
		id = "IMPACT", name = "Impact Grenade", slot = "grenade", kind = "grenade", damage = 450, ap = 3,
		splash = { radius = 6, core = 2, damage = 450, ap = 3 }, sound = "Explosion", unlock = "bond:FIELDKIT",
		desc = "Explodes on contact.",
	},
	STUN = {
		id = "STUN", name = "Stun Grenade", slot = "grenade", kind = "grenade", damage = 0, ap = 0,
		splash = { radius = 9, core = 9, damage = 0, ap = 0 }, sound = "EMP", unlock = "armory", salvage = 350, rank = 3,
		desc = "Stuns everything except Behemoths for 5 s.",
	},
	ROCKET = {
		id = "ROCKET", name = "Breacher Rocket Tube", slot = "support", kind = "rocket",
		damage = 650, ap = 5, rpm = 20, mag = 1, spareMags = 6, reload = 3.0, spread = 0.3, range = 500,
		splash = { radius = 6, core = 2, damage = 250, ap = 3 },
		recoil = 5, sound = "ShotRocket", tracer = Color3.fromHex("ffa040"), unlock = "callin",
		desc = "Anti-armour rocket. Aim for the eye.",
	},
	GATLING = {
		id = "GATLING", name = "Thrum Gatling", slot = "support", kind = "auto",
		damage = 45, ap = 3, rpm = 900, mag = 150, spareMags = 2, reload = 4.0, spread = 2.2, range = 350, spinUp = 0.4,
		recoil = 0.35, sound = "ShotGatling", tracer = Color3.fromHex("ffe07a"), unlock = "callin",
		desc = "Spins up, shreds everything medium and below.",
	},
	RAIL = {
		id = "RAIL", name = "Rail Lance", slot = "support", kind = "rail",
		damage = 900, ap = 5, rpm = 30, mag = 1, spareMags = 12, reload = 1.0, spread = 0, range = 800, charge = 2, pierce = 2,
		recoil = 4, sound = "ShotRail", tracer = Color3.fromHex("8affff"), unlock = "callin",
		desc = "Charge 2 s, pierce two targets. Behemoth eyes beware.",
	},
}

local Weapons = { byId = W }

function Weapons.get(id: string): Weapon?
	return W[id]
end

function Weapons.list(slot: string?): { Weapon }
	local out = {}
	for _, w in W do
		if slot == nil or w.slot == slot then
			table.insert(out, w)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

return Weapons
