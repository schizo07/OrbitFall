--!nonstrict
-- Local-player gun feel (third person). Loaded by Fx.init (collectModules) and called by WeaponController:
--   GunFeel.shot(w, aiming)   per predicted shot: grip recoil spring, star muzzle flash + light + sparks, shell casing, gatling heat
-- Self-driven (RenderStepped) for the rest:
--   * recoil / reload pose: the Tool's RightGrip weld C0 is offset locally (never replicated) and sprung back
--   * reload: gun tilts 35 deg for the reload duration, magazine drops from under the gun, rack kick at the end
--   * gatling barrels heat up toward orange with sustained fire and cool down again
-- Casings and the dropped magazine are simulated by hand (ray vs ground) instead of Roblox physics: no collision with
-- the player's own character, no network ownership, and a hard cap of 25 casings. Skipped on low quality.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared:WaitForChild("Data"):WaitForChild("Weapons"))
local Store = require(script.Parent.Parent:WaitForChild("Store"))

local GunFeel = {}
GunFeel.offset = CFrame.identity -- current recoil/reload offset in gun space (read by CombatPose)
GunFeel.reloadBlend = 0
GunFeel.lastShot = 0
GunFeel.external = false -- true once CombatPose drives the grip weld (then GunFeel never writes it)

local Fx: any = nil
local Audio: any = nil
local player = Players.LocalPlayer
local rng = Random.new()
local C3 = Color3.fromRGB

-- grip kick per weapon (pistol .6, carbine .8, smg .5, shotgun 1.6, marksman 1.4, rocket 2.2, rail 2.0, gatling .3)
local KICK: { [string]: number } = {
	P3 = 0.6, BP2 = 1.0, PR7 = 0.8, VR1 = 0.8, SM2 = 0.5, SG4 = 1.6, HS3 = 1.8, MR9 = 1.4, ROCKET = 2.2, RAIL = 2.0, GATLING = 0.3,
}
-- ejected casing type
local CASING: { [string]: string } = { PR7 = "brass", SM2 = "brass", MR9 = "brass", P3 = "brass", GATLING = "brass", SG4 = "shell", HS3 = "shell" }
-- energy weapons flash in their tracer colour
local ENERGY: { [string]: boolean } = { VR1 = true, RAIL = true, MR9 = false }
local WARM = C3(255, 200, 120)
local BRASS = C3(214, 170, 80)
local SHELL_RED = C3(205, 52, 44)

-- ---------------------------------------------------------------------------------------------
-- Gun lookup
-- ---------------------------------------------------------------------------------------------
local function getHandle(): BasePart?
	local c = player.Character
	local gun = c and c:FindFirstChild("Gun")
	return gun and gun:FindFirstChild("Handle") :: BasePart?
end

local function getMuzzle(): (CFrame?, BasePart?)
	local h = getHandle()
	if not h then
		return nil, nil
	end
	local att = h:FindFirstChild("Muzzle")
	if att and att:IsA("Attachment") then
		return att.WorldCFrame, h
	end
	return h.CFrame * CFrame.new(0, 0, -2), h
end

-- ---------------------------------------------------------------------------------------------
-- Grip spring + reload pose
-- ---------------------------------------------------------------------------------------------
local gripWeld: Weld? = nil
local gripBase = CFrame.identity
local gripDirty = false
local kx, kv = 0, 0 -- recoil spring (kick units)
local reloadBlend = 0
local reloading = false
local reloadEnd = 0 -- server time the current reload finishes

local function findGrip(): Weld?
	if gripWeld and gripWeld.Parent then
		return gripWeld
	end
	gripWeld = nil
	local c = player.Character
	if not c then
		return nil
	end
	local hand = c:FindFirstChild("RightHand") or c:FindFirstChild("Right Arm")
	local w = hand and hand:FindFirstChild("RightGrip")
	if w and w:IsA("Weld") then
		gripWeld = w
		gripBase = w.C0
		gripDirty = false
		return w
	end
	return nil
end

