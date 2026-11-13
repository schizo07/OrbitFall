-- Mission state machine (docs/spec.md §2.1):
-- Ship -> Countdown -> Drop -> Active -> Extract -> Results -> Ship   (or -> Failed -> Ship)
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Enemies = require(Shared.Data.Enemies)
local Planets = require(Shared.Data.Planets)

local Mission = {}
local S

Mission.state = "Ship"
Mission.endsAt = 0
Mission.lives = 0
Mission.faction = "COG"
Mission.planet = nil :: string?
Mission.difficulty = 1
Mission.objective = "MISSILE"
Mission.extract = nil :: any
Mission.kills = {} :: { [Player]: number }
Mission.lastBeacon = nil :: Vector3?

local token = 0 -- invalidates stale timers when the mission changes
local OBJECTIVE_NAMES = { MISSILE = "Missile Launch", UPLINK = "Uplink Relay" }

local function now()
	return workspace:GetServerTimeNow()
end

local function snapshot()
	return {
		state = Mission.state,
		endsAt = Mission.endsAt,
		lives = Mission.lives,
		faction = Mission.faction,
		factionName = Enemies.Factions[Mission.faction] and Enemies.Factions[Mission.faction].name or "",
		planet = Mission.planet,
		planetName = Mission.planet and Planets.get(Mission.planet) and (Planets.get(Mission.planet) :: any).name or nil,
		difficulty = Mission.difficulty,
		objectiveName = OBJECTIVE_NAMES[Mission.objective] or Mission.objective,
		extract = Mission.extract,
	}
end

function Mission.broadcast()
	S.State.broadcast("mission", snapshot())
end

local function setState(st: string, duration: number?)
	Mission.state = st
	Mission.endsAt = duration and (now() + duration) or 0
	Mission.broadcast()
end

function Mission.setExtract(info)
	Mission.extract = info
	-- Skiff inbound / on the pad: the mission clock must not run out under the squad mid-boarding or mid-takeoff
	-- (beginExtraction only extended it relative to when the main objective finished, not to when the Skiff was called)
	if type(info) == "table" and Mission.state == "Extract" then
		local windowEnd = info.window or ((info.eta or now()) + Config.ExtractWindow)
		Mission.endsAt = math.max(Mission.endsAt, windowEnd + 30)
	end
	Mission.broadcast()
end

function Mission.useLife(): boolean
	if Mission.lives <= 0 then
		return false
	end
	Mission.lives -= 1
	Mission.broadcast()
	return true
end

function Mission.onKill(_enemy, source)
	local p = source and source.player
	if p and typeof(p) == "Instance" and p:IsA("Player") then
		Mission.kills[p] = (Mission.kills[p] or 0) + 1
	end
end

function Mission.onBeacon(pos: Vector3)
	Mission.lastBeacon = pos
end

local function inMission()
	return Mission.state == "Drop" or Mission.state == "Active" or Mission.state == "Extract"
end

function Mission.onPlayerDied(_p: Player)
	-- fail check happens in the tick loop
end

function Mission.onPlayerJoined(p: Player)
	if inMission() and S.Map.current then
		S.Players.respawnAt(p, S.Map.current.insertion.Position)
	else
		S.Players.spawnOnShip(p)
	end
end

local function cleanup()
	for _, svc in { S.Director, S.Objectives, S.Extraction, S.CallIns } do
		if svc then
			local f = svc.stop or svc.stopAll
			if svc.stopAll then
				f = svc.stopAll
			end
			if f then
				local ok, err = pcall(f)
				if not ok then
					warn("[Mission] cleanup", err)
				end
			end
		end
	end
	if S.Enemies then
		pcall(S.Enemies.clear)
	end
	if S.Projectiles and S.Projectiles.clear then
		pcall(S.Projectiles.clear)
	end
	local f = workspace:FindFirstChild("CallInObjects")
	if f then
		f:ClearAllChildren()
	end
end

local function returnToShip()
	cleanup()
	Mission.extract = nil
	Mission.lastBeacon = nil
	setState("Ship")
	for _, p in Players:GetPlayers() do
		task.spawn(S.Players.spawnOnShip, p)
	end
	task.defer(function()
		if S.Map and S.Map.clear then
			pcall(S.Map.clear)
		end
	end)
end

local function finish(success: boolean)
	if not inMission() then
		return
	end
	token += 1
	local my = token
	local mainSteps = S.Objectives.getMainSteps and S.Objectives.getMainSteps() or 0
	local sides = S.Objectives.getSidesDone and S.Objectives.getSidesDone() or 0
	local samples = S.Objectives.getSamples and S.Objectives.getSamples() or 0
	if S.Director then
		pcall(S.Director.stop)
	end
	local st = success and "Results" or "Failed"
	setState(st, success and Config.ResultsTime or Config.FailedTime)
	S.Fx.play("Sound", { k = success and "MissionSuccess" or "MissionFail" })
	if success and Mission.planet and S.War then
		pcall(S.War.contribute, Mission.planet, Mission.difficulty, Players:GetPlayers())
	end
	for _, p in Players:GetPlayers() do
		-- pcall: a reward error must not strand the squad in Results (the return-to-ship timer is scheduled below)
		local okR, res = pcall(S.Progress.reward, p, {
			success = success,
			mainSteps = mainSteps,
			sides = sides,
			samples = samples,
			kills = Mission.kills[p] or 0,
		})
		if not okR then
			warn("[Mission] reward failed:", res)
			res = nil
		end
		local snap = snapshot()
		snap.results = res
		S.State.send(p, "mission", snap)
	end
	task.delay(success and Config.ResultsTime or Config.FailedTime, function()
		if token == my then
			returnToShip()
		end
	end)
end

