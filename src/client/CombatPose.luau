--!nonstrict
-- Combat pose (every client, every armed character): a real two-handed weapon hold instead of Roblox's
-- default "arm straight out" tool pose.
--   * the gun is placed in a shoulder pocket of the UpperTorso and pointed along the aim (local: camera pitch,
--     others: the replicated character attribute AimPitch, sent through the "aim" action)
--   * both arms are solved with analytic 2-bone IK onto the gun (right hand on the grip, left hand on the
--     foregrip; pistols: both hands on the grip, arms extended)
--   * the upper body leans into the aim (Waist C0), runs drop the gun to a low-ready across the body,
--     GunFeel's recoil/reload offset is applied in gun space (local player)
-- Runs in PreSimulation, after the Animator has written this frame's Motor6D.Transform values, so the arm
-- Transforms here replace the walk/idle arm animation while the legs keep animating.
-- Skipped while diving / tumbling / mantling / dead; then the default pose comes back.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local CombatPose = {}

local player = Players.LocalPlayer
local GunFeel: any = nil
local Movement: any = nil
local ArmorFx: any = nil
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
local UP = Vector3.new(0, 1, 0)
local CF0 = CFrame.identity
local clamp, exp, sqrt, abs = math.clamp, math.exp, math.sqrt, math.abs

-- ── tunables (studs / radians, UpperTorso space: +X right, +Y up, -Z forward) ──────────────────────────────
-- Roblox arms are short for the torso width (shoulder->wrist 1.64 studs, shoulders 1.5 off-centre), so a square
-- stance cannot get the left hand onto a rifle: the chest is BLADED (yawed so the left shoulder comes forward), the
-- head counter-turns to stay on target, and the gun sits near the centre line under the eye.
local POCKET = Vector3.new(0.42, 0.48, -0.45) -- rifle butt on the right shoulder (square chest frame; visible from the shoulder cam)
local GRIP_FROM_POCKET = Vector3.new(0, -0.32, -0.85) -- gun-space offset of the grip (handle origin) from the pocket
local BLADE = 0.55 -- chest yaw (rad) while holding a long gun; the left shoulder comes forward
local HEAD_SHARE = 0.6 -- part of the remaining aim pitch taken by the neck
local PISTOL_POCKET = Vector3.new(0.18, 0.38, -0.55)
local PISTOL_REACH = 1.55 -- how far forward of the pocket the pistol grip sits (arms almost straight)
local WAIST_SHARE = 0.45 -- part of the aim pitch taken by the spine
local LOW_READY_PITCH = -0.62
local LOW_READY_YAW = 0.55 -- muzzle swings to the left across the body
local LOW_READY_ROLL = -0.35
local RUN_SPEED = 19 -- horizontal speed above which a character carries the gun low (sprinting)
local AIM_SEND_EVERY = 0.12
-- Studio-only live tuning: workspace attributes PoseTune_<name> override the constants above (no restart needed)
local IS_STUDIO = RunService:IsStudio()
local function tune(name: string, default: any): any
	if not IS_STUDIO then
		return default
	end
	local v = Workspace:GetAttribute("PoseTune_" .. name)
	return if v ~= nil and typeof(v) == typeof(default) then v else default
end
local CULL_DIST = 220

-- wrist position relative to what the hand holds (gun space)
local R_WRIST = Vector3.new(0.05, 0.28, 0.12)
local L_WRIST = Vector3.new(-0.12, -0.02, 0.16)

-- uB / lB: part-space basis of each bone (bone direction, then a perpendicular reference), inverted, so the
-- solver works on rigs whose bones are not straight down the part's -Y (standard R15 shoulders sit on the
-- upper arm's top corner: the shoulder->elbow bone leans ~34 degrees)
type Arm = { sh: Motor6D, el: Motor6D, wr: Motor6D, a: number, b: number, uB: CFrame, lB: CFrame }
type Rig = {
	c: Model,
	hrp: BasePart,
	hum: Humanoid,
	root: Motor6D,
	waist: Motor6D,
	waistBase: CFrame,
	neck: Motor6D?,
	neckBase: CFrame?,
	R: Arm,
	L: Arm,
	grip: Weld?,
	gripBase: CFrame?,
	gripHandle: BasePart?,
	pitch: number,
	low: number,
	active: boolean,
}
local rigs: { [Model]: Rig } = {}

