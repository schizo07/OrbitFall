-- Touch button cluster (right side). Only created when Input.isTouch().
-- The Roblox dynamic thumbstick stays on the left; we hide the default jump button (it sits where FIRE goes).
-- Input actions driven: Fire Aim Reload Grenade Dial Jump Sprint Crouch Swap1 Swap2 Swap3, plus Input.addLook / Input.setDialPointer.
-- Store keys read: mission, me, menuOpen, stance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared:WaitForChild("Data"):WaitForChild("Weapons"))
local Store = require(script.Parent.Parent.Store)
local Input = require(script.Parent.Parent.Input)
local Theme = require(script.Parent.Theme)

local C = Theme.C

local MobileControls = {}

local inited = false
local gui: ScreenGui
local root: Frame
local scaleObj: UIScale
local buttons: { [string]: any } = {}

local DIAL_DEAD_ZONE = 18

local function currentScale(): number
	local cam = workspace.CurrentCamera
	local y = cam and cam.ViewportSize.Y or 400
	return Theme.clamp(y / 420, 1, 1.4)
end

local function refreshScale()
	local s = currentScale()
	scaleObj.Scale = s
	root.Size = UDim2.fromScale(1 / s, 1 / s)
end

local function pressVisual(b: any, down: boolean)
	local on = down or b.toggled
	Theme.tween(b.btn, 0.07, { BackgroundTransparency = down and 0.1 or (b.toggled and 0.15 or 0.35) })
	Theme.tween(b.scale, 0.08, { Scale = down and 0.92 or 1 })
	b.stroke.Color = on and C.Gold or b.color
end

local function setToggled(b: any, on: boolean)
	b.toggled = on
	b.btn.BackgroundColor3 = on and b.color or C.Navy
	pressVisual(b, false)
end

-- Generic touch-hold binding. Uses InputObject.Changed so drags that leave the button keep working.
local function bind(b: any, onDown: ((InputObject) -> ())?, onUp: (() -> ())?, onMove: ((InputObject) -> ())?)
	local active: InputObject? = nil
	b.btn.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch or active then
			return
		end
		active = input
		pressVisual(b, true)
		Theme.sfx("UIClick")
		if onDown then
			onDown(input)
		end
		local c: RBXScriptConnection
		c = input.Changed:Connect(function()
			local st = input.UserInputState
			if st == Enum.UserInputState.End or st == Enum.UserInputState.Cancel then
				c:Disconnect()
				active = nil
				pressVisual(b, false)
				if onUp then
					onUp()
				end
			elseif onMove then
				onMove(input)
			end
		end)
	end)
end

local function make(name: string, cx: number, cy: number, d: number, glyph: string, caption: string, color: Color3, glyphSize: number?): any
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.BackgroundColor3 = C.Navy
	btn.BackgroundTransparency = 0.35
	btn.BorderSizePixel = 0
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.Position = UDim2.new(1, -cx, 1, -cy)
	btn.Size = UDim2.fromOffset(d, d)
	btn.Parent = root
	Theme.corner(btn, d)
	local st = Theme.stroke(btn, color, 3, 0.15)
	local scale = Instance.new("UIScale")
	scale.Parent = btn
	local g = Theme.label({
		Text = glyph,
		Font = "Black",
		TextSize = glyphSize or math.floor(d * 0.36),
		Size = UDim2.fromScale(1, caption ~= "" and 0.62 or 1),
		Position = UDim2.fromScale(0, caption ~= "" and 0.1 or 0),
		Parent = btn,
	})
	local cap = Theme.label({
		Text = caption,
		Font = "Header",
		TextSize = 9,
		Color = color,
		Size = UDim2.fromScale(1, 0.2),
		Position = UDim2.fromScale(0, 0.68),
		Visible = caption ~= "",
		Parent = btn,
	})
	local b = { btn = btn, scale = scale, stroke = st, glyph = g, caption = cap, color = color, toggled = false, name = name }
	buttons[name] = b
	return b
end

local function hideDefaultJump()
	task.spawn(function()
		local pg = Theme.playerGui()
		local touchGui = pg:WaitForChild("TouchGui", 20)
		if not touchGui then
			return
		end
		local frame = touchGui:WaitForChild("TouchControlFrame", 10)
		local jb = frame and frame:WaitForChild("JumpButton", 10)
		if jb and jb:IsA("GuiObject") then
			jb.Visible = false
			jb:GetPropertyChangedSignal("Visible"):Connect(function()
				if jb.Visible then
					jb.Visible = false
				end
			end)
		end
	end)
end

local function refreshVisibility()
	local m = Store.get("mission")
	local me = Store.get("me")
	local state = m and m.state or "Ship"
	local menu = Store.get("menuOpen") == true
	local alive = not me or me.alive ~= false
	local combat = (state == "Active" or state == "Extract") and alive and not menu
	local move = (state == "Active" or state == "Extract" or state == "Ship") and alive and not menu
	for name, b in buttons do
		local show = combat
		if name == "Jump" or name == "Sprint" or name == "Crouch" then
			show = move
		end
		b.btn.Visible = show
	end
	gui.Enabled = not menu
end

