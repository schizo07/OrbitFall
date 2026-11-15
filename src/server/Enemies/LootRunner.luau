-- S.LootRunner: now and then a loot runner shows up near the squad and runs away. Kill it inside ESCAPE_T seconds and it bursts
-- into a resupply for every trooper within BURST_R studs (plus the one who landed the kill): ammo, stims, a grenade, and a bit
-- of bonus salvage on the results screen. Mission starts / stops it next to Hazards.
--
--   Runner kinds (Data/Enemies.luau): COG "Scrap Courier" (LOOT_COG), BROOD "Gilded Grub" (LOOT_BROOD); the LUMEN faction
--   gets the COG cart. ~250 HP, light armour, 1.15 x trooper sprint speed. EnemyAI moves it (def.behavior = "flee": runs from
--   the nearest trooper, zig-zags, never attacks); it goes through EnemyService like any enemy, so every weapon, status and
--   kill credit works. Models: server/Enemies/EnemyModels.luau. Client marker (compass pip + billboard) and bursts:
--   client/Fx/EnemyFx.luau, Fx kinds "LootBurst" and "LootEscape".
--
--   Studio A/B workspace attribute Feel_LootRunner (Variants group "LOOT RUNNER", mirrored by the "studioFeel" action):
--     nil / anything else  off
--     "on"                 one runner every 3-5 min
--     "fast"               one runner every 40-60 s (testing)
--
--   LootRunner.start(map)  LootRunner.stop()   (Mission: next to Hazards)
--   LootRunner.spawnNow()  one runner now, near a random living trooper (DebugHook "lootrunner")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local LootRunner = {}
local S: any = nil

local rng = Random.new()
local token = 0 -- bumped by start / stop: invalidates the running timer loop and every watcher
local current: any = nil -- the live runner (one at a time)

-- tuning
local ESCAPE_T = 40 -- s before it burrows away
local DIST = { 30, 45 } -- studs from the chosen trooper
local VIEW_DOT = 0.45 -- spawn spots inside this forward cone (cos) of a trooper, within VIEW_RANGE, count as "seen"
local VIEW_RANGE = 90
local BURST_R = 15 -- troopers within this of the kill get the resupply
local RESUPPLY_GRENADES = 1
local BONUS_SALVAGE = 40 -- per trooper in range, added to the mission results
local GAPS = { on = { 180, 300 }, fast = { 40, 60 } }
local GOLD = Config.Colors.Gold

function LootRunner.init(s)
	S = s
end

local function mode(): string?
	local v = workspace:GetAttribute("Feel_LootRunner")
	if v == "on" or v == "fast" then
		return v
	end
	return nil
end

local function missionLive(): boolean
	local st = S.Mission and S.Mission.state
	return st == "Active" or st == "Extract"
end

local function groundAt(x: number, z: number, refY: number): number
	local m = S.Map and S.Map.current
	if m and m.groundY then
		local ok, y = pcall(m.groundY, x, z)
		if ok and type(y) == "number" then
			return y
		end
	end
	return refY
end

-- Reward ------------------------------------------------------------------------------
local function reward(e: any)
	local pos: Vector3 = e.pos
	S.Fx.play("LootBurst", { p = pos + Vector3.new(0, 2, 0), f = e.faction })
	local lucky = {}
	for _, p in S.Players.getAlive() do
		local root = S.Players.getRoot(p)
		if root and (root.Position - pos).Magnitude <= BURST_R then
			lucky[p] = true
		end
	end
	-- whoever landed the kill is never left out (a sniper shot from 80 studs still pays)
	local killer = e.lastHitBy
	if killer and typeof(killer) == "Instance" and killer:IsA("Player") and killer.Parent and S.Players.isAlive(killer) then
		lucky[killer] = true
	end
	local n = 0
	for p in lucky do
		n += 1
		S.Players.refill(p, { grenades = RESUPPLY_GRENADES })
		local loot = S.Mission and S.Mission.lootSalvage
		if loot and not S.Mission.arena then
			loot[p] = (loot[p] or 0) + BONUS_SALVAGE
		end
	end
	if n == 0 then
		S.State.notify(nil, "Loot runner down, but nobody was close enough to grab the loot.", GOLD)
	end
end

