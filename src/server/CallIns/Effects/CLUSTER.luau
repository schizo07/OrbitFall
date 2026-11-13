-- Cluster Drop: a jet releases a canister that bursts into 30 bomblets over an 18x10 patch.
local ALTITUDE = 80
local APPROACH = 200
local JET_SPEED = 180
local FALL = 0.6
local BURST_TIME = 1.1 -- seconds over which the bomblets rain down

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local dir = ctx.dir
	local right = Vector3.new(-dir.Z, 0, dir.X)
	local center = ctx.pos
	local up = Vector3.new(0, ALTITUDE, 0)
	local rng = Random.new()

	S.Fx.play("Jet", {
		a = center - dir * APPROACH + up,
		b = center + dir * APPROACH + up,
		t = (APPROACH * 2) / JET_SPEED,
	})
	task.wait(APPROACH / JET_SPEED) -- jet is overhead: canister bursts

	-- jittered grid of impact points covering length (along dir) x width (across)
	local cols, rows = 6, math.ceil(prm.bomblets / 6)
	local points = {}
	for i = 0, prm.bomblets - 1 do
		local c, r = i % cols, i // cols
		local u = ((c + rng:NextNumber(0.1, 0.9)) / cols - 0.5) * prm.length
		local v = ((r + rng:NextNumber(0.1, 0.9)) / rows - 0.5) * prm.width
		table.insert(points, center + dir * u + right * v)
	end
	for i = #points, 2, -1 do
		local j = rng:NextInteger(1, i)
		points[i], points[j] = points[j], points[i]
	end

	local startT = os.clock()
	for i, raw in points do
		local at = (i - 1) / #points * BURST_TIME
		local wait = at - (os.clock() - startT)
		if wait > 0 then
			task.wait(wait)
		end
		local p = ctx.groundAt(raw)
		S.Fx.play("Shell", { p = p, t = FALL, s = 0.35 })
		ctx.spawn(function()
			task.wait(FALL)
			S.Fx.play("Explosion", { p = p, r = prm.radius, size = "S", style = "fire" })
			S.Enemies.explode(p, prm.radius, prm.core, prm.damage, prm.ap, ctx.source)
		end)
	end
end
