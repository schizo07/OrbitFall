-- Support-weapon drop (shared by ROCKETDROP / GATLINGDROP / RAILDROP; the weapon id comes from params).
-- A pod lands, leaving a case with a ProximityPrompt. First player to take it gets the weapon.
local POD_FALL = 1.6
local LIFETIME = 120

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Weapons = require(Shared.Data.Weapons)

local function part(props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = true
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	return p
end

return function(ctx)
	local S = ctx.S
	local weaponId = ctx.params.weapon
	local weapon = Weapons.get(weaponId)
	local name = weapon and weapon.name or weaponId
	local pos = ctx.groundAt(ctx.pos)

	S.Fx.play("DropPod", { p = pos, kind = "weapon", t = POD_FALL })
	task.wait(POD_FALL)
	S.Fx.play("Explosion", { p = pos, r = 4, size = "S", style = "spark" })
	S.Fx.play("Shake", { p = pos, mag = 0.8, r = 40 })

	local yaw = math.atan2(-ctx.dir.X, -ctx.dir.Z)
	local cf = CFrame.new(pos + Vector3.new(0, 0.7, 0)) * CFrame.Angles(0, yaw, 0)
	local model = Instance.new("Model")
	model.Name = "WeaponCase"
	local body = part({
		Name = "Body", Size = Vector3.new(4.4, 1.3, 1.7), Material = Enum.Material.Metal,
		Color = Color3.fromRGB(40, 46, 58), CFrame = cf,
	})
	body.Parent = model
	part({
		Name = "Stripe", Size = Vector3.new(4.5, 0.25, 0.5), Material = Enum.Material.Neon,
		Color = Color3.fromRGB(47, 139, 255), CFrame = cf * CFrame.new(0, 0.66, 0), CanCollide = false,
	}).Parent = model
	for _, x in { -1.6, 1.6 } do
		part({
			Name = "Latch", Size = Vector3.new(0.4, 1.4, 1.85), Material = Enum.Material.Metal,
			Color = Color3.fromRGB(255, 138, 43), CFrame = cf * CFrame.new(x, 0, 0), CanCollide = false,
		}).Parent = model
	end
	model.PrimaryPart = body
	model.Parent = ctx.folder
	ctx.onStop(function()
		model:Destroy()
	end)

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 34)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 90
	gui.Parent = body
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 18
	label.TextColor3 = Color3.fromRGB(244, 246, 250)
	label.TextStrokeTransparency = 0
	label.Text = string.upper(name)
	label.Parent = gui

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pick up " .. name
	prompt.ObjectText = "Support Weapon"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = body

	local taken = false
	local conn = prompt.Triggered:Connect(function(player)
		if taken or not S.Players.isAlive(player) then
			return
		end
		taken = true
		S.Players.giveSupport(player, weaponId)
		S.Fx.to(player, "Sound", { k = "Pickup", p = body.Position })
		S.State.notify(player, "Picked up " .. name, Color3.fromRGB(62, 230, 200), "callin")
	end)
	ctx.onStop(function()
		conn:Disconnect()
	end)

	local t0 = os.clock()
	while not taken and os.clock() - t0 < LIFETIME do
		task.wait(0.5)
	end
	prompt.Enabled = false
end
