--!strict
-- Single source of truth for names, tuning and monetisation IDs.
-- Rename the game here only (see docs/spec.md §0).

local Config = {}

Config.GameName = "Orbitfall"
Config.ShipName = "ORV Halcyon"
Config.ShuttleName = "Skiff"
Config.Version = "0.1.0"

-- Places / world
Config.ShipHeight = 900 -- lobby deck Y
Config.DropHeight = 600 -- drop capsule start Y
Config.MapSize = 640 -- studs, square, centred at origin

Config.Music = false -- ship / combat music tracks (client/Main.client); off since 2026-11-16

-- Mission tuning
Config.MissionTime = 14 * 60 -- 2026-11-15 pick (was 18, before that 25); Studio A/B Feel_MissionTime (minutes) overrides it in server/Mission.luau
Config.StartCountdown = 10
Config.ResultsTime = 12
Config.FailedTime = 8
Config.ExtractEta = 60
Config.ExtractWindow = 25
Config.LivesBase = 6
Config.LivesPerPlayer = 2
Config.AutoReinforceDelay = 8
Config.FriendlyFire = false
Config.FailRewardScale = 0.25

-- Player
Config.PlayerHealth = 150
-- Stims (server/PlayerService "stim" action; client/Fx/VitalsFx input + feedback)
Config.Stims = {
	Max = 3, -- carried per trooper; respawn and supply crates refill to Max
	Heal = 0.85, -- share of max health restored per stim
	Delay = 0.08, -- seconds before the heal starts
	Duration = 1.0, -- seconds the heal is spread over
	Critical = 0.3, -- health share below which the HUD bar turns red and the "use stim" prompt shows
	Sprint = 5, -- seconds of unlimited stamina after a stim (server/MovementService.boost; Studio A/B Feel_StimSprint, 0 = off)
	Hold = 0.8, -- seconds the stim key is held before the stim goes in (shared/Downed.stimHold; Studio A/B Feel_StimHold, 0 = tap)
}
-- Downed state (server/Downed.luau, client/DownedFx.luau, rules in shared/Downed.luau). A hit that would kill you puts
-- you on the ground instead: a small health pool that bleeds out; at 0 you die as before (a life, reinforce).
-- Get up: a squadmate holds Interact on you, or you use a stim (costs one). Sidearm only while down.
-- Studio A/B: workspace attribute Feel_Downed = "long" (20 s bleed) | "off" (instant death, the old rule).
Config.Downed = {
	Enabled = true,
	BleedTime = 12, -- seconds from going down to bleeding out, if nobody shoots you
	BleedTimeLong = 20, -- Feel_Downed = "long"
	Pool = 0.3, -- share of max health the downed body has (drains over BleedTime)
	HitMult = 0.5, -- damage taken while down (enemies still finish you, slower)
	ReviveHold = 2.5, -- seconds a squadmate holds Interact
	ReviveRange = 9,
	ReviveHealth = 0.35, -- share of max health after a squadmate revive (a stim revive heals like a stim on top)
	CrawlSpeed = 2.5,
}
-- Passive regen (server/PlayerService). Studio A/B: workspace attribute Feel_Regen = "off" | "slow" | "current".
Config.Regen = {
	Mode = "slow",
	Slow = { above = 0.5, delay = 6, rate = 5, cap = 1.0 }, -- only above 50 % hp, 6 s after the last hit, up to full
	Current = { above = 0, delay = 5, rate = 10, cap = 0.6 }, -- the old regen: below 60 % only, 5 s after the last hit
}
Config.TrooperBody = true -- everyone spawns as the standard R15 trooper body (server/PlayerService loadTrooper)
Config.WalkSpeed = 16
Config.SprintSpeed = 24
Config.AimSpeed = 11
-- Movement (client/Movement.luau predicts, server/MovementService.luau is authoritative for stamina/stance)
Config.Move = {
	SprintTime = 6, -- seconds of continuous sprint from full stamina
	RegenDelay = 1, -- seconds after the last drain before stamina refills
	RegenTime = 3.5, -- seconds from empty to full once regen starts
	RecoverAt = 0.3, -- exhausted (jog-limp) until stamina is back to this
	LimpSpeed = 12,
	CrouchSpeed = 9,
	CrouchAimSpeed = 7,
	ProneSpeed = 4.5,
	ProneHoldTime = 0.32, -- hold crouch this long -> prone
	DiveCost = 0.18,
	DiveCooldown = 1,
	DiveSpeed = 34,
	DiveUp = 26, -- with default gravity 196 (35 % cancelled mid-dive) ~0.45 s airtime, ~12 studs
	DiveRecover = 0.35,
	MantleMin = 2.5,
	MantleMax = 6,
	MantleTime = 0.35,
	KnockdownSpeed = 40, -- knock impulses at least this strong put you on the ground
	KnockdownTime = 0.8,
	SprintFov = 6,
}
Config.Grenades = 4
Config.BeaconThrowSpeed = 70 -- studs/s
Config.InteractRange = 10

