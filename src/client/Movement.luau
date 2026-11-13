-- Tactical movement (client, predicted; server/MovementService.luau is authoritative for stamina + stance).
--  * Stamina: sprint drains (Config.Move.SprintTime), refills after RegenDelay; at 0 you jog-limp until RecoverAt.
--  * Stances: Crouch tap = crouch/stand, hold = prone; Prone key toggles prone; Jump stands you up.
--  * Dive: Crouch/Prone while sprinting -> forward dive, land prone, short recovery. Costs stamina, 1 s cooldown.
--  * Mantle: Jump into a 2.5-6 stud ledge -> smooth climb onto it.
--  * Knockdown: heavy server knocks ("Knockdown" Fx) tumble you on the ground for KnockdownTime, then you get up.
--  * Poses: animation-free Motor6D C0 offsets + Humanoid.HipHeight, applied by every client to every character
--    (remote characters read the replicated `Stance` attribute the server sets).
-- Store keys written: stance ("stand"|"crouch"|"prone"), stamina ({v: number, exhausted: boolean}), moveMode.
-- Camera hooks (CameraController): Movement.cameraStep(dt, rawFocusY), Movement.allowFacing().
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Input = require(script.Parent.Input)
local Store = require(script.Parent.Store)

local M = Config.Move
local Movement = {}
local player = Players.LocalPlayer
local actionEv: RemoteEvent? = nil

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
local rad = math.rad
local UP = Vector3.new(0, 1, 0)

-- ── local state ────────────────────────────────────────────────────────────────────────────────────────────────
local stance = "stand" -- stand | crouch | prone
local mode = "none" -- none | dive | mantle | down | recover
local modeT = 0
local recoverFor = 0
local stamina, exhausted = 1, false
local lastDrain = -99
local lastDive = -99
local sprintApplied = false
local crouchDownAt: number? = nil
local crouchFreshCrouch = false -- this press is the one that crouched us (release must not stand back up)
local sentStance, sentSprint = "", false
local diveDir = Vector3.new(0, 0, -1)
local mantleFrom: Vector3 = Vector3.zero
local mantleTo: Vector3 = Vector3.zero
local mantleDir: Vector3 = Vector3.new(0, 0, -1)
local mantleDur = 0.35
local baseHip: number? = nil -- humanoid's own HipHeight (refreshed whenever we are not overriding it)
local hipCur: number? = nil -- what we last wrote (nil = not overriding)
local jumpEnabled = true
local jumpLock = false -- Jump was used to stand up / mantle: no real jump until it is released
local publishedStamina = -1
local publishedExhausted = false

-- camera feel
local focusY: number? = nil
local camDrop = 0
local landDip, landVel = 0, 0
local minVy = 0
local sprintBlend = 0
local bobPhase, bobAmp, limpAmp = 0, 0, 0

-- ── helpers ────────────────────────────────────────────────────────────────────────────────────────────────────
local function chr(): (Model?, Humanoid?, BasePart?)
	local c = player.Character
	if not c then
		return nil, nil, nil
	end
	local hum = c:FindFirstChildOfClass("Humanoid")
	local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	return c, hum, root
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

local function refreshFilter()
	local list: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, n in { "Enemies", "ClientFx" } do
		local f = workspace:FindFirstChild(n)
		if f then
			table.insert(list, f)
		end
	end
	rayParams.FilterDescendantsInstances = list
	overlapParams.FilterDescendantsInstances = list
end

local function cast(origin: Vector3, dir: Vector3): RaycastResult?
	return workspace:Raycast(origin, dir, rayParams)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function send(name: string, ...)
	if actionEv then
		actionEv:FireServer(name, ...)
	end
end

local function serverStance(): string
	if mode == "dive" or mode == "mantle" or mode == "down" then
		return mode
	end
	return stance
end

local function setStance(s: string)
	if stance == s then
		return
	end
	stance = s
	Store.set("stance", s)
end

local function setMode(m: string)
	mode = m
	modeT = os.clock()
	Store.set("moveMode", m)
end