local function motor(c: Model, part: string, name: string): Motor6D?
	local p = c:FindFirstChild(part)
	local m = p and p:FindFirstChild(name)
	return if m and isJoint(m) then m else nil
end

-- orthonormal frame whose X column is the bone direction and Y column the part's X axis made perpendicular to it
local function boneBasis(dir: Vector3): CFrame
	local ref = Vector3.new(1, 0, 0) - dir * dir.X
	if ref.Magnitude < 1e-3 then
		ref = Vector3.new(0, 0, 1) - dir * dir.Z
	end
	ref = ref.Unit
	return CFrame.fromMatrix(Vector3.zero, dir, ref, dir:Cross(ref))
end

local function buildArm(c: Model, side: string): Arm?
	local sh = motor(c, side .. "UpperArm", side .. "Shoulder")
	local el = motor(c, side .. "LowerArm", side .. "Elbow")
	local wr = motor(c, side .. "Hand", side .. "Wrist")
	if not (sh and el and wr) then
		return nil
	end
	local ub = el.C0.Position - sh.C1.Position
	local lb = wr.C0.Position - el.C1.Position
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
	local neck = motor(c, "Head", "Neck")
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
		waistBase = waist.C0,
		neck = neck,
		neckBase = neck and neck.C0,
		R = R,
		L = L,
		pitch = 0,
		low = 0,
		active = false,
	}
end

-- ── IK ──────────────────────────────────────────────────────────────────────────────────────────────────────
-- Solves one arm so the wrist joint reaches `target`, elbow bent toward `pole`; hand keeps the forearm's line,
-- rolled by `handRoll`. Writes the three Transforms and returns the hand's world CFrame.
local function solveArm(arm: Arm, torso: CFrame, target: Vector3, pole: Vector3, handRot: CFrame?): CFrame
	local sh, el, wr = arm.sh, arm.el, arm.wr
	local shJoint = torso * sh.C0
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

	-- part rotation mapping the part-space bone frame onto the world bone frame (bone -> u/f, reference -> bend axis X)
	-- upper arm: placed so its shoulder point (C1) sits on the shoulder joint
	local R1 = CFrame.fromMatrix(Vector3.zero, u, X, u:Cross(X)) * arm.uB
	local upper = CFrame.new(S) * R1 * CFrame.new(-sh.C1.Position)
	sh.Transform = shJoint:Inverse() * upper * sh.C1

	-- forearm
	local elJoint = upper * el.C0
	local R2 = CFrame.fromMatrix(Vector3.zero, f, X, f:Cross(X)) * arm.lB
	local lower = CFrame.new(elJoint.Position) * R2 * CFrame.new(-el.C1.Position)
	el.Transform = elJoint:Inverse() * lower * el.C1

	-- hand
	local wrJoint = lower * wr.C0
	local R3 = handRot or R2
	local J3 = CFrame.new(wrJoint.Position) * R3 * wr.C1.Rotation
	wr.Transform = wrJoint:Inverse() * J3
	return J3 * wr.C1:Inverse()
end

-- ── per character ──────────────────────────────────────────────────────────────────────────────────────────
local function findGun(c: Model): (Instance?, BasePart?)
	local gun = c:FindFirstChild("Gun")
	local handle = gun and gun:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		return gun, handle
	end
	return nil, nil
end

local function release(r: Rig)
	if not r.active then
		return
	end
	r.active = false
	setC0(r.waist, r.waistBase)
	if r.neck and r.neckBase then
		setC0(r.neck, r.neckBase)
	end
	for _, arm in { r.R, r.L } do
		arm.sh.Transform = CF0
		arm.el.Transform = CF0
		arm.wr.Transform = CF0
	end
	if r.grip and r.grip.Parent and r.gripBase then
		r.grip.C0 = r.gripBase
	end
	r.grip, r.gripBase, r.gripHandle = nil, nil, nil
