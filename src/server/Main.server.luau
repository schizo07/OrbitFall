-- Server bootstrap: builds the service registry, inits in dependency order, then starts.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Config = require(Shared.Config)

Net.init()

local root = script.Parent
local S = require(root.Services)

local function try(name: string, path: () -> Instance?)
	local ok, inst = pcall(path)
	if not ok or not inst then
		warn("[Main] missing module", name)
		return nil
	end
	local ok2, mod = pcall(require, inst)
	if not ok2 then
		warn("[Main] failed to load", name, mod)
		return nil
	end
	return mod
end

S.Assets = try("Assets", function() return root.World.Assets end)
S.Actions = try("ActionRouter", function() return root.ActionRouter end)
S.Fx = try("FxService", function() return root.FxService end)
S.State = try("StateService", function() return root.StateService end)
S.Save = try("SaveService", function() return root.SaveService end)
S.Progress = try("ProgressService", function() return root.ProgressService end)
S.Shop = try("ShopService", function() return root.ShopService end)
S.Players = try("PlayerService", function() return root.PlayerService end)
S.Weapons = try("WeaponService", function() return root.WeaponService end)
S.Enemies = try("EnemyService", function() return root.Enemies.EnemyService end)
S.Projectiles = try("Projectiles", function() return root.Enemies.Projectiles end)
S.Director = try("Director", function() return root.Enemies.Director end)
S.CallIns = try("CallInService", function() return root.CallIns.CallInService end)
S.Map = try("MapBuilder", function() return root.World.MapBuilder end)
S.Ship = try("Ship", function() return root.World.Ship end)
S.Objectives = try("ObjectiveService", function() return root.Objectives.ObjectiveService end)
S.Extraction = try("Extraction", function() return root.Objectives.Extraction end)
S.War = try("WarService", function() return root.WarService end)
S.Mission = try("Mission", function() return root.Mission end)
S.TestArena = try("TestArena", function() return root.World.TestArena end) -- Studio test arena
S.DevTools = try("DevTools", function() return root.DevTools end) -- Studio quick start + arena keys remote
S.Hazards = try("Hazards", function() return root.Hazards end) -- planet hazards (debris showers), started by Mission
S.LootRunner = try("LootRunner", function() return root.Enemies.LootRunner end) -- loot runner (a courier that runs from the squad), started by Mission
S.Ping = try("PingService", function() return root.PingService end) -- squad ping relay
S.Explosions = try("Explosions", function() return root.Explosions end) -- blast entry point + onBlast listeners (no init needed)
S.Jammers = try("Jammers", function() return root.Jammers end) -- call-in jam areas (no init needed)
S.Weather = try("WeatherService", function() return root.WeatherService end) -- dust storm phases (workspace Weather attrs)

local ORDER = {
	"Assets", "Actions", "Fx", "State", "Save", "Progress", "Shop", "Enemies", "Projectiles", "Director",
	"CallIns", "Map", "Ship", "Objectives", "Extraction", "Players", "Weapons", "War", "Hazards", "LootRunner", "Mission", "TestArena", "DevTools", "Ping",
	"Weather",
}

for _, name in ORDER do
	local svc = S[name]
	if svc and svc.init then
		local ok, err = pcall(svc.init, S)
		if not ok then
			warn("[Main] init failed", name, err)
		end
	end
end

if not workspace:FindFirstChild("CallInObjects") then
	local folder = Instance.new("Folder")
	folder.Name = "CallInObjects"
	folder.Parent = workspace
end

-- Lobby deck
if S.Ship then
	local ok, res = pcall(S.Ship.build)
	if ok and res then
		S.shipSpawn = res.spawn
	else
		warn("[Main] ship build failed", res)
	end
end
S.shipSpawn = S.shipSpawn or CFrame.new(0, Config.ShipHeight + 5, 0)

-- Lifecycle start() only for services whose start() is a boot hook (others use start() for mission APIs).
local BOOT = { "Save", "Shop", "Enemies", "Projectiles", "Players", "War" }
for _, name in BOOT do
	local svc = S[name]
	if svc and svc.start then
		task.spawn(function()
			local ok, err = pcall(svc.start)
			if not ok then
				warn("[Main] start failed", name, err)
			end
		end)
	end
end

