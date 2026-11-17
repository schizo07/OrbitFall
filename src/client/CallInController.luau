-- Uplink input + beacon throw.
-- Two arm methods (Studio A/B group "UPLINK ARM", workspace attribute Feel_UplinkArm):
--   Codes (default, PC + gamepad): hold the dial key (Q / LB) -> code list (UI/UplinkCodes). WASD / arrow keys / D-pad type
--     arrows; the character does not walk from WASD while the list is open (ContextActionService sink, see bindArrows).
--     A full code arms the call-in (callin_ready). It stays armed after you let go of the dial key until you throw it
--     (Fire), cancel it (Reload), swap weapons, die, or arm another one. Pressing the dial key again re-opens the list.
--   Slot+Sync (Feel_UplinkArm = "slot"): the old radial UplinkDial with the Perfect Sync needle. Touch always uses this
--     (tap / drag to pick), so phones never type codes.
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local CallIns = require(Shared.Data.CallIns)

local Store = require(script.Parent.Store)
local Input = require(script.Parent.Input)
local Audio = require(script.Parent.Audio)
local Cam = require(script.Parent.CameraController)
local Codes = require(script.Parent.UI.UplinkCodes)
local ThrowArc = require(script.Parent.ThrowArc)

local CallInController = {}
local actionEv: RemoteEvent
local Dial: any
local aimPointFn: (number, number?) -> Vector3
local holdingSince = 0
local openMode: string? = nil -- "codes" | "slot" while the dial key is down
local arrowsBound = false
local lastServerHolding: string? = nil
local padPtr: Vector2? = nil -- last right-stick dial direction (gamepad)
local padPtrAt = 0
local PAD_PTR_KEEP = 0.2 -- s the last stick direction stays selected after the stick is released

local ARROW_ACTION = "OrbitUplinkCodes"
local ARROW_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.W] = "U",
	[Enum.KeyCode.S] = "D",
	[Enum.KeyCode.A] = "L",
	[Enum.KeyCode.D] = "R",
	[Enum.KeyCode.Up] = "U",
	[Enum.KeyCode.Down] = "D",
	[Enum.KeyCode.Left] = "L",
	[Enum.KeyCode.Right] = "R",
	[Enum.KeyCode.DPadUp] = "U",
	[Enum.KeyCode.DPadDown] = "D",
	[Enum.KeyCode.DPadLeft] = "L",
	[Enum.KeyCode.DPadRight] = "R",
}

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

local function heldId(): string?
	local h = Store.get("holding") or serverHolding()
	return if type(h) == "table" and type(h.id) == "string" then h.id else nil
end

local function canUse(): boolean
	local m = me()
	return m ~= nil and m.alive and not m.dropping and not m.downed and not Store.get("menuOpen")
end

-- Arm method for the next dial press. Touch always uses the radial dial.
local function codesMode(): boolean
	if Input.isTouch() then
		return false
	end
	return workspace:GetAttribute("Feel_UplinkArm") ~= "slot"
end

-- Context hints with the real bindings
local function throwHint(): string
	if Input.isTouch() then
		return "Tap FIRE to throw"
	end
	local pad = Input.isGamepad()
	if codesMode() then
		return if pad then "Press [R2] to throw   [X] cancel" else "Press [LMB] to throw   [R] cancel"
	end
	return if pad then "[R2] or [LB] to throw" else "Left-click or [Q] to throw"
end

local function typeHint(): string
	return if Input.isGamepad() then "Hold [LB] + D-pad: type a code" else "Hold [Q] + WASD / arrows: type a code"
end

-- How to open the uplink at all (HUD mission-start banner reads Store "dialHint")
local function dialHint(): string
	if Input.isTouch() then
		return "Tap UPLINK to call the sky down"
	end
	if codesMode() then
		return typeHint()
	end
	return if Input.isGamepad() then "Hold [LB] for the Uplink Dial" else "Hold [Q] for the Uplink Dial"
