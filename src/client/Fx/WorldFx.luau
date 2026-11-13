-- Client visuals for the world/objective systems:
--   Fx "Missile"  phase "doors"  {p, t}             silo seals blow: steam jets, then the hatch leaves slam open (server tween)
--                 phase "ignite" {p, t}             ignition hold: smoke billows out of the silo mouth, ground ring, flicker
--                 phase "launch" {p, mouth, top, rise, t, dir, tail, m}   liftoff: flash, rolling dust ring, lingering exhaust
--                       column, the missile root `m` is flown locally along missilePath (slight arc), flame + streak + far flare
--   Fx "Skiff"    {p, t, phase, pre?, fly?, inward?, root?, m?}   phase "land"|"leave" (p = Skiff root on the pad). "leave":
--                 ramp closes for `pre` s, then every client flies the replicated Skiff locally along skiffPath; boarded
--                 players get the takeoff cinematic (letterbox, crane shot, fade to black, Results backdrop).
--   Fx "Minigame" {id, obj, bands, speeds, pos, timeout}   the trajectory dial UI (3 needles, lock inside the green band)
-- The mini-game reports with Action "minigame"(obj, {locks = {a1, a2, a3}} | {cancel = true}).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Config = require(Shared.Config)

local WorldFx = {}

local Audio: any = nil
local Juice: any = nil
local FxApi: any = nil
local CamApi: any = nil
local localPlayer = Players.LocalPlayer

local function quality(): number
	return if FxApi and type(FxApi.quality) == "number" then FxApi.quality else 1
end

local fxFolder: Folder? = nil
local function getFolder(): Folder
	if fxFolder and fxFolder.Parent then
		return fxFolder
	end
	local f = Instance.new("Folder")
	f.Name = "ClientWorldFx"
	f.Parent = Workspace
	fxFolder = f
	return f
end

local function play3D(key: string, at: Vector3?)
	if Audio and Audio.play then
		pcall(Audio.play, key, at)
	end
end

local function play2D(key: string)
	if Audio and Audio.play2D then
		pcall(Audio.play2D, key)
	end
end

local function shake(mag: number, dur: number, pos: Vector3?)
	if Juice and Juice.shake then
		pcall(Juice.shake, mag, dur, pos)
	end
end

local function flash(color: Color3, alpha: number, dur: number)
	if Juice and Juice.flash then
		pcall(Juice.flash, color, alpha, dur)
	end
end

local function distanceToCamera(p: Vector3): number
	local cam = Workspace.CurrentCamera
	if not cam then
		return 0
	end
	return (cam.CFrame.Position - p).Magnitude
end

local function anchorPart(pos: Vector3, size: Vector3?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = size or Vector3.new(1, 1, 1)
	p.Position = pos
	p.Parent = getFolder()
	return p
end

local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local FIRE = "rbxasset://textures/particles/fire_main.dds"

local function emitter(parent: Instance, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = SMOKE
	e.Rate = 0
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = parent
	return e
end

local function ring(pos: Vector3, color: Color3, fromD: number, toD: number, dur: number)
	local r = Instance.new("Part")
	r.Anchored = true
	r.CanCollide = false
	r.CanQuery = false
	r.CanTouch = false
	r.CastShadow = false
	r.Shape = Enum.PartType.Cylinder
	r.Material = Enum.Material.Neon
	r.Color = color
	r.Transparency = 0.2
	r.Size = Vector3.new(0.6, fromD, fromD)
	r.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2)
	r.Parent = getFolder()
	local tw = TweenService:Create(r, TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.3, toD, toD), Transparency = 1 })
	tw:Play()
	Debris:AddItem(r, dur + 0.2)
end

-- ---------------------------------------------------------------- shared helpers (missile + skiff)
local NK = NumberSequenceKeypoint.new
local function NS(flat: { number }): NumberSequence
	-- flat {t0, v0, t1, v1, ...}
	local kps = {}
	for i = 1, #flat, 2 do
		kps[#kps + 1] = NK(flat[i], flat[i + 1])
	end
	return NumberSequence.new(kps)
end

local stepSeq = 0
local function bindStep(name: string, fn: (number) -> ()): () -> ()
	-- runs right before the camera (CameraController binds at Camera priority): locally moved parts, Fx rigs and the
	-- cinematic camera all read the same pose in the same frame (no one-frame lag / jitter)
	stepSeq += 1
	local id = "WorldFx_" .. name .. stepSeq
	RunService:BindToRenderStep(id, Enum.RenderPriority.Camera.Value - 1, fn)
	local bound = true
	return function()
		if bound then
			bound = false
			RunService:UnbindFromRenderStep(id)
		end
	end
end

local function smooth(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

-- distant thump: 2D so it carries across the whole map, softened and delayed (speed of sound feel) with distance
local function boom(key: string, at: Vector3, maxVol: number)
	local d = distanceToCamera(at)
	local vol = math.clamp(maxVol * (1 - d / 1800), 0.18, maxVol)
	task.delay(math.min(d / 1100, 1.2), function()
		if Audio and Audio.play2D then
			pcall(Audio.play2D, key, { volume = vol })
		end
	end)
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
local function groundAt(pos: Vector3): Vector3?
	local map = Workspace:FindFirstChild("Map")
	local list: { Instance } = { Workspace.Terrain }
	if map then
		list[2] = map
	end
	groundParams.FilterDescendantsInstances = list
	local hit = Workspace:Raycast(pos + Vector3.new(0, 120, 0), Vector3.new(0, -320, 0), groundParams)
	return hit and hit.Position
end

-- `count` invisible hosts on a circle around `center`, each emitting outward (Front): a ground-hugging ring
local function sideRing(center: Vector3, count: number, radius: number, props: { [string]: any }, burst: number, life: number): { ParticleEmitter }
	local list: { ParticleEmitter } = {}
	for k = 0, count - 1 do
		local a = k / count * math.pi * 2 + math.random() * 0.4
		local out = Vector3.new(math.cos(a), 0, math.sin(a))
		local host = anchorPart(center + out * radius)
		host.CFrame = CFrame.lookAt(center + out * radius, center + out * (radius + 1))
		local e = emitter(host, props)
		if burst > 0 then
			e:Emit(burst)
		end
		Debris:AddItem(host, life)
		list[#list + 1] = e
	end
	return list
end

local EXHAUST = ColorSequence.new(Color3.fromRGB(238, 236, 232), Color3.fromRGB(146, 144, 142))
local DENSE = NS({ 0, 0.05, 0.55, 0.4, 1, 1 })

-- ---------------------------------------------------------------- Missile
-- Flight curve (client only: the server leaves the missile root in the silo and deletes it after t + 4 s; every client flies
-- the replicated root locally): quad-in climb along `dir` plus a cubic sideways bend, so the climb arcs over slightly.
local MISSILE_ARC = 0.22

local function missilePath(top: Vector3, dir: Vector3, arcDir: Vector3, rise: number, a: number): (Vector3, Vector3)
	local pos = top + dir * rise * a * a + arcDir * rise * MISSILE_ARC * a * a * a
	local vel = dir * 2 * a + arcDir * 3 * MISSILE_ARC * a * a
	return pos, if vel.Magnitude > 1e-3 then vel.Unit else dir
end

local function steamProps(dirId: Enum.NormalId, speed: NumberRange, spread: Vector2): { [string]: any }
	return {
		Lifetime = NumberRange.new(1.3, 2.3),
		Speed = speed,
		SpreadAngle = spread,
		EmissionDirection = dirId,
		Drag = 2.4,
		LightInfluence = 0.8,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-50, 50),
		Acceleration = Vector3.new(3, 5, 1.5),
		Size = NS({ 0, 2.5, 1, 15 }),
		Transparency = NS({ 0, 0.15, 0.5, 0.55, 1, 1 }),
		Color = ColorSequence.new(Color3.fromRGB(248, 248, 246), Color3.fromRGB(196, 196, 198)),
	}
end

-- silo seals blow: a vertical steam jet + sideways seam jets, a second puff when the leaves hit their stops
local function missileDoors(p: Vector3, T: number)
	local q = quality()
	play3D("GasHiss", p)
	shake(0.45, 0.6, p)
	local host = anchorPart(p + Vector3.new(0, 1, 0))
	Debris:AddItem(host, T + 4)
	local jet = emitter(host, steamProps(Enum.NormalId.Top, NumberRange.new(28, 50), Vector2.new(12, 12)))
	jet:Emit(math.floor(20 * q) + 4)
	jet.Rate = 40 * q
	local seams = sideRing(p + Vector3.new(0, 1.2, 0), if q < 0.6 then 4 else 6, 4, steamProps(Enum.NormalId.Front, NumberRange.new(30, 52), Vector2.new(8, 22)), math.floor(5 * q) + 1, T + 4)
	for _, e in seams do
		e.Rate = 10 * q
	end
	task.delay(T * 0.6, function()
		jet.Rate = 0
		for _, e in seams do
			e.Enabled = false
		end
	end)
	task.delay(1.2, function()
		-- leaves slam into their stops (server: 0.5 s pause + 1.6 s bounce tween): dust shakes loose
		if host.Parent then
			jet:Emit(math.floor(10 * q) + 2)
			ring(p + Vector3.new(0, 0.6, 0), Color3.fromRGB(230, 214, 186), 8, 40, 0.6)
		end
	end)
end

-- ignition hold: smoke pours out of the silo mouth and rolls along the ground, the pit glows and flickers
local function missileIgnite(p: Vector3, hold: number)
	local q = quality()
	local host = anchorPart(p + Vector3.new(0, 1, 0))
	Debris:AddItem(host, hold + 8)
	local billow = emitter(host, {
		Lifetime = NumberRange.new(3, 5),
		Speed = NumberRange.new(10, 22),
		SpreadAngle = Vector2.new(70, 70),
		EmissionDirection = Enum.NormalId.Top,
		Drag = 3,
		LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-30, 30),
		Size = NS({ 0, 8, 1, 28 }),
		Transparency = DENSE,
		Color = EXHAUST,
	})
	billow:Emit(math.floor(16 * q) + 4)
	billow.Rate = 50 * q
	local rolls = sideRing(p + Vector3.new(0, 0.8, 0), if q < 0.6 then 5 else 8, 5, {
		Lifetime = NumberRange.new(3, 4.5),
		Speed = NumberRange.new(22, 36),
		SpreadAngle = Vector2.new(18, 6),
		EmissionDirection = Enum.NormalId.Front,
		Drag = 3,
		LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-30, 30),
		Size = NS({ 0, 6, 1, 22 }),
		Transparency = DENSE,
		Color = EXHAUST,
	}, math.floor(4 * q) + 1, hold + 8)
	for _, e in rolls do
		e.Rate = 7 * q
	end
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 150, 70)
	glow.Range = 40
	glow.Brightness = 0
	glow.Shadows = false
	glow.Parent = host
	shake(0.7, hold, p)
	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		local tau = os.clock() - t0
		if tau > hold + 0.3 or not host.Parent then
			conn:Disconnect()
			billow.Rate = 0
			for _, e in rolls do
				e.Rate = 0
			end
			glow.Enabled = false
			return
		end
		glow.Brightness = (1.5 + 3.5 * tau / hold) * (0.7 + 0.3 * math.random())
	end)
