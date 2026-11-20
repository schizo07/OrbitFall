-- Haul objective ("Recover Core Cells"), client side of carrying a core cell.
-- Server: server/Objectives/HaulCells.luau (pickup prompt, weld, drop, delivery). Rules: shared/Carry.luau.
--   * Input gates while the local trooper carries (Player attribute `CarryCell`): Aim always reads as released, Fire
--     reads as released at 2 cells (1 cell hip-fires the equipped weapon), Grenade throws are skipped
--     (WeaponController checks Input.isGated).
--   * Interact (E) or Grenade (G / R1 / the touch GRENADE button) drops the cell: Action "cellDrop".
--   * Pose: 2 cells = both arms hold the stack, gun hidden. 1 cell = left arm holds the cell at the hip, the gun stays
--     in the right hand and CombatPose drives that arm (hipFire pose, runs after this module each frame).
-- Carry speed (walk and sprint, shared/Carry.speedMult) and animation cadence live in client/Movement.luau.
-- Carry pose + heavier movement live here on PreSimulation (every client, every carrier; CombatPose yields via ownsPose).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Carry = require(Shared.Carry)
local DownedRules = require(Shared.Downed)
local Input = require(script.Parent.Input)
local Store = require(script.Parent.Store)
local fxFolder = script.Parent:FindFirstChild("Fx")
local ArmorFx: any = if fxFolder and fxFolder:FindFirstChild("ArmorFx") then require(fxFolder:FindFirstChild("ArmorFx") :: ModuleScript) else nil

local CellCarry = {}

local player = Players.LocalPlayer
local actionEv: RemoteEvent? = nil
local lastDrop = 0

local clamp, exp, sqrt, abs = math.clamp, math.exp, math.sqrt, math.abs
local UP = Vector3.new(0, 1, 0)
local CF0 = CFrame.identity
local IS_STUDIO = RunService:IsStudio()
local CULL_DIST = 220

local localSprinting = false
local localGrounded = true
local localStance = "stand"
local localBusy = false

local function slot(): number?
	local m = Store.get("me")
	return if type(m) == "table" and type(m.weapon) == "number" then m.weapon else nil
end

function CellCarry.isCarrying(): boolean
	return Carry.isCarrying(player)
end

function CellCarry.carryCount(who: Instance?): number
	return Carry.count(who or player)
end

function CellCarry.setLocal(sprinting: boolean, grounded: boolean, stance: string, busy: boolean)
	localSprinting = sprinting
	localGrounded = grounded
	localStance = stance
	localBusy = busy
end

-- ── carry pose + heavier movement (Motor6D / Transform, every client) ─────────────────────────────────────────
local CARRY_HAND = Vector3.new(Carry.SIZE.X / 2 + 0.08, -0.14, 0.08) -- wrist target in cell space (X mirrored for left)
local CARRY_LEAN_BACK = 0.16 -- rad, standing / walking lean back
local CARRY_LEAN_SPRINT = -0.26 -- rad, sprinting forward lean
local CARRY_ROLL = 0.075 -- rad of upper-body side-to-side sway at full walk
local CARRY_TWIST = 0.05 -- rad of shoulder counter-twist with the steps
local CARRY_SWAY_LAT = 0.08 -- studs of pelvis side-to-side weight shift
local CARRY_BOB_WALK = 0.21 -- studs of vertical bounce per step while walking
local CARRY_BOB_SPRINT = 0.28 -- studs of vertical bounce per step while sprinting
local STEP_RATE_WALK = 0.46 -- stride phase (rad) per stud moved while walking
local STEP_RATE_SPRINT = 0.54 -- stride phase (rad) per stud moved while sprinting

local function tune(name: string, default: any): any
	if not IS_STUDIO then
		return default
	end
	local v = Workspace:GetAttribute("PoseTune_" .. name)
	return if v ~= nil and typeof(v) == typeof(default) then v else default
end

local function isJoint(x: Instance?): boolean
	return x ~= nil and (x:IsA("Motor6D") or x:IsA("AnimationConstraint"))
end

local function c0Of(j: any): CFrame
	if j:IsA("AnimationConstraint") then
		return if j.Attachment0 then j.Attachment0.CFrame else CF0
	end
	return j.C0
end

local function c1Of(j: any): CFrame
	if j:IsA("AnimationConstraint") then
		return if j.Attachment1 then j.Attachment1.CFrame else CF0
	end
	return j.C1