local function springStep(x: number, v: number, dt: number): (number, number)
	local steps = math.clamp(math.ceil(dt / 0.004), 1, 8)
	local h = dt / steps
	local k, c = 2025, 90 -- omega 45 rad/s, critically damped: settles in ~0.1 s
	for _ = 1, steps do
		v += (-k * x - c * v) * h
		x += v * h
	end
	return x, v
end

-- ---------------------------------------------------------------------------------------------
-- Hand-simulated bits (shell casings, dropped magazine)
-- ---------------------------------------------------------------------------------------------
type Bit = {
	part: Part,
	pos: Vector3,
	vel: Vector3,
	rot: CFrame,
	axis: Vector3,
	spin: number,
	t: number,
	life: number,
	settled: boolean,
	clinked: boolean,
	casing: boolean,
	fadeFrom: number,
}

local bits: { Bit } = {}
local casingCount = 0
local MAX_CASINGS = 25
local simConn: RBXScriptConnection? = nil
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local nextFilter = 0

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
	rayParams.FilterDescendantsInstances = list
end

local function killBit(i: number)
	local b = bits[i]
	if b.casing then
		casingCount -= 1
	end
	if b.part.Parent then
		b.part:Destroy()
	end
	local n = #bits
	bits[i] = bits[n]
	bits[n] = nil
end

local function simStep(dt: number)
	local now = os.clock()
	if now >= nextFilter then
		nextFilter = now + 1
		refreshFilter()
	end
	dt = math.min(dt, 0.05)
	for i = #bits, 1, -1 do
		local b = bits[i]
		b.t += dt
		if b.t >= b.life or not b.part.Parent then
			killBit(i)
			continue
		end
		if b.t > b.fadeFrom then
			b.part.Transparency = math.clamp((b.t - b.fadeFrom) / (b.life - b.fadeFrom), 0, 1)
		end
		if not b.settled then
			b.vel += Vector3.new(0, -workspace.Gravity * 0.6 * dt, 0)
			local step = b.vel * dt
			local hit = if step.Magnitude > 1e-4 then workspace:Raycast(b.pos, step + step.Unit * 0.08, rayParams) else nil
			if hit then
				b.pos = hit.Position + hit.Normal * 0.06
				local n = hit.Normal
				local v = b.vel
				local vn = v:Dot(n)
				if not b.clinked and vn < -3 then
					b.clinked = true
					if Audio then
						Audio.play("HitMetal", b.pos, { volume = if b.casing then 0.22 else 0.4, pitch = if b.casing then 2.3 else 1.1, priority = 1 })
					end
				end
				v = (v - n * vn * 1.0) * 0.55 - n * vn * 0.32
				b.vel = v
				b.spin *= 0.5
				if v.Magnitude < 3.5 then
					b.settled = true
					local _, yaw, _ = b.rot:ToOrientation()
					b.rot = CFrame.Angles(0, yaw, 0)
				end
			else
				b.pos += step
				b.rot = b.rot * CFrame.fromAxisAngle(b.axis, b.spin * dt)
			end
			b.part.CFrame = CFrame.new(b.pos) * b.rot
		end
	end
	if #bits == 0 and simConn then
		simConn:Disconnect()
		simConn = nil
	end
end

local function addBit(part: Part, pos: Vector3, vel: Vector3, life: number, casing: boolean)
	local b: Bit = {
		part = part,
		pos = pos,
		vel = vel,
		rot = CFrame.Angles(rng:NextNumber() * 6.28, rng:NextNumber() * 6.28, rng:NextNumber() * 6.28),
		axis = Vector3.new(rng:NextNumber() - 0.5, rng:NextNumber() - 0.5, rng:NextNumber() - 0.5).Unit,
		spin = (rng:NextNumber() * 2 - 1) * 28,
		t = 0,
		life = life,
		settled = false,
		clinked = false,
		casing = casing,
		fadeFrom = life - 0.4,
	}
	if casing then
		casingCount += 1
		-- oldest casing goes first when over the cap
		if casingCount > MAX_CASINGS then
			for i = 1, #bits do
				if bits[i].casing then
					killBit(i)
					break
				end
			end
		end
	end
	table.insert(bits, b)
	part.CFrame = CFrame.new(pos) * b.rot
	part.Parent = Fx.folder
	if not simConn then
		nextFilter = 0
		simConn = RunService.Heartbeat:Connect(simStep)
	end
