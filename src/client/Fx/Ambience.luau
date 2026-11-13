--!nonstrict
-- Living air (docs/art-direction.md rule 7): a box of ambient particles that follows the camera, per biome,
-- plus 2-4 distant smoke columns. Local only, budgeted by Fx.quality (0.3-1, derived from the saved graphics level).
--   desert: dust motes + a few wind-blown dust gusts      ash: falling ash + rising embers
--   swamp:  drifting spores + a few glowing fireflies     ice: snowfall + glints
-- The biome comes from workspace.Map attribute "Biome" (set by MapBuilder; falls back to the mission planet's biome).
-- Off on the ship (no Map folder / mission state "Ship").

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Planets = require(Shared.Data.Planets)

local Ambience = {}

local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
-- soft round mote for spores/embers/glints/fireflies (the 4-point sparkle texture read as cartoon stars)
local TEX_MOTE = TEX_SMOKE

local RGB = Color3.fromRGB
local NS = NumberSequence.new
local NK = NumberSequenceKeypoint.new

local Store: any = nil
local quality = 1

-- NumberSequence helper: {a, b, c} -> evenly spaced keypoints
local function seq(vals: { number }): NumberSequence
	local kps = {}
	local n = #vals
	for i, v in vals do
		table.insert(kps, NK((i - 1) / math.max(n - 1, 1), v))
	end
	return NS(kps)
end

-- Emitter presets per biome. rate is particles/second at quality 1.
local BIOME_FX: { [string]: { any } } = {
	desert = {
		{ -- dust motes
			tex = TEX_SMOKE, rate = 16, life = { 6, 9 }, speed = { 0.4, 1.4 }, spread = 180, dir = "Top",
			size = { 0.25, 0.5 }, alpha = { 0.55, 0.45, 1 }, color = RGB(255, 214, 160), emit = 0.5, accel = Vector3.new(2.2, 0.2, 1.2),
		},
		{ -- gusts of dust along the ground
			tex = TEX_SMOKE, rate = 1.2, life = { 6, 8 }, speed = { 10, 16 }, spread = 14, dir = "Right",
			size = { 6, 14 }, alpha = { 0.92, 0.86, 1 }, color = RGB(236, 190, 140), emit = 0, accel = Vector3.new(0, 0.3, 0),
		},
	},
	ash = {
		{ -- falling ash
			tex = TEX_SMOKE, rate = 24, life = { 8, 11 }, speed = { 2, 4 }, spread = 25, dir = "Bottom",
			size = { 0.3, 0.55 }, alpha = { 0.25, 0.35, 0.9 }, color = RGB(96, 88, 86), emit = 0, accel = Vector3.new(3, 0, 1.4),
		},
		{ -- rising embers
			tex = TEX_MOTE, rate = 6, life = { 5, 8 }, speed = { 3, 7 }, spread = 40, dir = "Top",
			size = { 0.25, 0.45 }, alpha = { 0, 0.2, 1 }, color = RGB(255, 140, 50), emit = 1, accel = Vector3.new(2, 1.5, 0.6),
		},
	},
	swamp = {
		{ -- spores
			tex = TEX_MOTE, rate = 12, life = { 8, 11 }, speed = { 0.3, 1 }, spread = 180, dir = "Top",
			size = { 0.28, 0.5 }, alpha = { 0.4, 0.2, 1 }, color = RGB(170, 240, 150), emit = 0.6, accel = Vector3.new(0.6, 0.4, 0.3),
		},
		{ -- fireflies
			tex = TEX_MOTE, rate = 0.7, life = { 9, 12 }, speed = { 0.5, 1.6 }, spread = 180, dir = "Top",
			size = { 0.7, 1.0 }, alpha = { 1, 0, 0.35, 0, 1 }, color = RGB(210, 255, 120), emit = 1, accel = Vector3.new(0, 0, 0), firefly = true,
		},
	},
	ice = {
		{ -- snow
			tex = TEX_SMOKE, rate = 34, life = { 8, 11 }, speed = { 3, 5 }, spread = 20, dir = "Bottom",
			size = { 0.28, 0.5 }, alpha = { 0.1, 0.1, 0.8 }, color = RGB(240, 248, 255), emit = 0.3, accel = Vector3.new(4, 0, 2),
		},
		{ -- glints
			tex = TEX_MOTE, rate = 4, life = { 4, 7 }, speed = { 0.5, 1.5 }, spread = 180, dir = "Top",
			size = { 0.3, 0.5 }, alpha = { 1, 0.1, 1 }, color = RGB(220, 240, 255), emit = 1, accel = Vector3.new(2, -0.4, 1),
		},
	},
}

-- distant smoke column colours per biome
local SMOKE_COLOR = {
	desert = RGB(120, 96, 78),
	ash = RGB(46, 30, 30),
	swamp = RGB(86, 120, 96),
	ice = RGB(210, 224, 244),
}

local DIRS = {
	Top = Enum.NormalId.Top, Bottom = Enum.NormalId.Bottom, Right = Enum.NormalId.Right,
	Left = Enum.NormalId.Left, Front = Enum.NormalId.Front, Back = Enum.NormalId.Back,
}

local folder: Folder? = nil
local conn: RBXScriptConnection? = nil
local activeBiome: string? = nil
local columnToken = 0

local function makeEmitter(parent: Instance, spec: any, q: number)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = spec.tex
	pe.Rate = math.max(spec.rate * q, 0.2)
	pe.Lifetime = NumberRange.new(spec.life[1], spec.life[2])
	pe.Speed = NumberRange.new(spec.speed[1], spec.speed[2])
	pe.SpreadAngle = Vector2.new(spec.spread, spec.spread)
	pe.EmissionDirection = DIRS[spec.dir] or Enum.NormalId.Top
	pe.Size = NS({ NK(0, spec.size[1]), NK(0.5, spec.size[2]), NK(1, spec.size[1]) })
	pe.Transparency = seq(spec.alpha)
	pe.Color = ColorSequence.new(spec.color)
	pe.LightEmission = spec.emit
	pe.LightInfluence = if spec.emit >= 1 then 0 else 0.6
	pe.Acceleration = spec.accel
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-30, 30)
	pe.LockedToPart = false
	pe.Drag = if spec.firefly then 1 else 0.2
	pe.Shape = Enum.ParticleEmitterShape.Box
	pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	pe.Parent = parent
