-- First-time player hints, shown by client/UI/Tips.luau as a small card near the top of the screen.
-- Each hint:
--   id        unique key (session counts are kept per id)
--   trigger   what fires it; the detectors live in client/UI/Tips.luau:
--               start      the mission goes Active (after `delay` seconds)
--               lowMag     magazine at or under 25 % (and not empty)
--               noSpare    no spare ammo left for the weapon in hand, magazine half empty or less
--               hurt       health under 45 %, a stim left, not downed
--               exhausted  stamina ran out (jog-limp)
--               armed      a call-in is armed (beacon in hand)
--               downed     the local trooper goes down
--               mateDown   a squadmate goes down
--               mateOut    a squadmate is out (dead, not downed)
--               heavy      first heavy / behemoth contact callout (Fx "HeavyContact")
--               breach     the Director starts a breach (Store "intensity".state)
--               cell       the local trooper picks up a core cell (Player attribute CarryCell)
--               side       within SIDE_RANGE studs of an unfinished side objective marker
--               extract    the main objective is done (mission state Extract)
--               board      the Skiff is down and boarding (Store "mission".extract.window)
--   times     how many times per session it may show
--   priority  higher jumps the queue (default 1)
--   delay     seconds after the trigger before it is queued (default 0)
--   kb / pad / touch   text per input type. Tokens:
--               {press}     "Press" or "Hold" (the stim key is a hold when Downed.stimHold() > 0)
--               {interact}  the gamepad interact button (X, or D-pad Up with Studio A/B "PAD INTERACT" B)
--               {title}     the side objective's title (trigger side)
--   kbSlot / padSlot   optional text when the uplink uses the radial dial (Studio A/B "UPLINK ARM" B)
local Tips = {}

Tips.SIDE_RANGE = 45

export type Tip = {
	id: string,
	trigger: string,
	times: number,
	priority: number?,
	delay: number?,
	kb: string,
	pad: string,
	touch: string,
	kbSlot: string?,
	padSlot: string?,
}

