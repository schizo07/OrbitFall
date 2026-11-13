-- Shield Dome: a generator drops in and projects a dome that stops enemy projectiles.
local POD_FALL = 1.0

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local pos = ctx.groundAt(ctx.pos)
	local id = ctx.nextId()

	S.Fx.play("DropPod", { p = pos, kind = "shield", t = POD_FALL })
	task.wait(POD_FALL)
	S.Fx.play("Explosion", { p = pos, r = 4, size = "S", style = "spark" })

	local teal = Color3.fromRGB(62, 230, 200)
	local model = Instance.new("Model")
	model.Name = "ShieldDome"

	local gen = Instance.new("Part")
	gen.Name = "Generator"
	gen.Shape = Enum.PartType.Cylinder
	gen.Size = Vector3.new(2.4, 2.2, 2.2)
	gen.Material = Enum.Material.Metal
	gen.Color = Color3.fromRGB(44, 52, 66)
	gen.Anchored = true
	gen.CanCollide = true
	gen.CanTouch = false
	gen.CFrame = CFrame.new(pos + Vector3.new(0, 1.2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	gen.Parent = model
	local orb = Instance.new("Part")
	orb.Name = "Orb"
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(1.4, 1.4, 1.4)
	orb.Material = Enum.Material.Neon
	orb.Color = teal
	orb.Anchored = true
	orb.CanCollide = false
	orb.CanTouch = false
	orb.CanQuery = false
	orb.CastShadow = false
	orb.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
	orb.Parent = model
	local light = Instance.new("PointLight")
	light.Color = teal
	light.Range = 24
	light.Brightness = 2
	light.Parent = orb

	local dome = Instance.new("Part")
	dome.Name = "Dome"
	dome.Shape = Enum.PartType.Ball
	dome.Size = Vector3.new(prm.radius * 2, prm.radius * 2, prm.radius * 2)
	dome.Material = Enum.Material.ForceField
	dome.Color = teal
	dome.Transparency = 0.35
	dome.Anchored = true
	dome.CanCollide = false
	dome.CanQuery = false
	dome.CanTouch = false
	dome.CastShadow = false
	dome.CFrame = CFrame.new(pos)
	dome.Parent = model
	model.PrimaryPart = gen
	model.Parent = ctx.folder

	local removeDome = ctx.addDome(pos, prm.radius)
	ctx.onStop(function()
		removeDome()
		model:Destroy()
	end)

	S.Fx.play("Dome", { id = id, p = pos, r = prm.radius, t = prm.duration })

	local startT = os.clock()
	while true do
		local left = prm.duration - (os.clock() - startT)
		if left <= 0 then
			break
		end
		if left < 3 then
			-- warning flicker before it drops
			dome.Transparency = (math.floor(left * 6) % 2 == 0) and 0.35 or 0.85
		end
		task.wait(0.1)
	end
	removeDome()
	dome.Transparency = 1
	S.Fx.play("Explosion", { p = pos + Vector3.new(0, 2, 0), r = 5, size = "S", style = "spark" })
end