end

local function teardown()
	columnToken += 1
	if conn then
		conn:Disconnect()
		conn = nil
	end
	if folder then
		folder:Destroy()
		folder = nil
	end
	activeBiome = nil
end

local function groundAt(x: number, z: number): number?
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Include
	rp.FilterDescendantsInstances = { Workspace.Terrain }
	local r = Workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -600, 0), rp)
	return r and r.Position.Y or nil
end

-- 2-4 distant smoke columns on the horizon ring, deterministic so everyone sees the same ones
local function buildColumns(biome: string, token: number)
	task.wait(3) -- terrain streams in just after the Map folder appears
	if token ~= columnToken or not folder then
		return
	end
	local count = 2 + (if quality > 0.6 then 1 else 0) + (if quality > 0.85 then 1 else 0)
	local rnd = Random.new(7741)
	local base = rnd:NextNumber(0, math.pi * 2)
	local color = SMOKE_COLOR[biome] or SMOKE_COLOR.desert
	for i = 1, count do
		local a = base + (i - 1) / count * math.pi * 2 + rnd:NextNumber(-0.3, 0.3)
		local d = rnd:NextNumber(255, 300)
		local x, z = math.cos(a) * d, math.sin(a) * d
		local y = groundAt(x, z) or 20
		local p = Instance.new("Part")
		p.Name = "SmokeColumn"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Transparency = 1
		p.Size = Vector3.new(10, 1, 10)
		p.CFrame = CFrame.new(x, y + 1, z)
		p.Parent = folder
		local pe = Instance.new("ParticleEmitter")
		pe.Texture = TEX_SMOKE
		pe.Rate = math.max(3.2 * quality, 1.5)
		pe.Lifetime = NumberRange.new(16, 22)
		pe.Speed = NumberRange.new(14, 19)
		pe.SpreadAngle = Vector2.new(5, 5)
		pe.Size = NS({ NK(0, 10), NK(0.4, 34), NK(1, 78) })
		pe.Transparency = NS({ NK(0, 0.55), NK(0.5, 0.72), NK(1, 1) })
		pe.Color = ColorSequence.new(color)
		pe.Rotation = NumberRange.new(0, 360)
		pe.RotSpeed = NumberRange.new(-6, 6)
		pe.Acceleration = Vector3.new(7, 0, 3)
		pe.LightInfluence = 0.7
		pe.Parent = p
		task.wait()
	end
end

local function start(biome: string)
	teardown()
	local specs = BIOME_FX[biome]
	if not specs then
		return
	end
	activeBiome = biome
	local f = Instance.new("Folder")
	f.Name = "ClientAmbience"
	f.Parent = Workspace
	folder = f

	local h = Instance.new("Part")
	h.Name = "AirBox"
	h.Anchored = true
	h.CanCollide = false
	h.CanQuery = false
	h.CanTouch = false
	h.CastShadow = false
	h.Transparency = 1
	h.Size = Vector3.new(64, 34, 64)
	h.Parent = f
	for _, spec in specs do
		-- fireflies only on decent graphics settings
		if not (spec.firefly and quality < 0.5) then
			makeEmitter(h, spec, math.max(quality, 0.3))
		end
	end

	conn = RunService.RenderStepped:Connect(function()
		local cam = Workspace.CurrentCamera
		if cam and h.Parent then
			h.CFrame = CFrame.new(cam.CFrame.Position + Vector3.new(0, 10, 0))
		end
	end)

	local token = columnToken
	task.spawn(buildColumns, biome, token)
end

-- Which biome should be running right now (nil = none: ship, no map)
local function desiredBiome(): string?
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local mission = Store and Store.get("mission")
	if mission and mission.state == "Ship" then
		return nil
	end
	local b = map:GetAttribute("Biome")
	if type(b) == "string" and BIOME_FX[b] then
		return b
	end
	if mission and mission.planet then
		local pl = Planets.get(mission.planet)
		if pl and BIOME_FX[pl.biome] then
			return pl.biome
		end
	end
	return if mission and mission.faction == "BROOD" then "swamp" else "desert"
end

local function refresh()
	local want = desiredBiome()
	if want ~= activeBiome then
		if want then
			start(want)
		else
			teardown()
		end
	end
end

function Ambience.init(Fx: any, _Audio: any, _Juice: any)
	quality = if Fx and type(Fx.quality) == "number" then math.clamp(Fx.quality, 0.3, 1) else 1
	local ok, mod = pcall(function()
		return require(script.Parent.Parent:WaitForChild("Store", 10))
	end)
	if ok then
		Store = mod
	end
	if Store then
		Store.on("mission", function()
			refresh()
		end)
	end
	Workspace.ChildAdded:Connect(function(c)
		if c.Name == "Map" then
			task.defer(refresh)
		end
	end)
	Workspace.ChildRemoved:Connect(function(c)
		if c.Name == "Map" then
			task.defer(refresh)
		end
	end)
	-- safety net (late attribute replication, state changes)
	task.spawn(function()
		while true do
			refresh()
			task.wait(1)
		end
	end)
end

return Ambience
