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

-- Shootable chain-detonating COG Fuel Barrels ----------------------------------------------------------------
type BarrelRec = {
	id: number,
	model: Model,
	body: Part,
	pos: Vector3,
	hp: number,
	state: string, -- "intact" | "ignited" | "blown"
}
local barrels: { [number]: BarrelRec } = {}
local barrelNextId = 0
local barrelGen = 0 -- bumped on clearBarrels so pending chain timers abort cleanly on map unload

local BARREL_HP = 35
local BARREL_IGNITE_DELAY = 0.25
local BARREL_CHAIN_MIN = 0.18
local BARREL_CHAIN_MAX = 0.30
local BARREL_BLAST_R = 15
local BARREL_BLAST_CORE = 5.5
local BARREL_BLAST_DMG = 520
local BARREL_BLAST_AP = 4
local BARREL_PLAYER_DMG = 48

local COL_COG_RED = Color3.fromRGB(142, 34, 28)
local COL_GUNMETAL = Color3.fromRGB(42, 46, 54)
local COL_BRASS = Color3.fromRGB(166, 128, 56)
local COL_AMBER = Color3.fromRGB(198, 130, 32)
local CYL_UP = CFrame.Angles(0, 0, math.pi / 2)

local function pruneBarrels()
	for id, b in barrels do
		if not b.model.Parent or b.state == "blown" then
			barrels[id] = nil
		end
	end
end

function Hazards.clearBarrels()
	barrelGen += 1
	table.clear(barrels)
end

local function makeBarrelPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material, solid: boolean): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Cylinder
	p.Anchored = true
	p.CanCollide = solid
	p.CanQuery = solid
	p.CanTouch = false
	p.CastShadow = solid
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p:SetAttribute("KeepMat", true)
	p.Parent = parent
	return p
end

local function buildBarrel(folder: Instance, pos: Vector3, yaw: number): BarrelRec
	barrelNextId += 1
	local id = barrelNextId
	local model = Instance.new("Model")
	model.Name = "COGFuelBarrel"
	model:SetAttribute("FuelBarrel", true)
	model:SetAttribute("BarrelId", id)
	model:SetAttribute("BarrelState", "intact")

	local base = CFrame.new(pos.X, pos.Y + 1.75, pos.Z) * CFrame.Angles(0, yaw, 0)
	local body = makeBarrelPart(model, "Drum", Vector3.new(3.5, 2.25, 2.25), base * CYL_UP, COL_COG_RED, Enum.Material.Metal, true)
	body:SetAttribute("FuelBarrel", true)
	body:SetAttribute("BarrelId", id)
	-- heavy gunmetal top/bottom rims
	makeBarrelPart(model, "CapTop", Vector3.new(0.28, 2.38, 2.38), (base * CFrame.new(0, 1.66, 0)) * CYL_UP, COL_GUNMETAL, Enum.Material.Metal, false)
	makeBarrelPart(model, "CapBot", Vector3.new(0.28, 2.38, 2.38), (base * CFrame.new(0, -1.66, 0)) * CYL_UP, COL_GUNMETAL, Enum.Material.Metal, false)
	-- forged brass bands
	makeBarrelPart(model, "BandTop", Vector3.new(0.22, 2.40, 2.40), (base * CFrame.new(0, 0.85, 0)) * CYL_UP, COL_BRASS, Enum.Material.Metal, false)
	makeBarrelPart(model, "BandBot", Vector3.new(0.22, 2.40, 2.40), (base * CFrame.new(0, -0.85, 0)) * CYL_UP, COL_BRASS, Enum.Material.Metal, false)
	-- recessed matte industrial amber hazard stripe (no bright neon spam)
	makeBarrelPart(model, "HazardBand", Vector3.new(0.44, 2.29, 2.29), base * CYL_UP, COL_AMBER, Enum.Material.SmoothPlastic, false)
	-- pressure filler valve on top
	makeBarrelPart(model, "Valve", Vector3.new(0.35, 0.65, 0.65), (base * CFrame.new(0.45, 1.92, 0)) * CYL_UP, COL_GUNMETAL, Enum.Material.Metal, false)

	model.PrimaryPart = body
	model.Parent = folder
	local rec: BarrelRec = {
		id = id,
		model = model,
		body = body,
		pos = pos,
		hp = BARREL_HP,
		state = "intact",
	}
	barrels[id] = rec
	return rec
end

