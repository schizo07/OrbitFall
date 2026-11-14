-- Combat pacing tunables (Phase 2: the intensity state machine in server/Enemies/Director.luau).
--
--   CALM -> BUILD -> BREACH -> RELAX -> CALM ...        (and EXTRACT: continuous BREACH until the shuttle lifts off)
--
-- Everything is in seconds unless noted. `scale` = 1 + DiffScale * (difficulty - 1) + PlayerScale * (players - 1); long
-- phases (CALM) shrink and big ones (BREACH wave budget) grow with it.
-- Client presentation (HUD strip / banners / music) lives in client/Fx/IntensityFx.luau and reads the replicated
-- Store key "intensity" (see Director.snapshot) + the Fx kind "HeavyContact" (plus the existing Shake / Sound / Shockwave /
-- Debris / DropPod / Breach kinds).

local Intensity = {}

-- Director v2 (docs/intensity-spec.md section 2): fights are local, dense and spiky. CALM = patrols crossing the squad's path, BREACH
-- = 2-3 breach SOURCES (holes / drop pods / rift shards) 35-55 studs away that emit fodder bursts until the squad closes them.
Intensity.Calm = { min = 20, max = 35 } -- quiet stretch between incidents
Intensity.Build = { min = 8, max = 10 } -- warning phase (rumble / signal spike, one more patrol)
Intensity.Breach = { min = 30, max = 45 } -- the breach (ends early when every source is closed)
-- mop-up; units beyond the straggler count (far first, then fodder past fodderScatterDist) are quietly removed, re-checked every trimEvery s
Intensity.Relax = { min = 10, max = 10, stragglersMin = 6, stragglersMax = 10, fodderScatterDist = 18, regularScatterDist = 35, trimEvery = 2 }

Intensity.DiffScale = 0.07
Intensity.PlayerScale = 0.06
Intensity.CalmMinScaled = 14 -- calm never shrinks below this (except while the mission timer is critical)

-- CALM / BUILD patrols: a group of `count` units spawns `dist` studs from the squad (to the side of its heading) and walks ACROSS its path
Intensity.Patrol = {
	calmInterval = 14, -- seconds between patrols in CALM
	buildInterval = 6, -- ... and in BUILD (the field fills up)
	firstDelay = 8, -- first patrol this long after the mission starts
	count = { min = 5, max = 8 },
	mediumChance = 0.25, -- per member (the rest are regulars)
	dist = { min = 90, max = 120 },
	sideDeg = { min = 55, max = 110 }, -- spawn angle off the squad's heading (either side)
	ahead = { min = 15, max = 40 }, -- the walk target sits this far ahead of the squad, so the patrol crosses its path
	overshoot = { min = 35, max = 60 }, -- ... and this far past it on the other side
	minHeadingSpeed = 2.5, -- studs/s: below this the squad has no heading and the patrol comes from a random side
	crossFor = 6, -- seconds the patrol ignores the squad (unless shot at) so it really walks across instead of charging at once
}

