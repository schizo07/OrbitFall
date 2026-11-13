-- Abstract input actions for keyboard/mouse, gamepad and touch (MobileControls calls Input.set).
-- Actions: Fire Aim Reload Grenade Dial Interact Sprint Swap1 Swap2 Swap3 Jump Scoreboard Crouch Prone
local UserInputService = game:GetService("UserInputService")

local Input = {}
local down: { [string]: boolean } = {}
local handlers: { [string]: { (boolean) -> () } } = {}
local lookDx, lookDy = 0, 0
local dialPtr: Vector2? = nil

local KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.R] = "Reload",
	[Enum.KeyCode.G] = "Grenade",
	[Enum.KeyCode.Q] = "Dial",
	[Enum.KeyCode.E] = "Interact",
	[Enum.KeyCode.LeftShift] = "Sprint",
	[Enum.KeyCode.One] = "Swap1",
	[Enum.KeyCode.Two] = "Swap2",
	[Enum.KeyCode.Three] = "Swap3",
	[Enum.KeyCode.Tab] = "Scoreboard",
	[Enum.KeyCode.ButtonR2] = "Fire",
	[Enum.KeyCode.ButtonL2] = "Aim",
	[Enum.KeyCode.ButtonX] = "Reload",
	[Enum.KeyCode.ButtonR1] = "Grenade",
	[Enum.KeyCode.ButtonL1] = "Dial",
	[Enum.KeyCode.ButtonL3] = "Sprint",
	[Enum.KeyCode.ButtonY] = "SwapNext",
	-- movement (client/Movement.luau): Crouch tap = crouch, hold = prone, while sprinting = dive
	[Enum.KeyCode.C] = "Crouch",
	[Enum.KeyCode.LeftControl] = "Crouch",
	[Enum.KeyCode.Z] = "Prone",
	[Enum.KeyCode.ButtonB] = "Crouch",
	[Enum.KeyCode.Space] = "Jump",
	[Enum.KeyCode.ButtonA] = "Jump",
}
-- Default Roblox controls sink these (gameProcessed = true) but we still need to see them (mantle, stand up).
local PASS_GP: { [string]: boolean } = { Jump = true }
local MOUSE: { [Enum.UserInputType]: string } = {
	[Enum.UserInputType.MouseButton1] = "Fire",
	[Enum.UserInputType.MouseButton2] = "Aim",
}

function Input.on(action: string, fn: (boolean) -> ())
	handlers[action] = handlers[action] or {}
	table.insert(handlers[action], fn)
end

function Input.set(action: string, isDown: boolean)
	if down[action] == isDown then
		return
	end
	down[action] = isDown
	local hs = handlers[action]
	if hs then
		for _, fn in hs do
			task.spawn(fn, isDown)
		end
	end
end

function Input.isDown(action: string): boolean
	return down[action] == true
end

function Input.isTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

function Input.isGamepad(): boolean
	return UserInputService.GamepadEnabled and UserInputService:GetLastInputType().Name:find("Gamepad") ~= nil
end

function Input.addLook(dx: number, dy: number)
	lookDx += dx
	lookDy += dy
end

-- Consumed by CameraController each frame.
function Input.takeLook(): (number, number)
	local x, y = lookDx, lookDy
	lookDx, lookDy = 0, 0
	return x, y
end

function Input.setDialPointer(v: Vector2?)
	dialPtr = v
end

function Input.dialPointer(): Vector2?
	return dialPtr
end

function Input.init()
	UserInputService.InputBegan:Connect(function(io, gp)
		local a = MOUSE[io.UserInputType] or KEYS[io.KeyCode]
		if not a then
			return
		end
		if gp and io.UserInputType ~= Enum.UserInputType.Gamepad1 then
			if not (PASS_GP[a] and UserInputService:GetFocusedTextBox() == nil) then
				return
			end
		end
		Input.set(a, true)
	end)
	UserInputService.InputEnded:Connect(function(io)
		local a = MOUSE[io.UserInputType] or KEYS[io.KeyCode]
		if a then
			Input.set(a, false)
		end
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		for a, v in down do
			if v then
				Input.set(a, false)
			end
		end
	end)
end

return Input
