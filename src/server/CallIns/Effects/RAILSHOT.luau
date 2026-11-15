-- Railshot: a targeting laser locks on the beacon for `charge` s, then one orbital slug hits exactly there.
-- Direct hit: `damage` at AP `ap` (tank armour) to every enemy whose body overlaps `hitRadius`; then a small splash
-- through S.Explosions.blast (Data/Blasts.luau RAILSHOT row: radius / core / knock / effect size).
local Blasts = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Blasts"))

local Combos = require(script.Parent.Parent:WaitForChild("Combos"))

local OVERCHARGE_RADIUS_MUL = 1.5
local OVERCHARGE_COLOR = Color3.fromRGB(225, 200, 255)

return function(ctx)
	local S = ctx.S
	local prm = Blasts.merge("RAILSHOT", ctx.params)
	local pos = ctx.groundAt(ctx.pos)

	S.Fx.play("Railshot", { p = pos, t = prm.charge })
	task.wait(prm.charge)

	-- RAIL OVERCHARGE combo (Studio A/B CALL-IN COMBOS): a slug landing inside a pulling Gravity Well overcharges. The direct hit
	-- reaches the well's whole pull radius, the splash grows and the slug collapses the well on the spot (its burst follows).
	local hitRadius, radius, vis = prm.hitRadius, prm.radius, prm.vis
	local well = Combos.wellNear(pos)
	if well then
		hitRadius = math.max(hitRadius, well.radius)
		radius = prm.radius * OVERCHARGE_RADIUS_MUL
		vis = prm.vis * OVERCHARGE_RADIUS_MUL
		well.handle.collapse = true
		S.Fx.play("RailOvercharge", { p = pos, r = hitRadius })
		if S.State and S.State.notify then
			S.State.notify(nil, "COMBO: RAIL OVERCHARGE", OVERCHARGE_COLOR, "callin")
		end
	end

	for _, e in S.Enemies.getInRadius(pos, hitRadius + 6) do
		if e.alive and e.root then
			local rp = e.root.Position
			local flat = math.sqrt((rp.X - pos.X) ^ 2 + (rp.Z - pos.Z) ^ 2)
			if flat <= hitRadius + (e.def.size or 2) * 0.6 and math.abs(rp.Y - pos.Y) < 30 then
				local mult = S.Explosions.frozenMult(e) -- Cryo shatter on the direct hit
				S.Enemies.damage(e, prm.damage * mult, prm.ap, ctx.source, "body")
				if mult > 1 then
					S.Fx.play("Shatter", { p = rp })
				end
			end
		end
	end

	S.Explosions.blast(pos, {
		radius = radius,
		core = prm.core,
		damage = prm.splash,
		ap = prm.splashAp,
		size = "M",
		style = "rail",
		vis = vis,
		knock = prm.knock,
		shake = prm.shake,
		legacy = { shake = 1.2, shakeR = 70, shockwave = radius * 1.5, crater = 3 },
	}, ctx.source)

	-- Idea (Studio A/B "RAILSHOT HOT GROUND", Feel_RailHot = "on"): the slug leaves a molten pool that burns for a few s
	if workspace:GetAttribute("Feel_RailHot") ~= "on" then
		return
	end
	local HOT_R, HOT_T, HOT_DPS, HOT_AP = 4.5, 6, 70, 3
	S.Fx.play("Firestorm", { a = pos - Vector3.new(1.5, 0, 0), b = pos + Vector3.new(1.5, 0, 0), w = HOT_R * 2, t = HOT_T, n = 3, s = 0.05 })
	local startT = os.clock()
	local last = startT
	Combos.addZone("railhot", pos, HOT_R, startT + HOT_T)
	while os.clock() - startT < HOT_T and ctx.alive() do
		task.wait(0.25)
		local t = os.clock()
		local dt = math.min(t - last, 0.5)
		last = t
		for _, e in S.Enemies.getInRadius(pos, HOT_R) do
			if e.alive and e.root and math.abs(e.root.Position.Y - pos.Y) < 8 then
				S.Enemies.damage(e, HOT_DPS * dt, HOT_AP, ctx.source, "body")
			end
		end
	end
end
