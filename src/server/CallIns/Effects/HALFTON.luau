-- Half-Ton Bomb: one huge bomb. Core = 3000 dmg AP 6 (ignores armour); outer ring OUTER_DAMAGE at AP 4, falling to
-- Damage.EDGE of it at the edge (1600 -> 720; was 1600 -> 400 with the old linear falloff).
-- Radius / core / knock / effect size come from Data/Blasts.luau (HALFTON row) over Data/CallIns.luau params.
local Blasts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Blasts"))

local FALL_TIME = 1.5
local OUTER_DAMAGE = 1600

return function(ctx)
	local S = ctx.S
	local prm = Blasts.merge("HALFTON", ctx.params)
	local pos = ctx.groundAt(ctx.pos)

	S.Fx.play("Bomb", { p = pos, t = FALL_TIME })
	task.wait(FALL_TIME)

	-- Inner core (coreDamage): full 3000, ignores all armour.
	S.Explosions.blast(pos, {
		radius = prm.radius,
		core = prm.core,
		damage = OUTER_DAMAGE,
		ap = prm.edgeAp,
		coreDamage = prm.damage,
		coreAp = prm.ap,
		size = "XL",
		style = "fire",
		vis = prm.vis,
		knock = prm.knock,
		shake = prm.shake,
		shakeRadius = prm.shakeRadius,
		legacy = { shake = 2.5, shakeR = prm.shakeRadius, shockwave = prm.radius * 1.4, crater = 9 },
	}, ctx.source)
end