end

local function blocked(r: Rig, isLocal: boolean): boolean
	if r.hum.Health <= 0 then
		return true
	end
	local st = r.hum:GetState()
	if st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Ragdoll or st == Enum.HumanoidStateType.FallingDown or st == Enum.HumanoidStateType.Seated then
		return true
	end
	if isLocal then
		if Movement and Movement.isBusy and Movement.isBusy() then
			return true
		end
	else
		local s = r.c:GetAttribute("Stance")
		if s == "dive" or s == "down" then
			return true
		end
	end
	if r.hrp.Anchored then -- drop pod / cinematics
		return true
	end
	return false
end

local function step(r: Rig, dt: number, isLocal: boolean, cam: Camera)
	local _, handle = findGun(r.c)
	local grip = handle and r.c:FindFirstChild("RightHand") and (r.c.RightHand :: BasePart):FindFirstChild("RightGrip")
	if not handle or not grip or not grip:IsA("Weld") or grip.Part1 ~= handle or blocked(r, isLocal) then
		release(r)
		return
	end
	if r.grip ~= grip then
		release(r)
		r.grip = grip
		r.gripBase = grip.C0
		r.gripHandle = handle
	end
	r.active = true

	-- aim pitch
	local pitch: number
	if isLocal then
		pitch = math.asin(clamp(cam.CFrame.LookVector.Y, -1, 1))
	else
		local p = r.c:GetAttribute("AimPitch")
		pitch = if typeof(p) == "number" then p else 0
	end
	pitch = clamp(pitch, -1.2, 1.2)
	r.pitch += (pitch - r.pitch) * (1 - exp(-dt * (if isLocal then 40 else 14)))

	-- low ready while running (not while shooting / aiming)
	local vel = r.hrp.AssemblyLinearVelocity
	local hs = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local wantLow = hs > RUN_SPEED
	if isLocal and GunFeel and os.clock() - (GunFeel.lastShot or 0) < 0.6 then
		wantLow = false
	end
	r.low += ((if wantLow then 1 else 0) - r.low) * (1 - exp(-dt * 9))
	local low = r.low
	local p = r.pitch * (1 - low)

	local muzzle = handle:FindFirstChild("Muzzle")
	local reach = if muzzle and muzzle:IsA("Attachment") then -muzzle.Position.Z else 2
	local pistol = reach < 1.25

	-- spine: lean into the aim pitch, blade the chest for long guns (less while running at low-ready)
	local blade = (if pistol then tune("PistolBlade", 0.2) else tune("Blade", BLADE)) * (1 - low * 0.6)
	local waistShare = tune("WaistShare", WAIST_SHARE)
	setC0(
		r.waist,
		r.waistBase * (if ArmorFx and ArmorFx.waistOffset then ArmorFx.waistOffset else CF0) * CFrame.Angles(p * waistShare, 0, 0) * CFrame.Angles(0, -blade, 0)
	)
	-- head: undo the blade and take part of the remaining pitch, so the visor looks down the sights
	if r.neck and r.neckBase then
		setC0(r.neck, r.neckBase * CFrame.Angles(0, blade, 0) * CFrame.Angles(p * (1 - waistShare) * tune("HeadShare", HEAD_SHARE), 0, 0))
	end

	-- forward kinematics down to the upper torso (this frame's animated Transforms)
	local hrpCF = r.hrp.CFrame
	local lower = hrpCF * r.root.C0 * r.root.Transform * r.root.C1:Inverse()
	local upper = lower * r.waist.C0 * r.waist.Transform * r.waist.C1:Inverse()
	-- the same chest without the blade yaw: pockets are authored in this square frame
	local square = upper * CFrame.Angles(0, blade, 0)

	-- gun frame: yaw of the root, pitch of the aim, plus low-ready
	local look = hrpCF.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local yawCF = CFrame.lookAt(Vector3.zero, flat, UP)
	local gp = r.pitch * (1 - low) + LOW_READY_PITCH * low
	local aimRot = yawCF * CFrame.Angles(0, LOW_READY_YAW * low, 0) * CFrame.Angles(gp, 0, LOW_READY_ROLL * low)

	local gunCF: CFrame
	if pistol then
		local pocket = square * tune("PistolPocket", PISTOL_POCKET)
		gunCF = CFrame.new(pocket) * aimRot * CFrame.new(0, -0.1, -tune("PistolReach", PISTOL_REACH))
	else
		local pocket = square * tune("Pocket", POCKET)
		gunCF = CFrame.new(pocket) * aimRot * CFrame.new(tune("Grip", GRIP_FROM_POCKET))
	end
	if isLocal and GunFeel then
		gunCF = gunCF * (GunFeel.offset or CF0)
	end

	-- arms
	local right = upper.RightVector
	local back = -upper.LookVector
	local down = -upper.UpVector
	local rTarget = (gunCF * CFrame.new(R_WRIST)).Position
	local lTarget: Vector3
	if pistol then
		lTarget = (gunCF * CFrame.new(-0.16, 0.12, 0.16)).Position
	else
		-- support hand slides along the handguard: as far forward as wanted, but never past what the left arm
		-- can reach (long guns on short Roblox arms), so the hand stays ON the gun instead of hovering short of it
		local want = clamp(reach * 0.5, 0.75, 1.7)
		local P0 = (gunCF * CFrame.new(L_WRIST)).Position
		local D = gunCF.LookVector
		local w = P0 - (upper * r.L.sh.C0).Position
		local R = (r.L.a + r.L.b) * 0.97
		local wd = w:Dot(D)
		local disc = wd * wd - w:Dot(w) + R * R
		local fg = if disc >= 0 then -wd + sqrt(disc) else -wd
		fg = clamp(math.min(fg, want), 0.35, want)
		lTarget = P0 + D * fg
	end
	local gunRot = gunCF.Rotation
	-- hands: fingers (-Y) wrap down around the grip / under the handguard, palms facing the gun
	local rHandRot = gunRot * CFrame.Angles(-0.35, 0, 0)
	local lHandRot = gunRot * CFrame.Angles(-1.1, 0, -0.5)
	local rHand = solveArm(r.R, upper, rTarget, down + right * 0.9 + back * 0.35, rHandRot)
	solveArm(r.L, upper, lTarget, down * 1.2 - right * 0.25 + back * 0.1, lHandRot)

	-- weld the gun where we want it, relative to the solved right hand
	grip.C0 = rHand:Inverse() * gunCF * grip.C1
end

local lastSent, lastSentAt = 0, 0

local function frame(dt: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
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
		if not r then
			if not findGun(c) then
				continue
			end
			r = buildRig(c)
			if not r then
				continue
			end
			rigs[c] = r
		end
		local rr = r :: Rig
		local isLocal = plr == player
		if not isLocal and (rr.hrp.Position - camPos).Magnitude > CULL_DIST then
			release(rr)
			continue
		end
		local ok, err = pcall(step, rr, dt, isLocal, cam)
		if not ok then
			release(rr)
			warn("[CombatPose]", err)
		end
	end
	for c, r in rigs do
		if not c.Parent then
			rigs[c] = nil
		end
	end

	-- share our aim pitch
	local t = os.clock()
	if actionEv and t - lastSentAt > AIM_SEND_EVERY then
		local pitch = math.asin(clamp(cam.CFrame.LookVector.Y, -1, 1))
		if abs(pitch - lastSent) > 0.03 then
			lastSent, lastSentAt = pitch, t
			actionEv:FireServer("aim", pitch)
		end
	end
end

function CombatPose.init(gunFeel: any, movement: any, armorFx: any)
	ArmorFx = armorFx
	if ArmorFx then
		ArmorFx.external = true
	end
	GunFeel = gunFeel
	Movement = movement
	if GunFeel then
		GunFeel.external = true
	end
	actionEv = Net.event("Action")
	RunService.PreSimulation:Connect(function(dt)
		frame(dt)
	end)
end

return CombatPose