end

local function newBitPart(size: Vector3, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Size = size
	p.Color = color
	p.Material = material
	return p
end

local shellParity = 0

local function ejectCasing(w: any, handle: BasePart)
	if not Fx or Fx.quality < 0.6 then
		return
	end
	-- gatling: every other shot (15 casings/s would only hit the cap)
	shellParity += 1
	if w.id == "GATLING" and shellParity % 2 == 0 then
		return
	end
	local kind = CASING[w.id]
	if not kind then
		return
	end
	local part = if kind == "shell"
		then newBitPart(Vector3.new(0.16, 0.16, 0.42), SHELL_RED, Enum.Material.SmoothPlastic)
		else newBitPart(Vector3.new(0.12, 0.12, 0.3), BRASS, Enum.Material.Metal)
	local cf = handle.CFrame
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local inherit = if root then root.AssemblyLinearVelocity * 0.85 else Vector3.zero
	local pos = (cf * CFrame.new(0.12, 0.18, -0.55)).Position
	local vel = cf.RightVector * rng:NextNumber(7, 11) + cf.UpVector * rng:NextNumber(5, 9) + cf.LookVector * rng:NextNumber(-3, 1) + inherit
	addBit(part, pos, vel, 2, true)
end

local function dropMagazine(w: any, handle: BasePart)
	if w.perShellReload or w.kind == "rocket" or w.kind == "rail" then
		return
	end
	local part = newBitPart(Vector3.new(0.2, 0.5, 0.32), C3(38, 40, 46), Enum.Material.Metal)
	local cf = handle.CFrame
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local inherit = if root then root.AssemblyLinearVelocity * 0.6 else Vector3.zero
	local pos = (cf * CFrame.new(0, -0.45, -0.1)).Position
	local vel = Vector3.new(rng:NextNumber(-1.5, 1.5), -2, rng:NextNumber(-1.5, 1.5)) + inherit
	addBit(part, pos, vel, 3, false)
end

-- ---------------------------------------------------------------------------------------------
-- Muzzle flash rig: 3-pronged Neon star (random roll each shot) + hot core + forward lick + PointLight
-- ---------------------------------------------------------------------------------------------
type Rig = { parts: { Part }, core: Part, light: PointLight?, t: number, active: boolean }
local rigs: { Rig } = {}
local liveRigs: { Rig } = {}
local flashConn: RBXScriptConnection? = nil
local FLASH_LIFE = 0.065 -- ~4 frames: long enough to register, short enough to strobe on full-auto

local function newRig(): Rig
	local function neon(size: Vector3, shape: Enum.PartType?): Part
		local p = newBitPart(size, Color3.new(1, 1, 1), Enum.Material.Neon)
		if shape then
			p.Shape = shape
		end
		p.Parent = nil
		return p
	end
	local rig: Rig = { parts = {}, core = neon(Vector3.new(0.55, 0.55, 0.55), Enum.PartType.Ball), light = nil, t = 0, active = false }
	table.insert(rig.parts, rig.core)
	for _ = 1, 3 do
		table.insert(rig.parts, neon(Vector3.new(1.9, 0.09, 0.09)))
	end
	table.insert(rig.parts, neon(Vector3.new(0.3, 0.3, 1.5))) -- forward lick
	if Fx.quality >= 0.75 then
		local l = Instance.new("PointLight")
		l.Range = 16
		l.Brightness = 5
		l.Shadows = false
		l.Enabled = false
		l.Parent = rig.core
		rig.light = l
	end
	return rig
end

local function flashStep(dt: number)
	for i = #liveRigs, 1, -1 do
		local r = liveRigs[i]
		r.t += dt
		local f = r.t / FLASH_LIFE
		if f >= 1 then
			for _, p in r.parts do
				p.Parent = nil
			end
			if r.light then
				r.light.Enabled = false
			end
			r.active = false
			table.insert(rigs, r)
			local n = #liveRigs
			liveRigs[i] = liveRigs[n]
			liveRigs[n] = nil
		else
			for _, p in r.parts do
				p.Transparency = 0.15 + 0.85 * f * f
			end
			if r.light then
				r.light.Brightness = 5 * (1 - f)
			end
		end
	end
	if #liveRigs == 0 and flashConn then
		flashConn:Disconnect()
		flashConn = nil
	end
end

local function muzzleFlash(w: any, cf: CFrame)
	local rig = table.remove(rigs) or (#liveRigs < 6 and newRig() or nil)
	if not rig then
		return
	end
	local col = if ENERGY[w.id] and w.tracer then w.tracer else WARM
	local white = col:Lerp(Color3.new(1, 1, 1), 0.35) -- hot core, but not a pure-white blowout
	local roll = rng:NextNumber() * math.pi
	local s = rng:NextNumber(0.85, 1.2) * (if w.kind == "rocket" or w.kind == "rail" then 1.6 elseif w.id == "GATLING" then 0.8 else 1)
	rig.t = 0
	rig.active = true
	local base = cf * CFrame.Angles(0, 0, roll)
	rig.core.Color = white
	rig.core.Size = Vector3.one * 0.8 * s
	rig.core.CFrame = base
	for k = 1, 3 do
		local p = rig.parts[1 + k]
		p.Color = if k == 1 then white else col
		p.Size = Vector3.new(2.7 * s, 0.13, 0.13)
		p.CFrame = base * CFrame.Angles(0, 0, (k - 1) * math.pi / 3)
	end
	local lick = rig.parts[5]
	lick.Color = col
	lick.Size = Vector3.new(0.38 * s, 0.38 * s, 2.4 * s)
	lick.CFrame = cf * CFrame.new(0, 0, -1.2 * s)
	for _, p in rig.parts do
		p.Parent = Fx.folder
	end
	if rig.light then
		rig.light.Color = col
		rig.light.Brightness = 5
		rig.light.Enabled = true
	end
	table.insert(liveRigs, rig)
	if not flashConn then
		flashConn = RunService.Heartbeat:Connect(flashStep)
	end
	-- 2-3 sparkle / fire particles from the barrel
	Fx.burst("sparks", cf, 3, { scale = 0.55, speed = 0.9, color = col:Lerp(Color3.new(1, 1, 1), 0.3) })
	if Fx.quality >= 0.75 then
		Fx.burst("fire", cf, 1, { scale = 0.18, speed = 0.4, color = col })
	end
	if w.kind == "rail" or (ENERGY[w.id] and Fx.quality >= 0.6) then
		Fx.burst("zap", cf, if w.kind == "rail" then 6 else 2, { scale = 0.35, speed = 0.5 })
	end
end

-- ---------------------------------------------------------------------------------------------
-- Barrel smoke wisp after a sustained burst / heavy shot, rocket back-blast
-- One ParticleEmitter per gun, parented to the Muzzle attachment (local only, dies with the Tool).
-- ---------------------------------------------------------------------------------------------
local burstShots = 0
local lastBurstShot = 0
local wispUntil = 0
local wispEmitter: ParticleEmitter? = nil
local WISP_HEAVY: { [string]: boolean } = { ROCKET = true, RAIL = true, SG4 = true, HS3 = true, MR9 = true, BP2 = true }

local function getWisp(): ParticleEmitter?
	if wispEmitter and wispEmitter:IsDescendantOf(workspace) then
		return wispEmitter
	end
	wispEmitter = nil
	local h = getHandle()
	local att = h and h:FindFirstChild("Muzzle")
	if not att or not att:IsA("Attachment") then
		return nil
	end
	local e = att:FindFirstChild("GunFeelWisp") :: ParticleEmitter?
	if not e then
		local n = Instance.new("ParticleEmitter")
		n.Name = "GunFeelWisp"
		n.Texture = "rbxasset://textures/particles/smoke_main.dds"
		n.Rate = 0
		n.Enabled = false
		n.Lifetime = NumberRange.new(0.9, 1.6)
		n.Speed = NumberRange.new(0.4, 1.1)
		n.SpreadAngle = Vector2.new(25, 25)
		n.EmissionDirection = Enum.NormalId.Top
		n.Acceleration = Vector3.new(0, 2.6, 0)
		n.Drag = 1.2
		n.Rotation = NumberRange.new(0, 360)
		n.RotSpeed = NumberRange.new(-50, 50)
		n.LightInfluence = 1
		n.LightEmission = 0
		n.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.12), NumberSequenceKeypoint.new(0.5, 0.45), NumberSequenceKeypoint.new(1, 0.9) })
		n.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.15, 0.62), NumberSequenceKeypoint.new(1, 1) })
		n.Color = ColorSequence.new(C3(150, 146, 140), C3(96, 94, 92))
		n.Parent = att
		e = n
	end
	wispEmitter = e
	return e
