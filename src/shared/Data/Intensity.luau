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

Intensity.Calm = { min = 40, max = 70 } -- quiet stretch between incidents
Intensity.Build = { min = 14, max = 20 } -- warning phase (rumble / signal spike, patrols ramp up)
Intensity.Breach = { min = 30, max = 45 } -- the directional wave
Intensity.Relax = { min = 14, max = 24, clearFraction = 0.25 } -- mop-up; ends early once live enemies < clearFraction * cap (after `min`)

Intensity.DiffScale = 0.07
Intensity.PlayerScale = 0.06
Intensity.CalmMinScaled = 26 -- calm never shrinks below this (except while the mission timer is critical)

-- patrol-rate multiplier (divides the patrol interval) and patrol budget multiplier per state
Intensity.PatrolRate = { calm = 0.5, build = 1.6, breach = 0.35, relax = 0.7 }
Intensity.PatrolBudget = { calm = 0.7, build = 1.15, breach = 0.8, relax = 0.7 }

-- breach waves: one big group-wave every `interval` seconds from one compass side of the squad
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
	heavyChance = 0.7,
	behemothChance = 0.55,
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

-- objective hooks: Director.objectiveEvent(name). `force` = start a breach (after a short BUILD of `delay` s), `bring` = pull the next
-- CALM -> BUILD forward by that many seconds. Ignored while a BUILD/BREACH/extraction hold is already running; during RELAX a forced
-- event is queued and fires as soon as CALM begins.
Intensity.Events = {
	DEFEND_START = { force = true, delay = 5 }, -- generator spin-up / data upload begins
	MAIN_STEP = { bring = 20 }, -- any main-objective step completed
	FINAL_STEPS = { force = true, delay = 7 }, -- the launch / last-but-one step completed
	SAMPLE = { bring = 9 }, -- a sample picked up
	SIDE_DONE = { bring = 14 }, -- nest / fabricator destroyed
	LOUD = { bring = 12 }, -- anything noisy (beacon throws etc.)
	TIME_CRITICAL = { force = true, delay = 6, ignoreCooldown = true }, -- fired by the Director itself when the mission clock drops under TimerCriticalSec
}
Intensity.ForceCooldown = 50 -- seconds after a breach ends before a forced event may fire another

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