-- Debug hook for Studio MCP / command bar (separate Lua VMs can't share require caches).
local hook = Instance.new("BindableFunction")
hook.Name = "DebugHook"
hook.Parent = game:GetService("ServerStorage")
hook.OnInvoke = function(cmd: string, a: any, b: any, c: any)
	local Players = game:GetService("Players")
	local first = Players:GetPlayers()[1]
	if cmd == "start" then
		a = a or { faction = "COG", objective = "MISSILE", difficulty = 1 }
		-- no planet given: build the DESERT map for any faction (Studio only, see Mission.start `quickBiome`).
		-- Pass `biome = "swamp"` etc., or a `planet`, to override.
		if not a.planet and not a.quickBiome then
			a.quickBiome = a.biome or "desert"
		end
		if not a.planet and not a.quickBiome and S.War then -- pick a playable planet of the requested faction
			for id, st in S.War.state() do
				if st.playable and (a.faction == nil or st.faction == a.faction) then
					a.planet = id
					break
				end
			end
		end
		return S.Mission.start(first, a)
	elseif cmd == "finish" then
		S.Mission.debugFinish(a ~= false)
		return true
	elseif cmd == "abort" then
		S.Mission.debugAbort()
		return true
	elseif cmd == "spawn" then -- spawn(kind, distanceInFront)
		local root = first and S.Players.getRoot(first)
		if not root then
			return "no player"
		end
		local pos = root.Position + root.CFrame.LookVector * (b or 40)
		local e = S.Enemies.spawn(a or "TINKER", CFrame.lookAt(pos, root.Position * Vector3.new(1, 0, 1) + Vector3.new(0, pos.Y, 0)))
		return e and e.id
	elseif cmd == "elite" then -- elite(affix, distanceInFront): a TINKER elite, affix "Plated" | "Volatile" | "Swift" (default Plated)
		local root = first and S.Players.getRoot(first)
		if not root then
			return "no player"
		end
		local affix = a or "Plated"
		if affix ~= "Plated" and affix ~= "Volatile" and affix ~= "Swift" then
			return "unknown affix (Plated | Volatile | Swift)"
		end
		local pos = root.Position + root.CFrame.LookVector * (b or 40)
		local e = S.Enemies.spawn("TINKER", CFrame.lookAt(pos, root.Position * Vector3.new(1, 0, 1) + Vector3.new(0, pos.Y, 0)), { elite = affix })
		return e and e.id
	elseif cmd == "lootrunner" then -- lootrunner(): one loot runner now, 30-45 studs from a random living trooper (needs a mission / the arena)
		local e = S.LootRunner and S.LootRunner.spawnNow()
		return if e then e.id else "none (no mission / no trooper / one already running)"
	elseif cmd == "callin" then -- run a call-in effect at a point in front of the player
		local root = first and S.Players.getRoot(first)
		if not root then
			return "no player"
		end
		local pos = root.Position + root.CFrame.LookVector * (b or 30)
		if S.Map.current and S.Map.current.groundY then
			pos = Vector3.new(pos.X, S.Map.current.groundY(pos.X, pos.Z), pos.Z)
		end
		return S.CallIns.debugRun(first, a, pos, root.CFrame.LookVector)
	elseif cmd == "give" then
		S.Players.giveSupport(first, a)
		return true
	elseif cmd == "arena" then -- arena(["COG"|"BROOD"]) enters the Studio test arena; arena("exit") leaves it
		if a == "exit" then
			return S.TestArena.exit()
		end
		local ok, why = S.TestArena.enter(a)
		return if ok then "arena open" else why
	elseif cmd == "arenaspawn" then -- arenaspawn(kind, count, dist): e.g. ("TINKER_SWARM", 6, 30); kinds are Data/Enemies ids
		return S.TestArena.spawn(first, a, b, c)
	elseif cmd == "arenaop" then -- arenaop(op): tinker skitter tinkerswarm skitterswarm rivet spitter clear god director breach refill faction
		return S.DevTools.run(first, a)
	elseif cmd == "god" then
		if S.DevTools and first then -- same effect as before, but remembered across respawns
			return S.DevTools.setGod(first, a ~= false)
		end
		local h = first and S.Players.getHumanoid(first)
		if h then
			h.MaxHealth = a == false and Config.PlayerHealth or 1e6
			h.Health = h.MaxHealth
		end
		return true
	elseif cmd == "killnear" then -- killnear(radius): kill every enemy within radius of the first player (pacing tests)
		local root = first and S.Players.getRoot(first)
		local n = 0
		if root then
			for _, e in S.Enemies.getAll() do
				if e.root and (e.root.Position - root.Position).Magnitude <= (a or 25) then
					S.Enemies.damage(e, 1e6, 10, { player = first })
					n += 1
				end
			end
		end
		return n
	elseif cmd == "wave" then -- wave(budget, method): a Director wave around the first player ("drop" = COG dropship; AA tests)
		local root = first and S.Players.getRoot(first)
		if not root or not S.Director then
			return "no player / director"
		end
		return S.Director.spawnWave(root.Position, a or 4, { method = b, ignorePressure = true })
	elseif cmd == "selfhurt" then -- selfhurt(amount): damage the first player through the normal path (downed tests)
		if not first then
			return "no player"
		end
		S.Players.damage(first, a or 50, nil, { kind = "debug" })
		local h = S.Players.getHumanoid(first)
		return string.format("hp %.1f downed %s end %s", h and h.Health or -1, tostring(first:GetAttribute("Downed")),
			tostring(first:GetAttribute("DownedEnd")))
	elseif cmd == "hurt" then -- hurt(frac): every enemy loses frac (default 0.25) of its max HP, AP 10 (damage stage tests)
		local out = {}
		for _, e in S.Enemies.getAll() do
			if e.alive then
				S.Enemies.damage(e, e.maxHp * (a or 0.25), 10, { player = first })
				table.insert(out, string.format("%s %d/%d st%s", e.def.id, e.hp, e.maxHp, tostring(e.dmgStage)))
			end
		end
		return table.concat(out, ", ")
	elseif cmd == "tp" then -- teleport next to a map site (or the extraction pad)
		local m = S.Map.current
		local c = first and first.Character
		if not m or not c then
			return "no map/char"
		end
		local bz = a == "board" and workspace:FindFirstChild("BoardZone", true)
		local cf = bz and bz.CFrame or (a == "extraction" and CFrame.new(m.extraction)) or m.sites[a]
		if not cf then
			return "no site " .. tostring(a)
		end
		if bz then
			c:PivotTo(CFrame.new(bz.Position + Vector3.new(0, 3.5, 0)))
			return true
		end
		local p = cf.Position + Vector3.new(b or 6, 0, 0)
		c:PivotTo(CFrame.new(Vector3.new(p.X, m.groundY(p.X, p.Z) + 4, p.Z), cf.Position))
		return true
	elseif cmd == "trigger" then -- fire an objective prompt by ActionText (substring), bypassing range/hold
		for _, pp in workspace:GetDescendants() do
			if pp:IsA("ProximityPrompt") and pp.Enabled and string.find(string.lower(pp.ActionText), string.lower(a), 1, true) then
				local d = pp:FindFirstChild("DebugTrigger")
				if d then
					d:Fire(first)
					return pp.ActionText
				end
			end
		end
		return "no prompt " .. tostring(a)
	elseif cmd == "prompts" then
		local out = {}
		for _, pp in workspace:GetDescendants() do
			if pp:IsA("ProximityPrompt") and pp.Enabled then
				table.insert(out, pp.ActionText)
			end
		end
		return table.concat(out, ", ")
	elseif cmd == "fast" then -- shorten objective/extraction timers for testing
		workspace:SetAttribute("DebugFast", a ~= false)
		return true
	elseif cmd == "solve" then
		return S.Objectives.debugSolve(first)
	elseif cmd == "steps" then -- compact main-objective progress: x done, > active, - pending
		local st = S.Objectives.getState()
		local out = {}
		for _, o in st do
			local t = {}
			for _, s2 in o.steps do
				table.insert(t, (s2.done and "x" or (s2.active and ">" or "-")))
			end
			table.insert(out, o.id .. ":" .. table.concat(t))
		end
		return table.concat(out, " ") .. " | " .. S.Mission.state
	elseif cmd == "war" then -- war(key, amount) adds contribution; war("outcome", key, value)
		if a == "outcome" then
			S.War.debugSetOutcome(b, c)
		else
			S.War.debugAdd(a, b or 10)
		end
		return true
	elseif cmd == "objectives" then
		return S.Objectives.getState()
	elseif cmd == "intensity" then -- intensity("calm"|"build"|"breach"|"relax"): force the Director's pacing state (during Active)
		if a == nil then
			return S.Director.getIntensity()
		end
		local ok, why = S.Director.debugSetIntensity(tostring(a))
		return if ok then S.Director.getIntensity() else why
	elseif cmd == "breach" then -- breach(): force a BREACH right now (opens 2-3 sources; during Active)
		local ok, why = S.Director.debugBreach()
		return if ok then S.Director.getIntensity() else why
	elseif cmd == "sources" then -- sources(): open breach sources with hp / distance from the first player; sources("close"): close them all
		if a == "close" then
			return S.Director.debugCloseSources()
		end
		local root = first and S.Players.getRoot(first)
		return S.Director.getSources(root and root.Position or nil)
	elseif cmd == "extracthold" then -- extracthold(true|false): start / end the extraction hold-out without calling the Skiff
		if a == false then
			S.Director.endExtractHold()
		else
			S.Director.beginExtractHold()
		end
		return S.Director.getIntensity()
	elseif cmd == "event" then -- event("MAIN_STEP"|"FINAL_STEPS"|"DEFEND_START"|"SAMPLE"|...): fire an objective pacing event
		S.Director.objectiveEvent(tostring(a))
		return S.Director.getIntensity()
	elseif cmd == "state" then
		return {
			mission = S.Mission.state,
			enemies = S.Enemies and S.Enemies.count(),
			lives = S.Mission.lives,
			intensity = S.Director and S.Director.getIntensity(),
		}
	elseif cmd == "money" then
		local d = S.Save.get(first)
		d.salvage += a or 5000
		d.tokens += a or 5000
		S.Save.markDirty(first)
		return true
	end
	return "unknown cmd"
end

print(("[%s] server ready v%s"):format(Config.GameName, Config.Version))