local function tick(my: number)
	local deadSince: number? = nil
	while token == my and inMission() do
		task.wait(0.5)
		if token ~= my then
			return
		end
		if now() > Mission.endsAt and Mission.state ~= "Drop" then
			S.State.notify(nil, "Mission timer expired. The Halcyon is pulling out!", Config.Colors.Danger)
			finish(false)
			return
		end
		local alive = S.Players.getAlive()
		local anyDropping = false
		for _, p in Players:GetPlayers() do
			local r = S.Players.get(p)
			if r and r.dropping then
				anyDropping = true
			end
		end
		if #alive == 0 and not anyDropping and #Players:GetPlayers() > 0 then
			deadSince = deadSince or os.clock()
			if Mission.lives <= 0 then
				S.State.notify(nil, "Squad lost. No reinforcements left.", Config.Colors.Danger)
				finish(false)
				return
			elseif os.clock() - deadSince > Config.AutoReinforceDelay then
				deadSince = nil
				local at = Mission.lastBeacon or (S.Map.current and S.Map.current.insertion.Position)
				for _, p in S.Players.getDead() do
					if Mission.useLife() then
						S.Players.respawnAt(p, at)
					end
				end
				S.State.notify(nil, "Emergency reinforcements inbound!", Config.Colors.Accent)
			end
		else
			deadSince = nil
		end
	end
end

local function beginExtraction()
	if Mission.state ~= "Active" then
		return
	end
	Mission.state = "Extract"
	-- never let the mission clock run out mid-extraction
	Mission.endsAt = math.max(Mission.endsAt, now() + Config.ExtractEta + Config.ExtractWindow + 90)
	Mission.broadcast()
	S.State.notify(nil, "Main objective complete! Call the " .. Config.ShuttleName .. " at the extraction pad.", Config.Colors.Friendly)
	local my = token
	S.Extraction.start(S.Map.current, function(boarded)
		if token ~= my then
			return
		end
		finish(#boarded > 0)
	end)
end

function Mission.start(p: Player?, args)
	if Mission.state ~= "Ship" then
		return false, "A mission is already underway"
	end
	args = type(args) == "table" and args or {}
	Mission.planet = nil
	if args.planet ~= nil and S.War then
		local ok, factionOrReason = S.War.canPlay(args.planet)
		if not ok then
			return false, factionOrReason
		end
		Mission.planet = args.planet
		args.faction = factionOrReason
	elseif p ~= nil and S.War then
		return false, "Pick a planet on the war map"
	end
	Mission.faction = (args.faction == "BROOD") and "BROOD" or "COG"
	Mission.objective = (args.objective == "UPLINK") and "UPLINK" or "MISSILE"
	Mission.difficulty = math.clamp(math.floor(tonumber(args.difficulty) or 1), 1, 5)
	Mission.kills = {}
	Mission.extract = nil
	token += 1
	local my = token
	setState("Countdown", Config.StartCountdown)
	S.State.notify(nil, (p and p.DisplayName or "Squad") .. " is launching: " .. (OBJECTIVE_NAMES[Mission.objective]) .. (if Mission.planet then " on " .. ((Planets.get(Mission.planet) :: any).name) else "") .. " vs " .. Enemies.Factions[Mission.faction].name, Config.Colors.Accent)

	task.spawn(function()
		local built = false
		local okBuild, err = pcall(function()
			local pl = Mission.planet and Planets.get(Mission.planet)
			S.Map.build(Mission.faction, pl and pl.biome or nil)
		end)
		if not okBuild then
			warn("[Mission] map build failed:", err)
		end
		built = okBuild
		while token == my and now() < Mission.endsAt do
			task.wait(0.2)
		end
		if token ~= my then
			return
		end
		if not built or not S.Map.current then
			S.State.notify(nil, "Map failed to build.", Config.Colors.Danger)
			returnToShip()
			return
		end
		local map = S.Map.current
		local n = #Players:GetPlayers()
		Mission.lives = Config.LivesBase + Config.LivesPerPlayer * n
		setState("Drop", Config.MissionTime)
		Mission.state = "Drop"
		local ins = map.insertion.Position
		for i, pl in Players:GetPlayers() do
			local a = (i / math.max(n, 1)) * math.pi * 2
			local off = Vector3.new(math.cos(a) * 9, 0, math.sin(a) * 9)
			local x, z = ins.X + off.X, ins.Z + off.Z
			local y = map.groundY and map.groundY(x, z) or ins.Y
			S.Players.applyLoadout(pl)
			S.Players.dropTo(pl, Vector3.new(x, y, z), 2.2)
		end
		S.Fx.play("Sound", { k = "MissionStart" })
		task.wait(2.6)
		if token ~= my then
			return
		end
		Mission.state = "Active"
		Mission.broadcast()
		S.Objectives.onMainComplete = beginExtraction
		-- pcall: a failure here must not skip tick(), or the mission could never end (timer / squad-wipe checks live there)
		local okO, errO = pcall(S.Objectives.start, map, { main = Mission.objective, sides = { "NEST", "SAMPLES" }, faction = Mission.faction })
		if not okO then
			warn("[Mission] Objectives.start failed:", errO)
		end
		local okD, errD = pcall(S.Director.start, map, Mission.faction, Mission.difficulty)
		if not okD then
			warn("[Mission] Director.start failed:", errD)
		end
		tick(my)
	end)
	return true, nil
end

-- Debug helpers (used from the Studio command bar / MCP)
function Mission.debugFinish(success: boolean)
	finish(success)
end
function Mission.debugAbort()
	token += 1
	returnToShip()
end

function Mission.init(s)
	S = s
	S.Progress.on("startMission", function(p, args)
		return Mission.start(p, args)
	end)
end

return Mission