local function legLengths(c: Model): (number, number)
	local thigh, shin = 1.1, 1.1
	local ul = c:FindFirstChild("LeftUpperLeg")
	local ll = c:FindFirstChild("LeftLowerLeg")
	local foot = c:FindFirstChild("LeftFoot")
	local hip = ul and ul:FindFirstChild("LeftHip") :: Motor6D?
	local knee = ll and ll:FindFirstChild("LeftKnee") :: Motor6D?
	local ankle = foot and foot:FindFirstChild("LeftAnkle") :: Motor6D?
	if hip and knee and isJoint(hip) and isJoint(knee) then
		thigh = (hip.C1.Position - knee.C0.Position).Magnitude
	end
	if knee and ankle and isJoint(knee) and isJoint(ankle) then
		shin = (knee.C1.Position - ankle.C0.Position).Magnitude
	end
	return math.clamp(thigh, 0.3, 4), math.clamp(shin, 0.3, 4)
end

-- crouch leg geometry (absolute angles from vertical; A = thigh forward, B = shin backward)
local CROUCH_A, CROUCH_B = rad(58), rad(-42)

local function hipTarget(c: Model, base: number): number
	local s = serverStance()
	if s == "dive" or s == "prone" then
		return 0.1
	elseif s == "crouch" then
		local thigh, shin = legLengths(c)
		local drop = thigh * (1 - math.cos(CROUCH_A)) + shin * (1 - math.cos(CROUCH_B))
		return math.max(0.2, base - drop)
	end
	return base
end

-- Is there head room to stand up from the current stance?
local function canStand(): boolean
	local _, hum, root = chr()
	if not hum or not root then
		return true
	end
	refreshFilter()
	local need = ((baseHip or hum.HipHeight) - hum.HipHeight) + root.Size.Y * 0.5 + 2.4
	return cast(root.Position, UP * need) == nil
end

local function setJumpEnabled(hum: Humanoid, on: boolean)
	if jumpEnabled == on then
		return
	end
	jumpEnabled = on
	hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, on)
	if on then
		hum.Jump = false
	end
end

local function groundBelow(root: BasePart, extra: number): RaycastResult?
	return cast(root.Position, Vector3.new(0, -(root.Size.Y * 0.5 + extra), 0))
end

local function camYawCF(pos: Vector3): CFrame
	local look = flat(workspace.CurrentCamera.CFrame.LookVector)
	if look.Magnitude < 0.05 then
		look = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(pos, pos + look.Unit)
end

-- ── actions ────────────────────────────────────────────────────────────────────────────────────────────────────
local function isSprinting(hum: Humanoid, root: BasePart): boolean
	return stance == "stand"
		and mode == "none"
		and Input.isDown("Sprint")
		and hum.FloorMaterial ~= Enum.Material.Air
		and flat(root.AssemblyLinearVelocity).Magnitude > Config.WalkSpeed + 1
end

local function tryDive(): boolean
	local _, hum, root = chr()
	if not hum or not root then
		return false
	end
	local t = os.clock()
	if not isSprinting(hum, root) or t - lastDive < M.DiveCooldown or stamina < M.DiveCost * 0.5 then
		return false
	end
	local v = flat(root.AssemblyLinearVelocity)
	diveDir = (v.Magnitude > 1 and v.Unit) or flat(root.CFrame.LookVector).Unit
	lastDive = t
	lastDrain = t
	stamina = math.max(0, stamina - M.DiveCost)
	setMode("dive")
	setJumpEnabled(hum, false)
	hum.PlatformStand = true
	root.AssemblyLinearVelocity = diveDir * M.DiveSpeed + UP * M.DiveUp
	root.AssemblyAngularVelocity = Vector3.zero
	send("dive")
	return true
end

