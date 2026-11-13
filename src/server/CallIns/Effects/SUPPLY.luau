-- Supply Drop: a pod crushes whatever it lands on, then opens into a resupply crate.
local POD_FALL = 1.6
local CRATE_LIFETIME = 90

local function part(props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = true
	p.CanQuery = true
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
	local prm = ctx.params
	local pos = ctx.groundAt(ctx.pos)

	S.Fx.play("DropPod", { p = pos, kind = "supply", t = POD_FALL })
	task.wait(POD_FALL)

	-- crush
	S.Fx.play("Explosion", { p = pos, r = prm.crushRadius + 2, size = "M", style = "spark" })
	S.Fx.play("Shake", { p = pos, mag = 1.2, r = 60 })
	S.Enemies.explode(pos, prm.crushRadius, prm.crushRadius, prm.crushDamage, prm.crushAp, ctx.source)

	-- crate
	local yaw = math.atan2(-ctx.dir.X, -ctx.dir.Z)
	local cf = CFrame.new(pos + Vector3.new(0, 1.35, 0)) * CFrame.Angles(0, yaw, 0)
	local model = Instance.new("Model")
	model.Name = "SupplyCrate"
	local body = part({
		Name = "Body", Size = Vector3.new(4.4, 2.7, 3.2), Material = Enum.Material.Metal,
		Color = Color3.fromRGB(52, 74, 104), CFrame = cf,
	})
	body.Parent = model
	part({
		Name = "Lid", Size = Vector3.new(4.6, 0.35, 3.4), Material = Enum.Material.SmoothPlastic,
		Color = Color3.fromRGB(30, 38, 54), CFrame = cf * CFrame.new(0, 1.4, 0), CanCollide = false,
	}).Parent = model
	part({
		Name = "Stripe", Size = Vector3.new(4.5, 0.5, 0.25), Material = Enum.Material.Neon,
		Color = Color3.fromRGB(47, 139, 255), CFrame = cf * CFrame.new(0, 0.3, 1.65), CanCollide = false,
	}).Parent = model
	part({
		Name = "Stripe2", Size = Vector3.new(4.5, 0.5, 0.25), Material = Enum.Material.Neon,
		Color = Color3.fromRGB(47, 139, 255), CFrame = cf * CFrame.new(0, 0.3, -1.65), CanCollide = false,
	}).Parent = model
	model.PrimaryPart = body
	model.Parent = ctx.folder
	ctx.onStop(function()
		model:Destroy()
	end)

	local remaining = prm.players
	local taken: { [number]: boolean } = {}

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(150, 34)
	gui.StudsOffset = Vector3.new(0, 3.6, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 80
	gui.Parent = body
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 20
	label.TextColor3 = Color3.fromRGB(244, 246, 250)
	label.TextStrokeTransparency = 0
	label.Parent = gui
	local function refreshLabel()
		label.Text = ("SUPPLY  %d/%d"):format(remaining, prm.players)
	end
	refreshLabel()

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Resupply"
	prompt.ObjectText = "Supply Crate"
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = body

	local conn = prompt.Triggered:Connect(function(player)
		if remaining <= 0 or not S.Players.isAlive(player) then
			return
		end
		if taken[player.UserId] then
			S.State.notify(player, "You already took supplies from this crate", nil, "callin")
			return
		end
		taken[player.UserId] = true
		remaining -= 1
		S.Players.refill(player, { grenades = prm.grenades })
		S.Fx.to(player, "Sound", { k = "CrateOpen", p = body.Position })
		S.State.notify(player, "Resupplied", Color3.fromRGB(62, 230, 200), "callin")
		refreshLabel()
	end)
	ctx.onStop(function()
		conn:Disconnect()
	end)

	local t0 = os.clock()
	while remaining > 0 and os.clock() - t0 < CRATE_LIFETIME do
		task.wait(0.5)
	end
	prompt.Enabled = false
	label.Text = "EMPTY"
	task.wait(1.5)
end
