--!nocheck
-- Sound catalogue (docs/spec.md §10). Consumed by src/client/Audio.luau.
--
-- Every layer has `id = ""` until a verified asset id ("rbxassetid://123") is filled in.
-- The engine silently skips empty ids, so the game runs (silently) with this file as-is.
-- `desc` says what to search for in the Creator Store.
--
-- Layer fields:
--   id        "rbxassetid://..." or "" (skipped)
--   desc      what the sound should be (for the asset search)
--   vol       base volume 0..~1.5 (default 1)
--   pitch     {min, max} playback speed range (default {0.95, 1.05}); number = fixed
--   delay     seconds (number) or {min, max} random (default 0)
--   group     SoundGroup name (defaults to the key's group)
--   minDist / maxDist   3D rolloff (default 10 / 450)
--   chance    0..1 probability the layer plays (default 1)
--   far       true = only plays when the listener is farther than key.farDist
--   near      true = only plays within key.nearDist; if also pitched <= 0.65 (sub-bass) or `felt = true`,
--             a quiet non-positional copy plays too so you FEEL the thump
--   loop      true = layer loops (Audio.loop / Audio.setMusic)
--   volVar    random volume variance, default 0.1 (±10 %)
-- Key fields:
--   limit     {count, window}: at most `count` plays per `window` seconds (per source if perSource)
--   perSource limit is counted per opts.source instead of globally
--   priority  1..5 (5 = never culled first); used when the 48-voice cap is hit
--   nearDist / farDist  thresholds for near/far layers (defaults 40 / 120)
--   duck      {groups = {...}, db = -6, seconds = 0.4} automatic ducking when this key plays
--   group     default group for layers

export type Layer = {
	id: string,
	desc: string?,
	vol: number?,
	pitch: (number | { number })?,
	delay: (number | { number })?,
	group: string?,
	minDist: number?,
	maxDist: number?,
	chance: number?,
	far: boolean?,
	near: boolean?,
	loop: boolean?,
	volVar: number?,
}
export type Entry = {
	layers: { Layer },
	limit: { count: number, window: number }?,
	perSource: boolean?,
	priority: number?,
	nearDist: number?,
	farDist: number?,
	duck: { groups: { string }, db: number, seconds: number }?,
	group: string?,
}

-- Builds an entry: group/priority/limit applied, per-layer group defaulted.
local function K(group: string, priority: number, layers: { any }, extra: { [string]: any }?): Entry
	for _, l in layers do
		l.group = l.group or group
		if l.id == nil then
			l.id = ""
		end
	end
	local e: any = { layers = layers, priority = priority, group = group }
	if extra then
		for k, v in extra do
			e[k] = v
		end
	end
	return e
end

local GUN = { count = 5, window = 0.25 } -- ~20 shots/s per owner
local HIT = { count = 4, window = 0.3 }
local BOOM = { count = 6, window = 0.25 }
local W, I, X, E, C, U, A, M = "Weapons", "Impacts", "Explosions", "Enemies", "CallIns", "UI", "Ambience", "Music"

local S: { [string]: Entry } = {

	-- WEAPONS ----------------------------------------------------------------------
	ShotRifle = K(W, 2, {
		{ id = "rbxassetid://18835647605", desc = "sharp rifle crack, short transient, dry", vol = 0.9, pitch = { 0.96, 1.04 } },
		{ id = "rbxassetid://88162798516964", desc = "rifle shot low body thump, punchy", vol = 0.7, pitch = { 0.9, 1.0 } },
		{ id = "rbxassetid://134975275558568", desc = "mechanical bolt/action click", vol = 0.3, near = true, pitch = { 0.95, 1.1 }, maxDist = 60 },
		{ id = "rbxassetid://88162798516964", desc = "felt sub-bass punch (shooter only)", vol = 0.5, near = true, felt = true, pitch = { 0.55, 0.62 }, maxDist = 40 },
		{ id = "rbxassetid://18835710353", desc = "distant muffled rifle shot with echo tail", vol = 0.6, far = true, delay = 0.1, maxDist = 900 },
	}, { limit = GUN, perSource = true, nearDist = 30, farDist = 130 }),

	ShotShotgun = K(W, 3, {
		{ id = "rbxassetid://5651137842", desc = "shotgun blast crack, loud and snappy", vol = 1.0, pitch = { 0.95, 1.03 } },
		{ id = "rbxassetid://18878161489", desc = "shotgun boom low body thump", vol = 0.85, pitch = { 0.85, 0.95 } },
		{ id = "rbxassetid://113837896417526", desc = "shotgun pump action rack click", vol = 0.5, near = true, delay = 0.38, maxDist = 60 },
		{ id = "rbxassetid://5651137842", desc = "distant muffled shotgun boom echo", vol = 0.6, far = true, delay = 0.12, maxDist = 900 },
	}, { limit = { count = 3, window = 0.25 }, perSource = true, nearDist = 30, farDist = 130 }),

	ShotSMG = K(W, 2, {
		{ id = "rbxassetid://79266532175234", desc = "light submachine gun shot, short snappy burst crack", vol = 0.8, pitch = { 0.95, 1.08 } },
		{ id = "rbxassetid://77130830495173", desc = "small gun low thump body", vol = 0.5, pitch = { 1.0, 1.1 } },
		{ id = "rbxassetid://77130830495173", desc = "felt sub-bass punch (shooter only)", vol = 0.35, near = true, felt = true, pitch = { 0.6, 0.66 }, maxDist = 40 },
		{ id = "rbxassetid://79266532175234", desc = "distant muffled smg shot", vol = 0.5, far = true, delay = 0.1, maxDist = 800 },
	}, { limit = { count = 6, window = 0.25 }, perSource = true, farDist = 120 }),

	ShotMarksman = K(W, 3, {
		{ id = "rbxassetid://98063753863205", desc = "sniper rifle supersonic crack, sharp and loud", vol = 1.0, pitch = { 0.97, 1.03 } },
		{ id = "rbxassetid://133904008738767", desc = "heavy rifle boom body, deep", vol = 0.85, pitch = { 0.8, 0.9 } },
		{ id = "rbxassetid://98063753863205", desc = "rifle bolt action cycle clack", vol = 0.45, near = true, delay = 0.3, maxDist = 60 },
		{ id = "rbxassetid://133904008738767", desc = "long outdoor sniper shot echo/reverb tail", vol = 0.7, far = true, delay = 0.2, maxDist = 1000 },
	}, { limit = { count = 3, window = 0.3 }, perSource = true, nearDist = 30, farDist = 100 }),

	ShotPistol = K(W, 2, {
		{ id = "rbxassetid://89214508659473", desc = "pistol shot crack, crisp", vol = 0.85, pitch = { 0.95, 1.05 } },
		{ id = "rbxassetid://138905044369113", desc = "pistol low thump body", vol = 0.55, pitch = { 0.9, 1.0 } },
		{ id = "rbxassetid://89214508659473", desc = "distant muffled pistol shot", vol = 0.5, far = true, delay = 0.1, maxDist = 700 },
	}, { limit = { count = 4, window = 0.25 }, perSource = true, farDist = 110 }),

	ShotPistolHeavy = K(W, 3, {
		{ id = "rbxassetid://18918494387", desc = "magnum revolver blast crack, big", vol = 0.95, pitch = { 0.9, 1.0 } },
		{ id = "rbxassetid://3292839892", desc = "explosive round pop plus small boom", vol = 0.8, pitch = { 0.85, 0.95 }, delay = 0.02 },
		{ id = "rbxassetid://18918494387", desc = "heavy low thump", vol = 0.7, near = true, pitch = { 0.55, 0.65 } },
		{ id = "rbxassetid://3292839892", desc = "distant muffled magnum shot echo", vol = 0.5, far = true, delay = 0.12, maxDist = 800 },
	}, { limit = { count = 3, window = 0.25 }, perSource = true }),

	ShotRocket = K(W, 4, {
		{ id = "rbxassetid://12222065", desc = "rocket launcher fire whoomp, thick", vol = 1.0, pitch = { 0.95, 1.03 } },
		{ id = "rbxassetid://140307246312623", desc = "rocket whoosh/exhaust trail hiss", vol = 0.7, delay = 0.05, pitch = { 0.9, 1.05 } },
		{ id = "rbxassetid://12222065", desc = "launcher sub thump", vol = 0.7, near = true, pitch = { 0.55, 0.65 } },
		{ id = "rbxassetid://140307246312623", desc = "distant muffled rocket launch", vol = 0.55, far = true, delay = 0.15, maxDist = 900 },
	}, { limit = { count = 2, window = 0.4 }, perSource = true, nearDist = 40, farDist = 140 }),

	ShotGatling = K(W, 2, {
		{ id = "rbxassetid://138382899505069", desc = "minigun / gatling gun single shot burst, snappy", vol = 0.75, pitch = { 0.93, 1.07 } },
		{ id = "rbxassetid://139941137246408", desc = "heavy machine gun low thump body", vol = 0.6, pitch = { 0.8, 0.95 } },
		{ id = "rbxassetid://138382899505069", desc = "gatling barrel whirring motor", vol = 0.25, near = true, pitch = { 0.95, 1.1 }, maxDist = 80 },
		{ id = "rbxassetid://139941137246408", desc = "distant muffled machine gun fire", vol = 0.5, far = true, delay = 0.12, maxDist = 900 },
	}, { limit = { count = 7, window = 0.25 }, perSource = true, farDist = 120 }),

	ShotRail = K(W, 4, {
		{ id = "rbxassetid://77016949836420", desc = "sci-fi railgun discharge, sharp electric crack", vol = 1.0, pitch = { 0.97, 1.03 } },
		{ id = "rbxassetid://104211574669495", desc = "sci-fi heavy energy boom low", vol = 0.8, pitch = { 0.7, 0.85 } },
		{ id = "rbxassetid://77016949836420", desc = "electric crackle zap decay", vol = 0.5, delay = 0.08, pitch = { 1.0, 1.2 } },
		{ id = "rbxassetid://104211574669495", desc = "distant sci-fi cannon boom", vol = 0.6, far = true, delay = 0.15, maxDist = 1000 },
	}, { limit = { count = 2, window = 0.4 }, perSource = true }),

	ShotVolt = K(W, 2, {
		{ id = "rbxassetid://92090867642655", desc = "sci-fi laser pulse zap, electric", vol = 0.85, pitch = { 0.95, 1.1 } },
		{ id = "rbxassetid://97096310054904", desc = "electric arc crackle short", vol = 0.5, delay = 0.02, pitch = { 1.0, 1.25 } },
		{ id = "rbxassetid://92090867642655", desc = "distant electric zap", vol = 0.5, far = true, delay = 0.1, maxDist = 700 },
	}, { limit = { count = 5, window = 0.25 }, perSource = true }),

	Reload = K(W, 2, {
		{ id = "rbxassetid://9113104176", desc = "magazine eject click and slap new magazine", vol = 0.7, pitch = { 0.95, 1.05 }, minDist = 6, maxDist = 120 },
		{ id = "rbxassetid://137782748730401", desc = "short mechanical clack", vol = 0.4, delay = 0.35, minDist = 6, maxDist = 120 },
	}, { limit = { count = 2, window = 0.3 }, perSource = true }),

	ReloadEnd = K(W, 2, {
		{ id = "rbxassetid://104732809594116", desc = "rifle charging handle rack, satisfying chunk", vol = 0.8, pitch = { 0.95, 1.05 }, minDist = 6, maxDist = 120 },
	}, { limit = { count = 2, window = 0.3 }, perSource = true }),

	DryFire = K(W, 2, {
		{ id = "rbxassetid://90499731723010", desc = "empty gun dry fire click, hollow", vol = 0.6, pitch = { 0.95, 1.05 }, minDist = 6, maxDist = 100 },
	}, { limit = { count = 3, window = 0.25 }, perSource = true }),

	Swap = K(W, 2, {
		{ id = "rbxassetid://99050406637477", desc = "weapon swap/draw rustle and metal clack", vol = 0.55, pitch = { 0.95, 1.05 }, minDist = 6, maxDist = 100 },
	}, { limit = { count = 2, window = 0.3 }, perSource = true }),

	Grenade = K(W, 2, {
		{ id = "rbxassetid://113843307673576", desc = "grenade throw whoosh with pin pull ping", vol = 0.7, pitch = { 0.95, 1.05 }, minDist = 8, maxDist = 150 },
	}, { limit = { count = 3, window = 0.3 } }),

	TurretFire = K(W, 2, {
		{ id = "rbxassetid://6224645687", desc = "automated sentry turret machine gun burst shot, mechanical", vol = 0.75, pitch = { 0.95, 1.1 } },
		{ id = "rbxassetid://109055416264229", desc = "turret servo/mech clank", vol = 0.3, near = true, pitch = { 0.9, 1.1 }, maxDist = 80 },
		{ id = "rbxassetid://6224645687", desc = "distant muffled machine gun fire", vol = 0.45, far = true, delay = 0.1, maxDist = 800 },
	}, { limit = { count = 6, window = 0.25 }, perSource = true }),

	-- IMPACTS ----------------------------------------------------------------------
	HitPen = K(I, 2, {
		{ id = "rbxassetid://9116673678", desc = "bullet impact crunch, meaty, medium", vol = 0.8, pitch = { 0.9, 1.1 }, maxDist = 250 },
		{ id = "rbxassetid://123559569929123", desc = "short sharp thwack transient", vol = 0.4, pitch = { 1.0, 1.2 }, maxDist = 200 },
	}, { limit = HIT }),

	HitPartial = K(I, 1, {
		{ id = "rbxassetid://9120885468", desc = "dull thud on armour, muted", vol = 0.7, pitch = { 0.85, 1.0 }, maxDist = 220 },
	}, { limit = HIT }),

	HitDeflect = K(I, 2, {
		{ id = "rbxassetid://7842386350", desc = "bullet ricochet metal tink, bright", vol = 0.85, pitch = { 0.9, 1.25 }, maxDist = 250 },
		{ id = "rbxassetid://7842389592", desc = "ricochet whine ping, short, descending", vol = 0.5, delay = 0.02, pitch = { 0.9, 1.2 }, maxDist = 200 },
	}, { limit = { count = 3, window = 0.4 } }),

	HitWeak = K(I, 3, {
		{ id = "rbxassetid://103516326607012", desc = "bright critical hit ding, bell-like, satisfying", vol = 0.8, pitch = { 1.0, 1.15 }, minDist = 20, maxDist = 300 },
		{ id = "rbxassetid://81933188942245", desc = "crisp pop crunch", vol = 0.5, pitch = { 1.0, 1.2 }, maxDist = 200 },
	}, { limit = { count = 3, window = 0.3 } }),

	HitGoo = K(I, 2, {
		{ id = "rbxassetid://75221355097604", desc = "wet squish splat, small, gooey", vol = 0.8, pitch = { 0.9, 1.15 }, maxDist = 220 },
		{ id = "rbxassetid://9114519753", desc = "short crunchy bug shell crack", vol = 0.4, pitch = { 0.95, 1.1 }, maxDist = 180 },
	}, { limit = HIT }),

	HitMetal = K(I, 2, {
		{ id = "rbxassetid://98609496290942", desc = "metal bullet impact clang crunch, robot", vol = 0.8, pitch = { 0.9, 1.15 }, maxDist = 250 },
		{ id = "rbxassetid://110295421669790", desc = "small metal debris tinkle", vol = 0.3, delay = { 0.03, 0.08 }, pitch = { 1.0, 1.3 }, maxDist = 150 },
	}, { limit = HIT }),

	HitGround = K(I, 1, {
		{ id = "rbxassetid://9120885468", desc = "bullet hitting dirt, dull thump with grit", vol = 0.55, pitch = { 0.9, 1.15 }, maxDist = 150 },
	}, { limit = { count = 3, window = 0.3 } }),

	BoltImpact = K(I, 2, {
		{ id = "rbxassetid://201858087", desc = "sci-fi blaster bolt impact, sizzling zap burst", vol = 0.75, pitch = { 0.95, 1.1 }, maxDist = 250 },
		{ id = "rbxassetid://71947288327190", desc = "small spark crackle", vol = 0.35, delay = 0.03, pitch = { 1.0, 1.3 }, maxDist = 150 },
	}, { limit = { count = 4, window = 0.3 } }),

	GrenadeBounce = K(I, 1, {
		{ id = "rbxassetid://9113133597", desc = "grenade bouncing metal clink on ground", vol = 0.6, pitch = { 0.9, 1.15 }, maxDist = 120 },
	}, { limit = { count = 3, window = 0.3 } }),

	Kill = K(I, 3, {
		{ id = "rbxassetid://140323850218372", desc = "satisfying pop / burst, short", vol = 0.7, pitch = { 0.95, 1.1 }, maxDist = 250 },
		{ id = "rbxassetid://72264591133889", desc = "scrap metal clatter small", vol = 0.5, delay = { 0.03, 0.1 }, pitch = { 0.9, 1.15 }, maxDist = 200 },
	}, { limit = { count = 4, window = 0.3 } }),

	KillWeak = K(I, 3, {
		{ id = "rbxassetid://4612374393", desc = "bright critical kill ding, bell-like, rewarding", vol = 0.8, pitch = { 1.05, 1.2 }, minDist = 20, maxDist = 300 },
		{ id = "rbxassetid://4612374495", desc = "satisfying pop burst", vol = 0.6, pitch = { 1.0, 1.15 }, maxDist = 250 },
	}, { limit = { count = 3, window = 0.3 } }),

	Footstep = K(I, 1, {
		{ id = "rbxassetid://98912102275037", desc = "boot footstep on dirt/gravel, soft", vol = 0.35, pitch = { 0.85, 1.15 }, minDist = 4, maxDist = 60, volVar = 0.2 },
	}, { limit = { count = 4, window = 0.3 } }),

	Jump = K(I, 1, {
		{ id = "rbxassetid://135162567109750", desc = "short jump grunt-less cloth whoosh and boot push", vol = 0.35, pitch = { 0.95, 1.1 }, minDist = 4, maxDist = 60 },
	}, { limit = { count = 3, window = 0.3 } }),

	Land = K(I, 1, {
		{ id = "rbxassetid://9119641416", desc = "boots landing thud on dirt with gear rattle", vol = 0.5, pitch = { 0.9, 1.1 }, minDist = 4, maxDist = 70 },
	}, { limit = { count = 3, window = 0.3 } }),

	PlayerHurt = K(I, 5, {
		{ id = "rbxassetid://123559569929123", desc = "armour hit thump with grunt-less impact, hurt feedback", vol = 0.9, pitch = { 0.9, 1.05 } },
		{ id = "rbxassetid://9119641545", desc = "short electrical armour zap crackle", vol = 0.4, delay = 0.03, pitch = { 1.0, 1.2 } },
	}, { limit = { count = 3, window = 0.3 } }),

	PlayerDown = K(I, 5, {
		{ id = "rbxassetid://9113469292", desc = "heavy body collapse crash with sci-fi power down", vol = 0.9, pitch = { 0.9, 1.0 } },
		{ id = "rbxassetid://9120256999", desc = "descending power-down whine", vol = 0.6, delay = 0.1, pitch = 1.0 },
	}, { limit = { count = 2, window = 0.5 } }),

	LowHealth = K(U, 5, {
		{ id = "rbxassetid://6202853067", desc = "heartbeat thump low warning, single beat", vol = 0.9, pitch = 1.0, volVar = 0.03 },
		{ id = "rbxassetid://139481207162657", desc = "soft alarm beep warning", vol = 0.25, delay = 0.02, pitch = 1.0 },
	}, { limit = { count = 2, window = 0.5 } }),

	-- DEATHS (Enemies) -------------------------------------------------------------
	DeathScrap = K(E, 3, {
		{ id = "rbxassetid://9120253198", desc = "robot explosion pop, small burst, cartoony", vol = 0.8, pitch = { 0.9, 1.1 }, maxDist = 280 },
		{ id = "rbxassetid://9119068481", desc = "scrap metal clatter falling parts", vol = 0.65, delay = { 0.05, 0.2 }, pitch = { 0.9, 1.15 }, maxDist = 220 },
		{ id = "rbxassetid://9120253198", desc = "bolts and screws scatter tinkle", vol = 0.35, delay = { 0.15, 0.4 }, pitch = { 1.0, 1.3 }, maxDist = 120 },
	}, { limit = { count = 3, window = 0.3 } }),

	DeathGoo = K(E, 3, {
		{ id = "rbxassetid://122278974705447", desc = "big wet splat, gooey burst", vol = 0.85, pitch = { 0.9, 1.15 }, maxDist = 280 },
		{ id = "rbxassetid://75221355097604", desc = "slimy squelch drip", vol = 0.45, delay = { 0.05, 0.25 }, pitch = { 0.9, 1.2 }, maxDist = 180 },
		{ id = "rbxassetid://122278974705447", desc = "short bug screech cut off, small", vol = 0.35, pitch = { 1.1, 1.4 }, maxDist = 150 },
	}, { limit = { count = 3, window = 0.3 } }),

	DeathBig = K(E, 4, {
		{ id = "rbxassetid://9116546968", desc = "giant robot explosion crack, heavy metal", vol = 1.0, pitch = { 0.9, 1.0 } },
		{ id = "rbxassetid://9116546326", desc = "deep boom body with metal groan", vol = 0.9, delay = 0.03, pitch = { 0.8, 0.95 } },
		{ id = "rbxassetid://9116546968", desc = "sub bass thump", vol = 0.8, near = true, pitch = { 0.5, 0.6 } },
		{ id = "rbxassetid://9116546326", desc = "heavy metal debris crash and clatter rain", vol = 0.7, delay = { 0.15, 0.6 }, pitch = { 0.85, 1.05 } },
	}, { limit = { count = 2, window = 0.4 }, nearDist = 60, farDist = 160 }),

	-- EXPLOSIONS -------------------------------------------------------------------
	Explosion = K(X, 5, {
		{ id = "rbxassetid://138533090376585", desc = "explosion crack, sharp transient, loud", vol = 1.0, pitch = { 0.95, 1.05 } },
		{ id = "rbxassetid://139210252225248", desc = "explosion boom body, deep rolling", vol = 1.0, pitch = { 0.85, 1.0 }, delay = 0.02 },
		{ id = "rbxassetid://137603819936855", desc = "sub bass thump impact (use any explosion, it is pitched down)", vol = 0.9, near = true, pitch = { 0.5, 0.6 } },
		{ id = "rbxassetid://9113805612", desc = "debris rain, rocks and dirt falling after explosion", vol = 0.55, delay = { 0.15, 0.6 }, pitch = { 0.9, 1.1 } },
		{ id = "rbxassetid://117080687873544", desc = "distant muffled explosion rumble", vol = 0.8, far = true, delay = 0.25, pitch = { 0.8, 0.95 }, maxDist = 1200 },
	}, { limit = BOOM, nearDist = 60, farDist = 140, duck = { groups = { "Weapons", "Ambience" }, db = -6, seconds = 0.4 } }),

	ExplosionSmall = K(X, 4, {
		{ id = "rbxassetid://70668515192625", desc = "small explosion pop crack, grenade-sized", vol = 0.95, pitch = { 0.95, 1.1 } },
		{ id = "rbxassetid://129848017786439", desc = "small boom body punchy", vol = 0.75, pitch = { 0.9, 1.05 }, delay = 0.02 },
		{ id = "rbxassetid://70668515192625", desc = "debris pebbles falling", vol = 0.35, delay = { 0.1, 0.4 }, pitch = { 1.0, 1.3 }, maxDist = 150 },
		{ id = "rbxassetid://129848017786439", desc = "distant muffled pop", vol = 0.6, far = true, delay = 0.15, maxDist = 700 },
	}, { limit = BOOM, nearDist = 40, farDist = 110 }),

	ExplosionHuge = K(X, 5, {
		{ id = "rbxassetid://113607842417670", desc = "massive explosion crack, bomb detonation", vol = 1.2, pitch = { 0.9, 1.0 } },
		{ id = "rbxassetid://2089920319", desc = "massive deep boom body, rolling thunder", vol = 1.2, pitch = { 0.75, 0.9 }, delay = 0.03 },
		{ id = "rbxassetid://113607842417670", desc = "sub bass drop thump, very deep", vol = 1.1, near = true, pitch = { 0.5, 0.6 } },
		{ id = "rbxassetid://2089920319", desc = "rumbling aftershock rolling rumble", vol = 0.8, pitch = { 0.7, 0.85 }, delay = { 0.2, 0.4 } },
		{ id = "rbxassetid://113607842417670", desc = "large debris rain, rocks and metal crashing down", vol = 0.7, delay = { 0.3, 1.0 }, pitch = { 0.8, 1.0 } },
		{ id = "rbxassetid://2089920319", desc = "distant huge explosion rumble, muffled", vol = 1.0, far = true, delay = 0.4, pitch = { 0.7, 0.85 }, maxDist = 2000 },
	}, { limit = { count = 3, window = 0.4 }, nearDist = 100, farDist = 220, duck = { groups = { "Weapons", "Ambience", "Enemies" }, db = -8, seconds = 0.6 } }),

	EMP = K(X, 4, {
		{ id = "rbxassetid://135847326073354", desc = "sci-fi EMP burst pulse zap, electric shockwave", vol = 1.0, pitch = { 0.95, 1.05 } },
		{ id = "rbxassetid://124307033081669", desc = "electric crackle fading decay", vol = 0.6, delay = 0.1, pitch = { 0.9, 1.1 } },
		{ id = "rbxassetid://135847326073354", desc = "sub bass pulse thump", vol = 0.8, near = true, pitch = { 0.5, 0.6 } },
	}, { limit = { count = 3, window = 0.4 } }),

	MissileLaunch = K(X, 5, {
		{ id = "rbxassetid://2853035419", desc = "huge rocket/missile launch ignition roar", vol = 1.2, pitch = { 0.9, 1.0 }, maxDist = 1500 },
		{ id = "rbxassetid://123619882242196", desc = "deep rumbling rocket engine thunder", vol = 1.0, delay = 0.2, pitch = { 0.7, 0.85 }, maxDist = 1500 },
		{ id = "rbxassetid://2853035419", desc = "sub bass rumble", vol = 0.9, near = true, pitch = { 0.5, 0.6 } },
	}, { limit = { count = 1, window = 1 }, nearDist = 150, farDist = 300 }),

	-- CALL-INS ---------------------------------------------------------------------
	BeaconThrow = K(C, 3, {
		{ id = "rbxassetid://113824294371409", desc = "device throw whoosh with electronic chirp", vol = 0.7, pitch = { 0.95, 1.05 }, minDist = 8, maxDist = 150 },
	}, { limit = { count = 2, window = 0.4 } }),

	BeaconPing = K(C, 3, {
		{ id = "rbxassetid://3027984748", desc = "sci-fi beacon ping, sonar-like, repeatable loop-friendly", vol = 0.6, pitch = 1.0, minDist = 15, maxDist = 200, loop = true },
	}, { limit = { count = 2, window = 0.4 } }),

	ShipRadio = K(C, 4, {
		{ id = "rbxassetid://9118027586", desc = "radio static blip, communication chirp, ship acknowledges", vol = 0.7, pitch = { 0.95, 1.05 } },
		{ id = "rbxassetid://123582950451975", desc = "short radio squelch click", vol = 0.4, delay = 0.35 },
	}, { limit = { count = 2, window = 0.4 } }),

	LanceCharge = K(C, 4, {
		{ id = "rbxassetid://8392900771", desc = "orbital laser charge up rising energy whine, sci-fi", vol = 0.9, pitch = { 0.95, 1.05 }, maxDist = 500 },
		{ id = "rbxassetid://123132185939954", desc = "deep power rumble rising", vol = 0.7, pitch = 1.0, maxDist = 500 },
	}, { limit = { count = 1, window = 1 } }),

	LanceHum = K(C, 4, {
		{ id = "rbxassetid://126321934365548", desc = "sustained powerful energy beam hum loop, sci-fi laser", vol = 0.9, loop = true, minDist = 20, maxDist = 500 },
		{ id = "rbxassetid://75130957161939", desc = "electric crackle sizzle loop", vol = 0.5, loop = true, minDist = 20, maxDist = 400 },
	}),

	LanceEnd = K(C, 4, {
		{ id = "rbxassetid://135847326073354", desc = "laser beam shutdown power-down zap and thump", vol = 0.9, pitch = { 0.95, 1.05 }, maxDist = 500 },
		{ id = "rbxassetid://17871250897", desc = "sizzle cooling hiss", vol = 0.4, delay = 0.15, maxDist = 250 },
	}, { limit = { count = 1, window = 1 } }),

	BombWhistle = K(C, 4, {
		{ id = "rbxassetid://127333563637736", desc = "falling bomb whistle descending, classic", vol = 0.9, pitch = { 0.95, 1.05 }, maxDist = 600 },
		{ id = "rbxassetid://116150406781332", desc = "jet engine distant roar overhead", vol = 0.5, pitch = 1.0, maxDist = 600 },
	}, { limit = { count = 2, window = 0.5 } }),

	JetFlyby = K(C, 4, {
		{ id = "rbxassetid://106006741903011", desc = "fighter jet flyby whoosh, doppler roar", vol = 1.0, pitch = { 0.95, 1.05 }, minDist = 40, maxDist = 800 },
		{ id = "rbxassetid://99181880134494", desc = "jet afterburner rumble", vol = 0.6, delay = 0.2, minDist = 40, maxDist = 800 },
	}, { limit = { count = 2, window = 0.5 } }),

	ShellWhistle = K(C, 3, {
		{ id = "rbxassetid://81509845941651", desc = "artillery shell incoming whistle, short descending", vol = 0.8, pitch = { 0.9, 1.15 }, maxDist = 500 },
	}, { limit = { count = 4, window = 0.3 } }),

	GasHiss = K(C, 3, {
		{ id = "rbxassetid://102999890133674", desc = "gas canister release hiss, pressurised spray, looping", vol = 0.7, loop = true, minDist = 10, maxDist = 200 },
		{ id = "rbxassetid://137858412731781", desc = "canister pop and burst", vol = 0.6, pitch = { 0.95, 1.05 }, maxDist = 200 },
	}, { limit = { count = 2, window = 0.4 } }),

	EMPPulse = K(C, 4, {
		{ id = "rbxassetid://9126067243", desc = "electromagnetic pulse charge-up buzz and ping, sci-fi", vol = 0.8, pitch = { 0.95, 1.05 } },
		{ id = "rbxassetid://135847326073354", desc = "electric zap crackle", vol = 0.5, delay = 0.05, pitch = { 1.0, 1.2 } },
	}, { limit = { count = 2, window = 0.4 } }),

	MineArm = K(C, 2, {
		{ id = "rbxassetid://16903690359", desc = "mine arming beeps, three short electronic beeps with click", vol = 0.6, pitch = { 0.95, 1.05 }, maxDist = 120 },
	}, { limit = { count = 4, window = 0.4 } }),

	MineBeep = K(C, 1, {
		{ id = "rbxassetid://140006631574809", desc = "single short proximity mine beep", vol = 0.4, pitch = { 0.98, 1.02 }, minDist = 5, maxDist = 60 },
	}, { limit = { count = 3, window = 0.4 } }),

	PodFall = K(C, 4, {
		{ id = "rbxassetid://116150406781332", desc = "drop pod re-entry roar, falling fireball whoosh", vol = 0.9, pitch = { 0.95, 1.05 }, maxDist = 600 },
		{ id = "rbxassetid://89485009204188", desc = "descending whistle", vol = 0.5, pitch = 1.0, maxDist = 600 },
	}, { limit = { count = 4, window = 0.5 } }),

	PodImpact = K(C, 5, {
		{ id = "rbxassetid://9119641416", desc = "heavy metal capsule crash impact, ground slam", vol = 1.0, pitch = { 0.9, 1.0 } },
		{ id = "rbxassetid://91288569991875", desc = "sub bass slam thump", vol = 0.9, near = true, pitch = { 0.5, 0.6 } },
		{ id = "rbxassetid://9119641416", desc = "metal creak and debris settle", vol = 0.5, delay = { 0.2, 0.5 }, pitch = { 0.9, 1.1 } },
	}, { limit = { count = 3, window = 0.4 }, duck = { groups = { "Ambience" }, db = -4, seconds = 0.3 } }),

	CrateOpen = K(C, 3, {
		{ id = "rbxassetid://5582720822", desc = "supply crate latch unlock and lid open clunk", vol = 0.8, pitch = { 0.95, 1.05 }, maxDist = 150 },
		{ id = "rbxassetid://17419512544", desc = "pressurised hydraulic hiss", vol = 0.5, delay = 0.1, maxDist = 120 },
	}, { limit = { count = 2, window = 0.4 } }),

	ShieldUp = K(C, 3, {
		{ id = "rbxassetid://126809328894734", desc = "energy shield dome activation hum swell, sci-fi", vol = 0.85, pitch = { 0.95, 1.05 }, maxDist = 300 },
		{ id = "rbxassetid://92636095967110", desc = "short electric zap shimmer", vol = 0.5, delay = 0.05, maxDist = 250 },
	}, { limit = { count = 2, window = 0.4 } }),

	SmokePop = K(C, 2, {
		{ id = "rbxassetid://118435762926567", desc = "smoke grenade pop and hiss", vol = 0.7, pitch = { 0.95, 1.05 }, maxDist = 200 },
	}, { limit = { count = 3, window = 0.3 } }),

	Pickup = K(C, 3, {
		{ id = "rbxassetid://138277374585498", desc = "pickup chime with ammo clack, short, positive", vol = 0.7, pitch = { 0.95, 1.1 }, minDist = 8, maxDist = 80 },
	}, { limit = { count = 3, window = 0.3 } }),

	-- ENEMIES ----------------------------------------------------------------------
	EnemyBolt = K(E, 2, {
		{ id = "rbxassetid://96160724494413", desc = "sci-fi blaster pew, enemy laser bolt shot, distinct from player guns", vol = 0.75, pitch = { 0.9, 1.1 }, maxDist = 350 },
		{ id = "rbxassetid://76951923939470", desc = "short electric fizz", vol = 0.3, delay = 0.02, pitch = { 1.0, 1.2 }, maxDist = 150 },
	}, { limit = { count = 4, window = 0.3 }, perSource = false }),

	EnemyCannon = K(E, 3, {
		{ id = "rbxassetid://131068121289461", desc = "heavy robot cannon blast, big sci-fi boom", vol = 1.0, pitch = { 0.85, 1.0 }, maxDist = 500 },
		{ id = "rbxassetid://125205557479599", desc = "deep thump", vol = 0.7, near = true, pitch = { 0.55, 0.65 } },
	}, { limit = { count = 3, window = 0.4 } }),

	AcidSpit = K(E, 2, {
		{ id = "rbxassetid://9119054571", desc = "bug spitting acid hock, wet gurgle spit", vol = 0.8, pitch = { 0.9, 1.1 }, maxDist = 300 },
		{ id = "rbxassetid://122278974705447", desc = "sizzle whoosh", vol = 0.35, delay = 0.05, pitch = { 1.0, 1.2 }, maxDist = 200 },
	}, { limit = { count = 3, window = 0.4 } }),

	AcidSplat = K(E, 2, {
		{ id = "rbxassetid://75221355097604", desc = "acid splash sizzle, wet splat with hiss", vol = 0.8, pitch = { 0.9, 1.1 }, maxDist = 250 },
		{ id = "rbxassetid://122278974705447", desc = "bubbling sizzle", vol = 0.4, delay = 0.1, maxDist = 150 },
	}, { limit = { count = 3, window = 0.4 } }),

	Mortar = K(E, 3, {
		{ id = "rbxassetid://99408126754348", desc = "mortar tube launch thump, hollow bloop", vol = 0.9, pitch = { 0.9, 1.05 }, maxDist = 600 },
		{ id = "rbxassetid://123402454968182", desc = "short whoosh arc", vol = 0.35, delay = 0.1, maxDist = 300 },
	}, { limit = { count = 3, window = 0.4 } }),

	Telegraph = K(E, 4, {
		{ id = "rbxassetid://98180814011947", desc = "attack warning beep rising, danger telegraph, sci-fi", vol = 0.8, pitch = 1.0, volVar = 0.03, minDist = 20, maxDist = 300 },
	}, { limit = { count = 3, window = 0.4 } }),

	DropShip = K(E, 4, {
		{ id = "rbxassetid://4669178369", desc = "enemy dropship engine flyby, heavy hover roar, sci-fi", vol = 1.0, minDist = 30, maxDist = 900 },
		{ id = "rbxassetid://108734242300536", desc = "mechanical clunk cargo bay doors", vol = 0.5, delay = 0.5, maxDist = 400 },
	}, { limit = { count = 2, window = 0.5 } }),

	Breach = K(E, 4, {
		{ id = "rbxassetid://9113223222", desc = "ground burst, dirt eruption rumble and rock crack", vol = 1.0, pitch = { 0.85, 1.0 }, maxDist = 500 },
		{ id = "rbxassetid://120212342534790", desc = "bug screech roar", vol = 0.6, delay = 0.15, pitch = { 0.9, 1.1 }, maxDist = 400 },
		{ id = "rbxassetid://9113223222", desc = "sub rumble", vol = 0.8, near = true, pitch = { 0.5, 0.6 } },
	}, { limit = { count = 2, window = 0.5 } }),

	RobotStep = K(E, 1, {
		{ id = "rbxassetid://9125818616", desc = "small robot metal footstep clank with servo whir", vol = 0.45, pitch = { 0.85, 1.15 }, minDist = 8, maxDist = 90, volVar = 0.2 },
	}, { limit = { count = 4, window = 0.3 } }),

	BugScreech = K(E, 2, {
		{ id = "rbxassetid://9118199536", desc = "alien insect screech chitter, short cartoony", vol = 0.7, pitch = { 0.85, 1.25 }, maxDist = 250 },
	}, { limit = { count = 3, window = 0.4 } }),

	ChargerRoar = K(E, 4, {
		{ id = "rbxassetid://133651202885353", desc = "big beetle roar growl windup, heavy", vol = 1.0, pitch = { 0.8, 0.95 }, maxDist = 400 },
		{ id = "rbxassetid://9113980319", desc = "stomping thud rumble", vol = 0.5, delay = 0.1, near = true, pitch = { 0.6, 0.8 } },
	}, { limit = { count = 2, window = 0.5 } }),

	TitanRoar = K(E, 5, {
		{ id = "rbxassetid://110716346002611", desc = "colossal monster roar, huge deep creature bellow", vol = 1.2, pitch = { 0.7, 0.85 }, minDist = 30, maxDist = 900 },
		{ id = "rbxassetid://140183060324629", desc = "deep sub rumble", vol = 0.9, near = true, pitch = { 0.5, 0.6 } },
		{ id = "rbxassetid://110716346002611", desc = "distant monster bellow echo", vol = 0.8, far = true, delay = 0.4, pitch = { 0.7, 0.85 }, maxDist = 1500 },
	}, { limit = { count = 1, window = 1.0 }, nearDist = 100, farDist = 250 }),

	ColossusHorn = K(E, 5, {
		{ id = "rbxassetid://70444139603815", desc = "giant mechanical war horn blast, low brass-like foghorn, ominous", vol = 1.2, pitch = { 0.8, 0.9 }, minDist = 40, maxDist = 1200 },
		{ id = "rbxassetid://127364360574780", desc = "deep sub drone", vol = 0.8, near = true, pitch = { 0.5, 0.6 } },
	}, { limit = { count = 1, window = 1.0 }, nearDist = 120 }),

	LaserSweep = K(E, 4, {
		{ id = "rbxassetid://126321934365548", desc = "continuous big sci-fi laser beam sustained hum with crackle, loopable", vol = 0.9, loop = true, minDist = 25, maxDist = 600 },
		{ id = "rbxassetid://122892602795552", desc = "rising charge whine", vol = 0.5, loop = true, minDist = 25, maxDist = 500 },
	}),

	-- WORLD / OBJECTIVES (ambience group) ------------------------------------------
	Generator = K(A, 1, {
		{ id = "rbxassetid://9119806932", desc = "industrial generator engine hum running loop, mechanical drone", vol = 0.6, loop = true, minDist = 8, maxDist = 120 },
	}),

	Alarm = K(A, 4, {
		{ id = "rbxassetid://129621997122495", desc = "facility alarm siren loop, short wail, urgent", vol = 0.7, loop = true, minDist = 20, maxDist = 300 },
	}),

	Klaxon = K(A, 4, {
		{ id = "rbxassetid://3165700530", desc = "deep klaxon horn warning blast, ominous launch warning", vol = 0.9, pitch = 1.0, minDist = 30, maxDist = 900 },
	}, { limit = { count = 1, window = 1.0 } }),

	SkiffEngine = K(A, 4, {
		{ id = "rbxassetid://9119806923", desc = "dropship / shuttle engine hover loop, turbine roar, sci-fi", vol = 0.9, loop = true, minDist = 30, maxDist = 700 },
		{ id = "rbxassetid://83370360151288", desc = "low engine rumble loop", vol = 0.6, loop = true, minDist = 30, maxDist = 700 },
	}),

	-- PACING CUES (Director intensity, client/Fx/IntensityFx.luau). All ids below are REUSED from the entries above -- no new uploads.
	-- TODO(audio): swap in dedicated assets when available: a distant subterranean tremor for WarnRumble, a distant dropship/
	-- servo swell for WarnMachinery, a proper 3-note breach siren for BreachHorn, a short ominous sting for HeavyContact.
	WarnRumble = K(E, 4, {
		{ id = "rbxassetid://9113223222", desc = "low distant ground rumble, burrowing tremor (reuses the Breach rumble, pitched down)", vol = 0.9, pitch = { 0.45, 0.6 }, minDist = 220, maxDist = 1400 },
		{ id = "rbxassetid://140183060324629", desc = "deep sub rumble swell", vol = 0.8, delay = 0.25, pitch = { 0.55, 0.7 }, minDist = 220, maxDist = 1400 },
		{ id = "rbxassetid://120212342534790", desc = "far-off bug screech echo", vol = 0.35, delay = { 0.6, 1.4 }, pitch = { 0.6, 0.8 }, chance = 0.6, minDist = 220, maxDist = 1400 },
	}, { limit = { count = 2, window = 1.5 }, priority = 4 }),

	WarnMachinery = K(E, 4, {
		{ id = "rbxassetid://4669178369", desc = "distant dropship engines gathering overhead (reuses DropShip, pitched down)", vol = 0.9, pitch = { 0.6, 0.72 }, minDist = 220, maxDist = 1400 },
		{ id = "rbxassetid://127364360574780", desc = "deep ominous machine drone", vol = 0.7, delay = 0.2, pitch = { 0.55, 0.7 }, minDist = 220, maxDist = 1400 },
		{ id = "rbxassetid://108734242300536", desc = "cargo bay clunk far away", vol = 0.35, delay = { 0.5, 1.2 }, pitch = { 0.7, 0.9 }, chance = 0.6, minDist = 220, maxDist = 1400 },
	}, { limit = { count = 2, window = 1.5 }, priority = 4 }),

	BreachHorn = K(X, 5, {
		{ id = "rbxassetid://3165700530", desc = "klaxon siren blast, breach inbound (reuses Klaxon)", vol = 1.0, pitch = { 0.82, 0.9 } },
		{ id = "rbxassetid://70444139603815", desc = "giant war horn blast (reuses ColossusHorn)", vol = 1.1, pitch = { 0.78, 0.86 }, delay = 0.15 },
		{ id = "rbxassetid://129621997122495", desc = "facility alarm wail tail", vol = 0.55, delay = 0.7, pitch = { 0.95, 1.0 } },
		{ id = "rbxassetid://127364360574780", desc = "sub drone under the horn", vol = 0.9, pitch = { 0.5, 0.58 } },
	}, { limit = { count = 1, window = 2 }, duck = { groups = { "Weapons", "Ambience" }, db = -5, seconds = 1.2 } }),

	HeavyContact = K(U, 5, {
		{ id = "rbxassetid://98180814011947", desc = "ominous rising warning tone (reuses Telegraph, pitched down)", vol = 0.85, pitch = { 0.6, 0.68 } },
		{ id = "rbxassetid://9113223222", desc = "ground slam under the tone", vol = 0.7, delay = 0.05, pitch = { 0.5, 0.6 } },
	}, { limit = { count = 1, window = 1.2 } }),

	Wind = K(A, 1, {
		{ id = "rbxassetid://102354126031648", desc = "desert wind ambience loop, soft gusts, seamless", vol = 0.6, loop = true, pitch = 1.0 },
	}),

	-- UI ---------------------------------------------------------------------------
	UIClick = K(U, 4, {
		{ id = "rbxassetid://15675059323", desc = "UI button click, short crisp sci-fi tick", vol = 0.6, pitch = { 0.97, 1.03 }, volVar = 0.05 },
	}, { limit = { count = 4, window = 0.2 } }),

	UIHover = K(U, 3, {
		{ id = "rbxassetid://139800881181209", desc = "UI hover blip, very soft quiet tick", vol = 0.3, pitch = { 0.95, 1.1 }, volVar = 0.05 },
	}, { limit = { count = 3, window = 0.2 } }),

	UIOpen = K(U, 4, {
		{ id = "rbxassetid://80901093788349", desc = "UI panel open swoosh, sci-fi whoosh with chirp", vol = 0.6, pitch = { 0.97, 1.03 } },
	}, { limit = { count = 2, window = 0.3 } }),

	UIError = K(U, 4, {
		{ id = "rbxassetid://87519554692663", desc = "UI error buzz, short low denied beep", vol = 0.6, pitch = 1.0 },
	}, { limit = { count = 2, window = 0.3 } }),

	UIBuy = K(U, 4, {
		{ id = "rbxassetid://100813529228543", desc = "purchase success, coin/cash register cha-ching, bright", vol = 0.7, pitch = { 0.98, 1.04 } },
		{ id = "rbxassetid://4612374393", desc = "short rising sparkle chime", vol = 0.4, delay = 0.05 },
	}, { limit = { count = 2, window = 0.3 } }),

	DialOpen = K(U, 4, {
		{ id = "rbxassetid://3027984748", desc = "radial menu open, sci-fi uplink whoosh and ping", vol = 0.65, pitch = { 0.98, 1.02 } },
	}, { limit = { count = 2, window = 0.3 } }),

	DialTick = K(U, 3, {
		{ id = "rbxassetid://9120093264", desc = "mechanical dial tick click, crisp ratchet notch", vol = 0.4, pitch = { 0.95, 1.1 }, volVar = 0.05 },
	}, { limit = { count = 6, window = 0.3 } }),

	DialSelect = K(U, 4, {
		{ id = "rbxassetid://102563892600485", desc = "selection confirm, satisfying thunk-chirp", vol = 0.65, pitch = { 0.98, 1.03 } },
		{ id = "rbxassetid://81933188942245", desc = "short electronic blip up", vol = 0.35, delay = 0.04 },
	}, { limit = { count = 2, window = 0.3 } }),

	DialPerfect = K(U, 5, {
		{ id = "rbxassetid://103516326607012", desc = "perfect timing success chime, bright golden ding, rewarding", vol = 0.8, pitch = 1.0 },
		{ id = "rbxassetid://4612374495", desc = "sparkle shimmer rising", vol = 0.5, delay = 0.05 },
	}, { limit = { count = 2, window = 0.3 } }),

	Notify = K(U, 4, {
		{ id = "rbxassetid://17208361335", desc = "notification chime, short friendly two-note ping", vol = 0.6, pitch = { 0.98, 1.03 } },
	}, { limit = { count = 3, window = 0.3 } }),

	ObjectiveDone = K(U, 5, {
		{ id = "rbxassetid://9067124098", desc = "objective complete fanfare sting, short triumphant, sci-fi", vol = 0.85, pitch = 1.0 },
		{ id = "rbxassetid://1844584698", desc = "checkmark ding bell", vol = 0.5, delay = 0.05 },
	}, { limit = { count = 2, window = 0.5 } }),

	MissionStart = K(U, 5, {
		{ id = "rbxassetid://3165700530", desc = "mission start, drop countdown whoosh and radio chirp, cinematic hit", vol = 0.9, pitch = 1.0 },
		{ id = "rbxassetid://70444139603815", desc = "deep cinematic impact boom", vol = 0.7, near = true },
	}, { limit = { count = 1, window = 1 } }),

	MissionSuccess = K(U, 5, {
		{ id = "rbxassetid://133000497392138", desc = "mission success victory fanfare, short heroic orchestral/synth sting", vol = 0.9, pitch = 1.0 },
	}, { limit = { count = 1, window = 1 } }),

	MissionFail = K(U, 5, {
		{ id = "rbxassetid://1842057518", desc = "mission failed sting, descending somber tones, power-down", vol = 0.9, pitch = 1.0 },
	}, { limit = { count = 1, window = 1 } }),

	RankUp = K(U, 5, {
		{ id = "rbxassetid://112485797063762", desc = "level up / rank up fanfare, rising sparkle jingle, rewarding", vol = 0.9, pitch = 1.0 },
		{ id = "rbxassetid://134821092416328", desc = "shimmer sparkle tail", vol = 0.5, delay = 0.2 },
	}, { limit = { count = 1, window = 1 } }),

	-- MUSIC (loops; played with Audio.setMusic) ------------------------------------
	Music_Ship = K(M, 5, {
		{ id = "rbxassetid://103700934283247", desc = "calm ambient sci-fi space station music loop, hopeful, synth pads, seamless loop", vol = 0.8, loop = true, pitch = 1.0, volVar = 0 },
	}),

	Music_Combat = K(M, 5, {
		{ id = "rbxassetid://9038488995", desc = "intense action sci-fi combat music loop, driving drums and bass, seamless loop", vol = 0.8, loop = true, pitch = 1.0, volVar = 0 },
	}),
}

return S