local function tryMantle(): boolean
	local c, hum, root = chr()
	if not c or not hum or not root or mode ~= "none" or stance ~= "stand" or root.Anchored or hum.Sit then
		return false
	end
	refreshFilter()
	local half = root.Size.Y * 0.5
	local feetY = root.Position.Y - half - hum.HipHeight
	-- climb where we are heading, as long as that is roughly where we face (no backwards mantles)
	local look = flat(root.CFrame.LookVector).Unit
	local md = flat(hum.MoveDirection)
	local fwd = if md.Magnitude > 0.1 and md.Unit:Dot(look) > 0.2 then md.Unit else look
	local base = Vector3.new(root.Position.X, 0, root.Position.Z)
	-- 1. chest ray must hit a wall-ish surface close in front
	local chest = base + Vector3.new(0, feetY + 1.6, 0)
	local wall = cast(chest, fwd * 3.2)
	if not wall or math.abs(wall.Normal.Y) > 0.55 then
		return false
	end
	-- 2. above-head ray must be clear (ledge no taller than MantleMax)
	local headY = feetY + M.MantleMax + 0.6
	if cast(base + Vector3.new(0, headY, 0), fwd * (wall.Distance + 1.4)) then
		return false
	end
	-- 3. find the top surface just past the wall (thick ledge first, then thin wall top)
	local top: RaycastResult? = nil
	local probe = Vector3.zero
	for _, inset in { 1.1, 0.4 } do
		probe = flat(wall.Position) + fwd * inset
		local hit = cast(probe + Vector3.new(0, headY, 0), Vector3.new(0, -(headY - feetY - 0.4), 0))
		if hit and hit.Normal.Y > 0.7 then
			local h = hit.Position.Y - feetY
			if h >= M.MantleMin and h <= M.MantleMax then
				top = hit
				break
			end
		end
	end
	if not top then
		return false
	end
	local standHip = baseHip or hum.HipHeight
	local targetY = top.Position.Y + standHip + half + 0.05
	-- 4. room on top for a standing body, and nothing over our head on the way up
	local bodyH = standHip + root.Size.Y + 1.2
	local boxCf = CFrame.new(probe.X, top.Position.Y + 0.2 + bodyH * 0.5, probe.Z)
	for _, part in workspace:GetPartBoundsInBox(boxCf, Vector3.new(1.6, bodyH - 0.1, 1.2), overlapParams) do
		if part.CanCollide then
			return false
		end
	end
	if cast(root.Position, UP * (targetY - root.Position.Y + 2.2)) then
		return false
	end
	mantleFrom = root.Position
	mantleTo = Vector3.new(probe.X, targetY, probe.Z)
	mantleDir = fwd
	local h = top.Position.Y - feetY
	mantleDur = M.MantleTime * (0.8 + 0.2 * h / 4)
	setMode("mantle")
	setJumpEnabled(hum, false)
	hum.Jump = false
	hum.PlatformStand = true
	return true
end

local function standUp()
	if stance == "stand" then
		return
	end
	if canStand() then
		setStance("stand")
	elseif stance == "prone" then
		setStance("crouch")
	end
end

function Movement.knockdown(v: Vector3)
	local _, hum, root = chr()
	if not hum or not root or hum.Health <= 0 or root.Anchored then
		return
	end
	setMode("down")
	setStance("stand")
	setJumpEnabled(hum, false)
	hum.PlatformStand = true
	root.AssemblyLinearVelocity += v
	local f = flat(v)
	local axis = if f.Magnitude > 0.1 then f.Unit:Cross(UP) else Vector3.new(1, 0, 0)
	-- tumble away from the blast, cartoony spin
	root.AssemblyAngularVelocity = -axis * (7 + math.random() * 4) + UP * (math.random() * 6 - 3)
end

-- ── input ──────────────────────────────────────────────────────────────────────────────────────────────────────
local function blockedInput(): boolean
	local _, hum = chr()
	return Store.get("menuOpen") == true or not hum or hum.Health <= 0
end

local function onCrouch(down: boolean)
	if not down then
		if crouchDownAt and stance == "crouch" and os.clock() - crouchDownAt < M.ProneHoldTime and not crouchFreshCrouch then
			standUp()
		end
		crouchDownAt = nil
		return
	end
	if blockedInput() or (mode ~= "none" and mode ~= "recover") then
		return
	end
	if mode == "none" and tryDive() then
		return
	end
	crouchDownAt = os.clock()
	crouchFreshCrouch = false
	if stance == "stand" then
		setStance("crouch")
		crouchFreshCrouch = true
	elseif stance == "prone" then
		setStance("crouch")
		crouchDownAt = nil
	end
end

local function onProne(down: boolean)
	if not down or blockedInput() or (mode ~= "none" and mode ~= "recover") then
		return
	end
	if mode == "none" and tryDive() then
		return
	end
	if stance == "prone" then
		standUp()
	else
		setStance("prone")
	end
end

local function onJump(down: boolean)
	if not down or blockedInput() or mode ~= "none" then
		return
	end
	if stance ~= "stand" then
		jumpLock = true
		standUp()
		return
	end
	if tryMantle() then
		jumpLock = true
	end
end

