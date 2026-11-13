--!nonstrict
-- Dismemberment visuals (client). Server: server/Enemies/Dismember.luau, data: Shared/Data/Limbs.
-- Fx "Dismember" {id, part, parts: {string}, stump, p, v, f = "COG"|"BROOD", k = kind}:
--   * hides the limb sub-tree on the live model (the server also sets Transparency 1, this just avoids a frame of lag);
--   * flings an anchored clone of the limb (sub-tree kept rigid) with spin, hand-simulated vs the ground like the
--     shell casings in GunFeel (ray per step, bounce, settle, fade). No network physics.
--     Cap: 24 live pieces (10 on low quality), each lives 4-6 s, oldest goes first;
--   * robots: sparks + oily smoke puff + a few bolts, and a spark/oil sputter on the stump for 3 s;
--     bugs: cartoon green goo puff + splat + chunky shell chips, short goo drip on the stump;
--   * limp: models that lost legs get their Body Motor6D leaned towards the missing side (bipeds hop-limp while moving).
--     Applied in PreSimulation on top of whatever EnemyAnim wrote in RenderStepped this frame.
-- The death break-up (EnemyAnim) only clones visible parts, so a lost limb is never duplicated there.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EnemyData = require(Shared.Data.Enemies)
local Limbs = require(Shared.Data.Limbs)

local DismemberFx = {}

local Fx, Audio
local rng = Random.new()

local function rnd(a: number, b: number): number
	return a + (b - a) * rng:NextNumber()
end

local function quality(): number
	return if Fx and type(Fx.quality) == "number" then Fx.quality else 1
end

-- -------------------------------------------------------------------------------------------
-- Model lookup
-- -------------------------------------------------------------------------------------------
local function findModel(id: number): Model?
	local folder = workspace:FindFirstChild("Enemies")
	if not folder then
		return nil
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("EnemyId") == id then
			return m
		end
	end
	return nil
end

-- -------------------------------------------------------------------------------------------
-- Flung pieces (hand-simulated)
-- -------------------------------------------------------------------------------------------
type Piece = {
	parts: { BasePart },
	rel: { CFrame }, -- each part relative to the piece pivot
	baseT: { number },
	pos: Vector3,
	vel: Vector3,
	rot: CFrame,
	axis: Vector3,
	spin: number,
	r: number, -- contact radius
	t: number,
	life: number,
	fadeFrom: number,
	settled: boolean,
	bounced: boolean,
	brood: boolean,
}

local pieces: { Piece } = {}
local simConn: RBXScriptConnection? = nil
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local nextFilter = 0

local function maxPieces(): number
	return if quality() < 0.6 then 10 else 24
end

local function refreshFilter()
	local list: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	if Fx and Fx.folder then
		table.insert(list, Fx.folder)
	end
	local en = workspace:FindFirstChild("Enemies")
	if en then
		table.insert(list, en)
	end
	local audio = workspace:FindFirstChild("ClientAudio")
	if audio then
		table.insert(list, audio)
	end
	rayParams.FilterDescendantsInstances = list
end

local function killPiece(i: number)
	local pc = pieces[i]
	for _, p in pc.parts do
		if p.Parent then
			p:Destroy()
		end
	end
	table.remove(pieces, i)
end

local function placePiece(pc: Piece)
	local cf = CFrame.new(pc.pos) * pc.rot
	for k, p in pc.parts do
		p.CFrame = cf * pc.rel[k]
	end
end

local function onLand(pc: Piece, at: Vector3)
	if not Audio then
		return
	end
	if pc.brood then
		Audio.play("HitGoo", at, { volume = 0.45, pitch = rnd(0.75, 0.95), priority = 1 })
		if Fx and Fx.splat and quality() >= 0.5 then
			Fx.splat(at, rnd(1.2, 2), Color3.fromRGB(110, 225, 70))
		end
	else
		Audio.play("HitMetal", at, { volume = 0.5, pitch = rnd(0.55, 0.75), priority = 1 })
	end
end

