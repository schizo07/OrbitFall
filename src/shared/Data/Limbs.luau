-- Detachable limbs per enemy kind (dismemberment). Read by server/Enemies/Dismember.luau and client/Fx/DismemberFx.luau.
-- Only rigged mesh models (model attr Rigged = true) can lose limbs; part names are the manifest names (art/fbx/manifest.json).
--
-- Limb fields:
--   part     manifest part name. Hits on any part hanging below it in the Motor6D tree (Leg_L_Lower under Leg_L_Upper)
--            count towards it, and the whole sub-tree comes off together.
--   hp       limb HP at difficulty 1 (scaled like enemy HP). Bullet damage is armour-checked against the hit part's
--            zone armour with zone mult 1; explosions use falloff to the limb part (x0.8).
--   speed    move-speed multiplier once lost (stacks multiplicatively, floor 0.3)
--   leg      "L" | "R": leg side, the client leans the body that way (limp)
--   disarm   attack kinds this limb fires; once lost they become the `melee` fallback attack (same slot)
--   melee    fallback melee attack { damage, range, cooldown, windup? }
--   weaken   { kind, mult }: that attack's damage is multiplied once lost
--   armor    new body-zone armour once lost (armour plate shot off)
-- Fatal weak spots (eyes, sacs, cores, throats) are never listed here: they still kill as before.
-- Behemoths only shed small parts; their lower legs need a huge amount of damage.

export type Limb = {
	part: string,
	hp: number,
	speed: number?,
	leg: string?,
	disarm: { string }?,
	melee: { damage: number, range: number, cooldown: number, windup: number? }?,
	weaken: { kind: string, mult: number }?,
	armor: number?,
}
export type KindInfo = { biped: boolean?, limbs: { Limb } }

local function hexLegs(hp: number, speed: number): { Limb }
	local out: { Limb } = {}
	for i = 1, 6 do
		table.insert(out, { part = "Leg_" .. i, hp = hp, speed = speed, leg = if i % 2 == 1 then "L" else "R" })
	end
	return out
end

local function append(a: { Limb }, b: { Limb }): { Limb }
	for _, l in b do
		table.insert(a, l)
	end
	return a
end

local byKind: { [string]: KindInfo } = {
	TINKER = {
		biped = true,
		limbs = {
			{ part = "Arm_R", hp = 45, disarm = { "bolt" }, melee = { damage = 10, range = 3, cooldown = 1.3 } },
			{ part = "Arm_L", hp = 45 },
			{ part = "Leg_L_Upper", hp = 50, speed = 0.55, leg = "L" },
			{ part = "Leg_R_Upper", hp = 50, speed = 0.55, leg = "R" },
		},
	},
	RIVET = {
		biped = true,
		limbs = {
			{ part = "Arm_R", hp = 110, disarm = { "burst" }, melee = { damage = 18, range = 3.5, cooldown = 1.4 } },
			{ part = "Arm_L", hp = 110 },
			{ part = "Leg_L_Upper", hp = 130, speed = 0.6, leg = "L" },
			{ part = "Leg_R_Upper", hp = 130, speed = 0.6, leg = "R" },
		},
	},
	BULWARK = {
		limbs = {
			{ part = "Shield", hp = 700 }, -- front plate: once gone, shots reach the body behind it
			{ part = "Arm_R", hp = 300 },
			{ part = "Arm_L", hp = 300 },
			{ part = "Leg_1", hp = 500, speed = 0.8, leg = "L" },
			{ part = "Leg_2", hp = 500, speed = 0.8, leg = "R" },
			{ part = "Leg_3", hp = 500, speed = 0.8, leg = "L" },
			{ part = "Leg_4", hp = 500, speed = 0.8, leg = "R" },
		},
	},
	COLOSSUS = {
		limbs = {
			{ part = "Leg_1_Lower", hp = 1800, speed = 0.8, leg = "R" },
			{ part = "Leg_2_Lower", hp = 1800, speed = 0.8, leg = "L" },
			{ part = "Leg_3_Lower", hp = 1800, speed = 0.8, leg = "R" },
			{ part = "Leg_4_Lower", hp = 1800, speed = 0.8, leg = "L" },
		},
	},
	SKITTER = {
		limbs = append({
			{ part = "Mandible_L", hp = 12, weaken = { kind = "leap", mult = 0.75 } },
			{ part = "Mandible_R", hp = 12, weaken = { kind = "leap", mult = 0.75 } },
		}, hexLegs(15, 0.85)),
	},
	SPITTER = {
		limbs = append({
			{ part = "Head", hp = 70, disarm = { "spit" }, melee = { damage = 16, range = 3.5, cooldown = 1.4 } },
		}, hexLegs(45, 0.85)),
	},
	CHARGER = {
		limbs = append({
			{ part = "Ram", hp = 800, armor = 3 }, -- front carapace cracked off: body armour 4 -> 3
		}, hexLegs(220, 0.82)),
	},
	TITAN = {
		limbs = {
			{ part = "Mandible_L", hp = 350 },
			{ part = "Mandible_R", hp = 350 },
			{ part = "Leg_1_Lower", hp = 1600, speed = 0.9, leg = "L" },
			{ part = "Leg_2_Lower", hp = 1600, speed = 0.9, leg = "R" },
			{ part = "Leg_3_Lower", hp = 1600, speed = 0.9, leg = "L" },
			{ part = "Leg_4_Lower", hp = 1600, speed = 0.9, leg = "R" },
			{ part = "Leg_5_Lower", hp = 1600, speed = 0.9, leg = "L" },
			{ part = "Leg_6_Lower", hp = 1600, speed = 0.9, leg = "R" },
		},
	},
}

local Limbs = { byKind = byKind }

function Limbs.info(kind: string): KindInfo?
	return byKind[kind]
end

function Limbs.get(kind: string): { Limb }?
	local k = byKind[kind]
	return if k then k.limbs else nil
end

-- the limb entry for a part name (exact match only), or nil
function Limbs.find(kind: string, partName: string): Limb?
	local k = byKind[kind]
	if not k then
		return nil
	end
	for _, l in k.limbs do
		if l.part == partName then
			return l
		end
	end
	return nil
end

return Limbs
