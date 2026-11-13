-- Toxin Cloud: a lingering gas cloud. Bugs take x1.5, robots x0.5; everything inside is confused.
local TICK = 0.2
local FALL = 0.7

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local pos = ctx.groundAt(ctx.pos)
	local id = ctx.nextId()

	S.Fx.play("Shell", { p = pos, t = FALL, s = 0.7, c = Color3.fromRGB(120, 255, 90) })
	task.wait(FALL)

	S.Fx.play("Gas", { id = id, p = pos, r = prm.radius, t = prm.duration })
	S.Fx.play("Shockwave", { p = pos, r = prm.radius * 0.7 })

	local startT = os.clock()
	local last = startT
	while os.clock() - startT < prm.duration do
		task.wait(TICK)
		local t = os.clock()
		local dt = math.min(t - last, 0.5)
		last = t
		for _, e in S.Enemies.getInRadius(pos, prm.radius) do
			if e.alive then
				local mult = if e.faction == "BROOD" then prm.bugMult else prm.robotMult
				S.Enemies.damage(e, prm.dps * mult * dt, 6, ctx.source, "body")
				S.Enemies.applyStatus(e, "confuse", 1.2)
			end
		end
	end
end