local function simStep(dt: number)
	local now = os.clock()
	if now >= nextFilter then
		nextFilter = now + 1
		refreshFilter()
	end
	dt = math.min(dt, 0.05)
	local g = workspace.Gravity * 0.55
	for i = #pieces, 1, -1 do
		local pc = pieces[i]
		pc.t += dt
		if pc.t >= pc.life or not pc.parts[1].Parent then
			killPiece(i)
			continue
		end
		if pc.t > pc.fadeFrom then
			local a = math.clamp((pc.t - pc.fadeFrom) / (pc.life - pc.fadeFrom), 0, 1)
			for k, p in pc.parts do
				p.Transparency = pc.baseT[k] + (1 - pc.baseT[k]) * a
			end
		end
		if pc.settled then
			continue
		end
		pc.vel += Vector3.new(0, -g * dt, 0)
		local step = pc.vel * dt
		local hit = if step.Magnitude > 1e-4 then workspace:Raycast(pc.pos, step + step.Unit * pc.r, rayParams) else nil
		if hit then
			local n = hit.Normal
			pc.pos = hit.Position + n * pc.r
			local v = pc.vel
			local vn = v:Dot(n)
			if vn < -4 and not pc.bounced then
				pc.bounced = true
				onLand(pc, hit.Position)
			end
			-- bounce: tangential friction + a little restitution; chunky pieces tumble on
			v = (v - n * vn) * 0.6 - n * vn * 0.3
			pc.vel = v
			pc.spin *= 0.55
			-- tumble: tip the spin axis towards the rolling direction
			local roll = if v.Magnitude > 0.1 then n:Cross(v.Unit) else Vector3.zero
			local ax = pc.axis + roll * 0.5
			if ax.Magnitude > 0.05 then
				pc.axis = ax.Unit
			end
			if v.Magnitude < 2.5 then
				pc.settled = true
			end
		else
			pc.pos += step
		end
		pc.rot = CFrame.fromAxisAngle(pc.axis, pc.spin * dt) * pc.rot
		placePiece(pc)
	end
	if #pieces == 0 and simConn then
		simConn:Disconnect()
		simConn = nil
	end
end

local KEEP_CHILD = { SpecialMesh = true, SurfaceAppearance = true, Decal = true, Texture = true }

local function cloneVisual(src: BasePart): BasePart?
	local ok, c = pcall(function()
		return src:Clone()
	end)
	if not ok or not c then
		return nil
	end
	for _, ch in c:GetChildren() do
		if not KEEP_CHILD[ch.ClassName] then
			ch:Destroy()
		end
	end
	for name in c:GetAttributes() do
		c:SetAttribute(name, nil)
	end
	c.Anchored = true
	c.CanCollide = false
	c.CanQuery = false
	c.CanTouch = false
	c.Massless = true
	c.CastShadow = quality() >= 0.75
	local t0 = src:GetAttribute("LostT")
	c.Transparency = if type(t0) == "number" then t0 elseif src.Transparency < 0.99 then src.Transparency else 0
	return c
end

local function oilTrail(part: BasePart)
	local att = Instance.new("Attachment")
	att.Parent = part
	local em = Instance.new("ParticleEmitter")
	em.Texture = "rbxasset://textures/particles/smoke_main.dds"
	em.Color = ColorSequence.new(Color3.fromRGB(70, 66, 62), Color3.fromRGB(30, 30, 32))
	em.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1.8) })
	em.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
	em.Lifetime = NumberRange.new(0.4, 0.8)
	em.Speed = NumberRange.new(0.5, 2)
	em.Acceleration = Vector3.new(0, 4, 0)
	em.Rate = 22 * quality()
	em.RotSpeed = NumberRange.new(-60, 60)
	em.Parent = att
	task.delay(1.4, function()
		if em.Parent then
			em.Enabled = false
		end
	end)
end

