-- Strafe Run: a jet flies along the throw direction and carpets a 40-stud line with bombs.
-- Bomb radius / core / knock / effect size: Data/Blasts.luau (STRAFE row) over Data/CallIns.luau params.
local Blasts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Blasts"))

local ALTITUDE = 80
local APPROACH = 220 -- jet starts/ends this far from the line centre
local JET_SPEED = 160
local FALL = 0.55

return function(ctx)
	local S = ctx.S
	local prm = Blasts.merge("STRAFE", ctx.params)
	local dir = ctx.dir
	local center = ctx.pos
	local up = Vector3.new(0, ALTITUDE, 0)
	local a = center - dir * APPROACH + up
	local b = center + dir * APPROACH + up
	local total = (APPROACH * 2) / JET_SPEED

	S.Fx.play("Jet", { a = a, b = b, t = total })

	local half = prm.length / 2
	local n = prm.bombs
	local startT = os.clock()
	for k = 0, n - 1 do
		local s = -half + k * (prm.length / math.max(n - 1, 1))
		local hitAt = (APPROACH + s) / JET_SPEED -- jet is over the point
		local releaseAt = hitAt - FALL
		local wait = releaseAt - (os.clock() - startT)
		if wait > 0 then
			task.wait(wait)
		end
		local p = ctx.groundAt(center + dir * s)
		local from = center + dir * (s - JET_SPEED * FALL) + up
		S.Fx.play("Bomb", { p = p, t = FALL, s = 0.45, from = from })
		ctx.spawn(function()
			task.wait(FALL)
			S.Explosions.blast(p, {
				radius = prm.radius,
				core = prm.core,
				damage = prm.damage,
				ap = prm.ap,
				size = "M",
				style = "fire",
				vis = prm.vis,
				knock = prm.knock,
				shake = prm.shake,
				legacy = { shake = 0.9, shakeR = 50 },
			}, ctx.source)
		end)
	end
end