end

local function motor(c: Model, part: string, name: string): any
	local p = c:FindFirstChild(part)
	local m = p and p:FindFirstChild(name)
	return if m and isJoint(m) then m else nil
end

local function boneBasis(dir: Vector3): CFrame
	local ref = Vector3.new(1, 0, 0) - dir * dir.X
	if ref.Magnitude < 1e-3 then
		ref = Vector3.new(0, 0, 1) - dir * dir.Z
	end
	ref = ref.Unit
	return CFrame.fromMatrix(Vector3.zero, dir, ref, dir:Cross(ref))
end

type Arm = { sh: any, el: any, wr: any, a: number, b: number, uB: CFrame, lB: CFrame }
type Rig = {
	c: Model,
	hrp: BasePart,
	hum: Humanoid,
	root: any,
	waist: any,
	neck: any?,
	lHip: any?,
	rHip: any?,
	lKnee: any?,
	rKnee: any?,
	R: Arm,
	L: Arm,
	ph: number,
	lean: number,
	walkW: number,
	sprintW: number,
	gunHidden: boolean,
	active: boolean,
}
local rigs: { [Model]: Rig } = {}

local function buildArm(c: Model, side: string): Arm?
	local sh = motor(c, side .. "UpperArm", side .. "Shoulder")
	local el = motor(c, side .. "LowerArm", side .. "Elbow")
	local wr = motor(c, side .. "Hand", side .. "Wrist")
	if not (sh and el and wr) then
		return nil
	end
	local ub = c0Of(el).Position - c1Of(sh).Position
	local lb = c0Of(wr).Position - c1Of(el).Position
	local a, b = ub.Magnitude, lb.Magnitude
	if a < 0.1 or b < 0.1 then
		return nil
	end
	return { sh = sh, el = el, wr = wr, a = a, b = b, uB = boneBasis(ub / a):Inverse(), lB = boneBasis(lb / b):Inverse() }
end

local function buildRig(c: Model): Rig?
	local hrp = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = c:FindFirstChildOfClass("Humanoid")
	if not hrp or not hum or hum.RigType ~= Enum.HumanoidRigType.R15 then
		return nil
	end
	local root = motor(c, "LowerTorso", "Root")
	local waist = motor(c, "UpperTorso", "Waist")
	local R, L = buildArm(c, "Right"), buildArm(c, "Left")
	if not (root and waist and R and L) then
		return nil
	end
	return {
		c = c,
		hrp = hrp,
		hum = hum,
		root = root,
		waist = waist,
		neck = motor(c, "Head", "Neck"),
		lHip = motor(c, "LeftUpperLeg", "LeftHip"),
		rHip = motor(c, "RightUpperLeg", "RightHip"),
		lKnee = motor(c, "LeftLowerLeg", "LeftKnee"),
		rKnee = motor(c, "RightLowerLeg", "RightKnee"),
		R = R,
		L = L,
		ph = 0,
		lean = CARRY_LEAN_BACK,
		walkW = 0,
		sprintW = 0,
		gunHidden = false,
		active = false,
	}
end

local function solveArm(arm: Arm, torso: CFrame, target: Vector3, pole: Vector3, handRot: CFrame)
	local sh, el, wr = arm.sh, arm.el, arm.wr
	local shJoint = torso * c0Of(sh)
	local S = shJoint.Position
	local a, b = arm.a, arm.b
	local v = target - S
	local d = v.Magnitude
	local dir = if d > 1e-4 then v / d else -UP
	d = clamp(d, abs(a - b) + 0.02, a + b - 0.002)
	local perp = pole - dir * pole:Dot(dir)
	if perp.Magnitude < 1e-3 then
		perp = (-UP) - dir * (-UP):Dot(dir)
		if perp.Magnitude < 1e-3 then
			perp = Vector3.new(1, 0, 0)
		end
	end
	perp = perp.Unit
	local cosA = clamp((a * a + d * d - b * b) / (2 * a * d), -1, 1)
	local sinA = sqrt(1 - cosA * cosA)
	local E = S + dir * (a * cosA) + perp * (a * sinA)
	local T = S + dir * d
	local u = (E - S).Unit
	local f = (T - E).Unit
	local X = u:Cross(f)
	if X.Magnitude < 1e-3 then
		X = perp:Cross(u)
	end
	X = X.Unit

	local sc1, ec1, wc1 = c1Of(sh), c1Of(el), c1Of(wr)
	local R1 = CFrame.fromMatrix(Vector3.zero, u, X, u:Cross(X)) * arm.uB
	local upper = CFrame.new(S) * R1 * CFrame.new(-sc1.Position)
	sh.Transform = shJoint:Inverse() * upper * sc1

	local elJoint = upper * c0Of(el)
	local R2 = CFrame.fromMatrix(Vector3.zero, f, X, f:Cross(X)) * arm.lB
	local lower = CFrame.new(elJoint.Position) * R2 * CFrame.new(-ec1.Position)
	el.Transform = elJoint:Inverse() * lower * ec1

	local wrJoint = lower * c0Of(wr)
	local J3 = CFrame.new(wrJoint.Position) * handRot * wc1.Rotation
	wr.Transform = wrJoint:Inverse() * J3
