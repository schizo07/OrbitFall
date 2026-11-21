-- S.TestArena: STUDIO-ONLY flat combat test space (docs/RESET-brief.md stage 1 / 2).
--   S.TestArena.enter(faction?)            builds the arena, puts every player in it with the starter kit -> ok, why?
--   S.TestArena.exit()                     back to the ship (Mission.endArena -> returnToShip -> onClosed)
--   S.TestArena.active()                   -> boolean
--   S.TestArena.spawn(p, kind, count, dist) enemies in front of the player (kind = enemy id from Data/Enemies) -> number spawned
--   S.TestArena.clear()                    removes every enemy + enemy projectile
--   S.TestArena.refill(p)                  ammo, grenades, call-in cooldowns
--   S.TestArena.toggleDirector(on?)        the Director's automatic pacing (OFF by default: the arena is quiet)
--   S.TestArena.forceBreach()              starts the Director if needed and forces a BREACH now
--   S.TestArena.toggleFaction()            COG -> BROOD -> LUMEN -> COG (what the Director spawns; Mission.faction)
--   S.TestArena.spawnPlayer(p)             (re)spawn at the start with the starter kit (Mission.onPlayerJoined / auto respawn)
--   S.TestArena.onClosed()                 Mission calls this when the arena state ends (any path)
--
-- How it works: the arena is a normal "Active" mission (Mission.beginArena) whose map is this fake Map table, so the combat HUD, call-ins,
-- enemies, Fx and ambience all behave as in a mission. There are no objectives, no tick loop and no Director until it is toggled on.
-- Position: x/z in -130..130 (inside the Director's / EnemyAI's +-300 clamp), surface at Y = 300: above the mission map (terrain tops out
-- near y = 176) and far below the ship (y = 900). Mission.start refuses while the arena is open, so the two never coexist.
-- Ground is TERRAIN (EnemyAI snaps enemies to Terrain only); the 640 x 640 slab gives the horizon real ground. Parts: 4 invisible walls + cover.
-- Workspace attributes for the client key-help label (client/DebugKeys.luau): TestArena (bool), ArenaFaction, ArenaDirector (bool).

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local EnemyData = require(Shared.Data.Enemies)
local CallInData = require(Shared.Data.CallIns)
local Assets = require(script.Parent.Assets)

local TestArena = {}
local S: any = nil

local Y0 = 300 -- ground surface height
local HALF = 130 -- playable half extent (260 x 260)
local SLAB = 320 -- terrain slab half extent (640 x 640)
local SPAWN_Z = -108 -- the player starts at the south end, facing +Z
local MAX_SPAWN = 40

local isActive = false
local arenaFaction = "COG"
local directorOn = false
local arenaMap: any = nil
local loopToken = 0

local function groundY(x: number, z: number): number
	-- the Director / spawn helpers treat y < -200 as "no ground": keep spawns inside the walls
	if math.abs(x) <= HALF - 4 and math.abs(z) <= HALF - 4 then
		return Y0
	end
	return -1000
end

local function loadout()
	return { primary = "PR7", secondary = "P3", grenade = "FRAG", callins = table.clone(CallInData.Starter) }
end

local function prop(parent: Instance, name: string, size: Vector3, pos: Vector3, yawDeg: number, color: Color3, mat: Enum.Material)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = CFrame.new(pos.X, Y0 + size.Y / 2 + pos.Y, pos.Z) * CFrame.Angles(0, math.rad(yawDeg), 0)
	p.Color = color
	p.Material = mat
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function wall(parent: Instance, size: Vector3, cf: CFrame)
	local p = Instance.new("Part")
	p.Name = "ArenaWall"
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Transparency = 1
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
end