local function igniteBarrel(b: BarrelRec, attacker: Player?, delaySec: number)
	if b.state ~= "intact" or not b.model.Parent then
		return
	end
	b.state = "ignited"
	b.model:SetAttribute("BarrelState", "ignited")
	local gen = barrelGen
	if S and S.Fx and S.Fx.play then
		S.Fx.play("BarrelIgnite", { p = b.pos, dur = delaySec })
	end
	task.delay(delaySec, function()
		if gen ~= barrelGen or (b.state :: string) ~= "ignited" or not b.model.Parent then
			return
		end
		b.state = "blown"
		barrels[b.id] = nil
		local blastPos = b.pos + Vector3.new(0, 1.6, 0)
		b.model:Destroy()
		if S and S.Explosions and S.Explosions.blast then
			S.Explosions.blast(blastPos, {
				radius = BARREL_BLAST_R,
				core = BARREL_BLAST_CORE,
				damage = BARREL_BLAST_DMG,
				ap = BARREL_BLAST_AP,
				size = "L",
				style = "fire",
				vis = 1.65,
				knock = 75,
				power = 95,
				shake = 1.35,
				playerDamage = BARREL_PLAYER_DMG,
				playerKind = "hazard",
			}, { player = attacker, kind = "barrel", id = "FUEL_BARREL" })
		end
	end)
end

-- Spawns a tactical cluster of 2-3 shootable COG Fuel Barrels under `parent` (auto-cleaned when the map folder clears).
function Hazards.spawnBarrelCluster(parent: Instance, center: Vector3, groundFn: ((number, number) -> number)?, count: number?, seed: number?)
	if not parent then
		return
	end
	pruneBarrels()
	local n = math.clamp(math.floor(count or 3), 1, 3)
	local f = parent:FindFirstChild("FuelBarrels")
	if not f then
		f = Instance.new("Folder")
		f.Name = "FuelBarrels"
		f.Parent = parent
	end
	local r = Random.new(seed or math.floor(math.abs(center.X * 13 + center.Z * 31) + 17))
	local baseYaw = r:NextNumber(0, math.pi * 2)
	local offsets: { Vector3 }
	if n == 1 then
		offsets = { Vector3.zero }
	elseif n == 2 then
		offsets = { Vector3.new(-1.35, 0, -0.3), Vector3.new(1.35, 0, 0.35) }
	else
		offsets = { Vector3.new(-1.45, 0, -0.85), Vector3.new(1.45, 0, -0.75), Vector3.new(0.05, 0, 1.55) }
	end
	local rot = CFrame.Angles(0, baseYaw, 0)
	for _, off in offsets do
		local w = rot:VectorToWorldSpace(off)
		local x = center.X + w.X
		local z = center.Z + w.Z
		local y = center.Y
		if groundFn then
			local ok, gy = pcall(groundFn, x, z)
			if ok and type(gy) == "number" and gy > -200 then
				y = gy
			end
		end
		buildBarrel(f :: Instance, Vector3.new(x, y, z), r:NextNumber(0, math.pi * 2))
	end
end

-- Called by WeaponService when a player shot strikes a part tagged FuelBarrel. Returns true if this shot ignited it.
function Hazards.hitBarrel(inst: Instance, damage: number, attacker: Player?): boolean
	local id = inst:GetAttribute("BarrelId")
	if type(id) ~= "number" then
		local m = inst:FindFirstAncestorOfClass("Model")
		id = m and m:GetAttribute("BarrelId")
	end
	if type(id) ~= "number" then
		return false
	end
	local b = barrels[id]
	if not b or b.state ~= "intact" or not b.model.Parent then
		return false
	end
	b.hp -= math.max(damage or 25, 1)
	if b.hp <= 0 then
		igniteBarrel(b, attacker, BARREL_IGNITE_DELAY)
		return true
	end
	return false
end

-- Called by Explosions.blast: chain-detonates intact barrels within the blast radius after a staggered 0.18-0.30 s delay.
function Hazards.onBlast(pos: Vector3, radius: number, source: any?)
	if not next(barrels) then
		return
	end
	local reach = radius + 4.5
	local attacker: Player? = if type(source) == "table" and source.player then source.player else nil
	for id, b in table.clone(barrels) do
		if not b.model.Parent or b.state == "blown" then
			barrels[id] = nil
		elseif b.state == "intact" and (b.pos - pos).Magnitude <= reach then
			igniteBarrel(b, attacker, rng:NextNumber(BARREL_CHAIN_MIN, BARREL_CHAIN_MAX))
		end
	end
end

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
	Hazards.stopArtillery()
	Hazards.clearBarrels()
end

