-- Shield Dome: a generator drops in and projects a dome that stops enemy projectiles.
local RunService = game:GetService("RunService")
local ModelShare = require(script.Parent.Parent.ModelShare)

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

	local gen: BasePart
	local orb: BasePart
	local mesh = ModelShare.visual(S, "callin_shield_emitter") -- Body, Head (spins), glowing Emitter + Cells
	local meshBody = mesh and mesh:FindFirstChild("Body")
	local meshHead = mesh and mesh:FindFirstChild("Head")
	local meshEmitter = mesh and mesh:FindFirstChild("Emitter")
	if mesh and meshBody and meshHead and meshEmitter then
		local rig = ModelShare.rig(mesh)
		local base = CFrame.new(pos)
		ModelShare.pose(rig, base)
		local pivot = S.Assets.pivot("callin_shield_emitter", "Head") or Vector3.new(-0.265, 2.3, 0)
		for _, d in mesh:GetChildren() do
			if d:IsA("BasePart") then
				d.CastShadow = false
				d.Parent = model
			end
		end
		mesh:Destroy()
		gen = meshBody :: BasePart
		gen.CanCollide = true
		gen.CanQuery = true
		orb = meshEmitter :: BasePart
		orb.Name = "Emitter"
		local head = meshHead :: BasePart
		local t0 = os.clock()
		local spin = RunService.Heartbeat:Connect(function()
			local m = ModelShare.hinge(pivot, CFrame.Angles(0, (os.clock() - t0) * 1.6, 0))
			head.CFrame = base * m * rig.rel[head]
			orb.CFrame = base * m * rig.rel[orb]
		end)
		ctx.onStop(function()
			spin:Disconnect()
		end)
	else
		if mesh then
			mesh:Destroy()
		end
		local g = Instance.new("Part")
		g.Name = "Generator"
		g.Shape = Enum.PartType.Cylinder
		g.Size = Vector3.new(2.4, 2.2, 2.2)
		g.Material = Enum.Material.Metal
		g.Color = Color3.fromRGB(44, 52, 66)
		g.Anchored = true
		g.CanCollide = true
		g.CanTouch = false
		g.CFrame = CFrame.new(pos + Vector3.new(0, 1.2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
		g.Parent = model
		gen = g
		local o = Instance.new("Part")
		o.Name = "Orb"
		o.Shape = Enum.PartType.Ball
		o.Size = Vector3.new(1.4, 1.4, 1.4)
		o.Material = Enum.Material.Neon
		o.Color = teal
		o.Anchored = true
		o.CanCollide = false
		o.CanTouch = false
		o.CanQuery = false
		o.CastShadow = false
		o.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
		o.Parent = model
		orb = o
	end
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