function MobileControls.init()
	if inited then
		return
	end
	if not Input.isTouch() then
		return
	end
	inited = true

	gui = Theme.gui("OrbitMobile", { DisplayOrder = 20, Insets = "DeviceSafeInsets" })
	root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	scaleObj = Instance.new("UIScale")
	scaleObj.Parent = root
	root.Parent = gui
	refreshScale()
	local function hookCam()
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(refreshScale)
		end
		refreshScale()
	end
	hookCam()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCam)

	-- FIRE (hold; dragging turns the camera)
	local fire = make("Fire", 76, 76, 104, "FIRE", "", C.Accent, 24)
	fire.btn.BackgroundColor3 = Color3.fromHex("5a2a10")
	do
		local last = Vector2.zero
		bind(fire, function(input)
			last = Vector2.new(input.Position.X, input.Position.Y)
			Input.set("Fire", true)
		end, function()
			Input.set("Fire", false)
		end, function(input)
			local p = Vector2.new(input.Position.X, input.Position.Y)
			local d = p - last
			last = p
			if d.X ~= 0 or d.Y ~= 0 then
				Input.addLook(d.X, d.Y)
			end
		end)
	end

	-- UPLINK (press opens dial; drag picks a slot; release selects)
	local uplink = make("Uplink", 250, 84, 72, "📡", "UPLINK", C.Friendly, 26)
	do
		local origin = Vector2.zero
		bind(uplink, function(input)
			origin = Vector2.new(input.Position.X, input.Position.Y)
			Input.setDialPointer(nil)
			Input.set("Dial", true)
		end, function()
			Input.set("Dial", false)
			Input.setDialPointer(nil)
		end, function(input)
			local v = Vector2.new(input.Position.X, input.Position.Y) - origin
			if v.Magnitude < DIAL_DEAD_ZONE then
				Input.setDialPointer(nil)
			else
				Input.setDialPointer(v.Unit)
			end
		end)
	end

	-- AIM (toggle)
	local aim = make("Aim", 172, 48, 64, "◎", "AIM", C.Accent, 26)
	bind(aim, function()
		local on = not aim.toggled
		setToggled(aim, on)
		Input.set("Aim", on)
	end)
	Input.on("Aim", function(isDown)
		if aim.toggled ~= isDown then
			setToggled(aim, isDown)
		end
	end)

	-- RELOAD
	local reload = make("Reload", 170, 120, 64, "↻", "RELOAD", C.Accent, 28)
	bind(reload, function()
		Input.set("Reload", true)
	end, function()
		Input.set("Reload", false)
	end)

	-- GRENADE
	local grenade = make("Grenade", 156, 192, 64, "💣", "GRENADE", C.Accent, 26)
	bind(grenade, function()
		Input.set("Grenade", true)
	end, function()
		Input.set("Grenade", false)
	end)

	-- JUMP (hold)
	local jump = make("Jump", 76, 176, 64, "▲", "JUMP", C.Text, 24)
	bind(jump, function()
		Input.set("Jump", true)
	end, function()
		Input.set("Jump", false)
	end)

	-- SPRINT (toggle)
	local sprint = make("Sprint", 248, 160, 64, "»", "SPRINT", C.Friendly, 28)
	bind(sprint, function()
		local on = not sprint.toggled
		setToggled(sprint, on)
		Input.set("Sprint", on)
	end)
	Input.on("Sprint", function(isDown)
		if sprint.toggled ~= isDown then
			setToggled(sprint, isDown)
		end
	end)

	-- CROUCH (tap = crouch/stand, hold = prone, while sprinting = dive) -> client/Movement.luau
	local crouch = make("Crouch", 236, 236, 64, "▼", "CROUCH", C.Friendly, 22)
	bind(crouch, function()
		Input.set("Crouch", true)
	end, function()
		Input.set("Crouch", false)
	end)
	local function refreshCrouch()
		local st = Store.get("stance")
		local glyph, caption = "▼", "CROUCH"
		if st == "prone" then
			glyph, caption = "▬", "PRONE"
		elseif sprint.toggled and st ~= "crouch" then
			glyph, caption = "↘", "DIVE"
		end
		crouch.glyph.Text = glyph
		crouch.caption.Text = caption
		local on = st == "crouch" or st == "prone"
		if crouch.toggled ~= on then
			setToggled(crouch, on)
		end
	end
	Store.on("stance", refreshCrouch)
	Input.on("Sprint", function()
		task.defer(refreshCrouch)
	end)

	-- SWAP weapon chip: cycles Swap1 -> Swap2 -> Swap3
	local swap = make("Swap", 76, 246, 64, "PR7", "SWAP", C.Gold, 15)
	swap.glyph.TextScaled = true
	local swapLimit = Instance.new("UITextSizeConstraint")
	swapLimit.MaxTextSize = 16
	swapLimit.MinTextSize = 8
	swapLimit.Parent = swap.glyph
	swap.glyph.Size = UDim2.fromScale(0.72, 0.4)
	swap.glyph.Position = UDim2.fromScale(0.14, 0.2)
	bind(swap, function()
		local me = Store.get("me")
		local cur = me and me.weapon or 1
		-- empty slots arrive as `false`: step to the next slot that actually holds a weapon
		local nxt = cur
		if me and me.weapons then
			for k = 1, 3 do
				local i = (cur + k - 1) % 3 + 1
				if me.weapons[i] then
					nxt = i
					break
				end
			end
		end
		if nxt == cur then
			return
		end
		local action = "Swap" .. nxt
		Input.set(action, true)
		task.delay(0.06, function()
			Input.set(action, false)
		end)
	end)

	local function refreshSwap()
		local me = Store.get("me")
		local entry = me and me.weapons and me.weapons[me.weapon or 1]
		local def = entry and Weapons.get(entry.id)
		swap.glyph.Text = def and def.id or "?"
	end

	Store.on("mission", refreshVisibility)
	Store.on("menuOpen", refreshVisibility)
	Store.on("me", function()
		refreshVisibility()
		refreshSwap()
	end)
	refreshVisibility()
	refreshSwap()
	hideDefaultJump()
end

return MobileControls