end

local function refreshHints()
	Store.set("throwHint", throwHint())
	Store.set("dialHint", dialHint())
	if Codes.isOpen() then
		local id = heldId()
		if id then
			local def = CallIns.get(id)
			Codes.setHint(string.format("%s  -  %s", def and def.name or id, throwHint()), Color3.fromHex("F5B93A"))
		else
			Codes.setHint(typeHint())
		end
	end
end

local function throw()
	local p = aimPointFn(45, 0)
	actionEv:FireServer("callin_throw", p)
	ThrowArc.thrown()
	Store.set("holding", nil)
	Codes.setArmed(nil)
	refreshHints()
	Audio.play2D("BeaconThrow")
end

local function cancelHolding()
	actionEv:FireServer("callin_cancel")
	Store.set("holding", nil)
	Codes.setArmed(nil)
	refreshHints()
end

local function toast(text: string)
	Store.set("toast", text)
end

-- Codes ----------------------------------------------------------------------------------------------------------------------
local function arm(entry: any)
	actionEv:FireServer("callin_ready", entry.slot, false)
	Store.set("holding", { id = entry.id, perfect = false })
	holdingSince = os.clock()
	Codes.setArmed(entry.id)
	refreshHints()
end

local function onArrow(dir: string)
	if not canUse() then
		return
	end
	local kind, entry = Codes.press(dir)
	if kind == "step" then
		Audio.play2D("DialTick")
	elseif kind == "error" then
		Audio.play2D("UIError")
	elseif kind == "match" and entry then
		if entry.available then
			Audio.play2D("DialSelect")
			arm(entry)
		else
			Audio.play2D("UIError")
			local name = entry.def and entry.def.name or entry.id
			if entry.status == "COOLDOWN" then
				toast(string.format("%s on cooldown (%ds)", name, math.ceil(entry.remaining or 0)))
			elseif entry.status == "NO USES" then
				toast(name .. ": no uses left")
			else
				toast(name .. " is not ready")
			end
		end
	end
end

-- While the code list is open, WASD / arrows / D-pad are sunk above the default movement controls. Binding over a key
-- that is already held sends Cancel to the movement action, which zeroes its move vector, so nothing keeps walking;
-- after the unbind, a key still held stays idle until it is pressed again.
local function bindArrows(on: boolean)
	if on == arrowsBound then
		return
	end
	arrowsBound = on
	if on then
		local keys = {}
		for k in ARROW_KEYS do
			table.insert(keys, k)
		end
		ContextActionService:BindActionAtPriority(ARROW_ACTION, function(_, state, io)
			if state == Enum.UserInputState.Begin then
				local dir = ARROW_KEYS[io.KeyCode]
				if dir then
					task.spawn(onArrow, dir)
				end
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 100, table.unpack(keys))
	else
		ContextActionService:UnbindAction(ARROW_ACTION)
	end
end

local function openCodes()
	openMode = "codes"
	Codes.setArmed(heldId())
	Codes.open()
	bindArrows(true)
	Store.set("dialOpen", true)
	refreshHints()
	Audio.play2D("DialOpen")
end

local function closeCodes()
	bindArrows(false)
	Codes.close()
	Store.set("dialOpen", nil)
end

-- Slot + Sync (radial dial) ------------------------------------------------------------------------------------------------------
-- The right stick points at the dial slot, so it must not also turn the camera while the dial is open. CameraController
-- reads padSens every frame; hold it at 0 while open and put it back on close.
local savedPadSens: number? = nil
local function holdStickLook(hold: boolean)
	if hold then
		if savedPadSens == nil then
			savedPadSens = Cam.padSens
			Cam.padSens = 0
		end
	elseif savedPadSens ~= nil then
		Cam.padSens = savedPadSens
		savedPadSens = nil
	end
end

