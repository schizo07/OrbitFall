-- Over-the-shoulder third-person camera (mouse lock, touch drag, gamepad stick), wall collision,
-- aim zoom, character facing, plus Juice offsets (shake/recoil).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Input = require(script.Parent.Input)
local Store = require(script.Parent.Store)
local Juice = require(script.Parent.Juice)
-- stance height, landing dip, sprint bob/FOV (optional: camera still works if Movement fails to load)
local okMove, MovementMod = pcall(require, script.Parent.Movement)
local Movement = if okMove then MovementMod else nil
if not okMove then
	warn("[Camera] Movement unavailable:", MovementMod)
end

local CameraController = {}
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Aim = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Aim"))
local CombatPose = require(script.Parent.CombatPose)

-- First-person scope (weapons with zoom >= 2, aiming): the lens sits on the shared bullet origin (shared/Aim.origin,
-- the point the server traces every shot from), so the scope's centre ray and the bullet line are the same line.
-- Studio A/B "SCOPE" (Feel_Scope): nil = scope, "old" = third-person zoom, "fade" = scope fading in over 0.15 s.
local SCOPE_MIN_ZOOM = 2
local SCOPE_FOV_DIV = 1.65 -- scope FOV = base FOV / (zoom * this): 66 -> 20 at 2x
local scoped = false
local scopeSince = 0
local lastScopeHide = 0

-- Framing (intensity spec §1): tight over-the-shoulder, trooper fills the lower-left, body clipped at the thighs.
local yaw, pitch = 0, -0.15
local dist = 5 -- smoothed zoom distance
local distTarget = 5 -- player zoom (mouse wheel / pinch), clamped to [DIST_MIN, DIST_MAX]
local DIST_MIN, DIST_MAX = 4, 7.5
local WHEEL_STEP = 0.75
-- 2026-11-14 playtest pick: "high + back" camera (Variants FRAMING C) with the rifle at the cheek (CombatPose)
local PIVOT_UP = 1.9 -- focus height above the root
local BASE_FOV = 66
local HIP_DIST_ADD = 3 -- added to the wheel zoom distance at hip (5 -> 8)
local SHOULDER = Vector3.new(2.25, 1.8, 0) -- 2026-11-15 pick: between the old 2.0 and the wider 2.5. Default right-shoulder offset (X is mirrored by the shoulder swap)
local SPRINT_SHOULDER_SCALE = Vector3.new(0.8, 0.9, 1) -- sprint pulls the lens a little toward the back
local SPRINT_DIST_ADD = 1
local SPRINT_FOV_ADD = 8
local SIDE_RATE = 10 -- shoulder swap blend speed (exp rate, 1/s)
local LOW_SHOULDER = Vector3.new(1.2, 0.3, 0) -- prone / dive
local LOW_DIST = 4.2
local FOLLOW_RATE = 13 -- horizontal focus follow (exp rate, 1/s): grounded weight when moving
local STRAFE_ROLL = math.rad(1.8)
local FADE_DIST = 1.8 -- lens closer than this to the focus fades the local character
local aimBlend = 0
local zoomMult = 1
local ADS_DIST = 2.6 -- lens distance behind the focus while aiming
local ADS_SHOULDER = Vector3.new(1.15, 0.55, 0) -- right-shoulder offset while aiming
local ADS_FOV_DROP = 24 -- 72 -> 48 FOV at full aim
local ADS_SENS = 0.5 -- look sensitivity multiplier at full aim
local LEFT_ADS_EXTRA = Vector3.new(0.6, 0.3, 0) -- extra lens offset (away from the head, up) aiming over the left shoulder, "camera" preset
local LEFT_HEAD_FADE = 0.6 -- local head / helmet / hat LocalTransparencyModifier at full left-shoulder aim, "camera" preset
-- accessories that sit on the head (the trooper helmet itself is the TrooperArmor Helmet / Visor parts)
local HEAD_ACCESSORIES: { [Enum.AccessoryType]: boolean } = {
	[Enum.AccessoryType.Hat] = true,
	[Enum.AccessoryType.Hair] = true,
	[Enum.AccessoryType.Face] = true,
	[Enum.AccessoryType.Eyebrow] = true,
	[Enum.AccessoryType.Eyelash] = true,
}
local lowBlend = 0 -- prone / dive framing
local carryBlend = 0 -- core cell carry framing (wider, trooper nearer the middle)
local CARRY_DIST_ADD = 4
local CARRY_SHOULDER = Vector3.new(1.2, 2.4, 0)
-- drop capsule ride (character attribute InCapsule, server/PlayerService.dropTo): the camera sits on top of the
-- capsule looking down at the ground ahead (steering: client/CapsuleSteer), then eases back to the shoulder once the
-- door opens
local capBlend = 0
local wasInCapsule = false
local CAP_DIST = 15 -- lens behind the top of the capsule
local CAP_LIFT = Vector3.new(0, 6, 0) -- camera-space lift: the capsule sits low in the frame, the ground ahead shows
local CAP_TOP = 8.5 -- focus lifted from the trooper to the capsule's roof
local CAP_FOV_ADD = 10
local CAP_PITCH = -0.85 -- look down toward the landing area when the ride starts
-- while the lens eases back in from behind, the landed capsule (server/DropCapsule) is see-through locally
local capFade = 0
local function fadeOwnCapsule(v: number)
	if v == capFade then
		return
	end
	capFade = v
	local map = workspace:FindFirstChild("Map")
	local f = (map and map:FindFirstChild("DropCapsules")) or workspace:FindFirstChild("DropCapsules")
	if not f then
		return
	end
	for _, m in f:GetChildren() do
		if m:GetAttribute("Owner") == player.UserId then
			for _, p in m:GetDescendants() do
				if p:IsA("BasePart") then
					p.LocalTransparencyModifier = v
				end
			end
		end
	end