end

local function missileLaunch(data: any)
	local q = quality()
	local p: Vector3 = data.p
	local mouth: Vector3 = data.mouth or (p + Vector3.new(0, 2, 0))
	local top: Vector3 = data.top or (p + Vector3.new(0, 14, 0))
	local rise: number = data.rise or 900
	local T: number = data.t or 9
	local dir: Vector3 = if typeof(data.dir) == "Vector3" and data.dir.Magnitude > 0.01 then data.dir.Unit else Vector3.yAxis
	local tail: number = data.tail or 8
	local flat = Vector3.new(dir.X, 0, dir.Z)
	local arcDir = if flat.Magnitude > 0.01 then flat.Unit else Vector3.xAxis
	local m: BasePart? = if typeof(data.m) == "Instance" and data.m:IsA("BasePart") then data.m else nil
	local rot0 = if m then m.CFrame.Rotation else CFrame.new()
	local dist = distanceToCamera(mouth)

	-- 1. ignition flash + shock rings + the boom everybody on the map hears
	play3D("MissileLaunch", mouth)
	boom("ExplosionHuge", mouth, 0.9)
	shake(math.clamp(3.4 - dist / 260, 0.5, 3.2), 3.5, mouth)
	if dist < 320 then
		flash(Color3.fromRGB(255, 228, 184), 0.45, 0.6)
	end
	local fb = anchorPart(mouth, Vector3.new(6, 6, 6))
	fb.Shape = Enum.PartType.Ball
	fb.Material = Enum.Material.Neon
	fb.Color = Color3.fromRGB(255, 236, 196)
	fb.Transparency = 0.05
	TweenService:Create(fb, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(44, 44, 44), Transparency = 1 }):Play()
	Debris:AddItem(fb, 0.8)
	ring(p + Vector3.new(0, 1, 0), Color3.fromRGB(255, 214, 160), 14, 210, 1.5)
	task.delay(0.2, function()
		ring(p + Vector3.new(0, 1, 0), Color3.fromRGB(255, 160, 90), 10, 130, 1.1)
	end)

	-- 2. ground dust ring rolling outward
	local dustRing = sideRing(mouth + Vector3.new(0, -0.5, 0), if q < 0.6 then 6 else 10, 6, {
		Lifetime = NumberRange.new(4, 6.5),
		Speed = NumberRange.new(55, 85),
		SpreadAngle = Vector2.new(16, 4),
		EmissionDirection = Enum.NormalId.Front,
		Drag = 2.4,
		LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-40, 40),
		Acceleration = Vector3.new(0, 2.5, 0),
		Size = NS({ 0, 8, 1, 34 }),
		Transparency = NS({ 0, 0.2, 0.55, 0.5, 1, 1 }),
		Color = ColorSequence.new(Color3.fromRGB(214, 190, 152), Color3.fromRGB(150, 132, 112)),
	}, math.floor(7 * q) + 2, 10)
	for _, e in dustRing do
		e.Rate = 10 * q
	end
	task.delay(2.2, function()
		for _, e in dustRing do
			e.Enabled = false
		end
	end)

	-- 3. thick white-grey base column: billows that linger for ~12 s and lean over with the wind
	local base = anchorPart(mouth + Vector3.new(0, 2, 0))
	Debris:AddItem(base, 18)
	local column = emitter(base, {
		Lifetime = NumberRange.new(9, 13),
		Speed = NumberRange.new(10, 24),
		SpreadAngle = Vector2.new(40, 40),
		EmissionDirection = Enum.NormalId.Top,
		Drag = 1.2,
		LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-15, 15),
		Acceleration = Vector3.new(3.5, 1.2, 1.8),
		Size = NS({ 0, 12, 0.4, 34, 1, 62 }),
		Transparency = NS({ 0, 0.05, 0.5, 0.35, 1, 1 }),
		Color = EXHAUST,
	})
	column:Emit(math.floor(20 * q) + 5)
	column.Rate = 26 * q
	task.delay(3.5, function()
		column.Rate = 0
	end)
	local baseFire = emitter(base, {
		Texture = FIRE,
		Lifetime = NumberRange.new(0.6, 1.2),
		Speed = NumberRange.new(20, 45),
		SpreadAngle = Vector2.new(65, 65),
		EmissionDirection = Enum.NormalId.Top,
		LightEmission = 1,
		LightInfluence = 0,
		Size = NS({ 0, 16, 1, 4 }),
		Transparency = NS({ 0, 0, 1, 1 }),
		Color = ColorSequence.new(Color3.fromRGB(255, 236, 160), Color3.fromRGB(255, 90, 30)),
	})
	for k = 1, 6 do
		task.delay(k * 0.15, function()
			baseFire:Emit(math.floor(8 * q) + 2)
		end)
	end
	local baseLight = Instance.new("PointLight")
	baseLight.Color = Color3.fromRGB(255, 160, 80)
	baseLight.Range = 110
	baseLight.Brightness = 9
	baseLight.Shadows = false
	baseLight.Parent = base
	TweenService:Create(baseLight, TweenInfo.new(4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0 }):Play()

	-- 4. tail rig: flame, exhaust column (left in the air, drifting), bright trail, screen-space flare for the far streak
	local rig = anchorPart(top - dir * tail)
	rig.CFrame = CFrame.lookAt(rig.Position, rig.Position - dir) -- Front = exhaust direction
	local fire = emitter(rig, {
		Texture = FIRE,
		Rate = 110 * math.max(q, 0.6),
		Lifetime = NumberRange.new(0.22, 0.4),
		Speed = NumberRange.new(45, 70),
		SpreadAngle = Vector2.new(7, 7),
		EmissionDirection = Enum.NormalId.Front,
		LightEmission = 1,
		LightInfluence = 0,
		Size = NS({ 0, 7, 1, 2.5 }),
		Transparency = NS({ 0, 0, 1, 1 }),
		Color = ColorSequence.new(Color3.fromRGB(255, 246, 220), Color3.fromRGB(255, 120, 40)),
	})
	local smokeCol = emitter(rig, {
		Rate = 30 * q,
		Lifetime = NumberRange.new(10, 14),
		Speed = NumberRange.new(3, 8),
		SpreadAngle = Vector2.new(18, 18),
		EmissionDirection = Enum.NormalId.Front,
		Drag = 0.8,
		LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-12, 12),
		Acceleration = Vector3.new(3.5, 0.8, 1.8),
		Size = NS({ 0, 6, 0.3, 22, 1, 52 }),
		Transparency = NS({ 0, 0.08, 0.55, 0.45, 1, 1 }),
		Color = EXHAUST,
	})
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(1.8, 0, 0)
	a0.Parent = rig
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(-1.8, 0, 0)
	a1.Parent = rig
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.FaceCamera = true
	trail.Lifetime = 1.4
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.MinLength = 0.2
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 250, 236), Color3.fromRGB(255, 150, 60))
	trail.Transparency = NS({ 0, 0.05, 1, 1 })
	trail.WidthScale = NS({ 0, 1, 1, 0.2 })
	trail.Parent = rig
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(40, 40)
	bb.LightInfluence = 0
	bb.AlwaysOnTop = false
	bb.MaxDistance = 100000
	bb.Parent = rig
	local halo = Instance.new("Frame")
	halo.AnchorPoint = Vector2.new(0.5, 0.5)
	halo.Position = UDim2.fromScale(0.5, 0.5)
	halo.Size = UDim2.fromScale(1, 1)
	halo.BackgroundColor3 = Color3.fromRGB(255, 184, 104)
	halo.BackgroundTransparency = 1
	halo.BorderSizePixel = 0
	halo.Parent = bb
	Instance.new("UICorner", halo).CornerRadius = UDim.new(1, 0)
	local core = halo:Clone()
	core.Size = UDim2.fromScale(0.42, 0.42)
	core.BackgroundColor3 = Color3.fromRGB(255, 252, 240)
	core.Parent = bb
	local flameLight = Instance.new("PointLight")
	flameLight.Color = Color3.fromRGB(255, 170, 90)
	flameLight.Range = 70
	flameLight.Brightness = 8
	flameLight.Shadows = false
	flameLight.Parent = rig

	-- 5. fly (the replicated missile root is moved locally; the server leaves it in the silo)
	local t0 = os.clock()
	local rumbled = false
	local unbind: () -> ()
	unbind = bindStep("Missile", function()
		local tau = os.clock() - t0
		local a = math.clamp(tau / T, 0, 1)
		local pos, v = missilePath(top, dir, arcDir, rise, a)
		if m and m.Parent then
			local axis = Vector3.yAxis:Cross(v)
			local lean = if axis.Magnitude > 1e-4 then CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(v.Y, -1, 1))) else CFrame.new()
			m.CFrame = CFrame.new(pos) * lean * rot0
		end
		if rig.Parent then
			local tp = pos - v * tail
			rig.CFrame = CFrame.lookAt(tp, tp - v)
		end
		flameLight.Brightness = 8 * (1 - a * 0.7)
		-- the far flare fades in as the missile climbs out of the plume (a bright star high in the sky)
		local far = smooth((a - 0.08) / 0.25)
		halo.BackgroundTransparency = 1 - 0.5 * far
		core.BackgroundTransparency = 1 - far * (0.85 + 0.15 * math.random())
		if tau > 2.5 and not rumbled then
			rumbled = true
			shake(math.clamp(1.4 - dist / 500, 0.2, 1.2), 3, mouth)
		end
		if tau >= T or not rig.Parent then
			unbind()
			fire.Rate = 0
			smokeCol.Rate = 0
			trail.Enabled = false
			flameLight.Enabled = false
			bb.Enabled = false
			Debris:AddItem(rig, 15) -- the exhaust column stays up and drifts for its full lifetime
		end
	end)
