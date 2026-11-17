--!nonstrict
-- Foot planting (local character): Roblox stands the root on the ground and swings the legs from the walk animation
-- as if the ground were flat, so on slopes, bumps and rocks a foot sinks into the ground. Each frame, after the
-- Animator, Movement and CombatPose have written this frame's joint values (PreSimulation), every leg is run
-- forward from the hip, the ground under the heel and the toe is ray-cast, and if the foot is below it the leg is
-- re-solved with an analytic two-bone IK (hip + knee) so the foot sits on the ground. The foot keeps its animated
-- world orientation. Legs that are above the ground are left alone (a stride stays a stride).
-- Off while airborne, diving, mantling, knocked down, prone or dead (checked: enabled() returns false for stance "prone"
-- and for any Movement mode; while prone the Humanoid state was also Freefall before the prone hover-height fix).
-- NOTE: PreSimulation handlers of one signal run in REVERSE connection order (measured in Studio), so this one, connected
-- last in Main, runs before CombatPose and Movement.step (only Movement's delayed twist / lying-pose handler runs earlier);
-- it only needs the Animator's values. While prone the leg joints belong to Movement's lying pose, not to this module.
-- Studio: workspace attribute FootPlant=false turns it off live for A/B.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local FootPlant = {}

local player = Players.LocalPlayer
local Movement: any = nil
local BodyDebug = require(script.Parent.BodyDebug)
local lastOn = false -- enabled() result of the last step (BodyDebug readout)

local MIN_PEN = 0.03 -- ignore sinkage smaller than this (studs)
local MAX_LIFT = 1.6 -- never lift a foot by more than this (big ledges: the leg simply cannot reach)
local RAISE_RATE = 30 -- 1/s: how fast the correction follows (exp), up
local DROP_RATE = 18 -- 1/s: down (a little slower so a foot doesn't flicker on noisy ground)

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true
rayParams.IgnoreWater = true

local function isJoint(x: Instance?): boolean
	return x ~= nil and (x:IsA("Motor6D") or x:IsA("AnimationConstraint"))
end
local function c0(j: any): CFrame
	if j:IsA("Motor6D") then
		return j.C0
	end
	return if j.Attachment0 then j.Attachment0.CFrame else CFrame.identity
end
local function c1(j: any): CFrame
	if j:IsA("Motor6D") then
		return j.C1
	end
	return if j.Attachment1 then j.Attachment1.CFrame else CFrame.identity
end
-- What we wrote last frame, per joint: if nothing (Animator, Movement, CombatPose) overwrote it since, the joint's
-- "animated" value is the one we replaced, not our own correction (otherwise the fix would feed back into itself).
local written: { [any]: { mine: CFrame, base: CFrame } } = setmetatable({}, { __mode = "k" }) :: any
local function animT(j: any): CFrame
	local t = j.Transform
	local w = written[j]
	if w and t == w.mine then
		return w.base
	end
	return t
end
local function writeT(j: any, base: CFrame, t: CFrame)
	j.Transform = t
	written[j] = { mine = j.Transform, base = base }
	if BodyDebug.on then
		BodyDebug.mark(j, "T", "FootPlant")
	end
end
-- Part1 world = Part0 world * C0 * Transform * C1^-1 (Motor6D and AnimationConstraint alike)
local function child(parentCF: CFrame, j: any): CFrame
	return parentCF * c0(j) * animT(j) * c1(j):Inverse()
end
-- Transform that puts Part1 at `want` given Part0 at `parentCF`
local function transformFor(parentCF: CFrame, j: any, want: CFrame): CFrame
	return (parentCF * c0(j)):Inverse() * want * c1(j)
end

-- rotation taking unit vector a onto unit vector b (shortest arc)
local function rotBetween(a: Vector3, b: Vector3): CFrame
	local d = math.clamp(a:Dot(b), -1, 1)
	if d > 0.99999 then
		return CFrame.identity
	end
	local axis = a:Cross(b)
	if axis.Magnitude < 1e-6 then
		axis = if math.abs(a.X) < 0.9 then a:Cross(Vector3.xAxis) else a:Cross(Vector3.yAxis)
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(d))
end
-- rotate a CFrame about a world point
local function rotateAbout(cf: CFrame, pivot: Vector3, r: CFrame): CFrame
	return CFrame.new(pivot) * r * CFrame.new(-pivot) * cf
end

type Leg = { hip: any, knee: any, ankle: any, joints: { any }, foot: BasePart, lift: number, tilt: CFrame? }
local rig: { root: BasePart, rootJ: any, hum: Humanoid, char: Model, legs: { Leg } }? = nil

local function build(c: Model)
	rig = nil
	local root = c:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	local hum = c:WaitForChild("Humanoid", 5) :: Humanoid?
	local lt = c:WaitForChild("LowerTorso", 5)
	if not (root and hum and lt) then
		return
	end
	local rootJ = lt:WaitForChild("Root", 5)
	if not isJoint(rootJ) then
		return
	end
	local legs = {}
	for _, side in { "Left", "Right" } do
		local ul = c:WaitForChild(side .. "UpperLeg", 5)
		local ll = c:WaitForChild(side .. "LowerLeg", 5)
		local ft = c:WaitForChild(side .. "Foot", 5) :: BasePart?
		local hip = ul and ul:WaitForChild(side .. "Hip", 5)
		local knee = ll and ll:WaitForChild(side .. "Knee", 5)
		local ankle = ft and ft:WaitForChild(side .. "Ankle", 5)
		if not (isJoint(hip) and isJoint(knee) and isJoint(ankle) and ft) then
			return
		end
		table.insert(legs, { hip = hip, knee = knee, ankle = ankle, joints = { hip, knee, ankle }, foot = ft :: BasePart, lift = 0 })
	end
	rig = { root = root, rootJ = rootJ, hum = hum, char = c, legs = legs }
end

-- Second result true = only a "soft" reason (FloorMaterial Air / Freefall / Jumping) turned it off. Those flip for a
-- frame or two when walking over bumps; step() keeps the planting on through them for SOFT_HOLD seconds (hysteresis)
-- instead of dropping and re-raising the feet. A real fall needs no gate: the rays find no ground near the feet.
local function enabled(): (boolean, boolean)
	local r = rig
	if not r or not r.char.Parent or r.hum.Health <= 0 then
		return false, false
	end
	if RunService:IsStudio() and workspace:GetAttribute("FootPlant") == false then
		return false, false
	end
	if r.root.Anchored then
		return false, false
	end
	local st = r.hum:GetState()
	if st == Enum.HumanoidStateType.Seated or st == Enum.HumanoidStateType.PlatformStanding then
		return false, false
	end
	local soft = r.hum.FloorMaterial == Enum.Material.Air or st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping
	if Movement then
		local okM, mode = pcall(Movement.getMode)
		if okM and mode ~= "none" then
			return false, false
		end
		local okS, stance = pcall(Movement.getStance)
		if okS and stance == "prone" then
			return false, false
		end
	end
	if soft then
		return false, true
	end
	return true, false
end
local SOFT_HOLD = 0.12
local softFor = 0

local function groundHit(p: Vector3, from: number): RaycastResult?
	return workspace:Raycast(Vector3.new(p.X, from, p.Z), Vector3.new(0, -(from - p.Y) - 2.5, 0), rayParams)
end
local MAX_TILT = math.rad(40) -- foot follows the slope up to this angle
local CORNERS = { { -0.8, -0.8 }, { 0.8, -0.8 }, { -0.8, 0.8 }, { 0.8, 0.8 } }
-- Studio A/B Feel_Perf ("PERF": "touch" = phones only, "all" = everywhere): heel and toe only (6 rays a frame, not 10)
local CORNERS_PERF = { { 0, -0.8 }, { 0, 0.8 } }
local IS_STUDIO = RunService:IsStudio()
local UserInputService = game:GetService("UserInputService")

-- ray filter: assigned only when the character, camera or Enemies folder changes (each assignment copies the list)
local filterChar: Instance? = nil
local filterCam: Instance? = nil
local filterEnemies: Instance? = nil
local function refreshFilter(char: Model)
	local cam = workspace.CurrentCamera
	local en = filterEnemies
	if not (en and en.Parent == workspace) then
		en = workspace:FindFirstChild("Enemies")
	end
	if char == filterChar and cam == filterCam and en == filterEnemies then
		return
	end
	filterChar, filterCam, filterEnemies = char, cam, en
	local ex: { Instance } = { char }
	if cam then
		table.insert(ex, cam)
	end
	if en then
		table.insert(ex, en)
	end
	rayParams.FilterDescendantsInstances = ex
end

local function step(dt: number)
	local r = rig
	if not r then
		return
	end
	local on, soft = enabled()
	if soft then
		softFor += dt
		on = softFor < SOFT_HOLD
	else
		softFor = 0
	end
	lastOn = on
	refreshFilter(r.char)
	local corners = CORNERS
	if IS_STUDIO then
		local perf = workspace:GetAttribute("Feel_Perf")
		if perf == "all" or (perf == "touch" and UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
			corners = CORNERS_PERF
		end
	end

	local ltCF = child(r.root.CFrame, r.rootJ)
	local castFrom = r.root.Position.Y -- rays start at hip height: anything higher is a wall, not ground
	for _, leg in r.legs do
		local ulCF = child(ltCF, leg.hip)
		local llCF = child(ulCF, leg.knee)
		local ftCF = child(llCF, leg.ankle)
		-- foot tilted onto the slope under it, then sinkage of its four bottom corners
		local want = 0
		local tilt = CFrame.identity
		if on then
			local half = leg.foot.Size / 2
			local centre = groundHit(ftCF.Position, castFrom)
			if centre and centre.Position.Y > ftCF.Position.Y - half.Y - 0.6 then -- only near the ground (not mid-stride)
				local up = ftCF.UpVector
				local nrm = centre.Normal
				local ang = math.acos(math.clamp(up:Dot(nrm), -1, 1))
				if ang > 0.01 then
					local axis = up:Cross(nrm)
					if axis.Magnitude > 1e-5 then
						tilt = CFrame.fromAxisAngle(axis.Unit, math.min(ang, MAX_TILT))
					end
				end
			end
			local tilted = tilt * ftCF.Rotation + ftCF.Position
			for _, k in corners do
				local bottom = (tilted * CFrame.new(k[1] * half.X, -half.Y, k[2] * half.Z)).Position
				local hit = groundHit(bottom, castFrom)
				if hit then
					want = math.max(want, hit.Position.Y - bottom.Y)
				end
			end
			if want < MIN_PEN then
				want = 0
			end
			want = math.min(want, MAX_LIFT)
		end
		leg.tilt = if want > 0 then tilt else CFrame.identity
		local rate = if want > leg.lift then RAISE_RATE else DROP_RATE
		leg.lift += (want - leg.lift) * (1 - math.exp(-dt * rate))
		if leg.lift < 0.005 then
			leg.lift = 0
			-- hand back any correction still sitting on a joint nobody else rewrote
			for _, j in leg.joints do
				local w = written[j]
				if w then
					if j.Transform == w.mine then
						j.Transform = w.base
						if BodyDebug.on then
							BodyDebug.mark(j, "T", "FootPlant")
						end
					end
					written[j] = nil
				end
			end
			continue
		end

		-- two-bone IK: joint positions from the forward pass
		local hipP = (ltCF * c0(leg.hip)).Position
		local kneeP = (ulCF * c0(leg.knee)).Position
		local ankP = (llCF * c0(leg.ankle)).Position
		local target = ankP + Vector3.new(0, leg.lift, 0)
		local a = (kneeP - hipP).Magnitude
		local b = (ankP - kneeP).Magnitude
		local toT = target - hipP
		local d = math.clamp(toT.Magnitude, math.abs(a - b) + 0.01, a + b - 0.01)
		local dirT = toT.Unit
		-- bend plane from the animated leg (keeps the knee pointing where the animation had it)
		local n = (kneeP - hipP):Cross(ankP - hipP)
		if n.Magnitude < 1e-4 then
			n = (ltCF.RightVector):Cross(dirT)
			if n.Magnitude < 1e-4 then
				continue
			end
		end
		n = n.Unit
		local cosA = math.clamp((a * a + d * d - b * b) / (2 * a * d), -1, 1)
		local angA = math.acos(cosA)
		-- knee = dirT rotated about n by angA (same side as the animated knee)
		-- (n = hip->knee x hip->ankle, so turning hip->ankle toward the knee is a negative angle about n)
		local kneeDir = CFrame.fromAxisAngle(n, -angA):VectorToWorldSpace(dirT)
		local newKnee = hipP + kneeDir * a
		local newAnk = hipP + dirT * d

		-- upper leg: swing about the hip so hip->knee points at newKnee
		local r1 = rotBetween((kneeP - hipP).Unit, kneeDir)
		local newUl = rotateAbout(ulCF, hipP, r1)
		-- lower leg: carried by r1, then swung about the new knee so knee->ankle points at newAnk
		local llCarried = rotateAbout(llCF, hipP, r1)
		local carriedAnk = (llCarried * c0(leg.ankle)).Position
		local r2 = rotBetween((carriedAnk - newKnee).Unit, (newAnk - newKnee).Unit)
		local newLl = rotateAbout(llCarried, newKnee, r2)
		-- foot: animated world orientation tilted onto the slope (blended by how much correction is applied),
		-- moved with the ankle
		local w = math.clamp(leg.lift / math.max(want, 0.05), 0, 1)
		local tiltNow = CFrame.identity:Lerp(leg.tilt or CFrame.identity, w)
		local newFt = (tiltNow * ftCF.Rotation) + (ftCF.Position + (newAnk - ankP))

		writeT(leg.hip, animT(leg.hip), transformFor(ltCF, leg.hip, newUl))
		writeT(leg.knee, animT(leg.knee), transformFor(newUl, leg.knee, newLl))
		writeT(leg.ankle, animT(leg.ankle), transformFor(newLl, leg.ankle, newFt))
	end
end

-- BodyDebug readout: (enabled last step, left lift, right lift) in studs
function FootPlant.debugState(): (boolean, number, number)
	local r = rig
	if not r then
		return false, 0, 0
	end
	return lastOn, r.legs[1] and r.legs[1].lift or 0, r.legs[2] and r.legs[2].lift or 0
end

function FootPlant.init(movement: any)
	Movement = movement
	player.CharacterAdded:Connect(function(c)
		task.spawn(build, c)
	end)
	if player.Character then
		task.spawn(build, player.Character)
	end
	RunService.PreSimulation:Connect(function(dt)
		debug.profilebegin("FootPlant") -- MicroProfiler label
		local ok, err = pcall(step, dt)
		debug.profileend()
		if not ok then
			warn("[FootPlant] " .. tostring(err))
			rig = nil
		end
	end)
end

return FootPlant