local function spawnPiece(model: Model, names: { string }, mainName: string, vel: Vector3, brood: boolean)
	local main = model:FindFirstChild(mainName)
	if not (main and main:IsA("BasePart")) then
		return
	end
	local pivot = main.CFrame
	local parts: { BasePart } = {}
	local rel: { CFrame } = {}
	local baseT: { number } = {}
	for _, n in names do
		local src = model:FindFirstChild(n)
		if src and src:IsA("BasePart") then
			local c = cloneVisual(src)
			if c then
				-- main part first: pieces[i].parts[1] is the liveness check
				local at = if n == mainName then 1 else #parts + 1
				table.insert(parts, at, c)
				table.insert(rel, at, pivot:Inverse() * src.CFrame)
				table.insert(baseT, at, c.Transparency)
			end
		end
	end
	if #parts == 0 then
		return
	end
	while #pieces >= maxPieces() do
		killPiece(1)
	end
	local s = main.Size
	local life = rnd(4, 6) * (if quality() < 0.6 then 0.8 else 1)
	local pc: Piece = {
		parts = parts,
		rel = rel,
		baseT = baseT,
		pos = pivot.Position,
		vel = vel + Vector3.new(rnd(-3, 3), rnd(0, 4), rnd(-3, 3)),
		rot = pivot.Rotation,
		axis = Vector3.new(rnd(-1, 1), rnd(-0.4, 0.4), rnd(-1, 1)).Unit,
		spin = rnd(7, 15) * (if rng:NextNumber() < 0.5 then -1 else 1),
		r = math.max(math.min(s.X, s.Y, s.Z) * 0.45, 0.15),
		t = 0,
		life = life,
		fadeFrom = life - 0.8,
		settled = false,
		bounced = false,
		brood = brood,
	}
	if pc.axis ~= pc.axis then -- NaN guard
		pc.axis = Vector3.xAxis
	end
	for _, c in parts do
		c.Parent = Fx.folder
	end
	placePiece(pc)
	if not brood and quality() >= 0.6 then
		oilTrail(parts[1])
	end
	table.insert(pieces, pc)
	if not simConn then
		nextFilter = 0
		simConn = RunService.Heartbeat:Connect(simStep)
	end
end

-- -------------------------------------------------------------------------------------------
-- Stump sputter
-- -------------------------------------------------------------------------------------------
local liveStumps = 0

local function stumpFx(model: Model, stumpName: string, mainName: string, brood: boolean)
	local cap = if quality() < 0.6 then 4 else 12
	if liveStumps >= cap then
		return
	end
	local stump = model:FindFirstChild(stumpName)
	local main = model:FindFirstChild(mainName)
	if not (stump and stump:IsA("BasePart") and main) then
		return
	end
	local motor = main:FindFirstChild(mainName)
	local att = Instance.new("Attachment")
	att.Name = "DismemberStump"
	att.CFrame = if motor and motor:IsA("Motor6D") then motor.C0 else stump.CFrame:ToObjectSpace(main.CFrame)
	att.Parent = stump
	local q = quality()
	if brood then
		local drip = Instance.new("ParticleEmitter")
		drip.Color = ColorSequence.new(Color3.fromRGB(170, 255, 110), Color3.fromRGB(70, 180, 50))
		drip.LightEmission = 0.2
		drip.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0.1) })
		drip.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 0.6) })
		drip.Lifetime = NumberRange.new(0.35, 0.6)
		drip.Speed = NumberRange.new(1, 4)
		drip.SpreadAngle = Vector2.new(40, 40)
		drip.Acceleration = Vector3.new(0, -45, 0)
		drip.Rate = 12 * q
		drip.Parent = att
	else
		local sp = Instance.new("ParticleEmitter")
		sp.Color = ColorSequence.new(Color3.fromRGB(255, 240, 170), Color3.fromRGB(255, 130, 30))
		sp.LightEmission = 1
		sp.LightInfluence = 0
		sp.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.22), NumberSequenceKeypoint.new(1, 0) })
		sp.Lifetime = NumberRange.new(0.15, 0.4)
		sp.Speed = NumberRange.new(8, 18)
		sp.SpreadAngle = Vector2.new(60, 60)
		sp.Acceleration = Vector3.new(0, -60, 0)
		sp.Drag = 2
		sp.Rate = 0
		sp.Parent = att
		if q >= 0.6 then
			local sm = Instance.new("ParticleEmitter")
			sm.Texture = "rbxasset://textures/particles/smoke_main.dds"
			sm.Color = ColorSequence.new(Color3.fromRGB(60, 58, 56), Color3.fromRGB(28, 28, 30))
			sm.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1.6) })
			sm.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
			sm.Lifetime = NumberRange.new(0.6, 1.1)
			sm.Speed = NumberRange.new(1, 3)
			sm.Acceleration = Vector3.new(0, 4, 0)
			sm.Rate = 5 * q
			sm.Parent = att
		end
		-- sputter: short irregular spark spits instead of a steady stream
		task.spawn(function()
			local t = 0
			while t < 3 and sp.Parent do
				sp:Emit(math.max(1, math.floor(rnd(2, 6) * q + 0.5)))
				local w = rnd(0.08, 0.3)
				task.wait(w)
				t += w
			end
		end)
	end
	liveStumps += 1
	task.delay(if brood then 2 else 3, function()
		for _, em in att:GetChildren() do
			if em:IsA("ParticleEmitter") then
				em.Enabled = false
			end
		end
		task.wait(1.2)
		liveStumps -= 1
		if att.Parent then
			att:Destroy()
		end
	end)
