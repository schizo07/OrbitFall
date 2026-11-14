-- Gravity Well: a vortex drags enemies toward the centre for `pullTime` s (S.Enemies.push, heavier classes resist),
-- then bursts through S.Explosions.blast. Blast radius / core / knock / effect size: Data/Blasts.luau (GRAVWELL row).
local Blasts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Blasts"))

local FALL = 0.6
local TICK = 0.1

return function(ctx)
	local S = ctx.S
	local prm = Blasts.merge("GRAVWELL", ctx.params)
	local pos = ctx.groundAt(ctx.pos)

	S.Fx.play("Shell", { p = pos, t = FALL, s = 0.6, c = Color3.fromRGB(175, 95, 255) })
	task.wait(FALL)

	S.Fx.play("GravWell", { p = pos, r = prm.pullRadius, t = prm.pullTime })
	S.Fx.play("Sound", { k = "EMPPulse", p = pos })

	local startT = os.clock()
	while true do
		task.wait(TICK)
		local u = (os.clock() - startT) / prm.pullTime
		if u >= 1 then
			break
		end
		for _, e in S.Enemies.getInRadius(pos, prm.pullRadius) do
			if e.alive and e.root then
				local ep = e.pos or e.root.Position
				local to = Vector3.new(pos.X - ep.X, 0, pos.Z - ep.Z)
				local d = to.Magnitude
				if d > 1.5 then
					if S.Enemies.push then
						-- pull strengthens over the window; never faster than closing the gap in ~1.5 ticks
						local speed = math.min(prm.pullSpeed * (0.6 + 0.8 * u), d / (TICK * 1.5))
						S.Enemies.push(e, to.Unit * speed, TICK * 1.6)
					else
						S.Enemies.applyStatus(e, "slow", TICK * 3, 0.6)
					end
				end
			end
		end
	end

	S.Explosions.blast(pos, {
		radius = prm.radius,
		core = prm.core,
		damage = prm.damage,
		ap = prm.ap,
		size = "L",
		style = "void",
		vis = prm.vis,
		knock = prm.knock,
		shake = prm.shake,
		legacy = { shake = 1.6, shakeR = 70, shockwave = prm.radius * 1.3, crater = 5 },
	}, ctx.source)
end
