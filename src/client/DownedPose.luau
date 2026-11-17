--!nonstrict
-- Downed body pose (every client, every downed character; driven by the replicated character attribute `Downed`,
-- server/Downed.luau). Code-driven like the rest of the body poses, no uploaded animations.
--   * body: Movement's pose rig (poseStep) asks DownedPose.bodyPose(c) for the lying pose of a downed character:
--       elbow  reclined on the back, rolled onto the left side (propped on the left elbow), thighs raised level
--       back   flat on the back, head up, both hands on the sidearm over the chest
--       prone  face down (Movement's plain prone, the pose before this module)
--     The sidearm keeps aiming through CombatPose as usual (pistol hold, solved from the posed chest).
--   * elbow pose: the left arm is re-solved here AFTER CombatPose (PreSimulation runs last-connected-first and this
--     handler is connected from Movement.init, before CombatPose.init), so the elbow rests on the floor and the
--     sidearm stays in the right hand; crawling drags the elbow along. CombatPose itself is not changed.
--   * get up: DownedPose.PUSH is the "push up off the ground" pose Movement holds for PUSH_TIME s when a downed
--     trooper gets back up (stim or squadmate), before the crouch -> stand.
-- Studio A/B (client/Variants.luau): DOWNED POSE = Feel_DownedPose nil (elbow) | "back" | "prone";
-- GET UP = Feel_DownedGetUp nil (push up) | "snap" (straight up, the old way).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Rules = require(Shared.Downed)

local DownedPose = {}

local rad = math.rad
local clamp, exp, sqrt, abs = math.clamp, math.exp, math.sqrt, math.abs
local UP = Vector3.new(0, 1, 0)
local CF0 = CFrame.identity

-- p = body pitch forward (rad; negative = reclined onto the back), d = body drop (studs), b = knee bend 0..1,
-- roll = turn about the spine (rad; positive = chest turns left, left side down), hip = extra thigh lift (rad) so the
-- legs lie level
DownedPose.POSES = {
	elbow = { p = -rad(55), d = 0, b = 0, roll = rad(28), hip = rad(35) },
	back = { p = -rad(78), d = 0, b = 0, roll = 0, hip = rad(12) },
}
DownedPose.PUSH = { p = rad(45), d = -0.2, b = 0.8, roll = 0, hip = 0 } -- hands-and-knees on the way up
DownedPose.PUSH_TIME = 0.22 -- seconds held in PUSH before the crouch -> stand

function DownedPose.mode(): string
	local a = Workspace:GetAttribute("Feel_DownedPose")
	if a == "back" or a == "prone" then
		return a
	end
	return "elbow"
end

-- the lying pose table for a downed character, or nil for Movement's plain prone
function DownedPose.bodyPose(c: Model): any
	if c:GetAttribute(Rules.ATTR) ~= true then
		return nil
	end
	return DownedPose.POSES[DownedPose.mode()]
end

function DownedPose.pushUp(): boolean
	return Workspace:GetAttribute("Feel_DownedGetUp") ~= "snap"
end

-- ── left arm prop (elbow pose) ──────────────────────────────────────────────────────────────────────────────────
local function isJoint(x: Instance?): boolean
	return x ~= nil and (x:IsA("Motor6D") or x:IsA("AnimationConstraint"))
end
local function c0Of(j: any): CFrame
	if j:IsA("AnimationConstraint") then
		return if j.Attachment0 then j.Attachment0.CFrame else CF0
	end
	return j.C0
end
local function motor(c: Model, part: string, name: string): any
	local p = c:FindFirstChild(part)
	local m = p and p:FindFirstChild(name)
	return if m and isJoint(m) then m else nil
end

-- same bone frames as CombatPose's arm solver (X column = bone direction)
local function boneBasis(dir: Vector3): CFrame
	local ref = Vector3.new(1, 0, 0) - dir * dir.X
	if ref.Magnitude < 1e-3 then
		ref = Vector3.new(0, 0, 1) - dir * dir.Z
	end
	ref = ref.Unit
	return CFrame.fromMatrix(Vector3.zero, dir, ref, dir:Cross(ref))
end

type Arm = { sh: any, el: any, wr: any, a: number, b: number, uB: CFrame, lB: CFrame }
type Rec = { c: Model, hrp: BasePart, root: any, waist: any, arm: Arm, w: number, ph: number }
local recs: { [Model]: Rec } = {}

local function buildRec(c: Model): Rec?
	local hrp = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	local root = motor(c, "LowerTorso", "Root")
	local waist = motor(c, "UpperTorso", "Waist")
	local sh = motor(c, "LeftUpperArm", "LeftShoulder")
	local el = motor(c, "LeftLowerArm", "LeftElbow")
	local wr = motor(c, "LeftHand", "LeftWrist")
	if not (hrp and root and waist and sh and el and wr) then
		return nil
	end
	local ub = el.C0.Position - sh.C1.Position
	local lb = wr.C0.Position - el.C1.Position
	local a, b = ub.Magnitude, lb.Magnitude
	if a < 0.1 or b < 0.1 then
		return nil
	end
	local arm = { sh = sh, el = el, wr = wr, a = a, b = b, uB = boneBasis(ub / a):Inverse(), lB = boneBasis(lb / b):Inverse() }
	return { c = c, hrp = hrp, root = root, waist = waist, arm = arm, w = 0, ph = 0 }
end

-- 2-bone solve (wrist to `target`, elbow toward `pole`), blended over the joints' current Transforms by `w`
local function solveArm(arm: Arm, torso: CFrame, target: Vector3, pole: Vector3, w: number)
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
		perp = Vector3.new(1, 0, 0)
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
	local R1 = CFrame.fromMatrix(Vector3.zero, u, X, u:Cross(X)) * arm.uB
	local upper = CFrame.new(S) * R1 * CFrame.new(-sh.C1.Position)
	local shT = shJoint:Inverse() * upper * sh.C1
	local elJoint = upper * c0Of(el)
	local R2 = CFrame.fromMatrix(Vector3.zero, f, X, f:Cross(X)) * arm.lB
	local lower = CFrame.new(elJoint.Position) * R2 * CFrame.new(-el.C1.Position)
	local elT = elJoint:Inverse() * lower * el.C1
	local wrJoint = lower * c0Of(wr)
	local wrT = wrJoint:Inverse() * (CFrame.new(wrJoint.Position) * R2 * wr.C1.Rotation)
	if w >= 0.999 then
		sh.Transform, el.Transform, wr.Transform = shT, elT, wrT
	else
		sh.Transform = sh.Transform:Lerp(shT, w)
		el.Transform = el.Transform:Lerp(elT, w)
		wr.Transform = wr.Transform:Lerp(wrT, w)
	end
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function armStep(r: Rec, dt: number)
	local c = r.c
	local hum = c:FindFirstChildOfClass("Humanoid")
	local want = c:GetAttribute(Rules.ATTR) == true and DownedPose.mode() == "elbow" and hum ~= nil and hum.Health > 0
	r.w += ((if want then 1 else 0) - r.w) * (1 - exp(-dt * 6))
	if r.w < 0.01 then
		return
	end
	local hrpCF = r.hrp.CFrame
	local lower = hrpCF * c0Of(r.root) * r.root.Transform * r.root.C1:Inverse()
	local upper = lower * c0Of(r.waist) * r.waist.Transform * r.waist.C1:Inverse()
	local S = (upper * c0Of(r.arm.sh)).Position
	-- legs' heading on the floor (the reclined body faces its feet)
	local look = hrpCF.LookVector
	local fwd = Vector3.new(look.X, 0, look.Z)
	fwd = if fwd.Magnitude > 1e-3 then fwd.Unit else Vector3.new(0, 0, -1)
	local left = fwd:Cross(UP) * -1 -- world left of the heading
	rayParams.FilterDescendantsInstances = { c }
	local hit = Workspace:Raycast(S, Vector3.new(0, -6, 0), rayParams)
	local floorY = if hit then hit.Position.Y else S.Y - r.arm.a
	-- crawling: the elbow drags along (forward reach, then pull back under the shoulder)
	local v = r.hrp.AssemblyLinearVelocity
	local spd = Vector3.new(v.X, 0, v.Z).Magnitude
	r.ph = (r.ph + dt * spd * 2.4) % (math.pi * 2)
	local crawl = clamp(spd / 2, 0, 1)
	local reach = 0.3 * crawl * math.sin(r.ph)
	local lift = 0.18 * crawl * math.max(0, math.cos(r.ph))
	local elbow = Vector3.new(S.X, floorY + 0.12 + lift, S.Z) + left * 0.35 + fwd * (0.05 + reach)
	local wrist = elbow + fwd * (r.arm.b * 0.95) + left * 0.05
	solveArm(r.arm, upper, wrist, elbow - S, r.w)
end

local function frame(dt: number)
	for _, plr in Players:GetPlayers() do
		local c = plr.Character
		if not c then
			continue
		end
		local r = recs[c]
		if r and (not r.hrp.Parent or not r.arm.sh.Parent or not r.waist.Parent) then
			recs[c] = nil
			r = nil
		end
		if not r then
			if c:GetAttribute(Rules.ATTR) ~= true then
				continue
			end
			r = buildRec(c)
			if not r then
				continue
			end
			recs[c] = r
		end
		local ok, err = pcall(armStep, r :: Rec, dt)
		if not ok then
			recs[c] = nil
			warn("[DownedPose]", err)
		elseif (r :: Rec).w < 0.01 and c:GetAttribute(Rules.ATTR) ~= true then
			recs[c] = nil
		end
	end
	for c in recs do
		if not c.Parent then
			recs[c] = nil
		end
	end
end

-- Connect from Movement.init BEFORE CombatPose.init (handlers of one signal run last-connected-first, so this one runs
-- after CombatPose's arm solve and wins the left arm).
local inited = false
function DownedPose.init()
	if inited then
		return
	end
	inited = true
	RunService.PreSimulation:Connect(frame)
end

return DownedPose
