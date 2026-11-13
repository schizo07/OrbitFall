-- Bond tracks (docs/spec.md §8.2). Item `grant` says what owning it unlocks.
-- grant.kind: "weapon" | "callin" | "cosmetic" | "title" | "tokens"
-- Every item is buyable with Bond Tokens (earned free by playing). Premium bonds
-- additionally have a Game Pass that grants access + all items (Config.GamePasses).

export type BondItem = { id: string, name: string, cost: number, page: number, grant: { kind: string, id: string }, desc: string }
export type Bond = {
	id: string,
	name: string,
	premium: boolean,
	accessCost: number, -- BT; 0 for free tracks
	pass: string?, -- Config.GamePasses key
	color: Color3,
	pageUnlock: number, -- items needed on page n to open page n+1
	items: { BondItem },
}

local B: { [string]: Bond } = {
	FIELDKIT = {
		id = "FIELDKIT", name = "Field Kit Bond", premium = false, accessCost = 0,
		color = Color3.fromHex("3ee6c8"), pageUnlock = 3,
		items = {
			{ id = "FK_TITLE_ROOKIE", name = "Title: Drop Rookie", cost = 20, page = 1, grant = { kind = "title", id = "Drop Rookie" }, desc = "Show it off." },
			{ id = "FK_IMPACT", name = "Impact Grenade", cost = 60, page = 1, grant = { kind = "weapon", id = "IMPACT" }, desc = "Explodes on contact." },
			{ id = "FK_SKIN_SAND", name = "Armour: Dune Runner", cost = 40, page = 1, grant = { kind = "cosmetic", id = "SKIN_SAND" }, desc = "Sand-and-orange armour paint." },
			{ id = "FK_CAPE_TEAL", name = "Cape: Teal Banner", cost = 40, page = 1, grant = { kind = "cosmetic", id = "CAPE_TEAL" }, desc = "A flowing teal cape." },
			{ id = "FK_STUN_SKIN", name = "Grenade Skin: Hazard", cost = 30, page = 1, grant = { kind = "cosmetic", id = "NADE_HAZARD" }, desc = "Stripy grenades." },
			{ id = "FK_CLUSTER", name = "Call-in: Cluster Drop", cost = 90, page = 2, grant = { kind = "callin", id = "CLUSTER" }, desc = "Crowd-clearing bomblets." },
			{ id = "FK_HS3", name = "HS-3 Hammerhead", cost = 100, page = 2, grant = { kind = "weapon", id = "HS3" }, desc = "Slug shotgun." },
			{ id = "FK_SKIN_NIGHT", name = "Armour: Night Shift", cost = 60, page = 2, grant = { kind = "cosmetic", id = "SKIN_NIGHT" }, desc = "Dark navy with glow strips." },
			{ id = "FK_TITLE_VET", name = "Title: Orbit Veteran", cost = 40, page = 2, grant = { kind = "title", id = "Orbit Veteran" }, desc = "Earned the hard way." },
			{ id = "FK_TOKENS", name = "Bond Token Cache", cost = 50, page = 3, grant = { kind = "tokens", id = "70" }, desc = "Refunds 70 BT. Keep grinding!" },
			{ id = "FK_SKIN_GOLD", name = "Armour: Brass Hero", cost = 120, page = 3, grant = { kind = "cosmetic", id = "SKIN_GOLD" }, desc = "Shiny brass trim." },
		},
	},
	IRONCLAD = {
		id = "IRONCLAD", name = "Ironclad Bond", premium = true, accessCost = 300, pass = "IroncladBond",
		color = Color3.fromHex("ff8a2b"), pageUnlock = 3,
		items = {
			{ id = "IC_VR1", name = "VR-1 Volt Repeater", cost = 100, page = 1, grant = { kind = "weapon", id = "VR1" }, desc = "Chain-arc rifle." },
			{ id = "IC_SKIN", name = "Armour: Ironclad", cost = 80, page = 1, grant = { kind = "cosmetic", id = "SKIN_IRON" }, desc = "Heavy riveted plates." },
			{ id = "IC_CAPE", name = "Cape: Molten", cost = 50, page = 1, grant = { kind = "cosmetic", id = "CAPE_MOLTEN" }, desc = "Glowing orange cape." },
			{ id = "IC_TITLE", name = "Title: Bolt Breaker", cost = 30, page = 1, grant = { kind = "title", id = "Bolt Breaker" }, desc = "Robots fear you." },
			{ id = "IC_BP2", name = "BP-2 Boomer Pistol", cost = 90, page = 2, grant = { kind = "weapon", id = "BP2" }, desc = "Explosive sidearm." },
			{ id = "IC_SHIELD", name = "Call-in: Shield Dome", cost = 110, page = 2, grant = { kind = "callin", id = "SHIELD" }, desc = "Projectile-proof dome." },
			{ id = "IC_EMOTE", name = "Emote: Salute Spin", cost = 40, page = 2, grant = { kind = "cosmetic", id = "EMOTE_SPIN" }, desc = "Show-off spin." },
			{ id = "IC_RAIL", name = "Call-in: Rail Lance", cost = 120, page = 3, grant = { kind = "callin", id = "RAILDROP" }, desc = "Charged piercing support weapon." },
			{ id = "IC_SKIN2", name = "Armour: Chrome Ironclad", cost = 120, page = 3, grant = { kind = "cosmetic", id = "SKIN_CHROME" }, desc = "Mirror finish." },
		},
	},
	HIVEBREAKER = {
		id = "HIVEBREAKER", name = "Hivebreaker Bond", premium = true, accessCost = 300, pass = "HivebreakerBond",
		color = Color3.fromHex("8cff3a"), pageUnlock = 3,
		items = {
			{ id = "HB_SMOKE", name = "Call-in: Smoke Screen", cost = 70, page = 1, grant = { kind = "callin", id = "SMOKE" }, desc = "Break line of sight." },
			{ id = "HB_SKIN", name = "Armour: Goo-Proof", cost = 80, page = 1, grant = { kind = "cosmetic", id = "SKIN_GOO" }, desc = "Slick green hazmat." },
			{ id = "HB_TITLE", name = "Title: Bug Squasher", cost = 30, page = 1, grant = { kind = "title", id = "Bug Squasher" }, desc = "Squish." },
			{ id = "HB_CAPE", name = "Cape: Hive Silk", cost = 50, page = 1, grant = { kind = "cosmetic", id = "CAPE_SILK" }, desc = "Shimmering silk." },
			{ id = "HB_BARRAGE", name = "Call-in: Orbital Barrage", cost = 120, page = 2, grant = { kind = "callin", id = "BARRAGE" }, desc = "15-shell rain." },
			{ id = "HB_FLAME", name = "Armour: Ember", cost = 90, page = 2, grant = { kind = "cosmetic", id = "SKIN_EMBER" }, desc = "Flame decals." },
			{ id = "HB_EMOTE", name = "Emote: Victory Stomp", cost = 40, page = 2, grant = { kind = "cosmetic", id = "EMOTE_STOMP" }, desc = "Stomp stomp." },
			{ id = "HB_SKIN2", name = "Armour: Titan Hunter", cost = 120, page = 3, grant = { kind = "cosmetic", id = "SKIN_HUNTER" }, desc = "Trophy plates." },
		},
	},
}

local Bonds = { byId = B, order = { "FIELDKIT", "IRONCLAD", "HIVEBREAKER" } }

function Bonds.get(id: string): Bond?
	return B[id]
end

function Bonds.findItem(itemId: string): (Bond?, BondItem?)
	for _, b in B do
		for _, it in b.items do
			if it.id == itemId then
				return b, it
			end
		end
	end
	return nil, nil
end

return Bonds