-- Hostile COG Artillery Barrage & Spotter Counterplay -------------------------------------------------------
-- During active COG missions (and TestArena when Director is running), every 40-60 s during active combat a live
-- COG ranged unit (or fallback off-map battery if none) becomes an Artillery Spotter for 3.0 s. Killing or stunning
-- the spotter aborts the barrage; otherwise 3 heavy whistling shells bracket the locked position (staggered 0.9 s
-- apart, 1.8 s lead warning ring + descending shell streak), detonating through S.Explosions.blast and hurting
-- both careless troopers and enemies baited into the kill zone.
local ART_GAP_MIN, ART_GAP_MAX = 40, 60
local ART_FIRST_MIN, ART_FIRST_MAX = 24, 34
local ART_SPOT_DUR = 3.0
local ART_SHELL_COUNT = 3
local ART_SHELL_STAGGER = 0.9
local ART_SHELL_LEAD = 1.8
local ART_SHELL_RADIUS = 16
local ART_SHELL_CORE = 5.5
local ART_SHELL_ENEMY_DMG = 45
local ART_SHELL_PLAYER_DMG = 42
local ART_SHELL_KNOCK = 62
local ART_SPREAD_MIN, ART_SPREAD_MAX = 10, 22

local artilleryGen = 0
local activeSpotter: any = nil

local function clearSpotterAttr(e: any?)
	if e and e.model and e.model.Parent then
		if e.model:GetAttribute("ArtillerySpot") then
			e.model:SetAttribute("ArtillerySpot", nil)
		end
	end
end

function Hazards.stopArtillery()
	artilleryGen += 1
	if activeSpotter then
		clearSpotterAttr(activeSpotter)
		activeSpotter = nil
	end
	if S and S.Fx and S.Fx.play then
		S.Fx.play("ArtilleryAlert", { phase = "clear" })
	end
end

local function isSpotterStunned(e: any): boolean
	local now = workspace:GetServerTimeNow()
	if e.status then
		if e.status.stun and e.status.stun.untilT > now then
			return true
		end
		if e.status.confuse and e.status.confuse.untilT > now then
			return true
		end
	end
	if e.frozenUntil and e.frozenUntil > now then
		return true
	end
	return false
end