end

local function showGun(r: Rig, on: boolean)
	if on and not r.gunHidden then
		return
	end
	local gun = r.c:FindFirstChild("Gun")
	if gun then
		for _, d in gun:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = if on then 0 else 1
			end
		end
	end
	r.gunHidden = not on
end

local function releaseRig(r: Rig)
	if not r.active and not r.gunHidden then
		return
	end
	r.active = false
	r.walkW = 0
	r.sprintW = 0
	r.lean = CARRY_LEAN_BACK
	showGun(r, true)
end

-- True while this character is in a cell carry pose (CombatPose yields to this).
function CellCarry.ownsPose(c: Model?): boolean
	if not c or not Carry.isCarrying(c) or c:GetAttribute(DownedRules.ATTR) == true then
		return false
	end
	local hum = c:FindFirstChildOfClass("Humanoid")
	local hrp = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not hrp or hum.Health <= 0 or hrp.Anchored then
		return false
	end
	local st = hum:GetState()
	if st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Ragdoll or st == Enum.HumanoidStateType.FallingDown or st == Enum.HumanoidStateType.Seated then
		return false
	end
	if c == player.Character then
		if localBusy or localStance == "prone" then
			return false
		end
	else
		local s = c:GetAttribute("Stance")
		if s == "dive" or s == "down" or s == "prone" or s == "mantle" then
			return false
		end
	end
	return true
end

-- True while this character carries one cell and keeps the weapon in the right hand (CombatPose draws that arm + gun).
function CellCarry.holdsGun(c: Model?): boolean
	return Carry.holdsGun(c) and CellCarry.ownsPose(c)
end

function CellCarry.cameraBob(grounded: boolean): (number, number, number)
	local c = player.Character
	local r = if c then rigs[c] else nil
	local cnt = if c then Carry.count(c) else 0
	if not r or not r.active or not grounded or r.walkW < 0.01 or cnt <= 0 then
		return 0, 0, 0
	end
	local camScale = if cnt >= Carry.MAX_CELLS then 1.15 else 0.45
	local sw = math.sin(r.ph) * r.walkW
	local bounce = 0.5 * (1 - math.cos(2 * r.ph)) * r.walkW
	local amp = (0.045 + 0.055 * r.sprintW) * camScale
	return sw * amp * 0.7, (0.35 - bounce) * amp * 1.1, sw * (0.008 + 0.008 * r.sprintW) * camScale
end

