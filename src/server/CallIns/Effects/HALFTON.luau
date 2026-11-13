-- Half-Ton Bomb: one huge bomb. Core (7 studs) = 3000 dmg AP 6, falling to 400 dmg AP 4 at 18 studs.
local FALL_TIME = 1.5
local EDGE_DAMAGE = 400

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local pos = ctx.groundAt(ctx.pos)

	S.Fx.play("Bomb", { p = pos, t = FALL_TIME })
	task.wait(FALL_TIME)

	S.Fx.play("Explosion", { p = pos, r = prm.radius, size = "XL", style = "fire" })
	S.Fx.play("Shockwave", { p = pos, r = prm.radius * 1.4 })
	S.Fx.play("Shake", { p = pos, mag = 2.5, r = prm.shakeRadius })
	S.Fx.play("Crater", { p = pos, r = 9 })

	-- Outer ring: damage falls linearly from core to 25 % at the edge, so scale it to land on EDGE_DAMAGE.
	S.Enemies.explode(pos, prm.radius, prm.core, EDGE_DAMAGE / 0.25, prm.edgeAp, ctx.source)
	-- Inner core: full 3000, ignores all armour.
	S.Enemies.explode(pos, prm.core, prm.core, prm.damage, prm.ap, ctx.source)
end