end

-- -------------------------------------------------------------------------------------------
-- Limp (Body motor lean)
-- -------------------------------------------------------------------------------------------
type Limp = {
	model: Model,
	motor: Motor6D,
	root: BasePart,
	biped: boolean,
	lean: number, -- signed: + leans to the left (-X) side
	legsLost: number,
	drop: number, -- static sink (biped with no legs left)
	speed: number,
	phase: number,
	lastPos: Vector3,
	base: CFrame,
	written: CFrame?,
}
local limps: { [Model]: Limp } = {}
local limpConn: RBXScriptConnection? = nil

local function limpStep(dt: number)
	if dt <= 0 then
		return
	end
	local cam = workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	for model, st in limps do
		if not model.Parent or not st.motor.Parent then
			limps[model] = nil
			continue
		end
		local pos = st.root.Position
		local d = pos - st.lastPos
		st.lastPos = pos
		if (pos - camPos).Magnitude > 160 then
			continue
		end
		local m = st.motor
		local base = m.Transform
		if st.written and base == st.written then
			base = st.base -- EnemyAnim did not write this frame (far / culled): do not stack the lean
		end
		st.base = base
		local v = Vector3.new(d.X, 0, d.Z).Magnitude / dt
		local move = math.clamp(v / math.max(st.speed * 0.5, 1), 0, 1)
		st.phase += dt * math.clamp(v * 0.9, 0, 14)
		local hop = math.abs(math.sin(st.phase))
		local roll, dip
		if st.biped then
			roll = st.lean * (0.1 + 0.18 * hop * move)
			dip = -st.drop - 0.35 * hop * move
		else
			roll = st.lean * (0.05 + 0.04 * hop * move)
			dip = -0.08 * st.legsLost
		end
		local w = base * CFrame.new(0, dip, 0) * CFrame.Angles(0, 0, roll)
		m.Transform = w
		st.written = w
	end
	if next(limps) == nil and limpConn then
		limpConn:Disconnect()
		limpConn = nil
	end
end

