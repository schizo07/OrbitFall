-- The war map (docs/spec.md §14). Positions are 0..1 on the war-map canvas.
-- owner = who holds the planet at the START of the war ("FREE" | "COG" | "BROOD" | "LUMEN").
-- Live ownership comes from Shared/War.luau (contributions + operation outcomes).
-- gain   = liberation % added per successful mission (before difficulty scaling)
-- biome  = map dressing hint for MapBuilder ("desert" | "ash" | "swamp" | "ice" | "crystal")

export type Planet = {
	id: string,
	name: string,
	sector: string,
	pos: Vector2,
	owner: string,
	biome: string,
	gain: number,
	size: number, -- visual radius scale on the map
	links: { string }, -- supply lanes drawn on the map
	desc: string,
}

local Sectors = {
	HALCYON = { name = "Halcyon Reach", pos = Vector2.new(0.24, 0.55), radius = 0.17, color = Color3.fromHex("3ee6c8") },
	CINDER = { name = "Cinder Expanse", pos = Vector2.new(0.70, 0.27), radius = 0.18, color = Color3.fromHex("ff4a3a") },
	MIRE = { name = "Mire Belt", pos = Vector2.new(0.72, 0.74), radius = 0.17, color = Color3.fromHex("8cff3a") },
	FRONTIER = { name = "Outer Frontier", pos = Vector2.new(0.47, 0.50), radius = 0.13, color = Color3.fromHex("ffb36b") },
	VEIL = { name = "Prism Veil", pos = Vector2.new(0.30, 0.16), radius = 0.12, color = Color3.fromHex("c060ff") },
}

local P: { [string]: Planet } = {
	-- Home space (free at war start)
	VERDANCE = { id = "VERDANCE", name = "Verdance", sector = "HALCYON", pos = Vector2.new(0.17, 0.55), owner = "FREE", biome = "desert", gain = 0.6, size = 1.4, links = { "TESSALY", "BRIGHTWATER" }, desc = "Capital world. If it falls, everything falls." },
	TESSALY = { id = "TESSALY", name = "Tessaly", sector = "HALCYON", pos = Vector2.new(0.29, 0.44), owner = "FREE", biome = "desert", gain = 0.6, size = 1.0, links = { "ARIDANE", "CANDERA" }, desc = "Farming moons and quiet towns." },
	BRIGHTWATER = { id = "BRIGHTWATER", name = "Brightwater", sector = "HALCYON", pos = Vector2.new(0.28, 0.67), owner = "FREE", biome = "ice", gain = 0.6, size = 0.9, links = { "GLASSMERE" }, desc = "Ice-mining colony." },
	-- Frontier (contested)
	ARIDANE = { id = "ARIDANE", name = "Aridane", sector = "FRONTIER", pos = Vector2.new(0.45, 0.40), owner = "COG", biome = "desert", gain = 0.5, size = 1.0, links = { "FERROX", "KILN" }, desc = "Dust storms and old missile silos." },
	GLASSMERE = { id = "GLASSMERE", name = "Glassmere", sector = "FRONTIER", pos = Vector2.new(0.48, 0.60), owner = "BROOD", biome = "swamp", gain = 0.5, size = 0.9, links = { "SPOREHOLD" }, desc = "Glass deserts melted by old wars." },
	-- Cogwork Legion space
	FERROX = { id = "FERROX", name = "Ferrox Prime", sector = "CINDER", pos = Vector2.new(0.63, 0.22), owner = "COG", biome = "ash", gain = 0.5, size = 1.3, links = { "KILN", "RUSTHOLM" }, desc = "Foundry world. The Legion keeps its warheads here." },
	KILN = { id = "KILN", name = "Kiln", sector = "CINDER", pos = Vector2.new(0.74, 0.36), owner = "COG", biome = "ash", gain = 0.4, size = 0.9, links = { "RUSTHOLM" }, desc = "Lava rivers and smelters." },
	RUSTHOLM = { id = "RUSTHOLM", name = "Rustholm", sector = "CINDER", pos = Vector2.new(0.81, 0.18), owner = "COG", biome = "desert", gain = 0.4, size = 1.0, links = {}, desc = "The Legion's command spire." },
	-- Skitter Brood space
	SPOREHOLD = { id = "SPOREHOLD", name = "Sporehold", sector = "MIRE", pos = Vector2.new(0.63, 0.70), owner = "BROOD", biome = "swamp", gain = 0.5, size = 1.1, links = { "BOGRUN", "CHITTERFALL" }, desc = "Spore jungles, knee-deep goo." },
	BOGRUN = { id = "BOGRUN", name = "Bogrun", sector = "MIRE", pos = Vector2.new(0.76, 0.83), owner = "BROOD", biome = "swamp", gain = 0.4, size = 0.9, links = { "CHITTERFALL" }, desc = "Hive mounds as far as the eye can see." },
	CHITTERFALL = { id = "CHITTERFALL", name = "Chitterfall", sector = "MIRE", pos = Vector2.new(0.84, 0.66), owner = "BROOD", biome = "swamp", gain = 0.4, size = 1.2, links = {}, desc = "Home of the Hive Titans." },
	-- Lumen Concord space
	CANDERA = { id = "CANDERA", name = "Candera", sector = "VEIL", pos = Vector2.new(0.37, 0.23), owner = "LUMEN", biome = "crystal", gain = 0.5, size = 1.0, links = { "PRISMARA", "SOLLUNE" }, desc = "Chalk plains where the crystals sing at dawn." },
	PRISMARA = { id = "PRISMARA", name = "Prismara", sector = "VEIL", pos = Vector2.new(0.22, 0.14), owner = "LUMEN", biome = "crystal", gain = 0.4, size = 1.1, links = { "SOLLUNE" }, desc = "Every surface splits the light. Prism Lancers patrol the glare." },
	SOLLUNE = { id = "SOLLUNE", name = "Sollune", sector = "VEIL", pos = Vector2.new(0.33, 0.08), owner = "LUMEN", biome = "crystal", gain = 0.4, size = 1.2, links = {}, desc = "The Choir Spires gather here. Nobody has heard them stop." },
}

local Planets = { byId = P, Sectors = Sectors }

Planets.Order = { "VERDANCE", "TESSALY", "BRIGHTWATER", "ARIDANE", "GLASSMERE", "FERROX", "KILN", "RUSTHOLM", "SPOREHOLD", "BOGRUN", "CHITTERFALL", "CANDERA", "PRISMARA", "SOLLUNE" }

function Planets.get(id: string): Planet?
	return P[id]
end

return Planets
