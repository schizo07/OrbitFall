-- Orbital Barrage: shells rain down on a 20-stud disc over several seconds.
-- Shell blast / core / knock / effect size: Data/Blasts.luau (BARRAGE row) over Data/CallIns.luau params.
local Blasts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Blasts"))

local FALL = 1.3

return function(ctx)
	local S = ctx.S
	local prm = Blasts.merge("BARRAGE", ctx.params)
	local center = ctx.pos
	local n = prm.shells
	local rng = Random.new()
	local startT = os.clock()

	for i = 0, n - 1 do
		local at = (i / math.max(n - 1, 1)) * prm.duration * 0.92 + rng:NextNumber(-0.15, 0.15)
		local wait = math.max(at, 0) - (os.clock() - startT)
		if wait > 0 then
			task.wait(wait)
		end
		local ang = rng:NextNumber(0, math.pi * 2)
		local r = prm.radius * math.sqrt(rng:NextNumber())
		local p = ctx.groundAt(center + Vector3.new(math.cos(ang) * r, 0, math.sin(ang) * r))
		S.Fx.play("Shell", { p = p, t = FALL, s = 1 })
		ctx.spawn(function()
			task.wait(FALL)
			S.Explosions.blast(p, {
				radius = prm.blast,
				core = prm.core,
				damage = prm.damage,
				ap = prm.ap,
				size = "L",
				style = "fire",
				vis = prm.vis,
				knock = prm.knock,
				shake = prm.shake,
				legacy = { shake = 1.1, shakeR = 70, crater = 3 },
			}, ctx.source)
		end)
	end
end
