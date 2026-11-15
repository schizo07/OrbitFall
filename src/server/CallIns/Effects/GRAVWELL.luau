-- Gravity Well: a vortex drags enemies toward the centre for `pullTime` s (S.Enemies.push, heavier classes resist),
-- then bursts through S.Explosions.blast. Blast radius / core / knock / effect size: Data/Blasts.luau (GRAVWELL row).
local Blasts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Blasts"))

local Combos = require(script.Parent.Parent:WaitForChild("Combos"))
local Damage = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Damage"))
local CallInData = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("CallIns"))

local FALL = 0.6
local TICK = 0.1

-- FIRE VORTEX combo (Studio A/B CALL-IN COMBOS, Feel_Combos = "on"): fire inside the pull radius (a Firestorm strip, Railshot
-- hot ground, a Volatile blast, a burning enemy) turns the rest of the pull into a fire column. It burns everything it pulls
-- and ends with a bigger burst.
local VORTEX_DPS, VORTEX_AP = 90, 3
local VORTEX_BURN_DPS, VORTEX_BURN_T = 20, 2.5
local VORTEX_RADIUS_MUL, VORTEX_DAMAGE_MUL = 1.3, 1.25
local VORTEX_COLOR = Color3.fromRGB(255, 140, 50)

-- SHATTER IMPLOSION combo (same switch): a Cryo Bomb that goes off inside the pull (Effects/CRYO flags the well), or frozen
-- enemies already in the pull radius. The end burst then counts as a shatter on every frozen enemy it pulled: each takes the
-- full burst damage x the Cryo `shatter` param (the normal blast already gives part of that by distance; the rest is topped up).
local IMPLODE_FX_CAP = 8
local IMPLODE_COLOR = Color3.fromRGB(150, 220, 255)
local cryoDef = CallInData.get("CRYO")
local SHATTER = cryoDef and cryoDef.params.shatter or 2

return function(ctx)
	local S = ctx.S
	local prm = Blasts.merge("GRAVWELL", ctx.params)
	local pos = ctx.groundAt(ctx.pos)
	local combos = Combos.enabled()
	local vortex = false
	local implode = false
	local handle: Combos.WellHandle = {}

	S.Fx.play("Shell", { p = pos, t = FALL, s = 0.6, c = Color3.fromRGB(175, 95, 255) })
	task.wait(FALL)

	S.Fx.play("GravWell", { p = pos, r = prm.pullRadius, t = prm.pullTime })
	S.Fx.play("Sound", { k = "EMPPulse", p = pos })

	local startT = os.clock()
	Combos.addWell(pos, prm.pullRadius, startT + prm.pullTime, handle)
	while true do
		task.wait(TICK)
		local u = (os.clock() - startT) / prm.pullTime
		if u >= 1 or handle.collapse then -- a Railshot slug collapses the well early (RAIL OVERCHARGE)
			break
		end
		if combos and not implode then
			local frozen = handle.shatter == true
			if not frozen then
				for _, e in S.Enemies.getInRadius(pos, prm.pullRadius) do
					if e.alive and S.Explosions.frozenMult(e) > 1 then
						frozen = true
						break
					end
				end
			end
			if frozen then
				implode = true
				S.Fx.play("IceVortex", { p = pos, r = prm.pullRadius, t = prm.pullTime * (1 - u) })
				if S.State and S.State.notify then
					S.State.notify(nil, "COMBO: SHATTER IMPLOSION", IMPLODE_COLOR, "callin")
				end
			end
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

	handle.ended = true

	local radius = if vortex then prm.radius * VORTEX_RADIUS_MUL else prm.radius
	local damage = if vortex then prm.damage * VORTEX_DAMAGE_MUL else prm.damage

	-- shatter top-up: list the frozen enemies before the blast moves or kills them (the blast itself gives damage x falloff x shatter)
	local topUp: { { e: any, extra: number, p: Vector3 } } = {}
	if implode then
		for _, e in S.Enemies.getInRadius(pos, prm.pullRadius) do
			if e.alive and e.root and S.Explosions.frozenMult(e) > 1 then
				local f = Damage.falloff((e.root.Position - pos).Magnitude, prm.core, radius)
				table.insert(topUp, { e = e, extra = damage * SHATTER * (1 - f), p = e.root.Position })
			end
		end
	end

	S.Explosions.blast(pos, {
		radius = radius,
		core = prm.core,
		damage = damage,
		ap = prm.ap,
		size = "L",
		style = if vortex then "fire" else "void",
		vis = if vortex then prm.vis * VORTEX_RADIUS_MUL else prm.vis,
		knock = prm.knock,
		shake = prm.shake,
		legacy = { shake = 1.6, shakeR = 70, shockwave = radius * 1.3, crater = 5 },
	}, ctx.source)

	local fxSent = 0
	for _, t in topUp do
		if t.e.alive and t.extra > 0 then
			S.Enemies.damage(t.e, t.extra, prm.ap, ctx.source, "body")
		end
		if fxSent < IMPLODE_FX_CAP then
			fxSent += 1
			S.Fx.play("Shatter", { p = t.p }) -- also on the ones the blast just killed
		end
	end
end
