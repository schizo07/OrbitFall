-- Minefield: 12 proximity mines. Arm after 1 s, trigger on enemies only (never players).
local POD_FALL = 1.2
local ARM_TIME = 1.0
local TICK = 0.125
local TRIGGER = 3.2

local function makeMine(parent: Instance, pos: Vector3, normal: Vector3)
	local model = Instance.new("Model")
	model.Name = "Mine"
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Shape = Enum.PartType.Cylinder
	base.Size = Vector3.new(0.5, 1.9, 1.9)
	base.Material = Enum.Material.Metal
	base.Color = Color3.fromRGB(58, 62, 70)
	base.Anchored = true
	base.CanCollide = false
	base.CanQuery = false
	base.CanTouch = false
	base.CastShadow = false
	-- cylinder axis is local X; point it along the surface normal
	local ref = math.abs(normal.Y) > 0.9 and Vector3.xAxis or Vector3.yAxis
	base.CFrame = CFrame.fromMatrix(pos + normal * 0.25, normal, normal:Cross(ref).Unit)
	base.Parent = model
	local lamp = Instance.new("Part")
	lamp.Name = "Lamp"
	lamp.Shape = Enum.PartType.Ball
	lamp.Size = Vector3.new(0.5, 0.5, 0.5)
	lamp.Material = Enum.Material.Neon
	lamp.Color = Color3.fromRGB(255, 200, 40)
	lamp.Anchored = true
	lamp.CanCollide = false
	lamp.CanQuery = false
	lamp.CanTouch = false
	lamp.CastShadow = false
	lamp.CFrame = CFrame.new(pos + normal * 0.6)
	lamp.Parent = model
	model.PrimaryPart = base
	model.Parent = parent
	return model, lamp
end

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local center = ctx.groundAt(ctx.pos)
	local radius = prm.spread / 2

	S.Fx.play("DropPod", { p = center, kind = "mines", t = POD_FALL })
	task.wait(POD_FALL)
	S.Fx.play("Explosion", { p = center, r = 4, size = "S", style = "spark" })

	local container = Instance.new("Folder")
	container.Name = "Minefield"
	container.Parent = ctx.folder
	ctx.onStop(function()
		container:Destroy()
	end)

	-- sunflower layout inside the circle
	local mines = {}
	for i = 1, prm.count do
		local r = radius * math.sqrt((i - 0.5) / prm.count)
		local ang = i * 2.39996
		local p, n = ctx.groundAt(center + Vector3.new(math.cos(ang) * r, 0, math.sin(ang) * r))
		if n.Y < 0.5 then
			n = Vector3.yAxis
		end
		local model, lamp = makeMine(container, p, n)
		table.insert(mines, { model = model, lamp = lamp, pos = p, armed = false })
		task.wait(0.04)
	end
	local placedAt = os.clock()
	S.Fx.play("Sound", { k = "MineArm", p = center })

	local lifetime = prm.lifetime
	local beepAt = 0
	local frame = 0
	while #mines > 0 and os.clock() - placedAt < lifetime do
		task.wait(TICK)
		frame += 1
		local t = os.clock() - placedAt
		local armed = t >= ARM_TIME

		-- blink: slow yellow while arming, red pulse when armed
		for _, m in mines do
			if armed then
				if not m.armed then
					m.armed = true
				end
				local on = (frame % 8) < 2
				m.lamp.Color = Color3.fromRGB(255, 40, 30)
				m.lamp.Transparency = on and 0 or 0.8
			end
		end

		if armed then
			local enemies = S.Enemies.getInRadius(center, radius + 14)
			if #enemies > 0 then
				local nearest = math.huge
				for i = #mines, 1, -1 do
					local m = mines[i]
					local hit = false
					for _, e in enemies do
						if e.alive and e.root then
							local rp = e.root.Position
							local flat = math.sqrt((rp.X - m.pos.X) ^ 2 + (rp.Z - m.pos.Z) ^ 2)
							nearest = math.min(nearest, flat)
							if flat <= TRIGGER + (e.def.size or 2) * 0.5 and math.abs(rp.Y - m.pos.Y) < 12 then
								hit = true
								break
							end
						end
					end
					if hit then
						table.remove(mines, i)
						m.model:Destroy()
						ctx.spawn(function()
							S.Fx.play("Explosion", { p = m.pos, r = prm.radius, size = "M", style = "fire" })
							S.Fx.play("Shake", { p = m.pos, mag = 0.8, r = 45 })
							S.Enemies.explode(m.pos, prm.radius, prm.core, prm.damage, prm.ap, ctx.source)
						end)
					end
				end
				if nearest < 10 and os.clock() >= beepAt then
					beepAt = os.clock() + 0.7
					S.Fx.playU("Sound", { k = "MineBeep", p = center })
				end
			end
		end
	end
end