-- ── per-frame simulation ───────────────────────────────────────────────────────────────────────────────────────
-- Runs on PreSimulation: after WeaponController's RenderStepped WalkSpeed write, right before physics, so ours wins.
local function step(dt: number)
	local c, hum, root = chr()
	if not c or not hum or not root or hum.Health <= 0 then
		return
	end
	local t = os.clock()
	if root.Anchored or hum.Sit then
		-- drop capsule / seats / cutscenes: drop everything and stand
		if mode ~= "none" then
			hum.PlatformStand = false
			setMode("none")
		end
		crouchDownAt = nil
		setStance("stand")
	end
	if hipCur == nil then
		baseHip = hum.HipHeight
	end
	local base = baseHip or hum.HipHeight

	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	local moving = hum.MoveDirection.Magnitude > 0.1
	local aiming = Input.isDown("Aim")
	local firing = Input.isDown("Fire")

	-- crouch held long enough -> prone
	if crouchDownAt and mode == "none" and t - crouchDownAt >= M.ProneHoldTime then
		crouchDownAt = nil
		setStance("prone")
	end

	-- special modes ------------------------------------------------------------------------------------------
	if mode == "dive" then
		refreshFilter()
		local e = t - modeT
		hum.PlatformStand = true
		-- 35 % of gravity cancelled for a floatier, readable arc
		local vy = root.AssemblyLinearVelocity.Y + workspace.Gravity * 0.35 * dt
		local horiz = diveDir * M.DiveSpeed * math.max(0.5, 1 - e * 0.7)
		root.AssemblyLinearVelocity = horiz + UP * vy
		root.AssemblyAngularVelocity = Vector3.zero
		root.CFrame = CFrame.lookAt(root.Position, root.Position + diveDir)
		if (e > 0.2 and vy <= 2 and groundBelow(root, 0.7) ~= nil) or e > 1.5 then
			hum.PlatformStand = false
			root.AssemblyLinearVelocity = horiz * 0.35 + UP * math.min(vy, 0)
			setStance("prone")
			setMode("recover")
			recoverFor = M.DiveRecover
			landVel -= 4
		end
	elseif mode == "mantle" then
		local e = math.clamp((t - modeT) / mantleDur, 0, 1)
		hum.PlatformStand = true
		local up = math.clamp(e / 0.6, 0, 1)
		up = 1 - (1 - up) * (1 - up) -- ease out
		local f = if e < 0.6 then 0.15 * (e / 0.6) else 0.15 + 0.85 * ((e - 0.6) / 0.4)
		f = f * f * (3 - 2 * f)
		local h = flat(mantleFrom):Lerp(flat(mantleTo), f)
		local pos = Vector3.new(h.X, mantleFrom.Y + (mantleTo.Y - mantleFrom.Y) * up, h.Z)
		root.CFrame = CFrame.lookAt(pos, pos + mantleDir)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		if e >= 1 then
			hum.PlatformStand = false
			root.AssemblyLinearVelocity = mantleDir * 8
			setMode("none")
			landVel -= 1.5
		end
	elseif mode == "down" then
		hum.PlatformStand = true
		local e = t - modeT
		if e >= M.KnockdownTime then
			refreshFilter()
			local g = groundBelow(root, 3)
			if g or e > 3 then
				local gy = if g then g.Position.Y else root.Position.Y - root.Size.Y * 0.5
				root.CFrame = camYawCF(Vector3.new(root.Position.X, gy + base + root.Size.Y * 0.5, root.Position.Z))
				root.AssemblyAngularVelocity = Vector3.zero
				root.AssemblyLinearVelocity = UP * math.min(0, root.AssemblyLinearVelocity.Y)
				hum.PlatformStand = false
				hum:ChangeState(Enum.HumanoidStateType.GettingUp)
				setMode("recover")
				recoverFor = 0.2
				landVel -= 3
			end
		end
	elseif mode == "recover" then
		if t - modeT >= recoverFor then
			setMode("none")
		end
	end

	-- stamina (prediction; server reconciles through `me`) ---------------------------------------------------
	sprintApplied = mode == "none"
		and stance == "stand"
		and Input.isDown("Sprint")
		and moving
		and not aiming
		and not firing
		and not exhausted
	if sprintApplied then
		stamina = math.max(0, stamina - dt / M.SprintTime)
		lastDrain = t
		if stamina <= 0 then
			exhausted = true
			sprintApplied = false
		end
	elseif t - lastDrain >= M.RegenDelay then
		stamina = math.min(1, stamina + dt / M.RegenTime)
	end
	if exhausted and stamina >= M.RecoverAt then
		exhausted = false
	end

	-- speed ----------------------------------------------------------------------------------------------------
	local speed
	if mode ~= "none" then
		speed = 0
	elseif stance == "prone" then
		speed = M.ProneSpeed
	elseif stance == "crouch" then
		speed = if aiming then M.CrouchAimSpeed else M.CrouchSpeed
	elseif aiming then
		speed = Config.AimSpeed
	elseif sprintApplied then
		speed = Config.SprintSpeed
	else
		speed = Config.WalkSpeed
	end
	if exhausted and stance == "stand" then
		speed = math.min(speed, M.LimpSpeed)
	end
	hum.WalkSpeed = speed

	-- hip height (smoothed; only overridden while not standing) ----------------------------------------------
	local target = if root.Anchored then base else hipTarget(c, base)
	if hipCur ~= nil or math.abs(target - base) > 1e-3 then
		local cur = hipCur or hum.HipHeight
		cur += (target - cur) * (1 - math.exp(-dt * 14))
		if math.abs(target - base) <= 1e-3 and math.abs(cur - base) < 0.02 then
			hum.HipHeight = base
			hipCur = nil
		else
			hum.HipHeight = cur
			hipCur = cur
		end
	end
	if jumpLock and not Input.isDown("Jump") then
		jumpLock = false
	end
	setJumpEnabled(hum, mode == "none" and stance == "stand" and not jumpLock)

	-- landing dip ----------------------------------------------------------------------------------------------
	local vy = root.AssemblyLinearVelocity.Y
	if mode == "down" or mode == "mantle" or root.Anchored then
		minVy = 0
	elseif not grounded then
		minVy = math.min(minVy, vy)
	else
		if minVy < -28 then
			landVel -= math.clamp((-minVy - 22) / 45, 0.15, 1) * 9
		end
		minVy = 0
	end

	-- replicate ------------------------------------------------------------------------------------------------
	local ss = serverStance()
	if ss ~= sentStance or sprintApplied ~= sentSprint then
		sentStance, sentSprint = ss, sprintApplied
		send("move", ss, sprintApplied)
	end
	if math.abs(stamina - publishedStamina) > 0.01 or exhausted ~= publishedExhausted then
		publishedStamina, publishedExhausted = stamina, exhausted
		Store.set("stamina", { v = stamina, exhausted = exhausted })
	end