local function escape(e: any)
	S.Fx.play("LootEscape", { p = e.pos + Vector3.new(0, 1, 0), f = e.faction })
	S.Enemies.despawn(e)
	S.State.notify(nil, "The loot runner got away.", Config.Colors.Danger)
end

-- watches one runner: killed (reward), out of time (escape) or the mission ended (silent removal)
local function watch(e: any, my: number)
	local born = os.clock()
	while true do
		task.wait(0.1)
		if token ~= my then
			return -- Mission cleanup clears the enemies
		end
		if not e.alive then
			reward(e)
			return
		end
		if not missionLive() then
			S.Enemies.despawn(e)
			return
		end
		if os.clock() - born >= ESCAPE_T then
			escape(e)
			return
		end
	end
end

-- Spawn -------------------------------------------------------------------------------
-- a random living trooper, 30-45 studs away, preferably outside every trooper's forward cone
function LootRunner.spawnNow(): any?
	if not S or (current and current.alive) then
		return nil
	end
	local alive = S.Players.getAlive()
	local roots: { BasePart } = {}
	for _, p in alive do
		local r = S.Players.getRoot(p)
		if r then
			table.insert(roots, r)
		end
	end
	if #roots == 0 then
		return nil
	end
	local base = roots[rng:NextInteger(1, #roots)]
	local half = Config.MapSize / 2 - 8
	local spot: Vector3? = nil
	for _ = 1, 14 do
		local ang = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(DIST[1], DIST[2])
		local x = math.clamp(base.Position.X + math.cos(ang) * dist, -half, half)
		local z = math.clamp(base.Position.Z + math.sin(ang) * dist, -half, half)
		local pos = Vector3.new(x, groundAt(x, z, base.Position.Y - 3), z)
		local seen = false
		for _, r in roots do
			local to = Vector3.new(pos.X - r.Position.X, 0, pos.Z - r.Position.Z)
			local m = to.Magnitude
			if m > 0.1 and m < VIEW_RANGE and r.CFrame.LookVector:Dot(to / m) > VIEW_DOT then
				seen = true
				break
			end
		end
		spot = spot or pos -- fallback: the first candidate, even if somebody sees it
		if not seen then
			spot = pos
			break
		end
	end
	local pos = spot :: Vector3
	local away = Vector3.new(pos.X - base.Position.X, 0, pos.Z - base.Position.Z)
	local look = if away.Magnitude > 0.1 then pos + away.Unit else pos + Vector3.new(0, 0, -1)
	local kind = if S.Mission and S.Mission.faction == "BROOD" then "LOOT_BROOD" else "LOOT_COG"
	local ok, e = pcall(S.Enemies.spawn, kind, CFrame.lookAt(pos, look), { hpScale = 1 }) -- ~250 HP at every difficulty
	if not ok or not e then
		warn("[LootRunner] spawn failed:", e)
		return nil
	end
	current = e
	e.model:SetAttribute("LootEnds", workspace:GetServerTimeNow() + ESCAPE_T) -- client marker countdown
	S.State.notify(nil, "Loot runner spotted!", GOLD)
	local my = token
	task.spawn(watch, e, my)
	return e
end

-- Lifecycle ---------------------------------------------------------------------------
function LootRunner.stop()
	token += 1
	current = nil
end

function LootRunner.start(_map: any?)
	token += 1
	current = nil
	local my = token
	task.spawn(function()
		local nextAt = os.clock() + 1e9 -- armed when the A/B turns on
		local armedMode: string? = nil
		while token == my do
			task.wait(1)
			if token ~= my or not missionLive() then
				continue
			end
			local m = mode()
			if m ~= armedMode then -- A/B switched: restart the countdown with that preset's gap
				armedMode = m
				if m then
					local g = GAPS[m]
					nextAt = os.clock() + rng:NextNumber(g[1], g[2])
					if game:GetService("RunService"):IsStudio() then
						print(string.format("[LootRunner] %s armed, first runner in %.0f s", m, nextAt - os.clock()))
					end
				end
			end
			if m and os.clock() >= nextAt then
				LootRunner.spawnNow()
				local g = GAPS[m]
				nextAt = os.clock() + rng:NextNumber(g[1], g[2])
			end
		end
	end)
end

return LootRunner
