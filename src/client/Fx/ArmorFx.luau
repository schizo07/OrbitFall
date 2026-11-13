--!nonstrict
-- Being-hit feedback + idle life on the local player's TrooperArmor (server/TrooperArmor.luau; parts Visor, Backpack, Thruster_L/R).
--   Fx "Hurt" {amount = % of max hp, from = attacker position?} (a second handler next to Main.client's vignette/shake/sound):
--     * 0.12 s warm->red Highlight flash over the whole character (one reusable Highlight)
--     * 4-6 orange sparks + 2-3 plate chips (Fx.debris, quality >= 0.6) and a grey puff on the hit side
--     * hits >= 15 % hp: shoulder stagger (local Waist.C0 spring, twists away from the hit) + small camera kick
--     * visor flicker (red strobe, 0.25 s)
--     * screen-edge directional damage indicator (pooled, 4 slots, follows the camera yaw while it fades)
--   Low health (< 30 %): visor blinks red slowly, dark smoke wisps rise from the backpack. (The heartbeat vignette lives in HUD.)
--   Idle life: Thruster_L/R emit a faint blue-white flicker only while sprinting / airborne; the visor pulses very gently.
-- Everything is local; no per-frame allocations once the armour is bound.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Store = require(script.Parent.Parent:WaitForChild("Store"))

local ArmorFx = {}
ArmorFx.waistOffset = CFrame.identity -- heavy-hit stagger twist (CombatPose applies it when it owns the waist)
ArmorFx.external = false

local Fx: any = nil
local player = Players.LocalPlayer
local rng = Random.new()
local C3 = Color3.fromRGB

local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local RED = C3(255, 48, 40)
local ORANGE_SPARKS = ColorSequence.new({
	ColorSequenceKeypoint.new(0, C3(255, 245, 200)),
	ColorSequenceKeypoint.new(0.4, C3(255, 160, 50)),
	ColorSequenceKeypoint.new(1, C3(230, 80, 20)),
})

-- ---------------------------------------------------------------------------------------------
-- Armour binding
-- ---------------------------------------------------------------------------------------------
local visor: BasePart? = nil
local visorBase = C3(90, 220, 255)
local backpack: BasePart? = nil
local smoke: ParticleEmitter? = nil
local thrusters: { ParticleEmitter } = {}
local nextBind = 0
local boundChar: Model? = nil

local function makeSmoke(parent: BasePart): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = "ArmorFxSmoke"
	e.Texture = TEX_SMOKE
	e.Rate = 6
	e.Lifetime = NumberRange.new(0.9, 1.5)
	e.Speed = NumberRange.new(2, 4)
	e.SpreadAngle = Vector2.new(22, 22)
	e.EmissionDirection = Enum.NormalId.Top
	e.Acceleration = Vector3.new(0, 3, 0)
	e.Drag = 1
	e.LockedToPart = false
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-40, 40)
	e.LightInfluence = 0.7
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1.9) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
	e.Color = ColorSequence.new(C3(78, 76, 78), C3(40, 40, 44))
	e.Enabled = false
	e.Parent = parent
	return e
end

local function makeThruster(parent: BasePart): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = "ArmorFxThruster"
	e.Texture = TEX_SPARK
	e.Rate = 6
	e.Lifetime = NumberRange.new(0.16, 0.3)
	e.Speed = NumberRange.new(1.5, 4)
	e.SpreadAngle = Vector2.new(14, 14)
	e.EmissionDirection = Enum.NormalId.Bottom
	e.LockedToPart = false
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	e.Color = ColorSequence.new(C3(235, 250, 255), C3(110, 190, 255))
	e.Enabled = false
	e.Parent = parent
	return e
end

local function bind()
	local c = player.Character
	local armor = c and c:FindFirstChild("TrooperArmor")
	if not armor then
		visor, backpack, smoke = nil, nil, nil
		table.clear(thrusters)
		boundChar = nil
		return
	end
	local v = armor:FindFirstChild("Visor")
	if v and v:IsA("BasePart") and v ~= visor then
		visor = v
		visorBase = v.Color
	end
	local bp = armor:FindFirstChild("Backpack")
	if bp and bp:IsA("BasePart") and bp ~= backpack then
		backpack = bp
		smoke = bp:FindFirstChild("ArmorFxSmoke") or makeSmoke(bp)
	end
	table.clear(thrusters)
	for _, n in { "Thruster_L", "Thruster_R" } do
		local t = armor:FindFirstChild(n)
		if t and t:IsA("BasePart") then
			table.insert(thrusters, t:FindFirstChild("ArmorFxThruster") or makeThruster(t))
		end
	end
	boundChar = c