end

-- ── procedural poses (every character) ──────────────────────────────────────────────────────────────────────────
type Joint = { m: Motor6D, base: CFrame }
type Rig = { root: Joint, joints: { [string]: Joint }, p: number, d: number, b: number, active: boolean }
local rigs: { [Model]: Rig } = {}

-- Motor6D name -> part that holds it (R15). R6 gets the root tilt only.
local JOINTS = {
	LeftHip = "LeftUpperLeg",
	RightHip = "RightUpperLeg",
	LeftKnee = "LeftLowerLeg",
	RightKnee = "RightLowerLeg",
	LeftAnkle = "LeftFoot",
	RightAnkle = "RightFoot",
	LeftShoulder = "LeftUpperArm",
	RightShoulder = "RightUpperArm",
	Neck = "Head",
}
-- p = body pitch forward (rad), d = extra drop of the body (studs), b = knee bend 0..1
local POSES = {
	stand = { p = 0, d = 0, b = 0 },
	down = { p = 0, d = 0, b = 0 }, -- physics tumble does the work
	crouch = { p = rad(16), d = 0, b = 1 },
	prone = { p = rad(84), d = -0.3, b = 0 },
	dive = { p = rad(70), d = 0, b = 0 },
	mantle = { p = rad(30), d = 0, b = 0.55 },
}

local function findMotor(c: Model, partName: string, name: string): Motor6D?
	local part = c:FindFirstChild(partName)
	local m = part and part:FindFirstChild(name)
	if m and isJoint(m) then
		return m
	end
	return nil
end

local function buildRig(c: Model): Rig?
	local rootM = findMotor(c, "LowerTorso", "Root") or findMotor(c, "HumanoidRootPart", "RootJoint")
	if not rootM then
		return nil
	end
	local rig: Rig = { root = { m = rootM, base = rootM.C0 }, joints = {}, p = 0, d = 0, b = 0, active = false }
	for name, part in JOINTS do
		local m = findMotor(c, part, name)
		if m then
			rig.joints[name] = { m = m, base = m.C0 }
		end
	end
	return rig