-- Enemy director
Config.MaxEnemies = 45
Config.MaxBehemoths = 2
Config.MaxHeavies = 6
Config.PatrolInterval = 45
Config.ReinforceCallCooldown = 40
Config.DifficultyHpScale = { 1.0, 1.1, 1.2, 1.3, 1.4 }
-- Action-density tuning (combat rework). The Director uses these instead of MaxEnemies / PatrolInterval /
-- ReinforceCallCooldown above (those stay as the old baseline). liveCap = min(CapMax, CapBase + CapPerPlayer*players + CapPerDifficulty*diff).
Config.Action = {
	CapMax = 56,
	CapBase = 22,
	CapPerPlayer = 7,
	CapPerDifficulty = 4,
	PatrolInterval = 22, -- seconds between patrol groups (was 45)
	PatrolIntervalBusy = 0.4, -- multiplier on that interval while the field is nearly empty (< EmptyFraction of the cap)
	EmptyFraction = 0.4,
	ReinforceCooldown = 45, -- seconds between "spotted -> reinforcements" calls (was 40, 24, 12; playtest: calls cascaded during breaches)
	ReinforceBreachLockout = 30, -- no call may start during BUILD / BREACH / extraction hold-out, nor this many seconds after a breach ended
	ReinforceChainMax = 1, -- calls units delivered by a call may make themselves per breach cycle (further ones just fight)
	ReinforceWindup = 3, -- seconds the caller burns a flare before the reinforcements arrive; killing / stunning it cancels the call
	AggroMult = 1.25, -- enemy detection radius multiplier (EnemyAI)
	AdvanceSpeed = 1.0, -- speed fraction patrols/seekers advance at (was 0.8)

	-- Melee slots (EnemyAI): at most this many melee attackers engage ONE player at once, the rest circle at CircleMin..CircleMax studs.
	-- Director.meleeSlots() = MeleeSlotsBase + floor(difficulty / 2)  (diff 1 -> 3 ... diff 4-5 -> 5), clamped to MeleeSlotsMax.
	MeleeSlotsBase = 3,
	MeleeSlotsMax = 5,
	MeleeSlotLease = { 5, 9 }, -- seconds a melee unit keeps its slot before it may rotate out (only when somebody is waiting)
	MeleeClaimRange = 14, -- a melee unit only claims a slot once it is this close to its target
	CircleMin = 8,
	CircleMax = 12,
	-- 4 s lull (no new spawns, no reinforcement calls) after a player goes down
	DownLull = 4,

	-- Fodder / swarm tier (one cheap unit per faction, see Data/Enemies.luau SWARM kinds)
	FodderCost = 0.5, -- share of the live cap one fodder body costs (the cap is counted in "load", not bodies)
	FodderSteerRange = 40, -- inside this many studs of the target fodder skip obstacle raycasts and just seeks (steer only)
	FodderThink = 0.18, -- seconds between AI thinks of a fodder unit (others: 0.1)
	FodderGroundSnap = 1.2, -- fodder re-snaps to the terrain every this many studs of movement (others: 0.25)

	-- Proximity budget while a BREACH is up
	NearRadius = 70, -- "close to the action": within this many studs of some player
	NearFraction = 0.6, -- target share of live enemies that should be near
	RecycleDist = 140, -- stragglers beyond this (regular / medium / fodder) are despawned and respawned at a source
	RecycleInterval = 2, -- seconds between proximity passes
	RecycleMax = 8, -- most units recycled per pass
}