local function stepRig(r: Rig, dt: number, isLocal: boolean)
	r.active = true
	local count = Carry.count(r.c)
	local twoHands = count >= Carry.MAX_CELLS
	local weight = if twoHands then 1 else 0.48

	local v = r.hrp.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local grounded = if isLocal then localGrounded else (r.hum.FloorMaterial ~= Enum.Material.Air)
	local crouching = if isLocal then (localStance == "crouch") else (r.c:GetAttribute("Stance") == "crouch")
	local sprinting = if isLocal then localSprinting else (r.c:GetAttribute("Sprinting") == true)

	local walkT = if grounded and speed > 0.6 then clamp(speed / 10, 0, 1) * (if crouching then 0.35 else 1) else 0
	local sprintT = if not twoHands and sprinting and grounded and speed > 0.6 and not crouching then 1 else 0
	r.walkW += (walkT - r.walkW) * (1 - exp(-dt * 8))
	r.sprintW += (sprintT - r.sprintW) * (1 - exp(-dt * 7))

	local stepRate = STEP_RATE_WALK + (STEP_RATE_SPRINT - STEP_RATE_WALK) * r.sprintW
	if grounded and speed > 0.6 then
		r.ph = (r.ph + dt * speed * stepRate) % (2 * math.pi)
	end

	local sw = math.sin(r.ph) * r.walkW
	local bounce = 0.5 * (1 - math.cos(2 * r.ph))
	local leanWalk = if twoHands then CARRY_LEAN_BACK else CARRY_LEAN_BACK * 0.40
	local leanSprint = if twoHands then CARRY_LEAN_SPRINT else CARRY_LEAN_SPRINT * 0.55
	local leanT = leanWalk + (leanSprint - leanWalk) * r.sprintW
	if crouching then
		leanT = leanWalk * 0.5
	end
	r.lean += (leanT - r.lean) * (1 - exp(-dt * 7))

	-- Pelvis: weighted walk/sprint bob + lateral weight shift + sprint tilt
	local rawRoot = r.root.Transform
	if not crouching then
		local bobAmp = (CARRY_BOB_WALK + (CARRY_BOB_SPRINT - CARRY_BOB_WALK) * r.sprintW) * weight
		local bobY = (0.35 - bounce) * bobAmp * r.walkW
		local swayX = sw * (CARRY_SWAY_LAT + 0.03 * r.sprintW) * weight
		local pelvisPitch = -0.07 * r.sprintW * weight
		local pelvisRoll = -sw * 0.045 * weight
		local rootBlend = if twoHands then 0.75 else 0.85
		r.root.Transform = CFrame.new(swayX, bobY, 0) * CFrame.Angles(pelvisPitch, 0, pelvisRoll) * CF0:Lerp(rawRoot, rootBlend)

		-- Heavier step: extra hip/knee compression on each footstrike (lighter for 1 cell, full for 2 cells)
		if r.walkW > 0.01 then
			local hipExtra = (0.08 + 0.12 * r.sprintW) * bounce * r.walkW * weight
			local kneeExtra = -(0.14 + 0.22 * r.sprintW) * bounce * r.walkW * weight
			local stanceOut = 0.05 * r.walkW * weight
			if r.lHip then
				r.lHip.Transform = r.lHip.Transform * CFrame.Angles(hipExtra, 0, -stanceOut)
			end
			if r.rHip then
				r.rHip.Transform = r.rHip.Transform * CFrame.Angles(hipExtra, 0, stanceOut)
			end
			if r.lKnee then
				r.lKnee.Transform = r.lKnee.Transform * CFrame.Angles(kneeExtra, 0, 0)
			end
			if r.rKnee then
				r.rKnee.Transform = r.rKnee.Transform * CFrame.Angles(kneeExtra, 0, 0)
			end
		end
	end

	-- Upper body: load lean (subtle left-side load lean for 1 cell), side-to-side sway & step nod
	local stepPitch = -(0.03 + 0.06 * r.sprintW) * bounce * r.walkW * weight
	local sideLoadLean = if twoHands then 0 else 0.045
	local roll = sideLoadLean + sw * (CARRY_ROLL + 0.025 * r.sprintW) * weight
	local twist = sw * (CARRY_TWIST + 0.02 * r.sprintW) * weight
	local stagger = if isLocal and ArmorFx and ArmorFx.waistOffset then ArmorFx.waistOffset else CF0
	local waistBlend = if twoHands then 0.2 else 0.35
	r.waist.Transform = CF0:Lerp(r.waist.Transform, waistBlend) * stagger * CFrame.Angles(r.lean + stepPitch, twist, roll)

	if r.neck then
		-- Head stays level-ish over the load (counters most of the lean and sway)
		r.neck.Transform = CF0:Lerp(r.neck.Transform, 0.35) * CFrame.Angles(-(r.lean + stepPitch) * 0.65, 0, -roll * 0.55)
	end

	-- Arms: 2 cells = two-handed chest carry; 1 cell = left hand at the hip, the right arm belongs to CombatPose (hip-fire)
	local hrpCF = r.hrp.CFrame
	local lower = hrpCF * c0Of(r.root) * r.root.Transform * c1Of(r.root):Inverse()
	local upper = lower * c0Of(r.waist) * r.waist.Transform * c1Of(r.waist):Inverse()
	local right, back, up = upper.RightVector, -upper.LookVector, upper.UpVector
	if twoHands then
		local cell = upper * Carry.HOLD
		local h = tune("CarryHand", CARRY_HAND) :: Vector3
		local rPole = right * 1.55 + back * 0.45 + up * 0.12
		local lPole = -right * 1.55 + back * 0.45 + up * 0.12
		local rRot = cell.Rotation * CFrame.Angles(-0.35, 0, -0.25)
		local lRot = cell.Rotation * CFrame.Angles(-0.35, 0, 0.25)
		solveArm(r.R, upper, (cell * CFrame.new(h.X, h.Y, h.Z)).Position, rPole, rRot)
		solveArm(r.L, upper, (cell * CFrame.new(-h.X, h.Y, h.Z)).Position, lPole, lRot)
	else
		local cell = upper * Carry.HOLD_ONE
		local gripPos = (cell * CFrame.new(0, Carry.SIZE.Y / 2 + 0.10, 0)).Position
		local lPole = -right * 1.15 + back * 0.85 + up * 0.10
		local lRot = upper.Rotation * CFrame.Angles(-0.15, 0, 0.15)
		solveArm(r.L, upper, gripPos, lPole, lRot)
	end
	showGun(r, not twoHands)
