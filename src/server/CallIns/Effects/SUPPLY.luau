-- Supply Drop: a pod crushes whatever it lands on, then opens into a resupply crate.
local Players = game:GetService("Players")
local ModelShare = require(script.Parent.Parent.ModelShare)

local POD_FALL = 1.6
local CRATE_LIFETIME = 90
local MAX_TAKES = 4
local SMOOTH_MAT = Enum.Material.SmoothPlastic
local NEON_MAT = Enum.Material.Neon
local DIM_COLOR = Color3.fromRGB(30, 38, 54)

-- direction each petal of callin_supply_pod folds out to (model frame, front = -Z)
local PETAL_OUT = {
	Petal_1 = Vector3.new(0, 0, -1),
	Petal_2 = Vector3.new(-1, 0, 0),
	Petal_3 = Vector3.new(0, 0, 1),
	Petal_4 = Vector3.new(1, 0, 0),
}

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
	if S.Explosions and S.Explosions.blast then
		S.Explosions.blast(pos, {
			radius = prm.crushRadius,
			core = prm.crushRadius,
			damage = prm.crushDamage,
			ap = prm.crushAp,
			size = "M",
			style = "spark",
			knock = 70,
			shake = 1.2,
			shakeRadius = 60,
		}, ctx.source)
	else
		S.Fx.play("Explosion", { p = pos, r = prm.crushRadius + 2, size = "M", style = "spark" })
		S.Fx.play("Shake", { p = pos, mag = 1.2, r = 60 })
		S.Enemies.explode(pos, prm.crushRadius, prm.crushRadius, prm.crushDamage, prm.crushAp, ctx.source)
	end

	-- crate
	local yaw = math.atan2(-ctx.dir.X, -ctx.dir.Z)
	local cf = CFrame.new(pos + Vector3.new(0, 1.35, 0)) * CFrame.Angles(0, yaw, 0)
	local model = Instance.new("Model")
	model.Name = "SupplyCrate"
	local body: BasePart
	local labelY = 3.6
	local ammoCF = cf * CFrame.new(3.3, -0.45, 0)
	local mesh = ModelShare.visual(S, "callin_supply_pod") -- Body, Glow, Thruster, Petal_1..4 (opens like a flower)
	if mesh and not mesh:FindFirstChild("Body") then
		mesh:Destroy()
		mesh = nil
	end
	local petalRig: ModelShare.Rig? = nil
	local meshCF = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
	if mesh then
		local rig = ModelShare.rig(mesh)
		petalRig = rig
		ModelShare.pose(rig, meshCF)
		for _, d in mesh:GetChildren() do
			if d:IsA("BasePart") then
				d.CanQuery = true
				d.Parent = model
			end
		end
		mesh:Destroy()
		body = rig.parts.Body
		body.CanCollide = true
		body.Name = "Body"
		model.PrimaryPart = body
		labelY = 5.8
		ammoCF = meshCF * CFrame.new(3.5, 0.9, 3.5) -- between two petals, clear of the open flower
	else
		body = part({
			Name = "Body", Size = Vector3.new(4.4, 2.7, 3.2), Material = Enum.Material.Metal,
			Color = Color3.fromRGB(52, 74, 104), CFrame = cf,
		})
		body.Parent = model
		part({
			Name = "Lid", Size = Vector3.new(4.6, 0.35, 3.4), Material = SMOOTH_MAT,
			Color = DIM_COLOR, CFrame = cf * CFrame.new(0, 1.4, 0), CanCollide = false,
		}).Parent = model
		part({
			Name = "Stripe", Size = Vector3.new(4.5, 0.5, 0.25), Material = NEON_MAT,
			Color = Color3.fromRGB(47, 139, 255), CFrame = cf * CFrame.new(0, 0.3, 1.65), CanCollide = false,
		}).Parent = model
		part({
			Name = "Stripe2", Size = Vector3.new(4.5, 0.5, 0.25), Material = NEON_MAT,
			Color = Color3.fromRGB(47, 139, 255), CFrame = cf * CFrame.new(0, 0.3, -1.65), CanCollide = false,
		}).Parent = model
		model.PrimaryPart = body
	end
	if S.Weapons and S.Weapons.spawnAmmoPack then -- big-ammo backpack beside the crate (server/WeaponService)
		S.Weapons.spawnAmmoPack(model, ammoCF)
	end
	model.Parent = ctx.folder
	if petalRig then
		-- the petals fold out over 0.5 s (the client pod has just landed closed on the same spot)
		local rig = petalRig
		task.spawn(function()
			local t0 = os.clock()
			while true do
				local a = math.clamp((os.clock() - t0) / 0.5, 0, 1)
				local e = 1 - (1 - a) * (1 - a)
				local motions: { [string]: CFrame } = {}
				for name, out in PETAL_OUT do
					local pv = S.Assets.pivot("callin_supply_pod", name)
					if pv then
						motions[name] = ModelShare.hinge(pv, CFrame.fromAxisAngle(Vector3.new(0, 1, 0):Cross(out), math.rad(80) * e))
					end
				end
				if not model.Parent then
					return
				end
				ModelShare.pose(rig, meshCF, motions)
				if a >= 1 then
					return
				end
				task.wait()
			end
		end)
	end
	ctx.onStop(function()
		model:Destroy()
	end)

	local playerCap = if type(prm.players) == "number" and prm.players > 0 then math.min(prm.players, MAX_TAKES) else MAX_TAKES
	local maxTakes = math.clamp(#Players:GetPlayers(), 1, playerCap)
	local remaining = maxTakes
	local taken: { [number]: boolean } = {}
	local closed = false
	local conn: RBXScriptConnection? = nil
	local removingConn: RBXScriptConnection? = nil

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(150, 34)
	gui.StudsOffset = Vector3.new(0, labelY, 0)
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

	local prompt = Instance.new("ProximityPrompt")
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = body

	local function refreshState()
		if remaining > 0 then
			label.Text = ("SUPPLY  %d/%d"):format(remaining, maxTakes)
			prompt.ActionText = "Resupply"
			prompt.ObjectText = ("Supply Crate (%d/%d)"):format(remaining, maxTakes)
		else
			label.Text = "EMPTY"
			prompt.ActionText = "EMPTY"
			prompt.ObjectText = "Supply Crate (EMPTY)"
		end
	end

	local function dimLights()
		local ammoPack = model:FindFirstChild("AmmoPackPickup")
		for _, d in model:GetDescendants() do
			if ammoPack and (d == ammoPack or d:IsDescendantOf(ammoPack)) then
				continue
			end
			if d:IsA("Light") then
				d.Brightness = 0
				d.Enabled = false
			elseif d:IsA("BasePart") and d.Material == NEON_MAT then
				d.Material = SMOOTH_MAT
				d.Color = d.Color:Lerp(DIM_COLOR, 0.75)
			end
		end
	end

	local function allActivePlayersTook(): boolean
		local active = Players:GetPlayers()
		if #active == 0 then
			return false
		end
		for _, p in active do
			if not taken[p.UserId] then
				return false
			end
		end
		return true
	end

	local function closePod()
		if closed then
			return
		end
		closed = true
		prompt.Enabled = false
		prompt.ActionText = "EMPTY"
		prompt.ObjectText = "Supply Crate (EMPTY)"
		label.Text = "EMPTY"
		if conn then
			conn:Disconnect()
			conn = nil
		end
		if removingConn then
			removingConn:Disconnect()
			removingConn = nil
		end
		dimLights()
	end

	refreshState()

	conn = prompt.Triggered:Connect(function(player)
		if closed or remaining <= 0 or not player or not S.Players.isAlive(player) then
			return
		end
		local uid = player.UserId
		if taken[uid] then
			S.State.notify(player, "You already took supplies from this crate", nil, "callin")
			return
		end
		taken[uid] = true
		remaining -= 1
		S.Players.refill(player, { grenades = prm.grenades })
		S.Fx.to(player, "Sound", { k = "CrateOpen", p = body.Position })
		S.State.notify(player, "Resupplied", Color3.fromRGB(62, 230, 200), "callin")
		refreshState()
		if remaining <= 0 or allActivePlayersTook() then
			closePod()
		end
	end)
	removingConn = Players.PlayerRemoving:Connect(function()
		if not closed and next(taken) ~= nil then
			task.defer(function()
				if not closed and (remaining <= 0 or allActivePlayersTook()) then
					closePod()
				end
			end)
		end
	end)
	ctx.onStop(function()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		if removingConn then
			removingConn:Disconnect()
			removingConn = nil
		end
	end)

	local t0 = os.clock()
	while not closed and remaining > 0 and os.clock() - t0 < CRATE_LIFETIME do
		task.wait(0.5)
	end
	closePod()
	task.wait(1.5)
end