-- Encounters (server/Enemies/Director.luau + Garrisons.luau): fewer, tougher enemies. The world is held by garrisons (guard posts
-- at sites, patrol squads walking between them); waves and breaches are rarer and come as a response (spotted calls, objectives,
-- mission clock). Multipliers apply on top of Config.Action and shared/Data/Intensity.luau.
Config.Encounters = {
	CapMult = 0.55, -- live cap (Config.Action Cap*, breach / extraction caps and floors)
	BudgetMult = 0.55, -- every composed wave / reinforcement / extraction budget
	FodderMult = 0.6, -- breach source fodder batch size (Brood swarms stay, smaller)
	EliteEveryMult = 1.4, -- seconds between a source's elites
	ReinforceCooldown = 90, -- seconds between spotted -> reinforcement calls (Config.Action.ReinforceCooldown is the old 45)
	-- ambient pacing: CALM lasts CalmEarly x as long at mission start, easing to CalmLate x by RampTime seconds in
	CalmEarly = 2.6,
	CalmLate = 1.2,
	RampTime = 540,
	FirstCalmMult = 1.3, -- the opening CALM is longer still (the squad explores, meets garrisons)
	-- roaming patrols that cross the squad's path (Intensity.Patrol): rarer and smaller
	PatrolIntervalMult = 3,
	PatrolCount = { 2, 4 },
	PatrolFirstDelay = 45,
	-- garrison units that have not joined the fight do not use up the live cap, up to this much load
	GarrisonFreeLoad = 12,
	GarrisonMinInsertDist = 80, -- no guard post or patrol route point closer than this to the insertion point
}

-- Rewards (per successful mission)
Config.Rewards = {
	XpBase = 250, XpPerMainStep = 60, XpPerSide = 80, XpPerKill = 2,
	SalvageBase = 150, SalvagePerSide = 60, SalvagePerSample = 25,
	TokensBase = 10, TokensPerSide = 2, TokensFirstWinOfDay = 10,
	WeeklyMissionGoal = 10, WeeklyTokens = 40,
}

-- Monetisation. Placeholders (0) until real products are created on the Creator Dashboard.
-- Every item here MUST also be earnable for free (see docs/spec.md §8.3).
Config.Products = {
	Tokens100 = { id = 0, tokens = 100, robux = 99 },
	Tokens550 = { id = 0, tokens = 550, robux = 449 },
	Tokens1200 = { id = 0, tokens = 1200, robux = 899 },
}
Config.GamePasses = {
	IroncladBond = { id = 0, bond = "IRONCLAD", robux = 499 },
	HivebreakerBond = { id = 0, bond = "HIVEBREAKER", robux = 499 },
	SquadColours = { id = 0, cosmetic = "SQUAD_COLOURS", robux = 149, freeAtRank = 20 },
}

-- Save
Config.DataStoreName = "OrbitfallSave_v1"
Config.AutosaveInterval = 120

-- Ranks: xp needed to go from rank r to r+1
function Config.xpForRank(rank: number): number
	return 400 + (rank - 1) * 120
end
Config.MaxRank = 50

-- Colours (UI theme)
Config.Colors = {
	Navy = Color3.fromHex("10151f"),
	Panel = Color3.fromHex("1a2231"),
	Accent = Color3.fromHex("ff8a2b"),
	Friendly = Color3.fromHex("3ee6c8"),
	Danger = Color3.fromHex("ff4a4a"),
	Gold = Color3.fromHex("ffd34a"),
	Text = Color3.fromHex("f4f6fa"),
	Muted = Color3.fromHex("8a96aa"),
	BeaconOffense = Color3.fromHex("ff3b30"),
	BeaconSupply = Color3.fromHex("2f8bff"),
	BeaconDefense = Color3.fromHex("33e07a"),
}

return Config