end

local function onMissile(data: any)
	if type(data) ~= "table" or typeof(data.p) ~= "Vector3" then
		return
	end
	local phase = data.phase or "launch"
	if phase == "doors" then
		missileDoors(data.p, data.t or 1.6)
	elseif phase == "ignite" then
		missileIgnite(data.p, data.t or 1.5)
	else
		missileLaunch(data)
	end
end

-- ---------------------------------------------------------------- Skiff
-- Takeoff flight path. MUST stay identical to skiffPath in server/Objectives/Extraction.luau (the server snaps the Skiff to the
-- end pose; every client flies the replicated Skiff locally along this curve, in sync with the engine Fx and the camera).
-- rise PATH_HOVER studs while yawing from the pad heading onto the flight heading, then accelerate along `fly` and climb, nose up.
local PATH_HOVER, PATH_DIST, PATH_CLIMB, PATH_RISE = 16, 340, 190, 0.32
local function skiffPath(landed: Vector3, rot: CFrame, fly: Vector3, T: number, tau: number): CFrame
	local flyRot = CFrame.lookAt(Vector3.zero, fly)
	local riseT = T * PATH_RISE
	if tau <= riseT then
		local u = math.clamp(tau / riseT, 0, 1)
		local e = u * u * (3 - 2 * u)
		return CFrame.new(landed + Vector3.new(0, PATH_HOVER * e, 0)) * rot:Lerp(flyRot, e)
	end
	local u = math.clamp((tau - riseT) / (T - riseT), 0, 1)
	local e = u * u
	local pos = landed + Vector3.new(0, PATH_HOVER, 0) + fly * PATH_DIST * e + Vector3.new(0, PATH_CLIMB * e, 0)
	return CFrame.new(pos) * flyRot * CFrame.Angles(math.rad(14) * math.min(1, u * 3), 0, 0)
end

local StoreMod: any = nil
local function missionState(): string?
	if not StoreMod then
		local ok, mod = pcall(function()
			return require(script.Parent.Parent.Store)
		end)
		if not ok then
			return nil
		end
		StoreMod = mod
	end
	local m = StoreMod.get("mission")
	return if type(m) == "table" then m.state else nil
end

local cinematicActive = false

