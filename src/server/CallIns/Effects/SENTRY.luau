-- Sentry Turret: drops in, tracks the nearest visible enemy and fires hitscan bursts.
local POD_FALL = 1.2
local HEAD_HEIGHT = 2.7
local MAX_CANDIDATES = 6

local function part(parent: Instance, props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local pos = ctx.groundAt(ctx.pos)

	S.Fx.play("DropPod", { p = pos, kind = "turret", t = POD_FALL })
	task.wait(POD_FALL)
	S.Fx.play("Explosion", { p = pos, r = 4, size = "S", style = "spark" })
	S.Fx.play("Shake", { p = pos, mag = 0.6, r = 35 })

	local model = Instance.new("Model")
	model.Name = "SentryTurret"
	local dark, olive, accent = Color3.fromRGB(44, 48, 56), Color3.fromRGB(74, 96, 70), Color3.fromRGB(255, 138, 43)

	local yaw0 = math.atan2(-ctx.dir.X, -ctx.dir.Z)
	local baseCF = CFrame.new(pos + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, yaw0, 0)
	local base = part(model, {
		Name = "Base", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.6, 3.6, 3.6),
		Material = Enum.Material.Metal, Color = dark, CanCollide = true,
		CFrame = baseCF * CFrame.Angles(0, 0, math.pi / 2),
	})
	part(model, {
		Name = "Column", Shape = Enum.PartType.Cylinder, Size = Vector3.new(2.0, 1.3, 1.3),
		Material = Enum.Material.Metal, Color = dark,
		CFrame = baseCF * CFrame.new(0, 1.3, 0) * CFrame.Angles(0, 0, math.pi / 2),
	})
	for i = 0, 2 do
		local a = i * (math.pi * 2 / 3)
		part(model, {
			Name = "Leg", Size = Vector3.new(0.35, 0.35, 2.4), Material = Enum.Material.Metal, Color = dark,
			CFrame = baseCF * CFrame.Angles(0, a, 0) * CFrame.new(0, 0.6, -1.4) * CFrame.Angles(math.rad(35), 0, 0),
		})
	end
	model.PrimaryPart = base

	-- rotating head (model so we can PivotTo it)
	local head = Instance.new("Model")
	head.Name = "Head"
	head.Parent = model
	local housing = part(head, {
		Name = "Housing", Size = Vector3.new(1.9, 1.4, 2.6), Material = Enum.Material.Metal, Color = olive,
	})
	local muzzles = {}
	for i, x in { -0.55, 0.55 } do
		part(head, {
			Name = "Barrel", Shape = Enum.PartType.Cylinder, Size = Vector3.new(3.0, 0.4, 0.4),
			Material = Enum.Material.Metal, Color = dark, CFrame = CFrame.new(x, 0, -2.6) * CFrame.Angles(0, math.pi / 2, 0),
		})
		local m = part(head, {
			Name = "Muzzle", Shape = Enum.PartType.Ball, Size = Vector3.new(0.7, 0.7, 0.7), Material = Enum.Material.Neon,
			Color = Color3.fromRGB(255, 220, 120), Transparency = 1, CFrame = CFrame.new(x, 0, -4.2),
		})
		muzzles[i] = m
	end
	part(head, { Name = "Ammo", Size = Vector3.new(1.2, 1.0, 1.0), Material = Enum.Material.Metal, Color = dark, CFrame = CFrame.new(0, -0.2, 1.7) })
	part(head, {
		Name = "Eye", Shape = Enum.PartType.Ball, Size = Vector3.new(0.45, 0.45, 0.45), Material = Enum.Material.Neon,
		Color = accent, CFrame = CFrame.new(0, 0.55, -1.0),
	})
	head.PrimaryPart = housing
	local headPos = pos + Vector3.new(0, HEAD_HEIGHT, 0)
	local headCF = CFrame.lookAt(headPos, headPos + ctx.dir)
	head:PivotTo(headCF)
	model.Parent = ctx.folder
	ctx.onStop(function()
		model:Destroy()
	end)

	local destroyed = false
	local structureParts = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(structureParts, d)
		end
	end
	ctx.registerStructure(structureParts, prm.hp, function()
		destroyed = true
	end)

	local rng = Random.new()
	local interval = 60 / prm.rpm
	local ammo = prm.ammo
	local tracerColor = Color3.fromRGB(255, 214, 110)
	local startT = os.clock()
	local last = startT
	local target = nil
	local retargetAt = 0
	local acc = 0
	local shots = 0
	local barrelIdx = 1
	local aimPoint = headPos + ctx.dir * 20
	local emptyAt: number? = nil

	local function muzzleWorld(i: number): Vector3
		return headCF:PointToWorldSpace(Vector3.new(i == 1 and -0.55 or 0.55, 0, -4.2))
	end

	local function pickTarget()
		local origin = muzzleWorld(1)
		local list = S.Enemies.getInRadius(headPos, prm.range)
		table.sort(list, function(a, b)
			return (a.root.Position - headPos).Magnitude < (b.root.Position - headPos).Magnitude
		end)
		for i = 1, math.min(#list, MAX_CANDIDATES) do
			local e = list[i]
			if e.alive and e.root and ctx.los(origin, e.root.Position) then
				return e
			end
		end
		return nil
	end

	local function fire(i: number)
		local origin = muzzleWorld(i)
		local aim = aimPoint - origin
		if aim.Magnitude < 0.1 then
			return
		end
		local spread = math.rad(1.4)
		local d = (CFrame.lookAt(Vector3.zero, aim) * CFrame.Angles(rng:NextNumber(-spread, spread), rng:NextNumber(-spread, spread), 0)).LookVector
		local res = workspace:Raycast(origin, d * prm.range, ctx.enemyParams())
		local b = res and res.Position or origin + d * prm.range
		S.Fx.playU("Tracer", { a = origin, b = b, c = tracerColor, w = "GATLING", u = 0 })
		if res and res.Instance:GetAttribute("EnemyId") then
			S.Enemies.hit(res.Instance, prm.damage, prm.ap, ctx.source, res.Position)
		end
		muzzles[i].Transparency = 0
		task.delay(0.05, function()
			muzzles[i].Transparency = 1
		end)
		shots += 1
		if shots % 3 == 1 then
			S.Fx.playU("Sound", { k = "TurretFire", p = origin })
		end
	end

	while os.clock() - startT < prm.lifetime and not destroyed do
		task.wait()
		local t = os.clock()
		local dt = math.min(t - last, 0.1)
		last = t

		if ammo <= 0 then
			emptyAt = emptyAt or t
			if t - emptyAt > 4 then
				break
			end
		end

		local valid = target ~= nil and target.alive and target.root ~= nil and target.root.Parent ~= nil
		if valid and (target.root.Position - headPos).Magnitude > prm.range then
			valid = false
		end
		if (not valid or t >= retargetAt) and ammo > 0 then
			if not valid or t >= retargetAt then
				target = pickTarget()
				retargetAt = t + 0.3
			end
		end

		if target and target.alive and target.root and ammo > 0 then
			aimPoint = target.root.Position
			local want = CFrame.lookAt(headPos, aimPoint)
			headCF = headCF:Lerp(want, 1 - math.exp(-14 * dt))
			head:PivotTo(headCF)
			local err = math.acos(math.clamp(headCF.LookVector:Dot((aimPoint - headPos).Unit), -1, 1))
			if err < math.rad(8) then
				acc += dt
				local burst = 0
				while acc >= interval and ammo > 0 and burst < 4 do
					acc -= interval
					burst += 1
					ammo -= 1
					fire(barrelIdx)
					barrelIdx = 3 - barrelIdx
				end
			end
		else
			acc = 0
		end
	end

	S.Fx.play("Explosion", { p = headPos, r = 4, size = "S", style = destroyed and "fire" or "spark" })
end