end

-- ---------------------------------------------------------------------------------------------
-- Hit flash (one Highlight, reused)
-- ---------------------------------------------------------------------------------------------
local highlight: Highlight? = nil
local flashToken = 0
local flickerUntil = 0

local function hitFlash()
	local c = player.Character
	if not c then
		return
	end
	if not highlight or highlight.Parent ~= c then
		if highlight then
			highlight:Destroy()
		end
		local h = Instance.new("Highlight")
		h.Name = "HitFlash"
		h.OutlineTransparency = 1
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Adornee = c
		h.Enabled = false
		h.Parent = c
		highlight = h
	end
	local h = highlight :: Highlight
	flashToken += 1
	local token = flashToken
	h.FillColor = C3(255, 186, 150) -- warm hot-metal flash, not a white blowout
	h.FillTransparency = 0.62
	h.Enabled = true
	local tw = TweenService:Create(h, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FillTransparency = 1,
		FillColor = C3(255, 70, 50),
	})
	tw:Play()
	task.delay(0.14, function()
		if token == flashToken and h.Parent then
			h.Enabled = false
		end
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Directional damage indicator
-- ---------------------------------------------------------------------------------------------
local gui: ScreenGui? = nil
type Slot = { holder: Frame, bar: Frame, grad: UIGradient, dir: Vector3?, t0: number, life: number, busy: boolean }
local slots: { Slot } = {}
local slotIdx = 0
local indicatorConn: RBXScriptConnection? = nil
local INDICATOR_LIFE = 0.9

local function ensureGui(): boolean
	if gui and gui.Parent then
		return true
	end
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return false
	end
	local g = Instance.new("ScreenGui")
	g.Name = "HitIndicators"
	g.IgnoreGuiInset = true
	g.ResetOnSpawn = false
	g.DisplayOrder = 6
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.Parent = pg
	gui = g
	table.clear(slots)
	for _ = 1, 4 do
		local holder = Instance.new("Frame")
		holder.AnchorPoint = Vector2.new(0.5, 0.5)
		holder.Size = UDim2.fromOffset(0, 0)
		holder.BackgroundTransparency = 1
		holder.Visible = false
		holder.Parent = g
		local bar = Instance.new("Frame")
		bar.Size = UDim2.fromOffset(170, 20)
		bar.BackgroundColor3 = RED
		bar.BorderSizePixel = 0
		bar.Active = false
		bar.Parent = holder
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = bar
		local grad = Instance.new("UIGradient")
		grad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.22, 0.35),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(0.78, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		grad.Parent = bar
		table.insert(slots, { holder = holder, bar = bar, grad = grad, dir = nil, t0 = 0, life = INDICATOR_LIFE, busy = false })
	end
	return true
end

local function indicatorStep()
	local cam = workspace.CurrentCamera
	local any = false
	if cam then
		local vp = cam.ViewportSize
		local radius = vp.Y * 0.34
		local look = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
		local right = Vector3.new(cam.CFrame.RightVector.X, 0, cam.CFrame.RightVector.Z)
		for _, s in slots do
			if s.busy then
				local f = (os.clock() - s.t0) / s.life
				if f >= 1 then
					s.busy = false
					s.holder.Visible = false
				else
					any = true
					local ang = 0
					if s.dir and look.Magnitude > 0.01 then
						ang = math.atan2(right:Dot(s.dir), look:Dot(s.dir))
					end
					s.holder.Position = UDim2.fromOffset(vp.X / 2, vp.Y / 2)
					s.holder.Rotation = math.deg(ang)
					s.bar.Position = UDim2.fromOffset(-85, -radius - 10)
					s.bar.BackgroundTransparency = 0.3 + 0.7 * f * f
				end
			end
		end
	end
	if not any and indicatorConn then
		indicatorConn:Disconnect()
		indicatorConn = nil
	end
end

local function showIndicator(dir: Vector3)
	if not ensureGui() then
		return
	end
	slotIdx = slotIdx % #slots + 1
	local s = slots[slotIdx]
	s.dir = dir
	s.t0 = os.clock()
	s.busy = true
	s.holder.Visible = true
	if not indicatorConn then
		indicatorConn = RunService.RenderStepped:Connect(indicatorStep)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Heavy-hit stagger: the Waist joint's C0 is twisted locally (never replicated) and sprung back, like GunFeel's grip.
-- The Animator writes Motor6D.Transform, so C0 composes with the walk/hold animations.
-- ---------------------------------------------------------------------------------------------
-- R15 joints are Motor6D on classic rigs and AnimationConstraint on the upgraded avatar joints (same C0/C1/Transform API)
local function isJoint(x: Instance?): boolean
	return x ~= nil and (x:IsA("Motor6D") or x:IsA("AnimationConstraint"))
end
-- C0 is read-only on AnimationConstraint: move its Attachment0 instead (same frame)
local function setC0(j: any, cf: CFrame)
	if j:IsA("AnimationConstraint") then
		local a = j.Attachment0
		if a then
			a.CFrame = cf
		end
	else
		j.C0 = cf
	end
end
local waist: Motor6D? = nil
local waistBase = CFrame.identity
local waistDirty = false
local stX, stV = 0, 0 -- twist spring (radians around the torso's up axis)
local stP, stPV = 0, 0 -- recoil-back spring (radians around the torso's right axis)

local function findWaist(): Motor6D?
	if waist and waist.Parent then
		return waist
	end
	waist = nil
	waistDirty = false
	local c = player.Character
	local ut = c and c:FindFirstChild("UpperTorso")
	local m = ut and ut:FindFirstChild("Waist")
	if m and isJoint(m) then
		waist = m
		waistBase = m.C0
		return m
	end
	return nil
end

local function spring(x: number, v: number, dt: number): (number, number)
	-- slightly under-damped (omega 22 rad/s, zeta 0.55): one small overshoot reads as the body catching itself
	local steps = math.clamp(math.ceil(dt / 0.008), 1, 6)
	local h = dt / steps
	for _ = 1, steps do
		v += (-484 * x - 24 * v) * h
		x += v * h
	end
	return x, v
end

local function stepStagger(dt: number)
	if not waistDirty and stX == 0 and stP == 0 and stV == 0 and stPV == 0 then
		return
	end
	stX, stV = spring(stX, stV, dt)
	stP, stPV = spring(stP, stPV, dt)
	local w = findWaist()
	if not w then
		stX, stV, stP, stPV = 0, 0, 0, 0
		return
	end
	if math.abs(stX) + math.abs(stP) < 0.002 and math.abs(stV) + math.abs(stPV) < 0.02 then
		stX, stV, stP, stPV = 0, 0, 0, 0
		ArmorFx.waistOffset = CFrame.identity
		if not ArmorFx.external then
			setC0(w, waistBase)
		end
		waistDirty = false
		return
	end
	ArmorFx.waistOffset = CFrame.Angles(stP, stX, 0)
	if not ArmorFx.external then
		setC0(w, waistBase * ArmorFx.waistOffset)
	end
	waistDirty = true
end

-- localDir: hit direction in the character's frame (x right, z back). Heavier hits push harder.
local function stagger(amount: number, localDir: Vector3?)
	if not findWaist() then
		return
	end
	local k = math.clamp((amount - 15) / 30, 0, 1)
	local twist = 0.2 + 0.18 * k -- peak twist in radians (~11-22 deg)
	local side = if localDir and math.abs(localDir.X) > 0.05 then -math.sign(localDir.X) else (if rng:NextNumber() < 0.5 then -1 else 1)
	stV += side * twist * 22 -- impulse: v0 = peak * omega
	-- hit from the front throws the shoulders back
	local front = if localDir then -localDir.Z else 0.5
	stPV += math.clamp(front, -0.3, 1) * (0.1 + 0.1 * k) * 22
end

-- ---------------------------------------------------------------------------------------------
-- Hurt
-- ---------------------------------------------------------------------------------------------
local Juice: any = nil
local CHIP_PALETTE = { C3(58, 60, 64), C3(46, 44, 42), C3(150, 132, 104) } -- charcoal plate, dark edge, worn tan
local lastChipAt = 0

local function onHurt(d: any)
	local c = player.Character
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local amount = if type(d.amount) == "number" then d.amount else 10
	hitFlash()
	flickerUntil = os.clock() + 0.25

	local dir: Vector3? = nil
	if typeof(d.from) == "Vector3" then
		local flat = Vector3.new(d.from.X - root.Position.X, 0, d.from.Z - root.Position.Z)
		if flat.Magnitude > 0.5 then
			dir = flat.Unit
		end
	end
	if Fx then
		local side = dir
		if not side then
			local rv = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
			side = if rv.Magnitude > 0.05 then rv.Unit else root.CFrame.LookVector
		end
		local pos = root.Position + side * 1.1 + Vector3.new(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0.2, 1.0), rng:NextNumber(-0.3, 0.3))
		Fx.burst("sparks", pos, 4 + math.min(2, math.floor(amount / 15)), { scale = 0.5, speed = 0.75, color = ORANGE_SPARKS })
		-- a few paint/plate chips knocked off the armour (rate-limited so damage-over-time does not spray confetti)
		local now = os.clock()
		if amount >= 6 and now - lastChipAt > 0.25 then
			lastChipAt = now
			if Fx.quality >= 0.6 then
				Fx.debris(pos, { n = if amount >= 20 then 3 else 2, style = "scrap", scale = 0.22, speed = 11, up = 0.8, life = 1.1, palette = CHIP_PALETTE })
			end
			Fx.burst("puff", pos, 1, { scale = 0.3, speed = 0.4, color = C3(92, 88, 84) })
		end
	end
	if amount >= 15 then
		local ld = if dir then root.CFrame:VectorToObjectSpace(dir) else nil
		stagger(amount, ld)
		if Juice and Juice.kick then
			local sx = if ld and ld.X < 0 then -1 else 1
			Juice.kick(math.clamp(amount / 20, 0.6, 2.2), sx * math.clamp(amount / 30, 0.4, 1.4))
		end
	end
	if dir then
		showIndicator(dir)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Per-frame: visor, low-health smoke, thrusters
-- ---------------------------------------------------------------------------------------------
local lastVisor = Color3.new()

local function update(dt: number)
	local now = os.clock()
	stepStagger(math.min(dt, 0.1))
	local c = player.Character
	if now >= nextBind and (c ~= boundChar or not visor or not visor.Parent or not backpack or not backpack.Parent) then
		nextBind = now + 0.5
		bind()
	end

	local me = Store.get("me")
	local alive = me ~= nil and me.alive ~= false
	local frac = 1
	if me and me.maxHp and me.maxHp > 0 then
		frac = math.clamp((me.hp or 0) / me.maxHp, 0, 1)
	end
	local low = alive and frac < 0.3

	if visor and visor.Parent then
		local col = visorBase:Lerp(Color3.new(1, 1, 1), 0.03 + 0.03 * math.sin(now * 1.3)) -- very slow idle pulse (the visor is dark glass now)
		if low then
			local blink = 0.5 + 0.5 * math.sin(now * 3.2)
			col = col:Lerp(RED, 0.25 + 0.7 * blink)
		end
		if now < flickerUntil and math.floor(now * 14) % 2 == 0 then
			col = RED
		end
		if col ~= lastVisor then
			lastVisor = col
			visor.Color = col
		end
	end

	if smoke then
		smoke.Enabled = low and (Fx == nil or Fx.quality >= 0.4)
	end

	if #thrusters > 0 then
		local hum = c and c:FindFirstChildOfClass("Humanoid")
		local on = false
		if hum and alive then
			local airborne = hum.FloorMaterial == Enum.Material.Air
			local sprinting = hum.MoveDirection.Magnitude > 0.1 and hum.WalkSpeed >= Config.SprintSpeed - 0.5
			on = airborne or sprinting
		end
		for _, e in thrusters do
			if e.Parent then
				e.Enabled = on
			end
		end
	end
end

function ArmorFx.init(fx: any, _audio: any, juice: any)
	Fx = fx
	Juice = juice
	Fx.register("Hurt", onHurt)
	RunService.RenderStepped:Connect(update)
	player.CharacterAdded:Connect(function()
		waist, waistDirty = nil, false
		stX, stV, stP, stPV = 0, 0, 0, 0
		highlight = nil
		visor, backpack, smoke = nil, nil, nil
		table.clear(thrusters)
		boundChar = nil
		nextBind = 0
		flickerUntil = 0
	end)
end

return ArmorFx
