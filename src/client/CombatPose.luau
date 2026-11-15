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
local Carry = require(Shared.Carry) -- haul objective carry pose
local Input = require(script.Parent.Input)
local Store = require(script.Parent.Store)

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

-- X-mirror of a CFrame (reflect through the YZ plane on both sides)
local function mirrorX(cf: CFrame): CFrame
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return CFrame.new(-x, y, z, r00, -r01, -r02, -r10, r11, r12, -r20, r21, r22)
end
-- scale a vector's X (mirror = -1)
local function sx(v: Vector3, s: number): Vector3
	return Vector3.new(v.X * s, v.Y, v.Z)
end

-- ── tunables (studs / radians, UpperTorso space: +X right, +Y up, -Z forward) ──────────────────────────────
-- Roblox arms are short for the torso width (shoulder->wrist 1.64 studs, shoulders 1.5 off-centre), so a square
-- stance cannot get the left hand onto a rifle: the chest is BLADED (yawed so the left shoulder comes forward), the
-- head counter-turns to stay on target, and the gun sits near the centre line under the eye.
-- 2026-11-14 playtest pick (Variants FRAMING D): rifle raised to cheek height, out of the right glove's shadow
local POCKET = Vector3.new(0.85, 0.95, -0.4) -- rifle butt (square chest frame; was 0.42, 0.48, -0.45)
local GRIP_FROM_POCKET = Vector3.new(0, -0.32, -0.85) -- gun-space offset of the grip (handle origin) from the pocket
local BLADE = 0.35 -- chest yaw (rad) while holding a long gun; the left shoulder comes forward (was 0.55)
local HEAD_SHARE = 0.6 -- part of the remaining aim pitch taken by the neck
-- local player aiming down sights: the cheek pocket sits flush against the (2-stud) helmet, so from the ADS camera
-- the gun hides behind the head / right glove. Slide it out to the right (square chest frame) while aiming.
local ADS_POCKET_SHIFT = Vector3.new(0.45, -0.1, 0)
local PISTOL_POCKET = Vector3.new(0.18, 0.38, -0.55)
local PISTOL_REACH = 1.55 -- how far forward of the pocket the pistol grip sits (arms almost straight)
local WAIST_SHARE = 0.45 -- part of the aim pitch taken by the spine
local LOW_READY_PITCH = -0.62
local LOW_READY_YAW = 0.55 -- muzzle swings to the left across the body
local LOW_READY_ROLL = -0.35
local RUN_SPEED = 19 -- horizontal speed above which a character carries the gun low (sprinting)
local AIM_SEND_EVERY = 0.12
-- Left shoulder (V / R3, Store "camSide" = -1), Studio A/B workspace attribute Feel_LeftShoulder: nil = the gun
-- follows the camera to the left shoulder (left hand on the grip, right hand on the handguard); "camera" and "old"
-- keep the gun right-handed (CameraController owns the "camera" fix). Local player only: the hand does not replicate.
local HAND_RATE = 10 -- hand swap blend speed (exp rate, 1/s), same as the camera's shoulder swap
local SWAP_DIP = Vector3.new(0, -0.45, -0.25) -- square chest frame, x (1 - h^2): mid-swap the gun ducks under the chin
local SWAP_BAND = 0.35 -- the hands trade grip / handguard only while |h| < this (gun near the centre line)
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
	ads: number, -- local aim-down-sights blend (0..1)
	hand: number, -- smoothed handedness: +1 gun on the right shoulder .. -1 on the left (local player only)
	active: boolean,
	gunHidden: boolean?, -- haul carry pose hid the gun (showGun)
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
		ads = 0,
		hand = 1,
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

-- haul carry: hide the gun locally while both hands hold a core cell (re-applied every carry frame: swaps rebuild the gun)
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
	showGun(r, true)
end