local function addLimp(model: Model, kind: string, mainName: string)
	local limb = Limbs.find(kind, mainName)
	if not (limb and limb.leg) then
		return
	end
	local info = Limbs.info(kind)
	local body = model:FindFirstChild("Body")
	local motor = body and body:FindFirstChild("Body")
	local root = model.PrimaryPart or model:FindFirstChild("Root")
	if not (motor and motor:IsA("Motor6D") and root and root:IsA("BasePart")) then
		return
	end
	local st = limps[model]
	if not st then
		local def = EnemyData.get(kind)
		st = {
			model = model,
			motor = motor,
			root = root,
			biped = info ~= nil and info.biped == true,
			lean = 0,
			legsLost = 0,
			drop = 0,
			speed = if def then def.speed else 10,
			phase = 0,
			lastPos = root.Position,
			base = motor.Transform,
			written = nil,
		}
		limps[model] = st
	end
	st.legsLost += 1
	local side = if limb.leg == "L" then 1 else -1
	st.lean = math.clamp(st.lean + side * (if st.biped then 1 else 0.5), -1.5, 1.5)
	if st.biped and st.legsLost >= 2 then
		-- both legs gone: sit down on the hips
		local main = model:FindFirstChild(mainName)
		st.drop = if main and main:IsA("BasePart") then main.Size.Y * 1.6 else 1.5
		st.lean = 0
	end
	if not limpConn then
		limpConn = RunService.PreSimulation:Connect(limpStep)
	end
end

-- -------------------------------------------------------------------------------------------
-- Handler
-- -------------------------------------------------------------------------------------------
local BOLT_COLORS = { Color3.fromRGB(96, 110, 132), Color3.fromRGB(60, 64, 74), Color3.fromRGB(217, 100, 43) }
local SHELL_COLORS = { Color3.fromRGB(98, 56, 132), Color3.fromRGB(58, 34, 82), Color3.fromRGB(104, 70, 48), Color3.fromRGB(44, 134, 134) }

local function burstFx(p: Vector3, brood: boolean, big: boolean)
	local s = if big then 1.6 else 1
	if brood then
		Fx.burst("goo", p, 12 * s, { scale = 0.8 * s })
		Fx.burst("puff", p, 4, { color = Color3.fromRGB(150, 235, 100), scale = 0.8 * s })
		Fx.debris(p, { n = 4, style = "rock", scale = 0.45 * s, speed = 22, up = 1.2, life = 2, palette = SHELL_COLORS })
		Audio.play("HitGoo", p, { volume = 0.8, pitch = rnd(0.75, 0.9) })
		Audio.play("AcidSplat", p, { volume = 0.35, pitch = rnd(1.2, 1.4) })
	else
		Fx.burst("sparks", p, 16 * s, { scale = s })
		Fx.burst("smoke", p, 3, { color = Color3.fromRGB(46, 44, 42), scale = 0.45 * s })
		Fx.debris(p, { n = 4, style = "scrap", scale = 0.35 * s, speed = 26, up = 1.2, life = 2, palette = BOLT_COLORS })
		Audio.play("HitMetal", p, { volume = 0.8, pitch = rnd(0.6, 0.75) })
		Audio.play("DeathScrap", p, { volume = 0.3, pitch = rnd(1.4, 1.6) })
	end
end

local function onDismember(d: any)
	if type(d) ~= "table" or typeof(d.p) ~= "Vector3" then
		return
	end
	local brood = d.f == "BROOD"
	local def = EnemyData.get(d.k or "")
	local big = def ~= nil and (def.class == "heavy" or def.class == "behemoth")
	local far = Fx.camDistance(d.p) > 220
	local model = if type(d.id) == "number" then findModel(d.id) else nil
	local names: { string } = if type(d.parts) == "table" then d.parts else { d.part }
	if model then
		if not far and type(d.part) == "string" then
			spawnPiece(model, names, d.part, if typeof(d.v) == "Vector3" then d.v else Vector3.new(0, 15, 0), brood)
		end
		-- hide after cloning (the server does the same; this just beats replication)
		for _, n in names do
			local p = model:FindFirstChild(n)
			if p and p:IsA("BasePart") then
				p.Transparency = 1
			end
		end
		if type(d.part) == "string" then
			if not far and type(d.stump) == "string" then
				stumpFx(model, d.stump, d.part, brood)
			end
			addLimp(model, d.k or "", d.part)
		end
	end
	if not far then
		burstFx(d.p, brood, big)
	end
end

function DismemberFx.init(fx: any, audio: any, _juice: any)
	Fx = fx
	Audio = audio
	Fx.register("Dismember", onDismember)
end

return DismemberFx
