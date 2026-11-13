-- EMP Burst: stuns robots, slows bugs, 60 dmg, strips shields.
local FALL = 0.8

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local pos = ctx.groundAt(ctx.pos)

	S.Fx.play("Shell", { p = pos, t = FALL, s = 1, c = Color3.fromRGB(110, 190, 255) })
	task.wait(FALL)

	S.Fx.play("Explosion", { p = pos, r = prm.radius, size = "L", style = "emp" })
	S.Fx.play("Shockwave", { p = pos, r = prm.radius })
	S.Fx.play("Shake", { p = pos, mag = 1.2, r = 60 })
	S.Fx.play("Sound", { k = "EMPPulse", p = pos })

	local until_ = workspace:GetServerTimeNow() + prm.stun
	for _, e in S.Enemies.getInRadius(pos, prm.radius) do
		if e.alive then
			S.Enemies.damage(e, prm.damage, 6, ctx.source, "body")
			if e.alive then
				if e.faction == "COG" then
					S.Enemies.applyStatus(e, "stun", prm.stun)
					if e.model then
						-- hint for the enemy AI: shield/riot gear is offline until this server time
						e.model:SetAttribute("EmpUntil", until_)
					end
				else
					S.Enemies.applyStatus(e, "slow", prm.slowTime, prm.slow)
				end
			end
		end
	end
end