-- ── haul objective carry pose (character attribute CarryCell, shared/Carry.luau) ─────────────────────────────
-- Both hands on the core cell the server welds at Carry.HOLD in front of the belly; the gun is hidden (local
-- transparency) meanwhile. SIDEARM rule with the pistol in hand: the normal pose, so the sidearm can aim.
local CARRY_HAND = Vector3.new(Carry.SIZE.X / 2 + 0.14, 0.2, 0) -- wrist target in cell space (x mirrored for the left)
local function wantsCarry(r: Rig, handle: BasePart): boolean
	if r.c:GetAttribute(Carry.ATTR) ~= true then
		return false
	end
	if Carry.rule() == "SIDEARM" then
		local muzzle = handle:FindFirstChild("Muzzle")
		local reach = if muzzle and muzzle:IsA("Attachment") then -muzzle.Position.Z else 2
		if reach < 1.25 then
			return false
		end
	end
	return true
end

local function carryStep(r: Rig, dt: number)
	r.pitch += (0 - r.pitch) * (1 - exp(-dt * 10))
	r.low, r.ads = 0, 0
	setC0(r.waist, r.waistBase * (if ArmorFx and ArmorFx.waistOffset then ArmorFx.waistOffset else CF0) * CFrame.Angles(-0.06, 0, 0))
	if r.neck and r.neckBase then
		setC0(r.neck, r.neckBase)
	end
	local hrpCF = r.hrp.CFrame
	local lower = hrpCF * r.root.C0 * r.root.Transform * r.root.C1:Inverse()
	local upper = lower * r.waist.C0 * r.waist.Transform * r.waist.C1:Inverse()
	local cell = upper * Carry.HOLD
	local right, back, down = upper.RightVector, -upper.LookVector, -upper.UpVector
	local h = tune("CarryHand", CARRY_HAND)
	solveArm(r.R, upper, (cell * CFrame.new(h.X, h.Y, h.Z)).Position, down + right * 0.8 + back * 0.3, cell.Rotation)
	solveArm(r.L, upper, (cell * CFrame.new(-h.X, h.Y, h.Z)).Position, down - right * 0.8 + back * 0.3, cell.Rotation)
	showGun(r, false)
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

-- ── stim injection pose ──────────────────────────────────────────────────────────────────────────────────────
-- VitalsFx's Fx "Stim" calls CombatPose.stimPose(userId) for every client. The free hand (the support hand: left, or
-- the right one while the gun sits in the left hand) swings an injector to the neck, jabs, drops back; the gun hand
-- is untouched, so moving and shooting one-handed carry on. Studio A/B workspace attribute Feel_StimPose:
-- nil = neck jab 0.55 s, "thigh" = thigh jab 0.4 s without head tilt, "off" = no pose.
-- Profile times (s): arm up by `rise`, jab runs j0 -> j1 (in) -> j2 (out), arm drops from `drop0` to `dur`.
local STIM_NECK = { rise = 0.2, j0 = 0.2, j1 = 0.29, j2 = 0.38, drop0 = 0.38, dur = 0.55 }
local STIM_THIGH = { rise = 0.13, j0 = 0.13, j1 = 0.19, j2 = 0.26, drop0 = 0.26, dur = 0.4 }
local STIM_PRONE_SHARE = 0.6 -- lying down: the arm only goes this far toward the target, no head tilt
local STIM_TILT = 0.2 -- head roll (rad) away from the injected side
type StimState = { t0: number, thigh: boolean, p: any, arm: string?, prop: Instance? }
local stims: { [Model]: StimState } = {}

local function smooth(x: number): number
	x = clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- arm weight, jab and head tilt amounts (all 0..1) at elapsed time e
local function stimEnvelope(p: any, e: number): (number, number, number)
	local w = smooth(e / p.rise) * (1 - smooth((e - p.drop0) / (p.dur - p.drop0)))
	local jab = 0
	if e >= p.j0 and e < p.j1 then
		jab = smooth((e - p.j0) / (p.j1 - p.j0))
	elseif e >= p.j1 and e <= p.j2 then
		jab = 1 - smooth((e - p.j1) / (p.j2 - p.j1))
	end
	return w, jab, w * (0.5 + 0.5 * jab)
end