local function buildTerrain()
	local t = Workspace.Terrain
	t:Clear()
	t:FillBlock(CFrame.new(0, Y0 - 8, 0), Vector3.new(SLAB * 2, 16, SLAB * 2), Enum.Material.Sand)
	-- broad low-saturation desert value bands + central compacted lane (clean deck, zero micro-clutter)
	t:FillBlock(CFrame.new(0, Y0 - 1.1, 0), Vector3.new(26, 2.4, HALF * 2), Enum.Material.Concrete)
	local bands = {
		{ x = -96, z = 40, r = 54, mat = Enum.Material.Ground },
		{ x = 92, z = -34, r = 58, mat = Enum.Material.Sandstone },
		{ x = -72, z = -78, r = 42, mat = Enum.Material.Sandstone },
		{ x = 78, z = 76, r = 46, mat = Enum.Material.Ground },
		{ x = 0, z = 96, r = 38, mat = Enum.Material.Slate },
	}
	for _, b in bands do
		t:FillCylinder(CFrame.new(b.x, Y0 - 1.1, b.z), 2.4, b.r, b.mat)
	end
	-- low rock rim around the playable square (the invisible walls sit just inside it)
	local e = HALF + 4
	local len = (HALF + 8) * 2
	t:FillBlock(CFrame.new(0, Y0 + 3, e), Vector3.new(len, 10, 8), Enum.Material.Basalt)
	t:FillBlock(CFrame.new(0, Y0 + 3, -e), Vector3.new(len, 10, 8), Enum.Material.Basalt)
	t:FillBlock(CFrame.new(e, Y0 + 3, 0), Vector3.new(8, 10, len), Enum.Material.Basalt)
	t:FillBlock(CFrame.new(-e, Y0 + 3, 0), Vector3.new(8, 10, len), Enum.Material.Basalt)
end

