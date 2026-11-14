-- S.DevTools: STUDIO-ONLY test helpers. Everything here is a no-op outside Studio (RunService:IsStudio()).
--   QuickStart   workspace attribute (string), read when the FIRST player has loaded:
--                  "slice"  start the vertical slice at once: faction (QuickStartFaction, default COG), MISSILE objective, difficulty 1,
--                           built on the DESERT biome (planet-less test mission, see Mission.start `quickBiome`)
--                  "arena"  enter the test arena (World/TestArena.luau)
--                  empty    normal game (ship lobby)
--   QuickStartFaction  "COG" | "BROOD" (default COG)
--   QuickStartGod      bool: god mode for the first player (re-applied on every respawn)
--   DevSpawn           RemoteEvent in ReplicatedStorage.Remotes (created only in Studio), fired by client/DebugKeys.luau with an op name.
--   S.DevTools.run(player, op)   the same ops for the DebugHook (`arenaop`):
--        tinker skitter tinkerswarm skitterswarm rivet spitter clear god director breach refill faction
--   S.DevTools.setGod(player, bool) / toggleGod(player)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared").Config)

local DevTools = {}
local S: any = nil

local godOn: { [Player]: boolean } = {}
local lastOp: { [Player]: number } = {}

local function applyGod(p: Player)
	local h = S.Players.getHumanoid(p)
	if h then
		h.MaxHealth = if godOn[p] then 1e6 else Config.PlayerHealth
		h.Health = h.MaxHealth
	end
end

local function publishGod()
	local any = false
	for _, v in godOn do
		if v then
			any = true
		end
	end
	workspace:SetAttribute("ArenaGod", any)
end

function DevTools.setGod(p: Player?, on: boolean): boolean
	if not p then
		return false
	end
	godOn[p] = on or nil
	applyGod(p)
	publishGod()
	return on
end

function DevTools.toggleGod(p: Player?): boolean
	return DevTools.setGod(p, not (p and godOn[p]))
end

function DevTools.onArenaClosed()
	-- god mode is kept (it is a per-player test flag), nothing else to reset
end

local function pack(kind: string, count: number)
	return function(p: Player)
		return S.TestArena.spawn(p, kind, count, 30)
	end
end

local OPS: { [string]: (Player) -> any } = {
	tinker = pack("TINKER", 1),
	skitter = pack("SKITTER", 1),
	tinkerswarm = pack("TINKER_SWARM", 6),
	skitterswarm = pack("SKITTER_SWARM", 6),
	rivet = pack("RIVET", 1), -- Cogwork medium
	spitter = pack("SPITTER", 1), -- Brood medium
	clear = function()
		return S.TestArena.clear()
	end,
	god = function(p)
		return DevTools.toggleGod(p)
	end,
	director = function()
		return S.TestArena.toggleDirector()
	end,
	breach = function()
		return S.TestArena.forceBreach()
	end,
	refill = function(p)
		return S.TestArena.refill(p)
	end,
	faction = function()
		return S.TestArena.toggleFaction()
	end,
}

function DevTools.run(p: Player?, op: any): any
	if not RunService:IsStudio() then
		return "Studio only"
	end
	local fn = type(op) == "string" and OPS[string.lower(op)]
	if not p or not fn then
		return "unknown op " .. tostring(op)
	end
	if not S.Map.current then
		return "no arena or mission map"
	end
	return fn(p)
end

-- Quick start ---------------------------------------------------------------------------------------------
local function quickStart(p: Player)
	local mode = workspace:GetAttribute("QuickStart")
	local god = workspace:GetAttribute("QuickStartGod") == true
	if type(mode) ~= "string" or mode == "" then
		return
	end
	-- wait until the profile is loaded and the trooper stands on the ship (Mission.onPlayerJoined ran)
	local t0 = os.clock()
	while p.Parent and os.clock() - t0 < 45 do
		local r = S.Players.get(p)
		if r and (not S.Save or S.Save.isLoaded(p)) and p.Character and S.Players.isAlive(p) then
			break
		end
		task.wait(0.25)
	end
	if not p.Parent then
		return
	end
	if god then
		DevTools.setGod(p, true)
	end
	local faction = if workspace:GetAttribute("QuickStartFaction") == "BROOD" then "BROOD" else "COG"
	mode = string.lower(mode)
	if mode == "slice" then
		local ok, why = S.Mission.start(p, { faction = faction, objective = "MISSILE", difficulty = 1, quickBiome = "desert" })
		print("[QuickStart] slice", faction, ok, why)
	elseif mode == "arena" then
		local ok, why = S.TestArena.enter(faction)
		print("[QuickStart] arena", faction, ok, why)
	else
		warn("[QuickStart] unknown mode '" .. mode .. "' (use slice or arena)")
	end
end

function DevTools.init(s: any)
	S = s
	if not RunService:IsStudio() then
		return
	end
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local ev = remotes:FindFirstChild("DevSpawn")
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = "DevSpawn"
		ev.Parent = remotes
	end
	ev.OnServerEvent:Connect(function(p, op)
		if not RunService:IsStudio() then
			return
		end
		local t = os.clock()
		if t - (lastOp[p] or 0) < 0.12 then
			return
		end
		lastOp[p] = t
		local ok, res = pcall(DevTools.run, p, op)
		if not ok then
			warn("[DevTools]", op, res)
		end
	end)

	-- god mode survives respawns (PlayerService.setupCharacter resets MaxHealth on every new character)
	local function watch(p: Player)
		p.CharacterAdded:Connect(function()
			if godOn[p] then
				task.delay(0.6, applyGod, p)
			end
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerRemoving:Connect(function(p)
		godOn[p] = nil
		lastOp[p] = nil
		publishGod()
	end)

	local started = false
	local function first(p: Player)
		if started then
			return
		end
		started = true
		task.spawn(quickStart, p)
	end
	Players.PlayerAdded:Connect(first)
	for _, p in Players:GetPlayers() do
		first(p)
	end
end

return DevTools