local function openDial()
	if not Dial or Dial.isOpen() then
		return
	end
	openMode = "slot"
	padPtr = nil
	Dial.open()
	Store.set("dialOpen", true)
	Cam.setFreeMouse(not Input.isTouch())
	holdStickLook(true)
	Audio.play2D("DialOpen")
end

local function closeDial()
	holdStickLook(false)
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
			refreshHints()
			Store.set("toast", (perfect and "PERFECT SYNC — " or "") .. "Throw the " .. (def and def.name or id) .. " beacon")
		end
	end
end

local function closeAny()
	local mode = openMode
	openMode = nil
	if mode == "codes" then
		closeCodes()
	elseif mode == "slot" then
		closeDial()
	end
end

-- Close without picking anything (death, a menu opening).
local function abortAny()
	local mode = openMode
	openMode = nil
	holdStickLook(false)
	if mode == "codes" then
		closeCodes()
	elseif Dial and Dial.isOpen() then
		Dial.close()
		Store.set("dialOpen", nil)
		Cam.setFreeMouse(false)
	end
end

function CallInController.init(dialModule, aimPoint: (number, number?) -> Vector3)
	Dial = dialModule
	aimPointFn = aimPoint
	actionEv = Net.event("Action")
	Codes.init()
	refreshHints()
	ThrowArc.init(aimPoint, CallInController.isHolding, heldId)

	Input.on("Dial", function(down)
		if down then
			if openMode ~= nil or not canUse() then
				return
			end
			if codesMode() then
				openCodes()
				return
			end
			if CallInController.isHolding() then
				throw()
				return
			end
			openDial()
		else
			closeAny()
		end
	end)
	Input.on("Fire", function(down)
		-- codes: throw also works while the list is still open (you aim with the camera while typing)
		if down and canUse() and CallInController.isHolding() and not (Dial and Dial.isOpen()) then
			throw()
		end
	end)
	Input.on("Reload", function(down)
		-- reload while holding a beacon cancels it
		if down and CallInController.isHolding() then
			cancelHolding()
		end
	end)
	-- codes: swapping weapons drops an armed call-in (the radial dial keeps its old behaviour)
	for _, a in { "Swap1", "Swap2", "Swap3", "SwapNext" } do
		Input.on(a, function(down)
			if down and codesMode() and CallInController.isHolding() then
				cancelHolding()
			end
		end)
	end

	Store.on("me", function(m)
		-- server is authoritative: drop our prediction once the server disagrees for a while
		if Store.get("holding") and not (m and m.callins and m.callins.holding) and os.clock() - holdingSince > 1.0 then
			Store.set("holding", nil)
		end
		-- armed confirmation click + keep the list's ACTIVATING row in step with the server
		local sid = m and m.callins and m.callins.holding and m.callins.holding.id or nil
		if sid ~= lastServerHolding then
			if sid and codesMode() then
				Audio.play2D("UIClick")
			end
			lastServerHolding = sid
			Codes.setArmed(heldId())
			refreshHints()
		end
		if m and not m.alive then
			Store.set("holding", nil)
			Codes.setArmed(nil)
			abortAny()
		end
	end)
	Store.on("menuOpen", function(v)
		if v then
			abortAny()
		end
	end)
	-- PC <-> gamepad: re-word the hints (LastInputTypeChanged also fires for mouse <-> keyboard, so only on a real change)
	local wasPad = Input.isGamepad()
	UserInputService.LastInputTypeChanged:Connect(function()
		local pad = Input.isGamepad()
		if pad ~= wasPad then
			wasPad = pad
			refreshHints()
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
					padPtr, padPtrAt = ptr, os.clock()
				end
			end
			if not ptr and padPtr and os.clock() - padPtrAt < PAD_PTR_KEEP then
				ptr = padPtr -- the stick sprang back a frame or two before LB was released: keep the choice
			end
			-- the mouse only when the last input was not a gamepad (on a console GetMouseLocation is not the centre)
			if not ptr and not Input.isGamepad() then
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