-- Boarded players only. Timeline (tc = seconds since the "leave" Fx; liftoff at tc = pre):
--   0 .. pre+0.4   low shot beside the ramp as it closes, letterbox slides in, engines spool
--   .. pre+3.6     crane: the camera sweeps back and up while the Skiff rises and yaws onto its heading
--   .. pre+T       wide climb-out toward the hazy sun, tracking zoom FOV 66 -> 46, battle still raging below
--   last 1.1 s     fade to black ("EXTRACTION COMPLETE"), hold until the mission state is Results (max 4 s)
--   Results        slow drift over the battlefield behind the rewards panel; HUD back on
--   Ship           (Boarded cleared / state changes / new character) -> camera override released, GUI removed
-- Every exit path goes through finish(): override cleared (CameraController resumes: Scriptable rig + its own FOV), hidden
-- ScreenGuis re-enabled, letterbox/fade GUI destroyed.
local function playTakeoffCinematic(landed: Vector3, rot: CFrame, fly: Vector3, T: number, pre: number)
	if cinematicActive then
		return
	end
	if not CamApi then
		local ok, mod = pcall(function()
			return require(script.Parent.Parent.CameraController)
		end)
		if not ok then
			return
		end
		CamApi = mod
	end
	local pg = localPlayer:FindFirstChildOfClass("PlayerGui")
	local char = localPlayer.Character
	if not pg or not char or not CamApi.setOverride then
		return
	end
	cinematicActive = true

	-- hide the HUD for the shot (restored when the Results backdrop starts, or on any exit)
	local hidden: { ScreenGui } = {}
	for _, g in pg:GetChildren() do
		if g:IsA("ScreenGui") and g.Enabled then
			table.insert(hidden, g)
			g.Enabled = false
		end
	end
	local function restoreGuis()
		for _, g in hidden do
			if g.Parent and not g.Enabled then
				g.Enabled = true
			end
		end
		table.clear(hidden)
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkiffCinematic"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 500
	sg.Parent = pg
	local bars: { Frame } = {}
	for _, anchorY in { 0, 1 } do
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0, anchorY)
		f.Position = UDim2.fromScale(0, anchorY)
		f.Size = UDim2.fromScale(1, 0)
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BorderSizePixel = 0
		f.Parent = sg
		TweenService:Create(f, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 0.1) }):Play()
		bars[#bars + 1] = f
	end
	local fade = Instance.new("Frame")
	fade.Size = UDim2.fromScale(1, 1)
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 1
	fade.BorderSizePixel = 0
	fade.ZIndex = 10
	fade.Parent = sg
	local title = Instance.new("TextLabel")
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, 0.5)
	title.Size = UDim2.fromScale(0.8, 0.07)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.Michroma
	title.Text = "E X T R A C T I O N   C O M P L E T E"
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(232, 214, 180)
	title.TextTransparency = 1
	title.ZIndex = 11
	title.Parent = sg

	-- camera rig
	local up = Vector3.yAxis
	local fwd = rot.LookVector
	local rear = -fwd
	local padSide = Vector3.new(-fwd.Z, 0, fwd.X)
	local side = Vector3.new(-fly.Z, 0, fly.X)
	local padY = landed.Y - 5
	local camA0 = Vector3.new(landed.X, padY + 1.8, landed.Z) + rear * 23 + padSide * 8 -- low, beside the ramp
	local rampLook = landed + rear * 7 + Vector3.new(0, -1.5, 0)
	local camB0 = landed - fly * 62 + side * 26 + Vector3.new(0, 7, 0) -- behind the climb-out, sun ahead
	local wideFrom = landed + fly * 120 + side * 75 + Vector3.new(0, 72, 0) -- Results backdrop
	local lookPos = rampLook
	local t0 = os.clock()
	local total = pre + T
	local phase = "shot" -- "shot" | "hold" | "results"
	local holdCF = CFrame.lookAt(camA0, rampLook)
	local resultsAt = 0
	local rumbleAt = 0

	CamApi.setOverride(function(dt: number)
		local tc = os.clock() - t0
		if phase == "results" then
			local tr = tc - resultsAt
			local pos = wideFrom - side * (tr * 2.2) + Vector3.new(0, tr * 0.5, 0)
			return CFrame.lookAt(pos, landed - fly * 20 + Vector3.new(0, 4, 0)), 55
		elseif phase == "hold" then
			return holdCF, 46
		end
		local tau = tc - pre
		local cf = skiffPath(landed, rot, fly, T, math.max(tau, 0))
		-- look target slides from the closing ramp to the hull centre as the Skiff lifts
		local s2 = smooth(tau / 2.5)
		local target = (cf * CFrame.new(0, -1.5 * (1 - s2), 7 * (1 - s2))).Position
		lookPos = lookPos:Lerp(target, 1 - math.exp(-6 * math.min(dt, 0.1)))
		-- crane from the low ramp shot to the wide chase position (with a little lift in the middle of the move)
		local s = smooth((tc - (pre + 0.4)) / 3.2)
		local camA = camA0 + (rampLook - camA0).Unit * math.min(tc, 4) * 0.8
		local camB = camB0 - fly * (math.max(tau, 0) * 3) + up * (math.max(tau, 0) * 1.4)
		local pos = camA:Lerp(camB, s) + up * (math.sin(s * math.pi) * 8)
		local fov = 66 - 20 * smooth((tau - 1) / (T - 1.5))
		-- engine rumble while the Skiff is still close
		if tau > 0 and tau < 3.5 and tc >= rumbleAt then
			rumbleAt = tc + 0.6
			shake(0.35 * (1 - tau / 3.5) + 0.1, 0.7)
		end
		local out = CFrame.lookAt(pos, lookPos)
		if tc >= total then
			phase = "hold"
			holdCF = out
		end
		return out, fov
	end)
	task.delay(pre, function()
		if cinematicActive then
			shake(1.2, 1.3) -- liftoff
		end
	end)

	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		if CamApi and CamApi.setOverride then
			CamApi.setOverride(nil)
		end
		restoreGuis()
		if sg.Parent and fade.BackgroundTransparency < 0.99 then
			TweenService:Create(fade, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
			TweenService:Create(title, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
			task.delay(0.5, function()
				sg:Destroy()
			end)
		else
			sg:Destroy()
		end
		cinematicActive = false
	end
	-- the squad is going home (Extraction.stop cleared Boarded / back on the ship / respawned): give the camera back
	local function aborted(): boolean
		if localPlayer.Character ~= char or not char.Parent then
			return true
		end
		if char:GetAttribute("Boarded") ~= true then
			return true
		end
		local st = missionState()
		return st ~= nil and st ~= "Extract" and st ~= "Results" and st ~= "Failed"
	end

	task.spawn(function()
		local ok, err = pcall(function()
			while not finished and os.clock() - t0 < total - 1.1 do
				if aborted() then
					return
				end
				task.wait(0.1)
			end
			if finished then
				return
			end
			TweenService:Create(fade, TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { BackgroundTransparency = 0 }):Play()
			task.delay(0.7, function()
				if not finished then
					TweenService:Create(title, TweenInfo.new(0.8), { TextTransparency = 0.1 }):Play()
				end
			end)
			-- hold black until the server reports Results (onDone fires right as the flight ends), max 4 s
			local deadline = t0 + total + 4
			while not finished and os.clock() < deadline do
				local st = missionState()
				if os.clock() - t0 >= total + 0.6 and (st == "Results" or st == "Failed") then
					break
				end
				if aborted() then
					return
				end
				task.wait(0.1)
			end
			local st = missionState()
			if finished or (st ~= "Results" and st ~= "Failed") then
				return
			end
			-- Results backdrop: HUD (rewards panel) back on, letterbox out, fade in on a slow drift over the battlefield
			phase = "results"
			resultsAt = os.clock() - t0
			restoreGuis()
			for _, b in bars do
				TweenService:Create(b, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = UDim2.fromScale(1, 0) }):Play()
			end
			TweenService:Create(title, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
			TweenService:Create(fade, TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
			-- keep the backdrop until the squad is sent back to the ship
			local cap = os.clock() + 45
			while not finished and os.clock() < cap and not aborted() do
				task.wait(0.1)
			end
		end)
		if not ok then
			warn("[WorldFx] takeoff cinematic failed:", err)
		end
		finish()
	end)
end

-- cinematic flair: the war goes on below the climbing Skiff (cosmetic explosions + upward tracer fire in front of the camera)
local function battleBelow(landed: Vector3, fly: Vector3, T: number, pre: number)
	if not FxApi or type(FxApi.explosion) ~= "function" then
		return
	end
	local q = quality()
	local rnd = Random.new()
	local side = Vector3.new(-fly.Z, 0, fly.X)
	task.spawn(function()
		task.wait(pre + 1.4)
		local stopAt = os.clock() + T - 1.8
		while os.clock() < stopAt and cinematicActive do
			local guess = landed + fly * rnd:NextNumber(40, 170) + side * rnd:NextNumber(-95, 95)
			local g = groundAt(guess)
			if g then
				pcall(FxApi.explosion, g, { size = if rnd:NextNumber() < 0.35 then "L" else "M", style = "fire", noShake = true, silent = rnd:NextNumber() < 0.5 })
				if type(FxApi.tracer) == "function" and q >= 0.5 then
					for _ = 1, rnd:NextInteger(1, 3) do
						local a = g + side * rnd:NextNumber(-25, 25) + fly * rnd:NextNumber(-20, 20) + Vector3.new(0, 2, 0)
						local d = (Vector3.new(rnd:NextNumber(-0.4, 0.4), 1, rnd:NextNumber(-0.4, 0.4))).Unit
						local c = if rnd:NextNumber() < 0.5 then Color3.fromRGB(255, 196, 120) else Color3.fromRGB(255, 92, 70)
						pcall(FxApi.tracer, a, a + d * rnd:NextNumber(90, 160), c, 0.2)
					end
				end
			end
			task.wait(rnd:NextNumber(0.55, 1.0) / math.max(q, 0.5))
		end
	end)
end

-- Takeoff show (phase "leave", every client): the ramp closes for `pre` s while the engines spool, then the replicated Skiff is
-- flown locally along skiffPath with blue-white engine flames, heat-shimmer, warm engine lights and pad dust that dies off with
-- altitude. Boarded players (character attribute Boarded) also get the takeoff cinematic.
local function leaveShow(data: any, p: Vector3, ground: Vector3, T: number, pre: number)
	local flat = Vector3.new(-p.X, 0, -p.Z)
	local inward: Vector3 = if typeof(data.inward) == "Vector3" then data.inward elseif flat.Magnitude > 1 then flat.Unit else Vector3.new(0, 0, -1)
	local fly: Vector3 = if typeof(data.fly) == "Vector3" and data.fly.Magnitude > 0.1 then data.fly.Unit else inward
	local rot = CFrame.lookAt(Vector3.zero, inward)
	local q = quality()

	-- the replicated Skiff (moved locally from liftoff on; the server leaves it on the pad until the end)
	local model: Instance? = if typeof(data.m) == "Instance" then data.m else nil
	local root: BasePart? = if typeof(data.root) == "Instance" and data.root:IsA("BasePart") then data.root else nil
	if not root then
		local f = Workspace:FindFirstChild("ExtractionObjects")
		local mdl = model or (f and f:FindFirstChild(Config.ShuttleName))
		local r = mdl and mdl:FindFirstChild("Root")
		if r and r:IsA("BasePart") then
			root = r
			model = mdl
		end
	end

	-- engine nozzle offsets in Skiff space (mesh parts Engine_L/R, pushed toward their rear; fallback = mesh pivots)
	local base = CFrame.new(p) * rot
	local offs: { Vector3 } = {}
	if model then
		for _, n in { "Engine_L", "Engine_R" } do
			local e = model:FindFirstChild(n, true)
			if e and e:IsA("BasePart") then
				offs[#offs + 1] = base:PointToObjectSpace(e.Position) + Vector3.new(0, -0.6, math.max(e.Size.X, e.Size.Z) * 0.35)
			end
		end
	end
	if #offs < 2 then
		offs = { Vector3.new(-4.4, -2.2, 5.8), Vector3.new(4.4, -2.2, 5.8) }
	end

	local rigs: { { part: Part, off: Vector3, rear: ParticleEmitter, down: ParticleEmitter, haze: ParticleEmitter, light: PointLight } } = {}
	local flameColor = ColorSequence.new(Color3.fromRGB(244, 250, 255), Color3.fromRGB(96, 164, 255))
	local flameTrans = NS({ 0, 0, 0.7, 0.35, 1, 1 })
	for _, off in offs do
		local part = anchorPart(p)
		part.CFrame = base * CFrame.new(off)
		local rear = emitter(part, {
			Texture = FIRE, Lifetime = NumberRange.new(0.2, 0.35), Speed = NumberRange.new(28, 42), SpreadAngle = Vector2.new(5, 5),
			EmissionDirection = Enum.NormalId.Back, LightEmission = 1, LightInfluence = 0, Color = flameColor, Transparency = flameTrans,
			Size = NS({ 0, 3.4, 1, 0.5 }),
		})
		local down = emitter(part, {
			Texture = FIRE, Lifetime = NumberRange.new(0.25, 0.42), Speed = NumberRange.new(18, 28), SpreadAngle = Vector2.new(8, 8),
			EmissionDirection = Enum.NormalId.Bottom, LightEmission = 1, LightInfluence = 0, Color = flameColor, Transparency = flameTrans,
			Size = NS({ 0, 3.6, 1, 0.8 }),
		})
		-- heat haze stand-in: big, faint, warm-white shimmer under the nozzles
		local haze = emitter(part, {
			Lifetime = NumberRange.new(0.6, 1.0), Speed = NumberRange.new(8, 14), SpreadAngle = Vector2.new(14, 14),
			EmissionDirection = Enum.NormalId.Bottom, LightEmission = 0.25, LightInfluence = 0.3,
			Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-90, 90),
			Size = NS({ 0, 4, 1, 12 }), Transparency = NS({ 0, 0.86, 0.5, 0.9, 1, 1 }),
			Color = ColorSequence.new(Color3.fromRGB(255, 244, 228)),
		})
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 226, 196) -- warm-white: the flames are blue, the light on the sand is not
		light.Range = 32
		light.Brightness = 0
		light.Shadows = false
		light.Parent = part
		table.insert(rigs, { part = part, off = off, rear = rear, down = down, haze = haze, light = light })
	end

	-- pad dust: ground-hugging ring thrown outward by the down-thrust
	local ringE = sideRing(ground + Vector3.new(0, 1.2, 0), if q < 0.6 then 5 else 8, 7, {
		Lifetime = NumberRange.new(2.5, 3.8),
		Speed = NumberRange.new(28, 44),
		SpreadAngle = Vector2.new(22, 5),
		EmissionDirection = Enum.NormalId.Front,
		Drag = 3,
		LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-40, 40),
		Size = NS({ 0, 5, 1, 20 }),
		Transparency = NS({ 0, 0.25, 0.6, 0.55, 1, 1 }),
		Color = ColorSequence.new(Color3.fromRGB(222, 198, 156), Color3.fromRGB(170, 148, 116)),
	}, 0, pre + T + 6)

	local boarded = localPlayer.Character ~= nil and localPlayer.Character:GetAttribute("Boarded") == true
	if boarded then
		playTakeoffCinematic(p, rot, fly, T, pre)
		battleBelow(p, fly, T, pre)
	end

	local t0 = os.clock()
	local burst = false
	local unbind: () -> ()
	unbind = bindStep("Skiff", function()
		local tc = os.clock() - t0
		local tau = tc - pre
		local cf = skiffPath(p, rot, fly, T, math.max(tau, 0))
		-- also during the ramp close (pose = the pad pose): re-seats a hull that drifted locally while a boarded player turned
		if root and root.Parent then
			root.CFrame = cf
		end
		if tau >= 0 and not burst then
			burst = true
			for _, e in ringE do
				e:Emit(math.max(2, math.floor(8 * q)))
			end
		end
		-- spool: idle flicker while the ramp closes, full thrust at liftoff, fading as it leaves
		local spool = if tau < 0 then 0.2 + 0.3 * smooth(tc / math.max(pre, 0.01)) else 1
		local k = spool * math.clamp((T - tau) / 1.2, 0, 1)
		local climbing = tau > T * PATH_RISE
		for _, r in rigs do
			r.part.CFrame = cf * CFrame.new(r.off)
			r.rear.Rate = (if climbing then 110 else 40) * q * k
			r.down.Rate = (if tau < T * 0.45 then 80 else 10) * q * k
			r.haze.Rate = (if tau < T * 0.5 then 20 else 5) * q * k
			r.light.Brightness = 3 * k
		end
		local height = cf.Position.Y - p.Y
		local dustK = if tau < 0 then 0.12 * spool else math.clamp(1 - height / 45, 0, 1)
		for _, e in ringE do
			e.Rate = 22 * q * dustK
		end
		if tau >= T + 0.2 then
			unbind()
			for _, r in rigs do
				r.rear.Enabled = false
				r.down.Enabled = false
				r.haze.Enabled = false
				r.light.Enabled = false
				Debris:AddItem(r.part, 2)
			end
			for _, e in ringE do
				e.Enabled = false
			end
		end
	end)
end

local function downwash(p: Vector3, t: number, phase: string)
	local ground = p - Vector3.new(0, 5, 0)
	local dist = distanceToCamera(p)
	local q = quality()
	play3D("SkiffEngine", p)

	local base = anchorPart(ground + Vector3.new(0, 1, 0))
	local dust = emitter(base, {
		Lifetime = NumberRange.new(2.5, 4.5),
		Speed = NumberRange.new(30, 60),
		SpreadAngle = Vector2.new(88, 88),
		EmissionDirection = Enum.NormalId.Top,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 6), NumberSequenceKeypoint.new(1, 22) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) }),
		Color = ColorSequence.new(Color3.fromRGB(214, 184, 146), Color3.fromRGB(140, 120, 104)),
		Drag = 3,
		RotSpeed = NumberRange.new(-60, 60),
	})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 190, 110)
	light.Range = 70
	light.Brightness = 0
	light.Parent = base

	local dur = if phase == "land" then t + 2.5 else t
	local t0 = os.clock()
	local lastShake = -1
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		local tau = os.clock() - t0
		if tau >= dur or not base.Parent then
			conn:Disconnect()
			dust.Rate = 0
			Debris:AddItem(base, 6)
			return
		end
		local k: number
		if phase == "land" then
			-- downwash grows as the Skiff gets closer, then settles
			k = if tau < t then math.clamp((tau / t) ^ 2.2, 0, 1) else math.max(0, 1 - (tau - t) / 2.5)
		else
			k = math.clamp(1 - tau / 3.5, 0, 1) ^ 0.7 -- blast at liftoff, gone once the Skiff is high above the pad
		end
		dust.Rate = 130 * q * k
		light.Brightness = 3.5 * k
		if tau - lastShake >= 0.8 then
			lastShake = tau
			shake(math.clamp(0.7 - dist / 600, 0.05, 0.6) * k, 0.8, p)
		end
	end)
	if phase == "land" then
		task.delay(t, function()
			dust:Emit(math.floor(50 * q) + 10)
			ring(ground + Vector3.new(0, 0.6, 0), Color3.fromRGB(255, 200, 130), 10, 80, 0.9)
		end)
	else
		dust:Emit(math.floor(60 * q) + 10)
		ring(ground + Vector3.new(0, 0.6, 0), Color3.fromRGB(255, 200, 130), 10, 90, 1)
	end
