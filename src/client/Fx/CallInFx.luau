-- Client renderers for the call-in system (server: src/server/CallIns/*).
-- Fx kinds: Beacon, BeaconEnd, LanceStart/Move/End, Bomb, Jet, Shell, Gas, Smoke, Dome, DropPod, Crater.
-- Everything lives in workspace.CurrentCamera.CallInFx (local only, no collisions, auto-cleaned).
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

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
type BeaconRec = { model: Model, conn: RBXScriptConnection, loop: any, light: PointLight, parts: { Part } }
local beacons: { [any]: BeaconRec } = {}

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
	tween(b.light, 0.45, { Brightness = 0 })
	Debris:AddItem(b.model, 0.6)
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
		local HEIGHT = 700
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
		local lamp = light(base, main, 30, 3)
		emitter(base, {
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
		local nextRing = 0
		local conn = RunService.RenderStepped:Connect(function()
			local t = os.clock() - t0
			local k = 0.5 + 0.5 * math.sin(t * 7)
			column.Transparency = 0.45 + 0.2 * k
			column.Size = Vector3.new(1.2 + 0.4 * k, HEIGHT, 1.2 + 0.4 * k)
			halo.Size = Vector3.new(3 + 1.2 * k, HEIGHT, 3 + 1.2 * k)
			lamp.Brightness = 2 + 2 * k
			if t >= nextRing then
				nextRing = t + 0.9
				ring(pos, main, 1, 7, 0.9)
			end
			if t > 40 then
				endBeacon(d.id)
			end
		end)

		snd("ShipRadio", pos)
		local loop = loopAt("BeaconPing", pos, pos)
		if d.callin == "LANCE" then
			snd("LanceCharge", pos)
		end
		beacons[d.id] = { model = model, conn = conn, loop = loop, light = lamp, parts = { base, column, core, halo } }
	end)

	Fx.register("BeaconEnd", function(d)
		endBeacon(d.id)
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
function CallInFx.init(Fx: any, audio: any, juice: any)
	Audio = audio
	Juice = juice
	registerBeacon(Fx)
	registerLance(Fx)
	registerFalling(Fx)
	registerJet(Fx)
	registerClouds(Fx)
	registerPods(Fx)
end

return CallInFx
