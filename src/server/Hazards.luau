-- S.Hazards: planet hazards that run during a mission's combat phase (Mission starts / stops it next to the Director).
--
--   DEBRIS SHOWER (idea, off by default): Studio A/B workspace attribute Feel_Hazard (Variants group "PLANET HAZARD",
--   mirrored to the server by the "studioFeel" action).
--     nil / anything else  no hazard
--     "debris"             a shower every 90-140 s
--     "debris_fast"        a shower every 30-45 s (testing)
--   A shower picks one living trooper, then over 8 s lands 6-9 rocks 8-40 studs from them. Every rock first shows the
--   red ground warning (Fx "Telegraph") and a falling streak (Fx "Shell", client/Fx/CallInFx.luau) for 2 s, then
--   blows up through S.Explosions.blast (enemies blown up and tumbled; troopers hurt the way enemy mortar shells do,
--   through Explosions.playerFalloff, so a direct hit takes about 60 % of a full-health trooper's HP).
--   The first shower of a mission is announced on the radio.
--
--   Hazards.start(map)  Hazards.stop()   (Mission: after Director.start / with the Director's stop)

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local Hazards = {}
local S: any = nil

local rng = Random.new()
local token = 0 -- bumped by start / stop: invalidates the running loop and any rock still in the air

-- tuning
local WARN_T = 2 -- s from warning to blast
local SHOWER_T = 8 -- s over which a shower's rocks land
local ROCKS = { 6, 9 }
local DIST = { 8, 40 } -- studs from the chosen trooper
local RADIUS, CORE = 7, 2
local DAMAGE, AP = 250, 3 -- vs enemies (Damage.compute armour tiers)
local KNOCK = 60 -- >= Config.Move.KnockdownSpeed (40) / 1.1 at the core: the squad tumbles
local PLAYER_HIT = 0.6 -- share of a full-health trooper's HP a direct hit takes
local GAPS = { normal = { 90, 140 }, fast = { 30, 45 } }

function Hazards.init(s)
	S = s
end

local function mode(): string?
	local v = workspace:GetAttribute("Feel_Hazard")
	if v == "debris" then
		return "normal"
	elseif v == "debris_fast" then
		return "fast"
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

-- trooper damage: same path as the mortar shell in Enemies/Projectiles.finish (playerFalloff, 1.2 stud body allowance)
local function hurtPlayers(pos: Vector3)
	local full = Config.PlayerHealth * PLAYER_HIT
	for _, p in S.Players.getAlive() do
		local root = S.Players.getRoot(p)
		if root then
			local d = (root.Position - pos).Magnitude
			if d < RADIUS + 1.2 then
				local f = S.Explosions.playerFalloff(math.max(d - 1.2, 0), CORE, RADIUS)
				if f > 0 then
					S.Players.damage(p, full * f, pos, { kind = "hazard" })
				end
			end
		end
	end
end

local function impact(my: number, pos: Vector3)
	S.Fx.play("Telegraph", { shape = "circle", p = pos + Vector3.new(0, 0.15, 0), r = RADIUS, t = WARN_T })
	S.Fx.play("Shell", { p = pos, t = WARN_T, s = 1.3, c = Color3.fromRGB(255, 120, 50) })
	task.delay(WARN_T, function()
		if token ~= my or not missionLive() then
			return
		end
		hurtPlayers(pos)
		S.Explosions.blast(pos, {
			radius = RADIUS,
			core = CORE,
			damage = DAMAGE,
			ap = AP,
			size = "M",
			style = "rock",
			knock = KNOCK,
		}, { kind = "hazard" })
	end)
end

local function shower(my: number)
	local alive = S.Players.getAlive()
	if #alive == 0 then
		return
	end
	local victim = alive[rng:NextInteger(1, #alive)]
	local n = rng:NextInteger(ROCKS[1], ROCKS[2])
	local lastPos = S.Players.getRoot(victim) and (S.Players.getRoot(victim) :: BasePart).Position
	local times = {}
	for i = 1, n do
		times[i] = rng:NextNumber(0, SHOWER_T)
	end
	table.sort(times)
	local half = Config.MapSize / 2 - 6
	local t0 = os.clock()
	for i = 1, n do
		local wait = times[i] - (os.clock() - t0)
		if wait > 0 then
			task.wait(wait)
		end
		if token ~= my or not missionLive() then
			return
		end
		-- aim at where the trooper is now (falls back to the last known spot if they went down meanwhile)
		local root = if victim.Parent and S.Players.isAlive(victim) then S.Players.getRoot(victim) else nil
		if root then
			lastPos = root.Position
		end
		if lastPos then
			local ang = rng:NextNumber(0, math.pi * 2)
			local dist = rng:NextNumber(DIST[1], DIST[2])
			local x = math.clamp(lastPos.X + math.cos(ang) * dist, -half, half)
			local z = math.clamp(lastPos.Z + math.sin(ang) * dist, -half, half)
			impact(my, Vector3.new(x, groundAt(x, z, lastPos.Y - 3), z))
		end
	end
end

function Hazards.stop()
	token += 1
end

function Hazards.start(_map: any?)
	token += 1
	local my = token
	task.spawn(function()
		local announced = false
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
						print(string.format("[Hazards] %s armed, first shower in %.0f s", m, nextAt - os.clock()))
					end
				end
			end
			if m and os.clock() >= nextAt then
				if #S.Players.getAlive() > 0 then
					if not announced then
						announced = true
						S.State.notify(nil, "HALCYON: Debris belt overhead. Watch the sky.", Config.Colors.Danger)
						task.wait(3)
					end
					if token == my then
						shower(my)
					end
				end
				local g = GAPS[m]
				nextAt = os.clock() + rng:NextNumber(g[1], g[2])
			end
		end
	end)
end

return Hazards