end

local function onSkiff(data: any)
	if type(data) ~= "table" or typeof(data.p) ~= "Vector3" then
		return
	end
	local p: Vector3 = data.p
	local t: number = data.t or 6
	local phase: string = data.phase or "land"
	if phase == "land" then
		downwash(p, t, phase)
		return
	end
	-- leave: the ramp closes for `pre` s, then the blast; the show (and the cinematic) starts right away
	local pre: number = math.max(data.pre or 0, 0)
	task.delay(pre, downwash, p, t, phase)
	local ok, err = pcall(leaveShow, data, p, p - Vector3.new(0, 5, 0), t, pre)
	if not ok then
		warn("[WorldFx] Skiff leave show failed:", err)
	end
end

-- ---------------------------------------------------------------- Trajectory mini-game
local activeClose: (() -> ())? = nil

local DIAL_NAMES = { "ELEVATION", "AZIMUTH", "THRUST" }
local DIAL_AMP = 85

local function make(class: string, props: { [string]: any }, parent: Instance?): any
	local i = Instance.new(class)
	for k, v in props do
		i[k] = v
	end
	if parent then
		i.Parent = parent
	end
	return i
end

local function openTrajectory(data: any)
	if activeClose then
		activeClose()
	end
	local pg = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local bands: { { c: number, h: number } } = data.bands or { { c = 0, h = 14 }, { c = 20, h = 12 }, { c = -20, h = 10 } }
	local speeds: { number } = data.speeds or { 1.5, 2.0, 2.6 }
	local objId: string = data.obj or "MISSILE"
	local timeout: number = data.timeout or 90
	local consolePos: Vector3? = data.pos

	local gui = make("ScreenGui", { Name = "TrajectoryMinigame", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 60, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, pg)
	make("Frame", { Name = "Dim", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.5, BorderSizePixel = 0, Active = true }, gui)
	local canvas = make("Frame", {
		Name = "Canvas",
		Size = UDim2.fromOffset(720, 440),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = Config.Colors.Panel,
		BorderSizePixel = 0,
	}, gui)
	make("UICorner", { CornerRadius = UDim.new(0, 14) }, canvas)
	make("UIStroke", { Color = Config.Colors.Accent, Thickness = 3 }, canvas)
	local uiScale = make("UIScale", {}, canvas)

	local conns: { RBXScriptConnection } = {}
	local function fit()
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		uiScale.Scale = math.clamp(math.min(vp.X / 760, vp.Y / 480), 0.45, 1.3)
	end
	fit()
	local cam = Workspace.CurrentCamera
	if cam then
		conns[#conns + 1] = cam:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end

	make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(700, 36), Position = UDim2.fromOffset(10, 12), Font = Enum.Font.Michroma, Text = "SET TRAJECTORY", TextColor3 = Config.Colors.Accent, TextSize = 26 }, canvas)
	make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(700, 22), Position = UDim2.fromOffset(10, 50), Font = Enum.Font.GothamBold, Text = "Lock each needle inside the green band  -  press E / tap LOCK", TextColor3 = Config.Colors.Muted, TextSize = 16 }, canvas)

	local R = 96
	local L = 84
	local needles: { Frame } = {}
	local lamps: { Frame } = {}
	local ticksByDial: { { Frame } } = {}
	local phases = { 0, 1.7, 3.1 }
	for i = 1, 3 do
		local cx, cy = 120 + (i - 1) * 240, 235
		local b = bands[i]
		local dialTicks: { Frame } = {}
		for a = -90, 90, 6 do
			local inBand = math.abs(a - b.c) <= b.h
			local major = a % 30 == 0
			local len = if inBand then 20 else (if major then 16 else 9)
			local r = R - len / 2 + 4
			local rad = math.rad(a)
			local tick = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(if inBand then 5 else 3, len),
				Position = UDim2.fromOffset(cx + r * math.sin(rad), cy - r * math.cos(rad)),
				Rotation = a,
				BackgroundColor3 = if inBand then Color3.fromRGB(70, 255, 130) else Config.Colors.Muted,
				BorderSizePixel = 0,
			}, canvas)
			dialTicks[#dialTicks + 1] = tick
		end
		ticksByDial[i] = dialTicks
		-- needle (container rotates around the pivot at its centre)
		local holder = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(L * 2, L * 2), Position = UDim2.fromOffset(cx, cy), BackgroundTransparency = 1 }, canvas)
		make("Frame", { AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(4, L), Position = UDim2.fromScale(0.5, 0), BackgroundColor3 = Config.Colors.Danger, BorderSizePixel = 0 }, holder)
		needles[i] = holder
		local hub = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(cx, cy), BackgroundColor3 = Config.Colors.Text, BorderSizePixel = 0 }, canvas)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, hub)
		make("TextLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(200, 22), Position = UDim2.fromOffset(cx, cy + 22), Font = Enum.Font.GothamBold, Text = DIAL_NAMES[i], TextColor3 = Config.Colors.Text, TextSize = 16 }, canvas)
		local lamp = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(20, 20), Position = UDim2.fromOffset(cx, cy - R - 24), BackgroundColor3 = Color3.fromRGB(70, 74, 86), BorderSizePixel = 0 }, canvas)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, lamp)
		lamps[i] = lamp
	end

	local msg = make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(700, 26), Position = UDim2.fromOffset(10, 402), Font = Enum.Font.GothamBold, Text = "", TextColor3 = Config.Colors.Gold, TextSize = 20 }, canvas)
	local lockBtn = make("TextButton", {
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(300, 66),
		Position = UDim2.fromOffset(360, 320),
		BackgroundColor3 = Config.Colors.Accent,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBlack,
		Text = "LOCK  [E]",
		TextColor3 = Color3.fromRGB(20, 20, 26),
		TextSize = 30,
		AutoButtonColor = true,
	}, canvas)
	make("UICorner", { CornerRadius = UDim.new(0, 12) }, lockBtn)
	local cancelBtn = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(96, 34),
		Position = UDim2.fromOffset(710, 10),
		BackgroundColor3 = Color3.fromRGB(50, 58, 74),
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = "CANCEL",
		TextColor3 = Config.Colors.Text,
		TextSize = 16,
	}, canvas)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, cancelBtn)

	-- logic
	local t0 = os.clock()
	local locks: { number } = {}
	local nextDial = 1
	local busy = false
	local closed = false
	local completed = false
	local angles = { 0, 0, 0 }

	local function close()
		if closed then
			return
		end
		closed = true
		activeClose = nil
		ContextActionService:UnbindAction("WorldFxLock")
		ContextActionService:UnbindAction("WorldFxCancel")
		for _, c in conns do
			c:Disconnect()
		end
		if not completed then
			Net.event("Action"):FireServer("minigame", objId, { cancel = true })
		end
		gui:Destroy()
		pcall(function()
			require(script.Parent.Parent.Store).set("menuOpen", nil)
		end)
	end
	activeClose = close
	-- free the mouse (camera respects menuOpen) so LOCK / CANCEL can be clicked
	pcall(function()
		require(script.Parent.Parent.Store).set("menuOpen", true)
	end)

	local function resetDials()
		for i = 1, 3 do
			lamps[i].BackgroundColor3 = Color3.fromRGB(70, 74, 86)
		end
		table.clear(locks)
		nextDial = 1
		t0 = os.clock()
	end

	local function lock()
		if busy or closed then
			return
		end
		local i = nextDial
		local a = angles[i]
		locks[i] = a
		local b = bands[i]
		local off = math.abs(a - b.c)
		if off <= b.h then
			lamps[i].BackgroundColor3 = Color3.fromRGB(70, 255, 130)
			play2D(if off <= b.h * 0.4 then "DialPerfect" else "DialTick")
			nextDial += 1
			if nextDial > 3 then
				busy = true
				completed = true
				msg.Text = "TRAJECTORY LOCKED"
				msg.TextColor3 = Color3.fromRGB(70, 255, 130)
				Net.event("Action"):FireServer("minigame", objId, { locks = { locks[1], locks[2], locks[3] } })
				task.delay(0.9, close)
			end
		else
			busy = true
			lamps[i].BackgroundColor3 = Config.Colors.Danger
			play2D("UIClick")
			msg.Text = "MISALIGNED - RECALIBRATING"
			msg.TextColor3 = Config.Colors.Danger
			task.delay(0.8, function()
				if closed then
					return
				end
				msg.Text = ""
				resetDials()
				busy = false
			end)
		end
	end

	lockBtn.Activated:Connect(lock)
	cancelBtn.Activated:Connect(close)
	ContextActionService:BindActionAtPriority("WorldFxLock", function(_, state)
		if state == Enum.UserInputState.Begin then
			lock()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.E, Enum.KeyCode.Space, Enum.KeyCode.ButtonA, Enum.KeyCode.ButtonR2)
	ContextActionService:BindActionAtPriority("WorldFxCancel", function(_, state)
		if state == Enum.UserInputState.Begin then
			close()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB)

	local checkT = 0
	conns[#conns + 1] = RunService.RenderStepped:Connect(function(dt)
		if closed then
			return
		end
		local now = os.clock() - t0
		for i = 1, 3 do
			if i >= nextDial then
				angles[i] = DIAL_AMP * math.sin(speeds[i] * now + phases[i])
			else
				angles[i] = locks[i]
			end
			needles[i].Rotation = angles[i]
		end
		checkT += dt
		if checkT > 0.5 then
			checkT = 0
			if os.clock() - t0 > timeout + 5 and not busy then
				close()
				return
			end
			local ch = localPlayer.Character
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
			if consolePos and (not hrp or (hrp.Position - consolePos).Magnitude > 40) then
				close()
			end
		end
	end)
