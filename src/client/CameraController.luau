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

local yaw, pitch = 0, -0.15
local dist = 10 -- smoothed zoom distance
local distTarget = 10 -- player zoom (mouse wheel / pinch), clamped to [DIST_MIN, DIST_MAX]
local DIST_MIN, DIST_MAX = 6.5, 20
local aimBlend = 0
local zoomMult = 1
local ADS_DIST = 5.4 -- lens distance behind the focus while aiming
local ADS_SHOULDER = Vector3.new(1.75, 0.7, 0) -- right-shoulder offset while aiming
local ADS_FOV_DROP = 20 -- 70 -> 50 FOV at full aim
local ADS_SENS = 0.5 -- look sensitivity multiplier at full aim
local freeMouse = false -- set by dial/menus
CameraController.sens = 0.0042
CameraController.touchSens = 0.0065
CameraController.padSens = 3.0

local touchLook: { [InputObject]: Vector3 } = {}

function CameraController.setFreeMouse(v: boolean)
	freeMouse = v
end

function CameraController.setZoom(mult: number)
	zoomMult = mult
end

function CameraController.getYaw(): number
	return yaw
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

local function camExclude(): { Instance }
	local list: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, n in { "Enemies", "ClientFx", "CallInObjects" } do
		local f = workspace:FindFirstChild(n)
		if f then
			table.insert(list, f)
		end
	end
	return list
end

function CameraController.init()
	camera.CameraType = Enum.CameraType.Scriptable

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
				yaw -= d.X * CameraController.touchSens
				pitch -= d.Y * CameraController.touchSens
			end
		end
		if io.UserInputType == Enum.UserInputType.MouseWheel and not gp then
			distTarget = math.clamp(distTarget - io.Position.Z * 1.5, DIST_MIN, DIST_MAX)
		end
	end)
	local pinchStart = distTarget
	UserInputService.TouchPinch:Connect(function(_touches, scale, _velocity, state, gp)
		if gp then
			return
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
		local lx, ly = Input.takeLook()
		yaw -= lx * CameraController.touchSens
		pitch -= ly * CameraController.touchSens
		local state = UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
		for _, io in state do
			if io.KeyCode == Enum.KeyCode.Thumbstick2 and io.Position.Magnitude > 0.15 then
				yaw -= io.Position.X * CameraController.padSens * dt
				pitch += io.Position.Y * CameraController.padSens * dt * 0.7
			end
		end
		pitch = math.clamp(pitch, -1.25, 1.2)

		local aiming = Input.isDown("Aim")
		aimBlend += ((aiming and 1 or 0) - aimBlend) * math.min(1, dt * 14)

		local c = player.Character
		local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = c and c:FindFirstChildOfClass("Humanoid")
		local focus: Vector3
		if root then
			focus = root.Position + Vector3.new(0, 2.1, 0)
		else
			focus = camera.Focus.Position
		end
		local bob, fovAdd = CFrame.identity, 0
		if Movement and root then
			local offY, b, f = Movement.cameraStep(dt, focus.Y)
			focus += Vector3.new(0, offY, 0)
			bob = CFrame.identity:Lerp(b, 1 - aimBlend) -- steady while aiming
			fovAdd = f * (1 - aimBlend)
		end
		local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
		dist += (distTarget - dist) * math.min(1, dt * 8)
		-- aim-down-sights: pull in tight over the right shoulder (fixed ADS distance, independent of wheel zoom)
		local ads = aimBlend * aimBlend * (3 - 2 * aimBlend) -- smoothstep: snappy in the middle, soft ends
		local wantDist = dist + (ADS_DIST - dist) * ads
		local shoulder = Vector3.new(2.3 + (ADS_SHOULDER.X - 2.3) * ads, 1.1 + (ADS_SHOULDER.Y - 1.1) * ads, 0)
		local desired = CFrame.new(focus) * rot * CFrame.new(shoulder + Vector3.new(0, 0, wantDist))
		-- collision: pull in toward focus
		rayParams.FilterDescendantsInstances = camExclude()
		local fromP = (CFrame.new(focus) * rot * CFrame.new(shoulder.X * 0.4, shoulder.Y, 0)).Position
		local toP = desired.Position
		-- spherecast so the lens never clips into walls; snap in instantly, ease back out (no popping)
		local offset = toP - fromP
		local full = offset.Magnitude
		local allowed = full
		local hit = workspace:Spherecast(fromP, 0.45, offset, rayParams)
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
		cf = cf * Juice.step(dt)
		camera.CFrame = cf
		camera.Focus = CFrame.new(focus)
		local fov = 70 - ads * (ADS_FOV_DROP + (zoomMult - 1) * 22) + fovAdd
		camera.FieldOfView = fov

		-- face where we aim (unless dead / menu / dive, mantle or tumble own the body)
		if root and hum and hum.Health > 0 and not root.Anchored and (not Movement or Movement.allowFacing()) then
			hum.AutoRotate = false
			local look = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
			root.CFrame = CFrame.lookAt(root.Position, root.Position + look)
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
