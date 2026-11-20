-- Dustbowl Ridge layout plan: the one table the map (World/MapBuilder), the set pieces (World/Places) and the missions
-- (Objectives/*) read positions from. Studs on the ground plane: Vector2(x, z), x = east, z = south (north = -Z).
-- The playable floor is |x|, |z| <= ~240; the edge cliffs rise from ~250. A site keeps max(|x|,|z|) + its pad inner
-- radius <= 225.
--
-- Mission shape (HAUL): you land at one of three crash sites (a downed COG cargo drone), take its spilled cell, and
-- find the other cell places (mesa, quarry, graveyard). Every cell goes to the cargo lifter in the refinery near the
-- middle, and you extract at the salt pan on the east edge. Side objectives sit at fixed spots on the routes.
local MapPlan = {}

local V2 = Vector2.new

-- The four big places plus the extraction. `site` = the old map.sites name this place fills (MISSILE / UPLINK and the
-- side objectives still look sites up by these names). `r` = rough radius the place's set piece and terrain shape use;
-- MapBuilder keeps camps, rubble and props out of it.
MapPlan.places = {
	refinery = { at = V2(20, -20), r = 46, site = "silo" }, -- cargo lifter plaza in the middle, walls with two gaps, smoke stack (landmark)
	mesa = { at = V2(-165, -155), r = 50, site = "uplink", height = 26 }, -- flat-topped rock, one ramp facing the refinery, relay mast (landmark)
	quarry = { at = V2(165, -168), r = 54, site = "generator", depth = 18 }, -- stepped pit (3 terraces), ramp down facing the refinery
	graveyard = { at = V2(165, 160), r = 44, site = "console" }, -- a huge fallen COG walker; ribs you walk between (landmark)
	saltpan = { at = V2(190, 10), r = 52, site = "extraction" }, -- flat white pan, a wrecked hauler + rock clusters for cover
}

-- One crash site per mission, picked by the map's rng. `crash` becomes map.insertion (the squad lands here), `spilled`
-- becomes the "codes" site: the first cell, lying in the drone's debris on the trail away from the crash.
MapPlan.crashes = {
	{ name = "SW", crash = V2(-175, 175), spilled = V2(-195, 0) },
	{ name = "S", crash = V2(-20, 170), spilled = V2(-115, 95) },
	{ name = "W", crash = V2(-178, -25), spilled = V2(-82, -108) },
}
MapPlan.crashPad = { 34, 64 } -- inner (flat crater floor), outer (blend) radius
MapPlan.spilledPad = { 14, 32 } -- inner, outer

-- Side objective spots, by kind. They fill the old nest1..nest4 site names in this order.
MapPlan.sides = {
	{ kind = "radar", at = V2(-100, -20), site = "nest1" }, -- on the old service road, west of the refinery
	{ kind = "jammer", at = V2(125, -120), site = "nest2" }, -- its circle (45-80 studs) covers the quarry
	{ kind = "foundry", at = V2(-5, -180), site = "nest3" }, -- north, between the mesa and the quarry
	{ kind = "any", at = V2(60, 110), site = "nest4" }, -- south, in the riverbed (nests / wreck / air defence)
}
MapPlan.samples = { V2(-40, 70), V2(110, 40), V2(40, -105) } -- samples1..3

-- Cells per place by difficulty 1..5 (totals 5 / 6 / 7 / 8 / 9, as HaulCells.COUNTS).
MapPlan.cells = {
	spilled = { 1, 1, 1, 1, 2 },
	mesa = { 1, 2, 2, 2, 2 },
	quarry = { 2, 2, 2, 3, 3 },
	graveyard = { 1, 1, 2, 2, 2 },
}

-- Dustbowl Ridge HAUL mission tuning (clues, per-site encounters, escalation, finale and mid-mission surprise).
MapPlan.haul = {
	revealDist = 120,
	closeRevealDist = 28,
	flightLogReveals = 2,
	cradleSeconds = 20,
	launchSeconds = 50,
	stormSeconds = 60,
	carryAttractRadius = 85,
	carryAttractMax = 3,
	encounterPool = { "courier", "cradle", "guardian", "buried" },
	fixedEncounters = { quarry = "pylons" },
}

-- Ground features (terrain only; World/Places adds the props along them).
-- riverbed: a dry channel ~22 wide, ~6 deep, gentle banks, west edge -> the salt pan.
MapPlan.riverbed = { V2(-250, 145), V2(-130, 135), V2(-10, 132), V2(90, 95), V2(160, 45), V2(215, 15) }
-- trails back to the refinery, one per cell place (so a carrier can follow the ground home):
MapPlan.trails = {
	{ name = "pylons", from = "mesa", style = "pylons" }, -- power pylons + cable (props), plain ground
	{ name = "haulRoad", from = "quarry", style = "road" }, -- flat packed road, ~10 wide
	{ name = "dragTracks", from = "graveyard", style = "tracks" }, -- two dark drag lines
	{ name = "serviceRoad", fromAt = V2(-240, -10), via = V2(-100, -20), style = "road" }, -- old road past the radar
}
-- debris trail: from the crash to its spilled cell (scorched ground + wreck bits)

-- Helpers ----------------------------------------------------------------------------------------------------------

-- the crash variant by name or index (nil -> the first)
function MapPlan.crash(which: (string | number)?): { name: string, crash: Vector2, spilled: Vector2 }
	if type(which) == "number" then
		return MapPlan.crashes[math.clamp(math.floor(which), 1, #MapPlan.crashes)]
	end
	for _, c in MapPlan.crashes do
		if c.name == which then
			return c
		end
	end
	return MapPlan.crashes[1]
end

-- ground-plane position of a named place ("refinery", "mesa", "quarry", "graveyard", "saltpan")
function MapPlan.at(name: string): Vector2?
	local p = MapPlan.places[name]
	return p and p.at
end

-- cell count for a place at a difficulty (1..5)
function MapPlan.cellCount(place: string, difficulty: number): number
	local row = MapPlan.cells[place]
	if not row then
		return 0
	end
	return row[math.clamp(math.floor(difficulty), 1, #row)]
end

-- the side spot for a side kind ("radar" / "jammer" / "foundry"), or nil
function MapPlan.sideSpot(kind: string): { kind: string, at: Vector2, site: string }?
	for _, s in MapPlan.sides do
		if s.kind == kind then
			return s
		end
	end
	return nil
end

return MapPlan