local function makeInjector(c: Model, arm: string): Instance?
	local hand = c:FindFirstChild(arm .. "Hand")
	if not hand or not hand:IsA("BasePart") then
		return nil
	end
	local function part(size: Vector3, color: Color3, mat: Enum.Material, cf: CFrame, shape: Enum.PartType): Part
		local x = Instance.new("Part")
		x.Name = "StimInjector"
		x.Shape = shape
		x.Size = size
		x.Color = color
		x.Material = mat
		x.CanCollide = false
		x.CanQuery = false
		x.CanTouch = false
		x.Massless = true
		x.CastShadow = false
		x.CFrame = (hand :: BasePart).CFrame * cf
		local w = Instance.new("Weld")
		w.Part0 = hand :: BasePart
		w.Part1 = x
		w.C0 = cf
		w.Parent = x
		x.Parent = c
		return x
	end
	-- barrel along the hand's -Y (the fingers' direction), neon tip at the far end
	local barrel = part(Vector3.new(0.9, 0.25, 0.25), Color3.fromRGB(70, 78, 92), Enum.Material.Metal, CFrame.new(0, -0.3, 0) * CFrame.Angles(0, 0, math.rad(90)), Enum.PartType.Cylinder)
	part(Vector3.new(0.22, 0.17, 0.17), Color3.fromRGB(90, 255, 150), Enum.Material.Neon, CFrame.new(0, -0.86, 0) * CFrame.Angles(0, 0, math.rad(90)), Enum.PartType.Cylinder).Parent = barrel
	return barrel
end

local function dropStim(c: Model)
	local s = stims[c]
	if s then
		if s.prop then
			s.prop:Destroy()
		end
		stims[c] = nil
	end
end

-- wrist target, elbow pole and hand rotation for the injecting arm (side: -1 left hand, +1 right hand)
local function stimTarget(thigh: boolean, side: number, upper: CFrame, S: Vector3, jab: number): (Vector3, Vector3, CFrame)
	local rightV, upV, fwd = upper.RightVector, upper.UpVector, upper.LookVector
	local off: Vector3, dirIn: Vector3, pole: Vector3
	if thigh then
		off = Vector3.new(-side * (0.05 + 0.25 * jab), -1.55 + 0.1 * jab, -0.1 + 0.05 * jab)
		dirIn = (-rightV * side * 0.8 - upV * 0.6).Unit
		pole = -fwd * 0.8 + rightV * side * 0.3
	else
		off = Vector3.new(-side * (0.1 + 0.2 * jab), 0.45 - 0.05 * jab, -0.35 + 0.05 * jab)
		dirIn = (-rightV * side - upV * 0.1).Unit
		pole = rightV * side - upV * 0.6
	end
	local Y = -dirIn
	local X = (fwd - Y * fwd:Dot(Y)).Unit
	return S + upper:VectorToWorldSpace(off), pole, CFrame.fromMatrix(Vector3.zero, X, Y)
end

function CombatPose.stimPose(userId: number)
	local plr = Players:GetPlayerByUserId(tonumber(userId) or 0)
	local c = plr and plr.Character
	if not c then
		return
	end
	local mode = Workspace:GetAttribute("Feel_StimPose")
	if mode == "off" then
		return
	end
	dropStim(c)
	local thigh = mode == "thigh"
	stims[c] = { t0 = os.clock(), thigh = thigh, p = if thigh then STIM_THIGH else STIM_NECK }
end

-- which shoulder the local gun belongs on: -1 only for the mirrored-aim preset (default) while the camera is left
local function wantedHand(): number
	local mode = Workspace:GetAttribute("Feel_LeftShoulder")
	if mode == "camera" or mode == "old" then
		return 1
	end
	return if Store.get("camSide") == -1 then -1 else 1
end