end

local function startWisp(dur: number)
	if not Fx or Fx.quality < 0.5 then
		return
	end
	local e = getWisp()
	if not e then
		return
	end
	wispUntil = math.max(wispUntil, os.clock() + dur)
	e.Rate = if Fx.quality >= 0.75 then 9 else 5
	e.Enabled = true
end

local function stepWisp(now: number)
	if burstShots > 0 and now - lastBurstShot > 0.22 then
		-- the burst just ended: a long one leaves the barrel smoking
		if burstShots >= 10 then
			startWisp(math.clamp(burstShots * 0.06, 0.8, 2.2))
		end
		burstShots = 0
	end
	local e = wispEmitter
	if e and e.Enabled and (now >= wispUntil or not e.Parent) then
		e.Enabled = false
	end
end

local function backBlast(handle: BasePart)
	if not Fx then
		return
	end
	local back = handle.CFrame * CFrame.new(0, 0.2, 1.6)
	Fx.burst("smoke", back.Position, 3, { scale = 0.35, speed = 0.6 })
	if Fx.quality >= 0.75 then
		Fx.burst("fire", back.Position, 2, { scale = 0.3, speed = 0.5 })
	end
end

-- ---------------------------------------------------------------------------------------------
-- Gatling heat
-- ---------------------------------------------------------------------------------------------
local heat = 0
local lastShotAt = 0
local barrelOrig: { [BasePart]: { color: Color3, material: Enum.Material, last: number } } =setmetatable({}, { __mode = "k" }) :: any
local HOT = C3(255, 120, 30)
local nextSmoke = 0

