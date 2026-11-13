-- Uplink Dial input + beacon throw. Dial UI lives in UI/UplinkDial.
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local CallIns = require(Shared.Data.CallIns)

local Store = require(script.Parent.Store)
local Input = require(script.Parent.Input)
local Audio = require(script.Parent.Audio)
local Cam = require(script.Parent.CameraController)

local CallInController = {}
local actionEv: RemoteEvent
local Dial: any
local aimPointFn: (number, number?) -> Vector3
local holdingSince = 0

local function me()
	return Store.get("me")
end

local function serverHolding()
	local m = me()
	return m and m.callins and m.callins.holding
end

function CallInController.isHolding(): boolean
	return Store.get("holding") ~= nil or serverHolding() ~= nil
end

local function canUse(): boolean
	local m = me()
	return m ~= nil and m.alive and not m.dropping and not Store.get("menuOpen")
end

local function throw()
	local p = aimPointFn(45, 0)
	actionEv:FireServer("callin_throw", p)
	Store.set("holding", nil)
	Audio.play2D("BeaconThrow")
end

local function openDial()
	if not Dial or Dial.isOpen() then
		return
	end
	Dial.open()
	Store.set("dialOpen", true)
	Cam.setFreeMouse(not Input.isTouch())
	Audio.play2D("DialOpen")
end

local function closeDial()
	if not Dial or not Dial.isOpen() then
		return
	end
	local slot, perfect = Dial.close()
	Store.set("dialOpen", nil)
	Cam.setFreeMouse(false)
	if slot ~= nil then
		local m = me()
		local id
		if slot == "REINFORCE" then
			id = "REINFORCE"
		else
			local s = m and m.callins and m.callins.slots and m.callins.slots[slot]
			id = s and s.id
		end
		if id then
			actionEv:FireServer("callin_ready", slot, perfect == true)
			Store.set("holding", { id = id, perfect = perfect })
			holdingSince = os.clock()
			local def = CallIns.get(id)
			Audio.play2D(perfect and "DialPerfect" or "DialSelect")
			Store.set("toast", (perfect and "PERFECT SYNC — " or "") .. "Throw the " .. (def and def.name or id) .. " beacon")
		end
	end
end

function CallInController.init(dialModule, aimPoint: (number, number?) -> Vector3)
	Dial = dialModule
	aimPointFn = aimPoint
	actionEv = Net.event("Action")

	Input.on("Dial", function(down)
		if down then
			if not canUse() then
				return
			end
			if CallInController.isHolding() then
				throw()
				return
			end
			openDial()
		else
			closeDial()
		end
	end)
	Input.on("Fire", function(down)
		if down and canUse() and CallInController.isHolding() and not (Dial and Dial.isOpen()) then
			throw()
		end
	end)
	Input.on("Reload", function(down)
		-- reload while holding a beacon cancels it
		if down and CallInController.isHolding() then
			actionEv:FireServer("callin_cancel")
			Store.set("holding", nil)
		end
	end)

	Store.on("me", function(m)
		-- server is authoritative: drop our prediction once the server disagrees for a while
		if Store.get("holding") and not (m and m.callins and m.callins.holding) and os.clock() - holdingSince > 1.0 then
			Store.set("holding", nil)
		end
		if m and not m.alive then
			Store.set("holding", nil)
			if Dial and Dial.isOpen() then
				Dial.close()
				Store.set("dialOpen", nil)
				Cam.setFreeMouse(false)
			end
		end
	end)

	RunService.RenderStepped:Connect(function()
		if not Dial or not Dial.isOpen() then
			return
		end
		local ptr: Vector2? = nil
		if Input.isTouch() then
			ptr = Input.dialPointer()
		else
			local pad = UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
			for _, io in pad do
				if io.KeyCode == Enum.KeyCode.Thumbstick2 and io.Position.Magnitude > 0.4 then
					ptr = Vector2.new(io.Position.X, -io.Position.Y).Unit
				end
			end
			if not ptr then
				local cam = workspace.CurrentCamera
				local centre = cam.ViewportSize / 2
				local mp = UserInputService:GetMouseLocation()
				local d = mp - centre
				if d.Magnitude > 40 then
					ptr = d.Unit
				end
			end
		end
		Dial.setPointer(ptr)
	end)
end

return CallInController