-- support hand slides along the handguard: as far forward as wanted, but never past what that arm can reach
-- (long guns on short Roblox arms), so the hand stays ON the gun instead of hovering short of it
local function handguardTarget(arm: Arm, upper: CFrame, gunCF: CFrame, wrist: Vector3, reach: number): Vector3
	local want = clamp(reach * 0.5, 0.75, 1.7)
	local P0 = (gunCF * CFrame.new(wrist)).Position
	local D = gunCF.LookVector
	local w = P0 - (upper * arm.sh.C0).Position
	local R = (arm.a + arm.b) * 0.97
	local wd = w:Dot(D)
	local disc = wd * wd - w:Dot(w) + R * R
	local fg = if disc >= 0 then -wd + sqrt(disc) else -wd
	fg = clamp(math.min(fg, want), 0.35, want)
	return P0 + D * fg
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
	-- haul objective: both hands on the carried core cell instead of the gun
	if wantsCarry(r, handle) then
		carryStep(r, dt)
		return
	end
	showGun(r, true)

	-- handedness: the local gun follows the camera shoulder (smoothed); other characters stay right-handed
	local handTarget = if isLocal then wantedHand() else 1
	r.hand += (handTarget - r.hand) * (1 - exp(-dt * HAND_RATE))
	local h = clamp(r.hand, -1, 1)
	local mid = 1 - h * h -- 0 on either shoulder, 1 mid-swap
	-- gR: the right hand's share of the grip role (1 = right hand on the grip); the hands trade only near the centre line
	local band = math.max(tune("SwapBand", SWAP_BAND), 0.05)
	local gR = clamp((h + band) / (2 * band), 0, 1)
	gR = gR * gR * (3 - 2 * gR)

	-- stim injection: the support hand (left, or the right one while the gun is in the left hand) does the jab
	local stim = stims[r.c]
	local stimW, stimJab, stimTilt, stimSide = 0, 0, 0, -1
	if stim then
		local e = os.clock() - stim.t0
		if e < stim.p.dur then
			if not stim.arm then
				stim.arm = if gR >= 0.5 then "L" else "R"
				stim.prop = makeInjector(r.c, stim.arm)
			end
			stimSide = if stim.arm == "L" then -1 else 1
			stimW, stimJab, stimTilt = stimEnvelope(stim.p, e)
			local stance = r.c:GetAttribute("Stance")
			if isLocal and Movement and Movement.getStance then
				stance = Movement.getStance()
			end
			if stance == "prone" then
				stimW *= STIM_PRONE_SHARE
				stimTilt = 0
			end
			if stim.thigh then
				stimTilt = 0
			end
		end
	end

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
	local blade = (if pistol then tune("PistolBlade", 0.2) else tune("Blade", BLADE)) * (1 - low * 0.6) * h
	local waistShare = tune("WaistShare", WAIST_SHARE)
	setC0(
		r.waist,
		r.waistBase * (if ArmorFx and ArmorFx.waistOffset then ArmorFx.waistOffset else CF0) * CFrame.Angles(p * waistShare, 0, 0) * CFrame.Angles(0, -blade, 0)
	)
	-- head: undo the blade and take part of the remaining pitch, so the visor looks down the sights
	if r.neck and r.neckBase then
		setC0(
			r.neck,
			r.neckBase * CFrame.Angles(0, blade, 0) * CFrame.Angles(p * (1 - waistShare) * tune("HeadShare", HEAD_SHARE), 0, stimSide * STIM_TILT * stimTilt)
		)
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
	-- prone / dive: the upper body twists toward the camera while the legs (root) stay put (Movement twist)
	local twist = if Movement and Movement.getTwist then Movement.getTwist(r.c) else 0
	if twist ~= 0 then
		flat = CFrame.Angles(0, twist, 0):VectorToWorldSpace(flat)
	end
	local yawCF = CFrame.lookAt(Vector3.zero, flat, UP)
	local gp = r.pitch * (1 - low) + LOW_READY_PITCH * low
	local aimRot = yawCF * CFrame.Angles(0, LOW_READY_YAW * low * h, 0) * CFrame.Angles(gp, 0, LOW_READY_ROLL * low * h)

	local gunCF: CFrame
	if pistol then
		local pocket = square * sx(tune("PistolPocket", PISTOL_POCKET), h)
		gunCF = CFrame.new(pocket) * aimRot * CFrame.new(0, -0.1, -tune("PistolReach", PISTOL_REACH))
	else
		-- the ADS slide pushes the gun to the camera's side: right-handed it only helps over the right shoulder, so on
		-- the left shoulder it stays off unless the gun itself moved to the left hand (mirrored-aim preset)
		local wantAds = if isLocal and Input.isDown("Aim") and (handTarget == -1 or Store.get("camSide") ~= -1) then 1 else 0
		r.ads += (wantAds - r.ads) * (1 - exp(-dt * 14)) -- same rate as the camera's aim blend
		local shoulderPocket = tune("Pocket", POCKET) + tune("AdsShift", ADS_POCKET_SHIFT) * r.ads * (1 - low)
		local pocket = square * (sx(shoulderPocket, h) + tune("SwapDip", SWAP_DIP) * mid)
		gunCF = CFrame.new(pocket) * aimRot * CFrame.new(tune("Grip", GRIP_FROM_POCKET))
	end
	if isLocal and GunFeel then
		local off = GunFeel.offset or CF0
		if h < 0.999 then
			off = off:Lerp(mirrorX(off), (1 - h) * 0.5) -- the reload roll tips the other way on the left shoulder
		end
		gunCF = gunCF * off
	end

	-- arms
	local right = upper.RightVector
	local back = -upper.LookVector
	local down = -upper.UpVector
	-- per-hand grip / support targets (wrist offsets and hand rotations belong to the hand, X-mirrored for the left),
	-- blended by gR so the hands trade roles mid-swap. At h = 1 this is the plain right-handed hold.
	local rGripT = (gunCF * CFrame.new(R_WRIST)).Position
	local lGripT = (gunCF * CFrame.new(sx(R_WRIST, -1))).Position
	local lSupT: Vector3
	local rSupT: Vector3
	if pistol then
		lSupT = (gunCF * CFrame.new(-0.16, 0.12, 0.16)).Position
		rSupT = (gunCF * CFrame.new(0.16, 0.12, 0.16)).Position
	else
		lSupT = handguardTarget(r.L, upper, gunCF, L_WRIST, reach)
		-- the right hand only goes on the handguard while swapping or on the left shoulder
		rSupT = if gR < 1 - 1e-3 then handguardTarget(r.R, upper, gunCF, sx(L_WRIST, -1), reach) else rGripT
	end
	local gunRot = gunCF.Rotation
	-- hands: fingers (-Y) wrap down around the grip / under the handguard, palms facing the gun
	local gripRot = gunRot * CFrame.Angles(-0.35, 0, 0) -- symmetric: the same for either hand
	local lSupRot = gunRot * CFrame.Angles(-1.1, 0, -0.5)
	local rSupRot = gunRot * CFrame.Angles(-1.1, 0, 0.5)
	-- elbow poles: grip elbow out to its side and back, support elbow tucked under
	local rPole = (down * 1.2 + right * 0.25 + back * 0.1):Lerp(down + right * 0.9 + back * 0.35, gR)
	local lPole = (down - right * 0.9 + back * 0.35):Lerp(down * 1.2 - right * 0.25 + back * 0.1, gR)
	local rTarget, rRot = rSupT:Lerp(rGripT, gR), rSupRot:Lerp(gripRot, gR)
	local lTarget, lRot = lGripT:Lerp(lSupT, gR), gripRot:Lerp(lSupRot, gR)
	if stimW > 0 and stim then
		-- the injecting arm blends away from the gun; the grip weld below compensates, so the gun stays put
		local free = if stim.arm == "L" then r.L else r.R
		local tgt, pole, rot = stimTarget(stim.thigh, stimSide, upper, (upper * free.sh.C0).Position, stimJab)
		if stim.arm == "L" then
			lTarget, lPole, lRot = lTarget:Lerp(tgt, stimW), lPole:Lerp(pole, stimW), lRot:Lerp(rot, stimW)
		else
			rTarget, rPole, rRot = rTarget:Lerp(tgt, stimW), rPole:Lerp(pole, stimW), rRot:Lerp(rot, stimW)
		end
	end
	local rHand = solveArm(r.R, upper, rTarget, rPole, rRot)
	solveArm(r.L, upper, lTarget, lPole, lRot)

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
	-- stim poses end on their own clock (also when the rig was released mid-way); the injector goes with them
	for c, s in stims do
		if not c.Parent or os.clock() - s.t0 >= s.p.dur then
			dropStim(c)
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
