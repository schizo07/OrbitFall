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
	[Enum.KeyCode.V] = "Shoulder", -- swap camera shoulder (CameraController)
	[Enum.KeyCode.ButtonR3] = "Shoulder",
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
-- Stim (client/Fx/VitalsFx): F. Gamepad D-pad Left is read by VitalsFx itself and only while the Uplink dial (LB) is
-- NOT held, because the D-pad types call-in codes while LB is held. Touch: MobileControls STIM button.
KEYS[Enum.KeyCode.F] = "Stim"
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

-- Studio-only: workspace attribute DebugHold_<Action> = true holds an action down for scripted tests
-- (simulated mouse holds are unreliable). Live games skip the attribute read.
local IS_STUDIO = game:GetService("RunService"):IsStudio()

-- Optional gates: while gate(action)() returns true, Input.isDown(action) reads false (held-state readers like the gun,
-- the ADS camera and the aim pose stop). Edge handlers (Input.on) still fire. Used by client/CellCarry (haul carrier).
local gates: { [string]: () -> boolean } = {}
function Input.setGate(action: string, fn: (() -> boolean)?)
	gates[action] = fn :: any
end
function Input.isGated(action: string): boolean
	local g = gates[action]
	return g ~= nil and g() == true
end

function Input.isDown(action: string): boolean
	if gates[action] and Input.isGated(action) then
		return false
	end
	if IS_STUDIO and workspace:GetAttribute("DebugHold_" .. action) == true then
		return true
	end
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

-- Gamepad X is both Reload and the ProximityPrompt default key. Studio A/B "PAD INTERACT" (Feel_PadInteract):
--   nil    = X interacts while a prompt is up (no reload then), reloads otherwise
--   "dpad" = shown prompts move to D-pad Up (client-side), X always reloads
local shownPrompts: { [ProximityPrompt]: boolean } = {}
local function padInteractDpad(): boolean
	return workspace:GetAttribute("Feel_PadInteract") == "dpad"
end
function Input.padInteractKey(): string -- ContextPrompt label for Interact on a gamepad
	return if padInteractDpad() then "@up" else "X"
end
local function promptUp(): boolean
	for pp in shownPrompts do
		if pp.Parent and pp.Enabled then
			return true
		end
		shownPrompts[pp] = nil
	end
	return false
end
local function hookPrompts()
	local PPS = game:GetService("ProximityPromptService")
	PPS.PromptShown:Connect(function(pp: ProximityPrompt)
		shownPrompts[pp] = true
		local want = if padInteractDpad() then Enum.KeyCode.DPadUp else Enum.KeyCode.ButtonX
		if pp.GamepadKeyCode ~= want then
			pp.GamepadKeyCode = want
		end
	end)
	PPS.PromptHidden:Connect(function(pp: ProximityPrompt)
		shownPrompts[pp] = nil
	end)
end

function Input.init()
	hookPrompts()
	UserInputService.InputBegan:Connect(function(io, gp)
		local a = MOUSE[io.UserInputType] or KEYS[io.KeyCode]
		if not a then
			return
		end
		if io.KeyCode == Enum.KeyCode.ButtonX and not padInteractDpad() and promptUp() then
			return -- X goes to the prompt this time
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
