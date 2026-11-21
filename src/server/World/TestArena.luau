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
-- Position: x/z in -220..220 (inside Config.MapSize/2 = 320 and EnemyAI +-300 clamp), surface at Y = 300: above the mission map
-- (terrain tops out near y = 176) and far below the ship (y = 900). Mission.start refuses while the arena is open, so the two never coexist.
-- Ground is TERRAIN (EnemyAI snaps enemies to Terrain only); the 840 x 840 slab gives the horizon real ground. Parts: 4 invisible walls + cover.
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
local HALF = 220 -- playable half extent (440 x 440)
local SLAB = 420 -- terrain slab half extent (840 x 840)
local SPAWN_Z = -185 -- the player starts at the south end, facing +Z
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
	-- broad low-saturation desert value bands + central compacted highway lane (32 wide, zero micro-clutter)
	t:FillBlock(CFrame.new(0, Y0 - 1.1, 0), Vector3.new(32, 2.4, HALF * 2), Enum.Material.Concrete)
	-- north fortified outpost yard slate/concrete deck (Z = +120..+175)
	t:FillBlock(CFrame.new(0, Y0 - 1.1, 148), Vector3.new(172, 2.4, 58), Enum.Material.Slate)
	local bands = {
		{ x = -132, z = 48, r = 74, mat = Enum.Material.Ground },
		{ x = 136, z = -42, r = 78, mat = Enum.Material.Sandstone },
		{ x = -114, z = -118, r = 64, mat = Enum.Material.Sandstone },
		{ x = 118, z = 112, r = 68, mat = Enum.Material.Ground },
		{ x = -72, z = 138, r = 48, mat = Enum.Material.Ground },
		{ x = 74, z = -132, r = 52, mat = Enum.Material.Ground },
		{ x = 0, z = 186, r = 42, mat = Enum.Material.Slate },
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

	-- stark brutalist weathered-concrete & dark-charcoal-steel cover (zero bright yellow/red neon clutter)
	local concrete = Color3.fromRGB(82, 78, 72)
	local concreteDark = Color3.fromRGB(60, 58, 55)
	local steelDark = Color3.fromRGB(42, 46, 52)
	local steelLight = Color3.fromRGB(118, 122, 130)
	local rust = Color3.fromRGB(96, 68, 52)
	local rockPalette = {
		Color3.fromRGB(78, 66, 54),
		Color3.fromRGB(64, 55, 47),
		Color3.fromRGB(88, 74, 60),
	}

	local function jerseyBarrier(pos: Vector3, len: number, yawDeg: number)
		local body = prop(props, "JerseyBarrier", Vector3.new(len, 4.8, 2.4), pos, yawDeg, concrete, Enum.Material.Concrete)
		body:SetAttribute("KeepMat", true)
		local trim = Instance.new("Part")
		trim.Name = "BarrierCap"
		trim.Anchored = true
		trim.CanCollide = false
		trim.CanQuery = false
		trim.CanTouch = false
		trim.CastShadow = false
		trim.Size = Vector3.new(len + 0.15, 0.5, 2.0)
		trim.CFrame = body.CFrame * CFrame.new(0, 2.25, 0)
		trim.Color = steelDark
		trim.Material = Enum.Material.Metal
		trim:SetAttribute("KeepMat", true)
		trim.Parent = props
	end

	local function localPart(cfBase: CFrame, name: string, size: Vector3, localPos: Vector3, color: Color3, mat: Enum.Material)
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.Size = size
		p.CFrame = cfBase * CFrame.new(localPos.X, size.Y / 2 + localPos.Y, localPos.Z)
		p.Color = color
		p.Material = mat
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p:SetAttribute("KeepMat", true)
		p.Parent = props
		return p
	end

	local function crateStack(x: number, z: number, yawDeg: number)
		local base = CFrame.new(x, Y0, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
		localPart(base, "Crate", Vector3.new(5.5, 4.4, 5.5), Vector3.new(-3.2, 0, -1.0), steelDark, Enum.Material.Metal)
		localPart(base, "Crate", Vector3.new(5.5, 4.4, 5.5), Vector3.new(3.2, 0, 1.2), rust, Enum.Material.CorrodedMetal)
		local top = localPart(base, "Crate", Vector3.new(5.0, 3.8, 5.0), Vector3.new(0, 4.4, 0), steelDark, Enum.Material.Metal)
		top.CFrame *= CFrame.Angles(0, math.rad(24), 0)
	end

	local function bunker(cx: number, cz: number, yawDeg: number, hasRoof: boolean)
		local cfBase = CFrame.new(cx, Y0, cz) * CFrame.Angles(0, math.rad(yawDeg), 0)
		-- open-flank concrete bunker with front doorway gap & side wing entrances for cover/flanking AI tests
		localPart(cfBase, "CoverWall", Vector3.new(20, 7.2, 2.2), Vector3.new(0, 0, 6), concrete, Enum.Material.Concrete)
		localPart(cfBase, "CoverWall", Vector3.new(2.2, 7.2, 9.5), Vector3.new(-9, 0, -0.5), concreteDark, Enum.Material.Concrete)
		localPart(cfBase, "CoverWall", Vector3.new(2.2, 7.2, 9.5), Vector3.new(9, 0, -0.5), concreteDark, Enum.Material.Concrete)
		localPart(cfBase, "CoverWall", Vector3.new(6.2, 4.6, 2.2), Vector3.new(-6.4, 0, -6.5), concrete, Enum.Material.Concrete)
		localPart(cfBase, "CoverWall", Vector3.new(6.2, 4.6, 2.2), Vector3.new(6.4, 0, -6.5), concrete, Enum.Material.Concrete)
		if hasRoof then
			localPart(cfBase, "BunkerRoof", Vector3.new(21.5, 1.2, 16.5), Vector3.new(0, 7.2, -0.2), concreteDark, Enum.Material.Concrete)
		end
	end

	local function checkpoint(cx: number, cz: number, yawDeg: number)
		local cfBase = CFrame.new(cx, Y0, cz) * CFrame.Angles(0, math.rad(yawDeg), 0)
		localPart(cfBase, "CheckpointWall", Vector3.new(2.4, 7.4, 15), Vector3.new(-5.5, 0, 0), concreteDark, Enum.Material.Concrete)
		localPart(cfBase, "CheckpointWing", Vector3.new(8.5, 4.8, 2.2), Vector3.new(-0.5, 0, -6.4), concrete, Enum.Material.Concrete)
		localPart(cfBase, "CheckpointWing", Vector3.new(8.5, 4.8, 2.2), Vector3.new(-0.5, 0, 6.4), concrete, Enum.Material.Concrete)
		localPart(cfBase, "CheckpointCanopy", Vector3.new(12.5, 1.0, 16.5), Vector3.new(-1.5, 7.4, 0), steelDark, Enum.Material.Metal)
	end

	local function placeMeshProp(key: string, cf: CFrame, scale: number, tint: Color3, mat: Enum.Material, collidable: boolean, fallbackSize: Vector3?)
		local m = Assets.get(key, { anchored = true })
		if m then
			if scale ~= 1 then
				m:ScaleTo(scale)
			end
			m:PivotTo(cf)
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = collidable
					d.CanQuery = collidable
					d.CanTouch = false
					d.CastShadow = collidable
					d.Color = tint
					d.Material = mat
					d:SetAttribute("KeepMat", true)
				end
			end
			m.Parent = props
			return
		end
		if fallbackSize then
			local b = prop(props, "Boulder", fallbackSize, Vector3.new(cf.Position.X, 0, cf.Position.Z), 0, tint, mat)
			b:SetAttribute("KeepMat", true)
		end
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

	-- Central compacted highway lane (32 wide): staggered Jersey barrier firing bays preserving a >300-stud center sightline down X = 0
	for _, jb in {
		{ x = -12.5, z = -132, len = 14, yaw = 8 },
		{ x = 12.5, z = -96, len = 14, yaw = -8 },
		{ x = -12.5, z = -12, len = 16, yaw = 6 },
		{ x = 12.5, z = 28, len = 16, yaw = -6 },
		{ x = -12.5, z = 78, len = 14, yaw = 10 },
		{ x = 12.5, z = 92, len = 14, yaw = -10 },
	} do
		jerseyBarrier(Vector3.new(jb.x, 0, jb.z), jb.len, jb.yaw)
	end
	-- Two flanking concrete highway checkpoints
	checkpoint(-28, -56, 0)
	checkpoint(28, 48, 180)

	-- West & East combat lanes: cover bunkers, Jersey barriers, supply crates, and sandstone/basalt rock cover clusters
	bunker(-98, -24, 15, true)
	bunker(-134, 72, -20, false)
	bunker(98, 12, 165, true)
	bunker(132, -82, 200, false)

	for _, jb in {
		{ x = -64, z = -84, len = 14, yaw = 24 },
		{ x = -154, z = -66, len = 14, yaw = -18 },
		{ x = -74, z = 34, len = 15, yaw = -14 },
		{ x = -148, z = 134, len = 14, yaw = 22 },
		{ x = 64, z = -36, len = 14, yaw = -22 },
		{ x = 156, z = -18, len = 14, yaw = 16 },
		{ x = 72, z = 76, len = 15, yaw = 14 },
		{ x = 148, z = 130, len = 14, yaw = -22 },
	} do
		jerseyBarrier(Vector3.new(jb.x, 0, jb.z), jb.len, jb.yaw)
	end

	for _, cs in {
		{ x = -68, z = 14, yaw = 12 },
		{ x = -118, z = -126, yaw = -18 },
		{ x = 68, z = -118, yaw = -14 },
		{ x = 118, z = 72, yaw = 22 },
		{ x = -58, z = 144, yaw = 10 },
		{ x = 58, z = 144, yaw = -10 },
	} do
		crateStack(cs.x, cs.z, cs.yaw)
	end

	local rockClusters = {
		{ key = "env_rock_a", x = -78, z = -138, yaw = 27, sc = 1.25, sink = 1.2, mat = Enum.Material.Basalt, tint = rockPalette[2], fb = Vector3.new(12, 7, 9) },
		{ key = "env_rock_c", x = -90, z = -148, yaw = -40, sc = 0.85, sink = 1.0, mat = Enum.Material.Sandstone, tint = rockPalette[1], fb = Vector3.new(8, 5, 7) },
		{ key = "env_rock_b", x = -162, z = 16, yaw = 18, sc = 1.15, sink = 1.3, mat = Enum.Material.Sandstone, tint = rockPalette[3], fb = Vector3.new(13, 10, 11) },
		{ key = "env_rock_a", x = -148, z = 28, yaw = -28, sc = 1.0, sink = 1.1, mat = Enum.Material.Sandstone, tint = rockPalette[1], fb = Vector3.new(10, 6, 8) },
		{ key = "env_rock_b", x = -116, z = 126, yaw = 42, sc = 1.05, sink = 1.4, mat = Enum.Material.Basalt, tint = rockPalette[2], fb = Vector3.new(12, 11, 10) },
		{ key = "env_rock_c", x = -104, z = 116, yaw = -15, sc = 1.05, sink = 1.0, mat = Enum.Material.Sandstone, tint = rockPalette[3], fb = Vector3.new(8, 6, 7) },
		{ key = "env_rock_a", x = 86, z = -142, yaw = -24, sc = 1.15, sink = 1.1, mat = Enum.Material.Sandstone, tint = rockPalette[3], fb = Vector3.new(11, 7, 9) },
		{ key = "env_rock_c", x = 98, z = -132, yaw = 35, sc = 0.85, sink = 1.0, mat = Enum.Material.Basalt, tint = rockPalette[2], fb = Vector3.new(9, 5, 7) },
		{ key = "env_rock_a", x = 158, z = -32, yaw = -32, sc = 1.2, sink = 1.2, mat = Enum.Material.Basalt, tint = rockPalette[1], fb = Vector3.new(12, 7, 9) },
		{ key = "env_rock_c", x = 146, z = -20, yaw = 22, sc = 1.05, sink = 1.0, mat = Enum.Material.Sandstone, tint = rockPalette[3], fb = Vector3.new(8, 6, 7) },
		{ key = "env_rock_b", x = 124, z = 118, yaw = -46, sc = 1.15, sink = 1.3, mat = Enum.Material.Sandstone, tint = rockPalette[1], fb = Vector3.new(13, 10, 11) },
		{ key = "env_rock_b", x = 110, z = 128, yaw = 14, sc = 1.0, sink = 1.4, mat = Enum.Material.Basalt, tint = rockPalette[2], fb = Vector3.new(11, 10, 9) },
	}
	for _, rc in rockClusters do
		placeMeshProp(rc.key, CFrame.new(rc.x, Y0 - rc.sink, rc.z) * CFrame.Angles(0, math.rad(rc.yaw), 0), rc.sc, rc.tint, rc.mat, true, rc.fb)
	end

	-- North fortified outpost yard (Z = +120..+175, X = -84..+84) with central & flank breach doorways
	local outpostWalls = {
		{ name = "OutpostWall", size = Vector3.new(30, 8.5, 3.0), pos = Vector3.new(-29, 0, 120), col = concrete },
		{ name = "OutpostWall", size = Vector3.new(30, 8.5, 3.0), pos = Vector3.new(29, 0, 120), col = concrete },
		{ name = "OutpostWall", size = Vector3.new(26, 8.5, 3.0), pos = Vector3.new(-71, 0, 120), col = concreteDark },
		{ name = "OutpostWall", size = Vector3.new(26, 8.5, 3.0), pos = Vector3.new(71, 0, 120), col = concreteDark },
		{ name = "OutpostWall", size = Vector3.new(3.0, 8.5, 24), pos = Vector3.new(-84, 0, 134), col = concreteDark },
		{ name = "OutpostWall", size = Vector3.new(3.0, 8.5, 18), pos = Vector3.new(-84, 0, 166), col = concreteDark },
		{ name = "OutpostWall", size = Vector3.new(3.0, 8.5, 24), pos = Vector3.new(84, 0, 134), col = concreteDark },
		{ name = "OutpostWall", size = Vector3.new(3.0, 8.5, 18), pos = Vector3.new(84, 0, 166), col = concreteDark },
		{ name = "OutpostWall", size = Vector3.new(68, 8.5, 3.0), pos = Vector3.new(-50, 0, 175), col = concrete },
		{ name = "OutpostWall", size = Vector3.new(68, 8.5, 3.0), pos = Vector3.new(50, 0, 175), col = concrete },
		{ name = "CoverWall", size = Vector3.new(16, 5.2, 2.4), pos = Vector3.new(-46, 0, 154), col = concreteDark },
		{ name = "CoverWall", size = Vector3.new(16, 5.2, 2.4), pos = Vector3.new(46, 0, 154), col = concreteDark },
	}
	for _, w in outpostWalls do
		local part = prop(props, w.name, w.size, w.pos, 0, w.col, Enum.Material.Concrete)
		part:SetAttribute("KeepMat", true)
	end
	jerseyBarrier(Vector3.new(-18, 0, 114), 10, 22)
	jerseyBarrier(Vector3.new(18, 0, 114), 10, -22)
	jerseyBarrier(Vector3.new(-24, 0, 146), 14, -18)
	jerseyBarrier(Vector3.new(24, 0, 146), 14, 18)

	-- 360-degree natural desert canyon rim & towering mountain skyline projected outside the 440 x 440 square
	local function ringPos(angDeg: number, wallOffset: number): (number, number, number)
		local a = math.rad(angDeg)
		local boxR = HALF / math.max(math.abs(math.cos(a)), math.abs(math.sin(a)))
		local r = boxR + wallOffset
		return math.cos(a) * r, math.sin(a) * r, a
	end

	-- Band 1: near-rim jagged canyon cliffs & rock buttresses (HALF + 16..34 outside the playable walls)
	local nearRim = {
		{ ang = 0, off = 22, key = "desert_cliff", sc = 3.2, yawOff = 90, sink = 16 },
		{ ang = 24, off = 28, key = "env_spire_b", sc = 2.2, yawOff = 15, sink = 18 },
		{ ang = 46, off = 20, key = "desert_cliff", sc = 3.0, yawOff = 84, sink = 15 },
		{ ang = 70, off = 32, key = "env_rock_b", sc = 4.6, yawOff = -22, sink = 16 },
		{ ang = 92, off = 24, key = "desert_cliff", sc = 3.3, yawOff = 96, sink = 16 },
		{ ang = 116, off = 28, key = "env_spire_a", sc = 2.1, yawOff = 40, sink = 18 },
		{ ang = 138, off = 20, key = "desert_cliff", sc = 3.1, yawOff = 88, sink = 15 },
		{ ang = 162, off = 34, key = "env_spire_b", sc = 2.3, yawOff = -30, sink = 18 },
		{ ang = 184, off = 22, key = "desert_cliff", sc = 3.2, yawOff = 94, sink = 16 },
		{ ang = 208, off = 30, key = "env_rock_b", sc = 4.8, yawOff = 18, sink = 16 },
		{ ang = 230, off = 20, key = "desert_cliff", sc = 3.1, yawOff = 82, sink = 15 },
		{ ang = 254, off = 28, key = "env_spire_a", sc = 2.0, yawOff = -12, sink = 18 },
		{ ang = 276, off = 24, key = "desert_cliff", sc = 3.2, yawOff = 90, sink = 16 },
		{ ang = 300, off = 32, key = "env_spire_b", sc = 2.2, yawOff = 24, sink = 18 },
		{ ang = 322, off = 20, key = "desert_cliff", sc = 3.0, yawOff = 86, sink = 15 },
		{ ang = 344, off = 28, key = "env_rock_b", sc = 4.5, yawOff = -16, sink = 16 },
	}
	for i, sp in nearRim do
		local x, z, a = ringPos(sp.ang, sp.off)
		local tint = rockPalette[(i % #rockPalette) + 1]
		local mat = if sp.key == "desert_cliff" then Enum.Material.Rock else Enum.Material.Slate
		placeMeshProp(sp.key, CFrame.new(x, Y0 - sp.sink, z) * CFrame.Angles(0, a + math.rad(sp.yawOff), 0), sp.sc, tint, mat, false)
	end

	-- Band 2: distant towering jagged mountain peaks fading cleanly into golden atmospheric haze
	local farPeaks = {
		{ ang = 14, off = 96, key = "env_spire_b", sc = 3.8, yawOff = 24, sink = 24 },
		{ ang = 48, off = 112, key = "env_spire_a", sc = 3.5, yawOff = -18, sink = 26 },
		{ ang = 78, off = 92, key = "desert_cliff", sc = 4.8, yawOff = 92, sink = 22 },
		{ ang = 110, off = 118, key = "env_spire_b", sc = 4.2, yawOff = 45, sink = 26 },
		{ ang = 140, off = 98, key = "env_spire_a", sc = 3.4, yawOff = -35, sink = 24 },
		{ ang = 172, off = 108, key = "desert_cliff", sc = 5.0, yawOff = 86, sink = 22 },
		{ ang = 202, off = 94, key = "env_spire_b", sc = 3.9, yawOff = 12, sink = 24 },
		{ ang = 234, off = 116, key = "env_spire_a", sc = 3.6, yawOff = -42, sink = 26 },
		{ ang = 266, off = 102, key = "desert_cliff", sc = 4.7, yawOff = 94, sink = 22 },
		{ ang = 296, off = 120, key = "env_spire_b", sc = 4.1, yawOff = 30, sink = 26 },
		{ ang = 326, off = 96, key = "env_spire_a", sc = 3.3, yawOff = -20, sink = 24 },
		{ ang = 352, off = 110, key = "desert_cliff", sc = 4.9, yawOff = 88, sink = 22 },
	}
	for i, sp in farPeaks do
		local x, z, a = ringPos(sp.ang, sp.off)
		local tint = rockPalette[((i + 1) % #rockPalette) + 1]
		local mat = if sp.key == "desert_cliff" then Enum.Material.Rock else Enum.Material.Slate
		placeMeshProp(sp.key, CFrame.new(x, Y0 - sp.sink, z) * CFrame.Angles(0, a + math.rad(sp.yawOff), 0), sp.sc, tint, mat, false)
	end

	folder.Parent = Workspace
	return folder, props
end

local function makeMap(folder: Folder, props: Folder): any
	local patrol: { Vector3 } = {}
	for _, p in { { -115, 65 }, { 115, 65 }, { 0, 148 }, { -95, -55 }, { 95, -55 } } do
		table.insert(patrol, Vector3.new(p[1], Y0 + 1, p[2]))
	end
	return {
		name = "Test Arena",
		arena = true,
		faction = arenaFaction,
		biome = "desert",
		size = HALF * 2,
		insertion = CFrame.new(0, Y0, SPAWN_Z),
		extraction = Vector3.new(0, Y0, HALF - 18),
		sites = {},
		patrolPoints = patrol,
		spawnPoints = {
			Vector3.new(-145, Y0 + 1, 145),
			Vector3.new(145, Y0 + 1, 145),
			Vector3.new(-145, Y0 + 1, 10),
			Vector3.new(145, Y0 + 1, 10),
		},
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
