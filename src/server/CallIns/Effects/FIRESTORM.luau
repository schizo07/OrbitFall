-- Firestorm Line: a jet lays a strip of fire `length` x `width` along the throw direction (centred on the beacon) that
-- burns enemies inside it for `duration` s at `dps` (AP `ap`).
local Combos = require(script.Parent.Parent:WaitForChild("Combos"))

local ALTITUDE = 70
local APPROACH = 200
local JET_SPEED = 170
local TICK = 0.25

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local dir = ctx.dir
	local center = ctx.groundAt(ctx.pos)
	local up = Vector3.new(0, ALTITUDE, 0)
	S.Fx.play("Jet", { a = center - dir * APPROACH + up, b = center + dir * APPROACH + up, t = APPROACH * 2 / JET_SPEED })

	-- the strip ignites as the jet passes over its start
	local half = prm.length / 2
	task.wait(math.max((APPROACH - half) / JET_SPEED, 0))
	local a = ctx.groundAt(center - dir * half)
	local b = ctx.groundAt(center + dir * half)
	S.Fx.play("Firestorm", { a = a, b = b, w = prm.width, t = prm.duration, n = prm.patches, s = prm.length / JET_SPEED })
	S.Fx.play("Sound", { k = "Explosion", p = center })

	local seg = b - a
	local len = math.max(seg.Magnitude, 0.1)
	local axis = seg / len
	local startT = os.clock()
	local last = startT
	-- combos (CALL-IN COMBOS): the strip is a row of fire zones, each registered as the jet's fire reaches it
	local comboSpots = {}
	if Combos.enabled() then
		local step = math.max(prm.width, 4)
		for along = 0, len, step do
			table.insert(comboSpots, along)
		end
	end
	local comboNext = 1
	while os.clock() - startT < prm.duration + prm.length / JET_SPEED do
		task.wait(TICK)
		local t = os.clock()
		local dt = math.min(t - last, 0.5)
		last = t
		-- the burning part grows along the strip at jet speed
		local lit = math.min((t - startT) * JET_SPEED, len)
		while comboSpots[comboNext] and comboSpots[comboNext] <= lit do
			Combos.addZone("firestorm", a + axis * comboSpots[comboNext], prm.width * 0.6, startT + prm.duration)
			comboNext += 1
		end
		for _, e in S.Enemies.getInRadius(center, half + prm.width) do
			if e.alive and e.root then
				local rel = e.root.Position - a
				local along = rel:Dot(axis)
				local side = (rel - axis * along)
				local across = Vector3.new(side.X, 0, side.Z).Magnitude
				if along >= -1 and along <= lit + 1 and across <= prm.width / 2 + (e.def.size or 2) * 0.4 then
					S.Enemies.damage(e, prm.dps * dt, prm.ap, ctx.source, "body")
				end
			end
		end
	end
end
