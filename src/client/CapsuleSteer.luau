-- Drop capsule steering: while the local character rides a capsule (character attribute InCapsule, set by
-- server/PlayerService.dropTo) the move input (WASD, touch thumbstick, left stick; Humanoid.MoveDirection, camera
-- relative) goes to the server as Action "capsuleSteer" = Vector3(turn, 0, thrust): A / D turn the capsule, W / S
-- thrust it forward / back.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local CapsuleSteer = {}

local player = Players.LocalPlayer
local SEND_GAP = 1 / 15 -- s between sends while the input changes
local REPEAT = 0.5 -- s: resend an unchanged non-zero input this often (a lost packet can't leave it stuck)

-- the walk input as a flat world direction: Humanoid.MoveDirection (already camera-relative; it still follows the
-- controls while the root is anchored in the capsule)
local function moveDir(c: Model): Vector3
	local hum = c:FindFirstChildOfClass("Humanoid")
	if not hum then
		return Vector3.zero
	end
	local m = hum.MoveDirection
	return Vector3.new(m.X, 0, m.Z)
end

function CapsuleSteer.init()
	local actionEv = Net.event("Action")
	local last = Vector3.zero
	local sentAt = 0
	local riding = false
	RunService.Heartbeat:Connect(function()
		local c = player.Character
		local on = c ~= nil and c:GetAttribute("InCapsule") == true
		if not on then
			if riding then
				riding = false
				last = Vector3.zero
			end
			return
		end
		riding = true
		-- back into stick space (the camera follows the capsule's heading): right = turn, forward = thrust
		local md = moveDir(c :: Model)
		local look = workspace.CurrentCamera.CFrame.LookVector
		local f = Vector3.new(look.X, 0, look.Z)
		f = if f.Magnitude > 0.01 then f.Unit else Vector3.new(0, 0, -1)
		local right = Vector3.new(-f.Z, 0, f.X)
		local w = Vector3.new(md:Dot(right), 0, md:Dot(f))
		if w.Magnitude > 1 then
			w = w.Unit
		end
		local now = os.clock()
		local changed = (w - last).Magnitude > 0.05
		if (changed and now - sentAt >= SEND_GAP) or (w.Magnitude > 0.05 and now - sentAt >= REPEAT) or (changed and w.Magnitude < 0.05) then
			last = w
			sentAt = now
			actionEv:FireServer("capsuleSteer", w)
		end
	end)
end

return CapsuleSteer