-- Breach sources (server/Enemies/BreachSources.luau; emission is driven by the Director)
Intensity.Sources = {
	count = { min = 2, max = 3 }, -- 3 gets likelier with difficulty / party size
	threeBase = 0.35,
	threePerDifficulty = 0.1,
	threePerPlayer = 0.1,
	distMin = 35, -- studs from the squad centroid
	distMax = 55,
	arcDeg = 90, -- the sources sit in this arc centred on the breach bearing
	minSpacing = 18, -- between two sources
	candidates = 28, -- placement samples per source
	hp = 600, -- base HP (a frag grenade does ~400 at the centre; two close it)
	hpPerDifficulty = 0.1, -- +10 % per difficulty step above 1
	hpPerPlayer = 0.12, -- +12 % per extra player
	hitRadius = 5.5, -- explosion distances are measured to this radius around the source centre
	descent = { COG = 2.0, BROOD = 0.8, LUMEN = 1.2 }, -- seconds before a source starts to emit (COG: drop-pod descent)
	openStagger = 0.9, -- seconds between the sources opening
	-- emission: bursts of `on` seconds then `off` seconds of silence
	burstOn = 12,
	burstOff = 4,
	fodderEvery = 2.5, -- seconds between fodder batches while a burst is on
	fodderCount = { min = 4, max = 6 },
	fodderSoloMult = 0.6, -- batch size multiplier for a solo player ...
	fodderPerPlayerMult = 0.15, -- ... + this per extra player (capped at 1)
	eliteEvery = 10, -- one elite (the faction's medium) per source this often
	heavyAt = 15, -- seconds into the breach the heavy shows up (once per breach) ...
	heavyMinDifficulty = 4, -- ... on this difficulty and above
	spawnRing = { min = 2.5, max = 7 }, -- fodder appear this far from the source centre
	extraBurst = 6, -- fodder added instantly to the nearest source when a spotted-reinforce call lands during a breach
	closeDelay = 0.2, -- seconds a closing source needs to collapse
}

-- breach waves (LEGACY / fallback: only used when no breach source could be placed, and by the extraction hold-out): one big
-- group-wave every `interval` seconds from one compass side of the squad
Intensity.BreachWave = {
	interval = 6.5, -- base seconds between waves (shrinks a little with difficulty)
	intervalMin = 4.5,
	baseBudget = 13, -- before player / difficulty / escalation scaling
	perPlayer = 4,
	perDifficulty = 2.5,
	escalation = 0.12, -- +12 % budget per wave inside one breach
	firstWaveMult = 1.35, -- the opening punch
	distMin = 85, -- spawn ring: distance from the squad centroid along the breach bearing
	distMax = 125,
	spreadDeg = 38, -- half-angle of the arc the groups pour out of
	capMult = 1.2, -- the live cap is raised by this much during a breach (never above CapMax + CapOver)
	capOver = 8,
	heavyChance = 0.62, -- compose() odds (normal 0.5)
	behemothChance = 0.5, -- (normal 0.4)
}

-- extraction hold-out: continuous escalating breach waves from the call until liftoff
Intensity.Extract = {
	firstDelay = 3,
	interval = 7,
	intervalMin = 4.2,
	intervalStep = 0.35, -- faster by this much per wave
	baseBudget = 14,
	escalation = 0.16,
	maxMult = 2.4,
	rotateEvery = 2, -- waves between compass-side changes (flanking)
	capMult = 1.3,
	capFloor = 48, -- the live cap never drops below this during the hold-out
	heavyChance = 0.7,
	behemothChance = 0.55,
	distMin = 62, -- the directional waves pour in closer than a normal breach wave (proximity budget)
	distMax = 90,
	-- the hold-out also keeps breach sources open: every `sourceEvery` seconds the missing ones re-open (up to `maxSources` at once)
	sourceEvery = 20,
	maxSources = 3,
	sourceDistMin = 30,
	sourceDistMax = 45,
	firstSources = 2, -- opened right after `firstDelay`
}

-- heavy / behemoth entrance (only while BUILD / BREACH / EXTRACT)
Intensity.Heavy = {
	calloutRange = 120, -- players within this many studs get "HEAVY CONTACT"
	extraDelay = 1.1, -- heavy appears this long after the rest of its group (the roar + ground burst telegraph)
	podFall = 2.0, -- robot drop-pod fall time
	shockR = { heavy = 18, behemoth = 30 },
	shake = { heavy = 3.4, behemoth = 5.5 }, -- Juice.shake falls off with distance squared, so the peak is high
	shakeRange = 170,
}

-- objective hooks: Director.objectiveEvent(name). `force` = start a BUILD within `Intensity.ForceWithin` seconds (its length is `delay`
-- clamped to Intensity.Build), `bring` = pull the next CALM -> BUILD forward by that many seconds. Ignored while a BUILD/BREACH/
-- extraction hold is already running; during RELAX a forced event is queued and fires as soon as CALM begins.
Intensity.Events = {
	DEFEND_START = { force = true, delay = 8 }, -- generator spin-up / data upload begins
	MAIN_STEP = { force = true, delay = 9 }, -- any main-objective step completed (terminal, ...)
	FINAL_STEPS = { force = true, delay = 8 }, -- the launch / last-but-one step completed
	SAMPLE = { bring = 9 }, -- a sample picked up
	SIDE_DONE = { bring = 14 }, -- nest / fabricator destroyed
	LOUD = { bring = 12 }, -- anything noisy (beacon throws etc.)
	TIME_CRITICAL = { force = true, delay = 8, ignoreCooldown = true }, -- fired by the Director itself when the mission clock drops under TimerCriticalSec
}
Intensity.ForceCooldown = 30 -- seconds after a breach ends before a forced event starts a BUILD at once (inside the cooldown it only pulls CALM to ForceWithin)
Intensity.ForceWithin = 10 -- a forced event always leads to a BUILD within this many seconds

Intensity.SpottedBring = 6 -- every "spotted -> reinforcements" call counts: pulls CALM forward by this many seconds
Intensity.SpottedBringMax = 18 -- total pull-forward allowed per CALM phase
Intensity.SpottedBreachExtend = 1.5 -- seconds added to a running BREACH per spotted call (max 10 s total)

Intensity.TimerCriticalSec = 180 -- mission time left: below this a breach is forced and CALM is halved
Intensity.TimerCriticalCalmMult = 0.45

-- Faction flavour for the warning phase. title/sub are shown on the HUD strip; sound is an Audio key (client/Audio + shared/Sounds).
Intensity.Warnings = {
	BROOD = { title = "SEISMIC ACTIVITY", sub = "tremors below", sound = "WarnRumble" },
	COG = { title = "SIGNAL SPIKE", sub = "dropships inbound", sound = "WarnMachinery" },
	LUMEN = { title = "RIFT FLUX", sub = "space is folding", sound = "WarnMachinery" },
}
Intensity.WarningDefault = Intensity.Warnings.COG

Intensity.CompassNames = { "NORTH", "NORTH-EAST", "EAST", "SOUTH-EAST", "SOUTH", "SOUTH-WEST", "WEST", "NORTH-WEST" }
Intensity.CompassShort = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

-- Bearing convention = the HUD compass: 0 = -Z (N), 90 = +X (E), clockwise.
function Intensity.bearingVector(bearingDeg: number): Vector3
	local r = math.rad(bearingDeg)
	return Vector3.new(math.sin(r), 0, -math.cos(r))
end

function Intensity.bearingOf(v: Vector3): number
	return (math.deg(math.atan2(v.X, -v.Z)) + 360) % 360
end

function Intensity.compassIndex(bearingDeg: number): number
	return math.floor(((bearingDeg % 360) + 22.5) / 45) % 8 + 1
end

function Intensity.compassName(bearingDeg: number): string
	return Intensity.CompassNames[Intensity.compassIndex(bearingDeg)]
end

function Intensity.compassShort(bearingDeg: number): string
	return Intensity.CompassShort[Intensity.compassIndex(bearingDeg)]
end

return Intensity