end

local function capture(rig: Rig)
	rig.root.base = rig.root.m.C0
	for _, j in rig.joints do
		j.base = j.m.C0
	end
end

local function restore(rig: Rig)
	setC0(rig.root.m, rig.root.base)
	for _, j in rig.joints do
		setC0(j.m, j.base)
	end
end

local function poseFor(c: Model): string
	if c == player.Character then
		if mode == "dive" or mode == "mantle" or mode == "down" then
			return mode
		end
		return stance
	end
	local s = c:GetAttribute("Stance")
	return if typeof(s) == "string" and POSES[s] then s else "stand"
end

local function setJ(rig: Rig, name: string, angle: number)
	local j = rig.joints[name]
	if j then
		setC0(j.m, j.base * CFrame.Angles(angle, 0, 0))
	end
end

local function poseStep(dt: number)
	for _, p in Players:GetPlayers() do
		local c = p.Character
		if not c then
			continue
		end
		local name = poseFor(c)
		local hum = c:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health <= 0 then
			name = "stand"
		end
		local rig = rigs[c]
		if rig and not rig.root.m.Parent then
			rigs[c] = nil
			rig = nil
		end
		if not rig then
			if name == "stand" or name == "down" then
				continue
			end
			rig = buildRig(c)
			if not rig then
				continue
			end
			rigs[c] = rig
		end
		local r = rig :: Rig
		local target = POSES[name]
		local k = 1 - math.exp(-dt * (if name == "dive" then 16 else 11))
		r.p += (target.p - r.p) * k
		r.d += (target.d - r.d) * k
		r.b += (target.b - r.b) * k
		if target.p == 0 and math.abs(r.p) < 0.003 and math.abs(r.d) < 0.003 and math.abs(r.b) < 0.003 then
			if r.active then
				restore(r)
				r.active = false
			end
			r.p, r.d, r.b = 0, 0, 0
			continue
		end
		if not r.active then
			capture(r)
			r.active = true
		end
		setC0(r.root.m, CFrame.new(0, r.d, 0) * CFrame.Angles(-r.p, 0, 0) * r.root.base)
		-- legs: thigh forward / shin back relative to the tilted pelvis, feet flat
		local hip = (CROUCH_A + r.p) * r.b
		local knee = (CROUCH_B - CROUCH_A) * r.b
		local ankle = -CROUCH_B * r.b
		setJ(r, "LeftHip", hip)
		setJ(r, "RightHip", hip)
		setJ(r, "LeftKnee", knee)
		setJ(r, "RightKnee", knee)
		setJ(r, "LeftAnkle", ankle)
		setJ(r, "RightAnkle", ankle)
		-- keep the gun and the face pointing forward while the body pitches
		setJ(r, "LeftShoulder", r.p * 0.9)
		setJ(r, "RightShoulder", r.p * 0.9)
		setJ(r, "Neck", r.p * 0.7)
	end
	for c, _ in rigs do
		if not c.Parent then
			rigs[c] = nil
		end
	end
end