end

-- ---------------------------------------------------------------- distant battle (mission maps only)
-- Far horizon dressing: 5 tall dark smoke columns on a ring (r 300-420) outside the play area, random distant explosion
-- flashes (3 pooled flash parts, round-robin) and an occasional faint tracer arc across the sky (max 3 live bars).
-- Everything lives in one folder that is destroyed as soon as the Map folder goes away. No sounds, no collision.
local HORIZON_COLUMNS = 5
local FLASH_POOL = 3
local TRACER_MAX = 3

local horizon: { folder: Folder, conn: RBXScriptConnection?, alive: boolean }? = nil

local function ringPoint(angle: number, radius: number, y: number): Vector3
	return Vector3.new(math.cos(angle) * radius, y, math.sin(angle) * radius)
end

local function lookAngle(): number
	local cam = Workspace.CurrentCamera
	if cam then
		local lv = cam.CFrame.LookVector
		return math.atan2(lv.Z, lv.X)
	end
	return math.random() * math.pi * 2
end

local function stopHorizon()
	if horizon then
		horizon.alive = false
		if horizon.conn then
			horizon.conn:Disconnect()
		end
		horizon.folder:Destroy()
		horizon = nil
	end
end

local function startHorizon()
	local q = quality()
	local folder = Instance.new("Folder")
	folder.Name = "ClientHorizonFx"
	folder.Parent = Workspace
	local state = { folder = folder, conn = nil :: RBXScriptConnection?, alive = true }
	horizon = state
	local rnd = Random.new(os.time())

	-- smoke columns: tall, dark, slow; a couple sit near the sun so the light shines through them
	local sunAngle = 0
	pcall(function()
		local d = game:GetService("Lighting"):GetSunDirection()
		sunAngle = math.atan2(d.Z, d.X)
	end)
	local count = if q < 0.6 then 3 else HORIZON_COLUMNS
	for i = 1, count do
		local a = (if i <= 2 then sunAngle + (i - 1.5) * 0.7 else (i / count) * math.pi * 2 + sunAngle + 1.2) + rnd:NextNumber(-0.25, 0.25)
		local host = anchorPart(ringPoint(a, rnd:NextNumber(300, 420), rnd:NextNumber(50, 90)))
		host.Parent = folder
		local e = Instance.new("ParticleEmitter")
		e.Texture = SMOKE
		e.Rate = if q < 0.6 then 2 else 3
		e.Lifetime = NumberRange.new(15, 19)
		e.Speed = NumberRange.new(14, 20)
		e.EmissionDirection = Enum.NormalId.Top
		e.SpreadAngle = Vector2.new(5, 5)
		e.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, rnd:NextNumber(30, 40)),
			NumberSequenceKeypoint.new(1, rnd:NextNumber(55, 70)),
		})
		e.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.12, 0.35),
			NumberSequenceKeypoint.new(0.7, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		})
		e.Color = ColorSequence.new(Color3.fromRGB(70, 58, 50), Color3.fromRGB(38, 34, 34))
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-6, 6)
		e.Acceleration = Vector3.new(4, 0, 2) -- steady wind leans the column over
		e.LightInfluence = 0.4
		e.Parent = host
	end

	-- explosion flashes: pooled parts with a PointLight and a small dust emitter
	local flashes: { { part: Part, light: PointLight, dust: ParticleEmitter, tween: Tween? } } = {}
	for i = 1, FLASH_POOL do
		local p = anchorPart(Vector3.new(0, -500, 0), Vector3.new(10, 10, 10))
		p.Shape = Enum.PartType.Ball
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(255, 190, 110)
		p.Transparency = 1
		p.Parent = folder
		local l = Instance.new("PointLight")
		l.Color = Color3.fromRGB(255, 170, 90)
		l.Range = 60
		l.Brightness = 0
		l.Shadows = false
		l.Parent = p
		local dust = Instance.new("ParticleEmitter")
		dust.Texture = SMOKE
		dust.Rate = 0
		dust.Lifetime = NumberRange.new(2.5, 4)
		dust.Speed = NumberRange.new(10, 22)
		dust.SpreadAngle = Vector2.new(60, 60)
		dust.EmissionDirection = Enum.NormalId.Top
		dust.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 14), NumberSequenceKeypoint.new(1, 34) })
		dust.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
		dust.Color = ColorSequence.new(Color3.fromRGB(120, 92, 70), Color3.fromRGB(60, 50, 44))
		dust.Rotation = NumberRange.new(0, 360)
		dust.LightInfluence = 0.5
		dust.Parent = p
		flashes[i] = { part = p, light = l, dust = dust, tween = nil }
	end
	local flashIdx = 0
	local function explode()
		flashIdx = flashIdx % FLASH_POOL + 1
		local f = flashes[flashIdx]
		if f.tween then
			f.tween:Cancel()
		end
		local a = if rnd:NextNumber() < 0.7 then lookAngle() + rnd:NextNumber(-1.3, 1.3) else rnd:NextNumber(0, math.pi * 2)
		local pos = ringPoint(a, rnd:NextNumber(300, 400), rnd:NextNumber(35, 80))
		local d = rnd:NextNumber(14, 26)
		f.part.Size = Vector3.new(d, d, d)
		f.part.Position = pos
		f.part.Transparency = 0.1
		f.light.Brightness = 5
		f.dust:Emit(if q < 0.6 then 4 else 8)
		local tw = TweenService:Create(f.part, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(d * 2.2, d * 2.2, d * 2.2), Transparency = 1 })
		local tl = TweenService:Create(f.light, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0 })
		f.tween = tw
		tw:Play()
		tl:Play()
	end

	-- tracer arcs: short neon bars flying a shallow parabola far away, oriented along their velocity every frame
	local tracers: { { part: Part, from: Vector3, vel: Vector3, t: number, life: number, delay: number } } = {}
	local function spawnTracers()
		local a = lookAngle() + rnd:NextNumber(-1.1, 1.1)
		local r = rnd:NextNumber(320, 420)
		local from = ringPoint(a, r, rnd:NextNumber(70, 140))
		local side = Vector3.new(-math.sin(a), 0, math.cos(a)) * (if rnd:NextNumber() < 0.5 then -1 else 1)
		local vel = side * rnd:NextNumber(120, 190) + Vector3.new(0, rnd:NextNumber(10, 40), 0)
		for k = 1, rnd:NextInteger(1, 3) do
			if #tracers >= TRACER_MAX then
				break
			end
			local p = Instance.new("Part")
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.CastShadow = false
			p.Material = Enum.Material.Neon
			p.Color = Color3.fromRGB(255, 186, 110)
			p.Transparency = 1
			p.Size = Vector3.new(0.5, 0.5, 16)
			p.CFrame = CFrame.lookAt(from, from + vel)
			p.Parent = folder
			tracers[#tracers + 1] = {
				part = p,
				from = from + Vector3.new(rnd:NextNumber(-6, 6), rnd:NextNumber(-4, 4), rnd:NextNumber(-6, 6)),
				vel = vel,
				t = 0,
				life = rnd:NextNumber(1.4, 2.2),
				delay = (k - 1) * rnd:NextNumber(0.1, 0.25),
			}
		end
	end
	state.conn = RunService.Heartbeat:Connect(function(dt)
		for i = #tracers, 1, -1 do
			local tr = tracers[i]
			if tr.delay > 0 then
				tr.delay -= dt
			else
				tr.t += dt
				if tr.t >= tr.life then
					tr.part:Destroy()
					table.remove(tracers, i)
				else
					local pos = tr.from + tr.vel * tr.t + Vector3.new(0, -9 * tr.t * tr.t, 0) -- slight ballistic droop
					local v = tr.vel + Vector3.new(0, -18 * tr.t, 0)
					tr.part.CFrame = CFrame.lookAt(pos, pos + v)
					local u = tr.t / tr.life
					tr.part.Transparency = 0.35 + 0.65 * math.max(0, math.abs(u * 2 - 1) ^ 3)
				end
			end
		end
	end)

	task.spawn(function()
		local nextFlash = os.clock() + rnd:NextNumber(1.5, 4)
		local nextTracer = os.clock() + rnd:NextNumber(3, 7)
		while state.alive and folder.Parent do
			local now = os.clock()
			if now >= nextFlash then
				nextFlash = now + rnd:NextNumber(2, 6)
				explode()
			end
			if now >= nextTracer and q >= 0.45 then
				nextTracer = now + rnd:NextNumber(6, 12)
				spawnTracers()
			end
			task.wait(0.25)
		end
	end)
end

local function watchHorizon()
	while true do
		local mapUp = Workspace:FindFirstChild("Map") ~= nil
		if mapUp and not horizon then
			local ok, err = pcall(startHorizon)
			if not ok then
				warn("[WorldFx] horizon fx failed:", err)
				stopHorizon()
				task.wait(30)
			end
		elseif not mapUp and horizon then
			stopHorizon()
		end
		task.wait(1)
	end
end

-- ---------------------------------------------------------------- init
function WorldFx.init(Fx: any, audio: any, juice: any)
	Audio = audio
	Juice = juice
	FxApi = Fx
	task.spawn(watchHorizon)
	Fx.register("Missile", onMissile)
	Fx.register("Skiff", onSkiff)
	Fx.register("Minigame", function(data: any)
		if type(data) == "table" and data.id == "trajectory" then
			openTrajectory(data)
		end
	end)
end

return WorldFx
