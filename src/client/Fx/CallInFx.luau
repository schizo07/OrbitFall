-- Client renderers for the call-in system (server: src/server/CallIns/*).
-- Fx kinds: Beacon, BeaconEnd, LanceStart/Move/End, Bomb, Jet, Shell, Gas, Smoke, Dome, DropPod, Crater,
-- GravWell, FireVortex, CryoFreeze, Shatter, Railshot, Firestorm, OverwatchSkiff, OverwatchEnd.
-- Everything lives in workspace.CurrentCamera.CallInFx (local only, no collisions, auto-cleaned).
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local OverwatchPath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("OverwatchPath"))

local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local TEX_FIRE = "rbxasset://textures/particles/fire_main.dds"

local Audio: any
local Juice: any

local CallInFx = {}

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
local folder: Folder? = nil
local function getFolder(): Folder
	local cam = workspace.CurrentCamera or workspace
	if folder and folder.Parent == cam then
		return folder
	end
	local f = cam:FindFirstChild("CallInFx")
	if not f then
		f = Instance.new("Folder")
		f.Name = "CallInFx"
		f.Parent = cam
	end
	folder = f :: Folder
	return folder :: Folder
end

local function setProps(inst: Instance, props: { [string]: any }?)
	if props then
		for k, v in props do
			(inst :: any)[k] = v
		end
	end
end

local function mkPart(props: { [string]: any }, parent: Instance?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	setProps(p, props)
	p.Parent = parent or getFolder()
	return p
end

local function emitter(parent: Instance, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	setProps(e, props)
	e.Parent = parent
	return e
end

local function seq(...: number): NumberSequence
	local pts = { ... }
	local kp = {}
	for i = 1, #pts do
		table.insert(kp, NumberSequenceKeypoint.new((i - 1) / math.max(#pts - 1, 1), pts[i]))
	end
	return NumberSequence.new(kp)
end

local function light(parent: Instance, color: Color3, range: number, brightness: number): PointLight
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = parent
	return l
end

-- Sound helpers (never let a missing key/arg kill an effect).
local function snd(key: string, at: any, fallback: Vector3?)
	if not Audio then
		return
	end
	local ok = pcall(Audio.play, key, at)
	if not ok and fallback then
		pcall(Audio.play, key, fallback)
	end
end

local function loopAt(key: string, at: any, fallback: Vector3?): any
	if not Audio or not Audio.loop then
		return nil
	end
	local ok, h = pcall(Audio.loop, key, at)
	if ok then
		return h
	end
	if fallback then
		local ok2, h2 = pcall(Audio.loop, key, fallback)
		if ok2 then
			return h2
		end
	end
	return nil
end

local function stopLoop(h: any)
	if h and h.stop then
		pcall(h.stop, h)
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

-- Runs step(alpha, dt) every frame for `duration` seconds (alpha 0..1), then finish().
local function animate(duration: number, step: (number, number) -> (), finish: (() -> ())?): RBXScriptConnection
	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		local a = (os.clock() - t0) / math.max(duration, 0.001)
		if a >= 1 then
			conn:Disconnect()
			step(1, dt)
			if finish then
				finish()
			end
			return
		end
		step(a, dt)
	end)
	return conn
end

local function tween(inst: Instance, time: number, goal: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	local tw = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), goal)
	tw:Play()
	return tw
end

-- Flat expanding ring on the ground.
local function ring(pos: Vector3, color: Color3, r0: number, r1: number, dur: number, thickness: number?)
	local th = thickness or 0.3
	local p = mkPart({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(th, r0 * 2, r0 * 2),
		Color = color,
		Transparency = 0.25,
		CFrame = CFrame.new(pos + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.pi / 2),
	})
	tween(p, dur, { Size = Vector3.new(th, r1 * 2, r1 * 2), Transparency = 1 })
	Debris:AddItem(p, dur + 0.1)
end

local function dustBurst(pos: Vector3, count: number, size: number)
	local anchor = mkPart({ Size = Vector3.new(1, 1, 1), Transparency = 1, CFrame = CFrame.new(pos + Vector3.new(0, 0.5, 0)) })
	local e = emitter(anchor, {
		Texture = TEX_SMOKE,
		Color = ColorSequence.new(Color3.fromRGB(170, 150, 125)),
		Size = seq(size * 0.5, size * 1.6),
		Transparency = seq(0.35, 1),
		Lifetime = NumberRange.new(0.8, 1.6),
		Speed = NumberRange.new(size * 2, size * 6),
		SpreadAngle = Vector2.new(80, 80),
		Rate = 0,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
		Acceleration = Vector3.new(0, 4, 0),
		Drag = 3,
		LightEmission = 0,
	})
	e:Emit(count)
	Debris:AddItem(anchor, 2.5)
end

local function rand(a: number, b: number): number
	return a + math.random() * (b - a)
end

-- Builds a model from part specs: { shape?, size, cf (local), color, material?, transparency? }
local function buildModel(specs: { { [string]: any } }): (Model, Part)
	local model = Instance.new("Model")
	local first: Part? = nil
	for _, s in specs do
		local p = mkPart({
			Shape = s.shape or Enum.PartType.Block,
			Size = s.size,
			Color = s.color,
			Material = s.material or Enum.Material.Metal,
			Transparency = s.transparency or 0,
			CFrame = s.cf,
		}, model)
		first = first or p
	end
	model.PrimaryPart = first
	model.Parent = getFolder()
	return model, first :: Part
end

-- ---------------------------------------------------------------------------------------------
-- Beacon
-- ---------------------------------------------------------------------------------------------
type BeaconRec = {
	model: Model,
	conn: RBXScriptConnection,
	loop: any,
	light: PointLight,
	parts: { Part },
	endAt: number?, -- BeaconEnd seen: the beam stays at full heat until this clock time (payload in flight), then fades
	far: Frame?,
	callin: string?,
}
local beacons: { [any]: BeaconRec } = {}

-- Seconds between BeaconEnd (payload launched) and the impact, per call-in: the beam holds at full heat meanwhile.
-- Mirrors the FALL / approach constants in server/CallIns/Effects/*.luau.
local BEACON_HOLD = {
	HALFTON = 1.5, -- FALL_TIME
	STRAFE = 1.4, -- jet reaches the line centre (APPROACH 220 / 160) ~ first bombs
	CLUSTER = 1.7, -- APPROACH 200 / 180 + FALL 0.6
	BARRAGE = 1.3, -- first shell FALL
	EMP = 0.8,
	TOXIN = 0.7,
	SMOKE = 0.6,
	LANCE = 0.2,
	GRAVWELL = 0.6, -- FALL
	CRYO = 0.7, -- FALL
	RAILSHOT = 0.9, -- charge
	FIRESTORM = 0.9, -- jet reaches the strip start
	OVERWATCH = 1.5, -- the Skiff is still flying in
}
local BEACON_RAMP = 1.2 -- the beam heats up over the last this-many seconds before BeaconEnd

local function endBeacon(id: any)
	local b = beacons[id]
	if not b then
		return
	end
	beacons[id] = nil
	b.conn:Disconnect()
	stopLoop(b.loop)
	for _, p in b.parts do
		tween(p, 0.45, { Transparency = 1 })
	end
	if b.far then
		tween(b.far, 0.45, { BackgroundTransparency = 1 })
	end
	tween(b.light, 0.45, { Brightness = 0 })
	Debris:AddItem(b.model, 0.6)
end

-- BeaconEnd: keep the beam burning (at full heat) until the payload lands, then fade it out
local function holdBeacon(id: any, callin: string?)
	local b = beacons[id]
	if not b then
		return
	end
	local hold = (callin and BEACON_HOLD[callin]) or 0.8
	b.endAt = os.clock() + hold
end

local function registerBeacon(Fx: any)
	Fx.register("Beacon", function(d)
		local pos: Vector3 = d.p
		local color: Color3 = d.color or Config.Colors.BeaconOffense
		local perfect = d.perfect == true
		local main = if perfect then color:Lerp(Config.Colors.Gold, 0.65) else color
		local coreCol = if perfect then Color3.fromRGB(255, 240, 190) else Color3.new(1, 1, 1)

		endBeacon(d.id) -- (defensive: duplicate id)
		local model = Instance.new("Model")
		model.Name = "Beacon"
		model.Parent = getFolder()

		local base = mkPart({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, 3.2, 3.2),
			Color = main,
			Transparency = 0.2,
			CFrame = CFrame.new(pos + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		}, model)
		local HEIGHT = 1200 -- was 700
		local column = mkPart({
			Size = Vector3.new(1.4, HEIGHT, 1.4),
			Color = main,
			Transparency = 0.55,
			CFrame = CFrame.new(pos + Vector3.new(0, HEIGHT / 2, 0)),
		}, model)
		local core = mkPart({
			Size = Vector3.new(0.45, HEIGHT, 0.45),
			Color = coreCol,
			Transparency = 0.1,
			CFrame = CFrame.new(pos + Vector3.new(0, HEIGHT / 2, 0)),
		}, model)
		local halo = mkPart({
			Size = Vector3.new(3.4, HEIGHT, 3.4),
			Color = main,
			Transparency = 0.88,
			CFrame = CFrame.new(pos + Vector3.new(0, HEIGHT / 2, 0)),
		}, model)
		-- wide, nearly invisible bloom sleeve: keeps the beam readable from across the map
		local bloomSleeve = mkPart({
			Size = Vector3.new(10, HEIGHT, 10),
			Color = main,
			Transparency = 0.94,
			CFrame = CFrame.new(pos + Vector3.new(0, HEIGHT / 2, 0)),
		}, model)
		-- far layer: a camera-facing billboard stripe (GUI is not fogged, so the beam cuts through the haze / dust storm).
		-- Faded out up close, where the 3D parts read better; fully on from ~160 studs.
		local farAnchor = mkPart({
			Size = Vector3.new(0.2, 0.2, 0.2),
			Transparency = 1,
			CFrame = CFrame.new(pos + Vector3.new(0, HEIGHT / 2, 0)),
		}, model)
		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.new(2.4, 0, HEIGHT, 0) -- scale = studs
		bb.LightInfluence = 0
		bb.Brightness = 2.5
		bb.AlwaysOnTop = false
		bb.ResetOnSpawn = false
		bb.Adornee = farAnchor
		bb.Parent = farAnchor
		local far = Instance.new("Frame")
		far.Size = UDim2.fromScale(1, 1)
		far.BorderSizePixel = 0
		far.BackgroundColor3 = main:Lerp(Color3.new(1, 1, 1), 0.25)
		far.BackgroundTransparency = 1
		far.Parent = bb
		local grad = Instance.new("UIGradient")
		grad.Rotation = 90 -- top of the stripe fades into the sky
		grad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.45, 0.35),
			NumberSequenceKeypoint.new(1, 0),
		})
		grad.Parent = far
		local lamp = light(base, main, 30, 3)
		local sparks = emitter(base, {
			Texture = TEX_SPARK,
			Color = ColorSequence.new(main),
			Size = seq(0.5, 0),
			Transparency = seq(0, 1),
			Lifetime = NumberRange.new(0.8, 1.5),
			Speed = NumberRange.new(10, 22),
			SpreadAngle = Vector2.new(25, 25),
			EmissionDirection = Enum.NormalId.Top,
			Rate = perfect and 40 or 22,
			LightEmission = 1,
			Acceleration = Vector3.new(0, -4, 0),
		})

		local t0 = os.clock()
		local delay = if type(d.t) == "number" then d.t else 3
		local nextRing = 0
		local phase = 0
		local id = d.id
		local conn = RunService.RenderStepped:Connect(function(dt)
			local now = os.clock()
			local t = now - t0
			local rec = beacons[id]
			-- heat 0..1: ramps up over the last BEACON_RAMP s of the delay, stays at 1 while the payload is in flight
			local heat = math.clamp((t - (delay - BEACON_RAMP)) / BEACON_RAMP, 0, 1)
			if rec and rec.endAt then
				heat = 1
				if now >= rec.endAt then
					endBeacon(id)
					return
				end
			end
			heat = heat * heat
			phase += dt * (7 + 18 * heat) -- pulse speeds up as the strike gets close
			local k = 0.5 + 0.5 * math.sin(phase)
			local w = 1 + 1.3 * heat
			column.Transparency = 0.45 + 0.2 * k - 0.25 * heat
			column.Size = Vector3.new((1.2 + 0.4 * k) * w, HEIGHT, (1.2 + 0.4 * k) * w)
			core.Size = Vector3.new(0.45 * (1 + 0.8 * heat), HEIGHT, 0.45 * (1 + 0.8 * heat))
			halo.Size = Vector3.new((3 + 1.2 * k) * w, HEIGHT, (3 + 1.2 * k) * w)
			halo.Transparency = 0.88 - 0.18 * heat
			bloomSleeve.Size = Vector3.new((9 + 3 * k) * w, HEIGHT, (9 + 3 * k) * w)
			bloomSleeve.Transparency = 0.94 - 0.08 * heat
			lamp.Brightness = (2 + 2 * k) * (1 + 1.5 * heat)
			lamp.Range = 30 + 25 * heat
			sparks.Rate = (if perfect then 40 else 22) * (1 + 2 * heat)
			-- far billboard: off within 60 studs, full from 160
			local cam = workspace.CurrentCamera
			local cd = if cam then (cam.CFrame.Position - pos).Magnitude else 0
			local farA = math.clamp((cd - 60) / 100, 0, 1)
			far.BackgroundTransparency = 1 - farA * (0.55 + 0.15 * k + 0.3 * heat)
			bb.Size = UDim2.new(2.4 * w + cd * 0.004, 0, HEIGHT, 0) -- a little wider with distance so it stays a few pixels thick
			if t >= nextRing then
				nextRing = t + 0.9 * (1 - 0.55 * heat)
				ring(pos, main, 1, 7 + 5 * heat, 0.9)
			end
			if t > 40 then
				endBeacon(id)
			end
		end)

		snd("ShipRadio", pos)
		local loop = loopAt("BeaconPing", pos, pos)
		if d.callin == "LANCE" then
			snd("LanceCharge", pos)
		end
		beacons[id] = {
			model = model,
			conn = conn,
			loop = loop,
			light = lamp,
			parts = { base, column, core, halo, bloomSleeve },
			far = far,
			callin = d.callin,
		}
	end)

	Fx.register("BeaconEnd", function(d)
		local b = beacons[d.id]
		holdBeacon(d.id, b and (b :: any).callin)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Orbital Lance
-- ---------------------------------------------------------------------------------------------
type Beam = {
	cur: Vector3,
	target: Vector3,
	conn: RBXScriptConnection,
	ending: number?,
	model: Model,
	loop: any,
}
local beams: { [any]: Beam } = {}

local function registerLance(Fx: any)
	Fx.register("LanceStart", function(d)
		local radius: number = d.r or 3
		local H = 700
		local start: Vector3 = d.p
		local model = Instance.new("Model")
		model.Name = "Lance"
		model.Parent = getFolder()

		local function beamPart(width: number, color: Color3, transparency: number): Part
			return mkPart({
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(H, width, width),
				Color = color,
				Transparency = transparency,
				CFrame = CFrame.new(start + Vector3.new(0, H / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
			}, model)
		end
		local layers = {
			{ part = beamPart(radius * 0.8, Color3.new(1, 1, 1), 0), w = radius * 0.8 },
			{ part = beamPart(radius * 1.6, Color3.fromRGB(255, 200, 150), 0.25), w = radius * 1.6 },
			{ part = beamPart(radius * 3.2, Color3.fromRGB(255, 80, 50), 0.62), w = radius * 3.2 },
			{ part = beamPart(radius * 6, Color3.fromRGB(255, 60, 40), 0.88), w = radius * 6 },
		}
		local ground = mkPart({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, radius * 6, radius * 6),
			Color = Color3.fromRGB(255, 190, 120),
			Transparency = 0.25,
			CFrame = CFrame.new(start + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		}, model)
		local anchor = mkPart({ Size = Vector3.new(1, 1, 1), Transparency = 1, CFrame = CFrame.new(start + Vector3.new(0, 1, 0)) }, model)
		local lamp = light(anchor, Color3.fromRGB(255, 150, 90), 55, 6)
		emitter(anchor, {
			Texture = TEX_SPARK,
			Color = ColorSequence.new(Color3.fromRGB(255, 190, 90), Color3.fromRGB(255, 60, 20)),
			Size = seq(0.9, 0),
			Transparency = seq(0, 1),
			Lifetime = NumberRange.new(0.4, 0.9),
			Speed = NumberRange.new(18, 42),
			SpreadAngle = Vector2.new(75, 75),
			EmissionDirection = Enum.NormalId.Top,
			Rate = 160,
			LightEmission = 1,
			Acceleration = Vector3.new(0, -60, 0),
		})
		emitter(anchor, {
			Texture = TEX_SMOKE,
			Color = ColorSequence.new(Color3.fromRGB(60, 50, 45)),
			Size = seq(radius * 2, radius * 5),
			Transparency = seq(0.5, 1),
			Lifetime = NumberRange.new(1, 2),
			Speed = NumberRange.new(4, 10),
			SpreadAngle = Vector2.new(40, 40),
			EmissionDirection = Enum.NormalId.Top,
			Rate = 22,
		})

		snd("LanceCharge", start)
		local loop = loopAt("LanceHum", anchor, start)
		flash(Color3.fromRGB(255, 230, 210), 0.55, 0.5)
		shake(2, 0.7, start)

		local rec: Beam = { cur = start, target = start, conn = nil :: any, ending = nil, model = model, loop = loop }
		local t0 = os.clock()
		local nextScorch = 0
		local nextShake = 0
		local ended = 0
		rec.conn = RunService.RenderStepped:Connect(function(dt)
			local t = os.clock() - t0
			rec.cur = rec.cur:Lerp(rec.target, 1 - math.exp(-10 * dt))
			local pos = rec.cur
			local fade = 1
			if rec.ending then
				ended = os.clock() - rec.ending
				fade = math.max(0, 1 - ended / 0.5)
				if fade <= 0 then
					rec.conn:Disconnect()
					model:Destroy()
					return
				end
			else
				-- grow in from a thin line
				fade = math.min(1, t / 0.25)
			end
			local jitter = 1 + (math.noise(t * 25, 0.5) * 0.18)
			for i, l in layers do
				local w = l.w * fade * (i == 1 and 1 + math.noise(t * 40, 2.5) * 0.25 or jitter)
				l.part.Size = Vector3.new(H, math.max(w, 0.05), math.max(w, 0.05))
				l.part.CFrame = CFrame.new(pos + Vector3.new(0, H / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			end
			ground.CFrame = CFrame.new(pos + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			ground.Size = Vector3.new(0.3, radius * 6 * fade * jitter, radius * 6 * fade * jitter)
			anchor.CFrame = CFrame.new(pos + Vector3.new(0, 1, 0))
			lamp.Brightness = 6 * fade

			if not rec.ending then
				if t >= nextScorch then
					nextScorch = t + 0.3
					local sc = mkPart({
						Shape = Enum.PartType.Cylinder,
						Size = Vector3.new(0.1, radius * 2.8, radius * 2.8),
						Color = Color3.fromRGB(22, 18, 16),
						Material = Enum.Material.SmoothPlastic,
						Transparency = 0.2,
						CFrame = CFrame.new(pos + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.pi / 2),
					})
					tween(sc, 7, { Transparency = 1 }, Enum.EasingStyle.Linear)
					Debris:AddItem(sc, 7.2)
				end
				if t >= nextShake then
					nextShake = t + 0.2
					shake(0.45, 0.3, pos)
				end
			end
		end)
		beams[d.id] = rec
	end)

	Fx.register("LanceMove", function(d)
		local b = beams[d.id]
		if b and not b.ending then
			b.target = d.p
		end
	end)

	Fx.register("LanceEnd", function(d)
		local b = beams[d.id]
		if not b then
			return
		end
		beams[d.id] = nil
		b.ending = os.clock()
		stopLoop(b.loop)
		snd("LanceEnd", b.cur)
		flash(Color3.fromRGB(255, 200, 160), 0.25, 0.3)
		ring(b.cur, Color3.fromRGB(255, 150, 80), 2, 14, 0.6)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Bomb (falling bomb), Shell (incoming streak)
-- ---------------------------------------------------------------------------------------------
local function registerFalling(Fx: any)
	Fx.register("Bomb", function(d)
		local s: number = d.s or 1
		local to: Vector3 = d.p
		local from: Vector3 = d.from or (to + Vector3.new(rand(-25, 25), 420, rand(-25, 25)))
		local fall: number = math.max(d.t or 1.5, 0.1)
		local olive, dark = Color3.fromRGB(78, 88, 64), Color3.fromRGB(40, 44, 50)
		-- nose points along local -Z
		local spec = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(6 * s, 2.2 * s, 2.2 * s), cf = CFrame.Angles(0, math.pi / 2, 0), color = olive },
			{ shape = Enum.PartType.Ball, size = Vector3.new(2.2 * s, 2.2 * s, 2.6 * s), cf = CFrame.new(0, 0, -3 * s), color = olive },
			{ size = Vector3.new(0.2 * s, 2.6 * s, 1.4 * s), cf = CFrame.new(0, 0, 2.6 * s), color = dark },
			{ size = Vector3.new(2.6 * s, 0.2 * s, 1.4 * s), cf = CFrame.new(0, 0, 2.6 * s), color = dark },
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.5 * s, 2.3 * s, 2.3 * s), cf = CFrame.new(0, 0, -0.8 * s) * CFrame.Angles(0, math.pi / 2, 0), color = Color3.fromRGB(255, 190, 40), material = Enum.Material.Neon },
		}
		local model, root = buildModel(spec)
		local dir = (to - from).Unit
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 0.4 * s, 3 * s)
		a0.Parent = root
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -0.4 * s, 3 * s)
		a1.Parent = root
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 0.5
		trail.Color = ColorSequence.new(Color3.fromRGB(230, 230, 230))
		trail.Transparency = seq(0.5, 1)
		trail.WidthScale = NumberSequence.new(1, 0)
		trail.Parent = root

		model:PivotTo(CFrame.lookAt(from, from + dir))
		snd("BombWhistle", root, to)
		animate(fall, function(a)
			local pos = from:Lerp(to, a ^ 1.35)
			model:PivotTo(CFrame.lookAt(pos, pos + dir))
		end, function()
			model:Destroy()
		end)
	end)

	Fx.register("Shell", function(d)
		local s: number = d.s or 1
		local to: Vector3 = d.p
		local from = to + Vector3.new(rand(-45, 45), 380, rand(-45, 45))
		local fall: number = math.max(d.t or 1.3, 0.1)
		local col: Color3 = d.c or Color3.fromRGB(255, 190, 110)
		local dir = (to - from).Unit
		local streak = mkPart({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(7 * s, 0.7 * s, 0.7 * s),
			Color = col,
			CFrame = CFrame.lookAt(from, from + dir) * CFrame.Angles(0, math.pi / 2, 0),
		})
		light(streak, col, 16 * s + 4, 3)
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(3.5 * s, 0.35 * s, 0)
		a0.Parent = streak
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(3.5 * s, -0.35 * s, 0)
		a1.Parent = streak
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 0.45
		trail.LightEmission = 1
		trail.Color = ColorSequence.new(col, Color3.fromRGB(255, 255, 255))
		trail.Transparency = seq(0.1, 1)
		trail.WidthScale = NumberSequence.new(1, 0)
		trail.Parent = streak

		snd("ShellWhistle", streak, to)
		animate(fall, function(a)
			local pos = from:Lerp(to, a ^ 1.3)
			streak.CFrame = CFrame.lookAt(pos, pos + dir) * CFrame.Angles(0, math.pi / 2, 0)
		end, function()
			streak:Destroy()
			if s >= 0.5 then
				local f = mkPart({ Shape = Enum.PartType.Ball, Size = Vector3.new(3, 3, 3) * s, Color = col, Transparency = 0.2, CFrame = CFrame.new(to) })
				tween(f, 0.25, { Size = Vector3.new(9, 9, 9) * s, Transparency = 1 })
				Debris:AddItem(f, 0.3)
			end
		end)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Jet flyover
-- ---------------------------------------------------------------------------------------------
local function registerJet(Fx: any)
	Fx.register("Jet", function(d)
		local a: Vector3, b: Vector3 = d.a, d.b
		local dur: number = math.max(d.t or 3, 0.3)
		local hull, dark = Color3.fromRGB(150, 158, 170), Color3.fromRGB(52, 58, 68)
		-- nose along local -Z
		local spec = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(11, 1.7, 1.7), cf = CFrame.Angles(0, math.pi / 2, 0), color = hull },
			{ shape = Enum.PartType.Ball, size = Vector3.new(1.7, 1.7, 3.6), cf = CFrame.new(0, 0, -5.6), color = hull },
			{ shape = Enum.PartType.Ball, size = Vector3.new(1.1, 0.9, 2.6), cf = CFrame.new(0, 0.85, -2.2), color = Color3.fromRGB(70, 130, 190), material = Enum.Material.Glass },
			-- swept wings
			{ size = Vector3.new(9, 0.25, 3.2), cf = CFrame.new(-4.6, 0, 1.6) * CFrame.Angles(0, 0.5, 0), color = dark },
			{ size = Vector3.new(9, 0.25, 3.2), cf = CFrame.new(4.6, 0, 1.6) * CFrame.Angles(0, -0.5, 0), color = dark },
			-- tail
			{ size = Vector3.new(0.25, 2.6, 2.2), cf = CFrame.new(0, 1.5, 4.4) * CFrame.Angles(math.rad(-18), 0, 0), color = dark },
			{ size = Vector3.new(5, 0.2, 1.8), cf = CFrame.new(0, 0, 4.7), color = dark },
			-- engines
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(1.4, 1.1, 1.1), cf = CFrame.new(-0.6, 0, 5.6) * CFrame.Angles(0, math.pi / 2, 0), color = Color3.fromRGB(255, 150, 60), material = Enum.Material.Neon },
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(1.4, 1.1, 1.1), cf = CFrame.new(0.6, 0, 5.6) * CFrame.Angles(0, math.pi / 2, 0), color = Color3.fromRGB(255, 150, 60), material = Enum.Material.Neon },
		}
		local model, root = buildModel(spec)
		local dir = (b - a).Unit
		local engines = {}
		for _, x in { -0.6, 0.6 } do
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(x, 0.35, 6.2)
			a0.Parent = root
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(x, -0.35, 6.2)
			a1.Parent = root
			local tr = Instance.new("Trail")
			tr.Attachment0 = a0
			tr.Attachment1 = a1
			tr.Lifetime = 0.7
			tr.LightEmission = 1
			tr.Color = ColorSequence.new(Color3.fromRGB(255, 180, 90), Color3.fromRGB(120, 120, 125))
			tr.Transparency = seq(0.1, 1)
			tr.WidthScale = NumberSequence.new(1, 2)
			tr.Parent = root
			table.insert(engines, tr)
		end
		model:PivotTo(CFrame.lookAt(a, a + dir))
		snd("JetFlyby", root, (a + b) / 2)
		local shook = false
		animate(dur, function(t)
			local pos = a:Lerp(b, t)
			local roll = math.sin(t * math.pi * 2) * 0.12
			model:PivotTo(CFrame.lookAt(pos, pos + dir) * CFrame.Angles(0, 0, roll))
			if not shook and t >= 0.5 then
				shook = true
				shake(0.8, 0.8, pos)
			end
		end, function()
			model:Destroy()
		end)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Gas, Smoke, Dome
-- ---------------------------------------------------------------------------------------------
local function registerClouds(Fx: any)
	Fx.register("Gas", function(d)
		local pos: Vector3, r: number = d.p, d.r or 14
		local dur: number = d.t or 12
		local green = Color3.fromRGB(105, 225, 70)
		local anchor = mkPart({
			Size = Vector3.new(r * 1.5, r * 0.5, r * 1.5),
			Transparency = 1,
			CFrame = CFrame.new(pos + Vector3.new(0, r * 0.3, 0)),
		})
		local bubble = mkPart({
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(r * 2, r * 2, r * 2),
			Color = green,
			Transparency = 0.9,
			CFrame = CFrame.new(pos),
		})
		light(anchor, green, r * 1.6, 1.5)
		local main = emitter(anchor, {
			Texture = TEX_SMOKE,
			Color = ColorSequence.new(Color3.fromRGB(90, 200, 60), Color3.fromRGB(60, 150, 50)),
			Size = seq(r * 0.45, r * 0.8),
			Transparency = seq(0.55, 0.75, 1),
			Lifetime = NumberRange.new(3, 5),
			Speed = NumberRange.new(0.5, 2.5),
			SpreadAngle = Vector2.new(180, 180),
			Rate = 10 + r * 1.2,
			Rotation = NumberRange.new(0, 360),
			RotSpeed = NumberRange.new(-25, 25),
			LightEmission = 0.35,
			Shape = Enum.ParticleEmitterShape.Box,
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		})
		local bubbles = emitter(anchor, {
			Texture = TEX_SPARK,
			Color = ColorSequence.new(Color3.fromRGB(190, 255, 140)),
			Size = seq(0.8, 0.2),
			Transparency = seq(0.1, 1),
			Lifetime = NumberRange.new(1, 2),
			Speed = NumberRange.new(2, 5),
			SpreadAngle = Vector2.new(20, 20),
			EmissionDirection = Enum.NormalId.Top,
			Rate = r * 2,
			LightEmission = 0.8,
			Shape = Enum.ParticleEmitterShape.Box,
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		})
		snd("GasHiss", pos)
		local loop = loopAt("GasHiss", anchor, pos)
		tween(bubble, 0.6, { Size = Vector3.new(r * 2, r * 2, r * 2) }, Enum.EasingStyle.Back)
		ring(pos, green, 2, r, 0.8)

		task.delay(dur, function()
			main.Enabled = false
			bubbles.Enabled = false
			stopLoop(loop)
			tween(bubble, 1, { Transparency = 1 })
		end)
		Debris:AddItem(anchor, dur + 6)
		Debris:AddItem(bubble, dur + 2)
	end)

	Fx.register("Smoke", function(d)
		local pos: Vector3 = d.p
		local dir: Vector3 = d.dir
		local length: number, width: number = d.length or 30, d.width or 10
		local dur: number = d.t or 15
		-- X axis = wall length (across), Z = depth along dir
		local cf = CFrame.lookAt(pos + Vector3.new(0, 5, 0), pos + Vector3.new(0, 5, 0) + dir)
		local anchor = mkPart({ Size = Vector3.new(length, 10, width), Transparency = 1, CFrame = cf })
		local main = emitter(anchor, {
			Texture = TEX_SMOKE,
			Color = ColorSequence.new(Color3.fromRGB(205, 205, 210), Color3.fromRGB(140, 140, 148)),
			Size = seq(9, 14, 16),
			Transparency = seq(0.15, 0.3, 1),
			Lifetime = NumberRange.new(5, 8),
			Speed = NumberRange.new(0.5, 2),
			SpreadAngle = Vector2.new(180, 180),
			Rate = 12 + length * 1.2,
			Rotation = NumberRange.new(0, 360),
			RotSpeed = NumberRange.new(-15, 15),
			Acceleration = Vector3.new(0, 0.5, 0),
			Shape = Enum.ParticleEmitterShape.Box,
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		})
		main:Emit(math.floor(length * 2)) -- instant puff
		snd("SmokePop", pos)
		dustBurst(pos, 14, 5)
		task.delay(dur, function()
			main.Enabled = false
		end)
		Debris:AddItem(anchor, dur + 9)
	end)

	Fx.register("Dome", function(d)
		local pos: Vector3, r: number = d.p, d.r or 12
		local teal = Config.Colors.Friendly
		local ball = mkPart({
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(2, 2, 2),
			Color = teal,
			Transparency = 0.5,
			CFrame = CFrame.new(pos),
		})
		tween(ball, 0.55, { Size = Vector3.new(r * 2.1, r * 2.1, r * 2.1), Transparency = 1 }, Enum.EasingStyle.Quint)
		Debris:AddItem(ball, 0.7)
		ring(pos, teal, 1, r, 0.7, 0.4)
		snd("ShieldUp", pos)
		shake(0.5, 0.3, pos)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Drop pod, crater
-- ---------------------------------------------------------------------------------------------
local POD_COLORS: { [string]: Color3 } = {
	supply = Color3.fromRGB(47, 139, 255),
	weapon = Color3.fromRGB(47, 139, 255),
	turret = Color3.fromRGB(51, 224, 122),
	mines = Color3.fromRGB(51, 224, 122),
	shield = Color3.fromRGB(62, 230, 200),
	reinforce = Color3.fromRGB(255, 211, 74),
}

local craters: { Instance } = {}

local function registerPods(Fx: any)
	Fx.register("DropPod", function(d)
		local to: Vector3 = d.p
		local fall: number = math.max(d.t or 1.6, 0.2)
		local accent = POD_COLORS[d.kind] or Color3.fromRGB(180, 190, 205)
		local from = to + Vector3.new(rand(-30, 30), 460, rand(-30, 30))
		local dir = (to - from).Unit
		local hull = Color3.fromRGB(70, 76, 88)
		-- nose along local -Z
		local spec = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(7, 3.2, 3.2), cf = CFrame.Angles(0, math.pi / 2, 0), color = hull },
			{ shape = Enum.PartType.Ball, size = Vector3.new(3.2, 3.2, 4), cf = CFrame.new(0, 0, -3.8), color = hull },
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.5, 3.4, 3.4), cf = CFrame.new(0, 0, -1.2) * CFrame.Angles(0, math.pi / 2, 0), color = accent },
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.5, 3.4, 3.4), cf = CFrame.new(0, 0, 1.6) * CFrame.Angles(0, math.pi / 2, 0), color = accent },
			{ shape = Enum.PartType.Ball, size = Vector3.new(2.4, 2.4, 3.6), cf = CFrame.new(0, 0, 4.2), color = Color3.fromRGB(255, 170, 70), material = Enum.Material.Neon },
		}
		local model, root = buildModel(spec)
		local flame = mkPart({ Size = Vector3.new(1, 1, 1), Transparency = 1, CFrame = CFrame.new(from) }, model)
		emitter(flame, {
			Texture = TEX_FIRE,
			Color = ColorSequence.new(Color3.fromRGB(255, 200, 100), Color3.fromRGB(255, 70, 20)),
			Size = seq(3, 0.5),
			Transparency = seq(0, 1),
			Lifetime = NumberRange.new(0.3, 0.6),
			Speed = NumberRange.new(2, 6),
			SpreadAngle = Vector2.new(15, 15),
			Rate = 120,
			LightEmission = 1,
		})
		emitter(flame, {
			Texture = TEX_SMOKE,
			Color = ColorSequence.new(Color3.fromRGB(190, 190, 195)),
			Size = seq(2, 6),
			Transparency = seq(0.4, 1),
			Lifetime = NumberRange.new(0.8, 1.4),
			Speed = NumberRange.new(0, 3),
			SpreadAngle = Vector2.new(25, 25),
			Rate = 60,
		})
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 0.9, 6)
		a0.Parent = root
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -0.9, 6)
		a1.Parent = root
		local tr = Instance.new("Trail")
		tr.Attachment0 = a0
		tr.Attachment1 = a1
		tr.Lifetime = 0.6
		tr.LightEmission = 0.8
		tr.Color = ColorSequence.new(Color3.fromRGB(255, 190, 110), Color3.fromRGB(110, 110, 115))
		tr.Transparency = seq(0.2, 1)
		tr.Parent = root

		model:PivotTo(CFrame.lookAt(from, from + dir))
		snd("PodFall", root, to)
		animate(fall, function(a)
			local pos = from:Lerp(to + Vector3.new(0, 3.5, 0), a ^ 1.6)
			local cf = CFrame.lookAt(pos, pos + dir)
			model:PivotTo(cf)
			flame.CFrame = cf * CFrame.new(0, 0, 6.5)
		end, function()
			snd("PodImpact", to)
			shake(1.3, 0.45, to)
			dustBurst(to, 36, 5)
			ring(to, accent, 2, 11, 0.5, 0.4)
			-- pod pops open and vanishes
			for _, p in model:GetDescendants() do
				if p:IsA("BasePart") and p.Transparency < 1 then
					tween(p, 0.3, { Transparency = 1 })
				end
			end
			Debris:AddItem(model, 0.4)
		end)
	end)

	Fx.register("Crater", function(d)
		local pos: Vector3, r: number = d.p, d.r or 6
		-- keep the number of live craters bounded
		while #craters >= 14 do
			local old = table.remove(craters, 1)
			if old then
				old:Destroy()
			end
		end
		local jitter = (#craters % 5) * 0.012
		-- lie flat on the actual ground (dunes are sloped): cylinder X axis = surface normal
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Include
		rp.FilterDescendantsInstances = { workspace.Terrain }
		local hit = workspace:Raycast(pos + Vector3.new(0, 8, 0), Vector3.new(0, -24, 0), rp)
		local n = hit and hit.Normal or Vector3.yAxis
		if n.Y < 0.55 then
			return -- steep face: skip the decal
		end
		if hit then
			pos = hit.Position
		end
		-- explicit frame with X = surface normal (CFrame.lookAt degenerates when n is straight up)
		local ref = if math.abs(n.X) < 0.9 then Vector3.xAxis else Vector3.zAxis
		local up = n:Cross(ref).Unit
		local base = CFrame.fromMatrix(pos, n, up)
		local scorch = mkPart({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.12, r * 2, r * 2),
			Color = Color3.fromRGB(24, 20, 18),
			Material = Enum.Material.Slate,
			Transparency = 0.1,
			CFrame = base * CFrame.new(0.1 + jitter, 0, 0) * CFrame.Angles(math.rad(math.random(0, 360)), 0, 0),
		})
		local halo = mkPart({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.1, r * 3, r * 3),
			Color = Color3.fromRGB(52, 44, 38),
			Material = Enum.Material.Slate,
			Transparency = 0.55,
			CFrame = base * CFrame.new(0.07 + jitter, 0, 0),
		}, scorch)
		scorch.CastShadow = false
		halo.CastShadow = false
		table.insert(craters, scorch)
		task.delay(14, function()
			if scorch.Parent then
				tween(scorch, 6, { Transparency = 1 }, Enum.EasingStyle.Linear)
				tween(halo, 6, { Transparency = 1 }, Enum.EasingStyle.Linear)
			end
		end)
		Debris:AddItem(scorch, 20.5)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Gravity Well / Cryo Bomb / Railshot / Firestorm Line (+ Shatter from server/Explosions)
-- ---------------------------------------------------------------------------------------------
-- Screen moment strength: Studio A/B group CALL-IN PUNCH (Feel_CallInPunch, default 1) scales the flashes and colour
-- punches below; shakes follow the explosion group BLAST SHAKE (Feel_BlastShake).
local FxRef: any = nil
local SpectacleRef: any = nil
local VOID = Color3.fromRGB(150, 70, 240)
local ICE = Color3.fromRGB(150, 220, 255)
local RAIL = Color3.fromRGB(140, 225, 255)
local FIRE = Color3.fromRGB(255, 140, 50)
local HIGHLIGHT_CAP = 14
local liveHighlights = 0

local function attrNum(name: string, default: number): number
	local v = workspace:GetAttribute(name)
	return if typeof(v) == "number" then v else default
end
local function punchMult(): number
	return attrNum("Feel_CallInPunch", 1)
end
local function shakeMult(): number
	return attrNum("Feel_BlastShake", 1)
end
local function quality(): number
	return FxRef and FxRef.quality or 1
end
local touchCached: boolean? = nil
local function lowEnd(): boolean
	if touchCached == nil then
		local ok, Theme = pcall(function()
			return require((script.Parent.Parent :: any).UI.Theme)
		end)
		touchCached = ok and Theme.isTouch() == true
	end
	return touchCached == true or quality() < 1
end
local function qn(n: number): number
	return math.max(1, math.floor(n * quality() + 0.5))
end
local function camDist(p: Vector3): number
	local cam = workspace.CurrentCamera
	return if cam then (cam.CFrame.Position - p).Magnitude else 0
end
local function punch(tint: Color3, strength: number, dur: number, sat: number?, p: Vector3)
	local m = punchMult()
	if m <= 0 or not Juice or not Juice.colorPunch then
		return
	end
	-- full strength within 40 studs, gone at 220
	local k = math.clamp(1 - (camDist(p) - 40) / 180, 0, 1)
	if k > 0 then
		pcall(Juice.colorPunch, tint, strength * m * k, dur, sat)
	end
end
local function flashAt(color: Color3, alpha: number, dur: number, p: Vector3)
	local m = punchMult()
	if m > 0 and Juice and Juice.flashAt then
		pcall(Juice.flashAt, color, math.min(alpha * m, 0.9), dur, p, 500)
	end
end
local function trauma(mag: number, dur: number, p: Vector3, range: number)
	local m = shakeMult()
	if m > 0 and Juice and Juice.trauma then
		pcall(Juice.trauma, mag * m, dur, p, range)
	end
end
local function orbitalMini(p: Vector3, sc: number, tint: Color3)
	if SpectacleRef and SpectacleRef.orbital then
		pcall(SpectacleRef.orbital, p, sc, { mini = true, tint = tint })
	end
end

local function registerNew(Fx: any)
	-- Gravity Well: inward particle swirl, orbiting motes, a dark core that swells, then the server's "void" blast
	Fx.register("GravWell", function(d)
		local p: Vector3, r: number, dur: number = d.p, d.r or 18, math.max(d.t or 3, 0.5)
		local centre = p + Vector3.new(0, 3, 0)
		local core = mkPart({ Shape = Enum.PartType.Ball, Size = Vector3.one * 1.5, Color = Color3.fromRGB(25, 5, 45), Material = Enum.Material.SmoothPlastic, CFrame = CFrame.new(centre) })
		local shell = mkPart({ Shape = Enum.PartType.Ball, Size = Vector3.one * 3, Color = VOID, Transparency = 0.55, CFrame = CFrame.new(centre) })
		local disc = mkPart({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.12, r * 2, r * 2),
			Color = VOID,
			Transparency = 0.82,
			CFrame = CFrame.new(p + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		})
		local l = light(shell, VOID, r * 1.4, 3)
		local anchor = mkPart({ Size = Vector3.one, Transparency = 1, CFrame = CFrame.new(centre) })
		local swirl = emitter(anchor, {
			Texture = TEX_SPARK,
			Color = ColorSequence.new(Color3.fromRGB(230, 190, 255), VOID),
			Size = seq(0.9, 0.3),
			Transparency = seq(0.2, 0.05, 1),
			Lifetime = NumberRange.new(1.0, 1.3),
			Speed = NumberRange.new(r * 0.8, r * 0.95),
			Rate = 60 * quality(),
			LightEmission = 1,
			Shape = Enum.ParticleEmitterShape.Sphere,
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
			ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward,
			RotSpeed = NumberRange.new(-180, 180),
		})
		anchor.Size = Vector3.new(r * 2, 4, r * 2)
		local dust = emitter(anchor, {
			Texture = TEX_SMOKE,
			Color = ColorSequence.new(Color3.fromRGB(120, 95, 140)),
			Size = seq(2.5, 0.8),
			Transparency = seq(0.6, 0.85, 1),
			Lifetime = NumberRange.new(1.1, 1.4),
			Speed = NumberRange.new(r * 0.7, r * 0.85),
			Rate = 18 * quality(),
			Shape = Enum.ParticleEmitterShape.Sphere,
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
			ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward,
		})
		-- orbiting motes on a shrinking spiral
		local motes = {}
		for i = 1, qn(10) do
			motes[i] = mkPart({ Shape = Enum.PartType.Ball, Size = Vector3.one * 0.7, Color = Color3.fromRGB(220, 170, 255), CFrame = CFrame.new(centre) })
		end
		local loop = loopAt("LanceHum", anchor, p)
		trauma(0.8, dur, p, 70)
		animate(dur, function(a)
			local t = os.clock()
			core.Size = Vector3.one * (1.5 + 3.5 * a)
			shell.Size = Vector3.one * (3 + 4 * a + math.sin(t * 20) * 0.4)
			shell.Transparency = 0.55 - 0.2 * a
			disc.Size = Vector3.new(0.12, r * 2 * (1 - 0.6 * a), r * 2 * (1 - 0.6 * a))
			disc.CFrame = CFrame.new(p + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, t * 3, 0) * CFrame.Angles(0, 0, math.pi / 2)
			l.Brightness = 3 + 4 * a
			for i, m in motes do
				local ang = t * (3 + 4 * a) + i * (math.pi * 2 / #motes)
				local rad = r * (0.85 - 0.7 * a) * (0.6 + 0.4 * ((i % 3) / 2))
				m.CFrame = CFrame.new(centre + Vector3.new(math.cos(ang) * rad, math.sin(t * 2 + i) * 1.5, math.sin(ang) * rad))
			end
		end, function()
			stopLoop(loop)
			swirl.Enabled = false
			dust.Enabled = false
			for _, m in motes do
				m:Destroy()
			end
			core:Destroy()
			disc:Destroy()
			-- implosion snap: the shell collapses to a point right as the server blast goes off
			tween(shell, 0.12, { Size = Vector3.one * 0.5, Transparency = 0 })
			Debris:AddItem(shell, 0.15)
			Debris:AddItem(anchor, 1.6)
			orbitalMini(p, 1.1, VOID)
			punch(VOID, 0.9, 0.7, -0.3, p)
			flashAt(Color3.fromRGB(235, 210, 255), 0.45, 0.3, p)
		end)
	end)

	-- Fire vortex (call-in combo, server/CallIns/Combos): a Gravity Well that caught fire. Spinning ring of flame motes round a
	-- tall flame column for the rest of the pull; the server's (bigger) blast ends it. Fewer motes / particles on touch and low quality.
	Fx.register("FireVortex", function(d)
		local p: Vector3, r: number, dur: number = d.p, d.r or 18, math.max(d.t or 2, 0.4)
		local lite = lowEnd()
		local height = 26
		local base = p + Vector3.new(0, 0.5, 0)
		local anchor = mkPart({ Size = Vector3.new(r * 0.5, height, r * 0.5), Transparency = 1, CFrame = CFrame.new(base + Vector3.new(0, height / 2, 0)) })
		local column = emitter(anchor, {
			Texture = TEX_FIRE,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 220, 120)),
				ColorSequenceKeypoint.new(0.5, FIRE),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 40, 20)),
			}),
			Size = seq(4.5, 7, 2),
			Transparency = seq(0.1, 0.3, 1),
			Lifetime = NumberRange.new(0.9, 1.3),
			Speed = NumberRange.new(14, 20),
			SpreadAngle = Vector2.new(8, 8),
			Rate = (if lite then 28 else 55) * quality(),
			LightEmission = 1,
			Rotation = NumberRange.new(0, 360),
			RotSpeed = NumberRange.new(-60, 60),
			EmissionDirection = Enum.NormalId.Top,
			Shape = Enum.ParticleEmitterShape.Cylinder,
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		})
		local smoke = emitter(anchor, {
			Texture = TEX_SMOKE,
			Color = ColorSequence.new(Color3.fromRGB(70, 55, 50)),
			Size = seq(4, 9),
			Transparency = seq(0.55, 0.8, 1),
			Lifetime = NumberRange.new(1.4, 2),
			Speed = NumberRange.new(10, 16),
			Rate = (if lite then 6 else 14) * quality(),
			EmissionDirection = Enum.NormalId.Top,
			Shape = Enum.ParticleEmitterShape.Cylinder,
		})
		local core = mkPart({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(height, 3, 3),
			Color = FIRE,
			Transparency = 0.6,
			CFrame = CFrame.new(base + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		})
		local l = light(core, FIRE, r * 1.2, 4)
		-- ring of flame motes spiralling round the column; each carries a small fire trail emitter
		local motes = {}
		for i = 1, qn(if lite then 5 else 9) do
			local m = mkPart({ Shape = Enum.PartType.Ball, Size = Vector3.one * 1.1, Color = Color3.fromRGB(255, 170, 70), CFrame = CFrame.new(base) })
			emitter(m, {
				Texture = TEX_FIRE,
				Color = ColorSequence.new(Color3.fromRGB(255, 200, 100), Color3.fromRGB(200, 60, 20)),
				Size = seq(2.2, 0.3),
				Transparency = seq(0.2, 1),
				Lifetime = NumberRange.new(0.4, 0.6),
				Speed = NumberRange.new(0, 2),
				Rate = if lite then 10 else 20,
				LightEmission = 1,
			})
			motes[i] = m
		end
		-- ignition thump: the existing Explosion sound, pitched down so the combo is audibly its own thing
		if not Audio or not pcall(Audio.play, "Explosion", p, { pitch = 0.7 }) then
			snd("Explosion", p)
		end
		trauma(0.5, dur, p, 60)
		flashAt(FIRE, 0.25, 0.25, p)
		punch(FIRE, 0.5, 0.5, 0.1, p)
		animate(dur, function(a)
			local t = os.clock()
			local grow = math.min(a * 8, 1) -- the column rises over the first ~1/8 of the pull
			core.Size = Vector3.new(height * grow, 2.5 + 2 * a, 2.5 + 2 * a)
			core.CFrame = CFrame.new(base + Vector3.new(0, height * grow / 2, 0)) * CFrame.Angles(t * 5, 0, math.pi / 2)
			l.Brightness = 4 + 3 * a
			for i, m in motes do
				local ang = t * (4 + 3 * a) + i * (math.pi * 2 / #motes)
				local rad = r * (0.8 - 0.55 * a) * (0.7 + 0.3 * ((i % 3) / 2))
				local rise = (((t * 6 + i * 3) % height) / height) * height * 0.9
				m.CFrame = CFrame.new(base + Vector3.new(math.cos(ang) * rad, 1 + rise, math.sin(ang) * rad))
			end
		end, function()
			column.Enabled = false
			smoke.Enabled = false
			for _, m in motes do
				for _, c in m:GetChildren() do
					if c:IsA("ParticleEmitter") then
						c.Enabled = false
					end
				end
				m:Destroy()
			end
			core:Destroy()
			Debris:AddItem(anchor, 2.2)
		end)
	end)

	-- Cryo Bomb: frost disc, ice spikes, ice tint (Highlight) on enemies whose FrozenUntil lies ahead
	Fx.register("CryoFreeze", function(d)
		local p: Vector3, r: number, dur: number = d.p, d.r or 14, d.t or 4
		local frost = mkPart({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.2, r * 0.6, r * 0.6),
			Color = Color3.fromRGB(205, 240, 255),
			Material = Enum.Material.Ice,
			Transparency = 0.25,
			CFrame = CFrame.new(p + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		})
		tween(frost, 0.25, { Size = Vector3.new(0.2, r * 2, r * 2) })
		task.delay(dur, function()
			tween(frost, 1, { Transparency = 1 })
		end)
		Debris:AddItem(frost, dur + 1.1)
		for _ = 1, qn(9) do
			local ang = math.random() * math.pi * 2
			local rad = math.sqrt(math.random()) * r * 0.85
			local base = p + Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)
			local h = rand(2.5, 6)
			local w = rand(0.8, 1.6)
			local tilt = CFrame.Angles(rand(-0.35, 0.35), rand(0, 6.28), rand(-0.35, 0.35))
			local spike = mkPart({
				Size = Vector3.new(w, 0.2, w),
				Color = Color3.fromRGB(190, 235, 255),
				Material = Enum.Material.Ice,
				Transparency = 0.15,
				CFrame = CFrame.new(base) * tilt,
			})
			tween(spike, 0.14, { Size = Vector3.new(w, h, w), CFrame = CFrame.new(base) * tilt * CFrame.new(0, h * 0.35, 0) }, Enum.EasingStyle.Back)
			task.delay(dur + rand(0, 0.4), function()
				if spike.Parent then
					tween(spike, 0.5, { Transparency = 1, Size = Vector3.new(w * 0.5, h * 0.4, w * 0.5) })
				end
			end)
			Debris:AddItem(spike, dur + 1.1)
		end
		ring(p, ICE, 2, r * 1.15, 0.45, 0.4)
		snd("EMPPulse", p)
		punch(ICE, 1, 1.1, -0.5, p)
		flashAt(Color3.fromRGB(225, 245, 255), 0.4, 0.35, p)

		-- ice tint on the frozen enemies (FrozenUntil replicates with the model)
		task.delay(0.12, function()
			local ef = workspace:FindFirstChild("Enemies")
			if not ef then
				return
			end
			local now = workspace:GetServerTimeNow()
			for _, m in ef:GetChildren() do
				if liveHighlights >= HIGHLIGHT_CAP then
					break
				end
				local fu = m:GetAttribute("FrozenUntil")
				local pp = m:IsA("Model") and m.PrimaryPart
				if pp and type(fu) == "number" and fu > now and (pp.Position - p).Magnitude < r + 8 and not m:FindFirstChild("CryoTint") then
					local hl = Instance.new("Highlight")
					hl.Name = "CryoTint"
					hl.FillColor = Color3.fromRGB(150, 220, 255)
					hl.FillTransparency = 0.3
					hl.OutlineColor = Color3.fromRGB(235, 250, 255)
					hl.OutlineTransparency = 0.2
					hl.DepthMode = Enum.HighlightDepthMode.Occluded
					hl.Adornee = m
					hl.Parent = m
					liveHighlights += 1
					local life = math.max(fu - now, 0.2)
					task.delay(life, function()
						liveHighlights -= 1
						if hl.Parent then
							tween(hl, 0.25, { FillTransparency = 1, OutlineTransparency = 1 })
							Debris:AddItem(hl, 0.3)
						end
					end)
				end
			end
		end)
	end)

	-- Shatter: a frozen enemy took a blast; ice shards fly off
	Fx.register("Shatter", function(d)
		local p: Vector3 = d.p
		if typeof(p) ~= "Vector3" or camDist(p) > 260 then
			return
		end
		local shards = {}
		for i = 1, qn(6) do
			local s = mkPart({
				Size = Vector3.new(rand(0.3, 0.7), rand(0.6, 1.4), rand(0.3, 0.6)),
				Color = Color3.fromRGB(200, 240, 255),
				Material = Enum.Material.Ice,
				Transparency = 0.1,
				CFrame = CFrame.new(p + Vector3.new(0, 1.5, 0)),
			})
			shards[i] = { part = s, v = Vector3.new(rand(-14, 14), rand(10, 22), rand(-14, 14)), rx = rand(-8, 8), ry = rand(-8, 8) }
		end
		snd("HitPartial", p)
		animate(0.7, function(a, dt)
			for _, sh in shards do
				sh.v -= Vector3.new(0, 70 * dt, 0)
				sh.part.CFrame = (sh.part.CFrame + sh.v * dt) * CFrame.Angles(sh.rx * dt, sh.ry * dt, 0)
				sh.part.Transparency = 0.1 + 0.9 * a
			end
		end, function()
			for _, sh in shards do
				sh.part:Destroy()
			end
		end)
	end)

	-- Railshot: targeting laser + shrinking reticle while it charges, then one beam from orbit
	Fx.register("Railshot", function(d)
		local p: Vector3, charge: number = d.p, math.max(d.t or 0.9, 0.1)
		local H = 600
		local laser = mkPart({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(H, 0.12, 0.12),
			Color = Color3.fromRGB(255, 70, 70),
			Transparency = 0.2,
			CFrame = CFrame.new(p + Vector3.new(0, H / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		})
		local ret = mkPart({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.1, 12, 12),
			Color = Color3.fromRGB(255, 80, 80),
			Transparency = 0.6,
			CFrame = CFrame.new(p + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		})
		snd("LanceCharge", p)
		animate(charge, function(a)
			local w = 0.12 + 0.25 * a
			laser.Size = Vector3.new(H, w, w)
			laser.Transparency = if math.floor(os.clock() * 24) % 2 == 0 then 0.15 else 0.45
			local s = 12 * (1 - a) + 1.2
			ret.Size = Vector3.new(0.1, s, s)
		end, function()
			laser:Destroy()
			ret:Destroy()
			local beam = mkPart({
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(H, 3.2, 3.2),
				Color = Color3.fromRGB(235, 250, 255),
				Transparency = 0,
				CFrame = CFrame.new(p + Vector3.new(0, H / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
			})
			local glow = mkPart({
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(H, 7, 7),
				Color = RAIL,
				Transparency = 0.55,
				CFrame = beam.CFrame,
			})
			light(beam, RAIL, 40, 6)
			tween(beam, 0.3, { Size = Vector3.new(H, 0.1, 0.1) })
			tween(glow, 0.4, { Size = Vector3.new(H, 0.2, 0.2), Transparency = 1 })
			Debris:AddItem(beam, 0.35)
			Debris:AddItem(glow, 0.45)
			snd("ShotRail", p)
			ring(p, RAIL, 1, 9, 0.35, 0.3)
			orbitalMini(p, 0.8, RAIL)
			trauma(2.2, 0.45, p, 110)
			punch(RAIL, 1, 0.55, 0.5, p)
			flashAt(Color3.fromRGB(240, 252, 255), 0.6, 0.25, p)
		end)
	end)

	-- Firestorm Line: fire patches ignite along a -> b at the jet's pace, burn for t, then die down
	Fx.register("Firestorm", function(d)
		local a: Vector3, b: Vector3 = d.a, d.b
		local w: number, dur: number = d.w or 7, d.t or 10
		local n: number = math.max(math.floor((d.n or 8) * math.clamp(quality(), 0.5, 1) + 0.5), 3)
		local sweep: number = d.s or 0.2
		local seg = b - a
		local len = seg.Magnitude
		if len < 0.5 then
			return
		end
		local dir = seg / len
		local piece = len / n
		local loop = nil
		local scorch = mkPart({
			Size = Vector3.new(w, 0.08, len),
			Color = Color3.fromRGB(30, 22, 18),
			Material = Enum.Material.SmoothPlastic,
			Transparency = 1,
			CFrame = CFrame.lookAt((a + b) / 2 + Vector3.new(0, 0.06, 0), (a + b) / 2 + Vector3.new(0, 0.06, 0) + dir),
		})
		tween(scorch, sweep + 0.3, { Transparency = 0.35 })
		task.delay(dur + sweep, function()
			tween(scorch, 4, { Transparency = 1 }, Enum.EasingStyle.Linear)
		end)
		Debris:AddItem(scorch, dur + sweep + 4.2)
		for i = 1, n do
			task.delay((i - 0.5) / n * sweep, function()
				local c = a + dir * (piece * (i - 0.5))
				local anchor = mkPart({
					Size = Vector3.new(w, 1, piece),
					Transparency = 1,
					CFrame = CFrame.lookAt(c + Vector3.new(0, 0.6, 0), c + Vector3.new(0, 0.6, 0) + dir),
				})
				local fire = emitter(anchor, {
					Texture = TEX_FIRE,
					Color = ColorSequence.new(Color3.fromRGB(255, 225, 120), Color3.fromRGB(255, 90, 30)),
					Size = seq(2.2, 3.2, 0.6),
					Transparency = seq(0.15, 0.35, 1),
					Lifetime = NumberRange.new(0.6, 1.1),
					Speed = NumberRange.new(4, 9),
					SpreadAngle = Vector2.new(12, 12),
					EmissionDirection = Enum.NormalId.Top,
					Rate = 14 * quality() + 4,
					LightEmission = 0.9,
					Rotation = NumberRange.new(0, 360),
					RotSpeed = NumberRange.new(-90, 90),
					Shape = Enum.ParticleEmitterShape.Box,
					ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
				})
				local smoke = emitter(anchor, {
					Texture = TEX_SMOKE,
					Color = ColorSequence.new(Color3.fromRGB(60, 50, 45)),
					Size = seq(2.5, 6),
					Transparency = seq(0.55, 1),
					Lifetime = NumberRange.new(1.6, 2.4),
					Speed = NumberRange.new(5, 8),
					EmissionDirection = Enum.NormalId.Top,
					Rate = 3 * quality() + 1,
					Shape = Enum.ParticleEmitterShape.Box,
				})
				if i % 3 == 1 then
					light(anchor, FIRE, w * 2.2, 2.5)
				end
				if i == 1 then
					loop = loopAt("GasHiss", anchor, c)
				end
				local burst = mkPart({ Shape = Enum.PartType.Ball, Size = Vector3.one * w * 0.6, Color = Color3.fromRGB(255, 190, 80), Transparency = 0.15, CFrame = CFrame.new(c + Vector3.new(0, 1, 0)) })
				tween(burst, 0.3, { Size = Vector3.one * w * 1.4, Transparency = 1 })
				Debris:AddItem(burst, 0.35)
				task.delay(dur, function()
					fire.Enabled = false
					smoke.Enabled = false
					if i == 1 then
						stopLoop(loop)
					end
				end)
				Debris:AddItem(anchor, dur + 2.6)
			end)
		end
		local mid = (a + b) / 2
		snd("ExplosionSmall", mid)
		trauma(1.2, 0.5, mid, 90)
		punch(FIRE, 0.6, 0.6, 0.3, mid)
		flashAt(Color3.fromRGB(255, 200, 140), 0.3, 0.25, mid)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Overwatch Skiff: a simple Skiff hull flown along shared/OverwatchPath (the server fires the door gun from the same path;
-- the rounds themselves are drawn by Fx "SkiffGun" in SkiffFx). One model per call-in, destroyed when it has flown out.
-- ---------------------------------------------------------------------------------------------
type OverwatchRec = { model: Model, conn: RBXScriptConnection, loop: any }
local overwatches: { [any]: OverwatchRec } = {}

local function stopOverwatch(id: any)
	local rec = overwatches[id]
	if not rec then
		return
	end
	overwatches[id] = nil
	rec.conn:Disconnect()
	stopLoop(rec.loop)
	rec.model:Destroy()
end

local function buildOverwatchSkiff(): (Model, Part)
	local white, orange = Color3.fromRGB(226, 228, 236), Color3.fromRGB(235, 120, 40)
	local grey, dark = Color3.fromRGB(180, 184, 196), Color3.fromRGB(44, 48, 58)
	local glow = Color3.fromRGB(120, 200, 255)
	local cyl = Enum.PartType.Cylinder
	local spec = {
		{ size = Vector3.new(11, 5.5, 22), cf = CFrame.new(), color = white, material = Enum.Material.SmoothPlastic }, -- hull (pivot)
		{ size = Vector3.new(10, 4, 7), cf = CFrame.new(0, -0.6, -14) * CFrame.Angles(math.rad(10), 0, 0), color = white, material = Enum.Material.SmoothPlastic },
		{ size = Vector3.new(8, 2.6, 5), cf = CFrame.new(0, 2.6, -11.5) * CFrame.Angles(math.rad(-24), 0, 0), color = glow, material = Enum.Material.Glass, transparency = 0.25 },
		{ size = Vector3.new(0.3, 1.4, 22), cf = CFrame.new(-5.6, 0.4, 0), color = orange, material = Enum.Material.SmoothPlastic },
		{ size = Vector3.new(0.3, 1.4, 22), cf = CFrame.new(5.6, 0.4, 0), color = orange, material = Enum.Material.SmoothPlastic },
		-- door guns
		{ size = Vector3.new(0.8, 0.8, 3.2), cf = CFrame.new(-6.6, -2.2, -3.2), color = dark },
		{ size = Vector3.new(0.8, 0.8, 3.2), cf = CFrame.new(6.6, -2.2, -3.2), color = dark },
	}
	for _, s in { -1, 1 } do
		table.insert(spec, { size = Vector3.new(11, 0.8, 9), cf = CFrame.new(s * 11, -0.6, 3) * CFrame.Angles(0, s * math.rad(-12), s * math.rad(5)), color = grey })
		table.insert(spec, { shape = cyl, size = Vector3.new(12, 5, 5), cf = CFrame.new(s * 14, 0.4, 4) * CFrame.Angles(0, math.pi / 2, 0), color = Color3.fromRGB(88, 94, 108) })
		table.insert(spec, { shape = cyl, size = Vector3.new(0.6, 4.2, 4.2), cf = CFrame.new(s * 14, 0.4, 10.3) * CFrame.Angles(0, math.pi / 2, 0), color = glow, material = Enum.Material.Neon })
		table.insert(spec, { shape = Enum.PartType.Ball, size = Vector3.new(1.2, 1.2, 1.2), cf = CFrame.new(s * 17, -0.2, 0), color = if s < 0 then Color3.fromRGB(255, 50, 50) else Color3.fromRGB(70, 255, 120), material = Enum.Material.Neon })
	end
	local model, root = buildModel(spec)
	light(root, Color3.fromRGB(255, 215, 170), 40, 1.2)
	return model, root
end

local function registerOverwatch(Fx: any)
	Fx.register("OverwatchSkiff", function(d)
		if type(d) ~= "table" or typeof(d.c) ~= "Vector3" or type(d.r) ~= "number" or type(d.d) ~= "number" or type(d.t0) ~= "number" then
			return
		end
		stopOverwatch(d.id)
		local centre: Vector3, radius: number, duration: number = d.c, d.r, d.d
		local total = OverwatchPath.total(duration)
		local tau0 = math.max(workspace:GetServerTimeNow() - d.t0, 0)
		if tau0 >= total then
			return
		end
		local model, root = buildOverwatchSkiff()
		model:PivotTo((OverwatchPath.cframe(centre, radius, duration, tau0)))
		local recv = os.clock()
		local conn = animate(total - tau0, function()
			model:PivotTo((OverwatchPath.cframe(centre, radius, duration, tau0 + os.clock() - recv)))
		end, function()
			stopOverwatch(d.id)
		end)
		overwatches[d.id] = { model = model, conn = conn, loop = loopAt("SkiffEngine", root) }
	end)
	Fx.register("OverwatchEnd", function(d)
		if type(d) == "table" then
			stopOverwatch(d.id)
		end
	end)
end

function CallInFx.init(Fx: any, audio: any, juice: any)
	Audio = audio
	Juice = juice
	registerBeacon(Fx)
	registerLance(Fx)
	registerFalling(Fx)
	registerJet(Fx)
	registerOverwatch(Fx)
	registerClouds(Fx)
	registerPods(Fx)
	FxRef = Fx
	local okS, mod = pcall(require, script.Parent:FindFirstChild("Spectacle"))
	if okS and type(mod) == "table" then
		SpectacleRef = mod
	end
	registerNew(Fx)
end

return CallInFx