Tips.list = {
	{
		id = "objective",
		trigger = "start",
		delay = 5,
		times = 2,
		kb = "Your objective is the cyan marker on the compass. Follow it.",
		pad = "Your objective is the cyan marker on the compass. Follow it.",
		touch = "Your objective is the cyan marker on the compass. Follow it.",
	},
	{
		id = "callin",
		trigger = "start",
		delay = 25,
		times = 2,
		kb = "Call-ins: hold Q, type the arrow code with WASD, then left-click to throw the beacon.",
		pad = "Call-ins: hold LB, type the arrow code on the D-pad, then RT to throw the beacon.",
		touch = "Call-ins: tap UPLINK, pick one, then tap FIRE to throw the beacon.",
		kbSlot = "Call-ins: hold Q, point at one and let go, then left-click to throw the beacon.",
		padSlot = "Call-ins: hold LB, point at one and let go, then RT to throw the beacon.",
	},
	{
		id = "beacon",
		trigger = "armed",
		times = 1,
		kb = "Throw the beacon where you want the call-in to land. R cancels.",
		pad = "Throw the beacon where you want the call-in to land. X cancels.",
		touch = "Throw the beacon where you want the call-in to land.",
	},
	{
		id = "lowMag",
		trigger = "lowMag",
		times = 1,
		kb = "Magazine low. Press R to reload before you run dry.",
		pad = "Magazine low. Press X to reload before you run dry.",
		touch = "Magazine low. Tap RELOAD before you run dry.",
	},
	{
		id = "noSpare",
		trigger = "noSpare",
		times = 2,
		kb = "No spare ammo. Swap weapons (1-3), grab ammo boxes, or call in a Supply Drop.",
		pad = "No spare ammo. Swap weapons (Y), grab ammo boxes, or call in a Supply Drop.",
		touch = "No spare ammo. Tap SWAP, grab ammo boxes, or call in a Supply Drop.",
	},
	{
		id = "hurt",
		trigger = "hurt",
		priority = 2,
		times = 2,
		kb = "Hurt. {press} F to use a stim and heal.",
		pad = "Hurt. {press} D-pad Left to use a stim and heal.",
		touch = "Hurt. {press} STIM to heal.",
	},
	{
		id = "tired",
		trigger = "exhausted",
		times = 1,
		kb = "Out of breath. Stop sprinting for a moment to get your stamina back.",
		pad = "Out of breath. Stop sprinting for a moment to get your stamina back.",
		touch = "Out of breath. Stop sprinting for a moment to get your stamina back.",
	},
	{
		id = "downed",
		trigger = "downed",
		priority = 3,
		times = 1,
		kb = "You're down. Crawl to cover, keep shooting with your sidearm. A squadmate can revive you.",
		pad = "You're down. Crawl to cover, keep shooting with your sidearm. A squadmate can revive you.",
		touch = "You're down. Crawl to cover, keep shooting with your sidearm. A squadmate can revive you.",
	},
	{
		id = "mateDown",
		trigger = "mateDown",
		priority = 3,
		times = 2,
		kb = "A squadmate is down. Get to them and hold E to revive.",
		pad = "A squadmate is down. Get to them and hold {interact} to revive.",
		touch = "A squadmate is down. Get to them and hold the revive prompt.",
	},
	{
		id = "mateOut",
		trigger = "mateOut",
		priority = 2,
		times = 1,
		kb = "Squadmate out. Call in a Reinforce to bring them back.",
		pad = "Squadmate out. Call in a Reinforce to bring them back.",
		touch = "Squadmate out. Call in a Reinforce to bring them back.",
	},
	{
		id = "heavy",
		trigger = "heavy",
		priority = 2,
		times = 2,
		kb = "Heavy enemy. Its armour stops light rounds: aim for weak spots, or use grenades and call-ins.",
		pad = "Heavy enemy. Its armour stops light rounds: aim for weak spots, or use grenades and call-ins.",
		touch = "Heavy enemy. Its armour stops light rounds: aim for weak spots, or use grenades and call-ins.",
	},
	{
		id = "breach",
		trigger = "breach",
		priority = 2,
		times = 1,
		kb = "Breach! A big wave is coming from the red arrow. Find cover or keep moving.",
		pad = "Breach! A big wave is coming from the red arrow. Find cover or keep moving.",
		touch = "Breach! A big wave is coming from the red arrow. Find cover or keep moving.",
	},
	{
		id = "cell",
		trigger = "cell",
		priority = 2,
		times = 1,
		kb = "Carrying a core cell: hip-fire only (1 cell), no weapons at 2 cells. Take it to the lifter. E or G drops it.",
		pad = "Carrying a core cell: hip-fire only (1 cell), no weapons at 2 cells. Take it to the lifter. R1 drops it.",
		touch = "Carrying a core cell: hip-fire only (1 cell), no weapons at 2 cells. Take it to the lifter. GRENADE drops it.",
	},
	{
		id = "side",
		trigger = "side",
		times = 2,
		kb = "Side objective nearby: {title}. Optional, but it pays.",
		pad = "Side objective nearby: {title}. Optional, but it pays.",
		touch = "Side objective nearby: {title}. Optional, but it pays.",
	},
	{
		id = "extract",
		trigger = "extract",
		priority = 2,
		delay = 3,
		times = 1,
		kb = "Main objective done. Go to the extraction pad and hold E on the terminal to call the Skiff.",
		pad = "Main objective done. Go to the extraction pad and hold {interact} on the terminal to call the Skiff.",
		touch = "Main objective done. Go to the extraction pad and hold the terminal prompt to call the Skiff.",
	},
	{
		id = "board",
		trigger = "board",
		priority = 3,
		times = 1,
		kb = "The Skiff is down. Get on the ramp before it leaves.",
		pad = "The Skiff is down. Get on the ramp before it leaves.",
		touch = "The Skiff is down. Get on the ramp before it leaves.",
	},
} :: { Tip }

Tips.byId = {} :: { [string]: Tip }
for _, t in Tips.list do
	Tips.byId[t.id] = t
end

return Tips