-- ── camera hooks (CameraController, normal over-shoulder path only) ─────────────────────────────────────────────
-- Returns (focusYOffset, bobCFrame (camera-local), fovAdd).
function Movement.cameraStep(dt: number, rawFocusY: number): (number, CFrame, number)
	local _, hum, root = chr()
	-- smooth only small discontinuities (get-up pop, step-ups); follow exactly while falling / anchored
	local follow = not root
		or root.Anchored
		or (hum ~= nil and hum.FloorMaterial == Enum.Material.Air and mode == "none")
	if follow or not focusY then
		focusY = rawFocusY
	end
	local fy = focusY :: number
	fy += (rawFocusY - fy) * (1 - math.exp(-dt * 20))
	fy = math.clamp(fy, rawFocusY - 2.5, rawFocusY + 2.5)
	focusY = fy
	local s = serverStance()
	local dropT = if s == "prone" or s == "dive" then -0.9 elseif s == "crouch" then -0.35 else 0
	camDrop += (dropT - camDrop) * (1 - math.exp(-dt * 8))
	-- landing spring
	landVel += (-landDip * 150 - landVel * 17) * dt
	landDip = math.clamp(landDip + landVel * dt, -2, 1)
	-- sprint feel
	local speed = if root then flat(root.AssemblyLinearVelocity).Magnitude else 0
	local grounded = hum ~= nil and hum.FloorMaterial ~= Enum.Material.Air and mode == "none"
	local sT = if sprintApplied and grounded and speed > Config.WalkSpeed + 2 then 1 else 0
	sprintBlend += (sT - sprintBlend) * (1 - math.exp(-dt * 5))
	local lT = if exhausted and grounded and speed > 3 and stance == "stand" then 1 else 0
	limpAmp += (lT - limpAmp) * (1 - math.exp(-dt * 5))
	local mT = if grounded then math.clamp(speed / Config.SprintSpeed, 0, 1) else 0
	bobAmp += (mT - bobAmp) * (1 - math.exp(-dt * 6))
	bobPhase = (bobPhase + dt * speed * 0.75) % (math.pi * 2)
	local a = 0.11 * sprintBlend * bobAmp + 0.06 * limpAmp
	local bx = math.sin(bobPhase) * a * 0.8
	local by = -math.abs(math.sin(bobPhase)) * a * 1.1 - limpAmp * 0.06 * math.max(0, math.sin(bobPhase))
	local roll = math.sin(bobPhase) * 0.01 * (sprintBlend + limpAmp * 0.6)
	return fy - rawFocusY + camDrop + landDip, CFrame.new(bx, by, 0) * CFrame.Angles(0, 0, roll), M.SprintFov * sprintBlend
end

-- false while the body is driven by a dive / mantle / tumble (camera must not snap the root to the aim yaw)
function Movement.allowFacing(): boolean
	return mode ~= "dive" and mode ~= "mantle" and mode ~= "down"
end

function Movement.getStance(): string
	return stance
end

function Movement.getStamina(): (number, boolean)
	return stamina, exhausted
end

function Movement.isBusy(): boolean
	return mode ~= "none"
end

function Movement.getMode(): (string, number)
	return mode, os.clock() - modeT
end

local function resetLocal()
	if mode ~= "none" then
		setMode("none")
	end
	setStance("stand")
	crouchDownAt = nil
	hipCur, baseHip = nil, nil
	jumpEnabled = true
	jumpLock = false
	sprintApplied = false
	stamina, exhausted = 1, false
	minVy, landDip, landVel = 0, 0, 0
	focusY = nil
	sentStance = ""
end

function Movement.init()
	actionEv = Net.event("Action")
	Store.set("stance", stance)
	Store.set("moveMode", mode)
	Store.set("stamina", { v = stamina, exhausted = exhausted })
	Input.on("Crouch", onCrouch)
	Input.on("Prone", onProne)
	Input.on("Jump", onJump)
	Input.on("Sprint", function(d)
		-- sprint gets you up (edge-triggered so a toggled touch sprint doesn't fight crouch)
		if d and mode == "none" and stance ~= "stand" and not blockedInput() then
			standUp()
		end
	end)
	-- server reconcile
	Store.on("me", function(me)
		if type(me) ~= "table" or type(me.stamina) ~= "number" then
			return
		end
		if math.abs(me.stamina - stamina) > 0.2 then
			stamina = me.stamina
		end
		if me.exhausted == true and not exhausted and stamina < M.RecoverAt then
			exhausted = true
		end
	end)
	local okFx, Fx = pcall(require, script.Parent:FindFirstChild("Fx"))
	if okFx and type(Fx) == "table" and Fx.register then
		Fx.register("Knockdown", function(d)
			if type(d) == "table" and typeof(d.v) == "Vector3" then
				Movement.knockdown(d.v)
			end
		end)
	else
		warn("[Movement] Fx unavailable; knockdowns disabled")
	end
	player.CharacterAdded:Connect(resetLocal)
	RunService.PreSimulation:Connect(step)
	RunService.RenderStepped:Connect(poseStep)
	local ui = script.Parent:FindFirstChild("UI")
	local barMod = ui and ui:FindFirstChild("StaminaBar")
	if barMod then
		local okBar, Bar = pcall(require, barMod)
		if okBar and type(Bar) == "table" and Bar.init then
			Bar.init(function()
				return stamina, exhausted, sprintApplied
			end)
		end
	end
end

return Movement
