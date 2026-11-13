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

-- Mission tuning
Config.MissionTime = 25 * 60
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
	ReinforceCooldown = 24, -- seconds between "spotted -> reinforcements" calls (was 40)
	AggroMult = 1.25, -- enemy detection radius multiplier (EnemyAI)
	AdvanceSpeed = 1.0, -- speed fraction patrols/seekers advance at (was 0.8)
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
