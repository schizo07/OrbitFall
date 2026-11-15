-- Cryo Bomb: a cold blast that freezes every enemy in the radius for `freeze` s (half for behemoths). Frozen enemies
-- stop (model attribute FrozenUntil, honoured by the enemy AI, plus a stun as a fallback) and take x`shatter` damage
-- from bullets and blasts while frozen (server/WeaponService, server/Explosions). Radius / effect size: Data/Blasts.luau.
local Blasts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Blasts"))

local Combos = require(script.Parent.Parent:WaitForChild("Combos"))

local FALL = 0.7

return function(ctx)
	local S = ctx.S
	local prm = Blasts.merge("CRYO", ctx.params)
	local pos = ctx.groundAt(ctx.pos)

	S.Fx.play("Shell", { p = pos, t = FALL, s = 0.7, c = Color3.fromRGB(150, 225, 255) })
	task.wait(FALL)

	-- the blast lands first, so its own damage is not doubled
	S.Explosions.blast(pos, {
		radius = prm.radius,
		core = prm.core,
		damage = prm.damage,
		ap = prm.ap,
		size = "L",
		style = "ice",
		vis = prm.vis,
		knock = prm.knock,
		shake = prm.shake,
	}, ctx.source)

	local now = workspace:GetServerTimeNow()
	for _, e in S.Enemies.getInRadius(pos, prm.radius) do
		if e.alive and e.model then
			local dur = if e.class == "behemoth" then prm.freeze * 0.5 else prm.freeze
			local prev = e.model:GetAttribute("FrozenUntil")
			local untilT = now + dur
			if type(prev) ~= "number" or prev < untilT then
				e.model:SetAttribute("FrozenUntil", untilT)
			end
			S.Enemies.applyStatus(e, "stun", prm.freeze, nil, ctx.source)
		end
	end
	S.Fx.play("CryoFreeze", { p = pos, r = prm.radius, t = prm.freeze })

	-- SHATTER IMPLOSION combo (Studio A/B CALL-IN COMBOS): going off inside a pulling Gravity Well flags it; its end burst
	-- then shatters everything frozen it pulled (Effects/GRAVWELL.luau)
	local well = Combos.wellNear(pos)
	if well then
		well.handle.shatter = true
	end
end
