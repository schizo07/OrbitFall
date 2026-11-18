--!nonstrict
-- Studio-only A/B switcher. Each group is a list of named presets; a preset is a set of workspace attributes
-- (CamTune_* read by CameraController, PoseTune_* read by CombatPose, ...). Keys cycle the active group's presets
-- live during Play so the user can pick by feel instead of describing it.
--   K / L  (or [ / ])   previous / next preset in the current group
--   J      (or \)       next group (when there is more than one)
-- A small label in the top-centre shows the group and preset. Live games never load this (Main.client: IsStudio).
-- Picked presets get baked into the code defaults and their group is removed (2026-11-14: framing, gun feel,
-- enemy hit, feet picked; the store sound candidates were rejected in favour of in-house sounds).

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Variants = {}

-- Every preset lists the full set of keys its group touches, so switching never leaves a stale value behind.
-- nil-valued keys are written as "clear" (attribute removed -> the code's default is used).
-- A preset may also carry `sounds = { SoundKey = { [layerIndex] = "rbxassetid://..." } }` to swap sound layers.
local GROUPS = {
	-- 2026-11-15 playtest: framing, prone twist, explosions, UI scale, regen, damage fx, uplink arm, call-in cards, enemy aim,
	-- carry, squad tags, pop sound, shot sound path, prone legs, stim sprint, pad interact, grenade throw, call-in punch,
	-- armour tag, skiff, player splash, mission time, left shoulder, stim pose, perf saver, ammo pack, colour grade picked
	-- and baked into the code defaults (list: docs/playtest-verdicts-2026-11-15.md).
	{
		-- shared/Carry.speedMult (client/Movement): walk / sprint speed while carrying a core cell (haul objective)
		name = "CARRY SPEED",
		keys = { "Feel_CarryWalk", "Feel_CarrySprint" },
		presets = {
			{ name = "A walk x0.80, sprint x0.80", set = {} },
			{ name = "B walk x0.85, sprint x0.75", set = { Feel_CarryWalk = 0.85, Feel_CarrySprint = 0.75 } },
			{ name = "C walk x0.90, sprint x0.85", set = { Feel_CarryWalk = 0.9, Feel_CarrySprint = 0.85 } },
		},
	},
	{
		-- client/Fx/Blast.luau + Fx/CallInFx: camera shake of explosions (2026-11-15: "much stronger than x1.6")
		name = "BLAST SHAKE",
		keys = { "Feel_BlastShake" },
		presets = {
			{ name = "A strong (x2.6)", set = {} },
			{ name = "B x2", set = { Feel_BlastShake = 2 } },
			{ name = "C brutal (x3.4)", set = { Feel_BlastShake = 3.4 } },
		},
	},
	{
		-- client/CameraController: camera lean on the shoulder swap (V / R3)
		name = "SHOULDER LEAN",
		keys = { "Feel_ShoulderLean" },
		presets = {
			{ name = "A lean held + dip on swap", set = {} },
			{ name = "B lean + dip only during the swap", set = { Feel_ShoulderLean = "swap" } },
			{ name = "C off", set = { Feel_ShoulderLean = "off" } },
		},
	},
	{
		-- client/CombatPose (+ Fx/GunFeel casings): the gun follows the camera to the left shoulder (V / R3)
		name = "LEFT HAND",
		keys = { "Feel_LeftShoulder", "Feel_LeftCasings" },
		presets = {
			{ name = "A gun mirrors with the camera, brass out left", set = {} },
			{ name = "B gun mirrors, brass from the gun's right port", set = { Feel_LeftCasings = "port" } },
			{ name = "C always right-handed (old)", set = { Feel_LeftShoulder = "old" } },
		},
	},
	{
		-- client/Fx/Blast.luau: mushroom cloud (stem + cap + rolling ring) on fire blasts from a Huge frag up
		name = "MUSHROOM",
		keys = { "Feel_Mushroom" },
		presets = {
			{ name = "A on", set = {} },
			{ name = "B bigger cap (x1.35)", set = { Feel_Mushroom = "big" } },
			{ name = "C off", set = { Feel_Mushroom = "off" } },
		},
	},
	{
		-- client/UI/HudSkin + HUD.rebuild: the in-mission HUD's look and layout, rebuilt live (D = the old HUD)
		name = "UI STYLE",
		keys = { "Feel_UiStyle" },
		presets = {
			{ name = "A Hairline (thin lines, angled cuts)", set = {} },
			{ name = "B Soft glass (rounded, translucent)", set = { Feel_UiStyle = "glass" } },
			{ name = "C Visor (one phosphor colour, mono)", set = { Feel_UiStyle = "visor" } },
			{ name = "D old HUD", set = { Feel_UiStyle = "old" } },
		},
	},
	{
		-- client/UI/HUD crosshair satellites (new UI STYLE only): mag count + health arc next to the crosshair
		name = "CROSSHAIR INFO",
		keys = { "Feel_XhairInfo" },
		presets = {
			{ name = "A on low ammo / low health", set = {} },
			{ name = "B always", set = { Feel_XhairInfo = "always" } },
			{ name = "C off", set = { Feel_XhairInfo = "off" } },
		},
	},
	{
		-- client/UI/GoalLine (new UI STYLE only, PC): what sits under the goal line; the full list is in the mission sheet
		name = "GOAL LINES",
		keys = { "Feel_GoalLines" },
		presets = {
			{ name = "A current step only (hold Tab for the list)", set = {} },
			{ name = "B + next 2 steps, smaller", set = { Feel_GoalLines = "next" } },
		},
	},
	{
		-- client/UI/Theme.applyFont: swaps the face of every HUD / menu text live (sizes stay)
		name = "UI FONT",
		keys = { "Feel_Font" },
		presets = {
			{ name = "A Oswald + Gotham (current)", set = {} },
			{ name = "B Builder Sans (Roblox)", set = { Feel_Font = "BuilderSans" } },
			{ name = "C Titillium Web (techy)", set = { Feel_Font = "TitilliumWeb" } },
			{ name = "D Sarpanch (sci-fi square)", set = { Feel_Font = "Sarpanch" } },
			{ name = "E Fredoka One (round cartoon)", set = { Feel_Font = "FredokaOne" } },
		},
	},
	{
		-- client/Fx/EnemyFx: heavy-target damage stages (smoke / breach / fire), impact puffs, burning death plates
		name = "DAMAGE STAGES",
		keys = { "Feel_StageFx" },
		presets = {
			{ name = "A default (x1)", set = {} },
			{ name = "B subtle (x0.5)", set = { Feel_StageFx = 0.5 } },
			{ name = "C heavy (x1.6)", set = { Feel_StageFx = 1.6 } },
			{ name = "D off (old look)", set = { Feel_StageFx = 0 } },
		},
	},
	{
		-- client/ThrowArc: predicted path + landing ring while a beacon is armed or the grenade button is held
		name = "THROW ARC",
		keys = { "Feel_ThrowArc" },
		presets = {
			{ name = "A arrow + ghost + ring", set = {} },
			{ name = "B old dots + ring", set = { Feel_ThrowArc = "dots" } },
			{ name = "C ring only", set = { Feel_ThrowArc = "ring" } },
		},
	},
	{
		-- client/CameraController + client/UI/ScopeOverlay: aiming a zoom >= 2 weapon (MR-9 Longwatch)
		name = "SCOPE",
		keys = { "Feel_Scope" },
		presets = {
			{ name = "A first-person scope", set = {} },
			{ name = "B old third-person zoom", set = { Feel_Scope = "old" } },
			{ name = "C scope, 0.15 s fade-in from black", set = { Feel_Scope = "fade" } },
		},
	},
	{
		-- server/WeatherService + client/Fx/Weather: dust storms on desert / ash (calm 2-4 min, storm 40-70 s)
		name = "WEATHER",
		keys = { "Feel_Weather" },
		server = true,
		presets = {
			{ name = "A storms on", set = {} },
			{ name = "B always clear", set = { Feel_Weather = "clear" } },
			{ name = "C storm now (then every 20 s calm)", set = { Feel_Weather = "now" } },
		},
	},
	{
		-- server/Objectives/SideWreck: download length and wave count, read when the download starts (server = mirrored)
		name = "WRECK DOWNLOAD",
		keys = { "Feel_WreckDownload" },
		server = true,
		presets = {
			{ name = "A 45 s, 3 waves", set = {} },
			{ name = "B 30 s, 2 waves", set = { Feel_WreckDownload = "B" } },
			{ name = "C 60 s, 4 waves", set = { Feel_WreckDownload = "C" } },
		},
	},
	{
		-- server/Objectives/SideConvoy: number of Strider walkers, read when the mission starts (server = mirrored)
		name = "CONVOY",
		keys = { "Feel_ConvoyCount" },
		server = true,
		presets = {
			{ name = "A 3 walkers", set = {} },
			{ name = "B 2 walkers", set = { Feel_ConvoyCount = 2 } },
			{ name = "C 5 walkers", set = { Feel_ConvoyCount = 5 } },
		},
	},
	{
		-- server/Objectives/SideRadar: how the dish is tuned, read when a player uses the console (server = mirrored)
		name = "RADAR TUNE",
		keys = { "Feel_RadarTune" },
		server = true,
		presets = {
			{ name = "A sweep, 3 taps in the band", set = {} },
			{ name = "B sweep, 2 taps in the band", set = { Feel_RadarTune = "sweep2" } },
			{ name = "C hold 4 s only (no mini-game)", set = { Feel_RadarTune = "hold" } },
		},
	},
	{
		-- server/Objectives/SideRadar: enemy-group ping on the compass while the radar runs (server = mirrored)
		name = "RADAR PING",
		keys = { "Feel_RadarPing" },
		server = true,
		presets = {
			{ name = "A every 20 s", set = {} },
			{ name = "B every 12 s", set = { Feel_RadarPing = 12 } },
			{ name = "C off", set = { Feel_RadarPing = "off" } },
		},
	},
	{
		-- server/Objectives/SideJammer: jam radius and charge fuse, read when the mission's objectives start (server = mirrored)
		name = "JAMMER",
		keys = { "Feel_Jammer" },
		server = true,
		presets = {
			{ name = "A 60 m radius, 10 s fuse", set = {} },
			{ name = "B 45 m radius, 8 s fuse", set = { Feel_Jammer = "B" } },
			{ name = "C 80 m radius, 12 s fuse", set = { Feel_Jammer = "C" } },
		},
	},
	{
		-- server/Objectives/SideFoundry: seconds between drone launches with a trooper within 150 m (far = x25/12),
		-- read live (server = mirrored)
		name = "FOUNDRY RATE",
		keys = { "Feel_FoundryRate" },
		server = true,
		presets = {
			{ name = "A every 12 s (far 25 s)", set = {} },
			{ name = "B every 8 s (far ~17 s)", set = { Feel_FoundryRate = 8 } },
			{ name = "C every 18 s (far ~38 s)", set = { Feel_FoundryRate = 18 } },
		},
	},
	{
		-- server/Enemies/DroneAI: foundry drone shot cone, read per shot (server = mirrored)
		name = "DRONE AIM",
		keys = { "Feel_DroneAim" },
		server = true,
		presets = {
			{ name = "A loose (6.5 deg cone, no lead)", set = {} },
			{ name = "B tight (2.2 deg cone, half lead)", set = { Feel_DroneAim = "tight" } },
		},
	},
	{
		-- client/UI/Pings + server/PingService: look + middle mouse / D-pad Right / touch long press = squad ping marker
		name = "SQUAD PING",
		keys = { "Feel_Ping" },
		presets = {
			{ name = "A off (input does nothing)", set = {} },
			{ name = "B on (middle mouse / D-pad Right / long press)", set = { Feel_Ping = "on" } },
		},
	},
	{
		-- IDEA (night/2026-11-14-ideas): server/CallIns/Effects/RAILSHOT molten pool after the slug (server = mirrored)
		name = "RAILSHOT HOT GROUND",
		keys = { "Feel_RailHot" },
		server = true,
		presets = {
			{ name = "A off", set = {} },
			{ name = "B molten pool 6 s", set = { Feel_RailHot = "on" } },
		},
	},
	{
		-- IDEA (night/2026-11-14-ideas): server/CallIns/Combos, overlapping call-ins combine (server = mirrored)
		name = "CALL-IN COMBOS",
		keys = { "Feel_Combos" },
		server = true,
		presets = {
			{ name = "A off", set = {} },
			{ name = "B fire vortex (Gravity Well + fire)", set = { Feel_Combos = "on" } },
		},
	},
	{
		-- IDEA (night/2026-11-14-ideas): server/Hazards debris showers during the mission (server = mirrored)
		name = "PLANET HAZARD",
		keys = { "Feel_Hazard" },
		server = true,
		presets = {
			{ name = "A off", set = {} },
			{ name = "B debris showers", set = { Feel_Hazard = "debris" } },
			{ name = "C debris every 30-45 s (testing)", set = { Feel_Hazard = "debris_fast" } },
		},
	},
	{
		-- IDEA (night/2026-11-14-ideas): server/Enemies/LootRunner: a courier runs from the squad, kill it for a resupply (server = mirrored)
		name = "LOOT RUNNER",
		keys = { "Feel_LootRunner" },
		server = true,
		presets = {
			{ name = "A off", set = {} },
			{ name = "B on (every 3-5 min)", set = { Feel_LootRunner = "on" } },
			{ name = "C on, every 40-60 s (testing)", set = { Feel_LootRunner = "fast" } },
		},
	},
	{
		-- IDEA (night/2026-11-14-ideas): server/Enemies/Elites: some regular / medium spawns are elites with one affix (server = mirrored)
		name = "ELITES",
		keys = { "Feel_Elites" },
		server = true,
		presets = {
			{ name = "A on (15 % of spawns)", set = {} },
			{ name = "B off", set = { Feel_Elites = "off" } },
			{ name = "C on, 40 % (testing)", set = { Feel_Elites = "fast" } },
		},
	},
	{
		-- server/Downed.luau: a killing hit puts you down (crawl, sidearm, bleed-out); stim or a squadmate gets you up.
		-- Test: press M in the arena (takes a 60 hp hit, god mode off); 3 hits = down
		name = "DOWNED",
		keys = { "Feel_Downed" },
		server = true,
		presets = {
			{ name = "A on, 12 s bleed-out", set = {} },
			{ name = "B on, 20 s bleed-out", set = { Feel_Downed = "long" } },
			{ name = "C off (instant death, old)", set = { Feel_Downed = "off" } },
		},
	},
	{
		-- server/Objectives/SideAirDefence + server/AirDefence: once the AA battery is online, enemy dropships are shot down
		-- (Studio quick mission: QuickStartSides = "AIRDEF")
		name = "AIR DEFENCE",
		keys = { "Feel_AirDefence" },
		server = true,
		presets = {
			{ name = "A every dropship shot down", set = {} },
			{ name = "B every second dropship", set = { Feel_AirDefence = "half" } },
		},
	},
	{
		-- client/Fx/VitalsFx + server/PlayerService: hold the stim key (F / D-pad Left / touch STIM) this long; a bar fills
		-- under the prompt, early release = no stim. Read by the server too (server = mirrored)
		name = "STIM HOLD",
		keys = { "Feel_StimHold" },
		server = true,
		presets = {
			{ name = "A hold 0.8 s", set = {} },
			{ name = "B hold 0.5 s", set = { Feel_StimHold = 0.5 } },
			{ name = "C hold 1.2 s", set = { Feel_StimHold = 1.2 } },
			{ name = "D tap (old)", set = { Feel_StimHold = 0 } },
		},
	},
	{
		-- client/DownedPose + Movement: how a downed trooper lies (everyone sees it). Test: arena key M x3 = down
		name = "DOWNED POSE",
		keys = { "Feel_DownedPose" },
		presets = {
			{ name = "A propped on the left elbow", set = {} },
			{ name = "B on the back", set = { Feel_DownedPose = "back" } },
			{ name = "C plain prone (old)", set = { Feel_DownedPose = "prone" } },
		},
	},
	{
		-- client/DownedPose + Movement: getting up from downed (stim or squadmate revive)
		name = "GET UP",
		keys = { "Feel_DownedGetUp" },
		presets = {
			{ name = "A push up, crouch, stand (~0.4 s)", set = {} },
			{ name = "B straight up (old)", set = { Feel_DownedGetUp = "snap" } },
		},
	},
	{
		-- Phone perf tuning. client/Fx/EnemyAnim: 100-stud enemy anim range at quality 0.5 (was 160), at most 6 hit
		-- Highlights at once (was 20). client/FootPlant: heel + toe rays only. client/Fx/CallInFx: beacon pulse written at
		-- 20 Hz. server/Enemies/EnemyAI: non-fodder ground snap every 0.9 studs (was 0.25); the server can't tell who is on
		-- touch, so its part is on for both B and C (server = mirrored).
		name = "PERF",
		keys = { "Feel_Perf" },
		server = true,
		presets = {
			{ name = "A current (off)", set = {} },
			{ name = "B on touch devices only", set = { Feel_Perf = "touch" } },
			{ name = "C everywhere (judge on PC)", set = { Feel_Perf = "all" } },
		},
	},
	{
		-- client/Fx/LumenFx: Lumen Concord charge / beam / pulse / blink / rift / shard death sizes and counts, and the
		-- crystal-biome aurora. The pulse ring always shows the real damage radius.
		name = "LUMEN FX",
		keys = { "Feel_LumenFx" },
		presets = {
			{ name = "A bigger + brighter, more shards (picked)", set = {} },
			{ name = "B first-pass sizes", set = { Feel_LumenFx = "normal" } },
			{ name = "C minimal (fewer parts, no lights, no aurora)", set = { Feel_LumenFx = "min" } },
		},
	},
	{
		-- client/Audio: Feel_Sound "off" mutes every sound on this client (master group 0, stray Sounds routed silent)
		name = "SOUND",
		keys = { "Feel_Sound" },
		presets = {
			{ name = "A on", set = {} },
			{ name = "B ALL SOUND OFF", set = { Feel_Sound = "off" } },
		},
	},
	{
		-- client/UI/Tips: first-time hint card at the top centre (shared/Data/Tips.luau)
		name = "TIPS",
		keys = { "Feel_Tips" },
		presets = {
			{ name = "A hints on", set = {} },
			{ name = "B only the first 3 min of combat", set = { Feel_Tips = "early" } },
			{ name = "C off", set = { Feel_Tips = "off" } },
		},
	},
	{
		-- client/UI/AfterAction: mission-end report (numbers per trooper from server/MissionStats); read when a report arrives
		name = "AFTER ACTION",
		keys = { "Feel_AfterAction" },
		presets = {
			{ name = "A full report (objectives + stats per trooper)", set = {} },
			{ name = "B compact (banner + titles only)", set = { Feel_AfterAction = "compact" } },
			{ name = "C off (results panel only, old)", set = { Feel_AfterAction = "off" } },
		},
	},
	{
		-- server/Enemies/EnemyAI (per-unit numbers in shared/Data/Enemies `tactics`): COG hold range + side-step, callout,
		-- flank, wounded Rivet backs off, Bulwark pushes; Brood packs spread their approach, swarm Skitterlings sometimes leap,
		-- a wounded Charger / Titan screeches and speeds up nearby bugs. Arena keys 4/8/I (COG), 5/7/O (Brood)
		name = "ENEMY TACTICS",
		keys = { "Feel_EnemyTactics" },
		server = true,
		presets = {
			{ name = "A on", set = {} },
			{ name = "B stronger (2x flank + leap chance, wider spread)", set = { Feel_EnemyTactics = "strong" } },
			{ name = "C off (old straight-in AI)", set = { Feel_EnemyTactics = "off" } },
		},
	},
	{
		-- touch only (Studio Device Emulator): UI/EventFeed FEED button, UI/HUD beacon prompt / kill streak / barrel ring
		name = "PHONE HUD",
		keys = { "Feel_PhoneHud" },
		presets = {
			{ name = "A FEED top row, prompt + streak above crosshair, ring x0.7", set = {} },
			{ name = "B old (FEED bottom-left, prompt low, streak high)", set = { Feel_PhoneHud = "old" } },
		},
	},
	{
		-- client/Input: gamepad L3 sprint
		name = "PAD SPRINT",
		keys = { "Feel_PadSprint" },
		presets = {
			{ name = "A L3 click toggles, stops when the stick is let go", set = {} },
			{ name = "B hold L3 (old)", set = { Feel_PadSprint = "hold" } },
		},
	},
	{
		-- server/WeaponService: what a reload does with the magazine still in the gun (server = mirrored); HUD reserve readout
		name = "MAGS",
		keys = { "Feel_Mags" },
		server = true,
		presets = {
			{ name = "A mags, early reload throws the rounds left away", set = {} },
			{ name = "B mags, part-used mag kept and loaded last", set = { Feel_Mags = "keep" } },
			{ name = "C pooled rounds, nothing lost", set = { Feel_Mags = "pool" } },
		},
	},
	{
		-- client/Sway: aim-point drift + breathing while aiming, more after sprinting / low stamina, less crouched / prone
		name = "SWAY",
		keys = { "Feel_Sway" },
		presets = {
			{ name = "A light", set = {} },
			{ name = "B stronger (x2.2)", set = { Feel_Sway = "strong" } },
			{ name = "C off", set = { Feel_Sway = "off" } },
		},
	},
}

-- sound layer swaps: Audio reads layer.id at play time, so editing the shared Sounds table is enough
local Sounds = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Sounds"))
local originalIds: { [string]: { [number]: string } } = {}
local function applySounds(g: any, p: any)
	-- restore every layer this group ever touched, then apply the preset's swaps
	for _, preset in g.presets do
		for key, swaps in (preset.sounds or {}) do
			local entry = Sounds[key]
			if entry then
				originalIds[key] = originalIds[key] or {}
				for i in swaps do
					local layer = entry.layers[i]
					if layer then
						if originalIds[key][i] == nil then
							originalIds[key][i] = layer.id
						end
						layer.id = originalIds[key][i]
					end
				end
			end
		end
	end
	for key, swaps in (p.sounds or {}) do
		local entry = Sounds[key]
		if entry then
			for i, id in swaps do
				if entry.layers[i] then
					entry.layers[i].id = id
				end
			end
		end
	end
end

local groupIdx, presetIdx = 1, 1
local label: TextLabel? = nil

local function apply()
	local g = GROUPS[groupIdx]
	local p = g.presets[presetIdx]
	for _, k in g.keys do
		workspace:SetAttribute(k, (p.set or {})[k])
	end
	-- groups marked `server` are read by server code: mirror them (server/PlayerService Action "studioFeel")
	if g.server then
		local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Net"))
		for _, k in g.keys do
			Net.event("Action"):FireServer("studioFeel", k, (p.set or {})[k])
		end
	end
	applySounds(g, p)
	if label then
		label.Text = string.format("%s: %s  (%d/%d)   K / L switch   J next group", g.name, p.name, presetIdx, #g.presets)
	end
end

function Variants.init()
	if not RunService:IsStudio() then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "Variants"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.IgnoreGuiInset = true
	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0)
	l.Position = UDim2.new(0.5, 0, 0, 104)
	l.Size = UDim2.fromOffset(420, 20)
	l.BackgroundColor3 = Color3.new(0, 0, 0)
	l.BackgroundTransparency = 0.45
	l.BorderSizePixel = 0
	l.TextColor3 = Color3.fromRGB(255, 200, 120)
	l.Font = Enum.Font.GothamBold
	l.TextSize = 13
	l.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	label = l
	apply()

	UserInputService.InputBegan:Connect(function(io, processed)
		if processed or io.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		local g = GROUPS[groupIdx]
		local k = io.KeyCode
		-- letters work on every keyboard layout; [ ] \ kept as alternates
		if k == Enum.KeyCode.L or k == Enum.KeyCode.RightBracket then
			presetIdx = presetIdx % #g.presets + 1
			apply()
		elseif k == Enum.KeyCode.K or k == Enum.KeyCode.LeftBracket then
			presetIdx = (presetIdx - 2) % #g.presets + 1
			apply()
		elseif (k == Enum.KeyCode.J or k == Enum.KeyCode.BackSlash) and #GROUPS > 1 then
			groupIdx = groupIdx % #GROUPS + 1
			presetIdx = 1
			apply()
		end
	end)
end

return Variants