local function applyHeat(w: any?)
	local h = getHandle()
	local motor = h and h:FindFirstChild("BarrelSpin")
	local barrels = motor and motor:IsA("Motor6D") and motor.Part1
	if not barrels then
		return
	end
	local orig = barrelOrig[barrels]
	if not orig then
		orig = { color = barrels.Color, material = barrels.Material, last = -1 }
		barrelOrig[barrels] = orig
	end
	local hot = if w and w.id == "GATLING" then heat else 0
	if math.abs(orig.last - hot) < 0.004 and hot < 0.7 then
		return
	end
	orig.last = hot
	barrels.Color = orig.color:Lerp(HOT, math.clamp(hot, 0, 1) ^ 1.2)
	barrels.Material = if hot > 0.82 then Enum.Material.Neon else orig.material
	if hot > 0.7 and os.clock() >= nextSmoke and Fx and Fx.quality >= 0.6 then
		nextSmoke = os.clock() + 0.22
		local cf = getMuzzle()
		if cf then
			Fx.burst("puff", cf, 1, { scale = 0.35, speed = 0.4, color = C3(170, 165, 160) })
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Per-frame
-- ---------------------------------------------------------------------------------------------
local function currentWeapon(): any?
	local m = Store.get("me")
	if not m or not m.weapons then
		return nil
	end
	local ws = m.weapons[m.weapon or 1]
	return ws and Weapons.get(ws.id) or nil
