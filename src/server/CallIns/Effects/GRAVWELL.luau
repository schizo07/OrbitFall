-- Gravity Well: a vortex drags enemies toward the centre for `pullTime` s (S.Enemies.push, heavier classes resist),
-- then bursts through S.Explosions.blast. Blast radius / core / knock / effect size: Data/Blasts.luau (GRAVWELL row).
local Blasts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Blasts"))

local Combos = require(script.Parent.Parent:WaitForChild("Combos"))

local FALL = 0.6
local TICK = 0.1

-- FIRE VORTEX combo (Studio A/B CALL-IN COMBOS, Feel_Combos = "on"): fire inside the pull radius (a Firestorm strip, Railshot
-- hot ground, a Volatile blast, a burning enemy) turns the rest of the pull into a fire column. It burns everything it pulls
-- and ends with a bigger burst.
local VORTEX_DPS, VORTEX_AP = 90, 3
local VORTEX_BURN_DPS, VORTEX_BURN_T = 20, 2.5
local VORTEX_RADIUS_MUL, VORTEX_DAMAGE_MUL = 1.3, 1.25
local VORTEX_COLOR = Color3.fromRGB(255, 140, 50)

return function(ctx)
	local S = ctx.S
	local prm = Blasts.merge("GRAVWELL", ctx.params)
	local pos = ctx.groundAt(ctx.pos)
	local combos = Combos.enabled()
	local vortex = false

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
		if combos and not vortex and (Combos.fireNear(pos, prm.pullRadius) or Combos.burningNear(S, pos, prm.pullRadius)) then
			vortex = true
			S.Fx.play("FireVortex", { p = pos, r = prm.pullRadius, t = prm.pullTime * (1 - u) })
			if S.State and S.State.notify then
				S.State.notify(nil, "COMBO: FIRE VORTEX", VORTEX_COLOR, "callin")
			end
		end
		for _, e in S.Enemies.getInRadius(pos, prm.pullRadius) do
			if e.alive and e.root then
				if vortex then
					S.Enemies.damage(e, VORTEX_DPS * TICK, VORTEX_AP, ctx.source, "body")
					if e.alive then
						S.Enemies.applyStatus(e, "burn", VORTEX_BURN_T, VORTEX_BURN_DPS, ctx.source)
					end
				end
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

	local radius = if vortex then prm.radius * VORTEX_RADIUS_MUL else prm.radius
	S.Explosions.blast(pos, {
		radius = radius,
		core = prm.core,
		damage = if vortex then prm.damage * VORTEX_DAMAGE_MUL else prm.damage,
		ap = prm.ap,
		size = "L",
		style = if vortex then "fire" else "void",
		vis = if vortex then prm.vis * VORTEX_RADIUS_MUL else prm.vis,
		knock = prm.knock,
		shake = prm.shake,
		legacy = { shake = 1.6, shakeR = 70, shockwave = radius * 1.3, crater = 5 },
	}, ctx.source)
end
