-- Railshot: a targeting laser locks on the beacon for `charge` s, then one orbital slug hits exactly there.
-- Direct hit: `damage` at AP `ap` (tank armour) to every enemy whose body overlaps `hitRadius`; then a small splash
-- through S.Explosions.blast (Data/Blasts.luau RAILSHOT row: radius / core / knock / effect size).
local Blasts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Blasts"))

return function(ctx)
	local S = ctx.S
	local prm = Blasts.merge("RAILSHOT", ctx.params)
	local pos = ctx.groundAt(ctx.pos)

	S.Fx.play("Railshot", { p = pos, t = prm.charge })
	task.wait(prm.charge)

	for _, e in S.Enemies.getInRadius(pos, prm.hitRadius + 6) do
		if e.alive and e.root then
			local rp = e.root.Position
			local flat = math.sqrt((rp.X - pos.X) ^ 2 + (rp.Z - pos.Z) ^ 2)
			if flat <= prm.hitRadius + (e.def.size or 2) * 0.6 and math.abs(rp.Y - pos.Y) < 30 then
				S.Enemies.damage(e, prm.damage, prm.ap, ctx.source, "body")
			end
		end
	end

	S.Explosions.blast(pos, {
		radius = prm.radius,
		core = prm.core,
		damage = prm.splash,
		ap = prm.splashAp,
		size = "M",
		style = "rail",
		vis = prm.vis,
		knock = prm.knock,
		shake = prm.shake,
		legacy = { shake = 1.2, shakeR = 70, shockwave = prm.radius * 1.5, crater = 3 },
	}, ctx.source)
end