end

local function update(dt: number)
	dt = math.min(dt, 0.1)
	local now = os.clock()
	local m = Store.get("me")
	local w = currentWeapon()

	-- reload tracking
	local serverNow = workspace:GetServerTimeNow()
	local isReloading = m ~= nil and m.alive ~= false and m.reloadUntil ~= nil and m.reloadUntil > serverNow
	if isReloading and not reloading then
		reloading = true
		reloadEnd = m.reloadUntil
		local h = getHandle()
		if h and w then
			dropMagazine(w, h)
		end
	elseif not isReloading and reloading then
		reloading = false
		-- rack the slide / seat the mag, only when the reload ran to the end (not cancelled by a swap or death)
		if serverNow >= reloadEnd - 0.15 and m and m.alive ~= false then
			kx += 0.7
		end
	end
	stepWisp(now)
	local target = if isReloading then 1 else 0
	reloadBlend += (target - reloadBlend) * math.min(1, dt * 11)

	-- heat
	if now - lastShotAt > 0.2 then
		heat = math.max(0, heat - dt * 0.3)
	end
	if heat > 0.001 or w and w.id == "GATLING" then
		applyHeat(w)
	end

	-- grip offset
	kx, kv = springStep(kx, kv, dt)
	local active = math.abs(kx) > 0.003 or math.abs(kv) > 0.02 or reloadBlend > 0.002
	local off = CFrame.identity
	if active then
		off = CFrame.new(0, 0.04 * kx, 0.34 * kx) * CFrame.Angles(0.17 * kx, 0, 0)
		if reloadBlend > 0.002 then
			local rb = reloadBlend
			local wob = math.sin(now * 9) * 0.05 * rb
			off = off * CFrame.new(0, -0.25 * rb, 0.1 * rb) * CFrame.Angles(-0.36 * rb + wob, 0, 0.5 * rb)
		end
	end
	GunFeel.offset = off -- gun-space recoil/reload offset; CombatPose applies it when it drives the gun
	GunFeel.reloadBlend = reloadBlend
	if GunFeel.external then
		if not active then
			kx, kv = 0, 0
		end
		return
	end
	local weld = findGrip()
	if not weld then
		return
	end
	if active then
		weld.C0 = gripBase * off
		gripDirty = true
	elseif gripDirty then
		weld.C0 = gripBase
		gripDirty = false
		kx, kv = 0, 0
	end
end

-- ---------------------------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------------------------
function GunFeel.shot(w: any, aiming: boolean?)
	if not Fx then
		return
	end
	local kick = (KICK[w.id] or 0.6) * (if aiming then 0.7 else 1)
	kx = math.min(kx + kick, 3)
	GunFeel.lastShot = os.clock()
	local cf, handle = getMuzzle()
	if cf then
		muzzleFlash(w, cf)
	end
	if handle then
		ejectCasing(w, handle)
		if w.kind == "rocket" then
			backBlast(handle)
		end
	end
	if w.id == "GATLING" then
		heat = math.min(1, heat + 0.02)
		lastShotAt = os.clock()
	end
	burstShots += 1
	lastBurstShot = os.clock()
	if WISP_HEAVY[w.id] then
		startWisp(if w.kind == "rocket" or w.kind == "rail" then 1.6 else 0.9)
	end
end

function GunFeel.init(fx: any, audio: any, _juice: any)
	Fx = fx
	Audio = audio
	RunService.RenderStepped:Connect(update)
	player.CharacterAdded:Connect(function()
		gripWeld = nil
		gripDirty = false
		kx, kv = 0, 0
		reloadBlend = 0
		reloading = false
		heat = 0
		burstShots = 0
		wispEmitter = nil
		wispUntil = 0
	end)
end

return GunFeel
