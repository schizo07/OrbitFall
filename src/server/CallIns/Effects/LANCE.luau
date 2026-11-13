-- Orbital Lance: a 12 s beam from orbit. Cuts through everything in a vertical column (AP 6) and
-- crawls toward the juiciest enemy within hunt radius.
local TICK = 0.1
local CLASS_WEIGHT = { regular = 1, medium = 1.15, heavy = 1.3, behemoth = 1.5 }

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local id = ctx.nextId()
	local pos = ctx.groundAt(ctx.pos)
	local radius = prm.radius

	S.Fx.play("LanceStart", { id = id, p = pos, r = radius })
	ctx.onStop(function()
		S.Fx.play("LanceEnd", { id = id })
		S.Fx.play("Crater", { p = pos, r = 5 })
	end)

	local function pickTarget()
		local best, bestScore = nil, -1
		for _, e in S.Enemies.getInRadius(pos, prm.huntRadius) do
			if e.alive and e.root then
				local score = e.hp * (CLASS_WEIGHT[e.class] or 1)
				if score > bestScore then
					best, bestScore = e, score
				end
			end
		end
		return best
	end

	local startT = os.clock()
	local last = startT
	local target = nil
	local retargetAt = 0
	local shakeAt = 0
	local scratch = 0

	while true do
		task.wait(TICK)
		local t = os.clock()
		local dt = math.min(t - last, 0.25)
		last = t
		if t - startT >= prm.duration then
			break
		end

		-- damage everything in the column
		for _, e in S.Enemies.getInRadius(pos, radius + 22) do
			if e.alive and e.root then
				local rp = e.root.Position
				local flat = math.sqrt((rp.X - pos.X) ^ 2 + (rp.Z - pos.Z) ^ 2)
				if flat <= radius + (e.def.size or 2) * 0.6 and math.abs(rp.Y - pos.Y) < 40 then
					S.Enemies.damage(e, prm.dps * dt, prm.ap, ctx.source, "body")
				end
			end
		end

		-- hunt
		local valid = target ~= nil and target.alive and target.root ~= nil and target.root.Parent ~= nil
		if valid then
			local tp = target.root.Position
			if math.sqrt((tp.X - pos.X) ^ 2 + (tp.Z - pos.Z) ^ 2) > prm.huntRadius * 1.2 then
				valid = false
			end
		end
		if not valid or t >= retargetAt then
			target = pickTarget()
			retargetAt = t + 0.6
		end
		if target and target.root then
			local tp = target.root.Position
			local to = Vector3.new(tp.X - pos.X, 0, tp.Z - pos.Z)
			local d = to.Magnitude
			if d > 0.4 then
				local np = pos + to.Unit * math.min(prm.speed * dt, d)
				pos = ctx.groundAt(Vector3.new(np.X, pos.Y, np.Z))
			end
		end

		S.Fx.playU("LanceMove", { id = id, p = pos })
		if t >= shakeAt then
			shakeAt = t + 0.5
			S.Fx.play("Shake", { p = pos, mag = 0.5, r = 70 })
		end
		scratch += dt
		if scratch >= 2 then
			scratch = 0
			S.Fx.play("Crater", { p = pos, r = 3 })
		end
	end
end