end

local function frame(dt: number)
	local cam = Workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else nil
	for _, plr in Players:GetPlayers() do
		local c = plr.Character
		if not c then
			continue
		end
		local r = rigs[c]
		if r and (not r.hrp.Parent or not r.waist.Parent or not r.R.sh.Parent or not r.L.sh.Parent) then
			rigs[c] = nil
			r = nil
		end
		if not CellCarry.ownsPose(c) then
			if r then
				releaseRig(r)
			end
			continue
		end
		if not r then
			r = buildRig(c)
			if not r then
				continue
			end
			rigs[c] = r
		end
		local rr = r :: Rig
		local isLocal = plr == player
		if not isLocal and camPos and (rr.hrp.Position - camPos).Magnitude > CULL_DIST then
			releaseRig(rr)
			continue
		end
		local ok, err = pcall(stepRig, rr, dt, isLocal)
		if not ok then
			releaseRig(rr)
			warn("[CellCarry]", err)
		end
	end
	for c in rigs do
		if not c.Parent then
			rigs[c] = nil
		end
	end
end

local function dropKeyText(): string
	if Input.isTouch() then
		return "GRENADE"
	elseif Input.isGamepad() then
		return "R1"
	end
	return "E / G"
end

local inited = false
function CellCarry.init()
	if inited then
		return
	end
	inited = true
	actionEv = Net.event("Action")
	-- the same gates also carry the downed rules (shared/Downed.luau: sidearm only, no grenades)
	Input.setGate("Fire", function()
		return Carry.blocks(player, "fire", slot()) or DownedRules.blocks(player, "fire", slot())
	end)
	Input.setGate("Aim", function()
		return Carry.blocks(player, "aim", slot()) or DownedRules.blocks(player, "aim", slot())
	end)
	Input.setGate("Grenade", function()
		return Carry.blocks(player, "grenade") or DownedRules.blocks(player, "grenade")
	end)

	local function tryDrop(d: boolean)
		if d and CellCarry.isCarrying() and os.clock() - lastDrop > 0.3 and actionEv then
			lastDrop = os.clock()
			actionEv:FireServer("cellDrop")
		end
	end
	Input.on("Interact", tryDrop)
	Input.on("Grenade", tryDrop)

	local lastCount = Carry.count(player)
	local function onCarryChange()
		local cnt = Carry.count(player)
		if cnt > lastCount then
			if cnt >= Carry.MAX_CELLS then
				Store.set("toast", "Carrying 2 core cells (heavy, no sprint). Load at the cargo lifter. [" .. dropKeyText() .. "] drop one")
			else
				Store.set("toast", "Core cell in hand (1/2): hip-fire only. Grab another or load at the cargo lifter. [" .. dropKeyText() .. "] drop")
			end
		end
		lastCount = cnt
	end
	player:GetAttributeChangedSignal(Carry.COUNT_ATTR):Connect(onCarryChange)
	player:GetAttributeChangedSignal(Carry.ATTR):Connect(onCarryChange)
	RunService.PreSimulation:Connect(frame)
end

return CellCarry