local function buildFolder()
	local folder = Instance.new("Folder")
	folder.Name = "Map" -- client Ambience / bolt raycasts / horizon fx look for workspace.Map
	folder:SetAttribute("Biome", "desert")
	folder:SetAttribute("Faction", arenaFaction)
	folder:SetAttribute("Arena", true)
	local props = Instance.new("Folder")
	props.Name = "Props"
	props.Parent = folder

	-- invisible walls (CanCollide stays true): nobody leaves the arena
	local h = 80
	local wl = (HALF + 6) * 2
	wall(folder, Vector3.new(wl, h, 4), CFrame.new(0, Y0 + h / 2 - 2, HALF + 2))
	wall(folder, Vector3.new(wl, h, 4), CFrame.new(0, Y0 + h / 2 - 2, -HALF - 2))
	wall(folder, Vector3.new(4, h, wl), CFrame.new(HALF + 2, Y0 + h / 2 - 2, 0))
	wall(folder, Vector3.new(4, h, wl), CFrame.new(-HALF - 2, Y0 + h / 2 - 2, 0))

	-- stark brutalist weathered-concrete & dark-charcoal-steel cover (zero bright yellow accent clutter)
	local concrete = Color3.fromRGB(82, 78, 72)
	local concreteDark = Color3.fromRGB(60, 58, 55)
	local steelDark = Color3.fromRGB(42, 46, 52)
	local steelLight = Color3.fromRGB(118, 122, 130)
	local rust = Color3.fromRGB(96, 68, 52)
	local rock = Color3.fromRGB(76, 65, 55)

	local function jerseyBarrier(pos: Vector3, len: number, yawDeg: number)
		local body = prop(props, "JerseyBarrier", Vector3.new(len, 4.8, 2.4), pos, yawDeg, concrete, Enum.Material.Concrete)
		body:SetAttribute("KeepMat", true)
		local cf = body.CFrame
		local trim = Instance.new("Part")
		trim.Name = "BarrierCap"
		trim.Anchored = true
		trim.CanCollide = false
		trim.CanQuery = false
		trim.CanTouch = false
		trim.CastShadow = false
		trim.Size = Vector3.new(len + 0.15, 0.5, 2.0)
		trim.CFrame = cf * CFrame.new(0, 2.25, 0)
		trim.Color = steelDark
		trim.Material = Enum.Material.Metal
		trim:SetAttribute("KeepMat", true)
		trim.Parent = props
	end

	-- ribbed metallic grating deck under player spawn on a deep-skirted concrete curb plinth
	local plinth = prop(props, "SpawnConcretePlinth", Vector3.new(19.4, 3.2, 15.4), Vector3.new(0, -3.05, SPAWN_Z), 0, concreteDark, Enum.Material.Concrete)
	plinth.CanCollide = false
	plinth.CanQuery = false
	plinth.CastShadow = false
	local pad = prop(props, "SpawnGratePad", Vector3.new(18, 0.35, 14), Vector3.new(0, -0.05, SPAWN_Z), 0, steelDark, Enum.Material.DiamondPlate)
	pad.CanCollide = false
	pad.CanQuery = false
	for _, xOff in { -8.6, 8.6 } do
		local rail = prop(props, "SpawnGrateEdge", Vector3.new(0.6, 0.45, 14.2), Vector3.new(xOff, 0.0, SPAWN_Z), 0, steelLight, Enum.Material.Metal)
		rail.CanCollide = false
		rail.CanQuery = false
	end
	for _, zOff in { -4.5, 0, 4.5 } do
		local rib = prop(props, "SpawnGrateRib", Vector3.new(16.6, 0.4, 0.45), Vector3.new(0, -0.01, SPAWN_Z + zOff), 0, steelLight, Enum.Material.Metal)
		rib.CanCollide = false
		rib.CanQuery = false
	end

	-- 1: staggered center modular Jersey barriers (clean 22-stud flanking gap down the middle)
	jerseyBarrier(Vector3.new(-17, 0, 6), 14, 0)
	jerseyBarrier(Vector3.new(17, 0, 6), 14, 0)
	-- 2: crate stack left flank
	prop(props, "Crate", Vector3.new(5.5, 4.4, 5.5), Vector3.new(-48, 0, 22), 12, steelDark, Enum.Material.Metal)
	prop(props, "Crate", Vector3.new(5.5, 4.4, 5.5), Vector3.new(-41.5, 0, 24.5), -8, rust, Enum.Material.CorrodedMetal)
	prop(props, "Crate", Vector3.new(5, 3.8, 5), Vector3.new(-45, 4.4, 23), 33, steelDark, Enum.Material.Metal)
	-- 3: craggy rock outcrop right flank
	do
		local r1 = Assets.get("env_rock_a", { anchored = true })
		if r1 then
			r1:ScaleTo(1.15)
			r1:PivotTo(CFrame.new(52, Y0 - 1.2, 18) * CFrame.Angles(0, math.rad(27), 0))
			for _, d in r1:GetDescendants() do
				if d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = true
					d.CanQuery = true
					d.Color = rock
					d.Material = Enum.Material.Rock
					d:SetAttribute("KeepMat", true)
				end
			end
			r1.Parent = props
		else
			prop(props, "Boulder", Vector3.new(11, 6.5, 8.5), Vector3.new(52, 0, 18), 27, rock, Enum.Material.Rock)
		end
		local r2 = Assets.get("env_rock_c", { anchored = true })
		if r2 then
			r2:ScaleTo(0.8)
			r2:PivotTo(CFrame.new(61, Y0 - 1.0, 10) * CFrame.Angles(0, math.rad(-40), 0))
			for _, d in r2:GetDescendants() do
				if d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = true
					d.CanQuery = true
					d.Color = Color3.fromRGB(66, 57, 49)
					d.Material = Enum.Material.Rock
					d:SetAttribute("KeepMat", true)
				end
			end
			r2.Parent = props
		else
			prop(props, "Boulder", Vector3.new(6, 4.2, 5.5), Vector3.new(60, 0, 11), -40, rock, Enum.Material.Rock)
		end
	end
	-- 4: L-shaped tactical retaining wall near player half
	jerseyBarrier(Vector3.new(-32, 0, -44), 16, 0)
	prop(props, "CoverWall", Vector3.new(2.4, 4.8, 12), Vector3.new(-39.2, 0, -37), 0, concreteDark, Enum.Material.Concrete)
	-- 5: right mid-lane cover wall + crate pair
	jerseyBarrier(Vector3.new(36, 0, -32), 13, -12)
	prop(props, "Crate", Vector3.new(5.5, 4.4, 5.5), Vector3.new(38, 0, 58), 20, rust, Enum.Material.CorrodedMetal)
	prop(props, "Crate", Vector3.new(5.5, 4.4, 5.5), Vector3.new(44.5, 0, 56), -15, steelDark, Enum.Material.Metal)
	-- 6: angled far modular barrier
	jerseyBarrier(Vector3.new(-8, 0, 76), 18, 14)

	-- 360-degree natural towering mountain & jagged canyon-spire skyline (zero overscaled industrial rim props)
	local rockPalette = {
		Color3.fromRGB(78, 66, 54),
		Color3.fromRGB(64, 55, 47),
		Color3.fromRGB(88, 74, 60),
	}
	local function placeHorizonRock(key: string, cf: CFrame, scale: number, tint: Color3, mat: Enum.Material): boolean
		local m = Assets.get(key, { anchored = true })
		if not m then
			return false
		end
		if scale ~= 1 then
			m:ScaleTo(scale)
		end
		m:PivotTo(cf)
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.CastShadow = false
				d.Color = tint
				d.Material = mat
				d:SetAttribute("KeepMat", true)
			end
		end
		m.Parent = props
		return true
	end

	-- Band 1: near-rim jagged canyon cliffs & rock buttresses surrounding the basin (sunk deep below Y0)
	local nearRim = {
		{ ang = 0, r = 178, key = "desert_cliff", sc = 2.6, yawOff = 90, sink = 16 },
		{ ang = 32, r = 186, key = "env_spire_b", sc = 1.9, yawOff = 15, sink = 18 },
		{ ang = 62, r = 176, key = "desert_cliff", sc = 2.4, yawOff = 84, sink = 15 },
		{ ang = 94, r = 188, key = "env_rock_b", sc = 4.2, yawOff = -22, sink = 16 },
		{ ang = 124, r = 180, key = "desert_cliff", sc = 2.7, yawOff = 96, sink = 16 },
		{ ang = 156, r = 184, key = "env_spire_a", sc = 1.85, yawOff = 40, sink = 18 },
		{ ang = 186, r = 176, key = "desert_cliff", sc = 2.5, yawOff = 88, sink = 15 },
		{ ang = 218, r = 190, key = "env_spire_b", sc = 2.0, yawOff = -30, sink = 18 },
		{ ang = 248, r = 180, key = "desert_cliff", sc = 2.6, yawOff = 94, sink = 16 },
		{ ang = 280, r = 186, key = "env_rock_b", sc = 4.5, yawOff = 18, sink = 16 },
		{ ang = 310, r = 178, key = "desert_cliff", sc = 2.5, yawOff = 82, sink = 15 },
		{ ang = 338, r = 186, key = "env_spire_a", sc = 1.75, yawOff = -12, sink = 18 },
	}
	for i, sp in nearRim do
		local a = math.rad(sp.ang)
		local x, z = math.cos(a) * sp.r, math.sin(a) * sp.r
		local tint = rockPalette[(i % #rockPalette) + 1]
		local mat = if sp.key == "desert_cliff" then Enum.Material.Rock else Enum.Material.Slate
		placeHorizonRock(sp.key, CFrame.new(x, Y0 - sp.sink, z) * CFrame.Angles(0, a + math.rad(sp.yawOff), 0), sp.sc, tint, mat)
	end

	-- Band 2: distant towering jagged mountain peaks fading cleanly into golden atmospheric haze
	local farPeaks = {
		{ ang = 14, r = 258, key = "env_spire_b", sc = 3.4, yawOff = 24, sink = 24 },
		{ ang = 48, r = 272, key = "env_spire_a", sc = 3.1, yawOff = -18, sink = 26 },
		{ ang = 78, r = 250, key = "desert_cliff", sc = 4.2, yawOff = 92, sink = 22 },
		{ ang = 110, r = 278, key = "env_spire_b", sc = 3.8, yawOff = 45, sink = 26 },
		{ ang = 140, r = 260, key = "env_spire_a", sc = 3.0, yawOff = -35, sink = 24 },
		{ ang = 172, r = 268, key = "desert_cliff", sc = 4.5, yawOff = 86, sink = 22 },
		{ ang = 202, r = 255, key = "env_spire_b", sc = 3.5, yawOff = 12, sink = 24 },
		{ ang = 234, r = 276, key = "env_spire_a", sc = 3.2, yawOff = -42, sink = 26 },
		{ ang = 266, r = 262, key = "desert_cliff", sc = 4.1, yawOff = 94, sink = 22 },
		{ ang = 296, r = 280, key = "env_spire_b", sc = 3.7, yawOff = 30, sink = 26 },
		{ ang = 326, r = 256, key = "env_spire_a", sc = 2.9, yawOff = -20, sink = 24 },
		{ ang = 352, r = 270, key = "desert_cliff", sc = 4.3, yawOff = 88, sink = 22 },
	}
	for i, sp in farPeaks do
		local a = math.rad(sp.ang)
		local x, z = math.cos(a) * sp.r, math.sin(a) * sp.r
		local tint = rockPalette[((i + 1) % #rockPalette) + 1]
		local mat = if sp.key == "desert_cliff" then Enum.Material.Rock else Enum.Material.Slate
		placeHorizonRock(sp.key, CFrame.new(x, Y0 - sp.sink, z) * CFrame.Angles(0, a + math.rad(sp.yawOff), 0), sp.sc, tint, mat)
	end

	folder.Parent = Workspace
	return folder, props
end

local function makeMap(folder: Folder, props: Folder): any
	local patrol: { Vector3 } = {}
	for _, p in { { -70, 80 }, { 70, 90 }, { 0, 100 } } do
		table.insert(patrol, Vector3.new(p[1], Y0 + 1, p[2]))
	end
	return {
		name = "Test Arena",
		arena = true,
		faction = arenaFaction,
		biome = "desert",
		size = HALF * 2,
		insertion = CFrame.new(0, Y0, SPAWN_Z),
		extraction = Vector3.new(0, Y0, HALF - 12),
		sites = {},
		patrolPoints = patrol,
		spawnPoints = { Vector3.new(-90, Y0 + 1, 100), Vector3.new(90, Y0 + 1, 100) },
		groundY = groundY,
		folder = folder,
		props = props,
		terrain = Workspace.Terrain,
	}
end

local function spawnCF(): CFrame
	local pos = Vector3.new(math.random(-6, 6), Y0 + 3.2, SPAWN_Z + math.random(-3, 3))
	return CFrame.lookAt(pos, pos + Vector3.zAxis)
end

-- Public -----------------------------------------------------------------------------------------------
function TestArena.active(): boolean
	return isActive
end

function TestArena.spawnPlayer(p: Player)
	S.Players.spawnAt(p, spawnCF(), loadout())
end

local function respawnLoop(my: number)
	local deadAt: { [Player]: number } = {}
	while isActive and my == loopToken do
		task.wait(0.5)
		local dead = {}
		for _, p in S.Players.getDead() do
			dead[p] = true
			deadAt[p] = deadAt[p] or os.clock()
			if os.clock() - deadAt[p] > 3 then
				deadAt[p] = nil
				task.spawn(TestArena.spawnPlayer, p)
			end
		end
		for p in deadAt do
			if not dead[p] then
				deadAt[p] = nil
			end
		end
	end
end

function TestArena.enter(faction: string?): (boolean, string?)
	if not RunService:IsStudio() then
		return false, "Studio only"
	end
	if isActive then
		for _, p in Players:GetPlayers() do
			task.spawn(TestArena.spawnPlayer, p)
		end
		return true, nil
	end
	if S.Mission.state ~= "Ship" then
		return false, "A mission is underway: `abort` first"
	end
	arenaFaction = if faction == "BROOD" or faction == "LUMEN" then faction else "COG"
	directorOn = false

	S.Map.clear() -- drop any leftover map / lighting so the arena starts from the ship state
	S.Map.applyBiomeLook("desert", arenaFaction) -- desert terrain colours + the real desert lighting / sky / post effects
	if S.Ship and S.Ship.setBackdrop then
		S.Ship.setBackdrop(false) -- same as a real map: hide the lobby planet backdrop
	end
	buildTerrain()
	local folder, props = buildFolder()
	arenaMap = makeMap(folder, props)
	S.Map.current = arenaMap

	local ok, why = S.Mission.beginArena(arenaFaction)
	if not ok then
		S.Map.clear()
		arenaMap = nil
		return false, why
	end
	isActive = true
	loopToken += 1
	Workspace:SetAttribute("TestArena", true)
	Workspace:SetAttribute("ArenaFaction", arenaFaction)
	Workspace:SetAttribute("ArenaDirector", false)
	for _, p in Players:GetPlayers() do
		task.spawn(TestArena.spawnPlayer, p)
	end
	task.spawn(respawnLoop, loopToken)
	S.State.notify(nil, "Test arena: Director OFF. See the key list on the right.", Color3.fromRGB(245, 185, 58))
	return true, nil
end

function TestArena.exit()
	if not isActive then
		return false
	end
	S.Mission.endArena() -- returnToShip -> cleanup + ship respawn + Map.clear; it calls onClosed
	return true
end

-- Mission calls this from returnToShip (exit, `abort`, `finish`, ...). Enemies / Director / call-ins are cleaned up by Mission.
function TestArena.onClosed()
	isActive = false
	directorOn = false
	arenaMap = nil
	loopToken += 1
	Workspace:SetAttribute("TestArena", false)
	Workspace:SetAttribute("ArenaDirector", false)
	if S.DevTools and S.DevTools.onArenaClosed then
		S.DevTools.onArenaClosed()
	end
end

function TestArena.clear()
	local n = S.Enemies.count()
	S.Enemies.clear()
	if S.Projectiles and S.Projectiles.clear then
		S.Projectiles.clear()
	end
	return n
end

-- Spawns `count` of `kind` around the point `dist` studs in front of the player, facing them. Returns how many spawned (or an error string).
function TestArena.spawn(p: Player?, kind: any, count: any, dist: any): any
	local root = p and S.Players.getRoot(p)
	if not root then
		return "no player"
	end
	local map = S.Map.current
	if not map then
		return "no arena or mission map"
	end
	local id = string.upper(tostring(kind or "TINKER"))
	local def = EnemyData.get(id)
	if not def then
		return "unknown enemy kind " .. id
	end
	local n = math.clamp(math.floor(tonumber(count) or 1), 1, MAX_SPAWN)
	local d = tonumber(dist) or 30
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	look = if look.Magnitude > 0.05 then look.Unit else Vector3.zAxis
	local base = root.Position + look * d
	local spacing = math.max(3, def.size * 1.5)
	local made = 0
	for i = 1, n do
		-- sunflower layout: a tight pack, nobody spawns inside another unit
		local ang = i * 2.39996
		local r = spacing * math.sqrt(i - 1)
		local x, z = base.X + math.cos(ang) * r, base.Z + math.sin(ang) * r
		if map.arena then
			x = math.clamp(x, -HALF + 6, HALF - 6)
			z = math.clamp(z, -HALF + 6, HALF - 6)
		end
		local gy = map.groundY and map.groundY(x, z) or root.Position.Y - 3
		if gy > -200 then
			local pos = Vector3.new(x, gy, z)
			local face = Vector3.new(root.Position.X, gy, root.Position.Z)
			local ok, e = pcall(S.Enemies.spawn, id, CFrame.lookAt(pos, if (face - pos).Magnitude > 0.5 then face else pos + look), { aggro = true })
			if ok and e then
				made += 1
			else
				warn("[TestArena] spawn failed:", e)
			end
		end
	end
	return made
end

function TestArena.refill(p: Player)
	S.Players.refill(p)
	S.CallIns.reset(p, table.clone(CallInData.Starter)) -- fresh cooldowns / charges / uses, Reinforce included
end

function TestArena.toggleDirector(on: boolean?): boolean
	if not isActive then
		return false
	end
	local want = if on == nil then not directorOn else on
	if want == directorOn then
		return directorOn
	end
	if want then
		S.Director.start(arenaMap, arenaFaction, 1, { noInitial = true })
	else
		S.Director.stop(false)
	end
	directorOn = want
	Workspace:SetAttribute("ArenaDirector", directorOn)
	return directorOn
end

function TestArena.forceBreach(): any
	if not isActive then
		return "arena not open"
	end
	if not directorOn then
		TestArena.toggleDirector(true)
	end
	local ok, why = S.Director.debugBreach()
	return if ok then S.Director.getIntensity() else why
end

function TestArena.toggleFaction(): string
	arenaFaction = if arenaFaction == "COG" then "BROOD" elseif arenaFaction == "BROOD" then "LUMEN" else "COG"
	if isActive then
		S.Mission.faction = arenaFaction
		S.Mission.broadcast()
		if arenaMap then
			arenaMap.faction = arenaFaction
		end
		if arenaMap and arenaMap.folder then
			arenaMap.folder:SetAttribute("Faction", arenaFaction)
		end
		Workspace:SetAttribute("ArenaFaction", arenaFaction)
		if directorOn then -- restart pacing with the other faction (nothing pre-placed)
			S.Director.start(arenaMap, arenaFaction, 1, { noInitial = true })
		end
	end
	return arenaFaction
end

function TestArena.init(s: any)
	S = s
end

return TestArena
