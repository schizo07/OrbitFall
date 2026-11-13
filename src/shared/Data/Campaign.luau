-- DEV-SCRIPTED WAR CAMPAIGN (docs/spec.md §14).
-- This is the file the devs edit for each update. Add an operation, publish, done.
--
-- Operation fields:
--   id          unique, never reuse (outcomes are stored permanently by id)
--   planet      Data/Planets id
--   kind        "liberate"  community must push the planet to 100 % liberation before `ends`
--               "defend"    a FREE planet is under attack; community must reach 100 % defence before `ends`
--   faction     enemy faction fighting there ("COG" | "BROOD")
--   starts/ends unix seconds (UTC). Use https://www.unixtimestamp.com or os.time{...} in Studio
--   resist      % per hour the enemy claws back while the operation is live (pressure)
--   onSuccess   "liberated" (planet becomes FREE) | "held" (defence succeeded, stays FREE)
--   onFail      "destroyed" (planet becomes a burning ball, unplayable forever)
--               | "lost" (enemy takes/keeps the planet) | "nothing"
--   title, brief, successText, failText   shown on the war map and broadcast in-game
--   bonusTokens Bond Tokens given to everyone who completed at least one mission in the operation
--
-- Operations with no deadline-driven story can still be played: every enemy-held planet that isn't
-- destroyed can be liberated mission by mission (no decay outside operations).

export type Operation = {
	id: string,
	planet: string,
	kind: string,
	faction: string,
	starts: number,
	ends: number,
	resist: number,
	onSuccess: string,
	onFail: string,
	title: string,
	brief: string,
	successText: string,
	failText: string,
	bonusTokens: number?,
}

local DAY = 86400

-- Launch reference: change WAR_START to your release date (unix seconds) before publishing.
local WAR_START = 1794355200 -- 2026-11-11 00:00 UTC

local Campaign = {}

Campaign.WarStart = WAR_START

Campaign.Operations = {
	-- UPDATE 1 --------------------------------------------------------------------------------------
	{
		id = "U1_FERROX_CODES",
		planet = "FERROX",
		kind = "liberate",
		faction = "COG",
		starts = WAR_START,
		ends = WAR_START + 7 * DAY,
		resist = 0.25,
		onSuccess = "liberated",
		onFail = "destroyed",
		title = "Operation Cold Fuse",
		brief = "The Cogwork Legion stormed Ferrox Prime and seized the planetary missile launch codes. "
			.. "Liberate it before they arm the warheads and turn their missiles on us.",
		successText = "Ferrox Prime is FREE! The launch codes are back in our hands.",
		failText = "We ran out of time. The Legion launched - Ferrox Prime is gone, a burning ruin.",
		bonusTokens = 40,
	},
	{
		id = "U1_TESSALY_DEFENCE",
		planet = "TESSALY",
		kind = "defend",
		faction = "BROOD",
		starts = WAR_START + 2 * DAY,
		ends = WAR_START + 5 * DAY,
		resist = 0.4,
		onSuccess = "held",
		onFail = "lost",
		title = "Hold Tessaly",
		brief = "Brood burrows are breaking through Tessaly's farm moons. Drop in and push them back underground.",
		successText = "Tessaly holds! The Brood retreats into the dark.",
		failText = "Tessaly has fallen to the Skitter Brood.",
		bonusTokens = 25,
	},
	{
		id = "U1_GLASSMERE_TIDE",
		planet = "GLASSMERE",
		kind = "liberate",
		faction = "BROOD",
		starts = WAR_START + 1 * DAY,
		ends = WAR_START + 9 * DAY,
		resist = 0.3,
		onSuccess = "liberated",
		onFail = "nothing",
		title = "Operation Glass Tide",
		brief = "Brood egg-towers are rising out of Glassmere's melted dunes. Burn the hatcheries and take the glass flats "
			.. "back before the next swarm hatches.",
		successText = "Glassmere is FREE! The hatcheries are ash and the glass flats are ours again.",
		failText = "The swarm hatched. Glassmere stays in Brood hands - for now.",
		bonusTokens = 30,
	},
	{
		id = "U1_BRIGHTWATER_FROST",
		planet = "BRIGHTWATER",
		kind = "defend",
		faction = "COG",
		starts = WAR_START + 2 * DAY + DAY // 2,
		ends = WAR_START + 6 * DAY,
		resist = 0.35,
		onSuccess = "held",
		onFail = "lost",
		title = "Operation Frostwatch",
		brief = "Cogwork drill-walkers dropped from orbit onto Brightwater's ice shelf and are cutting toward the miners' "
			.. "habitats. Hold the shafts until the evacuation haulers are loaded.",
		successText = "Brightwater holds! The drill-walkers froze where they stood.",
		failText = "Brightwater's mines have fallen to the Cogwork Legion.",
		bonusTokens = 25,
	},
} :: { Operation }

function Campaign.get(id: string): Operation?
	for _, op in Campaign.Operations do
		if op.id == id then
			return op
		end
	end
	return nil
end

return Campaign