local function findCogSpotter(victimPos: Vector3): any?
	if not (S and S.Enemies and S.Enemies.getAll) then
		return nil
	end
	local preferred: { any } = {}
	local fallback: { any } = {}
	for _, e in S.Enemies.getAll() do
		if e.alive and e.faction == "COG" and e.def and e.def.keepDistance and not e.def.static and not e.def.loot and e.model and e.model.Parent then
			if not isSpotterStunned(e) then
				local ep = e.pos or (e.root and e.root.Position)
				if ep then
					local d = Vector3.new(ep.X - victimPos.X, 0, ep.Z - victimPos.Z).Magnitude
					if d <= 145 then
						if not e.fodder and (e.kind == "TINKER" or e.kind == "RIVET") then
							table.insert(preferred, e)
						else
							table.insert(fallback, e)
						end
					end
				end
			end
		end
	end
	if #preferred > 0 then
		return preferred[rng:NextInteger(1, #preferred)]
	end
	if #fallback > 0 then
		return fallback[rng:NextInteger(1, #fallback)]
	end
	return nil
end

local function inActiveCogCombat(): (boolean, { Player })
	if not (S and S.Players and S.Players.getAlive) then
		return false, {}
	end
	local alive = S.Players.getAlive()
	if #alive == 0 then
		return false, alive
	end
	if S.Director then
		if S.Director.isRunning and not S.Director.isRunning() then
			return false, alive
		end
		if S.Director.getFaction and S.Director.getFaction() ~= "COG" then
			return false, alive
		end
		if S.Director.getThreat and S.Director.getThreat() >= 1 then
			return true, alive
		end
	end
	-- Also active when fighting COG units directly in a zone (or TestArena with Director enabled)
	if S.Enemies and S.Enemies.getAll then
		for _, e in S.Enemies.getAll() do
			if e.alive and e.faction == "COG" and e.target ~= nil then
				return true, alive
			end
		end
	end
	return false, alive
end

local function fireArtillerySalvo(myGen: number, lockPos: Vector3)
	if artilleryGen ~= myGen then
		return
	end
	if S and S.Fx and S.Fx.play then
		S.Fx.play("ArtilleryAlert", { phase = "incoming", p = lockPos })
	end
	local half = Config.MapSize / 2 - 10
	local baseAng = rng:NextNumber(0, math.pi * 2)
	for i = 1, ART_SHELL_COUNT do
		local stagger = (i - 1) * ART_SHELL_STAGGER
		task.delay(stagger, function()
			if artilleryGen ~= myGen then
				return
			end
			local ang = baseAng + (i - 1) * (math.pi * 2 / ART_SHELL_COUNT) + rng:NextNumber(-0.4, 0.4)
			local dist = rng:NextNumber(ART_SPREAD_MIN, ART_SPREAD_MAX)
			local x = math.clamp(lockPos.X + math.cos(ang) * dist, -half, half)
			local z = math.clamp(lockPos.Z + math.sin(ang) * dist, -half, half)
			local y = groundAt(x, z, lockPos.Y - 3)
			local impactPos = Vector3.new(x, y, z)
			if S and S.Fx and S.Fx.play then
				S.Fx.play("Telegraph", { shape = "circle", p = impactPos + Vector3.new(0, 0.15, 0), r = ART_SHELL_RADIUS, t = ART_SHELL_LEAD })
				S.Fx.play("Shell", { p = impactPos, t = ART_SHELL_LEAD, s = 1.55, c = Color3.fromRGB(255, 76, 36) })
			end
			task.delay(ART_SHELL_LEAD, function()
				if artilleryGen ~= myGen then
					return
				end
				if S and S.Explosions and S.Explosions.blast then
					S.Explosions.blast(impactPos, {
						radius = ART_SHELL_RADIUS,
						core = ART_SHELL_CORE,
						damage = ART_SHELL_ENEMY_DMG,
						ap = 4,
						size = "XL",
						style = "fire",
						vis = 1.95,
						knock = ART_SHELL_KNOCK,
						power = 105,
						shake = 1.65,
						shakeRadius = 155,
						playerDamage = ART_SHELL_PLAYER_DMG,
						playerKind = "hazard",
					}, { kind = "artillery", id = "COG_ARTILLERY" })
				end
			end)
		end)
	end
end

local function runArtilleryEvent(myGen: number, alive: { Player })
	local victim = alive[rng:NextInteger(1, #alive)]
	local vRoot = S.Players.getRoot(victim)
	if not vRoot then
		return
	end
	local lockPos = vRoot.Position
	local spotter = findCogSpotter(lockPos)
	if spotter then
		activeSpotter = spotter
		spotter.model:SetAttribute("ArtillerySpot", true)
		if S.Fx and S.Fx.play then
			S.Fx.play("ArtilleryAlert", { phase = "lock", p = spotter.pos or lockPos, id = spotter.id })
		end
		if S.State and S.State.notify then
			S.State.notify(nil, "COG ARTILLERY LOCK — KILL SPOTTER OR MOVE!", Config.Colors.Danger, "warning")
		end
		local deadline = os.clock() + ART_SPOT_DUR
		while os.clock() < deadline do
			task.wait(0.1)
			if artilleryGen ~= myGen then
				clearSpotterAttr(spotter)
				if activeSpotter == spotter then
					activeSpotter = nil
				end
				return
			end
			if not spotter.alive or not spotter.model or not spotter.model.Parent or isSpotterStunned(spotter) then
				clearSpotterAttr(spotter)
				if activeSpotter == spotter then
					activeSpotter = nil
				end
				if S.Fx and S.Fx.play then
					S.Fx.play("ArtilleryAlert", { phase = "abort", p = spotter.pos or lockPos })
				end
				if S.State and S.State.notify then
					S.State.notify(nil, "ARTILLERY ABORTED — SPOTTER NEUTRALIZED!", Config.Colors.Friendly)
				end
				return
			end
		end
		clearSpotterAttr(spotter)
		if activeSpotter == spotter then
			activeSpotter = nil
		end
		-- Refresh lock position at completion of spotter lock-on
		local rNow = if victim.Parent and S.Players.isAlive(victim) then S.Players.getRoot(victim) else nil
		if rNow then
			lockPos = rNow.Position
		end
		fireArtillerySalvo(myGen, lockPos)
	else
		-- Off-map battery fallback when no live COG spotter is available in range
		if S.State and S.State.notify then
			S.State.notify(nil, "COG ARTILLERY BARRAGE INBOUND — MOVE!", Config.Colors.Danger, "warning")
		end
		fireArtillerySalvo(myGen, lockPos)
	end
end

function Hazards.startArtillery(_map: any?, faction: string?)
	Hazards.stopArtillery()
	if faction ~= "COG" then
		return
	end
	local myGen = artilleryGen
	task.spawn(function()
		local nextAt = os.clock() + rng:NextNumber(ART_FIRST_MIN, ART_FIRST_MAX)
		while artilleryGen == myGen do
			task.wait(1)
			if artilleryGen ~= myGen then
				break
			end
			local active, alive = inActiveCogCombat()
			if not active then
				-- Keep countdown primed while out of combat so action resumes smoothly once engaged
				nextAt = math.max(nextAt, os.clock() + 8)
				continue
			end
			if os.clock() >= nextAt then
				local ok, err = pcall(runArtilleryEvent, myGen, alive)
				if not ok then
					warn("[Hazards] artillery event failed:", err)
				end
				if artilleryGen ~= myGen then
					break
				end
				nextAt = os.clock() + rng:NextNumber(ART_GAP_MIN, ART_GAP_MAX)
			end
		end
	end)
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