end
local side = 1 -- 1 = right shoulder, -1 = left (V / R3)
local SHOULDER_LEAN = math.rad(4) -- held camera roll toward the shoulder side (x1.6 extra at the middle of a swap)
local SHOULDER_DIP = 0.55 -- studs the lens drops while crossing behind the head
local SWAP_TIME = 0.4 -- s of the dip / extra lean after a swap
local swapAt = -10
local leanCur = 0
local sideBlend = 1
local rollCur = 0
local accelLag = 0
local prevFwdSpeed = 0
local focusXZ: Vector3? = nil
local lastFade = 0
local lastHeadFade = 0
local freeMouse = false -- set by dial/menus
CameraController.sens = 0.0042
CameraController.touchSens = 0.0065
CameraController.padSens = 3.0

-- Studio-only live tuning: workspace attributes CamTune_<name> override the framing constants above while playing
-- (same pattern as CombatPose's PoseTune_*). Variants.luau switches whole presets with a key. Live games ignore them.
local IS_STUDIO = RunService:IsStudio()
local function tune(name: string, default: any): any
	if not IS_STUDIO then
		return default
	end
	local v = workspace:GetAttribute("CamTune_" .. name)
	return if v ~= nil and typeof(v) == typeof(default) then v else default
end

local touchLook: { [InputObject]: Vector3 } = {}

-- the head Part, its face decals, the trooper helmet / visor pieces and head accessories
local function isHeadPart(p: Instance): boolean
	if p.Name == "Head" or (p.Parent and p.Parent.Name == "Head") then
		return true
	end
	local acc = p:FindFirstAncestorOfClass("Accessory")
	if acc then
		return HEAD_ACCESSORIES[acc.AccessoryType] == true
	end
	if p.Parent and p.Parent.Name == "TrooperArmor" then
		return string.find(p.Name, "^Helmet") ~= nil or string.find(p.Name, "^Visor") ~= nil
	end
	return false
end

function CameraController.setFreeMouse(v: boolean)
	freeMouse = v
end

function CameraController.setZoom(mult: number)
	zoomMult = mult
end

-- the scope view is on (first-person lens + overlay), and os.clock() when it came on
function CameraController.scopeState(): (boolean, number)
	return scoped, scopeSince
end

function CameraController.getYaw(): number
	return yaw
end

-- 1 = camera over the right shoulder, -1 = left (smoothed value, for anything that wants to follow the swap)
function CameraController.getSide(): number
	return sideBlend
end

-- Scripted shots (cinematics): fn(dt) -> (CFrame, fov?) takes over the camera; return nil to hand control back. clear with nil.
-- Juice shake/kick are still layered on top of the returned CFrame. Normal aim/facing logic is skipped while active.
local override: ((number) -> (CFrame?, number?))? = nil
function CameraController.setOverride(fn: ((number) -> (CFrame?, number?))?)
	override = fn
end

function CameraController.hasOverride(): boolean
	return override ~= nil
end

-- Aim ray from screen centre (crosshair). Returns origin, direction.
function CameraController.aimRay(): (Vector3, Vector3)
	local vp = camera.ViewportSize
	local r = camera:ViewportPointToRay(vp.X / 2, vp.Y / 2)
	return r.Origin, r.Direction
end

local camDist = 10 -- smoothed collision distance (focus -> lens)
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local CAM_EXCLUDE_FOLDERS = { "Enemies", "ClientFx", "CallInObjects" }
-- the filter is cached and only rebuilt when a character or one of the folders is swapped (checked once a second,
-- plus on CharacterAdded for every player)
local filterDirty = true
local filterCheckAt = 0
local filterKey: { Instance } = {}
local function camExclude(): { Instance }
	local list: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, n in CAM_EXCLUDE_FOLDERS do
		local f = workspace:FindFirstChild(n)
		if f then
			table.insert(list, f)
		end
	end
	return list
end

local function sameList(a: { Instance }, b: { Instance }): boolean
	if #a ~= #b then
		return false
	end
	for i, x in a do
		if b[i] ~= x then
			return false
		end
	end
	return true
end

local function refreshFilter()
	local t = os.clock()
	if not filterDirty and t - filterCheckAt < 1 then
		return
	end
	filterCheckAt = t
	local list = camExclude()
	if filterDirty or not sameList(list, filterKey) then
		filterKey = list
		rayParams.FilterDescendantsInstances = list
	end
	filterDirty = false
end

local function watchPlayer(p: Player)
	p.CharacterAdded:Connect(function()
		filterDirty = true
	end)
	p.CharacterRemoving:Connect(function()
		filterDirty = true
	end)
end

function CameraController.init()
	for _, p in Players:GetPlayers() do
		watchPlayer(p)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function()
		filterDirty = true
	end)
	workspace.ChildAdded:Connect(function(ch)
		if table.find(CAM_EXCLUDE_FOLDERS, ch.Name) then
			filterDirty = true
		end
	end)
	local padOn = UserInputService:GetGamepadConnected(Enum.UserInputType.Gamepad1)
	UserInputService.GamepadConnected:Connect(function(g)
		if g == Enum.UserInputType.Gamepad1 then
			padOn = true
		end
	end)
	UserInputService.GamepadDisconnected:Connect(function(g)
		if g == Enum.UserInputType.Gamepad1 then
			padOn = false
		end
	end)

	camera.CameraType = Enum.CameraType.Scriptable

	Input.on("Shoulder", function(isDown)
		if isDown then
			side = -side
			swapAt = os.clock()
			Store.set("camSide", side) -- CombatPose: the gun follows to the left hand (Feel_LeftShoulder)
		end
	end)

	UserInputService.InputChanged:Connect(function(io, gp)
		if io.UserInputType == Enum.UserInputType.MouseMovement then
			if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
				local k = CameraController.sens * (1 - aimBlend * (1 - ADS_SENS)) / zoomMult
				yaw -= io.Delta.X * k
				pitch -= io.Delta.Y * k
			end
		elseif io.UserInputType == Enum.UserInputType.Touch then
			local last = touchLook[io]
			if last then
				local d = io.Position - last
				touchLook[io] = io.Position
				local k = CameraController.touchSens * (if scoped then ADS_SENS / zoomMult else 1)
				yaw -= d.X * k
				pitch -= d.Y * k
			end
		end
		if io.UserInputType == Enum.UserInputType.MouseWheel and not gp then
			distTarget = math.clamp(distTarget - io.Position.Z * WHEEL_STEP, DIST_MIN, DIST_MAX)
		end
	end)
	local pinchStart = distTarget
	UserInputService.TouchPinch:Connect(function(touches, scale, _velocity, state, gp)
		if gp then
			return
		end
		local half = camera.ViewportSize.X * 0.45
		for _, t in touches do
			if t.X <= half then
				return -- one finger is on the stick side: move + look, not a pinch
			end
		end
		if state == Enum.UserInputState.Begin then
			pinchStart = distTarget
		else
			distTarget = math.clamp(pinchStart / math.max(scale, 0.1), DIST_MIN, DIST_MAX)
		end
	end)
	UserInputService.TouchStarted:Connect(function(io, gp)
		if gp then
			return
		end
		-- right 55 % of the screen rotates the camera (left side belongs to the thumbstick)
		if io.Position.X > camera.ViewportSize.X * 0.45 then
			touchLook[io] = io.Position
		end
	end)
	UserInputService.TouchEnded:Connect(function(io)
		touchLook[io] = nil
	end)

	RunService:BindToRenderStep("OrbitCam", Enum.RenderPriority.Camera.Value, function(dt)
		camera.CameraType = Enum.CameraType.Scriptable
		if override then
			local ocf, ofov = override(dt)
			if ocf then
				camera.CFrame = ocf * Juice.step(dt)
				camera.Focus = CFrame.new(ocf.Position + ocf.LookVector * 30)
				camera.FieldOfView = ofov or 70
				return
			end
			override = nil
		end
		local menu = Store.get("menuOpen") == true
		local lockMouse = not freeMouse and not menu and not Input.isTouch()
		UserInputService.MouseBehavior = lockMouse and Enum.MouseBehavior.LockCenter or Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = not lockMouse

		-- touch FIRE-drag look + gamepad right stick
		-- scoped: touch and stick turn slower with the zoom (the mouse already divides by zoomMult)
		local scopeSens = if scoped then ADS_SENS / zoomMult else 1
		local lx, ly = Input.takeLook()
		yaw -= lx * CameraController.touchSens * scopeSens
		pitch -= ly * CameraController.touchSens * scopeSens
		if padOn then
			local state = UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
			for _, io in state do
				if io.KeyCode == Enum.KeyCode.Thumbstick2 and io.Position.Magnitude > 0.15 then
					yaw -= io.Position.X * CameraController.padSens * dt * scopeSens
					pitch += io.Position.Y * CameraController.padSens * dt * 0.7 * scopeSens
				end
			end
		end
		pitch = math.clamp(pitch, -1.25, 1.2)

		local aiming = Input.isDown("Aim")
		aimBlend += ((aiming and 1 or 0) - aimBlend) * math.min(1, dt * 14)

		local c = player.Character
		local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = c and c:FindFirstChildOfClass("Humanoid")
		local wantScope = aiming
			and zoomMult >= SCOPE_MIN_ZOOM
			and workspace:GetAttribute("Feel_Scope") ~= "old"
			and not menu
			and root ~= nil
			and hum ~= nil
			and hum.Health > 0
			and not Store.get("holding")
		if wantScope ~= scoped then
			scoped = wantScope
			scopeSince = os.clock()
		end
		local focus: Vector3
		if root then
			-- horizontal follow lags a touch (weight); snap on teleports / drops
			local rp = root.Position
			local want = Vector3.new(rp.X, 0, rp.Z)
			if not focusXZ or (focusXZ - want).Magnitude > 8 or root.Anchored then
				focusXZ = want
			else
				focusXZ = focusXZ:Lerp(want, 1 - math.exp(-dt * FOLLOW_RATE))
			end
			local fxz = focusXZ :: Vector3
			focus = Vector3.new(fxz.X, rp.Y + tune("PivotUp", PIVOT_UP), fxz.Z)
		else
			focus = camera.Focus.Position
			focusXZ = nil
		end
		local bob, fovAdd = CFrame.identity, 0
		if Movement and root then
			local offY, b, f = Movement.cameraStep(dt, focus.Y)
			focus += Vector3.new(0, offY, 0)
			bob = CFrame.identity:Lerp(b, 1 - aimBlend) -- steady while aiming
			fovAdd = f * (1 - aimBlend)
		end
		-- sprint fraction (Movement reports it as its own FOV add) and prone/dive framing
		local sprint = math.clamp(fovAdd / math.max(Config.Move.SprintFov, 0.01), 0, 1)
		local low = false
		if Movement then
			local mode = Movement.getMode()
			low = Movement.getStance() == "prone" or mode == "dive"
		end
		lowBlend += ((low and 1 or 0) - lowBlend) * (1 - math.exp(-dt * 8))
		local inCapsule = c ~= nil and c:GetAttribute("InCapsule") == true
		if inCapsule and root then
			-- the camera rides behind the capsule's heading (A / D turn it, client/CapsuleSteer); pitch stays free
			local lv = root.CFrame.LookVector
			if Vector3.new(lv.X, 0, lv.Z).Magnitude > 0.1 then
				local want = math.atan2(-lv.X, -lv.Z)
				if not wasInCapsule then
					yaw = want
				else
					local d = (want - yaw + math.pi) % (2 * math.pi) - math.pi
					yaw += d * (1 - math.exp(-dt * 10))
				end
			end
			if not wasInCapsule then
				pitch = CAP_PITCH
			end
		end
		wasInCapsule = inCapsule
		-- quick to pull out, slower and eased on the way back in
		capBlend += ((inCapsule and 1 or 0) - capBlend) * (1 - math.exp(-dt * (if inCapsule then 6 else 2.2)))
		if capBlend < 0.002 then
			capBlend = 0
		end
		local capK = capBlend * capBlend * (3 - 2 * capBlend)
		if capK > 0 then
			-- the roof lets go later than the distance, so on the way back in the lens comes down over the capsule
			focus += Vector3.new(0, CAP_TOP * capK ^ 0.4, 0)
		end
		-- strafe roll + forward/back acceleration inertia
		local rollT = 0
		if root then
			local right = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
			local fwd = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
			local vel = root.AssemblyLinearVelocity
			local vx = vel:Dot(right)
			local vf = vel:Dot(fwd)
			local rollMax = STRAFE_ROLL
			rollT = -math.clamp(vx / 16, -1, 1) * rollMax * (1 - aimBlend * 0.6)
			if not root.Anchored then
				local accel = (vf - prevFwdSpeed) / math.max(dt, 1 / 120)
				local lagT = math.clamp(accel / 95, -0.35, 0.35) * (1 - aimBlend * 0.7)
				accelLag += (lagT - accelLag) * (1 - math.exp(-dt * 8))
			else
				accelLag *= math.exp(-dt * 10)
			end
			prevFwdSpeed = vf
		else
			accelLag = 0
			prevFwdSpeed = 0
		end
		rollCur += (rollT - rollCur) * (1 - math.exp(-dt * 6))
		-- shoulder lean (V, 2026-11-15 ask): the camera leans toward the shoulder it sits over and dips while it crosses.
		-- sideBlend is last frame's (eases -1..1); swapK = 1 mid-swap. Studio A/B Feel_ShoulderLean: nil = held lean + dip,
		-- "swap" = lean + dip only during the swap, "off".
		local leanMode = workspace:GetAttribute("Feel_ShoulderLean")
		-- swapK: a 0 -> 1 -> 0 bump over SWAP_TIME after the press (the shoulder blend itself crosses in ~0.07 s, too
		-- quick to see); the held lean eases on its own, slower than the shoulder move
		local swapK = math.sin(math.pi * math.clamp((os.clock() - swapAt) / SWAP_TIME, 0, 1))
		local leanT = 0
		if leanMode ~= "off" then
			local held = if leanMode == "swap" then 0 else -SHOULDER_LEAN * side * (1 - aimBlend * 0.5)
			leanT = held - SHOULDER_LEAN * 1.6 * side * swapK
		end
		leanCur += (leanT - leanCur) * (1 - math.exp(-dt * 7))
		bob = bob * CFrame.Angles(0, 0, rollCur + leanCur)

		local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
		dist += (distTarget - dist) * math.min(1, dt * 8)
		-- hip framing: default -> sprint (wider, a bit back) -> prone/dive (low and close)
		local hipDist = dist + tune("DistAdd", HIP_DIST_ADD) + SPRINT_DIST_ADD * sprint
		local baseShoulder = tune("Shoulder", SHOULDER) :: Vector3
		local hipShoulder = baseShoulder:Lerp(baseShoulder * SPRINT_SHOULDER_SCALE, sprint)
		hipDist += (LOW_DIST - hipDist) * lowBlend
		hipShoulder = hipShoulder:Lerp(LOW_SHOULDER, lowBlend)
		-- carrying a core cell (no fighting): pull back and in toward the middle so the trooper and the load are in view
		local carrying = player:GetAttribute("CarryCell") == true
		carryBlend += ((carrying and 1 or 0) - carryBlend) * (1 - math.exp(-dt * 4))
		if carryBlend > 0.001 then
			local k = carryBlend * carryBlend * (3 - 2 * carryBlend)
			hipDist += CARRY_DIST_ADD * k
			hipShoulder = hipShoulder:Lerp(CARRY_SHOULDER, k)
		end
		-- aim-down-sights: pull in tight over the right shoulder (fixed ADS distance, independent of wheel zoom)
		local ads = aimBlend * aimBlend * (3 - 2 * aimBlend) -- smoothstep: snappy in the middle, soft ends
		local wantDist = hipDist + (tune("AdsDist", ADS_DIST) - hipDist) * ads + accelLag
		local shoulder = hipShoulder:Lerp(tune("AdsShoulder", ADS_SHOULDER), ads)
		sideBlend += (side - sideBlend) * (1 - math.exp(-dt * SIDE_RATE))
		-- LEFT SHOULDER "camera" preset (Studio A/B Feel_LeftShoulder): the gun stays on the right, so while aiming over
		-- the left shoulder the lens goes further left and up, and the local head fades (below), to keep the gun line clear
		local leftAds = 0
		if workspace:GetAttribute("Feel_LeftShoulder") == "camera" then
			leftAds = ads * math.clamp(-sideBlend, 0, 1)
			local extra = tune("LeftAdsExtra", LEFT_ADS_EXTRA) :: Vector3
			shoulder += extra * leftAds
		end
		local dip = if leanMode == "off" then 0 else SHOULDER_DIP * swapK
		shoulder = Vector3.new(shoulder.X * sideBlend, shoulder.Y - dip, shoulder.Z)
		if capK > 0 then
			shoulder = shoulder:Lerp(CAP_LIFT, capK)
			wantDist += (CAP_DIST - wantDist) * capK
		end
		fadeOwnCapsule(if inCapsule then 0 else math.min(1, capK * 2) * 0.85)
		local desired = CFrame.new(focus) * rot * CFrame.new(shoulder + Vector3.new(0, 0, wantDist))
		-- collision: pull in toward focus
		refreshFilter()
		local fromP = (CFrame.new(focus) * rot * CFrame.new(shoulder.X * 0.4, shoulder.Y, 0)).Position
		-- the shoulder start point sits ~1.8 studs above the focus: under a low roof / arch it can start inside or above
		-- the geometry, so first clamp it along focus -> start
		do
			local up = fromP - focus
			local upHit = if up.Magnitude > 0.05 then workspace:Spherecast(focus, 0.4, up, rayParams) else nil
			if upHit then
				fromP = focus + up.Unit * math.max(0, upHit.Distance - 0.15)
			end
		end
		local toP = desired.Position
		-- spherecast so the lens never clips into walls; snap in instantly, ease back out (no popping)
		local offset = toP - fromP
		local full = offset.Magnitude
		local allowed = full
		local hit = workspace:Spherecast(fromP, 0.4, offset, rayParams)
		if hit then
			allowed = math.max(0.5, hit.Distance - 0.15)
		end
		if allowed < camDist then
			camDist = allowed
		else
			camDist = math.min(allowed, camDist + (allowed - camDist) * math.min(1, dt * 5) + dt * 2)
		end
		local camPos = if full > 0 then fromP + offset.Unit * math.min(camDist, full) else toP
		local cf = CFrame.new(camPos) * rot * bob
		local juiceCf = Juice.step(dt)
		cf = cf * juiceCf
		camera.CFrame = cf
		camera.Focus = CFrame.new(focus)
		local fov = tune("Fov", BASE_FOV) - ads * (tune("AdsFovDrop", ADS_FOV_DROP) + (zoomMult - 1) * 22) + SPRINT_FOV_ADD * sprint + CAP_FOV_ADD * capK + Juice.getFov()
		camera.FieldOfView = math.clamp(fov, 20, 100)

		-- lens jammed against the trooper (wall pull-in): fade the local character so it never fills the screen
		if c then
			-- the high shoulder keeps the lens >= ~2 studs from the focus even when pulled fully in, so also use how far
			-- the collision pulled it toward the shoulder start point
			local d = math.min((camPos - focus).Magnitude, camDist)
			local fade = if d < FADE_DIST then math.clamp((FADE_DIST - d) / 1.0, 0, 0.85) else 0
			fade = math.floor(fade * 20 + 0.5) / 20
			-- left-shoulder "camera" preset: the head and helmet go semi-transparent so the gun line shows through
			local headFade = math.floor(tune("LeftHeadFade", LEFT_HEAD_FADE) * leftAds * 20 + 0.5) / 20
			-- scope: the whole local trooper (gun and back pack included) is hidden; re-applied 4x a second while
			-- scoped because gun swaps / mesh loads add new parts
			local reapply = false
			if scoped then
				fade, headFade = 1, 0
				local t = os.clock()
				if t - lastScopeHide > 0.25 then
					lastScopeHide = t
					reapply = true
				end
			end
			if reapply or fade ~= lastFade or headFade ~= lastHeadFade then
				lastFade, lastHeadFade = fade, headFade
				for _, p in c:GetDescendants() do
					if p:IsA("BasePart") or p:IsA("Decal") then
						(p :: any).LocalTransparencyModifier = if headFade > fade and isHeadPart(p) then headFade else fade
					end
				end
			end
		end

		-- face where we aim (unless dead / menu / dive, mantle or tumble own the body)
		if root and hum and hum.Health > 0 and not root.Anchored and (not Movement or Movement.allowFacing()) then
			hum.AutoRotate = false
			local look = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
			root.CFrame = CFrame.lookAt(root.Position, root.Position + look)
		end

		-- scope: after the facing so Aim.origin uses this frame's root; no bob / roll, recoil kick and shake kept
		if scoped and c then
			local o = Aim.origin(c, CombatPose.handSign())
			if o then
				camera.CFrame = CFrame.new(o) * rot * juiceCf
				camera.Focus = CFrame.new(o)
				local sfov = tune("Fov", BASE_FOV) / (math.max(zoomMult, 1) * SCOPE_FOV_DIV) + Juice.getFov() * 0.3
				camera.FieldOfView = math.clamp(sfov, 8, 100)
			end
		end
	end)

	player.CharacterAdded:Connect(function(c)
		task.wait()
		local root = c:WaitForChild("HumanoidRootPart", 5) :: BasePart?
		if root then
			local _, ry, _ = root.CFrame:ToOrientation()
			yaw = ry
		end
	end)
end

return CameraController
